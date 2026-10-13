--[[
	All on-screen UI: menu, HUD, game over, toasts and damage effects.

	Look: "Glass Lab" technical annotation laid over the world. Paper panels,
	ink hairlines, sharp corners, hard offset shadows, and one accent color that
	follows the current zone theme (see setTheme). Red is reserved for damage
	and revive.

	Layout is drawn on a 600x340 reference sheet. Every block carries a UIScale
	that is refit whenever the screen changes size, so a 640x360 phone and a
	1080p monitor get the same composition (touch targets stay >= 44px on phones).
]]

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local player = Players.LocalPlayer

local UI = {}
UI.__index = UI

-- Look -----------------------------------------------------------------------
local PAPER = Color3.fromRGB(244, 241, 234)
local INK = Color3.fromRGB(17, 17, 17)
local GREY = Color3.fromRGB(112, 108, 100)
local DANGER = Color3.fromRGB(240, 38, 38)

local FONT_NUM = Enum.Font.Michroma -- numbers, titles, buttons
local FONT_LABEL = Enum.Font.RobotoMono -- small uppercase annotation

local REF_W, REF_H = 600, 340
local SCALE_MIN, SCALE_MAX = 0.8, 2
local HUD_SCALE = 0.85 -- HUD plates are drawn a bit smaller than menus
local SHADOW = 4 -- hard shadow offset behind buttons
local EDGE = 12 -- distance from the safe-area edge
local LOW_BALLS = 5
local TAB_H = 44
local FOOTER_H = 18

local ZONE_CARD_TIME = 1.6
local LEVEL_CARD_TIME = 2.4
local TOAST_TIME = 2
local MAX_TOASTS = 3

local TAB_NAMES = { "PLAY", "MISSIONS", "SEASON", "ZONES", "SHOP" }
local TAB_MISSIONS, TAB_SEASON = 2, 3
local GEM_PACKS = { "GemPack", "GemPackMedium", "GemPackLarge" }
-- The starter offer pops up once per session, the first time the menu opens
-- after a run (never on the very first screen, and never again once closed).
local OFFER_AFTER_MENU_OPENS = 2
local SUMMARY_TIMEOUT = 10 -- game over stops saying "TALLYING" after this
local SEASON_COLUMN_W = 56
local SEASON_COLUMN_GAP = 4
local PASS_ORDER = { "VIP", "Multiball", "Checkpoints" }
local PASS_INFO = {
	VIP = {
		code = "VIP",
		title = "VIP PASS",
		copy = string.format(
			"%dX GEMS + %d EXTRA BALLS EVERY RUN",
			Config.GamePasses.VIP.GemMultiplier or 2,
			Config.GamePasses.VIP.ExtraStartBalls or 0
		),
	},
	Multiball = { code = "x2", title = "MULTIBALL", copy = "NEVER DROP BELOW x2 MULTIBALL" },
	Checkpoints = { code = "CP", title = "CHECKPOINTS", copy = "START FROM ANY ZONE YOU'VE REACHED" },
}

local TOAST_KINDS = {
	multiball = { tag = "MULTIBALL", accent = true },
	reward = { tag = "REWARD", accent = true },
	level = { tag = "LEVEL UP", accent = true },
	info = { tag = "NOTE", accent = false },
	error = { tag = "ERROR", accent = false, hatch = true },
}

local rng = Random.new()

-- Shared registries (one UI per client) ---------------------------------------

local accentColor = Config.Themes[1].Accent
local accentTargets = {} -- instance -> property (pruned in setTheme once unparented)
local scalers = {} -- { uiScale, multiplier }
local textCaps = {} -- { constraint, label, max, min }
local currentScale = 1

-- Small helpers ----------------------------------------------------------------

local function tween(inst, time, props, style, direction)
	local t = TweenService:Create(
		inst,
		TweenInfo.new(time, style or Enum.EasingStyle.Quint, direction or Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

local function commas(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local sign, digits = string.match(s, "^(-?)(%d+)$")
	if not digits then
		return s
	end
	local out = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return sign .. out
end

local function twoDigits(n)
	return string.format("%02d", math.max(0, math.floor(tonumber(n) or 0)))
end

local function clock(seconds)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", seconds // 3600, (seconds % 3600) // 60, seconds % 60)
end

local function themeFor(zone)
	return Config.Themes[zone % #Config.Themes + 1]
end

local function ownedSkins()
	local owned = { Default = true, Classic = true }
	local raw = player:GetAttribute("OwnedSkins")
	if type(raw) == "string" then
		local ok, list = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and type(list) == "table" then
			for _, id in list do
				if type(id) == "string" then
					owned[id] = true
				end
			end
		end
	end
	return owned
end

local function hasPass(key)
	return player:GetAttribute("Pass_" .. key) == true
end

-- Progression data ------------------------------------------------------------------
-- The server mirrors progress to attributes (some as JSON). Any of them may be
-- missing before data loads, so every reader falls back to something safe.

local function decodeJson(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local ok, value = pcall(HttpService.JSONDecode, HttpService, raw)
	if ok then
		return value
	end
	return nil
end

local function attrNumber(name, default)
	local value = tonumber(player:GetAttribute(name))
	if value == nil or value ~= value then
		return default
	end
	return value
end

local function ownedFx()
	local owned = { Classic = true }
	local decoded = decodeJson(player:GetAttribute("OwnedFx"))
	if type(decoded) == "table" then
		for _, id in decoded do
			if type(id) == "string" then
				owned[id] = true
			end
		end
	end
	return owned
end

local function levelInfo()
	local level = math.max(1, math.floor(attrNumber("Level", 1)))
	local needed = math.max(1, math.floor(attrNumber("XPNeeded", Config.xpForLevel(level))))
	local xp = math.clamp(math.floor(attrNumber("XP", 0)), 0, needed)
	return level, xp, needed
end

local function skinName(id)
	local skin = Config.getSkin(id)
	return string.upper(if skin and skin.Id == id then skin.Name else tostring(id))
end

local function fxName(id)
	local fx = Config.getFx(id)
	return string.upper(if fx and fx.Id == id then fx.Name else tostring(id))
end

local function boostInfo(id)
	local boosts = Config.Boosts
	return if type(boosts) == "table" then boosts[id] else nil
end

local function boostName(id)
	local boost = boostInfo(id)
	return if boost and boost.Name then string.upper(boost.Name) else string.upper(tostring(id))
end

-- "+70 GEMS", "NEONITE SKIN", "SHATTERBORN SKIN + SUPERNOVA FX"...
local function rewardText(reward)
	if type(reward) ~= "table" then
		return ""
	end
	local parts = {}
	if reward.Gems then
		table.insert(parts, "+" .. commas(reward.Gems) .. " GEMS")
	end
	if reward.Skin then
		table.insert(parts, skinName(reward.Skin) .. " SKIN")
	end
	if reward.Fx then
		table.insert(parts, fxName(reward.Fx) .. " FX")
	end
	if reward.Boost then
		table.insert(parts, boostName(reward.Boost) .. " BOOST")
	end
	if reward.Balls then
		table.insert(parts, "+" .. commas(reward.Balls) .. " BALLS")
	end
	return table.concat(parts, " + ")
end

-- The first level unlock above `level`, or nil once they are all earned.
local function nextUnlock(level)
	local best = nil
	for unlockLevel, reward in Config.LevelUnlocks do
		if unlockLevel > level and (best == nil or unlockLevel < best) then
			best = unlockLevel
		end
	end
	return best, best and Config.LevelUnlocks[best]
end

-- "3D 04H", or hh:mm:ss under a day.
local function longClock(seconds)
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 86400 then
		return string.format("%dD %02dH", seconds // 86400, (seconds % 86400) // 3600)
	end
	return clock(seconds)
end

local function rainbowSequence()
	local keys = {}
	for i = 0, 6 do
		table.insert(keys, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 0.75, 1)))
	end
	return ColorSequence.new(keys)
end

-- Prices are fetched once per id and cached; waiters are called when it lands.
local priceCache = {}
local priceWaiters = {}

local function withPrice(id, infoType, onPrice)
	if not id or id == 0 then
		return
	end
	local key = tostring(infoType) .. ":" .. tostring(id)
	local cached = priceCache[key]
	if cached ~= nil then
		if cached then
			onPrice(cached)
		end
		return
	end
	if priceWaiters[key] then
		table.insert(priceWaiters[key], onPrice)
		return
	end
	priceWaiters[key] = { onPrice }
	task.spawn(function()
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, infoType)
		local price = ok and type(info) == "table" and info.PriceInRobux or false
		priceCache[key] = price
		local waiters = priceWaiters[key]
		priceWaiters[key] = nil
		if price then
			for _, waiter in waiters do
				task.spawn(waiter, price)
			end
		end
	end)
end

-- Builders -------------------------------------------------------------------------

-- Creates an instance. Non-button GuiObjects are never Active, so nothing but
-- real buttons can swallow a tap meant for throwing.
local function new(className, props, children)
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		inst.BorderSizePixel = 0
		if not inst:IsA("GuiButton") then
			inst.Active = false
		end
	end
	local parent = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			else
				(inst :: any)[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function text(props)
	local merged = {
		BackgroundTransparency = 1,
		Font = FONT_LABEL,
		TextColor3 = INK,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}
	for key, value in props do
		merged[key] = value
	end
	return new("TextLabel", merged)
end

local function setAccent(inst, prop)
	inst[prop] = accentColor
	accentTargets[inst] = prop
	return inst
end

local function clearAccent(inst)
	accentTargets[inst] = nil
end

local function fit(guiObject, multiplier)
	local s = new("UIScale", { Scale = currentScale * (multiplier or 1), Parent = guiObject })
	table.insert(scalers, { s, multiplier or 1 })
	return s
end

local function effectiveScale(inst)
	local s = 1
	local node = inst
	while node and not node:IsA("LayerCollector") do
		local scale = node:FindFirstChildOfClass("UIScale")
		if scale then
			s *= scale.Scale
		end
		node = node.Parent
	end
	return s
end

local function applyCap(entry)
	local constraint, label, max, min = entry[1], entry[2], entry[3], entry[4]
	if constraint.Parent == nil then
		return
	end
	constraint.MaxTextSize = math.clamp(math.floor(max * effectiveScale(label) + 0.5), min, 100)
end

-- TextScaled that stops at the designed size (scaled with the sheet), so text
-- only ever shrinks to fit and never balloons on big screens.
local function capText(label, max, min)
	label.TextScaled = true
	local constraint = new("UITextSizeConstraint", { MaxTextSize = max, MinTextSize = min or 7, Parent = label })
	local entry = { constraint, label, max, min or 7 }
	-- Menus rebuild rows often; drop entries for labels that were destroyed.
	if #textCaps > 200 then
		local alive = {}
		for _, existing in textCaps do
			if existing[1].Parent ~= nil then
				table.insert(alive, existing)
			end
		end
		textCaps = alive
	end
	table.insert(textCaps, entry)
	task.defer(applyCap, entry)
	return label
end

local function stroke(parent, thickness, color, transparency)
	return new("UIStroke", {
		Thickness = thickness or 1,
		Color = color or INK,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Miter,
		Parent = parent,
	})
end

local function rule(parent, props)
	local merged = { BackgroundColor3 = INK, Size = UDim2.new(1, 0, 0, 1) }
	for key, value in props do
		merged[key] = value
	end
	merged.Parent = parent
	return new("Frame", merged)
end

-- Registration ticks just outside each corner, like print crop marks.
local function cropMarks(parent, len, gap, transparency)
	for _, corner in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
		local sx, sy = corner[1], corner[2]
		local dx, dy = sx * 2 - 1, sy * 2 - 1
		rule(parent, {
			Name = "Crop",
			BackgroundTransparency = transparency or 0,
			AnchorPoint = Vector2.new(1 - sx, 0.5),
			Position = UDim2.new(sx, dx * gap, sy, 0),
			Size = UDim2.fromOffset(len, 1),
		})
		rule(parent, {
			Name = "Crop",
			BackgroundTransparency = transparency or 0,
			AnchorPoint = Vector2.new(0.5, 1 - sy),
			Position = UDim2.new(sx, 0, sy, dy * gap),
			Size = UDim2.fromOffset(1, len),
		})
	end
end

-- L-shaped viewfinder brackets inside each corner.
local function brackets(parent, len, thickness, transparency)
	for _, corner in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
		local anchor = Vector2.new(corner[1], corner[2])
		local position = UDim2.fromScale(corner[1], corner[2])
		for _, size in { UDim2.fromOffset(len, thickness), UDim2.fromOffset(thickness, len) } do
			rule(parent, {
				Name = "Bracket",
				BackgroundTransparency = transparency or 0,
				AnchorPoint = anchor,
				Position = position,
				Size = size,
			})
		end
	end
end

-- A solid triangle filling one corner (cx, cy in {0, 1}): the chamfered/cut-corner mark.
-- Built from a square with a hard-stepped diagonal gradient, so it needs no image.
local function notch(parent, size, cx, cy, color)
	local frame = new("Frame", {
		Name = "Notch",
		AnchorPoint = Vector2.new(cx, cy),
		Position = UDim2.fromScale(cx, cy),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = color or INK,
		Parent = parent,
	})
	if color == nil then
		setAccent(frame, "BackgroundColor3")
	end
	new("UIGradient", {
		Rotation = math.deg(math.atan2(cy * 2 - 1, cx * 2 - 1)),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.499, 1),
			NumberSequenceKeypoint.new(0.501, 0),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Parent = frame,
	})
	return frame
end

-- Diagonal hazard hatching from a striped transparency gradient.
local function hatch(parent, props, color, transparency, stripes)
	local frame = new("Frame", props)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency or 0
	frame.Parent = parent
	local keys = {}
	local count = stripes or 4
	local e = 0.001
	for i = 0, count - 1 do
		local a = i / count
		local m = a + 0.5 / count
		table.insert(keys, NumberSequenceKeypoint.new(a, 0))
		table.insert(keys, NumberSequenceKeypoint.new(m - e, 0))
		table.insert(keys, NumberSequenceKeypoint.new(m, 1))
		table.insert(keys, NumberSequenceKeypoint.new((i + 1) / count - e, 1))
	end
	table.insert(keys, NumberSequenceKeypoint.new(1, 0))
	new("UIGradient", { Rotation = 60, Transparency = NumberSequence.new(keys), Parent = frame })
	return frame
end

-- The gem mark: an accent diamond with an ink outline.
local function gemIcon(parent, size, position)
	local diamond = new("Frame", {
		Name = "Gem",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = UDim2.fromOffset(size, size),
		Rotation = 45,
		Parent = parent,
	})
	setAccent(diamond, "BackgroundColor3")
	stroke(diamond, 1)
	return diamond
end

local function blueprintGrid(parent, columns, rows, transparency)
	local grid = new("Frame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = parent })
	for i = 1, columns - 1 do
		rule(grid, { BackgroundTransparency = transparency, Position = UDim2.fromScale(i / columns, 0), Size = UDim2.new(0, 1, 1, 0) })
	end
	for i = 1, rows - 1 do
		rule(grid, { BackgroundTransparency = transparency, Position = UDim2.fromScale(0, i / rows), Size = UDim2.new(1, 0, 0, 1) })
	end
	return grid
end

-- A full-bleed frame that also covers the notch / home-bar areas outside the safe insets.
local function bleed(parent, props)
	local merged = { Position = UDim2.fromOffset(-200, -200), Size = UDim2.new(1, 400, 1, 400) }
	for key, value in props do
		merged[key] = value
	end
	merged.Parent = parent
	return new("Frame", merged)
end

-- Ruler strip: ticks every `spacing` px, taller every `major` ticks.
local function rulerTicks(parent, width, height, spacing, major, transparency)
	local count = math.floor(width / spacing)
	for i = 0, count do
		local isMajor = i % major == 0
		rule(parent, {
			BackgroundTransparency = transparency or 0,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, i * spacing, 1, 0),
			Size = UDim2.fromOffset(1, if isMajor then height else math.floor(height * 0.45)),
		})
	end
end

local FILLS = {
	accent = { text = INK },
	paper = { bg = PAPER, text = INK },
	ink = { bg = INK, text = PAPER },
	danger = { bg = DANGER, text = PAPER },
}

--[[
	Poster-style button: a face with a 2px ink outline sitting on a solid ink
	block offset by SHADOW px. It presses down 2px while held.
	opts: Name, Size, Position, AnchorPoint, LayoutOrder, Fill, Text, TextSize,
	Align, Index (small label top-left), Sub (small second line), OnClick
]]
local function hardButton(parent, opts)
	local holder = new("Frame", {
		Name = opts.Name or "Button",
		BackgroundTransparency = 1,
		Size = opts.Size,
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
		Parent = parent,
	})
	local shadow = new("Frame", {
		Name = "Shadow",
		BackgroundColor3 = INK,
		Position = UDim2.fromOffset(SHADOW, SHADOW),
		Size = UDim2.new(1, -SHADOW, 1, -SHADOW),
		Parent = holder,
	})
	local face = new("TextButton", {
		Name = "Face",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = PAPER,
		Size = UDim2.new(1, -SHADOW, 1, -SHADOW),
		Parent = holder,
	})
	stroke(face, 2)

	local align = opts.Align or Enum.TextXAlignment.Center
	local top = if opts.Index then 11 else 0
	local split = if opts.Sub then 0.6 else 1

	local index = nil
	if opts.Index then
		index = text({
			Name = "Index",
			Text = opts.Index,
			TextSize = 8,
			Position = UDim2.fromOffset(8, 4),
			Size = UDim2.new(1, -16, 0, 9),
			Parent = face,
		})
	end
	local label = text({
		Name = "Label",
		Font = FONT_NUM,
		Text = opts.Text or "",
		TextXAlignment = align,
		TextYAlignment = if opts.Sub then Enum.TextYAlignment.Bottom else Enum.TextYAlignment.Center,
		Position = UDim2.new(0, 8, 0, top),
		Size = UDim2.new(1, -16, split, -top),
		Parent = face,
	})
	capText(label, opts.TextSize or 13, 7)
	local sub = nil
	if opts.Sub then
		sub = text({
			Name = "Sub",
			Text = opts.Sub,
			TextSize = 9,
			TextXAlignment = align,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.new(0, 8, split, 1),
			Size = UDim2.new(1, -16, 1 - split, -2),
			Parent = face,
		})
	end

	local button = { holder = holder, face = face, label = label, sub = sub, index = index, enabled = true }

	function button.setFill(kind)
		local fill = FILLS[kind] or FILLS.paper
		if kind == "accent" then
			setAccent(face, "BackgroundColor3")
		else
			clearAccent(face)
			face.BackgroundColor3 = fill.bg
		end
		label.TextColor3 = fill.text
		if sub then
			sub.TextColor3 = fill.text
		end
		if index then
			index.TextColor3 = fill.text
		end
	end

	function button.setEnabled(enabled)
		button.enabled = enabled
		shadow.Visible = enabled
		face.Position = if enabled then UDim2.new() else UDim2.fromOffset(2, 2)
		label.TextTransparency = if enabled then 0 else 0.35
	end

	function button.setText(value)
		label.Text = value
	end

	local function release()
		if button.enabled then
			tween(face, 0.18, { Position = UDim2.new() }, Enum.EasingStyle.Back)
		end
	end

	face.MouseButton1Down:Connect(function()
		if button.enabled then
			tween(face, 0.06, { Position = UDim2.fromOffset(2, 2) })
		end
	end)
	face.MouseButton1Up:Connect(release)
	face.MouseLeave:Connect(release)
	face.Activated:Connect(function()
		release()
		if button.enabled and opts.OnClick then
			opts.OnClick()
		end
	end)

	button.setFill(opts.Fill or "paper")
	return button
end

local function sectionHeader(parent, order, index, title)
	local row = new("Frame", {
		Name = title,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = order,
		Parent = parent,
	})
	text({ Text = index .. "  " .. title, TextSize = 10, Size = UDim2.new(0.6, 0, 1, -3), Parent = row })
	local right = text({
		Text = "",
		TextSize = 9,
		TextColor3 = GREY,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.35, 0),
		Size = UDim2.new(0.65, 0, 1, -3),
		Parent = row,
	})
	rule(row, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) })
	local tick = new("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromOffset(18, 3),
		Parent = row,
	})
	setAccent(tick, "BackgroundColor3")
	return row, right
