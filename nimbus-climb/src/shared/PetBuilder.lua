-- PetBuilder: every winged pet of Nimbus Climb, built in code from Parts only (no meshes, decals or
-- asset ids). Usable on the server, on the client and inside ViewportFrames.
-- Plain Lua 5.1-compatible syntax only.
--
-- API (contract: ARCHITECTURE_V2.md section 2, polished in ARCHITECTURE_V3.md section 8)
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
--     orbiting rarity sparkles... A Clone() of a pet rebuilds its rig from those attributes on first Animate.
--   * Faces are built ON the head instead of stuck to it:
--       - every eye is a full ellipsoid whose centre sits INSIDE the head, so only a lens-shaped front shows;
--       - irises, highlights, cheeks, bellies, inner ears, mouths, nostrils and patches are "overlays":
--         flat ellipsoids whose centre is sunk by exactly the surface's sag under them, so their rim meets
--         the curved surface and their front rises only a hair (Lift) above it (no floating dots);
--       - snouts, noses, ears, horns and limbs are "bumps": ellipsoids partly buried in the surface they
--         grow from, so every join is a clean intersection line.
--   * Eyes blink every few seconds (Animate squashes the eyeballs and hides their highlights for a moment).
--   * Round things are Ball parts. Squashed round things are a Block with a SpecialMesh of MeshType.Sphere
--     (a built-in shape, no asset id); very thin ones keep a legal part size and shrink through Mesh.Scale.
--   * Part budget: roughly 35 to 70 parts per pet (the contract limit is ~70).
--   * Unknown Species / WingStyle / Accessory values fall back to Cat / Feather / none.
--   * Rarity flair: Legendary / Mythic pets get orbiting glints + a low-rate sparkle emitter; Secret pets get
--     orbiting four-point sparkle stars, an iridescent sheen on the wings and an iridescent sparkle emitter.

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
local MIN_SIZE = 0.05 -- smallest part dimension we ask the engine for (studs); thinner ellipsoids use Mesh.Scale
local BASE_SCALE = 0.88 -- all geometry below is authored a little large; this brings a pet to ~2.2-3.1 studs
local PART_BUDGET = 70 -- optional details (lash flicks, extra puffs) are skipped once a pet gets this big

local FLAP_HZ = 2.0 -- wing beats per second at Flap = 1
local WAG_HZ = 0.9 -- tail wags per second
local SWAY_HZ = 0.55 -- slow idle sway (ears, scarf, leaves, halo bob...)
local BLINK_TIME = 0.16 -- seconds a blink lasts

local V3 = Vector3.new
local CF = CFrame.new
local A = CFrame.Angles
local IDENT = CFrame.new()
local ZERO = Vector3.new(0, 0, 0)
local UP = Vector3.new(0, 1, 0)
local FORWARD = Vector3.new(0, 0, -1)

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
local GOLD = rgb(244, 192, 72)
local GOLD_LIGHT = rgb(255, 224, 138)
local CREAM = rgb(255, 240, 214)
local PINK = rgb(246, 156, 174)
local BEAK = rgb(242, 176, 76)
local LEAF = rgb(104, 182, 108)
local LEAF_LIGHT = rgb(150, 210, 128)
local CAP = rgb(214, 88, 98)
local SCARF = rgb(206, 84, 98)
local SCARF_STRIPE = rgb(248, 222, 196)
local NOSE = rgb(58, 44, 52)
local SHINE = rgb(255, 255, 255)

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

local function luminance(c)
	return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
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
	return Color3.fromHSV(h, clamp(s * 1.05, 0, 1), clamp(v * 1.75 + 0.12, 0, 1))
end

-- The same colour with its hue turned by dh (0..1): used for the iridescent sheen of Secret pets.
local function hueShift(c, dh, satMin, valMin)
	local h, s, v = rgbToHsv(c)
	return Color3.fromHSV((h + dh) % 1, clamp(math.max(s, satMin or 0), 0, 1), clamp(math.max(v, valMin or 0), 0, 1))
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
	local up = upHint or UP
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
	local dark = luminance(P) < 0.34
	local ctx = {
		Scale = scale * BASE_SCALE,
		Look = look,
		Seed = seed,
		Model = Instance.new("Model"),
		Nodes = {},
		Count = 0,
		EyeList = {},
		Glow = look.Glow == true,
		Dark = dark,
		Primary = nil,
		C = {
			P = P,
			S = S,
			E = E,
			W = W,
			Belly = mix(S, WHITE, 0.12),
			Iris = irisColor(E),
			Blush = mix(P, rgb(255, 112, 146), 0.58),
			Pink = mix(PINK, P, 0.12),
			Mouth = darken(mix(P, rgb(120, 56, 70), 0.55), 0.55),
			Lash = darken(mix(P, E, 0.6), 0.5),
		},
	}
	if dark then
		-- dark pets: features are drawn in light accents instead of disappearing into the fur
		ctx.C.Mouth = mix(S, P, 0.25)
		ctx.C.Lash = mix(S, WHITE, 0.2)
		ctx.C.Blush = mix(S, rgb(255, 120, 170), 0.5)
	end
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
-- an angle that depends on the node's Kind (wing / tail / ear / sway / bob / orbit). Nodes may have a
-- parent node; parents must be created first.
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
-- o: Material, Transparency, Shadow, Node (joint id), Blink ("squash" | "hide": eye parts)
local function makePart(ctx, name, kind, size, rel, color, o)
	o = o or {}
	local k = ctx.Scale
	local rx, ry, rz = size.X * k, size.Y * k, size.Z * k
	local sx = math.max(rx, MIN_SIZE)
	local sy = math.max(ry, MIN_SIZE)
	local sz = math.max(rz, MIN_SIZE)
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
			-- thinner than a legal part: keep the part legal and shrink the drawn sphere instead
			if rx < MIN_SIZE or ry < MIN_SIZE or rz < MIN_SIZE then
				mesh.Scale = V3(math.max(rx, 0.001) / sx, math.max(ry, 0.001) / sy, math.max(rz, 0.001) / sz)
			end
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
	if o.Blink then
		part:SetAttribute("PB_Blink", o.Blink)
		local list = ctx.EyeList
		list[#list + 1] = { Part = part, Size = part.Size, Hide = o.Blink == "hide", T0 = part.Transparency }
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
-- Used for tails, plumes and fins. widths[i] = segment diameter, colors[i] = its colour.
local function chain(ctx, name, pts, widths, colors, o)
	o = o or {}
	local parent = o.Parent
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
			V3(w, w * (o.Flat or 1), len * (o.Stretch or 1.3)),
			colors[i],
			{ Node = id, Mesh = true }
		)
		ids[i] = id
		parts[i] = seg
		parent = id
	end
	return ids, parts
end

----------------------------------------------------------------------
-- Surfaces: ellipsoids other features sit on
----------------------------------------------------------------------
-- An ellipsoid surface descriptor in (unscaled) pet space: centre frame (its front is local -Z) + semi-axes.
local function ell(cf, size)
	return { CF = cf, A = V3(size.X / 2, size.Y / 2, size.Z / 2) }
end

-- Frame on the FRONT (-Z) half of ellipsoid e at local (x, y): returns (frame, normal, point), all in e's
-- local space; the frame's -Z points out of the surface (or along `lean`-blended forward), +Y stays "up".
local function surfaceFrame(e, x, y, roll, lean)
	local a = e.A
	local u = (x * x) / (a.X * a.X) + (y * y) / (a.Y * a.Y)
	if u > 0.995 then
		local k = math.sqrt(0.995 / u)
		x, y, u = x * k, y * k, 0.995
	end
	local z = -a.Z * math.sqrt(1 - u)
	local p = V3(x, y, z)
	local n = V3(x / (a.X * a.X), y / (a.Y * a.Y), z / (a.Z * a.Z)).Unit
	local look = n
	if lean and lean ~= 0 then
		look = (n * (1 - lean) + FORWARD * lean).Unit
	end
	local up = UP
	if math.abs(look.Y) > 0.96 then
		up = FORWARD
	end
	local cf = CFrame.lookAt(p, p + look, up)
	if roll and roll ~= 0 then
		cf = cf * A(0, 0, roll)
	end
	return cf, n, p
end

