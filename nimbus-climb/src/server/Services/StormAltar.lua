-- StormAltar (server): the Storm Altar lobby landmark from the player's own Stormfang art
-- (ARCHITECTURE_V3.md section 10, branding/stormfang-concept.webp: the crystal altar ring on dark storm clouds).
--
--   StormAltar.Build(lobbyInfo) -> CFrame   builds Model "StormAltar" under the lobby folder and returns the
--                                           altar CFrame (centre of the dais on the island's walking surface,
--                                           LookVector = towards the plaza). Safe to call again (rebuilds).
--   StormAltar.GetModel() -> Model | nil
--   StormAltar.GetCFrame() -> CFrame | nil
--   StormAltar.Used                         Util.Signal; Fire(player) when a player uses the altar's prompt
--
-- What it builds (all static; the client animates the showcase, ShowcaseController):
--   Island     a dark navy storm cloud sculpted with shared/Voxel.lua, as in the art: a storm-blue walking top
--              (DECK studs above the lobby) ringed by overlapping 2-stud-voxel billows (a lower outer row, a main
--              row and a bank piled up behind the dais; open towards the bridge) with lighter blue-grey tops and
--              pale grey-white highlights on a few crowns, over a hanging cumulus belly of 3-stud voxels (tiers of
--              lumps narrowing downwards), navy, darker underneath.
--   Dais       a ring of charcoal stone blocks (radius ~12) with bevelled lighter tops, stepped clusters and
--              stacked mounts by the crystals, scattered rubble; a segmented inner rim around a dark navy portal
--              disc with a softer heart and dim glowing runes.
--   Crystals   as in the art seen from its front (the plaza): the head crystal, the biggest (a stepped diamond with
--              two small side shards), rises at the far side behind the showcase, a medium pair flanks it, a
--              smaller pair stands at the near sides and a low diamond gem is set into the near stone. Every shard
--              is a pale Glass shell around an electric-cyan Neon core.
--   Showcase   StormfangShowcase: PetBuilder.Build(stormfang, { Detail = "High", Scale = 3 }), anchored, hovering
--              over the portal on its storm cloud, leaning forward (prowling) towards the plaza; tagged
--              "NC_Showcase" with the attributes PetId, PetParts, HoverAmp and Ready. An invisible collider keeps
--              players out of the big (non-colliding) pet.
--   Bridge     a stone bridge from the island to LobbyInfo.AltarDock (the street junction, whose inner rail
--              LobbyBuilder leaves open for it): a short level deck over the island edge, then a gentle ramp down
--              to the street height (no steps into the street). Low parapets with crystal lanterns, a storm
--              puff underneath.
--   Sign       Model StormAltarSign: a stone entrance gate standing on the street over the bridge's foot, its
--              12 x 6.4-stud poster facing the street (SurfaceGui at 50 px per stud in the cloud UI style: the
--              player's art Config.Art.StormfangImage in a 5.7-stud well, "STORM ALTAR" in 1.1-stud letters,
--              "Secret pets" and "Awakens soon" in 0.64-stud letters: readable from ~30 studs), low walls between
--              the bridge and the pillars, and a pixel-sized "STORM ALTAR" / "Secret pets" title tag above the
--              altar, readable from the plaza.
--   Prompt     ProximityPrompt "Storm Altar" (ActionText "Summon"). Phase 2 (gems): it opens the Shop on the
--              gems-only Secret roulette (OpenPanel("Shop", { RouletteId = Config.Gems.SecretRoulette.Id,
--              Currency = "Gems" }), rate-limited per player) when GemService.SecretRouletteState says "Open";
--              an account where PolicyService restricts paid random items gets a side toast that the Secret
--              Roulette is not available there; while the gem system is missing or still checking the account the
--              phase 1 side toast "The Storm Altar awakens soon: summon Secret pets with Gems!" is sent (toasts:
--              Notify, rate-limited per player).
--   Lights     a few soft electric-blue PointLights with small ranges (portal, head crystal, gate).
-- No AltarSite: a free spot between the plaza and the plot ring road is searched (away from lobby parts, NPC spots
-- and the spawn), and the dock is found by raycasting for the street. Collision only on walkable parts (island
-- top and billows, dais stones, rim, disc, bridge, steps, gate) plus the invisible showcase collider. Part budget
-- <= ~450 without the showcase pet. Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local function optional(name)
	local module = Shared:FindFirstChild(name) or Shared:WaitForChild(name, 5)
	if not module then
		warn("[StormAltar] shared module missing: " .. name)
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[StormAltar] failed to load " .. name .. ": " .. tostring(result))
	return nil
end

local Voxel = optional("Voxel")
local PetBuilder = optional("PetBuilder")
local PetCatalog = optional("PetCatalog")

local StormAltar = {}
StormAltar.Used = Util.Signal()

----------------------------------------------------------------------
-- Constants (studs; altar-local frame: origin = dais centre on the walking surface, -Z = front = the plaza)
----------------------------------------------------------------------
local MODEL_NAME = "StormAltar"
local SHOWCASE_TAG = "NC_Showcase"
local PET_ID = "stormfang"
local TOAST = "The Storm Altar awakens soon: summon Secret pets with Gems!"
local TOAST_RESTRICTED = "The Storm Altar's Secret Roulette is not available on your account."
local TOAST_COOLDOWN = 3 -- seconds between two toasts for the same player
local OPEN_COOLDOWN = 0.5 -- seconds between two "open the Secret roulette" for the same player
local SECRET_ROULETTE_ID = (type(Config.Gems) == "table" and type(Config.Gems.SecretRoulette) == "table"
	and type(Config.Gems.SecretRoulette.Id) == "string" and Config.Gems.SecretRoulette.Id) or "Secret"

local DECK = 3 -- the island's walking surface above the lobby walking height
local R_TOP = 23 -- walkable top radius
local RING_C, RING_D = 12.2, 3.2 -- stone ring: centre radius and radial depth (11 = 10.6 .. 13.8)
local RING_N = 22 -- stones around (one centred on the front, one on the back)
local RIM_R, RIM_D, RIM_H, RIM_N = 6.9, 1.6, 1.2, 14 -- inner portal rim
local DISC_S = 10.3 -- side of the four turned squares of the portal disc (union radius 6.2 .. 7.3)
local HOVER = 3.2 -- gap between the walking surface and the showcase's lowest point
local PROWL = math.rad(-8) -- forward lean of the showcase (nose down)
local BRIDGE_W = 8
local RAMP_LEVEL = 5 -- studs of level deck over the island edge before the ramp slopes down to the street
local GAP_HALF = 26 -- degrees kept free of rim billows around the bridge
local MAX_PARTS = 450
-- the entrance gate's poster (World text rule: a SurfaceGui at 50 px per stud, titles >= 1 stud, lines >= 0.6 stud)
local POSTER_PPS = 50
local PANEL_W, PANEL_H = 12, 6.4 -- studs = 600 x 320 px
local PANEL_BOTTOM = 8.3 -- studs above the street: everyone walks under it
local GATE_HALF = 5.6 -- pillar centres from the bridge's centre line (the junction wedge is ~13.8 studs wide
-- at the street's inner edge: the pillars stand clear of the neighbouring plots' street slabs)
local PILLAR_W = 1.3
local PILLAR_TOP = 15.2
local PANEL_Z = -(PILLAR_W / 2 + 0.2) -- centre of the poster's stone frame, on the street face of the pillars

