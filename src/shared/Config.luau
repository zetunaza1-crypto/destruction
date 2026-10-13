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
Config.ROOMS_AHEAD = 3 -- how many rooms are visible in front of the camera (the fog hides the far end);
-- rooms start building one room earlier than that, a few parts per frame
Config.SAFE_ROOMS = 2 -- the first rooms have no glass so players can warm up
Config.ROOMS_PER_CHECKPOINT = 14 -- rooms per zone: new colors + "ZONE" every N rooms
Config.CAMERA_HEIGHT = 6
Config.STUDS_PER_METER = 3

-- Speed ----------------------------------------------------------------------
-- A run warms up from START_SPEED (+SPEED_GAIN_PER_ROOM every room), but each
-- zone has its own top speed, so every new zone is a little faster than the last.
-- The server's anti-cheat uses Config.speedForRoom too, so keep all speed rules in it.
Config.START_SPEED = 22 -- studs per second
Config.MAX_SPEED = 60 -- never faster than this (zone 10 and beyond)
Config.SPEED_GAIN_PER_ROOM = 0.8
-- Top speed in each zone (1 = the first zone). Zones after the last use MAX_SPEED.
Config.ZoneTopSpeed = { 34, 40, 46, 50, 53, 55, 56.5, 58, 59, 60 }
-- A Checkpoints-pass run starting in a later zone starts this much below that zone's top speed.
Config.CHECKPOINT_WARMUP_DROP = 12

-- Speed while the camera is in room `roomIndex`, for a run that started in room `startRoom`.
function Config.speedForRoom(roomIndex, startRoom)
	local function topSpeed(room)
		local zone = room // Config.ROOMS_PER_CHECKPOINT + 1
		return math.min(Config.ZoneTopSpeed[zone] or Config.MAX_SPEED, Config.MAX_SPEED)
	end
	local warmStart = math.max(Config.START_SPEED, topSpeed(startRoom) - Config.CHECKPOINT_WARMUP_DROP)
	local warm = warmStart + math.max(0, roomIndex - startRoom) * Config.SPEED_GAIN_PER_ROOM
	return math.min(topSpeed(roomIndex), warm)
