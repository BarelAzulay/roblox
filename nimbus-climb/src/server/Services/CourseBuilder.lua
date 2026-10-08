-- CourseBuilder: procedural co-op sky parkour for Nimbus Climb.
--
--   Part 1  PURE layout generator  (Vector3 math + Config + Util.NewRng only, no Instances)
--   Part 2  Layout validator       (a proof that every hop is traversable)
--   Part 3  Builder                (turns a Layout into real, tagged Parts)
--
-- Plain Lua 5.1-compatible syntax only.
--
-- Physics model used by the generator AND the validator (so they can never disagree):
--   * a full-power jump from the edge of a platform to one `rise` studs higher stays airborne
--       airTime(rise) = (JumpPower + sqrt(JumpPower^2 - 2 g rise)) / g
--   * running (RunSpeed) covers  RunSpeed * airTime  studs, we keep a 10% safety factor and
--     1.5 studs of takeoff/landing margin:  runReach(rise) = 0.9 * RunSpeed * airTime - 1.5
--   * a dash adds Config.Physics.DashBonus studs, again with a 15% safety factor:
--       dashReach(rise) = 0.85 * (RunSpeed * airTime + DashBonus)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)
local Util = require(Shared.Util)

local CourseBuilder = {}

local P = Config.Physics
local Tags = Config.Tags

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local TH = 2 -- thickness (Size.Y) of every platform
local START_SIZE = 28
local CHECKPOINT_SIZE = 16
local FINISH_SIZE = 32
local LATERAL_LIMIT = 35 -- hard limit for |Pos.X| (validator)
local LATERAL_SOFT = 32 -- generator keeps centres inside this
local MIN_OVERLAP = 3 -- straight hops keep at least this much X overlap
local PLATE_OVERLAP = 5.5 -- plate bridges need a wider straight overlap for the span
local MAX_DROP = 4
local SIDE_SIZE = 7 -- plate side platforms are SIDE_SIZE wide
local SPAN_WIDTH = 4.5
local SPAN_THICKNESS = 1
local PLATE_SIZE = 4
local PLATE_HEIGHT = 0.5
local EPS = 0.01

-- Stage theme schedules (index = stage). The last stage is always the "mix" finale.
local SCHEDULES = {
	Breeze = { "plain", "bounce", "moving", "mix" },
	Gale = { "plain", "bounce", "moving", "spin", "plates", "mix" },
	Thunderstorm = { "plain", "vanish", "moving", "spin", "storm", "plates", "lightning", "mix" },
}

local THEME_NAMES = {
	plain = "Cloud Steps",
	bounce = "Bouncy Meadow",
	moving = "Drifting Clouds",
	vanish = "Fading Puffs",
	spin = "Whirlwind Alley",
	storm = "Rain Run",
	lightning = "Thunder Ridge",
	plates = "Teamwork Chasm",
	mix = "Skybreaker",
}

-- Per-tier (1 = Breeze, 2 = Gale, 3 = Thunderstorm) hazard numbers.
local MIX_FEATURES = {
	{ "Bounce", "Moving", "Vanishing" },
	{ "Bounce", "Moving", "SpinBarPlatform", "Vanishing", "StormPlatform" },
	{ "Moving", "SpinBarPlatform", "Vanishing", "StormPlatform", "LightningPlatform", "Bounce" },
}
local SPIN_SPEED = { { 55, 75 }, { 70, 100 }, { 95, 135 } } -- deg/s
local SPIN_DAMAGE = { 10, 15, 20 }
local STORM_DPS = { 5, 8, 12 }
local LIGHTNING_DAMAGE = { 18, 24, 30 }
local LIGHTNING_INTERVAL = { 5.5, 4.5, 3.8 }
local LIGHTNING_WARNING = { 1.6, 1.3, 1.1 }
local VANISH_DELAY = { 1.4, 1.0, 0.8 }
local VANISH_RETURN = { 3.0, 3.5, 4.0 }
local BOUNCE_POWER = { 70, 74, 78 }
local MOVE_WIDTH = { { 5, 7 }, { 6, 9 }, { 7, 10 } } -- studs of travel
local MOVE_PERIOD = { { 3.5, 4.2 }, { 2.8, 3.6 }, { 2.6, 3.2 } } -- seconds, one way

local STATIC_PREV = { Platform = true, Checkpoint = true, Start = true }
local FREE_FORM = { -- kinds that may be placed on a diagonal hop
	Platform = true,
	Bounce = true,
	Vanishing = true,
	SpinBarPlatform = true,
	StormPlatform = true,
	LightningPlatform = true,
	Checkpoint = true,
	Finish = true,
}
local REGULAR_KINDS = {
	Platform = true,
	Moving = true,
	Vanishing = true,
	Bounce = true,
	SpinBarPlatform = true,
	StormPlatform = true,
	LightningPlatform = true,
	PlateBridge = true,
	DashGap = true,
}

----------------------------------------------------------------------
-- Pure helpers
----------------------------------------------------------------------
local function snap(v)
	return math.floor(v * 2 + 0.5) / 2
end

local function tierOf(diff)
	for i, d in ipairs(Config.Difficulties) do
		if d.Id == diff.Id then
			return math.min(i, 3)
		end
	end
	return 1
end

-- Seconds a full jump lands `rise` studs higher (descending branch). Drops are treated as flat.
local function airTime(rise)
	if rise < 0 then
		rise = 0
	end
	local disc = P.JumpPower * P.JumpPower - 2 * P.Gravity * rise
	if disc < 0 then
		return 0
	end
	return (P.JumpPower + math.sqrt(disc)) / P.Gravity
end

local function runReach(rise)
	return 0.9 * P.RunSpeed * airTime(rise) - 1.5
end

local function dashReach(rise)
	return 0.85 * (P.RunSpeed * airTime(rise) + P.DashBonus)
end

-- Allowed dash-gap range for a difficulty (defaults for difficulties that do not define one).
local function dashRange(diff)
	local lo = diff.DashGapMin or 15
	local hi = diff.DashGapMax or 19
	hi = math.min(hi, 0.85 * P.MaxDashGap)
	lo = math.max(lo, P.MaxRunGap * 0.75 + 0.5)
	if lo > hi then
		lo = hi
	end
	return lo, hi
end

-- Shortest time a vanishing cloud must stay solid so a player can cross it and jump on.
local function minVanishDelay(size)
	local diag = math.sqrt(size.X * size.X + size.Z * size.Z)
	return 0.3 + diag / P.RunSpeed
end

-- Axis-aligned box of a step including the sweep of moving clouds (X only).
local function stepBox(step)
	local x0 = step.Pos.X
	local x1 = x0
	local h = step.Hazard
	if step.Kind == "Moving" and h and h.EndOffset then
		x1 = x0 + h.EndOffset.X
	end
	if x1 < x0 then
		x0, x1 = x1, x0
	end
	local hx = step.Size.X / 2
	local hz = step.Size.Z / 2
	return {
		x0 = x0 - hx,
		x1 = x1 + hx,
		z0 = step.Pos.Z - hz,
		z1 = step.Pos.Z + hz,
		y0 = step.Pos.Y - step.Size.Y,
		y1 = step.Pos.Y,
		cx0 = x0,
		cx1 = x1,
	}
end

-- Box of a plain slab given the centre of its top surface.
local function slabBox(pos, sx, sy, sz)
	return {
		x0 = pos.X - sx / 2,
		x1 = pos.X + sx / 2,
		z0 = pos.Z - sz / 2,
		z1 = pos.Z + sz / 2,
		y0 = pos.Y - sy,
		y1 = pos.Y,
		cx0 = pos.X,
		cx1 = pos.X,
	}
end

-- Signed gap along one axis: > 0 separated by that much, <= 0 overlapping.
local function axisGap(a0, a1, b0, b1)
	if b0 >= a1 then
		return b0 - a1
	elseif a0 >= b1 then
		return a0 - b1
	end
	return -(math.min(a1, b1) - math.max(a0, b0))
end

-- Euclidean edge-to-edge gap between two footprints in the XZ plane (0 when they overlap).
local function footGap(a, b)
	local dx = math.max(0, axisGap(a.x0, a.x1, b.x0, b.x1))
	local dz = math.max(0, axisGap(a.z0, a.z1, b.z0, b.z1))
	return math.sqrt(dx * dx + dz * dz)
end

-- Box of a step if it were frozen with its centre at x (used to test the ends of a sweep).
local function boxAtX(step, x)
	local hx = step.Size.X / 2
	local hz = step.Size.Z / 2
	return {
		x0 = x - hx,
		x1 = x + hx,
		z0 = step.Pos.Z - hz,
		z1 = step.Pos.Z + hz,
		y0 = step.Pos.Y - step.Size.Y,
		y1 = step.Pos.Y,
	}
end

-- X range a step's centre travels over (equal ends for static steps).
local function centreRange(step)
	local lo = step.Pos.X
	local hi = lo
	if step.Kind == "Moving" and step.Hazard and step.Hazard.EndOffset then
		hi = lo + step.Hazard.EndOffset.X
	end
	if hi < lo then
		lo, hi = hi, lo
	end
	return lo, hi
end

----------------------------------------------------------------------
-- Part 1: layout generator
----------------------------------------------------------------------
local function featuresFor(themeId, tier)
	if themeId == "bounce" then
		return { "Bounce" }
	elseif themeId == "moving" then
		return { "Moving" }
	elseif themeId == "vanish" then
		return { "Vanishing" }
	elseif themeId == "spin" then
		return { "SpinBarPlatform" }
	elseif themeId == "storm" then
		return { "StormPlatform" }
	elseif themeId == "lightning" then
		return { "LightningPlatform" }
	elseif themeId == "plates" then
		if tier >= 3 then
			return { "Vanishing", "Moving" }
		end
		return { "Moving", "Bounce" }
	elseif themeId == "mix" then
		return MIX_FEATURES[tier] or MIX_FEATURES[1]
	end
	return {}
end

