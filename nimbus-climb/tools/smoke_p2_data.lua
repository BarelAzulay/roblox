-- smoke_p2_data.lua: Phase 2 "Pet keys" + "Data" (ARCHITECTURE_V3.md "Phase 2 build contract"): shared/PetKeys.lua,
-- server/Services/DataService.lua (schema, migration, delta-save merge rules, ProfileSync additions, the new API),
-- the key-aware PetService and, on the client, State + PetController. Loaded by tools/smoke.py in BOTH worlds (like
-- smoke_storm.lua); ARGS.context picks the half:
--   p2data_keys      (server, content) PetKeys: canonical keys (Parse / Make round trips, junk refused),
--                    StatMultiplier 1 / 1.5 / 2.5, Count / Add / Remove (never below 0, MaxPerStack, unknown pets,
--                    hybrid records, empty entries cleaned), List order, DefOf (catalog def for Normal keys, a cached
--                    tier def with Look.Finish that leaves the catalog untouched, merged hybrid defs: Body species /
--                    colours / eyes from the first parent, Secondary / wings / accessory / element from the second,
--                    both elements, the higher rarity, stats and perks = average x1.2, blended names), PetBuilder
--                    builds tier and hybrid defs at High (<= 350 parts) and Low (<= 120) as their own cached looks
--   p2data_profile   (server, booted) a new profile's Phase 2 defaults, the Cash / Gems attributes and API (atomic
--                    spends, junk refused, whole units), Food, Home (GetHome copies, MutateHome edits / rollback on
--                    error or false / in-place sanitising / Rooms is Stations / CollectorCash fractions), pet levels
--                    (owned copies only), ProfileSync additions (plain data, slots encoded), equip / unequip by key
--                    (tier perks x1.5, the plain-petId fallback, hybrids with the EquippedHybrids attribute,
--                    PetService.Refresh after copies vanish), the roulette still grants Normal copies
--   p2data_save      (server, booted, DataStore) migration of the reserved Home.Rooms and of v2 / v3 profiles with tier
--                    keys equipped, Garden / Gym stored as arrays without holes, empty Phase 2 maps left out, Version 2,
--                    the merge rules against a concurrent server (Cash / Food / CollectorCash deltas, per-key
--                    Stations / Tiers / Hybrids / PetLevels, receipts union), the prestige rule both ways, bounded
--                    receipts (MarkReceipt idempotent), provisional profiles (no Home / XP / receipt decisions,
--                    CollectorCash still counts) and ResetFields({ Home = true }) over a higher stored prestige
--   (all, server)    the shared ProfileSync validator K.V.profileSync (smoke_server.lua, used by profile_sync and by
--                    final_checks over the whole run) predates pet keys: this file wraps it so its two plain-id rules
--                    follow the Phase 2 contract (an Equipped key is owned per PetKeys.Count against the snapshot's
--                    Pets / Tiers / Hybrids; Perks = sum of each copy's catalog perks x 1 / 1.5 / 2.5 by tier, hybrids
--                    their merged perks, capped). Every other rule of the validator is unchanged.
--   client_p2data    (client) State mirrors a Phase 2 snapshot (keys, tiers, hybrids, levels, food, home slots decoded,
--                    Cash / Gems from the attributes + signals), PetController draws tier keys and hybrids (only once
--                    their look arrived in EquippedHybrids; Low detail for other players)
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local CONTEXT = (ARGS and ARGS.context) or "server"

local abs = math.abs

local function near(a, b, eps)
	return type(a) == "number" and type(b) == "number" and abs(a - b) <= (eps or 1e-6)
end

local function countKeys(map)
	local n = 0
	for _ in pairs(type(map) == "table" and map or {}) do
		n = n + 1
	end
	return n
end

local function listText(list)
	local out = {}
	for i, v in ipairs(type(list) == "table" and list or {}) do
		out[i] = tostring(v)
	end
	return "{" .. table.concat(out, ",") .. "}"
end

local function partCount(model)
	local n = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			n = n + 1
		end
	end
	return n
end

