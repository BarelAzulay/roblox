-- smoke_hazards.lua: the `hazards` scenario (HazardService + TokenService on generated v2 courses).
--
-- Builds a few real courses that between them contain every hazard of Config.Tags, attaches HazardService and
-- drives each behaviour with a fake player:
--   v1: SpinBar, MovingCloud, StormCloud, LightningZone, VanishCloud, BouncePad, PressurePlate + PlateBridge
--   v2: Pendulum (swing arc / period / damage), WindGust (warning, push, speed cap, no damage), CloudCannon (launch
--       velocity from the contract formula, landing on the Target, protection in flight, re-arm), golden tokens
-- and finally that stopFn() leaves nothing running or lingering.
--
-- Loaded by smoke.py after smoke_server.lua, which exports its helper kit as the global K.
-- Plain Lua 5.1 syntax only.

local K = _G.K
local T = K.T
local guarded = K.guarded
local W = K.W
local fmt = K.fmt
local mod = K.mod
local config = K.config
local advance = K.advance
local flushErrors, flushWarnings = K.flushErrors, K.flushWarnings
local freshPlayers, removePlayers = K.freshPlayers, K.removePlayers
local remotesFor, logSize = K.remotesFor, K.logSize
local tagged, needBoot = K.tagged, K.needBoot
local DS = K.DS

local S = {}
local huge = math.huge
local abs, max, min, sqrt = math.abs, math.max, math.min, math.sqrt

local WANT = { "Moving", "Vanish", "Bounce", "SpinBar", "Storm", "Lightning", "Pendulum", "Wind", "Cannon", "PlateBridge" }

-- Half of the part's height in WORLD space (a rotated cylinder pad is "thin" along its local X, not Y).
local function halfHeight(part)
	local c, s = part.CFrame, part.Size
	return (abs(c.RightVector.Y) * s.X + abs(c.UpVector.Y) * s.Y + abs(c.LookVector.Y) * s.Z) / 2
end

-- Root position of a character standing on `part` (feet 0.1 stud inside the surface so the touch registers).
local function topOf(part)
	return part.Position + Vector3.new(0, halfHeight(part) + 2.9, 0)
end

local function yawOf(cf)
	local look = cf.LookVector
	return math.deg(math.atan2(look.X, look.Z))
end

local function wrap180(a)
	a = a % 360
	if a > 180 then
		a = a - 360
	end
	return a
end

