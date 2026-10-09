-- SpotService: every player owns a "spot" (their own cloud home) on the outer lobby ring.
--
-- * Assignment: after the profile loads the player gets Profile.SpotIndex when that spot is free,
--   otherwise the lowest free spot. The index is stored back in the profile and mirrored on the
--   player attribute Config.Attr.SpotIndex. Spots are freed when the owner leaves; players who
--   found no free spot are given one as soon as one opens up.
-- * Nameplate: NameLabel = display name, SubLabel = "3 pets • 120 ☁" (refreshed whenever the
--   pets / tokens change); unowned spots read "Free spot" / "Step in to claim".
-- * Showcase podium: a slowly turning + bobbing PetBuilder model of the owner's best (highest
--   rarity) pet with a small name / rarity tag. It is rebuilt only when that pet changes and is
--   only moved while a player is nearby.
--   Replication cost: a server-moved Anchored part replicates every CFrame change, and a pet has
--   up to ~70 parts. So the podium pet is ONE Anchored root (the PrimaryPart) with every other
--   part welded to it and unanchored: a spin / bob step is a single CFrame write on the root (the
--   welded parts follow on every client by themselves), at most 10 times a second, and only for
--   showcases with a player within CULL_RADIUS. PetBuilder.Animate is NOT used here (it would
--   write every part, and it cannot be used on a welded assembly): the pet keeps its rest pose.
-- * Remotes.GoToSpot -> Teleport (rate limited, refused during a match).
--
-- Public API: Init(lobbyInfo, deps)  GetSpot(player) -> SpotInfo|nil  Teleport(player) -> boolean
-- Extra: Refresh(player) (re-reads the profile now; normally automatic).
-- deps = { DataService = , PetService = }.
--
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local SpotService = {}

-- "\226\152\129" = cloud sign, "\226\128\162" = bullet (escaped so the file stays plain ASCII).
local CLOUD_GLYPH = "\226\152\129"
local BULLET = "\226\128\162"

local FREE_NAME = "Free spot"
local FREE_SUB = "Step in to claim"

local SHOWCASE_SCALE = 1.4 -- the podium pet is a bit larger than a follower
local HOVER_HEIGHT = 1.5 -- studs between the podium top and the pet's lowest point
local BOB_HEIGHT = 0.35 -- studs, +/-
local BOB_SPEED = 2.2 -- rad/s
local SPIN_SPEED = 0.55 -- rad/s
local ANIM_STEP = 0.1 -- seconds between server-side motion updates (10 Hz, ONE root CFrame write each)
local CULL_RADIUS = 55 -- move a showcase only while a player is this close (a bit more than the spot island)
local CULL_INTERVAL = 0.5 -- seconds between proximity checks
local REFRESH_INTERVAL = 1 -- seconds between profile signature checks
local PROFILE_WAIT = 20 -- give up waiting for a profile after this many seconds
local REMOTE_COOLDOWN = 0.25 -- per player per remote
local WELCOME_DELAY = 4 -- seconds after assignment before the "your spot" toast

local initialized = false
local running = false
local dataService = nil
local petService = nil
local spots = {} -- [index] = SpotInfo
local spotCount = 0
local owners = {} -- [index] = Player
local spotOf = {} -- [Player] = index
local waiting = {} -- [Player] = true : profile loaded but no free spot yet
local conns = {} -- [Player] = { RBXScriptConnection... }
local shows = {} -- [index] = showcase record (see makeShow)
local lastSig = {} -- [index] = last nameplate signature
local lastGo = {} -- [Player] = os.clock() of the last GoToSpot
local refreshQueued = {} -- [Player] = true while a deferred refresh is pending
local notifyRemote = nil
local departed = setmetatable({}, { __mode = "k" }) -- [Player] = true once PlayerRemoving ran

local rarityOrder = {}
local rarityColor = {}
for _, r in ipairs(Config.Rarities or {}) do
	rarityOrder[r.Id] = r.Order or 0
	rarityColor[r.Id] = r.Color
end

----------------------------------------------------------------------
-- Optional shared modules (PetBuilder / PetCatalog are written by other agents)
----------------------------------------------------------------------

local sharedCache = {} -- [name] = module | false

