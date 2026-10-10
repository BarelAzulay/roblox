-- CourseBuilder (v2): turns a CourseLayout layout into real, tagged, anchored Parts.
--
--   CourseBuilder.GenerateLayout(difficultyId, seed) -> Layout        (re-exported from CourseLayout)
--   CourseBuilder.ValidateLayout(layout) -> ok, problems              (re-exported from CourseLayout)
--   CourseBuilder.Build(layout, origin, parent) -> CourseInfo
--
-- CourseInfo = {
--   Folder, StartCFrame, Checkpoints = { [i] = { Part, Index, SpawnCFrame, Stage } }, Finish, KillY,
--   TotalTokens (token VALUE total), TotalSteps, Archetype, Themes
-- }
--
-- The layout schema is documented at the top of CourseLayout.lua; this file codes against it:
--   * every layout position is origin-relative, so world = origin + position (Cannon Target, Pendulum
--     Hinge, Moving EndOffset (a pure offset), Span / Plate / Zone positions ...)
--   * a step's CFrame is CFrame.new(origin + Pos) * CFrame.Angles(0, rad(Yaw), 0), its local +Z is the
--     direction of travel, and Pos is the centre of the TOP surface (the solid fills [Pos.Y - Size.Y, Pos.Y])
--
-- Look: a calm, slightly dim cloud world (Theme.World when it exists, own muted fallbacks otherwise).
-- Platform tops are lighter than their sides, trims use the difficulty colour with a per-stage tint,
-- every stage theme gets its own material/tint, every step kind its own props, and every stage a
-- floating landmark. Neon is only used for small accents. Everything is Anchored; decor never collides.
-- Plain Lua 5.1-compatible syntax only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)
local CourseLayout = require(script.Parent.CourseLayout)

local CourseBuilder = {}
CourseBuilder.GenerateLayout = CourseLayout.GenerateLayout
CourseBuilder.ValidateLayout = CourseLayout.ValidateLayout
CourseBuilder.Stats = CourseLayout.Stats

local Tags = Config.Tags
local Phys = Config.Physics

local rad, sin, cos, pi = math.rad, math.sin, math.cos, math.pi
local floor, ceil, max, min, abs, sqrt = math.floor, math.ceil, math.max, math.min, math.abs, math.sqrt
local atan2 = math.atan2 or function(y, x)
	return math.atan(y, x)
end

local PART_LIMIT = 2450 -- total parts we aim for (tokens included); decor shrinks to stay below it
local TOKEN_PARTS = 7 -- rough number of parts one TokenService token is made of
local MIN_SIZE = 0.05 -- smallest part dimension Roblox accepts everywhere
local EMPTY = {}
local SMOOTH = Enum.SurfaceType.Smooth
local MAT = Enum.Material

----------------------------------------------------------------------
-- Palette (Theme.World when present, muted fallbacks otherwise)
----------------------------------------------------------------------
local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local WORLD = Theme.World
if type(WORLD) ~= "table" then
	WORLD = {}
end

local function worldColor(key, fallback)
	local v = WORLD[key]
	if typeof(v) == "Color3" then
		return v
	end
	return fallback
end

local C = {
	Top = worldColor("CloudTop", rgb(206, 218, 238)), -- platform tops
	Side = worldColor("CloudSide", rgb(148, 166, 204)), -- platform bodies
	Shadow = worldColor("CloudShadow", rgb(102, 120, 160)),
	Hazard = worldColor("Hazard", rgb(158, 64, 92)),
	HazardGlow = worldColor("HazardGlow", rgb(214, 100, 120)),
	Checkpoint = worldColor("Checkpoint", rgb(66, 172, 154)),
	Token = worldColor("Token", rgb(238, 196, 88)),
	Ink = rgb(30, 38, 70), -- text outlines, sign strokes
	Panel = rgb(34, 44, 86), -- sign boards
	Storm = rgb(58, 64, 94), -- rain clouds
	Text = rgb(242, 246, 252), -- soft white for text only
	Gold = rgb(222, 184, 98), -- dash hints, finish
	Brass = rgb(196, 156, 82),
	Iron = rgb(74, 80, 104),
	Rock = rgb(88, 84, 104),
	Lava = rgb(236, 120, 70),
	Wind = rgb(176, 214, 232),
	Rainbow = {
		rgb(222, 112, 126),
		rgb(228, 160, 96),
		rgb(226, 204, 108),
		rgb(112, 196, 140),
		rgb(104, 168, 224),
		rgb(160, 130, 222),
	},
}

-- Bounce pads are safe and helpful, so they only wear the calm half of the rainbow (green / blue / violet).
-- Red and orange stay reserved for hazards: Rainbow[1] is within dE 3 of HazardGlow (SpinBar caps, danger and
-- strike rings) and Rainbow[2] within dE 3.3 of the Hard trim and the lava colour.
local PAD_COLORS = { C.Rainbow[4], C.Rainbow[5], C.Rainbow[6] }

-- per-stage tint index 1..8 (CourseLayout.Stages[k].Tint); trims lean towards it
local STAGE_TINTS = {
	rgb(112, 184, 214),
	rgb(214, 140, 164),
	rgb(226, 184, 104),
	rgb(150, 128, 208),
	rgb(108, 190, 152),
	rgb(224, 128, 102),
	rgb(104, 148, 224),
	rgb(188, 150, 214),
}

-- colours of the co-op bridges (BridgeNumber picks one)
local BRIDGE_COLORS = {
	rgb(214, 120, 176),
	rgb(104, 196, 222),
	rgb(132, 204, 130),
	rgb(226, 178, 84),
}

-- how each stage theme dresses its platforms: Hue = tint pulled into the cloud colours (Top / Side are
-- the pull strengths), Mat = side material, TopMat = top material
local THEME_LOOK = {
	Plain = { Hue = rgb(190, 200, 224), Top = 0.0, Side = 0.0 },
	Stones = { Hue = rgb(178, 198, 226), Top = 0.12, Side = 0.2 },
	Beams = { Hue = rgb(210, 172, 128), Top = 0.42, Side = 0.5, Mat = MAT.WoodPlanks, TopMat = MAT.WoodPlanks },
	Bounce = { Hue = rgb(122, 204, 164), Top = 0.28, Side = 0.34 },
	Moving = { Hue = rgb(116, 184, 232), Top = 0.28, Side = 0.34 },
	Spin = { Hue = rgb(196, 124, 156), Top = 0.26, Side = 0.34 },
	Storm = { Hue = rgb(70, 78, 108), Top = 0.5, Side = 0.58, Mat = MAT.Slate },
	Lightning = { Hue = rgb(142, 120, 196), Top = 0.4, Side = 0.5, Mat = MAT.Slate },
	Vanish = { Hue = rgb(196, 212, 236), Top = 0.2, Side = 0.2 },
	Cannon = { Hue = rgb(148, 150, 164), Top = 0.4, Side = 0.5, Mat = MAT.Concrete },
	Wind = { Hue = rgb(176, 218, 230), Top = 0.3, Side = 0.3 },
	Pendulum = { Hue = rgb(206, 170, 112), Top = 0.32, Side = 0.4 },
	Plates = { Hue = rgb(132, 150, 214), Top = 0.3, Side = 0.38 },
	DashGap = { Hue = rgb(224, 192, 112), Top = 0.3, Side = 0.36 },
	Gauntlet = { Hue = rgb(104, 96, 112), Top = 0.46, Side = 0.55, Mat = MAT.Slate },
}

----------------------------------------------------------------------
-- Small geometry helpers
----------------------------------------------------------------------
-- CFrame whose local X axis points along `dir` (cylinder axis), keeping a stable roll.
local function axisCF(pos, dir)
	local d = dir.Unit
	local up = Vector3.new(0, 1, 0)
	if abs(d.Y) > 0.98 then
		up = Vector3.new(0, 0, 1)
	end
	local u = (up - d * d:Dot(up)).Unit
	return CFrame.fromMatrix(pos, d, u)
end

local function stepFrame(ctx, step)
	return CFrame.new(ctx.Origin + step.Pos) * CFrame.Angles(0, rad(step.Yaw or 0), 0)
end

local function forwardOf(step)
	local a = rad(step.Yaw or 0)
	return Vector3.new(sin(a), 0, cos(a))
end

local function yawOf(dir)
	return atan2(dir.X, dir.Z)
end

local function tintOf(index)
	local n = #STAGE_TINTS
	return STAGE_TINTS[(((index or 1) - 1) % n) + 1]
end

----------------------------------------------------------------------
-- Part factory
----------------------------------------------------------------------
-- group: name of a sub-folder of the course folder. opts: Shape, Transparency, Solid (collides),
-- Trigger (no collision but touchable: hazard volumes), Shadow, Free (ignore ctx.Attach).
-- While ctx.Attach is set, decor is either parented under ctx.Attach.Root ("child": it fades / swings
-- with it) or welded to it ("weld": it follows a part moved by CFrame).
local function mk(ctx, group, name, className, size, cf, color, material, opts)
	opts = opts or EMPTY
	local p = Instance.new(className or "Part")
	p.Name = name
	if opts.Shape and (className == nil or className == "Part") then
		p.Shape = opts.Shape
	end
	if size.X < MIN_SIZE or size.Y < MIN_SIZE or size.Z < MIN_SIZE then
		size = Vector3.new(max(size.X, MIN_SIZE), max(size.Y, MIN_SIZE), max(size.Z, MIN_SIZE))
	end
	p.Size = size
	p.Anchored = true
	p.TopSurface = SMOOTH
	p.BottomSurface = SMOOTH
	p.Color = color
	p.Material = material or MAT.SmoothPlastic
	if opts.Transparency then
		p.Transparency = opts.Transparency
	end
	if opts.Solid then
		p.CanCollide = true
	else
		p.CanCollide = false
		p.CanQuery = false -- decor and hazard volumes are invisible to raycasts (camera, pets ...)
		if not opts.Trigger then
			p.CanTouch = false
		end
	end
	if not (opts.Solid or opts.Shadow) then
		p.CastShadow = false
	end
	p.CFrame = cf
	local parent = ctx.Groups[group]
	local attach = ctx.Attach
	if attach and not opts.Free and not opts.Solid and not opts.Trigger then
		if attach.Mode == "child" then
			parent = attach.Root
		else
			ctx.Welds[#ctx.Welds + 1] = { attach.Root, p }
		end
	end
	p.Parent = parent
	ctx.Parts = ctx.Parts + 1
	return p
end

local function blk(ctx, group, name, size, cf, color, material, trans)
	return mk(ctx, group, name, "Part", size, cf, color, material, { Transparency = trans })
end

-- Sphere, or an ellipsoid (a block with a Sphere SpecialMesh) when the size is not uniform.
local function ball(ctx, group, name, size, cf, color, material, trans)
	if type(size) == "number" then
		size = Vector3.new(size, size, size)
	end
	if abs(size.X - size.Y) > 0.01 or abs(size.X - size.Z) > 0.01 then
		local p = mk(ctx, group, name, "Part", size, cf, color, material, { Transparency = trans })
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = p
		return p
	end
	return mk(ctx, group, name, "Part", size, cf, color, material,
		{ Shape = Enum.PartType.Ball, Transparency = trans })
end

-- upright cylinder: its axis is the Y axis of `cf`
local function cyl(ctx, group, name, height, diameter, cf, color, material, trans)
	return mk(ctx, group, name, "Part", Vector3.new(height, diameter, diameter), cf * CFrame.Angles(0, 0, pi / 2),
		color, material, { Shape = Enum.PartType.Cylinder, Transparency = trans })
end

-- thin cylinder between two world points
local function rod(ctx, group, name, a, b, thick, color, material, trans)
	local d = b - a
	local len = d.Magnitude
	if len < 0.05 then
		return nil
	end
	return mk(ctx, group, name, "Part", Vector3.new(len, thick, thick), axisCF((a + b) / 2, d), color, material,
		{ Shape = Enum.PartType.Cylinder, Transparency = trans })
end

local function addLight(part, color, range, brightness)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Parent = part
	return light
end

local function addSparkles(parent, color, rate, speed, lifetime, size)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(color)
	e.Rate = rate
	e.Lifetime = NumberRange.new(lifetime * 0.6, lifetime)
	e.Speed = NumberRange.new(speed * 0.5, speed)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	e.LightEmission = 0.6
	e.Parent = parent
	return e
end

local function addSmoke(parent, color, rate, size)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.Color = ColorSequence.new(color)
	e.Rate = rate
	e.Lifetime = NumberRange.new(3, 5)
	e.Speed = NumberRange.new(3, 6)
	e.SpreadAngle = Vector2.new(25, 25)
	e.EmissionDirection = Enum.NormalId.Top
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.5), NumberSequenceKeypoint.new(1, size * 1.6) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
	e.LightEmission = 0
	e.Parent = parent
	return e
end

-- Decor on parts that move (moving clouds, spin bars) is welded to the moving root once the whole
-- course is parented into the world.
local function applyWelds(ctx)
	for _, pair in ipairs(ctx.Welds) do
		local root, part = pair[1], pair[2]
		if root.Parent and part.Parent then
			part.Anchored = false
			part.Massless = true
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part
		end
	end
	ctx.Welds = {}
end

----------------------------------------------------------------------
-- GUI helpers (all text through Theme roles)
----------------------------------------------------------------------
-- World text rule (ARCHITECTURE_V3.md): hints floating over the course are PIXEL-sized BillboardGuis (constant
-- on-screen size: titles >= 22 px, info lines >= 18 px at 1080p, outlined glyphs on a compact solid plate that
-- sizes itself to its lines, LightInfluence 0, MaxDistance ~100-120); signs on surfaces are SurfaceGuis at 50-60
-- px per stud with FIXED text sizes (titles >= 1 stud, info lines >= 0.6 stud). Never TextScaled in the world.
local TEXT_INK = Theme.Colors.TextStroke or C.Ink
local HINT_TITLE = 30 -- px
local HINT_INFO = 19 -- px
local SIGN_INFO = 30 -- px at 50 px per stud = 0.6 stud

