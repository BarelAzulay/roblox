-- Voxel: the detailed fine-voxel kit of Nimbus Climb (ARCHITECTURE_V3.md, "ART DIRECTION").
-- Models are SCULPTED from signed-distance-like shapes into an integer voxel grid, shaded (lighter tops,
-- darker undersides and creases), then greedily merged into as few box Parts as possible.
-- Usable on the server, on the client and inside ViewportFrames. Plain Lua 5.1-compatible syntax only.
--
--   Voxel.NewGrid(resolution) -> grid          resolution = voxels per model height (informative; Build can use it)
--   Voxel.Shape(grid, shape) -> changed        sculpt one shape (see "Shapes" below)
--   Voxel.Shade(grid, opts) -> nLight, nDark   <key>_Light on exposed tops, <key>_Dark on undersides / creases
--   Voxel.Merge(grid, opts) -> boxes           the 3D greedy merge Build uses (opts.MaxParts = LOD, see Build)
--   Voxel.Build(grid, opts) -> Model, parts, boxes
--   Voxel.Box(parent, cframe, size, color, material, props) -> Part     one block, for world building
--
-- Extras: Voxel.Set / Get / Count / Bounds / Copy / Remap / Mirror / Hash / Lighten / Darken / BuildBoxes / MirrorBoxes
--
-- Coordinates: voxel (x, y, z) is the unit cube CENTRED on the integer point (x, y, z) (voxel units). Shapes are
-- given in voxel units too (fractions allowed); a voxel is filled when its centre lies inside the shape. Tips:
--   * an odd number of voxels across -> centre on an integer; an even number -> centre on .5
--   * round shapes (Ellipsoid, Capsule, Cone, Torus, Curve, RoundBox) are inflated by Bias = 0.25 voxel by
--     default, so a Radius of 3 gives a clean 7-voxel ball without single-voxel "nubs" at the poles.
--
-- Shapes: { Kind = ..., Key = paletteKey, Op = "Add" | "Carve" | "Paint", Rotation = CFrame, Pivot = point,
--           Pattern = fn(x, y, z, currentKey) -> key | nil (use Key) | false (skip this voxel),
--           OnlyKeys = key | {key = true} (Carve / Paint only touch these keys), KeepExisting = true (Add only fills
--           empty voxels), Bias = n }
--   Ellipsoid  Center, Radius (number or vector of radii)
--   Capsule    A, B, Radius [, RadiusB]            (tapered when RadiusB is given: Radius at A, RadiusB at B)
--   Box        Center, Size                         (full size; Bias 0)
--   RoundBox   Center, Size, Round (corner radius, default 1)
--   Cone       A (base centre), B (tip), Radius [, RadiusB = 0 (radius at B: a truncated cone when > 0)]
--   Torus      Center, Radius (ring), Thickness (tube) [, ThicknessB (taper along the arc), Arc = {from, to}
--              radians, measured from +X towards +Z]; the ring lies in the XZ plane (axis Y) before Rotation
--   Curve      Points = {p1, p2, ...} [, Radius, RadiusB (taper start -> end) | Radii = {r per point},
--              Smooth = true (Catmull-Rom through the points), Steps = 6 (segments per span)]
-- Points / vectors may be Vector3, {x, y, z} or {X =, Y =, Z =}. Rotation turns the shape about Pivot (default:
-- Center, or A / the first point).
--
-- Palette: { key = Color3 | { Color = Color3, Material = Enum.Material, Transparency = n, Reflectance = n } }.
-- A missing <key>_Light / <key>_Dark entry is derived from <key> (about 15% lighter / darker; shadows lean a
-- little cool, highlights a little warm).
--
-- Merging: same-key voxels become boxes. Voxels completely enclosed by opaque voxels can never be seen, so any
-- opaque box may pass through them (fewer, bigger boxes; the surface is unchanged). Untextured opaque materials
-- (SmoothPlastic, Neon) may also overlap boxes of their own key. Translucent keys get exact, disjoint boxes.
-- If the result has more boxes than opts.MaxParts, nearly-equal shades are merged first (_Light / _Dark back
-- into their base colour, the patchiest ones first, then increasingly different colours) until it fits (LOD).

local Voxel = {}

local floor, ceil, sqrt, abs, max, min = math.floor, math.ceil, math.sqrt, math.abs, math.max, math.min
local atan2 = math.atan2 or function(y, x)
	return math.atan(y, x)
end
local PI = math.pi
local TAU = math.pi * 2

----------------------------------------------------------------------
-- Packed integer keys: one number per voxel (fast table keys, cheap neighbour offsets)
----------------------------------------------------------------------
local OFF = 1024 -- coordinates -1024 .. 1023 on every axis
local S = 2048
local S2 = S * S
local STR = { 1, S, S2 }

local function pack(x, y, z)
	return (x + OFF) + (y + OFF) * S + (z + OFF) * S2
end

local function unpack3(k)
	local z = floor(k / S2)
	local r = k - z * S2
	local y = floor(r / S)
	local x = r - y * S
	return x - OFF, y - OFF, z - OFF
end

Voxel.Pack = pack
Voxel.Unpack = unpack3

-- the 6 face neighbours
local FACE = { 1, -1, S, -S, S2, -S2 }

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
-- x, y, z of a Vector3 / {x, y, z} / {X =, Y =, Z =} / number (all three)
local function vec(v, dx, dy, dz)
	if v == nil then
		return dx or 0, dy or 0, dz or 0
	end
	if type(v) == "number" then
		return v, v, v
	end
	if type(v) == "table" and rawget(v, 1) ~= nil then
		return v[1] or 0, v[2] or 0, v[3] or 0
	end
	if type(v) == "table" and rawget(v, "x") ~= nil then
		return v.x or 0, v.y or 0, v.z or 0
	end
	return v.X, v.Y, v.Z
end

-- rotation matrix components of a CFrame (nil when there is no rotation)
local function rotationOf(cf)
	if cf == nil then
		return nil
	end
	local ok, _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = pcall(function()
		return cf:GetComponents()
	end)
	if not ok or r00 == nil then
		return nil
	end
	if r00 == 1 and r11 == 1 and r22 == 1 and r01 == 0 and r02 == 0 and r10 == 0 and r12 == 0 and r20 == 0 and r21 == 0 then
		return nil
	end
	return { r00, r01, r02, r10, r11, r12, r20, r21, r22 }
end

-- world = pivot + R * (p - pivot)
local function rotatePoint(R, px, py, pz, x, y, z)
	local dx, dy, dz = x - px, y - py, z - pz
	return px + R[1] * dx + R[2] * dy + R[3] * dz,
		py + R[4] * dx + R[5] * dy + R[6] * dz,
		pz + R[7] * dx + R[8] * dy + R[9] * dz
