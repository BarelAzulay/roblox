-- HazardService: brings the tagged parts of a sky course to life and applies damage through
-- DamageService. One Attach() call per match; the returned stopFn tears everything down.
-- Plain Lua 5.1-compatible syntax only.
--
-- Behaviours (see Config.Tags):
--   v1: SpinBar, StormCloud, LightningZone, VanishCloud, MovingCloud, BouncePad,
--       PressurePlate + PlateBridge
--   v2: Pendulum (swinging beam), WindGust (periodic sideways push), CloudCannon (ballistic launch)
-- Every parameter is read from attributes with a sane default, so a part with a missing attribute
-- still behaves.
--
-- Structure: Attach() builds a per-match "context" table. All per-frame work (spinning bars,
-- pendulums, moving clouds, wind streaks, storm / plate / wind ticks) runs from ONE shared Heartbeat
-- connection owned by that context. Timed sequences (lightning, wind gusts, vanishing clouds, cannon
-- charge-ups) run in their own task threads that check ctx.stopped after every wait. Everything
-- created at runtime lives inside the container, except the WindGust force constraints, which have
-- to sit on the players' characters and are removed again by stopFn / when the gust ends.
--
-- Visual rule: warning discs, bolts, rain and puffs use the calm palette below (Theme.World when it
-- exists). Nothing here is pure white or full-saturation neon, and lightning flashes are brief.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local DamageService = require(script.Parent.DamageService)

-- Theme is only used for its in-world palette; a broken UI kit must never take the hazards down.
local themeOk, Theme = pcall(require, Shared.Theme)
if not themeOk or type(Theme) ~= "table" then
	Theme = {}
end

local HazardService = {}

local TAGS = Config.Tags
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local TWO_PI = math.pi * 2

----------------------------------------------------------------------
-- Tunables (anything a designer might want to tweak lives here)
----------------------------------------------------------------------
local STORM_TICK = 0.25 -- seconds between storm damage ticks (4 Hz)
local PLATE_TICK = 0.2 -- seconds between pressure-plate polls (5 Hz)
local HIT_TICK = 0.08 -- backup overlap poll for moving damage bars (12 Hz)
local WIND_TICK = 1 / 15 -- how often wind forces are re-evaluated
local PLATE_RETRACT_DELAY = 1.0 -- bridge stays up this long after the last player leaves
local PLATE_FADE_IN = 0.2
local PLATE_FADE_OUT = 0.45
local PLATE_PRESS_DEPTH = 0.18 -- how far a plate sinks when stood on
local HITTER_DEBOUNCE = 0.35 -- per player, per bar (DamageService i-frames do the rest)
local HITTER_MARGIN = 0.3 -- studs the overlap poll grows a bar by
local HITTER_NEAR_MARGIN = 10 -- bars with no player this close (beyond their own radius) are not polled
local SPINBAR_KNOCKBACK = 55
local PENDULUM_KNOCKBACK = 55
local BOUNCE_DEBOUNCE = 0.3
local LIGHTNING_KNOCKBACK = 40
local BOLT_HEIGHT = 90
local BOLT_SEGMENTS = 8

-- WindGust
local WIND_BLOW_TIME = 1.5 -- default seconds the push lasts after the warning (optional Duration attribute)
local WIND_RAMP_IN = 0.3 -- push strength fades in over this long ...
local WIND_RAMP_OUT = 0.4 -- ... and out over this long
local WIND_MAX_FORCE = 40 -- hard cap on the Force attribute (studs/s)
local WIND_MAX_ACCEL = 480 -- studs/s^2; has to beat the Humanoid's ground controller to shove a standing player
local WIND_GAIN = 18 -- 1/s: acceleration = (ceiling - speed along wind) * gain, then clamped
local WIND_STREAKS = 10 -- pooled streak parts per gust volume
local WIND_WARN_STREAKS = 4 -- how many of them show during the warning

-- CloudCannon
local CANNON_CHARGE = 0.35 -- squash + puff before the launch
local CANNON_REARM = 1.0 -- a player cannot be launched twice within this many seconds
local CANNON_STAND_SLACK = 5 -- still counts as "on the pad" this far beyond its edge
local CANNON_LANDING_GRACE = 0.8 -- extra protection after FlightTime for the touchdown
local CANNON_MAX_SPEED = 260 -- sanity cap for a broken Target / FlightTime
local CANNON_DEFAULT_FLIGHT = 1.6
local CANNON_MAX_LATENCY = 0.3 -- seconds of lag the launch compensates for at most

----------------------------------------------------------------------
-- Palette: calm, readable colours (Theme.World when present, local fallbacks otherwise)
----------------------------------------------------------------------
local WORLD = Theme.World or {}

local function colorOr(value, fallback)
	if typeof(value) == "Color3" then
		return value
	end
	return fallback
end

-- Pulls a colour away from full saturation / full brightness (hazard glows must stay calm).
local function calm(color)
	local ok, h, s, v = pcall(function()
		return color:ToHSV()
	end)
	if not ok then
		return color
	end
	return Color3.fromHSV(h, math.min(s, 0.72), math.min(v, 0.86))
end

local PAL = {}
PAL.Warn = calm(colorOr(WORLD.HazardGlow, Color3.fromRGB(204, 84, 100)))
PAL.WarnFill = PAL.Warn:Lerp(Color3.fromRGB(236, 170, 160), 0.3)
PAL.BoltCore = Color3.fromRGB(210, 222, 244) -- soft blue-white, never pure white
PAL.BoltGlow = Color3.fromRGB(118, 110, 204)
PAL.RainTop = Color3.fromRGB(152, 174, 210)
PAL.RainBottom = Color3.fromRGB(104, 136, 188)
PAL.Sparkle = Color3.fromRGB(228, 214, 164)
PAL.PuffLight = Color3.fromRGB(206, 218, 238)
PAL.PuffDark = Color3.fromRGB(150, 168, 200)
PAL.Wind = Color3.fromRGB(190, 208, 232)
PAL.WindDrift = Color3.fromRGB(170, 190, 220)
PAL.PlateGlow = Color3.fromRGB(220, 228, 244)

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local warned = {}

-- Run fn(...) in a pcall; the first failure per name is reported, never spammed per frame.
local function guarded(name, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and not warned[name] then
		warned[name] = true
		warn("[HazardService] " .. name .. " failed: " .. tostring(err))
	end
end

local function attrNumber(inst, name, default)
	local value = inst:GetAttribute(name)
	if type(value) == "number" and value == value then
		return value
	end
	return default
end

local function attrVector3(inst, name, default)
	local value = inst:GetAttribute(name)
	if typeof(value) == "Vector3" then
		return value
	end
	return default
end

local function attrString(inst, name, default)
	local value = inst:GetAttribute(name)
	if value == nil then
		return default
	end
	return tostring(value)
end

-- Horizontal unit vector of `v` (Y dropped), or `fallback` when v is (nearly) vertical / nil.
local function flatUnit(v, fallback)
	if typeof(v) == "Vector3" then
		local flat = Vector3.new(v.X, 0, v.Z)
		if flat.Magnitude > 0.01 then
			return flat.Unit
		end
	end
	return fallback
end

-- Create an anchored, non-interactive effect part. Parent is applied last.
local function makePart(props)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	local parent = nil
	for key, value in pairs(props) do
		if key == "Parent" then
			parent = value
		else
			part[key] = value
		end
	end
	part.Parent = parent
	return part
end

local function newEmitter(props)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARKLE_TEXTURE
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	for key, value in pairs(props) do
		emitter[key] = value
	end
	return emitter
end

-- Soft smoke puff emitter (cannon poof, wind drift). Rate 0: fire it with :Emit() or set Rate.
local function newPuffEmitter(props)
	local emitter = newEmitter({
		Texture = SMOKE_TEXTURE,
		Rate = 0,
		Color = ColorSequence.new(PAL.PuffLight, PAL.PuffDark),
		LightEmission = 0.05,
		LightInfluence = 0.8,
		Lifetime = NumberRange.new(0.5, 0.9),
		Speed = NumberRange.new(8, 16),
		EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(50, 50),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-80, 80),
		Drag = 2,
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.2),
			NumberSequenceKeypoint.new(1, 4.5),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(0.6, 0.65),
			NumberSequenceKeypoint.new(1, 1),
		}),
	})
	if props then
		for key, value in pairs(props) do
			emitter[key] = value
		end
	end
	return emitter
