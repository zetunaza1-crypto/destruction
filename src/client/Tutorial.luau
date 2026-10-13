--[[
	First-run tutorial and first-time tips.

	Tutorial (first run only): rooms 1-3 each teach one thing. As the lesson's
	target gets close, time slows almost to a stop, a card explains what to do
	and a ring points at the target. Doing it resumes the run. Crashes during
	the tutorial are free. A SKIP button ends it at any time.

	Tips: the first time a new obstacle type shows up (doors, moving glass...),
	a short card explains it once, ever. Seen tips are saved on the server.

	Drawn in the game's blueprint style: paper card, ink outline, hard shadow.
]]

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

local isTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local LESSONS = {
	{ title = if isTouch then "TAP TO THROW" else "CLICK TO THROW", body = "AIM AT THE GLASS AND SMASH IT" },
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

-- UI -------------------------------------------------------------------------

local gui, card, cardTitle, cardBody, ring, skipButton

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

local function buildUi()
	gui = new("ScreenGui", {
		Name = "TutorialHints",
		ResetOnSpawn = false,
		DisplayOrder = 20,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
		Parent = player:WaitForChild("PlayerGui"),
	})

	-- Instruction card: top center, clear of the middle of the screen.
	local holder = new("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 92),
		Size = UDim2.new(0.7, 0, 0, 74),
		BackgroundTransparency = 1,
		Active = false,
		Visible = false,
		Parent = gui,
	}, {
		new("UISizeConstraint", { MaxSize = Vector2.new(460, 74), MinSize = Vector2.new(260, 64) }),
	})
	-- Hard ink shadow, then the paper card on top.
	new("Frame", {
		Name = "Shadow",
		Position = UDim2.fromOffset(5, 5),
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
		Parent = gui,
	}, {
		new("UIStroke", { Thickness = 4, Color = ACCENT }),
	})

	skipButton = new("TextButton", {
		Name = "Skip",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 56),
		Size = UDim2.fromOffset(120, 40),
		BackgroundColor3 = PAPER,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Font = Enum.Font.RobotoMono,
		Text = "SKIP TUTORIAL",
		TextColor3 = INK,
		TextSize = 13,
		Visible = false,
		Parent = gui,
	}, { new("UIStroke", { Thickness = 2, Color = INK, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) })
	skipButton.Activated:Connect(function()
		Tutorial.finish(true)
	end)
end

local function showCard(title, body, color)
	cardTitle.Text = title
	cardBody.Text = body
	card.Paper.Accent.BackgroundColor3 = color or ACCENT
	if not card.Visible then
		card.Visible = true
		card.Position = UDim2.new(0.5, 0, 0, 70)
		TweenService:Create(card, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Position = UDim2.new(0.5, 0, 0, 92) }):Play()
	end
end

local function hideCard()
	card.Visible = false
	ring.Visible = false
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
	skipButton.Visible = true
end

function Tutorial.isActive()
	return active
end

function Tutorial.finish(skipped)
	if not active then
		return
	end
	active = false
	finishedThisSession = true
	scale = 1
	skipButton.Visible = false
	ring.Visible = false
	remember("FinishTutorial")

	if skipped then
		hideCard()
	else
		showCard("YOU'RE READY!", "GO AS FAR AS YOU CAN. GOOD LUCK!", Color3.fromRGB(80, 220, 120))
		task.delay(2, function()
			if not active then
				hideCard()
			end
		end)
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
	if target and target.Parent then
		local ahead = cameraZ - target.Position.Z
		if ahead > 0 and ahead < SLOW_DISTANCE then
			local lesson = LESSONS[step]
			showCard(lesson.title, lesson.body, if step == 3 then DANGER else ACCENT)

			-- Ease toward almost-frozen; fully slow once close.
			local t = math.clamp((SLOW_DISTANCE - ahead) / (SLOW_DISTANCE - FROZEN_DISTANCE), 0, 1)
			wanted = 1 + (SLOWEST - 1) * t

			-- Point at the target.
			local screen, onScreen = camera:WorldToViewportPoint(target.Position)
			ring.Visible = onScreen
			if onScreen then
				local inset = gui.AbsolutePosition
				ring.Position = UDim2.fromOffset(screen.X - inset.X, screen.Y - inset.Y)
				local pulse = 1 + math.sin(os.clock() * 6) * 0.12
				ring.Size = UDim2.fromOffset(84 * pulse, 84 * pulse)
			end
		elseif card.Visible and ahead <= 0 then
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
function Tutorial.tip(hintId)
	local text = Config.Hints[hintId]
	if not text or active or seenThisSession[hintId] or tipCooldown > 0 then
		return
	end
	if player:GetAttribute("Hints") == nil or table.find(seenHints(), hintId) then
		return
	end
	if not gui then
		buildUi()
	end
	seenThisSession[hintId] = true
	tipCooldown = TIP_SECONDS + 0.5
	remember("SeenHint", hintId)

	showCard("NEW!", text, ACCENT)
	local token = {}
	tipToken = token
	task.delay(TIP_SECONDS, function()
		if tipToken == token and not active then
			hideCard()
		end
	end)
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
	if gui then
		hideCard()
		skipButton.Visible = false
	end
end

return Tutorial
