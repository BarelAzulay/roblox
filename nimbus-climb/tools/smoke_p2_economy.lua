-- smoke_p2_economy.lua: Phase 2 economy (ARCHITECTURE_V3.md "Phase 2 build contract", shared/TycoonCatalog.lua),
-- loaded by tools/smoke.py in the SERVER world as a pure content scenario (no boot needed):
--   p2_economy   TycoonCatalog loads (twice = the same table, no Instances created) with the contract API and data;
--                Validate() passes; the catalog equals the constants block of tools/sim_tycoon.py (the balance
--                simulation: prices, tier caps, requirements, effects, foods, XP curve, prestige, and the pet / roulette
--                data the sim assumes, checked against PetCatalog and Config); pads behave like the contract (Press 1
--                free on a fresh home, the tree, lock reasons "Reach Home Level 10" / "Needs the Villa" /
--                "Unlocks at Prestige 1" / "Coming soon", tier caps, the prestige pad only with the Sky Castle);
--                Home Level, income (presses, Collector bonus, garden entries of every shape, slots, prestige x1.25),
--                Collector cap, offline earnings (Vault, minimum absence, hour cap), XP curve, food, fusion costs,
--                prestige reset (decor kept); junk input never errors; the yard layout (house at the back, presses +
--                conveyor + Collector on one side, garden opposite, decor along the fence, pads in front of their
--                stations, gate / spawn clear, pet spots inside the garden / gym, every pad reachable from the gate).
-- tools/sim_tycoon.py is read from the working directory (smoke.py / run_checks.sh run from the repo root).
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local K = _G.K

local abs, floor, huge = math.abs, math.floor, math.huge

local S = {}

local TIER_IDS = { "Cottage", "Villa", "Manor", "SkyCastle" }
local CONTRACT_IDS = {
	"Press1", "Press2", "Press3", "Press4", "Collector", "Garden", "Kitchen", "Gym", "Vault", "House",
	"FusionMachine", "ArenaGate", "DecorLamps", "DecorFence", "DecorFlowers", "DecorFountain", "DecorBanners", "DecorPodium",
}
local RARITY_ORDER = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }

local function fmt(v, n)
	return string.format("%." .. (n or 1) .. "f", tonumber(v) or 0)
end

local function near(a, b, tol)
	return type(a) == "number" and type(b) == "number" and abs(a - b) <= (tol or 1e-9)
end

local function listEq(a, b, tol)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return false
	end
	for i = 1, #a do
		if type(a[i]) == "number" or type(b[i]) == "number" then
			if not near(a[i], b[i], tol) then
				return false
			end
		elseif a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function show(list)
	if type(list) ~= "table" then
		return tostring(list)
	end
	local out = {}
	for i = 1, #list do
		out[i] = tostring(list[i])
	end
	return "[" .. table.concat(out, ", ") .. "]"
end

local function loadCatalog()
	local inst = K.moduleInstance("shared/TycoonCatalog")
	if not inst then
		return nil, "no ModuleScript shared/TycoonCatalog"
	end
	local ok, result = pcall(require, inst)
	if not ok then
		return nil, tostring(result)
	end
	if type(result) ~= "table" then
		return nil, "returned " .. type(result)
	end
	return result, inst
end

----------------------------------------------------------------------------------------------------
-- tools/sim_tycoon.py constants block: one `NAME = value` per line (number, [numbers], "string")
----------------------------------------------------------------------------------------------------
local function readSim()
	local here = debug.getinfo(1, "S").source:match("^=(.*)smoke_p2_economy%.lua$")
	local candidates = { "tools/sim_tycoon.py", "sim_tycoon.py", "../tools/sim_tycoon.py" }
	if here and here ~= "" then
		table.insert(candidates, 1, here .. "sim_tycoon.py")
	end
	for _, path in ipairs(candidates) do
		local fh = io.open(path, "r")
		if fh then
			local src = fh:read("*a")
			fh:close()
			return src, path
		end
	end
	return nil, "tools/sim_tycoon.py not found from the working directory (run tools/smoke.py from the repo root)"
end