-- Distance from q along dir (both in e's local space) to the ellipsoid surface; nil when the ray misses.
local function rayDepth(e, q, dir)
	local a = e.A
	local ox, oy, oz = q.X / a.X, q.Y / a.Y, q.Z / a.Z
	local dx, dy, dz = dir.X / a.X, dir.Y / a.Y, dir.Z / a.Z
	local qa = dx * dx + dy * dy + dz * dz
	local qb = 2 * (ox * dx + oy * dy + oz * dz)
	local qc = ox * ox + oy * oy + oz * oz - 1
	local disc = qb * qb - 4 * qa * qc
	if disc < 0 or qa < 1e-9 then
		return nil
	end
	local t = (-qb - math.sqrt(disc)) / (2 * qa)
	if t < 0 then
		return 0
	end
	return t
end

-- OVERLAY: a flat ellipse (radii rx, ry) lying flush on surface e at local (x, y). Its centre is sunk by the
-- surface's sag under the ellipse, so its rim meets the surface and its front rises only o.Lift above it.
-- o: Lift, Roll, Side (mirror for the left side), Material, Transparency, Node, Blink
local function overlay(ctx, name, e, x, y, rx, ry, color, o)
	o = o or {}
	local frame, n = surfaceFrame(e, x, y, o.Roll)
	local p = frame.Position
	local right, up = frame.RightVector, frame.UpVector
	local sag = 0
	for i = 0, 7 do
		local ang = i * TAU / 8
		local q = p + right * (rx * math.cos(ang)) + up * (ry * math.sin(ang))
		local t = rayDepth(e, q, -n)
		if t == nil then
			t = math.max(rx, ry) * 0.5
		end
		if t > sag then
			sag = t
		end
	end
	local lift = o.Lift or 0.012
	local rel = e.CF * (frame * CF(0, 0, sag))
	if o.Side then
		rel = sd(o.Side, rel)
	end
	return blobCF(ctx, name, rel, V3(rx * 2, ry * 2, (sag + lift) * 2), color, {
		Mesh = true,
		Material = o.Material,
		Transparency = o.Transparency,
		Node = o.Node,
		Blink = o.Blink,
	})
end

-- BUMP: an ellipsoid of `size` growing out of surface e at local (x, y); `embed` (0..1) of its depth is
-- buried. Returns the part and the RIGHT-side surface descriptor of the bump (for features on it).
-- o: Roll, Lean (0..1 blend of the outward axis toward pet forward), Pitch, Side, Material, Node, Shadow
local function bumpOn(ctx, name, e, x, y, size, embed, color, o)
	o = o or {}
	local frame = surfaceFrame(e, x, y, o.Roll, o.Lean)
	if o.Pitch then
		frame = frame * A(o.Pitch, 0, 0)
	end
	local localCF = frame * CF(0, 0, -(size.Z * 0.5 - embed * size.Z))
	local right = e.CF * localCF
	local rel = right
	if o.Side then
		rel = sd(o.Side, rel)
	end
	local part = blobCF(ctx, name, rel, size, color, {
		Mesh = o.Mesh ~= false,
		Material = o.Material,
		Transparency = o.Transparency,
		Node = o.Node,
		Shadow = o.Shadow,
	})
	return part, ell(right, size)
end

-- Head-surface coordinates from angles: theta = sideways from straight ahead (+ = pet's right),
-- phi = elevation (+ = up). Returns the head-local (x, y) for surfaceFrame / overlay / bumpOn.
local function headXY(ctx, theta, phi)
	local ha = ctx.HeadE.A
	return ha.X * math.sin(theta) * math.cos(phi), ha.Y * math.sin(phi)
end

-- Pet-space point and outward normal on the head at (theta, phi), for features built by hand.
local function headPoint(ctx, theta, phi)
	local x, y = headXY(ctx, theta, phi)
	local _, n, p = surfaceFrame(ctx.HeadE, x, y)
	return ctx.HeadE.CF * p, n
end

-- Frame for an appendage rooted at pet-space point `root` that grows along `dir` (right side): +Y = dir,
-- -Z faces the pet's front (turned outward by yaw).
local function growFrame(root, dir, yaw)
	local up = dir.Unit
	local back = V3(0, 0, 1) - up * up.Z
	if back.Magnitude < 0.05 then
		back = V3(0, -1, 0) - up * up.Y
	end
	back = back.Unit
	local right = up:Cross(back)
	local cf = CFrame.fromMatrix(root, right, up, back)
	if yaw and yaw ~= 0 then
		cf = cf * A(0, -yaw, 0)
	end
	return cf
end

-- Budget guard for optional details.
local function canAfford(ctx, n)
	return ctx.Count + n + (ctx.Reserve or 0) <= PART_BUDGET
end

----------------------------------------------------------------------
-- Face kit
----------------------------------------------------------------------
-- One eye set INTO surface e (the head, or the frog's eye bump) at local (x, y) - given for the RIGHT eye.
-- The eyeball is a full ellipsoid w x h x d whose centre is sunk so only `out` studs of its front show:
-- a lens-shaped dome with a crisp rim where it meets the face. Iris + highlights are overlays on the
-- eyeball's own surface; the highlights sit on the same world side on both eyes (one light source).
local function buildEye(ctx, s, e, x, y, w, h, d, out)
	local C = ctx.C
	local nm = sname(s)
	local frame = surfaceFrame(e, x, y)
	local sink = d * 0.5 - out
	local eyeCF = e.CF * (frame * CF(0, 0, sink)) -- right eye, pet space
	local eyeE = ell(eyeCF, V3(w, h, d))
	local ballColor = C.E
	if ctx.Glow then
		ballColor = darken(C.E, 0.78)
	end
	blobCF(ctx, "Eye" .. nm, sd(s, eyeCF), V3(w, h, d), ballColor, { Mesh = true, Blink = "squash" })
	if ctx.Glow then
		-- glowing iris filling most of the eye, a darker rim of eyeball around it
		overlay(ctx, "Eye" .. nm .. "Iris", eyeE, 0, -0.04 * h, 0.4 * w, 0.4 * h, lighten(C.E, 0.08),
			{ Lift = 0.008, Side = s, Material = NEON, Blink = "hide" })
	else
		-- lighter iris glow in the lower half of the dark eye
		overlay(ctx, "Eye" .. nm .. "Iris", eyeE, 0, -0.17 * h, 0.34 * w, 0.26 * h, C.Iris,
			{ Lift = 0.008, Side = s, Blink = "hide" })
	end
	-- big highlight upper-left (as seen from the front), small one lower-right
	local r1 = 0.19 * w
	overlay(ctx, "Eye" .. nm .. "Shine", eyeE, 0.2 * w * s, 0.22 * h, r1, r1 * 1.08, SHINE,
		{ Lift = 0.018, Side = s, Material = NEON, Blink = "hide" })
	local r2 = 0.085 * w
	overlay(ctx, "Eye" .. nm .. "Shine2", eyeE, -0.19 * w * s, -0.25 * h, r2, r2, SHINE,
		{ Lift = 0.018, Side = s, Material = NEON, Blink = "hide" })
	-- lash flick along the upper-outer rim: a thin line on the FACE that frames the eye
	if ctx.Lashes and canAfford(ctx, 1) then
		local alpha = 1.05 -- radians from the outer corner (+x) toward the top
		local ax, ay = w * 0.5 * math.cos(alpha), h * 0.5 * math.sin(alpha)
		local grow = 1.06
		local pWorld = eyeCF * V3(ax * grow, ay * grow, -sink)
		local pLocal = e.CF:PointToObjectSpace(pWorld)
		local tx, ty = -w * 0.5 * math.sin(alpha), h * 0.5 * math.cos(alpha)
		local beta = math.atan2(ty, tx) + PI
		overlay(ctx, "Lash" .. nm, e, pLocal.X, pLocal.Y, w * 0.3, 0.032, C.Lash,
			{ Lift = 0.01, Side = s, Roll = beta })
	end
end

-- Little "w" mouth (two short arcs) centred at (x, y) on surface e.
local function mouthW(ctx, e, x, y, size, color)
	local sz = size or 1
	pair(function(s)
		overlay(ctx, "Mouth" .. sname(s), e, x + 0.072 * sz, y, 0.08 * sz, 0.024, color or ctx.C.Mouth,
			{ Roll = 0.42, Side = s, Lift = 0.01 })
	end)
end

-- One wide gentle smile made of two arcs.
local function mouthWide(ctx, e, x, y, width, color)
	pair(function(s)
		overlay(ctx, "Mouth" .. sname(s), e, x + width * 0.5, y, width * 0.56, 0.026, color or ctx.C.Mouth,
			{ Roll = 0.22, Side = s, Lift = 0.01 })
	end)
end

----------------------------------------------------------------------
-- Ears
----------------------------------------------------------------------
-- Ear growing out of the head at head angles (Theta, Phi) along Dir (right side); the lower Embed
-- fraction of its height is buried in the head. Optional flush inner ear and a coloured tip.
-- e: Theta, Phi, Dir, Yaw, Size, Embed, Color, InColor, InScale, TipColor, Amp, Name
local function earPair(ctx, e)
	pair(function(s)
		local root = headPoint(ctx, e.Theta, e.Phi)
		local size = e.Size
		local frame = growFrame(root, e.Dir, e.Yaw)
		local earCF = frame * CF(0, size.Y * (0.5 - (e.Embed or 0.3)), 0)
		local n = newNode(ctx, {
			Kind = "ear",
			Hinge = sd(s, frame),
			Axis = "z",
			Amp = e.Amp or 0.05,
			Side = s,
			Phase = s * 2.1,
		})
		local name = e.Name or "Ear"
		blobCF(ctx, name .. sname(s), sd(s, earCF), size, e.Color, { Node = n, Mesh = true })
		local earE = ell(earCF, size)
		if e.TipColor then
			local tipCF = earCF * CF(0, size.Y * 0.31, 0)
			blobCF(ctx, name .. "Tip" .. sname(s), sd(s, tipCF), V3(size.X * 0.62, size.Y * 0.42, size.Z * 1.04), e.TipColor,
				{ Node = n, Mesh = true })
		end
		if e.InColor then
			local k = e.InScale or 1
			overlay(ctx, name .. "In" .. sname(s), earE, 0, -size.Y * 0.06, size.X * 0.29 * k, size.Y * 0.31 * k, e.InColor,
				{ Side = s, Node = n, Lift = 0.01 })
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
	EyeTheta = 0.5,
	EyePhi = -0.06,
	EyeW = 0.44,
	EyeH = 0.54,
	EyeD = 0.34,
	EyeOut = 0.07,
	CheekTheta = 0.9,
	CheekPhi = -0.3,
	CheekW = 0.3,
	CheekH = 0.18,
	BellyY = -0.08,
	BellyR = V3(0.36, 0.36, 0),
	FeetPos = V3(0.34, -0.52, -0.14),
	FeetSize = V3(0.44, 0.3, 0.54),
	ArmPos = V3(0.6, 0.0, -0.2),
	ArmSize = V3(0.27, 0.44, 0.3),
	ArmRoll = 0.38,
	WingAnchor = V3(0.34, 0.28, 0.44),
	WingScale = 1,
	AccessoryX = 0.5, -- how far from the centre line horns / antlers sit
	Lashes = true,
}

local PROFILES = {
	Cat = {},
	Dog = {},
	Fox = { Head = V3(2.0, 1.7, 1.75), AccessoryX = 0.3 },
	Bunny = { Head = V3(1.9, 1.72, 1.7) },
	Bear = { Head = V3(2.0, 1.75, 1.75), Body = V3(1.32, 1.2, 1.15) },
	Panda = { Head = V3(2.0, 1.75, 1.75), Body = V3(1.32, 1.2, 1.15), Lashes = false },
	Dragon = {
		Body = V3(1.35, 1.25, 1.2),
		Head = V3(2.05, 1.8, 1.8),
		HeadPos = V3(0, 1.0, -0.12),
		EyeTheta = 0.52,
		EyePhi = 0.02,
		EyeW = 0.48,
		EyeH = 0.6,
		EyeD = 0.36,
		BellyY = -0.06,
		BellyR = V3(0.42, 0.44, 0),
		BellyColor = function(C)
			return mix(CREAM, C.P, 0.2)
		end,
		WingAnchor = V3(0.34, 0.34, 0.48),
		WingScale = 1.1,
		AccessoryX = 0.5,
	},
	Owl = {
		Body = V3(1.35, 1.25, 1.15),
		Head = V3(2.0, 1.6, 1.65),
		HeadPos = V3(0, 0.95, -0.08),
		EyeTheta = 0.47,
		EyePhi = 0.02,
		EyeW = 0.52,
		EyeH = 0.58,
		CheekTheta = 1.0,
		CheekPhi = -0.36,
		BellyR = V3(0.44, 0.46, 0),
		Lashes = false,
	},
	Slime = {
		Body = V3(1.75, 0.95, 1.55),
		Head = V3(1.95, 1.6, 1.75),
		HeadPos = V3(0, 0.78, -0.05),
		EyeTheta = 0.5,
		EyePhi = -0.1,
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
		BellyR = V3(0.38, 0.38, 0),
	},
	Frog = {
		Body = V3(1.3, 1.05, 1.15),
		Head = V3(2.1, 1.5, 1.7),
		HeadPos = V3(0, 0.85, -0.1),
		FeetSize = V3(0.56, 0.26, 0.7),
		FeetPos = V3(0.4, -0.46, -0.16),
		EyeW = 0.4,
		EyeH = 0.46,
		EyeD = 0.32,
		CheekTheta = 0.82,
		CheekPhi = -0.26,
		Lashes = false,
	},
	Penguin = {
		Body = V3(1.4, 1.35, 1.2),
		Head = V3(1.85, 1.55, 1.6),
		HeadPos = V3(0, 0.95, -0.1),
		BellyY = -0.1,
		BellyR = V3(0.48, 0.5, 0),
		FeetPos = V3(0.3, -0.64, -0.24),
		FeetSize = V3(0.42, 0.16, 0.58),
		ArmPos = V3(0.68, -0.02, -0.02),
		ArmSize = V3(0.2, 0.66, 0.42),
		ArmRoll = 0.3,
		WingScale = 0.9,
	},
	Axolotl = {
		Body = V3(1.15, 1.05, 1.3),
		Head = V3(2.1, 1.55, 1.7),
		HeadPos = V3(0, 0.88, -0.1),
		EyeTheta = 0.68,
		EyePhi = 0.04,
		EyeW = 0.4,
		EyeH = 0.46,
		EyeD = 0.32,
		CheekTheta = 1.0,
		FeetSize = V3(0.4, 0.26, 0.5),
		Lashes = false,
	},
}

local SPECIES = {}

-- Muzzle bump on the lower face; returns its surface for nose / mouth.
local function muzzle(ctx, phi, size, color, embed, lean)
	local x, y = headXY(ctx, 0, phi)
	local _, e = bumpOn(ctx, "Muzzle", ctx.HeadE, x, y, size, embed or 0.62, color, { Lean = lean or 0.35 })
	return e
end

-- Nose bump sitting on the muzzle's upper front.
local function noseOn(ctx, e, y, size, color, name)
	local part = bumpOn(ctx, name or "Nose", e, 0, y, size, 0.55, color or NOSE, { Lean = 0.2 })
	return part
end

----- Cat -----
SPECIES.Cat = function(ctx, p)
	local C = ctx.C
	earPair(ctx, {
		Theta = 0.55, Phi = 0.86, Dir = V3(0.42, 1, 0.08), Yaw = 0.25, Size = V3(0.6, 0.74, 0.26), Embed = 0.32,
		Color = C.P, InColor = C.Pink,
	})
	local mz = muzzle(ctx, -0.36, V3(0.66, 0.4, 0.34), lighten(C.P, 0.42))
	noseOn(ctx, mz, 0.1, V3(0.16, 0.1, 0.1), C.Pink)
	mouthW(ctx, mz, 0, -0.07, 0.9)
	-- whiskers: two thin strokes per side fanning out of the muzzle sides
	pair(function(s)
		for i = 1, 2 do
			local frame = surfaceFrame(mz, 0.26, 0.03 - (i - 1) * 0.09)
			local base = mz.CF * frame.Position
			local dir = V3(1, 0.12 - (i - 1) * 0.2, 0.18).Unit
			local rel = CF(base + dir * 0.24) * aim(dir)
			blockCF(ctx, "Whisker" .. sname(s) .. i, sd(s, rel), V3(0.035, 0.035, 0.46), lighten(C.P, 0.62))
		end
	end)
	chain(ctx, "Tail",
		{ V3(0, -0.2, 0.42), V3(0, -0.12, 0.92), V3(0, 0.22, 1.28), V3(0, 0.68, 1.4) },
		{ 0.34, 0.32, 0.3 }, { C.P, C.P, mix(C.P, C.S, 0.6) }, { Amp = 0.2 })
end

----- Dog -----
SPECIES.Dog = function(ctx, p)
	local C = ctx.C
	local earC = mix(C.P, rgb(70, 46, 34), 0.24)
	earPair(ctx, {
		Theta = 1.02, Phi = 0.5, Dir = V3(0.42, -1, 0.06), Yaw = 0.9, Size = V3(0.42, 0.8, 0.24), Embed = 0.12,
		Color = earC, Amp = 0.08,
	})
	local mz = muzzle(ctx, -0.32, V3(0.8, 0.52, 0.5), C.S, 0.6, 0.45)
	noseOn(ctx, mz, 0.12, V3(0.3, 0.2, 0.18), NOSE)
	mouthW(ctx, mz, 0, -0.08, 1.1)
	overlay(ctx, "Tongue", mz, 0, -0.17, 0.08, 0.06, rgb(240, 120, 146), { Lift = 0.016 })
	-- a darker patch around one eye: every dog gets a little personality
	local px, py = headXY(ctx, p.EyeTheta + 0.06, p.EyePhi + 0.04)
	overlay(ctx, "Patch", ctx.HeadE, px, py, 0.34, 0.38, earC, { Lift = 0.006, Roll = -0.3 })
	chain(ctx, "Tail",
		{ V3(0, -0.22, 0.44), V3(0, -0.06, 0.88), V3(0, 0.32, 1.1) },
		{ 0.32, 0.28 }, { C.P, mix(C.P, C.S, 0.6) }, { Amp = 0.3, Rate = 1.5, Lag = 0.5 })
end

----- Fox -----
SPECIES.Fox = function(ctx, p)
	local C = ctx.C
	earPair(ctx, {
		Theta = 0.56, Phi = 0.82, Dir = V3(0.5, 1, 0.06), Yaw = 0.2, Size = V3(0.64, 0.86, 0.24), Embed = 0.3,
		Color = C.P, InColor = lighten(C.S, 0.15), TipColor = darken(C.P, 0.62),
	})
	-- a narrow cream muzzle that points forward, nose at its tip
	local mz = muzzle(ctx, -0.32, V3(0.6, 0.4, 0.62), C.S, 0.66, 0.55)
	noseOn(ctx, mz, 0.08, V3(0.2, 0.13, 0.13), NOSE)
	mouthW(ctx, mz, 0, -0.1, 0.9)
	-- cream cheek ruffs that flare out from the lower head
	pair(function(s)
		local x, y = headXY(ctx, 1.12, -0.42)
		bumpOn(ctx, "Ruff" .. sname(s), ctx.HeadE, x, y, V3(0.62, 0.34, 0.4), 0.55, C.S, { Side = s, Roll = -0.35 })
	end)
	chain(ctx, "Tail",
		{ V3(0, -0.16, 0.42), V3(0, -0.02, 1.0), V3(0, 0.34, 1.5), V3(0, 0.8, 1.76) },
		{ 0.6, 0.78, 0.62 }, { C.P, C.P, C.S }, { Amp = 0.18, Stretch = 1.32 })
end

----- Bunny -----
SPECIES.Bunny = function(ctx, p)
	local C = ctx.C
	earPair(ctx, {
		Theta = 0.26, Phi = 0.92, Dir = V3(0.16, 1, 0.12), Yaw = 0.15, Size = V3(0.42, 1.12, 0.22), Embed = 0.22,
		Color = C.P, InColor = C.Pink, InScale = 1.05, Amp = 0.07,
	})
	local mz = muzzle(ctx, -0.38, V3(0.62, 0.36, 0.3), lighten(C.P, 0.45))
	noseOn(ctx, mz, 0.09, V3(0.14, 0.1, 0.1), C.Pink)
	mouthW(ctx, mz, 0, -0.06, 0.85)
	overlay(ctx, "Teeth", mz, 0, -0.14, 0.07, 0.055, rgb(255, 250, 240), { Lift = 0.014 })
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.12, 0.5), Axis = "y", Amp = 0.28, Rate = 1.3 })
	blob(ctx, "Tail", V3(0, -0.16, 0.62), V3(0.5, 0.5, 0.5), lighten(C.S, 0.1), nil, { Node = n })
