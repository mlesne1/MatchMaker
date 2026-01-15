--[[
	RegionalQueue

	Manages a matchmaking queue for a specific region within a matchmaking mode.
	Handles party storage in MemoryStore, match polling, and distributed coordination.

	This module is internal to MatchMakerService and should not be used directly.
	Use MatchMakerService:AddPartyAsync() and MatchMakerService:RemovePartyAsync() instead.

	Architecture:
		- Each RegionalQueue manages parties for one region (e.g., "NA", "EUW")
		- Parties are stored in a MemoryStore SortedMap, sorted by join time
		- One server per region acts as the "coordinator" that runs matchmaking
		- Coordinator election uses a distributed lock in MemoryStore
		- Parties poll for match status every PARTY_REFRESH seconds

	Data Flow:
		1. Party joins → stored in SortedMap with sortKey = joinTime
		2. Coordinator fetches eligible parties via GetRangeAsync
		3. User's MatchMaking function returns Match objects
		4. CreateMatchAsync assigns MatchId to each party in the match
		5. Parties detect MatchId on next poll → teleport to private server

	Configuration Constants:
		QUEUE_TIMEOUT (1200s / 20min)
			Maximum time a party can stay in queue before auto-removal.

		PARTY_TIMEOUT (86400s / 24h)
			MemoryStore expiration time for party data.
			Should be much longer than QUEUE_TIMEOUT to handle edge cases.

		PARTY_REFRESH (5s)
			How often each party polls for match status.

		COORDINATOR_REFRESH (5s)
			How often the coordinator runs the matchmaking loop.

		COORDINATOR_TIMEOUT (30s)
			Lock expiration for coordinator election.
			If coordinator crashes, another server takes over after this time.

		MATCHMAKING_TOTALCOUNT (200)
			Maximum number of parties to fetch per matchmaking cycle.

		MATCHMAKING_SUBCOUNT (50)
			Batch size for GetRangeAsync pagination.

		BIG_QUEUE_TIME (9999999999)
			Sort key used to move parties to the "end" of the queue
			(e.g., when matched or leaving).

		CROSS_REGION_TIMEOUT (60s / 1min)
			Time a party must wait before becoming eligible for
			cross-region matching. Balances latency vs queue time.

		CROSS_REGION_MAX_PARTIES (50)
			Maximum parties to fetch from each fallback region.
			Limits MemoryStore calls while still providing options.

	Cross-Region Matching:
		When parties wait longer than CROSS_REGION_TIMEOUT:
		1. They become "cross-region eligible"
		2. Coordinators from fallback regions can fetch them
		3. They may be matched with parties from other regions
		4. Atomic MatchId assignment prevents double-matching

		Example: NA party waiting 90s may be matched by EUW coordinator
		with EUW parties, resulting in a cross-region match.
]]--

local RegionalQueue = {}
RegionalQueue.__index = RegionalQueue

-- Services

local RunService = game:GetService("RunService")
local MessagingService = game:GetService("MessagingService")
local MemoryStore = game:GetService("MemoryStoreService")

-- Dependencies

local PrivateServer = require(script.Parent.Parent:WaitForChild("PrivateServer"))

local Utils = game.ReplicatedStorage:WaitForChild("Utils")
local Signal = require(Utils:WaitForChild("Signal"))
local Thread = require(Utils:WaitForChild("Thread"))
local Promise = require(Utils:WaitForChild("Promise"))
local Maid = require(Utils:WaitForChild("Maid"))

-- Configuration

local Release = "v0.2"
local RegionLockMap = MemoryStore:GetHashMap("RegionLocks"..Release)

local QUEUE_TIMEOUT = 60 * 20        -- 20 minutes: max time in queue
local PARTY_TIMEOUT = 60 * 60 * 24   -- 24 hours: MemoryStore expiration
local PARTY_REFRESH = 5              -- 5 seconds: poll interval for match status

local BIG_QUEUE_TIME = 9999999999    -- Sort key to move parties to end of queue

local COORDINATOR_REFRESH = 5        -- 5 seconds: matchmaking loop interval
local COORDINATOR_TIMEOUT = 30       -- 30 seconds: coordinator lock expiration

local MATCHMAKING_TOTALCOUNT = 200   -- Max parties per matchmaking cycle
local MATCHMAKING_SUBCOUNT = 50      -- Batch size for GetRangeAsync

