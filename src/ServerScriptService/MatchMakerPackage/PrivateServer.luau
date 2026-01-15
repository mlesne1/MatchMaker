--[[
	PrivateServer

	Manages private server data storage for the matchmaking system.
	Handles server reservation, registration, updates, and lifecycle tracking.

	This module stores match/server data in MemoryStore so that:
		- Parties can retrieve their match details after being assigned
		- Game servers can access match configuration on startup
		- Match state can be tracked across the distributed system

	Data Flow:
		1. CreateMatchAsync reserves a server → ReserveServer()
		2. Match is created → RegisterAsync() stores match data
		3. Parties poll and find MatchId → GetPrivateServerDataAsync() retrieves data
		4. Game server starts → can call GetPrivateServerDataAsync() for config
		5. Match ends → CloseAsync() marks server as closed

	PrivateServerData Structure:
		After RegisterAsync(), the data contains:
			- PrivateServerId (string): Unique server identifier (from ReserveServer)
			- AccessCode (string): Code to teleport players to the server
			- PlaceId (number): The destination place ID
			- Parties (table<Party>): All parties in the match
			- CreatedTime (number): Unix timestamp when match was created
			- Mode (string): Matchmaking mode name
			- RegionCode (string): Region code
			- State (string): "Registered" | "Closed"
			- ServerState (string): "Created" (set by CreateMatchAsync)
			- (any custom fields from your Match object)

	Configuration:
		MATCH_RETENTION_TIME (86400s / 24h)
			How long match data persists in MemoryStore.
			Should be longer than any expected match duration.

	Usage Example:
		-- From a game server, retrieve match data on startup
		local PrivateServer = require(path.to.PrivateServer)
		local privateServerId = game.PrivateServerId

		PrivateServer:GetPrivateServerDataAsync(privateServerId):andThen(function(matchData)
			if matchData then
				print("Match mode:", matchData.Mode)
				print("Players expected:", #matchData.Parties)
			end
		end)

		-- When match ends
		PrivateServer:CloseAsync(matchData):andThen(function()
			print("Match closed")
		end)
]]--

local PrivateServer = {}
PrivateServer.__index = PrivateServer

-- Services

local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")

-- Dependencies

local Utils = game.ReplicatedStorage:WaitForChild("Utils")
local Signal = require(Utils:WaitForChild("Signal"))
local Thread = require(Utils:WaitForChild("Thread"))
local Promise = require(Utils:WaitForChild("Promise"))

-- Configuration

local MATCH_RETENTION_TIME = 60 * 60 * 24  -- 24 hours: MemoryStore expiration

-- Internal

local function GetHashMap()
	--[[
		Returns the MemoryStore HashMap for private server data.
		All match data is stored in a single HashMap keyed by PrivateServerId.
	]]--
	return MemoryStoreService:GetHashMap("PrivateServers")
end


-- Server Reservation

function PrivateServer:ReserverServer(PlaceId)
	--[[
		Reserves a new private server instance for a given place.

		This is a synchronous wrapper around TeleportService:ReserveServer().
		Called by CreateMatchAsync when no AccessCode is provided.

		Parameters:
			PlaceId (number) — The ID of the place to reserve a server for.

		Returns:
			AccessCode (string) — Code used to teleport players to the server.
			                      Pass to TeleportService:TeleportToPrivateServer().
			PrivateServerId (string) — Unique identifier for the reserved server.
			                           Used as the key for storing match data.

		Studio Behavior:
			Returns dummy values ("AccessCode", "PrivateServerId") when running
			in Studio since TeleportService doesn't work in test mode.

		Example:
			local accessCode, privateServerId = PrivateServer:ReserverServer(1234567890)
			-- Later: TeleportService:TeleportToPrivateServer(placeId, accessCode, players)

		Notes:
			- This does NOT store any data; call RegisterAsync() after creating the match
			- The reserved server remains available until it's used or times out
			- Roblox handles server cleanup automatically
	]]--

	if RunService:IsStudio() then
		return "AccessCode", "PrivateServerId"
	else
		return TeleportService:ReserveServer(PlaceId)
	end
end

-- Data Retrieval

function PrivateServer:GetPrivateServerDataAsync(PrivateServerId)
	--[[
		Fetches saved private server/match data from MemoryStore.

		This is used by:
			- Parties polling for their match assignment (via TeleportPartyAsync)
			- Game servers retrieving match configuration on startup
			- Any code that needs to look up match details

		Parameters:
			PrivateServerId (string) — The unique server ID (from ReserveServer).

		Returns:
			Promise<PrivateServerData | nil> — Resolves with:
				- The full match data object if found (see module header for structure)
				- nil if no match exists with that ID (expired or never created)

		Errors:
			- Rejects if MemoryStore GetAsync times out (10 seconds)
			- Rejects on MemoryStore service errors

		Example:
			-- On game server startup
			PrivateServer:GetPrivateServerDataAsync(game.PrivateServerId)
				:andThen(function(matchData)
					if matchData then
						setupMatch(matchData.Parties, matchData.Mode)
					else
						warn("No match data found - server may have been accessed directly")
					end
				end)
				:catch(function(err)
					warn("Failed to fetch match data:", err)
				end)
	]]--

	local HashMap = GetHashMap()

	print(`[PrivateServer]: Fetching Private Server Data (`, PrivateServerId, ")")

	return Promise.try(function()
		return HashMap:GetAsync(PrivateServerId)
	end):timeout(10, "GetPrivateServerDataAsync timed out for " .. tostring(PrivateServerId))
end

-- Data Registration & Updates

function PrivateServer:RegisterAsync(PrivateServerData)
	--[[
		Stores match data in MemoryStore after a match is created.

		Called by CreateMatchAsync after all parties have been successfully
		assigned to the match. This makes the match data available for
		parties to retrieve when they poll for their MatchId.

		Parameters:
			PrivateServerData (table) — The match data object. Must contain:
				- PrivateServerId (string): The key for storage
				- (all other match fields from CreateMatchAsync)

		Returns:
			Promise<void> — Resolves when data is successfully stored.

		Side Effects:
			- Sets PrivateServerData.State = "Registered"
			- Stores data in MemoryStore with 24-hour expiration

		Retry Behavior:
			- Retries up to 5 times on failure
			- 2 second delay between retries
			- Uses Promise.retryWithDelay for resilience

		Errors:
			- Rejects after 5 failed attempts
			- Each attempt can fail due to MemoryStore service errors

		Notes:
			- Data expires after MATCH_RETENTION_TIME (24 hours)
			- Use UpdateAsync() to modify data after registration
			- Use CloseAsync() to mark the match as ended
	]]--

	local HashMap = GetHashMap()

	print(`[PrivateServer]: Registering Private Server (`, PrivateServerData, ")")
	PrivateServerData.State = "Registered"

	return Promise.retryWithDelay(function()
		return Promise.try(function()
			return HashMap:SetAsync(PrivateServerData.PrivateServerId, PrivateServerData, MATCH_RETENTION_TIME)
		end)
	end, 5, 2)
end

function PrivateServer:UpdateAsync(PrivateServerData)
	--[[
		Updates existing match data in MemoryStore.

		Use this to modify match state during gameplay, such as:
			- Updating player counts as players join/leave
			- Storing match progress or scores
			- Adding custom state information

		Parameters:
			PrivateServerData (table) — Object with fields to update.
				- PrivateServerId (string): Required - identifies which match to update
				- (any other fields): Will be merged into existing data

		Returns:
			Promise<void> — Resolves when update is complete.

		Behavior:
			- Merges new fields into existing data (shallow merge)
			- If entry doesn't exist, creates it with the provided data
			- Refreshes the expiration timer

		Errors:
			- Rejects if MemoryStore UpdateAsync times out (10 seconds)
			- Rejects on MemoryStore service errors

		Example:
			-- Update player count during match
			matchData.PlayerCount = #Players:GetPlayers()
			matchData.LastUpdated = os.time()

			PrivateServer:UpdateAsync(matchData):catch(function(err)
				warn("Failed to update match data:", err)
			end)

		Notes:
			- Does NOT retry on failure (unlike RegisterAsync/CloseAsync)
			- For critical updates, consider wrapping in your own retry logic
	]]--

	local HashMap = GetHashMap()

	print(`[PrivateServer]: Updating Private Server Data (`, PrivateServerData, ")")

	return Promise.try(function()
		return HashMap:UpdateAsync(PrivateServerData.PrivateServerId, function(oldValue)
			if oldValue then
				for i, v in pairs(PrivateServerData) do
					oldValue[i] = v
				end

				return oldValue
			else
				return PrivateServerData
			end
		end, MATCH_RETENTION_TIME)
	end):timeout(10, "UpdateAsync timed out for " .. tostring(PrivateServerData.PrivateServerId))
end

-- Lifecycle Management

function PrivateServer:CloseAsync(PrivateServerData)
	--[[
		Marks a match as closed in MemoryStore.

		Call this when a match ends to update the server state.
		This allows other systems to know the match has concluded.

		Parameters:
			PrivateServerData (table) — The match data object.
				- PrivateServerId (string): Required - identifies the match

		Returns:
			Promise<void> — Resolves when the close is recorded.

		Side Effects:
			- Sets PrivateServerData.State = "Closed"
			- Updates the MemoryStore entry

		Retry Behavior:
			- Retries up to 5 times on failure
			- 2 second delay between retries
			- Important for ensuring match closure is recorded

		Example:
			-- When match ends (e.g., in game server)
			game:BindToClose(function()
				PrivateServer:CloseAsync(matchData):await()
			end)

			-- Or after match completion
			PrivateServer:CloseAsync(matchData):andThen(function()
				print("Match officially closed")
			end)

		Notes:
			- Data still persists until MATCH_RETENTION_TIME expires
			- Closed matches can still be read via GetPrivateServerDataAsync
			- The State field can be checked to determine if match is active
	]]--

	local HashMap = GetHashMap()

	PrivateServerData.State = "Closed"
	print(`[PrivateServer]: Closing Private Server (`, PrivateServerData, ")")

	return Promise.retryWithDelay(function()
		return Promise.try(function()
			return HashMap:UpdateAsync(PrivateServerData.PrivateServerId, function(oldValue)
				if oldValue then
					for i, v in pairs(PrivateServerData) do
						oldValue[i] = v
					end

					return oldValue
				else
					return PrivateServerData
				end
			end, MATCH_RETENTION_TIME)
		end)
	end, 5, 2)
end

return PrivateServer
