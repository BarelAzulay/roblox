-- PetBuilder: every winged pet of Nimbus Climb, sculpted in the detailed fine-voxel style (ARCHITECTURE_V3.md,
-- "ART DIRECTION") with the shared voxel kit (shared/Voxel.lua). Parts only, no meshes, decals or asset ids.
-- Usable on the server, on the client and inside ViewportFrames. Plain Lua 5.1-compatible syntax only.
--
-- API (ARCHITECTURE_V2.md section 2 + ARCHITECTURE_V3.md)
--   PetBuilder.Build(petDef, opts) -> Model   opts: { Scale = 1, Detail = "High" (default) | "Low" }
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
}

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

local function scaleValue(v)
	if type(v) == "number" then
		return v * SK
	elseif type(v) == "table" then
		return { (v[1] or 0) * SK, (v[2] or 0) * SK, (v[3] or 0) * SK }
	end
	return v
end

local POINT_FIELDS = { Center = true, A = true, B = true, Pivot = true, Radius = true, RadiusB = true, Size = true, Round = true, Thickness = true, ThicknessB = true }

-- copy of a shape table scaled to the current resolution (patterns still receive design coordinates)
local function scaled(t)
	local o = {}
	for k, v in pairs(t) do
		if POINT_FIELDS[k] then
			o[k] = scaleValue(v)
		elseif k == "Points" then
			local pts = {}
			for i, p in ipairs(v) do
				pts[i] = scaleValue(p)
			end
			o[k] = pts
		elseif k == "Radii" then
			local r = {}
			for i, x in ipairs(v) do
				r[i] = x * SK
			end
			o[k] = r
		elseif k == "Pattern" and type(v) == "function" and SK ~= 1 then
			local fn, k2 = v, SK
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
	return Voxel.Shape(g, scaled(t))
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
		hex(look.Secondary), hex(look.Eye), hex(look.WingColor), tostring(look.Glow),
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
		"L L L . . .",
		"R I I L L .",
		"R I S I I L",
		". R I G I I",
		". . R R R .",
	},
	FierceLow = {
		"L L .",
		"I S L",
		". I I",
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
	ctx.Tail = t
	ctx.TailHinge = hinge
	ctx.TailWag = wag or 0.3
	return t
end

----------------------------------------------------------------------
-- Species
----------------------------------------------------------------------
SPECIES.Cat = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	head(ctx, "Fur", { 0, 6.5, -0.5 }, { 8.6, 7, 7.2 })
	pair(function(s)
		ell(g, "Fur", { s * 5.4, 3.5, -2.8 }, { 3.8, 3, 3.6 }) -- cheeks
		triEar(ctx, s, { 5, 10.5, -0.5 }, { 6.6, 17.5, 0 }, 3.2)
	end)
	-- whisker pads + chin
	pair(function(s)
		ell(g, "Muzzle", { s * 1.4, 2.6, -6.7 }, { 2, 1.6, 1.3 })
	end)
	sitBody(ctx, { PawKey = "Belly" })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.6, -4.2 }, Radius = { 3.6, 4.6, 2.6 } }, "Fur")
	-- tabby markings: forehead "M", cheek lines, back stripes
	if H then
		pair(function(s)
			box(g, "Stripe", { s * 1.5, 12.2, -4 }, { 1, 2.6, 7 }, { Op = "Paint", OnlyKeys = "Fur" })
			for i = 0, 1 do
				cap(g, "Stripe", { s * 8.8, 6.5 - i * 2, -2 }, { s * 6.8, 6.2 - i * 2, -5 }, 0.55, 0.55, { Op = "Paint", OnlyKeys = "Fur" })
			end
			for i = 0, 2 do
				cap(g, "Stripe", { s * 5.6, -2.4 - i * 2.6, 2.5 }, { s * 2.5, -1 - i * 2.6, 6.4 }, 0.6, 0.6, { Op = "Paint", OnlyKeys = "Fur" })
			end
		end)
		box(g, "Stripe", { 0, 12.8, -3.5 }, { 1, 2, 7 }, { Op = "Paint", OnlyKeys = "Fur" })
	end
	addEyes(ctx, 5, 8.5, "Round")
	face(ctx, "Nose", H and { { 0, 4 }, { -1, 4 }, { 1, 4 }, { 0, 3 } } or { { 0, 3.6 } })
	if H then
		face(ctx, "Mouth", { { 0, 2 }, { 1, 1 }, { -1, 1 }, { 2, 2 }, { -2, 2 } })
	end
	blush(ctx, 5, 3.4, 3)
	-- long tail curling up, with rings
	local t = newTail(ctx, { 0, -8.5, 6.2 }, 0.32)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, 0.8, 4 }, { 0.6, 4.5, 7 }, { 0.6, 9.5, 7.6 }, { 0, 12.5, 5.6 } }, 1.55, 1.15)
	if H then
		for i = 1, 3 do
			box(t, "Stripe", { 0, 1.6 + i * 3.1, 7 }, { 7, 1, 7 }, { Op = "Paint", OnlyKeys = "Fur" })
		end
	end
	ctx.EarX = 6.2
	ctx.HeadTop = 13.2
	ctx.FlowerAt = { 4, 13, -2.5 }
end

SPECIES.Dog = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	head(ctx, "Fur", { 0, 6.6, -0.4 }, { 8, 7.2, 7.2 })
	pair(function(s)
		ell(g, "Fur", { s * 4.8, 3.8, -2.6 }, { 3.6, 2.8, 3.4 })
	end)
	-- snout: a rounded muzzle with a big glossy dark nose, a light blaze up the forehead
	ell(g, "Muzzle", { 0, 3, -6.4 }, { 3.4, 2.6, 3 })
	paint(g, "Muzzle", { Kind = "Ellipsoid", Center = { 0, 8, -6.8 }, Radius = { 1.1, 3.6, 2 } }, "Fur")
	ell(g, "Nose", { 0, 4.3, -9.1 }, { 1.7, 1.1, 0.9 })
	if H then
		shine(ctx, -1, 4.8)
		face(ctx, "Mouth", { { 0, 2.8 }, { 0, 2 }, { 1, 1.6 }, { -1, 1.6 }, { 2, 2 }, { -2, 2 } })
		-- the tip of a pink tongue
		bump(ctx, 0, 1.2, "Tongue")
		bump(ctx, 1, 1.2, "Tongue")
	end
	-- soft floppy ears hanging close to the head, a shade darker
	pair(function(s)
		ell(g, "Ear", { s * 7.6, 7.4, 0 }, { 1.7, 4.6, 2.8 }, { Rotation = CFrame.Angles(0, 0, s * 0.28) })
		ell(g, "Ear", { s * 8.6, 3.6, -0.2 }, { 1.6, 1.8, 2.4 })
	end)
	-- a darker patch around the right eye
	if H then
		paint(g, "Ear", { Kind = "Ellipsoid", Center = { 3.8, 7.4, -6 }, Radius = { 2.8, 3, 3 } }, "Fur")
	end
	sitBody(ctx, { PawKey = "Belly" })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.4, -4.4 }, Radius = { 3.8, 4.8, 2.6 } }, "Fur")
	addEyes(ctx, 5, 9.2, "Round")
	blush(ctx, 5.4, 4, 3)
	-- a happy tail curled up over the back
	local t = newTail(ctx, { 0, -7.5, 6.2 }, 0.5)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, 2.6, 2.4 }, { 0, 5.4, 2.6 }, { 0, 6.8, 0.6 } }, 1.7, 1.1)
	ell(t, "Belly", { 0, 6.9, 0.4 }, { 1.3, 1.3, 1.3 })
	ctx.Pal.Ear = darken(ctx.Pal.Fur, 0.22)
	ctx.Pal.Nose = rgb(54, 40, 42)
	ctx.Pal.Muzzle = mix(ctx.Look.Secondary, rgb(255, 250, 242), 0.4)
	ctx.EarX = 7.5
	ctx.HeadTop = 13.6
	ctx.FlowerAt = { 4.6, 12.6, -3 }