end

----- Bear -----
SPECIES.Bear = function(ctx, p)
	local C = ctx.C
	earPair(ctx, {
		Theta = 0.62, Phi = 0.74, Dir = V3(0.55, 1, 0.05), Yaw = 0.1, Size = V3(0.5, 0.46, 0.34), Embed = 0.36,
		Color = C.P, InColor = C.S, InScale = 1.2, Amp = 0.04,
	})
	local mz = muzzle(ctx, -0.33, V3(0.74, 0.5, 0.44), C.S)
	noseOn(ctx, mz, 0.1, V3(0.28, 0.18, 0.15), NOSE)
	mouthW(ctx, mz, 0, -0.1, 1.0)
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.15, 0.5), Axis = "y", Amp = 0.25 })
	blob(ctx, "Tail", V3(0, -0.2, 0.6), V3(0.32, 0.32, 0.32), C.P, nil, { Node = n })
end

----- Panda -----
SPECIES.Panda = function(ctx, p)
	local C = ctx.C
	earPair(ctx, {
		Theta = 0.64, Phi = 0.74, Dir = V3(0.55, 1, 0.05), Yaw = 0.1, Size = V3(0.5, 0.48, 0.36), Embed = 0.36,
		Color = C.S, Amp = 0.04,
	})
	-- dark teardrop eye patches lying flush on the face; the eyes sit in them
	pair(function(s)
		local x, y = headXY(ctx, p.EyeTheta + 0.04, p.EyePhi - 0.03)
		overlay(ctx, "Patch" .. sname(s), ctx.HeadE, x, y, 0.32, 0.4, C.S, { Lift = 0.006, Roll = -0.42, Side = s })
	end)
	local mz = muzzle(ctx, -0.36, V3(0.64, 0.42, 0.36), lighten(C.P, 0.35))
	noseOn(ctx, mz, 0.09, V3(0.24, 0.16, 0.13), C.S)
	mouthW(ctx, mz, 0, -0.08, 0.95)
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.15, 0.5), Axis = "y", Amp = 0.25 })
	blob(ctx, "Tail", V3(0, -0.2, 0.6), V3(0.3, 0.3, 0.3), lighten(C.P, 0.2), nil, { Node = n })
