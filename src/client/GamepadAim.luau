--[[
	Aiming with a controller (Xbox / PlayStation / a gamepad on PC).

	While the player's last input was a gamepad and a run is going, a crosshair
	shows on screen. Either thumbstick moves it (slowly at first, faster the
	longer the stick is held), and it drifts back to the middle when the stick
	is let go. RunController throws at it when R2 or A is pressed.

	The crosshair's ScreenGui covers the whole screen (no insets), so its
	position is in the same pixels as camera.ViewportSize: throw with
	camera:ViewportPointToRay, NOT ScreenPointToRay (that one expects positions
	measured below the Roblox top bar, like mouse/touch input).
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local GamepadAim = {}

-- Look (same "glass lab" palette as UI.luau)
local PAPER = Color3.fromRGB(244, 241, 234)
local INK = Color3.fromRGB(17, 17, 17)
local DISPLAY_ORDER = 18 -- above the main UI (10), below the tutorial (19/20)

local RETICLE_SIZE = 48 -- pixels
local TICK_LENGTH = 13
local TICK_WIDTH = 3
local CENTER_SIZE = 8

-- Feel
local DEADZONE = 0.18 -- stick movement smaller than this is ignored (worn sticks drift)
local SPEED = 0.95 -- full stick = this many screen-heights per second (before acceleration)
local CURVE = 1.7 -- > 1: small pushes move very slowly, for fine aiming
local ACCEL_START = 0.5 -- speed multiplier when the stick is first pushed...
local ACCEL_MAX = 1.7 -- ...growing to this...
local ACCEL_TIME = 0.6 -- ...after holding it this many seconds
local RECENTER_DELAY = 0.5 -- seconds after letting go before drifting back
local RECENTER_RATE = 1.2 -- how fast it drifts back (higher = faster)
local EDGE_MARGIN = 24 -- the crosshair stays this far inside the screen

local camera = workspace.CurrentCamera
local accentColor = Color3.fromRGB(90, 200, 255) -- replaced by setAccent with the zone color

local gui
local reticle
local reticleScale
local accentParts = {} -- frames tinted with the zone accent color

local usingGamepad = false
local activeGamepad = Enum.UserInputType.Gamepad1
local position -- Vector2, viewport pixels (nil until the first update)
local lastViewport = Vector2.zero
local holdTime = 0 -- seconds the stick has been pushed
local idleTime = 0 -- seconds since the stick was let go
local shown = false

local function isGamepad(inputType)
	return string.sub(inputType.Name, 1, 7) == "Gamepad"
end

local function isPointer(inputType)
	return inputType == Enum.UserInputType.Touch
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseButton3
		or inputType == Enum.UserInputType.MouseMovement
		or inputType == Enum.UserInputType.MouseWheel
end

local function onInputType(inputType)
	if isGamepad(inputType) then
		usingGamepad = true
		activeGamepad = inputType
	elseif isPointer(inputType) then
		usingGamepad = false
	end
	-- Keyboard / text input / focus changes leave it as it was.
end

local function new(className, props)
	local instance = Instance.new(className)
	for key, value in props do
		if key ~= "Parent" then
			instance[key] = value
		end
	end
	instance.Parent = props.Parent
	return instance
end

-- One crosshair arm: an ink bar with a paper outline, so it reads on bright
-- glass and on dark walls alike.
local function tick(size, anchor, offset)
	local bar = new("Frame", {
		AnchorPoint = anchor,
		Position = UDim2.new(0.5, offset.X, 0.5, offset.Y),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = INK,
		BorderSizePixel = 0,
		Parent = reticle,
	})
	new("UIStroke", { Color = PAPER, Thickness = 1, Parent = bar })
	return bar
end

-- Hard ink corner bracket (blueprint registration mark).
local function bracket(anchor, where)
	local holder = new("Frame", {
		AnchorPoint = anchor,
		Position = where,
		Size = UDim2.fromOffset(9, 9),
		BackgroundTransparency = 1,
		Parent = reticle,
	})
	local horizontal = new("Frame", {
		Size = UDim2.new(1, 0, 0, 2),
		Position = UDim2.fromScale(0, anchor.Y),
		AnchorPoint = Vector2.new(0, anchor.Y),
		BackgroundColor3 = INK,
		BorderSizePixel = 0,
		Parent = holder,
	})
	local vertical = new("Frame", {
		Size = UDim2.new(0, 2, 1, 0),
		Position = UDim2.fromScale(anchor.X, 0),
		AnchorPoint = Vector2.new(anchor.X, 0),
		BackgroundColor3 = INK,
		BorderSizePixel = 0,
		Parent = holder,
	})
	horizontal.BackgroundColor3 = accentColor
	vertical.BackgroundColor3 = accentColor
	table.insert(accentParts, horizontal)
	table.insert(accentParts, vertical)
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "GamepadAim"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = DISPLAY_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Whole screen, top bar included: offsets here are viewport pixels.
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.Enabled = false

	reticle = new("Frame", {
		Name = "Reticle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(RETICLE_SIZE, RETICLE_SIZE),
		BackgroundTransparency = 1,
		Active = false,
		Parent = gui,
	})
	reticleScale = new("UIScale", { Parent = reticle })

	-- Four arms with a gap in the middle so the target stays visible.
	local gap = CENTER_SIZE / 2 + 4
	tick(Vector2.new(TICK_WIDTH, TICK_LENGTH), Vector2.new(0.5, 1), Vector2.new(0, -gap))
	tick(Vector2.new(TICK_WIDTH, TICK_LENGTH), Vector2.new(0.5, 0), Vector2.new(0, gap))
	tick(Vector2.new(TICK_LENGTH, TICK_WIDTH), Vector2.new(1, 0.5), Vector2.new(-gap, 0))
	tick(Vector2.new(TICK_LENGTH, TICK_WIDTH), Vector2.new(0, 0.5), Vector2.new(gap, 0))

	-- Zone-colored corner brackets.
	bracket(Vector2.new(0, 0), UDim2.fromScale(0, 0))
	bracket(Vector2.new(1, 0), UDim2.fromScale(1, 0))
	bracket(Vector2.new(0, 1), UDim2.fromScale(0, 1))
	bracket(Vector2.new(1, 1), UDim2.fromScale(1, 1))

	-- Center: small accent square with an ink hairline.
	local center = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(CENTER_SIZE, CENTER_SIZE),
		BackgroundColor3 = accentColor,
		BorderSizePixel = 0,
		Parent = reticle,
	})
	new("UIStroke", { Color = INK, Thickness = 1.5, Parent = center })
	table.insert(accentParts, center)

	-- Annotation tag: which button throws.
	local tag = new("TextLabel", {
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(1, 4, 1, 2),
		Size = UDim2.fromOffset(52, 14),
		BackgroundColor3 = PAPER,
		BorderSizePixel = 0,
		Font = Enum.Font.RobotoMono,
		Text = "R2 THROW",
		TextColor3 = INK,
		TextSize = 9,
		Parent = reticle,
	})
	new("UIStroke", { Color = INK, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = tag })

	gui.Parent = player:WaitForChild("PlayerGui")
