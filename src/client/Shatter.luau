--[[
	Breaking effects.

	Glass panes crack outward from the point the ball hit: cracks run from the
	impact to the edges, a ring of cracks crosses them, and every piece in between
	becomes a real triangle shard. Shards near the impact burst out (some fly
	back past the camera), pop up and spin; the rest drop. All of them land on
	the floor, slide and pile up, then fade out (Config.SHARD_LIFETIME).

	Shatter.shieldBreak is the burst shown when a Shield boost absorbs a crash.
	Shatter.impact is the dust puff + chips when a ball hits a wall or the floor.
	Shatter.skinBurst is the splash in the ball skin's colors wherever a ball hits
	(animated balls get a themed one: Supernova flare, Black Hole implosion,
	Grinny's yellow sparkles with a few dark glitch bits...).
	Shatter.knockLoose / knockAround knock solid decorations off their spot.

	Smoothness (why it looks like this):
	  - Pooling: every shard part is made once and reused. Creating and
	    deleting parts is one of the most expensive things a game can do in a
	    frame; moving an existing part is cheap. Idle pool parts wait anchored,
	    invisible and non-colliding far above the track (PARK). That's cheaper
	    than parenting them to nil, because taking a part out of the world and
	    putting it back costs about as much as creating it. The pool fills up a
	    few parts per frame while you're in the menu (Config.SHARD_POOL_WARM).
	  - Spawn queue: a break only computes where its shards go; the shards
	    are placed by Shatter.update, a fixed time per frame
	    (Config.SHARD_SPAWN_BUDGET). Usually that's the same frame; a huge
	    multi-pane mega ball smash spreads over 2-3 frames.
	  - "Shards" collision group: shards and loose decorations hit the floor
	    and walls but not each other, so a pile costs the physics engine little.
	  - Shards that end up behind the camera are recycled early (nobody sees
	    them), so at top speed only a few dozen are ever live.
	  - Budget: above Config.MAX_LIVE_SHARDS live shard parts new breaks use
	    fewer cracks, only the small pieces around the impact and no glitter.

	Shatter.glass / Shatter.prop take an optional shatter effect (an entry of
	Config.ShatterFx) that tints the shards. nil or "Classic" = normal glass.
	Their `parent` argument is ignored now (pooled parts live in the
	workspace folder "ShatterPool"); it's kept so callers don't change.

	Low graphics (Settings): smaller shard and loose-decoration caps, fewer
	cracks per pane, fewer prop pieces, no glitter or glass dust.

	RunController must call Shatter.update(cameraZ) every frame and
	Shatter.reset() when a new run's world is built.
]]

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Settings = require(script.Parent.Settings)

local Shatter = {}

local rng = Random.new()
local TAU = math.pi * 2
local UP = Vector3.yAxis
local SMALL_PANE_AREA = 20 -- panes smaller than this (square studs) use few cracks
local BIG_PANE_AREA = 150 -- panes at least this big get a glass dust burst
local FEW_RAYS = 5
local LOW_MAX_RAYS = 7 -- Low graphics: at most this many cracks per pane
local LOW_PROP_PIECES = 5 -- Low graphics: at most this many shards per prop part
local SHARD_JITTER = 0.6 -- extra random lifetime so a pane's shards don't all vanish together

local PARK = CFrame.new(0, 5000, 0) -- idle pool parts wait here (anchored, invisible)
local RELEASES_PER_FRAME = 40 -- shards put back into the pool per frame, at most
local BEHIND_CHECK_INTERVAL = 0.25 -- seconds between checks for shards behind the camera
local BEHIND_DISTANCE = 8 -- shards this far behind the camera are recycled
local WARM_BUDGET = 0.0003 -- seconds per frame spent filling the pool
local WEDGE_WARM, CHIP_WARM = 40, 24 -- single wedges / chips made ahead of time
local MAX_WEDGES, LOW_MAX_WEDGES = 160, 80 -- single wedges (prop pieces, shield burst)
local MAX_CHIPS, LOW_MAX_CHIPS = 60, 30 -- small blocks (impact chips, crystal pop)
local SHARDS_GROUP = "Shards"

-- Knocked-loose decorations
local KNOCK_UP = 6 -- upward pop (studs per second)
local KNOCK_SPIN = 7 -- spin (radians per second, roughly)
local KNOCK_NUDGE = 0.06 -- studs a knocked part is moved off the wall / floor so it doesn't start stuck
local KNOCK_FULL_SIZE = 2.5 -- parts up to this size (studs) get the full knock; bigger ones less

-- Low graphics (kept up to date when the setting changes).
local low = Settings.graphicsLevel() == "Low"
Settings.changed:Connect(function(key)
	if key == "graphics" then
		low = Settings.graphicsLevel() == "Low"
	end
end)

-- Collision group -------------------------------------------------------------
-- Shards and loose decorations collide with the floor and walls (Default group)
-- but not with each other. If the group can't be set up from here, everything
-- still works; pieces just also bump into each other (more physics work).

local function setupCollisionGroup()
	local okCheck, registered = pcall(PhysicsService.IsCollisionGroupRegistered, PhysicsService, SHARDS_GROUP)
	if not okCheck then
		registered = false
	end
	if not registered then
		local ok, err = pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, SHARDS_GROUP)
		if not ok then
			warn("[Shatter] could not register the Shards collision group: " .. tostring(err))
			return nil
		end
	end
	local ok, err = pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, SHARDS_GROUP, SHARDS_GROUP, false)
	if not ok then
		warn("[Shatter] Shards collision group: " .. tostring(err))
	end
	return SHARDS_GROUP
end

local shardsGroup = setupCollisionGroup()

-- Pool ---------------------------------------------------------------------------
-- Kinds: "Pair" = triangle shard (two wedges + a weld), "Wedge" = one wedge,
-- "Chip" = small block. An entry is reused forever:
-- { kind, a, b?, weld?, parts, expires, fadeStart, baseT, spawnZ }

local poolFolder = Instance.new("Folder")
poolFolder.Name = "ShatterPool"
poolFolder.Parent = workspace

local free = { Pair = {}, Wedge = {}, Chip = {} }
local made = { Pair = 0, Wedge = 0, Chip = 0 }
local live = {} -- entries in use (any order)
local liveParts = 0

local function shardCap()
	return if low then Config.LOW_MAX_LIVE_SHARDS else Config.MAX_LIVE_SHARDS
end

local function maxMade(kind)
	if kind == "Pair" then
		return math.ceil(shardCap() / 2 * 1.25)
	elseif kind == "Wedge" then
		return if low then LOW_MAX_WEDGES else MAX_WEDGES
	end
	return if low then LOW_MAX_CHIPS else MAX_CHIPS
