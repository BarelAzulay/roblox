-- LobbyBuilder (v2): procedurally builds the Nimbus Climb cloud village at Config.Lobby.Origin.
--
-- Top view (+X right, +Z up the page, angles in degrees: x = cos, z = sin, plaza centre = Origin):
--
--   * PLAZA          a grand round cloud (radius ~116) with a medallion, paths, benches, lantern trees,
--                    a muted rainbow arch with the welcome board, and two info boards.
--   * PORTAL GATES   one per Config.Difficulties entry (Easy..Saint) spread over the +Z half of the
--                    plaza at radius Config.Lobby.PortalRingRadius, each in its difficulty colour with a
--                    3D star row and a billboard (title, stars, party count, status, blurb).
--   * SHOP ISLAND    south of the plaza (Config.Lobby.ShopOffset): four roulette machines (colour =
--                    roulette colour), an item-shop stall, a rarity guide board and decor.
--   * RING ROAD      a wide cloud promenade (radius ~168) around the village. Six spokes join it to the
--                    plaza; its two ends dock into the shop island.
--   * SPOT ISLANDS   Config.Lobby.SpotCount personal cloud homes on the outer ring, each reached by a
--                    short ramp from the ring road: home pad, nameplate, showcase podium, bench, lantern.
--   * DECOR ISLANDS  small gardens behind the portals, joined to the ring road by short planks.
--   * SKY            drifting clouds, a far cloud sea, fireflies and sparkle dust.
--
-- Walkability rules (so nobody gets stuck): every connection is a gently sloped slab, never a gap
-- bigger than a step; connecting slabs sit 0.06-0.16 studs BELOW the surface they dock into and end
-- inside it (no coplanar overlaps, no z-fighting); nothing needs more than a plain walk.
--
-- No external assets: Parts, ParticleEmitters (built-in textures) and Theme-styled GUI text.
-- Plain Lua 5.1-compatible syntax only. Everything is deterministic (seeded Random).
-- ProximityPrompts are NOT created here: PetService / ItemService attach them to the PromptParts.
--
-- Robustness: portals, spots, the shop machines and the item stall are the objects other services
-- depend on. Each is built inside pcall with a bare-bones fallback that still returns the same
-- LobbyInfo shape, and all pure decoration runs in guarded sections, so one scenery bug can never
-- take the whole lobby (or the game boot) down.

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)
local Util = require(Shared.Util)

local LobbyBuilder = {}

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

local LOBBY = Config.Lobby
local ORIGIN = LOBBY.Origin
local TOP = ORIGIN.Y -- y of the plaza walking surface
local SURF_R = LOBBY.PlazaRadius + 6 -- the cloud disc reaches a bit past PlazaRadius
local PORTAL_R = LOBBY.PortalRingRadius
local SPOT_R = LOBBY.SpotRingRadius
local SPOT_COUNT = LOBBY.SpotCount
local SEED = 20250117

local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"
local MAT = Enum.Material

-- Glyphs as UTF-8 byte escapes (keeps the source file ASCII).
local STAR_FULL = "\226\152\133"
local STAR_EMPTY = "\226\152\134"
local CLOUD_GLYPH = "\226\152\129"
local BULLET = "\226\128\162"
local ELLIPSIS = "\226\128\166"

local function atan2(y, x)
	if math.atan2 then
		return math.atan2(y, x)
	end
	return math.atan(y, x)
end

----------------------------------------------------------------------
-- Palette: Theme.World when the uikit agent provides it, calm fallbacks otherwise.
-- Nothing here is pure white; neon is only used on small accents.
----------------------------------------------------------------------

local function pickColor(value, fallback)
	if typeof(value) == "Color3" then
		return value
	end
	return fallback
end

local World = Theme.World
if type(World) ~= "table" then
	World = {}
end
local ThemeColors = Theme.Colors or {}

-- Whatever the theme says, no world surface may get brighter than `limit` on any channel
-- (keeps the lobby calm even if Theme.World is ever tuned too bright).
local function capBright(color, limit)
	local peak = math.max(color.R, color.G, color.B) * 255
	if peak > limit then
		local k = limit / peak
		return Color3.new(color.R * k, color.G * k, color.B * k)
	end
	return color
end

local COL = {}
COL.Top = capBright(pickColor(World.CloudTop, Color3.fromRGB(190, 204, 228)), 214)
COL.Side = capBright(pickColor(World.CloudSide, Color3.fromRGB(156, 172, 204)), 184)
COL.Shadow = capBright(pickColor(World.CloudShadow, Color3.fromRGB(120, 138, 178)), 150)
COL.Gold = capBright(pickColor(World.Token, Color3.fromRGB(226, 182, 84)), 232)
COL.Ink = pickColor(ThemeColors.Ink, Color3.fromRGB(34, 40, 72))
COL.Puff = COL.Top:Lerp(COL.Side, 0.18)
COL.Dusk = COL.Side:Lerp(Color3.fromRGB(118, 110, 170), 0.35)
COL.Path = Color3.fromRGB(196, 176, 152)
COL.Wood = Color3.fromRGB(150, 110, 82)
COL.WoodLight = Color3.fromRGB(176, 136, 102)
COL.WoodDark = Color3.fromRGB(104, 76, 60)
COL.Stem = Color3.fromRGB(98, 170, 122)
COL.Lantern = Color3.fromRGB(238, 188, 108)
COL.GoldDark = COL.Gold:Lerp(Color3.fromRGB(120, 80, 40), 0.35)
COL.Navy = Color3.fromRGB(34, 42, 76)
COL.Violet = Color3.fromRGB(68, 60, 118)
COL.Post = Color3.fromRGB(76, 70, 112)
COL.Slate = Color3.fromRGB(58, 66, 100)
COL.Water = Color3.fromRGB(96, 160, 214)
COL.WaterBed = Color3.fromRGB(70, 128, 196)
COL.Text = Color3.fromRGB(238, 243, 252) -- light text colour (GUI text only)
COL.TextDim = Color3.fromRGB(176, 190, 222)
COL.TextGold = Color3.fromRGB(244, 214, 132)
COL.StarOff = Color3.fromRGB(88, 96, 128)

-- Muted rainbow (arch + medallion).
local RAINBOW = {
	Color3.fromRGB(196, 92, 102),
	Color3.fromRGB(214, 142, 84),
	Color3.fromRGB(212, 190, 98),
	Color3.fromRGB(108, 170, 128),
	Color3.fromRGB(92, 144, 200),
	Color3.fromRGB(140, 116, 196),
}

local BLOSSOMS = {
	Color3.fromRGB(226, 170, 196),
	Color3.fromRGB(230, 190, 160),
	Color3.fromRGB(170, 210, 186),
	Color3.fromRGB(186, 176, 226),
}

local FLOWER_COLORS = {
	Color3.fromRGB(226, 140, 170),
	Color3.fromRGB(232, 196, 108),
	Color3.fromRGB(170, 150, 226),
	Color3.fromRGB(226, 130, 126),
	Color3.fromRGB(130, 190, 226),
	Color3.fromRGB(230, 214, 150),
}

-- One accent colour per spot (cycled): it tints the pad, podium and banner so a spot is easy to find.
local ACCENTS = {
	Color3.fromRGB(214, 120, 134),
	Color3.fromRGB(224, 160, 96),
	Color3.fromRGB(214, 196, 104),
	Color3.fromRGB(116, 184, 140),
	Color3.fromRGB(98, 176, 196),
	Color3.fromRGB(108, 148, 214),
	Color3.fromRGB(150, 126, 210),
	Color3.fromRGB(200, 128, 184),
}

----------------------------------------------------------------------
-- Per-build state
----------------------------------------------------------------------

local partCount = 0
local activeTweens = {}
local animQueue = {}

-- Animations are queued while building and started once the lobby is parented to Workspace.
local function later(fn)
	animQueue[#animQueue + 1] = fn
end

local function stopAnimations()
	for _, tween in ipairs(activeTweens) do
		pcall(function()
			tween:Cancel()
		end)
	end
	activeTweens = {}
	animQueue = {}
end

local function loopTween(inst, seconds, goal, style, reverses)
	local info = TweenInfo.new(
		seconds,
		style or Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut,
		-1,
		reverses ~= false,
		0
	)
	local tween = TweenService:Create(inst, info, goal)
	tween:Play()
	activeTweens[#activeTweens + 1] = tween
	return tween
end

----------------------------------------------------------------------
-- Primitive builders
----------------------------------------------------------------------

local function merge(dst, src)
	if src then
		for key, value in pairs(src) do
			dst[key] = value
		end
	end
	return dst
end

local function newFolder(parent, name)
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Anchored smooth-plastic part with sane defaults; props override anything.
local function mk(parent, props, className)
	local all = {
		Anchored = true,
		Material = MAT.SmoothPlastic,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
		CastShadow = false,
		Parent = parent,
	}
	merge(all, props)
	partCount = partCount + 1
	return Util.Create(className or "Part", all)
end

local function block(parent, cf, size, props)
	return mk(parent, merge({ CFrame = cf, Size = size }, props))
end

-- Upright cylinder (axis = world Y). pos = centre; "thickness" is its height.
local function disc(parent, pos, diameter, thickness, props)
	return mk(
		parent,
		merge({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(thickness, diameter, diameter),
			CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90)),
		}, props)
	)
end

-- Cylinder whose flat faces look along the local Z axis of `cf` (a wheel standing on its edge).
local function faceDisc(parent, cf, diameter, thickness, props)
	return mk(
		parent,
		merge({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(thickness, diameter, diameter),
			CFrame = cf * CFrame.Angles(0, math.rad(90), 0),
		}, props)
	)
end

local function ball(parent, pos, diameter, props)
	return mk(
		parent,
		merge({
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(diameter, diameter, diameter),
			CFrame = CFrame.new(pos),
		}, props)
	)
end

-- Point on the lobby at polar coordinates around the plaza centre (degrees).
local function polar(angleDeg, radius, y)
	local a = math.rad(angleDeg)
	return Vector3.new(ORIGIN.X + math.cos(a) * radius, y or TOP, ORIGIN.Z + math.sin(a) * radius)
end

local function angleDiff(a, b)
	local d = math.abs((a - b) % 360)
	if d > 180 then
		d = 360 - d
	end
	return d
end

local function nearAny(angle, list, half)
	if list then
		for _, other in ipairs(list) do
			if angleDiff(angle, other) < half then
				return true
			end
		end
	end
	return false
end

-- Flat horizontal perpendicular of a direction (for lining things up along a slab).
local function perpendicular(dir)
	local flat = Vector3.new(-dir.Z, 0, dir.X)
	if flat.Magnitude < 0.001 then
		return Vector3.new(1, 0, 0)
	end
	return flat.Unit
end

-- A tilted block between two points on its TOP surface (centres of the top face at both ends).
-- The slab hangs `thick` below the line; used for ramps, bridges and road segments.
local function slab(parent, a, b, width, thick, props)
	local dir = b - a
	local mid = (a + b) * 0.5
	local look = CFrame.lookAt(mid, mid + dir)
	return mk(
		parent,
		merge({
			CFrame = look * CFrame.new(0, -thick * 0.5, 0),
			Size = Vector3.new(width, thick, dir.Magnitude),
		}, props)
	)
end

----------------------------------------------------------------------
-- Effects helpers
----------------------------------------------------------------------

local FADE_IN_OUT = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.25, 0.2),
	NumberSequenceKeypoint.new(0.75, 0.2),
	NumberSequenceKeypoint.new(1, 1),
})

local function popSize(maxSize)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, maxSize),
		NumberSequenceKeypoint.new(1, 0),
	})
end

-- Sparkle ParticleEmitter with soft defaults; `props` overrides anything.
local function emitter(parent, props)
	local e = Instance.new("ParticleEmitter")
	e.Texture = SPARKLES
	e.Color = ColorSequence.new(COL.TextGold)
	e.LightEmission = 0.6
	e.LightInfluence = 0
	e.Rate = 6
	e.Lifetime = NumberRange.new(1.5, 2.5)
	e.Speed = NumberRange.new(1, 2)
	e.Size = popSize(0.7)
	e.Transparency = FADE_IN_OUT
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-60, 60)
	merge(e, props)
	e.Parent = parent
	return e
end

local function pointLight(parent, color, brightness, range)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Brightness = brightness
	l.Range = range
	l.Shadows = false
	l.Parent = parent
	return l
end

-- Invisible part used to host emitters / billboards.
local function anchorPart(parent, name, pos, size)
	return mk(parent, {
		Name = name,
		Size = size or Vector3.new(1, 1, 1),
		CFrame = CFrame.new(pos),
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
	})
end

----------------------------------------------------------------------
-- GUI helpers (all text goes through Theme roles)
----------------------------------------------------------------------

-- World-sized billboard: Size is in studs, so it shrinks with distance like the thing it labels.
local function newBillboard(adornee, widthStuds, heightStuds, offsetY, maxDistance)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Billboard"
	gui.Size = UDim2.new(widthStuds, 0, heightStuds, 0)
	gui.StudsOffset = Vector3.new(0, offsetY or 0, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = maxDistance or 120
	gui.Adornee = adornee
	gui.Parent = adornee
	return gui
end

-- Rounded dark card with a coloured outline; fills its parent.
local function cardPanel(parent, strokeColor, transparency)
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.new(1, 0, 1, 0)
	card.BackgroundColor3 = Color3.fromRGB(255, 255, 255) -- the gradient below sets the real colour
	card.BackgroundTransparency = transparency or 0.18
	card.BorderSizePixel = 0
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(COL.Violet, COL.Navy)
	gradient.Rotation = 90
	gradient.Parent = card
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.14, 0)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Color = strokeColor
	stroke.Thickness = 5
	stroke.Transparency = 0.1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card
	card.Parent = parent
	return card, stroke
end

-- Theme.Label when the theme provides it; otherwise an equivalent plain label (still Theme fonts).
local function makeLabel(text, role, opts)
	opts = opts or {}
	if type(Theme.Label) == "function" then
		return Theme.Label(text, role, opts)
	end
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	if type(Theme.Fonts) == "table" and Theme.Fonts[role] then
		label.Font = Theme.Fonts[role]
	end
	label.TextColor3 = opts.Color or COL.Text
	label.TextStrokeColor3 = COL.Ink
	label.TextStrokeTransparency = opts.Stroke or 0.55
	if opts.Scaled then
		label.TextScaled = true
	elseif opts.Size then
		label.TextSize = opts.Size
	end
	if opts.Props then
		for key, value in pairs(opts.Props) do
			label[key] = value
		end
	end
	return label
end

-- Auto-scaled text label placed with fractions of its parent.
local function fitLabel(parent, text, role, color, name, x, y, w, h, align)
	local label = makeLabel(text, role, {
		Scaled = true,
		Color = color,
		Props = {
			Name = name,
			Position = UDim2.new(x, 0, y, 0),
			Size = UDim2.new(w, 0, h, 0),
			TextWrapped = false,
			TextXAlignment = align or Enum.TextXAlignment.Center,
		},
	})
	label.Parent = parent
	return label
end

local function surfaceGui(part, pixelsPerStud, face)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 40
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Adornee = part
	return gui
end

