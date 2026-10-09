-- PetBuilder: every winged pet of Nimbus Climb, built in code from Parts only (no meshes, decals or
-- asset ids). Usable on the server, on the client and inside ViewportFrames.
-- Plain Lua 5.1-compatible syntax only.
--
-- API (contract: ARCHITECTURE_V2.md section 2)
--   PetBuilder.Build(petDef, opts)   -> Model   opts: { Scale = 1 }
--   PetBuilder.Animate(model, t, opts)           opts: { Flap = 1 (speed multiplier), Excited = 0..1 }
--   PetBuilder.GetHeight(petDef)     -> studs at Scale 1 (bounding box of the resting pose)
--   Extras: PetBuilder.Species / Accessories / WingStyles (the values Build understands)
--
-- Conventions
--   * The pet faces -Z (Roblox LookVector), up is +Y, its right hand is +X. Wings are named WingL / WingR.
--   * Every part is Anchored, CanCollide/CanTouch/CanQuery = false, Massless. Model.PrimaryPart = "Body".
--     Move the pet with model:PivotTo(cframe) and call Animate(model, t, opts) every frame afterwards.
--   * Animate never uses welds or Motor6D. Each animated part stores its resting offset relative to the
--     PrimaryPart (string attribute PB_Base) and Animate recomputes its CFrame from the PrimaryPart's
--     CURRENT CFrame, so the same code works in the workspace and in a ViewportFrame. Animated parts are
--     grouped in small joint trees ("nodes"): wing flap + feather fan, tail chain, ears, gills, halo,
--     orbiting rarity gems... A Clone() of a pet rebuilds its rig from those attributes on first Animate.
--   * Eyes blink every few seconds (Animate squashes the eyeball parts for a moment).
--   * Round things are Ball parts. Squashed round things (eyes, belly, ears...) are a Block with a
--     SpecialMesh of MeshType.Sphere (a built-in shape, no asset id), so every ellipsoid is exact.
--   * Part budget: roughly 35 to 66 parts per pet (the contract limit is ~70).
--   * Unknown Species / WingStyle / Accessory values fall back to Cat / Feather / none.

local PetBuilder = {}

PetBuilder.Species = {
	"Cat", "Dog", "Fox", "Bunny", "Bear", "Panda", "Dragon",
	"Owl", "Slime", "Unicorn", "Phoenix", "Frog", "Penguin", "Axolotl",
}
PetBuilder.Accessories = { "Horns", "Crown", "Halo", "Leaf", "Mushroom", "Scarf", "Antlers", "Flower" }
PetBuilder.WingStyles = { "Feather", "Bat", "Fairy", "Cloud", "Crystal", "Flame" }

----------------------------------------------------------------------
-- Constants and tiny helpers
----------------------------------------------------------------------
local PI = math.pi
local TAU = PI * 2
local MIN_SIZE = 0.05 -- smallest part dimension we ask the engine for (studs)
local BASE_SCALE = 0.88 -- all geometry below is authored a little large; this brings a pet to ~2.2-3.1 studs

local FLAP_HZ = 2.0 -- wing beats per second at Flap = 1
local WAG_HZ = 0.9 -- tail wags per second
local SWAY_HZ = 0.55 -- slow idle sway (ears, scarf, leaves, halo bob...)
local BLINK_TIME = 0.16 -- seconds a blink lasts

local V3 = Vector3.new
local CF = CFrame.new
local A = CFrame.Angles
local IDENT = CFrame.new()
local ZERO = Vector3.new(0, 0, 0)

local NEON = Enum.Material.Neon
local SMOOTH = Enum.Material.SmoothPlastic

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

local WHITE = rgb(255, 255, 255)
local BLACK = rgb(0, 0, 0)

-- Fixed little palette for things that should not depend on the pet's own colours.
local GOLD = rgb(244, 196, 78)
local GOLD_LIGHT = rgb(255, 226, 140)
local CREAM = rgb(255, 240, 214)
local PINK = rgb(246, 156, 174)
local BEAK = rgb(240, 178, 80)
local LEAF = rgb(108, 184, 112)
local LEAF_LIGHT = rgb(150, 210, 128)
local CAP = rgb(214, 92, 102)
local SCARF = rgb(206, 84, 98)
local SCARF_STRIPE = rgb(246, 220, 196)
local NOSE = rgb(58, 44, 52)

local function lighten(c, t)
	return c:Lerp(WHITE, t)
end

local function darken(c, t)
	return c:Lerp(BLACK, t)
end

local function mix(a, b, t)
	return a:Lerp(b, t)
end

local function asColor(v, fallback)
	if typeof(v) == "Color3" then
		return v
	end
	return fallback
end

local function rgbToHsv(c)
	local r, g, b = c.R, c.G, c.B
	local mx = math.max(r, g, b)
	local mn = math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 0.000001 then
		if mx == r then
			h = ((g - b) / d) % 6
		elseif mx == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h = h / 6
	end
	local s = 0
	if mx > 0 then
		s = d / mx
	end
	return h, s, mx
end

-- A brighter, slightly more saturated version of the eye colour (the glossy iris under the highlights).
local function irisColor(c)
	local h, s, v = rgbToHsv(c)
	return Color3.fromHSV(h, clamp(s * 1.05, 0, 1), clamp(v * 1.7 + 0.1, 0, 1))
end

-- Mirror a CFrame across the pet's YZ plane (x -> -x). Used for everything on the left side.
local function mirrorCF(cf)
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return CFrame.new(-x, y, z, r00, -r01, -r02, -r10, r11, r12, -r20, r21, r22)
end

local unpackList = table.unpack or unpack

-- CFrames are stored on parts as plain strings ("x,y,z,r00,...,r22"): string attributes are supported
-- everywhere, so a Clone() of a pet can always rebuild its animation rig.
local function cfToString(cf)
	return table.concat({ cf:GetComponents() }, ",")
end