end

local function toSet(v)
	if v == nil then
		return nil
	end
	if type(v) == "string" then
		return { [v] = true }
	end
	if type(v) == "table" then
		if rawget(v, 1) ~= nil then
			local s = {}
			for _, k in ipairs(v) do
				s[k] = true
			end
			return s
		end
		return v
	end
	return nil
end

-- Deterministic hash of three integers (+ seed) -> [0, 1). Handy for patterns and noise.
function Voxel.Hash(x, y, z, seed)
	local h = (x * 73856093 + y * 19349663 + z * 83492791 + (seed or 0) * 2654435761) % 2147483647
	h = (h * 16807) % 2147483647
	h = (h * 16807) % 2147483647
	return h / 2147483647
end

----------------------------------------------------------------------
-- Colours
----------------------------------------------------------------------
local function clamp01(v)
	if v < 0 then
		return 0
	elseif v > 1 then
		return 1
	end
	return v
end

-- about 15% lighter by default, warm highlight
function Voxel.Lighten(c, t)
	t = t or 0.15
	return Color3.new(clamp01(c.R + (1 - c.R) * t), clamp01(c.G + (0.98 - c.G) * t), clamp01(c.B + (0.9 - c.B) * t * 0.9))
end

-- about 15% darker by default, slightly cool shadow
function Voxel.Darken(c, t)
	t = t or 0.15
	return Color3.new(clamp01(c.R * (1 - t * 1.05)), clamp01(c.G * (1 - t)), clamp01(c.B * (1 - t * 0.75)))
end

local function baseKeyOf(key)
	if type(key) ~= "string" then
		return key, nil
	end
	local b = key:match("^(.*)_Light$")
	if b then
		return b, "Light"
	end
	b = key:match("^(.*)_Dark$")
	if b then
		return b, "Dark"
	end
	return key, nil
end
Voxel.BaseKey = baseKeyOf

local DEFAULT_COLOR = nil -- created lazily (Color3 may not exist when this file is parsed by tools)
local SMOOTH = nil

-- Resolves a palette key into { Color, Material, Transparency, Reflectance } (cached per call site).
local function resolveStyle(palette, key, cache)
	local st = cache[key]
	if st then
		return st
	end
	local entry = palette and palette[key]
	if entry ~= nil then
		if typeof(entry) == "Color3" then
			st = { Color = entry, Material = SMOOTH, Transparency = 0 }
		elseif type(entry) == "table" then
			st = {
				Color = entry.Color or DEFAULT_COLOR,
				Material = entry.Material or SMOOTH,
				Transparency = tonumber(entry.Transparency) or 0,
				Reflectance = tonumber(entry.Reflectance),
			}
		end
	end
	if not st then
		local base, variant = baseKeyOf(key)
		if variant then
			local b = resolveStyle(palette, base, cache)
			local color = variant == "Light" and Voxel.Lighten(b.Color) or Voxel.Darken(b.Color)
			st = { Color = color, Material = b.Material, Transparency = b.Transparency, Reflectance = b.Reflectance }
		else
			st = { Color = DEFAULT_COLOR, Material = SMOOTH, Transparency = 0 }
		end
	end
	cache[key] = st
	return st
end

local function initEnums()
	if not DEFAULT_COLOR then
		DEFAULT_COLOR = Color3.fromRGB(200, 200, 205)
		SMOOTH = Enum.Material.SmoothPlastic
	end
end

----------------------------------------------------------------------
-- Grid
----------------------------------------------------------------------
function Voxel.NewGrid(resolution)
	return { Resolution = tonumber(resolution) or 32, Cells = {}, Count = 0 }
end

function Voxel.Set(grid, x, y, z, key)
	local k = pack(x, y, z)
	local cur = grid.Cells[k]
	if key == nil then
		if cur ~= nil then
			grid.Cells[k] = nil
			grid.Count = grid.Count - 1
		end
		return
	end
	if cur == nil then
		grid.Count = grid.Count + 1
	end
	grid.Cells[k] = key
end

function Voxel.Get(grid, x, y, z)
	return grid.Cells[pack(x, y, z)]
end

function Voxel.Count(grid)
	return grid.Count
end

-- minX, minY, minZ, maxX, maxY, maxZ (nil for an empty grid)
function Voxel.Bounds(grid)
	local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
	local any = false
	for k in pairs(grid.Cells) do
		local x, y, z = unpack3(k)
		any = true
		if x < x0 then x0 = x end
		if y < y0 then y0 = y end
		if z < z0 then z0 = z end
		if x > x1 then x1 = x end
		if y > y1 then y1 = y end
		if z > z1 then z1 = z end
	end
	if not any then
		return nil
	end
	return x0, y0, z0, x1, y1, z1
end

function Voxel.Copy(grid)
	local g = Voxel.NewGrid(grid.Resolution)
	for k, v in pairs(grid.Cells) do
		g.Cells[k] = v
	end
	g.Count = grid.Count
	return g
end

-- Renames keys: map = { oldKey = newKey | false (remove) }.
function Voxel.Remap(grid, map)
	local cells = grid.Cells
	for k, v in pairs(cells) do
		local to = map[v]
		if to == false then
			cells[k] = nil
			grid.Count = grid.Count - 1
		elseif to ~= nil then
			cells[k] = to
		end
	end
end

-- Mirrors one half of the grid onto the other across the plane axis = 0 (axis "X" | "Y" | "Z").
-- keep = 1 copies the positive half onto the negative one (default), -1 the other way round.
function Voxel.Mirror(grid, axis, keep)
	keep = (keep == -1) and -1 or 1
	local cells = grid.Cells
	local new = {}
	local count = 0
	for k, v in pairs(cells) do
		local x, y, z = unpack3(k)
		local c = (axis == "Y" and y) or (axis == "Z" and z) or x
		if c * keep >= 0 then
			new[k] = v
			count = count + 1
			if c ~= 0 then
				local mk
				if axis == "Y" then
					mk = pack(x, -y, z)
				elseif axis == "Z" then
					mk = pack(x, y, -z)
				else
					mk = pack(-x, y, z)
				end
				new[mk] = v
				count = count + 1
			end
		end
	end
	grid.Cells = new
	grid.Count = count
end

----------------------------------------------------------------------
-- Sculpting
----------------------------------------------------------------------
local OP_ADD, OP_CARVE, OP_PAINT = 1, 2, 3

