-- PetBuilder: every winged pet of Nimbus Climb, sculpted in the detailed fine-voxel style (ARCHITECTURE_V3.md,
-- "ART DIRECTION") with the shared voxel kit (shared/Voxel.lua). Parts only, no meshes, decals or asset ids.
-- Usable on the server, on the client and inside ViewportFrames. Plain Lua 5.1-compatible syntax only.
--
-- API (ARCHITECTURE_V2.md section 2 + ARCHITECTURE_V3.md)
--   PetBuilder.Build(petDef, opts) -> Model   opts: { Scale = 1, Detail = "High" (default) | "Low", Evolved = false }
--                                             Evolved = true (or 1): the pet's evolved form (bigger, four-legged, fan
--                                             wings, gold jewellery; see "Evolved forms" below): High <= ~1560 parts,
--                                             Low <= ~380. Evolved = 2: the second evolution, Epic pets and up only
--                                             (others get their first one; see "Second evolution"): High <= ~2000
--                                             parts, Low <= ~520
--   PetBuilder.MaxEvolution(petDef) -> 1 | 2  how far the pet can evolve (2 for Epic, Legendary, Mythic, Secret)
--   PetBuilder.EvolutionColors(petDef, stage) -> Color3, Color3   the glow colours of an evolution into `stage`
--                                             (gold + the evolved form's gem; the second evolution's two neon accents)
--                                             High: <= ~350 parts (viewports, podiums, NPCs, your own pets)
--                                             Low:  <= ~120 parts (other players' followers, far away)
--   PetBuilder.Animate(model, t, opts)        opts: { Flap = 1 (speed multiplier), Excited = 0..1 }
--   PetBuilder.GetHeight(petDef) -> studs     height of the resting pose at Scale 1
--   Extras: PetBuilder.Species / Accessories / WingStyles (the values Build understands), PetBuilder.ClearCache()
--
-- How a pet is made
--   * Each species is sculpted from shapes (ellipsoids, capsules, cones, curves...) into a voxel grid about 28
--     voxels tall (0.1 stud voxels at Scale 1), painted with its patterns (bellies, muzzles, masks, stripes,
--     socks, spots), given a carved face (eye sockets 1 voxel deep holding a dark iris, pupil, white highlights
--     and a lower glint; nose, mouth, blush), shaded (lighter tops, darker undersides and creases) and greedily
--     merged into box Parts. Low detail sculpts the very same shapes at half the resolution. Part budgets are
--     enforced per group and in total (the body gives up its patchiest shading first); a rare heavy combination
--     (big wings + bushy tail + accessory + aura) is re-sculpted without the optional small details.
--   * Species: Cat, Dog, Fox, Bunny, Bear, Panda, Dragon (the Cloudy Dragon mascot follows branding/icon-512.png),
--     Owl, Slime, Unicorn, Phoenix, Frog, Penguin, Axolotl and Stormfang (the player's own armoured storm lynx,
--     ARCHITECTURE_V3.md section 10; it rides a storm cloud: WingStyle "StormCloud", whose halves are WingL / WingR
--     and sway gently; its neon accents pulse softly while animated).
--   * Wings (per WingStyle), the tail, a floating Halo and the Secret aura are separate rigid groups that Animate
--     moves; the right wing is the exact mirror image of the left one. Eyes blink (hidden lid parts).
--   * The pet faces -Z (Roblox LookVector), up is +Y, its right hand is +X. Model.PrimaryPart is "Body", an
--     invisible part at the pet's centre. Every part is Anchored, CanCollide/CanTouch/CanQuery = false,
--     Massless, CastShadow = false. Part names are unique inside a model ("Fur", "Fur2", "WingL", "WingL2"...).
--   * Animate never uses welds or Motor6D: every animated part stores its resting offset in its group's hinge
--     frame (attributes PB_G / PB_Base, model attribute PB_Rig) and Animate recomputes it from the PrimaryPart's
--     CURRENT CFrame, so it works in the workspace and in ViewportFrames; Clone()s rebuild their rig from the
--     attributes.
--   * Build results are cached per (pet look, detail): the first build sculpts, later builds Clone() a template.
--   * Unknown Species / WingStyle / Accessory values fall back to Cat / Feather / none.
--   * Rarity flair: Legendary and Mythic pets get a low-rate sparkle emitter; Secret pets get a ring of floating
--     glowing voxels orbiting them plus sparkles.

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
	"Stormfang", -- the player's own creature (ARCHITECTURE_V3.md section 10)
}
PetBuilder.Accessories = { "Horns", "Crown", "Halo", "Leaf", "Mushroom", "Scarf", "Antlers", "Flower" }
PetBuilder.WingStyles = { "Feather", "Bat", "Fairy", "Cloud", "Crystal", "Flame", "StormCloud" }

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local VOXEL = 0.1 -- studs per design voxel at Scale 1 (High detail sculpts at exactly this size)
local LOW_K = 0.5 -- Low detail sculpts the same shapes at this resolution factor
local LEAN_LOW_K = 0.42 -- ... or at this one for the rare heavy combination that would not fit
local LEAN_HIGH_K = 0.85 -- High detail falls back to this resolution for such combinations
local FLAP_HZ = 2.0 -- wing beats per second at Flap = 1 (PetController relies on this number)
local WAG_HZ = 0.9 -- tail wags per second
local SWAY_HZ = 0.55 -- slow idle motions (halo bob, aura orbit)
local BLINK_TIME = 0.16
local FLAP_AMP = math.rad(35)

-- part budgets per group; Total is what the body may fill up to, Cap the hard limit for the whole pet
local BUDGET = {
	High = { Total = 344, Cap = 350, Body = 216, Wing = 32, Tail = 20, Halo = 10 },
	Low = { Total = 116, Cap = 120, Body = 70, Wing = 11, Tail = 7, Halo = 4 },
	-- evolved forms (bigger, more detailed: PetBuilder.Build(def, { Evolved = true }))
	EvoHigh = { Total = 1500, Cap = 1560, Body = 1080, Wing = 190, Tail = 80, Halo = 30 },
	EvoLow = { Total = 360, Cap = 380, Body = 240, Wing = 44, Tail = 16, Halo = 8 },
	-- second evolution (Epic and up: PetBuilder.Build(def, { Evolved = 2 }))
	AscHigh = { Total = 1940, Cap = 2000, Body = 1240, Wing = 220, Wing2 = 110, Tail = 160, Halo = 80, Aura = 90 },
	AscLow = { Total = 480, Cap = 520, Body = 280, Wing = 46, Wing2 = 24, Tail = 28, Halo = 14, Aura = 20 },
}

-- the rarities that have a second evolution
local ASCEND_RARITY = { Epic = true, Legendary = true, Mythic = true, Secret = true }

local function budgetOf(look, detail)
	if look.Evolved == 2 then
		return BUDGET[(detail == "Low") and "AscLow" or "AscHigh"]
	elseif look.Evolved then
		return BUDGET[(detail == "Low") and "EvoLow" or "EvoHigh"]
	end
	return BUDGET[detail] or BUDGET.High
end

local TAU = math.pi * 2
local floor, max, min, abs, sin = math.floor, math.max, math.min, math.abs, math.sin

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

local WHITE, BLACK, NEON = nil, nil, nil

local function initConstants()
	if WHITE then
		return
	end
	WHITE = rgb(255, 255, 255)
	BLACK = rgb(0, 0, 0)
	NEON = Enum.Material.Neon
end

local function lighten(c, t)
	return c:Lerp(WHITE, t)
end

local function darken(c, t)
	return c:Lerp(BLACK, t)
end

-- hue rotation (for iridescent Secret accents); h in 0..1
local function hueShift(c, dh)
	local h, s, v = c:ToHSV()
	return Color3.fromHSV((h + dh) % 1, clamp(s, 0.35, 1), clamp(v, 0.6, 1))
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
		c[i] = string.format("%.6g", c[i])
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
-- Sculpting helpers. Every coordinate below is in DESIGN voxels (High resolution); SK scales them to the
-- resolution being sculpted (1 for High, LOW_K for Low). Points are {x, y, z}.
----------------------------------------------------------------------
local SK = 1

local function scaleValue(v, k)
	k = k or SK
	if type(v) == "number" then
		return v * k
	elseif type(v) == "table" then
		return { (v[1] or 0) * k, (v[2] or 0) * k, (v[3] or 0) * k }
	end
	return v
end

local POINT_FIELDS = { Center = true, A = true, B = true, Pivot = true, Radius = true, RadiusB = true, Size = true, Round = true, Thickness = true, ThicknessB = true }

-- copy of a shape table scaled to the current resolution, or to res (a grid's own; patterns still receive design
-- coordinates)
local function scaled(t, res)
	local K = res or SK
	local o = {}
	for k, v in pairs(t) do
		if POINT_FIELDS[k] then
			o[k] = scaleValue(v, K)
		elseif k == "Points" then
			local pts = {}
			for i, p in ipairs(v) do
				pts[i] = scaleValue(p, K)
			end
			o[k] = pts
		elseif k == "Radii" then
			local r = {}
			for i, x in ipairs(v) do
				r[i] = x * K
			end
			o[k] = r
		elseif k == "Pattern" and type(v) == "function" and K ~= 1 then
			local fn, k2 = v, K
			o[k] = function(x, y, z, cur)
				return fn(x / k2, y / k2, z / k2, cur)
			end
		else
			o[k] = v
		end
	end
	return o
end

local function shape(g, t)
	return Voxel.Shape(g, scaled(t, g.K)) -- (a grid may be sculpted at its own resolution: g.K)
end

local function withExtra(t, extra)
	if extra then
		for k, v in pairs(extra) do
			t[k] = v
		end
	end
	return t
end

local function ell(g, key, c, r, extra)
	return shape(g, withExtra({ Kind = "Ellipsoid", Center = c, Radius = r, Key = key }, extra))
end

local function cap(g, key, a, b, r, rb, extra)
	return shape(g, withExtra({ Kind = "Capsule", A = a, B = b, Radius = r, RadiusB = rb, Key = key }, extra))
end

local function cone(g, key, a, b, r, rb, extra)
	return shape(g, withExtra({ Kind = "Cone", A = a, B = b, Radius = r, RadiusB = rb or 0, Key = key }, extra))
end

local function curve(g, key, pts, r, rb, extra)
	return shape(g, withExtra({ Kind = "Curve", Points = pts, Radius = r, RadiusB = rb, Key = key }, extra))
end

local function box(g, key, c, size, extra)
	return shape(g, withExtra({ Kind = "Box", Center = c, Size = size, Key = key }, extra))
end

-- recolours existing voxels inside the shape (only = key or {key = true} limits it to those keys)
local function paint(g, key, t, only)
	t.Op = "Paint"
	t.Key = key
	t.OnlyKeys = only or t.OnlyKeys
	return shape(g, t)
end

local function carve(g, t, only)
	t.Op = "Carve"
	t.OnlyKeys = only or t.OnlyKeys
	return shape(g, t)
end

-- calls fn(side) for side = 1 (+X, the pet's right) and -1
local function pair(fn)
	fn(1)
	fn(-1)
end

-- design coordinate -> voxel index at the current resolution
local function vx(v)
	return floor(v * SK + 0.5)
end

local function get(g, x, y, z)
	return Voxel.Get(g, x, y, z)
end

local function set(g, x, y, z, key)
	Voxel.Set(g, x, y, z, key)
end

-- z of the frontmost (most -Z) voxel of the voxel column (x, y), or nil
local function frontZ(g, x, y)
	for z = -40, 40 do
		if get(g, x, y, z) then
			return z
		end
	end
	return nil
end

-- paints the frontmost voxel of the voxel column (x, y) (optionally only over the keys in `only`)
local function paintFrontV(g, x, y, key, only)
	local z = frontZ(g, x, y)
	if z and (not only or only[get(g, x, y, z)]) then
		set(g, x, y, z, key)
	end
	return z
end

-- same, in design coordinates
local function dot(ctx, x, y, key, only)
	return paintFrontV(ctx.Body, vx(x), vx(y), key, only)
end

-- a highlight voxel on the front of a shiny nose (design coordinates)
local function shine(ctx, x, y)
	local g = ctx.Body
	local X, Y = vx(x), vx(y)
	local z = frontZ(g, X, Y)
	if z then
		set(g, X, Y, z, "EyeShine")
	end
end

-- pushes a voxel one step out of the front surface (raised details: noses, buck teeth)
local function bump(ctx, x, y, key)
	local g = ctx.Body
	local X, Y = vx(x), vx(y)
	local z = frontZ(g, X, Y)
	if z then
		set(g, X, Y, z - 1, key)
	end
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
	local rarity, id = nil, "pet"
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
		hex(look.Secondary), hex(look.Eye), hex(look.WingColor), tostring(look.Glow), tostring(look.Evolved),
	}, "|")
end

-- Flat accents: never shaded and never recoloured by the LOD.
local FLAT_KEYS = {
	"EyeIris", "EyePupil", "EyeShine", "EyeGlint", "EyeRing", "Lash", "Nose", "Mouth", "Blush", "Nostril",
	"Tongue", "Tooth", "Gem", "GemB", "Spark", "AuraA", "AuraB", "AuraC", "Lid", "LidLine", "HaloGlow",
}

local CREAM = nil

local function makePalette(look)
	local P, S, E, W = look.Primary, look.Secondary, look.Eye, look.WingColor
	CREAM = rgb(255, 242, 218)
	local dark = luminance(P) < 0.3
	local pal = {
		Fur = P,
		Accent = S,
		AccentDark = darken(S, 0.3),
		Belly = mix(S, rgb(255, 250, 240), 0.45),
		Muzzle = mix(P, rgb(255, 250, 242), 0.6),
		Stripe = mix(darken(P, 0.3), S, 0.12),
		Patch = darken(P, 0.62),
		Inner = mix(rgb(246, 164, 176), P, 0.15),
		Nose = mix(rgb(226, 118, 136), P, 0.1),
		Mouth = dark and mix(S, WHITE, 0.35) or darken(mix(P, rgb(120, 52, 64), 0.65), 0.5),
		Blush = mix(rgb(255, 130, 158), P, 0.25),
		Lash = dark and mix(S, WHITE, 0.2) or darken(mix(P, E, 0.45), 0.7),
		Claw = rgb(250, 238, 216),
		Hoof = mix(rgb(120, 100, 96), P, 0.25),
		Horn = rgb(244, 192, 72),
		Gold = rgb(244, 192, 72),
		GoldDeep = rgb(214, 148, 50),
		Beak = rgb(244, 172, 70),
		Feet = rgb(240, 158, 72),
		Wing = W,
		WingTrim = darken(W, 0.25),
		WingEdge = lighten(W, 0.35),
		WingVein = darken(W, 0.35),
		Tongue = rgb(236, 112, 128),
		Tooth = rgb(255, 252, 246),
		Nostril = darken(P, 0.62),
		Gem = rgb(232, 72, 110),
		GemB = rgb(84, 172, 238),
		Spark = rgb(255, 250, 232),
		Leaf = rgb(108, 184, 96),
		LeafDeep = rgb(64, 140, 74),
		Stem = rgb(120, 92, 62),
		Cap = rgb(222, 82, 92),
		CapSpot = rgb(255, 246, 236),
		Scarf = rgb(214, 76, 92),
		ScarfStripe = rgb(255, 236, 214),
		Antler = rgb(176, 132, 96),
		AntlerTip = rgb(244, 226, 196),
		Petal = rgb(255, 184, 206),
		PetalDeep = rgb(240, 126, 164),
		Pollen = rgb(255, 214, 92),
		Cloud = rgb(246, 250, 255),
		Lid = P,
		LidLine = dark and mix(S, WHITE, 0.2) or darken(P, 0.55),
	}
	if dark then
		pal.Patch = lighten(P, 0.35)
	end
	-- eyes: a dark iris (or a glowing one for Glow pets), darker pupil, white highlights, a lower glint
	local bright = luminance(E) > 0.45
	pal.EyeIris = E
	pal.EyePupil = darken(E, bright and 0.62 or 0.55)
	pal.EyeGlint = lighten(E, bright and 0.5 or 0.38)
	pal.EyeShine = rgb(252, 252, 255)
	pal.EyeRing = mix(rgb(255, 196, 80), S, 0.25)
	if look.Glow then
		pal.EyeIris = { Color = E, Material = NEON }
		pal.EyeGlint = { Color = lighten(E, 0.5), Material = NEON }
		pal.WingEdge = { Color = lighten(W, 0.45), Material = NEON }
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
		High = detail ~= "Low", -- resolution: eye masks, blush
		Fine = detail ~= "Low", -- optional small details (patterns, toes, hollows); off in the lean rebuild
		Body = Voxel.NewGrid(30),
		Wing = Voxel.NewGrid(30), -- the LEFT wing, in hinge-local voxels (it reaches towards -X)
		Tail = nil, -- optional grid in tail-hinge-local voxels (the tail reaches towards +Z)
		Halo = nil, -- optional grid around the halo centre (bobs)
		Pal = makePalette(look),
		Eyes = {},
		-- anchors (design units) the species sets for wings, tail and accessories
		WingHinge = { 3.8, -1.5, 4.2 }, -- right wing root; the left one is its mirror image
		WingTilt = 0.38, -- radians the resting wings are raised
		WingSweep = 0.5, -- radians the resting wings are swept back
		TailHinge = { 0, -8.5, 6 },
		TailWag = 0.3,
		HeadC = { 0, 6.5, -0.5 },
		HeadR = { 8.6, 7, 7.2 },
		HeadTop = 13.5, -- y of the top of the head (hats sit here)
		EarX = 6, -- |x| of the ears (hats avoid them)
		NeckY = 0, -- y of the neck (scarves)
		NeckR = { 6, 6 }, -- neck radius x, z
		NeckZ = 1,
		FlowerAt = { 5.5, 11.5, -3 },
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
-- Faces
----------------------------------------------------------------------
-- Eye masks in SCREEN space (rows top -> bottom, columns left -> right as seen from the front). The highlight
-- sits on the viewer's upper left on both eyes (one light source).
--   S highlight   P pupil   I iris   G lower glint   R ring   L lash   . no eye
local EYE_MASKS = {
	Round = {
		". P P .",
		"S S P P",
		"S S P I",
		"P P I I",
		". G G .",
	},
	RoundLow = {
		"S P",
		"P P",
		"P G",
	},
	-- the mascot's huge sparkly eyes: big highlight top left, a small one bottom right, a lighter lower iris
	Big = {
		". P P P .",
		"P S S P P",
		"P S S P P",
		"P P P P I",
		"I P P S I",
		". G G G .",
	},
	BigLow = {
		"S S P",
		"S P P",
		"P G P",
	},
	Small = {
		"S P P",
		"P P I",
		". G .",
	},
	SmallLow = {
		"S P",
		"P G",
	},
	-- Stormfang's fierce slanted eyes (the left eye uses the mirror image): a dark brow line slanting down to the
	-- muzzle, a glowing blue iris with a bright core and a white glint, a violet rim along the lower edge
	Fierce = {
		"L L L . .",
		"R S I L L",
		"R I G I I",
		". R I I I",
		". . R R .",
	},
	FierceLow = {
		"L L",
		"I L",
		"I I",
	},
	Owl = {
		". R R R .",
		"R S S P R",
		"R S P P R",
		"R P P G R",
		". R R R .",
	},
	OwlLow = {
		"R R R",
		"R S R",
		"R P R",
	},
}
local EYE_KEYS = { L = "Lash", I = "EyeIris", P = "EyePupil", S = "EyeShine", G = "EyeGlint", R = "EyeRing" }

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

-- Registers a pair of eyes. xOuter / yTop (design units) = the outermost column and top row of the pet's right
-- eye (+X side, screen left); the left eye is placed mirror-symmetrically, with the same (unmirrored) mask.
local function addEyes(ctx, xOuter, yTop, kind, mirror)
	local name = (kind or "Round") .. (ctx.High and "" or "Low")
	local mask = parseMask(EYE_MASKS[name] or EYE_MASKS.Round)
	local w = #mask[1]
	local X, Y = vx(xOuter), vx(yTop)
	-- right eye: screen column 1 is the largest x
	ctx.Eyes[#ctx.Eyes + 1] = { XLeft = X, Y = Y, Mask = mask }
	local other = mask
	if mirror then
		other = {}
		for r, cols in ipairs(mask) do
			local rev = {}
			for c = #cols, 1, -1 do
				rev[#rev + 1] = cols[c]
			end
			other[r] = rev
		end
	end
	ctx.Eyes[#ctx.Eyes + 1] = { XLeft = -(X - w + 1), Y = Y, Mask = other }
end

-- Carves every eye 1 voxel into the face: the frontmost voxel of each eye column is removed and the voxel behind
-- it takes the eye colour, so the eye follows the curve of the head and sits INSIDE it. The removed voxels
-- become the blink lids (a hidden group, shown for a moment while blinking).
local function carveEyes(ctx)
	local g = ctx.Body
	ctx.LidCells = {}
	for _, eye in ipairs(ctx.Eyes) do
		local lid = {}
		local rows = #eye.Mask
		for r, cols in ipairs(eye.Mask) do
			local y = eye.Y - (r - 1)
			for c, ch in ipairs(cols) do
				local key = EYE_KEYS[ch]
				if key then
					local x = eye.XLeft - (c - 1)
					local z = frontZ(g, x, y)
					if z then
						local was = get(g, x, y, z)
						set(g, x, y, z, nil)
						set(g, x, y, z + 1, key)
						local lidKey = Voxel.BaseKey(was) or "Lid"
						if r == floor(rows / 2) + 1 then
							lidKey = "LidLine"
						end
						lid[#lid + 1] = { x, y, z, lidKey }
					end
				end
			end
		end
		ctx.LidCells[#ctx.LidCells + 1] = lid
	end
end

-- Blush: a short pink oval on each cheek (front surface), design coordinates of the inner end.
local function blush(ctx, x0, y, w)
	w = w or 3
	if ctx.High then
		for i = 0, w - 1 do
			dot(ctx, x0 + i, y, "Blush")
			dot(ctx, -(x0 + i), y, "Blush")
		end
		for i = 1, w - 2 do
			dot(ctx, x0 + i, y - 1, "Blush")
			dot(ctx, -(x0 + i), y - 1, "Blush")
		end
	else
		dot(ctx, x0 + 1, y, "Blush")
		dot(ctx, -(x0 + 1), y, "Blush")
	end
end

-- painted cells in design coordinates around x = 0: list of {x, y}
local function face(ctx, key, cells)
	for _, c in ipairs(cells) do
		dot(ctx, c[1], c[2], key)
	end
end

-- An open smiling mouth carved 1 voxel into the snout: dark inside with a pink tongue at the bottom.
-- (x = 0 centred; yTop = top row, design units)
local MOUTH_MASKS = {
	High = { "M M M M M", "M T T T M", ". M T M ." },
	Low = { "M M M", ". T ." },
}
local function openMouth(ctx, yTop)
	local g = ctx.Body
	local mask = parseMask(MOUTH_MASKS[ctx.High and "High" or "Low"])
	local w = #mask[1]
	local Y = vx(yTop)
	for r, cols in ipairs(mask) do
		for c, ch in ipairs(cols) do
			if ch ~= "." then
				local x = floor(w / 2) - (c - 1)
				local y = Y - (r - 1)
				local z = frontZ(g, x, y)
				if z then
					set(g, x, y, z, nil)
					set(g, x, y, z + 1, (ch == "T") and "Tongue" or "Mouth")
				end
			end
		end
	end
end

----------------------------------------------------------------------
-- Shared anatomy
----------------------------------------------------------------------
-- A round chibi head. Remembers its geometry for faces and accessories.
local function head(ctx, key, c, r)
	ell(ctx.Body, key, c, r)
	ctx.HeadC, ctx.HeadR = c, r
	ctx.HeadTop = c[2] + r[2]
end

-- Upright pointy ear with a hollow pink inside.
local function triEar(ctx, s, base, tip, r, innerKey, tipKey)
	local g = ctx.Body
	local bx, by, bz = base[1] * s, base[2], base[3]
	local tx, ty, tz = tip[1] * s, tip[2], tip[3]
	cone(g, "Fur", { bx, by, bz }, { tx, ty, tz }, r, 0.35)
	if tipKey then
		paint(g, tipKey, { Kind = "Ellipsoid", Center = { tx, ty - 0.8, tz }, Radius = { r * 0.9, 2.4, r * 0.9 } }, "Fur")
	end
	paint(g, innerKey or "Inner", { Kind = "Cone", A = { bx * 1.02, by + 0.6, bz - 1.1 }, B = { tx * 0.97, ty - 1.6, tz - 0.8 }, Radius = r * 0.62, RadiusB = 0.2 }, "Fur")
	if ctx.Fine then
		carve(ctx.Body, { Kind = "Cone", A = { bx * 1.02, by + 0.8, bz - 2.8 }, B = { tx * 0.97, ty - 1.8, tz - 2.1 }, Radius = r * 0.48, RadiusB = 0.1 }, { Fur = true, Inner = true })
	end
end

-- Round bear-like ear: a disc half sunk into the head with a lighter inner disc.
local function roundEar(ctx, s, c, r, key, innerKey)
	local g = ctx.Body
	ell(g, key or "Fur", { c[1] * s, c[2], c[3] }, { r, r, r * 0.62 })
	paint(g, innerKey or "Inner", { Kind = "Ellipsoid", Center = { c[1] * s, c[2] - 0.3, c[3] - r * 0.55 }, Radius = { r * 0.6, r * 0.6, r * 0.5 } }, key or "Fur")
end

-- Sitting body (pear-shaped) + four short legs with paws. o: FrontX, HindX, FootY, PawKey, LegKey, BodyC, BodyR
local function sitBody(ctx, o)
	local g = ctx.Body
	local legKey = o.LegKey or "Fur"
	local pawKey = o.PawKey or legKey
	local c = o.BodyC or { 0, -4.8, 1.5 }
	local r = o.BodyR or { 5.4, 5.8, 5.6 }
	ell(g, o.BodyKey or "Fur", c, r)
	local foot = o.FootY or -11.2
	local fx = o.FrontX or 2.8
	local fz = o.FrontZ or -2.6
	local hx = o.HindX or 4.3
	pair(function(s)
		-- front leg: tapered down to a round paw
		cap(g, legKey, { s * fx, -5.5, fz + 0.6 }, { s * fx, foot + 1.3, fz }, 1.75, 1.45)
		ell(g, pawKey, { s * fx, foot + 0.7, fz - 0.5 }, { 1.65, 1.15, 1.85 })
		-- hind leg: chunky thigh + long foot
		ell(g, legKey, { s * hx, foot + 3.4, 2.4 }, { 2.4, 3, 3.1 })
		ell(g, pawKey, { s * (hx + 0.1), foot + 0.7, 0.4 }, { 1.7, 1.15, 2.4 })
		if ctx.Fine and o.Toes ~= false then
			-- toe gaps on the front paws
			local X, Y = vx(s * fx), vx(foot + 0.4)
			local z = frontZ(g, X, Y)
			if z then
				set(g, X + 1, Y, z, o.ToeKey or "Lash")
				set(g, X - 1, Y, z, o.ToeKey or "Lash")
			end
		end
	end)
	ctx.NeckY = c[2] + r[2] - 1.2
	ctx.NeckR = { r[1] + 0.6, r[3] + 0.4 }
	ctx.NeckZ = c[3] - 0.2
end

-- A new tail grid; returns it.
local function newTail(ctx, hinge, wag)
	local t = Voxel.NewGrid(30)
	if ctx.LimbK then
		t.K = SK * ctx.LimbK -- (the second evolution sculpts its limbs a little coarser)
	end
	ctx.Tail = t
	ctx.TailHinge = hinge
	ctx.TailWag = wag or 0.3
	return t
end

----------------------------------------------------------------------
-- Species
----------------------------------------------------------------------
-- Shared by the furry species and the Dragon (Cat, Dog, Fox, Bunny, Bear, Panda, Dragon).
-- A soft eye (4 x 5): dark upper lid line, a big highlight top left, a small one lower right and a lighter iris
-- in the lower half (the mascot's sparkly eye, branding/icon-512.png).
EYE_MASKS.Cute = {
	". L L .",
	"P S S P",
	"P S P P",
	"I P I S",
	". I G .",
}
EYE_MASKS.CuteLow = {
	"S P",
	"P P",
	"I G",
}

-- Eye colours that read as eyes, never as holes: a deep pupil in the eye's own hue, a clearly lighter iris (a
-- dark brown catalog eye becomes a warm brown iris around a near-black pupil) and a bright glint; a glowing
-- (Neon) iris keeps its glow around a deep, saturated pupil instead of a muddy darkened one.
local function cuteEyes(ctx)
	local pal, E = ctx.Pal, ctx.Look.Eye
	local h, s, v = E:ToHSV()
	local glow = type(pal.EyeIris) == "table"
	pal.EyePupil = Color3.fromHSV(h, clamp(s * 0.8 + 0.25, 0.35, 0.8), glow and 0.2 or 0.12)
	pal.Lash = Color3.fromHSV(h, clamp(s * 0.6 + 0.15, 0.2, 0.6), 0.1)
	if glow then
		pal.EyeGlint = { Color = lighten(E, 0.6), Material = NEON }
	else
		local iris = E
		if luminance(E) < 0.4 then
			iris = Color3.fromHSV(h, clamp(s + 0.15, 0.4, 0.75), clamp(v + 0.4, 0.5, 0.66))
		end
		pal.EyeIris = iris
		pal.EyeGlint = lighten(iris, 0.5)
	end
end

-- The furry species' shading: the body may use the whole part budget the wings, tail and extras leave, and only
-- its main colours (keys) get broad shades, a lighter top and a darker underside without crease speckle, cheap
-- enough to survive the part budget (the default per-voxel shading is folded away first when a body runs over).
-- lightOnly: just the lighter tops (the cheapest set, for bodies that share the budget with heavy extras).
local function shadeMain(ctx, keys, lightOnly)
	local only = {}
	for _, k in ipairs(keys) do
		only[k] = true
	end
	ctx.BodyFill = true
	ctx.BodyShade = { LightAt = 0.7, DarkAt = -0.5, Dark = not lightOnly, Crease = 0, Smooth = 3, Only = only }
end

-- Toe gaps a little darker than the paw (not black dots); paw = palette key of the paws.
local function softToes(ctx, paw)
	ctx.Pal.Toe = darken(asColor(ctx.Pal[paw], ctx.Look.Primary), 0.32)
	return "Toe"
end

SPECIES.Cat = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	local look = ctx.Look
	head(ctx, "Fur", { 0, 6.5, -0.5 }, { 8.6, 7, 7.2 })
	pair(function(s)
		ell(g, "Fur", { s * 5.4, 3.5, -2.8 }, { 3.8, 3, 3.6 }) -- cheeks
		-- cheek fluff: a soft tuft poking out sideways and down below the eyes
		cone(g, "Fur", { s * 7.6, 3.4, -1.8 }, { s * 10.8, 1.4, -1.2 }, 1.7, 0.35)
		triEar(ctx, s, { 5, 10.5, -0.5 }, { 6.6, 17.5, 0 }, 3.2)
	end)
	-- whisker pads + chin
	pair(function(s)
		ell(g, "Muzzle", { s * 1.4, 2.6, -6.7 }, { 2, 1.6, 1.3 })
	end)
	sitBody(ctx, { PawKey = "Belly", ToeKey = softToes(ctx, "Belly") })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.6, -4.2 }, Radius = { 3.6, 4.6, 2.6 } }, "Fur")
	-- a fluffy chest tuft under the chin
	if H then
		cone(g, "Belly", { 0, -0.6, -4.6 }, { 0, -3.4, -6.4 }, 1.9, 0.4)
	end
	-- tabby markings: forehead "M", cheek lines, back stripes
	if H then
		pair(function(s)
			box(g, "Stripe", { s * 1.5, 12.2, -4 }, { 1, 2.6, 7 }, { Op = "Paint", OnlyKeys = "Fur" })
			for i = 0, 1 do
				cap(g, "Stripe", { s * 8.8, 6.5 - i * 2, -2 }, { s * 6.8, 6.2 - i * 2, -5 }, 0.55, 0.55, { Op = "Paint", OnlyKeys = "Fur" })
			end
		end)
		box(g, "Stripe", { 0, 12.8, -3.5 }, { 1, 2, 7 }, { Op = "Paint", OnlyKeys = "Fur" })
		-- two bands over the back (a pale cat keeps a plain back: its soft stripes would only blur)
		if luminance(look.Primary) <= 0.7 then
			for i = 0, 1 do
				box(g, "Stripe", { 0, -2 - i * 3, 6 }, { 20, 1, 8 }, { Op = "Paint", OnlyKeys = "Fur" })
			end
		end
	end
	addEyes(ctx, 5, 8.5, "Cute")
	cuteEyes(ctx)
	shadeMain(ctx, { "Fur" }, look.WingStyle == "Bat")
	face(ctx, "Nose", H and { { 0, 4 }, { -1, 4 }, { 1, 4 }, { 0, 3 } } or { { 0, 3.6 } })
	if H then
		face(ctx, "Mouth", { { 0, 2 }, { 1, 1 }, { -1, 1 }, { 2, 2 }, { -2, 2 } })
	end
	blush(ctx, 5, 3.4, 3)
	-- long tail swept back and raised, the tip curling forward, with rings (straight segments merge into few parts,
	-- so the rings keep their colour within the tail's part budget)
	local t = newTail(ctx, { 0, -8.5, 6.2 }, 0.32)
	cap(t, "Fur", { 0, 0, 0 }, { 0, 0.6, 5 }, 1.55, 1.4)
	cap(t, "Fur", { 0, 1, 5.8 }, { 0, 10.4, 6.4 }, 1.45, 1.2)
	ell(t, "Fur", { 0, 11.4, 5.6 }, { 1.3, 1.4, 1.4 })
	if H then
		for i = 1, 3 do
			box(t, "Stripe", { 0, 1.6 + i * 3.1, 7 }, { 7, 1, 7 }, { Op = "Paint", OnlyKeys = "Fur" })
		end
	end
	-- a pale cat gets soft stripes tinted by its second colour (grey ones look like smudges on white fur)
	if luminance(look.Primary) > 0.7 then
		ctx.Pal.Stripe = mix(darken(look.Primary, 0.1), look.Secondary, 0.55)
	end
	ctx.EarX = 6.2
	ctx.HeadTop = 13.2
	ctx.FlowerAt = { 4, 13, -2.5 }
end

SPECIES.Dog = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	local look = ctx.Look
	-- a corgi has big upright ears and a white blaze; other dogs have soft floppy ears and an eye patch
	local corgi = string.find(string.lower(look.Id), "corgi", 1, true) ~= nil
	head(ctx, "Fur", { 0, 6.6, -0.4 }, { 8, 6.8, 7.2 })
	pair(function(s)
		ell(g, "Fur", { s * 4.8, 3.8, -2.6 }, { 3.6, 2.8, 3.4 })
	end)
	-- snout: a rounded muzzle with a big glossy dark nose, a light blaze up the forehead
	ell(g, "Muzzle", { 0, 3, -6.4 }, { 3.4, 2.6, 3 })
	paint(g, "Muzzle", { Kind = "Ellipsoid", Center = { 0, 8, -6.8 }, Radius = { corgi and 1.6 or 1.1, 3.6, 2 } }, "Fur")
	ell(g, "Nose", { 0, 4.3, -9.1 }, { 1.7, 1.1, 0.9 })
	if H then
		shine(ctx, -1, 4.8)
		-- a "w" smile under the nose with the tip of a pink tongue
		face(ctx, "Mouth", { { 0, 3 }, { 0, 2 }, { 1, 1 }, { -1, 1 }, { 2, 2 }, { -2, 2 } })
		face(ctx, "Tongue", { { 0, 1 } })
	end
	if corgi then
		pair(function(s)
			triEar(ctx, s, { 4.4, 10.4, 0 }, { 7.4, 17.6, 0.8 }, 3.5)
		end)
	else
		-- soft floppy ears hanging close to the head, a shade darker
		pair(function(s)
			ell(g, "Ear", { s * 7.6, 7.4, 0 }, { 1.7, 4.6, 2.8 }, { Rotation = CFrame.Angles(0, 0, s * 0.28) })
			ell(g, "Ear", { s * 8.6, 3.6, -0.2 }, { 1.6, 1.8, 2.4 })
		end)
		-- a darker patch around the right eye
		if H then
			paint(g, "Ear", { Kind = "Ellipsoid", Center = { 3.8, 7.4, -6 }, Radius = { 2.8, 3, 3 } }, "Fur")
		end
	end
	sitBody(ctx, { PawKey = "Belly", ToeKey = softToes(ctx, "Belly") })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.4, -4.4 }, Radius = { 3.8, 4.8, 2.6 } }, "Fur")
	addEyes(ctx, 5, 9.2, "Cute")
	cuteEyes(ctx)
	shadeMain(ctx, { "Fur", "Ear" })
	blush(ctx, 5.4, 4, 3)
	-- a happy tail curled up over the back
	local t = newTail(ctx, { 0, -7.5, 6.2 }, 0.5)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, 2.6, 2.4 }, { 0, 5.4, 2.6 }, { 0, 6.8, 0.6 } }, 1.7, 1.1)
	ell(t, "Belly", { 0, 6.9, 0.4 }, { 1.3, 1.3, 1.3 })
	ctx.Pal.Ear = darken(ctx.Pal.Fur, 0.22)
	ctx.Pal.Nose = rgb(54, 40, 42)
	ctx.Pal.Muzzle = mix(look.Secondary, rgb(255, 250, 242), 0.4)
	ctx.EarX = corgi and 6.4 or 7.5
	ctx.HeadTop = 13.4
	ctx.FlowerAt = corgi and { 3, 11.8, -4.4 } or { 4.6, 12.6, -3 }
