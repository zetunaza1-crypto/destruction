--[[
	The game itself: moves the camera down the corridor, throws balls,
	smashes glass, counts crystals and handles game over / revive.
	Runs entirely on the player's device. The server only gets the distance and
	a few run stats (glass smashed, crystals, props, best multiball), and works
	out gems / XP / missions itself.

	Boosts (Config.Boosts): picked in the menu or bought mid-run. The server
	confirms which ones really started (Progress "BoostsActivated", or
	PurchaseGranted for a Robux boost) and only those are switched on here.
	  Shield     - the next crash costs no balls
	  Magnet     - crystals near the camera fly to you for a few seconds
	  MegaBall   - the next few throws are giant balls that smash through everything
	  SlowMo     - the world (camera, balls) runs slower for a few seconds
	  DoubleGems - handled by the server, only shown here
]]

local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Shatter = require(script.Parent.Shatter)
local Sounds = require(script.Parent.Sounds)
local TrackBuilder = require(script.Parent.TrackBuilder)
local UI = require(script.Parent.UI)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local ORIGIN = Config.TRACK_ORIGIN
local FORWARD = Vector3.new(0, 0, -1)
local CRASH_MARGIN = 0.8 -- how close to a pane's edge still counts as hitting it
local GRAVITY = Vector3.new(0, -Config.BALL_GRAVITY, 0)
local BALL_STEPS = 3 -- collision checks per ball per frame
local MEGA_STEPS = 8 -- mega balls can smash through several things in one frame