end

local function warmTarget(kind)
	if kind == "Pair" then
		return if low then Config.SHARD_POOL_WARM // 2 else Config.SHARD_POOL_WARM
	elseif kind == "Wedge" then
		return WEDGE_WARM
	end
	return CHIP_WARM
end

local function newPoolPart(className)
	local part = Instance.new(className)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.CFrame = PARK
	if shardsGroup then
		part.CollisionGroup = shardsGroup
	end
	part.Parent = poolFolder
	return part
end

local function createEntry(kind)
	local entry = { kind = kind, parts = 1, expires = 0, fadeStart = 0, baseT = 0, spawnZ = 0 }
	if kind == "Pair" then
		entry.a = newPoolPart("WedgePart")
		entry.b = newPoolPart("WedgePart")
		-- A classic Weld with an explicit offset (C0), set every time the pair is
		-- reused, so the two halves always line up exactly.
		local weld = Instance.new("Weld")
		weld.Part0 = entry.a
		weld.Part1 = entry.b
		weld.Parent = entry.a
		entry.weld = weld
		entry.parts = 2
	elseif kind == "Wedge" then
		entry.a = newPoolPart("WedgePart")
	else
		entry.a = newPoolPart("Part")
	end
	made[kind] += 1
	return entry
end

-- Takes a live entry out of the live list (swap with the last one).
local function removeLive(index)
	local entry = live[index]
	local last = #live
	live[index] = live[last]
	live[last] = nil
	liveParts -= entry.parts
	return entry
end

-- Puts a piece back: anchored, invisible, out of the way.
local function park(entry)
	local a = entry.a
	a.Anchored = true
	a.CanCollide = false
	a.Transparency = 1
	a.CFrame = PARK
	local b = entry.b
	if b then
		b.Anchored = true
		b.CanCollide = false
		b.Transparency = 1
		b.CFrame = PARK * entry.weld.C0
	end
	table.insert(free[entry.kind], entry)
end

-- A free piece of this kind: from the pool, newly made (pool not full yet), or
-- the oldest live one when everything is in use. nil if there's none at all.
local function acquire(kind)
	local entry = table.remove(free[kind])
	if entry then
		return entry
	end
	if made[kind] < maxMade(kind) then
		return createEntry(kind)
	end
	local oldestIndex, oldestTime = nil, math.huge
	for index, other in live do
		if other.kind == kind and other.expires < oldestTime then
			oldestIndex, oldestTime = index, other.expires
		end
	end
	if oldestIndex then
		return removeLive(oldestIndex)
	end
	return nil
end

-- Marks a placed piece as live; it fades over the last `fade` seconds of `lifetime`.
local function addLive(entry, baseTransparency, lifetime, fade, z)
	local now = os.clock()
	entry.expires = now + lifetime
	entry.fadeStart = entry.expires - math.min(fade, lifetime)
	entry.baseT = baseTransparency
	entry.spawnZ = z
	table.insert(live, entry)
	liveParts += entry.parts
end

local function applyStyle(part, style, collide)
	part.Material = style.Material
	part.Color = style.Color
	part.Transparency = style.Transparency
	part.Reflectance = style.Reflectance
	part.CanCollide = collide
end

function Shatter.liveCount()
	return liveParts
end

-- Particle bursts ------------------------------------------------------------------
-- A few emitters per effect, each on its own little anchored holder part. A burst
-- moves the next holder to the spot and calls Emit; particles already flying stay
-- where they are. Round robin, so a new burst rarely recolors a fresh one.

-- holderSize: only matters for emitters that spawn on a shape (BlackHole's implosion).
local function newEmitterSet(count, setup, holderSize)
	local set = { next = 1 }
	for i = 1, count do
		local holder = Instance.new("Part")
		holder.Name = "Emitter"
		holder.Anchored = true
		holder.CanCollide = false
		holder.CanQuery = false
		holder.CanTouch = false
		holder.CastShadow = false
		holder.Transparency = 1
		holder.Size = Vector3.one * (holderSize or 0.2)
		holder.CFrame = PARK
		local emitter = Instance.new("ParticleEmitter")
		emitter.Enabled = false
		setup(emitter)
		emitter.Parent = holder
		holder.Parent = poolFolder
		set[i] = { holder = holder, emitter = emitter }
	end
	set.count = count
	return set
end

local function nextEmitter(set)
	local slot = set[set.next]
	set.next = set.next % set.count + 1
	return slot
end

local glitter = newEmitterSet(4, function(emitter)
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new(0, 1)
	emitter.Lifetime = NumberRange.new(0.3, 0.7)
	emitter.Speed = NumberRange.new(8, 22)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -30, 0)
	emitter.Drag = 2
	emitter.Rotation = NumberRange.new(0, 360)
end)

local dust = newEmitterSet(3, function(emitter)
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.LightEmission = 0
	emitter.LightInfluence = 1
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1.8),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.35, 0.7)
	emitter.Speed = NumberRange.new(2, 6)
	emitter.SpreadAngle = Vector2.new(55, 55)
	emitter.Acceleration = Vector3.new(0, -2, 0)
	emitter.Drag = 4
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-40, 40)
end)

local glassDust = newEmitterSet(2, function(emitter)
	emitter.LightEmission = 0.6
	emitter.Color = ColorSequence.new(Color3.fromRGB(235, 248, 255))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.16),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new(0.1, 1)
	emitter.Lifetime = NumberRange.new(0.5, 1.1)
	emitter.Speed = NumberRange.new(4, 14)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -12, 0)
	emitter.Drag = 3
	emitter.Rotation = NumberRange.new(0, 360)
end)

-- A short burst of glitter at the impact point.
local function sparkle(position, color, amount)
	if low then
		return -- Low graphics: no glitter
	end
	local slot = nextEmitter(glitter)
	slot.holder.CFrame = CFrame.new(position)
	slot.emitter.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.5))
	slot.emitter:Emit(amount)
end

-- Fine glass dust hanging in the air after a big pane goes.
local function glassDustBurst(position, amount)
	if low then
		return
	end
	local slot = nextEmitter(glassDust)
	slot.holder.CFrame = CFrame.new(position)
	slot.emitter:Emit(amount)
end

-- Shatter effects -----------------------------------------------------------

local function hasFx(fx)
	return fx ~= nil and fx.Id ~= "Classic"
end

