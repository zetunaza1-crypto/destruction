--[[
	All on-screen UI: menu, HUD, game over, toasts and damage effects.

	Look: "Glass Lab" technical annotation laid over the world. Paper panels,
	ink hairlines, sharp corners, hard offset shadows, and one accent color that
	follows the current zone theme (see setTheme). Red is reserved for damage
	and revive.

	Layout is drawn on a 600x340 reference sheet. Every block carries a UIScale
	that is refit whenever the screen changes size, so a 640x360 phone and a
	1080p monitor get the same composition.

	Safe area: the ScreenGui uses CoreUISafeInsets, so nothing we draw can sit
	under Roblox's own top bar (menu / chat / "more" buttons, ~58px tall) or a
	phone notch. Full-screen washes still bleed edge to edge (see `bleed`).
	On a 640x360 phone that leaves about 640x302, so the sheet scales to ~0.89
	and every tappable thing is drawn at least 50 units tall (>= 44px there).

	Gamepad: while the last input is a controller, every screen puts the
	selection on its main button (PLAY, PLAY AGAIN / REVIVE, CLAIM...), B closes
	popovers, and small "A SELECT" style hints appear. The HUD clears the
	selection so the controller's buttons go to the game instead of the UI.

	Settings (gear button on the menu and the run report): sliders, toggles and
	a segmented control that write straight to Settings.luau, which every other
	module listens to. The UI itself follows "flashes" (no red flash / pulsing
	alarm / shield burst when off) and "shake" (no HUD shake when off).

	Robux: the server sets the DataLoaded attribute only after the player's save
	really loaded (DataFailed when it couldn't). Until DataLoaded, every Robux
	button is drawn pressed-flat and a tap only explains why, offers that depend
	on the save (starter pack, season premium, revive, gem top-up) stay hidden,
	and a DataFailed banner asks the player to rejoin before buying.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Settings = require(script.Parent.Settings)

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
local TAB_H = 50
local FOOTER_H = 18
local MENU_H = 340 -- height of the left menu column (the full reference sheet)
local ZONE_CARD_Y = 0.3 -- zone / level card top, as a fraction of the screen (clear of the HUD plates)
local BACK_ACTION = "ShatterRunUIBack" -- ContextActionService name for gamepad B (only bound while a popover is open)

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

-- Boosts (picked before a run, shown on the HUD while active).
local BOOST_ORDER = Config.BOOST_ORDER or {}
local MAX_PICKS = Config.MAX_BOOSTS_PER_RUN or 3
local LOW_BALLS_OFFER = Config.LOW_BALLS_OFFER or 8
local BOOST_CHIP_H = 50
local BOOST_CHIP_GAP = 1
local BOOST_POP_H = 110
local POP_CLOSE = 50 -- the popover's X is a 50x50 tap area in its top-right corner
local TOPUP_H = 56
local TOPUP_BUY_W = 84
local TOPUP_CLOSE_W = 50
local SHIELD_USED_HOLD = 0.9 -- seconds the HUD shield plate reads USED after a crash

-- Save state gate for Robux buttons (see the note at the top).
local SAVE_FAILED_TEXT = "YOUR SAVE DIDN'T LOAD - REJOIN BEFORE BUYING"
local SAVE_LOADING_TEXT = "STILL LOADING YOUR SAVE - TRY AGAIN IN A MOMENT"
local SAVE_BANNER_H = 36 -- the DataFailed strip at the bottom of the menu panel
local ROBUX_CALLBACKS = { onBuyProduct = true, onBuyPass = true, onRevive = true }

-- Season premium stops being sold in the last days of a season.
local SEASON_LAST_SALE = 3 * 86400

-- Daily streak: a broken streak's CLAIM asks twice before restarting at day 1,
-- and stays off while a streak saver purchase is on its way.
local RESTART_CONFIRM_TIME = 4 -- seconds the "TAP AGAIN" confirm stays armed
local SAVER_PROMPT_WAIT = 30 -- longest we wait for the Robux prompt to close
local SAVER_GRANT_WAIT = 15 -- after paying, longest we wait for the server to save the streak

-- Settings sheet (drawn on the same 600x340 sheet as everything else).
local SETTINGS_W = 520
local SETTINGS_HEADER = 24
local SETTINGS_BODY_H = 296 -- everything under the header; the body scrolls if the screen is shorter
local SETTINGS_ROW = 50 -- every control is a full 50-unit touch target
local SETTINGS_LABEL_W = 96 -- label column on the left of sliders / graphics
local SETTINGS_PCT_W = 52 -- "100%" readout on the right of sliders
local SETTINGS_GEAR_W = 62 -- the gear button next to DAILY / MENU
local SETTINGS_ACTION = "ShatterRunSettingsAdjust" -- gamepad left/right on a slider (only bound while open)
local SLIDER_STEP = 0.1 -- one D-pad press
local SLIDER_REPEAT_DELAY = 0.4 -- holding the D-pad / stick: first repeat...
local SLIDER_REPEAT_EVERY = 0.12 -- ...then this often
local STICK_THRESHOLD = 0.6

local TOAST_KINDS = {
	boost = { tag = "BOOSTS ACTIVE", accent = true },
	gift = { tag = "WELCOME GIFT", accent = true },
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

-- True only once the server says the save really loaded (never on a failed load).
local function saveLoaded()
	return player:GetAttribute("DataLoaded") == true and player:GetAttribute("DataFailed") ~= true
end

local function saveFailed()
	return player:GetAttribute("DataFailed") == true
end

-- When the season ends (0 = no end date set).
local function seasonEnds()
	return tonumber(ReplicatedStorage:GetAttribute("SeasonEnds")) or tonumber(Config.SEASON_ENDS) or 0
end

-- Premium isn't sold once less than SEASON_LAST_SALE is left (or the season is over).
local function seasonSaleClosed(now)
	local ends = seasonEnds()
	return ends > 0 and ends - now < SEASON_LAST_SALE
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

-- Boost inventory from the Boosts attribute: { [boostId] = count } (unknown ids dropped).
local function ownedBoosts()
	local counts = {}
	local decoded = decodeJson(player:GetAttribute("Boosts"))
	if type(decoded) == "table" then
		for id, count in decoded do
			if type(id) == "string" and boostInfo(id) then
				local n = tonumber(count)
				counts[id] = if n and n == n then math.max(0, math.floor(n)) else 0
			end
		end
	end
	return counts
end

-- A developer product's id, or 0 when it isn't set up (0 hides that offer).
local function productId(key)
	local product = Config.Products[key]
	return if type(product) == "table" and tonumber(product.Id) then product.Id else 0
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
	The holder itself is the (invisible) button, so the tap area and the gamepad
	selection cover the face *and* its shadow: a 50-tall button stays >= 44px
	even on the smallest phone sheet.
	opts: Name, Size, Position, AnchorPoint, LayoutOrder, Fill, Text, TextSize,
	Align, Index (small label top-left), Sub (small second line), OnClick
	A disabled button ignores taps, except that it calls button.onBlocked if set.
]]
local function hardButton(parent, opts)
	local holder = new("TextButton", {
		Name = opts.Name or "Button",
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
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
	local face = new("Frame", {
		Name = "Face",
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

	holder.MouseButton1Down:Connect(function()
		if button.enabled then
			tween(face, 0.06, { Position = UDim2.fromOffset(2, 2) })
		end
	end)
	holder.MouseButton1Up:Connect(release)
	holder.MouseLeave:Connect(release)
	holder.Activated:Connect(function()
		release()
		if button.enabled then
			if opts.OnClick then
				opts.OnClick()
			end
		elseif button.onBlocked then
			button.onBlocked() -- e.g. a Robux button before the save loaded says why
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

-- Shield mark: a flat top half over a diamond, which reads as a pointed crest.
local function shieldGlyph(parent, size, position, color)
	local holder = new("Frame", {
		Name = "ShieldGlyph",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = UDim2.fromOffset(size, size),
		Parent = parent,
	})
	new("Frame", { BackgroundColor3 = color, Size = UDim2.new(1, 0, 0.5, 0), Parent = holder })
	local tip = math.floor(size * 0.707 + 0.5)
	new("Frame", {
		BackgroundColor3 = color,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(tip, tip),
		Rotation = 45,
		Parent = holder,
	})
	return holder
end

-- Settings mark: a sharp-cornered cog. Four bars make eight teeth, two squares
-- make the octagonal body, and a paper square punches the hole.
local function gearGlyph(parent, size, position, color, holeColor)
	local holder = new("Frame", {
		Name = "Gear",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = UDim2.fromOffset(size, size),
		Parent = parent,
	})
	local center = UDim2.fromScale(0.5, 0.5)
	local half = Vector2.new(0.5, 0.5)
	local tooth = math.max(2, math.floor(size * 0.24 + 0.5))
	for _, rotation in { 0, 45, 90, 135 } do
		new("Frame", { BackgroundColor3 = color, AnchorPoint = half, Position = center, Size = UDim2.fromOffset(size, tooth), Rotation = rotation, Parent = holder })
	end
	local body = math.floor(size * 0.7 + 0.5)
	for _, rotation in { 0, 45 } do
		new("Frame", { BackgroundColor3 = color, AnchorPoint = half, Position = center, Size = UDim2.fromOffset(body, body), Rotation = rotation, Parent = holder })
	end
	local hole = math.max(2, math.floor(size * 0.28 + 0.5))
	new("Frame", { Name = "Hole", BackgroundColor3 = holeColor or PAPER, AnchorPoint = half, Position = center, Size = UDim2.fromOffset(hole, hole), Rotation = 45, Parent = holder })
	return holder
end

-- Gamepad helpers ------------------------------------------------------------------------

-- "gamepad", "pointer" (mouse / keyboard / touch), or nil for inputs that say
-- nothing about how the player is playing (gyro, focus, text input...).
local function inputKind(inputType)
	if string.sub(inputType.Name, 1, 7) == "Gamepad" then
		return "gamepad"
	end
	if
		inputType == Enum.UserInputType.Touch
		or inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseMovement
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseButton3
		or inputType == Enum.UserInputType.MouseWheel
	then
		return "pointer"
	end
	return nil
end

local function gamepadAtStart()
	local kind = inputKind(UserInputService:GetLastInputType())
	if kind then
		return kind == "gamepad" and UserInputService.GamepadEnabled
	end
	return GuiService:IsTenFootInterface() -- console with no input yet
end

-- Visible on screen: itself and every ancestor up to an enabled ScreenGui.
local function onScreen(inst)
	if inst == nil or inst.Parent == nil then
		return false
	end
	local node = inst
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

-- The first selectable button under `container` that is showing, or nil.
local function firstSelectable(container)
	if container == nil then
		return nil
	end
	for _, inst in container:GetDescendants() do
		if inst:IsA("GuiButton") and inst.Selectable and onScreen(inst) then
			return inst
		end
	end
	return nil
end

-- Gamepad selection outline: a thick accent box with an ink hairline inside,
-- sharp corners, a few px outside the selected button.
local function selectionBox()
	local box = Instance.new("Frame")
	box.Name = "Selection"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Position = UDim2.fromOffset(-5, -5)
	box.Size = UDim2.new(1, 10, 1, 10)
	local accentStroke = stroke(box, 3, accentColor)
	local inner = new("Frame", {
		Name = "Hairline",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
		Parent = box,
	})
	stroke(inner, 1, INK)
	return box, accentStroke
end

-- Small controller hint row: ink keycap + label per pair, e.g. { {"A", "SELECT"}, {"B", "BACK"} }.
-- Hidden unless the player is on a gamepad (see _refreshHints).
local function inputHint(parent, entries, props, alignment)
	local merged = { Name = "InputHint", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 14), Visible = false }
	for key, value in props do
		merged[key] = value
	end
	merged.Parent = parent
	local row = new("Frame", merged)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = alignment or Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 3),
		Parent = row,
	})
	for i, pair in entries do
		local cap = new("Frame", {
			Name = "Key",
			BackgroundColor3 = INK,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 14, 1, 0),
			LayoutOrder = i * 2 - 1,
			Parent = row,
		})
		new("UIPadding", { PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 3), Parent = cap })
		text({
			Text = pair[1],
			TextSize = 8,
			TextColor3 = PAPER,
			TextXAlignment = Enum.TextXAlignment.Center,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 8, 1, 0),
			Parent = cap,
		})
		local word = text({
			Name = "Action",
			Text = pair[2],
			TextSize = 8,
			BackgroundColor3 = PAPER,
			BackgroundTransparency = 0.1,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 8, 1, 0),
			LayoutOrder = i * 2,
			Parent = row,
		})
		new("UIPadding", { PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 5), Parent = word })
	end
	return row
end

-- Explicit gamepad neighbours for a grid of buttons (row-major, `columns` wide).
-- Links left as nil fall back to Roblox's automatic choice.
local function linkGrid(buttons, columns)
	local count = #buttons
	for i, button in buttons do
		local column = (i - 1) % columns
		button.NextSelectionLeft = if column > 0 then buttons[i - 1] else nil
		button.NextSelectionRight = if column < columns - 1 and i < count then buttons[i + 1] else nil
		button.NextSelectionUp = if i > columns then buttons[i - columns] else nil
		local below = buttons[i + columns]
		if below == nil and i + columns - column <= count then
			below = buttons[count] -- short last row: drop to its last button
		end
		button.NextSelectionDown = below
	end
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
	self:_buildTopUp(root)
	self:_buildModal(root)
end