local function stringToCF(str)
	if type(str) ~= "string" then
		return nil
	end
	local f = {}
	for token in string.gmatch(str, "[^,]+") do
		f[#f + 1] = tonumber(token)
	end
	if #f ~= 12 then
		return nil
	end
	for i = 1, 12 do
		if not f[i] then
			return nil
		end
	end
	return CFrame.new(unpackList(f))
end

-- Multiply only the translation of a CFrame (used for Build's Scale).
local function scaleCF(cf, k)
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return CFrame.new(x * k, y * k, z * k, r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

-- Rotation (no translation) whose -Z axis points along dir; segments are long along their local Z.
local function aim(dir, upHint)
	local up = upHint or V3(0, 1, 0)
	if math.abs(dir.Unit:Dot(up.Unit)) > 0.98 then
		up = V3(1, 0, 0)
	end
	return CFrame.lookAt(ZERO, dir, up)
end

local function sname(s)
	if s > 0 then
		return "R"
	end
	return "L"
end

-- Right-hand CFrame -> the CFrame for side s (s = 1 right/+X, s = -1 left/-X).
local function sd(s, cf)
	if s < 0 then
		return mirrorCF(cf)
	end
	return cf
end

-- Run fn(s) for the right (s = 1) and then the left (s = -1) side.
local function pair(fn)
	fn(1)
	fn(-1)
end

local function hashString(str)
	local h = 7
	for i = 1, #str do
		h = (h * 31 + string.byte(str, i)) % 99991
	end
	return h
end

----------------------------------------------------------------------
-- Per-model animation state. Weak keys: models that go away take their rig with them.
----------------------------------------------------------------------
local rigs = setmetatable({}, { __mode = "k" })

----------------------------------------------------------------------
-- Build context + part primitives
----------------------------------------------------------------------
local function newContext(look, scale, seed)
	local P, S, E, W = look.Primary, look.Secondary, look.Eye, look.WingColor
	local ctx = {
		Scale = scale * BASE_SCALE,
		Look = look,
		Seed = seed,
		Model = Instance.new("Model"),
		Nodes = {},
		Count = 0,
		EyeList = {},
		Glow = look.Glow == true,
		Primary = nil,
		C = {
			P = P,
			S = S,
			E = E,
			W = W,
			Belly = S,
			Iris = irisColor(E),
			Blush = mix(P, rgb(255, 118, 150), 0.55),
			Mouth = darken(mix(P, rgb(120, 60, 70), 0.5), 0.5),
			Pink = mix(PINK, P, 0.15),
		},
	}
	return ctx
end

-- Serialises a node's animation parameters (stored on the first part of the node so a Clone() of the
-- model can rebuild its rig).
local function specString(n)
	return table.concat({
		n.Kind, n.Axis, n.Amp, n.Lag, n.Axis2, n.Amp2, n.Lag2, n.Side, n.Bias, n.Rate, n.Phase, n.Parent or 0,
	}, "|")
end

local function parseSpec(str)
	local f = {}
	for token in string.gmatch(str, "[^|]+") do
		f[#f + 1] = token
	end
	local parent = tonumber(f[12]) or 0
	if parent == 0 then
		parent = nil
	end
	return {
		Kind = f[1] or "sway",
		Axis = f[2] or "z",
		Amp = tonumber(f[3]) or 0,
		Lag = tonumber(f[4]) or 0,
		Axis2 = f[5] or "-",
		Amp2 = tonumber(f[6]) or 0,
		Lag2 = tonumber(f[7]) or 0,
		Side = tonumber(f[8]) or 1,
		Bias = tonumber(f[9]) or 0,
		Rate = tonumber(f[10]) or 1,
		Phase = tonumber(f[11]) or 0,
		Parent = parent,
	}
end

-- A node is a joint: parts attached to it are rotated about `Hinge` (a CFrame in PrimaryPart space) by
-- an angle that depends on the node's Kind (wing / tail / ear / sway / bob). Nodes may have a parent
-- node; parents must be created first.
--   spec: Kind, Parent, Hinge (CFrame, unscaled), Axis ("x"|"y"|"z"), Amp, Lag, Axis2, Amp2, Lag2,
--         Side (+1/-1: mirrored nodes), Bias, Rate, Phase
local function newNode(ctx, spec)
	local n = {
		Kind = spec.Kind or "sway",
		Parent = spec.Parent,
		Axis = spec.Axis or "z",
		Amp = spec.Amp or 0,
		Lag = spec.Lag or 0,
		Axis2 = spec.Axis2 or "-",
		Amp2 = spec.Amp2 or 0,
		Lag2 = spec.Lag2 or 0,
		Side = spec.Side or 1,
		Bias = spec.Bias or 0,
		Rate = spec.Rate or 1,
		Phase = spec.Phase or 0,
		Parts = {},
		Base = {},
	}
	if n.Kind == "bob" or n.Kind == "orbit" then
		n.Amp = n.Amp * ctx.Scale -- a distance in studs
	end
	n.Hinge = scaleCF(spec.Hinge or IDENT, ctx.Scale)
	n.HingeInv = n.Hinge:Inverse()
	n.Id = #ctx.Nodes + 1
	ctx.Nodes[n.Id] = n
	return n.Id
end

-- Core part constructor. kind: "Ball" | "Ellipsoid" | "Block" | "Cylinder".
-- size is unscaled; rel is the unscaled CFrame relative to the PrimaryPart (the pet's rest pose).
local function makePart(ctx, name, kind, size, rel, color, o)
	o = o or {}
	local k = ctx.Scale
	local sx = math.max(size.X * k, MIN_SIZE)
	local sy = math.max(size.Y * k, MIN_SIZE)
	local sz = math.max(size.Z * k, MIN_SIZE)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CastShadow = o.Shadow == true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = o.Material or SMOOTH
	part.Color = color
	part.Transparency = o.Transparency or 0
	if kind == "Ball" then
		local d = (sx + sy + sz) / 3
		part.Shape = Enum.PartType.Ball
		part.Size = V3(d, d, d)
	elseif kind == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder
		part.Size = V3(sx, sy, sz)
	else
		part.Size = V3(sx, sy, sz)
		if kind == "Ellipsoid" then
			local mesh = Instance.new("SpecialMesh")
			mesh.Name = "Round"
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = part
		end
	end
	local scaled = scaleCF(rel, k)
	part.CFrame = scaled
	if o.Node then
		local n = ctx.Nodes[o.Node]
		local idx = #n.Parts + 1
		n.Parts[idx] = part
		n.Base[idx] = scaled
		part:SetAttribute("PB_Node", n.Id)
		part:SetAttribute("PB_Base", cfToString(scaled))
		if idx == 1 then
			part:SetAttribute("PB_Hinge", cfToString(n.Hinge))
			part:SetAttribute("PB_Spec", specString(n))
		end
	end
	part.Parent = ctx.Model
	ctx.Count = ctx.Count + 1
	return part
end

-- Ellipsoid (a Ball when the size is uniform). o.Mesh forces the resizable Block+SpecialMesh form.
local function blobCF(ctx, name, rel, size, color, o)
	local mx = math.max(size.X, size.Y, size.Z)
	local mn = math.min(size.X, size.Y, size.Z)
	local kind = "Ellipsoid"
	if mx - mn < 0.04 * mx and not (o and o.Mesh) then
		kind = "Ball"
	end
	return makePart(ctx, name, kind, size, rel, color, o)
end

local function blob(ctx, name, pos, size, color, rot, o)
	return blobCF(ctx, name, CF(pos) * (rot or IDENT), size, color, o)
end

-- Mirrored helper: pos / rot are given for the RIGHT side, s selects the side. Name gets an R / L suffix.
local function blobS(ctx, s, name, pos, size, color, rot, o)
	return blobCF(ctx, name .. sname(s), sd(s, CF(pos) * (rot or IDENT)), size, color, o)
end

local function blockCF(ctx, name, rel, size, color, o)
	return makePart(ctx, name, "Block", size, rel, color, o)
end

-- Upright cylinder (axis along local Y): dia x height.
local function cylCF(ctx, name, rel, dia, height, color, o)
	return makePart(ctx, name, "Cylinder", V3(height, dia, dia), rel * A(0, 0, PI / 2), color, o)
end

-- Chain of ellipsoid segments along a polyline: node i is parented to node i-1 and hinged at pts[i].
-- Used for tails, plumes, scarf ends, manes. widths[i] = segment diameter, colors[i] = its colour.
local function chain(ctx, name, pts, widths, colors, o)
	o = o or {}
	local parent = nil
	local ids = {}
	local parts = {}
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local d = b - a
		local len = d.Magnitude
		local id = newNode(ctx, {
			Kind = o.Kind or "tail",
			Parent = parent,
			Hinge = CF(a),
			Axis = o.Axis or "y",
			Amp = o.Amp or 0.22,
			Lag = (i - 1) * (o.Lag or 0.7),
			Axis2 = o.Axis2 or "x",
			Amp2 = o.Amp2 or 0.05,
			Lag2 = (i - 1) * (o.Lag2 or 0.5),
			Rate = o.Rate or 1,
			Phase = o.Phase or 0,
		})
		local w = widths[i]
		local seg = blobCF(
			ctx,
			name .. i,
			CF((a + b) * 0.5) * aim(d),
			V3(w, w * (o.Flat or 1), len * (o.Stretch or 1.25)),
			colors[i],
			{ Node = id }
		)
		ids[i] = id
		parts[i] = seg
		parent = id
	end
	return ids, parts
end

----------------------------------------------------------------------
-- Face helpers: points on the head ellipsoid
----------------------------------------------------------------------
-- theta: sideways angle from straight ahead (+ = pet's right), phi: elevation (+ = up).
local function headPoint(ctx, theta, phi)
	local hc, ha = ctx.HC, ctx.HA
	local ct, st = math.cos(theta), math.sin(theta)
	local cp, sp = math.cos(phi), math.sin(phi)
	local pos = V3(hc.X + ha.X * st * cp, hc.Y + ha.Y * sp, hc.Z - ha.Z * ct * cp)
	local nrm = V3(st * cp / ha.X, sp / ha.Y, -ct * cp / ha.Z).Unit
	return pos, nrm
end

-- CFrame on the head surface with -Z pointing out of the head (thin parts: depth = local Z).
local function faceCF(ctx, theta, phi, push, roll)
	local pos, nrm = headPoint(ctx, theta, phi)
	pos = pos + nrm * (push or 0)
	local up = V3(0, 1, 0)
	if math.abs(nrm.Y) > 0.97 then
		up = V3(0, 0, -1)
	end
	local cf = CFrame.lookAt(pos, pos + nrm, up)
	if roll and roll ~= 0 then
		cf = cf * A(0, 0, roll)
	end
	return cf
end

-- Big glossy eye: dark (or neon) ball, iris / pupil, two sparkle highlights. ecf = right eye frame.
local function buildEye(ctx, s, ecf, w, h, d)
	local C = ctx.C
	local nm = sname(s)
	local frame = sd(s, ecf)
	-- offsets are given in "right eye" terms; x is flipped on the left eye so highlights stay on the
	-- same world side (upper left as seen by someone looking at the pet).
	local function lp(x, y, z)
		return frame * CF(x * s, y, z)
	end
	local list = ctx.EyeList
	local base
	local second
	if ctx.Glow then
		base = blobCF(ctx, "Eye" .. nm, frame, V3(w, h, d), C.E, { Material = NEON, Mesh = true })
		second = blobCF(ctx, "Eye" .. nm .. "Pupil", lp(0, -h * 0.02, -d * 0.26), V3(w * 0.52, h * 0.64, d * 0.8), darken(C.E, 0.85), { Mesh = true })
	else
		base = blobCF(ctx, "Eye" .. nm, frame, V3(w, h, d), C.E, { Mesh = true })
		second = blobCF(ctx, "Eye" .. nm .. "Iris", lp(0, -h * 0.12, -d * 0.22), V3(w * 0.8, h * 0.56, d * 0.8), C.Iris, { Mesh = true })
	end
	local shine1 = blobCF(ctx, "Eye" .. nm .. "Shine", lp(w * 0.2, h * 0.2, -d * 0.56), V3(w * 0.29, w * 0.29, d * 0.3), WHITE, { Material = NEON, Mesh = true })
	local shine2 = blobCF(ctx, "Eye" .. nm .. "Shine2", lp(-w * 0.18, -h * 0.24, -d * 0.5), V3(w * 0.14, w * 0.14, d * 0.25), WHITE, { Material = NEON, Mesh = true })
	list[#list + 1] = { Part = base, Size = base.Size, Hide = false }
	list[#list + 1] = { Part = second, Size = second.Size, Hide = false }
	list[#list + 1] = { Part = shine1, Size = shine1.Size, Hide = true, T0 = 0 }
	list[#list + 1] = { Part = shine2, Size = shine2.Size, Hide = true, T0 = 0 }
end

-- Two little arcs forming a "w" mouth around the point (theta ~ 0, phi).
local function smileW(ctx, phi, push)
	pair(function(s)
		blobCF(ctx, "Mouth" .. sname(s), sd(s, faceCF(ctx, 0.12, phi, push or 0.02, 0.4)), V3(0.17, 0.055, 0.05), ctx.C.Mouth)
	end)
end

-- One wide thin smile.
local function smileWide(ctx, phi, width, push)
	pair(function(s)
		blobCF(ctx, "Mouth" .. sname(s), sd(s, faceCF(ctx, 0.2, phi, push or 0.02, 0.28)), V3(width, 0.06, 0.05), ctx.C.Mouth)
	end)
end

-- Rounded/cuddly muzzle patch on the lower face.
local function muzzle(ctx, phi, push, size, color)
	return blobCF(ctx, "Muzzle", faceCF(ctx, 0, phi, push or 0), size, color)
end

local function nose(ctx, phi, push, size, color)
	return blobCF(ctx, "Nose", faceCF(ctx, 0, phi, push or 0), size, color or NOSE, { Mesh = true })
end

-- Ears made of one or more ellipsoids per side (+ optional inner ear and tip), twitching on their own node.
-- e: Pos, Size, Roll, Pitch, Color, InColor, InOffset, TipColor, Hinge, Amp
local function earPair(ctx, e)
	pair(function(s)
		local n = newNode(ctx, {
			Kind = "ear",
			Hinge = sd(s, CF(e.Hinge)),
			Axis = "z",
			Amp = e.Amp or 0.05,
			Side = s,
			Phase = s * 2.1,
		})
		local rot = A(e.Pitch or 0, 0, e.Roll or 0)
		blobS(ctx, s, "Ear", e.Pos, e.Size, e.Color, rot, { Node = n })
		if e.InColor then
			local ip = e.Pos + (e.InOffset or V3(-0.02, -0.04, -0.1))
			blobS(ctx, s, "EarIn", ip, V3(e.Size.X * 0.56, e.Size.Y * 0.68, e.Size.Z * 0.5), e.InColor, rot, { Node = n })
		end
		if e.TipColor then
			local tp = e.Pos + rot * V3(0, e.Size.Y * 0.36, 0)
			blobS(ctx, s, "EarTip", tp, V3(e.Size.X * 0.74, e.Size.Y * 0.3, e.Size.Z * 0.92), e.TipColor, rot, { Node = n })
		end
	end)
end

----------------------------------------------------------------------
-- Species profiles (numbers for the shared chibi core) and species extras
----------------------------------------------------------------------
local DEFAULT_PROFILE = {
	Body = V3(1.25, 1.15, 1.1),
	BodyPos = V3(0, 0, 0),
	Head = V3(1.95, 1.75, 1.75),
	HeadPos = V3(0, 0.98, -0.1),
	EyeTheta = 0.58,
	EyePhi = -0.08,
	EyeW = 0.40,
	EyeH = 0.50,
	EyeD = 0.20,
	CheekTheta = 0.98,
	CheekPhi = -0.34,
	CheekW = 0.30,
	CheekH = 0.20,
	BellyPos = V3(0, -0.05, -0.43),
	BellySize = V3(0.8, 0.8, 0.42),
	FeetPos = V3(0.36, -0.55, -0.12),
	FeetSize = V3(0.46, 0.30, 0.56),
	ArmPos = V3(0.67, 0.02, -0.18),
	ArmSize = V3(0.28, 0.46, 0.30),
	ArmRoll = 0.35,
	WingAnchor = V3(0.36, 0.28, 0.46),
	WingScale = 1,
	AccessoryX = 0.5, -- how far from the centre line horns / antlers sit
}

local PROFILES = {
	Cat = {},
	Dog = {},
	Fox = { Head = V3(2.0, 1.7, 1.75), AccessoryX = 0.3 },
	Bunny = { Head = V3(1.9, 1.72, 1.7) },
	Bear = { Head = V3(2.0, 1.75, 1.75), Body = V3(1.32, 1.2, 1.15) },
	Panda = { Head = V3(2.0, 1.75, 1.75), Body = V3(1.32, 1.2, 1.15) },
	Dragon = {
		Body = V3(1.35, 1.25, 1.2),
		Head = V3(2.05, 1.8, 1.8),
		HeadPos = V3(0, 1.0, -0.12),
		EyeTheta = 0.62,
		EyePhi = 0.0,
		EyeW = 0.46,
		EyeH = 0.58,
		EyeD = 0.24,
		BellyPos = V3(0, -0.04, -0.45),
		BellySize = V3(0.92, 0.95, 0.42),
		BellyColor = function(C)
			return mix(CREAM, C.P, 0.2)
		end,
		WingAnchor = V3(0.36, 0.34, 0.5),
		WingScale = 1.1,
		AccessoryX = 0.5,
	},
	Owl = {
		Body = V3(1.35, 1.25, 1.15),
		Head = V3(2.0, 1.6, 1.65),
		HeadPos = V3(0, 0.95, -0.08),
		EyeTheta = 0.56,
		EyePhi = 0.0,
		EyeW = 0.54,
		EyeH = 0.6,
		EyeD = 0.22,
		CheekTheta = 1.1,
		CheekPhi = -0.4,
		BellySize = V3(0.95, 0.95, 0.44),
	},
	Slime = {
		Body = V3(1.75, 0.95, 1.55),
		Head = V3(1.95, 1.6, 1.75),
		HeadPos = V3(0, 0.78, -0.05),
		EyeTheta = 0.6,
		EyePhi = -0.1,
		BellyPos = V3(0, 0, -0.5),
		BellySize = V3(1.0, 0.5, 0.3),
		NoFeet = true,
		NoArms = true,
		NoBelly = true,
		WingAnchor = V3(0.4, 0.3, 0.5),
	},
	Unicorn = { Head = V3(1.95, 1.8, 1.8), AccessoryX = 0.42 },
	Phoenix = {
		Body = V3(1.3, 1.25, 1.2),
		Head = V3(1.85, 1.7, 1.7),
		AccessoryX = 0.4,
	},
	Frog = {
		Body = V3(1.3, 1.05, 1.15),
		Head = V3(2.1, 1.5, 1.7),
		HeadPos = V3(0, 0.85, -0.1),
		EyeTheta = 0.0, -- overridden: eyes sit on bumps
		FeetSize = V3(0.56, 0.3, 0.72),
		FeetPos = V3(0.4, -0.5, -0.1),
	},
	Penguin = {
		Body = V3(1.4, 1.35, 1.2),
		Head = V3(1.85, 1.55, 1.6),
		HeadPos = V3(0, 0.95, -0.1),
		BellyPos = V3(0, -0.06, -0.46),
		BellySize = V3(1.0, 1.05, 0.5),
		FeetPos = V3(0.36, -0.68, -0.18),
		FeetSize = V3(0.5, 0.14, 0.62),
		ArmPos = V3(0.72, 0.0, -0.05),
		ArmSize = V3(0.2, 0.62, 0.4),
		WingScale = 0.9,
	},
	Axolotl = {
		Body = V3(1.15, 1.05, 1.3),
		Head = V3(2.1, 1.55, 1.7),
		HeadPos = V3(0, 0.88, -0.1),
		EyeTheta = 0.78,
		EyePhi = 0.02,
		EyeW = 0.4,
		EyeH = 0.46,
		EyeD = 0.2,
		CheekTheta = 1.1,
		FeetSize = V3(0.4, 0.26, 0.5),
	},
}

local SPECIES = {}

----- Cat -----
SPECIES.Cat = function(ctx, p)
	local C = ctx.C
	earPair(ctx, {
		Pos = V3(0.64, 1.82, -0.06), Size = V3(0.52, 0.72, 0.22), Roll = -0.34, Color = C.P,
		InColor = C.Pink, Hinge = V3(0.58, 1.6, -0.08),
	})
	muzzle(ctx, -0.36, 0, V3(0.66, 0.4, 0.34), lighten(C.P, 0.4))
	nose(ctx, -0.26, 0.07, V3(0.16, 0.11, 0.1), C.Pink)
	smileW(ctx, -0.47, 0.04)
	-- whiskers: two thin sticks per side
	pair(function(s)
		for i = 1, 2 do
			local roll = 0.2 - (i - 1) * 0.3
			local cf = faceCF(ctx, 0.74, -0.3 + (i - 1) * -0.06, 0.1, roll)
			blockCF(ctx, "Whisker" .. sname(s) .. i, sd(s, cf * CF(0.24, 0, 0)), V3(0.5, 0.05, 0.05), lighten(C.P, 0.6))
		end
	end)
	chain(ctx, "Tail",
		{ V3(0, -0.15, 0.5), V3(0, -0.08, 0.96), V3(0, 0.26, 1.32), V3(0, 0.7, 1.46) },
		{ 0.36, 0.34, 0.32 }, { C.P, C.P, mix(C.P, C.S, 0.6) }, { Amp = 0.2 })
end

----- Dog -----
SPECIES.Dog = function(ctx, p)
	local C = ctx.C
	local earC = mix(C.P, rgb(60, 40, 30), 0.22)
	pair(function(s)
		local n = newNode(ctx, { Kind = "ear", Hinge = sd(s, CF(0.78, 1.5, 0)), Axis = "z", Amp = 0.07, Side = s, Phase = s * 1.9 })
		blobS(ctx, s, "Ear", V3(0.93, 1.2, 0.02), V3(0.36, 0.7, 0.26), earC, A(0, 0, 0.32), { Node = n })
	end)
	muzzle(ctx, -0.3, 0.1, V3(0.8, 0.54, 0.58), C.S)
	nose(ctx, -0.2, 0.4, V3(0.3, 0.22, 0.2), NOSE)
	smileW(ctx, -0.5, 0.36)
	blob(ctx, "Tongue", V3(0, 0.53, -1.18), V3(0.17, 0.09, 0.22), rgb(240, 124, 148), A(0.25, 0, 0))
	chain(ctx, "Tail",
		{ V3(0, -0.2, 0.5), V3(0, -0.06, 0.92), V3(0, 0.34, 1.14) },
		{ 0.34, 0.3 }, { C.P, mix(C.P, C.S, 0.6) }, { Amp = 0.3, Rate = 1.5, Lag = 0.5 })
end

----- Fox -----
SPECIES.Fox = function(ctx, p)
	local C = ctx.C
	earPair(ctx, {
		Pos = V3(0.66, 1.88, -0.04), Size = V3(0.58, 0.82, 0.2), Roll = -0.38, Color = C.P,
		InColor = lighten(C.S, 0.2), TipColor = darken(C.P, 0.62), Hinge = V3(0.56, 1.6, -0.05),
	})
	muzzle(ctx, -0.32, 0.12, V3(0.62, 0.42, 0.6), C.S)
	nose(ctx, -0.18, 0.5, V3(0.2, 0.15, 0.15), NOSE)
	smileW(ctx, -0.5, 0.34)
	-- fluffy cheek tufts
	pair(function(s)
		blobS(ctx, s, "CheekTuft", V3(0.8, 0.58, -0.42), V3(0.6, 0.3, 0.3), C.S, A(0, 0.75, -0.1))
	end)
	chain(ctx, "Tail",
		{ V3(0, -0.12, 0.5), V3(0, 0.0, 1.05), V3(0, 0.36, 1.55), V3(0, 0.82, 1.84) },
		{ 0.62, 0.8, 0.66 }, { C.P, C.P, C.S }, { Amp = 0.18, Stretch = 1.3 })
end

----- Bunny -----
SPECIES.Bunny = function(ctx, p)
	local C = ctx.C
	earPair(ctx, {
		Pos = V3(0.36, 2.1, 0.0), Size = V3(0.4, 1.06, 0.2), Roll = -0.12, Color = C.P,
		InColor = C.Pink, InOffset = V3(0, -0.04, -0.1), Hinge = V3(0.36, 1.6, 0), Amp = 0.07,
	})
	muzzle(ctx, -0.38, 0, V3(0.62, 0.36, 0.3), lighten(C.P, 0.45))
	nose(ctx, -0.27, 0.06, V3(0.14, 0.1, 0.1), C.Pink)
	smileW(ctx, -0.5, 0.04)
	blob(ctx, "Teeth", faceCF(ctx, 0, -0.58, 0.0).Position, V3(0.17, 0.15, 0.05), rgb(255, 250, 240))
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.1, 0.55), Axis = "y", Amp = 0.28, Rate = 1.3 })
	blob(ctx, "Tail", V3(0, -0.15, 0.7), V3(0.56, 0.56, 0.56), C.S, nil, { Node = n })
end

----- Bear -----
SPECIES.Bear = function(ctx, p)
	local C = ctx.C
	pair(function(s)
		local n = newNode(ctx, { Kind = "ear", Hinge = sd(s, CF(0.66, 1.62, -0.05)), Axis = "z", Amp = 0.04, Side = s, Phase = s * 1.6 })
		blobS(ctx, s, "Ear", V3(0.7, 1.76, -0.05), V3(0.5, 0.5, 0.4), C.P, nil, { Node = n })
		blobS(ctx, s, "EarIn", V3(0.7, 1.74, -0.2), V3(0.28, 0.28, 0.2), C.S, nil, { Node = n })
	end)
	muzzle(ctx, -0.33, 0.1, V3(0.74, 0.52, 0.46), C.S)
	nose(ctx, -0.2, 0.3, V3(0.28, 0.2, 0.16), NOSE)
	smileW(ctx, -0.5, 0.3)
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.15, 0.5), Axis = "y", Amp = 0.25 })
	blob(ctx, "Tail", V3(0, -0.2, 0.62), V3(0.32, 0.32, 0.32), C.P, nil, { Node = n })
end

----- Panda -----
SPECIES.Panda = function(ctx, p)
	local C = ctx.C
	pair(function(s)
		local n = newNode(ctx, { Kind = "ear", Hinge = sd(s, CF(0.68, 1.62, -0.05)), Axis = "z", Amp = 0.04, Side = s, Phase = s * 1.6 })
		blobS(ctx, s, "Ear", V3(0.72, 1.76, -0.05), V3(0.5, 0.5, 0.4), C.S, nil, { Node = n })
	end)
	-- dark eye patches
	pair(function(s)
		local cf = faceCF(ctx, p.EyeTheta + 0.02, p.EyePhi, -0.03, -0.38)
		blobCF(ctx, "Patch" .. sname(s), sd(s, cf), V3(0.56, 0.66, 0.14), C.S)
	end)
	muzzle(ctx, -0.36, 0.08, V3(0.64, 0.44, 0.38), lighten(C.P, 0.3))
	nose(ctx, -0.24, 0.2, V3(0.25, 0.18, 0.14), C.S)
	smileW(ctx, -0.5, 0.2)
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.15, 0.5), Axis = "y", Amp = 0.25 })
	blob(ctx, "Tail", V3(0, -0.2, 0.62), V3(0.32, 0.32, 0.32), lighten(C.P, 0.2), nil, { Node = n })
