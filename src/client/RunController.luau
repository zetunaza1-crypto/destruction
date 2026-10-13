--[[
	The game itself: moves the camera down the corridor, throws balls,
	smashes glass, counts crystals and handles game over / revive.
	Runs entirely on the player's device. The server only gets the distance and
	a few run stats (glass smashed, crystals, props, best multiball), and works
	out gems / XP / missions itself.

	Boosts (Config.Boosts): picked in the menu or bought mid-run. The server
	confirms which ones really started (Progress "BoostsActivated", or the
	"UseBoostNow" answer for a Robux boost bought mid-run) and only those are
	switched on here.
	  Shield     - the next crash costs no balls (buying more stacks: one per crash)
	  Magnet     - crystals near the camera fly to you for a few seconds
	  MegaBall   - the next few throws are giant balls that smash through everything
	  SlowMo     - the world (camera, balls) runs slower for a few seconds
	  DoubleGems - handled by the server, only shown here

	Game feel (section "Feel" below): hit-stop (a split-second freeze) on big
	smashes, a field-of-view punch on every smash, a kick + shake on crashes, a
	tiny recoil on throws, and phone / controller vibration (Haptics.luau).
	Camera effects follow Settings "shake", the shield tint follows "flashes".

	Destruction: balls knock solid decorations loose (Shatter.knockLoose) and kick
	up dust + chips where they hit walls and floor (Shatter.impact). Knocked
	pieces can't be hit again and never block glass.

	Smoothness: nothing in the frame loop builds new tables (the HUD tables are
	reused), crash checks read TrackBuilder's cached hazard list, and
	PerfOverlay (Config.SHOW_PERF) shows FPS / worst frame / part counts.
]]

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local BallFx = require(script.Parent.BallFx)
local GamepadAim = require(script.Parent.GamepadAim)
local Haptics = require(script.Parent.Haptics)
local LeaveGift = require(script.Parent.LeaveGift)
local Shatter = require(script.Parent.Shatter)
local Sounds = require(script.Parent.Sounds)
local TrackBuilder = require(script.Parent.TrackBuilder)
local LightingFx = require(script.Parent.LightingFx)
local PerfOverlay = require(script.Parent.PerfOverlay)
local Settings = require(script.Parent.Settings)
local Tutorial = require(script.Parent.Tutorial)
local UI = require(script.Parent.UI)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local ORIGIN = Config.TRACK_ORIGIN
local FORWARD = Vector3.new(0, 0, -1)
local CRASH_MARGIN = 0.25 -- small allowance only: if it looks like you missed the glass, you missed it
local GRAVITY = Vector3.new(0, -Config.BALL_GRAVITY, 0)
local BALL_STEPS = 3 -- collision checks per ball per frame
local BEHIND_CAMERA = 15 -- normal balls this far behind the camera are removed
local TUTORIAL_MIN_BALL_SPEED = 0.5 -- balls still fly at least half speed while the tutorial slows time
local MEGA_STEPS = 8 -- mega balls can smash through several things in one frame
local KNOCK_SPLASH = 1.2 -- a ball knocking a decoration loose also knocks parts this close (multi-part decorations come apart)
local KNOCK_OUT = 0.8 -- knocked parts fly along the ball, plus this much straight out of the surface
local MEGA_KNOCK_REACH = 1 -- mega balls knock loose everything within their radius plus this
local MEGA_STRENGTH = 1.5 -- ...and knock it harder
local DECOR_DEPTH = 3 -- decorations stick out this far from the walls / floor / ceiling

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
local BASE_SATURATION = 0 -- zone grading already sets saturation; this layer stays neutral

-- Feel
local BASE_FOV = 70
local SPEED_FOV = 15 -- extra field of view at top speed
local HITSTOP_TIME = 0.06 -- seconds the world freezes on a big smash
local HITSTOP_BIG_TIME = 0.07 -- mega ball breaking several things at once
local HITSTOP_MAX = 0.1 -- a burst of big smashes never freezes longer than this in total...
local HITSTOP_COOLDOWN = 0.35 -- ...and the next freeze waits this long after one ends
local HITSTOP_SCALE = 0.03 -- world speed while frozen (not quite 0, so it never looks stuck)
local BIG_PANE_AREA = 150 -- panes at least this big (square studs) count as a big smash (full walls)
local FOV_PUNCH_SHATTER = 3
local FOV_PUNCH_BIG = 5
local FOV_PUNCH_CRASH = 6
local FOV_PUNCH_MAX = 7
local FOV_PUNCH_RETURN = 15 -- how fast the punch eases back (gone after ~0.2 s)
local KICK_RETURN = 12 -- how fast camera kicks / recoil settle
local THROW_RECOIL = math.rad(0.5) -- camera tips up this much on a throw
local CRASH_KICK = math.rad(3.5) -- camera snaps up this much on a crash...
local CRASH_ROLL = math.rad(2.5) -- ...and tilts sideways up to this much
local KICK_MAX = math.rad(6)