end

----- Dragon (the Cloudy Dragon is the mascot: fluffy, round, gold horns, cloud-puff tail) -----
SPECIES.Dragon = function(ctx, p)
	local C = ctx.C
	local cream = mix(CREAM, C.P, 0.2)
	-- stubby rounded snout with two nostrils and a small smile, all flush on it
	local x, y = headXY(ctx, 0, -0.3)
	local _, snout = bumpOn(ctx, "Snout", ctx.HeadE, x, y, V3(0.8, 0.5, 0.48), 0.6, cream, { Lean = 0.45 })
	pair(function(s)
		overlay(ctx, "Nostril" .. sname(s), snout, 0.13, 0.07, 0.045, 0.034, darken(mix(C.E, C.S, 0.4), 0.25),
			{ Side = s, Lift = 0.008, Roll = 0.35 })
	end)
	mouthWide(ctx, snout, 0, -0.09, 0.15)
	-- soft fins flaring from the cheeks (like the icon), with a lighter flush inner panel
	earPair(ctx, {
		Name = "Fin", Theta = 1.22, Phi = 0.18, Dir = V3(1, 0.62, 0.32), Yaw = 0.7, Size = V3(0.46, 0.72, 0.16),
		Embed = 0.22, Color = C.S, InColor = lighten(C.S, 0.45), InScale = 1.1, Amp = 0.08,
	})
	-- fluffy cloud tuft between the horns
	local tx, ty = headXY(ctx, 0, 1.05)
	bumpOn(ctx, "Tuft1", ctx.HeadE, tx, ty, V3(0.5, 0.44, 0.48), 0.55, lighten(C.P, 0.1), { Mesh = false })
	pair(function(s)
		local qx, qy = headXY(ctx, 0.3, 1.18)
		bumpOn(ctx, "Tuft" .. sname(s), ctx.HeadE, qx, qy, V3(0.34, 0.32, 0.34), 0.55, C.P, { Side = s, Mesh = false })
	end)
	-- sky-blue cloud puffs down the back
	local backE = ell(CF(p.BodyPos) * A(0, PI, 0), p.Body) -- the body seen from behind (front = pet back)
	local puffs = { { 0.36, 0.42 }, { 0.04, 0.36 }, { -0.26, 0.3 } }
	for i = 1, #puffs do
		bumpOn(ctx, "Puff" .. i, backE, 0, puffs[i][1], V3(puffs[i][2], puffs[i][2], puffs[i][2]), 0.5, C.S, { Mesh = false })
	end
	-- tail ending in a cloud puff
	local ids = chain(ctx, "Tail",
		{ V3(0, -0.26, 0.44), V3(0, -0.3, 1.0), V3(0, -0.02, 1.52), V3(0, 0.38, 1.86) },
		{ 0.5, 0.42, 0.34 }, { C.P, mix(C.P, C.S, 0.35), mix(C.P, C.S, 0.7) },
		{ Amp = 0.2, Lag = 0.8 })
	local tipNode = ids[#ids]
	blob(ctx, "TailPuff1", V3(0, 0.5, 1.96), V3(0.56, 0.52, 0.52), C.P, nil, { Node = tipNode })
	blob(ctx, "TailPuff2", V3(0.26, 0.4, 1.92), V3(0.36, 0.34, 0.34), lighten(C.S, 0.2), nil, { Node = tipNode })
	blob(ctx, "TailPuff3", V3(-0.26, 0.4, 1.92), V3(0.36, 0.34, 0.34), lighten(C.S, 0.2), nil, { Node = tipNode })
end

----- Owl -----
SPECIES.Owl = function(ctx, p)
	local C = ctx.C
	-- pale facial discs flush around the huge eyes
	pair(function(s)
		local x, y = headXY(ctx, p.EyeTheta, p.EyePhi - 0.02)
		overlay(ctx, "Disc" .. sname(s), ctx.HeadE, x, y, 0.44, 0.44, C.S, { Lift = 0.006, Side = s })
	end)
	earPair(ctx, {
		Name = "Tuft", Theta = 0.62, Phi = 0.72, Dir = V3(0.75, 1, 0.1), Yaw = 0.2, Size = V3(0.3, 0.56, 0.22), Embed = 0.3,
		Color = darken(C.P, 0.12), Amp = 0.04,
	})
	local bx, by = headXY(ctx, 0, -0.2)
	bumpOn(ctx, "Beak", ctx.HeadE, bx, by, V3(0.22, 0.3, 0.24), 0.55, BEAK, { Lean = 0.3, Pitch = -0.25 })
	-- feathery chest scallops drawn on the belly
	for i = 1, 3 do
		overlay(ctx, "Ruffle" .. i, ctx.BodyE, 0, 0.14 - (i - 1) * 0.17, 0.26 - (i - 1) * 0.03, 0.03, darken(C.S, 0.14),
			{ Lift = 0.02, Roll = 0 })
	end
	-- short fan tail
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.2, 0.46), Axis = "y", Amp = 0.18 })
	blob(ctx, "Tail", V3(0, -0.3, 0.76), V3(0.46, 0.16, 0.6), darken(C.P, 0.1), A(0.25, 0, 0), { Node = n, Mesh = true })
	blob(ctx, "TailL", V3(-0.2, -0.28, 0.72), V3(0.28, 0.13, 0.5), C.P, A(0.25, 0.3, 0), { Node = n, Mesh = true })
	blob(ctx, "TailR", V3(0.2, -0.28, 0.72), V3(0.28, 0.13, 0.5), C.P, A(0.25, -0.3, 0), { Node = n, Mesh = true })
end