end

----- Dragon (the Cloudy Dragon is the mascot: fluffy, round, gold horns, cloud-puff tail) -----
SPECIES.Dragon = function(ctx, p)
	local C = ctx.C
	local fin = C.S
	local cream = mix(CREAM, C.P, 0.2)
	-- stubby snout with two nostril dots and a little smile
	blobCF(ctx, "Snout", faceCF(ctx, 0, -0.3, 0.16), V3(0.72, 0.5, 0.52), cream)
	pair(function(s)
		blobCF(ctx, "Nostril" .. sname(s), sd(s, faceCF(ctx, 0.14, -0.19, 0.38)), V3(0.1, 0.1, 0.07), darken(C.E, 0.2), { Mesh = true })
	end)
	smileWide(ctx, -0.47, 0.22, 0.3)
	-- cream belly bands
	blob(ctx, "BellyBand1", V3(0, 0.2, -0.6), V3(0.8, 0.12, 0.14), mix(cream, C.S, 0.35))
	blob(ctx, "BellyBand2", V3(0, -0.2, -0.62), V3(0.76, 0.12, 0.14), mix(cream, C.S, 0.35))
	-- sky-blue ear fins that flare out from the cheeks
	pair(function(s)
		local n = newNode(ctx, { Kind = "ear", Hinge = sd(s, CF(0.9, 1.1, 0.0)), Axis = "z", Amp = 0.08, Side = s, Phase = s * 1.3 })
		blobS(ctx, s, "Fin", V3(1.12, 1.16, 0.12), V3(0.14, 0.7, 0.52), fin, A(0, 0.55, -0.3), { Node = n })
		blobS(ctx, s, "FinIn", V3(1.12, 1.14, 0.0), V3(0.1, 0.44, 0.32), lighten(fin, 0.4), A(0, 0.55, -0.3), { Node = n })
	end)
	-- fluffy cloud tuft between the horns
	blob(ctx, "Tuft1", V3(0, 1.95, -0.12), V3(0.46, 0.4, 0.46), C.P)
	blob(ctx, "Tuft2", V3(0.24, 1.9, 0.02), V3(0.32, 0.3, 0.32), lighten(C.P, 0.1))
	blob(ctx, "Tuft3", V3(-0.24, 1.9, 0.02), V3(0.32, 0.3, 0.32), lighten(C.P, 0.1))
	-- sky-blue puffs down the back
	blob(ctx, "Puff1", V3(0, 0.46, 0.58), V3(0.42, 0.42, 0.4), C.S)
	blob(ctx, "Puff2", V3(0, 0.1, 0.66), V3(0.36, 0.36, 0.34), C.S)
	blob(ctx, "Puff3", V3(0, -0.22, 0.7), V3(0.3, 0.3, 0.3), C.S)
	-- tail ending in a cloud puff
	local ids = chain(ctx, "Tail",
		{ V3(0, -0.25, 0.5), V3(0, -0.3, 1.05), V3(0, 0.0, 1.6), V3(0, 0.4, 1.98) },
		{ 0.5, 0.44, 0.38 }, { C.P, mix(C.P, C.S, 0.35), mix(C.P, C.S, 0.7) },
		{ Amp = 0.2, Lag = 0.8 })
	local tipNode = ids[#ids]
	blob(ctx, "TailPuff1", V3(0, 0.5, 2.06), V3(0.58, 0.54, 0.54), C.P, nil, { Node = tipNode })
	blob(ctx, "TailPuff2", V3(0.3, 0.42, 2.02), V3(0.36, 0.34, 0.34), C.S, nil, { Node = tipNode })
	blob(ctx, "TailPuff3", V3(-0.3, 0.42, 2.02), V3(0.36, 0.34, 0.34), C.S, nil, { Node = tipNode })
end

----- Owl -----
SPECIES.Owl = function(ctx, p)
	local C = ctx.C
	-- facial discs behind the huge eyes
	pair(function(s)
		blobCF(ctx, "Disc" .. sname(s), sd(s, faceCF(ctx, p.EyeTheta, p.EyePhi, -0.03)), V3(0.92, 0.9, 0.14), C.S)
	end)
	-- ear tufts
	earPair(ctx, {
		Pos = V3(0.7, 1.7, -0.02), Size = V3(0.3, 0.6, 0.22), Roll = -0.5, Color = darken(C.P, 0.12),
		Hinge = V3(0.62, 1.5, 0), Amp = 0.04,
	})
	blobCF(ctx, "Beak", faceCF(ctx, 0, -0.22, 0.1), V3(0.22, 0.28, 0.22), BEAK, { Mesh = true })
	-- feathery chest scallops
	for i = 1, 3 do
		blob(ctx, "Ruffle" .. i, V3(0, 0.2 - (i - 1) * 0.2, -0.63 - (i - 1) * 0.005), V3(0.62 - (i - 1) * 0.06, 0.07, 0.1), darken(C.S, 0.1))
	end
	-- short fan tail
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.2, 0.5), Axis = "y", Amp = 0.18 })
	blob(ctx, "Tail", V3(0, -0.28, 0.82), V3(0.5, 0.18, 0.62), darken(C.P, 0.1), A(0.2, 0, 0), { Node = n })
	blob(ctx, "TailL", V3(-0.2, -0.26, 0.78), V3(0.3, 0.14, 0.52), C.P, A(0.2, 0.3, 0), { Node = n })
	blob(ctx, "TailR", V3(0.2, -0.26, 0.78), V3(0.3, 0.14, 0.52), C.P, A(0.2, -0.3, 0), { Node = n })
