--[[
	Game passes and developer products.
	IDs come from Shared/Config. Anything with an ID of 0 is ignored.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local PlayerData = require(script.Parent.PlayerData)
local Progression = require(script.Parent.Progression)

local Remotes = ReplicatedStorage.Remotes

local Monetization = {}

-- Set by Main: tries to use a bought boost on the player's current run right
-- away. Returns true if it did (false = no active run, or it can't stack).
Monetization.useBoostOnRun = nil

-- Gems given instead when a StreakSaver is bought while the streak is fine.
local STREAK_SAVER_FALLBACK_GEMS = 100

-- Products the server delivers itself. Everything else (balls) is delivered
-- to the player's device, because runs happen there.
-- These must not yield: they run inside ProcessReceipt.
local serverRewards = {
	-- One-time offer. If it's somehow bought twice, the gems are still given
	-- (the skin and effect are already owned), so a purchase is never wasted.
	StarterPack = function(player, data)
		local product = Config.Products.StarterPack
		local text = Progression.grantReward(data, { Gems = product.Gems, Skin = product.Skin, Fx = product.Fx })
		data.StarterPackBought = true
		PlayerData.publish(player, Progression.REWARD_FIELDS)
		PlayerData.publish(player, { "StarterPackBought" })
		Progression.fire(player, { type = "Reward", text = "Starter pack: " .. text })
	end,

	-- Unlocks the premium track of the current season (tiers already reached
	-- become claimable right away).
	SeasonPremium = function(player, data)
		Progression.ensureSeason(data)
		data.SeasonPremium = true
		PlayerData.publish(player, { "SeasonId", "SeasonTier", "SeasonXP", "SeasonClaimed", "SeasonPremium" })
		Progression.fire(player, { type = "Reward", text = "Premium season pass unlocked" })
	end,

	-- +1 mission reroll. Bought rerolls don't expire at midnight.
	ExtraReroll = function(player, data)
		if Progression.refreshMissions(data, os.time()) then
			PlayerData.publish(player, Progression.MISSION_FIELDS)
		end
		data.ExtraRerolls += 1
		data.MissionRerolls += 1
		PlayerData.publish(player, { "MissionRerolls", "ExtraRerolls" })
		Progression.fire(player, { type = "Reward", text = "+1 mission reroll" })
	end,

	-- Keeps a broken login streak going. If it wasn't broken (bought twice, or
	-- the client was out of date) they get gems instead: a purchase is never wasted.
	StreakSaver = function(player, data)
		local now = os.time()
		if Progression.saveStreak(data, now) then
			PlayerData.publish(player, Progression.DAILY_FIELDS)
			Progression.fire(player, { type = "Reward", text = "Streak saved: day " .. data.StreakDay .. " is waiting" })
		else
			data.Gems += STREAK_SAVER_FALLBACK_GEMS
			PlayerData.publish(player, { "Gems" })
			Progression.fire(player, {
				type = "Reward",
				text = "Your streak was safe: +" .. STREAK_SAVER_FALLBACK_GEMS .. " gems instead",
			})
		end
	end,
}

-- Boost products (BoostShield, BoostMagnet...): used on the current run if one is
-- going, otherwise added to the inventory. Returns whether it went to the run;
-- that is sent to the client with PurchaseGranted so it knows what to do.
local function boostReward(boostId)
	return function(player, data)
		if Monetization.useBoostOnRun and Monetization.useBoostOnRun(player, boostId) then
			return true
		end
		Progression.addBoost(data, boostId, 1)
		PlayerData.publish(player, { "Boosts" })
		return false
	end
end

-- Plain gem packs (GemPack, GemPackMedium, GemPackLarge...): any product with
-- Gems that has no special handler above.
local function rewardFor(productKey, product)
	if serverRewards[productKey] then
		return serverRewards[productKey]
	end
	if product.Boost and Progression.isBoost(product.Boost) then
		return boostReward(product.Boost)
	end
	if product.Gems then
		return function(player, data)
			data.Gems += product.Gems
			PlayerData.publish(player, { "Gems" })
		end
	end
	return nil
end

function Monetization.ownsPass(player, passKey)
	return player:GetAttribute("Pass_" .. passKey) == true
end

local function checkPasses(player)
	for passKey, pass in Config.GamePasses do
		if pass.Id ~= 0 then
			local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, pass.Id)
			if ok and owns then
				player:SetAttribute("Pass_" .. passKey, true)
			end
		end
	end
end

-- Roblox calls this for every developer product purchase, and keeps retrying
-- until we return PurchaseGranted. Each PurchaseId is only ever paid out once.
local function processReceipt(receipt)
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player or not PlayerData.get(player) then
		-- Not here (or still loading). Roblox will retry later.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not PlayerData.canSave(player) then
		-- Their data failed to load, so we couldn't keep a record of this. Try again later.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- Already paid out earlier in this session (an earlier save failed): just retry the save.
	if PlayerData.hasReceipt(player, receipt.PurchaseId) then
		return if PlayerData.save(player)
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else Enum.ProductPurchaseDecision.NotProcessedYet
	end

	for productKey, product in Config.Products do
		if product.Id ~= 0 and product.Id == receipt.ProductId then
			local reward = rewardFor(productKey, product)
			local info = nil -- extra detail for the client (boosts: used on the run right away?)
			if reward then
				info = reward(player, PlayerData.get(player))
			end
			PlayerData.addReceipt(player, receipt.PurchaseId)

			-- Deliver right away so the player isn't left waiting on a slow DataStore.
			Remotes.PurchaseGranted:FireClient(player, productKey, info)
			if Monetization.onProductGranted then
				Monetization.onProductGranted(player, productKey)
			end

			-- Only tell Roblox we're done once the receipt is safely saved.
			-- If the save fails, Roblox retries and hasReceipt() above stops a double payout.
			return if PlayerData.save(player)
				then Enum.ProductPurchaseDecision.PurchaseGranted
				else Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	warn("Unknown product purchased:", receipt.ProductId)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function Monetization.init()
	MarketplaceService.ProcessReceipt = processReceipt

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not purchased then
			return
		end
		for passKey, pass in Config.GamePasses do
			if pass.Id == passId then
				player:SetAttribute("Pass_" .. passKey, true)
			end
		end
	end)

	Players.PlayerAdded:Connect(checkPasses)
	for _, player in Players:GetPlayers() do
		task.spawn(checkPasses, player)
	end
end

return Monetization