end

local function list(parent, padding)
	return new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding or 0),
		Parent = parent,
	})
end

local function clearRows(container)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- Thin measurement bar: faint ink track with an accent fill (0..1).
local function meter(parent, props, height)
	local merged = { BackgroundColor3 = INK, BackgroundTransparency = 0.82, Size = UDim2.new(1, 0, 0, height or 4) }
	for key, value in props do
		merged[key] = value
	end
	merged.Parent = parent
	local track = new("Frame", merged)
	local fill = new("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), Parent = track })
	setAccent(fill, "BackgroundColor3")
	return track, fill
end

-- Rubber stamp: outlined slab with double rules, like NEW BEST on the run report.
local function stamp(parent, label, props, fill)
	local merged = { Name = "Stamp", AnchorPoint = Vector2.new(0.5, 0.5), Rotation = -8 }
	for key, value in props do
		merged[key] = value
	end
	merged.Parent = parent
	local frame = new("Frame", merged)
	if fill == "accent" then
		setAccent(frame, "BackgroundColor3")
	else
		frame.BackgroundColor3 = PAPER
		frame.BackgroundTransparency = if fill == "clear" then 1 else 0
	end
	stroke(frame, 1.5)
	rule(frame, { Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 0, 1) })
	rule(frame, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 3, 1, -3), Size = UDim2.new(1, -6, 0, 1) })
	local textLabel = capText(text({
		Name = "Label",
		Text = label,
		Font = FONT_NUM,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.new(1, -8, 1, 0),
		Parent = frame,
	}), 11, 6)
	return frame, textLabel
end

-- Small ink tag with paper (or accent) text: "LOCKED", "BEST VALUE"...
local function tag(parent, label, props, accentText)
	local merged = { Name = "Tag", BackgroundColor3 = INK }
	for key, value in props do
		merged[key] = value
	end
	merged.Parent = parent
	local frame = new("Frame", merged)
	local textLabel = text({
		Text = label,
		TextSize = 8,
		TextColor3 = PAPER,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})
	if accentText then
		setAccent(textLabel, "TextColor3")
	end
	return frame, textLabel
end

-- One triangular glass shard (hard-stepped diagonal gradient, no image).
local function shard(parent, x, y, size, rotation, color)
	local frame = new("Frame", {
		Name = "Shard",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(x, y),
		Size = UDim2.fromOffset(size, size),
		Rotation = rotation,
		BackgroundColor3 = color,
		Parent = parent,
	})
	new("UIGradient", {
		Rotation = 45,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.499, 0),
			NumberSequenceKeypoint.new(0.501, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = frame,
	})
	return frame
end

local SHARD_LAYOUT = {
	{ 0.5, 0.52, 16, 10 },
	{ 0.3, 0.32, 11, 70 },
	{ 0.7, 0.3, 10, -40 },
	{ 0.24, 0.72, 9, 150 },
	{ 0.76, 0.7, 12, 200 },
	{ 0.52, 0.16, 7, 120 },
	{ 0.12, 0.46, 6, 30 },
	{ 0.88, 0.48, 7, -110 },
	{ 0.5, 0.88, 7, 260 },
}

-- Ink sample plate showing shards in an effect's color.
local function fxSwatch(parent, fx, props, scale)
	local merged = { Name = "Swatch", BackgroundColor3 = INK }
	for key, value in props do
		merged[key] = value
	end
	merged.Parent = parent
	local plate = new("Frame", merged)
	plate.ClipsDescendants = true
	scale = scale or 1
	for i, spec in SHARD_LAYOUT do
		local color = fx.Color or Config.GLASS_COLOR
		if fx.Rainbow then
			color = Color3.fromHSV((i - 1) / #SHARD_LAYOUT, 0.7, 1)
		end
		shard(plate, spec[1], spec[2], math.floor(spec[3] * scale + 0.5), spec[4], color)
	end
	if fx.Sparkle then
		for _, spot in { { 0.38, 0.5 }, { 0.62, 0.42 }, { 0.42, 0.22 }, { 0.66, 0.8 }, { 0.2, 0.2 } } do
			new("Frame", {
				BackgroundColor3 = PAPER,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(spot[1], spot[2]),
				Size = UDim2.fromOffset(2, 2),
				Parent = plate,
			})
		end
	end
	return plate
end

-- Tiny color sample for a reward (skin color, fx color, or the gem mark).
local function rewardChip(parent, reward, size, position)
	if type(reward) ~= "table" then
		return nil
	end
	if reward.Skin or reward.Fx then
		local item = if reward.Skin then Config.getSkin(reward.Skin) else Config.getFx(reward.Fx)
		local chip = new("Frame", {
			Name = "Chip",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = position,
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = item.Color or Config.GLASS_COLOR,
			Parent = parent,
		})
		stroke(chip, 1)
		if item.Rainbow then
			new("UIGradient", { Color = rainbowSequence(), Rotation = 20, Parent = chip })
		end
		if reward.Fx and not reward.Skin then
			chip.Rotation = 45 -- effects read as diamonds, skins as squares
		end
		return chip
	end
	if reward.Boost then
		local boost = boostInfo(reward.Boost)
		local chip = new("Frame", {
			Name = "Chip",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = position,
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = boost and boost.Color or INK,
			Parent = parent,
		})
		stroke(chip, 1)
		-- Boosts read as a square with an ink bar through it (a "capsule" mark).
		rule(chip, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 1) })
		return chip
	end
	return gemIcon(parent, math.floor(size * 0.8), position)
end

-- Menu ---------------------------------------------------------------------------------

function UI._buildMenu(self)
	local m = {}
	self._menu = m

	local root = new("Frame", { Name = "Menu", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = self.gui })
	m.root = root

	-- Paper wash on the left so the logotype reads; the corridor stays visible on the right.
	local wash = bleed(root, { Name = "Wash", BackgroundColor3 = PAPER })
	new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(0.32, 0.2),
			NumberSequenceKeypoint.new(0.58, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = wash,
	})
	blueprintGrid(root, 12, 8, 0.93)

	-- Vanishing-point crosshair over the track preview.
	local cross = new("Frame", {
		Name = "Crosshair",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(22, 22),
		Parent = root,
	})
	fit(cross)
	rule(cross, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundTransparency = 0.3 })
	rule(cross, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0, 1, 1, 0), BackgroundTransparency = 0.3 })
	text({ Text = "VP / 0 M", TextSize = 8, Position = UDim2.fromOffset(14, 13), Size = UDim2.fromOffset(60, 10), TextTransparency = 0.3, Parent = cross })

	self:_buildMenuLeft(root)
	self:_buildMenuPanel(root)
	self:_buildModal(root)
end

function UI._buildMenuLeft(self, root)
	local m = self._menu
	local left = new("Frame", {
		Name = "Left",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, EDGE + 4, 0.5, 0),
		Size = UDim2.fromOffset(256, 300),
		Parent = root,
	})
	fit(left)
	m.left = left

	-- Index line
	local chip = new("Frame", { Position = UDim2.fromOffset(0, 3), Size = UDim2.fromOffset(6, 6), Parent = left })
	setAccent(chip, "BackgroundColor3")
	text({ Text = "SR-01 / GLASS LAB / FIELD TEST", TextSize = 8, Position = UDim2.fromOffset(12, 0), Size = UDim2.fromOffset(244, 12), Parent = left })

	-- Logotype: SHATTER is split along a crack, the right shard knocked out of
	-- register, with an accent misprint behind it. RUN sits in a solid ink block.
	local logo = new("Frame", { Name = "Logo", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 16), Size = UDim2.fromOffset(256, 50), Parent = left })
	local function word(parent, props)
		local merged = { Text = "SHATTER", Font = FONT_NUM, TextYAlignment = Enum.TextYAlignment.Center }
		for key, value in props do
			merged[key] = value
		end
		merged.Parent = parent
		return capText(text(merged), 46, 20)
	end
	local ghost = word(logo, { Position = UDim2.fromOffset(3, 3), Size = UDim2.fromScale(1, 1) })
	setAccent(ghost, "TextColor3")
	local SPLIT = 0.57
	local leftShard = new("Frame", { BackgroundTransparency = 1, ClipsDescendants = true, Size = UDim2.fromScale(SPLIT, 1), Parent = logo })
	word(leftShard, { Size = UDim2.fromScale(1 / SPLIT, 1) })
	local rightShard = new("Frame", {
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.new(SPLIT, 2, 0, 3),
		Size = UDim2.fromScale(1 - SPLIT, 1),
		Parent = logo,
	})
	word(rightShard, { Position = UDim2.fromScale(-SPLIT / (1 - SPLIT), 0), Size = UDim2.fromScale(1 / (1 - SPLIT), 1) })
	new("Frame", {
		Name = "Crack",
		BackgroundColor3 = PAPER,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(SPLIT, 1, 0.5, 0),
		Size = UDim2.fromOffset(3, 62),
		Rotation = 16,
		Parent = logo,
	})
	rule(logo, {
		Name = "CrackLine",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(SPLIT, 5, 0.5, 6),
		Size = UDim2.fromOffset(1, 78),
		Rotation = 16,
	})

	local runBlock = new("Frame", { Name = "Run", BackgroundColor3 = INK, Position = UDim2.fromOffset(0, 70), Size = UDim2.fromOffset(112, 40), Parent = left })
	capText(text({ Text = "RUN", Font = FONT_NUM, TextColor3 = PAPER, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = runBlock }), 28, 12)
	notch(runBlock, 10, 1, 0)
	text({
		Text = "GLIDE.\nTHROW.\nSHATTER.",
		TextSize = 9,
		LineHeight = 1.05,
		TextYAlignment = Enum.TextYAlignment.Center,
		Position = UDim2.fromOffset(122, 70),
		Size = UDim2.fromOffset(134, 40),
		Parent = left,
	})

	-- Stats strip
	-- Stats strip: BEST | GEMS | LEVEL badge, with the XP bar along the bottom edge.
	local stats = new("Frame", { Name = "Stats", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 120), Size = UDim2.fromOffset(256, 46), Parent = left })
	rule(stats, {})
	rule(stats, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) })
	rule(stats, { Position = UDim2.fromOffset(92, 8), Size = UDim2.new(0, 1, 1, -18) })
	rule(stats, { Position = UDim2.fromOffset(176, 8), Size = UDim2.new(0, 1, 1, -18) })
	text({ Text = "BEST / M", TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(0, 5), Size = UDim2.fromOffset(88, 10), Parent = stats })
	m.best = capText(text({ Text = "0", Font = FONT_NUM, Position = UDim2.fromOffset(0, 17), Size = UDim2.fromOffset(88, 22), Parent = stats }), 16, 8)
	gemIcon(stats, 7, UDim2.fromOffset(104, 10))
	text({ Text = "GEMS", TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(114, 5), Size = UDim2.fromOffset(60, 10), Parent = stats })
	m.gems = capText(text({ Text = "0", Font = FONT_NUM, Position = UDim2.fromOffset(100, 17), Size = UDim2.fromOffset(72, 22), Parent = stats }), 16, 8)

	local badge = new("Frame", { Name = "Level", BackgroundColor3 = INK, Position = UDim2.fromOffset(184, 6), Size = UDim2.fromOffset(72, 32), Parent = stats })
	notch(badge, 8, 1, 0)
	text({ Text = "LEVEL", TextSize = 7, TextColor3 = PAPER, TextTransparency = 0.35, Position = UDim2.fromOffset(6, 2), Size = UDim2.fromOffset(50, 9), Parent = badge })
	m.level = capText(text({ Text = "LV 01", Font = FONT_NUM, TextColor3 = PAPER, Position = UDim2.fromOffset(6, 11), Size = UDim2.fromOffset(62, 18), Parent = badge }), 13, 7)
	m.levelBump = new("UIScale", { Parent = badge })
	local _, xpFill = meter(stats, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -1) }, 3)
	m.xpFill = xpFill
	m.xpNote = text({
		Text = "",
		TextSize = 7,
		TextColor3 = GREY,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(0, 167),
		Size = UDim2.fromOffset(256, 9),
		Parent = left,
	})

	-- PLAY
	local play = hardButton(left, {
		Name = "Play",
		Fill = "accent",
		Text = "PLAY",
		TextSize = 26,
		Align = Enum.TextXAlignment.Left,
		Index = "A / START RUN / 0 M",
		Position = UDim2.fromOffset(0, 178),
		Size = UDim2.fromOffset(256, 66),
		OnClick = function()
			self:_fire("onPlay", 0)
		end,
	})
	hatch(play.face, { Name = "Hatch", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.new(0, 46, 1, -16) }, INK, 0, 4)
	m.play = play

	-- DAILY: opens the 7-day streak sheet. The pips on the right show the streak at a glance.
	local daily = hardButton(left, {
		Name = "Daily",
		Fill = "paper",
		Text = "--:--:--",
		TextSize = 13,
		Align = Enum.TextXAlignment.Left,
		Index = "B / DAILY",
		Position = UDim2.fromOffset(0, 252),
		Size = UDim2.fromOffset(256, 48),
		OnClick = function()
			self:_openDaily()
		end,
	})
	daily.label.Size = UDim2.new(1, -104, 1, -11)
	local pipRow = new("Frame", {
		Name = "Streak",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 4),
		Size = UDim2.fromOffset(#Config.DailyStreak * 12 - 2, 12),
		Parent = daily.face,
	})
	m.dailyPips = {}
	for day = 1, #Config.DailyStreak do
		local isBig = day == #Config.DailyStreak
		local pip = new("Frame", {
			Name = "Day" .. day,
			BackgroundColor3 = INK,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset((day - 1) * 12 + 5, 6),
			Size = if isBig then UDim2.fromOffset(9, 9) else UDim2.fromOffset(8, 8),
			Rotation = if isBig then 45 else 0,
			Parent = pipRow,
		})
		local pipStroke = stroke(pip, 1)
		m.dailyPips[day] = { frame = pip, stroke = pipStroke }
	end
	m.daily = daily
end

