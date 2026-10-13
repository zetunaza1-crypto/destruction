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
Config.PREMIUM_GEM_BONUS = 0.1 -- Roblox Premium members earn +10% gems

-- Daily login streak: claim once per day, day 7 is the big one. Missing a day
-- (48h without claiming) restarts at day 1.
Config.DAILY_REWARD_COOLDOWN = 20 * 60 * 60 -- 20 hours, so it fits any daily routine
Config.DAILY_STREAK_RESET = 48 * 60 * 60
Config.DailyStreak = {
	{ Gems = 50 },
	{ Gems = 75, Boost = "Shield" },
	{ Gems = 100 },
	{ Gems = 150, Balls = 10 }, -- bonus balls added to the next run
	{ Gems = 200, Boost = "MegaBall" },
	{ Gems = 250, Boost = "DoubleGems" },
	{ Gems = 500, Fx = "Prism" }, -- exclusive shatter effect
}
Config.DAILY_REWARD_GEMS = Config.DailyStreak[1].Gems -- kept for older UI text

-- Player level --------------------------------------------------------------------
-- XP from every run. Levels give gems; some levels unlock cosmetics.
Config.XP = {
	PerMeter = 0.5,
	PerGlass = 1,
	PerCrystal = 2,
	PerProp = 1,
}
function Config.xpForLevel(level)
	return 100 + 25 * math.min(level - 1, 40)
end
Config.LEVEL_UP_GEMS = 25
Config.LevelUnlocks = {
	[3] = { Skin = "Copper" },
	[5] = { Fx = "Ember" },
	[10] = { Skin = "Chrome" },
	[15] = { Fx = "Toxic" },
	[20] = { Skin = "Obsidian" },
	[30] = { Fx = "Galaxy" },
}

-- Daily missions -----------------------------------------------------------------
-- 3 random missions every day. Stat names match what a run reports.
Config.MISSIONS_PER_DAY = 3
Config.MISSION_REROLLS_PER_DAY = 1
Config.MissionPool = {
	{ Id = "glass_s", Stat = "glass", Goal = 100, Gems = 60, XP = 80, Text = "Smash %d glass" },
	{ Id = "glass_l", Stat = "glass", Goal = 400, Gems = 150, XP = 200, Text = "Smash %d glass" },
	{ Id = "crystal_s", Stat = "crystals", Goal = 30, Gems = 60, XP = 80, Text = "Collect %d crystals" },
	{ Id = "crystal_l", Stat = "crystals", Goal = 120, Gems = 150, XP = 200, Text = "Collect %d crystals" },
	{ Id = "props", Stat = "props", Goal = 40, Gems = 80, XP = 100, Text = "Break %d decorations" },
	{ Id = "runs", Stat = "runs", Goal = 5, Gems = 50, XP = 60, Text = "Play %d runs" },
	{ Id = "dist", Stat = "bestRunMeters", Goal = 500, Gems = 100, XP = 120, Text = "Fly %dm in one run", Max = true },
	{ Id = "zone2", Stat = "bestZone", Goal = 2, Gems = 120, XP = 150, Text = "Reach zone %d", Max = true },
	{ Id = "multi", Stat = "bestMultiball", Goal = 3, Gems = 80, XP = 100, Text = "Reach multiball x%d", Max = true },
}

-- Season pass ----------------------------------------------------------------------
-- Tiers fill with the same XP as levels. Free rewards for everyone, premium
-- rewards need Products.SeasonPremium. Bump SEASON_ID to start a new season.
Config.SEASON_ID = 1
Config.SEASON_NAME = "SEASON 1: FIRST CRACK"
Config.SEASON_ENDS = 0 -- os.time() the season ends (0 = no countdown shown)
Config.SEASON_TIER_XP = 300
Config.SeasonTiers = {} -- filled below: SeasonTiers[tier] = { Free = reward?, Premium = reward }
for tier = 1, 30 do
	local free = if tier % 3 == 0 then { Gems = 50 + tier * 5 } elseif tier % 4 == 1 then { Boost = "Shield" } else nil
	local premium = { Gems = 40 + tier * 6 }
	if tier == 5 then
		premium = { Skin = "Neonite" }
	elseif tier == 10 then
		premium = { Fx = "Gold" }
	elseif tier == 15 then
		free = { Skin = "Season1" }
	elseif tier == 20 then
		premium = { Skin = "Diamond" }
	elseif tier == 25 then
		premium = { Fx = "Rainbow" }
	elseif tier == 30 then
		free = { Gems = 500 }
		premium = { Skin = "Shatterborn", Fx = "Supernova" }
	end
	Config.SeasonTiers[tier] = { Free = free, Premium = premium }
end