end

SPECIES.Fox = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	head(ctx, "Fur", { 0, 6.6, -0.4 }, { 8.4, 6.8, 7 })
	-- white cheek ruffs sweeping out to the sides
	pair(function(s)
		cone(g, "Belly", { s * 4.5, 3.4, -3.2 }, { s * 9.8, 2.4, -1.4 }, 3.2, 0.6)
		ell(g, "Belly", { s * 4.2, 3, -3.6 }, { 3.6, 2.8, 3.2 })
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
	sitBody(ctx, { LegKey = "Patch", PawKey = "Patch", ToeKey = "Fur" })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3, -4.4 }, Radius = { 3.6, 5, 2.8 } }, "Fur")
	addEyes(ctx, 5, 8.6, "Round")
	if H then
		face(ctx, "Mouth", { { 0, 2.2 }, { 1, 1.6 }, { -1, 1.6 } })
		-- eyebrow flecks
		face(ctx, "Belly", { { 3.5, 10.2 }, { 4.5, 10.2 }, { -3.5, 10.2 }, { -4.5, 10.2 } })
	end
	blush(ctx, 5.4, 4.6, 2)
	-- huge bushy tail with a white tip
	local t = newTail(ctx, { 0, -8.2, 5.8 }, 0.28)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, 1.6, 4 }, { 0, 5.4, 7.2 }, { 0, 10, 7.6 }, { 0, 13, 5.2 } }, 1.8, 3.2, { Radii = { 1.8, 3, 3.6, 3.4, 2 } })
	ell(t, "Belly", { 0, 12.6, 5.4 }, { 2.6, 2.4, 2.6 })
	paint(t, "Belly", { Kind = "Ellipsoid", Center = { 0, 13.4, 5 }, Radius = { 3.4, 2.4, 3.4 } }, "Fur")
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
	sitBody(ctx, { BodyC = { 0, -4.8, 1.6 }, BodyR = { 5.8, 5.8, 5.8 }, PawKey = "Belly", HindX = 4.6 })
	pair(function(s)
		-- big hind feet
		ell(g, "Belly", { s * 4.5, -10.6, -0.6 }, { 1.9, 1.1, 3 })
	end)
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.6, -4.6 }, Radius = { 3.8, 4.6, 2.6 } }, "Fur")
	addEyes(ctx, 5, 8.6, "Round")
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
	head(ctx, "Fur", { 0, 6.4, -0.4 }, { 8.6, 7.2, 7.2 })
	pair(function(s)
		ell(g, "Fur", { s * 5, 3.4, -2.6 }, { 3.8, 3, 3.6 })
		roundEar(ctx, s, { 6.2, 11.6, 0.2 }, 2.9, earKey, earInner)
	end)
	-- round muzzle with a big nose
	ell(g, "Muzzle", { 0, 2.8, -6.4 }, { 3.6, 2.7, 2.4 })
	ell(g, "Nose", { 0, 4, -8.6 }, { 1.7, 1.1, 0.9 })
	if H then
		shine(ctx, -1, 4.4)
		face(ctx, "Mouth", { { 0, 2.6 }, { 0, 1.8 }, { 1, 1.3 }, { -1, 1.3 } })
	end
end

SPECIES.Bear = function(ctx)
	local g = ctx.Body
	bearHead(ctx, "Fur", "Muzzle")
	sitBody(ctx, { BodyR = { 6, 6, 6 }, PawKey = "Muzzle" })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.8, -4.8 }, Radius = { 4, 4.8, 2.8 } }, "Fur")
	addEyes(ctx, 5.4, 9, "Small")
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
	addEyes(ctx, 5.2, 8.6, "Small")
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
	local nY = vx(4.2)
	pair(function(s)
		local X = vx(s * 1.6)
		local z = frontZ(g, X, nY)
		if z then
			set(g, X, nY, z, "Nostril")
		end
	end)
	openMouth(ctx, 2.6)
	-- the crown of the head: a cloud tuft (cloud dragons) or a little crest of spikes
	if cloudy then
		ell(g, "Cloud", { 0, 14, 0.4 }, { 2.4, 1.9, 2.2 })
		ell(g, "Cloud", { 1.9, 13.4, 0.8 }, { 1.7, 1.5, 1.7 })
		ell(g, "Cloud", { -1.9, 13.4, 0.8 }, { 1.7, 1.5, 1.7 })
		ell(g, "Cloud", { 0, 13.2, 2.4 }, { 1.8, 1.5, 1.8 })
	else
		for i = 0, 2 do
			cone(g, "Accent", { 0, 13.2 - i * 1.3, 0.4 + i * 2.2 }, { 0, 15.8 - i * 1.6, 2 + i * 2.4 }, 1.4, 0.2)
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
			box(g, "BellyLine", { 0, -7 + i * 2.4, -6 }, { 9, 0.6, 6 }, { Op = "Paint", OnlyKeys = "Belly" })
		end
		-- little back spikes / cloud tufts between the wings
		for i = 0, 1 do
			if cloudy then
				ell(g, "Cloud", { 0, 0.6 - i * 3.4, 6.8 + i * 0.4 }, { 1.6, 1.5, 1.6 })
			else
				cone(g, "Accent", { 0, 0.4 - i * 3.4, 6.2 }, { 0, 1.8 - i * 3.4, 8.6 }, 1.3, 0.2)
			end
		end
	end
	addEyes(ctx, 6, 9.8, "Big")
	blush(ctx, 5.6, 4.4, 3)
	-- thick tail sweeping round to the side, ending in a big cloud puff (cloud dragons) or a spade
	local t = newTail(ctx, { 0, -8.6, 5.6 }, 0.3)
	curve(t, "Scale", { { 0, 0, 0 }, { 0.6, -0.4, 4.4 }, { 3, 1.4, 8 }, { 6.6, 4, 8.8 } }, 1.8, 1)
	if cloudy then
		ell(t, "Cloud", { 7.8, 5.4, 9 }, { 2.7, 2.4, 2.4 })
		ell(t, "Cloud", { 9.8, 4.4, 9 }, { 1.8, 1.7, 1.8 })
	else
		cone(t, "Accent", { 6.2, 3.6, 8.8 }, { 9.6, 6.4, 9.4 }, 2.3, 0.2)
	end
	if cloudy then
		ctx.Pal.Fur = mix(look.Primary, look.Secondary, 0.2)
		ctx.Pal.Scale = mix(look.Primary, look.Secondary, 0.72)
	else
		ctx.Pal.Scale = mix(look.Primary, look.Secondary, 0.18)
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