-- Roblox's own UI we hide (the game has its own leaderboard, and the player
-- list would cover the distance readout). Chat stays on.
local HIDDEN_CORE_GUI = {
	Enum.CoreGuiType.Backpack,
	Enum.CoreGuiType.Health,
	Enum.CoreGuiType.PlayerList,
	Enum.CoreGuiType.EmotesMenu,
}
local CORE_GUI_ATTEMPTS = 10

local RunController = {}

-- State ----------------------------------------------------------------------

local state = "Menu" -- "Menu" | "Running" | "GameOver"
local world -- Folder holding everything for the current run
local shardFolder
local track
local raycastParams
local overlapParams -- the track only, for knocking decorations loose

local cameraZ = ORIGIN.Z
local speed = Config.START_SPEED
local balls = 0
local multiball = 1
local streak = 0
local lastThrow = 0
local lastRoom = 0
local lastReportedRoom = 0 -- last room index sent to the server with RoomReached
local startCheckpoint = 0
local shake = 0
local activeBalls = {}
local reportedMeters = 0
local runFx -- shatter effect equipped for this run (Config.ShatterFx entry)
-- Counted from the start of the run (a revive continues it). Sent with RunEnded.
local runStats = { glass = 0, crystals = 0, props = 0, maxMultiball = 1 }
local ui

-- Boosts running in this run (only what the server confirmed).
-- shield = crashes it still absorbs, magnet / slowmo = seconds left,
-- megaball = giant throws left.
local boost = { shield = 0, magnet = 0, slowmo = 0, megaball = 0, doubleGems = false }
local timeScale = 1 -- 1 = normal speed, lower while SlowMo is on
local slowLook = 0 -- how much of the slow-mo color effect is showing (0..1)
local magnetized = {} -- crystals currently flying to the camera

-- Feel (see the "Feel" section)
local hitStopLeft = 0 -- real seconds of freeze still to go
local hitStopUsed = 0 -- seconds frozen in the current burst (capped at HITSTOP_MAX)
local hitStopCooldown = 0
local lastTutorialScale = 1 -- the tutorial's slow-down last frame (no hit-stop while it slows time)
local fovPunch = 0 -- extra degrees of field of view, easing back to 0
local kickPitch = 0 -- radians, camera tipped up (recoil / crash), easing back to 0
local kickRoll = 0 -- radians, camera tilted sideways (crash), easing back to 0
local shakeOn = Settings.get("shake") ~= false
local flashesOn = Settings.get("flashes") ~= false
local runSerial = 0 -- RunStarted events sent; the server echoes it with BoostsActivated
local unusedBoostsSent = true -- ReturnUnusedBoosts already sent for this run (none before the first run)

-- Purchases
-- A Robux prompt opened during a run freezes the run until it closes, so the
-- player can't crash while reading it. Safety net: never frozen longer than this.
local PROMPT_FREEZE_MAX = 120
local promptFreezeUntil = 0 -- os.clock() the freeze ends at (0 = not frozen)
local rerollAfterPurchase = nil -- mission id to reroll once an ExtraReroll purchase arrives

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

-- One table reused every frame (the UI only reads it).
local hudState = { balls = 0, multiball = 1, streak = 0, meters = 0, zone = 0 }

local function updateHud()
	hudState.balls = balls
	hudState.multiball = multiball
	hudState.streak = (streak % Config.CRYSTALS_PER_MULTIBALL_LEVEL) / Config.CRYSTALS_PER_MULTIBALL_LEVEL
	hudState.meters = meters()
	hudState.zone = currentRoom() // Config.ROOMS_PER_CHECKPOINT
	ui:setHud(hudState)
end

-- Lighting -------------------------------------------------------------------

-- Zone lighting lives in LightingFx. This extra color layer is only for
-- gameplay effects (slow-mo desaturation, shield flash), stacked on top.
local colorCorrection

local function setupLighting()
	LightingFx.setup()

	colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "GameplayGrade"
	colorCorrection.Saturation = BASE_SATURATION
	colorCorrection.Parent = Lighting
end

local function applyTheme(zone)
	local theme = TrackBuilder.themeFor(zone * Config.ROOMS_PER_CHECKPOINT)
	LightingFx.applyTheme(theme)
	ui:setTheme(theme)
	GamepadAim.setAccent(theme.Accent)
	LeaveGift.setAccent(theme.Accent)
end

-- Feel -----------------------------------------------------------------------

-- Freezes the world for a split second (balls, camera, crystals). Real-time
-- things (boost timers, the UI, the tutorial) keep going. Several big smashes
-- in a row never add up to more than HITSTOP_MAX, and never while the tutorial
-- is slowing time down.
local function hitStop(duration)
	if state ~= "Running" or hitStopCooldown > 0 or lastTutorialScale < 0.999 then
		return
	end
	local extra = math.min(duration - hitStopLeft, HITSTOP_MAX - hitStopUsed)
	if extra > 0 then
		hitStopLeft += extra
		hitStopUsed += extra
	end
end