end

SPECIES.Fox = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	local look = ctx.Look
	head(ctx, "Fur", { 0, 6.6, -0.4 }, { 8.4, 6.8, 7 })
	-- white cheek ruffs: a pointed tuft sweeping out and down on each side
	pair(function(s)
		ell(g, "Belly", { s * 4.2, 2.4, -3.6 }, { 3.6, 2.6, 3.2 }, { Rotation = CFrame.Angles(0, 0, s * 0.35) })
		cone(g, "Belly", { s * 6.4, 2.6, -2.4 }, { s * 9.8, 0, -1 }, 2, 0.35)
	end)
	-- pointed snout
	ctx.Pal.Nose = rgb(48, 36, 40)
	cone(g, "Belly", { 0, 3.6, -4.8 }, { 0, 3.2, -10.4 }, 3, 1.1)
	ell(g, "Nose", { 0, 3.9, -10.4 }, { 1, 0.7, 0.8 })
	paint(g, "Fur", { Kind = "Ellipsoid", Center = { 0, 5.8, -8 }, Radius = { 2, 1.6, 3 } }, "Belly")
	-- big ears with dark backs and tips
	pair(function(s)
		triEar(ctx, s, { 4.6, 10.4, -0.4 }, { 7.2, 18.2, 0.4 }, 3.6, "Inner", "Patch")
	end)
	-- dark socks on the lower legs and the feet: a deep tone of the fur, not black (dark foxes keep the lighter
	-- patch colour of the palette)
	if luminance(look.Primary) >= 0.3 then
		ctx.Pal.Patch = darken(look.Primary, 0.5)
	end
	sitBody(ctx, { PawKey = "Patch", Toes = false })
	pair(function(s)
		cap(g, "Patch", { s * 2.8, -7.4, -2.1 }, { s * 2.8, -11, -2.6 }, 2.1, 2.1, { Op = "Paint", OnlyKeys = "Fur" })
	end)
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3, -4.4 }, Radius = { 3.6, 5, 2.8 } }, "Fur")
	addEyes(ctx, 5, 8.6, "Cute")
	cuteEyes(ctx)
	shadeMain(ctx, { "Fur" })
	if H then
		face(ctx, "Mouth", { { 0, 2 } })
		-- eyebrow flecks
		face(ctx, "Belly", { { 3.5, 10.2 }, { 4.5, 10.2 }, { -3.5, 10.2 }, { -4.5, 10.2 } })
	end
	blush(ctx, 5.4, 4.6, 2)
	-- huge bushy tail raised behind the back, with a white tip (two round volumes: few parts, so the tip keeps its
	-- colour within the tail's part budget)
	local t = newTail(ctx, { 0, -8.2, 5.8 }, 0.28)
	ell(t, "Fur", { 0, 5.2, 5.5 }, { 3, 6, 3.4 })
	ell(t, "Belly", { 0, 11, 6.1 }, { 2.4, 2.4, 2.4 })
	ctx.EarX = 6.6
	ctx.HeadTop = 13.2
	ctx.FlowerAt = { 4, 13, -2.5 }
end

SPECIES.Bunny = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	head(ctx, "Fur", { 0, 6.2, -0.4 }, { 8.2, 7, 7.2 })
	pair(function(s)
		ell(g, "Fur", { s * 4.8, 3.2, -2.6 }, { 3.8, 3, 3.6 })
		ell(g, "Muzzle", { s * 1.3, 2.7, -6.7 }, { 1.9, 1.6, 1.3 })
		-- fluffy cheeks
		if H then
			cone(g, "Fur", { s * 7, 3, -1.8 }, { s * 9.6, 1.8, -1.2 }, 1.5, 0.35)
		end
		-- long ears, slightly apart, pink inside
		local base = { s * 3.2, 11.5, 0.3 }
		local tip = { s * 4.8, 19.2, 1.4 }
		cap(g, "Fur", base, tip, 2.2, 1.7)
		ell(g, "Fur", { s * 4.3, 16.8, 1.2 }, { 2.3, 3.2, 1.6 })
		paint(g, "Inner", { Kind = "Capsule", A = { s * 3.3, 13, -1 }, B = { s * 4.7, 18.4, 0.2 }, Radius = 1.25, RadiusB = 1.05 }, "Fur")
		if H then
			carve(g, { Kind = "Capsule", A = { s * 3.3, 13.5, -2.1 }, B = { s * 4.7, 18, -0.9 }, Radius = 0.9, RadiusB = 0.7 }, { Fur = true, Inner = true })
		end
	end)
	sitBody(ctx, { BodyC = { 0, -4.8, 1.6 }, BodyR = { 5.8, 5.8, 5.8 }, PawKey = "Belly", HindX = 4.6, ToeKey = softToes(ctx, "Belly") })
	pair(function(s)
		-- big hind feet
		ell(g, "Belly", { s * 4.5, -10.6, -0.6 }, { 1.9, 1.1, 3 })
	end)
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.6, -4.6 }, Radius = { 3.8, 4.6, 2.6 } }, "Fur")
	addEyes(ctx, 5, 8.6, "Cute")
	cuteEyes(ctx)
	shadeMain(ctx, { "Fur" })
	face(ctx, "Nose", H and { { 0, 4 }, { -1, 4 }, { 1, 4 } } or { { 0, 3.6 } })
	if H then
		face(ctx, "Mouth", { { 0, 3 }, { 1, 2 }, { -1, 2 } })
		-- buck teeth just under the mouth
		bump(ctx, 0, 1, "Tooth")
		bump(ctx, -1, 1, "Tooth")
	end
	blush(ctx, 5, 3.4, 3)
	local t = newTail(ctx, { 0, -7.8, 6.4 }, 0.25)
	ell(t, "Belly", { 0, 0.6, 1.6 }, { 2.6, 2.6, 2.6 })
	ctx.EarX = 4.2
	ctx.HeadTop = 13
	ctx.FlowerAt = { 6, 11.6, -2.6 }
end

local function bearHead(ctx, earKey, earInner)
	local g, H = ctx.Body, ctx.Fine
	ctx.Pal.Nose = rgb(58, 42, 44)
	head(ctx, "Fur", { 0, 6.4, -0.4 }, { 8.4, 7.2, 7.2 })
	pair(function(s)
		ell(g, "Fur", { s * 4.8, 3.6, -2.4 }, { 3.9, 3.1, 3.8 })
		roundEar(ctx, s, { 5.4, 12.4, 0.4 }, 2.9, earKey, earInner)
	end)
	-- round muzzle with a soft button nose (wide on top, narrowing down) and a little smile
	ell(g, "Muzzle", { 0, 2.9, -6.3 }, { 3.6, 2.6, 2.5 })
	ell(g, "Nose", { 0, 4.3, -8.7 }, { 1.6, 0.75, 0.9 })
	ell(g, "Nose", { 0, 3.4, -8.5 }, { 0.75, 0.6, 0.8 })
	if H then
		shine(ctx, -1, 4.3)
		face(ctx, "Mouth", { { 0, 2.4 }, { 1, 1.6 }, { -1, 1.6 } })
	end
end

SPECIES.Bear = function(ctx)
	local g = ctx.Body
	bearHead(ctx, "Fur", "Muzzle")
	sitBody(ctx, { BodyR = { 6, 6, 6 }, PawKey = "Muzzle", ToeKey = softToes(ctx, "Muzzle") })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.8, -4.8 }, Radius = { 4, 4.8, 2.8 } }, "Fur")
	addEyes(ctx, 5.4, 10, "Cute")
	cuteEyes(ctx)
	shadeMain(ctx, { "Fur" })
	blush(ctx, 5.6, 4, 3)
	local t = newTail(ctx, { 0, -8.4, 6.4 }, 0.2)
	ell(t, "Fur", { 0, 0.4, 1.2 }, { 1.9, 1.9, 1.9 })
	ctx.EarX = 6.2
	ctx.HeadTop = 13.4
	ctx.FlowerAt = { 4, 13.2, -2.8 }
end

SPECIES.Panda = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	bearHead(ctx, "Accent", "AccentDark")
	-- the dark eye patches (tilted ovals) and the dark arms / shoulder band
	pair(function(s)
		ell(g, "Accent", { s * 3.7, 6.2, -6.6 }, { 2.6, 3.3, 1.8 }, { Op = "Paint", OnlyKeys = "Fur", Rotation = CFrame.Angles(0, 0, s * -0.5) })
	end)
	sitBody(ctx, { BodyR = { 6, 6, 6 }, LegKey = "Accent", PawKey = "Accent", ToeKey = "AccentDark" })
	paint(g, "Accent", { Kind = "Box", Center = { 0, -2.2, 1.5 }, Size = { 14, 3.2, 14 } }, "Fur")
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -5.8, -4.6 }, Radius = { 3.2, 3.2, 2.4 } }, "Fur")
	addEyes(ctx, 5.2, 9.6, "Cute")
	cuteEyes(ctx)
	shadeMain(ctx, { "Fur", "Accent" })
	if H then
		blush(ctx, 6, 3.6, 2)
	end
	local t = newTail(ctx, { 0, -8.4, 6.4 }, 0.2)
	ell(t, "Fur", { 0, 0.4, 1.2 }, { 1.9, 1.9, 1.9 })
	ctx.Pal.Belly = lighten(ctx.Pal.Fur, 0.25)
	ctx.Pal.Muzzle = lighten(ctx.Pal.Fur, 0.3)
	ctx.Pal.Lid = ctx.Look.Secondary
	ctx.EarX = 6.2
	ctx.HeadTop = 13.4
	ctx.FlowerAt = { 4, 13.2, -2.8 }
end

SPECIES.Dragon = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	local look = ctx.Look
	local cloudy = look.WingStyle == "Cloud"
	-- big round head (light), sky-coloured body and limbs, cream belly in plates (the game's mascot look)
	head(ctx, "Fur", { 0, 6.8, -0.3 }, { 8.6, 7.2, 7.2 })
	pair(function(s)
		ell(g, "Fur", { s * 5, 3.8, -2.4 }, { 3.8, 3.1, 3.6 })
	end)
	-- wide cream snout with two nostrils and an open smile
	ell(g, "Muzzle", { 0, 2.6, -6.3 }, { 4.6, 2.8, 2.6 })
	ell(g, "Muzzle", { 0, 2.2, -5.2 }, { 3.6, 2.6, 2.6 })
	-- (Low detail skips the two nostril voxels: at that size they only cost parts the colours need)
	local nY = vx(4.8)
	pair(function(s)
		local X = vx(s * 1.6)
		local z = ctx.High and frontZ(g, X, nY)
		if z then
			set(g, X, nY, z, "Nostril")
		end
	end)
	openMouth(ctx, 2.6)
	-- the crown of the head: a cloud tuft (cloud dragons) or a crest of spikes running back over the head
	if cloudy then
		ell(g, "Cloud", { 0, 14, 0.4 }, { 2.4, 1.9, 2.2 })
		ell(g, "Cloud", { 1.9, 13.4, 0.8 }, { 1.7, 1.5, 1.7 })
		ell(g, "Cloud", { -1.9, 13.4, 0.8 }, { 1.7, 1.5, 1.7 })
		ell(g, "Cloud", { 0, 13.2, 2.4 }, { 1.8, 1.5, 1.8 })
	else
		-- three stepped spikes, smaller towards the back (axis-aligned steps: crisp and cheap)
		for i = 0, 2 do
			local y, z = 13.6 - i * 1.6, 0.4 + i * 2.8
			box(g, "Accent", { 0, y, z }, { 3, 2, 3 })
			box(g, "Accent", { 0, y + 1.5, z + 0.5 }, { 3, 1, 2 })
			box(g, "Accent", { 0, y + 2.5, z + 1 }, { 1, 1, 1 })
		end
	end
	-- horn nubs (the Horns accessory replaces them with big golden horns)
	if look.Accessory ~= "Horns" then
		pair(function(s)
			cone(g, "Horn", { s * 4.2, 11.4, 0 }, { s * 5.6, 15.2, 1 }, 1.6, 0.45)
		end)
		ctx.Pal.Horn = mix(CREAM, look.Secondary, 0.25)
	end
	sitBody(ctx, { BodyKey = "Scale", LegKey = "Scale", PawKey = "Scale", BodyR = { 5.8, 6, 6 }, ToeKey = "Claw", FootY = -11.4 })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -4.2, -4.2 }, Radius = { 4.2, 5.4, 2.8 } }, "Scale")
	if H then
		for i = 0, 2 do
			box(g, "BellyLine", { 0, -8 + i * 3, -6 }, { 9, 1, 6 }, { Op = "Paint", OnlyKeys = "Belly" })
		end
		-- little cloud tufts between the wings (a cloud dragon)
		if cloudy then
			for i = 0, 1 do
				ell(g, "Cloud", { 0, 0.6 - i * 3.4, 6.8 + i * 0.4 }, { 1.6, 1.5, 1.6 })
			end
		end
	end
	addEyes(ctx, 6, 9.8, "Big")
	cuteEyes(ctx)
	shadeMain(ctx, cloudy and { "Fur", "Scale" } or { "Fur" })
	blush(ctx, 5.6, 4.4, 3)
	-- thick tail sweeping round to the side, ending in a big cloud puff (cloud dragons) or a spade
	local t = newTail(ctx, { 0, -8.6, 5.6 }, 0.3)
	cap(t, "Scale", { 0, 0, 0 }, { 0, 0, 5.6 }, 1.8, 1.5)
	if ctx.High then
		cap(t, "Scale", { 0, 0, 5.6 }, { 5.6, 0, 5.6 }, 1.5, 1.2)
		cap(t, "Scale", { 5.6, 0, 5.6 }, { 6.4, 3, 7.4 }, 1.2, 1)
	else
		cap(t, "Scale", { 0, 0, 5.6 }, { 6.4, 2, 6.6 }, 1.5, 1.2)
	end
	if cloudy then
		ell(t, "Cloud", { 7, 4, 7.6 }, { 3, 2.5, 2.5 })
	else
		cone(t, "Accent", { 6.2, 3.6, 7.4 }, { 9.2, 6.2, 8 }, 2.3, 0.2)
	end
	if cloudy then
		ctx.Pal.Fur = mix(look.Primary, look.Secondary, 0.2)
		ctx.Pal.Scale = mix(look.Primary, look.Secondary, 0.72)
	else
		-- the body a touch lighter than the head, in the same hue (the Secondary colour is the accents')
		ctx.Pal.Scale = lighten(look.Primary, 0.1)
	end
	ctx.Pal.Belly = mix(CREAM, look.Primary, 0.1)
	ctx.Pal.BellyLine = darken(ctx.Pal.Belly, 0.14)
	ctx.Pal.Muzzle = CREAM
	ctx.Pal.Cloud = mix(rgb(252, 253, 255), look.Primary, 0.2)
	ctx.Pal.Mouth = rgb(92, 44, 60)
	ctx.EarX = 5
	ctx.HeadTop = 13.4
	ctx.HornBase = { 4.2, 11.2, 0 }
	ctx.FlowerAt = { 6.2, 11.8, -2.4 }
	ctx.WingHinge = { 3.8, -1.2, 4.4 }
end

-- Owl, Slime, Unicorn, Phoenix, Frog, Penguin, Axolotl (and Stormfang below)
-- Broad, cheap shading for a species' main colours (keys): a lighter top and (unless lightOnly) a darker
-- underside, smoothed and without crease speckle, so the shades survive the part budget; the body may also use
-- whatever the wings, tail and extras leave of the total budget.
local function broadShade(ctx, keys, lightOnly)
	local only = {}
	for _, k in ipairs(keys) do
		only[k] = true
	end
	ctx.BodyFill = true
	ctx.BodyShade = { LightAt = 0.7, DarkAt = -0.5, Dark = not lightOnly, Crease = 0, Smooth = 3, Only = only }
end

SPECIES.Owl = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- a round, bean-shaped owl: one plump body that narrows a little towards the top of the head
	head(ctx, "Fur", { 0, 0.4, 0.2 }, { 8.6, 10.2, 7.6 })
	ell(g, "Fur", { 0, -4.4, 0.6 }, { 8.8, 6.8, 7.4 })
	-- ear tufts with darker tips
	pair(function(s)
		cone(g, "Fur", { s * 4.4, 8.8, -0.8 }, { s * 8.2, 13.6, 0.2 }, 2, 0.35)
		if H then
			paint(g, "Stripe", { Kind = "Ellipsoid", Center = { s * 7.8, 12.8, 0 }, Radius = { 1.6, 1.6, 1.6 } }, "Fur")
		end
	end)
	-- the heart-shaped facial disc: two light ovals around the eyes with a darker rim
	pair(function(s)
		ell(g, "Stripe", { s * 3.6, 5.4, -5.6 }, { 4.6, 4.8, 2.6 }, { Op = "Paint", OnlyKeys = "Fur" })
	end)
	pair(function(s)
		ell(g, "Accent", { s * 3.6, 5.4, -6 }, { 3.9, 4.1, 2.6 }, { Op = "Paint", OnlyKeys = { Fur = true, Stripe = true } })
	end)
	-- a little hooked beak between the eyes
	cone(g, "Beak", { 0, 4.6, -6.8 }, { 0, 2.4, -8.6 }, 1.3, 0.35)
	-- the light chest with small rows of v-shaped feather marks
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -4.4, -4.6 }, Radius = { 5.8, 5.8, 3.8 } }, "Fur")
	if H then
		for _, row in ipairs({ { -2.2, { -2, 2 } }, { -4.8, { -3.4, 0, 3.4 } }, { -7.4, { -2, 2 } } }) do
			for _, x in ipairs(row[2]) do
				face(ctx, "BellyMark", { { x - 1, row[1] }, { x, row[1] - 1 }, { x + 1, row[1] } })
			end
		end
	end
	-- feet with three little talons each
	pair(function(s)
		ell(g, "Feet", { s * 3, -10.8, -2.6 }, { 1.8, 1, 2 })
		if H then
			for _, o in ipairs({ -1, 0, 1 }) do
				box(g, "Feet", { s * 3 + o, -11.2, -4.6 }, { 0.8, 1, 1.4 })
			end
		end
	end)
	addEyes(ctx, 6, 7.8, "Owl")
	blush(ctx, 6.4, 2.4, 2)
	broadShade(ctx, { "Fur", "Belly", "Accent" })
	-- tail feathers fanning out behind
	local t = newTail(ctx, { 0, -8, 6.6 }, 0.16)
	for i = -1, 1 do
		cap(t, (i == 0) and "Fur" or "Stripe", { 0, 0, 0 }, { i * 2, -1.4, 4.2 }, 1.4, 1.1)
	end
	ctx.Pal.Belly = lighten(ctx.Look.Secondary, 0.2)
	ctx.Pal.BellyMark = mix(ctx.Pal.Belly, darken(ctx.Look.Primary, 0.2), 0.45)
	ctx.Pal.Stripe = mix(darken(ctx.Look.Primary, 0.32), ctx.Look.Secondary, 0.08)
	ctx.Pal.EyeRing = mix(rgb(255, 200, 84), ctx.Look.Eye, 0.2)
	if ctx.Look.Glow then
		ctx.Pal.EyeRing = { Color = mix(rgb(255, 214, 120), ctx.Look.Eye, 0.4), Material = NEON }
	end
	ctx.WingHinge = { 7, -1.6, 2 }
	ctx.HeadTop = 11
	ctx.EarX = 6.4
	ctx.NeckY = -1.6
	ctx.NeckR = { 8.4, 7.6 }
	ctx.NeckZ = 0.4
	ctx.FlowerAt = { 4.6, 10.4, -3.4 }
end

SPECIES.Slime = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- a squishy jelly drop: a round dome settling into a wider, softly flared base, with a little swirl on top
	head(ctx, "Fur", { 0, -1, 0 }, { 9.2, 8.8, 8.6 })
	ell(g, "Fur", { 0, -6.2, 0.2 }, { 10.2, 4.8, 9.6 })
	carve(g, { Kind = "Box", Center = { 0, -13.6, 0 }, Size = { 30, 6, 30 } })
	ell(g, "Fur", { 0, 7.8, 0.2 }, { 3.2, 2.2, 3.2 })
	cone(g, "Fur", { 0, 9, 0.2 }, { 1.6, 12, -0.6 }, 1.6, 0.4)
	-- a slightly deeper colour sinking to the bottom of the jelly
	paint(g, "Core", { Kind = "Box", Center = { 0, -10.6, 0 }, Size = { 30, 1.4, 30 } }, "Fur")
	-- glossy highlights: a curved streak on the upper left of the dome and a small round glint
	if H then
		face(ctx, "Spark", { { 4, 7 }, { 5, 7 }, { 5, 6 }, { 6, 5 }, { 6, 4 }, { 2, 8 } })
	else
		face(ctx, "Spark", { { 6, 5 }, { 6, 3 } })
	end
	addEyes(ctx, 4.6, 2.4, "Round")
	broadShade(ctx, { "Fur" })
	if H then
		face(ctx, "Mouth", { { -2, -2 }, { -1, -3 }, { 0, -3 }, { 1, -3 }, { 2, -2 } })
	end
	blush(ctx, 5, -2, 3)
	ctx.Pal.Core = darken(ctx.Look.Primary, 0.1)
	ctx.Pal.Fur_Light = lighten(ctx.Look.Primary, 0.22)
	ctx.Pal.Spark = rgb(255, 252, 254)
	ctx.WingHinge = { 5.4, 0.6, 4.6 }
	ctx.HeadTop = 9.8
	ctx.EarX = 3
	ctx.NeckY = -4.4
	ctx.NeckR = { 9.8, 9.2 }
	ctx.NeckZ = 0
	ctx.FlowerAt = { 4.6, 7.2, -3.8 }
end

SPECIES.Unicorn = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- a round head with a long, soft, lighter muzzle, small pointed ears and a golden spiral horn
	head(ctx, "Fur", { 0, 7, 0 }, { 7.6, 6.8, 6.8 })
	ell(g, "Muzzle", { 0, 3.4, -5.6 }, { 3.4, 2.8, 3.6 })
	pair(function(s)
		-- little nostrils on the front of the muzzle
		local X, Y = vx(s * 1.6), vx(4)
		local z = frontZ(g, X, Y)
		if z then
			set(g, X, Y, z, "Nostril")
		end
		triEar(ctx, s, { 4.6, 11.4, 1 }, { 5.8, 16, 1.6 }, 2)
	end)
	-- spiral golden horn
	cone(g, "Gold", { 0, 12.4, -2.4 }, { 0, 19.4, -4.2 }, 1.9, 0.3)
	if H then
		for i = 0, 2 do
			box(g, "GoldDeep", { 0, 13.8 + i * 2, -2.8 - i * 0.45 }, { 5, 0.7, 5 }, { Op = "Paint", OnlyKeys = "Gold" })
		end
	end
	-- a flowing mane over the top of the head and down the neck, with a darker streak, and a forelock
	ell(g, "Accent", { 0, 11.6, 3.2 }, { 3, 3.4, 4.2 })
	curve(g, "Accent", { { 0, 12.6, 1.2 }, { 0, 10.4, 6.4 }, { 0, 4.6, 7.6 }, { 0, -0.4, 7 } }, 2.6, 1.6)
	if H then
		curve(g, "AccentDark", { { 1.4, 11.8, 2.8 }, { 1.6, 7.4, 7.2 }, { 1.4, 2.6, 8 } }, 1.1, 0.8)
	end
	curve(g, "Accent", { { 0.6, 13, -1.4 }, { -1.6, 12.2, -4.6 }, { -2.8, 10.2, -6 } }, 1.5, 0.9)
	-- a sitting body with slender legs and golden hooves, a light tummy
	sitBody(ctx, { BodyR = { 5.2, 5.8, 5.8 }, PawKey = "Hoof", FrontX = 2.9, Toes = false })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -4, -4.4 }, Radius = { 3.4, 4.6, 2.4 } }, "Fur")
	broadShade(ctx, { "Fur", "Accent" })
	addEyes(ctx, 5.4, 9.6, "Round")
	-- long lashes at the outer corners
	if H then
		face(ctx, "Lash", { { 6, 10 }, { 7, 11 }, { -6, 10 }, { -7, 11 } })
	end
	blush(ctx, 5.2, 5.4, 2)
	-- flowing tail
	local t = newTail(ctx, { 0, -7.8, 6 }, 0.26)
	curve(t, "Accent", { { 0, 0, 0 }, { 0, 1.8, 3.6 }, { 0, -0.2, 7 }, { 0, -2.6, 8.2 } }, 2, 1.4)
	if H then
		curve(t, "AccentDark", { { 0.6, 0.6, 1.6 }, { 0.8, 1.2, 4.6 }, { 0.8, -2, 7.8 } }, 0.8, 0.6)
	end
	ctx.Pal.Hoof = mix(ctx.Pal.Gold, ctx.Look.Primary, 0.35)
	ctx.Pal.Muzzle = lighten(ctx.Look.Primary, 0.4)
	ctx.Pal.Belly = lighten(ctx.Look.Primary, 0.32)
	ctx.Pal.Nostril = mix(darken(ctx.Look.Primary, 0.3), rgb(214, 96, 128), 0.35)
	ctx.Pal.Lash = darken(mix(ctx.Look.Primary, ctx.Look.Eye, 0.5), 0.55)
	ctx.EarX = 5
	ctx.HeadTop = 13.8
	ctx.FlowerAt = { 5, 12.2, -3 }
end

SPECIES.Phoenix = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- a round head on a plump, teardrop body, a lighter breast and face
	head(ctx, "Fur", { 0, 5.6, -0.4 }, { 7.6, 6.8, 6.8 })
	ell(g, "Fur", { 0, -4.2, 1.2 }, { 6.6, 6.6, 6.4 })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.6, -4 }, Radius = { 4.6, 5.6, 3 } }, "Fur")
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, 4, -5.8 }, Radius = { 5.2, 3.6, 2.4 } }, "Fur")
	-- a small hooked golden beak
	cone(g, "Beak", { 0, 4.6, -6.4 }, { 0, 2.4, -8.6 }, 1.3, 0.3)
	-- crest: three flame plumes sweeping up and back, each ending in a glowing tip
	for i = -1, 1 do
		local tip = { i * 3.2, 16.4 - abs(i) * 1.2, 3 }
		curve(g, (i == 0) and "Accent" or "Fur", { { i * 1.2, 11.2, -0.6 }, { i * 2.2, 14.4, 0 }, tip }, 1.3, 0.6)
		ell(g, "Glow", { tip[1], tip[2] + 0.4, tip[3] + 0.6 }, { 0.9, 1.1, 0.9 })
	end
	-- cheek feathers flaring out and back
	pair(function(s)
		cone(g, "Accent", { s * 6.2, 4.4, -1.4 }, { s * 9.6, 3, 1.6 }, 1.8, 0.3)
		cone(g, "Accent", { s * 5.8, 2.4, -1.2 }, { s * 8.6, 0.4, 1.4 }, 1.4, 0.3)
	end)
	-- feet with little talons
	pair(function(s)
		ell(g, "Feet", { s * 2.8, -10.6, -1.6 }, { 1.6, 0.9, 2 })
		cap(g, "Feet", { s * 2.6, -9.2, 0 }, { s * 2.8, -10.4, -1 }, 0.7, 0.6)
	end)
	addEyes(ctx, 5.4, 8.4, "Round")
	broadShade(ctx, { "Fur", "Belly", "Accent" })
	blush(ctx, 5.4, 3.8, 2)
	-- long flowing tail plumes with glowing ends
	local t = newTail(ctx, { 0, -6.6, 5.8 }, 0.18)
	for i = -1, 1 do
		local tip = { i * 3, -4 + abs(i) * 1.4, 11.6 }
		curve(t, (i == 0) and "Accent" or "Fur", { { 0, 0, 0 }, { i * 1.2, -1.2, 4.4 }, { i * 2.4, -3, 8.4 }, tip }, 1.2, 0.6)
		ell(t, "Glow", { tip[1], tip[2] - 0.6, tip[3] + 0.4 }, { 1, 1, 1 })
	end
	ctx.Pal.Glow = { Color = lighten(ctx.Look.Secondary, 0.35), Material = NEON }
	ctx.Pal.Belly = mix(ctx.Look.Secondary, CREAM, 0.3)
	ctx.Pal.Feet = mix(rgb(246, 170, 70), ctx.Look.Secondary, 0.3)
	-- its sparkle is attached: the glowing plume tips (no floating aura voxels for a Secret phoenix)
	ctx.NoAura = true
	ctx.WingHinge = { 5, -1.4, 3.6 }
	ctx.HeadTop = 12.4
	ctx.EarX = 3.6
	ctx.NeckY = -0.6
	ctx.NeckR = { 6.6, 6.4 }
	ctx.NeckZ = 0.6
	ctx.FlowerAt = { 5.6, 10.6, -2.6 }
end

SPECIES.Frog = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- a squat, round frog: a wide head over a plump sitting body, big bulging eye domes on top
	head(ctx, "Fur", { 0, 3.2, -0.6 }, { 9.4, 5.6, 7.2 })
	shape(g, { Kind = "RoundBox", Center = { 0, -4.6, 1 }, Size = { 14, 11.6, 13.4 }, Round = 4.4, Key = "Fur" })
	pair(function(s)
		ell(g, "Fur", { s * 4.8, 7.6, -2.2 }, { 3.6, 3.6, 3.4 })
	end)
	-- light throat and belly
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -2.6, -5.4 }, Radius = { 6.4, 6.4, 3.8 } }, "Fur")
	-- darker spots on the back and the top of the head
	if H then
		for _, p in ipairs({ { 3.4, 6.6, 4.6 }, { -3.6, 4.4, 5.8 } }) do
			paint(g, "Stripe", { Kind = "Ellipsoid", Center = p, Radius = { 1.6, 1.6, 1.6 } }, "Fur")
		end
	end
	-- a wide smile right across the face
	if H then
		face(ctx, "Mouth", { { -5, 2 }, { -4, 1 }, { -3, 1 }, { -2, 1 }, { -1, 1 }, { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1 }, { 4, 1 }, { 5, 2 } })
	else
		face(ctx, "Mouth", { { -2, 1.4 }, { 0, 1 }, { 2, 1.4 } })
	end
	-- short front legs with round webbed feet, big folded hind legs
	pair(function(s)
		cap(g, "Fur", { s * 4, -5, -4.6 }, { s * 4.2, -9.2, -5.4 }, 1.5, 1.3)
		ell(g, "Belly", { s * 4.2, -10.3, -5.8 }, { 2, 0.9, 1.9 })
		ell(g, "Fur", { s * 6.4, -7.4, 2 }, { 2.8, 3.4, 4 })
		ell(g, "Belly", { s * 6.8, -10.4, -1.6 }, { 2, 0.9, 2.4 })
		if H then
			-- toe gaps on the webbed feet
			box(g, "FeetLine", { s * 4, -10.2, -7.4 }, { 0.8, 2, 2 }, { Op = "Paint", OnlyKeys = "Belly" })
		end
	end)
	broadShade(ctx, { "Fur", "Belly" })
	addEyes(ctx, 7, 9.6, "Round")
	blush(ctx, 6.6, 3.2, 2)
	ctx.Pal.Stripe = darken(ctx.Look.Primary, 0.2)
	ctx.Keep.Stripe = true
	ctx.Pal.FeetLine = darken(ctx.Pal.Belly, 0.18)
	ctx.WingHinge = { 5.6, -0.8, 4.6 }
	ctx.HeadTop = 10.4
	ctx.EarX = 4.8
	ctx.NeckY = -1.4
	ctx.NeckR = { 8.4, 7.6 }
	ctx.NeckZ = 0.6
	ctx.FlowerAt = { 6.8, 9.6, -2 }
end

SPECIES.Penguin = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- a round, egg-shaped penguin: a big round head on a plump body, a white tummy and a heart-shaped face
	head(ctx, "Fur", { 0, 5, -0.2 }, { 7.8, 7.2, 7.2 })
	ell(g, "Fur", { 0, -3.8, 0.6 }, { 7.6, 7.6, 7 })
	-- a little curl of feathers on top of the head
	if H then
		curve(g, "Fur", { { 0, 11.6, 0 }, { 0.4, 13.2, -0.4 }, { 1.6, 13.8, -0.8 } }, 1, 0.6)
	end
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.8, -3.6 }, Radius = { 5.6, 7, 4.2 } }, "Fur")
	pair(function(s)
		ell(g, "Belly", { s * 2.9, 4.8, -5.2 }, { 3.6, 4, 2.6 }, { Op = "Paint", OnlyKeys = "Fur" })
		-- flippers resting at the sides, tips turned out a little
		ell(g, "Fur", { s * 7.2, -2.8, 0.8 }, { 1.5, 4.4, 2.6 }, { Rotation = CFrame.Angles(0, 0, s * 0.32) })
		-- orange feet
		ell(g, "Feet", { s * 2.8, -11, -2.2 }, { 1.9, 0.9, 2.4 })
		if H then
			box(g, "FeetLine", { s * 2.8, -11, -4.2 }, { 0.8, 1, 1.6 }, { Op = "Paint", OnlyKeys = "Feet" })
		end
	end)
	-- small orange beak with a darker lower half
	cone(g, "Beak", { 0, 3.8, -6.4 }, { 0, 3.2, -8.8 }, 1.5, 0.4)
	if H then
		box(g, "BeakLow", { 0, 2.8, -7.6 }, { 4, 0.8, 4 }, { Op = "Paint", OnlyKeys = "Beak" })
	end
	addEyes(ctx, 5.2, 7.6, "Round")
	broadShade(ctx, { "Fur" })
	blush(ctx, 5, 3, 3)
	local t = newTail(ctx, { 0, -9, 5.8 }, 0.18)
	cone(t, "Fur", { 0, 0, 0 }, { 0, -1.2, 3.2 }, 2.2, 0.8)
	-- the white face and tummy stay clean (no speckled shading); the dark coat keeps its shades
	ctx.NoShade.Belly = true
	ctx.Pal.BeakLow = darken(ctx.Pal.Beak, 0.18)
	ctx.Pal.FeetLine = darken(ctx.Pal.Feet, 0.2)
	ctx.WingHinge = { 6.4, -0.8, 2.8 }
	ctx.HeadTop = 12.2
	ctx.EarX = 3
	ctx.NeckY = -0.8
	ctx.NeckR = { 6.9, 6.5 }
	ctx.NeckZ = 0.4
	ctx.FlowerAt = { 5, 10.4, -2.8 }
end

SPECIES.Axolotl = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- a big, broad, flat-topped head on a chubby little body with short stubby legs
	head(ctx, "Fur", { 0, 4.6, -0.6 }, { 9, 6.2, 7 })
	ell(g, "Fur", { 0, -5, 2 }, { 6.8, 5, 7 })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -5, -3.4 }, Radius = { 4.6, 4, 2.8 } }, "Fur")
	-- three feathery gills on each side, sweeping up and back, with darker fringes and tips
	pair(function(s)
		for i = -1, 1 do
			local a = { s * 7.6, 6 + i * 2.4, 0.4 }
			local m = { s * 10.4, 7.6 + i * 3, 1.4 }
			local b = { s * 12.2, 10 + i * 3.4, 2.6 }
			curve(g, "Accent", { a, m, b }, 1.1, 0.7)
			ell(g, "AccentDark", b, { 0.9, 0.9, 0.9 })
			if H then
				cap(g, "AccentDark", { m[1], m[2], m[3] }, { m[1] + s * 0.6, m[2] + 1.6, m[3] + 0.4 }, 0.5, 0.4)
			end
		end
	end)
	-- a wide, happy smile
	if H then
		face(ctx, "Mouth", { { -4, 2.2 }, { -3, 1.4 }, { -2, 1 }, { -1, 1 }, { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1.4 }, { 4, 2.2 } })
	else
		face(ctx, "Mouth", { { -2, 1.4 }, { 0, 1 }, { 2, 1.4 } })
	end
	-- short stubby legs with little toes
	pair(function(s)
		cap(g, "Fur", { s * 4.4, -7, -1.8 }, { s * 5, -9.6, -2.4 }, 1.6, 1.3)
		cap(g, "Fur", { s * 4.8, -7, 4.6 }, { s * 5.2, -9.6, 4.4 }, 1.6, 1.3)
		ell(g, "Accent", { s * 5.2, -10.2, -2.8 }, { 1.6, 0.8, 1.6 })
		ell(g, "Accent", { s * 5.4, -10.2, 4 }, { 1.6, 0.8, 1.6 })
	end)
	broadShade(ctx, { "Fur", "Accent" })
	addEyes(ctx, 6.4, 7.8, "Round")
	blush(ctx, 6, 3.4, 3)
	-- paddle tail with a fin along its top
	local t = newTail(ctx, { 0, -7, 6.6 }, 0.35)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, -0.4, 4 }, { 0, 0.6, 8 } }, 2, 1)
	ell(t, "Accent", { 0, 1.4, 5.6 }, { 0.8, 3.2, 4.4 })
	ctx.Pal.Belly = lighten(ctx.Look.Primary, 0.3)
	ctx.WingHinge = { 4.2, -1.4, 4.8 }
	ctx.HeadTop = 10.8
	ctx.EarX = 4
	ctx.NeckY = -0.8
	ctx.NeckR = { 6.2, 6.8 }
	ctx.NeckZ = 1.4
	ctx.FlowerAt = { 4.6, 9.6, -2.6 }