-- The per-voxel write shared by every shape kind. Returns 1 when the voxel changed.
local function makeWriter(grid, shape)
	local cells = grid.Cells
	local op = OP_ADD
	if shape.Op == "Carve" then
		op = OP_CARVE
	elseif shape.Op == "Paint" then
		op = OP_PAINT
	end
	local key = shape.Key
	local pattern = shape.Pattern
	if type(pattern) ~= "function" then
		pattern = nil
	end
	local only = toSet(shape.OnlyKeys)
	local keep = shape.KeepExisting == true
	local changed = 0
	local function write(x, y, z)
		local k = (x + OFF) + (y + OFF) * S + (z + OFF) * S2
		local cur = cells[k]
		if op == OP_CARVE then
			if cur ~= nil and (not only or only[cur]) then
				cells[k] = nil
				grid.Count = grid.Count - 1
				changed = changed + 1
			end
			return
		end
		if op == OP_PAINT then
			if cur == nil or (only and not only[cur]) then
				return
			end
		elseif keep and cur ~= nil then
			return
		end
		local v = key
		if pattern then
			local p = pattern(x, y, z, cur)
			if p == false then
				return
			elseif p ~= nil then
				v = p
			end
		end
		if v == nil or v == cur then
			return
		end
		if cur == nil then
			grid.Count = grid.Count + 1
		end
		cells[k] = v
		changed = changed + 1
	end
	return write, function()
		return changed
	end
end

