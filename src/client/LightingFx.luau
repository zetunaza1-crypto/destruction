--[[
	Realistic lighting for each zone, plus real lights inside every room.

	- Each zone style has its own time of day, ambient light, atmosphere haze,
	  color grading and bloom. Crossing a checkpoint fades smoothly to the next.
	- lightRoom() turns a room's biggest glowing (Neon) parts into actual light
	  sources and lets decorations cast shadows, so nothing looks flat.
	- Shadow-casting lights are expensive, so only the room the camera is in
	  and the next one get one (setShadowRooms, called by TrackBuilder when the
	  camera enters a new room). All other room lights have no shadows.
	Requires Lighting.Technology = Future in the place (set in place.project.json).
	Everything here runs on the player's own device only.

	Graphics setting (Settings.graphicsLevel(), changes apply right away):
	  High - everything above.
	  Low  - no room lights, no shadows at all, softer bloom and sun rays.
	         Switching to Low also switches off lights/shadows in rooms already
	         built; switching back to High lights them up again.
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Settings = require(script.Parent.Settings)

local LightingFx = {}

local FADE = TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

local LIGHTS_PER_ROOM = 4
local PARTS_PER_PAUSE_CHECK = 16 -- lightRoom checks the build time budget this often
local SHADOW_CASTER_MAX_SIZE = 15 -- the room shell (80 studs long) never casts
local SHADOW_CASTER_MIN_SIZE = 1.5 -- tiny details (seams, trim, glyph bars) never cast either
-- Phones and tablets: no shadow-casting lights (too heavy for their GPUs).
local TOUCH_ONLY = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- Low graphics: lighter glow effects.
local LOW_BLOOM_INTENSITY = 0.5 -- multiplier
local LOW_BLOOM_SIZE = 0.7 -- multiplier
local HIGH_SUNRAYS = 0.04
local LOW_SUNRAYS = 0.015

-- Per zone style. Colors are Color3, numbers are the Lighting/effect properties.
local PRESETS = {
	Lab = {
		ClockTime = 14,
		Brightness = 2.4,
		Ambient = Color3.fromRGB(105, 112, 125),
		OutdoorAmbient = Color3.fromRGB(150, 158, 170),
		ExposureCompensation = 0.1,
		Atmosphere = { Density = 0.38, Offset = 0.1, Haze = 1, Glare = 0 },
		Grade = { Brightness = 0.02, Contrast = 0.08, Saturation = 0.05, TintColor = Color3.fromRGB(240, 248, 255) },
		Bloom = { Intensity = 0.55, Size = 24, Threshold = 1.1 },
		LightBrightness = 1.4,
		LightRange = 16,
	},
	Neon = {
		ClockTime = 0,
		Brightness = 0.4,
		Ambient = Color3.fromRGB(38, 36, 58),
		OutdoorAmbient = Color3.fromRGB(50, 45, 75),
		ExposureCompensation = 0.2,
		Atmosphere = { Density = 0.45, Offset = 0.05, Haze = 2, Glare = 0.3 },
		Grade = { Brightness = 0, Contrast = 0.18, Saturation = 0.22, TintColor = Color3.fromRGB(255, 235, 250) },
		Bloom = { Intensity = 1.1, Size = 30, Threshold = 0.85 },
		LightBrightness = 2.2,
		LightRange = 18,
	},
	Temple = {
		ClockTime = 17.6,
		Brightness = 2,
		Ambient = Color3.fromRGB(120, 88, 60),
		OutdoorAmbient = Color3.fromRGB(165, 125, 90),
		ExposureCompensation = 0,
		Atmosphere = { Density = 0.42, Offset = 0.15, Haze = 2.2, Glare = 0.6 },
		Grade = { Brightness = 0.01, Contrast = 0.12, Saturation = 0.12, TintColor = Color3.fromRGB(255, 236, 214) },
		Bloom = { Intensity = 0.8, Size = 28, Threshold = 0.95 },
		LightBrightness = 1.8,
		LightRange = 16,
	},
	Greenhouse = {
		ClockTime = 12.5,
		Brightness = 3,
		Ambient = Color3.fromRGB(95, 120, 95),
		OutdoorAmbient = Color3.fromRGB(150, 175, 145),
		ExposureCompensation = 0,
		Atmosphere = { Density = 0.4, Offset = 0.2, Haze = 2.5, Glare = 0.2 },
		Grade = { Brightness = 0.02, Contrast = 0.06, Saturation = 0.15, TintColor = Color3.fromRGB(245, 255, 235) },
		Bloom = { Intensity = 0.5, Size = 26, Threshold = 1.15 },
		LightBrightness = 1.2,
		LightRange = 14,
	},
	Void = {
		ClockTime = 0,
		Brightness = 0.25,
		Ambient = Color3.fromRGB(48, 30, 70),
		OutdoorAmbient = Color3.fromRGB(60, 40, 90),
		ExposureCompensation = 0.25,
		Atmosphere = { Density = 0.5, Offset = 0, Haze = 1.5, Glare = 0.4 },
		Grade = { Brightness = 0, Contrast = 0.2, Saturation = 0.18, TintColor = Color3.fromRGB(240, 225, 255) },
		Bloom = { Intensity = 1.3, Size = 34, Threshold = 0.8 },
		LightBrightness = 2.4,
		LightRange = 18,
	},
}

local atmosphere
local grade
local bloom
local sunRays
local currentTheme = nil
local bloomTween = nil -- the zone fade, cancelled if the graphics level changes mid-fade
local low = Settings.graphicsLevel() == "Low"

-- Rooms that went through lightRoom: roomFolder -> { theme, lights = { PointLight }, casters = { BasePart }, shadowLight }.
-- Weak keys: a room deleted behind the camera just drops out.
local rooms = setmetatable({}, { __mode = "k" })
-- Room folders allowed a shadow-casting light right now (at most 2, see setShadowRooms).
local shadowRooms = setmetatable({}, { __mode = "k" })

local function presetFor(theme)
	return PRESETS[theme and theme.Style or "Lab"] or PRESETS.Lab
end

function LightingFx.isLow()
	return low
end

local function bloomGoal(preset)
	if not low then
		return preset.Bloom
	end
	return {
		Intensity = preset.Bloom.Intensity * LOW_BLOOM_INTENSITY,
		Size = preset.Bloom.Size * LOW_BLOOM_SIZE,
		Threshold = preset.Bloom.Threshold,
	}
end

-- Global switches that depend on the graphics level.
local function applyQuality()
	Lighting.GlobalShadows = not low
	if sunRays then
		sunRays.Intensity = if low then LOW_SUNRAYS else HIGH_SUNRAYS
	end
end

-- Replaces whatever the place had (the Baseplate template ships its own
-- Atmosphere/Bloom) with our own effects.
function LightingFx.setup()
	for _, child in Lighting:GetChildren() do
		if
			child:IsA("Atmosphere")
			or child:IsA("BloomEffect")
			or child:IsA("ColorCorrectionEffect")
			or child:IsA("SunRaysEffect")
			or child:IsA("DepthOfFieldEffect")
		then
			child:Destroy()
		end
	end

	Lighting.ShadowSoftness = 0.25
	Lighting.EnvironmentDiffuseScale = 1 -- PBR ambient from the sky
	Lighting.EnvironmentSpecularScale = 1 -- reflections on glass, metal, marble

	atmosphere = Instance.new("Atmosphere")
	atmosphere.Parent = Lighting

	grade = Instance.new("ColorCorrectionEffect")
	grade.Parent = Lighting

	bloom = Instance.new("BloomEffect")
	bloom.Parent = Lighting

	sunRays = Instance.new("SunRaysEffect")
	sunRays.Spread = 0.6
	sunRays.Parent = Lighting

	applyQuality()
	LightingFx.applyTheme(nil, true)
end

-- Fades the whole look to a zone's preset (instant = true skips the fade).
function LightingFx.applyTheme(theme, instant)
	if not atmosphere then
		return
	end
	currentTheme = theme
	local preset = presetFor(theme)

	local fogColor = if theme then theme.Fog else Color3.fromRGB(215, 230, 245)
	local function set(object, goal)
		if object == bloom and bloomTween then
			bloomTween:Cancel()
			bloomTween = nil
		end
		if instant then
			for property, value in goal do
				object[property] = value
			end
		else
			local fade = TweenService:Create(object, FADE, goal)
			fade:Play()
			if object == bloom then
				bloomTween = fade
			end
		end
	end

	set(Lighting, {
		ClockTime = preset.ClockTime,
		Brightness = preset.Brightness,
		Ambient = preset.Ambient,
		OutdoorAmbient = preset.OutdoorAmbient,
		ExposureCompensation = preset.ExposureCompensation,
	})
	set(atmosphere, {
		Density = preset.Atmosphere.Density,
		Offset = preset.Atmosphere.Offset,
		Haze = preset.Atmosphere.Haze,
		Glare = preset.Atmosphere.Glare,
		Color = fogColor,
		Decay = fogColor:Lerp(Color3.new(0, 0, 0), 0.35),
	})
	set(grade, preset.Grade)
	set(bloom, bloomGoal(preset))
end

-- Gives the room's main light shadows only if it's one of the shadow rooms.
local function applyShadow(roomFolder, record)
	local light = record.shadowLight
	if light then
		local wanted = shadowRooms[roomFolder] == true and not low and not TOUCH_ONLY
		if light.Shadows ~= wanted then
			light.Shadows = wanted
		end
	end
end

-- Only these rooms (the camera's room and the next one) get a shadow-casting light.
function LightingFx.setShadowRooms(roomFolder, nextRoomFolder)
	table.clear(shadowRooms)
	if roomFolder then
		shadowRooms[roomFolder] = true
	end
	if nextRoomFolder then
		shadowRooms[nextRoomFolder] = true
	end
	for folder, record in rooms do
		applyShadow(folder, record)
	end
end

-- Switches a lit room's lights and shadows off (Low graphics).
local function darkenRoom(record)
	for _, light in record.lights do
		light:Destroy()
	end
	for _, part in record.casters do
		if part.Parent then
			part.CastShadow = false
		end
	end
	table.clear(record.lights)
	table.clear(record.casters)
	record.shadowLight = nil
	record.lit = false
end

-- Adds the real lights and shadows to a room (High graphics).
-- pause (optional): called every few parts so a room build can wait for the
-- next frame when its time is up (TrackBuilder's time slicing).
local function lightUp(roomFolder, record, pause)
	local preset = presetFor(record.theme)
	local glowing = {}
	for index, part in roomFolder:GetDescendants() do
		if pause and index % PARTS_PER_PAUSE_CHECK == 0 then
			pause()
		end
		if not part:IsA("BasePart") then
			continue
		end
		local size = part.Size
		local kind = part:GetAttribute("Kind")

		if part.Material == Enum.Material.Neon and part.Transparency < 0.8 then
			local area = size.X * size.Y + size.Y * size.Z + size.X * size.Z
			if area > 1.5 and kind ~= "Glass" and kind ~= "Crystal" then
				table.insert(glowing, { part = part, area = area })
			end
		elseif
			(kind == "Wall" or kind == "Prop")
			and math.max(size.X, size.Y, size.Z) < SHADOW_CASTER_MAX_SIZE
			and size.Magnitude > SHADOW_CASTER_MIN_SIZE
			and part.Transparency < 0.5
		then
			part.CastShadow = true
			table.insert(record.casters, part)
		end
	end

	-- While this room build was paused the graphics setting may have changed
	-- (and lit the room already, or switched to Low): nothing more to do then.
	if record.lit or low then
		return
	end

	table.sort(glowing, function(a, b)
		return a.area > b.area
	end)

	-- Spread lights out: skip glowing parts too close to one already lit.
	local lit = {}
	for _, entry in glowing do
		if #lit >= LIGHTS_PER_ROOM then
			break
		end
		local position = entry.part.Position
		local tooClose = false
		for _, other in lit do
			if (other.Position - position).Magnitude < 12 then
				tooClose = true
				break
			end
		end
		if not tooClose then
			local light = Instance.new("PointLight")
			light.Name = "RoomLight"
			light.Color = entry.part.Color
			light.Brightness = preset.LightBrightness
			light.Range = preset.LightRange
			light.Shadows = false -- see applyShadow
			light.Parent = entry.part
			table.insert(lit, entry.part)
			table.insert(record.lights, light)
		end
	end
	-- The biggest light is the one that may cast shadows (when the camera is near).
	record.shadowLight = record.lights[1]
	record.lit = true
	applyShadow(roomFolder, record)
end

-- Turns the room's biggest glowing parts into real lights and lets decorations
-- cast shadows. Call after the room (and its decorations) are built.
-- On Low graphics it only remembers the room (so switching to High can light it).
-- pause: optional, see lightUp.
function LightingFx.lightRoom(roomFolder, theme, pause)
	local record = rooms[roomFolder]
	if not record then
		record = { theme = theme, lights = {}, casters = {}, lit = false }
		rooms[roomFolder] = record
	end
	record.theme = theme
	if low then
		if record.lit then
			darkenRoom(record)
		end
	elseif not record.lit then
		lightUp(roomFolder, record, pause)
	end
end

-- Graphics setting changed: re-apply everything to match.
local function onGraphicsChanged()
	local nowLow = Settings.graphicsLevel() == "Low"
	if nowLow == low then
		return
	end
	low = nowLow
	applyQuality()
	if bloom then
		if bloomTween then
			bloomTween:Cancel()
			bloomTween = nil
		end
		local preset = presetFor(currentTheme)
		for property, value in bloomGoal(preset) do
			bloom[property] = value
		end
	end
	for roomFolder, record in rooms do
		if not roomFolder.Parent then
			rooms[roomFolder] = nil
		elseif low then
			if record.lit then
				darkenRoom(record)
			end
		elseif not record.lit then
			lightUp(roomFolder, record)
		end
	end
end

Settings.changed:Connect(function(key)
	if key == "graphics" then
		onGraphicsChanged()
	end
end)

return LightingFx