----- Slime -----
SPECIES.Slime = function(ctx, p)
	local C = ctx.C
	-- glossy highlights lying on the jelly
	local gx, gy = headXY(ctx, -0.42, 0.42)
	overlay(ctx, "Gloss1", ctx.HeadE, gx, gy, 0.26, 0.11, lighten(C.P, 0.7), { Lift = 0.012, Roll = 0.5, Transparency = 0.1 })
	local hx, hy = headXY(ctx, -0.62, 0.22)
	overlay(ctx, "Gloss2", ctx.HeadE, hx, hy, 0.07, 0.07, lighten(C.P, 0.75), { Lift = 0.012, Transparency = 0.1 })
	-- wobbly base drips melting into the body
	blob(ctx, "Drip1", V3(-0.62, -0.32, -0.32), V3(0.46, 0.32, 0.46), C.P, nil, { Mesh = true })
	blob(ctx, "Drip2", V3(0.64, -0.3, -0.26), V3(0.42, 0.3, 0.42), C.P, nil, { Mesh = true })
	blob(ctx, "Drip3", V3(0.1, -0.36, 0.5), V3(0.46, 0.28, 0.46), C.P, nil, { Mesh = true })
	-- peak on top that bobbles
	local n = newNode(ctx, { Kind = "sway", Hinge = CF(0, 1.46, -0.05), Axis = "z", Amp = 0.18, Axis2 = "x", Amp2 = 0.1, Lag2 = 1.2, Rate = 1.3 })
	blob(ctx, "Peak", V3(0.03, 1.64, -0.05), V3(0.36, 0.52, 0.36), lighten(C.P, 0.06), A(0, 0, -0.25), { Node = n, Mesh = true })
	local mx, my = headXY(ctx, 0, -0.36)
	mouthWide(ctx, ctx.HeadE, mx, my, 0.2)
end

----- Unicorn -----
SPECIES.Unicorn = function(ctx, p)
	local C = ctx.C
	earPair(ctx, {
		Theta = 0.5, Phi = 0.86, Dir = V3(0.42, 1, 0.12), Yaw = 0.3, Size = V3(0.34, 0.58, 0.2), Embed = 0.3,
		Color = C.P, InColor = lighten(C.S, 0.25),
	})
	local mz = muzzle(ctx, -0.34, V3(0.82, 0.54, 0.54), lighten(C.P, 0.32), 0.6, 0.45)
	pair(function(s)
		overlay(ctx, "Nostril" .. sname(s), mz, 0.15, 0.06, 0.04, 0.03, C.Mouth, { Side = s, Lift = 0.008, Roll = 0.3 })
	end)
	mouthWide(ctx, mz, 0, -0.1, 0.16)
	-- spiral horn: four stacked, shrinking pearls growing out of the forehead
	local root, nrm = headPoint(ctx, 0, 0.62)
	local dir = (nrm + V3(0, 0.55, 0)).Unit
	local hornCols = { GOLD_LIGHT, rgb(250, 238, 200), GOLD_LIGHT, rgb(250, 238, 200) }
	local hornW = { 0.3, 0.24, 0.17, 0.11 }
	local hn = newNode(ctx, { Kind = "sway", Hinge = CF(root), Axis = "x", Amp = 0.04, Rate = 0.8 })
	for i = 1, 4 do
		local pos = root + dir * (0.06 + (i - 1) * 0.21)
		blob(ctx, "Horn" .. i, pos, V3(hornW[i], hornW[i], 0.36), hornCols[i], aim(dir), { Node = hn, Mesh = true })
	end
	-- flowing mane (secondary colour) from the forehead down the back of the neck
	local maneC = { C.S, mix(C.S, C.P, 0.35), C.S }
	local m1 = newNode(ctx, { Kind = "sway", Hinge = CF(0, 1.7, 0.3), Axis = "x", Amp = 0.08, Rate = 1.1 })
	local fx, fy = headXY(ctx, 0.2, 0.58)
	bumpOn(ctx, "Forelock", ctx.HeadE, fx, fy, V3(0.4, 0.36, 0.3), 0.55, maneC[1], { Node = m1, Roll = -0.4 })
	blob(ctx, "Mane1", V3(0, 1.66, 0.52), V3(0.56, 0.56, 0.5), maneC[2], nil, { Node = m1, Mesh = true })
	blob(ctx, "Mane2", V3(0, 1.18, 0.76), V3(0.5, 0.62, 0.44), maneC[1], nil, { Node = m1, Mesh = true })
	blob(ctx, "Mane3", V3(0, 0.64, 0.66), V3(0.44, 0.56, 0.4), maneC[3], nil, { Node = m1, Mesh = true })
	-- swishy tail
	chain(ctx, "Tail",
		{ V3(0, -0.18, 0.44), V3(0, -0.2, 0.96), V3(0, 0.1, 1.42), V3(0, 0.55, 1.68) },
		{ 0.42, 0.44, 0.4 }, { C.S, mix(C.S, C.P, 0.3), mix(C.S, WHITE, 0.4) }, { Amp = 0.22, Lag = 0.8, Stretch = 1.32 })
end

----- Phoenix -----
SPECIES.Phoenix = function(ctx, p)
	local C = ctx.C
	local bx, by = headXY(ctx, 0, -0.22)
	local _, beak = bumpOn(ctx, "Beak", ctx.HeadE, bx, by, V3(0.28, 0.22, 0.42), 0.55, C.S, { Lean = 0.5 })
	overlay(ctx, "BeakLine", beak, 0, -0.03, 0.12, 0.016, darken(C.S, 0.3), { Lift = 0.008 })
	-- flame crest: three flickering plumes rooted in the crown
	local cx, cy = headXY(ctx, 0, 0.9)
	local crestRoot = ctx.HeadE.CF * surfaceFrame(ctx.HeadE, cx, cy).Position
	local cn = newNode(ctx, { Kind = "sway", Hinge = CF(crestRoot), Axis = "z", Amp = 0.12, Axis2 = "x", Amp2 = 0.1, Lag2 = 1.5, Rate = 2.4 })
	blob(ctx, "Crest1", crestRoot + V3(0, 0.3, 0.06), V3(0.22, 0.74, 0.16), C.S, A(-0.25, 0, 0), { Node = cn, Mesh = true })
	blob(ctx, "Crest2", crestRoot + V3(0.2, 0.22, 0.1), V3(0.18, 0.58, 0.14), mix(C.S, C.P, 0.5), A(-0.25, 0, -0.42), { Node = cn, Mesh = true })
	blob(ctx, "Crest3", crestRoot + V3(-0.2, 0.22, 0.1), V3(0.18, 0.58, 0.14), mix(C.S, C.P, 0.5), A(-0.25, 0, 0.42), { Node = cn, Mesh = true })
	-- three long tail plumes, fanned
	local cols = { C.S, C.P, C.S }
	local yaws = { -0.38, 0, 0.38 }
	for i = 1, 3 do
		local dir = V3(math.sin(yaws[i]), -0.22, math.cos(yaws[i])).Unit
		local root = V3(0, -0.2, 0.42)
		local tip = root + dir * 1.5
		chain(ctx, "Plume" .. i, { root, (root + tip) * 0.5, tip }, { 0.38, 0.32 }, { cols[i], mix(cols[i], C.S, 0.5) },
			{ Amp = 0.16, Lag = 0.9, Rate = 1.4, Flat = 0.7, Phase = i * 1.1 })
	end
end

----- Frog -----
SPECIES.Frog = function(ctx, p)
	local C = ctx.C
	-- eye bumps on top of the head; the eyes are set into them (core reads ctx.EyeHost)
	local ex, ey = headXY(ctx, 0.42, 0.56)
	local hostE
	pair(function(s)
		local _, e = bumpOn(ctx, "EyeBump" .. sname(s), ctx.HeadE, ex, ey, V3(0.72, 0.68, 0.66), 0.5, C.P,
			{ Side = s, Lean = 0.25, Mesh = false })
		hostE = e
	end)
	ctx.EyeHost = hostE
	local mx, my = headXY(ctx, 0, -0.34)
	mouthWide(ctx, ctx.HeadE, mx, my, 0.56)
	pair(function(s)
		local nx, ny = headXY(ctx, 0.1, -0.08)
		overlay(ctx, "Nostril" .. sname(s), ctx.HeadE, nx, ny, 0.035, 0.03, darken(C.P, 0.45), { Side = s, Lift = 0.008 })
	end)
	-- pale throat drawn on the lower head
	local tx, ty = headXY(ctx, 0, -0.62)
	overlay(ctx, "Throat", ctx.HeadE, tx, ty, 0.46, 0.2, lighten(C.S, 0.1), { Lift = 0.008 })
end

----- Penguin -----
SPECIES.Penguin = function(ctx, p)
	local C = ctx.C
	-- heart-shaped white face mask: two lobes round the eyes + a chin, flush on the head
	pair(function(s)
		local x, y = headXY(ctx, 0.36, -0.04)
		overlay(ctx, "Mask" .. sname(s), ctx.HeadE, x, y, 0.44, 0.46, C.S, { Lift = 0.006, Side = s, Roll = -0.15 })
	end)
	local cx, cy = headXY(ctx, 0, -0.38)
	overlay(ctx, "MaskChin", ctx.HeadE, cx, cy, 0.52, 0.34, C.S, { Lift = 0.008 })
	local bx, by = headXY(ctx, 0, -0.24)
	bumpOn(ctx, "Beak", ctx.HeadE, bx, by, V3(0.36, 0.2, 0.34), 0.55, BEAK, { Lean = 0.4 })
	local n = newNode(ctx, { Kind = "tail", Hinge = CF(0, -0.36, 0.5), Axis = "y", Amp = 0.28 })
	blob(ctx, "Tail", V3(0, -0.44, 0.66), V3(0.36, 0.18, 0.42), C.P, A(0.3, 0, 0), { Node = n, Mesh = true })
