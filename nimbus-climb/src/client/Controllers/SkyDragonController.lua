-- SkyDragonController (client): the Sage Dragon, a big eastern (serpentine) dragon that swims through the sky in a
-- slow closed loop high above the lobby, purely for atmosphere (ARCHITECTURE_V3.md section 7 + "ART DIRECTION").
--
--   SkyDragonController.Init()
--   SkyDragonController.GetModel()      -- the dragon Model once it is built (nil before; debug / tests)
--   SkyDragonController.IsPaused()      -- true while the camera is far from the lobby (the dragon is frozen)
--
-- Look: detailed fine-voxel style, every piece sculpted with shared/Voxel.lua at ONE voxel scale (1 stud).
--   * head: a long snout with a bulbous upturned nose and carved nostrils, glowing amber eyes (slit pupil and a white
--     highlight voxel) set one voxel into the face under heavy overhanging brows, gold antlers with a forward tine,
--     layered ivory cheek frills, a mane collar and a crown tuft, gold whisker roots and fangs; the lower jaw (cream
--     chin plates and a wise sage's beard) is its own piece and slowly opens and closes;
--   * body: 14 tube segments of sage-green scales in three shades (light back, mid flanks, a dark flank line), a flat
--     cream belly with raised plate rims, a darker raised spine ridge and a tiered jade dorsal spine; thick at the
--     shoulders, tapering to a tail that ends in a puffy cloud tuft; four short legs with ivory claws and elbow
--     tufts paddle while it swims;
--   * block-chain whiskers (gold) and mane locks (ivory) trail from the head as follow-the-leader chains;
--   * small voxel cloud puffs drift off the tail tuft, swell and fade.
-- Big surfaces are auto-shaded with Voxel.Shade; small features use hand-placed shade keys (dark root, light tip),
-- and the forms are bevelled boxes and stepped tiers, which keeps the silhouettes crisp and the part count low.
-- Motion: the head flies a smooth closed 3D figure-eight (70 s per loop at constant speed) 140-220 studs above
-- Config.Lobby.Origin, with a vertical swimming bob and a little sway. Every body piece follows the head along the
-- path history (a ring buffer of head positions sampled every stud), so the whole body undulates like a real
-- serpent and banks into each turn exactly where the head banked.
-- Runtime: client only, in workspace.ClientFx; parts are anchored with collisions, touches, queries and shadows off.
-- One RenderStepped connection poses every part and moves them all with one workspace:BulkMoveTo call; the per-frame
-- code builds no tables, closures or instances (only the unavoidable CFrame values). Frozen while the camera is far
-- from the lobby (e.g. the player is in a match). About 295 parts.
-- Plain Lua 5.1-compatible syntax only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SkyDragonController = {}

local sin, cos, sqrt, floor, max, min = math.sin, math.cos, math.sqrt, math.floor, math.max, math.min
local PI = math.pi
local TAU = PI * 2

----------------------------------------------------------------------
-- Tuning
----------------------------------------------------------------------
local VS = 1 -- studs per voxel, the same for every piece of the dragon
local FOLDER_NAME = "ClientFx"
local MODEL_NAME = "SkyDragon"
local TAG = "[SkyDragon] "
local FAR_SQ = 1500 * 1500 -- camera further than this from the lobby -> frozen
local MAX_DT = 0.1

-- Flight path (studs, relative to Config.Lobby.Origin): a figure-eight over the plaza and the home plots that crosses
-- itself at two different heights (47 studs apart), so the body never passes through itself.
local PATH = {
	Period = 70, -- seconds per loop
	AmpX = 280,
	AmpZ = 150,
	Altitude = 170,
	AltA = 32,
	AltB = 12,
	BobAmp = 4, -- the swimming wave that runs down the body
	BobPeriod = 3.4,
	SwayAmp = 3,
	SwayPeriod = 5.3,
	BankGain = 34, -- lean of the up vector per unit of curvature (studs)
	MaxTilt = 0.7, -- tan(35 degrees)
}

-- Body layout along the path (studs).
local BODY = {
	SegHalf = 5, -- a segment is 2 * SegHalf + 1 voxels long
	Spacing = 7.5, -- between segment centres (neighbours overlap by 3.5 studs, so bends never open gaps)
	HeadGap = 6, -- from the head pivot to the first segment centre
	TailGap = 6.5, -- from the last segment centre to the tail pivot
	LookBase = 3, -- half the path baseline used to aim a body piece
	HeadLook = 6, -- baseline used to aim the head
}

-- Radius (voxels) per segment, neck first; the first two carry the mane locks instead of a dorsal spine.
local SEGMENTS = {
	{ R = 3.0, Fin = false },
	{ R = 3.5, Fin = false },
	{ R = 4.0, Fin = true },
	{ R = 4.5, Fin = true },
	{ R = 4.5, Fin = true },
	{ R = 4.5, Fin = true },
	{ R = 4.0, Fin = true },
	{ R = 4.0, Fin = true },
	{ R = 3.5, Fin = true },
	{ R = 3.5, Fin = true },
	{ R = 3.0, Fin = true },
	{ R = 2.5, Fin = true },
	{ R = 2.0, Fin = true },
	{ R = 1.5, Fin = true },
}

-- Part budget per piece (Voxel.Build folds near-equal auto shades first when a piece is over it). Every piece is
-- designed to fit, so these are safety caps: ~73 head, 14 jaw, 7-13 per segment, 6 per leg, 11 tail.
local BUDGET = { Head = 80, Jaw = 14, Segment = 14, Leg = 6, Tail = 14, Puff = 2 }

-- Legs paddle as they swim: segment index, side, phase.
local LEGS = {
	{ Seg = 4, Side = 1, Phase = 0 },
	{ Seg = 4, Side = -1, Phase = PI },
	{ Seg = 10, Side = 1, Phase = PI * 0.5 },
	{ Seg = 10, Side = -1, Phase = PI * 1.5 },
}
local LEG = { RestPitch = -0.55, Splay = 0.3, Swing = 0.4, Freq = 1.9 }

-- Block chains trailing from the head (anchor in head-local studs; the head looks along -Z).
local CHAINS = {
	{ Key = "Whisker", Anchor = { 4.2, 0.5, -10.5 }, Links = 4, Length = 2.3, Thick = 0.8, ThickEnd = 0.45, Droop = 2.2, Flutter = 2.4, Freq = 2.6, Phase = 0 },
	{ Key = "Whisker", Anchor = { -4.2, 0.5, -10.5 }, Links = 4, Length = 2.3, Thick = 0.8, ThickEnd = 0.45, Droop = 2.2, Flutter = 2.4, Freq = 2.6, Phase = 1.9 },
	{ Key = "Mane", Anchor = { 0, 5.2, 6.2 }, Links = 4, Length = 2.3, Thick = 1.7, ThickEnd = 0.9, Droop = 0.5, Flutter = 1.4, Freq = 1.7, Phase = 0.7 },
	{ Key = "Mane", Anchor = { 3, 3.6, 6.4 }, Links = 4, Length = 2.2, Thick = 1.5, ThickEnd = 0.8, Droop = 0.8, Flutter = 1.4, Freq = 1.9, Phase = 2.3 },
	{ Key = "Mane", Anchor = { -3, 3.6, 6.4 }, Links = 4, Length = 2.2, Thick = 1.5, ThickEnd = 0.8, Droop = 0.8, Flutter = 1.4, Freq = 1.9, Phase = 4.1 },
}

-- Cloud puffs shed by the tail tuft.
local PUFF = { Pool = 5, Life = 4.2, Every = 0.85, Rise = 1.4, Point = { 0, 2, 11 } }

-- Path history and the arc-length table.
local TRAIL_STEP = 1
local TRAIL_CAP = 256
local ARC_STEPS = 1024

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local Voxel = nil
local palette = nil
local S = {
	Started = false,
	Paused = false,
	Connection = nil,
	Model = nil,
	Clock = 0,
	PathLength = 1,
	Speed = 1,
	UseBulk = true,
	BulkMode = nil,
	Rng = nil,
	JawHinge = nil,
	TuftV = nil,
	NextPuff = 1,
	PuffTimer = 0,
	-- part index ranges of the rigid pieces
	HeadFirst = 1,
	HeadLast = 0,
	JawFirst = 1,
	JawLast = 0,
	TailFirst = 1,
	TailLast = 0,
}
local ox, oy, oz = 0, 300, 0 -- lobby origin
local thetaAtS = {}

-- trail ring buffer (newest sample at trailNewest) and the current head pivot / tilt
local trX, trY, trZ, trTX, trTZ = {}, {}, {}, {}, {}
local trailNewest, trailCount, headLead = 1, 0, 0
local hx, hy, hz, htx, htz = 0, 0, 0, 0, 0
local lastRX, lastRY, lastRZ = 1, 0, 0

-- every moving part, its target CFrame and its offset from its piece's pivot
local parts, cfs, offsets = {}, {}, {}
local nParts = 0
local seg = { First = {}, Last = {}, CF = {} }
local leg = { First = {}, Last = {}, Base = {} }
local chain = { First = {}, Anchor = {}, X = {}, Y = {}, Z = {} }
local puff = { First = {}, Last = {}, Age = {}, X = {}, Y = {}, Z = {}, Rot = {}, Scale = {}, Pos = {}, Size = {} }

----------------------------------------------------------------------
-- Palette: a tidy set of colour families, 2-3 shades each
----------------------------------------------------------------------
local function makePalette()
	local rgb = Color3.fromRGB
	return {
		Scale = rgb(138, 178, 122), Scale_Light = rgb(172, 206, 148), Scale_Dark = rgb(102, 140, 96),
		Ridge = rgb(86, 122, 86), Ridge_Light = rgb(110, 150, 102),
		Fin = rgb(84, 152, 128), Fin_Light = rgb(132, 196, 164),
		Belly = rgb(246, 233, 198), BellyLine = rgb(206, 184, 138),
		Horn = rgb(228, 180, 74), Horn_Light = rgb(250, 218, 124), Horn_Dark = rgb(182, 130, 52),
		Whisker = rgb(238, 196, 92),
		Mane = rgb(246, 243, 233), Mane_Light = rgb(255, 255, 250), Mane_Dark = rgb(214, 216, 214),
		Cloud = rgb(238, 245, 255), Cloud_Light = rgb(255, 255, 255), Cloud_Dark = rgb(204, 220, 242),
		Claw = rgb(244, 236, 214), Claw_Light = rgb(255, 250, 236),
		Eye = { Color = rgb(255, 176, 52), Material = Enum.Material.Neon },
		Pupil = rgb(46, 26, 16),
		Shine = rgb(255, 255, 255),
		Mouth = rgb(122, 42, 56),
		Tooth = rgb(250, 247, 236),
		Nostril = rgb(58, 74, 54),
	}
end

-- keys the part-budget LOD must never recolour (features and the hand-placed shades)
local KEEP = { "Eye", "Pupil", "Shine", "Nostril", "Tooth", "Mouth", "BellyLine", "Horn_Light", "Horn_Dark", "Mane_Light",
	"Mane_Dark", "Ridge_Light", "Fin_Light", "Claw_Light", "Cloud_Light", "Cloud_Dark", "Scale_Dark" }

----------------------------------------------------------------------
-- Sculpting helpers (voxel units; every piece looks along -Z with +Y up)
----------------------------------------------------------------------
local function withExtra(t, extra)
	if extra then
		for k, v in pairs(extra) do
			t[k] = v
		end
	end
	return t
end

local function rbox(g, key, c, size, round, extra)
	return Voxel.Shape(g, withExtra({ Kind = "RoundBox", Center = c, Size = size, Round = round, Key = key }, extra))
end

-- an axis-aligned block of voxels (inclusive voxel ranges); key nil + { Op = "Carve" } removes them
local function vbox(g, key, x0, x1, y0, y1, z0, z1, extra)
	return Voxel.Shape(g, withExtra({
		Kind = "Box",
		Center = { (x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5 },
		Size = { x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1 },
		Key = key,
	}, extra))
end

-- the same block on the right (x0..x1 >= 0) and mirrored on the left
local function vpair(g, key, x0, x1, y0, y1, z0, z1, extra)
	vbox(g, key, x0, x1, y0, y1, z0, z1, extra)
	vbox(g, key, -x1, -x0, y0, y1, z0, z1, extra)
end

-- x of the outermost voxel of the row (y, z) on one side (side = 1: +X, -1: -X), or nil
local function outerX(g, side, y, z)
	for i = 16, 0, -1 do
		if Voxel.Get(g, i * side, y, z) ~= nil then
			return i * side
		end
	end
	return nil
end

-- y of the topmost voxel of the column (x, z), or nil
local function topY(g, x, z)
	for y = 16, -16, -1 do
		if Voxel.Get(g, x, y, z) ~= nil then
			return y
		end
	end
	return nil
end

-- Paints a small mask onto the outer side surface, set ONE voxel into it (the surface voxel is removed and the one
-- behind takes the key), so eyes sit inside the face instead of on it. rows: top row first; columns run from the
-- front (zFront) backwards; codes maps a character to a palette key ("." = untouched). Only cells whose surface
-- voxel is skin (a "Scale" key) are touched.
local SKIN = { Scale = true, Scale_Light = true, Scale_Dark = true }
local function sideMask(g, side, yTop, zFront, rows, codes)
	for r = 1, #rows do
		local row = rows[r]
		local y = yTop - (r - 1)
		for c = 1, #row do
			local key = codes[row:sub(c, c)]
			if key then
				local z = zFront + (c - 1)
				local x = outerX(g, side, y, z)
				if x and SKIN[Voxel.Get(g, x, y, z)] then
					Voxel.Set(g, x, y, z, nil)
					Voxel.Set(g, x - side, y, z, key)
				end
			end
		end
	end
end

local EYE_ROWS = { ".SEE.", "EEPEE", ".EPE." }
local EYE_CODES = { E = "Eye", P = "Pupil", S = "Shine" }
local PAINT_SCALE = { Op = "Paint", OnlyKeys = "Scale" }
local CARVE = { Op = "Carve" }

----------------------------------------------------------------------
-- The pieces
----------------------------------------------------------------------
-- Head: the pivot (0, 0, 0) is the neck joint; the nose reaches z = -13.
local function sculptHead()
	local g = Voxel.NewGrid(20)
	-- skull, long snout and the bulbous upturned nose
	rbox(g, "Scale", { 0, 1.5, 0 }, { 9, 8, 9 }, 2.4)
	rbox(g, "Scale", { 0, 0.5, -8 }, { 7, 5, 9 }, 1.6)
	rbox(g, "Scale", { 0, 2.3, -11.5 }, { 6, 3, 3.4 }, 1.1)
	-- the spine ridge runs on over the nose; heavy brows overhang the eyes and end in small crests
	vbox(g, "Ridge", 0, 0, 4, 4, -9, -4)
	vbox(g, "Ridge", -1, 1, 6, 6, -3, 0)
	vpair(g, "Ridge", 2, 5, 4, 5, -5, -2)
	vpair(g, "Ridge_Light", 3, 4, 6, 6, -3, -1)
	-- ivory mane: a collar behind the skull, layered cheek frills sweeping back, a crown tuft
	rbox(g, "Mane", { 0, 1.5, 5.5 }, { 11, 9, 4 }, 1.6, { KeepExisting = true })
	vpair(g, "Mane_Light", 5, 5, 1, 2, 1, 6)
	vpair(g, "Mane", 5, 6, -1, 0, 1, 8)
	vpair(g, "Mane_Dark", 5, 5, -3, -2, 2, 7)
	vbox(g, "Mane_Light", -1, 1, 7, 7, 1, 6)
	vbox(g, "Mane", 0, 0, 8, 8, 3, 8)
	-- gold antlers (dark at the root, light at the tip) with a forward tine, and gold whisker roots
	vpair(g, "Horn_Dark", 2, 3, 6, 7, 0, 1)
	vpair(g, "Horn", 2, 3, 8, 8, 1, 4)
	vpair(g, "Horn", 3, 3, 9, 9, 4, 7)
	vpair(g, "Horn_Light", 3, 4, 9, 9, 8, 9)
	vpair(g, "Horn_Light", 4, 4, 10, 11, 10, 11)
	vpair(g, "Horn", 2, 2, 9, 10, 1, 1)
	vpair(g, "Horn_Light", 2, 2, 11, 11, 0, 0)
	vpair(g, "Horn", 4, 4, 0, 1, -11, -10)
	-- palate (seen when the jaw opens) and fangs at the lip line
	vbox(g, "Mouth", -1, 1, -2, -2, -11, -4, PAINT_SCALE)
	Voxel.Set(g, 3, -2, -11, "Tooth")
	Voxel.Set(g, -3, -2, -11, "Tooth")
	Voxel.Shade(g, { Only = { Scale = true }, Crease = 0.15, Smooth = 2 })
	-- carved nostrils on top of the nose and glowing eyes set into the face under the brows
	for side = -1, 1, 2 do
		for x = 1, 2 do
			local y = topY(g, side * x, -12)
			if y then
				Voxel.Set(g, side * x, y, -12, nil)
				Voxel.Set(g, side * x, y - 1, -12, "Nostril")
			end
		end
		sideMask(g, side, 3, -4, EYE_ROWS, EYE_CODES)
	end
	return g
end

-- Lower jaw, in head coordinates (it hinges at JAW_HINGE): mouth, fangs, cream chin plates and a sage's beard.
local JAW_HINGE = { 0, -2.5, 0.5 }
local function sculptJaw()
	local g = Voxel.NewGrid(20)
	rbox(g, "Scale", { 0, -4, -6.5 }, { 5, 3, 11 }, 1)
	vbox(g, "Mouth", -1, 1, -3, -3, -11, -2, PAINT_SCALE)
	Voxel.Set(g, 2, -2, -11, "Tooth")
	Voxel.Set(g, -2, -2, -11, "Tooth")
	vbox(g, "Belly", -1, 1, -5, -5, -11, -1, PAINT_SCALE)
	-- the beard: tiers narrowing downwards, swept back by the wind
	vbox(g, "Mane_Light", -1, 1, -6, -6, -11, -6)
	vbox(g, "Mane", -1, 1, -7, -7, -10, -6)
	vbox(g, "Mane", 0, 0, -8, -8, -9, -6)
	vbox(g, "Mane_Dark", 0, 0, -9, -9, -8, -7)
	vbox(g, "Mane_Dark", 0, 0, -10, -10, -7, -7)
	return g
end

-- One body segment: a straight tube of radius r (voxels) centred on (0, 0, 0) with a flat plated belly. It is
-- sculpted longer than it ends up, so the shading has no end effects, then trimmed to 2 * SegHalf + 1 voxels.
local function sculptSegment(r, withFin)
	local g = Voxel.NewGrid(20)
	local ry = r * 0.9
	local half = BODY.SegHalf
	local ext = half + 5
	Voxel.Shape(g, {
		Kind = "Ellipsoid",
		Center = { 0, 0, 0 },
		Radius = { r, ry, 80 },
		Key = "Scale",
		Pattern = function(_, _, z)
			if z < -ext or z > ext then
				return false
			end
			return nil
		end,
	})
	local top = floor(ry + 0.25)
	local bottom = -top
	if r >= 3 then
		-- flatten the belly: drop the narrow lowest row
		vbox(g, nil, -20, 20, bottom, bottom, -ext, ext, CARVE)
		bottom = bottom + 1
	end
	-- cream belly below the cut (left unshaded so it stays bright seen from below), darker raised spine ridge
	local cut = -floor(ry * 0.4 + 0.5)
	local w = (r >= 3.5) and 1 or 0
	vbox(g, "Belly", -20, 20, -20, cut, -ext, ext, PAINT_SCALE)
	vbox(g, "Ridge", -w, w, top, top + 1, -ext, ext)
	Voxel.Shade(g, { Only = { Scale = true }, Crease = 0, Smooth = 2 })
	if r >= 2.5 then
		-- a darker flank line just above the belly: the third scale shade, and a crisp belly outline from below
		vbox(g, "Scale_Dark", -20, 20, cut + 1, cut + 1, -ext, ext, PAINT_SCALE)
	end
	-- trim to length (the neighbours overlap both ends)
	vbox(g, nil, -20, 20, -20, 20, half + 1, ext + 1, CARVE)
	vbox(g, nil, -20, 20, -20, 20, -ext - 1, -half - 1, CARVE)
	if r >= 3 then
		-- belly plate edge: a scute rim one voxel proud of the belly, inset from the sides, in the stretch of the
		-- belly that only this segment shows
		local wb = 0
		while wb < 20 and Voxel.Get(g, wb + 1, bottom, 0) ~= nil do
			wb = wb + 1
		end
		wb = max(wb - 1, 0)
		vbox(g, "BellyLine", -wb, wb, bottom - 1, bottom - 1, -1, -1)
	end
	-- a flat jade dorsal spine in tiers that lean back, lighter at the tip
	if withFin then
		local h = max(2, floor(r + 0.5))
		local tiers = floor((h + 1) / 2)
		for t = 0, tiers - 1 do
			local y0 = top + 2 + t * 2
			local y1 = min(y0 + 1, top + 1 + h)
			local key = (tiers > 1 and t == tiers - 1) and "Fin_Light" or "Fin"
			vbox(g, key, 0, 0, y0, y1, -2 + t * 2, 2 + min(t, 1))
		end
	end
	return g
end

-- A short leg: the pivot is the shoulder / hip joint; it reaches down with the paw and its claws forward.
local function sculptLeg()
	local g = Voxel.NewGrid(10)
	vbox(g, "Scale", -1, 1, -3, 0, 0, 2)
	vbox(g, "Scale", -1, 1, -5, -3, -1, 0)
	vbox(g, "Scale_Dark", -1, 1, -6, -6, -3, 0)
	vbox(g, "Claw", -1, 1, -6, -6, -4, -4)
	vbox(g, "Claw_Light", 0, 0, -6, -6, -5, -5)
	vbox(g, "Mane", 0, 0, -3, -2, 3, 5)
	return g
end

-- Tail tip: tapers on from the last segment into a puffy cloud tuft (cloud white, light bumps on top, a cool
-- blue-white underside).
local function sculptTail()
	local g = Voxel.NewGrid(20)
	vbox(g, "Scale", -1, 1, -1, 1, -5, 2)
	vbox(g, "Scale", -1, 1, 0, 1, 3, 5)
	vbox(g, "Belly", -1, 1, -1, -1, -5, 2, PAINT_SCALE)
	vbox(g, "Ridge", 0, 0, 2, 2, -5, 4)
	vbox(g, "Cloud", -3, 3, 0, 3, 6, 12)
	vpair(g, "Cloud", 4, 4, 1, 2, 7, 11)
	vbox(g, "Cloud", -2, 2, 0, 2, 5, 5)
	vbox(g, "Cloud", -2, 2, 1, 2, 13, 13)
	vbox(g, "Cloud_Dark", -2, 2, -1, -1, 7, 11)
	vbox(g, "Cloud_Light", -3, 0, 4, 4, 6, 8)
	vbox(g, "Cloud_Light", 0, 2, 4, 4, 9, 11)
	vbox(g, "Cloud_Light", -1, 1, 5, 5, 7, 7)
	return g
end

-- A small voxel cloud puff, centred on (0, 0, 0): a flat base with a soft bump, lit from above.
local function sculptPuff()
	local g = Voxel.NewGrid(6)
	vbox(g, "Cloud", -2, 2, -1, 0, -1, 1)
	vbox(g, "Cloud_Light", -1, 1, 1, 1, -1, 1)
	return g
end

local function buildPiece(grid, name, maxParts)
	return Voxel.Build(grid, {
		VoxelSize = VS,
		Palette = palette,
		Name = name,
		MaxParts = maxParts,
		Keep = KEEP,
		CastShadow = false,
		Anchored = true,
	})
end

----------------------------------------------------------------------
-- Flight path: the base figure-eight, its arc-length table and the bank tilt
----------------------------------------------------------------------
local function basePath(theta)
	return PATH.AmpX * sin(theta), PATH.Altitude + PATH.AltA * sin(theta + 0.9) + PATH.AltB * sin(2 * theta + 0.3), PATH.AmpZ * sin(2 * theta)
end

-- thetaAtS[k] = the path parameter at arc length k / ARC_STEPS of the loop (constant flying speed)
local function setupPath()
	local n = ARC_STEPS * 4
	local cum = { [0] = 0 }
	local px, py, pz = basePath(0)
	for i = 1, n do
		local x, y, z = basePath(TAU * i / n)
		local dx, dy, dz = x - px, y - py, z - pz
		cum[i] = cum[i - 1] + sqrt(dx * dx + dy * dy + dz * dz)
		px, py, pz = x, y, z
	end
	S.PathLength = max(cum[n], 1)
	S.Speed = S.PathLength / PATH.Period
	local j = 0
	for k = 0, ARC_STEPS do
		local s = S.PathLength * k / ARC_STEPS
		while j < n - 1 and cum[j + 1] < s do
			j = j + 1
		end
		local span = cum[j + 1] - cum[j]
		local f = 0
		if span > 1e-9 then
			f = min(max((s - cum[j]) / span, 0), 1)
		end
		thetaAtS[k] = TAU * (j + f) / n
	end
end

local function thetaOf(s)
	local length = S.PathLength
	local u = (s % length) / length * ARC_STEPS
	local k = floor(u)
	local f = u - k
	if k >= ARC_STEPS then
		k = ARC_STEPS - 1
		f = 1
	end
	local a = thetaAtS[k]
	return a + (thetaAtS[k + 1] - a) * f
end

-- the head pivot at time t (world) and the bank tilt (the horizontal lean of the up vector into the turn)
local function headAt(t)
	local theta = thetaOf(t * S.Speed)
	local x, y, z = basePath(theta)
	-- derivatives of the base path by theta
	local x1, x2 = PATH.AmpX * cos(theta), -PATH.AmpX * sin(theta)
	local z1, z2 = 2 * PATH.AmpZ * cos(2 * theta), -4 * PATH.AmpZ * sin(2 * theta)
	local y1 = PATH.AltA * cos(theta + 0.9) + 2 * PATH.AltB * cos(2 * theta + 0.3)
	local y2 = -PATH.AltA * sin(theta + 0.9) - 4 * PATH.AltB * sin(2 * theta + 0.3)
	local sp2 = x1 * x1 + y1 * y1 + z1 * z1
	local tx, tz = 0, 0
	if sp2 > 1e-9 then
		-- curvature vector = (P'' - (P'' . T) T) / |P'|^2: it points to the centre of the turn
		local d = (x1 * x2 + y1 * y2 + z1 * z2) / sp2
		tx = (x2 - d * x1) / sp2 * PATH.BankGain
		tz = (z2 - d * z1) / sp2 * PATH.BankGain
		local m = sqrt(tx * tx + tz * tz)
		if m > PATH.MaxTilt then
			tx, tz = tx * PATH.MaxTilt / m, tz * PATH.MaxTilt / m
		end
	end
	-- swimming bob and a gentle sideways sway (the body follows the head's trail, so the wave runs down it)
	local hl = sqrt(x1 * x1 + z1 * z1)
	local nx, nz = 0, 0
	if hl > 1e-9 then
		nx, nz = -z1 / hl, x1 / hl
	end
	local sway = PATH.SwayAmp * sin(t * TAU / PATH.SwayPeriod)
	local bob = PATH.BobAmp * sin(t * TAU / PATH.BobPeriod)
	return ox + x + nx * sway, oy + y + bob, oz + z + nz * sway, tx, tz
end

----------------------------------------------------------------------
-- Path history (ring buffer of head samples, TRAIL_STEP studs apart)
----------------------------------------------------------------------
local function pushSample(x, y, z, tx, tz)
	trailNewest = trailNewest % TRAIL_CAP + 1
	trX[trailNewest], trY[trailNewest], trZ[trailNewest] = x, y, z
	trTX[trailNewest], trTZ[trailNewest] = tx, tz
	if trailCount < TRAIL_CAP then
		trailCount = trailCount + 1
	end
end

-- moves the head to time t and records a sample every TRAIL_STEP studs along the way
local function advanceHead(t)
	hx, hy, hz, htx, htz = headAt(t)
	if trailCount == 0 then
		pushSample(hx, hy, hz, htx, htz)
	end
	local i = trailNewest
	local dx, dy, dz = hx - trX[i], hy - trY[i], hz - trZ[i]
	local dist = sqrt(dx * dx + dy * dy + dz * dz)
	local guard = 0
	while dist >= TRAIL_STEP and guard < TRAIL_CAP do
		guard = guard + 1
		local f = TRAIL_STEP / dist
		local px, py, pz = trX[i] + dx * f, trY[i] + dy * f, trZ[i] + dz * f
		pushSample(px, py, pz, trTX[i] + (htx - trTX[i]) * f, trTZ[i] + (htz - trTZ[i]) * f)
		i = trailNewest
		dx, dy, dz = hx - px, hy - py, hz - pz
		dist = sqrt(dx * dx + dy * dy + dz * dz)
	end
	headLead = dist
end

-- position and tilt at path distance d behind the head
local function trailAt(d)
	local i = trailNewest
	if d <= headLead then
		local a = 0
		if headLead > 1e-6 then
			a = max(d, 0) / headLead
		end
		return hx + (trX[i] - hx) * a, hy + (trY[i] - hy) * a, hz + (trZ[i] - hz) * a, htx + (trTX[i] - htx) * a, htz + (trTZ[i] - htz) * a
	end
	local k = (d - headLead) / TRAIL_STEP
	local n = floor(k)
	local f = k - n
	if n >= trailCount - 1 then
		n = max(trailCount - 1, 0)
		f = 0
	end
	local i1 = (trailNewest - 1 - n) % TRAIL_CAP + 1
	local i2 = (trailNewest - 2 - n) % TRAIL_CAP + 1
	return trX[i1] + (trX[i2] - trX[i1]) * f, trY[i1] + (trY[i2] - trY[i1]) * f, trZ[i1] + (trZ[i2] - trZ[i1]) * f,
		trTX[i1] + (trTX[i2] - trTX[i1]) * f, trTZ[i1] + (trTZ[i2] - trTZ[i1]) * f
end

-- CFrame at (x, y, z) looking along f, with the up vector leaning by the tilt (tx, tz)
local function orient(x, y, z, fx, fy, fz, tx, tz)
	local fl = sqrt(fx * fx + fy * fy + fz * fz)
	if fl < 1e-6 then
		fx, fy, fz = 0, 0, -1
	else
		fx, fy, fz = fx / fl, fy / fl, fz / fl
	end
	-- right = forward x (tx, 1, tz)
	local rx, ry, rz = fy * tz - fz, fz * tx - fx * tz, fx - fy * tx
	local rl = sqrt(rx * rx + ry * ry + rz * rz)
	if rl < 1e-6 then
		rx, ry, rz = lastRX, lastRY, lastRZ
	else
		rx, ry, rz = rx / rl, ry / rl, rz / rl
		lastRX, lastRY, lastRZ = rx, ry, rz
	end
	-- up = right x forward
	local ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
	return CFrame.new(x, y, z, rx, ux, -fx, ry, uy, -fy, rz, uz, -fz)
end

-- frame of a body piece at path distance d: aimed along the path, banked as the head was there
local function frameAt(d)
	local x, y, z, tx, tz = trailAt(d)
	local ax, ay, az = trailAt(d - BODY.LookBase)
	local bx, by, bz = trailAt(d + BODY.LookBase)
	return orient(x, y, z, ax - bx, ay - by, az - bz, tx, tz)
end

----------------------------------------------------------------------
-- Posing (per frame: numbers and CFrame values only)
----------------------------------------------------------------------
local function writeGroup(first, last, cf)
	for k = first, last do
		cfs[k] = cf * offsets[k]
	end
end

-- follow-the-leader chains: each block keeps its length to the one before it and is dragged along; a wave runs
-- down the strand and gravity pulls it down a little
local function poseChains(headCF, t, dt)
	local right, up, look = headCF.RightVector, headCF.UpVector, headCF.LookVector
	local cx, cy, cz = chain.X, chain.Y, chain.Z
	for c = 1, #CHAINS do
		local spec = CHAINS[c]
		local a = headCF * chain.Anchor[c]
		local px, py, pz = a.X, a.Y, a.Z
		local first = chain.First[c]
		for j = 1, spec.Links do
			local k = first + j - 1
			local dx, dy, dz = cx[k] - px, cy[k] - py, cz[k] - pz
			local w = sin(t * spec.Freq - j * 0.8 + spec.Phase) * spec.Flutter * dt
			local w2 = cos(t * spec.Freq * 0.7 - j * 0.6 + spec.Phase) * spec.Flutter * 0.6 * dt
			dx = dx + up.X * w + right.X * w2
			dy = dy + up.Y * w + right.Y * w2 - spec.Droop * dt
			dz = dz + up.Z * w + right.Z * w2
			local len = sqrt(dx * dx + dy * dy + dz * dz)
			if len < 1e-4 then
				dx, dy, dz, len = -look.X, -look.Y, -look.Z, 1
			end
			local f = spec.Length / len
			local nx, ny, nz = px + dx * f, py + dy * f, pz + dz * f
			cx[k], cy[k], cz[k] = nx, ny, nz
			cfs[k] = orient((px + nx) * 0.5, (py + ny) * 0.5, (pz + nz) * 0.5, px - nx, py - ny, pz - nz, 0, 0)
			px, py, pz = nx, ny, nz
		end
	end
end

-- lays every chain straight back from its anchor (at the start)
local function resetChains(headCF)
	local look = headCF.LookVector
	for c = 1, #CHAINS do
		local spec = CHAINS[c]
		local a = headCF * chain.Anchor[c]
		for j = 1, spec.Links do
			local k = chain.First[c] + j - 1
			chain.X[k] = a.X - look.X * spec.Length * j
			chain.Y[k] = a.Y - look.Y * spec.Length * j - 0.3 * j
			chain.Z[k] = a.Z - look.Z * spec.Length * j
		end
	end
end

-- sheds a puff from the tail tuft now and then; live puffs rise, swell and fade (dead ones stay invisible)
local function posePuffs(tailCF, dt)
	S.PuffTimer = S.PuffTimer - dt
	if S.PuffTimer <= 0 then
		S.PuffTimer = PUFF.Every
		local p = S.NextPuff
		S.NextPuff = S.NextPuff % PUFF.Pool + 1
		local src = tailCF * S.TuftV
		local rng = S.Rng
		puff.X[p] = src.X + rng:NextNumber(-1.5, 1.5)
		puff.Y[p] = src.Y + rng:NextNumber(-1, 1)
		puff.Z[p] = src.Z + rng:NextNumber(-1.5, 1.5)
		puff.Rot[p] = CFrame.Angles(0, rng:NextNumber(0, TAU), 0)
		puff.Scale[p] = rng:NextNumber(0.85, 1.2)
		puff.Age[p] = 0
	end
	for p = 1, PUFF.Pool do
		local age = puff.Age[p]
		if age >= 0 then
			age = age + dt
			if age >= PUFF.Life then
				puff.Age[p] = -1
				for k = puff.First[p], puff.Last[p] do
					parts[k].Transparency = 1
				end
			else
				puff.Age[p] = age
				local a = age / PUFF.Life
				local s = puff.Scale[p] * (0.7 + 0.7 * a)
				local alpha = min(age / 0.35, 1) * (1 - a) * (1 - a)
				local cf = CFrame.new(puff.X[p], puff.Y[p] + age * PUFF.Rise, puff.Z[p]) * puff.Rot[p]
				for k = puff.First[p], puff.Last[p] do
					local o = puff.Pos[k]
					cfs[k] = cf * CFrame.new(o.X * s, o.Y * s, o.Z * s)
					local part = parts[k]
					part.Size = puff.Size[k] * s
					part.Transparency = 1 - 0.85 * alpha
				end
			end
		end
	end
end

local function pose(t, dt)
	-- head: aimed along its own trail, with a slow look-around of its own
	local ax, ay, az = trailAt(BODY.HeadLook)
	local headCF = orient(hx, hy, hz, hx - ax, hy - ay, hz - az, htx, htz) * CFrame.Angles(0.07 * sin(t * 0.61), 0.13 * sin(t * 0.37), 0)
	writeGroup(S.HeadFirst, S.HeadLast, headCF)
	-- jaw: a calm breath, opening wider now and then
	local o = sin(t * 0.45)
	local open = 0.08 + 0.05 * sin(t * 1.3)
	if o > 0 then
		open = open + 0.22 * o * o * o
	end
	writeGroup(S.JawFirst, S.JawLast, headCF * S.JawHinge * CFrame.Angles(-open, 0, 0))
	-- body segments along the path history
	local nSeg = #SEGMENTS
	for i = 1, nSeg do
		local cf = frameAt(BODY.HeadGap + (i - 1) * BODY.Spacing)
		seg.CF[i] = cf
		writeGroup(seg.First[i], seg.Last[i], cf)
	end
	-- legs paddle around their shoulder / hip
	for l = 1, #LEGS do
		local spec = LEGS[l]
		local cf = seg.CF[spec.Seg] * leg.Base[l] * CFrame.Angles(LEG.RestPitch + LEG.Swing * sin(t * LEG.Freq + spec.Phase), 0, 0)
		writeGroup(leg.First[l], leg.Last[l], cf)
	end
	-- tail tip with a lazy flick
	local tailCF = frameAt(BODY.HeadGap + (nSeg - 1) * BODY.Spacing + BODY.TailGap) * CFrame.Angles(0.1 * sin(t * 1.1), 0.18 * sin(t * 0.8), 0)
	writeGroup(S.TailFirst, S.TailLast, tailCF)
	poseChains(headCF, t, dt)
	posePuffs(tailCF, dt)
	return headCF
end

local function step(dt)
	local model = S.Model
	if model == nil or model.Parent == nil then
		return -- removed by something else: nothing left to move
	end
	local camera = Workspace.CurrentCamera
	if camera then
		local p = camera.CFrame.Position
		local dx, dy, dz = p.X - ox, p.Y - oy, p.Z - oz
		S.Paused = dx * dx + dy * dy + dz * dz > FAR_SQ
		if S.Paused then
			return
		end
	end
	if type(dt) ~= "number" or dt ~= dt or dt < 0 then
		dt = 0
	elseif dt > MAX_DT then
		dt = MAX_DT
	end
	S.Clock = S.Clock + dt
	advanceHead(S.Clock)
	pose(S.Clock, dt)
	if S.UseBulk then
		Workspace:BulkMoveTo(parts, cfs, S.BulkMode)
	else
		for k = 1, nParts do
			parts[k].CFrame = cfs[k]
		end
	end
end

local function onRenderStep(dt)
	local ok, err = pcall(step, dt)
	if not ok then
		if S.Connection then
			S.Connection:Disconnect()
			S.Connection = nil
		end
		warn(TAG .. "stopped: " .. tostring(err))
	end
end

----------------------------------------------------------------------
-- Building
----------------------------------------------------------------------
-- registers the parts of one piece; offsets are relative to `pivot` (nil = the identity the piece was built at)
local function addParts(list, pivot)
	local inv = nil
	if pivot then
		inv = pivot:Inverse()
	end
	local first = nParts + 1
	for _, part in ipairs(list) do
		nParts = nParts + 1
		parts[nParts] = part
		cfs[nParts] = part.CFrame
		if inv then
			offsets[nParts] = inv * part.CFrame
		else
			offsets[nParts] = part.CFrame
		end
	end
	return first, nParts
end

local function partsOf(model)
	local list = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			list[#list + 1] = d
		end
	end
	return list
end

-- head and jaw (the jaw's offsets are relative to its hinge)
local function buildHead(model)
	local head, headParts = buildPiece(sculptHead(), "Head", BUDGET.Head)
	head.Parent = model
	S.HeadFirst, S.HeadLast = addParts(headParts, nil)
	task.wait()
	S.JawHinge = CFrame.new(JAW_HINGE[1] * VS, JAW_HINGE[2] * VS, JAW_HINGE[3] * VS)
	local jaw, jawParts = buildPiece(sculptJaw(), "Jaw", BUDGET.Jaw)
	jaw.Parent = model
	S.JawFirst, S.JawLast = addParts(jawParts, S.JawHinge)
	task.wait()
end

-- body segments (one sculpt per radius / fin, cloned for the others), legs and the tail tip
local function buildBody(model)
	local templates = {}
	for i, spec in ipairs(SEGMENTS) do
		local key = tostring(spec.R) .. (spec.Fin and "F" or "")
		local piece
		if templates[key] then
			piece = templates[key]:Clone()
		else
			piece = buildPiece(sculptSegment(spec.R, spec.Fin), "Segment", BUDGET.Segment)
			templates[key] = piece
			task.wait()
		end
		piece.Name = string.format("Segment%02d", i)
		piece.Parent = model
		seg.First[i], seg.Last[i] = addParts(partsOf(piece), nil)
		seg.CF[i] = CFrame.new()
	end
	local legTemplate = buildPiece(sculptLeg(), "Leg", BUDGET.Leg)
	for l, spec in ipairs(LEGS) do
		local piece = (l == 1) and legTemplate or legTemplate:Clone()
		piece.Name = "Leg" .. l
		piece.Parent = model
		leg.First[l], leg.Last[l] = addParts(partsOf(piece), nil)
		local r = (SEGMENTS[spec.Seg] and SEGMENTS[spec.Seg].R or 3) * VS
		leg.Base[l] = CFrame.new(spec.Side * r * 0.72, -r * 0.45, 0.4) * CFrame.Angles(0, 0, spec.Side * LEG.Splay)
	end
	task.wait()
	local tail, tailParts = buildPiece(sculptTail(), "Tail", BUDGET.Tail)
	tail.Parent = model
	S.TailFirst, S.TailLast = addParts(tailParts, nil)
	S.TuftV = Vector3.new(PUFF.Point[1] * VS, PUFF.Point[2] * VS, PUFF.Point[3] * VS)
	task.wait()
end

-- block-chain whiskers and mane locks: single blocks, tapering towards the tip, every other one a shade lighter
local function buildChains(model)
	local holder = Instance.new("Model")
	holder.Name = "Chains"
	holder.Parent = model
	for c, spec in ipairs(CHAINS) do
		chain.Anchor[c] = Vector3.new(spec.Anchor[1] * VS, spec.Anchor[2] * VS, spec.Anchor[3] * VS)
		local color = palette[spec.Key]
		if typeof(color) ~= "Color3" then
			color = palette.Mane
		end
		local list = {}
		for j = 1, spec.Links do
			local k = nParts + j
			chain.X[k], chain.Y[k], chain.Z[k] = 0, 0, 0
			local a = (spec.Links > 1) and (j - 1) / (spec.Links - 1) or 0
			local thick = (spec.Thick + (spec.ThickEnd - spec.Thick) * a) * VS
			local shade = color
			if j % 2 == 0 then
				shade = color:Lerp(Color3.new(1, 1, 1), 0.18)
			end
			list[j] = Voxel.Box(holder, CFrame.new(), Vector3.new(thick, thick, (spec.Length + 0.25) * VS), shade, Enum.Material.SmoothPlastic, {
				Name = spec.Key,
				CastShadow = false,
			})
		end
		chain.First[c] = addParts(list, nil)
	end
end

-- the cloud puff pool (invisible until shed)
local function buildPuffs(model)
	local holder = Instance.new("Model")
	holder.Name = "Puffs"
	holder.Parent = model
	local template = buildPiece(sculptPuff(), "Puff", BUDGET.Puff)
	for p = 1, PUFF.Pool do
		local piece = (p == 1) and template or template:Clone()
		piece.Name = "Puff" .. p
		piece.Parent = holder
		local list = partsOf(piece)
		for _, part in ipairs(list) do
			part.Transparency = 1
		end
		puff.First[p], puff.Last[p] = addParts(list, nil)
		for k = puff.First[p], puff.Last[p] do
			puff.Pos[k] = parts[k].Position
			puff.Size[k] = parts[k].Size
		end
		puff.Age[p] = -1
		puff.X[p], puff.Y[p], puff.Z[p] = 0, 0, 0
		puff.Rot[p] = CFrame.new()
		puff.Scale[p] = 1
	end
	task.wait()
end

-- fills the path history so the whole body is already formed, then poses everything once
local function primeFlight()
	local back = (BODY.HeadGap + #SEGMENTS * BODY.Spacing + BODY.TailGap + 20) / max(S.Speed, 1)
	trailCount = 0
	local tt = -back
	while tt < 0 do
		advanceHead(tt)
		tt = tt + 1 / 30
	end
	S.Clock = 0
	advanceHead(0)
	local headCF = pose(0, 0)
	resetChains(headCF)
	poseChains(headCF, 0, 0)
	for k = 1, nParts do
		parts[k].CFrame = cfs[k]
	end
end

local function loadShared(name)
	local shared = ReplicatedStorage:FindFirstChild("Shared") or ReplicatedStorage:WaitForChild("Shared", 10)
	if not shared then
		return nil
	end
	local inst = shared:FindFirstChild(name) or shared:WaitForChild(name, 10)
	if not inst then
		return nil
	end
	local ok, mod = pcall(require, inst)
	if ok and type(mod) == "table" then
		return mod
	end
	return nil
end

local function clientFxFolder()
	local folder = Workspace:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = Workspace
	end
	return folder
end

local function build()
	local Config = loadShared("Config")
	Voxel = loadShared("Voxel")
	local kit = { "NewGrid", "Shape", "Shade", "Build", "Box", "Get", "Set" }
	for _, fn in ipairs(kit) do
		if Voxel and type(Voxel[fn]) ~= "function" then
			Voxel = nil
		end
	end
	if not Voxel then
		warn(TAG .. "shared/Voxel is missing: the Sage Dragon is not built")
		return false
	end
	local lobby = Config and Config.Lobby
	if type(lobby) == "table" and typeof(lobby.Origin) == "Vector3" then
		ox, oy, oz = lobby.Origin.X, lobby.Origin.Y, lobby.Origin.Z
	end
	palette = makePalette()
	S.Rng = Random.new(7071)
	S.BulkMode = Enum.BulkMoveMode.FireCFrameChanged
	setupPath()

	local model = Instance.new("Model")
	model.Name = MODEL_NAME
	buildHead(model)
	buildBody(model)
	buildChains(model)
	buildPuffs(model)
	primeFlight()
	model.Parent = clientFxFolder()
	S.Model = model

	-- BulkMoveTo is the fast path; fall back to plain CFrame writes if it is unavailable
	S.UseBulk = pcall(Workspace.BulkMoveTo, Workspace, parts, cfs, S.BulkMode) and true or false
	return true
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function SkyDragonController.Init()
	if S.Started then
		return
	end
	S.Started = true
	if not RunService:IsClient() then
		return
	end
	task.spawn(function()
		local ok, result = pcall(build)
		if not ok then
			warn(TAG .. "could not build the Sage Dragon: " .. tostring(result))
			if S.Model then
				S.Model:Destroy()
				S.Model = nil
			end
			return
		end
		if result then
			S.Connection = RunService.RenderStepped:Connect(onRenderStep)
		end
	end)
end

function SkyDragonController.GetModel()
	return S.Model
end

function SkyDragonController.IsPaused()
	return S.Paused
end

return SkyDragonController