-- The look of one shard as a plain table (read once, so the original part can
-- be deleted right away). Rainbow effects get a new random hue for every shard.
local function styledTemplate(template, fx)
	local style = {
		Material = template.Material,
		Color = template.Color,
		Transparency = template.Transparency,
		Reflectance = template.Reflectance,
	}
	if not hasFx(fx) then
		return style
	end
	if fx.Rainbow then
		style.Color = Color3.fromHSV(rng:NextNumber(), 0.75, 1)
	elseif fx.Color then
		style.Color = fx.Color
	end
	if fx.Neon then
		style.Material = Enum.Material.Neon
		style.Transparency = math.min(style.Transparency, 0.2)
	elseif fx.Metal then
		style.Material = Enum.Material.Foil
		style.Transparency = 0
		style.Reflectance = 0.35
	end
	return style
end

-- Color and amount of the glitter burst.
local function sparkleStyle(baseColor, amount, fx)
	if not hasFx(fx) then
		return baseColor, amount
	end
	local color = fx.Color or baseColor
	if fx.Rainbow then
		color = Color3.fromHSV(rng:NextNumber(), 0.6, 1)
	end
	if fx.Sparkle then
		amount = math.floor(amount * 2.5)
	end
	return color, amount
end

-- How a shard flies: through the pane along `push`, outward from the impact,
-- popping up and spinning. Pieces right at the impact fly hardest, and some of
-- them burst back toward the player instead (Config.SHARD_BACK_BURST).
local function launchVelocity(center, hitPoint, push, reach)
	local away = center - hitPoint
	local distance = away.Magnitude
	local closeness = math.clamp(1 - distance / reach, 0, 1)
	local radial = if distance > 0.01 then away / distance else rng:NextUnitVector()

	local through = push * (4 + 26 * closeness ^ 1.5)
	if rng:NextNumber() < Config.SHARD_BACK_BURST * closeness then
		through = -push * rng:NextNumber(6, 16)
	end
	local linear = through
		+ radial * (3 + 20 * closeness)
		+ UP * (2 + 10 * closeness * rng:NextNumber(0.5, 1))
		+ rng:NextUnitVector() * 2
	local angular = rng:NextUnitVector() * rng:NextNumber(3, 8 + 16 * closeness)
	return linear, angular
end

-- Triangles ----------------------------------------------------------------

-- A flat triangle a-b-c as two wedge parts: returns their sizes and CFrames,
-- or nil for a sliver too thin to draw.
local function triangleShape(a, b, c, thickness)
	-- Make b-c the longest edge.
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b

	local normal = ac:Cross(ab)
	if normal.Magnitude < 0.05 or bc.Magnitude < 0.05 then
		return nil
	end
	local right = normal.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	if height < 0.05 then
		return nil
	end

	local size1 = Vector3.new(thickness, height, math.abs(ab:Dot(back)))
	local cframe1 = CFrame.fromMatrix((a + b) / 2, right, up, back)
	local size2 = Vector3.new(thickness, height, math.abs(ac:Dot(back)))
	local cframe2 = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
	return size1, cframe1, size2, cframe2
end

-- Spawn queue ---------------------------------------------------------------
-- Jobs: { triangle = true, a, b, c, thickness, style, hit, push, reach }
--    or { size, cframe, style, hit, push, reach } (one prop piece)

local queue = {}
local queueHead = 1
local queuedParts = 0

local function enqueue(job, parts)
	table.insert(queue, job)
	queuedParts += parts
end

local function spawnTriangle(job)
	queuedParts -= 2
	local size1, cframe1, size2, cframe2 = triangleShape(job.a, job.b, job.c, job.thickness)
	if not size1 then
		return
	end
	local entry = acquire("Pair")
	if not entry then
		return
	end
	local a, b = entry.a, entry.b
	applyStyle(a, job.style, true)
	applyStyle(b, job.style, true)
	a.Size = size1
	b.Size = size2
	entry.weld.C0 = cframe1:ToObjectSpace(cframe2)
	a.CFrame = cframe1
	b.CFrame = cframe2
	a.Anchored = false
	b.Anchored = false
	local center = (job.a + job.b + job.c) / 3
	local linear, angular = launchVelocity(center, job.hit, job.push, job.reach)
	a.AssemblyLinearVelocity = linear
	a.AssemblyAngularVelocity = angular
	addLive(entry, job.style.Transparency, Config.SHARD_LIFETIME + rng:NextNumber(0, SHARD_JITTER), Config.SHARD_FADE_TIME, center.Z)
end

local function spawnPiece(job)
	queuedParts -= 1
	local entry = acquire("Wedge")
	if not entry then
		return
	end
	local part = entry.a
	applyStyle(part, job.style, true)
	part.Size = job.size
	part.CFrame = job.cframe
	part.Anchored = false
	local position = job.cframe.Position
	local linear, angular = launchVelocity(position, job.hit, job.push, job.reach)
	part.AssemblyLinearVelocity = linear
	part.AssemblyAngularVelocity = angular
	addLive(entry, job.style.Transparency, Config.SHARD_LIFETIME + rng:NextNumber(0, SHARD_JITTER), Config.SHARD_FADE_TIME, position.Z)
end

-- Places queued shards until this frame's spawn time is used up (at least one).
local function processQueue()
	local deadline = os.clock() + (if low then Config.LOW_SHARD_SPAWN_BUDGET else Config.SHARD_SPAWN_BUDGET)
	while queue[queueHead] do
		local job = queue[queueHead]
		queue[queueHead] = false -- keeps the array dense until it's cleared below
		queueHead += 1
		if job.triangle then
			spawnTriangle(job)
		else
			spawnPiece(job)
		end
		if os.clock() > deadline then
			break
		end
	end
	if queue[queueHead] == nil then
		table.clear(queue)
		queueHead = 1
		queuedParts = 0
	end
end

local function overBudget()
	return liveParts + queuedParts >= shardCap()
end

-- Crack pattern ------------------------------------------------------------

-- Where a ray from p in direction d leaves the rectangle [-hx,hx] x [-hy,hy].
local function toEdge(p, d, hx, hy)
	local t = math.huge
	if d.X > 1e-6 then
		t = math.min(t, (hx - p.X) / d.X)
	elseif d.X < -1e-6 then
		t = math.min(t, (-hx - p.X) / d.X)
	end
	if d.Y > 1e-6 then
		t = math.min(t, (hy - p.Y) / d.Y)
	elseif d.Y < -1e-6 then
		t = math.min(t, (-hy - p.Y) / d.Y)
	end
	return p + d * t, t
end

local function angleOf(p, q)
	return math.atan2(q.Y - p.Y, q.X - p.X) % TAU
end

