--[[
	Your arms in first person, each holding a ball.

	During a run your avatar's arms (the cleaned-up copy the server builds, see
	Server/ViewmodelRigs.server.luau) come up from the bottom-left and
	bottom-right of the view, each holding the equipped ball (HeldBall.luau).
	Throws alternate right, left, right, left: the throwing arm does a quick
	overhand throw, the ball flies from that hand, and the hand instantly grabs a
	new ball from the pocket (a quick dip, and the ball pops in).

	Balls in hand follow your ball count:
	  2 or more  both hands hold a ball
	  1          only the hand that throws next holds one
	  0          both hands are empty

	Layout: like the old single ball, each hand's ball sits at a fraction of the
	screen and its size is a share of the screen height, so the arms look the
	same on a phone, a PC or a TV at any field of view (the view widens at speed).
	The balls stay above the corner HUD buttons (Ball Pack right, Shield left).
	The arms are 3D parts, so the HUD is always drawn on top of them.

	Feel: a gentle running bob (the arms go up and down in turn, faster at
	higher speed) and a little sway when the camera kicks or shakes. Both are off
	when the player turns camera shake off in Settings.

	Viewmodel.start()           -- once: starts waiting for this player's arms
	Viewmodel.attach(folder)    -- the run's world folder (the balls live there)
	Viewmodel.setSkin(skinId)
	Viewmodel.update(dt, view)  -- every frame, after the camera has moved
		view = {
			show = bool,          -- false in the menu / game over
			balls = number,       -- balls left
			mega = bool,          -- MegaBall throws left (balls drawn bigger)
			avoid = Vector2?,     -- the tutorial pointer ring (viewport pixels)...
			avoidRadius = number?, -- ...a hand hides while it would cover it
			speedShare = number,  -- 0 at the start speed .. 1 at top speed
			worldRate = number,   -- how fast the world runs (slow-mo, hit-stop, frozen = 0)
		}
	Viewmodel.launch(both) -> firstSpot, secondSpot, firstSide, bothThrew
		Throws from the hand whose turn it is (and the other hand too when
		`both`, i.e. multiball, and it has a ball). The spots are the world
		positions of the thrown balls (nil = that hand isn't showing: throw from
		the middle of the view). firstSide: 1 = right hand, -1 = left hand.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ViewmodelRig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ViewmodelRig"))
local HeldBall = require(script.Parent.HeldBall)
local Settings = require(script.Parent.Settings)
local Sounds = require(script.Parent.Sounds)

local player = Players.LocalPlayer

local Viewmodel = {}

-- Arms (camera space: +X right, +Y up, -Z forward; numbers are for the right arm, the left one is mirrored)
local ARM_SCALE = 0.75 -- the R6 arm (1 x 2 x 1) is scaled to this: 0.75 wide, 1.5 long
local ARM_LENGTH = 2 * ARM_SCALE
local SHOULDER_DIRECTION = Vector3.new(0.1, -0.8, 0.6).Unit -- from the hand back to the shoulder: down, toward you, a bit outward
local BALL_FORWARD = 0.4 -- the ball sits this many ball-radii past the fingertips...
local BALL_UP = 1.0 -- ...and this many above the middle of the arm (resting in the hand)
local UP = Vector3.yAxis
local REST_FRONT = (UP - SHOULDER_DIRECTION * UP:Dot(SHOULDER_DIRECTION)).Unit -- the top of the arm at rest

-- Where each hand's ball sits on screen (center, as a fraction of the screen,
-- right hand; the left one is mirrored) and how big it is (diameter as a share
-- of the screen height). The arms are sized to match the ball.
local LAYOUT = {
	wide = { x = 0.78, y = 0.74, share = 0.2 },
	phone = { x = 0.72, y = 0.7, share = 0.24 }, -- short screens: further in, a bit bigger
}
local PHONE_HEIGHT = 600 -- viewport heights below this use the phone layout
local HIGHEST = 0.55 -- a ball's center never goes above this much of the screen height