end

-- Stormfang: the player's own creature (ARCHITECTURE_V3.md section 10, branding/stormfang-*.png), sculpted to
-- follow their art: a lean, fierce but cute storm lynx crouched on its storm cloud, ready to pounce. Charcoal
-- armour in four greys (charcoal grooves, mid-grey armour, light plates, pale bevelled edges) with blade spikes
-- sweeping back over the head and spine; a white fluffy face mask (brows sweeping up to the ears, cheeks flaring
-- into a pointed ruff, a white chin) around a grey V-shaped forehead plate that runs down to the nose and holds a
-- cyan diamond gem; tall lynx ears with neon violet and electric-blue inner stripes; fierce slanted glowing eyes
-- with a violet rim carved into the mask; big armoured paws with glowing claws; a fluffy armoured tail with a
-- neon band and a white tip. Its sparkle is attached: neon seams and gems that pulse softly (no floating bits).

-- A cyan diamond gem in a dark bezel, standing out of the surface at the fixed depth zFront (design units): the
-- bezel is a diamond h rows above and below cy, the glowing gem a smaller diamond one voxel in front of it with a
-- bright core and a glass glint at its top tip. Axis-aligned columns, so it merges into a handful of parts.
local function stormGem(g, cx, cy, zFront, h, depth, lean)
	if SK < 1 then
		box(g, "Gem", { cx, cy + 0.4, zFront - 1 }, { 1.6, 3.6, 2 })
		box(g, "GemCore", { cx, cy + 1.4, zFront - 2.6 }, { 1.6, 1.6, 1.6 })
		return
	end
	-- lean > 0 tips the top of the gem back with the forehead (rows above cy + 1 step back)
	local function column(key, x, y0, y1, zf, d)
		local yA = y0
		while yA <= y1 do
			local back = (lean and lean > 0) and floor(max(0, yA - cy - 1) * lean + 0.5) or 0
			local yB = yA
			while yB + 1 <= y1 and ((lean and lean > 0) and floor(max(0, yB + 1 - cy - 1) * lean + 0.5) or 0) == back do
				yB = yB + 1
			end
			box(g, key, { x, (yA + yB) / 2, zf + back + (d - 1) / 2 }, { 1, yB - yA + 1, d })
			yA = yB + 1
		end
	end
	for dx = -2, 2 do
		local hb = floor(h - abs(dx) * 1.5)
		if hb >= 0 then
			column("Base", cx + dx, cy - hb, cy + hb, zFront, depth)
		end
		local hg = floor(h - 1 - abs(dx) * 1.5)
		if hg >= 0 then
			column("Gem", cx + dx, cy - hg, cy + hg, zFront - 1, 1)
		end
	end
	column("GemCore", cx, cy, cy + 1, zFront - 1, 1)
	column("GemRim", cx, cy + h, cy + h, zFront - 1, 1)
end

-- Stormfang's fierce slanted eyes (screen space, the pet's right eye; the left one is its mirror image): S white
-- glint, I glowing iris, G bright core, R violet rim, set into the dark eye band of the mask
local STORM_EYES = {
	High = {
		{ "I S I . .", "R I G I I", ". R R I I" },
		{ "I I I . .", "R I S I I", ". R R I I" },
	},
	Low = {
		{ "S I", "R I" },
		{ "I S", "R I" },
	},
}

local function rbox(g, key, c, size, round)
	return shape(g, { Kind = "RoundBox", Center = c, Size = size, Round = round or 1, Key = key })
end

-- An axis-aligned stepped shape from a to b (design units) in `steps` steps (one box at each end of every step),
-- the full box size interpolated from sa to sb ({x, y, z}). Blades, ears and tufts made of such steps stay crisp
-- like the chunky steps of the art and merge into few parts; every box is at least ~one sculpted voxel thick, so
-- thin blades never vanish at Low detail.
local function stair(g, key, a, b, sa, sb, steps, extra)
	local dx, dy, dz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
	local n = steps or max(1, floor(max(abs(dx), abs(dy), abs(dz)) + 0.5))
	local minSize = 1.2 / SK
	for i = 0, n do
		local t = i / n
		local size = {
			max(minSize, sa[1] + (sb[1] - sa[1]) * t),
			max(minSize, sa[2] + (sb[2] - sa[2]) * t),
			max(minSize, sa[3] + (sb[3] - sa[3]) * t),
		}
		shape(g, withExtra({ Kind = "Box", Center = { a[1] + dx * t, a[2] + dy * t, a[3] + dz * t }, Size = size, Key = key }, extra))
	end
end