local CROSS_REGION_TIMEOUT = 60      -- 60 seconds: time before cross-region fallback
local CROSS_REGION_MAX_PARTIES = 50  -- Max parties to fetch from each fallback region


-- Constructor

function RegionalQueue.new(Params)
	--[[
		Creates a new regional queue instance.

		This is called internally by MatchMakerService:GetRegionalQueue().
		Do not instantiate directly.

		Parameters:
			Params.RegionCode (string) — Region identifier (e.g., "NA", "EUW", "BR").
			Params.Mode (MatchMakerService) — The parent matchmaker instance.

		Returns:
			RegionalQueue — A new queue instance with the following properties:
				- ID (string): Unique identifier "{ModeName}-{RegionCode}"
				- RegionCode (string): The region this queue manages
				- MainServer (boolean): Whether this server is the coordinator
				- Active (boolean): Whether the queue is active
				- SortedMap (MemoryStoreSortedMap): The MemoryStore for party data
				- Cache (table): Local cache of parties on this server
				- Connections (Maid): Connection manager for cleanup

		Side Effects:
			- Registers itself in Mode.RegionalQueues[RegionCode]
			- Creates a new MemoryStore SortedMap for the mode-region pair
	]]--

	local self = setmetatable(Params, RegionalQueue)

	self.RegionCode = self.RegionCode
	self.MainServer = false
	self.Active = true
	self.ID = self.Mode.Name.."-"..self.RegionCode
	self.SortedMap = self:GetSortedMap(self.Mode.Name, self.RegionCode)
	self.Cache = {}
	self.Connections = Maid.new()

	self.Mode.RegionalQueues[self.RegionCode] = self

	self:Print("New regional queue has been created")

	return self
end

-- Party Management

function RegionalQueue:GetSortedMap(Mode, RegionCode)
	--[[
		Returns a MemoryStore SortedMap unique to a mode-region pair.

		The SortedMap name includes the Release version to allow
		for clean migrations between versions.

		Parameters:
			Mode (string) — The matchmaking mode name.
			RegionCode (string) — The region identifier.

		Returns:
			MemoryStoreSortedMap — The SortedMap for storing party data.
			                       Key: PartyId, Value: Party table, SortKey: JoinTime
	]]--

	return game:GetService("MemoryStoreService"):GetSortedMap(Mode.."-"..RegionCode..Release)
end

function RegionalQueue:TeleportPartyAsync(Party, MatchId)
	--[[
		Fetches match data and removes the party from local cache.

		This is called when a party's match is detected during polling.
		The actual teleportation is handled by the game code listening
		to the PartyRemoved event.

		Parameters:
			Party (table) — The party object to teleport.
			MatchId (string) — The PrivateServerId of the match.

		Returns:
			Promise<void> — Resolves after:
				1. Fetching PrivateServerData from MemoryStore
				2. Removing party from local cache
				3. Firing PartyRemoved event with match data

		Errors:
			- Rejects if PrivateServerData cannot be fetched within 10 seconds.
	]]--

	return PrivateServer:GetPrivateServerDataAsync(MatchId)
		:timeout(10, "GetPrivateServerDataAsync timed out for match " .. MatchId)
		:andThen(function(Match)
			self:RemovePartyTable(Party.Id, Match)
		end)
end

function RegionalQueue:CheckIfPartyFoundMatch(Party, LeaveQueue)
	--[[
		Checks if a party has been assigned to a match in MemoryStore.

		This is called periodically (every PARTY_REFRESH seconds) by each party
		to detect when the coordinator has assigned them to a match.

		Parameters:
			Party (table) — The party to check.
			LeaveQueue (boolean?) — If true, marks the party as leaving.
			                        Sets PartyLeft=true and moves to end of queue.

		Returns:
			Promise<string | nil> — Resolves with:
				- MatchId (string) if a match was found
				- nil if no match yet or party data expired

		Behavior:
			- Updates the party's MemoryStore entry (refreshes expiration)
			- If LeaveQueue=true, sets sortKey to BIG_QUEUE_TIME
			- Reads MatchId from the stored party data if present

		Errors:
			- Rejects if MemoryStore UpdateAsync times out (10 seconds).
	]]--

	local MatchId

	return Promise.try(function()

		return self.SortedMap:UpdateAsync(Party.Id, function(oldValue, sortKey)

			if not oldValue then
				-- means the queue timed out
				return nil
			end

			if LeaveQueue then
				oldValue.PartyLeft = true
				sortKey = BIG_QUEUE_TIME
			end

			if oldValue.MatchId then
				-- ayy we found a match !
				MatchId = oldValue.MatchId
			end

			return oldValue, sortKey
		end, PARTY_TIMEOUT)

	end):timeout(10, "CheckIfPartyFoundMatch timed out for party " .. Party.Id)
	:andThen(function()
		return MatchId
	end)