-- Returns a list of 2D triangles { {a, b, c, inner = bool}, ... } covering the
-- pane, in the pane's local X/Y plane, with the impact point p. Inner pieces
-- come first. innerOnly = true: just the small fan around the impact (shard budget).
local function crackPattern(p, hx, hy, rays, innerOnly)
	local start = rng:NextNumber(0, TAU)
	local angles = {}
	for i = 0, rays - 1 do
		local jitter = rng:NextNumber(-0.35, 0.35) * TAU / rays
		table.insert(angles, (start + i * TAU / rays + jitter) % TAU)
	end
	table.sort(angles)

	local edges, rings = {}, {}
	for i, angle in angles do
		local d = Vector2.new(math.cos(angle), math.sin(angle))
		local edge, length = toEdge(p, d, hx, hy)
		edges[i] = edge
		rings[i] = p + d * length * rng:NextNumber(0.25, 0.55)
	end

	local corners = {
		Vector2.new(hx, hy),
		Vector2.new(-hx, hy),
		Vector2.new(-hx, -hy),
		Vector2.new(hx, -hy),
	}

	local triangles = {}
	-- Inner fan: the small, fast pieces around the impact.
	for i = 1, rays do
		local j = i % rays + 1
		table.insert(triangles, { p, rings[i], rings[j], inner = true })
	end
	if innerOnly then
		return triangles
	end

	for i = 1, rays do
		local j = i % rays + 1
		local a1, a2 = angles[i], angles[j]
		local span = (a2 - a1) % TAU

		-- Outer piece: ring crack -> edge, including any pane corners in between.
		local boundary = { edges[i] }
		local between = {}
		for _, corner in corners do
			local offset = (angleOf(p, corner) - a1) % TAU
			if offset > 0 and offset < span then
				table.insert(between, { offset = offset, point = corner })
			end
		end
		table.sort(between, function(x, y)
			return x.offset < y.offset
		end)
		for _, entry in between do
			table.insert(boundary, entry.point)
		end
		table.insert(boundary, edges[j])

		for k = 1, #boundary - 1 do
			table.insert(triangles, { rings[i], boundary[k], boundary[k + 1] })
		end
		table.insert(triangles, { rings[i], edges[j], rings[j] })
	end
	return triangles
end

-- Public -------------------------------------------------------------------

function Shatter.glass(panel, hitPoint, push, _parent, fx)
	local size = panel.Size
	local cf = panel.CFrame
	local hx, hy = size.X / 2, size.Y / 2
	local thickness = math.min(size.Z, 0.4)

	-- Impact point in the pane's own 2D space (clamped just inside the edges).
	local localHit = cf:PointToObjectSpace(hitPoint)
	local p = Vector2.new(math.clamp(localHit.X, -hx * 0.95, hx * 0.95), math.clamp(localHit.Y, -hy * 0.95, hy * 0.95))

	-- Bigger panes get a few more cracks, small ones (grid tiles) only a few.
	-- Too many shards already: few cracks, inner pieces only, no glitter.
	local area = size.X * size.Y
	local busy = overBudget()
	local rays = math.clamp(Config.SHARD_RAYS + math.floor(area / 120), 5, 12)
	if low then
		rays = math.min(rays, LOW_MAX_RAYS)
	end
	if busy or area < SMALL_PANE_AREA then
		rays = FEW_RAYS
	end
	local reach = math.max(size.X, size.Y) * 0.6
	local worldHit = cf * Vector3.new(p.X, p.Y, 0)

	local plainStyle = if fx and fx.Rainbow then nil else styledTemplate(panel, fx)
	for _, tri in crackPattern(p, hx, hy, rays, busy) do
		enqueue({
			triangle = true,
			a = cf * Vector3.new(tri[1].X, tri[1].Y, 0),
			b = cf * Vector3.new(tri[2].X, tri[2].Y, 0),
			c = cf * Vector3.new(tri[3].X, tri[3].Y, 0),
			thickness = thickness,
			style = plainStyle or styledTemplate(panel, fx),
			hit = worldHit,
			push = push,
			reach = reach,
		}, 2)
	end

	if not busy then
		local sparkleColor, sparkleAmount = sparkleStyle(panel.Color, 25, fx)
		sparkle(worldHit, sparkleColor, sparkleAmount)
		if area >= BIG_PANE_AREA then
			glassDustBurst(worldHit, 30)
		end
	end
	panel:Destroy()
end