end

-- Root part + humanoid of a player that is currently alive, or nil.
local function getLivingRoot(player)
	local char = player and player.Character
	if not char then
		return nil
	end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if humanoid and root and humanoid.Health > 0 then
		return root, humanoid
	end
	return nil
end

-- Touched part -> (player, root) for a living player character, else nil.
local function playerFromHit(hit)
	local player = Util.PlayerFromPart(hit)
	if not player then
		return nil
	end
	local root = getLivingRoot(player)
	if not root then
		return nil
	end
	return player, root
end

local function isDowned(player)
	return player:GetAttribute(Config.Attr.Downed) == true
end

-- Axis-aligned world-space extents (full sizes) of a possibly rotated part.
local function worldExtents(part)
	local cf = part.CFrame
	local s = part.Size
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	return Vector3.new(
		math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z,
		math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z,
		math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z
	)
end

-- Half-extent of the part's (oriented) box measured along the world unit vector `dir`.
local function halfExtentAlong(part, dir)
	local cf = part.CFrame
	local s = part.Size
	return 0.5 * (math.abs(dir:Dot(cf.RightVector)) * s.X
		+ math.abs(dir:Dot(cf.UpVector)) * s.Y
		+ math.abs(dir:Dot(cf.LookVector)) * s.Z)
end

-- A "fade set" is a part plus every BasePart (and particle emitter) parented under it, with the
-- original look remembered so it can be faded out and restored exactly.
local function collectFadeSet(root)
	local set = { parts = {}, emitters = {} }
	local function addPart(part, isRoot)
		local transparency = part.Transparency
		local canCollide = part.CanCollide
		if isRoot then
			canCollide = true -- the tagged walkable part is always solid when shown
			if transparency > 0.95 then
				transparency = 0 -- authored invisible: show it as a solid cloud instead
			end
		end
		table.insert(set.parts, { part = part, transparency = transparency, canCollide = canCollide })
	end
	addPart(root, true)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			if not CollectionService:HasTag(d, TAGS.CloudToken) then
				addPart(d, false)
			end
		elseif d:IsA("ParticleEmitter") then
			table.insert(set.emitters, { emitter = d, enabled = d.Enabled })
		end
	end
	return set
end

