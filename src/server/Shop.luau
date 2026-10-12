--[[
	Gem shop (ball skins) and the daily reward.
	The client asks through the ShopRequest RemoteFunction; every check happens here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local PlayerData = require(script.Parent.PlayerData)

local Remotes = ReplicatedStorage.Remotes

local Shop = {}

local function findSkin(skinId)
	for _, skin in Config.Skins do
		if skin.Id == skinId then
			return skin
		end
	end
	return nil
end

local function owns(data, skinId)
	return table.find(data.OwnedSkins, skinId) ~= nil
end

local actions = {}

function actions.BuySkin(player, data, skinId)
	local skin = findSkin(skinId)
	if not skin then
		return false, "That skin doesn't exist"
	end
	if owns(data, skinId) then
		return false, "You already own " .. skin.Name
	end
	if data.Gems < skin.Price then
		return false, "Not enough gems"
	end

	local ownedSkins = table.clone(data.OwnedSkins)
	table.insert(ownedSkins, skinId)
	PlayerData.update(player, {
		Gems = data.Gems - skin.Price,
		OwnedSkins = ownedSkins,
		EquippedSkin = skinId,
	})
	return true, skin.Name .. " unlocked"
end

function actions.EquipSkin(player, data, skinId)
	if not findSkin(skinId) or not owns(data, skinId) then
		return false, "You don't own that skin"
	end
	PlayerData.update(player, { EquippedSkin = skinId })
	return true
end

function actions.ClaimDaily(player, data)
	local now = os.time()
	if now < data.NextDaily then
		return false, "Come back later"
	end
	PlayerData.update(player, {
		Gems = data.Gems + Config.DAILY_REWARD_GEMS,
		NextDaily = now + Config.DAILY_REWARD_COOLDOWN,
	})
	return true, "+" .. Config.DAILY_REWARD_GEMS .. " gems"
end

-- One request at a time per player, so spamming can't double-spend.
local busy = {}

function Shop.init()
	Remotes.ShopRequest.OnServerInvoke = function(player, action, argument)
		local handler = actions[action]
		local data = PlayerData.get(player)
		if type(action) ~= "string" or not handler or not data then
			return false, "Try again in a moment"
		end
		if busy[player] then
			return false, "Slow down"
		end

		busy[player] = true
		local ok, success, message = pcall(handler, player, data, argument)
		busy[player] = nil

		if not ok then
			warn("Shop error:", success)
			return false, "Something went wrong"
		end
		if success then
			task.spawn(PlayerData.save, player)
		end
		return success, message
	end
end

function Shop.release(player)
	busy[player] = nil
end

return Shop