function UI._buildMenuLeft(self, root)
	local m = self._menu
	local left = new("Frame", {
		Name = "Left",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, EDGE + 4, 0.5, 0),
		Size = UDim2.fromOffset(256, MENU_H),
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

	-- Boost picker: one chip per boost, right above PLAY.
	self:_buildBoostPicker(left, 178)

	-- PLAY
	local play = hardButton(left, {
		Name = "Play",
		Fill = "accent",
		Text = "PLAY",
		TextSize = 26,
		Align = Enum.TextXAlignment.Left,
		Index = "A / START RUN / 0 M",
		Position = UDim2.fromOffset(0, 232),
		Size = UDim2.fromOffset(256, 54),
		OnClick = function()
			self:_fire("onPlay", 0, self:_pickedBoosts())
		end,
	})
	hatch(play.face, { Name = "Hatch", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.new(0, 46, 1, -16) }, INK, 0, 4)
	m.play = play

	-- DAILY: opens the 7-day streak sheet. The pips on the right show the streak at a glance.
	-- It shares the bottom row with the SETTINGS gear, so PLAY stays the one big button.
	local daily = hardButton(left, {
		Name = "Daily",
		Fill = "paper",
		Text = "--:--:--",
		TextSize = 13,
		Align = Enum.TextXAlignment.Left,
		Index = "B / DAILY",
		Position = UDim2.fromOffset(0, 290),
		Size = UDim2.fromOffset(256 - SETTINGS_GEAR_W, 50),
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

	local gear = self:_gearButton(left, {
		Position = UDim2.fromOffset(256 - SETTINGS_GEAR_W, 290),
	})
	m.settingsButton = gear
	daily.holder.NextSelectionRight = gear.holder
	gear.holder.NextSelectionLeft = daily.holder
	gear.holder.NextSelectionUp = play.holder
end

-- The SETTINGS gear: a small square hard button (50 tall, like everything tappable).
function UI._gearButton(self, parent, opts)
	local button
	button = hardButton(parent, {
		Name = "Settings",
		Fill = "paper",
		Text = "",
		Index = "SETTINGS",
		Position = opts.Position,
		AnchorPoint = opts.AnchorPoint,
		LayoutOrder = opts.LayoutOrder,
		Size = UDim2.fromOffset(SETTINGS_GEAR_W, 50),
		OnClick = function()
			self:_openSettings(button.holder)
		end,
	})
	button.index.TextXAlignment = Enum.TextXAlignment.Center
	capText(button.index, 8, 5)
	button.gear = gearGlyph(button.face, 18, UDim2.new(0.5, 0, 0.5, 5), INK, PAPER)
	return button
end

-- Boost picker ------------------------------------------------------------------------------
-- Chips toggle which owned boosts go into the next run (up to MAX_PICKS). A chip
-- with none owned shows a "+" and opens a small buy popover above the strip.

function UI._buildBoostPicker(self, left, y)
	local m = self._menu
	m.boostPicks = {}
	m.boostChips = {}
	m.boostChipList = {}
	local count = #BOOST_ORDER
	if count == 0 then
		return
	end
	local width = 256
	local gap = BOOST_CHIP_GAP -- tight, so 5 chips stay >= 50 wide (44px on a phone)
	local chipW = math.floor((width - gap * (count - 1)) / count)
	local strip = new("Frame", {
		Name = "Boosts",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.fromOffset(width, BOOST_CHIP_H),
		Parent = left,
	})
	m.boostStrip = strip
	m.boostChipW = chipW

	for i, id in BOOST_ORDER do
		if boostInfo(id) then
			-- The holder is the button, so the whole chip (shadow included) is the tap / selection area.
			local holder = new("TextButton", {
				Name = id,
				AutoButtonColor = false,
				Text = "",
				Selectable = true,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset((i - 1) * (chipW + gap), 0),
				Size = UDim2.fromOffset(chipW, BOOST_CHIP_H),
				Parent = strip,
			})
			local bump = new("UIScale", { Parent = holder })
			local shadow = new("Frame", {
				Name = "Shadow",
				BackgroundColor3 = INK,
				Position = UDim2.fromOffset(2, 2),
				Size = UDim2.new(1, -2, 1, -2),
				Visible = false,
				Parent = holder,
			})
			local face = new("Frame", {
				Name = "Face",
				BackgroundColor3 = PAPER,
				Size = UDim2.new(1, -2, 1, -2),
				Parent = holder,
			})
			local outline = stroke(face, 1, INK, 0.5)
			rewardChip(face, { Boost = id }, 7, UDim2.fromOffset(8, 8))
			local countLabel = text({
				Name = "Count",
				Text = "x0",
				TextSize = 8,
				TextXAlignment = Enum.TextXAlignment.Right,
				Position = UDim2.fromOffset(14, 2),
				Size = UDim2.new(1, -17, 0, 11),
				Parent = face,
			})
			local plus = new("Frame", {
				Name = "Plus",
				BackgroundColor3 = INK,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -3, 0, 3),
				Size = UDim2.fromOffset(11, 11),
				Visible = false,
				Parent = face,
			})
			setAccent(text({
				Text = "+",
				Font = FONT_NUM,
				TextSize = 9,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.fromScale(1, 1),
				Parent = plus,
			}), "TextColor3")
			local name = capText(text({
				Name = "Name",
				Text = boostName(id),
				Font = FONT_NUM,
				TextXAlignment = Enum.TextXAlignment.Center,
				Position = UDim2.fromOffset(2, 18),
				Size = UDim2.new(1, -4, 0, 22),
				Parent = face,
			}), 8, 5)
			local chip = {
				id = id,
				order = i,
				holder = holder,
				bump = bump,
				shadow = shadow,
				face = face,
				outline = outline,
				count = countLabel,
				plus = plus,
				name = name,
			}
			holder.Activated:Connect(function()
				self:_tapBoostChip(chip)
			end)
			m.boostChips[id] = chip
			table.insert(m.boostChipList, chip)
		end
	end

	self:_buildBoostPop(left, y)
end

-- The small "buy one" popover that sits above the chip strip.
function UI._buildBoostPop(self, left, chipY)
	local m = self._menu
	local pop = {}
	m.boostPop = pop
	local frame = new("Frame", {
		Name = "BoostPop",
		BackgroundColor3 = PAPER,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromOffset(0, chipY - 6),
		Size = UDim2.fromOffset(256, BOOST_POP_H),
		ZIndex = 3,
		Visible = false,
		Parent = left,
	})
	frame.Active = true -- taps on the popover don't fall through
	-- Gamepad selection stays inside the popover until it closes (B or X).
	frame.SelectionGroup = true
	frame.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	frame.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	frame.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	frame.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	pop.frame = frame
	pop.y = chipY - 6
	stroke(frame, 1.5)
	cropMarks(frame, 6, 3)

	local header = new("Frame", { Name = "Header", BackgroundColor3 = INK, Size = UDim2.new(1, 0, 0, 24), Parent = frame })
	pop.title = text({
		Text = "",
		TextSize = 8,
		TextColor3 = PAPER,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -(POP_CLOSE + 68), 1, 0),
		Parent = header,
	})
	setAccent(text({
		Text = "BUY 1",
		TextSize = 8,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -(POP_CLOSE + 60), 0, 0),
		Size = UDim2.fromOffset(54, 24),
		Parent = header,
	}), "TextColor3")
	rule(header, { BackgroundColor3 = PAPER, BackgroundTransparency = 0.6, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -POP_CLOSE, 0, 5), Size = UDim2.new(0, 1, 1, -10) })
	-- The X is drawn in the header, but its tap area is a full 50x50 corner
	-- (reaching down past the copy line, which stops short of it).
	local close = new("TextButton", {
		Name = "Close",
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(POP_CLOSE, POP_CLOSE),
		ZIndex = 2,
		Parent = frame,
	})
	text({
		Text = "X",
		Font = FONT_NUM,
		TextSize = 10,
		TextColor3 = PAPER,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 24),
		Parent = close,
	})
	close.Activated:Connect(function()
		self:_closeBoostPop()
	end)
	pop.close = close

	pop.copy = text({
		Text = "",
		TextSize = 8,
		TextColor3 = GREY,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(8, 28),
		Size = UDim2.new(1, -(POP_CLOSE + 12), 0, 11),
		Parent = frame,
	})

	-- Leader line from the popover down to the chip it belongs to.
	pop.pointer = rule(frame, { Name = "Pointer", Position = UDim2.new(0, 24, 1, 0), Size = UDim2.fromOffset(1, 6) })

	pop.gems = hardButton(frame, {
		Name = "Gems",
		Fill = "ink",
		Text = "",
		TextSize = 11,
		Align = Enum.TextXAlignment.Left,
		Index = "PAY / GEMS",
		Position = UDim2.fromOffset(8, 54),
		Size = UDim2.fromOffset(120, 50),
		OnClick = function()
			self:_buyBoostWithGems()
		end,
	})
	pop.robux = hardButton(frame, {
		Name = "Robux",
		Fill = "accent",
		Text = "R$ --",
		TextSize = 11,
		Align = Enum.TextXAlignment.Left,
		Index = "PAY / ROBUX",
		Position = UDim2.fromOffset(132, 54),
		Size = UDim2.fromOffset(120, 50),
		OnClick = function()
			if pop.id then
				self:_fire("onBuyProduct", "Boost" .. pop.id)
			end
		end,
	})
	self:_robuxButton(pop.robux)
	pop.gems.holder.NextSelectionUp = close
	pop.robux.holder.NextSelectionUp = close
	pop.gems.holder.NextSelectionRight = pop.robux.holder
	pop.robux.holder.NextSelectionLeft = pop.gems.holder
	close.NextSelectionDown = pop.robux.holder
end

function UI._pickedBoosts(self)
	local picks = self._menu.boostPicks
	return if picks then table.clone(picks) else {}
end

