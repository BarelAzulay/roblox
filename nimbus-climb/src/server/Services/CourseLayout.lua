-- CourseLayout: pure, deterministic parkour layout generator + validator for Nimbus Climb (v2).
-- Only requires Config and Util (shared). No Instances. Plain Lua 5.1 syntax.
--
-- API
--   CourseLayout.GenerateLayout(difficultyId, seed) -> Layout    same (id, seed) -> identical layout, always valid
--   CourseLayout.ValidateLayout(layout) -> ok:boolean, problems:{string}   a proof of every rule below
--   CourseLayout.Stats(layout) -> table of summary numbers (see the end of the file)
--   CourseLayout.StepGap(stepA, stepB) -> number   edge-to-edge gap (below)
--   CourseLayout.ToLocal(step, x, z) -> lx, lz     world XZ (origin-relative) -> the step's local XZ
--   CourseLayout.ToWorld(step, lx, lz) -> x, z     the step's local XZ -> world XZ (origin-relative)
--   CourseLayout.RootHeight = 3                    HumanoidRootPart height above the feet
--   CourseLayout.RunReach(rise) / DashReach(rise) / AirTime(rise)   the jump model used by the rules
--   CourseLayout.Debug = nil | { reasons = {}, attempts = {}, problems = {}, stuck = {} }   optional statistics sink
--
-- ======================================================================================================
-- SCHEMA (the CourseBuilder codes its geometry against exactly this)
-- ======================================================================================================
-- COORDINATES
--   * Every position is ORIGIN-RELATIVE: world = origin + position. Y is up. The Start step is at (0, 0, 0).
--   * The route is NOT limited to +Z any more: it follows an archetype (a path in the XZ plane) and climbs.
--     Steps of different laps / lanes may overlap in XZ at different heights.
--   * Step.Pos = the CENTRE of the step's TOP surface. The solid occupies Y in [Pos.Y - Size.Y, Pos.Y].
--     Walkable geometry must fill the whole X*Z rectangle of the top (corners may be rounded by <= 1.5 studs) and
--     must stay inside the box [Pos.Y - Size.Y, Pos.Y] (puffs may hang below, never above the top).
--   * Step.Size = Vector3(width X, thickness Y, depth Z): the footprint BEFORE Yaw.
--   * Step.Yaw = degrees about +Y, exactly CFrame.Angles(0, math.rad(Yaw), 0). The local +Z axis of a step is
--     (sin Yaw, 0, cos Yaw) in world XZ and its local +X axis is (cos Yaw, 0, -sin Yaw). CFrame for a step top:
--     CFrame.new(origin + Pos) * CFrame.Angles(0, math.rad(Yaw), 0). Yaw is in [0, 360).
--   * Edge-to-edge GAP between two steps = the Euclidean distance in the XZ plane between their two footprint
--     rectangles (after Yaw), 0 when they overlap. For a Moving step the footprint slides from Pos to Pos +
--     Hazard.EndOffset; its gap to a neighbour is the LARGEST gap over the whole slide (Step.Gap) and the
--     smallest gap over the slide is also guaranteed to be >= the difficulty's GapMin.
--   * "Rise" between consecutive steps = next.Pos.Y - prev.Pos.Y (top to top).
--
-- Layout = {
--   DifficultyId = "Hard",     -- Config.Difficulties[i].Id
--   Seed = 1234,               -- the seed that was passed in
--   Attempt = 1,               -- which internal generation attempt passed validation (informational)
--   Archetype = "Spiral",      -- one of Config.Archetypes (Straight | Zigzag | Serpent | Spiral)
--   Themes = { "Stones", ... },-- Themes[k] = theme id of stage k, one per stage (no equal neighbours)
--   Steps = { Step, ... },     -- in order of travel; Steps[1].Kind == "Start", Steps[#Steps].Kind == "Finish"
--   Stages = { StageInfo, ... },-- Stages[k], k = 1..diff.Stages
--   Checkpoints = { [k] = stepIndex },  -- Steps[Checkpoints[k]] is the Checkpoint that ends stage k; the last
--                              -- checkpoint is Steps[#Steps - 1], directly followed by the Finish
--   Scenery = { SceneryItem, ... },
--   Centre = Vector3|nil,      -- Spiral only: Y = 0 centre of the helix (the CentralPillar stands here)
--   TotalTokens = n,           -- sum of token VALUES (regular 1, golden 5) over every step's Tokens
--   TokenCount = n, GoldenCount = n,
--   Bounds = { Min = Vector3, Max = Vector3 },  -- AABB of every solid with a 2 stud margin in X and Z: Min.Y is
--                              -- 6 below the lowest underside, Max.Y the highest (top + Headroom).
--                              -- Hazard volumes stay inside it.
-- }
-- StageInfo = {
--   Index = k, Theme = "Wind", Name = "Gale Gardens",
--   Tint = 1..8,               -- per-stage trim tint index (never equal to the previous stage's)
--   FirstStep = i, LastStep = j,  -- Steps[i..j] are the stage's steps; Steps[j] is its Checkpoint
--   Landmark = "KiteFlock"|nil,   -- type of the scenery landmark placed for this stage (nil if none fitted)
-- }
--
-- Step = {
--   Index = i,                 -- == position in Steps
--   Stage = k,                 -- 0 for Start; k for the steps and the Checkpoint of stage k; Finish = last stage
--   Kind = string,             -- see the table below
--   Pos = Vector3, Size = Vector3, Yaw = number,
--   Gap = number,              -- edge-to-edge gap to Steps[i-1] (largest over a Moving step's slide); nil on Start
--   Link = string,             -- how this step is reached from the previous one; nil on Start:
--                              --   "Walk"   ordinary run-and-jump: GapMin <= gap <= GapMax and gap <= RunReach(rise)
--                              --   "Dash"   DashGap / PlateBridge: gap needs a dash (see DashHint)
--                              --   "Cannon" the landing island of the previous CannonPad (only way: the cannon)
--                              --   "Bounce" rise is above the jump cap: reachable only from the previous Bounce pad
--   Variant = 1..4,            -- cosmetic seed for the builder (shape/puff variation); no gameplay meaning
--   Headroom = number,         -- free height above Pos.Y that nothing of ANOTHER step may enter where footprints
--                              --   overlap, and the maximum height of THIS step's own hazard geometry and decor.
--                              --   >= Config.Course.Clearance (13: a full jump needs JumpHeight 6.9 + the character's ~5.2).
--                              --   Bounce = pad apex + 1; Start 18 and Finish 18 (their arches); Checkpoint 10.5 (flag);
--                              --   Storm 10.5; Lightning 12; Pendulum 11.5; Wind 10; CannonPad 9; each raised to at least
--                              --   Clearance.
--   Hazard = table|nil,        -- per Kind below; nil for kinds without one
--   Tokens = { Token, ... }|nil,
--   DashHint = { From = i-1, Pos = Vector3, Dir = Vector3 }|nil,  -- DashGap and PlateBridge only: Pos is a spot on
--                              --   the previous (run-up) platform's top surface 1.5 studs behind its edge along
--                              --   the line to this step; Dir is the horizontal unit vector towards the gap. The
--                              --   builder puts the "DASH!" arrow + sign there.
-- }
-- Token = { Pos = Vector3 (origin-relative centre of the coin), Value = 1 | 5, Golden = boolean }
--   Value 5 = Config.Tokens.GoldenValue (golden: also tag Config.Tags.GoldenToken). Tokens hover 3-4.5 studs above
--   their step's top, over the step or in the gap in front of it. Use TokenService.MakeTokenPart(world, parent, Value).
--
-- KINDS (Size rules: Platform-like kinds are within [diff.PlatformMin, diff.PlatformMax] on X and Z)
--   Start             26x26, no hazard. At (0,0,0). Yaw = the direction of the first lane.
--   Platform          plain step (also cannon landing islands, which have Link = "Cannon")
--   Beam              long narrow beam: X 2.5-4, Z 14-30 (long axis = local Z = the walking direction)
--   Moving            Hazard "Moving"           (tag MovingCloud)
--   Vanishing         Hazard "Vanish"           (tag VanishCloud)
--   Bounce            Hazard "Bounce"           (tag BouncePad)
--   SpinBarPlatform   Hazard "SpinBar"          (tag SpinBar)
--   StormPlatform     Hazard "Storm"            (tag StormCloud)
--   LightningPlatform Hazard "Lightning"        (tag LightningZone)
--   PendulumPlatform  Hazard "Pendulum"         (tag Pendulum)        X and Z in [9, 15]
--   WindPlatform      Hazard "Wind"             (tag WindGust)        X and Z in [9, 15]
--   CannonPad         Hazard "Cannon"           (tag CloudCannon)     X, Z >= 7; always followed by its landing island
--   PlateBridge       Hazard "PlateBridge"      (tags PlateBridge + PressurePlate), >= 7x7, Link "Dash", rise 0, same
--                     Yaw as the run-up platform, directly ahead of it
--   DashGap           no hazard, Link "Dash": the gap needs a dash; DashHint present
--   Checkpoint        16x16 (>= 14x14). tag Checkpoint, attr CheckpointIndex = Stage
--   Finish            30x30 (>= 28x28). tag FinishPad
--
-- HAZARDS. Hazard.Type is the string in quotes above. All positions are origin-relative; "top" = Step.Pos.Y.
--   "Moving" = { Type, EndOffset = Vector3 (horizontal, slide from Pos to Pos + EndOffset, length 3.5-10),
--                Period = seconds ONE WAY (travel / Period <= 4.2 studs/s) }
--       attrs: EndOffset, Period. The part starts at Pos (an extreme of the slide) and tweens back and forth.
--   "Vanish" = { Type, VanishDelay, ReturnDelay }                     attrs: VanishDelay, ReturnDelay
--   "Bounce" = { Type, Pos = pad centre (at the step centre, y = top), PadSize = pad width, Power, LaunchSpeed,
--                Apex = Power^2 / (2 * gravity) }                     attrs: Power, LaunchSpeed
--   "SpinBar" = { Type, Pos = hub (step centre, y = top), Length, Speed = deg/s (signed), Damage, Count = 1|2,
--                 Height = bar centre above top }
--       one SpinBar part per bar k = 1..Count (suggested size Length x 1.5 x 1.1), rotated (k-1) * 180 / Count
--       degrees about Y; attrs Speed, Damage on each.
--   "Storm" = { Type, DPS, Box = { Pos = centre of the box BASE (y = top), Size = Vector3(X, height, Z), Yaw } }
--       the box (covering the footprint) is the StormCloud volume part: CFrame.new(Pos + (0, Size.Y/2, 0)) *
--       Angles(0, rad(Yaw), 0); attr DPS. Dark puffs may sit above it up to Headroom.
--   "Lightning" = { Type, Zones = { { Pos = disc centre (y = top), Radius }, ... } (1-3 zones, inside the
--                   footprint, always leaving a safe spot), Damage, Interval, Warning }
--       one LightningZone part per zone; attrs Damage, Interval, Warning (+ Radius).
--   "Pendulum" = { Type, Hinge = world pivot above the step, Axis = horizontal unit vector the beam rotates about,
--                  Arc = degrees each side, Period = seconds per full swing, Damage, Length = hinge to beam end,
--                  BeamSize = Vector3(width along Axis, Length, 1), RestClear = beam end height above top at rest }
--       the beam part hangs straight down from Hinge at rest (centre Hinge - (0, Length/2, 0), its X axis along
--       Axis); attrs Hinge, Axis, Period, Arc, Damage. It swings across the middle of the platform and never
--       leaves the footprint.
--   "Wind" = { Type, Zone = { Pos = base centre (y = top), Size = Vector3(X, height, Z), Yaw }, Direction = horizontal
--              unit vector, Force (<= 26), Interval, Warning, Duration }
--       the Zone box is the invisible WindGust volume; attrs Force, Direction, Interval, Warning. The zone sits on
--       the upwind part of the platform and always leaves >= 4.9 studs of calm lee on the same platform downwind.
--   "Cannon" = { Type, Pos = pad centre (step centre, y = top), PadRadius, Target = where the rider's ROOT lands
--                (landing top + RootHeight), LandingPoint = Target - (0, 3, 0) on the landing top, FlightTime,
--                Aim = horizontal unit vector towards the target, Speed, Apex = root peak height above the pad top,
--                LandingIndex = index of the landing step }
--       the pad part carries tag CloudCannon, attrs Target (as given, world), FlightTime. HazardService sets the
--       rider's velocity to v = (Target - rootPos) / t + (0, g t / 2, 0) so the root arrives exactly at Target.
--       Guaranteed: Target is >= 2.5 studs inside the landing top, 1.0 <= FlightTime <= 2.2, launch speed <= 170,
--       peak <= 60 above the pad, 25-60 studs horizontally, nothing in the way (checked for the whole pad).
--   "PlateBridge" = { Type, BridgeNumber = n, Span = { Pos = top centre, Size = Vector3(X, 1, Z), Yaw },
--                     Sides = { Side, Side } }   (Sides[1] belongs to the run-up platform, Sides[2] to this step)
--       Side = { Pos = top centre, Size = Vector3(7, 2, depth), Yaw, From = index of the step it sits beside, Gap,
--                Plate = { Pos = top centre of the plate, Size = Vector3(4, 0.5, 4) } }
--       Span = PlateBridge part (BridgeId = "bridge" .. BridgeNumber), exists only while a plate is held; Sides
--       are walkable platforms reachable from their anchor WITHOUT the bridge; Plate = PressurePlate part (same
--       BridgeId) in the middle of its side platform. Span and sides are solids (separation/headroom apply).
--
-- SCENERY (decoration, never intersects a step or blocks a jump): SceneryItem = {
--   Type, Stage = k (0 for CentralPillar/Puff), Pos = centre of the item's BASE (lowest point), Yaw,
--   Radius = footprint radius, Height = vertical extent above Pos, Seed = int (builder variation), Tint = 1..8 }
--   Types: landmark of the stage theme: Stones CloudWindmill, Beams CrystalSpires, Bounce SkyBalloon, Moving
--   RainbowArc, Spin GiantRing, Storm StormTower, Lightning LightningRods, Vanish LanternCluster, Cannon
--   CloudFortress, Wind KiteFlock, Pendulum BellTower, Plates RuneObelisk, DashGap SkyGate, Gauntlet
--   FloatingVolcano; plus "CentralPillar" (Spiral only, at Layout.Centre) and "Puff" (distant cloud puffs and a
--   cloud sea below the course). Within Radius + 4 horizontally of an item there is no step (vertical band
--   [Pos.Y - 4, Pos.Y + Height + 4] against [step underside, top + Headroom]).
--
-- RULES PROVEN BY ValidateLayout (diff = Config.GetDifficulty(layout.DifficultyId), g = Config.Physics)
--   links    walk: GapMin <= gap <= GapMax, gap <= RunReach(rise), rise <= min(RiseMax, 0.7 * JumpHeight);
--            corner-to-corner links are rejected (the footprints overlap >= 3 studs seen from the jump direction)
--            dash (DashGap/PlateBridge): gap in [DashGapMin, DashGapMax] (defaults 15/19), <= 0.85 * MaxDashGap,
--            > 0.75 * MaxRunGap, rise 0..2, gap <= DashReach(rise), previous step Platform/Checkpoint/Start >= 5 wide
--            (>= 7 for a PlateBridge); cannon: see "Cannon"; bounce: rise up to 9 only from a Bounce pad that reaches
--            drop: rise >= -4 always.      Moving steps satisfy the gap limits over their whole slide.
--   steps never closer than 2 studs (3D box distance) to any non-adjacent step; no step's underside within the lower
--            step's Headroom above another walkable top where footprints overlap (<= 1 stud apart); steps i and j >= i+3
--            are never within 22 studs of each other unless j is out of jump reach of i: more than JumpHeight + 0.5 above
--            it, or more than a Bounce pad's reach (its apex + 0.5 to 1.5) above it when i is a Bounce step (no jump-skips)
--   jumps    free air above every Walk / Dash link: no other solid within 1 stud of the strip a jump flies through (the last
--            4 studs of the take-off step, the gap, the first 3 studs of the landing step, 4 studs wide) may have its
--            underside lower than Config.Course.Clearance + 0.3 above the take-off step's top
--   every step within Config.Course.MaxRadius (horizontal, all corners and the whole slide) of the origin and no lower
--            than origin.Y - 10; exactly diff.Stages checkpoints, the last one right before the Finish; every stage has
--            StepsPerStage steps; sizes in range (see KINDS); hazards on platforms big enough (Pendulum/Wind >= 9)
--   tokens   >= TokensPerStage steps per stage carry a regular token, 1-2 golden tokens per stage, never inside geometry
--   themes   chosen from diff.Themes, no repeated neighbour, a safe opener for stage 1, every stage contains its theme's
--            feature (Cannon -> CannonPad, Plates -> exactly one PlateBridge, Gauntlet -> >= 3 hazard kinds, ...)
-- ======================================================================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)

local CourseLayout = {}
CourseLayout.Version = 2

local PH = Config.Physics

local sqrt, floor, ceil, abs = math.sqrt, math.floor, math.ceil, math.abs
local min, max, sin, cos, huge = math.min, math.max, math.sin, math.cos, math.huge
local RAD = math.pi / 180
local DEG = 180 / math.pi
local atan2 = math.atan2 or function(y, x)
	return math.atan(y, x)
end

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local TH = 2 -- thickness (Size.Y) of every step
local EPS = 0.01
local RISE_EPS = 1e-6 -- rise limits are exact
local ROOT_H = 3 -- HumanoidRootPart height above the feet
local SIZES = { Start = 26, Checkpoint = 16, Finish = 30 } -- fixed footprints (X and Z)
local MAX_DROP = 4
local SKIP_GAP = 22 -- no step j >= i + 3 may be closer than this (edge gap) to step i unless it is out of jump reach
local SKIP_RISE = PH.JumpHeight + 0.5 -- ... "out of jump reach" = higher than a full jump (6.89) plus a margin above step i;
-- above a Bounce step i the limit is the pad's apex instead (see shortcutProblem)
-- Height of the CourseBuilder decor standing on these steps (Start arch: StartBeam top 15.9, bunting 17.0; checkpoint flag
-- pole + orb 9.9; Finish arch: FinishBeam top 17.8). Their Headroom keeps later steps from poking through the decor.
local DECOR_HEAD = { Start = 18, Checkpoint = 10.5, Finish = 18 }
local BODY_R, BODY_UP, BODY_DOWN = 1.5, 2.7, 3.0 -- player body used for cannon flight clearance
local CENTRE_LIMIT = 142 -- the macro planner keeps step centres inside this radius (MaxRadius is checked on corners)
local HEAD_CLEAR = 1.0 -- footprints closer than this count as "overlapping" for the headroom rule
local LATERAL_NEED = 3 -- required overlap (studs) of two consecutive steps seen from the jump direction
-- Jump corridor of a Walk / Dash link a -> b: the strip (CORRIDOR_HALF to each side of the line between the middles of the two
-- steps) from CORRIDOR_BEFORE studs inside a's edge to CORRIDOR_AFTER studs inside b's edge. A full jump out of it needs free
-- air up to Config.Course.Clearance (+ 0.3) above a's top, so no other solid within CORRIDOR_NEAR of the strip may hang lower.
local CORRIDOR_BEFORE, CORRIDOR_AFTER, CORRIDOR_HALF, CORRIDOR_NEAR = 4, 3, 2, 1
local MAX_PROBLEMS = 80

local KINDS = {
	Start = true, Finish = true, Checkpoint = true, Platform = true, Beam = true, Moving = true,
	Vanishing = true, Bounce = true, SpinBarPlatform = true, StormPlatform = true, LightningPlatform = true,
	PendulumPlatform = true, WindPlatform = true, CannonPad = true, PlateBridge = true, DashGap = true,
}
local HAZARD_OF_KIND = {
	Moving = "Moving", Vanishing = "Vanish", Bounce = "Bounce", SpinBarPlatform = "SpinBar",
	StormPlatform = "Storm", LightningPlatform = "Lightning", PendulumPlatform = "Pendulum",
	WindPlatform = "Wind", CannonPad = "Cannon", PlateBridge = "PlateBridge",
}
local STATIC_RUNUP = { Platform = true, Checkpoint = true, Start = true }
-- the step kind every stage of a theme must contain (Stones/Gauntlet/Beams/Plates have extra rules)
local THEME_FEATURE = {
	Bounce = "Bounce", Moving = "Moving", Spin = "SpinBarPlatform", Storm = "StormPlatform",
	Lightning = "LightningPlatform", Vanish = "Vanishing", Cannon = "CannonPad", Wind = "WindPlatform",
	Pendulum = "PendulumPlatform", Plates = "PlateBridge", DashGap = "DashGap", Beams = "Beam",
}

local THEME_NAMES = {
	Stones = "Cloud Steps", Beams = "Balance Beams", Bounce = "Bouncy Meadow", Moving = "Drifting Clouds",
	Spin = "Whirlwind Alley", Storm = "Rain Run", Lightning = "Thunder Ridge", Vanish = "Fading Puffs",
	Cannon = "Cannon Canyon", Wind = "Gale Gardens", Pendulum = "Swinging Bells", Plates = "Teamwork Chasm",
	DashGap = "Leap of Faith", Gauntlet = "The Gauntlet",
}
-- scenery landmark per stage theme (CourseBuilder builds them from parts)
local LANDMARK_OF_THEME = {
	Stones = "CloudWindmill", Beams = "CrystalSpires", Bounce = "SkyBalloon", Moving = "RainbowArc",
	Spin = "GiantRing", Storm = "StormTower", Lightning = "LightningRods", Vanish = "LanternCluster",
	Cannon = "CloudFortress", Wind = "KiteFlock", Pendulum = "BellTower", Plates = "RuneObelisk",
	DashGap = "SkyGate", Gauntlet = "FloatingVolcano",
}
-- { Radius lo, hi, Height lo, hi } footprint radius and vertical size of each landmark
local LANDMARK_SIZE = {
	CloudWindmill = { 16, 22, 26, 34 }, CrystalSpires = { 12, 18, 22, 36 }, SkyBalloon = { 9, 12, 24, 30 },
	RainbowArc = { 22, 30, 20, 28 }, GiantRing = { 16, 22, 32, 44 }, StormTower = { 16, 22, 36, 48 },
	LightningRods = { 8, 12, 24, 34 }, LanternCluster = { 8, 12, 18, 26 }, CloudFortress = { 18, 26, 20, 30 },
	KiteFlock = { 12, 16, 22, 30 }, BellTower = { 9, 12, 30, 38 }, RuneObelisk = { 8, 11, 22, 30 },
	SkyGate = { 14, 18, 26, 34 }, FloatingVolcano = { 16, 22, 22, 30 },
}
local SCENERY_TYPES = { CentralPillar = true, Puff = true }
for _, id in pairs(LANDMARK_OF_THEME) do
	SCENERY_TYPES[id] = true
end

-- Per-difficulty-tier numbers (index = position in Config.Difficulties: 1 Easy .. 5 Saint).
local TIER = {
	SpinSpeed = { { 40, 60 }, { 55, 75 }, { 70, 100 }, { 90, 130 }, { 105, 148 } },
	SpinDamage = { 8, 10, 14, 18, 22 },
	StormDPS = { 4, 5, 7, 10, 13 },
	LightningDamage = { 16, 20, 24, 28, 34 },
	LightningInterval = { 6, 5.5, 4.6, 4.0, 3.6 },
	LightningWarning = { 1.8, 1.6, 1.4, 1.2, 1.1 },
	VanishDelay = { 1.6, 1.3, 1.1, 0.95, 0.85 },
	VanishReturn = { 3.0, 3.2, 3.6, 4.0, 4.4 },
	BouncePower = { 70, 72, 75, 78, 80 },
	BounceSpeed = { 22, 23, 24, 25, 26 },
	MoveWidth = { { 5, 7 }, { 6, 9 }, { 7, 10 }, { 7, 10 }, { 7, 10 } },
	MovePeriod = { { 3.6, 4.4 }, { 3.0, 3.8 }, { 2.8, 3.4 }, { 2.6, 3.2 }, { 2.5, 3.0 } },
	PendDamage = { 12, 15, 19, 23, 28 },
	PendPeriod = { { 3.6, 4.2 }, { 3.2, 3.8 }, { 2.8, 3.4 }, { 2.5, 3.0 }, { 2.3, 2.8 } },
	PendArc = { { 28, 40 }, { 30, 42 }, { 34, 48 }, { 38, 54 }, { 42, 60 } },
	WindForce = { 12, 14, 18, 22, 26 },
	WindInterval = { 7, 6, 5, 4.5, 4 },
	WindWarning = { 1.8, 1.6, 1.4, 1.2, 1.0 },
	GoldenPerStage = { { 1, 1 }, { 1, 2 }, { 1, 2 }, { 2, 2 }, { 2, 2 } },
}

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

local function snap(v)
	return floor(v * 2 + 0.5) / 2
end

local function wrap180(a)
	a = a % 360
	if a > 180 then
		a = a - 360
	end
	return a
end

local function hypot(x, z)
	return sqrt(x * x + z * z)
end

local function tierOf(diff)
	for i, d in ipairs(Config.Difficulties) do
		if d.Id == diff.Id then
			return i
		end
	end
	return 1
end

local function byTier(tbl, tier)
	return tbl[min(tier, #tbl)]
end

-- weight of `id` inside a { id = weight } table (0 when absent)
local function weightIn(tbl, id)
	local w = tbl and tbl[id]
	if type(w) == "number" and w > 0 then
		return w
	end
	return 0
end

local function weightedPick(rng, list, weightOf)
	local total = 0
	for _, id in ipairs(list) do
		total = total + weightOf(id)
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:Float(0, total)
	for _, id in ipairs(list) do
		local w = weightOf(id)
		if w > 0 then
			if roll <= w then
				return id
			end
			roll = roll - w
		end
	end
	for i = #list, 1, -1 do
		if weightOf(list[i]) > 0 then
			return list[i]
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Physics model shared by generator and validator
--   * a full-power jump to a step `rise` studs higher stays airborne airTime(rise)
--   * running covers RunSpeed * airTime; runReach keeps a 10% safety factor and 1.5 studs of margin
--   * a dash adds Config.Physics.DashBonus studs; dashReach keeps a 15% safety factor
----------------------------------------------------------------------
local function airTime(rise)
	if rise < 0 then
		rise = 0
	end
	local disc = PH.JumpPower * PH.JumpPower - 2 * PH.Gravity * rise
	if disc < 0 then
		return 0
	end
	return (PH.JumpPower + sqrt(disc)) / PH.Gravity
end

local function runReach(rise)
	return 0.9 * PH.RunSpeed * airTime(rise) - 1.5
end

local function dashReach(rise)
	return 0.85 * (PH.RunSpeed * airTime(rise) + PH.DashBonus)
end

local function dashRange(diff)
	local lo = diff.DashGapMin or 15
	local hi = diff.DashGapMax or 19
	hi = min(hi, 0.85 * PH.MaxDashGap)
	lo = max(lo, PH.MaxRunGap * 0.75 + 0.5)
	if lo > hi then
		lo = hi
	end
	return lo, hi
end

-- Horizontal studs a bounce pad launch covers before it descends through `rise + 0.3` (8% safety).
local function bounceReach(power, speed, rise)
	local disc = power * power - 2 * PH.Gravity * (rise + 0.3)
	if disc < 0 then
		return -1
	end
	local t = (power + sqrt(disc)) / PH.Gravity
	return 0.92 * speed * t
end

local function riseCapOf(diff)
	return min(diff.RiseMax, PH.JumpHeight * 0.7)
end

-- shortest time a vanishing step must stay solid so a runner can cross it and jump on
local function minVanishDelay(size)
	local diag = sqrt(size.X * size.X + size.Z * size.Z)
	return 0.3 + diag / PH.RunSpeed
end

----------------------------------------------------------------------
-- Geometry (all numbers; shapes are convex polygons in the XZ plane)
--   shape = { n = vertex count, [1..2n] = x,z pairs, cx, cz = centre, r = bounding radius about the centre }
--   Yaw convention: a step with Yaw = a has local +Z = (sin a, cos a) and local +X = (cos a, -sin a)
--   in world XZ, i.e. CFrame.Angles(0, rad(a), 0).
----------------------------------------------------------------------
local function rectShape(cx, cz, hx, hz, yawRad)
	local c, s = cos(yawRad), sin(yawRad)
	local ax, az = c * hx, -s * hx
	local bx, bz = s * hz, c * hz
	local sh = { n = 4, cx = cx, cz = cz, r = sqrt(hx * hx + hz * hz) }
	sh[1], sh[2] = cx - ax - bx, cz - az - bz
	sh[3], sh[4] = cx + ax - bx, cz + az - bz
	sh[5], sh[6] = cx + ax + bx, cz + az + bz
	sh[7], sh[8] = cx - ax + bx, cz - az + bz
	return sh
end

-- convex hull (Andrew monotone chain) of the points in `pts` (flat x,z array with n points)
local function hullShape(pts, n, cx, cz)
	local idx = {}
	for i = 1, n do
		idx[i] = i
	end
	table.sort(idx, function(a, b)
		local ax, bx = pts[2 * a - 1], pts[2 * b - 1]
		if ax ~= bx then
			return ax < bx
		end
		return pts[2 * a] < pts[2 * b]
	end)
	local function cross(o, a, b)
		return (pts[2 * a - 1] - pts[2 * o - 1]) * (pts[2 * b] - pts[2 * o])
			- (pts[2 * a] - pts[2 * o]) * (pts[2 * b - 1] - pts[2 * o - 1])
	end
	local hull = {}
	for _, i in ipairs(idx) do
		while #hull >= 2 and cross(hull[#hull - 1], hull[#hull], i) <= 0 do
			hull[#hull] = nil
		end
		hull[#hull + 1] = i
	end
	local lower = #hull
	for k = #idx - 1, 1, -1 do
		local i = idx[k]
		while #hull > lower and cross(hull[#hull - 1], hull[#hull], i) <= 0 do
			hull[#hull] = nil
		end
		hull[#hull + 1] = i
	end
	hull[#hull] = nil
	local sh = { n = #hull, cx = cx, cz = cz, r = 0 }
	for k, i in ipairs(hull) do
		local x, z = pts[2 * i - 1], pts[2 * i]
		sh[2 * k - 1], sh[2 * k] = x, z
		local d = hypot(x - cx, z - cz)
		if d > sh.r then
			sh.r = d
		end
	end
	return sh
end

-- footprint of a rectangle sliding from (cx, cz) to (cx + dx, cz + dz)
local function sweptShape(cx, cz, dx, dz, hx, hz, yawRad)
	local a = rectShape(cx, cz, hx, hz, yawRad)
	local b = rectShape(cx + dx, cz + dz, hx, hz, yawRad)
	local pts = {}
	for i = 1, 8 do
		pts[i] = a[i]
		pts[8 + i] = b[i]
	end
	return hullShape(pts, 8, cx + dx * 0.5, cz + dz * 0.5)
end

local function ptSeg2(px, pz, ax, az, bx, bz)
	local dx, dz = bx - ax, bz - az
	local l2 = dx * dx + dz * dz
	local t = 0
	if l2 > 1e-12 then
		t = ((px - ax) * dx + (pz - az) * dz) / l2
		if t < 0 then
			t = 0
		elseif t > 1 then
			t = 1
		end
	end
	local ex, ez = ax + t * dx - px, az + t * dz - pz
	return ex * ex + ez * ez
end

-- true when the two convex polygons intersect (separating axis test)
local function shapesOverlap(A, B)
	for pass = 1, 2 do
		local S, T = A, B
		if pass == 2 then
			S, T = B, A
		end
		local sn, tn = S.n, T.n
		for i = 1, sn do
			local j = i % sn + 1
			local x1, z1, x2, z2 = S[2 * i - 1], S[2 * i], S[2 * j - 1], S[2 * j]
			local nx, nz = z2 - z1, x1 - x2
			local smin, smax = huge, -huge
			for k = 1, sn do
				local d = nx * S[2 * k - 1] + nz * S[2 * k]
				if d < smin then
					smin = d
				end
				if d > smax then
					smax = d
				end
			end
			local tmin, tmax = huge, -huge
			for k = 1, tn do
				local d = nx * T[2 * k - 1] + nz * T[2 * k]
				if d < tmin then
					tmin = d
				end
				if d > tmax then
					tmax = d
				end
			end
			if smax < tmin or tmax < smin then
				return false
			end
		end
	end
	return true
end

-- Euclidean distance between two convex polygons (0 when they overlap). With `cut`, any answer >= cut
-- may be a lower bound instead of the exact value (fast reject by bounding circles).
local function shapeDist(A, B, cut)
	local ddx, ddz = A.cx - B.cx, A.cz - B.cz
	local cd = sqrt(ddx * ddx + ddz * ddz) - A.r - B.r
	if cut and cd > cut then
		return cd
	end
	if shapesOverlap(A, B) then
		return 0
	end
	local best = huge
	local an, bn = A.n, B.n
	for i = 1, an do
		local px, pz = A[2 * i - 1], A[2 * i]
		for j = 1, bn do
			local k = j % bn + 1
			local d = ptSeg2(px, pz, B[2 * j - 1], B[2 * j], B[2 * k - 1], B[2 * k])
			if d < best then
				best = d
			end
		end
	end
	for i = 1, bn do
		local px, pz = B[2 * i - 1], B[2 * i]
		for j = 1, an do
			local k = j % an + 1
			local d = ptSeg2(px, pz, A[2 * j - 1], A[2 * j], A[2 * k - 1], A[2 * k])
			if d < best then
				best = d
			end
		end
	end
	return sqrt(best)
end

-- distance from a point to a convex polygon (0 inside)
local function pointDist(px, pz, S)
	local pos, neg = false, false
	local best = huge
	local n = S.n
	for i = 1, n do
		local j = i % n + 1
		local ax, az, bx, bz = S[2 * i - 1], S[2 * i], S[2 * j - 1], S[2 * j]
		local cr = (bx - ax) * (pz - az) - (bz - az) * (px - ax)
		if cr > 0 then
			pos = true
		elseif cr < 0 then
			neg = true
		end
		local d = ptSeg2(px, pz, ax, az, bx, bz)
		if d < best then
			best = d
		end
	end
	if not (pos and neg) then
		return 0
	end
	return sqrt(best)
end

local function shapeRadius(S)
	local m = 0
	for i = 1, S.n do
		local d = hypot(S[2 * i - 1], S[2 * i])
		if d > m then
			m = d
		end
	end
	return m
end

-- min/max projection of a shape onto the axis (ux, uz)
local function project(S, ux, uz)
	local lo, hi = huge, -huge
	for i = 1, S.n do
		local d = ux * S[2 * i - 1] + uz * S[2 * i]
		if d < lo then
			lo = d
		end
		if d > hi then
			hi = d
		end
	end
	return lo, hi
end

-- Geometry record of a step-like table ({Pos, Size, Yaw, Kind, Hazard, Headroom}).
local function makeGeo(step)
	local pos, size = step.Pos, step.Size
	local yaw = (step.Yaw or 0) * RAD
	local g = {}
	g.cx, g.cz = pos.X, pos.Z
	g.hx, g.hz = size.X * 0.5, size.Z * 0.5
	g.yaw = yaw
	g.c, g.s = cos(yaw), sin(yaw)
	g.top = pos.Y
	g.th = size.Y
	g.bot = pos.Y - size.Y
	g.head = step.Headroom or Config.Course.Clearance
	g.kind = step.Kind
	g.rect = rectShape(g.cx, g.cz, g.hx, g.hz, yaw)
	g.hull = g.rect
	g.mx, g.mz = g.cx, g.cz -- middle of the sweep (== centre for static steps)
	local h = step.Hazard
	if step.Kind == "Moving" and type(h) == "table" and h.EndOffset then
		g.sx, g.sz = h.EndOffset.X, h.EndOffset.Z
		g.hull = sweptShape(g.cx, g.cz, g.sx, g.sz, g.hx, g.hz, yaw)
		g.mx, g.mz = g.cx + g.sx * 0.5, g.cz + g.sz * 0.5
	end
	return g
end

-- footprint of a step at fraction t (0..1) of its sweep
local function rectAt(g, t)
	if g.sx then
		return rectShape(g.cx + g.sx * t, g.cz + g.sz * t, g.hx, g.hz, g.yaw)
	end
	return g.rect
end

local function toWorld(g, lx, lz)
	return g.cx + lx * g.c + lz * g.s, g.cz - lx * g.s + lz * g.c
end

local function toLocal(g, x, z)
	local dx, dz = x - g.cx, z - g.cz
	return dx * g.c - dz * g.s, dx * g.s + dz * g.c
end

-- (min, max) edge-to-edge gap between two steps over every position of their sweeps
-- (at most one of the two may be a Moving step; two moving steps use their hulls).
local function gapRange(ga, gb)
	if not ga.sx and not gb.sx then
		local d = shapeDist(ga.rect, gb.rect)
		return d, d
	end
	local mover, still = ga, gb
	if not ga.sx then
		mover, still = gb, ga
	end
	if mover.sx and still.sx then
		local d = shapeDist(ga.hull, gb.hull)
		return d, huge
	end
	local function at(t)
		return shapeDist(rectAt(mover, t), still.rect)
	end
	local d0, d1 = at(0), at(1)
	local hi = max(d0, d1)
	-- distance is convex along a straight sweep: ternary search for the closest approach
	local a, b = 0, 1
	local lo = min(d0, d1)
	for _ = 1, 18 do
		local m1 = a + (b - a) / 3
		local m2 = b - (b - a) / 3
		local f1, f2 = at(m1), at(m2)
		if f1 < lo then
			lo = f1
		end
		if f2 < lo then
			lo = f2
		end
		if f1 < f2 then
			b = m2
		else
			a = m1
		end
	end
	return lo, hi
end

-- Overlap (studs) of the two footprints seen from the jump direction and the overlap a clean
-- straight run-and-jump needs. Both shapes are tested at the ends of their sweeps.
local function lateralOverlapOK(ga, gb)
	local function test(A, B)
		local dx, dz = B.cx - A.cx, B.cz - A.cz
		local d = hypot(dx, dz)
		if d < 1e-6 then
			return true
		end
		local ux, uz = -dz / d, dx / d
		local amin, amax = project(A, ux, uz)
		local bmin, bmax = project(B, ux, uz)
		local ov = min(amax, bmax) - max(amin, bmin)
		local need = min(LATERAL_NEED, 0.5 * min(amax - amin, bmax - bmin))
		return ov >= need - EPS
	end
	local ta = ga.sx and { 0, 1 } or { 0 }
	local tb = gb.sx and { 0, 1 } or { 0 }
	for _, t1 in ipairs(ta) do
		for _, t2 in ipairs(tb) do
			if not test(rectAt(ga, t1), rectAt(gb, t2)) then
				return false
			end
		end
	end
	return true
end

----------------------------------------------------------------------
-- Rules (the SAME functions prove a finished layout and filter every candidate the generator tries)
----------------------------------------------------------------------
local function isVec(v)
	return typeof(v) == "Vector3"
end

local function isNum(v)
	return type(v) == "number" and v == v and v > -1e9 and v < 1e9
end

local function minDimOf(size)
	return min(size.X, size.Z)
end

-- allowed Size.X / Size.Z ranges of a step kind: loX, hiX, loZ, hiZ
local function sizeBounds(kind, diff)
	local lo, hi = diff.PlatformMin, diff.PlatformMax
	if kind == "Start" then
		return 24, 40, 24, 40
	elseif kind == "Checkpoint" then
		return 14, 24, 14, 24
	elseif kind == "Finish" then
		return 28, 44, 28, 44
	elseif kind == "Beam" then
		return 2.5, 4, 14, 30
	elseif kind == "PendulumPlatform" or kind == "WindPlatform" then
		return 9, 15, 9, 15
	elseif kind == "CannonPad" then
		local a, b = max(lo, 7), max(hi, 7)
		return a, b, a, b
	elseif kind == "PlateBridge" then
		local a = max(lo, 7)
		return a, max(hi, a), a, max(hi, a)
	end
	return lo, hi, lo, hi
end

local function inFootprint(g, x, z, margin)
	local lx, lz = toLocal(g, x, z)
	return abs(lx) <= g.hx - margin + EPS and abs(lz) <= g.hz - margin + EPS
end

-- Launch velocity of the cannon for a rider whose root starts at (px, pz) on the pad.
local function cannonVelocity(padTop, px, pz, target, t)
	local g = PH.Gravity
	local py = padTop + ROOT_H
	return (target.X - px) / t, (target.Y - py) / t + g * t / 2, (target.Z - pz) / t, py
end

-- the five launch positions a rider can have on the pad (centre + four points of the pad circle)
local function cannonLaunchPoints(h)
	local r = h.PadRadius
	local x, z = h.Pos.X, h.Pos.Z
	return { { x, z }, { x + r, z }, { x - r, z }, { x, z + r }, { x, z - r } }
end

-- samples (every 0.02 s) of the five flight arcs { {x, y, z}, ... } (excluding the launch point itself)
local function cannonArcSamples(h, padTop)
	local out = {}
	local g = PH.Gravity
	local t = h.FlightTime
	local count = max(20, ceil(t / 0.02))
	for _, lp in ipairs(cannonLaunchPoints(h)) do
		local vx, vy, vz, py = cannonVelocity(padTop, lp[1], lp[2], h.Target, t)
		for k = 1, count do
			local tau = t * k / count
			out[#out + 1] = { lp[1] + vx * tau, py + vy * tau - 0.5 * g * tau * tau, lp[2] + vz * tau }
		end
	end
	return out
end

-- does the body of a rider at one arc sample touch a solid?
local function bodyHits(sample, s)
	local y = sample[2]
	if y + BODY_UP <= s.g.bot or y - BODY_DOWN >= s.g.top then
		return false
	end
	local hull = s.g.hull
	local dx, dz = sample[1] - hull.cx, sample[3] - hull.cz
	if hypot(dx, dz) - hull.r > BODY_R + 0.4 then
		return false
	end
	return pointDist(sample[1], sample[3], hull) < BODY_R + 0.4
end

local function sizeProblem(step, diff)
	local lx, hx, lz, hz = sizeBounds(step.Kind, diff)
	local sx, sy, sz = step.Size.X, step.Size.Y, step.Size.Z
	if sx < lx - EPS or sx > hx + EPS or sz < lz - EPS or sz > hz + EPS then
		return string.format("%s size %.1fx%.1f outside [%.1f-%.1f] x [%.1f-%.1f]", step.Kind, sx, sz, lx, hx, lz, hz)
	end
	if sy < 1 - EPS or sy > 6 then
		return string.format("thickness %.2f is not sensible", sy)
	end
	return nil
end

-- Rules of the cannon link pad -> landing (a = pad, b = landing).
local function cannonLinkProblem(diff, a, ga, b, gb, lo, hi, rise)
	local h = a.Hazard
	if type(h) ~= "table" or h.Type ~= "Cannon" then
		return "CannonPad has no Cannon hazard"
	end
	if not (isVec(h.Pos) and isVec(h.Target) and isVec(h.LandingPoint) and isNum(h.FlightTime) and isNum(h.PadRadius)) then
		return "Cannon hazard is missing Pos/Target/LandingPoint/FlightTime/PadRadius"
	end
	if b.Link ~= "Cannon" then
		return "landing step must have Link = Cannon"
	end
	if h.LandingIndex ~= b.Index then
		return "Cannon.LandingIndex does not name the next step"
	end
	if b.Kind ~= "Platform" or gb.sx then
		return "a cannon lands on a plain Platform"
	end
	if minDimOf(b.Size) < 7 - EPS then
		return "cannon landing island is smaller than 7x7"
	end
	if h.FlightTime < 1.0 - EPS or h.FlightTime > 2.2 + EPS then
		return string.format("cannon flight time %.2f outside [1.0, 2.2]", h.FlightTime)
	end
	local lx, lz = toLocal(gb, h.Target.X, h.Target.Z)
	if abs(lx) > gb.hx - 2.5 + EPS or abs(lz) > gb.hz - 2.5 + EPS then
		return string.format("cannon target (%.1f, %.1f) is not 2.5 studs inside the landing top", lx, lz)
	end
	if abs(h.Target.Y - (b.Pos.Y + ROOT_H)) > 0.05 or abs(h.LandingPoint.Y - b.Pos.Y) > 0.05 then
		return "cannon Target/LandingPoint height does not match the landing top"
	end
	if hypot(h.LandingPoint.X - h.Target.X, h.LandingPoint.Z - h.Target.Z) > 0.05 then
		return "cannon LandingPoint is not below Target"
	end
	if hypot(h.Pos.X - ga.cx, h.Pos.Z - ga.cz) > 0.5 or abs(h.Pos.Y - a.Pos.Y) > EPS then
		return "cannon pad is not at the middle of its step"
	end
	if h.PadRadius < 2 - EPS or h.PadRadius > min(minDimOf(a.Size) * 0.5 - 1, 4) + EPS then
		return "cannon pad radius does not fit its step"
	end
	local hdist = hypot(h.Target.X - h.Pos.X, h.Target.Z - h.Pos.Z)
	if hdist < 25 - EPS or hdist > 60 + EPS then
		return string.format("cannon flies %.1f studs (needs 25-60)", hdist)
	end
	if lo < dashReach(max(rise, 0)) + 1 then
		return string.format("cannon gap %.1f can be crossed without the cannon", lo)
	end
	if rise < -3 - RISE_EPS or rise > 10.5 + RISE_EPS then
		return string.format("cannon landing is %.1f above the pad (limit -3..10.5)", rise)
	end
	for idx, lp in ipairs(cannonLaunchPoints(h)) do
		local vx, vy, vz = cannonVelocity(a.Pos.Y, lp[1], lp[2], h.Target, h.FlightTime)
		local speed = sqrt(vx * vx + vy * vy + vz * vz)
		local apex = ROOT_H + (vy > 0 and vy * vy / (2 * PH.Gravity) or 0)
		if speed > 170 + EPS then
			return string.format("cannon launch speed %.1f exceeds 170", speed)
		end
		if apex > 60 + EPS then
			return string.format("cannon peak %.1f above the pad exceeds 60", apex)
		end
		if idx == 1 then
			if not isNum(h.Speed) or abs(h.Speed - speed) > 0.5 or not isNum(h.Apex) or abs(h.Apex - apex) > 0.5 then
				return "cannon Speed/Apex fields do not match the ballistics"
			end
			local aim = h.Aim
			if not isVec(aim) or abs(aim.Y) > EPS or abs(hypot(aim.X, aim.Z) - 1) > 0.01 then
				return "cannon Aim must be a horizontal unit vector"
			end
			local want = hypot(vx, vz)
			if want > 0.001 and (aim.X * vx + aim.Z * vz) / want < 0.99 then
				return "cannon Aim does not point at the target"
			end
		end
	end
	return nil
end

-- Rules of the link between two consecutive steps (a = previous, b = this one).
local function pairProblem(diff, a, ga, b, gb)
	local rise = b.Pos.Y - a.Pos.Y
	if rise < -MAX_DROP - RISE_EPS then
		return string.format("drops %.2f (limit -%d)", rise, MAX_DROP)
	end
	if ga.sx and gb.sx then
		return "two moving steps are adjacent"
	end
	local lo, hi = gapRange(ga, gb)
	if not isNum(b.Gap) or abs(b.Gap - hi) > 0.05 then
		return string.format("Gap field %s does not match the geometry (%.2f)", tostring(b.Gap), hi)
	end
	if a.Kind == "CannonPad" then
		return cannonLinkProblem(diff, a, ga, b, gb, lo, hi, rise)
	end
	if b.Link == "Cannon" then
		return "only the step after a CannonPad may have Link = Cannon"
	end
	if b.Kind == "DashGap" or b.Kind == "PlateBridge" then
		local dlo, dhi = dashRange(diff)
		if b.Link ~= "Dash" then
			return "dash-gap steps must have Link = Dash"
		end
		if lo < dlo - EPS or hi > dhi + EPS then
			return string.format("dash gap %.2f..%.2f outside [%.1f, %.1f]", lo, hi, dlo, dhi)
		end
		if hi > 0.85 * PH.MaxDashGap + EPS then
			return string.format("dash gap %.2f exceeds 0.85 * MaxDashGap", hi)
		end
		if lo <= PH.MaxRunGap * 0.75 then
			return string.format("dash gap %.2f does not need a dash", lo)
		end
		if rise < -RISE_EPS or rise > 2 + RISE_EPS then
			return string.format("dash gap rise %.2f outside [0, 2]", rise)
		end
		if hi > dashReach(rise) + EPS then
			return string.format("dash gap %.2f exceeds dash reach %.2f", hi, dashReach(rise))
		end
		if not STATIC_RUNUP[a.Kind] or ga.sx or gb.sx then
			return "a dash gap needs a static run-up platform (" .. tostring(a.Kind) .. ")"
		end
		local need = 5
		if b.Kind == "PlateBridge" then
			need = 7
		end
		if minDimOf(a.Size) < need - EPS then
			return "the run-up platform before a dash gap is too small"
		end
		local yawLimit = 20
		if b.Kind == "PlateBridge" then
			yawLimit = 0.5
		end
		if abs(wrap180((b.Yaw or 0) - (a.Yaw or 0))) > yawLimit then
			return "dash-gap step is not aligned with its run-up platform"
		end
		if not lateralOverlapOK(ga, gb) then
			return "dash-gap step is not in front of its run-up platform"
		end
		return nil
	end
	-- ordinary run-and-jump link
	if lo < diff.GapMin - EPS or hi > diff.GapMax + EPS then
		return string.format("gap %.2f..%.2f outside [%s, %s]", lo, hi, tostring(diff.GapMin), tostring(diff.GapMax))
	end
	local cap = riseCapOf(diff)
	local assisted = rise > cap + RISE_EPS
	if not assisted and hi > runReach(rise) + EPS then
		return string.format("gap %.2f exceeds run-jump reach %.2f for rise %.2f", hi, runReach(rise), rise)
	end
	local expectLink = "Walk"
	if assisted then
		-- only a bounce pad can lift the rider this high
		local h = a.Hazard
		if a.Kind ~= "Bounce" or type(h) ~= "table" or not isVec(h.Pos) or not isNum(h.Power) or not isNum(h.LaunchSpeed) then
			return string.format("rises %.2f (cap %.2f) without a bounce pad", rise, cap)
		end
		if rise > 9 + RISE_EPS then
			return string.format("bounce rise %.2f exceeds 9", rise)
		end
		local near = pointDist(h.Pos.X, h.Pos.Z, gb.hull)
		local reach = bounceReach(h.Power, h.LaunchSpeed, rise)
		if near > reach + EPS then
			return string.format("bounce pad reaches %.1f but the next step starts %.1f away", reach, near)
		end
		expectLink = "Bounce"
	end
	if b.Link ~= expectLink then
		return "Link should be " .. expectLink .. " but is " .. tostring(b.Link)
	end
	if not lateralOverlapOK(ga, gb) then
		return "consecutive steps only meet corner to corner"
	end
	return nil
end

-- Rules of one step's own hazard / hint / size. `prev`, `gPrev` are the previous step (may be nil for Start).
local function hazardProblem(diff, step, g, prev, gPrev)
	local kind = step.Kind
	local h = step.Hazard
	local expectType = HAZARD_OF_KIND[kind]
	if not expectType then
		if h ~= nil then
			return kind .. " must not carry a Hazard"
		end
	else
		if type(h) ~= "table" or h.Type ~= expectType then
			return kind .. " needs Hazard.Type = " .. expectType
		end
	end
	if not isNum(step.Headroom) or step.Headroom < Config.Course.Clearance - EPS then
		return "Headroom is missing or below Config.Course.Clearance"
	end
	if DECOR_HEAD[kind] and step.Headroom < DECOR_HEAD[kind] - EPS then
		return kind .. " Headroom must cover its decor (" .. DECOR_HEAD[kind] .. ")"
	end
	local minDim = minDimOf(step.Size)

	if kind == "Moving" then
		if not isVec(h.EndOffset) or not isNum(h.Period) then
			return "Moving lacks EndOffset/Period"
		end
		local travel = hypot(h.EndOffset.X, h.EndOffset.Z)
		if abs(h.EndOffset.Y) > EPS or travel < 3.5 - EPS then
			return "Moving must slide >= 3.5 studs horizontally"
		end
		if h.Period < 2 - EPS or travel / h.Period > 4.2 + EPS then
			return string.format("Moving is too fast (%.1f studs in %.2fs)", travel, h.Period)
		end
	elseif kind == "Vanishing" then
		if not isNum(h.VanishDelay) or not isNum(h.ReturnDelay) then
			return "Vanish lacks delays"
		end
		if h.VanishDelay < minVanishDelay(step.Size) - EPS then
			return string.format("Vanish after %.2fs but crossing needs %.2fs", h.VanishDelay, minVanishDelay(step.Size))
		end
		if h.ReturnDelay < h.VanishDelay + 1 - EPS or h.ReturnDelay > 8 then
			return "Vanish ReturnDelay is unfair"
		end
	elseif kind == "Bounce" then
		if not (isNum(h.Power) and isNum(h.LaunchSpeed) and isNum(h.PadSize) and isNum(h.Apex) and isVec(h.Pos)) then
			return "Bounce lacks Power/LaunchSpeed/PadSize/Apex/Pos"
		end
		if h.Power < 50 or h.Power > 90 or h.LaunchSpeed < 18 or h.LaunchSpeed > 30 then
			return "Bounce Power/LaunchSpeed out of range"
		end
		if h.PadSize < 2.5 - EPS or h.PadSize > minDim * 0.5 + EPS then
			return "Bounce pad does not fit its step"
		end
		if hypot(h.Pos.X - g.cx, h.Pos.Z - g.cz) > 0.5 or abs(h.Pos.Y - step.Pos.Y) > EPS then
			return "Bounce pad is not at the middle of its step"
		end
		if abs(h.Apex - h.Power * h.Power / (2 * PH.Gravity)) > 0.2 or step.Headroom < h.Apex + 1 - EPS then
			return "Bounce Headroom must exceed the bounce apex"
		end
	elseif kind == "SpinBarPlatform" then
		if not (isNum(h.Speed) and isNum(h.Damage) and isNum(h.Length) and isNum(h.Height) and isVec(h.Pos)) then
			return "SpinBar lacks Speed/Damage/Length/Height/Pos"
		end
		if h.Speed == 0 or abs(h.Speed) > 150 or h.Damage <= 0 then
			return "SpinBar Speed/Damage out of range"
		end
		if h.Count ~= 1 and h.Count ~= 2 then
			return "SpinBar Count must be 1 or 2"
		end
		if h.Length < 3 - EPS or h.Length > minDim - 2.2 + EPS then
			return string.format("SpinBar length %.1f does not fit a %.1f platform", h.Length, minDim)
		end
		if hypot(h.Pos.X - g.cx, h.Pos.Z - g.cz) > 0.5 or abs(h.Pos.Y - step.Pos.Y) > EPS then
			return "SpinBar hub is not at the middle of its step"
		end
		if h.Height < 0.5 or h.Height > 2 then
			return "SpinBar Height out of range"
		end
	elseif kind == "StormPlatform" then
		local b = h.Box
		if not isNum(h.DPS) or h.DPS <= 0 or type(b) ~= "table" or not isVec(b.Pos) or not isVec(b.Size) or not isNum(b.Yaw) then
			return "Storm lacks DPS/Box"
		end
		if b.Size.Y < 4 or b.Size.Y > 9 or b.Size.X < step.Size.X - EPS or b.Size.Z < step.Size.Z - EPS then
			return "Storm box must cover the footprint and be 4-9 tall"
		end
		if step.Headroom < b.Size.Y + 3.5 - EPS then
			return "Storm Headroom must exceed the cloud height + 3.5"
		end
	elseif kind == "LightningPlatform" then
		if not (isNum(h.Damage) and isNum(h.Interval) and isNum(h.Warning)) or type(h.Zones) ~= "table" then
			return "Lightning lacks Damage/Interval/Warning/Zones"
		end
		if h.Interval < 2.5 or h.Warning < 0.8 or h.Warning > h.Interval - 1.2 + EPS then
			return string.format("Lightning timing %.1f / %.1f is unfair", h.Interval, h.Warning)
		end
		if #h.Zones < 1 or #h.Zones > 3 then
			return "Lightning needs 1-3 zones"
		end
		local zs = {}
		for i, z in ipairs(h.Zones) do
			if type(z) ~= "table" or not isVec(z.Pos) or not isNum(z.Radius) or z.Radius < 1.5 then
				return "Lightning zone is malformed"
			end
			local lx, lz = toLocal(g, z.Pos.X, z.Pos.Z)
			if abs(lx) + z.Radius > g.hx + EPS or abs(lz) + z.Radius > g.hz + EPS or abs(z.Pos.Y - step.Pos.Y) > EPS then
				return "Lightning zone leaves the platform"
			end
			zs[i] = { lx, lz, z.Radius }
		end
		-- a safe spot: somewhere on the platform clear of every strike disc by 1.2 studs
		local safe = false
		local x = -g.hx + 0.8
		while x <= g.hx - 0.8 + 1e-6 and not safe do
			local z = -g.hz + 0.8
			while z <= g.hz - 0.8 + 1e-6 do
				local ok = true
				for _, q in ipairs(zs) do
					if hypot(x - q[1], z - q[2]) < q[3] + 1.2 then
						ok = false
						break
					end
				end
				if ok then
					safe = true
					break
				end
				z = z + 0.5
			end
			x = x + 0.5
		end
		if not safe then
			return "Lightning platform has no safe spot"
		end
		if step.Headroom < 12 - EPS then
			return "Lightning Headroom must be >= 12"
		end
	elseif kind == "PendulumPlatform" then
		if not (isVec(h.Hinge) and isVec(h.Axis) and isVec(h.BeamSize) and isNum(h.Arc) and isNum(h.Period)
			and isNum(h.Damage) and isNum(h.Length)) then
			return "Pendulum lacks Hinge/Axis/BeamSize/Arc/Period/Damage/Length"
		end
		if abs(h.Axis.Y) > EPS or abs(hypot(h.Axis.X, h.Axis.Z) - 1) > 0.01 then
			return "Pendulum Axis must be a horizontal unit vector"
		end
		if h.Arc < 20 or h.Arc > 70 or h.Period < 2 or h.Damage <= 0 or h.Length < 4 or h.Length > 9 then
			return "Pendulum Arc/Period/Damage/Length out of range"
		end
		if abs(h.BeamSize.Y - h.Length) > EPS then
			return "Pendulum BeamSize.Y must equal Length"
		end
		local rest = h.Hinge.Y - step.Pos.Y - h.Length
		if rest < 1.0 - EPS then
			return "Pendulum beam hangs lower than 1 stud above the platform"
		end
		if step.Headroom < h.Hinge.Y - step.Pos.Y + 1 - EPS then
			return "Pendulum Headroom must exceed the hinge height"
		end
		local swx, swz = -h.Axis.Z, h.Axis.X
		local ex1, ex2, ez1, ez2 = g.c, -g.s, g.s, g.c
		local es = g.hx * abs(swx * ex1 + swz * ex2) + g.hz * abs(swx * ez1 + swz * ez2)
		local ea = g.hx * abs(h.Axis.X * ex1 + h.Axis.Z * ex2) + g.hz * abs(h.Axis.X * ez1 + h.Axis.Z * ez2)
		local dx, dz = h.Hinge.X - g.cx, h.Hinge.Z - g.cz
		local ps = dx * swx + dz * swz
		local pa = dx * h.Axis.X + dz * h.Axis.Z
		local sweep = h.Length * sin(h.Arc * RAD)
		if abs(ps) + sweep > es - 1.0 + EPS then
			return "Pendulum swings beyond the platform edge"
		end
		if h.BeamSize.X * 0.5 + abs(pa) > ea + EPS then
			return "Pendulum beam is wider than the platform"
		end
	elseif kind == "WindPlatform" then
		local z = h.Zone
		if not (isNum(h.Force) and isNum(h.Interval) and isNum(h.Warning) and isNum(h.Duration) and isVec(h.Direction))
			or type(z) ~= "table" or not isVec(z.Pos) or not isVec(z.Size) or not isNum(z.Yaw) then
			return "Wind lacks Force/Interval/Warning/Duration/Direction/Zone"
		end
		if h.Force < 5 or h.Force > 26 + EPS then
			return string.format("Wind force %.1f outside [5, 26]", h.Force)
		end
		if abs(h.Direction.Y) > EPS or abs(hypot(h.Direction.X, h.Direction.Z) - 1) > 0.01 then
			return "Wind Direction must be a horizontal unit vector"
		end
		if h.Interval < 3 or h.Warning < 0.8 or h.Warning > h.Interval - 1 or h.Duration < 1 or h.Duration > 2 then
			return "Wind timing is unfair"
		end
		if z.Size.X < 3.5 or z.Size.Z < 3.5 or z.Size.Y < 5 or step.Headroom < z.Size.Y + 0.5 - EPS then
			return "Wind zone is too small or Headroom too low"
		end
		local zs = rectShape(z.Pos.X, z.Pos.Z, z.Size.X * 0.5, z.Size.Z * 0.5, z.Yaw * RAD)
		for i = 1, 4 do
			if not inFootprint(g, zs[2 * i - 1], zs[2 * i], 0) then
				return "Wind zone leaves the platform"
			end
		end
		local _, platMax = project(g.rect, h.Direction.X, h.Direction.Z)
		local _, zoneMax = project(zs, h.Direction.X, h.Direction.Z)
		if platMax - zoneMax < 4.9 then
			return string.format("Wind leaves only %.1f studs of calm lee on the platform", platMax - zoneMax)
		end
	elseif kind == "CannonPad" then
		-- link rules live in cannonLinkProblem; only the shape of the hazard is checked here
		if not isVec(h.Pos) or not isNum(h.PadRadius) then
			return "Cannon lacks Pos/PadRadius"
		end
		if step.Headroom < 9 - EPS then
			return "CannonPad Headroom must be >= 9"
		end
	elseif kind == "PlateBridge" then
		if not prev then
			return "PlateBridge has no previous step"
		end
		local sp = h.Span
		if not isNum(h.BridgeNumber) or type(sp) ~= "table" or not isVec(sp.Pos) or not isVec(sp.Size) or not isNum(sp.Yaw)
			or type(h.Sides) ~= "table" or #h.Sides ~= 2 then
			return "PlateBridge lacks BridgeNumber/Span/Sides"
		end
		if abs(sp.Pos.Y - prev.Pos.Y) > EPS or abs(step.Pos.Y - prev.Pos.Y) > EPS then
			return "PlateBridge span is not level with its platforms"
		end
		if abs(wrap180(sp.Yaw - (step.Yaw or 0))) > 0.5 or sp.Size.X < 3 - EPS or sp.Size.Y < 0.5 then
			return "PlateBridge span is malformed"
		end
		local spanShape = rectShape(sp.Pos.X, sp.Pos.Z, sp.Size.X * 0.5, sp.Size.Z * 0.5, sp.Yaw * RAD)
		if shapeDist(spanShape, gPrev.rect) > 0.05 or shapeDist(spanShape, g.rect) > 0.05 then
			return "PlateBridge span does not reach both platforms"
		end
		for _, gg in ipairs({ gPrev, g }) do
			local lx = toLocal(gg, sp.Pos.X, sp.Pos.Z)
			if abs(lx) + sp.Size.X * 0.5 > gg.hx + EPS then
				return "PlateBridge span is wider than the platform it lands on"
			end
		end
		local seen = {}
		local gmax = min(diff.GapMax, runReach(0))
		for _, side in ipairs(h.Sides) do
			if type(side) ~= "table" or not isVec(side.Pos) or not isVec(side.Size) or not isNum(side.Yaw)
				or type(side.Plate) ~= "table" or not isVec(side.Plate.Pos) or not isVec(side.Plate.Size) then
				return "PlateBridge side platform is malformed"
			end
			local anchor, ganchor
			if side.From == prev.Index then
				anchor, ganchor = prev, gPrev
			elseif side.From == step.Index then
				anchor, ganchor = step, g
			end
			if not anchor then
				return "PlateBridge side platform has a bad anchor"
			end
			seen[side.From] = true
			if abs(side.Pos.Y - anchor.Pos.Y) > EPS or abs(wrap180(side.Yaw - (anchor.Yaw or 0))) > 0.5 then
				return "PlateBridge side platform is not level/aligned with its anchor"
			end
			local sg = makeGeo({ Pos = side.Pos, Size = side.Size, Yaw = side.Yaw })
			local d = shapeDist(sg.rect, ganchor.rect)
			if d < diff.GapMin - EPS or d > gmax + EPS or not isNum(side.Gap) or abs(side.Gap - d) > 0.05 then
				return string.format("PlateBridge side platform gap %.2f is not reachable without the bridge", d)
			end
			if minDimOf(side.Size) < 6 - EPS then
				return "PlateBridge side platform is smaller than 6x6"
			end
			local pl = side.Plate
			local lx, lz = toLocal(sg, pl.Pos.X, pl.Pos.Z)
			if abs(lx) > sg.hx - pl.Size.X * 0.5 + EPS or abs(lz) > sg.hz - pl.Size.Z * 0.5 + EPS
				or abs(pl.Pos.Y - (side.Pos.Y + pl.Size.Y)) > EPS then
				return "PlateBridge plate is not on its side platform"
			end
		end
		if not seen[prev.Index] or not seen[step.Index] then
			return "PlateBridge needs one plate before and one after the chasm"
		end
	end

	if kind == "DashGap" or kind == "PlateBridge" then
		local hint = step.DashHint
		if type(hint) ~= "table" or not isVec(hint.Pos) or not isVec(hint.Dir) or hint.From ~= step.Index - 1 then
			return "dash-gap step lacks a DashHint"
		end
		if prev and gPrev then
			if abs(hint.Pos.Y - prev.Pos.Y) > EPS or not inFootprint(gPrev, hint.Pos.X, hint.Pos.Z, 0) then
				return "DashHint is not on the run-up platform"
			end
			if abs(hint.Dir.Y) > EPS or abs(hypot(hint.Dir.X, hint.Dir.Z) - 1) > 0.01 then
				return "DashHint.Dir must be a horizontal unit vector"
			end
			local dx, dz = g.cx - gPrev.cx, g.cz - gPrev.cz
			local d = hypot(dx, dz)
			if d > 0.01 and (dx * hint.Dir.X + dz * hint.Dir.Z) / d < 0.9 then
				return "DashHint does not point at the next step"
			end
		end
	elseif step.DashHint ~= nil then
		return "only dash-gap steps carry a DashHint"
	end
	return nil
end

----------------------------------------------------------------------
-- Solids: everything a rider can stand on (steps, bridge spans, plate side platforms)
----------------------------------------------------------------------
local function makeSolid(stepLike, tag, owner, anchor)
	return { g = makeGeo(stepLike), tag = tag, owner = owner, anchor = anchor }
end

-- side solids of a PlateBridge hazard (span + two plate platforms); tolerant of malformed hazards
local function bridgeSolids(step, out)
	local h = step.Hazard
	if step.Kind ~= "PlateBridge" or type(h) ~= "table" then
		return
	end
	local sp = h.Span
	if type(sp) == "table" and isVec(sp.Pos) and isVec(sp.Size) then
		out[#out + 1] = makeSolid({ Pos = sp.Pos, Size = sp.Size, Yaw = sp.Yaw or 0, Headroom = Config.Course.Clearance },
			"span", step.Index, step.Index - 1)
	end
	if type(h.Sides) == "table" then
		for _, side in ipairs(h.Sides) do
			if type(side) == "table" and isVec(side.Pos) and isVec(side.Size) then
				out[#out + 1] = makeSolid({ Pos = side.Pos, Size = side.Size, Yaw = side.Yaw or 0,
					Headroom = Config.Course.Clearance }, "perch", step.Index, side.From)
			end
		end
	end
end

-- pairs that touch/neighbour by design and are covered by the link rules instead
local function solidsExempt(a, b)
	if a.tag == "step" and b.tag == "step" then
		return abs(a.owner - b.owner) <= 1
	end
	if a.tag ~= "step" and b.tag ~= "step" then
		return a.owner == b.owner
	end
	local step, other = a, b
	if a.tag ~= "step" then
		step, other = b, a
	end
	if other.tag == "span" then
		return step.owner == other.owner or step.owner == other.owner - 1
	end
	return step.owner == other.anchor
end

-- 2 stud separation + headroom between two solids (nil when fine)
local function solidPairProblem(a, b)
	local d = shapeDist(a.g.hull, b.g.hull, 30)
	local gv = max(b.g.bot - a.g.top, a.g.bot - b.g.top)
	if gv < 0 then
		gv = 0
	end
	if sqrt(d * d + gv * gv) < 2 - EPS then
		return "closer than 2 studs"
	end
	if d <= HEAD_CLEAR then
		local hi, lo = a.g, b.g
		if b.g.top > a.g.top then
			hi, lo = b.g, a.g
		end
		if hi.bot - lo.top < lo.head - EPS then
			return string.format("only %.1f studs of headroom above a lower step (needs %.1f)", hi.bot - lo.top, lo.head)
		end
	end
	return nil
end

-- stepping stones further than two steps apart must not allow a jump-skip
local function shortcutProblem(a, b)
	if a.tag ~= "step" or b.tag ~= "step" then
		return nil
	end
	local lo, hi = a, b
	if b.owner < a.owner then
		lo, hi = b, a
	end
	if hi.owner - lo.owner < 3 then
		return nil
	end
	local reach = SKIP_RISE
	if lo.g.kind == "Bounce" then
		-- a pad launches to its apex; its Headroom is ceil(apex + 1), so Headroom - 0.5 is apex + 0.5 (up to 1.5 with the rounding)
		reach = max(reach, lo.g.head - 0.5)
	end
	if hi.g.top - lo.g.top > reach then
		return nil
	end
	local d = shapeDist(lo.g.hull, hi.g.hull, SKIP_GAP + 2)
	if d < SKIP_GAP then
		return string.format("steps %d and %d are only %.1f apart (jump-skip)", lo.owner, hi.owner, d)
	end
	return nil
end

-- distance from the middle of g's sweep to its edge along the horizontal unit vector (dx, dz)
local function exitDistOf(g, dx, dz)
	local lux = dx * g.c - dz * g.s
	local luz = dx * g.s + dz * g.c
	return min(g.hx / max(abs(lux), 1e-6), g.hz / max(abs(luz), 1e-6))
end

-- Jump corridor of the link from step `aIndex` (geometry ga) to step `bIndex` (gb): sample points (flat x,z array)
local function makeCorridor(ga, aIndex, gb, bIndex)
	local dx, dz = gb.mx - ga.mx, gb.mz - ga.mz
	local D = hypot(dx, dz)
	if D < 0.01 then
		return nil
	end
	dx, dz = dx / D, dz / D
	local t0 = max(0, exitDistOf(ga, dx, dz) - CORRIDOR_BEFORE)
	local t1 = min(D, D - exitDistOf(gb, -dx, -dz) + CORRIDOR_AFTER)
	local c = { a = aIndex, b = bIndex, top = ga.top, need = Config.Course.Clearance + 0.3, n = 0 }
	local t = t0
	while t <= t1 + 1e-6 do
		for _, off in ipairs({ -CORRIDOR_HALF, 0, CORRIDOR_HALF }) do
			c.n = c.n + 1
			c[2 * c.n - 1], c[2 * c.n] = ga.mx + dx * t - dz * off, ga.mz + dz * t + dx * off
		end
		t = t + 1
	end
	return c
end

-- Does the solid `sol` hang in the free air a jump through corridor `c` needs? (a, b and their bridge parts never do)
local function corridorBlocked(c, sol)
	if sol.owner == c.a or sol.owner == c.b then
		return false
	end
	local g = sol.g
	if g.top <= c.top or g.bot >= c.top + c.need - EPS then
		return false
	end
	local h = g.hull
	for k = 1, c.n do
		local x, z = c[2 * k - 1], c[2 * k]
		if hypot(x - h.cx, z - h.cz) <= h.r + CORRIDOR_NEAR and pointDist(x, z, h) < CORRIDOR_NEAR then
			return true
		end
	end
	return false
end

-- the pieces runAttempt needs, in one table (a Lua 5.1 function may only capture 60 upvalues)
local JUMPROOM = { Decor = DECOR_HEAD, MakeCorridor = makeCorridor, Blocked = corridorBlocked }

local function corridorMessage(c, sol)
	return string.format("%s %d hangs only %.1f studs above the jump from step %d to step %d (needs %.1f)", sol.tag, sol.owner,
		sol.g.bot - c.top, c.a, c.b, c.need)
end

-- Does the arc of a cannon flight (samples) hit the solid? (pad and landing owners are skipped)
local function arcProblem(samples, padOwner, landOwner, s)
	if s.owner == padOwner or s.owner == landOwner then
		return false
	end
	for _, q in ipairs(samples) do
		if bodyHits(q, s) then
			return true
		end
	end
	return false
end

----------------------------------------------------------------------
-- Tokens and scenery rules
----------------------------------------------------------------------
-- Is position (x, y, z) inside any solid (grown by `grow`)?
local function insideSolid(x, y, z, solids, grow)
	for _, s in ipairs(solids) do
		local g = s.g
		if y > g.bot - grow and y < g.top + grow then
			local dx, dz = x - g.hull.cx, z - g.hull.cz
			if hypot(dx, dz) <= g.hull.r + grow + 0.01 then
				if pointDist(x, z, g.hull) < grow + 0.001 then
					return s
				end
			end
		end
	end
	return nil
end

local function tokenProblem(step, g, tk, solids)
	if type(tk) ~= "table" or not isVec(tk.Pos) or not isNum(tk.Value) then
		return "token is malformed"
	end
	if tk.Value ~= Config.Tokens.DefaultValue and tk.Value ~= Config.Tokens.GoldenValue then
		return "token value is neither regular nor golden"
	end
	if (tk.Value == Config.Tokens.GoldenValue) ~= (tk.Golden == true) then
		return "token Golden flag does not match its value"
	end
	local dy = tk.Pos.Y - step.Pos.Y
	if dy < 3 - EPS or dy > 4.5 + EPS then
		return string.format("token height %.2f above its step is outside [3, 4.5]", dy)
	end
	-- it must hover over its own step or in the gap in front of it
	local d = pointDist(tk.Pos.X, tk.Pos.Z, g.hull)
	if d > 0.3 then
		local gap = step.Gap or 0
		if d > gap + 0.3 then
			return string.format("token is %.1f studs away from its step", d)
		end
	end
	local hit = insideSolid(tk.Pos.X, tk.Pos.Y, tk.Pos.Z, solids, 0.3)
	if hit then
		return string.format("token is inside %s %d", hit.tag, hit.owner)
	end
	if step.Kind == "CannonPad" then
		return "tokens do not belong on a cannon pad"
	end
	return nil
end

-- `samples` (optional): cannon flight samples that scenery must not stand in
local function sceneryProblem(item, solids, samples)
	if type(item) ~= "table" or type(item.Type) ~= "string" or not SCENERY_TYPES[item.Type] then
		return "unknown scenery type " .. tostring(item and item.Type)
	end
	if not (isVec(item.Pos) and isNum(item.Radius) and isNum(item.Height) and isNum(item.Yaw) and isNum(item.Seed)
		and isNum(item.Tint)) then
		return "scenery lacks Pos/Radius/Height/Yaw/Seed/Tint"
	end
	if item.Radius <= 0 or item.Height <= 0 then
		return "scenery has no size"
	end
	if hypot(item.Pos.X, item.Pos.Z) > 380 then
		return "scenery is too far from the course"
	end
	local y0, y1 = item.Pos.Y - 4, item.Pos.Y + item.Height + 4
	if samples then
		for _, q in ipairs(samples) do
			if q[2] > y0 - 1 and q[2] < y1 + 1 and hypot(q[1] - item.Pos.X, q[3] - item.Pos.Z) < item.Radius + 3 then
				return item.Type .. " would block a cannon flight"
			end
		end
	end
	for _, s in ipairs(solids) do
		local g = s.g
		if g.top + g.head > y0 and g.bot < y1 then
			local d = pointDist(item.Pos.X, item.Pos.Z, g.hull)
			if d < item.Radius + 4 then
				return string.format("%s overlaps %s %d (%.1f studs from it)", item.Type, s.tag, s.owner, d)
			end
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Tokens
----------------------------------------------------------------------
-- Places regular and golden tokens on the finished steps. Every token is proven with tokenProblem.
-- Returns total value, token count, golden count.
local function placeTokens(rng, diff, tier, steps, geos, solids, stages)
	local function F(a, b)
		if b - a < 1e-6 then
			return a
		end
		return rng:Float(a, b)
	end
	local function I(a, b)
		if b <= a then
			return a
		end
		return rng:Int(a, b)
	end
	local DEFAULT, GOLD = Config.Tokens.DefaultValue, Config.Tokens.GoldenValue
	local total, count, goldCount = 0, 0, 0

	-- one proposal (a Vector3) for step `step`; `risky` pushes it to an edge / into a hazard area
	local function proposal(step, g, risky, golden)
		local kind = step.Kind
		local hx, hz = g.hx, g.hz
		local h = step.Hazard
		local function at(lx, lz, yy)
			local wx = g.mx + lx * g.c + lz * g.s
			local wz = g.mz - lx * g.s + lz * g.c
			return Vector3.new(wx, step.Pos.Y + yy, wz)
		end
		local y = F(3.2, 4.0)
		if golden then
			y = F(3.6, 4.4)
		end
		if kind == "Bounce" then
			return at(0, 0, 3.8)
		elseif kind == "Moving" then
			return at(F(-1.2, 1.2), F(-hz * 0.25, hz * 0.25), F(3.2, 4.2))
		elseif (kind == "DashGap" or kind == "PlateBridge") and step.DashHint and (risky or rng:Chance(0.6)) then
			local hint = step.DashHint
			local d = 1.5 + (step.Gap or 15) * 0.5
			return Vector3.new(hint.Pos.X + hint.Dir.X * d, step.Pos.Y + F(3.6, 4.3), hint.Pos.Z + hint.Dir.Z * d)
		elseif kind == "Beam" then
			local lx = F(-0.3, 0.3)
			if risky then
				lx = (rng:Chance(0.5) and 1 or -1) * (hx - 0.3)
			end
			return at(lx, F(-hz + 1.2, hz - 1.2), y)
		elseif kind == "PendulumPlatform" and h then
			-- tokens wait in the calm strips beside the swing
			local alongX = abs(h.Axis.X * g.c - h.Axis.Z * g.s) < 0.5 -- swing runs along local X?
			local sweep = h.Length * sin(h.Arc * RAD)
			local sgn = rng:Chance(0.5) and 1 or -1
			if alongX then
				local es = hx
				return at(sgn * F(sweep + 0.5, es - 0.5), F(-hz + 1.5, hz - 1.5), y)
			end
			return at(F(-hx + 1.5, hx - 1.5), sgn * F(sweep + 0.5, hz - 0.5), y)
		elseif kind == "LightningPlatform" and h and risky then
			local z = h.Zones[I(1, #h.Zones)]
			local lx, lz = toLocal(g, z.Pos.X, z.Pos.Z)
			return at(lx + F(-z.Radius * 0.4, z.Radius * 0.4), lz + F(-z.Radius * 0.4, z.Radius * 0.4), F(3.3, 4.0))
		end
		if risky then
			local side = I(1, 3)
			if side == 1 then
				return at(F(-hx * 0.3, hx * 0.3), hz - 0.5, y)
			elseif side == 2 then
				return at(hx - 0.5, F(-hz * 0.3, hz * 0.3), y)
			end
			return at(-(hx - 0.5), F(-hz * 0.3, hz * 0.3), y)
		end
		return at(F(-hx * 0.2, hx * 0.2), F(-hz * 0.35, hz * 0.35), y)
	end

	-- adds up to `want` tokens to one step; returns how many were placed
	local function fill(step, want, risky, golden)
		local g = geos[step.Index]
		local placed = 0
		local tries = 0
		while placed < want and tries < 14 do
			tries = tries + 1
			local pos = proposal(step, g, risky, golden)
			local tk = { Pos = pos, Value = golden and GOLD or DEFAULT, Golden = golden and true or false }
			local ok = tokenProblem(step, g, tk, solids) == nil
			if ok and step.Tokens then
				for _, other in ipairs(step.Tokens) do
					if hypot(other.Pos.X - pos.X, other.Pos.Z - pos.Z) < 1.6 and abs(other.Pos.Y - pos.Y) < 1.6 then
						ok = false
						break
					end
				end
			end
			if ok then
				step.Tokens = step.Tokens or {}
				step.Tokens[#step.Tokens + 1] = tk
				placed = placed + 1
				total = total + tk.Value
				count = count + 1
				if golden then
					goldCount = goldCount + 1
				end
			end
		end
		return placed
	end

	local goldRange = byTier(TIER.GoldenPerStage, tier)
	for k, info in ipairs(stages) do
		local cands = {}
		for i = info.FirstStep, info.LastStep do
			local s = steps[i]
			if s.Kind ~= "Checkpoint" and s.Kind ~= "CannonPad" then
				cands[#cands + 1] = s
			end
		end
		for i = #cands, 2, -1 do
			local j = I(1, i)
			cands[i], cands[j] = cands[j], cands[i]
		end
		-- regular tokens: TokensPerStage .. +2 distinct steps, 40% of them on risky edges
		local want = min(#cands, diff.TokensPerStage + I(0, 2))
		local risky = ceil(want * 0.4)
		local used = 0
		local ci = 1
		while used < want and ci <= #cands do
			local s = cands[ci]
			ci = ci + 1
			local n = 1
			if used >= risky and rng:Chance(0.3) and s.Kind ~= "Beam" and s.Kind ~= "Bounce" and s.Kind ~= "Moving" then
				n = I(2, 3)
			end
			if fill(s, n, used < risky, false) > 0 then
				used = used + 1
			end
		end
		-- golden tokens: hazards and chasms first, always on a risky spot
		local gold = I(goldRange[1], goldRange[2])
		local order = {}
		for _, s in ipairs(cands) do
			local w = 1
			local kind = s.Kind
			if kind == "DashGap" or kind == "PlateBridge" or kind == "Beam" or kind == "LightningPlatform"
				or kind == "PendulumPlatform" or kind == "SpinBarPlatform" or kind == "Moving" then
				w = 3
			end
			order[#order + 1] = { s = s, key = rng:Float(0, 1) * w + (w - 1) * 0.5 }
		end
		table.sort(order, function(a, b)
			if a.key ~= b.key then
				return a.key > b.key
			end
			return a.s.Index < b.s.Index
		end)
		local placed = 0
		for _, o in ipairs(order) do
			if placed >= gold then
				break
			end
			placed = placed + fill(o.s, 1, true, true)
		end
		if placed == 0 and #cands > 0 then
			-- every risky spot was blocked: put one on the first step that accepts it
			for _, s in ipairs(cands) do
				if fill(s, 1, false, true) > 0 then
					break
				end
			end
		end
	end
	return total, count, goldCount
end

----------------------------------------------------------------------
-- Scenery
----------------------------------------------------------------------
local function placeScenery(rng, steps, solids, stages, spiral, samples)
	local function F(a, b)
		if b - a < 1e-6 then
			return a
		end
		return rng:Float(a, b)
	end
	local function I(a, b)
		if b <= a then
			return a
		end
		return rng:Int(a, b)
	end
	local items = {}
	local minY, maxY = huge, -huge
	for _, s in ipairs(solids) do
		minY = min(minY, s.g.bot)
		maxY = max(maxY, s.g.top + s.g.head)
	end

	local function clashes(item)
		for _, o in ipairs(items) do
			local d = hypot(item.Pos.X - o.Pos.X, item.Pos.Z - o.Pos.Z)
			local overlapY = item.Pos.Y < o.Pos.Y + o.Height + 4 and o.Pos.Y < item.Pos.Y + item.Height + 4
			if overlapY and d < item.Radius + o.Radius + 4 then
				return true
			end
		end
		return false
	end

	-- the spiral's central pillar fills the void inside the helix
	if spiral then
		local r = spiral.Rmin * 0.5
		while r >= 8 do
			local item = {
				Type = "CentralPillar", Stage = 0,
				Pos = Vector3.new(spiral.cx, minY - 24, spiral.cz), Yaw = F(0, 360),
				Radius = r, Height = (maxY - minY) + 56, Seed = I(1, 99999), Tint = I(1, 8),
			}
			if sceneryProblem(item, solids, samples) == nil then
				items[#items + 1] = item
				break
			end
			r = r * 0.85
		end
	end

	-- one landmark per stage, matching its theme, beside the stage's route
	for k, st in ipairs(stages) do
		local id = LANDMARK_OF_THEME[st.Theme]
		local sz = id and LANDMARK_SIZE[id]
		if sz then
			local rad, hgt = F(sz[1], sz[2]), F(sz[3], sz[4])
			local mid = steps[floor((st.FirstStep + st.LastStep) / 2)]
			local done = false
			for ring = 1, 4 do
				local dist0 = rad + 20 + (ring - 1) * 24
				local a0 = F(0, 360)
				for a = 0, 11 do
					local ang = (a0 + a * 30) * RAD
					local d = dist0 + F(0, 8)
					local item = {
						Type = id, Stage = k,
						Pos = Vector3.new(mid.Pos.X + sin(ang) * d, mid.Pos.Y - hgt * 0.3 + F(-4, 8), mid.Pos.Z + cos(ang) * d),
						Yaw = F(0, 360), Radius = rad, Height = hgt, Seed = I(1, 99999), Tint = st.Tint,
					}
					if sceneryProblem(item, solids, samples) == nil and not clashes(item) then
						items[#items + 1] = item
						st.Landmark = id
						done = true
						break
					end
				end
				if done then
					break
				end
			end
		end
	end

	-- distant puffs, plus a cloud sea far below the route
	local function addPuff(dist0, dist1, y0, y1)
		local ang = F(0, 360) * RAD
		local d = F(dist0, dist1)
		local r = F(12, 34)
		local item = {
			Type = "Puff", Stage = 0, Pos = Vector3.new(sin(ang) * d, F(y0, y1), cos(ang) * d), Yaw = F(0, 360),
			Radius = r, Height = r * 0.6, Seed = I(1, 99999), Tint = I(1, 8),
		}
		if sceneryProblem(item, solids, samples) == nil then
			items[#items + 1] = item
		end
	end
	for _ = 1, I(14, 22) do
		addPuff(200, 320, minY - 50, maxY + 30)
	end
	for _ = 1, I(6, 10) do
		addPuff(0, 200, minY - 46, minY - 28)
	end
	return items
end

----------------------------------------------------------------------
-- Generator
----------------------------------------------------------------------
-- Slide a shape along the ray (ox, oz) + D * (dx, dz) until its distance to `pShape` equals `gap`.
-- Returns the centre (x, z) or nil.
local function solvePlacement(pShape, ox, oz, dx, dz, makeShape, gap)
	local function f(D)
		return shapeDist(pShape, makeShape(ox + dx * D, oz + dz * D))
	end
	if f(0) > gap then
		return nil
	end
	local lo, hi = 0, 8
	while f(hi) < gap do
		lo = hi
		hi = hi + 8
		if hi > 220 then
			return nil
		end
	end
	for _ = 1, 22 do
		local mid = (lo + hi) * 0.5
		if f(mid) < gap then
			lo = mid
		else
			hi = mid
		end
	end
	return ox + dx * hi, oz + dz * hi
end

-- Finishes a generated course: checkpoints table, tokens, scenery, bounds.
local function assemble(rng, diff, tier, seed, attemptNo, archetype, themes, steps, geos, solids, stages, spiral, arcs)
	local layout = {
		DifficultyId = diff.Id, Seed = seed, Attempt = attemptNo + 1, Archetype = archetype, Themes = themes,
		Steps = steps, Stages = stages, Checkpoints = {}, Scenery = {}, TotalTokens = 0, TokenCount = 0, GoldenCount = 0,
	}
	for i, s in ipairs(steps) do
		if s.Kind == "Checkpoint" then
			layout.Checkpoints[s.Stage] = i
		end
	end
	if spiral then
		layout.Centre = Vector3.new(spiral.cx, 0, spiral.cz)
	end
	local total, count, gold = placeTokens(rng, diff, tier, steps, geos, solids, stages)
	layout.TotalTokens, layout.TokenCount, layout.GoldenCount = total, count, gold
	local samples = {}
	for _, a in ipairs(arcs) do
		for _, q in ipairs(a.samples) do
			samples[#samples + 1] = q
		end
	end
	layout.Scenery = placeScenery(rng, steps, solids, stages, spiral, samples)

	local mnx, mny, mnz, mxx, mxy, mxz = huge, huge, huge, -huge, -huge, -huge
	for _, s in ipairs(solids) do
		local h = s.g.hull
		for i = 1, h.n do
			mnx, mxx = min(mnx, h[2 * i - 1]), max(mxx, h[2 * i - 1])
			mnz, mxz = min(mnz, h[2 * i]), max(mxz, h[2 * i])
		end
		mny = min(mny, s.g.bot)
		mxy = max(mxy, s.g.top + s.g.head)
	end
	layout.Bounds = { Min = Vector3.new(mnx - 2, mny - 6, mnz - 2), Max = Vector3.new(mxx + 2, mxy, mxz + 2) }
	return layout
end

-- One complete generation attempt. Returns layout, nil  or  nil, reason.
local function runAttempt(diff, tier, seed, attemptNo, dbg)
	local MAXTURN = 42 -- degrees a step's heading may differ from the previous step's
	local OFFS = { 0, 8, -8, 16, -16, 26, -26, 38, -38, 52, -52, 68, -68, 90, -90 }
	local SAFE_OPENERS = { "Stones", "Bounce" }
	local MILD_OPENERS = { "Moving", "Beams", "Vanish", "Spin", "Plates" }
	local asin = math.asin
	local rng = Util.NewRng(floor(seed) + attemptNo * 1000003)
	local function F(a, b)
		if b - a < 1e-6 then
			return a
		end
		return rng:Float(a, b)
	end
	local function I(a, b)
		if b <= a then
			return a
		end
		return rng:Int(a, b)
	end
	local function coin()
		return rng:Chance(0.5)
	end

	local riseCap = riseCapOf(diff)
	local dashLo, dashHi = dashRange(diff)
	local clearance = Config.Course.Clearance
	local stageCount = diff.Stages
	local maxRadius = Config.Course.MaxRadius

	local steps, geos, heads, solids, arcs = {}, {}, {}, {}, {}
	local corridors = {} -- jump corridors of the accepted Walk / Dash links
	local bridgeCount = 0

	local function note(reason)
		if dbg and dbg.reasons then
			local key = reason:gsub("[%d%.%-]+", "#")
			dbg.reasons[key] = (dbg.reasons[key] or 0) + 1
		end
	end

	----------------------------------------------------------------
	-- archetype and stage themes
	----------------------------------------------------------------
	local archetype = weightedPick(rng, Config.Archetypes, function(id)
		return weightIn(diff.Archetypes, id)
	end) or "Straight"

	local function themeWeight(id)
		return weightIn(diff.Themes, id)
	end
	local themes, uses = {}, {}
	for k = 1, stageCount do
		local prevT = themes[k - 1]
		local pick
		if k == stageCount and stageCount > 1 and themeWeight("Gauntlet") > 0 and prevT ~= "Gauntlet" and rng:Chance(0.65) then
			pick = "Gauntlet"
		elseif k == 1 then
			pick = weightedPick(rng, SAFE_OPENERS, themeWeight)
			if not pick then
				pick = weightedPick(rng, MILD_OPENERS, themeWeight)
			end
		end
		if not pick then
			pick = weightedPick(rng, Config.StageThemes, function(id)
				if id == prevT then
					return 0
				end
				return themeWeight(id) * (0.45 ^ (uses[id] or 0))
			end)
		end
		if not pick then
			pick = prevT or "Stones"
		end
		themes[k] = pick
		uses[pick] = (uses[pick] or 0) + 1
	end

	----------------------------------------------------------------
	-- macro path (steering)
	----------------------------------------------------------------
	local avgPlat = (diff.PlatformMin + diff.PlatformMax) * 0.5
	local nomAdv = avgPlat + (diff.GapMin + diff.GapMax) * 0.5 * 0.9
	local avgSteps = (diff.StepsPerStage[1] + diff.StepsPerStage[2]) * 0.5
	local estLength = stageCount * (avgSteps + 1) * nomAdv * 1.2

	local steer = { arch = archetype, turning = false, laneLen = 0, laneS = 0, stageEnded = false, dd = 0, left = 0,
		sigma = 1, lastRate = 0 }
	local heading0
	local spiral = nil
	if archetype == "Spiral" then
		local R0 = F(45, 70)
		local R1 = clamp(R0 + F(-15, 15), 45, min(75, 144 - R0))
		steer.sigma = coin() and 1 or -1
		local a0 = F(0, 360)
		steer.R0, steer.R1 = R0, R1
		steer.cx, steer.cz = -R0 * sin(a0 * RAD), -R0 * cos(a0 * RAD)
		steer.aPrev, steer.aCum = a0, 0
		steer.totalAngle = estLength / ((R0 + R1) * 0.5) * DEG
		heading0 = a0 + steer.sigma * 90
		spiral = { cx = steer.cx, cz = steer.cz, Rmin = min(R0, R1) }
	else
		heading0 = F(0, 360)
		local rMin = max(18, 1.1 * diff.PlatformMax + 8)
		if archetype == "Straight" then
			steer.R = rMin + F(8, 14)
		elseif archetype == "Zigzag" then
			steer.R = rMin + F(0, 5)
			steer.minLane = 60
		else
			steer.R = rMin + F(10, 16)
			steer.theta = F(34, 50)
			steer.lambda = F(100, 140)
			steer.phase = F(0, 6.283)
		end
		steer.psi = heading0
		local sgn = coin() and 1 or -1
		local hr = heading0 * RAD
		steer.driftX, steer.driftZ = sgn * cos(hr), -sgn * sin(hr)
	end

	local function turnSlack(px, pz, h, R, sigma)
		local hr = h * RAD
		local ccx = px + sigma * cos(hr) * R
		local ccz = pz - sigma * sin(hr) * R
		return CENTRE_LIMIT - (hypot(ccx, ccz) + R)
	end
	local function bestSlack(px, pz, h, R)
		return max(turnSlack(px, pz, h, R, 1), turnSlack(px, pz, h, R, -1))
	end
	-- which way to U-turn: continue the sweep across the disc, flip when that side has no room
	local function chooseSigma(px, pz, h, R)
		local hr = h * RAD
		local pref = (cos(hr) * steer.driftX - sin(hr) * steer.driftZ) >= 0 and 1 or -1
		local s1 = turnSlack(px, pz, h, R, pref)
		local s2 = turnSlack(px, pz, h, R, -pref)
		if s1 >= 0 then
			return pref
		end
		if s2 >= 0 then
			steer.driftX, steer.driftZ = -steer.driftX, -steer.driftZ
			return -pref
		end
		return (s1 >= s2) and pref or -pref
	end

	local function desiredHeading(spec)
		local gPrev, hPrev = geos[#steps], heads[#steps]
		local px, pz = gPrev.mx, gPrev.mz
		local adv = gPrev.hz + (diff.GapMin + diff.GapMax) * 0.5 + spec.sz * 0.5
		local want
		if steer.arch == "Spiral" then
			local vx, vz = px - steer.cx, pz - steer.cz
			local r = hypot(vx, vz)
			local a = atan2(vx, vz) * DEG
			local frac = clamp(steer.aCum / steer.totalAngle, 0, 1)
			local Rt = steer.R0 + (steer.R1 - steer.R0) * frac
			local eps = clamp(atan2(r - Rt, 28) * DEG, -38, 38)
			local half = (adv / max(r, 10)) * 0.5 * DEG
			want = a + steer.sigma * (90 + eps + half)
		else
			if not steer.turning then
				local Rp = max(steer.R, adv * 1.4)
				local hr = hPrev * RAD
				local ax, az = px + sin(hr) * adv, pz + cos(hr) * adv
				local start = false
				if steer.arch == "Zigzag" and steer.stageEnded and steer.laneLen >= steer.minLane
					and bestSlack(px, pz, hPrev, Rp) >= 0 then
					start = true
				end
				if not start and bestSlack(ax, az, hPrev, Rp) < 0 then
					start = true
				end
				if start then
					local sg = chooseSigma(px, pz, hPrev, Rp)
					local target = steer.psi + 180
					local left = (((target - hPrev) * sg) % 360)
					if left >= 20 then
						steer.turning, steer.sigma, steer.Rp, steer.target, steer.left = true, sg, Rp, target, left
					end
				end
			end
			if steer.turning then
				local rate = min(steer.left, MAXTURN, DEG * adv / steer.Rp)
				steer.lastRate = rate
				want = hPrev + steer.sigma * rate
			elseif steer.arch == "Serpent" then
				want = steer.psi + steer.theta * sin(6.2832 * steer.laneS / steer.lambda + steer.phase)
			else
				want = steer.psi + steer.dd
			end
		end
		return hPrev + clamp(wrap180(want - hPrev), -MAXTURN, MAXTURN)
	end

	-- called once per committed step
	local function steerAfter(step, g)
		local prevG = geos[step.Index - 1]
		local dist = 0
		if prevG then
			dist = hypot(g.mx - prevG.mx, g.mz - prevG.mz)
		end
		steer.laneS = steer.laneS + dist
		if steer.arch == "Spiral" then
			local a = atan2(g.mx - steer.cx, g.mz - steer.cz) * DEG
			local da = wrap180(a - steer.aPrev) * steer.sigma
			if da > 0 then
				steer.aCum = steer.aCum + da
			end
			steer.aPrev = a
		else
			if steer.turning then
				steer.left = steer.left - steer.lastRate
				if steer.left <= 0.5 then
					steer.turning = false
					steer.psi = steer.target % 360
					steer.laneLen = 0
				end
			else
				steer.laneLen = steer.laneLen + dist
			end
			steer.dd = clamp(steer.dd + F(-3, 3), -9, 9)
		end
		steer.stageEnded = (step.Kind == "Checkpoint")
	end

	----------------------------------------------------------------
	-- solids / history
	----------------------------------------------------------------
	-- never below Config.Course.Clearance, whatever the hazard geometry itself needs
	local function headOf(kind)
		local h = JUMPROOM.Decor[kind] or 0
		if kind == "Bounce" then
			local p = byTier(TIER.BouncePower, tier)
			h = ceil(p * p / (2 * PH.Gravity) + 1)
		elseif kind == "StormPlatform" then
			h = 10.5
		elseif kind == "LightningPlatform" then
			h = 12
		elseif kind == "PendulumPlatform" then
			h = 11.5
		elseif kind == "WindPlatform" then
			h = 10
		elseif kind == "CannonPad" then
			h = 9
		end
		return max(clearance, h)
	end

	-- lowest top surface that keeps the headroom rule with every solid under/near the new footprint
	local function neededTop(g, index, top, head)
		local proxy = { tag = "step", owner = index }
		local need = -huge
		for _, es in ipairs(solids) do
			if not solidsExempt(proxy, es) then
				local d = shapeDist(g.hull, es.g.hull, HEAD_CLEAR + 2)
				if d <= HEAD_CLEAR + 0.5 then
					local aboveOK = (top - TH) >= es.g.top + es.g.head + 0.3
					local belowOK = (es.g.bot - top) >= head + 0.3
					if not (aboveOK or belowOK) then
						need = max(need, es.g.top + es.g.head + TH + 0.3)
					end
				end
			end
		end
		return need
	end

	local function historyProblem(newSolids, newCorridor)
		for _, ns in ipairs(newSolids) do
			for _, es in ipairs(solids) do
				if not solidsExempt(ns, es) then
					local msg = solidPairProblem(ns, es)
					if msg then
						return msg
					end
					msg = shortcutProblem(ns, es)
					if msg then
						return msg
					end
				end
			end
			for _, arc in ipairs(arcs) do
				if arcProblem(arc.samples, arc.pad, arc.land, ns) then
					return "blocks a cannon flight"
				end
			end
			for _, c in ipairs(corridors) do
				if JUMPROOM.Blocked(c, ns) then
					return "hangs over an earlier jump"
				end
			end
		end
		if newCorridor then
			for _, es in ipairs(solids) do
				if JUMPROOM.Blocked(newCorridor, es) then
					return "its jump runs under an earlier step"
				end
			end
		end
		return nil
	end

	----------------------------------------------------------------
	-- rise / gap / size sampling
	----------------------------------------------------------------
	local function sizeFor(kind, forceLo)
		local lo, hi = diff.PlatformMin, diff.PlatformMax
		if kind == "Checkpoint" then
			return SIZES.Checkpoint, SIZES.Checkpoint
		elseif kind == "Beam" then
			local wlo, whi = 3.6, 4
			if tier == 3 then
				wlo, whi = 3.4, 4
			elseif tier == 4 then
				wlo, whi = 3, 3.8
			elseif tier >= 5 then
				wlo, whi = 2.5, 3.4
			end
			local w = floor(F(wlo, whi) * 4 + 0.5) / 4
			return clamp(w, 2.5, 4), clamp(snap(F(14, 30)), 14, 30)
		elseif kind == "PendulumPlatform" or kind == "WindPlatform" then
			return clamp(snap(F(9, 13)), 9, 15), clamp(snap(F(9, 13)), 9, 15)
		end
		local a, b = lo, hi
		if kind == "CannonPad" then
			a, b = max(lo, 7), max(hi, 7)
		elseif kind == "PlateBridge" then
			a = max(lo, 7)
			b = max(hi, a)
		elseif kind == "Moving" or kind == "Bounce" or kind == "StormPlatform" then
			a = lo + (hi - lo) * 0.4
		elseif kind == "SpinBarPlatform" then
			a = max(lo + (hi - lo) * 0.4, 6.5)
		elseif kind == "LightningPlatform" then
			a = max(lo + (hi - lo) * 0.3, 6)
		end
		if forceLo and forceLo > a then
			a = forceLo
		end
		if a > b then
			a = b
		end
		local function pick()
			return clamp(snap(F(a, b)), a, b)
		end
		return pick(), pick()
	end

	local function pickRise(spec, prev, exitD)
		local kind = spec.kind
		if kind == "PlateBridge" then
			return 0
		elseif kind == "DashGap" then
			if coin() then
				return F(0, 1.5)
			end
			return 0
		elseif spec.cannonLanding then
			return F(-1, 7.5)
		end
		if prev.Kind == "Bounce" and spec.bounceUp then
			local hp = prev.Hazard
			local r = F(4.8, 8.5)
			if hp and hp.Power then
				while r > riseCap
					and bounceReach(hp.Power, hp.LaunchSpeed, r) - exitD - 0.8 < diff.GapMin + 0.3 do
					r = r - 0.5
				end
			end
			if r > riseCap then
				return r
			end
		end
		local r
		local roll = F(0, 1)
		if roll < 0.18 then
			r = 0
		elseif roll < 0.70 then
			r = F(0.5, riseCap * 0.7)
		elseif roll < 0.93 then
			r = F(riseCap * 0.55, riseCap)
		else
			r = -F(0.5, 3)
		end
		if r >= 0 and r < 0.4 and rng:Chance(0.4) then
			r = F(0.6, min(1.5, riseCap))
		end
		if r > 0 then
			r = r * spec.climb
		end
		if kind == "Moving" or kind == "SpinBarPlatform" or kind == "Vanishing" then
			r = min(r, 2.5)
		elseif kind == "PendulumPlatform" or kind == "WindPlatform" or kind == "Finish" or kind == "CannonPad" then
			r = clamp(r, 0, 2)
		elseif kind == "Checkpoint" then
			r = clamp(r, 0, riseCap * 0.7)
		end
		if r < 0 and (prev.Pos.Y < 3 or kind ~= "Platform") then
			r = 0
		end
		if prev.Pos.Y + r < -6 then
			r = 0
		end
		r = min(r, riseCap)
		while r > 0 and runReach(r) - 0.3 < diff.GapMin do
			r = r - 0.25
		end
		if r < 0.05 and r > 0 then
			r = 0
		end
		return r
	end

	local function pickGap(spec, rise, prev, exitD)
		local kind = spec.kind
		if kind == "DashGap" or kind == "PlateBridge" then
			local hi = min(dashHi, dashReach(rise) - 0.3)
			local lo = dashLo
			if hi < lo then
				hi = lo
			end
			return F(lo, hi)
		elseif spec.cannonLanding then
			return F(24, 46)
		end
		local lo, hi = diff.GapMin, diff.GapMax
		if rise > riseCap + RISE_EPS then
			local hp = prev.Hazard
			if hp and hp.Power then
				hi = min(hi, bounceReach(hp.Power, hp.LaunchSpeed, rise) - exitD - 0.8)
			end
		else
			hi = min(hi, runReach(rise) - 0.3)
		end
		if hi < lo then
			hi = lo
		end
		local t = F(0.05, 0.55 + 0.45 * spec.progress)
		if kind == "Vanishing" or kind == "Moving" then
			t = t * 0.8
		elseif kind == "Beam" then
			t = t * 0.6
		end
		return lo + (hi - lo) * t
	end

	----------------------------------------------------------------
	-- hazards
	----------------------------------------------------------------
	local function attachCannon(prev, gPrev, step, g)
		local tx, tz = g.cx, g.cz
		local hdist = hypot(tx - gPrev.cx, tz - gPrev.cz)
		local t0 = clamp(1.0 + hdist / 110, 1.05, 1.45)
		local aimX, aimZ = tx - gPrev.cx, tz - gPrev.cz
		local al = hypot(aimX, aimZ)
		if al < 0.01 then
			return false
		end
		local target = Vector3.new(tx, step.Pos.Y + ROOT_H, tz)
		local minDim = minDimOf(prev.Size)
		local padR = clamp(minDim * 0.3, 2.2, 3.4)
		for _, t in ipairs({ t0, t0 + 0.08, t0 - 0.08, 1.25, 1.4, 1.12 }) do
			if t >= 1.0 and t <= 1.45 then
				local vx, vy, vz = cannonVelocity(prev.Pos.Y, gPrev.cx, gPrev.cz, target, t)
				prev.Hazard = {
					Type = "Cannon",
					Pos = Vector3.new(gPrev.cx, prev.Pos.Y, gPrev.cz),
					PadRadius = padR,
					Target = target,
					LandingPoint = Vector3.new(tx, step.Pos.Y, tz),
					FlightTime = t,
					Aim = Vector3.new(aimX / al, 0, aimZ / al),
					Speed = sqrt(vx * vx + vy * vy + vz * vz),
					Apex = ROOT_H + (vy > 0 and vy * vy / (2 * PH.Gravity) or 0),
					LandingIndex = step.Index,
				}
				prev.Headroom = headOf("CannonPad")
				step.Link = "Cannon"
				local lo, hi = gapRange(gPrev, g)
				local msg = cannonLinkProblem(diff, prev, gPrev, step, g, lo, hi, step.Pos.Y - prev.Pos.Y)
				if not msg then
					return true
				end
				note("cannon: " .. msg)
			end
		end
		prev.Hazard = nil
		return false
	end

	-- Builds the hazard / hint of a freshly placed step. Returns extra solids ({} when none) or nil, reason.
	local function decorate(step, g, spec, prev, gPrev)
		local kind = step.Kind
		local top = step.Pos.Y
		local minDim = minDimOf(step.Size)
		local extras = {}
		if kind == "Vanishing" then
			local d = max(byTier(TIER.VanishDelay, tier), minVanishDelay(step.Size) + 0.05)
			d = ceil(d * 20) / 20
			step.Hazard = { Type = "Vanish", VanishDelay = d, ReturnDelay = max(byTier(TIER.VanishReturn, tier), d + 1.2) }
		elseif kind == "Bounce" then
			local power = byTier(TIER.BouncePower, tier)
			step.Hazard = {
				Type = "Bounce", Pos = Vector3.new(g.cx, top, g.cz), PadSize = clamp(minDim * 0.42, 3, 4.6),
				Power = power, LaunchSpeed = byTier(TIER.BounceSpeed, tier), Apex = power * power / (2 * PH.Gravity),
			}
		elseif kind == "SpinBarPlatform" then
			local sp = byTier(TIER.SpinSpeed, tier)
			local speed = floor(F(sp[1], sp[2]))
			if coin() then
				speed = -speed
			end
			local count = 1
			if tier >= 4 and minDim >= 7.5 and coin() then
				count = 2
			end
			step.Hazard = {
				Type = "SpinBar", Pos = Vector3.new(g.cx, top, g.cz), Length = clamp(floor((minDim - 2.4) * 2) / 2, 3, 9),
				Speed = speed, Damage = byTier(TIER.SpinDamage, tier), Count = count, Height = 1.0,
			}
		elseif kind == "StormPlatform" then
			step.Hazard = {
				Type = "Storm", DPS = byTier(TIER.StormDPS, tier),
				Box = { Pos = Vector3.new(g.cx, top, g.cz), Size = Vector3.new(step.Size.X + 2, 6.5, step.Size.Z + 2), Yaw = step.Yaw },
			}
		elseif kind == "LightningPlatform" then
			local r = clamp(minDim * 0.28, 1.8, 3.6)
			local nZones = 1
			if tier >= 4 and minDim >= 7.5 and coin() then
				nZones = 2
			end
			local pl = byTier(TIER.LightningInterval, tier)
			local okHaz = false
			for _ = 1, 14 do
				local zones = {}
				for z = 1, nZones do
					local lx = F(-(g.hx - r), g.hx - r)
					local lz = F(-(g.hz - r), g.hz - r)
					local wx, wz = toWorld(g, lx, lz)
					zones[z] = { Pos = Vector3.new(wx, top, wz), Radius = r }
				end
				step.Hazard = {
					Type = "Lightning", Zones = zones, Damage = byTier(TIER.LightningDamage, tier), Interval = pl,
					Warning = byTier(TIER.LightningWarning, tier),
				}
				if hazardProblem(diff, step, g, prev, gPrev) == nil then
					okHaz = true
					break
				end
				nZones = 1
			end
			if not okHaz then
				return nil, "lightning has no safe spot"
			end
		elseif kind == "PendulumPlatform" then
			local swingFwd = rng:Chance(0.6) -- swing along local Z (rotation axis = local X)
			local es, ea = g.hz, g.hx
			if not swingFwd then
				es, ea = g.hx, g.hz
			end
			local sweepMax = es - 1.0 - 0.3
			local ar = byTier(TIER.PendArc, tier)
			local arc = F(ar[1], ar[2])
			local L = clamp(sweepMax / sin(arc * RAD), 4.5, 8.5)
			if L * sin(arc * RAD) > sweepMax then
				arc = asin(sweepMax / L) * DEG
			end
			if arc < 24 then
				return nil, "pendulum arc too small"
			end
			L = floor(L * 10) / 10
			local axisX, axisZ = g.c, -g.s
			if not swingFwd then
				axisX, axisZ = g.s, g.c
			end
			local pp = byTier(TIER.PendPeriod, tier)
			step.Hazard = {
				Type = "Pendulum", Hinge = Vector3.new(g.cx, top + L + 1.2, g.cz), Axis = Vector3.new(axisX, 0, axisZ),
				Arc = floor(arc * 10) / 10, Period = F(pp[1], pp[2]), Damage = byTier(TIER.PendDamage, tier), Length = L,
				BeamSize = Vector3.new(min(2 * ea - 1.0, 12), L, 1.0), RestClear = 1.2,
			}
		elseif kind == "WindPlatform" then
			local alongX = coin()
			local sgn = coin() and 1 or -1
			local La, Lc = step.Size.Z, step.Size.X
			if alongX then
				La, Lc = step.Size.X, step.Size.Z
			end
			local zoneLen = La - 5.4
			local lx, lz, zx, zz = 0, 0, Lc - 0.4, zoneLen
			if alongX then
				lx, zx, zz = -sgn * 2.7, zoneLen, Lc - 0.4
			else
				lz = -sgn * 2.7
			end
			local wx, wz = toWorld(g, lx, lz)
			local dirx, dirz = sgn * g.s, sgn * g.c
			if alongX then
				dirx, dirz = sgn * g.c, -sgn * g.s
			end
			step.Hazard = {
				Type = "Wind", Zone = { Pos = Vector3.new(wx, top, wz), Size = Vector3.new(zx, 9, zz), Yaw = step.Yaw },
				Direction = Vector3.new(dirx, 0, dirz), Force = byTier(TIER.WindForce, tier),
				Interval = byTier(TIER.WindInterval, tier), Warning = byTier(TIER.WindWarning, tier), Duration = 1.5,
			}
		elseif kind == "DashGap" or kind == "PlateBridge" then
			-- hint: a spot on the run-up platform's top, 1.5 studs behind its edge along the line to this step
			local tx, tz = g.cx, g.cz
			if kind == "PlateBridge" then
				-- aim at the middle of the bridge lane
				local lxn = toLocal(gPrev, g.cx, g.cz)
				local ovLo = max(-gPrev.hx, lxn - g.hx)
				local ovHi = min(gPrev.hx, lxn + g.hx)
				local lc = (ovLo + ovHi) * 0.5
				local ov = ovHi - ovLo
				local sw = min(4.5, ov - 1.2)
				if sw < 3.2 then
					return nil, "bridge lanes do not overlap enough"
				end
				local gap = step.Gap
				local sx0, sz0 = toWorld(gPrev, lc, gPrev.hz + gap * 0.5)
				local spanSize = Vector3.new(sw, 1, gap + 0.6)
				local bridge = {
					Type = "PlateBridge", BridgeNumber = spec.bridgeNumber,
					Span = { Pos = Vector3.new(sx0, prev.Pos.Y, sz0), Size = spanSize, Yaw = step.Yaw },
					Sides = {},
				}
				local sgn = coin() and 1 or -1
				local sideLo = diff.GapMin
				local sideHi = max(sideLo, min(diff.GapMax, runReach(0)) - 1)
				for k, pair in ipairs({ { prev, gPrev }, { step, g } }) do
					local anchor, ga = pair[1], pair[2]
					local sgap = F(sideLo, sideHi)
					local sideZ = clamp(anchor.Size.Z, 6, 9)
					local side = (k == 1) and sgn or -sgn
					local wx, wz = toWorld(ga, side * (ga.hx + sgap + 3.5), 0)
					local sPos = Vector3.new(wx, anchor.Pos.Y, wz)
					local sSize = Vector3.new(7, TH, sideZ)
					local sg = makeGeo({ Pos = sPos, Size = sSize, Yaw = anchor.Yaw })
					bridge.Sides[k] = {
						Pos = sPos, Size = sSize, Yaw = anchor.Yaw, From = anchor.Index, Gap = shapeDist(sg.rect, ga.rect),
						Plate = { Pos = Vector3.new(wx, anchor.Pos.Y + 0.5, wz), Size = Vector3.new(4, 0.5, 4) },
					}
				end
				step.Hazard = bridge
				tx, tz = sx0, sz0
			end
			local ux, uz = tx - gPrev.cx, tz - gPrev.cz
			local ul = hypot(ux, uz)
			if ul < 0.01 then
				return nil, "dash line is degenerate"
			end
			ux, uz = ux / ul, uz / ul
			local lux = ux * gPrev.c - uz * gPrev.s
			local luz = ux * gPrev.s + uz * gPrev.c
			local texit = min(gPrev.hx / max(abs(lux), 1e-6), gPrev.hz / max(abs(luz), 1e-6))
			local back = min(1.5, texit * 0.5)
			step.DashHint = {
				From = prev.Index,
				Pos = Vector3.new(gPrev.cx + ux * (texit - back), prev.Pos.Y, gPrev.cz + uz * (texit - back)),
				Dir = Vector3.new(ux, 0, uz),
			}
		end
		if kind == "PlateBridge" then
			local tmp = { Pos = step.Pos, Size = step.Size, Yaw = step.Yaw, Kind = kind, Hazard = step.Hazard, Index = step.Index }
			bridgeSolids(tmp, extras)
		end
		return extras
	end

	----------------------------------------------------------------
	-- placement of one step
	----------------------------------------------------------------
	local function tryPlace(spec, heading, index, attempt)
		local kind = spec.kind
		local prev, gPrev = steps[#steps], geos[#steps]
		local hr = heading * RAD
		local dirx, dirz = sin(hr), cos(hr)
		local yaw = heading
		if spec.yawJitter then
			yaw = heading + F(-spec.yawJitter, spec.yawJitter)
		end
		if kind == "PlateBridge" then
			yaw = prev.Yaw
		end
		yaw = yaw % 360
		local yawRad = yaw * RAD
		local sx, sz = spec.sx, spec.sz
		local hx, hz = sx * 0.5, sz * 0.5
		local swx, swz = 0, 0
		local movingHaz = nil
		if kind == "Moving" then
			local sgn = coin() and 1 or -1
			local w = spec.sweepW
			if attempt > 2 then
				w = floor(F(min(3.6, w), w) * 2) / 2 -- later attempts try shorter slides
			end
			swx, swz = sgn * w * cos(yawRad), -sgn * w * sin(yawRad)
			local mp = byTier(TIER.MovePeriod, tier)
			local per = F(max(mp[1], w / 3.9), max(mp[2], w / 3.9 + 0.2))
			movingHaz = { Type = "Moving", EndOffset = Vector3.new(swx, 0, swz), Period = floor(per * 20) / 20 }
		end
		local function shapeAt(mx, mz)
			if kind == "Moving" then
				return sweptShape(mx - swx * 0.5, mz - swz * 0.5, swx, swz, hx, hz, yawRad)
			end
			return rectShape(mx, mz, hx, hz, yawRad)
		end

		local maxRise = riseCap
		if prev.Kind == "Bounce" then
			maxRise = 9
		end
		if spec.cannonLanding then
			maxRise = 10
		elseif kind == "DashGap" or kind == "PlateBridge" then
			maxRise = 2
		end
		-- distance from the middle of the previous step to its edge in the travel direction
		local lux = dirx * gPrev.c - dirz * gPrev.s
		local luz = dirx * gPrev.s + dirz * gPrev.c
		local exitD = min(gPrev.hx / max(abs(lux), 1e-6), gPrev.hz / max(abs(luz), 1e-6))
		local rise = pickRise(spec, prev, exitD)
		if rise > maxRise then
			rise = maxRise
		end
		local gap = pickGap(spec, rise, prev, exitD)

		local ox, oz = gPrev.mx, gPrev.mz
		if prev.Kind == "Beam" and abs(wrap180(heading - prev.Yaw)) < 100 then
			ox = ox + sin(prev.Yaw * RAD) * gPrev.hz
			oz = oz + cos(prev.Yaw * RAD) * gPrev.hz
		end
		local bridgeShift = 0
		if kind == "PlateBridge" then
			bridgeShift = F(-1.5, 1.5)
		elseif not spec.noShift and coin() then
			local lim = min(gPrev.hx, hx) * 0.5
			local shift = F(-lim, lim)
			ox, oz = ox + shift * cos(hr), oz - shift * sin(hr)
		end

		local function place(gapNow)
			if kind == "PlateBridge" then
				return toWorld(gPrev, bridgeShift, gPrev.hz + gapNow + hz)
			end
			return solvePlacement(gPrev.hull, ox, oz, dirx, dirz, shapeAt, gapNow)
		end

		local head = headOf(kind)
		local mx, mz = place(gap)
		if not mx then
			return nil, "no placement"
		end
		local top = prev.Pos.Y + rise
		local function tentative()
			return makeGeo({
				Pos = Vector3.new(mx - swx * 0.5, top, mz - swz * 0.5), Size = Vector3.new(sx, TH, sz), Yaw = yaw,
				Kind = kind, Hazard = movingHaz, Headroom = head,
			})
		end
		-- raise the step when an earlier lap/lane is too close underneath
		for _ = 1, 2 do
			local need = neededTop(tentative(), index, top, head)
			if need > top + EPS then
				local newRise = need - prev.Pos.Y
				if newRise > maxRise + 1e-9 then
					return nil, "needs too much climb"
				end
				rise, top = newRise, need
				if not spec.cannonLanding and kind ~= "DashGap" and kind ~= "PlateBridge" and rise <= riseCap + RISE_EPS
					and gap > runReach(rise) - 0.3 then
					gap = runReach(rise) - 0.3
					if gap < diff.GapMin then
						return nil, "no gap left after climbing"
					end
					mx, mz = place(gap)
					if not mx then
						return nil, "no placement"
					end
				end
			else
				break
			end
		end

		-- a moving neighbour makes the gap vary along its sweep: pull the nearest approach in so the far end stays legal
		if (gPrev.sx or kind == "Moving") and not spec.cannonLanding then
			local lo, hi = gapRange(gPrev, tentative())
			local limit = diff.GapMax
			if rise <= riseCap + RISE_EPS then
				limit = min(limit, runReach(rise) - 0.3)
			end
			if hi > limit then
				local target = limit - (hi - lo) - 0.05
				if target < diff.GapMin then
					return nil, "a moving step varies the gap too much"
				end
				gap = target
				mx, mz = place(gap)
				if not mx then
					return nil, "no placement"
				end
			end
		end

		local link = "Walk"
		if prev.Kind == "CannonPad" then
			link = "Cannon"
		elseif kind == "DashGap" or kind == "PlateBridge" then
			link = "Dash"
		elseif rise > riseCap + RISE_EPS then
			link = "Bounce"
		end
		local step = {
			Index = index, Stage = spec.stage, Kind = kind,
			Pos = Vector3.new(mx - swx * 0.5, top, mz - swz * 0.5), Size = Vector3.new(sx, TH, sz), Yaw = yaw,
			Gap = 0, Link = link, Variant = I(1, 4), Headroom = head, Hazard = movingHaz,
		}
		local g = makeGeo(step)
		local _, gapHi = gapRange(gPrev, g)
		step.Gap = gapHi
		spec.bridgeNumber = bridgeCount + 1
		local extras, why = decorate(step, g, spec, prev, gPrev)
		if not extras then
			return nil, why
		end
		if spec.cannonLanding and not attachCannon(prev, gPrev, step, g) then
			return nil, "cannon cannot reach"
		end

		local msg = sizeProblem(step, diff)
		if not msg then
			msg = pairProblem(diff, prev, gPrev, step, g)
		end
		if not msg and kind ~= "CannonPad" then
			msg = hazardProblem(diff, step, g, prev, gPrev)
		end
		if not msg and prev.Kind == "CannonPad" then
			msg = hazardProblem(diff, prev, gPrev, steps[#steps - 1], geos[#steps - 1])
		end
		if msg then
			if prev.Kind == "CannonPad" then
				prev.Hazard = nil
			end
			return nil, msg
		end
		if shapeRadius(g.hull) > maxRadius - 0.5 then
			if prev.Kind == "CannonPad" then
				prev.Hazard = nil
			end
			return nil, "outside the course radius"
		end
		local newSolids = { { g = g, tag = "step", owner = index } }
		for _, e in ipairs(extras) do
			if shapeRadius(e.g.hull) > maxRadius - 0.5 then
				if prev.Kind == "CannonPad" then
					prev.Hazard = nil
				end
				return nil, "bridge parts outside the course radius"
			end
			newSolids[#newSolids + 1] = e
		end
		local corridor = nil
		if link == "Walk" or link == "Dash" then
			corridor = JUMPROOM.MakeCorridor(gPrev, index - 1, g, index)
		end
		msg = historyProblem(newSolids, corridor)
		if not msg and prev.Kind == "CannonPad" then
			local samples = cannonArcSamples(prev.Hazard, prev.Pos.Y)
			for _, s in ipairs(solids) do
				if arcProblem(samples, index - 1, index, s) then
					msg = "the cannon flight would hit another step"
					break
				end
			end
			if not msg then
				for _, ns in ipairs(newSolids) do
					if ns.owner ~= index - 1 and ns.owner ~= index and arcProblem(samples, index - 1, index, ns) then
						msg = "the cannon flight would hit its own bridge"
						break
					end
				end
			end
			if not msg then
				arcs[#arcs + 1] = { samples = samples, pad = index - 1, land = index }
			end
		end
		if msg then
			if prev.Kind == "CannonPad" then
				prev.Hazard = nil
			end
			return nil, msg
		end

		-- accepted
		steps[index], geos[index], heads[index] = step, g, heading
		for _, s in ipairs(newSolids) do
			solids[#solids + 1] = s
		end
		if corridor then
			corridors[#corridors + 1] = corridor
		end
		if kind == "PlateBridge" then
			bridgeCount = bridgeCount + 1
		end
		steerAfter(step, g)
		return step
	end

	-- Slides of the previous (moving) step get shorter around their middle: always legal for its own link.
	local function shrinkMoving(idx, newW)
		local s, g = steps[idx], geos[idx]
		local travel = hypot(g.sx, g.sz)
		if travel <= newW + 0.01 then
			return false
		end
		local k = newW / travel
		local ex, ez = g.sx * k, g.sz * k
		s.Hazard.EndOffset = Vector3.new(ex, 0, ez)
		s.Pos = Vector3.new(g.mx - ex * 0.5, s.Pos.Y, g.mz - ez * 0.5)
		local ng = makeGeo(s)
		geos[idx] = ng
		for _, sol in ipairs(solids) do
			if sol.tag == "step" and sol.owner == idx then
				sol.g = ng
			end
		end
		local _, hi = gapRange(geos[idx - 1], ng)
		s.Gap = hi
		return true
	end

	local placeStepOnce
	local function placeStep(spec)
		local prev = steps[#steps]
		local step, why = placeStepOnce(spec)
		if not step and prev.Kind == "Moving" and shrinkMoving(#steps, 3.6) then
			note("shrank a moving step to let the next step fit")
			step, why = placeStepOnce(spec)
		end
		return step, why
	end

	placeStepOnce = function(spec)
		local prev = steps[#steps]
		local index = #steps + 1
		local sign = coin() and 1 or -1
		local jitter = 8
		if archetype == "Spiral" or archetype == "Serpent" then
			jitter = 3
		end
		-- phases of heading attempts: straight kinds keep the previous yaw, steps leaving a moving cloud first try
		-- to continue straight out of it (keeps the gap steady), everything else follows the macro path
		local phases = {}
		if spec.straight then
			phases[1] = { base = prev.Yaw, offs = { 0, 3, -3, 6, -6 }, tries = 10, exact = true }
		else
			if prev.Kind == "Moving" then
				phases[1] = { base = prev.Yaw, offs = { 0, 3, -3, 6, -6, 10, -10 }, tries = 14, exact = true }
			end
			phases[#phases + 1] = { base = desiredHeading(spec), offs = OFFS, tries = 30 }
		end
		local lastWhy = "?"
		local attempt = 0
		for _, ph in ipairs(phases) do
			for k = 1, ph.tries do
				attempt = attempt + 1
				local oi = floor((k + 1) / 2)
				local off = ph.offs[min(oi, #ph.offs)] * sign
				local heading = ph.base + off
				if not ph.exact then
					heading = heading + ((oi == 1) and F(-jitter, jitter) or F(-2, 2))
				end
				local step, why = tryPlace(spec, heading, index, attempt)
				if step then
					return step
				end
				lastWhy = why or "?"
				note(lastWhy .. " (" .. prev.Kind .. ">" .. spec.kind .. ")")
			end
		end
		return nil, lastWhy
	end

	local function demoteLast()
		local idx = #steps
		local s, g = steps[idx], geos[idx]
		s.Kind = "Platform"
		s.Hazard = nil
		s.Headroom = clearance
		g.kind = "Platform"
		g.head = clearance
	end

	----------------------------------------------------------------
	-- stage planning
	----------------------------------------------------------------
	local function planStage(theme, n, stage, progress)
		local kinds = {}
		local landing = {}
		for j = 1, n do
			kinds[j] = "Platform"
		end
		local pFeat = clamp(0.45 + 0.5 * diff.HazardChance, 0.5, 0.92)
		-- sprinkle `kind` on steps 2..n with chance p (never next to itself unless `run` allows); keep at least `need`
		local function sprinkle(kind, p, need, run)
			local count = 0
			local streak = 0
			for j = 2, n do
				if kinds[j] == "Platform" and streak < run and rng:Chance(p) then
					kinds[j] = kind
					count = count + 1
					streak = streak + 1
				else
					streak = 0
				end
			end
			local tries = 0
			while count < need and tries < 40 do
				tries = tries + 1
				local j = I(2, n)
				if kinds[j] == "Platform" and (run > 1 or (kinds[j - 1] ~= kind and kinds[j + 1] ~= kind)) then
					kinds[j] = kind
					count = count + 1
				end
			end
		end

		if theme == "Beams" then
			for j = 1, n do
				kinds[j] = "Beam"
			end
		elseif theme == "Bounce" then
			sprinkle("Bounce", pFeat * 0.75, 2, 2)
		elseif theme == "Moving" then
			sprinkle("Moving", pFeat, 2, 1)
		elseif theme == "Spin" then
			sprinkle("SpinBarPlatform", pFeat * 0.8, 2, (tier >= 4) and 2 or 1)
		elseif theme == "Storm" then
			sprinkle("StormPlatform", pFeat * 0.8, 2, 2)
		elseif theme == "Lightning" then
			sprinkle("LightningPlatform", pFeat * 0.8, 2, (tier >= 4) and 2 or 1)
		elseif theme == "Vanish" then
			sprinkle("Vanishing", pFeat, 2, 3)
		elseif theme == "Pendulum" then
			sprinkle("PendulumPlatform", pFeat * 0.5, (n >= 8) and 2 or 1, 1)
		elseif theme == "Wind" then
			sprinkle("WindPlatform", pFeat * 0.5, (n >= 8) and 2 or 1, 1)
		elseif theme == "Cannon" then
			local maxPads = min(2, n - diff.TokensPerStage)
			local pads = (maxPads >= 2 and n >= 8 and coin()) and 2 or 1
			if maxPads < 1 then
				pads = 0
			end
			local placed, tries = 0, 0
			while placed < pads and tries < 40 do
				tries = tries + 1
				local j = I(2, n - 1)
				if kinds[j] == "Platform" and kinds[j + 1] == "Platform" and not landing[j] and not landing[j + 1]
					and kinds[j - 1] ~= "CannonPad" and (kinds[j + 2] ~= "CannonPad") then
					kinds[j] = "CannonPad"
					landing[j + 1] = true
					placed = placed + 1
				end
			end
		elseif theme == "Plates" then
			local j = I(2, n)
			kinds[j] = "PlateBridge"
			local fill = (tier >= 3) and "Vanishing" or "Moving"
			for q = 2, n do
				if kinds[q] == "Platform" and q ~= j - 1 and rng:Chance(0.22) then
					kinds[q] = fill
				end
			end
		elseif theme == "DashGap" then
			for j = 1, n do
				if kinds[j] == "Platform" and (j == 1 or kinds[j - 1] == "Platform") and rng:Chance(0.55) then
					kinds[j] = "DashGap"
				end
			end
			local have = 0
			for j = 1, n do
				if kinds[j] == "DashGap" then
					have = have + 1
				end
			end
			if have == 0 then
				kinds[I(1, n)] = "DashGap"
			end
		elseif theme == "Gauntlet" then
			local pool = {}
			local themeOfKind = {
				SpinBarPlatform = "Spin", Vanishing = "Vanish", LightningPlatform = "Lightning", StormPlatform = "Storm",
				PendulumPlatform = "Pendulum", WindPlatform = "Wind", Moving = "Moving",
			}
			for _, kk in ipairs({ "SpinBarPlatform", "Vanishing", "LightningPlatform", "StormPlatform", "PendulumPlatform",
				"WindPlatform", "Moving" }) do
				if themeWeight(themeOfKind[kk]) > 0 then
					pool[#pool + 1] = kk
				end
			end
			if #pool < 3 then
				pool = { "SpinBarPlatform", "Vanishing", "Moving" }
			end
			-- three distinct hazards, shuffled, cycled over the stage
			for i = #pool, 2, -1 do
				local j = I(1, i)
				pool[i], pool[j] = pool[j], pool[i]
			end
			local chosen = { pool[1], pool[2], pool[3] }
			local ci = 0
			for j = 2, n do
				if rng:Chance(0.72) or j == 2 then
					ci = ci % 3 + 1
					kinds[j] = chosen[ci]
				end
			end
			-- every one of the three hazards must appear at least once
			for _, want in ipairs(chosen) do
				local present = false
				for j = 1, n do
					if kinds[j] == want then
						present = true
					end
				end
				local tries = 0
				while not present and tries < 40 do
					tries = tries + 1
					local j = I(2, n)
					local isChosen = false
					for _, c in ipairs(chosen) do
						if kinds[j] == c then
							isChosen = true
						end
					end
					if not isChosen or tries > 30 then
						kinds[j] = want
						present = true
					end
				end
			end
		end

		-- general fix-ups
		for j = 2, n do
			if kinds[j] == "Moving" and kinds[j - 1] == "Moving" then
				kinds[j] = "Platform"
			end
		end
		-- sprinkle dash gaps on harder levels (stage 2+)
		if stage >= 2 and (diff.DashGapChance or 0) > 0 and theme ~= "DashGap" then
			for j = 1, n do
				if kinds[j] == "Platform" and not landing[j] and (j == 1 or kinds[j - 1] == "Platform")
					and kinds[j + 1] ~= "PlateBridge" and rng:Chance(diff.DashGapChance) then
					kinds[j] = "DashGap"
				end
			end
		end
		-- dash gaps and plate bridges need a static plain run-up
		for j = 2, n do
			if (kinds[j] == "DashGap" or kinds[j] == "PlateBridge") and kinds[j - 1] ~= "Platform" then
				kinds[j] = "Platform"
			end
		end
		-- a cannon pad must stay followed by its landing island
		for j = 1, n do
			if kinds[j] == "CannonPad" and not landing[j + 1] then
				kinds[j] = "Platform"
			end
		end

		local entries = {}
		for j = 1, n + 1 do
			local kind = (j <= n) and kinds[j] or "Checkpoint"
			local forceLo = nil
			if kind ~= "Checkpoint" then
				local nxt = kinds[j + 1]
				if kind == "PlateBridge" or nxt == "PlateBridge" or (landing[j] and true or false) then
					forceLo = 7
				elseif nxt == "DashGap" then
					forceLo = 6
				end
			end
			local sx, sz = sizeFor(kind, forceLo)
			local psx, psz = sizeFor("Platform", forceLo)
			if kind == "Checkpoint" then
				psx, psz = sx, sz
			end
			entries[j] = {
				kind = kind, stage = stage, sx = sx, sz = sz, plain = { sx = psx, sz = psz }, progress = progress,
				cannonLanding = landing[j] and true or false, straight = (kind == "DashGap" or kind == "PlateBridge"),
				noShift = (kind == "DashGap" or kind == "PlateBridge" or kind == "Beam"),
			}
		end
		return entries
	end

	----------------------------------------------------------------
	-- build the course
	----------------------------------------------------------------
	local startSize = SIZES.Start
	local start = {
		Index = 1, Stage = 0, Kind = "Start", Pos = Vector3.new(0, 0, 0), Size = Vector3.new(startSize, TH, startSize),
		Yaw = heading0 % 360, Variant = I(1, 4), Headroom = headOf("Start"),
	}
	steps[1] = start
	geos[1] = makeGeo(start)
	heads[1] = heading0
	solids[1] = { g = geos[1], tag = "step", owner = 1 }

	local stages = {}
	local lastTint = 0
	for stage = 1, stageCount do
		local progress = 0
		if stageCount > 1 then
			progress = (stage - 1) / (stageCount - 1)
		end
		local n = I(diff.StepsPerStage[1], diff.StepsPerStage[2])
		local theme = themes[stage]
		local entries = planStage(theme, n, stage, progress)
		local climb = F(0.7, 1.25)
		local tint = I(1, 8)
		if tint == lastTint then
			tint = tint % 8 + 1
		end
		lastTint = tint
		local firstIndex = #steps + 1
		local skipLanding = false
		for j = 1, n + 1 do
			local e = entries[j]
			e.climb = climb
			if skipLanding and e.cannonLanding then
				e.kind, e.cannonLanding = "Platform", false
				e.sx, e.sz = e.plain.sx, e.plain.sz
				skipLanding = false
			end
			if e.kind == "Platform" or e.kind == "Vanishing" or e.kind == "Bounce" or e.kind == "StormPlatform"
				or e.kind == "SpinBarPlatform" or e.kind == "LightningPlatform" then
				e.yawJitter = 14
				local nxtKind = entries[j + 1] and entries[j + 1].kind
				if nxtKind == "Moving" or steps[#steps].Kind == "Moving" then
					e.yawJitter = 3 -- keep the faces of a moving cloud's neighbours square to it
				end
			end
			if steps[#steps].Kind == "Bounce" and e.kind ~= "Checkpoint" and e.kind ~= "Finish" then
				if theme == "Bounce" and rng:Chance(0.8) then
					e.bounceUp = true
				elseif rng:Chance(0.25) then
					e.bounceUp = true
				end
			end
			if e.kind == "Moving" then
				local prevW = steps[#steps].Size.X
				local nxt = entries[j + 1]
				local nextW = nxt and nxt.sx or SIZES.Checkpoint
				local mw = byTier(TIER.MoveWidth, tier)
				local w = F(mw[1], mw[2])
				w = min(w, prevW + e.sx - 5, e.sx + nextW - 5)
				if w < 3.6 or steps[#steps].Kind == "Moving" then
					e.kind = "Platform"
					e.sx, e.sz = e.plain.sx, e.plain.sz
				else
					e.sweepW = floor(w * 2) / 2
				end
			end
			local step, why = placeStep(e)
			if not step and e.kind ~= "Platform" and e.kind ~= "Checkpoint" then
				note("DEMOTED " .. e.kind .. " in " .. theme .. ": " .. tostring(why))
				if e.cannonLanding then
					demoteLast()
				end
				if e.kind == "CannonPad" then
					skipLanding = true
				end
				local plain = {}
				for k2, v in pairs(e) do
					plain[k2] = v
				end
				plain.kind, plain.cannonLanding, plain.straight, plain.noShift = "Platform", false, false, false
				plain.sx, plain.sz = e.plain.sx, e.plain.sz
				plain.sweepW, plain.yawJitter = nil, 14
				if e.kind == "Beam" then
					plain.yawJitter = nil
				end
				step, why = placeStep(plain)
			end
			if not step then
				return nil, "stuck at step " .. (#steps + 1) .. " (" .. tostring(e.kind) .. "): " .. tostring(why)
			end
		end
		stages[stage] = {
			Index = stage, Theme = theme, Name = THEME_NAMES[theme] or "Sky Climb", Tint = tint,
			FirstStep = firstIndex, LastStep = #steps,
		}
	end

	-- the finish island
	do
		local e = {
			kind = "Finish", stage = stageCount, sx = SIZES.Finish, sz = SIZES.Finish, progress = 1, climb = 1,
			plain = { sx = SIZES.Finish, sz = SIZES.Finish }, straight = false, noShift = false, cannonLanding = false,
		}
		local step, why = placeStep(e)
		if not step then
			return nil, "stuck at the finish: " .. tostring(why)
		end
	end
	for i = 1, #steps do
		if steps[i].Kind == "CannonPad" and not steps[i].Hazard then
			return nil, "a cannon pad was left without its landing"
		end
	end

	return assemble(rng, diff, tier, seed, attemptNo, archetype, themes, steps, geos, solids, stages, spiral, arcs)
end

----------------------------------------------------------------------
-- ValidateLayout: a proof of everything the contract promises
----------------------------------------------------------------------
function CourseLayout.ValidateLayout(layout)
	local problems = {}
	local function bad(fmt, ...)
		if #problems < MAX_PROBLEMS then
			problems[#problems + 1] = string.format(fmt, ...)
		end
	end
	if type(layout) ~= "table" or type(layout.Steps) ~= "table" then
		return false, { "layout has no Steps table" }
	end
	local diff = Config.GetDifficulty(layout.DifficultyId)
	if not diff then
		return false, { "unknown difficulty " .. tostring(layout.DifficultyId) }
	end
	local steps = layout.Steps
	local n = #steps
	if n < 3 then
		return false, { "layout has fewer than 3 steps" }
	end
	local clearance = Config.Course.Clearance
	local maxRadius = Config.Course.MaxRadius

	-- header: archetype, themes -------------------------------------------------
	local archetypeOk = false
	for _, a in ipairs(Config.Archetypes) do
		if a == layout.Archetype and weightIn(diff.Archetypes, a) > 0 then
			archetypeOk = true
		end
	end
	if not archetypeOk then
		bad("archetype %s is not allowed on %s", tostring(layout.Archetype), diff.Id)
	end
	local themes = layout.Themes
	if type(themes) ~= "table" or #themes ~= diff.Stages then
		bad("Themes must list one theme per stage (%d)", diff.Stages)
		themes = {}
	end
	local themeKinds = 0
	for _, id in ipairs(Config.StageThemes) do
		if weightIn(diff.Themes, id) > 0 then
			themeKinds = themeKinds + 1
		end
	end
	for k = 1, #themes do
		if weightIn(diff.Themes, themes[k]) <= 0 then
			bad("stage %d theme %s is not allowed on %s", k, tostring(themes[k]), diff.Id)
		end
		if k > 1 and themes[k] == themes[k - 1] and themeKinds > 1 then
			bad("stages %d and %d repeat the theme %s", k - 1, k, tostring(themes[k]))
		end
	end
	if themes[1] then
		local safe = weightIn(diff.Themes, "Stones") > 0 or weightIn(diff.Themes, "Bounce") > 0
		if safe and themes[1] ~= "Stones" and themes[1] ~= "Bounce" then
			bad("stage 1 must open with Stones or Bounce, not %s", tostring(themes[1]))
		elseif not safe and (themes[1] == "Storm" or themes[1] == "Lightning" or themes[1] == "Gauntlet"
			or themes[1] == "Pendulum" or themes[1] == "Wind" or themes[1] == "Cannon" or themes[1] == "DashGap") then
			bad("stage 1 opens with the harsh theme %s", tostring(themes[1]))
		end
	end
	if (layout.Archetype == "Spiral") ~= (layout.Centre ~= nil) then
		bad("Centre must be present exactly for Spiral courses")
	end

	-- steps ------------------------------------------------------------------------
	local geos = {}
	for i, s in ipairs(steps) do
		if type(s) ~= "table" or not isVec(s.Pos) or not isVec(s.Size) or type(s.Kind) ~= "string" then
			bad("step %d is malformed (needs Pos, Size, Kind)", i)
			return false, problems
		end
		geos[i] = makeGeo(s)
	end
	if steps[1].Kind ~= "Start" then
		bad("first step must be Start, got %s", tostring(steps[1].Kind))
	end
	if steps[n].Kind ~= "Finish" then
		bad("last step must be Finish, got %s", tostring(steps[n].Kind))
	end
	if steps[1].Pos.X ~= 0 or steps[1].Pos.Y ~= 0 or steps[1].Pos.Z ~= 0 then
		bad("Start must sit at the origin")
	end

	for i, s in ipairs(steps) do
		local ok, err = pcall(function()
			local g = geos[i]
			if s.Index ~= i then
				bad("step %d has Index %s", i, tostring(s.Index))
			end
			if not KINDS[s.Kind] then
				bad("step %d has unknown Kind %s", i, tostring(s.Kind))
				return
			end
			if not isNum(s.Yaw) then
				bad("step %d has no Yaw", i)
			end
			if (s.Kind == "Start") ~= (i == 1) or (s.Kind == "Finish") ~= (i == n) then
				bad("step %d: Start/Finish may only be the first/last step", i)
			end
			if not isNum(s.Stage) then
				bad("step %d has no Stage", i)
			end
			local msg = sizeProblem(s, diff)
			if msg then
				bad("step %d: %s", i, msg)
			end
			if s.Pos.Y < -10 - EPS then
				bad("step %d is lower than origin.Y - 10 (%.1f)", i, s.Pos.Y)
			end
			if shapeRadius(g.hull) > maxRadius + EPS then
				bad("step %d reaches %.1f studs from the origin (max %d)", i, shapeRadius(g.hull), maxRadius)
			end
			if i > 1 then
				msg = pairProblem(diff, steps[i - 1], geos[i - 1], s, g)
				if msg then
					bad("step %d (%s): %s", i, s.Kind, msg)
				end
			end
			if s.Kind ~= "CannonPad" or type(s.Hazard) == "table" then
				msg = hazardProblem(diff, s, g, steps[i - 1], geos[i - 1])
				if msg then
					bad("step %d (%s): %s", i, s.Kind, msg)
				end
			elseif s.Kind == "CannonPad" then
				bad("step %d: CannonPad has no Hazard", i)
			end
		end)
		if not ok then
			bad("step %d: internal error while validating: %s", i, tostring(err))
		end
	end

	-- stages + checkpoints -------------------------------------------------------------
	local cpCount = 0
	local perStage, bridgesPerStage = {}, {}
	for i, s in ipairs(steps) do
		if s.Kind == "Checkpoint" then
			cpCount = cpCount + 1
		end
		if s.Kind ~= "Start" and s.Kind ~= "Finish" and s.Kind ~= "Checkpoint" and isNum(s.Stage) then
			perStage[s.Stage] = (perStage[s.Stage] or 0) + 1
			if s.Kind == "PlateBridge" then
				bridgesPerStage[s.Stage] = (bridgesPerStage[s.Stage] or 0) + 1
				if themes[s.Stage] ~= "Plates" then
					bad("step %d: PlateBridge outside a Plates stage", i)
				end
			elseif s.Kind == "CannonPad" and themes[s.Stage] ~= "Cannon" then
				bad("step %d: CannonPad outside a Cannon stage", i)
			end
		end
		if i > 1 and isNum(s.Stage) and isNum(steps[i - 1].Stage) and s.Stage < steps[i - 1].Stage then
			bad("step %d goes back to an earlier stage", i)
		end
	end
	if cpCount ~= diff.Stages then
		bad("expected %d checkpoints, found %d", diff.Stages, cpCount)
	end
	local cps = layout.Checkpoints
	if type(cps) ~= "table" then
		bad("layout has no Checkpoints table")
		cps = {}
	end
	local lastCp = 0
	for k = 1, diff.Stages do
		local idx = cps[k]
		local s = idx and steps[idx]
		if not s or s.Kind ~= "Checkpoint" or s.Stage ~= k then
			bad("Checkpoints[%d] does not point at that stage's checkpoint", k)
		else
			if idx <= lastCp then
				bad("Checkpoints[%d] is out of order", k)
			end
			lastCp = idx
		end
	end
	if lastCp ~= n - 1 then
		bad("the last checkpoint (step %d) must sit right before the Finish (step %d)", lastCp, n)
	end
	if isNum(steps[n].Stage) and steps[n].Stage ~= diff.Stages then
		bad("the Finish must belong to the last stage")
	end
	for k = 1, diff.Stages do
		local c = perStage[k] or 0
		if c < diff.StepsPerStage[1] or c > diff.StepsPerStage[2] then
			bad("stage %d has %d steps (expected %d-%d)", k, c, diff.StepsPerStage[1], diff.StepsPerStage[2])
		end
		if (bridgesPerStage[k] or 0) > 1 then
			bad("stage %d has more than one PlateBridge", k)
		end
	end
	-- every stage must really contain what its theme promises
	local kindsInStage = {}
	for _, s in ipairs(steps) do
		if isNum(s.Stage) and s.Kind ~= "Start" and s.Kind ~= "Finish" and s.Kind ~= "Checkpoint" then
			local t = kindsInStage[s.Stage]
			if not t then
				t = {}
				kindsInStage[s.Stage] = t
			end
			t[s.Kind] = (t[s.Kind] or 0) + 1
		end
	end
	for k, theme in ipairs(themes) do
		local have = kindsInStage[k] or {}
		local feature = THEME_FEATURE[theme]
		if feature and (have[feature] or 0) < 1 then
			bad("stage %d (%s) has no %s step", k, theme, feature)
		end
		if theme == "Beams" and (have.Beam or 0) * 2 < (perStage[k] or 0) then
			bad("stage %d (Beams) is mostly not beams", k)
		elseif theme == "Plates" and have.PlateBridge ~= 1 then
			bad("stage %d (Plates) needs exactly one PlateBridge", k)
		elseif theme == "Gauntlet" then
			local distinct = 0
			for kind in pairs(have) do
				if kind ~= "Platform" then
					distinct = distinct + 1
				end
			end
			if distinct < 3 then
				bad("stage %d (Gauntlet) mixes only %d hazard kinds", k, distinct)
			end
		end
	end
	if type(layout.Stages) ~= "table" or #layout.Stages ~= diff.Stages then
		bad("Stages must describe every stage")
	else
		for k, info in ipairs(layout.Stages) do
			if type(info) ~= "table" or info.Index ~= k or info.Theme ~= themes[k] or type(info.Name) ~= "string"
				or not isNum(info.Tint) or not isNum(info.FirstStep) or info.LastStep ~= cps[k] then
				bad("Stages[%d] is malformed", k)
			end
		end
	end

	-- solids: separation, headroom, jump-skips --------------------------------------------
	local solids = {}
	for i, s in ipairs(steps) do
		solids[#solids + 1] = { g = geos[i], tag = "step", owner = i }
		local ok = pcall(bridgeSolids, s, solids)
		if not ok then
			bad("step %d: malformed bridge", i)
		end
	end
	for a = 1, #solids do
		for b = a + 1, #solids do
			local A, B = solids[a], solids[b]
			if not solidsExempt(A, B) then
				local msg = solidPairProblem(A, B)
				if msg then
					bad("%s %d and %s %d: %s", A.tag, A.owner, B.tag, B.owner, msg)
				end
				msg = shortcutProblem(A, B)
				if msg then
					bad("%s", msg)
				end
			end
		end
	end
	for _, s in ipairs(solids) do
		if s.tag ~= "step" and shapeRadius(s.g.hull) > maxRadius + EPS then
			bad("%s of step %d reaches beyond the course radius", s.tag, s.owner)
		end
	end
	-- jump corridors: a full jump of a Walk / Dash link must not bonk its head under another solid
	for i = 2, n do
		if steps[i].Link == "Walk" or steps[i].Link == "Dash" then
			local c = makeCorridor(geos[i - 1], i - 1, geos[i], i)
			if c then
				for _, sol in ipairs(solids) do
					if corridorBlocked(c, sol) then
						bad("%s", corridorMessage(c, sol))
					end
				end
			end
		end
	end

	-- cannon flights --------------------------------------------------------------------------
	for i, s in ipairs(steps) do
		local h = s.Hazard
		if s.Kind == "CannonPad" and type(h) == "table" and isVec(h.Target) and isVec(h.Pos) and isNum(h.FlightTime)
			and isNum(h.PadRadius) and h.FlightTime > 0 then
			local samples = cannonArcSamples(h, s.Pos.Y)
			for _, sol in ipairs(solids) do
				if arcProblem(samples, i, i + 1, sol) then
					bad("the flight of cannon %d hits %s %d", i, sol.tag, sol.owner)
				end
			end
		end
	end

	-- tokens ----------------------------------------------------------------------------------------
	local counted, valueSum, goldenTotal = 0, 0, 0
	local regularSteps, goldenInStage = {}, {}
	for i, s in ipairs(steps) do
		if s.Tokens ~= nil then
			if type(s.Tokens) ~= "table" then
				bad("step %d Tokens is not a list", i)
			else
				local hasRegular = false
				for _, tk in ipairs(s.Tokens) do
					local msg = tokenProblem(s, geos[i], tk, solids)
					if msg then
						bad("step %d: %s", i, msg)
					elseif type(tk) == "table" then
						counted = counted + 1
						valueSum = valueSum + tk.Value
						if tk.Golden then
							goldenTotal = goldenTotal + 1
							goldenInStage[s.Stage] = (goldenInStage[s.Stage] or 0) + 1
						else
							hasRegular = true
						end
					end
				end
				if hasRegular then
					regularSteps[s.Stage] = (regularSteps[s.Stage] or 0) + 1
				end
			end
		end
	end
	if valueSum ~= layout.TotalTokens then
		bad("TotalTokens %s does not match the placed token value %d", tostring(layout.TotalTokens), valueSum)
	end
	if counted ~= layout.TokenCount or goldenTotal ~= layout.GoldenCount then
		bad("TokenCount/GoldenCount do not match the placed tokens")
	end
	for k = 1, diff.Stages do
		if (regularSteps[k] or 0) < diff.TokensPerStage then
			bad("stage %d has regular tokens on %d steps (needs %d)", k, regularSteps[k] or 0, diff.TokensPerStage)
		end
		local gcount = goldenInStage[k] or 0
		if gcount < 1 or gcount > 2 then
			bad("stage %d has %d golden tokens (needs 1-2)", k, gcount)
		end
	end

	-- scenery -----------------------------------------------------------------------------------------
	if type(layout.Scenery) ~= "table" then
		bad("layout has no Scenery list")
	else
		local landmarks = {}
		local samples = {}
		for _, s in ipairs(steps) do
			local h = s.Hazard
			if s.Kind == "CannonPad" and type(h) == "table" and isVec(h.Target) and isVec(h.Pos) and isNum(h.FlightTime)
				and isNum(h.PadRadius) and h.FlightTime > 0 then
				for _, q in ipairs(cannonArcSamples(h, s.Pos.Y)) do
					samples[#samples + 1] = q
				end
			end
		end
		for _, item in ipairs(layout.Scenery) do
			local msg = sceneryProblem(item, solids, samples)
			if msg then
				bad("scenery: %s", msg)
			elseif item.Stage and item.Stage > 0 then
				landmarks[item.Stage] = item.Type
			end
		end
		if type(layout.Stages) == "table" then
			for k, info in ipairs(layout.Stages) do
				if type(info) == "table" and info.Landmark ~= nil and landmarks[k] ~= info.Landmark then
					bad("stage %d names the landmark %s but it is not in Scenery", k, tostring(info.Landmark))
				end
			end
		end
	end

	-- bounds ----------------------------------------------------------------------------------------------
	local bnd = layout.Bounds
	if type(bnd) ~= "table" or not isVec(bnd.Min) or not isVec(bnd.Max) then
		bad("layout has no Bounds")
	else
		for _, s in ipairs(solids) do
			local h = s.g.hull
			local inside = s.g.bot >= bnd.Min.Y - EPS and s.g.top <= bnd.Max.Y + EPS
			for i = 1, h.n do
				local x, z = h[2 * i - 1], h[2 * i]
				if x < bnd.Min.X - EPS or x > bnd.Max.X + EPS or z < bnd.Min.Z - EPS or z > bnd.Max.Z + EPS then
					inside = false
				end
			end
			if not inside then
				bad("%s %d lies outside Bounds", s.tag, s.owner)
				break
			end
		end
	end

	return #problems == 0, problems
end

----------------------------------------------------------------------
-- GenerateLayout
----------------------------------------------------------------------
local MAX_ATTEMPTS = 40

-- Set CourseLayout.Debug = { reasons = {}, attempts = {}, problems = {} } to collect generator statistics.
CourseLayout.Debug = nil

function CourseLayout.GenerateLayout(difficultyId, seed)
	local diff = Config.GetDifficulty(difficultyId) or Config.Difficulties[1]
	seed = tonumber(seed) or 0
	local tier = tierOf(diff)
	local dbg = CourseLayout.Debug
	local lastLayout = nil
	for attempt = 0, MAX_ATTEMPTS - 1 do
		local layout, why = runAttempt(diff, tier, seed, attempt, dbg)
		if layout then
			local ok, problems = CourseLayout.ValidateLayout(layout)
			if ok then
				if dbg and dbg.attempts then
					dbg.attempts[attempt + 1] = (dbg.attempts[attempt + 1] or 0) + 1
				end
				return layout
			end
			lastLayout = layout
			if dbg and dbg.problems then
				for _, p in ipairs(problems) do
					local key = p:gsub("[%d%.%-]+", "#")
					dbg.problems[key] = (dbg.problems[key] or 0) + 1
				end
			end
		elseif dbg and dbg.stuck then
			local key = tostring(why):gsub("[%d%.%-]+", "#")
			dbg.stuck[key] = (dbg.stuck[key] or 0) + 1
		end
	end
	if lastLayout then
		warn("[CourseLayout] no valid " .. diff.Id .. " layout for seed " .. tostring(seed) .. "; using the last attempt")
		return lastLayout
	end
	warn("[CourseLayout] could not generate a " .. diff.Id .. " layout for seed " .. tostring(seed))
	return {
		DifficultyId = diff.Id, Seed = seed, Attempt = MAX_ATTEMPTS, Archetype = "Straight", Themes = {}, Steps = {},
		Stages = {}, Checkpoints = {}, Scenery = {}, TotalTokens = 0, TokenCount = 0, GoldenCount = 0,
		Bounds = { Min = Vector3.new(0, 0, 0), Max = Vector3.new(0, 0, 0) },
	}
end

----------------------------------------------------------------------
-- Stats
----------------------------------------------------------------------
-- Summary numbers of a layout (for the UI, tests and tuning).
function CourseLayout.Stats(layout)
	local out = {
		Steps = 0, Regular = 0, Checkpoints = 0, Tokens = 0, Golden = 0, TotalTokens = 0, Height = 0, PathLength = 0,
		Radius = 0, MaxGap = 0, MaxRise = 0, Hazards = 0, Cannons = 0, Bridges = 0, DashGaps = 0, Beams = 0,
		Movers = 0, Scenery = 0, Stages = 0, Archetype = layout and layout.Archetype, Attempt = layout and layout.Attempt,
		KindCounts = {}, ThemeCounts = {}, HazardCounts = {},
	}
	if type(layout) ~= "table" or type(layout.Steps) ~= "table" then
		return out
	end
	local steps = layout.Steps
	out.Steps = #steps
	out.Tokens = layout.TokenCount or 0
	out.Golden = layout.GoldenCount or 0
	out.TotalTokens = layout.TotalTokens or 0
	out.Scenery = type(layout.Scenery) == "table" and #layout.Scenery or 0
	out.Stages = type(layout.Stages) == "table" and #layout.Stages or 0
	local minY, maxY = huge, -huge
	for i, s in ipairs(steps) do
		out.KindCounts[s.Kind] = (out.KindCounts[s.Kind] or 0) + 1
		if s.Kind == "Checkpoint" then
			out.Checkpoints = out.Checkpoints + 1
		elseif s.Kind ~= "Start" and s.Kind ~= "Finish" then
			out.Regular = out.Regular + 1
		end
		if s.Kind == "CannonPad" then
			out.Cannons = out.Cannons + 1
		elseif s.Kind == "PlateBridge" then
			out.Bridges = out.Bridges + 1
		elseif s.Kind == "DashGap" then
			out.DashGaps = out.DashGaps + 1
		elseif s.Kind == "Beam" then
			out.Beams = out.Beams + 1
		elseif s.Kind == "Moving" then
			out.Movers = out.Movers + 1
		end
		if type(s.Hazard) == "table" then
			out.Hazards = out.Hazards + 1
			out.HazardCounts[s.Hazard.Type] = (out.HazardCounts[s.Hazard.Type] or 0) + 1
		end
		minY = min(minY, s.Pos.Y)
		maxY = max(maxY, s.Pos.Y)
		out.Radius = max(out.Radius, hypot(s.Pos.X, s.Pos.Z))
		if i > 1 then
			local p = steps[i - 1]
			out.PathLength = out.PathLength + hypot(s.Pos.X - p.Pos.X, s.Pos.Z - p.Pos.Z)
			if type(s.Gap) == "number" and s.Link ~= "Cannon" then
				out.MaxGap = max(out.MaxGap, s.Gap)
			end
			out.MaxRise = max(out.MaxRise, s.Pos.Y - p.Pos.Y)
		end
	end
	if minY <= maxY then
		out.Height = maxY - minY
	end
	if type(layout.Themes) == "table" then
		for _, t in ipairs(layout.Themes) do
			out.ThemeCounts[t] = (out.ThemeCounts[t] or 0) + 1
		end
	end
	return out
end

-- helpers the builder / tests may want
CourseLayout.RootHeight = ROOT_H
CourseLayout.RunReach = runReach
CourseLayout.DashReach = dashReach
CourseLayout.AirTime = airTime

-- edge-to-edge gap between two layout steps (largest over a moving step's sweep)
function CourseLayout.StepGap(a, b)
	local _, hi = gapRange(makeGeo(a), makeGeo(b))
	return hi
end

-- local (lx, lz) of a world position inside a step's frame, and back
function CourseLayout.ToLocal(step, x, z)
	return toLocal(makeGeo(step), x, z)
end

function CourseLayout.ToWorld(step, lx, lz)
	return toWorld(makeGeo(step), lx, lz)
end

return CourseLayout