function UI._buildMenuPanel(self, root)
	local m = self._menu
	local panel = new("Frame", {
		Name = "Panel",
		BackgroundColor3 = PAPER,
		BackgroundTransparency = 0.03,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -(EDGE + 4), 0.5, 0),
		Size = UDim2.fromOffset(290, 300),
		Parent = root,
	})
	fit(panel)
	stroke(panel, 1.5)
	cropMarks(panel, 8, 4)
	notch(panel, 14, 1, 1)
	m.panel = panel

	-- Tabs
	m.tabs = {}
	local names = TAB_NAMES
	for i, name in names do
		local button = new("TextButton", {
			Name = "Tab" .. name,
			AutoButtonColor = false,
			Text = "",
			BackgroundColor3 = INK,
			BackgroundTransparency = 1,
			Position = UDim2.new((i - 1) / #names, 0, 0, 0),
			Size = UDim2.new(1 / #names, 0, 0, TAB_H),
			Parent = panel,
		})
		local index = text({ Text = twoDigits(i), TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(5, 5), Size = UDim2.fromOffset(30, 9), Parent = button })
		local label = capText(text({
			Text = name,
			Font = FONT_NUM,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(3, 16),
			Size = UDim2.new(1, -6, 0, 20),
			Parent = button,
		}), 11, 5)
		local bar = new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 3), Visible = false, Parent = button })
		setAccent(bar, "BackgroundColor3")
		-- "Something to claim here" marker.
		local pip = new("Frame", {
			Name = "Pip",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 6),
			Size = UDim2.fromOffset(7, 7),
			Rotation = 45,
			Visible = false,
			Parent = button,
		})
		setAccent(pip, "BackgroundColor3")
		stroke(pip, 1)
		if i > 1 then
			rule(button, { Size = UDim2.new(0, 1, 1, 0), BackgroundTransparency = 0.6 })
		end
		local page = new("ScrollingFrame", {
			Name = name .. "Page",
			Active = true,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, TAB_H + 1),
			Size = UDim2.new(1, 0, 1, -(TAB_H + 1 + FOOTER_H)),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = INK,
			VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
			Visible = false,
			Parent = panel,
		})
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 9),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 10),
			Parent = page,
		})
		list(page, 6)
		button.Activated:Connect(function()
			self:_selectTab(i)
		end)
		m.tabs[i] = { button = button, index = index, label = label, bar = bar, pip = pip, page = page, name = name }
	end
	rule(panel, { Position = UDim2.fromOffset(0, TAB_H) })

	-- Footer
	local footer = new("Frame", { Name = "Footer", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, FOOTER_H), Parent = panel })
	rule(footer, { BackgroundTransparency = 0.5 })
	m.footer = text({ Text = "SHEET 01 / " .. twoDigits(#names), TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(9, 1), Size = UDim2.new(0.5, -9, 1, -1), Parent = footer })
	text({
		Text = "SHATTER RUN / SPEC",
		TextSize = 8,
		TextColor3 = GREY,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0.5, 0, 0, 1),
		Size = UDim2.new(0.5, -22, 1, -1),
		Parent = footer,
	})

	-- 01 PLAY: global top runs + upgrades
	local playPage = m.tabs[1].page
	local _, runsRight = sectionHeader(playPage, 1, "01.1", "TOP RUNS")
	runsRight.Text = "GLOBAL / TOP 10"
	m.runs = new("Frame", { Name = "Runs", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = playPage })
	list(m.runs, 0)
	m.passHeader = sectionHeader(playPage, 3, "01.2", "UPGRADES")
	m.passes = new("Frame", { Name = "Passes", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Parent = playPage })
	list(m.passes, 8)

	-- 02 MISSIONS
	self:_buildMissionsPage(m.tabs[TAB_MISSIONS].page)

	-- 03 SEASON
	self:_buildSeasonPage(m.tabs[TAB_SEASON].page)

	-- 04 ZONES
	local zonesPage = m.tabs[4].page
	local _, zonesRight = sectionHeader(zonesPage, 1, "04.1", "ZONES")
	m.zonesRight = zonesRight
	m.zones = new("Frame", { Name = "Zones", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = zonesPage })
	list(m.zones, 0)

	-- 05 SHOP
	local shopPage = m.tabs[5].page
	local starter = Config.Products.StarterPack
	if starter and starter.Id ~= 0 then
		m.starterHeader = sectionHeader(shopPage, 1, "05.0", "STARTER PACK")
		m.starterCard = self:_buildStarterCard(shopPage, 2)
	end
	local _, gemsRight = sectionHeader(shopPage, 3, "05.1", "GEMS")
	m.shopGems = gemsRight
	for i, key in GEM_PACKS do
		local product = Config.Products[key]
		if product and product.Id ~= 0 then
			self:_buildGemPack(shopPage, 3 + i, key)
		end
	end
	local _, skinsRight = sectionHeader(shopPage, 10, "05.2", "BALL SKINS")
	m.skinsRight = skinsRight
	local grid = new("Frame", { Name = "Skins", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 11, Parent = shopPage })
	new("UIGridLayout", {
		CellSize = UDim2.new(0.5, -4, 0, 160),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	m.skinCards = {}
	for order, skin in Config.Skins do
		m.skinCards[skin.Id] = self:_buildSkinCard(grid, skin, order)
	end

	local _, fxRight = sectionHeader(shopPage, 12, "05.3", "SHATTER FX")
	m.fxRight = fxRight
	text({
		Text = "THE COLOR YOUR GLASS SHARDS TURN WHEN YOU BREAK THEM",
		TextSize = 8,
		TextColor3 = GREY,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 12),
		LayoutOrder = 13,
		Parent = shopPage,
	})
	local fxGrid = new("Frame", { Name = "Fx", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 14, Parent = shopPage })
	new("UIGridLayout", {
		CellSize = UDim2.new(0.5, -4, 0, 140),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = fxGrid,
	})
	m.fxCards = {}
	for order, fx in Config.ShatterFx do
		m.fxCards[fx.Id] = self:_buildFxCard(fxGrid, fx, order)
	end
end

function UI._buildGemPack(self, parent, order, key)
	key = key or "GemPack"
	local product = Config.Products[key]
	local card = new("Frame", { Name = key, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 60), LayoutOrder = order, Parent = parent })
	stroke(card, 1, INK, if product.Badge then 0 else 0.5)
	notch(card, 10, 0, 0)
	if product.Badge then
		stamp(card, string.upper(product.Badge), {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -92, 0, 1),
			Size = UDim2.fromOffset(78, 17),
			Rotation = -4,
		}, "accent")
	end
	gemIcon(card, 20, UDim2.fromOffset(28, 30))
	capText(text({
		Text = "+" .. commas(product.Gems) .. " GEMS",
		Font = FONT_NUM,
		Position = UDim2.fromOffset(52, 12),
		Size = UDim2.new(1, -140, 0, 20),
		Parent = card,
	}), 14, 8)
	text({ Text = "GEM PACK / INSTANT", TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(52, 34), Size = UDim2.new(1, -140, 0, 10), Parent = card })
	local buy = hardButton(card, {
		Name = "Buy",
		Fill = "accent",
		Text = "BUY",
		TextSize = 12,
		Sub = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(78, 50),
		OnClick = function()
			self:_fire("onBuyProduct", key)
		end,
	})
	withPrice(product.Id, Enum.InfoType.Product, function(price)
		buy.sub.Text = "R$ " .. commas(price)
	end)
end

-- What the starter pack contains, as three annotated lines.
local function starterLines(product)
	local lines = {}
	if product.Gems then
		table.insert(lines, { reward = { Gems = product.Gems }, text = "+" .. commas(product.Gems) .. " GEMS" })
	end
	if product.Skin then
		table.insert(lines, { reward = { Skin = product.Skin }, text = skinName(product.Skin) .. " BALL SKIN" })
	end
	if product.Fx then
		table.insert(lines, { reward = { Fx = product.Fx }, text = fxName(product.Fx) .. " SHATTER FX" })
	end
	return lines
end

-- Shop card for the one-time starter pack. Hidden once bought.
function UI._buildStarterCard(self, parent, order)
	local product = Config.Products.StarterPack
	local card = new("Frame", { Name = "StarterPack", BackgroundColor3 = INK, Size = UDim2.new(1, 0, 0, 92), LayoutOrder = order, Parent = parent })
	notch(card, 12, 1, 0)
	setAccent(text({ Text = "ONE-TIME PACK / NEW PLAYERS", TextSize = 8, Position = UDim2.fromOffset(10, 5), Size = UDim2.new(1, -110, 0, 10), Parent = card }), "TextColor3")
	for i, line in starterLines(product) do
		local y = 22 + (i - 1) * 22
		rewardChip(card, line.reward, 10, UDim2.fromOffset(16, y + 8))
		capText(text({ Text = line.text, Font = FONT_NUM, TextColor3 = PAPER, Position = UDim2.fromOffset(28, y), Size = UDim2.new(1, -124, 0, 16), Parent = card }), 10, 6)
	end
	local buy = hardButton(card, {
		Name = "Buy",
		Fill = "accent",
		Text = "BUY",
		TextSize = 12,
		Sub = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 4),
		Size = UDim2.fromOffset(84, 56),
		OnClick = function()
			self:_fire("onBuyProduct", "StarterPack")
		end,
	})
	withPrice(product.Id, Enum.InfoType.Product, function(price)
		if buy.sub.Parent then
			buy.sub.Text = "R$ " .. commas(price)
		end
	end)
	return card
end

-- Shop card for a shatter effect: same anatomy as the ball skin cards.
function UI._buildFxCard(self, parent, fx, order)
	local card = new("Frame", { Name = fx.Id, BackgroundTransparency = 1, LayoutOrder = order, Parent = parent })
	local outline = stroke(card, 1, INK, 0.5)
	local swatch = fxSwatch(card, fx, { Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 0, 42) })
	text({ Text = "FX-" .. twoDigits(order), TextSize = 8, TextColor3 = PAPER, Position = UDim2.fromOffset(4, 2), Size = UDim2.fromOffset(40, 10), Parent = swatch })
	local finish = if fx.Rainbow then "PRISM" elseif fx.Neon then "NEON" elseif fx.Metal then "METAL" elseif fx.Sparkle then "SPARKLE" else "GLASS"
	text({
		Text = finish,
		TextSize = 8,
		TextColor3 = PAPER,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -64, 0, 2),
		Size = UDim2.fromOffset(60, 10),
		Parent = swatch,
	})
	capText(text({ Text = string.upper(fx.Name), Font = FONT_NUM, Position = UDim2.fromOffset(6, 53), Size = UDim2.new(1, -12, 0, 16), Parent = card }), 12, 7)
	local price = text({
		Text = if fx.Price > 0 then commas(fx.Price) .. " GEMS" else "STANDARD ISSUE",
		TextSize = 9,
		TextColor3 = GREY,
		Position = UDim2.fromOffset(6, 70),
		Size = UDim2.new(1, -12, 0, 12),
		Parent = card,
	})
	local entry = { fx = fx, outline = outline, price = price, busy = false }
	entry.button = hardButton(card, {
		Name = "Action",
		Fill = "ink",
		Text = "BUY",
		TextSize = 11,
		Position = UDim2.fromOffset(6, 86),
		Size = UDim2.new(1, -12, 0, 48),
		OnClick = function()
			self:_fxAction(entry)
		end,
	})
	return entry
end

function UI._buildSkinCard(self, parent, skin, order)
	local card = new("Frame", { Name = skin.Id, BackgroundTransparency = 1, LayoutOrder = order, Parent = parent })
	local outline = stroke(card, 1, INK, 0.5)

	local swatch = new("Frame", { Name = "Swatch", BackgroundColor3 = skin.Color, Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 0, 58), Parent = card })
	stroke(swatch, 1)
	if skin.Rainbow then
		local keys = {}
		for i = 0, 6 do
			table.insert(keys, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 0.75, 1)))
		end
		new("UIGradient", { Color = ColorSequence.new(keys), Rotation = 20, Parent = swatch })
	end
	if skin.Trail then
		new("Frame", { Name = "Trail", BackgroundColor3 = skin.Trail, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 6), Parent = swatch })
	end
	-- Sample crosshair
	local dark = (skin.Color.R + skin.Color.G + skin.Color.B) < 1.2
	local markColor = if dark then PAPER else INK
	rule(swatch, { BackgroundColor3 = markColor, BackgroundTransparency = 0.55, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(14, 1) })
	rule(swatch, { BackgroundColor3 = markColor, BackgroundTransparency = 0.55, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(1, 14) })
	text({ Text = "S-" .. twoDigits(order), TextSize = 8, TextColor3 = markColor, Position = UDim2.fromOffset(4, 2), Size = UDim2.fromOffset(40, 10), Parent = swatch })
	text({
		Text = string.upper(skin.Material.Name),
		TextSize = 8,
		TextColor3 = markColor,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -64, 0, 2),
		Size = UDim2.fromOffset(60, 10),
		Parent = swatch,
	})

	capText(text({ Text = string.upper(skin.Name), Font = FONT_NUM, Position = UDim2.fromOffset(6, 70), Size = UDim2.new(1, -12, 0, 16), Parent = card }), 12, 7)
	local price = text({
		Text = if skin.Price > 0 then commas(skin.Price) .. " GEMS" elseif skin.Source then "LOCKED" else "STANDARD ISSUE",
		TextSize = 9,
		TextColor3 = GREY,
		Position = UDim2.fromOffset(6, 88),
		Size = UDim2.new(1, -12, 0, 12),
		Parent = card,
	})

	local entry = { skin = skin, outline = outline, price = price, busy = false }
	entry.button = hardButton(card, {
		Name = "Action",
		Fill = "ink",
		Text = "BUY",
		TextSize = 11,
		Position = UDim2.fromOffset(6, 106),
		Size = UDim2.new(1, -12, 0, 48),
		OnClick = function()
			self:_skinAction(entry)
		end,
	})
	return entry
end

function UI._selectTab(self, index)
	local m = self._menu
	m.tab = index
	for i, tab in m.tabs do
		local active = i == index
		tab.button.BackgroundTransparency = if active then 0 else 1
		tab.label.TextColor3 = if active then PAPER else INK
		if active then
			setAccent(tab.index, "TextColor3")
		else
			clearAccent(tab.index)
			tab.index.TextColor3 = GREY
		end
		tab.bar.Visible = active
		tab.page.Visible = active
		if active then
			tab.page.CanvasPosition = Vector2.zero
			tab.page.Position = UDim2.fromOffset(14, TAB_H + 1)
			tween(tab.page, 0.22, { Position = UDim2.fromOffset(0, TAB_H + 1) })
			m.footer.Text = "SHEET " .. twoDigits(i) .. " / " .. twoDigits(#m.tabs) .. " / " .. tab.name
		end
	end
	if index == TAB_SEASON then
		self:_scrollSeasonTrack()
	end
end

-- Popovers (daily streak, starter offer) ------------------------------------------------

-- A centered sheet with an ink header, like the run report. Active so taps on it
-- don't fall through to the wash (which closes the popover).
local function modalSheet(layer, name, width, height, index, title)
	local sheet = new("Frame", {
		Name = name,
		BackgroundColor3 = PAPER,
		BackgroundTransparency = 0.02,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, height),
		Visible = false,
		Parent = layer,
	})
	sheet.Active = true
	fit(sheet)
	stroke(sheet, 1.5)
	cropMarks(sheet, 10, 5)
	notch(sheet, 14, 1, 1, INK)
	local header = new("Frame", { Name = "Header", BackgroundColor3 = INK, Size = UDim2.new(1, 0, 0, 24), Parent = sheet })
	text({ Text = index .. " / " .. title, TextSize = 9, TextColor3 = PAPER, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.6, -10, 1, 0), Parent = header })
	local right = setAccent(text({
		Text = "",
		TextSize = 9,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0.4, 0, 0, 0),
		Size = UDim2.new(0.6, -10, 1, 0),
		Parent = header,
	}), "TextColor3")
	return sheet, right
end

function UI._buildModal(self, root)
	local m = self._menu
	local layer = new("Frame", { Name = "Modal", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = root })
	local wash = new("TextButton", {
		Name = "Wash",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = PAPER,
		BackgroundTransparency = 0.25,
		Position = UDim2.fromOffset(-200, -200),
		Size = UDim2.new(1, 400, 1, 400),
		Parent = layer,
	})
	wash.Activated:Connect(function()
		self:_closeModal()
	end)
	blueprintGrid(layer, 12, 8, 0.9)
	m.modal = layer
	m.modalWash = wash
	m.sheets = {}
	self:_buildDailySheet(layer)
	self:_buildOfferSheet(layer)
end

function UI._openModal(self, name)
	local m = self._menu
	local sheet = m.sheets[name]
	if not sheet then
		return
	end
	for key, other in m.sheets do
		other.Visible = key == name
	end
	m.modalOpen = name
	m.modal.Visible = true
	m.modalWash.BackgroundTransparency = 1
	tween(m.modalWash, 0.25, { BackgroundTransparency = 0.25 })
	sheet.Position = UDim2.new(0.5, 0, 0.5, 16)
	tween(sheet, 0.3, { Position = UDim2.fromScale(0.5, 0.5) })
end

function UI._closeModal(self)
	local m = self._menu
	if not m.modalOpen then
		return
	end
	m.modalOpen = nil
	m.modal.Visible = false
end

function UI._openDaily(self)
	self._menu.dailyKey = nil
	self:_refreshDaily()
	self:_openModal("daily")
end

