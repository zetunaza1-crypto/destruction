--[[
	The ball in your hand.

	During a run the equipped ball sits big and close in the bottom-right corner
	of the view (bottom-left if the "leftHanded" setting is on), slowly turning so
	its details show and swaying a little when the camera kicks. It's a real 3D
	ball, lit by the zone's lights, placed relative to the camera every frame.
	When you throw, the ball flies from here (HeldBall.launch gives its spot) and
	a new one pops back in (POP_TIME) like a reload, so you see your skin again
	after every throw.

	Layout: the ball's spot is a fraction of the screen and its size a share of
	the screen height, so it stays put at any field of view (the view widens at
	speed) or screen shape. It always sits above the corner HUD button (Ball Pack
	on the right, Shield on the left). Short screens (phones) move it a bit
	further in and draw it a bit bigger.

	HeldBall.attach(folder)  -- the run's world folder (call after building a new one)
	HeldBall.setSkin(skinId)
	HeldBall.update(dt, show, mega, avoid, avoidRadius)
		Every frame, after the camera has moved. show = false hides it (menu,
		game over, no balls left). mega = MegaBall throws left (drawn bigger).
		avoid / avoidRadius: a spot on screen (viewport pixels) it must not cover,
		e.g. the tutorial's pointer ring; it hides while it would.
	HeldBall.launch() -> Vector3?
		The world position of the ball being thrown, or nil when none is showing.
		Starts the pop-back-in.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local BallFx = require(script.Parent.BallFx)
local Settings = require(script.Parent.Settings)

local HeldBall = {}

-- Look
local PLAIN_DIAMETER = 0.9 -- studs across (the depth is worked out from the screen share)
local PREMIUM_DIAMETER = 1.25 -- premium balls have rings / flares around the core
local PREMIUM_SHARE = 1.2 -- ...so they're drawn a little bigger to keep the core readable
local MEGA_SCALE = 1.3 -- MegaBall throws left: a bigger ball in your hand
local SPIN_RPS = 0.12 -- turns per second
local TILT = math.rad(20) -- tipped toward the camera so the top shows too
local POP_DELAY = 0.03 -- seconds the hand is empty after a throw...
local POP_TIME = 0.12 -- ...then the next ball grows back in this long
local MIN_SCALE = 0.02

-- Where on screen (center, as a fraction of the screen) and how big (diameter as
-- a share of the screen height).
local LAYOUT = {
	wide = { x = 0.8, y = 0.8, share = 0.2 },
	phone = { x = 0.72, y = 0.76, share = 0.24 }, -- short screens: further in, a bit bigger
}
local PHONE_HEIGHT = 600 -- viewport heights below this use the phone layout
local HIGHEST = 0.55 -- the ball's center never goes above this much of the screen height

-- Mirrors of UI.luau's HUD numbers (600x340 sheet, corner buttons 122x52, 12 from the edge)
-- so the ball always sits above the Ball Pack / Shield button.
local REF_W, REF_H = 600, 340
local SCALE_MIN, SCALE_MAX = 0.8, 2
local EDGE = 12
local CORNER_BUTTON = Vector2.new(122, 52)
local BUTTON_MARGIN = 10 -- pixels between the ball and the button

-- Sway
local BOB_X, BOB_Y = 0.004, 0.006 -- screen-height shares
local LAG = 1.4 -- screen-height share per radian the camera turns in a frame
local LAG_MAX = 0.04
local LAG_RETURN = 10
local MESH_CHECK = 1 -- seconds between "has the Blender model loaded yet?" checks

local folder = nil
local skinId = "Default"
local held = nil -- BallFx.held object
local heldLow = nil -- graphics level it was built for
local shown = false
local popStart = -math.huge -- os.clock() the current ball started popping in
local lastCenter = nil -- world position of the ball last frame (nil = not showing)
local lastRotation = nil
local lagX, lagY = 0, 0
local lastMeshCheck = 0
local failedSkin = nil -- a skin whose ball couldn't be built (not retried every frame)

local function graphicsLow()
	local ok, level = pcall(Settings.graphicsLevel)
	return ok and level == "Low"
end

local function destroyHeld()
	if held then
		held.destroy()
		held = nil
	end
	shown = false
	lastCenter = nil
end

local function build()
	destroyHeld()
	if not folder or folder.Parent == nil then
		return
	end
	local diameter = if BallFx.isPremium(skinId) then PREMIUM_DIAMETER else PLAIN_DIAMETER
	local ok, result = pcall(BallFx.held, skinId, diameter)
	if ok and result then
		held = result
		heldLow = graphicsLow()
		held.diameter = diameter
		held.share = if BallFx.isPremium(skinId) then PREMIUM_SHARE else 1
	else
		failedSkin = skinId
		warn("[HeldBall] could not build the ball:", result)
	end
end

local function hide()
	if held and shown then
		held.root.Parent = nil
	end
	shown = false
	lastCenter = nil
	lagX, lagY = 0, 0
end

function HeldBall.attach(newFolder)
	folder = newFolder
	destroyHeld() -- the old one went with the old world
end

function HeldBall.setSkin(newSkinId)
	newSkinId = Config.getSkin(newSkinId).Id
	if newSkinId ~= skinId then
		skinId = newSkinId
		failedSkin = nil
		destroyHeld()
	end
end

-- Screen spot (viewport pixels) and radius, kept above the corner button.
local function screenSpot(viewport, share, scale)
	local layout = if viewport.Y < PHONE_HEIGHT then LAYOUT.phone else LAYOUT.wide
	local leftHanded = Settings.get("leftHanded") == true
	local radius = layout.share * share * scale * viewport.Y / 2
	local x = (if leftHanded then 1 - layout.x else layout.x) * viewport.X
	local y = layout.y * viewport.Y

	local insetTop, insetBottom = GuiService:GetGuiInset()
	local safe = viewport - insetTop - insetBottom
	local sheet = math.clamp(math.min(safe.X / REF_W, safe.Y / REF_H), SCALE_MIN, SCALE_MAX)
	local button = CORNER_BUTTON * sheet
	local buttonTop = viewport.Y - insetBottom.Y - EDGE - button.Y - BUTTON_MARGIN
	local overlapsSideways
	if leftHanded then
		overlapsSideways = x - radius < insetTop.X + EDGE + button.X + BUTTON_MARGIN
	else
		overlapsSideways = x + radius > viewport.X - insetBottom.X - EDGE - button.X - BUTTON_MARGIN
	end
	if overlapsSideways then
		y = math.min(y, buttonTop - radius)
	end
	y = math.max(y, HIGHEST * viewport.Y)
	return x, y, radius, layout.share * share
end

function HeldBall.update(dt, show, mega, avoid, avoidRadius)
	if not show or not folder or folder.Parent == nil then
		hide()
		return
	end
	local now = os.clock()
	if (held == nil and failedSkin ~= skinId) or (held and heldLow ~= graphicsLow()) then
		build()
	elseif held and not held.mesh and BallFx.isPremium(skinId) and now - lastMeshCheck > MESH_CHECK then
		lastMeshCheck = now
		if BallFx.hasMesh(skinId) then
			build() -- the Blender model finished loading: swap the stand-in for it
		end
	end
	if held == nil then
		return
	end

	local camera = workspace.CurrentCamera
	local viewport = camera.ViewportSize
	if viewport.X < 1 or viewport.Y < 1 then
		hide()
		return
	end
	local megaScale = if mega then MEGA_SCALE else 1
	local x, y, radius, share = screenSpot(viewport, held.share, megaScale)

	-- The tutorial's pointer ring: never cover the thing it points at.
	if avoid and (Vector2.new(x, y) - avoid).Magnitude < radius + (avoidRadius or 0) + BUTTON_MARGIN then
		hide()
		return
	end

	if not shown then
		shown = true
		held.root.Parent = folder
		popStart = now -- grows in when it (re)appears
		lastRotation = nil
	end

	-- Sway: a slow bob, plus lagging behind when the camera kicks (throw recoil, crashes).
	local rotation = camera.CFrame.Rotation
	if lastRotation then
		local pitch, yaw = lastRotation:ToObjectSpace(rotation):ToEulerAnglesYXZ()
		lagX = math.clamp(lagX + yaw * LAG, -LAG_MAX, LAG_MAX)
		lagY = math.clamp(lagY + pitch * LAG, -LAG_MAX, LAG_MAX)
	end
	lastRotation = rotation
	local settle = math.exp(-LAG_RETURN * dt)
	lagX *= settle
	lagY *= settle
	x += (lagX - math.sin(now * 0.7) * BOB_X) * viewport.Y
	y += (lagY + math.sin(now * 1.3) * BOB_Y) * viewport.Y

	-- Pop-in: quick overshoot, like it's been caught.
	local scale = megaScale
	local popT = (now - popStart - POP_DELAY) / POP_TIME
	if popT < 1 then
		if popT <= 0 then
			scale = MIN_SCALE
		else
			local back = 1 + 2.2 * (popT - 1) ^ 3 + 1.2 * (popT - 1) ^ 2 -- ease-out-back
			scale = math.max(MIN_SCALE, back * megaScale)
		end
	end

	-- Same size on screen at any field of view: the depth follows the FOV.
	local tanY = math.tan(math.rad(camera.FieldOfView) / 2)
	local depth = held.diameter / (2 * share * tanY)
	local ndcX = x / viewport.X * 2 - 1
	local ndcY = 1 - y / viewport.Y * 2
	local offset = Vector3.new(ndcX * tanY * viewport.X / viewport.Y * depth, ndcY * tanY * depth, -depth)
	local center = camera.CFrame * offset
	local turn = rotation * CFrame.Angles(TILT, now * SPIN_RPS * math.pi * 2, 0)
	held.place(CFrame.new(center) * turn, scale, now)
	lastCenter = center
	held.radius = radius
end

function HeldBall.launch()
	if not shown or lastCenter == nil then
		return nil
	end
	local position = lastCenter
	popStart = os.clock() -- empty hand for a moment, then the next ball grows in
	return position
end

return HeldBall
