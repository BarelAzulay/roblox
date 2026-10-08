-- LobbyBuilder: procedurally builds the Nimbus Climb cloud village at Config.Lobby.Origin.
--
-- Layout (top view, +Z is "up" the page, plaza centre = Config.Lobby.Origin):
--   * a big round plaza cloud with a puffy rim, a gold/rainbow medallion and three paths
--   * three portal gates on the portal ring (Breeze / Gale / Thunderstorm), 120 degrees apart
--   * a neon rainbow arch spanning the walkway to the first portal
--   * a welcome sign, a how-to-play board, benches, lantern trees, flowers and lamp posts
--   * six floating islands (bench / tree / pond / flowers / token showcase) joined to the
--     plaza by stepped cloud bridges
--   * drifting decorative clouds, a non-collidable sea of clouds far below, fireflies
--
-- No external assets: Parts, ParticleEmitters (built-in textures) and Theme-styled GUI text.
-- Plain Lua 5.1-compatible syntax only. Everything is deterministic (seeded Random).

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

local ORIGIN = Config.Lobby.Origin
local TOP = ORIGIN.Y -- y of the plaza walking surface
local SURF_R = Config.Lobby.PlazaRadius + 6 -- the cloud disc reaches a bit past PlazaRadius
local PORTAL_R = Config.Lobby.PortalRingRadius
local SEED = 20240611

local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"
local C = Theme.Colors
local MAT = Enum.Material

local COL = {
	Cloud = C.Cloud,
	Shade = C.CloudShade,
	Lilac = Color3.fromRGB(228, 218, 248),
	Dusk = Color3.fromRGB(205, 205, 240),
	Peach = Color3.fromRGB(255, 230, 216),
	Pink = Color3.fromRGB(255, 208, 226),
	Sky = Color3.fromRGB(222, 238, 255),
	Wood = Color3.fromRGB(190, 138, 96),
	WoodLight = Color3.fromRGB(214, 164, 118),
	WoodDark = Color3.fromRGB(128, 88, 64),
	Stem = Color3.fromRGB(120, 205, 140),
	Lantern = Color3.fromRGB(255, 196, 112),
	Gold = C.Token,
	Navy = Color3.fromRGB(44, 52, 110),
	Violet = Color3.fromRGB(96, 74, 156),
	Post = Color3.fromRGB(86, 74, 128),
	Water = Color3.fromRGB(122, 196, 255),
	WaterBed = Color3.fromRGB(86, 158, 236),
}

local BLOSSOMS = {
	Color3.fromRGB(255, 190, 214),
	Color3.fromRGB(255, 214, 190),
	Color3.fromRGB(196, 236, 214),
	Color3.fromRGB(214, 200, 255),
}

local FLOWER_COLORS = {
	Color3.fromRGB(255, 160, 196),
	Color3.fromRGB(255, 214, 112),
	Color3.fromRGB(190, 168, 255),
	Color3.fromRGB(255, 150, 150),
	Color3.fromRGB(150, 210, 255),
	Color3.fromRGB(255, 236, 170),
}

-- Floating islands. Angle = direction from the plaza centre (degrees, x = cos, z = sin),
-- Distance = island centre distance, Radius = island radius, Dy = height of the island
-- surface relative to the plaza surface. Bridge steps rise at most ~1.5 studs each.
local ISLANDS = {
	{ Name = "Sunset Perch", Angle = 0, Distance = 122, Radius = 17, Dy = 6, Features = { "Bench", "Tree", "Flowers" } },
	{ Name = "Lily Pond", Angle = 60, Distance = 128, Radius = 15, Dy = -5, Features = { "Pond", "Tree", "Flowers" } },
	{ Name = "Token Garden", Angle = 120, Distance = 118, Radius = 14, Dy = 10, Features = { "Tokens", "Bench", "Flowers" } },
	{ Name = "Moonflower Meadow", Angle = 180, Distance = 125, Radius = 17, Dy = 3, Features = { "Bench", "Tree", "Flowers", "Flowers" } },
	{ Name = "Quiet Cove", Angle = 240, Distance = 130, Radius = 14, Dy = -7, Features = { "Pond", "Bench" } },
	{ Name = "Lantern Grove", Angle = 300, Distance = 120, Radius = 15, Dy = 8, Features = { "Tree", "Tree", "Bench" } },
}

-- Rainbow arch: vertical plane z = ORIGIN.Z + ARCH_Z, centred on the plaza's x.
local ARCH_Z = 48
local ARCH_R = 38

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

----------------------------------------------------------------------
-- Effects helpers
----------------------------------------------------------------------

local FADE_IN_OUT = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.25, 0.15),
	NumberSequenceKeypoint.new(0.75, 0.15),
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
	e.Color = ColorSequence.new(C.White)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Rate = 8
	e.Lifetime = NumberRange.new(1.5, 2.5)
	e.Speed = NumberRange.new(1, 2)
	e.Size = popSize(0.8)
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