SPECIES.Stormfang = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	local look = ctx.Look
	local FUR = { Fur = true }
	local ON_FUR = { Op = "Paint", OnlyKeys = FUR }

	-------------------------------------------------- head: a broad lynx skull, cheeks, a short muzzle
	ell(g, "Fur", { 0, 6.4, -0.6 }, { 7, 6.2, 5.6 })
	pair(function(s)
		ell(g, "Fur", { s * 4.6, 3.2, -2.2 }, { 3.6, 2.8, 3.6 })
	end)
	ell(g, "Fur", { 0, 2.8, -5.6 }, { 2.4, 2.1, 2.4 })
	ell(g, "Fur", { 0, 1.2, -4.6 }, { 2.4, 1.5, 2.4 })
	ctx.HeadC, ctx.HeadR, ctx.HeadTop = { 0, 6.4, -0.6 }, { 7, 6.2, 5.6 }, 12.6

	-- the face, in diagonal bands rising towards the ears (u): a white brow band, the dark eye band, white cheeks
	-- down to the chin; the grey V plate narrows from the forehead down the bridge of the nose
	paint(g, "Mask", { Kind = "Box", Center = { 0, 5, -5.5 }, Size = { 20, 14, 9 }, Pattern = function(x, y, z)
		local ax = abs(x)
		if z > -1.4 - ax * 0.12 then
			return false
		end
		local vHalf = 1 + max(0, y - 3.5) * 0.5
		if y > 2.6 and y < 13 and ax <= vHalf then
			return "Plate"
		end
		local u = y - 0.55 * ax
		if u > 6.8 then
			return false
		elseif u >= 4.6 then
			return "Mask"
		elseif u >= 2.2 then
			return "Lash"
		elseif u >= 0.6 or (ax <= 2.8 and y > -1) then
			return "Mask"
		end
		return false
	end }, FUR)
	-- the cheek ruff: a soft white cheek fan with stepped points flaring out and back; white brow tufts up to the
	-- ear roots
	pair(function(s)
		stair(g, "Mask", { s * 6.8, 4.6, -2 }, { s * 10.6, 4.2, 0.4 }, { 3, 2.4, 3.2 }, { 1.6, 1.6, 1.8 }, 2)
		stair(g, "Mask", { s * 6.4, 2.2, -2.4 }, { s * 9.8, 0.6, 0 }, { 3, 2.4, 3.2 }, { 1.6, 1.6, 1.8 }, 2)
		stair(g, "Mask", { s * 5.8, 9, -2.6 }, { s * 8.6, 10.8, 0 }, { 2.4, 2, 2.4 }, { 1.4, 1.4, 1.6 }, 2)
	end)
	-- dark little nose at the tip of the bridge
	face(ctx, "Nose", H and { { -1, 3.8 }, { 0, 3.8 }, { 1, 3.8 }, { 0, 2.8 } } or { { 0, 3.4 } })

	-------------------------------------------------- crest: a stepped grey blade sweeping back over the head
	stair(g, "Plate", { 0, 11.8, -2.4 }, { 0, 16.2, 4 }, { 2.6, 2.4, 3 }, { 1.2, 1.4, 1.6 }, 4)

	-------------------------------------------------- tall stepped lynx ears: a dark inner panel set into the front face,
	-- a neon violet stripe up its outer edge and an electric-blue one up its inner edge
	pair(function(s)
		local a, b = { s * 4.8, 9.6, 0.6 }, { s * 8.2, 17.6, 1.6 }
		local sa, sb = { 6.4, 2.4, 4 }, { 1.4, 2.4, 1.4 }
		local n = 5
		stair(g, "Fur", a, b, sa, sb, n)
		for i = 0, n - 1 do
			local t = i / n
			local cx, cy = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
			local front = a[3] + (b[3] - a[3]) * t - (sa[3] + (sb[3] - sa[3]) * t) / 2
			local w = sa[1] + (sb[1] - sa[1]) * t - 2.2
			if not ctx.High then
				w = 0 -- Low detail: the stripes below
			elseif w >= 3 then
				box(g, "Base", { cx, cy, front + 0.5 }, { w, 2.4, 1 })
				box(g, "NeonViolet", { cx + s * (w / 2 - 0.5), cy, front + 0.5 }, { 1, 2.4, 1 })
				box(g, "NeonBlue", { cx - s * (w / 2 - 0.5), cy, front + 0.5 }, { 1, 2.4, 1 })
			elseif w >= 1.6 then
				box(g, "NeonViolet", { cx + s * 0.5, cy, front + 0.5 }, { 1, 2.4, 1 })
				box(g, "NeonBlue", { cx - s * 0.5, cy, front + 0.5 }, { 1, 2.4, 1 })
			elseif w >= 0.8 then
				box(g, "NeonBlue", { cx, cy, front + 0.5 }, { 1, 2.4, 1 })
			end
		end
		if not ctx.High then
			-- Low detail (2 design units per voxel): a blue inner and a violet outer column up the front face
			stair(g, "NeonBlue", { s * 6, 11.2, -0.8 }, { s * 7, 15.2, 0.2 }, { 2, 2.4, 2 }, { 2, 2.4, 2 }, 2)
			stair(g, "NeonViolet", { s * 8, 11.2, -0.4 }, { s * 8.4, 15.2, 0.6 }, { 2, 2.4, 2 }, { 2, 2.4, 2 }, 2)
		end
	end)

	-------------------------------------------------- body: crouched, high shoulders, armoured legs, huge paws
	ell(g, "Fur", { 0, -5.4, 2.8 }, { 4.8, 4, 5.8 })
	ell(g, "Fur", { 0, -3.4, -1.2 }, { 4.2, 3.4, 3.2 })
	ell(g, "Fur", { 0, -0.6, 1.6 }, { 4.4, 2.8, 4.4 })
	-- white neck fluff under the chin, ending in a stepped bib
	ell(g, "Mask", { 0, -0.8, -3.2 }, { 3.6, 2, 2.4 })
	pair(function(s)
		-- front legs with an armour ring
		cap(g, "Fur", { s * 3.6, -3.6, -2.4 }, { s * 4, -8.4, -4.6 }, 2, 1.8)
		box(g, "Plate", { s * 4, -6.4, -3.6 }, { 6, 1.4, 6 }, ON_FUR)
		-- big armoured paws: toe grooves and a glowing claw hooking down from every toe
		ell(g, "Plate", { s * 4, -9.6, -6 }, { 2.9, 1.7, 2.8 })
		if H then
			for _, o in ipairs({ -1, 1 }) do
				box(g, "Base", { s * (4 + o), -9.2, -8 }, { 1, 2.6, 2 }, { Op = "Paint", OnlyKeys = { Plate = true } })
			end
			for _, o in ipairs({ -2, 0, 2 }) do
				box(g, "Claw", { s * (4 + o), -10, -8.8 }, { 1, 1.4, 1.2 })
				box(g, "Claw", { s * (4 + o), -11, -9.6 }, { 1, 1, 1 })
			end
		else
			for _, o in ipairs({ -1.4, 1.4 }) do
				box(g, "Claw", { s * (4 + o), -10.6, -9.2 }, { 2.1, 2.1, 2.1 })
			end
		end
		-- haunches (the hind paws sink into the cloud)
		ell(g, "Fur", { s * 4.4, -7.8, 3.6 }, { 2.6, 3, 3.4 })
		-- shoulder plates (pauldrons) with a pale bevelled top and a glowing seam
		rbox(g, "Plate", { s * 5, -2.2, -0.2 }, { 4.6, 4.2, 6 }, 1.4)
		if H then
			box(g, "Bevel", { s * 5, -0.4, -0.2 }, { 6, 1, 8 }, { Op = "Paint", OnlyKeys = { Plate = true } })
		end
		box(g, "NeonBlue", { s * 5.4, -3.2, -0.2 }, { 6, H and 1 or 2, 8 }, { Op = "Paint", OnlyKeys = { Plate = true } })
	end)
	if H then
		-- stepped spine blades
		stair(g, "Plate", { 0, -1.2, 4.2 }, { 0, 1.8, 8.4 }, { 2, 2.2, 2.6 }, { 1.2, 1.2, 1.4 }, 3)
	end

	-------------------------------------------------- face + gems
	-- the eyes: the glint sits a row lower in the left eye, so the two never merge into one part through the head
	local masks = STORM_EYES[ctx.High and "High" or "Low"]
	for i, side in ipairs({ 1, -1 }) do
		local mask = parseMask(masks[i])
		if side < 0 then
			for r, cols in ipairs(mask) do
				local rev = {}
				for c = #cols, 1, -1 do
					rev[#rev + 1] = cols[c]
				end
				mask[r] = rev
			end
		end
		local w = #mask[1]
		local X = vx(6)
		ctx.Eyes[#ctx.Eyes + 1] = { XLeft = (side > 0) and X or -(X - w + 1), Y = vx(7), Mask = mask }
	end
	-- the raised V-shaped forehead plate, stepping down from the brow to the bridge of the nose, holds the gem
	for i, st in ipairs({ { 12, 3.6, -5.4 }, { 10, 3, -6.2 }, { 8, 2.6, -6.6 }, { 6, 2, -6.8 }, { 4.4, 1.2, -6.8 } }) do
		box(g, "Plate", { 0, st[1], st[3] + 1.5 }, { st[2] * 2 + 1, (i == 5) and 1.2 or 2, 3 })
	end
	stormGem(g, 0, 9, -7.4, 3, 2, 0.6)
	stormGem(g, 0, -4.4, -5, 2, 2)

	-------------------------------------------------- fluffy armoured tail curling up: plates, a neon band, a white tuft
	local t = newTail(ctx, { 0, -7.2, 8.2 }, 0.26)
	rbox(t, "Fur", { 0, 0.8, 2.2 }, { 3.6, 3.4, 4.6 }, 1.2)
	stair(t, "Fur", { 0.4, 2.6, 4.2 }, { 2, 8.6, 5.4 }, { 3.6, 3, 3.6 }, { 4.4, 3, 4 }, 3)
	rbox(t, "Mask", { 2.4, 10.4, 5 }, { 4.4, 4, 4.4 }, 1.4)
	if H then
		stair(t, "Mask", { 2.8, 12, 4.6 }, { 3.4, 13.8, 3.2 }, { 2.2, 1.6, 2 }, { 1.2, 1.2, 1.2 }, 2)
		box(t, "Plate", { 1, 4.2, 7 }, { 9, 1.4, 8 }, { Op = "Paint", OnlyKeys = FUR })
	end
	box(t, "NeonBlue", { 1, H and 7.2 or 6.6, 6 }, { 10, H and 1 or 2, 12 }, { Op = "Paint", OnlyKeys = FUR })

	-------------------------------------------------- palette, faithful to the art (the charcoal comes from the Look)
	local P = look.Primary
	local pal = ctx.Pal
	pal.Base = P -- ~#2a2c33 charcoal: grooves, ear insides, bezels
	pal.Fur = mix(P, rgb(96, 99, 110), 0.6) -- ~#4b4d57 armour
	pal.Plate = mix(P, rgb(148, 152, 164), 0.65) -- ~#70737e raised plates and blades
	pal.Bevel = mix(P, rgb(190, 193, 200), 0.82) -- ~#a3a6ae light bevelled edges
	pal.Mask = rgb(242, 244, 248) -- white fluffy mask and ruff
	pal.Mask_Dark = rgb(196, 202, 214)
	pal.Nose = rgb(28, 29, 36)
	pal.Lid = pal.Fur
	pal.LidLine = P
	pal.Lash = P
	local blue = look.Secondary
	pal.NeonViolet = { Color = rgb(122, 60, 255), Material = NEON }
	pal.NeonBlue = { Color = blue, Material = NEON }
	pal.Claw = { Color = mix(blue, rgb(150, 236, 255), 0.35), Material = NEON }
	pal.Gem = { Color = rgb(63, 200, 255), Material = NEON }
	pal.GemCore = { Color = rgb(186, 242, 255), Material = NEON }
	pal.GemRim = { Color = rgb(128, 214, 255), Material = Enum.Material.Glass, Transparency = 0.2 }
	pal.EyeIris = { Color = look.Eye, Material = NEON }
	pal.EyeGlint = { Color = rgb(170, 236, 255), Material = NEON }
	pal.EyeRing = { Color = rgb(122, 60, 255), Material = NEON }
	pal.EyeShine = rgb(252, 252, 255)
	ctx.Pulse = { NeonViolet = true, NeonBlue = true, Claw = true, Gem = true, GemCore = true }
	-- every colour is painted as its own layer: the greys are the shading (no automatic shades) and the LOD never
	-- recolours one layer into another
	for _, k in ipairs({ "Base", "Fur", "Plate", "Bevel", "Mask", "NeonViolet", "NeonBlue", "Claw", "Gem", "GemCore", "GemRim" }) do
		ctx.NoShade[k] = true
		ctx.Keep[k] = true
	end
	-- no floating aura voxels around the player's creature: its sparkle is the attached neon (pulsing seams, gems)
	ctx.NoAura = true
	-- anchors for accessories (other looks may combine them)
	ctx.EarX = 6.4
	ctx.HornBase = { 3.4, 9.6, -0.4 }
	ctx.FlowerAt = { 5, 11, -3.6 }
	ctx.NeckY = -0.4
	ctx.NeckR = { 5.2, 4.8 }
	ctx.NeckZ = -0.6
	ctx.WingHinge = { 0.5, -11, 1.4 }
end

----------------------------------------------------------------------
-- Wings (sculpted in hinge-local design voxels: the LEFT wing reaches towards -X, up is +Y, back is +Z)
----------------------------------------------------------------------
-- a flat feather (lens shaped, 2 voxels thick) from `a` to `b` in the wing plane
local function feather(w, key, a, b, width, extra)
	local dx, dy = b[1] - a[1], b[2] - a[2]
	local len = math.sqrt(dx * dx + dy * dy)
	local c = { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, 0.5 }
	local t = { Kind = "Ellipsoid", Center = c, Radius = { len / 2, width, 0.75 }, Key = key, Rotation = CFrame.Angles(0, 0, math.atan2(dy, dx)), Pivot = c }
	if extra then
		for k, v in pairs(extra) do
			t[k] = v
		end
	end
	return shape(w, t)
end

WINGS.Feather = function(ctx, w)
	local H = ctx.Fine
	-- long flight feathers fanning out (alternating shades, overlapping into one blade with rounded tips),
	-- a row of covert feathers over them and a light leading edge; a flat plate 2 voxels thick
	local tips = { { -14.2, 5 }, { -14.6, 1.6 }, { -13.4, -1.6 }, { -11, -4 }, { -7.6, -5 } }
	for i, tp in ipairs(tips) do
		feather(w, (i % 2 == 0) and "WingTrim" or "Wing", { -2.6, 1.8 }, tp, 1.75)
	end
	ell(w, "Wing", { -6.2, 2, 0.5 }, { 6.6, 2.8, 0.75 })
	ell(w, "WingEdge", { -5.2, 4, 0.5 }, { 6, 2.2, 0.75 })
	if H then
		for _, tp in ipairs(tips) do
			ell(w, "WingTip", { tp[1], tp[2], 0.5 }, { 1.7, 1.7, 1.2 }, { Op = "Paint", OnlyKeys = { Wing = true, WingTrim = true } })
		end
	end
	ctx.Pal.WingTip = darken(ctx.Look.WingColor, 0.3)
end

WINGS.Bat = function(ctx, w)
	local H = ctx.Fine
	-- arm bone along the top edge to a little claw, three finger bones, membrane between them
	curve(w, "WingTrim", { { 0, 0, 0 }, { -5, 4.4, 0.4 }, { -9.6, 6.6, 0.8 } }, 1.1, 0.8)
	ell(w, "Claw", { -10, 7.2, 0.8 }, { 0.8, 0.9, 0.8 })
	local fingers = { { -13.6, 2.6 }, { -11.6, -2.6 }, { -6.6, -4.6 } }
	for _, f in ipairs(fingers) do
		cap(w, "WingTrim", { -9.4, 6.4, 0.8 }, { f[1], f[2], 0.8 }, 0.7, 0.5)
	end
	-- membrane panels: fill between bones, then scallop the trailing edge
	for i = 1, #fingers do
		local a = fingers[i]
		local b = fingers[i + 1] or { -1.6, -0.6 }
		local cx = (a[1] + b[1] + -9.4) / 3
		local cy = (a[2] + b[2] + 6.4) / 3
		ell(w, "Wing", { cx, cy, 0.8 }, { 3.6, 3.8, 0.7 }, { KeepExisting = true })
	end
	ell(w, "Wing", { -5, 2.2, 0.8 }, { 4.6, 3.4, 0.7 }, { KeepExisting = true })
	for i = 1, #fingers do
		local a = fingers[i]
		local b = fingers[i + 1] or { -1.6, -0.6 }
		carve(w, { Kind = "Ellipsoid", Center = { (a[1] + b[1]) / 2 + 0.6, (a[2] + b[2]) / 2 - 1.8, 0.8 }, Radius = { 2, 2, 3 } }, "Wing")
	end
	if H then
		paint(w, "WingEdge", { Kind = "Ellipsoid", Center = { -4.4, 3.2, 0.8 }, Radius = { 3, 1.6, 2 } }, "Wing")
	end
end

WINGS.Fairy = function(ctx, w)
	-- upper and lower translucent lobes (1 voxel thin) with darker veins and bright spots
	ell(w, "Wing", { -6.6, 4.6, 0 }, { 6.2, 4.2, 0.5 })
	ell(w, "Wing", { -4.6, -2.4, 0 }, { 3.8, 2.6, 0.5 })
	if ctx.Fine then
		cap(w, "WingVein", { -1, 1.6, 0 }, { -10.4, 5.6, 0 }, 0.4, 0.3, { Op = "Paint", OnlyKeys = "Wing" })
		cap(w, "WingVein", { -1, 0, 0 }, { -6.6, -2.6, 0 }, 0.4, 0.3, { Op = "Paint", OnlyKeys = "Wing" })
		ell(w, "WingEdge", { -9.8, 3.6, 0 }, { 1.4, 1.4, 1 }, { Op = "Paint", OnlyKeys = "Wing" })
		ell(w, "WingEdge", { -6.2, -3.2, 0 }, { 1, 1, 1 }, { Op = "Paint", OnlyKeys = "Wing" })
	end
	ctx.Pal.Wing = { Color = ctx.Look.WingColor, Transparency = 0.3 }
	ctx.Pal.WingVein = { Color = darken(ctx.Look.WingColor, 0.22), Transparency = 0.1 }
	if not ctx.Look.Glow then
		ctx.Pal.WingEdge = { Color = lighten(ctx.Look.WingColor, 0.55), Transparency = 0.1 }
	end
	ctx.WingNoShade = true
end

WINGS.Cloud = function(ctx, w)
	-- a soft flat feathered fan in the wing colour with darker feather lines, its top edge and tip trimmed
	-- with puffy cloud balls
	for _, tp in ipairs({ { -12.6, 4.4 }, { -12.6, 0.4 }, { -9.8, -3.4 } }) do
		feather(w, "Wing", { -1.6, 1.8 }, tp, 2.3)
		if ctx.Fine then
			feather(w, "WingVein", { -4, 1.8 }, { tp[1] * 0.86, tp[2] * 0.86 }, 0.5, { Op = "Paint", OnlyKeys = "Wing" })
		end
	end
	local puffs = { { -3.6, 4.4, 0.6, 2.4 }, { -7.6, 5.8, 0.6, 2.7 }, { -11.8, 5.6, 0.6, 2.5 }, { -14.4, 2.6, 0.6, 2.1 } }
	for _, p in ipairs(puffs) do
		ell(w, "Cloud", { p[1], p[2], p[3] }, { p[4], p[4] * 0.92, 1.3 })
	end
	ctx.Pal.Cloud = mix(rgb(252, 253, 255), ctx.Look.WingColor, 0.1)
	ctx.Pal.WingVein = darken(ctx.Look.WingColor, 0.2)
	ctx.Pal.Wing = mix(ctx.Look.WingColor, ctx.Look.Secondary, 0.25)
end

WINGS.Crystal = function(ctx, w)
	-- three thin diamond shards fanning out (axis aligned in the wing plane, so they stay crisp), clear with a
	-- lighter core and a bright glint at the tip
	local shards = { { -8, 5.4, 7, 2.2 }, { -9.4, 1, 6.4, 1.8 }, { -6.4, -2.8, 4.6, 1.6 } }
	for _, sh in ipairs(shards) do
		shape(w, { Kind = "Ellipsoid", Center = { sh[1], sh[2], 0 }, Radius = { sh[3], sh[4], 0.5 }, Key = "Wing" })
		if ctx.Fine then
			box(w, "WingCore", { sh[1] + sh[3] * 0.15, sh[2], 0 }, { sh[3] * 0.9, 1, 3 }, { Op = "Paint", OnlyKeys = "Wing" })
			box(w, "WingEdge", { sh[1] - sh[3] * 0.82, sh[2], 0 }, { 1.6, 1, 3 }, { Op = "Paint", OnlyKeys = "Wing" })
		end
	end
	ctx.Pal.Wing = { Color = ctx.Look.WingColor, Transparency = 0.2, Material = Enum.Material.Glass }
	ctx.Pal.WingCore = { Color = lighten(ctx.Look.WingColor, 0.35), Transparency = 0.1, Material = Enum.Material.Glass }
	ctx.Pal.WingEdge = { Color = lighten(ctx.Look.WingColor, 0.6), Material = ctx.Look.Glow and NEON or Enum.Material.SmoothPlastic }
	ctx.WingNoShade = true
end

WINGS.Flame = function(ctx, w)
	-- flat flame tongues licking up and back, hotter (lighter, then glowing) towards the tips
	local tongues = { { -5.6, 9.4 }, { -10.6, 7.6 }, { -13.8, 3.4 }, { -12.4, -1.6 } }
	for _, t in ipairs(tongues) do
		feather(w, "Wing", { -1, 0.8 }, t, 2)
	end
	ell(w, "Wing", { -5, 2.6, 0.5 }, { 4.8, 3.6, 0.75 })
	paint(w, "WingFlame", { Kind = "Ellipsoid", Center = { 0, 0, 0 }, Radius = { 30, 30, 30 }, Pattern = function(x, y)
		local d = x * x + y * y
		if d > 110 then
			return "WingEdge"
		elseif d > 52 then
			return "WingFlame"
		end
		return false
	end }, "Wing")
	ctx.Pal.WingFlame = mix(ctx.Look.WingColor, rgb(255, 214, 96), 0.45)
	ctx.Pal.WingEdge = { Color = mix(rgb(255, 236, 150), ctx.Look.WingColor, 0.2), Material = NEON }
end

-- The little storm cloud Stormfang rides (branding/stormfang-art.png): heaped round navy puffs with lighter blue
-- tops and a few white puff caps, under and around the rider, which sinks into it a little. Like the clouds of
-- the art (and the lobby's), it is made of bigger voxels than the creature: it is always sculpted at the Low
-- resolution and, at High detail, every cloud voxel becomes a 2x2x2 block (chunky cloud cubes, few parts).
-- Its two halves are the WingL / WingR groups (the right half is the mirror image); Animate sways and drifts them
-- gently instead of flapping. Any species can ride it: the cloud is placed under the lowest voxels of the body.
WINGS.StormCloud = function(ctx, w)
	local floorY, midZ = -11.2, 1
	local _, y0, z0, _, _, z1 = Voxel.Bounds(ctx.Body)
	if y0 and SK > 0 then
		floorY = y0 / SK
		midZ = (z0 + z1) / 2 / SK
	end
	ctx.WingHinge = { 0.5, floorY + 1, midZ }
	local fineK = SK
	local up = ctx.High and 2 or 1
	local cg = (up == 2) and Voxel.NewGrid(15) or w
	SK = fineK / up
	local ok, err = pcall(function()
		-- the LEFT half in hinge-local design voxels: a soft cushion under the rider, then round puffs heaped
		-- around it, big and high at the back and the sides, smaller and lower in front (so the paws and claws
		-- hang over the edge); each puff gets a lighter top, the highest ones a white cap
		if not ctx.High then
			-- Low detail (already big voxels): a rounded cushion, a big puff rising at the side and a lighter top
			-- layer
			shape(cg, { Kind = "RoundBox", Center = { -6, -2.4, 0.6 }, Size = { 13, 3.6, 17 }, Round = 1.6, Key = "Wing" })
			ell(cg, "Wing", { -9.6, 0.4, 2.6 }, { 4, 3.2, 5.4 })
			box(cg, "CloudTop", { -8, 3.2, 0 }, { 30, 2.4, 30 }, { Op = "Paint", OnlyKeys = "Wing" })
		else
			ell(cg, "Wing", { -3.6, -2.6, 0.6 }, { 7.6, 2.6, 9 })
			local puffs = {
				{ -10.6, -0.4, 1.4, 4.2 },
				{ -5.6, 0.8, 7.6, 4.2 },
				{ -1.2, 2.4, 9.6, 3 },
				{ -11.2, 2.8, 6.4, 2.6 },
				{ -9.6, -1.8, -5.8, 3.2 },
				{ -4, -3.2, -8.2, 2.6 },
			}
			for _, p in ipairs(puffs) do
				ell(cg, "Wing", { p[1], p[2], p[3] }, { p[4], p[4] * 0.85, p[4] })
			end
			for i = 1, 5 do
				local p = puffs[i]
				ell(cg, "CloudTop", { p[1] + 0.4, p[2] + p[4] * 0.55, p[3] - 0.4 }, { p[4] * 0.85, p[4] * 0.55, p[4] * 0.85 }, { Op = "Paint", OnlyKeys = "Wing" })
			end
			ell(cg, "CloudLight", { -5.2, 4.6, 7.2 }, { 2, 1, 2 })
			ell(cg, "CloudLight", { -10.4, 3.4, 1 }, { 1.8, 1, 2 })
		end
	end)
	SK = fineK
	if not ok then
		error(err, 0)
	end
	if up == 2 then
		-- every cloud voxel -> a 2x2x2 block of fine voxels
		local x0, yy0, zz0, x1, yy1, zz1 = Voxel.Bounds(cg)
		if x0 then
			for x = x0, x1 do
				for y = yy0, yy1 do
					for z = zz0, zz1 do
						local k = get(cg, x, y, z)
						if k then
							for i = 0, 1 do
								for j = 0, 1 do
									for l = 0, 1 do
										set(w, 2 * x + i, 2 * y + j, 2 * z + l, k)
									end
								end
							end
						end
					end
				end
			end
		end
	end
	local navy = ctx.Look.WingColor
	ctx.Pal.Wing = navy -- ~#2e3a66
	ctx.Pal.CloudMid = mix(navy, rgb(107, 119, 168), 0.45) -- ~#44507f
	ctx.Pal.CloudTop = mix(navy, rgb(107, 119, 168), 0.92) -- ~#6b77a8
	ctx.Pal.CloudLight = rgb(236, 240, 250)
	-- the LOD never folds the cloud's lighter layers back into the navy
	ctx.Keep.Wing, ctx.Keep.CloudMid, ctx.Keep.CloudTop, ctx.Keep.CloudLight = true, true, true, true
	ctx.WingTilt = 0
	ctx.WingSweep = 0
	ctx.WingKind = "cloud"
	ctx.WingNoShade = true
end

----------------------------------------------------------------------
-- Accessories (sculpted into the body grid; the Halo is its own floating group)
----------------------------------------------------------------------
ACCESSORIES.Horns = function(ctx)
	local g = ctx.Body
	local hb = ctx.HornBase or { 3.6, ctx.HeadTop - 2.4, ctx.HeadC[3] + 0.4 }
	pair(function(s)
		-- thick at the root, curving up and outwards to a sharp point, with a darker ring near the root
		curve(g, "Horn", { { s * hb[1], hb[2], hb[3] }, { s * (hb[1] + 1.4), hb[2] + 3.6, hb[3] + 0.4 }, { s * (hb[1] + 3.4), hb[2] + 6.2, hb[3] + 1 }, { s * (hb[1] + 5), hb[2] + 7.2, hb[3] + 1.4 } }, 1.8, 0.4)
		if ctx.Fine then
			paint(g, "HornRing", { Kind = "Box", Center = { s * (hb[1] + 0.8), hb[2] + 1.8, hb[3] }, Size = { 5, 0.8, 5 } }, "Horn")
		end
	end)
	ctx.Pal.HornRing = darken(ctx.Pal.Horn, 0.16)
end

ACCESSORIES.Crown = function(ctx)
	local g = ctx.Body
	local top = ctx.HeadTop - 0.6
	-- a golden band with five points and three gems
	shape(g, { Kind = "Torus", Center = { 0, top + 0.6, ctx.HeadC[3] }, Radius = 4.2, Thickness = 1.1, Key = "Gold" })
	box(g, "Gold", { 0, top + 0.6, ctx.HeadC[3] }, { 8, 1.6, 8 }, { KeepExisting = true })
	for i = 0, 4 do
		local a = (i / 5) * TAU + 0.3
		local x, z = math.cos(a) * 4.2, ctx.HeadC[3] + math.sin(a) * 4.2
		cone(g, "Gold", { x, top + 1, z }, { x, top + 4.4, z }, 1.2, 0.2)
		ell(g, "Spark", { x, top + 4.6, z }, { 0.6, 0.6, 0.6 })
	end
	ell(g, "Gem", { 0, top + 1, ctx.HeadC[3] - 4.6 }, { 1, 1, 0.8 })
	pair(function(s)
		ell(g, "GemB", { s * 3.4, top + 1, ctx.HeadC[3] - 3 }, { 0.8, 0.8, 0.8 })
	end)
end

ACCESSORIES.Halo = function(ctx)
	local h = Voxel.NewGrid(30)
	shape(h, { Kind = "Torus", Center = { 0, 0, 0 }, Radius = 4.2, Thickness = 0.6, Key = "HaloGlow" })
	ctx.Halo = h
	ctx.HaloAt = { 0, ctx.HeadTop + 3.2, ctx.HeadC[3] + 0.6 }
	ctx.Pal.HaloGlow = { Color = rgb(255, 222, 120), Material = NEON }
end

ACCESSORIES.Leaf = function(ctx)
	local g = ctx.Body
	local top = ctx.HeadTop
	local z = ctx.HeadC[3] - 1
	cap(g, "Stem", { 0, top - 1.4, z }, { 0.4, top + 2.6, z }, 0.6, 0.5)
	-- the leaf: a tilted flattened ellipsoid with a darker midrib
	ell(g, "Leaf", { 2.8, top + 3.6, z }, { 3.4, 1, 2 }, { Rotation = CFrame.Angles(0, 0, 0.45), Pivot = { 2.8, top + 3.6, z } })
	if ctx.Fine then
		cap(g, "LeafDeep", { 0.6, top + 2.4, z - 0.2 }, { 5, top + 5.4, z - 0.2 }, 0.45, 0.3, { Op = "Paint", OnlyKeys = "Leaf" })
	end
	ell(g, "Leaf", { -1.8, top + 2.4, z + 0.2 }, { 1.8, 0.8, 1.2 }, { Rotation = CFrame.Angles(0, 0, -0.5), Pivot = { -1.8, top + 2.4, z + 0.2 } })
end

ACCESSORIES.Mushroom = function(ctx)
	local g = ctx.Body
	local top = ctx.HeadTop
	local z = ctx.HeadC[3]
	cap(g, "CapSpot", { 0, top - 1.6, z }, { 0, top + 1.6, z }, 1.6, 1.5)
	ell(g, "Cap", { 0, top + 2.6, z }, { 4.6, 2.6, 4.6 })
	carve(g, { Kind = "Box", Center = { 0, top + 0.4, z }, Size = { 12, 2, 12 } }, "Cap")
	local spots = { { 2.6, top + 4.4, z - 2 }, { -2.8, top + 4, z - 1.4 }, { 0, top + 5, z + 1.6 }, { 3.4, top + 3, z + 2 }, { -3.6, top + 3, z + 1.8 } }
	for i, p in ipairs(spots) do
		if ctx.Fine or i <= 2 then
			ell(g, "CapSpot", p, { 1, 0.8, 1 }, { Op = "Paint", OnlyKeys = "Cap" })
		end
	end
end

ACCESSORIES.Scarf = function(ctx)
	local g = ctx.Body
	local y, z = ctx.NeckY, ctx.NeckZ
	local rx, rz = ctx.NeckR[1], ctx.NeckR[2]
	-- a knitted ring around the neck (an elliptic torus: a scaled ring of capsules) and a hanging end
	local n = 14
	local pts = {}
	for i = 0, n do
		local a = i / n * TAU
		pts[#pts + 1] = { math.cos(a) * rx, y, z + math.sin(a) * rz }
	end
	curve(g, "Scarf", pts, 1.6, 1.6, { Smooth = false })
	cap(g, "Scarf", { 2.4, y - 0.6, z - rz - 0.4 }, { 3.4, y - 6, z - rz - 0.6 }, 1.5, 1.5)
	if ctx.Fine then
		local stripe = function(x, yy)
			if floor(yy + 0.5) % 3 == 0 then
				return "ScarfStripe"
			end
			return false
		end
		paint(g, "ScarfStripe", { Kind = "Capsule", A = { 2.4, y - 0.6, z - rz - 0.4 }, B = { 3.4, y - 6, z - rz - 0.6 }, Radius = 1.7, Pattern = stripe }, "Scarf")
		for i = 0, 3 do
			local a = i / 4 * TAU + 0.4
			ell(g, "ScarfStripe", { math.cos(a) * rx, y, z + math.sin(a) * rz }, { 0.8, 2, 0.8 }, { Op = "Paint", OnlyKeys = "Scarf" })
		end
	end
end

ACCESSORIES.Antlers = function(ctx)
	local g = ctx.Body
	local top = ctx.HeadTop
	pair(function(s)
		curve(g, "Antler", { { s * 3, top - 2, 0 }, { s * 4.4, top + 1.4, 0.6 }, { s * 6.6, top + 3.4, 1.2 }, { s * 7.8, top + 5.4, 1.6 } }, 1, 0.6)
		curve(g, "Antler", { { s * 4.6, top + 1.8, 0.6 }, { s * 2.8, top + 3.8, 0.4 }, { s * 2.6, top + 5, 0.4 } }, 0.7, 0.5)
		curve(g, "Antler", { { s * 6.4, top + 3.4, 1.2 }, { s * 8.8, top + 4, 1.4 }, { s * 9.8, top + 5.2, 1.6 } }, 0.65, 0.5)
		ell(g, "AntlerTip", { s * 7.8, top + 5.6, 1.6 }, { 0.6, 0.7, 0.6 })
		ell(g, "AntlerTip", { s * 2.6, top + 5.2, 0.4 }, { 0.6, 0.6, 0.6 })
	end)
	if ctx.Look.Glow then
		ctx.Pal.AntlerTip = { Color = lighten(ctx.Look.Secondary, 0.4), Material = NEON }
	end
end

ACCESSORIES.Flower = function(ctx)
	local g = ctx.Body
	local p = ctx.FlowerAt
	local cx, cy, cz = p[1], p[2], p[3]
	for i = 0, 4 do
		local a = i / 5 * TAU
		ell(g, (i % 2 == 0) and "Petal" or "PetalDeep", { cx + math.cos(a) * 1.8, cy + math.sin(a) * 1.8, cz }, { 1.3, 1.3, 0.9 })
	end
	ell(g, "Pollen", { cx, cy, cz - 0.6 }, { 1, 1, 0.8 })
	if ctx.Fine then
		ell(g, "Leaf", { cx - 1.8, cy - 2.6, cz + 0.6 }, { 1.6, 0.7, 1 })
	end
end

----------------------------------------------------------------------
-- Evolved forms: PetBuilder.Build(petDef, { Evolved = true }) sculpts a bigger, grander version of the pet
-- (about 1.5x as tall) after the player's evolved reference sheet: four-legged and proud (birds stand tall, the
-- slime stays a blob), big fanned wings, and gold jewellery set with the pet's gems (necklaces and pendants,
-- tiaras, crowns, anklets, chest plates). Same groups, rig and animation as the normal form; bigger budgets.
-- Design units are still voxels at High (0.1 stud); the evolved ground is y = EVO.Ground.
----------------------------------------------------------------------
local EVO = { Species = {}, Wings = {}, Pets = {}, Ground = -18 }
local ASC = { Pets = {} } -- the second evolution (Epic and up), see "Second evolution" below

-- the evolved eye (High, sculpted at 1.6x): 10 x 11 voxels, lash line on top, a big highlight top left, a small one
-- lower right, the pupil in a coloured iris that lightens towards the bottom
EYE_MASKS.Evo = {
	". . L L L L . .",
	". L P P P P L .",
	"L S S P P P P L",
	"P S S S P P P P",
	"P S S P P P P I",
	"I P P P P I S I",
	"I I P P I I S I",
	". I G G G G I .",
	". . I G G I . .",
}
-- the fierce evolved eye (dragons, Stormfang): the upper edge slants down towards the nose
EYE_MASKS.EvoFierce = {
	"L L L . . . . .",
	"L L L L L . . .",
	"P S S L L L L .",
	"P S S P P P L L",
	"P S P P P P P I",
	"I P P P P I S I",
	". I G G G I I .",
}
EYE_MASKS.EvoFierceLow = {
	"L L . .",
	"S L L L",
	"S P P I",
	". G G .",
}
EYE_MASKS.EvoLow = {
	". L L .",
	"S S P P",
	"S P P I",
	". G G .",
}

local function evoRGB(t)
	return rgb(t[1], t[2], t[3])
end

-- per pet: gem colours (Gem / GemB), wing colours (Wing = main, Tip = light tips) and extras (see EVO.Pets below)
EVO.Look = {
	biscuit_bear = { Gem = { 226, 40, 58 }, GemB = { 255, 210, 90 }, Wing = { 150, 98, 60 }, Tip = { 244, 222, 190 } },
	honey_bunny = { Gem = { 236, 52, 96 }, GemB = { 80, 196, 250 }, Wing = { 226, 176, 92 }, Tip = { 255, 244, 214 } },
	pip_penguin = { Gem = { 64, 170, 255 }, GemB = { 150, 230, 255 }, Wing = { 44, 60, 108 }, Tip = { 206, 228, 255 } },
	twilight_dragon = { Gem = { 255, 84, 170 }, GemB = { 255, 210, 90 }, Wing = { 112, 70, 200 }, Tip = { 236, 130, 214 } },
}

----------------------------------------------------------------------
-- evolved anatomy
----------------------------------------------------------------------
-- Four-legged body: chest, barrel and haunch, tapered legs with round paws, a thick neck rising to the head.
-- o: W (width), L (length), Leg (leg length, 1 = normal), LegKey, PawKey, BellyKey (false = none), Toes (false)
function EVO.Quad(ctx, o)
	local g = ctx.Body
	o = o or {}
	local W, L, leg = (o.W or 1) * 1.08, (o.L or 1) * 0.88, (o.Leg or 1) * 0.84
	if ctx.Ascended then
		leg = leg * 1.2 -- the second evolution stands taller
	end
	local G0 = EVO.Ground
	local legK, pawK = o.LegKey or "Fur", o.PawKey or "Belly"
	local by = -6.5 + (leg - 1) * 5 -- barrel centre height
	ell(g, "Fur", { 0, by, 2 * L }, { 8.2 * W, 7.2, 10.6 * L })
	ell(g, "Fur", { 0, by + 1.8, -4.8 * L }, { 8.8 * W, 8, 7.2 })
	ell(g, "Fur", { 0, by + 0.6, 9.2 * L }, { 8.6 * W, 7.6, 7 })
	if o.BellyKey ~= false then
		local bk = o.BellyKey or "Belly"
		paint(g, bk, { Kind = "Ellipsoid", Center = { 0, by + 1.2, -11 * L }, Radius = { 5.8 * W, 6.8, 3.6 } }, "Fur")
		paint(g, bk, { Kind = "Ellipsoid", Center = { 0, by - 6.6, 1.5 * L }, Radius = { 5.2 * W, 2.2, 9.5 * L } }, "Fur")
	end
	local fz, hz = -6.4 * L, 10.4 * L
	local top = by - 1.5
	pair(function(s)
		cap(g, legK, { s * 5.1 * W, top, fz }, { s * 5.3 * W, G0 + 3, fz - 0.4 }, 3.8, 3.3)
		ell(g, pawK, { s * 5.3 * W, G0 + 1.7, fz - 1.4 }, { 3.6, 1.9, 4.1 })
		ell(g, legK, { s * 5.8 * W, by - 0.8, hz }, { 4.3, 6, 5.8 })
		cap(g, legK, { s * 6 * W, by - 4.5, hz + 1.8 }, { s * 5.8 * W, G0 + 3, hz - 0.2 }, 3.5, 3.2)
		ell(g, pawK, { s * 5.8 * W, G0 + 1.7, hz - 1.2 }, { 3.6, 1.9, 4.1 })
		if ctx.Fine and o.Toes ~= false then
			local toe = o.ToeKey or "Toe"
			for _, p in ipairs({ { s * 5.3 * W, fz - 1.3 }, { s * 5.8 * W, hz - 1.1 } }) do
				for _, dx in ipairs({ -1, 1 }) do
					box(g, toe, { p[1] + dx, G0 + 1.4, p[2] - 3 }, { 0.6, 2.4, 1.6 }, { Op = "Paint", OnlyKeys = pawK })
				end
			end
		end
	end)
	cap(g, "Fur", { 0, by + 2.5, -6.6 * L }, { 0, by + 10, -9 * L }, 6.6 * W, 6.2)
	if o.Tufts and ctx.Fine then
		for i = 0, 6 do
			local z = -4 * L + i * 3.2 * L
			local x = ((i % 2 == 0) and 1.6 or -1.6)
			cone(g, "Fur", { x, by + 6, z }, { x * 1.4, by + 9.6, z + 1.8 }, 1.6, 0.3)
		end
		pair(function(s)
			for i = 0, 3 do
				local z = -7 * L + i * 4.2 * L
				cone(g, "Fur", { s * 7.4 * W, by + 2.5 - i * 0.4, z }, { s * 10 * W, by + 3.6 - i * 0.4, z + 2 }, 1.5, 0.3)
			end
			cone(g, "Fur", { s * 7.6 * W, by - 1, hz + 2 }, { s * 10 * W, by - 3, hz + 4.6 }, 1.6, 0.3)
		end)
	end
	ctx.NeckY, ctx.NeckZ, ctx.NeckR = by + 6.5, -8.2 * L, { 6.6 * W, 6.4 }
	ctx.ChestZ = -6.6 * L - 6.6 * W -- front of the chest (breast plates)
	ctx.WingHinge = { 7.6 * W, by + 7.2, -2.6 * L }
	ctx.TailHinge = { 0, by + 2.6, 15.6 * L }
	ctx.Legs = { Front = { 5.3 * W, fz }, Hind = { 5.8 * W, hz } }
	ctx.EvoBelly = by
	return by
end

-- big round head on the neck (design centre relative to the barrel), remembered for faces and jewellery
function EVO.Head(ctx, r, key, dy, dz)
	local by = ctx.EvoBelly or -6.5
	local c = { 0, by + 15.8 + (dy or 0), -11.5 + (dz or 0) }
	head(ctx, key or "Fur", c, r)
	shape(ctx.Body, { Kind = "RoundBox", Center = { c[1], c[2] + 0.3, c[3] + 0.6 }, Size = { r[1] * 1.78, r[2] * 1.72, r[3] * 1.7 }, Round = math.min(r[1], r[2]) * 0.5, Key = key or "Fur" })
	ctx.HeadTop = c[2] + r[2]
	ctx.EarX = r[1] * 0.7
	return c
end

-- the evolved face: big sparkly eyes, a soft nose, a smile and blush. o: EyeX (outer column), EyeY (top row)

function EVO.Face(ctx, c, o)
	o = o or {}
	addEyes(ctx, (o.EyeX or 8) + 0.4, c[2] + (o.EyeY or 3.5) + 0.4, o.Fierce and "EvoFierce" or "Evo", o.Fierce)
	cuteEyes(ctx)
	if o.Blush ~= false then
		local r = ctx.HeadR
		pair(function(s)
			paint(ctx.Body, "Blush", { Kind = "Ellipsoid", Center = { s * ((o.EyeX or 8) - 1.5), c[2] - 3.6, c[3] - r[3] + 0.5 }, Radius = { 2.4, 1.1, 3.2 } })
		end)
	end
end

-- upright bird body (penguin, owl, phoenix): a tall egg on two feet. Returns the head centre.
function EVO.Bird(ctx, o)
	local g = ctx.Body
	o = o or {}
	local G0 = EVO.Ground
	ell(g, "Fur", { 0, -4, 0.5 }, { 11.6, 13.8, 10.6 })
	if o.BellyKey ~= false then
		paint(g, o.BellyKey or "Belly", { Kind = "Ellipsoid", Center = { 0, -5, -5 }, Radius = { 8.4, 11.4, 6 } }, "Fur")
	end
	pair(function(s)
		cap(g, "Feet", { s * 4.6, G0 + 4, 0 }, { s * 4.8, G0 + 1.6, -1 }, 1.6, 1.4)
		for _, dx in ipairs({ -1.8, 0, 1.8 }) do
			cap(g, "Feet", { s * 4.8 + dx * 0.4, G0 + 1, -1 }, { s * 4.8 + dx, G0 + 0.8, -5.2 }, 1.1, 0.8)
		end
	end)
	ctx.NeckY, ctx.NeckZ, ctx.NeckR = 6.5, -0.5, { 9.4, 8.6 }
	ctx.WingHinge = { 6.4, 4, 2.2 }
	ctx.TailHinge = { 0, G0 + 6, 9 }
	ctx.EvoBelly = -6.5
	local c = { 0, 12.5, -1 }
	head(ctx, "Fur", c, o.HeadR or { 10.4, 9, 9.4 })
	ctx.HeadTop = c[2] + (o.HeadR or { 10.4, 9, 9.4 })[2]
	return c
end

----------------------------------------------------------------------
-- evolved jewellery (gold set with the pet's gems)
----------------------------------------------------------------------
-- a gold chain around the neck, drooping at the front, with a pendant: gold setting + gem + glint
function EVO.Necklace(ctx, o)
	local g = ctx.Body
	o = o or {}
	local y, z, r = ctx.NeckY + (o.DY or 0), ctx.NeckZ, ctx.NeckR
	local tilt = o.Tilt or 0.42
	local R = (o.R or r[1]) + 0.5
	shape(g, { Kind = "Torus", Center = { 0, y, z }, Radius = R, Thickness = 1.05, Key = "Gold", Rotation = CFrame.Angles(-tilt, 0, 0), Pivot = { 0, y, z } })
	if o.Double then
		shape(g, { Kind = "Torus", Center = { 0, y - 2.2, z - 0.6 }, Radius = R + 0.6, Thickness = 0.6, Key = "GoldDeep", Rotation = CFrame.Angles(-tilt - 0.15, 0, 0), Pivot = { 0, y - 2.2, z - 0.6 } })
	end
	local fy, fz = y - R * math.sin(tilt), z - R * math.cos(tilt)
	if o.Pendant ~= false then
		local s = (o.Size or 1) * 1.3
		ell(g, "GoldDeep", { 0, fy - 2 * s, fz - 0.6 }, { 2.4 * s, 2.8 * s, 1.1 })
		ell(g, "Gold", { 0, fy - 2 * s, fz - 1.1 }, { 1.9 * s, 2.3 * s, 0.9 })
		ell(g, o.Gem or "Gem", { 0, fy - 2 * s, fz - 1.8 }, { 1.3 * s, 1.6 * s, 0.8 })
		cone(g, "Gold", { 0, fy - 4.4 * s, fz - 0.9 }, { 0, fy - 6 * s, fz - 1 }, 0.9, 0.2)
		set(g, vx(-0.5), vx(fy - 1.4 * s), vx(fz - 2.6), "Spark")
	end
	-- little gem drops along the chain
	for i = 1, (o.Drops or 0) do
		local a = (i - (o.Drops + 1) / 2) * 0.42
		local x, zz = math.sin(a) * R, z - math.cos(a) * R * math.cos(tilt)
		local yy = y - math.cos(a) * R * math.sin(tilt)
		ell(g, (i % 2 == 0) and (o.Gem or "Gem") or "GemB", { x, yy - 1.2, zz - 0.5 }, { 0.8, 0.9, 0.7 })
	end
	ctx.Pendant = { 0, fy - 2, fz - 1.8 }
end

-- a gold circlet around the head with a jewelled peak over the forehead
function EVO.Tiara(ctx, o)
	local g = ctx.Body
	o = o or {}
	local c, r = ctx.HeadC, ctx.HeadR
	local h = o.H or 4.2
	local ry = h / r[2]
	local R = r[1] * math.sqrt(math.max(0.05, 1 - ry * ry)) + 0.3
	local y = c[2] + h
	shape(g, { Kind = "Torus", Center = { 0, y, c[3] + 0.4 }, Radius = R, Thickness = 0.8, Key = "Gold", Rotation = CFrame.Angles(0.18, 0, 0), Pivot = { 0, y, c[3] + 0.4 } })
	local fz = c[3] - r[3] * math.sqrt(math.max(0.05, 1 - ry * ry)) - 0.2
	local fy = y + 0.6
	ell(g, "GoldDeep", { 0, fy + 1.4, fz }, { 3.2, 3.6, 1.1 })
	ell(g, "Gold", { 0, fy + 1.4, fz - 0.4 }, { 2.5, 2.9, 1 })
	ell(g, o.Gem or "Gem", { 0, fy + 1.4, fz - 1.1 }, { 1.7, 2, 0.9 })
	cone(g, "Gold", { 0, fy + 3.4, fz + 0.4 }, { 0, fy + 6.4, fz + 0.8 }, 1, 0.2)
	pair(function(s)
		cone(g, "Gold", { s * 2.6, fy + 1.6, fz + 0.4 }, { s * 4.2, fy + 4, fz + 0.9 }, 0.8, 0.2)
		if o.Side ~= false then
			ell(g, "GemB", { s * 4.6, fy + 0.2, fz + 1.4 }, { 0.8, 0.8, 0.7 })
		end
	end)
	set(g, vx(-0.6), vx(fy + 1.8), vx(fz - 1.8), "Spark")
end

-- a tall gold crown on top of the head: band, points with gold balls, gems around the band
function EVO.Crown(ctx, o)
	local g = ctx.Body
	o = o or {}
	local c = ctx.HeadC
	local top = ctx.HeadTop - (o.Sink or 2.2)
	local R = o.R or 5.6
	local n = o.Points or 7
	shape(g, { Kind = "Torus", Center = { 0, top + 0.8, c[3] }, Radius = R, Thickness = 1.2, Key = "GoldDeep" })
	shape(g, { Kind = "Torus", Center = { 0, top + 2.4, c[3] }, Radius = R + 0.2, Thickness = 1.1, Key = "Gold" })
	for i = 0, n - 1 do
		local a = (i / n) * TAU - math.pi / 2
		local x, z = math.cos(a) * (R + 0.2), c[3] + math.sin(a) * (R + 0.2)
		local hgt = (i == 0) and 6 or 4.4
		cone(g, "Gold", { x, top + 2.6, z }, { x * 1.08, top + 2.6 + hgt, z + (z - c[3]) * 0.08 }, 1.3, 0.3)
		ell(g, "GoldLight", { x * 1.08, top + 3 + hgt, z + (z - c[3]) * 0.08 }, { 0.8, 0.8, 0.8 })
		if i % 2 == 1 then
			ell(g, "GemB", { x * 1.12, top + 1.6, z + (z - c[3]) * 0.12 }, { 0.8, 0.9, 0.8 })
		end
	end
	ell(g, o.Gem or "Gem", { 0, top + 2, c[3] - R - 1.1 }, { 1.4, 1.7, 0.8 })
	set(g, vx(-0.6), vx(top + 2.6), vx(c[3] - R - 2), "Spark")
end

-- gold anklets above the paws (with a small gem in front)
function EVO.Anklets(ctx, o)
	local g = ctx.Body
	o = o or {}
	local L = ctx.Legs
	if not L then
		return
	end
	local y = EVO.Ground + (o.Y or 4.2)
	pair(function(s)
		for _, p in ipairs({ L.Front, L.Hind }) do
			shape(g, { Kind = "Torus", Center = { s * p[1], y, p[2] + 0.1 }, Radius = 2.7, Thickness = 0.65, Key = "Gold" })
			if o.Gem ~= false then
				ell(g, o.Gem or "Gem", { s * p[1], y, p[2] - 3.3 }, { 0.7, 0.8, 0.6 })
			end
		end
	end)
end

-- a gold breast plate on the chest with a big gem
function EVO.ChestPlate(ctx, o)
	local g = ctx.Body
	o = o or {}
	local by = ctx.EvoBelly or -6.5
	paint(g, "GoldDeep", { Kind = "Ellipsoid", Center = { 0, by + 1.5, -12.5 }, Radius = { 6.4, 6, 3.4 } })
	paint(g, "Gold", { Kind = "Ellipsoid", Center = { 0, by + 1.7, -13.2 }, Radius = { 5.4, 5.2, 3 } })
	ell(g, o.Gem or "Gem", { 0, by + 2, -13.4 }, { 1.7, 2, 1 })
	set(g, vx(-0.6), vx(by + 2.8), vx(-14.6), "Spark")
end

----------------------------------------------------------------------
-- evolved wings (the LEFT wing in its hinge frame, reaching towards -X; the hinge sweeps it back so the fan rises
-- from the shoulders up and back over the body)
----------------------------------------------------------------------

local function evoFeather(w, key, a, b, width, z, extra)
	local dx, dy = b[1] - a[1], b[2] - a[2]
	local len = math.sqrt(dx * dx + dy * dy)
	local c = { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, z }
	local t = { Kind = "Ellipsoid", Center = c, Radius = { len / 2, width, 0.75 }, Key = key, Rotation = CFrame.Angles(0, 0, math.atan2(dy, dx)), Pivot = c }
	if extra then
		for k, v in pairs(extra) do
			t[k] = v
		end
	end
	return shape(w, t)
end

-- big raised wing of long pointed feathers (the LEFT wing in its hinge frame, reaching towards -X; 90 deg = up,
-- 180 = out): a back row of long primaries fanning from A0 to A1 with light tips, a front row of shorter
-- secondaries, scalloped coverts over the roots and a light leading edge. o: N, A0, A1, L0, L1, W, Sweep, Tilt
function EVO.Fan(ctx, w, o)
	o = o or {}
	local S = o.Size or 0.8
	local a0, a1 = o.A0 or 80, o.A1 or 186 -- left wing frame: 90 = up, 180 = straight out (the hinge turns it back)
	local fw = o.Width or 3.4
	local function quill(key, deg, r0, ln, wd, z, tip, hot)
		local ang = math.rad(deg)
		local dx, dy = math.cos(ang), math.sin(ang)
		local a = { dx * r0, dy * r0 }
		local b = { dx * (r0 + ln), dy * (r0 + ln) }
		evoFeather(w, key, a, b, wd, z)
		if tip and ctx.Fine then
			local tc = { b[1] - dx * ln * 0.2, b[2] - dy * ln * 0.2, z }
			shape(w, { Kind = "Ellipsoid", Center = tc, Radius = { ln * 0.26, wd + 0.6, 1.2 }, Key = tip, Op = "Paint", OnlyKeys = { [key] = true }, Rotation = CFrame.Angles(0, 0, ang), Pivot = tc })
		end
		if hot then
			-- glowing tips (second evolution)
			local gc = { b[1] - dx * ln * 0.07, b[2] - dy * ln * 0.07, z }
			shape(w, { Kind = "Ellipsoid", Center = gc, Radius = { ln * 0.13, wd + 0.6, 1.2 }, Key = "WingGlow", Op = "Paint", OnlyKeys = { [key] = true, [tip or key] = true }, Rotation = CFrame.Angles(0, 0, ang), Pivot = gc })
		end
	end
	-- back layer: long flight feathers fanning from up to out, broad and overlapping, light tips
	local n = o.N or 6
	for i = n - 1, 0, -1 do
		local t = i / (n - 1)
		local ln = 12 + 15 * math.sin(math.pi * (0.22 + 0.62 * (1 - math.abs(t - 0.38) / 0.62) * 0.8))
		if t > 0.38 then
			ln = 12 + (ln - 12) * (1 - (t - 0.38) / 0.62 * 0.55)
		end
		local key = o.Keys and o.Keys[i % #o.Keys + 1] or ((i % 2 == 0) and "Wing" or "WingTrim")
		quill(key, a0 + (a1 - a0) * t, 2.5, ln * S * (o.Long or 1), fw, 0, "WingTip", o.Glow)
	end
	-- middle layer: shorter, lighter feathers
	for i = 4, 0, -1 do
		local t = i / 4
		quill((i % 2 == 0) and "WingCov" or "WingCov2", a0 + 8 + (a1 - a0 - 16) * t, 2, (10 + 3 * (1 - math.abs(t - 0.4))) * S, o.CovWidth or 3.4, 1, "WingTip")
	end
	-- coverts: small rounded feathers over the roots
	for i = 3, 0, -1 do
		local t = i / 3
		quill((i % 2 == 0) and "WingCov2" or "WingCov", a0 + 10 + (a1 - a0 - 20) * t, 1.5, 5.8 * S, 3, 1.8, nil)
	end
	ell(w, "WingCov2", { -1.2, 1.4, 1.8 }, { 3.4, 3.4, 0.75 })
	-- a light leading edge along the top feather (gold on the second evolution)
	local ae = math.rad(a0 + 3)
	evoFeather(w, o.EdgeKey or "WingEdge", { math.cos(ae) * 2, math.sin(ae) * 2 }, { math.cos(ae) * 14 * S, math.sin(ae) * 14 * S }, o.EdgeWidth or 1.3, 1.6)
	ctx.WingSweep = o.Sweep or 0.95
	ctx.WingTilt = o.Tilt or 0.42
end


-- dragon / bat wing for the evolved dragons: an arm bone up to a clawed wrist, four long finger bones fanning up
-- and back, a membrane between them (point-in-polygon fill) with a scalloped trailing edge, lighter near the edge
function EVO.BatWing(ctx, w, o)
	o = o or {}
	local S = o.Size or 1
	local R = 0.6 + 0.4 * S -- bone thickness follows the size a little
	local wrist = { -7 * S, 13 * S }
	curve(w, "WingBone", { { 0, 0, 0.5 }, { -3.6 * S, 7 * S, 0.5 }, { wrist[1], wrist[2], 0.5 } }, 1.6 * R, 1.2 * R)
	ell(w, "Claw", { wrist[1] + 0.6, wrist[2] + 2 * R, 0.5 }, { 1 * R, 2 * R, 1 })
	local tips = o.Tips
	if not tips then
		tips = {}
		for i, tp in ipairs({ { -22, 27 }, { -32, 15 }, { -31, 2 }, { -22, -8 } }) do
			tips[i] = { tp[1] * S, tp[2] * S }
		end
	end
	for _, tp in ipairs(tips) do
		curve(w, "WingBone", { { wrist[1], wrist[2], 0.5 }, { (wrist[1] + tp[1]) / 2, (wrist[2] + tp[2]) / 2 + 1.4 * S, 0.5 }, { tp[1], tp[2], 0.5 } }, 1.1 * R, 0.5 * R)
		cone(w, "WingBone", { tp[1], tp[2], 0.5 }, { tp[1] - 1.6 * R, tp[2] + 1.6 * R, 0.5 }, 0.7 * R, 0.2)
	end
	local base = { -7 * S, -6 * S }
	local poly = { { 0, 0 }, { -3.6 * S, 7 * S }, wrist }
	for _, tp in ipairs(tips) do
		poly[#poly + 1] = tp
	end
	poly[#poly + 1] = base
	local scallops = {}
	local chain = {}
	for _, tp in ipairs(tips) do
		chain[#chain + 1] = tp
	end
	chain[#chain + 1] = base
	for i = 1, #chain - 1 do
		local a, b = chain[i], chain[i + 1]
		local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
		local dx, dy = b[1] - a[1], b[2] - a[2]
		local d = math.sqrt(dx * dx + dy * dy)
		local nx, ny = -dy / d, dx / d
		if (wrist[1] - mx) * nx + (wrist[2] - my) * ny > 0 then
			nx, ny = -nx, -ny
		end
		scallops[#scallops + 1] = { mx + nx * d * 0.32, my + ny * d * 0.32, d * 0.5 }
	end
	local function inside(x, y)
		local c = false
		local j = #poly
		for i = 1, #poly do
			local xi, yi, xj, yj = poly[i][1], poly[i][2], poly[j][1], poly[j][2]
			if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then
				c = not c
			end
			j = i
		end
		return c
	end
	local glow = o.Glow and (o.GlowWidth or 1.3) or nil
	box(w, "Wing", { -16 * S, 9 * S, 0.5 }, { 36 * S, 42 * S, 1.4 }, { KeepExisting = true, Pattern = function(x, y)
		if not inside(x, y) then
			return false
		end
		local edge = math.huge
		for _, sc in ipairs(scallops) do
			local d = math.sqrt((x - sc[1]) ^ 2 + (y - sc[2]) ^ 2) - sc[3]
			if d < 0 then
				return false
			end
			edge = math.min(edge, d)
		end
		if glow and edge < glow then
			return "WingGlow" -- a glowing trailing edge (second evolution)
		end
		local r = math.sqrt((x - wrist[1]) ^ 2 + (y - wrist[2]) ^ 2)
		if r > 17 * S then
			return "WingTip"
		end
		return nil
	end })
	ctx.Pal.WingBone = ctx.Pal.WingBone or darken(ctx.Look.WingColor, 0.35)
	ctx.WingSweep = o.Sweep or 1.32
	ctx.WingTilt = o.Tilt or 0.22
end

-- the phoenixes' wings: spread like a firebird's, an arm rising out from the shoulder, long pointed flame feathers
-- trailing out and down with glowing tips (the LEFT wing in its hinge frame: -X is out, +Y is up)
function EVO.FlameWing(ctx, w, o)
	o = o or {}
	local S = o.Size or 1
	local Wd = 0.55 + 0.45 * S -- plume width follows the size a little
	local arm = { { 0, 0 }, { -5 * S, 5.5 * S }, { -11 * S, 9.5 * S }, { -17 * S, 12 * S }, { -22 * S, 12.5 * S } }
	local function armAt(t)
		local f = t * (#arm - 1)
		local i = math.min(#arm - 1, floor(f) + 1)
		local u = f - (i - 1)
		local a, b = arm[i], arm[i + 1]
		return { a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u }
	end
	local function plume(key, p, deg, ln, wd, z, hot)
		local ang = math.rad(deg)
		local dx, dy = math.cos(ang), math.sin(ang)
		local b = { p[1] + dx * ln, p[2] + dy * ln }
		evoFeather(w, key, p, b, wd, z)
		if hot then
			local tc = { b[1] - dx * ln * 0.2, b[2] - dy * ln * 0.2, z }
			shape(w, { Kind = "Ellipsoid", Center = tc, Radius = { ln * 0.26, wd + 0.6, 1.2 }, Key = "WingTip", Op = "Paint", OnlyKeys = { [key] = true }, Rotation = CFrame.Angles(0, 0, ang), Pivot = tc })
		end
	end
	local np = o.N or 5
	for i = np, 0, -1 do
		local f = i / np
		plume((i % 2 == 0) and "Wing" or "WingTrim", armAt(0.42 + 0.58 * f), 240 - 54 * f, (11 + 7 * f) * S * (o.Long or 1), 2.3 * Wd, 0, true)
	end
	for i = 4, 0, -1 do
		local f = i / 4
		plume((i % 2 == 0) and "WingTrim" or "Wing", armAt(0.04 + 0.38 * f), 270 - 24 * f, (9 + 2.4 * f) * S, 2.5 * Wd, 0.4, true)
	end
	for i = 6, 0, -1 do
		local f = i / 6
		plume((i % 2 == 0) and "WingCov" or "WingCov2", armAt(0.04 + 0.86 * f), 258 - 60 * f, 5.6 * S, 2.4 * Wd, 1.2, false)
	end
	local pts = {}
	for i, a in ipairs(arm) do
		pts[i] = { a[1], a[2] + 0.6, 1 }
	end
	curve(w, o.EdgeKey or "WingEdge", pts, 1.5 * Wd, 0.9 * Wd, { Smooth = true })
	ctx.WingSweep = o.Sweep or 0.55
	ctx.WingTilt = o.Tilt or 0.55
end

-- palette for the evolved wings and jewellery
function EVO.Palette(ctx)
	local pal, look = ctx.Pal, ctx.Look
	local st = EVO.Look[look.Id] or {}
	local W = st.Wing and evoRGB(st.Wing) or look.WingColor
	local tip = st.Tip and mix(evoRGB(st.Tip), W, 0.25) or lighten(W, 0.45)
	pal.Wing = W
	pal.WingTrim = darken(W, 0.24)
	pal.WingTip = tip
	pal.WingCov = mix(W, tip, 0.18)
	pal.WingCov2 = mix(W, tip, 0.4)
	pal.WingEdge = mix(tip, rgb(255, 255, 255), 0.4)
	pal.Gold = rgb(250, 200, 70)
	pal.GoldDeep = rgb(214, 146, 40)
	pal.GoldLight = rgb(255, 232, 150)
	pal.Gem = st.Gem and evoRGB(st.Gem) or rgb(232, 60, 100)
	pal.GemB = st.GemB and evoRGB(st.GemB) or rgb(84, 172, 238)
	pal.Gem = { Color = pal.Gem, Material = NEON }
	pal.GemB = { Color = pal.GemB, Material = NEON }
	if look.Glow then
	end
	pal.Toe = darken(asColor(pal.Belly, look.Primary), 0.3)
	return st
end

----------------------------------------------------------------------
-- evolved species
----------------------------------------------------------------------
EVO.Species.Bear = function(ctx)
	local g = ctx.Body
	ctx.Pal.Nose = rgb(58, 40, 40)
	EVO.Quad(ctx, { W = 1.12, L = 0.95, PawKey = "Muzzle", ToeKey = "Toe" })
	local c = EVO.Head(ctx, { 10.8, 9.6, 9.8 })
	pair(function(s)
		ell(g, "Fur", { s * 6, c[2] - 3, c[3] - 3.4 }, { 4.6, 3.8, 4.4 }) -- cheeks
		roundEar(ctx, s, { 7.4, c[2] + 7.6, c[3] + 0.8 }, 3.6, "Fur", "Muzzle")
	end)
	ell(g, "Muzzle", { 0, c[2] - 3.8, c[3] - 8.8 }, { 5.4, 4, 3.9 })
	ell(g, "Nose", { 0, c[2] - 1.6, c[3] - 12.4 }, { 2.4, 1.4, 1.3 })
	ell(g, "Nose", { 0, c[2] - 2.8, c[3] - 12.1 }, { 1.1, 0.9, 1 })
	if ctx.Fine then
		shine(ctx, -1, c[2] - 1.4)
		face(ctx, "Mouth", { { 0, c[2] - 4 }, { 1, c[2] - 4.8 }, { -1, c[2] - 4.8 }, { 2, c[2] - 4.4 }, { -2, c[2] - 4.4 } })
	end
	EVO.Face(ctx, c, { EyeX = 8, EyeY = 3.6 })
	shadeMain(ctx, { "Fur" })
	local t = newTail(ctx, ctx.TailHinge, 0.2)
	ell(t, "Fur", { 0, 0.5, 1.5 }, { 2.8, 2.8, 2.8 })
end

EVO.Species.Bunny = function(ctx)
	local g = ctx.Body
	EVO.Quad(ctx, { W = 0.98, L = 0.92, PawKey = "Muzzle" })
	-- big hind haunches
	pair(function(s)
		ell(g, "Fur", { s * 6, ctx.EvoBelly + 0.4, 9 }, { 4.6, 7, 6.6 })
	end)
	local c = EVO.Head(ctx, { 10, 9.2, 9.4 }, nil, -0.5)
	pair(function(s)
		ell(g, "Fur", { s * 5.6, c[2] - 3.2, c[3] - 3.6 }, { 4.4, 3.6, 4.2 })
		-- long upright ears, slightly apart, with pink insides
		local bx = s * 3.6
		curve(g, "Fur", { { bx, c[2] + 6.5, c[3] + 1 }, { s * 4.6, c[2] + 13, c[3] + 1.8 }, { s * 5.6, c[2] + 19, c[3] + 2.8 }, { s * 6.2, c[2] + 23, c[3] + 3.6 } }, 2.7, 1.6, { Smooth = true })
		paint(g, "Inner", { Kind = "Curve", Points = { { s * 3.8, c[2] + 8, c[3] - 0.8 }, { s * 4.7, c[2] + 14, c[3] }, { s * 5.6, c[2] + 20, c[3] + 1.2 } }, Radius = 1.4, RadiusB = 0.9, Smooth = true }, "Fur")
	end)
	ell(g, "Muzzle", { 0, c[2] - 3.4, c[3] - 7.6 }, { 4, 3, 2.8 })
	ell(g, "Nose", { 0, c[2] - 1.8, c[3] - 10 }, { 1.4, 0.8, 0.8 })
	if ctx.Fine then
		face(ctx, "Mouth", { { 0, c[2] - 3.2 }, { 1, c[2] - 4 }, { -1, c[2] - 4 } })
		face(ctx, "Tooth", { { 0, c[2] - 5 }, { -1, c[2] - 5 } })
	end
	EVO.Face(ctx, c, { EyeX = 7.6, EyeY = 3.4 })
	shadeMain(ctx, { "Fur" })
	local t = newTail(ctx, ctx.TailHinge, 0.3)
	ell(t, "Belly", { 0, 1, 1.5 }, { 3.2, 3.2, 3.2 })
end

EVO.Species.Penguin = function(ctx)
	local g = ctx.Body
	local c = EVO.Bird(ctx, { HeadR = { 10.4, 9, 9.4 } })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, c[2] - 2.6, c[3] - 5.5 }, Radius = { 7.4, 5.4, 5 } }, "Fur")
	-- beak: orange wedge with a lighter tip
	cone(g, "Beak", { 0, c[2] - 2.2, c[3] - 8.6 }, { 0, c[2] - 3, c[3] - 14 }, 2.3, 0.4)
	paint(g, "Feet", { Kind = "Box", Center = { 0, c[2] - 3.6, c[3] - 11 }, Size = { 6, 1.4, 8 } }, "Beak")
	EVO.Face(ctx, c, { EyeX = 8.2, EyeY = 3.2 })
	shadeMain(ctx, { "Fur", "Belly" })
	-- flippers at the sides
	pair(function(s)
		ell(g, "Fur", { s * 11, -4, 0.5 }, { 2.4, 9, 5 }, { Rotation = CFrame.Angles(0, 0, s * 0.25), Pivot = { s * 11, -4, 0.5 } })
	end)
	local t = newTail(ctx, ctx.TailHinge, 0.15)
	cone(t, "Fur", { 0, 0, 0 }, { 0, -1.5, 4 }, 3, 0.8)
end


EVO.Species.Dragon = function(ctx)
	local g = ctx.Body
	local pal = ctx.Pal
	EVO.Quad(ctx, { W = 1.08, L = 0.9, PawKey = "Fur", BellyKey = "Belly", Toes = false })
	-- a big pale chest plate with ridges
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, ctx.EvoBelly + 1, -12 }, Radius = { 6.8, 7.8, 3.8 } }, "Fur")
	if ctx.Fine then
		for i = 0, 6 do
			box(g, "AccentDark", { 0, ctx.EvoBelly - 7 + i * 2.6, -4 }, { 14, 0.8, 28 }, { Op = "Paint", OnlyKeys = "Belly" })
		end
	end
	-- golden claws on every paw
	pal.Claw = rgb(250, 202, 72)
	pair(function(s)
		for _, p in ipairs({ ctx.Legs.Front, ctx.Legs.Hind }) do
			for _, dx in ipairs({ -1.7, 0, 1.7 }) do
				cone(g, "Claw", { s * p[1] + dx, EVO.Ground + 1.4, p[2] - 3.4 }, { s * p[1] + dx * 1.15, EVO.Ground + 0.4, p[2] - 5.8 }, 1, 0.25)
			end
		end
	end)
	-- squarish skull, long snout with an open toothy jaw, heavy brows, cheek spikes, fin ears
	local c = EVO.Head(ctx, { 10, 9, 9.2 }, nil, 0.5)
	shape(g, { Kind = "RoundBox", Center = { 0, c[2] + 0.6, c[3] + 0.4 }, Size = { 18, 16, 16.4 }, Round = 4.2, Key = "Fur" })
	shape(g, { Kind = "RoundBox", Center = { 0, c[2] - 3.6, c[3] - 8.8 }, Size = { 10.8, 6.4, 9.4 }, Round = 2.4, Key = "Fur" })
	shape(g, { Kind = "RoundBox", Center = { 0, c[2] - 8.4, c[3] - 7.8 }, Size = { 9, 2.6, 8 }, Round = 1.2, Key = "Belly" })
	box(g, "Mouth", { 0, c[2] - 6.9, c[3] - 9.4 }, { 7.4, 1.4, 6.4 })
	box(g, "Tongue", { 0, c[2] - 7.4, c[3] - 10.4 }, { 4, 0.8, 3.4 })
	paint(g, "Belly", { Kind = "Box", Center = { 0, c[2] - 5.6, c[3] - 9.4 }, Size = { 12, 1.4, 11 } }, "Fur")
	for _, x in ipairs({ -3.2, -1.6, 1.6, 3.2 }) do
		box(g, "Tooth", { x, c[2] - 6.6, c[3] - 12.9 }, { 1, 1.6, 1 })
	end
	box(g, "Tooth", { -3.2, c[2] - 7.6, c[3] - 12.4 }, { 1, 1.2, 1 })
	box(g, "Tooth", { 3.2, c[2] - 7.6, c[3] - 12.4 }, { 1, 1.2, 1 })
	if ctx.Fine then
		face(ctx, "Nostril", { { 2.2, c[2] - 1.6 }, { -2.2, c[2] - 1.6 } })
	end
	pal.Brow = darken(ctx.Look.Primary, 0.3)
	pair(function(s)
		cap(g, "Brow", { s * 2, c[2] + 6.2, c[3] - 9.8 }, { s * 8.8, c[2] + 8, c[3] - 6.6 }, 1.3, 1)
		cone(g, "Fur", { s * 8.8, c[2] - 2.4, c[3] + 1 }, { s * 13.6, c[2] - 3.4, c[3] + 5.4 }, 2.1, 0.3)
		cone(g, "Fur", { s * 8.8, c[2] + 1.6, c[3] + 2 }, { s * 13, c[2] + 2, c[3] + 6.8 }, 1.7, 0.3)
		triEar(ctx, s, { 8.2, c[2] + 4, c[3] + 2 }, { 12.4, c[2] + 9.4, c[3] + 4 }, 2.2, "WingTip")
	end)
	EVO.Face(ctx, c, { EyeX = 8.6, EyeY = 5.4, Fierce = true, Blush = false })
	-- big golden horns: thick at the root, sweeping up and back, ringed
	local hs = ctx.Ascended and 1.3 or 1 -- (the second evolution's horns are bigger)
	pair(function(s)
		curve(g, "Horn", { { s * 4.6, ctx.HeadTop - 3, c[3] - 1 }, { s * 5.8, ctx.HeadTop + 2.6 * hs, c[3] }, { s * 6.8, ctx.HeadTop + 7.4 * hs, c[3] + 3 * hs }, { s * 6.4, ctx.HeadTop + 10.6 * hs, c[3] + 7.6 * hs } }, 3.1 * (ctx.Ascended and 1.15 or 1), 0.6, { Smooth = true })
		if ctx.Fine then
			for i = 1, 3 do
				box(g, "HornRing", { s * 5.8, ctx.HeadTop + i * 2.6 * hs - 1, c[3] + i * 1.2 * hs - 0.6 }, { 8, 0.8, 9 }, { Op = "Paint", OnlyKeys = "Horn" })
			end
		end
	end)
	pal.HornRing = darken(pal.Horn, 0.18)
	-- forehead jewel
	ell(g, "Gold", { 0, c[2] + 7.2, c[3] - 8.8 }, { 2.4, 2.6, 1 })
	ell(g, "Gem", { 0, c[2] + 7.2, c[3] - 9.6 }, { 1.4, 1.7, 0.8 })
	-- spines down the back
	for i = 0, 6 do
		local z = -6 + i * 3.8
		local y = ctx.EvoBelly + 8 - math.abs(i - 1.5) * 0.5
		cone(g, "Spine", { 0, y - 1, z }, { 0, y + 3.4 - i * 0.25, z + 1.6 }, 1.6, 0.2)
	end
	pal.Spine = pal.Spine or rgb(250, 202, 72)
	shadeMain(ctx, { "Fur" })
	-- long tail swinging out to the side with spikes and a spade tip
	local t = newTail(ctx, ctx.TailHinge, 0.25)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, -2, 6 }, { 3, -6, 12 }, { 9, -9, 15 }, { 15, -10, 14 } }, 3.8, 1.3, { Smooth = true })
	cone(t, "Spine", { 15, -10, 14 }, { 20, -10.5, 13 }, 2.6, 0.2)
	for _, p in ipairs({ { 0, 2.8, 4 }, { 1, 0.8, 9 }, { 4.5, -2.8, 13 }, { 9.5, -5.6, 15.5 } }) do
		cone(t, "Spine", p, { p[1], p[2] + 2.6, p[3] + 1 }, 1.2, 0.2)
	end
end

----------------------------------------------------------------------
-- per-pet evolved details (after the species, before the eyes are carved)
----------------------------------------------------------------------
EVO.Pets.biscuit_bear = function(ctx)
	local g = ctx.Body
	-- a big knitted striped scarf with a hanging end and a square gold medallion set with a red gem
	local y, z, r = ctx.NeckY, ctx.NeckZ, ctx.NeckR
	local pts = {}
	for i = 0, 16 do
		local a = i / 16 * TAU
		pts[#pts + 1] = { math.cos(a) * (r[1] + 1.2), y - 0.6 + math.sin(a) * 1.2, z + math.sin(a) * (r[2] + 1.2) }
	end
	curve(g, "Scarf", pts, 2.2, 2.2, { Smooth = false })
	cap(g, "Scarf", { 3.6, y - 1.5, z - r[2] - 1.4 }, { 4.6, y - 9, z - r[2] - 1.2 }, 2.1, 2)
	if ctx.Fine then
		local stripe = function(x, yy, zz)
			local a = math.atan2(zz - z, x)
			if floor((a + math.pi) / TAU * 18) % 2 == 0 then
				return "ScarfStripe"
			end
			return false
		end
		paint(g, "ScarfStripe", { Kind = "Box", Center = { 0, y - 0.6, z }, Size = { 2 * r[1] + 8, 6, 2 * r[2] + 8 }, Pattern = stripe }, "Scarf")
		paint(g, "ScarfStripe", { Kind = "Capsule", A = { 3.6, y - 1.5, z - r[2] - 1.4 }, B = { 4.6, y - 9, z - r[2] - 1.2 }, Radius = 2.3, Pattern = function(x, yy)
			if floor(yy + 0.5) % 3 == 0 then
				return "ScarfStripe"
			end
			return false
		end }, "Scarf")
	end
	local fy, fz = y - 1.4, z - r[2] - 3
	box(g, "GoldDeep", { 0, fy - 1, fz }, { 5, 5, 1.6 })
	box(g, "Gold", { 0, fy - 1, fz - 0.6 }, { 4, 4, 1.2 })
	ell(g, "Gem", { 0, fy - 1, fz - 1.4 }, { 1.4, 1.4, 0.8 })
	set(g, vx(-0.5), vx(fy - 0.4), vx(fz - 2.2), "Spark")
end

EVO.Pets.honey_bunny = function(ctx)
	EVO.Tiara(ctx, { H = 4.6 })
	EVO.Necklace(ctx, { Double = true, Drops = 4 })
	EVO.Anklets(ctx, { Gem = false })
end

EVO.Pets.pip_penguin = function(ctx)
	local g = ctx.Body
	local c = ctx.HeadC
	-- a crest of blue ice crystals rising from a small gold crown
	shape(g, { Kind = "Torus", Center = { 0, ctx.HeadTop - 1.2, c[3] + 0.5 }, Radius = 3.4, Thickness = 0.9, Key = "Gold" })
	ell(g, "Gem", { 0, ctx.HeadTop - 0.6, c[3] - 3.4 }, { 1.2, 1.4, 0.8 })
	local crys = { { 0, 9, 0 }, { 2.4, 6.5, 0.8 }, { -2.4, 6.5, 0.8 }, { 1, 5, 2.6 }, { -1.2, 5.5, 2.4 } }
	for i, p in ipairs(crys) do
		local base = { p[1] * 0.6, ctx.HeadTop - 1, c[3] + p[3] * 0.5 }
		cone(g, (i == 1) and "Crystal" or "CrystalDeep", base, { p[1], ctx.HeadTop + p[2], c[3] + p[3] }, 1.6, 0.25)
	end
	ctx.Pal.Crystal = rgb(150, 220, 255)
	ctx.Pal.CrystalDeep = rgb(90, 170, 240)
	EVO.Necklace(ctx, { R = 8.6, DY = -1, Tilt = 0.3, Drops = 4 })
end

EVO.Pets.twilight_dragon = function(ctx)
	EVO.ChestPlate(ctx)
	EVO.Necklace(ctx, { Pendant = false })
	EVO.Anklets(ctx)
end

-- gem and wing colours of the other evolved pets (after the player's evolved reference sheet)
local EVO_LOOKS = {
	mallow_kitten = { Gem = { 255, 84, 168 }, GemB = { 200, 150, 255 }, Wing = { 242, 156, 194 }, Tip = { 255, 236, 244 } },
	pebble_pup = { Gem = { 236, 64, 108 }, GemB = { 255, 210, 90 }, Wing = { 166, 124, 84 }, Tip = { 246, 228, 200 } },
	puddle_frog = { Gem = { 60, 196, 220 }, GemB = { 255, 210, 90 }, Wing = { 92, 184, 88 }, Tip = { 206, 244, 170 } },
	bamboo_panda = { Gem = { 80, 200, 110 }, GemB = { 255, 210, 90 }, Wing = { 112, 186, 104 }, Tip = { 214, 244, 196 } },
	bubble_axolotl = { Gem = { 255, 76, 146 }, GemB = { 90, 200, 255 }, Wing = { 136, 198, 236 }, Tip = { 236, 250, 255 } },
	maple_fox = { Gem = { 236, 48, 52 }, GemB = { 255, 210, 90 }, Wing = { 222, 106, 44 }, Tip = { 255, 212, 146 } },
	mochi_slime = { Gem = { 232, 36, 88 }, GemB = { 255, 210, 90 }, Wing = { 244, 156, 188 }, Tip = { 255, 236, 244 } },
	sleepy_owl = { Gem = { 226, 52, 72 }, GemB = { 255, 210, 90 }, Wing = { 134, 98, 72 }, Tip = { 236, 214, 180 } },
	waffle_corgi = { Gem = { 255, 84, 148 }, GemB = { 90, 200, 255 }, Wing = { 222, 168, 92 }, Tip = { 255, 240, 204 } },
	blossom_bunny = { Gem = { 255, 96, 168 }, GemB = { 255, 210, 90 }, Wing = { 238, 164, 204 }, Tip = { 255, 236, 246 } },
	cherry_panda = { Gem = { 255, 92, 156 }, GemB = { 255, 210, 90 }, Wing = { 234, 146, 178 }, Tip = { 255, 226, 236 } },
	frostling_penguin = { Gem = { 226, 36, 56 }, GemB = { 120, 210, 255 }, Wing = { 124, 186, 236 }, Tip = { 236, 250, 255 } },
	shroomie_frog = { Gem = { 226, 44, 56 }, GemB = { 255, 210, 90 }, Wing = { 224, 116, 66 }, Tip = { 255, 230, 190 } },
	storm_tabby = { Gem = { 255, 76, 138 }, GemB = { 120, 200, 255 }, Wing = { 66, 74, 104 }, Tip = { 170, 180, 214 } },
	aurora_fox = { Gem = { 255, 104, 188 }, GemB = { 170, 240, 255 }, Wing = { 104, 198, 194 }, Tip = { 226, 252, 248 } },
	candy_unicorn = { Gem = { 84, 196, 255 }, GemB = { 255, 104, 176 }, Wing = { 244, 172, 206 }, Tip = { 255, 244, 250 } },
	moonlit_owl = { Gem = { 168, 84, 240 }, GemB = { 255, 220, 120 }, Wing = { 58, 70, 132 }, Tip = { 200, 210, 250 } },
	nebula_axolotl = { Gem = { 255, 96, 188 }, GemB = { 130, 240, 255 }, Wing = { 126, 96, 216 }, Tip = { 245, 240, 255 } },
	ember_phoenix = { Gem = { 255, 56, 36 }, GemB = { 255, 210, 90 }, Wing = { 238, 104, 36 }, Tip = { 255, 226, 96 } },
	sunbeam_bear = { Gem = { 226, 36, 66 }, GemB = { 76, 176, 255 }, Wing = { 234, 176, 66 }, Tip = { 255, 244, 200 } },
	cloudy_dragon = { Gem = { 64, 156, 255 }, GemB = { 255, 210, 90 }, Wing = { 222, 234, 250 }, Tip = { 255, 255, 255 } },
	starlight_unicorn = { Gem = { 168, 116, 255 }, GemB = { 255, 220, 120 }, Wing = { 198, 172, 250 }, Tip = { 250, 246, 255 } },
	stormfang = { Gem = { 76, 228, 255 }, GemB = { 170, 110, 255 }, Wing = { 66, 136, 228 }, Tip = { 170, 240, 255 } },
	eclipse_dragon = { Gem = { 255, 66, 168 }, GemB = { 76, 228, 216 }, Wing = { 104, 56, 186 }, Tip = { 232, 96, 212 } },
	obsidian_phoenix = { Gem = { 255, 56, 156 }, GemB = { 88, 208, 255 }, Wing = { 206, 64, 196 }, Tip = { 255, 186, 116 } },
	phantom_kitsune = { Gem = { 176, 116, 255 }, GemB = { 140, 255, 220 }, Wing = { 146, 116, 228 }, Tip = { 236, 226, 255 } },
}
for k, v in pairs(EVO_LOOKS) do
	EVO.Look[k] = v
end

-- a 5-petal flower facing the front (-Z)
function EVO.Flower(ctx, c, size, petal, centre)
	local g = ctx.Body
	size = size or 1
	for i = 0, 4 do
		local a = i / 5 * TAU + 0.3
		ell(g, (i % 2 == 0) and (petal or "Petal") or "PetalDeep", { c[1] + math.cos(a) * 1.7 * size, c[2] + math.sin(a) * 1.7 * size, c[3] }, { 1.3 * size, 1.3 * size, 0.9 })
	end
	ell(g, centre or "Pollen", { c[1], c[2], c[3] - 0.6 }, { 0.9 * size, 0.9 * size, 0.8 })
end

-- a pointed leaf from a (base) to b (tip), flattened, with a darker midrib
function EVO.Leaf(ctx, a, b, w, key, rib)
	local g = ctx.Body
	local dx, dy, dz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	local c = { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2 }
	if math.abs(dx) + math.abs(dz) < 0.01 then
		dz = 0.05
	end
	local rot = CFrame.lookAt(Vector3.new(0, 0, 0), Vector3.new(dx, dy, dz))
	ell(g, key or "Leaf", c, { w, 0.8, len / 2 }, { Rotation = rot, Pivot = c })
	if ctx.Fine and rib ~= false then
		cap(g, rib or "LeafDeep", a, { a[1] + dx * 0.8, a[2] + dy * 0.8, a[3] + dz * 0.8 }, 0.45, 0.3, { Op = "Paint", OnlyKeys = key or "Leaf" })
	end
end

-- bushy tail on a new tail grid (hinge-local, reaching back / up): pts, radii, tip key
function EVO.BushyTail(ctx, pts, r0, r1, tipKey, key)
	local t = ctx.Tail or newTail(ctx, ctx.TailHinge, 0.3)
	curve(t, key or "Fur", pts, r0, r1, { Smooth = true })
	if tipKey then
		local n = #pts
		local tp = pts[n]
		ell(t, tipKey, tp, { r1 + 1.6, r1 + 1.6, r1 + 1.6 }, { Op = "Paint", OnlyKeys = key or "Fur" })
	end
	return t
end

----------------------------------------------------------------------
-- the other evolved species
----------------------------------------------------------------------
EVO.Species.Cat = function(ctx)
	local g = ctx.Body
	EVO.Quad(ctx, { W = 0.95, L = 0.98, PawKey = "Belly", Tufts = true })
	local c = EVO.Head(ctx, { 10.6, 9, 9.2 })
	pair(function(s)
		ell(g, "Fur", { s * 6, c[2] - 3, c[3] - 3.2 }, { 4.6, 3.6, 4.4 })
		cone(g, "Fur", { s * 9.6, c[2] - 3.4, c[3] - 1.6 }, { s * 13.4, c[2] - 5.6, c[3] - 0.6 }, 2, 0.35)
		cone(g, "Fur", { s * 9.4, c[2] - 1, c[3] - 1.6 }, { s * 12.8, c[2] - 1.6, c[3] - 0.6 }, 1.6, 0.35)
		triEar(ctx, s, { 5.8, c[2] + 6.6, c[3] + 0.6 }, { 8.4, c[2] + 15.2, c[3] + 1.4 }, 3.9)
		ell(g, "Muzzle", { s * 1.7, c[2] - 3.8, c[3] - 8.3 }, { 2.5, 1.9, 1.5 })
	end)
	if ctx.Fine then
		face(ctx, "Nose", { { 0, c[2] - 2 }, { -1, c[2] - 2 }, { 1, c[2] - 2 }, { 0, c[2] - 3 } })
		face(ctx, "Mouth", { { 0, c[2] - 4 }, { 1, c[2] - 5 }, { -1, c[2] - 5 }, { 2, c[2] - 4.4 }, { -2, c[2] - 4.4 } })
		-- tabby marks: forehead and back stripes
		for _, x in ipairs({ -2.4, 0, 2.4 }) do
			box(g, "Stripe", { x, c[2] + 8, c[3] - 4 }, { 1, 3.4, 8 }, { Op = "Paint", OnlyKeys = "Fur" })
		end
		for i = 0, 3 do
			box(g, "Stripe", { 0, ctx.EvoBelly + 6.5, -4 + i * 4.6 }, { 22, 3, 1.2 }, { Op = "Paint", OnlyKeys = "Fur" })
		end
	end
	if luminance(ctx.Look.Primary) > 0.7 then
		ctx.Pal.Stripe = mix(darken(ctx.Look.Primary, 0.08), ctx.Look.Secondary, 0.6)
	end
	EVO.Face(ctx, c, { EyeX = 8, EyeY = 3.6 })
	shadeMain(ctx, { "Fur" })
	local t = newTail(ctx, ctx.TailHinge, 0.32)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, 2, 6 }, { 0, 8, 10 }, { 0, 15, 9 }, { 0, 19, 6 } }, 2.3, 1.7, { Smooth = true })
	if ctx.Fine then
		for i = 1, 4 do
			box(t, "Stripe", { 0, 1 + i * 3.8, 8 }, { 8, 1.2, 16 }, { Op = "Paint", OnlyKeys = "Fur" })
		end
	end
end

EVO.Species.Dog = function(ctx)
	local g = ctx.Body
	local corgi = ctx.Look.Id == "waffle_corgi"
	EVO.Quad(ctx, { W = corgi and 1.04 or 1, L = corgi and 1.08 or 1, Leg = corgi and 0.86 or 1, PawKey = "Belly", Tufts = true })
	local c = EVO.Head(ctx, { 10.6, 9.2, 9.4 }, nil, corgi and -1 or 0)
	pair(function(s)
		ell(g, "Fur", { s * 6, c[2] - 3.2, c[3] - 3.2 }, { 4.6, 3.8, 4.4 })
		if corgi then
			triEar(ctx, s, { 5.4, c[2] + 6.4, c[3] + 0.6 }, { 8.6, c[2] + 16.4, c[3] + 1.6 }, 4.4)
		else
			ctx.Pal.Ear = darken(ctx.Look.Primary, 0.2)
			ell(g, "Ear", { s * 10.4, c[2] - 0.5, c[3] + 1 }, { 2.6, 7.6, 4.6 }, { Rotation = CFrame.Angles(0, 0, s * 0.3), Pivot = { s * 10.4, c[2] - 0.5, c[3] + 1 } })
			ell(g, "Ear", { s * 8.4, c[2] + 6, c[3] + 1 }, { 3.6, 2.6, 4 })
		end
	end)
	-- a white blaze up the face, a long muzzle and a big shiny nose
	paint(g, "Muzzle", { Kind = "Ellipsoid", Center = { 0, c[2] + 1.5, c[3] - 7.5 }, Radius = { 2.2, 5.5, 3 } }, "Fur")
	ell(g, "Muzzle", { 0, c[2] - 3.8, c[3] - 9 }, { 5.4, 4.2, 4.4 })
	ell(g, "Nose", { 0, c[2] - 1.6, c[3] - 13 }, { 2.6, 1.6, 1.4 })
	ctx.Pal.Nose = rgb(46, 34, 36)
	if ctx.Fine then
		shine(ctx, -1, c[2] - 1.4)
		face(ctx, "Mouth", { { 0, c[2] - 4.2 }, { 1, c[2] - 5 }, { -1, c[2] - 5 }, { 2, c[2] - 4.6 }, { -2, c[2] - 4.6 } })
		face(ctx, "Tongue", { { 0, c[2] - 6 }, { 1, c[2] - 6 } })
	end
	EVO.Face(ctx, c, { EyeX = 8, EyeY = 3.4 })
	shadeMain(ctx, { "Fur" })
	local t = newTail(ctx, ctx.TailHinge, 0.45)
	if corgi then
		ell(t, "Fur", { 0, 1.5, 2 }, { 3.2, 3.6, 3.6 })
		ell(t, "Belly", { 0, 2.5, 3.6 }, { 2.4, 2.4, 2.4 })
	else
		curve(t, "Fur", { { 0, 0, 0 }, { 0, 4, 3 }, { 0, 8, 3.6 }, { 0, 10, 2 } }, 2.4, 1.6, { Smooth = true })
		ell(t, "Belly", { 0, 10.2, 1.8 }, { 2, 2, 2 })
	end
end

EVO.Species.Fox = function(ctx)
	local g = ctx.Body
	local id = ctx.Look.Id
	EVO.Quad(ctx, { W = 0.94, L = 1, PawKey = (id == "maple_fox") and "Patch" or "Belly", LegKey = "Fur", Tufts = true })
	if id == "maple_fox" then
		ctx.Pal.Patch = rgb(64, 40, 34)
		pair(function(s)
			for _, p in ipairs({ ctx.Legs.Front, ctx.Legs.Hind }) do
				paint(g, "Patch", { Kind = "Box", Center = { s * p[1], EVO.Ground + 4.5, p[2] }, Size = { 7, 9, 8 } }, "Fur")
			end
		end)
	end
	local c = EVO.Head(ctx, { 10.2, 8.8, 9 })
	pair(function(s)
		ell(g, "Belly", { s * 6.2, c[2] - 3.6, c[3] - 3.4 }, { 4.6, 3.6, 4.4 })
		cone(g, "Belly", { s * 9.6, c[2] - 3.6, c[3] - 1.4 }, { s * 13.6, c[2] - 6.2, c[3] }, 2.3, 0.35)
		triEar(ctx, s, { 5.4, c[2] + 6, c[3] + 0.8 }, { 8.6, c[2] + 16.6, c[3] + 1.8 }, 4.4, nil, "Patch")
	end)
	if not ctx.Pal.Patch or id ~= "maple_fox" then
		ctx.Pal.Patch = darken(ctx.Look.Primary, 0.45)
	end
	-- pointed muzzle, light below
	cone(g, "Fur", { 0, c[2] - 2.4, c[3] - 6 }, { 0, c[2] - 3.4, c[3] - 13 }, 3.8, 1.4)
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, c[2] - 5, c[3] - 8.6 }, Radius = { 4.4, 2.4, 5 } }, "Fur")
	ell(g, "Nose", { 0, c[2] - 3, c[3] - 13.6 }, { 1.5, 1.2, 1.1 })
	ctx.Pal.Nose = rgb(46, 32, 34)
	if ctx.Fine then
		face(ctx, "Mouth", { { 0, c[2] - 5 }, { 1, c[2] - 5.6 }, { -1, c[2] - 5.6 } })
	end
	-- fluffy chest ruff
	ell(g, "Belly", { 0, ctx.NeckY - 2, ctx.NeckZ - 5 }, { 6, 5, 3.4 })
	for _, x in ipairs({ -3, 0, 3 }) do
		cone(g, "Belly", { x, ctx.NeckY - 4, ctx.NeckZ - 6 }, { x * 1.1, ctx.NeckY - 8.4, ctx.NeckZ - 7 }, 2, 0.3)
	end
	EVO.Face(ctx, c, { EyeX = 8, EyeY = 3.6 })
	shadeMain(ctx, { "Fur" })
	if id == "phantom_kitsune" then
		-- five ghostly tails fanning up behind
		local t = newTail(ctx, ctx.TailHinge, 0.25)
		for i = -2, 2 do
			local a = i * 0.42
			local sx, sy = math.sin(a), math.cos(a)
			curve(t, "Tail", { { 0, 0, 0 }, { sx * 6, sy * 5, 4 }, { sx * 13, sy * 13, 6 }, { sx * 17, sy * 19, 4 } }, 2.4, 3.4, { Smooth = true })
			ell(t, "TailTip", { sx * 17.5, sy * 19.8, 3.8 }, { 3.2, 3.4, 3 }, { Op = "Paint", OnlyKeys = "Tail" })
		end
		ctx.Pal.Tail = rgb(132, 104, 214)
		ctx.Pal.TailTip = { Color = rgb(206, 186, 255), Material = NEON }
	else
		EVO.BushyTail(ctx, { { 0, 0, 0 }, { 0, 2, 6 }, { 0, 7, 11 }, { 0, 13, 12 }, { 0, 17, 9 } }, 3, 4.4, "Belly")
	end