-- Iterates the integer voxels of an AABB and writes those whose centre is inside (inside(lx, ly, lz) gets
-- the sample point in the shape's unrotated frame).
local function rasterize(write, bx0, by0, bz0, bx1, by1, bz1, R, pvx, pvy, pvz, inside)
	local x0, y0, z0 = ceil(bx0 - 1e-6), ceil(by0 - 1e-6), ceil(bz0 - 1e-6)
	local x1, y1, z1 = floor(bx1 + 1e-6), floor(by1 + 1e-6), floor(bz1 + 1e-6)
	if R then
		-- local = pivot + R^T (p - pivot)
		local r00, r01, r02, r10, r11, r12, r20, r21, r22 = R[1], R[2], R[3], R[4], R[5], R[6], R[7], R[8], R[9]
		for z = z0, z1 do
			local dz = z - pvz
			for y = y0, y1 do
				local dy = y - pvy
				for x = x0, x1 do
					local dx = x - pvx
					local lx = pvx + r00 * dx + r10 * dy + r20 * dz
					local ly = pvy + r01 * dx + r11 * dy + r21 * dz
					local lz = pvz + r02 * dx + r12 * dy + r22 * dz
					if inside(lx, ly, lz) then
						write(x, y, z)
					end
				end
			end
		end
	else
		for z = z0, z1 do
			for y = y0, y1 do
				for x = x0, x1 do
					if inside(x, y, z) then
						write(x, y, z)
					end
				end
			end
		end
	end
end

-- World AABB of a box of half extents (hx, hy, hz) centred on (cx, cy, cz) in the unrotated frame.
local function rotatedBounds(R, pvx, pvy, pvz, cx, cy, cz, hx, hy, hz)
	if not R then
		return cx - hx, cy - hy, cz - hz, cx + hx, cy + hy, cz + hz
	end
	local wx, wy, wz = rotatePoint(R, pvx, pvy, pvz, cx, cy, cz)
	local ex = abs(R[1]) * hx + abs(R[2]) * hy + abs(R[3]) * hz
	local ey = abs(R[4]) * hx + abs(R[5]) * hy + abs(R[6]) * hz
	local ez = abs(R[7]) * hx + abs(R[8]) * hy + abs(R[9]) * hz
	return wx - ex, wy - ey, wz - ez, wx + ex, wy + ey, wz + ez
end

-- One tapered capsule segment in world coordinates.
local function capsule(write, ax, ay, az, bx, by, bz, ra, rb, bias)
	local abx, aby, abz = bx - ax, by - ay, bz - az
	local len2 = abx * abx + aby * aby + abz * abz
	local rm = max(ra, rb) + bias
	local x0, y0, z0 = ceil(min(ax, bx) - rm - 1e-6), ceil(min(ay, by) - rm - 1e-6), ceil(min(az, bz) - rm - 1e-6)
	local x1, y1, z1 = floor(max(ax, bx) + rm + 1e-6), floor(max(ay, by) + rm + 1e-6), floor(max(az, bz) + rm + 1e-6)
	local dr = rb - ra
	for z = z0, z1 do
		local pz = z - az
		for y = y0, y1 do
			local py = y - ay
			for x = x0, x1 do
				local px = x - ax
				local t = 0
				if len2 > 1e-9 then
					t = (px * abx + py * aby + pz * abz) / len2
					if t < 0 then
						t = 0
					elseif t > 1 then
						t = 1
					end
				end
				local qx, qy, qz = px - abx * t, py - aby * t, pz - abz * t
				local r = ra + dr * t + bias
				if qx * qx + qy * qy + qz * qz <= r * r then
					write(x, y, z)
				end
			end
		end
	end
end

-- Catmull-Rom samples through the control points; returns parallel arrays of points and radii.
local function curveSamples(pts, radii, steps, smooth)
	local n = #pts
	local outP, outR = {}, {}
	if n == 1 or not smooth then
		for i = 1, n do
			outP[i] = pts[i]
			outR[i] = radii[i]
		end
		return outP, outR
	end
	for i = 1, n - 1 do
		local p0 = pts[max(1, i - 1)]
		local p1 = pts[i]
		local p2 = pts[i + 1]
		local p3 = pts[min(n, i + 2)]
		local r1, r2 = radii[i], radii[i + 1]
		local first = (i == 1) and 0 or 1
		for s = first, steps do
			local t = s / steps
			local t2, t3 = t * t, t * t * t
			local a = -0.5 * t3 + t2 - 0.5 * t
			local b = 1.5 * t3 - 2.5 * t2 + 1
			local c = -1.5 * t3 + 2 * t2 + 0.5 * t
			local d = 0.5 * t3 - 0.5 * t2
			outP[#outP + 1] = {
				a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1],
				a * p0[2] + b * p1[2] + c * p2[2] + d * p3[2],
				a * p0[3] + b * p1[3] + c * p2[3] + d * p3[3],
			}
			outR[#outR + 1] = r1 + (r2 - r1) * t
		end
	end
	return outP, outR
end

local KINDS = {}

KINDS.Ellipsoid = function(shape, write, R, bias)
	local cx, cy, cz = vec(shape.Center)
	local rx, ry, rz = vec(shape.Radius or 1)
	rx, ry, rz = max(rx, 0.01) + bias, max(ry, 0.01) + bias, max(rz, 0.01) + bias
	local pvx, pvy, pvz = vec(shape.Pivot, cx, cy, cz)
	local ix, iy, iz = 1 / (rx * rx), 1 / (ry * ry), 1 / (rz * rz)
	local x0, y0, z0, x1, y1, z1
	if R then
		-- exact AABB of a rotated ellipsoid
		local wx, wy, wz = rotatePoint(R, pvx, pvy, pvz, cx, cy, cz)
		local ex = sqrt((R[1] * rx) ^ 2 + (R[2] * ry) ^ 2 + (R[3] * rz) ^ 2)
		local ey = sqrt((R[4] * rx) ^ 2 + (R[5] * ry) ^ 2 + (R[6] * rz) ^ 2)
		local ez = sqrt((R[7] * rx) ^ 2 + (R[8] * ry) ^ 2 + (R[9] * rz) ^ 2)
		x0, y0, z0, x1, y1, z1 = wx - ex, wy - ey, wz - ez, wx + ex, wy + ey, wz + ez
	else
		x0, y0, z0, x1, y1, z1 = cx - rx, cy - ry, cz - rz, cx + rx, cy + ry, cz + rz
	end
	rasterize(write, x0, y0, z0, x1, y1, z1, R, pvx, pvy, pvz, function(x, y, z)
		local dx, dy, dz = x - cx, y - cy, z - cz
		return dx * dx * ix + dy * dy * iy + dz * dz * iz <= 1
	end)
end

KINDS.Box = function(shape, write, R, bias)
	local cx, cy, cz = vec(shape.Center)
	local sx, sy, sz = vec(shape.Size or 1)
	local hx, hy, hz = sx * 0.5 + bias - 1e-4, sy * 0.5 + bias - 1e-4, sz * 0.5 + bias - 1e-4
	local pvx, pvy, pvz = vec(shape.Pivot, cx, cy, cz)
	local x0, y0, z0, x1, y1, z1 = rotatedBounds(R, pvx, pvy, pvz, cx, cy, cz, hx, hy, hz)
	rasterize(write, x0, y0, z0, x1, y1, z1, R, pvx, pvy, pvz, function(x, y, z)
		return abs(x - cx) <= hx and abs(y - cy) <= hy and abs(z - cz) <= hz
	end)
end

KINDS.RoundBox = function(shape, write, R, bias)
	local cx, cy, cz = vec(shape.Center)
	local sx, sy, sz = vec(shape.Size or 1)
	local hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
	local r = tonumber(shape.Round) or 1
	r = max(0, min(r, hx, hy, hz))
	local ix, iy, iz = hx - r, hy - r, hz - r
	local pvx, pvy, pvz = vec(shape.Pivot, cx, cy, cz)
	local x0, y0, z0, x1, y1, z1 = rotatedBounds(R, pvx, pvy, pvz, cx, cy, cz, hx + bias, hy + bias, hz + bias)
	local lim = r + bias - 1e-4
	rasterize(write, x0, y0, z0, x1, y1, z1, R, pvx, pvy, pvz, function(x, y, z)
		local qx, qy, qz = abs(x - cx) - ix, abs(y - cy) - iy, abs(z - cz) - iz
		local ox, oy, oz = max(qx, 0), max(qy, 0), max(qz, 0)
		local d = sqrt(ox * ox + oy * oy + oz * oz) + min(max(qx, qy, qz), 0)
		return d <= lim
	end)
end

KINDS.Torus = function(shape, write, R, bias)
	local cx, cy, cz = vec(shape.Center)
	local ring = tonumber(shape.Radius) or 4
	local th = tonumber(shape.Thickness) or 1
	local thB = tonumber(shape.ThicknessB) or th
	local pvx, pvy, pvz = vec(shape.Pivot, cx, cy, cz)
	local a0, a1 = nil, nil
	if type(shape.Arc) == "table" then
		a0, a1 = tonumber(shape.Arc[1]) or 0, tonumber(shape.Arc[2]) or TAU
	end
	local tm = max(th, thB) + bias
	local x0, y0, z0, x1, y1, z1 = rotatedBounds(R, pvx, pvy, pvz, cx, cy, cz, ring + tm, tm, ring + tm)
	rasterize(write, x0, y0, z0, x1, y1, z1, R, pvx, pvy, pvz, function(x, y, z)
		local dx, dy, dz = x - cx, y - cy, z - cz
		local u = 0
		if a0 then
			local ang = atan2(dz, dx)
			local rel = (ang - a0) % TAU
			local span = a1 - a0
			if rel > span + 1e-9 then
				return false
			end
			if span > 1e-9 then
				u = rel / span
			end
		end
		local q = sqrt(dx * dx + dz * dz) - ring
		local t = th + (thB - th) * u + bias
		return q * q + dy * dy <= t * t
	end)
end

KINDS.Cone = function(shape, write, R, bias)
	local ax, ay, az = vec(shape.A)
	local bx, by, bz = vec(shape.B, ax, ay + 4, az)
	local pvx, pvy, pvz = vec(shape.Pivot, ax, ay, az)
	if R then
		ax, ay, az = rotatePoint(R, pvx, pvy, pvz, ax, ay, az)
		bx, by, bz = rotatePoint(R, pvx, pvy, pvz, bx, by, bz)
	end
	local ra = tonumber(shape.Radius) or 2
	local rb = tonumber(shape.RadiusB) or 0
	local abx, aby, abz = bx - ax, by - ay, bz - az
	local len2 = abx * abx + aby * aby + abz * abz
	if len2 < 1e-9 then
		return
	end
	local rm = max(ra, rb) + bias
	rasterize(write, min(ax, bx) - rm, min(ay, by) - rm, min(az, bz) - rm, max(ax, bx) + rm, max(ay, by) + rm, max(az, bz) + rm, nil, 0, 0, 0, function(x, y, z)
		local px, py, pz = x - ax, y - ay, z - az
		local t = (px * abx + py * aby + pz * abz) / len2
		if t < -1e-6 or t > 1 + 1e-6 then
			return false
		end
		local qx, qy, qz = px - abx * t, py - aby * t, pz - abz * t
		local r = ra + (rb - ra) * t + bias
		return qx * qx + qy * qy + qz * qz <= r * r
	end)
end

KINDS.Capsule = function(shape, write, R, bias)
	local ax, ay, az = vec(shape.A)
	local bx, by, bz = vec(shape.B, ax, ay, az)
	local pvx, pvy, pvz = vec(shape.Pivot, ax, ay, az)
	if R then
		ax, ay, az = rotatePoint(R, pvx, pvy, pvz, ax, ay, az)
		bx, by, bz = rotatePoint(R, pvx, pvy, pvz, bx, by, bz)
	end
	local ra = tonumber(shape.Radius) or 1
	local rb = tonumber(shape.RadiusB) or ra
	capsule(write, ax, ay, az, bx, by, bz, ra, rb, bias)
end

KINDS.Curve = function(shape, write, R, bias)
	local src = shape.Points
	if type(src) ~= "table" or #src == 0 then
		return
	end
	local pts = {}
	for i = 1, #src do
		local x, y, z = vec(src[i])
		pts[i] = { x, y, z }
	end
	local pvx, pvy, pvz = vec(shape.Pivot, pts[1][1], pts[1][2], pts[1][3])
	if R then
		for i = 1, #pts do
			local p = pts[i]
			p[1], p[2], p[3] = rotatePoint(R, pvx, pvy, pvz, p[1], p[2], p[3])
		end
	end
	local radii = {}
	local n = #pts
	local r0 = tonumber(shape.Radius) or 1
	local r1 = tonumber(shape.RadiusB) or r0
	for i = 1, n do
		if type(shape.Radii) == "table" and tonumber(shape.Radii[i]) then
			radii[i] = tonumber(shape.Radii[i])
		elseif n > 1 then
			radii[i] = r0 + (r1 - r0) * (i - 1) / (n - 1)
		else
			radii[i] = r0
		end
	end
	local steps = max(1, floor(tonumber(shape.Steps) or 6))
	local sp, sr = curveSamples(pts, radii, steps, shape.Smooth ~= false)
	if #sp == 1 then
		local p = sp[1]
		capsule(write, p[1], p[2], p[3], p[1], p[2], p[3], sr[1], sr[1], bias)
		return
	end
	for i = 1, #sp - 1 do
		local a, b = sp[i], sp[i + 1]
		capsule(write, a[1], a[2], a[3], b[1], b[2], b[3], sr[i], sr[i + 1], bias)
	end
end

local DEFAULT_BIAS = { Ellipsoid = 0.25, Capsule = 0.25, Cone = 0.25, Torus = 0.25, Curve = 0.25, RoundBox = 0.25, Box = 0 }

-- Sculpts one shape into the grid. Returns the number of voxels that changed.
function Voxel.Shape(grid, shape)
	if type(grid) ~= "table" or type(shape) ~= "table" then
		return 0
	end
	local kind = KINDS[shape.Kind or "Ellipsoid"]
	if not kind then
		warn("[Voxel] unknown shape kind " .. tostring(shape.Kind))
		return 0
	end
	local bias = tonumber(shape.Bias) or DEFAULT_BIAS[shape.Kind or "Ellipsoid"] or 0
	local write, changed = makeWriter(grid, shape)
	kind(shape, write, rotationOf(shape.Rotation), bias)
	return changed()
end

----------------------------------------------------------------------
-- Shading
----------------------------------------------------------------------
-- Offsets of the normal estimator: every neighbour within 2 voxels (weighted 1/d^2).
-- The same neighbourhood measures "openness": the share of it that is empty (about 0.32 on a flat surface,
-- more on convex bumps, much less in concave creases).
local NEIGH26 = {}
do
	for dz = -1, 1 do
		for dy = -1, 1 do
			for dx = -1, 1 do
				if dx ~= 0 or dy ~= 0 or dz ~= 0 then
					NEIGH26[#NEIGH26 + 1] = dx + dy * S + dz * S2
				end
			end
		end
	end
end
local NORMAL_K, NORMAL_X, NORMAL_Y, NORMAL_Z = {}, {}, {}, {}
local NORMAL_TOTAL = 0
do
	for dz = -2, 2 do
		for dy = -2, 2 do
			for dx = -2, 2 do
				local d2 = dx * dx + dy * dy + dz * dz
				if d2 > 0 and d2 <= 4.1 then
					NORMAL_TOTAL = NORMAL_TOTAL + 1
					NORMAL_K[NORMAL_TOTAL] = dx + dy * S + dz * S2
					NORMAL_X[NORMAL_TOTAL] = dx / d2
					NORMAL_Y[NORMAL_TOTAL] = dy / d2
					NORMAL_Z[NORMAL_TOTAL] = dz / d2
				end
			end
		end
	end
end

-- Assigns shade variants. opts (all optional):
--   LightDir = vector (default straight up), LightAt = 0.55 (normal . LightDir at or above -> _Light),
--   DarkAt = -0.35 (at or below -> _Dark), Crease = 0.22 (exposed voxels whose 2-voxel neighbourhood is at most
--   this empty sit in a crease -> _Dark; a flat surface is ~0.31), Light = false / Dark = false (disable one),
--   Smooth = 2 (passes that give isolated voxels the shade of their neighbours: cleaner bands, fewer parts),
--   Skip = {key = true} | {key, ...} (never shaded, e.g. eyes), Only = keys to shade,
--   Noise = 0..1 (fraction of voxels nudged one shade up / down, deterministic), Seed = n
function Voxel.Shade(grid, opts)
	opts = opts or {}
	local cells = grid.Cells
	local lx, ly, lz = vec(opts.LightDir, 0, 1, 0)
	local ll = sqrt(lx * lx + ly * ly + lz * lz)
	if ll < 1e-6 then
		lx, ly, lz, ll = 0, 1, 0, 1
	end
	lx, ly, lz = lx / ll, ly / ll, lz / ll
	local lightAt = tonumber(opts.LightAt) or 0.55
	local darkAt = tonumber(opts.DarkAt) or -0.35
	local crease = tonumber(opts.Crease) or 0.22
	local useLight = opts.Light ~= false
	local useDark = opts.Dark ~= false
	local passes = tonumber(opts.Smooth) or 2
	local skip = toSet(opts.Skip) or {}
	local only = toSet(opts.Only)
	local noise = tonumber(opts.Noise) or 0
	local seed = tonumber(opts.Seed) or 0
	local shadeable = {} -- per key: may it be shaded?
	local OK, OX, OY, OZ = NORMAL_K, NORMAL_X, NORMAL_Y, NORMAL_Z

	-- 1) shade of every exposed voxel from its estimated normal and how open its neighbourhood is
	local shade = {}
	local list = {}
	for k, v in pairs(cells) do
		local can = shadeable[v]
		if can == nil then
			local _, variant = baseKeyOf(v)
			can = not variant and not skip[v] and (not only or only[v]) and true or false
			shadeable[v] = can
		end
		if can then
			local exposed = false
			for i = 1, 6 do
				if cells[k + FACE[i]] == nil then
					exposed = true
					break
				end
			end
			if exposed then
				local nx, ny, nz = 0, 0, 0
				local empty = 0
				for i = 1, NORMAL_TOTAL do
					if cells[k + OK[i]] == nil then
						nx, ny, nz = nx + OX[i], ny + OY[i], nz + OZ[i]
						empty = empty + 1
					end
				end
				local nl = sqrt(nx * nx + ny * ny + nz * nz)
				local sh = 0
				if nl > 1e-6 then
					local d = (nx * lx + ny * ly + nz * lz) / nl
					if d >= lightAt and useLight then
						sh = 1
					elseif d <= darkAt and useDark then
						sh = -1
					end
				end
				if empty / NORMAL_TOTAL <= crease and useDark then
					sh = -1
				end
				shade[k] = sh
				list[#list + 1] = k
			end
		end
	end
	table.sort(list)

	-- 2) smoothing: a voxel that agrees with fewer than 2 of its same-colour surface neighbours takes their
	--    most common shade (Jacobi passes, so the result does not depend on iteration order)
	for _ = 1, passes do
		local nextShade = {}
		local changed = false
		for i = 1, #list do
			local k = list[i]
			local v = cells[k]
			local own = shade[k]
			local same, cl, c0, cd = 0, 0, 0, 0
			for j = 1, 26 do
				local nk = k + NEIGH26[j]
				local ns = shade[nk]
				if ns ~= nil and cells[nk] == v then
					if ns == own then
						same = same + 1
					end
					if ns > 0 then
						cl = cl + 1
					elseif ns < 0 then
						cd = cd + 1
					else
						c0 = c0 + 1
					end
				end
			end
			local new = own
			if same < 2 and cl + c0 + cd > 0 then
				if c0 >= cl and c0 >= cd then
					new = 0
				elseif cl >= cd then
					new = 1
				else
					new = -1
				end
			end
			nextShade[k] = new
			if new ~= own then
				changed = true
			end
		end
		shade = nextShade
		if not changed then
			break
		end
	end

	-- 3) optional speckle, then write the variants
	local nLight, nDark = 0, 0
	for i = 1, #list do
		local k = list[i]
		local sh = shade[k]
		if noise > 0 then
			local x, y, z = unpack3(k)
			local h = Voxel.Hash(x, y, z, seed)
			if h < noise * 0.5 then
				sh = sh + 1
			elseif h < noise then
				sh = sh - 1
			end
			if sh > 1 or (sh > 0 and not useLight) then
				sh = useLight and 1 or 0
			elseif sh < -1 or (sh < 0 and not useDark) then
				sh = useDark and -1 or 0
			end
		end
		if sh > 0 then
			cells[k] = cells[k] .. "_Light"
			nLight = nLight + 1
		elseif sh < 0 then
			cells[k] = cells[k] .. "_Dark"
			nDark = nDark + 1
		end
	end
	return nLight, nDark
