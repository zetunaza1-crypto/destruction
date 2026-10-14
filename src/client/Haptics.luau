--[[
	Vibration ("haptics") for phones and controllers.

	Haptics.play(kind) with kind:
	  "throw"      tiny tap
	  "shatter"    sharp, short
	  "bigShatter" stronger (full walls, mega ball, door burst)
	  "crash"      heavy, about a quarter second
	  "crystal"    soft pulse
	  "levelUp"    celebration pattern
	  "boost"      a boost from the boost bar switched on (double pop)
	  "gift"       celebration pattern

	Where it buzzes: the controller the player is using (gamepad), or the phone
	itself when the player is on touch. Keyboard / mouse players get nothing.

	Everything is checked at runtime and wrapped in pcall, so devices without
	vibration (most PCs, some phones) simply do nothing - never an error.
	Respects Settings "vibration" (turning it off stops the motors right away).

	Phones: Roblox drives phone vibration through HapticService with the Touch
	input type when the device reports support. If it doesn't, we try the newer
	HapticEffect object (preset effects) when this Roblox version has it.
]]

local HapticService = game:GetService("HapticService")
local UserInputService = game:GetService("UserInputService")

local Settings = require(script.Parent.Settings)

local Haptics = {}

local LARGE = Enum.VibrationMotor.Large
local SMALL = Enum.VibrationMotor.Small
local TOUCH = Enum.UserInputType.Touch

-- Light effects (throw / shatter / crystal) can come many times a second with
-- multiball. They're dropped if one played less than this long ago (~15/s).
local MIN_LIGHT_INTERVAL = 1 / 15
local LIGHT_KINDS = { throw = true, shatter = true, crystal = true }

-- Each pattern is a list of pulses: { at = delay, large = 0..1, small = 0..1, time = seconds }.
-- "large" is the heavy rumble motor, "small" the quick buzzy one.
local PATTERNS = {
	throw = { { at = 0, large = 0, small = 0.22, time = 0.035 } },
	shatter = { { at = 0, large = 0.15, small = 0.55, time = 0.05 } },
	bigShatter = { { at = 0, large = 0.7, small = 0.8, time = 0.12 } },
	crash = { { at = 0, large = 1, small = 0.75, time = 0.25 } },
	crystal = { { at = 0, large = 0, small = 0.35, time = 0.07 } },
	levelUp = {
		{ at = 0, large = 0.3, small = 0.5, time = 0.07 },
		{ at = 0.13, large = 0.4, small = 0.6, time = 0.07 },
		{ at = 0.26, large = 0.8, small = 0.8, time = 0.18 },
	},
}
PATTERNS.gift = PATTERNS.levelUp
PATTERNS.boost = {
	{ at = 0, large = 0.2, small = 0.6, time = 0.05 },
	{ at = 0.08, large = 0.55, small = 0.7, time = 0.1 },
}