end

----- Axolotl -----
SPECIES.Axolotl = function(ctx, p)
	local C = ctx.C
	-- three feathery gills per side, rooted in the sides of the head
	local phis = { 0.5, 0.18, -0.14 }
	local dirs = { V3(0.7, 1, 0.12), V3(1, 0.35, 0.12), V3(1, -0.2, 0.12) }
	pair(function(s)
		for i = 1, 3 do
			local root = headPoint(ctx, 1.32, phis[i])
			local frame = growFrame(root, dirs[i], 0.6)
			local n = newNode(ctx, { Kind = "sway", Hinge = sd(s, frame), Axis = "z", Amp = 0.18, Lag = i * 0.6, Rate = 1.8, Side = s, Phase = s })
			blobCF(ctx, "Gill" .. sname(s) .. i, sd(s, frame * CF(0, 0.3, 0)), V3(0.18, 0.74, 0.14), mix(C.S, WHITE, (i - 1) * 0.08),
				{ Node = n, Mesh = true })
		end
	end)
	local mx, my = headXY(ctx, 0, -0.32)
	mouthWide(ctx, ctx.HeadE, mx, my, 0.42)
	-- flat tail fin
	chain(ctx, "Tail",
		{ V3(0, -0.1, 0.5), V3(0, -0.04, 1.06), V3(0, 0.02, 1.58) },
		{ 0.48, 0.4 }, { mix(C.P, C.S, 0.3), C.S }, { Amp = 0.3, Lag = 0.8, Flat = 1.0 })
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

local LIMB_COLORS = {
	-- tidy colour blocking: some species have limbs in their secondary colour
	Panda = "S",
	Penguin = "Beak",
}

local function buildCore(ctx, p, species)
	local C = ctx.C
	local limb = C.P
	local feet = C.P
	local mode = LIMB_COLORS[species]
	if mode == "S" then
		limb, feet = C.S, C.S
	elseif mode == "Beak" then
		feet = BEAK
	end

	ctx.Primary = blobCF(ctx, "Body", CF(p.BodyPos), p.Body, resolveColor(p.BodyColor, C, C.P), { Shadow = true })
	ctx.BodyE = ell(CF(p.BodyPos), p.Body)
	ctx.HC = p.HeadPos
	ctx.HA = V3(p.Head.X / 2, p.Head.Y / 2, p.Head.Z / 2)
	ctx.HeadE = ell(CF(p.HeadPos), p.Head)
	ctx.Head = blobCF(ctx, "Head", CF(p.HeadPos), p.Head, resolveColor(p.HeadColor, C, C.P), { Shadow = true })

	-- belly patch lying flush on the body
	if not p.NoBelly then
		overlay(ctx, "Belly", ctx.BodyE, 0, p.BellyY, p.BellyR.X, p.BellyR.Y, resolveColor(p.BellyColor, C, C.Belly), { Lift = 0.012 })
	end

	if not p.NoFeet then
		pair(function(s)
			blobS(ctx, s, "Foot", p.FeetPos, p.FeetSize, feet, A(0, -0.14, 0), { Mesh = true })
		end)
	end
	if not p.NoArms then
		pair(function(s)
			blobS(ctx, s, "Arm", p.ArmPos, p.ArmSize, limb, A(0.1, 0, p.ArmRoll), { Mesh = true })
		end)
	end

	-- blush cheeks, flush on the face
	if not p.NoCheeks then
		pair(function(s)
			local x, y = headXY(ctx, p.CheekTheta, p.CheekPhi)
			overlay(ctx, "Cheek" .. sname(s), ctx.HeadE, x, y, p.CheekW * 0.5, p.CheekH * 0.5, C.Blush,
				{ Lift = 0.008, Roll = 0.12, Side = s, Transparency = 0.15 })
		end)
	end
end

-- Eyes come after the species extras (the frog builds its eye bumps there).
local function buildFaceEyes(ctx, p)
	ctx.Lashes = p.Lashes ~= false
	pair(function(s)
		if ctx.EyeHost then
			buildEye(ctx, s, ctx.EyeHost, 0, 0.02, p.EyeW, p.EyeH, p.EyeD, p.EyeOut)
		else
			local x, y = headXY(ctx, p.EyeTheta, p.EyePhi)
			buildEye(ctx, s, ctx.HeadE, x, y, p.EyeW, p.EyeH, p.EyeD, p.EyeOut)
		end
	end)
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
		local col = color
		if ctx.Sheen then
			-- Secret pets: an iridescent hue drift from the root to the tip of the wing
			col = ctx.Sheen(color, x)
		end
		return blobCF(ctx, name, sd(s, frame * scaled), V3(size.X * ws, size.Y * ws, size.Z * ws), col, o)
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

-- Layered feather panels: five broad flight feathers fanned out + two rows of shorter coverts over them.
WINGS.Feather = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	k.part(CF(0.14, 0.02, 0), V3(0.5, 0.42, 0.22), darken(W, 0.06), { Node = root, Mesh = true })
	local angles = { 0.96, 0.64, 0.34, 0.06, -0.22 }
	local lens = { 0.92, 1.22, 1.42, 1.36, 1.06 }
	for i = 1, 5 do
		local a = angles[i]
		local len = lens[i]
		local c = 0.14 + len / 2
		local n = k.joint(root, 0, 0, 0.09, i * 0.4)
		local col = mix(W, darken(W, 0.16), (i - 1) / 4)
		local o = { Node = n, Mesh = true }
		if i == 1 then
			o.Material = edgeMat(ctx)
		end
		k.part(CF(math.cos(a) * c, math.sin(a) * c, 0.03 * i) * A(0, 0, a), V3(len, 0.44, 0.08), col, o)
	end
	local cov = { 0.72, 0.2 }
	local covLen = { 0.7, 0.76 }
	for i = 1, 2 do
		local a = cov[i]
		local c = 0.12 + covLen[i] / 2
		k.part(CF(math.cos(a) * c, math.sin(a) * c, -0.07) * A(0, 0, a), V3(covLen[i], 0.42, 0.08), lighten(W, 0.22),
			{ Node = root, Mesh = true })
	end
end

-- Bat wing: bony arm, three finger spars and overlapping membrane panels in between.
WINGS.Bat = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	local bone = darken(W, 0.34)
	local skin = lighten(W, 0.06)
	-- arm (root, named Wing)
	k.part(CF(0.52, 0.05, 0) * A(0, 0, 0.12), V3(1.0, 0.16, 0.16), bone, { Node = root, Mesh = true })
	-- trailing membrane towards the body
	k.part(CF(0.46, -0.34, -0.01) * A(0, 0, -0.1), V3(1.0, 0.7, 0.05), skin, { Node = root, Mesh = true })
	-- wrist joint: fingers + their membranes bend a little
	local wx, wy = 1.0, 0.12
	local wrist = k.joint(root, wx, wy, 0.14, 0.9)
	local ang = { 0.95, 0.42, -0.1 }
	local len = { 0.85, 1.1, 0.95 }
	for i = 1, 3 do
		local a = ang[i]
		local c = len[i] / 2
		local o = { Node = wrist, Mesh = true }
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
		k.part(CF(wx + math.cos(a) * c, wy + math.sin(a) * c, 0.01 * i) * A(0, 0, a), V3(memLen[i], 0.78, 0.05), skin,
			{ Node = wrist, Mesh = true })
	end
end

-- Fairy wings: two translucent pairs (big upper, small lower) with a brighter sheen inside.
WINGS.Fairy = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	k.part(CF(0.08, 0, 0), V3(0.28, 0.28, 0.16), mix(W, ctx.C.P, 0.3), { Node = root, Mesh = true })
	local up = k.joint(root, 0, 0, 0.1, 0.5)
	local low = k.joint(root, 0, 0, 0.1, 1.5)
	k.part(CF(0.86, 0.5, 0) * A(0, 0, 0.55), V3(1.5, 0.95, 0.05), W, { Node = up, Transparency = 0.4, Mesh = true })
	k.part(CF(0.76, 0.43, -0.02) * A(0, 0, 0.55), V3(0.95, 0.5, 0.04), lighten(W, 0.5),
		{ Node = up, Transparency = 0.34, Material = edgeMat(ctx), Mesh = true })
	k.part(CF(0.62, -0.38, 0) * A(0, 0, -0.5), V3(1.02, 0.66, 0.05), W, { Node = low, Transparency = 0.4, Mesh = true })
	k.part(CF(0.56, -0.34, -0.02) * A(0, 0, -0.5), V3(0.62, 0.34, 0.04), lighten(W, 0.5),
		{ Node = low, Transparency = 0.34, Material = edgeMat(ctx), Mesh = true })
end