-- Breakable decorations (vases, bottles, lamps...). Each part bursts into
-- small random shards. Hitting any part of a breakable Model breaks all of it.
function Shatter.prop(part, hitPoint, push, _parent, fx)
	-- Walk up to the breakable model this part belongs to (if any).
	local root = part
	local ancestor = part.Parent
	while ancestor and ancestor ~= workspace do
		if ancestor:IsA("Model") and ancestor:GetAttribute("Breakable") then
			root = ancestor
			break
		end
		ancestor = ancestor.Parent
	end

	local pieces = if root:IsA("BasePart") then { root } else {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(pieces, descendant)
		end
	end

	local busy = overBudget()
	for _, piece in pieces do
		local size = piece.Size
		local volume = size.X * size.Y * size.Z
		local most = if busy then 3 elseif low then LOW_PROP_PIECES else 10
		local count = math.clamp(math.floor(volume / 1.5), 3, most)
		local reach = math.max(size.X, size.Y, size.Z) * 2
		local plainStyle = if fx and fx.Rainbow then nil else styledTemplate(piece, fx)
		for _ = 1, count do
			local shardSize = Vector3.new(
				math.max(0.1, size.X * rng:NextNumber(0.15, 0.4)),
				math.max(0.1, size.Y * rng:NextNumber(0.15, 0.4)),
				math.max(0.1, size.Z * rng:NextNumber(0.1, 0.3))
			)
			local offset = Vector3.new(
				rng:NextNumber(-0.5, 0.5) * size.X,
				rng:NextNumber(-0.5, 0.5) * size.Y,
				rng:NextNumber(-0.5, 0.5) * size.Z
			)
			local cframe = piece.CFrame
				* CFrame.new(offset)
				* CFrame.Angles(rng:NextNumber(0, TAU), rng:NextNumber(0, TAU), rng:NextNumber(0, TAU))
			enqueue({
				size = shardSize,
				cframe = cframe,
				style = plainStyle or styledTemplate(piece, fx),
				hit = hitPoint,
				push = push * 0.5,
				reach = reach,
			}, 1)
		end
		if not busy then
			local sparkleColor, sparkleAmount = sparkleStyle(piece.Color, 10, fx)
			sparkle(piece.Position, sparkleColor, sparkleAmount)
		end
	end

	root:Destroy()
end

-- Shield boost breaking: a ring of glowing shards bursts outward around the
-- player's view. cameraCFrame = where the camera is, carry = the camera's
-- velocity (so the burst travels along instead of being left behind).
local SHIELD_SHARDS = 16
local SHIELD_DISTANCE = 3.5
local SHIELD_RADIUS = 2.6

function Shatter.shieldBreak(cameraCFrame, color, _parent, carry)
	local style = {
		Material = Enum.Material.Neon,
		Color = color,
		Transparency = 0.25,
		Reflectance = 0,
	}
	local center = cameraCFrame * Vector3.new(0, 0, -SHIELD_DISTANCE)
	for i = 1, SHIELD_SHARDS do
		local entry = acquire("Wedge")
		if not entry then
			break
		end
		local angle = (i / SHIELD_SHARDS) * TAU + rng:NextNumber(-0.15, 0.15)
		local outward = cameraCFrame:VectorToWorldSpace(Vector3.new(math.cos(angle), math.sin(angle), 0))
		local shard = entry.a
		applyStyle(shard, style, false)
		shard.Size = Vector3.new(0.08, rng:NextNumber(0.4, 0.9), rng:NextNumber(0.3, 0.7))
		shard.CFrame = CFrame.lookAt(center + outward * SHIELD_RADIUS, center + outward * (SHIELD_RADIUS + 1))
			* CFrame.Angles(0, 0, rng:NextNumber(0, TAU))
		shard.Anchored = false
		shard.AssemblyLinearVelocity = carry + outward * rng:NextNumber(14, 24)
		shard.AssemblyAngularVelocity = rng:NextUnitVector() * rng:NextNumber(4, 10)
		addLive(entry, style.Transparency, 0.7, 0.25, center.Z)
	end
	sparkle(center, color, 30)
end

function Shatter.crystal(crystal, _parent)
	crystal.CanQuery = false

	-- A pop of glowing chips plus the crystal shrinking away.
	local style = {
		Material = crystal.Material,
		Color = crystal.Color,
		Transparency = crystal.Transparency,
		Reflectance = crystal.Reflectance,
	}
	for _ = 1, 6 do
		local entry = acquire("Chip")
		if not entry then
			break
		end
		local chip = entry.a
		applyStyle(chip, style, false)
		chip.Size = Vector3.one * rng:NextNumber(0.2, 0.45)
		chip.CFrame = crystal.CFrame * CFrame.Angles(rng:NextNumber(0, TAU), rng:NextNumber(0, TAU), 0)
		chip.Anchored = false
		chip.AssemblyLinearVelocity = rng:NextUnitVector() * rng:NextNumber(10, 20)
		addLive(entry, style.Transparency, 0.6, 0.2, crystal.Position.Z)
	end
	sparkle(crystal.Position, crystal.Color, 18)

	local tween = TweenService:Create(crystal, TweenInfo.new(0.25), {
		Size = Vector3.zero,
		Transparency = 1,
	})
	tween.Completed:Connect(function()
		crystal:Destroy()
	end)
	tween:Play()
end

-- Ball impacts -----------------------------------------------------------------

local lastImpact = 0

-- A ball hit a wall, the floor or a decoration: a small dust puff and a few
-- chips of that surface. Rate limited (Config.IMPACT_FX_INTERVAL).
function Shatter.impact(position, normal, surface)
	local now = os.clock()
	if now - lastImpact < Config.IMPACT_FX_INTERVAL then
		return
	end
	lastImpact = now

	local color = surface.Color
	local up = if math.abs(normal.Y) > 0.9 then Vector3.xAxis else UP
	local slot = nextEmitter(dust)
	slot.holder.CFrame = CFrame.lookAt(position, position + normal, up)
	slot.emitter.Color = ColorSequence.new(color:Lerp(Color3.fromRGB(150, 150, 150), 0.4))
	slot.emitter:Emit(if low then 3 else 6)

	local style = {
		Material = surface.Material,
		Color = color:Lerp(Color3.new(0, 0, 0), 0.15),
		Transparency = math.min(surface.Transparency, 0.3),
		Reflectance = 0,
	}
	for _ = 1, if low then 2 else rng:NextInteger(2, 4) do
		local entry = acquire("Chip")
		if not entry then
			break
		end
		local chip = entry.a
		applyStyle(chip, style, true)
		chip.Size = Vector3.new(rng:NextNumber(0.12, 0.3), rng:NextNumber(0.1, 0.22), rng:NextNumber(0.12, 0.3))
		chip.CFrame = CFrame.new(position + normal * 0.25)
			* CFrame.Angles(rng:NextNumber(0, TAU), rng:NextNumber(0, TAU), rng:NextNumber(0, TAU))
		chip.Anchored = false
		chip.AssemblyLinearVelocity = normal * rng:NextNumber(8, 16) + rng:NextUnitVector() * 5 + UP * 4
		chip.AssemblyAngularVelocity = rng:NextUnitVector() * rng:NextNumber(5, 15)
		addLive(entry, style.Transparency, Config.IMPACT_CHIP_LIFETIME, 0.3, position.Z)
	end
end

-- Ball skin splash ---------------------------------------------------------------
-- Wherever a ball hits glass, a prop or a wall, a short burst in its skin's colors
-- sprays out of the surface, so you see your skin at the moment that matters.
-- style = BallFx.impactStyle(skinId). Pooled emitters (round robin, made once;
-- the themed ones only the first time that ball is used). Rate limited; smaller
-- on Low graphics and while the shard budget is busy; the bright Supernova flare
-- follows the "flashes" setting.

local SKIN_BURST_INTERVAL = 0.05 -- at most one splash this often (a multiball fan hits at once)
local SKIN_BURST_COUNT = 14 -- sparks in a normal splash (Low: 40%)
local lastSkinBurst = 0
local flashesOn = Settings.get("flashes") ~= false
Settings.changed:Connect(function(key, value)
	if key == "flashes" then
		flashesOn = value ~= false
	end
end)

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local FIRE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"

local function fading(startSize, endSize)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, startSize),
		NumberSequenceKeypoint.new(1, endSize),
	})
end

-- Every skin: sparks thrown out of the surface (the emitter faces along the normal).
local skinSparks = newEmitterSet(4, function(emitter)
	emitter.Texture = SPARKLE_TEXTURE
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.LightEmission = 1
	emitter.Size = fading(0.4, 0)
	emitter.Transparency = NumberSequence.new(0, 1)
	emitter.Lifetime = NumberRange.new(0.25, 0.5)
	emitter.Speed = NumberRange.new(8, 20)
	emitter.SpreadAngle = Vector2.new(70, 70)
	emitter.Acceleration = Vector3.new(0, -25, 0)
	emitter.Drag = 4
	emitter.Rotation = NumberRange.new(0, 360)
end)

