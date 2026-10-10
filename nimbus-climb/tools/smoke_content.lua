-- smoke_content.lua: scenarios for the game's CONTENT (no player needed, only the loaded modules):
--   catalog      PetCatalog / ItemCatalog data, roulette odds, RollPet frequencies, perks; v3 roles / stats /
--                specials, Secret pets (never rollable), GetStats, IndexGroups, TotalCount, elements and Stormfang
--   config_shape Config.* tables the v2 systems read (difficulties, archetypes, themes, rarities, roulettes ...) and
--                the v3 additions (remotes, Index rewards, tutorial gift, pet stats, the element wheel, Config.Art)
--   petbuilder   PetBuilder.Build / Animate / GetHeight for every pet at both detail levels (High <= 350, Low <= 120
--                parts), wings, flags, the species x wing x accessory matrix, and Stormfang's look vs the player's art
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

local function perkSum(def)
	local sum = 0
	for _, v in pairs(def.Perks or {}) do
		if type(v) == "number" then
			sum = sum + v
		end
	end
	return sum
end

-- ARCHITECTURE_V3.md section 2: roles, stats, specials, Secret pets, GetStats, IndexGroups, TotalCount.
local function catalogV3(PC, Config, rank)
	local SECRET = CONTRACT.v3.secretRarity
	local roleSet, kindSet = {}, {}
	for _, r in ipairs(Config.PetStats.Roles) do
		roleSet[r] = true
	end
	for _, k in ipairs(PC.SpecialKinds or { "Blast", "Heal", "Shield", "Storm", "Pounce", "Freeze", "Beam" }) do
		kindSet[k] = true
	end
	local roles = T.tally("every pet has a Role (Economy | Combat) and positive base Stats { Income, Power, Health, Speed }")
	local fit = T.tally("Economy pets earn more than they hit (Income > Power); Combat pets the opposite")
	local specials = T.tally("every pet has a Special { Id (unique), Name, Kind, Power > 0, Color }")
	local perRole = {}
	local specialIds = {}
	for _, def in ipairs(PC.Pets) do
		local st = def.Stats
		local statsOk = type(st) == "table"
		if statsOk then
			for _, key in ipairs({ "Income", "Power", "Health", "Speed" }) do
				statsOk = statsOk and T.finite(st[key]) and st[key] > 0
			end
		end
		roles:case(roleSet[def.Role] == true and statsOk, def.Id .. ": Role " .. tostring(def.Role) .. ", Stats " .. tostring(st))
		if statsOk then
			fit:case((def.Role == "Economy" and st.Income > st.Power) or (def.Role == "Combat" and st.Power > st.Income), def.Id .. ": " .. tostring(def.Role) .. " with Income " .. st.Income .. " / Power " .. st.Power)
		end
		local sp = def.Special
		local spOk = type(sp) == "table" and type(sp.Id) == "string" and sp.Id ~= "" and not specialIds[sp.Id] and type(sp.Name) == "string" and #sp.Name > 2
			and kindSet[sp.Kind] == true and T.finite(sp.Power) and sp.Power > 0 and typeof(sp.Color) == "Color3"
		specials:case(spOk, def.Id .. ": Special " .. (type(sp) == "table" and (tostring(sp.Id) .. "/" .. tostring(sp.Kind)) or tostring(sp)))
		if type(sp) == "table" and type(sp.Id) == "string" then
			specialIds[sp.Id] = true
		end
		perRole[def.Rarity] = perRole[def.Rarity] or { Economy = 0, Combat = 0, n = 0 }
		local pr = perRole[def.Rarity]
		pr.n = pr.n + 1
		if def.Role == "Economy" or def.Role == "Combat" then
			pr[def.Role] = pr[def.Role] + 1
		end
	end
	roles:report()
	fit:report()
	specials:report()
	-- "roughly half of each per rarity"
	local split = T.tally("every rarity mixes Economy and Combat pets (roughly half each)")
	local splitText = {}
	for _, r in ipairs(Config.Rarities) do
		local pr = perRole[r.Id]
		if pr then
			splitText[#splitText + 1] = string.format("%s %d/%d", r.Id, pr.Economy, pr.Combat)
			if pr.n >= 2 then
				split:case(pr.Economy >= 1 and pr.Combat >= 1 and abs(pr.Economy - pr.Combat) <= math.max(1, math.floor(pr.n / 2)), r.Id .. ": " .. pr.Economy .. " Economy / " .. pr.Combat .. " Combat")
			end
		end
	end
	split:report("Economy/Combat: " .. table.concat(splitText, "  "))
	-- the mascot's signature special
	local dragon = PC.Get(CONTRACT.v2.mascotPetId)
	if dragon then
		T.eq(dragon.Role, "Combat", "the Cloudy Dragon is a Combat pet")
		T.check(type(dragon.Special) == "table" and dragon.Special.Name == "Cloud Breath" and dragon.Special.Kind == "Beam", "the Cloudy Dragon's special is 'Cloud Breath' (Kind Beam)", type(dragon.Special) == "table" and (tostring(dragon.Special.Name) .. " / " .. tostring(dragon.Special.Kind)) or "")
	end

	-- Secret pets: glowing, never rollable from any current roulette, stronger than the best Mythic
	local secrets = PC.ListByRarity(SECRET)
	local bestMythic = 0
	for _, def in ipairs(PC.ListByRarity("Mythic")) do
		bestMythic = max(bestMythic, perkSum(def))
	end
	local secretTally = T.tally("Secret pets glow (Look.Glow) and their perks beat the best Mythic (" .. string.format("%.2f", bestMythic) .. ")")
	for _, def in ipairs(secrets) do
		secretTally:case(def.Look.Glow == true and perkSum(def) >= bestMythic, def.Id .. ": glow " .. tostring(def.Look.Glow) .. ", perks " .. string.format("%.2f", perkSum(def)))
	end
	secretTally:report()
	local rollable = {}
	for _, r in ipairs(Config.Roulettes) do
		for _, o in ipairs(PC.GetOdds(r.Id)) do
			rollable[o.PetId] = r.Id
		end
		for _, def in ipairs(PC.PossiblePets(r.Id)) do
			rollable[def.Id] = rollable[def.Id] or r.Id
		end
	end
	local leaked = {}
	for _, def in ipairs(secrets) do
		if rollable[def.Id] then
			leaked[#leaked + 1] = def.Id .. " (" .. rollable[def.Id] .. ")"
		end
	end
	T.check(#leaked == 0, "no current roulette can roll a Secret pet (they come from the phase-2 gems-only roulette)", table.concat(leaked, ", "))
	local Util = M["shared/Util"]
	local rng = Util and Util.NewRng and Util.NewRng(31337)
	if rng then
		local secretRolls = 0
		for _, r in ipairs(Config.Roulettes) do
			for _ = 1, 400 do
				local id = PC.RollPet(r.Id, rng)
				local def = id and PC.Get(id)
				if def and def.Rarity == SECRET then
					secretRolls = secretRolls + 1
				end
			end
		end
		T.eq(secretRolls, 0, "1600 RollPet calls over every roulette never return a Secret pet")
	end

	-- GetStats(petId, level) = base * RarityScale[rarity] * (1 + 0.1 * (level - 1))
	local stats = T.tally("GetStats(petId, level) = base * RarityScale * (1 + 0.1 * (level - 1)) for levels 1, 2, 10")
	for _, def in ipairs(PC.Pets) do
		local scale = Config.PetStats.RarityScale[def.Rarity] or 1
		for _, level in ipairs({ 1, 2, 10 }) do
			local got = PC.GetStats(def.Id, level)
			local ok = type(got) == "table"
			for _, key in ipairs({ "Income", "Power", "Health", "Speed" }) do
				local want = def.Stats[key] * scale * (1 + 0.1 * (level - 1))
				ok = ok and T.finite(got[key]) and abs(got[key] - want) <= 1e-6 * max(1, want)
			end
			stats:case(ok, def.Id .. " level " .. level)
		end
	end
	stats:report()
	local one, none = PC.GetStats(CONTRACT.v2.mascotPetId), PC.GetStats(CONTRACT.v2.mascotPetId, 1)
	T.check(type(one) == "table" and type(none) == "table" and one.Power == none.Power, "GetStats(petId) defaults to level 1")
	local okBad, bad = pcall(PC.GetStats, "ghost_pet", 3)
	T.check(okBad and bad == nil, "GetStats of an unknown pet is nil (never raises)", tostring(bad))
	local okWeird, weird = pcall(PC.GetStats, CONTRACT.v2.mascotPetId, -4)
	T.check(okWeird and type(weird) == "table" and weird.Power == one.Power, "GetStats clamps a level below 1 to level 1")

	-- IndexGroups: one group per rarity that has pets, rarity order, Secret last, Config.Index rewards
	local groups = PC.IndexGroups()
	local order, seen, covered, groupsOk = {}, {}, 0, type(groups) == "table"
	local lastRank = 0
	for i, g in ipairs(groupsOk and groups or {}) do
		order[#order + 1] = tostring(g.Id)
		local list = PC.ListByRarity(g.Id)
		local same = type(g.Pets) == "table" and #g.Pets == #list and #list > 0
		for j, def in ipairs(list) do
			same = same and g.Pets[j] == def
			seen[def.Id] = (seen[def.Id] or 0) + 1
		end
		covered = covered + #list
		local want = Config.Index.Rewards[g.Id]
		local rewardOk = type(g.Reward) == "table" and type(want) == "table" and g.Reward.Tokens == want.Tokens
		T.check(g.Id == g.Rarity and rank[g.Id] ~= nil and rank[g.Id] > lastRank and same, "IndexGroups()[" .. i .. "] is the " .. tostring(g.Id) .. " group (ListByRarity, rarity order)")
		T.check(rewardOk, tostring(g.Id) .. " group reward = Config.Index.Rewards." .. tostring(g.Id) .. " (" .. tostring(want and want.Tokens) .. " tokens)", type(g.Reward) == "table" and tostring(g.Reward.Tokens) or tostring(g.Reward))
		lastRank = rank[g.Id] or lastRank
	end
	local rarityWithPets = 0
	for _, r in ipairs(Config.Rarities) do
		if #PC.ListByRarity(r.Id) > 0 then
			rarityWithPets = rarityWithPets + 1
		end
	end
	T.check(groupsOk and #groups == rarityWithPets and covered == #PC.Pets, "IndexGroups() covers every pet exactly once (" .. rarityWithPets .. " groups)", table.concat(order, ","))
	T.eq(order[#order], SECRET, "the Secret group comes last")
	if groupsOk and groups[1] then
		groups[1].Pets[1] = nil
		groups[1].Reward.Tokens = -1
		local again = PC.IndexGroups()
		T.check(again[1].Pets[1] ~= nil and again[1].Reward.Tokens > 0, "IndexGroups() returns fresh tables (a caller cannot corrupt the catalog)")
	end
end

-- ARCHITECTURE_V3.md section 11: one Element per pet, the wheel and the Celestial / Shadow pair.
local function catalogElements(PC, Config)
	local E = Config.Elements
	local anyElement = false
	for _, def in ipairs(PC.Pets) do
		if def.Element ~= nil then
			anyElement = true
		end
	end
	local helpers = type(PC.ElementMultiplier) == "function" or type(PC.GetElements) == "function" or type(PC.ElementsOf) == "function"
	if not anyElement and not helpers then
		T.warn("PetCatalog has no pet Elements yet (ARCHITECTURE_V3.md section 11: Element on every pet + GetElements / ElementMultiplier / ElementsOf)")
		return
	end
	local valid = {}
	for _, e in ipairs(E.Order) do
		valid[e] = true
	end
	local byElement, rarities = {}, {}
	local each = T.tally("every pet has one Element from Config.Elements.Order")
	for _, def in ipairs(PC.Pets) do
		each:case(valid[def.Element] == true, def.Id .. ": Element " .. tostring(def.Element))
		if valid[def.Element] then
			byElement[def.Element] = (byElement[def.Element] or 0) + 1
			rarities[def.Element] = rarities[def.Element] or {}
			rarities[def.Element][def.Rarity] = true
		end
	end
	each:report()
	local spread = T.tally("every element has at least " .. CONTRACT.v3.elements.minPetsPerElement .. " pets across several rarities")
	local text = {}
	for _, e in ipairs(E.Order) do
		local nR = 0
		for _ in pairs(rarities[e] or {}) do
			nR = nR + 1
		end
		text[#text + 1] = e .. " " .. (byElement[e] or 0)
		spread:case((byElement[e] or 0) >= CONTRACT.v3.elements.minPetsPerElement and nR >= 2, e .. ": " .. (byElement[e] or 0) .. " pets in " .. nR .. " rarities")
	end
	spread:report(table.concat(text, "  "))
	-- theme rules that are spelled out in the doc
	local function elementOf(id)
		local def = PC.Get(id)
		return def and def.Element
	end
	if PC.Get(CONTRACT.v3.stormfang.petId) then
		T.eq(elementOf(CONTRACT.v3.stormfang.petId), CONTRACT.v3.stormfang.element, "Stormfang is a " .. CONTRACT.v3.stormfang.element .. " pet")
	end
	-- (dark Secret pets may be Shadow instead: "dark Secrets -> Shadow")
	local speciesRule = T.tally("species elements follow the doc (Phoenix -> Flame, Penguin -> Frost; dark Secrets may be Shadow)")
	for _, def in ipairs(PC.Pets) do
		local darkSecret = def.Rarity == CONTRACT.v3.secretRarity and def.Element == "Shadow"
		if def.Look.Species == "Phoenix" and not darkSecret then
			speciesRule:case(def.Element == "Flame", def.Id .. ": Phoenix with Element " .. tostring(def.Element))
		elseif def.Look.Species == "Penguin" and not darkSecret then
			speciesRule:case(def.Element == "Frost", def.Id .. ": Penguin with Element " .. tostring(def.Element))
		end
	end
	speciesRule:report()
	-- helpers
	if T.check(type(PC.ElementMultiplier) == "function", "PetCatalog.ElementMultiplier(attack, defend) exists") then
		local wheel, pair = CONTRACT.v3.elements.wheel, CONTRACT.v3.elements.pair
		local strong, weak = CONTRACT.v3.elements.strong, CONTRACT.v3.elements.weak
		local chart = T.tally("ElementMultiplier follows the wheel (x" .. strong .. " / x" .. weak .. " / x1) and the Celestial <-> Shadow pair")
		local function want(a, d)
			for i, e in ipairs(wheel) do
				local nextE = wheel[i % #wheel + 1]
				if a == e and d == nextE then
					return strong
				elseif d == e and a == nextE then
					return weak
				end
			end
			if (a == pair[1] and d == pair[2]) or (a == pair[2] and d == pair[1]) then
				return strong
			end
			return 1
		end
		for _, a in ipairs(E.Order) do
			for _, d in ipairs(E.Order) do
				local ok, got = pcall(PC.ElementMultiplier, a, d)
				chart:case(ok and type(got) == "number" and abs(got - want(a, d)) < 1e-9, a .. " vs " .. d .. ": " .. tostring(got) .. " (want " .. want(a, d) .. ")")
			end
		end
		chart:report()
		local okJunk, junk = pcall(PC.ElementMultiplier, "Plasma", nil)
		T.check(okJunk and junk == 1, "ElementMultiplier of unknown elements is x1 (never raises)", tostring(junk))
	end
	if T.check(type(PC.GetElements) == "function", "PetCatalog.GetElements(petId) exists") then
		local got = PC.GetElements(CONTRACT.v2.mascotPetId)
		T.check(type(got) == "table" and got[1] == elementOf(CONTRACT.v2.mascotPetId), "GetElements(petId) lists the pet's element", type(got) == "table" and table.concat(got, ",") or tostring(got))
		local okNo, none = pcall(PC.GetElements, "ghost_pet")
		T.check(okNo and (none == nil or (type(none) == "table" and #none == 0)), "GetElements of an unknown pet is empty / nil")
	end
	if T.check(type(PC.ElementsOf) == "function", "PetCatalog.ElementsOf(def) exists") then
		local dragon = PC.Get(CONTRACT.v2.mascotPetId)
		local got = PC.ElementsOf(dragon)
		T.check(type(got) == "table" and got[1] == dragon.Element, "ElementsOf(def) lists the definition's element")
		local hybrid = PC.ElementsOf({ Elements = { "Water", "Flame", "Water" } })
		T.check(type(hybrid) == "table" and #hybrid == 2, "ElementsOf a fused hybrid ({ Elements = {...} }) is deduplicated", type(hybrid) == "table" and table.concat(hybrid, ",") or tostring(hybrid))
	end
end

-- ARCHITECTURE_V3.md section 10: the player's own creature. Checked once it is in the catalog.
local function catalogStormfang(PC, Config)
	local spec = CONTRACT.v3.stormfang
	local def = PC.Get(spec.petId)
	if not def then
		T.warn("Stormfang (" .. spec.petId .. ") is not in the catalog yet (ARCHITECTURE_V3.md section 10)")
		return
	end
	local SECRET = CONTRACT.v3.secretRarity
	T.eq(def.Name, spec.name, "Stormfang: Name")
	T.eq(def.Rarity, SECRET, "Stormfang: Rarity Secret")
	T.eq(def.Role, spec.role, "Stormfang: Role Combat")
	T.eq(def.Look.Species, spec.species, "Stormfang: its own species (not a recoloured Fox / Cat)")
	T.eq(def.Look.WingStyle, spec.wingStyle, "Stormfang: rides a storm cloud (WingStyle StormCloud)")
	T.check(T.contains(PC.Species, spec.species) and T.contains(PC.WingStyles or {}, spec.wingStyle), "PetCatalog.Species / WingStyles list Stormfang and StormCloud")
	T.eq(def.Look.Glow, true, "Stormfang: Glow (neon accents)")
	local sp = def.Special or {}
	T.check(sp.Name == "Storm Pounce" and sp.Kind == spec.specialKind, "Stormfang: Special 'Storm Pounce' (Kind Pounce)", tostring(sp.Name) .. " / " .. tostring(sp.Kind))
	if typeof(sp.Color) == "Color3" then
		T.check(sp.Color.B > 0.7 and sp.Color.B > sp.Color.R + 0.2, "Stormfang: the special is electric blue", tostring(sp.Color))
	end
	local secrets = PC.ListByRarity(SECRET)
	T.check(secrets[1] == def, "Stormfang is listed first among the Secrets (the player's signature creature)", secrets[1] and secrets[1].Id or "")
	local topPerks, topPower = true, true
	for _, other in ipairs(secrets) do
		if other ~= def then
			topPerks = topPerks and perkSum(def) >= perkSum(other) - 1e-9
			topPower = topPower and def.Stats.Power >= other.Stats.Power
		end
	end
	T.check(topPerks, "Stormfang: perks at the top of the Secret tier", string.format("%.2f", perkSum(def)))
	T.check(topPower, "Stormfang: Power at the top of the Secret tier", tostring(def.Stats.Power))
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
	local SECRET = CONTRACT.v3.secretRarity
	local stormfangId = CONTRACT.v3.stormfang.petId
	-- lineup
	local counts, total = {}, 0
	local ids, names = {}, {}
	local speciesUsed, wingUsed, accessoryUsed = {}, {}, {}
	local shape = T.tally("every pet has a valid Id / Name / Rarity / Blurb / Look / Perks")
	local sorted = true
	-- sort key inside one rarity: Name, except that Stormfang (the player's signature creature) leads the Secrets
	local function leads(def)
		return def.Id == stormfangId and def.Rarity == SECRET
	end
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
			if a > b or (a == b and leads(def)) or (a == b and not leads(prev) and prev.Name > def.Name) then
				sorted = false
			end
		end
		T.check(PC.ById[def.Id] == def and PC.Get(def.Id) == def, def.Id .. ": ById / Get return the definition")
	end
	shape:report()
	T.check(sorted, "PetCatalog.Pets is sorted by rarity order, then Name (Stormfang, the player's own creature, leads the Secrets)")
	-- the v2 rarities keep their v2 lineup; v3 adds the Secret tier (3 dark Secrets + Stormfang) after the Mythics
	for rarity, want in pairs(CONTRACT.v2.petCounts) do
		T.eq(counts[rarity] or 0, want, "lineup has " .. want .. " " .. rarity .. " pets")
		T.eq(#PC.ListByRarity(rarity), want, "ListByRarity('" .. rarity .. "') returns them")
	end
	T.check((counts[SECRET] or 0) >= CONTRACT.v3.minSecretPets, "lineup has at least " .. CONTRACT.v3.minSecretPets .. " Secret pets", tostring(counts[SECRET]))
	T.eq(#PC.ListByRarity(SECRET), counts[SECRET] or 0, "ListByRarity('Secret') returns them")
	local perRarity = 0
	for _, r in ipairs(Config.Rarities) do
		perRarity = perRarity + (counts[r.Id] or 0)
	end
	T.eq(perRarity, total, "every pet's rarity is a Config.Rarities id (the per-rarity counts add up to the lineup)")
	T.eq(PC.TotalCount(), total, "PetCatalog.TotalCount() is the size of the lineup (" .. total .. " pets, Secret pets included)")
	T.check(#PC.ListByRarity("NoSuchRarity") == 0, "ListByRarity of an unknown rarity is empty")
	T.check(PC.Get("nope") == nil and PC.Get(nil) == nil and PC.Get(5) == nil, "Get of an unknown id is nil")
	local missing = {}
	for _, s in ipairs(PC.Species) do
		if not speciesUsed[s] then
			missing[#missing + 1] = s
		end
	end
	T.check(#missing == 0, "every species is used by at least one pet", "unused: " .. table.concat(missing, ", "))
	for _, s in ipairs({ "Cat", "Dog", "Fox", "Bunny", "Bear", "Panda", "Dragon", "Owl", "Slime", "Unicorn", "Phoenix", "Frog", "Penguin", "Axolotl" }) do
		T.check(T.contains(PC.Species, s), "PetCatalog.Species keeps the v2 species " .. s)
	end
	local PB = M["shared/PetBuilder"]
	if PB and type(PB.Species) == "table" then
		local unbuilt = {}
		for _, s in ipairs(PC.Species) do
			if not T.contains(PB.Species, s) then
				unbuilt[#unbuilt + 1] = s
			end
		end
		T.check(#unbuilt == 0, "PetBuilder sculpts every catalog species (PetBuilder.Species)", "missing: " .. table.concat(unbuilt, ", "))
	end
	-- the v2 wing styles / accessories stay, and every value the catalog lists is used by some pet
	local function withExtras(base, extra)
		local out = {}
		for _, v in ipairs(base) do
			out[#out + 1] = v
		end
		for _, v in ipairs(extra or {}) do
			if not T.contains(out, v) then
				out[#out + 1] = v
			end
		end
		return out
	end
	for _, wstyle in ipairs(withExtras({ "Feather", "Bat", "Fairy", "Cloud", "Crystal", "Flame" }, PC.WingStyles)) do
		T.check(wingUsed[wstyle] == true, "wing style " .. wstyle .. " is used by a pet")
	end
	for _, acc in ipairs(withExtras({ "Horns", "Crown", "Halo", "Leaf", "Mushroom", "Scarf", "Antlers", "Flower" }, PC.Accessories)) do
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
		-- v3: the Secret tier (Order 7) sorts after the Mythics, so the mascot closes the rollable lineup instead of the list
		local at, firstSecret = nil, nil
		for i, def in ipairs(PC.Pets) do
			if def == dragon then
				at = i
			end
			if def.Rarity == SECRET and not firstSecret then
				firstSecret = i
			end
		end
		local tailOk = at ~= nil
		for i = (at or 1) + 1, #PC.Pets do
			local r = PC.Pets[i].Rarity
			if r ~= "Mythic" and r ~= SECRET then
				tailOk = false
			end
		end
		local mythics = PC.ListByRarity("Mythic")
		T.check(tailOk and (dragon == mythics[#mythics] or dragon == mythics[#mythics - 1]), "the mascot is one of the two Mythics at the end of the rollable lineup (only Mythics / Secrets follow it)", "index " .. tostring(at) .. " of " .. #PC.Pets)
		local secretsLast = true
		if firstSecret then
			for i = firstSecret, #PC.Pets do
				if PC.Pets[i].Rarity ~= SECRET then
					secretsLast = false
				end
			end
		end
		T.check(secretsLast, "the Secret pets close the list (rarity Order 7)")
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
		-- a rarity with no pets yet (v3's Secret rarity before its pets are added) has no average to compare
		if counts[r.Id] then
			local mean = meanPerk[r.Id] or 0
			line[#line + 1] = string.format("%s %.3f", r.Id, mean)
			if mean < prevMean then
				scales = false
			end
			prevMean = mean
		end
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

	-- v3: roles / stats / specials / Secret pets / GetStats / IndexGroups, elements and Stormfang
	catalogV3(PC, Config, rank)
	catalogElements(PC, Config)
	catalogStormfang(PC, Config)

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
		if not r.AllowSecret then
			T.check((byRarity[CONTRACT.v3.secretRarity] or 0) == 0, r.Id .. ": never offers Secret pets")
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
	T.eq(#Config.Rarities, 7, "seven rarities (v3 adds Secret)")
	T.eq(Config.Rarities[7].Id, "Secret", "the seventh rarity is Secret")
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

	-- v3 (ARCHITECTURE_V3.md): currencies, remotes, home plots, Pet Index, tutorial, pet stats, elements, art
	for _, name in ipairs(CONTRACT.v3.tutorialRemotes) do
		T.check(T.contains(Config.Remotes, name), "Config.Remotes lists " .. name)
	end
	local remoteSeen, dupRemotes = {}, {}
	for _, name in ipairs(Config.Remotes) do
		if remoteSeen[name] then
			dupRemotes[#dupRemotes + 1] = name
		end
		remoteSeen[name] = true
	end
	T.check(#dupRemotes == 0, "every Config.Remotes name is unique", table.concat(dupRemotes, ", "))
	T.check(Config.Attr.Cash == "Cash" and Config.Attr.Gems == "Gems", "Config.Attr.Cash / Gems exist (phase-2 currencies)")
	T.check(Config.Lobby.PlotSize >= 48 and 2 * math.pi * Config.Lobby.SpotRingRadius / Config.Lobby.SpotCount > Config.Lobby.PlotSize + 20,
		"home plots (PlotSize " .. tostring(Config.Lobby.PlotSize) .. ") fit side by side on the spot ring (radius " .. tostring(Config.Lobby.SpotRingRadius) .. ")")
	local rewardPrev, rewardOk, rewardText = 0, true, {}
	for _, r in ipairs(Config.Rarities) do
		local reward = Config.Index.Rewards[r.Id]
		local tokens = type(reward) == "table" and reward.Tokens
		rewardText[#rewardText + 1] = r.Id .. " " .. tostring(tokens)
		if not (type(tokens) == "number" and tokens > rewardPrev and tokens == floor(tokens)) then
			rewardOk = false
		end
		rewardPrev = type(tokens) == "number" and tokens or rewardPrev
	end
	T.check(rewardOk, "Config.Index.Rewards: a whole-token reward for every rarity, growing with rarity", table.concat(rewardText, ", "))
	local cheapestPrice = huge
	for _, r in ipairs(Config.Roulettes) do
		cheapestPrice = min(cheapestPrice, r.Price)
	end
	T.check(type(Config.Tutorial.GiftTokens) == "number" and Config.Tutorial.GiftTokens >= cheapestPrice, "the tutorial gift (" .. tostring(Config.Tutorial.GiftTokens) .. ") pays for the cheapest roulette spin (" .. cheapestPrice .. ")")
	T.check(type(Config.Tutorial.FinishReward) == "table" and type(Config.Tutorial.FinishReward.Tokens) == "number" and Config.Tutorial.FinishReward.Tokens > 0, "Config.Tutorial.FinishReward.Tokens is a positive reward")
	T.eq(table.concat(Config.PetStats.Roles, ","), "Economy,Combat", "Config.PetStats.Roles")
	local scalePrev, scaleOk = 0, true
	for _, r in ipairs(Config.Rarities) do
		local sc = Config.PetStats.RarityScale[r.Id]
		if not (type(sc) == "number" and sc > scalePrev) then
			scaleOk = false
		end
		scalePrev = type(sc) == "number" and sc or scalePrev
	end
	T.check(scaleOk, "Config.PetStats.RarityScale grows with every rarity (Common 1 ... Secret)")
	-- elements: eight of them, the wheel Water > Flame > Frost > Nature > Earth > Storm > Water and Celestial <-> Shadow
	local E = Config.Elements
	local wheel, pair = CONTRACT.v3.elements.wheel, CONTRACT.v3.elements.pair
	local wantOrder = {}
	for _, e in ipairs(wheel) do
		wantOrder[#wantOrder + 1] = e
	end
	for _, e in ipairs(pair) do
		wantOrder[#wantOrder + 1] = e
	end
	T.eq(table.concat(E.Order, ","), table.concat(wantOrder, ","), "Config.Elements.Order lists the eight elements")
	local infoOk, colors = true, {}
	for _, e in ipairs(E.Order) do
		local info = E.Info[e]
		infoOk = infoOk and type(info) == "table" and typeof(info.Color) == "Color3" and type(info.Blurb) == "string" and #info.Blurb > 3
		if type(info) == "table" and typeof(info.Color) == "Color3" then
			colors[#colors + 1] = { e, info.Color }
		end
	end
	T.check(infoOk, "every element has Info { Color, Blurb } (badges use the colour, no asset ids)")
	local closest, closestPair = huge, ""
	for i = 1, #colors do
		for j = i + 1, #colors do
			local d = K.colorDistance255(colors[i][2], colors[j][2])
			if d < closest then
				closest, closestPair = d, colors[i][1] .. "/" .. colors[j][1]
			end
		end
	end
	T.check(closest > 40, "element badge colours are distinct (closest pair " .. closestPair .. ")", fmt(closest, 0))
	local chartOk = true
	for i, e in ipairs(wheel) do
		local beats = E.Strong[e]
		chartOk = chartOk and type(beats) == "table" and #beats == 1 and beats[1] == wheel[i % #wheel + 1]
	end
	chartOk = chartOk and type(E.Strong[pair[1]]) == "table" and E.Strong[pair[1]][1] == pair[2] and type(E.Strong[pair[2]]) == "table" and E.Strong[pair[2]][1] == pair[1]
	T.check(chartOk, "Config.Elements.Strong is the wheel (each beats the next) plus the Celestial <-> Shadow pair")
	T.check(E.StrongMultiplier == CONTRACT.v3.elements.strong and E.WeakMultiplier == CONTRACT.v3.elements.weak, "element damage: strong x" .. CONTRACT.v3.elements.strong .. ", weak x" .. CONTRACT.v3.elements.weak)
	T.eq(Config.Art.StormfangImage, CONTRACT.v3.artImage, "Config.Art.StormfangImage is the player's uploaded Stormfang sheet")
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
	-- ARCHITECTURE_V3.md "ART DIRECTION": two levels of detail, High (default) <= ~350 parts, Low <= ~120 parts
	local budget = CONTRACT.v3.partBudget.petHigh
	local lowBudget = CONTRACT.v3.partBudget.petLow
	local holder = Instance.new("Folder")
	holder.Name = "SmokePets"
	holder.Parent = workspace
	local tally = {
		model = T.tally("PetBuilder.Build returns a Model with a PrimaryPart for every pet"),
		budget = T.tally("every pet stays within the High detail part budget (<= " .. budget .. " parts)"),
		detail = T.tally("Build(def) defaults to Detail = \"High\" and Build returns a fresh model every call (cached template, cloned)"),
		low = T.tally("Build(def, { Detail = \"Low\" }) stays within the Low budget (<= " .. lowBudget .. " parts) and is lighter than High"),
		lowShape = T.tally("the Low detail pet keeps the High one's size, colours, WingL / WingR and part flags"),
		lowAnimate = T.tally("Animate runs on a Low detail pet without errors, NaN or new instances"),
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
		flap = T.tally("Animate flaps the wings (a storm cloud sways gently) and WingL/WingR mirror each other"),
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
			-- detail levels
			local okHigh, high = pcall(PB.Build, def, { Detail = "High" })
			local nHigh = okHigh and typeof(high) == "Instance" and countParts(high) or -1
			tally.detail:case(nHigh == n and high ~= model, who .. ": Detail High gives " .. nHigh .. " parts, default " .. n)
			if okHigh and typeof(high) == "Instance" then
				high:Destroy()
			end
			local okLow, low = pcall(PB.Build, def, { Detail = "Low" })
			local lowBuilt = okLow and typeof(low) == "Instance" and low:IsA("Model") and low.PrimaryPart ~= nil
			if lowBuilt then
				low.Parent = holder
				low:PivotTo(CFrame.new(60, 3000, 0))
				local nLow = countParts(low)
				tally.low:case(nLow <= lowBudget and nLow >= 12 and nLow < n, who .. ": Low " .. nLow .. " parts vs High " .. n)
				local lowExt = low:GetExtentsSize().Y
				local hiExt = model:GetExtentsSize().Y
				local badFlags = 0
				local bestPrimary = huge
				for _, d in ipairs(low:GetDescendants()) do
					if d:IsA("BasePart") then
						if not (d.Anchored and not d.CanCollide and not d.CanTouch and not d.CanQuery) then
							badFlags = badFlags + 1
						end
						bestPrimary = min(bestPrimary, K.colorDistance255(d.Color, def.Look.Primary))
					end
				end
				local lwl, lwr = low:FindFirstChild("WingL", true), low:FindFirstChild("WingR", true)
				tally.lowShape:case(abs(lowExt - hiExt) <= 0.45 and bestPrimary <= 70 and badFlags == 0 and lwl ~= nil and lwr ~= nil,
					who .. ": height " .. fmt(lowExt, 2) .. " vs " .. fmt(hiExt, 2) .. ", primary colour distance " .. fmt(bestPrimary, 0) .. ", " .. badFlags .. " bad flags, wings " .. tostring(lwl) .. "/" .. tostring(lwr))
				local before = Mock.CountDescendants(low)
				local animOk, animErr = pcall(function()
					for i = 1, 45 do
						PB.Animate(low, i / 30, { Flap = 1, Excited = 0.3 })
					end
				end)
				local finite = true
				for _, d in ipairs(low:GetDescendants()) do
					if d:IsA("BasePart") and not finiteCFrame(d.CFrame) then
						finite = false
					end
				end
				tally.lowAnimate:case(animOk and finite and Mock.CountDescendants(low) == before, who .. ": " .. tostring(animErr) .. " finite=" .. tostring(finite))
				low:Destroy()
			else
				tally.low:case(false, who .. ": Build with Detail Low failed: " .. tostring(low))
			end
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
				local note = ""
				if look.WingStyle == "StormCloud" then
					-- Stormfang rides a storm cloud: its halves (WingL / WingR) sway and drift gently instead of flapping
					local drift = 0
					for i = 2, #frames do
						drift = max(drift, (frames[i].Position - frames[1].Position).Magnitude)
					end
					if spread < 1 and drift < 0.02 then
						note = "the storm cloud halves never move (expected a gentle sway / drift)"
					elseif spread > 40 then
						note = "the storm cloud flaps like a wing (" .. fmt(spread, 0) .. " degrees); it should only sway gently"
					elseif mirror > 0.05 then
						note = "WingL and WingR are not mirror images (max difference " .. fmt(mirror, 3) .. ")"
					end
				else
					local calm, wild, quick = path(1, 0), path(1, 1), path(2, 0)
					if spread < 40 then
						note = "wings swing only " .. fmt(spread, 0) .. " degrees (expected about +-35)"
					elseif mirror > 0.05 then
						note = "WingL and WingR are not mirror images (max difference " .. fmt(mirror, 3) .. ")"
					elseif wild < calm * 1.2 then
						note = "Excited = 1 does not flap faster (" .. fmt(wild, 0) .. " vs " .. fmt(calm, 0) .. " degrees travelled)"
					elseif quick < calm * 1.5 then
						note = "Flap = 2 does not flap faster (" .. fmt(quick, 0) .. " vs " .. fmt(calm, 0) .. " degrees travelled)"
					end
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
	-- Stormfang, the player's own creature, faithful to their art (ARCHITECTURE_V3.md section 10). The catalog pet is
	-- used once it exists; until then a definition with the doc's colours exercises PetBuilder's sculpt.
	local sf = CONTRACT.v3.stormfang
	if T.contains(PB.Species or {}, sf.species) then
		local function rgb3(t)
			return Color3.fromRGB(t[1], t[2], t[3])
		end
		local pal = sf.palette
		local def = PC.Get(sf.petId) or {
			Id = sf.petId, Name = sf.name, Rarity = CONTRACT.v3.secretRarity, Blurb = "-",
			Look = { Species = sf.species, WingStyle = sf.wingStyle, Glow = true, Primary = rgb3(pal.armour), Secondary = rgb3(pal.electric), Eye = rgb3(pal.electric), WingColor = rgb3(pal.cloud) },
			Perks = {},
		}
		local hiOk, hi = pcall(PB.Build, def, {})
		local loOk, lo = pcall(PB.Build, def, { Detail = "Low" })
		if T.check(hiOk and typeof(hi) == "Instance" and loOk and typeof(lo) == "Instance", "Stormfang builds at both detail levels", tostring(hi) .. " / " .. tostring(lo)) then
			hi.Parent, lo.Parent = holder, holder
			T.check(countParts(hi) <= budget and countParts(lo) <= lowBudget, "Stormfang: High <= " .. budget .. " and Low <= " .. lowBudget .. " parts", countParts(hi) .. " / " .. countParts(lo))
			-- how many visible parts carry a colour close to `target` (small face details like the nose do not count)
			local function count(target, limit, filter)
				local n, best = 0, huge
				for _, d in ipairs(hi:GetDescendants()) do
					if d:IsA("BasePart") and d.Transparency < 1 and not d.Name:find("^Eye") and not d.Name:find("^Nose") and not d.Name:find("^Mouth") and (not filter or filter(d)) then
						local dist = K.colorDistance255(d.Color, target)
						best = min(best, dist)
						if dist <= limit then
							n = n + 1
						end
					end
				end
				return n, best
			end
			local function isNeon(d)
				return d.Material == Enum.Material.Neon
			end
			local function isWing(d)
				return d.Name:find("^Wing") ~= nil
			end
			local function feature(label, target, limit, minParts, filter)
				local n, best = count(target, limit, filter)
				T.check(n >= minParts, "Stormfang: " .. label, n .. " part(s) within " .. limit .. " (closest colour distance " .. fmt(best, 0) .. ", needs " .. minParts .. ")")
				return n >= minParts
			end
			-- layered charcoal armour: 3-4 greys (base, mid, light, bevelled edges); the charcoal base must be one of them
			local greys = {
				{ "charcoal base ~#2a2c33", rgb3(pal.armour), 24 },
				{ "mid grey ~#4b4d57", rgb3(pal.armourMid), 32 },
				{ "light grey ~#70737e", rgb3(pal.armourLight), 32 },
				{ "bevelled edge ~#a3a6ae", Color3.fromRGB(163, 166, 174), 32 },
			}
			local found, shown = 0, {}
			for _, gr in ipairs(greys) do
				local n, best = count(gr[2], gr[3])
				if n >= 2 then
					found = found + 1
				end
				shown[#shown + 1] = gr[1] .. ": " .. n .. " parts (closest " .. fmt(best, 0) .. ")"
			end
			local baseParts = count(greys[1][2], greys[1][3])
			T.check(found >= 3 and baseParts >= 2, "Stormfang: layered charcoal armour plates in 3-4 greys, charcoal base included", table.concat(shown, "; "))
			feature("white fluffy face mask / cheek ruff", Color3.fromRGB(242, 244, 248), 24, 3)
			feature("neon violet ear stripes / eye rims (~#7a3cff, Neon)", rgb3(pal.violet), 40, 2, isNeon)
			feature("neon electric-blue stripes and glowing claws (~#2fb4ff, Neon)", rgb3(pal.electric), 50, 2, isNeon)
			feature("cyan diamond gems (~#3fc8ff, Neon core)", rgb3(pal.gem), 40, 1, isNeon)
			feature("dark navy storm cloud (~#2e3a66) as WingL / WingR", rgb3(pal.cloud), 36, 2, isWing)
			feature("lighter blue cloud tops (~#6b77a8)", Color3.fromRGB(107, 119, 168), 36, 1, isWing)
			feature("a few white puffs on the storm cloud", Color3.fromRGB(236, 240, 250), 30, 1, isWing)
			local glass, neonEyes = false, false
			for _, d in ipairs(hi:GetDescendants()) do
				if d:IsA("BasePart") then
					glass = glass or d.Material == Enum.Material.Glass
					neonEyes = neonEyes or (d.Name:find("^Eye") ~= nil and d.Material == Enum.Material.Neon)
				end
			end
			T.check(glass, "Stormfang: the gems have a Glass rim")
			T.check(neonEyes, "Stormfang: fierce glowing eyes (Neon eye parts)")
			T.check(hi:FindFirstChild("WingL", true) ~= nil and hi:FindFirstChild("WingR", true) ~= nil, "Stormfang: the storm cloud halves are WingL / WingR (Animate sways them)")
			-- the neon accents pulse softly while animated (client side)
			local neon = {}
			for _, d in ipairs(hi:GetDescendants()) do
				if d:IsA("BasePart") and d.Material == Enum.Material.Neon then
					neon[#neon + 1] = { d, d.Transparency, d.Color }
				end
			end
			PB.Animate(hi, 0.2, { Flap = 1, Excited = 0 })
			local snap = {}
			for i, e in ipairs(neon) do
				snap[i] = e[1].Transparency
			end
			PB.Animate(hi, 0.9, { Flap = 1, Excited = 0 })
			local pulsed, maxT = false, 0
			for i, e in ipairs(neon) do
				if abs(e[1].Transparency - snap[i]) > 0.02 or K.colorDistance255(e[1].Color, e[3]) > 3 then
					pulsed = true
				end
				maxT = max(maxT, e[1].Transparency)
			end
			T.check(pulsed and maxT < 0.6, "Stormfang: the neon accents pulse softly when animated (and never fade out)", "max transparency " .. fmt(maxT, 2))
			-- its own species: not a recoloured Fox or Cat
			local function nameSet(m)
				local set, list = {}, {}
				for _, d in ipairs(m:GetDescendants()) do
					if d:IsA("BasePart") then
						local n = d.Name:gsub("%d+$", "")
						if not set[n] then
							set[n] = true
							list[#list + 1] = n
						end
					end
				end
				table.sort(list)
				return table.concat(list, ",")
			end
			local mine = nameSet(hi)
			for _, other in ipairs({ "Fox", "Cat" }) do
				local look = {}
				for k, v in pairs(def.Look) do
					look[k] = v
				end
				look.Species = other
				local okO, m = pcall(PB.Build, { Id = "sf_" .. other, Name = other, Rarity = def.Rarity, Blurb = "-", Look = look, Perks = {} }, {})
				if okO and typeof(m) == "Instance" then
					T.check(nameSet(m) ~= mine, "Stormfang is its own sculpt, not a recoloured " .. other)
					m:Destroy()
				end
			end
			hi:Destroy()
			lo:Destroy()
		end
	else
		T.warn("PetBuilder does not sculpt the Stormfang species yet (ARCHITECTURE_V3.md section 10)")
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
	-- every species x wing style x accessory builds within budget at BOTH detail levels (small synthetic matrix; the
	-- builder's own species / wing lists count too, so a new species is covered before the catalog uses it)
	local speciesList, wingList = {}, {}
	for _, list in ipairs({ PC.Species, PB.Species or {} }) do
		for _, sp in ipairs(list) do
			if not T.contains(speciesList, sp) then
				speciesList[#speciesList + 1] = sp
			end
		end
	end
	for _, list in ipairs({ PC.WingStyles or { "Feather", "Bat", "Fairy", "Cloud", "Crystal", "Flame" }, PB.WingStyles or {} }) do
		for _, w in ipairs(list) do
			if not T.contains(wingList, w) then
				wingList[#wingList + 1] = w
			end
		end
	end
	local accessories = PC.Accessories or { "Horns", "Crown", "Halo", "Leaf", "Mushroom", "Scarf", "Antlers", "Flower" }
	for _, level in ipairs(CONTRACT.v3.petDetail.levels) do
		local cap = level == "Low" and lowBudget or budget
		local combos, worstCombo, worstName, comboBad = 0, 0, "", nil
		for _, species in ipairs(speciesList) do
			for wi, wing in ipairs(wingList) do
				local acc = accessories[(wi + #species) % (#accessories + 1) + 1]
				local d = {
					Id = "combo", Name = "Combo", Rarity = (wi % 3 == 0) and "Secret" or ((wi % 2 == 0) and "Mythic" or "Common"), Blurb = "-",
					Look = { Species = species, WingStyle = wing, Accessory = acc, Glow = wi % 2 == 0, Primary = Color3.fromRGB(180, 120, 90), Secondary = Color3.fromRGB(240, 220, 200), Eye = Color3.fromRGB(30, 30, 50), WingColor = Color3.fromRGB(200, 160, 220) },
					Perks = {},
				}
				local okc, m = pcall(PB.Build, d, { Scale = 1, Detail = level })
				combos = combos + 1
				local name = species .. "/" .. wing .. "/" .. tostring(acc)
				if not okc or typeof(m) ~= "Instance" then
					comboBad = comboBad or (name .. ": " .. tostring(m))
				else
					local n = countParts(m)
					if n > worstCombo then
						worstCombo, worstName = n, name
					end
					if n > cap then
						comboBad = comboBad or (name .. ": " .. n .. " parts")
					end
					if not (m:FindFirstChild("WingL", true) and m:FindFirstChild("WingR", true)) then
						comboBad = comboBad or (name .. ": no WingL / WingR")
					end
					m:Destroy()
				end
			end
		end
		T.check(comboBad == nil, "every Species x WingStyle x Accessory combination builds at Detail " .. level .. " within " .. cap .. " parts (" .. combos .. " combos, worst " .. worstCombo .. " parts: " .. worstName .. ")", comboBad)
	end
	holder:Destroy()
	flushErrors("petbuilder")
	flushWarnings("petbuilder")
end)

return S