function UI._tapBoostChip(self, chip)
	local m = self._menu
	local owned = ownedBoosts()[chip.id] or 0
	local index = table.find(m.boostPicks, chip.id)
	if index then
		table.remove(m.boostPicks, index)
	elseif owned <= 0 then
		if m.boostPop.frame.Visible and m.boostPop.id == chip.id then
			self:_closeBoostPop()
		else
			self:_openBoostPop(chip)
		end
		return
	elseif #m.boostPicks >= MAX_PICKS then
		self:toast("MAX " .. MAX_PICKS .. " BOOSTS PER RUN", "info")
		return
	else
		table.insert(m.boostPicks, chip.id)
		chip.bump.Scale = 1.12
		tween(chip.bump, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	self:_closeBoostPop()
	self:_refreshBoosts()
end

-- Chip looks; each chip only re-styles when its state or count changes.
function UI._refreshBoosts(self)
	local m = self._menu
	if not m or not m.boostChips then
		return
	end
	local counts = ownedBoosts()
	-- Drop picks that are no longer owned (spent, or inventory not loaded yet).
	for i = #m.boostPicks, 1, -1 do
		if (counts[m.boostPicks[i]] or 0) <= 0 then
			table.remove(m.boostPicks, i)
		end
	end

	-- A boost just bought from the open popover gets picked for the next run.
	local pop = m.boostPop
	if pop and pop.id and (counts[pop.id] or 0) > 0 then
		local id = pop.id
		self:_closeBoostPop()
		if not table.find(m.boostPicks, id) and #m.boostPicks < MAX_PICKS then
			table.insert(m.boostPicks, id)
		end
	end

	local full = #m.boostPicks >= MAX_PICKS
	for id, chip in m.boostChips do
		local owned = counts[id] or 0
		local picked = table.find(m.boostPicks, id) ~= nil
		local state = if picked then "picked" elseif owned <= 0 then "empty" elseif full then "full" else "owned"
		local key = state .. owned
		if key ~= chip.key then
			chip.key = key
			if picked then
				setAccent(chip.face, "BackgroundColor3")
			else
				clearAccent(chip.face)
				chip.face.BackgroundColor3 = PAPER
			end
			chip.face.BackgroundTransparency = if state == "empty" then 0.35 else 0
			chip.shadow.Visible = picked
			chip.outline.Thickness = if picked then 2 else 1
			chip.outline.Transparency = if picked then 0 elseif state == "empty" then 0.7 else 0.5
			chip.name.TextTransparency = if state == "empty" or state == "full" then 0.45 else 0
			chip.count.Visible = owned > 0
			chip.count.Text = "x" .. owned
			chip.count.TextColor3 = if picked then INK else GREY
			chip.plus.Visible = owned <= 0
		end
	end
	self:_refreshBoostPop()
	self:_refreshPlayIndex()
	self:_checkWelcome(counts)
end

function UI._openBoostPop(self, chip)
	local m = self._menu
	local pop = m.boostPop
	local boost = boostInfo(chip.id)
	if not pop or not boost then
		return
	end
	self:_hideTopUp()
	pop.id = chip.id
	pop.busy = false
	pop.gems.setEnabled(true)
	pop.title.Text = "C-" .. twoDigits(chip.order) .. " / " .. boostName(chip.id) .. " BOOST"
	pop.copy.Text = string.upper(tostring(boost.Text or ""))
	pop.pointer.Position = UDim2.new(0, chip.holder.Position.X.Offset + math.floor((m.boostChipW or 48) / 2) - 1, 1, 0)

	-- Robux option only when that boost's product is set up.
	local key = "Boost" .. chip.id
	local id = productId(key)
	pop.robux.holder.Visible = id ~= 0
	pop.gems.holder.Size = if id ~= 0 then UDim2.fromOffset(120, 50) else UDim2.fromOffset(244, 50)
	pop.close.NextSelectionDown = if id ~= 0 then pop.robux.holder else pop.gems.holder
	pop.robux.setText("R$ --")
	withPrice(id, Enum.InfoType.Product, function(price)
		if pop.id == chip.id and pop.robux.label.Parent then
			pop.robux.setText("R$ " .. commas(price))
		end
	end)

	pop.frame.Visible = true
	pop.frame.Position = UDim2.fromOffset(0, pop.y + 8)
	tween(pop.frame, 0.2, { Position = UDim2.fromOffset(0, pop.y) })
	pop.returnTo = chip.holder
	self:_refreshBoostPop()
	self:_syncBack()
	self:_focus(pop.gems.holder)
end

function UI._closeBoostPop(self)
	local pop = self._menu and self._menu.boostPop
	if not pop then
		return
	end
	if self._topUp and self._topUp.host == pop.frame then
		self:_hideTopUp()
	end
	local wasOpen = pop.frame.Visible
	pop.id = nil
	pop.frame.Visible = false
	if wasOpen then
		self:_syncBack()
		self:_returnFocus(pop.frame, pop.returnTo)
	end
end

-- Gem button: price, or how many gems are missing.
function UI._refreshBoostPop(self)
	local pop = self._menu and self._menu.boostPop
	if not pop or not pop.id or pop.busy then
		return
	end
	local boost = boostInfo(pop.id)
	local price = math.floor(tonumber(boost and boost.Gems) or 0)
	local short = price - math.floor(attrNumber("Gems", 0))
	local key = pop.id .. "|" .. short
	if key == pop.key then
		return
	end
	pop.key = key
	if short > 0 then
		pop.gems.setFill("paper")
		pop.gems.index.Text = "PAY / " .. commas(price) .. " GEMS"
		pop.gems.setText("NEED " .. commas(short) .. " GEMS")
	else
		pop.gems.setFill("ink")
		pop.gems.index.Text = "PAY / GEMS"
		pop.gems.setText(commas(price) .. " GEMS")
	end
end

function UI._buyBoostWithGems(self)
	local pop = self._menu.boostPop
	local id = pop.id
	local boost = id and boostInfo(id)
	if not boost or pop.busy then
		return
	end
	local price = math.floor(tonumber(boost.Gems) or 0)
	local short = price - math.floor(attrNumber("Gems", 0))
	if short > 0 then
		-- Not enough: offer the small gem top-up instead of a doomed request.
		if not self:_offerTopUp(price, pop.frame) then
			self:toast("NEED " .. commas(short) .. " MORE GEMS", "error")
		end
		return
	end
	pop.busy = true
	pop.key = nil
	pop.gems.setEnabled(false)
	pop.gems.setText("BUYING")
	task.spawn(function()
		local ok, message = self:_ask("onShop", "BuyBoost", id)
		pop.busy = false
		pop.gems.setEnabled(true)
		if ok then
			self:toast("+1 " .. boostName(id) .. " BOOST", "reward")
		else
			self:toast(message or "PURCHASE FAILED", "error")
			if pop.id == id then
				self:_offerTopUp(price, pop.frame)
			end
		end
		self:_refreshBoosts()
	end)
end

-- "A / START RUN / +10 BONUS BALLS / 2/3 BOOSTS"
function UI._refreshPlayIndex(self)
	local m = self._menu
	if not m.play then
		return
	end
	local parts = { "A / START RUN" }
	local bonus = math.max(0, math.floor(attrNumber("BonusBalls", 0)))
	if bonus > 0 then
		table.insert(parts, "+" .. bonus .. " BONUS BALLS")
	end
	local picks = if m.boostPicks then #m.boostPicks else 0
	if picks > 0 then
		table.insert(parts, picks .. "/" .. MAX_PICKS .. " BOOSTS")
	end
	if #parts == 1 then
		table.insert(parts, "0 M")
	end
	m.play.index.Text = table.concat(parts, " / ")
end

-- New players arrive with a starter set of boosts: say so once per session.
function UI._checkWelcome(self, counts)
	if self._welcomeDone then
		return
	end
	local stats = decodeJson(player:GetAttribute("Stats"))
	if player:GetAttribute("Level") == nil or type(stats) ~= "table" then
		return -- progress not loaded yet
	end
	local level = levelInfo()
	if level > 1 or (tonumber(stats.runs) or 0) > 0 then
		self._welcomeDone = true
		return
	end
	local total = 0
	for _, n in counts or ownedBoosts() do
		total += n
	end
	if total <= 0 then
		return
	end
	self._welcomeDone = true
	self:toast(total .. (if total == 1 then " FREE BOOST" else " FREE BOOSTS") .. " / PICK ABOVE PLAY", "gift")
	for i, chip in self._menu.boostChipList or {} do
		task.delay(0.08 * i, function()
			if chip.holder.Parent then
				chip.bump.Scale = 1.18
				tween(chip.bump, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end)
	end
end

-- Gem top-up ------------------------------------------------------------------------------
-- One small inline strip, moved next to whatever purchase just came up short
-- (shop panel or boost popover). No modal and no timer; it closes with X, once
-- the player can afford the item, or when the context goes away.

function UI._buildTopUp(self, root)
	local product = Config.Products.GemTopUp
	local id = productId("GemTopUp")
	if id == 0 or not tonumber(product.Gems) then
		return
	end
	local t = {}
	self._topUp = t
	local strip = new("Frame", {
		Name = "TopUp",
		BackgroundColor3 = INK,
		Size = UDim2.new(1, 0, 0, TOPUP_H),
		ZIndex = 6,
		Visible = false,
		Parent = root,
	})
	strip.Active = true
	t.strip = strip
	notch(strip, 8, 0, 0)
	local textW = -(12 + TOPUP_CLOSE_W + 2 + TOPUP_BUY_W + 8)
	t.short = setAccent(text({ Text = "", TextSize = 8, Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, textW, 0, 10), Parent = strip }), "TextColor3")
	t.offer = capText(text({
		Text = "GET +" .. commas(product.Gems) .. " GEMS",
		Font = FONT_NUM,
		TextColor3 = PAPER,
		Position = UDim2.fromOffset(12, 20),
		Size = UDim2.new(1, textW, 0, 26),
		Parent = strip,
	}), 12, 7)
	t.buy = hardButton(strip, {
		Name = "Buy",
		Fill = "accent",
		Text = "GET",
		TextSize = 11,
		Sub = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -(TOPUP_CLOSE_W + 2), 0.5, 2),
		Size = UDim2.fromOffset(TOPUP_BUY_W, 50),
		OnClick = function()
			self:_fire("onBuyProduct", "GemTopUp")
		end,
	})
	self:_robuxButton(t.buy)
	withPrice(id, Enum.InfoType.Product, function(price)
		t.buy.sub.Text = "R$ " .. commas(price)
	end)
	rule(strip, { BackgroundColor3 = PAPER, BackgroundTransparency = 0.7, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -TOPUP_CLOSE_W, 0, 8), Size = UDim2.new(0, 1, 1, -16) })
	local dismiss = new("TextButton", {
		Name = "Dismiss",
		AutoButtonColor = false,
		Text = "X",
		Font = FONT_NUM,
		TextSize = 10,
		TextColor3 = PAPER,
		Selectable = true,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, TOPUP_CLOSE_W, 1, 0),
		Parent = strip,
	})
	dismiss.Activated:Connect(function()
		self:_hideTopUp()
	end)
	t.buy.holder.NextSelectionRight = dismiss
	dismiss.NextSelectionLeft = t.buy.holder
end

-- Shows the top-up if the player is short for `price` by no more than the pack
-- gives. Returns whether it is showing.
function UI._offerTopUp(self, price, host)
	local t = self._topUp
	if not t or not host or not saveLoaded() then
		return false -- never push a Robux offer before the save loaded
	end
	local short = math.floor((tonumber(price) or 0) - attrNumber("Gems", 0))
	if short <= 0 or short > Config.Products.GemTopUp.Gems then
		return false
	end
	t.price = price
	t.host = host
	t.strip.Parent = host
	local y
	if host == self._menu.panel then
		-- Bottom of the panel, just above the footer.
		t.strip.AnchorPoint = Vector2.new(0.5, 1)
		y = -(FOOTER_H + 4)
		t.strip.Position = UDim2.new(0.5, 0, 1, y + 8)
		t.strip.Size = UDim2.new(1, -12, 0, TOPUP_H)
		tween(t.strip, 0.2, { Position = UDim2.new(0.5, 0, 1, y) })
	else
		-- Stacked on top of the boost popover.
		t.strip.AnchorPoint = Vector2.new(0, 1)
		t.strip.Position = UDim2.new(0, 0, 0, 2)
		t.strip.Size = UDim2.new(1, 0, 0, TOPUP_H)
		tween(t.strip, 0.2, { Position = UDim2.new(0, 0, 0, -6) })
	end
	t.shown = nil
	local selected = GuiService.SelectedObject
	if selected == nil or not selected:IsDescendantOf(t.strip) then
		t.returnTo = selected
	end
	t.strip.Visible = true
	self:_refreshTopUp()
	if t.strip.Visible then
		self:_syncBack()
		self:_focus(t.buy.holder)
	end
	return t.strip.Visible
end

function UI._refreshTopUp(self)
	local t = self._topUp
	if not t or not t.strip.Visible or not t.price then
		return
	end
	local short = math.floor(t.price - attrNumber("Gems", 0))
	if short <= 0 or short > Config.Products.GemTopUp.Gems then
		self:_hideTopUp()
		return
	end
	if short ~= t.shown then
		t.shown = short
		t.short.Text = "SHORT BY " .. commas(short) .. " GEMS"
	end
end

