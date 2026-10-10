-- TycoonCatalog: every number of the Phase 2 tycoon homes (ARCHITECTURE_V3.md "Phase 2: Tycoon homes" and the
-- "Phase 2 build contract"): the stations and their buy pads, prices, effects per level, house tiers, prestige,
-- foods, fusion costs, the pet XP curve and where everything stands on the 72 x 72 stud yard.
-- Pure data + pure functions: no Instances, no services, no yields; safe on the server and the client.
-- Plain Lua 5.1-compatible syntax only.
--
-- BALANCE: the prices and incomes below come from the progression simulation tools/sim_tycoon.py (an active player
-- who buys the best-value pad as soon as it is affordable, banks the Collector every ~20 s and places garden pets
-- from typical roulette luck). Change a number here -> change the same number in the constants block of
-- tools/sim_tycoon.py and re-run it (`python3 tools/sim_tycoon.py`); the smoke check (tools/smoke_p2_economy.lua)
-- fails while the two disagree. Targets proven by the sim: first purchase within 30 s of claiming, a purchase every
-- 1-3 minutes early on, the Villa after ~25-30 min, the first Prestige after ~2.5 h, later prestiges faster, never
-- more than 6 minutes with nothing affordable.
--
-- API (the contract):
--   TycoonCatalog.Get(id) -> StationDef | nil            READ-ONLY (shared table). "Prestige" returns the prestige
--                                                        pseudo-station (Kind "Prestige", see below)
--   TycoonCatalog.PriceFor(id, level) -> cash | nil      price of building / upgrading TO `level` (nil = no such level)
--   TycoonCatalog.AvailablePads(home) -> { pad... }      the pads to show on the yard, in station order:
--       pad = { StationId, NextLevel, Price, Locked = reason | nil,
--               Level (current), MaxLevel, Name, Title, Kind, Icon, LevelText ("Build" | "Lv 2 -> 3"), Prestige }
--       * a station shows a pad once its STATION prerequisites are built (the tree: the yard fills step by step);
--         maxed stations show no pad
--       * Locked (shown on the sign) when the next level needs more: "Reach Home Level 10", "Needs the Villa",
--         "Unlocks at Prestige 1", "Coming soon" (Arena Gate until Phase 3). Price is always the real price.
--       * once the Sky Castle is built the list also holds the PRESTIGE pad: { StationId = "Prestige",
--         Kind = "Prestige", Prestige = true, Price = 0, NextLevel = stars + 1, Locked = "Reach Home Level 40" | nil }.
--         TycoonService routes it to its Prestige() (never to a station purchase).
--   TycoonCatalog.HomeLevelOf(home) -> n                 sum of every station level (each purchase or upgrade = +1)
--   TycoonCatalog.IncomePerSecond(home, gardenDefs, prestige) -> cash/s, { Press, Garden, Multiplier }
--       (presses x Collector bonus + garden pets) x PrestigeMultiplier(prestige or home.Prestige); 0 without a
--       Collector (the presses feed it). gardenDefs: list of what sits in the Garden; each entry may be
--         a PetDef or PetKeys.DefOf(...) def (Stats.Income, Rarity; tier from StatMultiplier / Tier / Look.Finish;
--         level from .Level), { Def = def, Level = n, Tier = "Golden" }, { Income = cashPerSecond } (already
--         scaled, e.g. a PetCatalog.GetStats result), a plain number, or a pet key string ("cat", "cat@Golden").
--       Pet cash/s = Income x RarityScale x (1 + 0.1 x (level - 1)) x tier (Golden 1.5, Rainbow 2.5); only as many
--       entries as the Garden has slots count.
--   TycoonCatalog.CollectorCap(home, incomePerSecond?) -> cash   the Collector holds at most this much (0 without a
--       Collector): FlatCap + CapSeconds x income, from the Collector and Vault levels. The income is the larger of
--       incomePerSecond (pass IncomePerSecond's result) and the presses + the pet keys in home.Garden at level 1.
--   TycoonCatalog.OfflineEarnings(home, seconds, incomePerSecond) -> cash, { Seconds, Percent, MaxHours }
--       the Vault pays OfflinePercent of the income for up to OfflineHours (0 without a Vault, 0 for absences
--       shorter than OfflineMinSeconds). Pay it with AddCash ("While you were away" toast).
--   TycoonCatalog.XpToNext(level) -> xp                  pet XP from `level` to level + 1; math.huge at PetXp.MaxLevel
--   TycoonCatalog.Validate() -> ok, { problem... }       data self-check (prices, caps, tree, no dead end, slots
--                                                        inside the yard without overlaps, every pad reachable)
-- Data (the contract): Stations (array, display order) / ById / Order, HouseTiers, Prestige, Foods, Fusion, PetXp,
--   Layout. Stations, HouseTiers and Foods are ordered arrays that also answer an id (Stations.Press1,
--   HouseTiers.Villa, Foods.Snack); Fusion.Upgrade[rarity].Golden / .Rainbow, Fusion.Mix[rarity] (also Fusion[rarity]).
--   StationDef = { Id, Name, Kind, Icon, Blurb, MaxLevel,
--       Requires = { <stationId> = level, HomeLevel = n, House = tierId, Prestige = n },  -- station keys = the tree
--       LevelRequires = { [level] = { HomeLevel = n } },   -- per-level extra gate (the House: 10 / 20 / 30)
--       TierCaps = { Cottage = n, Villa = n, Manor = n, SkyCastle = n },  -- max level allowed by the house tier
--       Price = { [level] = cash }, Effects = { [level] = {...} },
--       Slot = { CFrame, Footprint, Pad, Walkable?, Perimeter?, Spots? },  -- plot-local (see Layout below)
--       KeepOnPrestige = true | nil, ComingSoon = true | nil }
--   NOTE: `Requires.House` is the house TIER (id "Villa" or tier index 2), never the House station level.
-- Effects by Kind:
--   Press     { Income = cash/s }                    Collector { Bonus = +x press income, CapSeconds, FlatCap }
--   Garden    { Slots }                              Kitchen   { Slots = Queue = cooking queue size, CookSpeed, Recipes }
--   Gym       { Slots, XpPerMinute }                 Vault     { CapSeconds, FlatCap, OfflinePercent, OfflineHours }
--   House     { Tier, TierIndex, Name }              Fusion    { TokenDiscount }
--   Arena     { Battles = true }                     Decor     { Pieces, Style }  (build hints for HomeBuilder)
-- Slots (plot-local, studs): origin = centre of the yard ON the ground (SpotInfo.PlotCFrame), -Z = the gate /
--   street side (PlotCFrame.LookVector), +Z = the back fence, X across. A station model goes at
--   PlotCFrame * Slot.CFrame; its LookVector is the station's FRONT (the side its pad is on). Footprint =
--   Vector3(width along the front, height, depth) in the station's own axes. Slot.Pad = the buy pad (centre on the
--   ground, Layout.PadSize, LookVector toward the station). Walkable = a decor zone with small pieces the player
--   walks through (lamp posts beside the path); Perimeter = follows the fence line (DecorFence); Spots = local
--   positions (in the station frame) of the Garden / Gym pet places. Layout.Paths = stone paths that keep every
--   pad reachable from the gate; Layout.Conveyor = the belt from the presses into the Collector.
-- Extras (nothing depends on them): HouseTierOf, HouseTier, MaxLevelAt, StationLevel, PressIncome, GardenIncome,
--   PetIncome, PrestigeMultiplier, PrestigeGems, CanPrestige, StationsAfterPrestige, CheckPurchase, EffectsOf,
--   GardenSlots, GymSlots, GymXpPerMinute, KitchenSpeed, FoodById, FoodsFor, CookSecondsFor, FusionCost, XpForLevel,
--   PadLevelText, FormatCash, ReachablePads, FootprintRect, PadRect, TierMultiplier, Kinds, Icons, FoodsById,
--   PrestigePad, MaxPetLevel, StartCash, OfflineMinSeconds, PlotSize, Version.
--
-- Notes for the services: a Price of 0 is FREE (Press 1 and the Collector: the first purchases right after
-- claiming; Cash starts at 0), so skip SpendCash or call it with 0. Prestige keeps every station whose
-- KeepOnPrestige is true (the decor: "decor choices kept"), resets the rest (StationsAfterPrestige does it).

local Shared = script.Parent
local Config = require(Shared.Config)

local TycoonCatalog = {}

local floor, max, min, huge = math.floor, math.max, math.min, math.huge

local PLOT = (type(Config.Lobby) == "table" and tonumber(Config.Lobby.PlotSize)) or 72
local HALF = PLOT / 2

TycoonCatalog.Version = 1
TycoonCatalog.PlotSize = PLOT
TycoonCatalog.StartCash = 0 -- Cash of a brand-new profile; Press 1 and the Collector are free
TycoonCatalog.OfflineMinSeconds = 120 -- shorter absences pay nothing (no rejoin farming)
TycoonCatalog.Kinds = { "Press", "Collector", "Garden", "Kitchen", "Gym", "Vault", "House", "Fusion", "Arena", "Decor" }
TycoonCatalog.TierMultiplier = { Normal = 1, Golden = 1.5, Rainbow = 2.5 } -- PetKeys.StatMultiplier

