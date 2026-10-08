-- smoke_course.lua: scenarios for the generated COURSES (ARCHITECTURE_V2.md sections 7 and 11):
--   layouts   5 difficulties x N seeds: GenerateLayout + ValidateLayout + an INDEPENDENT audit of the rules
--             (the audit re-derives gaps / rises / separation / headroom from the raw numbers instead of trusting
--             the validator), determinism, and printed per-difficulty statistics (steps, tokens, archetype mix,
--             theme mix, hazards)
--   cannon    ballistics of every CloudCannon in those layouts: the launch formula lands on Hazard.Target, inside
--             the landing top with a 2.5 stud margin, flight time / speed / peak limits, nothing in the way
--   courses   CourseBuilder.Build per difficulty: part budget, Start / Checkpoint / Finish, tags + attributes of
--             Config.Tags (incl. Cannon Target and Pendulum Hinge / Axis), golden tokens, palette, determinism
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
local flushErrors = K.flushErrors
local flushWarnings = K.flushWarnings
local tagged = K.tagged

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

local function allowed(weights, id)
	local w = weights and weights[id]
	return type(w) == "number" and w > 0
end

----------------------------------------------------------------------------------------------------
-- geometry: every step is a vertical prism over a rotated rectangle (pure numbers, no Instances)
----------------------------------------------------------------------------------------------------
-- Yaw convention (CourseLayout header): local +Z = (sin yaw, cos yaw), local +X = (cos yaw, -sin yaw).
local function prism(step, ox, oz)
	local yaw = (step.Yaw or 0) * RAD
	local s, c = sin(yaw), cos(yaw)
	local cx, cz = step.Pos.X + (ox or 0), step.Pos.Z + (oz or 0)
	local hx, hz = step.Size.X / 2, step.Size.Z / 2
	local ax, az = hx * c, -hx * s
	local bx, bz = hz * s, hz * c
	return {
		p = { cx - ax - bx, cz - az - bz, cx + ax - bx, cz + az - bz, cx + ax + bx, cz + az + bz, cx - ax + bx, cz - az + bz },
		cx = cx, cz = cz, r = sqrt(hx * hx + hz * hz), hx = hx, hz = hz,
		top = step.Pos.Y, bot = step.Pos.Y - step.Size.Y,
		ux = c, uz = -s, vx = s, vz = c, -- local X / local Z axes
	}
end