SPECIES.Owl = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- one round body-head with a heart-shaped facial disc
	head(ctx, "Fur", { 0, 3, 0 }, { 8.6, 10, 7.6 })
	ell(g, "Fur", { 0, -4.6, 0.8 }, { 7.4, 6, 6.8 })
	pair(function(s)
		ell(g, "Accent", { s * 3.6, 5.6, -5.2 }, { 4.2, 4.4, 2.6 }, { Op = "Paint", OnlyKeys = "Fur" })
		-- ear tufts
		cone(g, "Fur", { s * 5, 10.6, -0.4 }, { s * 7.4, 15.6, 0.8 }, 2.4, 0.5)
		if H then
			paint(g, "Stripe", { Kind = "Capsule", A = { s * 6.6, 13.6, -1 }, B = { s * 7.2, 15.2, 0.2 }, Radius = 0.7 }, "Fur")
		end
	end)
	-- beak
	cone(g, "Beak", { 0, 4.6, -6.6 }, { 0, 2, -8.8 }, 1.4, 0.3)
	-- chest with chevrons
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.6, -4.4 }, Radius = { 5.2, 5.6, 3.6 } }, "Fur")
	if H then
		for i = 0, 2 do
			for _, s in ipairs({ -1, 1 }) do
				local y = -1.2 - i * 2.6
				dot(ctx, s * 2, y, "Stripe", { Belly = true })
				dot(ctx, s * 1, y - 0.8, "Stripe", { Belly = true })
				dot(ctx, 0, y - 1.2, "Stripe", { Belly = true })
			end
		end
	end
	-- feet with talons
	pair(function(s)
		ell(g, "Feet", { s * 3, -10.6, -2.4 }, { 1.6, 1, 2 })
		if H then
			cap(g, "Feet", { s * 3, -10.8, -3 }, { s * 3.6, -11.2, -4.6 }, 0.55, 0.45)
			cap(g, "Feet", { s * 3, -10.8, -3 }, { s * 2.4, -11.2, -4.6 }, 0.55, 0.45)
		end
	end)
	addEyes(ctx, 6, 7.8, "Owl")
	blush(ctx, 6.2, 2.2, 2)
	-- tail feathers fan
	local t = newTail(ctx, { 0, -7.6, 6.6 }, 0.16)
	for i = -1, 1 do
		cap(t, (i == 0) and "Fur" or "Stripe", { 0, 0, 0 }, { i * 2, -1.6, 4.4 }, 1.4, 1.1)
	end
	ctx.Pal.Belly = lighten(ctx.Look.Secondary, 0.2)
	ctx.Pal.EyeRing = mix(rgb(255, 200, 84), ctx.Look.Eye, 0.2)
	if ctx.Look.Glow then
		ctx.Pal.EyeRing = { Color = mix(rgb(255, 214, 120), ctx.Look.Eye, 0.4), Material = NEON }
	end
	ctx.WingHinge = { 6.4, -1.4, 2.6 }
	ctx.HeadTop = 12.6
	ctx.EarX = 6.4
	ctx.NeckY = -1.6
	ctx.NeckR = { 8.2, 7.6 }
	ctx.NeckZ = 0.4
	ctx.FlowerAt = { 4.6, 11.6, -3 }
end

SPECIES.Slime = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- a squishy drop: flat bottom, rounded top, a little curl on top
	head(ctx, "Fur", { 0, -1.6, 0 }, { 9.6, 8.6, 9 })
	carve(g, { Kind = "Box", Center = { 0, -13.2, 0 }, Size = { 24, 6, 24 } })
	ell(g, "Fur", { 0, 7.6, 0.4 }, { 3.6, 2.6, 3.6 })
	curve(g, "Fur", { { 0, 9.6, 0.4 }, { 0.6, 11.6, 0 }, { 1.8, 12.4, -0.4 } }, 1.3, 0.7)
	-- inner darker core near the bottom, glossy highlights on top
	paint(g, "Stripe", { Kind = "Ellipsoid", Center = { 0, -9.4, 0 }, Radius = { 9.4, 1.6, 9 } }, "Fur")
	if H then
		cap(g, "Spark", { 4.6, 4.2, -6.4 }, { 6.6, 1.8, -6 }, 0.7, 0.6, { Op = "Paint", OnlyKeys = "Fur" })
		ell(g, "Spark", { 3, 5.6, -6.4 }, { 0.8, 0.8, 1 }, { Op = "Paint", OnlyKeys = "Fur" })
		-- a few drips
		pair(function(s)
			ell(g, "Fur", { s * 6.4, -9.6, -3.6 }, { 1.4, 1.4, 1.4 })
		end)
	end
	addEyes(ctx, 5, 2.6, "Round")
	if H then
		face(ctx, "Mouth", { { 0, -2.4 }, { -1, -2 }, { 1, -2 } })
	end
	blush(ctx, 5.4, -2.2, 3)
	ctx.Pal.Stripe = darken(ctx.Look.Primary, 0.12)
	ctx.WingHinge = { 5.2, 0, 4.6 }
	ctx.HeadTop = 9.4
	ctx.EarX = 3
	ctx.NeckY = -4
	ctx.NeckR = { 9.4, 8.8 }
	ctx.NeckZ = 0
	ctx.FlowerAt = { 4.6, 7.4, -3.6 }
end