function UI._hideTopUp(self)
	local t = self._topUp
	if t then
		local wasOpen = t.strip.Visible
		t.host = nil
		t.price = nil
		t.strip.Visible = false
		if wasOpen then
			self:_syncBack()
			self:_returnFocus(t.strip, t.returnTo)
		end
	end
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
			Selectable = true,
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
			Selectable = false, -- gamepad selection goes to the buttons inside; the page scrolls to follow it
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
	-- Gamepad: the tabs row is one straight line; LEFT off the first tab goes back to PLAY.
	for i, tab in m.tabs do
		tab.button.NextSelectionLeft = if i > 1 then m.tabs[i - 1].button else m.play and m.play.holder
		tab.button.NextSelectionRight = if i < #m.tabs then m.tabs[i + 1].button else nil
	end

	-- Footer
	local footer = new("Frame", { Name = "Footer", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, FOOTER_H), Parent = panel })
	rule(footer, { BackgroundTransparency = 0.5 })
	m.footer = text({ Text = "SHEET 01 / " .. twoDigits(#names), TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(9, 1), Size = UDim2.new(0.5, -9, 1, -1), Parent = footer })
	m.footerSpec = text({
		Text = "SHATTER RUN / SPEC",
		TextSize = 8,
		TextColor3 = GREY,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0.5, 0, 0, 1),
		Size = UDim2.new(0.5, -22, 1, -1),
		Parent = footer,
	})
	-- Same spot, controller only.
	m.footerHint = inputHint(footer, { { "A", "SELECT" }, { "B", "BACK" } }, {
		Position = UDim2.new(0.4, 0, 0, 2),
		Size = UDim2.new(0.6, -22, 1, -4),
	}, Enum.HorizontalAlignment.Right)

	-- Save didn't load: a strip above the footer (pages shrink to make room,
	-- see _refreshSaveState). Robux buttons are off until they rejoin.
	local banner = new("Frame", {
		Name = "SaveBanner",
		BackgroundColor3 = INK,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -FOOTER_H),
		Size = UDim2.new(1, 0, 0, SAVE_BANNER_H),
		Visible = false,
		Parent = panel,
	})
	hatch(banner, { Name = "Hatch", Size = UDim2.new(0, 8, 1, 0) }, PAPER, 0.45, 3)
	capText(setAccent(text({
		Text = "YOUR SAVE DIDN'T LOAD",
		Font = FONT_NUM,
		Position = UDim2.fromOffset(16, 4),
		Size = UDim2.new(1, -24, 0, 16),
		Parent = banner,
	}), "TextColor3"), 11, 7)
	text({
		Text = "REJOIN BEFORE BUYING / ROBUX SHOP IS OFF UNTIL THEN",
		TextSize = 8,
		TextColor3 = PAPER,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(16, 21),
		Size = UDim2.new(1, -24, 0, 11),
		Parent = banner,
	})
	m.saveBanner = banner

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
		CellSize = UDim2.new(0.5, -4, 0, 162),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	m.skinCards = {}
	local skinButtons = {}
	for order, skin in Config.Skins do
		local entry = self:_buildSkinCard(grid, skin, order)
		m.skinCards[skin.Id] = entry
		table.insert(skinButtons, entry.button.holder)
	end
	linkGrid(skinButtons, 2)

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
		CellSize = UDim2.new(0.5, -4, 0, 142),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = fxGrid,
	})
	m.fxCards = {}
	local fxButtons = {}
	for order, fx in Config.ShatterFx do
		local entry = self:_buildFxCard(fxGrid, fx, order)
		m.fxCards[fx.Id] = entry
		table.insert(fxButtons, entry.button.holder)
	end
	linkGrid(fxButtons, 2)
	-- Between the two grids: straight down from the last skins to the first effects and back.
	if #skinButtons > 0 and #fxButtons > 0 then
		local lastRowStart = #skinButtons - (#skinButtons - 1) % 2
		for i = lastRowStart, #skinButtons do
			skinButtons[i].NextSelectionDown = fxButtons[math.min(i - lastRowStart + 1, #fxButtons)]
		end
		for i = 1, math.min(2, #fxButtons) do
			fxButtons[i].NextSelectionUp = skinButtons[math.min(lastRowStart + i - 1, #skinButtons)]
		end
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
	self:_robuxButton(buy)
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
	self:_robuxButton(buy)
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
		Size = UDim2.new(1, -12, 0, 50),
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
		Size = UDim2.new(1, -12, 0, 50),
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
	if self._topUp and self._topUp.host == m.panel then
		self:_hideTopUp()
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
	-- Gamepad selection can't wander off the sheet to the menu underneath.
	sheet.SelectionGroup = true
	sheet.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	sheet.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	sheet.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	sheet.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
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
		Selectable = false, -- tap-outside-to-close only; never a gamepad stop
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
	local selected = GuiService.SelectedObject
	if selected == nil or not selected:IsDescendantOf(m.modal) then
		m.modalReturn = selected
	end
	m.modalOpen = name
	m.modal.Visible = true
	m.modalWash.BackgroundTransparency = 1
	tween(m.modalWash, 0.25, { BackgroundTransparency = 0.25 })
	sheet.Position = UDim2.new(0.5, 0, 0.5, 16)
	tween(sheet, 0.3, { Position = UDim2.fromScale(0.5, 0.5) })
	self:_syncBack()
	self:_focus(self:_modalPrimary())
end

function UI._closeModal(self)
	local m = self._menu
	if not m.modalOpen then
		return
	end
	m.modalOpen = nil
	m.modal.Visible = false
	self:_syncBack()
	self:_returnFocus(m.modal, m.modalReturn)
end

-- The button a popover's gamepad selection starts on.
function UI._modalPrimary(self)
	local m = self._menu
	if m.modalOpen == "daily" then
		local d = self._dailySheet
		return if d.claim.enabled then d.claim.holder else d.close.holder
	elseif m.modalOpen == "offer" then
		return m.offerBuy and m.offerBuy.holder
	end
	return nil
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
	d.height = height
	d.close = hardButton(sheet, {
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
	self:_buildStreakSaver(sheet)
end

-- Shown inside the daily sheet only while a broken streak can still be saved.
-- The sheet grows to make room; the claim row moves down under it.
local SAVER_H = 58

function UI._buildStreakSaver(self, sheet)
	local d = self._dailySheet
	local id = productId("StreakSaver")
	if id == 0 then
		return
	end
	local saver = new("Frame", {
		Name = "StreakSaver",
		BackgroundColor3 = INK,
		Position = UDim2.fromOffset(12, 150),
		Size = UDim2.new(1, -24, 0, SAVER_H - 4),
		Visible = false,
		Parent = sheet,
	})
	-- Text block is vertically centred in the taller strip.
	local textTop = math.floor((SAVER_H - 4 - 32) / 2)
	hatch(saver, { Name = "Hatch", Size = UDim2.new(0, 8, 1, 0) }, PAPER, 0.45, 3)
	notch(saver, 8, 1, 0)
	d.saverTitle = capText(setAccent(text({
		Text = "",
		Font = FONT_NUM,
		Position = UDim2.fromOffset(18, textTop),
		Size = UDim2.new(1, -118, 0, 20),
		Parent = saver,
	}), "TextColor3"), 12, 7)
	text({
		Text = "YOU MISSED A DAY / KEEP YOUR STREAK GOING",
		TextSize = 7,
		TextColor3 = PAPER,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(18, textTop + 22),
		Size = UDim2.new(1, -118, 0, 10),
		Parent = saver,
	})
	local buy = hardButton(saver, {
		Name = "Save",
		Fill = "accent",
		Text = "SAVE",
		TextSize = 11,
		Sub = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -2, 0.5, 0),
		Size = UDim2.fromOffset(92, 50),
		OnClick = function()
			-- CLAIM stays off until this purchase is done (see _saverPending), so a
			-- tap on CLAIM can't restart the streak before the saver lands.
			self._saverPendingUntil = os.clock() + SAVER_PROMPT_WAIT
			self:_refreshDaily()
			self:_fire("onBuyProduct", "StreakSaver")
		end,
	})
	self:_robuxButton(buy)
	d.saverBuy = buy
	withPrice(id, Enum.InfoType.Product, function(price)
		buy.sub.Text = "R$ " .. commas(price)
	end)
	d.saver = saver
end

function UI._layoutStreakSaver(self, saveDay)
	local d = self._dailySheet
	local show = saveDay ~= nil and d.saver ~= nil
	if d.saver then
		d.saver.Visible = show
		if show then
			d.saverTitle.Text = "SAVE YOUR DAY " .. saveDay .. " STREAK"
		end
	end
	local extra = if show then SAVER_H else 0
	d.sheet.Size = UDim2.fromOffset(d.sheet.Size.X.Offset, d.height + extra)
	d.close.holder.Position = UDim2.fromOffset(12, 152 + extra)
	d.claim.holder.Position = UDim2.fromOffset(116, 152 + extra)
	-- Gamepad: UP from the bottom row reaches the SAVE button while it shows.
	local saverButton = if show then d.saverBuy.holder else nil
	d.close.holder.NextSelectionUp = saverButton
	d.claim.holder.NextSelectionUp = saverButton
	if d.saverBuy then
		d.saverBuy.holder.NextSelectionDown = d.claim.holder
	end
	if not show then
		d.restartArmedUntil = nil
	end
end

-- True while a streak saver purchase is on its way (prompt open, or paid and
-- waiting for the server). CLAIM stays off meanwhile; see _tickDailySheet.
function UI._saverPending(self)
	local untilTime = self._saverPendingUntil
	if untilTime and os.clock() < untilTime then
		return true
	end
	self._saverPendingUntil = nil
	return false
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
	d.note.Text = if state.saveDay
		then "STREAK BROKEN / SAVE IT, OR CLAIMING RESTARTS AT DAY 1"
		elseif state.broken then "STREAK RESTARTED AT DAY 1 / CLAIM EVERY DAY TO KEEP IT"
		else "STREAK RESETS IF YOU MISS A DAY"
	self:_layoutStreakSaver(state.saveDay)
end

-- Claim button / countdown; runs every second while the menu is open.
function UI._tickDailySheet(self, state)
	local d = self._dailySheet
	if not d or self._dailyBusy then
		return
	end
	local reward = Config.DailyStreak[state.day] or {}
	local gems = commas(reward.Gems or 0)
	-- While the streak can still be saved, claiming would restart it at day 1,
	-- so the button says exactly that and asks twice.
	local restart = state.ready and state.saveDay ~= nil
	local mode
	if not state.ready then
		mode = "wait"
	elseif restart and self:_saverPending() then
		mode = "pending"
	elseif restart and d.restartArmedUntil and os.clock() < d.restartArmedUntil then
		mode = "confirm"
	elseif restart then
		mode = "restart"
	else
		mode = "claim"
	end
	if mode ~= d.mode then
		d.mode = mode
		d.claim.setFill(if mode == "claim" or mode == "confirm" then "accent" else "paper")
		d.claim.setEnabled(mode ~= "wait" and mode ~= "pending")
	end
	if mode == "wait" then
		d.claim.index.Text = "NEXT CLAIM IN"
		d.claim.setText(if state.wait then clock(state.wait) else "--:--:--")
	elseif mode == "pending" then
		d.claim.index.Text = "STREAK SAVER / ON ITS WAY"
		d.claim.setText("SAVING STREAK...")
	elseif mode == "confirm" then
		d.claim.index.Text = "SURE? YOUR STREAK GOES BACK TO DAY 1"
		d.claim.setText("TAP AGAIN TO RESTART")
	elseif mode == "restart" then
		d.claim.index.Text = "SKIP THE SAVER / CLAIM +" .. gems .. " GEMS"
		d.claim.setText("RESTART AT DAY 1")
	else
		d.claim.index.Text = "CLAIM / DAY " .. state.day
		d.claim.setText("CLAIM +" .. gems .. " GEMS")
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
	self:_robuxButton(buy)
	withPrice(product.Id, Enum.InfoType.Product, function(price)
		buy.sub.Text = "R$ " .. commas(price)
	end)
	m.offerBuy = buy
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
	if not saveLoaded() then
		return -- save not loaded (or failed to): we don't know if they own it
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
	-- Until the save loads we can't know whether they already bought it.
	local show = not bought and saveLoaded()
	if m.starterCard then
		m.starterCard.Visible = show
		m.starterHeader.Visible = show
	end
	if not show and m.modalOpen == "offer" then
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
	local focusPath = self:_captureFocus(m.missions)
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
	self:_restoreFocus(m.missions, focusPath, m.tabs[TAB_MISSIONS].button)
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
			Size = UDim2.fromOffset(88, 50),
			OnClick = function()
				self:_missionAction("RerollMission", mission, button, "...")
			end,
		})
		button.sub.TextSize = 7
	elseif productId("ExtraReroll") ~= 0 then
		-- Out of free rerolls: one more can be bought.
		local button = hardButton(row, {
			Name = "BuyReroll",
			Fill = "paper",
			Text = "REROLL",
			TextSize = 10,
			Sub = "R$ --",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.fromOffset(88, 50),
			OnClick = function()
				-- The mission id rides along so the controller can swap this
				-- mission as soon as the reroll is granted.
				self:_fire("onBuyProduct", "ExtraReroll", mission.id)
			end,
		})
		self:_robuxButton(button)
		button.sub.TextSize = 7
		withPrice(productId("ExtraReroll"), Enum.InfoType.Product, function(price)
			if button.sub.Parent then
				button.sub.Text = "R$ " .. commas(price)
			end
		end)
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
	self:_robuxButton(buy)
	withPrice(product and product.Id, Enum.InfoType.Product, function(price)
		buy.sub.Text = "R$ " .. commas(price)
	end)
	s.unlock = unlock
	s.active = tag(page, "PREMIUM TRACK ACTIVE", { Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Visible = false }, true)
	-- Last days of a season: premium isn't sold any more, and this says why.
	s.closed, s.closedLabel = tag(page, "PREMIUM CLOSED / SEASON ENDS SOON", { Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Visible = false })

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
		Selectable = false,
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

-- Premium UNLOCK card: only once the save loaded (we must know they don't own
-- it), and never in the last SEASON_LAST_SALE of a season. Runs every second
-- with the countdowns, so the card goes away on time.
function UI._refreshSeasonUnlock(self)
	local s = self._menu.season
	local premium = player:GetAttribute("SeasonPremium") == true
	local product = Config.Products.SeasonPremium
	local onSale = product ~= nil and product.Id ~= 0 and not premium and saveLoaded()
	local now = math.floor(workspace:GetServerTimeNow())
	local closed = seasonSaleClosed(now)
	local showUnlock = onSale and not closed
	local showClosed = onSale and closed
	if s.unlock.Visible ~= showUnlock then
		s.unlock.Visible = showUnlock
	end
	if s.closed.Visible ~= showClosed then
		s.closed.Visible = showClosed
	end
	if showClosed then
		s.closedLabel.Text = if seasonEnds() > now then "PREMIUM CLOSED / SEASON ENDS SOON" else "SEASON ENDED / NEW SEASON SOON"
	end
	s.active.Visible = premium
end

-- Rebuilds the 30-tier track only when tier, ownership or claims change.
function UI._rebuildSeason(self, force)
	local m = self._menu
	local s = m.season
	self:_refreshSeasonProgress()
	local tier, _, _, maxTier = seasonProgress()
	local premium = player:GetAttribute("SeasonPremium") == true
	local key = tier .. "|" .. tostring(premium) .. "|" .. tostring(player:GetAttribute("SeasonClaimed"))
	if not force and key == s.key then
		return
	end
	s.key = key
	local claimed = readSeasonClaimed()
	self:_refreshSeasonUnlock()

	local focusPath = self:_captureFocus(s.scroll)
	clearRows(s.scroll)
	local faces = { Free = {}, Premium = {} }
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
			faces[trackName][t] = self:_buildSeasonCell(column, if trackName == "Free" then 23 else 81, trackName, t, reward, state)
		end
	end
	self:_linkSeasonTrack(faces, maxTier)
	self:_restoreFocus(s.scroll, focusPath, m.tabs[TAB_SEASON].button)
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
		return nil
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
		Selectable = true,
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
	return face
end

-- Gamepad: LEFT / RIGHT walk along a row (skipping empty slots), UP / DOWN hop
-- between the free and premium rows. The track scrolls to follow the selection.
function UI._linkSeasonTrack(self, faces, maxTier)
	local function nearest(row, from, step)
		local t = from + step
		while t >= 1 and t <= maxTier do
			if row[t] then
				return row[t]
			end
			t += step
		end
		return nil
	end
	local function closest(row, t)
		if row[t] then
			return row[t]
		end
		return nearest(row, t, -1) or nearest(row, t, 1)
	end
	for trackName, row in faces do
		local other = if trackName == "Free" then faces.Premium else faces.Free
		for t, face in row do
			face.NextSelectionLeft = nearest(row, t, -1)
			face.NextSelectionRight = nearest(row, t, 1)
			if trackName == "Free" then
				face.NextSelectionDown = closest(other, t)
			else
				face.NextSelectionUp = closest(other, t)
			end
		end
	end
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
	local now = math.floor(workspace:GetServerTimeNow()) -- server clock, not the device clock
	local reset = tonumber(player:GetAttribute("MissionsReset"))
	if reset and reset > now then
		m.missionsReset.Text = "NEW MISSIONS IN " .. clock(reset - now)
	elseif reset then
		m.missionsReset.Text = "NEW MISSIONS ARRIVING"
	else
		m.missionsReset.Text = ""
	end
	local ends = seasonEnds()
	if ends > 0 then
		m.season.right.Text = if ends > now then "ENDS IN " .. longClock(ends - now) else "SEASON ENDED"
	else
		m.season.right.Text = ""
	end
	self:_refreshSeasonUnlock()
end

-- Menu data ---------------------------------------------------------------------------------

function UI._refreshStats(self)
	local m = self._menu
	m.best.Text = commas(player:GetAttribute("Best") or 0)
	local gems = commas(player:GetAttribute("Gems") or 0)
	m.gems.Text = gems
	m.shopGems.Text = "BALANCE " .. gems
	self:_refreshPlayIndex()
	self:_refreshSkins()
	self:_refreshFx()
	self:_refreshBoostPop()
	self:_refreshTopUp()
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
	local now = math.floor(workspace:GetServerTimeNow()) -- server clock, not the device clock
	local nextDaily = tonumber(player:GetAttribute("NextDaily"))
	local expires = tonumber(player:GetAttribute("StreakExpires"))
	local day = math.clamp(math.floor(attrNumber("StreakDay", 1)), 1, #Config.DailyStreak)
	local broken = expires ~= nil and expires > 0 and now > expires
	-- The streak saver only makes sense while the lost streak is still on record.
	-- If the server already reset StreakDay to 1 there is nothing left to save.
	local lostDay = math.floor(attrNumber("StreakDay", 1))
	local saveDay = nil
	if broken and lostDay > 1 and productId("StreakSaver") ~= 0 then
		saveDay = math.min(lostDay, #Config.DailyStreak)
	end
	if broken then
		day = 1
	end
	return {
		now = now,
		day = day,
		broken = broken,
		saveDay = saveDay,
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
	local key = state.day .. (if state.ready then "R" else "W") .. (if state.broken then "B" else "") .. (state.saveDay or 0)
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
		daily.index.Text = if state.saveDay
			then "B / DAILY / STREAK BROKEN / SAVE IT"
			else "B / DAILY / DAY " .. state.day .. " OF " .. #Config.DailyStreak
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
	local state = dailyState()
	if self._dailyBusy or not state.ready then
		return
	end
	local d = self._dailySheet
	if state.saveDay then
		-- Claiming now restarts a streak that could still be saved: never while
		-- a saver is being bought, and only on a second tap.
		if self:_saverPending() then
			return
		end
		if not (d.restartArmedUntil and os.clock() < d.restartArmedUntil) then
			d.restartArmedUntil = os.clock() + RESTART_CONFIRM_TIME
			self:_tickDailySheet(state)
			return
		end
	end
	d.restartArmedUntil = nil
	self._dailyBusy = true
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
		d.mode = nil
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
	local focusPath = self:_captureFocus(m.passes)
	clearRows(m.passes)
	local shown = 0
	-- Checkpoints only matters once there is a zone to start from.
	local reached = math.max(0, math.floor(tonumber(player:GetAttribute("Checkpoint")) or 0))
	for order, key in PASS_ORDER do
		local pass = Config.GamePasses[key]
		local useful = key ~= "Checkpoints" or reached > 0
		if pass and pass.Id ~= 0 and not hasPass(key) and useful then
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
			self:_robuxButton(buy)
			withPrice(pass.Id, Enum.InfoType.GamePass, function(price)
				if buy.sub.Parent then
					buy.sub.Text = "R$ " .. commas(price)
				end
			end)
		end
	end
	m.passHeader.Visible = shown > 0
	m.passes.Visible = shown > 0
	self:_restoreFocus(m.passes, focusPath, m.tabs[1].button)
end

function UI._rebuildZones(self)
	local m = self._menu
	local focusPath = self:_captureFocus(m.zones)
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
			Text = "START FROM ZONES YOU REACHED",
			TextSize = 12,
			Sub = "",
			Position = UDim2.fromOffset(0, 6),
			Size = UDim2.new(1, 0, 0, 50),
			OnClick = function()
				self:_fire("onBuyPass", "Checkpoints")
			end,
		})
		self:_robuxButton(unlock)
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
				Size = UDim2.fromOffset(74, 50),
				OnClick = function()
					self:_fire("onPlay", i, self:_pickedBoosts())
				end,
			})
		end
	end

	for i = 0, reached do
		zoneRow(i, i > 0 and not unlocked, false)
	end
	zoneRow(reached + 1, true, true)
	if reached > 0 then
		text({
			Name = "Note",
			Text = "CHECKPOINT RUNS DON'T COUNT FOR BEST",
			TextSize = 8,
			TextColor3 = GREY,
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = reached + 10,
			Parent = m.zones,
		})
	end
	self:_restoreFocus(m.zones, focusPath, m.tabs[4].button)
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
			if buying then
				self:_offerTopUp(card.skin.Price, self._menu.panel)
			end
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
			if buying then
				self:_offerTopUp(card.fx.Price, self._menu.panel)
			end
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

	-- Controller hint under the odometer during the first run ("R2 THROW").
	h.throwHint = inputHint(plate, { { "R2", "THROW" } }, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 5),
		Size = UDim2.new(1, 0, 0, 14),
	})

	-- Active boosts hang under the odometer (children of the plate, so they share its scale).
	self:_buildBoostRail(plate)

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
		self:_robuxButton(buy)
		withPrice(pack.Id, Enum.InfoType.Product, function(price)
			buy.sub.Text = "R$ " .. commas(price)
		end)
	end

	-- Shield quick-buy (bottom-left, away from the aim area): only while low on
	-- balls and not already shielded. See _refreshQuickShield.
	local shieldId = productId("BoostShield")
	if shieldId ~= 0 then
		local shieldBoost = boostInfo("Shield")
		local quick = hardButton(root, {
			Name = "QuickShield",
			Fill = "accent",
			Text = "SHIELD",
			TextSize = 12,
			Sub = "R$ --",
			Align = Enum.TextXAlignment.Left,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, EDGE, 1, -EDGE),
			Size = UDim2.fromOffset(122, 52),
			OnClick = function()
				self:_fire("onBuyProduct", "BoostShield")
			end,
		})
		quick.label.Size = UDim2.new(1, -40, 0.6, 0)
		quick.sub.Size = UDim2.new(1, -40, 0.4, -2)
		local block = new("Frame", {
			Name = "Mark",
			BackgroundColor3 = INK,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.fromOffset(26, 34),
			Parent = quick.face,
		})
		shieldGlyph(block, 14, UDim2.fromScale(0.5, 0.5), shieldBoost and shieldBoost.Color or PAPER)
		fit(quick.holder)
		quick.bump = new("UIScale", { Parent = quick.face })
		quick.holder.Visible = false
		self:_robuxButton(quick)
		withPrice(shieldId, Enum.InfoType.Product, function(price)
			quick.sub.Text = "R$ " .. commas(price)
		end)
		h.quickShield = quick
	end