-- factor 0 = original look, 1 = invisible. seconds 0 = instant.
local function fadeSet(set, factor, seconds)
	for _, e in ipairs(set.parts) do
		local goal = e.transparency + (1 - e.transparency) * factor
		if seconds > 0 then
			Util.Tween(e.part, seconds, { Transparency = goal }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		else
			e.part.Transparency = goal
		end
	end
	for _, e in ipairs(set.emitters) do
		if factor >= 1 then
			e.emitter.Enabled = false
		else
			e.emitter.Enabled = e.enabled
		end
	end
end

local function collideSet(set, solid)
	for _, e in ipairs(set.parts) do
		if solid then
			e.part.CanCollide = e.canCollide
		else
			e.part.CanCollide = false
		end
	end
end

----------------------------------------------------------------------
-- Context helpers (one context per Attach call)
----------------------------------------------------------------------
local function newContext(container, matchHandle)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.MaxParts = 128
	return {
		container = container,
		matchHandle = matchHandle,
		stopped = false,
		clock = 0, -- animation clock: advances only while the match is active
		rng = Random.new(),
		overlap = overlap,
		heartbeat = nil,
		connections = {}, -- RBXScriptConnections to disconnect on stop
		cleanups = {}, -- functions to run on stop
		permanents = {}, -- instances HazardService added for the whole match (destroyed on stop)
		temps = {}, -- short-lived effect parts: part -> true
		spinBars = {},
		pendulums = {},
		hitters = {}, -- every moving damage bar (spin bars + pendulums), for the overlap backup poll
		movers = {},
		moversMoving = false,
		storms = {},
		winds = {},
		launchedAt = {}, -- player -> os.clock() of their last cannon launch
		groups = {}, -- BridgeId -> group
		groupList = {},
		stormAcc = 0,
		plateAcc = 0,
		hitAcc = 0,
		windAcc = 0,
	}
end

-- True while hazards should run. A missing/broken matchHandle never freezes the course.
local function isActive(ctx)
	local handle = ctx.matchHandle
	if handle and type(handle.IsActive) == "function" then
		local ok, result = pcall(handle.IsActive)
		if ok then
			return result and true or false
		end
	end
	return true
end

local function connect(ctx, signal, fn)
	local conn = signal:Connect(fn)
	table.insert(ctx.connections, conn)
	return conn
end

local function onStop(ctx, fn)
	table.insert(ctx.cleanups, fn)
end

-- Parent a transient effect part under the container and auto-destroy it after `lifetime`.
local function addTemp(ctx, part, lifetime)
	if ctx.stopped then
		part:Destroy()
		return part
	end
	part.Parent = ctx.container
	ctx.temps[part] = true
	task.delay(lifetime, function()
		ctx.temps[part] = nil
		part:Destroy()
	end)
	return part
end

local function removeTemp(ctx, part)
	ctx.temps[part] = nil
	part:Destroy()
end

-- Apply damage through DamageService (only while active). Returns true if damage landed.
local function hurt(ctx, player, amount, kind, opts)
	if ctx.stopped or not isActive(ctx) then
		return false
	end
	if not player or player.Parent == nil or isDowned(player) then
		return false
	end
	local ok, applied = pcall(DamageService.Damage, player, amount, kind, opts)
	if not ok then
		if not warned.Damage then
			warned.Damage = true
			warn("[HazardService] DamageService.Damage failed: " .. tostring(applied))
		end
		return false
	end
	return applied == true
end

-- All living players with any body part overlapping the (possibly rotated) box.
local function playersInBox(ctx, cf, size)
	local found = {}
	local characters = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(characters, player.Character)
		end
	end
	if #characters == 0 then
		return found
	end
	ctx.overlap.FilterDescendantsInstances = characters
	local parts = Workspace:GetPartBoundsInBox(cf, size, ctx.overlap)
	local seen = {}
	for _, part in ipairs(parts) do
		local player = Util.PlayerFromPart(part)
		if player and not seen[player] then
			seen[player] = true
			if getLivingRoot(player) then
				table.insert(found, player)
			end
		end
	end
	return found
end

-- Wait `seconds` of ACTIVE time (the timer holds while the match is paused).
-- Returns false if the context was stopped meanwhile.
local function waitActive(ctx, seconds)
	local waited = 0
	while waited < seconds do
		if ctx.stopped then
			return false
		end
		local step = math.min(0.1, seconds - waited)
		local dt = task.wait(step)
		if ctx.stopped then
			return false
		end
		if isActive(ctx) then
			waited = waited + (dt or step)
		end
	end
	return not ctx.stopped
end

-- Block until the match is active. Returns false if stopped.
local function awaitActive(ctx)
	while not ctx.stopped and not isActive(ctx) do
		task.wait(0.1)
	end
	return not ctx.stopped
end

-- Wait `seconds` of real time. Returns false if stopped.
local function sleep(ctx, seconds)
	local waited = 0
	while waited < seconds do
		if ctx.stopped then
			return false
		end
		local step = math.min(0.1, seconds - waited)
		local dt = task.wait(step)
		waited = waited + (dt or step)
	end
	return not ctx.stopped
end

----------------------------------------------------------------------
-- Moving damage bars (SpinBar + Pendulum share one hit routine)
--   A hit comes from the part's Touched signal OR from the 12 Hz overlap poll below: an anchored
--   part that is swept through a character by CFrame occasionally misses a Touched event.
----------------------------------------------------------------------
local function registerHit(ctx, hitter, player)
	if ctx.stopped or not isActive(ctx) then
		return
	end
	local now = os.clock()
	local last = hitter.lastHit[player]
	if last and now - last < HITTER_DEBOUNCE then
		return
	end
	hitter.lastHit[player] = now
	hurt(ctx, player, hitter.damage, hitter.kind, {
		KnockbackFrom = hitter.part.Position,
		Knockback = hitter.knockback,
	})
end

local function pollHitters(ctx)
	-- Cheap early-out: collect the living roots once, then only run the (relatively expensive) box
	-- query for bars that have a player within reach.
	local roots = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local root = getLivingRoot(player)
		if root then
			table.insert(roots, root.Position)
		end
	end
	if #roots == 0 then
		return
	end
	for _, hitter in ipairs(ctx.hitters) do
		local part = hitter.part
		if part.Parent then
			local reach = part.Size.Magnitude / 2 + HITTER_NEAR_MARGIN
			local reach2 = reach * reach
			local near = false
			local centre = part.Position
			for _, position in ipairs(roots) do
				local d = position - centre
				if d:Dot(d) <= reach2 then
					near = true
					break
				end
			end
			if near then
				local size = part.Size + Vector3.new(HITTER_MARGIN, HITTER_MARGIN, HITTER_MARGIN)
				for _, player in ipairs(playersInBox(ctx, part.CFrame, size)) do
					registerHit(ctx, hitter, player)
				end
			end
		end
	end
end

----------------------------------------------------------------------
-- Per-frame / per-tick work (all driven by the one shared Heartbeat)
----------------------------------------------------------------------
local function updateSpinBars(ctx)
	local t = ctx.clock
	for _, bar in ipairs(ctx.spinBars) do
		local part = bar.part
		if part.Parent then
			-- Always derived from the base CFrame so rotation never accumulates error.
			part.CFrame = bar.base * CFrame.Angles(0, bar.phase + bar.speed * t, 0)
		end
	end
end

-- Pendulum swing: the beam (and anything anchored under it) is rotated about the world pivot
-- `Hinge` around the world axis `Axis`, always from the remembered base CFrame.
local function updatePendulums(ctx)
	local t = ctx.clock
	for _, p in ipairs(ctx.pendulums) do
		local part = p.part
		if part.Parent then
			local angle = p.arc * math.sin(TWO_PI * t / p.period + p.phase)
			local transform = p.pivot * CFrame.fromAxisAngle(p.axis, angle) * p.pivotInverse
			part.CFrame = transform * p.base
			for _, f in ipairs(p.followers) do
				if f.part.Parent then
					f.part.CFrame = transform * f.base
				end
			end
		end
	end
end

-- MovingCloud motion.
--
-- How standing players are carried: an Anchored part moved by CFrame has no physics velocity, so
-- Humanoids standing on it would simply be left behind. Pushing the player's HumanoidRootPart
-- from the SERVER every frame is not an option either: the character is simulated by its owning
-- client, so the server would keep writing a stale (latency-old) position back and the player
-- would rubber-band whenever they walk. Instead each frame we do two things to the anchored
-- cloud: (1) move it along its sine path with CFrame, and (2) publish the exact analytic
-- velocity of that path in AssemblyLinearVelocity. An anchored part's velocity is treated by the
-- engine as a moving surface (the same trick conveyor belts use), so Humanoids standing on the
-- cloud are carried along smoothly by their own client physics, with no teleporting involved.
-- Welded decor (CourseBuilder welds it to the cloud) follows the root automatically.
local function updateMovers(ctx)
	local t = ctx.clock
	for _, m in ipairs(ctx.movers) do
		local part = m.part
		if part.Parent then
			-- u runs 0..2; 0..1 is the trip out, 1..2 the trip back (one leg takes `period` s).
			local u = (t / m.period + m.phase) % 2
			local direction = 1
			if u > 1 then
				u = 2 - u
				direction = -1
			end
			local eased = 0.5 - 0.5 * math.cos(math.pi * u) -- Sine in/out
			local rate = 0.5 * math.pi * math.sin(math.pi * u) / m.period * direction
			part.CFrame = m.base + m.offset * eased
			part.AssemblyLinearVelocity = m.offset * rate
		end
	end
	ctx.moversMoving = true
end

-- Stop publishing velocity (match paused/ended) so nothing keeps dragging players.
local function haltMovers(ctx)
	for _, m in ipairs(ctx.movers) do
		if m.part.Parent then
			m.part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		end
	end
	ctx.moversMoving = false
end

local function tickStorms(ctx, elapsed)
	for _, storm in ipairs(ctx.storms) do
		local part = storm.part
		if part.Parent then
			local victims = playersInBox(ctx, part.CFrame, part.Size)
			for _, player in ipairs(victims) do
				-- DPS / 4 per 0.25 s tick; i-frames are ignored so the drizzle is steady.
				hurt(ctx, player, storm.dps * elapsed, "Storm", { IgnoreIFrames = true })
			end
		end
	end
end

local function setPlatePressed(plate, pressed)
	local part = plate.part
	if not part.Parent then
		return
	end
	plate.pressed = pressed
	if pressed then
		Util.Tween(part, 0.15, {
			CFrame = plate.baseCF - Vector3.new(0, PLATE_PRESS_DEPTH, 0),
			Color = plate.baseColor:Lerp(PAL.PlateGlow, 0.3),
		}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	else
		Util.Tween(part, 0.25, { CFrame = plate.baseCF, Color = plate.baseColor },
			Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end
end

local function setBridgeShown(group, shown)
	for _, bridge in ipairs(group.bridges) do
		if bridge.part.Parent then
			if shown then
				collideSet(bridge.set, true)
				fadeSet(bridge.set, 0, PLATE_FADE_IN)
			else
				-- Solid-ness goes first so nobody is left standing on a ghost.
				collideSet(bridge.set, false)
				fadeSet(bridge.set, 1, PLATE_FADE_OUT)
			end
		end
	end
end

-- Co-op rule: a bridge is solid only while at least one player stands on any plate sharing its
-- BridgeId; it retracts PLATE_RETRACT_DELAY seconds after the last player steps off.
local function tickPlates(ctx)
	local now = os.clock()
	for _, group in ipairs(ctx.groupList) do
		local occupied = false
		for _, plate in ipairs(group.plates) do
			local pressed = false
			if plate.part.Parent then
				pressed = #playersInBox(ctx, plate.boxCF, plate.boxSize) > 0
			end
			if pressed ~= plate.pressed then
				setPlatePressed(plate, pressed)
			end
			if pressed then
				occupied = true
			end
		end
		if occupied then
			group.emptySince = nil
			if not group.shown then
				group.shown = true
				setBridgeShown(group, true)
			end
		elseif group.shown then
			if not group.emptySince then
				group.emptySince = now
			end
			if now - group.emptySince >= PLATE_RETRACT_DELAY then
				group.shown = false
				group.emptySince = nil
				setBridgeShown(group, false)
			end
		end
	end
end

----------------------------------------------------------------------
-- WindGust runtime (per-frame streaks + 15 Hz push). Behaviour setup is further below.
----------------------------------------------------------------------
-- Wind push implementation note: the push is a horizontal VectorForce on the player's
-- HumanoidRootPart, not repeated AssemblyLinearVelocity writes. A character is simulated by its
-- owning client, so the server only ever reads a latency-old velocity; writing "old velocity +
-- push" back 15 times a second would also overwrite the vertical velocity with stale values (it
-- cancels jumps and makes falling floaty). A constraint is simulated by the owner itself, touches
-- X/Z only, and still obeys the contract: the speed gained along the wind is capped at `Force`
-- studs/s (the force switches off once the player is as fast as the gust).
local function releasePush(entry)
	if entry.force then
		pcall(function()
			entry.force:Destroy()
		end)
	end
	if entry.attachment then
		pcall(function()
			entry.attachment:Destroy()
		end)
	end
	entry.force = nil
	entry.attachment = nil
end

local function clearWindPushes(wind)
	for player, entry in pairs(wind.pushed) do
		releasePush(entry)
		wind.pushed[player] = nil
	end
end

local function setWindPhase(ctx, wind, phase)
	if ctx.stopped then
		return
	end
	wind.phase = phase
	wind.phaseClock = ctx.clock
	if wind.drift then
		if phase == "blow" then
			wind.drift.Rate = wind.blowRate
		elseif phase == "warning" then
			wind.drift.Rate = wind.warnRate
		else
			wind.drift.Rate = 0
		end
	end
end

-- Strength 0..1 of the current push (0 outside the blow phase).
local function windEnvelope(ctx, wind)
	if wind.phase ~= "blow" then
		return 0
	end
	local t = ctx.clock - wind.phaseClock
	local env = math.min(1, t / WIND_RAMP_IN, (wind.blow - t) / WIND_RAMP_OUT)
	if env < 0 then
		env = 0
	end
	return env
end

local function pushPlayer(wind, player, root, env)
	local entry = wind.pushed[player]
	if entry and (entry.root ~= root or not root.Parent or not entry.force or not entry.force.Parent) then
		releasePush(entry) -- respawned (or the constraint vanished): start over
		entry = nil
	end
	if not entry then
		local attachment = Instance.new("Attachment")
		attachment.Name = "NimbusWindAttachment"
		attachment.Parent = root
		local force = Instance.new("VectorForce")
		force.Name = "NimbusWindForce"
		force.Attachment0 = attachment
		force.ApplyAtCenterOfMass = true
		force.RelativeTo = Enum.ActuatorRelativeTo.World
		force.Force = Vector3.new(0, 0, 0)
		force.Parent = root
		entry = { root = root, attachment = attachment, force = force }
		wind.pushed[player] = entry
	end
	-- Speed already gained along the wind is capped at the (ramped) gust speed.
	local along = root.AssemblyLinearVelocity:Dot(wind.dir)
	local ceiling = wind.force * env
	local accel = Util.Clamp((ceiling - along) * WIND_GAIN, 0, WIND_MAX_ACCEL)
	entry.force.Force = wind.dir * (root.AssemblyMass * accel)
end

local function tickWind(ctx, wind)
	local env = windEnvelope(ctx, wind)
	if env <= 0 or not wind.part.Parent then
		clearWindPushes(wind)
		return
	end
	local inside = {}
	for _, player in ipairs(playersInBox(ctx, wind.part.CFrame, wind.part.Size)) do
		if not isDowned(player) then
			local root = getLivingRoot(player)
			if root then
				inside[player] = true
				pushPlayer(wind, player, root, env)
			end
		end
	end
	for player, entry in pairs(wind.pushed) do
		if not inside[player] then
			releasePush(entry)
			wind.pushed[player] = nil
		end
	end
end

local function tickWinds(ctx, active)
	for _, wind in ipairs(ctx.winds) do
		if active then
			tickWind(ctx, wind)
		else
			clearWindPushes(wind) -- paused: nobody keeps drifting
		end
	end
end

-- Start one streak: a thin soft line racing from the upwind face to the downwind face of the volume.
local function launchStreak(ctx, wind, slot)
	local rng = ctx.rng
	local part = wind.part
	local size = part.Size
	local localPoint = Vector3.new(
		(rng:NextNumber() - 0.5) * size.X,
		(rng:NextNumber() - 0.5) * size.Y,
		(rng:NextNumber() - 0.5) * size.Z
	)
	local point = part.CFrame:PointToWorldSpace(localPoint)
	local along = (point - wind.center):Dot(wind.dir)
	local lateral = point - wind.dir * along -- same spot, projected onto the centre plane
	slot.a = lateral - wind.dir * wind.halfLen
	slot.b = lateral + wind.dir * wind.halfLen
	local speed = math.max(30, wind.force * 2.4) * rng:NextNumber(0.85, 1.25)
	slot.life = Util.Clamp(wind.halfLen * 2 / speed, 0.35, 1.3)
	slot.age = 0
	slot.state = "fly"
	if wind.phase == "blow" then
		slot.minTransparency = 0.42
	else
		slot.minTransparency = 0.74 -- the warning is just a hint
	end
	local thickness = rng:NextNumber(0.1, 0.2)
	slot.part.Size = Vector3.new(thickness, thickness, rng:NextNumber(4, 8))
	wind.live = wind.live + 1
end

local function updateWindStreaks(ctx, dt)
	for _, wind in ipairs(ctx.winds) do
		if wind.phase ~= "idle" or wind.live > 0 then
			local limit = 0
			if wind.phase == "blow" then
				limit = #wind.streaks
			elseif wind.phase == "warning" then
				limit = WIND_WARN_STREAKS
			end
			for index, slot in ipairs(wind.streaks) do
				if slot.state == "idle" then
					if index <= limit then
						slot.delay = slot.delay - dt
						if slot.delay <= 0 then
							launchStreak(ctx, wind, slot)
						end
					end
				else
					slot.age = slot.age + dt
					local u = slot.age / slot.life
					if u >= 1 then
						slot.state = "idle"
						slot.part.Transparency = 1
						slot.delay = ctx.rng:NextNumber(0.02, 0.35)
						wind.live = wind.live - 1
					else
						local pos = slot.a:Lerp(slot.b, u)
						slot.part.CFrame = CFrame.lookAt(pos, pos + wind.dir)
						local alpha = math.min(u / 0.2, (1 - u) / 0.3, 1)
						slot.part.Transparency = 1 - (1 - slot.minTransparency) * alpha
					end
				end
			end
		end
	end
end

local function stepContext(ctx, dt)
	if ctx.stopped then
		return
	end
	if dt > 0.1 then
		dt = 0.1 -- a lag spike must not teleport bars/clouds
	end
	local active = isActive(ctx)
	if active then
		ctx.clock = ctx.clock + dt
		if #ctx.spinBars > 0 then
			guarded("SpinBar", updateSpinBars, ctx)
		end
		if #ctx.pendulums > 0 then
			guarded("Pendulum", updatePendulums, ctx)
		end
		if #ctx.movers > 0 then
			guarded("MovingCloud", updateMovers, ctx)
		end
		if #ctx.winds > 0 then
			guarded("WindGustVisuals", updateWindStreaks, ctx, dt)
		end
	elseif ctx.moversMoving then
		guarded("MovingCloud", haltMovers, ctx)
	end

	ctx.stormAcc = ctx.stormAcc + dt
	if ctx.stormAcc >= STORM_TICK then
		local elapsed = ctx.stormAcc
		ctx.stormAcc = 0
		if active and #ctx.storms > 0 then
			guarded("StormCloud", tickStorms, ctx, elapsed)
		end
	end

	ctx.hitAcc = ctx.hitAcc + dt
	if ctx.hitAcc >= HIT_TICK then
		ctx.hitAcc = 0
		if active and #ctx.hitters > 0 then
			guarded("HitPoll", pollHitters, ctx)
		end
	end

	ctx.windAcc = ctx.windAcc + dt
	if ctx.windAcc >= WIND_TICK then
		ctx.windAcc = 0
		if #ctx.winds > 0 then
			guarded("WindGust", tickWinds, ctx, active)
		end
	end

	ctx.plateAcc = ctx.plateAcc + dt
	if ctx.plateAcc >= PLATE_TICK then
		ctx.plateAcc = 0
		if #ctx.groupList > 0 then
			guarded("PressurePlate", tickPlates, ctx)
		end
	end
end

-- The single shared Heartbeat connection of this context (created lazily by the first behaviour
-- that needs per-frame work).
local function ensureHeartbeat(ctx)
	if ctx.heartbeat then
		return
	end
	ctx.heartbeat = RunService.Heartbeat:Connect(function(dt)
		stepContext(ctx, dt)
	end)
	table.insert(ctx.connections, ctx.heartbeat)
end

-- Register a moving damage bar (SpinBar / Pendulum): Touched + the backup overlap poll.
local function addHitter(ctx, hitter)
	table.insert(ctx.hitters, hitter)
	ensureHeartbeat(ctx)
	connect(ctx, hitter.part.Touched, function(hit)
		if ctx.stopped or not isActive(ctx) then
			return
		end
		local player = playerFromHit(hit)
		if player then
			registerHit(ctx, hitter, player)
		end
	end)
	onStop(ctx, function()
		hitter.lastHit = {}
	end)
end

----------------------------------------------------------------------
-- Behaviour: SpinBar
----------------------------------------------------------------------
local function attachSpinBar(ctx, part)
	local bar = {
		part = part,
		base = part.CFrame,
		speed = math.rad(attrNumber(part, "Speed", 70)),
		phase = math.rad(attrNumber(part, "Phase", 0)),
		-- hit data used by the shared moving-bar routine
		damage = attrNumber(part, "Damage", 15),
		kind = "SpinBar",
		knockback = SPINBAR_KNOCKBACK,
		lastHit = {},
	}
	table.insert(ctx.spinBars, bar)
	addHitter(ctx, bar)
	onStop(ctx, function()
		if part.Parent then
			part.CFrame = bar.base
		end
	end)
end

----------------------------------------------------------------------
-- Behaviour: Pendulum
--   Tagged part = the swinging beam. Attributes: Hinge (world pivot), Axis (world swing axis),
--   Period (s per full swing), Arc (degrees each side of rest), Damage, optional Phase (degrees).
--   Swing angle = Arc * sin(2*pi*t/Period + Phase); decor welded to the beam follows by itself,
--   decor merely parented under it (anchored) is moved by the same transform.
----------------------------------------------------------------------
local function attachPendulum(ctx, part)
	local base = part.CFrame
	local hinge = attrVector3(part, "Hinge", nil)
	if not hinge then
		hinge = base.Position + Vector3.new(0, 12, 0) -- sane default: pivot a little above the beam
	end
	local axis = attrVector3(part, "Axis", nil)
	if not axis or axis.Magnitude < 0.01 then
		axis = flatUnit(base.RightVector, Vector3.new(1, 0, 0))
	else
		axis = axis.Unit
	end

	local phase
	local phaseAttr = part:GetAttribute("Phase")
	if type(phaseAttr) == "number" then
		phase = math.rad(phaseAttr)
	else
		-- no explicit phase: derive one from the position so neighbouring pendulums are not in lockstep
		phase = (hinge.X * 0.173 + hinge.Y * 0.071 + hinge.Z * 0.291) % TWO_PI
	end

	-- anchored decor parented under the beam would be left behind by the swing: move it ourselves
	local followers = {}
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("BasePart") and d.Anchored then
			table.insert(followers, { part = d, base = d.CFrame })
		end
	end

	local pendulum = {
		part = part,
		base = base,
		pivot = CFrame.new(hinge),
		pivotInverse = CFrame.new(hinge):Inverse(),
		axis = axis,
		arc = math.rad(Util.Clamp(attrNumber(part, "Arc", 55), 0, 170)),
		period = math.max(0.8, attrNumber(part, "Period", 4)),
		phase = phase,
		followers = followers,
		-- hit data used by the shared moving-bar routine
		damage = attrNumber(part, "Damage", 20),
		kind = "Pendulum",
		knockback = PENDULUM_KNOCKBACK,
		lastHit = {},
	}
	table.insert(ctx.pendulums, pendulum)
	addHitter(ctx, pendulum)
	onStop(ctx, function()
		if part.Parent then
			part.CFrame = base
		end
		for _, f in ipairs(followers) do
			if f.part.Parent then
				f.part.CFrame = f.base
			end
		end
	end)
end

----------------------------------------------------------------------
-- Behaviour: MovingCloud (motion in updateMovers, see the carrying note there)
----------------------------------------------------------------------
local function attachMovingCloud(ctx, part)
	table.insert(ctx.movers, {
		part = part,
		base = part.CFrame,
		offset = attrVector3(part, "EndOffset", Vector3.new(0, 0, 16)),
		period = math.max(0.5, attrNumber(part, "Period", 5)),
		phase = attrNumber(part, "Phase", 0),
	})
	ensureHeartbeat(ctx)
	onStop(ctx, function()
		if part.Parent then
			part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		end
	end)
end

----------------------------------------------------------------------
-- Behaviour: StormCloud
----------------------------------------------------------------------
-- A rain emitter hugging the top of the storm volume; drops fall through it and a little below.
local function addRain(ctx, part)
	if part:FindFirstChildOfClass("ParticleEmitter") then
		return -- the builder already dressed this cloud
	end
	local size = part.Size
	local fallSpeed = 30
	local rainPart = makePart({
		Name = "StormRain",
		Transparency = 1,
		Size = Vector3.new(math.max(1, size.X * 0.95), 0.2, math.max(1, size.Z * 0.95)),
		CFrame = part.CFrame * CFrame.new(0, size.Y / 2 - 0.1, 0),
		Parent = ctx.container,
	})
	local lifetime = math.max(0.35, (size.Y + 2) / fallSpeed)
	local rate = Util.Clamp(size.X * size.Z * 1.2, 60, 320)
	local rain = newEmitter({
		Name = "Rain",
		Rate = rate,
		Lifetime = NumberRange.new(lifetime * 0.9, lifetime * 1.1),
		Speed = NumberRange.new(fallSpeed * 0.9, fallSpeed * 1.1),
		EmissionDirection = Enum.NormalId.Bottom,
		SpreadAngle = Vector2.new(3, 3),
		LightEmission = 0.1,
		LightInfluence = 0.7,
		Color = ColorSequence.new(PAL.RainTop, PAL.RainBottom),
		Size = NumberSequence.new(0.28),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.8, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Acceleration = Vector3.new(0, -40, 0),
	})
	rain.Parent = rainPart
	table.insert(ctx.permanents, rainPart)
end

local function attachStormCloud(ctx, part)
	table.insert(ctx.storms, { part = part, dps = attrNumber(part, "DPS", 8) })
	addRain(ctx, part)
	ensureHeartbeat(ctx)
end

----------------------------------------------------------------------
-- Behaviour: LightningZone
--   The tagged part marks the strike disc: its centre is the impact point and `Radius`
--   (default: half its footprint) is the damage radius. A red warning disc fills up for
--   `Warning` seconds, then a jagged bolt hits and everyone in the disc is damaged. The flash is
--   brief and dim on purpose: it must read as a strike, not blind the screen.
----------------------------------------------------------------------
local function zoneGroundY(part)
	local half = part.Size.Y / 2
	if part.Size.Y > 6 then
		return part.Position.Y - half -- tall volume: the floor is at its bottom
	end
	return part.Position.Y + half -- slab: the floor is its top face
end

local function showStrikeWarning(ctx, zone, target)
	local diameter = zone.radius * 2
	local flat = CFrame.new(target.X, target.Y + 0.2, target.Z) * CFrame.Angles(0, 0, math.pi / 2)
	local ring = makePart({
		Name = "StrikeWarning",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.1, diameter, diameter),
		CFrame = flat,
		Color = PAL.Warn,
		Transparency = 0.55,
	})
	local fill = makePart({
		Name = "StrikeWarningFill",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.14, 0.4, 0.4),
		CFrame = flat,
		Color = PAL.WarnFill,
		Transparency = 0.62,
	})
	addTemp(ctx, ring, zone.warning + 3)
	addTemp(ctx, fill, zone.warning + 3)
	-- the inner disc grows to the full radius exactly when the bolt lands
	Util.Tween(fill, zone.warning, { Size = Vector3.new(0.14, diameter, diameter) },
		Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	-- the outer ring pulses so the danger reads at a glance
	TweenService:Create(ring, TweenInfo.new(0.22, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.3 }):Play()
	return ring, fill
end

local function strikeAt(ctx, zone, target)
	local rng = ctx.rng
	local radius = zone.radius

	-- 1. jagged bolt from the sky: a soft glow shell + a thin core per segment
	local top = Vector3.new(target.X + rng:NextNumber(-8, 8), target.Y + BOLT_HEIGHT, target.Z + rng:NextNumber(-8, 8))
	local points = { top }
	for i = 1, BOLT_SEGMENTS - 1 do
		local alpha = i / BOLT_SEGMENTS
		local sway = 1 + (1 - alpha) * 5
		local p = top:Lerp(target, alpha)
		table.insert(points, p + Vector3.new(rng:NextNumber(-sway, sway), 0, rng:NextNumber(-sway, sway)))
	end
	table.insert(points, target)

	for i = 1, #points - 1 do
		local a = points[i]
		local b = points[i + 1]
		local length = (b - a).Magnitude + 0.4
		local look = CFrame.lookAt(a:Lerp(b, 0.5), b)
		local glow = makePart({
			Name = "BoltGlow",
			Size = Vector3.new(1.8, 1.8, length),
			CFrame = look,
			Color = PAL.BoltGlow,
			Transparency = 0.72,
		})
		local core = makePart({
			Name = "BoltCore",
			Size = Vector3.new(0.55, 0.55, length),
			CFrame = look,
			Color = PAL.BoltCore,
			Transparency = 0.08,
		})
		addTemp(ctx, glow, 0.7)
		addTemp(ctx, core, 0.7)
		Util.Tween(glow, 0.28, { Transparency = 1, Size = Vector3.new(0.5, 0.5, length) },
			Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Util.Tween(core, 0.28, { Transparency = 1, Size = Vector3.new(0.15, 0.15, length) },
			Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end

	-- 2. impact flash: a brief translucent ground disc + a small fading light + a short spark burst
	local flash = makePart({
		Name = "StrikeFlash",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, radius * 2, radius * 2),
		CFrame = CFrame.new(target.X, target.Y + 0.25, target.Z) * CFrame.Angles(0, 0, math.pi / 2),
		Color = PAL.BoltCore,
		Transparency = 0.5,
	})
	addTemp(ctx, flash, 0.8)
	Util.Tween(flash, 0.35, { Size = Vector3.new(0.2, radius * 2.4, radius * 2.4), Transparency = 1 },
		Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local impact = makePart({
		Name = "StrikeImpact",
		Transparency = 1,
		Size = Vector3.new(1, 1, 1),
		CFrame = CFrame.new(target.X, target.Y + 1.5, target.Z),
	})
	local light = Instance.new("PointLight")
	light.Color = PAL.BoltCore
	light.Brightness = 2.4
	light.Range = Util.Clamp(radius * 3.5, 16, 30)
	light.Shadows = false
	light.Parent = impact
	local sparks = newEmitter({
		Name = "StrikeSparks",
		Rate = 0,
		Color = ColorSequence.new(PAL.BoltCore, PAL.BoltGlow),
		Lifetime = NumberRange.new(0.35, 0.7),
		Speed = NumberRange.new(18, 32),
		EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(70, 70),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) }),
		Acceleration = Vector3.new(0, -60, 0),
	})
	sparks.Parent = impact
	addTemp(ctx, impact, 1.2)
	sparks:Emit(20)
	Util.Tween(light, 0.4, { Brightness = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	-- 3. damage everyone standing in the strike cylinder
	local reach = radius + 0.8
	local reach2 = reach * reach
	for _, player in ipairs(Players:GetPlayers()) do
		local root = getLivingRoot(player)
		if root then
			local p = root.Position
			local dx = p.X - target.X
			local dz = p.Z - target.Z
			if dx * dx + dz * dz <= reach2 and p.Y > target.Y - 4 and p.Y < target.Y + 16 then
				hurt(ctx, player, zone.damage, "Lightning", {
					KnockbackFrom = target,
					Knockback = LIGHTNING_KNOCKBACK,
				})
			end
		end
	end
end

-- One warn -> strike cycle. Returns false when the context was stopped.
local function lightningCycle(ctx, zone)
	if not awaitActive(ctx) then
		return false
	end
	local part = zone.part
	local target = Vector3.new(part.Position.X, zoneGroundY(part), part.Position.Z)
	local ring, fill = showStrikeWarning(ctx, zone, target)
	local ok = waitActive(ctx, zone.warning)
	removeTemp(ctx, ring)
	removeTemp(ctx, fill)
	if not ok then
		return false
	end
	strikeAt(ctx, zone, target)
	return true
end

local function runLightningZone(ctx, zone)
	-- Desynchronise zones so a whole stage does not flash at once.
	if not waitActive(ctx, ctx.rng:NextNumber(0.3, zone.interval)) then
		return
	end
	while not ctx.stopped and zone.part.Parent do
		local ok, result = pcall(lightningCycle, ctx, zone)
		if not ok then
			if not warned.Lightning then
				warned.Lightning = true
				warn("[HazardService] lightning cycle failed: " .. tostring(result))
			end
		elseif result == false then
			return
		end
		-- Interval is strike-to-strike; the warning already used part of it.
		local rest = zone.interval + ctx.rng:NextNumber(-zone.jitter, zone.jitter) - zone.warning
		if rest < 0.5 then
			rest = 0.5
		end
		if not waitActive(ctx, rest) then
			return
		end
	end
end

local function attachLightningZone(ctx, part)
	local interval = math.max(1.5, attrNumber(part, "Interval", 4))
	local radius = attrNumber(part, "Radius", 0)
	if radius <= 0 then
		radius = math.max(2, math.min(part.Size.X, part.Size.Z) / 2)
	end
	local zone = {
		part = part,
		damage = attrNumber(part, "Damage", 28),
		interval = interval,
		warning = math.max(0.4, attrNumber(part, "Warning", 1.2)),
		jitter = math.max(0, attrNumber(part, "Jitter", interval * 0.2)),
		radius = radius,
	}
	task.spawn(runLightningZone, ctx, zone)
end

----------------------------------------------------------------------
-- Behaviour: WindGust
--   Tagged part = invisible volume. Attributes: Force (studs/s the gust can reach), Direction
--   (unit vector, used horizontally), Interval (s between gust starts), Warning (s of faint
--   streaks before the push). Cycle: idle -> warning (hint streaks) -> blow (Duration attr, default 1.5 s, of
--   push + dense streaks) -> idle. No damage, ever. See the push note above releasePush.
----------------------------------------------------------------------
local function windCycle(ctx, wind)
	if not awaitActive(ctx) then
		return false
	end
	setWindPhase(ctx, wind, "warning")
	if not waitActive(ctx, wind.warning) then
		return false
	end
	setWindPhase(ctx, wind, "blow")
	if not waitActive(ctx, wind.blow) then
		return false
	end
	setWindPhase(ctx, wind, "idle")
	return true
end

local function runWind(ctx, wind)
	-- Desynchronise gust volumes so a whole stage does not blow at once.
	if not waitActive(ctx, ctx.rng:NextNumber(0.2, wind.interval)) then
		return
	end
	while not ctx.stopped and wind.part.Parent do
		local ok, result = pcall(windCycle, ctx, wind)
		if not ok then
			if not warned.WindCycle then
				warned.WindCycle = true
				warn("[HazardService] wind cycle failed: " .. tostring(result))
			end
			setWindPhase(ctx, wind, "idle")
		elseif result == false then
			return
		end
		local rest = wind.interval + ctx.rng:NextNumber(-0.4, 0.4) - wind.warning - wind.blow
		if rest < 0.8 then
			rest = 0.8
		end
		if not waitActive(ctx, rest) then
			return
		end
	end
end

local function attachWindGust(ctx, part)
	part.CanCollide = false -- an invisible wall would be a nasty surprise
	local dir = flatUnit(attrVector3(part, "Direction", nil), nil)
	if not dir then
		dir = flatUnit(part.CFrame.LookVector, Vector3.new(1, 0, 0))
	end
	local force = Util.Clamp(attrNumber(part, "Force", 18), 0, WIND_MAX_FORCE)
	local halfLen = math.max(1, halfExtentAlong(part, dir))
	local wind = {
		part = part,
		dir = dir,
		force = force,
		interval = math.max(2.5, attrNumber(part, "Interval", 5)),
		warning = math.max(0.5, attrNumber(part, "Warning", 1.5)),
		blow = Util.Clamp(attrNumber(part, "Duration", WIND_BLOW_TIME), 0.6, 3), -- optional extra attribute
		center = part.Position,
		halfLen = halfLen,
		phase = "idle",
		phaseClock = 0,
		pushed = {}, -- player -> { root, attachment, force }
		streaks = {},
		live = 0, -- streaks currently flying
		drift = nil,
		warnRate = 4,
		blowRate = 22,
	}

	-- drifting smoke at the upwind face: faint puffs carried along the wind
	local crossWidth = math.max(1, halfExtentAlong(part, dir:Cross(Vector3.new(0, 1, 0)).Unit) * 2)
	local crossHeight = math.max(1, halfExtentAlong(part, Vector3.new(0, 1, 0)) * 2)
	local upwind = wind.center - dir * halfLen
	local driftPart = makePart({
		Name = "WindDrift",
		Transparency = 1,
		Size = Vector3.new(crossWidth, crossHeight, 0.4),
		CFrame = CFrame.lookAt(upwind, upwind + dir),
		Parent = ctx.container,
	})
	table.insert(ctx.permanents, driftPart)
	local driftSpeed = force * 0.9 + 8
	wind.drift = newPuffEmitter({
		Name = "WindSmoke",
		Color = ColorSequence.new(PAL.WindDrift, PAL.PuffDark),
		LightEmission = 0,
		Lifetime = NumberRange.new(
			Util.Clamp(halfLen * 2 / driftSpeed, 0.5, 1.6),
			Util.Clamp(halfLen * 2.4 / driftSpeed, 0.6, 1.9)
		),
		Speed = NumberRange.new(driftSpeed * 0.85, driftSpeed * 1.15),
		EmissionDirection = Enum.NormalId.Front, -- the part's look vector == the wind direction
		SpreadAngle = Vector2.new(4, 4),
		Drag = 0,
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2),
			NumberSequenceKeypoint.new(1, 5),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.25, 0.86),
			NumberSequenceKeypoint.new(1, 1),
		}),
	})
	wind.drift.Parent = driftPart

	-- pooled streak parts (invisible until used)
	for _ = 1, WIND_STREAKS do
		local streak = makePart({
			Name = "WindStreak",
			Size = Vector3.new(0.14, 0.14, 6),
			Color = PAL.Wind,
			Transparency = 1,
			Parent = ctx.container,
		})
		table.insert(ctx.permanents, streak)
		table.insert(wind.streaks, {
			part = streak,
			state = "idle",
			delay = ctx.rng:NextNumber(0, 0.5),
			age = 0,
			life = 1,
			a = wind.center,
			b = wind.center,
			minTransparency = 0.5,
		})
	end

	table.insert(ctx.winds, wind)
	ensureHeartbeat(ctx)
	onStop(ctx, function()
		clearWindPushes(wind)
	end)
	task.spawn(runWind, ctx, wind)
