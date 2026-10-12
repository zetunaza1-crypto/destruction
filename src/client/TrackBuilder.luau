--[[
	Builds the corridor rooms in front of the camera and deletes the ones behind it.
	Everything here is created on the player's device only, so nobody else sees it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local WIDTH = Config.CORRIDOR_WIDTH
local HEIGHT = Config.CORRIDOR_HEIGHT
local LENGTH = Config.ROOM_LENGTH
local ORIGIN = Config.TRACK_ORIGIN
local EYE_Y = ORIGIN.Y + Config.CAMERA_HEIGHT

local TrackBuilder = {}
TrackBuilder.__index = TrackBuilder

local function newPart(parent, kind, props)
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

function TrackBuilder.themeFor(roomIndex)
	local checkpoint = roomIndex // Config.ROOMS_PER_CHECKPOINT
	return Config.Themes[checkpoint % #Config.Themes + 1]
end

function TrackBuilder.roomStartZ(roomIndex)
	return ORIGIN.Z - roomIndex * LENGTH
end

function TrackBuilder.new(parent, firstRoom)
	local self = setmetatable({}, TrackBuilder)
	self.folder = Instance.new("Folder")
	self.folder.Name = "Track"
	self.folder.Parent = parent
	self.rooms = {} -- roomIndex -> { folder, glass = { Part }, doors = { door }, crystals = { Part } }
	self.doorOf = setmetatable({}, { __mode = "k" }) -- door panel / button -> door
	self.nextRoom = firstRoom or 0
	self.rng = Random.new()
	return self
end

function TrackBuilder:addGlass(room, position, size)
	local glass = newPart(room.folder, "Glass", {
		Name = "Glass",
		Size = size,
		CFrame = CFrame.new(position),
		Material = Enum.Material.Glass,
		Color = Config.GLASS_COLOR,
		Transparency = 0.35,
		Reflectance = 0.15,
	})
	table.insert(room.glass, glass)
	return glass
end

function TrackBuilder:addCrystal(room, position)
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
function Patterns.Grid(self, room, z)
	for _, x in { -5, 0, 5 } do
		for _, y in { 2.5, 6.5, 10.5 } do
			self:addGlass(room, Vector3.new(ORIGIN.X + x, ORIGIN.Y + y, z), Vector3.new(4.6, 3.8, 0.4))
		end
	end
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
	door.button.Color = Color3.fromRGB(80, 255, 120)
	door.button.CanQuery = false
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
	Patterns[name](self, room, z)
end

function TrackBuilder:buildRoom(roomIndex)
	local theme = TrackBuilder.themeFor(roomIndex)
	local startZ = TrackBuilder.roomStartZ(roomIndex)
	local centerZ = startZ - LENGTH / 2
	local rng = self.rng

	local zone = roomIndex // Config.ROOMS_PER_CHECKPOINT
	local isZoneStart = roomIndex % Config.ROOMS_PER_CHECKPOINT == 0

	local folder = Instance.new("Folder")
	folder.Name = "Room" .. roomIndex
	local room = { folder = folder, glass = {}, doors = {}, crystals = {} }

	local wallProps = { Color = theme.Wall, Material = Enum.Material.SmoothPlastic }
	local function wall(size, position)
		local props = table.clone(wallProps)
		props.Size = size
		props.CFrame = CFrame.new(position)
		newPart(folder, "Wall", props)
	end
	wall(Vector3.new(WIDTH, 1, LENGTH), Vector3.new(ORIGIN.X, ORIGIN.Y - 0.5, centerZ))
	wall(Vector3.new(WIDTH, 1, LENGTH), Vector3.new(ORIGIN.X, ORIGIN.Y + HEIGHT + 0.5, centerZ))
	wall(Vector3.new(1, HEIGHT, LENGTH), Vector3.new(ORIGIN.X - WIDTH / 2 - 0.5, ORIGIN.Y + HEIGHT / 2, centerZ))
	wall(Vector3.new(1, HEIGHT, LENGTH), Vector3.new(ORIGIN.X + WIDTH / 2 + 0.5, ORIGIN.Y + HEIGHT / 2, centerZ))

	-- Glowing door frame at the start of each room gives a sense of speed.
	local accent = { Color = theme.Accent, Material = Enum.Material.Neon }
	local function trim(size, position)
		local props = table.clone(accent)
		props.Size = size
		props.CFrame = CFrame.new(position)
		newPart(folder, "Wall", props)
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
			newPart(folder, "Wall", props)
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

	if roomIndex >= Config.SAFE_ROOMS and not isZoneStart then
		-- Difficulty climbs inside each zone and keeps climbing zone to zone.
		local inZone = (roomIndex % Config.ROOMS_PER_CHECKPOINT) / Config.ROOMS_PER_CHECKPOINT
		local difficulty = math.min(inZone * 0.6 + zone * 0.15, 1)

		local groups = 1
		if rng:NextNumber() < difficulty then
			groups += 1
		end
		if rng:NextNumber() < difficulty * 0.6 then
			groups += 1
		end
		for group = 1, groups do
			self:addObstacle(room, startZ - LENGTH * group / (groups + 1), zone)
		end

		for _ = 1, rng:NextInteger(1, 2) do
			local position = Vector3.new(
				ORIGIN.X + rng:NextNumber(-7, 7),
				ORIGIN.Y + rng:NextNumber(3, HEIGHT - 3),
				startZ - rng:NextNumber(10, LENGTH - 10)
			)
			self:addCrystal(room, position)
		end
	end

	folder.Parent = self.folder
	self.rooms[roomIndex] = room
end

-- Call every frame with the camera's Z position.
function TrackBuilder:update(cameraZ, dt)
	local spin = CFrame.Angles(0, dt * 2, 0)
	for _, room in self.rooms do
		for _, crystal in room.crystals do
			if crystal.Parent and crystal.CanQuery then
				crystal.CFrame = crystal.CFrame * spin
			end
		end
	end

	while TrackBuilder.roomStartZ(self.nextRoom) > cameraZ - Config.ROOMS_AHEAD * LENGTH do
		self:buildRoom(self.nextRoom)
		self.nextRoom += 1
	end

	for roomIndex, room in self.rooms do
		local endZ = TrackBuilder.roomStartZ(roomIndex) - LENGTH
		if endZ > cameraZ + 10 then
			room.folder:Destroy()
			self.rooms[roomIndex] = nil
		end
	end
end

-- Everything you can crash into: unbroken glass and closed doors.
function TrackBuilder:hazards()
	local result = {}
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
