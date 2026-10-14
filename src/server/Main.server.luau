--[[
	Server entry point: player data, run results (gems, XP, missions) and the
	global leaderboard.
	The runs themselves happen on each player's device (see Client/RunController).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local PlayerData = require(script.Parent.PlayerData)
local Monetization = require(script.Parent.Monetization)
local Progression = require(script.Parent.Progression)
local Shop = require(script.Parent.Shop)

local Remotes = ReplicatedStorage.Remotes

-- Glass shards and knocked-loose decorations (built on each player's device)
-- bounce off the floor and walls but not off each other, which keeps physics
-- cheap. Collision groups must be registered on the server to work everywhere.
pcall(function()
	if not PhysicsService:IsCollisionGroupRegistered("Shards") then
		PhysicsService:RegisterCollisionGroup("Shards")
	end
	PhysicsService:CollisionGroupSetCollidable("Shards", "Shards", false)
end)
local leaderboardStore = DataStoreService:GetOrderedDataStore("BestDistance_v1")

local LEADERBOARD_SIZE = 10
local LEADERBOARD_REFRESH = 60
local MISSION_CHECK_INTERVAL = 30

-- Anti-cheat ------------------------------------------------------------------
-- Highest distance one run can put on the global leaderboard (a sanity cap far
-- above any realistic run).
local MAX_RUN_METERS = 25000
-- A run only counts toward Stats.runs and the "play N runs" mission after this far.
local MIN_COUNTED_RUN_METERS = 50
-- RunEnded reports closer together than this are ignored (spam).
local MIN_RUN_ENDED_GAP = 0.5
-- The fastest a room can be flown through: at top speed, plus 15% for lag.
local MIN_ROOM_SECONDS = Config.ROOM_LENGTH / (Config.MAX_SPEED * 1.15)
-- How far ahead of that pace a player may be, in rooms, so one late network
-- message doesn't block the rest of the run. Waiting can't bank more than this.
local ROOM_LAG_ALLOWANCE = 2

-- Season info for the UI.
ReplicatedStorage:SetAttribute("SeasonName", Config.SEASON_NAME)
ReplicatedStorage:SetAttribute("SeasonEnds", Config.SEASON_ENDS)

-- player -> {
--   startedAt, pausedAt (set while on the game over screen), pausedTotal,
--   startCheckpoint, startMeters, metersRewarded,
--   reported (run stats already paid for), counted (run added to Stats.runs),
--   boosts ({ [boostId] = true } used on this run), doubleGems,
--   meterGems (gems paid for distance on this run, for 2x Gems back pay),
--   midRunBoosts ({ [boostId] = count } turned on by UseBoostNow, for ReturnBoost),
--   shieldsOn / megaBallsOn (Shields / Mega Balls turned on this run, the most
--   ReturnUnusedBoosts can give back), readyOn ({ [boostId] = count } of the
--   Config.BOOST_BAR boosts RunStarted put in the boost bar, the most that can
--   come back untapped), unusedReturned (already given back),
--   lastUnused ({ shield, megaballThrows, readyMagnet, ... } the device reported
--   with its last RunEnded, given back if they leave from the game over screen),
--   lastRoom (last room index accepted from RoomReached), roomClock (active
--   seconds the next room is measured from), pausedMaxStuds (cached time cap
--   while paused), lastEndedAt (os.clock() of the last RunEnded we handled)
-- }
local activeRuns = {}

-- player -> os.clock() when they joined this server (for the "wait! free gift",
-- which needs some real play time first).
local sessionStarts = {}

-- player -> how many RunStarted events they've sent this session. Sent back with
-- BoostsActivated so the client can ignore a confirmation meant for an older run.
local runCounts = {}

-- The furthest anyone can legitimately travel in `seconds`, following the same
-- speeds as the client (Config.speedForRoom: a warm-up from the start room, and a
-- top speed per zone). Once the speed can't change any more (MAX_SPEED reached
-- in the last zone with its own top speed), longer times are a simple multiplication.
-- Worked out once per start checkpoint: { roomTimes, time, studs, finalSpeed }.
local speedRamps = {}

local function speedRamp(startCheckpoint)
	local ramp = speedRamps[startCheckpoint]
	if ramp then
		return ramp
	end
	ramp = { roomTimes = {}, time = 0, studs = 0, finalSpeed = Config.MAX_SPEED }
	local startRoom = startCheckpoint * Config.ROOMS_PER_CHECKPOINT
	-- After this room every zone runs at MAX_SPEED (zones past the ZoneTopSpeed list).
	local lastSpeedZoneRoom = #Config.ZoneTopSpeed * Config.ROOMS_PER_CHECKPOINT
	local room = startRoom
	while true do
		local speed = Config.speedForRoom(room, startRoom)
		if speed >= Config.MAX_SPEED and room >= lastSpeedZoneRoom then
			break
		end
		if #ramp.roomTimes > 2000 then
			ramp.finalSpeed = Config.MAX_SPEED -- safety net (bad Config): assume top speed from here
			break
		end
		local seconds = Config.ROOM_LENGTH / math.max(speed, 1)
		table.insert(ramp.roomTimes, seconds)
		ramp.time += seconds
		ramp.studs += Config.ROOM_LENGTH
		room += 1
	end
	speedRamps[startCheckpoint] = ramp
	return ramp
end

local function maxStudsIn(seconds, startCheckpoint)
	if seconds <= 0 then
		return 0
	end
	local ramp = speedRamp(startCheckpoint)
	if seconds >= ramp.time then
		return ramp.studs + (seconds - ramp.time) * ramp.finalSpeed
	end
	-- Still speeding up: walk the ramp rooms.
	local studs, time = 0, 0
	for _, roomSeconds in ramp.roomTimes do
		if time + roomSeconds >= seconds then
			local speed = Config.ROOM_LENGTH / roomSeconds
			return studs + (seconds - time) * speed
		end
		studs += Config.ROOM_LENGTH
		time += roomSeconds
	end
	return studs
end

local function activeSeconds(run)
	local now = run.pausedAt or os.clock()
	return now - run.startedAt - run.pausedTotal
end

-- Time cap for the run so far. While paused (game over screen) the run's
-- active time can't change, so it's only worked out once.
local function maxStudsForRun(run)
	if run.pausedAt then
		if not run.pausedMaxStuds then
			run.pausedMaxStuds = maxStudsIn(activeSeconds(run), run.startCheckpoint)
		end
		return run.pausedMaxStuds
	end
	return maxStudsIn(activeSeconds(run), run.startCheckpoint)
end

local function pauseRun(run)
	if not run.pausedAt then
		run.pausedAt = os.clock()
		run.pausedMaxStuds = nil
	end
end

local function resumeRun(run)
	if run.pausedAt then
		run.pausedTotal += os.clock() - run.pausedAt
		run.pausedAt = nil
		run.pausedMaxStuds = nil
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

-- Unused boosts ------------------------------------------------------------------
-- When the run really ends (PLAY AGAIN / MENU from the game over screen without a
-- revive, or leaving the game from there), these go back to the inventory:
--  * a Shield that never absorbed a crash, and a Mega Ball with all its throws left
--    ("your next crash is free" shouldn't vanish because you ran out of balls),
--  * a boost-bar boost (Config.BOOST_BAR: Magnet, Slow-Mo, Mega Ball) the player
--    never tapped.
-- Capped at what this run actually took from the inventory, and only once per run.

-- Reads a whole, non-negative count from a client table (anything else = 0).
local function readCount(source, name)
	local value = if type(source) == "table" then source[name] else nil
	if type(value) ~= "number" or value ~= value or value == math.huge then
		return 0
	end
	return math.max(0, math.floor(value))
end

-- The order refunds are listed in ("Unused boosts saved: 1 SHIELD + 1 MAGNET").
local REFUND_ORDER = { "Shield", "Magnet", "SlowMo", "MegaBall" }

-- A fresh { [boostId] = 0 } for every boost-bar boost.
local function emptyBarCounts()
	local counts = {}
	for _, boostId in Config.BOOST_BAR do
		counts[boostId] = 0
	end
	return counts
end

-- unused = what the device reported (any of these may be missing or junk = 0):
--   shield         - Shields that never absorbed a crash
--   megaballThrows - giant throws left on Mega Balls that were tapped
--   readyMagnet / readySlowMo / readyMegaBall - boost-bar boosts never tapped
-- Gives them back (capped, once per run) and returns { [boostId] = count given back }.
local function refundUnusedBoosts(player, data, run, unused)
	local refunded = {}
	if run.unusedReturned then
		return refunded
	end
	run.unusedReturned = true

	-- Never tapped: no more than RunStarted put in the bar.
	for _, boostId in Config.BOOST_BAR do
		local count = math.min(readCount(unused, "ready" .. boostId), run.readyOn[boostId] or 0)
		run.readyOn[boostId] = (run.readyOn[boostId] or 0) - count
		refunded[boostId] = count
	end

	local shields = math.min(readCount(unused, "shield"), run.shieldsOn)
	run.shieldsOn -= shields
	refunded.Shield = shields

	-- Mega Balls: whole ones with every throw left, plus the untapped ones counted
	-- above, but never more than this run turned on in total.
	local throwsPerMega = math.max(1, Config.Boosts.MegaBall.Throws)
	local megaBalls = math.min(readCount(unused, "megaballThrows") // throwsPerMega + (refunded.MegaBall or 0), run.megaBallsOn)
	run.megaBallsOn -= megaBalls
	refunded.MegaBall = megaBalls

	local any = false
	for boostId, count in refunded do
		if count > 0 then
			Progression.addBoost(data, boostId, count)
			any = true
		end
	end
	if any then
		PlayerData.publish(player, { "Boosts" })
	end
	return refunded
end

local function onPlayerAdded(player)
	sessionStarts[player] = sessionStarts[player] or os.clock()
	createLeaderstats(player)
	PlayerData.load(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	-- Left from the game over screen: give back unused boosts (the device can't
	-- tell us any more, so use what it reported with its last RunEnded).
	local run = activeRuns[player]
	local data = PlayerData.get(player)
	if run and data and run.pausedAt and run.lastUnused then
		refundUnusedBoosts(player, data, run, run.lastUnused)
	end
	activeRuns[player] = nil
	runCounts[player] = nil
	sessionStarts[player] = nil
	Shop.release(player)
	PlayerData.release(player)
end)

game:BindToClose(function()
	-- Roblox gives us up to 30 seconds to finish saving.
	PlayerData.releaseAll(25)
end)

Monetization.init()
Shop.init()
PlayerData.startAutosave()

-- Shop action "UseBoostNow"(boostId): the device asks this right after buying a
-- boost with Robux mid-run (the purchase always goes to the inventory first).
-- Takes one from the inventory and turns it on for the current run.
-- Returns true only if it's on; otherwise it stays in the inventory.
Shop.addAction("UseBoostNow", function(player, data, boostId)
	if not Progression.isBoost(boostId) then
		return false, "That boost doesn't exist"
	end
	local run = activeRuns[player]
	if not run or run.pausedAt then
		return false, "No run going"
	end
	if boostId == "DoubleGems" and run.doubleGems then
		return false, "2x gems is already on" -- can't stack
	end
	if not Progression.takeBoost(data, boostId) then
		return false, "You don't have that boost"
	end
	run.boosts[boostId] = true
	run.midRunBoosts[boostId] = (run.midRunBoosts[boostId] or 0) + 1
	if boostId == "Shield" then
		run.shieldsOn += 1
	elseif boostId == "MegaBall" then
		run.megaBallsOn += 1
	end
	local changed = { "Boosts" }
	if boostId == "DoubleGems" then
		run.doubleGems = true
		-- "Double gems for one run": also pay the extra 1x for the distance of
		-- this run that was already paid (e.g. before a revive). Only this run's
		-- distance gems, and only once (2x can't stack or be turned on twice).
		local backPay = run.meterGems
		if backPay > 0 then
			run.meterGems += backPay
			data.Gems += backPay
			table.insert(changed, "Gems")
			Progression.fire(player, { type = "Reward", text = "2x gems: +" .. backPay .. " for this run so far" })
		end
	end
	PlayerData.publish(player, changed)
	return true
end)

-- Shop action "ReturnBoost"(boostId): UseBoostNow said yes, but by the time the
-- answer reached the device the run had ended. Puts that boost back in the
-- inventory, but only one UseBoostNow really took on this run.
-- 2x Gems can't be returned: it already doubled this run's gems on the server.
Shop.addAction("ReturnBoost", function(player, data, boostId)
	if not Progression.isBoost(boostId) then
		return false, "That boost doesn't exist"
	end
	if boostId == "DoubleGems" then
		return false, "2x gems already counted for this run"
	end
	local run = activeRuns[player]
	local taken = if run then run.midRunBoosts[boostId] or 0 else 0
	if taken < 1 then
		return false, "Nothing to give back"
	end
	-- Already given back by ReturnUnusedBoosts? Then there's nothing left to return.
	if (boostId == "Shield" and run.shieldsOn < 1) or (boostId == "MegaBall" and run.megaBallsOn < 1) then
		return false, "Nothing to give back"
	end
	run.midRunBoosts[boostId] = taken - 1
	if boostId == "Shield" then
		run.shieldsOn = math.max(0, run.shieldsOn - 1)
	elseif boostId == "MegaBall" then
		run.megaBallsOn = math.max(0, run.megaBallsOn - 1)
	end
	Progression.addBoost(data, boostId, 1)
	PlayerData.publish(player, { "Boosts" })
	return true
end)

-- Shop action "BoostTapped"(boostId): a boost-bar boost was tapped on the
-- device, so it no longer counts as "never tapped" for ReturnUnusedBoosts.
Shop.addAction("BoostTapped", function(player, data, boostId)
	local run = activeRuns[player]
	if not run or type(boostId) ~= "string" or (run.readyOn[boostId] or 0) < 1 then
		return false, "Nothing to tap"
	end
	run.readyOn[boostId] -= 1
	return true
end)

-- Shop action "ReturnUnusedBoosts"({ shield = n, megaballThrows = t, readyMagnet = n,
-- readySlowMo = n, readyMegaBall = n }): the device sends this once when a run
-- really ends (PLAY AGAIN or MENU from the game over screen, no revive). Only
-- while the run is stopped at game over, and only once per run (see
-- refundUnusedBoosts for what each field means and the caps).
Shop.addAction("ReturnUnusedBoosts", function(player, data, unused)
	if type(unused) ~= "table" then
		return false, "Bad request"
	end
	local run = activeRuns[player]
	if not run or not run.pausedAt then
		return false, "No finished run"
	end
	if run.unusedReturned then
		return true -- already done for this run
	end
	local refunded = refundUnusedBoosts(player, data, run, unused)
	local parts = {}
	for _, boostId in REFUND_ORDER do
		local count = refunded[boostId] or 0
		if count > 0 then
			table.insert(parts, count .. " " .. Config.Boosts[boostId].Name)
		end
	end
	if #parts > 0 then
		return true, "Unused boosts saved: " .. table.concat(parts, " + ")
	end
	return true
end)

-- Shop action "UseBonusBalls"(amount): the device used balls from a Revive /
-- Ball Pack right away (mid-run or on the game over screen), so they come back
-- out of the saved BonusBalls (see Monetization). Never below zero.
Shop.addAction("UseBonusBalls", function(player, data, amount)
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount == math.huge then
		return false, "Bad amount"
	end
	local used = math.min(math.floor(amount), data.BonusBalls)
	if used > 0 then
		PlayerData.update(player, { BonusBalls = data.BonusBalls - used })
	end
	return true
end)

-- Shop action "RecheckPasses": the menu opened; picks up a game pass bought
-- outside this server. Rate limited in Monetization.
Shop.addAction("RecheckPasses", function(player)
	return Monetization.recheckPasses(player)
end)

-- Shop action "ResumeRun": the device sends this after it has really revived
-- (Revive or ball pack on the game over screen), so the run's clock runs again.
Shop.addAction("ResumeRun", function(player)
	local run = activeRuns[player]
	if not run then
		return false, "No run going"
	end
	resumeRun(run)
	return true
end)

-- Shop action "ClaimLeaveGift": the "wait! free gift" popup's CLAIM button.
-- Progression.claimLeaveGift checks the cooldown and the play time; the client's
-- own check only decides whether to show the popup.
Shop.addAction("ClaimLeaveGift", function(player, data)
	local started = sessionStarts[player]
	local playedSeconds = if started then os.clock() - started else 0
	local ok, message = Progression.claimLeaveGift(data, os.time(), playedSeconds)
	if ok then
		-- Saved by the autosave (publish marks the data as changed).
		PlayerData.publish(player, Progression.LEAVE_GIFT_FIELDS)
		Progression.fire(player, { type = "Reward", text = message, source = "LeaveGift" })
	end
	return ok, message
end)

-- Picks the boosts the player asked for (boostIds, a list of ids) that are real,
-- not repeated and actually owned, up to Config.MAX_BOOSTS_PER_RUN.
local function chooseBoosts(data, boostIds)
	local chosen = {}
	if type(boostIds) ~= "table" then
		return chosen
	end
	for i = 1, Config.MAX_BOOSTS_PER_RUN do
		local boostId = boostIds[i]
		if
			Progression.isBoost(boostId)
			and not table.find(chosen, boostId)
			and Progression.boostCount(data, boostId) >= 1
		then
			table.insert(chosen, boostId)
		end
	end
	return chosen
end

-- RunStarted(startCheckpoint, boostIds?)
-- startCheckpoint lets Checkpoints pass owners skip ahead to a zone they've reached.
-- boostIds: boosts picked from the inventory for this run (older clients send none).
Remotes.RunStarted.OnServerEvent:Connect(function(player, startCheckpoint, boostIds)
	runCounts[player] = (runCounts[player] or 0) + 1
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
	local run = {
		startedAt = os.clock(),
		pausedAt = nil,
		pausedTotal = 0,
		startCheckpoint = checkpoint,
		startMeters = startMeters,
		metersRewarded = startMeters, -- no gems for the part you skipped
		reported = { glass = 0, crystals = 0, props = 0, maxMultiball = 0 },
		counted = false,
		boosts = {},
		doubleGems = false,
		meterGems = 0,
		midRunBoosts = {},
		shieldsOn = 0,
		megaBallsOn = 0,
		readyOn = emptyBarCounts(),
		unusedReturned = false,
		lastUnused = nil,
		lastRoom = checkpoint * Config.ROOMS_PER_CHECKPOINT, -- the room the run starts in
		roomClock = 0,
		pausedMaxStuds = nil,
		lastEndedAt = nil,
	}
	activeRuns[player] = run

	-- Bonus balls (from the daily streak) go into this run. The client already
	-- read the attribute when it started the run.
	if data.BonusBalls > 0 then
		PlayerData.update(player, { BonusBalls = 0 })
	end

	-- Boosts: use up one of each, then tell the client which ones really started
	-- (it only turns on what we confirm here). Shield and 2x Gems work by
	-- themselves; boost-bar boosts (Config.BOOST_BAR) wait until the player taps
	-- them, and come back with ReturnUnusedBoosts if they never do.
	local used = {}
	for _, boostId in chooseBoosts(data, boostIds) do
		if Progression.takeBoost(data, boostId) then
			table.insert(used, boostId)
			run.boosts[boostId] = true
			if boostId == "DoubleGems" then
				run.doubleGems = true
			elseif boostId == "Shield" then
				run.shieldsOn += 1
			elseif boostId == "MegaBall" then
				run.megaBallsOn += 1
			end
			if run.readyOn[boostId] then
				run.readyOn[boostId] += 1
			end
		end
	end
	if #used > 0 then
		PlayerData.publish(player, { "Boosts" })
		Progression.fire(player, { type = "BoostsActivated", boosts = used, run = runCounts[player] })
		-- Saved by the autosave (publish marked the data as changed).
	end
end)

-- RoomReached(roomIndex): sent each time the player's camera enters a new room.
-- Rooms must come in order, and no faster than top speed allows (counting only
-- time actually running). RunEnded then pays at most up to the last accepted room.
Remotes.RoomReached.OnServerEvent:Connect(function(player, roomIndex)
	local run = activeRuns[player]
	if not run or type(roomIndex) ~= "number" or roomIndex ~= math.floor(roomIndex) then
		return -- not a whole number (NaN fails this too)
	end
	if roomIndex ~= run.lastRoom + 1 then
		return
	end
	local now = activeSeconds(run)
	local earliest = run.roomClock + MIN_ROOM_SECONDS
	if now < earliest then
		return -- too fast: ignore it (no kick; lag can cause the odd one)
	end
	run.lastRoom = roomIndex
	-- Measure the next room from here, but let a player who is slower than top
	-- speed be up to ROOM_LAG_ALLOWANCE rooms "ahead", so a late message
	-- followed by an on-time one still gets through.
	run.roomClock = math.max(earliest, now - ROOM_LAG_ALLOWANCE * MIN_ROOM_SECONDS)
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
	local now = os.clock()
	if run.lastEndedAt and now - run.lastEndedAt < MIN_RUN_ENDED_GAP then
		return -- spam
	end
	run.lastEndedAt = now
	if type(runStats) ~= "table" then
		runStats = {}
	end
	-- Shields / Mega Ball throws still unused and boost-bar boosts never tapped at
	-- this game over (given back if they leave from the game over screen; see
	-- PlayerRemoving). Same fields as a ReturnUnusedBoosts request.
	local lastUnused = {
		shield = readCount(runStats, "unusedShield"),
		megaballThrows = readCount(runStats, "unusedMegaThrows"),
	}
	for _, boostId in Config.BOOST_BAR do
		lastUnused["ready" .. boostId] = readCount(runStats, "ready" .. boostId)
	end
	run.lastUnused = lastUnused

	-- Anti-cheat: the distance is the smallest of
	--  * what the device says,
	--  * how far the speed ramp allows in the time they actually spent running
	--    (time on the game over screen doesn't count),
	--  * the end of the last room the server accepted from RoomReached.
	pauseRun(run)
	local timeCap = run.startMeters + maxStudsForRun(run) / Config.STUDS_PER_METER * 1.1 + 15
	local roomCap = (run.lastRoom + 1) * Config.ROOM_LENGTH / Config.STUDS_PER_METER
	meters = math.clamp(math.floor(meters), 0, math.floor(math.min(timeCap, roomCap)))

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
	-- Only a real attempt counts as a run (not tapping PLAY then MENU).
	deltas.runs = 0
	if not run.counted and flownMeters >= MIN_COUNTED_RUN_METERS then
		deltas.runs = 1
		run.counted = true
	end

	-- Gems and XP for what was added since the last report.
	local multiplier = gemMultiplier(player)
	if run.doubleGems then
		multiplier *= 2 -- DoubleGems boost
	end
	local gemsEarned = math.floor(newMeters * Config.GEMS_PER_METER * multiplier)
	run.meterGems += gemsEarned
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

	-- First-time zone rewards (Config.ZoneRewards), only for zones flown into on
	-- this run. Saved in ZonesRewarded so each one is given once.
	local zoneRewards = Progression.grantZoneRewards(data, run.startCheckpoint, reachedZone)
	if #zoneRewards > 0 then
		PlayerData.publish(player, Progression.REWARD_FIELDS)
	end
	-- Balls earned by lifetime stats (Smashbot: 50,000 glass in total), each once.
	local statUnlocks = Progression.grantStatUnlocks(data)
	if #statUnlocks > 0 then
		PlayerData.publish(player, { "OwnedSkins" })
	end

	-- Personal best + global leaderboard only count runs from the very start,
	-- so a Checkpoints pass can't buy a higher score.
	-- One run can never put more than MAX_RUN_METERS on the board.
	if run.startCheckpoint == 0 and meters > data.Best then
		changes.Best = meters
		-- Skip if their data didn't load: their real best is unknown.
		if PlayerData.canSave(player) then
			task.spawn(updateLeaderboard, player, math.min(meters, MAX_RUN_METERS))
		end
	end
	PlayerData.update(player, changes)

	for _, text in completed do
		Progression.fire(player, { type = "MissionComplete", text = text })
	end
	for _, event in events do
		Progression.fire(player, event)
	end
	for _, text in zoneRewards do
		Progression.fire(player, { type = "Reward", text = text, source = "Zone" })
	end
	for _, text in statUnlocks do
		Progression.fire(player, { type = "Reward", text = text, source = "Unlock" })
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