-- Fixed-size outlined label. place = { x, y, w, h } fractions of the parent, or nil for an auto-sized line
-- inside a list layout (order = LayoutOrder).
local function worldText(parent, text, role, size, color, place, order, wrap)
	local props = { TextWrapped = wrap == true, LayoutOrder = order or 0 }
	if place then
		props.Position = UDim2.new(place[1], 0, place[2], 0)
		props.Size = UDim2.new(place[3], 0, place[4], 0)
	else
		props.AutomaticSize = Enum.AutomaticSize.XY
		props.Size = UDim2.fromOffset(0, size + 4)
	end
	local ok, label = pcall(Theme.Label, text, role, {
		Size = size,
		Color = color,
		Stroke = 1, -- the glyph outline replaces the classic stroke
		Outline = math.max(2, math.floor(size / 16 + 0.5)),
		OutlineColor = TEXT_INK,
		Props = props,
	})
	if not ok or not label then
		label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextSize = size
		label.TextColor3 = color
		label.TextStrokeTransparency = 0
		pcall(Theme.Style, label, role, { Size = size, Color = color, Stroke = 0 })
		for k, v in pairs(props) do
			label[k] = v
		end
	end
	label.Parent = parent
	return label
end

local function addGradient(target, top, bottom)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = 90
	g.Parent = target
	return g
end

-- Pixel-sized hint tag on `part`. Its bottom edge sits `lift` studs above the part (world space) and it grows
-- upwards, so it never sinks into what it labels. Returns the compact plate; add lines with hintLine.
local function hintTag(part, lift, maxDistance, edge)
	local gui = Instance.new("BillboardGui")
	gui.Name = "HintTag"
	gui.Size = UDim2.fromOffset(420, 120)
	gui.SizeOffset = Vector2.new(0, 0.5)
	gui.StudsOffsetWorldSpace = Vector3.new(0, lift or 0, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = maxDistance or 110
	gui.ClipsDescendants = false
	gui.Parent = part
	-- dark plate: gold or pale text straight on the sky is only 1.2 - 2.1 : 1, on this plate 7 : 1 or better
	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.AnchorPoint = Vector2.new(0.5, 1)
	plate.Position = UDim2.new(0.5, 0, 1, 0)
	plate.Size = UDim2.fromOffset(120, 0)
	plate.AutomaticSize = Enum.AutomaticSize.XY
	plate.BackgroundColor3 = C.Panel
	plate.BackgroundTransparency = 0.06
	plate.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = plate
	local stroke = Instance.new("UIStroke")
	stroke.Color = edge or C.Ink
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = plate
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 5)
	pad.PaddingBottom = UDim.new(0, 7)
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = plate
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 1)
	layout.Parent = plate
	plate.Parent = gui
	return plate
end

local function hintLine(plate, text, role, size, color, order)
	return worldText(plate, text, role, size, color, nil, order)
end

local function surfaceOn(part, face, pixelsPerStud)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 50
	gui.LightInfluence = 0
	gui.Parent = part
	return gui
end

-- Canvas size (px) of a SurfaceGui on `face` of `part` at `pps` pixels per stud.
local function facePixels(part, face, pps)
	local s = part.Size
	if face == Enum.NormalId.Top or face == Enum.NormalId.Bottom then
		return s.X * pps, s.Z * pps
	elseif face == Enum.NormalId.Left or face == Enum.NormalId.Right then
		return s.Z * pps, s.Y * pps
	end
	return s.X * pps, s.Y * pps
end

-- The biggest fixed text size (px, Roblox caps TextSize at 100) for a glyph filling `k` of the face's short side.
local function faceTextSize(part, face, pps, k)
	local w, h = facePixels(part, face, pps)
	return math.max(SIGN_INFO, math.min(100, math.floor(math.min(w, h) * k)))
end

-- chunky dark sign panel for SurfaceGuis
local function panelFrame(parent, transparency)
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, 0, 1, 0)
	f.BackgroundColor3 = C.Panel
	f.BackgroundTransparency = transparency or 0.06
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = C.Ink
	stroke.Thickness = 3
	stroke.Parent = f
	f.Parent = parent
	return f
end

----------------------------------------------------------------------
-- Look of a step (colours / materials from stage theme, stage tint and step kind)
----------------------------------------------------------------------
local function lookFor(ctx, step)
	local layout = ctx.Layout
	local theme = layout.Themes and layout.Themes[step.Stage]
	local stage = layout.Stages and layout.Stages[step.Stage]
	local tint = tintOf(stage and stage.Tint)
	local base = THEME_LOOK[theme] or THEME_LOOK.Plain
	local look = {
		Top = C.Top:Lerp(base.Hue, base.Top):Lerp(tint, 0.06),
		Side = C.Side:Lerp(base.Hue, base.Side),
		Trim = ctx.Trim:Lerp(tint, 0.42),
		Mat = base.Mat or MAT.SmoothPlastic,
		TopMat = base.TopMat or MAT.SmoothPlastic,
		Tint = tint,
		Theme = theme,
	}
	local kind = step.Kind
	if kind == "Start" or kind == "Finish" then
		look.Mat = MAT.SmoothPlastic
		look.TopMat = MAT.SmoothPlastic
		look.Top = C.Top
		look.Side = C.Side
		look.Trim = ctx.Trim
	elseif kind == "Checkpoint" then
		look.Mat = MAT.SmoothPlastic
		look.TopMat = MAT.SmoothPlastic
		look.Top = C.Top:Lerp(C.Checkpoint, 0.16)
		look.Side = C.Side:Lerp(C.Checkpoint, 0.18)
		look.Trim = C.Checkpoint
	elseif kind == "DashGap" then
		look.Trim = C.Gold
	elseif kind == "SpinBarPlatform" then
		look.Trim = C.Hazard:Lerp(look.Trim, 0.25)
	elseif kind == "StormPlatform" then
		look.Trim = rgb(124, 138, 190)
	elseif kind == "LightningPlatform" then
		look.Trim = rgb(222, 196, 96)
	elseif kind == "Moving" then
		look.Trim = rgb(116, 200, 232):Lerp(look.Trim, 0.25)
	elseif kind == "PendulumPlatform" then
		look.Trim = C.Brass:Lerp(look.Trim, 0.3)
	elseif kind == "WindPlatform" then
		look.Trim = C.Wind:Lerp(look.Trim, 0.3)
	end
	return look
end

----------------------------------------------------------------------
-- Platform base: slab (tagged by the callers), top plate, trim, puffy underside
----------------------------------------------------------------------
-- A ">" painted on the floor: tip at the origin of `cf`, pointing along its local +Z.
local function chevron(ctx, group, name, cf, armLen, width, color, material, trans)
	local phi = pi / 4
	for _, sgn in ipairs({ -1, 1 }) do
		local centre = Vector3.new(sgn * sin(phi) * armLen / 2, 0, -cos(phi) * armLen / 2)
		blk(ctx, group, name, Vector3.new(width, 0.1, armLen), cf * CFrame.new(centre) * CFrame.Angles(0, -sgn * phi, 0),
			color, material, trans)
	end
end

-- Four trim strips on the top edges (long edges only for beams).
local function addTrim(ctx, step, F, color, longOnly)
	local sx, sz = step.Size.X, step.Size.Z
	local w, h, y = 0.5, 0.14, 0.17
	blk(ctx, "Decor", "Trim", Vector3.new(w, h, sz - 0.3), F * CFrame.new(sx / 2 - w / 2 - 0.1, y, 0), color)
	blk(ctx, "Decor", "Trim", Vector3.new(w, h, sz - 0.3), F * CFrame.new(-sx / 2 + w / 2 + 0.1, y, 0), color)
	if not longOnly then
		blk(ctx, "Decor", "Trim", Vector3.new(sx - 1.3, h, w), F * CFrame.new(0, y, sz / 2 - w / 2 - 0.1), color)
		blk(ctx, "Decor", "Trim", Vector3.new(sx - 1.3, h, w), F * CFrame.new(0, y, -sz / 2 + w / 2 + 0.1), color)
	end
end

