--[[
	All the numbers that control the game live here.
	Tweak these to change difficulty, rewards and monetization
	without touching the gameplay code.
]]

local Config = {}

Config.GAME_NAME = "Shatter Run"

-- Track ----------------------------------------------------------------------
-- Every player's run is built locally on their own device, far above the lobby.
Config.TRACK_ORIGIN = Vector3.new(0, 500, 0)
Config.CORRIDOR_WIDTH = 20
Config.CORRIDOR_HEIGHT = 14
Config.ROOM_LENGTH = 80
Config.ROOMS_AHEAD = 5 -- how many rooms are built in front of the camera
Config.SAFE_ROOMS = 2 -- the first rooms have no glass so players can warm up
Config.ROOMS_PER_CHECKPOINT = 10 -- new colors + "CHECKPOINT" every N rooms
Config.CAMERA_HEIGHT = 6
Config.STUDS_PER_METER = 3

-- Speed ----------------------------------------------------------------------
Config.START_SPEED = 22 -- studs per second
Config.MAX_SPEED = 55
Config.SPEED_GAIN_PER_ROOM = 0.8

-- Balls ----------------------------------------------------------------------
Config.START_BALLS = 25
Config.CRASH_PENALTY = 10 -- balls lost when you fly into glass
Config.CRYSTAL_REWARD = 3 -- balls gained per crystal
Config.CRYSTALS_PER_MULTIBALL_LEVEL = 5 -- crystals in a row to level up multiball
Config.MAX_MULTIBALL = 5
Config.THROW_COOLDOWN = 0.12
Config.BALL_SPEED = 160
Config.BALL_GRAVITY = 30
Config.BALL_RADIUS = 0.6
Config.BALL_LIFETIME = 3

-- Rewards --------------------------------------------------------------------
Config.GEMS_PER_METER = 0.1
Config.DAILY_REWARD_GEMS = 100
Config.DAILY_REWARD_COOLDOWN = 20 * 60 * 60 -- 20 hours, so it fits any daily routine

-- Ball skins, bought with gems in the shop ------------------------------------
-- Order here is the order they show up in the shop.
Config.Skins = {
	{ Id = "Default", Name = "Steel", Price = 0, Color = Color3.fromRGB(200, 205, 215), Material = Enum.Material.Metal },
	{ Id = "Gold", Name = "Gold", Price = 500, Color = Color3.fromRGB(255, 200, 60), Material = Enum.Material.Metal },
	{ Id = "Ruby", Name = "Ruby", Price = 800, Color = Color3.fromRGB(230, 40, 70), Material = Enum.Material.Glass },
	{ Id = "Toxic", Name = "Toxic", Price = 1200, Color = Color3.fromRGB(110, 255, 80), Material = Enum.Material.Neon },
	{ Id = "Void", Name = "Void", Price = 2000, Color = Color3.fromRGB(20, 10, 40), Material = Enum.Material.Neon, Trail = Color3.fromRGB(170, 80, 255) },
	{ Id = "Plasma", Name = "Plasma", Price = 3500, Color = Color3.fromRGB(80, 220, 255), Material = Enum.Material.ForceField, Trail = Color3.fromRGB(80, 220, 255) },
	{ Id = "Rainbow", Name = "Rainbow", Price = 6000, Color = Color3.fromRGB(255, 255, 255), Material = Enum.Material.Neon, Rainbow = true },
}

function Config.getSkin(skinId)
	for _, skin in Config.Skins do
		if skin.Id == skinId then
			return skin
		end
	end
	return Config.Skins[1]
end

function Config.checkpointMeters(checkpoint)
	return checkpoint * Config.ROOMS_PER_CHECKPOINT * Config.ROOM_LENGTH / Config.STUDS_PER_METER
end

-- Monetization ---------------------------------------------------------------
-- Create these in the Creator Hub (Monetization > Developer Products / Passes)
-- and paste the IDs here. An ID of 0 hides that button in the game.
-- Suggested prices are just a starting point.
Config.Products = {
	Revive = { Id = 0, Balls = 25 }, -- game over screen (~25 R$)
	BallPack = { Id = 0, Balls = 50 }, -- during a run (~15 R$)
	GemPack = { Id = 0, Gems = 500 }, -- shop (~49 R$)
}

Config.GamePasses = {
	VIP = { Id = 0, ExtraStartBalls = 15, GemMultiplier = 2 }, -- ~149 R$
	Multiball = { Id = 0 }, -- multiball never drops below x2 (~99 R$)
	Checkpoints = { Id = 0 }, -- start from any checkpoint you've reached (~199 R$)
}

Config.REVIVE_SECONDS = 6 -- how long the revive button stays up after game over

-- Sounds ---------------------------------------------------------------------
-- Upload sounds in the Creator Hub and paste the asset IDs. 0 = silent.
Config.Sounds = {
	Throw = 0,
	Shatter = 0,
	Crystal = 0,
	Crash = 0,
	Checkpoint = 0,
	Music = 0,
}

-- Visual themes, one per checkpoint (cycles when it runs out) ----------------
Config.Themes = {
	{
		Wall = Color3.fromRGB(235, 238, 245),
		Accent = Color3.fromRGB(90, 200, 255),
		Fog = Color3.fromRGB(215, 230, 245),
	},
	{
		Wall = Color3.fromRGB(40, 44, 60),
		Accent = Color3.fromRGB(255, 90, 170),
		Fog = Color3.fromRGB(30, 30, 45),
	},
	{
		Wall = Color3.fromRGB(245, 225, 200),
		Accent = Color3.fromRGB(255, 150, 40),
		Fog = Color3.fromRGB(250, 215, 170),
	},
	{
		Wall = Color3.fromRGB(20, 60, 50),
		Accent = Color3.fromRGB(80, 255, 160),
		Fog = Color3.fromRGB(15, 45, 40),
	},
	{
		Wall = Color3.fromRGB(70, 40, 90),
		Accent = Color3.fromRGB(255, 230, 80),
		Fog = Color3.fromRGB(55, 30, 75),
	},
}

-- Which obstacles show up in each zone. Zones after the last one use all of them.
Config.ZonePatterns = {
	{ "Window", "Pillars", "Beam" },
	{ "Window", "Pillars", "Beam", "FullWall", "Moving" },
	{ "Pillars", "Beam", "FullWall", "Moving", "Door", "Grid" },
	{ "FullWall", "Moving", "Door", "Grid", "Spinner", "Double" },
	{ "FullWall", "Moving", "Door", "Grid", "Spinner", "Double", "Pillars" },
}

Config.GLASS_COLOR = Color3.fromRGB(200, 235, 255)
Config.CRYSTAL_COLOR = Color3.fromRGB(60, 140, 255)
Config.DOOR_COLOR = Color3.fromRGB(60, 62, 70)
Config.BUTTON_COLOR = Color3.fromRGB(255, 60, 60)

return Config
