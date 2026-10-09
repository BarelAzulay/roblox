-- PetBuilder: every winged pet of Nimbus Climb, sculpted in the detailed fine-voxel style (ARCHITECTURE_V3.md,
-- "ART DIRECTION") with the shared voxel kit (shared/Voxel.lua). Parts only, no meshes, decals or asset ids.
-- Usable on the server, on the client and inside ViewportFrames. Plain Lua 5.1-compatible syntax only.
--
-- API (ARCHITECTURE_V2.md section 2 + ARCHITECTURE_V3.md)
--   PetBuilder.Build(petDef, opts) -> Model   opts: { Scale = 1, Detail = "High" (default) | "Low" }
--                                             High: <= ~350 parts (viewports, podiums, NPCs, own pets)
--                                             Low:  <= ~120 parts (other players' followers, far away)
--   PetBuilder.Animate(model, t, opts)        opts: { Flap = 1 (speed multiplier), Excited = 0..1 }
--   PetBuilder.GetHeight(petDef) -> studs     height of the resting pose at Scale 1
--   Extras: PetBuilder.Species / Accessories / WingStyles (the values Build understands), PetBuilder.ClearCache()
--
-- How a pet is made
--   * Each species is sculpted from shapes (ellipsoids, capsules, curves, cones...) into a voxel grid about 26-30
--     voxels tall (0.1 stud voxels at Scale 1), painted with its patterns (bellies, muzzles, masks, stripes, socks),
--     given a carved face (eye sockets 1 voxel deep holding a dark iris, pupil, white highlights and a darker lid
--     line; blush, nose, mouth), then shaded (lighter tops, darker undersides and creases) and greedily merged into
--     box Parts. Wings (per WingStyle), the tail, a floating Halo and the Secret aura are separate rigid groups so
--     Animate can move them; the right wing is the exact mirror image of the left one.
--   * The pet faces -Z (Roblox LookVector), up is +Y, its right hand is +X. Model.PrimaryPart is "Body", a small
--     invisible part at the pet's centre. Every part is Anchored, CanCollide/CanTouch/CanQuery = false, Massless,
--     CastShadow = false. Names are unique inside a model ("Fur", "Fur2", ..., "WingL", "WingL2", ...).
--   * Animate never uses welds or Motor6D: every animated part stores its resting offset (attribute PB_Base) in
--     its group's hinge frame, and Animate recomputes it from the PrimaryPart's CURRENT CFrame, so the same code
--     works in the workspace and in a ViewportFrame. Clones rebuild their rig from the attributes.
--   * Build results are cached per (pet look, detail, scale): the first build sculpts, later ones Clone().
--   * Unknown Species / WingStyle / Accessory values fall back to Cat / Feather / none.
--   * Rarity flair: Legendary and Mythic pets get a low-rate sparkle emitter; Secret pets get a ring of floating,
--     glowing voxels orbiting them (plus the sparkles).

local PetBuilder = {}

local Voxel = nil
do
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("Voxel", 10))
	end)
	if ok and type(mod) == "table" then
		Voxel = mod
	else
		warn("[PetBuilder] the Voxel kit is unavailable: " .. tostring(mod))
	end
end

PetBuilder.Species = {
	"Cat", "Dog", "Fox", "Bunny", "Bear", "Panda", "Dragon",
	"Owl", "Slime", "Unicorn", "Phoenix", "Frog", "Penguin", "Axolotl",
}
PetBuilder.Accessories = { "Horns", "Crown", "Halo", "Leaf", "Mushroom", "Scarf", "Antlers", "Flower" }
PetBuilder.WingStyles = { "Feather", "Bat", "Fairy", "Cloud", "Crystal", "Flame" }

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local VOXEL = 0.1 -- studs per voxel at Scale 1
local FLAP_HZ = 2.0 -- wing beats per second at Flap = 1 (PetController relies on this number)
local WAG_HZ = 0.9 -- tail wags per second
local SWAY_HZ = 0.55 -- slow idle motions (halo bob, aura orbit)
local BLINK_TIME = 0.16

-- part budgets per group and level of detail (the totals stay under ~350 / ~120)
local BUDGET = {
	High = { Body = 226, Wing = 34, Tail = 22, Halo = 12 },
	Low = { Body = 74, Wing = 10, Tail = 7, Halo = 4 },
}

local PI = math.pi
local TAU = PI * 2
local floor, max, min, abs, sin, cos, sqrt = math.floor, math.max, math.min, math.abs, math.sin, math.cos, math.sqrt

local function clamp(x, lo, hi)
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local function asColor(v, fallback)
	if typeof(v) == "Color3" then
		return v
	end
	return fallback
end

local function mix(a, b, t)
	return a:Lerp(b, t)
end

local function luminance(c)
	return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
end

local WHITE = nil
local BLACK = nil
local NEON = nil
local SMOOTH = nil
local GLASS = nil

local function initConstants()
	if WHITE then
		return
	end
	WHITE = rgb(255, 255, 255)
	BLACK = rgb(0, 0, 0)
	NEON = Enum.Material.Neon
	SMOOTH = Enum.Material.SmoothPlastic
	GLASS = Enum.Material.Glass
end

local function lighten(c, t)
	return c:Lerp(WHITE, t)
end

local function darken(c, t)
	return c:Lerp(BLACK, t)
end

local function hashString(str)
	local h = 5381
	for i = 1, #str do
		h = (h * 33 + string.byte(str, i)) % 2147483647
	end
	return h
end

