--[[
	First-run tutorial, the menu spotlight on PLAY, and first-time tips.

	Who gets it: players whose save says they never finished the tutorial
	(TutorialDone = false), or anyone who pressed REPLAY TUTORIAL in settings.

	Menu spotlight: until that first run starts, the menu is dimmed except for
	PLAY, with a bouncing arrow and a big "TAP PLAY TO START" label (CLICK on a
	mouse, PRESS A on a controller). Tapping anywhere else only nudges the
	arrow. It shows once per session for first-time players only (not after
	REPLAY TUTORIAL, not after a tutorial run ends). RunController shows / hides it (needsMenuSpotlight,
	showMenuSpotlight / hideMenuSpotlight).

	First run: one instruction at a time, in this order.
	  1. "TAP TO THROW"           ring on the first pane; done when it breaks
	  2. "ONLY GLOWING GLASS..."  then the ring jumps to a decoration at the
	     "THAT'S JUST DECORATION" side (the glass vase TrackBuilder always puts
	                              there); goes on by itself or with a tap
	  3. "GRAB CRYSTALS"          ring on the crystal; done when collected
	  4. "BALLS = YOUR LIFE"      a frame + arrow on the HUD balls counter,
	     "DON'T CRASH!"           then the crash cost; by itself or with a tap
	  5. "YOU'RE READY!"          and the run goes on normally
	"Target" lessons (1, 3): as the target gets close, time slows almost to a
	stop until you do it. "Info" lessons (2, 4) slow time right away and show
	one or two short cards, each for a few real seconds (a bar along the card's
	bottom shows the time); a tap goes to the next card straight away and
	never throws a ball. Crashes during the tutorial are free. A SKIP button
	ends it at any time.

	Tips: the first time a new obstacle type shows up (doors, moving glass...),
	a short card explains it once, ever. Seen tips are saved on the server.

	Drawn in the game's blueprint style: paper card, ink outline, hard shadow.

	Layout follows UI.luau: the ScreenGuis use CoreUISafeInsets (nothing under
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
local RunService = game:GetService("RunService")
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
local READY = Color3.fromRGB(80, 220, 120)

local SLOW_DISTANCE = 34 -- studs before the target where time starts slowing
local FROZEN_DISTANCE = 18 -- closest the camera gets while waiting
local SLOWEST = 0.08
local TAP_GRACE = 0.5 -- an info card stays at least this long before a tap moves on (taps still don't throw)
local TIP_SECONDS = 3.2
local TIP_SCAN_INTERVAL = 0.25
local TIP_DISTANCE = 45

-- Decorations the "just decoration" lesson may point at: this far ahead (studs).
local DECOR_MIN_AHEAD = 8
local DECOR_MAX_AHEAD = 90
local DECOR_SEARCH_EVERY = 0.25 -- seconds between searches while none is found

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
local CARD_H = 84 -- title line + up to two body lines + the timer bar
local CARD_SHADOW = 5
local SKIP_ACTION = "ShatterRunSkipTutorial"

-- Arrows (spotlight and HUD pointer) are drawn in a square this big.
local ARROW_SIZE = 44
local ARROW_BOUNCE = 8 -- px the arrow bounces back and forth
local HUD_FRAME_PAD = 6 -- px between the balls plate and the frame drawn around it

-- Menu spotlight (sizes in 600x340 sheet units, scaled like the menu).
local SPOT_DIM = 0.4 -- transparency of the dark wash over everything but PLAY
local SPOT_PAD = 6 -- px of clear space around PLAY
local SPOT_LABEL_W = 240
local SPOT_LABEL_H = 62
local SPOT_GAP = 6 -- between the arrow and the label

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
local START_LABELS = { gamepad = "PRESS A TO START", touch = "TAP PLAY TO START", mouse = "CLICK PLAY TO START" }

-- The lessons, in order (see the notes at the top).
-- "target" lessons wait for track.tutorialTargets[target] to break / be collected.
-- "info" lessons show their pages one after another; point = what the ring shows:
-- "decoration" (a decoration ahead) or "balls" (the HUD balls counter).
local LESSONS = {
	{
		kind = "target",
		target = 1,
		title = function()
			return THROW_TITLES[inputKind()]
		end,
		body = "SMASH THE GLOWING GLASS",
	},
	{
		kind = "info",
		pages = {
			{ title = "ONLY GLOWING GLASS", body = "BLOCKS YOUR WAY", seconds = 1.6 },
			{ title = "THAT'S JUST DECORATION", body = "DON'T WASTE BALLS ON IT", seconds = 2.5, point = "decoration" },
		},
	},
	{
		kind = "target",
		target = 2,
		title = "GRAB CRYSTALS",
		body = "HIT THEM - EACH ONE = +" .. Config.CRYSTAL_REWARD .. " BALLS",
	},
	{
		kind = "info",
		pages = {
			{ title = "BALLS = YOUR LIFE", body = "0 BALLS = GAME OVER", seconds = 1.8, point = "balls" },
			{
				title = "DON'T CRASH!",
				body = "CRASHING INTO GLASS COSTS " .. Config.CRASH_PENALTY .. " BALLS",
				seconds = 2.2,
				point = "balls",
				color = DANGER,
			},
		},
	},
}

-- State --------------------------------------------------------------------

local active = false
local step = 0 -- index in LESSONS
local page = 1 -- page of an info lesson
local pageTime = 0 -- real seconds the current info page has been up
local pointed = nil -- the decoration the "just decoration" page points at
local decorSearch = 0 -- seconds until the next search for one
local track
local ballsPlate -- the HUD balls counter (UI:ballsPlate), for the "balls" pages
local scale = 1
local finishedThisSession = false
local replayWanted = false -- REPLAY TUTORIAL was pressed: the next run from the start is a tutorial
local playFound = false -- a tutorial run has started (PLAY was pressed), so no more menu spotlight
local seenThisSession = {}
local tipCooldown = 0
local tipScan = 0
local tipToken
local cardHoldUntil = 0 -- os.clock() time until which the card must stay up
local cardRest = UDim2.new(0.5, 0, 0, 92) -- where the card sits (set by layoutUi)
local cardSlide = -22 -- it slides in from this many px above (top) or below (bottom)
local skipBound = false

-- UI -------------------------------------------------------------------------

local gui, pointerGui, card, cardTitle, cardBody, cardTimer, cardBump, ring, skipButton
local hudFrame, hudArrow

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

-- The same scale UI.luau draws the menu and HUD at.
local function sheetScale(size)
	return math.clamp(math.min(size.X / REF_W, size.Y / REF_H), SCALE_MIN, SCALE_MAX)
end

-- Visible on screen: itself and every ancestor up to an enabled ScreenGui.
local function isShowing(guiObject)
	local node = guiObject
	while node do
		if node:IsA("LayerCollector") then
			return node.Enabled
		end
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		node = node.Parent
	end
	return false
end

-- Where a GuiObject's center is, in another ScreenGui's coordinates (the two
-- ScreenGuis can have different insets; this works whatever they are).
local function centerIn(screenGui, guiObject)
	return guiObject.AbsolutePosition + guiObject.AbsoluteSize / 2 - screenGui.AbsolutePosition
end

-- A thick accent arrow with a hard ink shadow, drawn from plain frames (a shaft
-- and a two-bar head) so it needs no image. direction: Vector2 it points along
-- (screen pixels, y down). The arrow is centered on the returned frame.
local function makeArrow(parent, name, direction)
	local holder = new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(ARROW_SIZE, ARROW_SIZE),
		BackgroundTransparency = 1,
		Active = false,
		Parent = parent,
	})
	local center = Vector2.new(ARROW_SIZE / 2, ARROW_SIZE / 2)
	local tip = center + direction * 18
	local angle = math.deg(math.atan2(direction.Y, direction.X))
	local bars = { { center = center - direction, length = 34, angle = angle } } -- the shaft
	for _, turn in { 40, -40 } do
		local back = math.rad(angle + 180 + turn) -- the head's bars run back from the tip
		local along = Vector2.new(math.cos(back), math.sin(back))
		table.insert(bars, { center = tip + along * 9, length = 20, angle = angle + 180 + turn })
	end
	-- Ink shadow first (3 px down-right), the accent arrow on top.
	for _, layer in { { color = INK, offset = 3 }, { color = ACCENT, offset = 0 } } do
		for _, bar in bars do
			new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(bar.center.X + layer.offset, bar.center.Y + layer.offset),
				Size = UDim2.fromOffset(bar.length, 7),
				Rotation = bar.angle,
				BackgroundColor3 = layer.color,
				BorderSizePixel = 0,
				Active = false,
				Parent = holder,
			})
		end
	end
	return holder
