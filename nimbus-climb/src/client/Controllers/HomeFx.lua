-- HomeFx (client, Phase 2 homeworld): brings the tycoon homes that server/Services/HomeBuilder builds to life on
-- THIS client only (ARCHITECTURE_V3.md "Phase 2 build contract", Replication rule: the server never animates).
--
--   HomeFx.Init()
--   HomeFx.Count() -> number of home plots tracked
--   HomeFx.Stats() -> { Homes, Near, Stations, Presses, Pops, Blocks, Pool, HiddenPrompts, HiddenSigns, GardenPets,
--                       GymPets }
--
-- Every Folder tagged "NC_Home" (HomeBuilder's per-plot `Home` folder, attributes OwnerUserId / CollectorCash /
-- CollectorCap) gets:
--   * a voxel pop-in when a `Station_*` (or a buy pad `Pad_*`, the conveyor) appears while the game runs: its blocks
--     spring up from the ground bottom-to-top in under a second, then everything is put back exactly where the
--     server built it (only stations built in the last few seconds pop, so joining players do not see old builds pop)
--   * the Cloud Presses at work: the press head (`PressHead`) stamps down, a puff of cloud (`Puff` emitter on the
--     `PuffPoint` attachment) and a glowing cloud block drops out of the chute (attribute Chute) onto the belt
--     (Drop), rides the conveyor (`Conveyor`, attributes Start / Finish) into the Collector's intake (Intake) and the
--     Collector glows up; faster presses (attribute PuffInterval) make bigger blocks (BlockSize, BlockColor)
--   * the Collector: its screen (`CashLabel`, `CapLabel`) shows the cash waiting in it, the tank fill (`CashFill`,
--     attributes FillBottom / FillMax / FillWidth) rises with CollectorCash / CollectorCap, its `Glow` parts breathe
--     (faster when it is full) and flash whenever a block arrives
--   * the Fusion Machine's cloud chamber swirls (`Swirl`, attribute SwirlCenter) and its neon breathes
--   * owner-only prompts: every ProximityPrompt inside a home that is not the local player's (BuyPrompt,
--     CollectPrompt, FusionPrompt, ... by their OwnerUserId attribute, else the home's) is disabled locally, and the
--     pad signs (`PadSign`) of other players' pads are hidden; the "Claim Home" prompts of other plots are disabled
--     while the local player owns a home (one home per player). The server still checks everything. The signs of
--     the player's own LOCKED pads (their lock reason) only show within K.LOCKED_SIGN_NEAR studs, so the yard is not
--     a field of lock signs: from afar it shows what can be bought now, like a classic tycoon.
--   * the local player's own pads glow when the Cash attribute can pay their Price and dim (price in red) when not.
--   * the pets at work: every key of the plot's GardenPets attribute ("1=cat;3=fox@Golden", written by TycoonService
--     on the plot folder) stands on the Garden's Spot<slot> cushion (full size), every key of GymPets (PetCareService)
--     on the Gym's Spot<slot> target (a little smaller: the targets are closer together), PetBuilder Low detail,
--     facing the yard, for homes within K.PET_NEAR studs; they breathe / flap a few times a second (gym pets
--     livelier). Hybrid keys need their owner's record and are skipped. Pets live in workspace.ClientFx.HomePets.
-- Cheap: one RenderStepped connection; homes farther than K.NEAR studs from the camera are frozen; the cloud blocks
-- are pooled parts in workspace.ClientFx (never more than K.MAX_BLOCKS), nothing else is created per frame; no
-- collisions, queries, touches or shadows on anything HomeFx makes. Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local function optionalShared(name)
	local module = Shared:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

local TycoonCatalog = optionalShared("TycoonCatalog")
local Util = optionalShared("Util")
local PetBuilder = optionalShared("PetBuilder")
local PetKeys = optionalShared("PetKeys")
local PetCatalog = optionalShared("PetCatalog")

local HomeFx = {}

local HOME_TAG = "NC_Home"
local CASH_ATTR = (Config.Attr and Config.Attr.Cash) or "Cash"

