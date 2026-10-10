-- dump_model.lua: builds a model with the REAL game modules inside the Roblox mock and dumps every BasePart
-- (world position, full rotation matrix, Size, Color3 as 0-255, Material, Transparency, Shape / wedge class)
-- as JSON, so tools/render_model.py can draw it offline.
--
-- It runs under lupa with tools/robloxmock.lua, booted exactly like tools/smoke.py boots a world (render_model.py
-- does that: Mock.Configure + Mock.Boot(context) + src/ mounted where default.project.json says). Globals:
--   Mock    the booted mock
--   ROOTS   src directory name -> instance path ("shared" -> "ReplicatedStorage/Shared", ...)
--   DUMP    { target = "pet:stormfang:High", out = "file.json" | nil, box = { x0, y0, z0, x1, y1, z1 } | nil }
-- The chunk returns the JSON text (and writes it to DUMP.out when given).
--
-- Targets (several can be joined with "+", e.g. "lobby+npcs+storm-altar"; each becomes one entry of `models`):
--   pet:<petId>[:High|Low]          PetBuilder.Build with the catalog def (High by default)
--   species:<Species>[:High|Low]    PetBuilder.Build with a neutral sample Look of that species
--   pets[:High|Low]                 every catalog pet, one model each (render_model.py --grid)
--   species[:High|Low]              every species with the neutral sample Look, one model each
--   lobby                           LobbyBuilder.Build() (crop with DUMP.box)
--   npcs                            NpcService.Init(lobbyInfo) after the lobby (only the NPC folder is dumped)
--   storm-altar                     StormAltar.Build(lobbyInfo) after the lobby (server/Services/StormAltar.lua)
--   skydragon                       the Sage Dragon SkyDragonController builds (client world)
--   token[:golden]                  TokenService.MakeTokenPart (a normal or a golden coin)
--   home:<StationId>[:<level>|all]  a Phase 2 home station (HomeBuilder.BuildStationModel), see BUILDERS.home
--   homeplot[:<tier>[:pads]]        a fully built home plot on the lobby for house tier 1-4, see BUILDERS.homeplot
--   homefree                        spot 1 prepared by HomeBuilder but unclaimed (gate, claim signpost)
--   homegarden[:<level>] / homegym[:<level>]  (client) the Pet Garden / Gym with pets, placed by the real HomeFx
--   module:<path>:<func>[:lobby]    generic: require src/<path> (e.g. shared/Foo, server/Services/Foo) and call
--                                   <func>() (or <func>(lobbyInfo) with :lobby); the result may be an Instance, a
--                                   table with Model / Folder / Root, or nothing (then the new Workspace children)
-- Every model records `facing` (the direction its front looks at: a pet's LookVector, a coin's face normal,
-- the dragon head's LookVector) so the renderer's "front" view looks the model in the face.
-- Plain Lua 5.1 syntax only.

local Workspace = game:GetService("Workspace")

local ARGS = DUMP or {}

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------
local function fail(msg)
	error("dump_model: " .. tostring(msg), 0)
end

-- plain-text split ("a:b::c" -> { "a", "b", "", "c" })
local function split(text, sep)
	local out = {}
	local pos = 1
	while true do
		local a, b = text:find(sep, pos, true)
		if not a then
			out[#out + 1] = text:sub(pos)
			return out
		end
		out[#out + 1] = text:sub(pos, a - 1)
		pos = b + 1
	end
end

-- "shared/PetBuilder" -> the ModuleScript instance (nil when it does not exist)
local function moduleInstance(key)
	local top, rest = key:match("^(%w+)/(.+)$")
	local rootPath = top and ROOTS[top]
	if not rootPath then
		return nil
	end
	local inst = Mock.GetPath(rootPath)
	for part in rest:gmatch("[^/]+") do
		inst = inst and inst:FindFirstChild(part)
	end
	return inst
end

local loaded = {}
local function req(key, optional)
	if loaded[key] then
		return loaded[key]
	end
	local inst = moduleInstance(key)
	if not inst then
		if optional then
			return nil
		end
		fail("src/" .. key .. ".lua does not exist")
	end
	local ok, result = pcall(require, inst)
	if not ok then
		fail("require " .. key .. " failed: " .. tostring(type(result) == "table" and (result.msg or result) or result))
	end
	if type(result) ~= "table" then
		fail(key .. " did not return a table")
	end
	loaded[key] = result
	return result
end

local function vec3(v)
	return { v.X, v.Y, v.Z }
end

local function isInstance(v)
	return typeof(v) == "Instance"
end

-- an Instance from whatever a builder returned
local function rootOf(result)
	if isInstance(result) then
		return result
	end
	if type(result) == "table" then
		for _, key in ipairs({ "Model", "Folder", "Root", "Instance", "Part" }) do
			if isInstance(result[key]) then
				return result[key]
			end
		end
		if isInstance(result[1]) then
			return result[1]
		end
	end
	return nil
end

local function lookOf(inst)
	if not isInstance(inst) then
		return nil
	end
	local part = nil
	if inst:IsA("Model") then
		part = inst.PrimaryPart
	elseif inst:IsA("BasePart") then
		part = inst
	end
	if part then
		return vec3(part.CFrame.LookVector)
	end
	return nil
end

-- every BasePart of root (root included); box = optional { x0, y0, z0, x1, y1, z1 } world crop
local function collectParts(root, box)
	local list = {}
	if root:IsA("BasePart") then
		list[1] = root
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			list[#list + 1] = d
		end
	end
	if not box then
		return list, #list
	end
	local x0, y0, z0 = math.min(box[1], box[4]), math.min(box[2], box[5]), math.min(box[3], box[6])
	local x1, y1, z1 = math.max(box[1], box[4]), math.max(box[2], box[5]), math.max(box[3], box[6])
	local kept = {}
	for _, p in ipairs(list) do
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = p.CFrame:GetComponents()
		local s = p.Size
		local ex = (math.abs(r00) * s.X + math.abs(r01) * s.Y + math.abs(r02) * s.Z) / 2
		local ey = (math.abs(r10) * s.X + math.abs(r11) * s.Y + math.abs(r12) * s.Z) / 2
		local ez = (math.abs(r20) * s.X + math.abs(r21) * s.Y + math.abs(r22) * s.Z) / 2
		if x + ex >= x0 and x - ex <= x1 and y + ey >= y0 and y - ey <= y1 and z + ez >= z0 and z - ez <= z1 then
			kept[#kept + 1] = p
		end
	end
	return kept, #list
end

----------------------------------------------------------------------
-- JSON
----------------------------------------------------------------------
local fmt = string.format

local function num(v)
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return "0"
	end
	local s = fmt("%.4f", v)
	s = s:gsub("%.?0+$", "")
	if s == "-0" or s == "" then
		return "0"
	end
	return s
end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function str(v)
	local s = tostring(v)
	s = s:gsub('[%c"\\]', function(c)
		return ESC[c] or fmt("\\u%04x", c:byte())
	end)
	return '"' .. s .. '"'
end

local function arr(t)
	local out = {}
	for i = 1, #t do
		out[i] = num(t[i])
	end
	return "[" .. table.concat(out, ",") .. "]"
end

-- path of inst below root ("Pet.WingL3")
local function pathOf(inst, root)
	local names = {}
	local cur = inst
	local guard = 0
	while cur and cur ~= root and guard < 64 do
		table.insert(names, 1, cur.Name)
		cur = cur.Parent
		guard = guard + 1
	end
	if inst == root then
		return inst.Name
	end
	return table.concat(names, ".")
end

local function shapeOf(p)
	local cls = p.ClassName
	if cls == "WedgePart" then
		return "Wedge"
	elseif cls == "CornerWedgePart" then
		return "CornerWedge"
	elseif p:IsA("Part") then
		local ok, shape = pcall(function()
			return p.Shape
		end)
		if ok and shape ~= nil then
			local name = tostring(shape.Name or shape)
			if name == "Ball" or name == "Cylinder" or name == "Wedge" or name == "CornerWedge" then
				return name
			end
		end
		-- a SpecialMesh sphere turns a block into an ellipsoid
		local mesh = p:FindFirstChildOfClass("SpecialMesh")
		if mesh then
			local okType, mt = pcall(function()
				return mesh.MeshType
			end)
			if okType and mt and tostring(mt.Name or mt) == "Sphere" then
				return "Ellipsoid"
			end
		end
	end
	return "Block"
end

local function partJson(p, root)
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = p.CFrame:GetComponents()
	local c = p.Color
	local mat = p.Material
	local matName = tostring(mat and (mat.Name or mat) or "Plastic")
	return table.concat({
		"{\"path\":", str(pathOf(p, root)),
		",\"class\":", str(p.ClassName),
		",\"shape\":", str(shapeOf(p)),
		",\"pos\":", arr({ x, y, z }),
		",\"rot\":", arr({ r00, r01, r02, r10, r11, r12, r20, r21, r22 }),
		",\"size\":", arr({ p.Size.X, p.Size.Y, p.Size.Z }),
		",\"color\":[", tostring(math.floor(c.R * 255 + 0.5)), ",", tostring(math.floor(c.G * 255 + 0.5)), ",", tostring(math.floor(c.B * 255 + 0.5)), "]",
		",\"material\":", str(matName),
		",\"transparency\":", num(p.Transparency),
		"}",
	})
end

----------------------------------------------------------------------
-- builders (each returns { root = Instance, label, sub, facing })
----------------------------------------------------------------------
local lobbyInfo = nil
local function ensureLobby()
	if lobbyInfo then
		return lobbyInfo
	end
	local LobbyBuilder = req("server/Services/LobbyBuilder")
	local info = LobbyBuilder.Build()
	if type(info) ~= "table" or not isInstance(info.Folder) then
		fail("LobbyBuilder.Build() did not return a LobbyInfo with a Folder")
	end
	lobbyInfo = info
	return info
end

local function detailOf(value)
	if value == nil or value == "" then
		return "High"
	end
	local v = tostring(value):lower()
	if v == "low" then
		return "Low"
	elseif v == "high" then
		return "High"
	elseif v == "evolved" or v == "evo" then
		return "EvoHigh"
	elseif v == "evolvedlow" or v == "evolved-low" or v == "evolved_low" or v == "evolow" then
		return "EvoLow"
	elseif v == "evolved2" or v == "evo2" then
		return "Evo2High"
	elseif v == "evolved2low" or v == "evolved2-low" or v == "evolved2_low" or v == "evo2low" then
		return "Evo2Low"
	end
	fail("detail must be High or Low, got '" .. tostring(value) .. "'")
end

local function petModel(def, detail, label, sub)
	local PetBuilder = req("shared/PetBuilder")
	local evolved = detail:sub(1, 3) == "Evo"
	local stage = evolved and ((detail:sub(4, 4) == "2") and 2 or 1) or nil
	local model = PetBuilder.Build(def, { Detail = (detail:gsub("^Evo2?", "")), Evolved = stage })
	if not isInstance(model) then
		fail("PetBuilder.Build returned no model for " .. tostring(def.Id))
	end
	return { root = model, label = label, sub = sub, facing = lookOf(model) or { 0, 0, -1 } }
end

local function catalogPet(id, detail)
	local PetCatalog = req("shared/PetCatalog")
	local def = PetCatalog.Get(id)
	if not def then
		local ids = {}
		for _, d in ipairs(PetCatalog.Pets) do
			ids[#ids + 1] = d.Id
		end
		fail("unknown pet '" .. tostring(id) .. "'. Pets: " .. table.concat(ids, ", "))
	end
	local look = type(def.Look) == "table" and def.Look or {}
	local sub = tostring(def.Rarity) .. "  " .. tostring(look.Species) .. "  " .. detail
	if def.Element then
		sub = sub .. "  " .. tostring(def.Element)
	end
	return petModel(def, detail, tostring(def.Name or id), sub)
end

-- a neutral sample Look: calm beige fur, cream accents, dark eyes, pale wings
local function sampleDef(species)
	local wing = "Feather"
	if species == "Stormfang" then
		wing = "StormCloud"
	end
	return {
		Id = "sample_" .. species:lower(),
		Name = species,
		Rarity = "Common",
		Look = {
			Species = species,
			Primary = Color3.fromRGB(214, 190, 160),
			Secondary = Color3.fromRGB(246, 236, 220),
			Eye = Color3.fromRGB(46, 40, 62),
			Glow = false,
			WingStyle = wing,
			WingColor = Color3.fromRGB(232, 230, 244),
		},
	}
end

local function speciesList()
	local PetBuilder = req("shared/PetBuilder")
	if type(PetBuilder.Species) == "table" and #PetBuilder.Species > 0 then
		return PetBuilder.Species
	end
	return req("shared/PetCatalog").Species or {}
end

local function speciesPet(species, detail)
	local known = false
	local list = speciesList()
	for _, s in ipairs(list) do
		if s:lower() == tostring(species):lower() then
			species = s
			known = true
		end
	end
	if not known then
		fail("unknown species '" .. tostring(species) .. "'. Species: " .. table.concat(list, ", "))
	end
	return petModel(sampleDef(species), detail, species, "sample look  " .. detail)
end

local function workspaceSnapshot()
	local set = {}
	for _, c in ipairs(Workspace:GetChildren()) do
		set[c] = true
	end
	return set
end

-- new Workspace children since `before` gathered under one Folder-like view (a plain table of roots)
local function newChildren(before)
	local out = {}
	for _, c in ipairs(Workspace:GetChildren()) do
		if not before[c] and not c:IsA("Camera") and not c:IsA("Terrain") then
			out[#out + 1] = c
		end
	end
	return out
end

local BUILDERS = {}

BUILDERS.pet = function(a, b)
	if not a or a == "" then
		fail("usage: pet:<petId>[:High|Low]")
	end
	return { catalogPet(a, detailOf(b)) }
end

-- one entry of a batch (every pet / species): a model that fails to build becomes an empty, labelled entry
-- so the contact sheet still shows every other one
local function tryBuild(label, fn, ...)
	local ok, result = pcall(fn, ...)
	if ok then
		return result
	end
	local msg = tostring(type(result) == "table" and (result.msg or result) or result):gsub("^dump_model: ", "")
	return { root = nil, label = label, sub = "BUILD FAILED: " .. msg, facing = { 0, 0, -1 } }
end

BUILDERS.species = function(a, b)
	-- "species" alone (or "species:Low") = every species; "species:Cat[:Low]" = one
	if a == nil or a == "" or a:lower() == "high" or a:lower() == "low" then
		local detail = detailOf(a)
		local out = {}
		for _, s in ipairs(speciesList()) do
			out[#out + 1] = tryBuild(s, speciesPet, s, detail)
		end
		return out
	end
	return { speciesPet(a, detailOf(b)) }
end

BUILDERS.pets = function(a)
	local detail = detailOf(a)
	local second = detail:sub(1, 4) == "Evo2" -- the second evolution: only the pets that have one
	local out = {}
	for _, def in ipairs(req("shared/PetCatalog").Pets) do
		if not second or req("shared/PetBuilder").MaxEvolution(def) >= 2 then
			out[#out + 1] = tryBuild(tostring(def.Name or def.Id), catalogPet, def.Id, detail)
		end
	end
	return out
end

BUILDERS.lobby = function()
	local info = ensureLobby()
	return { { root = info.Folder, label = "Lobby", sub = "LobbyBuilder.Build()", facing = { 0, 0, -1 } } }
end

BUILDERS.npcs = function()
	local info = ensureLobby()
	local NpcService = req("server/Services/NpcService")
	NpcService.Init(info, {})
	Mock.Advance(0.2)
	local folder = Workspace:FindFirstChild("NimbusNpcs")
	if not folder then
		fail("NpcService.Init built no workspace.NimbusNpcs folder")
	end
	return { { root = folder, label = "NPCs", sub = "NpcService.Init(lobbyInfo)", facing = { 0, 0, -1 } } }
end

BUILDERS["storm-altar"] = function()
	local info = ensureLobby()
	local StormAltar = req("server/Services/StormAltar", true)
	if not StormAltar then
		fail("server/Services/StormAltar.lua does not exist yet")
	end
	if type(StormAltar.Build) ~= "function" then
		fail("StormAltar.Build is missing")
	end
	local result = StormAltar.Build(info)
	Mock.Advance(0.2)
	local root = rootOf(result)
	if not root or root.Name ~= "StormAltar" then
		root = Workspace:FindFirstChild("StormAltar", true) or root
	end
	if not root then
		fail("StormAltar.Build built no model named StormAltar")
	end
	local facing = lookOf(root)
	if not facing and typeof(info.AltarSite) == "CFrame" then
		facing = vec3(info.AltarSite.LookVector)
	end
	return { { root = root, label = "Storm Altar", sub = "StormAltar.Build(lobbyInfo)", facing = facing or { 0, 0, -1 } } }
end

BUILDERS.skydragon = function()
	local Sky = req("client/Controllers/SkyDragonController")
	Sky.Init()
	Mock.AdvanceUntil(function()
		return Sky.GetModel() ~= nil
	end, 30)
	local model = Sky.GetModel()
	if not model then
		fail("SkyDragonController built no model (is this the client world?)")
	end
	local facing = { 0, 0, -1 }
	local head = model:FindFirstChild("Head")
	if head then
		local part = head:IsA("BasePart") and head or head:FindFirstChildWhichIsA("BasePart", true)
		if part then
			facing = vec3(part.CFrame.LookVector)
		end
	end
	return { { root = model, label = "Sage Dragon", sub = "SkyDragonController (pose at t = 0)", facing = facing } }
end

BUILDERS.token = function(a)
	local Config = req("shared/Config")
	local TokenService = req("server/Services/TokenService")
	local golden = a ~= nil and a:lower() == "golden"
	local value = golden and Config.Tokens.GoldenValue or Config.Tokens.DefaultValue
	local token = TokenService.MakeTokenPart(Vector3.new(0, 0, 0), nil, value)
	if not isInstance(token) then
		fail("TokenService.MakeTokenPart returned no part")
	end
	-- the coin stands on its edge facing local X
	return { { root = token, label = golden and "Golden token" or "Cloud token", sub = "TokenService.MakeTokenPart", facing = vec3(token.CFrame.RightVector) } }
end

BUILDERS.module = function(path, func, extra)
	if not path or not func or path == "" or func == "" then
		fail("usage: module:<path>:<func>[:lobby]   e.g. module:server/Services/LobbyBuilder:Build")
	end
	path = path:gsub("^src/", ""):gsub("%.lua$", "")
	local m = req(path)
	if type(m[func]) ~= "function" then
		fail(path .. "." .. func .. " is not a function")
	end
	local args = {}
	if extra ~= nil and extra:lower() == "lobby" then
		args[1] = ensureLobby()
	end
	local before = workspaceSnapshot()
	local result = m[func](unpack(args))
	Mock.Advance(0.2)
	local root = rootOf(result)
	local label = path:match("([^/]+)$") .. "." .. func
	if root then
		return { { root = root, label = label, sub = "module", facing = lookOf(root) or { 0, 0, -1 } } }
	end
	local list = newChildren(before)
	if #list == 0 then
		fail(label .. " returned nothing and built nothing in the Workspace")
	end
	local out = {}
	for _, inst in ipairs(list) do
		out[#out + 1] = { root = inst, label = label .. " " .. inst.Name, sub = "module", facing = { 0, 0, -1 } }
	end
	return out
end
-- Phase 2 homes (server/Services/HomeBuilder.lua):
--   home:<StationId>[:<level>|all]   one station model at the origin (front -Z); "all" = every level, one model each
--   homerow:<StationId>[:<levels>]   levels side by side in one model (compare sizes at one scale), e.g. 1,4,7,10
--   homeplot[:<tier>[:pads]]       spot 1 of the real lobby built up for house tier 1-4 (every station at the cap of
--                                    that tier; tier 4 = everything maxed), owned by a stand-in player; ":pads" also
--                                    places the buy pads TycoonCatalog.AvailablePads would show
local function homeBuilder()
	local HB = req("server/Services/HomeBuilder", true)
	if not HB then
		fail("server/Services/HomeBuilder.lua does not exist yet")
	end
	return HB
end

BUILDERS.home = function(id, level)
	local HB = homeBuilder()
	local TC = req("shared/TycoonCatalog")
	local def = TC.Get(id or "")
	if not def or def.Kind == "Prestige" then
		local ids = {}
		for _, d in ipairs(TC.Stations) do
			ids[#ids + 1] = d.Id
		end
		fail("unknown station '" .. tostring(id) .. "'. Stations: " .. table.concat(ids, ", "))
	end
	local levels = {}
	if level == "all" then
		for l = 1, def.MaxLevel do
			levels[#levels + 1] = l
		end
	else
		levels[1] = tonumber(level) or def.MaxLevel
	end
	local out = {}
	for _, l in ipairs(levels) do
		local m = HB.BuildStationModel(id, l)
		if not m then
			fail("HomeBuilder.BuildStationModel(" .. id .. ", " .. l .. ") returned nothing")
		end
		m.Parent = Workspace
		out[#out + 1] = { root = m, label = def.Name .. "  Lv " .. l, sub = id .. ":" .. l, facing = { 0, 0, -1 } }
	end
	return out
end

-- homerow:<StationId>[:<l1,l2,...>]  the given levels (default: every level) side by side, ONE model, one scale
BUILDERS.homerow = function(id, list)
	local HB = homeBuilder()
	local TC = req("shared/TycoonCatalog")
	local def = TC.Get(id or "")
	if not def or def.Kind == "Prestige" then
		fail("unknown station '" .. tostring(id) .. "'")
	end
	local levels = {}
	for v in tostring(list or ""):gmatch("[^,]+") do
		levels[#levels + 1] = tonumber(v)
	end
	if #levels == 0 then
		for l = 1, def.MaxLevel do
			levels[#levels + 1] = l
		end
	end
	local folder = Instance.new("Model")
	folder.Name = "Row_" .. id
	local step = math.min(def.Slot.Footprint.X, 40) + 4
	for i, l in ipairs(levels) do
		local m = HB.BuildStationModel(id, l)
		if m then
			for _, d in ipairs(m:GetDescendants()) do
				if d:IsA("BasePart") then
					d.CFrame = CFrame.new((i - 1) * step, 0, 0) * d.CFrame
				end
			end
			m.Parent = folder
		end
	end
	folder.Parent = Workspace
	return { { root = folder, label = def.Name .. " levels " .. table.concat(levels, ","), sub = id, facing = { 0, 0, -1 } } }
end

BUILDERS.homeplot = function(tier, extra)
	local HB = homeBuilder()
	local TC = req("shared/TycoonCatalog")
	local info = ensureLobby()
	tier = math.max(1, math.min(4, tonumber(tier) or 4))
	HB.Init(info)
	local spot = info.Spots[1]
	local owner = nil
	pcall(function()
		owner = Mock.AddPlayer("HomeOwner", 777001)
	end)
	HB.SetOwner(spot, owner)
	local tierId = TC.HouseTiers[tier].Id
	local home = { Stations = {}, Prestige = (tier == 4) and 1 or 0 }
	for _, def in ipairs(TC.Stations) do
		local cap = def.TierCaps[tierId] or 0
		if def.Id == "House" then
			cap = tier
		end
		if def.ComingSoon and tier < 4 then
			cap = 0
		end
		if cap > 0 then
			home.Stations[def.Id] = math.min(cap, def.MaxLevel)
		end
	end
	HB.BuildHome(spot, home)
	if extra == "pads" then
		HB.SetPads(spot, TC.AvailablePads(home))
	end
	HB.SetCollector(spot, 1234, 5000)
	Mock.Advance(0.2)
	local parts = HB.PartCount(spot)
	return { { root = spot.Folder, label = "Home plot: " .. TC.HouseTiers[tier].Name, sub = "Home folder: " .. parts .. " parts", facing = { spot.PlotCFrame.LookVector.X, 0, spot.PlotCFrame.LookVector.Z } } }
end

-- homefree   spot 1 of the real lobby prepared by HomeBuilder.Init but not claimed: the gate's ClaimPrompt anchor and the
--            "FREE HOME" signpost (crop with --box to look at the gate)
BUILDERS.homefree = function()
	local HB = homeBuilder()
	local info = ensureLobby()
	HB.Init(info)
	local spot = info.Spots[1]
	Mock.Advance(0.2)
	return { { root = spot.Folder, label = "Free home plot", sub = "spot 1, unclaimed", facing = { spot.PlotCFrame.LookVector.X, 0, spot.PlotCFrame.LookVector.Z } } }
end

-- homegarden[:<level>] / homegym[:<level>]  (client world) a Pet Garden / Gym at <level> (default: its top level) on a
--            test plot with a pet on every open place: HomeBuilder builds the plot, the plot's GardenPets / GymPets
--            attribute names the pets and the real HomeFx puts them on the cushions / targets (PetBuilder Low)
local function homePetsView(stationId, attr, level)
	local HB = homeBuilder()
	local TC = req("shared/TycoonCatalog")
	local PC = req("shared/PetCatalog")
	local Fx = req("client/Controllers/HomeFx")
	local def = TC.Get(stationId)
	level = math.max(1, math.min(def.MaxLevel, tonumber(level) or def.MaxLevel))
	local folder = Instance.new("Folder")
	folder.Name = "Spot_99"
	folder.Parent = Workspace
	local cf = CFrame.new(0, 0, 0)
	local spot = { Index = 99, PlotCFrame = cf, PlotSize = TC.PlotSize, Center = cf.Position, Folder = folder }
	Fx.Init()
	HB.PreparePlot(spot)
	HB.SetStation(spot, stationId, level)
	local role = (stationId == "Gym") and "Combat" or "Economy"
	local ids = {}
	for _, d in ipairs(PC.Pets) do
		if d.Role == role and #ids < 8 then
			ids[#ids + 1] = d.Id
		end
	end
	local list = {}
	for i = 1, level do
		list[#list + 1] = i .. "=" .. ids[((i - 1) % #ids) + 1] .. ((i % 3 == 0) and "@Golden" or "")
	end
	folder:SetAttribute(attr, table.concat(list, ";"))
	local cam = Workspace.CurrentCamera
	if cam then
		cam.CFrame = CFrame.lookAt(Vector3.new(0, 30, -40), Vector3.new(0, 0, 0))
	end
	Mock.Advance(3)
	local view = Instance.new("Model")
	view.Name = stationId .. "View"
	local station = folder.Home:FindFirstChild("Station_" .. stationId)
	if station then
		station:Clone().Parent = view
	end
	local pets = Workspace:FindFirstChild("ClientFx") and Workspace.ClientFx:FindFirstChild("HomePets")
	local n = 0
	if pets then
		for _, p in ipairs(pets:GetChildren()) do
			p:Clone().Parent = view
			n = n + 1
		end
	end
	view.Parent = Workspace
	local look = (cf * def.Slot.CFrame).LookVector
	return { { root = view, label = def.Name .. " Lv " .. level .. " with " .. n .. " pets", sub = "HomeFx " .. attr, facing = { look.X, 0, look.Z } } }
end

BUILDERS.homegarden = function(level)
	return homePetsView("Garden", "GardenPets", level)
end

BUILDERS.homegym = function(level)
	return homePetsView("Gym", "GymPets", level)
end

BUILDERS["storm_altar"] = BUILDERS["storm-altar"]
BUILDERS.stormaltar = BUILDERS["storm-altar"]
BUILDERS.npc = BUILDERS.npcs
BUILDERS.dragon = BUILDERS.skydragon

----------------------------------------------------------------------
-- main
----------------------------------------------------------------------
local target = tostring(ARGS.target or "")
if target == "" then
	fail("no target (DUMP.target)")
end
local box = nil
if type(ARGS.box) == "table" or (type(ARGS.box) == "userdata") then
	local b = {}
	for i = 1, 6 do
		b[i] = tonumber(ARGS.box[i])
	end
	if b[6] then
		box = b
	end
end

local entries = {}
for _, piece in ipairs(split(target, "+")) do
	local fields = split(piece, ":")
	local kind = (fields[1] or ""):lower()
	local builder = BUILDERS[kind]
	if not builder then
		local names = {}
		for k in pairs(BUILDERS) do
			names[#names + 1] = k
		end
		table.sort(names)
		fail("unknown target '" .. piece .. "'. Known: " .. table.concat(names, ", "))
	end
	local built = builder(fields[2], fields[3], fields[4])
	for _, e in ipairs(built) do
		entries[#entries + 1] = e
	end
end

local chunks = {}
local summary = {}
for i, e in ipairs(entries) do
	local parts, uncropped = {}, 0
	if e.root then
		parts, uncropped = collectParts(e.root, box)
	end
	local lines = {}
	for j, p in ipairs(parts) do
		lines[j] = partJson(p, e.root)
	end
	-- total = BaseParts in this dump (after the crop), all = BaseParts of the whole model
	chunks[i] = table.concat({
		"{\"label\":", str(e.label or (e.root and e.root.Name) or "?"),
		",\"sub\":", str(e.sub or ""),
		",\"root\":", str(e.root and e.root.Name or ""),
		",\"facing\":", arr(e.facing or { 0, 0, -1 }),
		",\"total\":", tostring(#parts),
		",\"all\":", tostring(uncropped),
		",\"parts\":[\n", table.concat(lines, ",\n"), "]}",
	})
	summary[#summary + 1] = tostring(e.label or (e.root and e.root.Name) or "?") .. ": " .. #parts .. " parts"
end

local json = "{\"target\":" .. str(target) .. ",\"box\":" .. (box and arr(box) or "null") .. ",\"models\":[\n" .. table.concat(chunks, ",\n") .. "\n]}\n"

if ARGS.out and ARGS.out ~= "" then
	local fh, err = io.open(tostring(ARGS.out), "w")
	if not fh then
		fail("cannot write " .. tostring(ARGS.out) .. ": " .. tostring(err))
	end
	fh:write(json)
	fh:close()
end

return json, table.concat(summary, "; ")
