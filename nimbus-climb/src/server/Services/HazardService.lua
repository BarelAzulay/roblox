-- HazardService: brings the tagged parts of a sky course to life and applies damage through
-- DamageService. One Attach() call per match; the returned stopFn tears everything down.
-- Plain Lua 5.1-compatible syntax only.
--
-- Behaviours (see Config.Tags): SpinBar, StormCloud, LightningZone, VanishCloud, MovingCloud,
-- BouncePad, PressurePlate + PlateBridge. Every parameter is read from attributes with a sane
-- default, so a part with a missing attribute still behaves.
--
-- Structure: Attach() builds a per-match "context" table. All per-frame work (spinning bars,
-- moving clouds, storm ticks, plate polling) runs from ONE shared Heartbeat connection owned by
-- that context. Timed sequences (lightning, vanishing clouds) run in their own task threads that
-- check ctx.stopped after every wait. Everything created at runtime lives inside the container.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)
local Util = require(Shared.Util)
local DamageService = require(script.Parent.DamageService)

local HazardService = {}

local TAGS = Config.Tags
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

----------------------------------------------------------------------
-- Tunables (anything a designer might want to tweak lives here)
----------------------------------------------------------------------
local STORM_TICK = 0.25 -- seconds between storm damage ticks (4 Hz)
local PLATE_TICK = 0.2 -- seconds between pressure-plate polls (5 Hz)
local PLATE_RETRACT_DELAY = 1.0 -- bridge stays up this long after the last player leaves
local PLATE_FADE_IN = 0.2
local PLATE_FADE_OUT = 0.45
local PLATE_PRESS_DEPTH = 0.18 -- how far a plate sinks when stood on
local SPINBAR_DEBOUNCE = 0.35 -- per player, per bar (DamageService i-frames do the rest)
local SPINBAR_KNOCKBACK = 55
local BOUNCE_DEBOUNCE = 0.3
local LIGHTNING_KNOCKBACK = 40
local BOLT_HEIGHT = 90
local BOLT_SEGMENTS = 8

local WARNING_COLOR = Theme.Colors.Bad
local WARNING_FILL_COLOR = Color3.fromRGB(255, 84, 70)
local BOLT_CORE_COLOR = Color3.fromRGB(236, 244, 255)
local BOLT_GLOW_COLOR = Color3.fromRGB(150, 140, 255)

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
	if type(value) == "number" then
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
		movers = {},
		moversMoving = false,
		storms = {},
		groups = {}, -- BridgeId -> group
		groupList = {},
		stormAcc = 0,
		plateAcc = 0,
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

-- All living players with any body part overlapping the box.
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
			Color = plate.baseColor:Lerp(Theme.Colors.White, 0.45),
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
		if #ctx.movers > 0 then
			guarded("MovingCloud", updateMovers, ctx)
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

----------------------------------------------------------------------
-- Behaviour: SpinBar
----------------------------------------------------------------------
local function onSpinBarTouched(ctx, bar, hit)
	if ctx.stopped or not isActive(ctx) then
		return
	end
	local player = playerFromHit(hit)
	if not player then
		return
	end
	local now = os.clock()
	local last = bar.lastHit[player]
	if last and now - last < SPINBAR_DEBOUNCE then
		return
	end
	bar.lastHit[player] = now
	hurt(ctx, player, bar.damage, "SpinBar", {
		KnockbackFrom = bar.part.Position,
		Knockback = SPINBAR_KNOCKBACK,
	})
end

