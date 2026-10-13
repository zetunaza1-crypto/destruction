--[[
	Breaking effects.

	Glass panes crack outward from the point the ball hit: cracks run from the
	impact to the edges, a ring of cracks crosses them, and every piece in between
	becomes a real triangle shard. Shards near the impact blast away, the rest
	drop and tumble, bounce off the floor and sparkle.

	Shatter.shieldBreak is the burst shown when a Shield boost absorbs a crash.

	Shard budget: every shard is a physics part, and phones slow down when too
	many are flying at once. We count the live ones; above Config.MAX_LIVE_SHARDS
	new breaks use fewer cracks, only the small pieces around the impact and no
	glitter. Only those inner pieces bounce off things (CanCollide); the big outer
	pieces just fall, which is much cheaper for the physics engine.

	Shatter.glass / Shatter.prop take an optional shatter effect (an entry of
	Config.ShatterFx) that tints the shards. nil or "Classic" = normal glass.

	Low graphics (Settings): half the shard budget, fewer cracks per pane,
	fewer prop pieces and no glitter at all. Applies to the next break.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Settings = require(script.Parent.Settings)

local Shatter = {}

local rng = Random.new()
local TAU = math.pi * 2
local GRAVITY_BOOST = Vector3.new(0, -12, 0) -- shards look heavier with a small downward kick
local SMALL_PANE_AREA = 20 -- panes smaller than this (square studs) use few cracks
local FEW_RAYS = 5
local LOW_MAX_RAYS = 7 -- Low graphics: at most this many cracks per pane
local LOW_PROP_PIECES = 5 -- Low graphics: at most this many shards per prop part

-- Low graphics (kept up to date when the setting changes).
local low = Settings.graphicsLevel() == "Low"
Settings.changed:Connect(function(key)
	if key == "graphics" then
		low = Settings.graphicsLevel() == "Low"
	end
end)

-- Shard budget ------------------------------------------------------------------

-- Live shard parts, as batches { expires = os.clock() time, count = parts }.
local liveBatches = {}
local liveCount = 0

local function liveShards()
	local now = os.clock()
	for i = #liveBatches, 1, -1 do
		local batch = liveBatches[i]
		if batch.expires <= now then
			liveCount -= batch.count
			table.remove(liveBatches, i)
		end
	end
	return liveCount
end

local function addLive(count, lifetime)
	if count > 0 then
		liveCount += count
		table.insert(liveBatches, { expires = os.clock() + lifetime, count = count })
	end
end

local function overBudget()
	local budget = if low then Config.MAX_LIVE_SHARDS // 2 else Config.MAX_LIVE_SHARDS
	return liveShards() >= budget
end

-- Effects -------------------------------------------------------------------

-- A short burst of glitter at the impact point.
local function sparkle(position, color, amount, parent)
	if low then
		return -- Low graphics: no glitter
	end
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one * 0.2
	holder.CFrame = CFrame.new(position)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.5))
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
	emitter.Parent = holder

	holder.Parent = parent
	emitter:Emit(amount)
	Debris:AddItem(holder, 1.2)
end

local function makePiece(className, template)
	local piece = Instance.new(className)
	piece.Material = template.Material
	piece.Color = template.Color
	piece.Transparency = template.Transparency
	piece.Reflectance = template.Reflectance
	piece.CastShadow = false
	piece.CanQuery = false
	piece.CanTouch = false
	piece.CanCollide = true -- bounce off the floor and walls
	piece.TopSurface = Enum.SurfaceType.Smooth
	piece.BottomSurface = Enum.SurfaceType.Smooth
	return piece
end

-- Shatter effects -----------------------------------------------------------

local function hasFx(fx)
	return fx ~= nil and fx.Id ~= "Classic"
end

-- The look of one shard: a plain table makePiece can read like a Part.
-- Rainbow effects get a new random hue for every shard.
local function styledTemplate(template, fx)
	if not hasFx(fx) then
		return template
	end
	local style = {
		Material = template.Material,
		Color = template.Color,
		Transparency = template.Transparency,
		Reflectance = template.Reflectance,
	}
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