end

----- Slime -----
SPECIES.Slime = function(ctx, p)
	local C = ctx.C
	-- glossy highlights
	blob(ctx, "Gloss1", V3(0.46, 1.34, -0.55), V3(0.4, 0.18, 0.12), lighten(C.P, 0.65), A(0.5, -0.3, 0.6), { Transparency = 0.15 })
	blob(ctx, "Gloss2", V3(0.74, 1.12, -0.36), V3(0.14, 0.14, 0.1), lighten(C.P, 0.7), nil, { Transparency = 0.15 })
	-- wobbly base drips
	blob(ctx, "Drip1", V3(-0.6, -0.4, -0.35), V3(0.4, 0.3, 0.4), C.P)
	blob(ctx, "Drip2", V3(0.62, -0.38, -0.3), V3(0.36, 0.28, 0.36), C.P)
	blob(ctx, "Drip3", V3(0.1, -0.42, 0.55), V3(0.4, 0.26, 0.4), C.P)
	-- peak on top that bobbles
	local n = newNode(ctx, { Kind = "sway", Hinge = CF(0, 1.5, -0.05), Axis = "z", Amp = 0.18, Axis2 = "x", Amp2 = 0.1, Lag2 = 1.2, Rate = 1.3 })
	blob(ctx, "Peak", V3(0.03, 1.74, -0.05), V3(0.34, 0.5, 0.34), lighten(C.P, 0.08), A(0, 0, -0.25), { Node = n })
	smileWide(ctx, -0.38, 0.22, 0.02)
	-- tiny blob tail
	local t = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.1, 0.6), Axis = "y", Amp = 0.3 })
	blob(ctx, "Tail", V3(0, -0.12, 0.84), V3(0.34, 0.3, 0.4), C.P, nil, { Node = t })
end