-- Counts the freeze down in real time. Returns the world speed multiplier.
local function tickHitStop(dt)
	if hitStopLeft > 0 then
		hitStopLeft -= dt
		if hitStopLeft <= 0 then
			hitStopLeft = 0
			hitStopUsed = 0
			hitStopCooldown = HITSTOP_COOLDOWN
		end
		return HITSTOP_SCALE
	end
	hitStopCooldown = math.max(0, hitStopCooldown - dt)
	return 1
end

-- Camera effects (all skipped when the player turned camera shake off).
local function punchFov(amount)
	if shakeOn then
		fovPunch = math.min(FOV_PUNCH_MAX, math.max(fovPunch, amount))
	end
end

local function kickCamera(pitch, roll)
	if shakeOn then
		kickPitch = math.clamp(kickPitch + pitch, -KICK_MAX, KICK_MAX)
		kickRoll = math.clamp(kickRoll + roll, -KICK_MAX, KICK_MAX)
	end
end

local function shakeCamera(amount)
	if shakeOn then
		shake = math.max(shake, amount)
	end
end

local function resetFeel()
	hitStopLeft, hitStopUsed, hitStopCooldown = 0, 0, 0
	fovPunch, kickPitch, kickRoll, shake = 0, 0, 0, 0
end

-- One smash's feedback. big = full wall, mega multi-break or door burst.
local function smashFeedback(big)
	if big then
		hitStop(HITSTOP_TIME)
		punchFov(FOV_PUNCH_BIG)
		Haptics.play("bigShatter")
	else
		punchFov(FOV_PUNCH_SHATTER)
		Haptics.play("shatter")
	end
end

Settings.changed:Connect(function(key, value)
	if key == "shake" then
		shakeOn = value ~= false
		if not shakeOn then
			fovPunch, kickPitch, kickRoll, shake = 0, 0, 0, 0
		end
	elseif key == "flashes" then
		flashesOn = value ~= false
	end
end)

-- Balls ----------------------------------------------------------------------

-- mega: a giant MegaBall boost ball (bigger, always has a trail).
-- lite: a cheaper look for the extra balls of a multiball throw (premium balls
-- only: no rings, particles or light). The look itself is in BallFx.luau.
local function makeBallPart(mega, lite)
	local radius = if mega then MEGA_RADIUS else Config.BALL_RADIUS
	return BallFx.create(player:GetAttribute("EquippedSkin"), radius, {
		mega = mega,
		lite = lite,
		parent = shardFolder,
	})
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
		Tutorial.tip("Multiball")
	end
	Sounds.play("Crystal", 1 + math.min(streak, 10) * 0.03)
	Haptics.play("crystal")
	updateHud()
end

-- fx: the player's shatter effect (only for balls they throw), nil = plain glass.
-- feedback: true for the player's own smashes (punch, vibration, hit-stop on big
-- panes); crashes and revives have their own feedback.
-- Returns true when it was a big pane.
local function smashGlass(glass, hitPoint, push, fx, feedback)
	local size = glass.Size
	local big = glass:GetAttribute("Pattern") == "FullWall" or size.X * size.Y >= BIG_PANE_AREA
	Shatter.glass(glass, hitPoint, push, shardFolder, fx)
	track:markHazardsChanged()
	Sounds.play("Shatter", 0.85 + math.random() * 0.3)
	if feedback then
		smashFeedback(big)
	end
	return big
end

-- Bounces a ball off a wall/floor/door it just touched. Returns the rest of
-- this frame's movement.
local function bounce(ball, hit, remaining)
	local normal = hit.Normal
	ball.velocity = (ball.velocity - 2 * ball.velocity:Dot(normal) * normal) * 0.6
	ball.position += normal * 0.05
	return ball.velocity.Unit * remaining * 0.6
end

-- Which way a knocked-loose decoration flies: along the ball, and out of the
-- surface it was hit on (so it falls into the corridor instead of into the wall).
local function knockDirection(ballDirection, normal)
	local direction = ballDirection + normal * KNOCK_OUT
	return if direction.Magnitude > 0.01 then direction.Unit else normal
end

-- A ball hit a decoration: it comes loose, and so do its parts right next to it.
local function knockDecoration(part, hitPoint, direction, radius, strength)
	Shatter.knockLoose(part, direction, strength)
	Shatter.knockAround(hitPoint, radius, direction, strength, overlapParams)
end

-- Mega balls: anything within reach comes loose. Decorations only sit near
-- the walls, floor and ceiling, so the (more costly) area check only runs there.
local function megaKnockNearby(ball, direction)
	local p = ball.position
	local reach = MEGA_RADIUS + MEGA_KNOCK_REACH
	local nearEdge = math.abs(p.X - ORIGIN.X) > Config.CORRIDOR_WIDTH / 2 - DECOR_DEPTH - reach
		or p.Y < ORIGIN.Y + DECOR_DEPTH + reach
		or p.Y > ORIGIN.Y + Config.CORRIDOR_HEIGHT - DECOR_DEPTH - reach
	if nearEdge then
		Shatter.knockAround(p, reach, direction, MEGA_STRENGTH, overlapParams)
	end
end