-- Shatter effects: what color glass shards turn when YOU break them (cosmetic) ----
-- Price 0 + Source = unlocked another way (level, streak, season, starter pack).
Config.ShatterFx = {
	{ Id = "Classic", Name = "Classic", Price = 0 },
	{ Id = "Ruby", Name = "Ruby", Price = 600, Color = Color3.fromRGB(255, 60, 90) },
	{ Id = "Emerald", Name = "Emerald", Price = 600, Color = Color3.fromRGB(60, 230, 120) },
	{ Id = "Amethyst", Name = "Amethyst", Price = 900, Color = Color3.fromRGB(170, 90, 255) },
	{ Id = "Neon", Name = "Neon", Price = 1500, Color = Color3.fromRGB(80, 255, 240), Neon = true },
	{ Id = "Ember", Name = "Ember", Price = 0, Source = "LEVEL 5", Color = Color3.fromRGB(255, 120, 30), Neon = true },
	{ Id = "Toxic", Name = "Toxic", Price = 0, Source = "LEVEL 15", Color = Color3.fromRGB(150, 255, 40), Neon = true },
	{ Id = "Galaxy", Name = "Galaxy", Price = 0, Source = "LEVEL 30", Color = Color3.fromRGB(90, 40, 200), Neon = true, Sparkle = true },
	{ Id = "Prism", Name = "Prism", Price = 0, Source = "7-DAY STREAK", Rainbow = true },
	{ Id = "Frost", Name = "Frost", Price = 0, Source = "STARTER PACK", Color = Color3.fromRGB(190, 240, 255), Sparkle = true },
	{ Id = "Gold", Name = "Gold", Price = 0, Source = "SEASON PASS", Color = Color3.fromRGB(255, 200, 50), Metal = true },
	{ Id = "Rainbow", Name = "Rainbow", Price = 0, Source = "SEASON PASS", Rainbow = true, Neon = true },
	{ Id = "Supernova", Name = "Supernova", Price = 0, Source = "SEASON PASS", Color = Color3.fromRGB(255, 240, 200), Neon = true, Sparkle = true },
}

function Config.getFx(fxId)
	for _, fx in Config.ShatterFx do
		if fx.Id == fxId then
			return fx
		end
	end
	return Config.ShatterFx[1]
end

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
	-- Unlocked by progression / offers instead of gems (Price 0 + Source).
	{ Id = "Copper", Name = "Copper", Price = 0, Source = "LEVEL 3", Color = Color3.fromRGB(200, 110, 60), Material = Enum.Material.Metal },
	{ Id = "Chrome", Name = "Chrome", Price = 0, Source = "LEVEL 10", Color = Color3.fromRGB(240, 245, 255), Material = Enum.Material.Foil },
	{ Id = "Obsidian", Name = "Obsidian", Price = 0, Source = "LEVEL 20", Color = Color3.fromRGB(25, 20, 35), Material = Enum.Material.Glass, Trail = Color3.fromRGB(255, 80, 40) },
	{ Id = "Starter", Name = "Starter", Price = 0, Source = "STARTER PACK", Color = Color3.fromRGB(80, 200, 255), Material = Enum.Material.Neon, Trail = Color3.fromRGB(80, 200, 255) },
	{ Id = "Season1", Name = "Cracked", Price = 0, Source = "SEASON PASS", Color = Color3.fromRGB(220, 235, 255), Material = Enum.Material.Glass },
	{ Id = "Neonite", Name = "Neonite", Price = 0, Source = "SEASON PASS", Color = Color3.fromRGB(255, 70, 200), Material = Enum.Material.Neon, Trail = Color3.fromRGB(255, 70, 200) },
	{ Id = "Diamond", Name = "Diamond", Price = 0, Source = "SEASON PASS", Color = Color3.fromRGB(200, 240, 255), Material = Enum.Material.Glass, Trail = Color3.fromRGB(255, 255, 255) },
	{ Id = "Shatterborn", Name = "Shatterborn", Price = 0, Source = "SEASON PASS", Color = Color3.fromRGB(255, 255, 255), Material = Enum.Material.Neon, Rainbow = true },
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
	-- Gem packs: bigger packs are better value.
	GemPack = { Id = 0, Gems = 500 }, -- ~49 R$
	GemPackMedium = { Id = 0, Gems = 1200, Badge = "+20%" }, -- ~99 R$
	GemPackLarge = { Id = 0, Gems = 3200, Badge = "BEST VALUE" }, -- ~199 R$
	-- One-time offer for new players (hidden once bought).
	StarterPack = { Id = 0, Gems = 1000, Skin = "Starter", Fx = "Frost", OneTime = true }, -- ~49 R$
	-- Unlocks the premium track of the current season pass.
	SeasonPremium = { Id = 0 }, -- ~199 R$

	-- Impulse buys -----------------------------------------------------------
	-- Boosts bought with Robux: into your inventory (or used right away mid-run).
	BoostShield = { Id = 0, Boost = "Shield" }, -- ~10 R$
	BoostMagnet = { Id = 0, Boost = "Magnet" }, -- ~10 R$
	BoostDoubleGems = { Id = 0, Boost = "DoubleGems" }, -- ~15 R$
	BoostMegaBall = { Id = 0, Boost = "MegaBall" }, -- ~15 R$
	BoostSlowMo = { Id = 0, Boost = "SlowMo" }, -- ~10 R$
	-- Small gem top-up, offered when a player is just short for something.
	GemTopUp = { Id = 0, Gems = 150 }, -- ~15 R$
	-- Extra daily mission reroll.
	ExtraReroll = { Id = 0 }, -- ~5 R$
	-- Keeps a broken login streak going (only offered right after it breaks).
	StreakSaver = { Id = 0 }, -- ~15 R$
}

