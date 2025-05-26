#
# MatchMaker

The `MatchMaker` is the main entry point for defining matchmaking modes and accessing regional queues. This module allows you to register matchmaking logic, get access to queues, check match status, and manage party data.

---

## `.new`

**Description**:  
Creates or retrieves a matchmaking mode with a unique name.

**Parameters**:
- `Params` *(table)*:  
  - `Name` *(string)* – Unique name of the matchmaking mode (e.g., `"Solo"`, `"Duo"`).  
  - `MatchMaking` *(function)* – A function that takes a list of parties looking for a match and should return a list of matches to create. Each match should include the **list of Parties** in that match and **the PlaceId**. The rest will be added afterwards.

**Returns**: `MatchMaker` object for that mode.

**Example**:
```lua
local DuoMatchMaker = MatchMaker.new({
  Name = "Duo",
  MatchMaking = function(parties)
    -- your logic here
    return matches
  end
})
```

> A party is a table containing the following fields, which is created when you add players in a queue:
> - `Party.Id`: A unique string (GUID) that identifies the party.
> - `Party.Mode`: The name of the matchmaking mode the party is queued under (e.g., `"Solo"`, `"Duo"`).
> - `Party.RegionCode`: The region this party was assigned to (e.g., `"NA"`, `"EU"`).
> - `Party.MemberIds`: An array of user IDs representing the players in the party.
> - `Party.Data`: An optional table of custom metadata passed when the party was added — such as rank, preferred settings, or role.
> - `Party.QueueTimeStart`: The Unix timestamp indicating when the party was added to the queue.
> - `Party.MatchId`: The private server ID of the match assigned to this party (if any). Will be `nil` if the party hasn't been matched yet.

> A match is a table containing the following fields, which is created when you group parties into a match:
> - `Match.AccessCode`: The private server access code used for teleportation.
> - `Match.PrivateServerId`: The reserved server ID for the match.
> - `Match.PlaceId`: The game place where the match is hosted.
> - `Match.RegionCode`: The region the match was created in (e.g., `"NA"`, `"EU"`).
> - `Match.Mode`: The matchmaking mode that created the match (e.g., `"Solo"` or `"Duo"`).
> - `Match.Parties`: An array of party objects that were assigned to this match.
> - `Match.CreatedTime`: Unix timestamp when the match was created.
> - `Match.State`: A string representing the current state of the match. Common values:
>   - `"Registered"` – Match is queued and ready.
>   - `"InProgress"` – Match is actively running.
>   - `"Closed"` – Match is complete or terminated.

---

## `:GetMatchMaker`

**Description**:  
Returns a previously created matchmaking mode by name.

**Parameters**:
- `modeName` *(string)* – Name of the matchmaking mode.

**Returns**: `MatchMaker` object or `nil` if not found.

**Example**:
```lua
local DuoMatchMaker = MatchMaker:GetMatchMaker("Duo")
```

---

## `:GetRegionalQueue`

**Description**:  
Returns (or creates) a regional queue for the given region code.

**Parameters**:
- `regionCode` *(string)* – A key like `"NA"`, `"EU"`, ...

**Returns**: `RegionalQueue` object

**Example**:
```lua
local RegionalQueue = DuoMatchMaker:GetRegionalQueue("NA")
```

---

## `:GetParty`

**Description**:  
Searches all regional queues in this mode to find a party **currently in queue** by its ID.

**Parameters**:
- `partyId` *(string)* – The unique party identifier.

**Returns**: `Party` *(table)* or `nil`

**Example**:
```lua
local Party = MatchMaker:GetParty("PARTY_GUID")
```

---

## `:GetPartyMatchAsync`

**Description**:  
Checks whether a party has been matched by looking up its info in the regional queue’s SortedMap. The party doesn't have to be in queue to check this.

**Parameters**:
- `partyId` *(string)* – The party’s unique ID.  
- `mode` *(string)* – The mode name (e.g., `"Solo"`).  
- `regionCode` *(string)* – Region key (e.g., `"NA"`).

**Returns**: `Promise<Match | nil>`

**Example**:
```lua
local Success, Match = MatchMaker:GetPartyMatchAsync(partyId, "Solo", "NA")

if match then
    TeleportService:TeleportToPrivateServer(match.PlaceId, match.AccessCode, players)
end
```

---

## `:AddPartyAsync`

**Description**  
Adds a party to the matchmaking system under the current mode. If no `RegionCode` is provided, it automatically tries to detect the region using `LocalizationService` from the first online party member.

**Parameters**  
- `PartyMemberIds` *(array<number>)* – List of player `UserId`s to add to the party.  
- `PartyData` *(table, optional)* – Custom data you want to associate with the party (e.g., rank, preferences).  
- `RegionCode` *(string, optional)* – Optional override for the region code (e.g., `"NA"`, `"EU"`). If `nil`, it falls back to the player’s detected region or `"DEFAULT"`.

**Returns**  
- `Promise<void>` – Resolves when the party is successfully added to the regional queue.

