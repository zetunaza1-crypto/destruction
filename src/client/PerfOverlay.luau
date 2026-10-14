--[[
	Playtest helper: a tiny label in the bottom-left corner showing
	  FPS     - frames per second (smoothed)
	  MAX     - the slowest single frame in the last ~2 seconds, in milliseconds
	            (16.7 = still 60 fps; a stutter shows up here even if FPS looks fine)
	  PARTS   - parts in the current run's world (rooms, decorations, balls)
	  SHARDS  - shard / chip pieces flying or lying around right now
	Only shown when Config.SHOW_PERF is true. Turn it off before release.

	PerfOverlay.start(getShardCount) once; PerfOverlay.watch(runFolder) each time
	a new run world is built.

	Cheap on purpose: frame times go into two 1-second buckets (no lists), the
	part count follows DescendantAdded / DescendantRemoving instead of counting
	every frame, and the text is rewritten 4 times a second.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local PerfOverlay = {}

local PAPER = Color3.fromRGB(244, 241, 234)
local INK = Color3.fromRGB(17, 17, 17)
local TEXT_INTERVAL = 0.25 -- seconds between label updates
local BUCKET_SECONDS = 1 -- worst frame = max of this bucket and the previous one (1-2 s)

local label
local started = false
local getShards = function()
	return 0
end

local partCount = 0
local connections = {}

local smoothedDt = 1 / 60
local lastFrame = os.clock()
local bucketStart = os.clock()
local bucketWorst = 0
local previousWorst = 0
local nextText = 0

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "PerfOverlay"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50 -- above the game UI, but it never takes input
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- A paper strip with an ink hairline, hugging the bottom-left corner of the
	-- safe area, below where the HUD's corner button sits.
	local plate = Instance.new("TextLabel")
	plate.Name = "Stats"
	plate.Active = false
	plate.AnchorPoint = Vector2.new(0, 1)
	plate.Position = UDim2.new(0, 4, 1, -1)
	plate.Size = UDim2.fromOffset(0, 12)
	plate.AutomaticSize = Enum.AutomaticSize.X
	plate.BackgroundColor3 = PAPER
	plate.BackgroundTransparency = 0.1
	plate.BorderSizePixel = 0
	plate.Font = Enum.Font.RobotoMono
	plate.TextSize = 10
	plate.TextColor3 = INK
	plate.TextXAlignment = Enum.TextXAlignment.Left
	plate.Text = "-- FPS"
	pcall(function()
		plate.Interactable = false -- never blocks taps or clicks (newer property)
	end)

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 4)
	padding.PaddingRight = UDim.new(0, 4)
	padding.Parent = plate

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = INK
	stroke.Thickness = 1
	stroke.Parent = plate

	plate.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return plate
end

local function onFrame()
	local now = os.clock()
	local dt = now - lastFrame
	lastFrame = now

	smoothedDt += (dt - smoothedDt) * 0.08
	if now - bucketStart >= BUCKET_SECONDS then
		previousWorst = bucketWorst
		bucketWorst = 0
		bucketStart = now
	end
	if dt > bucketWorst then
		bucketWorst = dt
	end

	if now >= nextText then
		nextText = now + TEXT_INTERVAL
		local worst = math.max(bucketWorst, previousWorst)
		label.Text = string.format(
			"%d FPS  MAX %.1f MS  PARTS %d  SHARDS %d",
			math.floor(1 / math.max(smoothedDt, 1e-4) + 0.5),
			worst * 1000,
			partCount,
			getShards()
		)
		label.TextColor3 = if worst > 1 / 30 then Color3.fromRGB(200, 30, 30) else INK
	end
end

-- getShardCount: function returning how many shard pieces are live.
function PerfOverlay.start(getShardCount)
	if started or not Config.SHOW_PERF then
		return
	end
	started = true
	if getShardCount then
		getShards = getShardCount
	end
	label = build()
	RunService.RenderStepped:Connect(onFrame)
end

-- Counts the parts in a run's world folder from now on.
function PerfOverlay.watch(folder)
	if not started then
		return
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	partCount = 0
	if not folder then
		return
	end
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("BasePart") then
			partCount += 1
		end
	end
	table.insert(
		connections,
		folder.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("BasePart") then
				partCount += 1
			end
		end)
	)
	table.insert(
		connections,
		folder.DescendantRemoving:Connect(function(descendant)
			if descendant:IsA("BasePart") then
				partCount -= 1
			end
		end)
	)
end

return PerfOverlay