-- Preset effects used for the HapticEffect fallback (names are Roblox enum items;
-- an item this Roblox version doesn't have is just skipped).
local EFFECT_TYPES = {
	throw = "UIClick",
	shatter = "GameplayCollision",
	bigShatter = "GameplayExplosion",
	crash = "GameplayExplosion",
	crystal = "UIHover",
	levelUp = "UINotification",
	gift = "UINotification",
	boost = "UINotification",
}

-- Support checks -------------------------------------------------------------------

-- inputType -> { [motor] = true } (nil = not checked yet). Gamepads can be plugged
-- in later, so the cache is cleared when one connects / disconnects.
local supportCache = {}

local function supportedMotors(inputType)
	local cached = supportCache[inputType]
	if cached then
		return cached
	end
	local motors = {}
	local ok, vibrates = pcall(HapticService.IsVibrationSupported, HapticService, inputType)
	if ok and vibrates then
		for _, motor in { LARGE, SMALL } do
			local okMotor, supported = pcall(HapticService.IsMotorSupported, HapticService, inputType, motor)
			if okMotor and supported then
				motors[motor] = true
			end
		end
	end
	supportCache[inputType] = motors
	return motors
end

local function isGamepad(inputType)
	return string.sub(inputType.Name, 1, 7) == "Gamepad"
end

-- The controller / phone to buzz right now (nil = nothing to buzz).
local lastGamepad = Enum.UserInputType.Gamepad1
local function currentTarget()
	local lastInput = UserInputService:GetLastInputType()
	if isGamepad(lastInput) then
		lastGamepad = lastInput
		return lastInput
	end
	if lastInput == TOUCH or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
		return TOUCH
	end
	-- Console before any button press reports no "last input" worth trusting.
	if UserInputService.GamepadEnabled and not UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		return lastGamepad
	end
	return nil
end

-- Motors ---------------------------------------------------------------------------

-- What each motor is doing: motorState[inputType][motor] = { value, untilTime, token }.
local motorState = {}

local function setMotor(inputType, motor, value)
	pcall(HapticService.SetMotor, HapticService, inputType, motor, value)
end

local function stateFor(inputType, motor)
	motorState[inputType] = motorState[inputType] or {}
	local state = motorState[inputType][motor]
	if not state then
		state = { value = 0, untilTime = 0, token = nil }
		motorState[inputType][motor] = state
	end
	return state
end

-- Runs one motor at `value` for `duration` seconds. A weaker pulse that arrives
-- while a stronger one is still running is skipped (you couldn't feel it anyway);
-- a stronger one takes over and switches the motor off at its own end time.
local function pulseMotor(inputType, motor, value, duration)
	if value <= 0 then
		return
	end
	local now = os.clock()
	local state = stateFor(inputType, motor)
	if state.untilTime > now and state.value >= value then
		return
	end
	local token = {}
	state.token = token
	state.value = value
	state.untilTime = now + duration
	setMotor(inputType, motor, value)
	task.delay(duration, function()
		if state.token == token then
			state.token = nil
			state.value = 0
			setMotor(inputType, motor, 0)
		end
	end)
end

local function stopAll()
	for inputType, motors in motorState do
		for motor, state in motors do
			state.token = nil
			state.value = 0
			state.untilTime = 0
			setMotor(inputType, motor, 0)
		end
	end
end

-- Plays one pulse of a pattern on the target's motors. If the device has only
-- one motor, that motor gets the stronger of the two values.
local function playPulse(inputType, motors, pulse)
	if motors[LARGE] and motors[SMALL] then
		pulseMotor(inputType, LARGE, pulse.large, pulse.time)
		pulseMotor(inputType, SMALL, pulse.small, pulse.time)
	elseif motors[LARGE] then
		pulseMotor(inputType, LARGE, math.max(pulse.large, pulse.small), pulse.time)
	elseif motors[SMALL] then
		pulseMotor(inputType, SMALL, math.max(pulse.large, pulse.small), pulse.time)
	end
end

-- HapticEffect fallback (phones) -----------------------------------------------------

local effectsAvailable = nil -- nil = not checked yet
local effects = {} -- kind -> HapticEffect (false = this preset isn't available)

local function effectFor(kind)
	if effectsAvailable == false then
		return nil
	end
	if effects[kind] ~= nil then
		return effects[kind] or nil
	end
	local ok, effect = pcall(function()
		local instance = Instance.new("HapticEffect")
		instance.Type = (Enum :: any).HapticEffectType[EFFECT_TYPES[kind]]
		instance.Parent = workspace
		return instance
	end)
	if not ok or not effect then
		-- No HapticEffect class at all: stop trying. A missing preset: skip just that kind.
		local classOk = pcall(function()
			Instance.new("HapticEffect"):Destroy()
		end)
		if not classOk then
			effectsAvailable = false
		end
		effects[kind] = false
		return nil
	end
	effectsAvailable = true
	effects[kind] = effect
	return effect
end

-- Public ---------------------------------------------------------------------------

local lastLight = 0

function Haptics.isEnabled()
	return Settings.get("vibration") ~= false
end

function Haptics.play(kind)
	local pattern = PATTERNS[kind]
	if not pattern or not Haptics.isEnabled() then
		return
	end
	local target = currentTarget()
	if not target then
		return
	end

	local now = os.clock()
	if LIGHT_KINDS[kind] then
		if now - lastLight < MIN_LIGHT_INTERVAL then
			return
		end
		lastLight = now
	end

	local motors = supportedMotors(target)
	if next(motors) == nil then
		-- No motor control: phones may still have preset haptic effects.
		if target == TOUCH then
			local effect = effectFor(kind)
			if effect then
				pcall(effect.Play, effect)
			end
		end
		return
	end

	for _, pulse in pattern do
		if pulse.at <= 0 then
			playPulse(target, motors, pulse)
		else
			task.delay(pulse.at, function()
				-- Turned off (or switched device) in the meantime: skip the rest.
				if Haptics.isEnabled() and currentTarget() == target then
					playPulse(target, motors, pulse)
				end
			end)
		end
	end
end

-- Stops every motor right now.
Haptics.stop = stopAll

Settings.changed:Connect(function(key, value)
	if key == "vibration" and value == false then
		stopAll()
	end
end)

-- A motor must never keep buzzing: stop when the window loses focus, and forget
-- cached support when controllers come and go.
UserInputService.WindowFocusReleased:Connect(stopAll)
UserInputService.GamepadConnected:Connect(function(gamepad)
	supportCache[gamepad] = nil
end)
UserInputService.GamepadDisconnected:Connect(function(gamepad)
	supportCache[gamepad] = nil
	if motorState[gamepad] then
		for _, state in motorState[gamepad] do
			state.token = nil
			state.value = 0
			state.untilTime = 0
		end
	end
end)
-- Switching from controller to touch (or another controller) stops the old one.
UserInputService.LastInputTypeChanged:Connect(function(inputType)
	if isGamepad(inputType) and inputType ~= lastGamepad then
		local old = motorState[lastGamepad]
		if old then
			for motor, state in old do
				state.token = nil
				state.value = 0
				state.untilTime = 0
				setMotor(lastGamepad, motor, 0)
			end
		end
		lastGamepad = inputType
	end
end)

return Haptics
