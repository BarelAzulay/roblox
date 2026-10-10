-- EvolutionFx (client): the evolution animation of a pet, played on this client only (its parts never exist on
-- the server, so nothing replicates). Used by the developer pet showcase (DevPetShow, "/evolve") and ready for the
-- game's own evolve button.
--
--   EvolutionFx.Play(fromModel, toModel, pose, opts) -> handle
--       fromModel  the pet as it is now: a PetBuilder model at rest (any stage), placed at `pose`
--       toModel    the evolved pet: a PetBuilder model at rest (parented to opts.Parent when it appears)
--       pose       CFrame of the pets' root (PrimaryPart) at rest: where both hover; LookVector = their facing
--       opts       { Parent = Instance for toModel and the effect parts (default workspace),
--                    Colors = { Color3, Color3 } (glow, sparks: PetBuilder.EvolutionColors),
--                    Stage = 1 | 2 (the stage reached; the second evolution is grander and longer),
--                    Ground = y of the floor under the pets (default: just under fromModel),
--                    OnDone = function(toModel) (called once, after the animation or Stop) }
--       handle     { Done = false/true, Model = the pet on show (fromModel, then toModel), Stop = function() }
--                  Stop() ends it at once: fromModel destroyed, toModel at rest at `pose`, the effects gone.
--   EvolutionFx.Duration(stage) -> seconds the animation lasts
--   EvolutionFx.Count() -> evolutions playing right now
--
-- The animation (stage 1 about 4.3 s, stage 2 about 5 s):
--   charge  the pet rises and spins faster and faster while it starts to glow (a Highlight), a ring of voxel runes
--           grows on the ground under it (two counter-rotating rings for the second evolution), glowing motes
--           spiral in and a pillar of light rises
--   burst   the pet shrinks into a white flash and the pillar flares
--   reveal  the evolved pet pops out of the flash (overshoot, then settles), spins down to face forward exactly
--           as it was, sinks back to its hover height; a shock ring races over the ground, voxel sparks burst out
--           and sparkles fly; the glow fades
-- Pets are moved and scaled by placing / resizing their parts from their rest offsets (workspace:BulkMoveTo), so
-- PetBuilder.Animate must not run on them meanwhile; at the end toModel is back at rest, ready for Animate.
-- One RenderStepped connection while anything plays; every effect part is anchored, CanCollide / CanTouch /
-- CanQuery off, CastShadow off. Plain Lua 5.1-compatible syntax only.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local EvolutionFx = {}

local TAU = math.pi * 2
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local WHITE = Color3.fromRGB(255, 255, 255)

local K = {
	CHARGE = { 2.0, 2.6 }, -- seconds of charging, per stage reached
	BURST = 0.38,
	REVEAL = 1.35,
	SETTLE = 0.6,
	RISE = 0.28, -- the pet rises this share of its height while charging
	SPIN = 4.5, -- turns per second at the end of the charge
	REVEAL_TURNS = 2, -- turns the evolved pet spins down through
	MIN_SCALE = 0.04,
	RUNES = { 20, 28 }, -- voxel runes in the ground ring
	MOTES = { 18, 28 },
	SPARKS = { 22, 34 },
	PILLAR = { 9, 12 }, -- pillar height in pet heights... capped below
	PILLAR_MAX = 60, -- studs
}

local plays = {}
local loopConn = nil

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function clamp01(x)
	if x < 0 then
		return 0
	elseif x > 1 then
		return 1
	end
	return x
end

local function smooth(x)
	x = clamp01(x)
	return x * x * (3 - 2 * x)
end

local function easeIn(x)
	x = clamp01(x)
	return x * x * x
end

local function easeOut(x)
	x = clamp01(x)
	local y = 1 - x
	return 1 - y * y * y
end

-- overshoots to about 1.1 and settles at 1
local function easeOutBack(x)
	x = clamp01(x)
	local c1 = 1.70158
	local c3 = c1 + 1
	local y = x - 1
	return 1 + c3 * y * y * y + c1 * y * y
end

local function lighten(c, t)
	return c:Lerp(WHITE, t)
end

-- a small deterministic "random" in [0, 1) per index
local function hash(i, salt)
	local h = math.sin(i * 12.9898 + (salt or 0) * 78.233) * 43758.5453
	return h - math.floor(h)
end

local function effectPart(play, name, shape, color, size)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Massless = true
	p.Material = Enum.Material.Neon
	p.Color = color
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.Parent = play.Folder
	return p
end