-- Boosts
local BOOSTS = Config.Boosts
local MAGNET = BOOSTS.Magnet
local MEGA = BOOSTS.MegaBall
local SLOWMO = BOOSTS.SlowMo
local SHIELD = BOOSTS.Shield
local MEGA_RADIUS = Config.BALL_RADIUS * MEGA.Scale
local MEGA_PUSH = 1.6 -- mega balls blast glass shards harder
local MAGNET_PULL_SPEED = 60 -- studs per second a crystal flies at (plus the camera's speed)
local MAGNET_PICKUP = 1.5 -- this close to the camera = collected
local SLOWMO_EASE = 0.35 -- seconds to slow down / speed back up
local WHITE = Color3.new(1, 1, 1)
local SHIELD_FLASH = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BASE_SATURATION = 0.1

local RunController = {}

-- State ----------------------------------------------------------------------

local state = "Menu" -- "Menu" | "Running" | "GameOver"
local world -- Folder holding everything for the current run
local shardFolder
local track
local raycastParams

local cameraZ = ORIGIN.Z
local speed = Config.START_SPEED
local balls = 0
local multiball = 1
local streak = 0
local lastThrow = 0
local lastRoom = 0
local startCheckpoint = 0
local shake = 0
local activeBalls = {}
local pendingBalls = 0 -- balls bought while not in a run, added to the next one
local reportedMeters = 0
local runFx -- shatter effect equipped for this run (Config.ShatterFx entry)
-- Counted from the start of the run (a revive continues it). Sent with RunEnded.
local runStats = { glass = 0, crystals = 0, props = 0, maxMultiball = 1 }
local ui

-- Boosts running in this run (only what the server confirmed).
-- magnet / slowmo = seconds left, megaball = giant throws left.
local boost = { shield = false, magnet = 0, slowmo = 0, megaball = 0, doubleGems = false }
local timeScale = 1 -- 1 = normal speed, lower while SlowMo is on
local slowLook = 0 -- how much of the slow-mo color effect is showing (0..1)
local magnetized = {} -- crystals currently flying to the camera
local runSerial = 0 -- RunStarted events sent; the server echoes it with BoostsActivated

-- Helpers --------------------------------------------------------------------

local function ownsPass(passKey)
	return player:GetAttribute("Pass_" .. passKey) == true
end

local function minimumMultiball()
	return if ownsPass("Multiball") then 2 else 1
end

local function meters()
	return math.max(0, math.floor((ORIGIN.Z - cameraZ) / Config.STUDS_PER_METER))
end

local function currentRoom()
	return math.max(0, (ORIGIN.Z - cameraZ) // Config.ROOM_LENGTH)
end

local function cameraPosition()
	return Vector3.new(ORIGIN.X, ORIGIN.Y + Config.CAMERA_HEIGHT, cameraZ)
end

local function updateHud()
	ui:setHud({
		balls = balls,
		multiball = multiball,
		streak = (streak % Config.CRYSTALS_PER_MULTIBALL_LEVEL) / Config.CRYSTALS_PER_MULTIBALL_LEVEL,
		meters = meters(),
		zone = currentRoom() // Config.ROOMS_PER_CHECKPOINT,
	})
end

-- Lighting -------------------------------------------------------------------

local bloom
local colorCorrection

local function setupLighting()
	-- The Baseplate template ships an Atmosphere (which overrides fog) and its own bloom.
	-- Removing them here only affects this player's screen.
	for _, child in Lighting:GetChildren() do
		if child:IsA("Atmosphere") or child:IsA("BloomEffect") then
			child:Destroy()
		end
	end

	Lighting.FogStart = 60
	Lighting.FogEnd = Config.ROOM_LENGTH * (Config.ROOMS_AHEAD - 1)
	Lighting.Brightness = 2
	Lighting.GlobalShadows = false
	Lighting.Ambient = Color3.fromRGB(150, 150, 160)
	Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 160)

	bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.8
	bloom.Size = 30
	bloom.Threshold = 0.9
	bloom.Parent = Lighting

	colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Contrast = 0.1
	colorCorrection.Saturation = 0.1
	colorCorrection.Parent = Lighting
end

local function applyTheme(zone)
	local theme = TrackBuilder.themeFor(zone * Config.ROOMS_PER_CHECKPOINT)
	Lighting.FogColor = theme.Fog
	ui:setTheme(theme)
end

-- Balls ----------------------------------------------------------------------

-- mega: a giant MegaBall boost ball (bigger, always has a trail).
local function makeBallPart(mega)
	local skin = Config.getSkin(player:GetAttribute("EquippedSkin"))
	local radius = if mega then MEGA_RADIUS else Config.BALL_RADIUS

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

	if skin.Trail or skin.Rainbow or mega then
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, radius * 0.6, 0)
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -radius * 0.6, 0)
		a1.Parent = part

		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.25
		trail.LightEmission = 1
		trail.Color = ColorSequence.new(skin.Trail or (if mega then MEGA.Color else part.Color))
		trail.Transparency = NumberSequence.new(0.2, 1)
		trail.Parent = part
	end

	part.Parent = shardFolder
	return part
end

local function spawnBall(origin, velocity, mega)
	local part = makeBallPart(mega)
	part.CFrame = CFrame.new(origin)
	table.insert(activeBalls, { part = part, position = origin, velocity = velocity, age = 0, mega = mega })
end

local function throw(screenPosition)
	if state ~= "Running" or balls <= 0 then
		return
	end
	local now = os.clock()
	if now - lastThrow < Config.THROW_COOLDOWN then
		return
	end
	lastThrow = now
	balls -= 1

	-- MegaBall boost: this whole throw (every ball of the multiball fan) is giant.
	local mega = boost.megaball > 0
	if mega then
		boost.megaball -= 1
	end
	-- Giant balls start a bit further out so they don't fill the screen.
	local startDistance = if mega then 1.5 + MEGA_RADIUS else 1.5

	local ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
	local carry = FORWARD * speed -- balls keep the camera's forward momentum
	for i = 1, multiball do
		-- Spread extra balls out in a small fan.
		local angle = (i - (multiball + 1) / 2) * 0.05
		local direction = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(ray.Direction)
		spawnBall(ray.Origin + direction * startDistance, direction * Config.BALL_SPEED + carry, mega)
	end

	Sounds.play("Throw", 0.95 + math.random() * 0.1)
	updateHud()
end

