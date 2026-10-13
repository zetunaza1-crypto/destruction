--[[
	A ball held in one hand.

	Viewmodel.luau owns two of these (one per hand) and tells each one where to
	be every frame. This file only deals with the ball itself: building the
	equipped skin's look (BallFx.held, animated premium / earned balls included), swapping in the
	Blender model once it has loaded, rebuilding when the graphics setting
	changes, and drawing it at a given spot and size.

	It's a real 3D ball, lit by the zone's lights, placed relative to the camera
	every frame.

	local ball = HeldBall.new(particleShare)
		particleShare = { High = number, Low = number }: animated balls' particle
		rate for this ball at each graphics level (two hands = two balls, so each
		sparkles a bit less to keep phones smooth).
	ball.attach(folder)        -- the run's world folder (call after building a new one)
	ball.setSkin(skinId)
	ball.draw(cframe, scale, now)
		Draws the ball centered on cframe (which also turns it). scale 1 = the
		normal held size (HeldBall.DIAMETER across for plain balls, a bit more
		for animated ones). scale <= 0 hides it.
	ball.hide()
	ball.radius() -> studs     -- drawn radius at scale 1
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local BallFx = require(script.Parent.BallFx)
local Settings = require(script.Parent.Settings)

local HeldBall = {}

-- Look
HeldBall.DIAMETER = 0.9 -- studs across for a plain ball (the arms are sized around this)
local PREMIUM_DIAMETER = 1.25 -- animated (premium + earned) balls have rings / flares around the core
local PREMIUM_SHARE = 1.2 -- ...so they're drawn a little bigger to keep the core readable
local MIN_SCALE = 0.02 -- smaller than this = hidden
local MESH_CHECK = 1 -- seconds between "has the Blender model loaded yet?" checks

local function graphicsLow()
	local ok, level = pcall(Settings.graphicsLevel)
	return ok and level == "Low"
end

function HeldBall.new(particleShare)
	local ball = {}

	local folder = nil
	local skinId = "Default"
	local held = nil -- BallFx.held object
	local heldLow = nil -- graphics level it was built for
	local shown = false
	local lastMeshCheck = 0
	local failedSkin = nil -- a skin whose ball couldn't be built (not retried every frame)
	local meshTried = false -- already rebuilt once for the loaded Blender model (don't loop if it still fails)

	local function destroyHeld()
		if held then
			held.destroy()
			held = nil
		end
		shown = false
	end

	local function build()
		destroyHeld()
		if not folder or folder.Parent == nil then
			return
		end
		local animated = BallFx.isAnimated(skinId)
		local diameter = if animated then PREMIUM_DIAMETER else HeldBall.DIAMETER
		local low = graphicsLow()
		local particleScale = if particleShare then particleShare[if low then "Low" else "High"] else 1
		local ok, result = pcall(BallFx.held, skinId, diameter, particleScale)
		if ok and result then
			held = result
			heldLow = low
			held.diameter = diameter
			held.share = if animated then PREMIUM_SHARE else 1
		else
			failedSkin = skinId
			warn("[HeldBall] could not build the ball:", result)
		end
	end

	function ball.hide()
		if held and shown then
			held.root.Parent = nil
		end
		shown = false
	end

	function ball.attach(newFolder)
		folder = newFolder
		destroyHeld() -- the old one went with the old world
	end

	function ball.setSkin(newSkinId)
		newSkinId = Config.getSkin(newSkinId).Id
		if newSkinId ~= skinId then
			skinId = newSkinId
			failedSkin = nil
			meshTried = false
			destroyHeld()
		end
	end

	function ball.radius()
		local share = if BallFx.isAnimated(skinId) then PREMIUM_SHARE else 1
		return HeldBall.DIAMETER * share / 2
	end

	function ball.draw(cframe, scale, now)
		if scale <= MIN_SCALE or not folder or folder.Parent == nil then
			ball.hide()
			return
		end
		if (held == nil and failedSkin ~= skinId) or (held and heldLow ~= graphicsLow()) then
			build()
		elseif held and not held.mesh and not meshTried and BallFx.isAnimated(skinId) and now - lastMeshCheck > MESH_CHECK then
			lastMeshCheck = now
			if BallFx.hasMesh(skinId) then
				meshTried = true -- one try: if the model still can't be used, keep the stand-in
				build() -- the Blender model finished loading: swap the stand-in for it
			end
		end
		if held == nil then
			return
		end
		if not shown then
			shown = true
			held.root.Parent = folder
		end
		-- scale 1 = HeldBall.DIAMETER (x the animated-ball share) across.
		local size = scale * HeldBall.DIAMETER * held.share / held.diameter
		held.place(cframe, size, now)
	end

	return ball
end

return HeldBall
