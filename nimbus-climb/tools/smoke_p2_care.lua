-- smoke_p2_care.lua: Phase 2 pet care (ARCHITECTURE_V3.md "Phase 2: Tycoon homes" items 3-4 and the PetCareService
-- paragraph of the "Phase 2 build contract": server/Services/PetCareService.lua + PetCatalog.GetStats / levels).
-- Loaded by tools/smoke.py in the SERVER world:
--   p2care_stats      (pure) PetCatalog.GetStats(petId, level, tier) = base x RarityScale x level factor x tier for
--                     every pet, keys ("cat@Golden"), defs (tier copies, hybrids), junk levels / tiers, the same numbers
--                     as TycoonCatalog.PetIncome (the Garden's Cash/s); LevelCap by rarity, MaxPetLevel, LevelFactor,
--                     TierMultiplier
--   p2care_kitchen    (booted) the API, signals and the PetCare remote; cooking needs a claimed home with a Kitchen;
--                     Cook pays Price x n at once, one dish at a time for CookSeconds / CookSpeed, dishes go into Food,
--                     the queue is replicated (KitchenQueue / KitchenReadyAt / KitchenDishSeconds); recipes by Kitchen
--                     level, the queue size, orders bigger than the Cash or the queue cook what fits, faster Kitchens,
--                     cooking goes on while the player is elsewhere (in a match), the Kitchen's Cook / Feed prompts
--                     (owner only, rebuilt with the Kitchen), the FeedBowl feeds the pets that follow, leaving refunds
--                     the dishes that were not done (in the save)
--   p2care_feed       Feed gives the food's XP, level-ups toast the new stats (Income for Economy pets, Power / Health
--                     / Speed for Combat pets), tier copies and hybrids level on their own; refusals use no food; the
--                     Garden pays exactly GetStats(...).Income for a fed Economy pet; level caps by rarity (feeding
--                     stops exactly at the cap, a capped pet is refused before food is used, GrantXp respects caps)
--   p2care_gym        GymSet: needs a Gym, Combat pets only, owned, unlocked slots, not a Garden pet; replicated
--                     GymPets; XP per minute by Gym level (granted every 10 s) with level-up toasts; no training for a
--                     pet that also sits in the Garden or without a claimed home; move / auto slot / remove by key /
--                     clear; the cap stops training (toast)
--   p2care_exploits   junk / NaN / huge / wrong-type PetCare arguments change nothing and raise nothing; spam (one Cook
--                     and one Feed per cooldown, the burst budget, every eaten food gives exactly its XP); someone
--                     else's prompts and pets; Cash never negative. Leaves a player cooking for p2care_shutdown
--   p2care_shutdown   (after the "shutdown" scenario) BindToClose refunded that player's unfinished dish in the save
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local K = _G.K
local CONTEXT = (ARGS and ARGS.context) or "server"

local S = {}
if CONTEXT ~= "server" then
	return S
end

local abs, floor, ceil = math.abs, math.floor, math.ceil
local CLOSE = nil -- p2care_exploits leaves a player cooking for p2care_shutdown: { UserId, Cash }
local advance, config, mod = K.advance, K.config, K.mod

local function near(a, b, tol)
	return type(a) == "number" and type(b) == "number" and abs(a - b) <= (tol or 1e-6)
end

-- advances the fake clock until pred() holds (at most maxSeconds); true when it held
local function waitUntil(pred, maxSeconds)
	local waited = 0
	while not pred() and waited < maxSeconds do
		K.advance(0.25)
		waited = waited + 0.25
	end
	return pred() and true or false
end

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

local function PCS()
	return requireAt("server/Services/PetCareService")
end
local function TS()
	return requireAt("server/Services/TycoonService")
end
local function TC()
	return requireAt("shared/TycoonCatalog")
end
local function PK()
	return requireAt("shared/PetKeys")
end
local function PC()
	return requireAt("shared/PetCatalog")
end

----------------------------------------------------------------------------------------------------
-- helpers (booted scenarios)
----------------------------------------------------------------------------------------------------
local userSeq = 0
local function join(prefix)
	userSeq = userSeq + 1
	local p = Mock.AddPlayer(prefix .. userSeq, 963000 + userSeq)
	advance(1.0)
	return p
end

local function leave(p)
	if p and p.Parent then
		Mock.RemovePlayer(p)
	end
	advance(0.6)
end

local function spots()
	return (K.W.lobbyInfo and K.W.lobbyInfo.Spots) or {}
end

local function freeIndex()
	local SS = mod("SpotService")
	for i = 1, config().Lobby.SpotCount do
		if spots()[i] and not SS.GetOwner(i) then
			return i
		end
	end
	return nil
end

-- claims the first free plot (TycoonService.Claim); returns its index or nil
local function claimFree(p)
	local Ty = TS()
	local index = freeIndex()
	if not Ty or not index then
		return nil
	end
	local ok = Ty.Claim(p, index)
	advance(0.6)
	if ok then
		return index
	end
	return nil
end

local function remote(name)
	return K.remoteFolder():FindFirstChild(name)
end

local function care(p, ...)
	Mock.FromClient(remote("PetCare"), p, ...)
end

local function DS()
	return mod("DataService")
end

local function cashOf(p)
	return DS().GetCash(p)
end

local function foodOf(p, id)
	return DS().GetFood(p, id)
end

local function homeOf(p)
	return DS().GetHome(p)
end

-- writes station levels straight into the saved home (Home.Level follows), then lets the services sync the plot
local function setStations(p, map)
	local Cat = TC()
	DS().MutateHome(p, function(h)
		for id, lv in pairs(map) do
			if lv > 0 then
				h.Stations[id] = lv
			else
				h.Stations[id] = nil
			end
		end
		h.Level = Cat.HomeLevelOf(h)
	end)
	advance(2.1) -- one TycoonService tick builds the stations, one PetCareService tick dresses the Kitchen
end

local function givePet(p, key, n)
	local prof = DS().GetProfile(p)
	local ok = PK().Add(prof, key, n or 1)
	DS().MarkDirty(p)
	return ok
end

-- a non-Secret catalog pet of that role (and rarity), skipping `not1` / `not2`
local function pickPet(role, rarity, not1, not2)
	for _, def in ipairs(PC().Pets) do
		if def.Role == role and def.Rarity ~= "Secret" and (rarity == nil or def.Rarity == rarity) and def.Id ~= not1 and def.Id ~= not2 then
			return def
		end
	end
	return nil
end

-- total XP of a pet copy (level and XP folded into one number)
local function totalXp(p, key)
	local level, xp = DS().GetPetLevel(p, key)
	return TC().XpForLevel(level) + xp, level, xp
end

local function toasted(p, needle, kind, mark)
	for _, e in ipairs(K.remotesFor("Notify", p.UserId, mark or 0)) do
		if string.find(tostring(e.args[1]), needle, 1, true) and (kind == nil or e.args[2] == kind) then
			return true
		end
	end
	return false
end