----- Unicorn -----
SPECIES.Unicorn = function(ctx, p)
	local C = ctx.C
	earPair(ctx, {
		Pos = V3(0.58, 1.84, -0.02), Size = V3(0.32, 0.56, 0.18), Roll = -0.22, Color = C.P,
		InColor = lighten(C.S, 0.25), Hinge = V3(0.54, 1.62, -0.03),
	})
	muzzle(ctx, -0.34, 0.16, V3(0.82, 0.56, 0.58), lighten(C.P, 0.3))
	pair(function(s)
		blobCF(ctx, "Nostril" .. sname(s), sd(s, faceCF(ctx, 0.16, -0.26, 0.45)), V3(0.08, 0.08, 0.06), C.Mouth, { Mesh = true })
	end)
	smileWide(ctx, -0.5, 0.26, 0.3)
	-- spiral horn: four stacked, shrinking pearls along the forehead axis
	local hc = ctx.HC
	local base = V3(0, hc.Y + ctx.HA.Y * 0.8, hc.Z - ctx.HA.Z * 0.55)
	local dir = V3(0, 0.93, -0.36).Unit
	local hornCols = { GOLD_LIGHT, rgb(250, 238, 200), GOLD_LIGHT, rgb(250, 238, 200) }
	local hornW = { 0.3, 0.24, 0.17, 0.1 }
	local hn = newNode(ctx, { Kind = "sway", Hinge = CF(base), Axis = "x", Amp = 0.04, Rate = 0.8 })
	for i = 1, 4 do
		local pos = base + dir * (0.1 + (i - 1) * 0.23)
		blob(ctx, "Horn" .. i, pos, V3(hornW[i], hornW[i], 0.38), hornCols[i], aim(dir), { Node = hn })
	end
	-- flowing mane (secondary colour) behind the horn and down the neck
	local maneC = { C.S, mix(C.S, C.P, 0.4), C.S }
	local m1 = newNode(ctx, { Kind = "sway", Hinge = CF(0, 1.7, 0.3), Axis = "x", Amp = 0.08, Rate = 1.1 })
	blob(ctx, "Forelock", V3(0.16, 1.82, -0.62), V3(0.32, 0.4, 0.28), maneC[1], A(0, 0, -0.3), { Node = m1 })
	blob(ctx, "Mane1", V3(0, 1.72, 0.5), V3(0.6, 0.55, 0.5), maneC[2], nil, { Node = m1 })
	blob(ctx, "Mane2", V3(0, 1.2, 0.78), V3(0.52, 0.62, 0.42), maneC[1], nil, { Node = m1 })
	blob(ctx, "Mane3", V3(0, 0.62, 0.7), V3(0.46, 0.6, 0.4), maneC[3], nil, { Node = m1 })
	-- swishy tail
	chain(ctx, "Tail",
		{ V3(0, -0.15, 0.5), V3(0, -0.2, 1.0), V3(0, 0.1, 1.45), V3(0, 0.55, 1.72) },
		{ 0.42, 0.44, 0.4 }, { C.S, mix(C.S, C.P, 0.3), mix(C.S, WHITE, 0.4) }, { Amp = 0.22, Lag = 0.8, Stretch = 1.3 })
end

----- Phoenix -----
SPECIES.Phoenix = function(ctx, p)
	local C = ctx.C
	blobCF(ctx, "Beak", faceCF(ctx, 0, -0.22, 0.1), V3(0.26, 0.2, 0.42), C.S, { Mesh = true })
	blobCF(ctx, "BeakLow", faceCF(ctx, 0, -0.4, 0.04), V3(0.2, 0.1, 0.3), darken(C.S, 0.12), { Mesh = true })
	-- flame crest: three flickering plumes
	local hc = ctx.HC
	local cn = newNode(ctx, { Kind = "sway", Hinge = CF(0, hc.Y + 0.7, hc.Z + 0.1), Axis = "z", Amp = 0.12, Axis2 = "x", Amp2 = 0.1, Lag2 = 1.5, Rate = 2.4 })
	blob(ctx, "Crest1", V3(0, 2.15, -0.02), V3(0.22, 0.78, 0.16), C.S, nil, { Node = cn })
	blob(ctx, "Crest2", V3(0.22, 2.05, 0.02), V3(0.18, 0.62, 0.14), mix(C.S, C.P, 0.5), A(0, 0, -0.4), { Node = cn })
	blob(ctx, "Crest3", V3(-0.22, 2.05, 0.02), V3(0.18, 0.62, 0.14), mix(C.S, C.P, 0.5), A(0, 0, 0.4), { Node = cn })
	-- breast feathers
	blob(ctx, "Breast", V3(0, 0.12, -0.6), V3(0.7, 0.4, 0.14), lighten(C.S, 0.15))
	-- three long tail plumes, fanned
	local cols = { C.S, C.P, C.S }
	local yaws = { -0.38, 0, 0.38 }
	for i = 1, 3 do
		local dir = V3(math.sin(yaws[i]), -0.22, math.cos(yaws[i])).Unit
		local root = V3(0, -0.18, 0.5)
		local tip = root + dir * 1.5
		chain(ctx, "Plume" .. i, { root, (root + tip) * 0.5, tip }, { 0.4, 0.34 }, { cols[i], mix(cols[i], C.S, 0.5) },
			{ Amp = 0.16, Lag = 0.9, Rate = 1.4, Flat = 0.7, Phase = i * 1.1 })
	end
end

----- Frog -----
SPECIES.Frog = function(ctx, p)
	local C = ctx.C
	-- eye bumps on top of the head; the eyes themselves are built in the core using ctx.EyeFrame
	pair(function(s)
		blobS(ctx, s, "EyeBump", ctx.BumpPos, V3(0.7, 0.66, 0.66), C.P)
	end)
	smileWide(ctx, -0.38, 0.62, 0.0)
	pair(function(s)
		blobCF(ctx, "Nostril" .. sname(s), sd(s, faceCF(ctx, 0.1, -0.12, 0.0)), V3(0.07, 0.07, 0.05), C.Mouth, { Mesh = true })
	end)
	-- pale throat
	blobCF(ctx, "Throat", faceCF(ctx, 0, -0.62, -0.02), V3(0.9, 0.34, 0.4), lighten(C.S, 0.1))
	-- frogs have no real tail: a tiny round bob
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.2, 0.5), Axis = "y", Amp = 0.2 })
	blob(ctx, "Tail", V3(0, -0.22, 0.6), V3(0.26, 0.26, 0.26), C.P, nil, { Node = n })
end

----- Penguin -----
SPECIES.Penguin = function(ctx, p)
	local C = ctx.C
	-- white face mask the eyes sit on
	pair(function(s)
		blobCF(ctx, "Mask" .. sname(s), sd(s, faceCF(ctx, 0.42, -0.06, -0.04, -0.12)), V3(0.86, 0.9, 0.14), C.S)
	end)
	blobCF(ctx, "MaskMid", faceCF(ctx, 0, -0.2, -0.04), V3(0.6, 0.6, 0.14), C.S)
	blobCF(ctx, "Beak", faceCF(ctx, 0, -0.26, 0.08), V3(0.36, 0.2, 0.34), BEAK, { Mesh = true })
	smileW(ctx, -0.5, 0.0)
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.35, 0.55), Axis = "y", Amp = 0.28 })
	blob(ctx, "Tail", V3(0, -0.42, 0.7), V3(0.36, 0.2, 0.44), C.P, A(0.3, 0, 0), { Node = n })
end

----- Axolotl -----
SPECIES.Axolotl = function(ctx, p)
	local C = ctx.C
	-- three feathery gills per side
	local gillRoll = { -0.95, -1.4, -1.85 }
	local gillY = { 1.38, 1.1, 0.82 }
	pair(function(s)
		for i = 1, 3 do
			local hinge = V3(0.96, gillY[i], 0.0)
			local n = newNode(ctx, { Kind = "sway", Hinge = sd(s, CF(hinge)), Axis = "z", Amp = 0.18, Lag = i * 0.6, Rate = 1.8, Side = s, Phase = s })
			local rot = A(0, 0, gillRoll[i])
			local center = hinge + rot * V3(0, 0.38, 0)
			blobS(ctx, s, "Gill" .. i, center, V3(0.18, 0.78, 0.14), C.S, rot, { Node = n })
		end
	end)
	smileWide(ctx, -0.36, 0.5, 0.0)
	-- flat tail fin
	chain(ctx, "Tail",
		{ V3(0, -0.1, 0.55), V3(0, -0.05, 1.1), V3(0, 0.0, 1.6) },
		{ 0.5, 0.42 }, { mix(C.P, C.S, 0.3), C.S }, { Amp = 0.3, Lag = 0.8, Flat = 1.0 })
end

----------------------------------------------------------------------
-- The shared chibi core: body, belly, head, eyes, cheeks, feet, arms
----------------------------------------------------------------------
local function resolveColor(v, C, default)
	if type(v) == "function" then
		return v(C)
	end
	return v or default
end

local function buildCore(ctx, p)
	local C = ctx.C
	local limb = resolveColor(p.LimbColor, C, C.P)

	ctx.Primary = blobCF(ctx, "Body", CF(p.BodyPos), p.Body, resolveColor(p.BodyColor, C, C.P), { Shadow = true })
	if not p.NoBelly then
		blobCF(ctx, "Belly", CF(p.BellyPos), p.BellySize, resolveColor(p.BellyColor, C, C.Belly))
	end

	ctx.HC = p.HeadPos
	ctx.HA = V3(p.Head.X / 2, p.Head.Y / 2, p.Head.Z / 2)
	ctx.Head = blobCF(ctx, "Head", CF(p.HeadPos), p.Head, resolveColor(p.HeadColor, C, C.P), { Shadow = true })

	if not p.NoFeet then
		pair(function(s)
			blobS(ctx, s, "Foot", p.FeetPos, p.FeetSize, resolveColor(p.FootColor, C, limb), A(0, -0.14, 0))
		end)
	end
	if not p.NoArms then
		pair(function(s)
			blobS(ctx, s, "Arm", p.ArmPos, p.ArmSize, resolveColor(p.ArmColor, C, limb), A(0, 0, p.ArmRoll))
		end)
	end

	-- eyes (the frog overrides the frame: its eyes sit on bumps)
	local ecf
	if ctx.EyeFrame then
		ecf = ctx.EyeFrame
	else
		ecf = faceCF(ctx, p.EyeTheta, p.EyePhi, 0)
	end
	pair(function(s)
		buildEye(ctx, s, ecf, p.EyeW, p.EyeH, p.EyeD)
	end)

	-- blush cheeks
	if not p.NoCheeks then
		pair(function(s)
			local cf = faceCF(ctx, p.CheekTheta, p.CheekPhi, 0, 0.12)
			blobCF(ctx, "Cheek" .. sname(s), sd(s, cf), V3(p.CheekW, p.CheekH, 0.09), C.Blush, { Transparency = 0.1 })
		end)
	end
