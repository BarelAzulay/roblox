-- PetController (client): every player's equipped pets fly beside their owner, Bee-Swarm style.
--
--   PetController.Init()
--   PetController.Stop()            -- tears everything down (tests / hot reload)
--   PetController.GetPetCount()     -- number of pet models currently alive (debug helper)
--
-- What it does
--   * Reads the player attribute `EquippedPets` (csv of pet ids, Config.Attr.EquippedPets) of EVERY player
--     and keeps one follower per player. Ids unknown to PetCatalog are ignored, at most
--     Config.Pets.MaxEquipped are used. All pets are drawn on this client only (workspace.ClientPets, one
--     Folder per owner named after the UserId); the server pays nothing.
--   * Each pet is a PetBuilder model that is moved with PivotTo + PetBuilder.Animate once per frame.
--     Pets hover in a loose formation (left / right / behind, ~4 studs out, at head height), bob and sway
--     with their own phase, ease towards their slot with an exponential filter (so they trail and catch up
--     naturally), face the direction the owner travels, bank into turns, pitch forward when they speed up,
--     flap harder when the owner runs or is in the air, and fly a little ahead of the owner while running.
--   * Owners that are downed keep their pets close; owners that teleport (> 35 studs in one step) or
--     respawn get their pets snapped back into formation. A pet that ends up > 60 studs from its slot snaps.
--   * Pets of OTHER players are only shown within 150 studs of the viewer (with a little hysteresis) and are
--     updated less often the further away they are (LOD). The local player's pets are always shown.
--   * Models are built lazily (at most two per frame), destroyed when the pet is unequipped, when the owner's
--     character is removed or when the player leaves, and parked (Parent = nil) while culled.
--
-- Performance: the per-frame code touches only numbers stored on long-lived tables, builds no tables or
-- closures, and creates exactly one CFrame per pet per update (the rotation matrix is written out by hand).
-- Everything is wrapped in pcall so one broken pet can never stop the others.
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local PetBuilder = require(Shared:WaitForChild("PetBuilder"))

local PetController = {}

local LocalPlayer = Players.LocalPlayer
local ATTR = Config.Attr
local PHYS = Config.Physics

local sin, cos, exp, sqrt, abs = math.sin, math.cos, math.exp, math.sqrt, math.abs
-- Luau and Lua 5.1 have math.atan2; Lua 5.3+ folds it into math.atan(y, x). Support both.
local atan2 = math.atan2 or function(y, x)
	return math.atan(y, x)
end
local PI = math.pi
local TAU = math.pi * 2

----------------------------------------------------------------------
-- Tuning (feel only)
----------------------------------------------------------------------
local FOLDER_NAME = "ClientPets"
local MAX_EQUIPPED = 3
if type(Config.Pets) == "table" and type(Config.Pets.MaxEquipped) == "number" then
	MAX_EQUIPPED = math.max(1, math.floor(Config.Pets.MaxEquipped))
end

