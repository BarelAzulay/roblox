-- smoke_content.lua: scenarios for the game's CONTENT (no player needed, only the loaded modules):
--   catalog      PetCatalog / ItemCatalog data, roulette odds, RollPet frequencies, perks
--   config_shape Config.* tables the v2 systems read (difficulties, archetypes, themes, rarities, roulettes ...)
--   petbuilder   PetBuilder.Build / Animate / GetHeight for every pet (part budget, wings, flags)
--   layouts      5 difficulties x N seeds: GenerateLayout + ValidateLayout + an INDEPENDENT audit of the
--                ARCHITECTURE_V2.md rules, statistics per difficulty (steps, tokens, archetype and theme mix)
--   cannon       ballistics of every CannonPad in the generated layouts
--   courses      CourseBuilder.Build per difficulty: part budget, tags + attributes per Config.Tags, scenery
--
-- Loaded by smoke.py after smoke_server.lua, which exports its helper kit as the global K.
-- Plain Lua 5.1 syntax only.

local K = _G.K
local T = K.T
local guarded = K.guarded
local M = K.M
local W = K.W
local fmt = K.fmt
local mod = K.mod
local config = K.config
local advance = K.advance
local flushErrors = K.flushErrors
local flushWarnings = K.flushWarnings
local tagged = K.tagged

local CollectionService = game:GetService("CollectionService")
local S = {}

local RAD = math.pi / 180
local huge = math.huge
local sin, cos, sqrt, abs, floor, max, min = math.sin, math.cos, math.sqrt, math.abs, math.floor, math.max, math.min

