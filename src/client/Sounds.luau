--[[
	Plays the sound IDs from Config.Sounds. IDs left at 0 are silently skipped,
	so the game works before any audio is uploaded.

	Every sound belongs to one of two SoundGroups under SoundService:
	  "Music" - the background music, volume = Settings "music"
	  "SFX"   - everything else,       volume = Settings "sfx"
	Moving a volume slider changes the group right away (even mid-sound).
	Each sound keeps its own volume inside its group, so the gift sound stays
	louder than a shatter at any slider position.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Settings = require(script.Parent.Settings)

local Sounds = {}

-- Volume per sound (Roblox's Sound.Volume, 0-10) before the group volume is
-- applied. Sounds not listed use DEFAULT_VOLUME. The gift sound is meant to grab attention.
local DEFAULT_VOLUME = 0.6
local VOLUMES = {
	Gift = 1.4,
	Music = 0.6,
	Swing = 0.45, -- plays on every throw, so a bit softer
	Reload = 0.3, -- quiet: it's a background detail
}
local MUSIC_SOUNDS = { Music = true }
local CLEANUP_AFTER = 20 -- seconds: safety net for copies whose Ended never fires (failed to load)

-- Sound groups ---------------------------------------------------------------------

local function makeGroup(name)
	local group = SoundService:FindFirstChild(name)
	if not (group and group:IsA("SoundGroup")) then
		group = Instance.new("SoundGroup")
		group.Name = name
		group.Parent = SoundService
	end
	return group
end

local musicGroup = makeGroup("Music")
local sfxGroup = makeGroup("SFX")

local function volumeSetting(key)
	local value = tonumber(Settings.get(key))
	return math.clamp(value or Config.DefaultSettings[key] or 1, 0, 1)
end

local function applyVolumes()
	musicGroup.Volume = volumeSetting("music")
	sfxGroup.Volume = volumeSetting("sfx")
end
applyVolumes()

Settings.changed:Connect(function(key)
	if key == "music" or key == "sfx" then
		applyVolumes()
	end
end)

-- Sounds ---------------------------------------------------------------------------

local cache = {}

local function getSound(name)
	local id = Config.Sounds[name]
	if not id or id == 0 then
		return nil
	end
	if not cache[name] then
		local sound = Instance.new("Sound")
		sound.Name = name
		sound.SoundId = "rbxassetid://" .. id
		sound.Volume = VOLUMES[name] or DEFAULT_VOLUME
		sound.SoundGroup = if MUSIC_SOUNDS[name] then musicGroup else sfxGroup
		sound.Parent = SoundService
		cache[name] = sound
	end
	return cache[name]
end

-- pitch: optional playback speed (a little random variety).
-- volume: optional, overrides the sound's usual volume for this one play.
function Sounds.play(name, pitch, volume)
	-- Effects muted: don't even make the copy.
	if not MUSIC_SOUNDS[name] and sfxGroup.Volume <= 0 then
		return
	end
	local sound = getSound(name)
	if not sound then
		return
	end
	-- Always a fresh copy (it keeps its SoundGroup), so the same sound can overlap
	-- itself and the group volume always applies. Varying the pitch a little keeps
	-- repeated shatters from sounding robotic.
	local copy = sound:Clone()
	copy.PlaybackSpeed = pitch or 1
	copy.Volume = volume or sound.Volume
	copy.Parent = SoundService
	copy.Ended:Once(function()
		copy:Destroy()
	end)
	Debris:AddItem(copy, CLEANUP_AFTER)
	copy:Play()
end

function Sounds.startMusic()
	local music = getSound("Music")
	if music and not music.IsPlaying then
		music.Looped = true
		music:Play()
	end
end

-- For the settings menu, if it wants them (e.g. a preview blip).
Sounds.musicGroup = musicGroup
Sounds.sfxGroup = sfxGroup

return Sounds