end

-- One small plate per boost; hidden until setBoosts says it is running.
function UI._buildBoostRail(self, plate)
	local h = self._hud
	local rail = new("Frame", {
		Name = "BoostRail",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 6),
		Size = UDim2.fromOffset(340, 30),
		Parent = plate,
	})
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4),
		Parent = rail,
	})
	local b = { items = {}, rail = rail }
	h.boostRail = b

	-- { id, small label, has a countdown bar }
	local specs = {
		{ "Shield", "SHIELD", false },
		{ "Magnet", "MAGNET", true },
		{ "SlowMo", "SLOW-MO", true },
		{ "MegaBall", "MEGA BALL", true },
		{ "DoubleGems", "THIS RUN", false },
	}
	for order, spec in specs do
		local id = spec[1]
		local boost = boostInfo(id)
		if boost then
			local color = boost.Color or accentColor
			local frame = new("Frame", {
				Name = id,
				BackgroundColor3 = PAPER,
				BackgroundTransparency = 0.1,
				Size = UDim2.fromOffset(64, 30),
				LayoutOrder = order,
				Visible = false,
				Parent = rail,
			})
			stroke(frame, 1)
			local scale = new("UIScale", { Parent = frame })
			-- Ink icon block on the left.
			local block = new("Frame", { Name = "Mark", BackgroundColor3 = INK, Size = UDim2.new(0, 16, 1, 0), Parent = frame })
			if id == "Shield" then
				shieldGlyph(block, 10, UDim2.fromScale(0.5, 0.5), color)
			elseif id == "DoubleGems" then
				local gem = new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(7, 7),
					Rotation = 45,
					BackgroundColor3 = color,
					Parent = block,
				})
				stroke(gem, 1, PAPER, 0.3)
			else
				local swatch = new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(8, 8),
					BackgroundColor3 = color,
					Parent = block,
				})
				rule(swatch, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 1) })
			end
			text({ Text = spec[2], TextSize = 7, TextColor3 = GREY, Position = UDim2.fromOffset(20, 2), Size = UDim2.new(1, -22, 0, 9), Parent = frame })
			local value = capText(text({
				Text = "",
				Font = FONT_NUM,
				Position = UDim2.fromOffset(20, 11),
				Size = UDim2.new(1, -22, 0, 14),
				Parent = frame,
			}), 11, 6)
			local fill = nil
			if spec[3] then
				local track = new("Frame", {
					BackgroundColor3 = INK,
					BackgroundTransparency = 0.82,
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 16, 1, 0),
					Size = UDim2.new(1, -16, 0, 3),
					Parent = frame,
				})
				fill = new("Frame", { BackgroundColor3 = color, Size = UDim2.fromScale(1, 1), Parent = track })
			end
			b.items[id] = { frame = frame, value = value, fill = fill, scale = scale }
		end
	end
end