-- Icons (UTF-8 emoji, drawn as text on pad signs and in the Home window).
local ICON = {
	Cloud = "\226\152\129",
	Money = "\240\159\146\176",
	Seedling = "\240\159\140\177",
	Cook = "\240\159\141\179",
	Muscle = "\240\159\146\170",
	Bank = "\240\159\143\166",
	House = "\240\159\143\160",
	Castle = "\240\159\143\176",
	Crystal = "\240\159\148\174",
	Swords = "\226\154\148",
	Lantern = "\240\159\143\174",
	Garden = "\240\159\143\161",
	Tulip = "\240\159\140\183",
	Fountain = "\226\155\178",
	Flag = "\240\159\154\169",
	Trophy = "\240\159\143\134",
	Star = "\226\173\144",
}
TycoonCatalog.Icons = ICON

----------------------------------------------------------------------
-- House tiers (the House station's level IS the tier index; a home without a House counts as the Cottage tier)
----------------------------------------------------------------------
TycoonCatalog.HouseTiers = {
	{ Id = "Cottage", Name = "Cottage", Index = 1, HomeLevel = 0, Icon = ICON.House },
	{ Id = "Villa", Name = "Villa", Index = 2, HomeLevel = 10, Icon = ICON.House },
	{ Id = "Manor", Name = "Manor", Index = 3, HomeLevel = 20, Icon = ICON.House },
	{ Id = "SkyCastle", Name = "Sky Castle", Index = 4, HomeLevel = 30, Icon = ICON.Castle },
}
local TIERS = TycoonCatalog.HouseTiers
local TIER_INDEX = {}
local TIER_BY_ID = {}
for i, t in ipairs(TIERS) do
	TIER_INDEX[t.Id] = i
	TIER_BY_ID[t.Id] = t
end
setmetatable(TIERS, { __index = TIER_BY_ID }) -- HouseTiers.Villa works too

----------------------------------------------------------------------
-- Prestige: at Home Level 40 with the Sky Castle. Resets Cash and station levels (pets, food, decor kept) for +1
-- star: income x1.25 per star (compounding), a Gems reward, the Fusion Machine and the 4th battle-team slot at 1.
----------------------------------------------------------------------
TycoonCatalog.Prestige = {
	Id = "Prestige",
	HomeLevel = 40,
	House = "SkyCastle",
	IncomeMultiplier = 1.25, -- per star: PrestigeMultiplier(stars) = 1.25 ^ stars
	GemReward = 100, -- the first prestige; PrestigeGems(stars) lowers it by GemRewardStep per later star
	GemRewardStep = 10,
	GemRewardMin = 25,
	FusionUnlock = 1, -- the Fusion Machine pad unlocks at this many stars
	TeamSlotUnlock = 1, -- the 4th battle-team slot (Phase 3)
	Icon = ICON.Star,
}

----------------------------------------------------------------------
-- Pet food (cooked at the Kitchen with Cash, fed to pets for XP). KitchenLevel = the Kitchen level that unlocks it.
----------------------------------------------------------------------
TycoonCatalog.Foods = {
	{ Id = "Snack", Name = "Snack", Price = 50, Xp = 25, CookSeconds = 6, KitchenLevel = 1, Blurb = "A crunchy cloud cookie." },
	{ Id = "Meal", Name = "Meal", Price = 600, Xp = 150, CookSeconds = 20, KitchenLevel = 2, Blurb = "A warm bowl of sky stew." },
	{ Id = "Feast", Name = "Feast", Price = 6000, Xp = 800, CookSeconds = 45, KitchenLevel = 4, Blurb = "A whole starfruit pie." },
}
local FOOD_BY_ID = {}
for _, f in ipairs(TycoonCatalog.Foods) do
	FOOD_BY_ID[f.Id] = f
end
TycoonCatalog.FoodsById = FOOD_BY_ID
-- Foods is an ordered array; Foods.Snack also works (read-only lookup, pairs / ipairs still see each food once)
setmetatable(TycoonCatalog.Foods, { __index = FOOD_BY_ID })

----------------------------------------------------------------------
-- Pet XP curve: XpToNext(level) = round(Base * level ^ Exponent / Round) * Round, up to MaxLevel.
-- Pet stats grow +10% per level (PetCatalog.GetStats), so a level-50 pet earns 5.9x its level-1 income.
----------------------------------------------------------------------
TycoonCatalog.PetXp = { MaxLevel = 50, Base = 20, Exponent = 1.6, Round = 5 }
TycoonCatalog.MaxPetLevel = TycoonCatalog.PetXp.MaxLevel -- DataService.AddPetXp caps levels here

----------------------------------------------------------------------
-- Fusion Machine costs (section 11), by rarity (a Mix pays for the HIGHER rarity of its two inputs).
--   Upgrade[rarity].Golden  = 3 Normal copies -> 1 Golden;  Upgrade[rarity].Rainbow = 3 Golden -> 1 Rainbow
--   Mix[rarity]             = two different pets -> a hybrid; Mythic / Secret inputs cost Gems
----------------------------------------------------------------------
TycoonCatalog.Fusion = {
	Copies = 3,
	Upgrade = {
		Common = { Golden = { Tokens = 150 }, Rainbow = { Tokens = 450 } },
		Uncommon = { Golden = { Tokens = 300 }, Rainbow = { Tokens = 900 } },
		Rare = { Golden = { Tokens = 750 }, Rainbow = { Tokens = 2250 } },
		Epic = { Golden = { Tokens = 1800 }, Rainbow = { Tokens = 5400 } },
		Legendary = { Golden = { Tokens = 4500 }, Rainbow = { Tokens = 13500 } },
		Mythic = { Golden = { Tokens = 10000 }, Rainbow = { Tokens = 30000 } },
		Secret = { Golden = { Tokens = 25000 }, Rainbow = { Tokens = 75000 } },
	},
	Mix = {
		Common = { Tokens = 200 },
		Uncommon = { Tokens = 400 },
		Rare = { Tokens = 1000 },
		Epic = { Tokens = 2500 },
		Legendary = { Tokens = 6000 },
		Mythic = { Gems = 60 },
		Secret = { Gems = 150 },
	},
}
-- Fusion.ByRarity[rarity] = { Golden = cost, Rainbow = cost, Mix = cost } (also reachable as Fusion[rarity])
do
	local byRarity = {}
	for rarity, row in pairs(TycoonCatalog.Fusion.Upgrade) do
		byRarity[rarity] = { Golden = row.Golden, Rainbow = row.Rainbow, Mix = TycoonCatalog.Fusion.Mix[rarity] }
	end
	TycoonCatalog.Fusion.ByRarity = byRarity
	setmetatable(TycoonCatalog.Fusion, { __index = byRarity })
end

----------------------------------------------------------------------
-- Layout of the yard (plot-local studs, see the header). The yard is PlotSize x PlotSize inside the lobby fence;
-- nothing is placed outside |x|, |z| <= HALF - 1.5 except along-the-fence decor.
----------------------------------------------------------------------
local function V3(x, y, z)
	return Vector3.new(x, y, z)
end

-- yaw: 0 = the front faces the gate (-Z), 180 = faces the back fence, 90 = faces -X, -90 = faces +X
local function at(x, z, yaw)
	return CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yaw or 0), 0)
end

-- a pad on the ground at (x, z) looking toward (tx, tz) (the station it buys)
local function padAt(x, z, tx, tz)
	local from = V3(x, 0, z)
	local to = V3(tx, 0, tz)
	if (to - from).Magnitude < 1e-3 then
		return CFrame.new(from)
	end
	return CFrame.lookAt(from, to)
end

TycoonCatalog.Layout = {
	PlotSize = PLOT,
	Half = HALF,
	Margin = 1.5, -- stations keep this far from the fence line
	PadSize = V3(4, 0.6, 4), -- buy pads (flat, walkable)
	Gate = V3(0, 0, -HALF), -- centre of the gate opening (the lobby builds the gate; its pillars stand at x = +-7.2)
	GateWidth = 12, -- clear opening between the pillars
	Spawn = V3(0, 0, -12), -- the lobby's home spawn point (kept clear)
	-- the belt from behind the presses into the Collector (HomeFx animates blocks along it)
	Conveyor = { Start = V3(-32.5, 0, 18.5), Finish = V3(-32.5, 0, -22), Width = 3 },
	-- stone paths (centre line + width); every pad touches one
	Paths = {
		{ Name = "Main", Start = V3(0, 0, -HALF), Finish = V3(0, 0, -7), Width = 6 },
		{ Name = "FountainWest", Start = V3(-7, 0, -7), Finish = V3(-7, 0, 5), Width = 4 },
		{ Name = "FountainEast", Start = V3(7, 0, -7), Finish = V3(7, 0, 5), Width = 4 },
		{ Name = "FountainSouth", Start = V3(-7, 0, -7), Finish = V3(7, 0, -7), Width = 4 },
		{ Name = "FountainNorth", Start = V3(-7, 0, 5), Finish = V3(7, 0, 5), Width = 4 },
		{ Name = "HouseWalk", Start = V3(0, 0, 5), Finish = V3(0, 0, 15), Width = 6 },
		{ Name = "FrontCross", Start = V3(-15, 0, -19), Finish = V3(26, 0, -19), Width = 4 },
		{ Name = "GateWalk", Start = V3(-14, 0, -32.5), Finish = V3(14, 0, -32.5), Width = 3 },
		{ Name = "PressLane", Start = V3(-15, 0, -24), Finish = V3(-15, 0, 23), Width = 4 },
		{ Name = "BackCross", Start = V3(-15, 0, 12), Finish = V3(29, 0, 12), Width = 4 },
		{ Name = "GardenWalk", Start = V3(7, 0, -1), Finish = V3(12, 0, -1), Width = 4 },
	},
}