-- Navy -> violet rounded panel with a soft golden outline, filling the whole SurfaceGui.
local function signPanel(gui, strokeColor)
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.BackgroundColor3 = Color3.fromRGB(255, 255, 255) -- UIGradient multiplies this
	panel.BorderSizePixel = 0
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(COL.Violet, COL.Navy)
	gradient.Rotation = 90
	gradient.Parent = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 28)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = strokeColor or COL.TextGold
	stroke.Thickness = 6
	stroke.Transparency = 0.25
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = panel
	panel.Parent = gui
	return panel
end

local function textGradient(label, keypoints, rotation)
	local seq = {}
	for _, kp in ipairs(keypoints) do
		seq[#seq + 1] = ColorSequenceKeypoint.new(kp[1], kp[2])
	end
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(seq)
	g.Rotation = rotation or 0
	g.Parent = label
	return g
end

local function hex(color)
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

-- "50 <cloud>" / "5,000 <cloud>"
local function priceText(price)
	return Util.Commas(price) .. " " .. CLOUD_GLYPH
end

-- Rich-text star row: `filled` gold stars then dim hollow ones up to `total`.
local function starRow(filled, total)
	local out = string.format('<font color="%s">%s</font>', hex(COL.TextGold), string.rep(STAR_FULL, filled))
	if total > filled then
		out = out .. string.format('<font color="%s">%s</font>', hex(COL.StarOff), string.rep(STAR_EMPTY, total - filled))
	end
	return out
end

-- Small floating name tag in the cosy "Script" font.
local function nameTag(anchor, text, offsetY, maxDistance)
	local gui = newBillboard(anchor, 16, 3.6, offsetY, maxDistance or 110)
	gui.Name = "NameTag"
	fitLabel(gui, text, "Script", COL.Text, "Text", 0, 0, 1, 1)
	return gui
end

----------------------------------------------------------------------
-- Cloud helpers
----------------------------------------------------------------------

-- Flat-bottomed cumulus: one wide base disc plus overlapping domed puffs. `pos` is the centre
-- of the cluster's floor plane. opts: Puffs, Base, Color, Shade, Transparency, CanCollide.
-- Returns the list of parts (so callers can animate them together).
local function cloudCluster(parent, rng, pos, radius, opts)
	opts = opts or {}
	local color = opts.Color or COL.Puff
	local shade = opts.Shade or COL.Side
	local trans = opts.Transparency or 0
	local collide = opts.CanCollide ~= false
	local parts = {}

	if opts.Base ~= false then
		local baseTh = radius * 0.45
		parts[#parts + 1] = disc(parent, pos - Vector3.new(0, baseTh * 0.5, 0), radius * 1.9, baseTh, {
			Name = "CloudBase",
			Color = shade,
			Transparency = trans,
			CanCollide = collide,
		})
	end
	for _ = 1, opts.Puffs or 6 do
		local ang = rng:Float(0, math.pi * 2)
		local dist = rng:Float(0, radius * 0.75)
		local k = 1 - dist / (radius * 0.8) -- 1 in the middle, ~0 at the edge: domes the silhouette
		local d = radius * (0.65 + 0.55 * k) * rng:Float(0.85, 1.1)
		local puffPos = pos + Vector3.new(math.cos(ang) * dist, d * 0.3, math.sin(ang) * dist)
		parts[#parts + 1] = ball(parent, puffPos, d, {
			Name = "CloudPuff",
			Color = color:Lerp(shade, rng:Float(0, 0.3)),
			Transparency = trans,
			CanCollide = collide,
		})
	end
	return parts
end

-- A ring of big soft puffs around a disc edge (never solid: the disc itself is the floor).
-- `center` is the surface centre; a puff's crest pokes `crestMin..crestMax` studs above center.Y.
-- Angles listed in `skip` stay open (bridge entrances) within `skipHalf` degrees.
local function rimPuffs(parent, rng, center, ringR, count, dMin, dMax, crestMin, crestMax, color, skip, skipHalf)
	for i = 1, count do
		local ang = (i - 1) * (360 / count) + rng:Float(-4, 4)
		if not nearAny(ang, skip, skipHalf or 9) then
			local d = rng:Float(dMin, dMax)
			local r = ringR + rng:Float(-1, 1.5)
			local crest = rng:Float(crestMin, crestMax)
			local a = math.rad(ang)
			local pos = Vector3.new(center.X + math.cos(a) * r, center.Y + crest - d * 0.5, center.Z + math.sin(a) * r)
			ball(parent, pos, d, {
				Name = "RimPuff",
				Color = color:Lerp(COL.Side, rng:Float(0, 0.2)),
				CanCollide = false,
			})
		end
	end
end

-- Under-side of a round island: stacked, shrinking, slightly translucent tiers plus a few puffs.
-- `c` = centre of the walking surface, `r` = island radius, `top` = thickness of the top disc.
local function islandBody(parent, rng, c, r, top, tint, puffCount)
	local tiers = {
		{ k = 0.82, th = 3, y = top + 1.5, color = COL.Side, trans = 0.04 },
		{ k = 0.52, th = 4, y = top + 4.5, color = COL.Side:Lerp(COL.Shadow, 0.4), trans = 0.12 },
		{ k = 0.26, th = 4, y = top + 8.5, color = COL.Dusk, trans = 0.28 },
	}
	for _, tier in ipairs(tiers) do
		disc(parent, c - Vector3.new(0, tier.y, 0), r * 2 * tier.k, tier.th, {
			Name = "IslandTier",
			Color = tier.color:Lerp(tint, 0.08),
			Transparency = tier.trans,
			CanCollide = false,
		})
	end
	for _ = 1, puffCount or 2 do
		local a = rng:Float(0, math.pi * 2)
		local dist = rng:Float(r * 0.3, r * 0.7)
		local d = rng:Float(r * 0.4, r * 0.65)
		ball(parent, c + Vector3.new(math.cos(a) * dist, -rng:Float(top + 3, top + 8), math.sin(a) * dist), d, {
			Name = "UnderPuff",
			Color = COL.Dusk:Lerp(COL.Top, rng:Float(0.1, 0.4)),
			Transparency = 0.12,
			CanCollide = false,
		})
	end
end