end

function RegionalQueue:AddPartyAsync(PartyMemberIds, PartyData)
	--[[
		Adds a new party to the matchmaking queue.

		Creates a Party object, stores it in MemoryStore, and starts
		polling for match status.

		Parameters:
			PartyMemberIds (table<number>) — Array of UserIds in the party.
			PartyData (table?) — Optional custom data for matchmaking logic.
			                     Passed to your MatchMaking function.

		Returns:
			Promise<Party> — Resolves with the Party object:
				- Id (string): Unique GUID for this party
				- Mode (string): The matchmaking mode name
				- RegionCode (string): The region code
				- MemberIds (table<number>): The provided UserIds
				- Data (table): The provided PartyData (or empty table)
				- QueueTimeStart (number): Unix timestamp when joined

		Side Effects:
			1. Stores party in local Cache for this server
			2. Stores party in MemoryStore SortedMap (sorted by join time)
			3. Starts a polling loop (every 5s) to check for matches
			4. Starts matchmaking coordinator loop if not already running
			5. Fires Mode.PartyAdded event

		Automatic Behaviors:
			- Party is auto-removed after QUEUE_TIMEOUT (20 minutes)
			- When match is detected, party is teleported and removed
			- On MemoryStore failure, party is cleaned up from local cache

		Errors:
			- Rejects if MemoryStore SetAsync fails or times out (10s).
	]]--

	local JoinTime = os.time()
	local Party = {
		Id = game:GetService("HttpService"):GenerateGUID(false),
		Mode = self.Mode.Name,
		RegionCode = self.RegionCode,
		MemberIds = PartyMemberIds,
		Data = PartyData or {},
		QueueTimeStart = JoinTime
	}
	
	local CacheTable = {
		Connections = Maid.new(),
		JoinTime = JoinTime,
		Party = Party,
	}
	
	self.Cache[Party.Id] = CacheTable

	self:Print("Adding a party to the queue")

	-- Adding Player to SortedMap
	CacheTable.AddedToSortedMap = true

	return Promise.try(function()

		return self.SortedMap:SetAsync(Party.Id, Party, PARTY_TIMEOUT, JoinTime)

	end):timeout(10, "AddPartyAsync SetAsync timed out")
	:catch(function(err)

		CacheTable.AddedToSortedMap = false
		self:RemovePartyAsync(Party.Id, true):catch(function()
			-- Ignore cleanup errors
		end)

		return Promise.reject(err)

	end):andThen(function()

		CacheTable.Connections.RefreshConnection = Thread.DelayRepeat(PARTY_REFRESH, function()
			local TimeEllapsed = os.time() - JoinTime

			if TimeEllapsed > QUEUE_TIMEOUT then
				self:RemovePartyAsync(Party.Id):catch(function(err)
					self:Warn("Failed to remove party after timeout: " .. tostring(err))
				end)
			else
				self:CheckIfPartyFoundMatch(Party):andThen(function(MatchId)
					if MatchId then
						return self:TeleportPartyAsync(Party, MatchId)
					end
				end):catch(function(err)
					self:Warn("Failed to check/teleport party: " .. tostring(err))
				end)
			end
		end)

		if not self.Connections.MainServerRefresh then
			task.spawn(function()
				self:DoMatchmaking()
			end)
			self.Connections.MainServerRefresh = Thread.DelayRepeat(COORDINATOR_REFRESH, function()
				self:DoMatchmaking()
			end)
		end

		self.Mode.PartyAdded:Fire(Party)
		CacheTable.InQueue = true
		
		return Party
	end)
end