function UI._buildDailySheet(self, layer)
	local m = self._menu
	local days = #Config.DailyStreak
	local width, height = 400, 216
	local sheet, right = modalSheet(layer, "Daily", width, height, "06", "DAILY STREAK")
	m.sheets.daily = sheet
	local d = { sheet = sheet, right = right, cells = {} }
	self._dailySheet = d

	local gap = 6
	local cellW = math.floor((width - 24 - gap * (days - 1)) / days)
	local startX = math.floor((width - (cellW * days + gap * (days - 1))) / 2)
	for day = 1, days do
		local reward = Config.DailyStreak[day] or {}
		local cell = new("Frame", {
			Name = "Day" .. day,
			BackgroundColor3 = PAPER,
			Position = UDim2.fromOffset(startX + (day - 1) * (cellW + gap), 34),
			Size = UDim2.fromOffset(cellW, 96),
			Parent = sheet,
		})
		local outline = stroke(cell, 1, INK, 0.5)
		local bump = new("UIScale", { Parent = cell })
		local texts = {}
		table.insert(texts, text({ Text = "DAY " .. day, TextSize = 8, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 4), Size = UDim2.new(1, 0, 0, 10), Parent = cell }))
		if reward.Fx then
			fxSwatch(cell, Config.getFx(reward.Fx), { Position = UDim2.fromOffset(4, 17), Size = UDim2.new(1, -8, 0, 26) }, 0.6)
		else
			gemIcon(cell, 12, UDim2.new(0.5, 0, 0, 30))
		end
		table.insert(texts, capText(text({
			Text = "+" .. commas(reward.Gems or 0),
			Font = FONT_NUM,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(2, 46),
			Size = UDim2.new(1, -4, 0, 16),
			Parent = cell,
		}), 11, 6))
		local extra = if reward.Fx
			then fxName(reward.Fx) .. " FX"
			elseif reward.Boost then "+" .. boostName(reward.Boost)
			elseif reward.Balls then "+" .. reward.Balls .. " BALLS"
			else "GEMS"
		table.insert(texts, text({
			Text = extra,
			TextSize = 7,
			TextColor3 = if reward.Fx or reward.Balls or reward.Boost then INK else GREY,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(0, 63),
			Size = UDim2.new(1, 0, 0, 9),
			Parent = cell,
		}))
		local stateTag, stateLabel = tag(cell, "", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -4), Size = UDim2.new(1, -8, 0, 14) })
		d.cells[day] = { frame = cell, outline = outline, bump = bump, tag = stateTag, tagLabel = stateLabel, texts = texts }
	end

	d.note = text({
		Text = "STREAK RESETS IF YOU MISS A DAY",
		TextSize = 8,
		TextColor3 = GREY,
		Position = UDim2.fromOffset(12, 136),
		Size = UDim2.new(1, -24, 0, 10),
		Parent = sheet,
	})
	hardButton(sheet, {
		Name = "Close",
		Fill = "paper",
		Text = "CLOSE",
		TextSize = 11,
		Position = UDim2.fromOffset(12, 152),
		Size = UDim2.fromOffset(96, 52),
		OnClick = function()
			self:_closeModal()
		end,
	})
	d.claim = hardButton(sheet, {
		Name = "Claim",
		Fill = "accent",
		Text = "CLAIM",
		TextSize = 13,
		Align = Enum.TextXAlignment.Left,
		Index = "CLAIM",
		Position = UDim2.fromOffset(116, 152),
		Size = UDim2.new(1, -128, 0, 52),
		OnClick = function()
			self:_claimDaily()
		end,
	})
end

-- Day cell states; only runs when the streak day / readiness changes.
function UI._refreshDailySheet(self, state)
	local d = self._dailySheet
	if not d then
		return
	end
	for day, cell in d.cells do
		local done = day < state.day
		local today = day == state.day
		if today then
			setAccent(cell.frame, "BackgroundColor3")
		else
			clearAccent(cell.frame)
			cell.frame.BackgroundColor3 = PAPER
		end
		cell.outline.Thickness = if today then 2 else 1
		cell.outline.Transparency = if today or done then 0 else 0.5
		for _, label in cell.texts do
			label.TextTransparency = if done then 0.55 else 0
		end
		cell.tag.Visible = done or today
		cell.tagLabel.Text = if done then "DONE" elseif state.ready then "TODAY" else "NEXT"
	end
	d.right.Text = "DAY " .. state.day .. " OF " .. #Config.DailyStreak
	d.note.Text = if state.broken
		then "STREAK RESTARTED AT DAY 1 / CLAIM EVERY DAY TO KEEP IT"
		else "STREAK RESETS IF YOU MISS A DAY"
end

-- Claim button / countdown; runs every second while the menu is open.
function UI._tickDailySheet(self, state)
	local d = self._dailySheet
	if not d or self._dailyBusy then
		return
	end
	local reward = Config.DailyStreak[state.day] or {}
	if state.ready ~= d.ready then
		d.ready = state.ready
		d.claim.setFill(if state.ready then "accent" else "paper")
		d.claim.setEnabled(state.ready)
	end
	d.claim.index.Text = if state.ready then "CLAIM / DAY " .. state.day else "NEXT CLAIM IN"
	if state.ready then
		d.claim.setText("CLAIM +" .. commas(reward.Gems or 0) .. " GEMS")
	elseif state.wait then
		d.claim.setText(clock(state.wait))
	else
		d.claim.setText("--:--:--")
	end
end

function UI._buildOfferSheet(self, layer)
	local product = Config.Products.StarterPack
	if not product or product.Id == 0 then
		return
	end
	local m = self._menu
	local sheet, right = modalSheet(layer, "Offer", 400, 218, "07", "STARTER PACK")
	right.Text = "ONE-TIME PACK"
	m.sheets.offer = sheet

	text({ Text = "A HEAD START FOR NEW PLAYERS / ONCE PER ACCOUNT", TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(12, 30), Size = UDim2.fromOffset(240, 10), Parent = sheet })
	for i, line in starterLines(product) do
		local row = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 44 + (i - 1) * 30), Size = UDim2.fromOffset(236, 28), Parent = sheet })
		rule(row, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), BackgroundTransparency = 0.6 })
		rewardChip(row, line.reward, 14, UDim2.fromOffset(10, 14))
		capText(text({ Text = line.text, Font = FONT_NUM, Position = UDim2.fromOffset(26, 4), Size = UDim2.new(1, -26, 0, 20), Parent = row }), 12, 7)
	end

	-- Previews: the skin as a sample plate, the effect as shards.
	local skin = product.Skin and Config.getSkin(product.Skin)
	if skin then
		local plate = new("Frame", { Name = "SkinPreview", BackgroundColor3 = skin.Color, Position = UDim2.fromOffset(260, 34), Size = UDim2.fromOffset(128, 58), Parent = sheet })
		stroke(plate, 1)
		if skin.Trail then
			new("Frame", { BackgroundColor3 = skin.Trail, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 6), Parent = plate })
		end
		tag(plate, "SKIN", { Position = UDim2.fromOffset(0, 0), Size = UDim2.fromOffset(34, 12) })
	end
	if product.Fx then
		local swatch = fxSwatch(sheet, Config.getFx(product.Fx), { Position = UDim2.fromOffset(260, 96), Size = UDim2.fromOffset(128, 40) })
		local _, fxLabel = tag(swatch, "FX", { BackgroundColor3 = PAPER, Size = UDim2.fromOffset(24, 12) })
		fxLabel.TextColor3 = INK
	end

	text({ Text = "YOU CAN ALSO FIND THIS IN THE SHOP", TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(12, 140), Size = UDim2.new(1, -24, 0, 10), Parent = sheet })
	hardButton(sheet, {
		Name = "Close",
		Fill = "paper",
		Text = "CLOSE",
		TextSize = 11,
		Position = UDim2.fromOffset(12, 156),
		Size = UDim2.fromOffset(96, 52),
		OnClick = function()
			self:_closeModal()
		end,
	})
	local buy = hardButton(sheet, {
		Name = "Buy",
		Fill = "accent",
		Text = "BUY PACK",
		TextSize = 13,
		Align = Enum.TextXAlignment.Left,
		Sub = "",
		Position = UDim2.fromOffset(116, 156),
		Size = UDim2.new(1, -128, 0, 52),
		OnClick = function()
			self:_fire("onBuyProduct", "StarterPack")
		end,
	})
	withPrice(product.Id, Enum.InfoType.Product, function(price)
		buy.sub.Text = "R$ " .. commas(price)
	end)
end

-- Once per session, after the player's first run, if they haven't bought it.
function UI._maybeShowOffer(self)
	local m = self._menu
	if self._offerShown or not m.sheets.offer or m.modalOpen then
		return
	end
	if self._menuOpens < OFFER_AFTER_MENU_OPENS then
		return
	end
	if player:GetAttribute("Gems") == nil then
		return -- data not loaded yet; we don't know if they own it
	end
	if player:GetAttribute("StarterPackBought") == true then
		self._offerShown = true
		return
	end
	self._offerShown = true
	self:_openModal("offer")
end

function UI._refreshStarter(self)
	local m = self._menu
	local bought = player:GetAttribute("StarterPackBought") == true
	if m.starterCard then
		m.starterCard.Visible = not bought
		m.starterHeader.Visible = not bought
	end
	if bought and m.modalOpen == "offer" then
		self:_closeModal()
	end
end

function UI._setTabPip(self, index, on)
	local tab = self._menu.tabs[index]
	if tab then
		tab.pip.Visible = on
	end
end

-- Missions ---------------------------------------------------------------------------------

function UI._buildMissionsPage(self, page)
	local m = self._menu
	local _, right = sectionHeader(page, 1, "02.1", "DAILY MISSIONS")
	m.missionsRight = right
	m.missions = new("Frame", { Name = "Missions", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = page })
	list(m.missions, 6)
	m.missionsReset = text({ Text = "", TextSize = 9, TextColor3 = GREY, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 3, Parent = page })
	local _, roadRight = sectionHeader(page, 4, "02.2", "LEVEL ROAD")
	m.roadRight = roadRight
	m.levelRoad = new("Frame", { Name = "LevelRoad", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 5, Parent = page })
	list(m.levelRoad, 0)
end

local function readMissions()
	local raw = player:GetAttribute("Missions")
	local decoded = decodeJson(raw)
	if type(decoded) ~= "table" then
		return nil, raw
	end
	local missions = {}
	for _, entry in decoded do
		if type(entry) == "table" and entry.id ~= nil then
			local goal = math.max(1, math.floor(tonumber(entry.goal) or 1))
			table.insert(missions, {
				id = entry.id,
				text = string.upper(tostring(entry.text or "MISSION")),
				goal = goal,
				progress = math.clamp(math.floor(tonumber(entry.progress) or 0), 0, goal),
				gems = math.floor(tonumber(entry.gems) or 0),
				xp = math.floor(tonumber(entry.xp) or 0),
				claimed = entry.claimed == true,
			})
		end
	end
	return missions, raw
end

-- Rebuilds only when the Missions JSON or the reroll count actually changed.
function UI._rebuildMissions(self, force)
	local m = self._menu
	local missions, raw = readMissions()
	local rerolls = math.max(0, math.floor(attrNumber("MissionRerolls", 0)))
	local key = tostring(raw) .. "|" .. rerolls
	if not force and key == m.missionsKey then
		return
	end
	m.missionsKey = key
	clearRows(m.missions)
	m.missionsRight.Text = rerolls .. (if rerolls == 1 then " REROLL" else " REROLLS") .. " LEFT"

	local claimable = 0
	if missions == nil or #missions == 0 then
		text({
			Text = if missions == nil then "LOADING" else "NO MISSIONS / CHECK BACK SOON",
			TextSize = 9,
			TextColor3 = GREY,
			Size = UDim2.new(1, 0, 0, 28),
			Parent = m.missions,
		})
	else
		for i, mission in missions do
			if mission.progress >= mission.goal and not mission.claimed then
				claimable += 1
			end
			self:_buildMissionRow(m.missions, i, mission, rerolls)
		end
	end
	self:_setTabPip(TAB_MISSIONS, claimable > 0)
end

function UI._buildMissionRow(self, parent, index, mission, rerolls)
	local complete = mission.progress >= mission.goal
	local ready = complete and not mission.claimed
	local row = new("Frame", { Name = "Mission" .. index, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 72), LayoutOrder = index, Parent = parent })
	stroke(row, if ready then 1.5 else 1, INK, if mission.claimed then 0.75 elseif ready then 0 else 0.5)
	if ready then
		local bar = new("Frame", { Size = UDim2.new(0, 4, 1, 0), Parent = row })
		setAccent(bar, "BackgroundColor3")
	end
	local fade = if mission.claimed then 0.5 else 0

	text({ Text = "M-" .. twoDigits(index), TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(10, 5), Size = UDim2.fromOffset(40, 10), Parent = row })
	text({
		Text = commas(mission.progress) .. " / " .. commas(mission.goal),
		TextSize = 8,
		TextColor3 = GREY,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromOffset(50, 5),
		Size = UDim2.new(1, -152, 0, 10),
		Parent = row,
	})
	capText(text({
		Text = mission.text,
		Font = FONT_NUM,
		TextTransparency = fade,
		Position = UDim2.fromOffset(10, 16),
		Size = UDim2.new(1, -112, 0, 18),
		Parent = row,
	}), 11, 6)
	local _, fill = meter(row, { Position = UDim2.fromOffset(10, 39), Size = UDim2.new(1, -112, 0, 5) })
	fill.Size = UDim2.fromScale(mission.progress / mission.goal, 1)
	if mission.claimed then
		clearAccent(fill)
		fill.BackgroundColor3 = INK
		fill.BackgroundTransparency = 0.6
	end
	gemIcon(row, 7, UDim2.fromOffset(14, 57))
	text({
		Text = "+" .. commas(mission.gems) .. " GEMS   +" .. commas(mission.xp) .. " XP",
		TextSize = 9,
		TextTransparency = fade,
		Position = UDim2.fromOffset(24, 50),
		Size = UDim2.new(1, -126, 0, 14),
		Parent = row,
	})

	if mission.claimed then
		stamp(row, "CLAIMED", { Position = UDim2.new(1, -50, 0.5, 0), Size = UDim2.fromOffset(82, 24) }, "clear")
	elseif complete then
		local button
		button = hardButton(row, {
			Name = "Claim",
			Fill = "accent",
			Text = "CLAIM",
			TextSize = 12,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.fromOffset(88, 52),
			OnClick = function()
				self:_missionAction("ClaimMission", mission, button, "CLAIMING")
			end,
		})
	elseif rerolls > 0 then
		local button
		button = hardButton(row, {
			Name = "Reroll",
			Fill = "paper",
			Text = "REROLL",
			TextSize = 10,
			Sub = "SWAP MISSION",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.fromOffset(88, 48),
			OnClick = function()
				self:_missionAction("RerollMission", mission, button, "...")
			end,
		})
		button.sub.TextSize = 7
	else
		capText(text({
			Text = math.floor(mission.progress / mission.goal * 100) .. "%",
			Font = FONT_NUM,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.fromOffset(88, 30),
			Parent = row,
		}), 16, 8)
	end
end

function UI._missionAction(self, action, mission, button, busyText)
	local m = self._menu
	if m.missionBusy then
		return
	end
	m.missionBusy = true
	button.setEnabled(false)
	button.setText(busyText)
	task.spawn(function()
		local ok, message = self:_ask("onShop", action, mission.id)
		m.missionBusy = false
		if not ok then
			self:toast(message or (if action == "ClaimMission" then "COULD NOT CLAIM" else "COULD NOT REROLL"), "error")
		end
		self:_rebuildMissions(true)
	end)
end

-- Every level unlock in order, with how far away it is.
function UI._rebuildLevelRoad(self)
	local m = self._menu
	if not m.levelRoad then
		return
	end
	clearRows(m.levelRoad)
	local level = levelInfo()
	m.roadRight.Text = "+" .. Config.LEVEL_UP_GEMS .. " GEMS EVERY LEVEL"
	local levels = {}
	for unlockLevel in Config.LevelUnlocks do
		table.insert(levels, unlockLevel)
	end
	table.sort(levels)
	local upcoming = nextUnlock(level)
	for i, unlockLevel in levels do
		local reward = Config.LevelUnlocks[unlockLevel]
		local reached = level >= unlockLevel
		local row = new("Frame", { Name = "Lv" .. unlockLevel, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = i, Parent = m.levelRoad })
		rule(row, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), BackgroundTransparency = 0.8 })
		if unlockLevel == upcoming then
			local bar = new("Frame", { Size = UDim2.new(0, 3, 1, -6), Position = UDim2.fromOffset(0, 3), Parent = row })
			setAccent(bar, "BackgroundColor3")
		end
		capText(text({
			Text = "LV " .. twoDigits(unlockLevel),
			Font = FONT_NUM,
			TextTransparency = if reached or unlockLevel == upcoming then 0 else 0.45,
			Position = UDim2.fromOffset(8, 6),
			Size = UDim2.fromOffset(52, 18),
			Parent = row,
		}), 10, 7)
		rewardChip(row, reward, 10, UDim2.fromOffset(70, 15))
		text({
			Text = rewardText(reward),
			TextSize = 9,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextTransparency = if reached or unlockLevel == upcoming then 0 else 0.45,
			Position = UDim2.fromOffset(82, 0),
			Size = UDim2.new(1, -164, 1, 0),
			Parent = row,
		})
		local status = if reached then "UNLOCKED" elseif unlockLevel == upcoming then (unlockLevel - level) .. " LV TO GO" else "LOCKED"
		local statusTag, statusLabel = tag(row, status, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(76, 16) }, reached)
		if not reached then
			statusTag.BackgroundTransparency = 1
			statusLabel.TextColor3 = if unlockLevel == upcoming then INK else GREY
		end
	end
end

-- Season pass ------------------------------------------------------------------------------

