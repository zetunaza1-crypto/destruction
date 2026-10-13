--[[
	First-run tutorial and first-time tips.

	Tutorial (first run only): rooms 1-3 each teach one thing. As the lesson's
	target gets close, time slows almost to a stop, a card explains what to do
	and a ring points at the target. Doing it resumes the run. Crashes during
	the tutorial are free. A SKIP button ends it at any time.

	Tips: the first time a new obstacle type shows up (doors, moving glass...),
	a short card explains it once, ever. Seen tips are saved on the server.

	Drawn in the game's blueprint style: paper card, ink outline, hard shadow.

	Layout follows UI.luau: the ScreenGui uses CoreUISafeInsets (nothing under
	Roblox's top bar or a notch). The SKIP button sits under the HUD's distance
	plate; the card sits under the balls plate when the screen is tall enough,
	otherwise (phones) at the bottom between the corner buttons, so it never
	covers the middle of the screen where the targets are.
	On a controller, Y skips (and SKIP is selectable like any other button).
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local Tutorial = {}

local PAPER = Color3.fromRGB(244, 241, 234)
local INK = Color3.fromRGB(17, 17, 17)
local ACCENT = Color3.fromRGB(90, 200, 255)
local DANGER = Color3.fromRGB(235, 60, 60)

local SLOW_DISTANCE = 34 -- studs before the target where time starts slowing
local FROZEN_DISTANCE = 18 -- closest the camera gets while waiting
local SLOWEST = 0.08
local TIP_SECONDS = 3.2
local TIP_SCAN_INTERVAL = 0.25
local TIP_DISTANCE = 45

-- Mirrors of UI.luau's HUD layout numbers (600x340 sheet, HUD plates at 0.85),
-- so the card and SKIP button can sit just under the HUD plates.
local REF_W, REF_H = 600, 340
local SCALE_MIN, SCALE_MAX = 0.8, 2
local HUD_SCALE = 0.85
local EDGE = 12
local HUD_TOP = EDGE - 4
local BALLS_BLOCK_H = 144 -- balls plate + controller hint + boost rail
local DISTANCE_PLATE_H = 62
local CORNER_BUTTON_W = 122 -- ball pack (bottom-right) / shield (bottom-left)
local CARD_H = 74
local CARD_SHADOW = 5
local SKIP_ACTION = "ShatterRunSkipTutorial"

-- How the player is playing right now: "gamepad", "touch" or "mouse".
-- Asked at lesson time (not at load), so plugging in a controller mid-session counts.
local function inputKind()
	local last = UserInputService:GetLastInputType()
	if string.sub(last.Name, 1, 7) == "Gamepad" then
		return "gamepad"
	elseif last == Enum.UserInputType.Touch then
		return "touch"
	elseif
		last == Enum.UserInputType.Keyboard
		or last == Enum.UserInputType.MouseMovement
		or last == Enum.UserInputType.MouseButton1
		or last == Enum.UserInputType.MouseButton2
		or last == Enum.UserInputType.MouseWheel
	then
		return "mouse"
	end
	-- No telling input yet (or gyro etc.): guess from the device.
	if GuiService:IsTenFootInterface() then
		return "gamepad"
	elseif UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		return "touch"
	end
	return "mouse"
end

local THROW_TITLES = { gamepad = "PRESS R2 TO THROW", touch = "TAP TO THROW", mouse = "CLICK TO THROW" }

local LESSONS = {
	{
		title = function()
			return THROW_TITLES[inputKind()]
		end,
		body = "AIM AT THE GLASS AND SMASH IT",
	},
	{ title = "HIT THE CRYSTAL", body = "EVERY CRYSTAL GIVES YOU +" .. Config.CRYSTAL_REWARD .. " BALLS" },
	{ title = "DON'T CRASH!", body = "FLYING INTO GLASS COSTS " .. Config.CRASH_PENALTY .. " BALLS - BREAK IT FIRST" },
}

-- State --------------------------------------------------------------------

local active = false
local step = 0
local track
local scale = 1
local finishedThisSession = false
local seenThisSession = {}
local tipCooldown = 0
local tipScan = 0
local tipToken
local cardHoldUntil = 0 -- os.clock() time until which the card must stay up
local cardRest = UDim2.new(0.5, 0, 0, 92) -- where the card sits (set by layoutUi)
local cardSlide = -22 -- it slides in from this many px above (top) or below (bottom)
local skipBound = false

-- UI -------------------------------------------------------------------------

local gui, pointerGui, card, cardTitle, cardBody, ring, skipButton

local function new(className, props, children)
	local instance = Instance.new(className)
	for name, value in props do
		if name ~= "Parent" then
			instance[name] = value
		end
	end
	for _, child in children or {} do
		child.Parent = instance
	end
	instance.Parent = props.Parent
	return instance
end

-- Puts the SKIP button under the distance plate and the card where it covers
-- the least: under the balls plate when there is room, else at the bottom.
local function layoutUi()
	local size = gui.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		return
	end
	local sheet = math.clamp(math.min(size.X / REF_W, size.Y / REF_H), SCALE_MIN, SCALE_MAX)
	local hud = sheet * HUD_SCALE

	skipButton.Position = UDim2.new(1, -EDGE, 0, math.floor(HUD_TOP + DISTANCE_PLATE_H * hud + 8))

	local top = math.floor(HUD_TOP + BALLS_BLOCK_H * hud + 10)
	local width
	if top + CARD_H <= size.Y * 0.4 then
		width = math.clamp(size.X * 0.7, 260, 460)
		card.AnchorPoint = Vector2.new(0.5, 0)
		cardRest = UDim2.new(0.5, 0, 0, top)
		cardSlide = -22
	else
		local corner = EDGE + CORNER_BUTTON_W * sheet + 8
		width = math.clamp(size.X - corner * 2 - CARD_SHADOW, 240, 460)
		card.AnchorPoint = Vector2.new(0.5, 1)
		cardRest = UDim2.new(0.5, 0, 1, -(EDGE + CARD_SHADOW))
		cardSlide = 22
	end
	card.Size = UDim2.fromOffset(math.floor(width), CARD_H)
	card.Position = cardRest
end

local function refreshSkipLabel()
	if skipButton then
		skipButton.Text = if inputKind() == "gamepad" then "Y  SKIP TUTORIAL" else "SKIP TUTORIAL"
	end
end

-- SKIP is shown (and Y bound to it) only while the tutorial is running and not paused.
local function setSkipShown(shown)
	skipButton.Visible = shown
	if shown then
		refreshSkipLabel()
	end
	if shown ~= skipBound then
		skipBound = shown
		if shown then
			ContextActionService:BindAction(SKIP_ACTION, function(_, inputState)
				if inputState == Enum.UserInputState.Begin then
					Tutorial.finish(true)
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.KeyCode.ButtonY)
		else
			ContextActionService:UnbindAction(SKIP_ACTION)
		end
	end
end

local function buildUi()
	-- CoreUISafeInsets keeps the card and SKIP clear of Roblox's top bar and notches.
	gui = new("ScreenGui", {
		Name = "TutorialHints",
		ResetOnSpawn = false,
		DisplayOrder = 20,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		Parent = player:WaitForChild("PlayerGui"),
	})
	-- The pointer covers the whole screen (no insets), so its coordinates are
	-- exactly what camera:WorldToViewportPoint returns.
	pointerGui = new("ScreenGui", {
		Name = "TutorialPointer",
		ResetOnSpawn = false,
		DisplayOrder = 19,
		ScreenInsets = Enum.ScreenInsets.None,
		Parent = player:WaitForChild("PlayerGui"),
	})

	-- Instruction card: placed by layoutUi, clear of the middle of the screen.
	local holder = new("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = cardRest,
		Size = UDim2.fromOffset(400, CARD_H),
		BackgroundTransparency = 1,
		Active = false,
		Visible = false,
		Parent = gui,
	})
	-- Hard ink shadow, then the paper card on top.
	new("Frame", {
		Name = "Shadow",
		Position = UDim2.fromOffset(CARD_SHADOW, CARD_SHADOW),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = INK,
		BorderSizePixel = 0,
		Active = false,
		Parent = holder,
	})
	card = new("Frame", {
		Name = "Paper",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = PAPER,
		BorderSizePixel = 0,
		Active = false,
		Parent = holder,
	}, {
		new("UIStroke", { Thickness = 2, Color = INK }),
		new("Frame", {
			Name = "Accent",
			Size = UDim2.new(0, 6, 1, 0),
			BackgroundColor3 = ACCENT,
			BorderSizePixel = 0,
		}),
	})
	cardTitle = new("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(18, 8),
		Size = UDim2.new(1, -30, 0, 32),
		BackgroundTransparency = 1,
		Font = Enum.Font.Michroma,
		TextColor3 = INK,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	}, { new("UITextSizeConstraint", { MaxTextSize = 26, MinTextSize = 12 }) })
	cardBody = new("TextLabel", {
		Name = "Body",
		Position = UDim2.fromOffset(18, 44),
		Size = UDim2.new(1, -30, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.RobotoMono,
		TextColor3 = INK,
		TextTransparency = 0.15,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	}, { new("UITextSizeConstraint", { MaxTextSize = 14, MinTextSize = 8 }) })
	card = holder

	-- Pointer ring over the target (square ring = blueprint style, not a circle).
	ring = new("Frame", {
		Name = "Pointer",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(84, 84),
		Rotation = 45,
		BackgroundTransparency = 1,
		Active = false,
		Visible = false,
		Parent = pointerGui,
	}, {
		new("UIStroke", { Thickness = 4, Color = ACCENT }),
	})

	-- 150x44: a full-size tap target; selectable so a controller can reach it too
	-- (it uses the blueprint selection box UI.luau sets on PlayerGui).
	skipButton = new("TextButton", {
		Name = "Skip",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -EDGE, 0, 70),
		Size = UDim2.fromOffset(150, 44),
		BackgroundColor3 = PAPER,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Selectable = true,
		Font = Enum.Font.RobotoMono,
		Text = "SKIP TUTORIAL",
		TextColor3 = INK,
		TextScaled = true,
		Visible = false,
		Parent = gui,
	}, {
		new("UIStroke", { Thickness = 2, Color = INK, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
		new("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 8 }),
		new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
	})
	skipButton.Activated:Connect(function()
		Tutorial.finish(true)
	end)

	layoutUi()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutUi)
	UserInputService.LastInputTypeChanged:Connect(function()
		if skipButton.Visible then
			refreshSkipLabel()
		end
	end)
end

local function showCard(title, body, color)
	cardTitle.Text = title
	cardBody.Text = body
	card.Paper.Accent.BackgroundColor3 = color or ACCENT
	if not card.Visible then
		card.Visible = true
		card.Position = cardRest + UDim2.fromOffset(0, cardSlide)
		TweenService:Create(card, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Position = cardRest }):Play()
	end
end

local function hideCard()
	card.Visible = false
	ring.Visible = false
end

-- Cards that hide themselves later (tips, "YOU'RE READY!") use this token so
-- an old timer never hides a newer card.
local function hideLater(seconds)
	local token = {}
	tipToken = token
	task.delay(seconds, function()
		if tipToken == token and not active then
			hideCard()
		end
	end)
end

local function remember(action, argument)
	task.spawn(function()
		pcall(function()
			Remotes.ShopRequest:InvokeServer(action, argument)
		end)
	end)
end

-- Tutorial -----------------------------------------------------------------

-- Only when the server has loaded the player and says they haven't done it.
function Tutorial.isNeeded()
	return not finishedThisSession and player:GetAttribute("TutorialDone") == false
end

function Tutorial.start(trackBuilder)
	if not gui then
		buildUi()
	end
	track = trackBuilder
	active = true
	step = 1
	scale = 1
	setSkipShown(true)
end

function Tutorial.isActive()
	return active
end

-- Where the lesson's pointer ring is right now (viewport pixels) and how far it
-- reaches from its center, or nil when it isn't showing. The ball in the
-- player's hand (HeldBall.luau) steps aside rather than cover the target.
function Tutorial.pointerTarget()
	if not active or not ring or not ring.Visible then
		return nil
	end
	local position = ring.Position
	-- The ring is a square turned 45 degrees: its corners reach ~0.71 x its size.
	return Vector2.new(position.X.Offset, position.Y.Offset), ring.Size.X.Offset * 0.71
end

function Tutorial.finish(skipped)
	if not active then
		return
	end
	active = false
	finishedThisSession = true
	scale = 1
	setSkipShown(false)
	ring.Visible = false
	remember("FinishTutorial")

	if skipped then
		hideCard()
	else
		showCard("YOU'RE READY!", "GO AS FAR AS YOU CAN. GOOD LUCK!", Color3.fromRGB(80, 220, 120))
		tipCooldown = 2.5 -- don't cover it with a tip straight away
		hideLater(2)
	end
end

-- Game over screen: hide the tutorial (the SKIP button would sit on top of
-- the game over buttons). A revive shows it again.
function Tutorial.setPaused(paused)
	if not gui or not active then
		return
	end
	setSkipShown(not paused)
	if paused then
		hideCard()
	end
end

-- A lesson is done once its target is broken (gone) or collected.
local function targetDone(target)
	return target == nil or target.Parent == nil or not target.CanQuery
end

-- Call every frame while running. Returns the world time multiplier.
function Tutorial.update(dt, cameraZ)
	if not active then
		return 1
	end

	local target = track.tutorialTargets[step]
	-- Done (broken/collected), or missed and already behind the camera: next lesson.
	if step <= #LESSONS and target ~= nil then
		local passed = target.Parent ~= nil and cameraZ - target.Position.Z < -2
		if targetDone(target) or passed then
			step += 1
			target = track.tutorialTargets[step]
		end
	end
	if step > #LESSONS then
		Tutorial.finish(false)
		return 1
	end

	local wanted = 1
	local showing = false
	if target and target.Parent then
		local ahead = cameraZ - target.Position.Z
		if ahead > 0 and ahead < SLOW_DISTANCE then
			showing = true
			local lesson = LESSONS[step]
			local title = if type(lesson.title) == "function" then lesson.title() else lesson.title
			showCard(title, lesson.body, if step == 3 then DANGER else ACCENT)

			-- Ease toward almost-frozen; fully slow once close.
			local t = math.clamp((SLOW_DISTANCE - ahead) / (SLOW_DISTANCE - FROZEN_DISTANCE), 0, 1)
			wanted = 1 + (SLOWEST - 1) * t

			-- Point at the target.
			local screen, onScreen = camera:WorldToViewportPoint(target.Position)
			ring.Visible = onScreen
			if onScreen then
				ring.Position = UDim2.fromOffset(screen.X, screen.Y)
				local pulse = 1 + math.sin(os.clock() * 6) * 0.12
				ring.Size = UDim2.fromOffset(84 * pulse, 84 * pulse)
			end
		end
	end
	-- No lesson target close: hide the card and pointer (an "OOPS!" card stays
	-- up for a moment first).
	if not showing then
		ring.Visible = false
		if card.Visible and os.clock() >= cardHoldUntil then
			card.Visible = false
		end
	end

	-- Smooth so the slow-down never snaps.
	scale += (wanted - scale) * math.min(1, dt * 8)
	return scale
end

-- Crashes during the tutorial don't cost balls.
function Tutorial.crashIsFree()
	if not active then
		return false
	end
	showCard("OOPS!", "THAT WOULD HAVE COST " .. Config.CRASH_PENALTY .. " BALLS - THROW EARLIER", DANGER)
	cardHoldUntil = os.clock() + 1.5
	return true
end

-- Tips -----------------------------------------------------------------------

local function seenHints()
	local ok, list = pcall(function()
		return game:GetService("HttpService"):JSONDecode(player:GetAttribute("Hints") or "[]")
	end)
	return if ok and type(list) == "table" then list else {}
end

-- Shows a first-time tip if this player has never seen it.
-- Returns true once there's nothing left to do (shown now, or seen before), false
-- if it couldn't show yet (lesson or another tip on screen, save not loaded).
function Tutorial.tip(hintId)
	local text = Config.Hints[hintId]
	if not text or seenThisSession[hintId] then
		return true
	end
	if active or tipCooldown > 0 or player:GetAttribute("Hints") == nil then
		return false
	end
	if table.find(seenHints(), hintId) then
		seenThisSession[hintId] = true
		return true
	end
	if not gui then
		buildUi()
	end
	seenThisSession[hintId] = true
	tipCooldown = TIP_SECONDS + 0.5
	remember("SeenHint", hintId)

	showCard("NEW!", text, ACCENT)
	hideLater(TIP_SECONDS)
	return true
end

-- Looks ahead for obstacle types the player hasn't been told about yet.
function Tutorial.scanForTips(dt, cameraZ, trackBuilder)
	tipCooldown = math.max(0, tipCooldown - dt)
	tipScan -= dt
	if tipScan > 0 or active or tipCooldown > 0 then
		return
	end
	tipScan = TIP_SCAN_INTERVAL

	for _, hazard in trackBuilder:hazards() do
		local pattern = hazard:GetAttribute("Pattern")
		if pattern and Config.Hints[pattern] and not seenThisSession[pattern] then
			local ahead = cameraZ - hazard.Position.Z
			if ahead > 0 and ahead < TIP_DISTANCE then
				Tutorial.tip(pattern)
				return
			end
		end
	end
end

-- Hides everything (e.g. when going back to the menu).
function Tutorial.reset()
	active = false
	scale = 1
	tipToken = nil
	if gui then
		hideCard()
		setSkipShown(false)
	end
end

return Tutorial