end

EVO.Species.Panda = function(ctx)
	local g = ctx.Body
	ctx.Pal.Patch = (luminance(ctx.Look.Secondary) < 0.3) and ctx.Look.Secondary or darken(ctx.Look.Secondary, 0.2)
	EVO.Quad(ctx, { W = 1.12, L = 0.95, LegKey = "Patch", PawKey = "Patch", BellyKey = false, ToeKey = "Lash" })
	-- dark shoulder band
	paint(g, "Patch", { Kind = "Box", Center = { 0, ctx.EvoBelly + 1, -4.5 }, Size = { 24, 18, 5 } }, "Fur")
	local c = EVO.Head(ctx, { 11, 9.8, 10 })
	pair(function(s)
		ell(g, "Fur", { s * 6.2, c[2] - 3, c[3] - 3.2 }, { 4.6, 3.8, 4.4 })
		roundEar(ctx, s, { 7.6, c[2] + 7.8, c[3] + 0.8 }, 3.7, "Patch", "Patch")
		-- eye patches, tilted teardrops
		paint(g, "Patch", { Kind = "Ellipsoid", Center = { s * 5.3, c[2] + 0.6, c[3] - 8 }, Radius = { 3.4, 4.4, 3 }, Rotation = CFrame.Angles(0, 0, s * 0.5), Pivot = { s * 5.3, c[2] + 0.6, c[3] - 8 } }, "Fur")
	end)
	ell(g, "Fur", { 0, c[2] - 3.8, c[3] - 8.8 }, { 5.2, 3.9, 3.8 })
	ell(g, "Nose", { 0, c[2] - 1.8, c[3] - 12.4 }, { 2.3, 1.3, 1.3 })
	ctx.Pal.Nose = rgb(40, 36, 44)
	if ctx.Fine then
		shine(ctx, -1, c[2] - 1.8)
		face(ctx, "Mouth", { { 0, c[2] - 4.4 }, { 1, c[2] - 5 }, { -1, c[2] - 5 } })
	end
	EVO.Face(ctx, c, { EyeX = 8, EyeY = 3.8 })
	shadeMain(ctx, { "Fur", "Patch" })
	local t = newTail(ctx, ctx.TailHinge, 0.2)
	ell(t, "Fur", { 0, 0.6, 1.4 }, { 2.6, 2.6, 2.6 })
end

EVO.Species.Owl = function(ctx)
	local g = ctx.Body
	local c = EVO.Bird(ctx, { HeadR = { 11, 9.6, 9.6 } })
	-- facial disc, ear tufts, little hooked beak, gold eye rings
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, c[2] - 0.5, c[3] - 7 }, Radius = { 9, 6.4, 4 } }, "Fur")
	pair(function(s)
		cone(g, "Fur", { s * 6.6, c[2] + 6.5, c[3] }, { s * 9.4, c[2] + 13.5, c[3] + 1.4 }, 2.6, 0.4)
		paint(g, "EyeRing", { Kind = "Ellipsoid", Center = { s * 4.8, c[2] + 0.4, c[3] - 8.4 }, Radius = { 4.3, 4.6, 2.4 } }, "Belly")
	end)
	cone(g, "Beak", { 0, c[2] - 1.8, c[3] - 9 }, { 0, c[2] - 4.4, c[3] - 11.4 }, 1.7, 0.3)
	-- speckled chest
	if ctx.Fine then
		for i = 0, 11 do
			local x = (i % 4) * 3.2 - 4.8 + ((floor(i / 4) % 2) * 1.6)
			local y = -1 - floor(i / 4) * 3.4
			box(g, "Stripe", { x, y, -10 }, { 1.2, 1, 10 }, { Op = "Paint", OnlyKeys = "Belly" })
		end
	end
	ctx.Pal.EyeRing = rgb(250, 196, 70)
	EVO.Face(ctx, c, { EyeX = 8.2, EyeY = 3.8, Blush = false })
	if luminance(ctx.Look.Eye) < 0.45 then
		ctx.Pal.EyeIris = rgb(236, 170, 40)
		ctx.Pal.EyeGlint = rgb(255, 222, 120)
	end
	shadeMain(ctx, { "Fur" })
	local t = newTail(ctx, ctx.TailHinge, 0.15)
	cone(t, "Fur", { 0, 0, 0 }, { 0, -1.5, 5 }, 3.4, 1)
end

EVO.Species.Phoenix = function(ctx)
	local g = ctx.Body
	local G0 = EVO.Ground
	local pal = ctx.Pal
	pal.Talon = rgb(250, 202, 72)
	-- legs with golden talons
	pair(function(s)
		cap(g, "Feet", { s * 3.6, -10, 1.5 }, { s * 3.8, G0 + 2.2, 0 }, 1.5, 1.2)
		for _, dx in ipairs({ -1.6, 0, 1.6 }) do
			cap(g, "Talon", { s * 3.8, G0 + 1.4, 0 }, { s * 3.8 + dx, G0 + 0.8, -4 }, 0.9, 0.5)
		end
		cap(g, "Talon", { s * 3.8, G0 + 1.4, 0.6 }, { s * 3.8, G0 + 0.8, 3 }, 0.8, 0.5)
	end)
	-- body leaning forward, a puffed golden chest
	ell(g, "Fur", { 0, -6, 2.5 }, { 8.6, 9, 10.6 }, { Rotation = CFrame.Angles(0.42, 0, 0), Pivot = { 0, -6, 2.5 } })
	ell(g, "Fur", { 0, -2.5, -3.6 }, { 7.6, 7.8, 7 })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -4.5, -8.6 }, Radius = { 6.2, 8.6, 4.4 } }, "Fur")
	-- neck and a round head
	cap(g, "Fur", { 0, -1, -4.6 }, { 0, 8.6, -9.8 }, 5, 4.2)
	local c = { 0, 12.6, -10.4 }
	head(ctx, "Fur", c, { 7.6, 7.2, 7.4 })
	shape(g, { Kind = "RoundBox", Center = { 0, c[2] + 0.2, c[3] + 0.4 }, Size = { 13.6, 12.6, 13 }, Round = 3.6, Key = "Fur" })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, c[2] - 3.6, c[3] - 5.6 }, Radius = { 5.6, 3.4, 3 } }, "Fur")
	-- short hooked golden beak
	shape(g, { Kind = "Cone", A = { 0, c[2] - 1.4, c[3] - 6.6 }, B = { 0, c[2] - 3.8, c[3] - 11.4 }, Radius = 2.2, RadiusB = 0.4, Key = "Beak" })
	pal.Beak = rgb(250, 196, 70)
	ctx.HeadC, ctx.HeadR = c, { 7.6, 7.2, 7.4 }
	ctx.HeadTop = c[2] + 7.2
	ctx.NeckY, ctx.NeckZ, ctx.NeckR = 4.6, -7.6, { 4.2, 4 }
	ctx.WingHinge = { 6.8, 0.5, 0.5 }
	ctx.TailHinge = { 0, -6, 11 }
	ctx.EvoBelly = -6.5
	EVO.Face(ctx, c, { EyeX = 6.6, EyeY = 2.6 })
	-- flame crest sweeping back from the crown, hot cores
	local crest = { { 0, 1, -1.5, 11 }, { 2.4, 0.6, 0, 9 }, { -2.4, 0.6, 0, 9 }, { 0, 0.4, 2.6, 10 }, { 1.8, 0, 4.2, 7 }, { -1.8, 0, 4.2, 7 } }
	for i, f in ipairs(crest) do
		local base = { f[1] * 0.6, ctx.HeadTop - 1.4, c[3] + f[3] }
		local tip = { f[1] * 1.3, ctx.HeadTop + f[4], c[3] + f[3] + f[4] * 0.55 }
		local mid = { (base[1] + tip[1]) / 2, (base[2] + tip[2]) / 2 + 0.8, (base[3] + tip[3]) / 2 - 0.8 }
		curve(g, (i % 2 == 1) and "Flame" or "FlameHot", { base, mid, tip }, 1.9, 0.35, { Smooth = true })
	end
	shadeMain(ctx, { "Fur" })
	-- long tail plumes sweeping back and down, glowing tips
	local t = newTail(ctx, ctx.TailHinge, 0.2)
	for i = -2, 2 do
		local x = i * 1.6
		local drop = math.abs(i) * 1.6
		local key = (i % 2 == 0) and "Flame" or "Wing"
		curve(t, key, { { x * 0.4, 0, 0 }, { x, 1 - drop * 0.3, 5 }, { x * 1.5, 4.5 - drop, 10 }, { x * 1.9, 9 - drop * 1.6, 12.5 - math.abs(i) } }, 2.2, 0.7, { Smooth = true })
		ell(t, "FlameHot", { x * 1.9, 9 - drop * 1.6, 12.5 - math.abs(i) }, { 1.4, 2, 1.4 })
	end
end

