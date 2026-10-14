--[[
	The arms you see in first person (shared by the server and the client).

	Server (Server/ViewmodelRigs.server.luau): builds one arms model per player
	from a cleaned-up copy of their avatar and puts it in
	ReplicatedStorage.ViewmodelRigs, named by their UserId.
	Client (Client/Viewmodel.luau): clones it for the run and moves the arms with
	the camera.

	A rig is a Model with exactly:
	  "Left Arm", "Right Arm"  plain R6 arm blocks (anchored, no collisions)
	  Humanoid                 needed for the classic Shirt to show on the arms
	  Shirt                    (optional) the player's classic shirt
	  Body Colors              (optional) the player's skin colours
	Anything else is removed by ViewmodelRig.strip, on the server AND again on
	the client, so a strange avatar can never put anything else on screen.

	ViewmodelRig.strip(model) -> boolean   true when both arms are there
	ViewmodelRig.buildDefault(name) -> Model   plain arms in a neutral skin tone
]]

local ViewmodelRig = {}

ViewmodelRig.FOLDER_NAME = "ViewmodelRigs" -- in ReplicatedStorage
ViewmodelRig.ARM_NAMES = { "Left Arm", "Right Arm" }
ViewmodelRig.ARM_SIZE = Vector3.new(1, 2, 1) -- a standard blocky R6 arm
ViewmodelRig.DEFAULT_COLOR = Color3.fromRGB(234, 184, 146) -- neutral skin tone (default rig)

local function isArm(child)
	return child:IsA("BasePart") and (child.Name == "Left Arm" or child.Name == "Right Arm")
end

-- No collisions, no raycasts / touches, no shadows; moved by script only.
function ViewmodelRig.quietPart(part)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

-- A Humanoid that only draws clothing: no name tag, health bar, physics or animations.
local function quietHumanoid(humanoid)
	humanoid:ClearAllChildren() -- Animator, HumanoidDescription...
	pcall(function()
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end)
	pcall(function()
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end)
	pcall(function()
		humanoid.RequiresNeck = false
	end)
	pcall(function()
		humanoid.BreakJointsOnDeath = false
	end)
	pcall(function()
		humanoid.AutomaticScalingEnabled = false
	end)
	pcall(function()
		humanoid.EvaluateStateMachine = false
	end)
end

-- Keeps only the two arms, one Humanoid, one Shirt and one Body Colors.
-- Everything else (head, torso, legs, accessories, meshes, scripts, pants...)
-- is destroyed. Returns true when both arms are there.
function ViewmodelRig.strip(model)
	local kept = {}
	for _, child in model:GetChildren() do
		local kind = nil
		if isArm(child) then
			kind = child.Name
		elseif child:IsA("Humanoid") then
			kind = "Humanoid"
		elseif child:IsA("Shirt") then
			kind = "Shirt"
		elseif child:IsA("BodyColors") then
			kind = "BodyColors"
		end
		if kind and not kept[kind] then
			kept[kind] = child
		else
			child:Destroy()
		end
	end

	for _, armName in ViewmodelRig.ARM_NAMES do
		local arm = kept[armName]
		if arm then
			arm:ClearAllChildren() -- attachments, special meshes, decals
			ViewmodelRig.quietPart(arm)
			arm.Transparency = 0
		end
	end
	if kept.Humanoid then
		quietHumanoid(kept.Humanoid)
	end
	local right = kept["Right Arm"]
	if right then
		model.PrimaryPart = right
	end
	return kept["Left Arm"] ~= nil and right ~= nil
end

-- Plain arms in a neutral skin tone, used when the avatar can't be loaded.
function ViewmodelRig.buildDefault(name)
	local model = Instance.new("Model")
	model.Name = name
	for _, armName in ViewmodelRig.ARM_NAMES do
		local arm = Instance.new("Part")
		arm.Name = armName
		arm.Size = ViewmodelRig.ARM_SIZE
		arm.Color = ViewmodelRig.DEFAULT_COLOR
		arm.Material = Enum.Material.SmoothPlastic
		arm.TopSurface = Enum.SurfaceType.Smooth
		arm.BottomSurface = Enum.SurfaceType.Smooth
		ViewmodelRig.quietPart(arm)
		arm.Parent = model
	end
	local humanoid = Instance.new("Humanoid")
	quietHumanoid(humanoid)
	humanoid.Parent = model
	model.PrimaryPart = model:FindFirstChild("Right Arm")
	model:SetAttribute("Default", true)
	return model
end

return ViewmodelRig