-- MegaBall boost: a giant ball swept as a sphere (workspace:Spherecast), so it
-- hits everything its whole body touches. It smashes glass and decorations,
-- collects crystals and opens doors without slowing down; only walls stop it.
local function stepMegaBall(ball, travel)
	local broken = 0 -- glass / props smashed this frame
	local bigHit = false
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
			broken += 1
			if smashGlass(part, hit.Position, direction * MEGA_PUSH, runFx, false) then
				bigHit = true
			end
			travel = direction * remaining
		elseif kind == "Prop" then
			runStats.props += 1
			broken += 1
			Tutorial.tip("Props")
			Shatter.prop(part, hit.Position, direction * MEGA_PUSH, shardFolder, runFx)
			Sounds.play("Shatter", 0.8 + math.random() * 0.2)
			travel = direction * remaining
		elseif kind == "Crystal" then
			collectCrystal(part)
			travel = direction * remaining
		elseif Shatter.canKnock(part) then
			-- Decorations don't stop a giant ball: they're knocked flying.
			knockDecoration(part, hit.Position, knockDirection(direction, hit.Normal), MEGA_RADIUS + MEGA_KNOCK_REACH, MEGA_STRENGTH)
			Shatter.impact(hit.Position, hit.Normal, part)
			travel = direction * remaining
		else
			local door = if kind == "Door" or kind == "Button" then track:doorFor(part) else nil
			if door and not door.open then
				-- Bursts the door open. The panels slide away, so skip collisions
				-- for the rest of this frame instead of hitting them again.
				track:openDoor(door)
				Sounds.play("Checkpoint")
				ball.position += direction * remaining
				bigHit = true
				break
			end
			Shatter.impact(hit.Position, hit.Normal, part)
			travel = bounce(ball, hit, remaining)
		end
	end

	if ball.velocity.Magnitude > 1e-3 then
		megaKnockNearby(ball, ball.velocity.Unit)
	end

	-- One feedback per frame for everything this giant ball broke.
	if bigHit or broken >= 2 then
		hitStop(if broken >= 2 then HITSTOP_BIG_TIME else HITSTOP_TIME)
		punchFov(FOV_PUNCH_BIG)
		Haptics.play("bigShatter")
	elseif broken == 1 then
		smashFeedback(false)
	end
end

-- Moves one ball forward, bouncing off walls and breaking what it hits.
-- Returns false when the ball should be removed.
local function stepBall(ball, dt)
	ball.age += dt
	if ball.age > Config.BALL_LIFETIME then
		return false
	end

	-- Normal balls that bounced back well behind the camera can't hit anything useful.
	if not ball.mega and ball.position.Z > cameraZ + BEHIND_CAMERA then
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

		if kind == "Glass" and track:crackArmor(hit.Instance, hit.Position) then
			-- Armored glass: the first hit only cracks it and the ball bounces off.
			Shatter.impact(hit.Position, hit.Normal, hit.Instance)
			Sounds.play("Shatter", 0.55)
			smashFeedback(false)
			travel = bounce(ball, hit, remaining)
		elseif kind == "Glass" then
			runStats.glass += 1
			smashGlass(hit.Instance, hit.Position, ball.velocity.Unit, runFx, true)
			ball.velocity *= 0.7 -- the ball keeps going, a bit slower
			travel = ball.velocity.Unit * remaining * 0.7
		elseif kind == "Prop" then
			-- Breakable decoration: just for fun, the ball smashes straight through.
			runStats.props += 1
			Tutorial.tip("Props")
			Shatter.prop(hit.Instance, hit.Position, ball.velocity.Unit, shardFolder, runFx)
			Sounds.play("Shatter", 1.1 + math.random() * 0.3)
			smashFeedback(false)
			ball.velocity *= 0.85
			travel = ball.velocity.Unit * remaining * 0.85
		elseif kind == "Crystal" then
			collectCrystal(hit.Instance)
			travel = travel.Unit * remaining
		elseif kind == "Button" then
			track:openDoor(track:doorFor(hit.Instance))
			Sounds.play("Checkpoint")
			smashFeedback(false)
			ball.velocity = -ball.velocity * 0.4
			travel = ball.velocity.Unit * remaining * 0.4
		else
			-- Walls, floor, doors: bounce, with a puff of dust and a few chips.
			-- Decorations (not the room itself) are knocked loose too.
			local part = hit.Instance
			if Shatter.canKnock(part) then
				knockDecoration(part, hit.Position, knockDirection(ball.velocity.Unit, hit.Normal), KNOCK_SPLASH, 1)
			end
			Shatter.impact(hit.Position, hit.Normal, part)
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
			BallFx.destroy(ball.part)
			table.remove(activeBalls, i)
		end
	end
end

local function clearBalls()
	for _, ball in activeBalls do
		BallFx.destroy(ball.part)
	end
	table.clear(activeBalls)
end