local function loadShared(name)
	local cached = sharedCache[name]
	if cached ~= nil then
		return cached or nil
	end
	sharedCache[name] = false
	local module = Shared:FindFirstChild(name)
	if module then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			sharedCache[name] = result
			return result
		end
		warn("[SpotService] could not load " .. name .. ": " .. tostring(result))
	end
	return nil
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function notify(player, text, kind, seconds)
	if not player or not player.Parent then
		return
	end
	if not notifyRemote then
		local ok, remote = pcall(Remotes.Get, "Notify")
		if ok then
			notifyRemote = remote
		end
	end
	if notifyRemote then
		pcall(function()
			notifyRemote:FireClient(player, text, kind or "info", seconds or 3)
		end)
	end
end

local function getProfile(player)
	if dataService and type(dataService.GetProfile) == "function" then
		local ok, profile = pcall(dataService.GetProfile, player)
		if ok and type(profile) == "table" then
			return profile
		end
	end
	return nil
end

local function readTokens(player)
	local value = player:GetAttribute(Config.Attr.Tokens)
	if type(value) == "number" then
		return math.floor(value)
	end
	return 0
end

local function displayNameOf(player)
	local name = player.DisplayName
	if type(name) ~= "string" or name == "" then
		name = player.Name
	end
	return name
end

local function setText(label, text)
	if not label then
		return
	end
	pcall(function()
		label.Text = text
	end)
end

local function setLabels(index, name, sub)
	local info = spots[index]
	if not info then
		return
	end
	setText(info.NameLabel, name)
	setText(info.SubLabel, sub)
end

-- Pivot a character somewhere and kill its momentum.
local function placeCharacter(char, cframe)
	if not char or not char.Parent then
		return false
	end
	local ok = pcall(function()
		char:PivotTo(cframe)
	end)
	if not ok then
		return false
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if root then
		root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
	end
	return true
end

----------------------------------------------------------------------
-- Showcase podium
----------------------------------------------------------------------

-- The tag floating above the pet: dark rounded card, pet name, rarity in the rarity colour.
local function buildTag(info)
	local anchor = Instance.new("Part")
	anchor.Name = "ShowcaseAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.4, 0.4, 0.4)
	anchor.CFrame = CFrame.new(info.PodiumCFrame.Position + Vector3.new(0, 6, 0))

	local gui = Instance.new("BillboardGui")
	gui.Name = "ShowcaseTag"
	gui.Adornee = anchor
	gui.Size = UDim2.fromScale(9, 2.7)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 90
	gui.LightInfluence = 0
	gui.Enabled = false

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.new(1, 0, 1, 0)
	card.BackgroundColor3 = Color3.fromRGB(255, 255, 255) -- the gradient below sets the real colour
	card.BackgroundTransparency = 0.18
	card.BorderSizePixel = 0
	card.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(Theme.Colors.PanelLight, Theme.Colors.Panel)
	gradient.Rotation = 90
	gradient.Parent = card
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.2, 0)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Name = "RarityStroke"
	stroke.Thickness = 5
	stroke.Color = Theme.Colors.PanelLight
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card

	local nameLabel = Theme.Label("", "Title", {
		Scaled = true,
		Stroke = 0.25,
		Props = {
			Name = "PetName",
			Size = UDim2.new(0.94, 0, 0.56, 0),
			Position = UDim2.new(0.03, 0, 0.06, 0),
		},
	})
	nameLabel.Parent = card

	local rarityLabel = Theme.Label("", "Heading", {
		Scaled = true,
		Stroke = 0.35,
		Props = {
			Name = "PetRarity",
			Size = UDim2.new(0.7, 0, 0.28, 0),
			Position = UDim2.new(0.15, 0, 0.64, 0),
		},
	})
	rarityLabel.Parent = card

	anchor.Parent = info.Folder or workspace
	gui.Parent = anchor
	return {
		Anchor = anchor,
		Gui = gui,
		NameLabel = nameLabel,
		RarityLabel = rarityLabel,
		Stroke = stroke,
	}
end

