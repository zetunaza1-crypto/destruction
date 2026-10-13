--[[
	Server entry point: player data, run results (gems, XP, missions) and the
	global leaderboard.
	The runs themselves happen on each player's device (see Client/RunController).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local PlayerData = require(script.Parent.PlayerData)
local Monetization = require(script.Parent.Monetization)
local Progression = require(script.Parent.Progression)
local Shop = require(script.Parent.Shop)

local Remotes = ReplicatedStorage.Remotes
local leaderboardStore = DataStoreService:GetOrderedDataStore("BestDistance_v1")

local LEADERBOARD_SIZE = 10
local LEADERBOARD_REFRESH = 60
local MISSION_CHECK_INTERVAL = 30

-- Season info for the UI.
ReplicatedStorage:SetAttribute("SeasonName", Config.SEASON_NAME)
ReplicatedStorage:SetAttribute("SeasonEnds", Config.SEASON_ENDS)

-- player -> {
--   startedAt, pausedAt (set while on the game over screen), pausedTotal,
--   startCheckpoint, startMeters, metersRewarded,
--   reported (run stats already paid for), counted (run added to Stats.runs)
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
		startCheckpoint = checkpoint,
		startMeters = startMeters,
		metersRewarded = startMeters, -- no gems for the part you skipped
		reported = { glass = 0, crystals = 0, props = 0, maxMultiball = 0 },
		counted = false,
	}

	-- Bonus balls (from the daily streak) go into this run. The client already
	-- read the attribute when it started the run.
	if data.BonusBalls > 0 then
		PlayerData.update(player, { BonusBalls = 0 })
	end
end)

-- Reads one number from the client's run stats, clamped to what's possible.
local function readStat(runStats, name, maximum)
	local value = runStats[name]
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, math.max(0, math.floor(maximum)))
end

local function gemMultiplier(player)
	local multiplier = 1
	if Monetization.ownsPass(player, "VIP") then
		multiplier = Config.GamePasses.VIP.GemMultiplier
	end
	if player.MembershipType == Enum.MembershipType.Premium then
		multiplier *= 1 + Config.PREMIUM_GEM_BONUS
	end
	return multiplier
end

local function updateLeaderboard(player, meters)
	local ok, err = pcall(leaderboardStore.UpdateAsync, leaderboardStore, tostring(player.UserId), function(old)
		if old and old >= meters then
			return nil -- keep the higher score already stored
		end
		return meters
	end)
	if not ok then
		warn("Could not update leaderboard:", err)
	end
end

-- Sent at every game over: RunEnded(meters, runStats).
-- runStats = { glass, crystals, props, maxMultiball }, counted from the start of
-- the run. A revive continues the same run and reports again with bigger
-- numbers, so we only pay out what was added since the last report.
Remotes.RunEnded.OnServerEvent:Connect(function(player, meters, runStats)
	local run = activeRuns[player]
	local data = PlayerData.get(player)
	if not run or not data or type(meters) ~= "number" or meters ~= meters then
		return
	end
	if type(runStats) ~= "table" then
		runStats = {}
	end

	-- Anti-cheat: nobody can go further than the speed ramp allows in the time
	-- they actually spent running (time on the game over screen doesn't count).
	local maxMeters = run.startMeters + maxStudsIn(activeSeconds(run)) / Config.STUDS_PER_METER * 1.1 + 15
	meters = math.clamp(math.floor(meters), 0, math.floor(maxMeters))
	run.pausedAt = run.pausedAt or os.clock()

	local newMeters = math.max(0, meters - run.metersRewarded)
	run.metersRewarded = math.max(run.metersRewarded, meters)

	-- Run stats, capped by how many rooms they really flew through
	-- (+2 because balls reach rooms ahead of the camera).
	local flownMeters = math.max(0, meters - run.startMeters)
	local rooms = flownMeters * Config.STUDS_PER_METER // Config.ROOM_LENGTH + 2
	local crystals = readStat(runStats, "crystals", rooms * 2 + 5)
	local minimumMultiball = if Monetization.ownsPass(player, "Multiball") then 2 else 1
	local maxMultiballPossible = math.min(
		Config.MAX_MULTIBALL,
		minimumMultiball + crystals // Config.CRYSTALS_PER_MULTIBALL_LEVEL
	)
	local stats = {
		glass = readStat(runStats, "glass", rooms * 12 + 20),
		crystals = crystals,
		props = readStat(runStats, "props", rooms * 10 + 10),
		maxMultiball = readStat(runStats, "maxMultiball", maxMultiballPossible),
	}

	local deltas = {}
	for name, value in stats do
		deltas[name] = math.max(0, value - run.reported[name])
		run.reported[name] = math.max(run.reported[name], value)
	end
	deltas.runs = if run.counted then 0 else 1
	run.counted = true

	-- Gems and XP for what was added since the last report.
	local gemsEarned = math.floor(newMeters * Config.GEMS_PER_METER * gemMultiplier(player))
	local xp = Config.XP
	local xpEarned = math.floor(
		newMeters * xp.PerMeter
			+ deltas.glass * xp.PerGlass
			+ deltas.crystals * xp.PerCrystal
			+ deltas.props * xp.PerProp
	)

	-- Zone counts for missions only if they actually flew into it.
	local reachedZone = math.floor(meters / Config.checkpointMeters(1))
	local best = {
		bestZone = if reachedZone > run.startCheckpoint then reachedZone else 0,
		bestRunMeters = flownMeters,
		bestMultiball = run.reported.maxMultiball,
	}

	local missionsReset = Progression.refreshMissions(data, os.time())
	local completed = Progression.trackRun(data, deltas, best)

	local levelBefore = data.Level
	data.Gems += gemsEarned
	local events = Progression.addXP(data, xpEarned)

	local changed = { "Stats", "Missions" }
	if missionsReset then
		changed = { "Stats", "Missions", "MissionRerolls", "MissionsReset" }
	end
	PlayerData.publish(player, changed)
	PlayerData.publish(player, Progression.XP_FIELDS)

	local changes = {}
	if reachedZone > data.Checkpoint then
		changes.Checkpoint = reachedZone
	end

	-- Personal best + global leaderboard only count runs from the very start,
	-- so a Checkpoints pass can't buy a higher score.
	if run.startCheckpoint == 0 and meters > data.Best then
		changes.Best = meters
		-- Skip if their data didn't load: their real best is unknown.
		if PlayerData.canSave(player) then
			task.spawn(updateLeaderboard, player, meters)
		end
	end
	PlayerData.update(player, changes)

	for _, text in completed do
		Progression.fire(player, { type = "MissionComplete", text = text })
	end
	for _, event in events do
		Progression.fire(player, event)
	end
	Progression.fire(player, {
		type = "RunSummary",
		xp = xpEarned,
		gems = gemsEarned,
		levelBefore = levelBefore,
		levelAfter = data.Level,
		missionsCompleted = #completed,
	})
end)

-- New daily missions at midnight UTC, even for players who stay in the game.
task.spawn(function()
	while true do
		task.wait(MISSION_CHECK_INTERVAL)
		local now = os.time()
		PlayerData.forEach(function(player, data)
			if Progression.refreshMissions(data, now) then
				PlayerData.publish(player, Progression.MISSION_FIELDS)
			end
		end)
	end
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
