--[[
	MatchMakerService

	A distributed matchmaking service with regional queue support.
	Manages player queues across different regions and handles match creation.

	Dependencies:
		- Promise (ReplicatedStorage.Utils.Promise)
		- Signal (ReplicatedStorage.Utils.Signal)
		- Maid (ReplicatedStorage.Utils.Maid)
		- Thread (ReplicatedStorage.Utils.Thread)

	Usage Example:
		local MatchMaker = require(path.to.MatchMaker)

		local MM = MatchMaker.new({
			Name = "Ranked1v1",
			MatchMaking = function(Parties)
				-- Custom matchmaking logic
				-- Return a table of Match objects
				return Matches
			end
		})

		-- Add a party to the queue
		MM:AddPartyAsync({123456789}, {rank = 1500, level = 50}):andThen(function(party)
			print("Party added to queue:", party.Id)
		end):catch(function(err)
			warn("Failed to add party:", err)
		end)

		-- Remove a party from the queue
		MM:RemovePartyAsync(partyId):andThen(function()
			print("Party removed")
		end):catch(function(err)
			warn("Failed to remove:", err)
		end)

	Events:
		PartyAdded(Party: table)
			Fired when a party successfully joins the matchmaking queue.
			Party contains: Id, Mode, RegionCode, MemberIds, Data, QueueTimeStart

		PartyRemoved(Party: table, Match: table?)
			Fired when a party leaves the queue, either by cancellation or match found.
			Match is nil if the party was manually removed.
]]--

local MatchMakerService = {}
MatchMakerService.__index = MatchMakerService

-- Variables

local PlayerService = game:GetService("Players")
local MessagingService = game:GetService("MessagingService")
local LocalizationService = game:GetService("LocalizationService")

local PrivateServer = require(script.Parent:WaitForChild("PrivateServer"))

local Utils = game.ReplicatedStorage:WaitForChild("Utils")
local Signal = require(Utils:WaitForChild("Signal"))
local Thread = require(Utils:WaitForChild("Thread"))
local Promise = require(Utils:WaitForChild("Promise"))
local Maid = require(Utils:WaitForChild("Maid"))

local MatchMakers = {}

MatchMakerService.RegionalQueue = require(script:WaitForChild("RegionalQueue"))
MatchMakerService.RegionCodes = require(script:WaitForChild("RegionCodes"))


-- Methods

function MatchMakerService.new(Params)
	--[[
		Creates a new matchmaker instance or returns an existing one for the specified name.

		Parameters:
			Params.Name (string) — The name of the matchmaking mode.
			Params.MatchMaking (function) — The function used to perform the matchmaking logic.

		Returns:
			A new or cached MatchMakerService instance.
	]]--
	
	if MatchMakers[Params.Name] then
		return MatchMakers[Params.Name]
	end

	-- New Obj
	local self = setmetatable(Params, MatchMakerService)
	self.Active = true
	self.Maid = Maid.new()
	
	-- Events
	self.PartyAdded = self.Maid:GiveTask(Signal.new())
	self.PartyRemoved = self.Maid:GiveTask(Signal.new())

	-- Cache
	self.RegionalQueues = {}
	MatchMakers[self.Name] = self
	
	-- Done
	print(`[{self.Name}]: New matchmaker has been created`)
	
	return self
end

function MatchMakerService:GetMatchMaker(Mode)
	--[[
		Retrieves a cached matchmaker instance by name.

		Parameters:
			Mode (string) — The name of the matchmaking mode.

		Returns:
			A matchmaker instance if it exists; otherwise nil.
	]]--
	
	return MatchMakers[Mode]
end

function MatchMakerService:GetRegionalQueue(regionCode)
	--[[
		Returns an existing queue or creates a new one for the specified region.

		Parameters:
			regionCode (string) — A short code (e.g., "NA", "EUW") representing the region.
			                      See RegionCodes module for available regions.

		Returns:
			RegionalQueue — The regional queue instance for the given region.
	]]--

	local existingQueue = self.RegionalQueues[regionCode]

	if existingQueue then
		return existingQueue
	end

	local newQueue = self.RegionalQueue.new({
		RegionCode = regionCode,
		Mode = self,
	})

	self.RegionalQueues[regionCode] = newQueue

	return newQueue
end