end

----------------------------------------------------------------------
-- Behaviour: CloudCannon
--   Touch the pad -> 0.35 s squash + puff -> the player's root gets the velocity of a projectile that
--   leaves its CURRENT position and reaches Target after FlightTime under workspace.Gravity:
--       v = (Target - p) / t + Vector3.new(0, g * t / 2, 0)
--   (Target is where the root passes at t = FlightTime). The player cannot be launched again for
--   CANNON_REARM seconds and is protected from all damage (fall / void included) while in flight.
----------------------------------------------------------------------
local function chargeCannon(cannon)
	cannon.charging = cannon.charging + 1
	if cannon.puff then
		cannon.puff:Emit(8)
	end
	if cannon.sparks then
		cannon.sparks:Emit(8)
	end
	local base = cannon.baseSize
	cannon.tween = Util.Tween(cannon.part, CANNON_CHARGE * 0.85,
		{ Size = Vector3.new(base.X * 1.1, base.Y * 0.68, base.Z * 1.1) },
		Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
end

-- The charge ended (launch or cancelled): spring back once nobody else is charging.
local function releaseCannon(ctx, cannon)
	cannon.charging = math.max(0, cannon.charging - 1)
	if cannon.charging > 0 or ctx.stopped or not cannon.part.Parent then
		return
	end
	cannon.tween = Util.Tween(cannon.part, 0.55, { Size = cannon.baseSize },
		Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
end

-- Where the rider's root really is when our velocity write reaches their client: the server sees a
-- position that is up to one round trip old, and a walking rider keeps moving until the write lands.
local function launchOrigin(player, root)
	local position = root.Position
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	if ok and type(ping) == "number" and ping == ping then
		ping = Util.Clamp(ping, 0, CANNON_MAX_LATENCY)
		local v = root.AssemblyLinearVelocity
		position = position + Vector3.new(v.X, 0, v.Z) * ping
	end
	return position
end

local function launchPlayer(ctx, cannon, player, root)
	local gravity = Workspace.Gravity
	local flight = cannon.flight
	local origin = launchOrigin(player, root)
	local velocity = (cannon.target - origin) / flight + Vector3.new(0, gravity * flight / 2, 0)
	if velocity.Magnitude > CANNON_MAX_SPEED then
		velocity = velocity.Unit * CANNON_MAX_SPEED
	end
	root.AssemblyLinearVelocity = velocity
	ctx.launchedAt[player] = os.clock()
	-- no fall / void / hazard damage until just after the touchdown
	pcall(DamageService.GrantInvulnerability, player, flight + CANNON_LANDING_GRACE)
	if cannon.puff then
		cannon.puff:Emit(20)
	end
	if cannon.sparks then
		cannon.sparks:Emit(14)
	end
end

local function runCannonLaunch(ctx, cannon, player)
	chargeCannon(cannon)
	local alive = sleep(ctx, CANNON_CHARGE)
	cannon.pending[player] = nil
	if not alive then
		return -- match ended: the part may already be gone
	end
	local launched = false
	local root = getLivingRoot(player)
	if root and player.Parent and isActive(ctx) and not isDowned(player) and cannon.part.Parent then
		-- the player must still be on (or right next to) the pad: someone who jumped off is left alone
		local offset = root.Position - cannon.part.Position
		local reach = math.max(cannon.part.Size.X, cannon.part.Size.Z) / 2 + CANNON_STAND_SLACK
		if Vector3.new(offset.X, 0, offset.Z).Magnitude <= reach and math.abs(offset.Y) <= 12 then
			launchPlayer(ctx, cannon, player, root)
			launched = true
		end
	end
	if not launched and cannon.puff then
		cannon.puff:Emit(4) -- a little fizzle so the charge does not just vanish
	end
	releaseCannon(ctx, cannon)
end

local function onCannonTouched(ctx, cannon, hit)
	if ctx.stopped or not isActive(ctx) then
		return
	end
	local player, root = playerFromHit(hit)
	if not player or isDowned(player) or cannon.pending[player] then
		return
	end
	local last = ctx.launchedAt[player]
	if last and os.clock() - last < CANNON_REARM then
		return -- already flying (or just landed on another pad)
	end
	if root.Position.Y < cannon.part.Position.Y then
		return -- only standing on the pad arms it
	end
	cannon.pending[player] = true
	task.spawn(function()
		local ok, err = pcall(runCannonLaunch, ctx, cannon, player)
		if not ok then
			cannon.pending[player] = nil
			if not warned.Cannon then
				warned.Cannon = true
				warn("[HazardService] cannon launch failed: " .. tostring(err))
			end
		end
	end)
end

local function attachCloudCannon(ctx, part)
	local target = attrVector3(part, "Target", nil)
	if not target then
		-- no landing point authored: lob the player a little way ahead of the pad
		local ahead = flatUnit(part.CFrame.LookVector, Vector3.new(0, 0, 1))
		target = part.Position + ahead * 30 + Vector3.new(0, 6, 0)
	end
	local cannon = {
		part = part,
		target = target,
		flight = Util.Clamp(attrNumber(part, "FlightTime", CANNON_DEFAULT_FLIGHT), 0.4, 4),
		baseSize = part.Size,
		pending = {}, -- player -> true while charging
		charging = 0,
		tween = nil,
		puff = nil,
		sparks = nil,
	}
	cannon.puff = newPuffEmitter({ Name = "CannonPoof" })
	cannon.puff.Parent = part
	cannon.sparks = newEmitter({
		Name = "CannonSparks",
		Rate = 0,
		Color = ColorSequence.new(PAL.Sparkle, PAL.PuffLight),
		Lifetime = NumberRange.new(0.4, 0.8),
		Speed = NumberRange.new(8, 18),
		EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(60, 60),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) }),
		Acceleration = Vector3.new(0, -16, 0),
	})
	cannon.sparks.Parent = part
	connect(ctx, part.Touched, function(hit)
		onCannonTouched(ctx, cannon, hit)
	end)
	onStop(ctx, function()
		if cannon.tween then
			cannon.tween:Cancel()
		end
		if part.Parent then
			part.Size = cannon.baseSize
		end
		cannon.pending = {}
	end)