-- Boosts --------------------------------------------------------------------------
-- Picked before a run (from inventory), or bought mid-run. Also earned for free
-- from streaks, level ups and the season pass so players get a taste first.
Config.Boosts = {
	Shield = { Name = "SHIELD", Text = "YOUR NEXT CRASH IS FREE", Gems = 150, Color = Color3.fromRGB(80, 200, 255) },
	Magnet = { Name = "MAGNET", Text = "CRYSTALS FLY TO YOU", Gems = 120, Duration = 20, Range = 22, Color = Color3.fromRGB(255, 80, 120) },
	DoubleGems = { Name = "2X GEMS", Text = "DOUBLE GEMS THIS RUN", Gems = 200, Color = Color3.fromRGB(255, 200, 50) },
	MegaBall = { Name = "MEGA BALL", Text = "NEXT 10 THROWS ARE GIANT", Gems = 150, Throws = 10, Scale = 3, Color = Color3.fromRGB(255, 120, 30) },
	SlowMo = { Name = "SLOW-MO", Text = "SLOW TIME FOR 8 SECONDS", Gems = 100, Duration = 8, TimeScale = 0.5, Color = Color3.fromRGB(150, 110, 255) },
}
Config.BOOST_ORDER = { "Shield", "Magnet", "DoubleGems", "MegaBall", "SlowMo" }
Config.WELCOME_BOOSTS = { Shield = 1, Magnet = 1, DoubleGems = 1, MegaBall = 1, SlowMo = 1 }
Config.MAX_BOOSTS_PER_RUN = 3
Config.LOW_BALLS_OFFER = 8 -- show the mid-run Shield quick-buy at or below this many balls
-- Every level up also gives one boost, cycling through BOOST_ORDER.
Config.LEVEL_UP_BOOST = true

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

-- 3D models ------------------------------------------------------------------
-- Blender models from assets/models/, uploaded to Roblox as Model assets.
-- Paste each asset ID here. 0 = use the built-in block version instead.
Config.Models = {
	Crystal = 0,
	GlassVase = 0,
	GlassBottle = 0,
	GlassUrn = 0,
	GlassLantern = 0,
	Flask = 0,
	TestTubeRack = 0,
	GlassOrb = 0,
	NeonTube = 0,
	Pillar = 0,
	Brazier = 0,
	Planter = 0,
	Plant = 0,
	HangingVine = 0,
	LabBench = 0,
	ServerRack = 0,
	CeilingLight = 0,
	PipeRun = 0,
	Vent = 0,
	Crate = 0,
}

-- Visual themes, one per checkpoint (cycles when it runs out) ----------------
-- Style picks the room decoration set in src/client/Decor.luau.
Config.Themes = {
	{
		Wall = Color3.fromRGB(235, 238, 245),
		Accent = Color3.fromRGB(90, 200, 255),
		Fog = Color3.fromRGB(215, 230, 245),
		Style = "Lab", -- decoration set used by Decor.luau
		Name = "LAB",
	},
	{
		Wall = Color3.fromRGB(40, 44, 60),
		Accent = Color3.fromRGB(255, 90, 170),
		Fog = Color3.fromRGB(30, 30, 45),
		Style = "Neon", -- decoration set used by Decor.luau
		Name = "NEON CITY",
	},
	{
		Wall = Color3.fromRGB(245, 225, 200),
		Accent = Color3.fromRGB(255, 150, 40),
		Fog = Color3.fromRGB(250, 215, 170),
		Style = "Temple", -- decoration set used by Decor.luau
		Name = "TEMPLE",
	},
	{
		Wall = Color3.fromRGB(20, 60, 50),
		Accent = Color3.fromRGB(80, 255, 160),
		Fog = Color3.fromRGB(15, 45, 40),
		Style = "Greenhouse", -- decoration set used by Decor.luau
		Name = "GREENHOUSE",
	},
	{
		Wall = Color3.fromRGB(70, 40, 90),
		Accent = Color3.fromRGB(255, 230, 80),
		Fog = Color3.fromRGB(55, 30, 75),
		Style = "Void", -- decoration set used by Decor.luau
		Name = "THE VOID",
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

-- Glass breaking ---------------------------------------------------------------
Config.SHARD_RAYS = 8 -- cracks spreading from the impact (more = finer shards, slower)
Config.SHARD_LIFETIME = 2.5

Config.GLASS_COLOR = Color3.fromRGB(200, 235, 255)
Config.CRYSTAL_COLOR = Color3.fromRGB(60, 140, 255)
Config.DOOR_COLOR = Color3.fromRGB(60, 62, 70)
Config.BUTTON_COLOR = Color3.fromRGB(255, 60, 60)

return Config