SPECIES.Unicorn = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	head(ctx, "Fur", { 0, 6.8, 0 }, { 7.8, 7, 7 })
	-- long soft muzzle with nostrils
	ell(g, "Muzzle", { 0, 3.4, -6.8 }, { 4, 3.2, 3.4 })
	pair(function(s)
		local X, Y = vx(s * 1.7), vx(4)
		local z = frontZ(g, X, Y)
		if z then
			set(g, X, Y, z, "Nostril")
		end
		triEar(ctx, s, { 4.4, 11, 0.6 }, { 5.6, 16.4, 1.2 }, 2.2)
	end)
	if H then
		face(ctx, "Mouth", { { -1, 1.6 }, { 0, 1.4 }, { 1, 1.6 } })
	end
	-- spiral golden horn
	cone(g, "Gold", { 0, 12.2, -2.8 }, { 0, 19.4, -4.6 }, 1.9, 0.3)
	if H then
		for i = 0, 2 do
			box(g, "GoldDeep", { 0, 13.6 + i * 2, -3.2 - i * 0.45 }, { 5, 0.7, 5 }, { Op = "Paint", OnlyKeys = "Gold" })
		end
	end
	-- flowing mane down the back of the head and neck, with a forelock
	ell(g, "Accent", { 0, 10.4, 3.6 }, { 2.8, 4.4, 4.2 })
	curve(g, "Accent", { { 0, 12, 1.6 }, { 0, 9.4, 6.6 }, { 0, 3.6, 7.6 }, { 0, -1, 7.2 } }, 2.6, 1.6)
	curve(g, "AccentDark", { { 1.4, 11.4, 3 }, { 1.6, 7, 7.4 }, { 1.4, 2.6, 8.2 } }, 1.2, 0.8)
	curve(g, "Accent", { { 0, 12.6, -2 }, { -1.6, 11.6, -5 }, { -2.6, 9.6, -6.4 } }, 1.5, 0.9)
	sitBody(ctx, { BodyR = { 5.4, 5.8, 6 }, PawKey = "Hoof", FrontX = 2.9, Toes = false })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -4, -4.4 }, Radius = { 3.4, 4.6, 2.4 } }, "Fur")
	addEyes(ctx, 5.4, 9.4, "Round")
	blush(ctx, 5.6, 5, 2)
	-- flowing tail
	local t = newTail(ctx, { 0, -7.8, 6 }, 0.26)
	curve(t, "Accent", { { 0, 0, 0 }, { 0, 1.8, 3.6 }, { 0, -0.2, 7 }, { 0, -2.6, 8.2 } }, 2, 1.4)
	if H then
		curve(t, "AccentDark", { { 0.6, 0.6, 1.6 }, { 0.8, 1.2, 4.6 }, { 0.8, -2, 7.8 } }, 0.8, 0.6)
	end
	ctx.Pal.Hoof = mix(ctx.Pal.Gold, ctx.Look.Primary, 0.35)
	ctx.Pal.Muzzle = lighten(ctx.Look.Primary, 0.35)
	ctx.EarX = 5
	ctx.HeadTop = 13.6
	ctx.FlowerAt = { 5, 12, -3 }
end

SPECIES.Phoenix = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	head(ctx, "Fur", { 0, 5.4, -0.6 }, { 8, 7.4, 7 })
	ell(g, "Fur", { 0, -4, 1 }, { 6.4, 6.6, 6.4 })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.4, -4.2 }, Radius = { 4.4, 5.6, 3 } }, "Fur")
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, 3.6, -6 }, Radius = { 5, 3.6, 2.4 } }, "Fur")
	-- hooked golden beak
	cone(g, "Beak", { 0, 4.6, -6.4 }, { 0, 2.2, -9.4 }, 1.7, 0.4)
	-- crest: three plumes with glowing tips
	for i = -1, 1 do
		curve(g, (i == 0) and "Accent" or "Fur", { { i * 1.4, 11.4, 0 }, { i * 2.6, 15.4, 0.6 }, { i * 3.6, 17.4, 2.6 } }, 1.2, 0.6)
		ell(g, "Glow", { i * 3.6, 17.6, 2.8 }, { 0.9, 0.9, 0.9 })
	end
	-- cheek feathers
	pair(function(s)
		cone(g, "Accent", { s * 6.4, 4, -1 }, { s * 9.4, 2.4, 1.6 }, 1.8, 0.3)
	end)
	-- feet
	pair(function(s)
		ell(g, "Feet", { s * 2.8, -10.4, -1.6 }, { 1.5, 0.9, 2 })
		cap(g, "Feet", { s * 2.6, -9, 0 }, { s * 2.8, -10.2, -1 }, 0.7, 0.6)
	end)
	addEyes(ctx, 5, 7.8, "Round")
	blush(ctx, 5.2, 3.6, 2)
	-- long flowing tail plumes with glowing ends
	local t = newTail(ctx, { 0, -6.6, 5.6 }, 0.18)
	for i = -1, 1 do
		local tip = { i * 3, -4 + abs(i) * 1.4, 11.6 }
		curve(t, (i == 0) and "Accent" or "Fur", { { 0, 0, 0 }, { i * 1.2, -1.2, 4.4 }, { i * 2.4, -3, 8.4 }, tip }, 1.2, 0.6)
		ell(t, "Glow", { tip[1], tip[2] - 0.6, tip[3] + 0.4 }, { 1, 1, 1 })
	end
	ctx.Pal.Glow = { Color = lighten(ctx.Look.Secondary, 0.35), Material = NEON }
	ctx.Pal.Belly = mix(ctx.Look.Secondary, CREAM, 0.3)
	ctx.Pal.Feet = mix(rgb(246, 170, 70), ctx.Look.Secondary, 0.3)
	ctx.WingHinge = { 4.8, -1.2, 3.6 }
	ctx.HeadTop = 12.4
	ctx.EarX = 3.6
	ctx.NeckY = -0.4
	ctx.NeckR = { 6.8, 6.6 }
	ctx.FlowerAt = { 5.6, 10.6, -2.6 }
end

SPECIES.Frog = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- wide, flat head-body with bulging eye domes on top
	head(ctx, "Fur", { 0, 2.4, -0.6 }, { 9.6, 6.4, 8 })
	ell(g, "Fur", { 0, -4.4, 1.4 }, { 7.6, 5.6, 6.8 })
	pair(function(s)
		ell(g, "Fur", { s * 4.6, 7.4, -2.4 }, { 3.2, 3.2, 3.2 })
	end)
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -2.4, -5 }, Radius = { 6.6, 6.2, 3.6 } }, "Fur")
	-- back spots
	if H then
		for _, p in ipairs({ { 3, 6.4, 5 }, { -4, 5, 5.6 }, { 0, 7.6, 3.4 }, { 5.6, 1, 6.6 }, { -5.6, 0, 6.6 }, { 1.6, -2.4, 7.6 } }) do
			paint(g, "Stripe", { Kind = "Ellipsoid", Center = p, Radius = { 1.4, 1.4, 1.4 } }, "Fur")
		end
	end
	-- wide smile across the face
	if H then
		face(ctx, "Mouth", { { -3, 1.4 }, { -2, 0.8 }, { -1, 0.6 }, { 0, 0.6 }, { 1, 0.6 }, { 2, 0.8 }, { 3, 1.4 } })
	else
		face(ctx, "Mouth", { { -1, 0.8 }, { 0, 0.8 }, { 1, 0.8 } })
	end
	-- splayed front legs, folded hind legs, webbed feet
	pair(function(s)
		cap(g, "Fur", { s * 4.4, -5, -3 }, { s * 5.4, -9.6, -4.6 }, 1.5, 1.3)
		ell(g, "Belly", { s * 5.8, -10.4, -5.4 }, { 2.2, 0.9, 1.8 })
		ell(g, "Fur", { s * 6.8, -6.6, 2 }, { 2.6, 3.2, 4 })
		ell(g, "Belly", { s * 7.4, -10.2, -0.4 }, { 2.4, 1, 2.6 })
	end)
	addEyes(ctx, 6, 8.6, "Small")
	blush(ctx, 6.4, 2.6, 2)
	ctx.Pal.Stripe = darken(ctx.Look.Primary, 0.22)
	ctx.WingHinge = { 5.4, -1.6, 4.4 }
	ctx.HeadTop = 10.2
	ctx.EarX = 4.6
	ctx.NeckY = -1.4
	ctx.NeckR = { 8.6, 7.6 }
	ctx.NeckZ = 0.4
	ctx.FlowerAt = { 6.6, 9.4, -2 }