-- Cloud wings: a fluffy scalloped cloud - a bright row of puffs on top, a softly shaded row underneath,
-- all overlapping, that rolls in a soft wave as it flaps.
WINGS.Cloud = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	local top = lighten(W, 0.1)
	local hi = lighten(W, 0.3)
	local shade = mix(W, ctx.C.S, 0.45)
	-- shoulder puff (named WingR / WingL) and its shaded underside
	k.part(CF(0.3, 0.06, 0), V3(0.62, 0.62, 0.62), W, { Node = root })
	k.part(CF(0.42, -0.26, 0.08), V3(0.46, 0.46, 0.46), shade, { Node = root })
	-- middle of the wing
	local j2 = k.joint(root, 0.5, 0.1, 0.12, 0.8)
	k.part(CF(0.82, 0.3, 0.02), V3(0.76, 0.76, 0.76), top, { Node = j2 })
	k.part(CF(0.9, -0.12, 0.1), V3(0.54, 0.54, 0.54), shade, { Node = j2 })
	k.part(CF(0.58, 0.6, 0.08), V3(0.42, 0.42, 0.42), hi, { Node = j2 })
	-- wing tip curls up
	local j3 = k.joint(j2, 1.05, 0.3, 0.16, 1.6)
	k.part(CF(1.32, 0.58, 0.04), V3(0.64, 0.64, 0.64), top, { Node = j3, Material = edgeMat(ctx) })
	k.part(CF(1.4, 0.18, 0.12), V3(0.44, 0.44, 0.44), shade, { Node = j3 })
	if canAfford(ctx, 1) then
		k.part(CF(1.7, 0.86, 0.06), V3(0.4, 0.4, 0.4), hi, { Node = j3 })
	end
end

-- Crystal wings: angled translucent shards, each a chunky prism rod with a glowing tip.
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
		if i <= 3 then
			local tip = 0.18 + l + 0.08
			k.part(CF(math.cos(a) * tip, math.sin(a) * tip, 0.02 * i) * A(0, 0, a + PI / 4), V3(0.42, 0.42, 0.2),
				lighten(W, 0.4), { Node = n, Material = NEON, Transparency = 0.3 })
		end
	end
end

-- Flame wings: orange tongues of translucent Neon with brighter cores that flicker.
WINGS.Flame = function(ctx, p, s, frame, root)
	local k = wingKit(ctx, p, s, frame, root)
	local W = ctx.C.W
	k.part(CF(0.1, 0, 0), V3(0.38, 0.34, 0.2), W, { Node = root, Material = NEON, Transparency = 0.1, Mesh = true })
	local ang = { 1.0, 0.6, 0.2, -0.2 }
	local len = { 0.9, 1.3, 1.45, 1.1 }
	for i = 1, 4 do
		local a = ang[i]
		local l = len[i]
		local c = 0.16 + l / 2
		local n = k.joint(root, 0, 0, 0.12, i * 0.55)
		k.part(CF(math.cos(a) * c, math.sin(a) * c, 0.02 * i) * A(0, 0, a), V3(l, 0.44, 0.07), W,
			{ Node = n, Material = NEON, Transparency = 0.3, Mesh = true })
		if i <= 3 then
			local cl = l * 0.62
			local cc = 0.16 + cl / 2
			k.part(CF(math.cos(a) * cc, math.sin(a) * cc, 0.02 * i - 0.04) * A(0, 0, a), V3(cl, 0.2, 0.06), lighten(W, 0.55),
				{ Node = n, Material = NEON, Transparency = 0.12, Mesh = true })
		end
	end
end

-- Parts each wing style needs (both wings), so the builder can reserve room for them before the extras.
local WING_PARTS = { Feather = 16, Bat = 16, Fairy = 10, Cloud = 16, Crystal = 16, Flame = 16 }

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
local ACCESSORY_PARTS = { Horns = 4, Crown = 7, Halo = 8, Leaf = 3, Mushroom = 5, Scarf = 4, Antlers = 8, Flower = 6 }

local function headTop(ctx)
	return ctx.HC + V3(0, ctx.HA.Y, 0)
end

-- Two curved gold horns growing out of the top of the head (two segments each: base + lighter tip).
ACCESSORIES.Horns = function(ctx, p)
	local theta = math.asin(clamp(p.AccessoryX / ctx.HA.X, -0.9, 0.9))
	pair(function(s)
		local root = headPoint(ctx, theta, 0.86)
		local frame = growFrame(root, V3(0.32, 1, 0.34), 0)
		blobCF(ctx, "Horn" .. sname(s), sd(s, frame * CF(0, 0.16, 0)), V3(0.26, 0.48, 0.26), GOLD, { Mesh = true })
		local tipFrame = frame * CF(0, 0.36, 0) * A(-0.35, 0, 0.18)
		blobCF(ctx, "HornTip" .. sname(s), sd(s, tipFrame * CF(0, 0.1, 0)), V3(0.16, 0.34, 0.16), GOLD_LIGHT, { Mesh = true })
	end)
end

ACCESSORIES.Crown = function(ctx, p)
	local top = headTop(ctx)
	local base = top + V3(0, -0.06, -0.04)
	local band = cylCF(ctx, "CrownBand", CF(base), 0.96, 0.24, GOLD, { Material = SMOOTH })
	for i = 0, 4 do
		local a = i * TAU / 5
		blob(ctx, "CrownPoint" .. (i + 1), base + V3(math.sin(a) * 0.4, 0.2, math.cos(a) * 0.4), V3(0.18, 0.34, 0.18), GOLD_LIGHT,
			nil, { Mesh = true })
	end
	blob(ctx, "CrownJewel", base + V3(0, 0.0, -0.48), V3(0.16, 0.16, 0.1), rgb(232, 84, 112), nil, { Material = NEON, Mesh = true })
	return band
end

ACCESSORIES.Halo = function(ctx, p)
	local top = headTop(ctx) + V3(0, 0.48, 0.05)
	local n = newNode(ctx, { Kind = "bob", Hinge = CF(top), Axis = "z", Amp = 0.07, Amp2 = 0.05, Axis2 = "x", Rate = 1.2 })
	local r = 0.56
	local tilt = A(-0.3, 0, 0.06)
	for i = 0, 7 do
		local a = i * TAU / 8
		local pos = top + tilt * V3(math.sin(a) * r, 0, math.cos(a) * r)
		-- each segment is tangent to the ring and long enough to overlap its neighbours
		local tang = tilt * V3(math.cos(a), 0, -math.sin(a))
		blobCF(ctx, "Halo" .. (i + 1), CF(pos) * aim(tang, UP), V3(0.11, 0.1, 0.52), rgb(255, 236, 160), { Node = n, Material = NEON, Mesh = true })
	end
end

ACCESSORIES.Leaf = function(ctx, p)
	local top = headTop(ctx) + V3(0, -0.06, -0.04)
	local n = newNode(ctx, { Kind = "sway", Hinge = CF(top), Axis = "z", Amp = 0.1, Axis2 = "x", Amp2 = 0.07, Lag2 = 1.0, Rate = 1.2 })
	blob(ctx, "LeafStem", top + V3(0, 0.14, 0), V3(0.07, 0.36, 0.07), darken(LEAF, 0.25), nil, { Node = n, Mesh = true })
	blob(ctx, "LeafA", top + V3(0.24, 0.32, 0), V3(0.56, 0.12, 0.3), LEAF, A(0, 0, 0.5), { Node = n, Mesh = true })
	blob(ctx, "LeafB", top + V3(-0.2, 0.3, -0.02), V3(0.46, 0.1, 0.26), LEAF_LIGHT, A(0, 0, -0.55), { Node = n, Mesh = true })
end

ACCESSORIES.Mushroom = function(ctx, p)
	local top = headTop(ctx) + V3(0.0, -0.08, 0.02)
	blob(ctx, "ShroomStem", top + V3(0, 0.12, 0), V3(0.3, 0.34, 0.3), CREAM, nil, { Mesh = true })
	local capCF = CF(top + V3(0, 0.32, 0))
	local capSize = V3(0.86, 0.46, 0.86)
	blobCF(ctx, "ShroomCap", capCF, capSize, CAP, { Mesh = true })
	-- white dots flush on the cap (the cap seen from above: front = up)
	local capE = ell(capCF * A(PI / 2, 0, 0), V3(capSize.X, capSize.Z, capSize.Y))
	local dots = { { 0.2, -0.14, 0.08 }, { -0.2, -0.1, 0.07 }, { 0.02, 0.2, 0.08 } }
	for i = 1, 3 do
		local d = dots[i]
		overlay(ctx, "ShroomDot" .. i, capE, d[1], d[2], d[3], d[3], rgb(252, 244, 230), { Lift = 0.01 })
	end
end

ACCESSORIES.Scarf = function(ctx, p)
	local hc, ha = ctx.HC, ctx.HA
	local neck = V3(hc.X, hc.Y - ha.Y * 0.74, hc.Z + 0.06)
	blob(ctx, "ScarfRing", neck, V3(1.46, 0.3, 1.26), SCARF, nil, { Mesh = true })
	blob(ctx, "ScarfStripe", neck + V3(0, -0.02, 0), V3(1.48, 0.07, 1.28), SCARF_STRIPE, nil, { Mesh = true })
	local n = newNode(ctx, { Kind = "sway", Hinge = CF(0.36, neck.Y - 0.05, -0.5), Axis = "x", Amp = 0.12, Axis2 = "z", Amp2 = 0.08, Lag2 = 1.0, Rate = 1.2 })
	blob(ctx, "ScarfEnd", V3(0.4, neck.Y - 0.3, -0.5), V3(0.3, 0.62, 0.12), SCARF, A(0.12, 0, 0.12), { Node = n, Mesh = true })
	blob(ctx, "ScarfEndStripe", V3(0.4, neck.Y - 0.44, -0.51), V3(0.31, 0.07, 0.13), SCARF_STRIPE, A(0.12, 0, 0.12), { Node = n, Mesh = true })
end