end

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
Config.MAX_LIVE_BALLS = 40 -- oldest balls disappear past this (keeps phones smooth)

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
Config.SEASON_ENDS = 1797292800 -- 15 Dec 2026 00:00 UTC (shown as a countdown; never end a season early)
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
	-- Endless distance milestones (Config.ZoneRewards).
	{ Id = "Endless", Name = "Endless", Price = 0, Source = "REACH ZONE 15", Color = Color3.fromRGB(70, 230, 255), Neon = true, Sparkle = true },
	{ Id = "Starfall", Name = "Starfall", Price = 0, Source = "REACH ZONE 30", Color = Color3.fromRGB(255, 215, 90), Neon = true, Sparkle = true },
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
	-- Free reward for reaching ZONE 10 (Config.ZoneRewards): a rainbow glass ball.
	{ Id = "PrismShard", Name = "Prism Shard", Price = 0, Source = "REACH ZONE 10", Color = Color3.fromRGB(235, 225, 255), Material = Enum.Material.Glass, Rainbow = true, Trail = Color3.fromRGB(200, 160, 255) },
	-- Endless distance milestones (Config.ZoneRewards): only the best players have these.
	{ Id = "Afterburn", Name = "Afterburn", Price = 0, Source = "REACH ZONE 20", Color = Color3.fromRGB(255, 120, 30), Material = Enum.Material.Neon, Trail = Color3.fromRGB(255, 200, 60) },
	-- Premium balls: Robux only (Config.Products.Ball<Id>), never sold for gems.
	-- Robux = price shown if the live price can't be loaded. Each one is an animated
	-- Blender model (Config.BallModels, styled by Shared.BallStyles). Until that's
	-- uploaded they're built from parts: a Color core, a Shell, spinning Ring(s) and a Trail.
	{ Id = "Frostbite", Name = "Frostbite", Price = 0, Premium = true, Robux = 79, ProductKey = "BallFrostbite", Text = "AN ICE CORE WITH FROST SHARDS CIRCLING IT", Color = Color3.fromRGB(150, 225, 255), Material = Enum.Material.Neon, Shell = Color3.fromRGB(220, 245, 255), Ring = Color3.fromRGB(190, 240, 255), Trail = Color3.fromRGB(170, 230, 255) },
	{ Id = "CyberCore", Name = "Cyber Core", Price = 0, Premium = true, Robux = 79, ProductKey = "BallCyberCore", Text = "A GLOWING CHIP INSIDE SPINNING DATA RINGS", Color = Color3.fromRGB(0, 255, 170), Material = Enum.Material.Neon, Shell = Color3.fromRGB(30, 40, 50), Ring = Color3.fromRGB(0, 230, 255), Trail = Color3.fromRGB(0, 255, 200) },
	{ Id = "PlasmaCore", Name = "Plasma Core", Price = 0, Premium = true, Robux = 99, ProductKey = "BallPlasmaCore", Text = "CRACKLING PLASMA TRAPPED IN A FORCE FIELD", Color = Color3.fromRGB(210, 90, 255), Material = Enum.Material.Neon, Shell = Color3.fromRGB(255, 120, 230), Ring = Color3.fromRGB(255, 90, 220), Trail = Color3.fromRGB(220, 100, 255) },
	{ Id = "MagmaHeart", Name = "Magma Heart", Price = 0, Premium = true, Robux = 99, ProductKey = "BallMagmaHeart", Text = "A MOLTEN HEART IN A CRACKED ROCK SHELL", Color = Color3.fromRGB(255, 110, 20), Material = Enum.Material.Neon, Shell = Color3.fromRGB(60, 30, 25), Ring = Color3.fromRGB(255, 170, 40), Trail = Color3.fromRGB(255, 90, 20) },
	{ Id = "BlackHole", Name = "Black Hole", Price = 0, Premium = true, Robux = 149, ProductKey = "BallBlackHole", Text = "PURE DARKNESS WITH A BLAZING SPINNING DISK", Color = Color3.fromRGB(8, 4, 16), Material = Enum.Material.Neon, Shell = Color3.fromRGB(120, 60, 255), Ring = Color3.fromRGB(255, 150, 60), Trail = Color3.fromRGB(150, 80, 255) },
	{ Id = "Supernova", Name = "Supernova", Price = 0, Premium = true, Robux = 199, ProductKey = "BallSupernova", Text = "A STAR ABOUT TO EXPLODE, WITH BLAZING RINGS", Color = Color3.fromRGB(255, 245, 210), Material = Enum.Material.Neon, Shell = Color3.fromRGB(255, 200, 80), Ring = Color3.fromRGB(255, 180, 50), Trail = Color3.fromRGB(255, 220, 120) },
	-- Earned animated balls: the same kind of animated Blender model as the premium
	-- balls (Config.BallModels, Shared.BallStyles), but NEVER sold - not for Robux,
	-- not for gems. Animated = true: looks like a premium ball, earned like a reward.
	-- Source = how to get it (shown in the shop). Unlock = { Stat, Amount }: the
	-- server gives it once the lifetime stat (data.Stats[Stat]) reaches Amount.
	-- Shell / Ring / Trail: the part-built look until the model is uploaded.
	{ Id = "Infinity", Name = "Infinity", Price = 0, Animated = true, Source = "REACH ZONE 50", Text = "A TINY BLACK UNIVERSE WITH INFINITY RINGS AND LIGHTNING", Color = Color3.fromRGB(120, 70, 255), Material = Enum.Material.Neon, Shell = Color3.fromRGB(40, 20, 70), Ring = Color3.fromRGB(255, 205, 110), Trail = Color3.fromRGB(170, 110, 255) },
	{ Id = "Smashbot", Name = "Smashbot", Price = 0, Animated = true, Source = "SMASH 50,000 GLASS", Unlock = { Stat = "glass", Amount = 50000 }, Text = "A ROBOT BALL WITH OPENING ARMOR AND A GLOWING EYE", Color = Color3.fromRGB(255, 140, 40), Material = Enum.Material.Neon, Shell = Color3.fromRGB(70, 76, 90), Ring = Color3.fromRGB(255, 150, 40), Trail = Color3.fromRGB(90, 220, 255) },
}