local function launch(part, center, hitPoint, push, reach)
	local away = center - hitPoint
	local distance = away.Magnitude
	local closeness = math.clamp(1 - distance / reach, 0, 1)
	local direction = if distance > 0.01 then away.Unit else rng:NextUnitVector()

	part.AssemblyLinearVelocity = push * (6 + 40 * closeness ^ 1.5)
		+ direction * (3 + 18 * closeness)
		+ rng:NextUnitVector() * 2
		+ GRAVITY_BOOST
	part.AssemblyAngularVelocity = rng:NextUnitVector() * rng:NextNumber(2, 6 + 12 * closeness)
end

-- Triangles ----------------------------------------------------------------

-- Builds a flat triangle a-b-c out of two wedge parts welded together.
-- Returns the root wedge (move/launch that one) or nil for a sliver too thin to draw.
-- collide = false: the piece falls through everything (cheaper physics).
local function triangle(a, b, c, thickness, template, parent, collide)
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

	local first = makePiece("WedgePart", template)
	first.CanCollide = collide
	first.Size = Vector3.new(thickness, height, math.abs(ab:Dot(back)))
	first.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)

	local second = makePiece("WedgePart", template)
	second.CanCollide = collide
	second.Size = Vector3.new(thickness, height, math.abs(ac:Dot(back)))
	second.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = first
	weld.Part1 = second
	weld.Parent = first

	-- Parented to the first half so both are cleaned up together.
	second.Parent = first
	first.Parent = parent
	return first
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
-- pane, in the pane's local X/Y plane, with the impact point p.
-- innerOnly = true: just the small fan around the impact (shard budget).
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
	for i = 1, rays do
		local j = i % rays + 1
		local a1, a2 = angles[i], angles[j]
		local span = (a2 - a1) % TAU

		-- Inner fan: the small, fast pieces around the impact.
		table.insert(triangles, { p, rings[i], rings[j], inner = true })
		if innerOnly then
			continue
		end

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

function Shatter.glass(panel, hitPoint, push, parent, fx)
	local size = panel.Size
	local cf = panel.CFrame
	local hx, hy = size.X / 2, size.Y / 2
	local thickness = math.min(size.Z, 0.4)

	-- Impact point in the pane's own 2D space (clamped just inside the edges).
	local localHit = cf:PointToObjectSpace(hitPoint)
	local p = Vector2.new(math.clamp(localHit.X, -hx * 0.95, hx * 0.95), math.clamp(localHit.Y, -hy * 0.95, hy * 0.95))

	-- Bigger panes get a few more cracks, small ones (grid tiles) only a few.
	-- Too many shards already flying: few cracks, inner pieces only, no glitter.
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

	local made = 0
	for _, tri in crackPattern(p, hx, hy, rays, busy) do
		local a = cf * Vector3.new(tri[1].X, tri[1].Y, 0)
		local b = cf * Vector3.new(tri[2].X, tri[2].Y, 0)
		local c = cf * Vector3.new(tri[3].X, tri[3].Y, 0)
		local shard = triangle(a, b, c, thickness, styledTemplate(panel, fx), parent, tri.inner == true)
		if shard then
			launch(shard, (a + b + c) / 3, worldHit, push, reach)
			Debris:AddItem(shard, Config.SHARD_LIFETIME + rng:NextNumber(0, 0.6))
			made += 2 -- two wedges per triangle
		end
	end
	addLive(made, Config.SHARD_LIFETIME + 0.6)

	if not busy then
		local sparkleColor, sparkleAmount = sparkleStyle(panel.Color, 25, fx)
		sparkle(worldHit, sparkleColor, sparkleAmount, parent)
	end
	panel:Destroy()
end

