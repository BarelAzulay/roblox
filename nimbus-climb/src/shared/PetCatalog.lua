-- PetCatalog: every collectible winged pet in Nimbus Climb, plus the pure logic around them
-- (roulette rolling, odds, perk maths, v3 roles / stats / specials and the Pet Index groups).
-- Pure data + logic: no Instances, safe on server and client. Plain Lua 5.1-compatible syntax only.
--
-- API (contract in ARCHITECTURE_V2.md section 2 and ARCHITECTURE_V3.md section 2):
--   PetCatalog.Species                    array of species names PetBuilder understands
--   PetCatalog.Pets                       array of PetDef, sorted by rarity order, then Name (a Signature pet
--                                         leads its rarity)
--   PetCatalog.ById                       map id -> PetDef
--   PetCatalog.Get(id)                    -> PetDef|nil
--   PetCatalog.ListByRarity(rarityId)     -> { PetDef... } (same order as Pets)
--   PetCatalog.GetRarity(rarityId)        -> { Id, Order, Color }|nil          (from Config.Rarities)
--   PetCatalog.RollPet(rouletteId, rng)   -> petId|nil   weighted rarity (Roulette.Odds), then uniform pet
--   PetCatalog.GetOdds(rouletteId)        -> { { PetId, Rarity, Chance }... }  Chance sums to 1
--   PetCatalog.PossiblePets(rouletteId)   -> { PetDef... }
--   PetCatalog.PerkLabel(perkType, value) -> "+12% Max Health"
--   PetCatalog.SumPerks(petIds)           -> { MaxHealth, TokenBonus, StaminaRegen, CheckpointHeal } (capped)
--   v3:
--   PetCatalog.IndexGroups()              -> { { Id, Rarity, Pets = {PetDef...}, Reward = {Tokens = n} }... }
--                                            one group per rarity that has pets, in rarity order (Secret last)
--   PetCatalog.GetStats(petId, level, tier) -> { Income, Power, Health, Speed } | nil   (Phase 2: tier added)
--                                            base * Config.PetStats.RarityScale[rarity] * (1 + 0.1 * (level - 1))
--                                            * tier multiplier (Normal 1, Golden 1.5, Rainbow 2.5). The same numbers
--                                            as TycoonCatalog.PetIncome, so the Income shown is the Cash/s the Garden
--                                            pays (prestige not applied). petId may also be a pet key ("cat@Golden":
--                                            the tier comes from the key unless `tier` is given) or a def table
--                                            (PetKeys.DefOf: tier copies and fused hybrids). level defaults to 1 and
--                                            is clamped to 1..MaxPetLevel(); tier also takes a key or a multiplier.
--   PetCatalog.TotalCount()               -> number of pets in the catalog (Secret pets included)
--   Phase 2 pet levels (care agent; the XP curve itself is TycoonCatalog.XpToNext):
--   PetCatalog.LevelCap(subject)          -> the highest level feeding / the Gym can raise a pet to, by rarity
--                                            (subject = rarity id, pet id, pet key or def): Common 20, Uncommon 25,
--                                            Rare 30, Epic 35, Legendary 40, Mythic 45, Secret 50. TycoonCatalog may
--                                            override them (PetXp.RarityCaps / PetLevelCaps); never above
--                                            MaxPetLevel(). nil for unknown pets.
--   PetCatalog.MaxPetLevel()              -> top of the XP curve (TycoonCatalog.MaxPetLevel, else MaxLevel = 50)
--   PetCatalog.LevelFactor(level)         -> 1 + 0.1 * (level - 1)   (level clamped like GetStats)
--   PetCatalog.TierMultiplier(tier)       -> 1 | 1.5 | 2.5 (a tier name, a pet key, a def or a multiplier)
--   v3 elements (ARCHITECTURE_V3.md section 11, chart in Config.Elements):
--   PetCatalog.ElementsOf(def)            -> { element... }  a pet's Element, or a fused hybrid's Elements
--                                            (deduplicated, only names from Config.Elements.Order; {} otherwise)
--   PetCatalog.GetElements(petId)         -> { element... }  ElementsOf(Get(petId)); {} for unknown pets
--   PetCatalog.ElementMultiplier(attackElement, defendElement) -> number
--                                            StrongMultiplier (1.5) when the attacker beats the defender,
--                                            WeakMultiplier (0.75) when the defender beats the attacker, else 1.
--                                            Either side may also be a list (a dual-element hybrid): the attacker
--                                            uses its best element, a dual defender combines both matchups
--                                            (clamped to weak .. strong). Unknown / nil elements count as x1.
-- Extras (nothing depends on them): PerkOrder, PerkNames, Accessories, WingStyles, Roles, RoleBlurbs,
--   StatOrder, StatNames, SpecialKinds, GetRarityOdds, PerkLines, GetIndexGroup, IsRollable, Validate.
--
-- PetDef v3 fields (every pet has them):
--   Role    = "Economy" | "Combat". Economy pets earn Cash at home (phase 2): high Income, low Power/Health.
--             Combat pets fight in the arena (phase 3): high Power/Health, low Income. Roughly half of each per rarity.
--   Stats   = { Income, Power, Health, Speed }: BASE values at rarity scale 1. Income = Cash per second while
--             working at home, Power = damage per hit, Health = hit points, Speed = attack tempo rating.
--   Special = { Id, Name, Kind, Power, Color }: the pet's special attack. Kind decides the effect
--             (Blast / Pounce / Beam / Storm / Freeze deal damage, Freeze also slows, Heal restores HP,
--             Shield absorbs damage); Power is its base strength at rarity scale 1 (scale it like Stats);
--             Color tints the effect.
--   Element = one of Config.Elements.Order, chosen by species, look and theme (Phoenix / flame looks -> Flame,
--             Penguin / icy -> Frost, Frog / Axolotl / watery -> Water, Bunny / Panda / leafy -> Nature,
--             Bear / Dog / earthy -> Earth, Owl / electric / windy sky pets -> Storm, Unicorn / halo -> Celestial,
--             dark Secrets -> Shadow). Every element has at least 3 pets across several rarities.
--   Signature = true (optional): the player's own creature (Stormfang); it leads its rarity in every list.
--
-- Secret pets (Rarity "Secret") come only from a roulette that sets `AllowSecret = true` (the gems-only Secret
-- roulette of phase 2). No current roulette does, so RollPet / GetOdds / PossiblePets never offer them.
--
-- Perk strength scales with rarity (Common ~2-4%, Mythic ~10-25%, Secret a step above Mythic). Pets never touch
-- run speed or jump power, so the course physics guarantees keep holding.

local Config = require(script.Parent.Config)

local PetCatalog = {}

PetCatalog.Species = {
	"Cat", "Dog", "Fox", "Bunny", "Bear", "Panda", "Dragon",
	"Owl", "Slime", "Unicorn", "Phoenix", "Frog", "Penguin", "Axolotl",
	"Stormfang", -- the player's own armoured storm lynx (ARCHITECTURE_V3.md section 10)
}

-- Values PetBuilder supports for the optional / enumerated Look fields.
PetCatalog.Accessories = { "Horns", "Crown", "Halo", "Leaf", "Mushroom", "Scarf", "Antlers", "Flower" }
PetCatalog.WingStyles = { "Feather", "Bat", "Fairy", "Cloud", "Crystal", "Flame", "StormCloud" } -- StormCloud: Stormfang's ride

