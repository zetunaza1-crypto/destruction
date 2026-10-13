--[[
	Loads and saves each player's progress (best distance, gems, skins, level,
	missions, season pass...).
	Note: DataStores only work in Studio if "Enable Studio Access to
	API Services" is turned on in Game Settings > Security.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Progression = require(script.Parent.Progression)

local PlayerData = {}

local store = DataStoreService:GetDataStore("PlayerData_v1")

local LOAD_ATTEMPTS = 3
-- Changed profiles are saved about once a minute (spread out over the minute),
-- instead of after every action: DataStores only allow so many writes.
local AUTOSAVE_INTERVAL = 60
local MAX_RECEIPTS = 50 -- remembered purchase IDs, so a retried receipt is never paid twice

-- Every new field needs a default here. Old saves get missing fields filled in.
local DEFAULT_DATA = {
	Best = 0, -- meters (only runs started from the beginning count)
	Gems = 0,
	Checkpoint = 0, -- highest zone reached
	-- ZoneLength: rooms per zone the save's Checkpoint is counted in (missing in old
	-- 10-room saves; Progression.migrateZoneLength converts them once and sets it).
	OwnedSkins = { "Default" },
	EquippedSkin = "Default",
	OwnedFx = { "Classic" },
	EquippedFx = "Classic",
	Receipts = {}, -- recent developer product PurchaseIds

	-- Player level
	Level = 1,
	XP = 0, -- progress inside the current level
	Stats = {
		glass = 0,
		crystals = 0,
		props = 0,
		runs = 0,
		bestZone = 0,
		bestRunMeters = 0,
		bestMultiball = 0,
	},

	-- Daily missions: { { id, progress, claimed } }
	Missions = {},
	MissionRerolls = Config.MISSION_REROLLS_PER_DAY, -- left today (includes ExtraRerolls)
	ExtraRerolls = 0, -- bought with the ExtraReroll product; they don't expire at midnight
	MissionsReset = 0, -- os.time() of the next refresh

	-- Daily login streak
	StreakDay = 1, -- which Config.DailyStreak entry the next claim gives
	NextDaily = 0, -- os.time() when the daily reward can be claimed again
	StreakExpires = 0, -- claiming after this restarts at day 1

	-- Season pass
	SeasonId = Config.SEASON_ID,
	SeasonTier = 0,
	SeasonXP = 0,
	SeasonPremium = false,
	SeasonClaimed = { free = {}, premium = {} },

	StarterPackBought = false,
	-- Added to the next run: daily streak balls, and Revive / Ball Pack balls
	-- (saved here first so a purchase can never be lost; the device takes them
	-- back out with "UseBonusBalls" when it uses them right away).
	BonusBalls = 0,
	Boosts = {}, -- { [boostId] = count }: welcome gift, level ups, streak, season, shop
	WelcomeGiven = false, -- the one-time Config.WELCOME_BOOSTS gift was given
	Settings = table.clone(Config.DefaultSettings), -- volume, vibration, graphics...
	TutorialDone = false, -- finished or skipped the first-run tutorial
	Hints = {}, -- first-time tips already shown (keys of Config.Hints)

	-- "Wait! Free gift" (Config.LeaveGift)
	LeaveGiftNext = 0, -- os.time() when the gift can be claimed again
	LeaveGiftIndex = 0, -- which Config.LeaveGift.Rewards entry is next (counts from 0, cycles)
}

-- player -> {
--   data = {...}, canSave = bool,
--   dirty = bool (changed since the last save started),
--   saving = bool (a save is running right now), released = bool
-- }
local profiles = {}
local pendingSaves = 0

local function key(player)
	return "player_" .. player.UserId
end

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = deepCopy(v)
	end
	return copy
end

local function isDictionary(t)
	return next(t) ~= nil and #t == 0
end