end

----------------------------------------------------------------------
-- Wing styles. Every builder creates ONE wing (s = +1 right, -1 left) in a local wing frame:
-- +X runs along the wing away from the shoulder, +Y is "up" within the wing plane, Z is the plane normal.
-- The wing root node flaps about the body's Z axis through the shoulder; sub nodes fan / bend the parts.
----------------------------------------------------------------------
local WINGS = {}

-- Small toolbox shared by the wing builders.
local function wingKit(ctx, p, s, frame, root)
	local ws = p.WingScale or 1
	local sn = sname(s)
	local kit = { Count = 0 }
	-- part in wing space (positions / sizes are multiplied by the wing scale)
	function kit.part(lcf, size, color, o)
		kit.Count = kit.Count + 1
		local name = "Wing" .. sn
		if kit.Count > 1 then
			name = "Wing" .. sn .. "_" .. kit.Count
		end
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = lcf:GetComponents()
		local scaled = CFrame.new(x * ws, y * ws, z * ws, r00, r01, r02, r10, r11, r12, r20, r21, r22)
		return blobCF(ctx, name, sd(s, frame * scaled), V3(size.X * ws, size.Y * ws, size.Z * ws), color, o)
	end
	-- joint node inside the wing (rotates about the wing normal at wing-space point (hx, hy))
	function kit.joint(parent, hx, hy, amp, lag)
		return newNode(ctx, {
			Kind = "wing",
			Parent = parent or root,
			Hinge = sd(s, frame * CF(hx * ws, hy * ws, 0)),
			Axis = "z",
			Amp = amp,
			Lag = lag,
			Side = s,
		})
	end
	kit.ws = ws
	return kit
end

local function edgeMat(ctx)
	if ctx.Glow then
		return NEON
	end
	return SMOOTH
end

-- Layered feather panels: five long flight feathers fanned out + two shorter coverts over them.
WINGS.Feather = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	k.part(CF(0.1, 0, 0), V3(0.38, 0.34, 0.2), darken(W, 0.08), { Node = root })
	local angles = { 0.98, 0.66, 0.36, 0.08, -0.2 }
	local lens = { 0.9, 1.2, 1.42, 1.4, 1.1 }
	for i = 1, 5 do
		local a = angles[i]
		local len = lens[i]
		local c = 0.16 + len / 2
		local n = k.joint(root, 0, 0, 0.09, i * 0.4)
		local col = W
		if i % 2 == 0 then
			col = mix(W, darken(W, 0.2), 0.6)
		end
		local o = { Node = n }
		if i == 1 then
			o.Material = edgeMat(ctx)
		end
		k.part(CF(math.cos(a) * c, math.sin(a) * c, 0.03 * i) * A(0, 0, a), V3(len, 0.36, 0.07), col, o)
	end
	local cov = { 0.74, 0.22 }
	local covLen = { 0.62, 0.7 }
	for i = 1, 2 do
		local a = cov[i]
		local c = 0.14 + covLen[i] / 2
		k.part(CF(math.cos(a) * c, math.sin(a) * c, -0.06) * A(0, 0, a), V3(covLen[i], 0.32, 0.07), lighten(W, 0.2), { Node = root })
	end
end

-- Bat wing: bony arm, three finger spars and overlapping membrane panels in between.
WINGS.Bat = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	local bone = darken(W, 0.34)
	local skin = lighten(W, 0.06)
	-- arm (root, named Wing)
	k.part(CF(0.52, 0.05, 0) * A(0, 0, 0.12), V3(1.0, 0.16, 0.16), bone, { Node = root })
	-- trailing membrane towards the body
	k.part(CF(0.46, -0.34, -0.01) * A(0, 0, -0.1), V3(1.0, 0.7, 0.05), skin, { Node = root })
	-- wrist joint: fingers + their membranes bend a little
	local wx, wy = 1.0, 0.12
	local wrist = k.joint(root, wx, wy, 0.14, 0.9)
	local ang = { 0.95, 0.42, -0.1 }
	local len = { 0.85, 1.1, 0.95 }
	for i = 1, 3 do
		local a = ang[i]
		local c = len[i] / 2
		local o = { Node = wrist }
		if i == 1 then
			o.Material = edgeMat(ctx)
		end
		k.part(CF(wx + math.cos(a) * c, wy + math.sin(a) * c, 0) * A(0, 0, a), V3(len[i], 0.1, 0.1), bone, o)
	end
	local memAng = { 0.7, 0.16, -0.36 }
	local memLen = { 0.8, 1.0, 0.95 }
	for i = 1, 3 do
		local a = memAng[i]
		local c = memLen[i] * 0.5
		k.part(CF(wx + math.cos(a) * c, wy + math.sin(a) * c, 0.01 * i) * A(0, 0, a), V3(memLen[i], 0.78, 0.05), skin, { Node = wrist })
	end
end

-- Fairy wings: two translucent pairs (big upper, small lower) with a brighter sheen inside.
WINGS.Fairy = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	k.part(CF(0.08, 0, 0), V3(0.28, 0.28, 0.16), mix(W, ctx.C.P, 0.3), { Node = root })
	local up = k.joint(root, 0, 0, 0.1, 0.5)
	local low = k.joint(root, 0, 0, 0.1, 1.5)
	k.part(CF(0.86, 0.5, 0) * A(0, 0, 0.55), V3(1.5, 0.95, 0.05), W, { Node = up, Transparency = 0.42 })
	local o = { Node = up, Transparency = 0.36 }
	o.Material = edgeMat(ctx)
	k.part(CF(0.76, 0.43, -0.02) * A(0, 0, 0.55), V3(0.95, 0.5, 0.04), lighten(W, 0.5), o)
	k.part(CF(0.62, -0.38, 0) * A(0, 0, -0.5), V3(1.02, 0.66, 0.05), W, { Node = low, Transparency = 0.42 })
	k.part(CF(0.56, -0.34, -0.02) * A(0, 0, -0.5), V3(0.62, 0.34, 0.04), lighten(W, 0.5), { Node = low, Transparency = 0.36, Material = edgeMat(ctx) })
end

-- Cloud wings: three puffy spheres (+ shaded puffs underneath) that bend in a soft wave.
WINGS.Cloud = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	local shade = mix(W, ctx.C.S, 0.5)
	k.part(CF(0.45, 0.08, 0), V3(0.9, 0.9, 0.9), W, { Node = root })
	k.part(CF(0.56, -0.34, 0.06), V3(0.6, 0.6, 0.6), shade, { Node = root })
	local j2 = k.joint(root, 0.45, 0.08, 0.14, 0.8)
	k.part(CF(1.12, 0.32, 0.02), V3(0.74, 0.74, 0.74), lighten(W, 0.05), { Node = j2 })
	k.part(CF(1.0, -0.14, 0.06), V3(0.5, 0.5, 0.5), shade, { Node = j2 })
	local j3 = k.joint(j2, 1.12, 0.32, 0.17, 1.6)
	k.part(CF(1.66, 0.62, 0.03), V3(0.54, 0.54, 0.54), lighten(W, 0.12), { Node = j3, Material = edgeMat(ctx) })
end

-- Crystal wings: angled translucent shards, each a chunky prism rod with a glowing diamond tip.
WINGS.Crystal = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	k.part(CF(0.1, 0, 0) * A(0, 0, PI / 4), V3(0.36, 0.36, 0.26), lighten(W, 0.15), { Node = root, Transparency = 0.1 })
	local ang = { 0.95, 0.5, 0.05, -0.38 }
	local len = { 0.8, 1.15, 1.3, 0.9 }
	for i = 1, 4 do
		local a = ang[i]
		local l = len[i]
		local c = 0.18 + l / 2
		local n = k.joint(root, 0, 0, 0.07, i * 0.5)
		local rot = A(0, 0, a) * A(PI / 4, 0, 0)
		k.part(CF(math.cos(a) * c, math.sin(a) * c, 0.02 * i) * rot, V3(l, 0.34, 0.26), W, { Node = n, Transparency = 0.25 })
		local tip = 0.18 + l + 0.1
		k.part(CF(math.cos(a) * tip, math.sin(a) * tip, 0.02 * i) * A(0, 0, a + PI / 4), V3(0.46, 0.46, 0.2),
			lighten(W, 0.4), { Node = n, Material = NEON, Transparency = 0.3 })
	end
end

-- Flame wings: orange tongues of translucent Neon with brighter cores that flicker.
WINGS.Flame = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	k.part(CF(0.1, 0, 0), V3(0.38, 0.34, 0.2), W, { Node = root, Material = NEON, Transparency = 0.1 })
	local ang = { 1.0, 0.6, 0.2, -0.2 }
	local len = { 0.9, 1.3, 1.45, 1.1 }
	for i = 1, 4 do
		local a = ang[i]
		local l = len[i]
		local c = 0.16 + l / 2
		local n = k.joint(root, 0, 0, 0.12, i * 0.55)
		k.part(CF(math.cos(a) * c, math.sin(a) * c, 0.02 * i) * A(0, 0, a), V3(l, 0.44, 0.07), W, { Node = n, Material = NEON, Transparency = 0.3 })
		if i <= 3 then
			local cl = l * 0.62
			local cc = 0.16 + cl / 2
			k.part(CF(math.cos(a) * cc, math.sin(a) * cc, 0.02 * i - 0.04) * A(0, 0, a), V3(cl, 0.2, 0.06), lighten(W, 0.55), { Node = n, Material = NEON, Transparency = 0.12 })
		end
	end
end

local function buildWings(ctx, p, style)
	local fn = WINGS[style] or WINGS.Feather
	local sh = p.WingAnchor
	local frame = CF(sh) * A(0, -0.5, 0.42)
	pair(function(s)
		local root = newNode(ctx, {
			Kind = "wing",
			Hinge = sd(s, CF(sh)),
			Axis = "z",
			Amp = 0.44,
			Bias = -0.05,
			Axis2 = "x",
			Amp2 = 0.1,
			Lag2 = 1.3,
			Side = s,
		})
		fn(ctx, p, s, frame, root)
	end)
end

----------------------------------------------------------------------
-- Accessories
----------------------------------------------------------------------
local ACCESSORIES = {}