-- Themed splashes of the animated balls (premium + earned), made the first time they're needed.
local THEMES = {
	Supernova = {
		count = 22,
		setup = function(emitter) -- gold sparks flying hard
			emitter.Texture = FIRE_TEXTURE
			emitter.EmissionDirection = Enum.NormalId.Front
			emitter.LightEmission = 1
			emitter.Color = ColorSequence.new(Color3.fromRGB(255, 240, 180), Color3.fromRGB(255, 140, 30))
			emitter.Size = fading(0.6, 0)
			emitter.Transparency = NumberSequence.new(0, 1)
			emitter.Lifetime = NumberRange.new(0.25, 0.55)
			emitter.Speed = NumberRange.new(14, 30)
			emitter.SpreadAngle = Vector2.new(85, 85)
			emitter.Drag = 5
			emitter.Rotation = NumberRange.new(0, 360)
		end,
		flare = function(emitter) -- one big gold glow that blooms and fades
			emitter.Texture = SPARKLE_TEXTURE
			emitter.LightEmission = 1
			emitter.Color = ColorSequence.new(Color3.fromRGB(255, 225, 140))
			emitter.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1.5),
				NumberSequenceKeypoint.new(0.3, 4.5),
				NumberSequenceKeypoint.new(1, 0.5),
			})
			emitter.Transparency = NumberSequence.new(0.1, 1)
			emitter.Lifetime = NumberRange.new(0.22)
			emitter.Speed = NumberRange.new(0)
			emitter.Rotation = NumberRange.new(0, 360)
		end,
	},
	BlackHole = {
		count = 26,
		holderSize = 3.2,
		setup = function(emitter) -- purple sparks pulled in from a sphere around the hit
			emitter.Texture = SPARKLE_TEXTURE
			emitter.Shape = Enum.ParticleEmitterShape.Sphere
			emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
			emitter.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward
			emitter.LightEmission = 1
			emitter.Color = ColorSequence.new(Color3.fromRGB(215, 180, 255), Color3.fromRGB(130, 50, 255))
			emitter.Size = fading(0.3, 0.05)
			emitter.Transparency = NumberSequence.new(0.1, 0.6)
			emitter.Lifetime = NumberRange.new(0.2, 0.26)
			emitter.Speed = NumberRange.new(6, 7.5) -- reaches the middle as it fades
			emitter.Rotation = NumberRange.new(0, 360)
		end,
	},
	MagmaHeart = {
		count = 18,
		setup = function(emitter) -- glowing embers drifting up
			emitter.Texture = SPARKLE_TEXTURE
			emitter.EmissionDirection = Enum.NormalId.Front
			emitter.LightEmission = 1
			emitter.Color = ColorSequence.new(Color3.fromRGB(255, 190, 60), Color3.fromRGB(230, 50, 10))
			emitter.Size = fading(0.28, 0.05)
			emitter.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.7, 0.3),
				NumberSequenceKeypoint.new(1, 1),
			})
			emitter.Lifetime = NumberRange.new(0.7, 1.3)
			emitter.Speed = NumberRange.new(4, 11)
			emitter.SpreadAngle = Vector2.new(80, 80)
			emitter.Acceleration = Vector3.new(0, 7, 0)
			emitter.Drag = 2.5
			emitter.Rotation = NumberRange.new(0, 360)
			emitter.RotSpeed = NumberRange.new(-90, 90)
		end,
	},
	PlasmaCore = {
		count = 20,
		setup = function(emitter) -- fast violet sparks
			emitter.Texture = SPARKLE_TEXTURE
			emitter.EmissionDirection = Enum.NormalId.Front
			emitter.LightEmission = 1
			emitter.Color = ColorSequence.new(Color3.fromRGB(255, 150, 255), Color3.fromRGB(140, 80, 255))
			emitter.Size = fading(0.35, 0)
			emitter.Transparency = NumberSequence.new(0, 1)
			emitter.Lifetime = NumberRange.new(0.15, 0.35)
			emitter.Speed = NumberRange.new(20, 34)
			emitter.SpreadAngle = Vector2.new(90, 90)
			emitter.Drag = 7
			emitter.Rotation = NumberRange.new(0, 360)
			emitter.RotSpeed = NumberRange.new(-300, 300)
		end,
	},
	Frostbite = {
		count = 24,
		setup = function(emitter) -- soft snow sparkle settling down
			emitter.Texture = SPARKLE_TEXTURE
			emitter.EmissionDirection = Enum.NormalId.Front
			emitter.LightEmission = 0.7
			emitter.Color = ColorSequence.new(Color3.fromRGB(240, 250, 255), Color3.fromRGB(150, 215, 255))
			emitter.Size = fading(0.22, 0.06)
			emitter.Transparency = NumberSequence.new(0.05, 1)
			emitter.Lifetime = NumberRange.new(0.8, 1.4)
			emitter.Speed = NumberRange.new(3, 7)
			emitter.SpreadAngle = Vector2.new(90, 90)
			emitter.Acceleration = Vector3.new(0, -4, 0)
			emitter.Drag = 2
			emitter.Rotation = NumberRange.new(0, 360)
			emitter.RotSpeed = NumberRange.new(-60, 60)
		end,
	},
	-- Earned balls (never sold) get a themed splash too.
	Infinity = {
		count = 24,
		setup = function(emitter) -- cosmic sparkles bursting outward: violet, pink, gold
			emitter.Texture = SPARKLE_TEXTURE
			emitter.EmissionDirection = Enum.NormalId.Front
			emitter.LightEmission = 1
			emitter.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 90, 255)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 110, 220)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 210, 120)),
			})
			emitter.Size = fading(0.4, 0.05)
			emitter.Transparency = NumberSequence.new(0, 1)
			emitter.Lifetime = NumberRange.new(0.35, 0.7)
			emitter.Speed = NumberRange.new(10, 22)
			emitter.SpreadAngle = Vector2.new(85, 85)
			emitter.Drag = 5
			emitter.Rotation = NumberRange.new(0, 360)
			emitter.RotSpeed = NumberRange.new(-180, 180)
		end,
		flare = function(emitter) -- a soft violet-gold bloom
			emitter.Texture = SPARKLE_TEXTURE
			emitter.LightEmission = 1
			emitter.Color = ColorSequence.new(Color3.fromRGB(200, 160, 255), Color3.fromRGB(255, 220, 150))
			emitter.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1.2),
				NumberSequenceKeypoint.new(0.3, 3.5),
				NumberSequenceKeypoint.new(1, 0.4),
			})
			emitter.Transparency = NumberSequence.new(0.2, 1)
			emitter.Lifetime = NumberRange.new(0.2)
			emitter.Speed = NumberRange.new(0)
			emitter.Rotation = NumberRange.new(0, 360)
		end,
	},
	Smashbot = {
		count = 22,
		setup = function(emitter) -- fast hot sparks, orange into cyan
			emitter.Texture = SPARKLE_TEXTURE
			emitter.EmissionDirection = Enum.NormalId.Front
			emitter.LightEmission = 1
			emitter.Color = ColorSequence.new(Color3.fromRGB(255, 160, 50), Color3.fromRGB(110, 225, 255))
			emitter.Size = fading(0.3, 0)
			emitter.Transparency = NumberSequence.new(0, 1)
			emitter.Lifetime = NumberRange.new(0.1, 0.28)
			emitter.Speed = NumberRange.new(24, 40)
			emitter.SpreadAngle = Vector2.new(90, 90)
			emitter.Drag = 8
			emitter.Rotation = NumberRange.new(0, 360)
			emitter.RotSpeed = NumberRange.new(-400, 400)
		end,
	},
	-- Gem-shop balls too. Grinny: happy yellow sparkles + a few dark glitch bits
	-- (pooled chips, GRINNY_BITS below) for its creepy side. Nothing gory.
	Grinny = {
		count = 22,
		setup = function(emitter) -- bright yellow sparkles popping outward
			emitter.Texture = SPARKLE_TEXTURE
			emitter.EmissionDirection = Enum.NormalId.Front
			emitter.LightEmission = 1
			emitter.Color = ColorSequence.new(Color3.fromRGB(255, 245, 150), Color3.fromRGB(255, 195, 30))
			emitter.Size = fading(0.38, 0.05)
			emitter.Transparency = NumberSequence.new(0, 1)
			emitter.Lifetime = NumberRange.new(0.3, 0.6)
			emitter.Speed = NumberRange.new(10, 20)
			emitter.SpreadAngle = Vector2.new(85, 85)
			emitter.Drag = 5
			emitter.Rotation = NumberRange.new(0, 360)
			emitter.RotSpeed = NumberRange.new(-200, 200)
		end,
		bits = "Grinny",
	},
	-- CyberCore: glowing cyan bits (pooled chips, see below) + the normal sparks.
}
local themeSets = {} -- id -> { sparks = set, flare = set? }