function MatchMakerService:AddPartyAsync(PartyMemberIds, PartyData, RegionCode)
	--[[
		Adds a party to the matchmaking queue.

		If no RegionCode is provided, it will be automatically detected based on
		the first online player in the party using LocalizationService.

		Parameters:
			PartyMemberIds (table<number>) — Array of UserIds representing the party members.
			PartyData (table?) — Optional metadata for the party (e.g., {rank = 1500, mode = "solo"}).
			                     This data is passed to your MatchMaking function.
			RegionCode (string?) — Optional region code. If nil, auto-detected from player location.

		Returns:
			Promise<Party> — Resolves with the Party object containing:
				- Id (string): Unique party identifier
				- Mode (string): The matchmaking mode name
				- RegionCode (string): The assigned region
				- MemberIds (table<number>): The party member UserIds
				- Data (table): The provided PartyData
				- QueueTimeStart (number): Unix timestamp when party joined queue

		Errors:
			Rejects if the party cannot be added to the MemoryStore queue.

		Example:
			matchmaker:AddPartyAsync({player.UserId}, {rank = 1500}):andThen(function(party)
				print("Joined queue:", party.Id)
			end)
	]]--

	if not RegionCode then
		local Player

		for _, PartyMemberId in pairs(PartyMemberIds) do
			Player = PlayerService:GetPlayerByUserId(PartyMemberId)
			if Player then break end
		end

		if Player then
			local Success, result = pcall(function()
				return LocalizationService:GetCountryRegionForPlayerAsync(Player)
			end)
			RegionCode = self.RegionCodes.CountryCodes[result or "DEFAULT"]
		end
	end

	if not RegionCode then
		RegionCode = self.RegionCodes.CountryCodes.DEFAULT
	end

	local RegionalQueue = self:GetRegionalQueue(RegionCode)

	return RegionalQueue:AddPartyAsync(PartyMemberIds, PartyData)
end

function MatchMakerService:RemovePartyAsync(PartyId, Forced)
	--[[
		Removes a party from the matchmaking queue.

		If the party has already been matched, the removal will be rejected
		and the party will be teleported to their match instead.

		Parameters:
			PartyId (string) — The unique identifier of the party to remove.
			Forced (boolean?) — If true, removes the party even if still being added to queue.
			                    Use with caution, mainly for cleanup purposes.

		Returns:
			Promise<void> — Resolves when the party has been successfully removed.

		Errors:
			- "Party is not in queue" — The party ID was not found in any regional queue.
			- "Player has already found a match, cannot cancel now" — A match was found before removal.
			- "Player is still being added to the queue, please try again" — Party not fully queued yet.

		Example:
			matchmaker:RemovePartyAsync(partyId):andThen(function()
				print("Successfully left queue")
			end):catch(function(err)
				if tostring(err):find("already found a match") then
					print("Too late! Match found, teleporting...")
				end
			end)
	]]--

	local Party = self:GetParty(PartyId)

	if not Party then
		return Promise.reject("Party is not in queue")
	end

	local RegionalQueue = self:GetRegionalQueue(Party.RegionCode)

	return RegionalQueue:RemovePartyAsync(Party.Id, Forced)
end

function MatchMakerService:GetParty(PartyId)
	--[[
		Searches through all regional queues to retrieve a party by its ID.

		Parameters:
			PartyId (string) — The unique ID of the party.

		Returns:
			Party (table) — The party object if found; otherwise nil.
	]]--
	
	for i, RegionalQueue in pairs(self.RegionalQueues) do
		for Id, CacheTable in pairs(RegionalQueue.Cache) do
			if Id == PartyId then
				return CacheTable.Party
			end
		end
	end
end

function MatchMakerService:GetPartyMatchAsync(PartyId, Mode, RegionCode)
	--[[
		Checks whether a match has been found for the party and retrieves the private server data.

		This is useful for polling match status from a different server context,
		or for retrieving match details after receiving a match notification.

		Parameters:
			PartyId (string) — The unique ID of the party.
			Mode (string) — The matchmaking mode name.
			RegionCode (string) — The region code where the party is queued.

		Returns:
			Promise<PrivateServerData | nil> — Resolves with the match data containing:
				- PrivateServerId (string): The private server identifier
				- AccessCode (string): Code to join the server
				- PlaceId (number): The place to teleport to
				- Parties (table): All parties in the match
				- CreatedTime (number): When the match was created
			Returns nil if no match has been found yet.

		Example:
			matchmaker:GetPartyMatchAsync(partyId, "Ranked1v1", "NA"):andThen(function(matchData)
				if matchData then
					TeleportService:TeleportToPrivateServer(matchData.PlaceId, matchData.AccessCode, players)
				end
			end)
	]]--

	return Promise.try(function()
		return self.RegionalQueue:GetSortedMap(Mode, RegionCode):GetAsync(PartyId)
	end):andThen(function(result)
		if not result or not result.MatchId then
			return Promise.resolve(nil)
		end

		return PrivateServer:GetPrivateServerDataAsync(result.MatchId)
	end)
end

function MatchMakerService:Destroy()
	--[[
		Cleans up and destroys the matchmaker instance.

		This method:
		- Destroys all regional queues (releases coordinator locks)
		- Disconnects all event connections
		- Cleans up the Maid instance

		Note: This is automatically called on game:BindToClose for all matchmakers.
		      You typically don't need to call this manually unless you want to
		      stop matchmaking for a specific mode during runtime.

		Safe to call multiple times (idempotent).
	]]--

	if not self.Active then return end

	self.Active = false

	for _, RegionalQueue in pairs(self.RegionalQueues) do
		RegionalQueue:Destroy()
	end

	self.Maid:Destroy()
end

game:BindToClose(function()
	for i, MatchMaker in pairs(MatchMakers) do
		task.spawn(function()
			MatchMaker:Destroy()
		end)
	end
end)

return MatchMakerService