local function headTop(ctx)
	return ctx.HC + V3(0, ctx.HA.Y, 0)
end

ACCESSORIES.Horns = function(ctx, p)
	local hc, ha = ctx.HC, ctx.HA
	pair(function(s)
		local pos = V3(p.AccessoryX, hc.Y + ha.Y * 0.88, hc.Z - ha.Z * 0.1)
		local rot = A(0.38, 0, -0.34)
		blobS(ctx, s, "Horn", pos, V3(0.26, 0.44, 0.26), GOLD, rot)
		blobS(ctx, s, "HornTip", pos + rot * V3(0, 0.3, 0), V3(0.15, 0.32, 0.15), GOLD_LIGHT, rot)
	end)
end

ACCESSORIES.Crown = function(ctx, p)
	local top = headTop(ctx)
	local base = top + V3(0, -0.04, -0.06)
	local band = cylCF(ctx, "CrownBand", CF(base), 1.0, 0.24, GOLD, { Material = SMOOTH })
	for i = 0, 4 do
		local a = i * TAU / 5
		blob(ctx, "CrownPoint" .. (i + 1), base + V3(math.sin(a) * 0.43, 0.22, math.cos(a) * 0.43), V3(0.2, 0.36, 0.2), GOLD_LIGHT)
	end
	blob(ctx, "CrownJewel", base + V3(0, 0.0, -0.5), V3(0.16, 0.16, 0.12), rgb(232, 84, 112), nil, { Material = NEON })
	return band
end

ACCESSORIES.Halo = function(ctx, p)
	local top = headTop(ctx) + V3(0, 0.5, 0.05)
	local n = newNode(ctx, { Kind = "bob", Hinge = CF(top), Axis = "z", Amp = 0.07, Amp2 = 0.05, Axis2 = "x", Rate = 1.2 })
	local r = 0.58
	for i = 0, 7 do
		local a = i * TAU / 8
		local pos = top + A(-0.3, 0, 0.06) * V3(math.sin(a) * r, 0, math.cos(a) * r)
		-- each segment is tangent to the ring
		local tang = A(-0.3, 0, 0.06) * V3(math.cos(a), 0, -math.sin(a))
		blobCF(ctx, "Halo" .. (i + 1), CF(pos) * aim(tang, V3(0, 1, 0)), V3(0.11, 0.1, 0.5), rgb(255, 238, 168), { Node = n, Material = NEON })
	end
end

ACCESSORIES.Leaf = function(ctx, p)
	local top = headTop(ctx) + V3(0, -0.06, -0.04)
	local n = newNode(ctx, { Kind = "sway", Hinge = CF(top), Axis = "z", Amp = 0.1, Axis2 = "x", Amp2 = 0.07, Lag2 = 1.0, Rate = 1.2 })
	blob(ctx, "LeafStem", top + V3(0, 0.14, 0), V3(0.07, 0.34, 0.07), darken(LEAF, 0.25), nil, { Node = n })
	blob(ctx, "LeafA", top + V3(0.24, 0.32, 0), V3(0.56, 0.12, 0.3), LEAF, A(0, 0, 0.5), { Node = n })
	blob(ctx, "LeafB", top + V3(-0.2, 0.3, -0.02), V3(0.46, 0.1, 0.26), LEAF_LIGHT, A(0, 0, -0.55), { Node = n })
end

ACCESSORIES.Mushroom = function(ctx, p)
	local top = headTop(ctx) + V3(0.0, -0.06, 0.02)
	blob(ctx, "ShroomStem", top + V3(0, 0.1, 0), V3(0.3, 0.3, 0.3), CREAM)
	blob(ctx, "ShroomCap", top + V3(0, 0.3, 0), V3(0.86, 0.46, 0.86), CAP)
	local dots = { V3(0.22, 0.5, -0.16), V3(-0.2, 0.49, -0.2), V3(0.0, 0.54, 0.18) }
	for i = 1, 3 do
		blob(ctx, "ShroomDot" .. i, top + dots[i], V3(0.16, 0.08, 0.16), rgb(250, 240, 224))
	end
end

ACCESSORIES.Scarf = function(ctx, p)
	local hc, ha = ctx.HC, ctx.HA
	local neck = V3(hc.X, hc.Y - ha.Y * 0.74, hc.Z + 0.06)
	blob(ctx, "ScarfRing", neck, V3(1.5, 0.3, 1.28), SCARF)
	blob(ctx, "ScarfStripe", neck + V3(0, -0.02, 0), V3(1.52, 0.07, 1.3), SCARF_STRIPE)
	local n = newNode(ctx, { Kind = "sway", Hinge = CF(0.36, neck.Y - 0.05, -0.5), Axis = "x", Amp = 0.12, Axis2 = "z", Amp2 = 0.08, Lag2 = 1.0, Rate = 1.2 })
	blob(ctx, "ScarfEnd", V3(0.4, neck.Y - 0.3, -0.52), V3(0.3, 0.62, 0.12), SCARF, A(0.12, 0, 0.12), { Node = n })
	blob(ctx, "ScarfEndStripe", V3(0.4, neck.Y - 0.44, -0.53), V3(0.31, 0.07, 0.13), SCARF_STRIPE, A(0.12, 0, 0.12), { Node = n })
end

ACCESSORIES.Antlers = function(ctx, p)
	local hc, ha = ctx.HC, ctx.HA
	local col = rgb(232, 206, 154)
	local tipMat = SMOOTH
	if ctx.Glow then
		tipMat = NEON
	end
	pair(function(s)
		local base = V3(p.AccessoryX, hc.Y + ha.Y * 0.84, hc.Z + 0.02)
		local n = newNode(ctx, { Kind = "ear", Hinge = sd(s, CF(base)), Axis = "z", Amp = 0.03, Side = s, Phase = s })
		local rot = A(0.1, 0, -0.3)
		local r1 = rot * A(0, 0, -0.85) -- lower prong flares outwards
		local r2 = rot * A(0.6, 0, 0.5) -- upper prong points forward and in
		blobS(ctx, s, "Antler", base + rot * V3(0, 0.42, 0), V3(0.16, 0.9, 0.16), col, rot, { Node = n })
		blobS(ctx, s, "AntlerProng1", base + rot * V3(0, 0.34, 0) + r1 * V3(0, 0.2, 0), V3(0.12, 0.44, 0.12), col, r1, { Node = n })
		blobS(ctx, s, "AntlerProng2", base + rot * V3(0, 0.62, 0) + r2 * V3(0, 0.17, 0), V3(0.11, 0.36, 0.11), col, r2, { Node = n })
		blobS(ctx, s, "AntlerTip", base + rot * V3(0, 0.9, 0), V3(0.17, 0.22, 0.17), lighten(col, 0.35), rot, { Node = n, Material = tipMat })
	end)
end

ACCESSORIES.Flower = function(ctx, p)
	local cf = faceCF(ctx, 1.0, 0.72, 0.1)
	local cols = { ctx.C.W, rgb(250, 208, 224), CREAM, rgb(196, 182, 250) }
	local petal = cols[1]
	-- choose the petal colour that stands out most against the head
	local best, bestD = petal, -1
	for i = 1, #cols do
		local c = cols[i]
		local dr, dg, db = c.R - ctx.C.P.R, c.G - ctx.C.P.G, c.B - ctx.C.P.B
		local d = dr * dr + dg * dg + db * db
		if d > bestD then
			best, bestD = c, d
		end
	end
	petal = best
	for i = 0, 4 do
		local a = i * TAU / 5 + 0.3
		blobCF(ctx, "Petal" .. (i + 1), cf * CF(math.cos(a) * 0.17, math.sin(a) * 0.17, 0), V3(0.22, 0.22, 0.12), petal)
	end
	blobCF(ctx, "FlowerCore", cf * CF(0, 0, -0.04), V3(0.16, 0.16, 0.12), rgb(250, 218, 110))
end

----------------------------------------------------------------------
-- Rarity flair
----------------------------------------------------------------------
-- Legendary and Mythic pets get a soft sparkle emitter (low rate) and a few little gems that orbit them.
-- The gems are real parts so the flair also shows in ViewportFrames, which do not draw particles.
local FLAIR = {
	Legendary = { Rate = 3, Gems = 2, A = rgb(255, 226, 140), B = rgb(255, 190, 90) },
	Mythic = { Rate = 5, Gems = 3, A = rgb(255, 214, 236), B = rgb(190, 226, 255) },
}