end

----------------------------------------------------------------------
-- Behaviour: VanishCloud
--   Touched from above -> blinks for VanishDelay, fades and turns non-solid, comes back after
--   ReturnDelay. The timers always complete (even while paused) so a cloud is never stuck gone.
----------------------------------------------------------------------
local function runVanish(ctx, cloud)
	cloud.state = "pending"
	-- crumble warning: a quick blink
	local elapsed = 0
	local dim = false
	while elapsed < cloud.delay do
		if ctx.stopped then
			return
		end
		dim = not dim
		local step = math.min(0.15, cloud.delay - elapsed)
		if dim then
			fadeSet(cloud.set, 0.4, step)
		else
			fadeSet(cloud.set, 0, step)
		end
		task.wait(step)
		elapsed = elapsed + step
	end
	if ctx.stopped then
		return
	end

	cloud.state = "gone"
	collideSet(cloud.set, false)
	fadeSet(cloud.set, 1, 0.35)
	if not sleep(ctx, cloud.returnDelay) then
		return
	end

	cloud.state = "returning"
	collideSet(cloud.set, true)
	fadeSet(cloud.set, 0, 0.4)
	if not sleep(ctx, 0.45) then
		return
	end
	cloud.state = "idle"
end

local function attachVanishCloud(ctx, part)
	local cloud = {
		part = part,
		set = collectFadeSet(part),
		delay = math.max(0.1, attrNumber(part, "VanishDelay", 0.9)),
		returnDelay = math.max(0.5, attrNumber(part, "ReturnDelay", 3.5)),
		state = "idle",
	}
	connect(ctx, part.Touched, function(hit)
		if ctx.stopped or cloud.state ~= "idle" or not isActive(ctx) then
			return
		end
		local player, root = playerFromHit(hit)
		if not player then
			return
		end
		if root.Position.Y < part.Position.Y then
			return -- bumped from below/side-on at its underside: only standing on it counts
		end
		cloud.state = "pending" -- claim it before the thread starts so a second touch cannot race
		task.spawn(runVanish, ctx, cloud)
	end)
	onStop(ctx, function()
		-- leave the cloud in its pristine state in case the course is reused
		if part.Parent then
			collideSet(cloud.set, true)
			fadeSet(cloud.set, 0, 0)
		end
	end)
