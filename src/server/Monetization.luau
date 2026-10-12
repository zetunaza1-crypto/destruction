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
		if not data then
			return false
		end
		PlayerData.update(player, { Gems = data.Gems + Config.Products.GemPack.Gems })
		PlayerData.save(player)
		return true
	end,
}

local Monetization = {}

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

local function processReceipt(receipt)
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		-- They left before we could give it to them. Roblox will retry later.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	for productKey, product in Config.Products do
		if product.Id ~= 0 and product.Id == receipt.ProductId then
			local reward = serverRewards[productKey]
			if reward and not reward(player) then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			Remotes.PurchaseGranted:FireClient(player, productKey)
			return Enum.ProductPurchaseDecision.PurchaseGranted
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