local function addFlair(ctx, rarity)
	local f = FLAIR[rarity]
	if not f or not ctx.Head then
		return
	end
	local hinge = CF(0, 0.5, 0.1)
	for i = 1, f.Gems do
		local phase = (i - 1) * TAU / f.Gems
		local n = newNode(ctx, {
			Kind = "orbit",
			Hinge = hinge,
			Axis = "y",
			Phase = phase,
			Rate = 0.8 + i * 0.13,
			Amp = 0.12,
		})
		local col = f.A
		if i % 2 == 0 then
			col = f.B
		end
		-- Each gem gets its own height and its orbit phase baked into the rest pose (nodeMotion only adds
		-- the running angle), so a pet that is never Animated (the lobby mascot statue) still shows the gems
		-- spread evenly round the body instead of stacked on one side.
		local y = 0.35 + (i - 1) * 0.5
		local rest = hinge * A(0, phase, 0) * hinge:Inverse() * CF(1.8, y, 0.1)
		blockCF(ctx, "Gem" .. i, rest * A(0.6, 0, PI / 4), V3(0.2, 0.2, 0.2), col, { Node = n, Material = NEON, Transparency = 0.1 })
	end
	local k = ctx.Scale
	local e = Instance.new("ParticleEmitter")
	e.Name = "RarityGlow"
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Rate = f.Rate
	e.Lifetime = NumberRange.new(1.3, 2.3)
	e.Speed = NumberRange.new(0.2 * k, 0.8 * k)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-60, 60)
	e.LightEmission = 0.8
	e.LightInfluence = 0
	e.Acceleration = Vector3.new(0, 0.5 * k, 0)
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.4, 0.4 * k),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.25),
		NumberSequenceKeypoint.new(0.75, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Color = ColorSequence.new(f.A, f.B)
	e.Parent = ctx.Head
end

----------------------------------------------------------------------
-- Look + profile reading
----------------------------------------------------------------------
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
	return {
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

local function makeProfile(species)
	local p = {}
	for k, v in pairs(DEFAULT_PROFILE) do
		p[k] = v
	end
	local over = PROFILES[species]
	if over then
		for k, v in pairs(over) do
			p[k] = v
		end
	end
	-- species colour decisions that need the palette are made in the species builders
	return p
end

----------------------------------------------------------------------
-- Animation
----------------------------------------------------------------------
local function axisRot(axis, a)
	if axis == "x" then
		return A(a, 0, 0)
	elseif axis == "y" then
		return A(0, a, 0)
	end
	return A(0, 0, a)
end

local function sideSign(axis, side)
	if axis == "x" then
		return 1
	end
	return side
end

-- Short, quick ear twitch on a slow cycle (each ear has its own phase).
local function earFlick(n, st)
	local u = (st.T * (0.27 + 0.5 * st.Excite) + n.Phase * 0.37) % 1
	if u < 0.08 then
		return math.sin(u / 0.08 * PI) * 0.34
	end
	return 0
end

-- The motion of one node in PrimaryPart space: hinge * rotation * hinge^-1 (and a lift for "bob").
local function nodeMotion(n, st)
	local kind = n.Kind
	local a1 = n.Bias
	local a2 = 0
	local lift = 0
	if kind == "wing" then
		a1 = a1 + n.Amp * st.WingAmp * math.sin(st.Flap - n.Lag)
		if n.Amp2 ~= 0 then
			a2 = n.Amp2 * math.sin(st.Flap - n.Lag2)
		end
	elseif kind == "tail" then
		a1 = a1 + n.Amp * st.WagAmp * math.sin(st.Wag * n.Rate - n.Lag + n.Phase)
		if n.Amp2 ~= 0 then
			a2 = n.Amp2 * math.sin(st.Wag * n.Rate * 0.7 - n.Lag2 + n.Phase)
		end
	elseif kind == "ear" then
		a1 = a1 + n.Amp * math.sin(st.Sway * 1.3 + n.Phase) + earFlick(n, st)
	elseif kind == "orbit" then
		-- the node's Phase is already baked into the parts' rest CFrames (see addFlair); it only offsets the bob
		a1 = st.Sway * n.Rate
		lift = n.Amp * math.sin(st.Sway * 1.7 + n.Phase * 2)
	elseif kind == "bob" then
		lift = n.Amp * math.sin(st.Sway * n.Rate + n.Phase)
		a1 = a1 + n.Amp2 * math.sin(st.Sway * n.Rate * 0.8 + n.Phase + 1)
	else
		a1 = a1 + n.Amp * math.sin(st.Sway * n.Rate - n.Lag + n.Phase)
		if n.Amp2 ~= 0 then
			a2 = n.Amp2 * math.sin(st.Sway * n.Rate * 0.8 - n.Lag2 + n.Phase)
		end
	end
	local rot = axisRot(n.Axis, a1 * sideSign(n.Axis, n.Side))
	if a2 ~= 0 and n.Axis2 ~= "-" then
		rot = rot * axisRot(n.Axis2, a2 * sideSign(n.Axis2, n.Side))
	end
	local m = n.Hinge * rot * n.HingeInv
	if lift ~= 0 then
		m = CF(0, lift, 0) * m
	end
	return m
end

local function newRig(nodes, eyes, seed)
	return {
		Nodes = nodes,
		Eyes = eyes,
		Cache = {},
		St = { T = 0, Flap = 0, Wag = 0, Sway = 0, Excite = 0, WingAmp = 1, WagAmp = 1 },
		Offset = (seed % 628) / 100,
		BlinkPeriod = 3.1 + (seed % 17) * 0.13,
		BlinkOffset = (seed % 29) * 0.11,
		BlinkK = 0,
		LastT = nil,
	}
end

-- Rebuilds a rig from the attributes stored on a model's parts (used for Clone()d models).
local function rebuildRig(model)
	local nodes = {}
	local found = false
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") then
			local id = inst:GetAttribute("PB_Node")
			local base = stringToCF(inst:GetAttribute("PB_Base"))
			if type(id) == "number" and base then
				found = true
				local n = nodes[id]
				if not n then
					n = { Id = id, Parts = {}, Base = {} }
					nodes[id] = n
				end
				n.Parts[#n.Parts + 1] = inst
				n.Base[#n.Base + 1] = base
				local spec = inst:GetAttribute("PB_Spec")
				local hinge = stringToCF(inst:GetAttribute("PB_Hinge"))
				if type(spec) == "string" and hinge then
					local parsed = parseSpec(spec)
					for key, value in pairs(parsed) do
						n[key] = value
					end
					n.Hinge = hinge
					n.HingeInv = hinge:Inverse()
				end
			end
		end
	end
	if not found then
		return nil
	end
	-- dense, ordered list (parents always have a smaller id)
	local ids = {}
	for id, n in pairs(nodes) do
		if n.Hinge then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	local ordered = {}
	local remap = {}
	for i, id in ipairs(ids) do
		remap[id] = i
	end
	for i, id in ipairs(ids) do
		local n = nodes[id]
		if n.Parent then
			n.Parent = remap[n.Parent]
		end
		n.Id = i
		ordered[i] = n
	end
	local eyes = {}
	for _, side in ipairs({ "L", "R" }) do
		local base = model:FindFirstChild("Eye" .. side)
		local inner = model:FindFirstChild("Eye" .. side .. "Iris") or model:FindFirstChild("Eye" .. side .. "Pupil")
		local s1 = model:FindFirstChild("Eye" .. side .. "Shine")
		local s2 = model:FindFirstChild("Eye" .. side .. "Shine2")
		if base then
			eyes[#eyes + 1] = { Part = base, Size = base.Size, Hide = false }
		end
		if inner then
			eyes[#eyes + 1] = { Part = inner, Size = inner.Size, Hide = false }
		end
		if s1 then
			eyes[#eyes + 1] = { Part = s1, Size = s1.Size, Hide = true, T0 = 0 }
		end
		if s2 then
			eyes[#eyes + 1] = { Part = s2, Size = s2.Size, Hide = true, T0 = 0 }
		end
	end
	local seed = model:GetAttribute("PB_Seed")
	if type(seed) ~= "number" then
		seed = 1
	end
	return newRig(ordered, eyes, seed)
end

local function getRig(model)
	local rig = rigs[model]
	if rig then
		return rig
	end
	if rig == false then
		return nil
	end
	local ok, built = pcall(rebuildRig, model)
	if ok and built then
		rigs[model] = built
		return built
	end
	rigs[model] = false
	return nil
end

-- Advances the animation clocks. The clocks are accumulated (not t * speed) so changing Flap / Excited
-- never makes a wing jump.
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
	st.WingAmp = 1 + 0.18 * ex
	st.WagAmp = 1 + 0.5 * ex
	st.T = t
end

local function updateBlink(rig, t)
	local eyes = rig.Eyes
	if not eyes or #eyes == 0 then
		return
	end
	local u = (t + rig.BlinkOffset) % rig.BlinkPeriod
	local k = 0
	if u < BLINK_TIME then
		k = math.sin(u / BLINK_TIME * PI)
	end
	if k < 0.05 then
		k = 0
	end
	if k == rig.BlinkK then
		return
	end
	rig.BlinkK = k
	for i = 1, #eyes do
		local e = eyes[i]
		local part = e.Part
		if part and part.Parent then
			if e.Hide then
				if k > 0.35 then
					part.Transparency = 1
				else
					part.Transparency = e.T0
				end
			else
				part.Size = V3(e.Size.X, e.Size.Y * (1 - 0.9 * k), e.Size.Z)
			end
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function PetBuilder.Build(petDef, opts)
	opts = type(opts) == "table" and opts or {}
	local scale = clamp(tonumber(opts.Scale) or 1, 0.05, 40)
	local look = readLook(petDef)
	local id = "pet"
	local rarity = nil
	if type(petDef) == "table" then
		if petDef.Id ~= nil then
			id = tostring(petDef.Id)
		end
		rarity = petDef.Rarity
	end
	local seed = hashString(id .. look.Species)
	local ctx = newContext(look, scale, seed)
	ctx.Model.Name = "Pet_" .. id

	local profile = makeProfile(look.Species)
	if look.Species == "Frog" then
		-- the eyes sit on two bumps on top of the head
		local bump = V3(0.58, 1.46, -0.3)
		ctx.BumpPos = bump
		local n = V3(0.18, 0.5, -0.85).Unit
		local pos = bump + n * 0.3
		ctx.EyeFrame = CFrame.lookAt(pos, pos + n, V3(0, 1, 0))
		profile.EyeW, profile.EyeH, profile.EyeD = 0.42, 0.5, 0.2
	end
	buildCore(ctx, profile)
	SPECIES[look.Species](ctx, profile)
	buildWings(ctx, profile, look.WingStyle)
	if look.Accessory then
		ACCESSORIES[look.Accessory](ctx, profile)
	end
	addFlair(ctx, rarity)

	local model = ctx.Model
	model.PrimaryPart = ctx.Primary
	model:SetAttribute("PB_Seed", seed)
	model:SetAttribute("PB_Scale", scale)
	if type(petDef) == "table" and petDef.Id ~= nil then
		model:SetAttribute("PetId", tostring(petDef.Id))
	end
	rigs[model] = newRig(ctx.Nodes, ctx.EyeList, seed)
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
	local flapMul = 1
	local excited = 0
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
	local nodes = rig.Nodes
	local cache = rig.Cache
	local st = rig.St
	for i = 1, #nodes do
		local n = nodes[i]
		local parentCF = base
		if n.Parent then
			parentCF = cache[n.Parent] or base
		end
		local cur = parentCF * nodeMotion(n, st)
		cache[i] = cur
		local parts = n.Parts
		local bases = n.Base
		for j = 1, #parts do
			parts[j].CFrame = cur * bases[j]
		end
	end
	updateBlink(rig, t)
end

-- Height of the resting pose (studs, Scale 1): measured once per pet definition from a throwaway build.
local heightCache = setmetatable({}, { __mode = "k" })
local DEFAULT_HEIGHT = 2.7
local defaultHeightKey = {}

function PetBuilder.GetHeight(petDef)
	local key = petDef
	if type(key) ~= "table" then
		key = defaultHeightKey
	end
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
				local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = inst.CFrame:GetComponents()
				local half = (math.abs(r10) * inst.Size.X + math.abs(r11) * inst.Size.Y + math.abs(r12) * inst.Size.Z) / 2
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