end

----------------------------------------------------------------------
-- Greedy merge
----------------------------------------------------------------------
-- growth orders tried per box (the best one wins); two orders get within ~1% of all six at a third of the cost
local ORDERS = { { 2, 1, 3 }, { 1, 3, 2 } }
local BRIDGE_CELLS = 160 -- zero-gain cells a growing box may look through after its last gain

-- Opacity / overlap rules from the palette (no palette: everything opaque and overlappable).
local function makeRules(palette)
	initEnums()
	local cache = {}
	local opaque, overlap = {}, {}
	local NEON = Enum.Material.Neon
	local function info(key)
		local o = opaque[key]
		if o == nil then
			if palette then
				local st = resolveStyle(palette, key, cache)
				o = (st.Transparency or 0) <= 0.001
				overlap[key] = o and (st.Material == SMOOTH or st.Material == NEON)
			else
				o = true
				overlap[key] = true
			end
			opaque[key] = o
		end
		return o, overlap[key]
	end
	return info, cache
end

-- The voxels a merge must cover (sorted, so the result is deterministic) and the hidden ones (opaque voxels
-- boxed in by opaque voxels on all 6 faces). Key remaps of the LOD keep opacity, so this is computed once.
local function prepare(cells, info)
	local hidden = {}
	local list = {}
	local n = 0
	for k, v in pairs(cells) do
		local enclosed = false
		if info(v) then
			enclosed = true
			for f = 1, 6 do
				local nv = cells[k + FACE[f]]
				if nv == nil or not info(nv) then
					enclosed = false
					break
				end
			end
		end
		if enclosed then
			hidden[k] = true
		else
			n = n + 1
			list[n] = k
		end
	end
	table.sort(list)
	return { List = list, Hidden = hidden }