local function collectCrystal(crystal)
	Shatter.crystal(crystal, shardFolder)
	balls += Config.CRYSTAL_REWARD
	streak += 1
	runStats.crystals += 1
	if streak % Config.CRYSTALS_PER_MULTIBALL_LEVEL == 0 and multiball < Config.MAX_MULTIBALL then
		multiball += 1
		runStats.maxMultiball = math.max(runStats.maxMultiball, multiball)
		ui:toast("MULTIBALL x" .. multiball, "multiball")
	end
	Sounds.play("Crystal", 1 + math.min(streak, 10) * 0.03)
	updateHud()
end

-- fx: the player's shatter effect (only for balls they throw), nil = plain glass.
local function smashGlass(glass, hitPoint, push, fx)
	Shatter.glass(glass, hitPoint, push, shardFolder, fx)
	Sounds.play("Shatter", 0.85 + math.random() * 0.3)
end

-- Bounces a ball off a wall/floor/door it just touched. Returns the rest of
-- this frame's movement.
local function bounce(ball, hit, remaining)
	local normal = hit.Normal
	ball.velocity = (ball.velocity - 2 * ball.velocity:Dot(normal) * normal) * 0.6
	ball.position += normal * 0.05
	return ball.velocity.Unit * remaining * 0.6
end

-- MegaBall boost: a giant ball swept as a sphere (workspace:Spherecast), so it
-- hits everything its whole body touches. It smashes glass and decorations,
-- collects crystals and opens doors without slowing down; only walls stop it.
local function stepMegaBall(ball, travel)
	for _ = 1, MEGA_STEPS do
		local distance = travel.Magnitude
		if distance < 1e-3 then
			break
		end
		local hit = workspace:Spherecast(ball.position, MEGA_RADIUS, travel, raycastParams)
		if not hit then
			ball.position += travel
			break
		end

		-- hit.Distance is how far the sphere's center got before touching.
		local direction = travel / distance
		local remaining = distance - hit.Distance
		ball.position += direction * hit.Distance
		local part = hit.Instance
		local kind = part:GetAttribute("Kind")

		if kind == "Glass" then
			runStats.glass += 1
			smashGlass(part, hit.Position, direction * MEGA_PUSH, runFx)
			travel = direction * remaining
		elseif kind == "Prop" then
			runStats.props += 1
			Shatter.prop(part, hit.Position, direction * MEGA_PUSH, shardFolder, runFx)
			Sounds.play("Shatter", 0.8 + math.random() * 0.2)
			travel = direction * remaining
		elseif kind == "Crystal" then
			collectCrystal(part)
			travel = direction * remaining
		else
			local door = if kind == "Door" or kind == "Button" then track:doorFor(part) else nil
			if door and not door.open then
				-- Bursts the door open. The panels slide away, so skip collisions
				-- for the rest of this frame instead of hitting them again.
				track:openDoor(door)
				Sounds.play("Checkpoint")
				ball.position += direction * remaining
				break
			end
			travel = bounce(ball, hit, remaining)
		end
	end
end