-- The pet's parts, their rest offsets from the root and their sizes.
local function rigOf(model)
	local root = model.PrimaryPart or model:FindFirstChild("Body")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local base = root.CFrame
	local rig = { Model = model, Root = root, Parts = {}, Pos = {}, Rot = {}, Size = {}, Scale = 1 }
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local rel = base:ToObjectSpace(d.CFrame)
			local n = #rig.Parts + 1
			rig.Parts[n] = d
			rig.Pos[n] = rel.Position
			rig.Rot[n] = rel - rel.Position
			rig.Size[n] = d.Size
		end
	end
	return rig
end

-- Places the pet with its root at cf, scaled by s around the root.
local function poseRig(rig, cf, s)
	if not rig or not rig.Model.Parent then
		return
	end
	local resize = s ~= rig.Scale
	local list = {}
	for i, part in ipairs(rig.Parts) do
		if resize then
			part.Size = rig.Size[i] * s
		end
		list[i] = cf * CFrame.new(rig.Pos[i] * s) * rig.Rot[i]
	end
	rig.Scale = s
	Workspace:BulkMoveTo(rig.Parts, list, Enum.BulkMoveMode.FireCFrameChanged)
end

-- Height, radius (half the larger horizontal size) and the offset from the root down to the pet's lowest point.
local function measure(rig)
	local lo, hi = math.huge, -math.huge
	local rx = 0
	local base = rig.Root.CFrame
	for i, part in ipairs(rig.Parts) do
		if part.Transparency < 1 then
			local p = rig.Pos[i]
			local half = rig.Size[i].Magnitude / 2
			lo = math.min(lo, p.Y - half)
			hi = math.max(hi, p.Y + half)
			rx = math.max(rx, math.abs(p.X) + half, math.abs(p.Z) + half)
		end
	end
	if lo == math.huge then
		return 3, 2, -1.5, base
	end
	return hi - lo, rx, lo, base
end

----------------------------------------------------------------------
-- One play
----------------------------------------------------------------------
local function ringPose(play, i, n, radius, turn, lift)
	local a = i / n * TAU + turn
	local c = play.Pose
	local centre = Vector3.new(c.Position.X, play.Ground + (lift or 0.06), c.Position.Z)
	local pos = centre + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
	return CFrame.new(pos) * CFrame.Angles(0, -a, 0)
end

