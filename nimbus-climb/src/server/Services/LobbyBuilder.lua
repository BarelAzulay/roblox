-- LobbyBuilder (v3): builds the Nimbus Climb sky village in the DETAILED VOXEL style
-- (ARCHITECTURE_V3.md, "ART DIRECTION" + section 6), sculpted with shared/Voxel.lua.
--
-- Top view (+X right, +Z up the page, angles in degrees: x = cos, z = sin, plaza centre = Origin):
--
--   * PLAZA          a big round cloud island (walkable radius ~116). Its body is a tiered voxel cloud with
--                    puffy rim clouds; the top is tiled ground in layers: shaded lawn with flower pixels, a
--                    stone court with a golden medallion (arrows point at every portal), a stone promenade
--                    on the portal ring, stone / sand paths with borders, a wooden boardwalk to the shop
--                    with a fountain roundabout (Nimbus, the Cloudy Dragon, on top), a voxel rainbow arch
--                    with the welcome sign, notice boards, trees, lamps, benches, flower beds, bunting and
--                    banners in the difficulty colours.
--   * PORTAL GATES   Model Portal_<Id>: one per Config.Difficulties entry on Config.Lobby.PortalRingRadius,
--                    spread over the +Z half (Easy at 0 degrees ... Saint at 180). A sculpted cloud-and-stone
--                    ring gate in the difficulty colour, star gems, a tiled ready pad (the Zone) + billboard.
--   * SHOP ISLAND    at Config.Lobby.ShopOffset: four voxel gacha machines (Model Roulette_<Id>, built in
--                    the roulette colour), the striped item stall (Model ItemShop), a rarity board, a token
--                    statue and an entrance arch, joined to the plaza by a short stone neck.
--   * HOME PLOTS     Config.Lobby.SpotCount cloud islands on Config.Lobby.SpotRingRadius. Each has a flat
--                    PlotSize x PlotSize mowed lawn yard (kept EMPTY for the phase-2 home), fence posts and
--                    rails, a gate facing the ring street, a mailbox with the nameplate, the pet podium.
--   * RING STREET    a stone street along the front of every plot; wooden bridges join neighbouring plots
--                    at the junctions. Wooden spoke bridges (supported by cloud puffs) join the plaza to every
--                    other junction; two garden islands hang off the street; one junction slot stays free for
--                    the Storm Altar (LobbyInfo.AltarSite).
--   * SKY            voxel cumulus clouds around the village and a cloud sea far below.
--
-- LobbyBuilder.Build() -> LobbyInfo (ARCHITECTURE.md / _V2 / _V3 contract):
--   Folder, SpawnCFrame, Portals[id] = PortalInfo (+ Model), Spots[i] = SpotInfo, Shop = { Roulettes[id], ItemShop },
--   NpcSpots = { CFrame x6 }   ground-level CFrames on the plaza lawn beside the walkways, LookVector = towards
--                              the walkway / court, each with ~5 studs of free space for an NPC pedestal
--   AltarSite = CFrame | nil   reserved, empty spot inside the ring for the Storm Altar island (faces the plaza)
--   AltarDock = Vector3 | nil  inner edge of the street junction in front of it (where a bridge can dock)
-- SpotInfo also carries PlotCFrame (centre of the flat yard surface, LookVector = towards the gate),
-- PlotSize (= Config.Lobby.PlotSize), GateCFrame (gate, on the ground) and Accent (the plot colour).
-- Spot folders are named Spot_NN and carry the attribute SpotIndex; portal / roulette models are named
-- Portal_<Id> / Roulette_<Id> (tutorial targets).
--
-- Walkability: every walking surface is a flat collidable part at the plaza height (TOP); layers that meet
-- differ by at most 0.3 studs (no gaps, no jumps, no z-fighting: overlapping layers are offset in height).
-- No server-side animation (v3 replication rule): life comes from ParticleEmitters and lights only.
--
-- Part budget: <= ~6000 parts after the greedy voxel merge. Repeated decor (trees, lamps, benches, flower beds,
-- the whole plot with its island, fence and gate, cloud puffs, sky clouds) is sculpted once and :Clone()d.
-- No external assets: Parts, built-in particle textures and Theme-styled GUI text. Deterministic (seeded).
-- ProximityPrompts are NOT created here: PetService / ItemService attach them to the PromptParts.
--
-- Robustness: portals, spots, the shop machines and the item stall are what other services depend on. Each
-- is built inside pcall with a plain-part fallback that still returns the same LobbyInfo shape (the
-- fallbacks also cover a missing shared/Voxel module), and all decoration runs in guarded sections.
-- Plain Lua 5.1-compatible syntax only.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)
local Util = require(Shared.Util)

local LobbyBuilder = {}

local function loadShared(name)
	local inst = Shared:FindFirstChild(name)
	if not inst then
		return nil
	end
	local ok, result = pcall(require, inst)
	if ok and type(result) == "table" then
		return result
	end
	warn("[LobbyBuilder] shared/" .. name .. " unavailable: " .. tostring(result))
	return nil
end

local Voxel = loadShared("Voxel")

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

local LOBBY = Config.Lobby
local ORIGIN = LOBBY.Origin
local TOP = ORIGIN.Y -- y of every walking surface
local OX, OZ = ORIGIN.X, ORIGIN.Z
local PLAZA_R = (LOBBY.PlazaRadius or 110) + 6 -- walkable radius of the plaza ground
local PORTAL_R = LOBBY.PortalRingRadius or 88
local SPOT_R = LOBBY.SpotRingRadius or 300
local SPOT_COUNT = math.max(1, LOBBY.SpotCount or 16)
local PLOT = LOBBY.PlotSize or 72
local SEED = 20261009
local MAT = Enum.Material
local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"

-- Glyphs as UTF-8 byte escapes (keeps the source file ASCII).
local GLYPH = {
	StarFull = "\226\152\133",
	StarEmpty = "\226\152\134",
	Cloud = "\226\152\129",
	Bullet = "\226\128\162",
	Ellipsis = "\226\128\166",
}

local function atan2(y, x)
	if math.atan2 then
		return math.atan2(y, x)
	end
	return math.atan(y, x)
end

-- Layout numbers (studs). Plot-local frames: origin = yard centre on the ground, -Z = towards the plaza
-- (the gate side), +X = across.
local G = {}
G.CourtR = 29 -- stone court around the spawn
G.PromIn = PORTAL_R - 9 -- stone promenade ring the portal pads sit on
G.PromOut = PORTAL_R + 9
G.PathHalf = 5 -- radial stone paths (half width incl. border)
G.BoardHalf = 7 -- the wooden boardwalk to the shop
G.StubHalf = 5 -- sand paths to the spoke bridges
G.FountainD = 58 -- fountain roundabout, distance from the centre towards the shop
G.Step = 360 / SPOT_COUNT
G.HalfStep = G.Step / 2
G.PlotHalf = PLOT / 2
G.Verge = 4
G.StreetW = 14
G.StreetZ = -(G.PlotHalf + G.Verge + G.StreetW / 2) -- plot-local z of the street centre line
G.StreetR = SPOT_R + G.StreetZ -- distance of the street centre line from the origin
G.IslandHalfX = G.PlotHalf + 6
G.IslandBack = G.PlotHalf + 6
G.IslandFront = G.StreetZ - G.StreetW / 2
G.JunctionX = G.StreetR * math.tan(math.rad(G.HalfStep)) -- plot-local x of the junctions
G.StreetExt = (G.StreetW / 2) * math.tan(math.rad(G.HalfStep)) + 0.8 -- overlap past the junction
G.SpokeEndR = (G.StreetR - G.StreetW / 2) / math.cos(math.rad(G.HalfStep)) + 2.4
G.SpokeW = 10
G.GardenR = 186 -- garden island centres
G.GardenSize = 22 -- garden island radius

----------------------------------------------------------------------
-- Palette: cheerful but not blinding. Nothing is pure white (cloud tops stay below 249 on red).
----------------------------------------------------------------------

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local C = {
	CloudLight = rgb(244, 247, 252),
	Cloud = rgb(232, 238, 249),
	CloudShade = rgb(212, 222, 241),
	Mist = rgb(194, 211, 240),
	MistDark = rgb(170, 190, 228),
	Grass = rgb(108, 186, 86),
	GrassLight = rgb(132, 202, 98),
	GrassDark = rgb(86, 160, 76),
	Hedge = rgb(74, 146, 72),
	HedgeLight = rgb(100, 170, 84),
	Stone = rgb(208, 202, 190),
	StoneLight = rgb(226, 221, 209),
	StoneDark = rgb(172, 164, 154),
	StoneEdge = rgb(146, 138, 132),
	Sand = rgb(236, 214, 166),
	SandDark = rgb(212, 186, 138),
	Plank = rgb(196, 146, 98),
	PlankLight = rgb(214, 166, 114),
	PlankDark = rgb(152, 108, 72),
	Bark = rgb(132, 92, 62),
	Iron = rgb(64, 70, 92),
	IronLight = rgb(96, 104, 130),
	Gold = rgb(244, 198, 84),
	GoldDark = rgb(206, 154, 62),
	Lamp = rgb(255, 214, 140),
	Water = rgb(92, 178, 236),
	WaterDeep = rgb(62, 136, 212),
	Leaf = rgb(98, 178, 80),
	Pine = rgb(60, 138, 92),
	Blossom = rgb(246, 174, 204),
	BlossomWhite = rgb(250, 228, 238),
	Soil = rgb(120, 86, 64),
	Navy = rgb(34, 42, 76),
	Violet = rgb(68, 60, 118),
	Ink = (Theme.Colors and Theme.Colors.Ink) or rgb(26, 32, 64),
	Text = rgb(238, 243, 252),
	TextDim = rgb(190, 202, 230),
	TextGold = rgb(246, 216, 132),
	StarOff = rgb(96, 104, 136),
	Rose = rgb(234, 120, 146),
	Cream = rgb(246, 234, 210),
}

local FLOWERS = {
	rgb(246, 150, 188), -- pink
	rgb(250, 214, 92), -- yellow
	rgb(244, 244, 248), -- white (not pure)
	rgb(172, 142, 232), -- violet
	rgb(236, 104, 108), -- red
	rgb(112, 172, 240), -- blue
}

-- One accent per home plot (cycled): banner, mailbox flag, podium trim.
local ACCENTS = {
	rgb(232, 112, 132),
	rgb(240, 160, 84),
	rgb(236, 204, 92),
	rgb(108, 192, 124),
	rgb(86, 186, 206),
	rgb(98, 148, 226),
	rgb(154, 122, 222),
	rgb(222, 120, 192),
}

local RAINBOW = {
	rgb(232, 104, 116),
	rgb(242, 160, 86),
	rgb(244, 212, 96),
	rgb(108, 196, 120),
	rgb(96, 164, 232),
	rgb(156, 124, 226),
}

-- One palette for every voxel grid (keys are shared; Voxel derives missing _Light / _Dark variants).
local P = {
	CloudLight = C.CloudLight,
	Cloud = C.Cloud,
	CloudShade = C.CloudShade,
	Mist = C.Mist,
	MistDark = C.MistDark,
	Grass = C.Grass,
	GrassLight = C.GrassLight,
	GrassDark = C.GrassDark,
	Hedge = C.Hedge,
	Stone = C.Stone,
	StoneLight = C.StoneLight,
	StoneDark = C.StoneDark,
	StoneEdge = C.StoneEdge,
	Sand = C.Sand,
	SandDark = C.SandDark,
	Plank = C.Plank,
	PlankLight = C.PlankLight,
	PlankDark = C.PlankDark,
	Bark = C.Bark,
	Iron = C.Iron,
	Gold = C.Gold,
	GoldDark = C.GoldDark,
	GoldGlow = { Color = C.Gold, Material = MAT.Neon },
	Leaf = C.Leaf,
	Pine = C.Pine,
	Blossom = C.Blossom,
	BlossomWhite = C.BlossomWhite,
	Soil = C.Soil,
	Water = { Color = C.Water, Material = MAT.Glass, Transparency = 0.35 },
	WaterDeep = C.WaterDeep,
	Lamp = { Color = C.Lamp, Material = MAT.Neon },
	Rose = C.Rose,
	Cream = C.Cream,
}
for i, color in ipairs(FLOWERS) do
	P["Flower" .. i] = color
end
for i, color in ipairs(RAINBOW) do
	P["Rainbow" .. i] = color
end
for i, diff in ipairs(Config.Difficulties) do
	P["Diff" .. i] = diff.Color
end

-- Cloud keys used by tiers, from the top tier down (height-banded shading: cheap and soft).
local TIER_KEYS = { "CloudLight", "Cloud", "CloudShade", "Mist", "MistDark" }

----------------------------------------------------------------------
-- Per-build state
----------------------------------------------------------------------

local templates = {} -- name -> unparented Model built at the origin, cloned with place()
local reserved = {} -- { x, z, radius } world circles taken by plaza decor (keeps props apart)

----------------------------------------------------------------------
-- Small math helpers
----------------------------------------------------------------------

local function polar(angleDeg, radius, y)
	local a = math.rad(angleDeg)
	return Vector3.new(OX + math.cos(a) * radius, y or TOP, OZ + math.sin(a) * radius)
end

local function dirOf(angleDeg)
	local a = math.rad(angleDeg)
	return Vector3.new(math.cos(a), 0, math.sin(a))
end

-- CFrame at `pos` looking (flat) at `target`.
local function flatLook(pos, target)
	local d = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
	if d.Magnitude < 1e-3 then
		return CFrame.new(pos)
	end
	return CFrame.lookAt(pos, pos + d.Unit)
end

local function faceCentre(pos)
	return flatLook(pos, Vector3.new(OX, pos.Y, OZ))
end

local function angleDiff(a, b)
	local d = math.abs((a - b) % 360)
	if d > 180 then
		d = 360 - d
	end
	return d
end

local function nearAny(angle, list, half)
	for _, other in ipairs(list or {}) do
		if angleDiff(angle, other) < half then
			return true
		end
	end
	return false
end

-- angle inside [from, to] (degrees, from may be negative)
local function angleIn(angle, from, to)
	local a = (angle - from) % 360
	return a <= (to - from)
end

local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

-- Deterministic hash of integers -> [0, 1). The squared term makes hashes with different seeds independent.
local function hash3(x, y, z, seed)
	local h = (x * 73856093 + y * 19349663 + z * 83492791 + seed * 2654435761) % 2147483647
	h = (h * 16807) % 2147483647
	local a = h % 65521
	a = (a * a + seed * 7919 + 12345) % 65521
	h = ((h + a * 32771) * 16807) % 2147483647
	return h / 2147483647
end

-- Smooth 2D value noise in 0..1 (deterministic).
local function vnoise(x, z, scale, seed)
	local fx, fz = x / scale, z / scale
	local x0, z0 = math.floor(fx), math.floor(fz)
	local tx, tz = fx - x0, fz - z0
	tx = tx * tx * (3 - 2 * tx)
	tz = tz * tz * (3 - 2 * tz)
	local a, b = hash3(x0, 0, z0, seed), hash3(x0 + 1, 0, z0, seed)
	local c, d = hash3(x0, 0, z0 + 1, seed), hash3(x0 + 1, 0, z0 + 1, seed)
	local ab = a + (b - a) * tx
	local cd = c + (d - c) * tx
	return ab + (cd - ab) * tz
end

----------------------------------------------------------------------
-- Instance helpers
----------------------------------------------------------------------

local function newFolder(parent, name)
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function newModel(parent, name)
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	return model
end

-- One anchored block. opts: Collide (default false), Material, Transparency, Shadow, Reflectance.
local function box(parent, name, cf, size, color, opts)
	opts = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = opts.Material or MAT.SmoothPlastic
	p.Transparency = opts.Transparency or 0
	if opts.Reflectance then
		p.Reflectance = opts.Reflectance
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = opts.Collide == true
	p.CanQuery = opts.Collide == true or opts.Query == true
	p.CanTouch = false
	if opts.Shadow ~= nil then
		p.CastShadow = opts.Shadow == true
	else
		p.CastShadow = math.max(size.X, size.Y, size.Z) >= 4
	end
	p.Parent = parent
	return p
end

-- Invisible part used to host emitters / billboards / lights.
local function anchorPart(parent, name, pos, size)
	local p = box(parent, name, CFrame.new(pos), size or Vector3.new(1, 1, 1), C.Cloud, { Transparency = 1, Shadow = false })
	return p
end

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
	e.Color = ColorSequence.new(C.TextGold)
	e.LightEmission = 0.6
	e.LightInfluence = 0
	e.Rate = 6
	e.Lifetime = NumberRange.new(1.5, 2.5)
	e.Speed = NumberRange.new(1, 2)
	e.Size = popSize(0.7)
	e.Transparency = FADE_IN_OUT
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-60, 60)
	if props then
		for key, value in pairs(props) do
			e[key] = value
		end
	end
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

----------------------------------------------------------------------
-- GUI helpers (all text goes through Theme font roles)
----------------------------------------------------------------------
-- World text rule (ARCHITECTURE_V3.md, added after the playtest "letters too small"):
--   * Tags above things are PIXEL-sized BillboardGuis (offset UDim2), so their text keeps one on-screen size at
--     any distance: names >= 22 px and info lines >= 18 px at 1080p, outlined glyphs on a compact solid plate
--     that sizes itself to its text, LightInfluence 0 and a MaxDistance of ~60-120 studs.
--   * Signs on surfaces are SurfaceGuis at SIGN_PPS pixels per stud with FIXED text sizes: titles >= 1 stud,
--     info lines >= 0.6 stud.
--   * Never TextScaled in the world: the engine drew the auto-scaled world text tiny in the playtest.

local INK = (Theme.Colors and Theme.Colors.TextStroke) or C.Ink
local TAG_NAME = 28 -- px: the name / title of a tag
local TAG_INFO = 20 -- px: info lines of a tag
local TAG_SMALL = 18 -- px: badges and pills (the info-line minimum)
local TAG_RANGE = 110 -- studs: MaxDistance of an ordinary tag
local SIGN_PPS = 50 -- pixels per stud on every surface sign
local SIGN_TITLE = 56 -- px at SIGN_PPS = 1.12 studs
local SIGN_INFO = 30 -- px at SIGN_PPS = 0.6 stud

-- Pixel-sized tag on `adornee`. The `w` x `h` container is transparent (the plate inside sizes itself to its
-- text); SizeOffset puts the container's BOTTOM edge on the adornee, raised `lift` studs in world space, so the
-- tag grows upwards and never sinks into what it labels, whatever the camera distance.
local function newTag(adornee, name, w, h, lift, maxDistance)
	local gui = Instance.new("BillboardGui")
	gui.Name = name or "Tag"
	gui.Size = UDim2.fromOffset(w, h)
	gui.SizeOffset = Vector2.new(0, 0.5)
	gui.StudsOffsetWorldSpace = Vector3.new(0, lift or 0, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = maxDistance or TAG_RANGE
	gui.ClipsDescendants = false
	gui.Adornee = adornee
	gui.Parent = adornee
	return gui
end

local function listLayout(parent, direction, gap, hAlign)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = direction or Enum.FillDirection.Vertical
	layout.HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, gap or 0)
	layout.Parent = parent
	return layout
end

local function padding(parent, top, left, bottom, right)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, top)
	pad.PaddingLeft = UDim.new(0, left)
	pad.PaddingBottom = UDim.new(0, bottom or top)
	pad.PaddingRight = UDim.new(0, right or left)
	pad.Parent = parent
	return pad
end

local function rounded(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = (type(radius) == "number") and UDim.new(0, radius) or radius
	corner.Parent = parent
	return corner
end

local function outline(parent, color, thickness, transparency)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

local function vgradient(parent, top, bottom)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = 90
	g.Parent = parent
	return g
end

local function plainFrame(parent, name, props)
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	if props then
		for key, value in pairs(props) do
			f[key] = value
		end
	end
	f.Parent = parent
	return f
end

-- The compact solid plate of a tag in the HUD card look (navy gradient, rounded, a thick outline in `edge`),
-- sized to its content and standing on the bottom centre of the tag; its children are laid out by a list.
local function tagPlate(gui, edge, minW, direction, gap)
	local plate = plainFrame(gui, "Plate", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.fromOffset(minW or 0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = Color3.fromRGB(255, 255, 255), -- the gradient supplies the colour
		BackgroundTransparency = 0.04,
	})
	rounded(plate, 16)
	outline(plate, edge or C.TextGold, 3.5)
	vgradient(plate, (Theme.Colors and Theme.Colors.PanelLight) or C.Violet, (Theme.Colors and Theme.Colors.Panel) or C.Navy)
	padding(plate, 7, 16, 9)
	listLayout(plate, direction, gap or 2)
	return plate
end

-- Fixed-size outlined text that sizes itself to its text (tags, pills, list layouts).
local function tagText(parent, name, text, role, size, color, order, thickness)
	local label = Theme.Label(text, role, {
		Size = size,
		Color = color or C.Text,
		Stroke = 1, -- the glyph outline below replaces the classic text stroke
		Outline = thickness or 2.5,
		OutlineColor = INK,
		Props = {
			Name = name,
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, size + 4),
			TextWrapped = false,
			LayoutOrder = order or 0,
		},
	})
	label.Parent = parent
	return label
