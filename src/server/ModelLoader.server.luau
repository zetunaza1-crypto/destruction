--[[
	Loads the uploaded Blender models (Config.Models) into
	ReplicatedStorage.ModelLibrary so every player's device can clone them.
	Models must be owned by the same account/group that owns the game.
]]

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local library = Instance.new("Folder")
library.Name = "ModelLibrary"
library.Parent = ReplicatedStorage

for name, assetId in Config.Models do
	if assetId ~= 0 then
		task.spawn(function()
			local ok, container = pcall(InsertService.LoadAsset, InsertService, assetId)
			if not ok then
				warn("Could not load model", name, assetId, container)
				return
			end

			-- LoadAsset wraps the asset in a Model; unwrap a single inner Model.
			local model = container
			local children = container:GetChildren()
			if #children == 1 and children[1]:IsA("Model") then
				model = children[1]
				model.Parent = nil
				container:Destroy()
			end

			model.Name = name
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") then
					part.Anchored = true
				end
			end
			model.Parent = library
		end)
	end
end
