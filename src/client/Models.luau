--[[
	Places the Blender models loaded by the server (ReplicatedStorage.ModelLibrary).
	If a model isn't uploaded yet (ID 0 in Config.Models) or hasn't loaded,
	Models.place returns nil and the caller builds its block version instead.

	Model parts are named <Model>_<Role> (Glass, Metal, Wood, Stone, Neon, Plant, Body).
	Each role gets its color/material from Shared.ModelStyles, overridable per call.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModelStyles = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ModelStyles"))

local Models = {}

local function library()
	return ReplicatedStorage:FindFirstChild("ModelLibrary")
end

function Models.has(name)
	local folder = library()
	return folder ~= nil and folder:FindFirstChild(name) ~= nil
end

local function roleOf(part)
	return part.Name:match("_(%w+)$") or "Body"
end

--[[
	options = {
		kind = "Wall" | "Prop",            -- Prop = breakable decoration
		anchor = "floor" | "ceiling" | "center",  -- which point of the model sits at `cframe`
		scale = number?,
		colors = { [Role] = Color3 }?,     -- e.g. tint glass with the zone accent
	}
]]
function Models.place(name, parent, cframe, options)
	local folder = library()
	local template = folder and folder:FindFirstChild(name)
	if not template then
		return nil
	end
	options = options or {}

	local model = template:Clone()
	local style = ModelStyles[name] or {}
	local kind = options.kind or (if style.Breakable then "Prop" else "Wall")

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local role = roleOf(part)
			local roleStyle = style[role]
			if type(roleStyle) == "table" and roleStyle.Material then
				part.Color = roleStyle.Color
				part.Material = roleStyle.Material
				part.Transparency = roleStyle.Transparency
			end
			if options.colors and options.colors[role] then
				part.Color = options.colors[role]
			end
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CastShadow = false
			part:SetAttribute("Kind", kind)
		end
	end
	if kind == "Prop" then
		model:SetAttribute("Breakable", true)
	end

	-- Imported FBX units can come in at the wrong scale; fit the model to its
	-- true height from the manifest, then apply any extra scale asked for.
	local scale = options.scale or 1
	if style.Size then
		local _, importedSize = model:GetBoundingBox()
		if importedSize.Y > 0.01 then
			scale *= style.Size.Y / importedSize.Y
		end
	end
	if math.abs(scale - 1) > 0.001 then
		model:ScaleTo(model:GetScale() * scale)
	end

	-- Line the chosen anchor point of the bounding box up with `cframe`.
	model:PivotTo(CFrame.new(model:GetPivot().Position) * cframe.Rotation)
	local boxCFrame, boxSize = model:GetBoundingBox()
	local anchorOffset = Vector3.zero
	local anchor = options.anchor or style.Anchor
	if anchor == "floor" then
		anchorOffset = Vector3.new(0, boxSize.Y / 2, 0)
	elseif anchor == "ceiling" then
		anchorOffset = Vector3.new(0, -boxSize.Y / 2, 0)
	end
	local target = cframe.Position + anchorOffset
	model:PivotTo(model:GetPivot() + (target - boxCFrame.Position))

	model.Parent = parent
	return model
end

return Models