local function attachSpinBar(ctx, part)
	local bar = {
		part = part,
		base = part.CFrame,
		speed = math.rad(attrNumber(part, "Speed", 70)),
		phase = math.rad(attrNumber(part, "Phase", 0)),
		damage = attrNumber(part, "Damage", 15),
		lastHit = {},
	}
	table.insert(ctx.spinBars, bar)
	ensureHeartbeat(ctx)
	connect(ctx, part.Touched, function(hit)
		onSpinBarTouched(ctx, bar, hit)
	end)
	onStop(ctx, function()
		bar.lastHit = {}
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
		LightEmission = 0.25,
		LightInfluence = 0.6,
		Color = ColorSequence.new(Theme.Colors.CloudShade, Theme.Colors.Stamina),
		Size = NumberSequence.new(0.28),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.8, 0.3),
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
--   (default: half its footprint) is the damage radius. Red warning disc fills up for
--   `Warning` seconds, then a jagged Neon bolt hits and everyone in the disc is damaged.
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
		Color = WARNING_COLOR,
		Transparency = 0.5,
	})
	local fill = makePart({
		Name = "StrikeWarningFill",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.14, 0.4, 0.4),
		CFrame = flat,
		Color = WARNING_FILL_COLOR,
		Transparency = 0.3,
	})
	addTemp(ctx, ring, zone.warning + 3)
	addTemp(ctx, fill, zone.warning + 3)
	-- the inner disc grows to the full radius exactly when the bolt lands
	Util.Tween(fill, zone.warning, { Size = Vector3.new(0.14, diameter, diameter) },
		Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	-- the outer ring pulses so the danger reads at a glance
	TweenService:Create(ring, TweenInfo.new(0.22, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.15 }):Play()
	return ring, fill
end

local function strikeAt(ctx, zone, target)
	local rng = ctx.rng
	local radius = zone.radius

	-- 1. jagged bolt from the sky: a glow shell + a white core per segment
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
		local look = CFrame.new(a:Lerp(b, 0.5), b)
		local glow = makePart({
			Name = "BoltGlow",
			Size = Vector3.new(2.4, 2.4, length),
			CFrame = look,
			Color = BOLT_GLOW_COLOR,
			Transparency = 0.6,
		})
		local core = makePart({
			Name = "BoltCore",
			Size = Vector3.new(0.8, 0.8, length),
			CFrame = look,
			Color = BOLT_CORE_COLOR,
			Transparency = 0,
		})
		addTemp(ctx, glow, 1)
		addTemp(ctx, core, 1)
		Util.Tween(glow, 0.4, { Transparency = 1, Size = Vector3.new(0.6, 0.6, length) },
			Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Util.Tween(core, 0.4, { Transparency = 1, Size = Vector3.new(0.2, 0.2, length) },
			Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end

	-- 2. impact flash: expanding ground disc + a fading point light + a spark fountain
	local flash = makePart({
		Name = "StrikeFlash",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, radius * 2, radius * 2),
		CFrame = CFrame.new(target.X, target.Y + 0.25, target.Z) * CFrame.Angles(0, 0, math.pi / 2),
		Color = BOLT_CORE_COLOR,
		Transparency = 0.1,
	})
	addTemp(ctx, flash, 1)
	Util.Tween(flash, 0.45, { Size = Vector3.new(0.2, radius * 2.6, radius * 2.6), Transparency = 1 },
		Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local impact = makePart({
		Name = "StrikeImpact",
		Transparency = 1,
		Size = Vector3.new(1, 1, 1),
		CFrame = CFrame.new(target.X, target.Y + 1.5, target.Z),
	})
	local light = Instance.new("PointLight")
	light.Color = BOLT_CORE_COLOR
	light.Brightness = 9
	light.Range = Util.Clamp(radius * 5, 24, 48)
	light.Shadows = false
	light.Parent = impact
	local sparks = newEmitter({
		Name = "StrikeSparks",
		Rate = 0,
		Color = ColorSequence.new(BOLT_CORE_COLOR, BOLT_GLOW_COLOR),
		Lifetime = NumberRange.new(0.4, 0.8),
		Speed = NumberRange.new(20, 36),
		EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(70, 70),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
		Acceleration = Vector3.new(0, -60, 0),
	})
	sparks.Parent = impact
	addTemp(ctx, impact, 1.5)
	sparks:Emit(28)
	Util.Tween(light, 0.55, { Brightness = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

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
	local velocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(velocity.X, pad.power, velocity.Z)
	popPad(ctx, pad)
end

local function attachBouncePad(ctx, part)
	local pad = {
		part = part,
		power = attrNumber(part, "Power", 90),
		baseSize = part.Size,
		lastHit = {},
		tween = nil,
		burst = nil,
	}
	-- one reusable sparkle puff, fired on every bounce
	local burst = newEmitter({
		Name = "BounceBurst",
		Rate = 0,
		Color = ColorSequence.new(Theme.Colors.White, Theme.Colors.TokenGlow),
		Lifetime = NumberRange.new(0.4, 0.8),
		Speed = NumberRange.new(10, 22),
		EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(40, 40),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
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