end

-- How far back from its target an arrow is right now (it bounces toward it).
local function bounce()
	return (math.sin(os.clock() * 7) * 0.5 + 0.5) * ARROW_BOUNCE
end

-- Puts the SKIP button under the distance plate and the card where it covers
-- the least: under the balls plate when there is room, else at the bottom.
local function layoutUi()
	local size = gui.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		return
	end
	local sheet = sheetScale(size)
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
	cardBump = new("UIScale", { Parent = holder }) -- a small pop when the text changes
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
		Position = UDim2.fromOffset(18, 7),
		Size = UDim2.new(1, -30, 0, 30),
		BackgroundTransparency = 1,
		Font = Enum.Font.Michroma,
		TextColor3 = INK,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	}, { new("UITextSizeConstraint", { MaxTextSize = 28, MinTextSize = 12 }) })
	-- Up to two lines, so a body of ~50 characters stays readable on a phone.
	cardBody = new("TextLabel", {
		Name = "Body",
		Position = UDim2.fromOffset(18, 40),
		Size = UDim2.new(1, -30, 0, 32),
		BackgroundTransparency = 1,
		Font = Enum.Font.RobotoMono,
		TextColor3 = INK,
		TextTransparency = 0.1,
		TextScaled = true,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = card,
	}, { new("UITextSizeConstraint", { MaxTextSize = 16, MinTextSize = 9 }) })
	-- Info cards: a bar along the bottom fills up until the card moves on by itself.
	local timerTrack = new("Frame", {
		Name = "Timer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 6, 1, 0),
		Size = UDim2.new(1, -6, 0, 4),
		BackgroundColor3 = INK,
		BackgroundTransparency = 0.85,
		BorderSizePixel = 0,
		Visible = false,
		Parent = card,
	})
	cardTimer = new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = ACCENT,
		BorderSizePixel = 0,
		Parent = timerTrack,
	})
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

	-- "Balls" pages: a frame around the HUD balls counter and an arrow under it, pointing up.
	hudFrame = new("Frame", {
		Name = "BallsFrame",
		BackgroundTransparency = 1,
		Active = false,
		Visible = false,
		Parent = pointerGui,
	}, {
		new("UIStroke", { Thickness = 4, Color = ACCENT }),
	})
	hudArrow = makeArrow(pointerGui, "BallsArrow", Vector2.new(0, -1))
	hudArrow.Visible = false

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
	local changed = cardTitle.Text ~= title or cardBody.Text ~= body
	cardTitle.Text = title
	cardBody.Text = body
	card.Paper.Accent.BackgroundColor3 = color or ACCENT
	cardTimer.BackgroundColor3 = color or ACCENT
	if not card.Visible then
		card.Visible = true
		cardBump.Scale = 1
		card.Position = cardRest + UDim2.fromOffset(0, cardSlide)
		TweenService:Create(card, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Position = cardRest }):Play()
	elseif changed then
		-- Next instruction on the same card: a small pop so it reads as new.
		cardBump.Scale = 1.06
		TweenService:Create(cardBump, TweenInfo.new(0.2, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	end
end

-- fraction: how much of an info card's time has gone (nil = no timer bar).
local function setCardTimer(fraction)
	local timerTrack = cardTimer.Parent
	timerTrack.Visible = fraction ~= nil
	if fraction then
		cardTimer.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	end
end

local function hidePointers()
	ring.Visible = false
	hudFrame.Visible = false
	hudArrow.Visible = false
end

local function hideCard()
	card.Visible = false
	setCardTimer(nil)
	hidePointers()
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

-- Pointers --------------------------------------------------------------------

-- The ring over a spot in the world. Returns false when it is off screen.
local function ringAt(worldPosition)
	local screen, onScreen = camera:WorldToViewportPoint(worldPosition)
	ring.Visible = onScreen
	if onScreen then
		ring.Position = UDim2.fromOffset(screen.X, screen.Y)
		local pulse = 1 + math.sin(os.clock() * 6) * 0.12
		ring.Size = UDim2.fromOffset(84 * pulse, 84 * pulse)
	end
	return onScreen
end

-- A frame around the HUD balls counter, and an arrow under it pointing up.
local function pointAtBalls()
	ring.Visible = false
	if ballsPlate == nil or not isShowing(ballsPlate) then
		hudFrame.Visible = false
		hudArrow.Visible = false
		return
	end
	local center = centerIn(pointerGui, ballsPlate)
	local size = ballsPlate.AbsoluteSize
	local pulse = math.sin(os.clock() * 6) * 2
	hudFrame.Visible = true
	hudFrame.Position = UDim2.fromOffset(center.X - size.X / 2 - HUD_FRAME_PAD - pulse, center.Y - size.Y / 2 - HUD_FRAME_PAD - pulse)
	hudFrame.Size = UDim2.fromOffset(size.X + (HUD_FRAME_PAD + pulse) * 2, size.Y + (HUD_FRAME_PAD + pulse) * 2)
	hudArrow.Visible = true
	hudArrow.Position = UDim2.fromOffset(center.X, center.Y + size.Y / 2 + HUD_FRAME_PAD + ARROW_SIZE / 2 + 4 + bounce())
end

-- The decoration nearest ahead that is on screen: the tutorial's own glass vase
-- if it can be seen, else any breakable decoration ("Prop"), else any other
-- decoration part (room walls, floors and fixed light strips don't count).
local function findDecoration(cameraZ)
	local best, bestAhead, bestRank = nil, math.huge, math.huge
	local function consider(part, rank)
		if part == nil or part.Parent == nil or not part.CanQuery then
			return
		end
		local ahead = cameraZ - part.Position.Z
		if ahead < DECOR_MIN_AHEAD or ahead > DECOR_MAX_AHEAD then
			return
		end
		if rank > bestRank or (rank == bestRank and ahead >= bestAhead) then
			return
		end
		local _, onScreen = camera:WorldToViewportPoint(part.Position)
		if onScreen then
			best, bestAhead, bestRank = part, ahead, rank
		end
	end
	consider(track.tutorialDecor, 1)
	if best then
		return best
	end
	for _, room in track.rooms do
		if room.folder.Parent then
			for _, part in room.folder:GetDescendants() do
				if part:IsA("BasePart") then
					local kind = part:GetAttribute("Kind")
					if kind == "Prop" then
						consider(part, 2)
					elseif kind == "Wall" and part:GetAttribute("Shell") ~= true then
						consider(part, 3)
					end
				end
			end
		end
	end
	return best
end

local function pointAtDecoration(dt, cameraZ)
	hudFrame.Visible = false
	hudArrow.Visible = false
	-- Broken (or gone behind): find another one.
	if pointed and (pointed.Parent == nil or not pointed.CanQuery or cameraZ - pointed.Position.Z < 2) then
		pointed = nil
	end
	if pointed == nil then
		decorSearch -= dt
		if decorSearch <= 0 then
			decorSearch = DECOR_SEARCH_EVERY
			pointed = findDecoration(cameraZ)
		end
	end
	if pointed == nil or not ringAt(pointed.Position) then
		ring.Visible = false
	end
end

-- Tutorial -----------------------------------------------------------------

-- Only when the server has loaded the player and says they haven't done it,
-- or after REPLAY TUTORIAL.
function Tutorial.isNeeded()
	if replayWanted then
		return true
	end
	return not finishedThisSession and player:GetAttribute("TutorialDone") == false
end

-- REPLAY TUTORIAL (settings): the next run from the start is a tutorial run.
function Tutorial.replay()
	replayWanted = true
	-- No menu spotlight for a replay: the player already knows where PLAY is, and
	-- an accidental tap shouldn't dim the whole menu.
end

-- The menu spotlight on PLAY: only for real first-time players, until their
-- first tutorial run starts (a run that ends in game over doesn't bring it back;
-- REPLAY TUTORIAL never shows it).
function Tutorial.needsMenuSpotlight()
	return not playFound and not finishedThisSession and player:GetAttribute("TutorialDone") == false
end

-- ballsCounter: the HUD's balls plate (UI:ballsPlate), pointed at by the "balls" pages.
function Tutorial.start(trackBuilder, ballsCounter)
	if not gui then
		buildUi()
	end
	Tutorial.hideMenuSpotlight()
	playFound = true
	track = trackBuilder
	ballsPlate = ballsCounter
	active = true
	step = 1
	page = 1
	pageTime = 0
	pointed = nil
	decorSearch = 0
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
	replayWanted = false
	scale = 1
	setSkipShown(false)
	hidePointers()
	setCardTimer(nil)
	remember("FinishTutorial")

	if skipped then
		hideCard()
	else
		showCard("YOU'RE READY!", "GO AS FAR AS YOU CAN. GOOD LUCK!", READY)
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
	return target.Parent == nil or not target.CanQuery
end

local function nextLesson()
	step += 1
	page = 1
	pageTime = 0
	pointed = nil
	decorSearch = 0
end

-- Next page of an info lesson (or the next lesson after its last page).
local function nextPage()
	local lesson = LESSONS[step]
	if lesson and lesson.kind == "info" and page < #lesson.pages then
		page += 1
		pageTime = 0
		pointed = nil
		decorSearch = 0
	else
		nextLesson()
	end
end

-- A tap / click / A / RT during the run. While an info card is up it moves on
-- (after a short moment, so a throw-tap just before can't skip it unread) and
-- never throws. Returns true when the tutorial used the tap.
function Tutorial.takeTap()
	if not active then
		return false
	end
	local lesson = LESSONS[step]
	if lesson == nil or lesson.kind ~= "info" then
		return false
	end
	if pageTime >= TAP_GRACE then
		nextPage()
	end
	return true
end

-- Call every frame while running (dt in real seconds). Returns the world time multiplier.
function Tutorial.update(dt, cameraZ)
	if not active then
		return 1
	end

	-- A target lesson is over once its target is broken / collected, or missed
	-- and already behind the camera. (A target that isn't built yet: wait.)
	local lesson = LESSONS[step]
	if lesson and lesson.kind == "target" then
		local target = track.tutorialTargets[lesson.target]
		if target ~= nil and (targetDone(target) or cameraZ - target.Position.Z < -2) then
			nextLesson()
		end
	elseif lesson and lesson.kind == "info" and os.clock() >= cardHoldUntil then
		pageTime += dt
		if pageTime >= lesson.pages[page].seconds then
			nextPage()
		end
	end
	lesson = LESSONS[step]
	if lesson == nil then
		Tutorial.finish(false)
		return 1
	end

	local wanted = 1
	local showing = false
	if lesson.kind == "info" and os.clock() < cardHoldUntil then
		-- An "OOPS!" card (free crash) is still up: let it be read first.
		showing = true
		wanted = SLOWEST
		hidePointers()
	elseif lesson.kind == "info" then
		-- Info cards: time almost stops right away, the card says one thing.
		showing = true
		wanted = SLOWEST
		local info = lesson.pages[page]
		showCard(info.title, info.body, info.color)
		setCardTimer(pageTime / info.seconds)
		if info.point == "decoration" then
			pointAtDecoration(dt, cameraZ)
		elseif info.point == "balls" then
			pointAtBalls()
		else
			hidePointers()
		end
	else
		local target = track.tutorialTargets[lesson.target]
		if target and target.Parent then
			local ahead = cameraZ - target.Position.Z
			if ahead > 0 and ahead < SLOW_DISTANCE then
				showing = true
				local title = if type(lesson.title) == "function" then lesson.title() else lesson.title
				showCard(title, lesson.body, ACCENT)
				setCardTimer(nil)

				-- Ease toward almost-frozen; fully slow once close.
				local t = math.clamp((SLOW_DISTANCE - ahead) / (SLOW_DISTANCE - FROZEN_DISTANCE), 0, 1)
				wanted = 1 + (SLOWEST - 1) * t

				hudFrame.Visible = false
				hudArrow.Visible = false
				ringAt(target.Position)
			end
		end
	end
	-- No lesson card needed: hide the card and pointers (an "OOPS!" card stays
	-- up for a moment first).
	if not showing then
		hidePointers()
		if card.Visible and os.clock() >= cardHoldUntil then
			hideCard()
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
	setCardTimer(nil)
	cardHoldUntil = os.clock() + 1.5
	return true
end

-- Menu spotlight ---------------------------------------------------------------
-- Everything on the menu is dimmed except PLAY (four dark panels around it).
-- The panels catch taps, so a tap anywhere else only nudges the arrow.

local spot -- the spotlight's parts, built the first time it shows

local function nudgeSpotlight()
	if spot == nil then
		return
	end
	spot.bump.Scale = 1.15
	TweenService:Create(spot.bump, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	spot.holeStroke.Thickness = 7
	TweenService:Create(spot.holeStroke, TweenInfo.new(0.35), { Thickness = 3 }):Play()
end

local function buildSpotlight()
	local root = new("ScreenGui", {
		Name = "TutorialSpotlight",
		ResetOnSpawn = false,
		DisplayOrder = 21, -- over the menu (UI.luau is 10)
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ClipToDeviceSafeArea = false, -- the dark panels reach every edge of the screen
		Enabled = false,
		Parent = player:WaitForChild("PlayerGui"),
	})
	spot = { gui = root, dims = {} }
	for _, name in { "Top", "Bottom", "Left", "Right" } do
		local dim = new("TextButton", {
			Name = "Dim" .. name,
			AutoButtonColor = false,
			Selectable = false,
			Text = "",
			BackgroundColor3 = INK,
			BackgroundTransparency = SPOT_DIM,
			BorderSizePixel = 0,
			Parent = root,
		})
		dim.Activated:Connect(nudgeSpotlight)
		spot.dims[name] = dim
	end
	-- The accent outline around PLAY (taps go straight through to the button).
	spot.hole = new("Frame", { Name = "Hole", BackgroundTransparency = 1, Active = false, Parent = root })
	spot.holeStroke = new("UIStroke", { Thickness = 3, Color = ACCENT, Parent = spot.hole })

	-- Arrow + label, drawn on the 600x340 sheet and scaled like the menu.
	local pointer = new("Frame", { Name = "Pointer", BackgroundTransparency = 1, Active = false, Parent = root })
	spot.pointer = pointer
	spot.scale = new("UIScale", { Parent = pointer })
	spot.arrowLeft = makeArrow(pointer, "ArrowLeft", Vector2.new(-1, 0)) -- label beside PLAY
	spot.arrowDown = makeArrow(pointer, "ArrowDown", Vector2.new(0, 1)) -- label above PLAY (narrow screens)

	local label = new("Frame", {
		Name = "Label",
		AnchorPoint = Vector2.new(0.5, 0.5), -- so a nudge pops it from its middle
		Size = UDim2.fromOffset(SPOT_LABEL_W, SPOT_LABEL_H),
		BackgroundTransparency = 1,
		Active = false,
		Parent = pointer,
	})
	spot.label = label
	spot.bump = new("UIScale", { Parent = label })
	new("Frame", {
		Name = "Shadow",
		Position = UDim2.fromOffset(CARD_SHADOW, CARD_SHADOW),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = INK,
		BorderSizePixel = 0,
		Parent = label,
	})
	local paper = new("Frame", {
		Name = "Paper",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = PAPER,
		BorderSizePixel = 0,
		Parent = label,
	}, {
		new("UIStroke", { Thickness = 2, Color = INK }),
		new("Frame", { Name = "Accent", Size = UDim2.new(0, 6, 1, 0), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }),
	})
	new("TextLabel", {
		Name = "Index",
		Position = UDim2.fromOffset(16, 5),
		Size = UDim2.new(1, -28, 0, 10),
		BackgroundTransparency = 1,
		Font = Enum.Font.RobotoMono,
		Text = "FIRST RUN / 01",
		TextSize = 9,
		TextColor3 = INK,
		TextTransparency = 0.3,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = paper,
	})
	spot.text = new("TextLabel", {
		Name = "Text",
		Position = UDim2.fromOffset(16, 17),
		Size = UDim2.new(1, -28, 1, -22),
		BackgroundTransparency = 1,
		Font = Enum.Font.Michroma,
		Text = "",
		TextColor3 = INK,
		TextScaled = true,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = paper,
	}, { new("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 10 }) })
end

-- Every frame while the spotlight is up: follows PLAY (the menu slides in,
-- the screen can turn), bounces the arrow and keeps a controller on PLAY.
local function updateSpotlight()
	local target = spot.target
	local visible = target ~= nil and isShowing(target)
	spot.gui.Enabled = visible
	if not visible then
		return
	end
	local size = spot.gui.AbsoluteSize
	if size.X < 300 or size.Y < 150 then
		return -- not laid out yet (no real screen is this small)
	end
	local center = centerIn(spot.gui, target)
	local half = target.AbsoluteSize / 2
	local x0, y0 = center.X - half.X - SPOT_PAD, center.Y - half.Y - SPOT_PAD
	local x1, y1 = center.X + half.X + SPOT_PAD, center.Y + half.Y + SPOT_PAD
	local far = 2000 -- past every screen edge (also under Roblox's top bar)
	local dims = spot.dims
	dims.Top.Position = UDim2.fromOffset(-far, -far)
	dims.Top.Size = UDim2.fromOffset(size.X + far * 2, y0 + far)
	dims.Bottom.Position = UDim2.fromOffset(-far, y1)
	dims.Bottom.Size = UDim2.fromOffset(size.X + far * 2, size.Y - y1 + far)
	dims.Left.Position = UDim2.fromOffset(-far, y0)
	dims.Left.Size = UDim2.fromOffset(x0 + far, y1 - y0)
	dims.Right.Position = UDim2.fromOffset(x1, y0)
	dims.Right.Size = UDim2.fromOffset(size.X - x1 + far, y1 - y0)
	spot.hole.Position = UDim2.fromOffset(x0, y0)
	spot.hole.Size = UDim2.fromOffset(x1 - x0, y1 - y0)
	spot.holeStroke.Transparency = 0.2 + math.sin(os.clock() * 5) * 0.2

	-- Arrow + label beside PLAY (pointing left at it) when there is room on the
	-- right, else above it (pointing down). Kept inside the safe area.
	local s = sheetScale(size)
	spot.scale.Scale = s
	local pointer = spot.pointer
	local sideW = ARROW_SIZE + SPOT_GAP + SPOT_LABEL_W
	local back = bounce()
	if x1 + 6 + sideW * s + EDGE <= size.X then
		pointer.AnchorPoint = Vector2.new(0, 0.5)
		pointer.Size = UDim2.fromOffset(sideW, SPOT_LABEL_H)
		local y = math.clamp((y0 + y1) / 2, SPOT_LABEL_H * s / 2 + EDGE, size.Y - SPOT_LABEL_H * s / 2 - EDGE)
		pointer.Position = UDim2.fromOffset(x1 + 6, y)
		spot.arrowLeft.Visible = true
		spot.arrowDown.Visible = false
		spot.arrowLeft.Position = UDim2.fromOffset(ARROW_SIZE / 2 + back, SPOT_LABEL_H / 2)
		spot.label.Position = UDim2.fromOffset(ARROW_SIZE + SPOT_GAP + SPOT_LABEL_W / 2, SPOT_LABEL_H / 2)
	else
		local tall = SPOT_LABEL_H + SPOT_GAP + ARROW_SIZE
		pointer.AnchorPoint = Vector2.new(0.5, 1)
		pointer.Size = UDim2.fromOffset(SPOT_LABEL_W, tall)
		local x = math.clamp((x0 + x1) / 2, SPOT_LABEL_W * s / 2 + EDGE, size.X - SPOT_LABEL_W * s / 2 - EDGE)
		pointer.Position = UDim2.fromOffset(x, y0 - 4)
		spot.arrowLeft.Visible = false
		spot.arrowDown.Visible = true
		spot.arrowDown.Position = UDim2.fromOffset(SPOT_LABEL_W / 2, tall - ARROW_SIZE / 2 - back)
		spot.label.Position = UDim2.fromOffset(SPOT_LABEL_W / 2, SPOT_LABEL_H / 2)
	end

	local kind = inputKind()
	local wording = START_LABELS[kind]
	if spot.text.Text ~= wording then
		spot.text.Text = wording
	end
	-- A controller always stays on PLAY (the rest of the menu is dimmed).
	if kind == "gamepad" and not GuiService.MenuIsOpen and GuiService.SelectedObject ~= target and target.Selectable then
		local wandered = GuiService.SelectedObject ~= nil
		GuiService.SelectedObject = target
		if wandered then
			nudgeSpotlight()
		end
	end
end

-- Dims the menu except `playButton` (UI:playButton) and points at it. Stays up
-- until hideMenuSpotlight; hides itself while the button isn't on screen.
function Tutorial.showMenuSpotlight(playButton)
	if spot == nil then
		buildSpotlight()
	end
	spot.target = playButton
	if spot.connection == nil then
		spot.connection = RunService.RenderStepped:Connect(updateSpotlight)
		updateSpotlight()
	end
end

function Tutorial.hideMenuSpotlight()
	if spot == nil then
		return
	end
	spot.target = nil
	spot.gui.Enabled = false
	if spot.connection then
		spot.connection:Disconnect()
		spot.connection = nil
	end
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
	setCardTimer(nil)
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
	pointed = nil
	if gui then
		hideCard()
		setSkipShown(false)
	end
end

return Tutorial