end

-- A rounded colour pill around one short text (status, price, rarity). Returns pill, label.
local function tagPill(parent, name, text, role, size, fill, order)
	local pill = plainFrame(parent, name, {
		Size = UDim2.fromOffset(0, size + 8),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = fill,
		BackgroundTransparency = 0,
		LayoutOrder = order or 0,
	})
	rounded(pill, math.floor(size * 0.55))
	outline(pill, INK, 2.5)
	padding(pill, 2, math.floor(size * 0.5), 3)
	local label = tagText(pill, name .. "Label", text, role, size, C.Text, 1, 2)
	return pill, label
end

local function surfaceGui(part, face)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = SIGN_PPS
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
	vgradient(panel, C.Violet, C.Navy)
	rounded(panel, 24)
	outline(panel, strokeColor or C.TextGold, 6, 0.2)
	panel.Parent = gui
	return panel
end

-- Sign text with a FIXED size (px at SIGN_PPS), placed with fractions of its parent (x, y, w, h).
local function signText(parent, text, role, size, color, name, x, y, w, h, align, wrap)
	local label = Theme.Label(text, role, {
		Size = size,
		Color = color,
		Stroke = 1,
		Outline = math.max(2, math.floor(size / 16 + 0.5)),
		OutlineColor = INK,
		Props = {
			Name = name,
			Position = UDim2.new(x, 0, y, 0),
			Size = UDim2.new(w, 0, h, 0),
			TextWrapped = wrap == true,
			TextXAlignment = align or Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
		},
	})
	label.Parent = parent
	return label
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
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

-- "50 <cloud>" / "5,000 <cloud>"
local function priceText(price)
	return Util.Commas(price) .. " " .. GLYPH.Cloud
end

-- Rich-text star row: `filled` gold stars then dim hollow ones up to `total`.
local function starRow(filled, total)
	local out = string.format('<font color="%s">%s</font>', hex(C.TextGold), string.rep(GLYPH.StarFull, filled))
	if total > filled then
		out = out .. string.format('<font color="%s">%s</font>', hex(C.StarOff), string.rep(GLYPH.StarEmpty, total - filled))
	end
	return out
end

-- A key-cap chip + a description: one row of a notice board (fractions of the 550 x 400 px board canvas).
local function keyRow(parent, y, rowH, keyText, descText)
	local chip = Instance.new("Frame")
	chip.Name = "KeyChip"
	chip.Size = UDim2.new(0.27, 0, rowH, 0)
	chip.Position = UDim2.new(0.04, 0, y, 0)
	chip.BackgroundColor3 = rgb(58, 66, 100)
	chip.BorderSizePixel = 0
	rounded(chip, 12)
	outline(chip, C.TextGold, 2.5, 0.25)
	chip.Parent = parent
	signText(chip, keyText, "Heading", SIGN_INFO, C.TextGold, "Key", 0, 0, 1, 1)
	signText(parent, descText, "Body", SIGN_INFO, C.Text, "Desc", 0.335, y, 0.64, rowH, Enum.TextXAlignment.Left)
end

----------------------------------------------------------------------
-- Voxel helpers
----------------------------------------------------------------------

local VX = {}

-- Vertical cylinder of voxels (voxel units). keep = only fill empty voxels.
function VX.Disc(g, cx, cz, r, y0, y1, key, keep)
	local ri = math.ceil(r) + 1
	local r2 = r * r
	for y = y0, y1 do
		for x = math.floor(cx) - ri, math.ceil(cx) + ri do
			for z = math.floor(cz) - ri, math.ceil(cz) + ri do
				local dx, dz = x - cx, z - cz
				if dx * dx + dz * dz <= r2 and (not keep or Voxel.Get(g, x, y, z) == nil) then
					Voxel.Set(g, x, y, z, key)
				end
			end
		end
	end
end

function VX.Ring(g, cx, cz, r0, r1, y0, y1, key)
	local ri = math.ceil(r1) + 1
	for y = y0, y1 do
		for x = math.floor(cx) - ri, math.ceil(cx) + ri do
			for z = math.floor(cz) - ri, math.ceil(cz) + ri do
				local dx, dz = x - cx, z - cz
				local d = math.sqrt(dx * dx + dz * dz)
				if d >= r0 and d <= r1 then
					Voxel.Set(g, x, y, z, key)
				end
			end
		end
	end
end

-- Inclusive integer box of voxels.
function VX.Fill(g, x0, x1, y0, y1, z0, z1, key)
	for y = y0, y1 do
		for x = x0, x1 do
			for z = z0, z1 do
				Voxel.Set(g, x, y, z, key)
			end
		end
	end
end

-- Rounded rectangle prism centred on (cx, cz): sx by sz voxels, corner radius `round`.
function VX.RoundRect(g, cx, cz, sx, sz, round, y0, y1, key, keep)
	local hx, hz = sx / 2, sz / 2
	round = math.max(0, math.min(round, hx, hz))
	for y = y0, y1 do
		for x = math.floor(cx - hx) - 1, math.ceil(cx + hx) + 1 do
			for z = math.floor(cz - hz) - 1, math.ceil(cz + hz) + 1 do
				local qx, qz = math.abs(x - cx) - (hx - round), math.abs(z - cz) - (hz - round)
				local ox, oz = math.max(qx, 0), math.max(qz, 0)
				local d = math.sqrt(ox * ox + oz * oz) + math.min(math.max(qx, qz), 0)
				if d <= round and (not keep or Voxel.Get(g, x, y, z) == nil) then
					Voxel.Set(g, x, y, z, key)
				end
			end
		end
	end
end

