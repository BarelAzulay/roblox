-- smoke_p2_homeworld.lua: Phase 2 home world (ARCHITECTURE_V3.md "Phase 2 build contract": HomeBuilder + HomeFx,
-- ART DIRECTION, World text rule, Replication rule). Loaded by tools/smoke.py in BOTH worlds; ARGS.context picks the
-- half:
--   p2home_art      (server) every station at every level (HomeBuilder.BuildStationModel): clean models (Station_<Id>,
--                   anchored, no welds, only the allowed asset-free content), per-station part budgets, every level
--                   differs from the one before, the stations GROW (a level-1 Cloud Press is small, level 10 is
--                   bigger and shiny with gold and neon; Cottage -> Villa -> Manor -> Sky Castle each taller and
--                   wider; Kitchen / Gym / Vault / Collector / Garden bigger at the top level), the Fusion Machine has
--                   two input pods, a glass chamber with a Swirl and an output pod; templates are reused (a second
--                   build is a clone with the same parts)
--   p2home_plot     (server, booted) a private test plot far from the lobby: PreparePlot (Home folder tagged
--                   NC_Home, the gate's ClaimPrompt "Claim Home" / "Free home" / E / SpotIndex, the FREE HOME
--                   signpost, idempotent, at most 3 parts per free plot; the lobby's free plots carry the prompt on
--                   their own gate part), SetOwner (claim prompt + signpost only while free), a greedy progression
--                   through TycoonCatalog.AvailablePads with SetStation + SetPads after every purchase (the plot
--                   never passes ~950 parts, the fully built plot stays <= 900), contract names and attributes on
--                   stations (StationId, Level, BuiltAt, same level = no-op, level 0 removes), presses (PressHead,
--                   Puff, Chute / Drop on the conveyor line), the Conveyor ending at the Collector's intake, the
--                   Collector (CashLabel / CapLabel / CashFill / CollectPrompt / CollectPad), the Fusion Machine
--                   (Swirl, SwirlCenter, FusionPrompt), pads (Pad_<Id>, BuyPrompt "Buy" / 0.25 s / StationId /
--                   OwnerUserId, enabled only when unlocked and owned, a pixel-sized readable PadSign, unchanged pads
--                   kept, removed pads gone, a cheap ghost for "Unlocks at Prestige" / "Coming soon"), SetCollector
--                   only writes attributes, junk arguments never error, layout sanity on the built plot (stations
--                   inside the yard, no station blocks a pad or a stone path at walking height, no two stations
--                   overlap), the server never moves a part (Replication rule), ClearPlot (the claim prompt stays)
--   client_p2home   (client) HomeFx on plots HomeBuilder builds in the client world (standing in for replication):
--                   it finds every NC_Home, hides another player's BuyPrompts / CollectPrompt / pad signs and the
--                   claim prompts of other plots while the local player owns a home (and keeps hiding a prompt the
--                   server re-enables), the owner's prompts stay; a new station pops in and ends exactly where the
--                   server built it; the presses stamp (head moves, Puff emits) and pooled cloud blocks ride the belt
--                   into the Collector; the Collector screen shows CollectorCash / CollectorCap ("FULL") and the tank
--                   fills; the Fusion swirl turns; the Garden's pets (GardenPets) and the Gym's (GymPets) stand on
--                   their cushions / targets; the owner's pads dim when Cash cannot pay; far homes freeze and
--                   recycle their blocks; nothing is created per frame; ClearPlot / removing the home cleans up; no
--                   errors or warnings from HomeFx
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local CONTEXT = (ARGS and ARGS.context) or "server"

local abs, floor, max, min, huge = math.abs, math.floor, math.max, math.min, math.huge

local function fmt(v, n)
	if type(v) ~= "number" then
		return tostring(v)
	end
	return string.format("%." .. (n or 2) .. "f", v)
end

local function parts(root)
	local out = {}
	if not root then
		return out
	end
	if root:IsA("BasePart") then
		out[#out + 1] = root
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			out[#out + 1] = d
		end
	end
	return out
end

-- world-aligned box {x0, y0, z0, x1, y1, z1} of a part (its 8 corners)
local function aabb(p)
	local h = p.Size / 2
	local x0, y0, z0, x1, y1, z1 = huge, huge, huge, -huge, -huge, -huge
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local c = p.CFrame * Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)
				x0, y0, z0 = min(x0, c.X), min(y0, c.Y), min(z0, c.Z)
				x1, y1, z1 = max(x1, c.X), max(y1, c.Y), max(z1, c.Z)
			end
		end
	end
	return { x0, y0, z0, x1, y1, z1 }
end

-- bounds of every visible part of a model in the model's frame `cf` (default: world)
local function bounds(root, cf)
	local b = { huge, huge, huge, -huge, -huge, -huge }
	for _, p in ipairs(parts(root)) do
		if p.Transparency < 1 then
			local h = p.Size / 2
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local c = p.CFrame * Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)
						if cf then
							c = cf:PointToObjectSpace(c)
						end
						b[1], b[2], b[3] = min(b[1], c.X), min(b[2], c.Y), min(b[3], c.Z)
						b[4], b[5], b[6] = max(b[4], c.X), max(b[5], c.Y), max(b[6], c.Z)
					end
				end
			end
		end
	end
	return b
end

local function overlap(a, b, tol)
	tol = tol or 0
	return a[1] < b[4] - tol and b[1] < a[4] - tol and a[2] < b[5] - tol and b[2] < a[5] - tol and a[3] < b[6] - tol and b[3] < a[6] - tol
end

local function colorNear(a, b, tol)
	return abs(a.R - b.R) * 255 <= tol and abs(a.G - b.G) * 255 <= tol and abs(a.B - b.B) * 255 <= tol
end

local function find(root, name, className)
	if not root then
		return nil
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == name and (not className or d:IsA(className)) then
			return d
		end
	end
	return nil
end

