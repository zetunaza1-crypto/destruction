--[[
	Server entry point: player data, run results, gems and the global leaderboard.
	The runs themselves happen on each player's device (see Client/RunController).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local PlayerData = require(script.Parent.PlayerData)
local Monetization = require(script.Parent.Monetization)
local Shop = require(script.Parent.Shop)

local Remotes = ReplicatedStorage.Remotes
local leaderboardStore = DataStoreService:GetOrderedDataStore("BestDistance_v1")

local LEADERBOARD_SIZE = 10
local LEADERBOARD_REFRESH = 60

-- player -> { startedAt = number, startMeters = number, metersRewarded = number }
local activeRuns = {}

local function createLeaderstats(player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local best = Instance.new("IntValue")
	best.Name = "Best"
	best.Parent = leaderstats

	local gems = Instance.new("IntValue")
	gems.Name = "Gems"
	gems.Parent = leaderstats

	leaderstats.Parent = player
end

local function onPlayerAdded(player)
	createLeaderstats(player)
	PlayerData.load(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	activeRuns[player] = nil
	Shop.release(player)
	PlayerData.release(player)
end)

game:BindToClose(function()
	PlayerData.saveAll()
	task.wait(2)
end)

Monetization.init()
Shop.init()

-- startCheckpoint lets Checkpoints pass owners skip ahead to a zone they've reached.
Remotes.RunStarted.OnServerEvent:Connect(function(player, startCheckpoint)
	local data = PlayerData.get(player)
	if not data then
		return
	end

	local checkpoint = 0
	if
		type(startCheckpoint) == "number"
		and startCheckpoint == math.floor(startCheckpoint)
		and startCheckpoint > 0
		and startCheckpoint <= data.Checkpoint
		and Monetization.ownsPass(player, "Checkpoints")
	then
		checkpoint = startCheckpoint
	end

	local startMeters = math.floor(Config.checkpointMeters(checkpoint))
	activeRuns[player] = {
		startedAt = os.clock(),
		startMeters = startMeters,
		metersRewarded = startMeters, -- no gems for the part you skipped
	}
end)

-- Sent at every game over. A revive continues the same run, so we only pay
-- out gems for the meters added since the last report.
Remotes.RunEnded.OnServerEvent:Connect(function(player, meters)
	local run = activeRuns[player]
	local data = PlayerData.get(player)
	if not run or not data or type(meters) ~= "number" or meters ~= meters then
		return
	end

	-- Basic anti-cheat: nobody can go further than max speed allows.
	local elapsed = os.clock() - run.startedAt
	local maxMeters = run.startMeters + elapsed * Config.MAX_SPEED / Config.STUDS_PER_METER * 1.2 + 10
	meters = math.clamp(math.floor(meters), 0, math.floor(maxMeters))

	local newMeters = math.max(0, meters - run.metersRewarded)
	run.metersRewarded = math.max(run.metersRewarded, meters)

	local multiplier = 1
	if Monetization.ownsPass(player, "VIP") then
		multiplier = Config.GamePasses.VIP.GemMultiplier
	end
	local gemsEarned = math.floor(newMeters * Config.GEMS_PER_METER * multiplier)

	local changes = { Gems = data.Gems + gemsEarned }

	local metersPerZone = Config.checkpointMeters(1)
	local reachedCheckpoint = math.floor(meters / metersPerZone)
	if reachedCheckpoint > data.Checkpoint then
		changes.Checkpoint = reachedCheckpoint
	end

	if meters > data.Best then
		changes.Best = meters
		task.spawn(function()
			local ok, err = pcall(leaderboardStore.SetAsync, leaderboardStore, tostring(player.UserId), meters)
			if not ok then
				warn("Could not update leaderboard:", err)
			end
		end)
	end
	PlayerData.update(player, changes)
end)

-- Global leaderboard ---------------------------------------------------------

local nameCache = {}

local function getName(userId)
	if nameCache[userId] then
		return nameCache[userId]
	end
	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if ok then
		nameCache[userId] = name
		return name
	end
	return "???"
end

local function refreshLeaderboard()
	local ok, pages = pcall(leaderboardStore.GetSortedAsync, leaderboardStore, false, LEADERBOARD_SIZE)
	if not ok then
		warn("Could not load leaderboard:", pages)
		return
	end

	local top = {}
	for rank, entry in pages:GetCurrentPage() do
		table.insert(top, {
			rank = rank,
			name = getName(tonumber(entry.key)),
			meters = entry.value,
		})
	end
	ReplicatedStorage:SetAttribute("TopRuns", HttpService:JSONEncode(top))
end

task.spawn(function()
	while true do
		refreshLeaderboard()
		task.wait(LEADERBOARD_REFRESH)
	end
end)