**Example**  
```lua
local MatchMaker = MatchMakerService:Get("Duo")

local Success, Party = MatchMaker:AddPartyAsync(
  {Player1.UserId, Player2.UserId},
  {Rank = "Gold"}
)

if success then
  print("Party "..Party.Id.." successfully queued!")
else
  warn("Failed to queue party:", Party)
end
```

---

## `:RemovePartyAsync`

**Description**  
Removes a party from the queue. If the party has already been matched, and `Forced` is not set, the removal is rejected. If `Forced` is true, it proceeds with removal but still checks if the party had a match to ensure proper handoff.

**Parameters**  
- `PartyId` *(string)* – The unique party ID to remove.  
- `Forced` *(boolean, optional)* – If `true`, bypasses queue validation and forcibly removes the party (eg: when a player leaves game).

**Returns**  
- `Promise<void>` – Resolves if the party was removed or rejected if not found or already matched.

**Example**  
```lua
local MatchMaker = MatchMakerService:Get("Solo")

local success, err = MatchMaker:RemovePartyAsync(partyId, true)

if success then
  print("Party successfully removed.")
else
  warn("Error removing party:", err)
end
```

---
## `:Destroy`

**Description**:  
Cleans up all regional queues and connections associated with this matchmaker instance.

**Parameters**: None  
**Returns**: None

**Example**:
```lua
matchMaker:Destroy()
```

---

Each `MatchMaker` object includes two signals:

## `.PartyAdded`
Fires when a party is added to any queue in this mode.

**Example**:
```lua
matchMaker.PartyAdded:Connect(function(party)
  print("Party joined:", party.Id)
end)
```

---

## `.PartyRemoved`
Fires when a party leaves the queue, optionally with a match if it was successfully created.
> Any party that leaves the queue will fire this event, even if there isn't any player of that party left in the game

**Example**:
```lua
matchMaker.PartyRemoved:Connect(function(party, match)
  print("Party left:", party.Id)
end)
```


---

# PrivateServer

The `PrivateServer` module handles **reserving**, **registering**, **updating**, and **closing** private Roblox servers. It wraps `TeleportService` and `MemoryStoreService` to make match data accessible across all servers in a session.

---

## `:ReserverServer`

**Description**:  
Reserves a private server instance for a given place. In Studio, returns mock data for local testing.

**Parameters**:
- `placeId` *(number)* – The place ID where the match will occur.

**Returns**:  
- `accessCode` *(string)* – Used to teleport players.
- `privateServerId` *(string)* – Unique server identifier.

**Example**:
```lua
local accessCode, serverId = PrivateServer:ReserverServer(game.PlaceId)
print("Reserved server:", accessCode, serverId)
```

---

## `:RegisterAsync`

**Description**:  
Registers the server's match data into `MemoryStore`, making it accessible to all servers.

**Parameters**:
- `serverData` *(table)* – Data representing the match:
  - `PrivateServerId` *(string)*
  - `AccessCode` *(string)*
  - `PlaceId` *(number)*
  - `Parties` *(array)* – List of party tables
  - `State` *(string)* – Defaults to `"Registered"`

**Returns**: `Promise<void>`

**Example**:
```lua
PrivateServer:RegisterAsync({
  PrivateServerId = serverId,
  AccessCode = accessCode,
  PlaceId = game.PlaceId,
  Parties = {partyA, partyB},
})
```

---

## `:GetPrivateServerDataAsync`

**Description**:  
Retrieves a previously registered private server's match data using its ID.

**Parameters**:
- `serverId` *(string)* – The unique identifier of the private server.

**Returns**: `Promise<table>` – The match data object.

**Example**:
```lua
PrivateServer:GetPrivateServerDataAsync(serverId)
  :andThen(function(data)
    print("Match data:", data.PlaceId, data.State)
  end)
  :catch(function(err)
    warn("Failed to fetch match:", err)
  end)
```

---

## `:UpdateAsync`

**Description**:  
Merges new data into the existing private server data. Uses `UpdateAsync` to prevent overwriting.

**Parameters**:
- `serverData` *(table)* – Fields to merge with existing match data.

**Returns**: `Promise<void>`

**Example**:
```lua
PrivateServer:UpdateAsync({
  PrivateServerId = serverId,
  State = "InProgress",
})
```

---

## `:CloseAsync`

**Description**:  
Marks a private server as `"Closed"` in `MemoryStore`. This is useful when the match ends or the server is shutting down.

**Parameters**:
- `serverData` *(table)* – Must include `PrivateServerId`.

**Returns**: `Promise<void>`

**Example**:
```lua
PrivateServer:CloseAsync({
  PrivateServerId = serverId,
  State = "Closed",
})
```



# RegionalQueue (Internal)

The `RegionalQueue` module manages a matchmaking queue for a specific region and mode (e.g., `"EU-Solo"`, `"NA-Duo"`). It handles party entry, timeout logic, coordinator election, matchmaking cycles, and match creation.

