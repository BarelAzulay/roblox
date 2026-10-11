-- NpcDialog: the six NPC pets of the lobby and what they say (ARCHITECTURE_V3.md section 5). Data only, no
-- Instances, so the server (NpcService builds the NPCs) and the client (NpcController shows the dialog) share it.
--
--   NpcDialog.Npcs            array in lobby-spot order: { Id, Name, Title, PetId, Species, Scale, Accent, Keywords,
--                             ColorWords (optional: word -> Color3), Lines = { "...", ... } }   (3-5 short lines each)
--   NpcDialog.ById[id]        the same entries by id
--   NpcDialog.Get(id) -> entry | nil
--   NpcDialog.GetLines(id) -> { line, ... }   (empty table for an unknown id)
--   NpcDialog.Tag             "NC_Npc", the CollectionService tag of every NPC model (attribute NpcId = entry.Id)
--   NpcDialog.Settings        shared numbers (scale, prompt / close distances, hover gap)
--
-- The tips quote the game's real numbers: prices, bonuses, odds and rewards are read from Config / ItemCatalog /
-- TycoonCatalog when this module loads, so they stay correct when those change. Phase 2 tips: claiming a home, the
-- presses + Collector, house tiers and Prestige (Mayor Panda), the Kitchen + feeding (Granny Owl), the Gym (Coach
-- Corgi), the Fusion Machine, Gems and the Secret roulette at the Storm Altar (Professor Axolotl). Nimbus the Cloudy Dragon is NOT an NPC: it is
-- the tutorial guide. `Keywords` are phrases the dialog box highlights (numbers are highlighted automatically),
-- `ColorWords` words it paints in their own colour (the element names).
-- Lines never contain "<", ">" or "&" (the client renders them as rich text).
-- Plain Lua 5.1-compatible syntax only.

local Config = require(script.Parent:WaitForChild("Config"))

local ItemCatalog = nil
do
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("ItemCatalog", 5))
	end)
	if ok and type(mod) == "table" then
		ItemCatalog = mod
	end
end

local TycoonCatalog = nil
do
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("TycoonCatalog", 5))
	end)
	if ok and type(mod) == "table" then
		TycoonCatalog = mod
	end
end

local NpcDialog = {}

NpcDialog.Tag = "NC_Npc"

NpcDialog.Settings = {
	Scale = 2.2, -- PetBuilder scale of every NPC pet
	PromptDistance = 10, -- ProximityPrompt.MaxActivationDistance
	CloseDistance = 16, -- the dialog closes when the player walks this far from the NPC
	HoverGap = 1.0, -- studs between the pedestal cushion and the lowest voxel of the pet
}

----------------------------------------------------------------------
-- Number helpers (the tips quote Config)
----------------------------------------------------------------------
local TOKEN = "\226\152\129" -- the cloud glyph used for Cloud Tokens everywhere

local function commas(n)
	local s = tostring(math.floor((tonumber(n) or 0) + 0.5))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return out
end

local function tokens(n)
	return commas(n) .. " " .. TOKEN
end

local function percent(fraction)
	local p = (tonumber(fraction) or 0) * 100
	if math.abs(p - math.floor(p + 0.5)) < 0.05 then
		return tostring(math.floor(p + 0.5)) .. "%"
	end
	return string.format("%.1f%%", p)
end

local function number(n)
	n = tonumber(n) or 0
	if math.abs(n - math.floor(n + 0.5)) < 1e-6 then
		return tostring(math.floor(n + 0.5))
	end
	return (string.format("%.2f", n):gsub("0+$", ""):gsub("%.$", ""))
end

local function itemPrice(id, fallback)
	if ItemCatalog then
		local def = nil
		if type(ItemCatalog.Get) == "function" then
			def = ItemCatalog.Get(id)
		elseif type(ItemCatalog.ById) == "table" then
			def = ItemCatalog.ById[id]
		end
		if type(def) == "table" and tonumber(def.Price) then
			return tonumber(def.Price)
		end
	end
	return fallback
end

local function shortName(roulette)
	if type(roulette.Id) == "string" and roulette.Id ~= "" then
		return roulette.Id
	end
	return (tostring(roulette.DisplayName or "?"):gsub(" Roulette$", ""))