-- the positions a (possibly moving) step occupies: 1 for a static one, n samples along the slide for a Moving one
local function forms(step, n)
	local h = step.Hazard
	if step.Kind == "Moving" and type(h) == "table" and typeof(h.EndOffset) == "Vector3" then
		local out = {}
		n = n or 5
		for i = 0, n - 1 do
			local t = i / (n - 1)
			out[#out + 1] = prism(step, h.EndOffset.X * t, h.EndOffset.Z * t)
		end
		return out
	end
	return { prism(step) }
end

local function projRange(p, ax, az)
	local lo, hi = huge, -huge
	for i = 1, 7, 2 do
		local d = p[i] * ax + p[i + 1] * az
		if d < lo then
			lo = d
		end
		if d > hi then
			hi = d
		end
	end
	return lo, hi
end

local function overlap2D(A, B)
	local axes = { A.ux, A.uz, A.vx, A.vz, B.ux, B.uz, B.vx, B.vz }
	for i = 1, 8, 2 do
		local alo, ahi = projRange(A.p, axes[i], axes[i + 1])
		local blo, bhi = projRange(B.p, axes[i], axes[i + 1])
		if ahi < blo or bhi < alo then
			return false
		end
	end
	return true
end

local function pointSeg2(px, pz, ax, az, bx, bz)
	local dx, dz = bx - ax, bz - az
	local len2 = dx * dx + dz * dz
	local t = 0
	if len2 > 0 then
		t = ((px - ax) * dx + (pz - az) * dz) / len2
		if t < 0 then
			t = 0
		elseif t > 1 then
			t = 1
		end
	end
	local qx, qz = ax + t * dx - px, az + t * dz - pz
	return qx * qx + qz * qz
end

-- edge-to-edge distance of two footprints in the XZ plane (0 when they overlap)
local function dist2D(A, B)
	if sqrt((A.cx - B.cx) ^ 2 + (A.cz - B.cz) ^ 2) - A.r - B.r > 60 then
		return 60
	end
	if overlap2D(A, B) then
		return 0
	end
	local best = huge
	local pa, pb = A.p, B.p
	for i = 1, 4 do
		local px, pz = pa[2 * i - 1], pa[2 * i]
		for j = 1, 4 do
			local k = j % 4 + 1
			local d = pointSeg2(px, pz, pb[2 * j - 1], pb[2 * j], pb[2 * k - 1], pb[2 * k])
			if d < best then
				best = d
			end
		end
	end
	for i = 1, 4 do
		local px, pz = pb[2 * i - 1], pb[2 * i]
		for j = 1, 4 do
			local k = j % 4 + 1
			local d = pointSeg2(px, pz, pa[2 * j - 1], pa[2 * j], pa[2 * k - 1], pa[2 * k])
			if d < best then
				best = d
			end
		end
	end
	return sqrt(best)
end

-- gap range over every combination of the two steps' slide samples
local function gapRange(a, b, n)
	local lo, hi = huge, -huge
	for _, fa in ipairs(forms(a, n)) do
		for _, fb in ipairs(forms(b, n)) do
			local d = dist2D(fa, fb)
			lo = min(lo, d)
			hi = max(hi, d)
		end
	end
	return lo, hi
end

-- 3D distance of two prisms
local function dist3D(A, B)
	local d2 = dist2D(A, B)
	local dy = max(0, max(A.bot, B.bot) - min(A.top, B.top))
	return sqrt(d2 * d2 + dy * dy)
end

-- horizontal distance from a point to a footprint (0 inside)
local function pointToPrism(x, z, P)
	local dx, dz = x - P.cx, z - P.cz
	local lx = dx * P.ux + dz * P.uz
	local lz = dx * P.vx + dz * P.vz
	local ex, ez = max(abs(lx) - P.hx, 0), max(abs(lz) - P.hz, 0)
	return sqrt(ex * ex + ez * ez), lx, lz
end

-- horizontal run reach of a full jump onto a step `rise` higher at RunSpeed (no safety factor: the real limit)
local function physicalReach(PH, rise)
	rise = max(rise, 0)
	local disc = PH.JumpPower * PH.JumpPower - 2 * PH.Gravity * rise
	if disc < 0 then
		return 0
	end
	return PH.RunSpeed * (PH.JumpPower + sqrt(disc)) / PH.Gravity
end

----------------------------------------------------------------------------------------------------
-- the audit
----------------------------------------------------------------------------------------------------
local KINDS = {
	Start = true, Platform = true, Checkpoint = true, Moving = true, Vanishing = true, Bounce = true, SpinBarPlatform = true,
	StormPlatform = true, LightningPlatform = true, PlateBridge = true, DashGap = true, Finish = true, Beam = true,
	PendulumPlatform = true, WindPlatform = true, CannonPad = true,
}
local HAZARD_TYPE = {
	Moving = "Moving", Vanishing = "Vanish", Bounce = "Bounce", SpinBarPlatform = "SpinBar", StormPlatform = "Storm",
	LightningPlatform = "Lightning", PendulumPlatform = "Pendulum", WindPlatform = "Wind", CannonPad = "Cannon", PlateBridge = "PlateBridge",
}
local THEME_FEATURE = {
	Bounce = "Bounce", Moving = "Moving", Spin = "SpinBarPlatform", Storm = "StormPlatform", Lightning = "LightningPlatform",
	Vanish = "Vanishing", Cannon = "CannonPad", Wind = "WindPlatform", Pendulum = "PendulumPlatform", Plates = "PlateBridge",
	DashGap = "DashGap", Beams = "Beam",
}
local LANDMARK = {
	Stones = "CloudWindmill", Beams = "CrystalSpires", Bounce = "SkyBalloon", Moving = "RainbowArc", Spin = "GiantRing",
	Storm = "StormTower", Lightning = "LightningRods", Vanish = "LanternCluster", Cannon = "CloudFortress", Wind = "KiteFlock",
	Pendulum = "BellTower", Plates = "RuneObelisk", DashGap = "SkyGate", Gauntlet = "FloatingVolcano",
}
local CATEGORIES = { "structure", "stages", "themes", "links", "sizes", "bounds", "separation", "headroom", "tokens", "hazards", "scenery" }

local function isVec(v)
	return typeof(v) == "Vector3"
end
local function isNum(v)
	return type(v) == "number" and v == v and v > -1e9 and v < 1e9
end

-- Returns cats = { [category] = first problem text } (empty when the layout satisfies every rule).
local function audit(layout, diff, Config, cannons)
	local PH = Config.Physics
	local cats = {}
	local function bad(cat, msg)
		if not cats[cat] then
			cats[cat] = msg
		end
	end
	if type(layout) ~= "table" or type(layout.Steps) ~= "table" or #layout.Steps < 3 then
		bad("structure", "no Steps")
		return cats
	end
	local steps = layout.Steps
	local n = #steps
	if layout.DifficultyId ~= diff.Id then
		bad("structure", "DifficultyId " .. tostring(layout.DifficultyId))
	end

	-- structure ------------------------------------------------------------------------------------
	for i, s in ipairs(steps) do
		if type(s) ~= "table" or not isVec(s.Pos) or not isVec(s.Size) or type(s.Kind) ~= "string" or not isNum(s.Yaw) then
			bad("structure", "step " .. i .. " is malformed (Pos / Size / Kind / Yaw)")
			return cats
		end
		if s.Index ~= i then
			bad("structure", "step " .. i .. " has Index " .. tostring(s.Index))
		end
		if not KINDS[s.Kind] then
			bad("structure", "step " .. i .. " has unknown Kind " .. s.Kind)
		end
		if s.Yaw < 0 or s.Yaw >= 360 then
			bad("structure", "step " .. i .. " Yaw " .. fmt(s.Yaw) .. " outside [0, 360)")
		end
		if HAZARD_TYPE[s.Kind] then
			if type(s.Hazard) ~= "table" or s.Hazard.Type ~= HAZARD_TYPE[s.Kind] then
				bad("structure", "step " .. i .. " (" .. s.Kind .. ") needs a '" .. HAZARD_TYPE[s.Kind] .. "' Hazard")
			end
		elseif s.Hazard ~= nil then
			bad("structure", "step " .. i .. " (" .. s.Kind .. ") must not carry a Hazard")
		end
	end
	local first, last = steps[1], steps[n]
	if first.Kind ~= "Start" or first.Pos.Magnitude > 1e-6 then
		bad("structure", "step 1 must be the Start at the origin")
	end
	if last.Kind ~= "Finish" then
		bad("structure", "the last step must be the Finish")
	end
	for i = 2, n - 1 do
		if steps[i].Kind == "Start" or steps[i].Kind == "Finish" then
			bad("structure", "step " .. i .. " is a second " .. steps[i].Kind)
		end
	end
	local bnd = layout.Bounds
	if type(bnd) ~= "table" or not isVec(bnd.Min) or not isVec(bnd.Max) then
		bad("structure", "Bounds missing")
	else
		for i, s in ipairs(steps) do
			for _, f in ipairs(forms(s, 3)) do
				for k = 1, 7, 2 do
					local x, z = f.p[k], f.p[k + 1]
					if x < bnd.Min.X - 0.01 or x > bnd.Max.X + 0.01 or z < bnd.Min.Z - 0.01 or z > bnd.Max.Z + 0.01 or f.bot < bnd.Min.Y - 0.01 or f.top > bnd.Max.Y + 0.01 then
						bad("structure", "step " .. i .. " lies outside Bounds")
					end
				end
			end
		end
	end

	-- stages + checkpoints ---------------------------------------------------------------------------
	local cps = layout.Checkpoints
	if type(cps) ~= "table" then
		bad("stages", "no Checkpoints table")
		cps = {}
	end
	local cpCount, perStage = 0, {}
	for i, s in ipairs(steps) do
		if s.Kind == "Checkpoint" then
			cpCount = cpCount + 1
		elseif s.Kind ~= "Start" and s.Kind ~= "Finish" then
			perStage[s.Stage] = (perStage[s.Stage] or 0) + 1
		end
		if i > 1 and isNum(s.Stage) and isNum(steps[i - 1].Stage) and s.Stage < steps[i - 1].Stage then
			bad("stages", "step " .. i .. " goes back to an earlier stage")
		end
	end
	if cpCount ~= diff.Stages then
		bad("stages", "expected " .. diff.Stages .. " checkpoints, found " .. cpCount)
	end
	local lastCp = 0
	for k = 1, diff.Stages do
		local s = steps[cps[k] or 0]
		if not s or s.Kind ~= "Checkpoint" or s.Stage ~= k then
			bad("stages", "Checkpoints[" .. k .. "] does not name the checkpoint of stage " .. k)
		else
			if cps[k] <= lastCp then
				bad("stages", "Checkpoints are out of order")
			end
			lastCp = cps[k]
		end
		local c = perStage[k] or 0
		if c < diff.StepsPerStage[1] or c > diff.StepsPerStage[2] then
			bad("stages", "stage " .. k .. " has " .. c .. " steps (expected " .. diff.StepsPerStage[1] .. "-" .. diff.StepsPerStage[2] .. ")")
		end
	end
	if lastCp ~= n - 1 then
		bad("stages", "the last checkpoint must sit directly before the Finish")
	end
	if last.Stage ~= diff.Stages then
		bad("stages", "the Finish must belong to the last stage")
	end
	if type(layout.Stages) ~= "table" or #layout.Stages ~= diff.Stages then
		bad("stages", "Layout.Stages must describe each of the " .. diff.Stages .. " stages")
	end

	-- archetype + themes -----------------------------------------------------------------------------
	if not allowed(diff.Archetypes, layout.Archetype) then
		bad("themes", "archetype " .. tostring(layout.Archetype) .. " is not offered by " .. diff.Id)
	end
	if (layout.Archetype == "Spiral") ~= (layout.Centre ~= nil) then
		bad("themes", "Centre must exist exactly for Spiral courses")
	end
	local themes = layout.Themes
	if type(themes) ~= "table" or #themes ~= diff.Stages then
		bad("themes", "Themes must list one theme per stage")
		themes = {}
	end
	local kinds = 0
	for _ in pairs(diff.Themes) do
		kinds = kinds + 1
	end
	for k, theme in ipairs(themes) do
		if not allowed(diff.Themes, theme) then
			bad("themes", "stage " .. k .. " theme " .. tostring(theme) .. " is not offered by " .. diff.Id)
		end
		if k > 1 and kinds > 1 and theme == themes[k - 1] then
			bad("themes", "stages " .. (k - 1) .. " and " .. k .. " repeat the theme " .. tostring(theme))
		end
	end
	if themes[1] then
		local safe = allowed(diff.Themes, "Stones") or allowed(diff.Themes, "Bounce")
		local harsh = { Storm = true, Lightning = true, Gauntlet = true, Pendulum = true, Wind = true, Cannon = true, DashGap = true }
		if safe and themes[1] ~= "Stones" and themes[1] ~= "Bounce" then
			bad("themes", "stage 1 must open with Stones or Bounce, got " .. themes[1])
		elseif not safe and harsh[themes[1]] then
			bad("themes", "stage 1 opens with the harsh theme " .. themes[1])
		end
	end
	local have = {}
	for _, s in ipairs(steps) do
		if s.Kind ~= "Start" and s.Kind ~= "Finish" and s.Kind ~= "Checkpoint" then
			have[s.Stage] = have[s.Stage] or {}
			have[s.Stage][s.Kind] = (have[s.Stage][s.Kind] or 0) + 1
		end
	end
	for k, theme in ipairs(themes) do
		local h = have[k] or {}
		local feature = THEME_FEATURE[theme]
		if feature and (h[feature] or 0) < 1 then
			bad("themes", "stage " .. k .. " (" .. theme .. ") has no " .. feature .. " step")
		end
		if theme == "Plates" and h.PlateBridge ~= 1 then
			bad("themes", "stage " .. k .. " (Plates) needs exactly one PlateBridge, has " .. tostring(h.PlateBridge))
		elseif theme ~= "Plates" and (h.PlateBridge or 0) > 0 then
			bad("themes", "stage " .. k .. " (" .. theme .. ") contains a PlateBridge")
		elseif theme == "Cannon" and (h.CannonPad or 0) < 1 then
			bad("themes", "stage " .. k .. " (Cannon) has no CannonPad")
		elseif theme == "Gauntlet" then
			local distinct = 0
			for kind in pairs(h) do
				if kind ~= "Platform" then
					distinct = distinct + 1
				end
			end
			if distinct < 3 then
				bad("themes", "stage " .. k .. " (Gauntlet) mixes only " .. distinct .. " hazard kinds")
			end
		elseif theme == "Beams" and (h.Beam or 0) * 2 < (perStage[k] or 0) then
			bad("themes", "stage " .. k .. " (Beams) is mostly not beams")
		end
		if theme ~= "Cannon" and theme ~= "Gauntlet" and (h.CannonPad or 0) > 0 then
			bad("themes", "stage " .. k .. " (" .. theme .. ") contains a CannonPad")
		end
	end
	if diff.Id == "Easy" and (have[1] and false) then
		bad("themes", "unreachable")
	end

	-- sizes ----------------------------------------------------------------------------------------------
	local plain = { Platform = true, Moving = true, Vanishing = true, Bounce = true, SpinBarPlatform = true, StormPlatform = true, LightningPlatform = true, DashGap = true }
	for i, s in ipairs(steps) do
		local x, y, z = s.Size.X, s.Size.Y, s.Size.Z
		local kind = s.Kind
		local okSize = true
		if kind == "Start" then
			okSize = x >= 24 and z >= 24
		elseif kind == "Checkpoint" then
			okSize = x >= 14 and z >= 14
		elseif kind == "Finish" then
			okSize = x >= 28 and z >= 28
		elseif kind == "Beam" then
			okSize = x >= 2.5 - 0.01 and x <= 4 + 0.01 and z >= 14 - 0.01 and z <= 30 + 0.01
		elseif kind == "PendulumPlatform" or kind == "WindPlatform" then
			okSize = x >= 9 - 0.01 and z >= 9 - 0.01
		elseif kind == "CannonPad" or kind == "PlateBridge" then
			okSize = x >= 7 - 0.01 and z >= 7 - 0.01
		elseif plain[kind] then
			local lo, hi = diff.PlatformMin, diff.PlatformMax
			okSize = x >= lo - 0.01 and x <= hi + 0.01 and z >= lo - 0.01 and z <= hi + 0.01
			if kind == "Platform" and s.Link == "Cannon" then
				okSize = x >= 7 - 0.01 and z >= 7 - 0.01
			end
		end
		if not okSize then
			bad("sizes", "step " .. i .. " " .. kind .. " is " .. fmt(x) .. "x" .. fmt(z) .. " (PlatformMin/Max " .. diff.PlatformMin .. "/" .. diff.PlatformMax .. ")")
		end
		if y < 1 - 0.01 or y > 6 then
			bad("sizes", "step " .. i .. " thickness " .. fmt(y, 2))
		end
	end

	-- bounds: radius + lowest ------------------------------------------------------------------------------
	for i, s in ipairs(steps) do
		if s.Pos.Y < -10 - 0.01 then
			bad("bounds", "step " .. i .. " is " .. fmt(-s.Pos.Y) .. " studs below the origin (limit 10)")
		end
		for _, f in ipairs(forms(s, 3)) do
			for k = 1, 7, 2 do
				local r = sqrt(f.p[k] ^ 2 + f.p[k + 1] ^ 2)
				if r > Config.Course.MaxRadius + 0.01 then
					bad("bounds", "step " .. i .. " reaches " .. fmt(r) .. " studs from the origin (Config.Course.MaxRadius " .. Config.Course.MaxRadius .. ")")
				end
			end
		end
	end

	-- links -----------------------------------------------------------------------------------------------
	local riseCap = min(diff.RiseMax, PH.JumpHeight * 0.7)
	local dashLo, dashHi = diff.DashGapMin or 15, diff.DashGapMax or 19
	local dashSteps = 0
	for i = 2, n do
		local a, b = steps[i - 1], steps[i]
		local rise = b.Pos.Y - a.Pos.Y
		local lo, hi = gapRange(a, b, 9)
		if rise < -4 - 1e-6 then
			bad("links", "step " .. i .. " drops " .. fmt(-rise) .. " studs (limit 4)")
		end
		if a.Kind == "Moving" and b.Kind == "Moving" then
			bad("links", "two Moving steps are adjacent at " .. i)
		end
		if not isNum(b.Gap) or abs(b.Gap - hi) > 0.1 then
			bad("links", "step " .. i .. " Gap field " .. tostring(b.Gap) .. " differs from the geometry " .. fmt(hi, 2))
		end
		if a.Kind == "CannonPad" then
			if b.Link ~= "Cannon" or b.Kind ~= "Platform" then
				bad("links", "the step after a CannonPad (" .. i .. ") must be a plain Platform with Link 'Cannon'")
			end
			if lo < 20 then
				bad("links", "cannon landing " .. i .. " is only " .. fmt(lo) .. " studs from its pad (would not need the cannon)")
			end
		elseif b.Link == "Cannon" then
			bad("links", "step " .. i .. " has Link 'Cannon' without a CannonPad before it")
		elseif b.Kind == "DashGap" or b.Kind == "PlateBridge" then
			dashSteps = dashSteps + 1
			if b.Link ~= "Dash" then
				bad("links", "step " .. i .. " (" .. b.Kind .. ") needs Link 'Dash'")
			end
			if lo < dashLo - 0.01 or hi > dashHi + 0.01 then
				bad("links", "dash gap " .. fmt(lo, 2) .. ".." .. fmt(hi, 2) .. " at step " .. i .. " outside [" .. dashLo .. ", " .. dashHi .. "]")
			end
			if hi > 0.85 * PH.MaxDashGap + 0.01 then
				bad("links", "dash gap " .. fmt(hi, 2) .. " exceeds 0.85 * MaxDashGap (" .. fmt(0.85 * PH.MaxDashGap, 2) .. ")")
			end
			if lo <= 0.75 * PH.MaxRunGap then
				bad("links", "dash gap " .. fmt(lo, 2) .. " does not need a dash (<= 0.75 * MaxRunGap)")
			end
			if rise < -1e-6 or rise > 2 + 1e-6 then
				bad("links", "dash gap rise " .. fmt(rise, 2) .. " outside 0..2")
			end
			if not (a.Kind == "Platform" or a.Kind == "Checkpoint" or a.Kind == "Start") then
				bad("links", "dash gap " .. i .. " has a " .. a.Kind .. " as run-up (needs a static platform)")
			end
			if not b.DashHint or b.DashHint.From ~= i - 1 or not isVec(b.DashHint.Pos) or not isVec(b.DashHint.Dir) then
				bad("links", "step " .. i .. " has no DashHint")
			end
		else
			if lo < diff.GapMin - 0.01 or hi > diff.GapMax + 0.01 then
				bad("links", "gap " .. fmt(lo, 2) .. ".." .. fmt(hi, 2) .. " at step " .. i .. " outside [" .. diff.GapMin .. ", " .. diff.GapMax .. "]")
			end
			if rise <= riseCap + 1e-6 then
				if b.Link ~= "Walk" then
					bad("links", "step " .. i .. " is an ordinary hop and needs Link 'Walk', has " .. tostring(b.Link))
				end
				if hi > physicalReach(PH, rise) then
					bad("links", "gap " .. fmt(hi, 2) .. " at step " .. i .. " exceeds the physical run reach " .. fmt(physicalReach(PH, rise), 2) .. " for rise " .. fmt(rise, 2))
				end
			else
				if a.Kind ~= "Bounce" or b.Link ~= "Bounce" then
					bad("links", "rise " .. fmt(rise, 2) .. " at step " .. i .. " exceeds the jump cap " .. fmt(riseCap, 2) .. " without a bounce pad")
				elseif rise > 9 + 1e-6 then
					bad("links", "bounce rise " .. fmt(rise, 2) .. " exceeds 9")
				end
			end
			if b.Link == "Dash" then
				bad("links", "step " .. i .. " has Link 'Dash' but is not a dash gap")
			end
		end
	end
	if diff.DashGapChance == 0 and not allowed(diff.Themes, "DashGap") and not allowed(diff.Themes, "Plates") and dashSteps > 0 then
		bad("links", diff.Id .. " has dash-only gaps although it offers none")
	end

	-- separation + headroom ----------------------------------------------------------------------------------
	local fm = {}
	for i, s in ipairs(steps) do
		fm[i] = forms(s, 3)
	end
	local clearance = Config.Course.Clearance
	for i = 1, n do
		for j = i + 1, n do
			local fi, fj = fm[i], fm[j]
			local best3, bestXZ = huge, huge
			local sep, headBad
			for _, A in ipairs(fi) do
				for _, B in ipairs(fj) do
					if sqrt((A.cx - B.cx) ^ 2 + (A.cz - B.cz) ^ 2) - A.r - B.r <= 6 then
						local d2 = dist2D(A, B)
						bestXZ = min(bestXZ, d2)
						local dy = max(0, max(A.bot, B.bot) - min(A.top, B.top))
						local d3 = sqrt(d2 * d2 + dy * dy)
						best3 = min(best3, d3)
						if d2 <= 1.0 then
							local lower, upper = A, B
							if B.top < A.top then
								lower, upper = B, A
							end
							if upper.bot - lower.top < clearance - 0.01 and (j - i) > 0 then
								headBad = upper.bot - lower.top
							end
						end
					end
				end
			end
			if j - i >= 2 and best3 < 2 - 0.01 then
				bad("separation", "steps " .. i .. " and " .. j .. " are only " .. fmt(best3, 2) .. " studs apart (limit 2)")
			end
			if headBad then
				bad("headroom", "step " .. max(i, j) .. " hangs " .. fmt(headBad, 1) .. " studs above step " .. min(i, j) .. " (Config.Course.Clearance " .. clearance .. ")")
			end
		end
	end

	-- tokens ------------------------------------------------------------------------------------------------------
	local counted, valueSum, golden = 0, 0, 0
	local regularSteps, goldenIn = {}, {}
	for i, s in ipairs(steps) do
		local hasRegular = false
		for _, tk in ipairs(s.Tokens or {}) do
			if type(tk) ~= "table" or not isVec(tk.Pos) or (tk.Value ~= 1 and tk.Value ~= Config.Tokens.GoldenValue) or (tk.Golden == true) ~= (tk.Value == Config.Tokens.GoldenValue) then
				bad("tokens", "step " .. i .. " has a malformed token")
			else
				counted = counted + 1
				valueSum = valueSum + tk.Value
				local h = tk.Pos.Y - s.Pos.Y
				if h < 2.9 or h > 4.6 then
					bad("tokens", "a token at step " .. i .. " floats " .. fmt(h, 2) .. " studs above the top (3-4.5)")
				end
				if tk.Golden then
					golden = golden + 1
					goldenIn[s.Stage] = (goldenIn[s.Stage] or 0) + 1
				else
					hasRegular = true
				end
				for j = max(1, i - 6), min(n, i + 6) do
					local P = fm[j][1]
					local d = pointToPrism(tk.Pos.X, tk.Pos.Z, P)
					if d <= 0.01 and tk.Pos.Y > P.bot and tk.Pos.Y < P.top then
						bad("tokens", "a token of step " .. i .. " is inside step " .. j)
					end
				end
			end
		end
		if hasRegular then
			regularSteps[s.Stage] = (regularSteps[s.Stage] or 0) + 1
		end
	end
	if valueSum ~= layout.TotalTokens then
		bad("tokens", "TotalTokens " .. tostring(layout.TotalTokens) .. " is not the sum of the token values " .. valueSum)
	end
	if counted ~= layout.TokenCount or golden ~= layout.GoldenCount then
		bad("tokens", "TokenCount / GoldenCount do not match the placed tokens")
	end
	for k = 1, diff.Stages do
		if (regularSteps[k] or 0) < diff.TokensPerStage then
			bad("tokens", "stage " .. k .. " has regular tokens on " .. (regularSteps[k] or 0) .. " steps (TokensPerStage " .. diff.TokensPerStage .. ")")
		end
		local g = goldenIn[k] or 0
		if g < 1 or g > 2 then
			bad("tokens", "stage " .. k .. " has " .. g .. " golden tokens (1-2)")
		end
	end

	-- hazard parameters ----------------------------------------------------------------------------------------
	for i, s in ipairs(steps) do
		local h = s.Hazard
		if type(h) == "table" then
			local t = h.Type
			if t == "Moving" then
				local len = isVec(h.EndOffset) and sqrt(h.EndOffset.X ^ 2 + h.EndOffset.Z ^ 2) or -1
				if not isVec(h.EndOffset) or abs(h.EndOffset.Y) > 1e-6 or len < 3.5 - 0.01 or len > 10 + 0.01 or not isNum(h.Period) or h.Period <= 0 or len / h.Period > 4.2 + 0.01 then
					bad("hazards", "step " .. i .. " Moving: slide " .. fmt(len, 2) .. " / period " .. tostring(h.Period) .. " (3.5-10 studs, <= 4.2 studs/s)")
				end
			elseif t == "Vanish" then
				if not isNum(h.VanishDelay) or h.VanishDelay <= 0 or not isNum(h.ReturnDelay) or h.ReturnDelay <= 0 then
					bad("hazards", "step " .. i .. " Vanish: VanishDelay / ReturnDelay")
				end
			elseif t == "Bounce" then
				if not isNum(h.Power) or h.Power <= 0 or not isNum(h.LaunchSpeed) or h.LaunchSpeed < 0 or not isVec(h.Pos) or not isNum(h.Apex) or abs(h.Apex - h.Power ^ 2 / (2 * PH.Gravity)) > 0.5 then
					bad("hazards", "step " .. i .. " Bounce: Power / LaunchSpeed / Apex")
				end
			elseif t == "SpinBar" then
				if not isNum(h.Speed) or h.Speed == 0 or not isNum(h.Damage) or h.Damage <= 0 or (h.Count ~= 1 and h.Count ~= 2) or not isNum(h.Length) or h.Length <= 0 then
					bad("hazards", "step " .. i .. " SpinBar: Speed / Damage / Count / Length")
				end
			elseif t == "Storm" then
				if not isNum(h.DPS) or h.DPS <= 0 or type(h.Box) ~= "table" or not isVec(h.Box.Pos) or not isVec(h.Box.Size) then
					bad("hazards", "step " .. i .. " Storm: DPS / Box")
				end
			elseif t == "Lightning" then
				local zonesOk = type(h.Zones) == "table" and #h.Zones >= 1 and #h.Zones <= 3
				if not zonesOk or not isNum(h.Damage) or h.Damage <= 0 or not isNum(h.Interval) or h.Interval <= 0 or not isNum(h.Warning) or h.Warning <= 0 or h.Warning >= h.Interval then
					bad("hazards", "step " .. i .. " Lightning: Zones (1-3) / Damage / Interval / Warning")
				else
					-- always a safe spot: some point of the platform is outside every strike disc
					local P = fm[i][1]
					local safe = false
					local gx = -P.hx + 0.8
					while gx <= P.hx - 0.8 + 1e-6 and not safe do
						local gz = -P.hz + 0.8
						while gz <= P.hz - 0.8 + 1e-6 and not safe do
							local wx = P.cx + gx * P.ux + gz * P.vx
							local wz = P.cz + gx * P.uz + gz * P.vz
							local clear = true
							for _, z in ipairs(h.Zones) do
								if sqrt((wx - z.Pos.X) ^ 2 + (wz - z.Pos.Z) ^ 2) < z.Radius + 1.2 then
									clear = false
								end
							end
							safe = clear
							gz = gz + 0.5
						end
						gx = gx + 0.5
					end
					if not safe then
						bad("hazards", "step " .. i .. " Lightning leaves no safe spot on its platform")
					end
				end
			elseif t == "Pendulum" then
				local axisOk = isVec(h.Axis) and abs(h.Axis.Y) < 1e-6 and abs(h.Axis.Magnitude - 1) < 1e-3
				if not isVec(h.Hinge) or not axisOk or not isNum(h.Arc) or h.Arc <= 0 or h.Arc >= 90 or not isNum(h.Period) or h.Period <= 0 or not isNum(h.Damage) or h.Damage <= 0 or not isNum(h.Length) or h.Length <= 0 then
					bad("hazards", "step " .. i .. " Pendulum: Hinge / Axis (horizontal unit) / Arc / Period / Damage / Length")
				else
					local P = fm[i][1]
					if h.Hinge.Y - h.Length < s.Pos.Y + 0.5 then
						bad("hazards", "step " .. i .. " Pendulum: the beam hangs into the platform at rest")
					end
					local d = pointToPrism(h.Hinge.X, h.Hinge.Z, P)
					if d > 0.01 then
						bad("hazards", "step " .. i .. " Pendulum: the hinge is outside the platform")
					end
				end
			elseif t == "Wind" then
				local dirOk = isVec(h.Direction) and abs(h.Direction.Y) < 1e-6 and abs(h.Direction.Magnitude - 1) < 1e-3
				if not dirOk or not isNum(h.Force) or h.Force <= 0 or h.Force > 26 + 1e-6 or not isNum(h.Interval) or h.Interval <= 0 or not isNum(h.Warning) or h.Warning <= 0 or type(h.Zone) ~= "table" or not isVec(h.Zone.Pos) or not isVec(h.Zone.Size) then
					bad("hazards", "step " .. i .. " Wind: Direction (horizontal unit) / Force (<= 26) / Interval / Warning / Zone")
				else
					-- calm lee: >= 4.9 studs of platform downwind of the gust volume
					local P = fm[i][1]
					local zoneStep = { Pos = h.Zone.Pos + Vector3.new(0, 0, 0), Size = Vector3.new(h.Zone.Size.X, 1, h.Zone.Size.Z), Yaw = h.Zone.Yaw or s.Yaw }
					local Z = prism(zoneStep)
					local _, platHi = projRange(P.p, h.Direction.X, h.Direction.Z)
					local _, zoneHi = projRange(Z.p, h.Direction.X, h.Direction.Z)
					if platHi - zoneHi < 4.9 - 0.05 then
						bad("hazards", "step " .. i .. " Wind: only " .. fmt(platHi - zoneHi, 2) .. " studs of calm lee (needs 4.9)")
					end
				end
			elseif t == "PlateBridge" then
				local sides = h.Sides
				if type(h.Span) ~= "table" or type(sides) ~= "table" or #sides ~= 2 or not isNum(h.BridgeNumber) then
					bad("hazards", "step " .. i .. " PlateBridge: Span / Sides / BridgeNumber")
				else
					for k, side in ipairs(sides) do
						if type(side.Plate) ~= "table" or not isVec(side.Plate.Pos) or not isVec(side.Pos) then
							bad("hazards", "step " .. i .. " PlateBridge: side " .. k .. " has no Plate")
						end
					end
				end
			elseif t == "Cannon" then
				if not isVec(h.Target) or not isNum(h.FlightTime) or not isVec(h.Pos) or not isNum(h.PadRadius) then
					bad("hazards", "step " .. i .. " Cannon: Target / FlightTime / Pos / PadRadius")
				elseif cannons then
					local land = steps[h.LandingIndex or (i + 1)]
					if not cats._prisms then
						local list = {}
						for j, st in ipairs(steps) do
							list[j] = forms(st, 3)
						end
						cats._prisms = list
					end
					cannons[#cannons + 1] = {
						diff = diff.Id, seed = layout.Seed, index = i,
						padTop = s.Pos.Y, pos = { h.Pos.X, h.Pos.Y, h.Pos.Z }, padRadius = h.PadRadius,
						target = { h.Target.X, h.Target.Y, h.Target.Z }, flight = h.FlightTime, speed = h.Speed, apex = h.Apex,
						landing = land and { top = land.Pos.Y, prism = prism(land), kind = land.Kind } or nil,
						landingIndex = h.LandingIndex, landingGap = land and land.Gap, link = land and land.Link,
						prisms = cats._prisms,
					}
				end
			end
		end
	end

	-- scenery -------------------------------------------------------------------------------------------------------
	if type(layout.Scenery) ~= "table" then
		bad("scenery", "no Scenery list")
	else
		local landmarks, nLandmark = {}, 0
		for si, item in ipairs(layout.Scenery) do
			if type(item) ~= "table" or type(item.Type) ~= "string" or not isVec(item.Pos) or not isNum(item.Radius) or item.Radius <= 0 or not isNum(item.Height) or item.Height <= 0 then
				bad("scenery", "scenery item " .. si .. " is malformed (Type / Pos / Radius / Height)")
			else
				if item.Stage and item.Stage > 0 then
					landmarks[item.Stage] = item.Type
					nLandmark = nLandmark + 1
				end
				if item.Type ~= "Puff" then
					for j = 1, n do
						local P = fm[j][1]
						local d = pointToPrism(item.Pos.X, item.Pos.Z, P)
						local overlapV = (item.Pos.Y - 4) < (steps[j].Pos.Y + (steps[j].Headroom or 8)) and (item.Pos.Y + item.Height + 4) > P.bot
						if d < item.Radius + 4 - 0.5 and overlapV then
							bad("scenery", item.Type .. " (stage " .. tostring(item.Stage) .. ") crowds step " .. j .. " (" .. fmt(d) .. " < " .. fmt(item.Radius + 4) .. ")")
						end
					end
				end
			end
		end
		for k, theme in ipairs(themes) do
			local want = LANDMARK[theme]
			if landmarks[k] ~= want then
				bad("scenery", "stage " .. k .. " (" .. theme .. ") should have the landmark " .. tostring(want) .. ", has " .. tostring(landmarks[k]))
			end
		end
	end
	cats._prisms = nil
	return cats
end

----------------------------------------------------------------------------------------------------
-- scenario: layouts
----------------------------------------------------------------------------------------------------
local function signature(layout)
	local parts = { layout.Archetype or "?", table.concat(layout.Themes or {}, ","), tostring(#layout.Steps) }
	local lastStep = layout.Steps[#layout.Steps]
	if lastStep then
		parts[#parts + 1] = string.format("%.1f,%.1f,%.1f", lastStep.Pos.X, lastStep.Pos.Y, lastStep.Pos.Z)
	end
	return table.concat(parts, "|")
end

local function fullSignature(layout)
	local out = { signature(layout) }
	for _, s in ipairs(layout.Steps) do
		out[#out + 1] = string.format("%s:%.2f,%.2f,%.2f:%.1f", s.Kind, s.Pos.X, s.Pos.Y, s.Pos.Z, s.Yaw)
	end
	return table.concat(out, ";")
end

S.layouts = guarded("layouts", function()
	local Config = config()
	local CB, CL = mod("CourseBuilder"), mod("CourseLayout")
	if not (CB and CL) then
		T.fail("layouts needs CourseBuilder and CourseLayout")
		return
	end
	T.check(CB.GenerateLayout == CL.GenerateLayout or CB.GenerateLayout ~= nil, "CourseBuilder.GenerateLayout is available (re-exported from CourseLayout)")
	T.check(CB.ValidateLayout ~= nil and type(CB.Build) == "function", "CourseBuilder.ValidateLayout / Build are available")
	local seeds = ARGS.seeds or 40
	W.layoutSeeds = seeds
	W.layoutCache = {}
	W.cannons = {}
	W.layoutStats = {}
	local catTally = {}
	for _, cat in ipairs(CATEGORIES) do
		catTally[cat] = T.tally("independent audit [" .. cat .. "]: every layout of all 5 difficulties satisfies the " .. cat .. " rules")
	end
	local prevMean
	local means = {}
	for di, diff in ipairs(Config.Difficulties) do
		local t0 = Mock.RealClock()
		local genTally = T.tally(diff.Id .. ": GenerateLayout('" .. diff.Id .. "', seed) never raises (" .. seeds .. " seeds)")
		local validTally = T.tally(diff.Id .. ": ValidateLayout accepts every generated layout (" .. seeds .. " seeds)")
		local auditTally = T.tally(diff.Id .. ": the independent audit finds nothing to complain about (" .. seeds .. " seeds)")
		local detTally = T.tally(diff.Id .. ": the same (difficulty, seed) gives an identical layout")
		local api = T.tally(diff.Id .. ": layout header fields (DifficultyId, Seed, Archetype, Themes, Steps, Checkpoints, TotalTokens, Bounds)")
		local stats = {
			n = 0, steps = 0, minSteps = huge, maxSteps = 0, tokens = 0, golden = 0, regular = 0, total = 0, height = 0, radius = 0, path = 0,
			hazards = 0, cannons = 0, bridges = 0, dash = 0, beams = 0, movers = 0, scenery = 0, maxGap = 0,
			archetypes = {}, themes = {}, themeTotal = 0, kinds = {}, hazardTypes = {}, signatures = {},
			distinct = 0, attempts = 0, retried = 0,
		}
		W.layoutCache[diff.Id] = {}
		local invalid = {}
		for seed = 1, seeds do
			local ok, layout = pcall(CB.GenerateLayout, diff.Id, seed)
			genTally:case(ok and type(layout) == "table", "seed " .. seed .. ": " .. tostring(layout))
			if ok and type(layout) == "table" then
				stats.n = stats.n + 1
				api:case(layout.DifficultyId == diff.Id and layout.Seed == seed and type(layout.Archetype) == "string" and type(layout.Themes) == "table"
					and type(layout.Steps) == "table" and type(layout.Checkpoints) == "table" and type(layout.TotalTokens) == "number"
					and type(layout.Bounds) == "table", "seed " .. seed)
				local vok, valid, problems = pcall(CB.ValidateLayout, layout)
				validTally:case(vok and valid == true, "seed " .. seed .. ": " .. tostring(vok and problems and problems[1] or valid))
				if vok and valid ~= true and #invalid < 3 then
					invalid[#invalid + 1] = seed
				end
				local cats = audit(layout, diff, Config, W.cannons)
				local firstCat, firstMsg = next(cats)
				if firstCat then
					local msgs = {}
					for _, cat in ipairs(CATEGORIES) do
						if cats[cat] then
							msgs[#msgs + 1] = cat .. ": " .. cats[cat]
							break
						end
					end
					auditTally:case(false, "seed " .. seed .. " " .. msgs[1])
				else
					auditTally:case(true)
				end
				for _, cat in ipairs(CATEGORIES) do
					catTally[cat]:case(cats[cat] == nil, diff.Id .. " seed " .. seed .. ": " .. tostring(cats[cat]))
				end
				-- determinism on the first seeds (a full compare is expensive)
				if seed <= 12 then
					local again = CB.GenerateLayout(diff.Id, seed)
					detTally:case(fullSignature(layout) == fullSignature(again), "seed " .. seed .. " changed between two calls")
				end
				-- statistics
				local st = CL.Stats(layout)
				stats.steps = stats.steps + st.Steps
				stats.minSteps = min(stats.minSteps, st.Steps)
				stats.maxSteps = max(stats.maxSteps, st.Steps)
				stats.tokens = stats.tokens + st.Tokens
				stats.golden = stats.golden + st.Golden
				stats.total = stats.total + st.TotalTokens
				stats.height = stats.height + st.Height
				stats.radius = stats.radius + st.Radius
				stats.path = stats.path + st.PathLength
				stats.hazards = stats.hazards + st.Hazards
				stats.cannons = stats.cannons + st.Cannons
				stats.bridges = stats.bridges + st.Bridges
				stats.dash = stats.dash + st.DashGaps
				stats.beams = stats.beams + st.Beams
				stats.movers = stats.movers + st.Movers
				stats.scenery = stats.scenery + st.Scenery
				stats.maxGap = max(stats.maxGap, st.MaxGap)
				stats.attempts = stats.attempts + (layout.Attempt or 1)
				if (layout.Attempt or 1) > 1 then
					stats.retried = stats.retried + 1
				end
				stats.archetypes[layout.Archetype] = (stats.archetypes[layout.Archetype] or 0) + 1
				for _, th in ipairs(layout.Themes) do
					stats.themes[th] = (stats.themes[th] or 0) + 1
					stats.themeTotal = stats.themeTotal + 1
				end
				for kind, c in pairs(st.HazardCounts) do
					stats.hazardTypes[kind] = (stats.hazardTypes[kind] or 0) + c
				end
				local sig = signature(layout)
				if not stats.signatures[sig] then
					stats.signatures[sig] = true
					stats.distinct = stats.distinct + 1
				end
				-- keep a handful for the course builder scenario
				if seed <= 6 then
					W.layoutCache[diff.Id][seed] = layout
				end
			end
		end
		genTally:report()
		validTally:report()
		auditTally:report()
		detTally:report()
		api:report()
		W.layoutStats[diff.Id] = stats
		local n = max(stats.n, 1)
		means[di] = { steps = stats.steps / n, total = stats.total / n, height = stats.height / n, path = stats.path / n, hazards = stats.hazards / n / diff.Stages, golden = stats.golden / n / diff.Stages, regular = stats.tokens / n }
		T.info(string.format("*%-7s %d layouts in %.1fs: steps %.0f (%d-%d)  tokens %.0f value (%.1f coins + %.1f golden)  height %.0f  route %.0f  radius %.0f  hazards/stage %.1f  cannons %.2f  plates %.2f  dash %.2f  beams %.1f  movers %.1f  retries %s",
			diff.Id, stats.n, Mock.RealClock() - t0, stats.steps / n, stats.minSteps == huge and 0 or stats.minSteps, stats.maxSteps, stats.total / n, (stats.tokens - stats.golden) / n, stats.golden / n,
			stats.height / n, stats.path / n, stats.radius / n, stats.hazards / n / diff.Stages, stats.cannons / n, stats.bridges / n, stats.dash / n, stats.beams / n, stats.movers / n, pct(stats.retried, n)))
		T.info("*        archetypes: " .. mixText(stats.archetypes, n, 6))
		T.info("*        themes:     " .. mixText(stats.themes, stats.themeTotal, 14))
		T.info("*        hazards:    " .. mixText(stats.hazardTypes, max(stats.hazards, 1), 10))
		-- variety: every offered archetype / theme shows up, layouts differ
		if seeds >= 30 then
			local missingA, missingT = {}, {}
			for a in pairs(diff.Archetypes) do
				if (stats.archetypes[a] or 0) == 0 then
					missingA[#missingA + 1] = a
				end
			end
			for th in pairs(diff.Themes) do
				if (stats.themes[th] or 0) == 0 then
					missingT[#missingT + 1] = th
				end
			end
			table.sort(missingA)
			table.sort(missingT)
			T.check(#missingA == 0, diff.Id .. ": every offered archetype appears over " .. seeds .. " seeds", "never generated: " .. table.concat(missingA, ", "))
			T.check(#missingT == 0, diff.Id .. ": every offered stage theme appears over " .. seeds .. " seeds", "never generated: " .. table.concat(missingT, ", "))
		end
		T.check(stats.distinct >= stats.n * 0.9, diff.Id .. ": different seeds give different courses (" .. stats.distinct .. " distinct of " .. stats.n .. ")")
		-- a layout is a different seed's layout: the weights are respected (no theme the difficulty does not offer)
		local foreign = {}
		for th in pairs(stats.themes) do
			if not allowed(diff.Themes, th) then
				foreign[#foreign + 1] = th
			end
		end
		T.check(#foreign == 0, diff.Id .. ": only stage themes of Config.Difficulties are generated", table.concat(foreign, ", "))
	end
	for _, cat in ipairs(CATEGORIES) do
		catTally[cat]:report()
	end

	-- the five difficulties are meaningfully different
	for di = 2, #Config.Difficulties do
		local a, b = means[di - 1], means[di]
		local ida, idb = Config.Difficulties[di - 1].Id, Config.Difficulties[di].Id
		if a and b then
			T.check(b.steps > a.steps * 1.05, idb .. " courses have more steps than " .. ida, string.format("%.1f vs %.1f", b.steps, a.steps))
			T.check(b.total > a.total * 1.05, idb .. " courses carry more token value than " .. ida, string.format("%.1f vs %.1f", b.total, a.total))
			T.check(b.height > a.height, idb .. " courses climb higher than " .. ida, string.format("%.0f vs %.0f", b.height, a.height))
			T.check(b.hazards >= a.hazards - 0.05, idb .. " courses have at least as many hazards per stage as " .. ida, string.format("%.2f vs %.2f", b.hazards, a.hazards))
			T.check(b.golden >= a.golden - 0.05, idb .. " courses hide at least as many golden tokens per stage as " .. ida, string.format("%.2f vs %.2f", b.golden, a.golden))
		end
	end
	local easy, saint = W.layoutStats.Easy, W.layoutStats.Saint
	if easy and saint then
		T.check((easy.hazardTypes.Pendulum or 0) == 0 and (easy.hazardTypes.Wind or 0) == 0 and (easy.hazardTypes.Storm or 0) == 0, "Easy has no pendulums, wind or storms")
		T.check((saint.hazardTypes.Pendulum or 0) > 0 and (saint.hazardTypes.Wind or 0) > 0 and (saint.hazardTypes.Lightning or 0) > 0, "Saint uses pendulums, wind and lightning")
		T.check((easy.dash or 0) == 0 and saint.dash > 0, "only the harder levels need dashes (Easy none, Saint some)")
	end
	-- Stats helper
	local sample = W.layoutCache.Medium and W.layoutCache.Medium[1]
	if sample then
		local st = CL.Stats(sample)
		T.check(st.Steps == #sample.Steps and st.TotalTokens == sample.TotalTokens and st.Checkpoints == Config.GetDifficulty("Medium").Stages, "CourseLayout.Stats(layout) summarises steps / tokens / checkpoints")
		T.check(CB.Stats ~= nil and CB.Stats(sample).Steps == st.Steps, "CourseBuilder.Stats re-exports it")
	end
	-- the audit itself catches broken layouts (so a clean run above means something)
	do
		local hard = Config.GetDifficulty("Hard")
		local function auditCatches(cat, fn)
			local copy = CB.GenerateLayout("Hard", 1)
			fn(copy)
			local cats = audit(copy, hard, Config)
			return cats[cat] ~= nil
		end
		T.check(auditCatches("links", function(l)
			l.Steps[3].Pos = l.Steps[3].Pos + Vector3.new(0, 0, 60)
		end), "audit self-test: a 60 stud gap is reported under 'links'")
		T.check(auditCatches("links", function(l)
			l.Steps[4].Pos = l.Steps[4].Pos + Vector3.new(0, 20, 0)
		end), "audit self-test: a 20 stud rise is reported under 'links'")
		T.check(auditCatches("separation", function(l)
			l.Steps[5].Pos = l.Steps[1].Pos + Vector3.new(0, 0.5, 0)
		end), "audit self-test: overlapping steps are reported under 'separation'")
		T.check(auditCatches("headroom", function(l)
			l.Steps[10].Pos = l.Steps[8].Pos + Vector3.new(0, 5, 0)
		end), "audit self-test: a step hanging 3 studs above another is reported under 'headroom'")
		T.check(auditCatches("sizes", function(l)
			l.Steps[2].Size = Vector3.new(2, 2, 2)
		end), "audit self-test: a 2x2 platform is reported under 'sizes'")
		T.check(auditCatches("bounds", function(l)
			l.Steps[6].Pos = l.Steps[6].Pos + Vector3.new(300, 0, 0)
		end), "audit self-test: a step 300 studs away is reported under 'bounds'")
		T.check(auditCatches("themes", function(l)
			l.Themes[2] = l.Themes[1]
		end), "audit self-test: a repeated stage theme is reported under 'themes'")
		T.check(auditCatches("stages", function(l)
			l.Checkpoints[1] = l.Checkpoints[2]
		end), "audit self-test: a wrong checkpoint index is reported under 'stages'")
		T.check(auditCatches("tokens", function(l)
			for _, s in ipairs(l.Steps) do
				if s.Tokens and s.Tokens[1] then
					s.Tokens[1].Pos = s.Tokens[1].Pos + Vector3.new(0, 6, 0)
					break
				end
			end
		end), "audit self-test: a token floating 6 studs too high is reported under 'tokens'")
		T.check(auditCatches("scenery", function(l)
			for i = #l.Scenery, 1, -1 do
				if l.Scenery[i].Stage and l.Scenery[i].Stage > 0 then
					table.remove(l.Scenery, i)
				end
			end
		end), "audit self-test: missing stage landmarks are reported under 'scenery'")
	end
	-- the validator really rejects broken layouts
	local victim = W.layoutCache.Hard and W.layoutCache.Hard[1]
	if victim then
		local function mutated(fn)
			local copy = CB.GenerateLayout("Hard", 1)
			fn(copy)
			local ok, valid = pcall(CB.ValidateLayout, copy)
			return ok and valid == false
		end
		T.check(mutated(function(l)
			l.Steps[3].Pos = l.Steps[3].Pos + Vector3.new(0, 0, 60)
		end), "ValidateLayout rejects a layout with an impossible gap")
		T.check(mutated(function(l)
			l.Steps[4].Pos = l.Steps[4].Pos + Vector3.new(0, 20, 0)
		end), "ValidateLayout rejects an impossible rise")
		T.check(mutated(function(l)
			l.Steps[#l.Steps].Kind = "Platform"
		end), "ValidateLayout rejects a layout that does not end in a Finish")
		T.check(mutated(function(l)
			l.Archetype = "Teleporter"
		end), "ValidateLayout rejects an unknown archetype")
		T.check(mutated(function(l)
			l.Steps[5].Pos = l.Steps[1].Pos + Vector3.new(0, 0.5, 0)
		end), "ValidateLayout rejects steps that overlap or hang above each other")
	end
	flushErrors("layouts")
	flushWarnings("layouts")
end)

----------------------------------------------------------------------------------------------------
-- scenario: cannon ballistics
----------------------------------------------------------------------------------------------------
S.cannon = guarded("cannon", function()
	local Config = config()
	local PH = Config.Physics
	local list = W.cannons or {}
	if #list == 0 then
		T.fail("cannon: no CannonPad was found in any generated layout (did the layouts scenario run? do Medium+ offer the Cannon theme?)")
		return
	end
	local g = PH.Gravity
	local byDiff, n = {}, 0
	local tally = {
		time = T.tally("cannon flight time is within 1.0 - 2.2 s"),
		speed = T.tally("cannon launch speed is <= 170 studs/s"),
		peak = T.tally("cannon peak height is <= 60 studs above the pad"),
		dist = T.tally("cannon flies 25 - 60 studs horizontally"),
		margin = T.tally("cannon Target lies inside the landing top with a >= 2.5 stud margin"),
		height = T.tally("cannon Target is one root height (3 studs) above the landing top"),
		lands = T.tally("cannon: integrating the launch under workspace.Gravity lands on the Target (< 0.25 studs)"),
		lip = T.tally("cannon: the rider's feet touch down on the landing top (not beside it)"),
		clear = T.tally("cannon: the flight does not clip any other step"),
		link = T.tally("cannon: landing step is the next step, a plain platform with Link 'Cannon' that cannot be reached by running"),
		fields = T.tally("cannon: Hazard.Speed and Hazard.Apex match the ballistics"),
	}
	local worstErr, worstMargin = 0, huge
	local sMax, aMax, tMin, tMax, dMin, dMax = 0, 0, huge, 0, huge, 0
	for _, c in ipairs(list) do
		n = n + 1
		byDiff[c.diff] = (byDiff[c.diff] or 0) + 1
		local who = c.diff .. " seed " .. c.seed .. " step " .. c.index
		local t = c.flight
		tally.time:case(t >= 1.0 - 1e-6 and t <= 2.2 + 1e-6, who .. ": " .. fmt(t, 2) .. " s")
		local px, py, pz = c.pos[1], c.padTop + 3, c.pos[3]
		local vx, vy, vz = (c.target[1] - px) / t, (c.target[2] - py) / t + g * t / 2, (c.target[3] - pz) / t
		local speed = sqrt(vx * vx + vy * vy + vz * vz)
		local apex = 3 + (vy > 0 and vy * vy / (2 * g) or 0)
		sMax, aMax = max(sMax, speed), max(aMax, apex)
		tMin, tMax = min(tMin, t), max(tMax, t)
		tally.speed:case(speed <= 170 + 1e-6, who .. ": " .. fmt(speed) .. " studs/s")
		tally.peak:case(apex <= 60 + 1e-6, who .. ": " .. fmt(apex) .. " studs")
		tally.fields:case(c.speed ~= nil and c.apex ~= nil and abs(c.speed - speed) <= 0.5 and abs(c.apex - apex) <= 0.5, who .. ": Speed " .. tostring(c.speed) .. " vs " .. fmt(speed) .. ", Apex " .. tostring(c.apex) .. " vs " .. fmt(apex))
		local hd = sqrt((c.target[1] - px) ^ 2 + (c.target[3] - pz) ^ 2)
		dMin, dMax = min(dMin, hd), max(dMax, hd)
		tally.dist:case(hd >= 25 - 1e-6 and hd <= 60 + 1e-6, who .. ": " .. fmt(hd) .. " studs")
		-- numeric integration (position Verlet, 1/240 s: exact for constant gravity) with the gravity Roblox applies
		local x, y, z, vyy = px, py, pz, vy
		local dt = t / floor(t * 240 + 0.5)
		for _ = 1, floor(t * 240 + 0.5) do
			x, y, z = x + vx * dt, y + vyy * dt - 0.5 * g * dt * dt, z + vz * dt
			vyy = vyy - g * dt
		end
		-- the body of the rider (feet 3 studs below the root, head 2.7 above, radius ~1.2) must not clip another step
		local clipped
		if c.prisms then
			local frames = max(20, floor(t / 0.02))
			for k = 1, frames - 1 do
				local tau = t * k / frames
				local sx, sy, sz = px + vx * tau, py + vy * tau - 0.5 * g * tau * tau, pz + vz * tau
				for j, forms_ in ipairs(c.prisms) do
					if j ~= c.index and j ~= c.landingIndex and not clipped then
						for _, f in ipairs(forms_) do
							if sqrt((sx - f.cx) ^ 2 + (sz - f.cz) ^ 2) - f.r < 1.4 and sy + 2.7 > f.bot and sy - 3 < f.top then
								if pointToPrism(sx, sz, f) < 1.2 then
									clipped = "step " .. j .. " at t=" .. fmt(tau, 2)
								end
							end
						end
					end
				end
			end
		end
		tally.clear:case(clipped == nil, who .. ": clips " .. tostring(clipped))
		local err = sqrt((x - c.target[1]) ^ 2 + (y - c.target[2]) ^ 2 + (z - c.target[3]) ^ 2)
		worstErr = max(worstErr, err)
		tally.lands:case(err < 0.25, who .. ": lands " .. fmt(err, 2) .. " studs off")
		local land = c.landing
		if land and land.prism then
			local d, lx, lz = pointToPrism(c.target[1], c.target[3], land.prism)
			local inside = min(land.prism.hx - abs(lx), land.prism.hz - abs(lz))
			worstMargin = min(worstMargin, inside)
			tally.margin:case(inside >= 2.5 - 0.02, who .. ": margin " .. fmt(inside, 2))
			tally.height:case(abs(c.target[2] - (land.top + 3)) < 0.05, who .. ": Target.Y " .. fmt(c.target[2], 2) .. " vs landing top " .. fmt(land.top, 2))
			tally.lip:case(d <= 0.001, who .. ": lands " .. fmt(d, 2) .. " beside the platform")
			tally.link:case(c.landingIndex == c.index + 1 and land.kind == "Platform" and c.link == "Cannon" and (c.landingGap or 0) >= 20, who .. ": landing " .. tostring(c.landingIndex) .. " " .. tostring(land.kind) .. " Link " .. tostring(c.link) .. " gap " .. tostring(c.landingGap))
		else
			tally.margin:case(false, who .. ": no landing step")
		end
	end
	for _, tl in pairs(tally) do
		tl:report()
	end
	local parts = {}
	for _, id in ipairs(sortedKeys(byDiff)) do
		parts[#parts + 1] = id .. " " .. byDiff[id]
	end
	T.info(string.format("*cannons: %d in %d layouts (%s)  flight %.2f-%.2f s  distance %.0f-%.0f  max speed %.0f  max peak %.0f  worst integration error %.3f  smallest landing margin %.2f", n, (W.layoutSeeds or 0) * 5, table.concat(parts, ", "), tMin, tMax, dMin, dMax, sMax, aMax, worstErr, worstMargin == huge and 0 or worstMargin))
	T.check((byDiff.Easy or 0) == 0, "Easy has no cannons (its themes do not offer them)")
	T.check((byDiff.Medium or 0) + (byDiff.Hard or 0) + (byDiff.Extreme or 0) + (byDiff.Saint or 0) > 0, "Medium and harder courses contain cannons")
	flushErrors("cannon")
end)

----------------------------------------------------------------------------------------------------
-- scenario: CourseBuilder.Build
----------------------------------------------------------------------------------------------------
local function countTag(folder, tag)
	return #tagged(tag, folder)
end

local function nearVec(a, b, tol)
	return typeof(a) == "Vector3" and typeof(b) == "Vector3" and (a - b).Magnitude <= (tol or 0.05)
end

-- number of tagged parts the layout should produce, by Config.Tags key
local function expectedCounts(layout, Config)
	local e = {
		SpinBar = 0, StormCloud = 0, LightningZone = 0, VanishCloud = 0, MovingCloud = 0, BouncePad = 0, PressurePlate = 0,
		PlateBridge = 0, Pendulum = 0, WindGust = 0, CloudCannon = 0, Checkpoint = 0, FinishPad = 1,
	}
	for _, s in ipairs(layout.Steps) do
		local h = s.Hazard
		if s.Kind == "Checkpoint" then
			e.Checkpoint = e.Checkpoint + 1
		end
		if h then
			if h.Type == "SpinBar" then
				e.SpinBar = e.SpinBar + (h.Count or 1)
			elseif h.Type == "Storm" then
				e.StormCloud = e.StormCloud + 1
			elseif h.Type == "Lightning" then
				e.LightningZone = e.LightningZone + #h.Zones
			elseif h.Type == "Vanish" then
				e.VanishCloud = e.VanishCloud + 1
			elseif h.Type == "Moving" then
				e.MovingCloud = e.MovingCloud + 1
			elseif h.Type == "Bounce" then
				e.BouncePad = e.BouncePad + 1
			elseif h.Type == "PlateBridge" then
				e.PlateBridge = e.PlateBridge + 1
				e.PressurePlate = e.PressurePlate + #h.Sides
			elseif h.Type == "Pendulum" then
				e.Pendulum = e.Pendulum + 1
			elseif h.Type == "Wind" then
				e.WindGust = e.WindGust + 1
			elseif h.Type == "Cannon" then
				e.CloudCannon = e.CloudCannon + 1
			end
		end
	end
	return e
end

-- picks cached layouts so that between them every hazard type of v2 is built at least once
local function pickBuildLayouts(Config, CB)
	local picks = {}
	for _, diff in ipairs(Config.Difficulties) do
		local cache = W.layoutCache and W.layoutCache[diff.Id]
		for seed = 1, ARGS.quick and 2 or 3 do
			local layout = cache and cache[seed] or CB.GenerateLayout(diff.Id, seed)
			picks[#picks + 1] = { diff = diff, layout = layout, seed = seed }
		end
	end
	return picks
end

S.courses = guarded("courses", function()
	local Config = config()
	local CB = mod("CourseBuilder")
	local TS = mod("TokenService")
	if not CB then
		T.fail("courses needs CourseBuilder")
		return
	end
	local holder = Instance.new("Folder")
	holder.Name = "SmokeCourses"
	holder.Parent = workspace
	local origin = Vector3.new(30000, 900, 0)
	local picks = pickBuildLayouts(Config, CB)
	local seenTags = {}
	local maxParts, worst = 0, nil
	local unanchoredTotal, whiteTotal, neonTotal, builds = 0, 0, 0, 0
	local partsByDiff = {}
	local tallies = {
		build = T.tally("CourseBuilder.Build(layout, origin, parent) returns a CourseInfo and never raises"),
		folder = T.tally("the course lives in a Folder 'Course_<seed>' under the given parent"),
		budget = T.tally("a built course stays under the part budget (" .. CONTRACT.v2.partBudget.course .. " parts)"),
		start = T.tally("StartCFrame sits on the start platform (solid ground, at the origin)"),
		cps = T.tally("Checkpoints[i] = { Part (tagged, CheckpointIndex), Index, SpawnCFrame, Stage } for every stage"),
		finish = T.tally("Finish is a part tagged FinishPad at the end of the route"),
		info = T.tally("CourseInfo: KillY = origin.Y - 60, TotalTokens = token value, TotalSteps, Archetype, Themes"),
		counts = T.tally("tagged part counts match the layout's hazards (Config.Tags)"),
		attrs = T.tally("hazard attributes follow the Config.Tags comments"),
		geometry = T.tally("every step has solid, collidable ground at its top surface"),
		anchored = T.tally("course parts are Anchored (decor on moving parts is welded)"),
		tokens = T.tally("tokens: one CloudToken per layout token, golden ones tagged GoldenToken too (Value = GoldenValue)"),
		palette = T.tally("palette: no pure-white parts, Neon only on small accents"),
		cannons = T.tally("CloudCannon pads carry Target (world) and FlightTime from the layout"),
		pendulums = T.tally("Pendulum beams carry Hinge (world) / Axis from the layout and hang at rest from the hinge"),
		determinism = T.tally("building the same layout twice gives the same number of parts"),
		signs = T.tally("signs: START, FINISH, 'Checkpoint k/N' for every stage and one 'DASH!' hint per dash gap (Theme fonts)"),
	}
	local dumped = false
	for _, pick in ipairs(picks) do
		local diff, layout = pick.diff, pick.layout
		local who = diff.Id .. " seed " .. pick.seed
		local before = Mock.Stats()
		local t0 = Mock.RealClock()
		local ok, info = pcall(CB.Build, layout, origin, holder)
		tallies.build:case(ok and type(info) == "table", who .. ": " .. tostring(info))
		if ok and type(info) == "table" then
			builds = builds + 1
			local folder = info.Folder
			local nParts = Mock.CountDescendants(folder, "BasePart")
			partsByDiff[diff.Id] = max(partsByDiff[diff.Id] or 0, nParts)
			if nParts > maxParts then
				maxParts, worst = nParts, who
			end
			tallies.folder:case(typeof(folder) == "Instance" and folder.Name == "Course_" .. tostring(layout.Seed) and folder.Parent == holder, who .. ": folder " .. tostring(folder and folder.Name))
			tallies.budget:case(nParts < CONTRACT.v2.partBudget.course, who .. ": " .. nParts .. " parts")
			-- start
			local startOk = typeof(info.StartCFrame) == "CFrame" and nearVec(info.StartCFrame.Position, origin, 12)
			if startOk then
				local hit = workspace:Raycast(info.StartCFrame.Position + Vector3.new(0, 3, 0), Vector3.new(0, -12, 0))
				startOk = hit ~= nil and abs(hit.Position.Y - origin.Y) < 1.5
			end
			tallies.start:case(startOk, who .. ": StartCFrame " .. tostring(info.StartCFrame and info.StartCFrame.Position))
			-- checkpoints
			local cpOk, cpWhy = type(info.Checkpoints) == "table", ""
			for i = 1, diff.Stages do
				local cp = info.Checkpoints and info.Checkpoints[i]
				if not (cp and typeof(cp.Part) == "Instance" and cp.Part:IsA("BasePart") and cp.Index == i and typeof(cp.SpawnCFrame) == "CFrame" and cp.Stage == i
					and cp.Part:HasTag(Config.Tags.Checkpoint) and cp.Part:GetAttribute("CheckpointIndex") == i and cp.Part:IsDescendantOf(folder)) then
					cpOk, cpWhy = false, "checkpoint " .. i .. " is malformed"
					break
				end
				local expected = layout.Steps[layout.Checkpoints[i]]
				local off = cp.Part.Position - (origin + expected.Pos)
				if sqrt(off.X * off.X + off.Z * off.Z) > 12 or off.Y < -6 or off.Y > 10 then
					cpOk, cpWhy = false, "checkpoint " .. i .. " is not on its step (offset " .. tostring(off) .. ")"
				end
				if cp.SpawnCFrame.Position.Y <= origin.Y + expected.Pos.Y then
					cpOk, cpWhy = false, "checkpoint " .. i .. " SpawnCFrame is not above the pad"
				end
			end
			if info.Checkpoints and info.Checkpoints[diff.Stages + 1] ~= nil then
				cpOk, cpWhy = false, "too many checkpoints"
			end
			tallies.cps:case(cpOk, who .. ": " .. cpWhy)
			-- finish
			local fin = info.Finish
			local finishStep = layout.Steps[#layout.Steps]
			tallies.finish:case(typeof(fin) == "Instance" and fin:IsA("BasePart") and fin:HasTag(Config.Tags.FinishPad) and (fin.Position - (origin + finishStep.Pos)).Magnitude <= finishStep.Size.Y + 6, who .. ": Finish " .. tostring(fin and fin.Position))
			-- info
			local tokensTagged = tagged(Config.Tags.CloudToken, folder)
			local valueSum = 0
			for _, tk in ipairs(tokensTagged) do
				valueSum = valueSum + (tk:GetAttribute("Value") or 1)
			end
			tallies.info:case(abs(info.KillY - (origin.Y - 60)) < 0.01 and info.TotalTokens == valueSum and info.TotalTokens == layout.TotalTokens and info.TotalSteps == #layout.Steps
				and info.Archetype == layout.Archetype and type(info.Themes) == "table" and #info.Themes == #layout.Themes,
				who .. ": KillY " .. tostring(info.KillY) .. " TotalTokens " .. tostring(info.TotalTokens) .. " (placed " .. valueSum .. ", layout " .. layout.TotalTokens .. ") TotalSteps " .. tostring(info.TotalSteps) .. " Archetype " .. tostring(info.Archetype))
			-- counts per tag
			local expect = expectedCounts(layout, Config)
			local wrong = {}
			for key, want in pairs(expect) do
				local tag = Config.Tags[key]
				local got = tag and countTag(folder, tag) or -1
				seenTags[key] = (seenTags[key] or 0) + got
				if got ~= want then
					wrong[#wrong + 1] = key .. " " .. got .. " (layout: " .. want .. ")"
				end
			end
			table.sort(wrong)
			tallies.counts:case(#wrong == 0, who .. ": " .. table.concat(wrong, ", "))
			-- tokens
			local goldenTagged = tagged(Config.Tags.GoldenToken, folder)
			local goldenOk = #goldenTagged == layout.GoldenCount
			for _, tk in ipairs(goldenTagged) do
				goldenOk = goldenOk and tk:HasTag(Config.Tags.CloudToken) and tk:GetAttribute("Value") == Config.Tokens.GoldenValue
			end
			tallies.tokens:case(#tokensTagged == layout.TokenCount and goldenOk, who .. ": " .. #tokensTagged .. " tokens (layout " .. layout.TokenCount .. "), " .. #goldenTagged .. " golden (layout " .. layout.GoldenCount .. ")")
			-- attributes
			local attrBad = {}
			local function need(inst, name, kind, label)
				local v = inst:GetAttribute(name)
				if v == nil or (kind and typeof(v) ~= kind) then
					attrBad[#attrBad + 1] = label .. "." .. name .. " is " .. typeof(v) .. " (expected " .. tostring(kind) .. ")"
				end
				return v
			end
			-- every tagged part carries the attributes Config.Tags documents (tools/contract.json: v2.tagAttributes)
			for tagKey, attrs in pairs(CONTRACT.v2.tagAttributes) do
				local tag = Config.Tags[tagKey]
				if tag then
					for _, inst in ipairs(tagged(tag, folder)) do
						for attrName, attrType in pairs(attrs) do
							need(inst, attrName, attrType, tagKey)
						end
					end
				else
					attrBad[#attrBad + 1] = "contract.json lists the unknown tag " .. tagKey
				end
			end
			local plateIds = {}
			for _, p in ipairs(tagged(Config.Tags.PressurePlate, folder)) do
				plateIds[p:GetAttribute("BridgeId") or "?"] = true
			end
			for _, p in ipairs(tagged(Config.Tags.PlateBridge, folder)) do
				local id = p:GetAttribute("BridgeId")
				if not plateIds[id or "?"] then
					attrBad[#attrBad + 1] = "PlateBridge " .. tostring(id) .. " has no PressurePlate with the same BridgeId"
				end
			end
			for _, p in ipairs(tagged(Config.Tags.WindGust, folder)) do
				local dir = p:GetAttribute("Direction")
				if typeof(dir) == "Vector3" and abs(dir.Magnitude - 1) > 0.01 then
					attrBad[#attrBad + 1] = "WindGust.Direction is not a unit vector"
				end
			end
			for _, p in ipairs(tagged(Config.Tags.Pendulum, folder)) do
				local axis = p:GetAttribute("Axis")
				if typeof(axis) == "Vector3" and (abs(axis.Magnitude - 1) > 0.01 or abs(axis.Y) > 0.01) then
					attrBad[#attrBad + 1] = "Pendulum.Axis is not a horizontal unit vector"
				end
			end
			tallies.attrs:case(#attrBad == 0, who .. ": " .. table.concat(attrBad, "; "))
			-- cannons
			local cannonBad = {}
			local layoutCannons = {}
			for _, s in ipairs(layout.Steps) do
				if s.Hazard and s.Hazard.Type == "Cannon" then
					layoutCannons[#layoutCannons + 1] = s.Hazard
				end
			end
			local pads = tagged(Config.Tags.CloudCannon, folder)
			for _, p in ipairs(pads) do
				local target, flight = p:GetAttribute("Target"), p:GetAttribute("FlightTime")
				if typeof(target) ~= "Vector3" or type(flight) ~= "number" then
					cannonBad[#cannonBad + 1] = "pad lacks Target / FlightTime"
				else
					local match = false
					for _, h in ipairs(layoutCannons) do
						if nearVec(target, origin + h.Target, 0.05) and abs(flight - h.FlightTime) < 1e-6 then
							match = true
						end
					end
					if not match then
						cannonBad[#cannonBad + 1] = "pad Target " .. tostring(target) .. " is not origin + layout Target"
					end
				end
			end
			tallies.cannons:case(#cannonBad == 0, who .. ": " .. table.concat(cannonBad, "; "))
			-- pendulums
			local pendBad = {}
			local layoutPend = {}
			for _, s in ipairs(layout.Steps) do
				if s.Hazard and s.Hazard.Type == "Pendulum" then
					layoutPend[#layoutPend + 1] = s.Hazard
				end
			end
			for _, p in ipairs(tagged(Config.Tags.Pendulum, folder)) do
				local hinge, axis = p:GetAttribute("Hinge"), p:GetAttribute("Axis")
				local period, arc, damage = p:GetAttribute("Period"), p:GetAttribute("Arc"), p:GetAttribute("Damage")
				if typeof(hinge) ~= "Vector3" or typeof(axis) ~= "Vector3" or type(period) ~= "number" or type(arc) ~= "number" or type(damage) ~= "number" then
					pendBad[#pendBad + 1] = "beam lacks Hinge / Axis / Period / Arc / Damage"
				else
					local match
					for _, h in ipairs(layoutPend) do
						if nearVec(hinge, origin + h.Hinge, 0.05) then
							match = h
						end
					end
					if not match then
						pendBad[#pendBad + 1] = "Hinge " .. tostring(hinge) .. " is not origin + layout Hinge"
					else
						if (axis - match.Axis).Magnitude > 0.01 then
							pendBad[#pendBad + 1] = "Axis " .. tostring(axis) .. " differs from the layout " .. tostring(match.Axis)
						end
						if abs(arc - match.Arc) > 1e-6 or abs(period - match.Period) > 1e-6 then
							pendBad[#pendBad + 1] = "Arc / Period differ from the layout"
						end
						-- at rest the beam hangs straight down from the hinge: its top end is at the hinge
						local top = p.Position + Vector3.new(0, p.Size.Y / 2, 0)
						if abs(p.CFrame.UpVector.Y) < 0.99 or (top - hinge).Magnitude > 1.5 then
							pendBad[#pendBad + 1] = "beam at rest is not hanging from the hinge (top end " .. tostring(top) .. ", hinge " .. tostring(hinge) .. ")"
						end
					end
				end
			end
			tallies.pendulums:case(#pendBad == 0, who .. ": " .. table.concat(pendBad, "; "))
			-- geometry: ground under every step's centre
			-- (hazard hubs / pads sit on top of some platforms, so look at the centre and four inner points)
			local missing = {}
			local params = RaycastParams.new()
			params.RespectCanCollide = true
			for i, s in ipairs(layout.Steps) do
				local top = origin + s.Pos
				local yaw = (s.Yaw or 0) * RAD
				local sn, cs = sin(yaw), cos(yaw)
				local ox, oz = max(0, s.Size.X / 2 - 1.6), max(0, s.Size.Z / 2 - 1.6)
				local good, lastHit = false, nil
				for _, q in ipairs({ { 0, 0 }, { ox, oz }, { -ox, oz }, { ox, -oz }, { -ox, -oz } }) do
					local wx = q[1] * cs + q[2] * sn
					local wz = -q[1] * sn + q[2] * cs
					local hit = workspace:Raycast(top + Vector3.new(wx, 4, wz), Vector3.new(0, -9, 0), params)
					lastHit = hit
					if hit and hit.Position.Y - top.Y >= -0.6 and hit.Position.Y - top.Y <= 1.0 then
						good = true
					end
				end
				if not good and #missing < 3 then
					missing[#missing + 1] = "step " .. i .. " " .. s.Kind .. " " .. (lastHit and ("surface " .. fmt(lastHit.Position.Y - top.Y, 2) .. " off the top") or "no ground")
				end
			end
			tallies.geometry:case(#missing == 0, who .. ": " .. table.concat(missing, "; "))
			-- anchoring
			local loose = 0
			for _, d in ipairs(folder:GetDescendants()) do
				if d:IsA("BasePart") and not d.Anchored then
					local welded = false
					for _, w in ipairs(d:GetDescendants()) do
						if w:IsA("WeldConstraint") then
							welded = true
						end
					end
					if not welded then
						for _, w in ipairs(d.Parent and d.Parent:GetChildren() or {}) do
							if w:IsA("WeldConstraint") and (w.Part0 == d or w.Part1 == d) then
								welded = true
							end
						end
					end
					if not welded then
						loose = loose + 1
					end
				end
			end
			unanchoredTotal = unanchoredTotal + loose
			tallies.anchored:case(loose == 0, who .. ": " .. loose .. " unanchored, unwelded parts")
			-- palette
			local pal = K.paletteAudit(folder, { maxNeonFace = 220 })
			whiteTotal = whiteTotal + pal.whiteCount
			neonTotal = neonTotal + pal.neonCount
			tallies.palette:case(pal.whiteCount == 0 and pal.bigNeonCount == 0, who .. ": white " .. pal.whiteCount .. " (" .. table.concat(pal.white, "; ") .. "), big neon " .. pal.bigNeonCount .. " (" .. table.concat(pal.bigNeon, "; ") .. ")")
			-- signs (billboards / surface guis built from Theme labels)
			local text = K.plainText(K.textsUnder(folder)):upper()
			local signBad = {}
			if not text:find("START", 1, true) then
				signBad[#signBad + 1] = "no START sign"
			end
			if not text:find("FINISH", 1, true) then
				signBad[#signBad + 1] = "no FINISH sign"
			end
			for k = 1, diff.Stages do
				if not text:find("CHECKPOINT " .. k .. "/" .. diff.Stages, 1, true) and not text:find("CHECKPOINT " .. k .. " / " .. diff.Stages, 1, true) then
					signBad[#signBad + 1] = "no 'Checkpoint " .. k .. "/" .. diff.Stages .. "' label"
					break
				end
			end
			local hints = 0
			for _, st in ipairs(layout.Steps) do
				if st.DashHint then
					hints = hints + 1
				end
			end
			local dashTexts = 0
			for _, t in ipairs(K.textsUnder(folder)) do
				if (tostring(t):gsub("<[^>]*>", "")):upper():match("^%s*DASH%s*!+%s*$") then
					dashTexts = dashTexts + 1
				end
			end
			if hints > 0 and dashTexts < hints then
				signBad[#signBad + 1] = hints .. " dash gaps but only " .. dashTexts .. " 'DASH' labels"
			elseif hints == 0 and dashTexts > 0 then
				signBad[#signBad + 1] = dashTexts .. " 'DASH' labels without a dash gap"
			end
			tallies.signs:case(#signBad == 0, who .. ": " .. table.concat(signBad, "; "))
			-- determinism: a second build of the same layout
			if pick.seed == 1 then
				local ok2, info2 = pcall(CB.Build, layout, origin + Vector3.new(0, 0, 3000), holder)
				if ok2 and type(info2) == "table" then
					local n2 = Mock.CountDescendants(info2.Folder, "BasePart")
					tallies.determinism:case(n2 == nParts, who .. ": " .. nParts .. " vs " .. n2 .. " parts")
					info2.Folder:Destroy()
				else
					tallies.determinism:case(false, who .. ": second build failed: " .. tostring(info2))
				end
			end
			T.info(string.format("*built %-8s seed %d: %4d parts, %3d instances, %d tokens, %.2fs", diff.Id, pick.seed, nParts, Mock.CountDescendants(folder), #tokensTagged, Mock.RealClock() - t0))
			-- cleanliness: destroying the folder removes everything
			folder:Destroy()
		end
	end
	for _, tl in pairs(tallies) do
		tl:report()
	end
	local seen = {}
	for _, key in ipairs(sortedKeys(seenTags)) do
		seen[#seen + 1] = key .. "=" .. seenTags[key]
	end
	T.info("*tagged parts built over " .. builds .. " courses: " .. table.concat(seen, " "))
	T.info("*largest course: " .. tostring(worst) .. " with " .. maxParts .. " parts (budget " .. CONTRACT.v2.partBudget.course .. ")")
	for _, key in ipairs({ "SpinBar", "StormCloud", "LightningZone", "VanishCloud", "MovingCloud", "BouncePad", "PressurePlate", "PlateBridge", "Pendulum", "WindGust", "CloudCannon", "Checkpoint", "FinishPad" }) do
		T.check((seenTags[key] or 0) > 0, "the built courses contain " .. key .. " parts (tag Config.Tags." .. key .. ")")
	end
	for i = 2, #Config.Difficulties do
		local a, b = Config.Difficulties[i - 1].Id, Config.Difficulties[i].Id
		T.check((partsByDiff[b] or 0) >= (partsByDiff[a] or 0) * 0.8, b .. " courses are at least as detailed as " .. a, (partsByDiff[b] or 0) .. " vs " .. (partsByDiff[a] or 0) .. " parts")
	end
	-- Build is defensive
	local okNil = pcall(CB.Build, CB.GenerateLayout("Easy", 77), origin, holder)
	T.check(okNil, "Build works for a fresh layout (Easy, seed 77)")
	local stubOk, stubInfo = pcall(CB.Build, { DifficultyId = "Easy", Seed = 5, Steps = {}, Stages = {}, Checkpoints = {}, Scenery = {}, TotalTokens = 0, Bounds = { Min = Vector3.new(), Max = Vector3.new() } }, origin, holder)
	T.check(stubOk, "Build survives the generator's empty fallback layout", tostring(stubInfo))
	holder:Destroy()
	K.advance(2)
	T.eq(#K.courseFolders(), 0, "no Course_* folder is left in workspace after the course scenario")
	flushErrors("courses")
	flushWarnings("courses", { "layout without start" })
end)

return S
