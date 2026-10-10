-- NpcService: builds the six NPC pets of the lobby (ARCHITECTURE_V3.md section 5).
--
--   NpcService.Init(lobbyInfo, deps)   builds every NPC of shared/NpcDialog at lobbyInfo.NpcSpots[i] (6 ground-level
--                                      CFrames facing the walkway; missing ones fall back to 6 points around the
--                                      plaza). Safe to call again: the old NPCs are replaced. Returns GetNpcs().
--   NpcService.GetNpcs() -> { { Id, Name, Model, Pet, Prompt, Spot }, ... }
--   NpcService.GetNpc(id) -> record | nil
--   NpcService.FallbackSpots(lobbyInfo, count) -> { CFrame, ... }
--   NpcService.Talked                  Util.Signal; Fire(player, npcId) when a player uses an NPC's prompt
--
-- Every NPC is a Model "Npc_<Id>" in workspace.NimbusNpcs, tagged NpcDialog.Tag ("NC_Npc") with the attributes
-- NpcId, NpcName, Title, PetId, Accent (Color3) and PetParts (the pet's part count, so a client can tell when it
-- has fully replicated). Inside it:
--   Pedestal     a crafted voxel plinth (shared/Voxel.lua): a stepped stone base with a coloured tile band, studs,
--                a gold plaque, moss on the rim, tiny flowers and a patterned rug in the NPC's accent colour
--   Pet          PetBuilder.Build(catalog pet, { Detail = "High", Scale = 2.2 }) hovering above the rug, facing the
--                spot's LookVector (the walkway)
--   Collider     one invisible collidable cylinder around plinth + pet (players bump into the NPC, never stand in it)
--   PromptPart   an invisible part at the pet's centre holding the BillboardGui "Nameplate" (name + title pills and
--                a gold "!" badge; Theme fonts, readable sizes), a soft light, a few rising sparkles and the Attachment
--                "PromptAnchor" (front of the cushion) with the ProximityPrompt "TalkPrompt" (ActionText "Talk",
--                ObjectText = Name, HoldDuration 0, MaxActivationDistance 10, RequiresLineOfSight false, attribute NpcId)
-- The server never moves an NPC after building it: client/Controllers/NpcController idles them and shows the
-- dialog. The pets are not part of the lobby folder, so the lobby's part budget is unaffected.
-- Plain Lua 5.1-compatible syntax only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))

local function optional(name)
	local module = Shared:FindFirstChild(name) or Shared:WaitForChild(name, 5)
	if not module then
		warn("[NpcService] shared module missing: " .. name)
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[NpcService] failed to load " .. name .. ": " .. tostring(result))
	return nil
end

local NpcDialog = optional("NpcDialog")
local PetCatalog = optional("PetCatalog")
local PetBuilder = optional("PetBuilder")
local Voxel = optional("Voxel")

local NpcService = {}
NpcService.Talked = Util.Signal()

local FOLDER_NAME = "NimbusNpcs"
local TAG = (NpcDialog and NpcDialog.Tag) or "NC_Npc"
local SETTINGS = (NpcDialog and NpcDialog.Settings) or {}
local NPC_SCALE = tonumber(SETTINGS.Scale) or 2.2
local PROMPT_DISTANCE = tonumber(SETTINGS.PromptDistance) or 10
local HOVER_GAP = tonumber(SETTINGS.HoverGap) or 1.0
local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"

-- Pedestal geometry (voxel units; one voxel = PV studs, about two pet voxels at Scale 2.2)
local PV = 0.4
local SINK = 0.15 -- the plinth starts slightly below the spot so it never floats over a lower ground tile
local R_BASE, R_DRUM, R_CAP = 10.6, 9.3, 9.8
local Y_BAND, Y_CAP, Y_CUSHION = 2, 4, 5
local PEDESTAL_TOP = (Y_CUSHION + 2) * PV - SINK -- studs above the spot: the cushion's top surface
local MAX_PEDESTAL_PARTS = 120 -- a safety net only: the design merges to about 100 parts

local records = {}
local folder = nil

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