local function makeShow(index)
	local info = spots[index]
	local show = {
		Index = index,
		PetId = nil,
		Model = nil,
		Root = nil, -- the ONLY anchored part of the model (its PrimaryPart); the rest is welded to it
		RootFromPivot = nil, -- model pivot -> Root offset (identity unless the root has a PivotOffset)
		Rest = nil, -- pivot position when the pet is at the centre of its bob
		Rot = nil, -- rotation-only CFrame the spin is applied on top of
		Phase = (index * 1.37) % (math.pi * 2),
		Active = false,
		Tag = nil,
	}
	local ok, tag = pcall(buildTag, info)
	if ok then
		show.Tag = tag
	else
		warn("[SpotService] could not build the showcase tag: " .. tostring(tag))
	end
	return show
end

local function clearShowModel(show)
	if show.Model then
		pcall(function()
			show.Model:Destroy()
		end)
		show.Model = nil
	end
	show.Root = nil
	show.RootFromPivot = nil
	show.Active = false
	if show.Tag and show.Tag.Gui then
		show.Tag.Gui.Enabled = false
	end
end

-- Makes the model's PrimaryPart (or its "Body", or any part) the only Anchored part: every other part gets
-- a Weld to it (C0 = the current offset, so nothing shifts) and is unanchored. Returns the root, or nil
-- when the model has no part at all. Call it with the model already in its final pose.
local function weldToRoot(model)
	local root = nil
	if model:IsA("Model") then
		root = model.PrimaryPart
	end
	if not root or not root:IsA("BasePart") then
		root = model:FindFirstChild("Body")
	end
	if not root or not root:IsA("BasePart") then
		root = nil
		for _, inst in ipairs(model:GetDescendants()) do
			if inst:IsA("BasePart") then
				root = inst
				break
			end
		end
	end
	if not root then
		return nil
	end
	if model:IsA("Model") and model.PrimaryPart ~= root then
		model.PrimaryPart = root
	end

	local rootInverse = root.CFrame:Inverse()
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") and inst ~= root then
			local weld = Instance.new("Weld")
			weld.Name = "ShowcaseWeld"
			weld.Part0 = root
			weld.Part1 = inst
			weld.C0 = rootInverse * inst.CFrame
			weld.C1 = CFrame.new()
			weld.Parent = inst
			inst.Anchored = false
		end
	end
	root.Anchored = true
	return root
end

-- Builds + places the podium pet. petId may be nil (podium stays empty).
local function setShowcasePet(index, petId)
	local show = shows[index]
	local info = spots[index]
	if not show or not info then
		return
	end
	if show.PetId == petId then
		return
	end
	clearShowModel(show)
	show.PetId = petId
	if not petId then
		return
	end

	local builder = loadShared("PetBuilder")
	local catalog = loadShared("PetCatalog")
	if not builder or not catalog or type(builder.Build) ~= "function" or type(catalog.Get) ~= "function" then
		return
	end
	local def = catalog.Get(petId)
	if not def then
		return
	end

	local okBuild, model = pcall(builder.Build, def, { Scale = SHOWCASE_SCALE })
	if not okBuild or typeof(model) ~= "Instance" then
		warn("[SpotService] PetBuilder.Build failed for " .. tostring(petId) .. ": " .. tostring(model))
		return
	end

	-- Visual only: nothing may collide, be touched or be hit by raycasts.
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") then
			inst.Anchored = true
			inst.CanCollide = false
			inst.CanTouch = false
			inst.CanQuery = false
		end
	end

	-- Measure the model at the origin: how far its lowest point sits below the pivot, and its height.
	local podium = info.PodiumCFrame
	local bottomOffset = 1.2
	local height = 3
	local okBox = pcall(function()
		model:PivotTo(CFrame.new(0, 0, 0))
		local boxCf, boxSize = model:GetBoundingBox()
		local pivotY = model:GetPivot().Position.Y
		bottomOffset = pivotY - (boxCf.Position.Y - boxSize.Y * 0.5)
		height = boxSize.Y
	end)
	if not okBox and type(builder.GetHeight) == "function" then
		local okH, h = pcall(builder.GetHeight, def)
		if okH and type(h) == "number" then
			height = h * SHOWCASE_SCALE
			bottomOffset = height * 0.5
		end
	end

	show.Rest = podium.Position + Vector3.new(0, HOVER_HEIGHT + bottomOffset, 0)
	show.Rot = podium - podium.Position
	show.Model = model
	model.Name = "ShowcasePet"
	model:PivotTo(CFrame.new(show.Rest) * show.Rot)

	-- One anchored root, everything else welded to it (see the header): the spin / bob is one CFrame write.
	local root = weldToRoot(model)
	if root then
		show.Root = root
		show.RootFromPivot = model:GetPivot():Inverse() * root.CFrame
	end
	model.Parent = info.Folder or workspace

	-- Tag: name + rarity, floating above the highest point of the bob.
	local tag = show.Tag
	if tag then
		local color = rarityColor[def.Rarity] or Theme.Colors.PanelLight
		tag.Anchor.CFrame = CFrame.new(podium.Position + Vector3.new(0, HOVER_HEIGHT + height + BOB_HEIGHT + 1.9, 0))
		tag.NameLabel.Text = tostring(def.Name or petId)
		tag.RarityLabel.Text = tostring(def.Rarity or "")
		tag.RarityLabel.TextColor3 = color
		tag.Stroke.Color = color
		tag.Gui.Enabled = true
	end