-- Puffs / stalactites that hang under (or round the rim of) a platform. They never rise above the top.
-- Variant 1 = under-balls, 2 = stalactite, 3 = rim puffs, 4 = belly, big = belly + stalactite.
local function underside(ctx, step, look, F, big, lite)
	local sx, th, sz = step.Size.X, step.Size.Y, step.Size.Z
	local hx, hz = sx / 2, sz / 2
	local rng = ctx.Rng
	local v = step.Variant or 1
	local small = min(sx, sz)
	local puff = look.Side:Lerp(C.Top, 0.3)
	local deep = look.Side:Lerp(C.Shadow, 0.4)
	if lite then
		v = 0
	end
	if big then
		v = 5
	end
	if v == 0 or v == 1 then
		local n = 3
		if v == 0 then
			n = 1
		end
		for _ = 1, n do
			local d = rng:NextNumber(2.6, 4.6)
			local px = rng:NextNumber(-1, 1) * max(0, hx - d * 0.4)
			local pz = rng:NextNumber(-1, 1) * max(0, hz - d * 0.4)
			ball(ctx, "Decor", "Puff", d, F * CFrame.new(px, -th - d * 0.28, pz), puff)
		end
	elseif v == 2 then
		local d = small * 0.7
		local h = 1.3
		for k = 1, 3 do
			cyl(ctx, "Decor", "Stalactite", h, d, F * CFrame.new(0, -th - h * (k - 0.5) + 0.05, 0),
				puff:Lerp(deep, k / 3))
			d = d * 0.6
		end
	elseif v == 3 then
		local d = max(2.0, min(small * 0.3, 3.4))
		local spots = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }
		if sz > sx * 1.4 then
			spots[#spots + 1] = { -1, 0 }
			spots[#spots + 1] = { 1, 0 }
		elseif sx > sz * 1.4 then
			spots[#spots + 1] = { 0, -1 }
			spots[#spots + 1] = { 0, 1 }
		end
		for _, s in ipairs(spots) do
			ball(ctx, "Decor", "RimPuff", d, F * CFrame.new(s[1] * (hx - d * 0.2), -d / 2 - 0.1, s[2] * (hz - d * 0.2)), puff)
		end
	elseif v == 4 then
		ball(ctx, "Decor", "Belly", Vector3.new(sx * 0.82, 2.4, sz * 0.82), F * CFrame.new(0, -th - 0.5, 0), puff)
		ball(ctx, "Decor", "Belly", Vector3.new(sx * 0.46, 2.2, sz * 0.46),
			F * CFrame.new(rng:NextNumber(-1, 1) * hx * 0.2, -th - 1.7, rng:NextNumber(-1, 1) * hz * 0.2), deep)
	else
		ball(ctx, "Decor", "Belly", Vector3.new(sx * 0.86, 3.0, sz * 0.86), F * CFrame.new(0, -th - 0.4, 0), puff)
		local d = small * 0.6
		local h = 1.8
		for k = 1, 3 do
			cyl(ctx, "Decor", "Stalactite", h, d, F * CFrame.new(0, -th - 1.5 - h * (k - 0.5), 0), puff:Lerp(deep, k / 3))
			d = d * 0.6
		end
	end
end

-- Builds the walkable slab plus its dressing and returns (slab, frame).
-- opts: Name, Slab (slab only), Attach ("weld"|"child": see mk), Lite, Under (false = no underside),
--       LongTrim, Big, Transparency
local function buildBase(ctx, step, look, opts)
	opts = opts or EMPTY
	local F = stepFrame(ctx, step)
	local sx, th, sz = step.Size.X, step.Size.Y, step.Size.Z
	local main = mk(ctx, "Platforms", opts.Name or ("Step_" .. step.Index), "Part", Vector3.new(sx, th, sz),
		F * CFrame.new(0, -th / 2, 0), look.Side, look.Mat or MAT.SmoothPlastic,
		{ Solid = true, Shadow = true, Transparency = opts.Transparency })
	main:SetAttribute("StepIndex", step.Index)
	main:SetAttribute("Stage", step.Stage)
	main:SetAttribute("StepKind", step.Kind)
	if not ctx.CurrentMain then
		ctx.CurrentMain = main
	end
	if opts.Slab then
		return main, F
	end
	if opts.Attach then
		ctx.Attach = { Mode = opts.Attach, Root = main }
	end
	blk(ctx, "Decor", "TopPlate", Vector3.new(sx, 0.1, sz), F * CFrame.new(0, 0.05, 0), look.Top,
		look.TopMat or MAT.SmoothPlastic)
	addTrim(ctx, step, F, look.Trim, opts.LongTrim)
	if opts.Under ~= false then
		local lite = opts.Lite or ctx.Parts > ctx.UnderCap
		underside(ctx, step, look, F, opts.Big, lite)
	end
	return main, F
end

-- bullseye on a cannon's landing island
local function addBullseye(ctx, step, F)
	local prev = ctx.Layout.Steps[step.Index - 1]
	local h = prev and prev.Hazard
	if not (h and h.LandingPoint) then
		return
	end
	local lp = F:PointToObjectSpace(ctx.Origin + h.LandingPoint)
	cyl(ctx, "Decor", "TargetRing", 0.05, 5.6, F * CFrame.new(lp.X, 0.11, lp.Z), C.Gold, MAT.Neon, 0.35)
	cyl(ctx, "Decor", "TargetField", 0.05, 4.4, F * CFrame.new(lp.X, 0.13, lp.Z), C.Top:Lerp(C.Hazard, 0.12))
	cyl(ctx, "Decor", "TargetDot", 0.05, 2.4, F * CFrame.new(lp.X, 0.15, lp.Z), C.Gold, MAT.Neon, 0.3)
end

----------------------------------------------------------------------
-- Kind builders. KB.<Kind>(ctx, step, look) -> main part (the part players stand on)
----------------------------------------------------------------------
local KB = {}

-- a little prop in one corner of a plain platform (flower lamp, crystal pair or flag), when parts allow
local function addProp(ctx, step, look, F)
	if ctx.Parts > ctx.UnderCap - 150 then
		return
	end
	local rng = ctx.Rng
	if rng:NextNumber(0, 1) > 0.45 then
		return
	end
	local sx, sz = step.Size.X, step.Size.Z
	local cx = (rng:NextNumber(0, 1) < 0.5 and -1 or 1) * (sx / 2 - 0.6)
	local cz = (rng:NextNumber(0, 1) < 0.5 and -1 or 1) * (sz / 2 - 0.6)
	local kind = (step.Variant or 1) % 3
	if kind == 1 then
		cyl(ctx, "Decor", "FlowerStem", 1.4, 0.18, F * CFrame.new(cx, 0.8, cz), rgb(92, 150, 110))
		ball(ctx, "Decor", "FlowerLamp", 0.85, F * CFrame.new(cx, 1.7, cz), look.Tint:Lerp(C.Text, 0.25), MAT.Neon, 0.1)
	elseif kind == 2 then
		for k = 1, 2 do
			blk(ctx, "Decor", "MiniCrystal", Vector3.new(0.45, 1.0 + 0.6 * k, 0.45),
				F * CFrame.new(cx + 0.4 * k - 0.6, 0.5 + 0.3 * k, cz) * CFrame.Angles(0.15 * k, 0.5 * k, 0.12 * k),
				look.Tint, MAT.SmoothPlastic, 0.2)
		end
	else
		cyl(ctx, "Decor", "MiniPole", 2.4, 0.16, F * CFrame.new(cx, 1.3, cz), C.Iron:Lerp(C.Top, 0.3))
		blk(ctx, "Decor", "MiniFlag", Vector3.new(0.08, 0.7, 1.1), F * CFrame.new(cx, 2.1, cz + 0.55), look.Tint)
	end
end

function KB.Platform(ctx, step, look)
	local main, F = buildBase(ctx, step, look, { Name = "Cloud_" .. step.Index })
	if step.Link == "Cannon" then
		addBullseye(ctx, step, F)
	else
		addProp(ctx, step, look, F)
	end
	return main
end

-- long balance beam: planks, keel, end puffs and two lantern posts
function KB.Beam(ctx, step, look)
	local main, F = buildBase(ctx, step, look, { Name = "Beam_" .. step.Index, Under = false, LongTrim = true })
	local sx, th, sz = step.Size.X, step.Size.Y, step.Size.Z
	local seam = look.Top:Lerp(C.Shadow, 0.45)
	local n = max(2, floor(sz / 2.6))
	for k = 1, n do
		local z = -sz / 2 + (k - 0.5) * sz / n
		blk(ctx, "Decor", "Plank", Vector3.new(sx - 0.2, 0.05, 0.16), F * CFrame.new(0, 0.12, z), seam)
	end
	local deep = look.Side:Lerp(C.Shadow, 0.4)
	blk(ctx, "Decor", "Keel", Vector3.new(sx * 0.55, 1.4, sz * 0.9), F * CFrame.new(0, -th - 0.7, 0), deep)
	local puff = look.Side:Lerp(C.Top, 0.3)
	for _, e in ipairs({ -1, 1 }) do
		ball(ctx, "Decor", "EndPuff", Vector3.new(sx * 1.5, 2.2, sx * 1.5), F * CFrame.new(0, -th - 0.3, e * (sz / 2 - sx * 0.4)), puff)
	end
	for i, e in ipairs({ -1, 1 }) do
		local side = (i == 1) and 1 or -1
		local px, pz = side * (sx / 2 - 0.25), e * (sz / 2 - 0.5)
		cyl(ctx, "Decor", "LanternPost", 2.2, 0.3, F * CFrame.new(px, 1.1, pz), look.Trim:Lerp(C.Shadow, 0.5))
		ball(ctx, "Decor", "Lantern", 0.8, F * CFrame.new(px, 2.4, pz), look.Trim:Lerp(C.Text, 0.35), MAT.Neon, 0.1)
	end
	return main
end

-- sliding cloud: decor is welded so it rides along, a faint rail shows the route
function KB.Moving(ctx, step, look)
	local h = step.Hazard or EMPTY
	local main, F = buildBase(ctx, step, look, { Name = "MovingCloud_" .. step.Index, Attach = "weld", Lite = true })
	local eo = h.EndOffset or Vector3.new(0, 0, 6)
	CollectionService:AddTag(main, Tags.MovingCloud)
	main:SetAttribute("EndOffset", eo)
	main:SetAttribute("Period", h.Period or 3.2)
	local dir = Vector3.new(eo.X, 0, eo.Z)
	local th = step.Size.Y
	local top = ctx.Origin + step.Pos
	if dir.Magnitude > 0.1 then
		local u = dir.Unit
		local yaw = yawOf(u)
		local spread = min(step.Size.X, step.Size.Z) * 0.2
		for _, s in ipairs({ 1, -1 }) do
			local cf = CFrame.new(top + u * (s * spread) + Vector3.new(0, 0.16, 0)) * CFrame.Angles(0, yaw + (s == 1 and 0 or pi), 0)
			chevron(ctx, "Decor", "SlideArrow", cf, 1.7, 0.4, look.Tint, MAT.SmoothPlastic, 0.1)
		end
	end
	ctx.Attach = nil
	local a = top + Vector3.new(0, -th - 5.2, 0)
	local b = a + Vector3.new(eo.X, 0, eo.Z)
	local railColor = rgb(116, 200, 232)
	rod(ctx, "Decor", "MoveRail", a, b, 0.35, railColor, MAT.Neon, 0.55)
	ball(ctx, "Decor", "MoveStop", 1.0, CFrame.new(a), railColor, MAT.Neon, 0.35)
	ball(ctx, "Decor", "MoveStop", 1.0, CFrame.new(b), railColor, MAT.Neon, 0.35)
	return main
end

-- fading step: pale translucent slab, cracks, sparkles (all decor is a child, so it fades with the slab)
function KB.Vanishing(ctx, step, look)
	local h = step.Hazard or EMPTY
	local ghost = look.Top:Lerp(look.Trim, 0.3)
	local ghostLook = { Side = ghost, Mat = MAT.SmoothPlastic, Top = ghost, Trim = look.Trim:Lerp(C.Text, 0.3) }
	local main, F = buildBase(ctx, step, ghostLook, { Name = "VanishCloud_" .. step.Index, Slab = true, Transparency = 0.2 })
	CollectionService:AddTag(main, Tags.VanishCloud)
	main:SetAttribute("VanishDelay", h.VanishDelay or 1)
	main:SetAttribute("ReturnDelay", h.ReturnDelay or 3.5)
	ctx.Attach = { Mode = "child", Root = main }
	addTrim(ctx, step, F, ghostLook.Trim)
	local sx, sz = step.Size.X, step.Size.Z
	local crack = ghost:Lerp(C.Shadow, 0.55)
	for k = 1, 3 do
		local len = ctx.Rng:NextNumber(min(sx, sz) * 0.3, min(sx, sz) * 0.55)
		local x = ctx.Rng:NextNumber(-1, 1) * (sx / 2 - len * 0.5 - 0.3)
		local z = ctx.Rng:NextNumber(-1, 1) * (sz / 2 - len * 0.5 - 0.3)
		blk(ctx, "Decor", "Crack", Vector3.new(0.14, 0.05, len),
			F * CFrame.new(x, 0.03, z) * CFrame.Angles(0, ctx.Rng:NextNumber(0, pi), 0), crack, MAT.SmoothPlastic, 0.1)
	end
	addSparkles(main, look.Trim, 3, 2, 1.6, 0.7)
	ctx.Attach = nil
	return main
end

-- bounce pad: round pad with a dark skirt, glow ring and an arrow
function KB.Bounce(ctx, step, look)
	local h = step.Hazard or EMPTY
	local main, F = buildBase(ctx, step, look, { Name = "BounceCloud_" .. step.Index })
	local padSize = h.PadSize or 4
	local color = PAD_COLORS[(step.Index % #PAD_COLORS) + 1]
	local pc = ctx.Origin + (h.Pos or step.Pos)
	cyl(ctx, "Decor", "PadSkirt", 0.3, padSize + 1.4, CFrame.new(pc + Vector3.new(0, 0.15, 0)), C.Iron, MAT.Metal)
	local pad = mk(ctx, "Hazards", "BouncePad", "Part", Vector3.new(0.7, padSize, padSize),
		CFrame.new(pc + Vector3.new(0, 0.35, 0)) * CFrame.Angles(0, 0, pi / 2), color, MAT.SmoothPlastic,
		{ Shape = Enum.PartType.Cylinder, Solid = true })
	CollectionService:AddTag(pad, Tags.BouncePad)
	pad:SetAttribute("Power", h.Power or 75)
	pad:SetAttribute("LaunchSpeed", h.LaunchSpeed or 0)
	cyl(ctx, "Decor", "PadGlow", 0.05, padSize * 0.68, CFrame.new(pc + Vector3.new(0, 0.72, 0)), color:Lerp(C.Text, 0.4), MAT.Neon, 0.25)
	local glyph = blk(ctx, "Decor", "PadGlyph", Vector3.new(padSize * 0.7, 0.05, padSize * 0.7),
		CFrame.new(pc + Vector3.new(0, 0.76, 0)), color, MAT.SmoothPlastic, 1)
	local gui = surfaceOn(glyph, Enum.NormalId.Top, 60)
	worldText(gui, "▲", "Accent", faceTextSize(glyph, Enum.NormalId.Top, 60, 0.75), C.Ink, { 0, 0.05, 1, 0.9 })
	return main
end

-- spinning bar(s) over a hub, with a faint danger ring on the floor
function KB.SpinBarPlatform(ctx, step, look)
	local h = step.Hazard or EMPTY
	local main, F = buildBase(ctx, step, look, { Name = "SpinPlatform_" .. step.Index })
	local hub = ctx.Origin + (h.Pos or step.Pos)
	local len = h.Length or 6
	local count = h.Count or 1
	cyl(ctx, "Decor", "DangerRing", 0.05, len + 0.4, CFrame.new(hub + Vector3.new(0, 0.11, 0)), C.HazardGlow, MAT.Neon, 0.5)
	cyl(ctx, "Decor", "DangerFloor", 0.05, len - 0.2, CFrame.new(hub + Vector3.new(0, 0.13, 0)), main.Color:Lerp(C.Top, 0.7))
	cyl(ctx, "Decor", "BarHub", 2.1, 2.2, CFrame.new(hub + Vector3.new(0, 1.05, 0)), C.Iron, MAT.Metal)
	for k = 1, count do
		local cf = CFrame.new(hub + Vector3.new(0, h.Height or 1, 0)) * CFrame.Angles(0, rad((k - 1) * 180 / count), 0)
		local bar = mk(ctx, "Hazards", "SpinBar", "Part", Vector3.new(len, 1.5, 1.1), cf, C.Hazard, MAT.SmoothPlastic,
			{ Solid = true })
		CollectionService:AddTag(bar, Tags.SpinBar)
		bar:SetAttribute("Speed", h.Speed or 70)
		bar:SetAttribute("Damage", h.Damage or 15)
		ctx.Attach = { Mode = "weld", Root = bar }
		for _, sgn in ipairs({ -1, 1 }) do
			ball(ctx, "Decor", "BarCap", 1.9, cf * CFrame.new(sgn * len / 2, 0, 0), C.HazardGlow, MAT.Neon, 0.1)
			blk(ctx, "Decor", "BarStripe", Vector3.new(0.5, 1.56, 1.16), cf * CFrame.new(sgn * len * 0.25, 0, 0), C.Gold)
		end
		ctx.Attach = nil
	end
	return main
end

-- rain cloud: slate platform, translucent damage volume, dark puffs above (HazardService adds the rain)
function KB.StormPlatform(ctx, step, look)
	local h = step.Hazard or EMPTY
	local main = buildBase(ctx, step, look, { Name = "StormPlatform_" .. step.Index })
	local box = h.Box
	if not box then
		return main
	end
	local bsize = box.Size
	local BF = CFrame.new(ctx.Origin + box.Pos) * CFrame.Angles(0, rad(box.Yaw or 0), 0)
	local vol = mk(ctx, "Hazards", "StormCloud", "Part", bsize, BF * CFrame.new(0, bsize.Y / 2, 0), C.Storm,
		MAT.SmoothPlastic, { Trigger = true, Transparency = 0.8 })
	CollectionService:AddTag(vol, Tags.StormCloud)
	vol:SetAttribute("DPS", h.DPS or 8)
	local n = max(4, min(8, floor(step.Size.X * step.Size.Z / 40) + 3))
	for _ = 1, n do
		local d = ctx.Rng:NextNumber(4.2, 5.8)
		local lx = ctx.Rng:NextNumber(-1, 1) * max(0, bsize.X / 2 - d * 0.3)
		local lz = ctx.Rng:NextNumber(-1, 1) * max(0, bsize.Z / 2 - d * 0.3)
		ball(ctx, "Decor", "StormPuff", d, BF * CFrame.new(lx, ctx.Rng:NextNumber(7.0, 7.4), lz),
			C.Storm:Lerp(rgb(120, 130, 164), ctx.Rng:NextNumber(0, 0.4)), MAT.SmoothPlastic, 0.08)
	end
	return main
end

-- strike zones with permanent scorch rings, two lightning rods and thunder puffs
function KB.LightningPlatform(ctx, step, look)
	local h = step.Hazard or EMPTY
	local main, F = buildBase(ctx, step, look, { Name = "LightningPlatform_" .. step.Index })
	for i, z in ipairs(h.Zones or EMPTY) do
		local zp = ctx.Origin + z.Pos
		local d = z.Radius * 2
		local zone = mk(ctx, "Hazards", "LightningZone", "Part", Vector3.new(d, 0.2, d), CFrame.new(zp + Vector3.new(0, 0.1, 0)),
			C.HazardGlow, MAT.SmoothPlastic, { Trigger = true, Transparency = 1 })
		CollectionService:AddTag(zone, Tags.LightningZone)
		zone:SetAttribute("Damage", h.Damage or 28)
		zone:SetAttribute("Interval", h.Interval or 4)
		zone:SetAttribute("Warning", h.Warning or 1.2)
		zone:SetAttribute("Radius", z.Radius)
		cyl(ctx, "Decor", "StrikeRing", 0.05, d + 0.3, CFrame.new(zp + Vector3.new(0, 0.1, 0)), C.HazardGlow, MAT.Neon, 0.5)
		cyl(ctx, "Decor", "Scorch", 0.05, d - 0.1, CFrame.new(zp + Vector3.new(0, 0.12, 0)), rgb(58, 50, 84), MAT.SmoothPlastic, 0.3)
	end
	local sx, sz = step.Size.X, step.Size.Z
	for i, c in ipairs({ { 1, 1 }, { -1, -1 } }) do
		local px, pz = c[1] * (sx / 2 - 0.8), c[2] * (sz / 2 - 0.8)
		local base = F * CFrame.new(px, 0, pz)
		cyl(ctx, "Decor", "RodPole", 6, 0.34, base * CFrame.new(0, 3, 0), C.Iron, MAT.Metal)
		cyl(ctx, "Decor", "RodBase", 0.8, 1.2, base * CFrame.new(0, 0.4, 0), C.Iron, MAT.Metal)
		ball(ctx, "Decor", "RodTip", 0.9, base * CFrame.new(0, 6.2, 0), rgb(236, 214, 120), MAT.Neon, 0.1)
	end
	for _ = 1, 3 do
		local d = ctx.Rng:NextNumber(4.0, 5.5)
		ball(ctx, "Decor", "ThunderPuff", d,
			F * CFrame.new(ctx.Rng:NextNumber(-1, 1) * sx * 0.3, 9.0, ctx.Rng:NextNumber(-1, 1) * sz * 0.3),
			rgb(84, 80, 118):Lerp(rgb(130, 126, 164), ctx.Rng:NextNumber(0, 0.5)), MAT.SmoothPlastic, 0.1)
	end
	return main
end

-- swinging plank hung from an axle on two posts
function KB.PendulumPlatform(ctx, step, look)
	local h = step.Hazard or EMPTY
	local main = buildBase(ctx, step, look, { Name = "PendulumPlatform_" .. step.Index })
	if not (h.Hinge and h.Axis) then
		return main
	end
	local top = ctx.Origin + step.Pos
	local hinge = ctx.Origin + h.Hinge
	local axis = Vector3.new(h.Axis.X, 0, h.Axis.Z).Unit
	local bs = h.BeamSize or Vector3.new(8, h.Length or 6, 1)
	local len = bs.Y
	local beamCF = CFrame.fromMatrix(hinge - Vector3.new(0, len / 2, 0), axis, Vector3.new(0, 1, 0))
	local beam = mk(ctx, "Hazards", "PendulumBeam", "Part", bs, beamCF, C.Hazard, MAT.SmoothPlastic, { Solid = true })
	CollectionService:AddTag(beam, Tags.Pendulum)
	beam:SetAttribute("Hinge", hinge)
	beam:SetAttribute("Axis", axis)
	beam:SetAttribute("Period", h.Period or 3.4)
	beam:SetAttribute("Arc", h.Arc or 40)
	beam:SetAttribute("Damage", h.Damage or 20)
	-- anchored decor parented under the beam is swung along by HazardService
	ctx.Attach = { Mode = "child", Root = beam }
	for k = 1, 3 do
		blk(ctx, "Decor", "BeamStripe", Vector3.new(bs.X + 0.04, 0.9, bs.Z + 0.06),
			beamCF * CFrame.new(0, -len / 2 + k * len * 0.22, 0), C.Gold)
	end
	ball(ctx, "Decor", "BeamWeight", max(2.6, bs.Z * 3), beamCF * CFrame.new(0, -len / 2 + 1.0, 0), C.Hazard:Lerp(C.Iron, 0.5), MAT.Metal)
	ctx.Attach = nil
	-- static frame: axle + two posts
	local reach = bs.X / 2 + 0.9
	local ea, eb = hinge - axis * reach, hinge + axis * reach
	rod(ctx, "Decor", "Axle", ea, eb, 0.7, C.Iron, MAT.Metal)
	for _, e in ipairs({ ea, eb }) do
		ball(ctx, "Decor", "AxleCap", 1.2, CFrame.new(e), C.Brass, MAT.Metal)
		rod(ctx, "Decor", "Post", e, Vector3.new(e.X, top.Y, e.Z), 0.6, C.Iron:Lerp(C.Brass, 0.3), MAT.Metal)
	end
	return main
end

-- gust zone with painted wind arrows and a flag in the calm lee
function KB.WindPlatform(ctx, step, look)
	local h = step.Hazard or EMPTY
	local main, F = buildBase(ctx, step, look, { Name = "WindPlatform_" .. step.Index })
	local z = h.Zone
	if not z then
		return main
	end
	local dir = h.Direction or forwardOf(step)
	dir = Vector3.new(dir.X, 0, dir.Z)
	if dir.Magnitude < 0.01 then
		dir = forwardOf(step)
	end
	dir = dir.Unit
	local zy = rad(z.Yaw or 0)
	local lx = Vector3.new(cos(zy), 0, -sin(zy))
	local lz = Vector3.new(sin(zy), 0, cos(zy))
	local along = abs(dir:Dot(lx)) * z.Size.X + abs(dir:Dot(lz)) * z.Size.Z
	local across = abs(dir:Dot(lx)) * z.Size.Z + abs(dir:Dot(lz)) * z.Size.X
	local centre = ctx.Origin + z.Pos
	local vol = mk(ctx, "Hazards", "WindGust", "Part", z.Size,
		CFrame.new(centre + Vector3.new(0, z.Size.Y / 2, 0)) * CFrame.Angles(0, zy, 0), C.Wind, MAT.SmoothPlastic,
		{ Trigger = true, Transparency = 1 })
	CollectionService:AddTag(vol, Tags.WindGust)
	vol:SetAttribute("Force", h.Force or 18)
	vol:SetAttribute("Direction", dir)
	vol:SetAttribute("Interval", h.Interval or 5)
	vol:SetAttribute("Warning", h.Warning or 1.5)
	local n = max(1, min(4, floor(along / 2.8)))
	local armLen = max(1.3, min(2.4, across * 0.28))
	for k = 1, n do
		local off = (k - (n + 1) / 2) * (along / n)
		chevron(ctx, "Decor", "WindArrow", CFrame.new(centre + dir * off + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, yawOf(dir), 0),
			armLen, 0.32, C.Wind, MAT.Neon, 0.45)
	end
	-- flag in the lee
	local polePos = centre + dir * (along / 2 + 2.2)
	local top = ctx.Origin + step.Pos
	polePos = Vector3.new(polePos.X, top.Y, polePos.Z)
	cyl(ctx, "Decor", "FlagPole", 3.8, 0.25, CFrame.new(polePos + Vector3.new(0, 1.9, 0)), C.Iron:Lerp(C.Top, 0.4))
	local flagCF = CFrame.new(polePos + Vector3.new(0, 3.2, 0) + dir * 1.35) * CFrame.Angles(0, yawOf(dir) + pi / 2, 0)
	blk(ctx, "Decor", "WindFlag", Vector3.new(0.12, 0.9, 2.6), flagCF, look.Tint, MAT.SmoothPlastic)
	ball(ctx, "Decor", "FlagTop", 0.5, CFrame.new(polePos + Vector3.new(0, 3.9, 0)), C.Gold, MAT.Metal)
	return main
end

-- the cannon: iron plate with a brass disc (the tagged pad), a big tilted barrel behind it, wheels,
-- a fuse and a dotted flight arc to the landing island
function KB.CannonPad(ctx, step, look)
	local h = step.Hazard or EMPTY
	local main, F = buildBase(ctx, step, look, { Name = "CannonBase_" .. step.Index })
	if not (h.Target and h.Pos) then
		return main
	end
	local padR = h.PadRadius or 2.6
	local pc = ctx.Origin + h.Pos
	local target = ctx.Origin + h.Target
	local aim = h.Aim
	if not aim or aim.Magnitude < 0.01 then
		aim = Vector3.new(target.X - pc.X, 0, target.Z - pc.Z)
	end
	aim = Vector3.new(aim.X, 0, aim.Z).Unit
	local t = h.FlightTime or 1.3
	local padH = 0.8
	local padCF = CFrame.new(pc + Vector3.new(0, padH / 2, 0)) * CFrame.Angles(0, yawOf(aim), 0)
	local pad = mk(ctx, "Hazards", "CloudCannon", "Part", Vector3.new(padR * 2, padH, padR * 2), padCF, C.Iron, MAT.Metal,
		{ Solid = true })
	CollectionService:AddTag(pad, Tags.CloudCannon)
	pad:SetAttribute("Target", target)
	pad:SetAttribute("FlightTime", t)
	local deck = pc + Vector3.new(0, padH, 0)
	cyl(ctx, "Decor", "PadDisc", 0.08, padR * 1.84, CFrame.new(deck + Vector3.new(0, 0.04, 0)), C.Brass, MAT.Metal)
	cyl(ctx, "Decor", "PadGlowRing", 0.05, padR * 1.3, CFrame.new(deck + Vector3.new(0, 0.1, 0)), C.Gold, MAT.Neon, 0.3)
	cyl(ctx, "Decor", "PadCore", 0.06, padR * 1.1, CFrame.new(deck + Vector3.new(0, 0.12, 0)), C.Iron:Lerp(C.Brass, 0.25), MAT.Metal)
	for _, off in ipairs({ -0.2, 0.4 }) do
		chevron(ctx, "Decor", "LaunchArrow", CFrame.new(deck + aim * (padR * off) + Vector3.new(0, 0.16, 0)) *
			CFrame.Angles(0, yawOf(aim), 0), padR * 0.5, 0.3, C.Gold, MAT.Neon, 0.2)
	end
	addSparkles(pad, C.Gold, 4, 3, 1.4, 0.6)

	-- launch arc exactly as HazardService flies it: v = (T - R)/t + (0, g t / 2, 0) from the root
	local g = Phys.Gravity
	local root = deck + Vector3.new(0, CourseLayout.RootHeight or 3, 0)
	local v = (target - root) / t + Vector3.new(0, g * t / 2, 0)
	local elev = atan2(v.Y, sqrt(v.X * v.X + v.Z * v.Z))
	elev = max(rad(34), min(rad(62), elev))
	local d = aim * cos(elev) + Vector3.new(0, sin(elev), 0)

	-- barrel: sized to stay (almost) inside the platform behind the pad
	local D = max(2.4, min(3.6, padR * 1.15))
	local aimLocal = F:VectorToObjectSpace(aim)
	local edgeBack = min((step.Size.X / 2) / max(abs(aimLocal.X), 0.001), (step.Size.Z / 2) / max(abs(aimLocal.Z), 0.001))
	local back = padR * 0.9
	local L = max(3.8, min(7.0, (edgeBack + 1.0 - back) / cos(elev)))
	local mh = D * 0.45 + L * sin(elev)
	local muzzle = pc + Vector3.new(0, mh, 0) - aim * back
	local rear = muzzle - d * L
	local function along(s)
		return muzzle - d * s
	end
	mk(ctx, "Decor", "CannonBarrel", "Part", Vector3.new(L, D, D), axisCF(along(L / 2), d), C.Iron, MAT.Metal,
		{ Shape = Enum.PartType.Cylinder })
	ball(ctx, "Decor", "Breech", D * 1.08, CFrame.new(rear), C.Iron:Lerp(C.Ink, 0.4), MAT.Metal)
	mk(ctx, "Decor", "MuzzleRing", "Part", Vector3.new(0.9, D * 1.22, D * 1.22), axisCF(along(0.35), d), C.Brass, MAT.Metal,
		{ Shape = Enum.PartType.Cylinder })
	mk(ctx, "Decor", "MuzzleHole", "Part", Vector3.new(0.1, D * 0.82, D * 0.82), axisCF(muzzle + d * 0.04, d), rgb(24, 24, 34),
		MAT.SmoothPlastic, { Shape = Enum.PartType.Cylinder })
	for _, s in ipairs({ L * 0.36, L * 0.66 }) do
		mk(ctx, "Decor", "BarrelBand", "Part", Vector3.new(0.5, D * 1.1, D * 1.1), axisCF(along(s), d), C.Brass, MAT.Metal,
			{ Shape = Enum.PartType.Cylinder })
	end
	-- fuse
	local fuseBase = rear + Vector3.new(0, D * 0.5, 0)
	rod(ctx, "Decor", "Fuse", fuseBase, fuseBase + Vector3.new(0, 1.0, 0), 0.22, rgb(150, 120, 90))
	local spark = ball(ctx, "Decor", "FuseSpark", 0.6, CFrame.new(fuseBase + Vector3.new(0, 1.1, 0)), C.Lava, MAT.Neon, 0.05)
	addSparkles(spark, C.Lava, 6, 3, 0.8, 0.5)
	-- carriage and wheels
	local top = ctx.Origin + step.Pos
	local side = aim:Cross(Vector3.new(0, 1, 0)).Unit
	local mid = along(L * 0.5)
	local wheelY = top.Y + 1.3
	blk(ctx, "Decor", "Carriage", Vector3.new(D * 1.3, 0.6, L * 0.55),
		CFrame.new(mid.X, top.Y + 0.9, mid.Z) * CFrame.Angles(0, yawOf(aim), 0), C.Iron:Lerp(C.Brass, 0.2), MAT.Metal)
	for _, sgn in ipairs({ -1, 1 }) do
		local wp = Vector3.new(mid.X, wheelY, mid.Z) + side * (sgn * (D * 0.65 + 0.5))
		mk(ctx, "Decor", "Wheel", "Part", Vector3.new(0.6, 2.6, 2.6), CFrame.fromMatrix(wp, side, Vector3.new(0, 1, 0)),
			C.Iron:Lerp(C.Brass, 0.15), MAT.Metal, { Shape = Enum.PartType.Cylinder })
		ball(ctx, "Decor", "WheelHub", 0.9, CFrame.new(wp + side * (sgn * 0.3)), C.Brass, MAT.Metal)
	end
	-- dotted arc
	local dots = 7
	if ctx.Parts > ctx.UnderCap then
		dots = 4
	end
	for k = 1, dots do
		local s = t * k / (dots + 1)
		local p = root + v * s - Vector3.new(0, 0.5 * g * s * s, 0)
		ball(ctx, "Decor", "ArcDot", 0.75 - 0.035 * k, CFrame.new(p), C.Wind:Lerp(C.Text, 0.3), MAT.Neon, 0.45)
	end
	-- label
	local chip = hintTag(pad, 4.8, 100, C.Gold)
	hintLine(chip, "CANNON", "Accent", HINT_TITLE, C.Gold, 1)
	hintLine(chip, "step on to launch!", "Body", HINT_INFO, C.Text, 2)
	return main
end

-- co-op bridge: the far platform (this step) plus the retractable span and two plate islands
function KB.PlateBridge(ctx, step, look)
	local h = step.Hazard or EMPTY
	local main = buildBase(ctx, step, look, { Name = "BridgeLanding_" .. step.Index })
	local number = h.BridgeNumber or 1
	local color = BRIDGE_COLORS[((number - 1) % #BRIDGE_COLORS) + 1]
	local bridgeId = "bridge" .. tostring(number)
	local sp = h.Span
	if sp then
		local SF = CFrame.new(ctx.Origin + sp.Pos) * CFrame.Angles(0, rad(sp.Yaw or 0), 0)
		local span = mk(ctx, "Hazards", "PlateBridge", "Part", sp.Size, SF * CFrame.new(0, -sp.Size.Y / 2, 0),
			color:Lerp(C.Top, 0.3), MAT.SmoothPlastic, { Solid = true, Transparency = 0.1 })
		CollectionService:AddTag(span, Tags.PlateBridge)
		span:SetAttribute("BridgeId", bridgeId)
		-- decor under the span fades with it
		ctx.Attach = { Mode = "child", Root = span }
		for _, sgn in ipairs({ -1, 1 }) do
			blk(ctx, "Decor", "BridgeEdge", Vector3.new(0.25, 0.2, sp.Size.Z - 0.2), SF * CFrame.new(sgn * (sp.Size.X / 2 - 0.12), 0.1, 0),
				color, MAT.Neon, 0.15)
		end
		chevron(ctx, "Decor", "BridgeArrow", SF * CFrame.new(0, 0.08, sp.Size.Z * 0.12) * CFrame.Angles(0, 0, 0), 1.4, 0.3, color:Lerp(C.Text, 0.4),
			MAT.Neon, 0.3)
		ctx.Attach = nil
		-- ghost rails stay visible while the span is retracted
		for _, sgn in ipairs({ -1, 1 }) do
			blk(ctx, "Decor", "GhostRail", Vector3.new(0.2, 0.2, sp.Size.Z), SF * CFrame.new(sgn * (sp.Size.X / 2 - 0.1), 0.1, 0),
				color, MAT.Neon, 0.55)
		end
	end
	for i, side in ipairs(h.Sides or EMPTY) do
		local fake = {
			Index = step.Index, Stage = step.Stage, Kind = "Platform", Pos = side.Pos, Size = side.Size,
			Yaw = side.Yaw or step.Yaw, Variant = ((step.Variant or 1) + i) % 4 + 1,
		}
		local sideLook = {
			Top = look.Top, Side = look.Side, Mat = look.Mat, TopMat = look.TopMat, Trim = color,
			Tint = look.Tint,
		}
		buildBase(ctx, fake, sideLook, { Name = "PlateIsland_" .. step.Index .. "_" .. i })
		if side.Plate then
			local ps = side.Plate.Size
			local plate = mk(ctx, "Hazards", "PressurePlate", "Part", ps,
				CFrame.new(ctx.Origin + side.Plate.Pos - Vector3.new(0, ps.Y / 2, 0)) * CFrame.Angles(0, rad(side.Yaw or 0), 0),
				color, MAT.SmoothPlastic, { Solid = true })
			CollectionService:AddTag(plate, Tags.PressurePlate)
			plate:SetAttribute("BridgeId", bridgeId)
			addLight(plate, color, 12, 0.9)
			addSparkles(plate, color, 4, 5, 1.4, 0.7)
			-- dark ink on the lit plate colour: 5 - 7.7 : 1 (the soft white it used was only 1.8 : 1)
			local gui = surfaceOn(plate, Enum.NormalId.Top, 60)
			worldText(gui, "HOLD", "Heading", faceTextSize(plate, Enum.NormalId.Top, 60, 0.25), C.Ink, { 0, 0.2, 1, 0.6 })
			local sign = hintTag(plate, 3.7, 110, color)
			if i == 1 then
				hintLine(sign, "HOLD THE PLATE", "Accent", 28, color:Lerp(C.Text, 0.3), 1)
				hintLine(sign, "so your team can cross", "Body", HINT_INFO, C.Text, 2)
			else
				hintLine(sign, "HOLD TO LET THEM CROSS", "Accent", 28, color:Lerp(C.Text, 0.3), 1)
				hintLine(sign, "then everyone moves on", "Body", HINT_INFO, C.Text, 2)
			end
		end
	end
	return main
end

-- dash-only gap: gold-trimmed landing (the hint sits on the previous platform, see buildDashHint)
function KB.DashGap(ctx, step, look)
	local main = buildBase(ctx, step, look, { Name = "DashLanding_" .. step.Index })
	return main
end

----------------------------------------------------------------------
-- Start, checkpoint and finish
----------------------------------------------------------------------
-- dark rounded sign board standing at `localPos` (in the frame F), readable from its `face` side
local function buildBoard(ctx, F, localPos, face, title, body, accent)
	local cf = F * CFrame.new(localPos)
	local board = blk(ctx, "Signs", "InfoBoard", Vector3.new(0.4, 5.6, 8.6), cf, C.Panel, MAT.SmoothPlastic)
	for _, dz in ipairs({ -3.2, 3.2 }) do
		cyl(ctx, "Signs", "BoardLeg", 1.0, 0.5, F * CFrame.new(localPos.X, localPos.Y - 3.3, localPos.Z + dz), C.Iron, MAT.Metal)
	end
	-- 430 x 280 px canvas: a 1-stud title, then 0.6-stud body lines
	local gui = surfaceOn(board, face, 50)
	local panel = panelFrame(gui, 0.04)
	worldText(panel, title, "Title", 50, accent, { 0.03, 0.03, 0.94, 0.2 })
	local lines = worldText(panel, body, "Body", SIGN_INFO, C.Text, { 0.05, 0.27, 0.9, 0.69 }, nil, true)
	lines.TextYAlignment = Enum.TextYAlignment.Top
	lines.LineHeight = 1.12
end

-- Decor heights vs the Headroom CourseLayout reserves (nothing of another step may enter that space, so keep
-- every arch / flag / sign below it; CourseLayout.DECOR_HEAD must stay >= these tops, measured above the step top):
--   Start       arch pillars 12.5, StartBeam top 15.9, bunting top 17.0      Headroom 18
--   Checkpoint  flag poles 9.0, orbs 9.9, label from 10.0 (pixel-sized tag)  Headroom >= 13 (Config.Course.Clearance)
--   Finish      rainbow pillars 14.4, FinishBeam top 17.8                    Headroom 18
function KB.Start(ctx, step, look)
	local main, F = buildBase(ctx, step, look, { Name = "StartPlatform", Big = true })
	local trim = ctx.Trim
	-- glowing ring on the floor, where the party gathers
	cyl(ctx, "Decor", "StartRing", 0.05, 11.4, F * CFrame.new(0, 0.12, -3), trim, MAT.Neon, 0.45)
	cyl(ctx, "Decor", "StartRingInner", 0.05, 10.2, F * CFrame.new(0, 0.14, -3), look.Top)
	-- START arch over the way forward (local +Z is the first lane)
	local archZ = 9
	local half = 9.5
	for _, sgn in ipairs({ -1, 1 }) do
		cyl(ctx, "Decor", "ArchPillar", 12.5, 1.8, F * CFrame.new(sgn * half, 6.25, archZ), C.Top:Lerp(C.Side, 0.4))
		cyl(ctx, "Decor", "ArchBase", 1.2, 2.8, F * CFrame.new(sgn * half, 0.6, archZ), C.Side)
		ball(ctx, "Decor", "ArchCap", 2.4, F * CFrame.new(sgn * half, 13.3, archZ), trim, MAT.Neon, 0.1)
	end
	local beam = blk(ctx, "Signs", "StartBeam", Vector3.new(22, 3.4, 2), F * CFrame.new(0, 14.2, archZ), C.Panel)
	blk(ctx, "Decor", "StartGlow", Vector3.new(22, 0.25, 2.1), F * CFrame.new(0, 12.45, archZ), trim, MAT.Neon, 0.1)
	for k, c in ipairs(C.Rainbow) do
		ball(ctx, "Decor", "Bunting", 1.2, F * CFrame.new(-9 + (k - 1) * 3.6, 16.4, archZ), c)
	end
	local sub = ctx.Diff.DisplayName .. " - " .. tostring(ctx.Layout.Archetype or "Straight") .. " course"
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = surfaceOn(beam, face, 50) -- 1100 x 170 px: the title 2 studs tall, the line 0.72 stud
		local title = worldText(gui, "START", "Title", 100, C.Text, { 0, 0, 1, 0.66 })
		addGradient(title, C.Text, trim:Lerp(C.Text, 0.35))
		worldText(gui, sub, "Script", 36, trim:Lerp(C.Text, 0.4), { 0, 0.67, 1, 0.3 })
	end
	-- info boards on both sides
	buildBoard(ctx, F, Vector3.new(-11.4, 3.6, -3), Enum.NormalId.Right, "HOW TO CLIMB",
		"SHIFT  run\nSPACE  jump\nQ  dash (or tap DASH)\nGrab the floating clouds!", trim:Lerp(C.Text, 0.3))
	buildBoard(ctx, F, Vector3.new(11.4, 3.6, -3), Enum.NormalId.Left, "TEAMWORK",
		"Flags heal everyone and\nlift up downed friends.\nHold plates for bridges.\nNobody gets left behind!",
		C.Checkpoint:Lerp(C.Text, 0.3))
	return main
end

function KB.Checkpoint(ctx, step, look)
	local index = step.Stage
	local total = ctx.CheckpointTotal
	local main, F = buildBase(ctx, step, look, { Name = "Checkpoint_" .. index, Big = true })
	CollectionService:AddTag(main, Tags.Checkpoint)
	main:SetAttribute("CheckpointIndex", index)
	local sx, sz = step.Size.X, step.Size.Z
	local d = min(sx, sz) - 3.2
	local ring = cyl(ctx, "Decor", "CheckpointRing", 0.05, d, F * CFrame.new(0, 0.12, 0), C.Checkpoint, MAT.Neon, 0.35)
	cyl(ctx, "Decor", "CheckpointInner", 0.05, d - 1.2, F * CFrame.new(0, 0.14, 0), look.Top)
	addSparkles(ring, C.Checkpoint:Lerp(C.Text, 0.3), 5, 4, 1.8, 0.8)

	local orb
	local orbY = 9.3
	for i, sgn in ipairs({ -1, 1 }) do
		local px = sgn * (sx / 2 - 1.3)
		local pz = sz / 2 - 1.3
		cyl(ctx, "Decor", "FlagPole", 9, 0.5, F * CFrame.new(px, 4.5, pz), C.Top:Lerp(C.Gold, 0.3), MAT.Metal)
		local ballTop = ball(ctx, "Decor", "FlagTop", 1.2, F * CFrame.new(px, orbY, pz), C.Token, MAT.Neon, 0.1)
		addLight(ballTop, C.Token:Lerp(C.Text, 0.3), 14, 0.9)
		orb = orb or ballTop
		local banner = blk(ctx, "Signs", "FlagBanner", Vector3.new(4, 2.6, 0.15), F * CFrame.new(px - sgn * 2.2, 7.6, pz), C.Checkpoint)
		blk(ctx, "Decor", "BannerTrim", Vector3.new(4.1, 0.25, 0.2), F * CFrame.new(px - sgn * 2.2, 8.8, pz), look.Tint)
		for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
			local gui = surfaceOn(banner, face, 60)
			worldText(gui, tostring(index), "Display", faceTextSize(banner, face, 60, 0.7), C.Text, { 0, 0.05, 1, 0.9 })
		end
	end
	-- The label stands right on top of the orbs (bottom edge at the orb tops, 10.0) and grows upwards; it is
	-- pixel-sized (World text rule), so it reads the same from any distance.
	local labelBottom = orbY + 0.7
	local gui = hintTag(orb, labelBottom - orbY, 120, C.Checkpoint)
	hintLine(gui, "Checkpoint " .. index .. "/" .. total, "Title", 28, C.Text, 1)
	local nextStage = ctx.Layout.Stages and ctx.Layout.Stages[index + 1]
	local sub = "Final stretch - the finish is close!"
	if nextStage and nextStage.Name then
		sub = "Next: " .. nextStage.Name
	end
	hintLine(gui, sub, "Body", HINT_INFO, C.Checkpoint:Lerp(C.Text, 0.45), 2)
	return main
end

function KB.Finish(ctx, step, look)
	local main, F = buildBase(ctx, step, look, { Name = "FinishPlatform", Big = true })
	CollectionService:AddTag(main, Tags.FinishPad)
	local sz = step.Size.Z
	-- muted rainbow bullseye
	for k, c in ipairs(C.Rainbow) do
		local d = 26 - (k - 1) * 4
		cyl(ctx, "Decor", "GoalRing", 0.05, d, F * CFrame.new(0, 0.12 + (k - 1) * 0.03, 0), c, MAT.SmoothPlastic, 0.05)
	end
	local orb = ball(ctx, "Decor", "GoalOrb", 4.2, F * CFrame.new(0, 3.6, 0), C.Gold, MAT.Neon, 0.2)
	addLight(orb, C.Gold:Lerp(C.Text, 0.3), 28, 1.1)
	local confetti = addSparkles(orb, C.Text, 14, 14, 2.6, 1.0)
	local keys = {}
	for k, c in ipairs(C.Rainbow) do
		keys[#keys + 1] = ColorSequenceKeypoint.new((k - 1) / (#C.Rainbow - 1), c)
	end
	confetti.Color = ColorSequence.new(keys)
	confetti.SpreadAngle = Vector2.new(40, 40)
	confetti.EmissionDirection = Enum.NormalId.Top

	-- rainbow arch near the arrival edge (local -Z is where the route comes from)
	local archZ = -sz / 2 + 6
	local half = 11
	for _, sgn in ipairs({ -1, 1 }) do
		for k, c in ipairs(C.Rainbow) do
			cyl(ctx, "Decor", "ArchSegment", 2.4, 2.2, F * CFrame.new(sgn * half, 1.2 + (k - 1) * 2.4, archZ), c)
		end
	end
	local beam = blk(ctx, "Signs", "FinishBeam", Vector3.new(26, 3.6, 2), F * CFrame.new(0, 16, archZ), C.Panel)
	blk(ctx, "Decor", "FinishGlow", Vector3.new(26, 0.25, 2.1), F * CFrame.new(0, 14.1, archZ), C.Gold, MAT.Neon, 0.1)
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = surfaceOn(beam, face, 50) -- 1300 x 180 px: the title 2 studs tall, the line 0.72 stud
		local title = worldText(gui, "FINISH", "Title", 100, C.Text, { 0, 0.02, 1, 0.64 })
		addGradient(title, C.Gold:Lerp(C.Text, 0.4), C.Rainbow[1])
		worldText(gui, "you made it - together!", "Script", 36, C.Text, { 0, 0.67, 1, 0.3 })
	end
	local sign = hintTag(orb, 2.9, 120, C.Gold)
	hintLine(sign, "GOAL", "Title", HINT_TITLE, C.Gold:Lerp(C.Text, 0.25), 1)
	hintLine(sign, "wait here for your team", "Body", HINT_INFO, C.Text, 2)
	return main
end

----------------------------------------------------------------------
-- "DASH!" hint on the platform before a dash gap / plate bridge
----------------------------------------------------------------------
local function buildDashHint(ctx, step)
	local hint = step.DashHint
	if not (hint and hint.Pos) then
		return
	end
	local pos = ctx.Origin + hint.Pos
	local dir = hint.Dir
	if not dir or Vector3.new(dir.X, 0, dir.Z).Magnitude < 0.01 then
		dir = forwardOf(step)
	end
	dir = Vector3.new(dir.X, 0, dir.Z).Unit
	local yaw = yawOf(dir)
	-- Neon gold straight on the pale platform top is only 1.3 : 1, so the arrows are a deeper gold and sit on a dark
	-- outline (skipped when the part budget is nearly used up)
	local arrowColor = C.Gold:Lerp(C.Ink, 0.25)
	for k = 1, 3 do
		local tip = pos + dir * (0.4 - (k - 1) * 1.6) + Vector3.new(0, 0.14, 0)
		local cf = CFrame.new(tip) * CFrame.Angles(0, yaw, 0)
		if ctx.Parts <= ctx.UnderCap then
			chevron(ctx, "Decor", "DashArrowShadow", cf * CFrame.new(0, -0.02, 0), 2.3, 0.9, C.Ink, MAT.SmoothPlastic, 0.35)
		end
		chevron(ctx, "Decor", "DashArrow", cf, 2.2, 0.55, arrowColor, MAT.Neon, 0.05 + 0.1 * (k - 1))
	end
	local perp = Vector3.new(dir.Z, 0, -dir.X)
	local pole = pos + perp * 1.8
	rod(ctx, "Decor", "DashPole", pole, pole + Vector3.new(0, 4.6, 0), 0.25, C.Brass, MAT.Metal)
	local head = ball(ctx, "Decor", "DashBeacon", 0.9, CFrame.new(pole + Vector3.new(0, 4.8, 0)), C.Gold, MAT.Neon, 0.1)
	local gui = hintTag(head, 0.8, 110, C.Gold)
	hintLine(gui, "DASH!", "Accent", 32, C.Gold, 1)
	if step.Kind == "PlateBridge" then
		hintLine(gui, "or hold the plate for a bridge", "Body", HINT_INFO, C.Text, 2)
	else
		hintLine(gui, "press Q  or tap DASH", "Body", HINT_INFO, C.Text, 2)
	end
end

----------------------------------------------------------------------
-- Tokens (TokenService owns the visual)
----------------------------------------------------------------------
local function fallbackToken(ctx, pos, value)
	local golden = value >= (Config.Tokens.GoldenValue or 5)
	local size = golden and 3 or 2
	local p = mk(ctx, "Tokens", "CloudToken", "Part", Vector3.new(size, size, size), CFrame.new(pos), C.Token, MAT.Neon,
		{ Shape = Enum.PartType.Ball, Trigger = true, Free = true })
	p.CanTouch = true
	CollectionService:AddTag(p, Tags.CloudToken)
	if golden then
		CollectionService:AddTag(p, Tags.GoldenToken)
	end
	p:SetAttribute("Value", value)
	return p
end

-- returns the token VALUE total that was actually created
local function buildTokens(ctx)
	local TokenService = nil
	local okRequire, mod = pcall(function()
		return require(script.Parent.TokenService)
	end)
	if okRequire and type(mod) == "table" and type(mod.MakeTokenPart) == "function" then
		TokenService = mod
	else
		warn("[CourseBuilder] TokenService unavailable, using plain tokens: " .. tostring(mod))
	end
	local total = 0
	for _, step in ipairs(ctx.Layout.Steps) do
		for _, tok in ipairs(step.Tokens or EMPTY) do
			local value = tok.Value
			if type(value) ~= "number" then
				value = Config.Tokens.DefaultValue or 1
				if tok.Golden then
					value = Config.Tokens.GoldenValue or 5
				end
			end
			local pos = ctx.Origin + tok.Pos
			local part = nil
			if TokenService then
				local okMake, made = pcall(TokenService.MakeTokenPart, pos, ctx.Groups.Tokens, value)
				if okMake and typeof(made) == "Instance" then
					part = made
				end
			end
			if not part then
				part = fallbackToken(ctx, pos, value)
			end
			if not CollectionService:HasTag(part, Tags.CloudToken) then
				CollectionService:AddTag(part, Tags.CloudToken)
			end
			if value >= (Config.Tokens.GoldenValue or 5) and not CollectionService:HasTag(part, Tags.GoldenToken) then
				CollectionService:AddTag(part, Tags.GoldenToken)
			end
			total = total + value
		end
	end
	return total
end

----------------------------------------------------------------------
-- One step
----------------------------------------------------------------------
-- Last-resort geometry if a decorated builder errors: keep the course traversable and tagged.
local function buildFallback(ctx, step)
	local main = ctx.CurrentMain
	if not main then
		local look = lookFor(ctx, step)
		main = buildBase(ctx, step, look, { Name = "Cloud_" .. step.Index, Slab = true })
	end
	if step.Kind == "Checkpoint" then
		CollectionService:AddTag(main, Tags.Checkpoint)
		main:SetAttribute("CheckpointIndex", step.Stage)
	elseif step.Kind == "Finish" then
		CollectionService:AddTag(main, Tags.FinishPad)
	end
	return main
end

local function buildStep(ctx, step)
	ctx.Attach = nil
	ctx.CurrentMain = nil
	local builder = KB[step.Kind] or KB.Platform
	local ok, result = pcall(function()
		return builder(ctx, step, lookFor(ctx, step))
	end)
	ctx.Attach = nil
	if not ok then
		warn("[CourseBuilder] step " .. tostring(step.Index) .. " (" .. tostring(step.Kind) .. ") failed: " .. tostring(result))
		result = buildFallback(ctx, step)
	end
	if step.DashHint then
		local okHint, err = pcall(buildDashHint, ctx, step)
		if not okHint then
			warn("[CourseBuilder] dash hint " .. tostring(step.Index) .. " failed: " .. tostring(err))
		end
	end
	return result
end

----------------------------------------------------------------------
-- Scenery: one floating landmark per stage theme, the spiral's central pillar, distant cloud puffs.
-- Everything is decor (no collision / touch / query). Items arrive from layout.Scenery:
--   { Type, Stage, Pos = centre of the BASE, Yaw, Radius, Height, Seed, Tint }
-- Builders get (ctx, item, B, rng, col, lite): B is the base frame (Y up), `lite` asks for fewer parts.
----------------------------------------------------------------------
local G = "Scenery"
local LM = {}

local function worldPoint(B, x, y, z)
	return B:PointToWorldSpace(Vector3.new(x, y, z))
end

local function sceneryPalette(item)
	local tint = tintOf(item.Tint)
	return {
		Cloud = C.Top:Lerp(C.Side, 0.25),
		Shade = C.Side:Lerp(C.Shadow, 0.25),
		Soft = tint:Lerp(C.Top, 0.4),
		Tint = tint,
		Dark = tint:Lerp(C.Shadow, 0.55),
	}
end

-- windmill made of cloud drums with four sail blades
function LM.CloudWindmill(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local ht = H * 0.52
	local lb = max(5, min(R * 0.95, ht - 1.2, H - ht - 2.0))
	ball(ctx, G, "WindmillBase", Vector3.new(R * 1.5, R * 0.45, R * 1.5), B * CFrame.new(0, R * 0.225, 0), col.Cloud)
	local seg = ht / 3
	for k = 1, 3 do
		cyl(ctx, G, "WindmillTower", seg, R * (0.66 - 0.1 * k), B * CFrame.new(0, seg * (k - 0.5), 0),
			(k % 2 == 1) and col.Cloud or col.Soft)
	end
	blk(ctx, G, "WindmillDoor", Vector3.new(R * 0.14, R * 0.26, 0.4), B * CFrame.new(0, R * 0.13, R * 0.27), col.Dark)
	local hub = B * CFrame.new(0, ht + seg * 0.15, R * 0.22)
	ball(ctx, G, "WindmillHub", R * 0.26, hub, col.Tint)
	local spin = rng:NextNumber(0, pi / 2)
	for k = 0, 3 do
		local arm = hub * CFrame.Angles(0, 0, spin + k * pi / 2)
		blk(ctx, G, "BladeArm", Vector3.new(lb * 0.1, lb, lb * 0.1), arm * CFrame.new(0, lb / 2, 0), col.Shade)
		blk(ctx, G, "BladeSail", Vector3.new(lb * 0.34, lb * 0.62, 0.3), arm * CFrame.new(lb * 0.2, lb * 0.64, 0.15), col.Cloud)
		if not lite then
			ball(ctx, G, "BladeTip", lb * 0.16, arm * CFrame.new(0, lb, 0), col.Soft)
		end
	end
end

-- cluster of tall translucent crystals on a small rock
function LM.CrystalSpires(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	ball(ctx, G, "SpireRock", Vector3.new(R * 1.7, 3.6, R * 1.7), B * CFrame.new(0, 1.0, 0), col.Shade)
	local n = 6
	if lite then
		n = 4
	end
	for k = 1, n do
		local a = (k / n) * pi * 2 + rng:NextNumber(-0.3, 0.3)
		local r = R * rng:NextNumber(0.3, 0.6)
		local h = H * rng:NextNumber(0.6, 0.95)
		if k == 1 then
			r = 0
			h = H
		end
		local w = rng:NextNumber(2.2, 3.6)
		local tilt = rng:NextNumber(-0.08, 0.08)
		local cf = B * CFrame.new(cos(a) * r, 2.0, sin(a) * r) * CFrame.Angles(tilt, rng:NextNumber(0, pi), -tilt * 0.7)
		local bodyH = h * 0.75 - 2
		local crystal = col.Soft:Lerp(col.Tint, 0.45)
		blk(ctx, G, "Crystal", Vector3.new(w, bodyH, w * 0.8), cf * CFrame.new(0, bodyH / 2, 0), crystal, MAT.SmoothPlastic, 0.18)
		local tip = w * 0.95
		blk(ctx, G, "CrystalTip", Vector3.new(tip, tip, tip), cf * CFrame.new(0, bodyH + tip * 0.5, 0) * CFrame.Angles(pi / 4, 0, pi / 4),
			crystal, MAT.SmoothPlastic, 0.15)
		if not lite then
			blk(ctx, G, "CrystalCore", Vector3.new(0.35, bodyH * 0.9, 0.35), cf * CFrame.new(0, bodyH / 2, 0), col.Tint, MAT.Neon, 0.3)
		end
	end
end

-- striped hot-air balloon built from stacked discs
function LM.SkyBalloon(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local re = max(4, min(R * 0.95, (H - 7.5) / 2))
	local yc = 7 + re
	local layers = 11
	if lite then
		layers = 7
	end
	local cA = col.Tint:Lerp(C.Top, 0.15)
	local cB = C.Rainbow[((item.Seed or 1) % #C.Rainbow) + 1]:Lerp(C.Top, 0.1)
	for i = 1, layers do
		local u = -0.92 + (i - 1) * (1.84 / (layers - 1))
		local dia = 2 * re * sqrt(1 - u * u)
		local hgt = re * 1.84 / layers * 1.06 + 0.05
		cyl(ctx, G, "Envelope", hgt, dia, B * CFrame.new(0, yc + u * re, 0), (i % 2 == 1) and cA or cB)
	end
	ball(ctx, G, "BalloonCap", re * 0.18, B * CFrame.new(0, yc + re * 0.97, 0), col.Dark)
	blk(ctx, G, "Basket", Vector3.new(2.8, 1.8, 2.8), B * CFrame.new(0, 1.4, 0), rgb(150, 116, 92), MAT.WoodPlanks)
	for _, c in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
		rod(ctx, G, "Rope", worldPoint(B, c[1] * 1.3, 2.3, c[2] * 1.3), worldPoint(B, c[1] * re * 0.5, yc - re * 0.8, c[2] * re * 0.5),
			0.15, C.Iron)
	end
	local burner = ball(ctx, G, "Burner", 0.9, B * CFrame.new(0, 4.4, 0), C.Lava, MAT.Neon, 0.1)
	addLight(burner, C.Lava, 14, 0.8)
end

-- a muted rainbow arch standing on two clouds
function LM.RainbowArc(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local ro = max(8, min(R * 0.95, H - 1.0))
	local bands = 6
	if lite then
		bands = 4
	end
	local bw = 1.3
	for i = 1, bands do
		local ri = ro - (i - 0.5) * bw
		local n = max(8, ceil(pi * ri / 3.8))
		local chord = pi * ri / n * 1.1
		for j = 0, n - 1 do
			local phi = (j + 0.5) * pi / n
			blk(ctx, G, "RainbowBand", Vector3.new(chord, bw * 1.04, 2.0),
				B * CFrame.new(ri * cos(phi), ri * sin(phi), 0) * CFrame.Angles(0, 0, phi + pi / 2), C.Rainbow[i],
				MAT.SmoothPlastic, 0.05)
		end
	end
	local foot = ro - bands * bw / 2
	for _, s in ipairs({ -1, 1 }) do
		ball(ctx, G, "RainbowFoot", Vector3.new(8, 4, 6), B * CFrame.new(s * foot, 0.6, 0), col.Cloud)
		ball(ctx, G, "RainbowFoot", Vector3.new(5, 3, 4), B * CFrame.new(s * (foot + 2.6), 0.3, 1.4), col.Soft)
	end
end

-- big stone ring on a pedestal with a glowing core
function LM.GiantRing(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local rrOut = max(8, min(R * 0.95, H * 0.5 - 2.0))
	local rr = rrOut - 1.3
	local cy = H - rrOut - 0.3
	local n = 22
	if lite then
		n = 14
	end
	local chord = 2 * pi * rr / n * 1.12
	for j = 0, n - 1 do
		local phi = j * 2 * pi / n
		blk(ctx, G, "RingSegment", Vector3.new(chord, 2.6, 3.0),
			B * CFrame.new(rr * cos(phi), cy + rr * sin(phi), 0) * CFrame.Angles(0, 0, phi + pi / 2),
			(j % 2 == 0) and col.Cloud or col.Soft)
		if not lite then
			blk(ctx, G, "RingGlow", Vector3.new(chord * 0.9, 0.35, 0.4),
				B * CFrame.new((rr - 1.6) * cos(phi), cy + (rr - 1.6) * sin(phi), 0) * CFrame.Angles(0, 0, phi + pi / 2),
				col.Tint, MAT.Neon, 0.25)
		end
	end
	local core = ball(ctx, G, "RingCore", 2.4, B * CFrame.new(0, cy, 0), col.Tint, MAT.Neon, 0.3)
	addSparkles(core, col.Tint, 6, 4, 2, 0.8)
	if not lite then
		for k = 0, 3 do
			local phi = k * pi / 2 + pi / 4
			rod(ctx, G, "RingSpoke", worldPoint(B, 0, cy, 0), worldPoint(B, (rr - 1.6) * cos(phi), cy + (rr - 1.6) * sin(phi), 0),
				0.18, col.Tint, MAT.Neon, 0.5)
		end
	end
	local bottom = cy - rrOut
	cyl(ctx, G, "RingStand", bottom, 4.0, B * CFrame.new(0, bottom / 2, 0), col.Shade)
	ball(ctx, G, "RingBase", Vector3.new(R * 1.1, 3, R * 1.1), B * CFrame.new(0, 1, 0), col.Cloud)
end

-- dark tapering tower crowned with storm puffs and a red beacon
function LM.StormTower(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local bodyH = H * 0.7
	local drums = 6
	local h = bodyH / drums
	local stone = C.Storm:Lerp(C.Side, 0.2)
	for k = 1, drums do
		local dia = R * (0.95 - 0.09 * k)
		cyl(ctx, G, "TowerDrum", h, dia, B * CFrame.new(0, h * (k - 0.5), 0), (k % 2 == 1) and stone or stone:Lerp(C.Shadow, 0.3))
		if k >= 2 and not lite then
			for _, s in ipairs({ -1, 1 }) do
				blk(ctx, G, "TowerWindow", Vector3.new(0.9, 1.7, 0.5), B * CFrame.new(s * dia * 0.18, h * (k - 0.5), dia * 0.5),
					rgb(240, 208, 128), MAT.Neon, 0.15)
			end
		end
	end
	for k = 1, 4 do
		local a = k * pi / 2 + rng:NextNumber(-0.4, 0.4)
		ball(ctx, G, "TowerPuff", R * rng:NextNumber(0.55, 0.75),
			B * CFrame.new(cos(a) * R * 0.22, bodyH + 2 + rng:NextNumber(-0.5, 1.0), sin(a) * R * 0.22),
			C.Storm:Lerp(rgb(120, 130, 164), rng:NextNumber(0, 0.4)), MAT.SmoothPlastic, 0.08)
	end
	rod(ctx, G, "TowerSpire", worldPoint(B, 0, bodyH + 2, 0), worldPoint(B, 0, H - 1.5, 0), 0.7, C.Iron, MAT.Metal)
	local beacon = ball(ctx, G, "TowerBeacon", 1.6, B * CFrame.new(0, H - 1, 0), C.HazardGlow, MAT.Neon, 0.1)
	addLight(beacon, C.HazardGlow, 20, 1.0)
end

-- tall rods with glowing tips and little sparks between them
function LM.LightningRods(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local n = 5
	if lite then
		n = 3
	end
	local tips = {}
	for k = 1, n do
		local a = k * 2 * pi / n + rng:NextNumber(-0.3, 0.3)
		local r = R * 0.7
		local h = H * rng:NextNumber(0.55, 0.85)
		if k == 1 then
			r = 0
			h = H
		end
		local x, z = cos(a) * r, sin(a) * r
		cyl(ctx, G, "RodPole", h, 0.9, B * CFrame.new(x, h / 2, z), C.Iron, MAT.Metal)
		cyl(ctx, G, "RodBase", 1.4, 2.6, B * CFrame.new(x, 0.7, z), C.Iron:Lerp(C.Side, 0.3), MAT.Metal)
		for _, f in ipairs({ 0.4, 0.7 }) do
			cyl(ctx, G, "RodRing", 0.3, 2.2, B * CFrame.new(x, h * f, z), C.Brass, MAT.Metal)
		end
		local tip = ball(ctx, G, "RodTip", 1.7, B * CFrame.new(x, h + 0.6, z), rgb(236, 214, 130), MAT.Neon, 0.1)
		tips[#tips + 1] = worldPoint(B, x, h + 0.6, z)
		if k == 1 then
			addLight(tip, rgb(236, 214, 130), 22, 0.9)
		end
	end
	if not lite then
		for k = 1, #tips do
			local a, b = tips[k], tips[k % #tips + 1]
			local mid = (a + b) / 2 + Vector3.new(rng:NextNumber(-2, 2), rng:NextNumber(-2, 1), rng:NextNumber(-2, 2))
			rod(ctx, G, "RodSpark", a, mid, 0.16, rgb(190, 176, 240), MAT.Neon, 0.35)
			rod(ctx, G, "RodSpark", mid, b, 0.16, rgb(190, 176, 240), MAT.Neon, 0.35)
		end
	end
end

-- paper lanterns hanging from a little cloud
function LM.LanternCluster(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local cloudY = H - R * 0.35
	ball(ctx, G, "LanternCloud", Vector3.new(R * 1.7, R * 0.7, R * 1.7), B * CFrame.new(0, cloudY, 0), col.Cloud)
	ball(ctx, G, "LanternCloud", Vector3.new(R, R * 0.6, R), B * CFrame.new(R * 0.4, cloudY + R * 0.04, R * 0.2), col.Soft)
	local n = 9
	if lite then
		n = 5
	end
	for k = 1, n do
		local a = rng:NextNumber(0, 2 * pi)
		local r = R * rng:NextNumber(0.1, 0.8)
		local x, z = cos(a) * r, sin(a) * r
		local d = rng:NextNumber(2.2, 3.2)
		local y = rng:NextNumber(3 + d, cloudY - 4)
		rod(ctx, G, "LanternRope", worldPoint(B, x, cloudY - 0.6, z), worldPoint(B, x, y + d * 0.6, z), 0.12, C.Iron)
		local lamp = ball(ctx, G, "Lantern", Vector3.new(d, d * 1.2, d), B * CFrame.new(x, y, z),
			col.Tint:Lerp(C.Gold, rng:NextNumber(0.2, 0.7)), MAT.Neon, 0.15)
		cyl(ctx, G, "LanternCap", 0.35, d * 0.55, B * CFrame.new(x, y + d * 0.62, z), C.Iron, MAT.Metal)
		cyl(ctx, G, "LanternCap", 0.35, d * 0.55, B * CFrame.new(x, y - d * 0.62, z), C.Iron, MAT.Metal)
		if k <= 2 then
			addLight(lamp, col.Tint:Lerp(C.Gold, 0.5), 18, 0.7)
		end
	end
end

-- a small cloud castle: keep, four round towers, walls, gate, flag and two cannon barrels
function LM.CloudFortress(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	ball(ctx, G, "FortressBase", Vector3.new(R * 1.95, 4.4, R * 1.95), B * CFrame.new(0, 0.4, 0), col.Cloud)
	local y0 = 2.2
	local K = R * 0.7
	local Hk = H * 0.5
	blk(ctx, G, "Keep", Vector3.new(K, Hk, K), B * CFrame.new(0, y0 + Hk / 2, 0), col.Shade)
	blk(ctx, G, "KeepTop", Vector3.new(K * 1.1, 1.0, K * 1.1), B * CFrame.new(0, y0 + Hk + 0.5, 0), col.Cloud)
	local cren = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 }, { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
	for _, c in ipairs(cren) do
		blk(ctx, G, "Merlon", Vector3.new(K * 0.18, 1.4, K * 0.18),
			B * CFrame.new(c[1] * K * 0.46, y0 + Hk + 1.7, c[2] * K * 0.46), col.Cloud)
	end
	local tr = R * 0.58
	local td = R * 0.34
	local th = H * 0.7
	for _, cx in ipairs({ -1, 1 }) do
		for _, cz in ipairs({ -1, 1 }) do
			local x, z = cx * tr, cz * tr
			cyl(ctx, G, "FortTower", th, td, B * CFrame.new(x, y0 + th / 2, z), col.Cloud)
			cyl(ctx, G, "FortCornice", 1.1, td * 1.2, B * CFrame.new(x, y0 + th + 0.5, z), col.Shade)
			cyl(ctx, G, "FortRoof", 1.3, td * 0.85, B * CFrame.new(x, y0 + th + 1.7, z), col.Tint)
			cyl(ctx, G, "FortRoof", 1.3, td * 0.45, B * CFrame.new(x, y0 + th + 3.0, z), col.Tint:Lerp(C.Top, 0.2))
		end
	end
	local wl = 2 * tr - td
	local wh = H * 0.3
	blk(ctx, G, "FortWall", Vector3.new(wl, wh, 1.8), B * CFrame.new(0, y0 + wh / 2, tr), col.Cloud)
	blk(ctx, G, "FortWall", Vector3.new(wl, wh, 1.8), B * CFrame.new(0, y0 + wh / 2, -tr), col.Cloud)
	blk(ctx, G, "FortWall", Vector3.new(1.8, wh, wl), B * CFrame.new(tr, y0 + wh / 2, 0), col.Cloud)
	blk(ctx, G, "FortWall", Vector3.new(1.8, wh, wl), B * CFrame.new(-tr, y0 + wh / 2, 0), col.Cloud)
	blk(ctx, G, "FortGate", Vector3.new(R * 0.22, wh * 0.7, 0.5), B * CFrame.new(0, y0 + wh * 0.35, tr + 0.95), col.Dark)
	local top = worldPoint(B, 0, y0 + Hk + 2.2, 0)
	rod(ctx, G, "FortFlagPole", top, top + Vector3.new(0, H * 0.22, 0), 0.4, C.Iron, MAT.Metal)
	blk(ctx, G, "FortFlag", Vector3.new(0.15, 2.2, 3.4), B * CFrame.new(1.8, y0 + Hk + 2.2 + H * 0.22 - 1.4, 0), col.Tint)
	if not lite then
		for _, cx in ipairs({ -1, 1 }) do
			local base = worldPoint(B, cx * tr, y0 + th * 0.55, tr)
			local muzzle = worldPoint(B, cx * (tr + R * 0.04), y0 + th * 0.55 + 1.8, tr + R * 0.17)
			rod(ctx, G, "FortCannon", base, muzzle, 1.5, C.Iron, MAT.Metal)
			ball(ctx, G, "FortCannonMouth", 1.9, CFrame.new(muzzle), C.Brass, MAT.Metal)
		end
	end
end

-- a flock of diamond kites on long strings, tails of coloured beads
function LM.KiteFlock(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	ball(ctx, G, "KiteCloud", Vector3.new(R * 1.2, 3.2, R * 1.2), B * CFrame.new(0, 0.8, 0), col.Cloud)
	cyl(ctx, G, "KitePole", 3.6, 0.4, B * CFrame.new(0, 3.2, 0), C.Iron, MAT.Metal)
	local poleTop = worldPoint(B, 0, 5.2, 0)
	local n = 5
	if lite then
		n = 3
	end
	for k = 1, n do
		local a = (k / n) * 2 * pi + rng:NextNumber(-0.3, 0.3)
		local r = R * rng:NextNumber(0.3, 0.75)
		local y = H * rng:NextNumber(0.45, 0.9)
		local pos = Vector3.new(cos(a) * r, y, sin(a) * r)
		local s = rng:NextNumber(2.8, 3.8)
		local cf = B * CFrame.new(pos) * CFrame.Angles(-0.25, pi / 2 - a, 0)
		local color = C.Rainbow[((k + (item.Seed or 0)) % #C.Rainbow) + 1]
		blk(ctx, G, "Kite", Vector3.new(s, s, 0.15), cf * CFrame.Angles(0, 0, pi / 4), color, MAT.SmoothPlastic, 0.05)
		blk(ctx, G, "KiteSpar", Vector3.new(0.12, s * 1.42, 0.22), cf * CFrame.new(0, 0, 0.05), col.Dark)
		blk(ctx, G, "KiteSpar", Vector3.new(s * 1.42, 0.12, 0.22), cf * CFrame.new(0, 0, 0.05), col.Dark)
		local beads = 5
		if lite then
			beads = 3
		end
		for j = 1, beads do
			ball(ctx, G, "KiteTail", 0.5 + 0.06 * j, cf * CFrame.new(0.5 * sin(j * 1.3), -s * 0.8 - j * 0.9, -0.1),
				C.Rainbow[((j + k) % #C.Rainbow) + 1])
		end
		rod(ctx, G, "KiteString", worldPoint(B, pos.X, pos.Y - s * 0.7, pos.Z), poleTop, 0.1, C.Top, MAT.SmoothPlastic, 0.2)
	end
end

-- stone bell tower with a golden bell
function LM.BellTower(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local W = R * 0.9
	local hb = H * 0.46
	blk(ctx, G, "BellBase", Vector3.new(W, hb, W), B * CFrame.new(0, hb / 2, 0), col.Cloud)
	blk(ctx, G, "BellDoor", Vector3.new(W * 0.3, hb * 0.28, 0.4), B * CFrame.new(0, hb * 0.14, W / 2 + 0.1), col.Dark)
	if not lite then
		for _, s in ipairs({ -1, 1 }) do
			blk(ctx, G, "BellWindow", Vector3.new(0.9, 2.2, 0.4), B * CFrame.new(s * W * 0.24, hb * 0.62, W / 2 + 0.1),
				rgb(240, 208, 128), MAT.Neon, 0.2)
		end
	end
	blk(ctx, G, "BellLedge", Vector3.new(W * 1.15, 1.0, W * 1.15), B * CFrame.new(0, hb + 0.5, 0), col.Shade)
	local y0 = hb + 1.0
	local fh = H * 0.2
	for _, cx in ipairs({ -1, 1 }) do
		for _, cz in ipairs({ -1, 1 }) do
			cyl(ctx, G, "BelfryPillar", fh, 1.3, B * CFrame.new(cx * W * 0.38, y0 + fh / 2, cz * W * 0.38), col.Cloud)
		end
	end
	ball(ctx, G, "Bell", 3.0, B * CFrame.new(0, y0 + fh * 0.62, 0), C.Gold, MAT.Metal)
	cyl(ctx, G, "BellFlare", 1.0, 4.2, B * CFrame.new(0, y0 + fh * 0.62 - 1.5, 0), C.Gold, MAT.Metal)
	ball(ctx, G, "BellClapper", 0.8, B * CFrame.new(0, y0 + fh * 0.62 - 2.3, 0), C.Brass, MAT.Metal)
	blk(ctx, G, "BelfryBeam", Vector3.new(W * 0.9, 0.6, 0.6), B * CFrame.new(0, y0 + fh * 0.9, 0), col.Shade)
	local ry = y0 + fh
	blk(ctx, G, "BellRoof", Vector3.new(W * 1.2, 1.0, W * 1.2), B * CFrame.new(0, ry + 0.5, 0), col.Tint)
	blk(ctx, G, "BellRoof", Vector3.new(W * 0.9, 1.0, W * 0.9), B * CFrame.new(0, ry + 1.5, 0), col.Tint:Lerp(C.Top, 0.15))
	blk(ctx, G, "BellRoof", Vector3.new(W * 0.55, 1.0, W * 0.55), B * CFrame.new(0, ry + 2.5, 0), col.Tint:Lerp(C.Top, 0.3))
	rod(ctx, G, "BellSpire", worldPoint(B, 0, ry + 3, 0), worldPoint(B, 0, H - 0.8, 0), 0.4, C.Iron, MAT.Metal)
	ball(ctx, G, "BellFinial", 1.2, B * CFrame.new(0, H - 0.5, 0), C.Gold, MAT.Metal)
end

-- tapered obelisk with a glowing capstone, rune bars and floating rune stones
function LM.RuneObelisk(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local sizes = { R * 0.62, R * 0.46, R * 0.32 }
	local heights = { H * 0.32, H * 0.28, H * 0.22 }
	local y = 0
	for k = 1, 3 do
		blk(ctx, G, "Obelisk", Vector3.new(sizes[k], heights[k], sizes[k]), B * CFrame.new(0, y + heights[k] / 2, 0),
			(k % 2 == 1) and col.Shade or col.Cloud)
		y = y + heights[k]
	end
	local tip = ball(ctx, G, "Capstone", R * 0.34, B * CFrame.new(0, y + R * 0.2, 0), col.Tint, MAT.Neon, 0.15)
	addLight(tip, col.Tint, 20, 0.8)
	addSparkles(tip, col.Tint:Lerp(C.Text, 0.3), 5, 4, 2, 0.7)
	if not lite then
		for _, z in ipairs({ -1, 1 }) do
			local fz = z * (sizes[1] / 2 + 0.1)
			blk(ctx, G, "RuneBar", Vector3.new(0.3, heights[1] * 0.7, 0.2), B * CFrame.new(-sizes[1] * 0.2, heights[1] * 0.5, fz), col.Tint, MAT.Neon, 0.25)
			blk(ctx, G, "RuneBar", Vector3.new(0.3, heights[1] * 0.4, 0.2), B * CFrame.new(sizes[1] * 0.2, heights[1] * 0.45, fz), col.Tint, MAT.Neon, 0.25)
			blk(ctx, G, "RuneBar", Vector3.new(sizes[1] * 0.5, 0.3, 0.2), B * CFrame.new(0, heights[1] * 0.62, fz), col.Tint, MAT.Neon, 0.25)
		end
	end
	for k = 1, 3 do
		local a = k * 2 * pi / 3 + rng:NextNumber(-0.3, 0.3)
		local cf = B * CFrame.new(cos(a) * R * 0.85, H * (0.3 + 0.17 * k), sin(a) * R * 0.85) * CFrame.Angles(0, pi / 2 - a, rng:NextNumber(-0.15, 0.15))
		blk(ctx, G, "RuneStone", Vector3.new(1.8, 2.8, 0.7), cf, col.Dark)
		blk(ctx, G, "RuneGlyph", Vector3.new(0.3, 1.6, 0.2), cf * CFrame.new(0, 0, 0.4), col.Tint, MAT.Neon, 0.2)
	end
end

-- a big gate with a glowing ring in its opening
function LM.SkyGate(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local px = R * 0.62
	local ph = H * 0.78
	for _, s in ipairs({ -1, 1 }) do
		cyl(ctx, G, "GateBase", 1.6, 5.0, B * CFrame.new(s * px, 0.8, 0), col.Shade)
		cyl(ctx, G, "GatePillar", ph, 3.6, B * CFrame.new(s * px, ph / 2, 0), col.Cloud)
		cyl(ctx, G, "GateCapital", 1.2, 5.0, B * CFrame.new(s * px, ph + 0.6, 0), col.Shade)
	end
	local ly = ph + 1.2 + 1.6
	blk(ctx, G, "GateLintel", Vector3.new(px * 2 + 5, 3.2, 3.6), B * CFrame.new(0, ly, 0), col.Cloud)
	blk(ctx, G, "GateCrest", Vector3.new(px * 0.9, 1.8, 3.0), B * CFrame.new(0, ly + 2.5, 0), col.Tint)
	for k = -1, 1 do
		blk(ctx, G, "GateEmblem", Vector3.new(1.4, 1.4, 0.4), B * CFrame.new(k * 3.4, ly, 1.9) * CFrame.Angles(0, 0, pi / 4), C.Gold, MAT.Neon, 0.2)
	end
	local rr = R * 0.4
	local cy = ph * 0.52
	local n = 16
	if lite then
		n = 10
	end
	for j = 0, n - 1 do
		local phi = j * 2 * pi / n
		blk(ctx, G, "GateRing", Vector3.new(2 * pi * rr / n * 1.1, 0.7, 0.6),
			B * CFrame.new(rr * cos(phi), cy + rr * sin(phi), 0) * CFrame.Angles(0, 0, phi + pi / 2), col.Tint, MAT.Neon, 0.25)
	end
	local core = ball(ctx, G, "GateCore", 1.6, B * CFrame.new(0, cy, 0), col.Tint, MAT.Neon, 0.35)
	addSparkles(core, col.Tint:Lerp(C.Text, 0.3), 6, 4, 2, 0.7)
end

-- floating rock island with a smoking volcano
function LM.FloatingVolcano(ctx, item, B, rng, col, lite)
	local R, H = item.Radius, item.Height
	local rock = C.Rock
	for k = 1, 6 do
		local hk = H * 0.07
		cyl(ctx, G, "VolcanoRock", hk, R * 2 * (0.14 + 0.15 * k), B * CFrame.new(0, hk * (k - 0.5), 0),
			rock:Lerp(C.Shadow, (6 - k) * 0.06), MAT.Slate)
	end
	local y0 = H * 0.42
	local ch = H * 0.09
	for k = 1, 5 do
		cyl(ctx, G, "VolcanoCone", ch, R * (1.9 - 0.34 * (k - 1)), B * CFrame.new(0, y0 + ch * (k - 0.5), 0),
			rock:Lerp(C.Hazard, 0.08 * k), MAT.Slate)
	end
	local topY = y0 + ch * 5
	local lava = cyl(ctx, G, "VolcanoLava", 0.5, R * 0.52, B * CFrame.new(0, topY + 0.2, 0), C.Lava, MAT.Neon, 0.1)
	addLight(lava, C.Lava, 24, 1.0)
	addSmoke(lava, rgb(110, 108, 124), 4, R * 0.5)
	addSparkles(lava, C.Lava, 6, 8, 1.6, 0.6)
	if not lite then
		for k = 1, 3 do
			local a = k * 2 * pi / 3 + rng:NextNumber(-0.4, 0.4)
			rod(ctx, G, "LavaStreak", worldPoint(B, cos(a) * R * 0.2, topY, sin(a) * R * 0.2),
				worldPoint(B, cos(a) * R * 0.78, y0 + ch * 0.6, sin(a) * R * 0.78), 0.55, C.Lava, MAT.Neon, 0.2)
		end
	end
end

-- the spiral's central column: soft cloud pillar with glowing slits and tinted bands
function LM.CentralPillar(ctx, item, B, rng, col, lite)
	local r, height = item.Radius, item.Height
	local body = C.Side:Lerp(C.Shadow, 0.3)
	cyl(ctx, G, "Pillar", height, r * 2, B * CFrame.new(0, height / 2, 0), body)
	local bands = min(10, floor(height / 18))
	for k = 1, bands do
		cyl(ctx, G, "PillarBand", 1.4, r * 2 + 1.6, B * CFrame.new(0, height * k / (bands + 1), 0),
			(k % 2 == 1) and col.Soft or col.Tint:Lerp(C.Shadow, 0.3))
	end
	if not lite then
		for k = 0, 3 do
			local a = k * pi / 2 + pi / 4
			blk(ctx, G, "PillarSlit", Vector3.new(0.5, height * 0.6, 0.35),
				B * CFrame.new(cos(a) * (r + 0.1), height * 0.5, sin(a) * (r + 0.1)) * CFrame.Angles(0, pi / 2 - a, 0),
				col.Tint, MAT.Neon, 0.55)
		end
	end
	ball(ctx, G, "PillarCrown", Vector3.new(r * 3.2, r * 1.2, r * 3.2), B * CFrame.new(0, height, 0), col.Cloud)
	ball(ctx, G, "PillarFoot", Vector3.new(r * 3.6, r * 1.4, r * 3.6), B * CFrame.new(0, 0, 0), col.Cloud)
end

-- distant cloud puff / part of the cloud sea below the route
function LM.Puff(ctx, item, B, rng, col, lite)
	local r = item.Radius
	local cloud = C.Top:Lerp(C.Side, 0.4)
	local trans = rng:NextNumber(0.18, 0.32)
	ball(ctx, G, "FarCloud", Vector3.new(r * 2, r * 1.1, r * 1.7), B * CFrame.new(0, r * 0.3, 0), cloud, MAT.SmoothPlastic, trans)
	local bumps = 2
	if lite then
		bumps = 1
	end
	for k = 1, bumps do
		local s = r * rng:NextNumber(0.8, 1.1)
		ball(ctx, G, "FarCloud", Vector3.new(s, s * 0.7, s * 0.9),
			B * CFrame.new((k == 1 and -1 or 1) * r * 0.6, r * 0.38, rng:NextNumber(-0.3, 0.3) * r), cloud:Lerp(C.Top, 0.25),
			MAT.SmoothPlastic, trans)
	end
end

local function buildScenery(ctx)
	local items = ctx.Layout.Scenery
	if type(items) ~= "table" then
		return
	end
	for _, item in ipairs(items) do
		local fn = LM[item.Type]
		if fn and item.Pos and ctx.Parts < ctx.Cap then
			local B = CFrame.new(ctx.Origin + item.Pos) * CFrame.Angles(0, rad(item.Yaw or 0), 0)
			local rng = Random.new(item.Seed or 1)
			ctx.Attach = nil
			local ok, err = pcall(fn, ctx, item, B, rng, sceneryPalette(item), ctx.Parts > ctx.LiteCap)
			ctx.Attach = nil
			if not ok then
				warn("[CourseBuilder] scenery " .. tostring(item.Type) .. " failed: " .. tostring(err))
			end
		end
	end
end

----------------------------------------------------------------------
-- Build
----------------------------------------------------------------------
local function difficultyTrim(diff, tier)
	local trims = WORLD.Trim
	if type(trims) == "table" then
		local v = trims[diff.Id]
		if typeof(v) ~= "Color3" then
			v = trims[tier]
		end
		if typeof(v) == "Color3" then
			return v
		end
	end
	return diff.Color
end

-- CFrame on top of a step, `up` studs above the surface, looking along the step's direction of travel.
local function spawnOn(ctx, step, up, back)
	local fwd = forwardOf(step)
	local p = ctx.Origin + step.Pos + Vector3.new(0, up, 0) - fwd * (back or 0)
	return CFrame.new(p, p + fwd)
end

-- Only used when the layout generator hands back an empty layout: a start and a finish platform so
-- the match flow still has something to stand on.
local function buildStub(ctx, info)
	local start = {
		Index = 1, Stage = 0, Kind = "Start", Pos = Vector3.new(0, 0, 0), Size = Vector3.new(26, 2, 26), Yaw = 0, Variant = 1,
	}
	local finish = {
		Index = 2, Stage = 1, Kind = "Finish", Pos = Vector3.new(0, 0, 31), Size = Vector3.new(30, 2, 30), Yaw = 0, Variant = 1,
	}
	ctx.Layout.Steps = { start, finish }
	buildStep(ctx, start)
	info.Finish = buildStep(ctx, finish)
	info.StartCFrame = spawnOn(ctx, start, 3.5, 3)
	info.TotalSteps = 2
end

function CourseBuilder.Build(layout, origin, parent)
	origin = origin or Vector3.new(0, 0, 0)
	parent = parent or Workspace
	layout = layout or {}
	local diff = Config.GetDifficulty(layout.DifficultyId) or Config.Difficulties[1]
	local tier = 1
	for i, d in ipairs(Config.Difficulties) do
		if d.Id == diff.Id then
			tier = i
		end
	end
	layout.Steps = layout.Steps or {}
	local steps = layout.Steps

	local folder = Instance.new("Folder")
	folder.Name = "Course_" .. tostring(layout.Seed)
	folder:SetAttribute("DifficultyId", diff.Id)
	folder:SetAttribute("Archetype", tostring(layout.Archetype or ""))
	local groups = {}
	for _, name in ipairs({ "Platforms", "Hazards", "Decor", "Signs", "Tokens", "Scenery" }) do
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = folder
		groups[name] = f
	end

	local tokenCount = layout.TokenCount
	if type(tokenCount) ~= "number" then
		tokenCount = 0
		for _, s in ipairs(steps) do
			tokenCount = tokenCount + #(s.Tokens or EMPTY)
		end
	end
	local checkpointTotal = 0
	for _, s in ipairs(steps) do
		if s.Kind == "Checkpoint" then
			checkpointTotal = checkpointTotal + 1
		end
	end

	local cap = PART_LIMIT - tokenCount * TOKEN_PARTS
	local ctx = {
		Layout = layout,
		Origin = origin,
		Diff = diff,
		Trim = difficultyTrim(diff, tier),
		Folder = folder,
		Groups = groups,
		Welds = {},
		Parts = 0,
		Attach = nil,
		CurrentMain = nil,
		CheckpointTotal = max(checkpointTotal, 1),
		Rng = Random.new((layout.Seed or 0) * 7 + 13),
		Cap = cap, -- scenery stops here
		LiteCap = cap - 250, -- landmarks get simpler past this
		UnderCap = cap - 380, -- platform undersides get simpler past this
	}

	local info = {
		Folder = folder,
		Checkpoints = {},
		TotalTokens = layout.TotalTokens or 0,
		TotalSteps = #steps,
		KillY = origin.Y - 60,
		Archetype = layout.Archetype,
		Themes = layout.Themes,
	}

	for _, step in ipairs(steps) do
		local main = buildStep(ctx, step)
		if step.Kind == "Start" then
			info.StartCFrame = spawnOn(ctx, step, 3.5, 3)
		elseif step.Kind == "Checkpoint" then
			info.Checkpoints[step.Stage] = {
				Part = main,
				Index = step.Stage,
				SpawnCFrame = spawnOn(ctx, step, 3.5, 0),
				Stage = step.Stage,
			}
		elseif step.Kind == "Finish" then
			info.Finish = main
		end
	end
	if #steps == 0 or not info.StartCFrame or not info.Finish then
		warn("[CourseBuilder] layout without start / finish for " .. tostring(layout.DifficultyId) .. " seed " .. tostring(layout.Seed))
		if #steps == 0 then
			buildStub(ctx, info)
		end
		info.StartCFrame = info.StartCFrame or CFrame.new(origin + Vector3.new(0, 5, 0))
	end

	buildScenery(ctx)

	-- parent once, then do everything that needs the parts to live in the world
	folder.Parent = parent
	applyWelds(ctx)
	local okTokens, tokenTotal = pcall(buildTokens, ctx)
	if okTokens then
		info.TotalTokens = tokenTotal
	else
		warn("[CourseBuilder] tokens failed: " .. tostring(tokenTotal))
	end
	return info
end

return CourseBuilder