ACCESSORIES.Antlers = function(ctx, p)
	local col = rgb(232, 206, 154)
	local tipMat = SMOOTH
	if ctx.Glow then
		tipMat = NEON
	end
	local theta = math.asin(clamp(p.AccessoryX / ctx.HA.X, -0.9, 0.9))
	pair(function(s)
		local base = headPoint(ctx, theta, 0.84)
		local n = newNode(ctx, { Kind = "ear", Hinge = sd(s, CF(base)), Axis = "z", Amp = 0.03, Side = s, Phase = s })
		local rot = A(0.1, 0, -0.3)
		local r1 = rot * A(0, 0, -0.85) -- lower prong flares outwards
		local r2 = rot * A(0.6, 0, 0.5) -- upper prong points forward and in
		blobS(ctx, s, "Antler", base + rot * V3(0, 0.38, 0), V3(0.16, 0.9, 0.16), col, rot, { Node = n, Mesh = true })
		blobS(ctx, s, "AntlerProng1", base + rot * V3(0, 0.3, 0) + r1 * V3(0, 0.2, 0), V3(0.12, 0.44, 0.12), col, r1, { Node = n, Mesh = true })
		blobS(ctx, s, "AntlerProng2", base + rot * V3(0, 0.58, 0) + r2 * V3(0, 0.17, 0), V3(0.11, 0.36, 0.11), col, r2, { Node = n, Mesh = true })
		blobS(ctx, s, "AntlerTip", base + rot * V3(0, 0.86, 0), V3(0.17, 0.22, 0.17), lighten(col, 0.35), rot, { Node = n, Material = tipMat, Mesh = true })
	end)
end

ACCESSORIES.Flower = function(ctx, p)
	local cols = { ctx.C.W, rgb(250, 208, 224), CREAM, rgb(196, 182, 250) }
	-- choose the petal colour that stands out most against the head
	local best, bestD = cols[1], -1
	for i = 1, #cols do
		local c = cols[i]
		local dr, dg, db = c.R - ctx.C.P.R, c.G - ctx.C.P.G, c.B - ctx.C.P.B
		local d = dr * dr + dg * dg + db * db
		if d > bestD then
			best, bestD = c, d
		end
	end
	-- five petals + a golden heart tucked behind the right ear, flush on the head
	local x, y = headXY(ctx, 0.95, 0.62)
	local frame = surfaceFrame(ctx.HeadE, x, y)
	local centre = ctx.HeadE.CF * frame
	for i = 0, 4 do
		local a = i * TAU / 5 + 0.3
		blobCF(ctx, "Petal" .. (i + 1), centre * CF(math.cos(a) * 0.17, math.sin(a) * 0.17, -0.02) * A(0, 0, a),
			V3(0.24, 0.2, 0.1), best, { Mesh = true })
	end
	blobCF(ctx, "FlowerCore", centre * CF(0, 0, -0.06), V3(0.16, 0.16, 0.12), rgb(250, 216, 104), { Mesh = true })
end

----------------------------------------------------------------------
-- Rarity flair
----------------------------------------------------------------------
-- Legendary and Mythic pets get a soft sparkle emitter (low rate) and a few little glints that orbit them;
-- Secret pets get four-point sparkle stars on a tilted orbit and an iridescent emitter. The orbiting
-- pieces are real parts so the flair also shows in ViewportFrames, which do not draw particles.
local FLAIR = {
	Legendary = { Rate = 3, Gems = 2, A = rgb(255, 226, 140), B = rgb(255, 190, 90) },
	Mythic = { Rate = 5, Gems = 3, A = rgb(255, 214, 236), B = rgb(190, 226, 255) },
	Secret = { Rate = 6, Stars = 3 },
}
local FLAIR_PARTS = { Legendary = 2, Mythic = 3, Secret = 6 }

local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

local function addEmitter(ctx, rate, colors)
	local k = ctx.Scale
	local e = Instance.new("ParticleEmitter")
	e.Name = "RarityGlow"
	e.Texture = SPARKLE
	e.Rate = rate
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
	local keys = {}
	for i = 1, #colors do
		keys[i] = ColorSequenceKeypoint.new((i - 1) / math.max(#colors - 1, 1), colors[i])
	end
	if #keys == 1 then
		keys[2] = ColorSequenceKeypoint.new(1, colors[1])
	end
	e.Color = ColorSequence.new(keys)
	e.Parent = ctx.Head
	return e
end

-- Iridescent trio derived from the pet's own palette (used by Secret pets).
local function iridescent(ctx)
	local base = ctx.C.S
	return {
		hueShift(base, 0, 0.45, 0.85),
		hueShift(base, 0.33, 0.45, 0.85),
		hueShift(base, 0.66, 0.45, 0.85),
	}
end

local function addFlair(ctx, rarity)
	local f = FLAIR[rarity]
	if not f or not ctx.Head then
		return
	end
	local hinge = CF(0, 0.5, 0.1)
	if f.Gems then
		for i = 1, f.Gems do
			local phase = (i - 1) * TAU / f.Gems
			local n = newNode(ctx, { Kind = "orbit", Hinge = hinge, Axis = "y", Phase = phase, Rate = 0.8 + i * 0.13, Amp = 0.12 })
			local col = f.A
			if i % 2 == 0 then
				col = f.B
			end
			-- Each glint gets its own height and its orbit phase baked into the rest pose (nodeMotion only adds
			-- the running angle), so a pet that is never Animated (the lobby mascot statue) still shows them
			-- spread evenly round the body instead of stacked on one side.
			local y = 0.35 + (i - 1) * 0.5
			local rest = hinge * A(0, phase, 0) * hinge:Inverse() * CF(1.8, y, 0.1)
			blobCF(ctx, "Gem" .. i, rest * A(0, 0, 0.35), V3(0.14, 0.3, 0.14), col, { Node = n, Material = NEON, Transparency = 0.05, Mesh = true })
		end
		addEmitter(ctx, f.Rate, { f.A, f.B })
	elseif f.Stars then
		local cols = iridescent(ctx)
		local tilt = A(0.32, 0, -0.18)
		for i = 1, f.Stars do
			local phase = (i - 1) * TAU / f.Stars
			local n = newNode(ctx, { Kind = "orbit", Hinge = hinge * tilt, Axis = "y", Phase = phase, Rate = 0.7, Amp = 0.1 })
			local y = 0.25 + ((i - 1) % 2) * 0.35
			local rest = hinge * tilt * A(0, phase, 0) * CF(1.75, y, 0) * A(0, -phase, 0) * tilt:Inverse()
			local col = cols[i] or cols[1]
			-- a four-point sparkle: two thin crossed glints
			blobCF(ctx, "Star" .. i, rest * A(0, 0, 0.2), V3(0.08, 0.46, 0.08), col, { Node = n, Material = NEON, Mesh = true })
			blobCF(ctx, "Star" .. i .. "X", rest * A(0, 0, 0.2 + PI / 2), V3(0.07, 0.3, 0.07), lighten(col, 0.4), { Node = n, Material = NEON, Mesh = true })
		end
		addEmitter(ctx, f.Rate, { cols[1], cols[2], cols[3] })
	end
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
	local eyes = {}
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
			local blink = inst:GetAttribute("PB_Blink")
			if blink == "squash" or blink == "hide" then
				eyes[#eyes + 1] = { Part = inst, Size = inst.Size, Hide = blink == "hide", T0 = inst.Transparency }
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

-- Blink: the eyeballs squash to a slit (they are sunk in the face, so this reads as closing lids) and the
-- iris / highlights hide for the middle of the blink.
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
				if k > 0.3 then
					part.Transparency = 1
				else
					part.Transparency = e.T0
				end
			else
				part.Size = V3(e.Size.X, e.Size.Y * (1 - 0.88 * k), e.Size.Z)
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
		if type(petDef.Rarity) == "string" then
			rarity = petDef.Rarity
		end
	end
	local seed = hashString(id .. look.Species)
	local ctx = newContext(look, scale, seed)
	ctx.Model.Name = "Pet_" .. id

	-- room the always-built pieces still need, so optional details never push a pet over the budget
	ctx.Reserve = (WING_PARTS[look.WingStyle] or 16) + (FLAIR_PARTS[rarity] or 0) + 10
	if look.Accessory then
		ctx.Reserve = ctx.Reserve + (ACCESSORY_PARTS[look.Accessory] or 6)
	end
	if rarity == "Secret" then
		-- iridescent sheen: wing parts drift through the pet's accent hues from root to tip
		local cols = iridescent(ctx)
		ctx.Sheen = function(color, x)
			local t = clamp(x / 1.8, 0, 1)
			local target = cols[2]
			if t > 0.5 then
				target = cols[3]
			end
			return mix(color, target, 0.18 + 0.3 * t)
		end
	end

	local profile = makeProfile(look.Species)
	buildCore(ctx, profile, look.Species)
	SPECIES[look.Species](ctx, profile)
	ctx.Reserve = ctx.Reserve - 10
	buildFaceEyes(ctx, profile)
	ctx.Reserve = (FLAIR_PARTS[rarity] or 0)
	if look.Accessory then
		ctx.Reserve = ctx.Reserve + (ACCESSORY_PARTS[look.Accessory] or 6)
	end
	buildWings(ctx, profile, look.WingStyle)
	ctx.Sheen = nil
	ctx.Reserve = FLAIR_PARTS[rarity] or 0
	if look.Accessory then
		ACCESSORIES[look.Accessory](ctx, profile)
	end
	ctx.Reserve = 0
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