local function parseSim(src)
	local block = src:match("# ==== BEGIN SIM CONSTANTS ====\n(.-)\n# ==== END SIM CONSTANTS ====")
	if not block then
		return nil, "no '# ==== BEGIN SIM CONSTANTS ====' ... '# ==== END SIM CONSTANTS ====' block"
	end
	local out, order, bad = {}, {}, {}
	for line in (block .. "\n"):gmatch("([^\n]*)\n") do
		if not line:match("^%s*#") and line:match("%S") then
			local body = line:gsub("%s+#.*$", "")
			local name, value = body:match("^([%w_]+)%s*=%s*(.-)%s*$")
			if not name then
				bad[#bad + 1] = line
			elseif value:sub(1, 1) == "[" then
				local list = {}
				for num in value:gmatch("[-%d%.eE]+") do
					list[#list + 1] = tonumber(num)
				end
				out[name] = list
				order[#order + 1] = name
			elseif value:sub(1, 1) == '"' then
				out[name] = value:match('^"(.*)"$') or ""
				order[#order + 1] = name
			elseif tonumber(value) then
				out[name] = tonumber(value)
				order[#order + 1] = name
			else
				bad[#bad + 1] = line
			end
		end
	end
	return out, order, bad
end

local function words(text)
	local out = {}
	for w in tostring(text or ""):gmatch("%S+") do
		out[#out + 1] = w
	end
	return out
end

-- "Press2=3 House=Villa" -> { Press2 = 3, House = "Villa" }
local function parseReq(text)
	local out = {}
	for _, tok in ipairs(words(text)) do
		local k, v = tok:match("^([%w_]+)=([%w_]+)$")
		if k then
			out[k] = (k == "House") and v or tonumber(v)
		end
	end
	return out
end

local function reqEq(a, b)
	for k, v in pairs(a) do
		if b[k] ~= v then
			return false
		end
	end
	for k, v in pairs(b) do
		if a[k] ~= v then
			return false
		end
	end
	return true
end

local function reqText(r)
	local keys = {}
	for k in pairs(r) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do
		out[#out + 1] = k .. "=" .. tostring(r[k])
	end
	return table.concat(out, " ")
end

local function effectList(def, key)
	local out = {}
	for i, e in ipairs(def.Effects) do
		out[i] = e[key]
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- checks
----------------------------------------------------------------------------------------------------
local function apiChecks(TC)
	local fns = { "Get", "PriceFor", "AvailablePads", "HomeLevelOf", "IncomePerSecond", "CollectorCap", "OfflineEarnings", "XpToNext", "Validate" }
	local missing = {}
	for _, name in ipairs(fns) do
		if type(TC[name]) ~= "function" then
			missing[#missing + 1] = name
		end
	end
	T.check(#missing == 0, "economy: TycoonCatalog has the contract API (Get, PriceFor, AvailablePads, HomeLevelOf, IncomePerSecond, CollectorCap, OfflineEarnings, XpToNext, Validate)", table.concat(missing, ", "))
	local fields = { "Stations", "HouseTiers", "Prestige", "Foods", "Fusion", "PetXp", "Layout" }
	missing = {}
	for _, name in ipairs(fields) do
		if type(TC[name]) ~= "table" then
			missing[#missing + 1] = name
		end
	end
	T.check(#missing == 0, "economy: ...and the contract data (Stations, HouseTiers, Prestige, Foods, Fusion, PetXp, Layout)", table.concat(missing, ", "))

	-- every station of the contract, with the contract fields
	local tally = T.tally("economy: the 18 contract stations exist with Id, Name, Kind, MaxLevel, Requires, Price, Effects, Slot (CFrame + Footprint + Pad)")
	for _, id in ipairs(CONTRACT_IDS) do
		local def = TC.Get(id)
		local ok = type(def) == "table" and def.Id == id and type(def.Name) == "string" and type(def.Kind) == "string"
			and type(def.MaxLevel) == "number" and type(def.Requires) == "table" and type(def.Price) == "table"
			and type(def.Effects) == "table" and type(def.Slot) == "table" and typeof(def.Slot.CFrame) == "CFrame"
			and typeof(def.Slot.Footprint) == "Vector3" and typeof(def.Slot.Pad) == "CFrame"
		tally:case(ok, id)
	end
	tally:report()
	T.eq(#TC.Stations, #CONTRACT_IDS, "economy: ...and no other station")
	T.check(TC.Get("Nope") == nil and TC.PriceFor("Nope", 1) == nil, "economy: unknown ids give nil")

	-- house tiers + prestige per the contract
	local tiers = TC.HouseTiers
	local okTiers = #tiers == 4
	local wantHL = { 0, 10, 20, 30 }
	for i = 1, 4 do
		okTiers = okTiers and tiers[i] and tiers[i].Id == TIER_IDS[i] and tiers[i].HomeLevel == wantHL[i]
	end
	T.check(okTiers, "economy: HouseTiers = Cottage (start), Villa (Home Level 10), Manor (20), Sky Castle (30)")
	local p = TC.Prestige
	T.check(p.HomeLevel == 40 and p.House == "SkyCastle" and p.IncomeMultiplier == 1.25 and type(p.GemReward) == "number" and p.GemReward > 0,
		"economy: Prestige = { HomeLevel = 40, House = SkyCastle, IncomeMultiplier = 1.25, GemReward }")
	local foodsOk = true
	for _, id in ipairs({ "Snack", "Meal", "Feast" }) do
		local f = TC.FoodsById and TC.FoodsById[id]
		foodsOk = foodsOk and type(f) == "table" and type(f.Price) == "number" and type(f.Xp) == "number" and type(f.CookSeconds) == "number" and type(f.KitchenLevel) == "number"
	end
	T.check(foodsOk, "economy: Foods Snack / Meal / Feast with Price, Xp, CookSeconds, KitchenLevel")
	T.check(TC.Foods.Snack == TC.FoodsById.Snack and TC.Stations.Press1 == TC.Get("Press1") and TC.HouseTiers.Villa == TC.HouseTiers[2]
		and TC.Fusion.Rare and TC.Fusion.Rare.Golden == TC.Fusion.Upgrade.Rare.Golden,
		"economy: Stations / HouseTiers / Foods / Fusion also answer ids (Stations.Press1, Foods.Snack...) without extra pairs entries")
	local n = 0
	for _ in pairs(TC.Foods) do
		n = n + 1
	end
	T.eq(n, #TC.Foods, "economy: ...pairs(Foods) still sees each food once")
	T.eq(TC.MaxPetLevel, TC.PetXp.MaxLevel, "economy: MaxPetLevel = PetXp.MaxLevel (DataService.AddPetXp reads it)")
end

local function simChecks(TC, PC, Config)
	local src, path = readSim()
	if not T.check(src ~= nil, "economy: tools/sim_tycoon.py is readable", path) then
		return
	end
	local sim, order, bad = parseSim(src)
	if not T.check(sim ~= nil, "economy: the sim's constants block parses", order) then
		return
	end
	T.check(#bad == 0, "economy: ...every line of the block is NAME = number / [numbers] / \"string\"", table.concat(bad, " | "))
	T.check(#order >= 60, "economy: ...and it holds the whole economy (" .. #order .. " constants)")

	-- stations: prices, caps, requirements, flags, press incomes
	local keep = {}
	for _, w in ipairs(words(sim.KEEP_ON_PRESTIGE)) do
		keep[w] = true
	end
	local soon = {}
	for _, w in ipairs(words(sim.COMING_SOON)) do
		soon[w] = true
	end
	local prices = T.tally("economy: sim PRICE_<id> == catalog Price for every station", 4)
	local capsT = T.tally("economy: sim CAPS_<id> == catalog TierCaps (Cottage, Villa, Manor, Sky Castle)", 4)
	local reqT = T.tally("economy: sim REQ_<id> == catalog Requires", 4)
	local flagT = T.tally("economy: sim KEEP_ON_PRESTIGE / COMING_SOON == catalog KeepOnPrestige / ComingSoon", 4)
	local incT = T.tally("economy: sim INCOME_<press> == catalog press Effects.Income", 4)
	for _, def in ipairs(TC.Stations) do
		local id = def.Id
		local sp = sim["PRICE_" .. id]
		local cp = {}
		for lv = 1, def.MaxLevel do
			cp[lv] = def.Price[lv]
		end
		prices:case(listEq(sp, cp), id .. ": sim " .. show(sp) .. " vs catalog " .. show(cp))
		local caps = {}
		for i, t in ipairs(TIER_IDS) do
			caps[i] = def.TierCaps[t]
		end
		capsT:case(listEq(sim["CAPS_" .. id], caps), id .. ": sim " .. show(sim["CAPS_" .. id]) .. " vs " .. show(caps))
		local sr = sim["REQ_" .. id]
		reqT:case(type(sr) == "string" and reqEq(parseReq(sr), def.Requires), id .. ": sim '" .. tostring(sr) .. "' vs '" .. reqText(def.Requires) .. "'")
		flagT:case((keep[id] == true) == (def.KeepOnPrestige == true) and (soon[id] == true) == (def.ComingSoon == true), id)
		if def.Kind == "Press" then
			incT:case(listEq(sim["INCOME_" .. id], effectList(def, "Income")), id .. ": sim " .. show(sim["INCOME_" .. id]) .. " vs " .. show(effectList(def, "Income")))
		end
	end
	prices:report()
	capsT:report()
	reqT:report()
	flagT:report()
	incT:report()
	local extra = {}
	for _, name in ipairs(order) do
		local id = name:match("^PRICE_(.+)$")
		if id and not TC.Get(id) then
			extra[#extra + 1] = id
		end
	end
	T.check(#extra == 0, "economy: the sim prices no station the catalog lacks", table.concat(extra, ", "))

	-- effects tables
	local byId = TC.ById
	local effects = {
		{ "COLLECTOR_BONUS", "Collector", "Bonus" }, { "COLLECTOR_CAP_SECONDS", "Collector", "CapSeconds" },
		{ "COLLECTOR_FLAT_CAP", "Collector", "FlatCap" }, { "VAULT_CAP_SECONDS", "Vault", "CapSeconds" },
		{ "VAULT_FLAT_CAP", "Vault", "FlatCap" }, { "VAULT_OFFLINE_PERCENT", "Vault", "OfflinePercent" },
		{ "VAULT_OFFLINE_HOURS", "Vault", "OfflineHours" }, { "GARDEN_SLOTS", "Garden", "Slots" },
		{ "KITCHEN_SLOTS", "Kitchen", "Slots" }, { "KITCHEN_COOK_SPEED", "Kitchen", "CookSpeed" },
		{ "GYM_SLOTS", "Gym", "Slots" }, { "GYM_XP_PER_MINUTE", "Gym", "XpPerMinute" },
		{ "FUSION_TOKEN_DISCOUNT", "FusionMachine", "TokenDiscount" },
	}
	local effT = T.tally("economy: sim effect tables == catalog Effects (Collector, Vault, Garden, Kitchen, Gym, Fusion Machine)", 4)
	for _, e in ipairs(effects) do
		local got = effectList(byId[e[2]], e[3])
		effT:case(listEq(sim[e[1]], got), e[1] .. ": sim " .. show(sim[e[1]]) .. " vs " .. show(got))
	end
	effT:report()
	local hl = {}
	for i, t in ipairs(TC.HouseTiers) do
		hl[i] = t.HomeLevel
	end
	T.check(listEq(sim.HOUSE_HOME_LEVEL, hl), "economy: sim HOUSE_HOME_LEVEL == HouseTiers Home Levels", show(sim.HOUSE_HOME_LEVEL) .. " vs " .. show(hl))
	local p = TC.Prestige
	T.check(sim.PRESTIGE_HOME_LEVEL == p.HomeLevel and near(sim.PRESTIGE_MULTIPLIER, p.IncomeMultiplier)
		and listEq(sim.PRESTIGE_GEMS, { p.GemReward, p.GemRewardStep, p.GemRewardMin }),
		"economy: sim PRESTIGE_* == catalog Prestige (Home Level, x1.25, gem rewards)")
	T.eq(sim.OFFLINE_MIN_SECONDS, TC.OfflineMinSeconds, "economy: sim OFFLINE_MIN_SECONDS == catalog")
	local foodT = T.tally("economy: sim FOOD_<id> == catalog Foods (Price, Xp, CookSeconds, KitchenLevel)")
	for _, f in ipairs(TC.Foods) do
		local got = { f.Price, f.Xp, f.CookSeconds, f.KitchenLevel }
		foodT:case(listEq(sim["FOOD_" .. f.Id], got), f.Id .. ": sim " .. show(sim["FOOD_" .. f.Id]) .. " vs " .. show(got))
	end
	foodT:report()
	local px = TC.PetXp
	T.check(listEq(sim.PET_XP, { px.MaxLevel, px.Base, px.Exponent, px.Round }), "economy: sim PET_XP == catalog PetXp", show(sim.PET_XP))
	-- the sim's XP formula gives exactly XpToNext at every level
	local xpT = T.tally("economy: XpToNext(level) == the sim's round(Base * level ^ Exponent / Round) * Round for every level")
	if type(sim.PET_XP) == "table" and #sim.PET_XP == 4 then
		local maxL, base, ex, rnd = sim.PET_XP[1], sim.PET_XP[2], sim.PET_XP[3], sim.PET_XP[4]
		for lv = 1, maxL do
			local want = lv >= maxL and huge or math.max(rnd, floor(base * lv ^ ex / rnd + 0.5) * rnd)
			xpT:case(TC.XpToNext(lv) == want, "level " .. lv .. ": " .. tostring(TC.XpToNext(lv)) .. " vs " .. tostring(want))
		end
	end
	xpT:report()
	local tm = TC.TierMultiplier
	T.check(listEq(sim.TIER_MULTIPLIER, { tm.Normal, tm.Golden, tm.Rainbow }), "economy: sim TIER_MULTIPLIER == catalog TierMultiplier (1 / 1.5 / 2.5)")
	local pkInst = K.moduleInstance("shared/PetKeys")
	if pkInst then
		local ok, PK = pcall(require, pkInst)
		if ok and type(PK) == "table" and type(PK.StatMultiplier) == "function" then
			T.check(PK.StatMultiplier("Golden") == tm.Golden and PK.StatMultiplier("Rainbow") == tm.Rainbow and PK.StatMultiplier("Normal") == tm.Normal,
				"economy: ...and agrees with PetKeys.StatMultiplier")
		end
	end

	-- the pet data the sim assumes is the real catalog
	local scale = Config.PetStats.RarityScale
	local scales = {}
	for i, r in ipairs(RARITY_ORDER) do
		scales[i] = scale[r]
	end
	T.check(listEq(sim.RARITY_SCALE, scales), "economy: sim RARITY_SCALE == Config.PetStats.RarityScale", show(sim.RARITY_SCALE) .. " vs " .. show(scales))
	local rollable, econ = {}, {}
	for i, r in ipairs(RARITY_ORDER) do
		rollable[i] = 0
		econ[r] = {}
	end
	for _, def in ipairs(PC.Pets) do
		local canRoll = def.Rarity ~= "Secret"
		if type(PC.IsRollable) == "function" then
			canRoll = PC.IsRollable(def.Id) and true or false
		end
		if canRoll then
			for i, r in ipairs(RARITY_ORDER) do
				if r == def.Rarity then
					rollable[i] = rollable[i] + 1
				end
			end
			if def.Role == "Economy" and econ[def.Rarity] then
				local list = econ[def.Rarity]
				list[#list + 1] = def.Stats.Income
			end
		end
	end
	local want = {}
	for i = 1, 6 do
		want[i] = rollable[i]
	end
	T.check(listEq(sim.PET_ROLLABLE, want), "economy: sim PET_ROLLABLE == rollable pets per rarity in PetCatalog", show(sim.PET_ROLLABLE) .. " vs " .. show(want))
	local econT = T.tally("economy: sim ECON_INCOME_<rarity> == base Income of the rollable Economy pets (PetCatalog)")
	for i = 1, 6 do
		local r = RARITY_ORDER[i]
		local a, b = {}, {}
		for j, v in ipairs(sim["ECON_INCOME_" .. r] or {}) do
			a[j] = v
		end
		for j, v in ipairs(econ[r]) do
			b[j] = v
		end
		table.sort(a)
		table.sort(b)
		econT:case(listEq(a, b), r .. ": sim " .. show(a) .. " vs catalog " .. show(b))
	end
	econT:report()
	local oddsT = T.tally("economy: sim ODDS_<roulette> == Config.Roulettes odds (Common .. Mythic)")
	for _, roulette in ipairs(Config.Roulettes) do
		local got = {}
		for i = 1, 6 do
			got[i] = roulette.Odds[RARITY_ORDER[i]] or 0
		end
		oddsT:case(listEq(sim["ODDS_" .. roulette.Id], got), roulette.Id .. ": sim " .. show(sim["ODDS_" .. roulette.Id]) .. " vs " .. show(got))
	end
	oddsT:report()
end

local function padOf(pads, id)
	for _, pad in ipairs(pads) do
		if pad.StationId == id then
			return pad
		end
	end
	return nil
end

local function home(stations, prestige)
	return { Stations = stations or {}, Prestige = prestige or 0, Garden = {}, Gym = {} }
end

-- every station of a tier bought up to that tier's caps (no prestige-only / coming-soon stations)
local function builtTo(TC, tierIndex, prestige)
	local st = {}
	local tierId = TIER_IDS[tierIndex]
	for _, def in ipairs(TC.Stations) do
		if not def.ComingSoon and not (def.Requires.Prestige and def.Requires.Prestige > (prestige or 0)) then
			st[def.Id] = def.TierCaps[tierId]
		end
	end
	st.House = tierIndex
	return home(st, prestige)
end

local function padChecks(TC)
	-- a fresh home: only the free Press 1 pad
	local fresh = TC.AvailablePads(home())
	local p1 = padOf(fresh, "Press1")
	T.check(#fresh == 1 and p1 ~= nil and p1.Price == 0 and p1.Locked == nil and p1.NextLevel == 1,
		"economy: a freshly claimed home shows exactly one pad: Press 1, free and unlocked (first purchase within seconds)",
		#fresh .. " pads")
	T.eq(TC.PriceFor("Press1", 1), 0, "economy: PriceFor(Press1, 1) = 0 (free)")
	local afterPress = TC.AvailablePads(home({ Press1 = 1 }))
	local coll = padOf(afterPress, "Collector")
	T.check(coll ~= nil and coll.Price == 0 and coll.Locked == nil, "economy: ...then the Collector pad appears, free (Cash starts at 0)")
	T.check(padOf(afterPress, "Press1") and padOf(afterPress, "Press1").NextLevel == 2 and padOf(afterPress, "Press1").LevelText == "Lv 1 -> 2",
		"economy: the upgrade pad stays on the station: Press 1 'Lv 1 -> 2'")
	T.check(padOf(afterPress, "Garden") == nil and padOf(afterPress, "Press2") == nil, "economy: pads unlock in a tree (no Press 2 / Garden pad yet)")
	-- second step of the tree
	local h = home({ Press1 = 2, Collector = 1, House = 1 })
	T.check(padOf(TC.AvailablePads(h), "Press2") ~= nil, "economy: Press 1 level 2 opens the Press 2 pad")
	-- House locked by Home Level
	local housePad = padOf(TC.AvailablePads(h), "House")
	T.check(housePad and housePad.Locked == "Reach Home Level 10" and housePad.Title == "Villa" and housePad.Price == TC.PriceFor("House", 2),
		"economy: the House pad shows 'Reach Home Level 10' for the Villa until Home Level 10", housePad and tostring(housePad.Locked))
	-- Press 3 needs the Villa
	local h3 = home({ Press1 = 6, Press2 = 3, Collector = 2, House = 1 })
	local p3 = padOf(TC.AvailablePads(h3), "Press3")
	T.check(p3 and p3.Locked == "Needs the Villa", "economy: Press 3 shows 'Needs the Villa' in a Cottage", p3 and tostring(p3.Locked))
	-- tier caps
	local capped = padOf(TC.AvailablePads(h3), "Press1")
	T.check(capped and capped.Locked == "Needs the Villa" and capped.NextLevel == 7, "economy: a station at its Cottage cap shows 'Needs the Villa'", capped and tostring(capped.Locked))
	local villaHome = builtTo(TC, 2, 0)
	local p1v = padOf(TC.AvailablePads(villaHome), "Press1")
	T.check(p1v and p1v.Locked == "Needs the Manor", "economy: ...and 'Needs the Manor' at the Villa cap", p1v and tostring(p1v.Locked))
	-- Fusion Machine: locked silhouette until Prestige 1
	local hk = home({ Press1 = 2, Press2 = 2, Collector = 1, Garden = 1, Kitchen = 1 })
	local fm = padOf(TC.AvailablePads(hk), "FusionMachine")
	T.check(fm and fm.Locked == "Unlocks at Prestige 1", "economy: the Fusion Machine pad says 'Unlocks at Prestige 1' before the first prestige", fm and tostring(fm.Locked))
	local hk1 = home({ Press1 = 2, Press2 = 2, Collector = 1, Garden = 1, Kitchen = 1 }, 1)
	fm = padOf(TC.AvailablePads(hk1), "FusionMachine")
	T.check(fm and fm.Locked == nil, "economy: ...and opens with 1 prestige star")
	-- Arena Gate: coming soon
	local hg = home({ Press1 = 2, Press2 = 2, Collector = 1, Garden = 1, Kitchen = 1, Gym = 1 })
	local ag = padOf(TC.AvailablePads(hg), "ArenaGate")
	T.check(ag and ag.Locked == "Coming soon", "economy: the Arena Gate pad says 'Coming soon' (Phase 3)", ag and tostring(ag.Locked))
	-- prestige pad only with the Sky Castle; locked below Home Level 40
	local manor = builtTo(TC, 3, 0)
	local hasPrestige = false
	for _, pad in ipairs(TC.AvailablePads(manor)) do
		if pad.StationId == "Prestige" or pad.Prestige then
			hasPrestige = true
		end
	end
	T.check(not hasPrestige, "economy: no prestige pad before the Sky Castle")
	local castleLow = home({ Press1 = 1, Collector = 1, House = 4 })
	local pp = padOf(TC.AvailablePads(castleLow), "Prestige")
	T.check(pp and pp.Prestige == true and pp.Locked == "Reach Home Level 40" and pp.Price == 0, "economy: with the Sky Castle the prestige pad shows 'Reach Home Level 40' until Home Level 40", pp and tostring(pp.Locked))
	local castle = builtTo(TC, 4, 0)
	T.check(TC.HomeLevelOf(castle) >= 40, "economy: a fully built Sky Castle home reaches Home Level 40 (" .. TC.HomeLevelOf(castle) .. ")")
	pp = padOf(TC.AvailablePads(castle), "Prestige")
	T.check(pp and pp.Locked == nil and pp.NextLevel == 1, "economy: ...and its prestige pad is open")
	local okP = TC.CanPrestige and TC.CanPrestige(castle)
	T.check(okP == true, "economy: CanPrestige agrees")
	local def = TC.Get("Prestige")
	T.check(type(def) == "table" and def.Kind == "Prestige" and typeof(def.Slot.Pad) == "CFrame", "economy: Get('Prestige') gives the prestige pad's slot (Kind Prestige) so HomeBuilder can place Pad_Prestige")
	-- prices on pads are the real prices and every unlocked pad is buyable via CheckPurchase
	local mismatch = 0
	for _, pad in ipairs(TC.AvailablePads(villaHome)) do
		if pad.StationId ~= "Prestige" and pad.Price ~= TC.PriceFor(pad.StationId, pad.NextLevel) then
			mismatch = mismatch + 1
		end
		if TC.CheckPurchase then
			local ok, price, reason = TC.CheckPurchase(villaHome, pad.StationId)
			if pad.StationId ~= "Prestige" and ((pad.Locked == nil) ~= (ok == true) or (ok and price ~= pad.Price) or (not ok and reason ~= pad.Locked)) then
				mismatch = mismatch + 1
			end
		end
	end
	T.eq(mismatch, 0, "economy: pad prices equal PriceFor and CheckPurchase agrees with the lock reasons")
	-- maxed stations have no pad
	local maxed = home({ Press1 = 10, Collector = 1, House = 4 })
	T.check(padOf(TC.AvailablePads(maxed), "Press1") == nil, "economy: a maxed station shows no pad")

	-- Home Level
	T.eq(TC.HomeLevelOf(home({ Press1 = 3, Collector = 1, DecorLamps = 1 })), 5, "economy: Home Level = the sum of station levels (each purchase = +1)")
	T.eq(TC.HomeLevelOf(home({ Press1 = 99, Bogus = 5, Collector = -3, Garden = "2" })), 10 + 2, "economy: Home Level ignores unknown stations / negatives and clamps to MaxLevel")
	-- prestige reset keeps the decor only
	local after = TC.StationsAfterPrestige({ Press1 = 8, House = 4, DecorLamps = 2, DecorFountain = 1, Garden = 3, Bogus = 2 })
	T.check(after.Press1 == nil and after.House == nil and after.Garden == nil and after.Bogus == nil and after.DecorLamps == 2 and after.DecorFountain == 1,
		"economy: StationsAfterPrestige keeps the decor (KeepOnPrestige) and resets everything else")
end

local function incomeChecks(TC, PC, Config)
	local h0 = home({ Press1 = 1 })
	T.eq(TC.IncomePerSecond(h0, {}, 0), 0, "economy: no Collector, no income (the presses feed it)")
	local h1 = home({ Press1 = 1, Collector = 1 })
	local i1 = TC.IncomePerSecond(h1, {}, 0)
	T.check(near(i1, TC.Get("Press1").Effects[1].Income), "economy: Press 1 level 1 + Collector earns the press income (" .. fmt(i1) .. " Cash/s)")
	T.check(near(TC.IncomePerSecond(h1, {}, 1), i1 * 1.25) and near(TC.IncomePerSecond(h1, {}, 2), i1 * 1.5625),
		"economy: prestige multiplies income by 1.25 per star (compounding)")
	local hp = home({ Press1 = 1, Collector = 1 }, 2)
	T.check(near(TC.IncomePerSecond(hp, {}), i1 * 1.5625), "economy: ...taken from home.Prestige when the argument is nil")
	local hb = home({ Press1 = 4, Press2 = 2, Collector = 2 })
	local press = TC.Get("Press1").Effects[4].Income + TC.Get("Press2").Effects[2].Income
	T.check(near(TC.IncomePerSecond(hb, {}, 0), press * (1 + TC.Get("Collector").Effects[2].Bonus)), "economy: the Collector level adds its Bonus to the press income")

	-- garden entries of every shape; slots limit them
	local pup = PC.Get("pebble_pup")
	local scale = Config.PetStats.RarityScale
	local function petCash(def, level, mult)
		return def.Stats.Income * scale[def.Rarity] * (1 + 0.1 * ((level or 1) - 1)) * (mult or 1)
	end
	local hg = home({ Press1 = 1, Collector = 1, Garden = 2 })
	local base = TC.IncomePerSecond(hg, {}, 0)
	local unicorn = PC.Get("starlight_unicorn")
	local g1 = TC.IncomePerSecond(hg, { pup }, 0) - base
	T.check(near(g1, petCash(pup)), "economy: a garden PetDef earns Income x RarityScale (" .. fmt(g1) .. " Cash/s)")
	local g2 = TC.IncomePerSecond(hg, { { Def = unicorn, Level = 5, Tier = "Golden" } }, 0) - base
	T.check(near(g2, petCash(unicorn, 5, 1.5)), "economy: { Def, Level, Tier } applies the level factor (+10%/level) and the tier (Golden x1.5)")
	T.check(near(TC.IncomePerSecond(hg, { 7 }, 0) - base, 7) and near(TC.IncomePerSecond(hg, { { Income = 9 } }, 0) - base, 9),
		"economy: numbers and { Income = n } entries count as Cash/s")
	T.check(near(TC.IncomePerSecond(hg, { "pebble_pup@Rainbow" }, 0) - base, petCash(pup, 1, 2.5)), "economy: pet key strings resolve through PetCatalog (\"pebble_pup@Rainbow\" = x2.5)")
	T.check(near(TC.IncomePerSecond(hg, { pup, pup, pup, pup }, 0) - base, 2 * petCash(pup)), "economy: only as many garden pets count as the Garden has slots (2 at level 2)")
	T.check(near(TC.IncomePerSecond(hg, { [1] = pup, [3] = "pebble_pup" }, 0) - base, 2 * petCash(pup)), "economy: a slot -> entry map works too")
	T.check(near(TC.IncomePerSecond(home({ Press1 = 1, Collector = 1 }), { pup }, 0), i1), "economy: no Garden, no pet income")
	local nk = PC.Get("phantom_kitsune")
	if nk then
		T.check(near(TC.IncomePerSecond(hg, { nk }, 1) - TC.IncomePerSecond(hg, {}, 1), petCash(nk) * 1.25), "economy: the prestige multiplier applies to garden pets too")
	end

	-- Collector cap
	T.eq(TC.CollectorCap(home({ Press1 = 1 })), 0, "economy: no Collector, no cap (nothing piles up)")
	local cap1 = TC.CollectorCap(h1)
	local ce = TC.Get("Collector").Effects[1]
	T.eq(cap1, floor(ce.FlatCap + ce.CapSeconds * i1), "economy: CollectorCap = FlatCap + CapSeconds x income")
	local hv = home({ Press1 = 1, Collector = 1, Vault = 2 })
	T.check(TC.CollectorCap(hv) > cap1, "economy: the Vault raises the Collector cap (" .. cap1 .. " -> " .. TC.CollectorCap(hv) .. ")")
	T.check(TC.CollectorCap(h1, 1000) > TC.CollectorCap(h1), "economy: a passed income (with the garden) raises the cap")
	local hgc = { Stations = { Press1 = 1, Collector = 1, Garden = 1 }, Garden = { [1] = "starlight_unicorn" }, Prestige = 0 }
	T.check(TC.CollectorCap(hgc) > cap1, "economy: ...and so do the pets listed in home.Garden")

	-- offline earnings
	T.eq(TC.OfflineEarnings(h1, 3600, 100), 0, "economy: no Vault, no offline earnings")
	local ve = TC.Get("Vault").Effects[2]
	T.eq(TC.OfflineEarnings(hv, 60, 100), 0, "economy: absences shorter than OfflineMinSeconds pay nothing")
	T.eq(TC.OfflineEarnings(hv, 1800, 100), floor(100 * 1800 * ve.OfflinePercent), "economy: offline pays OfflinePercent of the income")
	T.eq(TC.OfflineEarnings(hv, 48 * 3600, 100), floor(100 * ve.OfflineHours * 3600 * ve.OfflinePercent), "economy: ...for at most OfflineHours")
	local amount, info = TC.OfflineEarnings(hv, 7200, 50)
	T.check(type(info) == "table" and info.Seconds > 0 and amount > 0, "economy: OfflineEarnings also returns { Seconds, Percent, MaxHours }")
	local best = TC.Get("Vault").Effects[TC.Get("Vault").MaxLevel]
	T.check(best.OfflinePercent * best.OfflineHours <= 2 and best.OfflinePercent * best.OfflineHours >= 0.5,
		"economy: the best Vault pays between 30 min and 2 h of active income (meaningful but capped): " .. fmt(best.OfflinePercent * best.OfflineHours * 60, 0) .. " min")

	-- XP curve, food, fusion
	local prev = 0
	local okXp = true
	for lv = 1, TC.PetXp.MaxLevel - 1 do
		local x = TC.XpToNext(lv)
		okXp = okXp and x >= prev and x > 0
		prev = x
	end
	T.check(okXp and TC.XpToNext(TC.PetXp.MaxLevel) == huge, "economy: XpToNext rises up to MaxLevel and is math.huge there (an XP loop always stops)")
	T.check(TC.XpToNext(0) == TC.XpToNext(1) and TC.XpToNext(nil) == TC.XpToNext(1) and TC.XpToNext(1e9) == huge, "economy: XpToNext treats junk as level 1 and huge levels as max")
	T.check(TC.CookSecondsFor("Snack", 1) == TC.FoodsById.Snack.CookSeconds and TC.CookSecondsFor("Feast", 1) == nil and TC.CookSecondsFor("Snack", 5) < TC.CookSecondsFor("Snack", 1),
		"economy: Kitchen levels unlock recipes and cook faster")
	local up = TC.FusionCost("Upgrade", "Rare", "Golden")
	local up2 = TC.FusionCost("Upgrade", "Rare", "Golden", 3)
	T.check(type(up) == "table" and up.Tokens > 0 and up2.Tokens < up.Tokens, "economy: FusionCost Upgrade costs Tokens by rarity, cheaper with Fusion Machine levels")
	local mixM = TC.FusionCost("Mix", "Mythic")
	local mixC = TC.FusionCost("Mix", "Common")
	T.check(mixM and mixM.Gems and mixM.Gems > 0 and mixC and mixC.Tokens and mixC.Tokens > 0, "economy: Mix costs Tokens, Gems for Mythic / Secret inputs")
	T.check(TC.PrestigeGems(1) == TC.Prestige.GemReward and TC.PrestigeGems(99) == TC.Prestige.GemRewardMin, "economy: PrestigeGems starts at GemReward and never drops below GemRewardMin")
end

local function junkChecks(TC)
	local junk = { nil, false, 5, "x", {}, { Stations = "x" }, { Stations = { Press1 = "abc", House = 99, Collector = 0 / 0, Garden = -1 }, Prestige = "z" }, { Stations = { House = 4 }, Prestige = -3 } }
	local errors = {}
	for i = 1, 8 do
		local h = junk[i]
		local calls = {
			function() return TC.AvailablePads(h) end,
			function() return TC.HomeLevelOf(h) end,
			function() return TC.IncomePerSecond(h, { "nope", false, { Def = 5 }, 0 / 0, -4, { Income = 1 / 0 } }, "q") end,
			function() return TC.CollectorCap(h, "x") end,
			function() return TC.OfflineEarnings(h, 0 / 0, -1) end,
			function() return TC.OfflineEarnings(h, 99999, 1 / 0) end,
			function() return TC.CheckPurchase and TC.CheckPurchase(h, 7) end,
			function() return TC.StationsAfterPrestige(h) end,
		}
		for j, fn in ipairs(calls) do
			local ok, err = pcall(fn)
			if not ok then
				errors[#errors + 1] = "junk " .. i .. " call " .. j .. ": " .. tostring(err)
			end
		end
	end
	local extra = {
		function() return TC.PriceFor("Press1", 0) end, function() return TC.PriceFor("Press1", 11) end,
		function() return TC.PriceFor(nil, nil) end, function() return TC.XpToNext("x") end,
		function() return TC.FusionCost("Nope", "Rare") end, function() return TC.FusionCost("Mix", "Nope") end,
		function() return TC.Get(nil) end, function() return TC.FormatCash and TC.FormatCash(1234567) end,
	}
	for j, fn in ipairs(extra) do
		local ok, err = pcall(fn)
		if not ok then
			errors[#errors + 1] = "extra " .. j .. ": " .. tostring(err)
		end
	end
	T.check(#errors == 0, "economy: junk input never errors (pads, Home Level, income, cap, offline, prices, XP, fusion)", table.concat(errors, " | "))
	T.check(TC.PriceFor("Press1", 0) == nil and TC.PriceFor("Press1", 11) == nil, "economy: PriceFor is nil outside 1..MaxLevel")
	local nan = TC.IncomePerSecond({ Stations = { Press1 = 1, Collector = 1, Garden = 3 } }, { 0 / 0, -4, { Income = 1 / 0 } }, 0)
	T.check(nan == nan and nan ~= huge and near(nan, TC.Get("Press1").Effects[1].Income), "economy: NaN / negative / infinite garden entries earn nothing", tostring(nan))
	local big = TC.IncomePerSecond({ Stations = { Press1 = 1, Collector = 1 }, Prestige = 1e12 }, {})
	T.check(big == big and big ~= huge, "economy: an absurd prestige count still gives a finite income", tostring(big))
	local offl = TC.OfflineEarnings({ Stations = { Collector = 1, Vault = 1 } }, 99999, 1 / 0)
	T.eq(offl, 0, "economy: an infinite income pays no offline earnings")
end

local function layoutChecks(TC, Config)
	local L = TC.Layout
	local half = L.Half
	T.eq(L.PlotSize, Config.Lobby.PlotSize, "layout: the yard is Config.Lobby.PlotSize studs (" .. tostring(L.PlotSize) .. ")")
	local function rect(def)
		return TC.FootprintRect(def.Slot.CFrame, def.Slot.Footprint)
	end
	local function pos(def)
		return def.Slot.CFrame.Position
	end
	local house = TC.Get("House")
	T.check(pos(house).Z > half * 0.5 and rect(house)[4] <= half, "layout: the house stands at the back of the yard (z " .. fmt(pos(house).Z) .. ")")
	local side = true
	for _, id in ipairs({ "Press1", "Press2", "Press3", "Press4", "Collector" }) do
		side = side and rect(TC.Get(id))[2] < 0
	end
	T.check(side, "layout: presses + Collector on one side (-X)")
	T.check(rect(TC.Get("Garden"))[1] > 0, "layout: the garden on the opposite side (+X)")
	local conv = L.Conveyor
	local cr = rect(TC.Get("Collector"))
	local behind = true
	for _, id in ipairs({ "Press1", "Press2", "Press3", "Press4" }) do
		local r = rect(TC.Get(id))
		local z = pos(TC.Get(id)).Z
		behind = behind and conv.Start.X < r[1] and z <= math.max(conv.Start.Z, conv.Finish.Z) and z >= math.min(conv.Start.Z, conv.Finish.Z)
	end
	T.check(behind and conv.Finish.X >= cr[1] and conv.Finish.X <= cr[2] and abs(conv.Finish.Z - cr[4]) < 1.5,
		"layout: the conveyor runs behind every press and ends in the Collector")
	-- decor along the fence / path
	for _, id in ipairs({ "DecorFlowers", "DecorBanners" }) do
		local r = rect(TC.Get(id))
		T.check(r[3] <= -half + 3, "layout: " .. id .. " lines the front fence")
	end
	T.check(TC.Get("DecorFence").Slot.Perimeter == true, "layout: the fence decor follows the whole fence line")
	T.check(rect(TC.Get("DecorPodium"))[1] < half - 12 and rect(TC.Get("DecorPodium"))[2] > half - 12 and abs(pos(TC.Get("DecorPodium")).Z - (-half + 10)) < 0.01,
		"layout: the Pet Podium decor surrounds the lobby's podium (24, -26)")
	-- pads in front of their stations (non-decor)
	local front = T.tally("layout: every station's pad is in front of it (the side its CFrame looks at)")
	for _, def in ipairs(TC.Stations) do
		if def.Kind ~= "Decor" then
			local p = def.Slot.Pad.Position
			local c = pos(def)
			local look = def.Slot.CFrame.LookVector
			front:case((p - c):Dot(look) > 0, def.Id)
		end
	end
	front:report()
	-- the gate opening and the spawn stay clear
	local clear = true
	local blockers = {}
	for _, def in ipairs(TC.Stations) do
		local slot = def.Slot
		if not slot.Walkable and not slot.Perimeter then
			local r = rect(def)
			if r[1] < L.GateWidth / 2 and r[2] > -L.GateWidth / 2 and r[3] < -half + 6 then
				clear = false
				blockers[#blockers + 1] = def.Id
			end
			if L.Spawn.X > r[1] and L.Spawn.X < r[2] and L.Spawn.Z > r[3] and L.Spawn.Z < r[4] then
				clear = false
				blockers[#blockers + 1] = def.Id .. " (spawn)"
			end
		end
	end
	T.check(clear, "layout: nothing solid blocks the gate opening or the home spawn", table.concat(blockers, ", "))
	-- pet spots
	local garden = TC.Get("Garden")
	local spotsOk = #(garden.Slot.Spots or {}) >= garden.Effects[garden.MaxLevel].Slots
	for _, v in ipairs(garden.Slot.Spots or {}) do
		local fp = garden.Slot.Footprint
		spotsOk = spotsOk and abs(v.X) <= fp.X / 2 and abs(v.Z) <= fp.Z / 2
	end
	T.check(spotsOk, "layout: the garden has a pet spot for every slot, inside its footprint")
	local gym = TC.Get("Gym")
	T.check(#(gym.Slot.Spots or {}) >= gym.Effects[gym.MaxLevel].Slots, "layout: the gym has a spot for every training slot")
	-- paths touch every pad
	local onPath = T.tally("layout: every pad touches a stone path (Layout.Paths) or the gate walk")
	local function nearPath(p)
		for _, path in ipairs(L.Paths) do
			local a, b, w = path.Start, path.Finish, path.Width
			local x0, x1 = math.min(a.X, b.X) - w / 2 - 3, math.max(a.X, b.X) + w / 2 + 3
			local z0, z1 = math.min(a.Z, b.Z) - w / 2 - 3, math.max(a.Z, b.Z) + w / 2 + 3
			if p.X >= x0 and p.X <= x1 and p.Z >= z0 and p.Z <= z1 then
				return true
			end
		end
		return false
	end
	for _, def in ipairs(TC.Stations) do
		onPath:case(nearPath(def.Slot.Pad.Position), def.Id)
	end
	onPath:case(nearPath(TC.Get("Prestige").Slot.Pad.Position), "Prestige")
	onPath:report()
	-- reachability from the gate (flood fill; Validate checks it too, this reports which pad)
	local reach = TC.ReachablePads(1, 1)
	local unreachable = {}
	for id, ok in pairs(reach) do
		if not ok then
			unreachable[#unreachable + 1] = id
		end
	end
	T.check(#unreachable == 0, "layout: a player (2 studs wide) can walk from the gate to every pad", table.concat(unreachable, ", "))
end

S.p2_economy = guarded("p2_economy", function()
	local Config = K.config()
	local PC = K.M["shared/PetCatalog"]
	local before = #game:GetDescendants()
	local TC, err = loadCatalog()
	if not T.check(TC ~= nil, "economy: shared/TycoonCatalog loads", err) then
		return
	end
	local again = loadCatalog()
	T.check(again == TC, "economy: requiring it twice gives the same table")
	apiChecks(TC)
	local ok, okValid, problems = pcall(TC.Validate)
	T.check(ok and okValid == true and type(problems) == "table" and #problems == 0, "economy: TycoonCatalog.Validate() passes",
		ok and table.concat(problems or {}, " | ") or tostring(okValid))
	if type(PC) == "table" and type(Config) == "table" then
		simChecks(TC, PC, Config)
		padChecks(TC)
		incomeChecks(TC, PC, Config)
	else
		T.fail("economy: PetCatalog and Config are loaded (load_modules)")
	end
	junkChecks(TC)
	layoutChecks(TC, Config)
	T.eq(#game:GetDescendants(), before, "economy: the catalog is pure (no Instances created)")
	K.flushErrors("p2_economy")
end)

return S