-- preSweep (mega balls only): the ball starts at the camera and is swept this
-- far before its first frame. A sphere cast can't hit something the sphere
-- already overlaps at its start, so starting a giant ball out in front would
-- miss glass, crystals and buttons right in front of the camera.
local function spawnBall(origin, velocity, mega, preSweep, lite)
	-- Too many balls slows phones down: the oldest ones disappear first.
	while #activeBalls >= Config.MAX_LIVE_BALLS do
		local oldest = table.remove(activeBalls, 1)
		BallFx.destroy(oldest.part)
	end

	local part = makeBallPart(mega, lite)
	local ball = { part = part, position = origin, velocity = velocity, age = 0, mega = mega }
	table.insert(activeBalls, ball)
	if mega and preSweep then
		stepMegaBall(ball, preSweep)
	end
	part.CFrame = CFrame.new(ball.position)
end

-- True while a Robux prompt opened mid-run is on screen (the run is frozen).
local function promptFrozen()
	return promptFreezeUntil > 0 and os.clock() < promptFreezeUntil
end

-- Throws along a ray from the camera (see throw / throwAtViewport below).
-- Returns true if a ball was thrown.
local function throwAlong(ray)
	if state ~= "Running" or balls <= 0 or promptFrozen() then
		return false
	end
	local now = os.clock()
	if now - lastThrow < Config.THROW_COOLDOWN then
		return false
	end
	lastThrow = now
	balls -= 1

	-- MegaBall boost: this whole throw (every ball of the multiball fan) is giant.
	local mega = boost.megaball > 0
	if mega then
		boost.megaball -= 1
	end
	-- Giant balls end up a bit further out so they don't fill the screen.
	local startDistance = if mega then 1.5 + MEGA_RADIUS else 1.5

	local carry = FORWARD * speed -- balls keep the camera's forward momentum
	-- Only the middle ball of a multiball fan gets the full premium look (perf).
	local hero = math.ceil(multiball / 2)
	for i = 1, multiball do
		-- Spread extra balls out in a small fan.
		local angle = (i - (multiball + 1) / 2) * 0.05
		local direction = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(ray.Direction)
		local velocity = direction * Config.BALL_SPEED + carry
		if mega then
			-- Swept from the camera so anything close is still smashed.
			spawnBall(ray.Origin, velocity, true, direction * startDistance, i ~= hero)
		else
			spawnBall(ray.Origin + direction * startDistance, velocity, false, nil, i ~= hero)
		end
	end

	Sounds.play("Throw", 0.95 + math.random() * 0.1)
	Haptics.play("throw")
	kickCamera(THROW_RECOIL, 0)
	updateHud()
	return true
end

-- Mouse / touch: input.Position is measured below the Roblox top bar, which is
-- what ScreenPointToRay expects.
local function throw(screenPosition)
	if state ~= "Running" then
		return false
	end
	return throwAlong(camera:ScreenPointToRay(screenPosition.X, screenPosition.Y))
end

-- Gamepad crosshair: its position is in full-screen (viewport) pixels, which
-- is what ViewportPointToRay expects.
local function throwAtViewport(viewportPosition)
	if state ~= "Running" then
		return false
	end
	return throwAlong(camera:ViewportPointToRay(viewportPosition.X, viewportPosition.Y))
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

-- Switches one boost on for this run. Buying the same timed boost again adds
-- time; each Shield absorbs one more crash.
local function activateBoost(boostId)
	if boostId == "Shield" then
		boost.shield += 1
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
	boost.shield = 0
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
	-- The blue tint is a full-screen flash: skipped when flashes are turned off.
	if colorCorrection and flashesOn then
		colorCorrection.TintColor = WHITE:Lerp(SHIELD.Color, 0.6)
		TweenService:Create(colorCorrection, SHIELD_FLASH, { TintColor = WHITE }):Play()
	end
	Sounds.play("Shatter", 0.6)
	ui:toast("SHIELD BROKEN", "info")
end

-- What the HUD shows for boosts (sent every frame; the UI only redraws changes).
-- One table reused every frame (the UI only reads it).
local boostState = { shield = false, magnet = 0, slowmo = 0, megaball = 0, doubleGems = false }