function CourseBuilder.GenerateLayout(difficultyId, seed)
	local diff = Config.GetDifficulty(difficultyId) or Config.Difficulties[1]
	seed = seed or 0
	local rng = Util.NewRng(seed)
	local tier = tierOf(diff)

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

	local riseCap = math.min(diff.RiseMax, P.JumpHeight * 0.7)
	local dashLo, dashHi = dashRange(diff)
	local schedule = SCHEDULES[diff.Id] or SCHEDULES.Breeze
	local stageCount = diff.Stages
	local stepsLo = diff.StepsPerStage[1]
	local stepsHi = diff.StepsPerStage[2]

	local steps = {}
	local layout = {
		DifficultyId = diff.Id,
		Seed = seed,
		Steps = steps,
		Checkpoints = {},
		Stages = {},
		TotalTokens = 0,
	}

	steps[1] = {
		Index = 1,
		Stage = 0,
		Kind = "Start",
		Pos = Vector3.new(0, 0, 0),
		Size = Vector3.new(START_SIZE, TH, START_SIZE),
	}

	-- Sizes -----------------------------------------------------------
	local function sizeFor(kind, forceLo)
		local pmin, pmax = diff.PlatformMin, diff.PlatformMax
		local lo = pmin
		if kind == "Moving" or kind == "Bounce" or kind == "SpinBarPlatform" or kind == "StormPlatform" then
			lo = pmin + (pmax - pmin) * 0.45
		elseif kind == "LightningPlatform" then
			lo = pmin + (pmax - pmin) * 0.3
		end
		if forceLo and forceLo > lo then
			lo = forceLo
		end
		if lo > pmax then
			lo = pmax
		end
		local function pick()
			return Util.Clamp(snap(F(lo, pmax)), lo, pmax)
		end
		return pick(), pick()
	end

	-- Vertical step ---------------------------------------------------
	local function pickRise(kind, prevY)
		if kind == "PlateBridge" then
			return 0
		elseif kind == "DashGap" then
			if rng:Chance(0.5) then
				return F(0, 1.5)
			end
			return 0
		end
		local roll = F(0, 1)
		local r
		if roll < 0.2 then
			r = 0
		elseif roll < 0.72 then
			r = F(0.6, riseCap * 0.75)
		elseif roll < 0.93 then
			r = F(riseCap * 0.6, riseCap)
		else
			r = -F(0.5, 3)
		end
		if kind == "Moving" or kind == "SpinBarPlatform" or kind == "Vanishing" then
			r = math.min(r, 2.5)
		elseif kind == "Finish" then
			r = Util.Clamp(r, 0, 2)
		end
		if r < 0 and prevY < 3 then
			r = 0
		end
		if prevY + r < -6 then
			r = 0
		end
		if r < -MAX_DROP then
			r = -MAX_DROP
		end
		-- keep the planned gap range reachable
		while r > 0 and runReach(r) - 0.3 < diff.GapMin do
			r = r - 0.25
		end
		if r < 0.05 and r > 0 then
			r = 0
		end
		return r
	end

	local function pickGap(kind, rise, progress)
		if kind == "DashGap" or kind == "PlateBridge" then
			return F(dashLo, dashHi)
		end
		local hi = math.min(diff.GapMax, runReach(rise) - 0.3)
		local lo = diff.GapMin
		if hi < lo then
			hi = lo
		end
		local t = F(0.05, 0.55 + 0.45 * progress)
		if kind == "Vanishing" or kind == "Moving" then
			t = t * 0.8
		end
		return lo + (hi - lo) * t
	end

	-- Placement -------------------------------------------------------
	-- spec: kind, stage, sx, sz, rise, gap, mode ("straight"|"diag"), sweep (signed X travel),
	--       minOv, pull (bias towards the centre line)
	local function appendStep(spec)
		local prev = steps[#steps]
		local pbox = stepBox(prev)
		local sx, sz = spec.sx, spec.sz
		local gap = spec.gap
		local width = math.abs(spec.sweep or 0)
		local x, z
		local placed = false

		if spec.mode == "diag" and width == 0 and prev.Kind ~= "Moving" and FREE_FORM[spec.kind] then
			local theta = F(0.15, 0.6)
			local gx = gap * math.sin(theta)
			local gz = gap * math.cos(theta)
			local off = prev.Size.X / 2 + gx + sx / 2
			local sgn = 1
			if rng:Chance(0.5) then
				sgn = -1
			end
			if math.abs(prev.Pos.X + sgn * off) > LATERAL_SOFT then
				sgn = -sgn
			end
			if math.abs(prev.Pos.X + sgn * off) <= LATERAL_SOFT then
				x = prev.Pos.X + sgn * off
				z = prev.Pos.Z + prev.Size.Z / 2 + gz + sz / 2
				placed = true
			end
		end

		if not placed then
			z = prev.Pos.Z + prev.Size.Z / 2 + gap + sz / 2
			local minOv = spec.minOv or MIN_OVERLAP
			local W = (prev.Size.X + sx) / 2 - minOv
			local lo = math.max(pbox.cx1 - W, -LATERAL_SOFT)
			local hi = math.min(pbox.cx0 + W - width, LATERAL_SOFT - width)
			if hi < lo then
				local m = (lo + hi) / 2
				lo, hi = m, m
			end
			local target = F(lo, hi)
			local centre = Util.Clamp(0, lo, hi)
			if spec.pull then
				target = target * 0.3 + centre * 0.7
			elseif math.abs(prev.Pos.X) > 16 then
				target = target * 0.5 + centre * 0.5
			end
			x = target
			if (spec.sweep or 0) < 0 then
				x = target + width -- start at the right-hand end, travel left
			end
		end

		local step = {
			Index = #steps + 1,
			Stage = spec.stage,
			Kind = spec.kind,
			Pos = Vector3.new(x, prev.Pos.Y + spec.rise, z),
			Size = Vector3.new(sx, TH, sz),
			Gap = gap,
		}
		steps[#steps + 1] = step
		return step
	end

	-- Hazard parameter builders --------------------------------------
	local function hazardFor(step)
		local kind = step.Kind
		local minDim = math.min(step.Size.X, step.Size.Z)
		if kind == "SpinBarPlatform" then
			local speed = F(SPIN_SPEED[tier][1], SPIN_SPEED[tier][2])
			if rng:Chance(0.5) then
				speed = -speed
			end
			local count = 1
			if tier >= 3 and minDim >= 8 and rng:Chance(0.35) then
				count = 2
			end
			return {
				Speed = math.floor(speed),
				Damage = SPIN_DAMAGE[tier],
				Length = math.max(4, math.floor((minDim - 3) * 2) / 2),
				Count = count,
			}
		elseif kind == "StormPlatform" then
			return { DPS = STORM_DPS[tier], Height = 10 }
		elseif kind == "LightningPlatform" then
			local radius = Util.Clamp(minDim * 0.34, 2.2, 4.2)
			local maxOffX = math.max(0, step.Size.X / 2 - radius - 0.3)
			local maxOffZ = math.max(0, step.Size.Z / 2 - radius - 0.3)
			return {
				Damage = LIGHTNING_DAMAGE[tier],
				Interval = LIGHTNING_INTERVAL[tier],
				Warning = LIGHTNING_WARNING[tier],
				Radius = radius,
				ZoneOffset = Vector3.new(F(-maxOffX, maxOffX), 0, F(-maxOffZ, maxOffZ)),
			}
		elseif kind == "Vanishing" then
			local delay = math.max(VANISH_DELAY[tier], minVanishDelay(step.Size) + 0.05)
			return { VanishDelay = math.ceil(delay * 20) / 20, ReturnDelay = VANISH_RETURN[tier] }
		elseif kind == "Bounce" then
			return {
				Power = BOUNCE_POWER[tier],
				PadSize = Util.Clamp(minDim * 0.42, 3, 4.6),
			}
		end
		return nil
	end

	-- Plate bridge geometry (span + two side platforms with plates) ---
	local bridgeCount = 0
	local function attachBridge(step, prev)
		bridgeCount = bridgeCount + 1
		local ovLo = math.max(prev.Pos.X - prev.Size.X / 2, step.Pos.X - step.Size.X / 2)
		local ovHi = math.min(prev.Pos.X + prev.Size.X / 2, step.Pos.X + step.Size.X / 2)
		local spanX = (ovLo + ovHi) / 2
		local zFront = prev.Pos.Z + prev.Size.Z / 2
		local zBack = step.Pos.Z - step.Size.Z / 2
		local hazard = {
			BridgeNumber = bridgeCount,
			Span = {
				Pos = Vector3.new(spanX, prev.Pos.Y, (zFront + zBack) / 2),
				Size = Vector3.new(SPAN_WIDTH, SPAN_THICKNESS, (zBack - zFront) + 0.6),
			},
			Sides = {},
		}
		local sideLo = diff.GapMin
		local sideHi = math.max(sideLo, math.min(diff.GapMax, runReach(0)) - 1)
		local prevSign = nil
		for _, anchor in ipairs({ prev, step }) do
			local sgap = F(sideLo, sideHi)
			local sgn
			if anchor.Pos.X > 8 then
				sgn = -1
			elseif anchor.Pos.X < -8 then
				sgn = 1
			else
				sgn = 1
				if rng:Chance(0.5) then
					sgn = -1
				end
				if prevSign then
					sgn = -prevSign -- put the two plates on opposite sides
				end
			end
			prevSign = sgn
			local sideZ = Util.Clamp(anchor.Size.Z, 6, 9)
			local sx = anchor.Pos.X + sgn * (anchor.Size.X / 2 + sgap + SIDE_SIZE / 2)
			local side = {
				Pos = Vector3.new(sx, anchor.Pos.Y, anchor.Pos.Z),
				Size = Vector3.new(SIDE_SIZE, TH, sideZ),
				From = anchor.Index,
				Gap = sgap,
				Plate = {
					Pos = Vector3.new(sx, anchor.Pos.Y + PLATE_HEIGHT, anchor.Pos.Z),
					Size = Vector3.new(PLATE_SIZE, PLATE_HEIGHT, PLATE_SIZE),
				},
			}
			hazard.Sides[#hazard.Sides + 1] = side
		end
		step.Hazard = hazard
	end

	-- Stages ----------------------------------------------------------
	for stage = 1, stageCount do
		local progress = 0
		if stageCount > 1 then
			progress = (stage - 1) / (stageCount - 1)
		end
		local themeId = schedule[((stage - 1) % #schedule) + 1]
		if stage == stageCount and stageCount > 1 then
			themeId = "mix"
		end
		local n = I(stepsLo, stepsHi)

		-- 1. plan the kinds
		local kinds = {}
		for j = 1, n do
			kinds[j] = "Platform"
		end
		local features = featuresFor(themeId, tier)
		if #features > 0 and n >= 3 then
			local p = Util.Clamp(0.25 + diff.HazardChance * 1.2, 0.3, 0.9)
			if themeId == "plates" then
				p = p * 0.45
			elseif themeId == "mix" then
				p = math.min(0.9, p + 0.1)
			end
			local count = 0
			for j = 2, n do
				if rng:Chance(p) then
					kinds[j] = rng:Pick(features)
					count = count + 1
				end
			end
			local want = 2
			if themeId == "plates" then
				want = 1
			end
			local tries = 0
			while count < want and tries < 30 do
				local j = I(2, n)
				if kinds[j] == "Platform" then
					kinds[j] = rng:Pick(features)
					count = count + 1
				end
				tries = tries + 1
			end
		end
		for j = 2, n do
			local k, pk = kinds[j], kinds[j - 1]
			local stormy = (k == "StormPlatform" or k == "LightningPlatform")
			local prevStormy = (pk == "StormPlatform" or pk == "LightningPlatform")
			if (k == "Moving" and pk == "Moving")
				or (stormy and prevStormy)
				or (k == "SpinBarPlatform" and pk == "SpinBarPlatform" and tier < 3) then
				kinds[j] = "Platform"
			end
		end
		local wantPlate = false
		if tier >= 2 and n >= 3 then
			if themeId == "plates" then
				wantPlate = true
			elseif themeId == "mix" and rng:Chance(0.6) then
				wantPlate = true
			end
		end
		if wantPlate then
			local k = I(2, n)
			kinds[k] = "PlateBridge"
			kinds[k - 1] = "Platform"
		end
		if stage >= 2 and (diff.DashGapChance or 0) > 0 then
			for j = 1, n do
				local prevOk = (j == 1) or kinds[j - 1] == "Platform"
				if kinds[j] == "Platform" and prevOk and kinds[j + 1] ~= "PlateBridge"
					and rng:Chance(diff.DashGapChance) then
					kinds[j] = "DashGap"
				end
			end
		end

		-- 2. plan the sizes
		local sizes = {}
		for j = 1, n do
			local forceLo = nil
			if kinds[j] == "PlateBridge" or kinds[j + 1] == "PlateBridge" then
				forceLo = 7
			elseif kinds[j + 1] == "DashGap" then
				forceLo = 6
			end
			local a, b = sizeFor(kinds[j], forceLo)
			sizes[j] = { a, b }
		end
		sizes[n + 1] = { CHECKPOINT_SIZE, CHECKPOINT_SIZE }

		-- 3. place
		local firstIndex = #steps + 1
		for j = 1, n + 1 do
			local kind = "Checkpoint"
			if j <= n then
				kind = kinds[j]
			end
			local prev = steps[#steps]
			local sx, sz = sizes[j][1], sizes[j][2]
			local rise = pickRise(kind, prev.Pos.Y)
			if kind == "Checkpoint" then
				rise = Util.Clamp(rise, 0, riseCap * 0.7)
			end
			local sweep = nil

			if kind == "Moving" then
				local nxt = sizes[j + 1]
				local pb = stepBox(prev)
				local W = (prev.Size.X + sx) / 2 - MIN_OVERLAP
				local Wn = (sx + nxt[1]) / 2 - MIN_OVERLAP
				local maxW = math.min(2 * W - (pb.cx1 - pb.cx0), 2 * Wn) - 0.3
				local wLo, wHi = MOVE_WIDTH[tier][1], MOVE_WIDTH[tier][2]
				wHi = math.min(wHi, maxW)
				if wHi < 3.5 then
					kind = "Platform"
				else
					local w = F(math.min(wLo, wHi), wHi)
					sweep = w
					if rng:Chance(0.5) then
						sweep = -w
					end
				end
			end

			local gap = pickGap(kind, rise, progress)
			local mode = "straight"
			if FREE_FORM[kind] and kind ~= "Checkpoint" and rng:Chance(0.45) then
				mode = "diag"
			end
			local minOv = nil
			if kind == "PlateBridge" then
				minOv = PLATE_OVERLAP
			end
			local step = appendStep({
				kind = kind,
				stage = stage,
				sx = sx,
				sz = sz,
				rise = rise,
				gap = gap,
				mode = mode,
				sweep = sweep,
				minOv = minOv,
				pull = (kind == "Checkpoint"),
			})

			if kind == "Moving" then
				step.Hazard = {
					EndOffset = Vector3.new(sweep, 0, 0),
					Period = F(MOVE_PERIOD[tier][1], MOVE_PERIOD[tier][2]),
				}
			elseif kind == "PlateBridge" then
				attachBridge(step, prev)
			else
				step.Hazard = hazardFor(step)
			end
			if kind == "Checkpoint" then
				layout.Checkpoints[stage] = step.Index
			end
		end
		layout.Stages[stage] = {
			Index = stage,
			Theme = themeId,
			Name = THEME_NAMES[themeId] or "Sky Climb",
			FirstStep = firstIndex,
			LastStep = #steps,
		}
	end

	-- Finish ----------------------------------------------------------
	do
		local prev = steps[#steps]
		local rise = pickRise("Finish", prev.Pos.Y)
		local gap = pickGap("Finish", rise, 1)
		local step = appendStep({
			kind = "Finish",
			stage = stageCount,
			sx = FINISH_SIZE,
			sz = FINISH_SIZE,
			rise = rise,
			gap = gap,
			mode = "straight",
			pull = true,
		})
		step.Hazard = nil
	end

	CourseBuilder._PlaceTokens(layout, rng, diff)
	CourseBuilder._ComputeBounds(layout)
	return layout
end

----------------------------------------------------------------------
-- Tokens + bounds (called at the end of GenerateLayout)
----------------------------------------------------------------------
-- Every box that counts as solid geometry: steps (swept), plate spans and plate side platforms.
local function collectBoxes(layout)
	local boxes = {}
	for i, s in ipairs(layout.Steps) do
		local b = stepBox(s)
		b.Tag = "step"
		b.Id = i
		boxes[#boxes + 1] = b
		local h = s.Hazard
		if s.Kind == "PlateBridge" and h then
			if h.Span then
				local sp = slabBox(h.Span.Pos, h.Span.Size.X, h.Span.Size.Y, h.Span.Size.Z)
				sp.Tag = "span"
				sp.Id = i
				boxes[#boxes + 1] = sp
			end
			for _, side in ipairs(h.Sides or {}) do
				local sb = slabBox(side.Pos, side.Size.X, side.Size.Y, side.Size.Z)
				sb.Tag = "side"
				sb.Id = i
				sb.From = side.From
				boxes[#boxes + 1] = sb
			end
		end
	end
	return boxes
end

function CourseBuilder._PlaceTokens(layout, rng, diff)
	local steps = layout.Steps
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

	local function tokenOffsets(step, risky)
		local sx, sz = step.Size.X, step.Size.Z
		local kind = step.Kind
		local list = {}
		local function add(x, y, z)
			list[#list + 1] = Vector3.new(x, Util.Clamp(y, 3.1, 4.4), z)
		end
		if kind == "Bounce" then
			add(0, 3.8, 0) -- right above the pad: the bounce carries you through it
			return list
		elseif kind == "Moving" then
			add(step.Hazard.EndOffset.X / 2 + F(-1, 1), F(3.2, 4.2), F(-sz * 0.2, sz * 0.2))
			return list
		elseif (kind == "DashGap" or kind == "PlateBridge") and rng:Chance(0.65) then
			-- a token hanging in the middle of the chasm
			local prev = steps[step.Index - 1]
			local ovLo = math.max(prev.Pos.X - prev.Size.X / 2, step.Pos.X - step.Size.X / 2)
			local ovHi = math.min(prev.Pos.X + prev.Size.X / 2, step.Pos.X + step.Size.X / 2)
			add((ovLo + ovHi) / 2 - step.Pos.X, F(3.6, 4.3), -(sz / 2 + step.Gap / 2))
			return list
		end
		local y0 = F(3.2, 4.0)
		if risky then
			local side = I(1, 3)
			if side == 1 then
				add(F(-sx * 0.3, sx * 0.3), y0, sz / 2 - 0.5) -- forward edge
			elseif side == 2 then
				add(sx / 2 - 0.5, y0, F(-sz * 0.3, sz * 0.3))
			else
				add(-(sx / 2 - 0.5), y0, F(-sz * 0.3, sz * 0.3))
			end
			return list
		end
		local count = 1
		if rng:Chance(0.3) then
			count = I(2, 3)
		end
		local x0 = F(-sx * 0.2, sx * 0.2)
		local z0 = F(-sz * 0.15, sz * 0.15)
		for k = 1, count do
			local z = Util.Clamp(z0 + (k - (count + 1) / 2) * 2.4, -(sz / 2 - 0.8), sz / 2 - 0.8)
			local bump = 0
			if count == 3 and k == 2 then
				bump = 0.3
			end
			add(x0, y0 + bump, z)
		end
		return list
	end

	local total = 0
	for stage = 1, #layout.Stages do
		local info = layout.Stages[stage]
		local cands = {}
		for i = info.FirstStep, info.LastStep do
			local s = steps[i]
			if s.Kind ~= "Checkpoint" then
				cands[#cands + 1] = s
			end
		end
		if #cands < diff.TokensPerStage then
			cands[#cands + 1] = steps[info.LastStep] -- tiny stages: the checkpoint carries one too
		end
		for i = #cands, 2, -1 do
			local j = I(1, i)
			cands[i], cands[j] = cands[j], cands[i]
		end
		local want = math.min(#cands, diff.TokensPerStage + I(0, 2))
		local riskyCount = math.ceil(want * 0.4)
		for k = 1, want do
			local s = cands[k]
			s.Tokens = tokenOffsets(s, k <= riskyCount)
			total = total + #s.Tokens
		end
	end
	layout.TotalTokens = total
end

function CourseBuilder._ComputeBounds(layout)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, b in ipairs(collectBoxes(layout)) do
		minX = math.min(minX, b.x0)
		minY = math.min(minY, b.y0)
		minZ = math.min(minZ, b.z0)
		maxX = math.max(maxX, b.x1)
		maxY = math.max(maxY, b.y1)
		maxZ = math.max(maxZ, b.z1)
	end
	-- headroom for arches, storm volumes and cloud puffs
	layout.Bounds = {
		Min = Vector3.new(minX, minY - 6, minZ),
		Max = Vector3.new(maxX, maxY + 16, maxZ),
	}
end

----------------------------------------------------------------------
-- Part 2: validator
----------------------------------------------------------------------
local KNOWN_KINDS = { Start = true, Finish = true, Checkpoint = true }
for kind in pairs(REGULAR_KINDS) do
	KNOWN_KINDS[kind] = true
end

function CourseBuilder.ValidateLayout(layout)
	local problems = {}
	local function bad(fmt, ...)
		if #problems < 60 then
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

	local riseCap = math.min(diff.RiseMax, P.JumpHeight * 0.7)
	local dashLo, dashHi = dashRange(diff)

	-- 1. structure + sizes --------------------------------------------
	if steps[1].Kind ~= "Start" then
		bad("first step must be Start, got %s", tostring(steps[1].Kind))
	end
	if steps[n].Kind ~= "Finish" then
		bad("last step must be Finish, got %s", tostring(steps[n].Kind))
	end
	for i, s in ipairs(steps) do
		if s.Index ~= i then
			bad("step %d has Index %s", i, tostring(s.Index))
		end
		if not KNOWN_KINDS[s.Kind] then
			bad("step %d has unknown Kind %s", i, tostring(s.Kind))
		end
		if not s.Pos or not s.Size then
			bad("step %d is missing Pos/Size", i)
			return false, problems
		end
		local sx, sz = s.Size.X, s.Size.Z
		if s.Kind == "Start" then
			if sx < 24 or sz < 24 then
				bad("Start platform %.1fx%.1f is smaller than 24x24", sx, sz)
			end
		elseif s.Kind == "Finish" then
			if sx < 28 or sz < 28 then
				bad("Finish platform %.1fx%.1f is smaller than 28x28", sx, sz)
			end
		elseif s.Kind == "Checkpoint" then
			if sx < 14 or sz < 14 then
				bad("Checkpoint %d platform %.1fx%.1f is smaller than 14x14", i, sx, sz)
			end
		else
			if sx < diff.PlatformMin - EPS or sx > diff.PlatformMax + EPS
				or sz < diff.PlatformMin - EPS or sz > diff.PlatformMax + EPS then
				bad("step %d (%s) size %.1fx%.1f outside [%s, %s]", i, s.Kind, sx, sz,
					tostring(diff.PlatformMin), tostring(diff.PlatformMax))
			end
			if s.Kind == "PlateBridge" and (sx < 7 - EPS or sz < 7 - EPS) then
				bad("PlateBridge step %d is smaller than 7x7", i)
			end
		end
		if s.Pos.Y < -10 - EPS then
			bad("step %d is lower than origin.Y - 10 (%.1f)", i, s.Pos.Y)
		end
		local lo, hi = centreRange(s)
		if math.abs(lo) > LATERAL_LIMIT + EPS or math.abs(hi) > LATERAL_LIMIT + EPS then
			bad("step %d wanders laterally to %.1f / %.1f (limit %d)", i, lo, hi, LATERAL_LIMIT)
		end
	end

	-- 2. every consecutive pair is traversable -------------------------
	for i = 2, n do
		local prev, s = steps[i - 1], steps[i]
		local pb, sb = stepBox(prev), stepBox(s)
		if s.Pos.Z <= prev.Pos.Z or sb.z0 < pb.z1 + 0.5 then
			bad("step %d does not progress towards +Z", i)
		end

		local pLo, pHi = centreRange(prev)
		local sLo, sHi = centreRange(s)
		local worst, best = 0, math.huge
		for _, px in ipairs({ pLo, pHi }) do
			for _, sx in ipairs({ sLo, sHi }) do
				local g = footGap(boxAtX(prev, px), boxAtX(s, sx))
				worst = math.max(worst, g)
				best = math.min(best, g)
			end
		end
		if worst - best > 0.05 then
			bad("step %d: gap to step %d varies from %.2f to %.2f while clouds move", i, i - 1, best, worst)
		end
		if type(s.Gap) ~= "number" or math.abs(s.Gap - worst) > 0.05 then
			bad("step %d: Gap field %s does not match geometry (%.2f)", i, tostring(s.Gap), worst)
		end

		local rise = s.Pos.Y - prev.Pos.Y
		if rise > riseCap + EPS then
			bad("step %d rises %.2f (cap %.2f)", i, rise, riseCap)
		end
		if rise < -MAX_DROP - EPS then
			bad("step %d drops %.2f (limit -%d)", i, rise, MAX_DROP)
		end

		if s.Kind == "DashGap" or s.Kind == "PlateBridge" then
			if worst < dashLo - EPS or worst > dashHi + EPS then
				bad("step %d dash gap %.2f outside [%.1f, %.1f]", i, worst, dashLo, dashHi)
			end
			if worst > 0.85 * P.MaxDashGap + EPS then
				bad("step %d dash gap %.2f exceeds 0.85 * MaxDashGap", i, worst)
			end
			if worst <= P.MaxRunGap * 0.75 then
				bad("step %d dash gap %.2f does not need a dash", i, worst)
			end
			if rise < -EPS or rise > 2 + EPS then
				bad("step %d dash gap rise %.2f outside [0, 2]", i, rise)
			end
			if worst > dashReach(rise) + EPS then
				bad("step %d dash gap %.2f exceeds dash reach %.2f", i, worst, dashReach(rise))
			end
			if not STATIC_PREV[prev.Kind] then
				bad("step %d needs a static run-up platform, got %s", i, tostring(prev.Kind))
			end
			if math.min(prev.Size.X, prev.Size.Z) < 5 then
				bad("step %d run-up platform is too small for the DASH sign", i)
			end
		else
			if worst < diff.GapMin - EPS or worst > diff.GapMax + EPS then
				bad("step %d gap %.2f outside [%s, %s]", i, worst, tostring(diff.GapMin), tostring(diff.GapMax))
			end
			if worst > runReach(rise) + EPS then
				bad("step %d gap %.2f exceeds run-jump reach %.2f for rise %.2f", i, worst, runReach(rise), rise)
			end
		end
	end

	-- 3. hazards ---------------------------------------------------------
	for i, s in ipairs(steps) do
		local h = s.Hazard
		local minDim = math.min(s.Size.X, s.Size.Z)
		if s.Kind == "Moving" then
			if not h or not h.EndOffset or type(h.Period) ~= "number" then
				bad("Moving step %d lacks EndOffset/Period", i)
			else
				local dx = h.EndOffset.X
				if math.abs(dx) < 3.5 or math.abs(h.EndOffset.Y) > EPS or math.abs(h.EndOffset.Z) > EPS then
					bad("Moving step %d must travel >= 3.5 studs along X only", i)
				end
				if h.Period < 2 or math.abs(dx) / h.Period > 4.2 then
					bad("Moving step %d is too fast (%.1f studs in %.1fs)", i, math.abs(dx), h.Period)
				end
			end
		elseif s.Kind == "SpinBarPlatform" then
			if not h or type(h.Speed) ~= "number" or h.Speed == 0 or math.abs(h.Speed) > 150
				or type(h.Damage) ~= "number" or h.Damage <= 0 or type(h.Length) ~= "number" then
				bad("SpinBar step %d has bad Speed/Damage/Length", i)
			else
				if h.Length > minDim - 2.5 + EPS or h.Length < 3 then
					bad("SpinBar step %d length %.1f does not fit a %.1f platform", i, h.Length, minDim)
				end
				if h.Count ~= 1 and h.Count ~= 2 then
					bad("SpinBar step %d has bad Count", i)
				end
			end
		elseif s.Kind == "StormPlatform" then
			if not h or type(h.DPS) ~= "number" or h.DPS <= 0 then
				bad("Storm step %d lacks DPS", i)
			end
		elseif s.Kind == "LightningPlatform" then
			if not h or type(h.Damage) ~= "number" or type(h.Interval) ~= "number"
				or type(h.Warning) ~= "number" or type(h.Radius) ~= "number" or not h.ZoneOffset then
				bad("Lightning step %d lacks parameters", i)
			else
				if h.Interval < 2.5 or h.Warning < 0.8 or h.Warning >= h.Interval then
					bad("Lightning step %d has unfair timing (%.1f / %.1f)", i, h.Interval, h.Warning)
				end
				if math.abs(h.ZoneOffset.X) + h.Radius > s.Size.X / 2 + EPS
					or math.abs(h.ZoneOffset.Z) + h.Radius > s.Size.Z / 2 + EPS then
					bad("Lightning step %d zone leaves the platform", i)
				end
			end
		elseif s.Kind == "Vanishing" then
			if not h or type(h.VanishDelay) ~= "number" or type(h.ReturnDelay) ~= "number" then
				bad("Vanishing step %d lacks delays", i)
			else
				if h.VanishDelay < minVanishDelay(s.Size) - EPS then
					bad("Vanishing step %d vanishes after %.2fs but crossing needs %.2fs", i, h.VanishDelay,
						minVanishDelay(s.Size))
				end
				if h.ReturnDelay < h.VanishDelay + 1 then
					bad("Vanishing step %d returns too quickly", i)
				end
			end
		elseif s.Kind == "Bounce" then
			if not h or type(h.Power) ~= "number" or h.Power < 50 or h.Power > 90
				or type(h.PadSize) ~= "number" or h.PadSize > minDim * 0.5 + EPS then
				bad("Bounce step %d has bad Power/PadSize", i)
			end
		elseif s.Kind == "PlateBridge" then
			if not h or not h.Span or not h.Sides or #h.Sides ~= 2 or type(h.BridgeNumber) ~= "number" then
				bad("PlateBridge step %d lacks Span/Sides", i)
			else
				local prev = steps[i - 1]
				local zFront = prev.Pos.Z + prev.Size.Z / 2
				local zBack = s.Pos.Z - s.Size.Z / 2
				local spanBox = slabBox(h.Span.Pos, h.Span.Size.X, h.Span.Size.Y, h.Span.Size.Z)
				if spanBox.z0 > zFront + EPS or spanBox.z1 < zBack - EPS then
					bad("PlateBridge %d span does not reach both platforms", i)
				end
				if math.abs(h.Span.Pos.Y - prev.Pos.Y) > EPS or math.abs(prev.Pos.Y - s.Pos.Y) > EPS then
					bad("PlateBridge %d span is not level", i)
				end
				local px0 = math.max(prev.Pos.X - prev.Size.X / 2, s.Pos.X - s.Size.X / 2)
				local px1 = math.min(prev.Pos.X + prev.Size.X / 2, s.Pos.X + s.Size.X / 2)
				if spanBox.x0 < px0 - EPS or spanBox.x1 > px1 + EPS then
					bad("PlateBridge %d span is wider than the overlap of its platforms", i)
				end
				local seenFrom = {}
				for _, side in ipairs(h.Sides) do
					local anchor = steps[side.From]
					if not anchor or (side.From ~= i - 1 and side.From ~= i) then
						bad("PlateBridge %d side platform has a bad anchor", i)
					else
						seenFrom[side.From] = true
						local sbx = slabBox(side.Pos, side.Size.X, side.Size.Y, side.Size.Z)
						local g = footGap(sbx, stepBox(anchor))
						if g < diff.GapMin - EPS or g > diff.GapMax + EPS or g > runReach(0) + EPS then
							bad("PlateBridge %d side platform gap %.2f is not reachable without the bridge", i, g)
						end
						if math.abs(side.Pos.Y - anchor.Pos.Y) > EPS then
							bad("PlateBridge %d side platform is not level with its anchor", i)
						end
						if math.abs(side.Pos.X) > LATERAL_LIMIT + SIDE_SIZE then
							bad("PlateBridge %d side platform wanders too far", i)
						end
						local pl = side.Plate
						if not pl or math.abs(pl.Pos.X - side.Pos.X) > side.Size.X / 2 - pl.Size.X / 2 + EPS
							or math.abs(pl.Pos.Z - side.Pos.Z) > side.Size.Z / 2 - pl.Size.Z / 2 + EPS then
							bad("PlateBridge %d plate is not on its side platform", i)
						end
					end
				end
				if not seenFrom[i - 1] or not seenFrom[i] then
					bad("PlateBridge %d needs one plate before and one after the chasm", i)
				end
			end
		end
	end

	-- 4. checkpoints + stages ------------------------------------------
	local cpCount = 0
	for _, s in ipairs(steps) do
		if s.Kind == "Checkpoint" then
			cpCount = cpCount + 1
		end
	end
	if cpCount ~= diff.Stages then
		bad("expected %d checkpoints, found %d", diff.Stages, cpCount)
	end
	local cps = layout.Checkpoints or {}
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
	local perStage = {}
	for _, s in ipairs(steps) do
		if REGULAR_KINDS[s.Kind] then
			perStage[s.Stage] = (perStage[s.Stage] or 0) + 1
		end
	end
	for k = 1, diff.Stages do
		local c = perStage[k] or 0
		if c < diff.StepsPerStage[1] or c > diff.StepsPerStage[2] then
			bad("stage %d has %d steps (expected %d-%d)", k, c, diff.StepsPerStage[1], diff.StepsPerStage[2])
		end
	end
	for i = 2, n do
		if steps[i].Stage < steps[i - 1].Stage then
			bad("step %d goes back to an earlier stage", i)
		end
	end

	-- 5. separation (nothing intersects, 2 stud clearance) ------------------
	local boxes = collectBoxes(layout)
	for a = 1, #boxes do
		for b = a + 1, #boxes do
			local A, B = boxes[a], boxes[b]
			local exempt = false
			if A.Tag == "step" and B.Tag == "step" and math.abs(A.Id - B.Id) == 1 then
				exempt = true -- adjacent hops are covered by the gap rules above
			elseif A.Tag == "span" and B.Tag == "step" and (B.Id == A.Id or B.Id == A.Id - 1) then
				exempt = true -- the span deliberately touches its two platforms
			elseif B.Tag == "span" and A.Tag == "step" and (A.Id == B.Id or A.Id == B.Id - 1) then
				exempt = true
			elseif A.Tag == "side" and B.Tag == "step" and B.Id == A.From then
				exempt = true -- side platform gap is validated above
			elseif B.Tag == "side" and A.Tag == "step" and A.Id == B.From then
				exempt = true
			end
			if not exempt then
				local gx = axisGap(A.x0, A.x1, B.x0, B.x1)
				local gy = axisGap(A.y0, A.y1, B.y0, B.y1)
				local gz = axisGap(A.z0, A.z1, B.z0, B.z1)
				if math.max(gx, gy, gz) < 2 - EPS then
					bad("%s %d and %s %d are closer than 2 studs", A.Tag, A.Id, B.Tag, B.Id)
				end
			end
		end
	end

	-- 6. tokens ------------------------------------------------------------
	local counted = 0
	local stageSteps = {}
	for i, s in ipairs(steps) do
		if s.Tokens and #s.Tokens > 0 then
			stageSteps[s.Stage] = (stageSteps[s.Stage] or 0) + 1
			local lo, hi = centreRange(s)
			for _, t in ipairs(s.Tokens) do
				counted = counted + 1
				if t.Y < 3 - EPS or t.Y > 4.5 + EPS then
					bad("step %d token height %.2f outside [3, 4.5]", i, t.Y)
				end
				local zMin = -s.Size.Z / 2 - 0.3
				if s.Kind == "DashGap" or s.Kind == "PlateBridge" then
					zMin = -(s.Size.Z / 2 + (s.Gap or 0)) - 0.3
				end
				if (s.Pos.X + t.X) < lo - s.Size.X / 2 - 0.3 or (s.Pos.X + t.X) > hi + s.Size.X / 2 + 0.3
					or t.Z < zMin or t.Z > s.Size.Z / 2 + 0.3 then
					bad("step %d token (%.1f, %.1f) is outside the platform", i, t.X, t.Z)
				end
				local wx, wy, wz = s.Pos.X + t.X, s.Pos.Y + t.Y, s.Pos.Z + t.Z
				for _, b in ipairs(boxes) do
					if wx > b.x0 - 0.3 and wx < b.x1 + 0.3 and wz > b.z0 - 0.3 and wz < b.z1 + 0.3
						and wy > b.y0 - 0.3 and wy < b.y1 + 0.3 then
						bad("step %d token is inside %s %d", i, b.Tag, b.Id)
						break
					end
				end
			end
		end
	end
	if counted ~= layout.TotalTokens then
		bad("TotalTokens %s does not match %d placed tokens", tostring(layout.TotalTokens), counted)
	end
	for k = 1, diff.Stages do
		if (stageSteps[k] or 0) < diff.TokensPerStage then
			bad("stage %d has tokens on %d steps (need %d)", k, stageSteps[k] or 0, diff.TokensPerStage)
		end
	end

	-- 7. bounds --------------------------------------------------------------
	local bnd = layout.Bounds
	if not bnd or not bnd.Min or not bnd.Max then
		bad("layout has no Bounds")
	else
		for _, b in ipairs(boxes) do
			if b.x0 < bnd.Min.X - EPS or b.x1 > bnd.Max.X + EPS or b.y0 < bnd.Min.Y - EPS
				or b.y1 > bnd.Max.Y + EPS or b.z0 < bnd.Min.Z - EPS or b.z1 > bnd.Max.Z + EPS then
				bad("%s %d lies outside Bounds", b.Tag, b.Id)
				break
			end
		end
	end

	return #problems == 0, problems
end

----------------------------------------------------------------------
-- Part 3: builder
----------------------------------------------------------------------
local PART_BUDGET = 1000 -- ambient decoration is skipped once this many parts exist (tokens add ~300 more)

local CLOUD_TINTS = {
	Color3.fromRGB(250, 252, 255),
	Color3.fromRGB(255, 243, 248),
	Color3.fromRGB(240, 247, 255),
	Color3.fromRGB(255, 250, 240),
}
local PLATE_COLORS = {
	Color3.fromRGB(255, 120, 200),
	Color3.fromRGB(110, 230, 255),
	Color3.fromRGB(150, 255, 160),
	Color3.fromRGB(255, 214, 90),
}
local BAR_RED = Color3.fromRGB(255, 96, 118)
local DASH_GOLD = Color3.fromRGB(255, 196, 70)
local STORM_DARK = Color3.fromRGB(58, 62, 86)

-- Create one anchored Part inside a group folder.
-- opts: Shape, Collide (default true), Decor (no collide/touch/query/shadow), Transparency
local function mk(ctx, group, name, size, cf, color, material, opts)
	opts = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	if opts.Shape then
		p.Shape = opts.Shape
	end
	p.Size = size
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = opts.Transparency or 0
	if opts.Decor then
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CastShadow = false
	else
		p.CanCollide = (opts.Collide ~= false)
	end
	p.CFrame = cf
	p.Parent = ctx.Groups[group]
	ctx.Parts = ctx.Parts + 1
	return p
end

-- An invisible, tiny anchor for BillboardGuis.
local function mkAnchor(ctx, group, pos)
	return mk(ctx, group, "SignAnchor", Vector3.new(0.4, 0.4, 0.4), CFrame.new(pos), Theme.Colors.White,
		Enum.Material.SmoothPlastic, { Decor = true, Transparency = 1 })
end

-- Cylinder helpers. Roblox cylinders have their axis along X, so we roll them upright.
local function upright(pos)
	return CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2)
end

local function tintFor(index)
	return CLOUD_TINTS[(index % #CLOUD_TINTS) + 1]
end

-- World-space-sized BillboardGui (scale units are studs).
local function billboard(part, widthStuds, heightStuds, yOffset, maxDistance)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.new(widthStuds, 0, heightStuds, 0)
	gui.StudsOffset = Vector3.new(0, yOffset or 0, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = maxDistance or 140
	gui.Parent = part
	return gui
end

local function surfaceGui(part, face, pixelsPerStud)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 50
	gui.LightInfluence = 0
	gui.Parent = part
	return gui
end

-- Themed text label filling a fraction of its parent. yScale/hScale are 0..1.
local function addText(parent, text, role, color, yScale, hScale, extraProps)
	local props = {
		Size = UDim2.new(1, 0, hScale, 0),
		Position = UDim2.new(0, 0, yScale, 0),
		TextWrapped = true,
	}
	if extraProps then
		for k, v in pairs(extraProps) do
			props[k] = v
		end
	end
	local label = Theme.Label(text, role, { Scaled = true, Color = color, Stroke = 0.35, Props = props })
	label.Parent = parent
	return label
end

local function sparkles(parent, color, rate, speed, lifetime, size)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(color)
	e.Rate = rate
	e.Lifetime = NumberRange.new(lifetime * 0.6, lifetime)
	e.Speed = NumberRange.new(speed * 0.5, speed)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	e.LightEmission = 0.8
	e.Parent = parent
	return e
end

-- Decor on parts that move (moving clouds, spin bars) is welded to the moving root once the
-- whole course is parented into the world; `weldLater` just remembers the pair.
local function weldLater(ctx, root, part)
	ctx.Welds[#ctx.Welds + 1] = { root, part }
end

local function applyWelds(ctx)
	for _, pair in ipairs(ctx.Welds) do
		local root, part = pair[1], pair[2]
		if root.Parent and part.Parent then
			part.Anchored = false
			part.Massless = true
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = root
		end
	end
end

-- A cloud platform: walkable slab + glowing difficulty-colour trim + puffy underside.
-- opts: Name, Color, TrimColor, Single (slab only), Dynamic (decor welded to the slab)
local function buildCloud(ctx, step, opts)
	opts = opts or {}
	local sx, sz = step.Size.X, step.Size.Z
	local top = ctx.Origin + step.Pos
	local main = mk(ctx, "Platforms", opts.Name or ("Step_" .. step.Index), Vector3.new(sx, TH, sz),
		CFrame.new(top - Vector3.new(0, TH / 2, 0)), opts.Color or tintFor(step.Index),
		Enum.Material.SmoothPlastic)
	main:SetAttribute("StepIndex", step.Index)
	main:SetAttribute("Stage", step.Stage)
	local decor = {}
	if opts.Single then
		return main, decor
	end

	local trim = opts.TrimColor or ctx.Diff.Color
	local function strip(size, offset)
		local p = mk(ctx, "Decor", "Trim", size, CFrame.new(top + offset), trim, Enum.Material.Neon,
			{ Decor = true, Transparency = 0.1 })
		decor[#decor + 1] = p
	end
	strip(Vector3.new(sx, 0.22, 0.5), Vector3.new(0, 0.11, sz / 2 - 0.25))
	strip(Vector3.new(sx, 0.22, 0.5), Vector3.new(0, 0.11, -sz / 2 + 0.25))
	strip(Vector3.new(0.5, 0.22, sz - 1), Vector3.new(sx / 2 - 0.25, 0.11, 0))
	strip(Vector3.new(0.5, 0.22, sz - 1), Vector3.new(-sx / 2 + 0.25, 0.11, 0))

	-- puffy underside: balls whose tops stay below the walking surface
	for k = 1, 3 do
		local d = ctx.Rng:NextNumber(2.4, 4.4)
		local px = ctx.Rng:NextNumber(-1, 1) * math.max(0, sx / 2 - d * 0.4)
		local pz = ctx.Rng:NextNumber(-1, 1) * math.max(0, sz / 2 - d * 0.4)
		local color = Theme.Colors.Cloud
		if k % 2 == 0 then
			color = Theme.Colors.CloudShade
		end
		local ball = mk(ctx, "Decor", "Puff", Vector3.new(d, d, d),
			CFrame.new(top + Vector3.new(px, -0.7 - d * 0.35, pz)), color, Enum.Material.SmoothPlastic,
			{ Shape = Enum.PartType.Ball, Decor = true })
		decor[#decor + 1] = ball
	end

	if opts.Dynamic then
		for _, p in ipairs(decor) do
			weldLater(ctx, main, p)
		end
	end
	return main, decor
end

local function darkPuffs(ctx, centre, count, spread, minD, maxD)
	for _ = 1, count do
		local d = ctx.Rng:NextNumber(minD, maxD)
		local off = Vector3.new(ctx.Rng:NextNumber(-spread, spread), ctx.Rng:NextNumber(-0.8, 0.8),
			ctx.Rng:NextNumber(-spread, spread))
		mk(ctx, "Decor", "StormPuff", Vector3.new(d, d, d), CFrame.new(centre + off), STORM_DARK,
			Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball, Decor = true, Transparency = 0.12 })
	end
end

----------------------------------------------------------------------
-- Per-kind builders
----------------------------------------------------------------------
local function buildMoving(ctx, step)
	local h = step.Hazard
	local main = buildCloud(ctx, step, {
		Name = "MovingCloud_" .. step.Index,
		Dynamic = true,
		TrimColor = Color3.fromRGB(120, 230, 255),
	})
	CollectionService:AddTag(main, Tags.MovingCloud)
	main:SetAttribute("EndOffset", h.EndOffset)
	main:SetAttribute("Period", h.Period)

	-- a faint glowing rail under the route shows where the cloud travels
	local top = ctx.Origin + step.Pos
	local dx = h.EndOffset.X
	local railY = -TH - 3.2
	mk(ctx, "Decor", "MoveRail", Vector3.new(math.abs(dx) + step.Size.X, 0.2, 0.5),
		CFrame.new(top + Vector3.new(dx / 2, railY, 0)), Color3.fromRGB(120, 230, 255), Enum.Material.Neon,
		{ Decor = true, Transparency = 0.55 })
	for _, ex in ipairs({ 0, dx }) do
		mk(ctx, "Decor", "MoveStop", Vector3.new(1.2, 1.2, 1.2), CFrame.new(top + Vector3.new(ex, railY, 0)),
			Color3.fromRGB(120, 230, 255), Enum.Material.Neon,
			{ Shape = Enum.PartType.Ball, Decor = true, Transparency = 0.3 })
	end
	return main
end

local function buildVanishing(ctx, step)
	local h = step.Hazard
	local ghost = ctx.Diff.Color:Lerp(Theme.Colors.Cloud, 0.7)
	local main = buildCloud(ctx, step, { Name = "VanishCloud_" .. step.Index, Single = true, Color = ghost })
	main.Transparency = 0.12
	CollectionService:AddTag(main, Tags.VanishCloud)
	main:SetAttribute("VanishDelay", h.VanishDelay)
	main:SetAttribute("ReturnDelay", h.ReturnDelay)
	sparkles(main, ctx.Diff.Color, 3, 2, 1.6, 0.7)
	return main
end

local function buildBounce(ctx, step)
	local h = step.Hazard
	local main = buildCloud(ctx, step, { Name = "BounceCloud_" .. step.Index })
	local top = ctx.Origin + step.Pos
	local pad = h.PadSize
	local color = Theme.Colors.Rainbow[(step.Index % #Theme.Colors.Rainbow) + 1]
	local p = mk(ctx, "Hazards", "BouncePad", Vector3.new(pad, 0.7, pad), CFrame.new(top + Vector3.new(0, 0.35, 0)),
		color, Enum.Material.Neon)
	CollectionService:AddTag(p, Tags.BouncePad)
	p:SetAttribute("Power", h.Power)
	local gui = surfaceGui(p, Enum.NormalId.Top, 60)
	addText(gui, "▲", "Accent", Theme.Colors.White, 0.05, 0.9)
	sparkles(p, color, 5, 6, 1.2, 0.8)
	return main
end

local function buildSpinBars(ctx, step)
	local h = step.Hazard
	local main = buildCloud(ctx, step, { Name = "SpinPlatform_" .. step.Index, TrimColor = BAR_RED })
	local top = ctx.Origin + step.Pos
	local count = h.Count or 1
	for k = 1, count do
		local angle = (k - 1) * math.pi / count
		local cf = CFrame.new(top + Vector3.new(0, 0.95, 0)) * CFrame.Angles(0, angle, 0)
		local bar = mk(ctx, "Hazards", "SpinBar", Vector3.new(h.Length, 1.5, 1.1), cf, BAR_RED, Enum.Material.Neon)
		CollectionService:AddTag(bar, Tags.SpinBar)
		bar:SetAttribute("Speed", h.Speed)
		bar:SetAttribute("Damage", h.Damage)
		for _, sgn in ipairs({ -1, 1 }) do
			local cap = mk(ctx, "Decor", "BarCap", Vector3.new(1.9, 1.9, 1.9),
				cf * CFrame.new(sgn * h.Length / 2, 0, 0), Theme.Colors.White, Enum.Material.Neon,
				{ Shape = Enum.PartType.Ball, Decor = true })
			weldLater(ctx, bar, cap)
		end
		if k == 1 then
			local hub = mk(ctx, "Decor", "BarHub", Vector3.new(2.4, 1.8, 1.8),
				CFrame.new(top + Vector3.new(0, 1.15, 0)) * CFrame.Angles(0, 0, math.pi / 2), Theme.Colors.PanelLight,
				Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder, Decor = true })
			weldLater(ctx, bar, hub)
		end
	end
	return main
end

local function buildStorm(ctx, step)
	local h = step.Hazard
	local main = buildCloud(ctx, step, { Name = "StormPlatform_" .. step.Index, TrimColor = Color3.fromRGB(140, 150, 200) })
	local top = ctx.Origin + step.Pos
	local height = h.Height or 10
	local vol = mk(ctx, "Hazards", "StormCloud", Vector3.new(step.Size.X + 2, height, step.Size.Z + 2),
		CFrame.new(top + Vector3.new(0, height / 2, 0)), Theme.Colors.Storm, Enum.Material.SmoothPlastic,
		{ Collide = false, Transparency = 0.74 })
	vol.CastShadow = false
	CollectionService:AddTag(vol, Tags.StormCloud)
	vol:SetAttribute("DPS", h.DPS)
	darkPuffs(ctx, top + Vector3.new(0, height + 1, 0), 4, math.min(step.Size.X, step.Size.Z) * 0.35, 5, 8)
	return main
end

local function buildLightning(ctx, step)
	local h = step.Hazard
	local main = buildCloud(ctx, step, { Name = "LightningPlatform_" .. step.Index, TrimColor = Color3.fromRGB(255, 226, 90) })
	local top = ctx.Origin + step.Pos
	local zonePos = top + h.ZoneOffset
	local d = h.Radius * 2
	local zone = mk(ctx, "Hazards", "LightningZone", Vector3.new(d, 0.2, d), CFrame.new(zonePos + Vector3.new(0, 0.1, 0)),
		Color3.fromRGB(255, 80, 90), Enum.Material.Neon, { Collide = false, Transparency = 1 })
	zone.CastShadow = false
	CollectionService:AddTag(zone, Tags.LightningZone)
	zone:SetAttribute("Damage", h.Damage)
	zone:SetAttribute("Interval", h.Interval)
	zone:SetAttribute("Warning", h.Warning)
	zone:SetAttribute("Radius", h.Radius)
	-- a permanent faint ring so players can read where bolts land
	mk(ctx, "Decor", "StrikeMark", Vector3.new(0.08, d, d), upright(zonePos + Vector3.new(0, 0.07, 0)),
		Color3.fromRGB(255, 80, 90), Enum.Material.Neon, { Shape = Enum.PartType.Cylinder, Decor = true, Transparency = 0.8 })
	darkPuffs(ctx, top + Vector3.new(0, 13, 0), 3, 3, 4.5, 6.5)
	local anchor = mkAnchor(ctx, "Signs", top + Vector3.new(h.ZoneOffset.X, 8, h.ZoneOffset.Z))
	local gui = billboard(anchor, 3, 3, 0, 110)
	addText(gui, "⚡", "Accent", Color3.fromRGB(255, 226, 90), 0, 1)
	return main
end

-- Co-op chasm: a bridge that only exists while someone holds a plate on a side platform.
local function buildPlateBridge(ctx, step)
	local h = step.Hazard
	local main = buildCloud(ctx, step, { Name = "BridgeLanding_" .. step.Index })
	local color = PLATE_COLORS[(h.BridgeNumber % #PLATE_COLORS) + 1]
	local bridgeId = "bridge" .. tostring(h.BridgeNumber)

	-- the bridge span itself (HazardService fades it in and out)
	local spanTop = ctx.Origin + h.Span.Pos
	local span = mk(ctx, "Hazards", "PlateBridge", h.Span.Size, CFrame.new(spanTop - Vector3.new(0, h.Span.Size.Y / 2, 0)),
		color:Lerp(Theme.Colors.White, 0.35), Enum.Material.Neon, { Transparency = 0.2 })
	CollectionService:AddTag(span, Tags.PlateBridge)
	span:SetAttribute("BridgeId", bridgeId)

	-- ghost rails stay visible while the bridge is retracted so the route is readable
	for _, sgn in ipairs({ -1, 1 }) do
		mk(ctx, "Decor", "GhostRail", Vector3.new(0.3, 0.3, h.Span.Size.Z),
			CFrame.new(spanTop + Vector3.new(sgn * (h.Span.Size.X / 2 - 0.15), 0.15, 0)), color, Enum.Material.Neon,
			{ Decor = true, Transparency = 0.45 })
	end

	for sideIndex, side in ipairs(h.Sides) do
		local fake = {
			Index = step.Index,
			Stage = step.Stage,
			Pos = side.Pos,
			Size = side.Size,
		}
		buildCloud(ctx, fake, { Name = "PlateIsland_" .. step.Index .. "_" .. sideIndex, TrimColor = color })
		local plateTop = ctx.Origin + side.Plate.Pos
		local plate = mk(ctx, "Hazards", "PressurePlate", side.Plate.Size,
			CFrame.new(plateTop - Vector3.new(0, side.Plate.Size.Y / 2, 0)), color, Enum.Material.Neon)
		CollectionService:AddTag(plate, Tags.PressurePlate)
		plate:SetAttribute("BridgeId", bridgeId)
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = 12
		light.Brightness = 1.2
		light.Parent = plate
		local gui = surfaceGui(plate, Enum.NormalId.Top, 60)
		addText(gui, "HOLD", "Heading", Theme.Colors.White, 0.2, 0.6)
		sparkles(plate, color, 4, 5, 1.4, 0.7)

		local anchor = mkAnchor(ctx, "Signs", plateTop + Vector3.new(0, 5.5, 0))
		local sign = billboard(anchor, 9, 3.4, 0, 120)
		if side.From == step.Index - 1 then
			addText(sign, "HOLD THE PLATE", "Accent", color, 0, 0.6)
			addText(sign, "so your team can cross", "Body", Theme.Colors.White, 0.62, 0.34)
		else
			addText(sign, "HOLD TO LET THEM CROSS", "Accent", color, 0, 0.6)
			addText(sign, "then everyone moves on", "Body", Theme.Colors.White, 0.62, 0.34)
		end
	end
	return main
end

----------------------------------------------------------------------
-- Signs, arches, flags
----------------------------------------------------------------------
-- DASH hint: a stack of gold chevrons on the run-up platform pointing +Z plus a floating sign.
local function buildDashHint(ctx, prev, step)
	local top = ctx.Origin + prev.Pos
	local frontZ = prev.Size.Z / 2
	local targetX = step.Pos.X
	if step.Kind == "PlateBridge" and step.Hazard and step.Hazard.Span then
		targetX = step.Hazard.Span.Pos.X
	end
	local localX = Util.Clamp(targetX - prev.Pos.X, -(prev.Size.X / 2 - 1.8), prev.Size.X / 2 - 1.8)
	local chevrons = 2
	if prev.Size.Z >= 8 then
		chevrons = 3
	end
	local armLen = 2.6
	local phi = math.pi / 4
	for k = 1, chevrons do
		local tip = top + Vector3.new(localX, 0.12, frontZ - 0.9 - (k - 1) * 1.7)
		for _, sgn in ipairs({ -1, 1 }) do
			-- each arm runs from the tip back and outwards; its length axis is local Z
			local dir = Vector3.new(sgn * math.sin(phi), 0, math.cos(phi))
			local centre = tip - dir * (armLen / 2)
			mk(ctx, "Decor", "DashArrow", Vector3.new(0.6, 0.12, armLen),
				CFrame.new(centre) * CFrame.Angles(0, sgn * phi, 0), DASH_GOLD, Enum.Material.Neon, { Decor = true })
		end
	end
	local anchor = mkAnchor(ctx, "Signs", top + Vector3.new(localX, 5, frontZ - 1.2))
	local gui = billboard(anchor, 8, 3.4, 0, 130)
	addText(gui, "DASH!", "Accent", DASH_GOLD, 0, 0.62)
	if step.Kind == "PlateBridge" then
		addText(gui, "or hold the plate for a bridge", "Body", Theme.Colors.White, 0.64, 0.32)
	else
		addText(gui, "press Q  or tap DASH", "Body", Theme.Colors.White, 0.64, 0.32)
	end
end

-- Wooden-less sign board: dark rounded panel with a themed title and body text.
local function buildBoard(ctx, centre, face, title, body, accent)
	local board = mk(ctx, "Signs", "InfoBoard", Vector3.new(0.4, 5.6, 10.4), CFrame.new(centre), Theme.Colors.Panel,
		Enum.Material.SmoothPlastic, { Decor = true })
	for _, dz in ipairs({ -4.2, 4.2 }) do
		mk(ctx, "Signs", "BoardPost", Vector3.new(2.6, 0.5, 0.5),
			upright(Vector3.new(centre.X, centre.Y - 2.8 - 1.3 + 0.3, centre.Z + dz)), Theme.Colors.CloudShade,
			Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder, Decor = true })
	end
	local gui = surfaceGui(board, face, 50)
	local panel = Theme.Panel({ Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 0.05 })
	panel.Parent = gui
	addText(panel, title, "Title", accent, 0.04, 0.2)
	addText(panel, body, "Body", Theme.Colors.White, 0.27, 0.68)
end

local function buildStart(ctx, step)
	local main = buildCloud(ctx, step, { Name = "StartPlatform", TrimColor = ctx.Diff.Color })
	local top = ctx.Origin + step.Pos
	local color = ctx.Diff.Color

	mk(ctx, "Decor", "StartRing", Vector3.new(0.1, 10, 10), upright(top + Vector3.new(0, 0.07, -4)), color,
		Enum.Material.Neon, { Shape = Enum.PartType.Cylinder, Decor = true, Transparency = 0.6 })

	-- START arch over the way forward
	local archZ = 9
	local half = 9.5
	for _, sgn in ipairs({ -1, 1 }) do
		mk(ctx, "Decor", "ArchPillar", Vector3.new(14, 1.8, 1.8), upright(top + Vector3.new(sgn * half, 7, archZ)),
			Theme.Colors.Cloud, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder, Decor = true })
		mk(ctx, "Decor", "ArchCap", Vector3.new(2.6, 2.6, 2.6), CFrame.new(top + Vector3.new(sgn * half, 14.4, archZ)),
			color, Enum.Material.Neon, { Shape = Enum.PartType.Ball, Decor = true })
	end
	local beam = mk(ctx, "Signs", "StartBeam", Vector3.new(22, 3.4, 2), CFrame.new(top + Vector3.new(0, 15.7, archZ)),
		Theme.Colors.Panel, Enum.Material.SmoothPlastic, { Decor = true })
	mk(ctx, "Decor", "StartGlow", Vector3.new(22, 0.25, 2.1), CFrame.new(top + Vector3.new(0, 13.95, archZ)), color,
		Enum.Material.Neon, { Decor = true })
	for k, c in ipairs(Theme.Colors.Rainbow) do
		mk(ctx, "Decor", "Bunting", Vector3.new(1.2, 1.2, 1.2),
			CFrame.new(top + Vector3.new(-9 + (k - 1) * 3.6, 17.9, archZ)), c, Enum.Material.Neon,
			{ Shape = Enum.PartType.Ball, Decor = true })
	end
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = surfaceGui(beam, face, 50)
		local title = addText(gui, "START", "Title", Theme.Colors.White, 0.04, 0.62)
		Theme.Gradient(title, Theme.Colors.White, color, 90)
		addText(gui, ctx.Diff.DisplayName, "Script", color:Lerp(Theme.Colors.White, 0.35), 0.66, 0.3)
	end

	-- info boards on both sides of the platform
	buildBoard(ctx, top + Vector3.new(-12.6, 5.2, 2), Enum.NormalId.Right, "HOW TO CLIMB",
		"SHIFT  run\nSPACE  jump\nQ  dash  (tap DASH on mobile)\nGrab the floating clouds!", color)
	buildBoard(ctx, top + Vector3.new(12.6, 5.2, 2), Enum.NormalId.Left, "TEAMWORK",
		"Touch a flag to heal everyone and lift up downed friends.\nHold glowing plates to raise bridges.\nNobody gets left behind!",
		Theme.Colors.Good)
	return main
end

local function buildCheckpoint(ctx, step, index, total)
	local main = buildCloud(ctx, step, { Name = "Checkpoint_" .. index, TrimColor = ctx.Diff.Color })
	CollectionService:AddTag(main, Tags.Checkpoint)
	main:SetAttribute("CheckpointIndex", index)
	local top = ctx.Origin + step.Pos
	local sx, sz = step.Size.X, step.Size.Z
	local color = ctx.Diff.Color

	local pad = mk(ctx, "Decor", "CheckpointPad", Vector3.new(sx - 3, 0.1, sz - 3), CFrame.new(top + Vector3.new(0, 0.07, 0)),
		color, Enum.Material.Neon, { Decor = true, Transparency = 0.55 })
	sparkles(pad, color, 6, 5, 1.8, 0.9)

	-- two flag poles at the front corners, banners hanging inwards
	for _, sgn in ipairs({ -1, 1 }) do
		local px = sgn * (sx / 2 - 1.3)
		local pz = sz / 2 - 1.3
		mk(ctx, "Decor", "FlagPole", Vector3.new(9, 0.5, 0.5), upright(top + Vector3.new(px, 4.5, pz)),
			Color3.fromRGB(255, 240, 200), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder, Decor = true })
		local ball = mk(ctx, "Decor", "FlagTop", Vector3.new(1.2, 1.2, 1.2), CFrame.new(top + Vector3.new(px, 9.3, pz)),
			Theme.Colors.Token, Enum.Material.Neon, { Shape = Enum.PartType.Ball, Decor = true })
		local light = Instance.new("PointLight")
		light.Color = Theme.Colors.TokenGlow
		light.Range = 14
		light.Brightness = 1.2
		light.Parent = ball
		local banner = mk(ctx, "Signs", "FlagBanner", Vector3.new(4, 2.6, 0.15),
			CFrame.new(top + Vector3.new(px - sgn * 2.2, 7.6, pz)), color, Enum.Material.SmoothPlastic, { Decor = true })
		for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
			local gui = surfaceGui(banner, face, 60)
			addText(gui, tostring(index), "Display", Theme.Colors.White, 0.05, 0.9)
		end
	end

	local anchor = mkAnchor(ctx, "Signs", top + Vector3.new(0, 11.5, 0))
	local gui = billboard(anchor, 11, 4.2, 0, 170)
	addText(gui, "Checkpoint " .. index .. "/" .. total, "Title", Theme.Colors.White, 0, 0.55)
	local nextStage = ctx.Layout.Stages and ctx.Layout.Stages[index + 1]
	local sub = "Final stretch - the finish is close!"
	if nextStage then
		sub = "Next: " .. nextStage.Name
	end
	addText(gui, sub, "Script", color:Lerp(Theme.Colors.White, 0.4), 0.58, 0.36)
	return main
end

local function buildFinish(ctx, step)
	local gold = Theme.Colors.Rainbow[3]
	local main = buildCloud(ctx, step, { Name = "FinishPlatform", TrimColor = gold })
	CollectionService:AddTag(main, Tags.FinishPad)
	local top = ctx.Origin + step.Pos
	local sz = step.Size.Z

	-- rainbow bullseye
	for k, c in ipairs(Theme.Colors.Rainbow) do
		local d = 26 - (k - 1) * 4
		mk(ctx, "Decor", "GoalRing", Vector3.new(0.1, d, d), upright(top + Vector3.new(0, 0.06 + k * 0.03, 0)), c,
			Enum.Material.Neon, { Shape = Enum.PartType.Cylinder, Decor = true, Transparency = 0.3 })
	end
	local orb = mk(ctx, "Decor", "GoalOrb", Vector3.new(4.5, 4.5, 4.5), CFrame.new(top + Vector3.new(0, 3.4, 0)),
		Theme.Colors.Token, Enum.Material.Neon, { Shape = Enum.PartType.Ball, Decor = true, Transparency = 0.15 })
	local light = Instance.new("PointLight")
	light.Color = Theme.Colors.TokenGlow
	light.Range = 30
	light.Brightness = 1.6
	light.Parent = orb
	local confetti = sparkles(orb, Theme.Colors.White, 18, 16, 2.6, 1.1)
	local keys = {}
	for k, c in ipairs(Theme.Colors.Rainbow) do
		keys[#keys + 1] = ColorSequenceKeypoint.new((k - 1) / (#Theme.Colors.Rainbow - 1), c)
	end
	confetti.Color = ColorSequence.new(keys)
	confetti.SpreadAngle = Vector2.new(40, 40)
	confetti.EmissionDirection = Enum.NormalId.Top

	-- rainbow arch near the arrival edge
	local archZ = -sz / 2 + 6
	local half = 11
	for _, sgn in ipairs({ -1, 1 }) do
		for k, c in ipairs(Theme.Colors.Rainbow) do
			mk(ctx, "Decor", "ArchSegment", Vector3.new(2.4, 2.2, 2.2),
				upright(top + Vector3.new(sgn * half, 1.2 + (k - 1) * 2.4, archZ)), c, Enum.Material.Neon,
				{ Shape = Enum.PartType.Cylinder, Decor = true })
		end
	end
	local beam = mk(ctx, "Signs", "FinishBeam", Vector3.new(26, 3.6, 2), CFrame.new(top + Vector3.new(0, 16, archZ)),
		Theme.Colors.Panel, Enum.Material.SmoothPlastic, { Decor = true })
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = surfaceGui(beam, face, 50)
		local title = addText(gui, "FINISH", "Title", Theme.Colors.White, 0.03, 0.64)
		Theme.Gradient(title, Theme.Colors.Rainbow[3], Theme.Colors.Rainbow[1], 90)
		addText(gui, "you made it - together!", "Script", Theme.Colors.White, 0.68, 0.28)
	end

	local anchor = mkAnchor(ctx, "Signs", top + Vector3.new(0, 10, 0))
	local sign = billboard(anchor, 10, 3.4, 0, 170)
	addText(sign, "GOAL", "Title", gold, 0, 0.62)
	addText(sign, "wait here for your team", "Script", Theme.Colors.White, 0.64, 0.32)
	return main
end

----------------------------------------------------------------------
-- Tokens + ambient scenery
----------------------------------------------------------------------
local function fallbackToken(ctx, pos)
	local p = mk(ctx, "Tokens", "CloudToken", Vector3.new(2, 2, 2), CFrame.new(pos), Theme.Colors.Token,
		Enum.Material.Neon, { Shape = Enum.PartType.Ball, Collide = false })
	p.CastShadow = false
	CollectionService:AddTag(p, Tags.CloudToken)
	p:SetAttribute("Value", Config.Tokens.DefaultValue or 1)
	return p
end

local function buildTokens(ctx)
	local okRequire, TokenService = pcall(function()
		return require(script.Parent.TokenService)
	end)
	if not okRequire or type(TokenService) ~= "table" or not TokenService.MakeTokenPart then
		warn("[CourseBuilder] TokenService unavailable, using plain tokens: " .. tostring(TokenService))
		TokenService = nil
	end
	local value = Config.Tokens.DefaultValue or 1
	for _, step in ipairs(ctx.Layout.Steps) do
		if step.Tokens then
			for _, offset in ipairs(step.Tokens) do
				local pos = ctx.Origin + step.Pos + offset
				local made = false
				if TokenService then
					made = pcall(TokenService.MakeTokenPart, pos, ctx.Groups.Tokens, value)
				end
				if not made then
					fallbackToken(ctx, pos)
				end
			end
		end
	end
end

-- Big soft cloud puffs far below and beside the route so the course floats in a sea of clouds.
local function buildAmbient(ctx)
	if ctx.Parts > PART_BUDGET then
		return
	end
	local steps = ctx.Layout.Steps
	local rng = ctx.Rng
	local count = math.min(26, math.floor(#steps / 2) + 6)
	for k = 1, count do
		local ref = steps[math.min(#steps, math.floor(((k - 0.5) / count) * #steps) + 1)]
		local side = -1
		if k % 2 == 0 then
			side = 1
		end
		local base = ctx.Origin + Vector3.new(side * rng:NextNumber(45, 95), ref.Pos.Y - rng:NextNumber(25, 70),
			ref.Pos.Z + rng:NextNumber(-20, 20))
		local d = rng:NextNumber(24, 46)
		for b = 1, 3 do
			local bd = d
			local off = Vector3.new(0, 0, 0)
			if b > 1 then
				bd = d * rng:NextNumber(0.55, 0.8)
				off = Vector3.new(rng:NextNumber(-d * 0.5, d * 0.5), -rng:NextNumber(0, d * 0.15),
					rng:NextNumber(-d * 0.4, d * 0.4))
			end
			mk(ctx, "Ambient", "FarCloud", Vector3.new(bd, bd, bd), CFrame.new(base + off), Theme.Colors.Cloud,
				Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball, Decor = true, Transparency = 0.3 })
		end
	end
end

----------------------------------------------------------------------
-- Build
----------------------------------------------------------------------
-- Build one step's geometry. Returns the main (tagged) part.
local function buildStep(ctx, step, checkpointTotal)
	local kind = step.Kind
	if kind == "Start" then
		return buildStart(ctx, step)
	elseif kind == "Checkpoint" then
		return buildCheckpoint(ctx, step, step.Stage, checkpointTotal)
	elseif kind == "Finish" then
		return buildFinish(ctx, step)
	elseif kind == "Moving" then
		return buildMoving(ctx, step)
	elseif kind == "Vanishing" then
		return buildVanishing(ctx, step)
	elseif kind == "Bounce" then
		return buildBounce(ctx, step)
	elseif kind == "SpinBarPlatform" then
		return buildSpinBars(ctx, step)
	elseif kind == "StormPlatform" then
		return buildStorm(ctx, step)
	elseif kind == "LightningPlatform" then
		return buildLightning(ctx, step)
	elseif kind == "PlateBridge" then
		return buildPlateBridge(ctx, step)
	end
	if kind == "DashGap" then
		-- gold trim marks the landing of a dash-only gap
		return buildCloud(ctx, step, { Name = "DashLanding_" .. step.Index, TrimColor = DASH_GOLD })
	end
	return buildCloud(ctx, step, { Name = "Cloud_" .. step.Index })
end

-- Last-resort geometry if a decorated builder errors: keep the course traversable.
local function buildFallback(ctx, step)
	local main = buildCloud(ctx, step, { Name = "Cloud_" .. step.Index, Single = true })
	if step.Kind == "Checkpoint" then
		CollectionService:AddTag(main, Tags.Checkpoint)
		main:SetAttribute("CheckpointIndex", step.Stage)
	elseif step.Kind == "Finish" then
		CollectionService:AddTag(main, Tags.FinishPad)
	end
	return main
end

function CourseBuilder.Build(layout, origin, parent)
	origin = origin or Vector3.new(0, 0, 0)
	parent = parent or Workspace
	local diff = Config.GetDifficulty(layout.DifficultyId) or Config.Difficulties[1]

	local folder = Instance.new("Folder")
	folder.Name = "Course_" .. tostring(layout.Seed)
	folder:SetAttribute("DifficultyId", diff.Id)
	local groups = {}
	for _, name in ipairs({ "Platforms", "Hazards", "Decor", "Signs", "Tokens", "Ambient" }) do
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = folder
		groups[name] = f
	end

	local ctx = {
		Layout = layout,
		Origin = origin,
		Diff = diff,
		Folder = folder,
		Groups = groups,
		Welds = {},
		Parts = 0,
		Rng = Random.new((layout.Seed or 0) * 7 + 13),
	}

	local checkpointTotal = 0
	for _ in pairs(layout.Checkpoints) do
		checkpointTotal = checkpointTotal + 1
	end

	local info = {
		Folder = folder,
		Checkpoints = {},
		TotalTokens = layout.TotalTokens,
		TotalSteps = #layout.Steps,
		KillY = origin.Y - 60,
	}

	for i, step in ipairs(layout.Steps) do
		local ok, result = pcall(buildStep, ctx, step, checkpointTotal)
		if not ok then
			warn("[CourseBuilder] step " .. i .. " (" .. tostring(step.Kind) .. ") failed: " .. tostring(result))
			result = buildFallback(ctx, step)
		end
		local top = origin + step.Pos
		if step.Kind == "Start" then
			local p = top + Vector3.new(0, 3.5, -4)
			info.StartCFrame = CFrame.new(p, p + Vector3.new(0, 0, 1))
		elseif step.Kind == "Checkpoint" then
			local p = top + Vector3.new(0, 3.5, 0)
			info.Checkpoints[step.Stage] = {
				Part = result,
				Index = step.Stage,
				SpawnCFrame = CFrame.new(p, p + Vector3.new(0, 0, 1)),
				Stage = step.Stage,
			}
		elseif step.Kind == "Finish" then
			info.Finish = result
		elseif (step.Kind == "DashGap" or step.Kind == "PlateBridge") and i > 1 then
			local okHint, err = pcall(buildDashHint, ctx, layout.Steps[i - 1], step)
			if not okHint then
				warn("[CourseBuilder] dash hint " .. i .. " failed: " .. tostring(err))
			end
		end
	end

	pcall(buildAmbient, ctx)

	-- parent once, then do everything that needs the parts to live in the world
	folder.Parent = parent
	applyWelds(ctx)
	local okTokens, errTokens = pcall(buildTokens, ctx)
	if not okTokens then
		warn("[CourseBuilder] tokens failed: " .. tostring(errTokens))
	end
	return info
end

return CourseBuilder