function UI._buildSeasonPage(self, page)
	local m = self._menu
	local s = {}
	m.season = s
	local _, right = sectionHeader(page, 1, "03.1", "SEASON PASS")
	s.right = right

	local info = new("Frame", { Name = "Info", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62), LayoutOrder = 2, Parent = page })
	s.name = capText(text({ Text = Config.SEASON_NAME, Font = FONT_NUM, Position = UDim2.fromOffset(0, 2), Size = UDim2.new(1, 0, 0, 18), Parent = info }), 12, 7)
	s.tier = text({ Text = "TIER 00", TextSize = 9, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(0.5, 0, 0, 12), Parent = info })
	s.xp = text({
		Text = "",
		TextSize = 9,
		TextColor3 = GREY,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0.5, 0, 0, 24),
		Size = UDim2.new(0.5, 0, 0, 12),
		Parent = info,
	})
	local _, fill = meter(info, { Position = UDim2.fromOffset(0, 39), Size = UDim2.new(1, 0, 0, 6) })
	s.fill = fill
	text({ Text = "EVERY RUN FILLS THE PASS / FREE ROW IS FOR EVERYONE", TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(0, 49), Size = UDim2.new(1, 0, 0, 10), Parent = info })

	-- Premium unlock card (hidden once owned, or when the product isn't set up).
	local product = Config.Products.SeasonPremium
	local unlock = new("Frame", { Name = "Premium", BackgroundColor3 = INK, Size = UDim2.new(1, 0, 0, 66), LayoutOrder = 3, Visible = false, Parent = page })
	notch(unlock, 10, 1, 0)
	capText(setAccent(text({ Text = "PREMIUM TRACK", Font = FONT_NUM, Position = UDim2.fromOffset(10, 7), Size = UDim2.new(1, -112, 0, 16), Parent = unlock }), "TextColor3"), 11, 7)
	text({
		Text = "UNLOCKS THE PREMIUM ROW FOR THIS SEASON: SKINS, FX AND MORE GEMS. TIERS YOU ALREADY REACHED CAN BE CLAIMED RIGHT AWAY.",
		TextSize = 7,
		TextColor3 = PAPER,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(10, 26),
		Size = UDim2.new(1, -112, 0, 36),
		Parent = unlock,
	})
	local buy = hardButton(unlock, {
		Name = "Unlock",
		Fill = "accent",
		Text = "UNLOCK",
		TextSize = 11,
		Sub = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 2),
		Size = UDim2.fromOffset(92, 54),
		OnClick = function()
			self:_fire("onBuyProduct", "SeasonPremium")
		end,
	})
	withPrice(product and product.Id, Enum.InfoType.Product, function(price)
		buy.sub.Text = "R$ " .. commas(price)
	end)
	s.unlock = unlock
	s.active = tag(page, "PREMIUM TRACK ACTIVE", { Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Visible = false }, true)

	local _, trackRight = sectionHeader(page, 4, "03.2", "REWARDS")
	s.trackRight = trackRight
	local holder = new("Frame", { Name = "Track", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 146), LayoutOrder = 5, Parent = page })
	for _, rowInfo in { { "FREE", 23 }, { "PREMIUM", 81 } } do
		local label = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, rowInfo[2]), Size = UDim2.fromOffset(40, 53), Parent = holder })
		rule(label, { Size = UDim2.new(0, 2, 1, 0) })
		text({ Text = rowInfo[1], TextSize = 7, Position = UDim2.fromOffset(5, 0), Size = UDim2.new(1, -5, 1, 0), Parent = label })
	end
	local scroll = new("ScrollingFrame", {
		Name = "Tiers",
		Active = true,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(42, 0),
		Size = UDim2.new(1, -42, 1, 0),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = INK,
		HorizontalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		Parent = holder,
	})
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, SEASON_COLUMN_GAP),
		Parent = scroll,
	})
	s.scroll = scroll
end

local function readSeasonClaimed()
	local decoded = decodeJson(player:GetAttribute("SeasonClaimed"))
	local claimed = { Free = {}, Premium = {} }
	if type(decoded) == "table" then
		for field, trackName in { free = "Free", premium = "Premium" } do
			local tiers = decoded[field]
			if type(tiers) == "table" then
				for _, tier in tiers do
					local n = tonumber(tier)
					if n then
						claimed[trackName][math.floor(n)] = true
					end
				end
			end
		end
	end
	return claimed
end

local function seasonProgress()
	local maxTier = #Config.SeasonTiers
	local tier = math.clamp(math.floor(attrNumber("SeasonTier", 0)), 0, maxTier)
	local need = math.max(1, Config.SEASON_TIER_XP)
	local xp = math.clamp(math.floor(attrNumber("SeasonXP", 0)), 0, need)
	return tier, xp, need, maxTier
end

function UI._refreshSeasonProgress(self)
	local s = self._menu.season
	local tier, xp, need, maxTier = seasonProgress()
	s.name.Text = string.upper(tostring(ReplicatedStorage:GetAttribute("SeasonName") or Config.SEASON_NAME))
	s.tier.Text = "TIER " .. twoDigits(tier) .. " / " .. maxTier
	local fraction = if tier >= maxTier then 1 else xp / need
	s.xp.Text = if tier >= maxTier then "PASS COMPLETE" else commas(xp) .. " / " .. commas(need) .. " XP TO TIER " .. (tier + 1)
	tween(s.fill, 0.4, { Size = UDim2.fromScale(fraction, 1) })
	if s.nextFill and s.nextFill.Parent then
		s.nextFill.Size = UDim2.fromScale(fraction, 1)
	end
end

-- Rebuilds the 30-tier track only when tier, ownership or claims change.
function UI._rebuildSeason(self, force)
	local s = self._menu.season
	self:_refreshSeasonProgress()
	local tier, _, _, maxTier = seasonProgress()
	local premium = player:GetAttribute("SeasonPremium") == true
	local key = tier .. "|" .. tostring(premium) .. "|" .. tostring(player:GetAttribute("SeasonClaimed"))
	if not force and key == s.key then
		return
	end
	s.key = key
	local claimed = readSeasonClaimed()
	local product = Config.Products.SeasonPremium
	s.unlock.Visible = not premium and product ~= nil and product.Id ~= 0
	s.active.Visible = premium

	clearRows(s.scroll)
	s.nextFill = nil
	local claimable, firstClaimable = 0, nil
	for t = 1, maxTier do
		local rewards = Config.SeasonTiers[t] or {}
		local reached = t <= tier
		local column = new("Frame", { Name = "Tier" .. t, BackgroundTransparency = 1, Size = UDim2.fromOffset(SEASON_COLUMN_W, 138), LayoutOrder = t, Parent = s.scroll })
		local head = new("Frame", { BackgroundColor3 = INK, BackgroundTransparency = if reached then 0 else 1, Size = UDim2.new(1, -3, 0, 18), Parent = column })
		if not reached then
			stroke(head, 1, INK, 0.6)
		end
		text({
			Text = "T" .. twoDigits(t),
			Font = FONT_NUM,
			TextSize = 9,
			TextColor3 = if reached then PAPER else INK,
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			Parent = head,
		})
		if t == tier + 1 then
			local _, fill = meter(column, { Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, -3, 0, 3) })
			s.nextFill = fill
		end
		for _, trackName in { "Free", "Premium" } do
			local reward = rewards[trackName]
			local state
			if reward == nil then
				state = "empty"
			elseif claimed[trackName][t] then
				state = "claimed"
			elseif trackName == "Premium" and not premium then
				state = "premiumLocked"
			elseif reached then
				state = "claimable"
			else
				state = "locked"
			end
			if state == "claimable" then
				claimable += 1
				firstClaimable = firstClaimable or t
			end
			self:_buildSeasonCell(column, if trackName == "Free" then 23 else 81, trackName, t, reward, state)
		end
	end
	self:_refreshSeasonProgress()
	s.trackRight.Text = if claimable > 0 then claimable .. " TO CLAIM" else "SWIPE FOR ALL " .. maxTier .. " TIERS"
	s.focusTier = firstClaimable or math.min(tier + 1, maxTier)
	self:_setTabPip(TAB_SEASON, claimable > 0)
	self:_scrollSeasonTrack()
end

function UI._buildSeasonCell(self, column, y, trackName, tier, reward, state)
	local holder = new("Frame", { Name = trackName, BackgroundTransparency = 1, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 56), Parent = column })
	if state == "empty" then
		local blank = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -3, 1, -3), Parent = holder })
		stroke(blank, 1, INK, 0.85)
		text({ Text = "--", TextSize = 9, TextColor3 = GREY, TextTransparency = 0.4, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = blank })
		return
	end
	local claimable = state == "claimable"
	local locked = state == "locked" or state == "premiumLocked"
	if claimable then
		new("Frame", { Name = "Shadow", BackgroundColor3 = INK, Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -3, 1, -3), Parent = holder })
	end
	local face = new("TextButton", {
		Name = "Face",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = PAPER,
		BackgroundTransparency = if locked then 0.4 else 0,
		Size = UDim2.new(1, -3, 1, -3),
		Parent = holder,
	})
	stroke(face, if claimable then 1.5 else 1, INK, if claimable or state == "claimed" then 0 else 0.5)
	if claimable then
		setAccent(face, "BackgroundColor3")
	end
	if state == "premiumLocked" then
		hatch(face, { Name = "Hatch", Size = UDim2.new(0, 5, 1, 0) }, INK, 0.3, 3)
	end
	local dim = if claimable then 0 elseif state == "claimed" then 0.55 else 0.4
	rewardChip(face, reward, 9, UDim2.fromOffset(11, 9))

	local big, small
	if reward.Skin then
		big, small = skinName(reward.Skin), if reward.Fx then "SKIN + FX" else "SKIN"
	elseif reward.Fx then
		big, small = fxName(reward.Fx), "FX"
	elseif reward.Boost and not reward.Gems then
		big, small = boostName(reward.Boost), "BOOST"
	else
		big, small = "+" .. commas(reward.Gems or 0), if reward.Boost then "GEMS + BOOST" else "GEMS"
	end
	capText(text({
		Text = big,
		Font = FONT_NUM,
		TextTransparency = dim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(3, 16),
		Size = UDim2.new(1, -6, 0, 14),
		Parent = face,
	}), 10, 5)
	text({
		Text = small,
		TextSize = 7,
		TextTransparency = dim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 9),
		Parent = face,
	})
	local status = if claimable then "CLAIM" elseif state == "claimed" then "CLAIMED" elseif state == "premiumLocked" then "PREMIUM" else "LOCKED"
	local statusTag, statusLabel = tag(face, status, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -3), Size = UDim2.new(1, -6, 0, 11) })
	statusLabel.TextSize = 7
	if not claimable then
		statusTag.BackgroundTransparency = 1
		statusLabel.TextColor3 = if state == "claimed" then INK else GREY
	end

	face.Activated:Connect(function()
		if state == "claimable" then
			self:_claimSeasonTier(trackName, tier, statusLabel)
		elseif state == "premiumLocked" then
			self:toast("PREMIUM TRACK REWARD", "info")
		elseif state == "locked" then
			self:toast("REACH TIER " .. tier .. " TO CLAIM", "info")
		end
	end)
end

function UI._claimSeasonTier(self, trackName, tier, statusLabel)
	local s = self._menu.season
	if s.busy then
		return
	end
	s.busy = true
	statusLabel.Text = "..."
	task.spawn(function()
		local ok, message = self:_ask("onShop", "ClaimSeasonTier", { track = trackName, tier = tier })
		s.busy = false
		if not ok then
			self:toast(message or "COULD NOT CLAIM", "error")
		end
		self:_rebuildSeason(true)
	end)
end

-- Bring the first claimable (or next) tier into view, one column of context on the left.
function UI._scrollSeasonTrack(self)
	local s = self._menu.season
	if not s or not s.focusTier then
		return
	end
	local focus = s.focusTier
	task.delay(0.1, function()
		if s.scroll.Parent then
			s.scroll.CanvasPosition = Vector2.new(math.max(0, (focus - 2) * (SEASON_COLUMN_W + SEASON_COLUMN_GAP)), 0)
		end
	end)
end

-- Missions reset + season end countdowns (ticked once a second while the menu is open).
function UI._refreshCountdowns(self)
	local m = self._menu
	local now = os.time()
	local reset = tonumber(player:GetAttribute("MissionsReset"))
	if reset and reset > now then
		m.missionsReset.Text = "NEW MISSIONS IN " .. clock(reset - now)
	elseif reset then
		m.missionsReset.Text = "NEW MISSIONS ARRIVING"
	else
		m.missionsReset.Text = ""
	end
	local ends = tonumber(ReplicatedStorage:GetAttribute("SeasonEnds")) or Config.SEASON_ENDS
	if ends and ends > 0 then
		m.season.right.Text = if ends > now then "ENDS IN " .. longClock(ends - now) else "SEASON ENDED"
	else
		m.season.right.Text = ""
	end
end

-- Menu data ---------------------------------------------------------------------------------

function UI._refreshStats(self)
	local m = self._menu
	m.best.Text = commas(player:GetAttribute("Best") or 0)
	local gems = commas(player:GetAttribute("Gems") or 0)
	m.gems.Text = gems
	m.shopGems.Text = "BALANCE " .. gems
	local bonus = math.max(0, math.floor(attrNumber("BonusBalls", 0)))
	m.play.index.Text = if bonus > 0 then "A / START RUN / +" .. bonus .. " BONUS BALLS" else "A / START RUN / 0 M"
	self:_refreshSkins()
	self:_refreshFx()
end

-- Level badge, XP bar and the "next unlock" note under the stats strip.
function UI._refreshLevel(self)
	local m = self._menu
	local level, xp, needed = levelInfo()
	m.level.Text = "LV " .. twoDigits(level)
	tween(m.xpFill, 0.4, { Size = UDim2.fromScale(xp / needed, 1) })
	local note = "XP " .. commas(xp) .. " / " .. commas(needed)
	local unlockLevel, reward = nextUnlock(level)
	if unlockLevel then
		note ..= " / NEXT: " .. rewardText(reward) .. " AT LV " .. unlockLevel
	end
	m.xpNote.Text = note
	if m.levelValue and level > m.levelValue and m.root.Visible then
		m.levelBump.Scale = 1.25
		tween(m.levelBump, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	if level ~= m.levelValue then
		m.levelValue = level
		self:_rebuildLevelRoad()
	end
end

-- Streak state as the UI shows it. Claiming after StreakExpires restarts at day 1.
local function dailyState()
	local now = os.time()
	local nextDaily = tonumber(player:GetAttribute("NextDaily"))
	local expires = tonumber(player:GetAttribute("StreakExpires"))
	local day = math.clamp(math.floor(attrNumber("StreakDay", 1)), 1, #Config.DailyStreak)
	local broken = expires ~= nil and expires > 0 and now > expires
	if broken then
		day = 1
	end
	return {
		now = now,
		day = day,
		broken = broken,
		ready = nextDaily ~= nil and now >= nextDaily,
		wait = if nextDaily then nextDaily - now else nil,
	}
end

function UI._refreshDaily(self)
	local m = self._menu
	local daily = m.daily
	local state = dailyState()
	local reward = Config.DailyStreak[state.day] or {}

	-- Streak pips: done days ink, today accent, the rest outlined.
	local key = state.day .. (if state.ready then "R" else "W") .. (if state.broken then "B" else "")
	if key ~= m.dailyKey then
		m.dailyKey = key
		for day, pip in m.dailyPips do
			local done = day < state.day
			local today = day == state.day
			if today then
				setAccent(pip.frame, "BackgroundColor3")
				pip.frame.BackgroundTransparency = 0
			else
				clearAccent(pip.frame)
				pip.frame.BackgroundColor3 = INK
				pip.frame.BackgroundTransparency = if done then 0 else 1
			end
			pip.stroke.Transparency = if done or today then 0 else 0.5
		end
		self:_refreshDailySheet(state)
	end

	if not self._dailyBusy then
		if state.ready ~= self._dailyReady then
			self._dailyReady = state.ready
			daily.setFill(if state.ready then "accent" else "paper")
		end
		daily.index.Text = "B / DAILY / DAY " .. state.day .. " OF " .. #Config.DailyStreak
		if state.ready then
			daily.setText("CLAIM +" .. commas(reward.Gems or 0))
		elseif state.wait then
			daily.setText(clock(state.wait))
		else
			daily.setText("--:--:--")
		end
	end
	self:_tickDailySheet(state)
end

function UI._claimDaily(self)
	if self._dailyBusy or not dailyState().ready then
		return
	end
	self._dailyBusy = true
	local d = self._dailySheet
	d.claim.setEnabled(false)
	d.claim.setText("CLAIMING")
	self._menu.daily.setText("CLAIMING")
	local claimedDay = dailyState().day
	task.spawn(function()
		local ok, message
		if type(self._callbacks.onClaimDaily) == "function" then
			ok, message = self:_ask("onClaimDaily")
		else
			ok, message = self:_ask("onShop", "ClaimDaily")
		end
		self._dailyBusy = false
		self._dailyReady = nil
		self._menu.dailyKey = nil
		d.ready = nil
		if ok then
			-- The server's Reward event toasts the amount; here the day gets stamped.
			local cell = d.cells[claimedDay]
			if cell then
				cell.bump.Scale = 1.2
				tween(cell.bump, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		else
			self:toast(message or "COULD NOT CLAIM", "error")
		end
		self:_refreshDaily()
	end)
end

function UI._rebuildTopRuns(self)
	local container = self._menu.runs
	clearRows(container)

	local raw = ReplicatedStorage:GetAttribute("TopRuns")
	local runs = nil
	if type(raw) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and type(decoded) == "table" then
			runs = decoded
		end
	end

	if runs == nil or #runs == 0 then
		text({
			Text = if runs == nil then "LOADING" else "NO RUNS YET / BE THE FIRST",
			TextSize = 9,
			TextColor3 = GREY,
			Size = UDim2.new(1, 0, 0, 28),
			Parent = container,
		})
		return
	end

	for i, run in runs do
		if i > 10 then
			break
		end
		local name = string.upper(tostring(run.name or "???"))
		local isMe = run.name == player.Name
		local row = new("Frame", {
			Name = "Run" .. i,
			BackgroundColor3 = INK,
			BackgroundTransparency = if isMe then 0 else 1,
			Size = UDim2.new(1, 0, 0, 24),
			LayoutOrder = i,
			Parent = container,
		})
		local ink = if isMe then PAPER else INK
		if (tonumber(run.rank) or i) == 1 then
			local bar = new("Frame", { Size = UDim2.new(0, 3, 1, 0), Parent = row })
			setAccent(bar, "BackgroundColor3")
		end
		local rank = text({ Text = twoDigits(run.rank or i), TextSize = 9, TextColor3 = if isMe then PAPER else GREY, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(0, 22, 1, 0), Parent = row })
		if isMe then
			setAccent(rank, "TextColor3")
		end
		text({
			Text = name,
			TextSize = 10,
			TextColor3 = ink,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(34, 0),
			Size = UDim2.new(1, -124, 1, 0),
			Parent = row,
		})
		capText(text({
			Text = commas(run.meters or 0) .. " M",
			Font = FONT_NUM,
			TextColor3 = ink,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 0),
			Size = UDim2.new(0, 86, 1, 0),
			Parent = row,
		}), 10, 7)
		if not isMe then
			rule(row, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), BackgroundTransparency = 0.85 })
		end
	end
