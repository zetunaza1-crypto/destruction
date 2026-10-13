--[[
	What a thrown ball looks like.

	Plain skins (Steel, Gold, Ruby...) are one ball part, like always.
	Premium balls (bought with Robux, Config.Skins entries with Premium = true)
	are little animated models: the Blender model from Config.BallModels once it
	has loaded (ReplicatedStorage.ModelLibrary.Balls), styled and animated by
	Shared.BallStyles. Until then a part-built version (glowing core, see-through
	shell, spinning rings / orbiting shards) so they already look special.

	BallFx.create(skinId, radius, options?) -> BasePart
		The ball to throw. Move it by setting its CFrame (it never needs to turn).
		Everything else (model parts, trail, particles, light) is welded to it /
		parented under it, so it follows on its own and :Destroy() removes it all.
		radius is the collision radius; premium balls are drawn 2.6x that across
		so their details read in flight.
		options = {
			mega = bool,       -- MegaBall boost ball (trail in the boost's color)
			lite = bool,       -- cheap version: no rings / particles / light (extra multiball balls)
			priority = bool,   -- the ball just thrown from the hand: always full detail
			                   -- (if the budget is full, the oldest full ball is toned down instead)
			trailScale = num,  -- trail lifetime multiplier (RunController: longer at high speed)
			parent = Instance,
		}
		Every ball has a trail in its skin's colors (premium ones longer and brighter).
	BallFx.destroy(ball)  -- use this instead of ball:Destroy() (frees its budget)
	BallFx.isPremium(skinId)
	BallFx.hasMesh(skinId) -- the Blender model has loaded
	BallFx.preview(skinId, diameter) -> { model, mesh, step(t), destroy() }
		Anchored copy for the shop's ViewportFrame. step(os.clock()) animates it.
	BallFx.held(skinId, diameter) -> { root, mesh, skinId, place(cframe, scale, t), destroy() }
		The ball in the player's hand (HeldBall.luau). Same look and animation as a
		thrown ball, with its particles but no trail / light. All parts are anchored
		and moved together with one BulkMoveTo per frame (it follows the camera).
		diameter = how big it's drawn across (studs); place() scales it (pop-in, mega).
	BallFx.impactStyle(skinId) -> { id, color, color2, rainbow, premium }
		The skin's colors for Shatter.skinBurst (the splash where a ball hits).

	Keeping phones smooth:
	  - one RenderStepped loop animates every live premium ball (no per-ball connections)
	  - at most MAX_FULL full-detail balls at once; more become lite versions
	  - particle rates are shared: the more full balls, the less each one emits
	  - only the newest MAX_LIGHTS balls get a light (none on Low graphics)
	  - balls far from the camera aren't animated
	  - trails: lifetime capped (TRAIL_MAX_LIFETIME), shorter on Low graphics
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BallStyles = require(Shared:WaitForChild("BallStyles"))
local Settings = require(script.Parent.Settings)

local BallFx = {}

local VISUAL_SCALE = 2.6 -- premium balls are drawn this many times the collision radius across
local MAX_FULL = { High = 8, Low = 4 } -- full-detail premium balls alive at once
local MAX_LIGHTS = { High = 3, Low = 0 } -- newest balls that get a PointLight
local PARTICLE_SHARE = 3 -- up to this many full balls emit at full rate; more share it
local MIN_RATE_SCALE = 0.15
local LOW_PARTICLE_SCALE = 0.4 -- Low graphics: fewer particles (and only the first emitter)
local ANIMATE_RANGE = 120 -- studs; balls further from the camera stop animating
local TAU = math.pi * 2
local MEGA_COLOR = Config.Boosts.MegaBall.Color

-- Trails: every ball leaves one in its skin's colors, so a skin reads even as a
-- far-away dot. Premium trails are longer and brighter.
local PLAIN_TRAIL_LIFETIME = 0.34 -- seconds (was 0.25, and only some skins had one)
local PLAIN_TRAIL_WIDTH = 0.8 -- x the ball's radius, above and below its center
local PREMIUM_TRAIL_LENGTH = 1.5 -- x the lifetime in BallStyles
local PREMIUM_TRAIL_WIDTH = 0.36 -- x the drawn diameter (was 0.3)
local TRAIL_BRIGHTNESS = { plain = 1.6, premium = 2.4 }
local TRAIL_MAX_LIFETIME = 0.8
local LOW_TRAIL_SCALE = 0.75 -- Low graphics: shorter trails
local HELD_PARTICLE_SCALE = 0.6 -- the ball in your hand sparkles a bit less than a thrown one

local TEXTURES = {
	sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	fire = "rbxasset://textures/particles/fire_main.dds",
}

-- Part-built look (no Blender model yet). Colors come from Config.Skins (Color, Shell, Ring).
-- rings: spinning ForceField hoops (a BlackHole "disk" is a flat glowing plate).
local FALLBACK = {
	Frostbite = { shell = Enum.Material.Glass, shellAlpha = 0.45, rings = 0, shards = 5 },
	CyberCore = { shell = Enum.Material.ForceField, shellAlpha = 0, rings = 2, shards = 0 },
	PlasmaCore = { shell = Enum.Material.ForceField, shellAlpha = 0, rings = 1, shards = 3 },
	MagmaHeart = { shell = Enum.Material.Glass, shellAlpha = 0.35, rings = 0, shards = 4 },
	BlackHole = { shell = Enum.Material.ForceField, shellAlpha = 0, rings = 0, disk = true, shards = 0 },
	Supernova = { shell = Enum.Material.ForceField, shellAlpha = 0, rings = 2, shards = 3 },
}
local DEFAULT_FALLBACK = { shell = Enum.Material.ForceField, shellAlpha = 0, rings = 1, shards = 0 }
local EMPTY_STYLE = { Diameter = 2, Parts = {}, Fx = { Particles = {} } }
local CENTER_PARTS = { "Core", "Heart", "Shell" } -- model parts that sit on the ball's center

local camera = workspace.CurrentCamera

-- Helpers -----------------------------------------------------------------------

local function graphicsLevel()
	local ok, level = pcall(Settings.graphicsLevel)
	return if ok and level == "Low" then "Low" else "High"
end

local function styleOf(skinId)
	local style = BallStyles[skinId]
	return if type(style) == "table" then style else EMPTY_STYLE
end

function BallFx.isPremium(skinId)
	local skin = Config.getSkin(skinId)
	return skin.Id == skinId and skin.Premium == true
end

local function meshTemplate(skinId)
	local library = ReplicatedStorage:FindFirstChild("ModelLibrary")
	local folder = library and library:FindFirstChild("Balls")
	return folder and folder:FindFirstChild(skinId)
end

function BallFx.hasMesh(skinId)
	return meshTemplate(skinId) ~= nil
end

-- Every part of a ball: no collisions, no queries (the game's raycasts skip it).
local function quiet(part, anchored)
	part.Anchored = anchored
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

local function newPart(name, shape, size, color, material, transparency)
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.Color = color
	part.Material = material
	part.Transparency = transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	quiet(part, false)
	return part
end

-- Trail.Brightness makes a trail glow brighter than its color alone. pcall: an
-- older client without the property just keeps the normal brightness.
local function setBrightness(trail, brightness)
	pcall(function()
		trail.Brightness = brightness
	end)
end

local function rainbowColors()
	local keys = {}
	for i = 0, 6 do
		table.insert(keys, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 0.8, 1)))
	end
	return ColorSequence.new(keys)
end

-- The invisible anchored center every premium ball hangs off.
local function newRoot(diameter)
	local root = Instance.new("Part")
	root.Name = "Ball"
	root.Shape = Enum.PartType.Ball
	root.Size = Vector3.one * math.max(0.2, diameter * 0.5)
	root.Transparency = 1
	quiet(root, true)
	root.CFrame = CFrame.new()
	return root
end

-- Welds `part` to the root at `rest` (its place in the ball's own space) and records
-- its animation, if any. Spins turn around the ball's center; pulses scale.
local function attach(proto, part, rest, spin, pulse)
	local joint = Instance.new("Weld")
	joint.Name = "Joint"
	joint.Part0 = proto.root
	joint.Part1 = part
	joint.C0 = rest
	joint.Parent = part
	part.CFrame = proto.root.CFrame * rest -- already in place (the preview has no welds)
	part.Parent = proto.root
	if spin or pulse then
		local axis = spin and spin.Axis
		table.insert(proto.anims, {
			name = part.Name,
			rest = rest,
			axis = if axis and axis.Magnitude > 1e-3 then axis.Unit else nil,
			rps = spin and tonumber(spin.Rps) or 0,
			pulse = pulse,
			baseSize = part.Size,
			phase = spin and spin.Phase or 0,
		})
	end
end

-- Prototypes ------------------------------------------------------------------------
-- Each look is built once per size and cloned for every throw.

local function buildFallback(proto, skin, style, diameter, lite)
	local look = FALLBACK[skin.Id] or DEFAULT_FALLBACK
	local parts = style.Parts or {}
	local coreStyle = parts.Core
	local core = newPart("Core", Enum.PartType.Ball, Vector3.one * diameter * 0.56, skin.Color, skin.Material or Enum.Material.Neon)
	attach(proto, core, CFrame.new(), nil, if lite or not coreStyle then nil else coreStyle.Pulse)

	local shellColor = skin.Shell or skin.Color
	local shell = newPart("Shell", Enum.PartType.Ball, Vector3.one * diameter * 0.78, shellColor, look.shell, look.shellAlpha)
	attach(proto, shell, CFrame.new())
	if lite then
		return
	end

	local ringColor = skin.Ring or skin.Color
	-- ForceField hoops glow mostly at their rim, so a thin disc reads as a ring.
	-- A cylinder's flat faces point along X; rest tilts it, the spin swings it around.
	local ringSpins = {
		{ tilt = CFrame.Angles(0, 0, math.rad(70)), axis = Vector3.yAxis, rps = 0.45 },
		{ tilt = CFrame.Angles(math.rad(60), math.rad(90), 0), axis = Vector3.new(1, 0.3, 0), rps = -0.6 },
	}
	for i = 1, math.min(look.rings or 0, #ringSpins) do
		local spec = ringSpins[i]
		local ring = newPart("Ring" .. i, Enum.PartType.Cylinder, Vector3.new(diameter * 0.04, diameter, diameter), ringColor, Enum.Material.ForceField)
		attach(proto, ring, spec.tilt, { Axis = spec.axis, Rps = spec.rps, Phase = i * 0.37 })
	end
	if look.disk then
		local disk = newPart("Disk", Enum.PartType.Cylinder, Vector3.new(diameter * 0.03, diameter, diameter), ringColor, Enum.Material.Neon, 0.35)
		attach(proto, disk, CFrame.Angles(0, 0, math.rad(80)), { Axis = Vector3.new(0.17, 1, 0), Rps = 0.8 })
	end
	-- Shards circling the ball on a tilted orbit.
	local count = look.shards or 0
	local orbitAxis = Vector3.new(0.3, 1, 0.15).Unit
	for i = 1, count do
		local angle = (i - 1) / count * TAU
		local shard = newPart(
			"Shard" .. i,
			Enum.PartType.Block,
			Vector3.new(diameter * 0.09, diameter * 0.2, diameter * 0.09),
			ringColor,
			Enum.Material.Neon
		)
		local offset = CFrame.fromAxisAngle(orbitAxis, angle) * CFrame.new(diameter * 0.5, 0, 0)
		attach(proto, shard, offset * CFrame.Angles(math.rad(25), angle, math.rad(35)), { Axis = orbitAxis, Rps = 0.7 })
	end
end

-- "<Id>_<Part>" -> "<Part>" ("Core", "RingA"...).
local function partKey(skinId, part)
	local name = part.Name
	local prefix = skinId .. "_"
	if string.sub(name, 1, #prefix) == prefix then
		return string.sub(name, #prefix + 1)
	end
	return string.match(name, "_(%w+)$") or name
end

local function buildMesh(proto, skinId, style, template, diameter, lite)
	local model = template:Clone()
	if model:IsA("BasePart") then
		local wrapper = Instance.new("Model")
		model.Parent = wrapper
		model = wrapper
	end
	if not model:IsA("Model") then
		model:Destroy()
		return false
	end
	-- Imported FBX units can be off: fit the model's longest side to its real
	-- size from the manifest (style.Size at style.Diameter), drawn at `diameter`.
	local _, size = model:GetBoundingBox()
	local longest = math.max(size.X, size.Y, size.Z)
	if longest < 1e-3 then
		model:Destroy()
		return false
	end
	local target = diameter
	local styleSize = style.Size
	if typeof(styleSize) == "Vector3" then
		local real = math.max(styleSize.X, styleSize.Y, styleSize.Z)
		target = diameter * real / (tonumber(style.Diameter) or 2)
	end
	model:ScaleTo(model:GetScale() * target / longest)

	local parts = {}
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			table.insert(parts, item)
		end
	end
	-- Center on the core / heart / shell (centered on the model's origin), or
	-- else the middle of the whole model.
	local center = nil
	for _, key in CENTER_PARTS do
		for _, part in parts do
			if partKey(skinId, part) == key then
				center = part.Position
				break
			end
		end
		if center then
			break
		end
	end
	if not center then
		center = model:GetBoundingBox().Position
	end

	local partStyles = style.Parts or {}
	-- Lite: only the parts that don't spin (usually the core and shell).
	local keepStatic = false
	if lite then
		for _, part in parts do
			local partStyle = partStyles[partKey(skinId, part)]
			if not (partStyle and partStyle.Spin) then
				keepStatic = true
			end
		end
	end

	for index, part in parts do
		local key = partKey(skinId, part)
		local partStyle = partStyles[key]
		if keepStatic and partStyle and partStyle.Spin then
			continue
		end
		if partStyle then
			part.Color = partStyle.Color
			part.Material = partStyle.Material
			part.Transparency = partStyle.Transparency or 0
		end
		quiet(part, false)
		part.Name = key .. "_" .. index -- unique, so a clone can find its animated parts
		local rest = CFrame.new(part.Position - center) * part.CFrame.Rotation
		if lite or not partStyle then
			attach(proto, part, rest)
		else
			attach(proto, part, rest, partStyle.Spin, partStyle.Pulse)
		end
	end
	model:Destroy()
	return true
end

local function addFx(proto, skin, style, diameter, lite, scale)
	local root = proto.root
	local fx = style.Fx or {}

	-- Trail: two attachments above / below the center (the root never turns).
	local trailStyle = fx.Trail
	local trailColor = if trailStyle then trailStyle.Color else (skin.Trail or skin.Color)
	local trailColor2 = if trailStyle then (trailStyle.Color2 or trailColor) else trailColor
	local width = diameter * PREMIUM_TRAIL_WIDTH * (if trailStyle then (trailStyle.WidthScale or 1) else 1)
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, width, 0)
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -width, 0)
	a1.Parent = root
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = (if trailStyle then (trailStyle.Lifetime or 0.3) else 0.3) * PREMIUM_TRAIL_LENGTH
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Color = ColorSequence.new(trailColor, trailColor2)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.55, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new(1, 0.25)
	setBrightness(trail, TRAIL_BRIGHTNESS.premium)
	trail.Parent = root
	if lite then
		return
	end

	-- Every emitter is built (prototypes are cached for the whole session, whatever
	-- the graphics level was then); on Low, rebalance() keeps only the first one on.
	local low = graphicsLevel() == "Low"
	for index, spec in fx.Particles or {} do
		local size = spec.Size or { 0.3, 0 }
		local lifetime = spec.Lifetime or { 0.3, 0.6 }
		local speed = spec.Speed or { 1, 3 }
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Particles" .. index
		emitter.Texture = TEXTURES[spec.Texture] or TEXTURES.sparkle
		emitter.Color = ColorSequence.new(spec.Color or skin.Color)
		emitter.Size = NumberSequence.new(size[1] * scale, size[2] * scale)
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Lifetime = NumberRange.new(lifetime[1], math.max(lifetime[1], lifetime[2]))
		emitter.Speed = NumberRange.new(speed[1] * scale, math.max(speed[1], speed[2]) * scale)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-120, 120)
		emitter.Drag = 3
		emitter.LightEmission = spec.LightEmission or 1
		emitter.Rate = spec.Rate or 10
		emitter.Enabled = not low or index == 1
		emitter.Parent = root
		table.insert(proto.emitters, { name = emitter.Name, rate = spec.Rate or 10, index = index })
	end

	local light = fx.Light
	if light and MAX_LIGHTS.High > 0 then
		local pointLight = Instance.new("PointLight")
		pointLight.Name = "Glow"
		pointLight.Color = light.Color
		pointLight.Range = math.clamp((light.Range or 8) * math.sqrt(scale), 4, 20)
		pointLight.Brightness = light.Brightness or 1
		pointLight.Shadows = false
		pointLight.Enabled = false -- switched on by the light budget
		pointLight.Parent = root
		proto.hasLight = true
	end
end

local prototypes = {} -- key -> prototype

local function prototypeFor(skin, radius, lite)
	local template = meshTemplate(skin.Id)
	local key = skin.Id .. ":" .. string.format("%.2f", radius) .. (if lite then ":lite" else "") .. (if template then ":mesh" else "")
	local proto = prototypes[key]
	if proto then
		return proto
	end

	local style = styleOf(skin.Id)
	local diameter = radius * VISUAL_SCALE
	local scale = diameter / (tonumber(style.Diameter) or 2)
	proto = { root = newRoot(diameter), anims = {}, emitters = {}, hasLight = false, mesh = false }
	if template then
		local ok, built = pcall(buildMesh, proto, skin.Id, style, template, diameter, lite)
		if ok and built then
			proto.mesh = true
		else
			if not ok then
				warn("[BallFx] could not use the model for", skin.Id, built)
			end
			proto.root:Destroy()
			proto = { root = newRoot(diameter), anims = {}, emitters = {}, hasLight = false, mesh = false }
		end
	end
	if not proto.mesh then
		buildFallback(proto, skin, style, diameter, lite)
	end
	addFx(proto, skin, style, diameter, lite, scale)
	prototypes[key] = proto
	return proto
end

-- Live premium balls + the one animation loop -------------------------------------------

local live = {} -- full-detail premium balls, oldest first
local entries = setmetatable({}, { __mode = "k" }) -- root -> entry

-- Shares particles and lights out over the live balls (newest get the light).
local function rebalance()
	local level = graphicsLevel()
	local count = #live
	local rateScale = math.clamp(PARTICLE_SHARE / math.max(count, 1), MIN_RATE_SCALE, 1)
	if level == "Low" then
		rateScale *= LOW_PARTICLE_SCALE
	end
	local lightsLeft = MAX_LIGHTS[level]
	for i = count, 1, -1 do
		local entry = live[i]
		for _, item in entry.emitters do
			item.emitter.Rate = item.rate * rateScale
			item.emitter.Enabled = level ~= "Low" or item.index == 1 -- Low: first emitter only
		end
		if entry.light then
			entry.light.Enabled = lightsLeft > 0
			lightsLeft -= 1
		end
	end
end

local function animate(entry, t, pulses)
	for _, anim in entry.anims do
		local c0 = anim.rest
		local pulse = anim.pulse
		if pulse and pulses then
			local s = pulse.Min + (pulse.Max - pulse.Min) * (0.5 + 0.5 * math.sin((t * pulse.Hz + entry.phase) * TAU))
			anim.part.Size = anim.baseSize * s
			c0 = CFrame.new(c0.Position * s) * c0.Rotation
		end
		if anim.axis then
			c0 = CFrame.fromAxisAngle(anim.axis, (t * anim.rps + anim.phase + entry.phase) * TAU) * c0
		end
		anim.joint.C0 = c0
	end
end

local function step()
	if #live == 0 then
		return
	end
	local t = os.clock()
	local cameraPosition = camera.CFrame.Position
	local pulses = graphicsLevel() ~= "Low"
	local removed = false
	for i = #live, 1, -1 do
		local entry = live[i]
		local root = entry.root
		if root.Parent == nil then
			table.remove(live, i)
			entries[root] = nil
			removed = true
		elseif (root.Position - cameraPosition).Magnitude < ANIMATE_RANGE then
			animate(entry, t, pulses)
		end
	end
	if removed then
		rebalance()
	end
end

local bound = false
local function ensureLoop()
	if bound then
		return
	end
	bound = true
	-- Right after RunController's step (Camera + 1), which moves the balls.
	RunService:BindToRenderStep("ShatterRunBallFx", Enum.RenderPriority.Camera.Value + 2, step)
end

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	camera = workspace.CurrentCamera or camera
end)

local function fullCount()
	local count = 0
	for _, entry in live do
		if entry.root.Parent then
			count += 1
		end
	end
	return count
end

-- Plain skins: one ball part (the look the game always had), now always with a
-- trail in the skin's colors. trail = false: no trail (the shop preview).
local function plainBall(skin, radius, mega, trail)
	local part = Instance.new("Part")
	part.Name = if mega then "MegaBall" else "Ball"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * radius * 2
	part.Material = skin.Material
	part.Color = skin.Color
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false

	if skin.Rainbow then
		part.Color = Color3.fromHSV(os.clock() % 1, 0.8, 1)
	end

	if trail ~= false then
		local width = radius * PLAIN_TRAIL_WIDTH
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, width, 0)
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -width, 0)
		a1.Parent = part

		local streak = Instance.new("Trail")
		streak.Attachment0 = a0
		streak.Attachment1 = a1
		streak.Lifetime = PLAIN_TRAIL_LIFETIME
		streak.LightEmission = 1
		streak.FaceCamera = true
		if mega then
			streak.Color = ColorSequence.new(MEGA_COLOR)
		elseif skin.Rainbow then
			streak.Color = rainbowColors()
		else
			-- Skin color into its trail color (dark skins like Void glow in their trail color).
			streak.Color = ColorSequence.new(skin.Trail or skin.Color, skin.Color:Lerp(skin.Trail or skin.Color, 0.6))
		end
		streak.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(0.6, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		streak.WidthScale = NumberSequence.new(1, 0.3)
		setBrightness(streak, TRAIL_BRIGHTNESS.plain)
		streak.Parent = part
	end
	return part
end

-- Over budget: the oldest full-detail ball stops animating and sparkling (it's
-- far down the corridor by now) so the one just thrown can be full detail.
local function demoteOldest()
	for i = 1, #live do
		local entry = live[i]
		if entry.root.Parent then
			table.remove(live, i)
			entries[entry.root] = nil
			for _, item in entry.emitters do
				item.emitter.Enabled = false
			end
			if entry.light then
				entry.light.Enabled = false
			end
			return true
		end
	end
	return false
end

-- Longer trails at high speed (options.trailScale), shorter on Low graphics.
local function scaleTrail(root, trailScale)
	local trail = root:FindFirstChildOfClass("Trail")
	if not trail then
		return
	end
	local scale = trailScale or 1
	if graphicsLevel() == "Low" then
		scale *= LOW_TRAIL_SCALE
	end
	trail.Lifetime = math.min(trail.Lifetime * scale, TRAIL_MAX_LIFETIME)
end

function BallFx.create(skinId, radius, options)
	options = options or {}
	local skin = Config.getSkin(skinId)
	local root
	if not skin.Premium then
		root = plainBall(skin, radius, options.mega)
		scaleTrail(root, options.trailScale)
		root.Parent = options.parent
		return root
	end

	local lite = options.lite == true
	if not lite then
		local most = MAX_FULL[graphicsLevel()]
		while fullCount() >= most do
			if not (options.priority and demoteOldest()) then
				lite = true
				break
			end
		end
	end
	local proto = prototypeFor(skin, radius, lite)
	root = proto.root:Clone()
	root.Name = if options.mega then "MegaBall" else "Ball"
	scaleTrail(root, options.trailScale)
	if not lite then
		local entry = { root = root, anims = {}, emitters = {}, light = nil, phase = math.random() }
		for _, anim in proto.anims do
			local part = root:FindFirstChild(anim.name)
			local joint = part and part:FindFirstChild("Joint")
			if joint then
				table.insert(entry.anims, {
					part = part,
					joint = joint,
					rest = anim.rest,
					axis = anim.axis,
					rps = anim.rps,
					pulse = anim.pulse,
					baseSize = anim.baseSize,
					phase = anim.phase,
				})
			end
		end
		for _, item in proto.emitters do
			local emitter = root:FindFirstChild(item.name)
			if emitter then
				table.insert(entry.emitters, { emitter = emitter, rate = item.rate, index = item.index })
			end
		end
		entry.light = if proto.hasLight then root:FindFirstChild("Glow") else nil
		table.insert(live, entry)
		entries[root] = entry
		ensureLoop()
		rebalance()
	end
	root.Parent = options.parent
	return root
end

function BallFx.destroy(ball)
	if ball == nil then
		return
	end
	local entry = entries[ball]
	if entry then
		entries[ball] = nil
		local index = table.find(live, entry)
		if index then
			table.remove(live, index)
		end
		ball:Destroy()
		rebalance()
		return
	end
	ball:Destroy()
end

-- Shop preview ----------------------------------------------------------------------------
-- An anchored copy (ViewportFrames have no physics, so the parts are placed directly).

function BallFx.preview(skinId, diameter)
	local skin = Config.getSkin(skinId)
	local radius = diameter / VISUAL_SCALE
	local model = Instance.new("Model")
	model.Name = "BallPreview"
	local anims = {}

	if skin.Premium then
		local proto = prototypeFor(skin, radius, false)
		local root = proto.root:Clone()
		for _, item in root:GetDescendants() do
			if item:IsA("BasePart") then
				item.Anchored = true
			elseif item:IsA("JointInstance") or item:IsA("Trail") or item:IsA("ParticleEmitter") or item:IsA("Light") then
				item:Destroy()
			end
		end
		-- Every part starts at its rest place (the clone keeps the prototype's).
		for _, anim in proto.anims do
			local part = root:FindFirstChild(anim.name)
			if part then
				table.insert(anims, {
					part = part,
					rest = anim.rest,
					axis = anim.axis,
					rps = anim.rps,
					pulse = anim.pulse,
					baseSize = anim.baseSize,
					phase = anim.phase,
				})
			end
		end
		root.Parent = model
		model.PrimaryPart = root
	else
		local part = plainBall(skin, diameter / 2, false, false) -- no trail in a viewport
		part.Parent = model
		model.PrimaryPart = part
	end

	local preview = { model = model, mesh = skin.Premium == true and BallFx.hasMesh(skinId) }
	function preview.step(t)
		for _, anim in anims do
			local c0 = anim.rest
			local pulse = anim.pulse
			if pulse then
				local s = pulse.Min + (pulse.Max - pulse.Min) * (0.5 + 0.5 * math.sin(t * pulse.Hz * TAU))
				anim.part.Size = anim.baseSize * s
				c0 = CFrame.new(c0.Position * s) * c0.Rotation
			end
			if anim.axis then
				c0 = CFrame.fromAxisAngle(anim.axis, (t * anim.rps + anim.phase) * TAU) * c0
			end
			anim.part.CFrame = c0
		end
	end
	function preview.destroy()
		model:Destroy()
	end
	return preview
end

-- The ball in your hand ----------------------------------------------------------------
-- Every part is anchored and placed directly each frame (one BulkMoveTo), so it
-- sticks to the camera exactly, with no physics or weld lag at full speed.

function BallFx.held(skinId, diameter)
	local skin = Config.getSkin(skinId)
	local held = { skinId = skin.Id, mesh = false }
	local low = graphicsLevel() == "Low"
	local parts = {} -- BulkMoveTo list (the root is last)
	local cframes = {}
	local items = {} -- one per visible part: { part, rest, baseSize, axis, rps, phase, pulse }
	local root
	local plain = nil

	if skin.Premium then
		local proto = prototypeFor(skin, diameter / VISUAL_SCALE, false)
		held.mesh = proto.mesh
		root = proto.root:Clone()
		local animByName = {}
		for _, anim in proto.anims do
			animByName[anim.name] = anim
		end
		for _, child in root:GetChildren() do
			if child:IsA("BasePart") then
				local joint = child:FindFirstChild("Joint")
				local rest = if joint then joint.C0 else CFrame.new()
				if joint then
					joint:Destroy()
				end
				child.Anchored = true
				local anim = animByName[child.Name]
				table.insert(items, {
					part = child,
					rest = rest,
					baseSize = child.Size,
					axis = anim and anim.axis,
					rps = anim and anim.rps or 0,
					phase = anim and anim.phase or 0,
					pulse = anim and anim.pulse,
				})
				table.insert(parts, child)
			end
		end
		-- No trail (it would smear as the camera moves) and no light (costly this
		-- close to the walls). Particles stay, locked to the ball so they travel with it.
		for _, item in root:GetDescendants() do
			if item:IsA("Trail") or item:IsA("Light") then
				item:Destroy()
			elseif item:IsA("ParticleEmitter") then
				local index = tonumber(string.match(item.Name, "%d+")) or 1
				item.LockedToPart = true
				item.Rate *= HELD_PARTICLE_SCALE * (if low then LOW_PARTICLE_SCALE else 1)
				item.Enabled = not low or index == 1
			end
		end
	else
		root = plainBall(skin, diameter / 2, false, false)
		plain = root
		table.insert(items, { part = root, rest = CFrame.new(), baseSize = root.Size, rps = 0, phase = 0 })
		table.insert(parts, root)
	end
	root.Name = "HeldBall"
	if skin.Premium then
		table.insert(parts, root) -- the invisible center carries the particles
	end
	held.root = root

	local lastScale = 1
	local pulses = not low
	-- cframe: the ball's center (and how it's turned). scale: 1 = `diameter` across.
	function held.place(cframe, scale, t)
		local resize = scale ~= lastScale
		lastScale = scale
		for i, item in items do
			local rest = item.rest
			local s = scale
			local pulse = item.pulse
			if pulse and pulses then
				s *= pulse.Min + (pulse.Max - pulse.Min) * (0.5 + 0.5 * math.sin(t * pulse.Hz * TAU))
				item.part.Size = item.baseSize * s
			elseif resize then
				item.part.Size = item.baseSize * s
			end
			local c0 = CFrame.new(rest.Position * s) * rest.Rotation
			if item.axis then
				c0 = CFrame.fromAxisAngle(item.axis, (t * item.rps + item.phase) * TAU) * c0
			end
			cframes[i] = cframe * c0
		end
		if plain then
			if skin.Rainbow then
				plain.Color = Color3.fromHSV((t * 0.2) % 1, 0.8, 1)
			end
		else
			cframes[#items + 1] = cframe
		end
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end

	function held.destroy()
		root:Destroy()
	end
	return held
end

-- Impact colors ---------------------------------------------------------------------------

local function luminance(color)
	return 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
end

-- The two colors a ball's impact splash uses: its trail color and its own color
-- (very dark balls like Void / Obsidian use a lighter mix so the splash shows).
function BallFx.impactStyle(skinId)
	local skin = Config.getSkin(skinId)
	local trail = styleOf(skin.Id).Fx and styleOf(skin.Id).Fx.Trail
	local color = if trail then trail.Color else (skin.Trail or skin.Color)
	local color2 = if trail and trail.Color2 then trail.Color2 else skin.Color
	if luminance(color2) < 0.25 then
		color2 = color:Lerp(Color3.new(1, 1, 1), 0.3)
	end
	if luminance(color) < 0.25 then
		color = color2
	end
	return {
		id = skin.Id,
		color = color,
		color2 = color2,
		rainbow = skin.Rainbow == true,
		premium = skin.Premium == true,
	}
end

-- Settings: switching graphics re-shares particles / lights right away.
Settings.changed:Connect(function(key)
	if key == "graphics" then
		rebalance()
	end
end)

return BallFx