-- greedy cover: a few (difficulty, seed) layouts that contain every hazard type
local function pickLayouts(CB, Config)
	local candidates = {}
	for _, diff in ipairs(Config.Difficulties) do
		for seed = 1, 25 do
			local layout = CB.GenerateLayout(diff.Id, seed)
			local have = {}
			for _, st in ipairs(layout.Steps) do
				if st.Hazard then
					have[st.Hazard.Type] = true
				end
			end
			candidates[#candidates + 1] = { layout = layout, have = have, id = diff.Id, seed = seed }
		end
	end
	local missing = {}
	for _, w in ipairs(WANT) do
		missing[w] = true
	end
	local picks = {}
	for _ = 1, 5 do
		local best, bestScore = nil, 0
		for _, c in ipairs(candidates) do
			local score = 0
			for w in pairs(missing) do
				if c.have[w] then
					score = score + 1
				end
			end
			if score > bestScore then
				best, bestScore = c, score
			end
		end
		if not best then
			break
		end
		picks[#picks + 1] = best
		for w in pairs(missing) do
			if best.have[w] then
				missing[w] = nil
			end
		end
		if next(missing) == nil then
			break
		end
	end
	return picks, missing
end

S.hazards = guarded("hazards", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local CB, HS, TS = mod("CourseBuilder"), mod("HazardService"), mod("TokenService")
	local players = freshPlayers(1, "Haz")
	local a = players[1]
	a:SetAttribute("InMatch", true)
	advance(2.0) -- spawn i-frames
	local holder = Instance.new("Folder")
	holder.Name = "SmokeHazards"
	holder.Parent = workspace
	local picks, missing = pickLayouts(CB, Config)
	local lacking = {}
	for w in pairs(missing) do
		lacking[#lacking + 1] = w
	end
	table.sort(lacking)
	T.check(#lacking == 0, "the generator offers every hazard type within a few layouts (" .. #picks .. " courses cover all)", "never found: " .. table.concat(lacking, ", "))
	local infos, stops, containers = {}, {}, {}
	local baseStats = Mock.Stats()
	local active = true
	for i, pick in ipairs(picks) do
		local info = CB.Build(pick.layout, Vector3.new(i * 900, 3000, 0), holder)
		infos[#infos + 1] = info
		containers[#containers + 1] = info.Folder
	end
	local before = {}
	for _, d in ipairs(holder:GetDescendants()) do
		before[d] = true
	end
	for _, info in ipairs(infos) do
		local stop = HS.Attach(info.Folder, { IsActive = function() return active end })
		T.check(type(stop) == "function", "HazardService.Attach returns a stop function")
		stops[#stops + 1] = stop
	end
	advance(0.6)
	local afterAttach = {}
	for _, d in ipairs(holder:GetDescendants()) do
		afterAttach[d] = true
	end
	local function all(tag)
		local out = {}
		for _, c in ipairs(containers) do
			for _, inst in ipairs(tagged(tag, c)) do
				out[#out + 1] = inst
			end
		end
		return out
	end
	local function dmgEntries(kind, fromIndex)
		local out = {}
		for _, e in ipairs(remotesFor("DamageTaken", a.UserId, fromIndex)) do
			if e.args[2] == kind then
				out[#out + 1] = e
			end
		end
		return out
	end
	local AWAY = Vector3.new(-4000, 3000, 0)
	local function root()
		return K.root(a)
	end
	-- the mock has no friction: knockback / bounce velocities would otherwise carry into the next test
	local function away()
		Mock.Teleport(a, AWAY)
		root().AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		advance(0.1)
	end
	local function reset()
		if DS().IsDowned(a) then
			DS().Revive(a)
		end
		DS().SetHealthFraction(a, 1)
		root().AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		advance(Config.Damage.IFrames + 0.3)
	end

	-- SpinBar -----------------------------------------------------------------------------------------
	local bars = all(Config.Tags.SpinBar)
	if #bars > 0 then
		local bar = bars[1]
		local speed = bar:GetAttribute("Speed") or 60
		local c0 = bar.CFrame
		advance(0.3)
		local turned = wrap180(yawOf(bar.CFrame) - yawOf(c0))
		T.check(bar.CFrame ~= c0, "SpinBar rotates", "CFrame unchanged")
		T.check(abs(abs(turned) - abs(speed) * 0.3) <= max(6, abs(speed) * 0.3 * 0.2), "...at its Speed attribute (" .. fmt(speed, 0) .. " deg/s)", "turned " .. fmt(turned, 1) .. " degrees in 0.3 s")
		T.check((bar.CFrame.Position - c0.Position).Magnitude < 0.01, "SpinBar rotates around its own axis (position stays)")
		local mark = logSize()
		local dmg = bar:GetAttribute("Damage") or 15
		Mock.Teleport(a, bar.Position)
		advance(0.8)
		local hits = dmgEntries("SpinBar", mark)
		T.check(#hits >= 1 and hits[1].args[1] == dmg, "touching a SpinBar deals its Damage as 'SpinBar'", #hits .. " hits, first " .. (hits[1] and tostring(hits[1].args[1]) or "-") .. " expected " .. dmg)
		away()
		reset()
		-- paused hazards are harmless and frozen
		active = false
		mark = logSize()
		local c1 = bar.CFrame
		Mock.Teleport(a, bar.Position)
		advance(1.0)
		T.eq(#dmgEntries("SpinBar", mark), 0, "hazards do nothing while matchHandle.IsActive() is false")
		T.check(bar.CFrame == c1 or (bar.CFrame.Position - c1.Position).Magnitude < 0.01 and abs(wrap180(yawOf(bar.CFrame) - yawOf(c1))) < 0.5, "paused SpinBars stop turning")
		active = true
		away()
		reset()
	else
		T.fail("hazards: no SpinBar in the sampled courses")
	end

	-- MovingCloud ------------------------------------------------------------------------------------
	local movers = all(Config.Tags.MovingCloud)
	if #movers > 0 then
		local cloud = movers[1]
		local offset = cloud:GetAttribute("EndOffset")
		local period = cloud:GetAttribute("Period") or 3
		local lo, hi = Vector3.new(huge, huge, huge), Vector3.new(-huge, -huge, -huge)
		local sawVelocity = false
		for _ = 1, math.floor(period * 30 * 2.2) do
			advance(1 / 30)
			local p = cloud.Position
			lo = Vector3.new(min(lo.X, p.X), min(lo.Y, p.Y), min(lo.Z, p.Z))
			hi = Vector3.new(max(hi.X, p.X), max(hi.Y, p.Y), max(hi.Z, p.Z))
			if cloud.AssemblyLinearVelocity.Magnitude > 0.2 then
				sawVelocity = true
			end
		end
		local travelled = (hi - lo).Magnitude
		if typeof(offset) == "Vector3" then
			T.check(abs(travelled - offset.Magnitude) <= offset.Magnitude * 0.15 + 0.3, "MovingCloud travels EndOffset back and forth", "travelled " .. fmt(travelled) .. ", EndOffset " .. fmt(offset.Magnitude))
		else
			T.check(travelled > 1, "MovingCloud moves", "travelled " .. fmt(travelled))
		end
		-- passengers: either the server carries them or the cloud publishes its velocity as a moving surface
		Mock.Teleport(a, topOf(cloud))
		advance(0.1)
		local startRoot, startCloud = root().Position, cloud.Position
		advance(period / 4)
		local movedRoot = root().Position - startRoot
		local movedCloud = cloud.Position - startCloud
		if movedCloud.Magnitude > 1 then
			local carried = (movedRoot - movedCloud).Magnitude <= movedCloud.Magnitude * 0.5 + 0.5
			T.check(carried or sawVelocity, "players standing on a MovingCloud are carried (CFrame nudge or published AssemblyLinearVelocity)", "cloud moved " .. fmt(movedCloud.Magnitude) .. ", player " .. fmt(movedRoot.Magnitude) .. ", velocity seen: " .. tostring(sawVelocity))
		end
		away()
	else
		T.fail("hazards: no MovingCloud in the sampled courses")
	end

	-- StormCloud ----------------------------------------------------------------------------------------
	local storms = all(Config.Tags.StormCloud)
	if #storms > 0 then
		local storm = storms[1]
		local dps = storm:GetAttribute("DPS") or 8
		local mark = logSize()
		Mock.Teleport(a, storm.Position)
		advance(2.1)
		local hits = dmgEntries("Storm", mark)
		local total = 0
		for _, e in ipairs(hits) do
			total = total + e.args[1]
		end
		T.check(#hits >= 4, "players inside a StormCloud are hit repeatedly (4 Hz ticks)", #hits .. " hits in 2 s")
		T.check(total >= dps * 1.2 and total <= dps * 2.6, "StormCloud deals ~DPS per second", "total " .. fmt(total) .. " over 2 s with DPS " .. dps)
		away()
		reset()
		mark = logSize()
		advance(1.0)
		T.eq(#dmgEntries("Storm", mark), 0, "no storm damage outside the cloud")
	else
		T.fail("hazards: no StormCloud in the sampled courses")
	end

	-- LightningZone ---------------------------------------------------------------------------------------
	local zones = all(Config.Tags.LightningZone)
	if #zones > 0 then
		local zone = zones[1]
		local interval = zone:GetAttribute("Interval") or 4
		local warning = zone:GetAttribute("Warning") or 1.2
		local dmg = zone:GetAttribute("Damage") or 28
		local mark = logSize()
		Mock.Teleport(a, zone.Position)
		-- a warning disc / bolt is any visible part around the zone's footprint that did not exist before the hazards
		-- were attached (the cycle may already be in its warning phase when this loop starts)
		local reach = max(zone.Size.X, zone.Size.Z) / 2 + 3
		local function newPartHere()
			for _, d in ipairs(holder:GetDescendants()) do
				if not before[d] and d:IsA("BasePart") and d.Transparency < 0.98 then
					local dx, dz = d.Position.X - zone.Position.X, d.Position.Z - zone.Position.Z
					if sqrt(dx * dx + dz * dz) <= reach then
						return true
					end
				end
			end
			return false
		end
		-- The loop may start in any phase of the warn -> strike cycle (the ring is removed in the same instant the bolt
		-- appears), so the first strike is only a sync point: the warning is judged on the NEXT cycle, counting only
		-- parts that did not exist right after that first strike.
		local function waitForStrike(since, limit)
			local deadline = Mock.Clock.now + limit
			local firstPart
			while Mock.Clock.now < deadline do
				advance(0.05)
				if not firstPart and newPartHere() then
					firstPart = Mock.Clock.now
				end
				local found = dmgEntries("Lightning", since)[1]
				if found then
					return found, Mock.Clock.now, firstPart
				end
				DS().SetHealthFraction(a, 1) -- keep the player fed so the test cannot kill them before the strikes
			end
			return nil, nil, firstPart
		end
		local hit1, hit1At = waitForStrike(mark, interval + warning + 3)
		T.check(hit1 ~= nil, "a LightningZone strikes players inside its radius", "no 'Lightning' damage within " .. fmt(interval + warning + 3) .. " s")
		local hit, hitAt, firstPartAt = hit1, hit1At, nil
		if hit1 then
			DS().SetHealthFraction(a, 1)
			-- parts alive right after strike 1 (its bolt, the dying ring) are not the warning of strike 2
			local sync = {}
			for _, d in ipairs(holder:GetDescendants()) do
				sync[d] = true
			end
			local baseNew = newPartHere
			newPartHere = function()
				for _, d in ipairs(holder:GetDescendants()) do
					if not before[d] and not sync[d] and d:IsA("BasePart") and d.Transparency < 0.98 then
						local dx, dz = d.Position.X - zone.Position.X, d.Position.Z - zone.Position.Z
						if sqrt(dx * dx + dz * dz) <= reach then
							return true
						end
					end
				end
				return false
			end
			local mark2 = logSize()
			local hit2
			hit2, hitAt, firstPartAt = waitForStrike(mark2, interval * 2 + warning + 3)
			newPartHere = baseNew
			T.check(hit2 ~= nil, "a LightningZone keeps striking every cycle", "no second 'Lightning' damage within " .. fmt(interval * 2 + warning + 3) .. " s")
			hit = hit2 or hit1
		end
		local warned = firstPartAt ~= nil and hitAt ~= nil and hitAt - firstPartAt >= warning * 0.6
		T.check(warned, "a LightningZone shows a warning (new parts above the zone) before it strikes", firstPartAt and hitAt and ("warning at " .. fmt(firstPartAt, 2) .. ", strike at " .. fmt(hitAt, 2) .. ", Warning attr " .. warning) or "no warning parts seen before the second strike")
		if hit then
			T.near(hit.args[1], dmg, 0.01, "lightning deals its Damage attribute")
		end
		away()
		reset()
		-- bolts and discs are short-lived: count runtime parts that appeared after the hazards started
		local function runtimeParts()
			local n = 0
			for _, d in ipairs(holder:GetDescendants()) do
				if d:IsA("BasePart") and not afterAttach[d] then
					n = n + 1
				end
			end
			return n
		end
		local peak = 0
		for _ = 1, 24 do
			advance(interval / 2)
			peak = max(peak, runtimeParts())
		end
		T.check(peak <= 90, "lightning bolts / warning discs are short-lived (bounded count)", "peak " .. peak .. " temporary parts")
		W.runtimeParts = runtimeParts
	else
		T.fail("hazards: no LightningZone in the sampled courses")
	end

	-- VanishCloud ---------------------------------------------------------------------------------------------
	local vanish = all(Config.Tags.VanishCloud)
	if #vanish > 0 then
		local cloud = vanish[1]
		local delay = cloud:GetAttribute("VanishDelay") or 0.9
		local back = cloud:GetAttribute("ReturnDelay") or 3.5
		Mock.Teleport(a, topOf(cloud))
		advance(delay + 0.8)
		away()
		T.check(cloud.CanCollide == false, "a VanishCloud turns non-solid after VanishDelay", "CanCollide " .. tostring(cloud.CanCollide))
		T.check(cloud.Transparency >= 0.8, "...and fades out", "Transparency " .. tostring(cloud.Transparency))
		advance(back + 2)
		T.check(cloud.CanCollide == true, "a VanishCloud returns after ReturnDelay", "CanCollide " .. tostring(cloud.CanCollide))
		T.check(cloud.Transparency <= 0.3, "...and becomes visible again", "Transparency " .. tostring(cloud.Transparency))
	else
		T.fail("hazards: no VanishCloud in the sampled courses")
	end

	-- BouncePad ---------------------------------------------------------------------------------------------------
	local pads = all(Config.Tags.BouncePad)
	if #pads > 0 then
		local pad = pads[1]
		local power = pad:GetAttribute("Power") or 90
		root().AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		Mock.Teleport(a, topOf(pad))
		advance(0.3)
		T.near(root().AssemblyLinearVelocity.Y, power, 1, "a BouncePad launches players with Power")
		root().AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		Mock.Touch(pad, root())
		advance(0.05)
		T.near(root().AssemblyLinearVelocity.Y, 0, 0.5, "BouncePad has a 0.3 s debounce")
		local speed = pad:GetAttribute("LaunchSpeed")
		if T.check(type(speed) == "number" and speed > 0, "BouncePads carry a LaunchSpeed attribute", tostring(speed)) then
			advance(0.5)
			root().AssemblyLinearVelocity = Vector3.new(3, 0, 4) -- 5 studs/s along (0.6, 0, 0.8)
			Mock.Touch(pad, root())
			advance(0.05)
			local v = root().AssemblyLinearVelocity
			T.near(v.Y, power, 1, "a moving player still gets the full Power")
			T.near(sqrt(v.X * v.X + v.Z * v.Z), speed, 0.5, "a moving player leaves a BouncePad at LaunchSpeed")
			T.near(v.X, speed * 0.6, 0.5, "...keeping the heading (X)")
			T.near(v.Z, speed * 0.8, 0.5, "...keeping the heading (Z)")
			advance(0.5)
			root().AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			Mock.Touch(pad, root())
			advance(0.05)
			v = root().AssemblyLinearVelocity
			T.near(v.Y, power, 1, "a standing player gets the full Power")
			T.near(sqrt(v.X * v.X + v.Z * v.Z), 0, 0.5, "a standing player bounces straight up")
		end
		away()
	else
		T.fail("hazards: no BouncePad in the sampled courses")
	end

	-- PressurePlate + PlateBridge --------------------------------------------------------------------------------------
	local plates = all(Config.Tags.PressurePlate)
	if #plates > 0 then
		local plate = plates[1]
		local id = plate:GetAttribute("BridgeId")
		local bridges = {}
		for _, b in ipairs(all(Config.Tags.PlateBridge)) do
			if b:GetAttribute("BridgeId") == id then
				bridges[#bridges + 1] = b
			end
		end
		T.check(id ~= nil and #bridges >= 1, "plate and bridge share a BridgeId", tostring(id))
		local function solid()
			for _, b in ipairs(bridges) do
				if b.CanCollide then
					return true
				end
			end
			return false
		end
		advance(0.5)
		T.check(not solid(), "bridges are not solid while nobody stands on the plate")
		Mock.Teleport(a, topOf(plate))
		advance(0.8)
		T.check(solid(), "standing on a PressurePlate makes its PlateBridge solid")
		local visible = false
		for _, b in ipairs(bridges) do
			visible = visible or b.Transparency < 0.5
		end
		T.check(visible, "...and visible")
		away()
		advance(0.4)
		T.check(solid(), "the bridge stays ~1 s after the last player leaves")
		advance(2.5)
		T.check(not solid(), "the bridge retracts after the plate is released")
	else
		T.fail("hazards: no PressurePlate in the sampled courses")
	end

	-- Pendulum ---------------------------------------------------------------------------------------------------------------
	local beams = all(Config.Tags.Pendulum)
	if #beams > 0 then
		local beam = beams[1]
		local hinge, axis = beam:GetAttribute("Hinge"), beam:GetAttribute("Axis")
		local period, arc, dmg = beam:GetAttribute("Period"), beam:GetAttribute("Arc"), beam:GetAttribute("Damage")
		if T.check(typeof(hinge) == "Vector3" and typeof(axis) == "Vector3" and type(period) == "number" and type(arc) == "number" and type(dmg) == "number", "Pendulum beams carry Hinge / Axis / Period / Arc / Damage") then
			-- rest pose: hangs straight down from the hinge, so the swing angle is the angle of its up vector to rest
			local peak, lo, hi = 0, huge, -huge
			local crossings, lastSign = 0, 0
			local radius0 = (beam.Position - hinge).Magnitude
			local radiusDrift = 0
			local steps = math.floor(period * 3 * 30)
			local restUp = Vector3.new(0, 1, 0)
			for _ = 1, steps do
				advance(1 / 30)
				local up = beam.CFrame.UpVector
				local angle = math.deg(math.acos(max(-1, min(1, up:Dot(restUp)))))
				-- signed: which side of the rest position along the swing direction
				local side = up:Cross(restUp):Dot(axis)
				local signed = side >= 0 and angle or -angle
				peak = max(peak, angle)
				lo, hi = min(lo, signed), max(hi, signed)
				local sign = signed > 1 and 1 or (signed < -1 and -1 or 0)
				if sign ~= 0 and lastSign ~= 0 and sign ~= lastSign then
					crossings = crossings + 1
				end
				if sign ~= 0 then
					lastSign = sign
				end
				radiusDrift = max(radiusDrift, abs((beam.Position - hinge).Magnitude - radius0))
			end
			T.check(abs(peak - arc) <= max(3, arc * 0.08), "the Pendulum swings +- Arc degrees (" .. fmt(arc, 0) .. ")", "peak " .. fmt(peak, 1))
			T.check(lo < -arc * 0.7 and hi > arc * 0.7, "...to BOTH sides of the rest position", fmt(lo, 1) .. " .. " .. fmt(hi, 1))
			T.check(abs(crossings - 6) <= 1, "...with Period seconds per full swing (about 6 rest crossings in 3 periods)", crossings .. " crossings, Period " .. fmt(period, 2))
			T.check(radiusDrift < 0.05, "...pivoting about the hinge (the beam keeps its distance to it)", "drift " .. fmt(radiusDrift, 3))
			local mark = logSize()
			Mock.Teleport(a, beam.Position)
			advance(0.9)
			local hits = dmgEntries("Pendulum", mark)
			T.check(#hits >= 1 and hits[1].args[1] == dmg, "touching a Pendulum beam deals its Damage as 'Pendulum'", #hits .. " hits, first " .. (hits[1] and tostring(hits[1].args[1]) or "-") .. " expected " .. dmg)
			away()
			reset()
			active = false
			mark = logSize()
			local c1 = beam.CFrame
			Mock.Teleport(a, beam.Position)
			advance(1.0)
			T.eq(#dmgEntries("Pendulum", mark), 0, "a paused Pendulum does not hurt")
			T.check((beam.CFrame.Position - c1.Position).Magnitude < 0.05, "...and does not move")
			active = true
			away()
			reset()
		end
	else
		T.fail("hazards: no Pendulum in the sampled courses")
	end

	-- WindGust ----------------------------------------------------------------------------------------------------------------
	local winds = all(Config.Tags.WindGust)
	if #winds > 0 then
		local wind = winds[1]
		local force = wind:GetAttribute("Force") or 18
		local dir = wind:GetAttribute("Direction") or Vector3.new(1, 0, 0)
		local interval = wind:GetAttribute("Interval") or 5
		local warning = wind:GetAttribute("Warning") or 1.5
		T.check(wind.CanCollide == false, "the WindGust volume is not solid")
		local streakParts = {}
		for _, d in ipairs(holder:GetDescendants()) do
			if d.Name == "WindStreak" and d:IsA("BasePart") then
				streakParts[#streakParts + 1] = d
			end
		end
		T.check(#streakParts > 0, "WindGust prepares streak parts for its warning", #streakParts .. " streak parts")
		Mock.Teleport(a, wind.Position)
		local mark = logSize()
		local sawStreak, sawForce, forceVec, firstForceAt, forceGoneAt = false, false, nil, nil, nil
		local streakBeforeForce = false
		local start = Mock.Clock.now
		local deadline = start + interval * 2 + warning + 4
		while Mock.Clock.now < deadline do
			advance(0.05)
			for _, d in ipairs(streakParts) do
				if d.Transparency < 0.95 then
					sawStreak = true
					streakBeforeForce = streakBeforeForce or not sawForce
					break
				end
			end
			local vf = root():FindFirstChildOfClass("VectorForce")
			if vf and vf.Force.Magnitude > 0.001 then
				if not sawForce then
					sawForce, firstForceAt = true, Mock.Clock.now
				end
				forceVec = vf.Force
			elseif sawForce and not forceGoneAt then
				forceGoneAt = Mock.Clock.now
			end
			if forceGoneAt and Mock.Clock.now - forceGoneAt > 0.5 then
				break
			end
			DS().SetHealthFraction(a, 1)
		end
		T.check(sawStreak and streakBeforeForce, "a WindGust shows streaks before it blows (the warning)")
		T.check(sawForce, "a player inside the volume gets pushed (a VectorForce on the root) once the gust blows", "no force within " .. fmt(interval * 2 + warning + 4) .. " s")
		if sawForce and forceVec then
			local unit = forceVec.Unit
			T.check(unit.X * dir.X + unit.Z * dir.Z > 0.99 and abs(unit.Y) < 0.01, "...horizontally along the gust Direction", tostring(forceVec))
		end
		T.check(forceGoneAt ~= nil and (forceGoneAt - (firstForceAt or 0)) <= 4, "...and the push ends again after the gust (~1.5 s)", forceGoneAt and fmt(forceGoneAt - (firstForceAt or 0), 2) or "never ended")
		T.eq(#remotesFor("DamageTaken", a.UserId, mark), 0, "wind deals no damage (no DamageTaken message at all)")
		-- a player already moving at the gust speed gains nothing more (the speed cap)
		away()
		advance(0.5)
		Mock.Teleport(a, wind.Position)
		local capped, pushedLater = false, false
		local deadline2 = Mock.Clock.now + interval * 2 + warning + 4
		while Mock.Clock.now < deadline2 and not capped do
			advance(0.05)
			local vf = root():FindFirstChildOfClass("VectorForce")
			if vf and vf.Force.Magnitude > 0.001 then
				pushedLater = true
				root().AssemblyLinearVelocity = Vector3.new(dir.X, 0, dir.Z).Unit * (force * 1.3)
				advance(0.12)
				local vf2 = root():FindFirstChildOfClass("VectorForce")
				capped = (not vf2) or vf2.Force.Magnitude < 0.5
			end
			DS().SetHealthFraction(a, 1)
		end
		T.check(pushedLater, "the gust pushes again on its next cycle")
		T.check(capped, "...and stops pushing a player who is already faster than the gust (speed gain is capped)")
		-- leaving the volume ends the push
		away()
		advance(0.4)
		T.check(root():FindFirstChildOfClass("VectorForce") == nil or root():FindFirstChildOfClass("VectorForce").Force.Magnitude < 0.001, "leaving the volume removes the push")
		root().AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		reset()
	else
		T.fail("hazards: no WindGust in the sampled courses")
	end

	-- CloudCannon -------------------------------------------------------------------------------------------------------------
	local cannons = all(Config.Tags.CloudCannon)
	if #cannons > 0 then
		local pad = cannons[1]
		local target, flight = pad:GetAttribute("Target"), pad:GetAttribute("FlightTime")
		if T.check(typeof(target) == "Vector3" and type(flight) == "number", "CloudCannon pads carry Target and FlightTime") then
			local g = workspace.Gravity
			local base = pad.Size
			local standing = pad.Position + Vector3.new(0, halfHeight(pad) + 2.9, 0)
			root().AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			K.waitNotInvulnerable(a)
			Mock.Teleport(a, standing)
			local t0 = Mock.Clock.now
			local squashed = false
			local launchedAfter
			while Mock.Clock.now - t0 < 2.0 do
				advance(0.03)
				if pad.Size.Y < base.Y - 0.01 then
					squashed = true
				end
				if root().AssemblyLinearVelocity.Magnitude > 5 then
					launchedAfter = Mock.Clock.now - t0
					break
				end
			end
			T.check(launchedAfter ~= nil, "touching the pad launches the rider", "no launch within 2 s")
			T.check(launchedAfter ~= nil and launchedAfter >= 0.3 and launchedAfter <= 0.9, "...after a short charge (about 0.35 s)", launchedAfter and fmt(launchedAfter, 2) .. " s" or "-")
			T.check(squashed, "...the pad squashes while it charges", "height stayed " .. fmt(base.Y, 2))
			local v = root().AssemblyLinearVelocity
			local p = root().Position
			local expected = (target - p) / flight + Vector3.new(0, g * flight / 2, 0)
			T.check((v - expected).Magnitude < 1.0 or (v.Magnitude >= 169 and (v.Unit - expected.Unit).Magnitude < 0.01), "the launch velocity is v = (Target - p) / t + (0, g t / 2, 0)", "got " .. tostring(v) .. ", expected " .. tostring(expected))
			-- integrate the flight from the launch point: the root must pass through the Target at t = FlightTime
			local steps = math.floor(flight * 240 + 0.5)
			local dt = flight / steps
			local x, y, z, vy = p.X, p.Y, p.Z, v.Y
			for _ = 1, steps do
				x, y, z = x + v.X * dt, y + vy * dt - 0.5 * g * dt * dt, z + v.Z * dt
				vy = vy - g * dt
			end
			local miss = (Vector3.new(x, y, z) - target).Magnitude
			T.check(miss < 0.5, "...so the rider lands on the Target (" .. fmt(miss, 3) .. " studs off)")
			T.check(DS().IsInvulnerable(a), "the rider is protected from damage while flying")
			T.check(v.Magnitude <= 171, "the launch speed stays within the safe limit (170)", fmt(v.Magnitude))
			-- a second touch inside the re-arm time does nothing (the mock keeps the rider on the pad, so a new
			-- launch would show up as a non-zero velocity again)
			root().AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			Mock.Touch(pad, root())
			advance(0.7)
			T.check(root().AssemblyLinearVelocity.Magnitude < 1, "a player who was just launched is not launched again within a second")
			T.check(abs(pad.Size.Y - base.Y) < 0.05 and abs(pad.Size.X - base.X) < 0.05, "the pad springs back to its size after the shot", "height " .. fmt(pad.Size.Y, 2) .. " vs " .. fmt(base.Y, 2))
			away()
			advance(flight + 1.2)
			T.check(not DS().IsInvulnerable(a), "the flight protection ends shortly after the landing", "still invulnerable")
			-- someone who jumps off during the charge is left alone
			advance(1.2)
			Mock.Teleport(a, standing)
			advance(0.15)
			away()
			root().AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			advance(0.6)
			T.check(root().AssemblyLinearVelocity.Magnitude < 1, "a player who leaves the pad during the charge is not launched")
			-- paused: no launch
			active = false
			Mock.Teleport(a, standing)
			advance(0.9)
			T.check(root().AssemblyLinearVelocity.Magnitude < 1, "a paused cannon does not fire")
			active = true
			away()
		end
	else
		T.fail("hazards: no CloudCannon in the sampled courses")
	end

	-- Golden tokens -----------------------------------------------------------------------------------------------------------------
	do
		local tokenFolder = Instance.new("Folder")
		tokenFolder.Name = "SmokeGolden"
		tokenFolder.Parent = workspace
		local regular = TS.MakeTokenPart(Vector3.new(-3000, 3000, 100), tokenFolder, 1)
		local golden = TS.MakeTokenPart(Vector3.new(-3000, 3000, 160), tokenFolder, Config.Tokens.GoldenValue)
		T.check(regular:HasTag(Config.Tags.CloudToken) and not regular:HasTag(Config.Tags.GoldenToken) and regular:GetAttribute("Value") == 1, "a normal token is tagged CloudToken only, Value 1")
		T.check(golden:HasTag(Config.Tags.CloudToken) and golden:HasTag(Config.Tags.GoldenToken) and golden:GetAttribute("Value") == Config.Tokens.GoldenValue, "a golden token is tagged GoldenToken + CloudToken with Value = GoldenValue")
		local function bigness(part)
			return max(part.Size.X, part.Size.Y, part.Size.Z)
		end
		T.check(bigness(golden) >= bigness(regular) * 1.4, "golden tokens are 1.5x bigger", fmt(bigness(golden), 2) .. " vs " .. fmt(bigness(regular), 2))
		T.check(golden.Color ~= regular.Color, "...and look different")

		-- Animation: with Config.Tokens.ClientAnimated (the shipping setting) the SERVER never poses a coin, because every
		-- pose would replicate to every client; TokenFx spins/bobs them locally (scenario client_tokens). With the flag
		-- off the old server driver poses the coins next to a player. Both coins sit within the driver's 65 stud range of
		-- the player here, so a driver that is running cannot miss them.
		do
			local function snapshot(token)
				local out = { [token] = token.CFrame }
				for _, d in ipairs(token:GetDescendants()) do
					if d:IsA("BasePart") then
						out[d] = d.CFrame
					end
				end
				return out
			end
			local function moved(snap)
				local n = 0
				for part, cf in pairs(snap) do
					if part.CFrame ~= cf then
						n = n + 1
					end
				end
				return n
			end
			local near = regular.Position + Vector3.new(12, 0, 0)
			Mock.Teleport(a, near)
			advance(0.6)
			local snapRegular, snapGolden = snapshot(regular), snapshot(golden)
			for _ = 1, 10 do
				Mock.Teleport(a, near)
				advance(0.25)
			end
			local rootPos = root().Position
			T.check((rootPos - regular.Position).Magnitude < 40 and (rootPos - golden.Position).Magnitude < 65,
				"token animation test: the player stands within the driver's range of both coins", fmt((rootPos - regular.Position).Magnitude, 1) .. " / " .. fmt((rootPos - golden.Position).Magnitude, 1) .. " studs")
			if Config.Tokens.ClientAnimated == true then
				T.eq(moved(snapRegular) + moved(snapGolden), 0, "Config.Tokens.ClientAnimated: TokenService does not animate (coins next to a player stay exactly as built after 2.5 s)")
			else
				T.check(moved(snapRegular) > 0 and moved(snapGolden) > 0, "Config.Tokens.ClientAnimated is false: TokenService's server driver spins and bobs the coins next to a player")
			end
			-- TokenFx takes the yaw the server built a coin with as its phase: coins must not all start alike
			local yaws, distinct, extra = {}, 0, {}
			for i = 1, 8 do
				local t = TS.MakeTokenPart(Vector3.new(-3000 + i * 6, 3000, 300), tokenFolder, 1)
				extra[#extra + 1] = t
				local _, yaw = t.CFrame:ToEulerAnglesYXZ()
				local key = string.format("%.3f", yaw)
				if not yaws[key] then
					yaws[key] = true
					distinct = distinct + 1
				end
			end
			T.check(distinct >= 6, "MakeTokenPart gives each coin its own random starting yaw (TokenFx uses it as the spin/bob phase)", distinct .. " distinct yaws of 8")
			for _, t in ipairs(extra) do
				t:Destroy()
			end
			away()
		end
		local collected = {}
		local stop = TS.Watch(tokenFolder, { AddTokens = function(player, n)
			collected[#collected + 1] = { player, n }
		end })
		Mock.Teleport(a, golden.Position)
		advance(0.8)
		T.check(#collected == 1 and collected[1][2] == Config.Tokens.GoldenValue, "collecting a golden token pays GoldenValue (" .. Config.Tokens.GoldenValue .. ")", #collected .. " pickups")
		T.check(golden.Parent == nil, "...and removes it")
		Mock.Teleport(a, regular.Position)
		advance(0.8)
		T.check(#collected == 2 and collected[2][2] == 1, "collecting a normal token pays 1")
		stop()
		tokenFolder:Destroy()
		away()
	end

	-- stop: nothing keeps running -----------------------------------------------------------------------------------------------------
	for _, stop in ipairs(stops) do
		stop()
	end
	advance(0.3)
	local statsAfterStop = Mock.Stats()
	local bar = bars[1]
	local c2 = bar and bar.CFrame
	local beam2 = beams[1]
	local mark = logSize()
	if bar then
		Mock.Teleport(a, bar.Position)
	end
	advance(1.0)
	if bar then
		T.check(bar.CFrame == c2, "after stopFn() SpinBars no longer turn")
		T.eq(#dmgEntries("SpinBar", mark), 0, "after stopFn() hazards no longer hurt")
	end
	if beam2 then
		local restAngle = math.deg(math.acos(max(-1, min(1, beam2.CFrame.UpVector:Dot(Vector3.new(0, 1, 0))))))
		T.check(restAngle < 0.5, "after stopFn() a Pendulum is back at rest, hanging straight down", fmt(restAngle, 2) .. " degrees off")
		advance(0.5)
		local still = math.deg(math.acos(max(-1, min(1, beam2.CFrame.UpVector:Dot(Vector3.new(0, 1, 0))))))
		T.check(still < 0.5, "...and stays there", fmt(still, 2) .. " degrees off")
	end
	local leftoverForces = 0
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("VectorForce") then
			leftoverForces = leftoverForces + 1
		end
	end
	T.eq(leftoverForces, 0, "after stopFn() no wind VectorForce is left anywhere")
	T.check(statsAfterStop.connections["RunService.Heartbeat"] == baseStats.connections["RunService.Heartbeat"], "stopFn() disconnects the Heartbeat drivers", tostring(statsAfterStop.connections["RunService.Heartbeat"]) .. " vs " .. tostring(baseStats.connections["RunService.Heartbeat"]))
	for _, stop in ipairs(stops) do
		pcall(stop) -- idempotent
	end
	away()
	advance(6)
	if W.runtimeParts then
		local left = 0
		for _, d in ipairs(holder:GetDescendants()) do
			if d:IsA("BasePart") and not afterAttach[d] then
				left = left + 1
			end
		end
		T.check(left <= 2, "after stopFn() no lightning bolts / discs / streaks linger", left .. " temporary parts after 6 s")
		W.runtimeParts = nil
	end
	holder:Destroy()
	advance(10)
	local final = Mock.Stats()
	T.check(final.pendingTasks <= baseStats.pendingTasks + 1, "hazard threads end after stopFn + Destroy", "pending " .. final.pendingTasks .. " vs " .. baseStats.pendingTasks)
	removePlayers(players)
	flushErrors("hazards")
	flushWarnings("hazards")
end)

return S