-- Moves one ball forward, bouncing off walls and breaking what it hits.
-- Returns false when the ball should be removed.
local function stepBall(ball, dt)
	ball.age += dt
	if ball.age > Config.BALL_LIFETIME then
		return false
	end

	ball.velocity += GRAVITY * dt
	local travel = ball.velocity * dt

	if ball.mega then
		stepMegaBall(ball, travel)
		ball.part.CFrame = CFrame.new(ball.position)
		return true
	end

	-- A few iterations so a fast ball can break glass and still bounce this frame.
	for _ = 1, BALL_STEPS do
		local hit = workspace:Raycast(ball.position, travel, raycastParams)
		if not hit then
			ball.position += travel
			break
		end

		local kind = hit.Instance:GetAttribute("Kind")
		local remaining = travel.Magnitude - hit.Distance
		ball.position = hit.Position

		if kind == "Glass" then
			runStats.glass += 1
			smashGlass(hit.Instance, hit.Position, ball.velocity.Unit, runFx)
			ball.velocity *= 0.7 -- the ball keeps going, a bit slower
			travel = ball.velocity.Unit * remaining * 0.7
		elseif kind == "Prop" then
			-- Breakable decoration: just for fun, the ball smashes straight through.
			runStats.props += 1
			Shatter.prop(hit.Instance, hit.Position, ball.velocity.Unit, shardFolder, runFx)
			Sounds.play("Shatter", 1.1 + math.random() * 0.3)
			ball.velocity *= 0.85
			travel = ball.velocity.Unit * remaining * 0.85
		elseif kind == "Crystal" then
			collectCrystal(hit.Instance)
			travel = travel.Unit * remaining
		elseif kind == "Button" then
			track:openDoor(track:doorFor(hit.Instance))
			Sounds.play("Checkpoint")
			ball.velocity = -ball.velocity * 0.4
			travel = ball.velocity.Unit * remaining * 0.4
		else
			-- Walls, floor, doors: bounce.
			travel = bounce(ball, hit, remaining)
		end
	end

	ball.part.CFrame = CFrame.new(ball.position)
	return true
end

local function stepBalls(dt)
	for i = #activeBalls, 1, -1 do
		local ball = activeBalls[i]
		if not stepBall(ball, dt) then
			ball.part:Destroy()
			table.remove(activeBalls, i)
		end
	end
end

local function clearBalls()
	for _, ball in activeBalls do
		ball.part:Destroy()
	end
	table.clear(activeBalls)
end

-- Boosts ---------------------------------------------------------------------

local function boostName(boostId)
	local info = BOOSTS[boostId]
	return if info then info.Name else "BOOST"
end

-- The player's boost inventory ({ [boostId] = count }) from the server.
local function ownedBoosts()
	local raw = player:GetAttribute("Boosts")
	if type(raw) ~= "string" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok and type(decoded) == "table" then decoded else {}
end

-- The boosts picked in the menu that the player really has (distinct, max
-- Config.MAX_BOOSTS_PER_RUN). The server checks again; this just avoids
-- asking for boosts they don't own.
local function pickBoosts(boostIds)
	local picked = {}
	if type(boostIds) ~= "table" then
		return picked
	end
	local owned = ownedBoosts()
	for _, boostId in ipairs(boostIds) do
		if #picked >= Config.MAX_BOOSTS_PER_RUN then
			break
		end
		if
			type(boostId) == "string"
			and BOOSTS[boostId]
			and not table.find(picked, boostId)
			and (tonumber(owned[boostId]) or 0) >= 1
		then
			table.insert(picked, boostId)
		end
	end
	return picked
end

-- Switches one boost on for this run. Buying the same timed boost again adds time.
local function activateBoost(boostId)
	if boostId == "Shield" then
		boost.shield = true
	elseif boostId == "Magnet" then
		boost.magnet += MAGNET.Duration
	elseif boostId == "SlowMo" then
		boost.slowmo += SLOWMO.Duration
	elseif boostId == "MegaBall" then
		boost.megaball += MEGA.Throws
	elseif boostId == "DoubleGems" then
		boost.doubleGems = true
	else
		return false
	end
	return true
end

local function setSlowLook(amount)
	if amount ~= slowLook and colorCorrection then
		slowLook = amount
		colorCorrection.Saturation = BASE_SATURATION - 0.45 * amount
	end
end

-- Everything off (new run or back to the menu).
local function resetBoosts()
	boost.shield = false
	boost.magnet = 0
	boost.slowmo = 0
	boost.megaball = 0
	boost.doubleGems = false
	timeScale = 1
	setSlowLook(0)
	table.clear(magnetized)
end