local MAT = Enum.Material
local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local C = {
	-- storm cloud (ARCHITECTURE_V3.md section 10: navy #2e3a66 / #44507f / lighter #6b77a8 tops, white puffs)
	StormDeep = rgb(34, 43, 78),
	Storm = rgb(46, 58, 102),
	StormMid = rgb(68, 80, 127),
	StormTop = rgb(107, 119, 168),
	Walk = rgb(86, 98, 143),
	Floor = rgb(36, 44, 80),
	Puff = rgb(222, 228, 242),
	PuffLight = rgb(242, 244, 250),
	PuffDark = rgb(186, 194, 220),
	-- charcoal stone (the armour greys of the art)
	StoneDeep = rgb(42, 44, 51),
	Stone = rgb(75, 77, 87),
	StoneB = rgb(66, 68, 78),
	StoneC = rgb(84, 87, 98),
	StoneLight = rgb(112, 115, 126),
	Bevel = rgb(163, 166, 174),
	RimSide = rgb(58, 66, 102),
	RimTop = rgb(104, 112, 146),
	Disc = rgb(26, 32, 64),
	DiscInner = rgb(33, 42, 84),
	-- crystals and glow
	CrystalCore = rgb(63, 200, 255),
	CrystalGlass = rgb(70, 172, 252),
	Rune = rgb(64, 150, 236),
	Electric = rgb(70, 170, 255),
	Violet = rgb(122, 60, 255),
	-- sign
	Navy = (Theme.Colors and Theme.Colors.Navy) or rgb(24, 34, 78),
	Ink = (Theme.Colors and Theme.Colors.TextStroke) or rgb(16, 22, 50),
	White = rgb(255, 255, 255),
	Cyan = rgb(150, 224, 255),
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local altarModel = nil
local altarCFrame = nil
local lastToast = {} -- [player] = os.clock() of the last toast
local lastOpen = {} -- [player] = os.clock() of the last OpenPanel (Secret roulette)
local playersHooked = false

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function atan2(y, x)
	if math.atan2 then
		return math.atan2(y, x)
	end
	return math.atan(y, x)
end

local function hash(a, b, seed)
	local h = (a * 73856093 + b * 19349663 + seed * 83492791) % 2147483647
	h = (h * 16807) % 2147483647
	h = (h * 16807) % 2147483647
	return h / 2147483647
end

local function angleDiff(a, b)
	local d = math.abs((a - b) % 360)
	if d > 180 then
		d = 360 - d
	end
	return d
end

-- Flat CFrame at pos looking (horizontally) at target.
local function flatLook(pos, target)
	local d = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
	if d.Magnitude < 1e-3 then
		return CFrame.new(pos)
	end
	return CFrame.lookAt(pos, pos + d.Unit)
end

-- Altar-local polar placement: deg 0 = front (-Z), 90 = right (+X).
local function polarCF(A, deg, r, y)
	return A * CFrame.Angles(0, -math.rad(deg), 0) * CFrame.new(0, y or 0, -r)
end

local function newModel(parent, name)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- One anchored block. opts: Material, Collide, Transparency, Shadow, Query.
local function block(parent, name, cf, size, color, opts)
	opts = opts or {}
	local part
	if Voxel and Voxel.Box then
		part = Voxel.Box(nil, cf, size, color, opts.Material or MAT.SmoothPlastic)
	else
		part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.CFrame = cf
		part.Color = color
		part.Material = opts.Material or MAT.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.CanTouch = false
	end
	part.Name = name
	part.CanCollide = opts.Collide == true
	part.CanQuery = opts.Collide == true or opts.Query == true
	part.CanTouch = false
	part.Transparency = opts.Transparency or 0
	if opts.Shadow ~= nil then
		part.CastShadow = opts.Shadow == true
	else
		part.CastShadow = math.max(size.X, size.Y, size.Z) >= 4
	end
	part.Parent = parent
	return part
end

local function invisible(parent, name, cf, size)
	return block(parent, name, cf, size or Vector3.new(1, 1, 1), C.Storm, { Transparency = 1, Shadow = false })
end

local function pointLight(parent, brightness, range)
	local l = Instance.new("PointLight")
	l.Name = "StormGlow"
	l.Color = C.Electric
	l.Brightness = brightness
	l.Range = range
	l.Shadows = false
	l.Parent = parent
	return l
end

local function sparkles(parent, rate, speed, size)
	local e = Instance.new("ParticleEmitter")
	e.Name = "StormSparkles"
	e.Texture = SPARKLES
	e.Color = ColorSequence.new(C.CrystalCore, C.Violet)
	e.LightEmission = 0.8
	e.LightInfluence = 0
	e.Rate = rate
	e.Lifetime = NumberRange.new(1.6, 2.8)
	e.Speed = NumberRange.new(speed * 0.5, speed)
	e.SpreadAngle = Vector2.new(30, 30)
	e.EmissionDirection = Enum.NormalId.Top
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-60, 60)
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, size),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Parent = parent
	return e
end

local function section(name, fn)
	local ok, err = pcall(fn)
	if not ok then
		warn("[StormAltar] " .. name .. " failed: " .. tostring(err))
	end
	return ok
end

