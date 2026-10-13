--[[
	Builds the corridor rooms in front of the camera and deletes the ones behind it.
	Everything here is created on the player's device only, so nobody else sees it.

	Smoothness: building or deleting a whole room in one frame makes phones
	stutter (a room is 150-300 parts), and at top speed a new room comes every
	~1.5 seconds. So nothing here ever does a whole room in one frame:

	  Building - each room is built by its own coroutine (a function that can
	    pause and continue later). Every part goes through newPart, and newPart
	    pauses the coroutine as soon as this frame's build time is used up
	    (Config.ROOM_BUILD_BUDGET, LOW_ROOM_BUILD_BUDGET on Low graphics). The
	    next frame it carries on exactly where it stopped. Order inside a room:
	      1. shell (floor, walls, trim) AND all glass, doors and crystals
	      2. decorations (Decor.luau, through builder.newPart)
	      3. lights (LightingFx.lightRoom)
	    Rooms are started one room earlier than they become visible
	    (Config.ROOMS_AHEAD + 1), so a room is long finished before the camera
	    gets there. Safety net: a room still unfinished when the camera is
	    Config.ROOM_FORCE_DISTANCE away is finished at once (Studio warns,
	    because that means the budget is too small for this device).
	    The room folder goes into the world right away and its parts arrive a few
	    per frame. That is on purpose: adding a part to the world has a cost too,
	    and parenting a finished 300-part folder in one go would be one big
	    spike again. Half-built rooms are a whole room past the fog, so nobody
	    sees them.

	  Deleting - rooms behind the camera go to a trash list and lose a few
	    parts per frame (Config.ROOM_TEARDOWN_BUDGET). They're out of view.

	Room shell parts carry the attribute Shell = true. Everything else of
	kind "Wall" is decoration that a ball can knock loose (see Shatter.knockLoose).

	Zones 6-10 add four obstacles (Config.ZonePatterns): ArmoredGlass (2 hits,
	see crackArmor), BobbingPane (tween), FallingPane (drops when you get close)
	and RingSpinner (a turning wheel of panes). The last two are moved by
	updateMovers every frame, only for finished rooms near the camera.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Decor = require(script.Parent.Decor)
local Models = require(script.Parent.Models)
local LightingFx = require(script.Parent.LightingFx)

local WIDTH = Config.CORRIDOR_WIDTH
local HEIGHT = Config.CORRIDOR_HEIGHT
local LENGTH = Config.ROOM_LENGTH
local ORIGIN = Config.TRACK_ORIGIN
local EYE_Y = ORIGIN.Y + Config.CAMERA_HEIGHT
local BUILD_AHEAD = (Config.ROOMS_AHEAD + 1) * LENGTH -- rooms start building this far ahead (studs)
local CATCH_UP_DISTANCE = 1.5 * LENGTH -- the room being built is this close: build twice as fast
local IS_STUDIO = RunService:IsStudio()

local TrackBuilder = {}
TrackBuilder.__index = TrackBuilder

-- Time slicing -------------------------------------------------------------
-- The coroutine building a room right now, and when this frame's build time ends.
local buildThread = nil
local buildDeadline = math.huge

-- Called before every part is made: if this frame's build time is used up,
-- pause the room's coroutine until the next frame. Does nothing outside a
-- room build (or when a room is being finished right away).
local function pauseIfOverBudget()
	if buildThread ~= nil and os.clock() > buildDeadline and coroutine.running() == buildThread then
		coroutine.yield()
	end
end

-- kind: "Wall" (balls bounce), "Glass" (hazard), "Crystal", "Door", "Button", "Prop" (breakable decoration)
local function newPart(parent, kind, props)
	pauseIfOverBudget()
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for name, value in props do
		part[name] = value
	end
	part:SetAttribute("Kind", kind)
	part.Parent = parent
	return part
end

-- Shell materials per zone style (floor gets its own material and a darker tint).
local SURFACES = {
	Lab = { Wall = Enum.Material.SmoothPlastic, Ceiling = Enum.Material.SmoothPlastic, Floor = Enum.Material.Marble, FloorTint = Color3.fromRGB(120, 125, 135), FloorTintAmount = 0.25 },
	Neon = { Wall = Enum.Material.DiamondPlate, Ceiling = Enum.Material.Metal, Floor = Enum.Material.Slate, FloorTint = Color3.fromRGB(10, 10, 18), FloorTintAmount = 0.5 },
	Temple = { Wall = Enum.Material.Sandstone, Ceiling = Enum.Material.Sandstone, Floor = Enum.Material.Limestone, FloorTint = Color3.fromRGB(150, 110, 70), FloorTintAmount = 0.3 },
	Greenhouse = { Wall = Enum.Material.Concrete, Ceiling = Enum.Material.Glass, Floor = Enum.Material.WoodPlanks, FloorTint = Color3.fromRGB(120, 80, 45), FloorTintAmount = 0.6 },
	Void = { Wall = Enum.Material.Basalt, Ceiling = Enum.Material.Basalt, Floor = Enum.Material.Slate, FloorTint = Color3.fromRGB(10, 5, 20), FloorTintAmount = 0.4 },
	Frost = { Wall = Enum.Material.Glacier, Ceiling = Enum.Material.Ice, Floor = Enum.Material.Glacier, FloorTint = Color3.fromRGB(150, 190, 225), FloorTintAmount = 0.3 },
	Magma = { Wall = Enum.Material.Basalt, Ceiling = Enum.Material.Basalt, Floor = Enum.Material.CrackedLava, FloorTint = Color3.fromRGB(35, 18, 12), FloorTintAmount = 0.35 },
	Aquarium = { Wall = Enum.Material.Slate, Ceiling = Enum.Material.Metal, Floor = Enum.Material.Sand, FloorTint = Color3.fromRGB(200, 180, 130), FloorTintAmount = 0.6 },
	Sky = { Wall = Enum.Material.Marble, Ceiling = Enum.Material.Marble, Floor = Enum.Material.Marble, FloorTint = Color3.fromRGB(225, 195, 135), FloorTintAmount = 0.25 },
	Core = { Wall = Enum.Material.Slate, Ceiling = Enum.Material.Basalt, Floor = Enum.Material.Marble, FloorTint = Color3.fromRGB(14, 8, 28), FloorTintAmount = 0.5 },
}

-- New obstacles (zones 6+) ----------------------------------------------------------
local ARMOR_COLOR = Color3.fromRGB(105, 150, 185) -- thick tinted glass
local ARMOR_CRACKED_COLOR = Color3.fromRGB(70, 100, 130)
local ARMOR_EDGE_COLOR = Color3.fromRGB(45, 52, 62)
local CRACK_COLOR = Color3.fromRGB(225, 245, 255)
local WARNING_COLOR = Color3.fromRGB(255, 170, 30)
local FALL_TRIGGER_DISTANCE = 70 -- a FallingPane drops when the camera is this close (studs)
local FALL_TIME = 0.4 -- seconds the drop takes
local RING_SLOTS = 8 -- RingSpinner: 8 places around the wheel, 6 have a pane (a 2-slot gap)
local RING_PANES = 6
local RING_CENTER_HEIGHT = 9.5 -- above the floor; the wheel turns above the middle of the corridor
local RING_INNER, RING_OUTER = 1, 4.4 -- each pane runs from this far from the center to this far
local SPIN_RANGE = 260 -- RingSpinners further ahead than this (studs) stand still (past the fog)
-- The wheel turns with the distance you fly, not with time: whatever your speed
-- (slow-mo, a pause...) the marked pane is exactly at the bottom when you get there.
-- Radians turned per stud flown (at 55 studs/s that is a slow 0.5-0.77 radians per second).
local RING_TURN_PER_STUD = { 0.009, 0.014 }
local RING_TARGET_TINT = 0.45 -- how orange the marked pane is

-- Groups of obstacles in one room are spread evenly, but never closer than this (studs).
local MIN_GROUP_SPACING = 20

-- Glass visibility: less see-through than before, plus a glowing outline.
local GLASS_TRANSPARENCY = 0.2
local GLASS_OUTLINE_THICKNESS = 0.07
local GLASS_OUTLINE_SURFACE = 0.82 -- the light tint inside the outline (Low graphics: edges only)
-- Outlines only show in the camera's room and the next OUTLINE_ROOMS rooms (a
-- room switches them on as it becomes the 2nd room ahead, 160+ studs away, so
-- glass always has its outline long before it's close). Further rooms are past the fog.
local OUTLINE_ROOMS = 2
-- Small "extra" panes (the far parts of a Grid) only get an outline while the
-- room has fewer than this many; the panes that matter always get one.
local OUTLINE_CAP_PER_ROOM = 12

-- Shared with Decor.luau.
TrackBuilder.newPart = newPart
TrackBuilder.WIDTH = WIDTH
TrackBuilder.HEIGHT = HEIGHT
TrackBuilder.LENGTH = LENGTH
TrackBuilder.ORIGIN = ORIGIN
TrackBuilder.EYE_Y = EYE_Y
TrackBuilder.Models = Models

function TrackBuilder.themeFor(roomIndex)
	local checkpoint = roomIndex // Config.ROOMS_PER_CHECKPOINT
	return Config.Themes[checkpoint % #Config.Themes + 1]
end

function TrackBuilder.roomStartZ(roomIndex)
	return ORIGIN.Z - roomIndex * LENGTH
end

-- tutorial = true builds the scripted first-run rooms (see buildTutorialRoom).
function TrackBuilder.new(parent, firstRoom, tutorial)
	local self = setmetatable({}, TrackBuilder)
	self.tutorial = tutorial == true
	self.tutorialTargets = {} -- step number -> part the player must break/collect
	self.folder = Instance.new("Folder")
	self.folder.Name = "Track"
	self.folder.Parent = parent
	self.rooms = {} -- roomIndex -> { folder, glass = { Part }, doors = { door }, crystals = { Part } }
	self.doorOf = setmetatable({}, { __mode = "k" }) -- door panel / button -> door
	self.nextRoom = firstRoom or 0
	self.rng = Random.new()
	self.buildQueue = {} -- rooms still being built, nearest first: { roomIndex, thread, done }
	self.trash = {} -- rooms behind the camera, deleted a few parts per frame: { folder, children, index }
	self.hazardList = {} -- cached result of hazards()
	self.hazardsDirty = true
	self.shadowRoom = nil -- room index the shadow lights were last set for
	self.warmedUp = false
	return self
end

-- optional = true: a small extra pane (part of a Grid) that only gets an outline
-- while the room is under OUTLINE_CAP_PER_ROOM outlines.
function TrackBuilder:addGlass(room, position, size, optional)
	local glass = newPart(room.folder, "Glass", {
		Name = "Glass",
		Size = size,
		CFrame = CFrame.new(position),
		Material = Enum.Material.Glass,
		Color = Config.GLASS_COLOR,
		Transparency = GLASS_TRANSPARENCY,
		Reflectance = 0.15,
	})

	-- Glowing outline + light tint so glass is always easy to see, even far
	-- away in the fog or against pale walls. It follows moving/spinning panes
	-- and disappears with the pane when it shatters. Hidden until the room is
	-- near (setOutlinesNear), and edges only on Low graphics.
	if not optional or #room.outlines < OUTLINE_CAP_PER_ROOM then
		local accent = if room.theme and room.theme.Accent then room.theme.Accent else Color3.fromRGB(90, 200, 255)
		local outline = Instance.new("SelectionBox")
		outline.Name = "Outline"
		outline.Adornee = glass
		outline.Color3 = accent:Lerp(Color3.new(1, 1, 1), 0.25)
		outline.LineThickness = GLASS_OUTLINE_THICKNESS
		outline.SurfaceColor3 = accent
		outline.SurfaceTransparency = if LightingFx.isLow() then 1 else GLASS_OUTLINE_SURFACE
		outline.Visible = room.outlinesOn == true
		outline.Parent = glass
		table.insert(room.outlines, outline)
	end

	table.insert(room.glass, glass)
	return glass
end

-- Switches a room's glass outlines on (it's one of the rooms near the camera).
local function showOutlines(room)
	if room.outlinesOn then
		return
	end
	room.outlinesOn = true
	local surface = if LightingFx.isLow() then 1 else GLASS_OUTLINE_SURFACE
	for _, outline in room.outlines do
		if outline.Parent then
			outline.SurfaceTransparency = surface
			outline.Visible = true
		end
	end
end

-- The camera moved into another room: outlines on for it and the next OUTLINE_ROOMS.
-- (Rooms behind are deleted; rooms further ahead still have theirs hidden.)
function TrackBuilder:setOutlinesNear(cameraZ)
	local current = TrackBuilder.roomAt(cameraZ)
	if current == self.outlineRoom then
		return
	end
	self.outlineRoom = current
	for roomIndex = current, current + OUTLINE_ROOMS do
		local room = self.rooms[roomIndex]
		if room then
			showOutlines(room)
		end
	end
end

-- Uses the Blender gem when it's uploaded, a rotated neon cube otherwise.
local function meshCrystal(parent, position)
	local model = Models.place("Crystal", parent, CFrame.new(position), { anchor = "center", kind = "Crystal" })
	if not model then
		return nil
	end
	local gem = model:FindFirstChildWhichIsA("BasePart", true)
	if not gem then
		model:Destroy()
		return nil
	end
	gem.Parent = parent
	model:Destroy()
	gem.Name = "Crystal"
	gem.Material = Enum.Material.Neon
	gem.Color = Config.CRYSTAL_COLOR
	return gem
end

function TrackBuilder:addCrystal(room, position)
	local gem = meshCrystal(room.folder, position)
	if gem then
		table.insert(room.crystals, gem)
		return
	end
	local crystal = newPart(room.folder, "Crystal", {
		Name = "Crystal",
		Size = Vector3.new(1.6, 1.6, 1.6),
		CFrame = CFrame.new(position) * CFrame.Angles(math.rad(45), 0, math.rad(45)),
		Material = Enum.Material.Neon,
		Color = Config.CRYSTAL_COLOR,
	})
	table.insert(room.crystals, crystal)
end

local function patternsForZone(zone)
	return Config.ZonePatterns[math.min(zone + 1, #Config.ZonePatterns)]
end

-- Loops a part between two CFrames forever. Destroying the part stops it.
local function animate(part, goal, duration, reverses)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, reverses)
	TweenService:Create(part, info, { CFrame = goal }):Play()
end

TrackBuilder.Patterns = {}
local Patterns = TrackBuilder.Patterns

-- A pane right in front of you, slightly off center.
function Patterns.Window(self, room, z)
	local x = ORIGIN.X + self.rng:NextNumber(-2, 2)
	self:addGlass(room, Vector3.new(x, EYE_Y, z), Vector3.new(8, 8, 0.4))
end

-- Tall panes across the corridor, one always in the middle.
function Patterns.Pillars(self, room, z)
	for _, x in { -7, 0, 7 } do
		self:addGlass(room, Vector3.new(ORIGIN.X + x, ORIGIN.Y + HEIGHT / 2, z), Vector3.new(4, HEIGHT, 0.4))
	end
end

-- A wide horizontal pane at eye level.
function Patterns.Beam(self, room, z)
	self:addGlass(room, Vector3.new(ORIGIN.X, EYE_Y, z), Vector3.new(WIDTH, 3, 0.4))
end

-- Blocks the whole corridor.
function Patterns.FullWall(self, room, z)
	self:addGlass(room, Vector3.new(ORIGIN.X, ORIGIN.Y + HEIGHT / 2, z), Vector3.new(WIDTH, HEIGHT, 0.4))
end

-- Two panes close together: one throw won't clear both.
function Patterns.Double(self, room, z)
	self:addGlass(room, Vector3.new(ORIGIN.X, EYE_Y, z), Vector3.new(10, 8, 0.4))
	self:addGlass(room, Vector3.new(ORIGIN.X, EYE_Y, z - 6), Vector3.new(10, 8, 0.4))
end

-- A pane sliding side to side.
function Patterns.Moving(self, room, z)
	local rng = self.rng
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	local from = CFrame.new(ORIGIN.X + 6 * side, EYE_Y, z)
	local to = CFrame.new(ORIGIN.X - 6 * side, EYE_Y, z)
	local glass = self:addGlass(room, from.Position, Vector3.new(7, 8, 0.4))
	animate(glass, to, rng:NextNumber(1.4, 2.4), true)
end

-- Spinning glass blades, like a fan.
function Patterns.Spinner(self, room, z)
	local center = CFrame.new(ORIGIN.X, EYE_Y, z)
	local duration = self.rng:NextNumber(2, 3.2)
	for _, startAngle in { 0, math.pi / 2 } do
		local from = center * CFrame.Angles(0, 0, startAngle)
		local blade = self:addGlass(room, from.Position, Vector3.new(HEIGHT - 1, 2.5, 0.4))
		blade.CFrame = from
		-- A blade turned half a circle looks identical, so the loop is seamless.
		animate(blade, from * CFrame.Angles(0, 0, math.pi), duration, false)
	end
end

-- A wall of small panes. You need several throws (or multiball) to clear a hole.
-- The eye-level and bottom rows always get an outline; the top row only while
-- the room has few outlines (it's above your head, the rows below show the wall).
function Patterns.Grid(self, room, z)
	for _, x in { -5, 0, 5 } do
		for _, y in { 2.5, 6.5, 10.5 } do
			self:addGlass(room, Vector3.new(ORIGIN.X + x, ORIGIN.Y + y, z), Vector3.new(4.6, 3.8, 0.4), y > 10)
		end
	end
end

-- A see-through detail that belongs to a pane: never hit by balls or crashes
-- (CanQuery off) and gone when the pane shatters (it's parented to the pane).
local function paneDetail(pane, size, cframe, color, material)
	local part = newPart(pane, "Detail", {
		Name = "Detail",
		Size = size,
		CFrame = cframe,
		Color = color,
		Material = material,
		CanQuery = false,
	})
	return part
end

-- Thick tinted glass with a metal edge. The first hit only cracks it
-- (TrackBuilder:crackArmor), the second one breaks it. Mega balls and crashing
-- into it break it right away. Sometimes a bonus crystal hides behind it.
function Patterns.ArmoredGlass(self, room, z)
	local rng = self.rng
	local width = rng:NextNumber(9, 11)
	local height = 9
	local x = ORIGIN.X + rng:NextNumber(-1.5, 1.5)
	local center = Vector3.new(x, ORIGIN.Y + 1.5 + height / 2, z)
	local glass = self:addGlass(room, center, Vector3.new(width, height, 0.8))
	glass.Name = "ArmoredGlass"
	glass.Color = ARMOR_COLOR
	glass.Transparency = 0.2
	glass.Reflectance = 0.3
	glass:SetAttribute("Armor", 1) -- extra hits it can take
	-- Metal edge on the side facing the player.
	local front = z + 0.45
	for _, sx in { -1, 1 } do
		paneDetail(glass, Vector3.new(0.35, height, 0.12), CFrame.new(x + sx * (width / 2 - 0.175), center.Y, front), ARMOR_EDGE_COLOR, Enum.Material.DiamondPlate)
	end
	for _, sy in { -1, 1 } do
		paneDetail(glass, Vector3.new(width, 0.35, 0.12), CFrame.new(x, center.Y + sy * (height / 2 - 0.175), front), ARMOR_EDGE_COLOR, Enum.Material.DiamondPlate)
	end
	if rng:NextNumber() < Config.ARMOR_BONUS_CRYSTAL_CHANCE then
		self:addCrystal(room, Vector3.new(x + rng:NextNumber(-2, 2), EYE_Y + rng:NextNumber(-1, 2), z - 3))
	end
end

-- Armored glass was hit: the first hit cracks it (darker, with glowing crack
-- lines from the hit point) and returns true, so the ball bounces off.
-- Returns false when the pane should shatter now (plain glass, or already cracked).
function TrackBuilder:crackArmor(glass, hitPoint)
	local armor = glass:GetAttribute("Armor")
	if type(armor) ~= "number" or armor <= 0 then
		return false
	end
	glass:SetAttribute("Armor", armor - 1)
	glass.Color = ARMOR_CRACKED_COLOR
	glass.Transparency = 0.25
	local cf = glass.CFrame
	local half = glass.Size / 2
	local hit = cf:PointToObjectSpace(hitPoint)
	local hx = math.clamp(hit.X, -half.X * 0.8, half.X * 0.8)
	local hy = math.clamp(hit.Y, -half.Y * 0.8, half.Y * 0.8)
	local front = half.Z + 0.03
	for i = 1, 6 do
		local angle = (i + self.rng:NextNumber(-0.35, 0.35)) * math.pi / 3
		local length = self.rng:NextNumber(1.8, 3.6)
		local endX = math.clamp(hx + math.cos(angle) * length, -half.X, half.X)
		local endY = math.clamp(hy + math.sin(angle) * length, -half.Y, half.Y)
		local a, b = Vector3.new(hx, hy, front), Vector3.new(endX, endY, front)
		local mid = (a + b) / 2
		local span = (b - a).Magnitude
		if span > 0.2 then
			local line = cf * CFrame.new(mid) * CFrame.Angles(0, 0, math.atan2(b.Y - a.Y, b.X - a.X))
			paneDetail(glass, Vector3.new(span, 0.08, 0.05), line, CRACK_COLOR, Enum.Material.Neon)
		end
	end
	return true
end

-- A pane that bobs up and down across your path.
function Patterns.BobbingPane(self, room, z)
	local rng = self.rng
	local x = ORIGIN.X + rng:NextNumber(-1.5, 1.5)
	-- Low: from 2 to 7 studs up, so its top edge is a full stud above your eyes
	-- (it clearly covers them, and the crash check agrees with what you see).
	local low = CFrame.new(x, ORIGIN.Y + 4.5, z)
	local high = CFrame.new(x, ORIGIN.Y + 10.5, z) -- you fly under it
	local startHigh = rng:NextNumber() < 0.5
	local glass = self:addGlass(room, (if startHigh then high else low).Position, Vector3.new(rng:NextNumber(10, 12), 5, 0.4))
	local info = TweenInfo.new(rng:NextNumber(1.1, 1.8), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(glass, info, { CFrame = if startHigh then low else high }):Play()
end

-- A pane waiting in a slot in the ceiling (its bottom edge shows, with blinking
-- warning lights and a stripe on the floor). It drops into your path when you
-- get close (TrackBuilder:update). Smash the edge early to stop it.
function Patterns.FallingPane(self, room, z)
	local rng = self.rng
	local width = rng:NextNumber(10, 13)
	local height = 9
	local x = ORIGIN.X + rng:NextNumber(-1, 1)
	local downY = ORIGIN.Y + 1.5 + height / 2
	local upY = ORIGIN.Y + 12.6 + height / 2 -- only the bottom 1.4 studs show below the ceiling
	local glass = self:addGlass(room, Vector3.new(x, upY, z), Vector3.new(width, height, 0.4))
	table.insert(room.fallers, { glass = glass, goal = CFrame.new(x, downY, z), dropped = false })

	-- Warning: blinking lights hanging beside the pane's edge (below anything a
	-- zone hangs on its ceiling, so decor can never hide them) and a dashed
	-- stripe on the floor.
	local blink = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local lightY = upY - height / 2 + 0.15 -- level with the pane's bottom edge
	for _, side in { -1, 1 } do
		local lightX = x + side * (width / 2 + 0.7)
		local rod = newPart(room.folder, "Wall", {
			Name = "WarningRod",
			Size = Vector3.new(0.15, ORIGIN.Y + HEIGHT - lightY, 0.15),
			CFrame = CFrame.new(lightX, (ORIGIN.Y + HEIGHT + lightY) / 2, z),
			Color = Color3.fromRGB(60, 64, 74),
			Material = Enum.Material.Metal,
		})
		rod:SetAttribute("Shell", true)
		local light = newPart(room.folder, "Wall", {
			Name = "Warning",
			Size = Vector3.new(0.8, 0.3, 0.8),
			CFrame = CFrame.new(lightX, lightY, z),
			Color = WARNING_COLOR,
			Material = Enum.Material.Neon,
		})
		light:SetAttribute("Shell", true)
		TweenService:Create(light, blink, { Transparency = 0.85 }):Play()
	end
	for i = -2, 2 do
		local stripe = newPart(room.folder, "Wall", {
			Name = "WarningStripe",
			Size = Vector3.new(width / 6, 0.04, 0.6),
			CFrame = CFrame.new(x + i * width / 5, ORIGIN.Y + 0.03, z),
			Color = WARNING_COLOR,
			Material = Enum.Material.Neon,
		})
		stripe:SetAttribute("Shell", true)
	end
end

-- Six panes on a wheel turning slowly above the middle of the corridor.
-- One pane is marked orange: the wheel turns with the distance you fly, so that
-- pane is always exactly at the bottom, in your way, when you get there. Smash
-- it early (then the empty slot passes over you). Turned by updateMovers.
function Patterns.RingSpinner(self, room, z)
	local rng = self.rng
	local center = CFrame.new(ORIGIN.X, ORIGIN.Y + RING_CENTER_HEIGHT, z)
	local direction = if rng:NextNumber() < 0.5 then -1 else 1
	local target = rng:NextInteger(0, RING_PANES - 1) -- the pane that ends up at the bottom
	local firstSlot = rng:NextInteger(0, RING_SLOTS - 1)
	local targetSlotAngle = (firstSlot + target) * 2 * math.pi / RING_SLOTS
	local ring = {
		center = center,
		-- Ring angle when the camera reaches the wheel: the target pane points down
		-- (a pane at angle 0 points up, so down is pi).
		arrivalAngle = math.pi - targetSlotAngle,
		turnPerStud = rng:NextNumber(RING_TURN_PER_STUD[1], RING_TURN_PER_STUD[2]) * direction,
		lastDistance = nil,
		panes = {},
	}
	ring.angle = ring.arrivalAngle + ring.turnPerStud * SPIN_RANGE -- standing still until in range
	local length = RING_OUTER - RING_INNER
	local offset = CFrame.new(0, RING_INNER + length / 2, 0)
	for i = 0, RING_PANES - 1 do
		local slotAngle = (firstSlot + i) * 2 * math.pi / RING_SLOTS
		local glass = self:addGlass(room, center.Position, Vector3.new(1.6, length, 0.4))
		glass.CFrame = center * CFrame.Angles(0, 0, ring.angle + slotAngle) * offset
		if i == target then
			glass.Color = Config.GLASS_COLOR:Lerp(WARNING_COLOR, RING_TARGET_TINT)
			local outline = glass:FindFirstChild("Outline")
			if outline then
				outline.Color3 = WARNING_COLOR
				outline.SurfaceColor3 = WARNING_COLOR
			end
		end
		table.insert(ring.panes, { glass = glass, slotAngle = slotAngle, offset = offset })
	end
	-- Hub the panes hang on (above your head, so it never gets in the way).
	local hub = newPart(room.folder, "Wall", {
		Name = "RingHub",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 1.4, 1.4),
		CFrame = center * CFrame.Angles(0, math.rad(90), 0),
		Color = Color3.fromRGB(60, 64, 74),
		Material = Enum.Material.Metal,
	})
	hub:SetAttribute("Shell", true)
	table.insert(room.rings, ring)
end

-- Metal doors you can't break. Hit the red button to open them.
function Patterns.Door(self, room, z)
	local half = WIDTH / 2
	local doorSize = Vector3.new(half, HEIGHT, 1)
	local y = ORIGIN.Y + HEIGHT / 2
	local door = { open = false, panels = {} }

	for _, side in { -1, 1 } do
		local panel = newPart(room.folder, "Door", {
			Name = "Door",
			Size = doorSize,
			CFrame = CFrame.new(ORIGIN.X + side * half / 2, y, z),
			Material = Enum.Material.DiamondPlate,
			Color = Config.DOOR_COLOR,
		})
		panel:SetAttribute("Side", side)
		table.insert(door.panels, panel)
		self.doorOf[panel] = door
	end

	local buttonX = ORIGIN.X + self.rng:NextNumber(-5, 5)
	local buttonY = ORIGIN.Y + self.rng:NextNumber(4, HEIGHT - 4)
	door.button = newPart(room.folder, "Button", {
		Name = "Button",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 3, 3),
		CFrame = CFrame.new(buttonX, buttonY, z + 0.7) * CFrame.Angles(0, math.rad(90), 0),
		Material = Enum.Material.Neon,
		Color = Config.BUTTON_COLOR,
	})
	self.doorOf[door.button] = door
	table.insert(room.doors, door)
end

function TrackBuilder:openDoor(door)
	if door.open then
		return
	end
	door.open = true
	self.hazardsDirty = true
	-- The button pops (quick swell, then shrinks away) so it doesn't stay
	-- floating in the middle of the path once the doors slide open.
	local button = door.button
	button.Color = Color3.fromRGB(80, 255, 120)
	button.CanQuery = false
	local swell = TweenService:Create(button, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = button.Size * 1.4,
	})
	local vanish = TweenService:Create(button, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
		Size = Vector3.new(0.05, 0.05, 0.05),
		Transparency = 1,
	})
	swell.Completed:Connect(function()
		vanish:Play()
	end)
	vanish.Completed:Connect(function()
		button:Destroy()
	end)
	swell:Play()

	for _, panel in door.panels do
		local side = panel:GetAttribute("Side")
		local goal = panel.CFrame + Vector3.new(side * WIDTH / 2, 0, 0)
		TweenService:Create(panel, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { CFrame = goal }):Play()
	end
end

-- Returns the door a button or door panel belongs to.
function TrackBuilder:doorFor(part)
	return self.doorOf[part]
end

-- One group of obstacles at depth z, picked from what this zone allows.
function TrackBuilder:addObstacle(room, z, zone)
	local patterns = patternsForZone(zone)
	local name = patterns[self.rng:NextInteger(1, #patterns)]
	local glassBefore, doorsBefore = #room.glass, #room.doors
	Patterns[name](self, room, z)

	-- Label what was just built so first-time tips know what they're looking at.
	for i = glassBefore + 1, #room.glass do
		room.glass[i]:SetAttribute("Pattern", name)
	end
	for i = doorsBefore + 1, #room.doors do
		for _, panel in room.doors[i].panels do
			panel:SetAttribute("Pattern", name)
		end
	end
end

-- The first-run tutorial: one simple lesson per room. Each lesson's target is
-- remembered so the Tutorial module can slow time and point at it.
function TrackBuilder:buildTutorialRoom(room, roomIndex, startZ)
	local step = table.find(Config.TUTORIAL_ROOMS, roomIndex)
	if step == 1 then
		-- Lesson 1: a single pane right in front of you.
		self.tutorialTargets[1] = self:addGlass(room, Vector3.new(ORIGIN.X, EYE_Y, startZ - 40), Vector3.new(8, 8, 0.4))
	elseif step == 2 then
		-- Lesson 2: a crystal, then an easy pane.
		self:addCrystal(room, Vector3.new(ORIGIN.X + 2, EYE_Y + 1, startZ - 30))
		self.tutorialTargets[2] = room.crystals[#room.crystals]
		self:addGlass(room, Vector3.new(ORIGIN.X, EYE_Y, startZ - 62), Vector3.new(8, 8, 0.4))
	elseif step == 3 then
		-- Lesson 3: a full wall you must break or crash into.
		self.tutorialTargets[3] =
			self:addGlass(room, Vector3.new(ORIGIN.X, ORIGIN.Y + HEIGHT / 2, startZ - 40), Vector3.new(WIDTH, HEIGHT, 0.4))
		self:addCrystal(room, Vector3.new(ORIGIN.X - 4, EYE_Y - 1, startZ - 55))
	end
end

-- Step 1: the room's shell plus everything you can crash into or collect.
function TrackBuilder:buildShell(roomIndex)
	local theme = TrackBuilder.themeFor(roomIndex)
	local startZ = TrackBuilder.roomStartZ(roomIndex)
	local centerZ = startZ - LENGTH / 2
	local rng = self.rng

	local zone = roomIndex // Config.ROOMS_PER_CHECKPOINT
	local isZoneStart = roomIndex % Config.ROOMS_PER_CHECKPOINT == 0

	-- The folder goes into the world now and fills up over the next frames
	-- (see the notes at the top).
	local folder = Instance.new("Folder")
	folder.Name = "Room" .. roomIndex
	folder.Parent = self.folder
	-- fallers: FallingPanes still waiting to drop; rings: RingSpinners to turn (both in update).
	-- outlines: the glass outlines (SelectionBoxes), shown once the room is near (setOutlinesNear).
	local room = {
		folder = folder,
		theme = theme,
		glass = {},
		doors = {},
		crystals = {},
		fallers = {},
		rings = {},
		outlines = {},
		outlinesOn = self.outlineRoom ~= nil and roomIndex <= self.outlineRoom + OUTLINE_ROOMS,
		finished = false,
	}
	self.rooms[roomIndex] = room

	-- Shell parts collide so glass shards can bounce off the floor and walls.
	-- Real surface materials per zone instead of flat plastic.
	local surfaces = SURFACES[theme.Style] or SURFACES.Lab
	local wallProps = { Color = theme.Wall, Material = surfaces.Wall, CanCollide = true }
	-- Shell parts are marked so balls never knock them loose.
	local function shellPart(props)
		newPart(folder, "Wall", props):SetAttribute("Shell", true)
	end
	local function wall(size, position, material, color)
		local props = table.clone(wallProps)
		props.Size = size
		props.CFrame = CFrame.new(position)
		props.Material = material or props.Material
		props.Color = color or props.Color
		shellPart(props)
	end
	local floorColor = theme.Wall:Lerp(surfaces.FloorTint, surfaces.FloorTintAmount)
	wall(Vector3.new(WIDTH, 1, LENGTH), Vector3.new(ORIGIN.X, ORIGIN.Y - 0.5, centerZ), surfaces.Floor, floorColor)
	wall(Vector3.new(WIDTH, 1, LENGTH), Vector3.new(ORIGIN.X, ORIGIN.Y + HEIGHT + 0.5, centerZ), surfaces.Ceiling)
	wall(Vector3.new(1, HEIGHT, LENGTH), Vector3.new(ORIGIN.X - WIDTH / 2 - 0.5, ORIGIN.Y + HEIGHT / 2, centerZ))
	wall(Vector3.new(1, HEIGHT, LENGTH), Vector3.new(ORIGIN.X + WIDTH / 2 + 0.5, ORIGIN.Y + HEIGHT / 2, centerZ))

	-- Glowing door frame at the start of each room gives a sense of speed.
	local accent = { Color = theme.Accent, Material = Enum.Material.Neon }
	local function trim(size, position)
		local props = table.clone(accent)
		props.Size = size
		props.CFrame = CFrame.new(position)
		shellPart(props)
	end
	trim(Vector3.new(WIDTH, 0.4, 0.4), Vector3.new(ORIGIN.X, ORIGIN.Y + 0.2, startZ))
	trim(Vector3.new(WIDTH, 0.4, 0.4), Vector3.new(ORIGIN.X, ORIGIN.Y + HEIGHT - 0.2, startZ))
	trim(Vector3.new(0.4, HEIGHT, 0.4), Vector3.new(ORIGIN.X - WIDTH / 2 + 0.2, ORIGIN.Y + HEIGHT / 2, startZ))
	trim(Vector3.new(0.4, HEIGHT, 0.4), Vector3.new(ORIGIN.X + WIDTH / 2 - 0.2, ORIGIN.Y + HEIGHT / 2, startZ))

	-- Glowing strips along the floor edges.
	for _, side in { -1, 1 } do
		trim(Vector3.new(0.3, 0.15, LENGTH), Vector3.new(ORIGIN.X + side * (WIDTH / 2 - 0.4), ORIGIN.Y + 0.08, centerZ))
	end

	-- Ribs along the walls every 10 studs.
	for ribZ = startZ - 10, startZ - LENGTH + 1, -10 do
		for _, side in { -1, 1 } do
			local props = table.clone(wallProps)
			props.Size = Vector3.new(0.6, HEIGHT, 1.2)
			props.CFrame = CFrame.new(ORIGIN.X + side * (WIDTH / 2 - 0.3), ORIGIN.Y + HEIGHT / 2, ribZ)
			props.Color = theme.Wall:Lerp(Color3.new(0, 0, 0), 0.12)
			shellPart(props)
		end
	end

	-- Big double gate marks the start of every new zone.
	if isZoneStart then
		for _, offset in { 0, -2 } do
			trim(Vector3.new(WIDTH, 1, 1), Vector3.new(ORIGIN.X, ORIGIN.Y + HEIGHT - 0.5, startZ + offset))
			trim(Vector3.new(1, HEIGHT, 1), Vector3.new(ORIGIN.X - WIDTH / 2 + 0.5, ORIGIN.Y + HEIGHT / 2, startZ + offset))
			trim(Vector3.new(1, HEIGHT, 1), Vector3.new(ORIGIN.X + WIDTH / 2 - 0.5, ORIGIN.Y + HEIGHT / 2, startZ + offset))
		end
	end

	if self.tutorial and table.find(Config.TUTORIAL_ROOMS, roomIndex) then
		self:buildTutorialRoom(room, roomIndex, startZ)
	elseif roomIndex >= Config.SAFE_ROOMS and not isZoneStart then
		-- Difficulty climbs inside each zone and keeps climbing zone to zone
		-- (Config.difficultyFor). More difficulty = more obstacle groups, up to 4.
		-- The 4th only comes in the endless zones after the designed ones (ZONE 10+),
		-- and then the groups are 20 studs apart (MIN_GROUP_SPACING), never closer.
		local difficulty = Config.difficultyFor(zone, roomIndex % Config.ROOMS_PER_CHECKPOINT)

		local groups = 1
		if rng:NextNumber() < difficulty then
			groups += 1
		end
		if rng:NextNumber() < difficulty * 0.6 then
			groups += 1
		end
		if zone >= #Config.ZoneDifficulty and rng:NextNumber() < (difficulty - 1) * 0.6 then
			groups += 1
		end
		-- Evenly spread (1 group: the middle; 3 groups: 20/40/60), centered in the room.
		local spacing = math.max(LENGTH / (groups + 1), MIN_GROUP_SPACING)
		local first = (LENGTH - spacing * (groups - 1)) / 2
		for group = 1, groups do
			self:addObstacle(room, startZ - (first + spacing * (group - 1)), zone)
		end

		-- Fewer crystals in later zones (Config.ZoneCrystals), so every ball counts.
		local crystalRange = Config.ZoneCrystals[math.min(zone + 1, #Config.ZoneCrystals)]
		for _ = 1, rng:NextInteger(crystalRange[1], crystalRange[2]) do
			local position = Vector3.new(
				ORIGIN.X + rng:NextNumber(-7, 7),
				ORIGIN.Y + rng:NextNumber(3, HEIGHT - 3),
				startZ - rng:NextNumber(10, LENGTH - 10)
			)
			self:addCrystal(room, position)
		end
	end

	-- Glass, doors and crystals all exist now: crash checks can see them.
	self.hazardsDirty = true

	return room,
		{
			roomIndex = roomIndex,
			zone = zone,
			theme = theme,
			startZ = startZ,
			isZoneStart = isZoneStart,
			rng = rng,
			low = LightingFx.isLow(), -- Low graphics: Decor skips its little animations
		}
end

-- The whole build of one room, run inside its coroutine (pauses in newPart).
function TrackBuilder:buildRoomSteps(roomIndex)
	local room, info = self:buildShell(roomIndex)
	Decor.decorate(self, room, info)
	-- Real lights from the room's glowing parts, shadows from decorations.
	LightingFx.lightRoom(room.folder, info.theme, pauseIfOverBudget)
	room.finished = true
end

-- Adds a room to the build queue (rooms are queued in order, nearest first).
function TrackBuilder:queueRoom(roomIndex)
	local job = { roomIndex = roomIndex, done = false }
	job.thread = coroutine.create(function()
		self:buildRoomSteps(roomIndex)
	end)
	table.insert(self.buildQueue, job)
end

-- Continues a room's build until it finishes or `deadline` (os.clock time) passes.
function TrackBuilder:resumeJob(job, deadline)
	buildThread, buildDeadline = job.thread, deadline
	local ok, err = coroutine.resume(job.thread)
	buildThread, buildDeadline = nil, math.huge
	if not ok then
		-- A bug in the build code: report it and move on (the room stays half built).
		warn("[TrackBuilder] room " .. job.roomIndex .. " failed to build: " .. debug.traceback(job.thread, tostring(err)))
	end
	if coroutine.status(job.thread) == "dead" then
		job.done = true
	end
end

-- Builds a whole room right now.
function TrackBuilder:buildRoom(roomIndex)
	self:queueRoom(roomIndex)
	self:finishRoomsUpTo(roomIndex)
end

-- Finishes every queued room up to lastRoomIndex, right now (no time limit).
function TrackBuilder:finishRoomsUpTo(lastRoomIndex)
	local queue = self.buildQueue
	while queue[1] and queue[1].roomIndex <= lastRoomIndex do
		self:resumeJob(queue[1], math.huge)
		table.remove(queue, 1)
	end
end

-- Queues every room that should be building by now.
function TrackBuilder:queueAhead(cameraZ)
	while TrackBuilder.roomStartZ(self.nextRoom) > cameraZ - BUILD_AHEAD do
		self:queueRoom(self.nextRoom)
		self.nextRoom += 1
	end
end

-- Call once right after new(): the room the camera starts in and the next one
-- are built completely now (it's the start of a run, a short pause is fine).
function TrackBuilder:warmUp(cameraZ)
	self:queueAhead(cameraZ)
	self:finishRoomsUpTo(TrackBuilder.roomAt(cameraZ) + 1)
	self.warmedUp = true
	self:update(cameraZ, 0)
end

function TrackBuilder.roomAt(z)
	return math.max(0, (ORIGIN.Z - z) // LENGTH)
end

-- Removes a few parts of the rooms in the trash, within `budget` seconds.
function TrackBuilder:emptyTrash(budget)
	local trash = self.trash
	local deadline = os.clock() + budget
	while trash[1] and os.clock() < deadline do
		local entry = trash[1]
		if not entry.children then
			entry.children = entry.folder:GetChildren()
			entry.index = 0
		end
		local children = entry.children
		-- A handful at a time between clock checks.
		for _ = 1, 4 do
			local i = entry.index + 1
			local child = children[i]
			if child == nil then
				break
			end
			entry.index = i
			child:Destroy()
		end
		if entry.index >= #children then
			entry.folder:Destroy() -- empty now, so this is cheap
			table.remove(trash, 1)
		end
	end
end

-- Shadow-casting lights only in the room the camera is in and the next one.
function TrackBuilder:updateShadowRooms(cameraZ, force)
	local current = TrackBuilder.roomAt(cameraZ)
	if current == self.shadowRoom and not force then
		return
	end
	self.shadowRoom = current
	local here = self.rooms[current]
	local nextRoom = if Config.SHADOW_LIGHT_ROOMS >= 2 then self.rooms[current + 1] else nil
	LightingFx.setShadowRooms(here and here.folder, nextRoom and nextRoom.folder)
end

-- FallingPanes drop when the camera gets close; RingSpinners in view turn.
-- Only finished rooms: a pane still being built has no final CFrame yet.
function TrackBuilder:updateMovers(cameraZ, dt)
	for roomIndex, room in self.rooms do
		if not room.finished then
			continue
		end
		local startZ = TrackBuilder.roomStartZ(roomIndex)
		if startZ - LENGTH > cameraZ or startZ < cameraZ - SPIN_RANGE then
			continue -- behind the camera, or too far ahead to see
		end
		for _, faller in room.fallers do
			local glass = faller.glass
			if not faller.dropped and glass.Parent and cameraZ - glass.Position.Z < FALL_TRIGGER_DISTANCE then
				faller.dropped = true
				local info = TweenInfo.new(FALL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				TweenService:Create(glass, info, { CFrame = faller.goal }):Play()
			end
		end
		for _, ring in room.rings do
			-- Angle from the distance still to fly (0 = the camera is at the wheel).
			local distance = math.clamp(cameraZ - ring.center.Position.Z, 0, SPIN_RANGE)
			if distance ~= ring.lastDistance then
				ring.lastDistance = distance
				ring.angle = ring.arrivalAngle + ring.turnPerStud * distance
				for _, pane in ring.panes do
					local glass = pane.glass
					if glass.Parent then
						glass.CFrame = ring.center * CFrame.Angles(0, 0, ring.angle + pane.slotAngle) * pane.offset
					end
				end
			end
		end
	end
end

-- Call every frame with the camera's Z position.
function TrackBuilder:update(cameraZ, dt)
	local frameStart = os.clock()
	local low = LightingFx.isLow()

	-- Spin the crystals close enough to see (rooms ahead, within CRYSTAL_SPIN_RANGE).
	if dt > 0 then
		local spin = CFrame.Angles(0, dt * 2, 0)
		local spinRange = Config.CRYSTAL_SPIN_RANGE
		for roomIndex, room in self.rooms do
			local startZ = TrackBuilder.roomStartZ(roomIndex)
			if startZ - LENGTH < cameraZ and startZ > cameraZ - spinRange then
				for _, crystal in room.crystals do
					if crystal.Parent and crystal.CanQuery then
						crystal.CFrame = crystal.CFrame * spin
					end
				end
			end
		end
	end

	self:updateMovers(cameraZ, dt)

	self:queueAhead(cameraZ)
	self:setOutlinesNear(cameraZ)

	-- Safety net: never let the camera reach an unfinished room.
	local queue = self.buildQueue
	while queue[1] and TrackBuilder.roomStartZ(queue[1].roomIndex) > cameraZ - Config.ROOM_FORCE_DISTANCE do
		if IS_STUDIO and self.warmedUp then
			warn(
				"[TrackBuilder] room "
					.. queue[1].roomIndex
					.. " was not finished in time and was built in one frame (raise ROOM_BUILD_BUDGET?)"
			)
		end
		self:resumeJob(queue[1], math.huge)
		table.remove(queue, 1)
	end

	-- Rooms ahead: only while this frame's build time lasts. Twice the time
	-- when the room being built is getting close (slow device).
	local budget = if low then Config.LOW_ROOM_BUILD_BUDGET else Config.ROOM_BUILD_BUDGET
	if queue[1] and TrackBuilder.roomStartZ(queue[1].roomIndex) > cameraZ - CATCH_UP_DISTANCE then
		budget *= 2
	end
	local deadline = frameStart + budget
	while queue[1] and os.clock() < deadline do
		self:resumeJob(queue[1], deadline)
		if queue[1].done then
			table.remove(queue, 1)
		end
	end

	-- Rooms behind the camera go to the trash...
	for roomIndex, room in self.rooms do
		local endZ = TrackBuilder.roomStartZ(roomIndex) - LENGTH
		if endZ > cameraZ + 10 then
			self.rooms[roomIndex] = nil
			self.hazardsDirty = true
			table.insert(self.trash, { folder = room.folder })
		end
	end
	-- ...which is emptied a little every frame.
	self:emptyTrash(if low then Config.LOW_ROOM_TEARDOWN_BUDGET else Config.ROOM_TEARDOWN_BUDGET)

	self:updateShadowRooms(cameraZ, false)
end

-- Something you can crash into changed (glass broken). hazards() rebuilds its list next time.
function TrackBuilder:markHazardsChanged()
	self.hazardsDirty = true
end

-- Everything you can crash into: unbroken glass and closed doors.
-- The list is cached and only rebuilt when something changed (a room was
-- added or removed, glass broke, a door opened), so calling this every frame
-- costs nothing. Don't change the returned table. Entries can go stale within
-- a frame (glass broken mid-loop): check hazard.Parent / door.open as before.
function TrackBuilder:hazards()
	local result = self.hazardList
	if not self.hazardsDirty then
		return result
	end
	self.hazardsDirty = false
	table.clear(result)
	for _, room in self.rooms do
		for _, glass in room.glass do
			if glass.Parent then
				table.insert(result, glass)
			end
		end
		for _, door in room.doors do
			if not door.open then
				for _, panel in door.panels do
					table.insert(result, panel)
				end
			end
		end
	end
	return result
end

function TrackBuilder:destroy()
	self.folder:Destroy()
end

return TrackBuilder