-- Same stone family as the lobby paths (LobbyBuilder palette), so the plinths belong to the plaza.
local STONE = {
	Base = rgb(150, 142, 136),
	Stone = rgb(208, 202, 190),
	Cap = rgb(226, 221, 209),
	Gold = rgb(244, 198, 84),
	Plaque = rgb(246, 234, 210),
	Moss = rgb(108, 180, 86),
	Leaf = rgb(82, 156, 74),
	Petal1 = rgb(246, 150, 188),
	Petal2 = rgb(250, 214, 92),
	Petal3 = rgb(172, 142, 232),
	Petal4 = rgb(244, 244, 248),
}

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function toCFrame(value)
	if typeof(value) == "CFrame" then
		return value
	elseif typeof(value) == "Vector3" then
		return CFrame.new(value)
	elseif type(value) == "table" and typeof(value.CFrame) == "CFrame" then
		return value.CFrame
	end
	return nil
end

-- Keeps only the yaw of a spot (NPCs stand upright even if a spot CFrame is tilted).
local function flatten(cf)
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end
	local pos = cf.Position
	return CFrame.lookAt(pos, pos + flat.Unit)
end

local function lighten(c, t)
	return c:Lerp(Color3.new(1, 1, 1), t)
end

local function darken(c, t)
	return c:Lerp(Color3.fromRGB(26, 30, 52), t)
end