end

-- One motion update for a showcase at time t: exactly ONE CFrame write (the anchored root); the welded
-- parts follow it. (Never PivotTo / PetBuilder.Animate here: those write every part.)
local function animateShow(show, t)
	local root = show.Root
	if not root or not root.Parent or not show.Rest then
		return
	end
	local bob = math.sin(t * BOB_SPEED + show.Phase) * BOB_HEIGHT
	local spin = t * SPIN_SPEED + show.Phase
	root.CFrame = CFrame.new(show.Rest + Vector3.new(0, bob, 0)) * show.Rot * CFrame.Angles(0, spin, 0)
		* show.RootFromPivot
end

-- Marks each showcase active when some player is within CULL_RADIUS of its podium.
local function cullShowcases()
	local positions = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local root = Util.GetRoot(player)
		if root then
			table.insert(positions, root.Position)
		end
	end
	for index, show in pairs(shows) do
		local active = false
		local info = spots[index]
		if show.Model and info then
			local center = info.PodiumCFrame.Position
			for _, pos in ipairs(positions) do
				if (pos - center).Magnitude <= CULL_RADIUS then
					active = true
					break
				end
			end
		end
		show.Active = active
	end
end

local function animationLoop()
	local lastCull = -CULL_INTERVAL -- cull immediately on the first pass
	while running do
		task.wait(ANIM_STEP)
		if not running then
			break
		end
		local now = os.clock()
		if now - lastCull >= CULL_INTERVAL then
			lastCull = now
			pcall(cullShowcases)
		end
		for _, show in pairs(shows) do
			if show.Active then
				animateShow(show, now)
			end
		end
	end
end

----------------------------------------------------------------------
-- Nameplate + best pet
----------------------------------------------------------------------

-- Highest rarity wins; ties prefer equipped pets, then the id (so the choice is stable).
local function pickBestPet(profile)
	local catalog = loadShared("PetCatalog")
	if not profile or type(profile.Pets) ~= "table" or not catalog or type(catalog.Get) ~= "function" then
		return nil
	end
	local equipped = {}
	if type(profile.Equipped) == "table" then
		for _, id in ipairs(profile.Equipped) do
			equipped[id] = true
		end
	end
	local bestId, bestOrder, bestEquipped = nil, -1, false
	for petId, count in pairs(profile.Pets) do
		if type(count) == "number" and count > 0 then
			local def = catalog.Get(petId)
			if def then
				local order = rarityOrder[def.Rarity] or 0
				local isEq = equipped[petId] == true
				local better = false
				if order > bestOrder then
					better = true
				elseif order == bestOrder then
					if isEq and not bestEquipped then
						better = true
					elseif isEq == bestEquipped and bestId ~= nil and tostring(petId) < tostring(bestId) then
						better = true
					end
				end
				if better then
					bestId, bestOrder, bestEquipped = petId, order, isEq
				end
			end
		end
	end
	return bestId
end

local function countPets(profile)
	local total = 0
	if profile and type(profile.Pets) == "table" then
		for _, count in pairs(profile.Pets) do
			if type(count) == "number" and count > 0 then
				total = total + math.floor(count)
			end
		end
	end
	return total
