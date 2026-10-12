--[[
	Game passes and developer products.
	IDs come from Shared/Config. Anything with an ID of 0 is ignored.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local PlayerData = require(script.Parent.PlayerData)

local Remotes = ReplicatedStorage.Remotes

-- Products the server delivers itself. Everything else (balls) is delivered
-- to the player's device, because runs happen there.
local serverRewards = {
	GemPack = function(player)
		local data = PlayerData.get(player)
		data.Gems += Config.Products.GemPack.Gems
		PlayerData.update(player, { Gems = data.Gems })
		return true
	end,
}

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
			local reward = serverRewards[productKey]
			if reward then
				reward(player)
			end
			PlayerData.addReceipt(player, receipt.PurchaseId)

			-- Deliver right away so the player isn't left waiting on a slow DataStore.
			Remotes.PurchaseGranted:FireClient(player, productKey)
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