local function make(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props) do
		inst[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(parent, px)
	return make("UICorner", { CornerRadius = UDim.new(0, px) }, parent)
end

local function stroke(parent, color, thickness)
	return make("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

-- Lowest / highest point and horizontal reach of every part of `model`, relative to `origin`.
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

local function countParts(model)
	local n = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			n = n + 1
		end
	end
	return n
end

----------------------------------------------------------------------
-- Spots
----------------------------------------------------------------------
-- Ground height under a point (the plaza surface), ignoring the NPC folder.
local function groundY(pos, fallbackY)
	local ok, hit = pcall(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		if folder then
			params.FilterDescendantsInstances = { folder }
		end
		return Workspace:Raycast(Vector3.new(pos.X, fallbackY + 30, pos.Z), Vector3.new(0, -60, 0), params)
	end)
	if ok and hit and hit.Position and math.abs(hit.Position.Y - fallbackY) <= 4 then
		return hit.Position.Y -- the plaza surface (a hit on a tree or an arch is ignored)
	end
	return fallbackY
end

-- Six points on the plaza lawn (radius 58): two between the portal walkways, four towards the shop island.
function NpcService.FallbackSpots(lobbyInfo, count)
	count = tonumber(count) or 6
	local lobby = Config.Lobby or {}
	local origin = lobby.Origin or Vector3.new(0, 300, 0)
	local shop = lobby.ShopOffset or Vector3.new(0, 0, -150)
	local shopAngle = math.deg(math.atan2(shop.Z, shop.X))
	local angles = { 22.5, 157.5, shopAngle - 30, shopAngle + 30, shopAngle - 60, shopAngle + 60 }
	local radius = math.min(58, (lobby.PlazaRadius or 110) * 0.53)
	local spots = {}
	for i = 1, count do
		local a = math.rad(angles[(i - 1) % #angles + 1] + math.floor((i - 1) / #angles) * 11)
		local pos = Vector3.new(origin.X + math.cos(a) * radius, origin.Y, origin.Z + math.sin(a) * radius)
		pos = Vector3.new(pos.X, groundY(pos, origin.Y), pos.Z)
		spots[i] = CFrame.lookAt(pos, Vector3.new(origin.X, pos.Y, origin.Z))
	end
	return spots
end

local function resolveSpots(lobbyInfo, count)
	local spots = {}
	local given = type(lobbyInfo) == "table" and lobbyInfo.NpcSpots or nil
	if type(given) == "table" then
		for i = 1, count do
			local cf = toCFrame(given[i])
			if cf then
				spots[i] = flatten(cf)
			end
		end
	end
	local fallback = nil
	for i = 1, count do
		if not spots[i] then
			fallback = fallback or NpcService.FallbackSpots(lobbyInfo, count)
			spots[i] = fallback[i]
		end
	end
	return spots
end

----------------------------------------------------------------------
-- Pedestal (sculpted voxel plinth)
----------------------------------------------------------------------
local function disc(g, r, y, key, test)
	local ri = math.ceil(r)
	local r2 = r * r
	for x = -ri, ri do
		for z = -ri, ri do
			local d2 = x * x + z * z
			if d2 <= r2 then
				local k = key
				if test then
					k = test(x, z, math.sqrt(d2))
				end
				if k then
					Voxel.Set(g, x, y, z, k)
				end
			end
		end
	end
end

local function pedestalPalette(accent)
	local pal = {}
	for k, v in pairs(STONE) do
		pal[k] = v
	end
	pal.Trim = darken(accent, 0.3)
	pal.Rug = darken(accent, 0.12)
	pal.RugTop = accent
	pal.RugTrim = lighten(accent, 0.42)
	pal.RugCenter = rgb(250, 224, 146)
	pal.Gold = { Color = STONE.Gold, Material = Enum.Material.SmoothPlastic, Reflectance = 0.05 }
	return pal
end

-- Voxel position on a circle (rounded to the grid).
local function onCircle(deg, r)
	local a = math.rad(deg)
	return math.floor(math.cos(a) * r + 0.5), math.floor(math.sin(a) * r + 0.5)
end

-- A plinth with a classic profile, its stone in three shades by height (dark foot, mid drum, pale cap):
-- foot, drum with a tile band in the accent colour + gold rivets + a gold-framed plaque at the front, an
-- overhanging cap with moss clumps, and a plump square cushion with a trim border, a gold medallion and tassels.
-- Whole flat layers keep the greedy merge cheap (about 100 parts), so no colour ever gets lost to the LOD.
local function sculptPedestal(seed)
	local g = Voxel.NewGrid(8)
	disc(g, R_BASE, 0, "Base")
	disc(g, R_DRUM, 1, "Stone")
	disc(g, R_DRUM, Y_BAND, "Trim")
	disc(g, R_DRUM, 3, "Stone")
	disc(g, R_CAP, Y_CAP, "Cap")

	-- gold rivets standing out of the band every 45 degrees (the front one gives way to the plaque)
	for i = 0, 7 do
		local deg = i * 45
		if deg ~= 270 then
			local x, z = onCircle(deg, R_DRUM + 0.9)
			Voxel.Set(g, x, Y_BAND, z, "Gold")
		end
	end

	-- plaque on the front (the pet faces -Z): a flat gold frame around a recessed cream plate
	local zFront = -math.floor(R_DRUM)
	for x = -3, 3 do
		for y = 1, 3 do
			if math.abs(x) == 3 or y ~= Y_BAND then
				Voxel.Set(g, x, y, zFront, "Gold")
			else
				Voxel.Set(g, x, y, zFront, nil)
				Voxel.Set(g, x, y, zFront + 1, "Plaque")
			end
		end
	end

	-- small moss clumps creeping over the cap rim: back and sides only, placement varies per NPC
	local clumps = { 30 + (seed * 17) % 120, 160 + (seed * 29) % 60, 330 + (seed * 13) % 40 }
	for _, deg in ipairs(clumps) do
		for k = -1, 1 do
			local x, z = onCircle(deg + k * 6, R_CAP - 0.4)
			Voxel.Set(g, x, Y_CAP, z, "Moss")
		end
		local ox, oz = onCircle(deg, R_CAP + 0.4)
		Voxel.Set(g, ox, Y_CAP - 1, oz, "Moss_Dark") -- a drip hanging over the edge
		local ix, iz = onCircle(deg + 3, R_CAP - 1.4)
		Voxel.Set(g, ix, Y_CAP + 1, iz, "Moss_Light") -- a tuft on top
	end

	-- cushion: side band, lighter top with a trim border, gold medallion, gold corner tassels
	local half = 6
	for x = -half, half do
		for z = -half, half do
			if math.abs(x) + math.abs(z) < 2 * half - 1 then -- clipped corners
				Voxel.Set(g, x, Y_CUSHION, z, "Rug")
			end
			local ax, az = math.abs(x), math.abs(z)
			if ax <= half - 1 and az <= half - 1 and ax + az < 2 * half - 3 then
				local key = "RugTop"
				if ax == half - 1 or az == half - 1 or ax + az == 2 * half - 4 then
					key = "RugTrim"
				elseif ax + az <= 2 then
					key = "RugCenter"
				end
				Voxel.Set(g, x, Y_CUSHION + 1, z, key)
			end
		end
	end
	for _, c in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
		Voxel.Set(g, c[1] * (half - 1), Y_CUSHION, c[2] * (half - 1), "Gold")
		Voxel.Set(g, c[1] * half, Y_CUSHION, c[2] * (half - 1), "Gold")
		Voxel.Set(g, c[1] * (half - 1), Y_CUSHION, c[2] * half, "Gold")
	end

	-- little flowers on the foot step: a leaf and a petal each
	for i, deg in ipairs({ 40 + seed * 11, 140 + seed * 7, 235 - seed * 13, 300 + seed * 5 }) do
		local x, z = onCircle(deg, R_BASE - 0.5)
		if Voxel.Get(g, x, 0, z) ~= nil and Voxel.Get(g, x, 1, z) == nil then
			Voxel.Set(g, x, 1, z, "Leaf")
			Voxel.Set(g, x, 2, z, "Petal" .. ((i + seed) % 4 + 1))
		end
	end
	return g
end

local function buildPedestal(parent, spot, accent, seed)
	if not Voxel then
		-- no voxel kit: a plain two-tier plinth so the NPC still stands somewhere
		local m = make("Model", { Name = "Pedestal" }, nil)
		make("Part", {
			Name = "Base", Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
			Shape = Enum.PartType.Cylinder, Material = Enum.Material.SmoothPlastic, Color = STONE.Stone,
			Size = Vector3.new(PEDESTAL_TOP + SINK, R_DRUM * PV * 2, R_DRUM * PV * 2),
			CFrame = spot * CFrame.new(0, (PEDESTAL_TOP - SINK) / 2, 0) * CFrame.Angles(0, 0, math.rad(90)),
		}, m)
		m.Parent = parent
		return m
	end
	local g = sculptPedestal(seed)
	local model = Voxel.Build(g, {
		VoxelSize = PV,
		Palette = pedestalPalette(accent),
		Name = "Pedestal",
		CFrame = spot * CFrame.new(0, PV / 2 - SINK, 0),
		Anchored = true,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
		MaxParts = MAX_PEDESTAL_PARTS,
		Keep = { "Gold", "Trim", "Rug", "RugTop", "RugTrim", "RugCenter", "Plaque" },
		PrimaryKey = "Stone",
	})
	model.Parent = parent
	return model
end

----------------------------------------------------------------------
-- Nameplate
----------------------------------------------------------------------
-- World text rule (ARCHITECTURE_V3.md): a PIXEL-sized tag (constant on-screen size), the name >= 22 px and the
-- title >= 18 px at 1080p with FIXED text sizes (never TextScaled), outlined glyphs on compact solid pills that
-- size themselves to their text. The transparent Plate is the 1080p design box; NpcController scales the tag
-- and Plate (UIScale "ReadScale") with the screen-height factor (attributes BaseWidth / BaseHeight).
local PLATE_W, PLATE_H = 300, 96
local NAME_PX = 28
local TITLE_PX = 19
local INK = Theme.Colors.TextStroke or Theme.Colors.Ink

-- A rounded pill that the engine sizes to its (fixed-size, outlined) text, so no name is ever truncated whatever
-- the real glyph widths: the label carries the padding (its own UIPadding) and grows with AutomaticSize X from a
-- minimum width of minW (the text stays centred), and the pill wraps the label. No list layout, so the corner
-- badge can live on the pill; `extraRight` keeps room for it. Returns pill, label.
local function textPill(parent, name, text, role, size, padX, height, minW, thickness, extraRight)
	local frame = make("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(0, height),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.Colors.White,
		BorderSizePixel = 0,
	}, parent)
	local label = Theme.Label(text, role, {
		Size = size,
		Stroke = 1, -- the glyph outline replaces the classic stroke
		Outline = thickness,
		OutlineColor = INK,
		Props = {
			Name = (name == "NamePill") and "Name" or "Title",
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(minW, height),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false,
		},
	})
	make("UIPadding", {
		PaddingLeft = UDim.new(0, padX + thickness),
		PaddingRight = UDim.new(0, padX + thickness + (extraRight or 0)),
	}, label)
	label.Parent = frame
	return frame, label
end

local function buildNameplate(parent, def, accent, offsetY)
	local gui = make("BillboardGui", {
		Name = "Nameplate",
		Size = UDim2.fromOffset(PLATE_W, PLATE_H),
		SizeOffset = Vector2.new(0, 0.5), -- the bottom edge sits offsetY studs over the pet's head
		StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0),
		AlwaysOnTop = false,
		MaxDistance = 85,
		LightInfluence = 0,
		ClipsDescendants = false,
	}, nil)
	gui:SetAttribute("BaseWidth", PLATE_W)
	gui:SetAttribute("BaseHeight", PLATE_H)

	local plate = make("Frame", {
		Name = "Plate",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromOffset(PLATE_W, PLATE_H),
		BackgroundTransparency = 1,
	}, gui)

	-- title pill in the accent colour at the bottom; the name pill sits on it (4 px tucked behind)
	local titleH = TITLE_PX + 10
	local titlePill, title = textPill(plate, "TitlePill", def.Title or "Lobby Friend", "Label", TITLE_PX, 12, titleH, 110, 2)
	titlePill.Position = UDim2.new(0.5, 0, 1, 0)
	titlePill.BackgroundColor3 = darken(accent, 0.3)
	titlePill.ZIndex = 2
	title.ZIndex = 2
	corner(titlePill, 12)
	stroke(titlePill, Theme.Colors.Navy or Theme.Colors.Ink, 2.5)

	-- name pill: dark navy card, accent outline, big outlined name
	local namePill = textPill(plate, "NamePill", def.Name or "Friend", "Title", NAME_PX, 16, NAME_PX + 18, 150, 2.5, 10)
	namePill.Position = UDim2.new(0.5, 0, 1, -(titleH - 4))
	corner(namePill, 16)
	stroke(namePill, accent, 3.5)
	Theme.Gradient(namePill, Theme.Colors.PanelLight, Theme.Colors.Panel, 90)

	-- "!" badge on the name pill's corner: new tips here (the client hides it once the player has talked to this NPC)
	local badge = make("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -4, 0, 4),
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = Theme.Colors.Gold or STONE.Gold,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, namePill)
	corner(badge, 16)
	stroke(badge, Theme.Colors.Navy or Theme.Colors.Ink, 3)
	local mark = Theme.Label("!", "Accent", {
		Size = 26,
		Stroke = 1,
		Outline = 2,
		OutlineColor = INK,
		Props = { Name = "Mark", Size = UDim2.fromScale(1, 1), ZIndex = 4 },
	})
	mark.Parent = badge

	gui.Parent = parent
	return gui
end

----------------------------------------------------------------------
-- One NPC
----------------------------------------------------------------------
local function catalogPet(def)
	if not PetCatalog or type(PetCatalog.Get) ~= "function" then
		return nil
	end
	local pet = PetCatalog.Get(def.PetId)
	if pet then
		return pet
	end
	-- the id vanished from the catalog: borrow another pet of the same species (or any pet)
	local list = PetCatalog.Pets or {}
	for _, p in ipairs(list) do
		if type(p) == "table" and type(p.Look) == "table" and p.Look.Species == def.Species then
			return p
		end
	end
	return list[1]
end

local function buildNpc(def, spot, index)
	local accent = typeof(def.Accent) == "Color3" and def.Accent or rgb(120, 180, 236)
	local model = make("Model", { Name = "Npc_" .. tostring(def.Id) }, nil)
	model:SetAttribute("NpcId", def.Id)
	model:SetAttribute("NpcName", def.Name or def.Id)
	model:SetAttribute("Title", def.Title or "")
	model:SetAttribute("Accent", accent)

	local okPed, errPed = pcall(buildPedestal, model, spot, accent, index)
	if not okPed then
		warn("[NpcService] pedestal of " .. tostring(def.Id) .. " failed: " .. tostring(errPed))
	end

	-- the pet, hovering HOVER_GAP above the rug, facing the walkway (pets face -Z = the spot's LookVector)
	local petDef = catalogPet(def)
	local pet = nil
	local centerY = PEDESTAL_TOP + 3.2
	local topY = PEDESTAL_TOP + 6.4
	local reach = 3
	if petDef and PetBuilder and type(PetBuilder.Build) == "function" then
		local ok, built = pcall(PetBuilder.Build, petDef, { Scale = def.Scale or NPC_SCALE, Detail = "High" })
		if ok and typeof(built) == "Instance" then
			pet = built
			pet.Name = "Pet"
			local origin = CFrame.new()
			pet:PivotTo(origin)
			local lo, hi, r = extents(pet, origin)
			if lo then
				local pivotY = PEDESTAL_TOP + HOVER_GAP - lo
				centerY = pivotY
				topY = pivotY + hi
				reach = r
			end
			pet:PivotTo(spot * CFrame.new(0, centerY, 0))
			pet.Parent = model
			model:SetAttribute("PetId", petDef.Id)
			model:SetAttribute("PetParts", countParts(pet))
		else
			warn("[NpcService] PetBuilder.Build failed for " .. tostring(def.Id) .. ": " .. tostring(built))
		end
	end

	-- one invisible collider: players walk around the NPC instead of into it
	local colliderH = topY + SINK + 0.3
	local colliderR = math.max(R_DRUM * PV + 0.15, math.min(reach * 0.75, R_CAP * PV))
	make("Part", {
		Name = "Collider",
		Anchored = true,
		CanCollide = true,
		CanTouch = false,
		Transparency = 1,
		CastShadow = false,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(colliderH, colliderR * 2, colliderR * 2),
		CFrame = spot * CFrame.new(0, colliderH / 2 - SINK, 0) * CFrame.Angles(0, 0, math.rad(90)),
	}, model)

	-- prompt + nameplate + light + sparkles live on an invisible part at the pet's centre
	local promptPart = make("Part", {
		Name = "PromptPart",
		Anchored = true,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
		Transparency = 1,
		CastShadow = false,
		Size = Vector3.new(1, 1, 1),
		CFrame = spot * CFrame.new(0, centerY, 0),
	}, model)
	local prompt = make("ProximityPrompt", {
		Name = "TalkPrompt",
		ActionText = "Talk",
		ObjectText = def.Name or "Friend",
		HoldDuration = 0,
		MaxActivationDistance = PROMPT_DISTANCE,
		RequiresLineOfSight = false,
	}, nil)
	prompt:SetAttribute("NpcId", def.Id)
	-- the prompt pops up at the front of the cushion, so its key hint never covers the pet's face
	local anchor = make("Attachment", {
		Name = "PromptAnchor",
		CFrame = promptPart.CFrame:Inverse() * (spot * CFrame.new(0, PEDESTAL_TOP + 0.9, -(R_CAP * PV - 0.6))),
	}, promptPart)
	prompt.Parent = anchor
	buildNameplate(promptPart, def, accent, topY - centerY + 0.9)

	make("PointLight", {
		Name = "Glow",
		Color = lighten(accent, 0.45),
		Brightness = 0.6,
		Range = 11,
		Shadows = false,
	}, promptPart)

	local rugAttachment = make("Attachment", {
		Name = "RugSparkles",
		CFrame = promptPart.CFrame:Inverse() * (spot * CFrame.new(0, PEDESTAL_TOP + 0.1, 0)),
	}, promptPart)
	make("ParticleEmitter", {
		Name = "Sparkles",
		Texture = SPARKLES,
		Color = ColorSequence.new(lighten(accent, 0.55), rgb(255, 236, 170)),
		LightEmission = 0.7,
		LightInfluence = 0,
		Rate = 2.2,
		Lifetime = NumberRange.new(1.6, 2.6),
		Speed = NumberRange.new(0.6, 1.3),
		SpreadAngle = Vector2.new(35, 35),
		EmissionDirection = Enum.NormalId.Top,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.3, 0.32),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.25, 0.25),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, rugAttachment)

	if pet and pet.PrimaryPart then
		model.PrimaryPart = pet.PrimaryPart
	else
		model.PrimaryPart = promptPart
	end

	prompt.Triggered:Connect(function(player)
		NpcService.Talked:Fire(player, def.Id)
	end)

	CollectionService:AddTag(model, TAG)
	model:SetAttribute("Ready", true)
	model.Parent = folder -- parented last: the whole NPC replicates in one step
	return {
		Id = def.Id,
		Name = def.Name,
		Model = model,
		Pet = pet,
		Prompt = prompt,
		Spot = spot,
	}
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function NpcService.Init(lobbyInfo, deps)
	local _ = deps
	if not NpcDialog or type(NpcDialog.Npcs) ~= "table" then
		warn("[NpcService] shared/NpcDialog is unavailable: no NPCs")
		return {}
	end
	local old = Workspace:FindFirstChild(FOLDER_NAME)
	if old then
		old:Destroy()
	end
	records = {}
	folder = make("Folder", { Name = FOLDER_NAME }, Workspace)

	local list = NpcDialog.Npcs
	local spots = resolveSpots(lobbyInfo, #list)
	for i, def in ipairs(list) do
		if type(def) == "table" and type(def.Id) == "string" and spots[i] then
			local ok, rec = pcall(buildNpc, def, spots[i], i)
			if ok and rec then
				records[#records + 1] = rec
			else
				warn("[NpcService] NPC " .. tostring(def.Id) .. " failed: " .. tostring(rec))
			end
		end
	end
	return NpcService.GetNpcs()
end

function NpcService.GetNpcs()
	local out = {}
	for i, rec in ipairs(records) do
		out[i] = rec
	end
	return out
end

function NpcService.GetNpc(id)
	for _, rec in ipairs(records) do
		if rec.Id == id then
			return rec
		end
	end
	return nil
end

return NpcService