-- Defaults + whatever was saved. A saved value of the wrong type is ignored,
-- and dictionaries (like Stats) get any missing keys filled in.
local function merge(defaults, saved)
	local data = deepCopy(defaults)
	if type(saved) ~= "table" then
		return data
	end
	for field, value in saved do
		local default = defaults[field]
		if default == nil then
			data[field] = deepCopy(value) -- unknown field: keep it as-is
		elseif type(value) == type(default) then
			if type(default) == "table" and isDictionary(default) then
				data[field] = merge(default, value)
			else
				data[field] = deepCopy(value)
			end
		end
	end
	return data
end

-- Publishing: attributes replicate to the client, which is how the UI reads progress.
-- Only the fields that changed are published, so JSON is only encoded when needed.

local function setJson(player, name, value)
	player:SetAttribute(name, HttpService:JSONEncode(value))
end

local publishers = {
	Best = function(player, data)
		player:SetAttribute("Best", data.Best)
		local leaderstats = player:FindFirstChild("leaderstats")
		if leaderstats then
			leaderstats.Best.Value = data.Best
		end
	end,
	Gems = function(player, data)
		player:SetAttribute("Gems", data.Gems)
		local leaderstats = player:FindFirstChild("leaderstats")
		if leaderstats then
			leaderstats.Gems.Value = data.Gems
		end
	end,
	Level = function(player, data)
		player:SetAttribute("Level", data.Level)
		player:SetAttribute("XPNeeded", Config.xpForLevel(data.Level))
	end,
	OwnedSkins = function(player, data)
		setJson(player, "OwnedSkins", data.OwnedSkins)
	end,
	OwnedFx = function(player, data)
		setJson(player, "OwnedFx", data.OwnedFx)
	end,
	Stats = function(player, data)
		setJson(player, "Stats", data.Stats)
	end,
	Boosts = function(player, data)
		setJson(player, "Boosts", data.Boosts)
	end,
	Settings = function(player, data)
		setJson(player, "Settings", data.Settings)
	end,
	Hints = function(player, data)
		setJson(player, "Hints", data.Hints)
	end,
	SeasonClaimed = function(player, data)
		setJson(player, "SeasonClaimed", data.SeasonClaimed)
	end,
	Missions = function(player, data)
		setJson(player, "Missions", Progression.publicMissions(data))
	end,
	Receipts = function() end, -- private
}

-- Plain number/bool/string fields are copied straight to an attribute.
local function publishField(player, data, field)
	local publisher = publishers[field]
	if publisher then
		publisher(player, data)
	elseif DEFAULT_DATA[field] ~= nil and type(data[field]) ~= "table" then
		player:SetAttribute(field, data[field])
	end
end

local function publishAll(player, data)
	for field in DEFAULT_DATA do
		publishField(player, data, field)
	end
end

local function defaultData()
	return deepCopy(DEFAULT_DATA)
end

function PlayerData.load(player)
	local ok, saved
	for attempt = 1, LOAD_ATTEMPTS do
		ok, saved = pcall(store.GetAsync, store, key(player))
		if ok then
			break
		end
		warn("Could not load data for", player.Name, "attempt", attempt, saved)
		task.wait(attempt * 2)
	end
	if not player.Parent then
		return -- left while we were loading
	end

	local data = if ok then merge(DEFAULT_DATA, saved) else defaultData()
	Progression.normalize(data, os.time())
	-- Players from before the tutorial existed already know how to play.
	if type(saved) == "table" and saved.TutorialDone == nil and data.Stats.runs > 0 then
		data.TutorialDone = true
	end

	-- If loading failed we never save, so we can't wipe their real data.
	profiles[player] = { data = data, canSave = ok, dirty = false, saving = false }
	publishAll(player, data)
	-- Tells the UI whether it's safe to sell things. Robux buttons stay off until
	-- DataLoaded is true; DataFailed shows "your save didn't load - rejoin".
	-- Set after publishAll, so every other attribute is already there.
	player:SetAttribute("DataFailed", not ok)
	player:SetAttribute("DataLoaded", ok)
end

