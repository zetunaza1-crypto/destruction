--[[
	Visual effects for breaking glass and collecting crystals.
	Glass panes are swapped for a grid of loose shards that fly apart.
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local Shatter = {}

local SHARD_SIZE = 2.5
local SHARD_LIFETIME = 2
local rng = Random.new()

function Shatter.glass(panel, hitPoint, push, parent)
	local size = panel.Size
	local columns = math.clamp(math.round(size.X / SHARD_SIZE), 2, 6)
	local rows = math.clamp(math.round(size.Y / SHARD_SIZE), 2, 6)
	local shardWidth = size.X / columns
	local shardHeight = size.Y / rows
	local reach = math.max(size.X, size.Y)

	for column = 1, columns do
		for row = 1, rows do
			local offset = Vector3.new(
				-size.X / 2 + shardWidth * (column - 0.5),
				-size.Y / 2 + shardHeight * (row - 0.5),
				0
			)

			local shard = Instance.new("Part")
			shard.Size = Vector3.new(
				shardWidth * rng:NextNumber(0.6, 0.95),
				shardHeight * rng:NextNumber(0.6, 0.95),
				size.Z
			)
			shard.CFrame = panel.CFrame * CFrame.new(offset) * CFrame.Angles(0, 0, rng:NextNumber(-0.6, 0.6))
			shard.Material = panel.Material
			shard.Color = panel.Color
			shard.Transparency = panel.Transparency
			shard.Reflectance = panel.Reflectance
			shard.CanCollide = false
			shard.CanQuery = false
			shard.CanTouch = false
			shard.CastShadow = false
			shard.Anchored = false
			shard.Parent = parent

			-- Shards near the impact fly out harder.
			local away = shard.Position - hitPoint
			local closeness = math.max(0, 1 - away.Magnitude / reach)
			local direction = if away.Magnitude > 0.01 then away.Unit else Vector3.zero
			shard.AssemblyLinearVelocity = direction * (8 + 30 * closeness) + push * (10 + 25 * closeness)
			shard.AssemblyAngularVelocity = rng:NextUnitVector() * rng:NextNumber(5, 15)

			Debris:AddItem(shard, SHARD_LIFETIME)
		end
	end

	panel:Destroy()
end

function Shatter.crystal(crystal)
	crystal.CanQuery = false
	local tween = TweenService:Create(crystal, TweenInfo.new(0.25), {
		Size = Vector3.zero,
		Transparency = 1,
	})
	tween.Completed:Connect(function()
		crystal:Destroy()
	end)
	tween:Play()
end

return Shatter