end

----------------------------------------------------------------------
-- Behaviour: BouncePad
----------------------------------------------------------------------
local function popPad(ctx, pad)
	local part = pad.part
	if pad.burst then
		pad.burst:Emit(10)
	end
	-- squash-and-spring: swell quickly, then settle back with an elastic overshoot
	local grow = Util.Tween(part, 0.07, { Size = pad.baseSize * 1.14 },
		Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	pad.tween = grow
	task.delay(0.07, function()
		-- a newer bounce owns the animation now, or the match is over
		if ctx.stopped or pad.tween ~= grow or not part.Parent then
			return
		end
		pad.tween = Util.Tween(part, 0.5, { Size = pad.baseSize },
			Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
	end)
end

local function onBounceTouched(ctx, pad, hit)
	if ctx.stopped then
		return
	end
	local player, root = playerFromHit(hit)
	if not player or isDowned(player) then
		return
	end
	if root.Position.Y < pad.part.Position.Y then
		return -- must land on top of the pad
	end
	local now = os.clock()
	local last = pad.lastHit[player]
	if last and now - last < BOUNCE_DEBOUNCE then
		return
	end
	pad.lastHit[player] = now
	-- keep the player's heading; when moving, rescale it to the pad's LaunchSpeed so a bounce always
	-- carries the distance the course generator validated. A standing player bounces straight up.
	local v = root.AssemblyLinearVelocity
	local h = Vector3.new(v.X, 0, v.Z)
	if pad.launchSpeed > 0 and h.Magnitude > 2 then
		h = h.Unit * pad.launchSpeed
	end
	root.AssemblyLinearVelocity = Vector3.new(h.X, pad.power, h.Z)
	popPad(ctx, pad)
end

local function attachBouncePad(ctx, part)
	local pad = {
		part = part,
		power = attrNumber(part, "Power", 90),
		launchSpeed = attrNumber(part, "LaunchSpeed", 0),
		baseSize = part.Size,
		lastHit = {},
		tween = nil,
		burst = nil,
	}
	-- one reusable sparkle puff, fired on every bounce
	local burst = newEmitter({
		Name = "BounceBurst",
		Rate = 0,
		Color = ColorSequence.new(PAL.PuffLight, PAL.Sparkle),
		Lifetime = NumberRange.new(0.4, 0.8),
		Speed = NumberRange.new(10, 22),
		EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(40, 40),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) }),
		Acceleration = Vector3.new(0, -20, 0),
	})
	burst.Parent = part
	pad.burst = burst
	connect(ctx, part.Touched, function(hit)
		onBounceTouched(ctx, pad, hit)
	end)
	onStop(ctx, function()
		if pad.tween then
			pad.tween:Cancel()
		end
		if part.Parent then
			part.Size = pad.baseSize
		end
		pad.lastHit = {}
	end)