local function sortedKeys(t)
	local out = {}
	for k in pairs(t) do
		out[#out + 1] = k
	end
	table.sort(out)
	return out
end

local function pct(n, total)
	if total == 0 then
		return "0%"
	end
	return string.format("%.0f%%", 100 * n / total)
end

-- "Name 40% Name2 25% ..." for a count table, biggest first
local function mixText(counts, total, limit)
	local list = {}
	for k, v in pairs(counts) do
		list[#list + 1] = { k = k, v = v }
	end
	table.sort(list, function(a, b)
		if a.v ~= b.v then
			return a.v > b.v
		end
		return a.k < b.k
	end)
	local parts = {}
	for i, e in ipairs(list) do
		if limit and i > limit then
			break
		end
		parts[#parts + 1] = e.k .. " " .. pct(e.v, total)
	end
	return table.concat(parts, "  ")
end

-- weight table (Config.Difficulties[i].Archetypes / .Themes) -> set of allowed ids
local function allowedSet(weights)
	local out = {}
	for k, w in pairs(weights or {}) do
		if type(w) == "number" and w > 0 then
			out[k] = true
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- scenario: PetCatalog + ItemCatalog
----------------------------------------------------------------------------------------------------
local function rarityRank(Config)
	local rank = {}
	for _, r in ipairs(Config.Rarities) do
		rank[r.Id] = r.Order
	end
	return rank
end

S.catalog = guarded("catalog", function()
	local Config = config()
	local PC, IC = M["shared/PetCatalog"], M["shared/ItemCatalog"]
	local Util = M["shared/Util"]
	if not (PC and IC and Util) then
		T.fail("catalog scenario needs PetCatalog, ItemCatalog and Util")
		return
	end
	local rank = rarityRank(Config)
	-- lineup
	local counts, total = {}, 0
	local ids, names = {}, {}
	local speciesUsed, wingUsed, accessoryUsed = {}, {}, {}
	local shape = T.tally("every pet has a valid Id / Name / Rarity / Blurb / Look / Perks")
	local sorted = true
	for i, def in ipairs(PC.Pets) do
		total = total + 1
		counts[def.Rarity] = (counts[def.Rarity] or 0) + 1
		local ok = type(def.Id) == "string" and def.Id:match("^[a-z0-9_]+$") ~= nil and type(def.Name) == "string" and #def.Name > 2 and rank[def.Rarity] ~= nil and type(def.Blurb) == "string" and #def.Blurb > 8
		shape:case(ok and not ids[def.Id] and not names[def.Name], def.Id .. ": bad id / name / rarity / blurb or duplicate")
		ids[def.Id] = true
		names[def.Name] = true
		local look = def.Look
		local lookOk = type(look) == "table" and T.contains(PC.Species, look.Species) and typeof(look.Primary) == "Color3" and typeof(look.Secondary) == "Color3" and typeof(look.Eye) == "Color3"
			and typeof(look.WingColor) == "Color3" and T.contains(PC.WingStyles or { "Feather", "Bat", "Fairy", "Cloud", "Crystal", "Flame" }, look.WingStyle)
			and (look.Accessory == nil or T.contains(PC.Accessories or { "Horns", "Crown", "Halo", "Leaf", "Mushroom", "Scarf", "Antlers", "Flower" }, look.Accessory))
			and (look.Glow == nil or type(look.Glow) == "boolean")
		shape:case(lookOk, def.Id .. ": Look is incomplete")
		if lookOk then
			speciesUsed[look.Species] = true
			wingUsed[look.WingStyle] = true
			if look.Accessory then
				accessoryUsed[look.Accessory] = true
			end
		end
		local nPerks, perkOk = 0, true
		for key, value in pairs(def.Perks or {}) do
			nPerks = nPerks + 1
			perkOk = perkOk and Config.Pets.PerkCaps[key] ~= nil and T.finite(value) and value > 0 and value <= Config.Pets.PerkCaps[key]
		end
		shape:case(perkOk and nPerks >= 1 and nPerks <= 2, def.Id .. ": a pet needs 1-2 perks from Config.Pets.PerkCaps, got " .. nPerks)
		local prev = PC.Pets[i - 1]
		if prev then
			local a, b = rank[prev.Rarity] or 0, rank[def.Rarity] or 0
			if a > b or (a == b and prev.Name > def.Name) then
				sorted = false
			end
		end
		T.check(PC.ById[def.Id] == def and PC.Get(def.Id) == def, def.Id .. ": ById / Get return the definition")
	end
	shape:report()
	T.check(sorted, "PetCatalog.Pets is sorted by rarity order, then Name")
	for rarity, want in pairs(CONTRACT.v2.petCounts) do
		T.eq(counts[rarity] or 0, want, "lineup has " .. want .. " " .. rarity .. " pets")
		T.eq(#PC.ListByRarity(rarity), want, "ListByRarity('" .. rarity .. "') returns them")
	end
	T.eq(total, 26, "the lineup has 26 pets")
	T.check(#PC.ListByRarity("NoSuchRarity") == 0, "ListByRarity of an unknown rarity is empty")
	T.check(PC.Get("nope") == nil and PC.Get(nil) == nil and PC.Get(5) == nil, "Get of an unknown id is nil")
	local missing = {}
	for _, s in ipairs(PC.Species) do
		if not speciesUsed[s] then
			missing[#missing + 1] = s
		end
	end
	T.check(#missing == 0, "every species is used by at least one pet", "unused: " .. table.concat(missing, ", "))
	T.check(#PC.Species == 14, "PetCatalog.Species lists 14 species", #PC.Species .. "")
	for _, wstyle in ipairs({ "Feather", "Bat", "Fairy", "Cloud", "Crystal", "Flame" }) do
		T.check(wingUsed[wstyle] == true, "wing style " .. wstyle .. " is used by a pet")
	end
	for _, acc in ipairs({ "Horns", "Crown", "Halo", "Leaf", "Mushroom", "Scarf", "Antlers", "Flower" }) do
		T.check(accessoryUsed[acc] == true, "accessory " .. acc .. " is used by a pet")
	end
	-- the mascot
	local dragon = PC.Get(CONTRACT.v2.mascotPetId)
	if T.check(dragon ~= nil, "the mascot 'cloudy_dragon' exists") then
		T.eq(dragon.Name, "Cloudy Dragon", "mascot Name")
		T.eq(dragon.Rarity, "Mythic", "mascot Rarity")
		T.eq(dragon.Look.Species, "Dragon", "mascot Species")
		T.eq(dragon.Look.Accessory, "Horns", "mascot Accessory")
		T.eq(dragon.Look.WingStyle, "Cloud", "mascot WingStyle")
		T.check(K.colorDistance255(dragon.Look.Primary, Color3.fromRGB(236, 244, 255)) < 2, "mascot Primary is cloud white (236,244,255)")
		T.check(K.colorDistance255(dragon.Look.Secondary, Color3.fromRGB(150, 196, 240)) < 2, "mascot Secondary is sky blue (150,196,240)")
		T.check(K.colorDistance255(dragon.Look.Eye, Color3.fromRGB(30, 40, 90)) < 2, "mascot Eye is deep blue (30,40,90)")
		T.check(K.colorDistance255(dragon.Look.WingColor, Color3.fromRGB(200, 225, 255)) < 2, "mascot WingColor (200,225,255)")
		T.near(dragon.Perks.MaxHealth or -1, 0.12, 1e-9, "mascot perk MaxHealth +12%")
		T.near(dragon.Perks.TokenBonus or -1, 0.25, 1e-9, "mascot perk TokenBonus +25%")
		T.check(PC.Pets[#PC.Pets - 1] == dragon or PC.Pets[#PC.Pets] == dragon, "the mascot is one of the two Mythics at the end of the list")
	end
	-- perk strength scales with rarity
	local meanPerk, maxPerk = {}, {}
	for _, def in ipairs(PC.Pets) do
		local sum = 0
		for _, v in pairs(def.Perks) do
			sum = sum + v
		end
		meanPerk[def.Rarity] = (meanPerk[def.Rarity] or 0) + sum / counts[def.Rarity]
		maxPerk[def.Rarity] = max(maxPerk[def.Rarity] or 0, sum)
	end
	local prevMean, scales = 0, true
	local line = {}
	for _, r in ipairs(Config.Rarities) do
		local mean = meanPerk[r.Id] or 0
		line[#line + 1] = string.format("%s %.3f", r.Id, mean)
		if mean < prevMean then
			scales = false
		end
		prevMean = mean
	end
	T.check(scales, "average perk strength never drops with rarity", table.concat(line, "  "))
	T.check((maxPerk.Common or 1) <= 0.06, "Common pets give small perks (<= 6% total)", tostring(maxPerk.Common))
	T.check((maxPerk.Mythic or 0) >= 0.12, "Mythic pets give big perks (>= 12% total)", tostring(maxPerk.Mythic))
	T.info("*lineup: " .. total .. " pets  mean perk sum per rarity: " .. table.concat(line, "  "))

	-- perk labels and sums
	T.eq(PC.PerkLabel("MaxHealth", 0.12), "+12% Max Health", "PerkLabel(MaxHealth, 0.12)")
	T.eq(PC.PerkLabel("TokenBonus", 0.25), "+25% Cloud Tokens", "PerkLabel(TokenBonus, 0.25)")
	T.eq(PC.PerkLabel("StaminaRegen", 0.1), "+10% Stamina Regen", "PerkLabel(StaminaRegen, 0.1)")
	T.eq(PC.PerkLabel("CheckpointHeal", 0.05), "+5% Checkpoint Heal", "PerkLabel(CheckpointHeal, 0.05)")
	local zero = PC.SumPerks({})
	T.check(zero.MaxHealth == 0 and zero.TokenBonus == 0 and zero.StaminaRegen == 0 and zero.CheckpointHeal == 0, "SumPerks({}) returns zero for all four perks")
	local one = PC.SumPerks({ "cloudy_dragon" })
	T.check(abs(one.MaxHealth - 0.12) < 1e-9 and abs(one.TokenBonus - 0.25) < 1e-9, "SumPerks({'cloudy_dragon'}) = 12% health + 25% tokens")
	local many = {}
	for _ = 1, 40 do
		many[#many + 1] = "cloudy_dragon"
	end
	local capped = PC.SumPerks(many)
	T.check(capped.MaxHealth == Config.Pets.PerkCaps.MaxHealth and capped.TokenBonus == Config.Pets.PerkCaps.TokenBonus, "SumPerks caps every perk at Config.Pets.PerkCaps", string.format("%.2f %.2f", capped.MaxHealth, capped.TokenBonus))
	T.check(PC.SumPerks({ "ghost" }).TokenBonus == 0, "SumPerks ignores unknown pet ids")
	for key, cap in pairs(Config.Pets.PerkCaps) do
		local best = 0
		for _, def in ipairs(PC.Pets) do
			best = max(best, def.Perks[key] or 0)
		end
		T.check(best <= cap, "no single pet's " .. key .. " perk exceeds its cap", best .. " > " .. cap)
	end
	-- the maximum a player can reach with the equip limit stays under the caps that protect the course physics
	for _, key in ipairs({ "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }) do
		local list = {}
		for _, def in ipairs(PC.Pets) do
			list[#list + 1] = def.Perks[key] or 0
		end
		table.sort(list, function(a, b)
			return a > b
		end)
		local top = 0
		for i = 1, Config.Pets.MaxEquipped do
			top = top + (list[i] or 0)
		end
		T.check(top <= Config.Pets.PerkCaps[key] + 1e-9, "the best " .. Config.Pets.MaxEquipped .. " pets cannot exceed the " .. key .. " cap on their own", string.format("%.2f vs cap %.2f", top, Config.Pets.PerkCaps[key]))
	end

	-- roulettes: odds
	local cheapest = huge
	local order = {}
	for _, r in ipairs(Config.Roulettes) do
		order[#order + 1] = r
	end
	table.sort(order, function(a, b)
		return a.Price < b.Price
	end)
	local prevPrice, prevExpected = -1, -1
	for _, r in ipairs(order) do
		local odds = PC.GetOdds(r.Id)
		local sum, seen, bad = 0, {}, 0
		local byRarity = {}
		for _, o in ipairs(odds) do
			sum = sum + o.Chance
			local def = PC.Get(o.PetId)
			if not def or def.Rarity ~= o.Rarity or seen[o.PetId] or not (o.Chance > 0 and o.Chance <= 1) then
				bad = bad + 1
			end
			seen[o.PetId] = true
			byRarity[o.Rarity] = (byRarity[o.Rarity] or 0) + o.Chance
		end
		T.check(abs(sum - 1) < 1e-9, r.Id .. ": GetOdds chances sum to 1", string.format("%.12f", sum))
		T.eq(bad, 0, r.Id .. ": GetOdds entries are valid, unique pets with 0 < Chance <= 1")
		local weightTotal = 0
		for _, w in pairs(r.Odds) do
			weightTotal = weightTotal + w
		end
		for rarity, w in pairs(r.Odds) do
			T.check(#PC.ListByRarity(rarity) > 0, r.Id .. ": rarity " .. rarity .. " has weight " .. w .. " and therefore needs pets")
			T.check(abs((byRarity[rarity] or 0) - w / weightTotal) < 1e-9, r.Id .. ": " .. rarity .. " share = " .. w .. "/" .. weightTotal, string.format("%.6f", byRarity[rarity] or 0))
		end
		for rarity in pairs(byRarity) do
			T.check((r.Odds[rarity] or 0) > 0, r.Id .. ": rarity " .. rarity .. " is only offered when it has weight")
		end
		local possible = PC.PossiblePets(r.Id)
		local pset, pcount = {}, 0
		for _, def in ipairs(possible) do
			pset[def.Id] = true
			pcount = pcount + 1
		end
		T.check(pcount == #odds and (function()
			for id in pairs(seen) do
				if not pset[id] then
					return false
				end
			end
			return true
		end)(), r.Id .. ": PossiblePets matches GetOdds", pcount .. " vs " .. #odds)
		-- cheap roulettes never roll Mythic; Mythics only come from Sky / Celestial
		local mythic = byRarity.Mythic or 0
		if r.Id == "Sky" or r.Id == "Celestial" then
			T.check(mythic > 0, r.Id .. ": can roll Mythic pets")
		else
			T.check(mythic == 0, r.Id .. ": never rolls Mythic pets (cheap roulette)", string.format("%.4f", mythic))
		end
		if r.Id == "Cloud" then
			T.check((byRarity.Common or 0) > 0 and (byRarity.Uncommon or 0) > 0, "Cloud roulette offers Commons and Uncommons")
			T.check((byRarity.Legendary or 0) == 0, "Cloud roulette cannot roll Legendary pets")
		end
		-- more expensive roulette = better expected rarity
		local expected = 0
		for rarity, share in pairs(byRarity) do
			expected = expected + share * (rank[rarity] or 0)
		end
		T.check(r.Price > prevPrice and expected > prevExpected, r.Id .. ": costs more and pays out better rarities than the cheaper roulette", string.format("expected rarity %.2f vs %.2f", expected, prevExpected))
		prevPrice, prevExpected = r.Price, expected
		cheapest = min(cheapest, r.Price)
	end
	T.check(PC.GetOdds("NoSuchRoulette") ~= nil and #PC.GetOdds("NoSuchRoulette") == 0, "GetOdds of an unknown roulette is an empty list")
	local okUnknown, unknownRoll = pcall(PC.RollPet, "NoSuchRoulette", Util.NewRng(1))
	T.check(okUnknown and unknownRoll == nil, "RollPet of an unknown roulette returns nil instead of raising")

	-- RollPet frequencies
	local rolls = ARGS.quick and 8000 or 30000
	for _, r in ipairs(Config.Roulettes) do
		local rng = Util.NewRng(9000 + #r.Id)
		local counted, perPet = {}, {}
		local invalid = 0
		local possible = {}
		for _, o in ipairs(PC.GetOdds(r.Id)) do
			possible[o.PetId] = o
		end
		for _ = 1, rolls do
			local id = PC.RollPet(r.Id, rng)
			local o = possible[id]
			if not o then
				invalid = invalid + 1
			else
				counted[o.Rarity] = (counted[o.Rarity] or 0) + 1
				perPet[id] = (perPet[id] or 0) + 1
			end
		end
		T.eq(invalid, 0, r.Id .. ": " .. rolls .. " rolls only return pets the roulette can give")
		local weightTotal = 0
		for _, w in pairs(r.Odds) do
			weightTotal = weightTotal + w
		end
		local freq = T.tally(r.Id .. ": rarity frequencies over " .. rolls .. " rolls match Odds (5 sigma)")
		local detail = {}
		for rarity, w in pairs(r.Odds) do
			local p = w / weightTotal
			local got = (counted[rarity] or 0) / rolls
			local sigma = sqrt(p * (1 - p) / rolls)
			freq:case(abs(got - p) <= 5 * sigma + 0.002, string.format("%s %.4f vs %.4f", rarity, got, p))
			detail[#detail + 1] = string.format("%s %.3f", rarity, got)
		end
		freq:report(table.concat(detail, " "))
		local uniform = T.tally(r.Id .. ": pets inside a rarity are equally likely (5 sigma)")
		for id, o in pairs(possible) do
			local p = o.Chance
			local sigma = sqrt(p * (1 - p) / rolls)
			uniform:case(abs((perPet[id] or 0) / rolls - p) <= 5 * sigma + 0.002, string.format("%s %.4f vs %.4f", id, (perPet[id] or 0) / rolls, p))
		end
		uniform:report()
		-- deterministic for a given seed
		local a, b = Util.NewRng(77), Util.NewRng(77)
		local same = true
		for _ = 1, 50 do
			same = same and PC.RollPet(r.Id, a) == PC.RollPet(r.Id, b)
		end
		T.check(same, r.Id .. ": RollPet is deterministic for a seed")
	end

	-- items
	local IL = IC.List
	T.eq(#IL, #CONTRACT.v2.items, "ItemCatalog.List has " .. #CONTRACT.v2.items .. " items")
	for i, id in ipairs(CONTRACT.v2.items) do
		local def = IL[i]
		if T.check(def ~= nil and def.Id == id, "ItemCatalog.List[" .. i .. "] is " .. id .. " (hotbar order)", def and def.Id) then
			T.check(IC.Get(id) == def and IC.ById[id] == def, id .. ": Get / ById")
			T.check(type(def.Name) == "string" and #def.Name > 2 and type(def.Blurb) == "string" and #def.Blurb > 10, id .. ": Name and Blurb")
			T.check(type(def.Price) == "number" and def.Price > 0 and def.Price == floor(def.Price), id .. ": Price is a positive integer")
			T.check(type(def.Glyph) == "string" and #def.Glyph >= 1 and #def.Glyph <= 8, id .. ": Glyph is one short symbol")
			T.check(typeof(def.Color) == "Color3", id .. ": Color is a Color3")
			T.check(rank[def.Rarity] ~= nil, id .. ": Rarity is a Config.Rarities id")
		end
	end
	T.eq(IC.Get("heal_cloud").Price, 30, "heal_cloud costs 30")
	T.eq(IC.Get("shield_bubble").Price, 45, "shield_bubble costs 45")
	T.eq(IC.Get("phoenix_feather").Price, 150, "phoenix_feather costs 150")
	T.eq(IC.Get("heal_cloud").Name, "Heal Cloud", "heal_cloud name")
	T.check(IC.Get("nothing") == nil and IC.Get(nil) == nil, "ItemCatalog.Get of an unknown id is nil")
	T.check(#IL <= Config.Items.HotbarSlots, "all items fit on the hotbar (Config.Items.HotbarSlots = " .. Config.Items.HotbarSlots .. ")")
	T.check(cheapest <= 50, "the cheapest roulette is affordable after a first easy run (<= 50 tokens)", tostring(cheapest))
	flushErrors("catalog")
end)

----------------------------------------------------------------------------------------------------
-- scenario: Config tables of v2
----------------------------------------------------------------------------------------------------
S.config_shape = guarded("config_shape", function()
	local Config = config()
	local want = CONTRACT.v2.difficulties
	T.eq(#Config.Difficulties, #want, "Config.Difficulties has " .. #want .. " entries")
	local archSet, themeSet = {}, {}
	for _, a in ipairs(Config.Archetypes) do
		archSet[a] = true
	end
	for _, t in ipairs(Config.StageThemes) do
		themeSet[t] = true
	end
	T.eq(table.concat(Config.Archetypes, ","), "Straight,Zigzag,Serpent,Spiral", "Config.Archetypes")
	T.eq(#Config.StageThemes, 14, "Config.StageThemes lists 14 themes")
	local prev
	for i, id in ipairs(want) do
		local d = Config.Difficulties[i]
		if T.check(d ~= nil and d.Id == id, "difficulty " .. i .. " is " .. id, d and d.Id) then
			T.eq(Config.GetDifficulty(id), d, id .. ": GetDifficulty")
			T.eq(d.Stars, i, id .. ": Stars = " .. i)
			T.check(typeof(d.Color) == "Color3" and type(d.Blurb) == "string" and type(d.DisplayName) == "string", id .. ": Color / Blurb / DisplayName")
			T.check(type(d.StepsPerStage) == "table" and d.StepsPerStage[1] <= d.StepsPerStage[2], id .. ": StepsPerStage range")
			T.check(d.GapMin < d.GapMax and d.PlatformMin <= d.PlatformMax and d.RiseMax > 0 and d.TokensPerStage > 0 and d.TimeLimit > 60, id .. ": gap / platform / rise / token / time numbers")
			local archCount, themeCount = 0, 0
			for k, w in pairs(d.Archetypes) do
				archCount = archCount + 1
				T.check(archSet[k] and type(w) == "number" and w > 0, id .. ": Archetypes weight '" .. k .. "' is a known archetype with a positive weight")
			end
			for k, w in pairs(d.Themes) do
				themeCount = themeCount + 1
				T.check(themeSet[k] and type(w) == "number" and w > 0, id .. ": Themes weight '" .. k .. "' is a known stage theme with a positive weight")
			end
			T.check(archCount >= 2 and themeCount >= 3, id .. ": offers several archetypes and themes (" .. archCount .. " / " .. themeCount .. ")")
			T.check(Config.Damage.VoidDamage[id] ~= nil and Config.Match.TokenBonusOnWin[id] ~= nil, id .. ": has VoidDamage and TokenBonusOnWin entries")
			if d.DashGapChance and d.DashGapChance > 0 then
				T.check(d.DashGapMin ~= nil and d.DashGapMax ~= nil and d.DashGapMin < d.DashGapMax, id .. ": dash gaps have DashGapMin < DashGapMax")
				T.check(d.DashGapMax <= 0.85 * Config.Physics.MaxDashGap + 1e-9 and d.DashGapMin > 0.75 * Config.Physics.MaxRunGap, id .. ": dash gaps lie inside (0.75 * MaxRunGap, 0.85 * MaxDashGap]", d.DashGapMin .. ".." .. d.DashGapMax)
			end
			if prev then
				T.check(d.Stages > prev.Stages and d.TimeLimit > prev.TimeLimit and d.TokensPerStage >= prev.TokensPerStage, id .. ": longer, more generous in time and tokens than " .. prev.Id)
				T.check(d.HazardChance > prev.HazardChance and d.GapMax >= prev.GapMax and d.PlatformMax <= prev.PlatformMax, id .. ": more hazards, wider gaps and smaller platforms than " .. prev.Id)
				T.check(Config.Damage.VoidDamage[id] > Config.Damage.VoidDamage[prev.Id] and Config.Match.TokenBonusOnWin[id] > Config.Match.TokenBonusOnWin[prev.Id], id .. ": bigger void damage and win bonus than " .. prev.Id)
			end
			prev = d
		end
		for _, old in ipairs(CONTRACT.v2.oldDifficultyIds) do
			T.check(Config.GetDifficulty(old) == nil, "the old difficulty id " .. old .. " is gone")
		end
	end
	-- every theme is used by some difficulty
	local used = {}
	for _, d in ipairs(Config.Difficulties) do
		for k in pairs(d.Themes) do
			used[k] = true
		end
	end
	local unused = {}
	for _, t in ipairs(Config.StageThemes) do
		if not used[t] then
			unused[#unused + 1] = t
		end
	end
	T.check(#unused == 0, "every stage theme appears in some difficulty", table.concat(unused, ","))
	-- rarities, pets, roulettes, items
	for i, r in ipairs(Config.Rarities) do
		T.check(r.Order == i and typeof(r.Color) == "Color3" and type(r.Id) == "string", "rarity " .. i .. " (" .. tostring(r.Id) .. ") has Order " .. i .. " and a Color")
	end
	T.eq(#Config.Rarities, 6, "six rarities")
	T.check(Config.Pets.MaxEquipped >= 1 and Config.Pets.MaxPerStack >= 1, "Config.Pets.MaxEquipped / MaxPerStack")
	for _, key in ipairs({ "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }) do
		T.check(type(Config.Pets.PerkCaps[key]) == "number" and Config.Pets.PerkCaps[key] > 0, "PerkCaps." .. key)
	end
	T.check(Config.Pets.PerkCaps.MaxHealth <= 1 and Config.Pets.PerkCaps.TokenBonus <= 2, "perk caps are modest (max health <= +100%, tokens <= +200%)")
	T.eq(#Config.Roulettes, 4, "four roulettes")
	local rankSet = rarityRank(Config)
	for _, r in ipairs(Config.Roulettes) do
		T.check(type(r.Id) == "string" and type(r.DisplayName) == "string" and type(r.Price) == "number" and r.Price > 0 and typeof(r.Color) == "Color3", r.Id .. ": Id / DisplayName / Price / Color")
		local oddsOk = true
		for rarity, w in pairs(r.Odds) do
			oddsOk = oddsOk and rankSet[rarity] ~= nil and type(w) == "number" and w > 0
		end
		T.check(oddsOk, r.Id .. ": Odds use known rarities and positive weights")
	end
	T.check(Config.Items.MaxCarry >= 1 and Config.Items.HotbarSlots == 4, "Config.Items: MaxCarry and 4 hotbar slots")
	-- remotes, tags, attributes added in v2
	for _, name in ipairs({ "ProfileSync", "RouletteResult", "OpenPanel", "RequestProfile", "BuyRoulette", "EquipPet", "UnequipPet", "BuyItem", "UseItem", "GoToSpot" }) do
		T.check(T.contains(Config.Remotes, name), "Config.Remotes lists " .. name)
	end
	for _, name in ipairs({ "Pendulum", "WindGust", "CloudCannon", "GoldenToken" }) do
		T.check(type(Config.Tags[name]) == "string", "Config.Tags." .. name .. " exists")
	end
	for _, name in ipairs({ "EquippedPets", "SpotIndex", "PerkStaminaRegen" }) do
		T.check(type(Config.Attr[name]) == "string", "Config.Attr." .. name .. " exists")
	end
	local tagSeen = {}
	local dupTags = {}
	for k, v in pairs(Config.Tags) do
		if tagSeen[v] then
			dupTags[#dupTags + 1] = k .. "/" .. tagSeen[v]
		end
		tagSeen[v] = k
	end
	T.check(#dupTags == 0, "every Config.Tags value is unique", table.concat(dupTags, ", "))
	T.check(Config.Tokens.GoldenValue > Config.Tokens.DefaultValue, "golden tokens are worth more than regular ones")
	T.eq(Config.Tokens.DataStoreName, "NimbusClimb_v2", "the v2 DataStore name")
	T.eq(Config.Tokens.LegacyDataStoreName, "NimbusClimb_v1", "the legacy (v1) DataStore name")
	T.check(Config.Course.MaxRadius > 100 and Config.Course.Clearance >= 6, "Config.Course.MaxRadius / Clearance")
	T.eq(Config.Lobby.SpotCount, 16, "16 lobby spots")
	T.check(Config.Lobby.SpotRingRadius > Config.Lobby.PortalRingRadius and Config.Lobby.PortalRingRadius < Config.Lobby.PlazaRadius, "lobby rings: portals inside the plaza, spots outside")
	flushErrors("config_shape")
end)

----------------------------------------------------------------------------------------------------
-- scenario: PetBuilder for every pet of the catalog
----------------------------------------------------------------------------------------------------
local function finiteCFrame(cf)
	for _, v in ipairs({ cf:GetComponents() }) do
		if not T.finite(v) then
			return false
		end
	end
	return true
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

local function partsNamed(model, pattern)
	local out = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Name:find(pattern) then
			out[#out + 1] = d
		end
	end
	return out
end

-- number of direction changes of `fn()` while animating a pet for `seconds` at 30 fps
local function turns(PB, model, opts, seconds, probe)
	local last, dir, count = nil, 0, 0
	local t = 0
	for _ = 1, floor(seconds * 30) do
		t = t + 1 / 30
		PB.Animate(model, t, opts)
		local v = probe()
		if last then
			local d = v - last
			if abs(d) > 1e-4 then
				local nd = d > 0 and 1 or -1
				if dir ~= 0 and nd ~= dir then
					count = count + 1
				end
				dir = nd
			end
		end
		last = v
	end
	return count
end

S.petbuilder = guarded("petbuilder", function()
	local Config = config()
	local PB, PC = M["shared/PetBuilder"], M["shared/PetCatalog"]
	if not (PB and PC) then
		T.fail("petbuilder needs PetBuilder and PetCatalog")
		return
	end
	local budget = CONTRACT.v2.partBudget.pet
	local holder = Instance.new("Folder")
	holder.Name = "SmokePets"
	holder.Parent = workspace
	local tally = {
		model = T.tally("PetBuilder.Build returns a Model with a PrimaryPart for every pet"),
		budget = T.tally("every pet stays within the part budget (<= " .. budget .. " parts)"),
		flags = T.tally("every pet part is Anchored, CanCollide=false, CanTouch=false, CanQuery=false, Massless"),
		shadows = T.tally("small pet parts have CastShadow = false"),
		wings = T.tally("every pet has two wings named WingL and WingR (BaseParts)"),
		height = T.tally("pets are 2.0 - 3.4 studs tall (GetHeight) and GetHeight matches the built model"),
		scale = T.tally("Build(def, { Scale = s }) scales the pet"),
		palette = T.tally("the pet is painted in its Look colours (Primary / Secondary / WingColor)"),
		eyes = T.tally("pets have big glossy eyes (Eye parts + shine highlights); Glow pets have Neon irises"),
		flair = T.tally("Legendary and Mythic pets carry a low-rate sparkle emitter"),
		noAssets = T.tally("pets use no external assets (no mesh ids, no textures except built-in particles)"),
		animate = T.tally("Animate runs for 120 frames without errors, NaN or new instances"),
		flap = T.tally("Animate flaps the wings and WingL/WingR mirror each other"),
		pivot = T.tally("Animate is relative to the PrimaryPart (same pose after PivotTo)"),
		clone = T.tally("a Clone() of a pet animates like the original"),
		species = T.tally("pets look different from each other (distinct part-name + colour signatures per species)"),
	}
	local totalParts, maxParts, minParts, maxPet = 0, 0, huge, nil
	local heights = {}
	local signatures = {}
	for _, def in ipairs(PC.Pets) do
		local who = def.Id
		local ok, model = pcall(PB.Build, def, { Scale = 1 })
		local built = ok and typeof(model) == "Instance" and model:IsA("Model") and model.PrimaryPart ~= nil and model.PrimaryPart:IsDescendantOf(model)
		tally.model:case(built, who .. ": " .. tostring(model))
		if built then
			model.Parent = holder
			model:PivotTo(CFrame.new(0, 3000, 0))
			local n = countParts(model)
			totalParts = totalParts + n
			if n > maxParts then
				maxParts, maxPet = n, who
			end
			minParts = min(minParts, n)
			tally.budget:case(n <= budget and n >= 25, who .. ": " .. n .. " parts (25-" .. budget .. ")")
			-- flags
			local badFlags, loudShadows = 0, 0
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") then
					if not (d.Anchored == true and d.CanCollide == false and d.CanTouch == false and d.CanQuery == false and d.Massless == true) then
						badFlags = badFlags + 1
					end
					if d.CastShadow and max(d.Size.X, d.Size.Y, d.Size.Z) < 1.5 then
						loudShadows = loudShadows + 1
					end
				end
			end
			tally.flags:case(badFlags == 0, who .. ": " .. badFlags .. " parts with wrong flags")
			tally.shadows:case(loudShadows <= n * 0.1, who .. ": " .. loudShadows .. " small parts cast shadows")
			-- wings
			local wl, wr = model:FindFirstChild("WingL", true), model:FindFirstChild("WingR", true)
			tally.wings:case(wl ~= nil and wr ~= nil and wl:IsA("BasePart") and wr:IsA("BasePart") and wl ~= wr, who .. ": WingL " .. tostring(wl) .. " WingR " .. tostring(wr))
			-- height + scale
			local h = PB.GetHeight(def)
			heights[#heights + 1] = h
			local ext = model:GetExtentsSize().Y
			local h2model = Instance.new("Model")
			tally.height:case(type(h) == "number" and h >= 2.0 and h <= 3.4 and abs(h - ext) <= 0.35, who .. ": GetHeight " .. tostring(h) .. ", extents " .. fmt(ext, 2))
			h2model:Destroy()
			local bigOk, big = pcall(PB.Build, def, { Scale = 1.4 })
			if bigOk and typeof(big) == "Instance" then
				big.Parent = holder
				local ratio = big:GetExtentsSize().Y / max(ext, 0.01)
				tally.scale:case(abs(ratio - 1.4) <= 0.12, who .. ": scale 1.4 gives " .. fmt(ratio, 2) .. "x")
				big:Destroy()
			else
				tally.scale:case(false, who .. ": Build with Scale failed: " .. tostring(big))
			end
			-- palette
			local look = def.Look
			local function nearest(color, filter)
				local best = huge
				for _, d in ipairs(model:GetDescendants()) do
					if d:IsA("BasePart") and (not filter or filter(d)) then
						best = min(best, K.colorDistance255(d.Color, color))
					end
				end
				return best
			end
			local dp, ds = nearest(look.Primary), nearest(look.Secondary)
			local dw = nearest(look.WingColor, function(d)
				return d.Name:find("^Wing") ~= nil
			end)
			tally.palette:case(dp <= 60 and ds <= 60 and dw <= 70, who .. ": colour distance primary " .. fmt(dp, 0) .. ", secondary " .. fmt(ds, 0) .. ", wing " .. fmt(dw, 0))
			-- eyes
			local eyeParts = partsNamed(model, "^Eye")
			local irisNeon, shine = false, 0
			for _, e in ipairs(eyeParts) do
				if e.Name:find("Shine") then
					shine = shine + 1
				end
				if e.Name:find("Iris") and e.Material == Enum.Material.Neon then
					irisNeon = true
				end
			end
			local eyeOk = #eyeParts >= 4 and shine >= 2 and (not look.Glow or irisNeon or #partsNamed(model, "Iris") == 0)
			if look.Glow then
				local anyNeon = false
				for _, d in ipairs(model:GetDescendants()) do
					if d:IsA("BasePart") and d.Material == Enum.Material.Neon and (d.Name:find("^Eye") or d.Name:find("^Wing")) and not d.Name:find("Shine") then
						anyNeon = true
					end
				end
				eyeOk = eyeOk and anyNeon
			end
			tally.eyes:case(eyeOk, who .. ": " .. #eyeParts .. " eye parts, " .. shine .. " highlights, glow=" .. tostring(look.Glow) .. ", neon iris/edge=" .. tostring(irisNeon))
			-- rarity flair
			local emitters = {}
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("ParticleEmitter") then
					emitters[#emitters + 1] = d
				end
			end
			if def.Rarity == "Legendary" or def.Rarity == "Mythic" then
				local lowRate = #emitters >= 1 and #emitters <= 3
				for _, e in ipairs(emitters) do
					lowRate = lowRate and e.Rate <= 12
				end
				tally.flair:case(lowRate, who .. ": " .. #emitters .. " emitters")
			else
				tally.flair:case(#emitters <= 1, who .. ": " .. #emitters .. " emitters on a " .. def.Rarity .. " pet")
			end
			-- assets: nothing but parts, built-in meshes and built-in particle textures
			local assetBad
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("MeshPart") and (d.MeshId ~= "" or d.TextureID ~= "") then
					assetBad = assetBad or (d.Name .. " is a MeshPart with asset ids")
				elseif d:IsA("SpecialMesh") and (d.MeshId ~= "" or d.TextureId ~= "") then
					assetBad = assetBad or (d.Name .. " is a SpecialMesh with asset ids")
				elseif d:IsA("ParticleEmitter") and d.Texture ~= "" and not d.Texture:find("^rbxasset://textures/particles/") then
					assetBad = assetBad or (d.Name .. ".Texture = " .. d.Texture)
				elseif d:IsA("Decal") or d:IsA("Texture") or d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Sound") or d:IsA("SurfaceAppearance") then
					assetBad = assetBad or (d.ClassName .. " " .. d.Name)
				end
			end
			tally.noAssets:case(assetBad == nil, who .. ": " .. tostring(assetBad))
			-- animation
			local before = Mock.CountDescendants(model)
			local errs = Mock.Errors and #Mock.Errors or 0
			local animOk, animErr = pcall(function()
				for i = 1, 120 do
					PB.Animate(model, i / 30, { Flap = 1, Excited = (i % 40) / 40 })
				end
			end)
			local finite = true
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") and not finiteCFrame(d.CFrame) then
					finite = false
				end
			end
			tally.animate:case(animOk and finite and Mock.CountDescendants(model) == before, who .. ": " .. tostring(animErr) .. " finite=" .. tostring(finite) .. " instances " .. before .. " -> " .. Mock.CountDescendants(model))
			-- flapping: the wings swing by tens of degrees, WingL / WingR mirror each other,
			-- Flap speeds the cycle up and Excited > 0.5 flaps faster
			if wl and wr then
				local function rel(w)
					return model.PrimaryPart.CFrame:ToObjectSpace(w.CFrame)
				end
				local function angle(a, b)
					local d = a:Dot(b)
					return math.deg(math.acos(max(-1, min(1, d))))
				end
				local frames, ups, mirror = {}, {}, 0
				for i = 1, 90 do
					PB.Animate(model, 4 + i / 30, { Flap = 1, Excited = 0 })
					local a, b = rel(wl), rel(wr)
					frames[i] = a
					ups[i] = { a.UpVector, a.RightVector, a.LookVector }
					mirror = max(mirror, abs(a.Position.X + b.Position.X), abs(a.Position.Y - b.Position.Y), abs(a.Position.Z - b.Position.Z))
				end
				local spread = 0
				for i = 1, 90, 3 do
					for j = i + 1, 90, 3 do
						spread = max(spread, angle(ups[i][1], ups[j][1]), angle(ups[i][2], ups[j][2]), angle(ups[i][3], ups[j][3]))
					end
				end
				local function path(flap, excited)
					local fresh = PB.Build(def, {})
					fresh.Parent = holder
					local w = fresh:FindFirstChild("WingL", true)
					local sum, last = 0, nil
					for i = 1, 150 do
						PB.Animate(fresh, 10 + i / 30, { Flap = flap, Excited = excited })
						local r = fresh.PrimaryPart.CFrame:ToObjectSpace(w.CFrame)
						if i > 60 then
							if last then
								sum = sum + angle(r.UpVector, last.UpVector) + angle(r.RightVector, last.RightVector) + angle(r.LookVector, last.LookVector)
							end
							last = r
						end
					end
					fresh:Destroy()
					return sum
				end
				local calm, wild, quick = path(1, 0), path(1, 1), path(2, 0)
				local note = ""
				if spread < 40 then
					note = "wings swing only " .. fmt(spread, 0) .. " degrees (expected about +-35)"
				elseif mirror > 0.05 then
					note = "WingL and WingR are not mirror images (max difference " .. fmt(mirror, 3) .. ")"
				elseif wild < calm * 1.2 then
					note = "Excited = 1 does not flap faster (" .. fmt(wild, 0) .. " vs " .. fmt(calm, 0) .. " degrees travelled)"
				elseif quick < calm * 1.5 then
					note = "Flap = 2 does not flap faster (" .. fmt(quick, 0) .. " vs " .. fmt(calm, 0) .. " degrees travelled)"
				end
				tally.flap:case(note == "", who .. ": " .. note)
			end
			-- relative to the PrimaryPart: two fresh pets with the same animation history, one moved somewhere else
			local twinA, twinB = PB.Build(def, {}), PB.Build(def, {})
			twinA.Parent, twinB.Parent = holder, holder
			twinA:PivotTo(CFrame.new(0, 3000, 0))
			twinB:PivotTo(CFrame.new(-420, 2900, 77) * CFrame.Angles(0.4, 2.1, -0.3))
			for i = 1, 20 do
				PB.Animate(twinA, 20 + i / 30, { Flap = 1, Excited = 0.2 })
				PB.Animate(twinB, 20 + i / 30, { Flap = 1, Excited = 0.2 })
			end
			local worst = 0
			for _, d in ipairs(twinA:GetDescendants()) do
				if d:IsA("BasePart") then
					local o = twinB:FindFirstChild(d.Name, true)
					if o then
						local ra = twinA.PrimaryPart.CFrame:ToObjectSpace(d.CFrame)
						local rb = twinB.PrimaryPart.CFrame:ToObjectSpace(o.CFrame)
						worst = max(worst, (ra.Position - rb.Position).Magnitude, (ra.LookVector - rb.LookVector).Magnitude, (ra.UpVector - rb.UpVector).Magnitude)
					end
				end
			end
			-- and animating again after moving the pet keeps the same relative pose
			twinB:PivotTo(CFrame.new(55, 3100, -9))
			PB.Animate(twinB, 20 + 21 / 30, { Flap = 1, Excited = 0.2 })
			PB.Animate(twinA, 20 + 21 / 30, { Flap = 1, Excited = 0.2 })
			for _, d in ipairs(twinA:GetDescendants()) do
				if d:IsA("BasePart") then
					local o = twinB:FindFirstChild(d.Name, true)
					if o then
						local ra = twinA.PrimaryPart.CFrame:ToObjectSpace(d.CFrame)
						local rb = twinB.PrimaryPart.CFrame:ToObjectSpace(o.CFrame)
						worst = max(worst, (ra.Position - rb.Position).Magnitude, (ra.LookVector - rb.LookVector).Magnitude)
					end
				end
			end
			tally.pivot:case(worst < 0.01, who .. ": the pose differs by " .. fmt(worst, 3) .. " after PivotTo")
			twinA:Destroy()
			twinB:Destroy()
			-- clone
			local copy = model:Clone()
			copy.Parent = holder
			copy:PivotTo(CFrame.new(40, 3000, 40))
			local cloneOk, cloneErr = pcall(function()
				for i = 1, 30 do
					PB.Animate(copy, 30 + i / 30, { Flap = 1, Excited = 0 })
				end
			end)
			local cw = copy:FindFirstChild("WingL", true)
			local moved = false
			if cw and copy.PrimaryPart then
				local r0 = copy.PrimaryPart.CFrame:ToObjectSpace(cw.CFrame).Position
				PB.Animate(copy, 31.2, { Flap = 1, Excited = 0 })
				local r1 = copy.PrimaryPart.CFrame:ToObjectSpace(cw.CFrame).Position
				moved = (r1 - r0).Magnitude > 0.001
			end
			tally.clone:case(cloneOk and copy.PrimaryPart ~= nil and copy.PrimaryPart ~= model.PrimaryPart and moved, who .. ": " .. tostring(cloneErr) .. " primary " .. tostring(copy.PrimaryPart) .. " moved " .. tostring(moved))
			copy:Destroy()
			-- silhouette signature
			local names = {}
			for _, d in ipairs(model:GetChildren()) do
				names[#names + 1] = d.Name:gsub("%d+$", "")
			end
			table.sort(names)
			local sig = look.Species .. "|" .. look.WingStyle .. "|" .. tostring(look.Accessory) .. "|" .. string.format("%d,%d,%d", look.Primary.R * 255, look.Primary.G * 255, look.Primary.B * 255)
			tally.species:case(not signatures[sig], who .. ": same species / wings / accessory / colour as " .. tostring(signatures[sig]))
			signatures[sig] = who
			model:Destroy()
		end
	end
	for _, tl in pairs(tally) do
		tl:report()
	end
	T.info(string.format("*pets built: %d  parts per pet %d-%d (avg %.0f, largest %s)  heights %.2f-%.2f", #PC.Pets, minParts == huge and 0 or minParts, maxParts, totalParts / max(#PC.Pets, 1), tostring(maxPet),
		(function()
			local m = huge
			for _, v in ipairs(heights) do
				m = min(m, v)
			end
			return m == huge and 0 or m
		end)(), (function()
			local m = 0
			for _, v in ipairs(heights) do
				m = max(m, v)
			end
			return m
		end)()))
	-- the mascot looks like the icon
	local dragon = PC.Get(CONTRACT.v2.mascotPetId)
	if dragon then
		local model = PB.Build(dragon, { Scale = 1 })
		model.Parent = holder
		local horns = partsNamed(model, "^Horn")
		T.check(#horns >= 2, "Cloudy Dragon has two horns", #horns .. " horn parts")
		local gold = 0
		for _, h in ipairs(horns) do
			local c = h.Color
			if c.R > 0.75 and c.G > 0.55 and c.B < 0.55 and c.R >= c.G then
				gold = gold + 1
			end
		end
		T.check(gold >= 2, "Cloudy Dragon's horns are gold", gold .. " gold horn parts")
		T.check(#partsNamed(model, "^Nostril") == 2, "Cloudy Dragon has two nostril dots", #partsNamed(model, "^Nostril") .. "")
		T.check(#partsNamed(model, "^Eye") >= 6, "Cloudy Dragon has big eyes with sparkle highlights", #partsNamed(model, "^Eye") .. " eye parts")
		T.check(#partsNamed(model, "Tail") >= 3, "Cloudy Dragon has a tail with a cloud-puff tip", #partsNamed(model, "Tail") .. " tail parts")
		T.check(#partsNamed(model, "^Wing[LR]") >= 6, "Cloudy Dragon's cloud wings are made of several puffs", #partsNamed(model, "^Wing[LR]") .. " wing parts")
		local belly = partsNamed(model, "^Belly")
		T.check(#belly >= 1 and belly[1].Color.R > 0.85 and belly[1].Color.B < belly[1].Color.R, "Cloudy Dragon has a cream belly", belly[1] and tostring(belly[1].Color))
		model:Destroy()
	end
	-- defensive: unknown Species / WingStyle / Accessory fall back, never raise
	local weird = {
		Id = "weird", Name = "Weird", Rarity = "Common", Blurb = "-",
		Look = { Species = "Blob", WingStyle = "Laser", Accessory = "Hat", Primary = Color3.fromRGB(10, 200, 10), Secondary = Color3.fromRGB(200, 10, 10), Eye = Color3.fromRGB(0, 0, 0), WingColor = Color3.fromRGB(250, 250, 10) },
		Perks = {},
	}
	local weirdOk, weirdModel = pcall(PB.Build, weird, { Scale = 1 })
	T.check(weirdOk and typeof(weirdModel) == "Instance" and weirdModel:FindFirstChild("WingL", true) ~= nil, "unknown Species / WingStyle / Accessory fall back to Cat / Feather / none without erroring", tostring(weirdModel))
	if weirdOk and typeof(weirdModel) == "Instance" then
		weirdModel:Destroy()
	end
	-- every species x wing style x accessory builds within budget (small synthetic matrix)
	local combos, worstCombo, comboBad = 0, 0, nil
	for _, species in ipairs(PC.Species) do
		for wi, wing in ipairs(PC.WingStyles or { "Feather", "Bat", "Fairy", "Cloud", "Crystal", "Flame" }) do
			local acc = (PC.Accessories or { "Horns", "Crown", "Halo", "Leaf", "Mushroom", "Scarf", "Antlers", "Flower" })[(wi + #species) % 9 + 1]
			local d = {
				Id = "combo", Name = "Combo", Rarity = (wi % 2 == 0) and "Mythic" or "Common", Blurb = "-",
				Look = { Species = species, WingStyle = wing, Accessory = acc, Glow = wi % 2 == 0, Primary = Color3.fromRGB(180, 120, 90), Secondary = Color3.fromRGB(240, 220, 200), Eye = Color3.fromRGB(30, 30, 50), WingColor = Color3.fromRGB(200, 160, 220) },
				Perks = {},
			}
			local okc, m = pcall(PB.Build, d, { Scale = 1 })
			combos = combos + 1
			if not okc or typeof(m) ~= "Instance" then
				comboBad = comboBad or (species .. "/" .. wing .. "/" .. tostring(acc) .. ": " .. tostring(m))
			else
				local n = countParts(m)
				worstCombo = max(worstCombo, n)
				if n > budget then
					comboBad = comboBad or (species .. "/" .. wing .. "/" .. tostring(acc) .. ": " .. n .. " parts")
				end
				m:Destroy()
			end
		end
	end
	T.check(comboBad == nil, "every Species x WingStyle x Accessory combination builds within the part budget (" .. combos .. " combos, worst " .. worstCombo .. " parts)", comboBad)
	holder:Destroy()
	flushErrors("petbuilder")
	flushWarnings("petbuilder")
end)

return S