-- Mirrors of UI.luau's HUD numbers (600x340 sheet, corner buttons 122x52, 12 from the edge)
-- so the balls always sit above the Ball Pack / Shield buttons.
local REF_W, REF_H = 600, 340
local SCALE_MIN, SCALE_MAX = 0.8, 2
local EDGE = 12
local CORNER_BUTTON = Vector2.new(122, 52)
local BUTTON_MARGIN = 10 -- pixels between a ball and the button / tutorial ring

-- Ball look
local MEGA_SCALE = 1.3 -- MegaBall throws left: bigger balls in your hands
local SPIN_RPS = 0.12 -- turns per second
local TILT = math.rad(20) -- tipped toward the camera so the top shows too
local PARTICLE_SHARE = { High = 0.7, Low = 0.5 } -- premium sparkles per hand (two balls on screen)

-- Throw (seconds). pitch: + = hand up and back, - = forward and down (radians,
-- around the shoulder). yaw: + = toward the middle. push: the arm slides along
-- itself (share of its length).
local WIND_TIME = 0.04
local SNAP_TIME = 0.08
local RETURN_TIME = 0.12
local WIND_POSE = { pitch = 0.35, yaw = -0.05, push = -0.1 }
local SNAP_POSE = { pitch = -0.35, yaw = 0.2, push = 0.1 }

-- Reload "from the pocket": once the snap is done the hand dips and a new ball pops in.
local RELOAD_AT = WIND_TIME + SNAP_TIME
local DIP_TIME = 0.05 -- the hand dips this long, then...
local POP_TIME = 0.06 -- ...the new ball grows in this long (while the hand comes back up)
local DIP_DEPTH = 0.07 -- screen-height share the hand dips
local DIP_OUT = 0.02 -- ...and moves out toward the pocket
local DIP_TWIST = 0.3 -- radians the hand flicks down
local DROP_TIME = 0.06 -- a ball put away (fewer balls than hands) shrinks this fast

-- Feel (screen-height shares; only while camera shake is on)
local BOB_STEPS = 1.6 -- running steps per second at the start speed...
local BOB_STEPS_FAST = 2.6 -- ...and at top speed
local BOB_Y = 0.008 -- each arm goes up and down this much, in turn
local BOB_X = 0.003 -- the body sways sideways this much
local LAG = 1.4 -- per radian the camera turns in a frame (throw recoil, crash kick)
local SHAKE_LAG = 0.05 -- per stud the camera jumps sideways (crash shake)
local LAG_MAX = 0.04
local LAG_RETURN = 10

-- Arms model
local RIG_WAIT = 10 -- seconds per wait for the server's rig folder (keeps waiting in the background)

local runFolder = nil
local model = nil -- this player's arms (a clone, parented to the camera)
local rigDirty = true -- rebuild the arms from the newest template
local rigFailed = false
local shakeOn = Settings.get("shake") ~= false
local bobPhase = 0
local lagX, lagY = 0, 0
local lastCamera = nil
local armParts = {} -- BulkMoveTo list: { right arm, left arm }
local armCFrames = {}

local function newHand(side)
	return {
		side = side, -- 1 = right, -1 = left
		ball = HeldBall.new(PARTICLE_SHARE),
		arm = nil, -- arm part in the current model
		visible = false, -- drawn this frame (false while it would cover the tutorial ring)
		wanted = false, -- the ball count says this hand holds a ball
		loaded = false, -- a ball is in the hand (or popping in)
		thrownAt = -math.huge, -- os.clock() of its last throw
		dipAt = -math.huge, -- the reload flick started
		dropAt = -math.huge, -- a ball was put away
		ballPosition = nil, -- world position of its ball last frame
		armVisible = false,
	}
end

local right = newHand(1)
local left = newHand(-1)
local hands = { right, left }

local function firstHand()
	return if Settings.get("leftHanded") == true then left else right
end
local nextHand = firstHand()

local function otherHand(hand)
	return if hand == right then left else right
end

Settings.changed:Connect(function(key, value)
	if key == "shake" then
		shakeOn = value ~= false
		if not shakeOn then
			lagX, lagY = 0, 0
		end
	end
end)

-- Arms model ----------------------------------------------------------------------