local function findAll(root, pred)
	local out = {}
	if root then
		for _, d in ipairs(root:GetDescendants()) do
			if pred(d) then
				out[#out + 1] = d
			end
		end
	end
	return out
end

local function plainText(root)
	local out = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TextLabel") then
			out[#out + 1] = d.Text
		end
	end
	return table.concat(out, " | ")
end

-- the station's stamp: part count + bounds + colour/material census (to tell two levels apart)
local function signature(model)
	local list = {}
	for _, p in ipairs(parts(model)) do
		list[#list + 1] = string.format("%s:%.1f,%.1f,%.1f:%s:%.0f", p.Name, p.Size.X, p.Size.Y, p.Size.Z, p.Color:ToHex(), p.Transparency * 100)
	end
	table.sort(list)
	return table.concat(list, ";")
end

local GOLD = Color3.fromRGB(244, 198, 84)

----------------------------------------------------------------------------------------------------
-- server half
----------------------------------------------------------------------------------------------------
local function serverScenarios()
	local K = _G.K
	local S = {}
	local CollectionService = game:GetService("CollectionService")

	local function requireAt(key)
		local inst = K.moduleInstance(key)
		if not inst then
			return nil
		end
		local ok, result = pcall(require, inst)
		if ok and type(result) == "table" then
			return result
		end
		return nil
	end

	local BUDGET = { House = 150, FusionMachine = 90, DecorFence = 60 }
	local DEFAULT_BUDGET = 80

	S.p2home_art = guarded("p2home_art", function()
		local HB = requireAt("server/Services/HomeBuilder")
		local TC = requireAt("shared/TycoonCatalog")
		if not T.check(type(HB) == "table", "HomeBuilder: server/Services/HomeBuilder.lua loads") then
			return
		end
		if not T.check(type(TC) == "table", "HomeBuilder art: shared/TycoonCatalog loads") then
			return
		end
		local api = T.tally("HomeBuilder: the contract API exists (Init, PreparePlot, SetOwner, SetStation, SetPads, SetCollector, ClearPlot)")
		for _, fn in ipairs({ "Init", "PreparePlot", "SetOwner", "SetStation", "SetPads", "SetCollector", "ClearPlot" }) do
			api:case(type(HB[fn]) == "function", fn)
		end
		api:report()
		if type(HB.BuildStationModel) ~= "function" then
			T.warn("HomeBuilder art: no BuildStationModel extra, the per-level art checks are skipped")
			return
		end

		local clean = T.tally("station art: every station at every level builds a clean model (anchored, no welds, no scripts, no asset ids)")
		local budget = T.tally("station art: per-station part budgets (House <= 150, Fusion Machine <= 90, fence <= 60, others <= 80)")
		local differ = T.tally("station art: every level looks different from the one before")
		local models = {} -- [id] = { [level] = { b = bounds, n = parts, gold = n, neon = n, sig = s } }
		local t0 = os.clock()
		local builds = 0
		for _, def in ipairs(TC.Stations) do
			if def.Kind ~= "Prestige" then
				models[def.Id] = {}
				local prev = nil
				for level = 1, def.MaxLevel do
					local ok, m = pcall(HB.BuildStationModel, def.Id, level)
					builds = builds + 1
					if not ok or typeof(m) ~= "Instance" then
						clean:case(false, def.Id .. " " .. level .. ": " .. tostring(m))
					else
						local list = parts(m)
						local bad = nil
						for _, p in ipairs(list) do
							if not p.Anchored then
								bad = "unanchored " .. p.Name
							end
						end
						for _, d in ipairs(m:GetDescendants()) do
							if d:IsA("WeldConstraint") or d:IsA("Weld") or d:IsA("Script") or d:IsA("LocalScript") then
								bad = d.ClassName .. " " .. d.Name
							elseif d:IsA("ParticleEmitter") and tostring(d.Texture):find("rbxassetid", 1, true) then
								bad = "asset id on " .. d.Name
							end
						end
						clean:case(bad == nil and m.Name == "Station_" .. def.Id and #list > 0, def.Id .. " " .. level .. ": " .. tostring(bad or m.Name))
						local cap = BUDGET[def.Id] or DEFAULT_BUDGET
						budget:case(#list <= cap, def.Id .. " " .. level .. ": " .. #list .. " parts > " .. cap)
						local gold, neon = 0, 0
						for _, p in ipairs(list) do
							if colorNear(p.Color, GOLD, 24) then
								gold = gold + 1
							end
							if p.Material == Enum.Material.Neon then
								neon = neon + 1
							end
						end
						local sig = signature(m)
						models[def.Id][level] = { b = bounds(m), n = #list, gold = gold, neon = neon, sig = sig, model = m }
						if prev then
							differ:case(sig ~= prev, def.Id .. " level " .. level .. " looks exactly like level " .. (level - 1))
						end
						prev = sig
					end
				end
			end
		end
		clean:report(builds .. " models")
		budget:report()
		differ:report()
		T.info("station art: " .. builds .. " station levels sculpted in " .. fmt(os.clock() - t0, 2) .. " s")

		local function size(id, level)
			local r = models[id] and models[id][level]
			if not r then
				return nil
			end
			local b = r.b
			return b[4] - b[1], b[5] - b[2], b[6] - b[3], r
		end
		-- presses: small at 1, big and shiny at 10
		local grow = T.tally("station art: a level-10 Cloud Press is wider, taller and shinier (gold + neon) than a level-1 press")
		for _, id in ipairs({ "Press1", "Press2", "Press3", "Press4" }) do
			local w1, h1, _, r1 = size(id, 1)
			local w10, h10, _, r10 = size(id, 10)
			grow:case(w1 and w10 and w10 >= w1 + 1.5 and h10 >= h1 + 3 and r10.gold > r1.gold + 3 and r10.neon >= r1.neon,
				string.format("%s: %sx%s -> %sx%s studs, gold %s -> %s", id, fmt(w1, 1), fmt(h1, 1), fmt(w10, 1), fmt(h10, 1), tostring(r1 and r1.gold), tostring(r10 and r10.gold)))
		end
		grow:report()
		-- the press grows step by step: never shrinks from one level to the next
		local steady = T.tally("station art: presses never shrink from one level to the next")
		for _, id in ipairs({ "Press1", "Press2", "Press3", "Press4" }) do
			for level = 2, 10 do
				local _, h0 = size(id, level - 1)
				local _, h1 = size(id, level)
				steady:case(h0 and h1 and h1 >= h0 - 0.01, id .. " " .. (level - 1) .. " -> " .. level .. ": " .. fmt(h0, 1) .. " -> " .. fmt(h1, 1))
			end
		end
		steady:report()
		-- the house: every tier clearly grander
		local tiers = T.tally("station art: the House goes Cottage -> Villa -> Manor -> Sky Castle, each tier taller and with a bigger footprint")
		for level = 2, 4 do
			local w0, h0, d0 = size("House", level - 1)
			local w1, h1, d1 = size("House", level)
			tiers:case(w0 and w1 and h1 >= h0 + 3 and w1 * d1 > w0 * d0 * 1.1, string.format("tier %d -> %d: %sx%sx%s -> %sx%sx%s", level - 1, level, fmt(w0, 0), fmt(h0, 0), fmt(d0, 0), fmt(w1, 0), fmt(h1, 0), fmt(d1, 0)))
		end
		tiers:report()
		local castle = models.House and models.House[4]
		T.check(castle and castle.gold >= 4 and castle.neon >= 3, "station art: the Sky Castle carries gold finials and lit windows", castle and ("gold " .. castle.gold .. ", neon " .. castle.neon) or "missing")
		-- other stations: bigger at the top level
		local bigger = T.tally("station art: Collector, Garden, Kitchen, Gym and Vault are bigger at their top level than at level 1")
		for _, id in ipairs({ "Collector", "Garden", "Kitchen", "Gym", "Vault" }) do
			local def = TC.Get(id)
			local w1, h1, d1 = size(id, 1)
			local wN, hN, dN = size(id, def.MaxLevel)
			bigger:case(w1 and wN and wN * hN * dN > w1 * h1 * d1 * 1.2, string.format("%s: %sx%sx%s -> %sx%sx%s", id, fmt(w1, 1), fmt(h1, 1), fmt(d1, 1), fmt(wN, 1), fmt(hN, 1), fmt(dN, 1)))
		end
		bigger:report()
		-- the Fusion Machine: two input pods, a glass chamber with the Swirl, an output pod, a prompt
		local fusion = models.FusionMachine and models.FusionMachine[1] and models.FusionMachine[1].model
		if T.check(fusion ~= nil, "station art: the Fusion Machine builds") then
			local glass = findAll(fusion, function(d)
				return d:IsA("BasePart") and d.Material == Enum.Material.Glass
			end)
			local pods = 0
			for _, g in ipairs(glass) do
				if g.Name == "PodGlass" then
					pods = pods + 1
				end
			end
			local swirl = fusion:FindFirstChild("Swirl")
			T.check(pods >= 3 and find(fusion, "Chamber") ~= nil, "station art: the Fusion Machine has two input pods + an output pod (glass) and a glass chamber", pods .. " pod glasses")
			T.check(swirl ~= nil and #parts(swirl) >= 3, "station art: ...with a cloud Swirl inside the chamber (HomeFx spins it)")
			local prompt = find(fusion, "FusionPrompt", "ProximityPrompt")
			T.check(prompt ~= nil and prompt.ActionText ~= "" and prompt.HoldDuration == 0, "station art: ...and a FusionPrompt that opens the Fusion window")
			local _, h1 = size("FusionMachine", 1)
			T.check(h1 and h1 >= 10, "station art: ...and it is an impressive machine (>= 10 studs tall)", fmt(h1, 1) .. " studs")
		end
		-- templates are cloned: a second build of the same level is identical
		local a = HB.BuildStationModel("House", 4)
		local b = HB.BuildStationModel("House", 4)
		T.check(a and b and a ~= b and signature(a) == signature(b), "station art: heavy pieces are built once and cloned (two builds of the Sky Castle are identical copies)")
		for _, levels in pairs(models) do
			for _, r in pairs(levels) do
				r.model:Destroy()
			end
		end
		if a then
			a:Destroy()
		end
		if b then
			b:Destroy()
		end
	end)

	S.p2home_plot = guarded("p2home_plot", function()
		local HB = requireAt("server/Services/HomeBuilder")
		local TC = requireAt("shared/TycoonCatalog")
		if not (type(HB) == "table" and type(TC) == "table") then
			T.warn("home plot: HomeBuilder or TycoonCatalog missing, skipped")
			return
		end
		local outputBefore, errorsBefore = #Mock.Output, #Mock.Errors
		-- a private plot far from the lobby (never one TycoonService manages)
		local root = Instance.new("Folder")
		root.Name = "SmokeHomes"
		root.Parent = workspace
		local spotFolder = Instance.new("Folder")
		spotFolder.Name = "Spot_91"
		spotFolder.Parent = root
		local plotCF = CFrame.new(4000, 300, 4000) * CFrame.Angles(0, math.rad(90), 0)
		local half = TC.PlotSize / 2
		local spot = { Index = 91, PlotCFrame = plotCF, PlotSize = TC.PlotSize, Center = plotCF.Position, Folder = spotFolder }
		local home = HB.PreparePlot(spot)
		if not T.check(typeof(home) == "Instance" and home.Name == "Home" and home.Parent == spotFolder, "home plot: PreparePlot makes the plot's Home folder", tostring(home)) then
			root:Destroy()
			return
		end
		T.check(CollectionService:HasTag(home, "NC_Home") and home:GetAttribute("SpotIndex") == 91, "home plot: the Home folder is tagged NC_Home with its SpotIndex (HomeFx finds it)")
		local claims = findAll(spotFolder, function(d)
			return d:IsA("ProximityPrompt") and d.Name == "ClaimPrompt"
		end)
		local claim = claims[1]
		T.check(#claims == 1 and claim.ActionText == "Claim Home" and claim.ObjectText == "Free home" and claim.KeyboardKeyCode == Enum.KeyCode.E
			and claim.HoldDuration == 0 and claim:GetAttribute("SpotIndex") == 91 and claim.Enabled,
			"home plot: the gate has one ClaimPrompt 'Claim Home' (E, ObjectText 'Free home', attribute SpotIndex)", claim and (claim.ActionText .. " / " .. claim.ObjectText) or "none")
		if claim then
			local gatePos = plotCF * Vector3.new(0, 0, -half)
			local p = claim.Parent
			local at = (p and p:IsA("Attachment") and p.WorldPosition) or (p and p:IsA("BasePart") and p.Position) or nil
			T.check(at ~= nil and (Vector3.new(at.X, gatePos.Y, at.Z) - gatePos).Magnitude <= 3 and claim.MaxActivationDistance >= 8,
				"home plot: the ClaimPrompt sits in the gate opening (reachable from the street)")
		end
		local signParts = 0
		local claimGate = spotFolder:FindFirstChild("ClaimGate")
		for _, d in ipairs(claimGate and claimGate:GetDescendants() or {}) do
			if d:IsA("BasePart") then
				signParts = signParts + 1
			end
		end
		T.check(signParts <= 3, "home plot: a free plot adds at most 3 parts (the lobby's part budget)", signParts .. " parts")
		local sign = find(spotFolder, "ClaimGui", "SurfaceGui")
		T.check(sign ~= nil and sign.PixelsPerStud >= 40 and sign.PixelsPerStud <= 60 and plainText(sign):find("FREE HOME", 1, true) and plainText(sign):find("Press E", 1, true),
			"home plot: a FREE HOME signpost tells free plots apart (\"Press E at the gate\", 40-60 px per stud)")
		local lobbySpots = (K.W and K.W.lobbyInfo and K.W.lobbyInfo.Spots) or {}
		local cheap = T.tally("home plot: every free lobby plot carries its ClaimPrompt in the gate on the lobby's own gate part (2 parts added per plot)")
		for i, info in pairs(lobbySpots) do
			local folder = info.Folder
			local prompt = folder and find(folder, "ClaimPrompt", "ProximityPrompt")
			local gateModel = folder and folder:FindFirstChild("ClaimGate")
			local n = 0
			for _, d in ipairs(gateModel and gateModel:GetDescendants() or {}) do
				if d:IsA("BasePart") then
					n = n + 1
				end
			end
			cheap:case(prompt ~= nil and n <= 2 and prompt.Parent:IsA("Attachment"), "spot " .. tostring(i) .. ": " .. n .. " parts, prompt on " .. (prompt and prompt.Parent.ClassName or "nothing"))
		end
		cheap:report()
		T.check(HB.PreparePlot(spot) == home and #findAll(spotFolder, function(d)
			return d.Name == "ClaimPrompt"
		end) == 1, "home plot: PreparePlot is idempotent (same Home folder, one ClaimPrompt)")

		-- an owner (a real player: SetOwner takes a Player)
		local owner = Mock.AddPlayer("HomeSmoke", 963501)
		K.advance(1.0)
		HB.SetOwner(spot, owner)
		T.check(home:GetAttribute("OwnerUserId") == owner.UserId and not claim.Enabled and find(spotFolder, "ClaimGui") == nil,
			"home plot: SetOwner(player) writes OwnerUserId; the claim prompt and the signpost go away while owned")

		-- junk never errors
		local junk = T.tally("home plot: junk arguments never error (unknown ids, NaN / negative / huge levels, wrong types)")
		for _, args in ipairs({ { "Nope", 1 }, { "Press1", 0 / 0 }, { "Press1", -5 }, { 42, 1 }, { "Press1", "x" }, { nil, nil }, { "Prestige", 1 } }) do
			local ok, err = pcall(HB.SetStation, spot, args[1], args[2])
			junk:case(ok, tostring(args[1]) .. "/" .. tostring(args[2]) .. ": " .. tostring(err))
		end
		local okPads, errPads = pcall(HB.SetPads, spot, { { StationId = 5 }, "x", { StationId = "Nope" } })
		junk:case(okPads, "SetPads junk: " .. tostring(errPads))
		local okC, errC = pcall(HB.SetCollector, spot, 0 / 0, -1)
		junk:case(okC and home:GetAttribute("CollectorCash") == 0, "SetCollector(NaN): " .. tostring(errC))
		local okH = pcall(HB.SetStation, spot, "Press1", 99)
		junk:case(okH and (home:FindFirstChild("Station_Press1") == nil or home.Station_Press1:GetAttribute("Level") == TC.Get("Press1").MaxLevel), "level 99 is clamped to MaxLevel")
		HB.SetStation(spot, "Press1", 0)
		junk:report()

		-- a greedy progression through the pads, the way a player fills the yard
		local state = { Stations = {}, Prestige = 0 }
		local function partCount()
			return #parts(home)
		end
		local maxParts, maxAt, steps = 0, "", 0
		local stationOk = T.tally("home plot: every purchase builds Station_<Id> under Home with StationId / Level / BuiltAt; the pads follow")
		local padOk = T.tally("home plot: every pad is Pad_<Id> under Home/Pads with a BuyPrompt 'Buy' (E, 0.25 s, StationId, OwnerUserId), enabled only when unlocked")
		local signOk = T.tally("home plot: every pad sign is a pixel-sized billboard (names >= 22 px, info >= 18 px, outlined, LightInfluence 0, MaxDistance 50-150) showing the name and 'Lv a -> b' + price or the lock reason")
		local ghostOk = T.tally("home plot: stations that unlock later ('Unlocks at Prestige', 'Coming soon') show a cheap ghost (<= 12 parts, no prompts, no collisions)")
		local function checkPads(pads)
			local padFolder = home:FindFirstChild("Pads")
			for _, pad in ipairs(pads) do
				local m = padFolder and padFolder:FindFirstChild("Pad_" .. pad.StationId)
				if not m then
					padOk:case(false, "no Pad_" .. pad.StationId)
				else
					local prompt = find(m, "BuyPrompt", "ProximityPrompt")
					local locked = pad.Locked ~= nil and pad.Locked ~= ""
					padOk:case(prompt ~= nil and prompt.ActionText == "Buy" and abs(prompt.HoldDuration - 0.25) < 1e-6 and prompt.KeyboardKeyCode == Enum.KeyCode.E
						and prompt:GetAttribute("StationId") == pad.StationId and prompt:GetAttribute("OwnerUserId") == owner.UserId
						and m:GetAttribute("StationId") == pad.StationId and m:GetAttribute("OwnerUserId") == owner.UserId and prompt.Enabled == not locked,
						pad.StationId .. (prompt and (" enabled=" .. tostring(prompt.Enabled) .. " locked=" .. tostring(locked)) or " no BuyPrompt"))
					local gui = find(m, "PadSign", "BillboardGui")
					if not gui then
						signOk:case(false, pad.StationId .. ": no PadSign")
					else
						local pixel = gui.Size.X.Scale == 0 and gui.Size.Y.Scale == 0 and gui.LightInfluence == 0 and gui.MaxDistance >= 50 and gui.MaxDistance <= 150
						local biggest, smallest, outlined = 0, huge, true
						for _, d in ipairs(gui:GetDescendants()) do
							if d:IsA("TextLabel") and d.Text ~= "" then
								biggest, smallest = max(biggest, d.TextSize), min(smallest, d.TextSize)
								local stroke = d:FindFirstChildWhichIsA("UIStroke")
								if d.TextStrokeTransparency > 0.5 and not stroke then
									outlined = false
								end
							end
						end
						local text = plainText(gui)
						local wants = locked and tostring(pad.Locked) or tostring(pad.LevelText or "")
						signOk:case(pixel and biggest >= 22 and smallest >= 18 and outlined and text:find(tostring(pad.Title or pad.Name), 1, true) ~= nil and text:find(wants, 1, true) ~= nil,
							pad.StationId .. ": '" .. text .. "' sizes " .. smallest .. "-" .. biggest)
					end
					if locked and (pad.Locked:find("Prestige", 1, true) or pad.Locked:find("Coming soon", 1, true)) and (tonumber(pad.Level) or 0) == 0 and pad.StationId ~= "Prestige" then
						local ghost = home:FindFirstChild("Ghost_" .. pad.StationId)
						local n = ghost and #parts(ghost) or 0
						local solid = false
						for _, p in ipairs(parts(ghost)) do
							if p.CanCollide then
								solid = true
							end
						end
						ghostOk:case(ghost ~= nil and n <= 12 and n > 0 and not solid and find(ghost, "BuyPrompt") == nil, pad.StationId .. ": " .. n .. " parts")
					end
				end
			end
		end
		local function buy(id, level)
			state.Stations[id] = level
			local m = HB.SetStation(spot, id, level)
			local built = home:FindFirstChild("Station_" .. id)
			stationOk:case(m ~= nil and built == m and m:GetAttribute("StationId") == id and m:GetAttribute("Level") == level and type(m:GetAttribute("BuiltAt")) == "number",
				id .. " -> " .. level)
			local pads = TC.AvailablePads(state)
			HB.SetPads(spot, pads)
			steps = steps + 1
			local n = partCount()
			if n > maxParts then
				maxParts, maxAt = n, id .. " " .. level
			end
			return pads
		end
		local pads = TC.AvailablePads(state)
		HB.SetPads(spot, pads)
		checkPads(pads)
		for _ = 1, 400 do
			local pick = nil
			for _, pad in ipairs(pads) do
				if (pad.Locked == nil or pad.Locked == "") and pad.StationId ~= "Prestige" then
					if not pick or (tonumber(pad.Price) or 0) < (tonumber(pick.Price) or 0) then
						pick = pad
					end
				end
			end
			if not pick then
				if state.Prestige == 0 and TC.HouseTierOf and (state.Stations.House or 0) >= 4 then
					state.Prestige = 1 -- the first star unlocks the Fusion Machine; keep building
					pads = TC.AvailablePads(state)
					HB.SetPads(spot, pads)
				else
					break
				end
			else
				pads = buy(pick.StationId, pick.NextLevel)
				if steps % 7 == 0 then
					checkPads(pads)
				end
			end
		end
		checkPads(pads)
		stationOk:report(steps .. " purchases")
		padOk:report()
		signOk:report()
		ghostOk:report()
		local full = partCount()
		T.check(maxParts <= 950, "home plot: the plot never passes ~950 parts while it fills up (pads included)", "max " .. maxParts .. " after " .. maxAt)
		T.check(full <= 900, "home plot: the fully built plot stays <= 900 parts", full .. " parts")
		T.check(HB.PartCount == nil or HB.PartCount(spot) == full, "home plot: PartCount(spot) agrees")
		local maxed = 0
		for _, def in ipairs(TC.Stations) do
			if def.Kind ~= "Prestige" and not def.ComingSoon and (state.Stations[def.Id] or 0) >= def.MaxLevel then
				maxed = maxed + 1
			end
		end
		T.info("home plot: " .. steps .. " purchases, " .. maxed .. " stations maxed, " .. full .. " parts built, peak " .. maxParts)

		-- SetStation: same level again is a no-op; replacing a level swaps the model
		local press = home:FindFirstChild("Station_Press1")
		T.check(press ~= nil and HB.SetStation(spot, "Press1", state.Stations.Press1) == press, "home plot: SetStation with the same level keeps the model (no rebuild)")

		-- presses and the conveyor
		local conv = home:FindFirstChild("Conveyor")
		local cs, cf = conv and conv:GetAttribute("Start"), conv and conv:GetAttribute("Finish")
		T.check(typeof(cs) == "Vector3" and typeof(cf) == "Vector3" and (cs - cf).Magnitude > 10 and (tonumber(conv:GetAttribute("Speed")) or 0) > 0,
			"home plot: the Conveyor carries Start / Finish (world points on the belt) and Speed")
		local pressOk = T.tally("home plot: every press has a PressHead, a disabled Puff emitter, Chute / Drop points (Drop on the belt line), BlockSize / BlockColor / PuffInterval")
		for _, id in ipairs({ "Press1", "Press2", "Press3", "Press4" }) do
			local m = home:FindFirstChild("Station_" .. id)
			if m then
				local head = m:FindFirstChild("PressHead")
				local puff = find(m, "Puff", "ParticleEmitter")
				local chute, drop = m:GetAttribute("Chute"), m:GetAttribute("Drop")
				local onBelt = false
				if typeof(drop) == "Vector3" and typeof(cs) == "Vector3" then
					local d = cf - cs
					local t = math.max(0, math.min(1, (drop - cs):Dot(d) / d:Dot(d)))
					onBelt = ((cs + d * t) - drop).Magnitude <= 1.5
				end
				pressOk:case(head ~= nil and #parts(head) >= 1 and puff ~= nil and not puff.Enabled and typeof(chute) == "Vector3" and onBelt
					and (tonumber(m:GetAttribute("BlockSize")) or 0) > 0 and typeof(m:GetAttribute("BlockColor")) == "Color3" and (tonumber(m:GetAttribute("PuffInterval")) or 0) > 0,
					id .. ": head " .. tostring(head ~= nil) .. ", puff " .. tostring(puff ~= nil) .. ", on belt " .. tostring(onBelt))
			end
		end
		pressOk:report()

		-- the Collector
		local col = home:FindFirstChild("Station_Collector")
		if T.check(col ~= nil, "home plot: the Collector is built") then
			local intake = col:GetAttribute("Intake")
			T.check(typeof(intake) == "Vector3" and typeof(cf) == "Vector3" and (intake - cf).Magnitude <= 3, "home plot: the conveyor ends at the Collector's intake",
				typeof(intake) == "Vector3" and fmt((intake - cf).Magnitude, 2) .. " studs" or "no Intake")
			local fill = find(col, "CashFill", "BasePart")
			local prompt = find(col, "CollectPrompt", "ProximityPrompt")
			local pad = find(col, "CollectPad", "BasePart")
			T.check(find(col, "CashLabel", "TextLabel") ~= nil and find(col, "CapLabel", "TextLabel") ~= nil and fill ~= nil
				and typeof(fill:GetAttribute("FillBottom")) == "Vector3" and (tonumber(fill:GetAttribute("FillMax")) or 0) > 0 and (tonumber(fill:GetAttribute("FillWidth")) or 0) > 0,
				"home plot: the Collector has its screen (CashLabel / CapLabel) and a CashFill (FillBottom / FillMax / FillWidth) for HomeFx")
			T.check(prompt ~= nil and prompt.ActionText == "Collect" and prompt:GetAttribute("OwnerUserId") == owner.UserId and prompt.Enabled and pad ~= nil and pad.CanTouch,
				"home plot: the Collector has an owner-only CollectPrompt and a touchable CollectPad")
			local screen = find(col, "CashGui", "SurfaceGui")
			T.check(screen ~= nil and screen.PixelsPerStud >= 40 and screen.PixelsPerStud <= 60 and screen.LightInfluence == 0, "home plot: the cash screen is a surface sign at 40-60 px per stud")
			local before = Mock.CountDescendants(home)
			local label = find(col, "CashLabel", "TextLabel")
			local text0 = label and label.Text
			HB.SetCollector(spot, 1234.7, 5000)
			T.check(home:GetAttribute("CollectorCash") == 1234 and home:GetAttribute("CollectorCap") == 5000 and Mock.CountDescendants(home) == before and (not label or label.Text == text0),
				"home plot: SetCollector only writes attributes (CollectorCash / CollectorCap; HomeFx draws them)")
		end

		-- the Fusion Machine
		local fusion = home:FindFirstChild("Station_FusionMachine")
		if T.check(fusion ~= nil, "home plot: the Fusion Machine is built after the first prestige") then
			T.check(fusion:FindFirstChild("Swirl") ~= nil and typeof(fusion:GetAttribute("SwirlCenter")) == "Vector3" and find(fusion, "FusionPrompt", "ProximityPrompt") ~= nil,
				"home plot: the Fusion Machine has its Swirl (SwirlCenter) and the owner-only FusionPrompt")
		end

		-- unchanged pads are kept, missing pads go
		local padFolder = home:FindFirstChild("Pads")
		local kept = HB.SetPads(spot, { { StationId = "DecorLamps", NextLevel = 2, Price = 10, Level = 1, Title = "Lanterns", LevelText = "Lv 1 -> 2" } })
		local lamp = padFolder and padFolder:FindFirstChild("Pad_DecorLamps")
		HB.SetPads(spot, { { StationId = "DecorLamps", NextLevel = 2, Price = 10, Level = 1, Title = "Lanterns", LevelText = "Lv 1 -> 2" } })
		T.check(kept and lamp ~= nil and padFolder:FindFirstChild("Pad_DecorLamps") == lamp and #padFolder:GetChildren() == 1, "home plot: SetPads keeps an unchanged pad and removes the pads that are no longer listed")
		HB.SetPads(spot, {})

		-- layout sanity on the built plot
		local inside = T.tally("home plot: every station stands inside the yard (fence decor along its edge)")
		local blocks = T.tally("home plot: no station blocks a buy pad or a stone path at walking height")
		local apart = T.tally("home plot: no two stations overlap")
		local solids = {}
		for _, m in ipairs(home:GetChildren()) do
			if m:IsA("Model") and m.Name:sub(1, 8) == "Station_" then
				local b = bounds(m, plotCF)
				local lim = half + ((m.Name == "Station_DecorFence") and 1.5 or 0.6)
				inside:case(b[1] >= -lim and b[4] <= lim and b[3] >= -lim and b[6] <= lim, m.Name .. string.format(" x %.1f..%.1f z %.1f..%.1f", b[1], b[4], b[3], b[6]))
				for _, p in ipairs(parts(m)) do
					if p.CanCollide and p.Transparency < 1 then
						solids[#solids + 1] = { name = m.Name, box = aabb(p), part = p }
					end
				end
			end
		end
		inside:report()
		local zones = {}
		for _, def in ipairs(TC.Stations) do
			if def.Slot and typeof(def.Slot.Pad) == "CFrame" then
				local c = (plotCF * def.Slot.Pad).Position
				zones[#zones + 1] = { name = "pad " .. def.Id, box = { c.X - 1.6, c.Y + 0.7, c.Z - 1.6, c.X + 1.6, c.Y + 5, c.Z + 1.6 } }
			end
		end
		for _, path in ipairs((TC.Layout and TC.Layout.Paths) or {}) do
			local a, b2 = plotCF * path.Start, plotCF * path.Finish
			local across = (path.Width or 4) / 2 - 0.5 -- the walkable middle of the path
			local dir = (b2 - a)
			local len = dir.Magnitude
			if len > 0 then
				-- sample the centre line every 2 studs (ends included, nothing beyond them: paths meet at junctions)
				local u = dir.Unit
				local side = Vector3.new(-u.Z, 0, u.X)
				for t = 0, len, 2 do
					local c = a + u * t
					local p1 = c + side * across + u * 0.5
					local p2 = c - side * across - u * 0.5
					zones[#zones + 1] = { name = "path " .. tostring(path.Name), box = { min(p1.X, p2.X), c.Y + 0.7, min(p1.Z, p2.Z), max(p1.X, p2.X), c.Y + 5, max(p1.Z, p2.Z) } }
				end
			end
		end
		for _, z in ipairs(zones) do
			local hit = nil
			for _, s in ipairs(solids) do
				if overlap(z.box, s.box, 0.05) then
					hit = s.name .. "." .. s.part.Name
					break
				end
			end
			blocks:case(hit == nil, z.name .. " blocked by " .. tostring(hit))
		end
		blocks:report(#zones .. " zones")
		local byStation = {}
		for _, s in ipairs(solids) do
			byStation[s.name] = byStation[s.name] or {}
			table.insert(byStation[s.name], s)
		end
		local names = {}
		for n in pairs(byStation) do
			names[#names + 1] = n
		end
		table.sort(names)
		for i = 1, #names do
			for j = i + 1, #names do
				local hit = nil
				for _, a in ipairs(byStation[names[i]]) do
					for _, b in ipairs(byStation[names[j]]) do
						if overlap(a.box, b.box, 0.2) then
							hit = a.part.Name .. " / " .. b.part.Name
							break
						end
					end
					if hit then
						break
					end
				end
				apart:case(hit == nil, names[i] .. " x " .. names[j] .. ": " .. tostring(hit))
			end
		end
		apart:report()

		-- the server never moves a part (HomeFx animates on the clients)
		local snap = {}
		for _, p in ipairs(parts(home)) do
			snap[p] = p.CFrame
		end
		K.advance(3)
		local moved = 0
		for p, c in pairs(snap) do
			if p.Parent and (p.CFrame.Position - c.Position).Magnitude > 1e-6 then
				moved = moved + 1
			end
		end
		T.check(moved == 0, "home plot: the server never moves a part of a home (Replication rule)", moved .. " parts moved")

		-- level 0 removes; ClearPlot empties the plot, the claim prompt stays
		HB.SetStation(spot, "DecorPodium", 0)
		T.check(home:FindFirstChild("Station_DecorPodium") == nil, "home plot: SetStation(id, 0) removes the station")
		HB.ClearPlot(spot)
		local left = 0
		for _, c in ipairs(home:GetChildren()) do
			if c.Name:sub(1, 8) == "Station_" or c.Name:sub(1, 6) == "Ghost_" or c.Name == "Conveyor" then
				left = left + 1
			end
		end
		T.check(left == 0 and (not home:FindFirstChild("Pads") or #home.Pads:GetChildren() == 0) and #findAll(spotFolder, function(d)
			return d.Name == "ClaimPrompt"
		end) == 1, "home plot: ClearPlot removes every station, pad, ghost and the conveyor; the ClaimPrompt stays")
		HB.SetOwner(spot, nil)
		T.check(home:GetAttribute("OwnerUserId") == 0 and claim.Enabled and find(spotFolder, "ClaimGui") ~= nil, "home plot: SetOwner(nil) frees the plot (claim prompt + signpost back)")

		-- no errors / warnings from HomeBuilder during all this
		local warned = nil
		for i = outputBefore + 1, #Mock.Output do
			local o = Mock.Output[i]
			if o.kind == "warn" and o.text:find("HomeBuilder", 1, true) then
				warned = o.text
			end
		end
		T.check(warned == nil and #Mock.Errors == errorsBefore, "home plot: no errors or HomeBuilder warnings", tostring(warned))
		root:Destroy()
		Mock.RemovePlayer(owner)
		K.advance(0.5)
	end)

	return S
end

----------------------------------------------------------------------------------------------------
-- client half
----------------------------------------------------------------------------------------------------
local function clientScenarios()
	local KC = _G.KC
	local S = {}
	local Players = game:GetService("Players")
	local CollectionService = game:GetService("CollectionService")
	local LocalPlayer = Players.LocalPlayer
	local advance = KC.advance

	local function moduleAt(top, rest)
		local inst = Mock.GetPath(ROOTS[top] .. "/" .. rest)
		if not inst then
			return nil
		end
		local ok, result = pcall(require, inst)
		return ok and type(result) == "table" and result or nil
	end

	S.client_p2home = guarded("client_p2home", function()
		local HF = KC.M.HomeFx or moduleAt("client", "Controllers/HomeFx")
		if not T.check(type(HF) == "table" and type(HF.Init) == "function", "HomeFx: client/Controllers/HomeFx.lua loads with Init") then
			return
		end
		HF.Init() -- Main.client.lua already did; a second call is a no-op
		local HB = moduleAt("server", "Services/HomeBuilder")
		local TC = moduleAt("shared", "TycoonCatalog")
		if not (HB and TC) then
			T.warn("HomeFx: HomeBuilder / TycoonCatalog missing in the client world, skipped")
			return
		end
		local outputBefore, errorsBefore = #Mock.Output, #Mock.Errors
		local stats = type(HF.Stats) == "function" and HF.Stats or function()
			return {}
		end
		local count = type(HF.Count) == "function" and HF.Count or function()
			return -1
		end
		local homes0 = count()
		-- two plots built the way the server builds them (standing in for replication): ours and a neighbour's,
		-- plus a free plot
		local root = Instance.new("Folder")
		root.Name = "SmokeHomesClient"
		root.Parent = workspace
		local function makeSpot(index, cf)
			local f = Instance.new("Folder")
			f.Name = string.format("Spot_%02d", index)
			f.Parent = root
			return { Index = index, PlotCFrame = cf, PlotSize = TC.PlotSize, Center = cf.Position, Folder = f }
		end
		local base = CFrame.new(-3000, 300, 3000)
		local mine = makeSpot(81, base)
		local theirs = makeSpot(82, base * CFrame.new(120, 0, 0))
		local free = makeSpot(83, base * CFrame.new(-120, 0, 0))
		local neighbour = Mock.AddPlayer("Neighbour", 5151, { character = false })
		advance(0.2)
		for _, sp in ipairs({ mine, theirs, free }) do
			HB.PreparePlot(sp)
		end
		local cam = workspace.CurrentCamera
		local savedCam = cam and cam.CFrame
		if cam then
			cam.CFrame = CFrame.lookAt(base.Position + Vector3.new(-30, 40, -60), base.Position)
		end
		advance(0.5)
		T.check(count() >= homes0 + 3, "HomeFx: finds every NC_Home folder (also ones added later)", tostring(homes0) .. " -> " .. tostring(count()))

		-- the free plot's claim prompt: shown while we own nothing, hidden once we own a home
		local freeClaim = HB.GetClaimPrompt and HB.GetClaimPrompt(free) or free.Folder:FindFirstChild("ClaimPrompt", true)
		T.check(freeClaim ~= nil and freeClaim.Enabled, "HomeFx: a free plot's Claim Home prompt is usable while the local player owns no home")

		local function buildHome(spot, owner, stations)
			HB.SetOwner(spot, owner)
			local home = { Stations = stations, Prestige = 1 }
			HB.BuildHome(spot, home)
			HB.SetPads(spot, TC.AvailablePads(home))
		end
		local stations = { Press1 = 4, Press2 = 2, Collector = 2, House = 1, Garden = 2, Kitchen = 1, Gym = 2, FusionMachine = 1, DecorLamps = 1 }
		LocalPlayer:SetAttribute("Cash", 0) -- broke while the pads arrive (and pop in)
		buildHome(mine, LocalPlayer, stations)
		buildHome(theirs, neighbour, stations)
		advance(2.0)
		local mineHome, theirHome = mine.Folder.Home, theirs.Folder.Home
		T.check(freeClaim == nil or not freeClaim.Enabled, "HomeFx: ...and the other plots' Claim Home prompts are disabled locally once it owns one (one home per player)")
		Mock.AdvanceUntil(function()
			return (tonumber(stats().Pops) or 0) == 0
		end, 15)
		local dimmed, priced = 0, 0
		for _, m in ipairs(mineHome.Pads:GetChildren()) do
			local locked = m:GetAttribute("Locked")
			local glow = m:FindFirstChild("Glow")
			if glow and (locked == nil or locked == "") and (tonumber(m:GetAttribute("Price")) or 0) > 0 then
				priced = priced + 1
				if glow.Transparency >= 0.55 then
					dimmed = dimmed + 1
				end
			end
		end
		T.check(priced > 0 and dimmed == priced, "HomeFx: pads that arrive (and pop in) while Cash cannot pay them settle dimmed", dimmed .. " of " .. priced)

		-- owner-only prompts and signs
		local function prompts(home, names)
			return findAll(home, function(d)
				return d:IsA("ProximityPrompt") and names[d.Name]
			end)
		end
		local ownerOnly = { BuyPrompt = true, CollectPrompt = true, FusionPrompt = true }
		local theirPrompts = prompts(theirHome, ownerOnly)
		local enabledTheirs = 0
		for _, p in ipairs(theirPrompts) do
			if p.Enabled then
				enabledTheirs = enabledTheirs + 1
			end
		end
		T.check(#theirPrompts >= 5 and enabledTheirs == 0, "HomeFx: every BuyPrompt / CollectPrompt / FusionPrompt of another player's home is disabled on this client",
			enabledTheirs .. " of " .. #theirPrompts .. " still enabled")
		local theirSigns = findAll(theirHome, function(d)
			return d:IsA("BillboardGui") and d.Name == "PadSign"
		end)
		local shownSigns = 0
		for _, g in ipairs(theirSigns) do
			if g.Enabled then
				shownSigns = shownSigns + 1
			end
		end
		T.check(#theirSigns > 0 and shownSigns == 0, "HomeFx: ...and its pad signs are hidden (only the owner sees their pads)", shownSigns .. " of " .. #theirSigns .. " shown")
		local mineOk = true
		local myPads = 0
		for _, p in ipairs(prompts(mineHome, { BuyPrompt = true })) do
			local pad = p.Parent and p.Parent.Parent
			local locked = pad and pad:GetAttribute("Locked")
			myPads = myPads + 1
			if p.Enabled ~= (locked == nil or locked == "") then
				mineOk = false
			end
		end
		local myCollect = find(mineHome, "CollectPrompt", "ProximityPrompt")
		T.check(myPads > 0 and mineOk and myCollect ~= nil and myCollect.Enabled, "HomeFx: the owner's own unlocked BuyPrompts and the CollectPrompt stay enabled")
		-- the server enabling a hidden prompt again: HomeFx hides it again
		local victim = theirPrompts[1]
		if victim then
			victim.Enabled = true
			advance(0.1)
			T.check(not victim.Enabled, "HomeFx: a hidden prompt the server re-enables is hidden again")
		end
		local st = stats()
		T.check((tonumber(st.HiddenPrompts) or 0) >= #theirPrompts, "HomeFx: Stats() counts the hidden prompts", tostring(st.HiddenPrompts))

		-- the collector screen and tank
		mineHome:SetAttribute("CollectorCash", 1234)
		mineHome:SetAttribute("CollectorCap", 5000)
		advance(0.1)
		local col = mineHome:FindFirstChild("Station_Collector")
		local cashLabel = col and find(col, "CashLabel", "TextLabel")
		local capLabel = col and find(col, "CapLabel", "TextLabel")
		local fill = col and find(col, "CashFill", "BasePart")
		local fmtCash = TC.FormatCash or function(n)
			return "$" .. tostring(n)
		end
		T.check(cashLabel and cashLabel.Text == fmtCash(1234) and capLabel and capLabel.Text:find(fmtCash(5000), 1, true),
			"HomeFx: the Collector screen shows the cash waiting (CollectorCash) and the cap", cashLabel and (cashLabel.Text .. " / " .. (capLabel and capLabel.Text or "?")) or "no labels")
		local h0 = fill and fill.Size.Y
		advance(1.5)
		local h1 = fill and fill.Size.Y
		local maxFill = fill and tonumber(fill:GetAttribute("FillMax")) or 3
		T.check(fill and h1 > 0.2 and abs(h1 - maxFill * 1234 / 5000) < 0.3, "HomeFx: the tank's cash fill rises to CollectorCash / CollectorCap", fmt(h0) .. " -> " .. fmt(h1) .. " (max " .. fmt(maxFill) .. ")")
		mineHome:SetAttribute("CollectorCash", 5000)
		advance(0.2)
		T.check(capLabel and capLabel.Text:upper():find("FULL", 1, true), "HomeFx: a full Collector says so", capLabel and capLabel.Text or "")

		-- presses at work: the head stamps, the puff emits, blocks ride the belt into the collector
		local press = mineHome:FindFirstChild("Station_Press1")
		local head = press and press:FindFirstChild("PressHead")
		local headPart = head and parts(head)[1]
		local rest = headPart and headPart.Position
		local emitted0 = Mock.Stats_ and Mock.Stats_.particlesEmitted or 0
		local lowest, blocksSeen = 0, 0
		local intake = col and col:GetAttribute("Intake")
		local closest = huge
		local fx = workspace:FindFirstChild("ClientFx") and workspace.ClientFx:FindFirstChild("HomeFx")
		for _ = 1, 60 do
			advance(0.1)
			if headPart and rest then
				lowest = max(lowest, rest.Y - headPart.Position.Y)
			end
			fx = fx or (workspace:FindFirstChild("ClientFx") and workspace.ClientFx:FindFirstChild("HomeFx"))
			if fx then
				for _, b in ipairs(fx:GetChildren()) do
					if b:IsA("BasePart") then
						blocksSeen = max(blocksSeen, #fx:GetChildren())
						if intake then
							closest = min(closest, (b.Position - intake).Magnitude)
						end
					end
				end
			end
		end
		local emitted = (Mock.Stats_ and Mock.Stats_.particlesEmitted or 0) - emitted0
		T.check(lowest >= 0.2, "HomeFx: the press heads stamp down", fmt(lowest) .. " studs")
		T.check(emitted > 0, "HomeFx: each stamp puffs cloud (the press's Puff emitter emits)", emitted .. " particles")
		T.check(blocksSeen > 0 and closest < 2.5, "HomeFx: glowing cloud blocks ride the conveyor into the Collector", blocksSeen .. " blocks, closest " .. fmt(closest) .. " studs from the intake")
		T.check(headPart and rest and (headPart.Position - rest).Magnitude <= 0.6, "HomeFx: the press head only moves along its stroke")
		-- nothing created per frame: the effect folder stays bounded
		local n1 = fx and Mock.CountDescendants(fx) or 0
		local homeDesc = Mock.CountDescendants(mineHome)
		advance(6)
		local n2 = fx and Mock.CountDescendants(fx) or 0
		st = stats()
		T.check(n2 <= 64 and (tonumber(st.Pool) or 0) <= 64 and Mock.CountDescendants(mineHome) == homeDesc,
			"HomeFx: the cloud blocks are pooled (<= 64, nothing else created per frame, nothing added to the home)", n1 .. " -> " .. n2 .. " blocks, pool " .. tostring(st.Pool))

		-- the fusion swirl turns
		local fusion = mineHome:FindFirstChild("Station_FusionMachine")
		local swirlPart = fusion and fusion:FindFirstChild("Swirl") and parts(fusion.Swirl)[1]
		local s0 = swirlPart and swirlPart.CFrame
		advance(0.5)
		T.check(swirlPart and (swirlPart.CFrame.Position - s0.Position).Magnitude > 0.01, "HomeFx: the Fusion Machine's cloud chamber swirls")

		-- garden pets: the plot's GardenPets attribute puts Low-detail pets on the Garden's cushions (open slots only)
		local PC = moduleAt("shared", "PetCatalog")
		local petId = nil
		for _, d in ipairs((PC and PC.Pets) or {}) do
			if d.Role == "Economy" then
				petId = d.Id
				break
			end
		end
		local petsFolder = function()
			local cfx = workspace:FindFirstChild("ClientFx")
			return cfx and cfx:FindFirstChild("HomePets")
		end
		if petId then
			mine.Folder:SetAttribute("GardenPets", "1=" .. petId .. ";2=" .. petId .. "@Golden;7=" .. petId .. ";3=hyb:nobody")
			advance(0.4)
			local garden = mineHome:FindFirstChild("Station_Garden")
			local pf = petsFolder()
			local pets = pf and pf:GetChildren() or {}
			local placed = 0
			for slot = 1, 2 do
				local att = garden and garden:FindFirstChild("Spot" .. slot, true)
				for _, pet in ipairs(pets) do
					local ok, pivot = pcall(function()
						return pet:GetPivot()
					end)
					if ok and att and (Vector3.new(pivot.X, 0, pivot.Z) - Vector3.new(att.WorldPosition.X, 0, att.WorldPosition.Z)).Magnitude < 0.6 then
						local lo = huge
						for _, part in ipairs(parts(pet)) do
							lo = min(lo, part.Position.Y - part.Size.Y / 2)
						end
						if abs(lo - att.WorldPosition.Y) < 0.4 then
							placed = placed + 1
						end
					end
				end
			end
			T.check(#pets == 2 and placed == 2 and (tonumber(stats().GardenPets) or 0) == 2,
				"HomeFx: the Garden's pets (GardenPets) stand on their cushions; locked slots and hybrids without a record are skipped", #pets .. " pets, " .. placed .. " on a cushion")
			local solid = 0
			for _, pet in ipairs(pets) do
				for _, part in ipairs(parts(pet)) do
					if part.CanCollide or not part.Anchored then
						solid = solid + 1
					end
				end
			end
			T.check(solid == 0, "HomeFx: garden pets are anchored and never collide", solid .. " parts")
			mine.Folder:SetAttribute("GardenPets", "")
			advance(0.3)
			pf = petsFolder()
			T.check((not pf or #pf:GetChildren() == 0) and (tonumber(stats().GardenPets) or 0) == 0, "HomeFx: emptying the Garden removes its pets")
			-- the Gym's training pets (GymPets, PetCareService) stand on the Gym's targets
			mine.Folder:SetAttribute("GymPets", "2=" .. petId .. ";4=" .. petId)
			advance(0.4)
			local gym = mineHome:FindFirstChild("Station_Gym")
			local att2 = gym and gym:FindFirstChild("Spot2", true)
			pf = petsFolder()
			local onTarget = 0
			for _, pet in ipairs(pf and pf:GetChildren() or {}) do
				local ok, pivot = pcall(function()
					return pet:GetPivot()
				end)
				if ok and att2 and (Vector3.new(pivot.X, 0, pivot.Z) - Vector3.new(att2.WorldPosition.X, 0, att2.WorldPosition.Z)).Magnitude < 0.6 then
					onTarget = onTarget + 1
				end
			end
			T.check(onTarget == 1 and (tonumber(stats().GymPets) or 0) == 1, "HomeFx: the Gym's training pets (GymPets) stand on their targets (only the open places)",
				tostring(stats().GymPets) .. " gym pets, " .. onTarget .. " on target 2")
			mine.Folder:SetAttribute("GymPets", nil)
			advance(0.3)
			T.check((tonumber(stats().GymPets) or 0) == 0, "HomeFx: ...and leave when the Gym empties")
			mine.Folder:SetAttribute("GardenPets", "1=" .. petId)
			advance(0.3)
		else
			T.warn("HomeFx: no Economy pet in the catalog, garden pets skipped")
		end

		-- pop-in: a new level assembles and ends exactly where the server built it
		local before = mineHome:FindFirstChild("Station_Kitchen")
		HB.SetStation(mine, "Kitchen", 3)
		local kitchen = mineHome:FindFirstChild("Station_Kitchen")
		local def = TC.Get("Kitchen")
		local slotCF = base * def.Slot.CFrame
		local ref = HB.BuildStationModel("Kitchen", 3)
		local refParts, kParts = parts(ref), parts(kitchen)
		advance(0.15)
		local popping = 0
		for i, p in ipairs(kParts) do
			local r = refParts[i]
			if r and (abs(p.Transparency - r.Transparency) > 0.01 or (p.Size - r.Size).Magnitude > 0.01) then
				popping = popping + 1
			end
		end
		T.check(kitchen ~= before and popping > 0, "HomeFx: a new station pops in (its blocks spring up bottom-to-top)", popping .. " of " .. #kParts .. " parts mid-pop")
		advance(2.0)
		local off = 0
		for i, p in ipairs(kParts) do
			local r = refParts[i]
			if r then
				local want = slotCF * r.CFrame
				if (p.Position - want.Position).Magnitude > 0.01 or (p.Size - r.Size).Magnitude > 0.01 or abs(p.Transparency - r.Transparency) > 0.01 then
					off = off + 1
				end
			end
		end
		T.check(#refParts == #kParts and off == 0, "HomeFx: ...and ends exactly where and how the server built it", off .. " parts off")
		ref:Destroy()

		-- the owner's pads: dim when the Cash attribute cannot pay, pulse when it can
		local function myPad()
			for _, m in ipairs(mineHome.Pads:GetChildren()) do
				local locked = m:GetAttribute("Locked")
				if (locked == nil or locked == "") and (tonumber(m:GetAttribute("Price")) or 0) > 0 then
					return m
				end
			end
			return nil
		end
		local pad = myPad()
		if pad then
			local glow = pad:FindFirstChild("Glow")
			LocalPlayer:SetAttribute("Cash", 1e12) -- whatever an earlier scenario left: rich, then broke
			advance(0.2)
			LocalPlayer:SetAttribute("Cash", 0)
			advance(0.3)
			local dim = glow and glow.Transparency
			LocalPlayer:SetAttribute("Cash", 1e12)
			local seen = {}
			for _ = 1, 10 do
				advance(0.1)
				seen[#seen + 1] = glow and glow.Transparency or 0
			end
			local lo, hi = huge, -huge
			for _, v in ipairs(seen) do
				lo, hi = min(lo, v), max(hi, v)
			end
			T.check(glow and dim >= 0.55 and hi - lo > 0.05 and lo < dim, "HomeFx: the owner's pad dims while Cash cannot pay its price and pulses once it can",
				"dim " .. fmt(dim) .. ", affordable " .. fmt(lo) .. ".." .. fmt(hi))
		else
			T.warn("HomeFx: no priced unlocked pad on the test home, affordability skipped")
		end

		-- far away: frozen, blocks recycled
		if cam then
			cam.CFrame = CFrame.lookAt(base.Position + Vector3.new(0, 40, 2000), base.Position + Vector3.new(0, 0, 1900))
		end
		advance(1.5)
		local live = 0
		fx = workspace:FindFirstChild("ClientFx") and workspace.ClientFx:FindFirstChild("HomeFx")
		if fx then
			for _, b in ipairs(fx:GetChildren()) do
				if b:IsA("BasePart") then
					live = live + 1
				end
			end
		end
		local headPos = headPart and headPart.Position
		advance(1.0)
		T.check(live == 0 and (not headPart or (headPart.Position - headPos).Magnitude < 1e-6), "HomeFx: homes far from the camera freeze and recycle their blocks", live .. " blocks left")
		if petId then
			local pf = petsFolder()
			T.check((not pf or #pf:GetChildren() == 0) and (tonumber(stats().GardenPets) or 0) == 0, "HomeFx: ...and put their garden pets away")
		end
		if cam and savedCam then
			cam.CFrame = savedCam
		end

		-- ownership changes: the neighbour's home becomes ours (prompts come back per lock state)
		HB.SetOwner(theirs, LocalPlayer)
		advance(0.3)
		local back = 0
		local should = 0
		for _, p in ipairs(prompts(theirHome, { BuyPrompt = true })) do
			local pad2 = p.Parent and p.Parent.Parent
			local locked = pad2 and pad2:GetAttribute("Locked")
			if locked == nil or locked == "" then
				should = should + 1
				if p.Enabled then
					back = back + 1
				end
			end
		end
		T.check(should > 0 and back == should, "HomeFx: when a home becomes the local player's, its unlocked BuyPrompts come back", back .. " of " .. should)

		-- clean up: ClearPlot and removing a home are followed
		local stations0 = tonumber(stats().Stations) or 0
		HB.ClearPlot(theirs)
		advance(0.2)
		T.check((tonumber(stats().Stations) or 0) < stations0, "HomeFx: ClearPlot's removed stations are forgotten")
		local c0 = count()
		root:Destroy()
		advance(0.5)
		T.check(count() <= c0 - 3, "HomeFx: removed homes are forgotten", c0 .. " -> " .. count())
		Mock.RemovePlayer(neighbour)
		LocalPlayer:SetAttribute("Cash", nil)
		advance(0.5)
		local warned = nil
		for i = outputBefore + 1, #Mock.Output do
			local o = Mock.Output[i]
			if o.kind == "warn" and o.text:find("HomeFx", 1, true) then
				warned = o.text
			end
		end
		T.check(warned == nil and #Mock.Errors == errorsBefore, "HomeFx: no errors or warnings from HomeFx", tostring(warned))
		KC.flushErrors("client_p2home")
	end)

	return S
end

if CONTEXT == "server" then
	return serverScenarios()
end
return clientScenarios()