EVO.Species.Slime = function(ctx)
	local g = ctx.Body
	local G0 = EVO.Ground
	ell(g, "Fur", { 0, G0 + 10, 0 }, { 14.5, 10.5, 13.5 })
	ell(g, "Fur", { 0, G0 + 15, -0.5 }, { 11.8, 10.5, 11 })
	ell(g, "Fur", { 0, G0 + 22.5, -1 }, { 7, 6.5, 6.5 })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, G0 + 20, -6 }, Radius = { 7, 5, 5 } }, "Fur")
	-- glossy top
	paint(g, "Shine", { Kind = "Ellipsoid", Center = { -4, G0 + 24, -5 }, Radius = { 2.4, 2, 2 } }, { Fur = true, Belly = true })
	ctx.Pal.Shine = lighten(ctx.Look.Primary, 0.5)
	local c = { 0, G0 + 14, -0.5 }
	ctx.HeadC, ctx.HeadR = c, { 11.8, 10.5, 11 }
	ctx.HeadTop = G0 + 29
	ctx.NeckY, ctx.NeckZ, ctx.NeckR = G0 + 6, 0, { 14, 13 }
	ctx.WingHinge = { 7, G0 + 17, 3 }
	ctx.TailHinge = { 0, G0 + 8, 12 }
	-- sprout on top
	cap(g, "Fur", { 0, ctx.HeadTop - 1, -1 }, { 1.4, ctx.HeadTop + 3, 0 }, 1.4, 0.6)
	addEyes(ctx, 8, c[2] + 3, "Evo")
	cuteEyes(ctx)
	blush(ctx, 7, c[2] - 3, 3)
	if ctx.Fine then
		face(ctx, "Mouth", { { 0, c[2] - 3 }, { 1, c[2] - 3.6 }, { -1, c[2] - 3.6 }, { 2, c[2] - 3.2 }, { -2, c[2] - 3.2 } })
	end
	shadeMain(ctx, { "Fur" })
end

EVO.Species.Unicorn = function(ctx)
	local g = ctx.Body
	ctx.Pal.Mane = ctx.Look.Secondary
	ctx.Pal.Mane2 = mix(ctx.Look.Secondary, rgb(255, 255, 255), 0.45)
	ctx.Pal.Mane3 = mix(ctx.Look.Secondary, rgb(255, 160, 210), 0.5)
	EVO.Quad(ctx, { W = 0.92, L = 1.02, Leg = 1.3, PawKey = "Gold", Toes = false })
	local c = EVO.Head(ctx, { 9, 8.8, 9 }, nil, 1.5, 1)
	-- long horse snout, small ears
	ell(g, "Fur", { 0, c[2] - 4.4, c[3] - 7.4 }, { 5, 4.4, 5.6 })
	paint(g, "Muzzle", { Kind = "Ellipsoid", Center = { 0, c[2] - 6, c[3] - 9.8 }, Radius = { 4.6, 3.2, 3.6 } }, "Fur")
	if ctx.Fine then
		face(ctx, "Nostril", { { 2, c[2] - 4.8 }, { -2, c[2] - 4.8 } })
		face(ctx, "Mouth", { { 0, c[2] - 7.4 }, { 1, c[2] - 7.8 }, { -1, c[2] - 7.8 } })
	end
	pair(function(s)
		triEar(ctx, s, { 4.4, c[2] + 6.4, c[3] + 1.6 }, { 5.8, c[2] + 12.2, c[3] + 2.4 }, 2.4)
	end)
	-- golden spiral horn
	cone(g, "Horn", { 0, c[2] + 6.8, c[3] - 3.4 }, { 0, c[2] + 20, c[3] - 6.2 }, 2.3, 0.3)
	if ctx.Fine then
		for i = 0, 5 do
			local y = c[2] + 8 + i * 2
			box(g, "GoldLight", { 0, y, c[3] - 4 - i * 0.4 }, { 6, 0.8, 6 }, { Op = "Paint", OnlyKeys = "Horn" })
		end
	end
	-- flowing mane down the neck and a forelock
	local keys = { "Mane", "Mane2", "Mane3" }
	for i = 0, 7 do
		local t = i / 7
		ell(g, keys[i % 3 + 1], { -1.2, c[2] + 6 - t * 15, c[3] + 6 + t * 5.5 }, { 3.4, 3.8, 3.4 })
	end
	ell(g, "Mane", { 1.5, c[2] + 6.6, c[3] - 5.4 }, { 3.2, 2.4, 2.4 })
	ell(g, "Mane2", { -1.8, c[2] + 6, c[3] - 4.4 }, { 2.6, 2.2, 2.2 })
	EVO.Face(ctx, c, { EyeX = 8.4, EyeY = 5.8, Blush = false })
	shadeMain(ctx, { "Fur" })
	local t = newTail(ctx, ctx.TailHinge, 0.3)
	for i = -1, 1 do
		curve(t, keys[i + 2], { { i * 1.2, 0, 0 }, { i * 1.6, 1, 5 }, { i * 2.2, -4, 10 }, { i * 2.8, -11, 12 } }, 2.4, 1.2, { Smooth = true })
	end
end

EVO.Species.Frog = function(ctx)
	local g = ctx.Body
	local G0 = EVO.Ground
	-- crouched: wide body low on its legs, the head merged into it
	ell(g, "Fur", { 0, G0 + 9, 2 }, { 12, 8.5, 11 })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, G0 + 7, -6 }, Radius = { 8.6, 7, 4 } }, "Fur")
	pair(function(s)
		-- folded hind legs at the sides, short front legs, wide webbed feet
		ell(g, "Fur", { s * 10.5, G0 + 6, 6 }, { 4.6, 5.6, 7.4 })
		ell(g, "Belly", { s * 10, G0 + 1.4, 1.5 }, { 3.6, 1.5, 4.6 })
		cap(g, "Fur", { s * 7, G0 + 7, -6 }, { s * 7.6, G0 + 2.5, -8 }, 2.8, 2.4)
		ell(g, "Belly", { s * 7.6, G0 + 1.4, -9.4 }, { 3.4, 1.5, 3 })
	end)
	local c = { 0, G0 + 17, -3.5 }
	ell(g, "Fur", c, { 11.4, 8.2, 9.6 })
	ctx.HeadC, ctx.HeadR = c, { 11.4, 8.2, 9.6 }
	-- bulging eyes on top
	pair(function(s)
		ell(g, "Fur", { s * 5.6, c[2] + 6, c[3] - 3.6 }, { 4.6, 4.4, 4.4 })
	end)
	ctx.HeadTop = c[2] + 9.4
	ctx.NeckY, ctx.NeckZ, ctx.NeckR = G0 + 11.5, -3, { 10.6, 9.6 }
	ctx.WingHinge = { 6.4, G0 + 15.5, 4 }
	ctx.TailHinge = { 0, G0 + 8, 12 }
	ctx.EvoBelly = G0 + 9
	addEyes(ctx, 8.6, c[2] + 9, "Evo")
	cuteEyes(ctx)
	blush(ctx, 7.5, c[2] - 1, 3)
	if ctx.Fine then
		-- a wide smile
		local cells = {}
		for x = -5, 5 do
			cells[#cells + 1] = { x, c[2] - 3.4 + ((math.abs(x) >= 4) and 1 or 0) }
		end
		face(ctx, "Mouth", cells)
		face(ctx, "Nostril", { { 1.5, c[2] + 0.8 }, { -1.5, c[2] + 0.8 } })
	end
	shadeMain(ctx, { "Fur" })
end

EVO.Species.Axolotl = function(ctx)
	local g = ctx.Body
	ctx.Pal.Gill = ctx.Look.Secondary
	ctx.Pal.GillTip = lighten(ctx.Look.Secondary, 0.3)
	EVO.Quad(ctx, { W = 1.02, L = 1.08, Leg = 0.8, PawKey = "Fur", Toes = false })
	local c = EVO.Head(ctx, { 11.4, 8.6, 9.4 }, nil, -2.5)
	-- feathery gills: three branches each side, beaded
	pair(function(s)
		for i = 0, 2 do
			local y = c[2] + 4.6 - i * 4
			local a = { s * 9.6, y, c[3] + 2 }
			local b = { s * (15 + (i == 1 and 1.5 or 0)), y + 3 - i * 1.6, c[3] + 4 }
			curve(g, "Gill", { a, { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2 + 1, c[3] + 3 }, b }, 1.2, 0.8)
			for k = 1, 3 do
				local t = k / 3.4
				local p = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t + 1, a[3] + (b[3] - a[3]) * t }
				ell(g, "GillTip", { p[1], p[2] + 1.6, p[3] }, { 0.9, 1.4, 0.9 })
			end
		end
	end)
	if ctx.Fine then
		local cells = {}
		for x = -4, 4 do
			cells[#cells + 1] = { x, c[2] - 4 + ((math.abs(x) >= 3) and 1 or 0) }
		end
		face(ctx, "Mouth", cells)
	end
	EVO.Face(ctx, c, { EyeX = 9.2, EyeY = 3 })
	shadeMain(ctx, { "Fur" })
	-- tail with a fin
	local t = newTail(ctx, ctx.TailHinge, 0.3)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, -1, 6 }, { 1.5, -2, 12 }, { 3, -2, 17 } }, 3.4, 1.4, { Smooth = true })
	ell(t, "Gill", { 1, 1.6, 10 }, { 1, 2.4, 8.4 })
	ell(t, "Gill", { 1, -5, 10 }, { 1, 2.2, 7.4 })
end

EVO.Species.Stormfang = function(ctx)
	local g = ctx.Body
	local pal = ctx.Pal
	pal.Fur = rgb(58, 62, 76)
	pal.Plate = rgb(226, 232, 242)
	pal.PlateDark = rgb(150, 158, 176)
	pal.Belly = rgb(96, 102, 120)
	pal.Neon = { Color = rgb(76, 228, 255), Material = NEON }
	pal.NeonB = { Color = rgb(170, 110, 255), Material = NEON }
	EVO.Quad(ctx, { W = 1.06, L = 1.05, PawKey = "Plate", Toes = false })
	-- armour plates: shoulders, back ridge, glowing seams
	pair(function(s)
		ell(g, "Plate", { s * 7.6, ctx.EvoBelly + 3.5, -4.5 }, { 3.4, 5.4, 5.4 })
		ell(g, "Plate", { s * 7.2, ctx.EvoBelly + 2.5, 9.5 }, { 3.2, 5, 5 })
		box(g, "Neon", { s * 8.4, ctx.EvoBelly + 3.4, -4.5 }, { 2, 0.8, 8 })
		for _, p in ipairs({ ctx.Legs.Front, ctx.Legs.Hind }) do
			box(g, "Neon", { s * p[1], EVO.Ground + 6, p[2] - 2.6 }, { 1, 4, 1 })
		end
	end)
	for i = 0, 5 do
		cone(g, (i % 2 == 0) and "Plate" or "PlateDark", { 0, ctx.EvoBelly + 6.5, -6 + i * 3.8 }, { 0, ctx.EvoBelly + 10.5, -4.6 + i * 3.8 }, 1.6, 0.3)
	end
	local c = EVO.Head(ctx, { 9.6, 8.4, 9.4 })
	-- wolf muzzle with a white plate, tall angular ears with glowing edges, a visor line
	cone(g, "Fur", { 0, c[2] - 2.4, c[3] - 6 }, { 0, c[2] - 3.6, c[3] - 13.4 }, 4.4, 2)
	paint(g, "Plate", { Kind = "Ellipsoid", Center = { 0, c[2] - 1, c[3] - 10 }, Radius = { 3.6, 2.6, 5 } }, "Fur")
	ell(g, "Nose", { 0, c[2] - 3, c[3] - 13.8 }, { 1.6, 1.2, 1 })
	pal.Nose = rgb(24, 26, 34)
	pair(function(s)
		triEar(ctx, s, { 5, c[2] + 5.6, c[3] + 1 }, { 8, c[2] + 17, c[3] + 2.4 }, 3.8, "NeonB", "Neon")
		ell(g, "Plate", { s * 6.4, c[2] - 3.4, c[3] - 3.6 }, { 4, 3.2, 4 })
	end)
	pal.EyeIris = { Color = rgb(90, 230, 255), Material = NEON }
	pal.EyeGlint = { Color = rgb(220, 255, 255), Material = NEON }
	addEyes(ctx, 8, c[2] + 3.2, "Evo")
	shadeMain(ctx, { "Fur", "Plate" })
	local t = newTail(ctx, ctx.TailHinge, 0.3)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, 3, 5 }, { 0, 8, 9 }, { 0, 12, 13 } }, 3, 2.4, { Smooth = true })
	ell(t, "Plate", { 0, 12.4, 13.4 }, { 3, 3, 3 })
	box(t, "Neon", { 0, 9, 10 }, { 1.2, 1.2, 4 })
end

-- crystal shard wings (Stormfang): long glowing-edged blades fanning up and back
function EVO.ShardWing(ctx, w, o)
	o = o or {}
	local S = o.Size or 1
	local shards = o.Shards or { { -4, 20, 2.6 }, { -11, 18, 2.4 }, { -16, 13, 2.2 }, { -19, 6, 2 }, { -18, -1, 1.8 } }
	for i, s in ipairs(shards) do
		local a = { -1.5, 1.5, 0.5 }
		local b = { s[1] * S, s[2] * S, 0.5 }
		local dx, dy = b[1] - a[1], b[2] - a[2]
		local len = math.sqrt(dx * dx + dy * dy)
		local cc = { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, 0.5 }
		ell(w, (i % 2 == 0) and "WingTrim" or "Wing", cc, { len / 2, s[3] * (0.6 + 0.4 * S), 0.75 }, { Rotation = CFrame.Angles(0, 0, math.atan2(dy, dx)), Pivot = cc })
		ell(w, "WingEdge", { b[1] - dx * 0.12, b[2] - dy * 0.12, 0.5 }, { 2 * (0.5 + 0.5 * S), 1.6, 1 }, { Op = "Paint", OnlyKeys = { Wing = true, WingTrim = true } })
		if o.Edges then
			-- a glowing leading edge along each blade (second evolution)
			local nx, ny = -dy / len, dx / len
			local ec = { cc[1] + nx * s[3] * 0.55, cc[2] + ny * s[3] * 0.55, 0.5 }
			ell(w, "WingEdge", ec, { len * 0.42, 0.9, 1 }, { Op = "Paint", OnlyKeys = { Wing = true, WingTrim = true }, Rotation = CFrame.Angles(0, 0, math.atan2(dy, dx)), Pivot = ec })
		end
	end
	ctx.Pal.Wing = rgb(70, 140, 230)
	ctx.Pal.WingTrim = rgb(140, 100, 236)
	ctx.Pal.WingEdge = { Color = rgb(150, 240, 255), Material = NEON }
	ctx.WingSweep = 1.35
	ctx.WingTilt = 0.15
end