function RegionalQueue:RemovePartyTable(PartyId, Match)
	--[[
		Immediately removes a party from the local cache (synchronous).

		This is an internal method that handles local cleanup only.
		It does NOT remove the party from MemoryStore.

		Parameters:
			PartyId (string) — The ID of the party to remove.
			Match (table?) — Optional match data to pass to PartyRemoved event.
			                 Nil if party left voluntarily, populated if match found.

		Side Effects:
			1. Destroys all connections for this party (stops polling)
			2. Removes party from local Cache
			3. Fires Mode.PartyRemoved(Party, Match) event
			4. Calls RemoveEmptyQueue() to cleanup if queue is empty

		Notes:
			- Safe to call if party doesn't exist (no-op)
			- Does not throw errors
	]]--

	local CacheTable = self.Cache[PartyId]
	if not CacheTable then
		self:RemoveEmptyQueue()
		return
	end

	CacheTable.Connections:Destroy()

	self.Cache[PartyId] = nil

	self.Mode.PartyRemoved:Fire(CacheTable.Party, Match)

	self:RemoveEmptyQueue()
end

function RegionalQueue:RemovePartyAsync(PartyId, Forced)
	--[[
		Safely removes a party from the queue with proper state handling.

		This method handles the full removal flow:
		1. Validates the party exists and is ready for removal
		2. Marks the party as leaving in MemoryStore
		3. Checks if a match was found in the meantime
		4. If match found: teleports and rejects (cannot cancel)
		5. If no match: removes from local cache

		Parameters:
			PartyId (string) — The ID of the party to remove.
			Forced (boolean?) — If true, skips the "InQueue" check.
			                    Used internally for cleanup on errors.

		Returns:
			Promise<void> — Resolves when party is successfully removed.

		Errors:
			- "The following partyId {id} is not in queue in this server"
			- "Player is still being added to the queue, please try again"
			- "Player has already found a match, cannot cancel now"

		Notes:
			- If a match is found during removal, the party will be teleported
			  and the promise will reject (this is intentional behavior)
	]]--

	local Party
	local CacheTable

	self:Print("Removing a party from the queue")

	return Promise.try(function()

		CacheTable = self.Cache[PartyId]
		assert(CacheTable ~= nil, "The following partyId "..PartyId.." is not in queue in this server")

		Party = CacheTable.Party

		assert(CacheTable.InQueue or Forced, "Player is still being added to the queue, please try again")

	end):andThen(function()

		if Forced then
			self:RemovePartyTable(Party.Id)
		end

		if CacheTable.AddedToSortedMap then
			return self:CheckIfPartyFoundMatch(Party, true)
		end

		return nil

	end):andThen(function(matchId)

		if matchId then
			-- Handle teleport and reject in sequence
			return self:TeleportPartyAsync(Party, matchId):andThen(function()
				return Promise.reject("Player has already found a match, cannot cancel now")
			end):catch(function(err)
				-- Still reject even if teleport fails
				return Promise.reject("Player has already found a match, cannot cancel now")
			end)
		end

		-- No match found, safe to remove
		self:RemovePartyTable(Party.Id)
		return nil

	end):finally(function(Status)
		self:Print("Removing a party from the queue: " .. tostring(Status))
	end)

end

-- Coordinator Management (Distributed Lock)

function RegionalQueue:TryLockServer()
	--[[
		Attempts to acquire or refresh the coordinator lock for this region.

		The matchmaking system uses a distributed lock to ensure only one server
		runs the matchmaking logic at a time. This prevents duplicate matches
		and reduces MemoryStore contention.

		Lock Acquisition Rules:
			1. If no lock exists → acquire it
			2. If we already own the lock → refresh it
			3. If lock exists but owner is inactive → take over
			4. Otherwise → return existing lock (owned by another)

		Returns:
			Promise<table> — The lock data containing:
				- serverId (string): JobId of the lock owner
				- timestamp (number): When the lock was last refreshed
				- Active (boolean): Whether the owner is still active

		Notes:
			- Lock expires after COORDINATOR_TIMEOUT (30 seconds)
			- Lock is stored in RegionLockMap MemoryStore HashMap
			- Called every COORDINATOR_REFRESH (5 seconds) by the coordinator

		Errors:
			- Rejects if MemoryStore UpdateAsync times out (10 seconds).
	]]--

	local lockKey = self.ID
	local myServerId = game.JobId
	local Active = self.Active

	return Promise.try(function()
		return RegionLockMap:UpdateAsync(lockKey, function(oldValue)
			-- No one owns the lock OR lock expired
			if not oldValue and Active then
				return {
					serverId = myServerId,
					timestamp = os.time(),
					Active = Active
				}
			elseif oldValue and oldValue.serverId == myServerId then
				return {
					serverId = myServerId,
					timestamp = os.time(),
					Active = Active
				}
			elseif oldValue and not oldValue.Active and Active then
				return {
					serverId = myServerId,
					timestamp = os.time(),
					Active = Active
				}
			else
				return oldValue
			end
		end, COORDINATOR_TIMEOUT)
	end):timeout(10, "TryLockServer timed out")