end

SPECIES.Penguin = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	-- egg-shaped body, white front with a heart-shaped face
	head(ctx, "Fur", { 0, 5.2, -0.2 }, { 8, 7.4, 7.2 })
	ell(g, "Fur", { 0, -3.8, 0.6 }, { 7.4, 7.6, 7 })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.8, -3.6 }, Radius = { 5.6, 7, 4.2 } }, "Fur")
	pair(function(s)
		ell(g, "Belly", { s * 2.9, 5, -5.2 }, { 3.6, 4, 2.6 }, { Op = "Paint", OnlyKeys = "Fur" })
		-- flippers resting at the sides
		ell(g, "Fur", { s * 7.4, -2.6, 0.6 }, { 1.6, 4.4, 2.6 }, { Rotation = CFrame.Angles(0, 0, s * 0.3) })
		-- orange feet
		ell(g, "Feet", { s * 2.8, -11, -2.2 }, { 1.9, 0.9, 2.4 })
	end)
	-- small orange beak
	cone(g, "Beak", { 0, 3.8, -6.6 }, { 0, 3.2, -9 }, 1.5, 0.4)
	addEyes(ctx, 5, 7.8, "Small")
	blush(ctx, 4.8, 3, 3)
	local t = newTail(ctx, { 0, -9, 5.8 }, 0.18)
	cone(t, "Fur", { 0, 0, 0 }, { 0, -1.2, 3.2 }, 2.2, 0.8)
	ctx.WingHinge = { 6.4, -0.8, 2.8 }
	ctx.HeadTop = 12.4
	ctx.EarX = 3
	ctx.NeckY = -0.6
	ctx.NeckR = { 7.8, 7.4 }
	ctx.NeckZ = 0.4
	ctx.FlowerAt = { 5, 10.6, -2.8 }
end

SPECIES.Axolotl = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	head(ctx, "Fur", { 0, 5.4, -0.4 }, { 9, 6.6, 7 })
	ell(g, "Fur", { 0, -4, 1.8 }, { 5.4, 5.6, 6.6 })
	paint(g, "Belly", { Kind = "Ellipsoid", Center = { 0, -3.8, -3.6 }, Radius = { 3.8, 4.6, 2.6 } }, "Fur")
	-- three feathery gills on each side
	pair(function(s)
		for i = -1, 1 do
			local a = { s * 7, 6.6 + i * 2.4, 0.4 }
			local b = { s * 11.2, 8.4 + i * 3.4, 1.6 }
			cap(g, "Accent", a, b, 1, 0.8)
			if H then
				for j = 1, 2 do
					local tx = a[1] + (b[1] - a[1]) * (j / 2.6)
					local ty = a[2] + (b[2] - a[2]) * (j / 2.6)
					cap(g, "AccentDark", { tx, ty, 0.8 }, { tx + s * 0.6, ty + 1.2, 1 }, 0.5, 0.4)
				end
			end
		end
	end)
	-- wide happy smile
	if H then
		face(ctx, "Mouth", { { -3, 2.2 }, { -2, 1.6 }, { -1, 1.6 }, { 0, 1.6 }, { 1, 1.6 }, { 2, 1.6 }, { 3, 2.2 } })
	end
	-- little legs
	pair(function(s)
		cap(g, "Fur", { s * 3.6, -6, -1.6 }, { s * 4.6, -9.6, -2.6 }, 1.4, 1.1)
		cap(g, "Fur", { s * 3.8, -6.6, 3.6 }, { s * 5, -9.6, 3.6 }, 1.4, 1.1)
		ell(g, "Accent", { s * 4.8, -10, -3 }, { 1.4, 0.8, 1.4 })
		ell(g, "Accent", { s * 5.1, -10, 3.4 }, { 1.4, 0.8, 1.4 })
	end)
	addEyes(ctx, 6.6, 8.2, "Round")
	blush(ctx, 6, 3.4, 3)
	-- paddle tail with a fin
	local t = newTail(ctx, { 0, -7, 6.4 }, 0.35)
	curve(t, "Fur", { { 0, 0, 0 }, { 0, -0.4, 4 }, { 0, 0.6, 8 } }, 2, 1)
	ell(t, "Accent", { 0, 1.2, 5.6 }, { 0.8, 3.4, 4.4 })
	ctx.Pal.Belly = lighten(ctx.Look.Primary, 0.3)
	ctx.WingHinge = { 4.2, -1.4, 4.8 }
	ctx.HeadTop = 11.8
	ctx.EarX = 4
	ctx.NeckY = 0.4
	ctx.NeckR = { 6.2, 7 }
	ctx.NeckZ = 1
	ctx.FlowerAt = { 5, 10.6, -2.4 }
end

-- Stormfang: the player's own creature (ARCHITECTURE_V3.md section 10, branding/stormfang-*.png), sculpted to
-- follow their art: a lean, fierce but cute storm lynx crouched on its storm cloud, ready to pounce. Layered
-- charcoal armour plates in four greys (light bevelled top edges, darker grooves) with stepped ridge spikes sweeping
-- back over the head, shoulders and spine; a white fluffy face mask with white brows sweeping up to the ears and a
-- spiky cheek ruff; tall stepped lynx ears with neon violet and electric-blue stripes; fierce slanted glowing eyes
-- with a violet rim; a cyan diamond gem in a V-shaped forehead plate (smaller gems on the chest and shoulder
-- plates); big armoured paws with glowing claws; a fluffy armoured tail with neon bands. Built mostly from
-- axis-aligned steps, like the art, which also keeps the part count low.

-- Screen-space masks pressed onto the front surface (gems): B dark bezel, R glass rim, G gem, C bright core.
local STORM_MASKS = {
	Brow = {
		". . . B . . .",
		". . B R B . .",
		". B R G R B .",
		"B R G C G R B",
		". R G C G R .",
		". B R G R B .",
		". . B R B . .",
		". . . B . . .",
	},
	BrowLow = {
		". R .",
		"R C R",
		". G .",
	},
	Chest = {
		". . B . .",
		". B G B .",
		"B G C G B",
		". B G B .",
		". . B . .",
	},
	ChestLow = {
		"C",
	},
	Shoulder = {
		". G .",
		"G C G",
		". G .",
	},
}
-- mask character -> { palette key, voxels it stands out of the surface }
local STORM_MASK_KEYS = { B = { "Base", 0 }, R = { "GemRim", 1 }, G = { "Gem", 1 }, C = { "GemCore", 2 } }