local function buildEffects(play)
	local stage = play.Stage
	local c1, c2 = play.Colors[1], play.Colors[2]
	local R, H = play.Radius, play.Height
	local u = math.max(0.6, math.min(R, H) * 0.22) -- size unit of the voxel bits
	play.Unit = u
	-- glow on the pet
	local hl = Instance.new("Highlight")
	hl.Name = "EvolveGlow"
	hl.FillColor = lighten(c1, 0.35)
	hl.OutlineColor = lighten(c2, 0.5)
	hl.FillTransparency = 1
	hl.OutlineTransparency = 1
	hl.Adornee = play.From.Model
	hl.Parent = play.Folder
	play.Glow = hl
	-- the rune ring(s) on the ground
	play.Runes = {}
	local rings = (stage == 2) and 2 or 1
	for r = 1, rings do
		local n = K.RUNES[stage] - (r - 1) * 8
		for i = 1, n do
			local col = ((i + r) % 2 == 0) and c1 or c2
			local part = effectPart(play, "EvolveRune", nil, col, Vector3.new(u * 0.55, u * 0.14, u * ((i % 3 == 0) and 1.5 or 0.9)))
			part.Transparency = 1
			play.Runes[#play.Runes + 1] = { Part = part, I = i, N = n, Ring = r }
		end
	end
	-- motes that spiral in
	play.Motes = {}
	for i = 1, K.MOTES[stage] do
		local part = effectPart(play, "EvolveMote", nil, (i % 2 == 0) and c1 or c2, Vector3.new(u * 0.4, u * 0.4, u * 0.4))
		part.Transparency = 1
		play.Motes[i] = { Part = part, A = hash(i, 1) * TAU, Y = 0.15 + hash(i, 2) * 1.05, Delay = hash(i, 3) * 0.35 }
	end
	-- the pillar of light (a cylinder's axis is its X axis: turned upright)
	local pillar = effectPart(play, "EvolvePillar", Enum.PartType.Cylinder, lighten(c1, 0.45), Vector3.new(0.1, R * 1.4, R * 1.4))
	pillar.Transparency = 1
	play.Pillar = pillar
	play.PillarHeight = math.min(K.PILLAR_MAX, H * K.PILLAR[stage])
	local light = Instance.new("PointLight")
	light.Name = "EvolveLight"
	light.Color = lighten(c1, 0.3)
	light.Range = math.min(40, R * 4 + 8)
	light.Brightness = 0
	light.Parent = pillar
	play.Light = light
	-- the flash
	local flash = effectPart(play, "EvolveFlash", Enum.PartType.Ball, WHITE, Vector3.new(0.2, 0.2, 0.2))
	flash.Transparency = 1
	play.Flash = flash
	-- sparkles (emitted in bursts)
	local att = Instance.new("Attachment")
	att.Name = "EvolveSparkles"
	att.Parent = flash
	local em = Instance.new("ParticleEmitter")
	em.Name = "EvolveSparkles"
	em.Texture = SPARKLE
	em.Color = ColorSequence.new(lighten(c1, 0.3), lighten(c2, 0.3))
	em.LightEmission = 1
	em.LightInfluence = 0
	em.Rate = 0
	em.Lifetime = NumberRange.new(0.7, 1.4)
	em.Speed = NumberRange.new(R * 2.2, R * 4.4)
	em.SpreadAngle = Vector2.new(180, 180)
	em.Rotation = NumberRange.new(0, 360)
	em.RotSpeed = NumberRange.new(-180, 180)
	em.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.25, u * 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	em.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	em.Parent = att
	play.Emitter = em
	-- shock ring + sparks (shown at the reveal)
	play.Shock = {}
	for i = 1, 28 do
		local part = effectPart(play, "EvolveShock", nil, (i % 2 == 0) and lighten(c2, 0.2) or WHITE, Vector3.new(u * 0.5, u * 0.18, u * 1.4))
		part.Transparency = 1
		play.Shock[i] = part
	end
	play.Sparks = {}
	for i = 1, K.SPARKS[stage] do
		local part = effectPart(play, "EvolveSpark", nil, (i % 3 == 0) and WHITE or ((i % 2 == 0) and c1 or c2), Vector3.new(u * 0.45, u * 0.45, u * 0.45))
		part.Transparency = 1
		local a = hash(i, 5) * TAU
		local speed = R * (2.4 + hash(i, 6) * 2.2)
		play.Sparks[i] = {
			Part = part,
			V = Vector3.new(math.cos(a) * speed, R * (2.2 + hash(i, 7) * 2.6), math.sin(a) * speed),
			Spin = Vector3.new(hash(i, 8) * 9, hash(i, 9) * 9, hash(i, 10) * 9),
		}
	end
end

local function cleanup(play)
	if play.Folder then
		pcall(function()
			play.Folder:Destroy()
		end)
		play.Folder = nil
	end
end

local function finish(play)
	if play.Handle.Done then
		return
	end
	play.Handle.Done = true
	-- fromModel goes, toModel rests exactly at the pose (scale 1)
	if play.From and play.From.Model then
		pcall(function()
			play.From.Model:Destroy()
		end)
	end
	if play.To and play.To.Model then
		if not play.To.Model.Parent then
			play.To.Model.Parent = play.Parent
		end
		poseRig(play.To, play.Pose, 1)
	end
	play.Handle.Model = play.To and play.To.Model or nil
	cleanup(play)
	for i = #plays, 1, -1 do
		if plays[i] == play then
			table.remove(plays, i)
		end
	end
	if #plays == 0 and loopConn then
		loopConn:Disconnect()
		loopConn = nil
	end
	if type(play.OnDone) == "function" and play.To then
		local ok, err = pcall(play.OnDone, play.To.Model)
		if not ok then
			warn("[EvolutionFx] OnDone failed: " .. tostring(err))
		end
	end
end

local function step(play, dt)
	play.T = play.T + dt
	local t = play.T
	local c, b, r, s = play.Charge, K.BURST, K.REVEAL, K.SETTLE
	local pose, H, R, u = play.Pose, play.Height, play.Radius, play.Unit
	local rise = H * K.RISE
	local runeTurn = t * 0.9
	-- the rune rings: grow while charging, stay through the reveal, fade while settling
	local ringP = smooth(t / (c * 0.6))
	local ringFade = clamp01((t - (c + b + r)) / s)
	local runeList, cfs = {}, {}
	for _, rune in ipairs(play.Runes) do
		local radius = R * (0.45 + 0.75 * ringP) * ((rune.Ring == 2) and 0.68 or 1)
		local turn = (rune.Ring == 2) and -runeTurn * 1.4 or runeTurn
		runeList[#runeList + 1] = rune.Part
		cfs[#cfs + 1] = ringPose(play, rune.I, rune.N, radius, turn, (rune.Ring == 2) and 0.1 or 0.06)
		rune.Part.Transparency = 1 - ringP * 0.9 * (1 - ringFade)
	end
	if #runeList > 0 then
		Workspace:BulkMoveTo(runeList, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
	local centre = pose.Position + Vector3.new(0, rise * smooth(t / c), 0)
	if t < c then
		-- charge: rise, spin up, shake a little, glow; motes spiral in; the pillar rises
		local p = t / c
		play.Yaw = play.Yaw + dt * TAU * K.SPIN * p * p
		local shake = H * 0.015 * p * p
		local jx = (hash(math.floor(t * 30), 11) - 0.5) * shake
		local jz = (hash(math.floor(t * 30), 12) - 0.5) * shake
		poseRig(play.From, pose * CFrame.new(jx, rise * smooth(p), jz) * CFrame.Angles(0, play.Yaw, 0), 1)
		play.Glow.FillTransparency = 1 - 0.78 * smooth(p)
		play.Glow.OutlineTransparency = 1 - smooth(p * 1.4)
		local moteList, moteCfs = {}, {}
		for i, m in ipairs(play.Motes) do
			local q = clamp01((p - m.Delay) / (1 - m.Delay))
			local radius = R * 1.9 * (1 - easeIn(q)) + R * 0.1
			local a = m.A + q * TAU * 1.6
			local y = pose.Position.Y - H * 0.4 + H * m.Y * (1 - q * 0.5) + rise * smooth(p)
			moteList[i] = m.Part
			moteCfs[i] = CFrame.new(centre.X + math.cos(a) * radius, y, centre.Z + math.sin(a) * radius) * CFrame.Angles(t * 3 + i, t * 2, 0)
			m.Part.Transparency = (q > 0 and q < 0.98) and 0.05 or 1
		end
		Workspace:BulkMoveTo(moteList, moteCfs, Enum.BulkMoveMode.FireCFrameChanged)
		local ph = play.PillarHeight * smooth(p * 1.3)
		local w = R * (0.9 + 0.3 * p)
		play.Pillar.Size = Vector3.new(math.max(0.1, ph), w, w)
		play.Pillar.CFrame = CFrame.new(centre.X, play.Ground + ph / 2, centre.Z) * CFrame.Angles(0, 0, math.pi / 2)
		play.Pillar.Transparency = 1 - 0.38 * smooth(p * 1.5)
		play.Light.Brightness = 3 * p
	elseif t < c + b then
		-- burst: the pet shrinks into a white flash; the pillar flares
		if not play.BurstStarted then
			play.BurstStarted = true
			for _, m in ipairs(play.Motes) do
				m.Part.Transparency = 1
			end
		end
		local p = (t - c) / b
		play.Yaw = play.Yaw + dt * TAU * K.SPIN
		poseRig(play.From, pose * CFrame.new(0, rise, 0) * CFrame.Angles(0, play.Yaw, 0), math.max(K.MIN_SCALE, 1 - easeIn(p)))
		local fs = (R * 0.4 + R * 1.3 * easeOut(p)) * 2
		play.Flash.Size = Vector3.new(fs, fs, fs)
		play.Flash.CFrame = CFrame.new(centre)
		play.Flash.Transparency = 0.2 + 0.2 * p
		local w = R * (1.2 + 1.2 * easeOut(p))
		play.Pillar.Size = Vector3.new(play.PillarHeight, w, w)
		play.Pillar.Transparency = 0.55 + 0.45 * p
		play.Light.Brightness = 3 + 3 * p
	elseif t < c + b + r then
		-- reveal: swap the pets once, then the evolved pet pops out, spins down to face forward and sinks back
		if not play.Swapped then
			play.Swapped = true
			pcall(function()
				play.From.Model.Parent = nil
			end)
			play.To.Model.Parent = play.Parent
			play.Glow.Adornee = play.To.Model
			play.Glow.FillColor = WHITE
			play.Glow.FillTransparency = 0
			play.Glow.OutlineTransparency = 0
			play.Handle.Model = play.To.Model
			play.Pillar.Transparency = 1
			play.Emitter:Emit(play.Stage == 2 and 70 or 45)
			play.SparkT0 = t
		end
		local p = (t - c - b) / r
		local yaw = TAU * K.REVEAL_TURNS * easeOut(p)
		local scale = K.MIN_SCALE + (1 - K.MIN_SCALE) * easeOutBack(math.min(1, p * 1.25))
		poseRig(play.To, pose * CFrame.new(0, rise * (1 - smooth(p)), 0) * CFrame.Angles(0, yaw, 0), math.max(K.MIN_SCALE, scale))
		play.Glow.FillTransparency = smooth(p)
		play.Glow.OutlineTransparency = smooth(p * 0.8)
		local fs = R * 1.7 * 2 * (1 + 0.35 * p)
		play.Flash.Size = Vector3.new(fs, fs, fs)
		play.Flash.Transparency = 0.4 + 0.6 * smooth(p * 3)
		play.Light.Brightness = 6 * (1 - p)
	else
		-- settle: hold the pose while the effects fade, then finish
		poseRig(play.To, pose, 1)
		play.Glow.FillTransparency = 1
		play.Glow.OutlineTransparency = 1
		play.Flash.Transparency = 1
		play.Light.Brightness = 0
		if t >= c + b + r + s then
			finish(play)
			return
		end
	end
	-- the shock ring and the sparks (from the swap on)
	if play.SparkT0 then
		local q = t - play.SparkT0
		local shockP = clamp01(q / 0.85)
		local list, list2 = {}, {}
		for i, part in ipairs(play.Shock) do
			list[i] = part
			list2[i] = ringPose(play, i, #play.Shock, R * (0.8 + 2.4 * easeOut(shockP)), 0, 0.12)
			part.Transparency = (shockP < 1) and (0.1 + 0.9 * shockP) or 1
		end
		Workspace:BulkMoveTo(list, list2, Enum.BulkMoveMode.FireCFrameChanged)
		local sl, sc = {}, {}
		local base = pose.Position + Vector3.new(0, rise * 0.5, 0)
		for i, sp in ipairs(play.Sparks) do
			local pos = base + sp.V * q + Vector3.new(0, -0.5 * 26 * q * q, 0)
			if pos.Y < play.Ground + u * 0.2 then
				pos = Vector3.new(pos.X, play.Ground + u * 0.2, pos.Z)
			end
			sl[i] = sp.Part
			sc[i] = CFrame.new(pos) * CFrame.Angles(sp.Spin.X * q, sp.Spin.Y * q, sp.Spin.Z * q)
			sp.Part.Transparency = clamp01(q / 1.2)
		end
		Workspace:BulkMoveTo(sl, sc, Enum.BulkMoveMode.FireCFrameChanged)
	end
	play.Handle.T = t
end

local function onFrame(dt)
	for i = #plays, 1, -1 do
		local play = plays[i]
		if play then
			local ok, err = pcall(step, play, math.min(dt, 0.1))
			if not ok then
				warn("[EvolutionFx] " .. tostring(err))
				pcall(finish, play)
			end
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function EvolutionFx.Duration(stage)
	return K.CHARGE[(stage == 2) and 2 or 1] + K.BURST + K.REVEAL + K.SETTLE
end

function EvolutionFx.Count()
	return #plays
end

function EvolutionFx.Play(fromModel, toModel, pose, opts)
	opts = type(opts) == "table" and opts or {}
	local handle = { Done = false, Model = fromModel, T = 0 }
	local from = (typeof(fromModel) == "Instance") and rigOf(fromModel) or nil
	local to = (typeof(toModel) == "Instance") and rigOf(toModel) or nil
	if not (from and to) or typeof(pose) ~= "CFrame" then
		warn("[EvolutionFx] Play needs two PetBuilder models and a CFrame")
		handle.Done = true
		handle.Stop = function() end
		return handle
	end
	local stage = (opts.Stage == 2) and 2 or 1
	local colors = type(opts.Colors) == "table" and opts.Colors or {}
	local parent = (typeof(opts.Parent) == "Instance") and opts.Parent or Workspace
	local height, radius, low = measure(to)
	local play = {
		Handle = handle,
		From = from,
		To = to,
		Pose = pose,
		Stage = stage,
		Colors = {
			typeof(colors[1]) == "Color3" and colors[1] or Color3.fromRGB(255, 214, 90),
			typeof(colors[2]) == "Color3" and colors[2] or Color3.fromRGB(120, 200, 255),
		},
		Parent = parent,
		Charge = K.CHARGE[stage],
		Height = math.max(1, height),
		Radius = math.max(0.8, radius),
		Ground = (type(opts.Ground) == "number") and opts.Ground or (pose.Position.Y + low - 0.5),
		OnDone = opts.OnDone,
		T = 0,
		Yaw = 0,
	}
	local folder = Instance.new("Folder")
	folder.Name = "EvolutionFx"
	folder.Parent = parent
	play.Folder = folder
	toModel.Parent = nil
	poseRig(from, pose, 1)
	buildEffects(play)
	handle.Stop = function()
		pcall(finish, play)
	end
	plays[#plays + 1] = play
	if not loopConn then
		loopConn = RunService.RenderStepped:Connect(onFrame)
	end
	return handle
end

return EvolutionFx
