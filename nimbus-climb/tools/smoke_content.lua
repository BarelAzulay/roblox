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

return S
