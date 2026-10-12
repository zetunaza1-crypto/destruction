--[[
	Plays the sound IDs from Config.Sounds. IDs left at 0 are silently skipped,
	so the game works before any audio is uploaded.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Sounds = {}

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
		sound.Parent = SoundService
		cache[name] = sound
	end
	return cache[name]
end

function Sounds.play(name, pitch)
	local sound = getSound(name)
	if not sound then
		return
	end
	if pitch then
		-- Varying the pitch a little keeps repeated shatters from sounding robotic.
		local copy = sound:Clone()
		copy.PlaybackSpeed = pitch
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