-- Moves every voxel whose base key is in `keys` into a new grid (for split collision / materials).
function VX.Split(g, keys)
	local out = Voxel.NewGrid(g.Resolution)
	local move = {}
	for k, v in pairs(g.Cells) do
		if keys[Voxel.BaseKey(v)] or keys[v] then
			move[#move + 1] = k
		end
	end
	for _, k in ipairs(move) do
		out.Cells[k] = g.Cells[k]
		out.Count = out.Count + 1
		g.Cells[k] = nil
		g.Count = g.Count - 1
	end
	return out
end

-- Voxel.Build with the lobby defaults. o: V (voxel size), Name, CF (where voxel 0,0,0 sits), Parent,
-- Collide, MaxParts, Keep, Shadow, Pal.
function VX.Build(g, o)
	if not g or g.Count == 0 then
		return nil
	end
	local model = Voxel.Build(g, {
		VoxelSize = o.V or 1,
		Palette = o.Pal or P,
		Name = o.Name or "Voxels",
		CFrame = o.CF or CFrame.new(),
		CanCollide = o.Collide == true,
		CanQuery = o.Collide == true,
		MaxParts = o.MaxParts,
		Keep = o.Keep,
		CastShadow = o.Shadow,
	})
	if o.Parent then
		model.Parent = o.Parent
	end
	return model
end

-- Clones a template (built at the origin) to `cf`; returns the clone.
local function place(tpl, cf, parent, name)
	if not tpl then
		return nil
	end
	local m = tpl:Clone()
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CFrame = cf * d.CFrame
		end
	end
	if name then
		m.Name = name
	end
	m.Parent = parent
	return m
end

local function template(name, make)
	local t = templates[name]
	if t == nil then
		local ok, result = pcall(make)
		if ok and result then
			t = result
		else
			warn("[LobbyBuilder] template " .. name .. " failed: " .. tostring(result))
			t = false
		end
		templates[name] = t
	end
	return t or nil
end

-- One flat layer of ground cells (a one-voxel-thick grid) whose top face sits at topY. fn(x, z) -> key | nil
-- gets the cell centre in studs relative to `centre`. Layers that overlap are offset in height (no z-fight).
local function groundLayer(parent, name, centre, radius, topY, cell, fn, maxParts)
	local g = Voxel.NewGrid(1)
	local n = math.ceil(radius / cell)
	for i = -n, n do
		for k = -n, n do
			local key = fn(i * cell, k * cell)
			if key then
				Voxel.Set(g, i, 0, k, key)
			end
		end
	end
	return VX.Build(g, {
		V = cell,
		Name = name,
		CF = CFrame.new(centre.X, topY - cell / 2, centre.Z),
		Collide = true,
		Shadow = false,
		Parent = parent,
		MaxParts = maxParts,
	})
end

-- A tiered voxel cloud body (tops at y = 0, V studs per voxel). spec:
--   Tiers = { { R = studs | SX =, SZ =, Round = studs, H = levels }, ... } from the top tier down
--   Puffs = { { x, y, z, rx, ry, rz } (studs, relative to the top centre) } soft bulges (shaded)
--   Rim = { same } puffs that rise above the walking surface; Carve = fn(x, y, z) -> remove voxel?
function VX.Cloud(spec)
	local V = spec.V or 3
	local g = Voxel.NewGrid(16)
	local y = 0
	for i, t in ipairs(spec.Tiers) do
		local key = t.Key or TIER_KEYS[math.min(i, #TIER_KEYS)]
		local h = t.H or 1
		if t.R then
			VX.Disc(g, 0, 0, t.R / V, y - h + 1, y, key)
		else
			VX.RoundRect(g, (t.X or 0) / V, (t.Z or 0) / V, t.SX / V, t.SZ / V, (t.Round or 6) / V, y - h + 1, y, key)
		end
		y = y - h
	end
	for _, p in ipairs(spec.Puffs or {}) do
		Voxel.Shape(g, { Kind = "Ellipsoid", Center = { p[1] / V, p[2] / V, p[3] / V }, Radius = { p[4] / V, p[5] / V, p[6] / V }, Key = "Puff", KeepExisting = true })
	end
	for _, p in ipairs(spec.Rim or {}) do
		Voxel.Shape(g, { Kind = "Ellipsoid", Center = { p[1] / V, p[2] / V, p[3] / V }, Radius = { p[4] / V, p[5] / V, p[6] / V }, Key = "Rim", KeepExisting = true })
	end
	if spec.Carve then
		local remove = {}
		for k in pairs(g.Cells) do
			local x, yy, z = Voxel.Unpack(k)
			if spec.Carve(x * V, yy * V, z * V) then
				remove[#remove + 1] = k
			end
		end
		for _, k in ipairs(remove) do
			g.Cells[k] = nil
			g.Count = g.Count - 1
		end
	end
	Voxel.Shade(g, { Only = { Puff = true, Rim = true }, Smooth = 2, Seed = spec.Seed or 1 })
	Voxel.Remap(g, {
		Puff = "Cloud",
		Puff_Light = "CloudLight",
		Puff_Dark = "Mist",
		Rim = "Cloud",
		Rim_Light = "CloudLight",
		Rim_Dark = "CloudShade",
	})
	return g
end

-- Builds a cloud spec at a CFrame whose position is the top centre of the cloud.
function VX.CloudModel(spec, cf, parent, name, collide)
	local V = spec.V or 3
	local g = VX.Cloud(spec)
	return VX.Build(g, {
		V = V,
		Name = name or "Cloud",
		CF = cf * CFrame.new(0, -V / 2, 0),
		Collide = collide,
		MaxParts = spec.MaxParts,
		Parent = parent,
	})
end

----------------------------------------------------------------------
-- Prop templates (sculpted once, cloned everywhere)
----------------------------------------------------------------------

local Props = {}

-- Detailed voxel trees (~18 studs, ~1.1-stud voxels). kind: "Round" (green, red fruit), "Blossom" (pink), "Pine".
-- Shapes are written in 1.4-stud units and scaled by S, so the voxels get finer without the tree changing size.
function Props.Tree(kind)
	return template("Tree" .. kind, function()
		local S = 1.3
		local function v(x, y, z)
			return { x * S, y * S, z * S }
		end
		local g = Voxel.NewGrid(16)
		local leaf = (kind == "Blossom") and "Blossom" or ((kind == "Pine") and "Pine" or "Leaf")
		-- trunk with a slight bend, flared roots and two branch stubs into the canopy
		Voxel.Shape(g, { Kind = "Curve", Points = { v(0, 0, 0), v(0.3, 2.4, 0), v(-0.2, 4.6, 0.2), v(0, 6.4, 0) }, Radius = 1.05 * S, RadiusB = 0.6 * S, Key = "Bark" })
		Voxel.Shape(g, { Kind = "Capsule", A = v(0, 0.3, 0), B = v(1.5, 0, 0.5), Radius = 0.55 * S, RadiusB = 0.25 * S, Key = "Bark" })
		Voxel.Shape(g, { Kind = "Capsule", A = v(0, 0.3, 0), B = v(-1.1, 0, -1.1), Radius = 0.55 * S, RadiusB = 0.25 * S, Key = "Bark" })
		Voxel.Shape(g, { Kind = "Capsule", A = v(0, 0.3, 0), B = v(-0.4, 0, 1.4), Radius = 0.5 * S, RadiusB = 0.25 * S, Key = "Bark" })
		if kind == "Pine" then
			-- three stacked, shrinking cone tiers
			Voxel.Shape(g, { Kind = "Cone", A = v(0, 3.2, 0), B = v(0, 8.6, 0), Radius = 4.6 * S, RadiusB = 1.2 * S, Key = leaf })
			Voxel.Shape(g, { Kind = "Cone", A = v(0, 6.6, 0), B = v(0, 11.4, 0), Radius = 3.7 * S, RadiusB = 0.8 * S, Key = leaf })
			Voxel.Shape(g, { Kind = "Cone", A = v(0, 9.6, 0), B = v(0, 14.2, 0), Radius = 2.6 * S, RadiusB = 0, Key = leaf })
		else
			Voxel.Shape(g, { Kind = "Curve", Points = { v(0, 5.4, 0), v(1.8, 7, 0.6) }, Radius = 0.45 * S, Key = "Bark" })
			Voxel.Shape(g, { Kind = "Curve", Points = { v(0, 5.8, 0), v(-1.6, 7.2, -0.8) }, Radius = 0.45 * S, Key = "Bark" })
			Voxel.Shape(g, { Kind = "Ellipsoid", Center = v(0, 8.3, 0), Radius = { 3.8 * S, 3.0 * S, 3.8 * S }, Key = leaf })
			Voxel.Shape(g, { Kind = "Ellipsoid", Center = v(2.3, 7.1, 1.1), Radius = { 2.4 * S, 2.1 * S, 2.4 * S }, Key = leaf })
			Voxel.Shape(g, { Kind = "Ellipsoid", Center = v(-2.1, 7.3, -1.4), Radius = { 2.5 * S, 2.1 * S, 2.5 * S }, Key = leaf })
			Voxel.Shape(g, { Kind = "Ellipsoid", Center = v(-0.8, 7.0, 2.3), Radius = { 2.2 * S, 2.0 * S, 2.2 * S }, Key = leaf })
			Voxel.Shape(g, { Kind = "Ellipsoid", Center = v(0.4, 10.6, -0.4), Radius = { 2.3 * S, 1.8 * S, 2.3 * S }, Key = leaf })
		end
		Voxel.Shade(g, { Smooth = 2, Noise = 0.05, Seed = 7 })
		local accent, onlyKey, chance = nil, nil, 0
		if kind == "Blossom" then
			accent, onlyKey, chance = "BlossomWhite", "Blossom_Light", 0.18 -- pale petals on the lit side
		elseif kind == "Round" then
			accent, onlyKey, chance = "Flower5", "Leaf", 0.05 -- small red fruit
		end
		if accent then
			Voxel.Shape(g, {
				Kind = "Ellipsoid",
				Center = v(0, 8.3, 0),
				Radius = { 5 * S, 4.5 * S, 5 * S },
				Op = "Paint",
				OnlyKeys = { [onlyKey] = true },
				Pattern = function(x, y, z)
					if hash3(x, y, z, 5) < chance then
						return accent
					end
					return false
				end,
			})
		end
		local V = 1.4 / S
		return VX.Build(g, { V = V, Name = kind .. "Tree", CF = CFrame.new(0, V / 2, 0), Collide = true, MaxParts = 54 })
	end)
end

-- Lamp post (~9 studs) with a warm neon lantern. Built from crafted blocks.
function Props.Lamp()
	return template("Lamp", function()
		local m = Instance.new("Model")
		m.Name = "Lamp"
		box(m, "LampBase", CFrame.new(0, 0.5, 0), Vector3.new(1.8, 1, 1.8), C.StoneDark, { Collide = true })
		box(m, "LampPole", CFrame.new(0, 4, 0), Vector3.new(0.6, 6.2, 0.6), C.Iron, { Collide = true })
		box(m, "LampCollar", CFrame.new(0, 7.2, 0), Vector3.new(1.2, 0.4, 1.2), C.IronLight)
		box(m, "LampGlass", CFrame.new(0, 8.1, 0), Vector3.new(1.1, 1.4, 1.1), C.Lamp, { Material = MAT.Neon })
		box(m, "LampRoof", CFrame.new(0, 9, 0), Vector3.new(1.7, 0.45, 1.7), C.Iron)
		box(m, "LampTip", CFrame.new(0, 9.45, 0), Vector3.new(0.6, 0.45, 0.6), C.GoldDark)
		return m
	end)
end

-- Wooden bench (plain parts, no Seat: running past must never sit you down). Faces -Z.
function Props.Bench()
	return template("Bench", function()
		local m = Instance.new("Model")
		m.Name = "Bench"
		box(m, "Seat", CFrame.new(0, 1.55, -0.45), Vector3.new(5.6, 0.4, 1), C.PlankLight, { Collide = true })
		box(m, "Seat", CFrame.new(0, 1.55, 0.55), Vector3.new(5.6, 0.4, 1), C.Plank, { Collide = true })
		box(m, "Back", CFrame.new(0, 2.55, 1.05), Vector3.new(5.6, 0.7, 0.3), C.PlankLight)
		box(m, "Back", CFrame.new(0, 3.35, 1.05), Vector3.new(5.6, 0.7, 0.3), C.Plank)
		box(m, "Frame", CFrame.new(-2.4, 1.6, 0.25), Vector3.new(0.4, 3.2, 2.2), C.Iron, { Collide = true })
		box(m, "Frame", CFrame.new(2.4, 1.6, 0.25), Vector3.new(0.4, 3.2, 2.2), C.Iron, { Collide = true })
		return m
	end)
end

-- Raised wooden flower bed (6 x 3) with leaves and flower pixels. variant picks the flower colours.
function Props.FlowerBed(variant)
	return template("FlowerBed" .. variant, function()
		local g = Voxel.NewGrid(4)
		for x = -3, 2 do
			for z = -2, 1 do
				local edge = x == -3 or x == 2 or z == -2 or z == 1
				Voxel.Set(g, x, 0, z, edge and "PlankDark" or "Soil")
				if not edge then
					local h = hash3(x, variant, z, 3)
					if h < 0.45 then
						Voxel.Set(g, x, 1, z, "Flower" .. (((variant + x + z) % 3 == 0) and variant or (variant % #FLOWERS + 1)))
					else
						Voxel.Set(g, x, 1, z, "Leaf")
					end
				end
			end
		end
		return VX.Build(g, { V = 1, Name = "FlowerBed", CF = CFrame.new(0.5, 0.5, 0.5), Collide = true, MaxParts = 16 })
	end)
end

-- A small voxel cloud puff (supports under bridges). size: "S" | "M".
function Props.Puff(size)
	return template("Puff" .. size, function()
		local s = (size == "M") and 1.35 or 1
		local spec = {
			V = 3,
			Tiers = { { R = 6 * s, H = 1 }, { R = 4.5 * s, H = 1 } },
			Puffs = {
				{ 5 * s, -1, 2 * s, 5 * s, 4 * s, 5 * s },
				{ -5 * s, -2, -1 * s, 5.5 * s, 4.5 * s, 5 * s },
				{ 0, -4, 0, 6 * s, 5 * s, 6 * s },
			},
			MaxParts = 22,
			Seed = 3,
		}
		return VX.CloudModel(spec, CFrame.new(), nil, "CloudPuff", false)
	end)
end

-- Bunting: a sagging rope with stepped voxel pennants in the given colours between two points.
local function bunting(parent, a, b, colors, sag)
	local m = newModel(parent, "Bunting")
	local span = b - a
	local len = span.Magnitude
	if len < 2 then
		return m
	end
	sag = sag or math.min(2, len * 0.06)
	local dir = span.Unit
	local count = math.max(2, math.floor(len / 4))
	local prev = a
	local pieces = 3
	for i = 1, pieces do
		local t = i / pieces
		local p = a + span * t - Vector3.new(0, sag * 4 * t * (1 - t), 0)
		local seg = p - prev
		local mid = (p + prev) * 0.5
		box(m, "Rope", CFrame.lookAt(mid, p), Vector3.new(0.18, 0.18, seg.Magnitude + 0.1), C.PlankDark, { Shadow = false })
		prev = p
	end
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(1, 0, 0)
	end
	for i = 1, count do
		local t = (i - 0.5) / count
		local p = a + span * t - Vector3.new(0, sag * 4 * t * (1 - t), 0)
		local color = colors[(i - 1) % #colors + 1]
		local cf = CFrame.lookAt(p, p + flat) * CFrame.Angles(0, math.rad(90), 0)
		box(m, "Pennant", cf * CFrame.new(0, -0.45, 0), Vector3.new(0.12, 0.7, 1.3), color, { Shadow = false })
		box(m, "Pennant", cf * CFrame.new(0, -1.05, 0), Vector3.new(0.12, 0.6, 0.6), color, { Shadow = false })
	end
	return m
end

-- Tall banner pole with a hanging cloth in `color` (and a gold finial). cf at ground level.
local function bannerPole(parent, cf, color)
	local m = newModel(parent, "Banner")
	box(m, "Pole", cf * CFrame.new(0, 5.5, 0), Vector3.new(0.5, 11, 0.5), C.Iron, { Collide = true })
	box(m, "Finial", cf * CFrame.new(0, 11.3, 0), Vector3.new(0.9, 0.7, 0.9), C.Gold)
	box(m, "Bar", cf * CFrame.new(0.9, 10.5, 0), Vector3.new(2.4, 0.3, 0.3), C.Iron)
	box(m, "Cloth", cf * CFrame.new(1.2, 8.2, 0), Vector3.new(2, 4.2, 0.15), color, { Shadow = false })
	box(m, "ClothTip", cf * CFrame.new(1.2, 5.75, 0), Vector3.new(1, 0.7, 0.15), color, { Shadow = false })
	return m
end

-- A wooden notice board with a small roof; returns the face part for the SurfaceGui. cf: ground, faces -Z.
local function noticeBoard(parent, cf, width, height, name)
	local m = newModel(parent, name or "NoticeBoard")
	local postH = height + 3.4
	for _, s in ipairs({ -1, 1 }) do
		box(m, "Post", cf * CFrame.new(s * (width / 2 + 0.5), postH / 2, 0), Vector3.new(1, postH, 1), C.PlankDark, { Collide = true })
		box(m, "PostFoot", cf * CFrame.new(s * (width / 2 + 0.5), 0.4, 0), Vector3.new(1.6, 0.8, 1.6), C.StoneDark, { Collide = true })
	end
	box(m, "Frame", cf * CFrame.new(0, 2.4 + height / 2, 0.15), Vector3.new(width + 0.6, height + 0.6, 0.6), C.Plank, { Collide = true })
	local face = box(m, "Face", cf * CFrame.new(0, 2.4 + height / 2, -0.2), Vector3.new(width, height, 0.2), C.Navy)
	box(m, "Roof", cf * CFrame.new(0, postH + 0.25, 0), Vector3.new(width + 3, 0.5, 2.4), C.PlankDark)
	box(m, "RoofTop", cf * CFrame.new(0, postH + 0.75, 0), Vector3.new(width + 1.6, 0.5, 1.4), C.Rose)
	return face, m
end

----------------------------------------------------------------------
-- Layout (derived once from Config.Lobby / Config.Difficulties)
----------------------------------------------------------------------

local function computeLayout()
	local diffs = Config.Difficulties
	local n = #diffs
	local L = {}

	-- Portals fan out over the +Z half of the plaza: the first (easiest) at angle 0 (+X), the last at 180.
	L.PortalStep = (n > 1) and (180 / (n - 1)) or 90
	L.PortalAngles = {}
	for i = 1, n do
		L.PortalAngles[i] = (n > 1) and ((i - 1) * L.PortalStep) or 90
	end
	L.MidAngle = L.PortalAngles[math.ceil(n / 2)] or 90
	L.PromFrom = (L.PortalAngles[1] or 0) - 14
	L.PromTo = (L.PortalAngles[n] or 180) + 14

	-- Shop island.
	local off = LOBBY.ShopOffset or Vector3.new(0, 0, -150)
	L.ShopCenter = Vector3.new(OX + off.X, TOP, OZ + off.Z)
	L.ShopDist = math.max(1, math.sqrt(off.X * off.X + off.Z * off.Z))
	L.ShopAngle = math.deg(atan2(off.Z, off.X)) % 360
	L.ShopR = clamp(L.ShopDist - PLAZA_R - 4, 18, 34)
	L.FountainX = math.cos(math.rad(L.ShopAngle)) * G.FountainD
	L.FountainZ = math.sin(math.rad(L.ShopAngle)) * G.FountainD

	-- Home plots sit between the junctions of the ring street; spokes join every other junction.
	L.PlotAngles = {}
	for i = 1, SPOT_COUNT do
		L.PlotAngles[i] = (i - 1) * G.Step + G.HalfStep
	end
	L.Junctions = {}
	L.SpokeAngles = {}
	for j = 0, SPOT_COUNT - 1 do
		local a = j * G.Step
		local info = { Angle = a, Index = j }
		L.Junctions[#L.Junctions + 1] = info
		if j % 2 == 1 and angleDiff(a, L.ShopAngle) > 14 and not nearAny(a, L.PortalAngles, 8) then
			info.Spoke = true
			L.SpokeAngles[#L.SpokeAngles + 1] = a
		end
	end

	-- Gardens (and the reserved Storm Altar site) hang off even junctions inside the ring.
	local function pickEven(target)
		local best, bestD = nil, 1e9
		for _, info in ipairs(L.Junctions) do
			local d = angleDiff(info.Angle, target)
			if not info.Spoke and not info.Garden and not info.Altar and d < bestD and angleDiff(info.Angle, L.ShopAngle) > 30 then
				best, bestD = info, d
			end
		end
		return best
	end
	L.Gardens = {}
	local specs = {
		{ Target = L.MidAngle - 45, Name = "Blossom Garden", Kind = "Blossom" },
		{ Target = L.MidAngle + 45, Name = "Lily Pond", Kind = "Pond" },
	}
	for _, spec in ipairs(specs) do
		local j = pickEven(spec.Target)
		if j then
			j.Garden = true
			L.Gardens[#L.Gardens + 1] = { Angle = j.Angle, Name = spec.Name, Kind = spec.Kind }
		end
	end
	local altar = pickEven(L.ShopAngle + 45)
	if altar then
		altar.Altar = true
		L.AltarAngle = altar.Angle
	end

	-- Exits through the plaza's soft cloud rim: spokes and the shop boardwalk.
	L.RimGaps = {}
	for _, a in ipairs(L.SpokeAngles) do
		L.RimGaps[#L.RimGaps + 1] = a
	end
	L.RimGaps[#L.RimGaps + 1] = L.ShopAngle

	-- Plaza path segments (plaza-local studs): { ax, az, dx, dz, len, half, kind }.
	local segs = {}
	local function segAB(ax, az, bx, bz, half, kind)
		local dx, dz = bx - ax, bz - az
		local len = math.max(0.01, math.sqrt(dx * dx + dz * dz))
		segs[#segs + 1] = { ax = ax, az = az, dx = dx / len, dz = dz / len, len = len, half = half, kind = kind }
	end
	local function seg(angle, r0, r1, half, kind)
		local d = dirOf(angle)
		segAB(d.X * r0, d.Z * r0, d.X * r1, d.Z * r1, half, kind)
	end
	for _, a in ipairs(L.PortalAngles) do
		seg(a, G.CourtR - 1, G.PromIn + 1, G.PathHalf, "Stone")
	end
	seg(L.ShopAngle, G.CourtR - 1, PLAZA_R + 1, G.BoardHalf, "Plank")
	for _, a in ipairs(L.SpokeAngles) do
		local e = dirOf(a)
		if angleIn(a, L.PromFrom, L.PromTo) then
			seg(a, G.PromOut - 1, PLAZA_R + 1, G.StubHalf, "Sand")
		elseif angleDiff(a, L.ShopAngle) <= 30 then
			-- the spokes beside the shop branch off the fountain roundabout
			segAB(L.FountainX, L.FountainZ, e.X * (PLAZA_R + 1), e.Z * (PLAZA_R + 1), G.StubHalf, "Sand")
		else
			-- start at the nearer end of the promenade (short paths, no long diagonals across the lawn)
			local endA = (angleDiff(a, L.PromFrom) < angleDiff(a, L.PromTo)) and (L.PromFrom + 4) or (L.PromTo - 4)
			local s0 = dirOf(endA)
			segAB(s0.X * PORTAL_R, s0.Z * PORTAL_R, e.X * (PLAZA_R + 1), e.Z * (PLAZA_R + 1), G.StubHalf, "Sand")
		end
	end
	L.PlazaSegs = segs
	return L
end

----------------------------------------------------------------------
-- Plaza: ground (layered voxel tiles), cloud body, decor
----------------------------------------------------------------------

local BORDER_KEY = { Stone = "StoneEdge", Sand = "SandDark", Plank = "PlankDark" }

local function segDist(px, pz, s)
	local rx, rz = px - s.ax, pz - s.az
	local t = rx * s.dx + rz * s.dz
	if t < 0 or t > s.len then
		return math.huge, t
	end
	return math.abs(-rx * s.dz + rz * s.dx), t
end

-- Keys of the plaza ground layers at a cell centre (plaza-local studs):
-- l1 lawn patches / flowers, l2 borders (just below the surface), l3 surfaces, l4 inlays.
local function plazaCell(x, z, L)
	local r = math.sqrt(x * x + z * z)
	if r > PLAZA_R - 0.5 then
		return nil
	end
	local ang = math.deg(atan2(z, x)) % 360
	local l1, l2, l3
	local n = vnoise(x + 400, z + 400, 46, 11)
	if n < 0.21 then
		l1 = "GrassDark"
	elseif n > 0.79 then
		l1 = "GrassLight"
	end
	-- court
	if r <= G.CourtR + 1 then
		l2 = "StoneEdge"
		if r <= G.CourtR - 1 then
			l3 = "Stone"
		end
	end
	-- promenade on the portal ring
	if r >= G.PromIn - 1 and r <= G.PromOut + 1 and angleIn(ang, L.PromFrom - 1.2, L.PromTo + 1.2) then
		l2 = l2 or "StoneEdge"
		if r >= G.PromIn + 1 and r <= G.PromOut - 1 and angleIn(ang, L.PromFrom, L.PromTo) then
			l3 = l3 or "Stone"
		end
	end
	-- fountain roundabout
	local fx, fz = x - L.FountainX, z - L.FountainZ
	local fr = math.sqrt(fx * fx + fz * fz)
	if fr <= 16 then
		l2 = l2 or "StoneEdge"
		if fr <= 14 then
			l3 = l3 or "Stone"
		end
	end
	-- paths
	for _, s in ipairs(L.PlazaSegs) do
		local d, t = segDist(x, z, s)
		if d <= s.half then
			l2 = l2 or BORDER_KEY[s.kind]
			if d <= s.half - 2 and not l3 then
				if s.kind == "Plank" then
					l3 = (math.floor(t / 4) % 2 == 0) and "Plank" or "PlankLight"
				else
					l3 = s.kind
				end
			end
		end
	end
	-- flower pixels on open lawn: a scattered meadow near the rim and a few denser patches
	if not l2 and not l3 then
		local h = hash3(math.floor(x), 0, math.floor(z), 21)
		local meadow = vnoise(x + 900, z + 900, 26, 5) > 0.84
		if (r > 101 and r < 111 and h < 0.035) or (meadow and h < 0.08) then
			l1 = "Flower" .. (math.floor(hash3(math.floor(x), 1, math.floor(z), 4) * #FLOWERS) + 1)
		end
	end
	return l1, l2, l3
end

-- The court medallion (1-stud inlay cells): a golden sun at the spawn, a coloured arrow pointing at every
-- portal, and a pale ring around them.
local function courtInlay(x, z, L)
	local r = math.sqrt(x * x + z * z)
	if r <= 3.6 then
		return "Gold"
	elseif r <= 4.8 then
		return "GoldDark"
	elseif r >= 16.4 and r <= 17.9 then
		return "StoneLight"
	end
	for i, pa in ipairs(L.PortalAngles) do
		local dx, dz = math.cos(math.rad(pa)), math.sin(math.rad(pa))
		local t = x * dx + z * dz
		local d = math.abs(-x * dz + z * dx)
		if t >= 8.5 and t <= 14.5 and d <= (14.6 - t) * 0.55 then
			return "Diff" .. i
		end
	end
	-- short sun rays between the arrows
	if r >= 5.6 and r <= 7.6 then
		local a = (math.deg(atan2(z, x)) - L.MidAngle) % 45
		if a < 7 or a > 38 then
			return "GoldDark"
		end
	end
	return nil
end

local function plazaKind(x, z, L)
	local r = math.sqrt(x * x + z * z)
	if r > PLAZA_R - 6 then
		return "edge"
	end
	local _, l2, l3 = plazaCell(x, z, L)
	if l2 or l3 then
		return "path"
	end
	return "lawn"
end

-- Is a circle (plaza-local) free lawn, away from paths, the rim and other decor?
local function plazaFree(x, z, radius, L)
	for _, o in ipairs({ { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.7, 0.7 }, { -0.7, 0.7 }, { 0.7, -0.7 }, { -0.7, -0.7 } }) do
		if plazaKind(x + o[1] * radius, z + o[2] * radius, L) ~= "lawn" then
			return false
		end
	end
	for _, rsv in ipairs(reserved) do
		local dx, dz = x - rsv[1], z - rsv[2]
		local need = radius + rsv[3]
		if dx * dx + dz * dz < need * need then
			return false
		end
	end
	return true
end

local function reserve(x, z, radius)
	reserved[#reserved + 1] = { x, z, radius }
end

-- Places a prop on the plaza lawn when the spot is free; returns the world ground position or nil.
local function plazaSpot(angle, radius, clearance, L, force)
	local d = dirOf(angle)
	local x, z = d.X * radius, d.Z * radius
	if not force and not plazaFree(x, z, clearance, L) then
		warn(string.format("[LobbyBuilder] plaza decor skipped at %.0f deg r=%.0f (not free)", angle, radius))
		return nil
	end
	reserve(x, z, clearance)
	return Vector3.new(OX + x, TOP, OZ + z), x, z
end

local function buildPlazaGround(f, L)
	local cell = 2
	local n = math.ceil(PLAZA_R / cell)
	local grids = { Voxel.NewGrid(1), Voxel.NewGrid(1), Voxel.NewGrid(1), Voxel.NewGrid(1), Voxel.NewGrid(1) }
	local r2 = (PLAZA_R - 0.5) * (PLAZA_R - 0.5)
	for i = -n, n do
		for k = -n, n do
			local x, z = i * cell, k * cell
			if x * x + z * z <= r2 then
				Voxel.Set(grids[1], i, 0, k, "Grass")
				local l1, l2, l3 = plazaCell(x, z, L)
				if l1 then
					Voxel.Set(grids[2], i, 0, k, l1)
				end
				if l2 then
					Voxel.Set(grids[3], i, 0, k, l2)
				end
				if l3 then
					Voxel.Set(grids[4], i, 0, k, l3)
				end
			end
		end
	end
	-- the medallion uses finer 1-stud cells
	local inlay = grids[5]
	local ci = math.ceil(G.CourtR)
	for i = -ci, ci do
		for k = -ci, ci do
			local key = courtInlay(i, k, L)
			if key then
				Voxel.Set(inlay, i, 0, k, key)
			end
		end
	end
	-- top surfaces: lawn -0.4, patches -0.3, borders -0.1, paths 0, inlays +0.1 (walkable steps, no z-fight;
	-- bridge decks that dock into the ground sit at -0.2)
	local tops = { -0.4, -0.3, -0.1, 0, 0.1 }
	local names = { "Lawn", "LawnPatches", "PathBorders", "Paths", "Inlays" }
	for li = 1, 5 do
		local cellSize = (li == 5) and 1 or cell
		VX.Build(grids[li], {
			V = cellSize,
			Name = names[li],
			CF = CFrame.new(OX, TOP + tops[li] - cellSize / 2, OZ),
			Collide = true,
			Shadow = false,
			Parent = f,
		})
	end
end

-- The plaza's cloud body: tiered, with lumpy side puffs and a soft rim of clouds around the lawn.
local function buildPlazaBody(f, L)
	local rng = Util.NewRng(SEED + 2)
	local R = PLAZA_R
	local puffs = {}
	for i = 1, 6 do
		local a = (i - 1) / 6 * math.pi * 2 + rng:Float(-0.2, 0.2)
		local tier = rng:Int(1, 2)
		local tr = ({ R - 8, R - 30 })[tier]
		local ty = ({ -7, -14 })[tier]
		local s = rng:Float(12, 17)
		puffs[#puffs + 1] = { math.cos(a) * tr, ty, math.sin(a) * tr, s, s * 0.7, s }
	end
	for i = 1, 3 do
		local a = rng:Float(0, math.pi * 2)
		local d = rng:Float(10, 40)
		puffs[#puffs + 1] = { math.cos(a) * d, -26, math.sin(a) * d, rng:Float(16, 24), rng:Float(8, 11), rng:Float(16, 24) }
	end
	-- rim puffs: one right beside every exit, the arcs between exits filled evenly (<= ~30 degrees apart)
	local rim = {}
	local gaps = {}
	for _, a in ipairs(L.RimGaps) do
		gaps[#gaps + 1] = a % 360
	end
	table.sort(gaps)
	local function addRim(adeg)
		local a = math.rad(adeg)
		local rr = R + rng:Float(-1, 1.5)
		local s = rng:Float(8.5, 11)
		rim[#rim + 1] = { math.cos(a) * rr, rng:Float(-1, 1.5), math.sin(a) * rr, s, s * 0.62, s }
	end
	if #gaps == 0 then
		gaps[1] = 0
	end
	for i, g0 in ipairs(gaps) do
		local g1 = gaps[i % #gaps + 1]
		local span = (g1 - g0) % 360
		if span == 0 then
			span = 360
		end
		local from, to = g0 + 9, g0 + span - 9
		if to > from then
			local n = math.max(1, math.ceil((to - from) / 30))
			for k = 0, n do
				addRim(from + (to - from) * k / n)
			end
		end
	end
	local spec = {
		V = 3,
		Tiers = {
			{ R = R + 3, H = 1 },
			{ R = R - 6, H = 2 },
			{ R = R - 28, H = 2 },
			{ R = R - 62, H = 3 },
		},
		Puffs = puffs,
		Rim = rim,
		-- keep the walking area clear: nothing of the body may rise above the lawn inside the rim
		Carve = function(x, y, z)
			return y > 0 and (x * x + z * z) < (R - 6) * (R - 6)
		end,
		Seed = 4,
		MaxParts = 360,
	}
	-- top of tier 1 sits 1.2 under the lawn surface; rim puffs rise up to ~5 studs above the lawn
	VX.CloudModel(spec, CFrame.new(OX, TOP - 1.2, OZ), f, "PlazaCloud", true)
end

-- Fountain on the roundabout: stone basin, translucent water, two tiers with falling water, spray, and
-- Nimbus the Cloudy Dragon (PetBuilder) perched on top when the pet modules are available.
local function buildFountain(f, centre, lookTarget)
	local m = newModel(f, "Fountain")
	local g = Voxel.NewGrid(16)
	VX.Ring(g, 0, 0, 7.6, 9.6, 0, 1, "Stone")
	VX.Ring(g, 0, 0, 7.2, 10.1, 2, 2, "StoneLight")
	VX.Disc(g, 0, 0, 7.6, 0, 0, "WaterDeep")
	VX.Disc(g, 0, 0, 7.6, 1, 1, "Water")
	VX.Disc(g, 0, 0, 1.7, 1, 4, "Stone")
	VX.Disc(g, 0, 0, 4.3, 4, 4, "StoneLight")
	VX.Ring(g, 0, 0, 3.4, 4.3, 5, 5, "StoneLight")
	VX.Disc(g, 0, 0, 3.3, 5, 5, "Water")
	VX.Disc(g, 0, 0, 1.1, 6, 8, "Stone")
	VX.Disc(g, 0, 0, 2.5, 8, 8, "StoneLight")
	VX.Ring(g, 0, 0, 1.7, 2.5, 9, 9, "StoneLight")
	VX.Disc(g, 0, 0, 1.6, 9, 9, "Water")
	-- falling water from both bowls
	for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
		VX.Fill(g, d[1] * 5, d[1] * 5, 2, 4, d[2] * 5, d[2] * 5, "Water")
		VX.Fill(g, d[1] * 3, d[1] * 3, 6, 8, d[2] * 3, d[2] * 3, "Water")
	end
	-- gold trim studs on the rim
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		Voxel.Set(g, math.floor(math.cos(a) * 8.6 + 0.5), 2, math.floor(math.sin(a) * 8.6 + 0.5), "Gold")
	end
	Voxel.Shade(g, { Only = { Stone = true, StoneLight = true }, Smooth = 1, Seed = 2 })
	local water = VX.Split(g, { Water = true })
	local cf = CFrame.new(centre.X, TOP + 0.5, centre.Z)
	VX.Build(g, { V = 1, Name = "Basin", CF = cf, Collide = true, Parent = m, MaxParts = 64 })
	VX.Build(water, { V = 1, Name = "Water", CF = cf, Collide = false, Parent = m })

	local spray = anchorPart(m, "Spray", centre + Vector3.new(0, 10.6, 0))
	emitter(spray, {
		Color = ColorSequence.new(rgb(206, 236, 255), rgb(150, 208, 250)),
		Rate = 26,
		Lifetime = NumberRange.new(0.9, 1.4),
		Speed = NumberRange.new(5, 8),
		SpreadAngle = Vector2.new(24, 24),
		Acceleration = Vector3.new(0, -18, 0),
		Size = popSize(0.55),
		LightEmission = 0.3,
	})
	pointLight(spray, rgb(170, 220, 255), 0.6, 18)

	-- Nimbus on top (optional)
	local ok, err = pcall(function()
		local builderModule = Shared:FindFirstChild("PetBuilder")
		local catalogModule = Shared:FindFirstChild("PetCatalog")
		if not builderModule or not catalogModule then
			return
		end
		local PetBuilder = require(builderModule)
		local PetCatalog = require(catalogModule)
		local def = PetCatalog.Get and PetCatalog.Get("cloudy_dragon")
		if not def or type(PetBuilder.Build) ~= "function" then
			return
		end
		local pet = PetBuilder.Build(def, { Scale = 2.6, Detail = "Low" })
		if not pet then
			return
		end
		pet.Name = "NimbusStatue"
		local topY = TOP + 10.5
		pet:PivotTo(CFrame.new(0, 0, 0))
		local boxCf, boxSize = pet:GetBoundingBox()
		local bottom = pet:GetPivot().Position.Y - (boxCf.Position.Y - boxSize.Y * 0.5)
		if type(bottom) ~= "number" or bottom ~= bottom or bottom < -50 or bottom > 100 then
			bottom = 2
		end
		local y = topY + bottom + 0.6
		pet:PivotTo(flatLook(Vector3.new(centre.X, y, centre.Z), lookTarget))
		for _, d in ipairs(pet:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
			end
		end
		pet.Parent = m
	end)
	if not ok then
		warn("[LobbyBuilder] fountain statue skipped: " .. tostring(err))
	end
	return m
end

-- Voxel rainbow arch over the main path, with the welcome sign standing on its crown.
local function buildArch(f, L)
	local m = newModel(f, "WelcomeArch")
	local angle = L.MidAngle
	local base = polar(angle, 54, TOP)
	local cf = flatLook(base, base + dirOf(angle)) -- local -Z = along the path, away from the court
	local V = 1.5
	local g = Voxel.NewGrid(16)
	Voxel.Shape(g, {
		Kind = "Torus",
		Center = { 0, 0, 0 },
		Radius = 9.5,
		Thickness = 2.6,
		Arc = { 0, math.pi },
		Rotation = CFrame.Angles(-math.pi / 2, 0, 0),
		Bias = 0.1,
		Key = "Rainbow1",
		Pattern = function(x, y, z)
			if math.abs(z) > 0.6 then
				return false
			end
			local d = math.sqrt(x * x + y * y)
			local band = clamp(math.floor((12.2 - d) / (5.2 / 6)) + 1, 1, 6)
			return "Rainbow" .. band
		end,
	})
	-- remove everything under the ground line, then cloud puffs hug both feet
	local remove = {}
	for k in pairs(g.Cells) do
		local _, y = Voxel.Unpack(k)
		if y < 0 then
			remove[#remove + 1] = k
		end
	end
	for _, k in ipairs(remove) do
		g.Cells[k] = nil
		g.Count = g.Count - 1
	end
	for _, s in ipairs({ -1, 1 }) do
		Voxel.Shape(g, { Kind = "Ellipsoid", Center = { s * 9.5, 1, 0 }, Radius = { 3.4, 2.4, 2.6 }, Key = "Puff" })
		Voxel.Shape(g, { Kind = "Ellipsoid", Center = { s * 11.2, 0.4, 0.6 }, Radius = { 2.2, 1.7, 2 }, Key = "Puff" })
		Voxel.Shape(g, { Kind = "Ellipsoid", Center = { s * 7.8, 0.2, -0.5 }, Radius = { 2, 1.5, 1.8 }, Key = "Puff" })
	end
	Voxel.Shade(g, { Only = { Puff = true }, Smooth = 2, Seed = 6 })
	Voxel.Remap(g, { Puff = "Cloud", Puff_Light = "CloudLight", Puff_Dark = "CloudShade" })
	VX.Build(g, {
		V = V,
		Name = "Rainbow",
		CF = cf * CFrame.new(0, V / 2, 0),
		Collide = true,
		Parent = m,
		MaxParts = 96,
		Keep = { "Rainbow1", "Rainbow2", "Rainbow3", "Rainbow4", "Rainbow5", "Rainbow6" },
	})
	for _, s in ipairs({ -1, 1 }) do
		reserve(base.X - OX + cf.RightVector.X * s * 14, base.Z - OZ + cf.RightVector.Z * s * 14, 6)
	end

	-- welcome sign standing on the crown, readable from the spawn (front) and from the portals (back)
	local crownY = 12.4 * V
	local boardCf = cf * CFrame.new(0, crownY + 3.4, 0) * CFrame.Angles(0, math.pi, 0)
	box(m, "SignPostL", cf * CFrame.new(-4.5, crownY + 0.6, 0), Vector3.new(0.8, 2, 0.8), C.PlankDark)
	box(m, "SignPostR", cf * CFrame.new(4.5, crownY + 0.6, 0), Vector3.new(0.8, 2, 0.8), C.PlankDark)
	box(m, "SignFrame", boardCf, Vector3.new(19.4, 6.4, 0.8), C.Plank)
	local board = box(m, "WelcomeSign", boardCf, Vector3.new(18.4, 5.4, 1.0), C.Navy, { Shadow = true })
	-- 920 x 270 px canvas: the name 2 studs tall, the two script lines 0.72 stud
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = surfaceGui(board, face)
		local panel = signPanel(gui, C.TextGold)
		signText(panel, "~ welcome to the clouds ~", "Script", 36, C.TextGold, "Welcome", 0.04, 0.05, 0.92, 0.17)
		local title = signText(panel, Config.GameName, "Title", 100, rgb(255, 255, 255), "Title", 0.03, 0.23, 0.94, 0.44)
		textGradient(title, {
			{ 0, rgb(255, 236, 160) },
			{ 0.5, rgb(255, 255, 255) },
			{ 1, rgb(180, 220, 255) },
		}, 90)
		signText(panel, Config.Tagline or "", "Script", 36, C.Text, "Tagline", 0.04, 0.72, 0.92, 0.17)
		gui.Parent = board
	end
	return m
end

-- "How to play" and "Guide" notice boards on both sides of the main path, facing the spawn.
local function buildBoards(f, L)
	local function spotFor(angle)
		local pos = plazaSpot(angle, 42, 6, L)
		if not pos then
			return nil
		end
		return faceCentre(pos) -- the board's face (-Z, the Front face) looks at the centre
	end
	-- 550 x 400 px canvas (11 x 8 studs): a 1.04-stud header, five 0.6-stud rows, a 0.6-stud footer
	local howCf = spotFor(L.MidAngle - L.PortalStep * 0.5)
	if howCf then
		local face = noticeBoard(f, howCf, 11, 8, "HowToBoard")
		local gui = surfaceGui(face, Enum.NormalId.Front)
		local panel = signPanel(gui)
		signText(panel, "HOW TO PLAY", "Title", 52, C.Gold, "Header", 0.04, 0.025, 0.92, 0.14)
		local rows = {
			{ "W A S D", "Move around" },
			{ "SHIFT", "Hold to run" },
			{ "Q", "Dash over wide gaps" },
			{ "SPACE", "Jump" },
			{ "1 - 4", "Use items (in a climb)" },
		}
		for i, row in ipairs(rows) do
			keyRow(panel, 0.18 + (i - 1) * 0.12, 0.105, row[1], row[2])
		end
		signText(panel, "Step into a glowing PORTAL to climb with friends!", "Body", SIGN_INFO, C.TextGold, "Footer", 0.05, 0.785, 0.9, 0.19, nil, true)
		gui.Parent = face
	end
	local guideCf = spotFor(L.MidAngle + L.PortalStep * 0.5)
	if guideCf then
		local face = noticeBoard(f, guideCf, 11, 8, "GuideBoard")
		local gui = surfaceGui(face, Enum.NormalId.Front)
		local panel = signPanel(gui, rgb(150, 200, 255))
		signText(panel, "CLOUD GUIDE", "Title", 52, C.Gold, "Header", 0.04, 0.025, 0.92, 0.14)
		local lines = {
			{ "TOKENS", "Collect " .. GLYPH.Cloud .. " on climbs" },
			{ "SHOP", "Spin roulettes for pets" },
			{ "PETS", "Pets give you perks" },
			{ "HOME", "Homes: the outer ring" },
			{ "FRIENDS", "Chat with plaza pets" },
		}
		for i, line in ipairs(lines) do
			keyRow(panel, 0.18 + (i - 1) * 0.12, 0.105, line[1], line[2])
		end
		signText(panel, "Harder portals pay more tokens!", "Body", SIGN_INFO, C.TextGold, "Footer", 0.05, 0.81, 0.9, 0.13)
		gui.Parent = face
	end
end

-- Plaza decor: fountain, arch, boards, NPC spots, trees, lamps, benches, flower beds, bunting, banners.
local function buildPlazaDecor(f, L)
	local diffColors = {}
	for i, d in ipairs(Config.Difficulties) do
		diffColors[i] = d.Color
	end
	reserve(L.FountainX, L.FountainZ, 15)
	reserve(0, 0, G.CourtR + 2)

	local fountainPos = Vector3.new(OX + L.FountainX, TOP, OZ + L.FountainZ)
	local okF, errF = pcall(buildFountain, f, fountainPos, Vector3.new(OX, TOP, OZ))
	if not okF then
		warn("[LobbyBuilder] fountain failed: " .. tostring(errF))
	end
	local okA, errA = pcall(buildArch, f, L)
	if not okA then
		warn("[LobbyBuilder] arch failed: " .. tostring(errA))
	end
	local okB, errB = pcall(buildBoards, f, L)
	if not okB then
		warn("[LobbyBuilder] boards failed: " .. tostring(errB))
	end

	-- NPC spots (NpcService builds the pets): on the lawn next to the walkways, facing them.
	L.NpcSpots = {}
	local step = L.PortalStep
	local npcPlan = {
		{ L.PortalAngles[1] + step * 0.5, 58 },
		{ L.PortalAngles[#L.PortalAngles] - step * 0.5, 58 },
		{ L.ShopAngle - 20, 42 },
		{ L.ShopAngle + 20, 42 },
		{ L.ShopAngle - 45, 50 },
		{ L.ShopAngle + 45, 50 },
	}
	for _, plan in ipairs(npcPlan) do
		local pos = plazaSpot(plan[1], plan[2], 5, L, false)
		if not pos then
			pos = plazaSpot(plan[1], plan[2] + 8, 5, L, true)
		end
		local look
		if math.abs(angleDiff(plan[1], L.ShopAngle) - 20) < 1 then
			-- beside the boardwalk: face across it
			local d = dirOf(L.ShopAngle)
			local toPath = Vector3.new(OX, TOP, OZ) + d * plan[2] - pos
			look = pos + Vector3.new(toPath.X, 0, toPath.Z)
		else
			look = Vector3.new(OX, TOP, OZ)
		end
		L.NpcSpots[#L.NpcSpots + 1] = flatLook(pos, look)
	end

	-- Trees on the south lawns.
	local trees = {
		{ L.ShopAngle - 45, 86, "Blossom" },
		{ L.ShopAngle + 45, 86, "Round" },
		{ L.ShopAngle - 79, 62, "Round" },
		{ L.ShopAngle + 79, 62, "Blossom" },
		{ L.ShopAngle - 31, 100, "Pine" },
		{ L.ShopAngle + 31, 100, "Pine" },
	}
	for i, t in ipairs(trees) do
		local pos = plazaSpot(t[1], t[2], 6, L)
		if pos then
			place(Props.Tree(t[3]), CFrame.new(pos) * CFrame.Angles(0, math.rad(i * 77), 0), f, t[3] .. "Tree")
		end
	end

	-- Lamps around the court (with light) and at every exit through the rim.
	local lampTpl = Props.Lamp()
	-- (the pair flanking the main path stays clear of the sight lines to the two notice boards)
	local courtLamps = {
		L.PortalAngles[1] + step * 0.5,
		L.MidAngle - 12.5,
		L.MidAngle + 12.5,
		L.PortalAngles[#L.PortalAngles] - step * 0.5,
		L.ShopAngle - 45,
		L.ShopAngle + 45,
	}
	local lampTops = {}
	for _, a in ipairs(courtLamps) do
		local pos = plazaSpot(a, G.CourtR + 5, 1.5, L)
		if pos then
			local lamp = place(lampTpl, CFrame.new(pos), f, "CourtLamp")
			local glass = lamp and lamp:FindFirstChild("LampGlass")
			if glass then
				pointLight(glass, C.Lamp, 0.9, 18)
			end
			lampTops[#lampTops + 1] = { Angle = a, Pos = pos + Vector3.new(0, 7.4, 0) }
		end
	end
	for _, a in ipairs(L.RimGaps) do
		local half = (angleDiff(a, L.ShopAngle) < 1) and G.BoardHalf or G.StubHalf
		local skip = angleIn(a, L.PromFrom, L.PromTo) -- banners mark the exits on the promenade side
		local side = dirOf(a + 90)
		local pos = polar(a, PLAZA_R - 6, TOP) + side * (half + 1.8)
		if not skip then
			place(lampTpl, CFrame.new(pos), f, "ExitLamp")
		end
		if angleDiff(a, L.ShopAngle) < 1 then
			local pos2 = polar(a, PLAZA_R - 6, TOP) - side * (half + 1.8)
			local lamp2 = place(lampTpl, CFrame.new(pos2), f, "ExitLamp")
			local glass = lamp2 and lamp2:FindFirstChild("LampGlass")
			if glass then
				pointLight(glass, C.Lamp, 0.8, 16)
			end
		end
	end

	-- Bunting between neighbouring court lamps (in the difficulty colours), open towards the shop.
	table.sort(lampTops, function(a, b)
		return (a.Angle % 360) < (b.Angle % 360)
	end)
	for i = 1, #lampTops do
		local a, b = lampTops[i], lampTops[i % #lampTops + 1]
		if a ~= b and angleDiff(a.Angle, b.Angle) <= 70 then
			bunting(f, a.Pos, b.Pos, diffColors, 1.2)
		end
	end

	-- Benches facing the court.
	local benchTpl = Props.Bench()
	local benches = {
		{ L.PortalAngles[1] + step * 0.5, 44 },
		{ L.PortalAngles[#L.PortalAngles] - step * 0.5, 44 },
	}
	for _, b in ipairs(benches) do
		local pos = plazaSpot(b[1], b[2], 3.5, L)
		if pos then
			place(benchTpl, faceCentre(pos), f, "Bench")
		end
	end

	-- Flower beds near the promenade, between the portal paths.
	for i = 1, #L.PortalAngles - 1 do
		local a = (L.PortalAngles[i] + L.PortalAngles[i + 1]) / 2
		local pos = plazaSpot(a, G.PromIn - 7, 4, L)
		if pos then
			place(Props.FlowerBed((i - 1) % #FLOWERS + 1), faceCentre(pos), f, "FlowerBed")
		end
	end

	-- Banners flank every spoke exit on the promenade side, in the colours of the neighbouring portals.
	for _, a in ipairs(L.SpokeAngles) do
		if angleIn(a, L.PromFrom, L.PromTo) then
			local left, right = nil, nil
			for i, pa in ipairs(L.PortalAngles) do
				if pa < a and (not left or pa > L.PortalAngles[left]) then
					left = i
				end
				if pa > a and (not right or pa < L.PortalAngles[right]) then
					right = i
				end
			end
			for _, s in ipairs({ -1, 1 }) do
				local idx = (s < 0) and (left or right) or (right or left)
				local color = diffColors[idx or 1] or C.Rose
				local pos = polar(a, G.PromOut + 3, TOP) + dirOf(a + 90) * (s * (G.StubHalf + 2.2))
				bannerPole(f, faceCentre(pos) * CFrame.Angles(0, (s < 0) and math.pi or 0, 0), color)
			end
		end
	end

	-- Fireflies and sparkle dust over the lawns.
	local flies = anchorPart(f, "Fireflies", Vector3.new(OX, TOP + 6, OZ), Vector3.new(PLAZA_R * 1.7, 10, PLAZA_R * 1.7))
	emitter(flies, {
		Color = ColorSequence.new(rgb(255, 236, 150), rgb(190, 240, 170)),
		Rate = 10,
		Lifetime = NumberRange.new(5, 8),
		Speed = NumberRange.new(0.3, 1),
		SpreadAngle = Vector2.new(180, 180),
		Size = popSize(0.45),
	})
end

local function buildPlaza(root, L)
	local f = newFolder(root, "Plaza")
	buildPlazaGround(f, L)
	local okBody, errBody = pcall(buildPlazaBody, f, L)
	if not okBody then
		warn("[LobbyBuilder] plaza cloud failed: " .. tostring(errBody))
	end
	local okDecor, errDecor = pcall(buildPlazaDecor, f, L)
	if not okDecor then
		warn("[LobbyBuilder] plaza decor failed: " .. tostring(errDecor))
	end
	return f
end

----------------------------------------------------------------------
-- Portal gates (Model Portal_<Id>)
----------------------------------------------------------------------

local MAX_STARS = 5
local gateBoxCache = nil

local function gatePalette(color)
	return {
		Stone = C.StoneLight,
		StoneDark = C.Stone,
		Frame = C.CloudLight,
		Puff = C.Cloud,
		Trim = color,
		Glow = { Color = color, Material = MAT.Neon },
		Swirl = { Color = color:Lerp(rgb(255, 255, 255), 0.35), Material = MAT.Neon, Transparency = 0.62 },
		Gem = { Color = C.Gold, Material = MAT.Neon },
	}
end

-- The gate is sculpted and merged once; every portal builds the same boxes with its own palette.
local function gateBoxes()
	if gateBoxCache then
		return gateBoxCache
	end
	local g = Voxel.NewGrid(24)
	VX.RoundRect(g, 0, 0, 22, 5, 1.5, 0, 0, "StoneDark")
	VX.RoundRect(g, 0, 0, 20, 4, 1.2, 1, 1, "Stone")
	for _, s in ipairs({ -1, 1 }) do
		VX.RoundRect(g, s * 9, 0, 3, 3.4, 0.8, 2, 10, "Stone")
		VX.RoundRect(g, s * 9, 0, 4, 4.2, 1, 11, 11, "Trim")
		VX.Fill(g, s * 9, s * 9, 12, 13, 0, 0, "Glow")
		VX.Fill(g, s * 9, s * 9, 3, 3, -2, -2, "Trim")
	end
	local ringRot = CFrame.Angles(math.pi / 2, 0, 0)
	Voxel.Shape(g, { Kind = "Torus", Center = { 0, 11, 0 }, Radius = 7.6, Thickness = 1.6, Rotation = ringRot, Key = "Frame" })
	Voxel.Shape(g, { Kind = "Torus", Center = { 0, 11, 0 }, Radius = 5.9, Thickness = 0.5, Rotation = ringRot, Key = "Glow" })
	Voxel.Shape(g, { Kind = "Ellipsoid", Center = { 0, 11, 0 }, Radius = { 5.3, 5.3, 0.2 }, Key = "Swirl", KeepExisting = true })
	-- the outer band of the frame takes the difficulty colour
	Voxel.Shape(g, {
		Kind = "Torus",
		Center = { 0, 11, 0 },
		Radius = 7.6,
		Thickness = 2.2,
		Rotation = ringRot,
		Op = "Paint",
		OnlyKeys = { Frame = true },
		Key = "Trim",
		Pattern = function(x, y, z)
			local dy = y - 11
			if math.sqrt(x * x + dy * dy) >= 8.6 then
				return "Trim"
			end
			return false
		end,
	})
	-- keystone with a gold gem facing the plaza
	VX.RoundRect(g, 0, 0, 4, 3, 0.8, 19, 20, "Trim")
	Voxel.Set(g, 0, 20, -2, "Gem")
	Voxel.Set(g, 0, 19, -2, "Gem")
	Voxel.Shade(g, { Skip = { Glow = true, Swirl = true, Gem = true }, Smooth = 1, Seed = 8 })
	-- LOD folds shade variants only (Keep: the coloured keys differ per portal)
	gateBoxCache = Voxel.Merge(g, {
		Palette = gatePalette(rgb(120, 180, 140)),
		MaxParts = 105,
		Keep = { "Stone", "StoneDark", "Frame", "Trim", "Glow", "Swirl", "Gem" },
	})
	return gateBoxCache
end

-- The portal's pixel tag (World text rule): name, stars + "0/4 players", a status pill. Returns the PortalInfo
-- GUI fields (Billboard + the four labels); PortalService rebuilds the same tag with the live party state.
local function portalTag(anchor, diff, stars, lift)
	local color = diff.Color or C.TextGold
	local gui = newTag(anchor, "PortalBillboard", 380, 150, lift, 120)
	local plate = tagPlate(gui, color:Lerp(C.Text, 0.15), 200, nil, 3)
	local title = tagText(plate, "TitleLabel", diff.DisplayName or diff.Id, "Title", 32, color:Lerp(C.Text, 0.6), 1)
	local row = plainFrame(plate, "InfoRow", { AutomaticSize = Enum.AutomaticSize.XY, LayoutOrder = 2 })
	listLayout(row, Enum.FillDirection.Horizontal, 12)
	local starLabel = tagText(row, "StarLabel", "", "Heading", 21, C.TextGold, 1)
	starLabel.RichText = true
	starLabel.Text = starRow(stars, MAX_STARS)
	local countLabel = tagText(row, "CountLabel", "0/" .. tostring(Config.Match.MaxPlayers) .. " players", "Heading", 21, C.Text, 2)
	local _, statusLabel = tagPill(plate, "StatusPill", "Step in to play", "Display", 24, color:Lerp(C.Navy, 0.25), 3)
	statusLabel.Name = "StatusLabel"
	return {
		Billboard = gui,
		TitleLabel = title,
		CountLabel = countLabel,
		StatusLabel = statusLabel,
		StarLabel = starLabel,
	}
end

local function buildPortal(parent, diff, angleDeg)
	local model = newModel(parent, "Portal_" .. diff.Id)
	local outward = dirOf(angleDeg)
	local color = diff.Color
	local padGround = polar(angleDeg, PORTAL_R, TOP)
	local padCF = flatLook(padGround, padGround - outward) -- local -Z = towards the plaza centre

	-- Ready pad: a tiled 14 x 14 voxel plate, 0.3 above the promenade.
	local pg = Voxel.NewGrid(14)
	for i = -7, 6 do
		for k = -7, 6 do
			local ring = math.min(i + 7, 6 - i, k + 7, 6 - k)
			local di = math.abs(i + 0.5) + math.abs(k + 0.5)
			local key = "Stone"
			if ring == 0 then
				key = "Trim"
			elseif ring == 1 then
				key = "StoneLight"
			elseif di <= 2.5 then
				key = "Glow"
			end
			Voxel.Set(pg, i, 0, k, key)
		end
	end
	local pad = VX.Build(pg, {
		V = 1,
		Name = "Pad",
		CF = padCF * CFrame.new(0.5, 0.3 - 0.5, 0.5),
		Collide = true,
		Parent = model,
		Pal = {
			Stone = C.Stone,
			StoneLight = C.StoneLight,
			Trim = color,
			TrimSoft = color:Lerp(C.StoneLight, 0.55),
			Glow = { Color = color, Material = MAT.Neon },
		},
	})
	if pad and pad.PrimaryPart then
		model.PrimaryPart = pad.PrimaryPart
	end

	-- Invisible detection zone: 14 x 6 x 14, floor flush with the pad surface.
	local zonePos = padGround + Vector3.new(0, 0.3 + 3, 0)
	local zone = box(model, "Zone_" .. diff.Id, flatLook(zonePos, zonePos - outward), Vector3.new(14, 6, 14), color, {
		Transparency = 1,
		Shadow = false,
	})
	zone:SetAttribute("PortalId", diff.Id)

	-- Lanterns on the two front corners of the pad.
	for _, sx in ipairs({ -1, 1 }) do
		local base = padCF * CFrame.new(sx * 7.9, 0, -7.9)
		box(model, "LanternPost", base * CFrame.new(0, 1.6, 0), Vector3.new(0.7, 3.2, 0.7), C.Iron, { Collide = true })
		box(model, "LanternCap", base * CFrame.new(0, 3.35, 0), Vector3.new(1.1, 0.3, 1.1), C.Iron)
		box(model, "LanternGlow", base * CFrame.new(0, 3.95, 0), Vector3.new(0.9, 0.9, 0.9), color, { Material = MAT.Neon })
	end

	-- Gate behind the pad (sculpted voxels in the difficulty colour).
	local gateBase = padGround + outward * 9.5
	local gateCF = flatLook(gateBase, gateBase - outward)
	local gate = Instance.new("Model")
	gate.Name = "Gate"
	Voxel.BuildBoxes(gateBoxes(), {
		VoxelSize = 1,
		Palette = gatePalette(color),
		CFrame = gateCF * CFrame.new(0, 0.5, 0),
		Model = gate,
		CanCollide = true,
		CanQuery = true,
	})
	for _, d in ipairs(gate:GetChildren()) do
		if d:IsA("BasePart") and (d.Name == "Swirl" or d.Name == "Puff" or d.Name == "Gem") then
			d.CanCollide = false
			d.CanQuery = false
		end
	end
	gate.Parent = model

	-- Swirl light + sparkles drifting out towards the pad.
	local core = box(model, "SwirlCore", gateCF * CFrame.new(0, 11.5, 0), Vector3.new(9, 9, 0.4), color, { Transparency = 1, Shadow = false })
	pointLight(core, color, 1.3, 28)
	emitter(core, {
		Color = ColorSequence.new(color:Lerp(rgb(255, 255, 255), 0.5), color),
		Rate = 12,
		Lifetime = NumberRange.new(1.4, 2.2),
		Speed = NumberRange.new(1.5, 3.5),
		EmissionDirection = Enum.NormalId.Front,
		SpreadAngle = Vector2.new(30, 30),
		Size = popSize(0.9),
	})

	-- Star gems above the keystone: lit gold for the difficulty, dim stone up to five.
	local stars = clamp(diff.Stars or 1, 0, MAX_STARS)
	for s = 1, MAX_STARS do
		local gx = ((MAX_STARS + 1) / 2 - s) * 2.6 -- gate +X is the viewer's left: lit stars first
		local lit = s <= stars
		box(model, lit and "StarGem" or "StarGemOff", gateCF * CFrame.new(gx, 23.6, 0) * CFrame.Angles(0, 0, math.rad(45)), Vector3.new(1.5, 1.5, 0.8), lit and C.Gold or C.StarOff, {
			Material = lit and MAT.Neon or MAT.SmoothPlastic,
			Shadow = false,
		})
	end

	-- Billboard: a pixel tag above the star gems (PortalService rebuilds it with the live party state).
	local cardH = 15
	local anchor = anchorPart(model, "BillboardAnchor", gateBase + Vector3.new(0, 25.2 + cardH / 2, 0))
	local tag = portalTag(anchor, diff, stars, 1.2 - cardH / 2) -- bottom edge 26.4 studs up, just over the gems
	tag.Id = diff.Id
	tag.Zone = zone
	tag.Center = zone.Position
	tag.Model = model
	return tag
end

-- Bare-minimum portal used only if the full builder throws: the gameplay contract (zone + labels) must
-- survive even when the scenery does not.
local function fallbackPortal(parent, diff, angleDeg)
	local old = parent:FindFirstChild("Portal_" .. diff.Id)
	if old then
		old:Destroy()
	end
	local model = newModel(parent, "Portal_" .. diff.Id)
	local ground = polar(angleDeg, PORTAL_R, TOP)
	local zone = box(model, "Zone_" .. diff.Id, CFrame.new(ground + Vector3.new(0, 3.3, 0)), Vector3.new(14, 6, 14), diff.Color, { Transparency = 1, Shadow = false })
	zone:SetAttribute("PortalId", diff.Id)
	local pad = box(model, "PadPlate", CFrame.new(ground + Vector3.new(0, 0, 0)), Vector3.new(14, 0.6, 14), C.Stone, { Collide = true })
	box(model, "PadGlow", CFrame.new(ground + Vector3.new(0, 0.35, 0)), Vector3.new(4, 0.1, 4), diff.Color, { Material = MAT.Neon })
	model.PrimaryPart = pad
	local anchor = anchorPart(model, "BillboardAnchor", ground + Vector3.new(0, 14, 0))
	local tag = portalTag(anchor, diff, clamp(diff.Stars or 1, 0, MAX_STARS), 0)
	tag.Id = diff.Id
	tag.Zone = zone
	tag.Center = zone.Position
	tag.Model = model
	return tag
end

----------------------------------------------------------------------
-- Shop island: four gacha-style roulette machines, the item stall, a rarity board, a token statue
----------------------------------------------------------------------

-- Size (studs) of the name + price card floating above every roulette machine.
local MACHINE_CARD_W = 14
local MACHINE_CARD_H = 7.6
local machineBoxCache = nil

-- Pixel tag of a roulette machine: the name in the roulette colour + a gold price. The machines stand ~15 studs
-- apart, so the tags hide beyond 60 studs (constant-size tags of neighbours would overlap on screen from afar).
local function machineTag(anchor, roulette, lift)
	local color = roulette.Color or C.Rose
	local gui = newTag(anchor, "PriceBillboard", 320, 110, lift, 60)
	local plate = tagPlate(gui, color, 160)
	tagText(plate, "NameLabel", roulette.DisplayName or roulette.Id, "Title", 26, color:Lerp(C.Text, 0.55), 1)
	tagText(plate, "PriceLabel", priceText(roulette.Price or 0), "Display", 24, C.TextGold, 2)
	return gui
end

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

local function machinePalette(roulette)
	local color = roulette.Color or C.Rose
	local pal = {
		Base = C.Iron,
		Body = color,
		Trim = C.Gold,
		Seg1 = color:Lerp(rgb(255, 255, 255), 0.45),
		Seg2 = C.Cream,
		Rim = C.GoldDark,
		Hub = C.Gold,
		Dark = rgb(42, 46, 70),
		Glass = { Color = rgb(214, 236, 255), Material = MAT.Glass, Transparency = 0.55 },
		Bulb = { Color = C.Lamp, Material = MAT.Neon },
		Knob = rgb(236, 88, 100),
		Iron = C.IronLight,
	}
	local rarities = oddsRarities(roulette)
	for i = 1, 4 do
		local r = rarities[(i - 1) % math.max(1, #rarities) + 1]
		pal["Egg" .. i] = (r and r.Color) or color
	end
	return pal
end

-- The machine is sculpted and merged once; each roulette builds it with its own colours. Front = -Z.
-- Two resolutions: the cabinet, wheel and lever in fine half-stud voxels, the glass dome in 1-stud voxels
-- (translucent voxels cannot hide behind each other, so a coarse dome keeps the part count sane).
local function machineBoxes()
	if machineBoxCache then
		return machineBoxCache
	end
	local g = Voxel.NewGrid(28)
	VX.RoundRect(g, 0, 0, 18, 14, 3, 0, 1, "Base")
	VX.RoundRect(g, 0, 0, 15, 11, 2, 2, 2, "Trim")
	VX.RoundRect(g, 0, 0, 14, 10, 2, 3, 10, "Body")
	VX.RoundRect(g, 0, 0, 15, 11, 2, 11, 11, "Trim")
	VX.RoundRect(g, 0, 0, 8, 8, 2, 12, 13, "Trim")
	-- the prize wheel on the front: eight coloured segments, a gold rim and hub, a red pointer on top
	local wy = 7
	for x = -4, 4 do
		for y = 3, 11 do
			local dy = y - wy
			local d = math.sqrt(x * x + dy * dy)
			if d <= 3.7 then
				local key
				if d <= 1.0 then
					key = "Hub"
				elseif d >= 2.9 then
					key = "Rim"
				else
					local seg = math.floor((atan2(dy, x) + math.pi) / (math.pi / 4))
					key = (seg % 2 == 0) and "Seg1" or "Seg2"
				end
				Voxel.Set(g, x, y, -6, key)
			end
		end
	end
	Voxel.Set(g, 0, 11, -6, "Knob")
	Voxel.Set(g, 0, 11, -7, "Knob")
	-- prize chute + gold tray, marquee bulbs on the top band
	VX.Fill(g, -2, 2, 3, 3, -6, -6, "Dark")
	VX.Fill(g, -2, 2, 2, 2, -7, -6, "Trim")
	for _, x in ipairs({ -6, -3, 3, 6 }) do
		Voxel.Set(g, x, 11, -6, "Bulb")
	end
	-- lever on the right side
	Voxel.Shape(g, { Kind = "Capsule", A = { 7.4, 6, 0 }, B = { 9, 12, 0 }, Radius = 0.6, Key = "Iron" })
	Voxel.Shape(g, { Kind = "Ellipsoid", Center = { 9, 13.2, 0 }, Radius = 1.3, Key = "Knob" })
	Voxel.Shade(g, {
		Skip = { Bulb = true, Seg1 = true, Seg2 = true, Hub = true, Rim = true, Dark = true, Knob = true },
		Smooth = 1,
		Seed = 12,
	})

	-- the glass dome full of pet eggs (1-stud voxels), sitting on the neck
	local d = Voxel.NewGrid(8)
	Voxel.Shape(d, { Kind = "Ellipsoid", Center = { 0, 9.4, 0 }, Radius = { 3.1, 2.9, 3.1 }, Key = "Glass" })
	local eggs = { { -1.2, 8.1, -0.9 }, { 1.2, 8.2, 0.7 }, { 0.2, 9.8, -1.3 }, { -0.9, 10, 1.1 }, { 1.4, 9.9, -0.2 }, { -0.1, 8.4, 1.6 } }
	for i, e in ipairs(eggs) do
		Voxel.Shape(d, { Kind = "Ellipsoid", Center = e, Radius = { 0.75, 0.95, 0.75 }, Key = "Egg" .. ((i - 1) % 4 + 1), Bias = 0.15 })
	end
	VX.RoundRect(d, 0, 0, 3, 3, 0.8, 12, 12, "Trim")
	Voxel.Set(d, 0, 13, 0, "Bulb")
	local pal = machinePalette(Config.Roulettes[1] or { Color = C.Rose })
	-- LOD only folds shade variants (the coloured keys differ per roulette, so they are kept as they are)
	local keep = { "Body", "Trim", "Seg1", "Seg2", "Rim", "Hub", "Glass", "Egg1", "Egg2", "Egg3", "Egg4", "Bulb", "Knob", "Base", "Iron", "Dark" }
	machineBoxCache = {
		Fine = Voxel.Merge(g, { Palette = pal, MaxParts = 70, Keep = keep }),
		Dome = Voxel.Merge(d, { Palette = pal, Keep = keep }),
	}
	return machineBoxCache
end

-- A gacha roulette machine (Model Roulette_<Id>). `cf` sits on the ground; LookVector = towards the customer.
local function buildMachine(parent, cf, roulette)
	local model = newModel(parent, "Roulette_" .. roulette.Id)
	local body = Instance.new("Model")
	body.Name = "Machine"
	-- the sculpt's front (-Z) faces along cf.LookVector (the customer)
	local boxes = machineBoxes()
	local pal = machinePalette(roulette)
	Voxel.BuildBoxes(boxes.Fine, { VoxelSize = 0.5, Palette = pal, CFrame = cf * CFrame.new(0, 0.25, 0), Model = body, CanCollide = true, CanQuery = true })
	Voxel.BuildBoxes(boxes.Dome, { VoxelSize = 1, Palette = pal, CFrame = cf * CFrame.new(0, 0.5, 0), Model = body, CanCollide = true, CanQuery = true })
	body.Parent = model
	local cabinet = nil
	for _, d in ipairs(body:GetChildren()) do
		if d:IsA("BasePart") and d.Name == "Body" and (not cabinet or d.Size.Magnitude > cabinet.Size.Magnitude) then
			cabinet = d
		end
	end
	local glow = anchorPart(model, "DomeGlow", (cf * CFrame.new(0, 9.5, 0)).Position)
	pointLight(glow, roulette.Color or C.Lamp, 0.9, 18)
	emitter(glow, {
		Color = ColorSequence.new((roulette.Color or C.Rose):Lerp(rgb(255, 255, 255), 0.4), C.TextGold),
		Rate = 3,
		Lifetime = NumberRange.new(1.5, 2.5),
		Speed = NumberRange.new(1, 2.5),
		SpreadAngle = Vector2.new(180, 180),
		Size = popSize(0.5),
	})

	-- Name + price tag standing on the dome.
	local anchor = anchorPart(model, "PriceAnchor", (cf * CFrame.new(0, 14.2 + MACHINE_CARD_H * 0.5, 0)).Position)
	machineTag(anchor, roulette, 0.5 - MACHINE_CARD_H * 0.5)

	-- Invisible spot in front where PetService hangs the ProximityPrompt.
	local prompt = box(model, "PromptPart", cf * CFrame.new(0, 2, -5.4), Vector3.new(5, 4, 3), roulette.Color or C.Rose, { Transparency = 1, Shadow = false })
	prompt.CanQuery = false
	model.PrimaryPart = cabinet or prompt
	return {
		Id = roulette.Id,
		PromptPart = prompt,
		Center = (cf * CFrame.new(0, 3.5, 0)).Position,
		Model = model,
	}
end

local function fallbackMachine(parent, cf, roulette)
	local old = parent:FindFirstChild("Roulette_" .. roulette.Id)
	if old then
		old:Destroy()
	end
	local model = newModel(parent, "Roulette_" .. roulette.Id)
	local cabinet = box(model, "Cabinet", cf * CFrame.new(0, 3, 0), Vector3.new(7, 6, 5), roulette.Color or C.Rose, { Collide = true })
	local anchor = anchorPart(model, "PriceAnchor", (cf * CFrame.new(0, 10, 0)).Position)
	machineTag(anchor, roulette, -2.5)
	local prompt = box(model, "PromptPart", cf * CFrame.new(0, 2, -5), Vector3.new(5, 4, 3), C.Cloud, { Transparency = 1, Shadow = false })
	model.PrimaryPart = cabinet
	return { Id = roulette.Id, PromptPart = prompt, Center = cabinet.Position, Model = model }
end

-- Striped market stall with goods on the shelf (Model ItemShop). Front (-Z of the sculpt) faces the customer.
local function buildItemStall(parent, cf)
	local model = newModel(parent, "ItemShop")
	local g = Voxel.NewGrid(14)
	VX.RoundRect(g, 0, 0, 10, 3, 0.6, 0, 2, "Wood")
	VX.RoundRect(g, 0, 0, 11, 4, 0.8, 3, 3, "Top")
	for x = -4, 4 do
		for y = 0, 2 do
			Voxel.Set(g, x, y, -2, (math.floor((x + 4) / 1) % 2 == 0) and "Rose" or "Cream")
		end
	end
	VX.Fill(g, -5, 5, 0, 8, 3, 3, "WoodDark")
	VX.Fill(g, -4, 4, 5, 5, 2, 2, "Wood")
	for _, sx in ipairs({ -6, 6 }) do
		VX.Fill(g, sx, sx, 0, 8, -3, -3, "Post")
		VX.Fill(g, sx, sx, 0, 10, 3, 3, "Post")
	end
	-- striped awning in three steps, sloping down to the front, with a scalloped fringe
	for x = -7, 7 do
		local stripe = (math.floor((x + 7) / 2) % 2 == 0) and "Rose" or "Cream"
		for z = -4, 4 do
			local y = 9 + math.floor((z + 4) / 3)
			Voxel.Set(g, x, y, z, stripe)
		end
		if x % 2 == 0 then
			Voxel.Set(g, x, 8, -4, stripe)
		end
	end
	-- goods: heal cloud, shield bubble, phoenix feather on the shelf; coins on the counter
	Voxel.Shape(g, { Kind = "Ellipsoid", Center = { -3, 6.5, 2 }, Radius = { 1.3, 0.8, 0.6 }, Key = "Heal" })
	Voxel.Shape(g, { Kind = "Ellipsoid", Center = { 0, 6.7, 2 }, Radius = { 0.9, 0.9, 0.6 }, Key = "Shield" })
	Voxel.Shape(g, { Kind = "Curve", Points = { { 2.6, 6, 2 }, { 3.2, 7, 2 }, { 3.5, 8.1, 2 } }, Radius = 0.45, RadiusB = 0.2, Key = "Feather" })
	Voxel.Set(g, 3, 8, 2, "Gold")
	Voxel.Set(g, 2, 4, 0, "Gold")
	Voxel.Set(g, 3, 4, -1, "Gold")
	Voxel.Set(g, -3, 4, 0, "Heal")
	Voxel.Shade(g, { Skip = { Shield = true, Rose = true, Cream = true }, Smooth = 1, Seed = 13 })
	VX.Build(g, {
		V = 1,
		Name = "Stall",
		CF = cf * CFrame.new(0, 0.5, 0),
		Collide = true,
		Parent = model,
		Pal = {
			Wood = C.Plank,
			WoodDark = C.PlankDark,
			Post = C.PlankDark,
			Top = C.Cream,
			Rose = C.Rose,
			Cream = C.Cream,
			Heal = rgb(124, 214, 150),
			Shield = { Color = rgb(120, 184, 250), Material = MAT.Glass, Transparency = 0.35 },
			Feather = rgb(244, 136, 70),
			Gold = C.Gold,
		},
		MaxParts = 80,
	})
	local lamp = anchorPart(model, "StallLight", (cf * CFrame.new(0, 7.5, 0)).Position)
	pointLight(lamp, C.Lamp, 0.8, 16)

	-- name tag standing on the awning (bottom edge 13.3 studs up)
	local anchor = anchorPart(model, "SignAnchor", (cf * CFrame.new(0, 15.5, 0)).Position)
	local bb = newTag(anchor, "ItemShopBillboard", 320, 110, -2.2, 80)
	local plate = tagPlate(bb, C.Rose, 160)
	tagText(plate, "NameLabel", "Item Shop", "Title", TAG_NAME, C.Text, 1)
	tagText(plate, "SubLabel", "Heal " .. GLYPH.Bullet .. " Shield " .. GLYPH.Bullet .. " Revive", "Body", TAG_INFO, C.TextGold, 2, 2)

	local prompt = box(model, "PromptPart", cf * CFrame.new(0, 2, -4.6), Vector3.new(5, 4, 3), C.Cloud, { Transparency = 1, Shadow = false })
	local counter = model:FindFirstChild("Stall")
	model.PrimaryPart = (counter and counter.PrimaryPart) or prompt
	return { PromptPart = prompt, Center = (cf * CFrame.new(0, 1.7, 0)).Position, Model = model }
end

local function fallbackItemStall(parent, cf)
	local old = parent:FindFirstChild("ItemShop")
	if old then
		old:Destroy()
	end
	local model = newModel(parent, "ItemShop")
	local counter = box(model, "Counter", cf * CFrame.new(0, 1.7, 0), Vector3.new(9, 3.4, 3.2), C.Plank, { Collide = true })
	local prompt = box(model, "PromptPart", cf * CFrame.new(0, 2, -4.6), Vector3.new(5, 4, 3), C.Cloud, { Transparency = 1, Shadow = false })
	model.PrimaryPart = counter
	return { PromptPart = prompt, Center = counter.Position, Model = model }
end

-- Board that explains the roulettes: price, and which rarities each one can give.
local function buildRarityBoard(parent, cf)
	-- 700 x 450 px canvas (14 x 9 studs): a 1-stud header, then one row per roulette: the name and the price
	-- (0.6 stud) over rarity pills that spell out what it can pay (0.6 stud)
	local face = noticeBoard(parent, cf, 14, 9, "RarityBoard")
	local gui = surfaceGui(face, Enum.NormalId.Front)
	local panel = signPanel(gui)
	local H = 450
	signText(panel, "WINGED PETS", "Title", 50, C.Gold, "Header", 0.04, 6 / H, 0.92, 54 / H)
	signText(panel, "Pricier roulette = rarer pets", "Body", SIGN_INFO, C.Text, "Sub", 0.04, 60 / H, 0.92, 34 / H)
	for i, roulette in ipairs(Config.Roulettes) do
		local top = 102 + (i - 1) * 84
		local y = top / H
		local color = roulette.Color or C.Rose
		signText(panel, roulette.DisplayName or roulette.Id, "Heading", SIGN_INFO, color:Lerp(C.Text, 0.35), "Name" .. i, 0.04, y, 0.6, 36 / H, Enum.TextXAlignment.Left)
		signText(panel, priceText(roulette.Price or 0), "Body", SIGN_INFO, C.TextGold, "Price" .. i, 0.6, y, 0.36, 36 / H, Enum.TextXAlignment.Right)
		local pills = plainFrame(panel, "Rarities" .. i, {
			Position = UDim2.new(0.04, 0, (top + 38) / H, 0),
			Size = UDim2.new(0.92, 0, 36 / H, 0),
		})
		local layout = listLayout(pills, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left)
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		for k, rarity in ipairs(oddsRarities(roulette)) do
			local pill = tagPill(pills, "Rarity_" .. rarity.Id, rarity.Id, "Body", SIGN_INFO, rarity.Color:Lerp(C.Navy, 0.18), k)
			local pad = pill:FindFirstChildOfClass("UIPadding")
			if pad then -- a slim pill: the row keeps a clear gap to the next roulette
				pad.PaddingTop = UDim.new(0, 0)
				pad.PaddingBottom = UDim.new(0, 0)
			end
			pill.Size = UDim2.fromOffset(0, 34)
		end
	end
	gui.Parent = face
end

-- A big decorative voxel coin with a cloud emblem on a pedestal (NOT a collectible token).
local function buildTokenStatue(parent, ground)
	local m = newModel(parent, "TokenStatue")
	local g = Voxel.NewGrid(12)
	VX.RoundRect(g, 0, 0, 6, 6, 1.2, 0, 1, "StoneLight")
	VX.RoundRect(g, 0, 0, 4.4, 4.4, 1, 2, 2, "Stone")
	for x = -4, 4 do
		for y = -4, 4 do
			local d = math.sqrt(x * x + y * y)
			if d <= 4.3 then
				local key = (d >= 3.4) and "GoldDark" or "Gold"
				Voxel.Set(g, x, 7 + y, 0, key)
			end
		end
	end
	-- the cloud emblem in relief on both faces
	local emblem = {}
	for _, row in ipairs({ { 2, -1, 0 }, { 1, -2, 2 }, { 0, -3, 3 }, { -1, -2, 2 } }) do
		for x = row[2], row[3] do
			emblem[#emblem + 1] = { x, row[1] }
		end
	end
	for _, e in ipairs(emblem) do
		Voxel.Set(g, e[1], 7 + e[2], -1, "GoldGlow")
		Voxel.Set(g, e[1], 7 + e[2], 1, "GoldGlow")
	end
	VX.Fill(g, -1, 1, 3, 3, 0, 0, "GoldDark")
	Voxel.Shade(g, { Only = { StoneLight = true, Stone = true }, Smooth = 1 })
	VX.Build(g, { V = 1, Name = "Coin", CF = flatLook(ground, Vector3.new(OX, ground.Y, OZ)) * CFrame.new(0, 0.5, 0), Collide = true, Parent = m })
	local sparkle = anchorPart(m, "CoinSparkle", ground + Vector3.new(0, 7, 0), Vector3.new(6, 6, 2))
	emitter(sparkle, { Rate = 5, Lifetime = NumberRange.new(1.2, 2), Speed = NumberRange.new(0.5, 1.5), SpreadAngle = Vector2.new(180, 180), Size = popSize(0.6) })
	return m
end

local function buildShop(root, L)
	local f = newFolder(root, "Shop")
	local S = L.ShopCenter
	local R = L.ShopR
	local shopCF = flatLook(S, Vector3.new(OX, TOP, OZ)) -- local -Z = towards the plaza (the entrance)
	local function at(x, z)
		return (shopCF * CFrame.new(x, 0, z)).Position
	end
	local function local2(wx, wz)
		local p = shopCF:PointToObjectSpace(Vector3.new(S.X + wx, TOP, S.Z + wz))
		return p.X, p.Z
	end
	local rng = Util.NewRng(SEED + 4)

	-- Ground layers (2-stud cells): lawn, patches + flowers, borders, the stone court + entrance path, inlays.
	local cell = 2
	local n = math.ceil(R / cell)
	local grids = { Voxel.NewGrid(1), Voxel.NewGrid(1), Voxel.NewGrid(1), Voxel.NewGrid(1), Voxel.NewGrid(1) }
	for i = -n, n do
		for k = -n, n do
			local wx, wz = i * cell, k * cell
			local r = math.sqrt(wx * wx + wz * wz)
			if r <= R - 0.5 then
				local x, z = local2(wx, wz)
				Voxel.Set(grids[1], i, 0, k, "Grass")
				local nz = vnoise(wx + 50, wz + 50, 22, 31)
				if nz < 0.26 then
					Voxel.Set(grids[2], i, 0, k, "GrassDark")
				elseif nz > 0.76 then
					Voxel.Set(grids[2], i, 0, k, "GrassLight")
				end
				local court = r <= 21
				local path = z < 0 and math.abs(x) <= 7
				if court or path then
					Voxel.Set(grids[3], i, 0, k, "StoneEdge")
				end
				if r <= 19 or (z < 0 and math.abs(x) <= 5) then
					Voxel.Set(grids[4], i, 0, k, "Stone")
				elseif not court and not path and r > R - 7 and hash3(i, 3, k, 8) < 0.07 then
					Voxel.Set(grids[2], i, 0, k, "Flower" .. (math.floor(hash3(i, 4, k, 2) * #FLOWERS) + 1))
				end
				if r <= 19 then
					if r >= 12 and r <= 13.5 then
						Voxel.Set(grids[5], i, 0, k, "StoneLight")
					elseif r >= 4.5 and r <= 6.5 then
						Voxel.Set(grids[5], i, 0, k, "GoldDark")
					end
				end
			end
		end
	end
	local tops = { -0.4, -0.3, -0.1, 0, 0.1 }
	for li = 1, 5 do
		VX.Build(grids[li], { V = cell, Name = "Ground" .. li, CF = CFrame.new(S.X, TOP + tops[li] - cell / 2, S.Z), Collide = true, Shadow = false, Parent = f })
	end

	-- The shop's cloud body + the stone neck to the plaza.
	local okBody, errBody = pcall(function()
		local rim = {}
		for i = 1, 9 do
			local a = (i - 1) / 9 * 360 + rng:Float(-5, 5)
			local wx, wz = math.cos(math.rad(a)) * (R + 1.5), math.sin(math.rad(a)) * (R + 1.5)
			local _, lz = local2(wx, wz)
			if lz > -R * 0.55 then
				local s = rng:Float(8, 10)
				rim[#rim + 1] = { wx, rng:Float(-1, 1), wz, s, s * 0.6, s }
			end
		end
		local puffs = {}
		for i = 1, 6 do
			local a = (i - 1) / 6 * math.pi * 2 + rng:Float(-0.3, 0.3)
			local s = rng:Float(7, 11)
			puffs[#puffs + 1] = { math.cos(a) * (R - 6), -7, math.sin(a) * (R - 6), s, s * 0.7, s }
		end
		VX.CloudModel({
			V = 3,
			Tiers = { { R = R + 3, H = 1 }, { R = R - 3, H = 2 }, { R = R - 11, H = 2 }, { R = R - 19, H = 2 } },
			Puffs = puffs,
			Rim = rim,
			Carve = function(x, y, z)
				return y > 0 and (x * x + z * z) < (R - 4) * (R - 4)
			end,
			Seed = 5,
			MaxParts = 84,
		}, CFrame.new(S.X, TOP - 1.2, S.Z), f, "ShopCloud", true)
	end)
	if not okBody then
		warn("[LobbyBuilder] shop cloud failed: " .. tostring(errBody))
	end
	local neckA = polar(L.ShopAngle, PLAZA_R - 4, TOP)
	local neckB = polar(L.ShopAngle, L.ShopDist - R + 5, TOP)
	local neckMid = (neckA + neckB) * 0.5
	box(f, "ShopNeck", flatLook(neckMid, neckB) * CFrame.new(0, -0.2 - 0.6, 0), Vector3.new(G.BoardHalf * 2, 1.2, (neckB - neckA).Magnitude), C.Stone, { Collide = true })
	place(Props.Puff("S"), CFrame.new(neckMid - Vector3.new(0, 1.4, 0)), f, "NeckPuff")

	-- Roulette machines on an arc across the back, cheapest on the left as the customer walks in.
	local roulettes = {}
	local count = #Config.Roulettes
	local arcR = 19
	local stepDeg = math.deg(2 * math.asin(math.min(1, (MACHINE_CARD_W + 1) / (2 * arcR))))
	if count > 1 then
		stepDeg = math.min(stepDeg, 150 / (count - 1))
	end
	for i, roulette in ipairs(Config.Roulettes) do
		local phi = math.rad((i - (count + 1) / 2) * stepDeg)
		local pos = at(-math.sin(phi) * arcR, math.cos(phi) * arcR)
		local cf = flatLook(pos, S)
		local ok, result = pcall(buildMachine, f, cf, roulette)
		if not ok then
			warn("[LobbyBuilder] roulette machine " .. tostring(roulette.Id) .. " failed: " .. tostring(result))
			result = fallbackMachine(f, cf, roulette)
		end
		roulettes[roulette.Id] = result
	end

	-- Item stall (left of the entrance) and rarity board (right), both facing the centre.
	local stallPos = at(-21, -8)
	local stallCF = flatLook(stallPos, S)
	local okStall, stall = pcall(buildItemStall, f, stallCF)
	if not okStall then
		warn("[LobbyBuilder] item stall failed: " .. tostring(stall))
		stall = fallbackItemStall(f, stallCF)
	end
	local okBoard, errBoard = pcall(buildRarityBoard, f, flatLook(at(21, -8), S))
	if not okBoard then
		warn("[LobbyBuilder] rarity board failed: " .. tostring(errBoard))
	end

	-- Decor: token statue, entrance arch with the shop sign, lamps, bunting, flower beds, fireflies.
	local okDecor, errDecor = pcall(function()
		buildTokenStatue(f, S)
		local archCF = shopCF * CFrame.new(0, 0, -(R - 5)) * CFrame.Angles(0, math.pi, 0)
		local arch = newModel(f, "ShopArch")
		for _, s in ipairs({ -1, 1 }) do
			box(arch, "Pillar", archCF * CFrame.new(s * 7.6, 0.6, 0), Vector3.new(2.6, 1.2, 2.6), C.StoneDark, { Collide = true })
			box(arch, "Pillar", archCF * CFrame.new(s * 7.6, 5.6, 0), Vector3.new(1.8, 8.8, 1.8), C.StoneLight, { Collide = true })
			box(arch, "PillarCap", archCF * CFrame.new(s * 7.6, 10.3, 0), Vector3.new(2.6, 0.8, 2.6), C.Rose)
			box(arch, "PillarLamp", archCF * CFrame.new(s * 7.6, 11.2, 0), Vector3.new(1, 1, 1), C.Lamp, { Material = MAT.Neon })
		end
		box(arch, "Beam", archCF * CFrame.new(0, 10.3, 0), Vector3.new(13, 0.8, 1.2), C.PlankDark)
		local sign = box(arch, "ShopSign", archCF * CFrame.new(0, 12.6, 0), Vector3.new(12.4, 3.6, 0.8), C.Navy, { Shadow = true })
		box(arch, "SignRoof", archCF * CFrame.new(0, 14.7, 0), Vector3.new(14, 0.6, 1.8), C.Rose)
		-- 620 x 180 px canvas: the name 1.6 studs tall, the caption 0.68 stud
		for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
			local gui = surfaceGui(sign, face)
			local panel = signPanel(gui, C.TextGold)
			signText(panel, "CLOUD SHOP", "Title", 80, C.Gold, "Name", 0.03, 0.05, 0.94, 0.56)
			signText(panel, "pets & items", "Body", 34, C.Text, "Sub", 0.04, 0.62, 0.92, 0.3)
			gui.Parent = sign
		end
		local lampTpl = Props.Lamp()
		local lampTops = {}
		for i, p in ipairs({ { -9, -13 }, { 9, -13 }, { -25, 6 }, { 25, 6 } }) do
			local lamp = place(lampTpl, CFrame.new(at(p[1], p[2])), f, "ShopLamp")
			local glass = lamp and lamp:FindFirstChild("LampGlass")
			if glass and i <= 2 then
				pointLight(glass, C.Lamp, 0.8, 16)
			end
			lampTops[i] = at(p[1], p[2]) + Vector3.new(0, 7.4, 0)
		end
		bunting(f, lampTops[1], lampTops[2], { C.Rose, C.Cream, C.Gold, rgb(120, 190, 235) }, 1.2)
		place(Props.FlowerBed(2), flatLook(at(-10, -21), S) * CFrame.Angles(0, math.rad(90), 0), f, "FlowerBed")
		place(Props.FlowerBed(4), flatLook(at(10, -21), S) * CFrame.Angles(0, math.rad(90), 0), f, "FlowerBed")
		local flies = anchorPart(f, "Fireflies", S + Vector3.new(0, 5, 0), Vector3.new(R * 1.5, 8, R * 1.5))
		emitter(flies, {
			Color = ColorSequence.new(rgb(255, 236, 150), rgb(190, 240, 170)),
			Rate = 5,
			Lifetime = NumberRange.new(5, 8),
			Speed = NumberRange.new(0.3, 1),
			SpreadAngle = Vector2.new(180, 180),
			Size = popSize(0.45),
		})
	end)
	if not okDecor then
		warn("[LobbyBuilder] shop decor failed: " .. tostring(errDecor))
	end
	return { Roulettes = roulettes, ItemShop = stall }
end

-- Last-resort shop: plain machines and a counter with their PromptParts, so pets and items stay purchasable.
local function fallbackShop(root, L)
	local f = newFolder(root, "ShopFallback")
	local S = L.ShopCenter
	box(f, "ShopTop", CFrame.new(S - Vector3.new(0, 1, 0)), Vector3.new(L.ShopR * 2, 2, L.ShopR * 2), C.Cloud, { Collide = true })
	local neckA = polar(L.ShopAngle, PLAZA_R - 4, TOP)
	local neckB = polar(L.ShopAngle, L.ShopDist - L.ShopR + 5, TOP)
	local mid = (neckA + neckB) * 0.5
	box(f, "ShopNeck", flatLook(mid, neckB) * CFrame.new(0, -0.8, 0), Vector3.new(14, 1.2, (neckB - neckA).Magnitude), C.Stone, { Collide = true })
	local roulettes = {}
	local count = #Config.Roulettes
	for i, roulette in ipairs(Config.Roulettes) do
		local pos = S + Vector3.new((i - (count + 1) / 2) * 12, 0, -12)
		roulettes[roulette.Id] = fallbackMachine(f, flatLook(pos, S), roulette)
	end
	local stallPos = S + Vector3.new(0, 0, 12)
	local stall = fallbackItemStall(f, flatLook(stallPos, S))
	return { Roulettes = roulettes, ItemShop = stall }
end

----------------------------------------------------------------------
-- Home plots (one per spot) and the ring street
----------------------------------------------------------------------

-- Local positions inside a plot (studs; origin = yard centre on the ground, -Z = gate / street side).
local PLOT_POS = {
	Gate = -G.PlotHalf,
	Mailbox = Vector3.new(-11, 0, -G.PlotHalf - 2),
	Podium = Vector3.new(G.PlotHalf - 12, 0, -G.PlotHalf + 10),
	Spawn = Vector3.new(0, 3, -12),
}

-- Everything every plot shares, built once in plot-local space and cloned per plot.
local function plotTemplate()
	return template("Plot", function()
		local m = Instance.new("Model")
		m.Name = "Plot"
		local half = G.PlotHalf
		local ix = G.IslandHalfX
		local front, back = G.IslandFront, G.IslandBack
		local depth = back - front
		local midZ = (back + front) / 2

		-- cloud island body (top 1.2 under the lawn), lumpy at the corners, bulging towards the neighbours
		-- a soft cushion profile (the edge bulges out under the lawn, then curls in) + two back puffs
		local rim = {
			{ -ix + 2, 0, back - 1, 9, 7, 9 },
			{ ix - 2, 0, back - 1, 9, 7, 9 },
		}
		VX.CloudModel({
			V = 3,
			Tiers = {
				{ SX = ix * 2 + 4, SZ = depth + 4, Z = midZ, Round = 10, H = 1 },
				{ SX = ix * 2 + 10, SZ = depth + 10, Z = midZ, Round = 14, H = 1 },
				{ SX = ix * 2 + 4, SZ = depth + 4, Z = midZ, Round = 16, H = 1 },
				{ SX = ix * 2 - 10, SZ = depth - 10, Z = midZ, Round = 18, H = 1 },
				{ SX = ix * 1.4, SZ = depth * 0.7, Z = midZ, Round = 18, H = 1 },
				{ SX = ix * 0.8, SZ = depth * 0.4, Z = midZ, Round = 12, H = 1 },
			},
			Rim = rim,
			-- nothing may rise above the yard, the verge or the street
			Carve = function(x, y, z)
				return y > 0 and ((math.abs(x) < G.PlotHalf + 1.5 and z < G.PlotHalf + 1.5 and z > -G.PlotHalf - G.Verge - 1) or (z <= -G.PlotHalf - G.Verge - 1 and z > front - 3 and math.abs(x) < ix + 6))
			end,
			MaxParts = 40,
			Seed = 9,
		}, CFrame.new(0, -1.2, 0), m, "Island", true)

		-- mowed lawn stripes in the yard + darker margins and verge (all flush at the walking height)
		local stripeW = PLOT / 6
		for i = 1, 6 do
			local z = -half + (i - 0.5) * stripeW
			box(m, "Yard", CFrame.new(0, -0.5, z), Vector3.new(PLOT, 1, stripeW), (i % 2 == 0) and C.GrassLight or C.Grass, { Collide = true, Shadow = false })
		end
		local verge = G.Verge
		box(m, "Margin", CFrame.new(-(half + ix) / 2, -0.5, (back + (-half - verge)) / 2), Vector3.new(ix - half, 1, back + half + verge), C.GrassDark, { Collide = true, Shadow = false })
		box(m, "Margin", CFrame.new((half + ix) / 2, -0.5, (back + (-half - verge)) / 2), Vector3.new(ix - half, 1, back + half + verge), C.GrassDark, { Collide = true, Shadow = false })
		box(m, "Margin", CFrame.new(0, -0.5, (back + half) / 2), Vector3.new(PLOT, 1, back - half), C.GrassDark, { Collide = true, Shadow = false })
		box(m, "Verge", CFrame.new(0, -0.5, -half - verge / 2), Vector3.new(PLOT, 1, verge), C.GrassDark, { Collide = true, Shadow = false })
		-- stepping stones from the gate into the yard
		for i, z in ipairs({ -half + 2.5, -half + 6.5, -half + 10.5 }) do
			box(m, "SteppingStone", CFrame.new((i % 2 == 0) and 0.6 or -0.4, 0.05, z), Vector3.new(4, 0.1, 2.6), C.StoneLight, { Collide = true, Shadow = false })
		end

		-- the street in front: stone slabs in two shades with darker curbs
		local sw = G.StreetW
		local slabs = 4
		local slabLen = (ix * 2) / slabs
		for i = 1, slabs do
			local x = -ix + (i - 0.5) * slabLen
			box(m, "Street", CFrame.new(x, -0.5, G.StreetZ), Vector3.new(slabLen, 1, sw - 3), (i % 2 == 0) and C.StoneLight or C.Stone, { Collide = true, Shadow = false })
		end
		for _, s in ipairs({ -1, 1 }) do
			box(m, "Curb", CFrame.new(0, -0.5, G.StreetZ + s * (sw / 2 - 0.75)), Vector3.new(ix * 2, 1, 1.5), C.StoneDark, { Collide = true, Shadow = false })
		end
		-- low hedge along the plaza side of the street (keeps walkers from stepping off the island)
		box(m, "Hedge", CFrame.new(0, 0.9, front - 0.9), Vector3.new(ix * 2, 1.8, 1.8), C.Hedge, { Collide = true })
		box(m, "HedgeTop", CFrame.new(0, 1.9, front - 0.9), Vector3.new(ix * 2 - 1, 0.4, 1.3), C.HedgeLight)

		-- fence posts + rails around the yard, open at the gate
		local postSpots = {}
		for _, x in ipairs({ -half, -half / 3, half / 3, half }) do
			postSpots[#postSpots + 1] = { x, half }
		end
		for _, z in ipairs({ -half / 3, half / 3 }) do
			postSpots[#postSpots + 1] = { -half, z }
			postSpots[#postSpots + 1] = { half, z }
		end
		postSpots[#postSpots + 1] = { -half, -half }
		postSpots[#postSpots + 1] = { half, -half }
		for _, p in ipairs(postSpots) do
			box(m, "FencePost", CFrame.new(p[1], 1.5, p[2]), Vector3.new(1, 3, 1), C.PlankDark, { Collide = true })
		end
		for _, y in ipairs({ 2.3 }) do
			box(m, "FenceRail", CFrame.new(0, y, half), Vector3.new(PLOT, 0.35, 0.35), C.Plank, { Collide = true })
			box(m, "FenceRail", CFrame.new(-half, y, 0), Vector3.new(0.35, 0.35, PLOT), C.Plank, { Collide = true })
			box(m, "FenceRail", CFrame.new(half, y, 0), Vector3.new(0.35, 0.35, PLOT), C.Plank, { Collide = true })
			local seg = half - 8
			box(m, "FenceRail", CFrame.new(-half + seg / 2, y, -half), Vector3.new(seg, 0.35, 0.35), C.Plank, { Collide = true })
			box(m, "FenceRail", CFrame.new(half - seg / 2, y, -half), Vector3.new(seg, 0.35, 0.35), C.Plank, { Collide = true })
		end

		-- the gate: stone pillars with lanterns, a beam across
		for _, s in ipairs({ -1, 1 }) do
			box(m, "GateBase", CFrame.new(s * 7.2, 0.5, -half), Vector3.new(2.6, 1, 2.6), C.StoneDark, { Collide = true })
			box(m, "GatePillar", CFrame.new(s * 7.2, 4, -half), Vector3.new(2, 6, 2), C.StoneLight, { Collide = true })
			box(m, "GateCap", CFrame.new(s * 7.2, 7.3, -half), Vector3.new(2.6, 0.6, 2.6), C.Stone)
			box(m, "GateLantern", CFrame.new(s * 7.2, 8.1, -half), Vector3.new(1, 1, 1), C.Lamp, { Material = MAT.Neon })
		end
		box(m, "GateBeam", CFrame.new(0, 6.6, -half), Vector3.new(13.4, 0.8, 1), C.PlankDark)

		-- mailbox (the nameplate floats above it); the gate lanterns light the street
		local mb = PLOT_POS.Mailbox
		box(m, "MailPost", CFrame.new(mb.X, 1.5, mb.Z), Vector3.new(0.5, 3, 0.5), C.PlankDark, { Collide = true })
		box(m, "MailBox", CFrame.new(mb.X, 3.4, mb.Z), Vector3.new(1.4, 1.2, 2.2), C.IronLight)

		-- pet podium: stepped stone with a band in the plot accent (recoloured per plot)
		local pod = Instance.new("Model")
		pod.Name = "Podium"
		local pp = PLOT_POS.Podium
		box(pod, "PodiumBase", CFrame.new(pp + Vector3.new(0, 0.5, 0)), Vector3.new(6, 1, 6), C.StoneDark, { Collide = true })
		box(pod, "Accent", CFrame.new(pp + Vector3.new(0, 1.5, 0)), Vector3.new(4.4, 1, 4.4), C.Rose, { Collide = true })
		box(pod, "PodiumTop", CFrame.new(pp + Vector3.new(0, 2.5, 0)), Vector3.new(5.2, 1, 5.2), C.StoneLight, { Collide = true })
		pod.Parent = m
		return m
	end)
end

-- "No. 7" on both faces of the plot's gate sign: 220 x 90 px, the number 1.12 studs tall, gold on navy.
local function numberSign(sign, index, accent)
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = surfaceGui(sign, face)
		local plate = plainFrame(gui, "Plate", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = 0,
		})
		vgradient(plate, C.Violet, C.Navy)
		rounded(plate, 10)
		outline(plate, accent:Lerp(C.TextGold, 0.5), 4)
		signText(plate, "No. " .. tostring(index), "Title", SIGN_TITLE, C.TextGold, "Number", 0.03, 0.04, 0.94, 0.92)
		gui.Parent = sign
	end
end

-- Home nameplate over the mailbox (World text rule): a compact pixel tag, readable from ~80 studs. Left: a round
-- avatar disc with the plot number badge; right: the name (big, outlined) and an info line. The disc holds
--   Headshot    ImageLabel: SpotService loads the owner's headshot into it (Players:GetUserThumbnailAsync)
--   Silhouette  the fallback built from frames (head + shoulders) while no headshot is available
--   FreeIcon    a "+" shown while the home is free
-- and the attributes OwnedColor / FreeColor (disc colour per state, read by SpotService).
-- Returns gui, nameLabel, subLabel.
local AVATAR_PX = 60

local function avatarDisc(parent, index, accent)
	local holder = plainFrame(parent, "AvatarHolder", { Size = UDim2.fromOffset(AVATAR_PX + 8, AVATAR_PX + 8), LayoutOrder = 1 })
	local freeColor = (Theme.Buttons and Theme.Buttons.Green) or rgb(96, 196, 108)
	local ownedColor = accent:Lerp(C.Cloud, 0.45)
	local disc = plainFrame(holder, "Avatar", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(AVATAR_PX, AVATAR_PX),
		BackgroundColor3 = freeColor,
		BackgroundTransparency = 0,
	})
	disc:SetAttribute("OwnedColor", ownedColor)
	disc:SetAttribute("FreeColor", freeColor)
	rounded(disc, UDim.new(0.5, 0))
	outline(disc, INK, 3)

	-- fallback avatar: head + shoulders in a deeper shade of the plot colour (fits inside the circle)
	local shade = Theme.Darken and Theme.Darken(accent, 0.38) or accent:Lerp(C.Navy, 0.38)
	local silhouette = plainFrame(disc, "Silhouette", { Size = UDim2.fromScale(1, 1), Visible = false })
	local head = plainFrame(silhouette, "Head", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(23, 23),
		BackgroundColor3 = shade,
		BackgroundTransparency = 0,
	})
	rounded(head, UDim.new(0.5, 0))
	local body = plainFrame(silhouette, "Shoulders", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 35),
		Size = UDim2.fromOffset(36, 19),
		BackgroundColor3 = shade,
		BackgroundTransparency = 0,
	})
	rounded(body, 10)

	-- free home: a chunky "+"
	local plus = plainFrame(disc, "FreeIcon", { Size = UDim2.fromScale(1, 1) })
	for _, size in ipairs({ Vector2.new(30, 9), Vector2.new(9, 30) }) do
		local bar = plainFrame(plus, "Bar", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(size.X, size.Y),
			BackgroundColor3 = C.Text,
			BackgroundTransparency = 0,
		})
		rounded(bar, 4)
	end

	local shot = Instance.new("ImageLabel")
	shot.Name = "Headshot"
	shot.AnchorPoint = Vector2.new(0.5, 0.5)
	shot.Position = UDim2.fromScale(0.5, 0.5)
	shot.Size = UDim2.new(1, -4, 1, -4)
	shot.BackgroundTransparency = 1
	shot.BorderSizePixel = 0
	shot.Image = ""
	shot.ScaleType = Enum.ScaleType.Crop
	shot.Visible = false
	rounded(shot, UDim.new(0.5, 0))
	shot.Parent = disc

	-- plot number badge on the disc's lower-left edge
	local badge = plainFrame(holder, "NumberBadge", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 10, 1, -9),
		Size = UDim2.fromOffset(26, TAG_SMALL + 6),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = 0,
		ZIndex = 3,
	})
	rounded(badge, 10)
	outline(badge, INK, 2.5)
	padding(badge, 1, 6, 2)
	local number = tagText(badge, "Number", "#" .. tostring(index), "Display", TAG_SMALL, C.Text, 1, 2)
	number.ZIndex = 4
	return holder
end

local function homeNameplate(anchor, index, accent)
	-- bottom edge 7.2 studs up: a few studs over the mailbox, under the gate lanterns' glow
	local gui = newTag(anchor, "Nameplate", 460, 110, -2.4, 100)
	local plate = tagPlate(gui, accent, 230, Enum.FillDirection.Horizontal, 12)
	local pad = plate:FindFirstChildOfClass("UIPadding")
	if pad then -- the avatar disc hugs the left edge
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 18)
		pad.PaddingTop = UDim.new(0, 5)
		pad.PaddingBottom = UDim.new(0, 5)
	end
	avatarDisc(plate, index, accent)
	local texts = plainFrame(plate, "Texts", { AutomaticSize = Enum.AutomaticSize.XY, LayoutOrder = 2 })
	listLayout(texts, Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left)
	local nameLabel = tagText(texts, "NameLabel", "Free home", "Title", TAG_NAME, C.Text, 1)
	local subLabel = tagText(texts, "SubLabel", "Step in to claim", "Body", TAG_INFO, C.TextGold, 2, 2)
	return gui, nameLabel, subLabel
end

local function buildSpot(parent, index, angle)
	local accent = ACCENTS[(index - 1) % #ACCENTS + 1]
	local f = newFolder(parent, string.format("Spot_%02d", index))
	f:SetAttribute("SpotIndex", index)
	local centre = polar(angle, SPOT_R, TOP)
	local plotCF = faceCentre(centre) -- LookVector = towards the gate / street / plaza
	local function at(v)
		return plotCF * CFrame.new(v)
	end

	local plot = place(plotTemplate(), plotCF, f, "Plot")
	if plot then
		-- the podium trim takes the plot accent
		local podium = plot:FindFirstChild("Podium")
		if podium then
			for _, d in ipairs(podium:GetChildren()) do
				if d:IsA("BasePart") and d.Name == "Accent" then
					d.Color = accent
				end
			end
		end
	else
		-- plain stand-in (template failed): a lawn slab so the spot stays usable
		box(f, "Yard", plotCF * CFrame.new(0, -0.5, -9), Vector3.new(PLOT + 12, 1, PLOT + 30), C.Grass, { Collide = true })
	end

	-- per-plot accents: banner pennants on the gate beam, mailbox flag, number sign
	for _, s in ipairs({ -1, 1 }) do
		box(f, "GateBanner", at(Vector3.new(s * 5.4, 5.4, PLOT_POS.Gate - 0.6)), Vector3.new(1.6, 2, 0.15), accent, { Shadow = false })
	end
	local mb = PLOT_POS.Mailbox
	box(f, "MailFlag", at(Vector3.new(mb.X + 0.85, 4.2, mb.Z + 0.4)), Vector3.new(0.15, 1, 0.8), accent, { Shadow = false })
	local sign = box(f, "NumberSign", at(Vector3.new(0, 7.9, PLOT_POS.Gate)), Vector3.new(4.4, 1.8, 0.5), C.Plank)
	numberSign(sign, index, accent)

	-- nameplate over the mailbox
	local anchor = anchorPart(f, "NameplateAnchor", at(Vector3.new(mb.X, 9.6, mb.Z)).Position)
	local gui, nameLabel, subLabel = homeNameplate(anchor, index, accent)

	local podiumTop = at(PLOT_POS.Podium + Vector3.new(0, 3, 0)).Position
	local spawnPos = at(PLOT_POS.Spawn).Position
	return {
		Index = index,
		Folder = f,
		Center = centre,
		SpawnCFrame = flatLook(spawnPos, centre + Vector3.new(0, 3, 0) + plotCF.LookVector * -30),
		NameLabel = nameLabel,
		SubLabel = subLabel,
		Nameplate = gui,
		PodiumCFrame = flatLook(podiumTop, podiumTop + plotCF.LookVector),
		PlotCFrame = plotCF,
		PlotSize = PLOT,
		GateCFrame = at(Vector3.new(0, 0, PLOT_POS.Gate)),
		Accent = accent,
	}
end

-- Bare-minimum spot (see fallbackPortal): a lawn slab, a podium and the two labels.
local function fallbackSpot(parent, index, angle)
	local old = parent:FindFirstChild(string.format("Spot_%02d", index))
	if old then
		old:Destroy()
	end
	local f = newFolder(parent, string.format("Spot_%02d", index))
	f:SetAttribute("SpotIndex", index)
	local centre = polar(angle, SPOT_R, TOP)
	local plotCF = faceCentre(centre)
	box(f, "Yard", plotCF * CFrame.new(0, -0.5, -9), Vector3.new(PLOT + 12, 1, PLOT + 30), C.Grass, { Collide = true })
	box(f, "PodiumBase", plotCF * CFrame.new(PLOT_POS.Podium + Vector3.new(0, 1.5, 0)), Vector3.new(5, 3, 5), C.Stone, { Collide = true })
	local anchor = anchorPart(f, "NameplateAnchor", (plotCF * CFrame.new(PLOT_POS.Mailbox + Vector3.new(0, 9.6, 0))).Position)
	local gui, nameLabel, subLabel = homeNameplate(anchor, index, C.TextGold)
	local podiumTop = (plotCF * CFrame.new(PLOT_POS.Podium + Vector3.new(0, 3, 0))).Position
	local spawnPos = (plotCF * CFrame.new(PLOT_POS.Spawn)).Position
	return {
		Index = index,
		Folder = f,
		Center = centre,
		SpawnCFrame = flatLook(spawnPos, centre + Vector3.new(0, 3, 0) + plotCF.LookVector * -30),
		NameLabel = nameLabel,
		SubLabel = subLabel,
		Nameplate = gui,
		PodiumCFrame = flatLook(podiumTop, podiumTop + plotCF.LookVector),
		PlotCFrame = plotCF,
		PlotSize = PLOT,
		GateCFrame = plotCF * CFrame.new(0, 0, PLOT_POS.Gate),
		Accent = C.TextGold,
	}
end

-- Rope rail with end posts along a straight edge (a, b = ground points).
local function rail(parent, a, b, height)
	height = height or 2.8
	local m = newModel(parent, "Rail")
	local dir = b - a
	local len = dir.Magnitude
	if len < 1 then
		return m
	end
	local posts = math.max(2, math.floor(len / 30) + 1)
	for i = 0, posts - 1 do
		local p = a + dir * (i / (posts - 1))
		box(m, "RailPost", CFrame.new(p + Vector3.new(0, height / 2, 0)), Vector3.new(0.6, height, 0.6), C.PlankDark, { Collide = true })
	end
	local mid = (a + b) * 0.5 + Vector3.new(0, height - 0.4, 0)
	box(m, "RailRope", CFrame.lookAt(mid, mid + dir), Vector3.new(0.3, 0.3, len), C.Plank, { Collide = true, Shadow = false })
	return m
end

-- A wooden bridge between two ground points (deck top `topOffset` below TOP): longitudinal planks, edge
-- beams, rope rails on both sides (open ends) and optional cloud puffs underneath.
local function woodBridge(parent, name, a, b, width, opts)
	opts = opts or {}
	local m = newModel(parent, name)
	local topY = TOP + (opts.Top or -0.2)
	a = Vector3.new(a.X, topY, a.Z)
	b = Vector3.new(b.X, topY, b.Z)
	local dir = b - a
	local len = dir.Magnitude
	local cf = CFrame.lookAt((a + b) * 0.5, b)
	local planks = math.max(3, math.floor(width / 2 + 0.5))
	local pw = width / planks
	for i = 1, planks do
		local x = -width / 2 + (i - 0.5) * pw
		box(m, "Plank", cf * CFrame.new(x, -0.5, 0), Vector3.new(pw, 1, len), (i % 2 == 0) and C.PlankLight or C.Plank, { Collide = true, Shadow = len > 8 })
	end
	if opts.Rails ~= false then
		local insetA = opts.RailInsetA or opts.RailInset or 3
		local insetB = opts.RailInsetB or opts.RailInset or 3
		local right = cf.RightVector
		for _, s in ipairs({ -1, 1 }) do
			if not (opts.NoRail and opts.NoRail[s]) then
				local off = right * (s * (width / 2 - 0.3))
				local p0 = a + dir.Unit * insetA + off
				local p1 = b - dir.Unit * insetB + off
				rail(m, Vector3.new(p0.X, topY, p0.Z), Vector3.new(p1.X, topY, p1.Z))
			end
		end
	end
	for _, t in ipairs(opts.Puffs or {}) do
		place(Props.Puff(opts.PuffSize or "M"), CFrame.new(a + dir * t - Vector3.new(0, 2.2, 0)) * CFrame.Angles(0, t * 7, 0), m, "BridgePuff")
	end
	return m
end

-- Ring street junctions (plank bridges between neighbouring plots), spoke bridges and garden bridges.
local function buildRoads(root, L)
	local f = newFolder(root, "Roads")
	local ext = G.JunctionX + G.StreetExt
	local ix = G.IslandHalfX
	local sw = G.StreetW
	for j, info in ipairs(L.Junctions) do
		local a = info.Angle
		local open = info.Spoke or info.Garden -- something docks on the plaza side here
		local jf = newModel(f, string.format("Junction_%02d", j))
		-- half A belongs to the plot before the junction (its local -X side), half B to the plot after it
		for half = 1, 2 do
			local plotAngle = (half == 1) and (a - G.HalfStep) or (a + G.HalfStep)
			local plotCF = faceCentre(polar(plotAngle, SPOT_R, TOP))
			local s = (half == 1) and -1 or 1
			local lift = (half == 1) and 0 or -0.1 -- the halves overlap at the junction: never coplanar
			local x0, x1 = s * ix, s * ext
			local len = math.abs(x1 - x0)
			local count = math.max(2, math.floor(len / 4 + 0.5))
			local pw = len / count
			for i = 1, count do
				local x = x0 + s * (i - 0.5) * pw
				box(jf, "Plank", plotCF * CFrame.new(x, -0.5 + lift, G.StreetZ), Vector3.new(pw, 1, sw), (i % 2 == 0) and C.PlankLight or C.Plank, { Collide = true, Shadow = false })
			end
		end
		-- one straight rail per side across both halves: outer always, inner unless a bridge docks here
		local plotA = faceCentre(polar(a - G.HalfStep, SPOT_R, TOP))
		local plotB = faceCentre(polar(a + G.HalfStep, SPOT_R, TOP))
		local sides = { G.StreetZ + sw / 2 - 0.9 }
		if not open then
			sides[2] = G.StreetZ - sw / 2 + 0.9
		end
		for _, z in ipairs(sides) do
			local pA = (plotA * CFrame.new(-ix - 0.8, 0, z)).Position
			local pB = (plotB * CFrame.new(ix + 0.8, 0, z)).Position
			rail(jf, Vector3.new(pA.X, TOP, pA.Z), Vector3.new(pB.X, TOP, pB.Z))
		end
		if open then
			-- short inner rails on both sides of the docking bridge
			local zIn = G.StreetZ - sw / 2 + 0.9
			local dock = polar(a, G.StreetR / math.cos(math.rad(G.HalfStep)) - sw / 2, TOP)
			local keep = ((info.Spoke and G.SpokeW) or 8) / 2 + 0.8
			for _, p in ipairs({ (plotA * CFrame.new(-ix - 0.8, 0, zIn)).Position, (plotB * CFrame.new(ix + 0.8, 0, zIn)).Position }) do
				local d = Vector3.new(dock.X - p.X, 0, dock.Z - p.Z)
				local len = d.Magnitude - keep
				if len > 1.5 then
					local q = p + d.Unit * len
					rail(jf, Vector3.new(p.X, TOP, p.Z), Vector3.new(q.X, TOP, q.Z))
				end
			end
		end
	end

	-- Spokes: plaza rim -> junction, over open sky, carried by cloud puffs.
	for _, a in ipairs(L.SpokeAngles) do
		local p0 = polar(a, PLAZA_R - 3, TOP)
		local p1 = polar(a, G.SpokeEndR, TOP)
		-- rails run from the plaza's cloud rim right up to the street edge (no open window over the sky)
		woodBridge(f, "Spoke", p0, p1, G.SpokeW, { Puffs = { 0.52 }, PuffSize = "S", RailInsetA = 6, RailInsetB = 2.6 })
	end
end

----------------------------------------------------------------------
-- Garden islands (hanging off the street) and the reserved Storm Altar site
----------------------------------------------------------------------

-- Five stacked ground layers around `centre` (2-stud cells). fn(x, z, r) -> l1, l2, l3, l4 (see plazaCell).
local function layeredGround(parent, centre, radius, fn)
	local cell = 2
	local n = math.ceil(radius / cell)
	local grids = { Voxel.NewGrid(1), Voxel.NewGrid(1), Voxel.NewGrid(1), Voxel.NewGrid(1), Voxel.NewGrid(1) }
	for i = -n, n do
		for k = -n, n do
			local x, z = i * cell, k * cell
			local r = math.sqrt(x * x + z * z)
			if r <= radius - 0.5 then
				Voxel.Set(grids[1], i, 0, k, "Grass")
				local keys = { fn(x, z, r) }
				for li = 1, 4 do
					if keys[li] then
						Voxel.Set(grids[li + 1], i, 0, k, keys[li])
					end
				end
			end
		end
	end
	local tops = { -0.4, -0.3, -0.1, 0, 0.1 }
	for li = 1, 5 do
		VX.Build(grids[li], { V = cell, Name = "Ground" .. li, CF = CFrame.new(centre.X, TOP + tops[li] - cell / 2, centre.Z), Collide = true, Shadow = false, Parent = parent })
	end
end

local function buildPond(parent, ground)
	local g = Voxel.NewGrid(14)
	VX.Ring(g, 0, 0, 5.2, 6.9, 0, 1, "Stone")
	VX.Disc(g, 0, 0, 5.3, -1, -1, "WaterDeep")
	VX.Disc(g, 0, 0, 5.3, 0, 0, "Water")
	for _, p in ipairs({ { -2, 1 }, { 2, -2 }, { 1, 3 } }) do
		Voxel.Set(g, p[1], 0, p[2], "Leaf")
		Voxel.Set(g, p[1] + 1, 0, p[2], "Leaf")
	end
	Voxel.Set(g, 1, 1, 3, "Blossom")
	Voxel.Set(g, -2, 1, 1, "BlossomWhite")
	local water = VX.Split(g, { Water = true })
	local cf = CFrame.new(ground.X, TOP + 0.1, ground.Z)
	VX.Build(g, { V = 1, Name = "PondStone", CF = cf, Collide = true, Parent = parent })
	VX.Build(water, { V = 1, Name = "PondWater", CF = cf, Collide = false, Parent = parent })
	local sparkle = anchorPart(parent, "PondSparkle", ground + Vector3.new(0, 1, 0), Vector3.new(9, 1, 9))
	emitter(sparkle, { Color = ColorSequence.new(rgb(200, 236, 255)), Rate = 3, Lifetime = NumberRange.new(1.5, 2.5), Speed = NumberRange.new(0.2, 0.6), Size = popSize(0.5) })
end

local function buildGarden(parent, spec, L)
	local f = newFolder(parent, "Garden_" .. (spec.Name:gsub("%s", "")))
	local a = spec.Angle
	local c = polar(a, G.GardenR, TOP)
	local R = G.GardenSize
	local out = dirOf(a)
	local rng = Util.NewRng(SEED + 40 + math.floor(a))
	local cf = flatLook(c, c + out) -- local -Z = outwards (towards the street bridge)

	local rim, puffs = {}, {}
	for i = 1, 6 do
		local deg = (i - 1) * 60 + a + 180 + rng:Float(-6, 6)
		if angleDiff(deg, a) > 30 then
			local s = rng:Float(8, 9.5)
			rim[#rim + 1] = { math.cos(math.rad(deg)) * (R + 1.5), rng:Float(-1.5, 0), math.sin(math.rad(deg)) * (R + 1.5), s, s * 0.62, s }
		end
	end
	for i = 1, 3 do
		local ang = (i - 1) / 3 * math.pi * 2 + rng:Float(-0.3, 0.3)
		local s = rng:Float(7, 9)
		puffs[#puffs + 1] = { math.cos(ang) * (R - 5), -6, math.sin(ang) * (R - 5), s, s * 0.7, s }
	end
	VX.CloudModel({
		V = 3,
		Tiers = { { R = R + 3, H = 1 }, { R = R - 3, H = 2 }, { R = R - 10, H = 2 }, { R = R - 16, H = 1 } },
		Puffs = puffs,
		Rim = rim,
		Carve = function(x, y, z)
			return y > 0 and (x * x + z * z) < (R - 3) * (R - 3)
		end,
		MaxParts = 46,
		Seed = 20 + math.floor(a),
	}, CFrame.new(c.X, TOP - 1.2, c.Z), f, "GardenCloud", true)

	layeredGround(f, c, R, function(x, z, r)
		local l1, l2, l3
		local nz = vnoise(x + a, z - a, 18, 17)
		if nz < 0.26 then
			l1 = "GrassDark"
		elseif nz > 0.76 then
			l1 = "GrassLight"
		end
		local ring = math.abs(r - 10)
		local t = x * out.X + z * out.Z
		local d = math.abs(-x * out.Z + z * out.X)
		local onPath = t >= 9 and d <= 3.6
		if ring <= 3.6 or onPath then
			l2 = "SandDark"
		end
		if ring <= 2.2 or (t >= 9 and d <= 2.2) then
			l3 = "Sand"
		end
		if not l2 and r > R - 6 and hash3(math.floor(x), 7, math.floor(z), 3) < 0.09 then
			l1 = "Flower" .. (math.floor(hash3(math.floor(x), 8, math.floor(z), 6) * #FLOWERS) + 1)
		end
		return l1, l2, l3, nil
	end)

	-- features
	local function localPos(deg, dist)
		-- deg measured from the outward direction
		return (cf * CFrame.Angles(0, math.rad(deg), 0) * CFrame.new(0, 0, -dist)).Position
	end
	if spec.Kind == "Pond" then
		buildPond(f, c)
		place(Props.Tree("Round"), CFrame.new(localPos(180, 16)) * CFrame.Angles(0, 1.3, 0), f, "RoundTree")
		place(Props.FlowerBed(6), flatLook(localPos(140, 16), c) * CFrame.Angles(0, math.rad(90), 0), f, "FlowerBed")
	else
		place(Props.Tree("Blossom"), CFrame.new(c) * CFrame.Angles(0, 0.7, 0), f, "BlossomTree")
		place(Props.FlowerBed(1), flatLook(localPos(180, 16), c) * CFrame.Angles(0, math.rad(90), 0), f, "FlowerBed")
	end
	for _, deg in ipairs({ 75, -75 }) do
		local p = localPos(deg, 15.5)
		place(Props.Bench(), flatLook(p, c), f, "Bench")
	end

	-- name tag + the bridge to the street junction
	local tag = anchorPart(f, "NameTag", c + Vector3.new(0, 22, 0))
	local gui = newTag(tag, "NameTag", 320, 80, -1.7, 120)
	local plate = tagPlate(gui, rgb(150, 210, 160), 160)
	tagText(plate, "Text", spec.Name, "Title", TAG_NAME + 2, C.Text, 1)
	woodBridge(f, "GardenBridge", polar(a, G.GardenR + R - 3, TOP), polar(a, G.SpokeEndR, TOP), 8, { RailInsetA = 3, RailInsetB = 2.6 })
	return f
end

----------------------------------------------------------------------
-- Sky: voxel cumulus around the village and a cloud sea far below (never collidable)
----------------------------------------------------------------------

local function cumulus(kind)
	return template("Sky" .. kind, function()
		local r = Util.NewRng(SEED + #kind * 13)
		local w = (kind == "Big") and 96 or ((kind == "Sea") and 150 or 60)
		local V = (kind == "Sea") and 8 or 6
		local rim = {}
		local n = (kind == "Sea") and 7 or 5
		for i = 1, n do
			local x = (i - (n + 1) / 2) / n * w * 0.9 + r:Float(-4, 4)
			local s = r:Float(0.16, 0.24) * w
			rim[#rim + 1] = { x, r:Float(0, 6), r:Float(-w * 0.12, w * 0.12), s, s * ((kind == "Sea") and 0.5 or 0.8), s * 0.9 }
		end
		if kind ~= "Sea" then
			rim[#rim + 1] = { r:Float(-6, 6), w * 0.18, 0, w * 0.22, w * 0.2, w * 0.2 }
		end
		local spec = {
			V = V,
			Tiers = { { SX = w, SZ = w * 0.55, Round = w * 0.2, H = 1, Key = "Mist" } },
			Rim = rim,
			MaxParts = (kind == "Sea") and 26 or 32,
			Seed = #kind,
		}
		return VX.CloudModel(spec, CFrame.new(), nil, "SkyCloud", false)
	end)
end

local function buildSky(root)
	local f = newFolder(root, "Sky")
	local rng = Util.NewRng(SEED + 5)
	local count = 3
	for i = 1, count do
		local ang = (i - 1) * (360 / count) + rng:Float(-14, 14) + 20
		local dist = rng:Float(430, 620)
		local y = TOP + rng:Float(-40, 80)
		local kind = (i == 2) and "Small" or "Big"
		local pos = polar(ang, dist, y)
		place(cumulus(kind), CFrame.new(pos) * CFrame.Angles(0, math.rad(rng:Float(0, 360)), 0), f, "SkyCloud")
	end
	for i = 1, 2 do
		local ang = (i - 1) * 180 + rng:Float(40, 80)
		local dist = rng:Float(120, 460)
		place(cumulus("Sea"), CFrame.new(polar(ang, dist, TOP - rng:Float(120, 170))) * CFrame.Angles(0, math.rad(rng:Float(0, 360)), 0), f, "CloudSea")
	end
	local dust = anchorPart(f, "SkyDust", Vector3.new(OX, TOP + 24, OZ), Vector3.new(560, 90, 560))
	emitter(dust, {
		Color = ColorSequence.new(rgb(255, 236, 200), rgb(200, 220, 255)),
		Rate = 14,
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
	return ok
end

-- Six spots on the plaza lawn when the decor pass could not compute them.
local function defaultNpcSpots(L)
	local spots = {}
	local plan = { 22.5, 157.5, L.ShopAngle - 30, L.ShopAngle + 30, L.ShopAngle - 60, L.ShopAngle + 60 }
	for _, a in ipairs(plan) do
		local pos = polar(a, 58, TOP)
		spots[#spots + 1] = faceCentre(pos)
	end
	return spots
end

function LobbyBuilder.Build()
	templates = {}
	reserved = {}
	gateBoxCache = nil
	machineBoxCache = nil

	local old = Workspace:FindFirstChild("NimbusLobby")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = "NimbusLobby"

	local L = computeLayout()
	local diffs = Config.Difficulties
	if not Voxel then
		warn("[LobbyBuilder] shared/Voxel is missing: building the plain fallback lobby")
	end

	-- Gameplay-critical objects first (portals, spots, shop); each has a bare-bones fallback.
	local portals = {}
	local portalFolder = newFolder(root, "Portals")
	for i, diff in ipairs(diffs) do
		local angle = L.PortalAngles[i]
		local ok, result = pcall(buildPortal, portalFolder, diff, angle)
		if not ok then
			warn("[LobbyBuilder] portal " .. tostring(diff.Id) .. " failed: " .. tostring(result))
			result = fallbackPortal(portalFolder, diff, angle)
		end
		portals[diff.Id] = result
	end

	local spots = {}
	local spotFolder = newFolder(root, "Spots")
	for i = 1, SPOT_COUNT do
		local angle = L.PlotAngles[i]
		local ok, result = pcall(buildSpot, spotFolder, i, angle)
		if not ok then
			warn("[LobbyBuilder] spot " .. tostring(i) .. " failed: " .. tostring(result))
			result = fallbackSpot(spotFolder, i, angle)
		end
		spots[i] = result
	end

	local okShop, shop = pcall(buildShop, root, L)
	if not okShop then
		warn("[LobbyBuilder] shop failed: " .. tostring(shop))
		local broken = root:FindFirstChild("Shop")
		if broken then
			broken:Destroy()
		end
		shop = fallbackShop(root, L)
	end

	-- The plaza ground is where everyone spawns: keep a plain floor if the voxel plaza cannot be built.
	local okPlaza = section("plaza", function()
		buildPlaza(root, L)
	end)
	if not okPlaza or not root:FindFirstChild("Plaza") or not root.Plaza:FindFirstChild("Paths") then
		local floor = newFolder(root, "PlazaFallback")
		box(floor, "PlazaFloor", CFrame.new(OX, TOP - 1, OZ), Vector3.new(PLAZA_R * 1.7, 2, PLAZA_R * 1.7), C.Grass, { Collide = true })
		box(floor, "ShopNeckFloor", CFrame.new((Vector3.new(OX, TOP - 1, OZ) + L.ShopCenter - Vector3.new(0, 1, 0)) * 0.5), Vector3.new(16, 2, L.ShopDist), C.Stone, { Collide = true })
	end
	if type(L.NpcSpots) ~= "table" or #L.NpcSpots < 6 then
		L.NpcSpots = defaultNpcSpots(L)
	end

	section("roads", function()
		buildRoads(root, L)
	end)
	section("gardens", function()
		local gf = newFolder(root, "Gardens")
		for _, spec in ipairs(L.Gardens) do
			section("garden " .. spec.Name, function()
				buildGarden(gf, spec, L)
			end)
		end
	end)
	section("sky", function()
		buildSky(root)
	end)

	root.Parent = Workspace
	-- the templates and merged box lists are only needed while building
	templates = {}
	gateBoxCache = nil
	machineBoxCache = nil

	-- Spawn on the golden medallion in the middle of the court, looking at the middle portal.
	local spawnPos = Vector3.new(OX, TOP + 3, OZ)
	local focus = polar(L.MidAngle, PORTAL_R, TOP + 3)
	local altarSite = nil
	local altarDock = nil
	if L.AltarAngle then
		altarSite = faceCentre(polar(L.AltarAngle, G.GardenR, TOP))
		altarDock = polar(L.AltarAngle, G.SpokeEndR - 2.4, TOP)
	end

	local parts = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			parts = parts + 1
		end
	end
	print(string.format("[LobbyBuilder] voxel lobby built (%d parts, %d portals, %d plots)", parts, #diffs, #spots))

	return {
		Folder = root,
		SpawnCFrame = flatLook(spawnPos, focus),
		Portals = portals,
		Spots = spots,
		Shop = shop,
		NpcSpots = L.NpcSpots,
		AltarSite = altarSite, -- reserved for the Storm Altar (ARCHITECTURE_V3.md section 10), faces the plaza
		AltarDock = altarDock, -- street inner edge where a bridge to the altar island can dock
	}
end

return LobbyBuilder