----------------------------------------------------------------------
-- Stations. Price[level] = cash to build / upgrade TO that level. TierCaps = the max level each house tier allows.
----------------------------------------------------------------------
local function caps(c, v, m, s)
	return { Cottage = c, Villa = v, Manor = m, SkyCastle = s }
end

local function pressEffects(incomes)
	local out = {}
	for i, v in ipairs(incomes) do
		out[i] = { Income = v }
	end
	return out
end

local STATIONS = {
	----------------------------------------------------------------- the money machines
	{
		Id = "Press1", Name = "Cloud Press 1", Kind = "Press", Icon = ICON.Cloud,
		Blurb = "Puffs glowing cloud blocks onto the conveyor.",
		MaxLevel = 10, TierCaps = caps(6, 8, 9, 10),
		Requires = {},
		Price = { 0, 60, 160, 500, 2000, 5500, 9000, 20000, 60000, 160000 },
		Effects = pressEffects({ 5, 6.5, 8.5, 11, 14.5, 18.5, 24, 31, 41, 53 }),
		Slot = { CFrame = at(-26.5, -14, -90), Footprint = V3(7, 10, 7), Pad = padAt(-19, -14, -26.5, -14) },
	},
	{
		Id = "Press2", Name = "Cloud Press 2", Kind = "Press", Icon = ICON.Cloud,
		Blurb = "A bigger press: bigger blocks, more Cash.",
		MaxLevel = 10, TierCaps = caps(6, 8, 9, 10),
		Requires = { Press1 = 2 },
		Price = { 700, 1800, 4200, 8500, 15000, 22000, 38000, 70000, 150000, 400000 },
		Effects = pressEffects({ 13, 17, 22, 29, 37, 48, 63, 82, 106, 138 }),
		Slot = { CFrame = at(-26.5, -4.5, -90), Footprint = V3(7, 11, 7), Pad = padAt(-19, -4.5, -26.5, -4.5) },
	},
	{
		Id = "Press3", Name = "Cloud Press 3", Kind = "Press", Icon = ICON.Cloud,
		Blurb = "A storm press that crackles with Cash.",
		MaxLevel = 10, TierCaps = caps(0, 6, 8, 10),
		Requires = { Press2 = 3, House = "Villa" },
		Price = { 18000, 25000, 36000, 52000, 75000, 105000, 170000, 240000, 640000, 1040000 },
		Effects = pressEffects({ 34, 44, 57, 74, 97, 125, 163, 210, 275, 360 }),
		Slot = { CFrame = at(-26.5, 5, -90), Footprint = V3(7, 12, 7), Pad = padAt(-19, 5, -26.5, 5) },
	},
	{
		Id = "Press4", Name = "Cloud Press 4", Kind = "Press", Icon = ICON.Cloud,
		Blurb = "The great sky press: the best money maker.",
		MaxLevel = 10, TierCaps = caps(0, 0, 8, 10),
		Requires = { Press3 = 3, House = "Manor" },
		Price = { 95000, 175000, 220000, 290000, 370000, 480000, 620000, 800000, 1300000, 1900000 },
		Effects = pressEffects({ 88, 114, 149, 193, 250, 325, 425, 550, 715, 930 }),
		Slot = { CFrame = at(-26.5, 14.5, -90), Footprint = V3(7, 13, 7), Pad = padAt(-19, 14.5, -26.5, 14.5) },
	},
	{
		Id = "Collector", Name = "Collector", Kind = "Collector", Icon = ICON.Money,
		Blurb = "Turns cloud blocks into Cash. Step on it to bank.",
		MaxLevel = 5, TierCaps = caps(2, 3, 4, 5),
		Requires = { Press1 = 1 },
		Price = { 0, 6000, 45000, 240000, 800000 },
		Effects = {
			{ Bonus = 0, CapSeconds = 300, FlatCap = 2000 },
			{ Bonus = 0.1, CapSeconds = 360, FlatCap = 6000 },
			{ Bonus = 0.2, CapSeconds = 420, FlatCap = 20000 },
			{ Bonus = 0.3, CapSeconds = 480, FlatCap = 60000 },
			{ Bonus = 0.4, CapSeconds = 600, FlatCap = 150000 },
		},
		Slot = { CFrame = at(-27.5, -26.5, -90), Footprint = V3(9, 8, 13), Pad = padAt(-17, -26.5, -27.5, -26.5) },
	},
	----------------------------------------------------------------- pets at home
	{
		Id = "Garden", Name = "Pet Garden", Kind = "Garden", Icon = ICON.Seedling,
		Blurb = "Economy pets work here and earn Cash.",
		MaxLevel = 8, TierCaps = caps(2, 4, 6, 8),
		Requires = { Press2 = 2 },
		Price = { 1500, 12000, 30000, 65000, 170000, 350000, 720000, 1440000 },
		Effects = {
			{ Slots = 1 }, { Slots = 2 }, { Slots = 3 }, { Slots = 4 },
			{ Slots = 5 }, { Slots = 6 }, { Slots = 7 }, { Slots = 8 },
		},
		Slot = {
			CFrame = at(24, -1, 90), Footprint = V3(22, 4, 20), Pad = padAt(10, -1, 24, -1),
			-- 8 pet places (station frame: X along the front, -Z toward the front)
			Spots = {
				V3(-7.5, 0, -4), V3(-2.5, 0, -4), V3(2.5, 0, -4), V3(7.5, 0, -4),
				V3(-7.5, 0, 4), V3(-2.5, 0, 4), V3(2.5, 0, 4), V3(7.5, 0, 4),
			},
		},
	},
	{
		Id = "Kitchen", Name = "Kitchen", Kind = "Kitchen", Icon = ICON.Cook,
		Blurb = "Cook pet food with Cash; feeding gives pets XP.",
		MaxLevel = 5, TierCaps = caps(1, 2, 4, 5),
		Requires = { Garden = 1 },
		Price = { 3500, 35000, 190000, 400000, 1100000 },
		Effects = {
			{ Slots = 3, CookSpeed = 1 },
			{ Slots = 4, CookSpeed = 1.25 },
			{ Slots = 6, CookSpeed = 1.5 },
			{ Slots = 8, CookSpeed = 1.75 },
			{ Slots = 10, CookSpeed = 2 },
		},
		Slot = { CFrame = at(25, 24, 0), Footprint = V3(16, 10, 10), Pad = padAt(19.5, 14.5, 25, 24) },
	},
	{
		Id = "Gym", Name = "Gym", Kind = "Gym", Icon = ICON.Muscle,
		Blurb = "Combat pets train here and gain XP over time.",
		MaxLevel = 5, TierCaps = caps(1, 2, 4, 5),
		Requires = { Kitchen = 1 },
		Price = { 14000, 65000, 250000, 540000, 1300000 },
		Effects = {
			{ Slots = 1, XpPerMinute = 20 },
			{ Slots = 2, XpPerMinute = 30 },
			{ Slots = 3, XpPerMinute = 45 },
			{ Slots = 4, XpPerMinute = 60 },
			{ Slots = 5, XpPerMinute = 80 },
		},
		Slot = {
			CFrame = at(-24, 29, 0), Footprint = V3(18, 10, 9), Pad = padAt(-19, 22.5, -24, 29),
			Spots = { V3(-6, 0, 0), V3(-3, 0, 0), V3(0, 0, 0), V3(3, 0, 0), V3(6, 0, 0) },
		},
	},
	{
		Id = "Vault", Name = "Vault", Kind = "Vault", Icon = ICON.Bank,
		Blurb = "Holds more Cash and pays you while you are away.",
		MaxLevel = 5, TierCaps = caps(1, 2, 4, 5),
		Requires = { Press2 = 2 },
		Price = { 9000, 50000, 220000, 480000, 1200000 },
		Effects = {
			{ CapSeconds = 300, FlatCap = 5000, OfflinePercent = 0.1, OfflineHours = 1 },
			{ CapSeconds = 600, FlatCap = 20000, OfflinePercent = 0.15, OfflineHours = 2 },
			{ CapSeconds = 900, FlatCap = 60000, OfflinePercent = 0.2, OfflineHours = 3 },
			{ CapSeconds = 1200, FlatCap = 150000, OfflinePercent = 0.25, OfflineHours = 4 },
			{ CapSeconds = 1800, FlatCap = 400000, OfflinePercent = 0.3, OfflineHours = 4 },
		},
		Slot = { CFrame = at(-10.5, -27, 180), Footprint = V3(7, 9, 8), Pad = padAt(-10.5, -19, -10.5, -27) },
	},
	{
		Id = "House", Name = "House", Kind = "House", Icon = ICON.House,
		Blurb = "Your home. Each new house raises every station's max level.",
		MaxLevel = 4, TierCaps = caps(4, 4, 4, 4),
		Requires = { Collector = 1 },
		LevelRequires = { [2] = { HomeLevel = 10 }, [3] = { HomeLevel = 20 }, [4] = { HomeLevel = 30 } },
		Price = { 300, 24000, 115000, 520000 },
		Effects = {
			{ Tier = "Cottage", TierIndex = 1, Name = "Cottage" },
			{ Tier = "Villa", TierIndex = 2, Name = "Villa" },
			{ Tier = "Manor", TierIndex = 3, Name = "Manor" },
			{ Tier = "SkyCastle", TierIndex = 4, Name = "Sky Castle" },
		},
		Slot = { CFrame = at(0, 25, 0), Footprint = V3(26, 30, 18), Pad = padAt(0, 12, 0, 25) },
	},
	{
		Id = "FusionMachine", Name = "Fusion Machine", Kind = "Fusion", Icon = ICON.Crystal,
		Blurb = "Fuse 3 copies into Golden or Rainbow, or mix two pets.",
		MaxLevel = 3, TierCaps = caps(1, 2, 3, 3),
		Requires = { Kitchen = 1, Prestige = 1 },
		Price = { 25000, 200000, 800000 },
		Effects = { { TokenDiscount = 0 }, { TokenDiscount = 0.1 }, { TokenDiscount = 0.2 } },
		Slot = { CFrame = at(11, -25, 180), Footprint = V3(10, 12, 10), Pad = padAt(11, -16, 11, -25) },
	},
	{
		Id = "ArenaGate", Name = "Arena Gate", Kind = "Arena", Icon = ICON.Swords,
		Blurb = "Opens the way to pet battles.",
		MaxLevel = 1, TierCaps = caps(1, 1, 1, 1),
		Requires = { Gym = 1 },
		ComingSoon = true, -- Phase 3 removes this flag
		Price = { 150000 },
		Effects = { { Battles = true } },
		Slot = { CFrame = at(32, 14.5, 90), Footprint = V3(7, 12, 4), Pad = padAt(27, 14.5, 32, 14.5) },
	},
	----------------------------------------------------------------- decor (kept on prestige, +1 Home Level each)
	{
		Id = "DecorLamps", Name = "Lanterns", Kind = "Decor", Icon = ICON.Lantern,
		Blurb = "Warm lanterns along your path.",
		MaxLevel = 3, TierCaps = caps(1, 2, 3, 3), KeepOnPrestige = true,
		Requires = { Collector = 1 },
		Price = { 3000, 27000, 210000 },
		Effects = { { Pieces = 4, Style = "Wood" }, { Pieces = 6, Style = "Brass" }, { Pieces = 8, Style = "Crystal" } },
		Slot = { CFrame = at(0, -21, 0), Footprint = V3(9, 7, 26), Walkable = true, Pad = padAt(-8, -12, -3, -12) },
	},
	{
		Id = "DecorFence", Name = "Garden Fence", Kind = "Decor", Icon = ICON.Garden,
		Blurb = "A prettier fence around your whole yard.",
		MaxLevel = 3, TierCaps = caps(1, 2, 3, 3), KeepOnPrestige = true,
		Requires = { Press2 = 2 },
		Price = { 7000, 48000, 290000 },
		Effects = { { Pieces = 1, Style = "Picket" }, { Pieces = 2, Style = "Hedge" }, { Pieces = 3, Style = "Cloudstone" } },
		Slot = { CFrame = at(0, 0, 0), Footprint = V3(PLOT, 4, PLOT), Perimeter = true, Pad = padAt(8, -10, 3, -10) },
	},
	{
		Id = "DecorFlowers", Name = "Flower Beds", Kind = "Decor", Icon = ICON.Tulip,
		Blurb = "Colourful flower beds along the front fence.",
		MaxLevel = 3, TierCaps = caps(1, 2, 3, 3), KeepOnPrestige = true,
		Requires = { Garden = 1 },
		Price = { 4500, 36000, 240000 },
		Effects = { { Pieces = 3, Style = "Tulips" }, { Pieces = 5, Style = "Roses" }, { Pieces = 7, Style = "Starflowers" } },
		Slot = { CFrame = at(-25, -34.3, 180), Footprint = V3(18, 2, 2.2), Pad = padAt(-12.5, -33.3, -25, -34.3) },
	},
	{
		Id = "DecorFountain", Name = "Fountain", Kind = "Decor", Icon = ICON.Fountain,
		Blurb = "A splashing fountain in the middle of the yard.",
		MaxLevel = 3, TierCaps = caps(0, 1, 2, 3), KeepOnPrestige = true,
		Requires = { Kitchen = 1, House = "Villa" },
		Price = { 45000, 290000, 880000 },
		Effects = { { Pieces = 1, Style = "Basin" }, { Pieces = 2, Style = "Tiered" }, { Pieces = 3, Style = "Sky" } },
		Slot = { CFrame = at(0, -1, 0), Footprint = V3(9, 8, 9), Pad = padAt(-7, -1, 0, -1) },
	},
	{
		Id = "DecorBanners", Name = "Banners", Kind = "Decor", Icon = ICON.Flag,
		Blurb = "Banners in your colours along the front fence.",
		MaxLevel = 3, TierCaps = caps(1, 2, 3, 3), KeepOnPrestige = true,
		Requires = { Vault = 1 },
		Price = { 12000, 65000, 380000 },
		Effects = { { Pieces = 2, Style = "Cloth" }, { Pieces = 4, Style = "Gold" }, { Pieces = 6, Style = "Royal" } },
		Slot = { CFrame = at(25, -34.3, 180), Footprint = V3(18, 6, 2.2), Pad = padAt(12.5, -33.3, 25, -34.3) },
	},
	{
		Id = "DecorPodium", Name = "Pet Podium", Kind = "Decor", Icon = ICON.Trophy,
		Blurb = "Shows off your favourite pet by the gate.",
		MaxLevel = 3, TierCaps = caps(1, 2, 3, 3), KeepOnPrestige = true,
		Requires = { Garden = 1 },
		Price = { 9000, 56000, 340000 },
		Effects = { { Pieces = 1, Style = "Stone" }, { Pieces = 2, Style = "Gold" }, { Pieces = 3, Style = "Crystal" } },
		-- the lobby's podium (SpotInfo.PodiumCFrame, the pet faces the street) stands at (24, -26): this decor dresses
		-- it up; its front (and pad) face the yard
		Slot = { CFrame = at(24, -26, 180), Footprint = V3(8, 6, 8), Pad = padAt(24, -17.5, 24, -26) },
	},
}

