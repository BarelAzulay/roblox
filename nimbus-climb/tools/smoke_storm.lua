-- smoke_storm.lua: the Stormfang round (ARCHITECTURE_V3.md section 10 and the ELEMENTS part of section 11) in one
-- place. Loaded by tools/smoke.py in BOTH worlds (like smoke_dev.lua); ARGS.context picks the half:
--   storm_elements  (server, content) Config.Elements holds the eight elements with a badge colour each; every pet
--                   has one valid Element (GetElements / ElementsOf agree); every element has >= 3 pets;
--                   ElementMultiplier gives x1.5 / x0.75 / x1 around the wheel Water > Flame > Frost > Nature >
--                   Earth > Storm > Water, x1.5 BOTH ways for Celestial <-> Shadow, lets a dual-element attacker
--                   use its better element and never raises on junk
--   storm_pet       (server, content) the catalog entry (Secret, Combat, special kind Pounce, species Stormfang,
--                   WingStyle StormCloud, Element Storm, first among the Secrets, never rollable yet) and
--                   PetCatalog.Validate(); PetBuilder.Build at High (<= 350 parts) and Low (<= 120): PrimaryPart,
--                   WingL / WingR, Neon claws / eyes / gems, pet part flags; Animate for a few seconds (no errors,
--                   NaN or new instances; the storm cloud sways gently instead of flapping); Scale 3 (the showcase)
--   storm_altar     (server, after boot) the altar Main built at boot, then StormAltar.Build(real LobbyInfo) again:
--                   one Model StormAltar (a rebuild replaces it on the same site), StormfangShowcase (tag
--                   NC_Showcase, attribute PetId, PetBuilder High), StormAltarSign ("STORM ALTAR" + the player's
--                   art, the only asset id; World text rule: a pixel-sized title tag, 40-60 px/stud signs, with
--                   small sign letters reported as a warning), <= 450 parts without the showcase, no overlap with
--                   the portals, roulette machines, NPC spots / NPC pets, the spawn or the home plots (oriented part
--                   boxes, separating-axis test), a walkable path from the island over the bridge down onto the
--                   street (a step-by-step ray walk: no gaps, no walls, small steps), and the "Storm Altar"
--                   ProximityPrompt (reachable from the deck) sends the side toast (Notify) to that player only,
--                   rate-limited per player, ignoring forged triggers
--   client_storm    (client) element pills (Element_<E>, coloured from Config.Elements.Info, readable) on every
--                   DISCOVERED card of every Index group and never on a ??? card, on every pet of every roulette's
--                   odds list and in the Pets panel detail; the Index art banner (Config.Art.StormfangImage) only for
--                   a discovered Stormfang; no other asset id on screen; the altar toast is a side toast (never
--                   centred); ShowcaseController hovers / pulses a tagged showcase, puts it back when the tag goes
--                   and cleans up when the showcase is destroyed
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local CONTEXT = (ARGS and ARGS.context) or "server"

local abs, max, min, huge = math.abs, math.max, math.min, math.huge
local SPEC = CONTRACT.v3.stormfang
local SECRET = CONTRACT.v3.secretRarity
local SHOWCASE_TAG = "NC_Showcase"
local TOAST_TEXT = "The Storm Altar awakens soon: summon Secret pets with Gems!"
local TOAST_NEEDLE = "awakens soon"

local function fmt(v, n)
	return string.format("%." .. (n or 1) .. "f", tonumber(v) or 0)
end

local function countParts(root, skip)
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and not (skip and d:IsDescendantOf(skip)) then
			n = n + 1
		end
	end
	return n
end

local function named(root, name)
	if not root then
		return nil
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == name then
			return d
		end
	end
	return nil
end

local function hdist(a, b)
	return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
end

local function colorDistance255(a, b)
	return math.sqrt(((a.R - b.R) * 255) ^ 2 + ((a.G - b.G) * 255) ^ 2 + ((a.B - b.B) * 255) ^ 2)
end

local function plain(text)
	return (tostring(text):gsub("<[^>]*>", ""))
end