-- Only touches instances when something visible actually changed.
function UI._setIndicator(self, item, visible, number, fraction, label)
	if not item then
		return
	end
	if visible ~= item.visible then
		item.visible = visible
		item.frame.Visible = visible
		if visible then
			item.scale.Scale = 1.25
			tween(item.scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	end
	if not visible then
		return
	end
	if number ~= item.number then
		item.number = number
		item.value.Text = label
	end
	if item.fill and fraction then
		local rounded = math.floor(math.clamp(fraction, 0, 1) * 100 + 0.5) / 100
		if rounded ~= item.fraction then
			item.fraction = rounded
			item.fill.Size = UDim2.fromScale(rounded, 1)
		end
	end
end

function UI._refreshQuickShield(self)
	local h = self._hud
	local quick = h.quickShield
	if not quick then
		return
	end
	local shielded = h.boostRail ~= nil and h.boostRail.shield == true
	local show = h.balls ~= nil and h.balls <= LOW_BALLS_OFFER and not shielded
	if show ~= quick.shown then
		quick.shown = show
		quick.holder.Visible = show
		if show then
			quick.bump.Scale = 0.8
			tween(quick.bump, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	end
end

-- Forget what the rail showed; the next setBoosts redraws it from scratch.
function UI._resetBoostRail(self)
	local h = self._hud
	local b = h.boostRail
	if b then
		b.shield = nil
		b.shieldUsedAt = nil
		for _, item in b.items do
			item.visible = false
			item.number = nil
			item.fraction = nil
			item.frame.Visible = false
		end
	end
	if h.quickShield then
		h.quickShield.shown = nil
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
	if low and Settings.get("flashes") == false then
		h.alarm.BackgroundTransparency = 0.85 -- steady tint instead of a blinking alarm
	elseif low then
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

	-- Save didn't load: said here instead of offering a revive.
	local warning = new("Frame", { Name = "SaveWarning", BackgroundColor3 = INK, Size = UDim2.new(1, -SHADOW, 0, 52), LayoutOrder = 0, Visible = false, Parent = actions })
	hatch(warning, { Name = "Hatch", Size = UDim2.new(0, 8, 1, 0) }, PAPER, 0.45, 3)
	capText(setAccent(text({
		Text = "YOUR SAVE DIDN'T LOAD",
		Font = FONT_NUM,
		Position = UDim2.fromOffset(16, 9),
		Size = UDim2.new(1, -22, 0, 16),
		Parent = warning,
	}), "TextColor3"), 11, 7)
	text({
		Text = "REJOIN BEFORE BUYING ANYTHING",
		TextSize = 8,
		TextColor3 = PAPER,
		Position = UDim2.fromOffset(16, 29),
		Size = UDim2.new(1, -22, 0, 12),
		Parent = warning,
	})
	g.saveWarning = warning

	local revive = Config.Products.Revive
	local reviveGroup = new("Frame", { Name = "Revive", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62), LayoutOrder = 1, Visible = false, Parent = actions })
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
	self:_robuxButton(g.reviveButton)
	withPrice(revive.Id, Enum.InfoType.Product, function(price)
		g.reviveButton.sub.Text = "R$ " .. commas(price)
	end)

	g.playAgain = hardButton(actions, {
		Name = "PlayAgain",
		Fill = "accent",
		Text = "PLAY AGAIN",
		TextSize = 14,
		Size = UDim2.new(1, 0, 0, 54),
		LayoutOrder = 2,
		OnClick = function()
			self:_fire("onPlayAgain", self:_pickedBoosts())
		end,
	})
	-- MENU and the SETTINGS gear share the last row.
	local menuRow = new("Frame", { Name = "MenuRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 50), LayoutOrder = 3, Parent = actions })
	g.menuButton = hardButton(menuRow, {
		Name = "Menu",
		Fill = "paper",
		Text = "MENU",
		TextSize = 12,
		Size = UDim2.new(1, -SETTINGS_GEAR_W, 1, 0),
		OnClick = function()
			self:_fire("onMenu")
		end,
	})
	g.settingsButton = self:_gearButton(menuRow, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
	})
	g.menuButton.holder.NextSelectionRight = g.settingsButton.holder
	g.settingsButton.holder.NextSelectionLeft = g.menuButton.holder
	g.settingsButton.holder.NextSelectionUp = g.playAgain.holder
end

-- Settings ------------------------------------------------------------------------------
-- One sheet over whatever is showing (menu or run report). Every control writes
-- straight to Settings, and everything is redrawn from Settings.changed, so a
-- value changed anywhere (or loaded from the account a moment late) shows here.
--
-- Body (under the 24-unit header), top to bottom:
--   01 MUSIC slider / 02 SOUND FX slider (full width, 50 tall)
--   graphics hint line, then 03 GRAPHICS  AUTO | LOW | HIGH
--   04 VIBRATION | 05 CAMERA SHAKE | 06 FLASHES toggles
--   note (or controller hints) and CLOSE
-- On a short screen the sheet is cut to fit and the body scrolls.

local GRAPHICS_LABELS = { Auto = "AUTO", Low = "LOW", High = "HIGH" }
local SETTINGS_TOGGLES = {
	{ key = "vibration", label = "04 / VIBRATION" },
	{ key = "shake", label = "05 / CAMERA SHAKE" },
	{ key = "flashes", label = "06 / FLASHES" },
}

-- Small index + name block on the left of a settings row (sliders, graphics).
local function settingsLabel(face, index, label)
	local chip = new("Frame", { Position = UDim2.fromOffset(8, 7), Size = UDim2.fromOffset(5, 5), Parent = face })
	setAccent(chip, "BackgroundColor3")
	text({ Text = index, TextSize = 8, TextColor3 = GREY, Position = UDim2.fromOffset(17, 4), Size = UDim2.fromOffset(40, 10), Parent = face })
	capText(text({
		Text = label,
		Font = FONT_NUM,
		Position = UDim2.fromOffset(8, 17),
		Size = UDim2.fromOffset(SETTINGS_LABEL_W - 14, 24),
		Parent = face,
	}), 11, 6)
end

function UI._buildSettings(self)
	local s = { sliders = {}, toggles = {}, toggleList = {}, segments = {}, open = false }
	self._settings = s

	local layer = new("Frame", { Name = "Settings", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = self.gui })
	s.layer = layer
	local wash = new("TextButton", {
		Name = "Wash",
		AutoButtonColor = false,
		Text = "",
		Selectable = false, -- tap-outside-to-close only; never a gamepad stop
		BackgroundColor3 = PAPER,
		BackgroundTransparency = 0.25,
		Position = UDim2.fromOffset(-200, -200),
		Size = UDim2.new(1, 400, 1, 400),
		Parent = layer,
	})
	wash.Activated:Connect(function()
		self:_closeSettings()
	end)
	s.wash = wash
	blueprintGrid(layer, 12, 8, 0.9)

	local sheet, right = modalSheet(layer, "Sheet", SETTINGS_W, SETTINGS_HEADER + SETTINGS_BODY_H, "08", "SETTINGS")
	sheet.Visible = true -- the layer shows / hides it
	right.Text = "SAVED TO YOUR ACCOUNT"
	s.sheet = sheet

	local body = new("ScrollingFrame", {
		Name = "Body",
		Active = true,
		Selectable = false, -- gamepad selection goes to the controls; the body scrolls to follow it
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, SETTINGS_HEADER),
		Size = UDim2.new(1, 0, 1, -SETTINGS_HEADER),
		CanvasSize = UDim2.fromOffset(0, SETTINGS_BODY_H),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = INK,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		Parent = sheet,
	})
	s.body = body

	self:_buildSettingsSlider(body, "music", "01", "MUSIC", 6)
	self:_buildSettingsSlider(body, "sfx", "02", "SOUND FX", 60)

	text({
		Text = "LOW = SMOOTHER ON OLD PHONES",
		TextSize = 9,
		Position = UDim2.fromOffset(12, 114),
		Size = UDim2.new(0.55, -12, 0, 12),
		Parent = body,
	})
	s.graphicsAuto = text({
		Text = "",
		TextSize = 8,
		TextColor3 = GREY,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0.55, 0, 0, 114),
		Size = UDim2.new(0.45, -12, 0, 12),
		Parent = body,
	})
	self:_buildSettingsSegments(body, 128)

	local toggleRow = new("Frame", {
		Name = "Toggles",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 184),
		Size = UDim2.new(1, -24, 0, SETTINGS_ROW),
		Parent = body,
	})
	for order, spec in SETTINGS_TOGGLES do
		self:_buildSettingsToggle(toggleRow, spec.key, spec.label, order)
	end

	-- Bottom row: a note (touch / mouse) or controller hints, and CLOSE.
	s.note = text({
		Text = "CHANGES APPLY RIGHT AWAY",
		TextSize = 8,
		TextColor3 = GREY,
		Position = UDim2.fromOffset(12, 258),
		Size = UDim2.new(1, -190, 0, 12),
		Parent = body,
	})
	s.hint = inputHint(body, { { "D-PAD", "ADJUST" }, { "B", "CLOSE" } }, {
		Position = UDim2.fromOffset(12, 257),
		Size = UDim2.new(1, -190, 0, 14),
	}, Enum.HorizontalAlignment.Left)
	s.close = hardButton(body, {
		Name = "Close",
		Fill = "accent",
		Text = "CLOSE",
		TextSize = 13,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 240),
		Size = UDim2.fromOffset(150, SETTINGS_ROW),
		OnClick = function()
			self:_closeSettings()
		end,
	})

	-- Gamepad neighbours: straight lines down the sheet. Sliders have nothing to
	-- their left or right (they are full width and the sheet stops selection at
	-- its edges), so left / right on a slider only ever changes its value.
	-- Edges point at the control itself, so selection stays put there instead
	-- of jumping diagonally (and a slider never loses the selection sideways,
	-- even if the engine also reads the D-pad we sink).
	local music, sfx = s.sliders.music.holder, s.sliders.sfx.holder
	for _, holder in { music, sfx } do
		holder.NextSelectionLeft = holder
		holder.NextSelectionRight = holder
	end
	music.NextSelectionUp = music
	music.NextSelectionDown = sfx
	sfx.NextSelectionUp = music
	sfx.NextSelectionDown = s.segments[1] and s.segments[1].button -- then follows the chosen option
	local toggles = s.toggleList
	for i, segment in s.segments do
		local button = segment.button
		button.NextSelectionUp = sfx
		button.NextSelectionLeft = if i > 1 then s.segments[i - 1].button else button
		button.NextSelectionRight = if i < #s.segments then s.segments[i + 1].button else button
		local below = toggles[math.min(i, #toggles)]
		button.NextSelectionDown = below and below.button.holder
	end
	for i, entry in toggles do
		local holder = entry.button.holder
		local above = s.segments[math.min(i, #s.segments)]
		holder.NextSelectionUp = above and above.button
		holder.NextSelectionLeft = if i > 1 then toggles[i - 1].button.holder else holder
		holder.NextSelectionRight = if i < #toggles then toggles[i + 1].button.holder else holder
		holder.NextSelectionDown = s.close.holder
	end
	local close = s.close.holder
	close.NextSelectionUp = if #toggles > 0 then toggles[#toggles].button.holder else sfx
	close.NextSelectionDown = close
	close.NextSelectionLeft = close
	close.NextSelectionRight = close

	-- Dragging keeps following the finger / mouse even when it leaves the row.
	table.insert(self._connections, UserInputService.InputChanged:Connect(function(input)
		local drag = s.drag
		if drag and (input == drag.input or (drag.mouse and input.UserInputType == Enum.UserInputType.MouseMovement)) then
			self:_slideTo(drag.slider, input.Position.X)
		end
	end))
	table.insert(self._connections, UserInputService.InputEnded:Connect(function(input)
		local drag = s.drag
		if drag and (input == drag.input or (drag.mouse and input.UserInputType == Enum.UserInputType.MouseButton1)) then
			self:_endSliderDrag(drag)
		end
	end))

	self:_refreshSettings()
end

-- A full-width slider row: label | ruler track with accent fill and ink thumb | percent.
-- Touch / mouse: press anywhere on the track (or just beside it) and drag.
-- Gamepad: select the row, then left / right steps 10% (see _onSettingsAdjust).
function UI._buildSettingsSlider(self, parent, key, index, label, y)
	local s = self._settings
	local holder = new("TextButton", {
		Name = key,
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, y),
		Size = UDim2.new(1, -24, 0, SETTINGS_ROW),
		Parent = parent,
	})
	local face = new("Frame", { Name = "Face", BackgroundColor3 = PAPER, Size = UDim2.fromScale(1, 1), Parent = holder })
	stroke(face, 1, INK, 0.5)
	settingsLabel(face, index, label)
	rule(face, { Position = UDim2.fromOffset(SETTINGS_LABEL_W, 8), Size = UDim2.new(0, 1, 1, -16), BackgroundTransparency = 0.6 })
	rule(face, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -(SETTINGS_PCT_W + 4), 0, 8), Size = UDim2.new(0, 1, 1, -16), BackgroundTransparency = 0.6 })

	local trackLeft = SETTINGS_LABEL_W + 18
	local trackRight = SETTINGS_PCT_W + 22
	local track = new("Frame", {
		Name = "Track",
		BackgroundColor3 = INK,
		BackgroundTransparency = 0.82,
		Position = UDim2.fromOffset(trackLeft, 19),
		Size = UDim2.new(1, -(trackLeft + trackRight), 0, 6),
		Parent = face,
	})
	local fill = new("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), Parent = track })
	setAccent(fill, "BackgroundColor3")
	-- Ruler ticks every 10% (one D-pad step), longer at 0 / 50 / 100.
	for i = 0, 10 do
		local major = i % 5 == 0
		rule(track, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(i / 10, 0, 1, 5),
			Size = UDim2.fromOffset(1, if major then 7 else 4),
			BackgroundTransparency = if major then 0.2 else 0.5,
		})
	end
	local thumb = new("Frame", {
		Name = "Thumb",
		BackgroundColor3 = INK,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(12, 24),
		Parent = track,
	})
	rule(thumb, { BackgroundColor3 = PAPER, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 2, 1, -10) })
	local bump = new("UIScale", { Parent = thumb })
	local pct = capText(text({
		Text = "",
		Font = FONT_NUM,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 0),
		Size = UDim2.new(0, SETTINGS_PCT_W - 8, 1, 0),
		Parent = face,
	}), 13, 7)

	local slider = { key = key, holder = holder, track = track, fill = fill, thumb = thumb, bump = bump, pct = pct }
	s.sliders[key] = slider

	holder.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
			return
		end
		if s.drag or not s.open then
			return -- one finger at a time
		end
		local left, width = track.AbsolutePosition.X, track.AbsoluteSize.X
		local margin = 20 * effectiveScale(track)
		local x = input.Position.X
		if width < 1 or x < left - margin or x > left + width + margin then
			return -- a tap on the label or the readout doesn't move the slider
		end
		self:_beginSliderDrag(slider, input)
	end)
	return slider
end

-- 03 GRAPHICS: label cell + AUTO | LOW | HIGH on one hard-shadowed strip. Each
-- option's tap area is the full 50 units (face and shadow), like hardButton.
function UI._buildSettingsSegments(self, parent, y)
	local s = self._settings
	local strip = new("Frame", {
		Name = "Graphics",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, y),
		Size = UDim2.new(1, -24, 0, SETTINGS_ROW),
		Parent = parent,
	})
	new("Frame", { Name = "Shadow", BackgroundColor3 = INK, Position = UDim2.fromOffset(SHADOW, SHADOW), Size = UDim2.new(1, -SHADOW, 1, -SHADOW), Parent = strip })
	local face = new("Frame", { Name = "Face", BackgroundColor3 = PAPER, Size = UDim2.new(1, -SHADOW, 1, -SHADOW), Parent = strip })
	stroke(face, 2)
	settingsLabel(face, "03", "GRAPHICS")
	rule(face, { Position = UDim2.fromOffset(SETTINGS_LABEL_W, 0), Size = UDim2.new(0, 1, 1, 0) })

	local options = new("Frame", {
		Name = "Options",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(SETTINGS_LABEL_W + 1, 0),
		Size = UDim2.new(1, -(SETTINGS_LABEL_W + 1 + SHADOW), 1, 0),
		Parent = strip,
	})
	local count = #Config.GRAPHICS_OPTIONS
	for i, option in Config.GRAPHICS_OPTIONS do
		local button = new("TextButton", {
			Name = option,
			AutoButtonColor = false,
			Text = "",
			Selectable = true,
			BackgroundTransparency = 1,
			Position = UDim2.fromScale((i - 1) / count, 0),
			Size = UDim2.fromScale(1 / count, 1),
			Parent = options,
		})
		local fill = new("Frame", { Name = "Fill", BackgroundColor3 = INK, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -SHADOW), Parent = button })
		if i > 1 then
			rule(button, { Size = UDim2.new(0, 1, 1, -SHADOW), BackgroundTransparency = 0.5 })
		end
		local label = capText(text({
			Text = GRAPHICS_LABELS[option] or string.upper(option),
			Font = FONT_NUM,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(4, 0),
			Size = UDim2.new(1, -8, 1, -SHADOW),
			Parent = button,
		}), 12, 7)
		local bar = new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -SHADOW), Size = UDim2.new(1, 0, 0, 3), Visible = false, Parent = button })
		setAccent(bar, "BackgroundColor3")
		button.Activated:Connect(function()
			Settings.set("graphics", option)
		end)
		table.insert(s.segments, { option = option, button = button, fill = fill, label = label, bar = bar })
	end
end

-- An ON / OFF hard button with a small switch drawn on its right.
function UI._buildSettingsToggle(self, row, key, label, order)
	local s = self._settings
	local count = #SETTINGS_TOGGLES
	local button = hardButton(row, {
		Name = key,
		Fill = "paper",
		Text = "ON",
		TextSize = 12,
		Align = Enum.TextXAlignment.Left,
		Index = label,
		Position = UDim2.new((order - 1) / count, (order - 1) * 2, 0, 0),
		Size = UDim2.new(1 / count, -4, 1, 0),
		OnClick = function()
			Settings.set(key, Settings.get(key) ~= true)
		end,
	})
	button.label.Size = UDim2.new(1, -58, 1, -11)
	local switch = new("Frame", {
		Name = "Switch",
		BackgroundColor3 = PAPER,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 5),
		Size = UDim2.fromOffset(32, 16),
		Parent = button.face,
	})
	stroke(switch, 1.5)
	local knob = new("Frame", {
		Name = "Knob",
		BackgroundColor3 = INK,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(13, 10),
		Parent = switch,
	})
	local entry = { key = key, button = button, switch = switch, knob = knob }
	s.toggles[key] = entry
	table.insert(s.toggleList, entry)
	return entry
end

-- Fits the sheet to the safe area (called on every resize). Phones in landscape
-- get the full 340-unit sheet height, so it fits without scrolling; anything
-- shorter cuts the sheet and lets the body scroll. Crop marks only show when
-- there is room for them outside the sheet.
function UI._layoutSettings(self)
	local s = self._settings
	if not s then
		return
	end
	local size = self.gui.AbsoluteSize
	if size.X < 1 or size.Y < 1 or currentScale <= 0 then
		return
	end
	local availW = size.X / currentScale
	local availH = size.Y / currentScale
	local width = math.floor(math.min(SETTINGS_W, availW - 8))
	local height = math.floor(math.min(SETTINGS_HEADER + SETTINGS_BODY_H, availH - 8))
	height = math.max(height, SETTINGS_HEADER + SETTINGS_ROW)
	s.sheet.Size = UDim2.fromOffset(width, height)
	local roomy = availH >= height + 30 and availW >= width + 30
	for _, child in s.sheet:GetChildren() do
		if child.Name == "Crop" and child:IsA("GuiObject") then
			child.Visible = roomy
		end
	end
end

-- Redraws every control from Settings (cheap; runs on every change).
function UI._refreshSettings(self)
	local s = self._settings
	if not s then
		return
	end
	local values = Settings.all()
	local instant = s.drag ~= nil or not s.open
	for key, slider in s.sliders do
		self:_showSliderValue(slider, values[key], instant)
	end
	for _, entry in s.toggleList do
		local on = values[entry.key] == true
		entry.button.setText(if on then "ON" else "OFF")
		entry.button.label.TextColor3 = if on then INK else GREY
		entry.knob.AnchorPoint = Vector2.new(if on then 1 else 0, 0.5)
		entry.knob.Position = if on then UDim2.new(1, -2, 0.5, 0) else UDim2.new(0, 2, 0.5, 0)
		entry.switch.BackgroundColor3 = if on then INK else PAPER
		if on then
			setAccent(entry.knob, "BackgroundColor3")
		else
			clearAccent(entry.knob)
			entry.knob.BackgroundColor3 = INK
		end
	end
	for _, segment in s.segments do
		local active = segment.option == values.graphics
		segment.fill.BackgroundTransparency = if active then 0 else 1
		segment.label.TextColor3 = if active then PAPER else INK
		segment.bar.Visible = active
		if active and s.sliders.sfx then
			s.sliders.sfx.holder.NextSelectionDown = segment.button
		end
	end
	local ok, level = pcall(Settings.graphicsLevel)
	s.graphicsAuto.Text = if values.graphics == "Auto" and ok and type(level) == "string"
		then "AUTO = " .. string.upper(level) .. " ON THIS DEVICE"
		else ""