local function findTemplate()
	local folder = ReplicatedStorage:FindFirstChild(ViewmodelRig.FOLDER_NAME)
	local template = folder and folder:FindFirstChild(tostring(player.UserId))
	return if template and template:IsA("Model") then template else nil
end

local function destroyModel()
	if model then
		model:Destroy()
		model = nil
	end
	right.arm, left.arm = nil, nil
	right.armVisible, left.armVisible = false, false
	table.clear(armParts)
end

local function setArmVisible(hand, visible)
	if hand.arm and hand.armVisible ~= visible then
		hand.armVisible = visible
		hand.arm.Transparency = if visible then 0 else 1
	end
end

-- Always the same size of arm, whatever the template says.
local function normalizeArms(newModel, rightArm, leftArm)
	local factor = ARM_LENGTH / math.max(rightArm.Size.Y, 0.01)
	if math.abs(factor - 1) > 1e-3 then
		local ok = pcall(function()
			newModel:ScaleTo(newModel:GetScale() * factor)
		end)
		if not ok then
			rightArm.Size *= factor
			leftArm.Size *= factor
		end
	end
	local size = ViewmodelRig.ARM_SIZE * ARM_SCALE
	for _, arm in { rightArm, leftArm } do
		if (arm.Size - size).Magnitude > 0.01 then
			arm.Size = size
		end
	end
end