----------------------------------------------------------------------
-- per-pet details of the other evolved pets
----------------------------------------------------------------------
local function evoScarf(ctx, medallion)
	local g = ctx.Body
	local y, z, r = ctx.NeckY, ctx.NeckZ, ctx.NeckR
	local pts = {}
	for i = 0, 16 do
		local a = i / 16 * TAU
		pts[#pts + 1] = { math.cos(a) * (r[1] + 1), y - 0.6 + math.sin(a) * 1.2, z + math.sin(a) * (r[2] + 1) }
	end
	curve(g, "Scarf", pts, 2.1, 2.1, { Smooth = false })
	cap(g, "Scarf", { 3.4, y - 1.4, z - r[2] - 1.2 }, { 4.6, y - 8.6, z - r[2] - 1 }, 2, 1.9)
	if ctx.Fine then
		paint(g, "ScarfStripe", { Kind = "Box", Center = { 0, y - 0.6, z }, Size = { 2 * r[1] + 8, 6, 2 * r[2] + 8 }, Pattern = function(x, yy, zz)
			if floor((math.atan2(zz - z, x) + math.pi) / TAU * 18) % 2 == 0 then
				return "ScarfStripe"
			end
			return false
		end }, "Scarf")
		paint(g, "ScarfStripe", { Kind = "Capsule", A = { 3.4, y - 1.4, z - r[2] - 1.2 }, B = { 4.6, y - 8.6, z - r[2] - 1 }, Radius = 2.2, Pattern = function(x, yy)
			if floor(yy + 0.5) % 3 == 0 then
				return "ScarfStripe"
			end
			return false
		end }, "Scarf")
	end
	if medallion then
		local fy, fz = y - 1.2, z - r[2] - 2.8
		box(g, "GoldDeep", { 0, fy - 1, fz }, { 5, 5, 1.6 })
		box(g, "Gold", { 0, fy - 1, fz - 0.6 }, { 4, 4, 1.2 })
		ell(g, "Gem", { 0, fy - 1, fz - 1.4 }, { 1.4, 1.4, 0.8 })
		set(g, vx(-0.5), vx(fy - 0.4), vx(fz - 2.2), "Spark")
	end
end

local function evoHalo(ctx, R, lift)
	local h = Voxel.NewGrid(30)
	shape(h, { Kind = "Torus", Center = { 0, 0, 0 }, Radius = R or 5.6, Thickness = 0.8, Key = "HaloGlow", Rotation = CFrame.Angles(-0.45, 0, 0), Pivot = { 0, 0, 0 } })
	ctx.Halo = h
	ctx.HaloAt = { 0, ctx.HeadTop + (lift or 3.4), ctx.HeadC[3] + 1 }
	ctx.Pal.HaloGlow = { Color = rgb(255, 222, 120), Material = NEON }
end

local function leafCrest(ctx, n, len)
	local c = ctx.HeadC
	-- a spiky crown of leaves: an outer ring leaning out, an inner ring standing up, one in the middle
	for i = 0, n - 1 do
		local a = (i / n) * TAU + 0.3
		local outer = (i % 2 == 0)
		local base = { math.cos(a) * 2.4, ctx.HeadTop - 1.6, c[3] + 1 + math.sin(a) * 2.4 }
		local spread = outer and 0.62 or 0.32
		local tip = { math.cos(a) * len * spread, ctx.HeadTop + len * (outer and 0.72 or 0.95), c[3] + 1 + math.sin(a) * len * spread }
		EVO.Leaf(ctx, base, tip, outer and 2 or 1.7, outer and "Leaf" or "LeafDeep", outer and "LeafDeep" or "Leaf")
	end
	EVO.Leaf(ctx, { 0, ctx.HeadTop - 1.5, c[3] + 1 }, { 0.4, ctx.HeadTop + len * 1.05, c[3] + 1.6 }, 1.8)
end

EVO.Pets.mallow_kitten = function(ctx)
	EVO.Tiara(ctx, { H = 4.4 })
	EVO.Necklace(ctx, { Double = true, Drops = 4 })
end

EVO.Pets.pebble_pup = function(ctx)
	EVO.Necklace(ctx, { Size = 1.1, Drops = 2 })
	local g = ctx.Body
	ell(g, "Fur", { 0, ctx.HeadTop - 0.5, ctx.HeadC[3] - 2 }, { 2.4, 2, 2.4 }) -- topknot
end

EVO.Pets.puddle_frog = function(ctx)
	leafCrest(ctx, 9, 13)
	EVO.Necklace(ctx, { R = 9.6, DY = 0.5, Tilt = 0.25, Drops = 4 })
end

EVO.Pets.bamboo_panda = function(ctx)
	local c = ctx.HeadC
	for i = 0, 6 do
		local a = (i / 6) * math.pi
		local base = { math.cos(a) * 6, ctx.HeadTop - 2, c[3] + 1 - math.sin(a) * 4 }
		local tip = { math.cos(a) * 10.5, ctx.HeadTop + 2.5, c[3] + 1 - math.sin(a) * 6.5 }
		EVO.Leaf(ctx, base, tip, 1.4, (i % 2 == 0) and "Leaf" or "LeafDeep")
	end
	EVO.Necklace(ctx, { Size = 1.1, Drops = 2 })
end

EVO.Pets.bubble_axolotl = function(ctx)
	EVO.Tiara(ctx, { H = 3.8 })
	EVO.Necklace(ctx, { Drops = 4 })
end

EVO.Pets.maple_fox = function(ctx)
	EVO.Tiara(ctx, { H = 4.2, Side = false })
	local c = ctx.HeadC
	EVO.Leaf(ctx, { 0, ctx.HeadTop - 1, c[3] + 1 }, { 3.5, ctx.HeadTop + 6, c[3] + 2 }, 2.4)
	EVO.Leaf(ctx, { 0, ctx.HeadTop - 1, c[3] + 1 }, { -3, ctx.HeadTop + 5, c[3] + 3 }, 2, "LeafDeep", "Leaf")
	EVO.Necklace(ctx, { Pendant = true, Drops = 2 })
end

EVO.Pets.mochi_slime = function(ctx)
	local g = ctx.Body
	local c = ctx.HeadC
	-- a tiara sitting on the dome
	shape(g, { Kind = "Torus", Center = { 0, ctx.HeadTop - 7.4, c[3] - 0.5 }, Radius = 7.6, Thickness = 0.8, Key = "Gold", Rotation = CFrame.Angles(0.25, 0, 0), Pivot = { 0, ctx.HeadTop - 7.4, c[3] - 0.5 } })
	local fz = c[3] - 8.6
	local fy = ctx.HeadTop - 6.2
	ell(g, "GoldDeep", { 0, fy, fz + 0.4 }, { 2.8, 3.2, 1 })
	ell(g, "Gold", { 0, fy, fz }, { 2.2, 2.6, 0.9 })
	ell(g, "Gem", { 0, fy, fz - 0.6 }, { 1.5, 1.8, 0.8 })
	cone(g, "Gold", { 0, fy + 2.4, fz + 0.6 }, { 0, fy + 5.6, fz + 1 }, 1, 0.2)
	pair(function(s)
		cone(g, "Gold", { s * 2.8, fy + 0.8, fz + 0.8 }, { s * 4.8, fy + 3.4, fz + 1.4 }, 0.8, 0.2)
	end)
end

EVO.Pets.sleepy_owl = function(ctx)
	EVO.Tiara(ctx, { H = 7.4 })
	EVO.Necklace(ctx, { R = 9.4, DY = -0.5, Tilt = 0.3, Drops = 2 })
end

EVO.Pets.waffle_corgi = function(ctx)
	EVO.Crown(ctx, { R = 4.8, Points = 6, Sink = 2.6 })
	EVO.Flower(ctx, { -5.4, ctx.HeadTop - 2, ctx.HeadC[3] - 5.4 }, 1.1)
	EVO.Necklace(ctx, { Drops = 4 })
end

EVO.Pets.blossom_bunny = function(ctx)
	EVO.Tiara(ctx, { H = 4.6 })
	local c = ctx.HeadC
	EVO.Flower(ctx, { 4.6, ctx.HeadTop + 0.5, c[3] - 3 }, 1.1)
	EVO.Flower(ctx, { -5, ctx.HeadTop, c[3] - 2.6 }, 0.9, "PetalDeep")
	EVO.Necklace(ctx, { Double = true, Drops = 4 })
end

EVO.Pets.cherry_panda = function(ctx)
	local c = ctx.HeadC
	for i = 0, 5 do
		local a = (i / 5) * math.pi
		EVO.Flower(ctx, { math.cos(a) * 6.6, ctx.HeadTop - 0.8 + math.sin(a) * 0.6, c[3] - math.sin(a) * 5 - 1 }, 1, (i % 2 == 0) and "Petal" or "PetalDeep")
	end
	EVO.Necklace(ctx, { Drops = 4 })
end

EVO.Pets.frostling_penguin = function(ctx)
	evoScarf(ctx, true)
	EVO.Crown(ctx, { R = 4.4, Points = 5, Sink = 1.6 })
end

EVO.Pets.shroomie_frog = function(ctx)
	local g = ctx.Body
	local c = ctx.HeadC
	local top = ctx.HeadTop - 1
	-- a huge red toadstool cap with white spots, a gold crown band around it
	cap(g, "CapSpot", { 0, top - 2, c[3] + 1 }, { 0, top + 2, c[3] + 1 }, 2.6, 2.4)
	ell(g, "Cap", { 0, top + 4.2, c[3] + 1 }, { 8.6, 5.4, 8.2 })
	carve(g, { Kind = "Box", Center = { 0, top + 0.4, c[3] + 1 }, Size = { 20, 3.6, 20 } }, "Cap")
	for _, p in ipairs({ { 3.4, top + 7.6, c[3] - 3 }, { -4, top + 6.6, c[3] - 3.6 }, { 0, top + 9, c[3] + 1.5 }, { 6, top + 4.6, c[3] - 2.6 }, { -6.6, top + 4.4, c[3] + 1 }, { 5, top + 6, c[3] + 4 } }) do
		ell(g, "CapSpot", p, { 1.4, 1.1, 1.4 }, { Op = "Paint", OnlyKeys = "Cap" })
	end
	shape(g, { Kind = "Torus", Center = { 0, top + 2.6, c[3] + 1 }, Radius = 8.4, Thickness = 0.8, Key = "Gold" })
	for i = 0, 4 do
		local a = -math.pi / 2 + (i - 2) * 0.5
		cone(g, "Gold", { math.cos(a) * 8.4, top + 3, c[3] + 1 + math.sin(a) * 8.4 }, { math.cos(a) * 8.8, top + 6, c[3] + 1 + math.sin(a) * 8.8 }, 1, 0.2)
	end
	ell(g, "Gem", { 0, top + 3, c[3] - 7.8 }, { 1.4, 1.6, 0.8 })
	EVO.Necklace(ctx, { R = 9.6, DY = 0.5, Tilt = 0.25, Drops = 2 })
end

EVO.Pets.storm_tabby = function(ctx)
	EVO.Necklace(ctx, { Drops = 2 })
end

EVO.Pets.aurora_fox = function(ctx)
	local g = ctx.Body
	local top = ctx.HeadTop
	local z = ctx.HeadC[3]
	pair(function(s)
		curve(g, "Antler", { { s * 3, top - 2.5, z }, { s * 4.6, top + 2.6, z + 1 }, { s * 7.4, top + 5.6, z + 2 }, { s * 9, top + 8.4, z + 2.6 } }, 1.3, 0.8)
		curve(g, "Antler", { { s * 4.8, top + 3, z + 1 }, { s * 3, top + 6, z + 0.6 }, { s * 2.8, top + 7.6, z + 0.6 } }, 0.9, 0.6)
		EVO.Flower(ctx, { s * 9, top + 9, z + 2.2 }, 0.8)
		EVO.Flower(ctx, { s * 2.8, top + 8.2, z + 0.4 }, 0.7, "PetalDeep")
	end)
	EVO.Tiara(ctx, { H = 4 })
	EVO.Necklace(ctx, { Double = true, Drops = 4 })
end

EVO.Pets.candy_unicorn = function(ctx)
	EVO.ChestPlate(ctx)
	EVO.Necklace(ctx, { Pendant = false })
	EVO.Anklets(ctx, { Y = 5.4, Gem = "GemB" })
	EVO.Flower(ctx, { -4.6, ctx.HeadTop - 1.2, ctx.HeadC[3] - 4.4 }, 1, "PetalDeep")
end

EVO.Pets.moonlit_owl = function(ctx)
	evoHalo(ctx, 6, 3)
	EVO.Necklace(ctx, { R = 9.4, DY = -0.5, Tilt = 0.3, Double = true, Drops = 4 })
end

EVO.Pets.nebula_axolotl = function(ctx)
	local g = ctx.Body
	EVO.Necklace(ctx, { Double = true, Drops = 4 })
	EVO.Anklets(ctx, { Gem = "GemB" })
	if ctx.Fine then
		ctx.Pal.Star = { Color = rgb(240, 236, 255), Material = NEON }
		for _, p in ipairs({ { 4, 0, 6 }, { -5, 1, 2 }, { 6, -3, 12 }, { -3, -2, 14 }, { 2, 2, -2 } }) do
			box(g, "Star", { p[1], ctx.EvoBelly + 6 + p[2], p[3] }, { 1, 1, 1 }, { Op = "Paint", OnlyKeys = "Fur" })
		end
	end
end

EVO.Pets.ember_phoenix = function(ctx)
	EVO.Necklace(ctx, { R = 4.8, DY = -0.6, Tilt = 0.5, Drops = 2 })
end

EVO.Pets.sunbeam_bear = function(ctx)
	EVO.Crown(ctx, { R = 5.8, Points = 8 })
	EVO.ChestPlate(ctx)
	EVO.Necklace(ctx, { Pendant = false, Drops = 4 })
	EVO.Anklets(ctx, { Gem = "GemB" })
end

EVO.Pets.cloudy_dragon = function(ctx)
	local g = ctx.Body
	local c = ctx.HeadC
	pair(function(s)
		ell(g, "Cloud", { s * 10, c[2] - 2, c[3] + 1 }, { 2.8, 2.6, 2.8 })
	end)
	EVO.ChestPlate(ctx)
	EVO.Necklace(ctx, { Pendant = false })
	EVO.Anklets(ctx, { Gem = "Gem" })
end

EVO.Pets.starlight_unicorn = function(ctx)
	evoHalo(ctx, 6, 9)
	EVO.ChestPlate(ctx)
	EVO.Necklace(ctx, { Pendant = false, Drops = 4 })
	EVO.Anklets(ctx, { Y = 5.4, Gem = "Gem" })
end

EVO.Pets.stormfang = function(ctx)
	EVO.Necklace(ctx, { Gem = "Gem", Drops = 0, Size = 1.1 })
end

EVO.Pets.eclipse_dragon = function(ctx)
	EVO.ChestPlate(ctx)
	EVO.Necklace(ctx, { Pendant = false, Drops = 4 })
	EVO.Anklets(ctx)
end

EVO.Pets.obsidian_phoenix = function(ctx)
	EVO.Crown(ctx, { R = 4.6, Points = 7, Sink = 1.4 })
	EVO.Flower(ctx, { 5, ctx.HeadTop, ctx.HeadC[3] - 3 }, 0.9, "Petal")
	EVO.Necklace(ctx, { R = 4.8, DY = -0.6, Tilt = 0.5, Drops = 4 })
end

EVO.Pets.phantom_kitsune = function(ctx)
	evoHalo(ctx, 5.6, 6)
	EVO.Necklace(ctx, { Drops = 4 })
	local g = ctx.Body
	ell(g, "GemB", { 0, ctx.HeadTop - 1.2, ctx.HeadC[3] - 5.8 }, { 1.2, 1.5, 0.8 })
end

-- colours some evolved species need on top of the normal palette
local EVO_COLOURS = {
	ember_phoenix = function(pal)
		pal.Flame = { Color = rgb(255, 140, 36), Material = NEON }
		pal.FlameHot = { Color = rgb(255, 222, 90), Material = NEON }
		pal.WingTip = { Color = rgb(255, 214, 90), Material = NEON }
	end,
	obsidian_phoenix = function(pal)
		pal.Flame = { Color = rgb(236, 70, 200), Material = NEON }
		pal.FlameHot = { Color = rgb(255, 170, 230), Material = NEON }
		pal.WingTip = { Color = rgb(255, 176, 120), Material = NEON }
	end,
	cloudy_dragon = function(pal)
		pal.Cloud = rgb(250, 252, 255)
	end,
	twilight_dragon = function(pal)
		pal.Wing = rgb(206, 92, 206)
		pal.WingTip = rgb(244, 140, 220)
		pal.WingBone = rgb(96, 64, 178)
	end,
	eclipse_dragon = function(pal)
		pal.Wing = rgb(170, 60, 196)
		pal.WingTip = rgb(236, 104, 214)
		pal.WingBone = rgb(52, 36, 104)
		pal.Spine = rgb(250, 202, 72)
	end,
}
EVO.Colours = EVO_COLOURS

-- builds the evolved body / wings / tail into ctx (called by buildBlueprint for look.Evolved)
function EVO.Sculpt(ctx)
	local look = ctx.Look
	ctx.Ascended = look.Evolved == 2
	EVO.Palette(ctx)
	if EVO.Colours[look.Id] then
		EVO.Colours[look.Id](ctx.Pal)
	end
	if ctx.Ascended then
		ASC.Palette(ctx)
		ctx.Grow = ASC.Grow
		ctx.LimbK = ASC.LimbK
		ctx.Wing.K = SK * ASC.LimbK
	end
	local fn = EVO.Species[look.Species] or EVO.Species.Bear
	fn(ctx)
	local extra = (ctx.Ascended and ASC.Pets[look.Id]) or EVO.Pets[look.Id]
	if extra then
		extra(ctx)
	end
	if ctx.BodyShade then
		ctx.BodyShade.Noise = 0
		ctx.BodyShade.Crease = 0
		ctx.BodyShade.Smooth = 3
		ctx.BodyShade.LightAt = 0.6
		ctx.BodyShade.DarkAt = -0.3
	end
end

function EVO.SculptWing(ctx, w)
	local look = ctx.Look
	if ctx.Ascended then
		return ASC.SculptWings(ctx, w)
	end
	if look.Species == "Dragon" and look.WingStyle == "Bat" then
		EVO.BatWing(ctx, w)
	elseif look.Species == "Stormfang" then
		EVO.ShardWing(ctx, w)
	elseif look.Species == "Phoenix" then
		EVO.FlameWing(ctx, w)
	else
		EVO.Fan(ctx, w)
	end
end

----------------------------------------------------------------------
-- Second evolution (Epic, Legendary, Mythic and Secret pets): PetBuilder.Build(petDef, { Evolved = 2 })
-- The evolved form grown up: built 1.2x bigger and standing taller, a second, lower pair of wings, glowing (Neon)
-- wing tips and gold leading edges, gold armour (pauldrons, a chest plate set with a big glowing gem, greaves),
-- a signature crest per pet (crystal antlers, a candy horn, a crescent moon, a sun disc, an eclipse, a crown of
-- horns, a storm crest, nine tails...) and an aura of its element orbiting it (crystals, candies, stars, bubbles,
-- flames, little suns, shadow orbs, clouds, lightning bolts, obsidian shards, ghost fire).
----------------------------------------------------------------------
ASC.Grow = 1.2
ASC.LimbK = 0.8 -- wings and tails are sculpted at 0.8x the body's resolution (bigger blocks, fewer parts)

-- per pet: Glow / GlowB (the two Neon accent colours) and the element of its aura
ASC.Look = {
	aurora_fox = { Glow = { 130, 255, 228 }, GlowB = { 255, 130, 214 }, Aura = "Crystal" },
	candy_unicorn = { Glow = { 255, 120, 196 }, GlowB = { 120, 214, 255 }, Aura = "Heart" },
	moonlit_owl = { Glow = { 255, 232, 150 }, GlowB = { 176, 160, 255 }, Aura = "Star" },
	nebula_axolotl = { Glow = { 255, 118, 220 }, GlowB = { 130, 232, 255 }, Aura = "Bubble" },
	ember_phoenix = { Glow = { 255, 206, 70 }, GlowB = { 255, 120, 40 }, Aura = "Flame" },
	sunbeam_bear = { Glow = { 255, 216, 96 }, GlowB = { 255, 150, 60 }, Aura = "Sun" },
	twilight_dragon = { Glow = { 255, 120, 222 }, GlowB = { 176, 130, 255 }, Aura = "Orb" },
	cloudy_dragon = { Glow = { 110, 206, 255 }, GlowB = { 255, 228, 120 }, Aura = "Cloud" },
	starlight_unicorn = { Glow = { 206, 176, 255 }, GlowB = { 255, 236, 160 }, Aura = "Star" },
	stormfang = { Glow = { 90, 236, 255 }, GlowB = { 186, 126, 255 }, Aura = "Bolt" },
	eclipse_dragon = { Glow = { 255, 84, 204 }, GlowB = { 90, 240, 222 }, Aura = "Orb" },
	obsidian_phoenix = { Glow = { 255, 84, 214 }, GlowB = { 255, 176, 116 }, Aura = "Shard" },
	phantom_kitsune = { Glow = { 120, 255, 222 }, GlowB = { 196, 150, 255 }, Aura = "Wisp" },
}

function ASC.Palette(ctx)
	local pal, look = ctx.Pal, ctx.Look
	local st = ASC.Look[look.Id] or {}
	local G = st.Glow and evoRGB(st.Glow) or lighten(look.Secondary, 0.3)
	local GB = st.GlowB and evoRGB(st.GlowB) or lighten(look.WingColor, 0.4)
	pal.Glow = { Color = G, Material = NEON }
	pal.GlowB = { Color = GB, Material = NEON }
	pal.WingGlow = { Color = G, Material = NEON }
	pal.AuraA = { Color = G, Material = NEON }
	pal.AuraB = { Color = GB, Material = NEON }
	pal.AuraC = mix(G, rgb(255, 255, 255), 0.55)
	pal.Star = { Color = rgb(255, 250, 228), Material = NEON }
	pal.Armor = rgb(250, 200, 70)
	return st
end

local function hash3(x, y, z)
	local h = math.sin(x * 12.9898 + y * 78.233 + z * 37.719) * 43758.5453
	return h - floor(h)
end

-- glowing specks (stars) on the exposed voxels of the given keys: density = share of those voxels;
-- cond(x, y, z) (design units) may limit where
function ASC.Sprinkle(g, key, only, density, seed, cond)
	local cells = g.Cells
	local o = Voxel.Pack(0, 0, 0)
	local dx, dy, dz = Voxel.Pack(1, 0, 0) - o, Voxel.Pack(0, 1, 0) - o, Voxel.Pack(0, 0, 1) - o
	local hits = {}
	for k, v in pairs(cells) do
		if only[v] and not (cells[k + dx] and cells[k - dx] and cells[k + dy] and cells[k - dy] and cells[k + dz] and cells[k - dz]) then
			local x, y, z = Voxel.Unpack(k)
			local K = g.K or SK
			if hash3(x + (seed or 0), y, z) < density and (not cond or cond(x / K, y / K, z / K)) then
				hits[#hits + 1] = k
			end
		end
	end
	for _, k in ipairs(hits) do
		cells[k] = key
	end
end

----------------------------------------------------------------------
-- second-evolution armour (gold, set with gems)
----------------------------------------------------------------------
-- gold domes over the shoulders with a gem (o.Spikes: a horn-like spike on each)
function ASC.Pauldrons(ctx, o)
	local g = ctx.Body
	o = o or {}
	local L = ctx.Legs
	if not L then
		return
	end
	local by = ctx.EvoBelly
	local W = L.Front[1] / 5.3
	local fz = L.Front[2]
	pair(function(s)
		local c = { s * 8.5 * W, by + 1.8, fz + 0.8 }
		ell(g, "GoldDeep", { c[1], c[2] - 0.8, c[3] }, { 3, 4.2, 4.9 })
		ell(g, "Gold", { c[1] + s * 0.5, c[2], c[3] }, { 2.9, 3.8, 4.4 })
		ell(g, o.Gem or "Gem", { c[1] + s * 3.1, c[2] + 0.3, c[3] }, { 0.8, 1.3, 1.3 })
		if o.Spikes then
			cone(g, "Gold", { c[1] + s * 1.4, c[2] + 2.4, c[3] + 1.2 }, { c[1] + s * 4.2, c[2] + 6.4, c[3] + 3.6 }, 1.3, 0.2)
		end
	end)
end

-- gold bands round every leg (above the paw and at the knee) with a gem plate in front
function ASC.Greaves(ctx, o)
	local g = ctx.Body
	o = o or {}
	local L = ctx.Legs
	if not L then
		return
	end
	local G0 = EVO.Ground
	pair(function(s)
		for _, p in ipairs({ L.Front, L.Hind }) do
			local x, z = s * p[1], p[2]
			shape(g, { Kind = "Torus", Center = { x, G0 + 5.2, z + 0.2 }, Radius = 3.1, Thickness = 0.8, Key = "Gold" })
			ell(g, "Gold", { x, G0 + 5.4, z - 3 }, { 1.5, 2.2, 1 })
			ell(g, o.Gem or "Gem", { x, G0 + 5.4, z - 3.7 }, { 0.8, 1.1, 0.6 })
		end
	end)
end

-- a gold breast plate with a big glowing gem in a claw setting, small gems around it
function ASC.ChestPlate(ctx, o)
	local g = ctx.Body
	o = o or {}
	local by = ctx.EvoBelly or -6.5
	local zf = (o.Z or ctx.ChestZ or -12.9) -- the chest's front surface
	local y = by + (o.DY or 1.6)
	paint(g, "GoldDeep", { Kind = "Ellipsoid", Center = { 0, y, zf + 0.4 }, Radius = { 7.4, 7, 3.6 } })
	paint(g, "Gold", { Kind = "Ellipsoid", Center = { 0, y + 0.3, zf - 0.4 }, Radius = { 6.2, 6, 3.2 } })
	ell(g, "GoldDeep", { 0, y + 0.4, zf - 0.6 }, { 3.2, 3.6, 1.6 })
	ell(g, "Gold", { 0, y + 0.4, zf - 1.2 }, { 2.7, 3.1, 1.3 })
	ell(g, o.Gem or "Gem", { 0, y + 0.4, zf - 2 }, { 1.9, 2.3, 1.1 })
	for _, d in ipairs({ { 0, 3.6 }, { 0, -3.6 }, { 3, 0 }, { -3, 0 } }) do
		cone(g, "Gold", { d[1] * 0.7, y + 0.4 + d[2] * 0.7, zf - 1 }, { d[1] * 1.25, y + 0.4 + d[2] * 1.25, zf - 1.4 }, 0.8, 0.2)
	end
	pair(function(s)
		ell(g, o.GemB or "GemB", { s * 4.4, y + 3.2, zf - 0.6 }, { 0.8, 0.9, 0.7 })
		ell(g, o.GemB or "GemB", { s * 4.2, y - 2.6, zf - 0.6 }, { 0.8, 0.9, 0.7 })
	end)
	set(g, vx(-0.7), vx(y + 1.4), vx(zf - 3), "Spark")
end

----------------------------------------------------------------------
-- second-evolution wings: a bigger first pair and a second, lower pair (Wing2L / Wing2R)
----------------------------------------------------------------------
-- a big raised feathered wing (the LEFT wing in its hinge frame: -X out, +Y up): an arm rising up and out to the
-- wrist, four long primaries fanning out from the hand, four broad secondaries hanging from the arm so their tips
-- make a scalloped lower edge, a row of coverts over their roots (on the front side), a gold leading edge; light
-- tips that glow at the very end. Few, broad feathers: clean to look at and cheap in parts.
-- o: Size, Keys (primary keys, top first), Glow, EdgeKey, Sweep, Tilt
function ASC.AngelWing(ctx, w, o)
	o = o or {}
	local S = o.Size or 1
	local Wd = 0.6 + 0.4 * S
	local arm = { { 0, 0 }, { -4 * S, 5.6 * S }, { -9 * S, 11.4 * S }, { -14 * S, 16.6 * S }, { -18 * S, 21 * S } }
	local function armAt(t)
		local f = t * (#arm - 1)
		local i = math.min(#arm - 1, floor(f) + 1)
		local u = f - (i - 1)
		local a, b = arm[i], arm[i + 1]
		return { a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u }
	end
	local function quill(key, p, deg, ln, wd, z, tip, hot)
		local ang = math.rad(deg)
		local dx, dy = math.cos(ang), math.sin(ang)
		local b = { p[1] + dx * ln, p[2] + dy * ln }
		evoFeather(w, key, p, b, wd, z)
		if tip then
			local tc = { b[1] - dx * ln * 0.14, b[2] - dy * ln * 0.14, z }
			shape(w, { Kind = "Ellipsoid", Center = tc, Radius = { ln * 0.2, wd + 0.6, 1.2 }, Key = tip, Op = "Paint", OnlyKeys = { [key] = true }, Rotation = CFrame.Angles(0, 0, ang), Pivot = tc })
		end
		if hot then
			local gc = { b[1] - dx * ln * 0.04, b[2] - dy * ln * 0.04, z }
			shape(w, { Kind = "Ellipsoid", Center = gc, Radius = { ln * 0.1, wd + 0.6, 1.2 }, Key = "WingGlow", Op = "Paint", OnlyKeys = { [key] = true, [tip or key] = true }, Rotation = CFrame.Angles(0, 0, ang), Pivot = gc })
		end
	end
	-- primaries from the hand: up-and-out at the top to out-and-down, the longest in the middle
	for i = 3, 0, -1 do
		local f = i / 3
		local key = o.Keys and o.Keys[i % #o.Keys + 1] or ((i % 2 == 0) and "Wing" or "WingTrim")
		quill(key, armAt(0.98 - 0.24 * f), 148 + 54 * f, (16 + 2.6 * math.sin(math.pi * (0.3 + 0.7 * f))) * S, 3.1 * Wd, 0, "WingTip", o.Glow)
	end
	-- secondaries hanging from the arm, out and down, shorter towards the body
	for i = 3, 0, -1 do
		local f = i / 3
		quill((i % 2 == 0) and "WingTrim" or "Wing", armAt(0.66 - 0.58 * f), 214 + 40 * f, (12.4 - 4.6 * f) * S, 3.5 * Wd, 0.3, "WingTip", o.Glow and i == 0)
	end
	-- coverts over the roots (front side)
	for i = 3, 0, -1 do
		local f = i / 3
		quill((i % 2 == 0) and "WingCov" or "WingCov2", armAt(0.92 - 0.8 * f), 200 + 48 * f, (8.4 - 1.8 * f) * S, 3.1 * Wd, -1.1, nil)
	end
	local pts = {}
	for i, a in ipairs(arm) do
		pts[i] = { a[1], a[2] + 0.5, 0 }
	end
	curve(w, o.EdgeKey or "Wing", pts, 1.3 * Wd, 0.9 * Wd, { Smooth = true })
	ctx.WingSweep = o.Sweep or 0.62
	ctx.WingTilt = o.Tilt or 0.2
end

function ASC.SculptWings(ctx, w)
	local look = ctx.Look
	local w2 = Voxel.NewGrid(30)
	w2.K = w.K
	local h = ctx.WingHinge
	local off = ctx.Wing2Offset or { -0.8, -4.4, 6 }
	local o1, o2 = ctx.WingOpts or {}, ctx.Wing2Opts or {}
	local function opts(base, extra)
		for k, v in pairs(extra) do
			base[k] = v
		end
		return base
	end
	local sweep2, tilt2
	if look.Species == "Dragon" and look.WingStyle == "Bat" then
		EVO.BatWing(ctx, w2, opts({ Size = 0.66, Glow = true, GlowWidth = 1.1 }, o2))
		sweep2, tilt2 = ctx.WingSweep + 0.12, ctx.WingTilt - 0.42
		EVO.BatWing(ctx, w, opts({ Size = 1.22, Glow = true, GlowWidth = 1.4 }, o1))
	elseif look.Species == "Stormfang" then
		local pal = ctx.Pal
		pal.Wing = rgb(40, 50, 92)
		pal.WingTip = rgb(62, 80, 148)
		pal.WingBone = { Color = rgb(90, 236, 255), Material = NEON }
		pal.Claw = { Color = rgb(200, 250, 255), Material = NEON }
		pal.WingGlow = { Color = rgb(186, 126, 255), Material = NEON }
		EVO.BatWing(ctx, w2, opts({ Size = 0.66, Glow = true, GlowWidth = 1.1 }, o2))
		sweep2, tilt2 = ctx.WingSweep + 0.12, ctx.WingTilt - 0.42
		EVO.BatWing(ctx, w, opts({ Size = 1.18, Glow = true, GlowWidth = 1.4 }, o1))
	elseif look.Species == "Phoenix" then
		EVO.FlameWing(ctx, w2, opts({ Size = 0.7 }, o2))
		sweep2, tilt2 = 1.15, -0.1
		EVO.FlameWing(ctx, w, opts({ Size = 1.22, N = 6, Long = 1.08, Tilt = 0.72 }, o1))
	else
		ASC.AngelWing(ctx, w2, opts({ Size = 0.72, Glow = true, Sweep = 0.5, Tilt = -0.3 }, o2))
		sweep2, tilt2 = ctx.WingSweep, ctx.WingTilt
		ASC.AngelWing(ctx, w, opts({ Size = 1.06, Glow = true, Sweep = 0.05, Tilt = 0.5 }, o1))
	end
	if ctx.NoWing2 then
		return
	end
	ctx.Wing2 = w2
	ctx.Wing2Hinge = { h[1] + off[1], h[2] + off[2], h[3] + off[3] }
	ctx.Wing2Sweep, ctx.Wing2Tilt = sweep2, tilt2
	if ctx.WingAfter then
		ctx.WingAfter(w, w2)
	end
end

----------------------------------------------------------------------
-- the elemental aura: small glowing things orbiting the pet (group "Aura", kind "orbit")
----------------------------------------------------------------------
local function auraKey(i)
	return (i % 2 == 0) and "AuraA" or "AuraB"
end

ASC.AuraBits = {
	Crystal = function(a, p, i)
		local k = auraKey(i)
		cone(a, k, p, { p[1], p[2] + 3.4, p[3] }, 1.4, 0)
		cone(a, k, p, { p[1], p[2] - 2.4, p[3] }, 1.4, 0)
	end,
	Star = function(a, p, i)
		local k = auraKey(i)
		ell(a, k, p, { 1.1, 1.1, 1.1 })
		cone(a, k, p, { p[1], p[2] + 2.8, p[3] }, 0.9, 0)
		cone(a, k, p, { p[1], p[2] - 2.8, p[3] }, 0.9, 0)
		cone(a, k, p, { p[1] + 2.8, p[2], p[3] }, 0.9, 0)
		cone(a, k, p, { p[1] - 2.8, p[2], p[3] }, 0.9, 0)
	end,
	Flame = function(a, p, i)
		ell(a, "AuraA", p, { 1.5, 1.5, 1.5 })
		cone(a, "AuraB", { p[1], p[2] + 0.8, p[3] }, { p[1] + 0.4, p[2] + 4.4, p[3] }, 1.3, 0)
	end,
	Bubble = function(a, p, i)
		ell(a, "AuraC", p, { 1.6, 1.6, 1.6 })
		ell(a, auraKey(i), { p[1] - 0.6, p[2] + 0.6, p[3] - 0.6 }, { 0.7, 0.7, 0.7 })
	end,
	Heart = function(a, p, i)
		local k = auraKey(i)
		ell(a, k, { p[1] - 0.9, p[2] + 0.7, p[3] }, { 1.2, 1.2, 0.9 })
		ell(a, k, { p[1] + 0.9, p[2] + 0.7, p[3] }, { 1.2, 1.2, 0.9 })
		cone(a, k, { p[1], p[2] + 0.5, p[3] }, { p[1], p[2] - 2.2, p[3] }, 1.9, 0)
	end,
	Sun = function(a, p, i)
		ell(a, "AuraA", p, { 1.4, 1.4, 1.4 })
		for r = 0, 3 do
			local ang = r * math.pi / 2 + 0.785
			cone(a, "AuraB", { p[1] + math.cos(ang) * 1.2, p[2] + math.sin(ang) * 1.2, p[3] }, { p[1] + math.cos(ang) * 3, p[2] + math.sin(ang) * 3, p[3] }, 0.6, 0)
		end
	end,
	Orb = function(a, p, i, ctx)
		ell(a, "AuraDark", p, { 1.5, 1.5, 1.5 })
		if ctx.High then
			shape(a, { Kind = "Torus", Center = p, Radius = 2.1, Thickness = 0.4, Key = auraKey(i), Rotation = CFrame.Angles(0.5, 0, 0.3), Pivot = p })
		else
			ell(a, auraKey(i), { p[1] - 0.5, p[2] + 0.5, p[3] - 0.5 }, { 0.8, 0.8, 0.8 })
		end
	end,
	Cloud = function(a, p, i)
		ell(a, "AuraC", { p[1] - 1.2, p[2], p[3] }, { 1.6, 1.3, 1.4 })
		ell(a, "AuraC", { p[1] + 1.2, p[2] + 0.2, p[3] }, { 1.7, 1.4, 1.5 })
		ell(a, "AuraC", { p[1], p[2] + 1, p[3] }, { 1.4, 1.3, 1.3 })
		cap(a, "AuraA", { p[1] + 0.4, p[2] - 1.2, p[3] }, { p[1] - 0.6, p[2] - 2.8, p[3] }, 0.45, 0.4)
		cap(a, "AuraA", { p[1] - 0.6, p[2] - 2.8, p[3] }, { p[1] + 0.2, p[2] - 4.2, p[3] }, 0.4, 0.3)
	end,
	Bolt = function(a, p, i)
		local k = auraKey(i)
		cap(a, k, { p[1] - 1, p[2] + 3, p[3] }, { p[1] + 0.9, p[2] + 0.6, p[3] }, 0.55, 0.5)
		cap(a, k, { p[1] + 0.9, p[2] + 0.6, p[3] }, { p[1] - 0.7, p[2] - 0.2, p[3] }, 0.5, 0.5)
		cap(a, k, { p[1] - 0.7, p[2] - 0.2, p[3] }, { p[1] + 1, p[2] - 3, p[3] }, 0.5, 0.3)
	end,
	Shard = function(a, p, i)
		cone(a, "AuraDark", p, { p[1] + 0.5, p[2] + 3.8, p[3] + 0.3 }, 1.3, 0)
		cone(a, "AuraDark", p, { p[1] - 0.3, p[2] - 2.2, p[3] }, 1.3, 0)
		ell(a, auraKey(i), { p[1] + 0.3, p[2] + 2.6, p[3] }, { 0.6, 1, 0.6 })
	end,
	Wisp = function(a, p, i)
		local k = auraKey(i)
		ell(a, k, p, { 1.5, 1.5, 1.5 })
		curve(a, k, { { p[1], p[2] + 0.8, p[3] }, { p[1] + 0.8, p[2] + 2.8, p[3] }, { p[1] - 0.3, p[2] + 4.6, p[3] } }, 1.1, 0.2, { Smooth = true })
	end,
}

function ASC.Aura(ctx, kind, o)
	o = o or {}
	local a = Voxel.NewGrid(30)
	local n = o.N or (ctx.High and 8 or 6)
	local R = o.R or 23
	local fn = ASC.AuraBits[kind] or ASC.AuraBits.Star
	for i = 0, n - 1 do
		local ang = (i + 0.5) / n * TAU + (o.Phase or 0)
		local y = (i % 2 == 0) and 4 or -1.5
		fn(a, { math.cos(ang) * R, y + (o.Y or 0), math.sin(ang) * R }, i, ctx)
	end
	ctx.AuraGrid = a
	ctx.AuraAt = o.At or { 0, (ctx.EvoBelly or -6.5) + 6, 1.5 }
	ctx.Pal.AuraDark = ctx.Pal.AuraDark or rgb(46, 30, 72)
end

----------------------------------------------------------------------
-- floating crests (the Halo group: they bob gently)
----------------------------------------------------------------------
-- a radiant sun disc standing behind the head: a glowing disc in a gold ring, long and short rays
function ASC.SunDisc(ctx, o)
	o = o or {}
	local h = Voxel.NewGrid(30)
	local R = o.R or 7.5
	local up = CFrame.Angles(math.pi / 2, 0, 0)
	ell(h, "SunCore", { 0, 0, 0.4 }, { R, R, 0.8 })
	shape(h, { Kind = "Torus", Center = { 0, 0, 0 }, Radius = R + 0.5, Thickness = 0.9, Key = "Gold", Rotation = up, Pivot = { 0, 0, 0 } })
	local n = o.Rays or 12
	for i = 0, n - 1 do
		local a = (i + 0.5) / n * TAU
		local long = (i % 2 == 0)
		local r1, r2 = R + 1, R + (long and 6.6 or 4)
		cone(h, long and "SunRay" or "Gold", { math.cos(a) * r1, math.sin(a) * r1, 0.4 }, { math.cos(a) * r2, math.sin(a) * r2, 0.4 }, long and 1.5 or 1.1, 0.15)
	end
	ctx.Halo = h
	ctx.HaloAt = o.At or { 0, ctx.HeadC[2] + 2.5, ctx.HeadC[3] + ctx.HeadR[3] + 2.4 }
	ctx.Pal.SunCore = { Color = rgb(255, 150, 40), Material = NEON }
	ctx.Pal.SunRay = { Color = rgb(255, 236, 150), Material = NEON }
end

-- a sunburst round the face: long glowing rays and short gold ones standing out of the back of the head like a
-- mane (none under the chin)
function ASC.SunMane(ctx, o)
	o = o or {}
	local g = ctx.Body
	local c, r = ctx.HeadC, ctx.HeadR
	local z = c[3] + (o.Back or 3.2)
	local n = o.Rays or 15
	for i = 0, n - 1 do
		local a = math.rad(-38 + 256 * i / (n - 1))
		local long = (i % 2 == 0)
		local r1 = math.min(r[1], r[2]) * 0.82
		local r2 = r1 + (long and 8.4 or 5.4)
		local ca, sa = math.cos(a), math.sin(a)
		cone(g, long and "SunRay" or "Gold", { ca * r1, c[2] + sa * r1, z }, { ca * r2 * 1.06, c[2] + sa * r2, z + 1.6 }, long and 2 or 1.5, 0.2)
	end
	ctx.Pal.SunRay = { Color = rgb(255, 176, 56), Material = NEON }
end

-- an eclipse floating above the head: a black sun in a glowing corona ring with flares
function ASC.Eclipse(ctx, o)
	o = o or {}
	local h = Voxel.NewGrid(30)
	local R = o.R or 3.6
	ell(h, "EclipseDark", { 0, 0, 0 }, { R, R, R })
	local up = CFrame.Angles(math.pi / 2 - 0.25, 0, 0)
	shape(h, { Kind = "Torus", Center = { 0, 0, 0 }, Radius = R + 1.2, Thickness = 0.8, Key = "Glow", Rotation = up, Pivot = { 0, 0, 0 } })
	for i = 0, 7 do
		local a = (i + 0.5) / 8 * TAU
		local d = up * Vector3.new(math.cos(a), 0, math.sin(a))
		local r1, r2 = R + 2, R + ((i % 2 == 0) and 4.8 or 3.4)
		cone(h, (i % 2 == 0) and "Glow" or "GlowB", { d.X * r1, d.Y * r1, d.Z * r1 }, { d.X * r2, d.Y * r2, d.Z * r2 }, 0.8, 0.1)
	end
	ctx.Halo = h
	ctx.HaloAt = o.At or { 0, ctx.HeadTop + (o.Lift or 8), ctx.HeadC[3] + 2 }
	ctx.Pal.EclipseDark = rgb(22, 14, 38)
end

-- a crescent moon floating above the head (upright, facing forward) with a little star in its arms
function ASC.Crescent(ctx, o)
	o = o or {}
	local h = Voxel.NewGrid(30)
	local R = o.R or 6.4
	ell(h, "Moon", { 0, 0, 0 }, { R, R, 1.2 })
	carve(h, { Kind = "Ellipsoid", Center = { -R * 0.42, R * 0.34, 0 }, Radius = { R * 0.86, R * 0.86, 3 } })
	ell(h, "Glow", { -R * 0.5, R * 0.3, 0 }, { 1, 1, 1 })
	cone(h, "Glow", { -R * 0.5, R * 0.3, 0 }, { -R * 0.5, R * 0.3 + 2.2, 0 }, 0.6, 0)
	cone(h, "Glow", { -R * 0.5, R * 0.3, 0 }, { -R * 0.5, R * 0.3 - 2.2, 0 }, 0.6, 0)
	cone(h, "Glow", { -R * 0.5, R * 0.3, 0 }, { -R * 0.5 + 2.2, R * 0.3, 0 }, 0.6, 0)
	cone(h, "Glow", { -R * 0.5, R * 0.3, 0 }, { -R * 0.5 - 2.2, R * 0.3, 0 }, 0.6, 0)
	ctx.Halo = h
	ctx.HaloAt = o.At or { 0, ctx.HeadTop + 7.5, ctx.HeadC[3] + 2 }
	ctx.Pal.Moon = { Color = rgb(255, 238, 168), Material = NEON }
end

-- a tilted gold halo with glowing points (stars or lightning) standing out of it
function ASC.PointHalo(ctx, o)
	o = o or {}
	local h = Voxel.NewGrid(30)
	local R = o.R or 6.4
	local tilt = CFrame.Angles(-0.45, 0, 0)
	shape(h, { Kind = "Torus", Center = { 0, 0, 0 }, Radius = R, Thickness = 0.8, Key = "HaloGlow", Rotation = tilt, Pivot = { 0, 0, 0 } })
	local n = o.Points or 6
	for i = 0, n - 1 do
		local a = (i + 0.5) / n * TAU
		local p = tilt * Vector3.new(math.cos(a) * R, 0, math.sin(a) * R)
		local q = { p.X, p.Y, p.Z }
		if o.Bolts then
			local up = { q[1] * 0.08, q[2] + 1, q[3] * 0.08 }
			cap(h, "Glow", q, { q[1] + up[1] + 0.8, q[2] + 2.2, q[3] }, 0.45, 0.4)
			cap(h, "Glow", { q[1] + up[1] + 0.8, q[2] + 2.2, q[3] }, { q[1] - 0.2, q[2] + 2.8, q[3] }, 0.4, 0.4)
			cap(h, "Glow", { q[1] - 0.2, q[2] + 2.8, q[3] }, { q[1] + 0.6, q[2] + 5, q[3] }, 0.4, 0.2)
		else
			ell(h, "Glow", { q[1], q[2] + 0.6, q[3] }, { 0.8, 0.8, 0.8 })
			cone(h, "Glow", { q[1], q[2] + 0.6, q[3] }, { q[1], q[2] + 3.4, q[3] }, 0.7, 0)
			cone(h, "Glow", { q[1] - 1.6, q[2] + 0.9, q[3] }, { q[1] + 1.6, q[2] + 0.9, q[3] }, 0.45, 0.45)
		end
	end
	ctx.Halo = h
	ctx.HaloAt = o.At or { 0, ctx.HeadTop + (o.Lift or 4), ctx.HeadC[3] + 1 }
	ctx.Pal.HaloGlow = { Color = rgb(255, 222, 120), Material = NEON }
end

----------------------------------------------------------------------
-- second-evolution tails
----------------------------------------------------------------------
-- a tail path (in the YZ plane, reaching back / up) leaning sideways by angle a about the tail's own axis
local function leanPts(pts, a, scale)
	local sa, ca = math.sin(a), math.cos(a)
	local q = {}
	for i, p in ipairs(pts) do
		local x, y = p[1] * (scale or 1), p[2] * (scale or 1)
		q[i] = { x * ca - y * sa, x * sa + y * ca, p[3] * (scale or 1) }
	end
	return q
end

-- a bushy tail on grid t leaning by a, with a light tip (tipKey) and a glowing end (glowKey)
function ASC.Brush(t, pts, a, r0, r1, key, tipKey, glowKey, scale)
	local q = leanPts(pts, a, scale)
	curve(t, key, q, r0, r1, { Smooth = true })
	local n = #q
	local tp, pv = q[n], q[n - 1]
	if tipKey then
		ell(t, tipKey, tp, { r1 + 1.6, r1 + 1.6, r1 + 1.6 }, { Op = "Paint", OnlyKeys = key })
	end
	if glowKey then
		local dx, dy, dz = tp[1] - pv[1], tp[2] - pv[2], tp[3] - pv[3]
		local d = math.sqrt(dx * dx + dy * dy + dz * dz)
		local e = { tp[1] + dx / d * r1 * 0.55, tp[2] + dy / d * r1 * 0.55, tp[3] + dz / d * r1 * 0.55 }
		ell(t, glowKey, e, { r1 * 0.7, r1 * 0.7, r1 * 0.7 }, { Op = "Paint", OnlyKeys = { [key] = true, [tipKey or key] = true } })
	end
end

----------------------------------------------------------------------
-- the second evolutions, pet by pet (after the species sculpt, which reads ctx.Ascended)
----------------------------------------------------------------------
ASC.Pets.aurora_fox = function(ctx)
	local g, pal = ctx.Body, ctx.Pal
	local top, z = ctx.HeadTop, ctx.HeadC[3] + 2.6
	pal.Crystal = rgb(255, 196, 228)
	pal.CrystalDeep = rgb(246, 150, 202)
	-- tall branching crystal antlers behind the ears, glowing tips, blossoms in the forks
	pair(function(s)
		curve(g, "Crystal", { { s * 3, top - 3, z }, { s * 4.6, top + 3.4, z + 1 }, { s * 8, top + 8.6, z + 2.4 }, { s * 10.2, top + 14, z + 3.4 } }, 1.9, 1, { Smooth = true })
		curve(g, "CrystalDeep", { { s * 5, top + 4.8, z + 1.2 }, { s * 3.6, top + 9, z + 0.8 }, { s * 3.4, top + 11.6, z + 0.6 } }, 1.05, 0.55, { Smooth = true })
		curve(g, "CrystalDeep", { { s * 8, top + 8.6, z + 2.4 }, { s * 11, top + 9.8, z + 1.8 }, { s * 13.6, top + 10.6, z + 1.2 } }, 0.95, 0.5, { Smooth = true })
		ell(g, "GlowB", { s * 10.3, top + 14.4, z + 3.4 }, { 1.2, 1.4, 1.2 })
		ell(g, "Glow", { s * 3.4, top + 12, z + 0.6 }, { 1, 1.2, 1 })
		ell(g, "Glow", { s * 13.9, top + 10.8, z + 1.2 }, { 1, 1.1, 1 })
		EVO.Flower(ctx, { s * 6.4, top + 6.4, z - 0.2 }, 0.8)
	end)
	EVO.Tiara(ctx, { H = 4 })
	EVO.Necklace(ctx, { Double = true, Drops = 4, Pendant = false })
	ASC.ChestPlate(ctx)
	ASC.Greaves(ctx)
	-- three big bushy tails fanning up behind, white tips glowing aurora pink
	local t = newTail(ctx, ctx.TailHinge, 0.25)
	local path = { { 0, 0, 0 }, { 0, 2, 6 }, { 0, 7, 11 }, { 0, 13, 12 }, { 0, 17, 9 } }
	for _, a in ipairs({ -0.62, 0.62, 0 }) do
		ASC.Brush(t, path, a, 2.7, 3.9, "Fur", "Belly", "GlowB", (a == 0) and 1.08 or 1)
	end
	ctx.WingAfter = function(w, w2)
		ASC.Sprinkle(w, "Star", { Wing = true, WingTrim = true, WingCov = true }, 0.012, 3)
	end
	ASC.Aura(ctx, "Crystal")
end

ASC.Pets.candy_unicorn = function(ctx)
	local g, pal = ctx.Body, ctx.Pal
	local c = ctx.HeadC
	-- a long candy horn: a white cone with a pink spiral, glowing at the tip
	pal.Candy = rgb(255, 250, 252)
	pal.CandyStripe = rgb(255, 120, 186)
	local a, b = { 0, c[2] + 6.8, c[3] - 3.4 }, { 0, c[2] + 25, c[3] - 8.2 }
	cone(g, "Candy", a, b, 2.9, 0.35)
	local slope = (b[3] - a[3]) / (b[2] - a[2])
	paint(g, "CandyStripe", { Kind = "Cone", A = a, B = b, Radius = 3.3, RadiusB = 0.7, Pattern = function(x, y, zz)
		local ang = math.atan2(x, zz - (a[3] + (y - a[2]) * slope))
		if floor((y - a[2]) / 2.2 + ang / math.pi) % 2 == 0 then
			return "CandyStripe"
		end
		return false
	end }, "Candy")
	ell(g, "Glow", { b[1], b[2] + 0.4, b[3] }, { 1, 1.4, 1 })
	-- a fuller pastel rainbow mane down the neck and a bigger forelock
	pal.Mane4 = rgb(255, 238, 150)
	pal.Mane5 = rgb(176, 236, 214)
	local keys = { "Mane", "Mane3", "Mane4", "Mane5", "Mane2" }
	for i = 0, 9 do
		local t = i / 9
		ell(g, keys[i % 5 + 1], { 1.4 * ((i % 2 == 0) and 1 or -1) - 1, c[2] + 7 - t * 17, c[3] + 6.6 + t * 6 }, { 3.6, 4, 3.6 })
	end
	ell(g, "Mane4", { 2.4, c[2] + 6.8, c[3] - 5.4 }, { 3, 2.4, 2.4 })
	ell(g, "Mane5", { -2.4, c[2] + 6.4, c[3] - 4.8 }, { 2.8, 2.2, 2.2 })
	-- a heart gem on a gold circlet, a chest plate, greaves and pauldrons
	EVO.Tiara(ctx, { H = 3.6, Gem = "GemB" })
	ASC.ChestPlate(ctx)
	ASC.Greaves(ctx, { Gem = "GemB" })
	EVO.Necklace(ctx, { Pendant = false, Drops = 4 })
	-- a long flowing tail in rainbow bands
	local t = newTail(ctx, ctx.TailHinge, 0.3)
	shape(t, { Kind = "Curve", Key = "Mane", Smooth = true, Points = { { 0, 0, 0 }, { 0, 1.6, 5 }, { 0.6, -3, 11 }, { 1.4, -10, 14.4 }, { 2.2, -16.6, 13.4 } }, Radii = { 2.4, 3.4, 3.8, 3.4, 1.6 } })
	paint(t, "Mane", { Kind = "Box", Center = { 0, -6, 9 }, Size = { 14, 28, 26 }, Pattern = function(x, y, z)
		return keys[floor((z * 0.5 - y) / 3.2) % 5 + 1]
	end }, "Mane")
	-- rainbow wings: every flight feather another candy colour
	pal.Rain1 = rgb(255, 156, 206)
	pal.Rain2 = rgb(255, 206, 150)
	pal.Rain3 = rgb(255, 240, 160)
	pal.Rain4 = rgb(170, 236, 206)
	pal.Rain5 = rgb(156, 214, 255)
	pal.Rain6 = rgb(206, 176, 255)
	ctx.WingOpts = { Keys = { "Rain6", "Rain5", "Rain4", "Rain3", "Rain2", "Rain1", "Rain1" } }
	ctx.Wing2Opts = { Keys = { "Rain5", "Rain4", "Rain3", "Rain2", "Rain1" } }
	ASC.Aura(ctx, "Heart")
end

ASC.Pets.moonlit_owl = function(ctx)
	local g, pal = ctx.Body, ctx.Pal
	local c = ctx.HeadC
	ASC.Crescent(ctx, { R = 6.6 })
	-- long ear tufts tipped with moonlight
	pair(function(s)
		cone(g, "Fur", { s * 7, c[2] + 7, c[3] + 0.6 }, { s * 11.4, c[2] + 16.4, c[3] + 3 }, 2.4, 0.35)
		ell(g, "Glow", { s * 11.2, c[2] + 15.8, c[3] + 2.9 }, { 1, 1.3, 1 }, { Op = "Paint", OnlyKeys = "Fur" })
	end)
	-- a gold mask round the eyes
	pair(function(s)
		paint(g, "Gold", { Kind = "Torus", Center = { s * 4.8, c[2] + 0.4, c[3] - 8.4 }, Radius = 4.6, Thickness = 0.7, Rotation = CFrame.Angles(math.pi / 2, 0, 0), Pivot = { s * 4.8, c[2] + 0.4, c[3] - 8.4 } }, { EyeRing = true, Belly = true, Fur = true })
	end)
	EVO.Necklace(ctx, { R = 9.4, DY = -0.5, Tilt = 0.3, Double = true, Drops = 6, Size = 1.25 })
	-- a fan of long tail feathers with glowing tips
	local t = newTail(ctx, ctx.TailHinge, 0.15)
	for i = -2, 2 do
		local a = i * 0.3
		local tip = { math.sin(a) * 9, -2 - math.abs(i) * 0.6, 10 + math.cos(a) * 3 }
		evoFeather(t, (i % 2 == 0) and "Fur" or "WingTrim", { 0, 0, 0 }, { tip[1], tip[2], tip[3] }, 2.3, 0)
		ell(t, "Glow", { tip[1] * 0.92, tip[2] * 0.92, tip[3] * 0.94 }, { 1.3, 1.6, 1.3 }, { Op = "Paint", OnlyKeys = { Fur = true, WingTrim = true } })
	end
	ctx.WingAfter = function(w, w2)
		ASC.Sprinkle(w, "Star", { Wing = true, WingTrim = true, WingCov = true, WingCov2 = true }, 0.018, 5)
		ASC.Sprinkle(w2, "Star", { Wing = true, WingTrim = true }, 0.02, 7)
	end
	ctx.Wing2Offset = { -0.6, -5.4, 4.2 }
	ASC.Aura(ctx, "Star", { R = 20 })
end

ASC.Pets.nebula_axolotl = function(ctx)
	local g, pal = ctx.Body, ctx.Pal
	local c = ctx.HeadC
	-- a crown of long glowing gills above the old ones
	pair(function(s)
		for i = 0, 1 do
			local a = { s * 8.8, c[2] + 6.4 - i * 2, c[3] + 2.4 }
			local b = { s * (16.5 + i * 2), c[2] + 13 - i * 3.4, c[3] + 5 }
			curve(g, "Gill", { a, { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2 + 1.6, c[3] + 3.6 }, b }, 1.4, 0.9, { Smooth = true })
			for k = 1, 4 do
				local f = k / 4.6
				local p = { a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f + 1.2, a[3] + (b[3] - a[3]) * f }
				ell(g, (k == 4) and "Glow" or "GillTip", { p[1], p[2] + 1.7, p[3] }, { 1, 1.5, 1 })
			end
			ell(g, "Glow", b, { 1.3, 1.3, 1.3 })
		end
	end)
	-- a nebula back: a glowing fin crest from the head to the tail, star specks over the fur
	pal.Fin = mix(ctx.Look.Secondary, rgb(255, 255, 255), 0.2)
	local by = ctx.EvoBelly
	for i = 0, 8 do
		local zz = -6 + i * 2.6
		local hgt = 3.2 - math.abs(i - 3.5) * 0.35
		ell(g, "Fin", { 0, by + 7.6 + hgt * 0.5, zz }, { 0.9, hgt, 1.8 })
		ell(g, "Glow", { 0, by + 7.6 + hgt * 1.2, zz }, { 0.8, 0.9, 1.4 }, { Op = "Paint", OnlyKeys = "Fin" })
	end
	ASC.Sprinkle(g, "Star", { Fur = true }, 0.012, 11)
	EVO.Tiara(ctx, { H = 3.8 })
	EVO.Necklace(ctx, { Double = true, Drops = 4, Pendant = false })
	ASC.ChestPlate(ctx)
	ASC.Greaves(ctx, { Gem = "GemB" })
	-- a long tail with a big glowing-edged fin
	local t = newTail(ctx, ctx.TailHinge, 0.3)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, -0.6, 7 }, { 1.6, -1.4, 14 }, { 3.6, -1.2, 21 } }, 3.6, 1.4, { Smooth = true })
	ell(t, "Fin", { 1.4, 2.2, 12 }, { 1, 3, 10.4 })
	ell(t, "Fin", { 1.4, -5, 12 }, { 1, 2.8, 9.4 })
	ell(t, "Glow", { 1.4, 4.4, 12 }, { 0.9, 1, 9 }, { Op = "Paint", OnlyKeys = "Fin" })
	ell(t, "Glow", { 1.4, -7.2, 12 }, { 0.9, 1, 8 }, { Op = "Paint", OnlyKeys = "Fin" })
	ASC.Sprinkle(t, "Star", { Fur = true }, 0.02, 13)
	ctx.WingAfter = function(w, w2)
		ASC.Sprinkle(w, "Star", { Wing = true, WingTrim = true, WingCov = true }, 0.014, 17)
	end
	ASC.Aura(ctx, "Bubble")
	pal.AuraC = rgb(186, 236, 255)
end

-- the phoenixes' train: seven long flame plumes sweeping back and down to the ground, glowing ends, and two
-- streamers rising and curling over them
local function ascPhoenixTail(ctx)
	local t = newTail(ctx, ctx.TailHinge, 0.2)
	for i = -3, 3 do
		local x = i * 1.7
		local key = (i % 2 == 0) and "Flame" or "Wing"
		local len = 1 - math.abs(i) * 0.06
		local p = { { x * 0.4, 0, 0 }, { x * 1.1, -0.4, 7 * len }, { x * 1.7, -3.2, 14 * len }, { x * 2.2, -7.8 - math.abs(i) * 0.4, 21 * len } }
		curve(t, key, p, 2.4, 0.8, { Smooth = true })
		ell(t, "FlameHot", p[4], { 1.6, 2, 1.6 })
	end
	pair(function(s)
		local p = { { s * 0.6, 0.6, 0 }, { s * 2, 5, 5 }, { s * 4.4, 11, 9 }, { s * 7.4, 14, 8 }, { s * 9, 12.6, 5.6 } }
		curve(t, "Flame", p, 1.6, 0.6, { Smooth = true })
		ell(t, "FlameHot", p[5], { 1.3, 1.3, 1.3 })
	end)
end

ASC.Pets.ember_phoenix = function(ctx)
	local g = ctx.Body
	local c = ctx.HeadC
	-- a taller crest of flames
	local crest = { { 0, -0.5, 15 }, { 2.6, 1, 12 }, { -2.6, 1, 12 }, { 1.2, 3.4, 11 }, { -1.2, 3.4, 11 } }
	for i, f in ipairs(crest) do
		local base = { f[1] * 0.5, ctx.HeadTop - 1.6, c[3] + f[2] }
		local tip = { f[1] * 1.5, ctx.HeadTop + f[3], c[3] + f[2] + f[3] * 0.62 }
		local mid = { (base[1] + tip[1]) / 2, (base[2] + tip[2]) / 2 + 1, (base[3] + tip[3]) / 2 - 1.2 }
		curve(g, (i % 2 == 1) and "FlameHot" or "Flame", { base, mid, tip }, 2, 0.35, { Smooth = true })
	end
	EVO.Tiara(ctx, { H = 2.6, Side = false })
	EVO.Necklace(ctx, { R = 4.8, DY = -0.6, Tilt = 0.5, Double = true, Drops = 4 })
	ascPhoenixTail(ctx)
	ASC.Aura(ctx, "Flame", { R = 20 })
end

ASC.Pets.obsidian_phoenix = function(ctx)
	local g, pal = ctx.Body, ctx.Pal
	local c = ctx.HeadC
	pal.Obsidian = rgb(30, 24, 44)
	pal.ObsidianEdge = { Color = rgb(236, 84, 210), Material = NEON }
	EVO.Crown(ctx, { R = 4.8, Points = 7, Sink = 1.4 })
	-- obsidian shards jutting up from the wing arms, glowing edges
	ctx.WingAfter = function(w, w2)
		for _, sh in ipairs({ { -6, 6.6, 6.5, 100 }, { -13.4, 11.6, 8, 112 }, { -21, 15, 7, 124 } }) do
			local a = math.rad(sh[4])
			local tip = { sh[1] + math.cos(a) * sh[3], sh[2] + math.sin(a) * sh[3], 1.4 }
			cone(w, "Obsidian", { sh[1], sh[2], 1.4 }, tip, 1.7, 0)
			cone(w, "ObsidianEdge", { sh[1] - 0.5, sh[2] + 0.4, 0.4 }, { tip[1] - 0.2, tip[2] - 0.4, 0.6 }, 0.5, 0)
		end
	end
	EVO.Necklace(ctx, { R = 4.8, DY = -0.6, Tilt = 0.5, Double = true, Drops = 4 })
	ascPhoenixTail(ctx)
	ASC.Aura(ctx, "Shard", { R = 20 })
	pal.AuraDark = rgb(34, 26, 50)
end

ASC.Pets.sunbeam_bear = function(ctx)
	local pal = ctx.Pal
	-- white-gold wings (they stand out against the golden fur and the sun)
	pal.Wing = rgb(255, 238, 198)
	pal.WingTrim = rgb(248, 216, 152)
	pal.WingTip = rgb(255, 252, 240)
	pal.WingCov = rgb(255, 230, 176)
	pal.WingCov2 = rgb(255, 244, 216)
	ASC.SunMane(ctx)
	EVO.Crown(ctx, { R = 6, Points = 9 })
	ASC.ChestPlate(ctx)
	ASC.Pauldrons(ctx, { Gem = "GemB" })
	ASC.Greaves(ctx, { Gem = "GemB" })
	EVO.Necklace(ctx, { Pendant = false, Drops = 4 })
	ASC.Aura(ctx, "Sun")
end

-- the dragons' second evolution: a crown of horns, glowing spines, armour, a longer tail with a crystal blade
local function ascDragon(ctx, o)
	local g, pal = ctx.Body, ctx.Pal
	local c = ctx.HeadC
	o = o or {}
	pair(function(s)
		-- brow spikes
		cone(g, "Horn", { s * 5.6, c[2] + 6.4, c[3] - 6 }, { s * 7, c[2] + 9.6, c[3] - 4.6 }, 1, 0.2)
		-- glowing tips on the (bigger) horns
		ell(g, "Glow", { s * 6.4, ctx.HeadTop + 13.4, c[3] + 9.6 }, { 1.2, 1.5, 1.5 }, { Op = "Paint", OnlyKeys = { Horn = true, HornRing = true } })
	end)
	-- a nose horn
	cone(g, "Horn", { 0, c[2] - 0.6, c[3] - 11.4 }, { 0, c[2] + 2.8, c[3] - 12.8 }, 1.3, 0.2)
	-- glowing spine tips
	for i = 0, 6 do
		local zz = -6 + i * 3.8
		local y = ctx.EvoBelly + 8 - math.abs(i - 1.5) * 0.5
		ell(g, "Glow", { 0, y + 3 - i * 0.25, zz + 1.4 }, { 0.9, 1.1, 0.9 }, { Op = "Paint", OnlyKeys = "Spine" })
	end
	ASC.ChestPlate(ctx, { Gem = o.Gem })
	ASC.Pauldrons(ctx, { Spikes = true, Gem = o.Gem })
	ASC.Greaves(ctx, { Gem = o.Gem })
	-- a longer tail with spikes and a glowing crystal blade
	local t = newTail(ctx, ctx.TailHinge, 0.25)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, -2, 7 }, { 3.4, -7, 14 }, { 10, -10.4, 18 }, { 18, -11.4, 18 } }, 4, 1.3, { Smooth = true })
	for _, p in ipairs({ { 0, 3, 4 }, { 1, 1, 9.6 }, { 4.6, -3.4, 14.6 }, { 10, -6.8, 18.6 }, { 15, -8.4, 19 } }) do
		cone(t, "Spine", p, { p[1], p[2] + 2.8, p[3] + 1 }, 1.25, 0.2)
	end
	cone(t, "Glow", { 17.6, -11.4, 18 }, { 24.6, -12, 17 }, 2.6, 0.2)
	cone(t, "GlowB", { 18.4, -11.4, 18 }, { 21, -8, 17.6 }, 1.2, 0.1)
	cone(t, "GlowB", { 18.4, -11.4, 18 }, { 21, -14.8, 17.6 }, 1.2, 0.1)