end

function UI._showSliderValue(self, slider, value, instant)
	value = math.clamp(tonumber(value) or 0, 0, 1)
	local percent = math.floor(value * 100 + 0.5)
	slider.pct.Text = if percent == 0 then "OFF" else percent .. "%"
	for _, running in slider.tweens or {} do
		running:Cancel()
	end
	slider.tweens = nil
	local fillSize = UDim2.fromScale(value, 1)
	local thumbPosition = UDim2.fromScale(value, 0.5)
	if instant then
		slider.fill.Size = fillSize
		slider.thumb.Position = thumbPosition
	else
		slider.tweens = {
			tween(slider.fill, 0.12, { Size = fillSize }),
			tween(slider.thumb, 0.12, { Position = thumbPosition }),
		}
	end
end

function UI._slideTo(self, slider, x)
	local track = slider.track
	local width = track.AbsoluteSize.X
	if width < 1 then
		return
	end
	local value = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
	Settings.set(slider.key, math.floor(value * 100 + 0.5) / 100)
end

function UI._beginSliderDrag(self, slider, input)
	local s = self._settings
	local drag = { slider = slider, input = input, mouse = input.UserInputType == Enum.UserInputType.MouseButton1 }
	s.drag = drag
	s.body.ScrollingEnabled = false -- the finger moves the slider, not the page
	self:_stopHold()
	drag.changed = input.Changed:Connect(function()
		local state = input.UserInputState
		if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			self:_endSliderDrag(drag)
		end
	end)
	slider.bump.Scale = 1.2
	self:_slideTo(slider, input.Position.X)
end

