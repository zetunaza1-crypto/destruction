--[[
	"Wait! A free gift for you."

	When a player opens the Roblox menu (Esc / the Roblox button / Start on a
	controller), they might be about to leave. If they close it again and come
	back, we surprise them with a free gift (Config.LeaveGift.Rewards, taking
	turns).

	Rules:
	  * Nothing happens while the menu is open, so leaving is never blocked or slowed.
	  * Only after Config.LeaveGift.MinPlaySeconds of play this session, and only
	    when the server's cooldown (LeaveGiftNext attribute) has run out.
	  * At most once per cooldown window (declining means no more popups this session).
	  * Never in the middle of a run: it waits for the menu / game over screen.
	The server checks everything again when CLAIM is pressed (Shop "ClaimLeaveGift").
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Sounds = require(script.Parent.Sounds)

local player = Players.LocalPlayer

local LeaveGift = {}

-- Look (same "glass lab" palette as UI.luau)
local PAPER = Color3.fromRGB(244, 241, 234)
local INK = Color3.fromRGB(17, 17, 17)
local GREY = Color3.fromRGB(112, 108, 100)
local WHITE = Color3.new(1, 1, 1)
local FONT_NUM = Enum.Font.Michroma
local FONT_LABEL = Enum.Font.RobotoMono

local DISPLAY_ORDER = 50 -- above the main UI (10) and the tutorial (20)
local REF_W, REF_H = 600, 340 -- same reference sheet as UI.luau
local SCALE_MIN, SCALE_MAX = 0.8, 2
local CARD_W, CARD_H = 320, 228
local SHADOW = 6
local SHARDS = 28
local CHECK_INTERVAL = 0.5 -- seconds between checks while a gift is waiting for the run to end

local settings = Config.LeaveGift
local sessionStart = os.clock()

local options = {} -- { claim = function() -> (ok, message), canShow = function() -> bool }
local accentColor = Config.Themes[1].Accent
local accentTargets = {} -- instance -> property

local gui, wash, fitScale, popScale, burstLayer
local rewardLabel, claimButton, claimLabel, claimPulseScale, noThanksButton, statusLabel

local menuWasOpened = false
local pending = false -- came back from the menu during a run: show when it ends
local showing = false
local busy = false
local shownWindow = nil -- LeaveGiftNext value when we last showed it (once per window)
local pulseTween = nil

-- Helpers ------------------------------------------------------------------------

local function new(className, props)
	local instance = Instance.new(className)
	if instance:IsA("GuiObject") then
		instance.BorderSizePixel = 0
	end
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	instance.Parent = props.Parent
	return instance
end

local function stroke(parent, thickness, color)
	return new("UIStroke", {
		Thickness = thickness,
		Color = color or INK,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Miter,
		Parent = parent,
	})
end

local function label(props)
	local merged = {
		BackgroundTransparency = 1,
		Font = FONT_LABEL,
		TextColor3 = INK,
		TextSize = 10,
		Text = "",
	}
	for key, value in props do
		merged[key] = value
	end
	return new("TextLabel", merged)
end

local function accent(instance, property)
	instance[property] = accentColor
	accentTargets[instance] = property
	return instance
end

local function tween(instance, time, props, style, direction)
	local t = TweenService:Create(
		instance,
		TweenInfo.new(time, style or Enum.EasingStyle.Quint, direction or Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

local function isGamepad(inputType)
	return string.sub(inputType.Name, 1, 7) == "Gamepad"
end

-- Eligibility --------------------------------------------------------------------

local function rewards()
	return if settings and type(settings.Rewards) == "table" then settings.Rewards else {}
end

local function nextReward()
	local list = rewards()
	local index = tonumber(player:GetAttribute("LeaveGiftIndex"))
	if #list == 0 or not index then
		return nil
	end
	return list[math.floor(index) % #list + 1]
end

local function isEligible()
	if not settings or showing then
		return false
	end
	local nextTime = tonumber(player:GetAttribute("LeaveGiftNext"))
	if not nextTime or not nextReward() then
		return false -- data not loaded yet, or no rewards set up
	end
	if shownWindow == nextTime then
		return false -- already offered in this window (claimed windows move LeaveGiftNext on)
	end
	if os.clock() - sessionStart < settings.MinPlaySeconds then
		return false
	end
	return workspace:GetServerTimeNow() >= nextTime
end

-- Popup --------------------------------------------------------------------------

-- Confetti: little glass shards (triangles) flying out of the card.
local function burst(count)
	local colors = { accentColor, INK, WHITE, accentColor }
	for i = 1, count do
		local size = math.random(6, 14)
		local shard = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(size, size * (0.6 + math.random() * 0.8)),
			Rotation = math.random(0, 359),
			BackgroundColor3 = colors[i % #colors + 1],
			ZIndex = 5,
			Parent = burstLayer,
		})
		-- A diagonal hard-edged gradient turns the square into a triangle.
		new("UIGradient", {
			Rotation = 45,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.499, 0),
				NumberSequenceKeypoint.new(0.501, 1),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = shard,
		})

		local angle = (i / count) * math.pi * 2 + (math.random() - 0.5) * 0.5
		local distance = 140 + math.random() * 140
		local target = Vector2.new(math.cos(angle) * distance, math.sin(angle) * distance * 0.75 - 30)
		local time = 0.7 + math.random() * 0.4
		tween(shard, time, {
			Position = UDim2.new(0.5, target.X, 0.5, target.Y),
			Rotation = shard.Rotation + math.random(-360, 360),
		}, Enum.EasingStyle.Quad)
		task.delay(time * 0.5, function()
			if shard.Parent then
				tween(shard, time * 0.5, { BackgroundTransparency = 1 }, Enum.EasingStyle.Linear)
			end
		end)
		task.delay(time + 0.05, function()
			shard:Destroy()
		end)
	end
end

local function refit()
	if not gui then
		return
	end
	local size = gui.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		return
	end
	fitScale.Scale = math.clamp(math.min(size.X / REF_W, size.Y / REF_H), SCALE_MIN, SCALE_MAX)
end

local function stopPulse()
	if pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
	end
	if claimPulseScale then
		claimPulseScale.Scale = 1
	end
end

local function hide()
	if not showing then
		return
	end
	showing = false
	busy = false
	stopPulse()
	-- Give gamepad selection back if it was on our buttons.
	local selected = GuiService.SelectedObject
	if selected and gui and selected:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	tween(wash, 0.2, { BackgroundTransparency = 1 })
	local closing = tween(popScale, 0.2, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	closing.Completed:Once(function()
		if not showing then
			gui.Enabled = false
		end
	end)
end

local function show()
	local reward = nextReward()
	if not reward or not gui then
		return
	end
	showing = true
	busy = false
	shownWindow = tonumber(player:GetAttribute("LeaveGiftNext"))

	rewardLabel.Text = string.upper(tostring(reward.Text or "FREE GIFT"))
	claimLabel.Text = "CLAIM"
	statusLabel.Text = ""
	gui.Enabled = true
	refit()

	-- Punchy pop-in: overshoot, a little wobble, then shards everywhere.
	wash.BackgroundTransparency = 1
	tween(wash, 0.25, { BackgroundTransparency = 0.3 })
	popScale.Scale = 0.3
	tween(popScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	local pop = popScale.Parent
	pop.Rotation = -6
	tween(pop, 0.5, { Rotation = 0 }, Enum.EasingStyle.Elastic)
	Sounds.play("Gift")
	burst(SHARDS)

	-- The CLAIM button breathes to draw the eye.
	stopPulse()
	pulseTween = TweenService:Create(
		claimPulseScale,
		TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, 0.45),
		{ Scale = 1.06 }
	)
	pulseTween:Play()

	if isGamepad(UserInputService:GetLastInputType()) then
		GuiService.SelectedObject = claimButton
	end
end

local function claim()
	if not showing or busy then
		return
	end
	busy = true
	stopPulse()
	claimLabel.Text = "..."
	local ok, message = false, "Try again later"
	if options.claim then
		ok, message = options.claim()
	end
	if not showing then
		return -- closed while we were waiting
	end
	if ok then
		-- The server's "Reward" toast says what was given.
		claimLabel.Text = "CLAIMED!"
		burst(SHARDS)
		task.delay(0.7, hide)
	else
		claimLabel.Text = "CLAIM"
		statusLabel.Text = string.upper(tostring(message or "Try again later"))
		task.delay(1.8, hide)
	end
end

local function buildGui()
	gui = new("ScreenGui", {
		Name = "LeaveGift",
		ResetOnSpawn = false,
		DisplayOrder = DISPLAY_ORDER,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,
		Enabled = false,
	})
	gui.ScreenInsets = Enum.ScreenInsets.None -- the wash covers the whole screen

	-- Paper wash over the game (also stops taps going through to throws).
	wash = new("TextButton", {
		Name = "Wash",
		AutoButtonColor = false,
		Selectable = false,
		Text = "",
		BackgroundColor3 = PAPER,
		BackgroundTransparency = 0.3,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})

	local fitHolder = new("Frame", {
		Name = "Fit",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(CARD_W, CARD_H),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	fitScale = new("UIScale", { Parent = fitHolder })

	burstLayer = new("Frame", {
		Name = "Burst",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = fitHolder,
	})

	local popHolder = new("Frame", {
		Name = "Pop",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = fitHolder,
	})
	popScale = new("UIScale", { Parent = popHolder })

	-- Hard ink shadow + the paper card.
	new("Frame", {
		Name = "Shadow",
		Position = UDim2.fromOffset(SHADOW, SHADOW),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = INK,
		Parent = popHolder,
	})
	local card = new("Frame", {
		Name = "Card",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = PAPER,
		Active = true,
		Parent = popHolder,
	})
	stroke(card, 2)

	-- Header strip.
	local header = new("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundColor3 = INK,
		Parent = card,
	})
	label({
		Text = "FIG. 00 / SPECIAL DELIVERY",
		TextSize = 9,
		TextColor3 = PAPER,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(0.7, -10, 1, 0),
		Parent = header,
	})
	accent(label({
		Text = "FREE",
		TextSize = 9,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.7, 0),
		Size = UDim2.new(0.3, -10, 1, 0),
		Parent = header,
	}), "TextColor3")

	-- Title.
	label({
		Text = "WAIT!",
		Font = FONT_NUM,
		TextSize = 32,
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 36),
		Parent = card,
	})
	label({
		Text = "A FREE GIFT FOR YOU",
		Font = FONT_NUM,
		TextSize = 12,
		Position = UDim2.fromOffset(0, 68),
		Size = UDim2.new(1, 0, 0, 16),
		Parent = card,
	})

	-- The reward plate: paper with an ink hairline and a zone-accent edge.
	local plate = new("Frame", {
		Name = "Reward",
		Position = UDim2.fromOffset(20, 94),
		Size = UDim2.new(1, -40, 0, 42),
		BackgroundColor3 = PAPER,
		Parent = card,
	})
	stroke(plate, 1.5)
	accent(new("Frame", {
		Name = "Edge",
		Size = UDim2.new(0, 8, 1, 0),
		Parent = plate,
	}), "BackgroundColor3")
	label({
		Text = "ITEM 01",
		TextSize = 8,
		TextColor3 = GREY,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 2),
		Size = UDim2.fromOffset(60, 10),
		Parent = plate,
	})
	rewardLabel = label({
		Font = FONT_NUM,
		TextSize = 14,
		TextWrapped = true,
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -22, 1, -10),
		Parent = plate,
	})

	-- Big CLAIM button: zone-accent face on a hard ink shadow, breathing.
	local claimHolder = new("Frame", {
		Name = "Claim",
		Position = UDim2.fromOffset(20, 146),
		Size = UDim2.new(1, -40, 0, 46),
		BackgroundTransparency = 1,
		Parent = card,
	})
	claimPulseScale = new("UIScale", { Parent = claimHolder })
	new("Frame", {
		Name = "Shadow",
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(1, -4, 1, -4),
		BackgroundColor3 = INK,
		Parent = claimHolder,
	})
	claimButton = accent(new("TextButton", {
		Name = "Face",
		AutoButtonColor = false,
		Selectable = true,
		Text = "",
		Size = UDim2.new(1, -4, 1, -4),
		Parent = claimHolder,
	}), "BackgroundColor3")
	stroke(claimButton, 2)
	claimLabel = label({
		Text = "CLAIM",
		Font = FONT_NUM,
		TextSize = 20,
		TextColor3 = INK,
		Size = UDim2.fromScale(1, 1),
		Parent = claimButton,
	})
	claimButton.MouseButton1Down:Connect(function()
		claimButton.Position = UDim2.fromOffset(2, 2)
	end)
	claimButton.MouseButton1Up:Connect(function()
		claimButton.Position = UDim2.new()
	end)
	claimButton.MouseLeave:Connect(function()
		claimButton.Position = UDim2.new()
	end)
	claimButton.Activated:Connect(function()
		claimButton.Position = UDim2.new()
		task.spawn(claim)
	end)

	-- Small "no thanks" (a comfortable tap area, quiet text).
	noThanksButton = new("TextButton", {
		Name = "NoThanks",
		AutoButtonColor = false,
		Selectable = true,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 196),
		Size = UDim2.fromOffset(140, 26),
		Font = FONT_LABEL,
		Text = "NO THANKS",
		TextSize = 10,
		TextColor3 = GREY,
		Parent = card,
	})
	noThanksButton.Activated:Connect(function()
		if not busy then
			hide()
		end
	end)
	claimButton.NextSelectionDown = noThanksButton
	noThanksButton.NextSelectionUp = claimButton

	-- Error line (e.g. "COME BACK LATER") under the plate.
	statusLabel = label({
		Text = "",
		TextSize = 8,
		TextColor3 = GREY,
		Position = UDim2.fromOffset(0, 136),
		Size = UDim2.new(1, 0, 0, 10),
		Parent = card,
	})

	gui.Parent = player:WaitForChild("PlayerGui")
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
	refit()
