-- Config: every tunable number and shared name in Nimbus Climb lives here.
-- Plain Lua 5.1-compatible syntax only (no Luau type annotations, `continue`, `+=`).

local Config = {}

Config.GameName = "Nimbus Climb"
Config.Tagline = "Climb the storm. Together."

----------------------------------------------------------------------
-- Character physics (applied to every Humanoid by PlayerService)
----------------------------------------------------------------------
local P = {
	Gravity = 196.2,
	WalkSpeed = 16,
	RunSpeed = 27,
	JumpPower = 52, -- Humanoid.UseJumpPower must be true
	MaxHealth = 100,
	DashSpeed = 85,
	DashDuration = 0.18,
	DashCooldown = 1.6,
	DashStaminaCost = 35,
	MaxStamina = 100,
	StaminaRegen = 22, -- per second while not running
	RunStaminaDrain = 14, -- per second while running
}
-- Derived numbers the course generator relies on (studs).
P.JumpHeight = (P.JumpPower * P.JumpPower) / (2 * P.Gravity) -- ~6.9
P.AirTime = (2 * P.JumpPower) / P.Gravity -- flat jump, ~0.53s
P.MaxRunGap = P.RunSpeed * P.AirTime -- ~14.3 theoretical
P.DashBonus = (P.DashSpeed - P.RunSpeed) * P.DashDuration -- ~10.4 extra
P.MaxDashGap = P.MaxRunGap + P.DashBonus -- ~24.7 theoretical
Config.Physics = P

----------------------------------------------------------------------
-- Names shared by server + client
----------------------------------------------------------------------
Config.Tags = {
	Checkpoint = "NC_Checkpoint", -- attr CheckpointIndex (int, 1..N)
	FinishPad = "NC_FinishPad",
	CloudToken = "NC_CloudToken", -- attr Value (int, default 1)
	SpinBar = "NC_SpinBar", -- attrs Speed (deg/s), Damage
	StormCloud = "NC_StormCloud", -- attr DPS (damage per second)
	LightningZone = "NC_LightningZone", -- attrs Damage, Interval, Warning
	VanishCloud = "NC_VanishCloud", -- attrs VanishDelay, ReturnDelay
	MovingCloud = "NC_MovingCloud", -- attrs EndOffset (Vector3), Period
	BouncePad = "NC_BouncePad", -- attrs Power, LaunchSpeed (horizontal studs/s when the player is moving)
	PressurePlate = "NC_PressurePlate", -- attr BridgeId (string)
	PlateBridge = "NC_PlateBridge", -- attr BridgeId (string)
	-- v2 hazards / elements
	Pendulum = "NC_Pendulum", -- the beam part; attrs Hinge (Vector3 world pivot), Axis (Vector3 world unit, swing axis), Period, Arc (deg each side), Damage
	WindGust = "NC_WindGust", -- invisible volume part; attrs Force (studs/s push), Direction (Vector3 unit), Interval, Warning
	CloudCannon = "NC_CloudCannon", -- the pad part; attrs Target (Vector3 world landing point), FlightTime (s)
	GoldenToken = "NC_GoldenToken", -- a CloudToken whose Value is 5 (also carries CloudToken tag)
}