local function makeModel()
	local newModel = nil
	local template = findTemplate()
	if template then
		local ok, clone = pcall(template.Clone, template)
		if ok and clone then
			newModel = clone
		end
	end
	-- Checked again here: only arms, Humanoid, Shirt and Body Colors stay.
	if newModel and not ViewmodelRig.strip(newModel) then
		newModel:Destroy()
		newModel = nil
	end
	if not newModel then
		newModel = ViewmodelRig.buildDefault("Viewmodel")
		ViewmodelRig.strip(newModel)
	end
	newModel.Name = "Viewmodel"
	local rightArm = newModel:FindFirstChild("Right Arm")
	local leftArm = newModel:FindFirstChild("Left Arm")
	normalizeArms(newModel, rightArm, leftArm)
	for _, arm in { rightArm, leftArm } do
		ViewmodelRig.quietPart(arm)
		arm.Transparency = 1 -- shown by update
	end
	-- The camera keeps it between runs (the run's world folder is rebuilt every run),
	-- and the Humanoid inside lets the classic Shirt show on the arms.
	newModel.Parent = workspace.CurrentCamera
	return newModel, rightArm, leftArm
end

local function buildModel()
	destroyModel()
	rigDirty = false
	local ok, newModel, rightArm, leftArm = pcall(makeModel)
	if not ok then
		rigFailed = true
		warn("[Viewmodel] could not build the arms:", newModel)
		return
	end
	rigFailed = false
	model = newModel
	right.arm, left.arm = rightArm, leftArm
	armParts[1], armParts[2] = rightArm, leftArm
end

-- Layout --------------------------------------------------------------------------

-- The right hand's ball: screen spot (viewport pixels) and size share, kept
-- above the corner button. The left hand's is the mirror image.
local function screenSpot(viewport)
	local layout = if viewport.Y < PHONE_HEIGHT then LAYOUT.phone else LAYOUT.wide
	local radius = layout.share * viewport.Y / 2
	local x = layout.x * viewport.X
	local y = layout.y * viewport.Y

	local insetTop, insetBottom = GuiService:GetGuiInset()
	local safe = viewport - insetTop - insetBottom
	local sheet = math.clamp(math.min(safe.X / REF_W, safe.Y / REF_H), SCALE_MIN, SCALE_MAX)
	local button = CORNER_BUTTON * sheet
	local buttonTop = viewport.Y - insetBottom.Y - EDGE - button.Y - BUTTON_MARGIN
	if x + radius > viewport.X - insetBottom.X - EDGE - button.X - BUTTON_MARGIN then
		y = math.min(y, buttonTop - radius)
	end
	y = math.max(y, HIGHEST * viewport.Y)
	return x, y, layout.share
end

-- Viewport pixels -> a camera-space point `depth` studs in front.
local function cameraPoint(x, y, depth, viewport, tanY)
	local ndcX = x / viewport.X * 2 - 1
	local ndcY = 1 - y / viewport.Y * 2
	return Vector3.new(ndcX * tanY * viewport.X / viewport.Y * depth, ndcY * tanY * depth, -depth)
end

-- Camera-space point -> viewport pixels (nil if it's behind the camera).
local function screenPoint(point, viewport, tanY)
	local depth = -point.Z
	if depth < 0.05 then
		return nil
	end
	local aspect = viewport.X / viewport.Y
	return Vector2.new(
		(0.5 + 0.5 * point.X / (depth * tanY * aspect)) * viewport.X,
		(0.5 - 0.5 * point.Y / (depth * tanY)) * viewport.Y
	)
end

local function distanceToSegment(point, a, b)
	local ab = b - a
	local lengthSquared = ab:Dot(ab)
	local t = if lengthSquared > 0 then math.clamp((point - a):Dot(ab) / lengthSquared, 0, 1) else 0
	return (point - (a + ab * t)).Magnitude
end

local function mirror(v)
	return Vector3.new(-v.X, v.Y, v.Z)
end

local function ease(t)
	return 1 - (1 - t) * (1 - t)
end

-- The throwing arm's pose t seconds after the throw: pitch, yaw, push.
local function throwPose(t)
	local from, to, k
	if t >= WIND_TIME + SNAP_TIME + RETURN_TIME or t < 0 then
		return 0, 0, 0
	elseif t < WIND_TIME then
		from, to, k = nil, WIND_POSE, ease(t / WIND_TIME)
	elseif t < WIND_TIME + SNAP_TIME then
		from, to, k = WIND_POSE, SNAP_POSE, ease((t - WIND_TIME) / SNAP_TIME)
	else
		from, to, k = SNAP_POSE, nil, ease((t - WIND_TIME - SNAP_TIME) / RETURN_TIME)
	end
	local fromPitch = if from then from.pitch else 0
	local fromYaw = if from then from.yaw else 0
	local fromPush = if from then from.push else 0
	local toPitch = if to then to.pitch else 0
	local toYaw = if to then to.yaw else 0
	local toPush = if to then to.push else 0
	return fromPitch + (toPitch - fromPitch) * k, fromYaw + (toYaw - fromYaw) * k, fromPush + (toPush - fromPush) * k
end

-- 0..1: how far down the reload flick is (down and back up again).
local function dipAmount(hand, now)
	local t = (now - hand.dipAt) / (DIP_TIME + POP_TIME)
	if t <= 0 or t >= 1 then
		return 0
	end
	return math.sin(t * math.pi)
end

-- How big the hand's ball is drawn (0 = empty hand).
local function ballScale(hand, now)
	if hand.loaded then
		local t = (now - hand.dipAt - DIP_TIME) / POP_TIME
		if t <= 0 then
			return 0
		elseif t >= 1 then
			return 1
		end
		return math.max(0, 1 + 2.2 * (t - 1) ^ 3 + 1.2 * (t - 1) ^ 2) -- ease-out-back: a little overshoot, like a catch
	end
	local t = (now - hand.dropAt) / DROP_TIME
	return if t < 1 then 1 - t else 0
end

-- Public ----------------------------------------------------------------------------

local function hideAll()
	for _, hand in hands do
		hand.ball.hide()
		setArmVisible(hand, false)
		hand.visible = false
		hand.wanted = false
		hand.loaded = false
		hand.thrownAt = -math.huge
		hand.dipAt = -math.huge
		hand.dropAt = -math.huge
		hand.ballPosition = nil
	end
	nextHand = firstHand()
	lastCamera = nil
	lagX, lagY = 0, 0
end

function Viewmodel.start()
	-- The server builds the arms a moment after joining (it has to load the
	-- avatar). Until they arrive, plain default arms are used; when they
	-- arrive (even mid-run) they're swapped in.
	task.spawn(function()
		local folder = nil
		while not folder do
			folder = ReplicatedStorage:WaitForChild(ViewmodelRig.FOLDER_NAME, RIG_WAIT)
		end
		local myName = tostring(player.UserId)
		folder.ChildAdded:Connect(function(child)
			if child.Name == myName then
				rigDirty = true
			end
		end)
		if folder:FindFirstChild(myName) then
			rigDirty = true
		end
	end)
end

function Viewmodel.attach(folder)
	runFolder = folder
	for _, hand in hands do
		hand.ball.attach(folder)
	end
end

function Viewmodel.setSkin(skinId)
	for _, hand in hands do
		hand.ball.setSkin(skinId)
	end
end

function Viewmodel.update(dt, view)
	if not view.show or not runFolder or runFolder.Parent == nil then
		hideAll()
		return
	end
	if rigDirty or (model and model.Parent ~= workspace.CurrentCamera) or (model == nil and not rigFailed) then
		buildModel()
	end

	local camera = workspace.CurrentCamera
	local viewport = camera.ViewportSize
	if viewport.X < 1 or viewport.Y < 1 then
		hideAll()
		return
	end
	local now = os.clock()
	local tanY = math.tan(math.rad(camera.FieldOfView) / 2)
	local spotX, spotY, share = screenSpot(viewport)
	-- Same size on screen at any field of view: the depth follows the FOV.
	local depth = HeldBall.DIAMETER / (2 * share * tanY)
	local studsPerScreen = 2 * depth * tanY -- studs per screen height at that depth
	local cameraCFrame = camera.CFrame

	-- Feel: running bob + lag behind camera kicks and shakes (only with shake on).
	if shakeOn then
		local steps = BOB_STEPS + (BOB_STEPS_FAST - BOB_STEPS) * math.clamp(view.speedShare or 0, 0, 1)
		bobPhase = (bobPhase + dt * (view.worldRate or 1) * steps * math.pi) % (math.pi * 2)
		if lastCamera then
			local delta = lastCamera:ToObjectSpace(cameraCFrame)
			local pitch, yaw = delta:ToEulerAnglesYXZ()
			local moved = delta.Position
			lagX = math.clamp(lagX + yaw * LAG - moved.X * SHAKE_LAG, -LAG_MAX, LAG_MAX)
			lagY = math.clamp(lagY + pitch * LAG + moved.Y * SHAKE_LAG, -LAG_MAX, LAG_MAX)
		end
		local settle = math.exp(-LAG_RETURN * dt)
		lagX *= settle
		lagY *= settle
	end
	lastCamera = cameraCFrame
	local swayX = if shakeOn then math.cos(bobPhase) * BOB_X else 0
	local bobY = if shakeOn then math.sin(bobPhase) * BOB_Y else 0

	local balls = view.balls or 0
	local megaScale = if view.mega then MEGA_SCALE else 1
	local spin = cameraCFrame.Rotation * CFrame.Angles(TILT, now * SPIN_RPS * math.pi * 2, 0)
	local avoid, avoidRadius = view.avoid, view.avoidRadius or 0

	for i, hand in hands do
		local side = hand.side

		-- Ball count rule, then the reload / put-away state.
		hand.wanted = balls >= 2 or (balls == 1 and hand == nextHand)
		if hand.wanted and not hand.loaded and now - hand.thrownAt >= RELOAD_AT then
			hand.loaded = true
			hand.dipAt = now -- quick flick to the pocket, then the new ball pops in
			if hand.thrownAt > -math.huge then
				Sounds.play("Reload", 0.95 + math.random() * 0.1) -- soft pocket grab
			end
		elseif not hand.wanted and hand.loaded then
			hand.loaded = false
			hand.dropAt = now
		end

		-- Everything below is worked out for the right arm and mirrored for the left.
		local x = spotX + side * (lagX + swayX) * viewport.Y
		local y = spotY + (lagY + side * bobY) * viewport.Y
		local restBall = cameraPoint(x, y, depth, viewport, tanY)
		local radius = HeldBall.DIAMETER / 2
		local restHand = restBall + SHOULDER_DIRECTION * (BALL_FORWARD * radius) - REST_FRONT * (BALL_UP * radius)
		local shoulder = restHand + SHOULDER_DIRECTION * ARM_LENGTH

		-- Throw swing around the shoulder, plus the reload dip.
		local pitch, yaw, push = throwPose(now - hand.thrownAt)
		local dip = dipAmount(hand, now)
		pitch -= DIP_TWIST * dip
		shoulder += Vector3.new(DIP_OUT * dip, -DIP_DEPTH * dip, 0) * studsPerScreen
		local along = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0):VectorToWorldSpace(-SHOULDER_DIRECTION) -- shoulder -> hand
		local handPoint = shoulder + along * (ARM_LENGTH * (1 + push))
		local armCenter = shoulder + along * (ARM_LENGTH * (0.5 + push))
		if side < 0 then
			along = mirror(along)
			handPoint = mirror(handPoint)
			armCenter = mirror(armCenter)
			shoulder = mirror(shoulder)
		end

		-- The arm block: +Y toward the shoulder, its front facing up (like arms raised in front of you).
		local yAxis = -along
		local front = UP - yAxis * UP:Dot(yAxis)
		front = if front.Magnitude > 1e-3 then front.Unit else -Vector3.zAxis
		local zAxis = -front
		local armLocal = CFrame.fromMatrix(armCenter, yAxis:Cross(zAxis), yAxis, zAxis)

		local ballRadius = hand.ball.radius() * megaScale
		local ballPoint = handPoint + along * (BALL_FORWARD * ballRadius) + front * (BALL_UP * ballRadius)

		-- The tutorial's pointer ring: never cover the thing it points at.
		local visible = true
		if avoid then
			local ballSpot = screenPoint(ballPoint, viewport, tanY)
			local handSpot = screenPoint(handPoint, viewport, tanY)
			local shoulderSpot = screenPoint(shoulder, viewport, tanY)
			local pixelsPerStud = viewport.Y / studsPerScreen
			local clear = avoidRadius + BUTTON_MARGIN
			if ballSpot and (avoid - ballSpot).Magnitude < ballRadius * pixelsPerStud + clear then
				visible = false
			elseif handSpot and shoulderSpot then
				-- The arm gets wider toward the bottom of the screen (it's closer).
				local armRadius = ARM_SCALE * 0.75 * pixelsPerStud
				if distanceToSegment(avoid, handSpot, shoulderSpot) < armRadius + clear then
					visible = false
				end
			end
		end
		hand.visible = visible

		-- Draw.
		setArmVisible(hand, visible)
		armCFrames[i] = cameraCFrame * armLocal
		local ballWorld = cameraCFrame * ballPoint
		hand.ballPosition = if visible then ballWorld else nil
		local scale = if visible then ballScale(hand, now) * megaScale else 0
		hand.ball.draw(CFrame.new(ballWorld) * spin, scale, now)
	end

	if right.arm and left.arm and (right.visible or left.visible) then
		workspace:BulkMoveTo(armParts, armCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Starts the throw on one hand. Returns where its ball is (nil = not showing).
local function throwFrom(hand, now)
	local position = if hand.visible then hand.ballPosition else nil
	-- Arm whoosh: right hand slightly higher pitch than the left, plus a little
	-- random wobble, so fast alternating throws don't sound robotic.
	Sounds.play("Swing", (if hand.side > 0 then 1.06 else 0.94) + (math.random() - 0.5) * 0.1)
	hand.thrownAt = now
	hand.loaded = false
	hand.dropAt = -math.huge -- gone at once (it's the ball that was just thrown)
	return position
end

function Viewmodel.launch(both)
	local now = os.clock()
	local first = nextHand
	local second = otherHand(first)
	nextHand = second -- right, left, right, left...
	local firstSpot = throwFrom(first, now)
	local secondSpot = nil
	local bothThrew = false
	-- Multiball: the other hand throws too, if it has a ball.
	if both and second.visible and second.wanted then
		secondSpot = throwFrom(second, now)
		bothThrew = true
	end
	return firstSpot, secondSpot, first.side, bothThrew
end

return Viewmodel