-- Small floating name tag in the cosy "Script" font.
local function nameTag(anchor, text, offsetY, subText)
	local gui = Instance.new("BillboardGui")
	gui.Name = "NameTag"
	gui.Size = UDim2.new(0, 320, 0, 90)
	gui.StudsOffset = Vector3.new(0, offsetY, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 130
	gui.Adornee = anchor

	local top = Theme.Label(text, "Script", {
		Size = 32,
		Color = C.White,
		Props = { Size = UDim2.new(1, 0, 0.6, 0), Position = UDim2.new(0, 0, 0, 0) },
	})
	top.Parent = gui
	if subText then
		local sub = Theme.Label(subText, "Body", {
			Size = 20,
			Color = C.TokenGlow,
			Props = { Size = UDim2.new(1, 0, 0.4, 0), Position = UDim2.new(0, 0, 0.6, 0) },
		})
		sub.Parent = gui
	end
	gui.Parent = anchor
	return gui
end

local function surfaceGui(part, pixelsPerStud)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 40
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Adornee = part
	return gui
end

-- Navy -> violet rounded panel with a soft golden outline, filling the whole SurfaceGui.
local function signPanel(gui)
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.BackgroundColor3 = C.White -- UIGradient multiplies this, so it must be white
	panel.BorderSizePixel = 0
	Theme.Gradient(panel, COL.Navy, COL.Violet, 90)
	Theme.Corner(panel, UDim.new(0, 28))
	Theme.Stroke(panel, C.TokenGlow, 6, 0.2)
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

----------------------------------------------------------------------
-- Cloud helpers
----------------------------------------------------------------------

-- Flat-bottomed cumulus: one wide base disc plus overlapping domed puffs. `pos` is the centre
-- of the cluster's floor plane. opts: Puffs, Base, Color, Shade, Transparency, CanCollide.
-- Returns the list of parts (so callers can animate them together).
local function cloudCluster(parent, rng, pos, radius, opts)
	opts = opts or {}
	local color = opts.Color or COL.Cloud
	local shade = opts.Shade or COL.Shade
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

-- A ring of big puffs around a disc edge (soft rim). `center` is the surface centre; a puff's
-- crest pokes `crestMin..crestMax` studs above center.Y. Angles listed in `skip` stay open
-- (bridge entrances) within `skipHalf` degrees.
local function rimPuffs(parent, rng, center, ringR, count, dMin, dMax, crestMin, crestMax, color, skip, skipHalf)
	for i = 1, count do
		local ang = (i - 1) * (360 / count) + rng:Float(-4, 4)
		if not nearAny(ang, skip, skipHalf or 9) then
			local d = rng:Float(dMin, dMax)
			local r = ringR + rng:Float(-1, 1.5)
			local crest = rng:Float(crestMin, crestMax)
			local a = math.rad(ang)
			local pos = Vector3.new(
				center.X + math.cos(a) * r,
				center.Y + crest - d * 0.5,
				center.Z + math.sin(a) * r
			)
			ball(parent, pos, d, {
				Name = "RimPuff",
				Color = color:Lerp(COL.Shade, rng:Float(0, 0.2)),
			})
		end
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

-- Wooden bench built around a real Seat so players can sit. `cf` is at ground level;
-- its LookVector is the direction the sitter faces.
local function bench(parent, cf)
	local function part(name, offset, size, color, material, className)
		return mk(parent, {
			Name = name,
			CFrame = cf * CFrame.new(offset),
			Size = size,
			Color = color,
			Material = material or MAT.WoodPlanks,
		}, className)
	end
	part("BenchSeat", Vector3.new(0, 1.55, 0), Vector3.new(5.6, 0.45, 2.1), COL.Wood, MAT.WoodPlanks, "Seat")
	part("BenchBack", Vector3.new(0, 2.7, 0.95), Vector3.new(5.6, 1.7, 0.35), COL.WoodLight, MAT.WoodPlanks)
	part("BenchLegL", Vector3.new(-2.4, 0.65, 0), Vector3.new(0.5, 1.3, 1.9), COL.WoodDark, MAT.Wood)
	part("BenchLegR", Vector3.new(2.4, 0.65, 0), Vector3.new(0.5, 1.3, 1.9), COL.WoodDark, MAT.Wood)
	part("BenchArmL", Vector3.new(-2.65, 2.0, 0), Vector3.new(0.4, 0.5, 2.0), COL.WoodDark, MAT.Wood)
	part("BenchArmR", Vector3.new(2.65, 2.0, 0), Vector3.new(0.4, 0.5, 2.0), COL.WoodDark, MAT.Wood)
end

-- Blossom tree hung with glowing lanterns. `base` = ground position at the trunk.
local function lanternTree(parent, rng, base, scale, blossom, withLight)
	local h = 8.5 * scale
	disc(parent, base + Vector3.new(0, h * 0.5, 0), 1.5 * scale, h, {
		Name = "TreeTrunk",
		Color = COL.WoodDark,
		Material = MAT.Wood,
	})

	-- Canopy: one big crown ball plus a ring of smaller ones.
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
			Color = blossom:Lerp(C.White, rng:Float(0.1, 0.4)),
			CanCollide = false,
		})
	end
	emitter(crown, {
		Color = ColorSequence.new(blossom, C.White),
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
			pointLight(lantern, COL.Lantern, 0.9, 16)
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
		local color = rng:Pick(FLOWER_COLORS)
		disc(parent, pos + Vector3.new(0, h * 0.5, 0), 0.18, h, {
			Name = "FlowerStem",
			Color = COL.Stem,
			CanCollide = false,
		})
		ball(parent, pos + Vector3.new(0, h + 0.1, 0), rng:Float(0.8, 1.2), {
			Name = "FlowerBloom",
			Color = color,
			CanCollide = false,
		})
		if rng:Chance(0.35) then
			disc(parent, pos + Vector3.new(0, h - 0.05, 0), rng:Float(1.6, 2.2), 0.12, {
				Name = "FlowerPetals",
				Color = color:Lerp(C.White, 0.35),
				CanCollide = false,
			})
		end
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
		Reflectance = 0.15,
		CanCollide = false,
	})
	local stones = math.max(6, math.floor(math.pi * 2 * radius / 2.7))
	for i = 1, stones do
		local a = (i - 1) * (math.pi * 2 / stones) + rng:Float(-0.1, 0.1)
		ball(parent, ground + Vector3.new(math.cos(a) * (radius + 0.5), 0.3, math.sin(a) * (radius + 0.5)), rng:Float(1.8, 2.4), {
			Name = "PondStone",
			Color = COL.Cloud:Lerp(COL.Shade, rng:Float(0, 0.4)),
			CanCollide = false,
		})
	end
	for i = 1, 2 do
		local a = rng:Float(0, math.pi * 2)
		local rr = rng:Float(0.3, radius * 0.55)
		disc(parent, ground + Vector3.new(math.cos(a) * rr, 0.55, math.sin(a) * rr), rng:Float(1.4, 1.9), 0.08, {
			Name = "LilyPad",
			Color = Color3.fromRGB(116, 214, 140),
			CanCollide = false,
		})
	end
	ball(parent, ground + Vector3.new(radius * 0.25, 0.8, -radius * 0.2), 0.9, {
		Name = "Lotus",
		Color = COL.Pink,
		CanCollide = false,
	})
	emitter(water, {
		Rate = 3,
		Lifetime = NumberRange.new(2, 3),
		Speed = NumberRange.new(0.3, 0.8),
		Color = ColorSequence.new(Color3.fromRGB(190, 230, 255)),
		Size = popSize(0.6),
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
		pointLight(glow, COL.Lantern, 0.8, 18)
	end
end

-- Pedestal with three spinning, bobbing golden cloud tokens (decorative, NOT tagged).
local function tokenShowcase(parent, ground)
	local pedestal = disc(parent, ground + Vector3.new(0, 0.6, 0), 6.2, 1.2, {
		Name = "TokenPedestal",
		Color = COL.Cloud,
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
			Color = C.Token,
			Material = MAT.Neon,
			CanCollide = false,
		})
		later(function()
			loopTween(coin, spec.spin, { Orientation = Vector3.new(0, 360, 0) }, Enum.EasingStyle.Linear, false)
			loopTween(coin, spec.bob, { Position = pos + Vector3.new(0, 0.7, 0) }, Enum.EasingStyle.Sine, true)
		end)
	end
	emitter(pedestal, {
		Color = ColorSequence.new(C.TokenGlow),
		Rate = 5,
		Lifetime = NumberRange.new(2, 3),
		Speed = NumberRange.new(1.5, 3),
		Size = popSize(0.7),
	})

	-- Info card floating over the pedestal.
	local gui = Instance.new("BillboardGui")
	gui.Name = "TokenInfo"
	gui.Size = UDim2.new(0, 340, 0, 110)
	gui.StudsOffset = Vector3.new(0, 12, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = 130
	gui.Adornee = pedestal
	local title = Theme.Label("Cloud Tokens", "Title", {
		Size = 42,
		Color = C.Token,
		Props = { Size = UDim2.new(1, 0, 0.6, 0) },
	})
	title.Parent = gui
	local sub = Theme.Label("Collect them on the way up!", "Body", {
		Size = 22,
		Color = C.White,
		Props = { Size = UDim2.new(1, 0, 0.4, 0), Position = UDim2.new(0, 0, 0.6, 0) },
	})
	sub.Parent = gui
	gui.Parent = pedestal
end

----------------------------------------------------------------------
-- Plaza
----------------------------------------------------------------------

local function buildPlaza(root, portalAngles, bridgeAngles, portalDiffs)
	local f = newFolder(root, "Plaza")
	local rng = Util.NewRng(SEED + 1)
	local ox, oz = ORIGIN.X, ORIGIN.Z

	-- Walkable top disc.
	disc(f, Vector3.new(ox, TOP - 3, oz), SURF_R * 2, 6, {
		Name = "PlazaTop",
		Color = COL.Cloud,
		CastShadow = true,
	})

	-- Inverted-cone underside: shrinking, slightly translucent tiers hidden behind puffs.
	local tiers = {
		{ r = SURF_R * 0.9, th = 6, y = -9, color = Color3.fromRGB(240, 238, 252), trans = 0.04, puffs = 8 },
		{ r = SURF_R * 0.68, th = 7, y = -15.5, color = Color3.fromRGB(228, 222, 248), trans = 0.1, puffs = 6 },
		{ r = SURF_R * 0.44, th = 8, y = -23, color = Color3.fromRGB(216, 212, 244), trans = 0.18, puffs = 4 },
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
				Color = tier.color:Lerp(C.White, 0.4),
				Transparency = tier.trans,
				CanCollide = false,
			})
		end
	end

	-- Puffy rim (open where bridges leave the plaza).
	rimPuffs(f, rng, Vector3.new(ox, TOP, oz), SURF_R + 0.5, 27, 8, 12, 0.2, 1.4, COL.Cloud, bridgeAngles, 9)

	-- Soft pastel swirl patches on the ground so the plaza is not one flat white sheet.
	local patchColors = { COL.Lilac, COL.Peach, COL.Pink, COL.Sky }
	for _ = 1, 12 do
		local ang = rng:Float(0, 360)
		local rr = rng:Float(18, 68)
		local d = rng:Float(6, 13)
		local nearPad = rr > 48 and nearAny(ang, portalAngles, 16)
		if not nearPad then
			disc(f, polar(ang, rr, TOP + 0.03), d, 0.06, {
				Name = "GroundPatch",
				Color = rng:Pick(patchColors),
				CanCollide = false,
			})
		end
	end

	-- Central medallion: gold rim, lavender field, rainbow dots, golden core.
	local layers = {
		{ d = 27, color = COL.Gold },
		{ d = 25.4, color = COL.Lilac },
		{ d = 19, color = C.White },
		{ d = 17.6, color = COL.Gold },
		{ d = 16.6, color = COL.Peach },
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
			Color = C.Rainbow[i],
			Material = MAT.Neon,
			CanCollide = false,
		})
	end
	disc(f, Vector3.new(ox, TOP + stack + 0.1, oz), 5.4, 0.2, {
		Name = "MedallionCore",
		Color = COL.Gold,
		Material = MAT.Neon,
		CanCollide = false,
	})

	-- Paths from the medallion to each portal pad, with lamp posts alongside.
	for i, deg in ipairs(portalAngles) do
		local a = math.rad(deg)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
		local mid = polar(deg, 35, TOP + 0.08)
		local pcf = CFrame.lookAt(mid, mid + dir)
		local edgeColor = portalDiffs[i].Color:Lerp(C.White, 0.35)
		block(f, pcf, Vector3.new(6.4, 0.16, 42), { Name = "Path", Color = COL.Peach, CanCollide = false })
		block(f, pcf * CFrame.new(-3.45, 0.02, 0), Vector3.new(0.5, 0.2, 42), { Name = "PathEdge", Color = edgeColor, CanCollide = false })
		block(f, pcf * CFrame.new(3.45, 0.02, 0), Vector3.new(0.5, 0.2, 42), { Name = "PathEdge", Color = edgeColor, CanCollide = false })
		for _, r in ipairs({ 24, 40 }) do
			lampPost(f, Vector3.new(ox, TOP, oz) + dir * r + tangent * 5.2, false)
			lampPost(f, Vector3.new(ox, TOP, oz) + dir * r - tangent * 5.2, r == 24)
		end
	end

	-- Benches: two face their signs, one faces the lantern grove.
	local function benchAt(deg, r)
		local pos = polar(deg, r, TOP)
		bench(f, CFrame.lookAt(pos, polar(deg, r + 10, TOP)))
	end
	benchAt(20, 36)
	benchAt(160, 36)
	benchAt(270, 44)

	-- Lantern trees: a grove behind the spawn plus two flanking the signs.
	local treeSpots = { { 262, 60 }, { 278, 60 }, { 358, 62 }, { 184, 62 } }
	for i, spot in ipairs(treeSpots) do
		lanternTree(f, rng, polar(spot[1], spot[2], TOP), rng:Float(1.0, 1.2), BLOSSOMS[(i - 1) % #BLOSSOMS + 1], i <= 2)
	end

	-- Flower beds at the sign bases and in the grove.
	for _, signDeg in ipairs({ 20, 160 }) do
		local a = math.rad(signDeg)
		local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
		local c = polar(signDeg, 44, TOP)
		flowerPatch(f, rng, c + tangent * 11, 3.4, 4)
		flowerPatch(f, rng, c - tangent * 11, 3.4, 4)
	end
	flowerPatch(f, rng, polar(270, 52, TOP), 5, 9)

	-- Lobby fireflies drifting over the whole plaza.
	local flies = anchorPart(f, "Fireflies", Vector3.new(ox, TOP + 9, oz), Vector3.new(130, 16, 130))
	emitter(flies, {
		Color = ColorSequence.new(Color3.fromRGB(255, 244, 160), Color3.fromRGB(190, 255, 175)),
		Rate = 16,
		Lifetime = NumberRange.new(5, 9),
		Speed = NumberRange.new(0.3, 1.2),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, 0.2, 0),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.2, 0.55),
			NumberSequenceKeypoint.new(0.5, 0.25),
			NumberSequenceKeypoint.new(0.8, 0.55),
			NumberSequenceKeypoint.new(1, 0),
		}),
	})