-- the last few toasts of a player (failure details)
local function toastsSince(p, mark)
	local out = {}
	for _, e in ipairs(K.remotesFor("Notify", p.UserId, mark or 0)) do
		out[#out + 1] = tostring(e.args[1])
	end
	local first = math.max(1, #out - 3)
	local tail = {}
	for i = first, #out do
		tail[#tail + 1] = out[i]
	end
	return table.concat(tail, " | ")
end

local function serverNow()
	return workspace:GetServerTimeNow()
end

-- the toast formats of PetCareService (income per second, compact stat numbers)
local function rateText(n)
	local s = string.format("%.1f", floor(n * 10 + 0.5) / 10)
	s = string.gsub(s, "%.0$", "")
	return "$" .. s .. "/s"
end

local function compactText(n)
	if n >= 1000 then
		local units = { { 1e6, "M" }, { 1e3, "K" } }
		for _, u in ipairs(units) do
			if n >= u[1] then
				local x = n / u[1]
				local s
				if x >= 100 then
					s = string.format("%d", floor(x))
				else
					s = string.format("%.1f", floor(x * 10) / 10)
					s = string.gsub(s, "%.0$", "")
				end
				return s .. u[2]
			end
		end
	end
	return tostring(floor(n + 0.5))
end

local function kitchenOf(index)
	local info = spots()[index]
	local home = info and info.Folder:FindFirstChild("Home")
	return (home and home:FindFirstChild("Station_Kitchen")) or (info and info.Folder:FindFirstChild("Station_Kitchen", true))
end

local function carePrompts(model)
	local cook, feed = {}, nil
	for _, d in ipairs(model and model:GetDescendants() or {}) do
		if d:IsA("ProximityPrompt") then
			if d.Name == "CookPrompt" then
				cook[tostring(d:GetAttribute("FoodId"))] = d
			elseif d.Name == "FeedPrompt" then
				feed = d
			end
		end
	end
	return cook, feed
end

local function count(map)
	local n = 0
	for _ in pairs(map) do
		n = n + 1
	end
	return n
end

local function storedProfile(userId)
	return Mock.DataStore.Data[config().Tokens.DataStoreName .. "/u_" .. userId]
end

----------------------------------------------------------------------------------------------------
-- p2care_stats (pure)
----------------------------------------------------------------------------------------------------
S.p2care_stats = guarded("p2care_stats", function()
	local Config = config()
	local PCat, Cat, Keys = PC(), TC(), PK()
	if not T.check(PCat ~= nil and type(PCat.GetStats) == "function", "care stats: PetCatalog.GetStats loads") then
		return
	end
	for _, fn in ipairs({ "LevelCap", "MaxPetLevel", "LevelFactor", "TierMultiplier", "StatsOf" }) do
		T.check(type(PCat[fn]) == "function", "care stats: PetCatalog." .. fn .. " is a function")
	end
	local top = PCat.MaxPetLevel()
	T.eq(top, Cat and Cat.MaxPetLevel or PCat.MaxLevel, "care stats: MaxPetLevel() is the top of the XP curve (TycoonCatalog.MaxPetLevel)")

	-- the formula: every pet, several levels, three tiers
	local tiers = { Normal = 1, Golden = 1.5, Rainbow = 2.5 }
	local formula = T.tally("care stats: GetStats(petId, level, tier) = base x RarityScale x (1 + 0.1 x (level - 1)) x tier (every pet; levels 1, 2, 7, top; 3 tiers)")
	for _, def in ipairs(PCat.Pets) do
		local scale = Config.PetStats.RarityScale[def.Rarity] or 1
		for _, level in ipairs({ 1, 2, 7, top }) do
			for tier, m in pairs(tiers) do
				local got = PCat.GetStats(def.Id, level, tier)
				local ok = type(got) == "table"
				for _, stat in ipairs({ "Income", "Power", "Health", "Speed" }) do
					local want = def.Stats[stat] * scale * (1 + 0.1 * (level - 1)) * m
					ok = ok and T.finite(got[stat]) and abs(got[stat] - want) <= 1e-6 * math.max(1, want)
				end
				formula:case(ok, def.Id .. " Lv " .. level .. " " .. tier)
			end
		end
	end
	formula:report()

	local def = PCat.Pets[1]
	local id = def.Id
	local function same(a, b)
		if type(a) ~= "table" or type(b) ~= "table" then
			return false
		end
		for _, stat in ipairs({ "Income", "Power", "Health", "Speed" }) do
			if not near(a[stat], b[stat], 1e-9 * math.max(1, abs(b[stat] or 0))) then
				return false
			end
		end
		return true
	end
	T.check(same(PCat.GetStats(id, 3), PCat.GetStats(id, 3, "Normal")) and same(PCat.GetStats(id, 3, nil), PCat.GetStats(id, 3, "Normal")),
		"care stats: no tier = Normal (the Phase 1 two-argument form is unchanged)")
	T.check(same(PCat.GetStats(id .. "@Golden", 3), PCat.GetStats(id, 3, "Golden")) and same(PCat.GetStats(id .. "@Rainbow", 3), PCat.GetStats(id, 3, "Rainbow")),
		"care stats: a pet key carries its tier ('" .. id .. "@Golden')")
	T.check(same(PCat.GetStats(id .. "@Golden", 3, "Rainbow"), PCat.GetStats(id, 3, "Rainbow")), "care stats: an explicit tier wins over the key's")
	T.check(same(PCat.GetStats(id, top + 25), PCat.GetStats(id, top)) and same(PCat.GetStats(id, 1e9), PCat.GetStats(id, top)),
		"care stats: levels above the top of the curve count as the top (like TycoonCatalog.PetIncome)")
	local junkLevels = T.tally("care stats: junk levels (0, -3, NaN, -inf, inf, 'abc', false, {}) count as level 1; 2.9 counts as 2, '5' as 5")
	for _, lv in ipairs({ 0, -3, 0 / 0, -1 / 0, 1 / 0, "abc", false }) do
		junkLevels:case(same(PCat.GetStats(id, lv), PCat.GetStats(id, 1)), tostring(lv))
	end
	junkLevels:case(same(PCat.GetStats(id, {}), PCat.GetStats(id, 1)), "table")
	junkLevels:case(same(PCat.GetStats(id, 2.9), PCat.GetStats(id, 2)), "2.9")
	junkLevels:case(same(PCat.GetStats(id, "5"), PCat.GetStats(id, 5)), "'5' (tonumber, like Phase 1)")
	junkLevels:report()
	local junkTiers = T.tally("care stats: unknown tiers count as Normal, a number is a multiplier, NaN / negative count as x1")
	junkTiers:case(same(PCat.GetStats(id, 2, "Diamond"), PCat.GetStats(id, 2)), "Diamond")
	junkTiers:case(same(PCat.GetStats(id, 2, 0 / 0), PCat.GetStats(id, 2)), "NaN")
	junkTiers:case(same(PCat.GetStats(id, 2, -2), PCat.GetStats(id, 2)), "-2")
	local x2 = PCat.GetStats(id, 2, 2)
	junkTiers:case(x2 and near(x2.Power, PCat.GetStats(id, 2).Power * 2, 1e-9), "2")
	junkTiers:report()
	local okNil1, r1 = pcall(PCat.GetStats, "ghost_pet", 3)
	local okNil2, r2 = pcall(PCat.GetStats, nil)
	local okNil3, r3 = pcall(PCat.GetStats, 42, 2, "Golden")
	local okNil4, r4 = pcall(PCat.GetStats, "hyb:h1", 2)
	T.check(okNil1 and okNil2 and okNil3 and okNil4 and r1 == nil and r2 == nil and r3 == nil and r4 == nil,
		"care stats: unknown pets, nil, numbers and hybrid keys without their profile answer nil (never raise)")

	-- defs: tier copies and hybrids (PetKeys.DefOf)
	if Keys then
		local gdef = Keys.DefOf(id .. "@Golden")
		T.check(gdef ~= nil and same(PCat.GetStats(gdef, 4), PCat.GetStats(id, 4, "Golden")) and same(PCat.StatsOf(gdef, 4), PCat.GetStats(id, 4, "Golden")),
			"care stats: a tier copy's def (PetKeys.DefOf) gets its tier (StatMultiplier) through GetStats / StatsOf")
		local other = nil
		for _, d in ipairs(PCat.Pets) do
			if d.Rarity ~= def.Rarity and d.Rarity ~= "Secret" then
				other = d
				break
			end
		end
		local profile = { Pets = {}, Tiers = {}, Hybrids = {} }
		Keys.Add(profile, "hyb:care1", 1, { Body = id, Style = other.Id, Tier = "Normal" })
		local hdef = Keys.DefOf("hyb:care1", profile)
		local hs = hdef and PCat.GetStats(hdef, 5)
		local ok = hs ~= nil
		if ok then
			local scale = Config.PetStats.RarityScale[hdef.Rarity] or 1
			for _, stat in ipairs({ "Income", "Power", "Health", "Speed" }) do
				ok = ok and near(hs[stat], hdef.Stats[stat] * scale * 1.4, 1e-6 * math.max(1, hs[stat]))
			end
		end
		T.check(ok, "care stats: a fused hybrid's def: its averaged base stats x the higher rarity's scale x level")
		T.eq(PCat.LevelCap(hdef), PCat.LevelCap(hdef.Rarity), "care stats: a hybrid's level cap is its (higher) rarity's")
	end

	-- the Garden pays what GetStats says (TycoonCatalog.PetIncome)
	if Cat and type(Cat.PetIncome) == "function" then
		local income = T.tally("care stats: GetStats(...).Income == TycoonCatalog.PetIncome (the Garden's Cash/s) for every Economy pet, levels 1/5/top, 3 tiers")
		for _, d in ipairs(PCat.Pets) do
			if d.Role == "Economy" then
				for _, level in ipairs({ 1, 5, top }) do
					for tier in pairs(tiers) do
						local a = PCat.GetStats(d.Id, level, tier).Income
						local b = Cat.PetIncome({ Def = d, Level = level, Tier = tier })
						income:case(near(a, b, 1e-9 * math.max(1, b)), d.Id .. " Lv " .. level .. " " .. tier .. ": " .. tostring(a) .. " vs " .. tostring(b))
					end
				end
				income:case(near(PCat.GetStats(d.Id .. "@Golden").Income, Cat.PetIncome(d.Id .. "@Golden"), 1e-9), d.Id .. "@Golden key")
			end
		end
		income:report()
	end

	-- level caps by rarity
	local lastCap, capsOk, capText = 0, true, {}
	local rarities = {}
	for _, r in ipairs(Config.Rarities) do
		rarities[#rarities + 1] = r
	end
	table.sort(rarities, function(a, b)
		return a.Order < b.Order
	end)
	for _, r in ipairs(rarities) do
		local cap = PCat.LevelCap(r.Id)
		capText[#capText + 1] = r.Id .. " " .. tostring(cap)
		if type(cap) ~= "number" or cap < 1 or cap > top or cap ~= floor(cap) or cap < lastCap then
			capsOk = false
		else
			lastCap = cap
		end
	end
	T.check(capsOk, "care caps: every rarity has a whole level cap in 1..top that never drops with rarity", table.concat(capText, ", "))
	T.check(PCat.LevelCap("Common") < PCat.LevelCap("Mythic") and PCat.LevelCap("Mythic") <= PCat.LevelCap("Secret"),
		"care caps: rarer pets grow further (" .. table.concat(capText, ", ") .. ")")
	local capForms = T.tally("care caps: LevelCap(rarity) == LevelCap(petId) == LevelCap(key) == LevelCap(def) for every pet")
	for _, d in ipairs(PCat.Pets) do
		local c = PCat.LevelCap(d.Rarity)
		capForms:case(PCat.LevelCap(d.Id) == c and PCat.LevelCap(d.Id .. "@Rainbow") == c and PCat.LevelCap(d) == c, d.Id)
	end
	capForms:report()
	T.check(PCat.LevelCap("ghost_pet") == nil and PCat.LevelCap(nil) == nil and PCat.LevelCap(5) == nil,
		"care caps: unknown pets / junk answer nil")

	-- small helpers
	T.check(PCat.LevelFactor(1) == 1 and near(PCat.LevelFactor(11), 2, 1e-9) and PCat.LevelFactor(top + 9) == PCat.LevelFactor(top) and PCat.LevelFactor(-4) == 1,
		"care stats: LevelFactor = 1 + 0.1 x (level - 1), clamped like GetStats")
	T.check(PCat.TierMultiplier("Normal") == 1 and PCat.TierMultiplier("Golden") == 1.5 and PCat.TierMultiplier("Rainbow") == 2.5
		and PCat.TierMultiplier(id .. "@Rainbow") == 2.5 and PCat.TierMultiplier(nil) == 1 and PCat.TierMultiplier("Diamond") == 1
		and PCat.TierMultiplier({ Tier = "Golden" }) == 1.5 and PCat.TierMultiplier({ Look = { Finish = "Rainbow" } }) == 2.5,
		"care stats: TierMultiplier(tier | key | def) = 1 / 1.5 / 2.5")
	local agree = true
	for tier, m in pairs(PCat.TierMultipliers) do
		if Keys and Keys.TierMultiplier[tier] ~= m then
			agree = false
		end
		if Cat and Cat.TierMultiplier[tier] ~= m then
			agree = false
		end
	end
	T.check(agree, "care stats: PetCatalog.TierMultipliers == PetKeys.TierMultiplier == TycoonCatalog.TierMultiplier")
end)

----------------------------------------------------------------------------------------------------
-- p2care_kitchen
----------------------------------------------------------------------------------------------------
S.p2care_kitchen = guarded("p2care_kitchen", function()
	if not K.needBoot() then
		return
	end
	local Config = config()
	local Care, Ty, Cat = PCS(), TS(), TC()
	if not T.check(Care ~= nil, "care: server/Services/PetCareService.lua loads") then
		return
	end
	for _, fn in ipairs({ "Init", "Cook", "Feed", "GymSet", "GrantXp", "LevelCap", "GetQueue" }) do
		T.check(type(Care[fn]) == "function", "care: PetCareService." .. fn .. " is a function")
	end
	for _, sig in ipairs({ "Cooked", "Fed", "LevelUp", "GymChanged" }) do
		T.check(type(Care[sig]) == "table" and type(Care[sig].Connect) == "function", "care: signal PetCareService." .. sig)
	end
	T.check(remote("PetCare") ~= nil, "care: the PetCare remote exists")
	if not T.check(Ty ~= nil and Cat ~= nil, "care: (precondition) TycoonService and TycoonCatalog load") then
		return
	end
	local DataS = DS()
	local snack, meal, feast = Cat.FoodById("Snack"), Cat.FoodById("Meal"), Cat.FoodById("Feast")

	local p = join("CareCook")
	DataS.AddCash(p, 100000)
	advance(0.3)
	local mark = K.logSize()
	care(p, "Cook", "Snack", 1)
	advance(0.3)
	T.check(cashOf(p) == 100000 and (p:GetAttribute("KitchenQueue") or "") == "", "care kitchen: no cooking without a claimed home (no Cash taken)")
	T.check(toasted(p, "Claim your home first", "bad", mark), "care kitchen: ...a side toast says to claim a home first", toastsSince(p, mark))
	local index = claimFree(p)
	if not T.check(index ~= nil, "care kitchen: (precondition) the player claims a plot") then
		leave(p)
		return
	end
	mark = K.logSize()
	care(p, "Cook", "Snack", 1)
	advance(0.3)
	T.check(toasted(p, "Build the Kitchen first", "bad", mark) and cashOf(p) == 100000, "care kitchen: a home without a Kitchen cannot cook (no Cash taken)", toastsSince(p, mark))

	setStations(p, { Press1 = 2, Collector = 1, Press2 = 2, Garden = 1, Kitchen = 1 })
	local cooked = {}
	local conn = Care.Cooked:Connect(function(pl, id, n)
		if pl == p then
			cooked[id] = (cooked[id] or 0) + n
		end
	end)
	mark = K.logSize()
	local cash0 = cashOf(p)
	care(p, "Cook", "Snack", 2)
	advance(0.05)
	local t0 = serverNow()
	T.eq(cash0 - cashOf(p), 2 * snack.Price, "care kitchen: Cook 2 Snacks takes 2 x Price in Cash at once")
	T.eq(p:GetAttribute("KitchenQueue"), "Snack,Snack", "care kitchen: the queue is replicated (attribute KitchenQueue, the dish cooking first)")
	local secs = Cat.CookSecondsFor("Snack", 1)
	T.check(near(p:GetAttribute("KitchenReadyAt") - t0, secs, 0.15) and near(p:GetAttribute("KitchenDishSeconds"), secs, 1e-6),
		"care kitchen: KitchenReadyAt / KitchenDishSeconds: the first Snack is ready after CookSecondsFor (" .. secs .. " s at Kitchen 1)",
		tostring(p:GetAttribute("KitchenReadyAt")) .. " - " .. tostring(t0))
	T.check(toasted(p, "Cooking 2 Snacks for $" .. 2 * snack.Price, "info", mark), "care kitchen: a 'Cooking 2 Snacks for $100' side toast", toastsSince(p, mark))
	local q = Care.GetQueue(p)
	T.check(#q == 2 and q[1].FoodId == "Snack" and near(q[2].ReadyIn, 2 * secs, 0.2), "care kitchen: GetQueue lists the dishes with their ready times")
	advance(secs - 1.2)
	T.eq(foodOf(p, "Snack"), 0, "care kitchen: nothing is in Food before its cook time")
	advance(2.3)
	T.eq(foodOf(p, "Snack"), 1, "care kitchen: the first Snack goes into Food when it is done")
	T.eq(p:GetAttribute("KitchenQueue"), "Snack", "care kitchen: ...and leaves the queue")
	advance(secs)
	T.eq(foodOf(p, "Snack"), 2, "care kitchen: the second one a cook time later (one dish at a time)")
	T.eq(p:GetAttribute("KitchenQueue"), "", "care kitchen: the queue is empty afterwards (KitchenReadyAt 0)")
	T.eq(p:GetAttribute("KitchenReadyAt"), 0, "care kitchen: KitchenReadyAt is 0 when idle")
	T.check(toasted(p, "Kitchen: 2 Snacks ready!", "good", mark), "care kitchen: a summary toast 'Kitchen: 2 Snacks ready!' when the queue is done", toastsSince(p, mark))
	T.eq(cooked.Snack, 2, "care kitchen: the Cooked signal reports the 2 Snacks")

	-- recipes by Kitchen level
	mark = K.logSize()
	local cash1 = cashOf(p)
	care(p, "Cook", "Meal", 1)
	advance(0.3)
	T.check(toasted(p, "Upgrade the Kitchen to Lv " .. meal.KitchenLevel, "bad", mark) and cashOf(p) == cash1,
		"care kitchen: a Meal needs Kitchen Lv " .. meal.KitchenLevel .. " (refused, no Cash taken)", toastsSince(p, mark))

	-- the queue size (Kitchen 1: 3 dishes): a bigger order cooks what fits
	local size = Cat.EffectsOf("Kitchen", 1).Queue
	care(p, "Cook", "Snack", 10)
	advance(0.05)
	T.eq(cash1 - cashOf(p), size * snack.Price, "care kitchen: an order for 10 Snacks at Kitchen 1 cooks what fits in its " .. size .. "-dish queue")
	T.eq(select(2, string.gsub(p:GetAttribute("KitchenQueue") or "", "Snack", "")), size, "care kitchen: ...the queue holds " .. size .. " Snacks")
	T.check(toasted(p, "(Kitchen full)", "info", mark), "care kitchen: ...the toast says the Kitchen is full", toastsSince(p, mark))
	advance(0.3)
	local cash2 = cashOf(p)
	care(p, "Cook", "Snack", 1)
	advance(0.3)
	T.check(toasted(p, "The Kitchen is busy (" .. size .. "/" .. size .. " cooking)", "bad", mark) and cashOf(p) == cash2,
		"care kitchen: a full queue refuses more (no Cash taken)", toastsSince(p, mark))
	advance(size * secs + 1.2)
	T.eq(foodOf(p, "Snack"), 2 + size, "care kitchen: every queued dish is delivered")

	-- not enough Cash: the order shrinks to what the Cash pays, then is refused
	DataS.SpendCash(p, cashOf(p) - (snack.Price + 20))
	mark = K.logSize()
	care(p, "Cook", "Snack", 3)
	advance(0.05)
	T.eq(cashOf(p), 20, "care kitchen: an order bigger than the Cash cooks what the Cash pays (1 Snack, $20 left)")
	T.check(toasted(p, "not enough Cash for more", "info", mark), "care kitchen: ...and says so", toastsSince(p, mark))
	advance(0.3)
	care(p, "Cook", "Snack", 1)
	advance(0.3)
	T.check(cashOf(p) == 20 and toasted(p, "Not enough Cash: a Snack costs $" .. snack.Price, "bad", mark), "care kitchen: no Cash, no order (Cash never goes negative)", toastsSince(p, mark))
	advance(secs + 1.2)
	DataS.AddCash(p, 100000)

	-- a better Kitchen cooks faster and better recipes; cooking goes on while the player is elsewhere
	setStations(p, { Kitchen = 5 })
	local fast = Cat.CookSecondsFor("Snack", 5)
	T.check(fast < secs, "care kitchen: (precondition) Kitchen 5 cooks a Snack faster (" .. fast .. " s)")
	local snacks = foodOf(p, "Snack")
	care(p, "Cook", "Snack", 1)
	advance(0.05)
	T.check(near(p:GetAttribute("KitchenDishSeconds"), fast, 1e-6), "care kitchen: CookSeconds shrink with the Kitchen level (CookSpeed): " .. fast .. " s at Lv 5")
	p:SetAttribute(Config.Attr.InMatch, true)
	Mock.Teleport(p, Config.Lobby.Origin + Vector3.new(0, 4, 0))
	advance(fast + 1.2)
	T.eq(foodOf(p, "Snack"), snacks + 1, "care kitchen: the Kitchen keeps cooking while the player is elsewhere (in a match, on the plaza)")
	p:SetAttribute(Config.Attr.InMatch, false)
	advance(0.3)
	local cash3 = cashOf(p)
	care(p, "Cook", "Feast", 1)
	advance(0.05)
	T.check(cash3 - cashOf(p) == feast.Price and p:GetAttribute("KitchenQueue") == "Feast", "care kitchen: Kitchen 5 cooks Feasts")
	advance(Cat.CookSecondsFor("Feast", 5) + 1.2)
	T.eq(foodOf(p, "Feast"), 1, "care kitchen: ...delivered after CookSecondsFor('Feast', 5)")

	-- the Kitchen's prompts (HomeBuilder's Station_Kitchen)
	local model = kitchenOf(index)
	if model then
		local cookPrompts, feedPrompt = carePrompts(model)
		local okAll = cookPrompts.Snack ~= nil and cookPrompts.Meal ~= nil and cookPrompts.Feast ~= nil and count(cookPrompts) == 3
		T.check(okAll, "care prompts: the Kitchen (Lv 5) has a 'Cook' prompt per recipe (Snack, Meal, Feast)")
		local keysSeen, propsOk = {}, okAll
		for foodId, prompt in pairs(cookPrompts) do
			local f = Cat.FoodById(foodId)
			propsOk = propsOk and prompt:GetAttribute("OwnerUserId") == p.UserId and prompt.ActionText == "Cook " .. f.Name
				and string.find(prompt.ObjectText, Cat.FormatCash(f.Price), 1, true) ~= nil and prompt.HoldDuration > 0 and prompt.MaxActivationDistance >= 6
			keysSeen[tostring(prompt.KeyboardKeyCode)] = true
		end
		T.check(propsOk and count(keysSeen) == count(cookPrompts), "care prompts: each reads 'Cook <food>' with its price, belongs to the owner (OwnerUserId), has its own key")
		-- positions: over the Kitchen's footprint, about counter height
		local info = spots()[index]
		local slot = Cat.Get("Kitchen").Slot
		local placed = true
		for _, prompt in pairs(cookPrompts) do
			local att = prompt.Parent
			local world = (att.Parent.CFrame * att.CFrame).Position
			local lp = (info.PlotCFrame * slot.CFrame):PointToObjectSpace(world)
			placed = placed and abs(lp.X) <= slot.Footprint.X / 2 and abs(lp.Z) <= slot.Footprint.Z / 2 and lp.Y > 2 and lp.Y < 7
		end
		T.check(placed, "care prompts: the Cook prompts float over the Kitchen counter (inside its footprint, 2-7 studs up)")
		T.check(feedPrompt ~= nil and feedPrompt.Parent.Name == "FeedBowl" and feedPrompt:GetAttribute("OwnerUserId") == p.UserId,
			"care prompts: the FeedBowl has a 'Feed pets' prompt (owner only)")

		-- E on the Snack prompt cooks one Snack; someone else's E does nothing
		local stranger = join("CareStranger")
		DataS.AddCash(stranger, 1000)
		local cs, cp = cashOf(stranger), cashOf(p)
		Mock.Trigger(cookPrompts.Snack, stranger)
		advance(0.1)
		T.check(cashOf(p) == cp and cashOf(stranger) == cs and p:GetAttribute("KitchenQueue") == "", "care prompts: another player's trigger of the owner's Cook prompt does nothing")
		Mock.Trigger(cookPrompts.Snack, p)
		advance(0.05)
		T.check(cp - cashOf(p) == snack.Price and p:GetAttribute("KitchenQueue") == "Snack", "care prompts: the owner's E on 'Cook Snack' orders one Snack")
		for _ = 1, 15 do
			Mock.Trigger(cookPrompts.Snack, p)
		end
		advance(0.05)
		T.eq(cp - cashOf(p), snack.Price, "care prompts: 15 more presses in the same frame order nothing more (cooldown)")
		advance(fast + 1.2)

		-- the FeedBowl: the pets that follow eat (one food each); without pets it opens the Pets panel
		local petsMark = K.logSize()
		Mock.Trigger(feedPrompt, p)
		advance(0.4)
		local opened = false
		for _, e in ipairs(K.remotesFor("OpenPanel", p.UserId, petsMark)) do
			if e.args[1] == "Pets" then
				opened = true
			end
		end
		T.check(opened and toasted(p, "Equip a pet", "bad", petsMark), "care prompts: the FeedBowl without pets following opens the Pets panel (and says why)", toastsSince(p, petsMark))
		local eco = pickPet("Economy", "Common")
		local combat = pickPet("Combat", "Common")
		givePet(p, eco.Id)
		givePet(p, combat.Id)
		local PetS = mod("PetService")
		PetS.Equip(p, eco.Id)
		PetS.Equip(p, combat.Id)
		advance(0.3)
		local food0 = foodOf(p, "Snack") + foodOf(p, "Feast")
		local xe, xc = totalXp(p, eco.Id), totalXp(p, combat.Id)
		Mock.Trigger(feedPrompt, p)
		advance(0.4)
		T.check(totalXp(p, eco.Id) > xe and totalXp(p, combat.Id) > xc and foodOf(p, "Snack") + foodOf(p, "Feast") == food0 - 2,
			"care prompts: E at the FeedBowl feeds every pet that follows the player one food each")
		stranger.Parent = stranger.Parent -- (keep the stranger for the rebuild check)
		local xs = totalXp(p, eco.Id)
		Mock.Trigger(feedPrompt, stranger)
		advance(0.4)
		T.eq(totalXp(p, eco.Id), xs, "care prompts: another player's trigger of the FeedBowl does nothing")
		leave(stranger)

		-- the prompts follow the Kitchen: a rebuild at Lv 2 has Snack + Meal
		setStations(p, { Kitchen = 2 })
		local model2 = kitchenOf(index)
		local cook2 = carePrompts(model2)
		T.check(model2 ~= nil and cook2.Snack ~= nil and cook2.Meal ~= nil and cook2.Feast == nil and count(cook2) == 2,
			"care prompts: a rebuilt Kitchen (Lv 2) gets the prompts of its recipes again (Snack, Meal)")
		setStations(p, { Kitchen = 5 })
	else
		T.info("*care prompts skipped: no Station_Kitchen model on the plot (HomeBuilder missing?)")
	end

	-- leaving with dishes still cooking refunds them (the save gets the Cash back)
	conn:Disconnect()
	local cashBefore = cashOf(p)
	local feastsBefore = foodOf(p, "Feast")
	advance(0.3)
	care(p, "Cook", "Feast", 2)
	advance(0.05)
	T.eq(cashBefore - cashOf(p), 2 * feast.Price, "care kitchen: (precondition) 2 Feasts ordered")
	local userId = p.UserId
	Mock.DataStore.Latency = 0.2 -- a real DataStore call takes a moment: the leave save is still running when we refund
	leave(p)
	advance(13) -- the leave save, then DataService's retry of the entry that changed meanwhile
	Mock.DataStore.Latency = 0
	local rec = storedProfile(userId)
	T.check(rec ~= nil and rec.Cash == cashBefore, "care kitchen: leaving with dishes still cooking refunds their Cash (in the save)",
		"stored " .. tostring(rec and rec.Cash) .. ", before the order " .. tostring(cashBefore))
	T.check(rec ~= nil and ((type(rec.Food) == "table" and rec.Food.Feast) or 0) == feastsBefore, "care kitchen: ...and the unfinished Feasts do not appear in Food",
		"stored " .. tostring(rec and type(rec.Food) == "table" and rec.Food.Feast) .. ", before " .. feastsBefore)
	K.flushErrors("p2care_kitchen")
	K.flushWarnings("p2care_kitchen")
end)

----------------------------------------------------------------------------------------------------
-- p2care_feed
----------------------------------------------------------------------------------------------------
S.p2care_feed = guarded("p2care_feed", function()
	if not K.needBoot() then
		return
	end
	local Care, Ty, Cat, PCat = PCS(), TS(), TC(), PC()
	if not Care or not Ty or not Cat or not PCat then
		T.fail("care feed: PetCareService, TycoonService, TycoonCatalog and PetCatalog load")
		return
	end
	local DataS = DS()
	local p = join("CareFeed")
	local index = claimFree(p)
	if not T.check(index ~= nil, "care feed: (precondition) the player claims a plot") then
		leave(p)
		return
	end
	setStations(p, { Press1 = 2, Collector = 1, Press2 = 2, Garden = 2, Kitchen = 1 })
	local eco = pickPet("Economy", "Common")
	local combat = pickPet("Combat", "Common")
	if not T.check(eco ~= nil and combat ~= nil, "care feed: (precondition) the catalog has Common Economy and Combat pets") then
		leave(p)
		return
	end
	givePet(p, eco.Id)
	givePet(p, combat.Id)
	DataS.AddFood(p, "Snack", 10)
	local snack = Cat.FoodById("Snack")
	local need1 = Cat.XpToNext(1)

	local fed, ups = {}, {}
	local c1 = Care.Fed:Connect(function(pl, key, foodId, levels)
		if pl == p then
			fed[#fed + 1] = { key, foodId, levels }
		end
	end)
	local c2 = Care.LevelUp:Connect(function(pl, key, level, source)
		if pl == p then
			ups[#ups + 1] = { key, level, source }
		end
	end)
	local mark = K.logSize()
	care(p, "Feed", eco.Id, "Snack")
	advance(0.15)
	local lv, xp = DataS.GetPetLevel(p, eco.Id)
	T.check(lv == 2 and xp == snack.Xp - need1, "care feed: a Snack gives its " .. snack.Xp .. " XP: Lv 1 -> 2 (XpToNext(1) = " .. need1 .. ")", lv .. "/" .. xp)
	T.eq(foodOf(p, "Snack"), 9, "care feed: ...and one Snack is eaten")
	local s2 = PCat.GetStats(eco.Id, 2)
	T.check(toasted(p, eco.Name .. " reached Lv 2! Income " .. rateText(s2.Income), "good", mark),
		"care feed: a level-up toast with the new stats (Economy: 'Income $x/s')", toastsSince(p, mark))
	advance(0.3)
	T.check(#fed == 1 and fed[1][1] == eco.Id and fed[1][2] == "Snack" and fed[1][3] == 1, "care feed: Fed fired (player, key, foodId, levelsGained)")
	T.check(#ups == 1 and ups[1][1] == eco.Id and ups[1][2] == 2 and ups[1][3] == "Feed", "care feed: LevelUp fired (player, key, 2, 'Feed')")
	care(p, "Feed", eco.Id, "Snack")
	advance(0.15)
	local need2 = Cat.XpToNext(2)
	T.check(toasted(p, eco.Name .. " ate a Snack: +" .. snack.Xp .. " XP (" .. (2 * snack.Xp - need1) .. "/" .. need2 .. " to Lv 3)", "good", mark),
		"care feed: a feed without a level-up shows the XP and the progress", toastsSince(p, mark))

	-- Combat pets: Power / Health / Speed
	care(p, "Feed", combat.Id, "Snack")
	advance(0.15)
	local cs = PCat.GetStats(combat.Id, 2)
	T.check(toasted(p, combat.Name .. " reached Lv 2! Power " .. compactText(cs.Power) .. ", Health " .. compactText(cs.Health) .. ", Speed " .. compactText(cs.Speed), "good", mark),
		"care feed: a Combat pet's level-up toast shows Power, Health and Speed", toastsSince(p, mark))

	-- refusals use no food
	local refusals = {
		{ eco.Id, "Meal", "You have no Meals", "a food the player has none of" },
		{ pickPet("Economy", nil, eco.Id).Id, "Snack", "You do not own that pet", "a pet the player does not own" },
		{ "!!", "Snack", "Unknown pet", "a junk key" },
		{ eco.Id, "Cake", "Unknown food", "an unknown food" },
	}
	for _, r in ipairs(refusals) do
		local before = foodOf(p, "Snack")
		local x0 = totalXp(p, eco.Id)
		mark = K.logSize()
		advance(0.15)
		care(p, "Feed", r[1], r[2])
		advance(0.15)
		T.check(foodOf(p, "Snack") == before and totalXp(p, eco.Id) == x0 and toasted(p, r[3], "bad", mark),
			"care feed: feeding " .. r[4] .. " is refused ('" .. r[3] .. "'), nothing is eaten", toastsSince(p, mark))
	end

	-- the Garden pays GetStats(...).Income for the fed pet, and more after a level-up
	local okG = Ty.GardenSet(p, 1, eco.Id)
	advance(1.2)
	local lvNow = DataS.GetPetLevel(p, eco.Id)
	local _, parts = Ty.IncomePerSecond(p)
	T.check(okG and near(parts.Garden, PCat.GetStats(eco.Id, lvNow).Income * Cat.PrestigeMultiplier(0), 1e-6),
		"care feed: the Garden pays exactly GetStats(pet, level).Income per second for the fed Economy pet (Lv " .. lvNow .. ")",
		tostring(parts and parts.Garden) .. " vs " .. tostring(PCat.GetStats(eco.Id, lvNow).Income))
	local guard = 0
	while DataS.GetPetLevel(p, eco.Id) == lvNow and guard < 20 do
		guard = guard + 1
		Care.Feed(p, eco.Id, "Snack")
	end
	local lvNext = DataS.GetPetLevel(p, eco.Id)
	local _, parts2 = Ty.IncomePerSecond(p)
	T.check(lvNext == lvNow + 1 and near(parts2.Garden, PCat.GetStats(eco.Id, lvNext).Income, 1e-6) and parts2.Garden > parts.Garden,
		"care feed: feeding it to Lv " .. lvNext .. " raises the Garden income to GetStats(pet, " .. lvNext .. ").Income",
		tostring(parts2 and parts2.Garden))

	-- a Golden copy levels on its own and shows Golden stats
	local golden = eco.Id .. "@Golden"
	givePet(p, golden)
	DataS.AddFood(p, "Snack", 1)
	mark = K.logSize()
	local okGold = Care.Feed(p, golden, "Snack")
	local gs = PCat.GetStats(eco.Id, 2, "Golden")
	T.check(okGold and DataS.GetPetLevel(p, golden) == 2 and DataS.GetPetLevel(p, eco.Id) == lvNext and toasted(p, "Income " .. rateText(gs.Income), "good", mark),
		"care feed: a Golden copy has its own level and its toast shows the Golden (x1.5) stats", toastsSince(p, mark))

	-- a fused hybrid can be fed too (its cap is its higher rarity's)
	local Keys = PK()
	local other = pickPet("Combat", "Rare") or pickPet("Combat", "Uncommon")
	local prof = DataS.GetProfile(p)
	Keys.Add(prof, "hyb:carefeed", 1, { Body = eco.Id, Style = other.Id, Tier = "Normal" })
	DataS.MarkDirty(p)
	DataS.AddFood(p, "Snack", 1)
	local okHyb = Care.Feed(p, "hyb:carefeed", "Snack")
	local hdef = Keys.DefOf("hyb:carefeed", prof)
	T.check(okHyb and DataS.GetPetLevel(p, "hyb:carefeed") == 2 and Care.LevelCap(p, "hyb:carefeed") == PCat.LevelCap(hdef.Rarity),
		"care feed: a fused hybrid eats and levels (its cap is its rarity's: " .. tostring(PCat.LevelCap(hdef.Rarity)) .. ")")

	-- level caps: feeding stops exactly at the cap
	local cap = PCat.LevelCap(eco.Id)
	T.eq(Care.LevelCap(p, eco.Id), cap, "care caps: PetCareService.LevelCap(player, key) = PetCatalog.LevelCap")
	local lv0, xp0 = DataS.GetPetLevel(p, eco.Id)
	local room = Cat.XpForLevel(cap) - (Cat.XpForLevel(lv0) + xp0)
	local feast = Cat.FoodById("Feast")
	local needFeasts = ceil(room / feast.Xp)
	DataS.AddFood(p, "Feast", needFeasts + 3)
	local feasts0 = foodOf(p, "Feast")
	local eaten = 0
	for _ = 1, needFeasts + 5 do
		local ok = Care.Feed(p, eco.Id, "Feast")
		if not ok then
			break
		end
		eaten = eaten + 1
	end
	local lvc, xpc = DataS.GetPetLevel(p, eco.Id)
	T.check(lvc == cap and xpc == 0, "care caps: feeding stops exactly at the " .. eco.Rarity .. " cap (Lv " .. cap .. ", no XP past it)", lvc .. "/" .. xpc)
	T.check(eaten == needFeasts and foodOf(p, "Feast") == feasts0 - needFeasts, "care caps: ...after exactly the Feasts the XP to the cap needs (" .. needFeasts .. ", the last one only partly used)", tostring(eaten))
	mark = K.logSize()
	local feastsLeft = foodOf(p, "Feast")
	advance(0.2)
	care(p, "Feed", eco.Id, "Feast")
	advance(0.15)
	T.check(foodOf(p, "Feast") == feastsLeft and DataS.GetPetLevel(p, eco.Id) == cap and toasted(p, "is at its max level (Lv " .. cap .. ")", "bad", mark),
		"care caps: a capped pet is refused before any food is used ('... is at its max level')", toastsSince(p, mark))
	local given, levels, why = Care.GrantXp(p, eco.Id, 5000, "Battle")
	T.check(given == 0 and levels == 0 and type(why) == "string" and DataS.GetPetLevel(p, eco.Id) == cap, "care caps: GrantXp (other services) never passes the cap either")
	-- GrantXp below the cap
	local cx0 = totalXp(p, combat.Id)
	local g2, l2 = Care.GrantXp(p, combat.Id, 30, "Battle")
	T.check(g2 == 30 and totalXp(p, combat.Id) == cx0 + 30 and type(l2) == "number", "care caps: GrantXp gives XP below the cap")
	-- a pet already above its cap (old data / developer tools) cannot be fed
	DataS.AddPetXp(p, combat.Id, Cat.XpForLevel(PCat.LevelCap(combat.Id) + 3))
	local over = DataS.GetPetLevel(p, combat.Id)
	local okOver = Care.Feed(p, combat.Id, "Snack")
	T.check(over > PCat.LevelCap(combat.Id) and not okOver and DataS.GetPetLevel(p, combat.Id) == over, "care caps: a pet above its cap (old data) is refused, its level stays")

	c1:Disconnect()
	c2:Disconnect()
	leave(p)
	K.flushErrors("p2care_feed")
	K.flushWarnings("p2care_feed")
end)

----------------------------------------------------------------------------------------------------
-- p2care_gym
----------------------------------------------------------------------------------------------------
S.p2care_gym = guarded("p2care_gym", function()
	if not K.needBoot() then
		return
	end
	local Care, Ty, Cat, PCat = PCS(), TS(), TC(), PC()
	if not Care or not Ty or not Cat or not PCat then
		T.fail("care gym: PetCareService, TycoonService, TycoonCatalog and PetCatalog load")
		return
	end
	local DataS = DS()
	local p = join("CareGym")
	local index = claimFree(p)
	if not T.check(index ~= nil, "care gym: (precondition) the player claims a plot") then
		leave(p)
		return
	end
	local info = spots()[index]
	setStations(p, { Press1 = 2, Collector = 1, Press2 = 2, Garden = 1, Kitchen = 1 })
	local combat = pickPet("Combat", "Common")
	local combat2 = pickPet("Combat", nil, combat.Id)
	local combat3 = pickPet("Combat", nil, combat.Id, combat2.Id)
	local eco = pickPet("Economy")
	givePet(p, combat.Id)
	givePet(p, combat2.Id)
	givePet(p, eco.Id)

	local mark = K.logSize()
	care(p, "GymSet", 1, combat.Id)
	advance(0.3)
	T.check(toasted(p, "Build the Gym first", "bad", mark) and homeOf(p).Gym[1] == nil, "care gym: no Gym, no training ('Build the Gym first')", toastsSince(p, mark))
	setStations(p, { Gym = 1 })
	local changed = 0
	local conn = Care.GymChanged:Connect(function(pl)
		if pl == p then
			changed = changed + 1
		end
	end)
	mark = K.logSize()
	care(p, "GymSet", 1, combat.Id)
	advance(0.3)
	T.eq(homeOf(p).Gym[1], combat.Id, "care gym: GymSet(1, key) puts a Combat pet in Gym slot 1 (Home.Gym)")
	T.check(toasted(p, combat.Name .. " is training in the Gym!", "good", mark), "care gym: ...with a side toast", toastsSince(p, mark))
	T.eq(info.Folder:GetAttribute("GymPets"), "1=" .. combat.Id, "care gym: the plot folder replicates GymPets ('1=" .. combat.Id .. "')")
	T.check(changed >= 1, "care gym: GymChanged fired")

	local refusals = {
		{ 1, eco.Id, "Only Combat pets can train in the Gym", "an Economy pet" },
		{ 2, combat2.Id, "Gym slot locked: upgrade the Gym", "a locked slot (Gym 1 has 1 slot)" },
		{ 1, combat3.Id, "You do not own that pet", "a pet the player does not own" },
		{ 1, "ghost_pet", "Unknown pet", "an unknown pet" },
	}
	for _, r in ipairs(refusals) do
		mark = K.logSize()
		advance(0.3)
		care(p, "GymSet", r[1], r[2])
		advance(0.3)
		T.check(toasted(p, r[3], "bad", mark) and homeOf(p).Gym[1] == combat.Id and homeOf(p).Gym[2] == nil,
			"care gym: " .. r[4] .. " is refused ('" .. r[3] .. "')", toastsSince(p, mark))
	end
	-- a pet working in the Garden cannot train (TycoonService only lets Economy pets in; an old save might differ)
	DataS.MutateHome(p, function(h)
		h.Garden[1] = combat2.Id
	end)
	mark = K.logSize()
	advance(0.3)
	local okGarden, whyGarden = Care.GymSet(p, 1, combat2.Id)
	T.check(not okGarden and whyGarden == "That pet is working in the Garden" and homeOf(p).Gym[1] == combat.Id, "care gym: a pet in the Garden is refused ('working in the Garden')", tostring(whyGarden))
	DataS.MutateHome(p, function(h)
		h.Garden[1] = nil
	end)

	-- XP per minute by Gym level, granted every 10 s, with level-up toasts
	local perMin = Cat.GymXpPerMinute(homeOf(p))
	local tol = perMin * 10 / 60 + 1
	mark = K.logSize()
	local x0 = totalXp(p, combat.Id)
	advance(60)
	local gained = totalXp(p, combat.Id) - x0
	T.check(abs(gained - perMin) <= tol, "care gym: a training pet gains the Gym's XP per minute (Gym 1: " .. perMin .. " XP/min, granted every 10 s)", tostring(gained))
	waitUntil(function()
		return DataS.GetPetLevel(p, combat.Id) >= 2
	end, 30) -- the grants come every 10 s: make sure the first level-up happened
	local lvAfter = DataS.GetPetLevel(p, combat.Id)
	local cs = PCat.GetStats(combat.Id, lvAfter)
	T.check(lvAfter >= 2 and toasted(p, combat.Name .. " trained to Lv " .. lvAfter .. "! Power " .. compactText(cs.Power), "good", mark),
		"care gym: a level-up from training shows a toast with the new stats", toastsSince(p, mark))
	local x1 = totalXp(p, eco.Id)
	T.eq(x1, 0, "care gym: pets outside the Gym gain nothing")

	-- Gym 3: more slots, faster
	setStations(p, { Gym = 3 })
	advance(0.3)
	local okSet2 = Care.GymSet(p, 2, combat2.Id)
	T.check(okSet2 and homeOf(p).Gym[2] == combat2.Id, "care gym: Gym Lv 3 unlocks slot 2")
	local perMin3 = Cat.GymXpPerMinute(homeOf(p))
	advance(10.5) -- let the grant with the old rate pass
	local a0, b0 = totalXp(p, combat.Id), totalXp(p, combat2.Id)
	advance(40)
	local ga, gb = totalXp(p, combat.Id) - a0, totalXp(p, combat2.Id) - b0
	local want = perMin3 * 40 / 60
	T.check(perMin3 > perMin and abs(ga - want) <= perMin3 * 10 / 60 + 1 and abs(gb - want) <= perMin3 * 10 / 60 + 1,
		"care gym: Gym Lv 3 trains every pet faster (" .. perMin3 .. " XP/min each)", ga .. ", " .. gb .. " vs " .. want)
	T.eq(info.Folder:GetAttribute("GymPets"), "1=" .. combat.Id .. ";2=" .. combat2.Id, "care gym: GymPets lists both training pets")

	-- not while in the Garden
	DataS.MutateHome(p, function(h)
		h.Garden[1] = combat2.Id
	end)
	advance(11) -- the XP it earned before is still granted
	local b1 = totalXp(p, combat2.Id)
	advance(30)
	T.eq(totalXp(p, combat2.Id), b1, "care gym: a pet that also sits in the Garden does not train")
	T.eq(info.Folder:GetAttribute("GymPets"), "1=" .. combat.Id, "care gym: ...and GymPets leaves it out")
	DataS.MutateHome(p, function(h)
		h.Garden[1] = nil
	end)

	-- move, already there, remove by key, auto slot, clear
	advance(0.3)
	local okMove = Care.GymSet(p, 3, combat.Id)
	local gym = homeOf(p).Gym
	T.check(okMove and gym[1] == nil and gym[3] == combat.Id, "care gym: GymSet to another slot moves the pet (one slot per pet)")
	local okAgain = Care.GymSet(p, 0, combat.Id)
	T.check(okAgain and homeOf(p).Gym[3] == combat.Id and homeOf(p).Gym[1] == nil, "care gym: GymSet(0, key) for a pet already training changes nothing")
	local okOut = Care.GymSet(p, combat.Id, nil)
	T.check(okOut and homeOf(p).Gym[3] == nil, "care gym: GymSet(key) takes that pet out of the Gym")
	local okAuto = Care.GymSet(p, nil, combat.Id)
	T.check(okAuto and homeOf(p).Gym[1] == combat.Id, "care gym: GymSet(nil, key) uses the first free slot")
	mark = K.logSize()
	advance(0.3)
	care(p, "GymSet", 2, nil)
	advance(0.3)
	T.check(homeOf(p).Gym[2] == nil and toasted(p, combat2.Name .. " left the Gym", "info", mark), "care gym: GymSet(slot, nil) clears the slot (side toast)", toastsSince(p, mark))
	advance(0.3)
	care(p, "GymSet", { Slot = 2, Key = combat2.Id })
	advance(0.3)
	T.eq(homeOf(p).Gym[2], combat2.Id, "care gym: the remote also takes {Slot =, Key =}")

	-- the cap stops training
	local cap = PCat.LevelCap(combat.Id)
	local have = totalXp(p, combat.Id)
	DataS.AddPetXp(p, combat.Id, Cat.XpForLevel(cap) - have - 3)
	mark = K.logSize()
	advance(11)
	local lvc, xpc = DataS.GetPetLevel(p, combat.Id)
	T.check(lvc == cap and xpc == 0, "care gym: training stops exactly at the pet's level cap (Lv " .. cap .. ")", lvc .. "/" .. xpc)
	T.check(toasted(p, "trained to Lv " .. cap .. " (max)!", "good", mark) and toasted(p, "is at its max level: free its Gym slot", "info", mark),
		"care gym: ...with a '(max)' level-up toast and a tip to free the slot", toastsSince(p, mark))
	advance(21)
	lvc, xpc = DataS.GetPetLevel(p, combat.Id)
	T.check(lvc == cap and xpc == 0, "care gym: a capped pet in the Gym stays at its cap")

	-- no training without a claimed home (like the Collector's income)
	local q = join("CareGymNoPlot")
	DataS.MutateHome(q, function(h)
		h.Stations.Gym = 1
	end)
	givePet(q, combat.Id)
	advance(0.3)
	local okQ = Care.GymSet(q, 1, combat.Id)
	local q0 = totalXp(q, combat.Id)
	advance(25)
	T.check(okQ and homeOf(q).Gym[1] == combat.Id and totalXp(q, combat.Id) == q0, "care gym: a player who has not claimed a home can set the Gym, but nothing trains until they do")
	local qIndex = claimFree(q)
	advance(25)
	T.check(qIndex ~= nil and totalXp(q, combat.Id) > q0, "care gym: ...once the home is claimed the pet trains")
	leave(q)

	-- leaving clears GymPets on the plot
	conn:Disconnect()
	leave(p)
	advance(0.5)
	T.check(info.Folder:GetAttribute("GymPets") == nil, "care gym: leaving clears GymPets from the plot")
	K.flushErrors("p2care_gym")
	K.flushWarnings("p2care_gym")
end)

----------------------------------------------------------------------------------------------------
-- p2care_exploits
----------------------------------------------------------------------------------------------------
S.p2care_exploits = guarded("p2care_exploits", function()
	if not K.needBoot() then
		return
	end
	local Care, Cat = PCS(), TC()
	if not Care or not Cat then
		T.fail("care exploits: PetCareService and TycoonCatalog load")
		return
	end
	local DataS = DS()
	local p = join("CareHack")
	local index = claimFree(p)
	if not T.check(index ~= nil, "care exploits: (precondition) the player claims a plot") then
		leave(p)
		return
	end
	setStations(p, { Press1 = 2, Collector = 1, Press2 = 2, Garden = 1, Kitchen = 2, Gym = 1 })
	local combat = pickPet("Combat", "Common")
	givePet(p, combat.Id)
	DataS.AddCash(p, 5000)
	DataS.AddFood(p, "Snack", 200)
	advance(0.5)
	local cash0, snack0, xp0 = cashOf(p), foodOf(p, "Snack"), totalXp(p, combat.Id)
	local errors0 = #Mock.Errors
	local nan, inf = 0 / 0, 1 / 0
	local long = string.rep("S", 5000)
	local junk = {
		{}, { 123 }, { nil, "Snack" }, { long }, { "cook", "Snack", 1 }, { "Prestige" }, { "Collect" }, { "Cook" },
		{ "Cook", 5, 1 }, { "Cook", {}, {} }, { "Cook", "Snack", nan }, { "Cook", "Snack", -3 }, { "Cook", "Snack", 0 },
		{ "Cook", "Snack", 0.5 }, { "Cook", "Snack", "2" }, { "Cook", "Snack", inf }, { "Cook", "Snack", -inf },
		{ "Cook", long, 1 }, { "Cook", "snack", 1 }, { "Cook", "Cake", 1 }, { "Cook", { FoodId = {}, Qty = nan } },
		{ "Feed" }, { "Feed", nil, "Snack" }, { "Feed", 42, "Snack" }, { "Feed", combat.Id, 7 }, { "Feed", {}, {} },
		{ "Feed", long, "Snack" }, { "Feed", "hyb:nope", "Snack" }, { "Feed", combat.Id .. "@Diamond", "Snack" },
		{ "Feed", combat.Id .. "@Normal", "Snack" }, { "Feed", combat.Id, long }, { "Feed", { Key = {}, FoodId = 1 } },
		{ "GymSet" }, { "GymSet", nan, combat.Id }, { "GymSet", 1.5, combat.Id }, { "GymSet", -1, combat.Id },
		{ "GymSet", 1e9, combat.Id }, { "GymSet", inf, combat.Id }, { "GymSet", { Slot = {}, Key = {} } }, { "GymSet", 1, 42 },
		{ "GymSet", "abc", 5 }, { "GymSet", string.rep("1", 500), combat.Id }, { "GymSet", 65, combat.Id }, { "GymSet", 1, long },
	}
	for _, args in ipairs(junk) do
		care(p, args[1], args[2], args[3])
		advance(0.3) -- past every cooldown: each junk request is really evaluated
	end
	T.check(cashOf(p) == cash0 and foodOf(p, "Snack") == snack0 and totalXp(p, combat.Id) == xp0 and (p:GetAttribute("KitchenQueue") or "") == "" and next(homeOf(p).Gym) == nil,
		"care exploits: " .. #junk .. " junk / NaN / inf / negative / wrong-type / oversized PetCare requests change nothing (Cash, Food, XP, queue, Gym)",
		"cash " .. cashOf(p) .. " food " .. foodOf(p, "Snack") .. " queue " .. tostring(p:GetAttribute("KitchenQueue")))
	T.eq(#Mock.Errors, errors0, "care exploits: ...and raise no script error")

	-- spam: one Cook per cooldown, one Feed per cooldown, the burst budget
	advance(2)
	local c = cashOf(p)
	for _ = 1, 40 do
		care(p, "Cook", "Snack", 1)
	end
	advance(0.05)
	T.eq(c - cashOf(p), Cat.FoodById("Snack").Price, "care exploits: 40 Cook requests in one frame order exactly one Snack (cooldown)")
	waitUntil(function()
		return (p:GetAttribute("KitchenQueue") or "") == ""
	end, 15) -- that Snack lands in Food before the feeding counts start
	local s = foodOf(p, "Snack")
	local x = totalXp(p, combat.Id)
	for _ = 1, 40 do
		care(p, "Feed", combat.Id, "Snack")
	end
	advance(0.05)
	T.check(s - foodOf(p, "Snack") == 1 and totalXp(p, combat.Id) - x == Cat.FoodById("Snack").Xp,
		"care exploits: 40 Feed requests in one frame feed exactly once")
	advance(3) -- refill the budget
	s = foodOf(p, "Snack")
	x = totalXp(p, combat.Id)
	local sent, t0 = 0, os.clock()
	for _ = 1, 80 do
		care(p, "Feed", combat.Id, "Snack")
		sent = sent + 1
		advance(0.11)
	end
	local elapsed = os.clock() - t0
	local eaten = s - foodOf(p, "Snack")
	local snackXp = Cat.FoodById("Snack").Xp
	T.check(eaten >= 1 and eaten < sent and eaten <= 12 + 6 * elapsed + 1, "care exploits: a steady flood of Feed requests is held to the burst budget (" .. eaten .. " of " .. sent .. " in " .. string.format("%.1f", elapsed) .. " s)")
	T.eq(totalXp(p, combat.Id) - x, eaten * snackXp, "care exploits: every eaten Snack gave exactly its XP (no food lost, no XP for free)")

	-- someone else's pets and Kitchen
	local q = join("CareHack2")
	DataS.AddFood(q, "Snack", 5)
	local qs = foodOf(q, "Snack")
	advance(0.3)
	care(q, "Feed", combat.Id, "Snack")
	advance(0.3)
	T.check(foodOf(q, "Snack") == qs and totalXp(p, combat.Id) == x + eaten * snackXp, "care exploits: feeding a pet you do not own does nothing (not even to its owner's copy)")
	local model = kitchenOf(index)
	if model then
		local cookPrompts, feedPrompt = carePrompts(model)
		DataS.AddCash(q, 1000)
		local cq, cp = cashOf(q), cashOf(p)
		for _, prompt in pairs(cookPrompts) do
			Mock.Trigger(prompt, q)
		end
		if feedPrompt then
			Mock.Trigger(feedPrompt, q)
		end
		advance(0.3)
		T.check(cashOf(q) == cq and cashOf(p) == cp, "care exploits: another player's presses on the owner's Kitchen prompts spend nothing on either side")
		-- a stray prompt that only looks like ours
		local fake = Instance.new("ProximityPrompt")
		fake.Name = "CookPrompt"
		fake:SetAttribute("FoodId", "Snack")
		fake:SetAttribute("OwnerUserId", q.UserId)
		fake.Parent = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		Mock.Trigger(fake, q)
		advance(0.3)
		T.check(cashOf(q) == cq and cashOf(p) == cp, "care exploits: a CookPrompt the service did not make (or on someone else's plot) is ignored")
		fake:Destroy()
	end
	leave(q)
	T.check(cashOf(p) >= 0, "care exploits: Cash never goes negative")
	leave(p)

	-- set-up for p2care_shutdown: a player stays online with a Feast still cooking when the server closes
	local closer = join("CareClose")
	if claimFree(closer) then
		setStations(closer, { Kitchen = 4 }) -- only what cooking needs: this plot still stands at final_checks
		DataS.AddCash(closer, 20000)
		local before = cashOf(closer)
		care(closer, "Cook", "Feast", 1)
		advance(0.1)
		if cashOf(closer) == before - Cat.FoodById("Feast").Price then
			CLOSE = { UserId = closer.UserId, Cash = before }
		end
	end
	K.flushErrors("p2care_exploits")
	K.flushWarnings("p2care_exploits")
end)

----------------------------------------------------------------------------------------------------
-- p2care_shutdown (runs right after the "shutdown" scenario, which calls every BindToClose callback)
----------------------------------------------------------------------------------------------------
S.p2care_shutdown = guarded("p2care_shutdown", function()
	if not CLOSE then
		T.info("*care shutdown check skipped: p2care_exploits did not leave a player cooking")
		return
	end
	local rec = storedProfile(CLOSE.UserId)
	T.check(rec ~= nil and rec.Cash == CLOSE.Cash, "care shutdown: a server shutdown refunds the dishes still cooking (the saved Cash is back to before the order)",
		"stored " .. tostring(rec and rec.Cash) .. ", before the order " .. tostring(CLOSE.Cash))
	K.flushErrors("p2care_shutdown")
end)

return S