end

----------------------------------------------------------------------
-- Behaviour: PressurePlate + PlateBridge
----------------------------------------------------------------------
local function getGroup(ctx, id)
	local group = ctx.groups[id]
	if not group then
		group = { id = id, plates = {}, bridges = {}, shown = false, emptySince = nil }
		ctx.groups[id] = group
		table.insert(ctx.groupList, group)
	end
	return group
end

local function attachPressurePlate(ctx, part)
	local group = getGroup(ctx, attrString(part, "BridgeId", "default"))
	local extents = worldExtents(part)
	local plate = {
		part = part,
		baseCF = part.CFrame,
		baseColor = part.Color,
		pressed = false,
		-- a world-aligned box from the plate's underside to 4.5 studs above its top
		boxCF = CFrame.new(part.Position + Vector3.new(0, 2.25, 0)),
		boxSize = Vector3.new(extents.X, extents.Y + 4.5, extents.Z),
	}
	table.insert(group.plates, plate)
	ensureHeartbeat(ctx)
	onStop(ctx, function()
		if part.Parent then
			part.CFrame = plate.baseCF
			part.Color = plate.baseColor
		end
	end)
end

local function attachPlateBridge(ctx, part)
	local group = getGroup(ctx, attrString(part, "BridgeId", "default"))
	local bridge = { part = part, set = collectFadeSet(part) }
	table.insert(group.bridges, bridge)
	-- Bridges start retracted: invisible and walk-through until somebody holds a plate.
	collideSet(bridge.set, false)
	fadeSet(bridge.set, 1, 0)
	ensureHeartbeat(ctx)