end

function UI._rebuildPasses(self)
	local m = self._menu
	clearRows(m.passes)
	local shown = 0
	for order, key in PASS_ORDER do
		local pass = Config.GamePasses[key]
		if pass and pass.Id ~= 0 and not hasPass(key) then
			shown += 1
			local info = PASS_INFO[key]
			local card = new("Frame", { Name = key, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 60), LayoutOrder = order, Parent = m.passes })
			stroke(card, 1, INK, 0.5)
			local code = new("Frame", { BackgroundColor3 = INK, Position = UDim2.fromOffset(6, 8), Size = UDim2.fromOffset(44, 44), Parent = card })
			capText(setAccent(text({
				Text = info.code,
				Font = FONT_NUM,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.fromScale(1, 1),
				Parent = code,
			}), "TextColor3"), 12, 7)
			capText(text({ Text = info.title, Font = FONT_NUM, Position = UDim2.fromOffset(58, 8), Size = UDim2.new(1, -146, 0, 16), Parent = card }), 11, 7)
			text({
				Text = info.copy,
				TextSize = 8,
				TextColor3 = GREY,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.fromOffset(58, 26),
				Size = UDim2.new(1, -146, 0, 28),
				Parent = card,
			})
			local buy = hardButton(card, {
				Name = "Buy",
				Fill = "accent",
				Text = "GET",
				TextSize = 12,
				Sub = "",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -6, 0.5, 0),
				Size = UDim2.fromOffset(78, 50),
				OnClick = function()
					self:_fire("onBuyPass", key)
				end,
			})
			withPrice(pass.Id, Enum.InfoType.GamePass, function(price)
				if buy.sub.Parent then
					buy.sub.Text = "R$ " .. commas(price)
				end
			end)
		end
	end
	m.passHeader.Visible = shown > 0
	m.passes.Visible = shown > 0
end

function UI._rebuildZones(self)
	local m = self._menu
	clearRows(m.zones)
	local reached = math.max(0, math.floor(tonumber(player:GetAttribute("Checkpoint")) or 0))
	local unlocked = hasPass("Checkpoints")
	m.zonesRight.Text = "REACHED " .. twoDigits(reached)

	local passId = Config.GamePasses.Checkpoints.Id
	if not unlocked and reached > 0 and passId ~= 0 then
		local holder = new("Frame", { Name = "Unlock", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62), LayoutOrder = 0, Parent = m.zones })
		local unlock = hardButton(holder, {
			Name = "UnlockAll",
			Fill = "accent",
			Text = "UNLOCK ALL ZONES",
			TextSize = 12,
			Sub = "",
			Position = UDim2.fromOffset(0, 6),
			Size = UDim2.new(1, 0, 0, 50),
			OnClick = function()
				self:_fire("onBuyPass", "Checkpoints")
			end,
		})
		withPrice(passId, Enum.InfoType.GamePass, function(price)
			if unlock.sub.Parent then
				unlock.sub.Text = "R$ " .. commas(price)
			end
		end)
	end

	local function zoneRow(i, locked, uncharted)
		local theme = themeFor(i)
		local row = new("Frame", { Name = "Zone" .. i, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56), LayoutOrder = i + 1, Parent = m.zones })
		rule(row, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), BackgroundTransparency = 0.8 })

		-- Two-tone chip: zone accent over its wall color.
		local chip = new("Frame", {
			BackgroundColor3 = theme.Accent,
			BackgroundTransparency = if uncharted then 0.7 else 0,
			Position = UDim2.fromOffset(0, 10),
			Size = UDim2.fromOffset(36, 36),
			Parent = row,
		})
		stroke(chip, 1.5, INK, if uncharted then 0.6 else 0)
		new("Frame", {
			BackgroundColor3 = theme.Wall,
			BackgroundTransparency = if uncharted then 0.7 else 0,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 11),
			Parent = chip,
		})

		local title = if i == 0 then "START" else "ZONE " .. twoDigits(i)
		capText(text({
			Text = title,
			Font = FONT_NUM,
			TextTransparency = if uncharted then 0.55 else 0,
			Position = UDim2.fromOffset(46, 12),
			Size = UDim2.new(1, -130, 0, 18),
			Parent = row,
		}), 13, 7)
		text({
			Text = (if uncharted then "UNCHARTED / " else "FROM ") .. commas(math.floor(Config.checkpointMeters(i) + 0.5)) .. " M",
			TextSize = 9,
			TextColor3 = GREY,
			Position = UDim2.fromOffset(46, 32),
			Size = UDim2.new(1, -130, 0, 12),
			Parent = row,
		})

		if uncharted then
			return
		elseif locked then
			local tag = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0), Size = UDim2.fromOffset(70, 24), Parent = row })
			stroke(tag, 1, INK, 0.3)
			text({ Text = "LOCKED", TextSize = 9, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = tag })
		else
			hardButton(row, {
				Name = "Go",
				Fill = if i == 0 then "paper" else "accent",
				Text = "GO",
				TextSize = 12,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.fromOffset(74, 48),
				OnClick = function()
					self:_fire("onPlay", i)
				end,
			})
		end
	end

	for i = 0, reached do
		zoneRow(i, i > 0 and not unlocked, false)
	end
	zoneRow(reached + 1, true, true)
end

function UI._refreshSkins(self)
	local m = self._menu
	if not m or not m.skinCards then
		return
	end
	local owned = ownedSkins()
	local equipped = player:GetAttribute("EquippedSkin") or "Default"
	local gems = tonumber(player:GetAttribute("Gems")) or 0
	local ownedCount = 0
	for _, skin in Config.Skins do
		if owned[skin.Id] then
			ownedCount += 1
		end
		local card = m.skinCards[skin.Id]
		if card and not card.busy then
			local button = card.button
			if equipped == skin.Id then
				card.state = "equipped"
				button.setFill("accent")
				button.setText("EQUIPPED")
				button.setEnabled(false)
				card.outline.Thickness = 2
				card.outline.Transparency = 0
			elseif owned[skin.Id] then
				card.state = "owned"
				button.setFill("paper")
				button.setText("EQUIP")
				button.setEnabled(true)
				card.outline.Thickness = 1
				card.outline.Transparency = 0.5
			elseif skin.Price <= 0 and skin.Source then
				-- Earned through levels / streak / season / offers, never sold for gems.
				card.state = "locked"
				button.setFill("paper")
				button.setText(skin.Source)
				button.setEnabled(false)
				card.outline.Thickness = 1
				card.outline.Transparency = 0.5
			else
				card.state = "buy"
				button.setFill("ink")
				button.setText("BUY")
				button.setEnabled(true)
				card.outline.Thickness = 1
				card.outline.Transparency = 0.5
			end
			if skin.Price > 0 then
				local short = skin.Price - gems
				card.price.Text = commas(skin.Price)
					.. " GEMS"
					.. (if card.state == "buy" and short > 0 then " / -" .. commas(short) else "")
			elseif skin.Source then
				card.price.Text = if card.state == "locked" then "LOCKED / EARN IT" else "EARNED / " .. skin.Source
			end
		end
	end
	m.skinsRight.Text = ownedCount .. " / " .. #Config.Skins .. " OWNED"
end

function UI._skinAction(self, card)
	if card.busy or card.state == "equipped" or card.state == "locked" then
		return
	end
	local buying = card.state == "buy"
	card.busy = true
	card.button.setEnabled(false)
	card.button.setText(if buying then "BUYING" else "EQUIPPING")
	task.spawn(function()
		local ok, message = self:_ask(if buying then "onBuySkin" else "onEquipSkin", card.skin.Id)
		card.busy = false
		if ok and buying then
			self:toast(string.upper(card.skin.Name) .. " UNLOCKED", "reward")
		elseif not ok then
			self:toast(message or (if buying then "PURCHASE FAILED" else "COULD NOT EQUIP"), "error")
		end
		self:_refreshSkins()
	end)
end

function UI._refreshFx(self)
	local m = self._menu
	if not m or not m.fxCards then
		return
	end
	local owned = ownedFx()
	local equipped = player:GetAttribute("EquippedFx")
	if type(equipped) ~= "string" or equipped == "" then
		equipped = "Classic"
	end
	local gems = tonumber(player:GetAttribute("Gems")) or 0
	local ownedCount = 0
	for _, fx in Config.ShatterFx do
		if owned[fx.Id] then
			ownedCount += 1
		end
		local card = m.fxCards[fx.Id]
		if card and not card.busy then
			local button = card.button
			if equipped == fx.Id then
				card.state = "equipped"
				button.setFill("accent")
				button.setText("EQUIPPED")
				button.setEnabled(false)
				card.outline.Thickness = 2
				card.outline.Transparency = 0
			elseif owned[fx.Id] then
				card.state = "owned"
				button.setFill("paper")
				button.setText("EQUIP")
				button.setEnabled(true)
				card.outline.Thickness = 1
				card.outline.Transparency = 0.5
			elseif fx.Price <= 0 then
				card.state = "locked"
				button.setFill("paper")
				button.setText(fx.Source or "LOCKED")
				button.setEnabled(false)
				card.outline.Thickness = 1
				card.outline.Transparency = 0.5
			else
				card.state = "buy"
				button.setFill("ink")
				button.setText("BUY")
				button.setEnabled(true)
				card.outline.Thickness = 1
				card.outline.Transparency = 0.5
			end
			if fx.Price > 0 then
				local short = fx.Price - gems
				card.price.Text = commas(fx.Price) .. " GEMS" .. (if card.state == "buy" and short > 0 then " / -" .. commas(short) else "")
			elseif fx.Source then
				card.price.Text = if card.state == "locked" then "LOCKED / EARN IT" else "EARNED / " .. fx.Source
			end
		end
	end
	m.fxRight.Text = ownedCount .. " / " .. #Config.ShatterFx .. " OWNED"
end

function UI._fxAction(self, card)
	if card.busy or card.state == "equipped" or card.state == "locked" then
		return
	end
	local buying = card.state == "buy"
	card.busy = true
	card.button.setEnabled(false)
	card.button.setText(if buying then "BUYING" else "EQUIPPING")
	task.spawn(function()
		local ok, message = self:_ask("onShop", if buying then "BuyFx" else "EquipFx", card.fx.Id)
		card.busy = false
		if ok and buying then
			self:toast(string.upper(card.fx.Name) .. " FX UNLOCKED", "reward")
		elseif not ok then
			self:toast(message or (if buying then "PURCHASE FAILED" else "COULD NOT EQUIP"), "error")
		end
		self:_refreshFx()
	end)
end

-- HUD -----------------------------------------------------------------------------

function UI._buildHud(self)
	local h = { cells = {}, pips = {} }
	self._hud = h

	local layer = new("Frame", { Name = "Hud", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = self.gui })
	h.layer = layer
	-- Everything that shakes lives in `root`; the layer itself never moves.
	local root = new("Frame", { Name = "Shake", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = layer })
	h.root = root

	-- Balls odometer -------------------------------------------------------
	local plate = new("Frame", {
		Name = "Balls",
		BackgroundColor3 = PAPER,
		BackgroundTransparency = 0.1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, EDGE - 4),
		Size = UDim2.fromOffset(176, 92),
		Parent = root,
	})
	fit(plate, HUD_SCALE)
	h.plateStroke = stroke(plate, 1.5)
	h.alarm = new("Frame", { Name = "Alarm", BackgroundColor3 = DANGER, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = plate })
	cropMarks(plate, 6, 3)
	local chip = new("Frame", { Position = UDim2.fromOffset(8, 6), Size = UDim2.fromOffset(5, 5), Parent = plate })
	setAccent(chip, "BackgroundColor3")
	text({ Text = "BALLS", TextSize = 9, Position = UDim2.fromOffset(17, 2), Size = UDim2.fromOffset(80, 12), Parent = plate })
	text({ Text = "01", TextSize = 8, TextColor3 = GREY, TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.new(1, -48, 0, 2), Size = UDim2.fromOffset(40, 12), Parent = plate })

	local digits = new("Frame", { Name = "Digits", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 16), Size = UDim2.fromOffset(160, 44), Parent = plate })
	h.bump = new("UIScale", { Parent = digits })
	for i = 1, 4 do
		local cell = new("Frame", {
			Name = "Cell" .. i,
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Position = UDim2.fromOffset((i - 1) * 40, 0),
			Size = UDim2.fromOffset(40, 44),
			Parent = digits,
		})
		if i > 1 then
			rule(cell, { Size = UDim2.new(0, 1, 1, -8), Position = UDim2.fromOffset(0, 4), BackgroundTransparency = 0.82 })
		end
		local label = capText(text({
			Text = "0",
			Font = FONT_NUM,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTransparency = 0.82,
			Size = UDim2.fromScale(1, 1),
			Parent = cell,
		}), 34, 10)
		h.cells[i] = { label = label, char = "0" }
	end
	rule(plate, { Position = UDim2.fromOffset(8, 62), Size = UDim2.new(1, -16, 0, 1), BackgroundTransparency = 0.6 })

	-- Multiball pips + streak bar
	text({ Text = "MULTI", TextSize = 9, Position = UDim2.fromOffset(8, 65), Size = UDim2.fromOffset(44, 16), Parent = plate })
	for i = 1, Config.MAX_MULTIBALL do
		local pip = new("Frame", {
			Name = "Pip" .. i,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(60 + (i - 1) * 16, 73),
			Size = UDim2.fromOffset(11, 11),
			Parent = plate,
		})
		setAccent(pip, "BackgroundColor3")
		stroke(pip, 1)
		h.pips[i] = pip
	end
	h.level = capText(text({
		Text = "x1",
		Font = FONT_NUM,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 65),
		Size = UDim2.fromOffset(36, 16),
		Parent = plate,
	}), 12, 7)
	local track = new("Frame", { BackgroundColor3 = INK, BackgroundTransparency = 0.82, Position = UDim2.fromOffset(8, 84), Size = UDim2.new(1, -16, 0, 3), Parent = plate })
	h.streak = new("Frame", { Size = UDim2.fromScale(0, 1), Parent = track })
	setAccent(h.streak, "BackgroundColor3")

	-- Zone (top-left) -------------------------------------------------------
	local zone = new("Frame", { Name = "Zone", BackgroundColor3 = PAPER, BackgroundTransparency = 0.1, Position = UDim2.fromOffset(EDGE, EDGE - 4), Size = UDim2.fromOffset(88, 46), Parent = root })
	fit(zone, HUD_SCALE)
	stroke(zone, 1.5)
	local zoneBar = new("Frame", { Size = UDim2.new(0, 4, 1, 0), Parent = zone })
	setAccent(zoneBar, "BackgroundColor3")
	notch(zone, 9, 1, 0, INK)
	text({ Text = "03 / ZONE", TextSize = 8, Position = UDim2.fromOffset(12, 3), Size = UDim2.fromOffset(70, 10), Parent = zone })
	h.zone = capText(text({ Text = "00", Font = FONT_NUM, Position = UDim2.fromOffset(12, 14), Size = UDim2.fromOffset(70, 28), Parent = zone }), 22, 9)

	-- Distance + ruler (top-right) -----------------------------------------
	local dist = new("Frame", {
		Name = "Distance",
		BackgroundColor3 = PAPER,
		BackgroundTransparency = 0.1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -EDGE, 0, EDGE - 4),
		Size = UDim2.fromOffset(150, 62),
		Parent = root,
	})
	fit(dist, HUD_SCALE)
	stroke(dist, 1.5)
	text({ Text = "02 / DISTANCE", TextSize = 8, Position = UDim2.fromOffset(8, 3), Size = UDim2.fromOffset(120, 10), Parent = dist })
	h.meters = capText(text({
		Text = "0",
		Font = FONT_NUM,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromOffset(8, 13),
		Size = UDim2.fromOffset(116, 26),
		Parent = dist,
	}), 22, 9)
	text({ Text = "M", TextSize = 11, TextYAlignment = Enum.TextYAlignment.Bottom, Position = UDim2.fromOffset(128, 13), Size = UDim2.fromOffset(14, 22), Parent = dist })
	local ruler = new("Frame", { Name = "Ruler", BackgroundTransparency = 1, ClipsDescendants = true, Position = UDim2.fromOffset(8, 43), Size = UDim2.fromOffset(134, 14), Parent = dist })
	h.tickPx, h.tickPeriod = 6, 30
	h.ticks = new("Frame", { Name = "Ticks", BackgroundTransparency = 1, Size = UDim2.fromOffset(134 + 36, 14), Parent = ruler })
	rulerTicks(h.ticks, 134 + 36, 12, h.tickPx, 5, 0)
	rule(ruler, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) })
	local marker = new("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0, 2, 1, 0), Parent = ruler })
	setAccent(marker, "BackgroundColor3")

	-- Ball pack (bottom-right) ---------------------------------------------
	local pack = Config.Products.BallPack
	if pack.Id ~= 0 then
		local buy = hardButton(root, {
			Name = "BallPack",
			Fill = "accent",
			Text = "+" .. pack.Balls .. " BALLS",
			TextSize = 12,
			Sub = "",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -EDGE, 1, -EDGE),
			Size = UDim2.fromOffset(122, 52),
			OnClick = function()
				self:_fire("onBuyProduct", "BallPack")
			end,
		})
		fit(buy.holder)
		withPrice(pack.Id, Enum.InfoType.Product, function(price)
			buy.sub.Text = "R$ " .. commas(price)
		end)
	end