local function updateBoostHud()
	if ui.setBoosts then
		boostState.shield = boost.shield > 0 -- the UI only shows on / off
		boostState.magnet = boost.magnet
		boostState.slowmo = boost.slowmo
		boostState.megaball = boost.megaball
		boostState.doubleGems = boost.doubleGems
		ui:setBoosts(boostState)
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
	local report = table.clone(runStats)
	-- Unused boosts: the server gives them back if the player leaves from here.
	report.unusedShield = boost.shield
	report.unusedMegaThrows = boost.megaball
	Remotes.RunEnded:FireServer(distance, report)
	Tutorial.setPaused(true)

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

	local roll = (if math.random() < 0.5 then -1 else 1) * CRASH_ROLL

	-- Crashing while learning is free.
	if Tutorial.crashIsFree() then
		shakeCamera(0.2)
		kickCamera(CRASH_KICK * 0.6, roll * 0.6)
		punchFov(FOV_PUNCH_SHATTER)
		Haptics.play("crash")
		Sounds.play("Crash")
		return
	end

	-- Shield boost: this crash is free (no balls lost, multiball kept).
	if boost.shield > 0 then
		boost.shield -= 1
		shakeCamera(0.2)
		kickCamera(CRASH_KICK * 0.5, roll * 0.5)
		punchFov(FOV_PUNCH_BIG)
		Haptics.play("bigShatter")
		shieldBreak()
		return
	end

	balls = math.max(0, balls - Config.CRASH_PENALTY)
	multiball = minimumMultiball()
	streak = 0
	shakeCamera(0.35)
	kickCamera(CRASH_KICK, roll)
	punchFov(FOV_PUNCH_CRASH)
	Haptics.play("crash")
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
local function resetWorld(checkpoint, tutorial)
	if world then
		world:Destroy()
	end
	clearBalls()
	resetBoosts()
	resetFeel()
	Shatter.reset()

	world = Instance.new("Folder")
	world.Name = "LocalRun"
	world.Parent = workspace

	shardFolder = Instance.new("Folder")
	shardFolder.Name = "Effects"
	shardFolder.Parent = world

	local firstRoom = checkpoint * Config.ROOMS_PER_CHECKPOINT
	track = TrackBuilder.new(world, firstRoom, tutorial)
	cameraZ = TrackBuilder.roomStartZ(firstRoom) + 4
	-- The first two rooms are built completely now; the rest a little per frame.
	track:warmUp(cameraZ)

	raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = { track.folder }

	overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = { track.folder }
	overlapParams.MaxParts = 24

	PerfOverlay.watch(world)

	lastRoom = firstRoom
	lastReportedRoom = firstRoom
	applyTheme(checkpoint)
end

local shopRequest -- defined in the Purchases section below

-- The run is really over (PLAY AGAIN or MENU from the game over screen, without
-- a revive): unused Shields and Mega Ball throws go back to the inventory.
-- Sent once per run; the server checks it against what the run really turned on.
local function returnUnusedBoosts()
	if state ~= "GameOver" or unusedBoostsSent then
		return
	end
	unusedBoostsSent = true
	local shield, throws = boost.shield, boost.megaball
	if shield <= 0 and throws < MEGA.Throws then
		return -- nothing that could be given back
	end
	-- Sent now (before RunStarted / resetWorld), answered in the background.
	task.spawn(function()
		local ok, message = shopRequest("ReturnUnusedBoosts", { shield = shield, megaballThrows = throws })
		if ok and type(message) == "string" then
			ui:toast(message, "reward")
		end
	end)
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

	returnUnusedBoosts() -- PLAY AGAIN from the game over screen
	unusedBoostsSent = false

	-- Brand-new players get the guided first run.
	local tutorialRun = checkpoint == 0 and Tutorial.isNeeded()
	Tutorial.reset()
	resetWorld(checkpoint, tutorialRun)
	if tutorialRun then
		Tutorial.start(track)
	end

	-- Bonus balls from the daily streak, and Revive / Ball Pack balls bought
	-- outside a run (the server saved them and resets them when the run starts).
	local bonusBalls = math.max(0, math.floor(tonumber(player:GetAttribute("BonusBalls")) or 0))

	balls = Config.START_BALLS + bonusBalls
	if ownsPass("VIP") then
		balls += Config.GamePasses.VIP.ExtraStartBalls
	end
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
		if hazard.Parent and ahead > -2 and ahead < 40 then
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
	Tutorial.setPaused(false)
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
	returnUnusedBoosts() -- MENU from the game over screen
	state = "Menu"
	Tutorial.reset()
	resetWorld(0)
	ui:showMenu()
	-- A game pass bought outside this server (website, another server) shows up
	-- without rejoining. The server limits how often this really checks.
	task.spawn(shopRequest, "RecheckPasses")
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

-- Tells the server each new room the camera reaches (it checks the distance
-- against these, so it must be every room, in order).
local function reportRoom(roomIndex)
	local remote = Remotes:FindFirstChild("RoomReached")
	if remote then
		remote:FireServer(roomIndex)
	end
end

local menuTime = 0