local function themeSet(id)
	local theme = THEMES[id]
	if not theme then
		return nil
	end
	local sets = themeSets[id]
	if not sets then
		sets = { sparks = newEmitterSet(2, theme.setup, theme.holderSize) }
		if theme.flare then
			sets.flare = newEmitterSet(2, theme.flare)
		end
		themeSets[id] = sets
	end
	return sets, theme
end

local CYBER_BIT_STYLE = {
	Material = Enum.Material.Neon,
	Color = Color3.fromRGB(0, 235, 255),
	Transparency = 0,
	Reflectance = 0,
}
-- Glitch bits (pooled chips) thrown out of a splash: { count, lowCount, styles }.
-- Each bit takes the next style in turn.
local BIT_SETS = {
	CyberCore = { count = 5, lowCount = 2, styles = { CYBER_BIT_STYLE } },
	Grinny = {
		count = 4,
		lowCount = 2,
		styles = {
			{ Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(28, 22, 34), Transparency = 0, Reflectance = 0 },
			{ Material = Enum.Material.Neon, Color = Color3.fromRGB(200, 30, 60), Transparency = 0, Reflectance = 0 },
		},
	},
}

-- A few small cubes (pooled "Chip" parts) flying off the hit, then fading.
local function throwBits(position, normal, bitSet)
	local styles = bitSet.styles
	for i = 1, if low then bitSet.lowCount else bitSet.count do
		local entry = acquire("Chip")
		if not entry then
			break
		end
		local bit = entry.a
		applyStyle(bit, styles[(i - 1) % #styles + 1], true)
		bit.Size = Vector3.one * rng:NextNumber(0.12, 0.24)
		bit.CFrame = CFrame.new(position + normal * 0.3)
			* CFrame.Angles(rng:NextNumber(0, TAU), rng:NextNumber(0, TAU), 0)
		bit.Anchored = false
		bit.AssemblyLinearVelocity = normal * rng:NextNumber(8, 16) + rng:NextUnitVector() * 6 + UP * 3
		bit.AssemblyAngularVelocity = rng:NextUnitVector() * rng:NextNumber(6, 14)
		addLive(entry, 0, 0.7, 0.3, position.Z)
	end
end

-- position: where the ball hit. normal: the surface's normal there (toward the ball).
-- style: BallFx.impactStyle(skinId). big: a big pane or a mega ball (bigger splash).
function Shatter.skinBurst(position, normal, style, big)
	if not style then
		return
	end
	local now = os.clock()
	if now - lastSkinBurst < SKIN_BURST_INTERVAL then
		return
	end
	lastSkinBurst = now

	local scale = (if big then 1.6 else 1) * (if low then 0.4 else 1)
	if overBudget() then
		scale *= 0.5 -- lots of glass flying already
	end
	local up = if math.abs(normal.Y) > 0.9 then Vector3.xAxis else UP
	local facing = CFrame.lookAt(position, position + normal, up)

	local slot = nextEmitter(skinSparks)
	slot.holder.CFrame = facing
	if style.rainbow then
		local hue = rng:NextNumber()
		slot.emitter.Color = ColorSequence.new(Color3.fromHSV(hue, 0.75, 1), Color3.fromHSV((hue + 0.3) % 1, 0.75, 1))
	else
		slot.emitter.Color = ColorSequence.new(style.color, style.color2)
	end
	slot.emitter:Emit(math.max(3, math.floor(SKIN_BURST_COUNT * scale + 0.5)))

	if not style.premium then
		return
	end
	-- Animated balls (premium + earned): a bigger, themed splash on top.
	local sets, theme = themeSet(style.id)
	if sets then
		local themed = nextEmitter(sets.sparks)
		-- A shape emitter (the implosion sphere) sits a little out of the surface.
		themed.holder.CFrame = if theme.holderSize then facing + normal * theme.holderSize * 0.25 else facing
		themed.emitter:Emit(math.max(4, math.floor(theme.count * scale + 0.5)))
		if sets.flare and flashesOn and not low then
			local flare = nextEmitter(sets.flare)
			flare.holder.CFrame = CFrame.new(position + normal * 0.3)
			flare.emitter:Emit(if big then 2 else 1)
		end
		if theme.bits and BIT_SETS[theme.bits] then
			throwBits(position, normal, BIT_SETS[theme.bits])
		end
	elseif style.id == "CyberCore" then
		throwBits(position, normal, BIT_SETS.CyberCore)
	end
end

-- Knock-loose decorations ------------------------------------------------------
-- Solid decorations (kind "Wall", not part of the room shell) that a ball hits
-- come off their spot and tumble. They stop being hittable (CanQuery = false),
-- so balls fly through them and never get blocked from reaching glass. They
-- never count as hazards. After LOOSE_DECOR_SETTLE seconds, or when too many
-- are loose, they freeze where they lie. Deleting the room removes them.

local loose = {} -- knocked parts, oldest first
local looseTime = {} -- os.clock() each one was knocked

local function looseCap()
	return if low then Config.LOW_LOOSE_DECOR_MAX else Config.LOOSE_DECOR_MAX
end

local function freezeOldest()
	local part = table.remove(loose, 1)
	table.remove(looseTime, 1)
	if part.Parent then
		part.Anchored = true
		part.CanCollide = false
	end
end

-- Can a ball knock this part loose?
function Shatter.canKnock(part)
	if not part:IsA("BasePart") or not part.Anchored or not part.CanQuery then
		return false
	end
	if part:GetAttribute("Kind") ~= "Wall" or part:GetAttribute("Shell") then
		return false
	end
	local size = part.Size
	if math.max(size.X, size.Y, size.Z) > Config.LOOSE_DECOR_MAX_SIZE then
		return false
	end
	-- Parts carrying a room light or a zone name sign stay put.
	if part:FindFirstChildWhichIsA("Light") or part:FindFirstChildWhichIsA("SurfaceGui") then
		return false
	end
	return true
end

-- Knocks one part loose, flying along `direction` (a unit vector).
-- strength: 1 = normal ball, more = harder.
function Shatter.knockLoose(part, direction, strength)
	while #loose >= looseCap() do
		freezeOldest()
	end
	local track = Config.TRACK_ORIGIN
	-- Nudge it off the wall / floor it was touching so it doesn't start stuck inside.
	local position = part.Position
	local towardMiddle = Vector3.new(track.X - position.X, 0, 0)
	local nudge = UP * KNOCK_NUDGE
	if towardMiddle.Magnitude > 0.01 then
		nudge += towardMiddle.Unit * KNOCK_NUDGE
	end
	part.CFrame += nudge

	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false -- moving shadow casters are costly; it's moving fast anyway
	part.CanCollide = true
	if shardsGroup then
		part.CollisionGroup = shardsGroup
	end
	part.Anchored = false
	-- Small things fly, big things (a sign board, a bench top) mostly topple over,
	-- so nothing large sails across the view in front of the glass.
	local size = part.Size
	local heft = math.clamp(KNOCK_FULL_SIZE / math.max(size.X, size.Y, size.Z), 0.35, 1)
	local speed = Config.LOOSE_DECOR_SPEED * strength * heft * rng:NextNumber(0.75, 1.15)
	part.AssemblyLinearVelocity = direction * speed + UP * KNOCK_UP * rng:NextNumber(0.6, 1.4) + rng:NextUnitVector() * 2
	part.AssemblyAngularVelocity = rng:NextUnitVector() * KNOCK_SPIN * heft * rng:NextNumber(0.5, 1.5)

	table.insert(loose, part)
	table.insert(looseTime, os.clock())
end

-- Knocks loose every knockable part touching a sphere (mega ball, or a normal
-- ball splashing a decoration made of several parts). params: OverlapParams
-- limited to the track. Returns how many parts came loose.
function Shatter.knockAround(position, radius, direction, strength, params)
	local count = 0
	for _, part in workspace:GetPartBoundsInRadius(position, radius, params) do
		if Shatter.canKnock(part) then
			Shatter.knockLoose(part, direction, strength)
			count += 1
		end
	end
	return count
end

-- Per frame ----------------------------------------------------------------------

local nextBehindCheck = 0
local KINDS = { "Pair", "Wedge", "Chip" }

-- Makes a few pool pieces ahead of time (a little per frame).
local function warmPool()
	local deadline = os.clock() + WARM_BUDGET
	for _, kind in KINDS do
		local list = free[kind]
		while made[kind] < warmTarget(kind) and made[kind] < maxMade(kind) do
			table.insert(list, createEntry(kind))
			if os.clock() > deadline then
				return
			end
		end
	end
end

local warmDone = false

-- Call every frame with the camera's Z position.
function Shatter.update(cameraZ)
	processQueue()

	local now = os.clock()
	local releases = 0

	-- Fade out, then return to the pool.
	for index = #live, 1, -1 do
		local entry = live[index]
		if now >= entry.expires then
			if releases < RELEASES_PER_FRAME then
				releases += 1
				park(removeLive(index))
			end
		elseif now >= entry.fadeStart then
			local t = (now - entry.fadeStart) / (entry.expires - entry.fadeStart)
			local transparency = entry.baseT + (1 - entry.baseT) * t
			entry.a.Transparency = transparency
			if entry.b then
				entry.b.Transparency = transparency
			end
		end
	end

	-- Shards behind the camera: nobody can see them, recycle them now.
	if now >= nextBehindCheck then
		nextBehindCheck = now + BEHIND_CHECK_INTERVAL
		local limit = cameraZ + BEHIND_DISTANCE
		for index = #live, 1, -1 do
			if releases >= RELEASES_PER_FRAME then
				break
			end
			local entry = live[index]
			if entry.spawnZ > cameraZ and entry.a.Position.Z > limit then
				releases += 1
				park(removeLive(index))
			end
		end
	end

	-- Loose decorations that tumbled long enough freeze where they lie.
	while looseTime[1] and now - looseTime[1] > Config.LOOSE_DECOR_SETTLE do
		freezeOldest()
	end

	if not warmDone then
		warmPool()
		warmDone = made.Pair >= warmTarget("Pair") and made.Wedge >= WEDGE_WARM and made.Chip >= CHIP_WARM
	end
end

-- New run: everything back into the pool, nothing queued, no loose decorations
-- (those were deleted with the old run's world).
function Shatter.reset()
	for index = #live, 1, -1 do
		park(removeLive(index))
	end
	table.clear(queue)
	queueHead = 1
	queuedParts = 0
	table.clear(loose)
	table.clear(looseTime)
	warmDone = false
end

return Shatter