> This module is typically not used directly outside of `MatchMaker`.

---

## `.new`

**Description**:  
Creates a new regional queue instance for a specific region and mode.

**Parameters**:
- `params` *(table)*:
  - `Mode` *(MatchMaker)* – The mode this queue belongs to (e.g., Solo, Duo).
  - `RegionCode` *(string)* – The region identifier (e.g., `"NA"`, `"EU"`).

**Returns**: `RegionalQueue` object.

**Example**:
```lua
local queue = RegionalQueue.new({
  Mode = MatchMaker:Get("Duo"),
  RegionCode = "EU",
})
```

---

## `:AddPartyAsync`

**Description**:  
Adds a new party to the queue. Automatically starts refreshing the party and checks for match assignments.

**Parameters**:
- `memberUserIds` *(array)* – A list of player user IDs.
- `partyData` *(table?, optional)* – Optional metadata to store with the party.

**Returns**: `Promise<void>`

**Example**:
```lua
queue:AddPartyAsync({12345678, 87654321}, {
  Rank = "Gold",
  CustomSkin = true
})
```

---

## `:RemovePartyAsync`

**Description**:  
Attempts to remove a party from the queue.  
If a match was already found, the player will still be teleported.

**Parameters**:
- `partyId` *(string)* – The unique Party ID.
- `forced` *(boolean)* – If `true`, bypasses queue validation and removes directly.

**Returns**: `Promise<void>`

**Example**:
```lua
queue:RemovePartyAsync(partyId, true)
  :andThen(function()
    print("Party removed successfully.")
  end)
  :catch(warn)
```

---

## `:CheckIfPartyFoundMatch`

**Description**:  
Checks if a party has been assigned a match. Optionally flags it as having left the queue.

**Parameters**:
- `party` *(table)* – The party data object.
- `leaveQueue` *(boolean)* – If `true`, the party is deprioritized.

**Returns**: `Promise<string?>` – Resolves with the `MatchId` or `nil`.

**Example**:
```lua
queue:CheckIfPartyFoundMatch(party, false)
  :andThen(function(matchId)
    if matchId then
      print("Match found:", matchId)
    else
      print("Still waiting...")
    end
  end)
```

---

## `:TeleportPartyAsync`

**Description**:  
Fetches the match info and teleports valid party members to the private server.

**Parameters**:
- `party` *(table)* – The party to teleport.
- `matchId` *(string)* – The ID of the private match.

**Returns**: `Promise<void>`

**Example**:
```lua
queue:TeleportPartyAsync(party, matchId)
  :catch(function(err)
    warn("Teleport failed:", err)
  end)
```

---

## `:GetSortedMap`

**Description**:  
Returns the underlying `MemoryStoreSortedMap` used to store parties in this queue.

**Returns**: `MemoryStoreSortedMap`

**Example**:
```lua
local sortedMap = queue:GetSortedMap("Duo", "NA")
```

---

## `:CreateMatchAsync`

**Description**:  
Attempts to atomically assign the specified parties to a match.  
Handles rollback if any party fails the update.

**Parameters**:
- `matchData` *(table)* – Must include `PlaceId`, `Parties`, and optionally `AccessCode`.

**Returns**: `Promise<void>`

**Example**:
```lua
queue:CreateMatchAsync({
  PlaceId = game.PlaceId,
  Parties = {party1, party2},
})
```

---

## `:CreateMatches`

**Description**:  
Creates multiple matches in parallel. Useful inside the matchmaker's coordinator cycle.

**Parameters**:
- `matchList` *(array)* – List of match data tables.

**Returns**: `Promise<void>`

**Example**:
```lua
queue:CreateMatches({
  {
    PlaceId = game.PlaceId,
    Parties = {partyA, partyB},
  },
  {
    PlaceId = game.PlaceId,
    Parties = {partyC, partyD},
  }
})
```

---

## `:DoMatchmaking`

**Description**:  
Coordinator-only method that fetches queued parties and runs the mode's `MatchMaking` logic.

**Returns**: `Promise<void>`

**Example**:
```lua
queue:DoMatchmaking()
```

---

## `:IsServerMainServer`

**Description**:  
Checks whether the current server holds the region's coordinator lock.

**Returns**: `Promise<boolean>`

**Example**:
```lua
queue:IsServerMainServer()
  :andThen(function()
    print("This server is the coordinator.")
  end)
  :catch(function()
    print("This server is not the coordinator.")
  end)
```

---

## `:TryLockServer`

**Description**:  
Attempts to acquire or renew the region lock. Used in coordinator election.

**Returns**: `Promise<LockData?>`

**Example**:
```lua
queue:TryLockServer()
  :andThen(function(lock)
    print("Lock acquired by:", lock.serverId)
  end)
```

---

## `:Destroy`

**Description**:  
Cleans up the queue and all of its connections. Called when the queue is empty or shut down.

**Returns**: `void`

**Example**:
```lua
queue:Destroy()
```

---
