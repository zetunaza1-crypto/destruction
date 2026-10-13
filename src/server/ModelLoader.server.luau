--[[
	Loads the uploaded Blender models (Config.Models) into
	ReplicatedStorage.ModelLibrary so every player's device can clone them.
	Premium ball models (Config.BallModels) go into ModelLibrary.Balls.
	Models must be owned by the same account/group that owns the game.
]]

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local library = Instance.new("Folder")
library.Name = "ModelLibrary"
library.Parent = ReplicatedStorage

local balls = Instance.new("Folder")
balls.Name = "Balls"
balls.Parent = library

-- Loads one model asset (in its own thread) and puts it in `folder` as `name`.
local function load(folder, name, assetId)
	if assetId == 0 then
		return
	end
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
		model.Parent = folder
	end)
end

for name, assetId in Config.Models do
	load(library, name, assetId)
end
for name, assetId in Config.BallModels or {} do
	load(balls, name, assetId)
end