-- Deterministic scatter with an exclusion list (used for island decorations).
local function newPlacer(rng)
	local taken = {}
	local placer = {}

	function placer.Reserve(x, z, radius)
		taken[#taken + 1] = { x, z, radius }
	end

	-- Angles are world degrees (so features can prefer the outer half of an island).
	-- Returns x, z offsets from the island centre, or nil when nothing fits.
	function placer.Find(radius, minD, maxD, angMin, angMax)
		for _ = 1, 40 do
			local ang = math.rad(rng:Float(angMin or 0, angMax or 360))
			local dist = rng:Float(minD, maxD)
			local x = math.cos(ang) * dist
			local z = math.sin(ang) * dist
			local ok = true
			for _, t in ipairs(taken) do
				local dx = x - t[1]
				local dz = z - t[2]
				local need = radius + t[3]
				if dx * dx + dz * dz < need * need then
					ok = false
				end
			end
			if ok then
				taken[#taken + 1] = { x, z, radius }
				return x, z
			end
		end
		return nil, nil
	end

	return placer
end

----------------------------------------------------------------------
-- Decorations
----------------------------------------------------------------------

-- Wooden bench (plain parts, no Seat: running past must never sit you down by accident).
-- `cf` is at ground level; its LookVector is the direction the sitter faces.
local function bench(parent, cf)
	local function part(name, offset, size, color, material)
		return mk(parent, {
			Name = name,
			CFrame = cf * CFrame.new(offset),
			Size = size,
			Color = color,
			Material = material or MAT.WoodPlanks,
		})
	end
	part("BenchSeat", Vector3.new(0, 1.55, 0), Vector3.new(5.6, 0.45, 2.1), COL.Wood, MAT.WoodPlanks)
	part("BenchBack", Vector3.new(0, 2.7, 0.95), Vector3.new(5.6, 1.7, 0.35), COL.WoodLight, MAT.WoodPlanks)
	part("BenchLegL", Vector3.new(-2.4, 0.65, 0), Vector3.new(0.5, 1.3, 1.9), COL.WoodDark, MAT.Wood)
	part("BenchLegR", Vector3.new(2.4, 0.65, 0), Vector3.new(0.5, 1.3, 1.9), COL.WoodDark, MAT.Wood)
end

-- Blossom tree hung with glowing lanterns. `base` = ground position at the trunk.
local function lanternTree(parent, rng, base, scale, blossom, withLight)
	local h = 8.5 * scale
	disc(parent, base + Vector3.new(0, h * 0.5, 0), 1.5 * scale, h, {
		Name = "TreeTrunk",
		Color = COL.WoodDark,
		Material = MAT.Wood,
	})

	-- Canopy: one big crown ball plus two smaller ones.
	local crownPos = base + Vector3.new(0, h + 0.6 * scale, 0)
	local crown = ball(parent, crownPos, 7.6 * scale, {
		Name = "TreeCrown",
		Color = blossom,
		CanCollide = false,
		CastShadow = true,
	})
	for i = 1, 2 do
		local a = (i - 1) * math.pi + rng:Float(-0.5, 0.5)
		local rr = rng:Float(2.4, 3.1) * scale
		ball(parent, crownPos + Vector3.new(math.cos(a) * rr, rng:Float(-1.4, -0.2) * scale, math.sin(a) * rr), rng:Float(4.6, 6) * scale, {
			Name = "TreeBlossom",
			Color = blossom:Lerp(COL.Top, rng:Float(0.1, 0.35)),
			CanCollide = false,
		})
	end
	emitter(crown, {
		Color = ColorSequence.new(blossom, COL.Top),
		Rate = 2,
		Lifetime = NumberRange.new(5, 7),
		Speed = NumberRange.new(0.3, 1),
		Acceleration = Vector3.new(0, -1.4, 0),
		Size = popSize(0.45),
		EmissionDirection = Enum.NormalId.Bottom,
	})

	-- Two lanterns on strings; the first one carries the real light.
	local a0 = rng:Float(0, math.pi * 2)
	for i = 1, 2 do
		local a = a0 + (i - 1) * math.pi
		local lx = math.cos(a) * 3.3 * scale
		local lz = math.sin(a) * 3.3 * scale
		local topY = h - 1.2 * scale
		disc(parent, base + Vector3.new(lx, topY - 1.4, lz), 0.12, 2.8, {
			Name = "LanternString",
			Color = COL.WoodDark,
			CanCollide = false,
		})
		local lantern = ball(parent, base + Vector3.new(lx, topY - 3.3, lz), 1.3, {
			Name = "Lantern",
			Color = COL.Lantern,
			Material = MAT.Neon,
			CanCollide = false,
		})
		if withLight and i == 1 then
			pointLight(lantern, COL.Lantern, 0.8, 16)
		end
	end
end

-- A handful of flowers scattered inside a circle. center = ground position.
local function flowerPatch(parent, rng, center, radius, count)
	for _ = 1, count do
		local a = rng:Float(0, math.pi * 2)
		local rr = radius * math.sqrt(rng:Float(0, 1))
		local pos = center + Vector3.new(math.cos(a) * rr, 0, math.sin(a) * rr)
		local h = rng:Float(1.1, 1.9)
		disc(parent, pos + Vector3.new(0, h * 0.5, 0), 0.18, h, {
			Name = "FlowerStem",
			Color = COL.Stem,
			CanCollide = false,
		})
		ball(parent, pos + Vector3.new(0, h + 0.1, 0), rng:Float(0.9, 1.3), {
			Name = "FlowerBloom",
			Color = rng:Pick(FLOWER_COLORS),
			CanCollide = false,
		})
	end
end

-- Tiny pond: dark bed, glassy water, a ring of cloud stones, lily pads and a lotus.
local function pond(parent, rng, ground, radius)
	disc(parent, ground + Vector3.new(0, 0.1, 0), radius * 2, 0.2, {
		Name = "PondBed",
		Color = COL.WaterBed,
		CanCollide = false,
	})
	local water = disc(parent, ground + Vector3.new(0, 0.35, 0), radius * 2 - 0.4, 0.3, {
		Name = "PondWater",
		Color = COL.Water,
		Material = MAT.Glass,
		Transparency = 0.4,
		Reflectance = 0.1,
		CanCollide = false,
	})
	local stones = math.max(6, math.floor(math.pi * 2 * radius / 3))
	for i = 1, stones do
		local a = (i - 1) * (math.pi * 2 / stones) + rng:Float(-0.1, 0.1)
		ball(parent, ground + Vector3.new(math.cos(a) * (radius + 0.5), 0.3, math.sin(a) * (radius + 0.5)), rng:Float(1.8, 2.4), {
			Name = "PondStone",
			Color = COL.Top:Lerp(COL.Side, rng:Float(0, 0.4)),
			CanCollide = false,
		})
	end
	for _ = 1, 2 do
		local a = rng:Float(0, math.pi * 2)
		local rr = rng:Float(0.3, radius * 0.55)
		disc(parent, ground + Vector3.new(math.cos(a) * rr, 0.55, math.sin(a) * rr), rng:Float(1.4, 1.9), 0.08, {
			Name = "LilyPad",
			Color = Color3.fromRGB(98, 172, 120),
			CanCollide = false,
		})
	end
	ball(parent, ground + Vector3.new(radius * 0.25, 0.8, -radius * 0.2), 0.9, {
		Name = "Lotus",
		Color = Color3.fromRGB(226, 170, 196),
		CanCollide = false,
	})
	emitter(water, {
		Color = ColorSequence.new(Color3.fromRGB(170, 210, 240)),
		Rate = 2,
		Lifetime = NumberRange.new(2, 3),
		Speed = NumberRange.new(0.3, 0.8),
		Size = popSize(0.5),
	})
end

-- Glowing lamp post.
local function lampPost(parent, ground, withLight)
	disc(parent, ground + Vector3.new(0, 2.1, 0), 0.5, 4.2, {
		Name = "LampPost",
		Color = COL.Post,
	})
	local glow = ball(parent, ground + Vector3.new(0, 4.5, 0), 1.5, {
		Name = "LampGlow",
		Color = COL.Lantern,
		Material = MAT.Neon,
		CanCollide = false,
	})
	if withLight then
		pointLight(glow, COL.Lantern, 0.7, 16)
	end
end

-- Plump cloud cushion (a squashed ball) for cosy corners.
local function cushion(parent, pos, size, color)
	return mk(parent, {
		Name = "Cushion",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(size, size * 0.6, size),
		CFrame = CFrame.new(pos + Vector3.new(0, size * 0.3, 0)),
		Color = color,
		CanCollide = false,
	})
end

-- Pedestal with three spinning, bobbing golden cloud tokens (decorative, NOT tagged).
local function tokenShowcase(parent, ground, title, sub)
	local pedestal = disc(parent, ground + Vector3.new(0, 0.6, 0), 6.2, 1.2, {
		Name = "TokenPedestal",
		Color = COL.Top,
		CastShadow = true,
	})
	disc(parent, ground + Vector3.new(0, 1.25, 0), 5.0, 0.1, {
		Name = "PedestalGlow",
		Color = COL.Gold,
		Material = MAT.Neon,
		CanCollide = false,
	})
	local specs = {
		{ x = 0, y = 5.4, d = 4.0, bob = 2.4, spin = 5 },
		{ x = -3.9, y = 4.2, d = 2.6, bob = 1.9, spin = 4 },
		{ x = 3.9, y = 4.2, d = 2.6, bob = 2.9, spin = 6 },
	}
	for _, spec in ipairs(specs) do
		local pos = ground + Vector3.new(spec.x, spec.y, 0)
		local coin = mk(parent, {
			Name = "ShowcaseToken",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.7, spec.d, spec.d),
			CFrame = CFrame.new(pos),
			Color = COL.Gold,
			Material = MAT.Neon,
			CanCollide = false,
		})
		later(function()
			loopTween(coin, spec.spin, { Orientation = Vector3.new(0, 360, 0) }, Enum.EasingStyle.Linear, false)
			loopTween(coin, spec.bob, { Position = pos + Vector3.new(0, 0.7, 0) }, Enum.EasingStyle.Sine, true)
		end)
	end
	emitter(pedestal, {
		Color = ColorSequence.new(COL.TextGold),
		Rate = 4,
		Lifetime = NumberRange.new(2, 3),
		Speed = NumberRange.new(1.5, 3),
		Size = popSize(0.6),
	})

	-- Info card floating over the pedestal.
	local gui = newBillboard(pedestal, 17, 5.4, 11, 110)
	gui.Name = "TokenInfo"
	fitLabel(gui, title or "Cloud Tokens", "Title", COL.TextGold, "Title", 0, 0, 1, 0.6)
	fitLabel(gui, sub or "Collect them on the way up!", "Body", COL.Text, "Sub", 0, 0.6, 1, 0.4)
end

-- A cluster of glass crystals (tilted translucent spires) around a small cloud mound.
local function crystalCluster(parent, rng, ground)
	ball(parent, ground + Vector3.new(0, 0.3, 0), 6.5, {
		Name = "CrystalMound",
		Color = COL.Puff,
		CanCollide = false,
	})
	local tints = {
		Color3.fromRGB(120, 150, 226),
		Color3.fromRGB(160, 130, 224),
		Color3.fromRGB(110, 190, 206),
		Color3.fromRGB(196, 140, 210),
	}
	for i = 1, 5 do
		local a = (i - 1) * (math.pi * 2 / 5) + rng:Float(-0.3, 0.3)
		local rr = rng:Float(0.8, 2.2)
		local h = rng:Float(4.5, 8.5)
		local tilt = math.rad(rng:Float(8, 18))
		local pos = ground + Vector3.new(math.cos(a) * rr, h * 0.5 + 0.8, math.sin(a) * rr)
		mk(parent, {
			Name = "Crystal",
			CFrame = CFrame.new(pos) * CFrame.Angles(math.cos(a) * tilt, rng:Float(0, 3), math.sin(a) * tilt),
			Size = Vector3.new(rng:Float(1.1, 1.7), h, rng:Float(1.1, 1.7)),
			Color = tints[(i - 1) % #tints + 1],
			Material = MAT.Glass,
			Transparency = 0.2,
			Reflectance = 0.1,
			CanCollide = false,
		})
	end
	local glow = ball(parent, ground + Vector3.new(0, 1.8, 0), 1.4, {
		Name = "CrystalCore",
		Color = Color3.fromRGB(150, 170, 240),
		Material = MAT.Neon,
		CanCollide = false,
	})
	pointLight(glow, Color3.fromRGB(150, 170, 240), 0.9, 16)
	emitter(glow, {
		Color = ColorSequence.new(Color3.fromRGB(180, 196, 250)),
		Rate = 4,
		Lifetime = NumberRange.new(2, 3),
		Speed = NumberRange.new(1, 2),
	})
end

-- A little brass stargazing telescope on a pedestal. `facing` = direction it points (flat).
local function telescope(parent, ground, facing)
	disc(parent, ground + Vector3.new(0, 1.0, 0), 1.4, 2.0, { Name = "ScopeStand", Color = COL.Post })
	local dir = Vector3.new(facing.X, 0.55, facing.Z).Unit
	local from = ground + Vector3.new(0, 2.6, 0)
	local mid = from + dir * 1.8
	mk(parent, {
		Name = "ScopeTube",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(3.6, 0.9, 0.9),
		CFrame = CFrame.lookAt(mid, mid + dir) * CFrame.Angles(0, math.rad(90), 0),
		Color = COL.GoldDark,
		Material = MAT.Metal,
		CanCollide = false,
	})
	ball(parent, from + dir * 3.7, 0.7, {
		Name = "ScopeLens",
		Color = COL.Water,
		Material = MAT.Glass,
		CanCollide = false,
	})
end

----------------------------------------------------------------------
-- Layout numbers (derived once from Config.Lobby / Config.Difficulties)
----------------------------------------------------------------------

local ROAD_W = 12 -- ring road width
local SPOKE_W = 10 -- plaza <-> ring road
local SPUR_W = 8 -- ring road <-> spot island
local ARCH_Z = 40 -- rainbow arch plane: z = ORIGIN.Z + ARCH_Z
local ARCH_R = 30

local SPOT_DY = { 2, 4, 1, 3, 4, 2, 3, 1, 4, 2, 3, 4, 1, 3, 2, 4 }

local DECOR_SPECS = {
	{ Name = "Sunset Perch", Dy = 2, Radius = 14, Features = { "Bench", "Tree", "Flowers" } },
	{ Name = "Lily Pond", Dy = 0, Radius = 14, Features = { "Pond", "Tree", "Flowers" } },
	{ Name = "Token Garden", Dy = 3, Radius = 14, Features = { "Tokens", "Bench", "Flowers" } },
	{ Name = "Crystal Cove", Dy = 1, Radius = 14, Features = { "Crystals", "Lanterns", "Bench" } },
	{ Name = "Moonflower Meadow", Dy = 2, Radius = 14, Features = { "Bench", "Tree", "Flowers", "Flowers" } },
	{ Name = "Quiet Cove", Dy = -1, Radius = 14, Features = { "Pond", "Bench", "Telescope" } },
	{ Name = "Lantern Grove", Dy = 1, Radius = 14, Features = { "Tree", "Tree", "Bench" } },
}

local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

local function computeLayout()
	local diffs = Config.Difficulties
	local n = #diffs
	local L = {}

	-- Portals fan out over the +Z half of the plaza: the first (easiest) at angle 0 (+X, the left
	-- hand of a player looking at +Z), the last (hardest) at 180. The middle one is dead ahead.
	local step = 90
	if n > 1 then
		step = 180 / (n - 1)
	end
	L.PortalStep = step
	L.PortalAngles = {}
	for i = 1, n do
		if n > 1 then
			L.PortalAngles[i] = (i - 1) * step
		else
			L.PortalAngles[i] = 90
		end
	end

	-- Spokes (plaza -> ring road) leave BETWEEN the portals, plus one beyond each end.
	L.SpokeAngles = {}
	for i = 1, n - 1 do
		L.SpokeAngles[#L.SpokeAngles + 1] = L.PortalAngles[i] + step / 2
	end
	L.SpokeAngles[#L.SpokeAngles + 1] = (L.PortalAngles[n] + step / 2) % 360
	L.SpokeAngles[#L.SpokeAngles + 1] = (L.PortalAngles[1] - step / 2) % 360

	-- Shop island.
	local off = LOBBY.ShopOffset
	L.ShopCenter = Vector3.new(ORIGIN.X + off.X, TOP + off.Y, ORIGIN.Z + off.Z)
	L.ShopDist = math.max(1, math.sqrt(off.X * off.X + off.Z * off.Z))
	L.ShopAngle = math.deg(atan2(off.Z, off.X)) % 360
	L.ShopR = clamp(L.ShopDist - SURF_R - 2, 24, 36)

	-- Spot islands: sized from the available arc, then the ring road radius follows.
	local count = math.max(1, SPOT_COUNT)
	local spacingDeg = 320 / math.max(1, count - 1)
	local spacingStuds = SPOT_R * math.rad(spacingDeg)
	L.IslandR = clamp(math.floor(spacingStuds * 0.25 + 0.5), 12, 20)
	L.RingR = SPOT_R - L.IslandR - 27

	-- Where the ring road meets the shop island's rim (law of cosines), as an angle off the shop axis.
	local cosDelta = (L.RingR * L.RingR + L.ShopDist * L.ShopDist - L.ShopR * L.ShopR) / (2 * L.RingR * L.ShopDist)
	local delta = math.deg(math.acos(clamp(cosDelta, -1, 1)))
	local dock = math.max(2, delta - 5.5) -- the road ends a little INSIDE the shop island
	L.RingFrom = L.ShopAngle + dock
	L.RingTo = L.ShopAngle + 360 - dock

	local first = L.ShopAngle + delta + 10
	local last = L.ShopAngle + 360 - delta - 10
	L.SpotAngles = {}
	for i = 1, count do
		if count == 1 then
			L.SpotAngles[i] = (first + last) / 2
		else
			L.SpotAngles[i] = first + (i - 1) * (last - first) / (count - 1)
		end
	end

	-- Decor islands: one behind every portal plus one beyond each end.
	L.DecorAngles = {}
	for i = 1, n do
		L.DecorAngles[#L.DecorAngles + 1] = L.PortalAngles[i]
	end
	L.DecorAngles[#L.DecorAngles + 1] = (L.PortalAngles[n] + step) % 360
	L.DecorAngles[#L.DecorAngles + 1] = (L.PortalAngles[1] - step) % 360

	-- Gaps in the plaza's soft rim: spokes and the shop neck.
	L.PlazaOpenings = {}
	for _, a in ipairs(L.SpokeAngles) do
		L.PlazaOpenings[#L.PlazaOpenings + 1] = a
	end
	L.PlazaOpenings[#L.PlazaOpenings + 1] = L.ShopAngle
	return L
end

----------------------------------------------------------------------
-- Mascot monument (the Cloudy Dragon)
----------------------------------------------------------------------

-- Pedestal + sign always; the dragon itself is built by PetBuilder when that shared module exists
-- (contract in ARCHITECTURE_V2.md) and silently skipped otherwise. Faces `lookTarget`.
local function mascotMonument(parent, ground, lookTarget)
	disc(parent, ground + Vector3.new(0, 0.8, 0), 10, 1.6, { Name = "MascotPedestal", Color = COL.Side, CastShadow = true })
	disc(parent, ground + Vector3.new(0, 1.7, 0), 8.6, 0.2, {
		Name = "MascotPedestalGlow",
		Color = COL.Gold,
		Material = MAT.Neon,
		CanCollide = false,
	})
	local cap = disc(parent, ground + Vector3.new(0, 1.95, 0), 7.4, 0.3, { Name = "MascotPedestalTop", Color = COL.Top })
	local topY = ground.Y + 2.1
	emitter(cap, {
		Color = ColorSequence.new(COL.TextGold, COL.Top),
		Rate = 6,
		Lifetime = NumberRange.new(2, 3.5),
		Speed = NumberRange.new(2, 4),
		Size = popSize(0.7),
	})

	local ok, model = pcall(function()
		local builderModule = Shared:FindFirstChild("PetBuilder")
		local catalogModule = Shared:FindFirstChild("PetCatalog")
		if not builderModule or not catalogModule then
			return nil
		end
		local PetBuilder = require(builderModule)
		local PetCatalog = require(catalogModule)
		local def = PetCatalog.Get("cloudy_dragon")
		if not def then
			return nil
		end
		local scale = 5
		local height = 3
		if PetBuilder.GetHeight then
			height = PetBuilder.GetHeight(def)
		end
		local m = PetBuilder.Build(def, { Scale = scale })
		local y = topY + height * scale * 0.5 + 1.5
		m.Name = "CloudyDragonStatue"
		m:PivotTo(CFrame.lookAt(Vector3.new(ground.X, y, ground.Z), Vector3.new(lookTarget.X, y, lookTarget.Z)))
		m.Parent = parent
		return m
	end)
	if ok and model then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				partCount = partCount + 1
			end
		end
	elseif not ok then
		warn("[LobbyBuilder] mascot statue skipped: " .. tostring(model))
	end

	-- Small plaque card in front of the pedestal.
	local toward = Vector3.new(lookTarget.X - ground.X, 0, lookTarget.Z - ground.Z)
	if toward.Magnitude > 0.001 then
		toward = toward.Unit
	else
		toward = Vector3.new(0, 0, 1)
	end
	local anchor = anchorPart(parent, "MascotPlaqueAnchor", ground + Vector3.new(0, 4.4, 0) + toward * 6.5)
	local gui = newBillboard(anchor, 11, 3.6, 0, 120)
	gui.Name = "MascotPlaque"
	local card = cardPanel(gui, COL.Gold, 0.16)
	fitLabel(card, "Cloudy Dragon", "Title", COL.TextGold, "Name", 0.05, 0.06, 0.9, 0.55)
	fitLabel(card, "Hatch winged pets in the shop", "Body", COL.Text, "Sub", 0.05, 0.64, 0.9, 0.28)
end

----------------------------------------------------------------------
-- Plaza
----------------------------------------------------------------------

local function buildPlaza(root, L)
	local f = newFolder(root, "Plaza")
	local rng = Util.NewRng(SEED + 1)
	local ox, oz = ORIGIN.X, ORIGIN.Z
	local diffs = Config.Difficulties

	-- Walkable top disc.
	disc(f, Vector3.new(ox, TOP - 3, oz), SURF_R * 2, 6, {
		Name = "PlazaTop",
		Color = COL.Top,
		CastShadow = true,
	})

	-- Inverted-cone underside: shrinking, slightly translucent tiers hidden behind puffs.
	local tiers = {
		{ r = SURF_R * 0.9, th = 6, y = -9, color = COL.Side, trans = 0.04, puffs = 8 },
		{ r = SURF_R * 0.68, th = 7, y = -15.5, color = COL.Side:Lerp(COL.Shadow, 0.4), trans = 0.1, puffs = 6 },
		{ r = SURF_R * 0.44, th = 8, y = -23, color = COL.Shadow, trans = 0.18, puffs = 4 },
		{ r = SURF_R * 0.22, th = 9, y = -31.5, color = COL.Dusk, trans = 0.3, puffs = 2 },
	}
	for _, tier in ipairs(tiers) do
		disc(f, Vector3.new(ox, TOP + tier.y, oz), tier.r * 2, tier.th, {
			Name = "PlazaTier",
			Color = tier.color,
			Transparency = tier.trans,
			CanCollide = false,
		})
		for i = 1, tier.puffs do
			local a = (i - 1) * (math.pi * 2 / tier.puffs) + rng:Float(-0.3, 0.3)
			local d = rng:Float(tier.th * 1.2, tier.th * 1.9)
			ball(f, Vector3.new(ox + math.cos(a) * tier.r * 0.93, TOP + tier.y + rng:Float(-1, 1.5), oz + math.sin(a) * tier.r * 0.93), d, {
				Name = "UnderPuff",
				Color = tier.color:Lerp(COL.Top, 0.3),
				Transparency = tier.trans,
				CanCollide = false,
			})
		end
	end

	-- Soft puffy rim (open where the spokes and the shop neck leave the plaza).
	rimPuffs(f, rng, Vector3.new(ox, TOP, oz), SURF_R + 0.5, 34, 8, 12, 0.2, 1.2, COL.Puff, L.PlazaOpenings, 8)

	-- Muted pastel patches on the ground so the plaza is not one flat sheet. Patches share one
	-- height, so candidates that would overlap an earlier patch are rejected (no z-fighting).
	local patchColors = {
		COL.Top:Lerp(Color3.fromRGB(214, 150, 166), 0.22),
		COL.Top:Lerp(Color3.fromRGB(224, 176, 120), 0.2),
		COL.Top:Lerp(Color3.fromRGB(120, 160, 220), 0.22),
		COL.Top:Lerp(Color3.fromRGB(130, 190, 160), 0.2),
	}
	local placed = {}
	local attempts = 0
	while #placed < 10 and attempts < 80 do
		attempts = attempts + 1
		local ang = rng:Float(0, 360)
		local rr = rng:Float(20, 100)
		local d = rng:Float(6, 13)
		local pos = polar(ang, rr, TOP + 0.03)
		local clear = true
		for _, p in ipairs(placed) do
			local dx, dz = pos.X - p.x, pos.Z - p.z
			local minDist = (d + p.d) / 2 + 0.5
			if dx * dx + dz * dz < minDist * minDist then
				clear = false
				break
			end
		end
		if clear then
			placed[#placed + 1] = { x = pos.X, z = pos.Z, d = d }
			disc(f, pos, d, 0.06, {
				Name = "GroundPatch",
				Color = rng:Pick(patchColors),
				CanCollide = false,
			})
		end
	end

	-- Central medallion: gold rim, cloud field, muted rainbow dots, golden core.
	local layers = {
		{ d = 27, color = COL.GoldDark },
		{ d = 25.4, color = COL.Side },
		{ d = 19, color = COL.Top:Lerp(COL.Gold, 0.18) },
		{ d = 17.6, color = COL.Gold },
		{ d = 16.6, color = COL.Path },
	}
	local stack = 0
	for _, layer in ipairs(layers) do
		disc(f, Vector3.new(ox, TOP + stack + 0.05, oz), layer.d, 0.1, {
			Name = "Medallion",
			Color = layer.color,
			CanCollide = false,
		})
		stack = stack + 0.1
	end
	for i = 1, 6 do
		disc(f, polar(i * 60, 6.4, TOP + stack + 0.05), 3.2, 0.1, {
			Name = "MedallionDot",
			Color = RAINBOW[i],
			CanCollide = false,
		})
	end
	disc(f, Vector3.new(ox, TOP + stack + 0.1, oz), 5.4, 0.2, {
		Name = "MedallionCore",
		Color = COL.Gold,
		Material = MAT.Neon,
		CanCollide = false,
	})

	-- Paths from the medallion to every portal pad, with lamp posts alongside.
	for i, deg in ipairs(L.PortalAngles) do
		local a = math.rad(deg)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
		local pcf = CFrame.lookAt(polar(deg, 49, TOP + 0.08), polar(deg, 50, TOP + 0.08))
		local edgeColor = diffs[i].Color
		block(f, pcf, Vector3.new(6.4, 0.16, 66), { Name = "Path", Color = COL.Path, CanCollide = false })
		block(f, pcf * CFrame.new(-3.45, 0.02, 0), Vector3.new(0.5, 0.2, 66), { Name = "PathEdge", Color = edgeColor, CanCollide = false })
		block(f, pcf * CFrame.new(3.45, 0.02, 0), Vector3.new(0.5, 0.2, 66), { Name = "PathEdge", Color = edgeColor, CanCollide = false })
		local base = Vector3.new(ox, TOP, oz)
		lampPost(f, base + dir * 32 + tangent * 5.4, true)
		lampPost(f, base + dir * 62 - tangent * 5.4, false)
	end

	-- Benches ring the medallion, facing it (placed between the paths).
	local benchAngles = { 22.5, 67.5, 112.5, 157.5, 202.5, 247.5, 292.5, 337.5 }
	for _, deg in ipairs(benchAngles) do
		local pos = polar(deg, 27, TOP)
		bench(f, CFrame.lookAt(pos, Vector3.new(ox, TOP, oz)))
	end

	-- Lantern trees: a grove on the south side (clear of the shop neck) and two flanking the paths.
	local treeSpots = { { 250, 72 }, { 290, 72 }, { 206, 86 }, { 334, 86 }, { 225, 52 }, { 315, 52 } }
	for i, spot in ipairs(treeSpots) do
		lanternTree(f, rng, polar(spot[1], spot[2], TOP), rng:Float(1.0, 1.2), BLOSSOMS[(i - 1) % #BLOSSOMS + 1], i <= 2)
	end

	-- Flower beds near the boards, the grove and the benches.
	local flowerSpots = { { 33, 66 }, { 147, 66 }, { 210, 64 }, { 330, 64 }, { 255, 42 }, { 285, 42 }, { 15, 34 }, { 165, 34 } }
	for _, spot in ipairs(flowerSpots) do
		flowerPatch(f, rng, polar(spot[1], spot[2], TOP), 4, 3)
	end

	-- Path to the shop (south) with lamps, the mascot monument on it, and two small ponds.
	local shopDir = Vector3.new(math.cos(math.rad(L.ShopAngle)), 0, math.sin(math.rad(L.ShopAngle)))
	local shopTan = perpendicular(shopDir)
	local spcf = CFrame.lookAt(polar(L.ShopAngle, 66, TOP + 0.08), polar(L.ShopAngle, 67, TOP + 0.08))
	block(f, spcf, Vector3.new(8, 0.16, 96), { Name = "ShopPath", Color = COL.Path, CanCollide = false })
	block(f, spcf * CFrame.new(-4.25, 0.02, 0), Vector3.new(0.5, 0.2, 96), { Name = "ShopPathEdge", Color = COL.Gold, CanCollide = false })
	block(f, spcf * CFrame.new(4.25, 0.02, 0), Vector3.new(0.5, 0.2, 96), { Name = "ShopPathEdge", Color = COL.Gold, CanCollide = false })
	local plazaBase = Vector3.new(ox, TOP, oz)
	lampPost(f, plazaBase + shopDir * 30 + shopTan * 6.2, true)
	lampPost(f, plazaBase + shopDir * 30 - shopTan * 6.2, false)
	lampPost(f, plazaBase + shopDir * 84 + shopTan * 6.2, false)
	lampPost(f, plazaBase + shopDir * 84 - shopTan * 6.2, true)
	mascotMonument(f, polar(L.ShopAngle, 50, TOP), plazaBase)
	pond(f, rng, polar(L.ShopAngle - 35, 80, TOP), 6)
	pond(f, rng, polar(L.ShopAngle + 35, 80, TOP), 6)

	-- Lobby fireflies drifting over the whole plaza.
	local flies = anchorPart(f, "Fireflies", Vector3.new(ox, TOP + 9, oz), Vector3.new(150, 16, 150))
	emitter(flies, {
		Color = ColorSequence.new(Color3.fromRGB(236, 224, 150), Color3.fromRGB(176, 228, 160)),
		Rate = 14,
		Lifetime = NumberRange.new(5, 9),
		Speed = NumberRange.new(0.3, 1.2),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, 0.2, 0),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.2, 0.5),
			NumberSequenceKeypoint.new(0.5, 0.25),
			NumberSequenceKeypoint.new(0.8, 0.5),
			NumberSequenceKeypoint.new(1, 0),
		}),
	})
end

----------------------------------------------------------------------
-- Signs: wooden frame + navy board with SurfaceGui text
----------------------------------------------------------------------

-- Two posts, a framed board and cloud puffs at the base. Returns the board part
-- (its Front face looks along `cf`'s look vector). `cf` is at ground level facing the viewers.
local function signStructure(parent, cf, width, height, postHeight)
	local boardY = postHeight - height * 0.5 - 1.2
	local postX = width * 0.5 + 1.9

	for _, side in ipairs({ -1, 1 }) do
		local postPos = (cf * CFrame.new(side * postX, postHeight * 0.5, 0.2)).Position
		disc(parent, postPos, 1.5, postHeight, { Name = "SignPost", Color = COL.WoodDark, Material = MAT.Wood })
		local basePos = (cf * CFrame.new(side * postX, 0, 0.2)).Position
		ball(parent, basePos + Vector3.new(0, 1.3, 0), 4.6, { Name = "SignPuff", Color = COL.Puff })
		local lanternPos = (cf * CFrame.new(side * postX, postHeight + 0.9, 0.2)).Position
		local lantern = ball(parent, lanternPos, 2.0, {
			Name = "SignLantern",
			Color = COL.Lantern,
			Material = MAT.Neon,
			CanCollide = false,
		})
		pointLight(lantern, COL.Lantern, 0.8, 18)
	end

	-- Backing frame (slightly bigger, behind) and the board itself.
	block(parent, cf * CFrame.new(0, boardY, 0.25), Vector3.new(width + 2, height + 1.8, 1.0), {
		Name = "SignFrame",
		Color = COL.WoodLight,
		Material = MAT.WoodPlanks,
	})
	local board = block(parent, cf * CFrame.new(0, boardY, -0.3), Vector3.new(width, height, 0.8), {
		Name = "SignBoard",
		Color = COL.Navy,
		CastShadow = true,
	})

	-- Muted rainbow trim along the bottom edge of the board.
	local stripW = width / 6
	for i = 1, 6 do
		local x = (i - 3.5) * stripW
		block(parent, cf * CFrame.new(x, boardY - height * 0.5 + 0.3, -0.75), Vector3.new(stripW, 0.5, 0.2), {
			Name = "SignTrim",
			Color = RAINBOW[i],
			CanCollide = false,
		})
	end
	return board
end

-- A key-cap chip + a description, laid out in rows of a sign panel.
local function keyRow(parent, y, rowH, keyText, descText)
	local chip = Instance.new("Frame")
	chip.Name = "KeyChip"
	chip.Size = UDim2.new(0.3, 0, rowH, 0)
	chip.Position = UDim2.new(0.06, 0, y, 0)
	chip.BackgroundColor3 = COL.Slate
	chip.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = chip
	local stroke = Instance.new("UIStroke")
	stroke.Color = COL.TextGold
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = chip
	chip.Parent = parent

	fitLabel(chip, keyText, "Heading", COL.TextGold, "Key", 0.04, 0.08, 0.92, 0.84)
	fitLabel(parent, descText, "Body", COL.Text, "Desc", 0.4, y, 0.56, rowH, Enum.TextXAlignment.Left)
end

local function buildHowToBoard(root, L)
	local f = newFolder(root, "HowToBoard")
	local mid = L.PortalAngles[#L.PortalAngles] - L.PortalStep / 2
	local ground = polar(mid, 60, TOP)
	local cf = CFrame.lookAt(ground, Vector3.new(ORIGIN.X, TOP, ORIGIN.Z))
	local board = signStructure(f, cf, 22, 16, 21)

	local gui = surfaceGui(board, 40)
	local panel = signPanel(gui)
	fitLabel(panel, "HOW TO PLAY", "Title", COL.Gold, "Header", 0.04, 0.03, 0.92, 0.14)

	keyRow(panel, 0.2, 0.1, "W A S D", "Move around")
	keyRow(panel, 0.32, 0.1, "SHIFT", "Hold to run")
	keyRow(panel, 0.44, 0.1, "Q", "Dash over wide gaps")
	keyRow(panel, 0.56, 0.1, "SPACE", "Jump")
	keyRow(panel, 0.68, 0.1, "1 - 4", "Use items (in a climb)")

	local footer = makeLabel("Stand in a glowing gate to form a party, then climb together!", "Body", {
		Scaled = true,
		Color = COL.TextGold,
		Props = {
			Position = UDim2.new(0.05, 0, 0.81, 0),
			Size = UDim2.new(0.9, 0, 0.15, 0),
			TextWrapped = true,
		},
	})
	footer.Parent = panel
	gui.Parent = board
end

-- Second board: how pets, spots and the shop fit together.
local function buildGuideBoard(root, L)
	local f = newFolder(root, "GuideBoard")
	local mid = L.PortalAngles[1] + L.PortalStep / 2
	local ground = polar(mid, 60, TOP)
	local cf = CFrame.lookAt(ground, Vector3.new(ORIGIN.X, TOP, ORIGIN.Z))
	local board = signStructure(f, cf, 22, 16, 21)

	local gui = surfaceGui(board, 40)
	local panel = signPanel(gui)
	fitLabel(panel, "PETS & SPOTS", "Title", COL.Gold, "Header", 0.04, 0.03, 0.92, 0.14)

	keyRow(panel, 0.2, 0.1, "PETS", "Winged friends follow you")
	keyRow(panel, 0.32, 0.1, "SHOP", "Spin roulettes for pets")
	keyRow(panel, 0.44, 0.1, "RARITY", "Pricier = rarer pets")
	keyRow(panel, 0.56, 0.1, "SPOT", "Your cloud home, saved")
	keyRow(panel, 0.68, 0.1, "MENU", "Bag, pets, stats at left")

	local footer = makeLabel("Collect cloud tokens in every climb to afford bigger roulettes.", "Body", {
		Scaled = true,
		Color = COL.TextGold,
		Props = {
			Position = UDim2.new(0.05, 0, 0.81, 0),
			Size = UDim2.new(0.9, 0, 0.15, 0),
			TextWrapped = true,
		},
	})
	footer.Parent = panel
	gui.Parent = board
end

----------------------------------------------------------------------
-- Rainbow arch (muted) with the welcome board hanging from it
----------------------------------------------------------------------

local function buildArch(root)
	local f = newFolder(root, "RainbowArch")
	local rng = Util.NewRng(SEED + 2)
	local cx, cz = ORIGIN.X, ORIGIN.Z + ARCH_Z
	local centre = Vector3.new(cx, TOP - 1, cz)
	local segments = 14
	local bandH = 1.25

	-- Six concentric bands (red outermost), each made of thin rotated blocks.
	for band = 1, 6 do
		local r = ARCH_R - (band - 1) * bandH
		local len = r * math.pi / segments * 1.12
		for k = 0, segments - 1 do
			local phi = (k + 0.5) * math.pi / segments
			local pos = centre + Vector3.new(math.cos(phi) * r, math.sin(phi) * r, 0)
			block(f, CFrame.new(pos) * CFrame.Angles(0, 0, phi + math.pi / 2), Vector3.new(len, bandH, 3.2), {
				Name = "RainbowBand" .. band,
				Color = RAINBOW[band],
				CanCollide = false,
			})
		end
	end

	-- A cloud bank at each foot of the arch, sparkling gently.
	local footR = ARCH_R - 2.7
	for _, sx in ipairs({ -1, 1 }) do
		local parts = cloudCluster(f, rng, Vector3.new(cx + sx * footR, TOP - 0.5, cz), 7, { Puffs = 4 })
		emitter(parts[1], {
			Color = ColorSequence.new(Color3.fromRGB(236, 214, 170), COL.Top),
			Rate = 5,
			Lifetime = NumberRange.new(2, 3.5),
			Speed = NumberRange.new(2, 4),
			Size = popSize(0.8),
		})
	end

	-- Welcome board crowning the arch (so it never hides the gates behind it). Its front faces the
	-- plaza centre (-Z); two short posts stand on the apex.
	local boardW, boardH = 20, 6.8
	local boardY = TOP + 33.6
	local board = block(f, CFrame.new(cx, boardY, cz), Vector3.new(boardW, boardH, 0.8), {
		Name = "WelcomeBoard",
		Color = COL.Navy,
		CanCollide = false,
		CastShadow = true,
	})
	block(f, CFrame.new(cx, boardY, cz + 0.15), Vector3.new(boardW + 1.2, boardH + 1.2, 0.8), {
		Name = "WelcomeFrame",
		Color = COL.WoodLight,
		Material = MAT.WoodPlanks,
		CanCollide = false,
	})
	for _, side in ipairs({ -1, 1 }) do
		block(f, CFrame.new(cx + side * 6.5, TOP + 29.7, cz), Vector3.new(0.9, 2.8, 1.2), {
			Name = "WelcomePost",
			Color = COL.WoodDark,
			Material = MAT.Wood,
			CanCollide = false,
		})
		local lantern = ball(f, Vector3.new(cx + side * (boardW / 2 + 1.6), boardY + boardH / 2 - 0.4, cz), 1.4, {
			Name = "WelcomeLantern",
			Color = COL.Lantern,
			Material = MAT.Neon,
			CanCollide = false,
		})
		if side == 1 then
			pointLight(lantern, COL.Lantern, 0.8, 22)
		end
	end

	local gui = surfaceGui(board, 40)
	local panel = signPanel(gui)

	fitLabel(panel, "~ welcome to the clouds ~", "Script", COL.TextGold, "Welcome", 0, 0.05, 1, 0.16)

	local titleText = string.upper(Config.GameName)
	local shadow = makeLabel(titleText, "Title", {
		Scaled = true,
		Color = COL.Ink,
		Stroke = 1,
		Props = { Size = UDim2.new(0.92, 0, 0.5, 0), Position = UDim2.new(0.052, 0, 0.245, 0), TextTransparency = 0.2 },
	})
	shadow.Parent = panel

	local title = makeLabel(titleText, "Title", {
		Scaled = true,
		Stroke = 1,
		Props = { Size = UDim2.new(0.92, 0, 0.5, 0), Position = UDim2.new(0.04, 0, 0.22, 0) },
	})
	textGradient(title, {
		{ 0, Color3.fromRGB(240, 160, 190) },
		{ 0.35, Color3.fromRGB(240, 214, 130) },
		{ 0.7, Color3.fromRGB(150, 224, 190) },
		{ 1, Color3.fromRGB(130, 190, 240) },
	}, 8)
	title.Parent = panel

	fitLabel(panel, Config.Tagline, "Script", COL.Text, "Tagline", 0.04, 0.76, 0.92, 0.17)
	gui.Parent = board
end

----------------------------------------------------------------------
-- Portal gates
----------------------------------------------------------------------

local MAX_STARS = 5

local function buildPortal(root, rng, diff, angleDeg)
	local f = newFolder(root, "Portal_" .. diff.Id)
	local a = math.rad(angleDeg)
	local outward = Vector3.new(math.cos(a), 0, math.sin(a))
	local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
	local color = diff.Color
	local pale = color:Lerp(COL.Top, 0.45)
	local deep = color:Lerp(COL.Ink, 0.3)

	----------------------------------------------------------------
	-- Pad (the party "ready pad") + invisible Zone
	----------------------------------------------------------------
	local padGround = polar(angleDeg, PORTAL_R, TOP)
	local padCF = CFrame.lookAt(padGround, padGround - outward)

	local plate = block(f, padCF * CFrame.new(0, 0.2, 0), Vector3.new(14, 0.4, 14), {
		Name = "PadPlate",
		Color = pale,
	})
	local edgeProps = { Name = "PadEdge", Color = color, Material = MAT.Neon, CanCollide = false }
	block(f, padCF * CFrame.new(0, 0.42, -6.75), Vector3.new(14, 0.14, 0.5), edgeProps)
	block(f, padCF * CFrame.new(0, 0.42, 6.75), Vector3.new(14, 0.14, 0.5), edgeProps)
	block(f, padCF * CFrame.new(-6.75, 0.42, 0), Vector3.new(0.5, 0.14, 14), edgeProps)
	block(f, padCF * CFrame.new(6.75, 0.42, 0), Vector3.new(0.5, 0.14, 14), edgeProps)

	local emblem = disc(f, padGround + Vector3.new(0, 0.45, 0), 9.5, 0.1, {
		Name = "PadEmblem",
		Color = color,
		Transparency = 0.35,
		CanCollide = false,
	})
	disc(f, padGround + Vector3.new(0, 0.5, 0), 5, 0.1, {
		Name = "PadEmblemCore",
		Color = COL.Top,
		Transparency = 0.5,
		CanCollide = false,
	})
	emitter(plate, {
		Color = ColorSequence.new(color, pale),
		Rate = 5,
		Lifetime = NumberRange.new(1.8, 2.8),
		Speed = NumberRange.new(2, 4),
		Size = popSize(0.6),
	})

	-- Four little glowing pylons mark the pad corners.
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local corner = (padCF * CFrame.new(sx * 7.2, 0, sz * 7.2)).Position
			disc(f, corner + Vector3.new(0, 1.2, 0), 0.8, 2.4, { Name = "PadPylon", Color = COL.Puff })
			ball(f, corner + Vector3.new(0, 2.8, 0), 1.4, {
				Name = "PadPylonGlow",
				Color = color,
				Material = MAT.Neon,
				CanCollide = false,
			})
		end
	end

	-- Invisible detection zone: 14 x 6 x 14, floor flush with the pad surface.
	local zonePos = padGround + Vector3.new(0, 3.4, 0)
	local zone = block(f, CFrame.lookAt(zonePos, zonePos - outward), Vector3.new(14, 6, 14), {
		Name = "Zone_" .. diff.Id,
		Transparency = 1,
		CanCollide = false,
	})
	zone:SetAttribute("PortalId", diff.Id)

	later(function()
		loopTween(emblem, 1.7, { Transparency = 0.72 }, Enum.EasingStyle.Sine, true)
	end)

	----------------------------------------------------------------
	-- Gate: neon ring + puffy cloud frame + swirling energy
	----------------------------------------------------------------
	local ringY = 9.4
	local ringR = 7.6
	local gateGround = padGround + outward * 8.5
	local gateCenter = gateGround + Vector3.new(0, ringY, 0)
	local gateCF = CFrame.lookAt(gateCenter, gateCenter - outward)

	local ringSegs = 20
	local segLen = 2 * ringR * math.sin(math.pi / ringSegs) * 1.12
	for k = 0, ringSegs - 1 do
		local phi = (k + 0.5) * (math.pi * 2 / ringSegs)
		local segColor = color
		if k % 2 == 1 then
			segColor = color:Lerp(COL.Top, 0.3)
		end
		block(f, gateCF * CFrame.new(math.cos(phi) * ringR, math.sin(phi) * ringR, 0) * CFrame.Angles(0, 0, phi + math.pi / 2), Vector3.new(segLen, 1.0, 1.6), {
			Name = "GateRing",
			Color = segColor,
			Material = MAT.Neon,
			CanCollide = false,
		})
	end

	local frameCount = 10
	for k = 0, frameCount - 1 do
		local phi = (k + rng:Float(-0.2, 0.2)) * (math.pi * 2 / frameCount)
		local fr = ringR + 1.9
		local puffPos = (gateCF * CFrame.new(math.cos(phi) * fr, math.sin(phi) * fr, rng:Float(-0.3, 0.3))).Position
		ball(f, puffPos, rng:Float(2.7, 3.4), {
			Name = "GateCloud",
			Color = COL.Puff:Lerp(pale, rng:Float(0, 0.3)),
			CanCollide = false,
		})
	end

	-- Swirl: translucent energy discs facing the plaza + three rotating sparkle arms.
	local faceCF = gateCF * CFrame.Angles(0, math.rad(90), 0)
	local swirl = mk(f, {
		Name = "GateSwirl",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 14.8, 14.8),
		CFrame = faceCF,
		Color = deep,
		Material = MAT.Neon,
		Transparency = 0.74,
		CanCollide = false,
	})
	mk(f, {
		Name = "GateSwirlCore",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 9.5, 9.5),
		CFrame = faceCF,
		Color = color,
		Material = MAT.Neon,
		Transparency = 0.72,
		CanCollide = false,
	})
	local glow = pointLight(swirl, color, 1.2, 30)
	emitter(swirl, {
		Color = ColorSequence.new(pale, color),
		Rate = 8,
		Lifetime = NumberRange.new(1.5, 2.5),
		Speed = NumberRange.new(0.3, 0.9),
		Size = popSize(1.0),
	})

	local arm = anchorPart(f, "SwirlArm", gateCenter, Vector3.new(1, 1, 1))
	arm.CFrame = gateCF
	for k = 0, 2 do
		local ang = k * (math.pi * 2 / 3)
		local att = Instance.new("Attachment")
		att.Position = Vector3.new(math.cos(ang) * 5.4, math.sin(ang) * 5.4, 0)
		att.Parent = arm
		emitter(att, {
			Color = ColorSequence.new(pale, color),
			Rate = 12,
			Lifetime = NumberRange.new(1.3, 1.9),
			Speed = NumberRange.new(0, 0.4),
			Size = popSize(1.3),
			RotSpeed = NumberRange.new(-90, 90),
		})
	end

	later(function()
		-- 3-fold symmetric arms: turning 120 degrees and restarting is visually seamless.
		loopTween(arm, 1.8, { CFrame = gateCF * CFrame.Angles(0, 0, math.rad(120)) }, Enum.EasingStyle.Linear, false)
		loopTween(swirl, 2.2, { Transparency = 0.86 }, Enum.EasingStyle.Sine, true)
		loopTween(glow, 2.2, { Brightness = 2.0 }, Enum.EasingStyle.Sine, true)
	end)

	-- Star row above the ring: a gold diamond per star, dim stone ones up to the maximum.
	local stars = clamp(diff.Stars or 1, 0, MAX_STARS)
	for s = 1, MAX_STARS do
		local gx = ((MAX_STARS + 1) / 2 - s) * 3.2 -- gate +X is the viewer's left: lit stars first
		local lit = s <= stars
		local gemColor = COL.StarOff
		local gemMat = MAT.SmoothPlastic
		if lit then
			gemColor = COL.Gold
			gemMat = MAT.Neon
		end
		block(f, gateCF * CFrame.new(gx, ringR + 3.4, 0) * CFrame.Angles(0, 0, math.rad(45)), Vector3.new(1.7, 1.7, 0.8), {
			Name = lit and "DifficultyGem" or "DifficultyGemOff",
			Color = gemColor,
			Material = gemMat,
			CanCollide = false,
		})
	end

	-- Cloud pillars flanking the gate, each topped with a glowing lantern in the portal colour.
	for _, side in ipairs({ -1, 1 }) do
		local base = gateGround + tangent * (12.4 * side)
		ball(f, base + Vector3.new(0, 3.0, 0), 6.4, { Name = "PillarPuff", Color = COL.Puff })
		ball(f, base + Vector3.new(0, 7.2, 0), 5.0, { Name = "PillarPuff", Color = COL.Puff, CanCollide = false })
		ball(f, base + Vector3.new(0, 10.3, 0), 3.8, { Name = "PillarPuff", Color = COL.Puff:Lerp(pale, 0.3), CanCollide = false })
		ball(f, base + Vector3.new(0, 12.9, 0), 1.8, {
			Name = "PillarGlow",
			Color = color,
			Material = MAT.Neon,
			CanCollide = false,
		})
	end

	----------------------------------------------------------------
	-- Billboard: title, stars, player count, status, blurb
	----------------------------------------------------------------
	local cardW, cardH = 24, 15
	local anchor = anchorPart(
		f,
		"BillboardAnchor",
		gateCenter + Vector3.new(0, ringR + 3.4 + 1.2 + 1.2 + cardH / 2, 0),
		Vector3.new(1, 1, 1)
	)
	local gui = newBillboard(anchor, cardW, cardH, 0, 230)
	gui.Name = "PortalBillboard"

	local card = cardPanel(gui, color, 0.16)
	local titleLabel = fitLabel(card, diff.DisplayName or diff.Id, "Title", color:Lerp(COL.Text, 0.35), "TitleLabel", 0.04, 0.03, 0.92, 0.25)

	local starLabel = fitLabel(card, "", "Heading", COL.TextGold, "StarLabel", 0.04, 0.29, 0.92, 0.12)
	starLabel.RichText = true
	starLabel.Text = starRow(stars, MAX_STARS)

	local countLabel = fitLabel(card, "0 / " .. tostring(Config.Match.MaxPlayers) .. " players", "Display", COL.Text, "CountLabel", 0.04, 0.43, 0.92, 0.19)
	local statusLabel = fitLabel(card, "Waiting for players" .. ELLIPSIS, "Body", COL.TextGold, "StatusLabel", 0.04, 0.63, 0.92, 0.15)
	fitLabel(card, diff.Blurb or "", "Script", COL.TextDim, "BlurbLabel", 0.05, 0.8, 0.9, 0.15)

	return {
		Id = diff.Id,
		Zone = zone,
		Center = zone.Position,
		Billboard = gui,
		TitleLabel = titleLabel,
		CountLabel = countLabel,
		StatusLabel = statusLabel,
		StarLabel = starLabel,
	}
end

-- Bare-minimum portal used only if the full builder above ever throws: the gameplay contract
-- (zone + labels) must survive even when the scenery does not.
local function fallbackPortal(root, diff, angleDeg)
	local f = newFolder(root, "PortalFallback_" .. diff.Id)
	local ground = polar(angleDeg, PORTAL_R, TOP)
	local zone = block(f, CFrame.new(ground + Vector3.new(0, 3.4, 0)), Vector3.new(14, 6, 14), {
		Name = "Zone_" .. diff.Id,
		Transparency = 1,
		CanCollide = false,
	})
	zone:SetAttribute("PortalId", diff.Id)
	block(f, CFrame.new(ground + Vector3.new(0, 0.2, 0)), Vector3.new(14, 0.4, 14), { Name = "PadPlate", Color = diff.Color })
	local anchor = anchorPart(f, "BillboardAnchor", ground + Vector3.new(0, 14, 0))
	local gui = newBillboard(anchor, 20, 9, 0, 200)
	local card = cardPanel(gui, diff.Color, 0.2)
	local titleLabel = fitLabel(card, diff.DisplayName or diff.Id, "Title", COL.Text, "TitleLabel", 0.04, 0.04, 0.92, 0.36)
	local countLabel = fitLabel(card, "0 / " .. tostring(Config.Match.MaxPlayers) .. " players", "Display", COL.Text, "CountLabel", 0.04, 0.42, 0.92, 0.3)
	local statusLabel = fitLabel(card, "Waiting for players" .. ELLIPSIS, "Body", COL.TextGold, "StatusLabel", 0.04, 0.74, 0.92, 0.22)
	return {
		Id = diff.Id,
		Zone = zone,
		Center = zone.Position,
		Billboard = gui,
		TitleLabel = titleLabel,
		CountLabel = countLabel,
		StatusLabel = statusLabel,
	}
end

----------------------------------------------------------------------
-- Roads: ring road, spokes, shop neck, spot ramps
----------------------------------------------------------------------

local RING_TOP = TOP - 0.16 -- ring road surface (below every surface it docks into)
local SPOKE_TOP = TOP - 0.08 -- spokes and the shop neck sit between plaza and ring

local function spotDy(index)
	return SPOT_DY[(index - 1) % #SPOT_DY + 1]
end

-- A cloud walkway between two top-surface points: sand-coloured plank + soft cloud body underneath.
local function walkway(parent, a, b, width, name, bodyDrop)
	slab(parent, a, b, width, 1.2, { Name = name, Color = COL.Path })
	local drop = Vector3.new(0, 1.2, 0)
	slab(parent, a - drop, b - drop, math.max(2, width - 3), bodyDrop or 2.4, {
		Name = name .. "Body",
		Color = COL.Side,
		CanCollide = false,
	})
end

local function buildRoads(root, L)
	local f = newFolder(root, "Roads")
	local rng = Util.NewRng(SEED + 3)
	local ringR = L.RingR

	-- Ring road: short flat planks following the circle; both ends dock INTO the shop island.
	local arc = L.RingTo - L.RingFrom
	local segCount = math.max(1, math.ceil(arc / 7.5))
	local segStep = arc / segCount
	local len = 2 * ringR * math.sin(math.rad(segStep / 2)) + 1.8
	for i = 0, segCount - 1 do
		local theta = L.RingFrom + (i + 0.5) * segStep
		local a = math.rad(theta)
		local centre = polar(theta, ringR, RING_TOP)
		local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
		local radial = Vector3.new(math.cos(a), 0, math.sin(a))
		slab(f, centre - tangent * (len / 2), centre + tangent * (len / 2), ROAD_W, 1.2, {
			Name = "RingRoad",
			Color = COL.Path,
		})
		local bodyPos = centre - Vector3.new(0, 2.6, 0)
		block(f, CFrame.lookAt(bodyPos, bodyPos + tangent), Vector3.new(ROAD_W - 3, 2.8, len), {
			Name = "RingBody",
			Color = COL.Side,
			CanCollide = false,
		})
		-- One soft puff per plank, alternating inner / outer edge.
		local side = 1
		if i % 2 == 1 then
			side = -1
		end
		ball(f, centre + radial * (side * (ROAD_W / 2 - 0.6)) - Vector3.new(0, 1.9, 0), rng:Float(4.2, 6), {
			Name = "RingPuff",
			Color = COL.Puff:Lerp(COL.Side, rng:Float(0, 0.4)),
			CanCollide = false,
		})
	end

	-- Lamp posts on the ring road, between the spot ramps.
	for j = 1, #L.SpotAngles - 1 do
		local mid = (L.SpotAngles[j] + L.SpotAngles[j + 1]) / 2
		local side = 1
		if j % 2 == 0 then
			side = -1
		end
		lampPost(f, polar(mid, ringR + side * (ROAD_W / 2 - 0.9), RING_TOP), j % 3 == 0)
	end

	-- Spokes: plaza rim -> ring road (between the portals, so nothing blocks them).
	for _, deg in ipairs(L.SpokeAngles) do
		local p0 = polar(deg, SURF_R - 6, SPOKE_TOP)
		local p1 = polar(deg, ringR, SPOKE_TOP)
		walkway(f, p0, p1, SPOKE_W, "Spoke")
		local dir = p1 - p0
		local perp = perpendicular(dir)
		for k = 1, 4 do
			local t = 0.14 + (k - 1) * 0.2
			for _, s in ipairs({ -1, 1 }) do
				ball(f, p0 + dir * t + perp * (s * (SPOKE_W / 2 - 0.2)) - Vector3.new(0, 1.3 + rng:Float(0, 0.6), 0), rng:Float(3.2, 4.6), {
					Name = "SpokePuff",
					Color = COL.Puff:Lerp(COL.Side, rng:Float(0, 0.4)),
					CanCollide = false,
				})
			end
		end
		-- A lantern on each side where the spoke leaves the plaza.
		local gate = polar(deg, SURF_R + 3, SPOKE_TOP)
		lampPost(f, gate + perp * (SPOKE_W / 2 - 0.8), false)
		lampPost(f, gate - perp * (SPOKE_W / 2 - 0.8), false)
	end

	-- Ramp from the ring road up (or down) to every spot island.
	for i, deg in ipairs(L.SpotAngles) do
		local dy = spotDy(i)
		local p0 = polar(deg, ringR + 3, RING_TOP + 0.06)
		local p1 = polar(deg, SPOT_R - L.IslandR + 2.5, TOP + dy - 0.08)
		walkway(f, p0, p1, SPUR_W, "SpotRamp", 2.2)
		local dir = p1 - p0
		local perp = perpendicular(dir)
		for _, s in ipairs({ -1, 1 }) do
			ball(f, p0 + dir * 0.5 + perp * (s * (SPUR_W / 2 - 0.2)) - Vector3.new(0, 1.3, 0), rng:Float(2.8, 3.8), {
				Name = "RampPuff",
				Color = COL.Puff:Lerp(COL.Side, rng:Float(0, 0.4)),
				CanCollide = false,
			})
		end
	end
end

----------------------------------------------------------------------
-- Spot islands (one personal cloud home each)
----------------------------------------------------------------------

local function buildSpot(parent, index, angle, L)
	local dy = spotDy(index)
	local accent = ACCENTS[(index - 1) % #ACCENTS + 1]
	local f = newFolder(parent, string.format("Spot_%02d", index))
	local rng = Util.NewRng(SEED + 200 + index)
	local R = L.IslandR
	local a = math.rad(angle)
	local out = Vector3.new(math.cos(a), 0, math.sin(a))
	local c = polar(angle, SPOT_R, TOP + dy) -- centre of the island's walking surface
	local base = CFrame.lookAt(c, c + out) -- local -Z points away from the plaza

	-- Position / CFrame in island-local terms: x across, y up, depth = studs away from the plaza.
	local function at(x, y, depth)
		return (base * CFrame.new(x, y, -depth)).Position
	end
	local function frame(x, y, depth)
		return base * CFrame.new(x, y, -depth)
	end

	-- Island body.
	local topPart = disc(f, c - Vector3.new(0, 1.5, 0), R * 2, 3, {
		Name = "SpotTop",
		Color = COL.Top:Lerp(accent, 0.1),
		CastShadow = true,
	})
	islandBody(f, rng, c, R, 3, accent, 2)
	rimPuffs(f, rng, c, R - 0.4, 7, 5, 8, 0.2, 0.9, COL.Puff, { angle + 180 }, 40)
	emitter(topPart, {
		Color = ColorSequence.new(Color3.fromRGB(236, 224, 150), Color3.fromRGB(176, 228, 160)),
		Rate = 2,
		Lifetime = NumberRange.new(5, 8),
		Speed = NumberRange.new(0.3, 1),
		SpreadAngle = Vector2.new(180, 180),
		Size = popSize(0.4),
	})

	-- Home pad: this is where the owner stands and respawns.
	disc(f, at(0, 0.12, -1), 13.8, 0.24, { Name = "HomePadRing", Color = accent, CanCollide = false })
	disc(f, at(0, 0.25, -1), 13, 0.5, { Name = "HomePad", Color = COL.Top:Lerp(accent, 0.4) })
	disc(f, at(0, 0.54, -1), 9.6, 0.08, { Name = "HomePadInner", Color = COL.Top:Lerp(accent, 0.65), CanCollide = false })
	cushion(f, at(3.4, 0.5, -4), 2.8, accent:Lerp(COL.Top, 0.45))
	cushion(f, at(-3.9, 0.5, -3.2), 2.4, accent:Lerp(COL.Top, 0.55))

	-- Showcase podium for the owner's best pet.
	local podiumTop = at(0, 2.3, 9)
	disc(f, at(0, 0.9, 9), 6.6, 1.8, { Name = "PodiumBase", Color = COL.Side })
	disc(f, at(0, 1.9, 9), 6.4, 0.2, { Name = "PodiumGlow", Color = accent, Material = MAT.Neon, CanCollide = false })
	local podiumCap = disc(f, at(0, 2.05, 9), 5.6, 0.5, { Name = "PodiumTop", Color = COL.Top:Lerp(accent, 0.25) })
	emitter(podiumCap, {
		Color = ColorSequence.new(accent:Lerp(COL.Top, 0.4)),
		Rate = 3,
		Lifetime = NumberRange.new(2, 3),
		Speed = NumberRange.new(1, 2),
		Size = popSize(0.5),
	})

	-- Nameplate sign: two posts, a beam, an accent banner and the billboard above.
	local signDepth = 15
	for _, s in ipairs({ -1, 1 }) do
		disc(f, at(s * 7.2, 4.5, signDepth), 0.7, 9, { Name = "SignPost", Color = COL.WoodDark, Material = MAT.Wood })
		ball(f, at(s * 7.2, 1.0, signDepth), 3.4, { Name = "SignTuft", Color = COL.Puff, CanCollide = false })
	end
	block(f, frame(0, 8.8, signDepth), Vector3.new(16.4, 0.7, 0.8), { Name = "SignBeam", Color = COL.Wood, Material = MAT.WoodPlanks })
	block(f, frame(0, 6.4, signDepth - 0.1), Vector3.new(7, 4, 0.25), { Name = "SignBanner", Color = accent, CanCollide = false })

	local anchor = anchorPart(f, "NameplateAnchor", at(0, 13.2, signDepth), Vector3.new(1, 1, 1))
	local gui = newBillboard(anchor, 20, 6.4, 0, 150)
	gui.Name = "Nameplate"
	local card = cardPanel(gui, accent, 0.14)

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Position = UDim2.new(0.03, 0, 0.14, 0)
	badge.Size = UDim2.new(0.16, 0, 0.72, 0)
	badge.BackgroundColor3 = accent
	badge.BorderSizePixel = 0
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0.3, 0)
	badgeCorner.Parent = badge
	badge.Parent = card
	fitLabel(badge, tostring(index), "Display", COL.Ink, "Number", 0.05, 0.1, 0.9, 0.8)

	local nameLabel = fitLabel(card, "Free spot", "Title", COL.Text, "NameLabel", 0.22, 0.06, 0.74, 0.54)
	local subLabel = fitLabel(card, "Step in to claim", "Body", COL.TextGold, "SubLabel", 0.22, 0.6, 0.74, 0.3)

	-- Cosy corners: bench, lantern, flowers.
	local padPos = at(0, 0, -1)
	local benchPos = at(-11, 0, 3)
	bench(f, CFrame.lookAt(benchPos, Vector3.new(padPos.X, benchPos.Y, padPos.Z)))
	lampPost(f, at(11.5, 0, 1), true)
	flowerPatch(f, rng, at(-12, 0, 11), 2.8, 3)
	flowerPatch(f, rng, at(12.5, 0, 10), 2.8, 3)

	-- Variety: every third home also gets a blossom tree behind the pad.
	if index % 3 == 0 then
		lanternTree(f, rng, at(-13.5, 0, -8), 0.9, BLOSSOMS[index % #BLOSSOMS + 1], false)
	end

	f:SetAttribute("SpotIndex", index)
	local spawnPos = at(0, 3.7, -1)
	return {
		Index = index,
		Folder = f,
		Center = c,
		SpawnCFrame = CFrame.lookAt(spawnPos, Vector3.new(podiumTop.X, spawnPos.Y, podiumTop.Z)),
		NameLabel = nameLabel,
		SubLabel = subLabel,
		PodiumCFrame = CFrame.lookAt(podiumTop, podiumTop + out),
	}
end

-- Bare-minimum spot (see fallbackPortal): a disc, a podium and the two labels.
local function fallbackSpot(parent, index, angle, L)
	local f = newFolder(parent, string.format("SpotFallback_%02d", index))
	local dy = spotDy(index)
	local a = math.rad(angle)
	local out = Vector3.new(math.cos(a), 0, math.sin(a))
	local c = polar(angle, SPOT_R, TOP + dy)
	disc(f, c - Vector3.new(0, 1.5, 0), L.IslandR * 2, 3, { Name = "SpotTop", Color = COL.Top })
	disc(f, c + Vector3.new(0, 1.0, 0) + out * 8, 5, 2, { Name = "PodiumBase", Color = COL.Side })
	local anchor = anchorPart(f, "NameplateAnchor", c + Vector3.new(0, 12, 0) + out * 12)
	local gui = newBillboard(anchor, 18, 6, 0, 140)
	local card = cardPanel(gui, COL.TextGold, 0.2)
	local nameLabel = fitLabel(card, "Free spot", "Title", COL.Text, "NameLabel", 0.05, 0.06, 0.9, 0.55)
	local subLabel = fitLabel(card, "Step in to claim", "Body", COL.TextGold, "SubLabel", 0.05, 0.62, 0.9, 0.3)
	local podiumTop = c + Vector3.new(0, 2.0, 0) + out * 8
	local spawnPos = c + Vector3.new(0, 3.7, 0) - out * 1
	return {
		Index = index,
		Folder = f,
		Center = c,
		SpawnCFrame = CFrame.lookAt(spawnPos, Vector3.new(podiumTop.X, spawnPos.Y, podiumTop.Z)),
		NameLabel = nameLabel,
		SubLabel = subLabel,
		PodiumCFrame = CFrame.lookAt(podiumTop, podiumTop + out),
	}
end

----------------------------------------------------------------------
-- Decor islands (small gardens behind the portals)
----------------------------------------------------------------------

local function buildDecorIsland(parent, spec, angle, seedIndex, L)
	local f = newFolder(parent, "Decor_" .. spec.Name)
	local rng = Util.NewRng(SEED + 300 + seedIndex)
	local R = spec.Radius
	local dist = L.RingR - ROAD_W / 2 - 5 - R
	local c = polar(angle, dist, TOP + spec.Dy)

	local topPart = disc(f, c - Vector3.new(0, 2, 0), R * 2, 4, {
		Name = "IslandTop",
		Color = COL.Top,
		CastShadow = true,
	})
	islandBody(f, rng, c, R, 4, COL.Dusk, 2)
	rimPuffs(f, rng, c, R - 0.4, 6, 5, 7, 0.2, 0.9, COL.Puff, { angle }, 24)

	-- Short plank from the ring road's inner edge onto the island.
	local p0 = polar(angle, L.RingR - 3, RING_TOP + 0.06)
	local p1 = polar(angle, dist + R - 2.5, TOP + spec.Dy - 0.08)
	walkway(f, p0, p1, 6, "DecorPlank", 2.0)

	-- Features, kept off the plank's landing.
	local placer = newPlacer(rng)
	placer.Reserve(math.cos(math.rad(angle)) * (R - 2), math.sin(math.rad(angle)) * (R - 2), 6)
	local inner = angle + 180
	for _, feature in ipairs(spec.Features) do
		if feature == "Bench" then
			local x, z = placer.Find(3.6, R * 0.35, R * 0.65, inner - 90, inner + 90)
			if x then
				local pos = c + Vector3.new(x, 0, z)
				bench(f, CFrame.lookAt(pos, pos + Vector3.new(x, 0, z).Unit))
			end
		elseif feature == "Tree" then
			local x, z = placer.Find(4.2, R * 0.3, R * 0.65, 0, 360)
			if x then
				lanternTree(f, rng, c + Vector3.new(x, 0, z), rng:Float(0.9, 1.1), rng:Pick(BLOSSOMS), true)
			end
		elseif feature == "Pond" then
			local x, z = placer.Find(5.4, 0, R * 0.4, 0, 360)
			if x then
				pond(f, rng, c + Vector3.new(x, 0, z), rng:Float(3.2, 3.8))
			end
		elseif feature == "Flowers" then
			local x, z = placer.Find(4.2, R * 0.2, R * 0.7, 0, 360)
			if x then
				flowerPatch(f, rng, c + Vector3.new(x, 0, z), 3.4, 4)
			end
		elseif feature == "Tokens" then
			local x, z = placer.Find(6.5, 0, R * 0.2, 0, 360)
			if x then
				tokenShowcase(f, c + Vector3.new(x, 0, z))
			end
		elseif feature == "Crystals" then
			local x, z = placer.Find(5, 0, R * 0.3, 0, 360)
			if x then
				crystalCluster(f, rng, c + Vector3.new(x, 0, z))
			end
		elseif feature == "Lanterns" then
			for _ = 1, 2 do
				local x, z = placer.Find(1.5, R * 0.35, R * 0.7, 0, 360)
				if x then
					lampPost(f, c + Vector3.new(x, 0, z), true)
				end
			end
		elseif feature == "Telescope" then
			local x, z = placer.Find(2.5, R * 0.4, R * 0.7, inner - 70, inner + 70)
			if x then
				telescope(f, c + Vector3.new(x, 0, z), Vector3.new(x, 0, z))
			end
		end
	end

	nameTag(topPart, spec.Name, 15, 110)
end

----------------------------------------------------------------------
-- Shop island: four roulette machines, the item stall, a rarity guide
----------------------------------------------------------------------

-- Rarities (in Config order) that a roulette can actually pay out.
local function oddsRarities(roulette)
	local list = {}
	for _, rarity in ipairs(Config.Rarities) do
		if roulette.Odds and (roulette.Odds[rarity.Id] or 0) > 0 then
			list[#list + 1] = rarity
		end
	end
	return list
end

-- A chunky roulette machine. `cf` sits on the ground; its LookVector points at the customer.
-- Returns { Id, PromptPart, Center, Model }.
local function buildMachine(parent, cf, roulette)
	local model = Instance.new("Model")
	model.Name = "Machine_" .. roulette.Id
	model.Parent = parent

	local color = roulette.Color
	local deep = color:Lerp(COL.Ink, 0.45)
	local light = color:Lerp(COL.Top, 0.4)
	local function at(x, y, z)
		return (cf * CFrame.new(x, y, z)).Position
	end
	local function frame(x, y, z)
		return cf * CFrame.new(x, y, z)
	end

	-- Plinth + cabinet.
	disc(model, at(0, 0.15, 0), 11, 0.3, { Name = "PlinthRim", Color = deep })
	disc(model, at(0, 0.6, 0), 10, 0.6, { Name = "Plinth", Color = COL.Slate })
	local cabinet = block(model, frame(0, 2.7, 0), Vector3.new(7.2, 3.6, 5), {
		Name = "Cabinet",
		Color = COL.Slate,
		CastShadow = true,
	})
	local panel = block(model, frame(0, 2.9, -2.55), Vector3.new(5.6, 2.2, 0.2), {
		Name = "FrontPanel",
		Color = deep,
		CanCollide = false,
	})
	block(model, frame(0, 1.5, -2.55), Vector3.new(1.8, 0.28, 0.2), {
		Name = "CoinSlot",
		Color = COL.GoldDark,
		Material = MAT.Metal,
		CanCollide = false,
	})
	block(model, frame(0, 1.15, -3.0), Vector3.new(3.4, 0.5, 1.2), { Name = "Tray", Color = deep, CanCollide = false })

	-- "? ? ?" on the front panel: the pet is a mystery.
	local gui = surfaceGui(panel, 50)
	local bg = Instance.new("Frame")
	bg.Name = "Face"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundTransparency = 1
	bg.Parent = gui
	fitLabel(bg, "? ? ?", "Title", light, "Mystery", 0.05, 0.08, 0.9, 0.84)
	gui.Parent = panel

	-- Glass dome with the wheel inside; two bars spin like roulette spokes.
	local dome = ball(model, at(0, 6.5, 0), 6.8, {
		Name = "Dome",
		Color = light,
		Material = MAT.Glass,
		Transparency = 0.45,
		Reflectance = 0.1,
		CanCollide = false,
	})
	faceDisc(model, frame(0, 6.5, -0.3), 4.0, 0.4, { Name = "WheelBack", Color = deep, CanCollide = false })
	faceDisc(model, frame(0, 6.5, -0.6), 3.6, 0.2, { Name = "WheelRing", Color = color, CanCollide = false })
	faceDisc(model, frame(0, 6.5, -0.75), 2.2, 0.2, { Name = "WheelInner", Color = light, CanCollide = false })
	ball(model, at(0, 6.5, -0.95), 0.9, { Name = "WheelHub", Color = COL.Gold, CanCollide = false })
	for k = 0, 1 do
		local barCF = frame(0, 6.5, -0.9) * CFrame.Angles(0, 0, math.rad(k * 90))
		local bar = block(model, barCF, Vector3.new(3.4, 0.3, 0.15), {
			Name = "WheelBar",
			Color = COL.TextGold,
			Material = MAT.Neon,
			CanCollide = false,
		})
		later(function()
			loopTween(bar, 1.6, { CFrame = barCF * CFrame.Angles(0, 0, math.rad(90)) }, Enum.EasingStyle.Linear, false)
		end)
	end
	pointLight(dome, color, 0.9, 20)
	emitter(dome, {
		Color = ColorSequence.new(light, COL.Top),
		Rate = 4,
		Lifetime = NumberRange.new(1.5, 2.5),
		Speed = NumberRange.new(1, 2.5),
		SpreadAngle = Vector2.new(180, 180),
		Size = popSize(0.6),
	})
	ball(model, at(0, 10.1, 0), 0.9, { Name = "Finial", Color = COL.Gold, CanCollide = false })

	-- One gem per rarity this roulette can pay out (higher price = rarer gems).
	local rarities = oddsRarities(roulette)
	for i, rarity in ipairs(rarities) do
		ball(model, at((i - (#rarities + 1) / 2) * 1.0, 4.1, -2.55), 0.7, {
			Name = "RarityGem",
			Color = rarity.Color,
			Material = MAT.Neon,
			CanCollide = false,
		})
	end

	-- Lever and corner lamps.
	local leverCF = frame(4.6, 3.6, 0) * CFrame.Angles(0, 0, math.rad(35))
	mk(model, {
		Name = "LeverRod",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.6, 0.3, 0.3),
		CFrame = leverCF,
		Color = COL.GoldDark,
		Material = MAT.Metal,
		CanCollide = false,
	})
	ball(model, (leverCF * CFrame.new(1.3, 0, 0)).Position, 0.95, { Name = "LeverKnob", Color = color, CanCollide = false })
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			ball(model, at(sx * 3.2, 4.65, sz * 1.9), 0.45, {
				Name = "CabinetLamp",
				Color = COL.Lantern,
				Material = MAT.Neon,
				CanCollide = false,
			})
		end
	end

	-- Big readable name + price billboard.
	local anchor = anchorPart(model, "PriceAnchor", at(0, 13.4, 0))
	local bb = newBillboard(anchor, 13, 6.4, 0, 120)
	bb.Name = "PriceBillboard"
	local card = cardPanel(bb, color, 0.14)
	fitLabel(card, roulette.DisplayName or roulette.Id, "Title", light, "NameLabel", 0.04, 0.05, 0.92, 0.42)
	fitLabel(card, priceText(roulette.Price or 0), "Display", COL.TextGold, "PriceLabel", 0.04, 0.5, 0.92, 0.44)

	-- Invisible spot in front where PetService hangs the ProximityPrompt.
	local prompt = block(model, frame(0, 2.0, -5.3), Vector3.new(5, 4, 3), {
		Name = "PromptPart",
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
	})

	model.PrimaryPart = cabinet
	return {
		Id = roulette.Id,
		PromptPart = prompt,
		Center = cabinet.Position,
		Model = model,
	}
end

local function fallbackMachine(parent, cf, roulette)
	local model = Instance.new("Model")
	model.Name = "MachineFallback_" .. roulette.Id
	model.Parent = parent
	local cabinet = block(model, cf * CFrame.new(0, 3, 0), Vector3.new(7, 6, 5), { Name = "Cabinet", Color = roulette.Color })
	local anchor = anchorPart(model, "PriceAnchor", (cf * CFrame.new(0, 10, 0)).Position)
	local bb = newBillboard(anchor, 12, 5, 0, 120)
	local card = cardPanel(bb, roulette.Color, 0.2)
	fitLabel(card, roulette.DisplayName or roulette.Id, "Title", COL.Text, "NameLabel", 0.04, 0.05, 0.92, 0.45)
	fitLabel(card, priceText(roulette.Price or 0), "Display", COL.TextGold, "PriceLabel", 0.04, 0.52, 0.92, 0.4)
	local prompt = block(model, cf * CFrame.new(0, 2, -5), Vector3.new(5, 4, 3), {
		Name = "PromptPart",
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
	})
	model.PrimaryPart = cabinet
	return { Id = roulette.Id, PromptPart = prompt, Center = cabinet.Position, Model = model }
end

-- Cosy market stall with striped awning and three displayed items. Front = -Z of `cf`.
local function buildItemStall(parent, cf)
	local model = Instance.new("Model")
	model.Name = "ItemShop"
	model.Parent = parent
	local function frame(x, y, z)
		return cf * CFrame.new(x, y, z)
	end
	local function at(x, y, z)
		return (cf * CFrame.new(x, y, z)).Position
	end

	local rose = Color3.fromRGB(206, 120, 136)
	local cream = Color3.fromRGB(216, 206, 186)
	local sage = Color3.fromRGB(116, 176, 140)
	local sky = Color3.fromRGB(108, 150, 206)

	local counter = block(model, frame(0, 1.7, 0), Vector3.new(9, 3.4, 3.2), {
		Name = "Counter",
		Color = COL.Wood,
		Material = MAT.WoodPlanks,
		CastShadow = true,
	})
	block(model, frame(0, 3.55, 0), Vector3.new(9.6, 0.3, 3.8), { Name = "CounterTop", Color = cream })
	local stripeColors = { rose, sage, sky }
	for i = 1, 3 do
		block(model, frame((i - 2) * 2.9, 1.7, -1.65), Vector3.new(1.5, 2.8, 0.15), {
			Name = "CounterStripe",
			Color = stripeColors[i],
			CanCollide = false,
		})
	end

	-- Back wall, shelf and the displayed goods.
	block(model, frame(0, 3.6, 1.85), Vector3.new(9.2, 7.2, 0.4), { Name = "BackWall", Color = COL.WoodDark, Material = MAT.WoodPlanks })
	block(model, frame(0, 5.0, 1.2), Vector3.new(8.2, 0.3, 1.2), { Name = "Shelf", Color = COL.WoodLight, Material = MAT.WoodPlanks, CanCollide = false })
	-- Heal cloud: a plump green cloud with a pale cross.
	ball(model, at(-2.6, 5.95, 1.2), 1.6, { Name = "ItemHeal", Color = Color3.fromRGB(146, 208, 170), CanCollide = false })
	block(model, frame(-2.6, 5.95, 0.4), Vector3.new(0.9, 0.28, 0.2), { Name = "ItemHealCross", Color = cream, CanCollide = false })
	block(model, frame(-2.6, 5.95, 0.4), Vector3.new(0.28, 0.9, 0.2), { Name = "ItemHealCross", Color = cream, CanCollide = false })
	-- Shield bubble: a glassy blue bubble.
	ball(model, at(0, 5.95, 1.2), 1.9, {
		Name = "ItemShield",
		Color = Color3.fromRGB(110, 170, 230),
		Material = MAT.Glass,
		Transparency = 0.3,
		CanCollide = false,
	})
	ball(model, at(0, 5.95, 1.2), 0.8, { Name = "ItemShieldCore", Color = Color3.fromRGB(190, 220, 250), CanCollide = false })
	-- Phoenix feather: a flame-coloured plume.
	block(model, frame(2.6, 6.0, 1.2) * CFrame.Angles(0, 0, math.rad(-20)), Vector3.new(0.55, 2.3, 0.2), {
		Name = "ItemFeather",
		Color = Color3.fromRGB(226, 130, 70),
		CanCollide = false,
	})
	ball(model, at(2.95, 7.2, 1.2), 0.8, { Name = "ItemFeatherTip", Color = COL.Gold, Material = MAT.Neon, CanCollide = false })

	-- Posts and the striped awning, sloping down towards the customers.
	for _, sx in ipairs({ -1, 1 }) do
		disc(model, at(sx * 4.4, 4.0, 1.6), 0.5, 8, { Name = "AwningPostBack", Color = COL.WoodDark, Material = MAT.Wood })
		disc(model, at(sx * 4.6, 3.3, -2.6), 0.5, 6.6, { Name = "AwningPostFront", Color = COL.WoodDark, Material = MAT.Wood })
		local lamp = ball(model, at(sx * 4.6, 7.0, -2.6), 1.0, {
			Name = "StallLamp",
			Color = COL.Lantern,
			Material = MAT.Neon,
			CanCollide = false,
		})
		if sx == 1 then
			pointLight(lamp, COL.Lantern, 0.8, 16)
		end
	end
	local slope = math.rad(17.6)
	for i = 1, 6 do
		local x = (i - 3.5) * 1.6
		local stripe = rose
		if i % 2 == 0 then
			stripe = cream
		end
		block(model, frame(x, 7.3, -0.6) * CFrame.Angles(-slope, 0, 0), Vector3.new(1.6, 0.25, 6.0), {
			Name = "AwningStripe",
			Color = stripe,
			CanCollide = false,
		})
		ball(model, at(x, 6.4, -3.46), 0.9, { Name = "AwningFringe", Color = stripe, CanCollide = false })
	end

	for _, sx in ipairs({ -1, 1 }) do
		ball(model, at(sx * 5.4, 0.9, 0.5), 3.4, { Name = "StallPuff", Color = COL.Puff, CanCollide = false })
	end

	-- Sign above the stall.
	local anchor = anchorPart(model, "SignAnchor", at(0, 12, 0))
	local bb = newBillboard(anchor, 12, 5, 0, 100)
	bb.Name = "ItemShopBillboard"
	local card = cardPanel(bb, rose, 0.14)
	fitLabel(card, "Item Shop", "Title", COL.Text, "NameLabel", 0.04, 0.06, 0.92, 0.52)
	fitLabel(card, "Heal " .. BULLET .. " Shield " .. BULLET .. " Revive", "Body", COL.TextGold, "SubLabel", 0.04, 0.62, 0.92, 0.3)

	local prompt = block(model, frame(0, 2.0, -4.6), Vector3.new(5, 4, 3), {
		Name = "PromptPart",
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
	})
	model.PrimaryPart = counter
	return { PromptPart = prompt, Center = counter.Position, Model = model }
end

local function fallbackItemStall(parent, cf)
	local model = Instance.new("Model")
	model.Name = "ItemShopFallback"
	model.Parent = parent
	local counter = block(model, cf * CFrame.new(0, 1.7, 0), Vector3.new(9, 3.4, 3.2), { Name = "Counter", Color = COL.Wood })
	local prompt = block(model, cf * CFrame.new(0, 2, -4.6), Vector3.new(5, 4, 3), {
		Name = "PromptPart",
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
	})
	model.PrimaryPart = counter
	return { PromptPart = prompt, Center = counter.Position, Model = model }
end

-- Board that explains the roulettes: price, and which rarities each one can give.
local function buildRarityBoard(parent, cf)
	local board = signStructure(parent, cf, 18, 11, 15)
	local gui = surfaceGui(board, 40)
	local panel = signPanel(gui)
	fitLabel(panel, "WINGED PETS", "Title", COL.Gold, "Header", 0.04, 0.03, 0.92, 0.14)
	fitLabel(panel, "Pricier roulette = rarer pets", "Script", COL.Text, "Sub", 0.04, 0.17, 0.92, 0.1)

	for i, roulette in ipairs(Config.Roulettes) do
		local y = 0.3 + (i - 1) * 0.145
		fitLabel(panel, roulette.DisplayName or roulette.Id, "Heading", roulette.Color:Lerp(COL.Text, 0.3), "Name" .. i, 0.04, y, 0.4, 0.125, Enum.TextXAlignment.Left)
		fitLabel(panel, priceText(roulette.Price or 0), "Body", COL.TextGold, "Price" .. i, 0.43, y, 0.2, 0.125, Enum.TextXAlignment.Right)
		local rarities = oddsRarities(roulette)
		for k, rarity in ipairs(rarities) do
			local chip = Instance.new("Frame")
			chip.Name = "Chip"
			chip.Position = UDim2.new(0.66 + (k - 1) * 0.085, 0, y + 0.01, 0)
			chip.Size = UDim2.new(0.075, 0, 0.105, 0)
			chip.BackgroundColor3 = rarity.Color
			chip.BorderSizePixel = 0
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.3, 0)
			corner.Parent = chip
			chip.Parent = panel
			fitLabel(chip, string.sub(rarity.Id, 1, 1), "Heading", COL.Ink, "Initial", 0.1, 0.05, 0.8, 0.9)
		end
	end

	local legend = {}
	for _, rarity in ipairs(Config.Rarities) do
		legend[#legend + 1] = string.format('<font color="%s">%s</font>', hex(rarity.Color), rarity.Id)
	end
	local legendLabel = fitLabel(panel, table.concat(legend, "  "), "Body", COL.Text, "Legend", 0.03, 0.9, 0.94, 0.07)
	legendLabel.RichText = true
	gui.Parent = board
end

local function buildShop(root, L)
	local f = newFolder(root, "Shop")
	local rng = Util.NewRng(SEED + 4)
	local S = L.ShopCenter
	local R = L.ShopR
	local sd = L.ShopAngle -- direction plaza -> shop
	local entrance = sd + 180 -- direction shop -> plaza

	-- World position on the shop island at an angle (degrees) and distance from its centre.
	local function shopPoint(deg, dist)
		local a = math.rad(deg)
		return S + Vector3.new(math.cos(a) * dist, 0, math.sin(a) * dist)
	end
	local function lookAtCentre(pos)
		return CFrame.lookAt(pos, Vector3.new(S.X, pos.Y, S.Z))
	end

	-- Island body + the neck that joins it to the plaza.
	local topPart = disc(f, S - Vector3.new(0, 2, 0), R * 2, 4, { Name = "ShopTop", Color = COL.Top, CastShadow = true })
	islandBody(f, rng, S, R, 4, COL.Dusk, 3)
	rimPuffs(f, rng, S, R - 0.5, 12, 6, 9, 0.2, 1.0, COL.Puff, { entrance }, 24)
	walkway(f, polar(sd, SURF_R - 4, SPOKE_TOP), polar(sd, L.ShopDist - R + 6, SPOKE_TOP), 16, "ShopNeck", 2.4)
	local neckDir = Vector3.new(math.cos(math.rad(sd)), 0, math.sin(math.rad(sd)))
	local neckPerp = perpendicular(neckDir)
	for _, s in ipairs({ -1, 1 }) do
		lampPost(f, polar(sd, SURF_R + 1, SPOKE_TOP) + neckPerp * (s * 7), false)
	end

	-- Floor medallion + a floating token pedestal as the shop's centrepiece.
	local mStack = 0
	local mLayers = {
		{ d = 15, color = COL.GoldDark },
		{ d = 13.6, color = COL.Side },
		{ d = 10, color = COL.Top:Lerp(COL.Gold, 0.2) },
	}
	for _, layer in ipairs(mLayers) do
		disc(f, S + Vector3.new(0, mStack + 0.05, 0), layer.d, 0.1, { Name = "ShopMedallion", Color = layer.color, CanCollide = false })
		mStack = mStack + 0.1
	end
	tokenShowcase(f, S + Vector3.new(0, 0.3, 0), "Cloud Shop", "Spend tokens on pets & items")

	-- Entrance sign facing the plaza.
	local signPos = shopPoint(entrance, R - 10)
	local signCF = CFrame.lookAt(signPos, Vector3.new(ORIGIN.X, signPos.Y, ORIGIN.Z))
	local signBoard = signStructure(f, signCF, 12, 4.6, 12)
	local sgui = surfaceGui(signBoard, 50)
	local spanel = signPanel(sgui, COL.TextGold)
	fitLabel(spanel, "CLOUD SHOP", "Title", COL.Gold, "Name", 0.04, 0.08, 0.92, 0.56)
	fitLabel(spanel, "pets & items", "Script", COL.Text, "Sub", 0.04, 0.66, 0.92, 0.28)
	sgui.Parent = signBoard

	-- Roulette machines on the far arc, cheapest on the left as the customer walks in.
	local thetas = { -42, -14, 14, 42 }
	local roulettes = {}
	for i, roulette in ipairs(Config.Roulettes) do
		local theta = thetas[i]
		if theta == nil then
			theta = (i - (#Config.Roulettes + 1) / 2) * 28
		end
		local pos = shopPoint(sd + theta, 22)
		local cf = lookAtCentre(pos)
		local info
		local ok, result = pcall(buildMachine, f, cf, roulette)
		if ok then
			info = result
		else
			warn("[LobbyBuilder] roulette machine " .. tostring(roulette.Id) .. " failed: " .. tostring(result))
			info = fallbackMachine(f, cf, roulette)
		end
		roulettes[roulette.Id] = info
	end

	-- Item stall (east of the entrance) and rarity guide (west), both facing the centre.
	local itemShop
	local stallCF = lookAtCentre(shopPoint(entrance - 62, 21))
	local okStall, stall = pcall(buildItemStall, f, stallCF)
	if okStall then
		itemShop = stall
	else
		warn("[LobbyBuilder] item stall failed: " .. tostring(stall))
		itemShop = fallbackItemStall(f, stallCF)
	end
	local okBoard, boardErr = pcall(buildRarityBoard, f, lookAtCentre(shopPoint(entrance + 62, 21)))
	if not okBoard then
		warn("[LobbyBuilder] rarity board failed: " .. tostring(boardErr))
	end

	-- Cosy details around the rim.
	bench(f, lookAtCentre(shopPoint(sd + 92, 27.5)))
	bench(f, lookAtCentre(shopPoint(sd - 92, 27.5)))
	flowerPatch(f, rng, shopPoint(sd - 65, 28), 3.4, 3)
	flowerPatch(f, rng, shopPoint(sd + 65, 28), 3.4, 3)
	local lampAngles = { sd - 55, sd + 55, entrance - 42, entrance + 42 }
	for i, deg in ipairs(lampAngles) do
		lampPost(f, shopPoint(deg, 29), i <= 2)
	end

	nameTag(topPart, "Cloud Shop", 22, 140)
	local flies = anchorPart(f, "Fireflies", S + Vector3.new(0, 5, 0), Vector3.new(R * 1.5, 8, R * 1.5))
	emitter(flies, {
		Color = ColorSequence.new(Color3.fromRGB(236, 224, 150), Color3.fromRGB(176, 228, 160)),
		Rate = 5,
		Lifetime = NumberRange.new(5, 8),
		Speed = NumberRange.new(0.3, 1),
		SpreadAngle = Vector2.new(180, 180),
		Size = popSize(0.45),
	})

	return { Roulettes = roulettes, ItemShop = itemShop }
end

----------------------------------------------------------------------
-- Sky decoration: drifting clouds, a far cloud sea, distant banks, dust
----------------------------------------------------------------------

local function buildSky(root)
	local f = newFolder(root, "SkyDecor")
	local rng = Util.NewRng(SEED + 5)

	-- Drifting puffs: each cluster slides sideways and back forever (all parts share one tween).
	local driftCount = 8
	for i = 1, driftCount do
		local ang = (i - 1) * (360 / driftCount) + rng:Float(-15, 15)
		local dist = rng:Float(255, 330)
		local y = TOP + rng:Float(-10, 70)
		local radius = rng:Float(10, 17)
		local parts = cloudCluster(f, rng, polar(ang, dist, y), radius, { Puffs = 2, CanCollide = false, Transparency = 0.05 })
		local a = math.rad(ang)
		local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
		local sign = 1
		if rng:Chance(0.5) then
			sign = -1
		end
		local offset = tangent * (rng:Float(26, 46) * sign) + Vector3.new(0, rng:Float(-3, 3), 0)
		local period = rng:Float(26, 44)
		later(function()
			for _, p in ipairs(parts) do
				loopTween(p, period, { Position = p.Position + offset }, Enum.EasingStyle.Sine, true)
			end
		end)
	end

	-- A fluffy sea far under the lobby. Non-collidable, so falling players are caught by the
	-- kill-plane teleport rather than landing on it.
	for i = 1, 10 do
		local ang = (i - 1) * 36 + rng:Float(-14, 14)
		local dist = rng:Float(120, 420)
		local y = TOP - rng:Float(75, 130)
		cloudCluster(f, rng, polar(ang, dist, y), rng:Float(24, 42), {
			Puffs = 2,
			CanCollide = false,
			Color = COL.Dusk:Lerp(COL.Top, 0.4),
			Shade = COL.Dusk,
		})
	end

	-- Distant cloud banks on the horizon give the village a sense of scale.
	for i = 1, 6 do
		local ang = (i - 1) * 60 + rng:Float(-20, 20)
		local dist = rng:Float(430, 540)
		cloudCluster(f, rng, polar(ang, dist, TOP + rng:Float(-70, 10)), rng:Float(40, 62), {
			Puffs = 3,
			CanCollide = false,
			Color = COL.Side,
			Shade = COL.Shadow,
			Transparency = 0.12,
		})
	end

	-- High, slow sparkle dust around the whole village.
	local dust = anchorPart(f, "SkyDust", Vector3.new(ORIGIN.X, TOP + 20, ORIGIN.Z), Vector3.new(520, 90, 520))
	emitter(dust, {
		Color = ColorSequence.new(Color3.fromRGB(226, 208, 190), Color3.fromRGB(190, 206, 236)),
		Rate = 12,
		Lifetime = NumberRange.new(8, 12),
		Speed = NumberRange.new(0.3, 1.2),
		SpreadAngle = Vector2.new(180, 180),
		Size = popSize(0.8),
	})
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

local function section(name, fn)
	local ok, err = pcall(fn)
	if not ok then
		warn("[LobbyBuilder] section '" .. name .. "' failed: " .. tostring(err))
	end
end

-- Last-resort shop (see fallbackPortal): a disc with plain machines and a counter, all with their
-- PromptParts, so pets and items stay purchasable even if the pretty shop could not be built.
local function fallbackShop(root, L)
	local f = newFolder(root, "ShopFallback")
	local S = L.ShopCenter
	disc(f, S - Vector3.new(0, 2, 0), L.ShopR * 2, 4, { Name = "ShopTop", Color = COL.Top })
	walkway(f, polar(L.ShopAngle, SURF_R - 4, SPOKE_TOP), polar(L.ShopAngle, L.ShopDist - L.ShopR + 6, SPOKE_TOP), 16, "ShopNeck", 2.4)
	local roulettes = {}
	local count = #Config.Roulettes
	for i, roulette in ipairs(Config.Roulettes) do
		local pos = S + Vector3.new((i - (count + 1) / 2) * 12, 0, -12)
		roulettes[roulette.Id] = fallbackMachine(f, CFrame.lookAt(pos, pos + Vector3.new(0, 0, 1)), roulette)
	end
	local stallPos = S + Vector3.new(0, 0, 12)
	local stall = fallbackItemStall(f, CFrame.lookAt(stallPos, stallPos + Vector3.new(0, 0, 1)))
	return { Roulettes = roulettes, ItemShop = stall }
end

function LobbyBuilder.Build()
	stopAnimations()
	partCount = 0

	local old = Workspace:FindFirstChild("NimbusLobby")
	if old then
		old:Destroy()
	end

	local root = Instance.new("Folder")
	root.Name = "NimbusLobby"

	local L = computeLayout()
	local diffs = Config.Difficulties

	-- Gameplay-critical objects first (portals, spots, shop); each has a bare-bones fallback so a
	-- scenery bug can never remove the contract the other services rely on.
	local portals = {}
	local portalFolder = newFolder(root, "Portals")
	for i, diff in ipairs(diffs) do
		local angle = L.PortalAngles[i]
		local ok, result = pcall(buildPortal, portalFolder, Util.NewRng(SEED + 10 + i), diff, angle)
		if not ok then
			warn("[LobbyBuilder] portal " .. tostring(diff.Id) .. " failed: " .. tostring(result))
			result = fallbackPortal(portalFolder, diff, angle)
		end
		portals[diff.Id] = result
	end

	local spots = {}
	local spotFolder = newFolder(root, "Spots")
	for i = 1, SPOT_COUNT do
		local angle = L.SpotAngles[i]
		local ok, result = pcall(buildSpot, spotFolder, i, angle, L)
		if not ok then
			warn("[LobbyBuilder] spot " .. tostring(i) .. " failed: " .. tostring(result))
			result = fallbackSpot(spotFolder, i, angle, L)
		end
		spots[i] = result
	end

	local shop
	local okShop, shopResult = pcall(buildShop, root, L)
	if okShop then
		shop = shopResult
	else
		warn("[LobbyBuilder] shop failed: " .. tostring(shopResult))
		shop = fallbackShop(root, L)
	end

	-- Everything else is decoration: a failure there must not take the lobby down.
	section("plaza", function()
		buildPlaza(root, L)
	end)
	section("rainbow arch", function()
		buildArch(root)
	end)
	section("how-to board", function()
		buildHowToBoard(root, L)
	end)
	section("guide board", function()
		buildGuideBoard(root, L)
	end)
	section("roads", function()
		buildRoads(root, L)
	end)
	section("decor islands", function()
		local decorFolder = newFolder(root, "DecorIslands")
		for i, angle in ipairs(L.DecorAngles) do
			local spec = DECOR_SPECS[(i - 1) % #DECOR_SPECS + 1]
			section("decor " .. spec.Name, function()
				buildDecorIsland(decorFolder, spec, angle, i, L)
			end)
		end
	end)
	section("sky", function()
		buildSky(root)
	end)

	root.Parent = Workspace

	-- Start looping animations now that everything lives in the DataModel.
	for _, fn in ipairs(animQueue) do
		local ok, err = pcall(fn)
		if not ok then
			warn("[LobbyBuilder] animation failed: " .. tostring(err))
		end
	end
	animQueue = {}

	-- Spawn in the middle of the plaza, looking at the middle portal.
	local spawnPos = Vector3.new(ORIGIN.X, TOP + 3, ORIGIN.Z)
	local focus = portals[diffs[math.ceil(#diffs / 2)].Id]
	local lookTarget = Vector3.new(focus.Center.X, spawnPos.Y, focus.Center.Z)

	print(string.format("[LobbyBuilder] lobby built (%d parts, %d portals, %d spots)", partCount, #diffs, #spots))

	return {
		Folder = root,
		SpawnCFrame = CFrame.lookAt(spawnPos, lookTarget),
		Portals = portals,
		Spots = spots,
		Shop = shop,
	}
end

return LobbyBuilder