end

function UI._setDigits(self, balls, rising)
	local h = self._hud
	local s = string.format("%04d", math.clamp(balls, 0, 9999))
	local firstSignificant = 4
	for i = 1, 4 do
		if string.sub(s, i, i) ~= "0" then
			firstSignificant = i
			break
		end
	end
	for i, cell in h.cells do
		local char = string.sub(s, i, i)
		if char ~= cell.char then
			cell.char = char
			cell.label.Text = char
			cell.label.Position = UDim2.fromOffset(0, if rising then 16 else -16)
			tween(cell.label, 0.18, { Position = UDim2.new() })
		end
		cell.label.TextTransparency = if i < firstSignificant then 0.82 else 0
	end
end

function UI._setLow(self, low)
	local h = self._hud
	if h.pulse then
		h.pulse:Cancel()
		h.pulse = nil
	end
	for _, cell in h.cells do
		cell.label.TextColor3 = if low then DANGER else INK
	end
	h.plateStroke.Color = if low then DANGER else INK
	h.alarm.BackgroundTransparency = 1
	if low then
		h.pulse = TweenService:Create(
			h.alarm,
			TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.78 }
		)
		h.pulse:Play()
	end
end

-- Game over ---------------------------------------------------------------------------

function UI._buildGameOver(self)
	local g = {}
	self._over = g

	local root = new("Frame", { Name = "GameOver", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = self.gui })
	g.root = root
	g.wash = bleed(root, { Name = "Wash", BackgroundColor3 = PAPER, BackgroundTransparency = 0.35 })
	blueprintGrid(root, 12, 8, 0.9)

	local sheet = new("Frame", {
		Name = "Sheet",
		BackgroundColor3 = PAPER,
		BackgroundTransparency = 0.02,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0.05, 0, 0.5, 0),
		Size = UDim2.fromOffset(540, 282),
		Parent = root,
	})
	fit(sheet)
	stroke(sheet, 1.5)
	cropMarks(sheet, 10, 5)
	notch(sheet, 16, 1, 1, INK)
	g.sheet = sheet

	local header = new("Frame", { Name = "Header", BackgroundColor3 = INK, Size = UDim2.new(1, 0, 0, 24), Parent = sheet })
	text({ Text = "04 / RUN REPORT", TextSize = 9, TextColor3 = PAPER, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.5, 0, 1, 0), Parent = header })
	setAccent(text({
		Text = "SHATTER RUN / GLASS LAB",
		TextSize = 9,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.new(0.5, -10, 1, 0),
		Parent = header,
	}), "TextColor3")

	-- Left: the measurement
	text({ Text = "DISTANCE / METERS", TextSize = 9, TextColor3 = GREY, Position = UDim2.fromOffset(12, 32), Size = UDim2.fromOffset(200, 12), Parent = sheet })
	local numberRow = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 44), Size = UDim2.fromOffset(300, 60), Parent = sheet })
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = numberRow,
	})
	g.distance = text({
		Text = "0",
		Font = FONT_NUM,
		TextSize = 48,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 60),
		LayoutOrder = 1,
		Parent = numberRow,
	})
	text({ Text = "M", TextSize = 16, TextYAlignment = Enum.TextYAlignment.Bottom, Size = UDim2.fromOffset(16, 46), LayoutOrder = 2, Parent = numberRow })

	-- Ruler: scale from 0 to a bit past max(run, best) with markers for both.
	local ruler = new("Frame", { Name = "Ruler", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 118), Size = UDim2.fromOffset(300, 30), Parent = sheet })
	local tickBand = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 8), Size = UDim2.fromOffset(300, 12), Parent = ruler })
	rulerTicks(tickBand, 300, 12, 15, 5, 0.2)
	rule(tickBand, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) })
	g.scaleLabels = {}
	for i = 0, 4 do
		g.scaleLabels[i] = text({
			Text = "0",
			TextSize = 7,
			TextColor3 = GREY,
			TextXAlignment = if i == 4 then Enum.TextXAlignment.Right elseif i == 0 then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(if i == 4 then 1 elseif i == 0 then 0 else 0.5, 0),
			Position = UDim2.new(i / 4, 0, 0, 21),
			Size = UDim2.fromOffset(50, 9),
			Parent = ruler,
		})
	end
	g.bestMarker = new("Frame", { BackgroundColor3 = INK, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0, 0), Size = UDim2.fromOffset(1, 20), Parent = ruler })
	text({ Text = "BEST", TextSize = 7, AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromOffset(3, -2), Size = UDim2.fromOffset(30, 8), Parent = g.bestMarker })
	g.runMarker = new("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0, 0), Size = UDim2.fromOffset(3, 20), Parent = ruler })
	setAccent(g.runMarker, "BackgroundColor3")

	-- Data table
	local function dataRow(y, label, withGem)
		rule(sheet, { Position = UDim2.fromOffset(12, y), Size = UDim2.fromOffset(300, 1), BackgroundTransparency = 0.6 })
		local x = 12
		if withGem then
			gemIcon(sheet, 7, UDim2.fromOffset(17, y + 14))
			x = 26
		end
		text({ Text = label, TextSize = 9, Position = UDim2.fromOffset(x, y + 1), Size = UDim2.fromOffset(150, 26), Parent = sheet })
		return capText(text({
			Text = "0",
			Font = FONT_NUM,
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.fromOffset(162, y + 4),
			Size = UDim2.fromOffset(150, 20),
			Parent = sheet,
		}), 13, 8)
	end
	g.best = dataRow(162, "BEST")
	g.gems = dataRow(190, "GEMS EARNED", true)
	rule(sheet, { Position = UDim2.fromOffset(12, 218), Size = UDim2.fromOffset(300, 1), BackgroundTransparency = 0.6 })

	-- XP tally: filled in when the server's RunSummary arrives.
	text({ Text = "XP EARNED", TextSize = 9, Position = UDim2.fromOffset(12, 219), Size = UDim2.fromOffset(100, 26), Parent = sheet })
	g.xpValue = capText(text({
		Text = "TALLYING...",
		Font = FONT_NUM,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromOffset(192, 223),
		Size = UDim2.fromOffset(120, 20),
		Parent = sheet,
	}), 13, 7)
	g.xpLevel = capText(text({ Text = "LV 01", Font = FONT_NUM, Position = UDim2.fromOffset(12, 246), Size = UDim2.fromOffset(44, 12), Parent = sheet }), 9, 6)
	local _, xpFill = meter(sheet, { Position = UDim2.fromOffset(60, 250), Size = UDim2.fromOffset(252, 5) })
	g.xpFill = xpFill
	g.xpProgress = text({ Text = "", TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(60, 258), Size = UDim2.fromOffset(130, 10), Parent = sheet })
	g.xpMissions = text({
		Text = "",
		TextSize = 8,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromOffset(190, 258),
		Size = UDim2.fromOffset(122, 10),
		Parent = sheet,
	})
	rule(sheet, { Position = UDim2.fromOffset(12, 272), Size = UDim2.fromOffset(300, 1), BackgroundTransparency = 0.6 })
	g.levelStamp = stamp(sheet, "LEVEL UP", { Position = UDim2.fromOffset(148, 232), Size = UDim2.fromOffset(84, 22), Rotation = -6, Visible = false }, "accent")
	g.levelStampScale = new("UIScale", { Parent = g.levelStamp })

	-- NEW BEST rubber stamp
	local stamp = new("Frame", {
		Name = "NewBest",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(262, 52),
		Size = UDim2.fromOffset(112, 32),
		Rotation = -9,
		Visible = false,
		Parent = sheet,
	})
	setAccent(stamp, "BackgroundColor3")
	stroke(stamp, 2)
	rule(stamp, { Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 0, 1) })
	rule(stamp, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 4, 1, -4), Size = UDim2.new(1, -8, 0, 1) })
	capText(text({ Text = "NEW BEST", Font = FONT_NUM, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = stamp }), 13, 8)
	g.stamp = stamp
	g.stampScale = new("UIScale", { Parent = stamp })

	-- Divider + right column: actions
	rule(sheet, { Position = UDim2.fromOffset(328, 34), Size = UDim2.new(0, 1, 1, -44), BackgroundTransparency = 0.4 })
	text({ Text = "05 / NEXT", TextSize = 9, TextColor3 = GREY, Position = UDim2.fromOffset(340, 32), Size = UDim2.fromOffset(188, 12), Parent = sheet })
	local actions = new("Frame", { Name = "Actions", BackgroundTransparency = 1, Position = UDim2.fromOffset(340, 48), Size = UDim2.fromOffset(188, 180), Parent = sheet })
	list(actions, 6)

	local revive = Config.Products.Revive
	local reviveGroup = new("Frame", { Name = "Revive", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 64), LayoutOrder = 1, Visible = false, Parent = actions })
	g.reviveButton = hardButton(reviveGroup, {
		Name = "ReviveButton",
		Fill = "danger",
		Text = "REVIVE +" .. revive.Balls .. " BALLS",
		TextSize = 11,
		Sub = "",
		Size = UDim2.new(1, 0, 0, 52),
		OnClick = function()
			local now = os.clock()
			if now - (g.lastRevive or 0) > 0.6 then
				g.lastRevive = now
				self:_fire("onRevive")
			end
		end,
	})
	hatch(g.reviveButton.face, { AnchorPoint = Vector2.new(1, 0), Size = UDim2.new(0, 14, 1, 0), Position = UDim2.fromScale(1, 0) }, PAPER, 0.55, 3)
	local reviveTrack = new("Frame", { BackgroundColor3 = INK, BackgroundTransparency = 0.82, Position = UDim2.fromOffset(0, 56), Size = UDim2.new(1, -SHADOW, 0, 5), Parent = reviveGroup })
	g.reviveBar = new("Frame", { BackgroundColor3 = DANGER, Size = UDim2.fromScale(1, 1), Parent = reviveTrack })
	g.reviveGroup = reviveGroup
	withPrice(revive.Id, Enum.InfoType.Product, function(price)
		g.reviveButton.sub.Text = "R$ " .. commas(price)
	end)

	hardButton(actions, {
		Name = "PlayAgain",
		Fill = "accent",
		Text = "PLAY AGAIN",
		TextSize = 14,
		Size = UDim2.new(1, 0, 0, 54),
		LayoutOrder = 2,
		OnClick = function()
			self:_fire("onPlayAgain")
		end,
	})
	hardButton(actions, {
		Name = "Menu",
		Fill = "paper",
		Text = "MENU",
		TextSize = 12,
		Size = UDim2.new(1, 0, 0, 48),
		LayoutOrder = 3,
		OnClick = function()
			self:_fire("onMenu")
		end,
	})
end

-- Toasts and zone card ------------------------------------------------------------------

function UI._buildToasts(self)
	local layer = new("Frame", { Name = "Toasts", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = self.gui })

	local stack = new("Frame", { Name = "Stack", BackgroundTransparency = 1, Position = UDim2.fromScale(0, 0.32), Size = UDim2.fromOffset(270, 160), Parent = layer })
	fit(stack, HUD_SCALE)
	list(stack, 6)
	self._toastStack = stack

	-- Checkpoint title card
	local card = new("CanvasGroup", {
		Name = "ZoneCard",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.24),
		Size = UDim2.fromOffset(360, 106),
		GroupTransparency = 1,
		Visible = false,
		Parent = layer,
	})
	fit(card, HUD_SCALE)
	local label = text({ Text = "CHECKPOINT", TextSize = 10, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromOffset(110, 14), Parent = card })
	label.BackgroundTransparency = 0.1
	label.BackgroundColor3 = PAPER
	local ruleLeft = rule(card, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(0.5, -60, 0, 7), Size = UDim2.fromOffset(0, 1) })
	local ruleRight = rule(card, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0.5, 60, 0, 7), Size = UDim2.fromOffset(0, 1) })
	local slab = new("Frame", { BackgroundColor3 = PAPER, BackgroundTransparency = 0.08, Position = UDim2.fromOffset(2, 18), Size = UDim2.new(1, -4, 0, 58), Parent = card })
	stroke(slab, 1.5)
	brackets(slab, 8, 2)
	local title = capText(text({
		Text = "",
		Font = FONT_NUM,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(12, 4),
		Size = UDim2.new(1, -24, 1, -8),
		Parent = slab,
	}), 40, 12)
	local bar = new("Frame", { Position = UDim2.fromOffset(0, 80), Size = UDim2.new(0, 0, 0, 5), Parent = card })
	setAccent(bar, "BackgroundColor3")
	-- Optional reward line under the bar (level ups).
	local sub = text({
		Text = "",
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Center,
		BackgroundTransparency = 0.1,
		BackgroundColor3 = PAPER,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 89),
		Size = UDim2.fromOffset(300, 15),
		Visible = false,
		Parent = card,
	})
	self._zoneCard = { card = card, label = label, title = title, sub = sub, ruleLeft = ruleLeft, ruleRight = ruleRight, bar = bar }
end