end

-- "A, B and C"
local function joinAnd(list)
	if #list == 0 then
		return ""
	elseif #list == 1 then
		return list[1]
	end
	return table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
end

----------------------------------------------------------------------
-- Lines built from Config
----------------------------------------------------------------------
local P = Config.Physics or {}
local M = Config.Match or {}
local T = Config.Tokens or {}
local D = Config.Damage or {}

-- "Easy +10, Medium +20, ..."
local function winBonusList()
	local parts = {}
	local bonus = M.TokenBonusOnWin or {}
	for _, d in ipairs(Config.Difficulties or {}) do
		if tonumber(bonus[d.Id]) then
			parts[#parts + 1] = tostring(d.DisplayName or d.Id) .. " +" .. commas(bonus[d.Id])
		end
	end
	return table.concat(parts, ", ")
end

-- "Cloud 50 ☁, Storm 250 ☁, ..."
local function roulettePriceList()
	local parts = {}
	for _, r in ipairs(Config.Roulettes or {}) do
		if tonumber(r.Price) then
			parts[#parts + 1] = shortName(r) .. " " .. tokens(r.Price)
		end
	end
	return table.concat(parts, ", ")
end

-- "Sky (3%) and Celestial (15%)": every roulette that can roll a Mythic, with its chance
local function mythicChances()
	local parts = {}
	for _, r in ipairs(Config.Roulettes or {}) do
		local odds = r.Odds or {}
		local total = 0
		for _, w in pairs(odds) do
			total = total + (tonumber(w) or 0)
		end
		local w = tonumber(odds.Mythic) or 0
		if w > 0 and total > 0 then
			parts[#parts + 1] = shortName(r) .. " (" .. percent(w / total) .. ")"
		end
	end
	return joinAnd(parts)
end

-- Index rewards of the lowest and the highest token-roulette rarity ("50 ☁ for Commons up to 5,000 ☁ for Mythics")
local function indexRewardRange()
	local rewards = (Config.Index and Config.Index.Rewards) or {}
	local low, high = nil, nil
	for _, rarity in ipairs(Config.Rarities or {}) do
		local r = rewards[rarity.Id]
		if rarity.Id ~= "Secret" and type(r) == "table" and tonumber(r.Tokens) then
			if not low then
				low = { rarity.Id, r.Tokens }
			end
			high = { rarity.Id, r.Tokens }
		end
	end
	if not low then
		return "a big token prize"
	end
	return tokens(low[2]) .. " for " .. low[1] .. "s up to " .. tokens(high[2]) .. " for " .. high[1] .. "s"
end

-- The element wheel as "A beats B" pairs, starting at Water, plus the two-way rivals.
local function elementWheel()
	local E = Config.Elements or {}
	local strong = E.Strong or {}
	local order = E.Order or {}
	local pairsList = {}
	local seen = {}
	local start = order[1] or "Water"
	local cur = start
	for _ = 1, #order do
		local beats = strong[cur] and strong[cur][1]
		if not beats or seen[cur] then
			break
		end
		seen[cur] = true
		pairsList[#pairsList + 1] = cur .. " beats " .. beats
		cur = beats
		if cur == start then
			break
		end
	end
	local rivals = {}
	for _, id in ipairs(order) do
		local beats = strong[id] and strong[id][1]
		if beats and not seen[id] and strong[beats] and strong[beats][1] == id and not seen[beats] then
			seen[id] = true
			seen[beats] = true
			rivals[#rivals + 1] = { id, beats }
		end
	end
	return pairsList, rivals
end

local wheel, rivals = elementWheel()
local half = math.ceil(#wheel / 2)
local wheelA, wheelB = {}, {}
for i, text in ipairs(wheel) do
	if i <= half then
		wheelA[#wheelA + 1] = text
	else
		wheelB[#wheelB + 1] = text
	end
end
local rivalLine
if rivals[1] then
	rivalLine = rivals[1][1] .. " and " .. rivals[1][2] .. " are rivals: each one beats the other. Light versus dark!"
else
	rivalLine = "Some elements are rivals and beat each other. Light versus dark!"
end
-- element name -> its colour (the dialog paints the element names in their own colours)
local function elementColors()
	local out = {}
	local info = (Config.Elements and Config.Elements.Info) or {}
	for name, e in pairs(info) do
		if type(e) == "table" and typeof(e.Color) == "Color3" then
			out[name] = e.Color
		end
	end
	return out
end

local strongMul = number((Config.Elements and Config.Elements.StrongMultiplier) or 1.5)
local weakMul = number((Config.Elements and Config.Elements.WeakMultiplier) or 0.75)

----------------------------------------------------------------------
-- Phase 2 numbers (TycoonCatalog: the home stations, food, the Gym, house tiers, Prestige, the Fusion Machine)
----------------------------------------------------------------------
local TC = TycoonCatalog or {}
local G = Config.Gems or {}

local function stationEffect(id, level)
	local get = type(TC.Get) == "function" and TC.Get or nil
	local def = get and get(id) or nil
	local effects = type(def) == "table" and def.Effects or nil
	if type(effects) ~= "table" then
		return nil, 0
	end
	if level == "max" then
		level = #effects
	end
	return effects[level], #effects
end

-- "a Snack gives 25 XP, a Meal 150 XP and a Feast 800 XP"
local function foodLine()
	local foods = type(TC.Foods) == "table" and TC.Foods or {}
	local parts = {}
	for i, f in ipairs(foods) do
		if type(f) == "table" and tonumber(f.Xp) then
			local name = tostring(f.Name or f.Id)
			if i == 1 then
				parts[#parts + 1] = "a " .. name .. " gives " .. commas(f.Xp) .. " XP"
			else
				parts[#parts + 1] = "a " .. name .. " " .. commas(f.Xp) .. " XP"
			end
		end
	end
	if #parts == 0 then
		return "every dish gives XP"
	end
	return joinAnd(parts)
end

local function gymNumbers()
	local first = stationEffect("Gym", 1)
	local top, levels = stationEffect("Gym", "max")
	local low = first and tonumber(first.XpPerMinute) or 20
	local high = top and tonumber(top.XpPerMinute) or 80
	local slots = top and tonumber(top.Slots) or 5
	return low, high, slots, levels
end

-- "Villa at Home Level 10, a Manor at 20 and the Sky Castle at 30"
local function houseLine()
	local tiers = type(TC.HouseTiers) == "table" and TC.HouseTiers or {}
	local parts = {}
	for i, t in ipairs(tiers) do
		if i > 1 and type(t) == "table" and tonumber(t.HomeLevel) then
			local name = tostring(t.Name or t.Id)
			if #parts == 0 then
				parts[#parts + 1] = "a " .. name .. " at Home Level " .. number(t.HomeLevel)
			elseif i == #tiers then
				parts[#parts + 1] = "the " .. name .. " at " .. number(t.HomeLevel)
			else
				parts[#parts + 1] = "a " .. name .. " at " .. number(t.HomeLevel)
			end
		end
	end
	if #parts == 0 then
		return "a bigger house every 10 Home Levels"
	end
	return joinAnd(parts)
end

local PR = type(TC.Prestige) == "table" and TC.Prestige or {}
local prestigeLevel = number(PR.HomeLevel or 40)
local prestigeMul = number(PR.IncomeMultiplier or 1.25)
local prestigeGems = commas(PR.GemReward or 100)
local castleName = "Sky Castle"
do
	local tiers = type(TC.HouseTiers) == "table" and TC.HouseTiers or nil
	local last = tiers and tiers[#tiers]
	if type(last) == "table" and type(last.Name) == "string" then
		castleName = last.Name
	end
end
local tierMul = type(TC.TierMultiplier) == "table" and TC.TierMultiplier or {}
local goldenMul = number(tierMul.Golden or 1.5)
local rainbowMul = number(tierMul.Rainbow or 2.5)
local fusionCopies = number((type(TC.Fusion) == "table" and TC.Fusion.Copies) or 3)
local fusionWhen = "After your first Prestige"
if tonumber(PR.FusionUnlock) and tonumber(PR.FusionUnlock) ~= 1 then
	fusionWhen = "At Prestige " .. number(PR.FusionUnlock)
end
local levelBonus = percent(0.1)
local secretRoulette = type(G.SecretRoulette) == "table" and G.SecretRoulette or {}
local secretPrice = commas(secretRoulette.GemPrice or 1500)
local cheapGemSpin = nil
do
	local prices = type(G.RouletteGemPrices) == "table" and G.RouletteGemPrices or {}
	for _, r in ipairs(Config.Roulettes or {}) do
		if tonumber(prices[r.Id]) and not cheapGemSpin then
			cheapGemSpin = shortName(r) .. " spin costs just " .. commas(prices[r.Id]) .. " Gems"
		end
	end
end
local gymLow, gymHigh, gymSlots = gymNumbers()

----------------------------------------------------------------------
-- The NPCs (order = lobbyInfo.NpcSpots order: the two by the portals, the two beside the boardwalk to the
-- shop, then the two on the lawns towards the shop)
----------------------------------------------------------------------
NpcDialog.Npcs = {
	{
		Id = "sparky_fox",
		Name = "Sparky Fox",
		Title = "Movement Trainer",
		PetId = "aurora_fox",
		Species = "Fox",
		Accent = Color3.fromRGB(64, 188, 192),
		Keywords = { "Shift", "RUN", "DASH!", "DASH", "Q", "1 to 4", "Heal Cloud", "big fall", "checkpoint" },
		Lines = {
			"Zap! Hold Shift to run (the RUN button on phones). Running drains stamina, walking refills it.",
			"Press Q to dash (DASH on phones). It costs " .. number(P.DashStaminaCost or 35) .. " stamina, recharges in "
				.. number(P.DashCooldown or 1.6) .. " seconds and works in mid-air!",
			"See a DASH! sign? That gap is too wide for a jump alone: jump first, then dash while you are in the air.",
			"Keys 1 to 4 use your hotbar items during a climb. A Heal Cloud (" .. tokens(itemPrice("heal_cloud", 30))
				.. ") restores 40% of your health.",
			"Missed a jump? A big fall costs health and puts you back at your team's checkpoint. Shake it off!",
		},
	},
	{
		Id = "captain_penguin",
		Name = "Captain Penguin",
		Title = "Co-op Captain",
		PetId = "frostling_penguin",
		Species = "Penguin",
		Accent = Color3.fromRGB(88, 148, 226),
		Keywords = { "portal pad", "next checkpoint", "Phoenix Feather", "Shield Bubble", "Pressure plates" },
		Lines = {
			"Ahoy! Step onto a portal pad together: up to " .. number(M.MaxPlayers or 4) .. " climbers can sail into the same course.",
			"Teammate down? Keep climbing! Reaching the next checkpoint revives everyone who is down.",
			"A Phoenix Feather (" .. tokens(itemPrice("phoenix_feather", 150))
				.. ") revives the nearest downed teammate right away, with 50% health.",
			"Every checkpoint heals the team by " .. percent(D.CheckpointHealFraction or 0.35) .. ". A Shield Bubble ("
				.. tokens(itemPrice("shield_bubble", 45)) .. ") blocks all damage for 8 seconds.",
			"Pressure plates need a crew: one climber holds the plate while the others cross the bridge.",
		},
	},
	{
		Id = "granny_owl",
		Name = "Granny Owl",
		Title = "Pet Expert",
		PetId = "sleepy_owl",
		Species = "Owl",
		Accent = Color3.fromRGB(160, 126, 222),
		Keywords = { "roulette machines", "shop island", "Mythic", "Pet Index", "Kitchen", "Feed", "Pets menu" },
		Lines = {
			"Hoo-hoo! New pets come from the roulette machines on the shop island. " .. roulettePriceList()
				.. ": the pricier, the rarer.",
			"Mythic pets only appear in the " .. mythicChances() .. " roulettes. The shop shows every chance.",
			"Every pet you find fills the Pet Index. Complete a rarity group for a reward: " .. indexRewardRange() .. "!",
			"Hungry pets grow! Build a Kitchen at home and cook pet food with Cash: " .. foodLine() .. ".",
			"Then open the Pets menu, pick a buddy and press Feed. Every level makes a pet " .. levelBonus
				.. " stronger, so spoil your favourites!",
		},
	},
	{
		Id = "coach_corgi",
		Name = "Coach Corgi",
		Title = "Token Coach",
		PetId = "waffle_corgi",
		Species = "Dog",
		Accent = Color3.fromRGB(240, 174, 70),
		Keywords = { "yours to keep", "Golden tokens", "Harder courses", "Gym", "Combat pets", "Train in Gym", "Pet Battles" },
		Lines = {
			"Woof! Every coin you grab on a climb is yours to keep, even when your team runs out of time!",
			"Win a climb and every finisher gets a bonus: " .. winBonusList() .. " " .. TOKEN .. "!",
			"Golden tokens are worth " .. tokens(T.GoldenValue or 5) .. " instead of " .. number(T.DefaultValue or 1)
				.. ". Harder courses are longer and hide more coins!",
			"Combat pets get tough in your home Gym: open Pets and press Train in Gym. Each one gains " .. number(gymLow)
				.. " XP a minute while you play.",
			"Upgrade the Gym for more spots and faster training: up to " .. number(gymSlots) .. " pets and " .. number(gymHigh)
				.. " XP a minute. Get ready for Pet Battles!",
		},
	},
	{
		Id = "mayor_panda",
		Name = "Mayor Panda",
		Title = "Village Mayor",
		PetId = "bamboo_panda",
		Species = "Panda",
		Accent = Color3.fromRGB(100, 184, 112),
		Keywords = { "free gate", "press E", "Cloud Press", "Collector", "Home Level", "Prestige", "Home", "Gems", "Economy pets", "Garden" },
		Lines = {
			"Welcome to Nimbus Village! Walk up to a free gate on the big ring and press E to claim your very own home.",
			"Start with a Cloud Press and the Collector: they make Cash while you play. Step on the Collector to bank it!",
			"Every purchase raises your Home Level: build " .. houseLine() .. ". Bigger houses unlock bigger upgrades!",
			"Home Level " .. prestigeLevel .. " and a " .. castleName .. "? Prestige! You start over with a star: x"
				.. prestigeMul .. " income forever and " .. prestigeGems .. " Gems.",
			"Economy pets earn Cash in your Garden. Tap Home in the menu to see every station, your income and upgrades!",
		},
	},
	{
		Id = "professor_axolotl",
		Name = "Professor Axolotl",
		Title = "Element Scholar",
		PetId = "nebula_axolotl",
		Species = "Axolotl",
		Accent = Color3.fromRGB(226, 112, 170),
		Keywords = { "Element", "Pet Battles", "Fusion Machine", "Golden", "Rainbow", "hybrid", "Storm Altar", "Secret pets", "Gems", "Prestige" },
		ColorWords = elementColors(),
		Lines = {
			"Blub! Every pet has an Element. " .. joinAnd(wheelA) .. ".",
			joinAnd(wheelB) .. ". " .. rivalLine,
			"In the coming Pet Battles a strong element hits for x" .. strongMul .. " damage, a weak one only x"
				.. weakMul .. ". Pick your team wisely!",
			fusionWhen .. " you can build the Fusion Machine: fuse " .. fusionCopies .. " copies into a Golden pet (x"
				.. goldenMul .. "), then Rainbow (x" .. rainbowMul .. "), or mix two pets into a brand-new hybrid!",
			"Secret pets like Stormfang are summoned at the Storm Altar for " .. secretPrice .. " Gems. "
				.. (cheapGemSpin and ("In the Shop's Gems tab a " .. cheapGemSpin .. "!") or "Gems also buy roulette spins in the Shop!"),
		},
	},
}

NpcDialog.List = NpcDialog.Npcs

NpcDialog.ById = {}
for _, npc in ipairs(NpcDialog.Npcs) do
	npc.Scale = npc.Scale or NpcDialog.Settings.Scale
	NpcDialog.ById[npc.Id] = npc
end

function NpcDialog.Get(id)
	if type(id) ~= "string" then
		return nil
	end
	return NpcDialog.ById[id]
end

function NpcDialog.GetLines(id)
	local npc = NpcDialog.Get(id)
	if npc and type(npc.Lines) == "table" then
		return npc.Lines
	end
	return {}
end

return NpcDialog
