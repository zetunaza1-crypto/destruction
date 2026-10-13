--[[
	Room decoration: gives every room details that match its zone (Config.Themes[].Style).
	TrackBuilder builds the bare shell (floor, ceiling, walls, ribs), then calls Decor.decorate.

	Golden rule: nothing here enters the flight path, the box in the middle of the corridor
	between knee and ceiling height (|x| < 6.5, 2 < y < 12 from the floor). Decor hugs the walls,
	lies on the floor or hangs above y = 12, so the player always sees the obstacles clearly.

	Kinds: "Wall" for solid decoration (balls bounce off), "Prop" for breakable glass.
	A breakable made of several parts is a Model with attribute Breakable = true:
	hitting any of its parts shatters the whole thing.

	Props that have a Blender model (Models.luau) use it through Kit:place / Kit:wallProp;
	when the model isn't loaded (ID 0 in Config.Models) those return nil and the
	part-built version below is made instead, exactly as before.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Models = require(script.Parent.Models)
local ModelStyles = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ModelStyles"))

local Decor = {}

local BAYS = { 5, 15, 25, 35, 45, 55, 65, 75 } -- wall bays between the ribs (depth into the room)
local SIDES = { -1, 1 }
local GATE_DEPTH = 5 -- where the zone entrance showpiece stands
local MIN_BREAKABLES = 3
local GLOBE_SPOTS = { 15, 35, 55 } -- ceiling spots for extra breakables when a room has too few

local Block = Enum.PartType.Block
local BallShape = Enum.PartType.Ball
local CylinderShape = Enum.PartType.Cylinder
local Material = Enum.Material

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- turns a cylinder's axis from X to Y
local ALONG_Z = CFrame.Angles(0, math.rad(90), 0) -- turns a cylinder's axis from X to Z
local QUARTER_TURN = math.rad(90)

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local METAL = Color3.fromRGB(150, 158, 170)

-- Simple line drawings, as segments { u1, v1, u2, v2 }: u = depth (positive = further down
-- the corridor), v = up. Used for neon signs, wall runes and floor runes.
local GLYPHS = {
	Arrow = { { -2, 0, 2, 0 }, { 2, 0, 0.8, 1.2 }, { 2, 0, 0.8, -1.2 } },
	Bolt = { { -1.6, 1.4, 0.3, 0.2 }, { 0.3, 0.2, -0.3, -0.2 }, { -0.3, -0.2, 1.6, -1.4 } },
	Diamond = { { 0, 1.4, 1.4, 0 }, { 1.4, 0, 0, -1.4 }, { 0, -1.4, -1.4, 0 }, { -1.4, 0, 0, 1.4 } },
	Chevrons = { { -1.8, 1.2, -0.6, 0 }, { -0.6, 0, -1.8, -1.2 }, { 0.2, 1.2, 1.4, 0 }, { 1.4, 0, 0.2, -1.2 } },
	Star = { { -1.5, 0, 1.5, 0 }, { 0, -1.5, 0, 1.5 }, { -1, -1, 1, 1 }, { -1, 1, 1, -1 } },
	Eye = { { -1.6, 0, 0, 1 }, { 0, 1, 1.6, 0 }, { 1.6, 0, 0, -1 }, { 0, -1, -1.6, 0 }, { 0, 0.35, 0, -0.35 } },
}
local GLYPH_NAMES = { "Arrow", "Bolt", "Diamond", "Chevrons", "Star", "Eye" }

-- Drawing kit ----------------------------------------------------------------------
-- Wraps builder.newPart with room coordinates: x across (0 = middle), y up from the floor,
-- d depth into the room (0 = room entrance, 80 = room end).

local Kit = {}
Kit.__index = Kit

local function newKit(builder, room, info)
	return setmetatable({
		newPart = builder.newPart,
		origin = builder.ORIGIN,
		half = builder.WIDTH / 2,
		height = builder.HEIGHT,
		length = builder.LENGTH,
		folder = room.folder,
		startZ = info.startZ,
		rng = info.rng,
		theme = info.theme,
		breakables = 0,
		maxBreakables = info.rng:NextInteger(5, 8),
	}, Kit)
end

function Kit:pos(x, y, d)
	return Vector3.new(self.origin.X + x, self.origin.Y + y, self.startZ - d)
end

function Kit:at(x, y, d)
	return CFrame.new(self:pos(x, y, d))
end

-- x of a point `inset` studs in front of the wall on `side` (-1 left, 1 right).
function Kit:wallX(side, inset)
	return side * (self.half - inset)
end

function Kit:random(min, max)
	return self.rng:NextNumber(min, max)
end

function Kit:chance(probability)
	return self.rng:NextNumber() < probability
end

function Kit:pick(list)
	return list[self.rng:NextInteger(1, #list)]
end

-- options = { { weight, value }, ... }
function Kit:pickWeighted(options)
	local total = 0
	for _, option in options do
		total += option[1]
	end
	local roll = self.rng:NextNumber() * total
	for _, option in options do
		roll -= option[1]
		if roll <= 0 then
			return option[2]
		end
	end
	return options[#options][2]
end

function Kit:part(parent, kind, shape, size, cframe, color, material, extra)
	local props = {
		Shape = shape,
		Size = size,
		CFrame = cframe,
		Color = color,
		Material = material or Material.SmoothPlastic,
	}
	if extra then
		for name, value in extra do
			props[name] = value
		end
	end
	return self.newPart(parent, kind, props)
end

-- Solid decoration ----------------------------------------------------------------

function Kit:block(size, cframe, color, material)
	return self:part(self.folder, "Wall", Block, size, cframe, color, material)
end

function Kit:glow(size, cframe, color)
	return self:part(self.folder, "Wall", Block, size, cframe, color, Material.Neon)
end

function Kit:ball(diameter, cframe, color, material)
	return self:part(self.folder, "Wall", BallShape, Vector3.one * diameter, cframe, color, material)
end

-- A cylinder lying along the X axis of cframe.
function Kit:rod(length, diameter, cframe, color, material)
	return self:part(self.folder, "Wall", CylinderShape, Vector3.new(length, diameter, diameter), cframe, color, material)
end

-- A standing cylinder from height y0 up to y0 + height.
function Kit:post(x, y0, height, diameter, d, color, material)
	return self:rod(height, diameter, self:at(x, y0 + height / 2, d) * UPRIGHT, color, material)
end

-- A straight bar between two world points. `up` must not be parallel to the bar:
-- it sets which way `depth` faces (Vector3.xAxis for drawings on a wall, yAxis on the floor).
function Kit:bar(p1, p2, width, depth, up, color, material, parent, kind)
	local length = (p2 - p1).Magnitude + width -- a little longer so joints close up
	local cframe = CFrame.lookAt((p1 + p2) / 2, p2, up)
	return self:part(parent or self.folder, kind or "Wall", Block, Vector3.new(width, depth, length), cframe, color, material)
end

-- Same settings newPart uses, for the one shape it can't make.
function Kit:wedge(size, cframe, color, material)
	local wedge = Instance.new("WedgePart")
	wedge.Anchored = true
	wedge.CanCollide = false
	wedge.CanTouch = false
	wedge.CastShadow = false
	wedge.Size = size
	wedge.CFrame = cframe
	wedge.Color = color
	wedge.Material = material or Material.SmoothPlastic
	wedge:SetAttribute("Kind", "Wall")
	wedge.Parent = self.folder
	return wedge
end

-- Neon line drawing flat against a wall, centered at depth d and height y.
function Kit:wallGlyph(segments, side, inset, d, y, scale, thickness, color, parent, kind)
	local x = self:wallX(side, inset)
	for _, s in segments do
		local p1 = self:pos(x, y + s[2] * scale, d + s[1] * scale)
		local p2 = self:pos(x, y + s[4] * scale, d + s[3] * scale)
		self:bar(p1, p2, thickness, thickness, Vector3.xAxis, color, Material.Neon, parent, kind)
	end
end

-- Neon line drawing lying on the floor (v becomes x).
function Kit:floorGlyph(segments, x, d, scale, color)
	for _, s in segments do
		local p1 = self:pos(x + s[2] * scale, 0.03, d + s[1] * scale)
		local p2 = self:pos(x + s[4] * scale, 0.03, d + s[3] * scale)
		self:bar(p1, p2, 0.22, 0.04, Vector3.yAxis, color, Material.Neon)
	end
end

-- Models -----------------------------------------------------------------------------

-- Places a Blender model in the room folder, or returns nil if it isn't available
-- (the caller then builds its part version). Breakable models count as breakables.
function Kit:place(name, cframe, options)
	local model = Models.place(name, self.folder, cframe, options)
	if model == nil then
		return nil
	end
	local style = ModelStyles[name]
	if style and style.Breakable then
		self.breakables += 1
	end
	return model
end

-- Places a wall model (origin at the center of its back face, front toward -Z in Blender)
-- with its back `inset` studs off the wall on `side` and its front facing into the corridor.
-- y is the model's anchor point (options.anchor: "floor", "ceiling" or "center").
-- The long side of the model ends up running along the corridor.
function Kit:wallProp(name, side, inset, y, d, options)
	local style = ModelStyles[name]
	if style == nil then
		return nil
	end
	options = options or {}
	local depth = style.Size.Z * (options.scale or 1)
	local cframe = self:at(self:wallX(side, inset + depth / 2), y, d) * CFrame.Angles(0, side * QUARTER_TURN, 0)
	return self:place(name, cframe, options)
end

-- Breakables -----------------------------------------------------------------------

function Kit:canBreak()
	return self.breakables < self.maxBreakables
end

-- Starts a breakable made of several parts; fill it with Kit:glass / Kit:inner.
function Kit:breakable(name)
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Breakable", true)
	model.Parent = self.folder
	self.breakables += 1
	return model
end

-- Glass piece. With parent = nil it is a breakable of its own.
function Kit:glass(parent, shape, size, cframe, color, transparency)
	if parent == nil then
		self.breakables += 1
	end
	return self:part(parent or self.folder, "Prop", shape, size, cframe, color, Material.Glass, {
		Name = "GlassProp",
		Transparency = transparency or 0.35,
		Reflectance = 0.25,
	})
end

-- Something inside a glass breakable (a glow, a plant, liquid). Shatters with it.
function Kit:inner(parent, shape, size, cframe, color, material)
	return self:part(parent, "Prop", shape, size, cframe, color, material or Material.Neon)
end

-- Glass tinted toward the zone color.
function Kit:tint(amount)
	return self.theme.Accent:Lerp(WHITE, amount or 0.45)
end

-- Shared props -----------------------------------------------------------------------

-- Round glass vase standing with its base at height y.
local function vase(kit, x, y, d, color, scale)
	if kit:place("GlassVase", kit:at(x, y, d), { anchor = "floor", scale = scale * 0.85, colors = { Glass = color } }) then
		return
	end
	local model = kit:breakable("Vase")
	local body = 1.6 * scale
	kit:glass(model, BallShape, Vector3.one * body, kit:at(x, y + body / 2, d), color)
	kit:glass(model, CylinderShape, Vector3.new(0.9, 0.7, 0.7) * scale, kit:at(x, y + body + 0.3 * scale, d) * UPRIGHT, color)
end

-- Wide-bellied urn with a neck and a lip.
local function urn(kit, x, y, d, color, scale)
	if kit:place("GlassUrn", kit:at(x, y, d), { anchor = "floor", scale = scale * 0.9, colors = { Glass = color } }) then
		return
	end
	local model = kit:breakable("Urn")
	kit:glass(model, BallShape, Vector3.one * 1.8 * scale, kit:at(x, y + 0.9 * scale, d), color, 0.25)
	kit:glass(model, CylinderShape, Vector3.new(0.6, 0.9, 0.9) * scale, kit:at(x, y + 1.95 * scale, d) * UPRIGHT, color, 0.25)
	kit:glass(model, CylinderShape, Vector3.new(0.2, 1.3, 1.3) * scale, kit:at(x, y + 2.3 * scale, d) * UPRIGHT, color, 0.25)
end

-- Glass ball with a glowing heart.
local function orb(kit, x, y, d, size, color)
	local placed = kit:place("GlassOrb", kit:at(x, y, d), {
		anchor = "center",
		scale = size / 2.3,
		colors = { Glass = color, Neon = kit.theme.Accent },
	})
	if placed then
		return
	end
	local model = kit:breakable("Orb")
	kit:glass(model, BallShape, Vector3.one * size, kit:at(x, y, d), color, 0.4)
	kit:inner(model, BallShape, Vector3.one * size * 0.35, kit:at(x, y, d), kit.theme.Accent)
end

-- Glass lantern hanging on a chain from the ceiling; y is its bottom.
local function lantern(kit, x, y, d, color)
	local placed = kit:place("GlassLantern", kit:at(x, y, d), {
		anchor = "floor",
		colors = { Glass = color, Neon = kit.theme.Accent },
	})
	if placed then
		local hook = y + ModelStyles.GlassLantern.Size.Y
		kit:post(x, hook, kit.height - hook, 0.12, d, Color3.fromRGB(60, 55, 50), Material.Metal)
		return
	end
	local top = y + 1.6
	kit:post(x, top, kit.height - top, 0.12, d, Color3.fromRGB(60, 55, 50), Material.Metal)
	local model = kit:breakable("Lantern")
	kit:glass(model, Block, Vector3.new(1.1, 1.6, 1.1), kit:at(x, y + 0.8, d), color, 0.3)
	kit:inner(model, BallShape, Vector3.one * 0.55, kit:at(x, y + 0.8, d), kit.theme.Accent)
end

-- Small glass globe lamp right under the ceiling (stays above the flight path anywhere).
local function ceilingGlobe(kit, x, d)
	kit:post(x, kit.height - 0.45, 0.45, 0.15, d, METAL, Material.Metal)
	orb(kit, x, kit.height - 1.05, d, 1.3, kit:tint(0.6))
end

-- Three crystals growing from a point; y is their base.
local function crystalCluster(kit, x, y, d, color)
	local model = kit:breakable("CrystalCluster")
	local spin = kit:random(0, math.pi)
	kit:glass(model, Block, Vector3.new(0.6, 2, 0.6), kit:at(x, y + 1, d) * CFrame.Angles(0, spin, 0), color, 0.2)
	kit:glass(model, Block, Vector3.new(0.45, 1.3, 0.45), kit:at(x, y + 0.6, d - 0.5) * CFrame.Angles(-0.5, 0, 0), color, 0.2)
	kit:glass(model, Block, Vector3.new(0.45, 1.3, 0.45), kit:at(x, y + 0.6, d + 0.5) * CFrame.Angles(0.5, 0, 0), color, 0.2)
end

-- The zone name painted on a sign, facing the player coming down the corridor.
local function nameplate(kit, part, color)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back -- +Z, toward the approaching player
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = kit.theme.Name or ""
	label.TextScaled = true
	label.Font = Enum.Font.Michroma
	label.TextColor3 = color
	label.Parent = gui
	gui.Parent = part
end

local function nothing() end

-- Lab: clean white panels, glass partitions, benches with test tubes ---------------------

local LAB_DARK = Color3.fromRGB(55, 62, 75)
local LAB_ROOM = Color3.fromRGB(38, 52, 66) -- the side labs seen through the windows
local LAB_RACK = Color3.fromRGB(35, 38, 45)
local LAB_YELLOW = Color3.fromRGB(255, 205, 40)
local LAB_LIGHT = Color3.fromRGB(235, 248, 255)
local LIQUIDS = {
	Color3.fromRGB(90, 255, 140),
	Color3.fromRGB(255, 90, 170),
	Color3.fromRGB(255, 200, 60),
	Color3.fromRGB(120, 160, 255),
}
local LED_COLORS = { Color3.fromRGB(80, 255, 140), Color3.fromRGB(90, 200, 255), Color3.fromRGB(255, 170, 60) }

local Lab = {}

function Lab.room(kit)
	local L, H = kit.length, kit.height
	local seam = kit.theme.Wall:Lerp(BLACK, 0.18)
	for _, side in SIDES do
		-- Panel seams along the walls.
		for _, y in { 4.5, 9.5 } do
			kit:block(Vector3.new(0.06, 0.12, L), kit:at(kit:wallX(side, 0.03), y, L / 2), seam)
		end
		-- Pipes along the ceiling corners.
		if kit:chance(0.75) then
			-- Four pipe segments end to end, hanging from the ceiling corner (the part version is two long rods).
			local segment = L / 4
			local pipeScale = segment / ModelStyles.PipeRun.Size.X
			local placed = 0
			for i = 1, 4 do
				local options = { anchor = "ceiling", scale = pipeScale, colors = { Metal = kit.theme.Accent } }
				if kit:wallProp("PipeRun", side, 0, H, (i - 0.5) * segment, options) then
					placed += 1
				end
			end
			if placed == 0 then
				kit:rod(L, 0.7, kit:at(kit:wallX(side, 1.2), H - 0.6, L / 2) * ALONG_Z, METAL, Material.Metal)
				kit:rod(L, 0.35, kit:at(kit:wallX(side, 2.1), H - 0.35, L / 2) * ALONG_Z, kit.theme.Accent)
			end
		end
		-- Warning stripes along the floor edges.
		kit:block(Vector3.new(0.6, 0.04, L), kit:at(side * 8.7, 0.02, L / 2), LAB_YELLOW)
		kit:block(Vector3.new(0.2, 0.05, L), kit:at(side * 8.7, 0.025, L / 2), LAB_DARK)
	end
	-- Ceiling light panels.
	for d = 10, L - 10, 20 do
		-- 1.25x: 5 wide, 1.14 deep, so its underside stays above the flight path (y = 12).
		local light = kit:place("CeilingLight", kit:at(0, H, d), { anchor = "ceiling", scale = 1.25 })
		if not light then
			kit:glow(Vector3.new(5, 0.12, 2.5), kit:at(0, H - 0.06, d), LAB_LIGHT)
		end
	end
end

local function labPoster(kit, side, d)
	local hazard = kit:chance(0.5)
	local y = kit:random(5.5, 7.5)
	kit:block(Vector3.new(0.08, 2.6, 2), kit:at(kit:wallX(side, 0.04), y, d), if hazard then LAB_YELLOW else kit.theme.Accent)
	local mark = CFrame.Angles(math.rad(45), 0, 0) -- a diamond symbol
	kit:block(Vector3.new(0.06, 0.9, 0.9), kit:at(kit:wallX(side, 0.1), y, d) * mark, if hazard then LAB_DARK else WHITE)
end

-- Glass partition looking into a side lab.
local function labWindow(kit, side, d)
	if not kit:canBreak() then
		return labPoster(kit, side, d)
	end
	local frame = kit.theme.Wall:Lerp(BLACK, 0.25)
	kit:block(Vector3.new(0.1, 6, 7), kit:at(kit:wallX(side, 0.07), 6.5, d), LAB_ROOM)
	kit:glow(Vector3.new(0.08, 0.25, 6.6), kit:at(kit:wallX(side, 0.14), 9.1, d), kit:tint(0.5))
	kit:block(Vector3.new(0.7, 0.3, 7.4), kit:at(kit:wallX(side, 0.35), 3.35, d), frame)
	kit:block(Vector3.new(0.7, 0.3, 7.4), kit:at(kit:wallX(side, 0.35), 9.65, d), frame)
	local pane = kit:glass(nil, Block, Vector3.new(0.15, 6, 7), kit:at(kit:wallX(side, 0.45), 6.5, d), kit:tint(0.6), 0.5)
	pane.Name = "LabWindow"
end

-- Rack of colored test tubes; y is the bench top.
local function testTubes(kit, x, y, d, side)
	if Models.has("TestTubeRack") then -- (checked first so the part version draws the same random numbers)
		local rack = kit:place("TestTubeRack", kit:at(x, y, d) * CFrame.Angles(0, side * QUARTER_TURN, 0), {
			anchor = "floor",
			colors = { Neon = kit:pick(LIQUIDS) },
		})
		if rack then
			return
		end
	end
	kit:block(Vector3.new(0.5, 0.25, 2.4), kit:at(x, y + 1.1, d), LAB_DARK)
	local model = kit:breakable("TestTubes")
	for _, offset in { -0.75, 0, 0.75 } do
		kit:glass(model, CylinderShape, Vector3.new(1.6, 0.32, 0.32), kit:at(x, y + 0.8, d + offset) * UPRIGHT, kit:pick(LIQUIDS), 0.2)
	end
end

-- Round flask with colored liquid; y is the bench top.
local function flask(kit, x, y, d)
	if Models.has("Flask") then
		local placed = kit:place("Flask", kit:at(x, y, d), {
			anchor = "floor",
			colors = { Glass = kit:tint(0.7), Neon = kit:pick(LIQUIDS) },
		})
		if placed then
			return
		end
	end
	local model = kit:breakable("Flask")
	kit:glass(model, BallShape, Vector3.one * 1.3, kit:at(x, y + 0.65, d), kit:tint(0.7), 0.5)
	kit:glass(model, CylinderShape, Vector3.new(0.8, 0.32, 0.32), kit:at(x, y + 1.6, d) * UPRIGHT, kit:tint(0.7), 0.5)
	kit:inner(model, BallShape, Vector3.one * 0.9, kit:at(x, y + 0.55, d), kit:pick(LIQUIDS), Material.SmoothPlastic)
end

local function labBench(kit, side, d)
	-- Scaled so the bench top sits at 3.25, where the glassware stands.
	local benchScale = 3.25 / ModelStyles.LabBench.Size.Y
	local bench = kit:wallProp("LabBench", side, 0, 0, d, { anchor = "floor", scale = benchScale })
	if not bench then
		kit:block(Vector3.new(2.2, 3, 6), kit:at(kit:wallX(side, 1.2), 1.5, d), kit.theme.Wall:Lerp(BLACK, 0.1))
		kit:block(Vector3.new(2.6, 0.25, 6.4), kit:at(kit:wallX(side, 1.35), 3.125, d), LAB_DARK)
	end
	if kit:canBreak() then
		testTubes(kit, kit:wallX(side, 1.6), 3.25, d - 1.5, side)
	end
	if kit:canBreak() then
		flask(kit, kit:wallX(side, 1.5), 3.25, d + 1.5)
	end
end

local function serverRacks(kit, side, d)
	local count = kit:pick({ 1, 2 })
	for i = 1, count do
		local rackD = if count == 1 then d else d + (if i == 1 then -1.9 else 1.9)
		local ledColor = kit:pick(LED_COLORS)
		-- 1.2x makes the rack 8.4 tall and 3.6 long, which still fits two per bay.
		local rack = kit:wallProp("ServerRack", side, 0, 0, rackD, { anchor = "floor", scale = 1.2, colors = { Neon = ledColor } })
		if not rack then
			kit:block(Vector3.new(1.8, 9, 3.4), kit:at(kit:wallX(side, 0.9), 4.5, rackD), LAB_RACK)
			kit:glow(Vector3.new(0.05, 7, 0.2), kit:at(kit:wallX(side, 1.83), 4.8, rackD + 0.9), ledColor)
		end
	end
end

-- Glass case on a pedestal with a glowing sample inside.
local function displayCase(kit, side, d)
	if not kit:canBreak() then
		return labPoster(kit, side, d)
	end
	local x = kit:wallX(side, 1.4)
	kit:block(Vector3.new(2, 2.5, 2), kit:at(x, 1.25, d), LAB_DARK)
	local model = kit:breakable("DisplayCase")
	kit:glass(model, Block, Vector3.new(1.8, 2, 1.8), kit:at(x, 3.5, d), kit:tint(0.7), 0.55)
	local sample = CFrame.Angles(math.rad(45), math.rad(45), 0)
	kit:inner(model, Block, Vector3.one * 0.7, kit:at(x, 3.3, d) * sample, kit:pick(LIQUIDS))
end

Lab.features = {
	{ 3, labWindow },
	{ 3, labBench },
	{ 2, serverRacks },
	{ 2, displayCase },
	{ 1, labPoster },
	{ 3, nothing },
}

-- Airlock frame with blinking beacons.
function Lab.gate(kit, d)
	local H = kit.height
	local frame = kit.theme.Wall:Lerp(BLACK, 0.3)
	for _, side in SIDES do
		kit:block(Vector3.new(3, H, 1.6), kit:at(side * 8.5, H / 2, d), frame)
		kit:glow(Vector3.new(0.2, 11.6, 0.3), kit:at(side * 6.9, 6, d - 0.6), kit.theme.Accent)
		kit:ball(0.8, kit:at(side * 7.6, 12.2, d - 1.1), Color3.fromRGB(255, 120, 40), Material.Neon)
	end
	local header = kit:block(Vector3.new(14, 1.6, 1.6), kit:at(0, H - 0.8, d), frame)
	nameplate(kit, header, kit.theme.Accent)
	kit:glow(Vector3.new(14, 0.2, 0.3), kit:at(0, 12.2, d - 0.6), kit.theme.Accent)
	kit:block(Vector3.new(14, 0.04, 1.6), kit:at(0, 0.02, d), LAB_YELLOW)
end

-- Neon city: dark alley, glowing signs, billboards, cables --------------------------------

local NEON_DARK = Color3.fromRGB(18, 18, 26)
local NEON_CABLE = Color3.fromRGB(12, 12, 16)
local NEON_COLORS = {
	Color3.fromRGB(0, 230, 255),
	Color3.fromRGB(255, 220, 60),
	Color3.fromRGB(120, 255, 110),
	Color3.fromRGB(180, 90, 255),
}

local Neon = {}

local function neonColor(kit)
	return if kit:chance(0.35) then kit.theme.Accent else kit:pick(NEON_COLORS)
end

function Neon.room(kit)
	local L, H = kit.length, kit.height
	local accent = kit.theme.Accent
	local grid = accent:Lerp(BLACK, 0.45)
	-- Glowing floor grid.
	for d = 10, L - 10, 20 do
		kit:glow(Vector3.new(18.6, 0.04, 0.15), kit:at(0, 0.02, d), grid)
	end
	for _, x in { -4, 4 } do
		kit:glow(Vector3.new(0.15, 0.04, L), kit:at(x, 0.02, L / 2), grid)
	end
	for _, side in SIDES do
		-- Guide light low on the walls, like a subway tunnel.
		kit:glow(Vector3.new(0.06, 0.2, L), kit:at(kit:wallX(side, 0.03), 1.2, L / 2), accent)
		-- Cables sagging between the ceiling corners.
		local x = kit:wallX(side, 1.1)
		local d = kit:random(2, 14)
		while d < L - 14 do
			local span = kit:random(8, 12)
			local sag = kit:random(0.8, 1.4)
			local a = kit:pos(x, H - 0.2, d)
			local mid = kit:pos(x, H - 0.2 - sag, d + span / 2)
			local b = kit:pos(x, H - 0.2, d + span)
			kit:bar(a, mid, 0.15, 0.15, Vector3.xAxis, NEON_CABLE)
			kit:bar(mid, b, 0.15, 0.15, Vector3.xAxis, NEON_CABLE)
			d += span + kit:random(14, 26)
		end
	end
	-- Ceiling vents.
	for _, d in { 25, 65 } do
		kit:block(Vector3.new(3, 0.1, 2), kit:at(kit:random(-4, 4), H - 0.05, d), NEON_DARK:Lerp(WHITE, 0.15), Material.DiamondPlate)
	end
end

local function billboard(kit, side, d)
	local y = kit:random(5.5, 7.5)
	local main = neonColor(kit)
	local second = main:Lerp(WHITE, 0.6)
	kit:block(Vector3.new(0.2, 4.6, 7), kit:at(kit:wallX(side, 0.1), y, d), NEON_DARK)
	kit:block(Vector3.new(0.1, 4, 6.4), kit:at(kit:wallX(side, 0.25), y, d), main:Lerp(BLACK, 0.25))
	kit:block(Vector3.new(0.08, 1.2, 3), kit:at(kit:wallX(side, 0.33), y + kit:random(-0.8, 0.8), d + kit:random(-1.2, 1.2)), second)
	kit:glow(Vector3.new(0.3, 0.15, 6.6), kit:at(kit:wallX(side, 0.5), y + 2.45, d), WHITE)
end

-- Neon line drawing behind a glass cover, on a dark board.
local function neonSign(kit, side, d)
	if not kit:canBreak() then
		return billboard(kit, side, d)
	end
	local color = neonColor(kit)
	kit:block(Vector3.new(0.15, 4, 6), kit:at(kit:wallX(side, 0.08), 7, d), NEON_DARK)
	local model = kit:breakable("NeonSign")
	kit:wallGlyph(GLYPHS[kit:pick(GLYPH_NAMES)], side, 0.3, d, 7, 1, 0.22, color, model, "Prop")
	kit:glass(model, Block, Vector3.new(0.08, 3.8, 5.8), kit:at(kit:wallX(side, 0.5), 7, d), color:Lerp(WHITE, 0.7), 0.7)
end

local function wallVent(kit, side, d)
	local y = kit:random(3, 10)
	if kit:wallProp("Vent", side, 0.02, y, d, { anchor = "center", scale = 1.25 }) then
		return
	end
	kit:block(Vector3.new(0.4, 2.4, 3), kit:at(kit:wallX(side, 0.2), y, d), NEON_DARK:Lerp(WHITE, 0.1), Material.Metal)
	for _, offset in { -0.45, 0.45 } do
		kit:block(Vector3.new(0.1, 0.18, 2.8), kit:at(kit:wallX(side, 0.45), y + offset, d), NEON_CABLE)
	end
end

-- Upright glass tubes with a glowing gas core.
local function neonTubes(kit, side, d)
	if not kit:canBreak() then
		return wallVent(kit, side, d)
	end
	local count = if kit.breakables + 1 < kit.maxBreakables and kit:chance(0.5) then 2 else 1
	local x = kit:wallX(side, 0.6)
	for i = 1, count do
		local tubeD = if count == 1 then d else d + (if i == 1 then -1.5 else 1.5)
		local color = neonColor(kit)
		-- The model is a horizontal tube on brackets; two of them stack instead of sitting side by side.
		local tubeY = if count == 1 then 6.5 else 6.5 + (if i == 1 then -1.6 else 1.6)
		local tube = kit:wallProp("NeonTube", side, 0.05, tubeY, d, { anchor = "center", scale = 1.4, colors = { Neon = color } })
		if tube then
			continue
		end
		local cframe = kit:at(x, 6.5, tubeD) * UPRIGHT
		local model = kit:breakable("NeonTube")
		kit:glass(model, CylinderShape, Vector3.new(6, 0.6, 0.6), cframe, color:Lerp(WHITE, 0.6), 0.6)
		kit:inner(model, CylinderShape, Vector3.new(5.8, 0.25, 0.25), cframe, color)
	end
end

-- A locked service hatch with a light stripe.
local function serviceHatch(kit, side, d)
	kit:block(Vector3.new(0.1, 7, 4), kit:at(kit:wallX(side, 0.05), 3.5, d), NEON_DARK)
	kit:glow(Vector3.new(0.12, 0.3, 4), kit:at(kit:wallX(side, 0.1), 5, d), neonColor(kit))
end

Neon.features = {
	{ 3, neonSign },
	{ 2, billboard },
	{ 2, wallVent },
	{ 2, neonTubes },
	{ 1, serviceHatch },
	{ 3, nothing },
}

-- Double neon arch with the zone name on a hanging sign.
function Neon.gate(kit, d)
	local colors = { kit.theme.Accent, NEON_COLORS[1] }
	for i, color in colors do
		local archD = d + (i - 1) * 1.5
		for _, side in SIDES do
			kit:glow(Vector3.new(0.4, 12.3, 0.4), kit:at(kit:wallX(side, 0.6), 6.15, archD), color)
		end
		kit:glow(Vector3.new(19.2, 0.4, 0.4), kit:at(0, 12.5, archD), color)
	end
	local board = kit:block(Vector3.new(10, 1.2, 0.3), kit:at(0, 13.3, d), NEON_DARK)
	nameplate(kit, board, kit.theme.Accent)
	kit:glow(Vector3.new(15, 0.04, 0.3), kit:at(0, 0.02, d), kit.theme.Accent)
end

-- Temple: sandstone pillars and arches, carvings, braziers, urns ---------------------------

local PILLAR_DEPTHS = { 20, 40, 60 }
local TEMPLE_RUNNER = Color3.fromRGB(150, 55, 40)
local TEMPLE_GOLD = Color3.fromRGB(230, 180, 60)
local TEMPLE_BRONZE = Color3.fromRGB(150, 95, 45)
local TEMPLE_FLAME = Color3.fromRGB(255, 230, 120)
local URN_COLORS = {
	Color3.fromRGB(60, 170, 170),
	Color3.fromRGB(70, 110, 220),
	Color3.fromRGB(230, 170, 60),
	Color3.fromRGB(200, 80, 60),
}
-- Raised shapes inside carved panels, as { u, v, width, height }.
local CARVINGS = {
	{ { 0, 0, 3.4, 0.5 }, { 0, 0, 1, 1 } }, -- eye
	{ { 0, -1.2, 3.6, 0.5 }, { 0, -0.4, 2.6, 0.5 }, { 0, 0.4, 1.6, 0.5 } }, -- stepped pyramid
	{ { 0, -0.3, 0.5, 3 }, { 0, 0.6, 2.4, 0.5 } }, -- cross
	{ { -1, 0, 0.5, 3 }, { 1, 0, 0.5, 3 }, { 0, 1.25, 2.5, 0.5 } }, -- gateway
}

local Temple = {}

local function stone(kit, amount)
	return kit.theme.Wall:Lerp(BLACK, amount)
end

function Temple.room(kit)
	local L = kit.length
	-- Red runner with gold borders down the middle of the floor.
	kit:block(Vector3.new(7, 0.04, L), kit:at(0, 0.02, L / 2), TEMPLE_RUNNER:Lerp(kit.theme.Accent, 0.2))
	for _, x in { -3.65, 3.65 } do
		kit:block(Vector3.new(0.3, 0.05, L), kit:at(x, 0.025, L / 2), TEMPLE_GOLD)
	end
	for _, d in PILLAR_DEPTHS do
		for _, side in SIDES do
			-- The model is 14 tall; 13/14 makes it end right under the beam (y = 13).
			local pillar = kit:place("Pillar", kit:at(side * 8.6, 0, d), {
				anchor = "floor",
				scale = 13 / ModelStyles.Pillar.Size.Y,
				colors = { Stone = stone(kit, 0.04) },
			})
			if not pillar then
				kit:post(side * 8.6, 0, 10, 2.2, d, stone(kit, 0.04), Material.Sandstone)
				kit:block(Vector3.new(3, 1, 3), kit:at(side * 8.5, 10.5, d), stone(kit, 0.15))
			end
			-- Arch shoulder: a wedge between the capital and the beam, sloping toward the middle.
			-- Its full faces point up (under the beam) and out (against the wall).
			local shoulder = CFrame.fromMatrix(kit:pos(side * 8.3, 12, d), Vector3.new(0, 0, side), Vector3.new(0, -1, 0))
			kit:wedge(Vector3.new(2.4, 2, 3.4), shoulder, stone(kit, 0.15))
		end
		kit:block(Vector3.new(20, 1, 2.4), kit:at(0, 13.5, d), stone(kit, 0.15))
	end
end

local function carving(kit, side, d)
	local y = kit:random(5.5, 7)
	kit:block(Vector3.new(0.1, 4.4, 4.4), kit:at(kit:wallX(side, 0.05), y, d), stone(kit, 0.22))
	local relief = kit.theme.Wall:Lerp(kit.theme.Accent, 0.25)
	for _, r in kit:pick(CARVINGS) do
		kit:block(Vector3.new(0.12, r[4], r[3]), kit:at(kit:wallX(side, 0.15), y + r[2], d + r[1]), relief)
	end
end

local function brazier(kit, side, d)
	local x = kit:wallX(side, 1.8)
	if kit:place("Brazier", kit:at(x, 0, d), { anchor = "floor", colors = { Neon = kit.theme.Accent } }) then
		return
	end
	kit:post(x, 0, 2.6, 0.5, d, TEMPLE_BRONZE, Material.Metal)
	kit:post(x, 2.6, 0.5, 1.8, d, TEMPLE_BRONZE, Material.Metal)
	kit:ball(1.1, kit:at(x, 3.35, d), kit.theme.Accent, Material.Neon)
	kit:ball(0.6, kit:at(x, 3.85, d), TEMPLE_FLAME, Material.Neon)
end

local function urnOnPedestal(kit, side, d)
	if not kit:canBreak() then
		return carving(kit, side, d)
	end
	local x = kit:wallX(side, 1.6)
	kit:block(Vector3.new(1.8, 1.2, 1.8), kit:at(x, 0.6, d), stone(kit, 0.15))
	urn(kit, x, 1.2, d, kit:pick(URN_COLORS), kit:random(0.9, 1.15))
end

local function vaseShelf(kit, side, d)
	if not kit:canBreak() then
		return carving(kit, side, d)
	end
	kit:block(Vector3.new(1.6, 0.3, 5), kit:at(kit:wallX(side, 0.8), 4.5, d), stone(kit, 0.2))
	for _, offset in { -1.5, 1.5 } do
		if kit:canBreak() then
			vase(kit, kit:wallX(side, 1), 4.65, d + offset, kit:pick(URN_COLORS):Lerp(WHITE, 0.2), 0.75)
		end
	end
end

local function templeLantern(kit, side, d)
	if not kit:canBreak() then
		return carving(kit, side, d)
	end
	lantern(kit, kit:wallX(side, 2), kit:random(8.5, 10), d, kit:tint(0.5))
end

Temple.features = {
	{ 3, carving },
	{ 2, brazier },
	{ 3, urnOnPedestal },
	{ 2, vaseShelf },
	{ 2, templeLantern },
	{ 5, nothing },
}

-- Massive stone gate with the zone name on the lintel, flames on either side.
function Temple.gate(kit, d)
	for _, side in SIDES do
		kit:block(Vector3.new(3.4, 12, 3), kit:at(side * 8.3, 6, d), stone(kit, 0.18))
		kit:glow(Vector3.new(0.6, 11, 0.1), kit:at(side * 7.1, 6, d - 1.55), kit.theme.Accent)
		brazier(kit, side, d + 4)
	end
	local lintel = kit:block(Vector3.new(20, 2, 3.6), kit:at(0, 13, d), stone(kit, 0.25))
	nameplate(kit, lintel, TEMPLE_GOLD)
end

-- Greenhouse: glass roof frames, planters, vines, terrariums ------------------------------

local GH_FRAME = Color3.fromRGB(95, 115, 105)
local GH_SKY = Color3.fromRGB(120, 190, 140)
local GH_OUTSIDE = Color3.fromRGB(70, 150, 95)
local GH_POT = Color3.fromRGB(175, 90, 60)
local GH_TRUNK = Color3.fromRGB(100, 70, 45)
local LEAVES = {
	Color3.fromRGB(60, 170, 80),
	Color3.fromRGB(40, 130, 60),
	Color3.fromRGB(110, 200, 90),
}
local FLOWERS = { Color3.fromRGB(255, 120, 180), Color3.fromRGB(255, 220, 70), Color3.fromRGB(180, 130, 255) }

local Greenhouse = {}

local function leaf(kit)
	return kit:pick(LEAVES)
end

function Greenhouse.room(kit)
	local L, H = kit.length, kit.height
	-- Daylight through the roof, crossed by metal frames.
	kit:glow(Vector3.new(19, 0.05, L), kit:at(0, H - 0.04, L / 2), GH_SKY)
	for d = 10, L - 10, 10 do
		kit:block(Vector3.new(20, 0.4, 0.4), kit:at(0, H - 0.3, d), GH_FRAME, Material.Metal)
	end
	for _, x in { -3.3, 3.3 } do
		kit:block(Vector3.new(0.4, 0.4, L), kit:at(x, H - 0.3, L / 2), GH_FRAME, Material.Metal)
	end
	-- Watering pipe with sprinkler heads along one ceiling corner.
	local pipeX = kit:wallX(kit:pick(SIDES), 0.8)
	kit:rod(L, 0.35, kit:at(pipeX, 12.8, L / 2) * ALONG_Z, GH_FRAME, Material.Metal)
	for d = 25, L - 15, 40 do
		kit:post(pipeX, 12.25, 0.55, 0.25, d, GH_FRAME, Material.Metal)
	end
	-- Vines hanging from the ceiling corners.
	for _, side in SIDES do
		for _ = 1, kit.rng:NextInteger(2, 3) do
			local d = kit:random(3, L - 3)
			local length = kit:random(2.5, 5)
			local x = kit:wallX(side, kit:random(0.4, 0.9))
			-- The model hangs 5.43 long; scaled to this vine's length and set against the wall.
			local vineScale = length / ModelStyles.HangingVine.Size.Y
			local vineX = kit:wallX(side, 0.1 + ModelStyles.HangingVine.Size.X * vineScale / 2)
			local vine = nil
			if Models.has("HangingVine") then -- (checked first so the part version draws the same random numbers)
				vine = kit:place("HangingVine", kit:at(vineX, H, d), {
					anchor = "ceiling",
					scale = vineScale,
					colors = { Plant = leaf(kit) },
				})
			end
			if not vine then
				kit:block(Vector3.new(0.15, length, 0.15), kit:at(x, H - length / 2, d), LEAVES[2], Material.Grass)
				if kit:chance(0.6) then
					kit:ball(0.7, kit:at(x, H - length, d), leaf(kit), Material.Grass)
				end
			end
		end
	end
end

-- A leafy Plant model standing on the floor (or a planter); `scale` 1.2 is 3.1 wide, still clear of the flight path.
local function plantModel(kit, x, y, d, scale)
	if not Models.has("Plant") then
		return nil
	end
	return kit:place("Plant", kit:at(x, y, d), { anchor = "floor", scale = scale, colors = { Plant = leaf(kit) } })
end

local function fern(kit, side, d)
	local x = kit:wallX(side, 1.3)
	local plantX = kit:wallX(side, 1.6) -- far enough off the wall for the model's width
	if plantModel(kit, plantX, 0, d - 1, 1.2) then
		plantModel(kit, plantX, 0, d + 1.2, 0.9)
		return
	end
	kit:ball(2.2, kit:at(x, 1, d - 1), leaf(kit), Material.Grass)
	kit:ball(1.6, kit:at(x, 0.7, d + 1.2), leaf(kit), Material.Grass)
	if kit:chance(0.5) then
		kit:ball(0.5, kit:at(x, 2.05, d - 1), kit:pick(FLOWERS), Material.Neon)
	end
end

local function planter(kit, side, d)
	local x = kit:wallX(side, 1.4)
	-- 1.5x: 6 long, 2.4 deep, 1.8 tall, the same footprint as the block version; two plants grow on top.
	if kit:wallProp("Planter", side, 0, 0, d, { anchor = "floor", scale = 1.5 }) then
		local soil = ModelStyles.Planter.Size.Y * 1.5 - 0.1
		local plantX = kit:wallX(side, 1.8)
		plantModel(kit, plantX, soil, d - 1.5, 1.2)
		plantModel(kit, plantX, soil, d + 1.5, 1.2)
		return
	end
	kit:block(Vector3.new(2.4, 1.4, 6), kit:at(x, 0.7, d), GH_POT)
	kit:post(x, 1.4, 2.8, 0.4, d, GH_TRUNK, Material.Wood)
	kit:ball(2.4, kit:at(x, 4.9, d), leaf(kit), Material.Grass)
	kit:ball(1.8, kit:at(x, 2.2, d + kit:pick({ -1.8, 1.8 })), leaf(kit), Material.Grass)
end

-- Glass box with a little plant inside, on a metal stand.
local function terrarium(kit, side, d)
	if not kit:canBreak() then
		return fern(kit, side, d)
	end
	local x = kit:wallX(side, 1.4)
	kit:block(Vector3.new(1.8, 2.4, 1.8), kit:at(x, 1.2, d), GH_FRAME, Material.Metal)
	local model = kit:breakable("Terrarium")
	kit:glass(model, Block, Vector3.new(1.7, 1.7, 1.7), kit:at(x, 3.25, d), kit:tint(0.6), 0.45)
	kit:inner(model, BallShape, Vector3.one * 0.9, kit:at(x, 2.85, d), leaf(kit), Material.Grass)
	kit:inner(model, BallShape, Vector3.one * 0.35, kit:at(x, 3.35, d), kit:pick(FLOWERS))
end

-- Breakable greenhouse wall panel with the garden glowing behind it.
local function wallPane(kit, side, d)
	if not kit:canBreak() then
		return fern(kit, side, d)
	end
	kit:glow(Vector3.new(0.1, 6.6, 6.6), kit:at(kit:wallX(side, 0.05), 6.5, d), GH_OUTSIDE)
	kit:block(Vector3.new(0.2, 6.8, 0.25), kit:at(kit:wallX(side, 0.2), 6.5, d), GH_FRAME, Material.Metal)
	kit:block(Vector3.new(0.2, 0.25, 6.8), kit:at(kit:wallX(side, 0.2), 6.5, d), GH_FRAME, Material.Metal)
	local pane = kit:glass(nil, Block, Vector3.new(0.15, 6.4, 6.4), kit:at(kit:wallX(side, 0.45), 6.5, d), kit:tint(0.55), 0.5)
	pane.Name = "GreenhousePane"
end

local function hangingBasket(kit, side, d)
	local x = kit:wallX(side, 2.2)
	kit:post(x, 11, 3, 0.1, d, GH_FRAME, Material.Metal)
	kit:post(x, 10.4, 0.6, 1.4, d, GH_TRUNK, Material.Wood)
	kit:ball(1.4, kit:at(x, 10.3, d), leaf(kit), Material.Grass)
	kit:block(Vector3.new(0.15, 2, 0.15), kit:at(x + side * 0.4, 9.6, d + 0.3), LEAVES[2], Material.Grass)
end

Greenhouse.features = {
	{ 3, planter },
	{ 2, terrarium },
	{ 2, wallPane },
	{ 2, fern },
	{ 1, hangingBasket },
	{ 3, nothing },
}

-- Leafy trellis arch with the zone name.
function Greenhouse.gate(kit, d)
	for _, side in SIDES do
		kit:block(Vector3.new(0.6, 12.6, 0.6), kit:at(side * 8, 6.3, d), GH_FRAME, Material.Metal)
		for _, y in { 3, 6.5, 10 } do
			kit:ball(1.6, kit:at(side * 8, y, d), leaf(kit), Material.Grass)
		end
		kit:ball(1.4, kit:at(side * 5.5, 13.2, d), leaf(kit), Material.Grass)
	end
	kit:block(Vector3.new(16.6, 0.6, 0.6), kit:at(0, 12.6, d), GH_FRAME, Material.Metal)
	local board = kit:block(Vector3.new(8, 1.2, 0.2), kit:at(0, 13.3, d - 0.5), GH_TRUNK, Material.Wood)
	nameplate(kit, board, Color3.fromRGB(230, 255, 220))
end

-- Void: windows to space, floating glass orbs and shards, glowing runes -------------------

local VOID_SPACE = Color3.fromRGB(12, 6, 24)
local VOID_ROCK = Color3.fromRGB(45, 35, 60)
local VOID_PLANETS = { Color3.fromRGB(255, 120, 200), Color3.fromRGB(90, 220, 255), Color3.fromRGB(255, 170, 70) }

local Void = {}

function Void.room(kit)
	local L, H = kit.length, kit.height
	-- Starry ceiling.
	kit:block(Vector3.new(19, 0.05, L), kit:at(0, H - 0.03, L / 2), VOID_SPACE)
	for _ = 1, 8 do
		local size = kit:random(0.12, 0.25)
		local color = if kit:chance(0.3) then kit.theme.Accent else WHITE
		kit:glow(Vector3.new(size, 0.04, size), kit:at(kit:random(-9, 9), H - 0.07, kit:random(1, L - 1)), color)
	end
	-- Glowing runes on the floor.
	for _, d in { 25, 55 } do
		kit:floorGlyph(GLYPHS[kit:pick(GLYPH_NAMES)], kit:random(-3, 3), d + kit:random(-4, 4), 0.8, kit.theme.Accent)
	end
end

-- A dark "window" into space with a far planet and drifting rocks.
local function spaceWindow(kit, side, d)
	kit:block(Vector3.new(0.1, 6, 6.5), kit:at(kit:wallX(side, 0.06), 6.5, d), VOID_SPACE)
	for _, y in { 3.4, 9.6 } do
		kit:glow(Vector3.new(0.2, 0.2, 6.9), kit:at(kit:wallX(side, 0.15), y, d), kit.theme.Accent)
	end
	kit:ball(0.9, kit:at(kit:wallX(side, 0.55), kit:random(5, 8), d + kit:random(-2, 2)), kit:pick(VOID_PLANETS), Material.Neon)
	local size = kit:random(0.6, 1.1)
	local spin = CFrame.Angles(kit:random(0, math.pi), kit:random(0, math.pi), kit:random(0, math.pi))
	local cframe = kit:at(kit:wallX(side, 1), kit:random(4, 9), d + kit:random(-2.5, 2.5)) * spin
	kit:block(Vector3.new(size, size * 0.7, size), cframe, VOID_ROCK)
end

local function rune(kit, side, d)
	kit:wallGlyph(GLYPHS[kit:pick(GLYPH_NAMES)], side, 0.1, d, kit:random(5, 8), kit:random(0.7, 0.9), 0.2, kit.theme.Accent)
end

local function floatingOrb(kit, side, d)
	if not kit:canBreak() then
		return rune(kit, side, d)
	end
	local size = kit:random(1.4, 2)
	orb(kit, kit:wallX(side, kit:random(1.6, 2.2)), kit:random(4, 10), d, size, kit:pick(VOID_PLANETS):Lerp(WHITE, 0.5))
end

-- Loose glass shards floating near the wall, each one breakable on its own.
local function shards(kit, side, d)
	if not kit:canBreak() then
		return rune(kit, side, d)
	end
	for _ = 1, kit.rng:NextInteger(2, 3) do
		if not kit:canBreak() then
			break
		end
		local size = Vector3.new(0.15, kit:random(1.4, 2.4), kit:random(0.6, 1.1))
		local spin = CFrame.Angles(kit:random(-0.6, 0.6), kit:random(0, math.pi), kit:random(-0.6, 0.6))
		local cframe = kit:at(kit:wallX(side, kit:random(1.3, 1.8)), kit:random(3.5, 10.5), d + kit:random(-3, 3)) * spin
		local shard = kit:glass(nil, Block, size, cframe, kit:tint(0.55), 0.3)
		shard.Name = "Shard"
	end
end

-- Floating rock with a crystal cluster growing on top.
local function crystalRock(kit, side, d)
	if not kit:canBreak() then
		return spaceWindow(kit, side, d)
	end
	local x = kit:wallX(side, 1.7)
	local y = kit:random(2.5, 7)
	kit:block(Vector3.new(2, 1.1, 2), kit:at(x, y, d) * CFrame.Angles(0, kit:random(0, math.pi), kit:random(-0.2, 0.2)), VOID_ROCK)
	crystalCluster(kit, x, y + 0.4, d, kit:tint(0.35))
end

Void.features = {
	{ 3, spaceWindow },
	{ 3, floatingOrb },
	{ 2, shards },
	{ 2, rune },
	{ 2, crystalRock },
	{ 3, nothing },
}

-- Glowing portal frame with the zone name and two guardian crystals.
function Void.gate(kit, d)
	for _, side in SIDES do
		kit:block(Vector3.new(2, kit.height, 1.2), kit:at(side * 9, kit.height / 2, d), VOID_SPACE)
		kit:glow(Vector3.new(0.5, 12.8, 0.5), kit:at(side * 7.6, 6.4, d), kit.theme.Accent)
		if kit:canBreak() then
			crystalCluster(kit, side * 8.3, 0, d + 3.5, kit:tint(0.35))
		end
	end
	kit:glow(Vector3.new(15.7, 0.5, 0.5), kit:at(0, 12.55, d), kit.theme.Accent)
	local top = kit:block(Vector3.new(16, 1.2, 1.2), kit:at(0, 13.4, d), VOID_SPACE)
	nameplate(kit, top, kit.theme.Accent)
	kit:glow(Vector3.new(15.2, 0.04, 0.5), kit:at(0, 0.02, d), kit.theme.Accent)
end

-- Dispatch --------------------------------------------------------------------------

local STYLES = {
	Lab = Lab,
	Neon = Neon,
	Temple = Temple,
	Greenhouse = Greenhouse,
	Void = Void,
}

function Decor.decorate(builder, room, info)
	local kit = newKit(builder, room, info)
	local style = STYLES[info.theme.Style] or STYLES.Lab

	style.room(kit)
	if info.isZoneStart then
		style.gate(kit, GATE_DEPTH)
	end

	-- One feature per wall bay, never the same twice in a row on one wall.
	local previous = {}
	for _, d in BAYS do
		if info.isZoneStart and d < GATE_DEPTH + 5 then
			continue -- the gate stands here
		end
		for _, side in SIDES do
			local feature = kit:pickWeighted(style.features)
			if feature == previous[side] then
				feature = kit:pickWeighted(style.features)
			end
			previous[side] = feature
			feature(kit, side, d)
		end
	end

	-- Every room gets a few things to smash.
	for _, d in GLOBE_SPOTS do
		if kit.breakables >= MIN_BREAKABLES then
			break
		end
		ceilingGlobe(kit, kit:random(-4, 4), d)
	end
end

return Decor