function UI._showZoneCard(self, value, heading, subline, duration)
	local z = self._zoneCard
	local token = {}
	z.token = token
	local holdTime = duration or ZONE_CARD_TIME
	z.label.Text = heading or "CHECKPOINT"
	z.sub.Text = subline or ""
	z.sub.Visible = subline ~= nil and subline ~= ""
	z.title.Text = string.upper(value)
	z.card.Visible = true
	z.card.GroupTransparency = 1
	z.card.Position = UDim2.new(0.5, 0, 0.24, 12)
	z.ruleLeft.Size = UDim2.fromOffset(0, 1)
	z.ruleRight.Size = UDim2.fromOffset(0, 1)
	z.bar.Size = UDim2.new(0, 0, 0, 5)
	tween(z.card, 0.3, { GroupTransparency = 0, Position = UDim2.fromScale(0.5, 0.24) })
	tween(z.ruleLeft, 0.35, { Size = UDim2.fromOffset(120, 1) })
	tween(z.ruleRight, 0.35, { Size = UDim2.fromOffset(120, 1) })
	tween(z.bar, holdTime, { Size = UDim2.new(1, 0, 0, 5) }, Enum.EasingStyle.Linear)
	task.delay(holdTime, function()
		if z.token ~= token then
			return
		end
		tween(z.card, 0.25, { GroupTransparency = 1, Position = UDim2.new(0.5, 0, 0.24, -10) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
		task.delay(0.26, function()
			if z.token == token then
				z.card.Visible = false
			end
		end)
	end)
end

function UI._dismissToast(self, toast)
	if toast.gone then
		return
	end
	toast.gone = true
	local index = table.find(self._toasts, toast)
	if index then
		table.remove(self._toasts, index)
	end
	tween(toast.card, 0.2, { Position = UDim2.new(-1, 0, 0, 0), GroupTransparency = 1 }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	task.delay(0.21, function()
		toast.holder:Destroy()
	end)
end

-- Damage vignette ---------------------------------------------------------------------

function UI._buildFx(self)
	local layer = new("Frame", { Name = "Fx", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = self.gui })
	self._vignette = {}
	local fade = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.35, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	-- { size, position, gradient rotation (0 = opaque end first), bleed size, bleed position }
	local edges = {
		{ UDim2.new(1, 0, 0.22, 0), UDim2.new(), 90, UDim2.new(1, 400, 0, 200), UDim2.fromOffset(-200, -200) },
		{ UDim2.new(1, 0, 0.22, 0), UDim2.fromScale(0, 0.78), -90, UDim2.new(1, 400, 0, 200), UDim2.new(0, -200, 1, 0) },
		{ UDim2.new(0.14, 0, 1, 0), UDim2.new(), 0, UDim2.new(0, 200, 1, 0), UDim2.fromOffset(-200, 0) },
		{ UDim2.new(0.14, 0, 1, 0), UDim2.fromScale(0.86, 0), 180, UDim2.new(0, 200, 1, 0), UDim2.new(1, 0, 0, 0) },
	}
	for _, edge in edges do
		local frame = new("Frame", { BackgroundColor3 = DANGER, BackgroundTransparency = 1, Size = edge[1], Position = edge[2], Parent = layer })
		new("UIGradient", { Rotation = edge[3], Transparency = fade, Parent = frame })
		table.insert(self._vignette, frame)
		local outside = new("Frame", { BackgroundColor3 = DANGER, BackgroundTransparency = 1, Size = edge[4], Position = edge[5], Parent = layer })
		table.insert(self._vignette, outside)
	end
end

function UI._shake(self, target, strength)
	local token = {}
	self._shakeToken = token
	task.spawn(function()
		for step = 1, 6 do
			if self._shakeToken ~= token then
				return
			end
			local magnitude = strength * (7 - step) / 6
			tween(target, 0.035, {
				Position = UDim2.fromOffset(rng:NextNumber(-magnitude, magnitude), rng:NextNumber(-magnitude, magnitude)),
			}, Enum.EasingStyle.Sine)
			task.wait(0.035)
		end
		if self._shakeToken == token then
			tween(target, 0.08, { Position = UDim2.new() }, Enum.EasingStyle.Sine)
		end
	end)
end

-- Callback plumbing ------------------------------------------------------------------

-- Fire-and-forget callbacks run in their own thread so errors keep their stack trace.
function UI._fire(self, name, ...)
	local callback = self._callbacks[name]
	if type(callback) == "function" then
		task.spawn(callback, ...)
	end
end

-- Yielding callbacks that answer (ok, message). Errors count as a failure.
function UI._ask(self, name, ...)
	local callback = self._callbacks[name]
	if type(callback) ~= "function" then
		return false, nil
	end
	local results = table.pack(pcall(callback, ...))
	if not results[1] then
		warn("[UI] " .. name .. " failed:", results[2])
		return false, nil
	end
	local message = results[3]
	return results[2] == true, if type(message) == "string" then message else nil
end

function UI._refreshAll(self)
	self:_refreshStats()
	self:_refreshLevel()
	self:_refreshDaily()
	self:_refreshCountdowns()
	self:_rebuildTopRuns()
	self:_rebuildPasses()
	self:_rebuildZones()
	self:_rebuildMissions()
	self:_rebuildSeason()
	self:_refreshStarter()
	self:_refreshSkins()
	self:_refreshFx()
end

-- Public API ---------------------------------------------------------------------------

function UI.new(callbacks)
	local self = setmetatable({}, UI)
	self._callbacks = callbacks or {}
	self._alive = true
	self._toasts = {}
	self._toastSerial = 0
	self._connections = {}
	self._menuOpens = 0

	local playerGui = player:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("ShatterRunUI")
	if old then
		old:Destroy()
	end

	self.gui = new("ScreenGui", {
		Name = "ShatterRunUI",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
		DisplayOrder = 10,
	})

	-- Back to front.
	self:_buildMenu()
	self:_buildHud()
	self:_buildGameOver()
	self:_buildToasts()
	self:_buildFx()
	self:_selectTab(1)

	self.gui.Parent = playerGui

	local function refit()
		local size = self.gui.AbsoluteSize
		if size.X < 1 or size.Y < 1 then
			return
		end
		currentScale = math.clamp(math.min(size.X / REF_W, size.Y / REF_H), SCALE_MIN, SCALE_MAX)
		for _, entry in scalers do
			entry[1].Scale = currentScale * entry[2]
		end
		local live = {}
		for _, entry in textCaps do
			if entry[1].Parent then
				applyCap(entry)
				table.insert(live, entry)
			end
		end
		textCaps = live
	end
	refit()

	local function connect(signal, handler)
		table.insert(self._connections, signal:Connect(handler))
	end
	connect(self.gui:GetPropertyChangedSignal("AbsoluteSize"), refit)

	-- Live data. Attributes can arrive after the UI exists; every reader handles nil.
	local function onAttribute(name, handler)
		connect(player:GetAttributeChangedSignal(name), handler)
	end
	onAttribute("Best", function()
		self:_refreshStats()
	end)
	onAttribute("Gems", function()
		self:_refreshStats()
	end)
	onAttribute("Checkpoint", function()
		self:_rebuildZones()
	end)
	onAttribute("EquippedSkin", function()
		self:_refreshSkins()
	end)
	onAttribute("OwnedSkins", function()
		self:_refreshSkins()
	end)
	for _, name in { "NextDaily", "StreakDay", "StreakExpires" } do
		onAttribute(name, function()
			self:_refreshDaily()
		end)
	end
	for _, name in { "Level", "XP", "XPNeeded" } do
		onAttribute(name, function()
			self:_refreshLevel()
		end)
	end
	for _, name in { "Missions", "MissionRerolls" } do
		onAttribute(name, function()
			self:_rebuildMissions()
		end)
	end
	onAttribute("MissionsReset", function()
		self:_refreshCountdowns()
	end)
	for _, name in { "SeasonTier", "SeasonClaimed", "SeasonPremium", "SeasonId" } do
		onAttribute(name, function()
			self:_rebuildSeason()
		end)
	end
	onAttribute("SeasonXP", function()
		self:_refreshSeasonProgress()
	end)
	for _, name in { "OwnedFx", "EquippedFx" } do
		onAttribute(name, function()
			self:_refreshFx()
		end)
	end
	onAttribute("StarterPackBought", function()
		self:_refreshStarter()
	end)
	onAttribute("BonusBalls", function()
		self:_refreshStats()
	end)
	for _, name in { "SeasonName", "SeasonEnds" } do
		connect(ReplicatedStorage:GetAttributeChangedSignal(name), function()
			self:_refreshSeasonProgress()
			self:_refreshCountdowns()
		end)
	end
	for _, key in PASS_ORDER do
		onAttribute("Pass_" .. key, function()
			self:_rebuildPasses()
			if key == "Checkpoints" then
				self:_rebuildZones()
			end
		end)
	end
	connect(ReplicatedStorage:GetAttributeChangedSignal("TopRuns"), function()
		self:_rebuildTopRuns()
	end)

	connect(self.gui.Destroying, function()
		self._alive = false
		for _, connection in self._connections do
			connection:Disconnect()
		end
	end)

	-- One shared 1s tick drives every countdown, and only while the menu is open.
	task.spawn(function()
		while self._alive do
			if self._menu.root.Visible then
				self:_refreshDaily()
				self:_refreshCountdowns()
			end
			task.wait(1)
		end
	end)

	self:_refreshAll()
	return self
end

function UI:showMenu()
	self:hideRevive()
	self._hud.layer.Visible = false
	self._over.root.Visible = false

	local m = self._menu
	m.root.Visible = true
	self._menuOpens += 1
	self:_refreshAll()
	self:_maybeShowOffer()

	m.left.Position = UDim2.new(0, EDGE - 16, 0.5, 0)
	tween(m.left, 0.35, { Position = UDim2.new(0, EDGE + 4, 0.5, 0) })
	m.panel.Position = UDim2.new(1, -(EDGE - 20), 0.5, 0)
	tween(m.panel, 0.35, { Position = UDim2.new(1, -(EDGE + 4), 0.5, 0) })
	local play = m.play.face
	play.Position = UDim2.fromOffset(2, 2)
	tween(play, 0.3, { Position = UDim2.new() }, Enum.EasingStyle.Back)
end

function UI:showHud()
	self:hideRevive()
	self:_closeModal()
	self._menu.root.Visible = false
	self._over.root.Visible = false
	self._hud.layer.Visible = true
end

function UI:setHud(state)
	local h = self._hud
	if type(state) ~= "table" then
		return
	end

	local balls = math.max(0, math.floor(tonumber(state.balls) or 0))
	if balls ~= h.balls then
		local previous = h.balls
		h.balls = balls
		self:_setDigits(balls, previous == nil or balls > previous)
		if previous ~= nil and balls > previous then
			h.bump.Scale = 1.16
			tween(h.bump, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		local low = balls <= LOW_BALLS
		if low ~= h.low then
			h.low = low
			self:_setLow(low)
		end
	end

	local level = math.clamp(math.floor(tonumber(state.multiball) or 1), 1, #h.pips)
	if level ~= h.levelValue then
		local previous = h.levelValue
		h.levelValue = level
		h.level.Text = "x" .. level
		for i, pip in h.pips do
			pip.BackgroundTransparency = if i <= level then 0 else 1
		end
		if previous and level > previous then
			local pip = h.pips[level]
			pip.Size = UDim2.fromOffset(17, 17)
			tween(pip, 0.25, { Size = UDim2.fromOffset(11, 11) }, Enum.EasingStyle.Back)
		end
	end

	local streak = math.floor(math.clamp(tonumber(state.streak) or 0, 0, 1) * 100 + 0.5) / 100
	if streak ~= h.streakValue then
		h.streakValue = streak
		tween(h.streak, 0.15, { Size = UDim2.fromScale(streak, 1) })
	end

	local meters = math.max(0, tonumber(state.meters) or 0)
	local whole = math.floor(meters)
	if whole ~= h.metersValue then
		h.metersValue = whole
		h.meters.Text = commas(whole)
	end
	local offset = -math.floor((meters * h.tickPx) % h.tickPeriod + 0.5)
	if offset ~= h.tickOffset then
		h.tickOffset = offset
		h.ticks.Position = UDim2.fromOffset(offset, 0)
	end

	local zone = math.floor(tonumber(state.zone) or 0)
	if zone ~= h.zoneValue then
		h.zoneValue = zone
		h.zone.Text = twoDigits(zone)
	end
end

function UI:showGameOver(info)
	info = info or {}
	local g = self._over
	self._hud.layer.Visible = false
	self._menu.root.Visible = false
	g.root.Visible = true

	local meters = math.max(0, math.floor(tonumber(info.meters) or 0))
	local best = math.max(meters, math.floor(tonumber(info.best) or 0))

	g.wash.BackgroundTransparency = 1
	tween(g.wash, 0.3, { BackgroundTransparency = 0.35 })
	g.sheet.Position = UDim2.new(0.05, -24, 0.5, 0)
	tween(g.sheet, 0.35, { Position = UDim2.new(0.05, 0, 0.5, 0) })

	-- Count the distance up and slide the run marker along the ruler with it.
	local span = math.max(best, 1) * 1.15
	for i, label in g.scaleLabels do
		label.Text = commas(span * i / 4)
	end
	g.bestMarker.Position = UDim2.fromScale(best / span, 0)
	g.runMarker.Position = UDim2.fromScale(0, 0)
	tween(g.runMarker, 0.7, { Position = UDim2.fromScale(meters / span, 0) })
	if g.counter then
		g.counter:Destroy()
	end
	local counter = Instance.new("NumberValue")
	g.counter = counter
	counter.Changed:Connect(function(value)
		g.distance.Text = commas(value)
	end)
	g.distance.Text = "0"
	tween(counter, 0.7, { Value = meters })

	g.best.Text = commas(best) .. " M"
	g.gems.Text = "+" .. commas(info.gemsEarned or 0)

	-- XP line waits for the server's RunSummary (see showProgress).
	local level, xp, needed = levelInfo()
	local token = {}
	g.summaryToken = token
	g.xpToken = nil
	g.xpValue.Text = "TALLYING..."
	g.xpLevel.Text = "LV " .. twoDigits(level)
	g.xpFill.Size = UDim2.fromScale(xp / needed, 1)
	g.xpProgress.Text = commas(xp) .. " / " .. commas(needed) .. " XP"
	g.xpMissions.Text = ""
	g.levelStamp.Visible = false
	if g.xpCounter then
		g.xpCounter:Destroy()
		g.xpCounter = nil
	end
	task.delay(SUMMARY_TIMEOUT, function()
		if g.summaryToken == token then
			g.xpValue.Text = "--" -- still accepted if it shows up later
		end
	end)

	g.stamp.Visible = info.isNewBest == true
	if info.isNewBest then
		g.stampScale.Scale = 1.8
		g.stamp.Rotation = -18
		task.delay(0.5, function()
			if g.stamp.Visible then
				tween(g.stampScale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
				tween(g.stamp, 0.22, { Rotation = -9 }, Enum.EasingStyle.Back)
			end
		end)
	end

	self:hideRevive()
	if info.canRevive and Config.Products.Revive.Id ~= 0 then
		g.reviveGroup.Visible = true
		g.reviveBar.Size = UDim2.fromScale(1, 1)
		local countdown = TweenService:Create(
			g.reviveBar,
			TweenInfo.new(Config.REVIVE_SECONDS, Enum.EasingStyle.Linear),
			{ Size = UDim2.fromScale(0, 1) }
		)
		g.reviveTween = countdown
		countdown.Completed:Connect(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed and g.reviveTween == countdown then
				self:hideRevive()
			end
		end)
		countdown:Play()
	end
end

function UI:hideRevive()
	local g = self._over
	local countdown = g.reviveTween
	g.reviveTween = nil
	if countdown then
		countdown:Cancel()
	end
	g.reviveGroup.Visible = false
end

function UI:toast(value, kind)
	value = string.upper(tostring(value or ""))
	kind = kind or "info"
	if kind == "checkpoint" then
		self:_showZoneCard(value)
		return
	end
	local style = TOAST_KINDS[kind] or TOAST_KINDS.info

	while #self._toasts >= MAX_TOASTS do
		self:_dismissToast(self._toasts[1])
	end

	self._toastSerial += 1
	local holder = new("Frame", {
		Name = "Toast",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = self._toastSerial,
		Parent = self._toastStack,
	})
	local card = new("CanvasGroup", {
		BackgroundTransparency = 1,
		Position = UDim2.new(-1, 0, 0, 0),
		Size = UDim2.new(1, -12, 1, 0),
		Parent = holder,
	})
	new("Frame", { BackgroundColor3 = INK, Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -4, 1, -4), Parent = card })
	local face = new("Frame", { BackgroundColor3 = PAPER, Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -5, 1, -5), Parent = card })
	stroke(face, 1)
	if style.hatch then
		hatch(face, { Size = UDim2.new(0, 6, 1, 0) }, INK, 0, 3)
	else
		local bar = new("Frame", { BackgroundColor3 = INK, Size = UDim2.new(0, 5, 1, 0), Parent = face })
		if style.accent then
			setAccent(bar, "BackgroundColor3")
		end
	end
	text({ Text = style.tag, TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(14, 3), Size = UDim2.new(1, -20, 0, 10), Parent = face })
	capText(text({
		Text = value,
		Font = FONT_NUM,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.new(1, -20, 0, 22),
		Parent = face,
	}), 13, 7)

	local toast = { holder = holder, card = card }
	table.insert(self._toasts, toast)
	card.Position = UDim2.new(-1, 0, 0, 0)
	tween(card, 0.3, { Position = UDim2.fromOffset(EDGE, 0) })
	task.delay(TOAST_TIME, function()
		self:_dismissToast(toast)
	end)
end

function UI:flashDamage()
	for _, frame in self._vignette do
		frame.BackgroundTransparency = 0.05
		tween(frame, 0.45, { BackgroundTransparency = 1 })
	end
	self:_shake(self._hud.root, 7)
end

function UI:setTheme(theme)
	if type(theme) ~= "table" or typeof(theme.Accent) ~= "Color3" then
		return
	end
	accentColor = theme.Accent
	for inst, prop in accentTargets do
		if inst.Parent == nil then
			accentTargets[inst] = nil
		else
			tween(inst, 0.35, { [prop] = accentColor })
		end
	end
end

function UI:isMenuOpen()
	return self._menu.root.Visible
end

-- Fills in the run report's XP line from the server's RunSummary.
function UI._applyRunSummary(self, event)
	local g = self._over
	if not g.root.Visible or g.summaryToken == nil then
		return -- report already closed (or this summary was for an earlier death)
	end
	local token = {}
	g.summaryToken = nil
	g.xpToken = token

	local gained = math.max(0, math.floor(tonumber(event.xp) or 0))
	local before = math.max(1, math.floor(tonumber(event.levelBefore) or 1))
	local after = math.max(before, math.floor(tonumber(event.levelAfter) or before))
	local missionsDone = math.max(0, math.floor(tonumber(event.missionsCompleted) or 0))
	if tonumber(event.gems) then
		g.gems.Text = "+" .. commas(event.gems)
	end
	g.xpMissions.Text = if missionsDone > 0
		then "+" .. missionsDone .. (if missionsDone == 1 then " MISSION DONE" else " MISSIONS DONE")
		else ""

	local counter = Instance.new("NumberValue")
	g.xpCounter = counter
	counter.Changed:Connect(function(value)
		g.xpValue.Text = "+" .. commas(value) .. " XP"
	end)
	g.xpValue.Text = "+0 XP"
	tween(counter, 0.6, { Value = gained })

	local function settle()
		local _, xp, needed = levelInfo()
		g.xpLevel.Text = "LV " .. twoDigits(after)
		g.xpProgress.Text = commas(xp) .. " / " .. commas(needed) .. " XP"
		tween(g.xpFill, 0.5, { Size = UDim2.fromScale(xp / needed, 1) })
	end

	if after > before then
		-- Fill to the end, roll over to the new level, then fill to the current XP.
		tween(g.xpFill, 0.45, { Size = UDim2.fromScale(1, 1) })
		task.delay(0.5, function()
			if g.xpToken ~= token or not g.root.Visible then
				return
			end
			g.xpFill.Size = UDim2.fromScale(0, 1)
			settle()
			g.levelStamp.Visible = true
			g.levelStampScale.Scale = 1.8
			g.levelStamp.Rotation = -14
			tween(g.levelStampScale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
			tween(g.levelStamp, 0.22, { Rotation = -6 }, Enum.EasingStyle.Back)
		end)
	else
		settle()
	end
end

-- Progress events from the server (forwarded by the controller).
function UI:showProgress(event)
	if type(event) ~= "table" then
		return
	end
	local kind = event.type
	if kind == "RunSummary" then
		self:_applyRunSummary(event)
	elseif kind == "LevelUp" then
		local level = math.max(1, math.floor(tonumber(event.level) or 1))
		local parts = {}
		if tonumber(event.gems) and tonumber(event.gems) > 0 then
			table.insert(parts, "+" .. commas(event.gems) .. " GEMS")
		end
		if type(event.unlock) == "table" then
			local unlocked = rewardText(event.unlock)
			if unlocked ~= "" then
				local cosmetic = event.unlock.Skin ~= nil or event.unlock.Fx ~= nil
				table.insert(parts, if cosmetic then unlocked .. " UNLOCKED" else unlocked)
			end
		end
		local subline = table.concat(parts, " / ")
		self:_showZoneCard("LEVEL " .. twoDigits(level), "LEVEL UP", subline, LEVEL_CARD_TIME)
		self:toast("LEVEL " .. twoDigits(level) .. (if subline ~= "" then " / " .. subline else ""), "level")
	elseif kind == "MissionComplete" then
		self:toast("MISSION COMPLETE: " .. tostring(event.text or ""), "reward")
	elseif kind == "SeasonTier" then
		self:toast("SEASON TIER " .. twoDigits(tonumber(event.tier) or 0), "reward")
	elseif kind == "Reward" then
		if event.text ~= nil then
			self:toast(tostring(event.text), "reward")
		end
	end
end

return UI