local K = {
	NEAR = 230, -- studs from the camera: homes farther away are frozen (no presses, no blocks)
	NEAR_CHECK = 0.5, -- seconds between distance checks
	POP_WINDOW = 6, -- a station whose BuiltAt is younger than this pops in
	POP_LIVE_AFTER = 1.5, -- children without BuiltAt pop when they arrive this long after the home was found
	POP_PART = 0.3, -- one block's spring
	POP_SPREAD = 0.6, -- bottom-to-top spread of one model's blocks
	POP_STAGGER = 0.1, -- between models that appear together (a claim rebuilds a whole home)
	POP_LIFT = 1.2, -- studs a block rises while it pops
	MAX_POP_PARTS = 3000, -- blocks animated at once (anything beyond simply appears)
	PRESS_DROP = 0.5, -- studs the press head stamps down (onto the lid)
	PRESS_DOWN = 0.18, -- seconds of the stamp
	PRESS_UP = 0.4, -- seconds back up
	FALL_TIME = 0.45, -- chute -> belt
	BELT_SPEED = 5, -- studs per second (the Conveyor's Speed attribute wins)
	INTAKE_TIME = 0.4, -- belt end -> into the Collector
	MAX_BLOCKS = 64, -- cloud blocks alive at once over all homes
	MAX_BLOCKS_HOME = 32,
	FILL_EASE = 5, -- the tank fill eases toward its level
	GLOW_RATE = 2.2, -- radians per second of the breathing glow
	GLOW_RATE_FULL = 6,
	GLOW_SWING = 0.3, -- transparency swing of a breathing glow
	FLASH_TIME = 0.3,
	SWIRL_SPEED = 1.4, -- radians per second of the Fusion Machine's swirl
	SWIRL_BOB = 0.25,
	PAD_PULSE = 3.2,
	PAD_DIM = 0.6, -- glow transparency of a pad the local player cannot pay for yet
	LOCKED_SIGN_NEAR = 30, -- studs: the sign of one of the local player's LOCKED pads (its lock reason) shows only
	LOCKED_SIGN_FAR = 34, -- this close (hidden again beyond FAR), so from afar the yard shows what can be bought now
	SIGN_CHECK = 0.25, -- seconds between two of those distance checks
	PET_NEAR = 110, -- garden / gym pets are shown for homes this close to the camera (hysteresis +20)
	PET_SCALE = 0.85,
	PET_ANIM_STEP = 0.125, -- seconds between two PetBuilder.Animate calls of the garden / gym pets
	PET_ANIM_NEAR = 80, -- ...only this close
	PET_HOVER = 0.08, -- studs between a pet's lowest block and its cushion
	MAX_GARDEN_SLOTS = 8,
}

local COLORS = {
	CapNormal = Color3.fromRGB(246, 216, 132),
	CapFull = Color3.fromRGB(255, 150, 110),
	PriceOk = Color3.fromRGB(170, 244, 140),
	PriceShort = Color3.fromRGB(255, 132, 120),
	Block = Color3.fromRGB(226, 242, 255),
}

local localPlayer = Players.LocalPlayer
local localUid = 0
local homes = {} -- [folder] = rec
local homeList = {} -- array of recs (iteration order)
local pops = {} -- array of pop records
local popParts = 0
local blocksAlive = 0
local pool = {} -- idle block parts
local poolCreated = 0
local fxFolder = nil
local petFolder = nil
local petLows = {} -- [key|scale] = height of the pet's lowest block under its pivot (studs), or false (cannot build)
-- the stations whose pets HomeFx shows, by Kind: the plot attribute that lists them and how lively they look
local PET_STATIONS = {
	Garden = { Attr = "GardenPets", Anim = { Flap = 0.6 }, Scale = 1 }, -- 5 studs between two cushions
	Gym = { Attr = "GymPets", Anim = { Flap = 1.4, Excited = 1 }, Scale = 0.85 }, -- 3 studs between two targets
}
local overrides = setmetatable({}, { __mode = "k" }) -- [ProximityPrompt] = state
local signs = setmetatable({}, { __mode = "k" }) -- [BillboardGui] = home rec
local signNear = setmetatable({}, { __mode = "k" }) -- [BillboardGui] = true while a locked pad's sign is close enough
local signFocus = nil -- where the local player is (character, else camera), refreshed every K.SIGN_CHECK
local nextSignCheck = 0
local clock = 0
local nextPopStart = 0
local loopConn = nil
local initialized = false
local frameWarned = false
local ownsHome = false

local floor, max, min, abs, sin, pi = math.floor, math.max, math.min, math.abs, math.sin, math.pi

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function serverNow()
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	if ok and type(t) == "number" then
		return t
	end
	return os.clock()
end

local function clamp01(x)
	if x < 0 then
		return 0
	elseif x > 1 then
		return 1
	end
	return x
end

local function commas(n)
	if Util and type(Util.Commas) == "function" then
		local ok, s = pcall(Util.Commas, n)
		if ok and type(s) == "string" then
			return s
		end
	end
	local s = tostring(floor(n))
	local out = s
	while true do
		local k
		out, k = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
		if k == 0 then
			break
		end
	end
	return out
end

local function formatCash(n)
	n = tonumber(n) or 0
	if n ~= n then
		n = 0
	end
	if TycoonCatalog and type(TycoonCatalog.FormatCash) == "function" then
		local ok, s = pcall(TycoonCatalog.FormatCash, n)
		if ok and type(s) == "string" then
			return s
		end
	end
	return "$" .. commas(max(0, floor(n)))
end

local function vecAttr(inst, name)
	local v = inst and inst:GetAttribute(name)
	if typeof(v) == "Vector3" then
		return v
	end
	return nil
end

local function numAttr(inst, name, default)
	local v = inst and tonumber(inst:GetAttribute(name))
	if v == nil or v ~= v then
		return default
	end
	return v
end

local function ensureFolder()
	if fxFolder and fxFolder.Parent then
		return fxFolder
	end
	local root = Workspace:FindFirstChild("ClientFx")
	if not root then
		root = Instance.new("Folder")
		root.Name = "ClientFx"
		root.Parent = Workspace
	end
	local f = root:FindFirstChild("HomeFx")
	if not f then
		f = Instance.new("Folder")
		f.Name = "HomeFx"
		f.Parent = root
	end
	fxFolder = f
	return f
end

local function ensurePetFolder()
	if petFolder and petFolder.Parent then
		return petFolder
	end
	local root = ensureFolder().Parent
	local f = root:FindFirstChild("HomePets")
	if not f then
		f = Instance.new("Folder")
		f.Name = "HomePets"
		f.Parent = root
	end
	petFolder = f
	return f
end

local function collectParts(model, out)
	out = out or {}
	if model:IsA("BasePart") then
		out[#out + 1] = model
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			out[#out + 1] = d
		end
	end
	return out
end

-- the nearest ancestor (or self) that carries `attr`
local function ancestorWith(inst, attr, stop)
	local node = inst
	for _ = 1, 8 do
		if not node or node == stop then
			return nil
		end
		if node:GetAttribute(attr) ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

----------------------------------------------------------------------
-- Owner-only prompts and signs
----------------------------------------------------------------------
local function homeOwner(rec)
	return rec and tonumber(rec.Folder:GetAttribute("OwnerUserId")) or 0
end

local function promptOwner(prompt, rec)
	local uid = tonumber(prompt:GetAttribute("OwnerUserId"))
	if uid == nil then
		local holder = ancestorWith(prompt.Parent, "OwnerUserId", rec and rec.Folder.Parent)
		uid = holder and tonumber(holder:GetAttribute("OwnerUserId")) or nil
	end
	if uid == nil then
		uid = homeOwner(rec)
	end
	return uid or 0
end

-- what the server would have this prompt show (HomeBuilder's rules), used when HomeFx stops hiding it
local function serverEnabled(prompt, state)
	if prompt.Name == "ClaimPrompt" then
		return state.Home ~= nil and homeOwner(state.Home) == 0
	end
	if prompt.Name == "BuyPrompt" then
		local pad = ancestorWith(prompt.Parent, "Locked", state.Home and state.Home.Folder)
		local locked = pad and pad:GetAttribute("Locked")
		return (locked == nil or locked == "") and promptOwner(prompt, state.Home) ~= 0
	end
	return state.Server
end

local function shouldHide(prompt, state)
	if prompt.Name == "ClaimPrompt" then
		-- one home per player: the other plots' claim prompts go away while the local player owns one
		return ownsHome and homeOwner(state.Home) ~= localUid
	end
	return promptOwner(prompt, state.Home) ~= localUid
end

local function applyPrompt(prompt)
	local state = overrides[prompt]
	if not state or not prompt.Parent then
		return
	end
	local hide = shouldHide(prompt, state)
	if hide then
		state.Hidden = true
		if prompt.Enabled then
			state.Wrote = false
			prompt.Enabled = false
		end
	elseif state.Hidden then
		state.Hidden = false
		local want = serverEnabled(prompt, state) and true or false
		if prompt.Enabled ~= want then
			state.Wrote = want
			prompt.Enabled = want
		end
	end
end

local function trackPrompt(prompt, rec)
	if overrides[prompt] then
		overrides[prompt].Home = rec
		applyPrompt(prompt)
		return
	end
	local state = { Home = rec, Server = prompt.Enabled, Hidden = false, Wrote = nil }
	overrides[prompt] = state
	prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
		local v = prompt.Enabled
		if state.Wrote ~= nil and v == state.Wrote then
			state.Wrote = nil -- the echo of our own write (signals may be deferred)
			return
		end
		state.Server = v
		if state.Hidden and v then
			applyPrompt(prompt)
		end
	end)
	prompt:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		applyPrompt(prompt)
	end)
	applyPrompt(prompt)
end

-- true when a sign belongs to a locked pad and the local player is not close to it (hysteresis NEAR / FAR)
local function lockedAndFar(gui, rec)
	local pad = ancestorWith(gui.Parent, "Locked", rec.Folder)
	local locked = pad and pad:GetAttribute("Locked")
	if locked == nil or locked == "" or not signFocus then
		signNear[gui] = nil
		return false
	end
	local anchor = gui.Adornee or gui.Parent
	if not anchor or not anchor:IsA("BasePart") then
		return false
	end
	local d = (anchor.Position - signFocus).Magnitude
	local near = d <= (signNear[gui] and K.LOCKED_SIGN_FAR or K.LOCKED_SIGN_NEAR)
	signNear[gui] = near or nil
	return not near
end

local function applySign(gui)
	local rec = signs[gui]
	if not rec or not gui.Parent then
		return
	end
	local holder = ancestorWith(gui.Parent, "OwnerUserId", rec.Folder)
	local uid = holder and tonumber(holder:GetAttribute("OwnerUserId")) or homeOwner(rec)
	local show = uid == localUid and uid ~= 0
	if show and lockedAndFar(gui, rec) then
		show = false
	end
	if gui.Enabled ~= show then
		gui.Enabled = show
	end
end

-- the local player's position for the locked-pad signs: the character, else the camera
local function focusPos()
	local character = localPlayer and localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	local cam = Workspace.CurrentCamera
	return cam and cam.CFrame.Position or nil
end

-- re-checks the signs of the local player's own home (locked pads show their reason only up close)
local function stepSigns()
	if clock < nextSignCheck then
		return
	end
	nextSignCheck = clock + K.SIGN_CHECK
	if not ownsHome then
		return
	end
	signFocus = focusPos()
	for gui, rec in pairs(signs) do
		if gui.Parent and homeOwner(rec) == localUid then
			applySign(gui)
		end
	end
end

local function refreshHome(rec)
	for prompt, state in pairs(overrides) do
		if state.Home == rec then
			applyPrompt(prompt)
		end
	end
	for gui, r in pairs(signs) do
		if r == rec then
			applySign(gui)
		end
	end
end

-- recomputes "the local player owns a home" and refreshes every claim prompt when it changed
local function refreshOwnership()
	local owns = false
	for _, rec in ipairs(homeList) do
		if localUid ~= 0 and homeOwner(rec) == localUid then
			owns = true
		end
	end
	if owns ~= ownsHome then
		ownsHome = owns
		for prompt in pairs(overrides) do
			if prompt.Name == "ClaimPrompt" then
				applyPrompt(prompt)
			end
		end
	end
end

----------------------------------------------------------------------
-- Pop-in
----------------------------------------------------------------------
local function cameraPos()
	local cam = Workspace.CurrentCamera
	return cam and cam.CFrame.Position or nil
end

local function easeBack(p)
	local s = 1.7
	local q = p - 1
	return 1 + q * q * ((s + 1) * q + s)
end

-- returns the pop record (nil when the model simply appears: too far, too much popping already, nothing visible)
local function startPop(model, rec)
	if popParts >= K.MAX_POP_PARTS then
		return nil
	end
	local parts = {}
	for _, p in ipairs(collectParts(model)) do
		if p.Transparency < 1 then
			parts[#parts + 1] = p
		end
	end
	if #parts == 0 then
		return nil
	end
	-- near enough to be seen?
	local eye = cameraPos()
	if eye and rec and rec.Center and (rec.Center - eye).Magnitude > K.NEAR + 60 then
		return nil
	end
	local bottoms = {}
	local lo, hi = math.huge, -math.huge
	for i, p in ipairs(parts) do
		local b = p.Position.Y - p.Size.Y / 2
		bottoms[i] = b
		lo, hi = min(lo, b), max(hi, b)
	end
	local span = max(0.001, hi - lo)
	local start = max(clock, nextPopStart)
	nextPopStart = start + K.POP_STAGGER
	local pop = { Model = model, Parts = parts, CF = {}, Size = {}, Trans = {}, Delay = {}, Start = start, Done = false }
	for i, p in ipairs(parts) do
		pop.CF[i] = p.CFrame
		pop.Size[i] = p.Size
		pop.Trans[i] = p.Transparency
		pop.Delay[i] = (bottoms[i] - lo) / span * K.POP_SPREAD
		p.Transparency = 1
	end
	pop.End = start + K.POP_SPREAD + K.POP_PART
	popParts = popParts + #parts
	pops[#pops + 1] = pop
	return pop
end

local function finishPop(pop)
	if pop.Done then
		return
	end
	pop.Done = true
	popParts = max(0, popParts - #pop.Parts)
	for i, p in ipairs(pop.Parts) do
		if p.Parent then
			p.Size = pop.Size[i]
			p.CFrame = pop.CF[i]
			p.Transparency = pop.Trans[i]
		end
	end
end

local function stepPops()
	local i = 1
	while i <= #pops do
		local pop = pops[i]
		if pop.Done or not pop.Model.Parent or clock >= pop.End then
			finishPop(pop)
			table.remove(pops, i)
		else
			local t = clock - pop.Start
			if t >= 0 then
				for j, p in ipairs(pop.Parts) do
					local q = (t - pop.Delay[j]) / K.POP_PART
					if q > 0 then
						if q >= 1 then
							if p.Transparency ~= pop.Trans[j] then
								p.Size = pop.Size[j]
								p.CFrame = pop.CF[j]
								p.Transparency = pop.Trans[j]
							end
						else
							local s = max(0.05, easeBack(q))
							p.Size = pop.Size[j] * s
							p.CFrame = pop.CF[j] + Vector3.new(0, -K.POP_LIFT * (1 - q), 0)
							local base = pop.Trans[j]
							p.Transparency = base + (1 - base) * (1 - clamp01(q * 2.5))
						end
					end
				end
			end
			i = i + 1
		end
	end
end

local function cancelPopOf(model)
	for _, pop in ipairs(pops) do
		if pop.Model == model then
			finishPop(pop)
		end
	end
end

----------------------------------------------------------------------
-- Cloud blocks (pooled)
----------------------------------------------------------------------
local function takeBlock()
	if blocksAlive >= K.MAX_BLOCKS then
		return nil
	end
	local p = table.remove(pool)
	if not p then
		p = Instance.new("Part")
		p.Name = "CloudBlock"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		poolCreated = poolCreated + 1
	end
	blocksAlive = blocksAlive + 1
	return p
end

local function giveBlock(p)
	blocksAlive = max(0, blocksAlive - 1)
	p.Parent = nil
	pool[#pool + 1] = p
end

local function recycleBlocks(rec)
	for i = #rec.Blocks, 1, -1 do
		giveBlock(rec.Blocks[i].Part)
		rec.Blocks[i] = nil
	end
end

local function beltOf(rec)
	local conv = rec.Conveyor
	if not conv or not conv.Parent then
		return nil
	end
	local a, b = vecAttr(conv, "Start"), vecAttr(conv, "Finish")
	if not a or not b or (a - b).Magnitude < 0.5 then
		return nil
	end
	return a, b, numAttr(conv, "Speed", K.BELT_SPEED)
end

-- the point on the belt line closest to `p` (clamped to the belt)
local function onBelt(p, a, b)
	local d = b - a
	local len2 = d:Dot(d)
	local t = clamp01((p - a):Dot(d) / len2)
	return a + d * t
end

local function spawnBlock(rec, press)
	if #rec.Blocks >= K.MAX_BLOCKS_HOME then
		return
	end
	local chute, drop = press.Chute, press.Drop
	if not chute or not drop then
		return
	end
	local part = takeBlock()
	if not part then
		return
	end
	local size = press.BlockSize
	local a, b, speed = beltOf(rec)
	local lift = Vector3.new(0, size / 2, 0)
	local land = drop
	if a then
		land = onBelt(drop, a, b)
	end
	part.Size = Vector3.new(size, size, size)
	part.Color = press.BlockColor
	part.Transparency = 0.1
	part.CFrame = CFrame.new(chute)
	part.Parent = ensureFolder()
	rec.Blocks[#rec.Blocks + 1] = {
		Part = part,
		Stage = 1,
		T = 0,
		Dur = K.FALL_TIME,
		A = chute,
		B = land + lift,
		Size = size,
		Lift = lift,
		Speed = speed or K.BELT_SPEED,
	}
end

local function flashCollector(rec)
	local col = rec.Collector
	if col then
		col.Flash = K.FLASH_TIME
	end
end

local function stepBlocks(rec, dt)
	local i = 1
	local blocks = rec.Blocks
	while i <= #blocks do
		local bl = blocks[i]
		bl.T = bl.T + dt
		local done = false
		if bl.T >= bl.Dur then
			-- next leg
			if bl.Stage == 1 then
				local a, b = beltOf(rec)
				bl.Stage = 2
				bl.T = 0
				bl.A = bl.B
				if a then
					bl.B = b + bl.Lift
				else
					local col = rec.Collector
					bl.B = (col and col.Intake and (col.Intake + bl.Lift)) or bl.A
				end
				bl.Dur = max(0.05, (bl.B - bl.A).Magnitude / max(0.5, bl.Speed))
			elseif bl.Stage == 2 then
				local col = rec.Collector
				bl.Stage = 3
				bl.T = 0
				bl.A = bl.B
				bl.B = (col and col.Intake and (col.Intake + bl.Lift)) or bl.A
				bl.Dur = K.INTAKE_TIME
			else
				done = true
			end
		end
		if done then
			if rec.Collector then
				flashCollector(rec)
			end
			giveBlock(bl.Part)
			table.remove(blocks, i)
		else
			local q = clamp01(bl.T / bl.Dur)
			local pos
			if bl.Stage == 1 then
				-- a little hop out of the chute, then down onto the belt
				local h = bl.A + (bl.B - bl.A) * q
				pos = Vector3.new(h.X, bl.A.Y + (bl.B.Y - bl.A.Y) * q * q + 0.6 * sin(q * pi), h.Z)
			else
				pos = bl.A + (bl.B - bl.A) * q
			end
			local part = bl.Part
			if bl.Stage == 3 then
				local s = max(0.05, bl.Size * (1 - q))
				part.Size = Vector3.new(s, s, s)
				part.Transparency = 0.1 + 0.6 * q
			end
			part.CFrame = CFrame.new(pos)
			i = i + 1
		end
	end
end

----------------------------------------------------------------------
-- Stations
----------------------------------------------------------------------
local function setHead(press, offset)
	if press.Offset == offset then
		return
	end
	press.Offset = offset
	local down = Vector3.new(0, -offset, 0)
	for i, p in ipairs(press.HeadParts) do
		if p.Parent then
			p.CFrame = press.HeadCF[i] + down
		end
	end
end

local function stepPress(rec, press, dt)
	if press.Popping then
		if press.Popping.Done then
			press.Popping = nil
		else
			return
		end
	end
	local interval = press.Interval
	press.Phase = press.Phase + dt
	if press.Phase >= interval then
		press.Phase = press.Phase - interval
		if press.Phase > interval then
			press.Phase = 0
		end
		-- the stamp: a puff and a block
		if press.Emitter and press.Emitter.Parent then
			pcall(press.Emitter.Emit, press.Emitter, press.PuffCount)
		end
		spawnBlock(rec, press)
	end
	local phase = press.Phase
	local offset = 0
	local downAt = interval - K.PRESS_DOWN
	if phase >= downAt then
		local q = (phase - downAt) / K.PRESS_DOWN
		offset = K.PRESS_DROP * q * q
	elseif phase < K.PRESS_UP then
		offset = K.PRESS_DROP * (1 - phase / K.PRESS_UP)
	end
	-- quantise a little so a resting head writes nothing
	offset = floor(offset * 50 + 0.5) / 50
	setHead(press, offset)
end

local function setFill(col, h)
	local fill = col.Fill
	if not fill or not fill.Parent or not col.FillBottom then
		return
	end
	local w = col.FillWidth
	local show = h > 0.02
	local hh = max(0.05, h)
	fill.Size = Vector3.new(w, hh, w)
	fill.CFrame = col.FillRot + (col.FillBottom + Vector3.new(0, hh / 2, 0))
	local t = show and 0.05 or 1
	if fill.Transparency ~= t then
		fill.Transparency = t
	end
end

local function updateCollectorText(rec)
	local col = rec.Collector
	if not col then
		return
	end
	local folder = rec.Folder
	local cash = numAttr(folder, "CollectorCash", nil)
	if cash == nil and folder.Parent then
		cash = numAttr(folder.Parent, "CollectorCash", 0)
	end
	local cap = numAttr(folder, "CollectorCap", nil)
	if cap == nil and folder.Parent then
		cap = numAttr(folder.Parent, "CollectorCap", 0)
	end
	cash, cap = max(0, cash or 0), max(0, cap or 0)
	col.Cash, col.Cap = cash, cap
	col.Full = cap > 0 and cash >= cap
	if col.CashLabel and col.CashLabel.Parent then
		local text = formatCash(cash)
		if col.CashLabel.Text ~= text then
			col.CashLabel.Text = text
		end
	end
	if col.CapLabel and col.CapLabel.Parent then
		local text, color
		if col.Full then
			text, color = "FULL! Collect", COLORS.CapFull
		elseif cap > 0 then
			text, color = "Max " .. formatCash(cap), COLORS.CapNormal
		else
			text, color = "Collector", COLORS.CapNormal
		end
		if col.CapLabel.Text ~= text then
			col.CapLabel.Text = text
		end
		col.CapLabel.TextColor3 = color
	end
	local frac = 0
	if cap > 0 then
		frac = clamp01(cash / cap)
	elseif cash > 0 then
		frac = 0.1
	end
	if cash > 0 then
		frac = max(frac, 0.06)
	end
	col.FillTarget = (col.FillMax or 3) * frac
end

local function stepCollector(rec, col, dt)
	if col.Popping then
		if col.Popping.Done then
			col.Popping = nil
		else
			return
		end
	end
	-- the tank fill eases toward its level
	local target = col.FillTarget or 0
	local h = col.FillH
	if h == nil then
		col.FillH = target
		setFill(col, target)
	elseif abs(target - h) > 0.005 then
		h = h + (target - h) * min(1, dt * K.FILL_EASE)
		if abs(target - h) <= 0.005 then
			h = target
		end
		col.FillH = h
		setFill(col, h)
	end
	-- breathing glow + a flash when a block arrives
	col.Wave = (col.Wave or 0) + dt * (col.Full and K.GLOW_RATE_FULL or K.GLOW_RATE)
	local swing = (0.5 + 0.5 * sin(col.Wave)) * K.GLOW_SWING
	local flash = 0
	if col.Flash and col.Flash > 0 then
		col.Flash = col.Flash - dt
		flash = clamp01(col.Flash / K.FLASH_TIME)
	end
	for i, p in ipairs(col.Glows) do
		if p.Parent then
			local base = col.GlowBase[i]
			local t = base + swing * (1 - flash)
			p.Transparency = min(0.95, t)
		end
	end
	if col.Light and col.Light.Parent then
		col.Light.Brightness = col.LightBase * (1 + 1.5 * flash + (col.Full and 0.5 or 0))
	end
end

local function stepSwirl(sw, dt)
	if sw.Popping then
		if sw.Popping.Done then
			sw.Popping = nil
		else
			return
		end
	end
	sw.Angle = (sw.Angle + dt * K.SWIRL_SPEED) % (2 * pi)
	local c = sw.Center
	local rot = CFrame.new(c.X, c.Y + sin(sw.Angle * 1.5) * K.SWIRL_BOB, c.Z) * CFrame.Angles(0, sw.Angle, 0)
	for i, p in ipairs(sw.Parts) do
		if p.Parent then
			p.CFrame = rot * sw.Local[i]
		end
	end
	sw.Wave = sw.Wave + dt * K.GLOW_RATE
	local swing = (0.5 + 0.5 * sin(sw.Wave)) * K.GLOW_SWING
	for i, p in ipairs(sw.Glows) do
		if p.Parent then
			p.Transparency = min(0.95, sw.GlowBase[i] + swing)
		end
	end
end

local function registerStation(rec, model)
	if rec.Stations[model] then
		return rec.Stations[model]
	end
	local id = tostring(model:GetAttribute("StationId") or string.sub(model.Name, 9))
	local kind = model:GetAttribute("Kind")
	if kind == nil then
		if string.sub(id, 1, 5) == "Press" then
			kind = "Press"
		elseif id == "Collector" then
			kind = "Collector"
		elseif id == "FusionMachine" then
			kind = "Fusion"
		end
	end
	local st = { Model = model, Id = id, Kind = kind }
	rec.Stations[model] = st
	if kind == "Press" then
		local head = model:FindFirstChild("PressHead")
		local parts = head and collectParts(head) or {}
		local cfs = {}
		for i, p in ipairs(parts) do
			cfs[i] = p.CFrame
		end
		st.HeadParts, st.HeadCF, st.Offset = parts, cfs, 0
		st.Chute, st.Drop = vecAttr(model, "Chute"), vecAttr(model, "Drop")
		st.BlockSize = max(0.3, min(2.5, numAttr(model, "BlockSize", 0.8)))
		local color = model:GetAttribute("BlockColor")
		st.BlockColor = (typeof(color) == "Color3") and color or COLORS.Block
		st.Interval = max(0.5, min(6, numAttr(model, "PuffInterval", 2)))
		local level = numAttr(model, "Level", 1)
		st.PuffCount = floor(4 + level / 2)
		local puff = model:FindFirstChild("Puff", true)
		st.Emitter = (puff and puff:IsA("ParticleEmitter")) and puff or nil
		-- presses do not stamp in sync: a phase from the station id
		local n = tonumber(string.match(id, "%d+")) or 1
		st.Phase = (n * 0.37 % 1) * st.Interval
		rec.Presses[#rec.Presses + 1] = st
	elseif kind == "Collector" then
		st.CashLabel = model:FindFirstChild("CashLabel", true)
		st.CapLabel = model:FindFirstChild("CapLabel", true)
		local fill = model:FindFirstChild("CashFill", true)
		if fill and fill:IsA("BasePart") then
			st.Fill = fill
			st.FillBottom = vecAttr(fill, "FillBottom") or vecAttr(model, "FillBottom")
			st.FillMax = numAttr(fill, "FillMax", numAttr(model, "FillMax", 3))
			st.FillWidth = numAttr(fill, "FillWidth", fill.Size.X)
			st.FillRot = fill.CFrame - fill.CFrame.Position
			st.FillH = nil -- the first frame writes the level
		end
		st.Intake = vecAttr(model, "Intake")
		st.Glows, st.GlowBase = {}, {}
		for _, p in ipairs(collectParts(model)) do
			if p.Name == "Glow" and p.Material == Enum.Material.Neon then
				st.Glows[#st.Glows + 1] = p
				st.GlowBase[#st.GlowBase + 1] = p.Transparency
			end
		end
		local light = model:FindFirstChildWhichIsA("PointLight", true)
		if light then
			st.Light, st.LightBase = light, light.Brightness
		end
		rec.Collector = st
		updateCollectorText(rec)
	elseif PET_STATIONS[kind] or PET_STATIONS[id] then
		local pk = rec.Pet[PET_STATIONS[kind] and kind or id]
		pk.Station = st
		pk.Dirty = true
	elseif kind == "Fusion" then
		local swirl = model:FindFirstChild("Swirl")
		local center = vecAttr(model, "SwirlCenter")
		if swirl and center then
			local parts = collectParts(swirl)
			local loc = {}
			local base = CFrame.new(center)
			for i, p in ipairs(parts) do
				loc[i] = base:Inverse() * p.CFrame
			end
			st.Parts, st.Local, st.Center, st.Angle, st.Wave = parts, loc, center, 0, 0
			st.Glows, st.GlowBase = {}, {}
			for _, p in ipairs(collectParts(model)) do
				if p.Name == "Glow" and p.Material == Enum.Material.Neon then
					st.Glows[#st.Glows + 1] = p
					st.GlowBase[#st.GlowBase + 1] = p.Transparency
				end
			end
			rec.Swirls[#rec.Swirls + 1] = st
		end
	end
	return st
end

local function removeFrom(list, item)
	for i = #list, 1, -1 do
		if list[i] == item then
			table.remove(list, i)
		end
	end
end

local function unregisterStation(rec, model)
	local st = rec.Stations[model]
	if not st then
		return
	end
	rec.Stations[model] = nil
	removeFrom(rec.Presses, st)
	removeFrom(rec.Swirls, st)
	if rec.Collector == st then
		rec.Collector = nil
	end
	for _, pk in pairs(rec.Pet) do
		if pk.Station == st then
			pk.Station = nil
			pk.Dirty = true
		end
	end
end

----------------------------------------------------------------------
-- Pads (the local player's own: glow when affordable)
----------------------------------------------------------------------
local function localCash()
	local v = localPlayer and localPlayer:GetAttribute(CASH_ATTR)
	return tonumber(v)
end

local function padAffordable(pad)
	local model = pad.Model
	local locked = model:GetAttribute("Locked")
	if locked ~= nil and locked ~= "" then
		return nil -- locked pads keep the server's look
	end
	local cash = localCash()
	if cash == nil then
		return true
	end
	return cash >= numAttr(model, "Price", 0)
end

local function refreshPad(rec, pad)
	local ok = nil -- true = can pay, false = cannot yet, nil = not ours / locked / unknown
	if localUid ~= 0 and homeOwner(rec) == localUid then
		ok = padAffordable(pad)
	end
	pad.Afford = ok
	if not pad.PriceLabel or not pad.PriceLabel.Parent then
		pad.PriceLabel = pad.Model:FindFirstChild("PriceLabel", true)
		pad.PriceColor = pad.PriceLabel and pad.PriceLabel.TextColor3 or nil
	end
	local label = pad.PriceLabel
	if label and label.Parent and pad.PriceColor then
		label.TextColor3 = (ok == false) and COLORS.PriceShort or pad.PriceColor
	end
	if ok ~= true then
		for i, p in ipairs(pad.Glows) do
			if p.Parent then
				p.Transparency = (ok == false) and max(pad.GlowBase[i], K.PAD_DIM) or pad.GlowBase[i]
			end
		end
	end
end

local function registerPad(rec, model)
	if rec.Pads[model] then
		return
	end
	local pad = { Model = model, Glows = {}, GlowBase = {}, Wave = 0 }
	for _, p in ipairs(collectParts(model)) do
		if p.Name == "Glow" then
			pad.Glows[#pad.Glows + 1] = p
			pad.GlowBase[#pad.GlowBase + 1] = p.Transparency
		end
	end
	rec.Pads[model] = pad
	model:GetAttributeChangedSignal("Price"):Connect(function()
		refreshPad(rec, pad)
	end)
	model:GetAttributeChangedSignal("Locked"):Connect(function()
		refreshPad(rec, pad)
		local sign = model:FindFirstChild("PadSign", true)
		if sign then
			applySign(sign)
		end
	end)
	refreshPad(rec, pad)
end

local function stepPads(rec, dt)
	for _, pad in pairs(rec.Pads) do
		if pad.Popping and pad.Popping.Done then
			pad.Popping = nil
			refreshPad(rec, pad) -- the pop put back the look the pad had when it started
		end
		if pad.Afford == true and not pad.Popping then
			pad.Wave = pad.Wave + dt * K.PAD_PULSE
			local swing = (0.5 + 0.5 * sin(pad.Wave)) * 0.35
			for i, p in ipairs(pad.Glows) do
				if p.Parent then
					p.Transparency = min(0.9, pad.GlowBase[i] + swing)
				end
			end
		end
	end
end

----------------------------------------------------------------------
-- Pets at work (GardenPets on the Garden's cushions, GymPets on the Gym's targets)
----------------------------------------------------------------------
local function parseSlots(text)
	local out = {}
	if type(text) ~= "string" then
		return out
	end
	for slot, key in string.gmatch(text, "(%d+)=([%w_%-@:]+)") do
		local n = tonumber(slot)
		if n and n >= 1 and n <= K.MAX_GARDEN_SLOTS and n == floor(n) then
			out[n] = key
		end
	end
	return out
end

-- the attribute on the plot folder (TycoonService / PetCareService write it there), else on the Home folder
local function slotText(rec, attr)
	local folder = rec.Folder
	local v = folder.Parent and folder.Parent:GetAttribute(attr)
	if v == nil then
		v = folder:GetAttribute(attr)
	end
	return v
end

local function petDefOf(key)
	if PetKeys and type(PetKeys.DefOf) == "function" then
		local ok, def = pcall(PetKeys.DefOf, key)
		if ok and type(def) == "table" then
			return def
		end
	end
	if PetCatalog and type(PetCatalog.Get) == "function" then
		local ok, def = pcall(PetCatalog.Get, key)
		if ok and type(def) == "table" then
			return def
		end
	end
	return nil
end

-- a fresh Low-detail model of the pet (PetBuilder caches the sculpt and clones), anchored and inert, plus the
-- height of its lowest block under the pivot
local function buildPet(key, scale)
	scale = tonumber(scale) or K.PET_SCALE
	local lowKey = key .. "|" .. scale
	if not PetBuilder or petLows[lowKey] == false then
		return nil
	end
	local def = petDefOf(key)
	if not def then
		petLows[lowKey] = false
		return nil
	end
	local ok, model = pcall(PetBuilder.Build, def, { Detail = "Low", Scale = scale })
	if not ok or typeof(model) ~= "Instance" then
		petLows[lowKey] = false
		return nil
	end
	model.Name = "HomePet"
	model:SetAttribute("PetKey", key)
	local list = collectParts(model)
	for _, part in ipairs(list) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
	local lo = petLows[lowKey]
	if lo == nil then
		model:PivotTo(CFrame.new())
		lo = 0
		local first = true
		for _, part in ipairs(list) do
			if part.Transparency < 1 then
				local bottom = part.Position.Y - part.Size.Y / 2
				if first or bottom < lo then
					lo, first = bottom, false
				end
			end
		end
		petLows[lowKey] = lo
	end
	return model, lo
end

local function dropPet(pk, slot)
	local entry = pk.Pets[slot]
	if entry then
		pk.Pets[slot] = nil
		if entry.Model then
			entry.Model:Destroy()
		end
	end
end

local function clearPets(rec)
	for _, pk in pairs(rec.Pet) do
		for slot in pairs(pk.Pets) do
			dropPet(pk, slot)
		end
	end
end

-- brings the pets of one station in line with its attribute (only while the home is near and the station stands)
local function syncPets(rec, kind)
	local pk = rec.Pet[kind]
	pk.Dirty = false
	local st = pk.Station
	local want = {}
	if rec.PetsNear and st and st.Model.Parent then
		want = parseSlots(slotText(rec, PET_STATIONS[kind].Attr))
	end
	for slot, entry in pairs(pk.Pets) do
		if want[slot] ~= entry.Key or not st or entry.Station ~= st.Model or not entry.Model.Parent then
			dropPet(pk, slot)
		end
	end
	for slot, key in pairs(want) do
		if not pk.Pets[slot] then
			local att = st.Model:FindFirstChild("Spot" .. slot, true)
			if att and att:IsA("Attachment") then
				local model, lo = buildPet(key, PET_STATIONS[kind].Scale)
				if model then
					model.Name = kind .. "Pet"
					model:PivotTo(att.WorldCFrame * CFrame.new(0, K.PET_HOVER - lo, 0))
					model.Parent = ensurePetFolder()
					pk.Pets[slot] = { Key = key, Model = model, Station = st.Model }
				end
			end
		end
	end
end

local function syncAllPets(rec)
	for kind in pairs(rec.Pet) do
		syncPets(rec, kind)
	end
end

local function stepPetStations(rec)
	for kind, pk in pairs(rec.Pet) do
		if pk.Dirty then
			local st = pk.Station
			if not (st and st.Popping and not st.Popping.Done) then
				syncPets(rec, kind)
			end
		end
	end
	if not PetBuilder or not rec.PetsAnimate or clock < (rec.PetAnimAt or 0) then
		return
	end
	rec.PetAnimAt = clock + K.PET_ANIM_STEP
	for kind, pk in pairs(rec.Pet) do
		local anim = PET_STATIONS[kind].Anim
		for _, entry in pairs(pk.Pets) do
			if entry.Model.Parent then
				pcall(PetBuilder.Animate, entry.Model, clock, anim)
			end
		end
	end
end

local function anyPetsDirty(rec)
	for _, pk in pairs(rec.Pet) do
		if pk.Dirty then
			return true
		end
	end
	return false
end

----------------------------------------------------------------------
-- Homes
----------------------------------------------------------------------
local function isNew(rec, inst)
	local built = tonumber(inst:GetAttribute("BuiltAt"))
	if built then
		return serverNow() - built < K.POP_WINDOW
	end
	return clock - rec.Found > K.POP_LIVE_AFTER
end

local function onDescendant(rec, d)
	if d:IsA("ProximityPrompt") then
		if d.Name ~= "ClaimPrompt" then
			trackPrompt(d, rec)
		end
	elseif d:IsA("BillboardGui") and d.Name == "PadSign" then
		signs[d] = rec
		applySign(d)
		local pad = ancestorWith(d.Parent, "StationId", rec.Folder)
		local entry = pad and rec.Pads[pad]
		if entry then
			entry.PriceLabel = nil
			refreshPad(rec, entry)
		end
	end
end

local function onHomeChild(rec, child, live)
	local name = child.Name
	if string.sub(name, 1, 8) == "Station_" and child:IsA("Model") then
		local st = registerStation(rec, child)
		if live and isNew(rec, child) then
			st.Popping = startPop(child, rec)
		end
	elseif name == "Conveyor" then
		rec.Conveyor = child
		if live and isNew(rec, child) then
			startPop(child, rec)
		end
	elseif name == "Pads" then
		rec.PadFolder = child
		for _, pad in ipairs(child:GetChildren()) do
			if pad:IsA("Model") then
				registerPad(rec, pad)
			end
		end
		rec.Conns[#rec.Conns + 1] = child.ChildAdded:Connect(function(pad)
			if pad:IsA("Model") then
				registerPad(rec, pad)
				if isNew(rec, pad) and rec.Pads[pad] then
					rec.Pads[pad].Popping = startPop(pad, rec)
				end
			end
		end)
		rec.Conns[#rec.Conns + 1] = child.ChildRemoved:Connect(function(pad)
			rec.Pads[pad] = nil
		end)
	end
end

local function plotCenter(folder)
	local cf = folder:GetAttribute("PlotCFrame")
	if typeof(cf) == "CFrame" then
		return cf.Position
	end
	local v = folder:GetAttribute("PlotCenter")
	if typeof(v) == "Vector3" then
		return v
	end
	return nil
end

local function addHome(folder)
	if homes[folder] or not folder:IsA("Folder") and not folder:IsA("Model") then
		return
	end
	local rec = {
		Folder = folder,
		Found = clock,
		Center = plotCenter(folder),
		Near = false,
		NextNear = 0,
		Stations = {},
		Presses = {},
		Swirls = {},
		Pads = {},
		Blocks = {},
		Conns = {},
		Collector = nil,
		Conveyor = nil,
		Pet = { -- by station Kind: { Station = record | nil, Pets = { [slot] = { Key, Model, Station } }, Dirty }
			Garden = { Station = nil, Pets = {}, Dirty = false },
			Gym = { Station = nil, Pets = {}, Dirty = false },
		},
		PetsNear = false,
		PetsAnimate = false,
	}
	homes[folder] = rec
	homeList[#homeList + 1] = rec
	for _, child in ipairs(folder:GetChildren()) do
		onHomeChild(rec, child, false)
	end
	for _, d in ipairs(folder:GetDescendants()) do
		onDescendant(rec, d)
	end
	rec.Conns[#rec.Conns + 1] = folder.ChildAdded:Connect(function(child)
		onHomeChild(rec, child, true)
	end)
	rec.Conns[#rec.Conns + 1] = folder.ChildRemoved:Connect(function(child)
		if rec.Stations[child] then
			cancelPopOf(child)
			unregisterStation(rec, child)
		elseif child == rec.Conveyor then
			rec.Conveyor = nil
		end
	end)
	rec.Conns[#rec.Conns + 1] = folder.DescendantAdded:Connect(function(d)
		onDescendant(rec, d)
	end)
	local function collectorChanged()
		updateCollectorText(rec)
	end
	rec.Conns[#rec.Conns + 1] = folder:GetAttributeChangedSignal("CollectorCash"):Connect(collectorChanged)
	rec.Conns[#rec.Conns + 1] = folder:GetAttributeChangedSignal("CollectorCap"):Connect(collectorChanged)
	rec.Conns[#rec.Conns + 1] = folder:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		refreshHome(rec)
		for _, pad in pairs(rec.Pads) do
			refreshPad(rec, pad)
		end
		refreshOwnership()
	end)
	rec.Conns[#rec.Conns + 1] = folder:GetAttributeChangedSignal("PlotCFrame"):Connect(function()
		rec.Center = plotCenter(folder)
	end)
	-- the plot's gate (a sibling of the Home folder): its Claim Home prompt; the plot folder's GardenPets / GymPets
	local spot = folder.Parent
	for kind, info in pairs(PET_STATIONS) do
		local function changed()
			rec.Pet[kind].Dirty = true
		end
		rec.Conns[#rec.Conns + 1] = folder:GetAttributeChangedSignal(info.Attr):Connect(changed)
		if spot then
			rec.Conns[#rec.Conns + 1] = spot:GetAttributeChangedSignal(info.Attr):Connect(changed)
		end
	end
	if spot then
		for _, d in ipairs(spot:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.Name == "ClaimPrompt" then
				trackPrompt(d, rec)
			end
		end
		rec.Conns[#rec.Conns + 1] = spot.DescendantAdded:Connect(function(d)
			if d:IsA("ProximityPrompt") and d.Name == "ClaimPrompt" then
				trackPrompt(d, rec)
			end
		end)
	end
	refreshOwnership()
	refreshHome(rec)
end

local function resetHome(rec)
	recycleBlocks(rec)
	clearPets(rec)
	for _, press in ipairs(rec.Presses) do
		setHead(press, 0)
	end
end

local function removeHome(folder)
	local rec = homes[folder]
	if not rec then
		return
	end
	homes[folder] = nil
	removeFrom(homeList, rec)
	for _, c in ipairs(rec.Conns) do
		c:Disconnect()
	end
	rec.Conns = {}
	for model in pairs(rec.Stations) do
		cancelPopOf(model)
	end
	resetHome(rec)
	for prompt, state in pairs(overrides) do
		if state.Home == rec then
			overrides[prompt] = nil
		end
	end
	for gui, r in pairs(signs) do
		if r == rec then
			signs[gui] = nil
		end
	end
	refreshOwnership()
end

----------------------------------------------------------------------
-- Frame loop
----------------------------------------------------------------------
local function updateNear(rec, eye)
	if clock < rec.NextNear then
		return
	end
	rec.NextNear = clock + K.NEAR_CHECK
	if not rec.Center then
		rec.Center = plotCenter(rec.Folder)
		if not rec.Center then
			for model in pairs(rec.Stations) do
				local ok, pivot = pcall(function()
					return model:GetPivot()
				end)
				if ok and pivot then
					rec.Center = pivot.Position
					break
				end
			end
		end
	end
	local dist = (rec.Center ~= nil and eye ~= nil) and (rec.Center - eye).Magnitude or 0
	local near = rec.Center ~= nil and dist <= K.NEAR
	local petsNear = near and dist <= (rec.PetsNear and (K.PET_NEAR + 20) or K.PET_NEAR)
	rec.PetsAnimate = petsNear and dist <= K.PET_ANIM_NEAR
	if petsNear ~= rec.PetsNear then
		rec.PetsNear = petsNear
		for _, pk in pairs(rec.Pet) do
			pk.Dirty = true
		end
	end
	if near ~= rec.Near then
		rec.Near = near
		if not near then
			resetHome(rec)
		end
	end
end

local function step(dt)
	dt = min(tonumber(dt) or 0, 0.1)
	clock = clock + dt
	if #pops > 0 then
		stepPops()
	end
	local eye = cameraPos()
	stepSigns()
	for _, rec in ipairs(homeList) do
		if rec.Folder.Parent then
			updateNear(rec, eye)
			if rec.Near then
				for _, press in ipairs(rec.Presses) do
					stepPress(rec, press, dt)
				end
				if #rec.Blocks > 0 then
					stepBlocks(rec, dt)
				end
				if rec.Collector then
					stepCollector(rec, rec.Collector, dt)
				end
				for _, sw in ipairs(rec.Swirls) do
					stepSwirl(sw, dt)
				end
				stepPads(rec, dt)
				stepPetStations(rec)
			elseif anyPetsDirty(rec) then
				syncAllPets(rec)
			end
		end
	end
end

local function safeStep(dt)
	local ok, err = pcall(step, dt)
	if not ok and not frameWarned then
		frameWarned = true
		warn("[HomeFx] frame error: " .. tostring(err))
	end
end

----------------------------------------------------------------------
-- Public
----------------------------------------------------------------------
function HomeFx.Count()
	return #homeList
end

function HomeFx.Stats()
	local stations, presses, near, hidden, hiddenSigns, pets, gymPets = 0, 0, 0, 0, 0, 0, 0
	for _, rec in ipairs(homeList) do
		for _ in pairs(rec.Pet.Garden.Pets) do
			pets = pets + 1
		end
		for _ in pairs(rec.Pet.Gym.Pets) do
			gymPets = gymPets + 1
		end
		for _ in pairs(rec.Stations) do
			stations = stations + 1
		end
		presses = presses + #rec.Presses
		if rec.Near then
			near = near + 1
		end
	end
	for prompt, state in pairs(overrides) do
		if state.Hidden and prompt.Parent then
			hidden = hidden + 1
		end
	end
	for gui in pairs(signs) do
		if gui.Parent and not gui.Enabled then
			hiddenSigns = hiddenSigns + 1
		end
	end
	return {
		Homes = #homeList,
		Near = near,
		Stations = stations,
		Presses = presses,
		Pops = #pops,
		Blocks = blocksAlive,
		Pool = poolCreated,
		HiddenPrompts = hidden,
		HiddenSigns = hiddenSigns,
		GardenPets = pets,
		GymPets = gymPets,
	}
end

function HomeFx.Init()
	if initialized then
		return
	end
	initialized = true
	localPlayer = localPlayer or Players.LocalPlayer
	localUid = localPlayer and localPlayer.UserId or 0
	CollectionService:GetInstanceAddedSignal(HOME_TAG):Connect(function(folder)
		local ok, err = pcall(addHome, folder)
		if not ok then
			warn("[HomeFx] could not track a home: " .. tostring(err))
		end
	end)
	CollectionService:GetInstanceRemovedSignal(HOME_TAG):Connect(removeHome)
	for _, folder in ipairs(CollectionService:GetTagged(HOME_TAG)) do
		local ok, err = pcall(addHome, folder)
		if not ok then
			warn("[HomeFx] could not track a home: " .. tostring(err))
		end
	end
	if localPlayer then
		localPlayer:GetAttributeChangedSignal(CASH_ATTR):Connect(function()
			for _, rec in ipairs(homeList) do
				if homeOwner(rec) == localUid then
					for _, pad in pairs(rec.Pads) do
						refreshPad(rec, pad)
					end
				end
			end
		end)
	end
	loopConn = RunService.RenderStepped:Connect(safeStep)
end

return HomeFx