----------------------------------------------------------------------------------------------------
-- server world
----------------------------------------------------------------------------------------------------
local function serverScenarios()
	local K = _G.K
	local S = {}
	local advance, config, mod = K.advance, K.config, K.mod

	local function requireShared(name)
		local inst = K.moduleInstance("shared/" .. name)
		if not inst then
			return nil
		end
		local ok, result = pcall(require, inst)
		if ok and type(result) == "table" then
			return result
		end
		return nil
	end

	local function storeKey(userId)
		return config().Tokens.DataStoreName .. "/u_" .. userId
	end

	local function stored(userId)
		return Mock.DataStore.Data[storeKey(userId)]
	end

	local function statsOf()
		return { Matches = 0, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = {} }
	end

	local function lastSnapshot(player, fromIndex)
		local list = K.remotesFor("ProfileSync", player.UserId, fromIndex or 0)
		local e = list[#list]
		return e and e.args[1] or nil
	end

	local function join(name, userId)
		local p = Mock.AddPlayer(name, userId)
		advance(1.0)
		return p
	end

	-- runs fn() while PetCatalog.RollPet always answers `petId`
	local function withRoll(petId, fn)
		local PC = K.M["shared/PetCatalog"]
		local original = PC.RollPet
		PC.RollPet = function()
			return petId
		end
		local ok, err = pcall(fn)
		PC.RollPet = original
		if not ok then
			error(err, 0)
		end
	end

	------------------------------------------------------------------------------------------------
	-- the whole-run ProfileSync validator, made key-aware (see the header)
	------------------------------------------------------------------------------------------------
	local TIER_MULT = { Normal = 1, Golden = 1.5, Rainbow = 2.5 } -- the contract's numbers, not PetKeys'

	-- perks of a list of keys computed independently of DataService: catalog perks x the tier multiplier
	local function keyPerks(PK, PC, equipped, snapshot)
		local Config = config()
		local sums = { MaxHealth = 0, TokenBonus = 0, StaminaRegen = 0, CheckpointHeal = 0 }
		for _, key in ipairs(equipped) do
			local parsed = PK.Parse(key)
			local perks = nil
			if parsed and parsed.HybridId then
				local def = PK.DefOf(key, snapshot)
				perks = def and def.Perks
			elseif parsed then
				local def = PC.Get(parsed.PetId)
				perks = def and def.Perks
			end
			local mult = parsed and TIER_MULT[parsed.Tier] or 1
			for perk, value in pairs(type(perks) == "table" and perks or {}) do
				if sums[perk] ~= nil and type(value) == "number" then
					sums[perk] = sums[perk] + value * mult
				end
			end
		end
		for perk, total in pairs(sums) do
			local cap = Config.Pets.PerkCaps[perk]
			if type(cap) == "number" and total > cap then
				total = cap
			end
			sums[perk] = math.floor(total * 10000 + 0.5) / 10000
		end
		return sums
	end

	if type(K.V) == "table" and type(K.V.profileSync) == "function" and not K.V.P2KeysAware then
		local original = K.V.profileSync
		K.V.P2KeysAware = true
		K.V.profileSync = function(snap)
			local problems = original(snap)
			local PK = requireShared("PetKeys")
			local PC = K.M["shared/PetCatalog"]
			if not PK or not PC or type(snap) ~= "table" or type(snap.Equipped) ~= "table" then
				return problems
			end
			local out = {}
			for _, msg in ipairs(problems) do
				local text = tostring(msg)
				if not (text:find("is not owned that often", 1, true) or text:find("but the equipped pets sum to", 1, true)) then
					out[#out + 1] = msg
				end
			end
			local used = {}
			for i, key in ipairs(snap.Equipped) do
				used[key] = (used[key] or 0) + 1
				if type(key) ~= "string" or used[key] > PK.Count(snap, key) then
					out[#out + 1] = "Equipped[" .. i .. "] = " .. tostring(key) .. " is not owned that often (pet keys: Pets / Tiers / Hybrids)"
				end
			end
			if type(snap.Perks) == "table" then
				local want = keyPerks(PK, PC, snap.Equipped, snap)
				for perk, value in pairs(want) do
					if type(snap.Perks[perk]) == "number" and abs(snap.Perks[perk] - value) > 1e-6 then
						out[#out + 1] = "Perks." .. perk .. " = " .. snap.Perks[perk] .. " but the equipped copies (key perks x tier) sum to " .. value
					end
				end
			end
			return out
		end
	end

	------------------------------------------------------------------------------------------------
	-- scenario: PetKeys (pure)
	------------------------------------------------------------------------------------------------
	S.p2data_keys = guarded("p2data_keys", function()
		local PK = requireShared("PetKeys")
		local PC = K.M["shared/PetCatalog"] or requireShared("PetCatalog")
		local PB = K.M["shared/PetBuilder"] or requireShared("PetBuilder")
		if not T.check(PK ~= nil and PC ~= nil, "p2 keys: shared/PetKeys.lua loads (with PetCatalog)") then
			return
		end
		for _, fn in ipairs({ "Parse", "Make", "Count", "Add", "Remove", "List", "DefOf", "StatMultiplier" }) do
			T.check(type(PK[fn]) == "function", "p2 keys: PetKeys." .. fn .. " is a function")
		end
		local Config = config()

		-- Parse / Make
		local p = PK.Parse("pebble_pup")
		T.check(p and p.PetId == "pebble_pup" and p.Tier == "Normal" and p.HybridId == nil, "p2 keys: Parse('pebble_pup') -> Normal copy of pebble_pup")
		p = PK.Parse("pebble_pup@Golden")
		T.check(p and p.PetId == "pebble_pup" and p.Tier == "Golden", "p2 keys: Parse('pebble_pup@Golden') -> Golden")
		p = PK.Parse("pebble_pup@Rainbow")
		T.check(p and p.Tier == "Rainbow", "p2 keys: ...'@Rainbow' -> Rainbow")
		p = PK.Parse("hyb:h1")
		T.check(p and p.HybridId == "h1" and p.PetId == nil and p.Tier == "Normal", "p2 keys: Parse('hyb:h1') -> a hybrid (no PetId)")
		p = PK.Parse("hyb:h1@Rainbow")
		T.check(p and p.HybridId == "h1" and p.Tier == "Rainbow", "p2 keys: ...a hybrid can carry a tier")
		local junk = { "pebble_pup@Normal", "pebble_pup@Shiny", "", "a,b", "a b", "hyb:", "hyb:a b", "@Golden", "hyb:x@Normal",
			string.rep("a", 60), "hyb:" .. string.rep("x", 30), "cat@Golden@Rainbow" }
		local bad = {}
		for _, k in ipairs(junk) do
			if PK.Parse(k) ~= nil then
				bad[#bad + 1] = k
			end
		end
		T.check(#bad == 0 and PK.Parse(nil) == nil and PK.Parse(5) == nil and PK.Parse({}) == nil,
			"p2 keys: non-canonical keys and junk parse to nil", table.concat(bad, " | "))
		T.check(PK.Make("pebble_pup") == "pebble_pup" and PK.Make("pebble_pup", "Normal") == "pebble_pup" and PK.Make("pebble_pup", "Golden") == "pebble_pup@Golden",
			"p2 keys: Make(petId[, tier]) -> 'petId' / 'petId@Golden'")
		T.check(PK.Make("pebble_pup@Golden", "Rainbow") == "pebble_pup@Rainbow" and PK.Make("hyb:h1", "Golden") == "hyb:h1@Golden" and PK.Make("hyb:h1@Golden") == "hyb:h1",
			"p2 keys: Make replaces the tier of a key and works for hybrids")
		T.check(PK.Make("pebble_pup", "Shiny") == nil and PK.Make("a b") == nil and PK.Make(nil) == nil, "p2 keys: Make refuses junk")
		local trips = T.tally("p2 keys: Parse(Make(petId, tier)) round-trips for every catalog pet and tier")
		for _, def in ipairs(PC.Pets) do
			for _, tier in ipairs({ "Normal", "Golden", "Rainbow" }) do
				local key = PK.Make(def.Id, tier)
				local back = key and PK.Parse(key)
				trips:case(back ~= nil and back.PetId == def.Id and back.Tier == tier, def.Id .. "/" .. tier .. " -> " .. tostring(key))
			end
		end
		trips:report()

		-- StatMultiplier
		T.check(PK.StatMultiplier(nil) == 1 and PK.StatMultiplier("Normal") == 1 and PK.StatMultiplier("Golden") == 1.5 and PK.StatMultiplier("Rainbow") == 2.5,
			"p2 keys: StatMultiplier Normal 1, Golden 1.5, Rainbow 2.5")
		T.check(PK.StatMultiplier("pebble_pup@Rainbow") == 2.5 and PK.StatMultiplier("junk tier") == 1, "p2 keys: ...also from a key; junk counts as x1")

		-- Count / Add / Remove
		local max = Config.Pets.MaxPerStack
		local prof = { Pets = {}, Tiers = {}, Hybrids = {} }
		T.check(PK.Add(prof, "pebble_pup", 2) == true and prof.Pets.pebble_pup == 2 and PK.Count(prof, "pebble_pup") == 2, "p2 keys: Add a Normal key -> Pets[petId]")
		T.check(PK.Add(prof, "pebble_pup@Golden") == true and prof.Tiers.pebble_pup and prof.Tiers.pebble_pup.Golden == 1 and PK.Count(prof, "pebble_pup@Golden") == 1,
			"p2 keys: Add a tier key -> Tiers[petId].Golden (n defaults to 1)")
		T.check(PK.Count(prof, "pebble_pup@Rainbow") == 0 and PK.Count(prof, "cloudy_dragon") == 0 and PK.Count(nil, "pebble_pup") == 0 and PK.Count(prof, "a b") == 0,
			"p2 keys: Count is 0 for keys not owned and for junk")
		T.check(PK.Add(prof, "ghost_pet") == false and PK.Add(prof, "pebble_pup", 0) == false and PK.Add(prof, "pebble_pup", 1.5) == false
			and PK.Add(prof, "pebble_pup@Normal") == false and PK.Add(prof, "pebble_pup", -1) == false and prof.Pets.ghost_pet == nil and prof.Pets.pebble_pup == 2,
			"p2 keys: Add refuses unknown pets, bad amounts and junk keys (nothing changes)")
		T.check(PK.Add(prof, "pebble_pup", max) == false and prof.Pets.pebble_pup == 2, "p2 keys: Add refuses to go past Config.Pets.MaxPerStack")
		T.check(PK.Remove(prof, "pebble_pup", 3) == false and prof.Pets.pebble_pup == 2, "p2 keys: Remove never goes below 0 (false, unchanged)")
		T.check(PK.Remove(prof, "pebble_pup", 2) == true and prof.Pets.pebble_pup == nil, "p2 keys: Remove the last copies clears the entry")
		T.check(PK.Remove(prof, "pebble_pup@Golden") == true and prof.Tiers.pebble_pup == nil, "p2 keys: removing the last tier copy cleans the empty Tiers entry")
		T.check(PK.Remove(prof, "pebble_pup") == false and PK.Remove(prof, "junk key") == false, "p2 keys: Remove of keys not owned is false")
		local rec = { Body = "pip_penguin", Style = "ember_phoenix" }
		T.check(PK.Add(prof, "hyb:h1", 1, rec) == true and type(prof.Hybrids.h1) == "table" and prof.Hybrids.h1.Tier == "Normal" and prof.Hybrids.h1.Body == "pip_penguin",
			"p2 keys: Add a hybrid key with its record -> Hybrids[uid] (Tier from the key)")
		T.check(PK.Count(prof, "hyb:h1") == 1 and PK.Count(prof, "hyb:h1@Golden") == 0, "p2 keys: a hybrid counts 1 for the key of its own tier only")
		T.check(PK.Add(prof, "hyb:h1", 1, rec) == false and PK.Add(prof, "hyb:h2", 1) == false and PK.Add(prof, "hyb:h2", 2, rec) == false
			and PK.Add(prof, "hyb:h2", 1, { Body = "a b", Style = "x" }) == false,
			"p2 keys: a hybrid uid is unique; Add needs a valid record and n = 1")
		T.check(PK.Add(prof, "hyb:h3@Golden", 1, rec) == true and prof.Hybrids.h3.Tier == "Golden" and PK.Count(prof, "hyb:h3@Golden") == 1 and PK.Count(prof, "hyb:h3") == 0,
			"p2 keys: a Golden hybrid key stores Tier = 'Golden'")
		T.check(PK.Remove(prof, "hyb:h3") == false and PK.Remove(prof, "hyb:h3@Golden") == true and prof.Hybrids.h3 == nil, "p2 keys: removing a hybrid needs its exact key and deletes the record")
		local newId = type(PK.NewHybridId) == "function" and PK.NewHybridId(prof, 12345)
		T.check(type(newId) == "string" and prof.Hybrids[newId] == nil and PK.Parse("hyb:" .. newId) ~= nil, "p2 keys: NewHybridId gives a free, valid uid", tostring(newId))

		-- List
		local lp = {
			Pets = { cloudy_dragon = 1, pebble_pup = 2, ghost_pet = 1, zero = 0 },
			Tiers = { pebble_pup = { Golden = 1, Rainbow = 2 }, mallow_kitten = { Golden = 0 } },
			Hybrids = { h1 = { Body = "pip_penguin", Style = "ember_phoenix" }, bad = { Body = "nope", Style = "nope2" } },
		}
		local list = PK.List(lp)
		local want = { "pebble_pup", "pebble_pup@Golden", "pebble_pup@Rainbow", "cloudy_dragon", "hyb:h1" }
		local same = #list == #want
		for i = 1, #want do
			same = same and list[i] == want[i]
		end
		T.check(same, "p2 keys: List = owned keys in catalog order (Normal, Golden, Rainbow), hybrids last; unknown pets / dead hybrids skipped", listText(list))

		-- DefOf: Normal + tiers
		local base = PC.Get("pebble_pup")
		T.check(PK.DefOf("pebble_pup") == base, "p2 keys: DefOf(petId) is the catalog def itself")
		local gold = PK.DefOf("pebble_pup@Golden")
		T.check(gold ~= nil and gold.Id == "pebble_pup@Golden" and gold.PetId == "pebble_pup" and gold.Tier == "Golden" and gold.StatMultiplier == 1.5,
			"p2 keys: a tier def: Id = the key, PetId, Tier, StatMultiplier")
		T.check(gold and type(gold.Look) == "table" and gold.Look.Finish == "Golden" and gold.Look.Species == base.Look.Species and gold.Look.Primary == base.Look.Primary
			and gold.Name == base.Name and gold.DisplayName == "Golden " .. base.Name and gold.Rarity == base.Rarity,
			"p2 keys: ...its Look is the catalog look + Finish = 'Golden' (DisplayName 'Golden Pebble Pup')")
		T.check(base.Look.Finish == nil and base.Id == "pebble_pup", "p2 keys: ...and the catalog def stays untouched")
		T.check(PK.DefOf("pebble_pup@Golden") == gold, "p2 keys: tier defs are cached (same table)")
		T.check(PK.DefOf("pebble_pup@Rainbow").Look.Finish == "Rainbow", "p2 keys: Rainbow -> Look.Finish = 'Rainbow'")
		T.check(PK.DefOf("ghost_pet") == nil and PK.DefOf("ghost_pet@Golden") == nil and PK.DefOf("junk key") == nil, "p2 keys: DefOf is nil for unknown pets and junk")

		-- DefOf: hybrids
		local A, B = PC.Get("pip_penguin"), PC.Get("ember_phoenix")
		T.check(PK.DefOf("hyb:h1") == nil, "p2 keys: a hybrid needs the profile's record (nil without it)")
		local hyb = PK.DefOf("hyb:h1", lp)
		if T.check(hyb ~= nil and A ~= nil and B ~= nil, "p2 keys: DefOf(hybrid key, profile) -> a merged def") then
			local L, LA, LB = hyb.Look, A.Look, B.Look
			T.check(L.Species == LA.Species and L.Primary == LA.Primary and L.Eye == LA.Eye, "p2 keys: hybrid look: species, body colour and eyes of the FIRST parent")
			T.check(L.Secondary == LB.Secondary and L.WingStyle == LB.WingStyle and L.WingColor == LB.WingColor and L.Accessory == (LB.Accessory or LA.Accessory),
				"p2 keys: ...Secondary, wings and accessory of the SECOND parent")
			T.check(hyb.Id == "hyb:h1" and hyb.IsHybrid == true and hyb.HybridId == "h1" and hyb.Body == A.Id and hyb.Style == B.Id and hyb.PetId == nil,
				"p2 keys: ...Id = key, IsHybrid, HybridId, Body / Style parents, no PetId")
			T.check(type(hyb.Elements) == "table" and hyb.Elements[1] == A.Element and hyb.Elements[2] == B.Element and hyb.Element == A.Element,
				"p2 keys: ...Elements = both parents' (deduplicated)", listText(hyb.Elements))
			if type(PC.ElementsOf) == "function" then
				T.eq(#PC.ElementsOf(hyb), 2, "p2 keys: ...PetCatalog.ElementsOf reads both")
			end
			T.eq(hyb.Rarity, "Legendary", "p2 keys: ...rarity = the higher of the two")
			local okStats = true
			for _, k in ipairs({ "Income", "Power", "Health", "Speed" }) do
				okStats = okStats and near(hyb.Stats[k], (A.Stats[k] + B.Stats[k]) / 2 * 1.2, 1e-9)
			end
			T.check(okStats, "p2 keys: ...stats = the parents' average x1.2")
			local wantRole = (hyb.Stats.Income > hyb.Stats.Power) and "Economy" or "Combat"
			T.eq(hyb.Role, wantRole, "p2 keys: ...Role follows the merged stats")
			T.eq(hyb.Name, "Pengnix", "p2 keys: ...name blended from both ('Pip Penguin' + 'Ember Phoenix' -> 'Pengnix')")
			T.check(type(hyb.Special) == "table" and hyb.Special.Id == A.Special.Id and type(hyb.Perks) == "table", "p2 keys: ...the special of the body parent, merged perks")
			T.check(A.Look.Finish == nil and hyb.Look.Finish == nil, "p2 keys: ...a Normal hybrid has no finish")
		end
		local named = PK.DefOf("hyb:n1@Golden", { Hybrids = { n1 = { Body = "pip_penguin", Style = "ember_phoenix", Name = "Sparky", Rarity = "Mythic", Elements = { "Storm" }, Tier = "Golden" } } })
		T.check(named and named.Name == "Sparky" and named.Rarity == "Mythic" and named.Elements[1] == "Storm" and #named.Elements == 1 and named.Look.Finish == "Golden",
			"p2 keys: the record's Name / Rarity / Elements win; a Golden hybrid gets Look.Finish")
		if type(PK.BlendName) == "function" then
			T.check(PK.BlendName("Cloudy Dragon", "Twilight Dragon") == "Clogon" and PK.BlendName("Biscuit Bear", "Aurora Fox") == "Befox",
				"p2 keys: BlendName handles equal last words and short words", PK.BlendName("Cloudy Dragon", "Twilight Dragon") .. " / " .. PK.BlendName("Biscuit Bear", "Aurora Fox"))
		end

		-- PetBuilder builds tier and hybrid defs (their own cached looks)
		if PB and type(PB.Build) == "function" then
			local okH, mh = pcall(PB.Build, hyb, { Detail = "High" })
			local okL, ml = pcall(PB.Build, hyb, { Detail = "Low" })
			T.check(okH and typeof(mh) == "Instance" and mh.PrimaryPart ~= nil and mh:FindFirstChild("WingL", true) ~= nil and partCount(mh) <= 350,
				"p2 keys: PetBuilder builds a hybrid def at High (<= 350 parts, PrimaryPart, wings)", okH and tostring(partCount(mh)) or tostring(mh))
			T.check(okL and typeof(ml) == "Instance" and partCount(ml) <= 120, "p2 keys: ...and at Low (<= 120 parts)", okL and tostring(partCount(ml)) or tostring(ml))
			local okG, mg = pcall(PB.Build, gold, { Detail = "High" })
			local okN, mn = pcall(PB.Build, base, { Detail = "High" })
			T.check(okG and okN and mg:GetAttribute("PetId") == "pebble_pup@Golden" and mn:GetAttribute("PetId") == "pebble_pup",
				"p2 keys: a tier def builds as its own look (PetBuilder caches it apart from the Normal pet)",
				okG and tostring(mg:GetAttribute("PetId")) or tostring(mg))
			for _, m in ipairs({ mh, ml, mg, mn }) do
				if typeof(m) == "Instance" then
					m:Destroy()
				end
			end
		end
		K.flushErrors("p2data_keys")
		K.flushWarnings("p2data_keys")
	end)

	------------------------------------------------------------------------------------------------
	-- scenario: the Phase 2 profile API + key-aware PetService
	------------------------------------------------------------------------------------------------
	S.p2data_profile = guarded("p2data_profile", function()
		if not K.needBoot() then
			return
		end
		local Config = config()
		local DataS, PS = mod("DataService"), mod("PetService")
		local PK = requireShared("PetKeys")
		local PC = K.M["shared/PetCatalog"]
		for _, fn in ipairs({ "GetHome", "MutateHome", "AddCash", "SpendCash", "GetCash", "AddGems", "SpendGems", "GetGems", "AddFood", "SpendFood", "GetFood", "GetPetLevel", "AddPetXp" }) do
			T.check(type(DataS[fn]) == "function", "p2 data: DataService." .. fn .. " is a function")
		end
		local mark = K.logSize()
		local p = join("P2Profile", 951001)
		local prof = DataS.GetProfile(p)
		if not T.check(prof ~= nil, "p2 data: (precondition) the profile loads") then
			return
		end
		local h = prof.Home
		T.check(prof.Cash == 0 and prof.Gems == 0 and type(h) == "table" and h.Level == 0 and h.Prestige == 0 and type(h.Stations) == "table" and type(h.Garden) == "table"
			and type(h.Gym) == "table" and h.CollectorCash == 0 and type(prof.Food) == "table" and type(prof.Tiers) == "table" and type(prof.Hybrids) == "table"
			and type(prof.PetLevels) == "table" and type(prof.GemReceipts) == "table" and type(prof.Teams) == "table",
			"p2 data: a new profile has the Phase 2 defaults (Cash, Gems, Home {Level, Prestige, Stations, Garden, Gym, CollectorCash}, Food, Tiers, Hybrids, PetLevels, GemReceipts, Teams)")
		T.check(h.Rooms == h.Stations, "p2 data: Home.Rooms (the v3 reserve) is the same table as Home.Stations")
		T.check(p:GetAttribute(Config.Attr.Cash) == 0 and p:GetAttribute(Config.Attr.Gems) == 0, "p2 data: the Cash / Gems attributes mirror the balances from the join on")
		local snap = lastSnapshot(p, mark)
		T.check(snap ~= nil and snap.Cash == 0 and snap.Gems == 0 and type(snap.Home) == "table" and type(snap.Home.Stations) == "table" and type(snap.Home.Garden) == "table"
			and type(snap.Food) == "table" and type(snap.Tiers) == "table" and type(snap.Hybrids) == "table" and type(snap.PetLevels) == "table",
			"p2 data: ProfileSync carries Cash, Gems, Home, Food, Tiers, Hybrids, PetLevels")
		T.check(snap ~= nil and snap.GemReceipts == nil and snap.Home.LastSeen == nil and snap.Teams == nil, "p2 data: ...but not the server-only receipts / LastSeen (small payloads)")

		-- Cash
		T.check(DataS.AddCash(p, 250) == true and DataS.GetCash(p) == 250 and p:GetAttribute(Config.Attr.Cash) == 250, "p2 data: AddCash -> GetCash and the Cash attribute")
		DataS.AddCash(p, 0.5)
		T.check(DataS.GetCash(p) == 250 and p:GetAttribute(Config.Attr.Cash) == 250, "p2 data: fractions of cash stay in the live balance (GetCash / attribute show whole units)")
		DataS.AddCash(p, 0.5)
		T.eq(DataS.GetCash(p), 251, "p2 data: ...and add up")
		T.check(DataS.AddCash(p, -5) == false and DataS.AddCash(p, 0 / 0) == false and DataS.AddCash(p, math.huge) == false and DataS.AddCash(p, "9") == false and DataS.GetCash(p) == 251,
			"p2 data: AddCash refuses negative / NaN / inf / non-numbers")
		T.check(DataS.SpendCash(p, 300) == false and DataS.GetCash(p) == 251, "p2 data: SpendCash refuses more than the balance (nothing taken)")
		T.check(DataS.SpendCash(p, 100) == true and DataS.GetCash(p) == 151 and p:GetAttribute(Config.Attr.Cash) == 151, "p2 data: SpendCash takes it (attribute follows)")
		T.check(DataS.SpendCash(p, -1) == false and DataS.SpendCash(p, 0) == true and DataS.GetCash(p) == 151, "p2 data: SpendCash(-1) is refused, SpendCash(0) is a free success")
		-- Gems
		T.check(DataS.AddGems(p, 40) == true and DataS.GetGems(p) == 40 and p:GetAttribute(Config.Attr.Gems) == 40, "p2 data: AddGems -> GetGems and the Gems attribute")
		T.check(DataS.SpendGems(p, 50) == false and DataS.SpendGems(p, 15) == true and DataS.GetGems(p) == 25 and p:GetAttribute(Config.Attr.Gems) == 25,
			"p2 data: SpendGems refuses more than the balance and takes what it can pay")

		-- Food
		T.check(DataS.AddFood(p, "Snack", 3) == true and DataS.GetFood(p, "Snack") == 3, "p2 data: AddFood / GetFood")
		T.check(DataS.SpendFood(p, "Snack", 5) == false and DataS.GetFood(p, "Snack") == 3, "p2 data: SpendFood refuses more than owned")
		T.check(DataS.SpendFood(p, "Snack", 2) == true and DataS.GetFood(p, "Snack") == 1, "p2 data: SpendFood takes it")
		T.check(DataS.AddFood(p, "", 1) == false and DataS.AddFood(p, "Meal", -1) == false and DataS.AddFood(p, 5, 1) == false and DataS.GetFood(p, "Meal") == 0,
			"p2 data: AddFood refuses junk ids and amounts")
		local foodMap = DataS.GetFood(p)
		T.check(type(foodMap) == "table" and foodMap.Snack == 1 and foodMap ~= prof.Food, "p2 data: GetFood(player) -> a copy of the whole map")
		advance(0.4)
		snap = lastSnapshot(p, 0)
		T.check(snap and snap.Food and snap.Food.Snack == 1, "p2 data: Food changes reach the client (throttled ProfileSync)")

		-- Home
		local copy = DataS.GetHome(p)
		T.check(type(copy) == "table" and copy ~= prof.Home and copy.Stations ~= prof.Home.Stations, "p2 data: GetHome -> a copy (not the live table)")
		copy.Level = 99
		T.eq(prof.Home.Level, 0, "p2 data: ...editing the copy changes nothing")
		local ok = DataS.MutateHome(p, function(home)
			home.Stations.Press1 = 1
			home.Garden[1] = "pebble_pup"
			home.Level = 1
		end)
		local home = DataS.GetHome(p)
		T.check(ok == true and home.Stations.Press1 == 1 and home.Garden[1] == "pebble_pup" and home.Level == 1, "p2 data: MutateHome edits the live Home (Stations, Garden, Level)")
		T.check(prof.Home.Rooms == prof.Home.Stations and prof.Home.Rooms.Press1 == 1, "p2 data: ...Rooms still is Stations")
		advance(0.4)
		snap = lastSnapshot(p, 0)
		T.check(snap and snap.Home and snap.Home.Stations.Press1 == 1 and snap.Home.Garden[1] == "pebble_pup" and snap.Home.Level == 1,
			"p2 data: a visible Home change is synced to the client")
		local okErr = DataS.MutateHome(p, function(home2)
			home2.Stations.Press1 = 5
			home2.Level = 9
			error("boom")
		end)
		home = DataS.GetHome(p)
		T.check(okErr == false and home.Stations.Press1 == 1 and home.Level == 1, "p2 data: a MutateHome callback that errors is rolled back (false)")
		local okFalse = DataS.MutateHome(p, function(home2)
			home2.Stations.Kitchen = 3
			return false
		end)
		T.check(okFalse == false and DataS.GetHome(p).Stations.Kitchen == nil, "p2 data: ...so is one that returns false")
		DataS.MutateHome(p, function(home2)
			home2.Stations.Junk = -5
			home2.Stations.Kitchen = 2.7
			home2.Garden[2] = 5
			home2.Garden[70] = "pebble_pup"
			home2.Gym.Ring = "cloudy_dragon"
		end)
		home = DataS.GetHome(p)
		T.check(home.Stations.Junk == nil and home.Stations.Kitchen == 2 and home.Garden[2] == nil and home.Garden[70] == nil and home.Gym.Ring == "cloudy_dragon",
			"p2 data: MutateHome sanitises the Home in place (bad levels / slots dropped, levels whole; named slots kept)")
		DataS.MutateHome(p, function(home2)
			home2.CollectorCash = home2.CollectorCash + 0.5
		end)
		DataS.MutateHome(p, function(home2)
			home2.CollectorCash = home2.CollectorCash + 0.75
		end)
		T.check(near(DataS.GetHome(p).CollectorCash, 1.25), "p2 data: CollectorCash keeps fractions between ticks (per-second income)", tostring(DataS.GetHome(p).CollectorCash))
		T.check(DataS.MutateHome(p, nil) == false and DataS.MutateHome(nil, function() end) == false, "p2 data: MutateHome refuses junk")

		-- pet levels
		local lv, xp = DataS.GetPetLevel(p, "pebble_pup")
		T.check(lv == 1 and xp == 0, "p2 data: GetPetLevel of a pet without XP -> 1, 0")
		T.eq(DataS.AddPetXp(p, "pebble_pup", 100), 0, "p2 data: AddPetXp refuses copies the player does not own")
		prof.Pets.pebble_pup = 1
		T.eq(DataS.AddPetXp(p, "pebble_pup", 1), 0, "p2 data: a little XP gains no level")
		lv, xp = DataS.GetPetLevel(p, "pebble_pup")
		T.check(lv == 1 and xp == 1, "p2 data: ...but is kept", lv .. "/" .. xp)
		local gained = DataS.AddPetXp(p, "pebble_pup", 100000)
		lv, xp = DataS.GetPetLevel(p, "pebble_pup")
		T.check(gained >= 1 and lv == 1 + gained and xp >= 0, "p2 data: lots of XP -> levels gained (level = 1 + gained)", "gained " .. gained .. ", level " .. lv)
		local TC = requireShared("TycoonCatalog")
		local cap = TC and (TC.MaxPetLevel or (type(TC.PetXp) == "table" and TC.PetXp.MaxLevel)) or 100
		DataS.AddPetXp(p, "pebble_pup", 1000000000)
		lv, xp = DataS.GetPetLevel(p, "pebble_pup")
		T.check(lv == cap and xp == 0, "p2 data: levels stop at the curve's max level (TycoonCatalog.MaxPetLevel; XP stops there)", lv .. "/" .. xp .. " cap " .. tostring(cap))
		T.eq(DataS.AddPetXp(p, "pebble_pup", 500), 0, "p2 data: ...no level past it")
		T.check(DataS.AddPetXp(p, "pebble_pup", -5) == 0 and DataS.AddPetXp(p, "pebble_pup", 0 / 0) == 0 and DataS.AddPetXp(p, "junk key", 5) == 0, "p2 data: AddPetXp refuses junk")
		advance(0.4)
		snap = lastSnapshot(p, 0)
		T.check(snap and snap.PetLevels and snap.PetLevels.pebble_pup and snap.PetLevels.pebble_pup.Level == lv, "p2 data: pet levels reach the client")

		-- equip by key
		while #prof.Equipped > 0 do
			table.remove(prof.Equipped)
		end
		PS.Refresh(p)
		prof.Pets.pebble_pup = nil
		prof.Tiers.pebble_pup = { Golden = 1 }
		advance(0.3)
		local okGold = PS.Equip(p, "pebble_pup@Golden")
		T.check(okGold == true and prof.Equipped[1] == "pebble_pup@Golden" and p:GetAttribute(Config.Attr.EquippedPets) == "pebble_pup@Golden",
			"p2 data: Equip by tier key (EquippedPets lists the key)")
		advance(0.3)
		T.eq(select(1, PS.Equip(p, "pebble_pup@Golden")), false, "p2 data: ...not more often than owned")
		local basePerk = PC.Get("pebble_pup").Perks.TokenBonus or 0
		T.check(near(PS.GetPerks(p).TokenBonus, math.floor(basePerk * 1.5 * 10000 + 0.5) / 10000) and near(PS.GetTokenMultiplier(p), 1 + math.floor(basePerk * 1.5 * 10000 + 0.5) / 10000),
			"p2 data: a Golden copy gives x1.5 perks (and token multiplier)", tostring(PS.GetPerks(p).TokenBonus))
		advance(0.3)
		local okRb, whyRb = PS.Equip(p, "pebble_pup@Rainbow")
		T.check(okRb == false and type(whyRb) == "string", "p2 data: equipping a tier the player does not own fails with a reason", tostring(whyRb))
		advance(0.3)
		T.check(PS.Unequip(p, "pebble_pup") == true and #prof.Equipped == 0, "p2 data: Unequip(petId) (old callers) also takes off a tier copy of that pet")
		-- hybrids
		advance(0.3)
		T.check(PK.Add(prof, "hyb:t1", 1, { Body = "pip_penguin", Style = "ember_phoenix", Rarity = "Legendary" }) == true, "p2 data: (setup) a hybrid record")
		local okHyb = PS.Equip(p, "hyb:t1")
		local looks = p:GetAttribute("EquippedHybrids")
		T.check(okHyb == true and p:GetAttribute(Config.Attr.EquippedPets) == "hyb:t1", "p2 data: Equip a hybrid key")
		T.check(type(looks) == "string" and looks:find("t1=pip_penguin/ember_phoenix/Normal/Legendary", 1, true) ~= nil,
			"p2 data: ...its look is published in the EquippedHybrids attribute for other clients", tostring(looks))
		local hdef = PK.DefOf("hyb:t1", prof)
		local wantPerks = DataS.ComputePerks({ "hyb:t1" }, prof)
		T.check(hdef ~= nil and near(PS.GetPerks(p).MaxHealth, wantPerks.MaxHealth) and near(PS.GetPerks(p).TokenBonus, wantPerks.TokenBonus),
			"p2 data: ...and its merged perks count")
		PK.Remove(prof, "hyb:t1")
		local changed = PS.Refresh(p)
		T.check(changed == true and #prof.Equipped == 0 and p:GetAttribute(Config.Attr.EquippedPets) == "" and p:GetAttribute("EquippedHybrids") == "",
			"p2 data: PetService.Refresh unequips copies that vanished (fused away) and clears the attributes")
		-- the roulette still grants Normal copies
		prof.Pets.pebble_pup = 1
		DataS.AddTokens(p, Config.Roulettes[1].Price)
		advance(0.3)
		local okRoll, result
		withRoll("pebble_pup", function()
			okRoll, result = PS.BuyRoulette(p, Config.Roulettes[1].Id)
		end)
		T.check(okRoll == true and prof.Pets.pebble_pup == 2 and prof.Tiers.pebble_pup.Golden == 1 and result.Key == "pebble_pup" and result.IsNew == false,
			"p2 data: a roulette roll adds a Normal copy (Tiers untouched; IsNew false: the pet was owned as Golden)")
		-- snapshot shape with tier copies
		advance(0.4)
		snap = lastSnapshot(p, 0)
		T.check(snap and snap.Tiers.pebble_pup and snap.Tiers.pebble_pup.Golden == 1 and snap.Discovered.pebble_pup == true, "p2 data: the snapshot lists tier copies (and their pet as discovered)")
		K.removePlayers({ p })
		advance(1)
		K.flushErrors("p2data_profile")
		K.flushWarnings("p2data_profile", { "MutateHome callback errored" })
	end)

	------------------------------------------------------------------------------------------------
	-- scenario: saves, migration, merge rules
	------------------------------------------------------------------------------------------------
	S.p2data_save = guarded("p2data_save", function()
		if not K.needBoot() then
			return
		end
		local DataS, PS = mod("DataService"), mod("PetService")
		local Config = config()
		local DSt = Mock.DataStore
		local data = DSt.Data

		-- migration: the reserved Home.Rooms becomes Stations; tier keys stay equipped
		local MIG = 951101
		data[storeKey(MIG)] = {
			Version = 2, Tokens = 5, Pets = {}, Equipped = { "pebble_pup@Golden", "ghost_pet" }, Items = {}, Stats = statsOf(),
			Discovered = {}, IndexClaimed = {}, Tutorial = { Step = 1, Done = false, Gifted = false }, Cash = 7, Gems = 1,
			Home = { Level = 2, Prestige = 0, Rooms = { Kitchen = 3, Gym = 1 } }, PetLevels = { ["pebble_pup@Golden"] = { Level = 4, Xp = 9 } },
			Tiers = { pebble_pup = { Golden = 1 } },
		}
		local m = join("P2Migrate", MIG)
		local mp = DataS.GetProfile(m)
		if T.check(mp ~= nil, "p2 save: (precondition) a v3 profile with Home.Rooms loads") then
			T.check(mp.Home.Stations.Kitchen == 3 and mp.Home.Stations.Gym == 1 and mp.Home.Rooms == mp.Home.Stations, "p2 save: migration: Home.Rooms levels become Home.Stations")
			T.check(#mp.Equipped == 1 and mp.Equipped[1] == "pebble_pup@Golden" and m:GetAttribute(Config.Attr.EquippedPets) == "pebble_pup@Golden",
				"p2 save: an equipped tier key stays equipped (tier copies count as owned); unknown ids are dropped")
			T.check(mp.Discovered.pebble_pup == true and mp.PetLevels["pebble_pup@Golden"].Level == 4, "p2 save: tier copies count as discovered; PetLevels keep keys")
			T.check(mp.Cash == 7 and m:GetAttribute(Config.Attr.Cash) == 7, "p2 save: stored Cash is mirrored on load")
		end
		DataS.AddCash(m, 10)
		K.removePlayers({ m })
		advance(2)
		local sm = stored(MIG) or {}
		local sh = type(sm.Home) == "table" and sm.Home or {}
		T.check(type(sh.Stations) == "table" and sh.Stations.Kitchen == 3 and sh.Rooms == nil and sm.Version == 2 and sm.Cash == 17,
			"p2 save: the save holds Home.Stations (no Rooms any more), Version 2, Cash 7 + 10")
		T.check(type(sm.Equipped) == "table" and sm.Equipped[1] == "pebble_pup@Golden" and type(sm.Tiers) == "table" and sm.Tiers.pebble_pup.Golden == 1,
			"p2 save: ...the equipped tier key and the tier copies")

		-- slots are stored without holes; empty Phase 2 maps are left out
		local SL = 951102
		data[storeKey(SL)] = nil
		local s = join("P2Slots", SL)
		DataS.MutateHome(s, function(home)
			home.Garden[1] = "pebble_pup"
			home.Garden[3] = "pip_penguin"
			home.Gym[2] = "cloudy_dragon"
		end)
		DataS.Save(s)
		local ss = stored(SL) or {}
		local g = type(ss.Home) == "table" and ss.Home.Garden or {}
		local gy = type(ss.Home) == "table" and ss.Home.Gym or {}
		T.check(g[1] == "pebble_pup" and g[2] == "" and g[3] == "pip_penguin" and #g == 3 and gy[1] == "" and gy[2] == "cloudy_dragon",
			"p2 save: Garden / Gym are stored as arrays with '' for empty slots (no sparse arrays in the store)", listText(g) .. " " .. listText(gy))
		T.check(ss.Food == nil and ss.Tiers == nil and ss.Hybrids == nil and ss.GemReceipts == nil and ss.Teams == nil, "p2 save: empty Phase 2 maps are left out of the record")
		K.removePlayers({ s })
		advance(2)
		local s2 = join("P2Slots", SL)
		local home2 = DataS.GetHome(s2)
		T.check(home2 and home2.Garden[1] == "pebble_pup" and home2.Garden[2] == nil and home2.Garden[3] == "pip_penguin" and home2.Gym[2] == "cloudy_dragon",
			"p2 save: ...and read back as slot -> key")
		K.removePlayers({ s2 })
		advance(2)

		-- merge rules against a concurrent server
		local MG = 951103
		data[storeKey(MG)] = {
			Version = 2, Tokens = 0, Pets = { pip_penguin = 1, pebble_pup = 1 }, Equipped = {}, Items = {}, Stats = statsOf(),
			Cash = 1000, Gems = 0, Food = { Snack = 1 },
			Home = { Level = 3, Prestige = 0, Stations = { Press1 = 1, Kitchen = 1 }, Garden = {}, Gym = {}, CollectorCash = 20, LastSeen = 100 },
		}
		local q = join("P2Merge", MG)
		local qp = DataS.GetProfile(q)
		-- another server changes the stored profile meanwhile
		local other = data[storeKey(MG)]
		other.Cash = other.Cash + 50
		other.Food = { Snack = 4 }
		other.Home.Stations.Kitchen = 5
		other.Home.CollectorCash = other.Home.CollectorCash + 40
		other.Tiers = { cloudy_dragon = { Golden = 1 } }
		other.PetLevels = { pip_penguin = { Level = 3, Xp = 0 } }
		other.Hybrids = { o1 = { Body = "pip_penguin", Style = "ember_phoenix", Tier = "Normal" } }
		other.GemReceipts = { r_other = 123 }
		-- this session
		DataS.AddCash(q, 100)
		DataS.AddFood(q, "Snack", 2)
		DataS.MutateHome(q, function(home)
			home.Stations.Press1 = 2
			home.CollectorCash = home.CollectorCash + 100
			home.LastSeen = 50
		end)
		qp.Tiers.pebble_pup = { Rainbow = 1 }
		qp.Hybrids.s1 = { Body = "pebble_pup", Style = "maple_fox", Tier = "Normal" }
		DataS.AddPetXp(q, "pebble_pup", 10)
		T.eq(DataS.MarkReceipt(q, "r_mine"), true, "p2 save: MarkReceipt -> true the first time")
		T.eq(DataS.MarkReceipt(q, "r_mine"), false, "p2 save: ...false for a purchase already processed")
		T.eq(DataS.HasReceipt(q, "r_mine"), true, "p2 save: HasReceipt")
		DataS.MarkDirty(q)
		DataS.Save(q)
		local sq = stored(MG) or {}
		local hq = type(sq.Home) == "table" and sq.Home or {}
		T.eq(sq.Cash, 1150, "p2 save: Cash merges as a delta (1000 + 50 elsewhere + 100 here)")
		T.check(type(sq.Food) == "table" and sq.Food.Snack == 6, "p2 save: Food merges as a delta (1 -> 4 elsewhere, +2 here)", type(sq.Food) == "table" and tostring(sq.Food.Snack) or "nil")
		T.check(type(hq.Stations) == "table" and hq.Stations.Press1 == 2 and hq.Stations.Kitchen == 5, "p2 save: Stations merge per key (Press1 from here, Kitchen from the other server)")
		T.eq(hq.CollectorCash, 160, "p2 save: CollectorCash merges as a delta (20 + 40 + 100)")
		T.eq(hq.LastSeen, 100, "p2 save: LastSeen keeps the later time")
		T.check(type(sq.Tiers) == "table" and sq.Tiers.cloudy_dragon and sq.Tiers.cloudy_dragon.Golden == 1 and sq.Tiers.pebble_pup and sq.Tiers.pebble_pup.Rainbow == 1,
			"p2 save: Tiers merge per pet")
		T.check(type(sq.Hybrids) == "table" and sq.Hybrids.o1 ~= nil and sq.Hybrids.s1 ~= nil, "p2 save: Hybrids merge per uid")
		T.check(type(sq.PetLevels) == "table" and sq.PetLevels.pip_penguin and sq.PetLevels.pip_penguin.Level == 3 and sq.PetLevels.pebble_pup ~= nil,
			"p2 save: PetLevels merge per key")
		T.check(type(sq.GemReceipts) == "table" and sq.GemReceipts.r_other == 123 and type(sq.GemReceipts.r_mine) == "number", "p2 save: GemReceipts only grow (union)")
		advance(0.5)
		T.check(DataS.GetCash(q) == 1150 and q:GetAttribute(Config.Attr.Cash) == 1150 and DataS.GetHome(q).Stations.Kitchen == 5 and qp.Tiers.cloudy_dragon ~= nil,
			"p2 save: the live profile adopts the merged store (Cash attribute, Kitchen, Tiers)")

		-- prestige rule A: a higher stored prestige wins the whole Home
		other = data[storeKey(MG)]
		other.Home = { Level = 0, Prestige = 1, Stations = { Press1 = 1 }, Garden = {}, Gym = {}, CollectorCash = 0, LastSeen = 100 }
		DataS.MutateHome(q, function(home)
			home.Stations.Press1 = 3
			home.Stations.Gym = 2
		end)
		DataS.Save(q)
		hq = (stored(MG) or {}).Home or {}
		T.check(hq.Prestige == 1 and hq.Stations.Press1 == 1 and hq.Stations.Gym == nil, "p2 save: a higher stored Prestige wins the whole Home (this server's station edits are void)")
		advance(0.5)
		local live = DataS.GetHome(q)
		T.check(live.Prestige == 1 and live.Stations.Press1 == 1 and live.Stations.Gym == nil, "p2 save: ...and the live Home follows")
		-- prestige rule B: the session prestiges past the store: its whole Home wins
		other = data[storeKey(MG)]
		other.Home.Stations.Kitchen = 9
		DataS.MutateHome(q, function(home)
			home.Prestige = 2
			for k in pairs(home.Stations) do
				home.Stations[k] = nil
			end
			home.Level = 0
		end)
		DataS.Save(q)
		hq = (stored(MG) or {}).Home or {}
		T.check(hq.Prestige == 2 and type(hq.Stations) == "table" and next(hq.Stations) == nil, "p2 save: a session that prestiged past the store writes its whole Home (stations reset)")
		-- receipts stay bounded and a fresh receipt always survives
		for i = 1, 120 do
			DataS.MarkReceipt(q, "bulk_" .. i)
		end
		T.eq(DataS.MarkReceipt(q, "bulk_last"), true, "p2 save: (a fresh receipt)")
		DataS.Save(q)
		local rc = (stored(MG) or {}).GemReceipts or {}
		T.check(countKeys(rc) <= 100 and rc.bulk_last ~= nil, "p2 save: GemReceipts stay bounded (<= 100) and keep the newest receipt", countKeys(rc) .. " receipts")
		K.removePlayers({ q })
		advance(2)

		-- ResetFields({ Home = true }) writes a reset Home over a higher stored prestige
		local RS = 951104
		data[storeKey(RS)] = {
			Version = 2, Tokens = 0, Pets = {}, Equipped = {}, Items = {}, Stats = statsOf(),
			Home = { Level = 30, Prestige = 3, Stations = { Press1 = 9 }, Garden = {}, Gym = {}, CollectorCash = 0, LastSeen = 0 },
		}
		local r = join("P2Reset", RS)
		local rp = DataS.GetProfile(r)
		rp.Home.Prestige = 0
		rp.Home.Level = 0
		rp.Home.Stations.Press1 = nil
		DataS.MarkDirty(r)
		DataS.Save(r)
		T.eq(((stored(RS) or {}).Home or {}).Prestige, 3, "p2 save: (without ResetFields a lowered prestige loses against the store)")
		advance(0.5)
		rp = DataS.GetProfile(r)
		rp.Home.Prestige = 0
		rp.Home.Level = 0
		rp.Home.Stations.Press1 = nil
		T.eq(DataS.ResetFields(r, { Home = true }), true, "p2 save: ResetFields accepts Home")
		DataS.Save(r)
		local rh = (stored(RS) or {}).Home or {}
		T.check(rh.Prestige == 0 and rh.Level == 0 and (type(rh.Stations) ~= "table" or rh.Stations.Press1 == nil), "p2 save: ...and the reset Home is written over the stored one")
		K.removePlayers({ r })
		advance(2)

		-- provisional profiles (load failed during an outage): no Home / XP / receipt decisions from stand-in data
		local PV = 951105
		data[storeKey(PV)] = {
			Version = 2, Tokens = 0, Pets = { pebble_pup = 1 }, Equipped = {}, Items = {}, Stats = statsOf(), Cash = 500,
			Home = { Level = 5, Prestige = 0, Stations = { Press1 = 7 }, Garden = {}, Gym = {}, CollectorCash = 30, LastSeen = 0 },
			PetLevels = { pebble_pup = { Level = 6, Xp = 0 } },
		}
		DSt.Fail = true
		local v = Mock.AddPlayer("P2Outage", PV)
		advance(4)
		local okProv = type(DataS.IsProvisional) == "function" and DataS.IsProvisional(v)
		T.check(okProv, "p2 save: (precondition) the outage makes the profile provisional")
		T.eq(DataS.GetHome(v), nil, "p2 save: GetHome is nil while provisional")
		T.eq(DataS.MutateHome(v, function(home)
			home.Stations.Press1 = 1
		end), false, "p2 save: MutateHome refuses station changes while provisional")
		T.eq(DataS.MutateHome(v, function(home)
			home.CollectorCash = home.CollectorCash + 15
		end), true, "p2 save: ...but CollectorCash (a delta) still counts")
		T.eq(DataS.AddPetXp(v, "pebble_pup", 50), 0, "p2 save: AddPetXp refuses while provisional")
		T.eq(DataS.MarkReceipt(v, "r_outage"), nil, "p2 save: MarkReceipt answers nil (NotProcessedYet) while provisional")
		T.eq(DataS.HasReceipt(v, "r_outage"), nil, "p2 save: ...and HasReceipt too")
		T.eq(DataS.AddCash(v, 5), true, "p2 save: AddCash (a delta) still works")
		DSt.Fail = false
		local recovered = K.waitFor(function()
			return not DataS.IsProvisional(v)
		end, 40)
		T.check(recovered, "p2 save: (the recovery reads the real save)")
		advance(1)
		local vh = DataS.GetHome(v)
		T.check(vh and vh.Stations.Press1 == 7 and vh.Level == 5 and vh.CollectorCash == 45 and DataS.GetCash(v) == 505,
			"p2 save: after the recovery the stored Home is intact and the in-outage deltas are on top (CollectorCash 30 + 15, Cash 500 + 5)",
			vh and (tostring(vh.Stations.Press1) .. " / " .. tostring(vh.CollectorCash) .. " / " .. tostring(DataS.GetCash(v))) or "no home")
		T.eq((DataS.GetPetLevel(v, "pebble_pup")), 6, "p2 save: ...and the stored pet level too")
		K.removePlayers({ v })
		advance(3)
		K.flushErrors("p2data_save")
		K.flushWarnings("p2data_save", { "[DataService]" })
	end)

	return S
end

----------------------------------------------------------------------------------------------------
-- client world
----------------------------------------------------------------------------------------------------
local function clientScenarios()
	local S = {}
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer

	S.client_p2data = guarded("client_p2data", function()
		local KC = _G.KC
		local advance = KC.advance
		local M = KC.M
		local State, PetController = M.State, M.PetController
		local Config = KC.env()
		if not T.check(State ~= nil and PetController ~= nil, "p2 client: State and PetController are loaded") then
			return
		end
		local before = State.Get()
		local beforePets = LocalPlayer:GetAttribute(Config.Attr.EquippedPets)
		local beforeHyb = LocalPlayer:GetAttribute("EquippedHybrids")
		local beforeCash = LocalPlayer:GetAttribute(Config.Attr.Cash)
		local beforeGems = LocalPlayer:GetAttribute(Config.Attr.Gems)

		KC.toClient("ProfileSync", {
			Tokens = 10, Pets = { pebble_pup = 2, cloudy_dragon = 1 }, Equipped = { "pebble_pup@Golden" }, Items = {},
			Stats = { Matches = 0, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = {} }, Perks = {},
			Discovered = {}, IndexClaimed = {}, Tutorial = { Step = 1, Done = false, Gifted = false },
			Cash = 1234, Gems = 5,
			Home = { Level = 3, Prestige = 1, Stations = { Press1 = 2, Bad = -1 }, Garden = { "pebble_pup", "", "hyb:h1" }, Gym = { ["2"] = "cloudy_dragon" }, CollectorCash = 77 },
			Food = { Snack = 3, Bad = -1 },
			Tiers = { pebble_pup = { Golden = 1, Rainbow = 0 } },
			Hybrids = { h1 = { Body = "pip_penguin", Style = "ember_phoenix", Elements = { "Frost", "Flame" }, Name = "Pengnix", Rarity = "Legendary", Tier = "Normal" }, junk = { Body = 5 } },
			PetLevels = { ["pebble_pup@Golden"] = { Level = 4, Xp = 12 }, bad = "x" },
		})
		advance(0.1)
		T.check(State.OwnedCount("pebble_pup") == 2 and State.OwnedCount("pebble_pup@Golden") == 1 and State.OwnedCount("pebble_pup@Rainbow") == 0
			and State.OwnedCount("hyb:h1") == 1 and State.OwnedCount("hyb:junk") == 0,
			"p2 client: State.OwnedCount counts keys (Normal, Golden, hybrid; junk records dropped)")
		local keys = State.Keys and State.Keys() or {}
		T.eq(table.concat(keys, ","), "pebble_pup,pebble_pup@Golden,cloudy_dragon,hyb:h1", "p2 client: State.Keys() lists every owned key in display order")
		local gold = State.DefOf and State.DefOf("pebble_pup@Golden")
		T.check(gold and gold.Look.Finish == "Golden", "p2 client: State.DefOf(tier key) carries Look.Finish")
		local hyb = State.DefOf and State.DefOf("hyb:h1")
		T.check(hyb and hyb.Name == "Pengnix" and hyb.Look.Species == "Penguin", "p2 client: State.DefOf(hybrid key) merges the parents' looks")
		local lv, xp = State.PetLevel("pebble_pup@Golden")
		T.check(lv == 4 and xp == 12 and (State.PetLevel("nothing")) == 1, "p2 client: State.PetLevel")
		T.check(State.FoodCount("Snack") == 3 and State.Food().Bad == nil, "p2 client: State.Food / FoodCount (junk dropped)")
		local home = State.Home()
		T.check(home.Level == 3 and home.Prestige == 1 and home.Stations.Press1 == 2 and home.Stations.Bad == nil and home.CollectorCash == 77,
			"p2 client: State.Home() mirrors the Home")
		T.check(home.Garden[1] == "pebble_pup" and home.Garden[2] == nil and home.Garden[3] == "hyb:h1" and home.Gym[2] == "cloudy_dragon",
			"p2 client: ...Garden / Gym decoded to slot -> key ('' = empty, string slot numbers become numbers)")
		T.check(State.IsDiscovered("pebble_pup@Golden") and State.IsDiscovered("hyb:h1") and not State.IsDiscovered("pip_penguin@Golden"),
			"p2 client: IsDiscovered of a tier key = its base pet; a hybrid key while owned")
		T.check(State.IsEquipped("pebble_pup@Golden") and State.EquippedCount("pebble_pup@Golden") == 1 and not State.IsEquipped("pebble_pup"),
			"p2 client: IsEquipped / EquippedCount work per key")
		local cashSeen = nil
		local conn = State.CashChanged and State.CashChanged:Connect(function(v)
			cashSeen = v
		end)
		LocalPlayer:SetAttribute(Config.Attr.Cash, 999)
		advance(0.1)
		T.check(State.Cash() == 999 and cashSeen == 999, "p2 client: State.Cash() reads the Cash attribute (CashChanged fires)", tostring(cashSeen))
		if conn then
			conn:Disconnect()
		end
		LocalPlayer:SetAttribute(Config.Attr.Gems, 7)
		advance(0.1)
		T.eq(State.Gems(), 7, "p2 client: State.Gems() reads the Gems attribute")

		-- PetController: tier keys and hybrids
		local function modelsOf(player)
			local folder = workspace:FindFirstChild("ClientPets")
			local f = folder and folder:FindFirstChild(tostring(player.UserId))
			local out = {}
			for _, c in ipairs(f and f:GetChildren() or {}) do
				if c:IsA("Model") then
					out[#out + 1] = c
				end
			end
			return out
		end
		LocalPlayer:SetAttribute("EquippedHybrids", "")
		LocalPlayer:SetAttribute(Config.Attr.EquippedPets, "pebble_pup@Golden")
		advance(1.5)
		local mine = modelsOf(LocalPlayer)
		T.check(#mine == 1 and mine[1]:GetAttribute("PetId") == "pebble_pup@Golden", "p2 client: a tier key is drawn as a follower built from its tier def",
			mine[1] and tostring(mine[1]:GetAttribute("PetId")) or "no model")
		LocalPlayer:SetAttribute(Config.Attr.EquippedPets, "hyb:h9@Golden")
		advance(1.5)
		T.eq(#modelsOf(LocalPlayer), 0, "p2 client: a hybrid whose look has not arrived yet is skipped")
		LocalPlayer:SetAttribute("EquippedHybrids", "h9=pip_penguin/ember_phoenix/Golden/Legendary")
		advance(1.5)
		mine = modelsOf(LocalPlayer)
		T.check(#mine == 1 and mine[1]:GetAttribute("PetId") == "hyb:h9@Golden" and partCount(mine[1]) <= 350,
			"p2 client: ...and drawn once EquippedHybrids carries it (merged look, High detail for your own)", mine[1] and tostring(mine[1]:GetAttribute("PetId")) or "no model")
		local friend = Mock.AddPlayer("HybridFriend", 6101)
		advance(1.0)
		local myRoot = KC.root()
		if myRoot then
			Mock.Teleport(friend, myRoot.Position + Vector3.new(20, 0, 0))
		end
		friend:SetAttribute("EquippedHybrids", "f1=cloudy_dragon/stormfang/Normal/Secret;bad entry;x=/")
		friend:SetAttribute(Config.Attr.EquippedPets, "hyb:f1,hyb:x,ghost_pet")
		advance(2.0)
		local theirs = modelsOf(friend)
		T.check(#theirs == 1 and theirs[1]:GetAttribute("PetId") == "hyb:f1" and partCount(theirs[1]) <= 120,
			"p2 client: another player's hybrid is drawn at Low detail from the attribute; junk entries are ignored",
			#theirs .. " models" .. (theirs[1] and (", " .. partCount(theirs[1]) .. " parts") or ""))
		Mock.RemovePlayer(friend)
		advance(1.0)

		-- leave things as the later scenarios expect them
		LocalPlayer:SetAttribute("EquippedHybrids", beforeHyb)
		LocalPlayer:SetAttribute(Config.Attr.EquippedPets, beforePets)
		LocalPlayer:SetAttribute(Config.Attr.Cash, beforeCash)
		LocalPlayer:SetAttribute(Config.Attr.Gems, beforeGems)
		KC.toClient("ProfileSync", before)
		advance(1.5)
		KC.flushErrors("client_p2data")
		KC.flushWarnings("client_p2data")
	end)

	return S
end

if CONTEXT == "server" then
	return serverScenarios()
end
return clientScenarios()