-- Attributes set on Player instances by the server (client HUD reads them).
Config.Attr = {
	Tokens = "CloudTokens", -- lifetime total (persisted)
	MatchTokens = "MatchTokens", -- collected in current match
	InMatch = "InMatch", -- bool
	Downed = "Downed", -- bool (KO'd inside a match)
	Stamina = "Stamina", -- number, written by the client controller only
	EquippedPets = "EquippedPets", -- csv of pet ids, e.g. "cloudy_dragon,pebble_pup" ("" when none)
	SpotIndex = "SpotIndex", -- lobby spot number (1..Config.Lobby.SpotCount), absent when none
	PerkStaminaRegen = "PerkStaminaRegen", -- number, e.g. 0.2 = +20% stamina regen (server writes)
}

Config.Remotes = {
	-- server -> client
	"Notify", -- (text:string, kind:string, duration:number)  kind: info|good|bad|token
	"DamageTaken", -- (amount:number, sourceKind:string)
	"PartyState", -- (state:table|nil)  see ARCHITECTURE.md
	"MatchState", -- (state:table|nil)  see ARCHITECTURE.md
	"MatchResult", -- (result:table)
	"DashFx", -- (userId:number)  server -> all clients, for others' trails
	"ProfileSync", -- (snapshot:table)  see ARCHITECTURE_V2.md
	"RouletteResult", -- (result:table)    see ARCHITECTURE_V2.md
	"OpenPanel", -- (panelId:string, args:table|nil)  e.g. ("Shop", {Tab="Roulette", RouletteId="Cloud"})
	-- client -> server
	"Dash", -- ()
	"LeaveParty", -- ()
	"LeaveMatch", -- ()
	"RequestProfile", -- ()  asks for a fresh ProfileSync
	"BuyRoulette", -- (rouletteId:string)
	"EquipPet", -- (petId:string)
	"UnequipPet", -- (petId:string)
	"BuyItem", -- (itemId:string, qty:number|nil)
	"UseItem", -- (itemId:string)
	"GoToSpot", -- ()
}

----------------------------------------------------------------------
-- Damage
----------------------------------------------------------------------
Config.Damage = {
	IFrames = 0.6, -- seconds of invulnerability after a hit
	DownedHealth = 1, -- Humanoid.Health a downed player is held at
	ReviveHealthFraction = 0.5, -- revived players come back with 50%
	CheckpointHealFraction = 0.35, -- everyone alive heals this much at a checkpoint
	VoidDamage = { Easy = 10, Medium = 15, Hard = 22, Extreme = 30, Saint = 40 },
	Kinds = { "Void", "Lightning", "SpinBar", "Storm", "Pendulum", "Other" },
}

----------------------------------------------------------------------
-- Lobby (a big floating cloud village high in the sky)
----------------------------------------------------------------------
Config.Lobby = {
	Origin = Vector3.new(0, 300, 0), -- centre of the main plaza surface
	PlazaRadius = 110,
	PortalRingRadius = 88, -- the five portal gates stand on this ring
	SpotRingRadius = 215, -- the player spots (personal cloud homes) stand on this ring
	SpotCount = 16, -- one saved spot per player; set the place's Max Players to <= this
	ShopOffset = Vector3.new(0, 0, -150), -- shop island centre relative to Origin
	KillY = 100, -- fall below this -> teleport back to the plaza
}

----------------------------------------------------------------------
-- Match settings + difficulties
----------------------------------------------------------------------
Config.Match = {
	MinPlayers = 1,
	MaxPlayers = 4,
	PartyCountdown = 15, -- seconds, starts when the first player enters a portal
	FullPartyCountdown = 4, -- shortened countdown once the party is full
	IntroCountdown = 5, -- "3-2-1" on the start platform (players frozen)
	EndScreenSeconds = 10, -- results screen before returning to lobby
	ArenaOrigin = Vector3.new(4000, 800, 0), -- start-platform centre of slot 1
	SlotSpacing = 800, -- studs between concurrent matches along +X
	MaxConcurrent = 6,
	TokenBonusOnWin = { Easy = 10, Medium = 20, Hard = 35, Extreme = 60, Saint = 100 },
}

-- Overall shape of a course, and the stage themes a course is assembled from.
-- (Semantics in ARCHITECTURE_V2.md. CourseBuilder owns the geometry.)
Config.Archetypes = { "Straight", "Zigzag", "Serpent", "Spiral" }
Config.StageThemes = {
	"Stones", -- plain steps of varied size/shape
	"Beams", -- narrow beams to balance on
	"Bounce", -- bounce pads launching to higher steps
	"Moving", -- clouds sliding back and forth
	"Spin", -- spinning-bar platforms
	"Storm", -- dark rain clouds that drizzle damage
	"Lightning", -- warned lightning strike zones
	"Vanish", -- steps that fade after you land
	"Cannon", -- cloud cannons that fling you to the next island
	"Wind", -- periodic wind gusts pushing sideways
	"Pendulum", -- swinging beams over narrow steps
	"Plates", -- co-op pressure-plate bridges
	"DashGap", -- gaps that need a dash
	"Gauntlet", -- short mixed hazard run
}
Config.Course = {
	MaxRadius = 170, -- no step further than this (horizontal) from the start platform centre
	Clearance = 8, -- min free headroom above any walkable top surface (no overhanging steps)
}

-- Order here == order of portals around the lobby (easy -> hardest).
-- Course rules are in STUDS. All gaps are edge-to-edge. Physics-safe by construction:
-- run gaps <= ~0.8 * MaxRunGap (14.3); rises <= 0.7 * JumpHeight (~4.8).
-- Archetypes / Themes are weight tables (higher = more likely).
Config.Difficulties = {
	{
		Id = "Easy",
		DisplayName = "Easy",
		Blurb = "Chill clouds and wide steps. Perfect for new climbers.",
		Color = Color3.fromRGB(96, 190, 140),
		Stars = 1,
		Stages = 4, -- each stage = StepsPerStage steps + 1 checkpoint
		StepsPerStage = { 5, 7 },
		GapMin = 4, GapMax = 7.5,
		RiseMax = 3,
		PlatformMin = 11, PlatformMax = 17,
		HazardChance = 0.10,
		DashGapChance = 0,
		TokensPerStage = 4,
		TimeLimit = 540,
		Archetypes = { Straight = 3, Serpent = 2 },
		Themes = { Stones = 4, Bounce = 3, Moving = 1 },
	},
	{
		Id = "Medium",
		DisplayName = "Medium",
		Blurb = "Moving clouds, spinning bars and your first co-op bridge.",
		Color = Color3.fromRGB(96, 160, 224),
		Stars = 2,
		Stages = 5,
		StepsPerStage = { 6, 8 },
		GapMin = 5.5, GapMax = 9,
		RiseMax = 3.8,
		PlatformMin = 8, PlatformMax = 13,
		HazardChance = 0.30,
		DashGapChance = 0,
		TokensPerStage = 4,
		TimeLimit = 720,
		Archetypes = { Straight = 2, Zigzag = 3, Serpent = 2 },
		Themes = { Stones = 3, Bounce = 2, Moving = 3, Spin = 2, Plates = 2, Cannon = 1 },
	},
	{
		Id = "Hard",
		DisplayName = "Hard",
		Blurb = "Vanishing steps, lightning and swinging beams.",
		Color = Color3.fromRGB(226, 150, 74),
		Stars = 3,
		Stages = 6,
		StepsPerStage = { 6, 8 },
		GapMin = 6.5, GapMax = 10,
		RiseMax = 4.3,
		PlatformMin = 6, PlatformMax = 10,
		HazardChance = 0.50,
		DashGapChance = 0.06,
		DashGapMin = 14, DashGapMax = 17,
		TokensPerStage = 5,
		TimeLimit = 900,
		Archetypes = { Zigzag = 3, Serpent = 2, Spiral = 3 },
		Themes = { Stones = 1, Moving = 2, Spin = 2, Vanish = 3, Lightning = 2, Pendulum = 2, Wind = 2, Plates = 2, Cannon = 2, Beams = 2 },
	},
	{
		Id = "Extreme",
		DisplayName = "Extreme",
		Blurb = "Dash-only gaps, storms and narrow beams. Bring friends.",
		Color = Color3.fromRGB(214, 92, 104),
		Stars = 4,
		Stages = 8,
		StepsPerStage = { 7, 9 },
		GapMin = 7.5, GapMax = 11,
		RiseMax = 4.6,
		PlatformMin = 5, PlatformMax = 8,
		HazardChance = 0.70,
		DashGapChance = 0.15,
		DashGapMin = 15, DashGapMax = 19,
		TokensPerStage = 5,
		TimeLimit = 1200,
		Archetypes = { Zigzag = 2, Serpent = 2, Spiral = 4 },
		Themes = { Beams = 3, Spin = 2, Vanish = 3, Lightning = 3, Storm = 3, Pendulum = 3, Wind = 3, Plates = 2, Cannon = 2, DashGap = 3, Gauntlet = 2 },
	},
	{
		Id = "Saint",
		DisplayName = "Saint",
		Blurb = "Only the saintly finish. Tiny steps, relentless hazards.",
		Color = Color3.fromRGB(226, 190, 96),
		Stars = 5,
		Stages = 10,
		StepsPerStage = { 7, 10 },
		GapMin = 8, GapMax = 11.5,
		RiseMax = 4.7,
		PlatformMin = 4, PlatformMax = 7,
		HazardChance = 0.85,
		DashGapChance = 0.25,
		DashGapMin = 16, DashGapMax = 20,
		TokensPerStage = 6,
		TimeLimit = 1500,
		Archetypes = { Spiral = 4, Serpent = 2, Zigzag = 2 },
		Themes = { Beams = 3, Vanish = 3, Lightning = 3, Storm = 3, Pendulum = 3, Wind = 3, Plates = 2, Cannon = 2, DashGap = 4, Gauntlet = 4, Spin = 2 },
	},
}

function Config.GetDifficulty(id)
	for _, d in ipairs(Config.Difficulties) do
		if d.Id == id then
			return d
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Tokens + persistence
----------------------------------------------------------------------
Config.Tokens = {
	DefaultValue = 1,
	GoldenValue = 5,
	RespawnSeconds = nil, -- tokens are one-shot per match
	DataStoreName = "NimbusClimb_v2",
	LegacyDataStoreName = "NimbusClimb_v1", -- read once to migrate v1 saves ({Tokens=n})
	AutosaveSeconds = 90,
}

----------------------------------------------------------------------
-- Pets (collectible winged companions), roulettes and items
----------------------------------------------------------------------
Config.Rarities = {
	{ Id = "Common", Order = 1, Color = Color3.fromRGB(168, 178, 194) },
	{ Id = "Uncommon", Order = 2, Color = Color3.fromRGB(104, 196, 128) },
	{ Id = "Rare", Order = 3, Color = Color3.fromRGB(88, 158, 232) },
	{ Id = "Epic", Order = 4, Color = Color3.fromRGB(176, 108, 232) },
	{ Id = "Legendary", Order = 5, Color = Color3.fromRGB(242, 182, 68) },
	{ Id = "Mythic", Order = 6, Color = Color3.fromRGB(238, 98, 140) },
}

Config.Pets = {
	MaxEquipped = 3, -- pets flying beside you
	MaxPerStack = 99,
	-- Perks pets can give (fractions, e.g. 0.1 = +10%). Totals are capped so nothing breaks the course physics.
	-- Pets never change run speed or jump power (courses are validated against Config.Physics).
	PerkCaps = { MaxHealth = 0.5, TokenBonus = 1.0, StaminaRegen = 0.6, CheckpointHeal = 1.0 },
}

-- Cost in cloud tokens. Odds are relative weights per rarity (pets inside a rarity are equally likely).
Config.Roulettes = {
	{
		Id = "Cloud",
		DisplayName = "Cloud Roulette",
		Price = 50,
		Color = Color3.fromRGB(120, 190, 235),
		Odds = { Common = 60, Uncommon = 28, Rare = 10, Epic = 2 },
	},
	{
		Id = "Storm",
		DisplayName = "Storm Roulette",
		Price = 250,
		Color = Color3.fromRGB(128, 120, 214),
		Odds = { Uncommon = 35, Rare = 40, Epic = 20, Legendary = 5 },
	},
	{
		Id = "Sky",
		DisplayName = "Sky Roulette",
		Price = 1000,
		Color = Color3.fromRGB(240, 180, 90),
		Odds = { Rare = 35, Epic = 45, Legendary = 17, Mythic = 3 },
	},
	{
		Id = "Celestial",
		DisplayName = "Celestial Roulette",
		Price = 5000,
		Color = Color3.fromRGB(236, 120, 170),
		Odds = { Epic = 45, Legendary = 40, Mythic = 15 },
	},
}

Config.Items = {
	MaxCarry = 5, -- per item type
	HotbarSlots = 4, -- keys 1-4
}

return Config
