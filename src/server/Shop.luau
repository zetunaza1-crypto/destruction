--[[
	Gem shop (ball skins + shatter effects + boosts), daily streak, mission and season
	pass claims. The client asks through the ShopRequest RemoteFunction:
	ShopRequest:InvokeServer(action, argument) -> (ok, message).
	Every check happens here; the client is never trusted.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local PlayerData = require(script.Parent.PlayerData)
local Progression = require(script.Parent.Progression)

local Remotes = ReplicatedStorage.Remotes

local Shop = {}

local function fireAll(player, events)
	for _, event in events do
		Progression.fire(player, event)
	end
end

local function reward(player, text)
	Progression.fire(player, { type = "Reward", text = text })
end

-- Items with Price 0 and a Source (level, season, starter pack...) can't be
-- bought: they're unlocked another way.
local function checkBuyable(item, owned)
	if owned then
		return false, "You already own " .. item.Name
	end
	if item.Source and item.Price <= 0 then
		return false, "Unlocked by " .. item.Source
	end
	return true
end

local actions = {}

function actions.BuySkin(player, data, skinId)
	local skin = Progression.findSkin(skinId)
	if not skin then
		return false, "That skin doesn't exist"
	end
	local ok, message = checkBuyable(skin, Progression.ownsSkin(data, skin.Id))
	if not ok then
		return false, message
	end
	if data.Gems < skin.Price then
		return false, "Not enough gems"
	end

	local ownedSkins = table.clone(data.OwnedSkins)
	table.insert(ownedSkins, skin.Id)
	PlayerData.update(player, {
		Gems = data.Gems - skin.Price,
		OwnedSkins = ownedSkins,
		EquippedSkin = skin.Id,
	})
	return true, skin.Name .. " unlocked"
end

function actions.EquipSkin(player, data, skinId)
	local skin = Progression.findSkin(skinId)
	if not skin or not Progression.ownsSkin(data, skin.Id) then
		return false, "You don't own that skin"
	end
	PlayerData.update(player, { EquippedSkin = skin.Id })
	return true
end

function actions.BuyFx(player, data, fxId)
	local fx = Progression.findFx(fxId)
	if not fx then
		return false, "That effect doesn't exist"
	end
	local ok, message = checkBuyable(fx, Progression.ownsFx(data, fx.Id))
	if not ok then
		return false, message
	end
	if data.Gems < fx.Price then
		return false, "Not enough gems"
	end

	local ownedFx = table.clone(data.OwnedFx)
	table.insert(ownedFx, fx.Id)
	PlayerData.update(player, {
		Gems = data.Gems - fx.Price,
		OwnedFx = ownedFx,
		EquippedFx = fx.Id,
	})
	return true, fx.Name .. " unlocked"
end

function actions.EquipFx(player, data, fxId)
	local fx = Progression.findFx(fxId)
	if not fx or not Progression.ownsFx(data, fx.Id) then
		return false, "You don't own that effect"
	end
	PlayerData.update(player, { EquippedFx = fx.Id })
	return true
end

-- One boost into the inventory, paid with gems (Config.Boosts[id].Gems).
function actions.BuyBoost(player, data, boostId)
	if not Progression.isBoost(boostId) then
		return false, "That boost doesn't exist"
	end
	local boost = Config.Boosts[boostId]
	local price = boost.Gems
	if type(price) ~= "number" or price <= 0 then
		return false, "That boost can't be bought with gems"
	end
	if data.Gems < price then
		return false, "Not enough gems"
	end

	data.Gems -= price
	Progression.addBoost(data, boostId, 1)
	PlayerData.publish(player, { "Gems", "Boosts" })
	return true, boost.Name .. " boost added"
end

function actions.ClaimDaily(player, data)
	local ok, message = Progression.claimDaily(data, os.time())
	if ok then
		PlayerData.publish(player, Progression.DAILY_FIELDS)
		reward(player, message)
	end
	return ok, message
end

-- New missions might be due (the player kept the game open past midnight).
local function refreshMissions(player, data)
	if Progression.refreshMissions(data, os.time()) then
		PlayerData.publish(player, Progression.MISSION_FIELDS)
	end
end

function actions.ClaimMission(player, data, missionId)
	if type(missionId) ~= "string" then
		return false, "Mission not found"
	end
	refreshMissions(player, data)
	local ok, message, events = Progression.claimMission(data, missionId)
	if ok then
		PlayerData.publish(player, { "Missions" })
		PlayerData.publish(player, Progression.XP_FIELDS)
		reward(player, message)
		fireAll(player, events)
	end
	return ok, message
end

function actions.RerollMission(player, data, missionId)
	if type(missionId) ~= "string" then
		return false, "Mission not found"
	end
	refreshMissions(player, data)
	local ok, message = Progression.rerollMission(data, missionId)
	if ok then
		PlayerData.publish(player, Progression.MISSION_FIELDS)
	end
	return ok, message
end

-- argument: { track = "Free" | "Premium", tier = number }
-- Settings come from the client: keep only known keys with the right type/range.
function actions.SaveSettings(player, data, incoming)
	if type(incoming) ~= "table" then
		return false
	end
	local clean = table.clone(data.Settings)
	for key, default in Config.DefaultSettings do
		local value = incoming[key]
		if type(value) == type(default) then
			if type(value) == "number" then
				if value == value then -- not NaN
					clean[key] = math.clamp(value, 0, 1)
				end
			elseif key == "graphics" then
				if table.find(Config.GRAPHICS_OPTIONS, value) then
					clean[key] = value
				end
			else
				clean[key] = value
			end
		end
	end
	PlayerData.update(player, { Settings = clean })
	return true
end

function actions.FinishTutorial(player, data)
	if data.TutorialDone then
		return true
	end
	PlayerData.update(player, { TutorialDone = true })
	return true
end

function actions.SeenHint(player, data, hintId)
	if type(hintId) ~= "string" or not Config.Hints[hintId] then
		return false, "Unknown tip"
	end
	if table.find(data.Hints, hintId) then
		return true
	end
	local hints = table.clone(data.Hints)
	table.insert(hints, hintId)
	PlayerData.update(player, { Hints = hints })
	return true
end

function actions.ClaimSeasonTier(player, data, request)
	local ok, message = Progression.claimSeasonTier(data, request)
	if ok then
		PlayerData.publish(player, { "SeasonClaimed" })
		PlayerData.publish(player, Progression.REWARD_FIELDS)
		reward(player, message)
	end
	return ok, message
end

-- Lets Main add actions that need the player's current run
-- (UseBoostNow, ResumeRun). handler(player, data, argument) -> (ok, message).
-- Like every action here, it must not yield.
function Shop.addAction(name, handler)
	actions[name] = handler
end

-- One request at a time per player, so spamming can't double-spend.
local busy = {}

function Shop.init()
	Remotes.ShopRequest.OnServerInvoke = function(player, action, argument)
		local handler = type(action) == "string" and actions[action]
		local data = PlayerData.get(player)
		if not handler or not data then
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
		-- No save here: changes are marked dirty and the autosave writes them
		-- (saving on every click would use up the DataStore's write budget).
		return success == true, message
	end
end

function Shop.release(player)
	busy[player] = nil
end

return Shop
