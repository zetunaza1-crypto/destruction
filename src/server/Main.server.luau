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

-- player -> {
--   startedAt, pausedAt (set while on the game over screen), pausedTotal,
--   startMeters, metersRewarded
-- }
local activeRuns = {}

-- The furthest anyone can legitimately travel in `seconds`, following the same
-- speed ramp as the client (speeds up every room, capped at MAX_SPEED).
local function maxStudsIn(seconds)
	local studs, time, dt = 0, 0, 0.05
	while time < seconds do
		local rooms = studs // Config.ROOM_LENGTH
		local speed = math.min(Config.MAX_SPEED, Config.START_SPEED + rooms * Config.SPEED_GAIN_PER_ROOM)
		studs += speed * dt
		time += dt
	end
	return studs
end

local function activeSeconds(run)
	local now = run.pausedAt or os.clock()
	return now - run.startedAt - run.pausedTotal
end

-- A revive (or ball pack on the game over screen) continues the run.
Monetization.onProductGranted = function(player, productKey)
	local run = activeRuns[player]
	if run and run.pausedAt and (productKey == "Revive" or productKey == "BallPack") then
		run.pausedTotal += os.clock() - run.pausedAt
		run.pausedAt = nil
	end
end

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
	-- Roblox gives us up to 30 seconds to finish saving.
	PlayerData.releaseAll(25)
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
		pausedAt = nil,
		pausedTotal = 0,
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

	-- Anti-cheat: nobody can go further than the speed ramp allows in the time
	-- they actually spent running (time on the game over screen doesn't count).
	local maxMeters = run.startMeters + maxStudsIn(activeSeconds(run)) / Config.STUDS_PER_METER * 1.1 + 15
	meters = math.clamp(math.floor(meters), 0, math.floor(maxMeters))
	run.pausedAt = run.pausedAt or os.clock()

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
		-- Skip if their data didn't load: their real best is unknown.
		if PlayerData.canSave(player) then
			task.spawn(function()
				local ok, err = pcall(leaderboardStore.UpdateAsync, leaderboardStore, tostring(player.UserId), function(old)
					if old and old >= meters then
						return nil -- keep the higher score already stored
					end
					return meters
				end)
				if not ok then
					warn("Could not update leaderboard:", err)
				end
			end)
		end
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
