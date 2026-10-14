--[[
	Builds each player's first-person arms from their avatar, made safe.

	Marketplace avatars can be huge, tiny, spiky or covered in accessories, so
	the arms are NOT a copy of the avatar. Instead a brand-new, empty
	HumanoidDescription gets only what we allow (a whitelist):
	  KEPT     the six body colours, the classic Shirt (and Pants, harmless:
	           the legs are removed anyway)
	  RESET    body parts (Head, Torso, arms, legs) = 0 -> standard blocky parts
	           scales: Height / Width / Depth / Head = 1, BodyType = 0, Proportion = 0
	           every accessory, hair, hat, face accessory, layered clothing = none
	           Face = 0, T-shirt = 0, every animation = 0
	From that, Roblox builds a plain R6 model, which is then cut down to just
	the two arms + Humanoid + Shirt + Body Colors (Shared/ViewmodelRig.strip),
	with the arms forced to the standard 1 x 2 x 1 size.

	The result goes into ReplicatedStorage.ViewmodelRigs as a Model named by the
	player's UserId (the client clones it, see Client/Viewmodel.luau). It is
	removed when they leave. If anything fails (avatar service down, Studio test
	player...), the player gets plain default arms instead.

	Players:GetHumanoidDescriptionFromUserId and
	Players:CreateHumanoidModelFromDescription only work on the server, which is
	why this is a server script.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ViewmodelRig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ViewmodelRig"))

local FETCH_ATTEMPTS = 3 -- first try + 2 retries
local RETRY_DELAY = 2 -- seconds between tries

local BODY_COLORS = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }
local BODY_PARTS = { "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }
local ACCESSORIES = {
	"HatAccessory",
	"HairAccessory",
	"FaceAccessory",
	"NeckAccessory",
	"ShouldersAccessory",
	"FrontAccessory",
	"BackAccessory",
	"WaistAccessory",
}
local ANIMATIONS = {
	"ClimbAnimation",
	"FallAnimation",
	"IdleAnimation",
	"JumpAnimation",
	"MoodAnimation",
	"RunAnimation",
	"SwimAnimation",
	"WalkAnimation",
}
local SCALES = {
	HeightScale = 1,
	WidthScale = 1,
	DepthScale = 1,
	HeadScale = 1,
	BodyTypeScale = 0,
	ProportionScale = 0,
}

local folder = ReplicatedStorage:FindFirstChild(ViewmodelRig.FOLDER_NAME)
if not folder then
	folder = Instance.new("Folder")
	folder.Name = ViewmodelRig.FOLDER_NAME
	folder.Parent = ReplicatedStorage
end

-- Sets one property, ignoring properties this Roblox version doesn't have.
local function trySet(instance, property, value)
	pcall(function()
		instance[property] = value
	end)
end

local function tryGet(instance, property)
	local ok, value = pcall(function()
		return instance[property]
	end)
	return if ok then value else nil
end

-- A clothing asset id we can trust: a whole number >= 0.
local function clothingId(value)
	if type(value) ~= "number" or value ~= value or value < 0 or value % 1 ~= 0 then
		return 0
	end
	return value
end

-- The player's avatar description (nil if Roblox couldn't give it).
local function fetchDescription(userId)
	for attempt = 1, FETCH_ATTEMPTS do
		local ok, description = pcall(Players.GetHumanoidDescriptionFromUserId, Players, userId)
		if ok and typeof(description) == "Instance" and description:IsA("HumanoidDescription") then
			return description
		end
		warn("[ViewmodelRigs] avatar for", userId, "not loaded (try " .. attempt .. "):", description)
		if attempt < FETCH_ATTEMPTS then
			task.wait(RETRY_DELAY)
		end
	end
	return nil
end

-- A brand-new description with only the allowed things copied over.
local function cleanDescription(source)
	local clean = Instance.new("HumanoidDescription")

	-- Kept: skin colours and classic clothing.
	for _, property in BODY_COLORS do
		local color = tryGet(source, property)
		if typeof(color) == "Color3" then
			trySet(clean, property, color)
		end
	end
	trySet(clean, "Shirt", clothingId(tryGet(source, "Shirt")))
	trySet(clean, "Pants", clothingId(tryGet(source, "Pants")))

	-- Reset (already the defaults on a new description, set anyway so it's
	-- guaranteed whatever Roblox's defaults are).
	for _, property in BODY_PARTS do
		trySet(clean, property, 0)
	end
	for property, value in SCALES do
		trySet(clean, property, value)
	end
	for _, property in ACCESSORIES do
		trySet(clean, property, "")
	end
	for _, property in ANIMATIONS do
		trySet(clean, property, 0)
	end
	trySet(clean, "Face", 0)
	trySet(clean, "GraphicTShirt", 0)
	-- Layered clothing and any other accessories.
	pcall(function()
		clean:SetAccessories({}, true)
	end)
	return clean
end

-- Arms from the cleaned avatar, or nil if Roblox couldn't build them.
local function buildAvatarRig(description, name)
	local clean = cleanDescription(description)
	local ok, model = pcall(Players.CreateHumanoidModelFromDescription, Players, clean, Enum.HumanoidRigType.R6)
	clean:Destroy()
	if not ok or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn("[ViewmodelRigs] could not build arms:", model)
		return nil
	end
	if not ViewmodelRig.strip(model) then
		model:Destroy()
		return nil
	end
	for _, armName in ViewmodelRig.ARM_NAMES do
		model[armName].Size = ViewmodelRig.ARM_SIZE
	end
	model.Name = name
	model:SetAttribute("Default", false)
	return model
end

local function setup(player)
	local userId = player.UserId
	local name = tostring(userId)
	local rig = nil

	-- Studio test players have UserIds <= 0 and no avatar: they get default arms.
	if userId > 0 then
		local description = fetchDescription(userId)
		if description then
			local ok, result = pcall(buildAvatarRig, description, name)
			if ok then
				rig = result
			else
				warn("[ViewmodelRigs] could not build arms:", result)
			end
			description:Destroy()
		end
	end
	if not rig then
		rig = ViewmodelRig.buildDefault(name)
	end

	-- They may have left while the avatar was loading.
	if player.Parent ~= Players then
		rig:Destroy()
		return
	end
	local old = folder:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	rig.Parent = folder
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(setup, player)
end)
for _, player in Players:GetPlayers() do
	task.spawn(setup, player)
end

Players.PlayerRemoving:Connect(function(player)
	local rig = folder:FindFirstChild(tostring(player.UserId))
	if rig then
		rig:Destroy()
	end
end)