end

-- Re-reads one owner's profile; touches the labels / podium only when something changed.
local function refreshSpot(index)
	local owner = owners[index]
	if not owner or not owner.Parent then
		return
	end
	local profile = getProfile(owner)
	local tokens = readTokens(owner)
	local petTotal = countPets(profile)
	local bestId = pickBestPet(profile)
	local name = displayNameOf(owner)

	local sig = name .. "|" .. tostring(tokens) .. "|" .. tostring(petTotal) .. "|" .. tostring(bestId)
	if lastSig[index] == sig then
		return
	end
	lastSig[index] = sig

	local petsText = tostring(petTotal) .. " pets"
	if petTotal == 1 then
		petsText = "1 pet"
	end
	setLabels(index, name, petsText .. " " .. BULLET .. " " .. Util.Commas(tokens) .. " " .. CLOUD_GLYPH)
	setShowcasePet(index, bestId)
end

function SpotService.Refresh(player)
	local index = spotOf[player]
	if index then
		refreshSpot(index)
	end
end

-- Several attribute changes in one frame produce a single refresh.
local function queueRefresh(player)
	if refreshQueued[player] then
		return
	end
	refreshQueued[player] = true
	task.defer(function()
		refreshQueued[player] = nil
		if player.Parent then
			SpotService.Refresh(player)
		end
	end)
end

local function refreshLoop()
	while running do
		task.wait(REFRESH_INTERVAL)
		if not running then
			break
		end
		for index = 1, spotCount do
			if owners[index] then
				local ok, err = pcall(refreshSpot, index)
				if not ok then
					warn("[SpotService] refresh failed: " .. tostring(err))
				end
			end
		end
	end
end

----------------------------------------------------------------------
-- Assignment
----------------------------------------------------------------------

local function claimSpot(player, index, profile)
	owners[index] = player
	spotOf[player] = index
	waiting[player] = nil
	lastSig[index] = nil

	player:SetAttribute(Config.Attr.SpotIndex, index)
	local info = spots[index]
	if info and info.Folder then
		pcall(function()
			info.Folder:SetAttribute("OwnerUserId", player.UserId)
		end)
	end

	if profile and profile.SpotIndex ~= index then
		profile.SpotIndex = index
		if dataService and type(dataService.MarkDirty) == "function" then
			pcall(dataService.MarkDirty, player)
		end
	end

	if not shows[index] then
		shows[index] = makeShow(index)
	end

	local list = {}
	conns[player] = list
	table.insert(list, player:GetAttributeChangedSignal(Config.Attr.Tokens):Connect(function()
		queueRefresh(player)
	end))
	table.insert(list, player:GetAttributeChangedSignal(Config.Attr.EquippedPets):Connect(function()
		queueRefresh(player)
	end))

	refreshSpot(index)

	task.delay(WELCOME_DELAY, function()
		if player.Parent and spotOf[player] == index then
			notify(player, "Your cloud home is spot " .. tostring(index) .. " - use the house button!", "info", 5)
		end
	end)
end

local function freeSpot(player)
	waiting[player] = nil
	refreshQueued[player] = nil
	local list = conns[player]
	conns[player] = nil
	if list then
		for _, conn in ipairs(list) do
			conn:Disconnect()
		end
	end
	local index = spotOf[player]
	spotOf[player] = nil
	if not index then
		return
	end
	if owners[index] == player then
		owners[index] = nil
	end
	lastSig[index] = nil
	if player.Parent then
		player:SetAttribute(Config.Attr.SpotIndex, nil)
	end
	local info = spots[index]
	if info and info.Folder then
		pcall(function()
			info.Folder:SetAttribute("OwnerUserId", nil)
		end)
	end
	local show = shows[index]
	if show then
		setShowcasePet(index, nil)
	end
	setLabels(index, FREE_NAME, FREE_SUB)
end

local function lowestFreeSpot()
	for index = 1, spotCount do
		if spots[index] and not owners[index] then
			return index
		end
	end
	return nil
end