-- Presses a mask onto the frontmost surface around x = cx (design units), top row at yTop. Only voxels whose
-- current key is in `only` (when given) are touched, so a gem never lands on a neighbouring paw or tuft.
local function stormMask(ctx, rows, cx, yTop, only)
	local g = ctx.Body
	local mask = parseMask(rows)
	local half = floor(#mask[1] / 2)
	local X0, Y0 = vx(cx) + half, vx(yTop)
	for r, cols in ipairs(mask) do
		for c, ch in ipairs(cols) do
			local spec = STORM_MASK_KEYS[ch]
			if spec then
				local x, y = X0 - (c - 1), Y0 - (r - 1)
				local z = frontZ(g, x, y)
				if z and (not only or only[Voxel.BaseKey(get(g, x, y, z))]) then
					set(g, x, y, z, spec[1])
					for i = 1, spec[2] do
						set(g, x, y, z - i, spec[1])
					end
				end
			end
		end
	end
end

-- An axis-aligned stepped shape from a to b (design units): `steps` boxes along the way (default one per design
-- voxel), their full size interpolated from sa to sb ({x, y, z}; a box should be at least as long as one step along
-- the way). Stepped blades, ears and tufts stay crisp and merge into few parts, like the chunky steps of the art.
-- Every box is at least ~one sculpted voxel thick, so thin blades never vanish at Low detail.
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
		local t2 = { Kind = "Box", Center = { a[1] + dx * t, a[2] + dy * t, a[3] + dz * t }, Size = size, Key = key }
		shape(g, withExtra(t2, extra))
	end
end

-- A ridge spike: a plate blade in three chunky steps from its root `a` back to its point `b` (root size {w, h}).
local function stormSpike(g, a, b, w, h)
	local len = max(abs(b[2] - a[2]), abs(b[3] - a[3]))
	local step = len / 3 + 0.6
	stair(g, "Plate", a, b, { w or 2, max(h or 2, step), step }, { 1, max(1.2, step * 0.7), step }, 3)
end

local function rbox(g, key, c, size, round)
	return shape(g, { Kind = "RoundBox", Center = c, Size = size, Round = round or 1, Key = key })
end

SPECIES.Stormfang = function(ctx)
	local g, H = ctx.Body, ctx.Fine
	local look = ctx.Look
	local PAINT_ARMOUR = { Op = "Paint", OnlyKeys = { Fur = true, Plate = true } }

	-------------------------------------------------- head: a wide wedge with a short muzzle
	rbox(g, "Fur", { 0, 6.4, -1 }, { 15, 9, 11 }, 2)
	rbox(g, "Mask", { 0, 2.8, -2.6 }, { 15, 5.6, 8.6 }, 2)
	ctx.HeadC, ctx.HeadR, ctx.HeadTop = { 0, 6.4, -1 }, { 7.5, 4.5, 5.5 }, 10.9
	-- white around the eyes, the muzzle with its grey bridge and dark nose
	pair(function(s)
		box(g, "Mask", { s * 4.6, 6.6, -6.4 }, { 5, 3, 2 }, { Op = "Paint", OnlyKeys = "Fur" })
	end)
	rbox(g, "Mask", { 0, 3, -7.6 }, { 6.4, 4.4, 4 }, 1)
	box(g, "Fur", { 0, 5.6, -7.4 }, { 3, 1.6, 4.4 })
	box(g, "Nose", { 0, 4.6, -9.8 }, { 3, 1.4, 1 })
	if H then
		face(ctx, "Mouth", { { 0, 3 }, { 0, 2 }, { 1, 1.6 }, { -1, 1.6 } })
	end
	-- the V-shaped forehead plate that holds the gem, stepping down to the bridge
	stair(g, "Plate", { 0, 11.6, -6.6 }, { 0, 6, -7.4 }, { 7.2, 1.2, 3 }, { 1.2, 1.2, 3 }, 6, { Op = "Paint", OnlyKeys = { Fur = true, Mask = true } })
	pair(function(s)
		-- white brows sweeping up and out to the ear roots
		if H then
			stair(g, "Mask", { s * 3.6, 10.2, -5.6 }, { s * 7.6, 12.4, -3.4 }, { 3, 1.8, 2 }, { 1.6, 1.4, 1.6 }, 2)
		end
		-- the cheek ruff: jagged white tufts flaring out and down
		stair(g, "Mask", { s * 7.2, 4.6, -2.6 }, { s * 11, 6, -0.4 }, { 2.4, 2.6, 3.4 }, { 1.6, 1.2, 1.4 }, 2)
		stair(g, "Mask", { s * 7.4, 2, -2.4 }, { s * 11.4, 1, 0 }, { 2.4, 2.6, 3.4 }, { 1.6, 1.2, 1.4 }, 2)
		if H then
			stair(g, "Mask", { s * 6, 0.2, -3 }, { s * 9, -1.8, -1 }, { 2.2, 2, 3 }, { 1.4, 1.2, 1.4 }, 2)
		end
	end)

	-------------------------------------------------- crest: stepped blades sweeping back over the head
	stormSpike(g, { 0, 10.8, -5 }, { 0, 15.4, 2.6 }, 3, 2.2)
	if H then
		pair(function(s)
			stormSpike(g, { s * 3, 10.6, -4 }, { s * 4.6, 13.8, 3 }, 2.4, 2)
		end)
	end

	-------------------------------------------------- tall stepped lynx ears: dark inside, neon violet + blue stripes
	pair(function(s)
		stair(g, "Fur", { s * 4.6, 10.2, 0.4 }, { s * 7.4, 19.2, 1.6 }, { 6, 2.2, 4.4 }, { 1.4, 2.2, 1.4 }, 5)
		-- the front face: dark, a violet stripe up the outer side and a blue one up the inner side
		stair(g, "Base", { s * 4.8, 10.8, -1.2 }, { s * 7.2, 17.4, 1.2 }, { 3.6, 2.2, 1.6 }, { 1.2, 2.2, 1.6 }, 4, { Op = "Paint", OnlyKeys = "Fur" })
		stair(g, "NeonViolet", { s * 6.4, 11, -1.2 }, { s * 7.4, 17, 1 }, { 1.2, 2.2, 1.6 }, { 1.2, 2.2, 1.6 }, 3, { Op = "Paint", OnlyKeys = "Base" })
		stair(g, "NeonBlue", { s * 3.6, 11.4, -1.2 }, { s * 6.4, 16.2, 1 }, { 1.2, 2.2, 1.6 }, { 1.2, 2.2, 1.6 }, 3, { Op = "Paint", OnlyKeys = "Base" })
	end)

	-------------------------------------------------- body: crouched with high shoulders, armoured legs, huge paws
	rbox(g, "Fur", { 0, -5.2, 1.4 }, { 9, 8, 11 }, 2)
	rbox(g, "Fur", { 0, -2.6, -2.2 }, { 8, 6, 5 }, 1.5)
	-- white neck fluff under the chin, the chest plate below it
	stair(g, "Mask", { 0, 0.4, -4.2 }, { 0, -2.6, -5.2 }, { 6, 2, 2.4 }, { 2, 1.6, 1.6 }, 2)
	rbox(g, "Plate", { 0, -4.6, -4.4 }, { 5, 3.6, 1.6 }, 0.8)
	pair(function(s)
		-- haunches and hind feet
		rbox(g, "Fur", { s * 3.8, -8, 3.8 }, { 4.4, 5, 6 }, 1.5)
		rbox(g, "Plate", { s * 4.2, -10.4, 0.6 }, { 3.4, 1.6, 4 }, 0.6)
		-- front legs: a dark under-suit with two armour rings
		box(g, "Base", { s * 4, -6, -4.2 }, { 3.4, 6, 3.4 })
		rbox(g, "Fur", { s * 4, -4.2, -3.6 }, { 4.2, 3.2, 4.2 }, 1)
		rbox(g, "Plate", { s * 4, -7.6, -4.6 }, { 4, 2.4, 4 }, 1)
		-- big armoured paws: toe plates split by dark grooves, a glowing claw at the tip of each toe
		rbox(g, "Plate", { s * 4, -9.9, -6.4 }, { 7, 2.8, 5.6 }, 1)
		if H then
			for _, o in ipairs({ -2, 0, 2 }) do
				box(g, "Base", { s * (4 + o), -9.4, -8.4 }, { 1, 2, 1.6 }, { Op = "Paint", OnlyKeys = "Plate" })
			end
			for _, o in ipairs({ -3, -1, 1, 3 }) do
				box(g, "Claw", { s * (4 + o), -10.6, -9.8 }, { 1, 2, 1 })
			end
		else
			for _, o in ipairs({ -2, 2 }) do
				box(g, "Claw", { s * (4 + o), -10.6, -9.6 }, { 2.1, 2.1, 2.1 })
			end
		end
		-- layered shoulder plates (pauldrons): a light bevelled top edge, a neon seam, a stepped spike
		rbox(g, "Fur", { s * 7.2, -3.2, 0.6 }, { 4.4, 3.2, 6.6 }, 1)
		rbox(g, "Plate", { s * 6.6, -0.6, -0.6 }, { 5, 3, 7 }, 1)
		box(g, "Bevel", { s * 6.6, 0.8, -0.6 }, { 5.2, 1, 7.4 }, { Op = "Paint", OnlyKeys = "Plate" })
		box(g, "NeonBlue", { s * 7.2, -2.2, -0.4 }, { 5, 1, 7.4 }, PAINT_ARMOUR)
		stormSpike(g, { s * 6.8, 1.4, 0 }, { s * 9.4, 3.8, 5.6 }, 2, 2)
	end)
	-- spine ridge
	stormSpike(g, { 0, -0.6, 4.6 }, { 0, 2.6, 9.4 }, 2, 2)

	-------------------------------------------------- face + gems
	addEyes(ctx, 7, 9, "Fierce", true)
	if H then
		stormMask(ctx, STORM_MASKS.Brow, 0, 11.4, { Plate = true, Fur = true })
		stormMask(ctx, STORM_MASKS.Chest, 0, -2.6, { Plate = true })
		pair(function(s)
			stormMask(ctx, STORM_MASKS.Shoulder, s * 6.6, 0.4, { Plate = true, Bevel = true })
		end)
	else
		stormMask(ctx, STORM_MASKS.BrowLow, 0, 10.4, { Plate = true, Fur = true })
		stormMask(ctx, STORM_MASKS.ChestLow, 0, -4, { Plate = true, Fur = true })
	end

	-------------------------------------------------- fluffy armoured tail: plates, neon bands, a white tuft
	local t = newTail(ctx, { 0, -7.4, 7.2 }, 0.26)
	rbox(t, "Fur", { 0, 0.6, 2 }, { 3.4, 3.2, 4.4 }, 1)
	stair(t, "Fur", { 0, 2.4, 4 }, { 0, 8.4, 5.8 }, { 3.4, 3, 3.4 }, { 4.2, 3, 3.6 }, 3)
	rbox(t, "Mask", { 0, 11, 5.4 }, { 4.8, 4.4, 4.6 }, 1.4)
	if H then
		stair(t, "Mask", { 0, 12.8, 5 }, { 0, 14.6, 3.4 }, { 2.4, 1.6, 2 }, { 1.2, 1.2, 1.2 }, 2)
		stormSpike(t, { 0, 4.6, 6.6 }, { 0, 6.6, 9.6 }, 1.6, 1.6)
	end
	for _, y in ipairs(H and { 3.6, 7 } or { 5.4 }) do
		box(t, "NeonBlue", { 0, y, 5 }, { 8, H and 1 or 2.1, 12 }, { Op = "Paint", OnlyKeys = "Fur" })
	end

	-------------------------------------------------- palette, faithful to the art (the charcoal comes from the Look)
	local P = look.Primary
	local pal = ctx.Pal
	pal.Base = P -- ~#2a2c33 charcoal: grooves, under-suit, ear insides, bezels
	pal.Fur = mix(P, rgb(96, 99, 110), 0.6) -- ~#4b4d57 armour
	pal.Plate = mix(P, rgb(148, 152, 164), 0.65) -- ~#70737e raised plates and spikes
	pal.Bevel = mix(P, rgb(190, 193, 200), 0.82) -- ~#a3a6ae light bevelled edges
	pal.Mask = rgb(242, 244, 248)
	pal.Mask_Light = rgb(252, 252, 255)
	pal.Mask_Dark = rgb(210, 214, 226)
	pal.Nose = rgb(28, 29, 36)
	pal.Mouth = rgb(40, 41, 50)
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
	pal.EyeGlint = { Color = lighten(look.Eye, 0.6), Material = NEON }
	pal.EyeRing = { Color = rgb(122, 60, 255), Material = NEON }
	pal.EyeShine = rgb(252, 252, 255)
	ctx.Pulse = { NeonViolet = true, NeonBlue = true, Claw = true, Gem = true, GemCore = true }
	-- the armour greys are painted as layers (no automatic shading: crisp plates, few parts); the fur is shaded
	for _, k in ipairs({ "Base", "Fur", "Plate", "Bevel", "NeonViolet", "NeonBlue", "Claw", "Gem", "GemCore", "GemRim" }) do
		ctx.NoShade[k] = true
	end
	-- the LOD may fold the fur's shading but never recolours a plate layer
	for _, k in ipairs({ "Base", "Fur", "Plate", "Bevel", "Mask", "NeonViolet", "NeonBlue", "Claw", "Gem", "GemCore", "GemRim" }) do
		ctx.Keep[k] = true
	end
	-- anchors for accessories (other looks may combine them)
	ctx.EarX = 6.2
	ctx.HornBase = { 3.4, 9.6, -0.4 }
	ctx.FlowerAt = { 5, 11, -3.6 }
	ctx.NeckY = 0.4
	ctx.NeckR = { 5.4, 5 }
	ctx.NeckZ = -1.4
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

-- The little storm cloud Stormfang rides (branding/stormfang-art.png): heaped dark navy puffs, lighter blue tops
-- and a few white puffs, under and around the rider, which sinks into it a little. Its two halves are the WingL /
-- WingR groups (the right half is the mirror image); Animate sways and drifts them gently instead of flapping.
-- Any species can ride it: the cloud is placed under the lowest voxels of the body it carries.
WINGS.StormCloud = function(ctx, w)
	local H = ctx.Fine
	local floorY, midZ = -11.2, 1
	local x0, y0, z0, x1, y1, z1 = Voxel.Bounds(ctx.Body)
	if y0 and SK > 0 then
		floorY = y0 / SK
		midZ = (z0 + z1) / 2 / SK
	end
	ctx.WingHinge = { 0.5, floorY + 1, midZ }
	-- the LEFT half in hinge-local design voxels: a flat rounded base, then puffs heaped around the rim (low in front
	-- so the paws and claws hang over the edge, high at the back and the sides)
	rbox(w, "Wing", { -6, -1.6, 0.6 }, { 13, 3.6, 15 }, 1.6)
	local puffs = {
		{ -11.2, 0, -0.6, 6, 5, 6.8 },
		{ -9.2, 0.8, 4.6, 6.4, 5.4, 6 },
		{ -3.6, 1.4, 6.4, 7, 5.8, 5 },
		{ -8, -0.6, -5.4, 5.4, 4, 5 },
	}
	for _, p in ipairs(puffs) do
		rbox(w, "Wing", { p[1], p[2], p[3] }, { p[4], p[5], p[6] }, 1.8)
	end
	-- lighter tops: the upper layers of the heap, the brightest caps on the high puffs, a few white puffs
	paint(w, "CloudMid", { Kind = "Box", Center = { -8, 4.6, 0 }, Size = { 30, 8, 30 } }, "Wing")
	paint(w, "CloudTop", { Kind = "Box", Center = { -8, 6.6, 0 }, Size = { 30, 8, 30 } }, "CloudMid")
	ell(w, "CloudLight", { -3.4, 4.2, 6.8 }, { 1.7, 1.3, 1.6 })
	if H then
		ell(w, "CloudLight", { -10.6, 3.2, 3.8 }, { 1.5, 1.2, 1.5 })
	end
	local navy = ctx.Look.WingColor
	ctx.Pal.Wing = navy -- ~#2e3a66
	ctx.Pal.Wing_Light = mix(navy, rgb(107, 119, 168), 0.45) -- ~#44507f
	ctx.Pal.Wing_Dark = darken(navy, 0.25)
	ctx.Pal.CloudTop = mix(navy, rgb(107, 119, 168), 0.92) -- ~#6b77a8
	ctx.Pal.CloudLight = rgb(236, 240, 250)
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
	SK = k
	local ok, result = pcall(function()
		local ctx = newContext(look, detail)
		if lean then
			ctx.Fine = false
		end
		local budget = BUDGET[detail] or BUDGET.High
		SPECIES[look.Species](ctx)
		if look.Accessory then
			ACCESSORIES[look.Accessory](ctx)
		end
		carveEyes(ctx)
		Voxel.Shade(ctx.Body, { Skip = ctx.NoShade })
		WINGS[look.WingStyle](ctx, ctx.Wing)
		if not ctx.WingNoShade then
			Voxel.Shade(ctx.Wing, { Skip = ctx.NoShade, LightAt = 0.5 })
		end

		local bp = { Groups = {}, Pal = ctx.Pal, Look = look, Detail = detail, K = k, Pulse = ctx.Pulse }
		local bodyGroup = { Name = "Body" }
		bp.Groups[#bp.Groups + 1] = bodyGroup

		-- wings: left from the grid, right = exact mirror image
		local wh = ctx.WingHinge
		local hingeR = CFrame.new(wh[1], wh[2], wh[3]) * CFrame.Angles(0, -ctx.WingSweep, 0) * CFrame.Angles(0, 0, ctx.WingTilt)
		local hingeL = mirrorCF(hingeR)
		local wingBoxes = mergeGroup(ctx, ctx.Wing, budget.Wing)
		local wingKind = ctx.WingKind or "wing"
		bp.Groups[#bp.Groups + 1] = { Name = "WingL", Boxes = wingBoxes, Hinge = hingeL, Kind = wingKind, Side = 1 }
		bp.Groups[#bp.Groups + 1] = { Name = "WingR", Boxes = Voxel.MirrorBoxes(wingBoxes), Hinge = hingeR, Kind = wingKind, Side = -1 }

		if ctx.Tail then
			Voxel.Shade(ctx.Tail, { Skip = ctx.NoShade })
			local th = ctx.TailHinge
			bp.Groups[#bp.Groups + 1] = {
				Name = "Tail", Boxes = mergeGroup(ctx, ctx.Tail, budget.Tail),
				Hinge = CFrame.new(th[1], th[2], th[3]), Kind = "tail", Amp = ctx.TailWag,
			}
		end
		if ctx.Halo then
			local ha = ctx.HaloAt
			bp.Groups[#bp.Groups + 1] = {
				Name = "Halo", Boxes = mergeGroup(ctx, ctx.Halo, budget.Halo),
				Hinge = CFrame.new(ha[1], ha[2], ha[3]), Kind = "bob", Amp = 0.6,
			}
		end
		if look.Rarity == "Secret" then
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
		bodyGroup.Boxes = mergeGroup(ctx, ctx.Body, max(30, min(budget.Body, budget.Total - used)))
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
		local cap = (BUDGET[detail] or BUDGET.High).Cap
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
			VoxelSize = vs,
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
		-- a storm cloud half: a slow, gentle sway and drift (it rides the flap clock, so Flap / Excited speed it up)
		local a = 0.2 * sin(st.Flap * 0.45)
		return CFrame.new(0, st.Stud * 1.2 * sin(st.Flap * 0.3 + 1), 0) * CFrame.Angles(0.05 * sin(st.Flap * 0.25), 0, a * gr.Side)
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
	local bp, bpKey = getBlueprint(look, detail)
	local tpl = getTemplate(bp, bpKey, scale)
	local model = tpl:Clone()
	model.PrimaryPart = model:FindFirstChild("Body")
	if look.Rarity == "Legendary" or look.Rarity == "Mythic" or look.Rarity == "Secret" then
		addSparkles(model, look, (detail == "Low") and 3 or 5, scale)
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
