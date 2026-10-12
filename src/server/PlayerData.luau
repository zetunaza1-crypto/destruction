--[[
	Loads and saves each player's progress (best distance + gems).
	Note: DataStores only work in Studio if "Enable Studio Access to
	API Services" is turned on in Game Settings > Security.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local PlayerData = {}

local store = DataStoreService:GetDataStore("PlayerData_v1")

local DEFAULT_DATA = {
	Best = 0, -- meters
	Gems = 0,
	Checkpoint = 0, -- highest zone reached
	OwnedSkins = { "Default" },
	EquippedSkin = "Default",
	NextDaily = 0, -- os.time() when the daily reward can be claimed again
}

-- player -> { data = {...}, canSave = bool }
local profiles = {}

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

function PlayerData.load(player)
	local ok, saved = pcall(store.GetAsync, store, key(player))
	if not ok then
		warn("Could not load data for", player.Name, saved)
	end

	local data = table.clone(DEFAULT_DATA)
	data.OwnedSkins = table.clone(DEFAULT_DATA.OwnedSkins)
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

function PlayerData.save(player)
	local profile = profiles[player]
	if not profile or not profile.canSave then
		return
	end
	local ok, err = pcall(store.SetAsync, store, key(player), profile.data)
	if not ok then
		warn("Could not save data for", player.Name, err)
	end
end

function PlayerData.release(player)
	PlayerData.save(player)
	profiles[player] = nil
end

function PlayerData.saveAll()
	for player in profiles do
		task.spawn(PlayerData.save, player)
	end
end

return PlayerData