end

----------------------------------------------------------------------
-- Tag dispatch
----------------------------------------------------------------------
local BEHAVIOURS = {
	[TAGS.SpinBar] = attachSpinBar,
	[TAGS.StormCloud] = attachStormCloud,
	[TAGS.LightningZone] = attachLightningZone,
	[TAGS.VanishCloud] = attachVanishCloud,
	[TAGS.MovingCloud] = attachMovingCloud,
	[TAGS.BouncePad] = attachBouncePad,
	[TAGS.PressurePlate] = attachPressurePlate,
	[TAGS.PlateBridge] = attachPlateBridge,
	[TAGS.Pendulum] = attachPendulum,
	[TAGS.WindGust] = attachWindGust,
	[TAGS.CloudCannon] = attachCloudCannon,
}

local function stopContext(ctx)
	if ctx.stopped then
		return
	end
	ctx.stopped = true -- every loop/thread checks this after each wait
	for _, conn in ipairs(ctx.connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	ctx.connections = {}
	ctx.heartbeat = nil
	for _, fn in ipairs(ctx.cleanups) do
		pcall(fn)
	end
	ctx.cleanups = {}
	for _, inst in ipairs(ctx.permanents) do
		pcall(function()
			inst:Destroy()
		end)
	end
	ctx.permanents = {}
	for part in pairs(ctx.temps) do
		pcall(function()
			part:Destroy()
		end)
	end
	ctx.temps = {}
	ctx.launchedAt = {}
end

-- Start every tagged behaviour found under `container`.
-- matchHandle = { IsActive = function() -> bool }  (hazards pause while it returns false)
-- Returns stopFn: stops all loops/connections and removes runtime effects (idempotent).
function HazardService.Attach(container, matchHandle)
	if not container then
		warn("[HazardService] Attach called without a container")
		return function() end
	end
	local ctx = newContext(container, matchHandle)
	for _, inst in ipairs(container:GetDescendants()) do
		if inst:IsA("BasePart") then
			for _, tag in ipairs(CollectionService:GetTags(inst)) do
				local attach = BEHAVIOURS[tag]
				if attach then
					local ok, err = pcall(attach, ctx, inst)
					if not ok then
						warn("[HazardService] could not attach " .. tag .. " to " .. inst:GetFullName() .. ": " .. tostring(err))
					end
				end
			end
		end
	end
	return function()
		stopContext(ctx)
	end
end

return HazardService