function PlayerData.get(player)
	local profile = profiles[player]
	return profile and profile.data
end

function PlayerData.canSave(player)
	local profile = profiles[player]
	return profile ~= nil and profile.canSave
end

-- Marks the player's data as changed, so the next autosave writes it.
-- update/publish/addReceipt do this for you.
function PlayerData.markDirty(player)
	local profile = profiles[player]
	if profile then
		profile.dirty = true
	end
end

-- Sets fields and sends them to the client.
function PlayerData.update(player, changes)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.dirty = true
	for field, value in changes do
		profile.data[field] = value
	end
	for field in changes do
		publishField(player, profile.data, field)
	end
end

-- Sends fields to the client after changing the data table directly.
-- fields: a list of field names, e.g. { "Gems", "OwnedSkins" }.
function PlayerData.publish(player, fields)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.dirty = true
	for _, field in fields do
		publishField(player, profile.data, field)
	end
end

function PlayerData.hasReceipt(player, purchaseId)
	local data = PlayerData.get(player)
	return data ~= nil and table.find(data.Receipts, purchaseId) ~= nil
end

function PlayerData.addReceipt(player, purchaseId)
	local data = PlayerData.get(player)
	if not data then
		return
	end
	table.insert(data.Receipts, purchaseId)
	while #data.Receipts > MAX_RECEIPTS do
		table.remove(data.Receipts, 1)
	end
	PlayerData.markDirty(player)
end

-- Returns true only if the data (as it is right now) really reached the DataStore.
-- Only one save per player runs at a time: if one is already running we wait
-- for it, and only save again if something changed after it started.
function PlayerData.save(player)
	local profile = profiles[player]
	if not profile or not profile.canSave then
		return false
	end

	pendingSaves += 1
	while profile.saving do
		task.wait(0.1)
	end
	if profile.lastSaveOk and not profile.dirty then
		-- The save we waited for already included every change.
		pendingSaves -= 1
		return true
	end

	profile.saving = true
	profile.dirty = false -- changes from now on need another save
	local ok, err = pcall(store.SetAsync, store, key(player), profile.data, { player.UserId })
	profile.saving = false
	profile.lastSaveOk = ok
	pendingSaves -= 1

	if not ok then
		profile.dirty = true -- try again next time
		warn("Could not save data for", player.Name, err)
	end
	return ok
end

function PlayerData.release(player)
	local profile = profiles[player]
	if not profile or profile.released then
		return
	end
	profile.released = true
	profile.dirty = true -- always write once more when they leave
	PlayerData.save(player)
	profiles[player] = nil
end

-- Used when the server shuts down: saves everyone and waits until done.
function PlayerData.releaseAll(timeout)
	for player in profiles do
		task.spawn(PlayerData.release, player)
	end
	local deadline = os.clock() + timeout
	task.wait()
	while pendingSaves > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

-- Saves changed profiles every AUTOSAVE_INTERVAL seconds, spread out over the
-- interval so all players don't hit the DataStore at the same moment.
-- Started once by Main.
local autosaveStarted = false
function PlayerData.startAutosave()
	if autosaveStarted then
		return
	end
	autosaveStarted = true
	task.spawn(function()
		while true do
			local due = {}
			for player, profile in profiles do
				if profile.dirty and profile.canSave and not profile.released and not profile.saving then
					table.insert(due, player)
				end
			end
			if #due == 0 then
				task.wait(AUTOSAVE_INTERVAL)
			else
				local gap = AUTOSAVE_INTERVAL / #due
				for _, player in due do
					local profile = profiles[player]
					if profile and profile.dirty and not profile.released then
						task.spawn(PlayerData.save, player)
					end
					task.wait(gap)
				end
			end
		end
	end)
end

-- Calls fn(player, data) for everyone whose data is loaded.
function PlayerData.forEach(fn)
	for player, profile in profiles do
		if not profile.released then
			fn(player, profile.data)
		end
	end
end

return PlayerData
