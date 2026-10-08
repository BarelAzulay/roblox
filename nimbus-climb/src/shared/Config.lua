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
	BouncePad = "NC_BouncePad", -- attr Power
	PressurePlate = "NC_PressurePlate", -- attr BridgeId (string)
	PlateBridge = "NC_PlateBridge", -- attr BridgeId (string)
}

-- Attributes set on Player instances by the server (client HUD reads them).
Config.Attr = {
	Tokens = "CloudTokens", -- lifetime total (persisted)
	MatchTokens = "MatchTokens", -- collected in current match
	InMatch = "InMatch", -- bool
	Downed = "Downed", -- bool (KO'd inside a match)
	Stamina = "Stamina", -- number, written by the client controller only
}

Config.Remotes = {
	-- server -> client
	"Notify", -- (text:string, kind:string, duration:number)  kind: info|good|bad|token
	"DamageTaken", -- (amount:number, sourceKind:string)
	"PartyState", -- (state:table|nil)  see ARCHITECTURE.md
	"MatchState", -- (state:table|nil)  see ARCHITECTURE.md
	"MatchResult", -- (result:table)
	"DashFx", -- (userId:number)  server -> all clients, for others' trails
	-- client -> server
	"Dash", -- ()
	"LeaveParty", -- ()
	"LeaveMatch", -- ()
}

----------------------------------------------------------------------
-- Damage
----------------------------------------------------------------------
Config.Damage = {
	IFrames = 0.6, -- seconds of invulnerability after a hit
	DownedHealth = 1, -- Humanoid.Health a downed player is held at
	ReviveHealthFraction = 0.5, -- revived players come back with 50%
	CheckpointHealFraction = 0.35, -- everyone alive heals this much at a checkpoint
	VoidDamage = { Breeze = 15, Gale = 22, Thunderstorm = 30 },
	Kinds = { "Void", "Lightning", "SpinBar", "Storm", "Other" },
}

----------------------------------------------------------------------
-- Lobby (a floating cloud village high in the sky)
----------------------------------------------------------------------
Config.Lobby = {
	Origin = Vector3.new(0, 300, 0), -- centre of the main plaza surface
	PlazaRadius = 70,
	PortalRingRadius = 62,
	KillY = 150, -- fall below this -> teleport back to the plaza
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
	TokenBonusOnWin = { Breeze = 10, Gale = 20, Thunderstorm = 40 },
}

-- Order here == order of portals around the lobby.
-- Course rules are in STUDS. All gaps are edge-to-edge. Physics-safe by construction:
-- MaxGap <= ~0.75 * MaxRunGap (14.3) so every non-dash gap is comfortably runnable.
Config.Difficulties = {
	{
		Id = "Breeze",
		DisplayName = "Soft Breeze",
		Blurb = "A gentle climb. Great for warming up.",
		Color = Color3.fromRGB(120, 220, 255),
		Stages = 4, -- each stage = ~5-7 steps + 1 checkpoint
		StepsPerStage = { 5, 7 },
		GapMin = 4, GapMax = 8,
		RiseMax = 3.5, -- max step up between consecutive platforms
		PlatformMin = 10, PlatformMax = 16,
		HazardChance = 0.15,
		DashGapChance = 0,
		TokensPerStage = 4,
		TimeLimit = 600,
		Stars = 1,
	},
	{
		Id = "Gale",
		DisplayName = "Gale Force",
		Blurb = "Moving clouds, spinning bars, tight landings.",
		Color = Color3.fromRGB(255, 190, 90),
		Stages = 6,
		StepsPerStage = { 6, 8 },
		GapMin = 6, GapMax = 10.5,
		RiseMax = 4.5,
		PlatformMin = 7, PlatformMax = 12,
		HazardChance = 0.4,
		DashGapChance = 0.08,
		TokensPerStage = 4,
		TimeLimit = 900,
		Stars = 2,
	},
	{
		Id = "Thunderstorm",
		DisplayName = "Thunderstorm",
		Blurb = "Lightning, vanishing clouds and dash-only gaps. Bring friends.",
		Color = Color3.fromRGB(190, 120, 255),
		Stages = 8,
		StepsPerStage = { 6, 9 },
		GapMin = 8, GapMax = 11,
		RiseMax = 5,
		PlatformMin = 5, PlatformMax = 9,
		HazardChance = 0.65,
		DashGapChance = 0.2,
		DashGapMin = 15, DashGapMax = 19, -- needs a dash; ~0.75 * MaxDashGap
		TokensPerStage = 5,
		TimeLimit = 1200,
		Stars = 3,
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
	RespawnSeconds = nil, -- tokens are one-shot per match
	DataStoreName = "NimbusClimb_v1",
	AutosaveSeconds = 90,
}

return Config