end

ASC.Pets.twilight_dragon = function(ctx)
	ascDragon(ctx)
	EVO.Necklace(ctx, { Pendant = false, Drops = 4 })
	ASC.Aura(ctx, "Orb")
	ctx.Pal.AuraDark = rgb(70, 46, 130)
end

ASC.Pets.eclipse_dragon = function(ctx)
	ascDragon(ctx, { Gem = "GemB" })
	ASC.Eclipse(ctx)
	EVO.Necklace(ctx, { Pendant = false, Drops = 4 })
	ASC.Aura(ctx, "Orb")
	ctx.Pal.AuraDark = rgb(30, 22, 52)
end

ASC.Pets.cloudy_dragon = function(ctx)
	local g, pal = ctx.Body, ctx.Pal
	local c = ctx.HeadC
	-- a ruff of clouds round the neck and puffs along the back
	local y, z, r = ctx.NeckY, ctx.NeckZ, ctx.NeckR
	for i = 0, 9 do
		local a = i / 10 * TAU
		ell(g, "Cloud", { math.cos(a) * (r[1] + 1.4), y - 1 + math.sin(a * 2) * 0.6, z + math.sin(a) * (r[2] + 1.4) }, { 3, 2.6, 3 })
	end
	for i = 0, 3 do
		ell(g, "Cloud", { 0, ctx.EvoBelly + 7.4 - i * 0.3, -1 + i * 4.4 }, { 3.4 - i * 0.3, 2.4, 2.8 })
	end
	pair(function(s)
		ell(g, "Cloud", { s * 10, c[2] - 2, c[3] + 1 }, { 2.8, 2.6, 2.8 })
		-- lightning-blue horn tips
		ell(g, "Glow", { s * 6.4, ctx.HeadTop + 13.4, c[3] + 9.6 }, { 1.2, 1.5, 1.5 }, { Op = "Paint", OnlyKeys = { Horn = true, HornRing = true } })
	end)
	ASC.PointHalo(ctx, { R = 5.2, Points = 6, Bolts = true, Lift = 12 })
	ASC.ChestPlate(ctx)
	ASC.Pauldrons(ctx)
	ASC.Greaves(ctx)
	EVO.Necklace(ctx, { Pendant = false, Drops = 4 })
	-- the tail ends in a cloud
	local t = newTail(ctx, ctx.TailHinge, 0.25)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, -2, 7 }, { 3.4, -7, 14 }, { 10, -10.4, 18 }, { 16, -11, 17.4 } }, 4, 1.4, { Smooth = true })
	ell(t, "Cloud", { 17, -11, 17.4 }, { 3.6, 3, 3.4 })
	ell(t, "Cloud", { 19.4, -9.6, 17 }, { 2.8, 2.6, 2.8 })
	ell(t, "Cloud", { 18.6, -12.6, 18.6 }, { 2.6, 2.2, 2.6 })
	ASC.Aura(ctx, "Cloud")
	pal.AuraC = rgb(250, 252, 255)
end

ASC.Pets.starlight_unicorn = function(ctx)
	local g, pal = ctx.Body, ctx.Pal
	local c = ctx.HeadC
	-- a long glowing crystal horn
	cone(g, "Glow", { 0, c[2] + 6.8, c[3] - 3.4 }, { 0, c[2] + 24, c[3] - 7.8 }, 2.8, 0.3)
	-- a starry night mane and forelock
	pal.Mane = rgb(98, 82, 196)
	pal.Mane2 = rgb(150, 126, 236)
	pal.Mane3 = rgb(70, 66, 160)
	local keys = { "Mane", "Mane2", "Mane3" }
	for i = 0, 9 do
		local t = i / 9
		ell(g, keys[i % 3 + 1], { 1.2 * ((i % 2 == 0) and 1 or -1) - 1, c[2] + 7 - t * 17, c[3] + 6.6 + t * 6 }, { 3.6, 4, 3.6 })
	end
	ell(g, "Mane2", { 2.4, c[2] + 6.8, c[3] - 5.4 }, { 3, 2.4, 2.4 })
	ASC.Sprinkle(g, "Star", { Mane = true, Mane2 = true, Mane3 = true }, 0.06, 19)
	ASC.PointHalo(ctx, { R = 6.6, Points = 6, Lift = 12 })
	ASC.ChestPlate(ctx)
	ASC.Greaves(ctx, { Gem = "Gem" })
	EVO.Necklace(ctx, { Pendant = false, Drops = 4 })
	-- a long starry tail
	local t = newTail(ctx, ctx.TailHinge, 0.3)
	for i = -2, 2 do
		curve(t, keys[(i + 2) % 3 + 1], { { i * 1, 0, 0 }, { i * 1.5, 1.4, 5 }, { i * 2.2, -3.4, 11 }, { i * 2.8, -10.4, 14 }, { i * 3.2, -16, 13 } }, 2.4, 1.1, { Smooth = true })
	end
	ASC.Sprinkle(t, "Star", { Mane = true, Mane2 = true, Mane3 = true }, 0.07, 23)
	ctx.WingAfter = function(w, w2)
		ASC.Sprinkle(w, "Star", { Wing = true, WingTrim = true }, 0.016, 29)
	end
	ASC.Aura(ctx, "Star")
end

ASC.Pets.stormfang = function(ctx)
	local g, pal = ctx.Body, ctx.Pal
	local c = ctx.HeadC
	-- a tall armoured crest from the brow back over the head, glowing edge; lightning horns
	for i = 0, 4 do
		local zz = c[3] - 6 + i * 3.4
		local hgt = 4.4 + math.sin(i / 4 * math.pi) * 3
		cone(g, "Plate", { 0, ctx.HeadTop - 2, zz }, { 0, ctx.HeadTop + hgt, zz + 2.6 }, 1.8, 0.2)
		ell(g, "Neon", { 0, ctx.HeadTop + hgt - 0.8, zz + 2.2 }, { 0.8, 1, 0.8 }, { Op = "Paint", OnlyKeys = "Plate" })
	end
	pair(function(s)
		cap(g, "Neon", { s * 6, ctx.HeadTop - 1, c[3] + 1 }, { s * 8.6, ctx.HeadTop + 3.6, c[3] + 2 }, 0.8, 0.7)
		cap(g, "Neon", { s * 8.6, ctx.HeadTop + 3.6, c[3] + 2 }, { s * 7.6, ctx.HeadTop + 5, c[3] + 2.6 }, 0.7, 0.7)
		cap(g, "Neon", { s * 7.6, ctx.HeadTop + 5, c[3] + 2.6 }, { s * 10.4, ctx.HeadTop + 9.6, c[3] + 3.6 }, 0.7, 0.2)
	end)
	-- lightning seams along the flanks
	local by = ctx.EvoBelly
	pair(function(s)
		paint(g, "Neon", { Kind = "Box", Center = { s * 9, by + 1, 2 }, Size = { 6, 10, 26 }, Pattern = function(x, y, zz)
			local u = (zz + 20) / 3.2
			local zig = (u % 2 < 1) and (u % 1) or (1 - u % 1)
			if math.abs(y - (by + 1.6 + zig * 3.2)) < 0.55 then
				return "Neon"
			end
			return false
		end }, "Fur")
	end)
	ASC.Pauldrons(ctx, { Spikes = true, Gem = "Gem" })
	ASC.Greaves(ctx, { Gem = "Gem" })
	EVO.Necklace(ctx, { Gem = "Gem", Drops = 0, Size = 1.1 })
	-- the tail ends in a glowing blade
	local t = newTail(ctx, ctx.TailHinge, 0.3)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, 3, 5 }, { 0, 8, 9 }, { 0, 13, 13 } }, 3, 2.4, { Smooth = true })
	ell(t, "Plate", { 0, 13.4, 13.4 }, { 3, 3, 3 })
	cone(t, "Neon", { 0, 14, 14 }, { 0, 21, 17 }, 2.2, 0.2)
	box(t, "Neon", { 0, 9, 10 }, { 1.2, 1.2, 4 })
	ASC.Aura(ctx, "Bolt")
end

ASC.Pets.phantom_kitsune = function(ctx)
	local g, pal = ctx.Body, ctx.Pal
	local c = ctx.HeadC
	-- nine ghostly tails fanning up behind, glowing tips
	local t = newTail(ctx, ctx.TailHinge, 0.22)
	pal.Tail = rgb(54, 60, 102)
	pal.Tail2 = rgb(74, 80, 132)
	pal.TailTip = { Color = rgb(150, 255, 226), Material = NEON }
	for i = -4, 4 do
		local a = i * 0.36
		local sx, sy = math.sin(a), math.cos(a)
		local L = 1.3 - math.abs(i) * 0.05
		local curl = (i == 0) and 0 or ((i > 0) and 1 or -1) * 2.4
		local tip = { sx * 18 * L + curl, sy * 20 * L, 13 + math.abs(i) * 0.4 }
		shape(t, { Kind = "Curve", Key = (i % 2 == 0) and "Tail" or "Tail2", Smooth = true, Points = { { 0, 0, 0 }, { sx * 6 * L, sy * 5.5 * L, 6 }, { sx * 13 * L, sy * 13.5 * L, 11 }, tip }, Radii = { 1.5, 2.1, 2.6, 1.4 } })
		ell(t, "TailTip", tip, { 2.4, 3, 2.4 }, { Op = "Paint", OnlyKeys = { Tail = true, Tail2 = true } })
	end
	-- spirit marks: glowing stripes on the legs and a flame mark on the brow
	local L = ctx.Legs
	pair(function(s)
		for _, p in ipairs({ L.Front, L.Hind }) do
			for k = 0, 1 do
				box(g, "Glow", { s * p[1], EVO.Ground + 6.4 + k * 2.6, p[2] - 2.6 }, { 7, 0.8, 3 }, { Op = "Paint", OnlyKeys = { Fur = true, Belly = true } })
			end
		end
	end)
	ell(g, "Glow", { 0, ctx.HeadTop - 2.2, c[3] - 6.4 }, { 0.9, 1.8, 1 }, { Op = "Paint", OnlyKeys = "Fur" })
	ell(g, "GlowB", { 0, ctx.HeadTop - 4.4, c[3] - 7.4 }, { 1.2, 1.1, 1 })
	ASC.PointHalo(ctx, { R = 5.6, Points = 5, Lift = 7 })
	ctx.WingOpts = { Size = 0.86 }
	ctx.NoWing2 = true
	ctx.Pal.HaloGlow = { Color = rgb(150, 255, 226), Material = NEON }
	EVO.Necklace(ctx, { Drops = 4 })
	ASC.Greaves(ctx, { Gem = "GemB" })
	ASC.Aura(ctx, "Wisp")
end

----------------------------------------------------------------------
-- Secret aura: a ring of floating glowing voxels (orbits)
----------------------------------------------------------------------
local function auraGrid(ctx)
	local a = Voxel.NewGrid(30)
	local count = ctx.High and 10 or 6
	local keys = { "AuraA", "AuraB", "AuraC" }
	for i = 0, count - 1 do
		local ang = i / count * TAU
		local r = 13.4 + (i % 2) * 1.6
		local y = -4 + (i * 7 % 13)
		local size = ctx.High and ((i % 3 == 0) and 1.6 or 1.1) or 2
		box(a, keys[i % 3 + 1], { math.cos(ang) * r, y, math.sin(ang) * r }, { size, size, size })
	end
	local P, S, E = ctx.Look.Primary, ctx.Look.Secondary, ctx.Look.Eye
	ctx.Pal.AuraA = { Color = hueShift(S, 0), Material = NEON }
	ctx.Pal.AuraB = { Color = hueShift(S, 0.12), Material = NEON }
	ctx.Pal.AuraC = { Color = hueShift(mix(E, P, 0.3), -0.1), Material = NEON }
	return a
end

----------------------------------------------------------------------
-- Blueprint: sculpt -> shade -> merge (cached per look + detail)
----------------------------------------------------------------------
local blueprints = {}
local lidBoxes -- defined below

local function mergeGroup(ctx, grid, budget)
	return Voxel.Merge(grid, { Palette = ctx.Pal, MaxParts = budget, Keep = ctx.Keep })
end

-- lean: nil, 1 (drop the optional small details) or 2 (also sculpt a little coarser)
local function buildBlueprint(look, detail, lean)
	local k = (detail == "Low") and LOW_K or 1
	if lean and detail == "Low" then
		k = LEAN_LOW_K
	elseif lean == 2 then
		k = LEAN_HIGH_K
	end
	if look.Evolved then
		k = ((detail == "Low") and 0.65 or 1.25) * (lean and 0.85 or 1)
	end
	SK = k
	local ok, result = pcall(function()
		local ctx = newContext(look, detail)
		if lean then
			ctx.Fine = false
		end
		local budget = budgetOf(look, detail)
		if look.Evolved then
			EVO.Sculpt(ctx)
			if look.Accessory and not EVO.Pets[look.Id] then
				ACCESSORIES[look.Accessory](ctx)
			end
		else
			SPECIES[look.Species](ctx)
			if look.Accessory then
				ACCESSORIES[look.Accessory](ctx)
			end
		end
		carveEyes(ctx)
		-- (a species may tune its body and tail shading with ctx.BodyShade = Voxel.Shade options)
		local bodyShade = { Skip = ctx.NoShade }
		for k, v in pairs(ctx.BodyShade or {}) do
			bodyShade[k] = v
		end
		Voxel.Shade(ctx.Body, bodyShade)
		if look.Evolved then
			EVO.SculptWing(ctx, ctx.Wing)
		else
			WINGS[look.WingStyle](ctx, ctx.Wing)
		end
		if not ctx.WingNoShade then
			Voxel.Shade(ctx.Wing, { Skip = ctx.NoShade, LightAt = 0.5, Smooth = look.Evolved and 2 or nil })
			if ctx.Wing2 then
				Voxel.Shade(ctx.Wing2, { Skip = ctx.NoShade, LightAt = 0.5, Smooth = 2 })
			end
		end

		local bp = { Groups = {}, Pal = ctx.Pal, Look = look, Detail = detail, K = k, Pulse = ctx.Pulse, Grow = ctx.Grow }
		local bodyGroup = { Name = "Body" }
		bp.Groups[#bp.Groups + 1] = bodyGroup

		-- wings: left from the grid, right = exact mirror image
		local wh = ctx.WingHinge
		local hingeR = CFrame.new(wh[1], wh[2], wh[3]) * CFrame.Angles(0, -ctx.WingSweep, 0) * CFrame.Angles(0, 0, ctx.WingTilt)
		local hingeL = mirrorCF(hingeR)
		local wingBoxes = mergeGroup(ctx, ctx.Wing, budget.Wing)
		local wingKind = ctx.WingKind or "wing"
		bp.Groups[#bp.Groups + 1] = { Name = "WingL", Boxes = wingBoxes, Hinge = hingeL, Kind = wingKind, Side = 1, K = ctx.Wing.K }
		bp.Groups[#bp.Groups + 1] = { Name = "WingR", Boxes = Voxel.MirrorBoxes(wingBoxes), Hinge = hingeR, Kind = wingKind, Side = -1, K = ctx.Wing.K }
		-- a second, lower pair of wings (second evolution), flapping with the first
		if ctx.Wing2 then
			local w2 = ctx.Wing2Hinge
			local h2R = CFrame.new(w2[1], w2[2], w2[3]) * CFrame.Angles(0, -ctx.Wing2Sweep, 0) * CFrame.Angles(0, 0, ctx.Wing2Tilt)
			local w2Boxes = mergeGroup(ctx, ctx.Wing2, budget.Wing2)
			bp.Groups[#bp.Groups + 1] = { Name = "Wing2L", Boxes = w2Boxes, Hinge = mirrorCF(h2R), Kind = "wing", Side = 1, K = ctx.Wing2.K }
			bp.Groups[#bp.Groups + 1] = { Name = "Wing2R", Boxes = Voxel.MirrorBoxes(w2Boxes), Hinge = h2R, Kind = "wing", Side = -1, K = ctx.Wing2.K }
		end

		if ctx.Tail then
			Voxel.Shade(ctx.Tail, bodyShade)
			local th = ctx.TailHinge
			bp.Groups[#bp.Groups + 1] = {
				Name = "Tail", Boxes = mergeGroup(ctx, ctx.Tail, budget.Tail),
				Hinge = CFrame.new(th[1], th[2], th[3]), Kind = "tail", Amp = ctx.TailWag, K = ctx.Tail.K,
			}
		end
		if ctx.Halo then
			local ha = ctx.HaloAt
			bp.Groups[#bp.Groups + 1] = {
				Name = "Halo", Boxes = mergeGroup(ctx, ctx.Halo, budget.Halo),
				Hinge = CFrame.new(ha[1], ha[2], ha[3]), Kind = "bob", Amp = 0.6,
			}
		end
		if ctx.AuraGrid then
			-- the second evolution's elemental aura
			local at = ctx.AuraAt or { 0, 1, 0 }
			bp.Groups[#bp.Groups + 1] = {
				Name = "Aura", Boxes = Voxel.Merge(ctx.AuraGrid, { Palette = ctx.Pal, MaxParts = budget.Aura }),
				Hinge = CFrame.new(at[1], at[2], at[3]), Kind = "orbit", Amp = 0.8,
			}
		elseif look.Rarity == "Secret" and not ctx.NoAura then
			bp.Groups[#bp.Groups + 1] = {
				Name = "Aura", Boxes = Voxel.Merge(auraGrid(ctx), { Palette = ctx.Pal }),
				Hinge = CFrame.new(0, 1, 0), Kind = "orbit", Amp = 0.8,
			}
		end
		-- blink lids: per eye an upper lid, a dark lash line and a lower lid, flat boxes in front of the carved
		-- eye (hidden until a blink)
		for i, cells in ipairs(ctx.LidCells or {}) do
			bp.Groups[#bp.Groups + 1] = { Name = "EyeLid", Boxes = lidBoxes(cells, not ctx.High), Kind = "lid", Index = i }
		end
		-- the body gets whatever the other groups left of the total budget (it can always give up shading)
		local used = 1 -- the root
		for _, gr in ipairs(bp.Groups) do
			if gr.Boxes then
				used = used + #gr.Boxes
			end
		end
		-- (a species that sets ctx.BodyFill may fill the whole remaining total, so its shades and colours survive)
		bodyGroup.Boxes = mergeGroup(ctx, ctx.Body, max(30, min(ctx.BodyFill and budget.Total or budget.Body, budget.Total - used)))
		return bp
	end)
	SK = 1
	if not ok then
		error(result, 0)
	end
	return result
end

-- flat lid boxes covering one carved eye: rows above the lash line, the lash line, rows below it (Low detail:
-- one plain lid)
lidBoxes = function(cells, single)
	local x0, x1, y0, y1, z = math.huge, -math.huge, math.huge, -math.huge, math.huge
	local counts = {}
	local lineY = nil
	for _, c in ipairs(cells) do
		x0, x1 = min(x0, c[1]), max(x1, c[1])
		y0, y1 = min(y0, c[2]), max(y1, c[2])
		z = min(z, c[3])
		if c[4] == "LidLine" then
			lineY = c[2]
		else
			counts[c[4]] = (counts[c[4]] or 0) + 1
		end
	end
	if x0 > x1 then
		return {}
	end
	local key, best = "Lid", -1
	for k, n in pairs(counts) do
		if n > best or (n == best and k < key) then
			key, best = k, n
		end
	end
	lineY = lineY or floor((y0 + y1) / 2)
	if single then
		-- Low detail: one closed lid over the whole eye
		return { { X0 = x0, X1 = x1, Y0 = y0, Y1 = y1, Z0 = z, Z1 = z, Key = key } }
	end
	local out = {}
	if y1 > lineY then
		out[#out + 1] = { X0 = x0, X1 = x1, Y0 = lineY + 1, Y1 = y1, Z0 = z, Z1 = z, Key = key }
	end
	out[#out + 1] = { X0 = x0, X1 = x1, Y0 = lineY, Y1 = lineY, Z0 = z, Z1 = z, Key = "LidLine" }
	if y0 < lineY then
		out[#out + 1] = { X0 = x0, X1 = x1, Y0 = y0, Y1 = lineY - 1, Z0 = z, Z1 = z, Key = key }
	end
	return out
end

local function partCount(bp)
	local n = 1
	for _, gr in ipairs(bp.Groups) do
		n = n + #gr.Boxes
	end
	return n
end

local function getBlueprint(look, detail)
	local key = lookSignature(look) .. "|" .. detail
	local bp = blueprints[key]
	if not bp then
		bp = buildBlueprint(look, detail)
		-- a rare heavy combination (big wings + bushy tail + accessory + aura): sculpt again without the
		-- optional small details and keep whichever fits
		local cap = budgetOf(look, detail).Cap
		for level = 1, 2 do
			if partCount(bp) <= cap then
				break
			end
			local lean = buildBlueprint(look, detail, level)
			if partCount(lean) < partCount(bp) then
				bp = lean
			end
		end
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

-- base colours before their shades, bigger boxes first (the first part of a name gets the bare name)
local function sortBoxes(boxes)
	local list = {}
	local info = {}
	for i, b in ipairs(boxes) do
		list[i] = b
		local base, variant = Voxel.BaseKey(b.Key)
		info[b] = { Variant = variant ~= nil, Base = tostring(base), Vol = (b.X1 - b.X0 + 1) * (b.Y1 - b.Y0 + 1) * (b.Z1 - b.Z0 + 1) }
	end
	table.sort(list, function(a, b)
		local ia, ib = info[a], info[b]
		if ia.Variant ~= ib.Variant then
			return not ia.Variant
		end
		if ia.Vol ~= ib.Vol then
			return ia.Vol > ib.Vol
		end
		if ia.Base ~= ib.Base then
			return ia.Base < ib.Base
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
	scale = scale * (bp.Grow or 1) -- (the second evolution is built bigger)
	local model = Instance.new("Model")
	model.Name = "Pet_" .. bp.Look.Id
	local designStud = VOXEL * scale -- hinge positions are in design voxels
	local vs = VOXEL / bp.K * scale -- box coordinates are in sculpted voxels
	local used = {}
	local function uniqueName(name)
		local c = (used[name] or 0) + 1
		used[name] = c
		if c > 1 then
			return name .. c
		end
		return name
	end
	-- the invisible root at the pet's centre (sized so rarity sparkles rise from the whole body)
	local root = Instance.new("Part")
	root.Name = uniqueName("Body")
	flagPart(root)
	root.Transparency = 1
	root.Size = Vector3.new(0.9, 1.1, 0.9) * scale
	root.CFrame = CFrame.new()
	root.Parent = model
	model.PrimaryPart = root

	local specs = {}
	for _, gr in ipairs(bp.Groups) do
		local boxes = sortBoxes(gr.Boxes)
		local hinge = nil
		if gr.Hinge then
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = gr.Hinge:GetComponents()
			hinge = CFrame.new(x * designStud, y * designStud, z * designStud, r00, r01, r02, r10, r11, r12, r20, r21, r22)
		end
		local _, parts = Voxel.BuildBoxes(boxes, {
			VoxelSize = gr.K and (VOXEL / gr.K * scale) or vs, -- (a group may have its own resolution)
			Palette = bp.Pal,
			CFrame = hinge or CFrame.new(),
			Model = model,
			CastShadow = false,
		})
		local animated = gr.Kind ~= nil and gr.Kind ~= "static"
		for i, part in ipairs(parts) do
			local base = Voxel.BaseKey(boxes[i].Key)
			local name = base
			if gr.Name == "Tail" or gr.Name == "Halo" or gr.Name == "Aura" then
				name = gr.Name
			elseif gr.Name ~= "Body" then
				name = gr.Name
			end
			part.Name = uniqueName(name)
			flagPart(part)
			if bp.Pulse and bp.Pulse[base] then
				-- glowing parts that pulse softly (Animate)
				part:SetAttribute("PB_Pulse", part.Transparency)
			end
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
	model:SetAttribute("PB_Detail", bp.Detail)
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
	local pulse = {}
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			local p0 = part:GetAttribute("PB_Pulse")
			if type(p0) == "number" then
				pulse[#pulse + 1] = { Part = part, T0 = p0 }
			end
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
	local scale = model:GetAttribute("PB_Scale")
	if type(scale) ~= "number" or scale <= 0 then
		scale = 1
	end
	return {
		Groups = moving,
		Lids = lids,
		Pulse = pulse,
		Blinking = false,
		St = { Flap = 0, Wag = 0, Sway = 0, Excite = 0, Stud = VOXEL * scale },
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

-- motion of one group in its hinge frame
local function groupMotion(gr, st)
	local kind = gr.Kind
	if kind == "wing" then
		local a = FLAP_AMP * (1 + 0.15 * st.Excite) * sin(st.Flap)
		local sweep = 0.12 * sin(st.Flap - 1.2)
		return CFrame.Angles(0, sweep * gr.Side, a * gr.Side)
	elseif kind == "cloud" then
		-- a storm cloud half: a slow, gentle roll (~0.4 Hz, +-7 degrees) and a small drift that keeps the rider
		-- sitting in it (it rides the flap clock, so Flap / Excited speed it up)
		local a = 0.12 * sin(st.Flap * 0.2)
		return CFrame.new(0, st.Stud * 0.8 * sin(st.Flap * 0.15 + 1), 0) * CFrame.Angles(0.04 * sin(st.Flap * 0.12), 0, a * gr.Side)
	elseif kind == "tail" then
		local a = gr.Amp * (1 + 0.5 * st.Excite) * sin(st.Wag)
		return CFrame.Angles(0.06 * sin(st.Wag * 0.5), a, 0)
	elseif kind == "bob" then
		return CFrame.new(0, gr.Amp * st.Stud * sin(st.Sway * 1.6) * 3, 0)
	elseif kind == "orbit" then
		return CFrame.new(0, gr.Amp * st.Stud * sin(st.Sway * 1.3) * 3, 0) * CFrame.Angles(0, st.Sway * 0.7, 0)
	end
	return CFrame.new()
end

-- neon accents breathe softly (Stormfang)
local function updatePulse(rig, t)
	local list = rig.Pulse
	if #list == 0 then
		return
	end
	local k = 0.2 * (0.5 + 0.5 * sin(t * 2.2))
	for i = 1, #list do
		local e = list[i]
		e.Part.Transparency = e.T0 + k
	end
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
			if closed then
				l.Part.Transparency = l.T0
			else
				l.Part.Transparency = 1
			end
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

local function addSparkles(model, look, rate, scale)
	local root = model.PrimaryPart
	if not root then
		return
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "RaritySparkles"
	emitter.Texture = SPARKLE_TEXTURE
	local a, b = lighten(look.WingColor, 0.5), lighten(look.Primary, 0.35)
	if look.Rarity == "Secret" then
		a, b = hueShift(look.Secondary, 0), hueShift(look.Secondary, 0.15)
	end
	emitter.Color = ColorSequence.new(a, b)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Rate = rate
	emitter.Lifetime = NumberRange.new(0.8, 1.5)
	emitter.Speed = NumberRange.new(0.3 * scale, 1.1 * scale)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.4, 0.22 * scale),
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
	-- evolution stage: true / 1 = evolved, 2 = second evolution (Epic and up; others stop at their first)
	local stage = opts.Evolved
	if stage == nil and type(petDef) == "table" then
		stage = petDef.Evolved
	end
	stage = (stage == true) and 1 or tonumber(stage) or 0
	stage = min(floor(stage), ASCEND_RARITY[look.Rarity] and 2 or 1)
	look.Evolved = (stage == 2) and 2 or (stage == 1) or nil
	local bp, bpKey = getBlueprint(look, detail)
	local tpl = getTemplate(bp, bpKey, scale)
	local model = tpl:Clone()
	model.PrimaryPart = model:FindFirstChild("Body")
	if look.Rarity == "Legendary" or look.Rarity == "Mythic" or look.Rarity == "Secret" then
		addSparkles(model, look, (detail == "Low") and 3 or 5, scale)
	end
	return model
end

-- the glow colours of an evolution into `stage` (1: gold + the evolved form's gem, 2: the second evolution's
-- two neon accents), for the evolution animation (client/Controllers/EvolutionFx.lua)
function PetBuilder.EvolutionColors(petDef, stage)
	initConstants()
	local look = readLook(petDef)
	if stage == 2 then
		local st = ASC.Look[look.Id]
		if st and st.Glow and st.GlowB then
			return evoRGB(st.Glow), evoRGB(st.GlowB)
		end
		return lighten(look.Secondary, 0.3), lighten(look.WingColor, 0.4)
	end
	local st = EVO.Look[look.Id]
	return rgb(255, 214, 90), (st and st.Gem) and evoRGB(st.Gem) or lighten(look.Secondary, 0.2)
end

-- how far a pet can evolve (petDef or a rarity name): 2 (a second evolution) for Epic, Legendary, Mythic and
-- Secret pets, 1 for the rest
function PetBuilder.MaxEvolution(petDef)
	local rarity = petDef
	if type(petDef) == "table" then
		rarity = petDef.Rarity
	end
	return ASCEND_RARITY[rarity] and 2 or 1
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
	updatePulse(rig, t)
end

-- Height of the resting pose (studs, Scale 1), measured once per look from the High build.
local heightCache = {}
local DEFAULT_HEIGHT = 2.8

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