function UI._endSliderDrag(self, drag)
	local s = self._settings
	drag = drag or s.drag
	if drag == nil or s.drag ~= drag then
		return
	end
	s.drag = nil
	if drag.changed then
		drag.changed:Disconnect()
	end
	s.body.ScrollingEnabled = true
	tween(drag.slider.bump, 0.18, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- The slider the gamepad selection is on, or nil.
function UI._selectedSlider(self)
	local s = self._settings
	local selected = GuiService.SelectedObject
	if not s or not s.open or selected == nil then
		return nil
	end
	for _, slider in s.sliders do
		if slider.holder == selected then
			return slider
		end
	end
	return nil
end

-- One gamepad step: to the next 10% mark in that direction (63% -> 70% / 60%).
function UI._stepSlider(self, slider, dir)
	local value = math.clamp(tonumber(Settings.get(slider.key)) or 0, 0, 1)
	local target
	if dir > 0 then
		target = math.floor(value * 10 + 1e-6) / 10 + SLIDER_STEP
	else
		target = math.ceil(value * 10 - 1e-6) / 10 - SLIDER_STEP
	end
	target = math.clamp(math.floor(target * 100 + 0.5) / 100, 0, 1)
	if target ~= value then
		Settings.set(slider.key, target)
		slider.bump.Scale = 1.25
		tween(slider.bump, 0.18, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

-- Holding the D-pad (or the stick) keeps stepping after a short pause.
function UI._startHold(self, source, dir)
	local s = self._settings
	local slider = self:_selectedSlider()
	if slider == nil then
		self:_stopHold(source)
		return false
	end
	local hold = { source = source, dir = dir }
	s.hold = hold
	self:_stepSlider(slider, dir)
	task.delay(SLIDER_REPEAT_DELAY, function()
		while s.hold == hold and s.open do
			local current = self:_selectedSlider()
			if current == nil then
				break
			end
			self:_stepSlider(current, dir)
			task.wait(SLIDER_REPEAT_EVERY)
		end
	end)
	return true
end

function UI._stopHold(self, source)
	local s = self._settings
	if s and s.hold and (source == nil or s.hold.source == source) then
		s.hold = nil
	end
end

-- Gamepad left / right while the sheet is open. On a slider the D-pad is
-- sunk (so it changes the value instead of moving the selection); anywhere else
-- it passes through to normal navigation. Up / down are never bound, so they
-- always move between rows. The stick always passes through: on a slider the
-- navigation has nowhere to go sideways anyway.
function UI._onSettingsAdjust(self, inputState, input)
	local s = self._settings
	if not s or not s.open then
		return Enum.ContextActionResult.Pass
	end
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		local position = input.Position
		local dir = 0
		local ended = inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel
		if not ended and math.abs(position.X) > STICK_THRESHOLD and math.abs(position.X) > math.abs(position.Y) then
			dir = if position.X > 0 then 1 else -1
		end
		local holding = s.hold and s.hold.source == "stick" and s.hold.dir or 0
		if dir == 0 then
			self:_stopHold("stick")
		elseif dir ~= holding then
			self:_startHold("stick", dir)
		end
		return Enum.ContextActionResult.Pass
	end
	local dir = if input.KeyCode == Enum.KeyCode.DPadLeft then -1 else 1
	if inputState == Enum.UserInputState.Begin then
		if self:_startHold(input.KeyCode, dir) then
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		local held = s.hold ~= nil and s.hold.source == input.KeyCode
		self:_stopHold(input.KeyCode)
		return if held then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	end
	return Enum.ContextActionResult.Pass
end

function UI._bindSettingsAdjust(self, on)
	local s = self._settings
	if on == (s.adjustBound == true) then
		return
	end
	s.adjustBound = on
	if on then
		ContextActionService:BindActionAtPriority(SETTINGS_ACTION, function(_, inputState, input)
			return self:_onSettingsAdjust(inputState, input)
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.DPadLeft, Enum.KeyCode.DPadRight, Enum.KeyCode.Thumbstick1)
	else
		ContextActionService:UnbindAction(SETTINGS_ACTION)
	end
end

-- Opens the sheet over the menu or the run report. `opener` gets the gamepad
-- selection back when it closes.
function UI._openSettings(self, opener)
	local s = self._settings
	if not s or s.open or self._hud.layer.Visible then
		return
	end
	s.open = true
	s.returnTo = opener or GuiService.SelectedObject
	s.layer.Visible = true
	self:_layoutSettings()
	self:_refreshSettings()
	s.body.CanvasPosition = Vector2.zero
	s.wash.BackgroundTransparency = 1
	tween(s.wash, 0.25, { BackgroundTransparency = 0.25 })
	s.sheet.Position = UDim2.new(0.5, 0, 0.5, 16)
	tween(s.sheet, 0.3, { Position = UDim2.fromScale(0.5, 0.5) })
	-- The gear on the button turns a quarter (it looks the same at rest).
	local face = opener and opener:FindFirstChild("Face")
	local gear = face and face:FindFirstChild("Gear")
	if gear and gear:IsA("GuiObject") then
		gear.Rotation = 0
		tween(gear, 0.45, { Rotation = 90 }, Enum.EasingStyle.Back)
	end
	self:_bindSettingsAdjust(true)
	self:_syncBack()
	self:_refreshHints()
	self:_focus(s.sliders.music.holder)
end

-- `quiet`: the screen underneath is changing anyway, so don't move the selection.
function UI._closeSettings(self, quiet)
	local s = self._settings
	if not s or not s.open then
		return
	end
	s.open = false
	self:_endSliderDrag()
	self:_stopHold()
	s.layer.Visible = false
	self:_bindSettingsAdjust(false)
	self:_syncBack()
	self:_refreshHints()
	local returnTo = s.returnTo
	s.returnTo = nil
	if not quiet then
		self:_returnFocus(s.layer, returnTo)
	end
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
		Position = UDim2.fromScale(0.5, ZONE_CARD_Y),
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
	z.card.Position = UDim2.new(0.5, 0, ZONE_CARD_Y, 12)
	z.ruleLeft.Size = UDim2.fromOffset(0, 1)
	z.ruleRight.Size = UDim2.fromOffset(0, 1)
	z.bar.Size = UDim2.new(0, 0, 0, 5)
	tween(z.card, 0.3, { GroupTransparency = 0, Position = UDim2.fromScale(0.5, ZONE_CARD_Y) })
	tween(z.ruleLeft, 0.35, { Size = UDim2.fromOffset(120, 1) })
	tween(z.ruleRight, 0.35, { Size = UDim2.fromOffset(120, 1) })
	tween(z.bar, holdTime, { Size = UDim2.new(1, 0, 0, 5) }, Enum.EasingStyle.Linear)
	task.delay(holdTime, function()
		if z.token ~= token then
			return
		end
		tween(z.card, 0.25, { GroupTransparency = 1, Position = UDim2.new(0.5, 0, ZONE_CARD_Y, -10) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
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

	-- Shield break: a diamond ring bursting outwards (the controller adds the
	-- shards and tint in the world).
	local shield = boostInfo("Shield")
	local color = shield and shield.Color or PAPER
	local ring = new("Frame", {
		Name = "ShieldRing",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(60, 60),
		Rotation = 45,
		Visible = false,
		Parent = layer,
	})
	local ringStroke = stroke(ring, 3, color, 1)
	self._shieldFlash = { ring = ring, ringStroke = ringStroke, last = 0 }

	-- With flashes off, a hit shows as a thin red line around the screen that
	-- fades out, instead of the full red wash.
	local edge = new("Frame", {
		Name = "DamageEdge",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
		Parent = layer,
	})
	self._damageEdge = stroke(edge, 3, DANGER, 1)
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

-- Robux buttons: drawn off until the save loaded; a tap then says why.
function UI._robuxButton(self, button)
	self._robuxButtons[button] = true
	button.onBlocked = function()
		self:_robuxRefused()
	end
	button.setEnabled(saveLoaded())
	return button
end

function UI._robuxRefused(self)
	if saveFailed() then
		self:toast(SAVE_FAILED_TEXT, "error")
	else
		self:toast(SAVE_LOADING_TEXT, "info")
	end
end

-- DataLoaded / DataFailed changed (or anything that shows Robux offers redrew).
function UI._refreshSaveState(self)
	local loaded = saveLoaded()
	local failed = saveFailed()
	for button in self._robuxButtons do
		if button.holder.Parent then
			if button.enabled ~= loaded then
				button.setEnabled(loaded)
			end
		else
			self._robuxButtons[button] = nil -- its row was rebuilt
		end
	end
	local m = self._menu
	if m.saveBanner.Visible ~= failed then
		m.saveBanner.Visible = failed
		local bottom = FOOTER_H + (if failed then SAVE_BANNER_H else 0)
		for _, tab in m.tabs do
			tab.page.Size = UDim2.new(1, 0, 1, -(TAB_H + 1 + bottom))
		end
	end
	self._over.saveWarning.Visible = failed
	if not loaded then
		self:_hideTopUp()
		self:hideRevive()
	end
	self:_refreshStarter()
	self:_refreshSeasonUnlock()
end

-- Fire-and-forget callbacks run in their own thread so errors keep their stack trace.
-- Robux prompts are refused (with the reason) until the save has loaded.
function UI._fire(self, name, ...)
	if ROBUX_CALLBACKS[name] and not saveLoaded() then
		self:_robuxRefused()
		return
	end
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
	self:_refreshBoosts()
	self:_refreshSaveState()
end

-- Gamepad selection -------------------------------------------------------------------
-- Nothing here does anything unless the last input came from a controller.

-- Puts the gamepad selection on `target` (a button that is on screen).
function UI._focus(self, target)
	if not self._gamepad or target == nil then
		return
	end
	GuiService.SelectedObject = target
	-- The engine can drop a selection made in the same frame something opens or
	-- closes (B also clears it by default); put it back once things settle.
	task.delay(0.05, function()
		if self._gamepad and GuiService.SelectedObject == nil and onScreen(target) then
			GuiService.SelectedObject = target
		end
	end)
end

-- The button a gamepad player should land on for whatever is showing, or nil
-- during a run (so A / R2 go to the game, not the UI).
function UI._primary(self)
	local settings = self._settings
	if settings and settings.open then
		return settings.sliders.music.holder
	end
	local m = self._menu
	if m.root.Visible then
		if m.modalOpen then
			return self:_modalPrimary()
		end
		local t = self._topUp
		if t and t.strip.Visible then
			return t.buy.holder
		end
		local pop = m.boostPop
		if pop and pop.frame.Visible then
			return pop.gems.holder
		end
		return m.play.holder
	end
	local g = self._over
	if g.root.Visible then
		return if g.reviveGroup.Visible then g.reviveButton.holder else g.playAgain.holder
	end
	return nil
end

-- After `container` closed: if the selection was in it (or got dropped), move it
-- back to `target` (what opened it), or to the screen's main button.
function UI._returnFocus(self, container, target)
	if not self._gamepad then
		return
	end
	local selected = GuiService.SelectedObject
	if selected ~= nil and selected ~= container and not selected:IsDescendantOf(container) then
		return -- the player had already moved on
	end
	if target and target.Selectable and onScreen(target) then
		self:_focus(target)
	else
		self:_focus(self:_primary())
	end
end

-- Rows get rebuilt when data changes (claiming a mission...). Remember where the
-- selection was by name, so it can land in the same place afterwards.
function UI._captureFocus(self, container)
	local selected = GuiService.SelectedObject
	if not self._gamepad or selected == nil or not selected:IsDescendantOf(container) then
		return nil
	end
	local path = {}
	local node = selected
	while node and node ~= container do
		table.insert(path, 1, node.Name)
		node = node.Parent
	end
	return path
end

function UI._restoreFocus(self, container, path, fallback)
	if path == nil or not self._gamepad then
		return
	end
	local node = container
	for _, name in path do
		node = node and node:FindFirstChild(name)
	end
	if node and node:IsA("GuiButton") and node.Selectable and onScreen(node) then
		self:_focus(node)
		return
	end
	-- That button is gone (claimed...): the same row's other button, any row's, or the tab.
	local row = container:FindFirstChild(path[1])
	self:_focus(firstSelectable(row) or firstSelectable(container) or fallback)
end

function UI._popoverOpen(self)
	local settings = self._settings
	if settings and settings.open then
		return true -- over the menu or the run report
	end
	local m = self._menu
	if not m.root.Visible then
		return false
	end
	local t = self._topUp
	local pop = m.boostPop
	return m.modalOpen ~= nil or (pop ~= nil and pop.frame.Visible) or (t ~= nil and t.strip.Visible)
end

-- Gamepad B closes the top-most popover. Bound only while one is open, so B is
-- free for everything else the rest of the time.
function UI._syncBack(self)
	local open = self:_popoverOpen()
	if open ~= (self._backBound == true) then
		self._backBound = open
		if open then
			ContextActionService:BindActionAtPriority(BACK_ACTION, function(_, inputState)
				if inputState == Enum.UserInputState.Begin then
					self:_back()
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonB)
		else
			ContextActionService:UnbindAction(BACK_ACTION)
		end
	end
end

function UI._back(self)
	local m = self._menu
	local t = self._topUp
	if self._settings and self._settings.open then
		self:_closeSettings() -- always the top-most sheet
	elseif t and t.strip.Visible then
		self:_hideTopUp()
	elseif m.boostPop and m.boostPop.frame.Visible then
		self:_closeBoostPop()
	elseif m.modalOpen then
		self:_closeModal()
	end
end

-- Controller hints: menu footer, and "R2 THROW" under the balls during the first run.
function UI._refreshHints(self)
	local gamepad = self._gamepad == true
	local m = self._menu
	m.footerHint.Visible = gamepad
	m.footerSpec.Visible = not gamepad
	local s = self._settings
	if s then
		s.hint.Visible = gamepad
		s.note.Visible = not gamepad
	end
	local h = self._hud
	local throw = gamepad and h.layer.Visible and self._runsEnded == 0
	h.throwHint.Visible = throw
	if h.boostRail then
		h.boostRail.rail.Position = UDim2.new(0.5, 0, 1, if throw then 22 else 6)
	end
end

function UI._setGamepad(self, gamepad)
	if gamepad == self._gamepad then
		return
	end
	self._gamepad = gamepad
	if gamepad then
		if GuiService.SelectedObject == nil then
			self:_focus(self:_primary())
		end
	else
		-- Back on touch / mouse: don't leave a selection box hanging around.
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(self.gui) then
			GuiService.SelectedObject = nil
		end
	end
	self:_refreshHints()
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
	self._robuxButtons = setmetatable({}, { __mode = "k" }) -- see _robuxButton
	self._runsEnded = 0 -- game overs this session (the "R2 THROW" hint shows until the first)
	self._gamepad = gamepadAtStart()

	local playerGui = player:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("ShatterRunUI")
	if old then
		old:Destroy()
	end

	-- CoreUISafeInsets: the usable area starts below Roblox's top bar and inside
	-- the notch / home bar, so no text or button can end up under them.
	-- Not clipping lets the full-screen washes (see `bleed`) still reach every edge.
	self.gui = new("ScreenGui", {
		Name = "ShatterRunUI",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ClipToDeviceSafeArea = false,
		DisplayOrder = 10,
	})

	-- One blueprint selection box for every gamepad-selected button in PlayerGui.
	local box, boxStroke = selectionBox()
	self._selectionStroke = boxStroke
	playerGui.SelectionImageObject = box

	-- Back to front.
	self:_buildMenu()
	self:_buildHud()
	self:_buildGameOver()
	self:_buildSettings()
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
		self:_layoutSettings()
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
		self:_rebuildPasses() -- the CHECKPOINTS card shows once a zone is reached
	end)
	for _, name in { "DataLoaded", "DataFailed" } do
		onAttribute(name, function()
			self:_refreshSaveState()
		end)
	end
	onAttribute("EquippedSkin", function()
		self:_refreshSkins()
	end)
	onAttribute("OwnedSkins", function()
		self:_refreshSkins()
	end)
	for _, name in { "NextDaily", "StreakDay", "StreakExpires" } do
		onAttribute(name, function()
			if name ~= "NextDaily" then
				self._saverPendingUntil = nil -- the streak changed: the saver (if any) has landed
			end
			self:_refreshDaily()
		end)
	end
	-- Streak saver prompt closed: cancelled frees CLAIM now; paid keeps it off
	-- until the server saves the streak (the attribute change above).
	connect(MarketplaceService.PromptProductPurchaseFinished, function(userId, id, purchased)
		if userId ~= player.UserId or id ~= productId("StreakSaver") or self._saverPendingUntil == nil then
			return
		end
		self._saverPendingUntil = if purchased then os.clock() + SAVER_GRANT_WAIT else nil
		self:_refreshDaily()
	end)
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
	onAttribute("Boosts", function()
		self:_refreshBoosts()
	end)
	onAttribute("Stats", function()
		self:_checkWelcome()
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

	-- Settings apply live: redraw the sheet, and follow flashes / shake in the HUD.
	connect(Settings.changed, function(key)
		self:_refreshSettings()
		local h = self._hud
		if key == "flashes" then
			if h.low then
				self:_setLow(true) -- pulsing alarm <-> steady tint
			end
			if Settings.get("flashes") == false then
				for _, frame in self._vignette do
					frame.BackgroundTransparency = 1
				end
			end
		elseif key == "shake" and Settings.get("shake") == false then
			self._shakeToken = nil
			h.root.Position = UDim2.new()
		end
	end)

	-- Gamepad: follow the last input, and never leave a gamepad player with
	-- nothing selected on a menu-type screen (B clears the selection by default).
	connect(UserInputService.LastInputTypeChanged, function(inputType)
		local kind = inputKind(inputType)
		if kind then
			self:_setGamepad(kind == "gamepad" and UserInputService.GamepadEnabled)
		end
	end)
	connect(UserInputService.GamepadDisconnected, function()
		if not UserInputService.GamepadEnabled then
			self:_setGamepad(false)
		end
	end)
	connect(GuiService:GetPropertyChangedSignal("SelectedObject"), function()
		if GuiService.SelectedObject ~= nil or not self._gamepad then
			return
		end
		local token = {}
		self._refocusToken = token
		task.delay(0.15, function()
			if self._refocusToken == token and self._gamepad and GuiService.SelectedObject == nil then
				local target = self:_primary()
				if target and onScreen(target) then
					GuiService.SelectedObject = target
				end
			end
		end)
	end)

	connect(self.gui.Destroying, function()
		self._alive = false
		for _, connection in self._connections do
			connection:Disconnect()
		end
		if self._backBound then
			self._backBound = false
			ContextActionService:UnbindAction(BACK_ACTION)
		end
		if self._settings and self._settings.adjustBound then
			self._settings.adjustBound = false
			ContextActionService:UnbindAction(SETTINGS_ACTION)
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
	self:_refreshHints()
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
	-- Passes bought outside the game (or a check that failed on join) show up
	-- without a rejoin. Fire-and-forget: the server sets the Pass_ attributes.
	task.spawn(function()
		self:_ask("onShop", "RecheckPasses")
	end)

	m.left.Position = UDim2.new(0, EDGE - 16, 0.5, 0)
	tween(m.left, 0.35, { Position = UDim2.new(0, EDGE + 4, 0.5, 0) })
	m.panel.Position = UDim2.new(1, -(EDGE - 20), 0.5, 0)
	tween(m.panel, 0.35, { Position = UDim2.new(1, -(EDGE + 4), 0.5, 0) })
	local play = m.play.face
	play.Position = UDim2.fromOffset(2, 2)
	tween(play, 0.3, { Position = UDim2.new() }, Enum.EasingStyle.Back)
	self:_refreshHints()
	self:_focus(self:_primary()) -- PLAY, or the starter offer if it just opened
end

function UI:showHud()
	self:_closeSettings(true)
	self:hideRevive()
	self:_closeModal()
	-- A run is starting (or resuming): picks were handed over with onPlay.
	self:_closeBoostPop()
	self:_hideTopUp()
	if self._menu.boostPicks and #self._menu.boostPicks > 0 then
		table.clear(self._menu.boostPicks)
		self:_refreshBoosts()
	end
	self:_resetBoostRail()
	self._menu.root.Visible = false
	self._over.root.Visible = false
	self._hud.layer.Visible = true
	self:_syncBack()
	self:_refreshHints()
	-- No UI selection during a run, so the controller's buttons throw instead of clicking.
	GuiService.SelectedObject = nil
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

	self:_refreshQuickShield()
end

--[[
	Active boosts, called every frame by the controller:
	{ shield = bool, magnet = secondsLeft, slowmo = secondsLeft, megaball = throwsLeft, doubleGems = bool }
	Only properties that changed are written.
]]
function UI:setBoosts(state)
	local h = self._hud
	local b = h and h.boostRail
	if type(state) ~= "table" or not b then
		return
	end
	local items = b.items

	local shield = state.shield == true
	if shield ~= b.shield then
		local was = b.shield
		b.shield = shield
		if was == true and not shield and h.layer.Visible then
			self:flashShield()
		end
		self:_refreshQuickShield()
	end
	local justUsed = not shield and b.shieldUsedAt ~= nil and os.clock() - b.shieldUsedAt < SHIELD_USED_HOLD
	if shield then
		self:_setIndicator(items.Shield, true, 1, nil, "ON")
	else
		self:_setIndicator(items.Shield, justUsed, 0, nil, "USED")
	end

	for _, entry in { { "Magnet", "magnet" }, { "SlowMo", "slowmo" } } do
		local seconds = math.max(0, tonumber(state[entry[2]]) or 0)
		local boost = boostInfo(entry[1])
		local duration = math.max(tonumber(boost and boost.Duration) or 1, seconds, 0.001)
		local whole = math.ceil(seconds)
		self:_setIndicator(items[entry[1]], seconds > 0, whole, seconds / duration, whole .. "S")
	end

	local throws = math.max(0, math.floor(tonumber(state.megaball) or 0))
	local mega = boostInfo("MegaBall")
	local maxThrows = math.max(tonumber(mega and mega.Throws) or 1, throws, 1)
	self:_setIndicator(items.MegaBall, throws > 0, throws, throws / maxThrows, "x" .. throws)

	self:_setIndicator(items.DoubleGems, state.doubleGems == true, 1, nil, "2X GEMS")
end

-- The shield just absorbed a crash. Safe to call more than once per crash.
function UI:flashShield()
	local f = self._shieldFlash
	if not f then
		return
	end
	local now = os.clock()
	if now - f.last < 0.3 then
		return
	end
	f.last = now
	if Settings.get("flashes") ~= false then
		f.ring.Visible = true
		f.ring.Size = UDim2.fromOffset(60, 60)
		f.ringStroke.Transparency = 0
		tween(f.ring, 0.45, { Size = UDim2.fromOffset(420, 420) })
		tween(f.ringStroke, 0.45, { Transparency = 1 })
	end
	-- setBoosts keeps the shield plate up for a beat, reading USED.
	local rail = self._hud.boostRail
	if rail then
		rail.shieldUsedAt = now
		local item = rail.items.Shield
		if item and item.visible then
			item.scale.Scale = 1.3
			tween(item.scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	end
end

function UI:showGameOver(info)
	info = info or {}
	local g = self._over
	self:_closeSettings(true)
	self._hud.layer.Visible = false
	self._menu.root.Visible = false
	g.root.Visible = true
	self._runsEnded += 1
	self:_syncBack()
	self:_refreshHints()

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
	g.saveWarning.Visible = saveFailed()
	if info.canRevive and Config.Products.Revive.Id ~= 0 and saveLoaded() then
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
	self:_focus(self:_primary()) -- REVIVE while it's on offer, else PLAY AGAIN
end

function UI:hideRevive()
	local g = self._over
	local countdown = g.reviveTween
	g.reviveTween = nil
	if countdown then
		countdown:Cancel()
	end
	local wasVisible = g.reviveGroup.Visible
	g.reviveGroup.Visible = false
	if wasVisible and g.root.Visible then
		self:_returnFocus(g.reviveGroup, g.playAgain.holder)
	end
end

function UI:toast(value, kind)
	value = string.upper(tostring(value or ""))
	kind = kind or "info"
	if kind == "checkpoint" then
		self:_showZoneCard(value)
		return
	end
	local style = TOAST_KINDS[kind] or TOAST_KINDS.info
	-- The same words twice within a second (e.g. controller + server event) show once.
	local now = os.clock()
	if value == self._lastToastText and now - (self._lastToastAt or 0) < 1 then
		return
	end
	self._lastToastText = value
	self._lastToastAt = now

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

-- Respects the player's settings: "flashes" off swaps the red wash for a thin
-- fading red edge, "shake" off keeps the HUD still.
function UI:flashDamage()
	if Settings.get("flashes") == false then
		local edge = self._damageEdge
		if edge then
			edge.Transparency = 0.3
			tween(edge, 0.7, { Transparency = 1 }, Enum.EasingStyle.Sine)
		end
	else
		for _, frame in self._vignette do
			frame.BackgroundTransparency = 0.05
			tween(frame, 0.45, { BackgroundTransparency = 1 })
		end
	end
	if Settings.get("shake") ~= false then
		self:_shake(self._hud.root, 7)
	end
end

function UI:setTheme(theme)
	if type(theme) ~= "table" or typeof(theme.Accent) ~= "Color3" then
		return
	end
	accentColor = theme.Accent
	if self._selectionStroke then
		self._selectionStroke.Color = accentColor
	end
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
	elseif kind == "BoostsActivated" then
		local names = {}
		if type(event.boosts) == "table" then
			for _, id in event.boosts do
				if type(id) == "string" then
					table.insert(names, boostName(id))
				end
			end
		end
		if #names > 0 and self._hud.layer.Visible then
			self:toast(table.concat(names, " + ") .. " ON", "boost")
		end
	end
end

return UI
