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
local MAX_RECEIPTS = 50 -- remembered purchase IDs, so a retried receipt is never paid twice

-- Every new field needs a default here. Old saves get missing fields filled in.
local DEFAULT_DATA = {
	Best = 0, -- meters (only runs started from the beginning count)
	Gems = 0,
	Checkpoint = 0, -- highest zone reached
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
	MissionRerolls = Config.MISSION_REROLLS_PER_DAY,
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
	BonusBalls = 0, -- added to the next run
	Boosts = {}, -- { [boostId] = count } earned from streak days / season tiers
}

-- player -> { data = {...}, canSave = bool }
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

	-- If loading failed we never save, so we can't wipe their real data.
	profiles[player] = { data = data, canSave = ok }
	publishAll(player, data)
end

function PlayerData.get(player)
	local profile = profiles[player]
	return profile and profile.data
end

function PlayerData.canSave(player)
	local profile = profiles[player]
	return profile ~= nil and profile.canSave
end

-- Sets fields and sends them to the client.
function PlayerData.update(player, changes)
	local profile = profiles[player]
	if not profile then
		return
	end
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
end

-- Returns true only if the data really reached the DataStore.
function PlayerData.save(player)
	local profile = profiles[player]
	if not profile or not profile.canSave then
		return false
	end

	pendingSaves += 1
	local ok, err = pcall(store.SetAsync, store, key(player), profile.data, { player.UserId })
	pendingSaves -= 1

	if not ok then
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

-- Calls fn(player, data) for everyone whose data is loaded.
function PlayerData.forEach(fn)
	for player, profile in profiles do
		if not profile.released then
			fn(player, profile.data)
		end
	end
end

return PlayerData
