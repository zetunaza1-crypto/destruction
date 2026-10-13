--[[
	Progression rules: player levels, the season pass, daily missions and
	rewards. Works directly on a player's data table (from PlayerData) and
	returns what happened, so the caller can publish + save.

	Nothing in here talks to the DataStore. Progression.fire sends a
	Progress event to the player's screen (level up, mission done...).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local Progression = {}

local SECONDS_PER_DAY = 24 * 60 * 60
local MAX_TIER = #Config.SeasonTiers
local TIER_XP = math.max(1, Config.SEASON_TIER_XP)
local MAX_LEVEL_UPS_AT_ONCE = 100 -- safety net against a broken xpForLevel

Progression.MAX_TIER = MAX_TIER

local rng = Random.new()

-- The Progress RemoteEvent (created here too in case the Rojo project lacks it).
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local progressRemote = Remotes:FindFirstChild("Progress")
if not progressRemote then
	progressRemote = Instance.new("RemoteEvent")
	progressRemote.Name = "Progress"
	progressRemote.Parent = Remotes
end

function Progression.fire(player, event)
	if player.Parent then
		progressRemote:FireClient(player, event)
	end
end

-- Lookups ----------------------------------------------------------------------

local function findById(list, id)
	for _, item in list do
		if item.Id == id then
			return item
		end
	end
	return nil
end

function Progression.findSkin(skinId)
	return findById(Config.Skins, skinId)
end

function Progression.findFx(fxId)
	return findById(Config.ShatterFx, fxId)
end

function Progression.missionDef(missionId)
	return findById(Config.MissionPool, missionId)
end

-- "Default" skin and "Classic" effect belong to everyone.
function Progression.ownsSkin(data, skinId)
	return skinId == "Default" or table.find(data.OwnedSkins, skinId) ~= nil
end

function Progression.ownsFx(data, fxId)
	return fxId == "Classic" or table.find(data.OwnedFx, fxId) ~= nil
end

-- Rewards ------------------------------------------------------------------------

-- Gives a reward table { Gems?, Balls?, Skin?, Fx?, Boost? } (Config format).
-- Returns a short description like "+50 gems, Frost effect".
function Progression.grantReward(data, reward)
	local parts = {}
	if reward.Gems and reward.Gems > 0 then
		data.Gems += reward.Gems
		table.insert(parts, "+" .. reward.Gems .. " gems")
	end
	if reward.Balls and reward.Balls > 0 then
		data.BonusBalls += reward.Balls
		table.insert(parts, "+" .. reward.Balls .. " balls next run")
	end
	if reward.Boost and Config.Boosts and Config.Boosts[reward.Boost] then
		-- Boost inventory: { [boostId] = count }, used before a run.
		data.Boosts[reward.Boost] = (data.Boosts[reward.Boost] or 0) + 1
		table.insert(parts, Config.Boosts[reward.Boost].Name .. " boost")
	end
	if reward.Skin then
		local skin = Progression.findSkin(reward.Skin)
		if skin and not Progression.ownsSkin(data, skin.Id) then
			table.insert(data.OwnedSkins, skin.Id)
			table.insert(parts, skin.Name .. " ball")
		end
	end
	if reward.Fx then
		local fx = Progression.findFx(reward.Fx)
		if fx and not Progression.ownsFx(data, fx.Id) then
			table.insert(data.OwnedFx, fx.Id)
			table.insert(parts, fx.Name .. " effect")
		end
	end
	return table.concat(parts, ", ")
end

-- Fields grantReward can touch (for publishing).
Progression.REWARD_FIELDS = { "Gems", "BonusBalls", "OwnedSkins", "OwnedFx", "Boosts" }

-- Levels + season pass ------------------------------------------------------------

-- Adds XP to both the player level and the season pass.
-- Returns a list of Progress events (LevelUp / SeasonTier) to send.
function Progression.addXP(data, amount)
	local events = {}
	amount = math.floor(amount)
	if amount <= 0 then
		return events
	end

	data.XP += amount
	for _ = 1, MAX_LEVEL_UPS_AT_ONCE do
		local needed = Config.xpForLevel(data.Level)
		if data.XP < needed then
			break
		end
		data.XP -= needed
		data.Level += 1
		data.Gems += Config.LEVEL_UP_GEMS

		local unlock = nil
		local unlockDef = Config.LevelUnlocks[data.Level]
		if unlockDef then
			unlock = {}
			if unlockDef.Skin and Progression.findSkin(unlockDef.Skin) then
				if not Progression.ownsSkin(data, unlockDef.Skin) then
					table.insert(data.OwnedSkins, unlockDef.Skin)
				end
				unlock.Skin = unlockDef.Skin
			end
			if unlockDef.Fx and Progression.findFx(unlockDef.Fx) then
				if not Progression.ownsFx(data, unlockDef.Fx) then
					table.insert(data.OwnedFx, unlockDef.Fx)
				end
				unlock.Fx = unlockDef.Fx
			end
			if next(unlock) == nil then
				unlock = nil
			end
		end
		table.insert(events, { type = "LevelUp", level = data.Level, gems = Config.LEVEL_UP_GEMS, unlock = unlock })
	end

	if data.SeasonTier < MAX_TIER then
		data.SeasonXP += amount
		while data.SeasonTier < MAX_TIER and data.SeasonXP >= TIER_XP do
			data.SeasonXP -= TIER_XP
			data.SeasonTier += 1
			table.insert(events, { type = "SeasonTier", tier = data.SeasonTier })
		end
	end
	if data.SeasonTier >= MAX_TIER then
		data.SeasonXP = 0
	end

	return events
end

-- Fields addXP can touch (for publishing).
Progression.XP_FIELDS = { "Level", "XP", "Gems", "OwnedSkins", "OwnedFx", "SeasonTier", "SeasonXP" }

-- A new season (Config.SEASON_ID bumped) starts everyone from tier 0.
function Progression.ensureSeason(data)
	if data.SeasonId == Config.SEASON_ID then
		return false
	end
	data.SeasonId = Config.SEASON_ID
	data.SeasonTier = 0
	data.SeasonXP = 0
	data.SeasonPremium = false
	data.SeasonClaimed = { free = {}, premium = {} }
	return true
end

-- Daily missions ----------------------------------------------------------------

-- Next midnight (UTC) after `now`.
function Progression.nextReset(now)
	return (now // SECONDS_PER_DAY + 1) * SECONDS_PER_DAY
end

-- Picks a mission that isn't already on the list, preferring a different stat
-- so the three missions of a day feel different.
local function pickMission(current)
	local usedIds, usedStats = {}, {}
	for _, mission in current do
		usedIds[mission.id] = true
		local def = Progression.missionDef(mission.id)
		if def then
			usedStats[def.Stat] = true
		end
	end

	local fresh, fallback = {}, {}
	for _, def in Config.MissionPool do
		if not usedIds[def.Id] then
			table.insert(fallback, def)
			if not usedStats[def.Stat] then
				table.insert(fresh, def)
			end
		end
	end
	local pool = if #fresh > 0 then fresh else fallback
	if #pool == 0 then
		return nil
	end
	return pool[rng:NextInteger(1, #pool)]
end

local function newMission(def)
	return { id = def.Id, progress = 0, claimed = false }
end

local function missionsValid(missions)
	if type(missions) ~= "table" or #missions == 0 then
		return false
	end
	for _, mission in missions do
		if
			type(mission) ~= "table"
			or type(mission.progress) ~= "number"
			or not Progression.missionDef(mission.id)
		then
			return false
		end
	end
	return true
end

-- New missions every day at midnight UTC. Returns true if they changed.
function Progression.refreshMissions(data, now)
	if now < data.MissionsReset and missionsValid(data.Missions) then
		return false
	end
	local missions = {}
	for _ = 1, Config.MISSIONS_PER_DAY do
		local def = pickMission(missions)
		if not def then
			break
		end
		table.insert(missions, newMission(def))
	end
	data.Missions = missions
	data.MissionRerolls = Config.MISSION_REROLLS_PER_DAY
	data.MissionsReset = Progression.nextReset(now)
	return true
end

Progression.MISSION_FIELDS = { "Missions", "MissionRerolls", "MissionsReset" }

-- What the client sees (the Missions attribute).
function Progression.publicMissions(data)
	local list = {}
	for _, mission in data.Missions do
		local def = Progression.missionDef(mission.id)
		if def then
			table.insert(list, {
				id = def.Id,
				text = string.format(def.Text, def.Goal),
				stat = def.Stat,
				goal = def.Goal,
				progress = math.min(mission.progress, def.Goal),
				gems = def.Gems,
				xp = def.XP,
				claimed = mission.claimed == true,
			})
		end
	end
	return list
end

local function findMission(data, missionId)
	for index, mission in data.Missions do
		if mission.id == missionId then
			return mission, index
		end
	end
	return nil
end

function Progression.rerollMission(data, missionId)
	local mission, index = findMission(data, missionId)
	local def = mission and Progression.missionDef(mission.id)
	if not mission or not def then
		return false, "Mission not found"
	end
	if data.MissionRerolls <= 0 then
		return false, "No rerolls left today"
	end
	if mission.claimed or mission.progress >= def.Goal then
		return false, "That mission is already done"
	end

	local others = table.clone(data.Missions)
	local replacement = pickMission(others) -- avoids the current one too
	if not replacement then
		return false, "No other missions available"
	end
	data.Missions[index] = newMission(replacement)
	data.MissionRerolls -= 1
	return true, "New mission: " .. string.format(replacement.Text, replacement.Goal)
end

-- Returns ok, message, rewardText, events.
function Progression.claimMission(data, missionId)
	local mission = findMission(data, missionId)
	local def = mission and Progression.missionDef(mission.id)
	if not mission or not def then
		return false, "Mission not found"
	end
	if mission.claimed then
		return false, "Already claimed"
	end
	if mission.progress < def.Goal then
		return false, "Not finished yet"
	end

	mission.claimed = true
	data.Gems += def.Gems
	local events = Progression.addXP(data, def.XP)
	local text = "+" .. def.Gems .. " gems, +" .. def.XP .. " XP"
	return true, text, events
end

-- Run results -------------------------------------------------------------------

local CUMULATIVE = { "glass", "crystals", "props", "runs" }
local BEST = { "bestZone", "bestRunMeters", "bestMultiball" }

-- Adds one run report to lifetime stats and mission progress.
-- deltas: { glass, crystals, props, runs } added since the last report.
-- best: { bestZone, bestRunMeters, bestMultiball } values reached this run.
-- Returns the texts of missions that just got completed.
function Progression.trackRun(data, deltas, best)
	local stats = data.Stats
	for _, stat in CUMULATIVE do
		stats[stat] += deltas[stat] or 0
	end
	for _, stat in BEST do
		stats[stat] = math.max(stats[stat], best[stat] or 0)
	end

	local completed = {}
	for _, mission in data.Missions do
		local def = Progression.missionDef(mission.id)
		if def and not mission.claimed then
			local before = mission.progress
			if def.Max then
				mission.progress = math.max(mission.progress, best[def.Stat] or 0)
			else
				mission.progress += deltas[def.Stat] or 0
			end
			if before < def.Goal and mission.progress >= def.Goal then
				table.insert(completed, string.format(def.Text, def.Goal))
			end
		end
	end
	return completed
end

-- Daily streak ------------------------------------------------------------------

-- Returns ok, message.
function Progression.claimDaily(data, now)
	if now < data.NextDaily then
		return false, "Come back later"
	end

	local day = data.StreakDay
	if now > data.StreakExpires then
		day = 1 -- missed a day: the streak starts over
	end
	day = math.clamp(day, 1, #Config.DailyStreak)

	local text = Progression.grantReward(data, Config.DailyStreak[day])
	data.StreakDay = day % #Config.DailyStreak + 1
	data.NextDaily = now + Config.DAILY_REWARD_COOLDOWN
	data.StreakExpires = now + Config.DAILY_STREAK_RESET
	return true, "Day " .. day .. ": " .. text
end

Progression.DAILY_FIELDS = { "Gems", "BonusBalls", "OwnedSkins", "OwnedFx", "Boosts", "StreakDay", "NextDaily", "StreakExpires" }

-- Season tiers ------------------------------------------------------------------

-- Returns ok, message.
function Progression.claimSeasonTier(data, request)
	if type(request) ~= "table" then
		return false, "Bad request"
	end
	local track, tier = request.track, request.tier
	if track ~= "Free" and track ~= "Premium" then
		return false, "Bad request"
	end
	if type(tier) ~= "number" or tier ~= math.floor(tier) or tier < 1 or tier > MAX_TIER then
		return false, "That tier doesn't exist"
	end
	if tier > data.SeasonTier then
		return false, "Reach tier " .. tier .. " first"
	end
	if track == "Premium" and not data.SeasonPremium then
		return false, "Needs the premium pass"
	end

	local reward = Config.SeasonTiers[tier][track]
	if not reward then
		return false, "No reward on this tier"
	end
	local claimedList = if track == "Free" then data.SeasonClaimed.free else data.SeasonClaimed.premium
	if table.find(claimedList, tier) then
		return false, "Already claimed"
	end

	table.insert(claimedList, tier)
	local text = Progression.grantReward(data, reward)
	if text == "" then
		text = "Reward claimed"
	end
	return true, "Tier " .. tier .. ": " .. text
end

-- Loading -----------------------------------------------------------------------

local function wholeNumber(value, minimum)
	if type(value) ~= "number" or value ~= value or value == math.huge then
		return minimum
	end
	return math.max(minimum, math.floor(value))
end

-- Fixes up data right after it's loaded (old saves, new season, new day).
function Progression.normalize(data, now)
	data.Level = wholeNumber(data.Level, 1)
	data.XP = wholeNumber(data.XP, 0)
	data.Gems = wholeNumber(data.Gems, 0)
	data.BonusBalls = wholeNumber(data.BonusBalls, 0)
	data.StreakDay = math.clamp(wholeNumber(data.StreakDay, 1), 1, #Config.DailyStreak)
	data.MissionRerolls = wholeNumber(data.MissionRerolls, 0)

	if not table.find(data.OwnedSkins, "Default") then
		table.insert(data.OwnedSkins, 1, "Default")
	end
	if not table.find(data.OwnedFx, "Classic") then
		table.insert(data.OwnedFx, 1, "Classic")
	end
	if not Progression.findSkin(data.EquippedSkin) or not Progression.ownsSkin(data, data.EquippedSkin) then
		data.EquippedSkin = "Default"
	end
	if not Progression.findFx(data.EquippedFx) or not Progression.ownsFx(data, data.EquippedFx) then
		data.EquippedFx = "Classic"
	end

	Progression.ensureSeason(data)
	data.SeasonTier = math.clamp(wholeNumber(data.SeasonTier, 0), 0, MAX_TIER)
	data.SeasonXP = wholeNumber(data.SeasonXP, 0)

	Progression.refreshMissions(data, now)
end

return Progression