end

function RegionalQueue:IsServerMainServer()
	--[[
		Checks if this server is the coordinator and updates local state.

		This is called before each matchmaking cycle to verify this server
		should still be running matchmaking. If another server has taken
		over, this will reject and the matchmaking loop will skip.

		Returns:
			Promise<void> — Resolves if this server is the coordinator.

		Side Effects:
			- Updates self.MainServer to true if we are coordinator
			- Updates self.MainServer to false if we lost coordinator status
			- Logs state changes

		Errors:
			- Rejects with "This server is not the main server" if another
			  server owns the lock
			- Rejects if TryLockServer fails

		Notes:
			- Being the coordinator is not permanent; it must be refreshed
			- If this server crashes, another will take over after timeout
	]]--

	local myServerId = game.JobId

	return self:TryLockServer():andThen(function(acquired)

		assert(acquired and acquired.serverId == myServerId and acquired.Active, "This server is not the main server")

		if not self.MainServer then
			self:Print("This server became the main server")
		end

		self.MainServer = true

	end):catch(function(err)

		if self.MainServer then
			self:Print("This server stopped being the main server")
		end

		self.MainServer = false

		return Promise.reject(err)

	end)
end

function RegionalQueue:CreateMatchAsync(Match)
	--[[
		Atomically assigns a match to multiple parties.

		This is the core match creation logic. It attempts to assign all parties
		to the match in a transactional manner - if any party fails, all
		assignments are rolled back.

		Parameters:
			Match (table) — The match object from your MatchMaking function:
				- Parties (table<Party>): Array of Party objects to match together
				- PlaceId (number): The place to teleport players to
				- AccessCode (string?): Optional pre-reserved server code
				- (any other custom fields you need)

		Returns:
			Promise<void> — Resolves when match is fully created and registered.

		Match Object (after processing):
			The Match object is enriched with:
				- CreatedTime (number): Unix timestamp
				- Mode (string): Matchmaking mode name
				- RegionCode (string): Region code
				- AccessCode (string): Server access code (generated if not provided)
				- PrivateServerId (string): Unique server identifier
				- ServerState (string): "Created"

		Algorithm:
			1. Reserve a private server (if AccessCode not provided)
			2. For each party, atomically set MatchId in MemoryStore
			3. If all succeed → register match in PrivateServer store
			4. If any fail → rollback all assigned parties

		Party Assignment Rules (checked atomically):
			- Party must still exist in MemoryStore
			- Party must not have PartyLeft=true
			- Party must not have a different MatchId

		Errors:
			- "One or more parties could not be assigned to the match"
			- MemoryStore timeout errors
			- PrivateServer registration errors

		Notes:
			- Uses Promise.all for fail-fast behavior
			- Rollback is best-effort (logs failures but doesn't block)
			- Parties detect their MatchId on next poll cycle
	]]--

	local PartiesAssigned = {}

	Match.CreatedTime = os.time()
	Match.Mode = self.Mode.Name
	Match.RegionCode = self.RegionCode
	if not Match.AccessCode then
		local AccessCode, PrivateServerId = PrivateServer:ReserverServer(Match.PlaceId)
		Match.AccessCode = AccessCode
		Match.PrivateServerId = PrivateServerId
	end
	Match.ServerState = "Created"

	local partyPromises = {}

	for _, Party in pairs(Match.Parties) do
		table.insert(partyPromises, Promise.try(function()
			return self.SortedMap:UpdateAsync(Party.Id, function(oldValue, sortKey)

				if not oldValue then
					-- means the party queue data was expired and they left queue
					return nil
				end

				if oldValue.PartyLeft or (oldValue.MatchId and oldValue.MatchId ~= Match.PrivateServerId) then
					-- means the party found another match or left the queue
					return nil
				end

				-- means the party is available for the match
				oldValue.MatchId = Match.PrivateServerId
				sortKey = BIG_QUEUE_TIME
				table.insert(PartiesAssigned, oldValue)

				return oldValue, sortKey

			end, PARTY_TIMEOUT)
		end):timeout(10, "MemoryStore UpdateAsync timed out for party " .. Party.Id))
	end

	-- Use Promise.all for fail-fast behavior - if one fails, rollback all
	return Promise.all(partyPromises):andThen(function(results)

		-- Verify all parties were successfully assigned
		local allSuccessful = true
		for i, success in ipairs(results) do
			if not success then
				allSuccessful = false
				break
			end
		end

		if not allSuccessful then
			return Promise.reject("One or more parties could not be assigned to the match")
		end

		return PrivateServer:RegisterAsync(Match)

	end):catch(function(err)

		-- Rollback: reset all parties that were assigned
		if #PartiesAssigned > 0 then
			local rollbackPromises = {}

			for _, Party in pairs(PartiesAssigned) do
				table.insert(rollbackPromises, Promise.try(function()
					return self.SortedMap:UpdateAsync(Party.Id, function(oldValue, sortKey)

						if not oldValue then
							return nil
						end

						if oldValue.MatchId and oldValue.MatchId == Match.PrivateServerId then
							oldValue.MatchId = nil
						end

						if oldValue.PartyLeft then
							sortKey = BIG_QUEUE_TIME
						else
							sortKey = oldValue.QueueTimeStart
						end

						return oldValue, sortKey

					end, PARTY_TIMEOUT)
				end):timeout(10):catch(function(rollbackErr)
					self:Warn("Rollback failed for party " .. Party.Id .. ": " .. tostring(rollbackErr))
				end))
			end

			-- Wait for rollback to complete before rejecting
			return Promise.allSettled(rollbackPromises):andThen(function()
				return Promise.reject(err)
			end)
		end

		return Promise.reject(err)

	end)

end

function RegionalQueue:CreateMatches(Matches)
	--[[
		Creates multiple matches concurrently with independent failure handling.

		Unlike CreateMatchAsync (which is transactional per match), this method
		processes all matches independently - one match failing doesn't affect others.

		Parameters:
			Matches (table<Match>) — Array of Match objects from your MatchMaking function.
			                         Each must have Parties and PlaceId at minimum.

		Returns:
			Promise<void> — Always resolves (individual failures are logged).

		Behavior:
			- All matches are processed concurrently using Promise.allSettled
			- Each match success/failure is tracked independently
			- Logs a summary: "Created successfully X/Y matches"
			- Failed matches are logged with their error reason

		Notes:
			- This is called by DoMatchmaking after your MatchMaking function returns
			- Uses allSettled so all matches are attempted even if some fail
			- Failed matches don't affect successful ones
	]]--

	local matchPromises = {}

	for _, Match in pairs(Matches) do
		table.insert(matchPromises, self:CreateMatchAsync(Match))
	end

	return Promise.allSettled(matchPromises):andThen(function(results)
		local successCount = 0
		local failureCount = 0

		for _, result in ipairs(results) do
			if result.status == Promise.Status.Resolved then
				successCount += 1
			else
				failureCount += 1
				self:Warn("Match creation failed: " .. tostring(result.reason))
			end
		end

		self:Print(`Created successfully {successCount}/{successCount+failureCount} matches`)
	end)
end

-- Cross-Region Matching

function RegionalQueue:FetchCrossRegionPartiesAsync(fallbackRegions)
	--[[
		Fetches long-waiting parties from fallback regions.

		This enables cross-region matching by allowing coordinators to
		fetch parties from other regions that have been waiting too long.

		Parameters:
			fallbackRegions (table<string>) — Array of region codes to fetch from.
			                                  Order determines priority.

		Returns:
			Promise<table<Party>> — Array of cross-region eligible parties.
			                        Each party has CrossRegion = true flag.

		Eligibility Criteria:
			- Party must be waiting > CROSS_REGION_TIMEOUT (60s)
			- Party must not be matched (no MatchId)
			- Party must not have left (no PartyLeft)

		Notes:
			- Fetches up to CROSS_REGION_MAX_PARTIES per fallback region
			- Errors from individual regions don't fail the whole operation
			- Parties are marked with CrossRegion = true for tracking
	]]--

	local crossRegionParties = {}
	local fetchPromises = {}
	local currentTime = os.time()

	-- Calculate the cutoff time for cross-region eligibility
	local crossRegionCutoff = currentTime - CROSS_REGION_TIMEOUT

	for _, fallbackRegionCode in ipairs(fallbackRegions) do
		local fallbackSortedMap = self:GetSortedMap(self.Mode.Name, fallbackRegionCode)

		local fetchPromise = Promise.try(function()
			-- Only fetch parties that have been waiting longer than CROSS_REGION_TIMEOUT
			-- sortKey = QueueTimeStart, so we want parties with sortKey < crossRegionCutoff
			return fallbackSortedMap:GetRangeAsync(
				Enum.SortDirection.Ascending,
				CROSS_REGION_MAX_PARTIES,
				nil,
				{ sortKey = crossRegionCutoff }
			)
		end):timeout(10, "Cross-region fetch timed out for " .. fallbackRegionCode)
		:andThen(function(items)
			local parties = {}

			for _, item in ipairs(items) do
				local Party = item.value

				-- Skip if already matched or left
				if Party.MatchId or Party.PartyLeft then
					continue
				end

				-- Mark as cross-region for tracking/debugging
				Party.CrossRegion = true
				Party.OriginalRegion = Party.RegionCode

				table.insert(parties, Party)
			end

			return parties
		end):catch(function(err)
			self:Warn("Failed to fetch from fallback region " .. fallbackRegionCode .. ": " .. tostring(err))
			return {} -- Return empty array on error, don't fail the whole operation
		end)

		table.insert(fetchPromises, fetchPromise)
	end

	-- Wait for all fallback fetches to complete
	return Promise.all(fetchPromises):andThen(function(results)
		for _, parties in ipairs(results) do
			for _, party in ipairs(parties) do
				table.insert(crossRegionParties, party)
			end
		end

		if #crossRegionParties > 0 then
			self:Print(`Fetched {#crossRegionParties} cross-region parties from {#fallbackRegions} fallback regions`)
		end

		return crossRegionParties
	end)
end

function RegionalQueue:DoMatchmaking()
	--[[
		Main matchmaking loop - fetches parties and creates matches.

		This is called every COORDINATOR_REFRESH seconds (5s) by the coordinator.
		Only the server that owns the coordinator lock will actually run matchmaking.

		Returns:
			Promise<void> — Resolves when cycle completes (or rejects on error).

		Algorithm:
			1. Verify this server is still the coordinator (IsServerMainServer)
			2. Fetch eligible parties from this region's MemoryStore
			3. Fetch cross-region eligible parties from fallback regions
			4. Combine all parties and call your MatchMaking function
			5. Create matches from the returned Match objects

		Party Fetching:
			- Fetches up to MATCHMAKING_TOTALCOUNT (200) parties from this region
			- Also fetches long-waiting parties from fallback regions
			- Cross-region parties must be waiting > CROSS_REGION_TIMEOUT (60s)

		Your MatchMaking Function:
			Receives: Parties (table<Party>) — Array of eligible parties
			          Parties may include CrossRegion = true flag for cross-region parties
			Returns: Matches (table<Match>) — Array of match objects, each with:
				- Parties (table<Party>): The parties to group together
				- PlaceId (number): Destination place ID
				- (any other custom data you need)

		Error Handling:
			- If not coordinator → silently skips (expected behavior)
			- MemoryStore errors → logged as warning
			- MatchMaking function errors → logged as warning
			- Cross-region fetch errors → logged, doesn't fail the cycle

		Notes:
			- Non-coordinator servers call this but exit early
			- Errors don't stop the loop; it will retry next cycle
			- Cross-region parties can be matched with local parties
	]]--

	local maxItems = MATCHMAKING_TOTALCOUNT
	local batchSize = MATCHMAKING_SUBCOUNT

	return self:IsServerMainServer():andThen(function()

		-- Fetching local parties using recursive Promise-based approach
		local Parties = {}
		local totalFetched = 0

		local exclusiveUpperBound = {
			sortKey = os.time() + COORDINATOR_REFRESH
		}

		self:Print("Retrieving parties from " .. self.RegionCode)

		local function fetchBatch(exclusiveLowerBound)
			return Promise.try(function()
				return self.SortedMap:GetRangeAsync(Enum.SortDirection.Ascending, batchSize, exclusiveLowerBound, exclusiveUpperBound)
			end):timeout(10, "GetRangeAsync timed out"):andThen(function(items)

				for _, item in ipairs(items) do
					totalFetched += 1

					local Party = item.value

					if Party.MatchId or Party.PartyLeft then
						break
					end

					table.insert(Parties, Party)

					if totalFetched >= maxItems then
						break
					end
				end

				-- Continue fetching if needed
				if #items >= batchSize and totalFetched < maxItems then
					local newLowerBound = {
						key = items[#items].key,
						sortKey = items[#items].sortKey
					}
					return fetchBatch(newLowerBound)
				end

				return Parties
			end)
		end

		return fetchBatch(nil):andThen(function(localParties)
			-- Now fetch cross-region parties from fallback regions
			local fallbackRegions = self.Mode.RegionCodes.RegionFallbacks[self.RegionCode]

			if not fallbackRegions or #fallbackRegions == 0 then
				return localParties
			end

			return self:FetchCrossRegionPartiesAsync(fallbackRegions):andThen(function(crossRegionParties)
				-- Combine local and cross-region parties
				for _, party in ipairs(crossRegionParties) do
					table.insert(localParties, party)
				end

				return localParties
			end)
		end)

	end):andThen(function(Parties)

		self:Print(`Retrieved {#Parties} parties`)

		return self.Mode.MatchMaking(Parties)

	end):andThen(function(Matches)

		if not Matches or #Matches == 0 then
			self:Print(`No match to create`)
			return nil
		end

		self:Print(`Creating {#Matches} matches`)

		return self:CreateMatches(Matches)

	end):catch(function(err)
		self:Warn(tostring(err))
	end)

end

-- Logging Utilities

function RegionalQueue:Print(Txt)
	--[[
		Logs an informational message with queue context.

		Parameters:
			Txt (string) — The message to log.

		Output Format:
			[MatchMakerService-{Mode}-{Region}] {message}

		Example:
			[MatchMakerService-Ranked1v1-NA] Retrieved 15 parties
	]]--

	print(`[MatchMakerService-{self.ID}] {Txt}`)
end

function RegionalQueue:Warn(Txt)
	--[[
		Logs a warning message with queue context.

		Parameters:
			Txt (string) — The warning message to log.

		Output Format:
			[MatchMakerService-{Mode}-{Region}] {message}

		Notes:
			- Used for non-fatal errors that don't interrupt operation
			- Errors are logged here rather than thrown to keep loops running
	]]--

	warn(`[MatchMakerService-{self.ID}] {Txt}`)
end

-- Cleanup

function RegionalQueue:RemoveEmptyQueue()
	--[[
		Auto-destroys the queue when no parties remain.

		Called automatically after each party removal.
		Keeps resource usage minimal by cleaning up inactive queues.

		Behavior:
			- If Cache is empty → calls Destroy()
			- If Cache has parties → no-op
	]]--

	if not next(self.Cache) then
		self:Destroy()
	end
end

function RegionalQueue:Destroy()
	--[[
		Cleans up and destroys this regional queue instance.

		This method:
			1. Marks the queue as inactive (prevents new operations)
			2. Destroys all connections (stops polling and matchmaking loops)
			3. Releases coordinator lock if this server was coordinator
			4. Unregisters from parent MatchMakerService

		Side Effects:
			- Sets self.Active = false
			- Destroys self.Connections (Maid)
			- Updates coordinator lock to show inactive status
			- Removes self from Mode.RegionalQueues

		Notes:
			- Safe to call multiple times (idempotent)
			- Called automatically when queue becomes empty
			- Called by MatchMakerService:Destroy() on shutdown
	]]--

	if not self.Active then return end

	self.Active = false

	self.Connections:Destroy()

	if self.MainServer then
		self:TryLockServer()
	end

	self:Print("Regional queue has been destroyed")
	self.Mode.RegionalQueues[self.RegionCode] = nil
end

return RegionalQueue