local function step(dt)
	-- worldDt: game time, slower than real time while SlowMo is on.
	local worldDt = dt
	local ballDt = dt -- balls ignore most of the tutorial's slow-down
	if state == "Running" then
		-- A Robux prompt is on screen: everything in the run stands still
		-- (boost timers too) until it closes.
		local runDt = if promptFrozen() then 0 else dt
		tickBoosts(runDt)
		-- The tutorial slows time while it waits for the player to act.
		local tutorialScale = Tutorial.update(runDt, cameraZ)
		lastTutorialScale = tutorialScale
		-- Hit-stop: a split-second freeze after a big smash.
		local freeze = tickHitStop(runDt)
		worldDt = runDt * timeScale * tutorialScale * freeze
		ballDt = runDt * timeScale * math.max(tutorialScale, TUTORIAL_MIN_BALL_SPEED) * freeze
		Tutorial.scanForTips(runDt, cameraZ, track)

		-- Same rule the server's anti-cheat uses (each zone has its own top speed).
		speed = Config.speedForRoom(currentRoom(), startCheckpoint * Config.ROOMS_PER_CHECKPOINT)

		local prevZ = cameraZ
		cameraZ -= speed * worldDt
		checkCrashes(prevZ, cameraZ)

		local room = currentRoom()
		if room ~= lastRoom and state == "Running" then
			lastRoom = room
			onRoomEntered(room)
		end
		while state == "Running" and room > lastReportedRoom do
			lastReportedRoom += 1
			reportRoom(lastReportedRoom)
		end
	end

	if track then
		track:update(cameraZ, worldDt)
	end
	stepBalls(ballDt)
	-- After the balls, so shards from this frame's smashes are placed this frame.
	Shatter.update(cameraZ)

	if state == "Running" then
		updateMagnet(worldDt)
		if balls <= 0 and #activeBalls == 0 then
			gameOver()
		end
		updateHud()
	end

	-- Camera: gentle sway, wider view at high speed, plus the feel effects
	-- (shake on crash, kick / recoil, field-of-view punch). Real time, so they
	-- still settle during slow-mo and hit-stop.
	menuTime += dt
	shake = math.max(0, shake - dt)
	local settle = 1 - math.exp(-KICK_RETURN * dt)
	kickPitch -= kickPitch * settle
	kickRoll -= kickRoll * settle
	fovPunch -= fovPunch * (1 - math.exp(-FOV_PUNCH_RETURN * dt))
	local sway = Vector3.new(math.sin(menuTime * 0.7) * 0.15, math.sin(menuTime * 1.3) * 0.1, 0)
	local jitter = Vector3.zero
	if shake > 0 then
		jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, 0) * shake * 2
	end
	local position = cameraPosition() + sway + jitter
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(position, position + FORWARD) * CFrame.Angles(kickPitch, 0, kickRoll)
	camera.FieldOfView = BASE_FOV
		+ (speed - Config.START_SPEED) / (Config.MAX_SPEED - Config.START_SPEED) * SPEED_FOV
		+ fovPunch

	updateBoostHud()
	GamepadAim.update(dt, state == "Running")
end

-- Purchases ------------------------------------------------------------------