end

----------------------------------------------------------------------
-- Rainbow arch
----------------------------------------------------------------------

local function buildRainbow(root)
	local f = newFolder(root, "Rainbow")
	local rng = Util.NewRng(SEED + 2)
	local centre = Vector3.new(ORIGIN.X, TOP - 1, ORIGIN.Z + ARCH_Z)
	local segments = 16

	-- Six concentric neon bands (red outermost), each made of thin rotated blocks.
	for band = 1, 6 do
		local r = ARCH_R - (band - 1) * 1.25
		local len = r * math.pi / segments * 1.12
		for k = 0, segments - 1 do
			local phi = (k + 0.5) * math.pi / segments
			local pos = centre + Vector3.new(math.cos(phi) * r, math.sin(phi) * r, 0)
			block(f, CFrame.new(pos) * CFrame.Angles(0, 0, phi + math.pi / 2), Vector3.new(len, 1.4, 3.2), {
				Name = "RainbowBand" .. band,
				Color = C.Rainbow[band],
				Material = MAT.Neon,
				Transparency = 0.08,
				CanCollide = false,
			})
		end
	end

	-- A cloud bank at each foot of the arch, sparkling gently.
	local footR = ARCH_R - 2.5
	for _, sx in ipairs({ -1, 1 }) do
		local parts = cloudCluster(f, rng, Vector3.new(ORIGIN.X + sx * footR, TOP - 0.5, ORIGIN.Z + ARCH_Z), 7.5, { Puffs = 6 })
		emitter(parts[1], {
			Color = ColorSequence.new(Color3.fromRGB(255, 240, 200), C.White),
			Rate = 6,
			Lifetime = NumberRange.new(2, 3.5),
			Speed = NumberRange.new(2, 4),
			Size = popSize(0.9),
		})
	end