-- Gives `player` a spot (preferred one first). Idempotent; no free spot => parked in `waiting`.
local function assignSpot(player)
	if not player or not player.Parent or departed[player] or spotOf[player] then
		return
	end
	local profile = getProfile(player)
	local index = nil
	local wanted = profile and profile.SpotIndex
	if type(wanted) == "number" and wanted == math.floor(wanted) and spots[wanted] and not owners[wanted] then
		index = wanted
	end
	if not index then
		index = lowestFreeSpot()
	end
	if not index then
		waiting[player] = true
		return
	end
	claimSpot(player, index, profile)
end

local function assignWaiting()
	for player in pairs(waiting) do
		if player.Parent then
			if lowestFreeSpot() then
				assignSpot(player)
			end
		else
			waiting[player] = nil
		end
	end
end

local function hasProfile(player)
	if not dataService or type(dataService.GetProfile) ~= "function" then
		return true -- nothing to wait for
	end
	return getProfile(player) ~= nil
end

-- Waits (bounded) for the player's profile, then assigns. The ProfileLoaded signal usually wins.
local function onPlayerAdded(player)
	task.spawn(function()
		local waited = 0
		while player.Parent and not spotOf[player] and not hasProfile(player) and waited < PROFILE_WAIT do
			task.wait(0.25)
			waited = waited + 0.25
		end
		if player.Parent then
			assignSpot(player)
		end
	end)
end

local function onPlayerRemoving(player)
	departed[player] = true
	lastGo[player] = nil
	local had = spotOf[player] ~= nil
	freeSpot(player)
	if had then
		assignWaiting()
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function SpotService.GetSpot(player)
	local index = player and spotOf[player]
	if index then
		return spots[index]
	end
	return nil
end

-- Pivot the player's character to their spot (ignored during a match). Returns true on success.
function SpotService.Teleport(player)
	if not player or not player.Parent then
		return false
	end
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return false
	end
	local info = SpotService.GetSpot(player)
	if not info or typeof(info.SpawnCFrame) ~= "CFrame" then
		return false
	end
	local humanoid = Util.GetHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	return placeCharacter(player.Character, info.SpawnCFrame)
end

local function onGoToSpot(player)
	local now = os.clock()
	local last = lastGo[player]
	if last and now - last < REMOTE_COOLDOWN then
		return
	end
	lastGo[player] = now
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return
	end
	if not spotOf[player] then
		notify(player, "No free spot right now - hang in there!", "bad", 3)
		return
	end
	SpotService.Teleport(player)
end

function SpotService.Init(lobbyInfo, deps)
	if initialized then
		return
	end
	initialized = true
	deps = deps or {}
	dataService = deps.DataService
	petService = deps.PetService

	local list = lobbyInfo and lobbyInfo.Spots
	if type(list) ~= "table" then
		warn("[SpotService] lobbyInfo.Spots is missing; spots are disabled")
		list = {}
	end
	for index, info in pairs(list) do
		if type(index) == "number" and type(info) == "table" and typeof(info.SpawnCFrame) == "CFrame"
			and typeof(info.PodiumCFrame) == "CFrame" then
			spots[index] = info
			if index > spotCount then
				spotCount = index
			end
		end
	end
	for index = 1, spotCount do
		if spots[index] then
			setLabels(index, FREE_NAME, FREE_SUB)
		end
	end

	-- Assignment hooks: profile loaded (fast path) + a bounded fallback poll per player.
	if dataService and dataService.ProfileLoaded and type(dataService.ProfileLoaded.Connect) == "function" then
		dataService.ProfileLoaded:Connect(function(player)
			if player and player.Parent then
				assignSpot(player)
			end
		end)
	end
	-- Pet changes show up on the nameplate / podium immediately.
	if petService and petService.PerksChanged and type(petService.PerksChanged.Connect) == "function" then
		petService.PerksChanged:Connect(function(player)
			if player and player.Parent then
				queueRefresh(player)
			end
		end)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	local okRemote, goRemote = pcall(Remotes.Get, "GoToSpot")
	if okRemote and goRemote then
		goRemote.OnServerEvent:Connect(onGoToSpot)
	else
		warn("[SpotService] GoToSpot remote unavailable")
	end

	running = true
	task.spawn(refreshLoop)
	task.spawn(animationLoop)
	game:BindToClose(function()
		running = false
	end)
end

return SpotService