-- Perk display order + player-facing names (keys match Config.Pets.PerkCaps).
PetCatalog.PerkOrder = { "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }
PetCatalog.PerkNames = {
	MaxHealth = "Max Health",
	TokenBonus = "Cloud Tokens",
	StaminaRegen = "Stamina Regen",
	CheckpointHeal = "Checkpoint Heal",
}

-- v3: roles, stats and special kinds (display order + player-facing names).
PetCatalog.Roles = { "Economy", "Combat" }
PetCatalog.RoleBlurbs = {
	Economy = "Works at your home and earns Cash.",
	Combat = "Fights in the arena with strong attacks.",
}
PetCatalog.StatOrder = { "Income", "Power", "Health", "Speed" }
PetCatalog.StatNames = { Income = "Income", Power = "Power", Health = "Health", Speed = "Speed" }
PetCatalog.SpecialKinds = { "Blast", "Heal", "Shield", "Storm", "Pounce", "Freeze", "Beam" }

local SECRET = "Secret"

local function C(r, g, b)
	return Color3.fromRGB(r, g, b)
end

-- Compact constructors for the v3 data (keeps the lineup readable).
local function Stats(income, power, health, speed)
	return { Income = income, Power = power, Health = health, Speed = speed }
end

local function Special(id, name, kind, power, color)
	return { Id = id, Name = name, Kind = kind, Power = power, Color = color }
end

----------------------------------------------------------------------
-- The lineup. Palettes are calm and slightly dusty (nothing blinding); the rarer the pet, the more
-- it glows. Wing colours are chosen to read against the sky, not to match the body exactly.
-- Stat bands at rarity scale 1:
--   Economy  Income 9-12, Power 2-4,  Health 24-36, Speed 7-13
--   Combat   Income 2-3,  Power 8-12, Health 50-72, Speed 7-14
-- Within a band the species decides the shape (bears/pandas tank, foxes/cats are quick, dragons hit hard).
----------------------------------------------------------------------
local RAW = {
	------------------------------------------------------------ Common (6): 3 Economy, 3 Combat
	{
		Id = "pebble_pup", Name = "Pebble Pup", Rarity = "Common",
		Blurb = "A loyal little pup who fetches stray cloud tokens for you.",
		Look = {
			Species = "Dog", Primary = C(190, 154, 114), Secondary = C(238, 222, 196), Eye = C(50, 36, 32),
			Glow = false, WingStyle = "Feather", WingColor = C(226, 208, 182),
		},
		Perks = { TokenBonus = 0.03 },
		Element = "Earth",
		Role = "Economy",
		Stats = Stats(10, 3, 28, 11),
		Special = Special("fetch_dash", "Fetch Dash", "Pounce", 22, C(236, 196, 128)),
	},
	{
		Id = "mallow_kitten", Name = "Mallow Kitten", Rarity = "Common",
		Blurb = "Soft as a marshmallow and twice as sweet. Purrs after every jump.",
		Look = {
			Species = "Cat", Primary = C(236, 218, 212), Secondary = C(240, 170, 182), Eye = C(66, 46, 74),
			Glow = false, WingStyle = "Fairy", WingColor = C(244, 200, 214),
		},
		Perks = { MaxHealth = 0.03 },
		Element = "Celestial",
		Role = "Combat",
		Stats = Stats(2, 9, 52, 13),
		Special = Special("marshmallow_pounce", "Marshmallow Pounce", "Pounce", 34, C(244, 186, 204)),
	},
	{
		Id = "puddle_frog", Name = "Puddle Frog", Rarity = "Common",
		Blurb = "Hops from puddle to puddle, wearing a lily pad as a hat.",
		Look = {
			Species = "Frog", Primary = C(128, 190, 120), Secondary = C(214, 232, 164), Eye = C(30, 52, 38),
			Glow = false, Accessory = "Leaf", WingStyle = "Fairy", WingColor = C(170, 222, 190),
		},
		Perks = { StaminaRegen = 0.04 },
		Element = "Water",
		Role = "Combat",
		Stats = Stats(2, 10, 50, 12),
		Special = Special("puddle_splash", "Puddle Splash", "Blast", 30, C(120, 196, 232)),
	},
	{
		Id = "honey_bunny", Name = "Honey Bunny", Rarity = "Common",
		Blurb = "Sweet as honey and always the first to spot a shiny token.",
		Look = {
			Species = "Bunny", Primary = C(240, 202, 146), Secondary = C(248, 232, 204), Eye = C(76, 48, 36),
			Glow = false, WingStyle = "Feather", WingColor = C(244, 220, 172),
		},
		Perks = { CheckpointHeal = 0.04 },
		Element = "Nature",
		Role = "Economy",
		Stats = Stats(11, 2, 24, 13),
		Special = Special("honey_hug", "Honey Hug", "Heal", 26, C(246, 196, 92)),
	},
	{
		Id = "biscuit_bear", Name = "Biscuit Bear", Rarity = "Common",
		Blurb = "A cuddly bear in a cosy scarf. Warm paws, warmer heart.",
		Look = {
			Species = "Bear", Primary = C(172, 120, 82), Secondary = C(224, 188, 148), Eye = C(44, 30, 26),
			Glow = false, Accessory = "Scarf", WingStyle = "Feather", WingColor = C(210, 170, 128),
		},
		Perks = { MaxHealth = 0.04 },
		Element = "Earth",
		Role = "Combat",
		Stats = Stats(3, 8, 70, 7),
		Special = Special("cosy_guard", "Cosy Guard", "Shield", 36, C(220, 156, 100)),
	},
	{
		Id = "pip_penguin", Name = "Pip Penguin", Rarity = "Common",
		Blurb = "Waddles through the air, which is the funniest thing you will see all day.",
		Look = {
			Species = "Penguin", Primary = C(60, 74, 108), Secondary = C(226, 232, 240), Eye = C(22, 28, 44),
			Glow = false, WingStyle = "Feather", WingColor = C(92, 112, 152),
		},
		Perks = { TokenBonus = 0.02, StaminaRegen = 0.02 },
		Element = "Frost",
		Role = "Economy",
		Stats = Stats(9, 3, 30, 9),
		Special = Special("snowball_toss", "Snowball Toss", "Freeze", 16, C(186, 220, 250)),
	},

	------------------------------------------------------------ Uncommon (6): 3 Economy, 3 Combat
	{
		Id = "maple_fox", Name = "Maple Fox", Rarity = "Uncommon",
		Blurb = "Smells of autumn leaves and always lands on its feet.",
		Look = {
			Species = "Fox", Primary = C(222, 128, 64), Secondary = C(244, 228, 204), Eye = C(52, 32, 24),
			Glow = false, Accessory = "Leaf", WingStyle = "Feather", WingColor = C(234, 160, 90),
		},
		Perks = { TokenBonus = 0.06 },
		Element = "Flame",
		Role = "Combat",
		Stats = Stats(2, 11, 50, 14),
		Special = Special("leaf_pounce", "Leaf Pounce", "Pounce", 38, C(232, 134, 60)),
	},
	{
		Id = "bamboo_panda", Name = "Bamboo Panda", Rarity = "Uncommon",
		Blurb = "Chews a bamboo leaf between flaps. Surprisingly tough.",
		Look = {
			Species = "Panda", Primary = C(232, 232, 224), Secondary = C(46, 50, 58), Eye = C(24, 26, 32),
			Glow = false, Accessory = "Leaf", WingStyle = "Feather", WingColor = C(206, 224, 204),
		},
		Perks = { MaxHealth = 0.06 },
		Element = "Nature",
		Role = "Combat",
		Stats = Stats(3, 9, 68, 7),
		Special = Special("bamboo_bash", "Bamboo Bash", "Blast", 32, C(140, 200, 110)),
	},
	{
		Id = "mochi_slime", Name = "Mochi Slime", Rarity = "Uncommon",
		Blurb = "Squishy, bouncy and slightly sticky. Everyone wants a squeeze.",
		Look = {
			Species = "Slime", Primary = C(240, 170, 196), Secondary = C(248, 214, 228), Eye = C(72, 38, 62),
			Glow = false, Accessory = "Flower", WingStyle = "Fairy", WingColor = C(248, 200, 222),
		},
		Perks = { CheckpointHeal = 0.08 },
		Element = "Water",
		Role = "Economy",
		Stats = Stats(11, 2, 32, 7),
		Special = Special("sticky_bounce", "Sticky Bounce", "Shield", 30, C(246, 170, 200)),
	},
	{
		Id = "sleepy_owl", Name = "Sleepy Owl", Rarity = "Uncommon",
		Blurb = "Yawns constantly, yet never misses a single token.",
		Look = {
			Species = "Owl", Primary = C(148, 118, 94), Secondary = C(228, 208, 176), Eye = C(74, 50, 26),
			Glow = false, WingStyle = "Feather", WingColor = C(176, 144, 112),
		},
		Perks = { StaminaRegen = 0.08 },
		Element = "Storm",
		Role = "Economy",
		Stats = Stats(10, 3, 26, 11),
		Special = Special("drowsy_lullaby", "Drowsy Lullaby", "Freeze", 18, C(190, 170, 230)),
	},
	{
		Id = "waffle_corgi", Name = "Waffle Corgi", Rarity = "Uncommon",
		Blurb = "A fluffy-bottomed corgi with a sunny flower on its head.",
		Look = {
			Species = "Dog", Primary = C(230, 168, 90), Secondary = C(246, 234, 216), Eye = C(52, 36, 28),
			Glow = false, Accessory = "Flower", WingStyle = "Feather", WingColor = C(242, 204, 138),
		},
		Perks = { TokenBonus = 0.04, MaxHealth = 0.03 },
		Element = "Earth",
		Role = "Economy",
		Stats = Stats(12, 3, 28, 10),
		Special = Special("sunny_bark", "Sunny Bark", "Heal", 24, C(250, 212, 96)),
	},
	{
		Id = "bubble_axolotl", Name = "Bubble Axolotl", Rarity = "Uncommon",
		Blurb = "Blows tiny bubbles that pop into sparkles. Always smiling.",
		Look = {
			Species = "Axolotl", Primary = C(244, 184, 198), Secondary = C(238, 142, 164), Eye = C(62, 36, 58),
			Glow = false, WingStyle = "Fairy", WingColor = C(170, 218, 232),
		},
		Perks = { StaminaRegen = 0.05, CheckpointHeal = 0.05 },
		Element = "Water",
		Role = "Combat",
		Stats = Stats(3, 8, 56, 9),
		Special = Special("bubble_barrier", "Bubble Barrier", "Shield", 34, C(150, 220, 240)),
	},

	------------------------------------------------------------ Rare (5): 3 Economy, 2 Combat
	{
		Id = "blossom_bunny", Name = "Blossom Bunny", Rarity = "Rare",
		Blurb = "Spring follows wherever this bunny hops. Petals trail from its wings.",
		Look = {
			Species = "Bunny", Primary = C(232, 196, 224), Secondary = C(246, 228, 240), Eye = C(72, 40, 90),
			Glow = false, Accessory = "Flower", WingStyle = "Fairy", WingColor = C(240, 186, 220),
		},
		Perks = { TokenBonus = 0.08, CheckpointHeal = 0.06 },
		Element = "Nature",
		Role = "Economy",
		Stats = Stats(12, 3, 26, 13),
		Special = Special("petal_breeze", "Petal Breeze", "Heal", 28, C(244, 170, 210)),
	},
	{
		Id = "shroomie_frog", Name = "Shroomie Frog", Rarity = "Rare",
		Blurb = "Wears a spotted mushroom cap and hums mossy lullabies.",
		Look = {
			Species = "Frog", Primary = C(92, 164, 124), Secondary = C(236, 224, 192), Eye = C(26, 44, 34),
			Glow = false, Accessory = "Mushroom", WingStyle = "Fairy", WingColor = C(226, 148, 148),
		},
		Perks = { CheckpointHeal = 0.12, MaxHealth = 0.04 },
		Element = "Nature",
		Role = "Economy",
		Stats = Stats(11, 3, 30, 11),
		Special = Special("spore_cloud", "Spore Cloud", "Storm", 18, C(176, 214, 132)),
	},
	{
		Id = "frostling_penguin", Name = "Frostling Penguin", Rarity = "Rare",
		Blurb = "A tiny ice-winged penguin who leaves snowflakes in the air.",
		Look = {
			Species = "Penguin", Primary = C(118, 176, 224), Secondary = C(222, 238, 246), Eye = C(24, 40, 80),
			Glow = false, Accessory = "Scarf", WingStyle = "Crystal", WingColor = C(166, 216, 242),
		},
		Perks = { MaxHealth = 0.08, StaminaRegen = 0.08 },
		Element = "Frost",
		Role = "Combat",
		Stats = Stats(2, 10, 62, 9),
		Special = Special("snow_burst", "Snow Burst", "Freeze", 22, C(170, 224, 250)),
	},
	{
		Id = "storm_tabby", Name = "Storm Tabby", Rarity = "Rare",
		Blurb = "Crackles with static when happy. Not scared of thunder. Mostly.",
		Look = {
			Species = "Cat", Primary = C(108, 116, 148), Secondary = C(190, 198, 222), Eye = C(36, 42, 70),
			Glow = false, WingStyle = "Bat", WingColor = C(80, 88, 122),
		},
		Perks = { StaminaRegen = 0.12, TokenBonus = 0.05 },
		Element = "Storm",
		Role = "Combat",
		Stats = Stats(3, 12, 50, 13),
		Special = Special("static_storm", "Static Storm", "Storm", 24, C(150, 170, 255)),
	},
	{
		Id = "cherry_panda", Name = "Cherry Panda", Rarity = "Rare",
		Blurb = "Cherry blossoms drift off its fur wherever it goes.",
		Look = {
			Species = "Panda", Primary = C(238, 222, 224), Secondary = C(74, 52, 66), Eye = C(38, 24, 38),
			Glow = false, Accessory = "Flower", WingStyle = "Feather", WingColor = C(244, 192, 204),
		},
		Perks = { MaxHealth = 0.09, TokenBonus = 0.07 },
		Element = "Nature",
		Role = "Economy",
		Stats = Stats(10, 4, 34, 8),
		Special = Special("blossom_rain", "Blossom Rain", "Heal", 30, C(246, 182, 200)),
	},

	------------------------------------------------------------ Epic (4): 2 Economy, 2 Combat
	{
		Id = "aurora_fox", Name = "Aurora Fox", Rarity = "Epic",
		Blurb = "Antlers shimmering with northern lights. Leaves a glowing trail at dusk.",
		Look = {
			Species = "Fox", Primary = C(116, 192, 198), Secondary = C(176, 146, 224), Eye = C(150, 236, 220),
			Glow = true, Accessory = "Antlers", WingStyle = "Crystal", WingColor = C(148, 212, 226),
		},
		Perks = { TokenBonus = 0.14, StaminaRegen = 0.08 },
		Element = "Frost",
		Role = "Combat",
		Stats = Stats(3, 11, 56, 14),
		Special = Special("aurora_beam", "Aurora Beam", "Beam", 42, C(130, 230, 210)),
	},
	{
		Id = "moonlit_owl", Name = "Moonlit Owl", Rarity = "Epic",
		Blurb = "Watches over sleepy climbers from beneath its own little moon.",
		Look = {
			Species = "Owl", Primary = C(72, 84, 140), Secondary = C(214, 208, 240), Eye = C(255, 224, 128),
			Glow = true, Accessory = "Halo", WingStyle = "Feather", WingColor = C(112, 126, 196),
		},
		Perks = { MaxHealth = 0.10, CheckpointHeal = 0.15 },
		Element = "Celestial",
		Role = "Combat",
		Stats = Stats(2, 10, 64, 11),
		Special = Special("moonlight_ward", "Moonlight Ward", "Shield", 40, C(222, 214, 255)),
	},
	{
		Id = "nebula_axolotl", Name = "Nebula Axolotl", Rarity = "Epic",
		Blurb = "Swims through the sky as if it were a pond full of stardust.",
		Look = {
			Species = "Axolotl", Primary = C(118, 104, 198), Secondary = C(232, 128, 186), Eye = C(156, 238, 250),
			Glow = true, WingStyle = "Cloud", WingColor = C(150, 128, 224),
		},
		Perks = { StaminaRegen = 0.14, CheckpointHeal = 0.12 },
		Element = "Water",
		Role = "Economy",
		Stats = Stats(12, 3, 30, 9),
		Special = Special("stardust_swirl", "Stardust Swirl", "Storm", 20, C(176, 146, 244)),
	},
	{
		Id = "candy_unicorn", Name = "Candy Unicorn", Rarity = "Epic",
		Blurb = "Sprinkle-swirl mane, sugar-spun horn and not a single worry.",
		Look = {
			Species = "Unicorn", Primary = C(244, 204, 224), Secondary = C(166, 210, 244), Eye = C(98, 50, 122),
			Glow = false, Accessory = "Flower", WingStyle = "Feather", WingColor = C(246, 222, 236),
		},
		Perks = { TokenBonus = 0.12, MaxHealth = 0.08 },
		Element = "Celestial",
		Role = "Economy",
		Stats = Stats(12, 4, 30, 11),
		Special = Special("sugar_rush", "Sugar Rush", "Heal", 30, C(246, 170, 214)),
	},

	------------------------------------------------------------ Legendary (3): 1 Economy, 2 Combat
	{
		Id = "ember_phoenix", Name = "Ember Phoenix", Rarity = "Legendary",
		Blurb = "Rises from every fall, just like you. Warm as a campfire.",
		Look = {
			Species = "Phoenix", Primary = C(222, 100, 58), Secondary = C(248, 196, 96), Eye = C(255, 214, 120),
			Glow = true, WingStyle = "Flame", WingColor = C(244, 138, 54),
		},
		Perks = { CheckpointHeal = 0.22, MaxHealth = 0.10 },
		Element = "Flame",
		Role = "Combat",
		Stats = Stats(3, 12, 60, 13),
		Special = Special("phoenix_flare", "Phoenix Flare", "Blast", 44, C(255, 140, 60)),
	},
	{
		Id = "sunbeam_bear", Name = "Sunbeam Bear", Rarity = "Legendary",
		Blurb = "The honey-gold king of the cloud meadow. Bowing is optional.",
		Look = {
			Species = "Bear", Primary = C(232, 186, 92), Secondary = C(246, 228, 168), Eye = C(255, 230, 140),
			Glow = true, Accessory = "Crown", WingStyle = "Feather", WingColor = C(246, 210, 118),
		},
		Perks = { MaxHealth = 0.14, TokenBonus = 0.16 },
		Element = "Earth",
		Role = "Economy",
		Stats = Stats(12, 4, 36, 7),
		Special = Special("golden_aegis", "Golden Aegis", "Shield", 38, C(255, 210, 110)),
	},
	{
		Id = "twilight_dragon", Name = "Twilight Dragon", Rarity = "Legendary",
		Blurb = "A dusk-purple dragon that snuggles up when the sky turns pink.",
		Look = {
			Species = "Dragon", Primary = C(92, 78, 160), Secondary = C(222, 164, 206), Eye = C(255, 176, 214),
			Glow = true, Accessory = "Horns", WingStyle = "Bat", WingColor = C(126, 98, 196),
		},
		Perks = { TokenBonus = 0.20, StaminaRegen = 0.14 },
		Element = "Shadow",
		Role = "Combat",
		Stats = Stats(3, 12, 62, 11),
		Special = Special("dusk_storm", "Dusk Storm", "Storm", 28, C(176, 124, 236)),
	},

	------------------------------------------------------------ Mythic (2): 1 Economy, 1 Combat
	{
		Id = "cloudy_dragon", Name = "Cloudy Dragon", Rarity = "Mythic",
		Blurb = "The fluffy guardian of the sky. Wings of cloud, a heart of sunshine.",
		Look = {
			Species = "Dragon", Primary = C(236, 244, 255), Secondary = C(150, 196, 240), Eye = C(30, 40, 90),
			Glow = false, Accessory = "Horns", WingStyle = "Cloud", WingColor = C(200, 225, 255),
		},
		Perks = { MaxHealth = 0.12, TokenBonus = 0.25 },
		Element = "Storm",
		Role = "Combat",
		Stats = Stats(3, 12, 70, 11),
		Special = Special("cloud_breath", "Cloud Breath", "Beam", 50, C(196, 228, 255)),
	},
	{
		Id = "starlight_unicorn", Name = "Starlight Unicorn", Rarity = "Mythic",
		Blurb = "Its mane is woven from constellations. Wishes made nearby tend to come true.",
		Look = {
			Species = "Unicorn", Primary = C(226, 230, 250), Secondary = C(196, 166, 246), Eye = C(170, 208, 255),
			Glow = true, Accessory = "Halo", WingStyle = "Crystal", WingColor = C(190, 200, 250),
		},
		Perks = { CheckpointHeal = 0.25, StaminaRegen = 0.18 },
		Element = "Celestial",
		Role = "Economy",
		Stats = Stats(12, 4, 36, 12),
		Special = Special("wishing_star", "Wishing Star", "Heal", 40, C(214, 204, 255)),
	},

	------------------------------------------------------------ Secret (4): 1 Economy, 3 Combat
	-- Gems-only Secret roulette (phase 2). Dark bodies with an iridescent second colour and glowing eyes;
	-- every perk is above the best Mythic value for the same perk.
	-- Stormfang is the player's own creature (ARCHITECTURE_V3.md section 10, branding/stormfang-*.png): its own
	-- species riding its own storm cloud, the top of the Secret tier, listed first among the Secrets.
	{
		Id = "stormfang", Name = "Stormfang", Rarity = "Secret", Signature = true,
		Blurb = "A storm lynx in thunder-forged armour. It pounces in a flash of blue lightning, long before the thunder.",
		Look = {
			-- charcoal armour, electric-blue neon, glowing blue eyes, a dark navy storm cloud to ride
			Species = "Stormfang", Primary = C(42, 44, 51), Secondary = C(47, 180, 255), Eye = C(47, 180, 255),
			Glow = true, WingStyle = "StormCloud", WingColor = C(46, 58, 102),
		},
		-- the top of the Secret tier (0.50 in total), while the best 3 pets of any perk still fit its cap
		Perks = { MaxHealth = 0.18, CheckpointHeal = 0.32 },
		Element = "Storm",
		Role = "Combat",
		Stats = Stats(3, 13, 74, 15),
		Special = Special("storm_pounce", "Storm Pounce", "Pounce", 56, C(47, 180, 255)),
	},
	{
		Id = "eclipse_dragon", Name = "Eclipse Dragon", Rarity = "Secret",
		Blurb = "Born when the sun hid behind the moon. Its scales shift from violet to teal to gold.",
		Look = {
			Species = "Dragon", Primary = C(46, 36, 78), Secondary = C(104, 226, 214), Eye = C(255, 200, 96),
			Glow = true, Accessory = "Horns", WingStyle = "Bat", WingColor = C(110, 72, 196),
		},
		Perks = { MaxHealth = 0.16, CheckpointHeal = 0.30 },
		Element = "Shadow",
		Role = "Combat",
		Stats = Stats(3, 12, 72, 12),
		Special = Special("eclipse_nova", "Eclipse Nova", "Blast", 52, C(156, 96, 255)),
	},
	{
		Id = "obsidian_phoenix", Name = "Obsidian Phoenix", Rarity = "Secret",
		Blurb = "Rose from the ashes of a starless night. Its violet flames are cool to the touch.",
		Look = {
			Species = "Phoenix", Primary = C(38, 32, 52), Secondary = C(236, 96, 196), Eye = C(255, 156, 238),
			Glow = true, Accessory = "Crown", WingStyle = "Flame", WingColor = C(176, 72, 230),
		},
		Perks = { StaminaRegen = 0.20, CheckpointHeal = 0.28 },
		Element = "Flame",
		Role = "Combat",
		Stats = Stats(2, 12, 66, 14),
		Special = Special("shadowflame_storm", "Shadowflame Storm", "Storm", 34, C(222, 86, 255)),
	},
	{
		Id = "phantom_kitsune", Name = "Phantom Kitsune", Rarity = "Secret",
		Blurb = "A spirit fox that brings good fortune to whoever earns its trust. Seen only at midnight.",
		Look = {
			Species = "Fox", Primary = C(40, 44, 74), Secondary = C(160, 236, 248), Eye = C(196, 255, 236),
			Glow = true, Accessory = "Halo", WingStyle = "Fairy", WingColor = C(150, 132, 240),
		},
		Perks = { TokenBonus = 0.30, MaxHealth = 0.15 },
		Element = "Shadow",
		Role = "Economy",
		Stats = Stats(12, 4, 36, 13),
		Special = Special("foxfire_ward", "Foxfire Ward", "Shield", 44, C(124, 252, 228)),
	},
}

----------------------------------------------------------------------
-- Indexes
----------------------------------------------------------------------

-- Rarities sorted by Order (a copy: Config.Rarities itself is never reordered).
local rarityList = {}
local rarityById = {}
for _, r in ipairs(Config.Rarities) do
	table.insert(rarityList, r)
	rarityById[r.Id] = r
end
table.sort(rarityList, function(a, b)
	return a.Order < b.Order
end)

local function rarityOrder(rarityId)
	local r = rarityById[rarityId]
	if r then
		return r.Order
	end
	return 1000 -- unknown rarities sort last (Validate reports them)
end

PetCatalog.Pets = {}
PetCatalog.ById = {}
for _, def in ipairs(RAW) do
	table.insert(PetCatalog.Pets, def)
	PetCatalog.ById[def.Id] = def
end
-- rarity order, then the player's own creature (Signature) first, then Name
table.sort(PetCatalog.Pets, function(a, b)
	local oa, ob = rarityOrder(a.Rarity), rarityOrder(b.Rarity)
	if oa ~= ob then
		return oa < ob
	end
	local sa, sb = a.Signature == true, b.Signature == true
	if sa ~= sb then
		return sa
	end
	return a.Name < b.Name
end)

-- rarityId -> { PetDef... } (already in display order because Pets is)
local byRarity = {}
for _, r in ipairs(rarityList) do
	byRarity[r.Id] = {}
end
for _, def in ipairs(PetCatalog.Pets) do
	if not byRarity[def.Rarity] then
		byRarity[def.Rarity] = {}
	end
	table.insert(byRarity[def.Rarity], def)
end

----------------------------------------------------------------------
-- Lookups
----------------------------------------------------------------------

function PetCatalog.Get(id)
	if type(id) ~= "string" then
		return nil
	end
	return PetCatalog.ById[id]
end

function PetCatalog.ListByRarity(rarityId)
	local out = {}
	local list = byRarity[rarityId]
	if list then
		for i, def in ipairs(list) do
			out[i] = def
		end
	end
	return out
end

function PetCatalog.GetRarity(rarityId)
	return rarityById[rarityId]
end

function PetCatalog.TotalCount()
	return #PetCatalog.Pets
end

----------------------------------------------------------------------
-- Roulettes
----------------------------------------------------------------------

local function findRoulette(rouletteId)
	for _, r in ipairs(Config.Roulettes) do
		if r.Id == rouletteId then
			return r
		end
	end
	return nil
end

-- Secret pets only come from a roulette that opts in with AllowSecret = true (phase 2's gems-only roulette).
local function rarityAllowed(roulette, rarityId)
	if rarityId == SECRET then
		return roulette.AllowSecret == true
	end
	return true
end

-- Rarity buckets a roulette can actually produce, in rarity order:
-- { { Rarity = id, Weight = w, Pets = {PetDef...} }... }, totalWeight.
-- Rarities with weight <= 0, without any pet, or not allowed (Secret) are skipped, so Chance always sums to 1.
local function oddsEntries(rouletteId)
	local roulette = findRoulette(rouletteId)
	if not roulette or type(roulette.Odds) ~= "table" then
		return nil, 0
	end
	local entries = {}
	local total = 0
	for _, r in ipairs(rarityList) do
		local w = roulette.Odds[r.Id]
		local pets = byRarity[r.Id]
		if type(w) == "number" and w > 0 and pets and #pets > 0 and rarityAllowed(roulette, r.Id) then
			table.insert(entries, { Rarity = r.Id, Weight = w, Pets = pets })
			total = total + w
		end
	end
	if #entries == 0 then
		return nil, 0
	end
	return entries, total
end

-- rng: anything with :Float(a, b) and :Int(a, b) (Util.NewRng). Falls back to math.random without one.
function PetCatalog.RollPet(rouletteId, rng)
	local entries, total = oddsEntries(rouletteId)
	if not entries then
		return nil
	end
	local r
	if type(rng) == "table" and rng.Float then
		r = rng:Float(0, total)
	else
		r = math.random() * total
	end
	local picked = entries[#entries] -- fallback also covers r landing on the very end
	local acc = 0
	for _, e in ipairs(entries) do
		acc = acc + e.Weight
		if r < acc then
			picked = e
			break
		end
	end
	local pets = picked.Pets
	local idx
	if type(rng) == "table" and rng.Int then
		idx = rng:Int(1, #pets)
	else
		idx = math.random(1, #pets)
	end
	if idx < 1 then
		idx = 1
	elseif idx > #pets then
		idx = #pets
	end
	return pets[idx].Id
end

-- Exact per-pet chances: rarity share (weight / total) split evenly between that rarity's pets.
function PetCatalog.GetOdds(rouletteId)
	local out = {}
	local entries, total = oddsEntries(rouletteId)
	if not entries then
		return out
	end
	for _, e in ipairs(entries) do
		local each = (e.Weight / total) / #e.Pets
		for _, def in ipairs(e.Pets) do
			table.insert(out, { PetId = def.Id, Rarity = e.Rarity, Chance = each })
		end
	end
	return out
end

-- Extra: chance per rarity, handy for an "Odds" card -> { { Rarity, Chance, Count }... }
function PetCatalog.GetRarityOdds(rouletteId)
	local out = {}
	local entries, total = oddsEntries(rouletteId)
	if not entries then
		return out
	end
	for _, e in ipairs(entries) do
		table.insert(out, { Rarity = e.Rarity, Chance = e.Weight / total, Count = #e.Pets })
	end
	return out
end

function PetCatalog.PossiblePets(rouletteId)
	local out = {}
	local entries = oddsEntries(rouletteId)
	if not entries then
		return out
	end
	for _, e in ipairs(entries) do
		for _, def in ipairs(e.Pets) do
			table.insert(out, def)
		end
	end
	return out
end

-- Extra: true when at least one current roulette can roll this pet (Secret pets: false until phase 2).
function PetCatalog.IsRollable(petId)
	local def = PetCatalog.Get(petId)
	if not def then
		return false
	end
	for _, roulette in ipairs(Config.Roulettes) do
		local w = type(roulette.Odds) == "table" and roulette.Odds[def.Rarity]
		if type(w) == "number" and w > 0 and rarityAllowed(roulette, def.Rarity) then
			return true
		end
	end
	return false
end

----------------------------------------------------------------------
-- Perks
----------------------------------------------------------------------

-- PerkLabel("MaxHealth", 0.12) -> "+12% Max Health"; fractional percents keep one decimal.
function PetCatalog.PerkLabel(perkType, value)
	local name = PetCatalog.PerkNames[perkType] or tostring(perkType)
	local pct = (tonumber(value) or 0) * 100
	local sign = "+"
	if pct < 0 then
		sign = "-"
		pct = -pct
	end
	local rounded = math.floor(pct + 0.5)
	local text
	if math.abs(pct - rounded) < 0.05 then
		text = string.format("%d", rounded)
	else
		text = string.format("%.1f", pct)
	end
	return sign .. text .. "% " .. name
end

-- Extra: all perk labels of a pet in PerkOrder, e.g. { "+12% Max Health", "+25% Cloud Tokens" }.
function PetCatalog.PerkLines(petDef)
	local out = {}
	if type(petDef) ~= "table" or type(petDef.Perks) ~= "table" then
		return out
	end
	for _, key in ipairs(PetCatalog.PerkOrder) do
		local v = petDef.Perks[key]
		if type(v) == "number" and v ~= 0 then
			table.insert(out, PetCatalog.PerkLabel(key, v))
		end
	end
	return out
end

-- Sum the perks of a list of pet ids (duplicates count once per entry), each total capped by
-- Config.Pets.PerkCaps. Unknown ids are ignored. Always returns all four perk keys.
function PetCatalog.SumPerks(petIds)
	local sums = {}
	for _, key in ipairs(PetCatalog.PerkOrder) do
		sums[key] = 0
	end
	if type(petIds) == "table" then
		for _, id in ipairs(petIds) do
			local def = PetCatalog.Get(id)
			if def then
				for key, value in pairs(def.Perks) do
					if sums[key] ~= nil and type(value) == "number" then
						sums[key] = sums[key] + value
					end
				end
			end
		end
	end
	local caps = Config.Pets.PerkCaps
	for key, total in pairs(sums) do
		local cap = caps[key]
		if type(cap) == "number" and total > cap then
			total = cap
		end
		-- trim float noise (0.1 + 0.2 style) so labels and comparisons stay tidy
		sums[key] = math.floor(total * 10000 + 0.5) / 10000
	end
	return sums
end

----------------------------------------------------------------------
-- v3: stats (tycoon income + battles)
----------------------------------------------------------------------

local function rarityScale(rarityId)
	local petStats = Config.PetStats
	local scales = type(petStats) == "table" and petStats.RarityScale
	local scale = type(scales) == "table" and scales[rarityId]
	if type(scale) == "number" and scale > 0 then
		return scale
	end
	return 1
end

----------------------------------------------------------------------
-- Phase 2: pet levels (care agent). Feeding (Kitchen food) and the Gym raise a pet copy's level (profile
-- PetLevels[key], XP curve TycoonCatalog.XpToNext); every level adds LevelBonus of the level-1 stats.
----------------------------------------------------------------------

PetCatalog.MaxLevel = 50 -- top of the XP curve when TycoonCatalog does not name one (its PetXp.MaxLevel wins)
PetCatalog.LevelBonus = 0.1 -- +10% of the level-1 stats per level (TycoonCatalog.PetIncome uses the same)
-- the highest level feeding / training can reach, by rarity (rarer pets grow further). TycoonCatalog may override
-- these (PetXp.RarityCaps or PetLevelCaps); a rarity missing here is capped at MaxPetLevel().
PetCatalog.LevelCaps = { Common = 20, Uncommon = 25, Rare = 30, Epic = 35, Legendary = 40, Mythic = 45, Secret = 50 }
-- stat multiplier of a pet copy's tier (PetKeys.TierMultiplier / TycoonCatalog.TierMultiplier hold the same values)
PetCatalog.TierMultipliers = { Normal = 1, Golden = 1.5, Rainbow = 2.5 }

local function finite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- TycoonCatalog (the economy agent's module) is read lazily: it requires PetCatalog lazily too, and builds without
-- it (tests of older rounds) still get the local numbers.
local tycoonCatalog, tycoonResolved = nil, false
local function getTycoonCatalog()
	if not tycoonResolved then
		tycoonResolved = true
		local parent = script and script.Parent
		local module = parent and parent:FindFirstChild("TycoonCatalog")
		if module then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				tycoonCatalog = result
			end
		end
	end
	return tycoonCatalog
end

-- Top of the XP curve: TycoonCatalog.MaxPetLevel (or PetXp.MaxLevel), else PetCatalog.MaxLevel.
function PetCatalog.MaxPetLevel()
	local tc = getTycoonCatalog()
	if tc then
		local px = type(tc.PetXp) == "table" and tc.PetXp or nil
		for _, v in ipairs({ tc.MaxPetLevel or false, px and px.MaxLevel or false }) do
			if finite(v) and v >= 1 then
				return math.floor(v)
			end
		end
	end
	return PetCatalog.MaxLevel
end

-- level -> whole number in 1..MaxPetLevel() (junk, NaN and anything below 1 count as 1)
local function clampLevel(level)
	local lv = tonumber(level)
	if not finite(lv) or lv < 1 then
		return 1
	end
	lv = math.floor(lv)
	local top = PetCatalog.MaxPetLevel()
	if lv > top then
		return top
	end
	return lv
end

function PetCatalog.LevelFactor(level)
	return 1 + PetCatalog.LevelBonus * (clampLevel(level) - 1)
end

-- "cat@Golden" -> "cat", "Golden"; "cat" -> "cat", nil; hybrid keys ("hyb:...") -> nil (they need the profile)
local function splitKey(key)
	if type(key) ~= "string" or key == "" or string.sub(key, 1, 4) == "hyb:" then
		return nil, nil
	end
	local base, tier = string.match(key, "^([^@]+)@(%a+)$")
	if base then
		return base, tier
	end
	return key, nil
end

-- 1 | 1.5 | 2.5 from a tier name ("Golden"), a pet key ("cat@Rainbow"), a def (StatMultiplier / Tier /
-- Look.Finish) or a positive multiplier; anything else is 1.
function PetCatalog.TierMultiplier(tier)
	if finite(tier) then
		if tier > 0 then
			return tier
		end
		return 1
	end
	if type(tier) == "table" then
		if finite(tier.StatMultiplier) and tier.StatMultiplier > 0 then
			return tier.StatMultiplier
		end
		local name = tier.Tier
		if type(name) ~= "string" then
			name = type(tier.Look) == "table" and tier.Look.Finish or nil
		end
		return (type(name) == "string" and PetCatalog.TierMultipliers[name]) or 1
	end
	if type(tier) ~= "string" then
		return 1
	end
	local m = PetCatalog.TierMultipliers[tier]
	if m then
		return m
	end
	local _, suffix = string.match(tier, "^([^@]+)@(%a+)$")
	return (suffix and PetCatalog.TierMultipliers[suffix]) or 1
end

-- the cap table: TycoonCatalog's when it has one, else PetCatalog.LevelCaps
local function capTable()
	local tc = getTycoonCatalog()
	if tc then
		local px = type(tc.PetXp) == "table" and tc.PetXp or nil
		local caps = (px and (px.RarityCaps or px.LevelCaps)) or tc.PetLevelCaps or tc.RarityLevelCaps
		if type(caps) == "table" then
			return caps
		end
	end
	return PetCatalog.LevelCaps
end

-- Level cap by rarity (see the API notes at the top). subject: a rarity id, a pet id, a pet key or a def table.
function PetCatalog.LevelCap(subject)
	local rarity = nil
	if type(subject) == "table" then
		rarity = subject.Rarity
	elseif type(subject) == "string" then
		if rarityById[subject] then
			rarity = subject
		else
			local def = PetCatalog.Get(splitKey(subject))
			if not def then
				return nil
			end
			rarity = def.Rarity
		end
	end
	if type(rarity) ~= "string" then
		return nil
	end
	local top = PetCatalog.MaxPetLevel()
	local cap = capTable()[rarity]
	if not finite(cap) and capTable() ~= PetCatalog.LevelCaps then
		cap = PetCatalog.LevelCaps[rarity]
	end
	if not finite(cap) or cap < 1 then
		return top
	end
	return math.min(math.floor(cap), top)
end

-- Stats of a def table at a level and tier (the body of GetStats; defs from PetKeys.DefOf work: tier copies carry
-- StatMultiplier, hybrids their averaged base Stats and the higher rarity). tier nil -> the def's own tier.
function PetCatalog.StatsOf(def, level, tier)
	if type(def) ~= "table" or type(def.Stats) ~= "table" then
		return nil
	end
	local mult
	if tier == nil then
		mult = PetCatalog.TierMultiplier(def)
	else
		mult = PetCatalog.TierMultiplier(tier)
	end
	local factor = rarityScale(def.Rarity) * PetCatalog.LevelFactor(level) * mult
	local out = {}
	for _, key in ipairs(PetCatalog.StatOrder) do
		local base = def.Stats[key]
		if not finite(base) then
			base = 0
		end
		out[key] = base * factor
	end
	return out
end

-- GetStats("cloudy_dragon", 3) -> { Income, Power, Health, Speed } = base * RarityScale * (1 + 0.1 * (level - 1))
-- * tier multiplier. level defaults to 1 (anything below 1 or not a number counts as 1; fractions are floored;
-- clamped to MaxPetLevel()). nil for unknown pets. See the API notes at the top for keys, defs and tiers.
function PetCatalog.GetStats(petId, level, tier)
	if type(petId) == "table" then
		return PetCatalog.StatsOf(petId, level, tier)
	end
	local base, keyTier = splitKey(petId)
	local def = PetCatalog.Get(base)
	if not def then
		return nil
	end
	if tier == nil then
		tier = keyTier
	end
	return PetCatalog.StatsOf(def, level, tier or "Normal")
end

----------------------------------------------------------------------
-- v3: Pet Index groups (one per rarity that has pets)
----------------------------------------------------------------------

local function copyReward(rarityId)
	local index = Config.Index
	local rewards = type(index) == "table" and index.Rewards
	local reward = type(rewards) == "table" and rewards[rarityId]
	local out = {}
	if type(reward) == "table" then
		for key, value in pairs(reward) do
			out[key] = value
		end
	end
	if type(out.Tokens) ~= "number" then
		out.Tokens = 0
	end
	return out
end

local function buildGroup(rarityId)
	local pets = byRarity[rarityId]
	if not pets or #pets == 0 then
		return nil
	end
	local list = {}
	for i, def in ipairs(pets) do
		list[i] = def
	end
	return { Id = rarityId, Rarity = rarityId, Pets = list, Reward = copyReward(rarityId) }
end

-- Fresh tables on every call (callers may sort or annotate them); rarity order, Secret last.
function PetCatalog.IndexGroups()
	local out = {}
	for _, r in ipairs(rarityList) do
		local group = buildGroup(r.Id)
		if group then
			table.insert(out, group)
		end
	end
	return out
end

-- Extra: one group by id (rarity id) or nil.
function PetCatalog.GetIndexGroup(groupId)
	if type(groupId) ~= "string" or not rarityById[groupId] then
		return nil
	end
	return buildGroup(groupId)
end

----------------------------------------------------------------------
-- v3: elements (ARCHITECTURE_V3.md section 11; the chart lives in Config.Elements)
----------------------------------------------------------------------

local function elementConfig()
	local E = Config.Elements
	if type(E) == "table" then
		return E
	end
	return {}
end

-- element name -> true for every name in Config.Elements.Order
local validElements = {}
for _, e in ipairs(elementConfig().Order or {}) do
	if type(e) == "string" then
		validElements[e] = true
	end
end

-- A pet definition's elements: `Elements` (a fused hybrid, phase 2) or its single `Element`. Deduplicated, in
-- the given order, unknown names dropped. Always a fresh table.
function PetCatalog.ElementsOf(def)
	local out = {}
	if type(def) ~= "table" then
		return out
	end
	local raw = def.Elements
	if type(raw) ~= "table" then
		raw = { def.Element }
	end
	local seen = {}
	for _, e in ipairs(raw) do
		if type(e) == "string" and validElements[e] and not seen[e] then
			seen[e] = true
			table.insert(out, e)
		end
	end
	return out
end

-- The elements of a catalog pet ({} for unknown ids).
function PetCatalog.GetElements(petId)
	return PetCatalog.ElementsOf(PetCatalog.Get(petId))
end

local function beats(attack, defend)
	local strong = elementConfig().Strong
	local list = type(strong) == "table" and strong[attack]
	if type(list) ~= "table" then
		return false
	end
	for _, e in ipairs(list) do
		if e == defend then
			return true
		end
	end
	return false
end

local function multipliers()
	local E = elementConfig()
	local strong = tonumber(E.StrongMultiplier) or 1.5
	local weak = tonumber(E.WeakMultiplier) or 0.75
	return strong, weak
end

-- one element against one element
local function singleMultiplier(attack, defend)
	if not validElements[attack] or not validElements[defend] then
		return 1
	end
	local strong, weak = multipliers()
	if beats(attack, defend) then
		return strong -- checked first, so the Celestial <-> Shadow rivals both hit hard
	elseif beats(defend, attack) then
		return weak
	end
	return 1
end

local function elementList(v)
	if type(v) == "table" then
		return v
	end
	return { v }
end

-- Damage multiplier of an attack element against a defending element (see the API notes at the top).
function PetCatalog.ElementMultiplier(attackElement, defendElement)
	local attackers = elementList(attackElement)
	local defenders = elementList(defendElement)
	local strong, weak = multipliers()
	local best = nil
	for _, a in ipairs(attackers) do
		local m = 1
		for _, d in ipairs(defenders) do
			m = m * singleMultiplier(a, d)
		end
		if m > strong then
			m = strong
		elseif m < weak then
			m = weak
		end
		if best == nil or m > best then
			best = m
		end
	end
	return best or 1
end

----------------------------------------------------------------------
-- Self-check (extra): returns ok, { problem strings }. Run once at load and warns in the output.
----------------------------------------------------------------------
function PetCatalog.Validate()
	local problems = {}
	local function bad(msg)
		table.insert(problems, msg)
	end

	local speciesSet, accessorySet, wingSet, roleSet, kindSet = {}, {}, {}, {}, {}
	for _, s in ipairs(PetCatalog.Species) do
		speciesSet[s] = true
	end
	for _, s in ipairs(PetCatalog.Accessories) do
		accessorySet[s] = true
	end
	for _, s in ipairs(PetCatalog.WingStyles) do
		wingSet[s] = true
	end
	for _, s in ipairs(PetCatalog.Roles) do
		roleSet[s] = true
	end
	for _, s in ipairs(PetCatalog.SpecialKinds) do
		kindSet[s] = true
	end

	local seenIds, seenNames, seenSpecials = {}, {}, {}
	local elementPets, elementRarities = {}, {}
	for _, def in ipairs(PetCatalog.Pets) do
		local id = tostring(def.Id)
		if seenIds[id] then
			bad("duplicate pet id " .. id)
		end
		seenIds[id] = true
		if seenNames[def.Name] then
			bad("duplicate pet name " .. tostring(def.Name))
		end
		seenNames[def.Name] = true
		if not rarityById[def.Rarity] then
			bad(id .. ": unknown rarity " .. tostring(def.Rarity))
		end
		local look = def.Look
		if type(look) ~= "table" then
			bad(id .. ": missing Look")
		else
			if not speciesSet[look.Species] then
				bad(id .. ": unknown species " .. tostring(look.Species))
			end
			if not wingSet[look.WingStyle] then
				bad(id .. ": unknown wing style " .. tostring(look.WingStyle))
			end
			if look.Accessory ~= nil and not accessorySet[look.Accessory] then
				bad(id .. ": unknown accessory " .. tostring(look.Accessory))
			end
			if look.Primary == nil or look.Secondary == nil or look.Eye == nil or look.WingColor == nil then
				bad(id .. ": Look is missing a colour")
			end
		end
		local count = 0
		for key, value in pairs(def.Perks or {}) do
			count = count + 1
			if Config.Pets.PerkCaps[key] == nil then
				bad(id .. ": perk " .. tostring(key) .. " is not in Config.Pets.PerkCaps")
			end
			if type(value) ~= "number" or value <= 0 then
				bad(id .. ": perk " .. tostring(key) .. " must be a positive number")
			end
		end
		if count < 1 or count > 2 then
			bad(id .. ": a pet needs 1-2 perks, has " .. count)
		end

		-- v3 fields
		if not roleSet[def.Role] then
			bad(id .. ": unknown role " .. tostring(def.Role))
		end
		if type(def.Element) ~= "string" or not validElements[def.Element] then
			bad(id .. ": Element " .. tostring(def.Element) .. " is not in Config.Elements.Order")
		else
			elementPets[def.Element] = (elementPets[def.Element] or 0) + 1
			elementRarities[def.Element] = elementRarities[def.Element] or {}
			elementRarities[def.Element][tostring(def.Rarity)] = true
		end
		local stats = def.Stats
		if type(stats) ~= "table" then
			bad(id .. ": missing Stats")
		else
			for _, key in ipairs(PetCatalog.StatOrder) do
				local v = stats[key]
				if type(v) ~= "number" or v <= 0 or v ~= v then
					bad(id .. ": stat " .. key .. " must be a positive number")
				end
			end
			if type(stats.Income) == "number" and type(stats.Power) == "number" then
				if def.Role == "Economy" and stats.Income <= stats.Power then
					bad(id .. ": an Economy pet needs more Income than Power")
				elseif def.Role == "Combat" and stats.Power <= stats.Income then
					bad(id .. ": a Combat pet needs more Power than Income")
				end
			end
		end
		local special = def.Special
		if type(special) ~= "table" then
			bad(id .. ": missing Special")
		else
			if type(special.Id) ~= "string" or special.Id == "" then
				bad(id .. ": Special.Id missing")
			elseif seenSpecials[special.Id] then
				bad(id .. ": duplicate special id " .. special.Id)
			else
				seenSpecials[special.Id] = true
			end
			if type(special.Name) ~= "string" or special.Name == "" then
				bad(id .. ": Special.Name missing")
			end
			if not kindSet[special.Kind] then
				bad(id .. ": unknown special kind " .. tostring(special.Kind))
			end
			if type(special.Power) ~= "number" or special.Power <= 0 then
				bad(id .. ": Special.Power must be a positive number")
			end
			if typeof(special.Color) ~= "Color3" then
				bad(id .. ": Special.Color must be a Color3")
			end
		end
	end

	-- The best pets for a perk, equipped together, must stay within that perk's cap on their own.
	local maxEquipped = tonumber(Config.Pets.MaxEquipped) or 3
	for key, cap in pairs(Config.Pets.PerkCaps) do
		local values = {}
		for _, def in ipairs(PetCatalog.Pets) do
			local v = type(def.Perks) == "table" and def.Perks[key]
			if type(v) == "number" then
				table.insert(values, v)
			end
		end
		table.sort(values, function(a, b)
			return a > b
		end)
		local top = 0
		for i = 1, math.min(maxEquipped, #values) do
			top = top + values[i]
		end
		if type(cap) == "number" and top > cap + 1e-9 then
			bad("the best " .. maxEquipped .. " " .. key .. " pets add up to " .. top .. ", above the cap " .. cap)
		end
	end

	-- Every element needs at least 3 pets spread over several rarities (battle teams can build around any of them).
	local order = elementConfig().Order
	if type(order) ~= "table" or #order == 0 then
		bad("Config.Elements.Order is missing")
	else
		for _, e in ipairs(order) do
			local nRarities = 0
			for _ in pairs(elementRarities[e] or {}) do
				nRarities = nRarities + 1
			end
			if (elementPets[e] or 0) < 3 or nRarities < 2 then
				bad("element " .. tostring(e) .. " has " .. (elementPets[e] or 0) .. " pet(s) in " .. nRarities .. " rarities (needs 3+ in 2+)")
			end
		end
	end

	-- Secret pets must outclass the best Mythic (total perk strength).
	local function perkSum(def)
		local sum = 0
		for _, v in pairs(def.Perks or {}) do
			if type(v) == "number" then
				sum = sum + v
			end
		end
		return sum
	end
	local bestMythic = 0
	for _, def in ipairs(byRarity.Mythic or {}) do
		bestMythic = math.max(bestMythic, perkSum(def))
	end
	for _, def in ipairs(byRarity[SECRET] or {}) do
		if perkSum(def) < bestMythic then
			bad(tostring(def.Id) .. ": a Secret pet's perks must be at least as strong as the best Mythic")
		end
	end

	for _, roulette in ipairs(Config.Roulettes) do
		local total = 0
		for rarityId, w in pairs(roulette.Odds) do
			if type(w) == "number" and w > 0 then
				if rarityId == SECRET and roulette.AllowSecret ~= true then
					bad("roulette " .. roulette.Id .. " lists Secret pets without AllowSecret = true (they are ignored)")
				else
					total = total + w
					if not byRarity[rarityId] or #byRarity[rarityId] == 0 then
						bad("roulette " .. roulette.Id .. " lists rarity " .. tostring(rarityId) .. " but no pet has it")
					end
				end
			end
		end
		if total <= 0 then
			bad("roulette " .. roulette.Id .. " has no positive odds")
		end
	end

	return #problems == 0, problems
end

do
	local ok, problems = PetCatalog.Validate()
	if not ok then
		for _, p in ipairs(problems) do
			warn("[PetCatalog] " .. p)
		end
	end
end

return PetCatalog