end

local function mergeCells(cells, info, prep)
	prep = prep or prepare(cells, info)
	local orders = ORDERS
	local list = prep.List
	local n = #list
	local hidden = prep.Hidden

	local covered = {}
	local boxes = {}
	local lo, hi = { 0, 0, 0 }, { 0, 0, 0 }
	local bestLo, bestHi = { 0, 0, 0 }, { 0, 0, 0 }
	local key, canHidden, canOverlap

	-- Grows the current box (lo / hi) along one axis in both directions, one slab at a time, while every voxel
	-- of the new slab is acceptable (same key and not yet covered, or covered and overlappable, or hidden and
	-- the key is opaque). Trailing slabs that added nothing are trimmed again. Bridging through hidden or covered
	-- voxels is allowed for a limited number of looked-at cells after the last useful slab (long thin bridges
	-- are cheap and often pay off; huge empty faces rarely do). Returns the number of newly covered voxels.
	-- (The slab scan is written out inline: this is the hot loop of every voxel model.)
	local function growAxis(axis)
		local a, b
		if axis == 1 then
			a, b = 2, 3
		elseif axis == 2 then
			a, b = 1, 3
		else
			a, b = 1, 2
		end
		local sa, sb, sc = STR[a], STR[b], STR[axis]
		local a0, a1, b0, b1 = lo[a], hi[a], lo[b], hi[b]
		local cost = (a1 - a0 + 1) * (b1 - b0 + 1)
		local k, hid, cov, cel = key, hidden, covered, cells
		local okHidden, okOverlap = canHidden, canOverlap
		local gained = 0
		local ends = { lo[axis], hi[axis] }
		local last = { ends[1], ends[2] }
		for dir = 1, 2 do
			local step = (dir == 1) and -1 or 1
			local c = ends[dir]
			local idle = 0
			while true do
				local nc = c + step
				local base = (nc + OFF) * sc
				local gain = 0
				local ok = true
				for i = a0, a1 do
					local row = base + (i + OFF) * sa
					for j = b0, b1 do
						local p = row + (j + OFF) * sb
						local v = cel[p]
						if v == k then
							if hid[p] then
								if not okHidden then
									ok = false
									break
								end
							elseif cov[p] then
								if not okOverlap then
									ok = false
									break
								end
							else
								gain = gain + 1
							end
						elseif not (okHidden and v ~= nil and hid[p]) then
							ok = false
							break
						end
					end
					if not ok then
						break
					end
				end
				if not ok then
					break
				end
				c = nc
				if gain > 0 then
					last[dir] = c
					gained = gained + gain
					idle = 0
				else
					idle = idle + cost
					if idle > BRIDGE_CELLS then
						break
					end
				end
			end
		end
		lo[axis], hi[axis] = last[1], last[2]
		return gained
	end

	for i = 1, n do
		local k = list[i]
		if not covered[k] then
			key = cells[k]
			local o, ov = info(key)
			canHidden = o
			canOverlap = ov
			local sx, sy, sz = unpack3(k)
			local best = -1
			for oi = 1, #orders do
				local order = orders[oi]
				lo[1], lo[2], lo[3] = sx, sy, sz
				hi[1], hi[2], hi[3] = sx, sy, sz
				local gain = 1 + growAxis(order[1]) + growAxis(order[2]) + growAxis(order[3])
				if gain > best then
					best = gain
					bestLo[1], bestLo[2], bestLo[3] = lo[1], lo[2], lo[3]
					bestHi[1], bestHi[2], bestHi[3] = hi[1], hi[2], hi[3]
				end
			end
			-- claim the box
			for z = bestLo[3], bestHi[3] do
				for y = bestLo[2], bestHi[2] do
					local row = (y + OFF) * S + (z + OFF) * S2 + OFF
					for x = bestLo[1], bestHi[1] do
						local p = row + x
						if cells[p] == key and not hidden[p] then
							covered[p] = true
						end
					end
				end
			end
			boxes[#boxes + 1] = {
				X0 = bestLo[1], Y0 = bestLo[2], Z0 = bestLo[3],
				X1 = bestHi[1], Y1 = bestHi[2], Z1 = bestHi[3],
				Key = key, Count = best,
			}
		end
	end
	return boxes
