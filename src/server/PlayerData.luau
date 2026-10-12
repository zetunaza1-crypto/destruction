--[[
	Loads and saves each player's progress (best distance, gems, skins...).
	Note: DataStores only work in Studio if "Enable Studio Access to
	API Services" is turned on in Game Settings > Security.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local PlayerData = {}

local store = DataStoreService:GetDataStore("PlayerData_v1")

local LOAD_ATTEMPTS = 3
local MAX_RECEIPTS = 50 -- remembered purchase IDs, so a retried receipt is never paid twice

local DEFAULT_DATA = {
	Best = 0, -- meters
	Gems = 0,
	Checkpoint = 0, -- highest zone reached
	OwnedSkins = { "Default" },
	EquippedSkin = "Default",
	NextDaily = 0, -- os.time() when the daily reward can be claimed again
	Receipts = {}, -- recent developer product PurchaseIds
}

-- player -> { data = {...}, canSave = bool }
local profiles = {}
local pendingSaves = 0

local function key(player)
	return "player_" .. player.UserId
end

local function publish(player, data)
	-- Attributes replicate to the client, which is how the UI reads progress.
	player:SetAttribute("Best", data.Best)
	player:SetAttribute("Gems", data.Gems)
	player:SetAttribute("Checkpoint", data.Checkpoint)
	player:SetAttribute("OwnedSkins", HttpService:JSONEncode(data.OwnedSkins))
	player:SetAttribute("EquippedSkin", data.EquippedSkin)
	player:SetAttribute("NextDaily", data.NextDaily)

	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		leaderstats.Best.Value = data.Best
		leaderstats.Gems.Value = data.Gems
	end
end

local function defaultData()
	local data = table.clone(DEFAULT_DATA)
	data.OwnedSkins = table.clone(DEFAULT_DATA.OwnedSkins)
	data.Receipts = {}
	return data
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

	local data = defaultData()
	if ok and type(saved) == "table" then
		for field, value in saved do
			data[field] = value
		end
	end

	-- If loading failed we never save, so we can't wipe their real data.
	profiles[player] = { data = data, canSave = ok }
	publish(player, data)
end

function PlayerData.get(player)
	local profile = profiles[player]
	return profile and profile.data
end

function PlayerData.canSave(player)
	local profile = profiles[player]
	return profile ~= nil and profile.canSave
end

function PlayerData.update(player, changes)
	local profile = profiles[player]
	if not profile then
		return
	end
	for field, value in changes do
		profile.data[field] = value
	end
	publish(player, profile.data)
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

return PlayerData