-- Counts boost timers down (real seconds, so slow-mo doesn't make them last longer)
-- and eases the world's time scale in and out of slow-mo.
local function tickBoosts(dt)
	boost.magnet = math.max(0, boost.magnet - dt)
	boost.slowmo = math.max(0, boost.slowmo - dt)

	local slowest = SLOWMO.TimeScale
	local target = if boost.slowmo > 0 then slowest else 1
	local change = (1 - slowest) / SLOWMO_EASE * dt
	if timeScale > target then
		timeScale = math.max(target, timeScale - change)
	elseif timeScale < target then
		timeScale = math.min(target, timeScale + change)
	end
	setSlowLook(if slowest < 1 then (1 - timeScale) / (1 - slowest) else 0)
end

-- Magnet boost: crystals within range of the camera fly to it and are collected
-- (exactly like hitting them with a ball). Crystals already flying keep going
-- after the magnet runs out.
local function updateMagnet(dt)
	local eye = cameraPosition()
	if boost.magnet > 0 and track then
		local range = MAGNET.Range
		for _, room in track.rooms do
			for _, crystal in room.crystals do
				-- CanQuery is turned off once a crystal is collected or already flying.
				if crystal.CanQuery and crystal.Parent and (crystal.Position - eye).Magnitude <= range then
					crystal.CanQuery = false
					table.insert(magnetized, crystal)
				end
			end
		end
	end

	local pull = (MAGNET_PULL_SPEED + speed) * dt -- how far a crystal flies this frame
	for i = #magnetized, 1, -1 do
		local crystal = magnetized[i]
		if not crystal.Parent then
			table.remove(magnetized, i)
		else
			local offset = eye - crystal.Position
			local distance = offset.Magnitude
			if distance <= pull + MAGNET_PICKUP then
				table.remove(magnetized, i)
				collectCrystal(crystal)
			else
				crystal.Position += offset * (pull / distance)
			end
		end
	end
end

-- Shield boost used up: a burst of blue shards around the view and a quick tint.
local function shieldBreak()
	Shatter.shieldBreak(camera.CFrame, SHIELD.Color, shardFolder, FORWARD * speed * timeScale)
	if colorCorrection then
		colorCorrection.TintColor = WHITE:Lerp(SHIELD.Color, 0.6)
		TweenService:Create(colorCorrection, SHIELD_FLASH, { TintColor = WHITE }):Play()
	end
	Sounds.play("Shatter", 0.6)
	ui:toast("SHIELD BROKEN", "info")
end

-- What the HUD shows for boosts (sent every frame; the UI only redraws changes).
local function updateBoostHud()
	if ui.setBoosts then
		ui:setBoosts({
			shield = boost.shield,
			magnet = boost.magnet,
			slowmo = boost.slowmo,
			megaball = boost.megaball,
			doubleGems = boost.doubleGems,
		})
	end
end

-- Run lifecycle ----------------------------------------------------------------

local function gameOver()
	if state ~= "Running" then
		return
	end
	state = "GameOver"

	local distance = meters()
	local best = player:GetAttribute("Best") or 0
	local gemMultiplier = if ownsPass("VIP") then Config.GamePasses.VIP.GemMultiplier else 1
	if player.MembershipType == Enum.MembershipType.Premium then
		gemMultiplier *= 1 + Config.PREMIUM_GEM_BONUS
	end
	if boost.doubleGems then
		gemMultiplier *= 2 -- the server doubles them too
	end
	local newMeters = math.max(0, distance - reportedMeters)
	reportedMeters = math.max(reportedMeters, distance)
	Remotes.RunEnded:FireServer(distance, table.clone(runStats))

	-- Personal best only counts runs started from the beginning (same as the server).
	local countsForBest = startCheckpoint == 0
	ui:showGameOver({
		meters = distance,
		best = if countsForBest then math.max(best, distance) else best,
		isNewBest = countsForBest and distance > best,
		gemsEarned = math.floor(newMeters * Config.GEMS_PER_METER * gemMultiplier),
		canRevive = Config.Products.Revive.Id ~= 0,
	})
end

local function crash(hazard)
	local door = track:doorFor(hazard)
	if door then
		track:openDoor(door)
	else
		smashGlass(hazard, cameraPosition(), FORWARD)
	end

	-- Shield boost: this crash is free (no balls lost, multiball kept).
	if boost.shield then
		boost.shield = false
		shake = 0.2
		shieldBreak()
		return
	end

	balls = math.max(0, balls - Config.CRASH_PENALTY)
	multiball = minimumMultiball()
	streak = 0
	shake = 0.35
	Sounds.play("Crash")
	ui:flashDamage()
	updateHud()

	if balls <= 0 then
		gameOver()
	end
end

-- Did the camera fly through any pane between prevZ and newZ?
local function checkCrashes(prevZ, newZ)
	local position = cameraPosition()
	for _, hazard in track:hazards() do
		-- The list was built before the loop, so skip anything an earlier crash already cleared
		-- (both panels of a door would otherwise each cost a crash).
		local door = track:doorFor(hazard)
		if not hazard.Parent or (door and door.open) then
			continue
		end
		local z = hazard.Position.Z
		if prevZ > z and newZ <= z then
			local localPoint = hazard.CFrame:PointToObjectSpace(Vector3.new(position.X, position.Y, z))
			local size = hazard.Size
			if
				math.abs(localPoint.X) <= size.X / 2 + CRASH_MARGIN
				and math.abs(localPoint.Y) <= size.Y / 2 + CRASH_MARGIN
			then
				crash(hazard)
				if state ~= "Running" then
					return
				end
			end
		end
	end
end

-- Throws away the old track and builds a fresh one starting at a checkpoint.
local function resetWorld(checkpoint)
	if world then
		world:Destroy()
	end
	clearBalls()
	resetBoosts()

	world = Instance.new("Folder")
	world.Name = "LocalRun"
	world.Parent = workspace

	shardFolder = Instance.new("Folder")
	shardFolder.Name = "Effects"
	shardFolder.Parent = world

	local firstRoom = checkpoint * Config.ROOMS_PER_CHECKPOINT
	track = TrackBuilder.new(world, firstRoom)
	cameraZ = TrackBuilder.roomStartZ(firstRoom) + 4
	track:update(cameraZ, 0)

	raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = { track.folder }

	lastRoom = firstRoom
	applyTheme(checkpoint)
end

-- boostIds: boosts picked in the menu (may be nil/empty). They only switch on
-- once the server confirms them (see onBoostsActivated).
local function startRun(checkpoint, boostIds)
	checkpoint = if type(checkpoint) == "number" then math.max(0, math.floor(checkpoint)) else 0
	if checkpoint > 0 and not ownsPass("Checkpoints") then
		checkpoint = 0
	end
	checkpoint = math.min(checkpoint, player:GetAttribute("Checkpoint") or 0)
	startCheckpoint = checkpoint

	resetWorld(checkpoint)

	-- Bonus balls from the daily streak (the server resets them when the run starts).
	local bonusBalls = math.max(0, math.floor(tonumber(player:GetAttribute("BonusBalls")) or 0))

	balls = Config.START_BALLS + pendingBalls + bonusBalls
	if ownsPass("VIP") then
		balls += Config.GamePasses.VIP.ExtraStartBalls
	end
	pendingBalls = 0
	multiball = minimumMultiball()
	streak = 0
	speed = Config.START_SPEED
	reportedMeters = math.floor(Config.checkpointMeters(checkpoint))
	runFx = Config.getFx(player:GetAttribute("EquippedFx"))
	runStats = { glass = 0, crystals = 0, props = 0, maxMultiball = multiball }
	state = "Running"

	local picked = pickBoosts(boostIds)
	runSerial += 1
	if #picked > 0 then
		Remotes.RunStarted:FireServer(checkpoint, picked)
	else
		Remotes.RunStarted:FireServer(checkpoint)
	end
	ui:showHud()
	updateHud()
	Sounds.startMusic()
	if bonusBalls > 0 then
		ui:toast("+" .. bonusBalls .. " BONUS BALLS", "reward")
	end
end

local function revive(extraBalls)
	if state ~= "GameOver" then
		return false
	end

	-- Clear everything right in front of the player so they don't crash instantly.
	for _, hazard in track:hazards() do
		local ahead = cameraZ - hazard.Position.Z
		if ahead > -2 and ahead < 40 then
			local door = track:doorFor(hazard)
			if door then
				track:openDoor(door)
			else
				smashGlass(hazard, hazard.Position, FORWARD)
			end
		end
	end

	balls = extraBalls
	multiball = minimumMultiball()
	streak = 0
	state = "Running"
	ui:hideRevive()
	ui:showHud()
	updateHud()
	return true
end

local function showMenu()
	-- Leaving mid-run still reports it, so the server doesn't think it's still going.
	if state == "Running" then
		gameOver()
	end
	state = "Menu"
	resetWorld(0)
	ui:showMenu()
end

-- Frame loop -----------------------------------------------------------------

local function onRoomEntered(room)
	if room > 0 and room % Config.ROOMS_PER_CHECKPOINT == 0 then
		local zone = room // Config.ROOMS_PER_CHECKPOINT
		applyTheme(zone)
		ui:toast(string.format("ZONE %02d", zone), "checkpoint")
		Sounds.play("Checkpoint")
	end
end

local menuTime = 0

local function step(dt)
	-- worldDt: game time, slower than real time while SlowMo is on.
	local worldDt = dt
	if state == "Running" then
		tickBoosts(dt)
		worldDt = dt * timeScale

		local zoneRooms = currentRoom() - startCheckpoint * Config.ROOMS_PER_CHECKPOINT
		speed = math.min(Config.MAX_SPEED, Config.START_SPEED + zoneRooms * Config.SPEED_GAIN_PER_ROOM)

		local prevZ = cameraZ
		cameraZ -= speed * worldDt
		checkCrashes(prevZ, cameraZ)

		local room = currentRoom()
		if room ~= lastRoom then
			lastRoom = room
			onRoomEntered(room)
		end
	end

	if track then
		track:update(cameraZ, worldDt)
	end
	stepBalls(worldDt)

	if state == "Running" then
		updateMagnet(worldDt)
		if balls <= 0 and #activeBalls == 0 then
			gameOver()
		end
		updateHud()
	end

	-- Camera: gentle sway, wider view at high speed, shake on crash.
	menuTime += dt
	shake = math.max(0, shake - dt)
	local sway = Vector3.new(math.sin(menuTime * 0.7) * 0.15, math.sin(menuTime * 1.3) * 0.1, 0)
	local jitter = Vector3.zero
	if shake > 0 then
		jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, 0) * shake * 2
	end
	local position = cameraPosition() + sway + jitter
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(position, position + FORWARD)
	camera.FieldOfView = 70 + (speed - Config.START_SPEED) / (Config.MAX_SPEED - Config.START_SPEED) * 15

	updateBoostHud()
