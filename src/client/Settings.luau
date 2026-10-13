--[[
	Player settings (volume, vibration, graphics, camera shake, flashes).

	One place every module reads from. Changing a setting applies it right away
	(Settings.changed fires) and saves it to the player's account a moment later,
	so settings follow the player to any device.

	Settings.get(key) / Settings.set(key, value) / Settings.all()
	Settings.changed: RBXScriptSignal (key, value)
	Settings.graphicsLevel(): "Low" | "High" (resolves "Auto" from the device)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local player = Players.LocalPlayer

local Settings = {}

local SAVE_DELAY = 1.5 -- seconds of no changes before saving (sliders change a lot)

local values = table.clone(Config.DefaultSettings)
local changedEvent = Instance.new("BindableEvent")
Settings.changed = changedEvent.Event

local saveToken

local function valid(key, value)
	local default = Config.DefaultSettings[key]
	if default == nil or type(value) ~= type(default) then
		return false
	end
	if key == "graphics" then
		return table.find(Config.GRAPHICS_OPTIONS, value) ~= nil
	end
	if type(value) == "number" then
		return value >= 0 and value <= 1
	end
	return true
end

local function scheduleSave()
	local token = {}
	saveToken = token
	task.delay(SAVE_DELAY, function()
		if saveToken ~= token then
			return
		end
		pcall(function()
			Remotes.ShopRequest:InvokeServer("SaveSettings", table.clone(values))
		end)
	end)
end

function Settings.get(key)
	return values[key]
end

function Settings.all()
	return table.clone(values)
end

function Settings.set(key, value)
	if not valid(key, value) or values[key] == value then
		return
	end
	values[key] = value
	changedEvent:Fire(key, value)
	scheduleSave()
end

-- "Auto" picks Low on phones/tablets, High elsewhere.
function Settings.graphicsLevel()
	local choice = values.graphics
	if choice ~= "Auto" then
		return choice
	end
	local phoneLike = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	return if phoneLike then "Low" else "High"
end

-- Loads the saved settings once the server publishes them.
local function loadFromAttribute()
	local raw = player:GetAttribute("Settings")
	if type(raw) ~= "string" then
		return
	end
	local ok, saved = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or type(saved) ~= "table" then
		return
	end
	for key, value in saved do
		if valid(key, value) and values[key] ~= value then
			values[key] = value
			changedEvent:Fire(key, value)
		end
	end
end

loadFromAttribute()
-- Only the first load matters; afterwards the client is the source of truth.
local connection
connection = player:GetAttributeChangedSignal("Settings"):Connect(function()
	loadFromAttribute()
	connection:Disconnect()
end)

return Settings
