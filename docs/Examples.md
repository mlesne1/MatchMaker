#
# Solo MatchMaker

```lua
--// Services
local PlayerService = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

--// Modules
local MatchMakerService = require(ServerScriptService.MatchMakerPackage.MatchMaker)

--// Create Solo Matchmaking Mode
local SoloMatchMaker = MatchMakerService.new({
	Name = "Solo",
	MatchMaking = function(parties)
		local matches = {}
		for _, party in ipairs(parties) do
			table.insert(matches, {
				PlaceId = game.PlaceId,
				Parties = { party },
			})
		end
		return matches
	end,
})

--// Event: When a party is matched or removed from the queue
SoloMatchMaker.PartyRemoved:Connect(function(party, match)
    if not match then return end

    local Players = {}

	for _, userId in ipairs(party.MemberIds) do
		local player = PlayerService:GetPlayerByUserId(userId)
		if not player then continue end
        table.insert(Players, player)
	end

	TeleportService:TeleportToPrivateServer(match.PlaceId, match.AccessCode, Players)
end)

--// When a player joins, add them to the solo queue
PlayerService.PlayerAdded:Connect(function(player)
	local success, party = SoloMatchMaker:AddPartyAsync({ player.UserId })
	if success then
		player:SetAttribute("PartyId", party.Id)
    else
		warn("Failed to queue player:", err)
	end
end)

--// When a player leaves, remove them from the queue
PlayerService.PlayerRemoving:Connect(function(player)
	local success, err = SoloMatchMaker:RemovePartyAsync(player:GetAttribute("PartyId"), true)
	if not success then
		warn("Failed to remove player from queue:", err)
	end
end)
```

# Template Place

https://www.roblox.com/games/131765851319441/MatchMaker-Template-Place