end

----------------------------------------------------------------------
-- Portal gates
----------------------------------------------------------------------

local function buildPortal(root, rng, diff, angleDeg)
	local f = newFolder(root, "Portal_" .. diff.Id)
	local a = math.rad(angleDeg)
	local outward = Vector3.new(math.cos(a), 0, math.sin(a))
	local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
	local color = diff.Color
	local pale = color:Lerp(C.White, 0.55)

	----------------------------------------------------------------
	-- Pad (the party "ready pad") + invisible Zone
	----------------------------------------------------------------
	local padGround = Vector3.new(ORIGIN.X, TOP, ORIGIN.Z) + outward * PORTAL_R
	local padCF = CFrame.lookAt(padGround, padGround - outward)

	local plate = block(f, padCF * CFrame.new(0, 0.2, 0), Vector3.new(14, 0.4, 14), {
		Name = "PadPlate",
		Color = pale,
		Transparency = 0.1,
	})
	local edgeProps = { Name = "PadEdge", Color = color, Material = MAT.Neon, CanCollide = false }
	block(f, padCF * CFrame.new(0, 0.42, -6.75), Vector3.new(14, 0.14, 0.5), edgeProps)
	block(f, padCF * CFrame.new(0, 0.42, 6.75), Vector3.new(14, 0.14, 0.5), edgeProps)
	block(f, padCF * CFrame.new(-6.75, 0.42, 0), Vector3.new(0.5, 0.14, 14), edgeProps)
	block(f, padCF * CFrame.new(6.75, 0.42, 0), Vector3.new(0.5, 0.14, 14), edgeProps)

	local emblem = disc(f, padGround + Vector3.new(0, 0.45, 0), 9.5, 0.1, {
		Name = "PadEmblem",
		Color = color,
		Material = MAT.Neon,
		Transparency = 0.4,
		CanCollide = false,
	})
	disc(f, padGround + Vector3.new(0, 0.5, 0), 5, 0.1, {
		Name = "PadEmblemCore",
		Color = C.White,
		Material = MAT.Neon,
		Transparency = 0.55,
		CanCollide = false,
	})
	emitter(plate, {
		Color = ColorSequence.new(color, C.White),
		Rate = 7,
		Lifetime = NumberRange.new(1.8, 2.8),
		Speed = NumberRange.new(2, 4),
		Size = popSize(0.7),
	})

	-- Four little glowing pylons mark the pad corners.
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local corner = (padCF * CFrame.new(sx * 7.2, 0, sz * 7.2)).Position
			disc(f, corner + Vector3.new(0, 1.2, 0), 0.8, 2.4, { Name = "PadPylon", Color = COL.Cloud })
			ball(f, corner + Vector3.new(0, 2.8, 0), 1.5, {
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
		loopTween(emblem, 1.7, { Transparency = 0.78 }, Enum.EasingStyle.Sine, true)
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
			segColor = color:Lerp(C.White, 0.45)
		end
		block(f, gateCF * CFrame.new(math.cos(phi) * ringR, math.sin(phi) * ringR, 0) * CFrame.Angles(0, 0, phi + math.pi / 2), Vector3.new(segLen, 1.0, 1.6), {
			Name = "GateRing",
			Color = segColor,
			Material = MAT.Neon,
			CanCollide = false,
		})
	end

	local frameCount = 12
	for k = 0, frameCount - 1 do
		local phi = (k + rng:Float(-0.2, 0.2)) * (math.pi * 2 / frameCount)
		local fr = ringR + 1.9
		local puffPos = (gateCF * CFrame.new(math.cos(phi) * fr, math.sin(phi) * fr, rng:Float(-0.3, 0.3))).Position
		ball(f, puffPos, rng:Float(2.5, 3.3), {
			Name = "GateCloud",
			Color = COL.Cloud:Lerp(pale, rng:Float(0, 0.25)),
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
		Color = color,
		Material = MAT.Neon,
		Transparency = 0.62,
		CanCollide = false,
	})
	mk(f, {
		Name = "GateSwirlCore",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 9.5, 9.5),
		CFrame = faceCF,
		Color = pale,
		Material = MAT.Neon,
		Transparency = 0.55,
		CanCollide = false,
	})
	local glow = pointLight(swirl, color, 1.6, 34)
	emitter(swirl, {
		Color = ColorSequence.new(pale, C.White),
		Rate = 10,
		Lifetime = NumberRange.new(1.5, 2.5),
		Speed = NumberRange.new(0.3, 0.9),
		Size = popSize(1.2),
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
			Rate = 16,
			Lifetime = NumberRange.new(1.3, 1.9),
			Speed = NumberRange.new(0, 0.4),
			Size = popSize(1.5),
			RotSpeed = NumberRange.new(-90, 90),
		})
	end

	later(function()
		-- 3-fold symmetric arms: turning 120 degrees and restarting is visually seamless.
		loopTween(arm, 1.8, { CFrame = gateCF * CFrame.Angles(0, 0, math.rad(120)) }, Enum.EasingStyle.Linear, false)
		loopTween(swirl, 2.2, { Transparency = 0.8 }, Enum.EasingStyle.Sine, true)
		loopTween(glow, 2.2, { Brightness = 2.6 }, Enum.EasingStyle.Sine, true)
	end)

	-- Difficulty gems above the ring: one golden diamond per star.
	local stars = diff.Stars or 1
	for s = 1, stars do
		local gx = (s - (stars + 1) / 2) * 3.2
		block(f, gateCF * CFrame.new(gx, ringR + 3.4, 0) * CFrame.Angles(0, 0, math.rad(45)), Vector3.new(1.7, 1.7, 0.8), {
			Name = "DifficultyGem",
			Color = C.Token,
			Material = MAT.Neon,
			CanCollide = false,
		})
	end

	-- Cloud pillars flanking the gate, each topped with a glowing lantern in the portal colour.
	for _, side in ipairs({ -1, 1 }) do
		local base = gateGround + tangent * (12.8 * side)
		ball(f, base + Vector3.new(0, 3.0, 0), 6.4, { Name = "PillarPuff", Color = COL.Cloud })
		ball(f, base + Vector3.new(0, 7.2, 0), 5.0, { Name = "PillarPuff", Color = COL.Cloud, CanCollide = false })
		ball(f, base + Vector3.new(0, 10.3, 0), 3.8, { Name = "PillarPuff", Color = COL.Cloud:Lerp(pale, 0.3), CanCollide = false })
		ball(f, base + Vector3.new(0, 12.9, 0), 1.8, {
			Name = "PillarGlow",
			Color = color,
			Material = MAT.Neon,
			CanCollide = false,
		})
	end

	----------------------------------------------------------------
	-- Billboard: title, stars, player count, status
	----------------------------------------------------------------
	local anchor = anchorPart(f, "BillboardAnchor", gateCenter + Vector3.new(0, 15.5, 0), Vector3.new(1, 1, 1))
	local gui = Instance.new("BillboardGui")
	gui.Name = "PortalBillboard"
	gui.Size = UDim2.new(0, 360, 0, 200)
	gui.StudsOffset = Vector3.new(0, 0, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 260
	gui.Adornee = anchor

	local card = Theme.Panel({ Name = "Card", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 0.28 })
	local cardStroke = card:FindFirstChildOfClass("UIStroke")
	if cardStroke then
		cardStroke.Color = color
		cardStroke.Thickness = 3
		cardStroke.Transparency = 0.1
	end
	card.Parent = gui

	local titleLabel = Theme.Label(diff.DisplayName, "Title", {
		Size = 44,
		Color = color,
		Props = { Name = "TitleLabel", Size = UDim2.new(1, 0, 0.3, 0), Position = UDim2.new(0, 0, 0.04, 0) },
	})
	titleLabel.Parent = card

	local starText = string.rep("\226\152\133", stars) .. string.rep("\226\152\134", math.max(0, 3 - stars)) -- filled stars, then hollow stars for the rest
	local starLabel = Theme.Label(starText, "Label", {
		Size = 26,
		Color = C.Token,
		Props = { Name = "StarLabel", Size = UDim2.new(1, 0, 0.14, 0), Position = UDim2.new(0, 0, 0.34, 0) },
	})
	starLabel.Parent = card

	local countLabel = Theme.Label("0 / " .. tostring(Config.Match.MaxPlayers) .. " players", "Display", {
		Size = 34,
		Color = C.White,
		Props = { Name = "CountLabel", Size = UDim2.new(1, 0, 0.26, 0), Position = UDim2.new(0, 0, 0.5, 0) },
	})
	countLabel.Parent = card

	local statusLabel = Theme.Label("Waiting for players\226\128\166", "Body", { -- trailing ellipsis
		Size = 22,
		Color = C.TokenGlow,
		Props = { Name = "StatusLabel", Size = UDim2.new(1, 0, 0.18, 0), Position = UDim2.new(0, 0, 0.77, 0) },
	})
	statusLabel.Parent = card

	gui.Parent = anchor

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
-- Signs
----------------------------------------------------------------------

-- Two wooden-looking posts, a framed board and cloud puffs at the base. Returns the board part
-- (its Front face looks at the plaza centre). `cf` is at ground level facing the plaza.
local function signStructure(parent, cf, width, height, postHeight)
	local boardY = postHeight - height * 0.5 - 1.2
	local postX = width * 0.5 + 1.9

	for _, side in ipairs({ -1, 1 }) do
		local postPos = (cf * CFrame.new(side * postX, postHeight * 0.5, 0.2)).Position
		disc(parent, postPos, 1.5, postHeight, { Name = "SignPost", Color = COL.WoodDark, Material = MAT.Wood })
		local basePos = (cf * CFrame.new(side * postX, 0, 0.2)).Position
		ball(parent, basePos + Vector3.new(0, 1.3, 0), 4.6, { Name = "SignPuff", Color = COL.Cloud })
		ball(parent, basePos + Vector3.new(side * -1.8, 0.8, 1.2), 3.2, { Name = "SignPuff", Color = COL.Shade })
		local lanternPos = (cf * CFrame.new(side * postX, postHeight + 0.9, 0.2)).Position
		local lantern = ball(parent, lanternPos, 2.2, {
			Name = "SignLantern",
			Color = COL.Lantern,
			Material = MAT.Neon,
			CanCollide = false,
		})
		pointLight(lantern, COL.Lantern, 1.0, 20)
	end

	-- Backing frame (slightly bigger, behind) and the board itself.
	block(parent, cf * CFrame.new(0, boardY, 0.25), Vector3.new(width + 2, height + 1.8, 1.0), {
		Name = "SignFrame",
		Color = COL.Pink,
	})
	local board = block(parent, cf * CFrame.new(0, boardY, -0.3), Vector3.new(width, height, 0.8), {
		Name = "SignBoard",
		Color = COL.Navy,
		CastShadow = true,
	})

	-- Rainbow trim along the bottom edge of the board.
	local stripW = width / 6
	for i = 1, 6 do
		local x = (i - 3.5) * stripW
		block(parent, cf * CFrame.new(x, boardY - height * 0.5 + 0.3, -0.75), Vector3.new(stripW, 0.5, 0.2), {
			Name = "SignTrim",
			Color = C.Rainbow[i],
			Material = MAT.Neon,
			CanCollide = false,
		})
	end
	return board
end

local function buildWelcomeSign(root)
	local f = newFolder(root, "WelcomeSign")
	local ground = polar(20, 50, TOP)
	local cf = CFrame.lookAt(ground, Vector3.new(ORIGIN.X, TOP, ORIGIN.Z))
	local board = signStructure(f, cf, 32, 11.6, 19)

	local gui = surfaceGui(board, 40)
	local panel = signPanel(gui)

	local welcome = Theme.Label("~ welcome to the clouds ~", "Script", {
		Size = 36,
		Color = C.TokenGlow,
		Props = { Size = UDim2.new(1, 0, 0.14, 0), Position = UDim2.new(0, 0, 0.06, 0) },
	})
	welcome.Parent = panel

	local titleText = string.upper(Config.GameName)
	local shadow = Theme.Label(titleText, "Title", {
		Scaled = true,
		Color = C.Ink,
		Stroke = 1,
		Props = { Size = UDim2.new(0.92, 0, 0.52, 0), Position = UDim2.new(0.048, 0, 0.225, 0), TextTransparency = 0.25 },
	})
	shadow.Parent = panel

	local title = Theme.Label(titleText, "Title", {
		Scaled = true,
		Stroke = 1,
		Props = { Size = UDim2.new(0.92, 0, 0.52, 0), Position = UDim2.new(0.04, 0, 0.2, 0) },
	})
	textGradient(title, {
		{ 0, Color3.fromRGB(255, 150, 190) },
		{ 0.35, Color3.fromRGB(255, 226, 120) },
		{ 0.7, Color3.fromRGB(150, 240, 200) },
		{ 1, Color3.fromRGB(130, 200, 255) },
	}, 8)
	title.Parent = panel

	local tagline = Theme.Label(Config.Tagline, "Script", {
		Size = 42,
		Color = C.White,
		Props = { Size = UDim2.new(1, 0, 0.16, 0), Position = UDim2.new(0, 0, 0.75, 0) },
	})
	tagline.Parent = panel

	gui.Parent = board
	emitter(board, {
		Color = ColorSequence.new(C.TokenGlow, C.White),
		Rate = 4,
		Lifetime = NumberRange.new(2, 3),
		Speed = NumberRange.new(1, 2),
		Size = popSize(0.8),
	})
end

local function keyRow(parent, y, keyText, descText)
	local chip = Instance.new("Frame")
	chip.Name = "KeyChip"
	chip.Size = UDim2.new(0.3, 0, 0.115, 0)
	chip.Position = UDim2.new(0.07, 0, y, 0)
	chip.BackgroundColor3 = C.PanelLight
	chip.BorderSizePixel = 0
	Theme.Corner(chip, UDim.new(0, 14))
	Theme.Stroke(chip, C.TokenGlow, 2, 0.3)
	chip.Parent = parent

	local key = Theme.Label(keyText, "Heading", {
		Size = 34,
		Color = C.TokenGlow,
		Props = { Size = UDim2.new(1, 0, 1, 0) },
	})
	key.Parent = chip

	local desc = Theme.Label(descText, "Body", {
		Size = 34,
		Color = C.White,
		Props = {
			Size = UDim2.new(0.55, 0, 0.115, 0),
			Position = UDim2.new(0.41, 0, y, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
		},
	})
	desc.Parent = parent
end

local function buildHowToBoard(root)
	local f = newFolder(root, "HowToBoard")
	local ground = polar(160, 50, TOP)
	local cf = CFrame.lookAt(ground, Vector3.new(ORIGIN.X, TOP, ORIGIN.Z))
	local board = signStructure(f, cf, 24, 16.4, 21)

	local gui = surfaceGui(board, 40)
	local panel = signPanel(gui)

	local header = Theme.Label("HOW TO PLAY", "Title", {
		Size = 62,
		Color = C.Token,
		Props = { Size = UDim2.new(1, 0, 0.16, 0), Position = UDim2.new(0, 0, 0.04, 0) },
	})
	header.Parent = panel

	keyRow(panel, 0.24, "W A S D", "Move around")
	keyRow(panel, 0.375, "SHIFT", "Hold to run")
	keyRow(panel, 0.51, "Q", "Dash across wide gaps")
	keyRow(panel, 0.645, "SPACE", "Jump")

	local footer = Theme.Label("Stand in a glowing portal to form a party, then climb together! Collect cloud tokens on the way up.", "Body", {
		Size = 27,
		Color = C.TokenGlow,
		Props = {
			Size = UDim2.new(0.9, 0, 0.17, 0),
			Position = UDim2.new(0.05, 0, 0.79, 0),
			TextWrapped = true,
		},
	})
	footer.Parent = panel

	gui.Parent = board
end

----------------------------------------------------------------------
-- Floating islands + bridges
----------------------------------------------------------------------

local function buildIsland(parent, rng, spec)
	local f = newFolder(parent, "Island_" .. spec.Name)
	local r = spec.Radius
	local c = polar(spec.Angle, spec.Distance, TOP + spec.Dy) -- centre of the island surface
	local toPlaza = spec.Angle + 180

	local topPart = disc(f, c - Vector3.new(0, 2, 0), r * 2, 4, {
		Name = "IslandTop",
		Color = COL.Cloud,
		CastShadow = true,
	})
	disc(f, c - Vector3.new(0, 6, 0), r * 1.6, 4, { Name = "IslandTier", Color = Color3.fromRGB(236, 232, 250), Transparency = 0.05, CanCollide = false })
	disc(f, c - Vector3.new(0, 10.5, 0), r * 1.0, 5, { Name = "IslandTier", Color = COL.Lilac, Transparency = 0.12, CanCollide = false })
	disc(f, c - Vector3.new(0, 15.5, 0), r * 0.5, 5, { Name = "IslandTier", Color = COL.Dusk, Transparency = 0.28, CanCollide = false })

	rimPuffs(f, rng, c, r - 0.4, 6, 5, 8, 0.2, 0.9, COL.Cloud, { toPlaza }, 22)
	for _ = 1, 3 do
		local a = rng:Float(0, math.pi * 2)
		local dist = rng:Float(r * 0.3, r * 0.8)
		local d = rng:Float(r * 0.45, r * 0.75)
		ball(f, c + Vector3.new(math.cos(a) * dist, -rng:Float(7, 13), math.sin(a) * dist), d, {
			Name = "UnderPuff",
			Color = COL.Lilac:Lerp(C.White, rng:Float(0, 0.4)),
			Transparency = 0.1,
			CanCollide = false,
		})
	end

	-- Decorations, kept off the bridge landing.
	local placer = newPlacer(rng)
	local back = math.rad(toPlaza)
	placer.Reserve(math.cos(back) * (r - 2), math.sin(back) * (r - 2), 6.5)

	for _, feature in ipairs(spec.Features) do
		if feature == "Bench" then
			local x, z = placer.Find(3.6, r * 0.45, r * 0.7, spec.Angle - 70, spec.Angle + 70)
			if x then
				local pos = c + Vector3.new(x, 0, z)
				local outDir = Vector3.new(x, 0, z).Unit
				bench(f, CFrame.lookAt(pos, pos + outDir))
			end
		elseif feature == "Tree" then
			local x, z = placer.Find(4.2, r * 0.35, r * 0.7, spec.Angle - 110, spec.Angle + 110)
			if x then
				lanternTree(f, rng, c + Vector3.new(x, 0, z), rng:Float(0.9, 1.1), rng:Pick(BLOSSOMS), true)
			end
		elseif feature == "Pond" then
			local x, z = placer.Find(5.4, 0, r * 0.45, 0, 360)
			if x then
				pond(f, rng, c + Vector3.new(x, 0, z), rng:Float(3.2, 3.8))
			end
		elseif feature == "Flowers" then
			local x, z = placer.Find(4.2, r * 0.2, r * 0.72, 0, 360)
			if x then
				flowerPatch(f, rng, c + Vector3.new(x, 0, z), 3.6, 4)
			end
		elseif feature == "Tokens" then
			local x, z = placer.Find(6.5, 0, r * 0.2, 0, 360)
			if x then
				tokenShowcase(f, c + Vector3.new(x, 0, z))
			end
		end
	end

	nameTag(topPart, spec.Name, 15)

	-- A few fireflies per island.
	local flies = anchorPart(f, "Fireflies", c + Vector3.new(0, 5, 0), Vector3.new(r * 1.6, 8, r * 1.6))
	emitter(flies, {
		Color = ColorSequence.new(Color3.fromRGB(255, 244, 160), Color3.fromRGB(190, 255, 175)),
		Rate = 4,
		Lifetime = NumberRange.new(5, 8),
		Speed = NumberRange.new(0.3, 1),
		SpreadAngle = Vector2.new(180, 180),
		Size = popSize(0.5),
	})
end

-- Stepped cloud bridge from the plaza rim to the island edge. Each step is a flat puffy disc;
-- the rise per step is Dy / steps (<= ~1.5 studs) so everything is walkable or an easy hop.
local function buildBridge(parent, rng, spec)
	local f = newFolder(parent, "Bridge_" .. spec.Name)
	local p0 = polar(spec.Angle, SURF_R - 2.5, TOP)
	local p1 = polar(spec.Angle, spec.Distance - spec.Radius + 2.5, TOP + spec.Dy)
	local dx = p1.X - p0.X
	local dz = p1.Z - p0.Z
	local horizontal = math.sqrt(dx * dx + dz * dz)
	local steps = math.max(3, math.ceil(horizontal / 4.4))
	local a = math.rad(spec.Angle)
	local perp = Vector3.new(-math.sin(a), 0, math.cos(a))

	-- A pair of glowing lamp posts marks the bridge entrance on the plaza side.
	local entry = polar(spec.Angle, SURF_R - 4.5, TOP)
	lampPost(f, entry + perp * 4.8, false)
	lampPost(f, entry - perp * 4.8, false)

	for i = 1, steps - 1 do
		local t = i / steps
		local wobble = rng:Float(-0.6, 0.6)
		local topY = TOP + spec.Dy * t
		local d = rng:Float(6.2, 7.6)
		local pos = Vector3.new(p0.X + dx * t, topY - 0.7, p0.Z + dz * t) + perp * wobble
		disc(f, pos, d, 1.4, {
			Name = "CloudStep",
			Color = COL.Cloud:Lerp(COL.Shade, rng:Float(0, 0.25)),
		})
		if i % 3 == 0 then
			local side = 1
			if rng:Chance(0.5) then
				side = -1
			end
			ball(f, pos + perp * (side * d * 0.5) + Vector3.new(0, -0.9, 0), rng:Float(2.8, 3.8), {
				Name = "StepPuff",
				Color = COL.Cloud:Lerp(COL.Shade, rng:Float(0, 0.35)),
				CanCollide = false,
			})
		end
	end
end

----------------------------------------------------------------------
-- Sky decoration: drifting clouds + sea of clouds far below
----------------------------------------------------------------------

local function buildSky(root)
	local f = newFolder(root, "SkyDecor")
	local rng = Util.NewRng(SEED + 5)

	-- Drifting puffs: each cluster slides sideways and back forever (all parts share one tween).
	local driftCount = 6
	for i = 1, driftCount do
		local ang = (i - 1) * (360 / driftCount) + rng:Float(-15, 15)
		local dist = rng:Float(175, 255)
		local y = TOP + rng:Float(-20, 55)
		local radius = rng:Float(9, 15)
		local parts = cloudCluster(f, rng, polar(ang, dist, y), radius, { Puffs = 2, CanCollide = false, Transparency = 0.05 })
		local a = math.rad(ang)
		local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
		local offset = tangent * (rng:Float(26, 46) * (rng:Chance(0.5) and 1 or -1)) + Vector3.new(0, rng:Float(-3, 3), 0)
		local period = rng:Float(26, 44)
		later(function()
			for _, p in ipairs(parts) do
				loopTween(p, period, { Position = p.Position + offset }, Enum.EasingStyle.Sine, true)
			end
		end)
	end

	-- A fluffy sea far under the lobby. Non-collidable, so falling players are caught by the
	-- kill-plane teleport rather than landing on it.
	for i = 1, 8 do
		local ang = (i - 1) * 45 + rng:Float(-16, 16)
		local dist = rng:Float(150, 340)
		local y = TOP - rng:Float(75, 130)
		cloudCluster(f, rng, polar(ang, dist, y), rng:Float(22, 40), {
			Puffs = 2,
			CanCollide = false,
			Color = COL.Lilac,
			Shade = COL.Dusk,
		})
	end

	-- High, slow sparkle dust around the whole village.
	local dust = anchorPart(f, "SkyDust", Vector3.new(ORIGIN.X, TOP + 20, ORIGIN.Z), Vector3.new(420, 90, 420))
	emitter(dust, {
		Color = ColorSequence.new(Color3.fromRGB(255, 232, 214), Color3.fromRGB(214, 226, 255)),
		Rate = 14,
		Lifetime = NumberRange.new(8, 12),
		Speed = NumberRange.new(0.3, 1.2),
		SpreadAngle = Vector2.new(180, 180),
		Size = popSize(0.9),
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

function LobbyBuilder.Build()
	stopAnimations()
	partCount = 0

	local old = Workspace:FindFirstChild("NimbusLobby")
	if old then
		old:Destroy()
	end

	local root = Instance.new("Folder")
	root.Name = "NimbusLobby"

	-- Portals sit evenly on the ring; the first difficulty is straight ahead (+Z) of the spawn.
	local diffs = Config.Difficulties
	local portalAngles = {}
	for i = 1, #diffs do
		portalAngles[i] = 90 + (i - 1) * (360 / #diffs)
	end
	local bridgeAngles = {}
	for i, spec in ipairs(ISLANDS) do
		bridgeAngles[i] = spec.Angle
	end

	-- Portals are the one thing the game cannot do without: build them first, no pcall.
	local portals = {}
	local portalFolder = newFolder(root, "Portals")
	for i, diff in ipairs(diffs) do
		portals[diff.Id] = buildPortal(portalFolder, Util.NewRng(SEED + 10 + i), diff, portalAngles[i])
	end

	-- Everything else is decoration: a failure there must not take the lobby down.
	section("plaza", function()
		buildPlaza(root, portalAngles, bridgeAngles, diffs)
	end)
	section("rainbow", function()
		buildRainbow(root)
	end)
	section("welcome sign", function()
		buildWelcomeSign(root)
	end)
	section("how-to board", function()
		buildHowToBoard(root)
	end)
	section("islands", function()
		local islandFolder = newFolder(root, "Islands")
		for i, spec in ipairs(ISLANDS) do
			local rng = Util.NewRng(SEED + 100 + i)
			section("island " .. spec.Name, function()
				buildIsland(islandFolder, rng, spec)
			end)
			section("bridge " .. spec.Name, function()
				buildBridge(islandFolder, rng, spec)
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

	-- Spawn in the middle of the plaza, looking at the first portal.
	local spawnPos = Vector3.new(ORIGIN.X, TOP + 3, ORIGIN.Z)
	local firstPortal = portals[diffs[1].Id]
	local lookTarget = Vector3.new(firstPortal.Center.X, spawnPos.Y, firstPortal.Center.Z)

	print(string.format("[LobbyBuilder] lobby built (%d parts)", partCount))

	return {
		Folder = root,
		SpawnCFrame = CFrame.lookAt(spawnPos, lookTarget),
		Portals = portals,
	}
end

return LobbyBuilder
