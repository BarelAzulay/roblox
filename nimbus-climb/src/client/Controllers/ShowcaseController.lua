-- ShowcaseController (client): brings the big showcase pets to life (ARCHITECTURE_V3.md section 10), e.g. the
-- StormfangShowcase on the Storm Altar.
--
--   ShowcaseController.Init()
--   ShowcaseController.Count() -> number of showcases being animated
--
-- Every model tagged "NC_Showcase" (also ones added later) gets, on this client only (the server never moves it):
--   * a gentle hover bob with a slow sway and roll around the pose the server built (attribute HoverAmp = studs)
--   * PetBuilder.Animate when the model carries a PetBuilder rig (attribute PB_Rig): the storm cloud drifts, the
--     tail sways, the eyes blink and the rig's own neon accents (PB_Pulse) breathe
--   * a soft pulse of every other Neon part (transparency), restored when the showcase stops
-- Cheap like the NPC idles: once the model has fully replicated (attributes Ready + PetParts), its static parts
-- are welded locally to the anchored PrimaryPart, so a pose is ONE CFrame write plus the animated groups.
-- Showcases further than CULL studs from the camera are frozen, past NEAR they update every other frame.
-- One RenderStepped connection, only while there is something to animate; nothing is created per frame.
-- Removing the model (or its tag) stops its animation cleanly. Plain Lua 5.1-compatible syntax only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local function optionalShared(name)
	local module = Shared:FindFirstChild(name) or Shared:WaitForChild(name, 5)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[ShowcaseController] failed to load " .. name .. ": " .. tostring(result))
	return nil
end

local PetBuilder = optionalShared("PetBuilder")

local ShowcaseController = {}

local TAG = "NC_Showcase"
local TAU = math.pi * 2

local K = {
	CULL = 300, -- frozen beyond this distance from the camera
	NEAR = 120, -- every other frame beyond this
	BOB_AMP = 0.45, -- studs (attribute HoverAmp overrides)
	BOB_PERIOD = 3.8, -- seconds
	SWAY = math.rad(4), -- slow yaw sway
	ROLL = math.rad(1.4),
	FLAP = 0.55, -- PetBuilder.Animate speed: a slow drift of the storm cloud
	PULSE = 0.22, -- neon transparency swing
	PULSE_RATE = 1.9, -- radians per second
	MAX_PULSE = 80, -- neon parts pulsed per showcase (cost cap)
	READY_TIMEOUT = 15,
}

local recs = {} -- list of records
local byModel = {} -- [model] = record
local pending = {} -- [model] = true while waiting for it to replicate
local loopConn = nil
local clock = 0
local initialized = false

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function countParts(model)
	local n = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			n = n + 1
		end
	end
	return n
end

local function isComplete(model)
	if model:GetAttribute("Ready") ~= true then
		return false
	end
	local wanted = model:GetAttribute("PetParts")
	if type(wanted) ~= "number" then
		return true
	end
	return countParts(model) >= wanted
end

local function rootOf(model)
	local root = model.PrimaryPart or model:FindFirstChild("Body")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Parts PetBuilder.Animate re-poses every call (wings / cloud halves, tail, halo, aura). Eyelids only change
-- their transparency, so they are welded like everything else.
local function isAnimatedPart(part)
	local spec = part:GetAttribute("PB_G")
	if type(spec) ~= "string" then
		return false
	end
	local kind = string.match(spec, "^[^:]*:([^:]*)")
	return kind ~= "lid"
end