----------------------------------------------------------------------
-- Site: LobbyInfo.AltarSite / AltarDock, or a free spot at the lobby edge
----------------------------------------------------------------------
-- Every visible part of the lobby near the walking height as an oriented box (for the free-spot search).
local function obstacleBoxes(folder, top)
	local list = {}
	if typeof(folder) ~= "Instance" then
		return list
	end
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 then
			local half = d.Size * 0.5
			local y = d.Position.Y
			if y + half.Magnitude > top - 30 and y - half.Magnitude < top + 40 then
				list[#list + 1] = { CF = d.CFrame, Half = half }
			end
		end
	end
	return list
end

-- Horizontal distance from p to the nearest obstacle box (capped at `cap`).
local function clearance(p, boxes, cap)
	local best = cap
	for i = 1, #boxes do
		local b = boxes[i]
		local q = b.CF:PointToObjectSpace(p)
		local dx = math.max(math.abs(q.X) - b.Half.X, 0)
		local dz = math.max(math.abs(q.Z) - b.Half.Z, 0)
		local d = math.sqrt(dx * dx + dz * dz)
		if d < best then
			best = d
			if best <= 0 then
				return 0
			end
		end
	end
	return best
end

-- A free spot between the plaza and the plot ring road, away from portals, machines, NPC spots and the spawn.
local function fallbackSite(lobbyInfo)
	local lobby = Config.Lobby or {}
	local origin = lobby.Origin or Vector3.new(0, 300, 0)
	local top = origin.Y
	local plazaR = (lobby.PlazaRadius or 110) + 6
	local streetIn = (lobby.SpotRingRadius or 300) - ((lobby.PlotSize or 72) / 2 + 4 + 14)
	local need = R_TOP + 6
	local r0 = math.max(plazaR + need + 8, (plazaR + streetIn) / 2)
	local shop = lobby.ShopOffset or Vector3.new(0, 0, -150)
	local prefer = math.deg(atan2(shop.Z, shop.X)) + 45
	local boxes = obstacleBoxes(lobbyInfo and lobbyInfo.Folder, top)
	local avoid = {}
	if type(lobbyInfo) == "table" then
		if type(lobbyInfo.NpcSpots) == "table" then
			for _, cf in ipairs(lobbyInfo.NpcSpots) do
				if typeof(cf) == "CFrame" then
					avoid[#avoid + 1] = cf.Position
				end
			end
		end
		if typeof(lobbyInfo.SpawnCFrame) == "CFrame" then
			avoid[#avoid + 1] = lobbyInfo.SpawnCFrame.Position
		end
	end
	local best, bestScore = nil, -math.huge
	for step = 0, 47 do
		local k = math.floor((step + 1) / 2) * ((step % 2 == 0) and 1 or -1)
		local deg = prefer + k * 7.5
		for _, r in ipairs({ r0, r0 - 10, r0 + 10 }) do
			if r - need > plazaR and r + need < streetIn - 4 then
				local a = math.rad(deg)
				local p = Vector3.new(origin.X + math.cos(a) * r, top, origin.Z + math.sin(a) * r)
				local score = clearance(p, boxes, need * 2)
				for _, q in ipairs(avoid) do
					local d = Vector3.new(q.X - p.X, 0, q.Z - p.Z).Magnitude
					score = math.min(score, d - 12)
				end
				if score >= need then
					return flatLook(p, Vector3.new(origin.X, top, origin.Z))
				end
				if score > bestScore then
					best, bestScore = p, score
				end
			end
		end
	end
	if not best then
		local a = math.rad(prefer)
		best = Vector3.new(origin.X + math.cos(a) * r0, top, origin.Z + math.sin(a) * r0)
	end
	return flatLook(best, Vector3.new(origin.X, top, origin.Z))
end

-- Walkable ground (a collidable, upward-facing surface at the lobby height) under p, or nil.
local function groundAt(p, top, exclude)
	local ok, hit = pcall(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = exclude
		return Workspace:Raycast(Vector3.new(p.X, top + 12, p.Z), Vector3.new(0, -30, 0), params)
	end)
	if ok and hit and hit.Instance and hit.Instance.CanCollide and math.abs(hit.Position.Y - top) <= 1.5 then
		return hit.Position
	end
	return nil
end

-- Where a bridge can dock: the nearest walkable ground along the site's radial line, outwards first.
local function findDock(site, top, exclude)
	local centre = site.Position
	local back = -site.LookVector
	for _, dir in ipairs({ back, site.LookVector }) do
		for s = R_TOP + 4, R_TOP + 96, 2 do
			local hit = groundAt(centre + dir * s, top, exclude)
			if hit then
				return Vector3.new(hit.X, top, hit.Z)
			end
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Island: a dark navy voxel storm cloud
----------------------------------------------------------------------
local ISLAND_PALETTE = {
	Body = C.Storm,
	Body_Light = C.StormMid,
	Body_Dark = C.StormDeep,
	Billow = C.StormMid,
	Billow_Light = C.StormTop,
	Billow_Dark = C.Storm,
	Puff = C.PuffDark,
	PuffTop = C.Puff,
}

-- Four squares turned 22.5 degrees apart: a 16-gon (union radius 0.601 .. 0.707 x side) in four parts.
local function polygon16(parent, name, cf, side, height, color, opts)
	for k = 0, 3 do
		block(parent, name, cf * CFrame.new(0, k * 0.004, 0) * CFrame.Angles(0, math.rad(k * 22.5), 0), Vector3.new(side, height, side), color, opts)
	end
end

local function ellipsoid(g, x, y, z, rx, ry, rz, key, keep)
	Voxel.Shape(g, { Kind = "Ellipsoid", Center = { x, y, z }, Radius = { rx, ry, rz }, Key = key, KeepExisting = keep })
end

-- Puffy rim billows (studs / BV voxels), open towards the bridge. Three overlapping rows make one continuous
-- cauliflower ring (no separate "teeth"): a lower outer row that bulges out over the belly, the main row on the
-- edge of the walking top and a bank piled up behind the dais (the front stays low: the view from the plaza
-- stays open). Lighter blue-grey tops, navy undersides, pale highlights painted onto a few crowns.
local BV = 2
local function sculptRim(gapDeg)
	local g = Voxel.NewGrid(16)
	local function billow(deg, r, y, rx, ry, key)
		local a = math.rad(deg)
		ellipsoid(g, math.sin(a) * r / BV, y / BV, -math.cos(a) * r / BV, rx / BV, ry / BV, rx / BV, key or "Billow", true)
	end
	-- main row: overlapping billows on the edge of the walking top
	local count = 17
	for i = 1, count do
		local deg = (i - 0.5) * 360 / count + (hash(i, 3, 9) - 0.5) * 8
		if angleDiff(deg, gapDeg) > GAP_HALF then
			local front = angleDiff(deg, 0) < 55
			local rx = 3.3 + hash(i, 5, 9) * 1.3
			local ry = front and (1.5 + hash(i, 6, 9) * 0.4) or (2.3 + hash(i, 6, 9) * 1.3)
			billow(deg, R_TOP - 0.9 + (hash(i, 4, 9) - 0.5) * 1.2, -0.7 + (hash(i, 7, 9) - 0.5) * 0.6, rx, ry)
		end
	end
	-- lower outer row: smaller bulges that round the island's side off into the belly
	for i = 1, 12 do
		local deg = (i - 0.25) * 360 / 12 + (hash(i, 13, 9) - 0.5) * 10
		if angleDiff(deg, gapDeg) > GAP_HALF - 6 then
			billow(deg, R_TOP + 0.9, -2.3 - hash(i, 14, 9) * 0.6, 2.9 + hash(i, 15, 9) * 0.8, 1.8 + hash(i, 16, 9) * 0.5)
		end
	end
	-- the bank behind the dais (the art's cloud wall behind the ring)
	for i = 1, 8 do
		local deg = 180 + (i - 4.5) * 17 + (hash(i, 8, 9) - 0.5) * 6
		if angleDiff(deg, gapDeg) > GAP_HALF + 6 then
			billow(deg, R_TOP - 0.2, 1.5 + hash(i, 10, 9) * 1.1, 2.4 + hash(i, 11, 9) * 0.9, 2.0 + hash(i, 12, 9) * 0.8)
		end
	end
	Voxel.Shade(g, { Only = { Billow = true }, Smooth = 3, Seed = 11, LightAt = 0.5, Dark = false })
	-- pale grey-white highlights on a few crowns (the art's lit cloud tops): a grey-blue cap, whiter on top
	for i, deg in ipairs({ -42, 38, 96, 140, 180, 222, 262, -96 }) do
		if angleDiff(deg, gapDeg) > GAP_HALF + 4 then
			local a = math.rad(deg)
			local r = R_TOP - 0.8
			local x, z = math.sin(a) * r / BV, -math.cos(a) * r / BV
			local y = (angleDiff(deg, 180) < 60) and 4.2 or 2.4
			Voxel.Shape(g, { Kind = "Ellipsoid", Center = { x, y / BV, z }, Radius = { 3.0 / BV, 2.4 / BV, 3.0 / BV }, Op = "Paint", OnlyKeys = { Billow_Light = true }, Key = "Puff" })
			Voxel.Shape(g, { Kind = "Ellipsoid", Center = { x, (y + 1.2) / BV, z }, Radius = { 1.8 / BV, 1.6 / BV, 1.8 / BV }, Op = "Paint", OnlyKeys = { Puff = true }, Key = "PuffTop" })
		end
	end
	return g
end

-- The belly under the walking top (3-stud voxels, top layer just under the walking surface): a hanging
-- cumulus, as wide as the rim at the top, then tiers of lumps that narrow downwards (a rounded, bumpy
-- underside instead of a flat slab); lighter where it faces up, navy, darker underneath.
local function sculptBelly()
	local g = Voxel.NewGrid(8)
	ellipsoid(g, 0, -0.6, 0, 7.4, 1.2, 7.4, "Body")
	local function ring(n, r, y, rx, ry, seed, turn)
		for i = 1, n do
			local a = (i - 1) / n * math.pi * 2 + (turn or 0) + (hash(i, seed, 5) - 0.5) * 0.4
			local s = rx * (0.85 + hash(i, seed + 1, 5) * 0.3)
			ellipsoid(g, math.sin(a) * r, y + (hash(i, seed + 2, 5) - 0.5) * 0.5, -math.cos(a) * r, s, ry, s, "Body", true)
		end
	end
	ring(9, 6.3, -1.2, 2.4, 1.5, 20, 0.2) -- the bumpy outer silhouette under the rim
	ellipsoid(g, 0.3, -2.3, -0.2, 5.4, 1.4, 5.2, "Body", true)
	ring(7, 4.6, -2.8, 2.0, 1.3, 30, 0.6)
	ellipsoid(g, -0.2, -3.8, 0.4, 3.4, 1.3, 3.2, "Body", true)
	ring(4, 2.6, -4.3, 1.6, 1.1, 40, 1.1)
	ellipsoid(g, 0.4, -5.1, -0.2, 1.7, 1.0, 1.6, "Body", true)
	-- never above the walking surface
	local remove = {}
	for k in pairs(g.Cells) do
		local _, y = Voxel.Unpack(k)
		if y > 0 then
			remove[#remove + 1] = k
		end
	end
	for _, k in ipairs(remove) do
		g.Cells[k] = nil
		g.Count = g.Count - 1
	end
	Voxel.Shade(g, { Smooth = 2, Seed = 5, LightAt = 0.5, DarkAt = -0.25 })
	return g
end

-- Parts whose top reaches the walking surface collide; everything below is decoration.
local function collideTops(model, A)
	local inv = A:Inverse()
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			local topY = (inv * part.CFrame).Position.Y + part.Size.Y / 2
			if topY >= -0.05 then
				part.CanCollide = true
				part.CanQuery = true
			end
		end
	end
end

local function buildIsland(parent, A, gapDeg)
	local m = newModel(parent, "Island")
	-- walking top: a 16-gon of storm blue (its points hide in the rim billows), the dark floor inside the ring
	polygon16(m, "WalkTop", A * CFrame.new(0, -1, 0), 32, 2, C.Walk, { Collide = true })
	polygon16(m, "Floor", A * CFrame.new(0, 0.01, 0), 19.4, 0.04, C.Floor, { Collide = true, Shadow = false })
	if not Voxel then
		-- no voxel kit: two plain navy slabs under the top
		block(m, "IslandBody", A * CFrame.new(0, -4, 0), Vector3.new(R_TOP * 1.7, 4, R_TOP * 1.7), C.Storm)
		block(m, "IslandBelly", A * CFrame.new(0, -8, 0), Vector3.new(R_TOP, 4, R_TOP), C.StormDeep)
		return m
	end
	local rim = Voxel.Build(sculptRim(gapDeg), {
		VoxelSize = BV,
		Palette = ISLAND_PALETTE,
		Name = "RimClouds",
		CFrame = A,
		MaxParts = 150,
		Keep = { "Puff", "PuffTop" },
	})
	collideTops(rim, A)
	rim.Parent = m
	local belly = Voxel.Build(sculptBelly(), {
		VoxelSize = 3,
		Palette = ISLAND_PALETTE,
		Name = "Belly",
		CFrame = A * CFrame.new(0, -2.55, 0), -- (0.05 under the rim's voxel layers: no flush faces)
		MaxParts = 52,
	})
	belly.Parent = m
	return m
end

----------------------------------------------------------------------
-- Crystals: square prisms turned 45 degrees (a diamond from the front), stepped pyramid tips,
-- a pale Glass shell around an electric-cyan Neon core
----------------------------------------------------------------------
local function crystalBlock(parent, cf, w, h)
	block(parent, "CrystalGlass", cf, Vector3.new(w, h, w), C.CrystalGlass, { Material = MAT.Glass, Transparency = 0.25, Shadow = false })
	if w > 0.5 then
		block(parent, "CrystalCore", cf, Vector3.new(w * 0.56, h * 0.98, w * 0.56), C.CrystalCore, { Material = MAT.Neon, Shadow = false })
	end
end

-- base: bottom centre of the body, Y = the shard's axis. Returns the model and the tip height above base.
local function crystal(parent, base, w, h, tipSteps, tipH, footSteps, footH)
	local m = newModel(parent, "Crystal")
	local axis = base * CFrame.Angles(0, math.rad(45), 0)
	crystalBlock(m, axis * CFrame.new(0, h / 2, 0), w, h)
	local y = h
	for i = 1, tipSteps do
		local s = w * (1 - i / (tipSteps + 1))
		local sh = tipH / tipSteps
		crystalBlock(m, axis * CFrame.new(0, y + sh / 2, 0), s, sh)
		y = y + sh
	end
	local yb = 0
	for i = 1, footSteps or 0 do
		local s = w * (1 - i / ((footSteps or 0) + 1))
		local sh = (footH or 0) / footSteps
		crystalBlock(m, axis * CFrame.new(0, yb - sh / 2, 0), s, sh)
		yb = yb - sh
	end
	return m, y
end

----------------------------------------------------------------------
-- Dais: stone ring, mounts + crystals, inner rim, portal disc
----------------------------------------------------------------------
local STONE_COLORS = { C.Stone, C.StoneB, C.StoneC }

-- Crystal stones (ring index -> shard). As in the art seen from its front (the plaza): the head crystal, the
-- biggest (a diamond), rises at the far side behind the showcase, a medium pair flanks it, a smaller pair stands
-- at the near sides and a low diamond gem is set into the near stone (index 0, facing the plaza).
-- W = width, H = body height, Steps / Tip = stepped point, FootSteps / Foot = stepped lower point,
-- Lean = degrees outwards, Mount = height of the stacked mount stone.
local HEAD = RING_N / 2
local CRYSTALS = {
	[HEAD] = { W = 3.6, H = 5.8, Steps = 4, Tip = 3.9, FootSteps = 2, Foot = 1.4, Lean = 3, Mount = 2.6 },
	[HEAD - 3] = { W = 2.4, H = 3.4, Steps = 3, Tip = 2.4, Lean = 9, Mount = 3.2 },
	[HEAD + 3] = { W = 2.4, H = 3.4, Steps = 3, Tip = 2.4, Lean = 9, Mount = 3.2 },
	[HEAD - 7] = { W = 2.1, H = 2.6, Steps = 3, Tip = 1.8, Lean = 11, Mount = 2.8 },
	[HEAD + 7] = { W = 2.1, H = 2.6, Steps = 3, Tip = 1.8, Lean = 11, Mount = 2.8 },
}

local function buildRing(parent, A)
	local m = newModel(parent, "Ring")
	local step = 360 / RING_N
	local width = 2 * math.pi * RING_C / RING_N - 0.22
	local tops = {}
	for i = 0, RING_N - 1 do
		local deg = i * step
		local key = i
		local spec = CRYSTALS[key]
		local h = 1.6 + math.floor(hash(i, 1, 21) * 4) * 0.4
		if spec then
			h = spec.Mount - 0.9
		elseif key == 0 then
			h = 2.8 -- the near stone carries the gem
		end
		local color = STONE_COLORS[(i % #STONE_COLORS) + 1]
		-- neighbours overlap at the ring's inner edge: alternate stones sit 0.06 higher (no flush tops)
		h = h + (i % 2) * 0.06
		local cf = polarCF(A, deg, RING_C, h / 2)
		block(m, "Stone", cf, Vector3.new(width, h, RING_D), color, { Collide = true })
		-- bevelled top: a lighter inset cap
		block(m, "StoneCap", cf * CFrame.new(0, h / 2 + 0.1, 0), Vector3.new(width - 0.5, 0.2, RING_D - 0.5), C.StoneLight, { Collide = true, Shadow = false })
		local topY = h + 0.2
		if spec then
			-- stacked mount block for the crystal
			local mh = 0.9
			local mcf = polarCF(A, deg, RING_C, h + 0.2 + mh / 2)
			block(m, "Mount", mcf, Vector3.new(width * 0.74, mh, RING_D * 0.74), C.StoneB, { Collide = true })
			block(m, "MountCap", mcf * CFrame.new(0, mh / 2 + 0.08, 0), Vector3.new(width * 0.74 - 0.4, 0.16, RING_D * 0.74 - 0.4), C.Bevel, { Collide = true, Shadow = false })
			topY = h + 0.2 + mh + 0.16
		elseif hash(i, 2, 21) < 0.4 and not (CRYSTALS[(i + 1) % RING_N] or CRYSTALS[(i - 1) % RING_N]) then
			-- a smaller stone stacked off-centre (the broken, stepped silhouette of the art)
			local sh = 0.8
			local off = (hash(i, 3, 21) < 0.5) and -0.55 or 0.55
			local scf = polarCF(A, deg + off * 4, RING_C + 0.4, h + 0.2 + sh / 2)
			block(m, "StoneStack", scf, Vector3.new(width * 0.48, sh, RING_D * 0.56), C.StoneC, { Collide = true, Shadow = false })
		end
		tops[key] = topY
		-- the stones beside a crystal step up towards it (the clustered blocks of the art)
		if CRYSTALS[(i + 1) % RING_N] or CRYSTALS[(i - 1) % RING_N] then
			local toward = CRYSTALS[(i + 1) % RING_N] and 1 or -1
			local sh = 0.7 + hash(i, 4, 21) * 0.6
			local scf = polarCF(A, deg + toward * step * 0.22, RING_C - 0.3, h + 0.2 + sh / 2)
			block(m, "StoneStack", scf, Vector3.new(width * 0.5, sh, RING_D * 0.62), C.StoneC, { Collide = true, Shadow = false })
		end
	end
	-- scattered rubble around the outer foot of the ring
	for i = 1, 3 do
		local deg = i * 120 + 25 + hash(i, 7, 21) * 14
		local s = 0.7 + hash(i, 8, 21) * 0.5
		local cf = polarCF(A, deg, RING_C + RING_D / 2 + 0.9 + hash(i, 9, 21) * 0.8, s / 2) * CFrame.Angles(0, hash(i, 10, 21) * 1.2, 0)
		block(m, "Rubble", cf, Vector3.new(s, s, s), (i % 2 == 0) and C.StoneC or C.StoneB, { Shadow = false })
	end
	return m, tops
end

local function buildCrystals(parent, A, tops)
	local m = newModel(parent, "Crystals")
	local step = 360 / RING_N
	local headTip = nil
	for key, spec in pairs(CRYSTALS) do
		local deg = key * step
		local baseY = (tops[key] or (spec.Mount + 0.2)) - 0.25
		if spec.FootSteps then
			baseY = baseY + (spec.Foot or 0) -- a diamond: its lower point rests on the mount
		end
		-- lean outwards a little (-Z of the polar frame points away from the centre)
		local base = polarCF(A, deg, RING_C, baseY) * CFrame.Angles(-math.rad(spec.Lean), 0, 0)
		local _, tip = crystal(m, base, spec.W, spec.H, spec.Steps, spec.Tip, spec.FootSteps, spec.Foot)
		if key == HEAD then
			headTip = baseY + tip
			-- two small side shards leaning away from the big one
			local mountTop = tops[key] or (spec.Mount + 0.2)
			for _, s in ipairs({ -1, 1 }) do
				local side = polarCF(A, deg, RING_C + 0.3, mountTop - 0.3) * CFrame.new(s * 1.6, 0, 0) * CFrame.Angles(0, 0, -s * math.rad(26))
				crystal(m, side, 0.9, 1.0, 2, 0.9)
			end
		end
	end
	-- the low diamond gem set into the outer face of the near stone: a dark setting, a Glass rim, a Neon core
	local near = polarCF(A, 0, RING_C + RING_D / 2 + 0.05, 1.6) * CFrame.Angles(0, 0, math.rad(45))
	block(m, "GemSetting", near * CFrame.new(0, 0, 0.06), Vector3.new(2.3, 2.3, 0.4), C.StoneDeep, { Shadow = false })
	block(m, "GemRim", near * CFrame.new(0, 0, -0.12), Vector3.new(1.8, 1.8, 0.4), C.CrystalGlass, { Material = MAT.Glass, Transparency = 0.25, Shadow = false })
	block(m, "GemCore", near * CFrame.new(0, 0, -0.2), Vector3.new(1.1, 1.1, 0.4), C.CrystalCore, { Material = MAT.Neon, Shadow = false })
	return m, headTip
end

local function buildPortal(parent, A)
	local m = newModel(parent, "Portal")
	-- inner rim: segmented stone band with lighter tops
	local width = 2 * math.pi * RIM_R / RIM_N + 0.12
	for i = 0, RIM_N - 1 do
		local deg = (i + 0.5) * 360 / RIM_N
		local cf = polarCF(A, deg, RIM_R, RIM_H / 2)
		block(m, "Rim", cf, Vector3.new(width, RIM_H, RIM_D), C.RimSide, { Collide = true, Shadow = false })
		block(m, "RimTop", cf * CFrame.new(0, RIM_H / 2 + 0.06, 0), Vector3.new(width - 0.1, 0.12, RIM_D - 0.36), C.RimTop, { Collide = true, Shadow = false })
	end
	-- the dark navy disc (four turned squares: a 16-gon whose corners hide under the rim) with a lighter heart
	polygon16(m, "Disc", A * CFrame.new(0, 0.08, 0), DISC_S, 0.2, C.Disc, { Collide = true, Shadow = false })
	polygon16(m, "DiscHeart", A * CFrame.new(0, 0.1, 0) * CFrame.Angles(0, math.rad(11.25), 0), 6.2, 0.2, C.DiscInner, { Shadow = false })
	-- dim glowing runes around the heart and a small diamond in the middle
	for i = 0, 7 do
		local cf = polarCF(A, i * 45 + 22.5, 5.05, 0.22)
		block(m, "Rune", cf, Vector3.new(0.9, 0.06, 0.36), C.Rune, { Material = MAT.Neon, Transparency = 0.35, Shadow = false })
	end
	block(m, "Rune", A * CFrame.new(0, 0.22, 0) * CFrame.Angles(0, math.rad(45), 0), Vector3.new(1.3, 0.06, 1.3), C.Rune, { Material = MAT.Neon, Transparency = 0.25, Shadow = false })
	return m
end

----------------------------------------------------------------------
-- Bridge: island -> dock, deck at the island height over the junction rail, steps down onto the street
----------------------------------------------------------------------
local puffTemplate = nil

local function stormPuff()
	if puffTemplate ~= nil then
		return puffTemplate or nil
	end
	puffTemplate = false
	if not Voxel then
		return nil
	end
	local ok, model = pcall(function()
		local g = Voxel.NewGrid(8)
		Voxel.Shape(g, { Kind = "Ellipsoid", Center = { 0, 0, 0 }, Radius = { 3.2, 1.5, 2.3 }, Key = "Body" })
		Voxel.Shape(g, { Kind = "Ellipsoid", Center = { 2.3, -0.5, 0.6 }, Radius = { 1.9, 1.3, 1.7 }, Key = "Body", KeepExisting = true })
		Voxel.Shade(g, { Smooth = 2, Seed = 4, Dark = false })
		return Voxel.Build(g, { VoxelSize = 1.4, Palette = ISLAND_PALETTE, Name = "StormPuff", MaxParts = 7 })
	end)
	if ok and model then
		puffTemplate = model
	else
		warn("[StormAltar] storm puff failed: " .. tostring(model))
	end
	return puffTemplate or nil
end

local function placePuff(parent, cf)
	local tpl = stormPuff()
	if not tpl then
		return
	end
	local m = tpl:Clone()
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CFrame = cf * d.CFrame
		end
	end
	m.Parent = parent
end

-- a stone post with a small crystal on top
local function lantern(parent, cf)
	block(parent, "LanternPost", cf * CFrame.new(0, 1.1, 0), Vector3.new(1.1, 2.2, 1.1), C.StoneB, { Collide = true, Shadow = false })
	local top = cf * CFrame.new(0, 2.2 + 0.45, 0) * CFrame.Angles(0, math.rad(45), 0)
	block(parent, "LanternGlass", top, Vector3.new(0.75, 0.9, 0.75), C.CrystalGlass, { Material = MAT.Glass, Transparency = 0.3, Shadow = false })
	block(parent, "LanternCore", top, Vector3.new(0.42, 0.86, 0.42), C.CrystalCore, { Material = MAT.Neon, Shadow = false })
end

-- landing: island edge point, dock: street point (both world, any height). Returns the bridge model and the
-- ground CFrame of the entrance gate (on the street, just past the dock; LookVector = towards the street).
-- Profile: RAMP_LEVEL studs level at the island height, then a straight ramp down to the street height at the
-- dock, then a short level lip that rests on the junction (the junction's inner rail is left open for it).
local function buildBridge(parent, A, landing, dock)
	local deckTop = A.Position.Y + 0.1
	local street = dock.Y
	local endTop = street + 0.06
	local flatA = Vector3.new(landing.X, 0, landing.Z)
	local span = Vector3.new(dock.X, 0, dock.Z) - flatA
	local len = span.Magnitude
	if len < 10 then
		return nil
	end
	local dir = span.Unit
	local m = newModel(parent, "Bridge")
	local over = 1.2 -- the lip past the dock, resting on the street junction
	local level = math.min(RAMP_LEVEL, len * 0.3)
	local function topAt(s)
		if s <= level then
			return deckTop
		elseif s >= len then
			return endTop
		end
		return deckTop + (endTop - deckTop) * (s - level) / (len - level)
	end
	local function pointAt(s)
		local p = flatA + dir * s
		return Vector3.new(p.X, topAt(s), p.Z)
	end
	-- a segment frame: origin on the deck top at s0, -Z down the segment (tilted with the ramp)
	local function segFrame(s0, s1)
		return CFrame.lookAt(pointAt(s0), pointAt(s1))
	end
	local function segLen(s0, s1)
		return (pointAt(s1) - pointAt(s0)).Magnitude
	end

	-- deck: stone slabs with thin seams over a dark beam, per segment
	local slabIndex = 0
	for _, seg in ipairs({ { 0, level }, { level, len }, { len, len + over } }) do
		local cf = segFrame(seg[1], seg[2])
		local sLen = segLen(seg[1], seg[2])
		local slabs = math.max(1, math.floor(sLen / 7 + 0.5))
		local sl = sLen / slabs
		for i = 1, slabs do
			slabIndex = slabIndex + 1
			block(m, "Deck", cf * CFrame.new(0, -0.5, -(i - 0.5) * sl), Vector3.new(BRIDGE_W, 1, sl - 0.14), (slabIndex % 2 == 0) and C.StoneC or C.Stone, { Collide = true })
		end
		if sLen > 2 then
			block(m, "Beam", cf * CFrame.new(0, -1.4, -sLen / 2), Vector3.new(BRIDGE_W - 1.6, 0.9, sLen - 0.4), C.StoneDeep, { Shadow = false })
		end
	end

	-- low parapets (tilted with the deck) with upright crystal lanterns; they stop before the gate's walls
	local mid = (level + len) / 2
	local pieces = { { 1.75, level }, { level, mid - 0.55 }, { mid + 0.55, len - 1.2 } }
	for _, side in ipairs({ -1, 1 }) do
		local x = side * (BRIDGE_W / 2 - 0.35)
		for _, p in ipairs(pieces) do
			local sa, sb = p[1], p[2]
			if sb - sa > 1 then
				local cf = segFrame(sa, sb)
				local l = segLen(sa, sb)
				local c = cf * CFrame.new(x, 0.55, -l / 2)
				block(m, "Parapet", c, Vector3.new(0.7, 1.1, l), C.StoneB, { Collide = true })
				block(m, "ParapetCap", c * CFrame.new(0, 0.62, 0), Vector3.new(0.9, 0.14, l), C.StoneLight, { Collide = true, Shadow = false })
			end
		end
		for _, s in ipairs({ mid }) do
			local p = pointAt(s) + CFrame.lookAt(Vector3.new(), dir).RightVector * x
			lantern(m, CFrame.lookAt(p, p + dir) * CFrame.new(0, -0.4, 0))
		end
	end

	-- a storm puff carries the ramp (under the deck: nothing pokes through it)
	for _, t in ipairs({ 0.55 }) do
		local p = pointAt(len * t)
		placePuff(m, CFrame.lookAt(p, p + dir) * CFrame.new(0, -2.8, 0) * CFrame.Angles(0, t * 5, 0))
	end
	-- the entrance gate stands on the street over the bridge's foot, its poster facing the street
	local g = flatA + dir * (len + 0.85)
	local gate = Vector3.new(g.X, street, g.Z)
	return m, CFrame.lookAt(gate, gate + dir)
end

----------------------------------------------------------------------
-- Sign: the entrance gate with its art panel (SurfaceGui) + a title tag above the altar
----------------------------------------------------------------------
local function corner(parent, scaleOrPx, isScale)
	local c = Instance.new("UICorner")
	if isScale then
		c.CornerRadius = UDim.new(scaleOrPx, 0)
	else
		c.CornerRadius = UDim.new(0, scaleOrPx)
	end
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function frame(parent, name, pos, size, color)
	local f = Instance.new("Frame")
	f.Name = name
	f.Position = pos
	f.Size = size
	f.BackgroundColor3 = color or C.White
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function gradient(parent, top, bottom)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = 90
	g.Parent = parent
	return g
end

local function label(parent, text, role, props, outline)
	local l = Theme.Label(text, role, { Color = props.Color or C.White, Stroke = 0, Outline = outline or 2, OutlineColor = C.Ink, Scaled = props.Scaled, Size = props.Size })
	l.Name = props.Name or "Text"
	l.AnchorPoint = props.AnchorPoint or Vector2.new(0.5, 0.5)
	l.Position = props.Position or UDim2.fromScale(0.5, 0.5)
	l.Size = props.Box or UDim2.fromScale(1, 1)
	l.TextWrapped = false
	l.ZIndex = 3
	l.Parent = parent
	return l
end

-- glossy strip over the top half of a bar (the chunky cloud UI look)
local function gloss(parent, radiusPx)
	local g = frame(parent, "Gloss", UDim2.new(0, 4, 0, 3), UDim2.new(1, -8, 0.46, 0), C.White)
	g.BackgroundTransparency = 0.78
	g.ZIndex = 2
	corner(g, radiusPx)
	return g
end

-- Gate poster: a SurfaceGui of 600 x 320 px (PANEL_W x PANEL_H studs at 50 px per stud) in the chunky cloud UI
-- style. World text rule: "STORM ALTAR" in two 56 px lines (1.12 studs), "Secret pets" 34 px (0.68 stud) and
-- "Awakens soon" 32 px (0.64 stud), so every line reads from ~30 studs; the player's art fills a 284 px
-- (5.7-stud) square well on the left.
local function panelGui(board)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "PosterGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = POSTER_PPS
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Adornee = board

	local card = frame(gui, "Card", UDim2.fromOffset(6, 6), UDim2.new(1, -12, 1, -12), C.White)
	corner(card, 24)
	stroke(card, C.Navy, 6)
	gradient(card, C.StormTop, C.Storm)

	-- the player's art in a dark well (left)
	local well = frame(card, "ArtWell", UDim2.fromOffset(12, 12), UDim2.fromOffset(284, 284), C.White)
	corner(well, 18)
	stroke(well, C.CrystalCore, 4)
	gradient(well, rgb(40, 50, 92), rgb(20, 26, 54))
	local art = Instance.new("ImageLabel")
	art.Name = "StormfangArt"
	art.BackgroundTransparency = 1
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.5, 0.5)
	art.Size = UDim2.new(1, -12, 1, -12)
	art.Image = Config.Art and Config.Art.StormfangImage or ""
	art.ScaleType = Enum.ScaleType.Fit
	art.ZIndex = 3
	art.Parent = well
	corner(art, 12)

	-- right column (x 308..572): the title bar, the "Secret pets" pill, the phase 1 caption
	local colX, colW = 308, 264
	local bar = frame(card, "TitleBar", UDim2.fromOffset(colX, 12), UDim2.fromOffset(colW, 140), C.White)
	corner(bar, 20)
	stroke(bar, C.Navy, 5)
	gradient(bar, rgb(84, 196, 255), rgb(40, 112, 214))
	gloss(bar, 14)
	local title = label(bar, "STORM\nALTAR", "Title", { Name = "Title", Size = 56, Box = UDim2.new(1, -16, 1, -10) }, 4)
	title.LineHeight = 0.9

	local pill = frame(card, "SecretPill", UDim2.fromOffset(colX, 164), UDim2.fromOffset(colW, 58), C.White)
	corner(pill, 29)
	stroke(pill, C.Navy, 5)
	gradient(pill, rgb(150, 98, 255), rgb(88, 46, 204))
	gloss(pill, 22)
	label(pill, "Secret pets", "Title", { Name = "Subtitle", Size = 34, Box = UDim2.new(1, -16, 1, -6) }, 3)
	label(card, "Awakens soon", "Body", { Name = "Caption", Size = 32, Color = C.Cyan, AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromOffset(colX, 232), Box = UDim2.fromOffset(colW, 48) }, 3)

	gui.Parent = board
	return gui
end

-- Title tag above the altar (readable from the plaza and the street). World text rule: a PIXEL-sized billboard,
-- so "STORM ALTAR" (36 px) and "Secret pets" (22 px) keep their on-screen size at any distance.
local TAG_W, TAG_H, TAG_TITLE, TAG_SUB = 300, 100, 36, 22
local function titleTag(anchor)
	local gui = Instance.new("BillboardGui")
	gui.Name = "TitleTag"
	gui.Size = UDim2.fromOffset(TAG_W, TAG_H)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 150
	gui.Adornee = anchor

	local card = frame(gui, "Card", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), C.White)
	card.BackgroundTransparency = 0.06
	corner(card, 0.3, true)
	stroke(card, C.Electric, 4)
	gradient(card, rgb(70, 60, 130), rgb(28, 36, 76))
	local shine = frame(card, "Gloss", UDim2.new(0.03, 0, 0.06, 0), UDim2.new(0.94, 0, 0.4, 0), C.White)
	shine.BackgroundTransparency = 0.86
	shine.ZIndex = 2
	corner(shine, 0.5, true)
	label(card, "STORM ALTAR", "Title", { Name = "Title", Size = TAG_TITLE, Position = UDim2.fromScale(0.5, 0.36), Box = UDim2.fromScale(0.9, 0.56) }, 3)
	label(card, "Secret pets", "Heading", { Name = "Subtitle", Size = TAG_SUB, Color = C.Cyan, Position = UDim2.fromScale(0.5, 0.78), Box = UDim2.fromScale(0.7, 0.3) }, 2)
	gui.Parent = anchor
	return gui
end

-- The stone entrance gate on the street, over the bridge's foot. cf: ground centre (the street surface),
-- LookVector = towards the street (the poster's face). Two charcoal pillars with crystal tips carry a lintel;
-- the poster hangs between them PANEL_BOTTOM studs up, in a light stone frame; low walls close the gaps between
-- the bridge and the pillars (the junction's inner rail is open here).
local function buildGate(parent, cf)
	local m = newModel(parent, "Gate")
	local px = GATE_HALF
	local pillarH = PILLAR_TOP + 0.6 -- from 0.6 under the street surface (rests in the junction planks)
	for _, side in ipairs({ -1, 1 }) do
		block(m, "GatePillar", cf * CFrame.new(side * px, PILLAR_TOP - pillarH / 2, 0), Vector3.new(PILLAR_W, pillarH, PILLAR_W), C.Stone, { Collide = true })
		block(m, "GatePlinth", cf * CFrame.new(side * px, 0.28, 0), Vector3.new(PILLAR_W + 0.6, 1.86, PILLAR_W + 0.6), C.StoneDeep, { Collide = true })
		-- a low wall from the bridge's edge to the pillar
		local wallW = px - PILLAR_W / 2 - BRIDGE_W / 2
		if wallW > 0.3 then
			local wcf = cf * CFrame.new(side * (BRIDGE_W / 2 + wallW / 2), 0.35, 0)
			block(m, "GateWall", wcf, Vector3.new(wallW, 1.9, 1), C.StoneB, { Collide = true })
			block(m, "GateWallCap", wcf * CFrame.new(0, 1.02, 0), Vector3.new(wallW, 0.16, 1.2), C.StoneLight, { Collide = true, Shadow = false })
		end
		-- a crystal on the lintel above each pillar
		local tip = cf * CFrame.new(side * px, PILLAR_TOP + 1.45, 0) * CFrame.Angles(0, math.rad(45), 0)
		block(m, "GateGemGlass", tip, Vector3.new(0.9, 1.6, 0.9), C.CrystalGlass, { Material = MAT.Glass, Transparency = 0.25, Shadow = false })
		local core = block(m, "GateGemCore", tip, Vector3.new(0.52, 1.5, 0.52), C.CrystalCore, { Material = MAT.Neon, Shadow = false })
		pointLight(core, 0.8, 9)
	end
	local panelY = PANEL_BOTTOM + PANEL_H / 2
	-- lintel across the pillar tops; the poster's stone frame hangs from it on the street face of the pillars
	block(m, "GateLintel", cf * CFrame.new(0, PILLAR_TOP + 0.35, PANEL_Z / 2), Vector3.new(2 * px + PILLAR_W + 0.8, 0.7, PILLAR_W - PANEL_Z + 0.2), C.StoneLight, { Collide = true })
	local frameH = PILLAR_TOP - PANEL_BOTTOM + 0.4
	block(m, "GateFrame", cf * CFrame.new(0, PILLAR_TOP - frameH / 2, PANEL_Z), Vector3.new(PANEL_W + 0.6, frameH, 0.4), C.StoneLight, { Shadow = false })
	-- the back of the frame between the pillars, with a diamond emblem (seen from the island)
	block(m, "GateBack", cf * CFrame.new(0, panelY, PANEL_Z + 0.25), Vector3.new(2 * px - PILLAR_W, PANEL_H - 0.4, 0.1), C.StoneB, { Shadow = false })
	local emblem = cf * CFrame.new(0, panelY, PANEL_Z + 0.4) * CFrame.Angles(0, 0, math.rad(45))
	block(m, "GateGemGlass", emblem, Vector3.new(1.8, 1.8, 0.3), C.CrystalGlass, { Material = MAT.Glass, Transparency = 0.25, Shadow = false })
	block(m, "GateGemCore", emblem * CFrame.new(0, 0, 0.06), Vector3.new(1.1, 1.1, 0.3), C.CrystalCore, { Material = MAT.Neon, Shadow = false })
	local gem = cf * CFrame.new(0, PILLAR_TOP + 1.25, PANEL_Z) * CFrame.Angles(0, 0, math.rad(45))
	block(m, "GateGemGlass", gem, Vector3.new(1.3, 1.3, 0.6), C.CrystalGlass, { Material = MAT.Glass, Transparency = 0.25, Shadow = false })
	block(m, "GateGemCore", gem * CFrame.new(0, 0, -0.08), Vector3.new(0.8, 0.8, 0.6), C.CrystalCore, { Material = MAT.Neon, Shadow = false })
	local board = block(m, "GatePanel", cf * CFrame.new(0, panelY, PANEL_Z - 0.25), Vector3.new(PANEL_W, PANEL_H, 0.3), C.Storm, { Shadow = false })
	panelGui(board)
	return m
end

-- gateCF: ground centre of the entrance gate (LookVector = towards the street), or nil.
local function buildSign(parent, A, gateCF, titleY)
	local m = newModel(parent, "StormAltarSign")
	if not gateCF then
		-- no bridge: a free-standing gate at the island's back edge
		local back = -A.LookVector
		local p = A.Position + back * (R_TOP - 5)
		gateCF = flatLook(p, p + back)
	end
	buildGate(m, gateCF)
	-- title tag above the showcase
	local anchor = invisible(m, "TitleAnchor", A * CFrame.new(0, titleY, 0))
	titleTag(anchor)
	return m
end

----------------------------------------------------------------------
-- Showcase: the big Stormfang
----------------------------------------------------------------------
local function stormfangDef()
	local def = nil
	if PetCatalog and type(PetCatalog.Get) == "function" then
		local ok, result = pcall(PetCatalog.Get, PET_ID)
		if ok and type(result) == "table" then
			def = result
		end
	end
	if not def then
		-- the catalog entry is not there (yet): a neutral look of the species
		def = { Id = PET_ID, Name = "Stormfang", Rarity = "Secret", Look = { Species = "Stormfang", WingStyle = "StormCloud" } }
	end
	return def
end

-- Lowest / highest point and horizontal reach of a model's parts relative to `origin`.
local function extents(model, origin)
	local lo, hi, reach = math.huge, -math.huge, 0
	local inv = origin:Inverse()
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local cf = inv * d.CFrame
			local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
			local s = d.Size
			local hy = (math.abs(r10) * s.X + math.abs(r11) * s.Y + math.abs(r12) * s.Z) / 2
			local hx = (math.abs(r00) * s.X + math.abs(r01) * s.Y + math.abs(r02) * s.Z) / 2
			local hz = (math.abs(r20) * s.X + math.abs(r21) * s.Y + math.abs(r22) * s.Z) / 2
			local p = cf.Position
			lo = math.min(lo, p.Y - hy)
			hi = math.max(hi, p.Y + hy)
			reach = math.max(reach, math.abs(p.X) + hx, math.abs(p.Z) + hz)
		end
	end
	if lo == math.huge then
		return nil
	end
	return lo, hi, reach
end

-- Returns the showcase model (or nil) and the height of its top above the walking surface.
local function buildShowcase(parent, A)
	if not PetBuilder or type(PetBuilder.Build) ~= "function" then
		warn("[StormAltar] PetBuilder is unavailable: no Stormfang showcase")
		return nil, HOVER + 10
	end
	local def = stormfangDef()
	local ok, pet = pcall(PetBuilder.Build, def, { Detail = "High", Scale = 3 })
	if not ok or typeof(pet) ~= "Instance" then
		warn("[StormAltar] Stormfang showcase failed: " .. tostring(pet))
		return nil, HOVER + 10
	end
	pet.Name = "StormfangShowcase"
	pet:PivotTo(CFrame.new())
	local lo, hi, reach = extents(pet, CFrame.new())
	lo, hi, reach = lo or -4, hi or 5, reach or 4.5
	-- hover over the portal, leaning forward (prowling) about the bottom centre
	local pose = A * CFrame.new(0, HOVER, 0) * CFrame.Angles(PROWL, 0, 0) * CFrame.new(0, -lo, 0)
	pet:PivotTo(pose)
	local parts = 0
	for _, d in ipairs(pet:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			parts = parts + 1
		end
	end
	pet:SetAttribute("PetId", def.Id or PET_ID)
	pet:SetAttribute("PetParts", parts)
	pet:SetAttribute("HoverAmp", 0.45)
	pet:SetAttribute("Ready", true)
	CollectionService:AddTag(pet, SHOWCASE_TAG)
	pet.Parent = parent

	-- one invisible collider keeps players out of the big (non-colliding) pet
	local height = HOVER + (hi - lo)
	local radius = math.min(math.max(reach * 0.8, 3.5), RIM_R - 0.6)
	local col = block(parent, "ShowcaseCollider", A * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.rad(90)), Vector3.new(height, radius * 2, radius * 2), C.Storm, { Collide = true, Transparency = 1, Shadow = false })
	col.Shape = Enum.PartType.Cylinder
	col.CanQuery = false
	return pet, height
end

----------------------------------------------------------------------
-- Prompt, lights, sparkles
----------------------------------------------------------------------
-- A side toast for that player (rate-limited per player: TOAST_COOLDOWN).
local function notify(player, text)
	local now = os.clock()
	local last = lastToast[player]
	if last and now - last < TOAST_COOLDOWN then
		return
	end
	lastToast[player] = now
	local ok, remote = pcall(Remotes.Get, "Notify")
	if ok and remote and player.Parent then
		remote:FireClient(player, text or TOAST, "info", 5)
	end
end

-- GemService (Phase 2) is optional and loaded after this module: looked up when the prompt is used.
local gemModule = nil
local function gemService()
	if gemModule then
		return gemModule
	end
	local inst = script.Parent and script.Parent:FindFirstChild("GemService")
	if not inst then
		return nil
	end
	local ok, result = pcall(require, inst)
	if ok and type(result) == "table" then
		gemModule = result
		return result
	end
	return nil
end

-- "Open" | "Restricted" | "Checking" | "Unavailable" (no GemService: the phase 1 behaviour)
local function secretState(player)
	local gems = gemService()
	if not gems or type(gems.SecretRouletteState) ~= "function" then
		return "Unavailable"
	end
	local ok, state = pcall(gems.SecretRouletteState, player)
	if ok and type(state) == "string" then
		return state
	end
	return "Unavailable"
end

-- Opens the Shop on the gems-only Secret roulette (no Tab: the Shop picks the tab that holds that roulette).
local function openSecretRoulette(player)
	local now = os.clock()
	local last = lastOpen[player]
	if last and now - last < OPEN_COOLDOWN then
		return
	end
	lastOpen[player] = now
	local ok, remote = pcall(Remotes.Get, "OpenPanel")
	if ok and remote and player.Parent then
		remote:FireClient(player, "Shop", { RouletteId = SECRET_ROULETTE_ID, Currency = "Gems" })
	end
end

local function onAltarUsed(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return
	end
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return
	end
	local state = secretState(player)
	if state == "Open" then
		openSecretRoulette(player)
	elseif state == "Restricted" then
		notify(player, TOAST_RESTRICTED)
	else
		notify(player, TOAST) -- the gem system is missing or still checking this account
	end
	StormAltar.Used:Fire(player)
end

local function buildPrompt(parent, A)
	local part = invisible(parent, "AltarPrompt", A * CFrame.new(0, 2.4, 0))
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StormAltarPrompt"
	prompt.ActionText = "Summon"
	prompt.ObjectText = "Storm Altar"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 21
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	prompt.Triggered:Connect(onAltarUsed)
	-- the portal's soft glow and a few sparkles rising from it
	pointLight(part, 1.3, 14)
	local rise = Instance.new("Attachment")
	rise.Name = "PortalSparkles"
	rise.CFrame = CFrame.new(0, -2.1, 0)
	rise.Parent = part
	sparkles(rise, 4, 2.2, 0.5)
	return prompt
end

local function hookPlayers()
	if playersHooked then
		return
	end
	playersHooked = true
	Players.PlayerRemoving:Connect(function(player)
		lastToast[player] = nil
		lastOpen[player] = nil
	end)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
local function containerOf(lobbyInfo)
	local folder = type(lobbyInfo) == "table" and lobbyInfo.Folder or nil
	if typeof(folder) == "Instance" and (folder:IsA("Folder") or folder:IsA("Model")) and folder:IsDescendantOf(Workspace) then
		return folder
	end
	return Workspace
end

function StormAltar.Build(lobbyInfo)
	hookPlayers()
	local container = containerOf(lobbyInfo)
	-- rebuild: replace an older altar
	local old = container:FindFirstChild(MODEL_NAME) or Workspace:FindFirstChild(MODEL_NAME, true)
	if old and old:IsA("Model") then
		old:Destroy()
	end
	altarModel, altarCFrame = nil, nil

	local info = type(lobbyInfo) == "table" and lobbyInfo or {}
	local site = typeof(info.AltarSite) == "CFrame" and info.AltarSite or nil
	if not site then
		site = fallbackSite(info)
	end
	site = flatLook(site.Position, site.Position + site.LookVector) -- yaw only
	local top = site.Position.Y -- the lobby's walking height
	local A = site * CFrame.new(0, DECK, 0)

	local model = Instance.new("Model")
	model.Name = MODEL_NAME
	model:SetAttribute("Phase", 1)
	local core = invisible(model, "AltarCore", A)
	model.PrimaryPart = core

	local dock = typeof(info.AltarDock) == "Vector3" and info.AltarDock or nil
	if not dock then
		dock = findDock(site, top, { model })
	end
	-- bridge direction (altar-local angle) and the landing on the island's edge
	local gapDeg, landing = 180, nil
	if dock then
		local dl = A:PointToObjectSpace(dock)
		gapDeg = math.deg(atan2(dl.X, -dl.Z)) % 360
		local flat = Vector3.new(dock.X - A.Position.X, 0, dock.Z - A.Position.Z)
		if flat.Magnitude > R_TOP + 2 then
			landing = A.Position + flat.Unit * (R_TOP - 4)
		end
	end

	section("island", function()
		buildIsland(model, A, gapDeg)
	end)
	local tops = {}
	section("stone ring", function()
		local _, t = buildRing(model, A)
		tops = t or {}
	end)
	section("portal", function()
		buildPortal(model, A)
	end)
	local headTip = 0
	section("crystals", function()
		local _, tip = buildCrystals(model, A, tops)
		headTip = tip or 0
	end)
	local gateCF = nil
	if landing and dock then
		section("bridge", function()
			local _, g = buildBridge(model, A, landing, Vector3.new(dock.X, top, dock.Z))
			gateCF = g
		end)
	end
	local showTop = HOVER + 10
	section("showcase", function()
		local _, h = buildShowcase(model, A)
		showTop = h or showTop
	end)
	section("sign", function()
		-- the title tag floats clear of the showcase and the head crystal
		buildSign(model, A, gateCF, math.max(showTop, headTip) + 4.6)
	end)
	section("prompt", function()
		buildPrompt(model, A)
	end)
	section("lights", function()
		-- the head crystal glows softly onto the stones and the cloud
		local glow = invisible(model, "CrystalGlow", polarCF(A, 180, RING_C - 1.5, 7))
		pointLight(glow, 1, 10)
		sparkles(glow, 1.5, 1, 0.35)
	end)

	-- part budget (the showcase pet is excluded)
	local parts = 0
	local showcase = model:FindFirstChild("StormfangShowcase")
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and not (showcase and d:IsDescendantOf(showcase)) then
			parts = parts + 1
		end
	end
	if parts > MAX_PARTS then
		warn(string.format("[StormAltar] %d parts (budget %d)", parts, MAX_PARTS))
	end

	model.Parent = container -- parented last: the whole altar replicates in one step
	altarModel = model
	altarCFrame = A
	print(string.format("[StormAltar] built (%d parts + showcase)", parts))
	return A
end

function StormAltar.GetModel()
	if altarModel and altarModel.Parent then
		return altarModel
	end
	return nil
end

function StormAltar.GetCFrame()
	return altarCFrame
end

return StormAltar