end

-- Purchases ------------------------------------------------------------------

local function promptProduct(productKey)
	local product = Config.Products[productKey]
	-- Don't let anyone pay twice for something they already have.
	if productKey == "StarterPack" and player:GetAttribute("StarterPackBought") == true then
		ui:toast("ALREADY OWNED", "reward")
		return
	end
	if productKey == "SeasonPremium" and player:GetAttribute("SeasonPremium") == true then
		ui:toast("ALREADY UNLOCKED", "reward")
		return
	end
	-- A streak saver only does its real job right after the streak breaks
	-- (the server still gives gems if it's bought anyway).
	if productKey == "StreakSaver" then
		local expires = tonumber(player:GetAttribute("StreakExpires")) or 0
		local day = tonumber(player:GetAttribute("StreakDay")) or 1
		if workspace:GetServerTimeNow() <= expires or day <= 1 then
			ui:toast("YOUR STREAK IS SAFE", "info")
			return
		end
	end
	if product and product.Id ~= 0 then
		MarketplaceService:PromptProductPurchase(player, product.Id)
	end
end

local function promptPass(passKey)
	local pass = Config.GamePasses[passKey]
	if pass and pass.Id ~= 0 then
		MarketplaceService:PromptGamePassPurchase(player, pass.Id)
	end
end

-- usedOnRun: for boost products, true when the server used it on the current
-- run right away (false = it went to the inventory).
local function onPurchaseGranted(productKey, usedOnRun)
	local product = Config.Products[productKey]
	if product and product.Boost then
		if usedOnRun == true and state ~= "Menu" and activateBoost(product.Boost) then
			ui:toast(boostName(product.Boost) .. " ON", "reward")
		else
			ui:toast(boostName(product.Boost) .. " ADDED TO YOUR BOOSTS", "reward")
		end
		return
	end
	-- Starter pack / season pass are announced by the server's Progress "Reward" event.
	if product and product.Gems and productKey ~= "StarterPack" then
		ui:toast("+" .. product.Gems .. " GEMS", "reward")
		return
	end
	if not product or not product.Balls then
		return
	end

	if state == "GameOver" then
		revive(product.Balls)
	elseif state == "Running" then
		balls += product.Balls
		updateHud()
	else
		pendingBalls += product.Balls
	end
	ui:toast("+" .. product.Balls .. " BALLS", "reward")
end

-- The server confirmed which picked boosts started (and used them up).
-- event = { type = "BoostsActivated", boosts = { ids }, run = number }
local function onBoostsActivated(event)
	if state == "Menu" or type(event.boosts) ~= "table" then
		return
	end
	-- Meant for an earlier run (the player restarted before it arrived).
	if event.run ~= nil and event.run ~= runSerial then
		return
	end
	local names = {}
	for _, boostId in ipairs(event.boosts) do
		if activateBoost(boostId) then
			table.insert(names, boostName(boostId))
		end
	end
	if #names > 0 then
		ui:toast(table.concat(names, " + ") .. " ON", "reward")
	end
end

local function shopRequest(action, argument)
	local ok, success, message = pcall(function()
		return Remotes.ShopRequest:InvokeServer(action, argument)
	end)
	if not ok then
		return false, "Connection problem"
	end
	return success == true, message
end

-- Startup --------------------------------------------------------------------

local function disableCharacterControls()
	local playerScripts = player:WaitForChild("PlayerScripts")
	local ok, playerModule = pcall(function()
		return require(playerScripts:WaitForChild("PlayerModule"))
	end)
	if ok then
		playerModule:GetControls():Disable()
	end
end

function RunController.start()
	ui = UI.new({
		-- boostIds: boosts picked in the menu (may be empty).
		onPlay = function(checkpoint, boostIds)
			startRun(checkpoint, boostIds)
		end,
		onPlayAgain = function(boostIds)
			startRun(startCheckpoint, boostIds)
		end,
		onMenu = showMenu,
		onRevive = function()
			promptProduct("Revive")
		end,
		onBuyProduct = promptProduct,
		onBuyPass = promptPass,
		onBuySkin = function(skinId)
			return shopRequest("BuySkin", skinId)
		end,
		onEquipSkin = function(skinId)
			return shopRequest("EquipSkin", skinId)
		end,
		onClaimDaily = function()
			return shopRequest("ClaimDaily")
		end,
		-- Generic: onShop("BuyFx", id), onShop("BuyBoost", id), onShop("ClaimMission", id),
		-- onShop("ClaimSeasonTier", { track, tier })...
		onShop = shopRequest,
	})

	setupLighting()
	showMenu()
	task.spawn(disableCharacterControls)

	Remotes.PurchaseGranted.OnClientEvent:Connect(onPurchaseGranted)

	-- Level ups, missions done, season tiers, run summaries, rewards.
	task.spawn(function()
		local progress = Remotes:WaitForChild("Progress")
		progress.OnClientEvent:Connect(function(event)
			if type(event) ~= "table" then
				return
			end
			if event.type == "BoostsActivated" then
				onBoostsActivated(event)
			end
			if ui.showProgress then
				ui:showProgress(event)
			end
		end)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			throw(input.Position)
		end
	end)

	RunService:BindToRenderStep("ShatterRun", Enum.RenderPriority.Camera.Value + 1, step)
end

return RunController