local function hex(c)
	return string.format("%02x%02x%02x", floor(c.R * 255 + 0.5), floor(c.G * 255 + 0.5), floor(c.B * 255 + 0.5))
end

----------------------------------------------------------------------
-- CFrame <-> string (attributes survive Clone())
----------------------------------------------------------------------
local function cfToString(cf)
	local c = { cf:GetComponents() }
	for i = 1, #c do
		c[i] = string.format("%.5g", c[i])
	end
	return table.concat(c, ",")
end

local function stringToCF(str)
	if type(str) ~= "string" then
		return nil
	end
	local n = {}
	for token in string.gmatch(str, "[^,]+") do
		n[#n + 1] = tonumber(token)
	end
	if #n ~= 12 then
		return nil
	end
	for i = 1, 12 do
		if n[i] == nil then
			return nil
		end
	end
	return CFrame.new(n[1], n[2], n[3], n[4], n[5], n[6], n[7], n[8], n[9], n[10], n[11], n[12])
end

-- Mirror image of a CFrame across the plane x = 0 (as a proper rotation: boxes are symmetric).
local function mirrorCF(cf)
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return CFrame.new(-x, y, z, r00, -r01, -r02, -r10, r11, r12, -r20, r21, r22)
end

----------------------------------------------------------------------
-- Sculpting helpers (all coordinates in voxels; points are {x, y, z})
----------------------------------------------------------------------
local function shape(g, t)
	return Voxel.Shape(g, t)
end

local function ell(g, key, c, r, extra)
	local t = { Kind = "Ellipsoid", Center = c, Radius = r, Key = key }
	if extra then
		for k, v in pairs(extra) do
			t[k] = v
		end
	end
	return Voxel.Shape(g, t)
end

local function cap(g, key, a, b, r, rb, extra)
	local t = { Kind = "Capsule", A = a, B = b, Radius = r, RadiusB = rb, Key = key }
	if extra then
		for k, v in pairs(extra) do
			t[k] = v
		end
	end
	return Voxel.Shape(g, t)
end

local function curve(g, key, pts, r, rb, extra)
	local t = { Kind = "Curve", Points = pts, Radius = r, RadiusB = rb, Key = key }
	if extra then
		for k, v in pairs(extra) do
			t[k] = v
		end
	end
	return Voxel.Shape(g, t)
end

local function paint(g, key, t)
	t.Op = "Paint"
	t.Key = key
	return Voxel.Shape(g, t)
end

local function carve(g, t)
	t.Op = "Carve"
	return Voxel.Shape(g, t)
end

-- calls fn(side) for side = 1 (+X, the pet's right) and -1
local function pair(fn)
	fn(1)
	fn(-1)
end

local function get(g, x, y, z)
	return Voxel.Get(g, x, y, z)
end

local function set(g, x, y, z, key)
	Voxel.Set(g, x, y, z, key)
end

-- z of the frontmost (most -Z) voxel of the column (x, y), or nil
local function frontZ(g, x, y, from, to)
	for z = from or -30, to or 30 do
		if get(g, x, y, z) then
			return z
		end
	end
	return nil
end

-- paints the frontmost voxel of column (x, y) (depth: also the next voxels behind it)
local function paintFront(g, x, y, key, depth)
	local z = frontZ(g, x, y)
	if not z then
		return nil
	end
	for d = 0, (depth or 1) - 1 do
		if get(g, x, y, z + d) then
			set(g, x, y, z + d, key)
		end
	end
	return z
end

-- topmost voxel of column (x, z) scanning down from y0
local function topY(g, x, z, from, to)
	for y = from or 40, to or -30, -1 do
		if get(g, x, y, z) then
			return y
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Look + palette
----------------------------------------------------------------------
local SPECIES = {}
local WINGS = {}
local ACCESSORIES = {}

local function readLook(petDef)
	local src = {}
	if type(petDef) == "table" and type(petDef.Look) == "table" then
		src = petDef.Look
	end
	local species = src.Species
	if type(species) ~= "string" or not SPECIES[species] then
		species = "Cat"
	end
	local wing = src.WingStyle
	if type(wing) ~= "string" or not WINGS[wing] then
		wing = "Feather"
	end
	local acc = src.Accessory
	if type(acc) ~= "string" or not ACCESSORIES[acc] then
		acc = nil
	end
	local primary = asColor(src.Primary, rgb(232, 206, 180))
	local rarity = nil
	local id = "pet"
	if type(petDef) == "table" then
		if type(petDef.Rarity) == "string" then
			rarity = petDef.Rarity
		end
		if petDef.Id ~= nil then
			id = tostring(petDef.Id)
		end
	end
	return {
		Id = id,
		Rarity = rarity,
		Species = species,
		WingStyle = wing,
		Accessory = acc,
		Primary = primary,
		Secondary = asColor(src.Secondary, rgb(250, 238, 222)),
		Eye = asColor(src.Eye, rgb(44, 38, 66)),
		WingColor = asColor(src.WingColor, lighten(primary, 0.4)),
		Glow = src.Glow == true,
	}
end

local function lookSignature(look)
	return table.concat({
		look.Id, tostring(look.Rarity), look.Species, look.WingStyle, tostring(look.Accessory), hex(look.Primary),
		hex(look.Secondary), hex(look.Eye), hex(look.WingColor), tostring(look.Glow),
	}, "|")
end

-- Keys that are never shaded (flat accents) and never recoloured by the LOD.
local FLAT_KEYS = {
	"EyeIris", "EyePupil", "EyeShine", "EyeGlint", "Lash", "Nose", "Mouth", "Blush", "Nostril", "Tongue", "Gem",
	"Glow", "Spark",
}

local function makePalette(look)
	local P, S, E, W = look.Primary, look.Secondary, look.Eye, look.WingColor
	local dark = luminance(P) < 0.3
	local glowE = look.Glow
	local brightEye = luminance(E) > 0.45
	local pal = {
		Fur = P,
		Accent = S,
		Belly = mix(S, rgb(255, 248, 236), 0.35),
		Muzzle = mix(P, rgb(255, 250, 240), 0.55),
		Stripe = darken(P, 0.28),
		Inner = mix(rgb(246, 160, 172), P, 0.2),
		Pad = rgb(240, 150, 166),
		Nose = mix(rgb(226, 120, 138), P, 0.12),
		Mouth = dark and mix(S, WHITE, 0.25) or darken(mix(P, rgb(110, 50, 60), 0.6), 0.45),
		Blush = mix(rgb(255, 128, 156), P, 0.28),
		Lash = dark and mix(S, WHITE, 0.15) or darken(mix(P, E, 0.5), 0.72),
		Claw = rgb(250, 240, 222),
		Horn = rgb(244, 192, 72),
		Gold = rgb(244, 192, 72),
		Wing = W,
		WingTrim = darken(W, 0.22),
		WingEdge = lighten(W, 0.35),
		Tongue = rgb(236, 112, 128),
		Nostril = darken(P, 0.6),
		Gem = rgb(232, 72, 104),
		Spark = rgb(255, 250, 230),
	}
	-- eyes: a dark iris (or a glowing one), darker pupil, white highlights
	if brightEye then
		pal.EyeIris = E
		pal.EyePupil = darken(E, 0.62)
		pal.EyeGlint = lighten(E, 0.45)
	else
		pal.EyeIris = E
		pal.EyePupil = darken(E, 0.55)
		pal.EyeGlint = lighten(E, 0.32)
	end
	pal.EyeShine = rgb(252, 252, 255)
	if glowE then
		pal.EyeIris = { Color = pal.EyeIris, Material = NEON }
		pal.EyeGlint = { Color = pal.EyeGlint, Material = NEON }
		pal.WingEdge = { Color = lighten(W, 0.4), Material = NEON }
	end
	return pal
end

----------------------------------------------------------------------
-- Build context
----------------------------------------------------------------------
local function newContext(look, detail)
	local ctx = {
		Look = look,
		Detail = detail,
		High = detail ~= "Low",
		Body = Voxel.NewGrid(30),
		Wing = Voxel.NewGrid(30), -- the LEFT wing, in hinge-local voxels (the wing reaches towards -X)
		Tail = nil, -- optional grid in tail-hinge-local voxels (the tail reaches towards +Z)
		Halo = nil, -- optional grid around the halo centre (bobs)
		Pal = makePalette(look),
		Eyes = {}, -- { X0, Y0, Mask = {rows top -> bottom}, Z = optional depth hint }
		WingHinge = { 4.5, 0, 4 }, -- left hinge mirrored from this (right side, +X)
		WingTilt = 0.35, -- radians the resting wing is raised
		WingSweep = 0.45, -- radians the resting wing is swept back
		WingScale = 1,
		TailHinge = { 0, -8, 6 },
		TailWag = 0.32, -- radians each side
		HeadTop = 14, -- y of the top of the head (accessories sit here)
		HeadZ = -0.5, -- z of the head centre
		HeadR = { 8.5, 7.5, 7.5 },
		HeadC = { 0, 6, -0.5 },
		NoShade = {},
		Keep = {},
	}
	for _, k in ipairs(FLAT_KEYS) do
		ctx.NoShade[k] = true
		ctx.Keep[k] = true
	end
	return ctx
end

----------------------------------------------------------------------
-- Faces: carved eyes, lids, blush, mouths
----------------------------------------------------------------------
-- Eye masks, rows from top to bottom, columns in +X order (the highlight sits on the viewer's upper left,
-- which is the pet's +X side, on both eyes: one light source).
--   L lid / lash line   I iris   P pupil   S highlight   s small highlight   G lower glint   . no eye
local EYE_MASKS = {
	High = {
		". L L .",
		"L I S S",
		"I P S S",
		"I P P I",
		"s G G I",
		". I I .",
	},
	Low = {
		". L L .",
		"L P S S",
		"I P P I",
		". I I .",
	},
	-- round, slightly smaller eyes (owls get big ones from their own species code)
	Small = {
		"L L L",
		"I P S",
		"I P P",
		". I .",
	},
}
local EYE_KEYS = { L = "Lash", I = "EyeIris", P = "EyePupil", S = "EyeShine", s = "EyeShine", G = "EyeGlint" }

local function parseMask(mask)
	local rows = {}
	for r, line in ipairs(mask) do
		local cols = {}
		for ch in string.gmatch(line, "%S") do
			cols[#cols + 1] = ch
		end
		rows[r] = cols
	end
	return rows
end

-- Adds a pair of eyes: the right eye's columns start at x0 (pet's right, +X), the left eye is its mirror image in
-- position (the mask itself is not mirrored, so both highlights face the same light). yTop = row of the top line.
local function addEyes(ctx, x0, yTop, maskName, opts)
	local mask = parseMask(EYE_MASKS[maskName] or EYE_MASKS.High)
	local w = #mask[1]
	opts = opts or {}
	ctx.Eyes[#ctx.Eyes + 1] = { X0 = x0, Y = yTop, Mask = mask, W = w, Lid = opts.Lid ~= false }
	ctx.Eyes[#ctx.Eyes + 1] = { X0 = -(x0 + w - 1), Y = yTop, Mask = mask, W = w, Lid = opts.Lid ~= false }
end

-- Carves every eye 1 voxel into the face: the frontmost voxel of each eye column is removed and the voxel behind
-- it takes the eye colour, so the eye follows the curve of the head and sits INSIDE it. The removed voxels become
-- the blink lids (an extra group, invisible until a blink).
local function carveEyes(ctx)
	local g = ctx.Body
	ctx.LidCells = {}
	for _, eye in ipairs(ctx.Eyes) do
		local lid = {}
		for r, cols in ipairs(eye.Mask) do
			local y = eye.Y - (r - 1)
			for c, ch in ipairs(cols) do
				local key = EYE_KEYS[ch]
				if key then
					local x = eye.X0 + c - 1
					local z = frontZ(g, x, y)
					if z then
						set(g, x, y, z, nil)
						if not get(g, x, y, z + 1) then
							set(g, x, y, z + 1, "Fur")
						end
						set(g, x, y, z + 1, key)
						-- the closed lid: fur, with a dark lash line on the middle row
						local lidKey = "Lid"
						if r == floor(#eye.Mask / 2) + 1 then
							lidKey = "LidLine"
						end
						lid[#lid + 1] = { x, y, z, lidKey }
					end
				end
			end
		end
		if eye.Lid then
			ctx.LidCells[#ctx.LidCells + 1] = lid
		end
	end
end

-- Paints cells on the frontmost surface (list of {x, y, key}).
local function paintFace(ctx, cells)
	for _, c in ipairs(cells) do
		paintFront(ctx.Body, c[1], c[2], c[3])
	end
end

-- Blush: a short pink oval on each cheek (front surface).
local function blush(ctx, x0, y, w)
	w = w or 3
	for i = 0, w - 1 do
		paintFront(ctx.Body, x0 + i, y, "Blush")
		paintFront(ctx.Body, -(x0 + i), y, "Blush")
	end
	if ctx.High and w >= 3 then
		for i = 1, w - 2 do
			paintFront(ctx.Body, x0 + i, y - 1, "Blush")
			paintFront(ctx.Body, -(x0 + i), y - 1, "Blush")
		end
	end
end

-- Mouth shapes painted on the front surface around x = 0. y = row just under the nose.
local function catMouth(ctx, y)
	paintFace(ctx, {
		{ 0, y, "Mouth" }, { -1, y - 1, "Mouth" }, { 1, y - 1, "Mouth" }, { -2, y - 1, "Mouth" }, { 2, y - 1, "Mouth" },
	})
	if ctx.High then
		paintFace(ctx, { { -3, y, "Mouth" }, { 3, y, "Mouth" } })
	end
end

local function smileMouth(ctx, y, w)
	w = w or 2
	local cells = {}
	for i = -w + 1, w - 1 do
		cells[#cells + 1] = { i, y - 1, "Mouth" }
	end
	cells[#cells + 1] = { -w, y, "Mouth" }
	cells[#cells + 1] = { w, y, "Mouth" }
	paintFace(ctx, cells)
end

----------------------------------------------------------------------
-- Shared body parts
----------------------------------------------------------------------
-- A rounded chibi body sitting upright with tucked paws. b = { c = centre, r = radii }.
local function sittingBody(ctx, key, c, r)
	ell(ctx.Body, key, c, r)
end

-- Four short legs: front paws hang under the chest, hind legs are chunky thighs with feet.
local function legs(ctx, key, opts)
	local g = ctx.Body
	opts = opts or {}
	local fx, fy, fz = opts.FrontX or 3, opts.FrontY or -6.5, opts.FrontZ or -2.5
	local foot = opts.FootY or -11
	local hx, hz = opts.HindX or 4.2, opts.HindZ or 2.5
	pair(function(s)
		-- front leg: tapered capsule down to a round paw
		cap(g, key, { s * fx, fy, fz }, { s * fx, foot + 1, fz - 0.6 }, opts.FrontR or 1.7, opts.PawR or 1.5)
		ell(g, opts.PawKey or key, { s * fx, foot + 0.6, fz - 1 }, { 1.7, 1.2, 1.9 })
		-- hind thigh + foot
		ell(g, key, { s * hx, foot + 3.2, hz }, { 2.6, 3, 3.2 })
		ell(g, opts.PawKey or key, { s * (hx + 0.2), foot + 0.6, hz - 1.6 }, { 1.8, 1.2, 2.2 })
		if ctx.High and opts.Toes ~= false then
			-- toe lines (darker creases) on the front paws
			local z = frontZ(g, s * fx, foot + 0)
			if z then
				set(g, s * fx - 1, foot + 0, z, "Lash")
				set(g, s * fx + 1, foot + 0, z, "Lash")
			end
		end
	end)
end

----------------------------------------------------------------------
-- Species
----------------------------------------------------------------------
SPECIES.Cat = function(ctx)
	local g = ctx.Body
	local H = ctx.High
	-- body + head
	sittingBody(ctx, "Fur", { 0, -4.5, 1.5 }, { 5.8, 6.2, 6.4 })
	ell(g, "Fur", { 0, 6, -0.5 }, { 8.6, 7.2, 7.4 })
	-- cheeks: a soft fluffy jowl on each side
	pair(function(s)
		ell(g, "Fur", { s * 5.6, 3.2, -3.2 }, { 3.6, 2.8, 3.6 })
	end)
	-- muzzle and chin (lighter)
	ell(g, "Muzzle", { 0, 2.8, -6.4 }, { 3.6, 2.4, 2.2 })
	paint(g, "Muzzle", { Kind = "Ellipsoid", Center = { 0, 1.6, -5.5 }, Radius = { 3.4, 2.2, 3 }, OnlyKeys = "Fur" })
	-- ears: tall triangles with a hollow, pink inner ear
	pair(function(s)
		shape(g, { Kind = "Cone", A = { s * 5, 11, -0.5 }, B = { s * 6.8, 18.2, 0.2 }, Radius = 3.3, RadiusB = 0.3, Key = "Fur" })
		paint(g, "Inner", { Kind = "Cone", A = { s * 5.1, 11.6, -1.6 }, B = { s * 6.6, 16.4, -0.8 }, Radius = 2, RadiusB = 0.2, OnlyKeys = "Fur" })
		carve(g, { Kind = "Cone", A = { s * 5.1, 11.8, -3.4 }, B = { s * 6.6, 16.2, -2.4 }, Radius = 1.6, RadiusB = 0.1, OnlyKeys = { Fur = true, Inner = true } })
	end)
	-- belly + chest fluff
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -4, -4.5 }, Radius = { 3.8, 5, 3.2 }, OnlyKeys = "Fur" })
	legs(ctx, "Fur", { PawKey = "Belly" })
	-- tabby stripes on the head and back (the Accent colour)
	if H then
		paint(g, "Stripe", {
			Kind = "Box", Center = { 0, 12.5, -2 }, Size = { 1, 3, 9 }, OnlyKeys = "Fur",
		})
		pair(function(s)
			paint(g, "Stripe", { Kind = "Box", Center = { s * 2.5, 12, -2 }, Size = { 1, 2, 8 }, OnlyKeys = "Fur" })
			for i = 0, 2 do
				paint(g, "Stripe", {
					Kind = "Capsule", A = { s * 6, -1 - i * 3, 3 }, B = { s * 3, 1.6 - i * 3, 6 }, Radius = 0.6, OnlyKeys = "Fur",
				})
			end
		end)
	end
	-- face
	addEyes(ctx, 2, 8, H and "High" or "Low")
	paintFace(ctx, { { 0, 4, "Nose" }, { -1, 4, "Nose" }, { 1, 4, "Nose" }, { 0, 3, "Nose" } })
	catMouth(ctx, 2)
	blush(ctx, 5, 3, 3)
	-- tail: long, curling up at the end, darker rings
	ctx.TailHinge = { 0, -8.5, 6.5 }
	local t = Voxel.NewGrid(30)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, 1, 4 }, { 1, 5, 7 }, { 1, 10, 7.5 }, { 0, 13, 5.5 } }, 1.5, 1.1)
	if H then
		for i = 1, 3 do
			paint(t, "Stripe", { Kind = "Box", Center = { 0, 2 + i * 3.2, 6.5 }, Size = { 6, 1, 6 }, OnlyKeys = "Fur" })
		end
	end
	ctx.Tail = t
	ctx.HeadTop = 13.5
end

----------------------------------------------------------------------
-- Wings (sculpted in hinge-local voxels: the LEFT wing reaches towards -X, up is +Y, back is +Z)
----------------------------------------------------------------------
WINGS.Feather = function(ctx, w)
	-- covert feathers (top, rounded) + long primaries fanning out
	ell(w, "WingEdge", { -5, 3.5, 0 }, { 5.5, 2.6, 0.8 })
	local tips = { { -13, 6.5 }, { -13.5, 3 }, { -12.5, -0.5 }, { -10.5, -3 }, { -7.5, -4.5 } }
	for i, tp in ipairs(tips) do
		local key = (i % 2 == 0) and "WingTrim" or "Wing"
		cap(w, key, { -2.5, 2, 0 }, { tp[1], tp[2], 0.6 }, 1.5, 1.1)
	end
	paint(w, "WingEdge", { Kind = "Ellipsoid", Center = { -4.5, 3.6, 0 }, Radius = { 5, 2.2, 2 } })
	ctx.Pal.Wing = ctx.Pal.Wing
end

----------------------------------------------------------------------
-- Accessories (sculpted into the body grid)
----------------------------------------------------------------------
ACCESSORIES.Horns = function(ctx)
	local g = ctx.Body
	local top = ctx.HeadTop
	pair(function(s)
		curve(g, "Horn", { { s * 3, top - 2.5, -1 }, { s * 4, top + 1, -0.2 }, { s * 5.5, top + 3, 0.8 }, { s * 7, top + 3.4, 2.2 } }, 1.4, 0.5)
	end)
end

----------------------------------------------------------------------
-- Blueprint: sculpt -> shade -> merge (cached per look + detail)
----------------------------------------------------------------------
local blueprints = {}

local function mergeGroup(ctx, grid, budget, extraKeep)
	local keep = ctx.Keep
	if extraKeep then
		keep = {}
		for k in pairs(ctx.Keep) do
			keep[k] = true
		end
		for k in pairs(extraKeep) do
			keep[k] = true
		end
	end
	return Voxel.Merge(grid, { Palette = ctx.Pal, MaxParts = budget, Keep = keep })
end

local function buildBlueprint(look, detail)
	local ctx = newContext(look, detail)
	local budget = BUDGET[detail] or BUDGET.High
	SPECIES[look.Species](ctx)
	if look.Accessory then
		ACCESSORIES[look.Accessory](ctx)
	end
	carveEyes(ctx)
	Voxel.Shade(ctx.Body, { Skip = ctx.NoShade })
	WINGS[look.WingStyle](ctx, ctx.Wing)
	Voxel.Shade(ctx.Wing, { Skip = ctx.NoShade, LightAt = 0.5 })

	local bp = { Groups = {}, Pal = ctx.Pal, Look = look, Detail = detail }
	bp.Groups[#bp.Groups + 1] = { Name = "Body", Boxes = mergeGroup(ctx, ctx.Body, budget.Body) }

	-- wings: left from the grid, right = exact mirror image
	local wh = ctx.WingHinge
	local hingeR = CFrame.new(wh[1], wh[2], wh[3]) * CFrame.Angles(0, -ctx.WingSweep, 0) * CFrame.Angles(0, 0, ctx.WingTilt)
	local hingeL = mirrorCF(hingeR)
	local wingBoxes = mergeGroup(ctx, ctx.Wing, budget.Wing)
	bp.Groups[#bp.Groups + 1] = { Name = "WingL", Boxes = wingBoxes, Hinge = hingeL, Kind = "wing", Side = 1 }
	bp.Groups[#bp.Groups + 1] = { Name = "WingR", Boxes = Voxel.MirrorBoxes(wingBoxes), Hinge = hingeR, Kind = "wing", Side = -1 }

	if ctx.Tail then
		Voxel.Shade(ctx.Tail, { Skip = ctx.NoShade })
		local th = ctx.TailHinge
		bp.Groups[#bp.Groups + 1] = {
			Name = "Tail", Boxes = mergeGroup(ctx, ctx.Tail, budget.Tail),
			Hinge = CFrame.new(th[1], th[2], th[3]), Kind = "tail", Amp = ctx.TailWag,
		}
	end
	-- blink lids: one small group per eye, hidden until a blink
	if ctx.LidCells then
		for i, cells in ipairs(ctx.LidCells) do
			local lg = Voxel.NewGrid(30)
			for _, c in ipairs(cells) do
				set(lg, c[1], c[2], c[3], c[4])
			end
			bp.Groups[#bp.Groups + 1] = { Name = "EyeLid", Boxes = Voxel.Merge(lg, { Palette = ctx.Pal }), Kind = "lid", Index = i }
		end
	end
	return bp
end

local function getBlueprint(look, detail)
	local key = lookSignature(look) .. "|" .. detail
	local bp = blueprints[key]
	if not bp then
		bp = buildBlueprint(look, detail)
		blueprints[key] = bp
	end
	return bp, key
end

----------------------------------------------------------------------
-- Instancing
----------------------------------------------------------------------
local function flagPart(part)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CastShadow = false
end

-- order: base colours before their shades, bigger boxes first (the first part of a name gets the bare name)
local function sortBoxes(boxes)
	local list = {}
	for i, b in ipairs(boxes) do
		list[i] = b
	end
	table.sort(list, function(a, b)
		local ab, av = Voxel.BaseKey(a.Key)
		local bb, bv = Voxel.BaseKey(b.Key)
		if (av ~= nil) ~= (bv ~= nil) then
			return av == nil
		end
		local va = (a.X1 - a.X0 + 1) * (a.Y1 - a.Y0 + 1) * (a.Z1 - a.Z0 + 1)
		local vb = (b.X1 - b.X0 + 1) * (b.Y1 - b.Y0 + 1) * (b.Z1 - b.Z0 + 1)
		if va ~= vb then
			return va > vb
		end
		if ab ~= bb then
			return tostring(ab) < tostring(bb)
		end
		if a.Y0 ~= b.Y0 then
			return a.Y0 < b.Y0
		end
		if a.X0 ~= b.X0 then
			return a.X0 < b.X0
		end
		return a.Z0 < b.Z0
	end)
	return list
end

local function groupSpec(gr)
	return table.concat({ gr.Name, gr.Kind or "static", tostring(gr.Side or 1), tostring(gr.Amp or 0), tostring(gr.Index or 0) }, ":")
end

local function instantiate(bp, scale)
	local model = Instance.new("Model")
	model.Name = "Pet_" .. bp.Look.Id
	local vs = VOXEL * scale
	local used = {}
	local function uniqueName(name)
		local c = (used[name] or 0) + 1
		used[name] = c
		if c > 1 then
			return name .. c
		end
		return name
	end
	-- the invisible root at the pet's centre
	local root = Instance.new("Part")
	root.Name = uniqueName("Body")
	flagPart(root)
	root.Transparency = 1
	root.Size = Vector3.new(0.2, 0.2, 0.2) * scale
	root.CFrame = CFrame.new()
	root.Parent = model
	model.PrimaryPart = root

	local specs = {}
	for _, gr in ipairs(bp.Groups) do
		local boxes = sortBoxes(gr.Boxes)
		local hinge = nil
		if gr.Hinge then
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = gr.Hinge:GetComponents()
			hinge = CFrame.new(x * vs, y * vs, z * vs, r00, r01, r02, r10, r11, r12, r20, r21, r22)
		end
		local _, parts = Voxel.BuildBoxes(boxes, {
			VoxelSize = vs,
			Palette = bp.Pal,
			CFrame = hinge or CFrame.new(),
			Model = model,
			CastShadow = false,
		})
		local animated = gr.Kind ~= nil and gr.Kind ~= "static"
		for i, part in ipairs(parts) do
			local b = boxes[i]
			local base = Voxel.BaseKey(b.Key)
			local name
			if gr.Name == "Body" then
				name = base
			elseif gr.Name == "Tail" then
				name = "Tail"
			else
				name = gr.Name
			end
			part.Name = uniqueName(name)
			flagPart(part)
			if animated then
				part:SetAttribute("PB_G", groupSpec(gr))
				local rel = hinge and hinge:ToObjectSpace(part.CFrame) or part.CFrame
				part:SetAttribute("PB_Base", cfToString(rel))
				if gr.Kind == "lid" then
					part:SetAttribute("PB_T0", part.Transparency)
					part.Transparency = 1
				end
			end
		end
		if gr.Hinge then
			specs[#specs + 1] = groupSpec(gr) .. "=" .. cfToString(hinge)
		end
	end
	model:SetAttribute("PB_Rig", table.concat(specs, ";"))
	model:SetAttribute("PB_Scale", scale)
	model:SetAttribute("PetId", bp.Look.Id)
	model:SetAttribute("PB_Seed", hashString(bp.Look.Id .. bp.Look.Species))
	return model
end

----------------------------------------------------------------------
-- Rig (animation state per model, rebuilt from attributes for clones)
----------------------------------------------------------------------
local rigs = setmetatable({}, { __mode = "k" })

local function parseGroup(spec)
	local f = {}
	for token in string.gmatch(spec, "[^:]+") do
		f[#f + 1] = token
	end
	return { Name = f[1], Kind = f[2] or "static", Side = tonumber(f[3]) or 1, Amp = tonumber(f[4]) or 0, Index = tonumber(f[5]) or 0 }
end

local function buildRig(model)
	local groups = {}
	local byKey = {}
	local rigAttr = model:GetAttribute("PB_Rig")
	if type(rigAttr) == "string" then
		for entry in string.gmatch(rigAttr, "[^;]+") do
			local spec, cf = string.match(entry, "^(.-)=(.*)$")
			if spec then
				local gr = parseGroup(spec)
				gr.Hinge = stringToCF(cf) or CFrame.new()
				gr.Parts, gr.Base = {}, {}
				groups[#groups + 1] = gr
				byKey[spec] = gr
			end
		end
	end
	local lids = {}
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			local spec = part:GetAttribute("PB_G")
			if type(spec) == "string" then
				local gr = byKey[spec]
				if not gr then
					gr = parseGroup(spec)
					gr.Hinge = CFrame.new()
					gr.Parts, gr.Base = {}, {}
					groups[#groups + 1] = gr
					byKey[spec] = gr
				end
				local base = stringToCF(part:GetAttribute("PB_Base"))
				if base then
					gr.Parts[#gr.Parts + 1] = part
					gr.Base[#gr.Base + 1] = base
				end
			end
		end
	end
	local moving = {}
	for _, gr in ipairs(groups) do
		if gr.Kind == "lid" then
			for _, p in ipairs(gr.Parts) do
				lids[#lids + 1] = { Part = p, T0 = tonumber(p:GetAttribute("PB_T0")) or 0 }
			end
		elseif #gr.Parts > 0 then
			moving[#moving + 1] = gr
		end
	end
	local seed = model:GetAttribute("PB_Seed")
	if type(seed) ~= "number" then
		seed = 1
	end
	return {
		Groups = moving,
		Lids = lids,
		Blinking = false,
		St = { Flap = 0, Wag = 0, Sway = 0, Excite = 0 },
		Offset = (seed % 628) / 100,
		BlinkPeriod = 3.1 + (seed % 17) * 0.13,
		BlinkOffset = (seed % 29) * 0.11,
		LastT = nil,
	}
end

local function getRig(model)
	local rig = rigs[model]
	if rig then
		return rig
	end
	if rig == false then
		return nil
	end
	local ok, built = pcall(buildRig, model)
	if ok and built then
		rigs[model] = built
		return built
	end
	rigs[model] = false
	return nil
end

-- clocks are accumulated (not t * speed) so changing Flap / Excited never makes a wing jump
local function advance(rig, t, flapMul, excited)
	local st = rig.St
	local first = rig.LastT == nil
	local dt = 0
	if not first then
		dt = clamp(t - rig.LastT, 0, 0.1)
	end
	rig.LastT = t
	if first then
		st.Excite = excited
	else
		st.Excite = st.Excite + (excited - st.Excite) * (1 - math.exp(-dt * 8))
	end
	local ex = st.Excite
	local flapRate = TAU * FLAP_HZ * flapMul * (1 + 1.25 * ex)
	local wagRate = TAU * WAG_HZ * (1 + 1.6 * ex)
	local swayRate = TAU * SWAY_HZ
	if first then
		st.Flap = t * flapRate + rig.Offset
		st.Wag = t * wagRate + rig.Offset * 0.7
		st.Sway = t * swayRate + rig.Offset * 0.5
	else
		st.Flap = st.Flap + dt * flapRate
		st.Wag = st.Wag + dt * wagRate
		st.Sway = st.Sway + dt * swayRate
	end
end

local FLAP_AMP = math.rad(35)

-- motion of one group in its hinge frame
local function groupMotion(gr, st)
	local kind = gr.Kind
	if kind == "wing" then
		local a = FLAP_AMP * (1 + 0.15 * st.Excite) * sin(st.Flap)
		local sweep = 0.12 * sin(st.Flap - 1.2)
		return CFrame.Angles(0, sweep * gr.Side, a * gr.Side)
	elseif kind == "tail" then
		local a = gr.Amp * (1 + 0.5 * st.Excite) * sin(st.Wag)
		return CFrame.Angles(0.05 * sin(st.Wag * 0.5), a, 0)
	elseif kind == "bob" then
		return CFrame.new(0, gr.Amp * sin(st.Sway * 1.6), 0) * CFrame.Angles(0, st.Sway * 0.35, 0)
	elseif kind == "orbit" then
		return CFrame.new(0, gr.Amp * sin(st.Sway * 1.3), 0) * CFrame.Angles(0, st.Sway * 0.8, 0)
	end
	return CFrame.new()
end

local function updateBlink(rig, t)
	local lids = rig.Lids
	if #lids == 0 then
		return
	end
	local u = (t + rig.BlinkOffset) % rig.BlinkPeriod
	local closed = u < BLINK_TIME
	if closed == rig.Blinking then
		return
	end
	rig.Blinking = closed
	for i = 1, #lids do
		local l = lids[i]
		if l.Part.Parent then
			l.Part.Transparency = closed and l.T0 or 1
		end
	end
end

----------------------------------------------------------------------
-- Templates (one per look + detail + scale; Build hands out clones)
----------------------------------------------------------------------
local templates = {}
local templateOrder = {}
local MAX_TEMPLATES = 40

local function getTemplate(bp, bpKey, scale)
	local key = bpKey .. "|" .. string.format("%.4f", scale)
	local tpl = templates[key]
	if tpl then
		return tpl
	end
	tpl = instantiate(bp, scale)
	templates[key] = tpl
	templateOrder[#templateOrder + 1] = key
	if #templateOrder > MAX_TEMPLATES then
		local old = table.remove(templateOrder, 1)
		local m = templates[old]
		templates[old] = nil
		if m then
			pcall(m.Destroy, m)
		end
	end
	return tpl
end

function PetBuilder.ClearCache()
	for _, m in pairs(templates) do
		pcall(m.Destroy, m)
	end
	templates = {}
	templateOrder = {}
	blueprints = {}
end

----------------------------------------------------------------------
-- Rarity flair
----------------------------------------------------------------------
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local function addSparkles(model, look, rate)
	local root = model.PrimaryPart
	if not root then
		return
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "RaritySparkles"
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(lighten(look.WingColor, 0.5), lighten(look.Primary, 0.3))
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Rate = rate
	emitter.Lifetime = NumberRange.new(0.8, 1.5)
	emitter.Speed = NumberRange.new(0.3, 1.1)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.4, 0.22),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = root
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function PetBuilder.Build(petDef, opts)
	initConstants()
	if not Voxel then
		error("PetBuilder needs shared/Voxel")
	end
	opts = type(opts) == "table" and opts or {}
	local scale = clamp(tonumber(opts.Scale) or 1, 0.05, 40)
	local detail = (opts.Detail == "Low") and "Low" or "High"
	local look = readLook(petDef)
	local bp, bpKey = getBlueprint(look, detail)
	local tpl = getTemplate(bp, bpKey, scale)
	local model = tpl:Clone()
	model.PrimaryPart = model:FindFirstChild("Body")
	if look.Rarity == "Legendary" or look.Rarity == "Mythic" then
		addSparkles(model, look, detail == "Low" and 3 or 5)
	elseif look.Rarity == "Secret" then
		addSparkles(model, look, detail == "Low" and 3 or 4)
	end
	return model
end

function PetBuilder.Animate(model, t, opts)
	if typeof(model) ~= "Instance" then
		return
	end
	local rig = getRig(model)
	if not rig then
		return
	end
	local root = model.PrimaryPart or model:FindFirstChild("Body")
	if not root or not root:IsA("BasePart") then
		return
	end
	if type(t) ~= "number" then
		t = os.clock()
	end
	local flapMul, excited = 1, 0
	if type(opts) == "table" then
		if type(opts.Flap) == "number" then
			flapMul = clamp(opts.Flap, 0, 8)
		end
		if type(opts.Excited) == "number" then
			excited = clamp(opts.Excited, 0, 1)
		end
	end
	advance(rig, t, flapMul, excited)
	local base = root.CFrame
	local st = rig.St
	local groups = rig.Groups
	for i = 1, #groups do
		local gr = groups[i]
		local cur = base * gr.Hinge * groupMotion(gr, st)
		local parts, bases = gr.Parts, gr.Base
		for j = 1, #parts do
			parts[j].CFrame = cur * bases[j]
		end
	end
	updateBlink(rig, t)
end

-- Height of the resting pose (studs, Scale 1), measured once per look from the High build.
local heightCache = {}
local DEFAULT_HEIGHT = 2.7

function PetBuilder.GetHeight(petDef)
	initConstants()
	if not Voxel then
		return DEFAULT_HEIGHT
	end
	local look = readLook(petDef)
	local key = lookSignature(look)
	local cached = heightCache[key]
	if cached then
		return cached
	end
	local h = DEFAULT_HEIGHT
	local ok, model = pcall(PetBuilder.Build, petDef, { Scale = 1 })
	if ok and model then
		local lo, hi = math.huge, -math.huge
		for _, inst in ipairs(model:GetDescendants()) do
			if inst:IsA("BasePart") then
				local _, y, _, _, _, _, r10, r11, r12 = inst.CFrame:GetComponents()
				local half = (abs(r10) * inst.Size.X + abs(r11) * inst.Size.Y + abs(r12) * inst.Size.Z) / 2
				if y - half < lo then
					lo = y - half
				end
				if y + half > hi then
					hi = y + half
				end
			end
		end
		if hi > lo then
			h = hi - lo
		end
		model:Destroy()
	end
	heightCache[key] = h
	return h
end

return PetBuilder