-- True for balls drawn as an animated model (premium Robux balls AND earned
-- Animated balls). Use this for anything about how a ball LOOKS. For anything
-- about money (products, Robux prices, refunds) use skin.Premium only.
function Config.isAnimatedSkin(skin)
	return type(skin) == "table" and (skin.Premium == true or skin.Animated == true)
end

-- Ids of the premium (Robux) balls above, in shop order. Never the earned
-- Animated balls: this list is what's sold.
Config.PremiumBalls = {}
-- Ids of the earned animated balls (Animated, never sold), in shop order.
Config.EarnedBalls = {}
for _, skin in Config.Skins do
	if skin.Premium then
		table.insert(Config.PremiumBalls, skin.Id)
	elseif skin.Animated then
		table.insert(Config.EarnedBalls, skin.Id)
	end
end

-- Gems given instead when someone buys a premium ball they already own
-- (e.g. bought twice while a save was failing): Robux price x this.
Config.PREMIUM_BALL_REFUND_GEMS_PER_ROBUX = 16

-- Blender models of the premium + earned animated balls (assets/balls/*.fbx), uploaded
-- as Model assets. 0 = not uploaded yet: the part-built version above is used instead.
Config.BallModels = {
	Frostbite = 95405037753431,
	CyberCore = 128733885861068,
	PlasmaCore = 124458067173363,
	MagmaHeart = 108350449356111,
	BlackHole = 116620455419343,
	Supernova = 72233037920626,
	Infinity = 123152768181258,
	Smashbot = 96416348312755,
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
	-- Ball products: the server saves the balls first (BonusBalls), so bought
	-- outside a run they start the next run instead of being lost.
	Revive = { Id = 3718291625, Balls = 25 }, -- game over screen (~25 R$)
	BallPack = { Id = 3718291633, Balls = 50 }, -- during a run (~15 R$)
	-- Gem packs: bigger packs are better value.
	GemPack = { Id = 3718291639, Gems = 500 }, -- ~49 R$
	GemPackMedium = { Id = 3718291644, Gems = 1200, Badge = "+20%" }, -- ~99 R$
	GemPackLarge = { Id = 3718291650, Gems = 3200, Badge = "BEST VALUE" }, -- ~199 R$
	-- One-time offer for new players (hidden once bought).
	StarterPack = { Id = 3718291655, Gems = 1000, Skin = "Starter", Fx = "Frost", OneTime = true }, -- ~49 R$
	-- Unlocks the premium track of the current season pass.
	SeasonPremium = { Id = 3718291657 }, -- ~199 R$

	-- Impulse buys -----------------------------------------------------------
	-- Boosts bought with Robux: into your inventory (or used right away mid-run).
	BoostShield = { Id = 3718291661, Boost = "Shield" }, -- ~10 R$
	BoostMagnet = { Id = 3718291664, Boost = "Magnet" }, -- ~10 R$
	BoostDoubleGems = { Id = 3718291666, Boost = "DoubleGems" }, -- ~15 R$
	BoostMegaBall = { Id = 3718291669, Boost = "MegaBall" }, -- ~15 R$
	BoostSlowMo = { Id = 3718291672, Boost = "SlowMo" }, -- ~10 R$
	-- Small gem top-up, offered when a player is just short for something.
	GemTopUp = { Id = 3718291674, Gems = 150 }, -- ~15 R$
	-- Extra daily mission reroll.
	ExtraReroll = { Id = 3718291678 }, -- ~5 R$
	-- Keeps a broken login streak going (only offered right after it breaks).
	StreakSaver = { Id = 3718291682 }, -- ~15 R$

	-- Premium balls (see Config.Skins): yours forever and equipped right away.
	-- Already owned? You get gems instead (Robux price x PREMIUM_BALL_REFUND_GEMS_PER_ROBUX).
	BallFrostbite = { Id = 3718303689, Skin = "Frostbite" }, -- 79 R$
	BallCyberCore = { Id = 3718303691, Skin = "CyberCore" }, -- 79 R$
	BallPlasmaCore = { Id = 3718303699, Skin = "PlasmaCore" }, -- 99 R$
	BallMagmaHeart = { Id = 3718303702, Skin = "MagmaHeart" }, -- 99 R$
	BallBlackHole = { Id = 3718303711, Skin = "BlackHole" }, -- 149 R$
	BallSupernova = { Id = 3718303716, Skin = "Supernova" }, -- 199 R$
}

-- Boosts --------------------------------------------------------------------------
-- Picked before a run (from inventory), or bought mid-run. Also earned for free
-- from streaks, level ups and the season pass so players get a taste first.
Config.Boosts = {
	Shield = { Name = "SHIELD", Text = "YOUR NEXT CRASH IS FREE", Gems = 150, Color = Color3.fromRGB(80, 200, 255) },
	Magnet = { Name = "MAGNET", Text = "CRYSTALS FLY TO YOU FOR 20S", Gems = 120, Duration = 20, Range = 22, Color = Color3.fromRGB(255, 80, 120) },
	DoubleGems = { Name = "2X GEMS", Text = "DOUBLE GEMS THIS RUN", Gems = 200, Color = Color3.fromRGB(255, 200, 50) },
	MegaBall = { Name = "MEGA BALL", Text = "NEXT 10 THROWS ARE GIANT", Gems = 150, Throws = 10, Scale = 3, Color = Color3.fromRGB(255, 120, 30) },
	SlowMo = { Name = "SLOW-MO", Text = "SLOW TIME FOR 8 SECONDS", Gems = 100, Duration = 8, TimeScale = 0.5, Color = Color3.fromRGB(150, 110, 255) },
}
Config.BOOST_ORDER = { "Shield", "Magnet", "DoubleGems", "MegaBall", "SlowMo" }
-- Picked boosts that wait in the HUD boost bar until the player taps them (or
-- presses D-pad Left / Up / Right, or keys 1 / 2 / 3, in this order). The others
-- (Shield, 2x Gems) work by themselves from the start of the run. A boost still
-- untapped when the run really ends goes back to the inventory.
Config.BOOST_BAR = { "Magnet", "SlowMo", "MegaBall" }
Config.WELCOME_BOOSTS = { Shield = 1, Magnet = 1, DoubleGems = 1, MegaBall = 1, SlowMo = 1 }
Config.MAX_BOOSTS_PER_RUN = 3
Config.LOW_BALLS_OFFER = 8 -- show the mid-run Shield quick-buy at or below this many balls
-- Every level up also gives one boost, cycling through BOOST_ORDER.
Config.LEVEL_UP_BOOST = true

Config.GamePasses = {
	VIP = { Id = 2033774283, ExtraStartBalls = 15, GemMultiplier = 2 }, -- ~149 R$
	Multiball = { Id = 2032604290 }, -- multiball never drops below x2 (~99 R$)
	Checkpoints = { Id = 2033012291 }, -- start from any checkpoint you've reached (~199 R$)
}

Config.REVIVE_SECONDS = 6 -- how long the revive button stays up after game over

-- Sounds ---------------------------------------------------------------------
-- Upload sounds in the Creator Hub and paste the asset IDs. 0 = silent.
Config.Sounds = {
	Throw = 97004882080822,
	Shatter = 114868106025273,
	Crystal = 123400852818800,
	Crash = 134925413192056,
	Checkpoint = 119584218311262,
	Gift = 109446253768240, -- assets/sounds/gift_*.mp3
	Music = 108496618537935,
	Swing = 75847376684855, -- arm throw whoosh (assets/sounds/swing_*.mp3)
	Reload = 109753819262777, -- pocket reload (assets/sounds/reload_*.mp3)
}

-- Player settings (saved per account; see src/client/Settings.luau) ------------------
Config.DefaultSettings = {
	music = 0.6, -- 0..1
	sfx = 0.8, -- 0..1
	vibration = true,
	graphics = "Auto", -- one of GRAPHICS_OPTIONS
	shake = true, -- camera shake + punch
	flashes = true, -- red damage flash and other full-screen flashes
}
Config.GRAPHICS_OPTIONS = { "Auto", "Low", "High" }

-- "Wait! Free gift" -----------------------------------------------------------------
-- When a player opens the Roblox menu (maybe to leave) and closes it again, a free
-- gift pops up with a big sound. Once per cooldown, after some real play time,
-- so it can't be farmed. It never blocks leaving.
Config.LeaveGift = {
	MinPlaySeconds = 120,
	Cooldown = 20 * 60 * 60,
	-- Cycles through these, one per claim.
	Rewards = {
		{ Boost = "Shield", Text = "FREE SHIELD BOOST" },
		{ Gems = 75, Text = "+75 FREE GEMS" },
		{ Boost = "MegaBall", Text = "FREE MEGA BALL BOOST" },
		{ Gems = 100, Text = "+100 FREE GEMS" },
		{ Boost = "DoubleGems", Text = "FREE 2X GEMS BOOST" },
	},
}

-- Tutorial & first-time tips ----------------------------------------------------
-- The first run teaches the basics in rooms 1-3 (time slows until you do it).
-- After that, each tip shows once, the first time that thing appears.
Config.TUTORIAL_ROOMS = { 1, 2, 3 }
Config.Hints = {
	Door = "HIT THE RED BUTTON TO OPEN THE DOOR",
	Moving = "THIS GLASS MOVES - TIME YOUR THROW",
	Spinner = "SPINNING GLASS! AIM FOR THE MIDDLE",
	Grid = "SMALL PANES - THROW A FEW BALLS",
	Double = "TWO PANES IN A ROW - THROW TWICE",
	Multiball = "MULTIBALL! EVERY TAP NOW THROWS MORE BALLS",
	Props = "BREAK DECORATIONS FOR MISSIONS AND XP",
	ArmoredGlass = "ARMORED GLASS! HIT IT TWICE TO BREAK IT",
	BobbingPane = "THIS GLASS BOBS UP AND DOWN - TIME YOUR THROW",
	FallingPane = "WATCH THE CEILING! GLASS DROPS IN FRONT OF YOU",
	RingSpinner = "RING! SMASH THE ORANGE PANE - IT TURNS INTO YOUR PATH",
	BoostBar = "TAP A BOOST TO USE IT WHEN YOU NEED IT", -- first run with a boost waiting in the bar
}

-- 3D models ------------------------------------------------------------------
-- Blender models from assets/models/, uploaded to Roblox as Model assets.
-- Paste each asset ID here. 0 = use the built-in block version instead.
Config.Models = {
	Crystal = 71122553195459,
	GlassVase = 95736141645894,
	GlassBottle = 133286417864756,
	GlassUrn = 139403879238182,
	GlassLantern = 121120655792654,
	Flask = 75379835914054,
	TestTubeRack = 111512710162434,
	GlassOrb = 104587869238169,
	NeonTube = 86431343269497,
	Pillar = 90753795746389,
	Brazier = 135076448089649,
	Planter = 135027161994753,
	Plant = 104443575586162,
	HangingVine = 83778887860086,
	LabBench = 139713171667919,
	ServerRack = 72678109653009,
	CeilingLight = 111102201783891,
	PipeRun = 107736602209422,
	Vent = 98915355039928,
	Crate = 88284134622799,
	IceCluster = 135974111689068,
	Icicle = 103318764223255,
	FrozenPillar = 106145180585770,
	IceSculpture = 102761384524681,
	LavaRock = 81609490559178,
	MagmaVent = 136823192487667,
	ForgeAnvil = 83253142226801,
	MagmaJar = 112905056304068,
	Coral = 130798422387948,
	Seaweed = 126294631253711,
	Anchor = 138452985127382,
	FishTank = 126166432025303,
	JellyLamp = 91066068920671,
	CloudCluster = 90787914879077,
	WindTurbine = 97056550572148,
	SkyLantern = 73176633283022,
	Banner = 121228017765972,
	EnergyPylon = 117945811591028,
	CoreCrystal = 89654016722562,
	FloatingRing = 137020398082328,
}

-- Visual themes, one per checkpoint (cycles when it runs out) ----------------
-- Style picks the room decoration set in src/client/Decor.luau.
-- GlassEdge (optional): glass outline color when the accent would blend into the room.
Config.Themes = {
	{
		Wall = Color3.fromRGB(235, 238, 245),
		Accent = Color3.fromRGB(90, 200, 255),
		GlassEdge = Color3.fromRGB(30, 120, 255), -- a deeper blue than the accent, so it reads on the pale walls
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
	{
		Wall = Color3.fromRGB(196, 222, 240),
		Accent = Color3.fromRGB(110, 215, 255),
		GlassEdge = Color3.fromRGB(80, 60, 255), -- cyan glass outlines vanished against the ice
		Fog = Color3.fromRGB(165, 200, 228),
		Style = "Frost", -- decoration set used by Decor.luau
		Name = "FROST CAVERNS",
	},
	{
		Wall = Color3.fromRGB(62, 38, 32),
		Accent = Color3.fromRGB(255, 110, 30),
		Fog = Color3.fromRGB(70, 30, 18),
		Style = "Magma", -- decoration set used by Decor.luau
		Name = "MAGMA FORGE",
	},
	{
		Wall = Color3.fromRGB(28, 72, 88),
		Accent = Color3.fromRGB(60, 255, 215),
		GlassEdge = Color3.fromRGB(255, 205, 60), -- cyan glass outlines vanished against the teal water
		Fog = Color3.fromRGB(14, 58, 74),
		Style = "Aquarium", -- decoration set used by Decor.luau
		Name = "DEEP AQUARIUM",
	},
	{
		Wall = Color3.fromRGB(236, 240, 248),
		Accent = Color3.fromRGB(255, 185, 50),
		Fog = Color3.fromRGB(190, 220, 250),
		Style = "Sky", -- decoration set used by Decor.luau
		Name = "SKY CITADEL",
	},
	{
		Wall = Color3.fromRGB(38, 24, 58),
		Accent = Color3.fromRGB(215, 140, 255),
		Fog = Color3.fromRGB(34, 20, 54),
		Style = "Core", -- decoration set used by Decor.luau
		Name = "CRYSTAL CORE",
	},
}

-- Which obstacles show up in each zone (1 = the first zone). Zones after the last one use the last list.
-- Zones 6-10 bring new obstacles: ArmoredGlass (2 hits), BobbingPane, FallingPane, RingSpinner.
Config.ZonePatterns = {
	{ "Window", "Pillars", "Beam" },
	{ "Window", "Pillars", "Beam", "FullWall", "Moving" },
	{ "Pillars", "Beam", "FullWall", "Moving", "Door", "Grid" },
	{ "FullWall", "Moving", "Door", "Grid", "Spinner", "Double" },
	{ "FullWall", "Moving", "Door", "Grid", "Spinner", "Double", "Pillars" },
	{ "FullWall", "Moving", "Door", "Grid", "Double", "Pillars", "ArmoredGlass", "ArmoredGlass", "BobbingPane" },
	{ "FullWall", "Moving", "Door", "Grid", "Spinner", "Double", "ArmoredGlass", "BobbingPane", "FallingPane", "FallingPane" },
	{ "Moving", "Door", "Grid", "Spinner", "Double", "ArmoredGlass", "BobbingPane", "FallingPane", "RingSpinner", "RingSpinner" },
	{ "FullWall", "Door", "Grid", "Spinner", "Double", "Moving", "ArmoredGlass", "BobbingPane", "FallingPane", "RingSpinner" },
	{ "FullWall", "Door", "Grid", "Spinner", "Double", "ArmoredGlass", "ArmoredGlass", "BobbingPane", "FallingPane", "RingSpinner", "RingSpinner" },
}

-- How hard each zone starts (0 = easy, 1 = very busy). It climbs a little more
-- inside every zone (ZONE_DIFFICULTY_RAMP over the zone's rooms). Zones after the
-- last keep adding ZONE_DIFFICULTY_AFTER per zone, so the endless part only gets harder.
-- More difficulty = more obstacle groups per room (up to 4).
Config.ZoneDifficulty = { 0.05, 0.15, 0.28, 0.4, 0.5, 0.58, 0.66, 0.74, 0.82, 0.9 }
Config.ZONE_DIFFICULTY_RAMP = 0.45
Config.ZONE_DIFFICULTY_AFTER = 0.06

function Config.difficultyFor(zone, roomInZone)
	local base = Config.ZoneDifficulty[zone + 1]
	if base == nil then
		base = Config.ZoneDifficulty[#Config.ZoneDifficulty]
			+ (zone + 1 - #Config.ZoneDifficulty) * Config.ZONE_DIFFICULTY_AFTER
	end
	return base + roomInZone / Config.ROOMS_PER_CHECKPOINT * Config.ZONE_DIFFICULTY_RAMP
end

-- Crystals (extra balls) per room: { min, max } per zone. Later zones give fewer,
-- so every throw counts. Zones after the last use the last entry.
Config.ZoneCrystals = { { 1, 2 }, { 1, 2 }, { 1, 1 }, { 1, 1 }, { 1, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 } }
-- Chance that armored glass hides a bonus crystal right behind it.
Config.ARMOR_BONUS_CRYSTAL_CHANCE = 0.4

-- First time you fly into a zone you get a reward (once per account, saved in
-- ZonesRewarded). Keys are the zone number the game shows ("ZONE 05"; START is 0).
-- ZONE 10 means you made it through all 10 zones.
Config.ZoneRewards = {
	[1] = { Gems = 50 },
	[2] = { Gems = 100 },
	[3] = { Gems = 150, Boost = "Shield" },
	[4] = { Gems = 200, Boost = "MegaBall" },
	[5] = { Gems = 250, Boost = "DoubleGems" },
	[6] = { Gems = 350, Boost = "Shield" },
	[7] = { Gems = 450, Boost = "SlowMo" },
	[8] = { Gems = 600, Boost = "MegaBall" },
	[9] = { Gems = 800, Boost = "DoubleGems" },
	[10] = { Gems = 1000, Skin = "PrismShard" },
	-- Endless milestones: the zones keep coming after ZONE 10, and so do rewards.
	-- (One zone = Config.checkpointMeters(1), about 373 m: ZONE 20 is about 7,500 m.)
	[12] = { Gems = 1200, Boost = "Shield" },
	[15] = { Gems = 1500, Fx = "Endless" },
	[20] = { Gems = 2000, Skin = "Afterburn" },
	[25] = { Gems = 2500, Boost = "MegaBall" },
	[30] = { Gems = 3000, Fx = "Starfall" },
	[40] = { Gems = 4000, Boost = "DoubleGems" },
	[50] = { Gems = 5000, Skin = "Infinity" },
}

-- The first zone after `zone` with a first-time reward, and that reward
-- (nil once there are no more).
function Config.nextZoneReward(zone)
	local best = nil
	for rewardZone in Config.ZoneRewards do
		if rewardZone > zone and (best == nil or rewardZone < best) then
			best = rewardZone
		end
	end
	return best, if best then Config.ZoneRewards[best] else nil
end

-- Smoothness (frame budgets) ---------------------------------------------------
-- Every heavy job is cut into small slices so no single frame does big work.
-- Times are seconds of work per frame. "LOW_" = Low graphics (weak phones).
Config.ROOM_BUILD_BUDGET = 0.0015 -- building rooms ahead (parts are created until this runs out, then it waits a frame)
Config.LOW_ROOM_BUILD_BUDGET = 0.001
Config.ROOM_TEARDOWN_BUDGET = 0.0006 -- deleting rooms behind the camera, a few parts per frame
Config.LOW_ROOM_TEARDOWN_BUDGET = 0.0004
-- Safety net: a room still unfinished when the camera is this close (studs) is finished at once.
-- Should never happen (rooms are built a whole room early); Studio prints a warning if it does.
Config.ROOM_FORCE_DISTANCE = 40
Config.CRYSTAL_SPIN_RANGE = 150 -- only crystals this close (studs) spin
Config.SHADOW_LIGHT_ROOMS = 2 -- shadow-casting lights only in the room you're in and the next one (High graphics, not phones)
Config.SHOW_PERF = false -- true = playtest build: small FPS / worst frame / part count label in the bottom-left corner

-- Glass breaking ---------------------------------------------------------------
-- Shards are reused from a pool (no creating / deleting parts per break), land on
-- the floor and pile up, then fade out. They hit floor and walls but not each other.
Config.SHARD_RAYS = 8 -- cracks spreading from the impact (more = finer shards, slower)
Config.SHARD_LIFETIME = 5 -- seconds a shard stays (shards behind the camera are recycled early)
Config.SHARD_FADE_TIME = 0.5 -- the last part of that lifetime they fade away
Config.MAX_LIVE_SHARDS = 360 -- above this many shard parts, new breaks use fewer, simpler shards
Config.LOW_MAX_LIVE_SHARDS = 160
Config.SHARD_POOL_WARM = 120 -- triangle shards made ahead of time, a few per frame (Low: half)
Config.SHARD_SPAWN_BUDGET = 0.0012 -- seconds per frame placing new shards (a big break spreads over 2-3 frames)
Config.LOW_SHARD_SPAWN_BUDGET = 0.0008
Config.SHARD_BACK_BURST = 0.35 -- chance a shard right at the impact flies back toward you instead of away

-- Knock-loose decorations: balls knock solid decorations (crates, benches, lamps,
-- plants, racks, signs) off their spot so they topple and tumble.
Config.LOOSE_DECOR_MAX = 80 -- at most this many tumbling at once (the oldest freeze in place)
Config.LOW_LOOSE_DECOR_MAX = 40
Config.LOOSE_DECOR_MAX_SIZE = 8 -- parts bigger than this (studs, longest side) never come loose
Config.LOOSE_DECOR_SETTLE = 6 -- seconds a knocked part tumbles before it freezes where it lies
Config.LOOSE_DECOR_SPEED = 26 -- how hard a ball knocks things (studs per second)

-- Ball impacts on walls / floor: a dust puff and a few chips.
Config.IMPACT_FX_INTERVAL = 0.04 -- at most one impact effect this often (seconds)
Config.IMPACT_CHIP_LIFETIME = 1.4

Config.GLASS_COLOR = Color3.fromRGB(200, 235, 255)
Config.CRYSTAL_COLOR = Color3.fromRGB(60, 140, 255)
Config.DOOR_COLOR = Color3.fromRGB(60, 62, 70)
Config.BUTTON_COLOR = Color3.fromRGB(255, 60, 60)

return Config
