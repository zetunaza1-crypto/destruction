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

-- Gems given instead when a StreakSaver is bought while the streak is fine.
-- Never less than the same Robux buys as gems (Gem Top-Up: 150 gems for ~15 R$).
local STREAK_SAVER_FALLBACK_GEMS = 150
-- Gems given instead when Season Premium is bought by someone who already has it
-- this season (e.g. bought while their save was still loading). Worth ~199 R$.
local SEASON_PREMIUM_FALLBACK_GEMS = 3200

-- Game pass ownership checks (UserOwnsGamePassAsync) sometimes fail (throttling,
-- web outages), so each one is tried a few times before giving up.
local PASS_CHECK_ATTEMPTS = 4
local PASS_CHECK_WAIT = 2 -- seconds; doubles after each failed try
-- The "RecheckPasses" shop action (menu opened) runs at most this often per player.
local RECHECK_PASSES_COOLDOWN = 60

-- Products with their own rules. Boosts, balls and gem packs are below.
-- Every product is recorded in the save here; the device is also told with
-- PurchaseGranted (balls / boosts can then be used right away mid-run).
-- These must not yield: they run inside ProcessReceipt.
local serverRewards = {
	-- One-time offer. If it's somehow bought twice, the gems are still given
	-- (the skin and effect are already owned), so a purchase is never wasted.
	StarterPack = function(player, data)
		local product = Config.Products.StarterPack
		if data.StarterPackBought then
			-- Bought again (e.g. while their save was loading): the items are
			-- already theirs, so say clearly that the gems are what they got.
			data.Gems += product.Gems
			PlayerData.publish(player, { "Gems" })
			Progression.fire(player, {
				type = "Reward",
				text = "YOU ALREADY OWNED THE STARTER ITEMS: +" .. product.Gems .. " GEMS",
			})
			return
		end
		local text = Progression.grantReward(data, { Gems = product.Gems, Skin = product.Skin, Fx = product.Fx })
		data.StarterPackBought = true
		PlayerData.publish(player, Progression.REWARD_FIELDS)
		PlayerData.publish(player, { "StarterPackBought" })
		Progression.fire(player, { type = "Reward", text = "Starter pack: " .. text })
	end,

	-- Unlocks the premium track of the current season (tiers already reached
	-- become claimable right away).
	-- Already premium this season (bought twice, or while the save was loading):
	-- they get SEASON_PREMIUM_FALLBACK_GEMS instead, so the purchase isn't wasted.
	SeasonPremium = function(player, data)
		Progression.ensureSeason(data)
		if data.SeasonPremium then
			data.Gems += SEASON_PREMIUM_FALLBACK_GEMS
			PlayerData.publish(player, { "Gems" })
			Progression.fire(player, {
				type = "Reward",
				text = "YOU ALREADY HAD PREMIUM: +" .. SEASON_PREMIUM_FALLBACK_GEMS .. " GEMS INSTEAD",
			})
			return
		end
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

-- Boost products (BoostShield, BoostMagnet...): always go to the inventory.
-- If the player is mid-run, their device then asks to use it right away with
-- the "UseBoostNow" shop action (only the device knows for sure that it's running).
local function boostReward(boostId)
	return function(player, data)
		Progression.addBoost(data, boostId, 1)
		PlayerData.publish(player, { "Boosts" })
	end
end

-- Ball products (Revive, BallPack): the balls are always saved first as
-- BonusBalls, so they can never be lost (the player leaves, the purchase finishes
-- after a rejoin, the device is back in the menu...). If the device is mid-run or
-- on the game over screen it uses them right away and takes them back out with
-- the "UseBonusBalls" shop action; otherwise the next run starts with them.
local function ballsReward(amount)
	return function(player, data)
		data.BonusBalls += amount
		PlayerData.publish(player, { "BonusBalls" })
	end
end

-- Premium ball products (BallSupernova...): the ball is theirs forever and is
-- equipped right away. Already owned (bought twice, e.g. while an earlier save
-- failed)? They get gems worth what they really paid instead (receipt.CurrencySpent,
-- which follows regional pricing and Creator Hub price changes; Config's Robux is
-- only the fallback, e.g. for Studio test purchases that spend 0), so a purchase
-- is never wasted.
local function premiumBallReward(skin)
	return function(player, data, receipt)
		local name = string.upper(skin.Name)
		if Progression.ownsSkin(data, skin.Id) then
			local spent = tonumber(receipt and receipt.CurrencySpent)
			local robux = if spent and spent > 0 then spent else (tonumber(skin.Robux) or 0)
			local gems = math.floor(robux * Config.PREMIUM_BALL_REFUND_GEMS_PER_ROBUX)
			data.Gems += gems
			PlayerData.publish(player, { "Gems" })
			Progression.fire(player, {
				type = "Reward",
				text = "YOU ALREADY OWN " .. name .. ": +" .. gems .. " GEMS INSTEAD",
			})
			return
		end
		table.insert(data.OwnedSkins, skin.Id)
		data.EquippedSkin = skin.Id
		PlayerData.publish(player, { "OwnedSkins", "EquippedSkin" })
		Progression.fire(player, { type = "Reward", text = name .. " BALL UNLOCKED AND EQUIPPED" })
	end
end

-- Plain gem packs (GemPack, GemPackMedium, GemPackLarge...): any product with
-- Gems that has no special handler above.
local function rewardFor(productKey, product)
	if serverRewards[productKey] then
		return serverRewards[productKey]
	end
	if product.Skin then
		-- Only Premium balls are ever sold. Earned balls (Animated, e.g. Infinity,
		-- Smashbot) and every other skin are never given for Robux.
		local skin = Progression.findSkin(product.Skin)
		if skin and skin.Premium then
			return premiumBallReward(skin)
		end
		warn("Product", productKey, "sells a ball that isn't a premium (Robux) ball:", product.Skin)
		return nil
	end
	if product.Boost and Progression.isBoost(product.Boost) then
		return boostReward(product.Boost)
	end
	if type(product.Balls) == "number" and product.Balls > 0 then
		return ballsReward(math.floor(product.Balls))
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

-- Asks Roblox whether the player owns one pass, retrying a failed call a few
-- times (with growing waits) so a hiccup doesn't hide a pass they paid for.
-- Yields. Sets Pass_<Key> when they own it.
local function checkPass(player, passKey, pass)
	local wait = PASS_CHECK_WAIT
	for attempt = 1, PASS_CHECK_ATTEMPTS do
		if not player.Parent or Monetization.ownsPass(player, passKey) then
			return
		end
		local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, pass.Id)
		if ok then
			if owns then
				player:SetAttribute("Pass_" .. passKey, true)
			end
			return
		end
		warn("Could not check pass", passKey, "for", player.Name, "attempt", attempt, owns)
		if attempt < PASS_CHECK_ATTEMPTS then
			task.wait(wait)
			wait *= 2
		end
	end
end

-- Checks every pass the player doesn't have yet (each one in its own thread,
-- so one slow check doesn't hold up the others).
local function checkPasses(player)
	for passKey, pass in Config.GamePasses do
		if pass.Id ~= 0 and not Monetization.ownsPass(player, passKey) then
			task.spawn(checkPass, player, passKey, pass)
		end
	end
end

-- player -> os.clock() of the last "RecheckPasses".
local lastRecheck = {}

-- Shop action "RecheckPasses" (the menu opened): picks up a pass bought outside
-- this server (website, another server) without rejoining. At most once every
-- RECHECK_PASSES_COOLDOWN seconds per player. Doesn't yield (the checks run in
-- the background and set Pass_<Key> when they finish).
function Monetization.recheckPasses(player)
	local now = os.clock()
	local last = lastRecheck[player]
	if last and now - last < RECHECK_PASSES_COOLDOWN then
		return false, "Checked recently"
	end
	lastRecheck[player] = now
	checkPasses(player)
	return true
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
			if reward then
				reward(player, PlayerData.get(player), receipt)
			end
			PlayerData.addReceipt(player, receipt.PurchaseId)

			-- Deliver right away so the player isn't left waiting on a slow DataStore.
			-- (A revive no longer restarts the run's clock here: the device sends
			-- the "ResumeRun" shop action once it has really revived.)
			Remotes.PurchaseGranted:FireClient(player, productKey)

			-- Only tell Roblox we're done once the receipt is safely saved (purchases are
			-- the one thing saved right away instead of by the autosave).
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
		for passKey, pass in Config.GamePasses do
			if pass.Id ~= 0 and pass.Id == passId then
				if purchased then
					player:SetAttribute("Pass_" .. passKey, true)
				else
					-- Not bought now, but maybe they already own it and our check on
					-- join failed (Roblox then says "you already own this").
					-- Checking again turns it on right away.
					task.spawn(checkPass, player, passKey, pass)
				end
			end
		end
	end)

	Players.PlayerAdded:Connect(checkPasses)
	for _, player in Players:GetPlayers() do
		task.spawn(checkPasses, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastRecheck[player] = nil
	end)
end

return Monetization
