--[[
	The game itself: moves the camera down the corridor, throws balls,
	smashes glass, counts crystals and handles game over / revive.
	Runs entirely on the player's device. The server only gets the distance and
	a few run stats (glass smashed, crystals, props, best multiball), and works
	out gems / XP / missions itself.
]]

local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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

local function makeBallPart()
	local skin = Config.getSkin(player:GetAttribute("EquippedSkin"))

	local part = Instance.new("Part")
	part.Name = "Ball"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * Config.BALL_RADIUS * 2
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

	if skin.Trail or skin.Rainbow then
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, Config.BALL_RADIUS * 0.6, 0)
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -Config.BALL_RADIUS * 0.6, 0)
		a1.Parent = part

		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.25
		trail.LightEmission = 1
		trail.Color = ColorSequence.new(skin.Trail or part.Color)
		trail.Transparency = NumberSequence.new(0.2, 1)
		trail.Parent = part
	end

	part.Parent = shardFolder
	return part
end

local function spawnBall(origin, velocity)
	local part = makeBallPart()
	part.CFrame = CFrame.new(origin)
	table.insert(activeBalls, { part = part, position = origin, velocity = velocity, age = 0 })
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

	local ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
	local carry = FORWARD * speed -- balls keep the camera's forward momentum
	for i = 1, multiball do
		-- Spread extra balls out in a small fan.
		local angle = (i - (multiball + 1) / 2) * 0.05
		local direction = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(ray.Direction)
		spawnBall(ray.Origin + direction * 1.5, direction * Config.BALL_SPEED + carry)
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

-- Moves one ball forward, bouncing off walls and breaking what it hits.
-- Returns false when the ball should be removed.
local function stepBall(ball, dt)
	ball.age += dt
	if ball.age > Config.BALL_LIFETIME then
		return false
	end

	ball.velocity += Vector3.new(0, -Config.BALL_GRAVITY, 0) * dt
	local travel = ball.velocity * dt

	-- A few iterations so a fast ball can break glass and still bounce this frame.
	for _ = 1, 3 do
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
			local normal = hit.Normal
			ball.velocity = (ball.velocity - 2 * ball.velocity:Dot(normal) * normal) * 0.6
			ball.position += normal * 0.05
			travel = ball.velocity.Unit * remaining * 0.6
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

local function startRun(checkpoint)
	checkpoint = checkpoint or 0
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

	Remotes.RunStarted:FireServer(checkpoint)
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
	if state == "Running" then
		local zoneRooms = currentRoom() - startCheckpoint * Config.ROOMS_PER_CHECKPOINT
		speed = math.min(Config.MAX_SPEED, Config.START_SPEED + zoneRooms * Config.SPEED_GAIN_PER_ROOM)

		local prevZ = cameraZ
		cameraZ -= speed * dt
		checkCrashes(prevZ, cameraZ)

		local room = currentRoom()
		if room ~= lastRoom then
			lastRoom = room
			onRoomEntered(room)
		end
	end

	if track then
		track:update(cameraZ, dt)
	end
	stepBalls(dt)

	if state == "Running" then
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

local function onPurchaseGranted(productKey)
	local product = Config.Products[productKey]
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
		onPlay = function(checkpoint)
			startRun(checkpoint)
		end,
		onPlayAgain = function()
			startRun(startCheckpoint)
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
		-- Generic: onShop("BuyFx", id), onShop("ClaimMission", id), onShop("ClaimSeasonTier", { track, tier })...
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
			if type(event) == "table" and ui.showProgress then
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
