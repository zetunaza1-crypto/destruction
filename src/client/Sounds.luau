--[[
	Plays the sound IDs from Config.Sounds. IDs left at 0 are silently skipped,
	so the game works before any audio is uploaded.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Sounds = {}

-- Volume per sound (Roblox's Sound.Volume, 0-10). Sounds not listed keep the
-- Roblox default of 0.5. The gift sound is meant to grab attention.
local DEFAULT_VOLUME = 0.5
local VOLUMES = {
	Gift = 1.2,
}

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
		sound.Parent = SoundService
		cache[name] = sound
	end
	return cache[name]
end

-- pitch: optional playback speed (a little random variety).
-- volume: optional, overrides the sound's usual volume for this one play.
function Sounds.play(name, pitch, volume)
	local sound = getSound(name)
	if not sound then
		return
	end
	if pitch or volume then
		-- Varying the pitch a little keeps repeated shatters from sounding robotic.
		local copy = sound:Clone()
		copy.PlaybackSpeed = pitch or 1
		copy.Volume = volume or sound.Volume
		copy.Parent = SoundService
		copy.Ended:Once(function()
			copy:Destroy()
		end)
		copy:Play()
	else
		SoundService:PlayLocalSound(sound)
	end
end

function Sounds.startMusic()
	local music = getSound("Music")
	if music and not music.IsPlaying then
		music.Looped = true
		music.Volume = 0.4
		music:Play()
	end
end

return Sounds