TycoonCatalog.Stations = STATIONS
local BY_ID = {}
local ORDER = {}
for i, def in ipairs(STATIONS) do
	def.Order = i
	def.Requires = def.Requires or {}
	def.LevelRequires = def.LevelRequires or {}
	BY_ID[def.Id] = def
	ORDER[i] = def.Id
end
TycoonCatalog.ById = BY_ID
TycoonCatalog.Order = ORDER
setmetatable(STATIONS, { __index = BY_ID }) -- Stations.Press1 works too (the array part stays the display order)

-- the Kitchen's recipes per level (derived from Foods so they never disagree)
do
	local kitchen = BY_ID.Kitchen
	for level, eff in ipairs(kitchen.Effects) do
		local recipes = {}
		for _, f in ipairs(TycoonCatalog.Foods) do
			if f.KitchenLevel <= level then
				recipes[#recipes + 1] = f.Id
			end
		end
		eff.Recipes = recipes
		eff.Queue = eff.Slots -- the cooking queue size
	end
end

-- tier caps also live on the tiers: HouseTiers[i].Caps[stationId] = max level
for i, tier in ipairs(TIERS) do
	tier.Caps = {}
	for _, def in ipairs(STATIONS) do
		tier.Caps[def.Id] = def.TierCaps[tier.Id] or 0
	end
	tier.Order = i
end

-- The prestige pad (not a station: TycoonService handles it with its Prestige()). Get("Prestige") returns this.
local PRESTIGE_PAD = {
	Id = "Prestige", Name = "Prestige", Kind = "Prestige", Icon = ICON.Star, IsPrestige = true,
	Blurb = "Start over with +1 star: x1.25 income forever and Gems.",
	MaxLevel = 1, TierCaps = caps(0, 0, 0, 1), Requires = { House = "SkyCastle" },
	LevelRequires = {}, Price = { 0 }, Effects = { {} },
	Slot = { CFrame = at(-8, 18, 0), Footprint = V3(4, 1, 4), Walkable = true, Pad = padAt(-8, 12, -8, 18) },
}
TycoonCatalog.PrestigePad = PRESTIGE_PAD

----------------------------------------------------------------------
-- small helpers
----------------------------------------------------------------------
local function int(v)
	v = tonumber(v)
	if not v or v ~= v or v == huge or v == -huge then
		return nil
	end
	return floor(v)
end

local function stationsOf(home)
	local st = type(home) == "table" and home.Stations
	if type(st) == "table" then
		return st
	end
	return nil
end

-- current level of a station in a home (0 for junk; clamped to 0..MaxLevel)
local function levelOf(home, id)
	local def = BY_ID[id]
	local st = stationsOf(home)
	if not def or not st then
		return 0
	end
	local v = int(st[id])
	if not v or v < 0 then
		return 0
	end
	if v > def.MaxLevel then
		return def.MaxLevel
	end
	return v
end

local function starsOf(home)
	local v = type(home) == "table" and int(home.Prestige)
	if not v or v < 0 then
		return 0
	end
	return min(v, 1000)
end

local MAX_STARS = 1000 -- corrupt data guard: 1.25 ^ 1000 is still a finite number

local function sanitizeStars(v)
	v = int(v)
	if not v or v < 0 then
		return 0
	end
	return min(v, MAX_STARS)
end

-- tier index from an id ("Villa"), an index (2) or nil
local function tierIndexOf(value)
	if type(value) == "string" then
		return TIER_INDEX[value]
	end
	local n = int(value)
	if n and n >= 1 and n <= #TIERS then
		return n
	end
	return nil
end

local function commas(n)
	local s = tostring(floor(n))
	local neg = s:sub(1, 1) == "-"
	if neg then
		s = s:sub(2)
	end
	local out = s
	while true do
		local k
		out, k = out:gsub("^(%d+)(%d%d%d)", "%1,%2")
		if k == 0 then
			break
		end
	end
	return (neg and "-" or "") .. out
end

----------------------------------------------------------------------
-- basic lookups
----------------------------------------------------------------------
function TycoonCatalog.Get(id)
	if id == "Prestige" then
		return PRESTIGE_PAD
	end
	return BY_ID[id]
end

function TycoonCatalog.PriceFor(id, level)
	local def = TycoonCatalog.Get(id)
	local lv = int(level)
	if not def or not lv or lv < 1 or lv > def.MaxLevel then
		return nil
	end
	return def.Price[lv]
end

function TycoonCatalog.EffectsOf(id, level)
	local def = BY_ID[id]
	local lv = int(level)
	if not def or not lv or lv < 1 then
		return nil
	end
	return def.Effects[min(lv, def.MaxLevel)]
end

function TycoonCatalog.StationLevel(home, id)
	return levelOf(home, id)
end

function TycoonCatalog.HomeLevelOf(home)
	local total = 0
	for _, def in ipairs(STATIONS) do
		total = total + levelOf(home, def.Id)
	end
	return total
end

-- house tier index (1 = Cottage .. 4 = Sky Castle) and its def; a home without a House is a Cottage
function TycoonCatalog.HouseTierOf(home)
	local i = max(1, levelOf(home, "House"))
	return i, TIERS[i]
end

function TycoonCatalog.HouseTier(idOrIndex)
	local i = tierIndexOf(idOrIndex)
	return i and TIERS[i] or nil
end

-- the max level the current house tier allows for a station
function TycoonCatalog.MaxLevelAt(id, home)
	local def = BY_ID[id]
	if not def then
		return 0
	end
	local tier = TycoonCatalog.HouseTierOf(home)
	return def.TierCaps[TIERS[tier].Id] or 0
end

-- first tier whose cap allows `level` (nil if none)
local function tierAllowing(def, level)
	for i, tier in ipairs(TIERS) do
		if (def.TierCaps[tier.Id] or 0) >= level then
			return i
		end
	end
	return nil
end

function TycoonCatalog.PrestigeMultiplier(stars)
	return TycoonCatalog.Prestige.IncomeMultiplier ^ sanitizeStars(stars)
end

-- Gems for reaching `newStars` (1 = the first prestige)
function TycoonCatalog.PrestigeGems(newStars)
	local p = TycoonCatalog.Prestige
	local n = max(1, sanitizeStars(newStars))
	return max(p.GemRewardMin, p.GemReward - p.GemRewardStep * (n - 1))
end

----------------------------------------------------------------------
-- requirements, lock reasons and pads
----------------------------------------------------------------------
local function treeMet(def, home)
	for key, need in pairs(def.Requires) do
		if BY_ID[key] and key ~= "House" then
			if levelOf(home, key) < (int(need) or 0) then
				return false
			end
		end
	end
	return true
end

-- why `nextLevel` of `def` cannot be bought yet (nil = it can, given the cash)
local function lockReason(def, nextLevel, home, homeLevel, tier, stars)
	if def.ComingSoon then
		return "Coming soon"
	end
	local req = def.Requires
	local needStars = int(req.Prestige)
	if needStars and stars < needStars then
		return "Unlocks at Prestige " .. needStars
	end
	local needTier = req.House ~= nil and tierIndexOf(req.House) or nil
	if needTier and tier < needTier then
		return "Needs the " .. TIERS[needTier].Name
	end
	local needHL = int(req.HomeLevel)
	local lr = def.LevelRequires[nextLevel]
	if type(lr) == "table" and int(lr.HomeLevel) and (not needHL or int(lr.HomeLevel) > needHL) then
		needHL = int(lr.HomeLevel)
	end
	if needHL and homeLevel < needHL then
		return "Reach Home Level " .. needHL
	end
	local cap = def.TierCaps[TIERS[tier].Id] or 0
	if nextLevel > cap then
		local t = tierAllowing(def, nextLevel)
		if t then
			return "Needs the " .. TIERS[t].Name
		end
		return "Maxed"
	end
	return nil
end

function TycoonCatalog.PadLevelText(currentLevel, nextLevel)
	local cur = int(currentLevel) or 0
	if cur <= 0 then
		return "Build"
	end
	return "Lv " .. cur .. " -> " .. (int(nextLevel) or (cur + 1))
end

-- ok, reason: can this home prestige right now?
function TycoonCatalog.CanPrestige(home)
	local p = TycoonCatalog.Prestige
	local tier = TycoonCatalog.HouseTierOf(home)
	local need = tierIndexOf(p.House) or #TIERS
	if tier < need or levelOf(home, "House") < need then
		return false, "Needs the " .. TIERS[need].Name
	end
	if TycoonCatalog.HomeLevelOf(home) < p.HomeLevel then
		return false, "Reach Home Level " .. p.HomeLevel
	end
	return true, nil
end

function TycoonCatalog.AvailablePads(home)
	local pads = {}
	local homeLevel = TycoonCatalog.HomeLevelOf(home)
	local tier = TycoonCatalog.HouseTierOf(home)
	local stars = starsOf(home)
	for _, def in ipairs(STATIONS) do
		local level = levelOf(home, def.Id)
		if level < def.MaxLevel and treeMet(def, home) then
			local nextLevel = level + 1
			local title = def.Name
			if def.Kind == "House" then
				title = (TIERS[nextLevel] and TIERS[nextLevel].Name) or def.Name
			end
			pads[#pads + 1] = {
				StationId = def.Id,
				NextLevel = nextLevel,
				Price = def.Price[nextLevel],
				Locked = lockReason(def, nextLevel, home, homeLevel, tier, stars),
				Level = level,
				MaxLevel = def.MaxLevel,
				Name = def.Name,
				Title = title,
				Kind = def.Kind,
				Icon = def.Icon,
				LevelText = TycoonCatalog.PadLevelText(level, nextLevel),
			}
		end
	end
	local castle = tierIndexOf(TycoonCatalog.Prestige.House) or #TIERS
	if levelOf(home, "House") >= castle then
		local ok, reason = TycoonCatalog.CanPrestige(home)
		pads[#pads + 1] = {
			StationId = PRESTIGE_PAD.Id,
			NextLevel = stars + 1,
			Price = 0,
			Locked = (not ok) and reason or nil,
			Level = stars,
			MaxLevel = stars + 1,
			Name = PRESTIGE_PAD.Name,
			Title = "Prestige " .. (stars + 1),
			Kind = PRESTIGE_PAD.Kind,
			Icon = PRESTIGE_PAD.Icon,
			LevelText = stars .. " -> " .. (stars + 1) .. " " .. ICON.Star,
			Prestige = true,
		}
	end
	return pads
end

-- Server-side purchase check: ok, price | nil, reason. (TycoonService still re-checks the Cash atomically.)
function TycoonCatalog.CheckPurchase(home, stationId)
	if type(stationId) ~= "string" or not BY_ID[stationId] then
		return false, nil, "Unknown station"
	end
	for _, pad in ipairs(TycoonCatalog.AvailablePads(home)) do
		if pad.StationId == stationId then
			if pad.Locked then
				return false, pad.Price, pad.Locked
			end
			return true, pad.Price, nil
		end
	end
	local def = BY_ID[stationId]
	if levelOf(home, stationId) >= def.MaxLevel then
		return false, nil, "Maxed"
	end
	return false, nil, "Not unlocked yet"
end

-- The Stations table after a prestige: decor (KeepOnPrestige) stays, everything else resets.
function TycoonCatalog.StationsAfterPrestige(stations)
	local out = {}
	if type(stations) ~= "table" then
		return out
	end
	for id, level in pairs(stations) do
		local def = BY_ID[id]
		local lv = int(level)
		if def and def.KeepOnPrestige and lv and lv > 0 then
			out[id] = min(lv, def.MaxLevel)
		end
	end
	return out
end

----------------------------------------------------------------------
-- income, cap, offline earnings
----------------------------------------------------------------------
-- press cash/s with the Collector bonus (prestige multiplier NOT applied)
function TycoonCatalog.PressIncome(home)
	local collector = levelOf(home, "Collector")
	if collector < 1 then
		return 0
	end
	local total = 0
	for _, def in ipairs(STATIONS) do
		if def.Kind == "Press" then
			local lv = levelOf(home, def.Id)
			if lv > 0 then
				total = total + (def.Effects[lv].Income or 0)
			end
		end
	end
	return total * (1 + (BY_ID.Collector.Effects[collector].Bonus or 0))
end

local function rarityScale(rarity)
	local ps = Config.PetStats
	local scales = type(ps) == "table" and ps.RarityScale
	local s = type(scales) == "table" and tonumber(scales[rarity])
	if s and s > 0 then
		return s
	end
	return 1
end

local function tierMultiplier(tier)
	if type(tier) == "number" and tier > 0 and tier == tier and tier ~= huge then
		return tier
	end
	return TycoonCatalog.TierMultiplier[tier] or 1
end

-- lazily resolved PetCatalog (only for pet key strings)
local petCatalog, petCatalogResolved = nil, false
local function getPetCatalog()
	if not petCatalogResolved then
		petCatalogResolved = true
		local module = Shared:FindFirstChild("PetCatalog")
		if module then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				petCatalog = result
			end
		end
	end
	return petCatalog
end

-- cash/s of one garden entry (any of the shapes listed in the header); prestige NOT applied
function TycoonCatalog.PetIncome(entry, level, tier)
	if type(entry) == "number" then
		if entry ~= entry or entry == huge or entry < 0 then
			return 0
		end
		return entry
	end
	local def = entry
	if type(entry) == "string" then
		if entry:sub(1, 4) == "hyb:" then
			return 0 -- hybrids need the profile: pass PetKeys.DefOf(key, profile) instead
		end
		local petId, suffix = entry:match("^([^@]+)@(%a+)$")
		petId = petId or entry
		tier = tier or suffix
		local pc = getPetCatalog()
		def = pc and type(pc.Get) == "function" and pc.Get(petId) or nil
		if not def then
			return 0
		end
	end
	if type(def) ~= "table" then
		return 0
	end
	if type(def.Def) == "table" then
		level = level or def.Level
		tier = tier or def.Tier
		def = def.Def
	elseif type(def.Stats) ~= "table" and type(def.Income) == "number" then
		local v = def.Income
		if v ~= v or v == huge or v < 0 then
			return 0
		end
		return v
	end
	local stats = def.Stats
	local base = type(stats) == "table" and tonumber(stats.Income) or nil
	if not base or base ~= base or base <= 0 or base == huge then
		return 0
	end
	local lv = int(level or def.Level) or 1
	if lv < 1 then
		lv = 1
	end
	lv = min(lv, TycoonCatalog.PetXp.MaxLevel)
	local mult = tier
	if mult == nil then
		mult = def.StatMultiplier or def.Tier or (type(def.Look) == "table" and def.Look.Finish) or nil
	end
	return base * rarityScale(def.Rarity) * (1 + 0.1 * (lv - 1)) * tierMultiplier(mult)
end

function TycoonCatalog.GardenSlots(home)
	local lv = levelOf(home, "Garden")
	if lv < 1 then
		return 0
	end
	return BY_ID.Garden.Effects[lv].Slots
end

-- garden cash/s (prestige NOT applied); only the first GardenSlots entries count (array order, then pairs)
function TycoonCatalog.GardenIncome(home, gardenDefs)
	local slots = TycoonCatalog.GardenSlots(home)
	if slots <= 0 or type(gardenDefs) ~= "table" then
		return 0
	end
	local total, counted = 0, 0
	local seen = {}
	for i, entry in ipairs(gardenDefs) do
		seen[i] = true
		if counted >= slots then
			break
		end
		local v = TycoonCatalog.PetIncome(entry)
		if v > 0 then
			total = total + v
			counted = counted + 1
		end
	end
	if counted < slots then
		-- a map (slot -> entry) instead of an array
		local keys = {}
		for k in pairs(gardenDefs) do
			if not seen[k] then
				keys[#keys + 1] = k
			end
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, k in ipairs(keys) do
			if counted >= slots then
				break
			end
			local v = TycoonCatalog.PetIncome(gardenDefs[k])
			if v > 0 then
				total = total + v
				counted = counted + 1
			end
		end
	end
	return total
end

function TycoonCatalog.IncomePerSecond(home, gardenDefs, prestige)
	local stars = prestige
	if stars == nil then
		stars = starsOf(home)
	end
	local mult = TycoonCatalog.PrestigeMultiplier(stars)
	if levelOf(home, "Collector") < 1 then
		return 0, { Press = 0, Garden = 0, Multiplier = mult }
	end
	local press = TycoonCatalog.PressIncome(home)
	local garden = TycoonCatalog.GardenIncome(home, gardenDefs)
	return (press + garden) * mult, { Press = press * mult, Garden = garden * mult, Multiplier = mult }
end

function TycoonCatalog.CollectorCap(home, incomePerSecond)
	local collector = levelOf(home, "Collector")
	if collector < 1 then
		return 0
	end
	local ce = BY_ID.Collector.Effects[collector]
	local flat, seconds = ce.FlatCap or 0, ce.CapSeconds or 0
	local vault = levelOf(home, "Vault")
	if vault > 0 then
		local ve = BY_ID.Vault.Effects[vault]
		flat = flat + (ve.FlatCap or 0)
		seconds = seconds + (ve.CapSeconds or 0)
	end
	-- presses + the pets listed in home.Garden (keys, counted at level 1) unless the caller knows better
	local income = TycoonCatalog.IncomePerSecond(home, type(home) == "table" and home.Garden or nil)
	local given = tonumber(incomePerSecond)
	if given and given == given and given ~= huge and given > income then
		income = given
	end
	return floor(flat + seconds * income)
end

function TycoonCatalog.OfflineEarnings(home, seconds, incomePerSecond)
	local vault = levelOf(home, "Vault")
	local s = tonumber(seconds)
	local income = tonumber(incomePerSecond)
	if vault < 1 or not s or s ~= s or not income or income ~= income or income <= 0 or income == huge then
		return 0, { Seconds = 0, Percent = 0, MaxHours = 0 }
	end
	local ve = BY_ID.Vault.Effects[vault]
	local info = { Seconds = 0, Percent = ve.OfflinePercent, MaxHours = ve.OfflineHours }
	if s < TycoonCatalog.OfflineMinSeconds then
		return 0, info
	end
	local counted = min(s, ve.OfflineHours * 3600)
	info.Seconds = counted
	return floor(income * counted * ve.OfflinePercent), info
end

----------------------------------------------------------------------
-- kitchen, gym, food, fusion, XP
----------------------------------------------------------------------
function TycoonCatalog.FoodById(id)
	return FOOD_BY_ID[id]
end

-- foods the Kitchen can cook at `kitchenLevel`
function TycoonCatalog.FoodsFor(kitchenLevel)
	local out = {}
	local lv = int(kitchenLevel) or 0
	for _, f in ipairs(TycoonCatalog.Foods) do
		if lv >= f.KitchenLevel then
			out[#out + 1] = f
		end
	end
	return out
end

function TycoonCatalog.KitchenSpeed(home)
	local lv = levelOf(home, "Kitchen")
	if lv < 1 then
		return 0
	end
	return BY_ID.Kitchen.Effects[lv].CookSpeed
end

-- seconds to cook one `foodId` at `kitchenLevel` (nil if the Kitchen cannot cook it)
function TycoonCatalog.CookSecondsFor(foodId, kitchenLevel)
	local f = FOOD_BY_ID[foodId]
	local lv = int(kitchenLevel) or 0
	if not f or lv < f.KitchenLevel then
		return nil
	end
	local eff = BY_ID.Kitchen.Effects[min(lv, BY_ID.Kitchen.MaxLevel)]
	return f.CookSeconds / (eff.CookSpeed or 1)
end

function TycoonCatalog.GymSlots(home)
	local lv = levelOf(home, "Gym")
	if lv < 1 then
		return 0
	end
	return BY_ID.Gym.Effects[lv].Slots
end

function TycoonCatalog.GymXpPerMinute(home)
	local lv = levelOf(home, "Gym")
	if lv < 1 then
		return 0
	end
	return BY_ID.Gym.Effects[lv].XpPerMinute
end

-- cost table ({Tokens = n} or {Gems = n}) of a fusion, or nil.
--   FusionCost("Upgrade", rarity, "Golden" | "Rainbow", fusionLevel?)   (target tier)
--   FusionCost("Mix", rarity, nil, fusionLevel?)                         (the higher rarity of both inputs)
-- The Fusion Machine's TokenDiscount (by level) lowers Token prices; Gem prices never change.
function TycoonCatalog.FusionCost(action, rarity, tier, fusionLevel)
	local F = TycoonCatalog.Fusion
	local base
	if action == "Upgrade" then
		local row = F.Upgrade[rarity]
		base = row and row[tier or "Golden"]
	elseif action == "Mix" then
		base = F.Mix[rarity]
	end
	if type(base) ~= "table" then
		return nil
	end
	local discount = 0
	local lv = int(fusionLevel)
	if lv and lv >= 1 then
		local eff = BY_ID.FusionMachine.Effects[min(lv, BY_ID.FusionMachine.MaxLevel)]
		discount = eff.TokenDiscount or 0
	end
	local out = {}
	for k, v in pairs(base) do
		if k == "Tokens" then
			out[k] = floor(v * (1 - discount) + 0.5)
		else
			out[k] = v
		end
	end
	return out
end

function TycoonCatalog.XpToNext(level)
	local px = TycoonCatalog.PetXp
	local lv = int(level)
	if not lv or lv < 1 then
		lv = 1
	end
	if lv >= px.MaxLevel then
		return huge
	end
	local raw = px.Base * lv ^ px.Exponent
	return max(px.Round, floor(raw / px.Round + 0.5) * px.Round)
end

-- total XP from level 1 to `level`
function TycoonCatalog.XpForLevel(level)
	local lv = int(level) or 1
	local total = 0
	for l = 1, min(lv, TycoonCatalog.PetXp.MaxLevel) - 1 do
		total = total + TycoonCatalog.XpToNext(l)
	end
	return total
end

-- "$950", "$12.5K", "$3.2M"
function TycoonCatalog.FormatCash(n)
	local v = tonumber(n) or 0
	if v ~= v then
		v = 0
	end
	local a = math.abs(v)
	local sign = v < 0 and "-" or ""
	if a < 10000 then
		return sign .. "$" .. commas(a)
	end
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in ipairs(units) do
		if a >= u[1] then
			local x = a / u[1]
			local s
			if x >= 100 then
				s = string.format("%d", floor(x))
			else
				s = string.format("%.1f", floor(x * 10) / 10)
				s = s:gsub("%.0$", "")
			end
			return sign .. "$" .. s .. u[2]
		end
	end
	return sign .. "$" .. commas(a)
end

----------------------------------------------------------------------
-- Validate (data self-check): ok, { problem... }
----------------------------------------------------------------------
-- world-aligned rectangle {x0, x1, z0, z1} of a slot footprint (yaw in 90 degree steps)
local function footprintRect(cf, size)
	local look = cf.LookVector
	local alongX = math.abs(look.X) > 0.7 -- the front faces +-X: the width runs along Z
	local w, d = size.X, size.Z
	local sx, sz = w, d
	if alongX then
		sx, sz = d, w
	end
	local p = cf.Position
	return { p.X - sx / 2, p.X + sx / 2, p.Z - sz / 2, p.Z + sz / 2 }
end
TycoonCatalog.FootprintRect = footprintRect

local function padRect(cf)
	local s = TycoonCatalog.Layout.PadSize
	local p = cf.Position
	return { p.X - s.X / 2, p.X + s.X / 2, p.Z - s.Z / 2, p.Z + s.Z / 2 }
end
TycoonCatalog.PadRect = padRect

local function overlap(a, b, gap)
	gap = gap or 0
	return a[1] < b[2] + gap and b[1] < a[2] + gap and a[3] < b[4] + gap and b[3] < a[4] + gap
end

-- Which pads can a player (about 2 studs wide) walk to from the gate? Returns { [padName] = true } for reachable
-- pads and the grid size. Obstacles: every station footprint that is not Walkable / Perimeter, grown by `radius`.
function TycoonCatalog.ReachablePads(radius, cell)
	radius = radius or 1
	cell = cell or 1
	local n = floor(PLOT / cell)
	local blocked = {}
	local rects = {}
	for _, def in ipairs(STATIONS) do
		local slot = def.Slot
		if slot and not slot.Walkable and not slot.Perimeter then
			rects[#rects + 1] = footprintRect(slot.CFrame, slot.Footprint)
		end
	end
	local function cellCentre(i)
		return -HALF + (i - 0.5) * cell
	end
	for ix = 1, n do
		for iz = 1, n do
			local x, z = cellCentre(ix), cellCentre(iz)
			local b = math.abs(x) > HALF - radius or math.abs(z) > HALF - radius
			if not b then
				for _, r in ipairs(rects) do
					if x > r[1] - radius and x < r[2] + radius and z > r[3] - radius and z < r[4] + radius then
						b = true
						break
					end
				end
			end
			if b then
				blocked[(ix - 1) * n + iz] = true
			end
		end
	end
	-- flood from the gate (the cells just inside the opening)
	local seen = {}
	local queue = {}
	local gate = TycoonCatalog.Layout.Gate
	for ix = 1, n do
		local x = cellCentre(ix)
		if math.abs(x - gate.X) < TycoonCatalog.Layout.GateWidth / 2 - radius then
			for iz = 1, 3 do
				local key = (ix - 1) * n + iz
				if not blocked[key] and not seen[key] then
					seen[key] = true
					queue[#queue + 1] = key
				end
			end
		end
	end
	local head = 1
	while head <= #queue do
		local key = queue[head]
		head = head + 1
		local ix = floor((key - 1) / n) + 1
		local iz = key - (ix - 1) * n
		local nbs = { { ix + 1, iz }, { ix - 1, iz }, { ix, iz + 1 }, { ix, iz - 1 } }
		for _, nb in ipairs(nbs) do
			local a, b = nb[1], nb[2]
			if a >= 1 and a <= n and b >= 1 and b <= n then
				local k2 = (a - 1) * n + b
				if not blocked[k2] and not seen[k2] then
					seen[k2] = true
					queue[#queue + 1] = k2
				end
			end
		end
	end
	local reachable = {}
	local all = {}
	for _, def in ipairs(STATIONS) do
		all[#all + 1] = { def.Id, def.Slot.Pad }
	end
	all[#all + 1] = { PRESTIGE_PAD.Id, PRESTIGE_PAD.Slot.Pad }
	for _, item in ipairs(all) do
		local r = padRect(item[2])
		local ok = false
		for ix = 1, n do
			local x = cellCentre(ix)
			if x > r[1] and x < r[2] then
				for iz = 1, n do
					local z = cellCentre(iz)
					if z > r[3] and z < r[4] and seen[(ix - 1) * n + iz] then
						ok = true
						break
					end
				end
			end
			if ok then
				break
			end
		end
		reachable[item[1]] = ok
	end
	return reachable, n
end

function TycoonCatalog.Validate()
	local problems = {}
	local function bad(msg)
		problems[#problems + 1] = msg
	end
	local kindSet = {}
	for _, k in ipairs(TycoonCatalog.Kinds) do
		kindSet[k] = true
	end
	local contractIds = {
		"Press1", "Press2", "Press3", "Press4", "Collector", "Garden", "Kitchen", "Gym", "Vault", "House",
		"FusionMachine", "ArenaGate", "DecorLamps", "DecorFence", "DecorFlowers", "DecorFountain", "DecorBanners", "DecorPodium",
	}
	for _, id in ipairs(contractIds) do
		if not BY_ID[id] then
			bad("missing station " .. id)
		end
	end
	if #STATIONS ~= #contractIds then
		bad("expected " .. #contractIds .. " stations, found " .. #STATIONS)
	end
	if #TIERS ~= 4 then
		bad("expected 4 house tiers")
	end

	local seen = {}
	for _, def in ipairs(STATIONS) do
		local id = tostring(def.Id)
		if seen[id] then
			bad("duplicate station id " .. id)
		end
		seen[id] = true
		if type(def.Name) ~= "string" or def.Name == "" then
			bad(id .. ": missing Name")
		end
		if not kindSet[def.Kind] then
			bad(id .. ": unknown Kind " .. tostring(def.Kind))
		end
		if type(def.Icon) ~= "string" or def.Icon == "" then
			bad(id .. ": missing Icon")
		end
		local maxLevel = int(def.MaxLevel)
		if not maxLevel or maxLevel < 1 or maxLevel ~= def.MaxLevel then
			bad(id .. ": MaxLevel must be a whole number >= 1")
			maxLevel = 0
		end
		-- prices: whole, >= 0, rising
		local last = -1
		for lv = 1, maxLevel do
			local p = def.Price[lv]
			if type(p) ~= "number" or p < 0 or p ~= floor(p) then
				bad(id .. ": Price[" .. lv .. "] must be a whole number >= 0")
			elseif p < last or (p == last and p > 0) then
				bad(id .. ": Price[" .. lv .. "] must be higher than the level before")
			else
				last = p
			end
			if type(def.Effects[lv]) ~= "table" then
				bad(id .. ": Effects[" .. lv .. "] missing")
			end
		end
		if def.Price[maxLevel + 1] ~= nil or def.Effects[maxLevel + 1] ~= nil then
			bad(id .. ": Price / Effects go past MaxLevel")
		end
		-- per-kind effects
		for lv = 1, maxLevel do
			local e = def.Effects[lv] or {}
			local prev = def.Effects[lv - 1]
			if def.Kind == "Press" then
				if type(e.Income) ~= "number" or e.Income <= 0 or (prev and e.Income <= prev.Income) then
					bad(id .. ": Effects[" .. lv .. "].Income must be positive and rising")
				end
			elseif def.Kind == "Garden" or def.Kind == "Gym" or def.Kind == "Kitchen" then
				if int(e.Slots) == nil or e.Slots < 1 or (prev and e.Slots < prev.Slots) then
					bad(id .. ": Effects[" .. lv .. "].Slots must be >= 1 and never drop")
				end
			end
		end
		-- tier caps: 0..MaxLevel, never dropping, the Sky Castle allows MaxLevel
		local lastCap = 0
		for _, tier in ipairs(TIERS) do
			local c = def.TierCaps[tier.Id]
			if type(c) ~= "number" or c < 0 or c > maxLevel or c ~= floor(c) then
				bad(id .. ": TierCaps." .. tier.Id .. " must be a whole number in 0.." .. maxLevel)
			elseif c < lastCap then
				bad(id .. ": TierCaps drop at " .. tier.Id)
			else
				lastCap = c
			end
		end
		if def.TierCaps.SkyCastle ~= maxLevel then
			bad(id .. ": the Sky Castle must allow MaxLevel")
		end
		-- requirement keys
		for key, need in pairs(def.Requires) do
			if key == "HomeLevel" or key == "Prestige" then
				if int(need) == nil or need < 0 then
					bad(id .. ": Requires." .. key .. " must be a whole number")
				end
			elseif key == "House" then
				if not tierIndexOf(need) then
					bad(id .. ": Requires.House must be a house tier id")
				end
			elseif BY_ID[key] then
				if key == id then
					bad(id .. ": requires itself")
				elseif int(need) == nil or need < 1 or need > BY_ID[key].MaxLevel then
					bad(id .. ": Requires." .. key .. " out of range")
				end
			else
				bad(id .. ": unknown requirement " .. tostring(key))
			end
		end
		-- slot
		local slot = def.Slot
		local slotOk = type(slot) == "table" and typeof(slot.CFrame) == "CFrame" and typeof(slot.Footprint) == "Vector3"
		if not slotOk or typeof(slot.Pad) ~= "CFrame" then
			bad(id .. ": Slot needs CFrame, Footprint and Pad")
		end
	end

	-- the House levels follow the tiers
	local house = BY_ID.House
	if house then
		for i, tier in ipairs(TIERS) do
			if house.Effects[i] and house.Effects[i].Tier ~= tier.Id then
				bad("House.Effects[" .. i .. "].Tier must be " .. tier.Id)
			end
			if i >= 2 then
				local lr = house.LevelRequires[i]
				if type(lr) ~= "table" or lr.HomeLevel ~= tier.HomeLevel then
					bad("House level " .. i .. " must need Home Level " .. tier.HomeLevel)
				end
			end
		end
	end
	local lastHL = -1
	for _, tier in ipairs(TIERS) do
		if type(tier.HomeLevel) ~= "number" or tier.HomeLevel <= lastHL then
			bad("HouseTiers HomeLevel must rise")
		end
		lastHL = tier.HomeLevel or lastHL
	end

	-- no dead ends: buying every unlocked pad (cheapest first, cash unlimited) reaches the Sky Castle, Home Level
	-- 40 and the prestige; with 1 star, every station but the "Coming soon" ones reaches MaxLevel
	local function buildOut(stars)
		local home = { Stations = {}, Prestige = stars }
		for _ = 1, 400 do
			local best = nil
			for _, pad in ipairs(TycoonCatalog.AvailablePads(home)) do
				if not pad.Locked and not pad.Prestige and (not best or pad.Price < best.Price) then
					best = pad
				end
			end
			if not best then
				break
			end
			home.Stations[best.StationId] = best.NextLevel
		end
		return home
	end
	local first = buildOut(0)
	local okPrestige, why = TycoonCatalog.CanPrestige(first)
	if not okPrestige then
		bad("dead end: a fresh home cannot reach the prestige (" .. tostring(why) .. ")")
	end
	local later = buildOut(1)
	for _, def in ipairs(STATIONS) do
		if not def.ComingSoon and levelOf(later, def.Id) < def.MaxLevel then
			bad("dead end: " .. def.Id .. " stops at level " .. levelOf(later, def.Id) .. " of " .. def.MaxLevel)
		end
	end
	-- each tier's caps allow enough Home Level for the next tier (else the house could never be upgraded)
	for i = 1, #TIERS - 1 do
		local total = 0
		for _, def in ipairs(STATIONS) do
			if not def.ComingSoon and not (def.Requires.Prestige and def.Requires.Prestige > 0) then
				total = total + (def.TierCaps[TIERS[i].Id] or 0)
			end
		end
		if total < TIERS[i + 1].HomeLevel then
			local nextTier = TIERS[i + 1]
			bad(TIERS[i].Id .. " caps add up to Home Level " .. total .. ", below the " .. nextTier.Id .. "'s " .. nextTier.HomeLevel)
		end
	end

	-- foods
	local lastXp = 0
	for i, f in ipairs(TycoonCatalog.Foods) do
		if type(f.Id) ~= "string" or type(f.Name) ~= "string" then
			bad("Foods[" .. i .. "] needs Id and Name")
		end
		for _, k in ipairs({ "Price", "Xp", "CookSeconds", "KitchenLevel" }) do
			if type(f[k]) ~= "number" or f[k] <= 0 then
				bad("Foods[" .. i .. "]." .. k .. " must be positive")
			end
		end
		if type(f.KitchenLevel) == "number" and BY_ID.Kitchen and f.KitchenLevel > BY_ID.Kitchen.MaxLevel then
			bad("Foods[" .. i .. "] needs a Kitchen level that does not exist")
		end
		if type(f.Xp) == "number" and f.Xp <= lastXp then
			bad("Foods: better food must give more XP")
		end
		lastXp = tonumber(f.Xp) or lastXp
	end
	for _, id in ipairs({ "Snack", "Meal", "Feast" }) do
		if not FOOD_BY_ID[id] then
			bad("missing food " .. id)
		end
	end

	-- XP curve
	local px = TycoonCatalog.PetXp
	local prev = 0
	for lv = 1, px.MaxLevel - 1 do
		local x = TycoonCatalog.XpToNext(lv)
		if type(x) ~= "number" or x < prev or x <= 0 or x == huge then
			bad("XpToNext(" .. lv .. ") must be positive and never drop")
			break
		end
		prev = x
	end
	if TycoonCatalog.XpToNext(px.MaxLevel) ~= huge then
		bad("XpToNext(MaxLevel) must be math.huge")
	end

	-- fusion costs for every rarity
	for _, r in ipairs(Config.Rarities or {}) do
		local up = TycoonCatalog.Fusion.Upgrade[r.Id]
		if type(up) ~= "table" or type(up.Golden) ~= "table" or type(up.Rainbow) ~= "table" then
			bad("Fusion.Upgrade." .. tostring(r.Id) .. " needs Golden and Rainbow")
		end
		local mix = TycoonCatalog.Fusion.Mix[r.Id]
		if type(mix) ~= "table" or (type(mix.Tokens) ~= "number" and type(mix.Gems) ~= "number") then
			bad("Fusion.Mix." .. tostring(r.Id) .. " needs Tokens or Gems")
		end
	end

	-- prestige
	local p = TycoonCatalog.Prestige
	if not tierIndexOf(p.House) then
		bad("Prestige.House must be a house tier")
	end
	if type(p.IncomeMultiplier) ~= "number" or p.IncomeMultiplier <= 1 then
		bad("Prestige.IncomeMultiplier must be above 1")
	end
	if type(p.GemReward) ~= "number" or p.GemReward < 0 then
		bad("Prestige.GemReward must be >= 0")
	end

	-- layout: inside the yard, no overlaps between stations / pads, every pad reachable from the gate
	local margin = TycoonCatalog.Layout.Margin
	local rects = {}
	for _, def in ipairs(STATIONS) do
		local slot = def.Slot
		local slotOk = type(slot) == "table" and typeof(slot.CFrame) == "CFrame" and typeof(slot.Footprint) == "Vector3"
		if slotOk and typeof(slot.Pad) == "CFrame" then
			local r = footprintRect(slot.CFrame, slot.Footprint)
			local limit = HALF - margin
			local outside = r[1] < -HALF or r[2] > HALF or r[3] < -HALF or r[4] > HALF
			local inMargin = r[1] < -limit or r[2] > limit or r[3] < -limit or r[4] > limit
			-- the fence decor follows the fence line; other decor may line the fence; stations keep the margin
			if not slot.Perimeter and (outside or (def.Kind ~= "Decor" and inMargin)) then
				bad(def.Id .. ": footprint leaves the yard")
			end
			local pr = padRect(slot.Pad)
			if pr[1] < -HALF or pr[2] > HALF or pr[3] < -HALF or pr[4] > HALF then
				bad(def.Id .. ": pad outside the yard")
			end
			rects[#rects + 1] = { Id = def.Id, R = r, Pad = pr, Walk = slot.Walkable or slot.Perimeter }
		end
	end
	local pp = padRect(PRESTIGE_PAD.Slot.Pad)
	rects[#rects + 1] = { Id = "Prestige", R = nil, Pad = pp, Walk = true }
	for i = 1, #rects do
		local a = rects[i]
		for j = i + 1, #rects do
			local b = rects[j]
			if a.R and b.R and not a.Walk and not b.Walk and overlap(a.R, b.R) then
				bad("slots overlap: " .. a.Id .. " and " .. b.Id)
			end
			if overlap(a.Pad, b.Pad, 0.5) then
				bad("pads too close: " .. a.Id .. " and " .. b.Id)
			end
		end
		for j = 1, #rects do
			local b = rects[j]
			if b.R and not b.Walk and overlap(a.Pad, b.R) then
				bad("pad of " .. a.Id .. " overlaps " .. b.Id)
			end
		end
	end
	local reach = TycoonCatalog.ReachablePads(1, 1)
	for id, ok in pairs(reach) do
		if not ok then
			bad("pad of " .. id .. " cannot be reached from the gate")
		end
	end
	return #problems == 0, problems
end

return TycoonCatalog