end

local function viewportSize()
	local size = camera.ViewportSize
	if size.X < 1 or size.Y < 1 then
		return Vector2.new(1280, 720)
	end
	return size
end

local function clampToScreen(point, size)
	local margin = math.min(EDGE_MARGIN, size.X / 4, size.Y / 4)
	return Vector2.new(math.clamp(point.X, margin, size.X - margin), math.clamp(point.Y, margin, size.Y - margin))
end

-- The strongest thumbstick push right now (screen direction: y grows downward),
-- with the deadzone taken out. Zero vector when both sticks rest.
local function readSticks()
	local best = Vector2.zero
	local ok, state = pcall(UserInputService.GetGamepadState, UserInputService, activeGamepad)
	if not ok then
		return best
	end
	for _, input in state do
		if input.KeyCode == Enum.KeyCode.Thumbstick1 or input.KeyCode == Enum.KeyCode.Thumbstick2 then
			local stick = Vector2.new(input.Position.X, -input.Position.Y)
			if stick.Magnitude > best.Magnitude then
				best = stick
			end
		end
	end
	local magnitude = best.Magnitude
	if magnitude <= DEADZONE then
		return Vector2.zero
	end
	-- Rescale so movement starts smoothly at the deadzone edge.
	local strength = math.min(1, (magnitude - DEADZONE) / (1 - DEADZONE))
	return best.Unit * strength
end

-- Called once per frame by RunController. running: a run is going (throws allowed).
function GamepadAim.update(dt, running)
	if not gui then
		return
	end
	local size = viewportSize()
	local centre = size / 2
	if not position then
		position = centre
	elseif size ~= lastViewport and lastViewport.X > 0 then
		-- Screen rotated / resized: keep the same relative spot.
		position = Vector2.new(position.X / lastViewport.X * size.X, position.Y / lastViewport.Y * size.Y)
	end
	lastViewport = size

	local visible = running and usingGamepad
	if visible ~= shown then
		shown = visible
		gui.Enabled = visible
		if visible then
			-- Every run starts aiming straight ahead.
			position = centre
			holdTime, idleTime = 0, 0
		end
	end
	if not visible then
		return
	end

	local stick = readSticks()
	if stick.Magnitude > 0 then
		holdTime += dt
		idleTime = 0
		local accel = ACCEL_START + (ACCEL_MAX - ACCEL_START) * math.min(1, holdTime / ACCEL_TIME)
		local pixelsPerSecond = SPEED * size.Y * accel * stick.Magnitude ^ CURVE
		position += stick.Unit * pixelsPerSecond * dt
	else
		holdTime = 0
		idleTime += dt
		if idleTime > RECENTER_DELAY then
			-- Frame-rate independent ease back to the middle.
			position = position:Lerp(centre, 1 - math.exp(-RECENTER_RATE * dt))
		end
	end
	position = clampToScreen(position, size)
	reticle.Position = UDim2.fromOffset(position.X, position.Y)
end

-- Is the crosshair on screen (gamepad player, run going)?
function GamepadAim.isShown()
	return shown
end

-- Was the last input from a gamepad?
function GamepadAim.usingGamepad()
	return usingGamepad
end

-- Where to throw, in viewport pixels (use camera:ViewportPointToRay).
function GamepadAim.viewportPosition()
	return clampToScreen(position or viewportSize() / 2, viewportSize())
end

-- Little kick on the crosshair when a ball is thrown.
function GamepadAim.pulse()
	if not reticleScale then
		return
	end
	reticleScale.Scale = 1.3
	TweenService:Create(reticleScale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
end

-- Zone accent color for the corner brackets and center (RunController's applyTheme).
function GamepadAim.setAccent(color)
	accentColor = color
	for _, part in accentParts do
		part.BackgroundColor3 = color
	end
end

local started = false
function GamepadAim.start()
	if started then
		return
	end
	started = true
	buildGui()

	onInputType(UserInputService:GetLastInputType())
	-- Consoles have no mouse or touch: start in gamepad mode even before any press.
	if
		UserInputService.GamepadEnabled
		and not UserInputService.TouchEnabled
		and not UserInputService.MouseEnabled
	then
		usingGamepad = true
	end
	UserInputService.LastInputTypeChanged:Connect(onInputType)

	-- The camera object can be replaced (rare); keep following the current one.
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		camera = workspace.CurrentCamera or camera
	end)
end

return GamepadAim