end

-- Copy of cells with keys renamed through map (keys missing in map stay).
local function remapped(cells, map)
	local out = {}
	for k, v in pairs(cells) do
		out[k] = map[v] or v
	end
	return out
end

-- Colour-cluster LOD tier: keys whose colours are within `tol` (and share material / transparency) collapse
-- into the key with the most voxels.
local function clusterMap(cells, palette, cache, tol)
	local counts = {}
	for _, v in pairs(cells) do
		counts[v] = (counts[v] or 0) + 1
	end
	local keys = {}
	for v in pairs(counts) do
		keys[#keys + 1] = v
	end
	table.sort(keys, function(a, b)
		if counts[a] ~= counts[b] then
			return counts[a] > counts[b]
		end
		return tostring(a) < tostring(b)
	end)
	local reps = {}
	local map = {}
	for _, v in ipairs(keys) do
		local st = resolveStyle(palette, v, cache)
		local target = nil
		for _, r in ipairs(reps) do
			local rs = r.St
			if rs.Material == st.Material and abs((rs.Transparency or 0) - (st.Transparency or 0)) < 0.05 then
				local c1, c2 = rs.Color, st.Color
				local d = sqrt((c1.R - c2.R) ^ 2 + (c1.G - c2.G) ^ 2 + (c1.B - c2.B) ^ 2)
				if d <= tol then
					target = r.Key
					break
				end
			end
		end
		if target then
			map[v] = target
		else
			reps[#reps + 1] = { Key = v, St = st }
		end
	end
	return map
end

-- The greedy merge (see the header). opts: Palette (opacity, overlap and colours for the LOD), MaxParts,
-- Keep = {key = true} | {key, ...} (keys the LOD never recolours, e.g. eyes). Returns { {X0, Y0, Z0, X1, Y1, Z1,
-- Key, Count}, ... } with inclusive voxel ranges.
function Voxel.Merge(grid, opts)
	opts = opts or {}
	local cells = grid.Cells or grid
	local palette = opts.Palette
	local info, cache = makeRules(palette)
	local prep = prepare(cells, info)
	local boxes = mergeCells(cells, info, prep)
	local maxParts = tonumber(opts.MaxParts)
	if not maxParts or #boxes <= maxParts then
		return boxes
	end
	local keep = toSet(opts.Keep) or {}
	local work = cells

	-- LOD step 1: fold shade variants back into their base colour, the least efficient ones first (the most
	-- boxes per voxel: small scattered shade patches go before the broad highlight on top of a head), a few
	-- keys at a time, until the estimated saving covers the overshoot.
	for _ = 1, 6 do
		local nBoxes, nVox = {}, {}
		for _, b in ipairs(boxes) do
			nBoxes[b.Key] = (nBoxes[b.Key] or 0) + 1
		end
		for _, v in pairs(work) do
			nVox[v] = (nVox[v] or 0) + 1
		end
		local cands = {}
		for key, nb in pairs(nBoxes) do
			local base, variant = baseKeyOf(key)
			if variant and not keep[key] then
				cands[#cands + 1] = { Key = key, Base = base, Boxes = nb, Ratio = nb / max(nVox[key] or 1, 1) }
			end
		end
		if #cands == 0 then
			break
		end
		table.sort(cands, function(a, b)
			if a.Ratio ~= b.Ratio then
				return a.Ratio > b.Ratio
			end
			return a.Key < b.Key
		end)
		local need = (#boxes - maxParts) * 1.25
		local saved = 0
		local map = {}
		for _, c in ipairs(cands) do
			map[c.Key] = c.Base
			saved = saved + c.Boxes * 0.5
			if saved >= need then
				break
			end
		end
		work = remapped(work, map)
		boxes = mergeCells(work, info, prep)
		if #boxes <= maxParts then
			return boxes
		end
	end

	-- LOD step 2: ever more different colours together (same material and transparency only)
	if palette then
		for _, tol in ipairs({ 0.06, 0.12, 0.2, 0.3, 0.45 }) do
			local map = clusterMap(work, palette, cache, tol)
			for k in pairs(keep) do
				map[k] = nil
			end
			if next(map) ~= nil then
				work = remapped(work, map)
				boxes = mergeCells(work, info, prep)
				if #boxes <= maxParts then
					return boxes
				end
			end
		end
	end
	return boxes
end

----------------------------------------------------------------------
-- Parts
----------------------------------------------------------------------
-- Mirrors a box list across x = 0 (exact mirror image of the parts, unlike merging a mirrored grid).
function Voxel.MirrorBoxes(boxes)
	local out = {}
	for i, b in ipairs(boxes) do
		out[i] = { X0 = -b.X1, X1 = -b.X0, Y0 = b.Y0, Y1 = b.Y1, Z0 = b.Z0, Z1 = b.Z1, Key = b.Key, Count = b.Count }
	end
	return out
end

local function applyCommon(part, opts)
	part.Anchored = opts.Anchored ~= false
	part.CanCollide = opts.CanCollide == true
	part.CanTouch = opts.CanTouch == true
	part.CanQuery = opts.CanQuery == true
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

-- Creates the parts of a box list. Same opts as Build (VoxelSize, Palette, CFrame, Offset, Anchored, ...);
-- opts.Model = an existing Model to add to. Returns model, parts (parts[i] is boxes[i]).
function Voxel.BuildBoxes(boxes, opts)
	initEnums()
	opts = opts or {}
	local vs = tonumber(opts.VoxelSize) or 1
	local palette = opts.Palette or {}
	local cache = {}
	local origin = opts.CFrame or opts.Origin or CFrame.new()
	local ox, oy, oz = vec(opts.Offset, 0, 0, 0)
	local shadowSize = tonumber(opts.ShadowSize) or 4
	local unique = opts.UniqueNames == true
	local nameOf = opts.NameOf
	local model = opts.Model
	if not model then
		model = Instance.new("Model")
		model.Name = opts.Name or "Voxels"
	end
	local used = {}
	local parts = {}
	for i, b in ipairs(boxes) do
		local st = resolveStyle(palette, b.Key, cache)
		local sx, sy, sz = (b.X1 - b.X0 + 1) * vs, (b.Y1 - b.Y0 + 1) * vs, (b.Z1 - b.Z0 + 1) * vs
		local cx = ((b.X0 + b.X1) * 0.5 - ox) * vs
		local cy = ((b.Y0 + b.Y1) * 0.5 - oy) * vs
		local cz = ((b.Z0 + b.Z1) * 0.5 - oz) * vs
		local part = Instance.new("Part")
		local name = nil
		if type(nameOf) == "function" then
			name = nameOf(b.Key, b)
		end
		if type(name) ~= "string" then
			name = tostring((baseKeyOf(b.Key)))
		end
		if unique then
			local c = (used[name] or 0) + 1
			used[name] = c
			if c > 1 then
				name = name .. c
			end
		end
		part.Name = name
		applyCommon(part, opts)
		if opts.CastShadow ~= nil then
			part.CastShadow = opts.CastShadow == true
		else
			part.CastShadow = max(sx, sy, sz) >= shadowSize
		end
		part.Material = st.Material or SMOOTH
		part.Color = st.Color or DEFAULT_COLOR
		part.Transparency = st.Transparency or 0
		if st.Reflectance then
			part.Reflectance = st.Reflectance
		end
		part.Size = Vector3.new(sx, sy, sz)
		part.CFrame = origin * CFrame.new(cx, cy, cz)
		part.Parent = model
		parts[i] = part
	end
	return model, parts
end

-- Builds a Model of box Parts from the grid. opts:
--   VoxelSize = studs per voxel (default: opts.Height / grid.Resolution, else 1)
--   Palette = { key -> Color3 | {Color, Material, Transparency, Reflectance} }
--   Name, Parent, CFrame (where voxel 0,0,0 sits; default identity), Offset = voxel point placed at the CFrame,
--   Center = true (Offset = the centre of the grid's bounds), Anchored (default true), CanCollide / CanTouch /
--   CanQuery (default false), CastShadow (default: only parts >= ShadowSize = 4 studs), UniqueNames,
--   NameOf = fn(key, box) -> name, PrimaryKey (PrimaryPart = the biggest part of that key; default: biggest
--   part), MaxParts + Keep (LOD, see Merge)
-- Returns model, parts, boxes.
function Voxel.Build(grid, opts)
	initEnums()
	opts = opts or {}
	local o = {}
	for k, v in pairs(opts) do
		o[k] = v
	end
	if not tonumber(o.VoxelSize) then
		local h = tonumber(o.Height)
		if h and grid.Resolution and grid.Resolution > 0 then
			o.VoxelSize = h / grid.Resolution
		else
			o.VoxelSize = 1
		end
	end
	if o.Center and o.Offset == nil then
		local x0, y0, z0, x1, y1, z1 = Voxel.Bounds(grid)
		if x0 then
			o.Offset = { (x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5 }
		end
	end
	local boxes = Voxel.Merge(grid, { Palette = o.Palette, MaxParts = o.MaxParts, Keep = o.Keep })
	local parent = o.Parent
	o.Parent = nil
	local model, parts = Voxel.BuildBoxes(boxes, o)
	-- PrimaryPart: the biggest part (of PrimaryKey when given)
	local best, bestVol = nil, -1
	for i, part in ipairs(parts) do
		local b = boxes[i]
		local base = baseKeyOf(b.Key)
		if o.PrimaryKey == nil or base == o.PrimaryKey or b.Key == o.PrimaryKey then
			local vol = (b.X1 - b.X0 + 1) * (b.Y1 - b.Y0 + 1) * (b.Z1 - b.Z0 + 1)
			if vol > bestVol then
				best, bestVol = part, vol
			end
		end
	end
	if not best and parts[1] then
		best = parts[1]
	end
	if best then
		model.PrimaryPart = best
	end
	if parent then
		model.Parent = parent
	end
	return model, parts, boxes
end

-- One block for world building. cframe: CFrame (or Vector3 position); size: Vector3 (or number for a cube).
-- Defaults: Anchored, CanCollide / CanTouch / CanQuery false, SmoothPlastic, CastShadow only when >= 4 studs.
-- props: any Part properties to override (e.g. { CanCollide = true, Name = "Path", Transparency = 0.4 }).
function Voxel.Box(parent, cframe, size, color, material, props)
	initEnums()
	local part = Instance.new("Part")
	part.Name = "Voxel"
	applyCommon(part, {})
	if type(size) == "number" then
		size = Vector3.new(size, size, size)
	end
	if size == nil then
		size = Vector3.new(1, 1, 1)
	end
	part.Size = size
	part.CastShadow = max(size.X, size.Y, size.Z) >= 4
	part.Material = material or SMOOTH
	if color then
		part.Color = color
	end
	if cframe ~= nil then
		if typeof(cframe) == "Vector3" then
			part.CFrame = CFrame.new(cframe)
		else
			part.CFrame = cframe
		end
	end
	if type(props) == "table" then
		for k, v in pairs(props) do
			local ok, err = pcall(function()
				part[k] = v
			end)
			if not ok then
				warn("[Voxel] Box: cannot set " .. tostring(k) .. ": " .. tostring(err))
			end
		end
	end
	if parent then
		part.Parent = parent
	end
	return part
end

return Voxel