-- Breakable decorations (vases, bottles, lamps...). Each part bursts into
-- small random shards. Hitting any part of a breakable Model breaks all of it.
function Shatter.prop(part, hitPoint, push, parent, fx)
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
	local made = 0
	for _, piece in pieces do
		local size = piece.Size
		local volume = size.X * size.Y * size.Z
		local most = if busy then 3 elseif low then LOW_PROP_PIECES else 10
		local count = math.clamp(math.floor(volume / 1.5), 3, most)
		local reach = math.max(size.X, size.Y, size.Z) * 2
		for _ = 1, count do
			local shard = makePiece("WedgePart", styledTemplate(piece, fx))
			shard.Size = Vector3.new(
				math.max(0.1, size.X * rng:NextNumber(0.15, 0.4)),
				math.max(0.1, size.Y * rng:NextNumber(0.15, 0.4)),
				math.max(0.1, size.Z * rng:NextNumber(0.1, 0.3))
			)
			local offset = Vector3.new(
				rng:NextNumber(-0.5, 0.5) * size.X,
				rng:NextNumber(-0.5, 0.5) * size.Y,
				rng:NextNumber(-0.5, 0.5) * size.Z
			)
			shard.CFrame = piece.CFrame * CFrame.new(offset) * CFrame.Angles(
				rng:NextNumber(0, TAU),
				rng:NextNumber(0, TAU),
				rng:NextNumber(0, TAU)
			)
			shard.Parent = parent
			launch(shard, shard.Position, hitPoint, push * 0.5, reach)
			Debris:AddItem(shard, Config.SHARD_LIFETIME + rng:NextNumber(0, 0.6))
			made += 1
		end
		if not busy then
			local sparkleColor, sparkleAmount = sparkleStyle(piece.Color, 10, fx)
			sparkle(piece.Position, sparkleColor, sparkleAmount, parent)
		end
	end
	addLive(made, Config.SHARD_LIFETIME + 0.6)

	root:Destroy()
end

-- Shield boost breaking: a ring of glowing shards bursts outward around the
-- player's view. cameraCFrame = where the camera is, carry = the camera's
-- velocity (so the burst travels along instead of being left behind).
local SHIELD_SHARDS = 16
local SHIELD_DISTANCE = 3.5
local SHIELD_RADIUS = 2.6

function Shatter.shieldBreak(cameraCFrame, color, parent, carry)
	local style = {
		Material = Enum.Material.Neon,
		Color = color,
		Transparency = 0.25,
		Reflectance = 0,
	}
	local center = cameraCFrame * Vector3.new(0, 0, -SHIELD_DISTANCE)
	for i = 1, SHIELD_SHARDS do
		local angle = (i / SHIELD_SHARDS) * TAU + rng:NextNumber(-0.15, 0.15)
		local outward = cameraCFrame:VectorToWorldSpace(Vector3.new(math.cos(angle), math.sin(angle), 0))
		local shard = makePiece("WedgePart", style)
		shard.CanCollide = false
		shard.Size = Vector3.new(0.08, rng:NextNumber(0.4, 0.9), rng:NextNumber(0.3, 0.7))
		shard.CFrame = CFrame.lookAt(center + outward * SHIELD_RADIUS, center + outward * (SHIELD_RADIUS + 1))
			* CFrame.Angles(0, 0, rng:NextNumber(0, TAU))
		shard.Parent = parent
		shard.AssemblyLinearVelocity = carry + outward * rng:NextNumber(14, 24)
		shard.AssemblyAngularVelocity = rng:NextUnitVector() * rng:NextNumber(4, 10)
		Debris:AddItem(shard, 0.7)
	end
	sparkle(center, color, 30, parent)
end

function Shatter.crystal(crystal, parent)
	crystal.CanQuery = false

	-- A pop of glowing chips plus the crystal shrinking away.
	for _ = 1, 6 do
		local chip = makePiece("Part", crystal)
		chip.CanCollide = false
		chip.Size = Vector3.one * rng:NextNumber(0.2, 0.45)
		chip.CFrame = crystal.CFrame * CFrame.Angles(rng:NextNumber(0, TAU), rng:NextNumber(0, TAU), 0)
		chip.Parent = parent
		chip.AssemblyLinearVelocity = rng:NextUnitVector() * rng:NextNumber(10, 20)
		Debris:AddItem(chip, 0.6)
	end
	sparkle(crystal.Position, crystal.Color, 18, parent)

	local tween = TweenService:Create(crystal, TweenInfo.new(0.25), {
		Size = Vector3.zero,
		Transparency = 1,
	})
	tween.Completed:Connect(function()
		crystal:Destroy()
	end)
	tween:Play()
end

return Shatter