----------------------------------------------------------------------
-- Records
----------------------------------------------------------------------
local function weldPart(rec, part)
	if part == rec.Root or rec.Animated[part] or part:FindFirstChild("ShowcaseWeld") then
		return
	end
	local weld = Instance.new("Weld")
	weld.Name = "ShowcaseWeld"
	weld.Part0 = rec.Root
	weld.Part1 = part
	weld.C0 = rec.Base:Inverse() * part.CFrame
	weld.C1 = CFrame.new()
	weld.Parent = part
	rec.Welds[#rec.Welds + 1] = weld
	if part.Anchored then
		part.Anchored = false
		rec.Unanchored[#rec.Unanchored + 1] = part
	end
end

local function addNeon(rec, part)
	if #rec.Neon >= K.MAX_PULSE or part.Material ~= Enum.Material.Neon then
		return
	end
	-- the rig's own accents (PB_Pulse) breathe through PetBuilder.Animate already
	if rec.Animate and part:GetAttribute("PB_Pulse") ~= nil then
		return
	end
	rec.Neon[#rec.Neon + 1] = { Part = part, T0 = part.Transparency }
end

-- Puts the model back the way the server built it (tag removed while the model stays).
local function restore(rec)
	pcall(function()
		for _, weld in ipairs(rec.Welds) do
			weld:Destroy()
		end
		for _, part in ipairs(rec.Unanchored) do
			if part.Parent then
				part.Anchored = true
			end
		end
		for _, n in ipairs(rec.Neon) do
			if n.Part.Parent then
				n.Part.Transparency = n.T0
			end
		end
		if rec.Root and rec.Root.Parent then
			rec.Root.CFrame = rec.Base
		end
	end)
	rec.Welds, rec.Unanchored = {}, {}
end

local function stopLoopIfIdle()
	if #recs == 0 and loopConn then
		loopConn:Disconnect()
		loopConn = nil
	end
end

local function removeRec(rec, putBack)
	for i = #recs, 1, -1 do
		if recs[i] == rec then
			table.remove(recs, i)
		end
	end
	if rec.Model and byModel[rec.Model] == rec then
		byModel[rec.Model] = nil
	end
	for _, conn in ipairs(rec.Conns) do
		conn:Disconnect()
	end
	rec.Conns = {}
	if putBack and rec.Model and rec.Model.Parent then
		restore(rec)
	end
	stopLoopIfIdle()
end

local ensureLoop -- forward declaration

local function setup(model, complete)
	if byModel[model] or not model.Parent then
		return
	end
	local root = rootOf(model)
	if not root then
		return
	end
	local amp = model:GetAttribute("HoverAmp")
	if type(amp) ~= "number" or amp ~= amp then
		amp = K.BOB_AMP
	end
	local rec = {
		Model = model,
		Root = root,
		Base = root.CFrame,
		Amp = math.max(0, math.min(amp, 3)),
		Phase = (#recs * 1.73) % TAU,
		Frame = 0,
		Animate = PetBuilder ~= nil and type(PetBuilder.Animate) == "function" and model:GetAttribute("PB_Rig") ~= nil,
		AnimOpts = { Flap = K.FLAP, Excited = 0 },
		Animated = {},
		Welds = {},
		Unanchored = {},
		Neon = {},
		Conns = {},
		Welded = false,
	}
	local parts = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			parts[#parts + 1] = d
			if rec.Animate and isAnimatedPart(d) then
				rec.Animated[d] = true
			end
		end
	end
	for _, part in ipairs(parts) do
		addNeon(rec, part)
	end
	-- weld the static parts (only when the whole model is here; otherwise PivotTo moves whatever exists)
	if complete then
		local ok, err = pcall(function()
			for _, part in ipairs(parts) do
				weldPart(rec, part)
			end
			root.Anchored = true
		end)
		rec.Welded = ok
		if not ok then
			warn("[ShowcaseController] could not weld a showcase, using PivotTo: " .. tostring(err))
			restore(rec)
		end
	end
	recs[#recs + 1] = rec
	byModel[model] = rec

	-- parts that stream in later join the rig
	rec.Conns[#rec.Conns + 1] = model.DescendantAdded:Connect(function(d)
		if not d:IsA("BasePart") or byModel[model] ~= rec then
			return
		end
		if rec.Animate and isAnimatedPart(d) then
			rec.Animated[d] = true
		elseif rec.Welded then
			pcall(weldPart, rec, d)
		end
		addNeon(rec, d)
	end)
	rec.Conns[#rec.Conns + 1] = model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(game) and byModel[model] == rec then
			removeRec(rec, false)
		end
	end)
	ensureLoop()
end

local function track(model)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end
	if byModel[model] or pending[model] then
		return
	end
	pending[model] = true
	task.spawn(function()
		local waited = 0
		while waited < K.READY_TIMEOUT and model.Parent and not isComplete(model) do
			task.wait(0.25)
			waited = waited + 0.25
		end
		pending[model] = nil
		if model.Parent and CollectionService:HasTag(model, TAG) then
			local ok, err = pcall(setup, model, isComplete(model))
			if not ok then
				warn("[ShowcaseController] showcase setup failed: " .. tostring(err))
			end
		end
	end)
end

----------------------------------------------------------------------
-- Animation
----------------------------------------------------------------------
local function pose(rec)
	local t = clock + rec.Phase
	local y = math.sin(t * TAU / K.BOB_PERIOD) * rec.Amp
	local yaw = math.sin(t * 0.37) * K.SWAY
	local roll = math.sin(t * 0.83) * K.ROLL
	local cf = rec.Base * CFrame.new(0, y, 0) * CFrame.Angles(0, yaw, roll)
	if rec.Welded then
		rec.Root.CFrame = cf
	else
		rec.Model:PivotTo(cf)
	end
	if rec.Animate then
		local ok = pcall(PetBuilder.Animate, rec.Model, clock, rec.AnimOpts)
		if not ok then
			rec.Animate = false -- a broken rig: keep the hover and the pulse only
		end
	end
	local neon = rec.Neon
	if #neon > 0 then
		local k = K.PULSE * (0.5 + 0.5 * math.sin(t * K.PULSE_RATE))
		for i = 1, #neon do
			local n = neon[i]
			n.Part.Transparency = math.min(1, n.T0 + k)
		end
	end
end

local function step(dt)
	clock = clock + dt
	local cam = Workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or nil
	for i = #recs, 1, -1 do
		local rec = recs[i]
		if rec and rec.Root and rec.Root.Parent then
			local d = 0
			if camPos then
				d = (rec.Base.Position - camPos).Magnitude
			end
			if d <= K.CULL then
				rec.Frame = rec.Frame + 1
				if d <= K.NEAR or rec.Frame % 2 == 0 then
					pose(rec)
				end
			end
		elseif rec then
			removeRec(rec, false)
		end
	end
end

ensureLoop = function()
	if loopConn or #recs == 0 then
		return
	end
	loopConn = RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(step, math.min(dt, 0.1))
		if not ok then
			warn("[ShowcaseController] frame failed: " .. tostring(err))
		end
	end)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function ShowcaseController.Init()
	if initialized then
		return
	end
	initialized = true
	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(model)
		pending[model] = nil
		local rec = byModel[model]
		if rec then
			removeRec(rec, true)
		end
	end)
	for _, model in ipairs(CollectionService:GetTagged(TAG)) do
		track(model)
	end
end

function ShowcaseController.Count()
	return #recs
end

return ShowcaseController