-- Robux purchases are only allowed once the server has loaded the player's save
-- (otherwise the server can't record them, or sells something already owned).
local function canBuy()
	if player:GetAttribute("DataFailed") == true then
		ui:toast("YOUR SAVE DIDN'T LOAD - REJOIN BEFORE BUYING", "error")
		return false
	end
	if player:GetAttribute("DataLoaded") ~= true then
		ui:toast("STILL LOADING YOUR SAVE - TRY AGAIN IN A MOMENT", "info")
		return false
	end
	return true
end

-- Freezes the run while a Robux prompt opened mid-run is on screen.
local function freezeForPrompt()
	if state == "Running" then
		promptFreezeUntil = os.clock() + PROMPT_FREEZE_MAX
	end
end

local function onPromptClosed()
	promptFreezeUntil = 0
end

-- context: extra info from the UI. For "ExtraReroll" it's the mission id, which
-- is rerolled automatically once the purchase arrives.
local function promptProduct(productKey, context)
	local product = Config.Products[productKey]
	if not product or product.Id == 0 then
		return
	end
	if not canBuy() then
		return
	end
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
	if productKey == "ExtraReroll" then
		rerollAfterPurchase = if type(context) == "string" then context else nil
	end
	local ok = pcall(MarketplaceService.PromptProductPurchase, MarketplaceService, player, product.Id)
	if ok then
		freezeForPrompt()
	end
end

local function promptPass(passKey)
	local pass = Config.GamePasses[passKey]
	if not pass or pass.Id == 0 then
		return
	end
	if not canBuy() then
		return
	end
	local ok = pcall(MarketplaceService.PromptGamePassPurchase, MarketplaceService, player, pass.Id)
	if ok then
		freezeForPrompt()
	end
end

shopRequest = function(action, argument)
	local ok, success, message = pcall(function()
		return Remotes.ShopRequest:InvokeServer(action, argument)
	end)
	if not ok then
		return false, "Connection problem"
	end
	return success == true, message
end

-- A Robux boost always goes to the boost inventory first. Bought during a run,
-- we ask the server to use it right away; it's only switched on if the server says yes.
-- If the run ended while we waited for the answer, it goes back to the inventory.
local function useBoostNow(boostId)
	local ok = shopRequest("UseBoostNow", boostId)
	if not ok then
		ui:toast(boostName(boostId) .. " ADDED TO YOUR BOOSTS", "reward")
		return
	end
	if boostId == "DoubleGems" then
		-- Already counted on the server for this run's gems, even if it just ended.
		activateBoost(boostId)
		ui:toast(boostName(boostId) .. " ON", "reward")
		return
	end
	if state == "Running" then
		activateBoost(boostId)
		ui:toast(boostName(boostId) .. " ON", "reward")
		return
	end
	-- The run ended in the meantime: put it back.
	if shopRequest("ReturnBoost", boostId) then
		ui:toast(boostName(boostId) .. " ADDED TO YOUR BOOSTS", "reward")
	elseif state == "GameOver" then
		-- Couldn't give it back (very unlikely): use it on this run instead,
		-- so it still helps if they revive.
		activateBoost(boostId)
		ui:toast(boostName(boostId) .. " ON", "reward")
	end
end

-- ExtraReroll bought from a mission row: swap that mission right away.
local function rerollBoughtMission()
	local missionId = rerollAfterPurchase
	rerollAfterPurchase = nil
	if not missionId then
		return
	end
	local ok, message = shopRequest("RerollMission", missionId)
	if ok then
		ui:toast(if type(message) == "string" then message else "MISSION SWAPPED", "reward")
	else
		ui:toast(
			(if type(message) == "string" then message .. " - " else "") .. "YOUR REROLL IS SAVED",
			"info"
		)
	end
end

local function onPurchaseGranted(productKey)
	local product = Config.Products[productKey]
	if product and product.Boost then
		if state == "Running" then
			task.spawn(useBoostNow, product.Boost)
		else
			ui:toast(boostName(product.Boost) .. " ADDED TO YOUR BOOSTS", "reward")
		end
		return
	end
	if productKey == "ExtraReroll" then
		task.spawn(rerollBoughtMission)
		return
	end
	-- Starter pack / season pass are announced by the server's Progress "Reward" event.
	if product and product.Gems and productKey ~= "StarterPack" then
		ui:toast("+" .. product.Gems .. " GEMS", "reward")
		return
	end
	if not product or type(product.Balls) ~= "number" then
		return
	end

	-- The server already saved these balls as BonusBalls. Used right away here,
	-- they're taken back out of the save ("UseBonusBalls"); in the menu they
	-- simply wait for the next run.
	local amount = product.Balls
	if state == "GameOver" then
		if revive(amount) then
			task.spawn(function()
				shopRequest("UseBonusBalls", amount)
				-- The server paused the run's clock at game over; start it again.
				shopRequest("ResumeRun")
			end)
		end
		ui:toast("+" .. amount .. " BALLS", "reward")
	elseif state == "Running" then
		balls += amount
		updateHud()
		task.spawn(shopRequest, "UseBonusBalls", amount)
		ui:toast("+" .. amount .. " BALLS", "reward")
	else
		ui:toast("SAVED: +" .. amount .. " BALLS AT THE START OF YOUR NEXT RUN", "reward")
	end
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
	-- The UI shows the "... ON" toast for BoostsActivated itself.
	for _, boostId in ipairs(event.boosts) do
		activateBoost(boostId)
	end
end

-- Startup --------------------------------------------------------------------

-- SetCoreGuiEnabled can fail if called before Roblox's UI has loaded, so retry a few times.
local function hideCoreGui()
	for _ = 1, CORE_GUI_ATTEMPTS do
		local allHidden = true
		for _, coreGuiType in HIDDEN_CORE_GUI do
			local ok = pcall(StarterGui.SetCoreGuiEnabled, StarterGui, coreGuiType, false)
			if not ok then
				allHidden = false
			end
		end
		if allHidden then
			return
		end
		task.wait(1)
	end
end

-- Controller throw buttons: R2 (the trigger) or A, aimed with the crosshair.
-- A also presses UI buttons, so it only throws when no button is selected.
local function onGamepadThrowButton(keyCode, gameProcessed)
	if state ~= "Running" or GuiService.MenuIsOpen then
		return
	end
	if keyCode == Enum.KeyCode.ButtonA and (gameProcessed or GuiService.SelectedObject ~= nil) then
		return
	end
	if throwAtViewport(GamepadAim.viewportPosition()) then
		GamepadAim.pulse()
	end
end

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
	task.spawn(hideCoreGui)
	PerfOverlay.start(Shatter.liveCount)
	GamepadAim.start()
	LeaveGift.start({
		claim = function()
			return shopRequest("ClaimLeaveGift")
		end,
		-- Never pops up in the middle of a run (it waits for the menu / game over).
		canShow = function()
			return state ~= "Running"
		end,
	})

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
		-- onBuyProduct(productKey, context): context is the mission id for "ExtraReroll".
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
	-- Music plays from the moment you join, not only once a run starts.
	Sounds.startMusic()
	task.spawn(disableCharacterControls)

	Remotes.PurchaseGranted.OnClientEvent:Connect(onPurchaseGranted)
	-- These fire on this device when a Robux prompt closes (bought or not).
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		if userId ~= player.UserId then
			return
		end
		onPromptClosed()
		-- Cancelled: forget which mission the reroll was for.
		if not purchased and productId == Config.Products.ExtraReroll.Id then
			rerollAfterPurchase = nil
		end
	end)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(who)
		if who == player then
			onPromptClosed()
		end
	end)

	-- Level ups, missions done, season tiers, run summaries, rewards.
	task.spawn(function()
		local progress = Remotes:WaitForChild("Progress")
		progress.OnClientEvent:Connect(function(event)
			if type(event) ~= "table" then
				return
			end
			if event.type == "BoostsActivated" then
				onBoostsActivated(event)
			elseif event.type == "LevelUp" then
				Haptics.play("levelUp")
			end
			if ui.showProgress then
				ui:showProgress(event)
			end
		end)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		local keyCode = input.KeyCode
		if keyCode == Enum.KeyCode.ButtonR2 or keyCode == Enum.KeyCode.ButtonA then
			onGamepadThrowButton(keyCode, gameProcessed)
			return
		end
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