-- Culling / level of detail (studs from the local player's character, or from the camera while it has
-- none; the local player's own pets ignore all of this)
local CULL_IN = 138 -- other players' pets appear inside this distance ...
local CULL_OUT = 150 -- ... and are parked beyond this one
local LOD_MID = 55 -- beyond this distance a follower is updated every 2nd frame
local LOD_FAR = 105 -- ... and beyond this one every 4th frame

-- Teleports and catch-up
local TELEPORT_STEP2 = 35 * 35 -- owner moved further than this in one update -> snap the formation
local SNAP_DIST2 = 60 * 60 -- a pet further than this from its slot snaps to it

-- Time steps
local MAX_DT = 0.1
local MIN_DT = 1 / 240
local ROOT_POLL = 0.25 -- seconds between searches for a missing HumanoidRootPart
local SLOW_TICK = 0.5 -- seconds between housekeeping checks per follower
local BUILDS_PER_FRAME = 2 -- pet models built per frame (a model is ~50 parts)
local BUILD_RETRY = 5 -- seconds before a failed build is tried again

-- Owner motion estimate
local VEL_RATE = 12 -- smoothing of the owner velocity (1/s)
local MAX_SPEED = 140 -- clamp for the instantaneous velocity (dash 85, cannons ~170)
local HEAD_MIN_SPEED = 3 -- below this the owner "faces" its LookVector instead of its velocity
local HEAD_RATE_MOVE = 4 -- how fast the formation swings round while the owner travels (1/s)
local HEAD_RATE_IDLE = 1.6 -- ... and while it stands still and turns on the spot
local RUN_K_FROM = 14 -- horizontal speed where the "running" factor starts ...
local RUN_K_SPAN = math.max(6, (PHYS and PHYS.RunSpeed or 27) - 14) -- ... and where it reaches 1
local RUN_RATE = 5
local AIR_RATE = 8
local DOWN_RATE = 4

-- Pet motion
local LEAD_H = 0.12 -- seconds of owner velocity added to the target (cancels most of the filter lag)
local LEAD_V = 0.05
local RUN_AHEAD = 4.0 -- studs the side pets move forward at full run speed
local RUN_RISE = 0.6 -- studs the pets rise at full run speed
local FACE_RATE = 7 -- pet yaw easing (1/s)
local TILT_RATE = 9 -- pitch / roll easing (1/s)
local BANK_GAIN = 0.1 -- radians of roll per radian/second of yaw rate
local BANK_MAX = 0.55
local PITCH_GAIN = 0.0125 -- radians of nose-down pitch per stud/second of forward speed

-- Slots: { side (+ = owner's right), up (above the HumanoidRootPart), back (behind the owner), ahead (0..1) }.
-- The HumanoidRootPart is ~3 studs above the floor, so +2 puts a pet's body at head height.
local FORMATION = {
	[1] = { { 4.0, 2.3, 1.4, 1.0 } },
	[2] = { { -4.0, 2.0, 1.3, 1.0 }, { 4.0, 2.6, 1.3, 1.0 } },
	[3] = { { -4.2, 1.9, 0.6, 1.0 }, { 4.2, 2.5, 0.6, 1.0 }, { 0.0, 3.2, 4.0, 0.3 } },
}

local BUILD_OPTS = { Scale = 1 }

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local initialized = false
local petsFolder = nil -- workspace.ClientPets
local followers = {} -- [Player] = follower
local order = {} -- array of followers (swap-remove), iterated every frame
local followerCount = 0
local localFollower = nil -- the follower of LocalPlayer (reference point for culling)
local renderConn = nil
local playerConns = {}
local frameIndex = 0
local buildBudget = 0
local nextFolderCheck = 0
local warnedAt = {} -- [key] = os.clock() of the last warning (rate limit)

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function clamp(x, lo, hi)
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

-- Shortest signed difference of two angles, in [-PI, PI).
local function wrapAngle(a)
	return (a + PI) % TAU - PI
end

local function warnLimited(key, message)
	local now = os.clock()
	local last = warnedAt[key]
	if last == nil or now - last > 10 then
		warnedAt[key] = now
		warn("[PetController] " .. tostring(message))
	end
end

local function ensurePetsFolder()
	if petsFolder and petsFolder.Parent == workspace then
		return petsFolder
	end
	local existing = workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		petsFolder = existing
	else
		petsFolder = Instance.new("Folder")
		petsFolder.Name = FOLDER_NAME
		petsFolder.Parent = workspace
	end
	return petsFolder
end

----------------------------------------------------------------------
-- Slots
----------------------------------------------------------------------
-- side, up, back, ahead for pet `i` of `n` (a generic fan for unusual MaxEquipped values).
local function slotOffsets(n, i)
	local set = FORMATION[n]
	local s = set and set[i]
	if s then
		return s[1], s[2], s[3], s[4]
	end
	local a = ((i - 0.5) / n - 0.5) * 2.4 -- -1.2 .. +1.2 radians
	local side = sin(a) * 4.4
	local back = 1.0 + (1 - cos(a)) * 3.0
	local up = 1.9 + (i % 3) * 0.55
	local ahead = 0.3 + 0.7 * abs(sin(a))
	return side, up, back, ahead
end

local function assignSlots(f)
	local n = f.n
	for i = 1, n do
		local p = f.pets[i]
		p.slot = i
		p.side, p.up, p.back, p.ahead = slotOffsets(n, i)
	end
end

----------------------------------------------------------------------
-- Pet records and models
----------------------------------------------------------------------
local function newPetRecord(def)
	local rnd = math.random
	return {
		def = def,
		id = def.Id,
		model = nil,
		slot = 1,
		side = 0,
		up = 2,
		back = 1,
		ahead = 1,
		lift = 0, -- extra hover for tall pets
		-- personality (so a group never moves in lockstep)
		phase = rnd() * TAU,
		phase2 = rnd() * TAU,
		bobRate = 2.3 + rnd() * 1.1,
		bobAmp = 0.34 + rnd() * 0.16,
		swayRate = 0.8 + rnd() * 0.6,
		swayAmp = 0.35 + rnd() * 0.3,
		rateH = 5.6 + rnd() * 2.0,
		rateV = 7.5 + rnd() * 2.5,
		flapVar = 0.9 + rnd() * 0.25,
		yawBias = (rnd() - 0.5) * 0.3,
		-- motion state
		x = 0,
		y = 0,
		z = 0,
		yaw = 0,
		pitch = 0,
		roll = 0,
		fresh = 1, -- 0 settled, 1 snap into the slot, 2 emerge from the owner
		retryAt = 0,
		animFails = 0,
		opts = { Flap = 1, Excited = 0 }, -- reused every frame for PetBuilder.Animate
	}
end

local function destroyPetModel(p)
	local model = p.model
	p.model = nil
	if model then
		pcall(model.Destroy, model)
	end
end

-- Builds the model of one pet (inside pcall: a broken definition must not take the controller down).
local function buildModel(f, p)
	local ok, model = pcall(PetBuilder.Build, p.def, BUILD_OPTS)
	if not ok or typeof(model) ~= "Instance" then
		p.retryAt = os.clock() + BUILD_RETRY
		warnLimited("build_" .. tostring(p.id), "could not build pet " .. tostring(p.id) .. ": " .. tostring(model))
		return
	end
	-- taller pets hover a little higher so every species sits at a similar height beside the owner
	local okSize, size = pcall(model.GetExtentsSize, model)
	if okSize and typeof(size) == "Vector3" then
		p.lift = clamp((size.Y - 2.7) * 0.35, -0.4, 0.6)
	end
	p.model = model
	p.animFails = 0
	model.Parent = f.folder
end

----------------------------------------------------------------------
-- Follower lifecycle
----------------------------------------------------------------------
local function newFollower(player)
	local folder = Instance.new("Folder")
	folder.Name = tostring(player.UserId)
	return {
		player = player,
		userId = player.UserId,
		isLocal = (player == LocalPlayer),
		folder = folder,
		visible = false,
		pets = {},
		n = 0,
		csv = "",
		applied = false,
		char = nil,
		root = nil,
		conns = {},
		index = 0,
		downed = false,
		established = false,
		failures = 0,
		disabled = false,
		nextRootCheck = 0,
		nextSlow = 0,
		accDt = 0,
		resetPending = true,
		-- owner motion estimate
		ox = 0,
		oy = 0,
		oz = 0,
		vx = 0,
		vy = 0,
		vz = 0,
		runK = 0,
		airK = 0,
		downK = 0,
		headYaw = 0,
	}
end

local function snapAllPets(f)
	for i = 1, f.n do
		f.pets[i].fresh = 1
	end
end

-- Shows / parks the follower's folder. Positions are stale after being parked, so snap on show.
local function setVisible(f, visible)
	if f.visible == visible then
		return
	end
	f.visible = visible
	if visible then
		f.folder.Parent = ensurePetsFolder()
		f.resetPending = true
		f.accDt = 0
		snapAllPets(f)
	else
		f.folder.Parent = nil
	end
end

-- The owner has no character (died, respawning, left): pets are destroyed and rebuilt for the new one.
local function releaseCharacter(f)
	f.root = nil
	f.char = nil
	f.established = false
	f.nextRootCheck = 0
	setVisible(f, false)
	for i = 1, f.n do
		local p = f.pets[i]
		destroyPetModel(p)
		p.fresh = 1
	end
end

local function acquireRoot(f)
	local char = f.player.Character
	if not char then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or not root.Parent then
		return
	end
	f.root = root
	f.char = char
	local pos = root.Position
	f.ox, f.oy, f.oz = pos.X, pos.Y, pos.Z
	f.vx, f.vy, f.vz = 0, 0, 0
	f.runK, f.airK, f.downK = 0, 0, 0
	f.resetPending = true
	f.accDt = 0
	local look = root.CFrame.LookVector
	f.headYaw = atan2(-look.X, -look.Z)
	snapAllPets(f)
end

-- Rebuilds the pet list from the player's attribute: keeps matching pets, destroys the rest, adds new ones.
local function applyEquipped(f)
	local csv = f.player:GetAttribute(ATTR.EquippedPets)
	if type(csv) ~= "string" then
		csv = ""
	end
	if f.applied and csv == f.csv then
		return
	end
	f.applied = true
	f.csv = csv

	local wanted = {}
	for token in string.gmatch(csv, "[^,]+") do
		local id = string.match(token, "^%s*(.-)%s*$")
		local def = PetCatalog.Get(id)
		if def and #wanted < MAX_EQUIPPED then
			wanted[#wanted + 1] = def
		end
	end

	local old = f.pets
	local used = {}
	local pets = {}
	for i = 1, #wanted do
		local def = wanted[i]
		local found = nil
		for j = 1, #old do
			if not used[j] and old[j].id == def.Id then
				used[j] = true
				found = old[j]
				break
			end
		end
		if not found then
			found = newPetRecord(def)
			-- a pet equipped while its owner is already flying around emerges from the owner
			if f.established then
				found.fresh = 2
			end
		end
		pets[i] = found
	end
	for j = 1, #old do
		if not used[j] then
			destroyPetModel(old[j])
		end
	end
	f.pets = pets
	f.n = #pets
	assignSlots(f)
end

local function destroyFollower(f)
	for i = 1, #f.conns do
		pcall(f.conns[i].Disconnect, f.conns[i])
	end
	f.conns = {}
	for i = 1, #f.pets do
		destroyPetModel(f.pets[i])
	end
	f.pets = {}
	f.n = 0
	f.root = nil
	f.char = nil
	local folder = f.folder
	f.folder = nil
	f.visible = false
	if folder then
		pcall(folder.Destroy, folder)
	end
end

local function removeFollower(player)
	local f = followers[player]
	if not f then
		return
	end
	followers[player] = nil
	if localFollower == f then
		localFollower = nil
	end
	local idx = f.index
	local last = order[followerCount]
	if last ~= f then
		order[idx] = last
		last.index = idx
	end
	order[followerCount] = nil
	followerCount = followerCount - 1
	destroyFollower(f)
end

local function trackPlayer(player)
	if followers[player] then
		return
	end
	local f = newFollower(player)
	followers[player] = f
	if f.isLocal then
		localFollower = f
	end
	followerCount = followerCount + 1
	f.index = followerCount
	order[followerCount] = f

	local conns = f.conns
	conns[#conns + 1] = player:GetAttributeChangedSignal(ATTR.EquippedPets):Connect(function()
		applyEquipped(f)
	end)
	conns[#conns + 1] = player:GetAttributeChangedSignal(ATTR.Downed):Connect(function()
		f.downed = player:GetAttribute(ATTR.Downed) == true
	end)
	conns[#conns + 1] = player.CharacterAdded:Connect(function()
		f.nextRootCheck = 0 -- look for the new HumanoidRootPart on the next frame
	end)
	conns[#conns + 1] = player.CharacterRemoving:Connect(function(char)
		if f.char == char then
			releaseCharacter(f)
		end
	end)

	f.downed = player:GetAttribute(ATTR.Downed) == true
	applyEquipped(f)
end

----------------------------------------------------------------------
-- Per-frame update
----------------------------------------------------------------------
-- Advances one follower by dt seconds. `viewPos` is where the viewer is (Vector3 or nil).
local function stepFollower(f, dt, now, viewPos)
	-- 1. owner root ------------------------------------------------------------------------------
	local root = f.root
	if root and not root.Parent then
		releaseCharacter(f)
		root = nil
	end
	if not root then
		if now >= f.nextRootCheck then
			f.nextRootCheck = now + ROOT_POLL
			acquireRoot(f)
			root = f.root
		end
		if not root then
			return
		end
	end

	-- 2. housekeeping a few times per second ---------------------------------------------------
	if now >= f.nextSlow then
		f.nextSlow = now + SLOW_TICK + (f.index % 5) * 0.02
		if f.player.Character ~= f.char then
			releaseCharacter(f) -- the character was replaced; the next poll picks up the new one
			return
		end
		if f.visible and f.folder.Parent ~= petsFolder then
			f.folder.Parent = ensurePetsFolder()
		end
	end

	local rootPos = root.Position
	local px, py, pz = rootPos.X, rootPos.Y, rootPos.Z
	if px ~= px or py ~= py or pz ~= pz then
		return -- a broken (NaN) character position: wait for it to recover instead of poisoning the pets
	end

	-- 3. culling + level of detail -------------------------------------------------------------
	if f.isLocal then
		if not f.visible then
			setVisible(f, true)
		end
	else
		local dist = 0
		if viewPos then
			local cx, cy, cz = px - viewPos.X, py - viewPos.Y, pz - viewPos.Z
			dist = sqrt(cx * cx + cy * cy + cz * cz)
		end
		if f.visible then
			if dist > CULL_OUT then
				setVisible(f, false)
				return
			end
		else
			if dist > CULL_IN then
				return
			end
			setVisible(f, true)
		end
		local stride = 1
		if dist > LOD_FAR then
			stride = 4
		elseif dist > LOD_MID then
			stride = 2
		end
		f.accDt = f.accDt + dt
		if stride > 1 and (frameIndex + f.index) % stride ~= 0 then
			return
		end
		dt = f.accDt
		f.accDt = 0
		if dt > MAX_DT then
			dt = MAX_DT
		end
	end
	if dt < MIN_DT then
		dt = MIN_DT
	end

	-- 4. owner motion estimate ---------------------------------------------------------------------
	local dx, dy, dz = px - f.ox, py - f.oy, pz - f.oz
	f.ox, f.oy, f.oz = px, py, pz
	local teleported = f.resetPending
	f.resetPending = false
	if dx * dx + dy * dy + dz * dz > TELEPORT_STEP2 then
		teleported = true
	end
	if teleported then
		f.vx, f.vy, f.vz = 0, 0, 0
		snapAllPets(f)
	else
		local kv = 1 - exp(-VEL_RATE * dt)
		f.vx = f.vx + (clamp(dx / dt, -MAX_SPEED, MAX_SPEED) - f.vx) * kv
		f.vy = f.vy + (clamp(dy / dt, -MAX_SPEED, MAX_SPEED) - f.vy) * kv
		f.vz = f.vz + (clamp(dz / dt, -MAX_SPEED, MAX_SPEED) - f.vz) * kv
	end
	local vx, vz = f.vx, f.vz
	local hs = sqrt(vx * vx + vz * vz)

	-- formation heading: travel direction, or the owner's facing when standing still
	local targetHead = f.headYaw
	local headRate = HEAD_RATE_IDLE
	if hs > HEAD_MIN_SPEED then
		targetHead = atan2(-vx, -vz)
		headRate = HEAD_RATE_MOVE
	else
		local look = root.CFrame.LookVector
		if look.X * look.X + look.Z * look.Z > 0.04 then
			targetHead = atan2(-look.X, -look.Z)
		end
	end
	if teleported then
		f.headYaw = targetHead
	else
		f.headYaw = wrapAngle(f.headYaw + wrapAngle(targetHead - f.headYaw) * (1 - exp(-headRate * dt)))
	end

	local runTarget = clamp((hs - RUN_K_FROM) / RUN_K_SPAN, 0, 1.3)
	f.runK = f.runK + (runTarget - f.runK) * (1 - exp(-RUN_RATE * dt))
	local airTarget = clamp((abs(f.vy) - 8) / 30, 0, 1)
	f.airK = f.airK + (airTarget - f.airK) * (1 - exp(-AIR_RATE * dt))
	local downTarget = 0
	if f.downed then
		downTarget = 1
	end
	f.downK = f.downK + (downTarget - f.downK) * (1 - exp(-DOWN_RATE * dt))

	local runK, airK, downK = f.runK, f.airK, f.downK
	local flapBase = 1 + 0.75 * runK + 0.9 * airK
	local excited = clamp(0.55 * runK + 0.75 * airK, 0, 1)
	if downK > 0 then
		flapBase = flapBase * (1 - 0.4 * downK)
		excited = excited * (1 - downK)
	end
	local compact = 1 - 0.45 * downK -- downed owners keep their pets close
	local leadX, leadZ = vx * LEAD_H, vz * LEAD_H
	local leadY = clamp(f.vy * LEAD_V, -1, 1.5)

	local face = f.headYaw
	local sh, ch = sin(face), cos(face)
	local rx, rz = ch, -sh -- owner's right (horizontal)
	local fx, fz = -sh, -ch -- owner's forward (horizontal)

	-- 5. pets ----------------------------------------------------------------------------------------
	local pets = f.pets
	for i = 1, f.n do
		local p = pets[i]
		local model = p.model
		if not model and buildBudget > 0 and now >= p.retryAt then
			buildBudget = buildBudget - 1
			buildModel(f, p)
			model = p.model
		end
		if model then
			-- target position in the owner's frame
			local bob = sin(now * p.bobRate + p.phase) * p.bobAmp * (1 - 0.5 * downK)
			local sway = sin(now * p.swayRate + p.phase2) * p.swayAmp
			local side = p.side * compact + sway
			local fwd = p.ahead * RUN_AHEAD * runK - p.back * compact
			local tx = px + rx * side + fx * fwd + leadX
			local tz = pz + rz * side + fz * fwd + leadZ
			local ty = py + p.up * (1 - 0.2 * downK) + p.lift + bob + (1.2 - p.ahead) * RUN_RISE * runK + leadY

			if p.fresh ~= 0 then
				if p.fresh == 2 then
					p.x, p.y, p.z = px, py + 0.5, pz -- emerge from the owner's chest
				else
					p.x, p.y, p.z = tx, ty, tz
				end
				p.yaw = face
				p.pitch, p.roll = 0, 0
				p.fresh = 0
			end

			local ox, oy, oz = p.x, p.y, p.z
			local ex, ey, ez = tx - ox, ty - oy, tz - oz
			if ex * ex + ey * ey + ez * ez > SNAP_DIST2 then
				ox, oy, oz = tx, ty, tz
				ex, ey, ez = 0, 0, 0
				p.yaw = face
			end
			local kh = 1 - exp(-p.rateH * dt)
			local kvv = 1 - exp(-p.rateV * dt)
			local nx, ny, nz = ox + ex * kh, oy + ey * kvv, oz + ez * kh
			p.x, p.y, p.z = nx, ny, nz
			local pvx, pvz = (nx - ox) / dt, (nz - oz) / dt

			-- facing, banking, pitch
			local yawOld = p.yaw
			local wobble = 0.1 * sin(now * 0.9 + p.phase2)
			local yawStep = wrapAngle(face + p.yawBias + wobble - yawOld) * (1 - exp(-FACE_RATE * dt))
			local yaw = wrapAngle(yawOld + yawStep)
			p.yaw = yaw
			local syw, cyw = sin(yaw), cos(yaw)
			local forwardSpeed = -pvx * syw - pvz * cyw
			local lateralSpeed = pvx * cyw - pvz * syw
			local pitchT = -clamp(forwardSpeed * PITCH_GAIN, -0.28, 0.42)
			local rollT = clamp(yawStep / dt * BANK_GAIN, -BANK_MAX, BANK_MAX)
				- clamp(lateralSpeed * 0.015, -0.3, 0.3)
				+ 0.05 * sin(now * 1.3 + p.phase)
			local kt = 1 - exp(-TILT_RATE * dt)
			local pitch = p.pitch + (pitchT - p.pitch) * kt
			local roll = p.roll + (rollT - p.roll) * kt
			p.pitch, p.roll = pitch, roll

			if nx == nx and ny == ny and nz == nz and pitch == pitch and roll == roll and yaw == yaw then
				-- rotation = Ry(yaw) * Rx(pitch) * Rz(roll), written out so only one CFrame is created
				local spt, cpt = sin(pitch), cos(pitch)
				local srl, crl = sin(roll), cos(roll)
				model:PivotTo(CFrame.new(
					nx, ny, nz,
					cyw * crl + syw * spt * srl, -cyw * srl + syw * spt * crl, syw * cpt,
					cpt * srl, cpt * crl, -spt,
					-syw * crl + cyw * spt * srl, syw * srl + cyw * spt * crl, cyw * cpt
				))

				if p.animFails < 3 then
					local o = p.opts
					o.Flap = flapBase * p.flapVar
					o.Excited = excited
					local okAnim = pcall(PetBuilder.Animate, model, now, o)
					if not okAnim then
						p.animFails = p.animFails + 1
					end
				end
			else
				-- numerical accident: restart this pet's motion from its slot on the next update
				p.fresh = 1
			end
		end
	end
	f.established = true
end

local function onRender(dt)
	local count = followerCount
	if count == 0 then
		return
	end
	frameIndex = frameIndex + 1
	buildBudget = BUILDS_PER_FRAME
	if dt > MAX_DT then
		dt = MAX_DT
	end
	local now = os.clock()
	if now >= nextFolderCheck then
		nextFolderCheck = now + 2
		ensurePetsFolder()
	end
	-- the viewer: the local character, else the camera
	local viewPos = nil
	local lf = localFollower
	if lf and lf.root and lf.root.Parent then
		viewPos = lf.root.Position
	else
		local camera = workspace.CurrentCamera
		if camera then
			viewPos = camera.CFrame.Position
		end
	end
	for i = 1, count do
		local f = order[i]
		if f and not f.disabled then
			local ok, err = pcall(stepFollower, f, dt, now, viewPos)
			if ok then
				f.failures = 0
			else
				f.failures = f.failures + 1
				warnLimited("step_" .. tostring(f.userId), "update failed: " .. tostring(err))
				if f.failures >= 10 then
					-- give up on this owner's pets rather than erroring every frame
					f.disabled = true
					releaseCharacter(f)
				end
			end
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function PetController.GetPetCount()
	local total = 0
	for i = 1, followerCount do
		local f = order[i]
		for j = 1, f.n do
			if f.pets[j].model then
				total = total + 1
			end
		end
	end
	return total
end

function PetController.Stop()
	if not initialized then
		return
	end
	initialized = false
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	for i = 1, #playerConns do
		playerConns[i]:Disconnect()
	end
	playerConns = {}
	local list = {}
	for player in pairs(followers) do
		list[#list + 1] = player
	end
	for i = 1, #list do
		removeFollower(list[i])
	end
	if petsFolder then
		pcall(petsFolder.Destroy, petsFolder)
		petsFolder = nil
	end
end

function PetController.Init()
	if initialized then
		return
	end
	if not LocalPlayer then
		return
	end
	initialized = true

	-- a folder left over from an earlier run (hot reload) would hold orphaned models
	local old = workspace:FindFirstChild(FOLDER_NAME)
	if old then
		old:Destroy()
	end
	petsFolder = nil
	ensurePetsFolder()

	playerConns[#playerConns + 1] = Players.PlayerAdded:Connect(trackPlayer)
	playerConns[#playerConns + 1] = Players.PlayerRemoving:Connect(removeFollower)
	for _, player in ipairs(Players:GetPlayers()) do
		trackPlayer(player)
	end

	renderConn = RunService.RenderStepped:Connect(onRender)
end

return PetController