end

-- Shows the gift now if everything allows it; otherwise keeps it waiting
-- (pending) only while it's still deserved.
local function tryShow()
	if not pending then
		return
	end
	if not isEligible() then
		pending = false
		return
	end
	if GuiService.MenuIsOpen then
		return -- never while the Roblox menu is up
	end
	if options.canShow and not options.canShow() then
		return -- mid-run: wait for the menu / game over screen
	end
	pending = false
	show()
end

-- Public -------------------------------------------------------------------------

-- Zone accent color (RunController's applyTheme).
function LeaveGift.setAccent(color)
	accentColor = color
	for instance, property in accentTargets do
		if instance.Parent then
			instance[property] = color
		else
			accentTargets[instance] = nil
		end
	end
end

-- opts.claim(): asks the server (Shop "ClaimLeaveGift"), returns ok, message.
-- opts.canShow(): false while a run is going.
local started = false
function LeaveGift.start(opts)
	if started then
		return
	end
	started = true
	options = opts or {}
	if not settings then
		return
	end
	buildGui()

	-- Opening the menu does nothing at all (leaving stays instant).
	GuiService.MenuOpened:Connect(function()
		menuWasOpened = true
	end)
	GuiService.MenuClosed:Connect(function()
		if not menuWasOpened then
			return
		end
		menuWasOpened = false
		if isEligible() then
			pending = true
			-- Next frame, so the menu has fully gone.
			task.defer(tryShow)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			if pending then
				tryShow()
			end
		end
	end)
end

return LeaveGift