-- every image / texture / mesh / sound id of `root` that is neither empty, built in (rbxasset://) nor the player's
-- art: { "ClassName Name: id" }
local function foreignAssets(root, art)
	local out = {}
	local function check(d, id)
		id = tostring(id or "")
		if id ~= "" and id ~= art and not id:find("^rbxasset://") then
			out[#out + 1] = d.ClassName .. " " .. d.Name .. ": " .. id
		end
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ImageLabel") or d:IsA("ImageButton") then
			check(d, d.Image)
		elseif d:IsA("Decal") or d:IsA("Texture") or d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
			check(d, d.Texture)
		elseif d:IsA("SpecialMesh") then
			check(d, d.MeshId)
			check(d, d.TextureId)
		elseif d:IsA("Sound") then
			check(d, d.SoundId)
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- server world
----------------------------------------------------------------------------------------------------
local function serverScenarios()
	local K = _G.K
	local S = {}
	local M, config, advance = K.M, K.config, K.advance
	local Players = game:GetService("Players")
	local CollectionService = game:GetService("CollectionService")

	local function finiteCFrame(cf)
		local c = { cf:GetComponents() }
		for i = 1, 12 do
			local v = c[i]
			if type(v) ~= "number" or v ~= v or v == huge or v == -huge then
				return false
			end
		end
		return true
	end

	local function angleBetween(a, b)
		return math.deg(math.acos(max(-1, min(1, a:Dot(b)))))
	end

	-- Neon parts whose name starts with `prefix`
	local function neonNamed(model, prefix)
		local n = 0
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.Material == Enum.Material.Neon and d.Name:sub(1, #prefix) == prefix then
				n = n + 1
			end
		end
		return n
	end

	------------------------------------------------------------------------------------------------
	-- elements
	------------------------------------------------------------------------------------------------
	-- the multiplier ARCHITECTURE_V3.md section 11 asks for (tools/contract.json v3.elements)
	local function wanted(a, d)
		local E = CONTRACT.v3.elements
		local wheel = E.wheel
		for i, e in ipairs(wheel) do
			local nextE = wheel[i % #wheel + 1]
			if a == e and d == nextE then
				return E.strong
			elseif d == e and a == nextE then
				return E.weak
			end
		end
		local p = E.pair
		if (a == p[1] and d == p[2]) or (a == p[2] and d == p[1]) then
			return E.strong
		end
		return 1
	end

	S.storm_elements = guarded("storm_elements", function()
		local Config, PC = config(), M["shared/PetCatalog"]
		if not T.check(type(PC) == "table" and type(Config) == "table", "elements: PetCatalog and Config are loaded") then
			return
		end
		local E = Config.Elements
		if not T.check(type(E) == "table" and type(E.Order) == "table" and type(E.Info) == "table", "elements: Config.Elements has Order and Info") then
			return
		end
		-- the eight elements of the doc, each with a badge colour
		local expected = {}
		for _, e in ipairs(CONTRACT.v3.elements.wheel) do
			expected[#expected + 1] = e
		end
		for _, e in ipairs(CONTRACT.v3.elements.pair) do
			expected[#expected + 1] = e
		end
		local missing = {}
		for _, e in ipairs(expected) do
			if not T.contains(E.Order, e) then
				missing[#missing + 1] = e
			end
		end
		T.check(#missing == 0 and #E.Order == #expected, "elements: Config.Elements.Order holds the " .. #expected .. " elements (the wheel + Celestial / Shadow)", table.concat(E.Order, ", ") .. (#missing > 0 and (" (missing " .. table.concat(missing, ", ") .. ")") or ""))
		local colours = T.tally("elements: every element has a badge colour (Config.Elements.Info[e].Color)")
		for _, e in ipairs(E.Order) do
			local info = E.Info[e]
			colours:case(type(info) == "table" and typeof(info.Color) == "Color3", e .. ": " .. tostring(info and info.Color))
		end
		colours:report()
		T.check(E.StrongMultiplier == CONTRACT.v3.elements.strong and E.WeakMultiplier == CONTRACT.v3.elements.weak, "elements: Config.Elements.StrongMultiplier / WeakMultiplier are x" .. CONTRACT.v3.elements.strong .. " / x" .. CONTRACT.v3.elements.weak, tostring(E.StrongMultiplier) .. " / " .. tostring(E.WeakMultiplier))

		-- every pet: one valid Element, and the helpers agree
		local valid = {}
		for _, e in ipairs(E.Order) do
			valid[e] = true
		end
		local each = T.tally("elements: every pet has one valid Element (Config.Elements.Order) and GetElements / ElementsOf agree")
		local perElement, rarities = {}, {}
		for _, def in ipairs(PC.Pets) do
			local okG, got = pcall(PC.GetElements, def.Id)
			local okE, of = pcall(PC.ElementsOf, def)
			local ok = valid[def.Element] == true and okG and type(got) == "table" and #got == 1 and got[1] == def.Element
				and okE and type(of) == "table" and #of == 1 and of[1] == def.Element
			each:case(ok, def.Id .. ": Element " .. tostring(def.Element) .. ", GetElements " .. ((okG and type(got) == "table") and ("{" .. table.concat(got, ",") .. "}") or tostring(got)))
			if valid[def.Element] then
				perElement[def.Element] = (perElement[def.Element] or 0) + 1
				rarities[def.Element] = rarities[def.Element] or {}
				rarities[def.Element][def.Rarity] = true
			end
		end
		each:report()
		local need = CONTRACT.v3.elements.minPetsPerElement
		local spread = T.tally("elements: every element has at least " .. need .. " pets, in several rarities")
		local summary = {}
		for _, e in ipairs(E.Order) do
			local nR = 0
			for _ in pairs(rarities[e] or {}) do
				nR = nR + 1
			end
			spread:case((perElement[e] or 0) >= need and nR >= 2, e .. ": " .. (perElement[e] or 0) .. " pets in " .. nR .. " rarities")
			summary[#summary + 1] = e .. " " .. (perElement[e] or 0)
		end
		spread:report(table.concat(summary, ", "))
		T.info("*elements: " .. table.concat(summary, ", "))

		-- the damage chart
		if not T.check(type(PC.ElementMultiplier) == "function", "elements: PetCatalog.ElementMultiplier exists") then
			return
		end
		local chart = T.tally("elements: ElementMultiplier(attack, defend) for all " .. (#E.Order * #E.Order) .. " pairs is x1.5 (strong) / x0.75 (weak) / x1")
		for _, a in ipairs(E.Order) do
			for _, d in ipairs(E.Order) do
				local ok, got = pcall(PC.ElementMultiplier, a, d)
				chart:case(ok and type(got) == "number" and abs(got - wanted(a, d)) < 1e-9, a .. " -> " .. d .. ": " .. tostring(got) .. " (want " .. wanted(a, d) .. ")")
			end
		end
		chart:report()
		local function m(a, d)
			local ok, v = pcall(PC.ElementMultiplier, a, d)
			if ok then
				return v
			end
			return "error: " .. tostring(v)
		end
		local wheel = CONTRACT.v3.elements.wheel
		local wheelBad = nil
		for i, e in ipairs(wheel) do
			local nextE = wheel[i % #wheel + 1]
			if m(e, nextE) ~= 1.5 or m(nextE, e) ~= 0.75 then
				wheelBad = wheelBad or (e .. " -> " .. nextE .. " x" .. tostring(m(e, nextE)) .. ", back x" .. tostring(m(nextE, e)))
			end
		end
		T.check(wheelBad == nil, "elements: around the wheel (" .. table.concat(wheel, " > ") .. " > " .. wheel[1] .. ") each beats the next for x1.5 and takes x0.75 back", wheelBad)
		T.check(m("Celestial", "Shadow") == 1.5 and m("Shadow", "Celestial") == 1.5, "elements: Celestial and Shadow hit each other for x1.5 BOTH ways", tostring(m("Celestial", "Shadow")) .. " / " .. tostring(m("Shadow", "Celestial")))
		T.check(m("Storm", "Celestial") == 1 and m("Shadow", "Storm") == 1 and m("Water", "Frost") == 1 and m("Storm", "Storm") == 1 and m("Flame", "Earth") == 1,
			"elements: everything else is x1 (Storm vs Celestial, Shadow vs Storm, Water vs Frost, Storm vs Storm, Flame vs Earth)")
		T.check(m({ "Nature", "Earth" }, "Storm") == 1.5 and m({ "Water", "Flame" }, "Flame") == 1.5 and m({ "Flame", "Frost" }, "Water") == 1,
			"elements: a dual-element attacker (fused hybrid) uses its better element", tostring(m({ "Nature", "Earth" }, "Storm")) .. ", " .. tostring(m({ "Water", "Flame" }, "Flame")) .. ", " .. tostring(m({ "Flame", "Frost" }, "Water")))
		local junkOk, junkBad = true, nil
		for _, pair in ipairs({ { nil, nil }, { "Plasma", "Storm" }, { "Storm", 42 }, { {}, {} }, { { "Plasma" }, "Water" }, { "storm", "water" } }) do
			local ok, v = pcall(PC.ElementMultiplier, pair[1], pair[2])
			if not (ok and v == 1) then
				junkOk = false
				junkBad = junkBad or (tostring(pair[1]) .. " vs " .. tostring(pair[2]) .. ": " .. tostring(v))
			end
		end
		T.check(junkOk, "elements: unknown / nil / empty / wrongly cased elements give x1 without raising", junkBad)
		K.flushErrors("storm_elements")
		K.flushWarnings("storm_elements")
	end)

	------------------------------------------------------------------------------------------------
	-- the Stormfang pet
	------------------------------------------------------------------------------------------------
	S.storm_pet = guarded("storm_pet", function()
		local Config, PC, PB = config(), M["shared/PetCatalog"], M["shared/PetBuilder"]
		if not T.check(type(PC) == "table" and type(PB) == "table", "Stormfang: PetCatalog and PetBuilder are loaded") then
			return
		end
		local def = PC.Get(SPEC.petId)
		if not T.check(type(def) == "table", "Stormfang: PetCatalog.Get('" .. SPEC.petId .. "') returns the player's creature") then
			return
		end
		local look = type(def.Look) == "table" and def.Look or {}
		local sp = type(def.Special) == "table" and def.Special or {}
		T.eq(def.Name, SPEC.name, "Stormfang: Name")
		T.eq(def.Rarity, SECRET, "Stormfang: Rarity Secret")
		T.eq(def.Role, SPEC.role, "Stormfang: Role Combat")
		T.check(sp.Kind == SPEC.specialKind and type(sp.Name) == "string" and sp.Name ~= "", "Stormfang: its special is of kind Pounce", tostring(sp.Name) .. " / " .. tostring(sp.Kind))
		T.eq(look.Species, SPEC.species, "Stormfang: species Stormfang (its own sculpt)")
		T.eq(look.WingStyle, SPEC.wingStyle, "Stormfang: WingStyle StormCloud (it rides a storm cloud)")
		T.eq(def.Element, SPEC.element, "Stormfang: Element Storm")
		T.check(T.contains(PC.Species or {}, SPEC.species) and T.contains(PB.Species or {}, SPEC.species), "Stormfang: the species is in PetCatalog.Species and PetBuilder.Species")
		T.check(T.contains(PC.WingStyles or {}, SPEC.wingStyle) and T.contains(PB.WingStyles or {}, SPEC.wingStyle), "Stormfang: StormCloud is in PetCatalog.WingStyles and PetBuilder.WingStyles")
		if T.check(type(PC.Validate) == "function", "PetCatalog.Validate exists") then
			local ok, valid, problems = pcall(PC.Validate)
			T.check(ok and valid == true, "PetCatalog.Validate() passes with Stormfang and the elements", ok and table.concat(type(problems) == "table" and problems or {}, "; ") or tostring(valid))
		end
		-- Secret pets come from the phase-2 gems-only roulette: no current roulette offers Stormfang
		local offeredBy = {}
		for _, r in ipairs(Config.Roulettes) do
			for _, o in ipairs(PC.GetOdds(r.Id)) do
				if o.PetId == SPEC.petId then
					offeredBy[#offeredBy + 1] = r.Id
				end
			end
		end
		T.check(#offeredBy == 0 and (type(PC.IsRollable) ~= "function" or PC.IsRollable(SPEC.petId) == false), "Stormfang: no current roulette offers it (the Secret roulette comes in phase 2)", table.concat(offeredBy, ", "))
		local secrets = PC.ListByRarity(SECRET)
		T.check(secrets[1] == def, "Stormfang: listed first among the Secret pets", secrets[1] and secrets[1].Id or "none")
		local leads = false
		for _, g in ipairs(PC.IndexGroups()) do
			if g.Id == SECRET and g.Pets[1] and g.Pets[1].Id == SPEC.petId then
				leads = true
			end
		end
		T.check(leads, "Stormfang: leads the Secret group of the Pet Index")
		local s1, s10 = PC.GetStats(SPEC.petId, 1), PC.GetStats(SPEC.petId, 10)
		T.check(type(s1) == "table" and type(s10) == "table" and s1.Power > s1.Income and s10.Power > s1.Power, "Stormfang: Combat stats (Power > Income) that grow with the level",
			type(s1) == "table" and ("Power " .. tostring(s1.Power) .. ", Income " .. tostring(s1.Income)) or tostring(s1))

		-- PetBuilder at both detail levels
		local holder = Instance.new("Folder")
		holder.Name = "SmokeStormfang"
		holder.Parent = workspace
		local budgets = { High = CONTRACT.v3.partBudget.petHigh, Low = CONTRACT.v3.partBudget.petLow }
		local counts = {}
		for i, level in ipairs(CONTRACT.v3.petDetail.levels) do
			local cap = budgets[level]
			local label = "Stormfang " .. level
			local ok, model = pcall(PB.Build, def, { Detail = level })
			if T.check(ok and typeof(model) == "Instance" and model:IsA("Model"), label .. ": PetBuilder.Build returns a Model", tostring(model)) then
				model.Parent = holder
				model:PivotTo(CFrame.new(i * 40, 3200, 0))
				local n = countParts(model)
				counts[level] = n
				T.check(n <= cap and n >= 12, label .. ": within the " .. level .. " part budget (<= " .. cap .. ")", n .. " parts")
				local primary = model.PrimaryPart
				T.check(primary ~= nil and primary:IsDescendantOf(model), label .. ": has a PrimaryPart")
				local wl, wr = model:FindFirstChild("WingL", true), model:FindFirstChild("WingR", true)
				T.check(wl ~= nil and wr ~= nil and wl:IsA("BasePart") and wr:IsA("BasePart"), label .. ": the storm cloud halves are WingL / WingR", tostring(wl) .. " / " .. tostring(wr))
				local claws, eyes, gems = neonNamed(model, "Claw"), neonNamed(model, "Eye"), neonNamed(model, "Gem")
				T.check(claws >= 2 and eyes >= 2 and gems >= 1, label .. ": glowing Neon claws, eyes and gem(s)", claws .. " claw, " .. eyes .. " eye, " .. gems .. " gem Neon parts")
				local badFlags = 0
				for _, d in ipairs(model:GetDescendants()) do
					if d:IsA("BasePart") and not (d.Anchored and not d.CanCollide and not d.CanTouch and not d.CanQuery) then
						badFlags = badFlags + 1
					end
				end
				T.eq(badFlags, 0, label .. ": every part is Anchored with CanCollide / CanTouch / CanQuery off")
				-- Animate for three seconds: no errors, NaN or new instances; the cloud sways, it does not flap
				if primary and wl and wr then
					local before = Mock.CountDescendants(model)
					local rel0 = primary.CFrame:ToObjectSpace(wl.CFrame)
					local spread, drift, mirror = 0, 0, 0
					local animOk, animErr = pcall(function()
						for f = 1, 90 do
							PB.Animate(model, f / 30, { Flap = 1, Excited = (f % 30) / 30 })
							local a = primary.CFrame:ToObjectSpace(wl.CFrame)
							local b = primary.CFrame:ToObjectSpace(wr.CFrame)
							spread = max(spread, angleBetween(a.UpVector, rel0.UpVector), angleBetween(a.LookVector, rel0.LookVector), angleBetween(a.RightVector, rel0.RightVector))
							drift = max(drift, (a.Position - rel0.Position).Magnitude)
							mirror = max(mirror, abs(a.Position.X + b.Position.X), abs(a.Position.Y - b.Position.Y), abs(a.Position.Z - b.Position.Z))
						end
					end)
					local finite = true
					for _, d in ipairs(model:GetDescendants()) do
						if d:IsA("BasePart") and not finiteCFrame(d.CFrame) then
							finite = false
						end
					end
					T.check(animOk and finite and Mock.CountDescendants(model) == before, label .. ": Animate runs for 90 frames without errors, NaN or new instances", tostring(animErr) .. ", finite " .. tostring(finite))
					T.check(spread < 40 and (spread > 0.3 or drift > 0.01), label .. ": the storm cloud sways / drifts gently (no 40+ degree wing flap)", fmt(spread, 1) .. " degrees, drift " .. fmt(drift, 3) .. " studs")
					T.check(mirror < 0.05, label .. ": WingL and WingR stay mirror images while animated", fmt(mirror, 3))
				end
			end
		end
		if counts.High and counts.Low then
			T.check(counts.Low < counts.High, "Stormfang: Low detail is lighter than High", counts.Low .. " vs " .. counts.High .. " parts")
		end
		-- the altar showcase size
		local okS, big = pcall(PB.Build, def, { Detail = "High", Scale = 3 })
		if T.check(okS and typeof(big) == "Instance" and big.PrimaryPart ~= nil, "Stormfang: builds at Scale 3 (the Storm Altar showcase)", tostring(big)) then
			big.Parent = holder
			big:PivotTo(CFrame.new(0, 3300, 80))
			local want = PB.GetHeight(def) * 3
			local got = big:GetExtentsSize().Y
			T.check(abs(got - want) <= want * 0.3 and countParts(big) <= budgets.High, "Stormfang at Scale 3: about 3x as tall (" .. fmt(want, 1) .. " studs) and within the High budget", fmt(got, 2) .. " studs, " .. countParts(big) .. " parts")
		end
		holder:Destroy()
		K.flushErrors("storm_pet")
		K.flushWarnings("storm_pet")
	end)

	------------------------------------------------------------------------------------------------
	-- the Storm Altar
	------------------------------------------------------------------------------------------------
	-- world axis-aligned bounds { x0, y0, z0, x1, y1, z1 } of an oriented box
	local function boxBounds(cf, s)
		local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
		local hx = (abs(r00) * s.X + abs(r01) * s.Y + abs(r02) * s.Z) / 2
		local hy = (abs(r10) * s.X + abs(r11) * s.Y + abs(r12) * s.Z) / 2
		local hz = (abs(r20) * s.X + abs(r21) * s.Y + abs(r22) * s.Z) / 2
		local c = cf.Position
		return { c.X - hx, c.Y - hy, c.Z - hz, c.X + hx, c.Y + hy, c.Z + hz }
	end
	-- bounds of every BasePart under `root` (and root itself when it is a part); nil when there is none
	local function boundsOf(root)
		if typeof(root) ~= "Instance" then
			return nil
		end
		local b = nil
		local function add(p)
			local pb = boxBounds(p.CFrame, p.Size)
			if not b then
				b = pb
			else
				for k = 1, 3 do
					b[k] = min(b[k], pb[k])
					b[k + 3] = max(b[k + 3], pb[k + 3])
				end
			end
		end
		if root:IsA("BasePart") then
			add(root)
		end
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") then
				add(d)
			end
		end
		return b
	end
	local function overlaps(a, b, tol)
		return a[1] < b[4] - tol and a[4] > b[1] + tol and a[2] < b[5] - tol and a[5] > b[2] + tol and a[3] < b[6] - tol and a[6] > b[3] + tol
	end
	-- an oriented box { c = centre, a = { 3 unit axes }, h = { 3 half sizes }, b = its world bounds }
	local function orientedBox(cf, s)
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
		return {
			c = { x, y, z },
			a = { { r00, r10, r20 }, { r01, r11, r21 }, { r02, r12, r22 } },
			h = { s.X / 2, s.Y / 2, s.Z / 2 },
			b = boxBounds(cf, s),
		}
	end
	local function dot3(u, v)
		return u[1] * v[1] + u[2] * v[2] + u[3] * v[3]
	end
	-- Separating-axis test: true when the two oriented boxes overlap by more than `tol` studs (a rotated part's
	-- world bounds are far bigger than the part, so the bounds alone would report overlaps that are not there).
	local function boxesOverlap(A, B, tol)
		if not overlaps(A.b, B.b, tol) then
			return false
		end
		local d = { B.c[1] - A.c[1], B.c[2] - A.c[2], B.c[3] - A.c[3] }
		local axes = {}
		for i = 1, 3 do
			axes[#axes + 1] = A.a[i]
			axes[#axes + 1] = B.a[i]
		end
		for i = 1, 3 do
			for j = 1, 3 do
				local u, v = A.a[i], B.a[j]
				local cx = { u[2] * v[3] - u[3] * v[2], u[3] * v[1] - u[1] * v[3], u[1] * v[2] - u[2] * v[1] }
				local len = math.sqrt(dot3(cx, cx))
				if len > 1e-4 then
					axes[#axes + 1] = { cx[1] / len, cx[2] / len, cx[3] / len }
				end
			end
		end
		for _, L in ipairs(axes) do
			local ra = A.h[1] * abs(dot3(A.a[1], L)) + A.h[2] * abs(dot3(A.a[2], L)) + A.h[3] * abs(dot3(A.a[3], L))
			local rb = B.h[1] * abs(dot3(B.a[1], L)) + B.h[2] * abs(dot3(B.a[2], L)) + B.h[3] * abs(dot3(B.a[3], L))
			if abs(dot3(d, L)) >= ra + rb - tol then
				return false
			end
		end
		return true
	end

	-- What the altar must keep clear of: { { kind, label, b = overall bounds, boxes = { { name, box } } } } where every
	-- box is an oriented box (one per part of a model obstacle), so only a real overlap counts.
	-- `region`: the altar's world bounds; boxes outside it are dropped right away (they cannot touch the altar).
	local function obstacles(info, Config, region)
		local list = {}
		local folder = info.Folder
		local function add(kind, label, boxes)
			if #boxes == 0 then
				return
			end
			local b, near = nil, {}
			for _, e in ipairs(boxes) do
				if not b then
					b = { e.box.b[1], e.box.b[2], e.box.b[3], e.box.b[4], e.box.b[5], e.box.b[6] }
				else
					for k = 1, 3 do
						b[k] = min(b[k], e.box.b[k])
						b[k + 3] = max(b[k + 3], e.box.b[k + 3])
					end
				end
				if overlaps(e.box.b, region, 0) then
					near[#near + 1] = e
				end
			end
			list[#list + 1] = { kind = kind, label = label, b = b, boxes = near, all = boxes }
		end
		local function addArea(kind, label, cf, size)
			add(kind, label, { { name = "its area", box = orientedBox(cf, size) } })
		end
		local function addModel(kind, label, root)
			if typeof(root) ~= "Instance" then
				return
			end
			local boxes = {}
			local all = root:GetDescendants()
			all[#all + 1] = root
			for _, d in ipairs(all) do
				if d:IsA("BasePart") then
					boxes[#boxes + 1] = { name = d.Name, box = orientedBox(d.CFrame, d.Size) }
				end
			end
			add(kind, label, boxes)
		end
		for _, diff in ipairs(Config.Difficulties) do
			addModel("portal", "Portal_" .. diff.Id, folder:FindFirstChild("Portal_" .. diff.Id, true))
			local p = info.Portals and info.Portals[diff.Id]
			if p and typeof(p.Zone) == "Instance" then
				addModel("portal", "portal zone " .. diff.Id, p.Zone)
			end
		end
		for _, r in ipairs(Config.Roulettes) do
			addModel("roulette", "Roulette_" .. r.Id, folder:FindFirstChild("Roulette_" .. r.Id, true))
		end
		for i, cf in ipairs(type(info.NpcSpots) == "table" and info.NpcSpots or {}) do
			if typeof(cf) == "CFrame" then
				addArea("npc", "NPC spot " .. i, cf * CFrame.new(0, 5, 0), Vector3.new(7, 10, 7))
			end
		end
		local npcs = workspace:FindFirstChild("NimbusNpcs")
		for _, m in ipairs(npcs and npcs:GetChildren() or {}) do
			addModel("npc", "NPC " .. m.Name, m)
		end
		if typeof(info.SpawnCFrame) == "CFrame" then
			addArea("spawn", "the spawn", info.SpawnCFrame, Vector3.new(12, 8, 12))
		end
		for _, d in ipairs(folder:GetDescendants()) do
			if d:IsA("SpawnLocation") then
				addModel("spawn", "SpawnLocation " .. d.Name, d)
			end
		end
		for i, sp in ipairs(type(info.Spots) == "table" and info.Spots or {}) do
			if typeof(sp.PlotCFrame) == "CFrame" then
				local size = sp.PlotSize or Config.Lobby.PlotSize
				addArea("plot", "home plot " .. i, sp.PlotCFrame * CFrame.new(0, 8, 0), Vector3.new(size, 20, size))
			end
			if typeof(sp.Folder) == "Instance" then
				addModel("plot", "home spot " .. i .. " (" .. sp.Folder.Name .. ")", sp.Folder)
			end
		end
		return list
	end

	-- A character's walk from `start` (on the island) along the flat unit vector `dir`: every stud a ray down
	-- from just above the feet must find a collidable floor (steps up <= MAX_STEP, drops <= MAX_DROP) and rays at
	-- knee and head height must find no wall. Succeeds on lobby ground (not the altar) at the street height.
	local MAX_STEP, MAX_DROP, HEAD = 1.6, 3, 4.6
	local FOOT = { { 0, 0 }, { 0.5, 0 }, { -0.5, 0 }, { 0, 0.5 }, { 0, -0.5 } } -- along, across (studs)
	local SAMPLE = 1 -- studs between two footsteps (every stair step is longer); each mock ray scans the workspace
	local function walk(altar, lobby, start, dir, maxDist, streetY, exclude)
		local side = Vector3.new(-dir.Z, 0, dir.X)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = exclude
		params.RespectCanCollide = true
		local first = workspace:Raycast(start + Vector3.new(0, 4, 0), Vector3.new(0, -10, 0), params)
		if not first or not first.Instance:IsDescendantOf(altar) then
			return false, "no walkable island deck at the start (" .. (first and first.Instance:GetFullName() or "nothing below") .. ")"
		end
		local h = first.Position.Y
		local prev = start
		local biggest = 0
		local trail = {} -- the last few floors, for the failure message
		local function lastFloors()
			return " [last floors: " .. table.concat(trail, ", ") .. "]"
		end
		for s = SAMPLE, maxDist, SAMPLE do
			local q = start + dir * s
			for _, lift in ipairs({ MAX_STEP + 0.3, HEAD }) do
				local wall = workspace:Raycast(Vector3.new(prev.X, h + lift, prev.Z), Vector3.new(q.X - prev.X, 0, q.Z - prev.Z), params)
				if wall then
					return false, string.format("blocked by %s %.1f studs along the way (%.1f studs above the feet)", wall.Instance:GetFullName(), s, lift) .. lastFloors()
				end
			end
			-- the floor under a foot (~1 stud wide): a thin seam between two deck slabs is no gap
			local hit = nil
			for _, o in ipairs(FOOT) do
				local p = q + dir * o[1] + side * o[2]
				hit = workspace:Raycast(Vector3.new(p.X, h + MAX_STEP + 0.3, p.Z), Vector3.new(0, -(MAX_STEP + 0.3 + MAX_DROP), 0), params)
				if hit then
					break
				end
			end
			if not hit then
				return false, string.format("a gap %.1f studs along the way (no floor within %.1f studs below)", s, MAX_DROP) .. lastFloors()
			end
			local y = hit.Position.Y
			if y - h > MAX_STEP then
				return false, string.format("a %.2f-stud ledge (%s) %.1f studs along the way", y - h, hit.Instance.Name, s) .. lastFloors()
			end
			trail[#trail + 1] = string.format("%.1f: %s y%+.2f", s, hit.Instance.Name, y - streetY)
			if #trail > 4 then
				table.remove(trail, 1)
			end
			biggest = max(biggest, abs(y - h))
			h = y
			prev = q
			if not hit.Instance:IsDescendantOf(altar) and hit.Instance:IsDescendantOf(lobby) and abs(y - streetY) <= 1.6 then
				return true, string.format("reached %s after %.1f studs (biggest step %.2f studs)", hit.Instance.Name, s, biggest), s
			end
		end
		return false, string.format("never reached lobby ground at the street height within %.0f studs (last floor at %.1f)", maxDist, h)
	end

	local function altarsInWorkspace()
		local out = {}
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == "StormAltar" and d:IsA("Model") then
				out[#out + 1] = d
			end
		end
		return out
	end

	S.storm_altar = guarded("storm_altar", function()
		if not K.needBoot() then
			return
		end
		local Config, PC = config(), M["shared/PetCatalog"]
		local SA = M["server/Services/StormAltar"]
		if not SA then
			local inst = K.moduleInstance("server/Services/StormAltar")
			if inst then
				local ok, result = pcall(require, inst)
				SA = ok and type(result) == "table" and result or nil
			end
		end
		if not T.check(type(SA) == "table" and type(SA.Build) == "function", "Storm Altar: server/Services/StormAltar.lua loads with Build") then
			return
		end
		local info = K.W.lobbyInfo
		local lobby = info.Folder

		-- the altar Main.server.lua built at boot
		local bootAltars = altarsInWorkspace()
		T.eq(#bootAltars, 1, "Storm Altar: boot built one Model StormAltar (Main.server.lua -> StormAltar.Build(lobbyInfo))")
		local oldPivot = bootAltars[1] and bootAltars[1]:GetPivot()

		-- build it again with the real LobbyInfo: replaces the old one on the same site
		local okB, A = pcall(SA.Build, info)
		advance(0.3)
		T.check(okB and typeof(A) == "CFrame", "Storm Altar: StormAltar.Build(real LobbyInfo) returns the altar CFrame", tostring(A))
		local altars = altarsInWorkspace()
		T.check(#altars == 1 and altars[1] ~= bootAltars[1], "Storm Altar: a rebuild replaces the old altar (still one StormAltar)", #altars .. " altars")
		local altar = altars[1]
		if not altar then
			return
		end
		if typeof(A) ~= "CFrame" then
			A = altar:GetPivot()
		end
		T.check(altar.Parent == lobby, "Storm Altar: it lives in the lobby folder (workspace.NimbusLobby)", altar:GetFullName())
		if type(SA.GetModel) == "function" then
			T.check(SA.GetModel() == altar, "Storm Altar: StormAltar.GetModel() returns it")
		end
		if oldPivot then
			T.check((altar:GetPivot().Position - oldPivot.Position).Magnitude < 0.05, "Storm Altar: the rebuild stands on the same site", fmt((altar:GetPivot().Position - oldPivot.Position).Magnitude, 3) .. " studs apart")
		end
		if typeof(info.AltarSite) == "CFrame" then
			T.check(hdist(A.Position, info.AltarSite.Position) <= 1, "Storm Altar: built at LobbyInfo.AltarSite", fmt(hdist(A.Position, info.AltarSite.Position), 2) .. " studs away")
		end

		-- the showcase
		local showcases = {}
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == "StormfangShowcase" then
				showcases[#showcases + 1] = d
			end
		end
		T.eq(#showcases, 1, "Storm Altar: exactly one StormfangShowcase in the workspace")
		local showcase = altar:FindFirstChild("StormfangShowcase", true)
		if T.check(showcase ~= nil and showcase:IsA("Model"), "Storm Altar: the big Stormfang (Model StormfangShowcase) is part of the altar") then
			T.check(CollectionService:HasTag(showcase, SHOWCASE_TAG), "Storm Altar: the showcase is tagged NC_Showcase (ShowcaseController animates it on the client)")
			local live = 0
			for _, m in ipairs(CollectionService:GetTagged(SHOWCASE_TAG)) do
				if m:IsDescendantOf(workspace) then
					live = live + 1
				end
			end
			T.eq(live, 1, "Storm Altar: one NC_Showcase model in the workspace (the old showcase went with the old altar)")
			T.eq(showcase:GetAttribute("PetId"), SPEC.petId, "Storm Altar: the showcase carries the attribute PetId = '" .. SPEC.petId .. "'")
			local n = countParts(showcase)
			T.check(n > 0 and n <= CONTRACT.v3.partBudget.showcasePet, "Storm Altar: the showcase is PetBuilder High detail (<= " .. CONTRACT.v3.partBudget.showcasePet .. " parts)", n .. " parts")
			local wantParts = showcase:GetAttribute("PetParts")
			if wantParts ~= nil then
				T.eq(wantParts, n, "Storm Altar: the showcase's PetParts attribute matches its part count (the client waits for them)")
			end
			if showcase:GetAttribute("Ready") ~= nil then
				T.eq(showcase:GetAttribute("Ready"), true, "Storm Altar: the showcase is marked Ready")
			end
			local loose = 0
			for _, d in ipairs(showcase:GetDescendants()) do
				if d:IsA("BasePart") and not (d.Anchored and not d.CanCollide) then
					loose = loose + 1
				end
			end
			T.eq(loose, 0, "Storm Altar: every showcase part is anchored and non-colliding")
			local def = PC and PC.Get(SPEC.petId)
			local PB = M["shared/PetBuilder"]
			if def and PB then
				local want = PB.GetHeight(def) * 3
				T.check(abs(showcase:GetExtentsSize().Y - want) <= want * 0.3, "Storm Altar: the showcase is Scale ~3", fmt(showcase:GetExtentsSize().Y, 2) .. " studs tall vs ~" .. fmt(want, 2))
			end
		end

		-- part budget (the showcase pet excluded)
		local parts = countParts(altar, showcase)
		T.check(parts <= CONTRACT.v3.partBudget.stormAltar and parts >= 30, "Storm Altar: at most " .. CONTRACT.v3.partBudget.stormAltar .. " parts without the showcase pet", parts .. " parts")
		T.info("*Storm Altar: " .. parts .. " parts + showcase " .. (showcase and countParts(showcase) or 0) .. " parts, " .. Mock.CountDescendants(altar) .. " instances")

		-- the sign and the only asset id
		local sign = altar:FindFirstChild("StormAltarSign", true)
		if T.check(sign ~= nil, "Storm Altar: the poster StormAltarSign exists") then
			local text = K.plainText(K.textsUnder(sign)):upper()
			T.check(text:find("STORM ALTAR", 1, true) ~= nil or text:find("STORM\nALTAR", 1, true) ~= nil, "Storm Altar: the sign reads 'STORM ALTAR'", text:sub(1, 120))
			local art = false
			for _, d in ipairs(sign:GetDescendants()) do
				if (d:IsA("ImageLabel") or d:IsA("ImageButton")) and d.Image == Config.Art.StormfangImage then
					art = true
				elseif (d:IsA("Decal") or d:IsA("Texture")) and d.Texture == Config.Art.StormfangImage then
					art = true
				end
			end
			T.check(art, "Storm Altar: the sign shows the player's art (Config.Art.StormfangImage)")
		end
		-- World text rule (ARCHITECTURE_V3.md): a tag above a thing is a PIXEL-sized BillboardGui (names >= 22 px,
		-- lines >= 18 px, LightInfluence 0, a sensible MaxDistance); a surface sign runs at 40-60 px per stud with
		-- title letters of ~1 stud and info lines of ~0.6 stud
		local tags = T.tally("Storm Altar: every BillboardGui with text is pixel-sized (offset UDim2, no TextScaled) with names >= 22 px, lines >= 18 px, LightInfluence 0 and MaxDistance 40-250")
		local boards = T.tally("Storm Altar: every SurfaceGui sign runs at 40-60 PixelsPerStud with LightInfluence 0")
		local smallLetters = {}
		for _, d in ipairs(altar:GetDescendants()) do
			local isTag, isBoard = d:IsA("BillboardGui"), d:IsA("SurfaceGui")
			if isTag or isBoard then
				local sizes, scaled = {}, false
				for _, t in ipairs(d:GetDescendants()) do
					if (t:IsA("TextLabel") or t:IsA("TextButton")) and (plain(t.Text):gsub("%s", "")) ~= "" then
						scaled = scaled or t.TextScaled
						sizes[#sizes + 1] = { size = t.TextSize, text = plain(t.Text):gsub("\n", " ") }
					end
				end
				table.sort(sizes, function(x, y)
					return x.size < y.size
				end)
				if isTag and #sizes > 0 then
					local pixel = d.Size.X.Scale == 0 and d.Size.Y.Scale == 0 and d.Size.X.Offset > 0 and d.Size.Y.Offset > 0
					tags:case(pixel and not scaled and sizes[#sizes].size >= 22 and sizes[1].size >= 18 and d.LightInfluence == 0 and d.MaxDistance >= 40 and d.MaxDistance <= 250,
						string.format("%s: size %s%s, text %d-%d px, LightInfluence %s, MaxDistance %s", d.Name, tostring(d.Size), scaled and " with TextScaled labels" or "", sizes[1].size, sizes[#sizes].size, tostring(d.LightInfluence), tostring(d.MaxDistance)))
				elseif isBoard then
					local pps = d.PixelsPerStud
					boards:case(d.SizingMode == Enum.SurfaceGuiSizingMode.PixelsPerStud and pps >= 40 and pps <= 60 and d.LightInfluence == 0, d.Name .. ": " .. tostring(d.SizingMode) .. " " .. tostring(pps) .. " px/stud, LightInfluence " .. tostring(d.LightInfluence))
					if #sizes > 0 and pps and pps > 0 then
						local title = sizes[#sizes]
						if title.size / pps < 0.95 then
							smallLetters[#smallLetters + 1] = string.format("title '%s' %.2f stud", title.text, title.size / pps)
						end
						for i = 1, #sizes - 1 do
							if sizes[i].size / pps < 0.6 then
								smallLetters[#smallLetters + 1] = string.format("'%s' %.2f stud", sizes[i].text, sizes[i].size / pps)
							end
						end
					end
				end
			end
		end
		tags:report()
		boards:report()
		if #smallLetters > 0 then
			-- the gate panel shares 8.4 x 4.8 studs with the player's art: reported, not failed
			T.warn("Storm Altar: sign letters below the World text rule (~1 stud titles, ~0.6 stud lines): " .. table.concat(smallLetters, "; "))
		end
		T.eq(Config.Art.StormfangImage, CONTRACT.v3.artImage, "Config.Art.StormfangImage is the player's uploaded sheet")
		local foreign = foreignAssets(altar, Config.Art.StormfangImage)
		T.check(#foreign == 0, "Storm Altar: no asset id but Config.Art.StormfangImage (built-in rbxasset:// textures only)", table.concat(foreign, "; "))

		-- no overlap with the portals, roulette machines, NPC spots / NPC pets, the spawn or the home plots
		local obs = obstacles(info, Config, boundsOf(altar))
		local kinds = {}
		for _, o in ipairs(obs) do
			kinds[o.kind] = (kinds[o.kind] or 0) + 1
		end
		T.check((kinds.portal or 0) >= #Config.Difficulties and (kinds.roulette or 0) >= #Config.Roulettes and (kinds.npc or 0) >= CONTRACT.v3.npcCount and (kinds.spawn or 0) >= 1 and (kinds.plot or 0) >= Config.Lobby.SpotCount,
			"Storm Altar overlap audit: finds the portals, roulette machines, NPC spots, spawn and home plots",
			string.format("%d portal, %d roulette, %d npc, %d spawn, %d plot boxes", kinds.portal or 0, kinds.roulette or 0, kinds.npc or 0, kinds.spawn or 0, kinds.plot or 0))
		do
			-- audit self-tests: a block at the spawn is caught; two thin crossed planks far apart are not
			local probe = orientedBox(info.SpawnCFrame or CFrame.new(), Vector3.new(2, 2, 2))
			local caught = false
			for _, o in ipairs(obs) do
				if o.kind == "spawn" and boxesOverlap(probe, o.all[1].box, 0.25) then
					caught = true
				end
			end
			local plankA = orientedBox(CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(45), 0), Vector3.new(80, 2, 2))
			local plankB = orientedBox(CFrame.new(30, 0, 30) * CFrame.Angles(0, math.rad(45), 0), Vector3.new(80, 2, 2))
			local crossing = orientedBox(CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(-45), 0), Vector3.new(80, 2, 2))
			T.check(caught and not boxesOverlap(plankA, plankB, 0.25) and boxesOverlap(plankA, crossing, 0.25), "Storm Altar overlap audit self-test: a block at the spawn is detected, parallel rotated planks are not, crossing ones are")
		end
		local hits, order = {}, {}
		for _, d in ipairs(altar:GetDescendants()) do
			if d:IsA("BasePart") then
				local box = orientedBox(d.CFrame, d.Size)
				for _, o in ipairs(obs) do
					if not hits[o.label] and #o.boxes > 0 and overlaps(box.b, o.b, 0.25) then
						for _, e in ipairs(o.boxes) do
							if boxesOverlap(box, e.box, 0.25) then
								order[#order + 1] = o.label
								hits[o.label] = (d:GetFullName():gsub("^Workspace%.NimbusLobby%.", "")) .. " vs " .. e.name
								break
							end
						end
					end
				end
			end
		end
		local described = {}
		for i = 1, min(#order, 4) do
			described[#described + 1] = order[i] .. " (" .. hits[order[i]] .. ")"
		end
		T.check(#order == 0, "Storm Altar: no altar part (island, dais, crystals, bridge, gate, showcase) overlaps a portal, roulette machine, NPC spot / NPC pet, the spawn or a home plot", #order .. " overlaps: " .. table.concat(described, "; "))

		-- the bridge: a walkable path from the island down onto the street
		local bridge = altar:FindFirstChild("Bridge", true)
		local exclude = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Character then
				exclude[#exclude + 1] = p.Character
			end
		end
		local startR = 16
		local deckStart = nil
		if T.check(bridge ~= nil, "Storm Altar: a Bridge model connects the island to the street") then
			-- the bridge runs from the altar centre towards its farthest collidable part (the street end)
			local far, farD = nil, -1
			for _, d in ipairs(bridge:GetDescendants()) do
				if d:IsA("BasePart") and d.CanCollide then
					local dd = hdist(d.Position, A.Position)
					if dd > farD then
						far, farD = d, dd
					end
				end
			end
			if T.check(far ~= nil and farD > startR, "Storm Altar: the bridge reaches beyond the island", fmt(farD, 1) .. " studs from the centre") then
				local flat = Vector3.new(far.Position.X - A.Position.X, 0, far.Position.Z - A.Position.Z).Unit
				local side = Vector3.new(-flat.Z, 0, flat.X)
				local streetY = Config.Lobby.Origin.Y
				local results, allOk = {}, true
				for _, offset in ipairs({ -2, 0, 2 }) do
					local start = Vector3.new(A.Position.X, A.Position.Y, A.Position.Z) + flat * startR + side * offset
					local ok, why = walk(altar, lobby, start, flat, farD - startR + 14, streetY, exclude)
					results[#results + 1] = string.format("offset %+d: %s", offset, why)
					allOk = allOk and ok
					if offset == 0 and ok then
						deckStart = start
					end
				end
				T.check(allOk, "Storm Altar: a player walks from the island over the bridge down onto the street (no gaps, no walls, steps <= " .. MAX_STEP .. " studs)", table.concat(results, " | "))
				-- walk self-test: with one deck slab made non-solid the same walk must find the gap
				local slab, best = nil, huge
				local mid = farD * 0.5 + startR * 0.5
				for _, d in ipairs(bridge:GetDescendants()) do
					if d:IsA("BasePart") and d.Name == "Deck" and d.CanCollide then
						local dd = abs(hdist(d.Position, A.Position) - mid)
						if dd < best then
							slab, best = d, dd
						end
					end
				end
				if slab then
					slab.CanCollide = false
					local okBroken, whyBroken = walk(altar, lobby, Vector3.new(A.Position.X, A.Position.Y, A.Position.Z) + flat * startR, flat, farD - startR + 14, streetY, exclude)
					slab.CanCollide = true
					T.check(not okBroken and tostring(whyBroken):find("gap", 1, true) ~= nil, "Storm Altar walk self-test: a missing deck slab is reported as a gap", tostring(whyBroken))
				end
				T.info("*Storm Altar bridge walk: " .. table.concat(results, " | "))
			end
		end

		-- the prompt: a side toast for that player only, rate-limited, forged triggers ignored
		local prompt = nil
		for _, d in ipairs(altar:GetDescendants()) do
			if d:IsA("ProximityPrompt") and (tostring(d.ObjectText) .. " " .. tostring(d.ActionText)):lower():find("storm altar", 1, true) then
				prompt = d
			end
		end
		if T.check(prompt ~= nil, "Storm Altar: a 'Storm Altar' ProximityPrompt") then
			T.check(prompt.Enabled ~= false and prompt.HoldDuration <= 0.5, "Storm Altar: the prompt is enabled and quick to use", "HoldDuration " .. tostring(prompt.HoldDuration))
			local anchor = prompt.Parent
			if anchor and anchor:IsA("Attachment") then
				anchor = anchor.Parent
			end
			if deckStart and anchor and anchor:IsA("BasePart") then
				local d = (anchor.Position - (deckStart + Vector3.new(0, 2.5, 0))).Magnitude
				T.check(d <= prompt.MaxActivationDistance, "Storm Altar: the prompt is in reach from the island deck by the bridge", fmt(d, 1) .. " studs, MaxActivationDistance " .. tostring(prompt.MaxActivationDistance))
			end
			local a = Mock.AddPlayer("StormVisitorA", 976101)
			local b = Mock.AddPlayer("StormVisitorB", 976102)
			advance(0.8)
			local function toasts(p, mark)
				local out = {}
				for _, e in ipairs(K.remotesFor("Notify", p.UserId, mark)) do
					if tostring(e.args[1]):lower():find(TOAST_NEEDLE, 1, true) then
						out[#out + 1] = e
					end
				end
				return out
			end
			local mark = K.logSize()
			Mock.Trigger(prompt, a)
			advance(0.1)
			local first = toasts(a, mark)
			local e = first[1]
			local sideKinds = { info = true, good = true, bad = true, token = true }
			T.check(#first == 1 and e.kind ~= "all" and sideKinds[e.args[2]] == true, "Storm Altar: using the prompt sends ONE side toast (Notify, kind info/good/bad/token) to that player",
				e and (tostring(e.args[1]) .. " / " .. tostring(e.args[2]) .. " / " .. tostring(e.kind)) or "no toast")
			if e then
				local text = tostring(e.args[1])
				T.check(text:lower():find("storm altar", 1, true) ~= nil and text:lower():find("secret", 1, true) ~= nil and text:lower():find("gems", 1, true) ~= nil,
					"Storm Altar: the toast says the altar awakens soon to summon Secret pets with Gems", text)
				T.check(e.args[3] == nil or (type(e.args[3]) == "number" and e.args[3] >= 2 and e.args[3] <= 8), "Storm Altar: the toast duration is sensible", tostring(e.args[3]))
			end
			T.eq(#toasts(b, mark), 0, "Storm Altar: ...the other player gets nothing")
			for _ = 1, 6 do
				Mock.Trigger(prompt, a)
				advance(0.2)
			end
			T.eq(#toasts(a, mark), 1, "Storm Altar: the toast is rate-limited per player (7 uses in ~1 s -> 1 toast)")
			Mock.Trigger(prompt, b)
			advance(0.1)
			T.eq(#toasts(b, mark), 1, "Storm Altar: ...while another player still gets theirs")
			advance(4)
			Mock.Trigger(prompt, a)
			advance(0.1)
			T.eq(#toasts(a, mark), 2, "Storm Altar: ...and a few seconds later the same player gets it again")
			local mark2 = K.logSize()
			local errorsBefore = #Mock.Errors
			Mock.FireSignal(prompt, "Triggered", nil)
			Mock.FireSignal(prompt, "Triggered", "StormVisitorA")
			Mock.FireSignal(prompt, "Triggered", workspace)
			advance(0.3)
			local stray = 0
			for _, ev in ipairs(K.remotesFor("Notify", nil, mark2)) do
				if tostring(ev.args[1]):lower():find(TOAST_NEEDLE, 1, true) then
					stray = stray + 1
				end
			end
			T.check(stray == 0 and #Mock.Errors == errorsBefore, "Storm Altar: forged prompt triggers (nil, a string, a non-player) send nothing and raise nothing", stray .. " toasts, " .. (#Mock.Errors - errorsBefore) .. " errors")
			K.removePlayers({ a, b })
		end

		-- the server never animates the altar (the client hovers the showcase)
		if showcase then
			local before = {}
			for _, d in ipairs(altar:GetDescendants()) do
				if d:IsA("BasePart") then
					before[d] = d.CFrame
				end
			end
			advance(1.5)
			local moved = 0
			for part, cf in pairs(before) do
				if part.Parent and (part.CFrame.Position - cf.Position).Magnitude > 1e-6 then
					moved = moved + 1
				end
			end
			T.eq(moved, 0, "Storm Altar: the server never moves an altar or showcase part (client-side animation only)")
		end
		K.flushErrors("storm_altar")
		K.flushWarnings("storm_altar")
	end)

	return S
end

----------------------------------------------------------------------------------------------------
-- client world
----------------------------------------------------------------------------------------------------
local function clientScenarios()
	local KC = _G.KC
	local S = {}
	local Players = game:GetService("Players")
	local CollectionService = game:GetService("CollectionService")
	local UserInputService = game:GetService("UserInputService")
	local LocalPlayer = Players.LocalPlayer
	local advance, gui, isShown, findText, toClient = KC.advance, KC.gui, KC.isShown, KC.findText, KC.toClient

	local function shared(name)
		return require(Mock.GetPath(ROOTS["shared"] .. "/" .. name))
	end
	local function controller(name)
		if KC.M[name] then
			return KC.M[name]
		end
		local inst = Mock.GetPath(ROOTS["client"] .. "/Controllers/" .. name)
		if not inst then
			return nil
		end
		local ok, result = pcall(require, inst)
		return ok and type(result) == "table" and result or nil
	end
	local function press(key)
		Mock.FireSignal(UserInputService, "InputBegan", Mock.NewInput(key, "Keyboard", "Begin"), false)
	end
	local function shown(obj)
		return obj ~= nil and isShown(obj)
	end

	-- a ProfileSync snapshot like the server's
	local function feed(over)
		local snap = {
			Tokens = 600,
			Pets = { cloudy_dragon = 1 },
			Equipped = {},
			Items = {},
			Stats = { Matches = 2, Wins = 1, TokensEarned = 300, Spins = 2, BestTimes = {} },
			SpotIndex = 3,
			Perks = { MaxHealth = 0, TokenBonus = 0, StaminaRegen = 0, CheckpointHeal = 0 },
			Discovered = {},
			IndexClaimed = {},
		}
		for k, v in pairs(over or {}) do
			snap[k] = v
		end
		LocalPlayer:SetAttribute("CloudTokens", snap.Tokens)
		toClient("ProfileSync", snap)
		advance(0.4)
	end

	-- the effective on-screen size of a label's text (TextSize x every UIScale above it)
	local function textPx(label)
		if label.TextScaled then
			return label.AbsoluteSize.Y
		end
		local scale = 1
		local cur = label
		while cur and cur ~= game do
			if cur:IsA("GuiObject") then
				for _, c in ipairs(cur:GetChildren()) do
					if c:IsA("UIScale") and c.Name ~= "FxScale" then
						scale = scale * c.Scale
					end
				end
			end
			cur = cur.Parent
		end
		return label.TextSize * scale
	end

	-- The shown element pill of `element` under `root`: a GuiObject named Element_<element> (or a label reading the
	-- element) whose own background, or one of its two closest GUI ancestors', has the Config.Elements.Info colour.
	-- Returns pill, problem.
	local function pillOf(root, element, Config)
		local info = Config.Elements and Config.Elements.Info and Config.Elements.Info[element]
		if not root then
			return nil, "no container"
		end
		if not info then
			return nil, "no Config.Elements.Info for " .. tostring(element)
		end
		local seen = {}
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("GuiObject") and shown(d) then
				local reads = (d:IsA("TextLabel") or d:IsA("TextButton")) and plain(d.Text):lower():find(element:lower(), 1, true) ~= nil
				if d.Name == "Element_" .. element or reads then
					local cur, depth, coloured = d, 0, false
					while cur and cur:IsA("GuiObject") and depth <= 2 do
						if cur.BackgroundTransparency < 0.5 and colorDistance255(cur.BackgroundColor3, info.Color) <= 45 then
							coloured = true
							break
						end
						cur, depth = cur.Parent, depth + 1
					end
					-- the label carrying the name: the object itself or a text child
					local label = (d:IsA("TextLabel") or d:IsA("TextButton")) and d or nil
					if not label then
						for _, c in ipairs(d:GetDescendants()) do
							if (c:IsA("TextLabel") or c:IsA("TextButton")) and plain(c.Text):lower():find(element:lower(), 1, true) then
								label = c
								break
							end
						end
					end
					if coloured and label and plain(label.Text):lower():find(element:lower(), 1, true) then
						if textPx(label) < 14.5 then
							return nil, string.format("the %s pill text is only %.1f px", element, textPx(label))
						end
						return d, nil
					end
					seen[#seen + 1] = d.Name .. " '" .. plain((d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text or "") .. "' coloured " .. tostring(coloured)
				end
			end
		end
		return nil, #seen > 0 and table.concat(seen, "; ", 1, min(#seen, 3)) or ("no shown pill for " .. element)
	end

	-- any shown element pill / element word under root (an undiscovered card must not give its element away)
	local function anyElementShown(root, Config)
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("GuiObject") and shown(d) then
				if d.Name:find("^Element_") then
					return d.Name
				end
				if d:IsA("TextLabel") or d:IsA("TextButton") then
					local t = plain(d.Text):lower()
					for _, e in ipairs(Config.Elements.Order or {}) do
						if t == e:lower() then
							return d.Name .. " '" .. d.Text .. "'"
						end
					end
				end
			end
		end
		return nil
	end

	local function menuGui()
		return gui():FindFirstChild("NimbusMenu")
	end
	local function visibleWindows()
		local out = {}
		local menu = menuGui()
		for _, c in ipairs(menu and menu:GetChildren() or {}) do
			if c.Name:find("^Window_") and c:IsA("GuiObject") and c.Visible then
				out[#out + 1] = c.Name
			end
		end
		return out
	end
	local function closeAll(Index)
		local popup = menuGui() and menuGui():FindFirstChild("OddsPopup")
		for _ = 1, 3 do
			if (popup and popup.Visible) or #visibleWindows() > 0 or (Index and Index.IsOpen and Index.IsOpen()) then
				press("Escape")
				advance(0.4)
			end
		end
		if Index and Index.IsOpen and Index.IsOpen() and Index.Close then
			Index.Close()
			advance(0.4)
		end
	end
	local function pickButton(tile)
		if not tile then
			return nil
		end
		if tile:IsA("GuiButton") then
			return tile
		end
		return tile:FindFirstChildWhichIsA("TextButton", true) or tile:FindFirstChildWhichIsA("ImageButton", true)
	end

	-- Pet Index: pills on discovered cards only (every group), and the Stormfang art banner
	local function indexChecks(Config, PC, Index)
		local art = Config.Art.StormfangImage
		local indexGui = gui():FindFirstChild("NimbusIndex")
		local function window()
			indexGui = gui():FindFirstChild("NimbusIndex")
			return indexGui and named(indexGui, "Window_Index")
		end
		local function bannerShown()
			local w = window()
			for _, d in ipairs(w and w:GetDescendants() or {}) do
				if (d:IsA("ImageLabel") or d:IsA("ImageButton")) and d.Image == art and shown(d) then
					return true
				end
			end
			return false
		end
		local function select(id)
			local b = pickButton(named(window(), "IndexPet_" .. id))
			if b then
				Mock.Click(b)
				advance(0.6)
			end
			return b ~= nil
		end
		-- 1. the banner: hidden while Stormfang is undiscovered, shown once discovered, only on its own card
		local secrets = PC.ListByRarity(SECRET)
		local other = nil
		for _, def in ipairs(secrets) do
			if def.Id ~= SPEC.petId then
				other = def
				break
			end
		end
		local disc = { cloudy_dragon = true }
		if other then
			disc[other.Id] = true
		end
		feed({ Discovered = disc })
		Index.Open(SECRET)
		advance(1.5)
		if not T.check(window() ~= nil and shown(window()) and Index.IsOpen(), "storm Index: Index.Open('Secret') shows the Pet Index window") then
			return
		end
		local stormTile = named(window(), "IndexPet_" .. SPEC.petId)
		T.check(stormTile ~= nil, "storm Index: the Secret group has a card for Stormfang (IndexPet_stormfang)")
		select(SPEC.petId)
		T.check(not bannerShown(), "storm Index: undiscovered, Stormfang's detail shows no art banner (it is a ??? silhouette like every pet)")
		T.check(stormTile ~= nil and findText("???", stormTile) ~= nil and anyElementShown(stormTile, Config) == nil, "storm Index: ...its card reads '???' without an element pill",
			stormTile and tostring(anyElementShown(stormTile, Config)) or "no card")
		disc[SPEC.petId] = true
		feed({ Discovered = disc })
		select(SPEC.petId)
		T.check(bannerShown(), "storm Index: once discovered, Stormfang's detail shows the player's art banner (Config.Art.StormfangImage)")
		local pill, why = pillOf(window(), SPEC.element, Config)
		T.check(pill ~= nil, "storm Index: ...and its Storm element pill", why)
		if other then
			select(other.Id)
			T.check(not bannerShown(), "storm Index: another discovered Secret pet (" .. other.Name .. ") shows no art banner")
			select(SPEC.petId)
			T.check(bannerShown(), "storm Index: ...and back on Stormfang the banner returns")
		end

		-- 2. element pills on every DISCOVERED card of every group, never on a ??? card
		local discovered = { cloudy_dragon = true }
		local hidden = {}
		for _, group in ipairs(PC.IndexGroups()) do
			for i, def in ipairs(group.Pets) do
				if i % 2 == 1 or def.Id == SPEC.petId then
					discovered[def.Id] = true
				end
			end
		end
		feed({ Discovered = discovered })
		local onCards = T.tally("storm Index: every discovered card of every group shows its element pill (Element_<E>, Config.Elements.Info colour, >= 15 px)")
		local noneHidden = T.tally("storm Index: no undiscovered (???) card shows an element")
		local cards = 0
		for _, group in ipairs(PC.IndexGroups()) do
			Index.Open(group.Id)
			advance(1.2)
			for _, def in ipairs(group.Pets) do
				local tile = named(window(), "IndexPet_" .. def.Id)
				local element = PC.GetElements(def.Id)[1]
				if not tile then
					onCards:case(false, def.Id .. ": no IndexPet_ card in group " .. group.Id)
				elseif discovered[def.Id] then
					cards = cards + 1
					local p, problem = pillOf(tile, element or "?", Config)
					onCards:case(p ~= nil, def.Id .. " (" .. tostring(element) .. "): " .. tostring(problem))
				else
					hidden[#hidden + 1] = def.Id
					local leak = anyElementShown(tile, Config)
					noneHidden:case(leak == nil, def.Id .. ": " .. tostring(leak))
				end
			end
		end
		onCards:report(cards .. " cards")
		noneHidden:report(#hidden .. " cards")
		Index.Close()
		advance(0.5)
	end

	-- the odds list of every roulette: every pet wears its element pill
	local function oddsChecks(Config, PC)
		local badges = T.tally("storm odds: every pet of every roulette's odds list shows its element pill (Config.Elements.Info colour, >= 15 px)")
		local opened = 0
		for _, r in ipairs(Config.Roulettes) do
			toClient("OpenPanel", "Shop", { Tab = "Roulette", RouletteId = r.Id })
			advance(0.7)
			local shop = menuGui() and menuGui():FindFirstChild("Window_Shop")
			local card = shop and named(shop, "Roulette_" .. r.Id)
			local odds = card and named(card, "Odds")
			if not odds then
				badges:case(false, r.Id .. ": no Odds button on the roulette card")
			else
				Mock.Click(odds)
				advance(0.6)
				local popup = menuGui():FindFirstChild("OddsPopup")
				if not shown(popup) then
					badges:case(false, r.Id .. ": the Odds button opened no OddsPopup")
				else
					opened = opened + 1
					for _, o in ipairs(PC.GetOdds(r.Id)) do
						local cell = named(popup, "Cell_" .. o.PetId)
						local element = PC.GetElements(o.PetId)[1]
						local p, problem = pillOf(cell, element or "?", Config)
						badges:case(p ~= nil, r.Id .. "/" .. o.PetId .. " (" .. tostring(element) .. "): " .. tostring(problem))
					end
				end
			end
			closeAll(nil)
		end
		badges:report(opened .. " odds lists")
	end

	-- the Pets panel: the selected pet's element pill
	local function petsPanelChecks(Config, PC)
		-- Stormfang plus one pet of two other elements
		local owned = { [SPEC.petId] = 1 }
		local picks = { SPEC.petId }
		local seenElements = { [SPEC.element] = true }
		for _, def in ipairs(PC.Pets) do
			if #picks < 3 and not seenElements[def.Element] then
				seenElements[def.Element] = true
				owned[def.Id] = 1
				picks[#picks + 1] = def.Id
			end
		end
		local disc = {}
		for id in pairs(owned) do
			disc[id] = true
		end
		feed({ Pets = owned, Equipped = {}, Discovered = disc })
		local column = menuGui() and menuGui():FindFirstChild("MenuColumn")
		local entry = column and column:FindFirstChild("Entry_Pets")
		local button = entry and entry:FindFirstChildWhichIsA("TextButton", true)
		if not T.check(button ~= nil, "storm Pets panel: the menu has the Pets tile") then
			return
		end
		Mock.Click(button)
		advance(0.8)
		local inv = menuGui():FindFirstChild("Window_Inventory")
		if not T.check(shown(inv), "storm Pets panel: the Pets tile opens the Inventory window") then
			return
		end
		local panel = T.tally("storm Pets panel: selecting a pet shows its element pill in the detail card (Config.Elements.Info colour, >= 15 px)")
		for _, id in ipairs(picks) do
			local slot = named(inv, "Pet_" .. id)
			local pick = pickButton(slot)
			if not pick then
				panel:case(false, id .. ": no Pet_" .. id .. " slot")
			else
				Mock.Click(pick)
				advance(0.6)
				local detail = named(inv, "Detail")
				local element = PC.GetElements(id)[1]
				local p, problem = pillOf(detail, element or "?", Config)
				panel:case(p ~= nil and findText(PC.Get(id).Name:lower(), detail) ~= nil, id .. " (" .. tostring(element) .. "): " .. tostring(problem))
			end
		end
		panel:report(table.concat(picks, ", "))
		closeAll(nil)
	end

	-- ShowcaseController: hover / pulse, put back when the tag goes, clean up when the showcase is destroyed
	local function showcaseChecks(PC)
		local SC = controller("ShowcaseController")
		if not T.check(type(SC) == "table" and type(SC.Init) == "function", "storm showcase: client/Controllers/ShowcaseController.lua loads") then
			return
		end
		local PB = shared("PetBuilder")
		local def = PC.Get(SPEC.petId)
		local count = type(SC.Count) == "function" and SC.Count or function()
			return -1
		end
		local base0 = count()
		local okB, model = pcall(PB.Build, def, { Detail = "High", Scale = 3 })
		if not T.check(okB and typeof(model) == "Instance" and model.PrimaryPart ~= nil, "storm showcase: PetBuilder builds the Scale-3 Stormfang", tostring(model)) then
			return
		end
		-- the way StormAltar hands it over (anchored, tagged, attributes), placed away from everything else
		local home = CFrame.new(1200, 420, -1200)
		model.Name = "StormfangShowcase"
		model:PivotTo(home)
		local parts = 0
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				parts = parts + 1
			end
		end
		model:SetAttribute("PetId", SPEC.petId)
		model:SetAttribute("PetParts", parts)
		model:SetAttribute("HoverAmp", 0.45)
		model:SetAttribute("Ready", true)
		CollectionService:AddTag(model, SHOWCASE_TAG)
		local cam = workspace.CurrentCamera
		local savedCam = cam and cam.CFrame
		if cam then
			cam.CFrame = CFrame.lookAt(home.Position + Vector3.new(0, 10, 36), home.Position)
		end
		local root = model.PrimaryPart
		local base = root.CFrame
		-- the server pose of every part (to compare after the controller lets go)
		local rest = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				rest[d] = { cf = d.CFrame, t = d.Transparency }
			end
		end
		local neon = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.Material == Enum.Material.Neon then
				neon[#neon + 1] = { part = d, t = d.Transparency }
			end
		end
		model.Parent = workspace
		advance(1)
		T.check(count() == base0 + 1, "storm showcase: ShowcaseController picks up a model tagged NC_Showcase", "Count() " .. tostring(base0) .. " -> " .. tostring(count()))
		local instances = Mock.CountDescendants(model)
		local moved, worst, pulsed = 0, 0, false
		for _ = 1, 30 do
			advance(0.1)
			local p = root.CFrame
			moved = max(moved, (p.Position - base.Position).Magnitude, (p.LookVector - base.LookVector).Magnitude)
			worst = max(worst, (p.Position - base.Position).Magnitude)
			for _, n in ipairs(neon) do
				if abs(n.part.Transparency - n.t) > 0.02 then
					pulsed = true
				end
			end
		end
		T.check(moved > 0.02 and worst <= 0.45 + 0.6, "storm showcase: it hovers gently around the pose the server built", "moved " .. fmt(moved, 3) .. ", farthest " .. fmt(worst, 2) .. " studs")
		T.check(pulsed or #neon == 0, "storm showcase: its neon accents pulse")
		T.eq(Mock.CountDescendants(model), instances, "storm showcase: nothing is created per frame while it is animated")
		-- the tag goes, the model stays: animation stops and the model is put back the way the server built it
		CollectionService:RemoveTag(model, SHOWCASE_TAG)
		advance(0.3)
		local pos0 = root.Position
		advance(0.5)
		local unanchored, welds = 0, 0
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and not d.Anchored then
				unanchored = unanchored + 1
			elseif d.Name == "ShowcaseWeld" then
				welds = welds + 1
			end
		end
		-- every part back at its server pose and transparency (also the cloud halves / tail that PetBuilder.Animate
		-- re-poses and the accents it pulses)
		local offPose, offLook, offT, worstName = 0, 0, 0, ""
		for part, r in pairs(rest) do
			if part.Parent then
				local dp = (part.CFrame.Position - r.cf.Position).Magnitude
				local dl = (part.CFrame.LookVector - r.cf.LookVector).Magnitude
				local dt = abs(part.Transparency - r.t)
				if dp > offPose or dl > offLook or dt > offT then
					worstName = part.Name
				end
				offPose, offLook, offT = max(offPose, dp), max(offLook, dl), max(offT, dt)
			end
		end
		T.check(count() == base0 and (root.Position - pos0).Magnitude < 1e-6, "storm showcase: removing the tag stops the animation", "Count() " .. tostring(count()))
		T.check((root.Position - base.Position).Magnitude < 0.01 and unanchored == 0 and welds == 0, "storm showcase: ...and puts the model back where the server built it (anchored, no welds)",
			string.format("%.3f studs off, %d unanchored, %d welds", (root.Position - base.Position).Magnitude, unanchored, welds))
		T.check(offPose < 0.01 and offLook < 0.01 and offT < 1e-3, "storm showcase: ...every part included (the swaying cloud halves, the tail, the pulsing neon)",
			string.format("worst %s: %.3f studs, %.3f turn, transparency %.3f", worstName, offPose, offLook, offT))
		-- tagged again, then destroyed: cleaned up, no errors from the frame loop afterwards
		CollectionService:AddTag(model, SHOWCASE_TAG)
		advance(1)
		T.check(count() == base0 + 1, "storm showcase: tagged again, it animates again", "Count() " .. tostring(count()))
		local outputBefore, errorsBefore = #Mock.Output, #Mock.Errors
		model:Destroy()
		advance(1)
		T.check(count() == base0, "storm showcase: destroying the showcase stops its animation (ShowcaseController forgets it)", "Count() " .. tostring(count()))
		local frameWarn = nil
		for i = outputBefore + 1, #Mock.Output do
			local o = Mock.Output[i]
			if o.kind == "warn" and o.text:find("ShowcaseController", 1, true) then
				frameWarn = o.text
			end
		end
		T.check(frameWarn == nil and #Mock.Errors == errorsBefore, "storm showcase: ...without errors or warnings from the frame loop", tostring(frameWarn))
		if cam and savedCam then
			cam.CFrame = savedCam
		end
	end

	S.client_storm = guarded("client_storm", function()
		local Config = KC.env()
		local PC = shared("PetCatalog")
		local Index = controller("IndexController")
		local def = PC.Get(SPEC.petId)
		if not T.check(def ~= nil and type(PC.GetElements) == "function", "storm client: the catalog has Stormfang and the element helpers") then
			return
		end
		closeAll(Index)
		if T.check(type(Index) == "table" and type(Index.Open) == "function" and type(Index.Close) == "function", "storm client: IndexController loads with Open / Close") then
			indexChecks(Config, PC, Index)
		end
		closeAll(Index)
		oddsChecks(Config, PC)
		petsPanelChecks(Config, PC)
		closeAll(Index)

		-- the only asset id on screen is the player's art
		local foreign = foreignAssets(gui(), Config.Art.StormfangImage)
		T.check(#foreign == 0, "storm client: no asset id in the GUI but Config.Art.StormfangImage", table.concat(foreign, "; ", 1, min(#foreign, 4)))

		-- the altar toast is a side toast, never in the middle of the screen
		toClient("Notify", TOAST_TEXT, "info", 5)
		advance(0.8)
		local label = findText(TOAST_NEEDLE)
		if T.check(label ~= nil, "storm client: the Storm Altar toast is shown") then
			local vp = Mock.Viewport
			local cx = label.AbsolutePosition.X + label.AbsoluteSize.X / 2
			local centred = KC.centredTexts(CONTRACT.v2.centreTolerance)
			local inMiddle = false
			for _, c in ipairs(centred) do
				if c.text:lower():find(TOAST_NEEDLE, 1, true) then
					inMiddle = true
				end
			end
			T.check(not inMiddle and cx > vp.X * 0.6, "storm client: ...as a side toast on the right, never in the middle of the screen", string.format("centre x %.2f of the screen", cx / vp.X))
			T.check(textPx(label) >= 15, "storm client: ...in readable text (>= 15 px)", fmt(textPx(label), 1) .. " px")
		end
		advance(7)

		showcaseChecks(PC)
		-- leave the profile as the later scenarios expect it
		feed({ Pets = { cloudy_dragon = 2, pebble_pup = 1, biscuit_bear = 3 }, Equipped = { "cloudy_dragon", "biscuit_bear" } })
		KC.flushErrors("client_storm")
		KC.flushWarnings("client_storm")
	end)

	return S
end

if CONTEXT == "server" then
	return serverScenarios()
end
return clientScenarios()
