-- SpotService: the home plots on the outer lobby ring (one per player, claimed with E at the gate).
--
-- * Claiming (ARCHITECTURE_V3.md "Phase 2: Tycoon homes"; replaces the v2 auto-assignment): nobody gets a plot on
--   join. Each free plot's gate carries a "Claim Home" ProximityPrompt (HomeBuilder builds it, TycoonService handles
--   it and calls SpotService.Claim). One plot per player, refused during a match; the plot is the player's for the
--   session and is released when they leave (TycoonService clears the build, the gate reads "Claim Home" again).
--   The claimed index is mirrored on the player attribute Config.Attr.SpotIndex (absent while the player has no
--   plot) and remembered in Profile.SpotIndex as the player's LAST plot: a returning player whose last plot is free
--   gets the side toast "Welcome back! Press E at your gate", everyone else "Pick a free home: press E at its gate".
-- * Nameplate (LobbyBuilder builds it: a compact PIXEL-sized tag, World text rule): NameLabel = the owner's display
--   name, SubLabel = "Home Level 12 • ★★" (the Home Level and one star per Prestige; "★ x7" past five stars),
--   refreshed whenever the home changes; the avatar disc shows the owner's headshot (Players:GetUserThumbnailAsync in
--   pcall, cached per user; the silhouette built from frames is the fallback). Free plots read "Free home" /
--   "Press E at the gate" with a "+" on the disc.
-- * Showcase podium: a slowly turning + bobbing PetBuilder model of the owner's best (highest
--   rarity) pet with a small name / rarity tag. It is rebuilt only when that pet changes and is
--   only moved while a player is nearby.
--   Replication cost: a server-moved Anchored part replicates every CFrame change, and a pet has
--   up to ~70 parts. So the podium pet is ONE Anchored root (the PrimaryPart) with every other
--   part welded to it and unanchored: a spin / bob step is a single CFrame write on the root (the
--   welded parts follow on every client by themselves), at most 10 times a second, and only for
--   showcases with a player within CULL_RADIUS. PetBuilder.Animate is NOT used here (it would
--   write every part, and it cannot be used on a welded assembly): the pet keeps its rest pose.
-- * Remotes.GoToSpot -> Teleport (rate limited, refused during a match): home when the player has a plot, otherwise
--   in front of the gate of their last plot when it is free, else of the nearest free plot.
--
-- Public API: Init(lobbyInfo, deps)  GetSpot(player) -> SpotInfo|nil (the CLAIMED plot)  Teleport(player) -> boolean
-- Phase 2 (used by TycoonService; the plot data stays here):
--   Claim(player, index) -> ok, reason        validated: a known plot, free, the player has none, not in a match
--   Release(player) -> index|nil               frees the player's plot (also automatic on leave)
--   GetOwner(index) -> Player|nil, GetSpotByIndex(index) -> SpotInfo|nil, GetSpots() -> { [index] = SpotInfo }
--   FindFreeSpot(position|nil, preferIndex|nil) -> SpotInfo|nil   the preferred plot when free, else the free plot
--                                              nearest to `position` (the lowest index without one)
--   SuggestSpot(player) -> SpotInfo|nil, owned  the claimed plot, else the last plot when free, else the nearest free
--   GateCFrame(spotInfo) -> CFrame              the gate on the ground (LookVector = towards the street)
--   Signals Claimed (player, index), Released (player, index)
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
SpotService.Claimed = Util.Signal() -- Fire(player, index)
SpotService.Released = Util.Signal() -- Fire(player, index)

-- "\226\128\162" = bullet, "\226\152\133" = black star (escaped so the file stays plain ASCII).
local BULLET = "\226\128\162"
local STAR = "\226\152\133"
local MAX_STAR_GLYPHS = 5 -- more stars than this read "★ x7"

local FREE_NAME = "Free home"
local FREE_SUB = "Press E at the gate"

-- Showcase tag (World text rule): pixel-sized, names >= 22 px, info >= 18 px, compact solid plate.
local TAG_W, TAG_H = 300, 96
local TAG_NAME_PX = 26
local TAG_RARITY_PX = 18
local TAG_RANGE = 80
local TAG_LIFT = -1.2 -- studs: the plate's bottom edge sits ~0.7 stud over the highest point of the bob
local INK = Theme.Colors.TextStroke or Theme.Colors.Ink

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
local HEADSHOT_RETRY = 120 -- seconds before a failed headshot request may be tried again
local WELCOME_DELAY = 4 -- seconds after the profile loaded before the "press E at your gate" toast
local GATE_OUTSIDE = 6 -- studs in front of the gate (street side) where GoToSpot puts a player without a plot
local GATE_LIFT = 3 -- studs above the ground for that placement (the character's root height)

local initialized = false
local running = false
local dataService = nil
local petService = nil
local spots = {} -- [index] = SpotInfo
local spotCount = 0
local owners = {} -- [index] = Player
local spotOf = {} -- [Player] = index
local conns = {} -- [Player] = { RBXScriptConnection... }
local shows = {} -- [index] = showcase record (see makeShow)
local lastSig = {} -- [index] = last nameplate signature
local lastGo = {} -- [Player] = os.clock() of the last GoToSpot
local welcomed = {} -- [Player] = true once the join toast was scheduled
local headshots = {} -- [userId] = content string : the GetUserThumbnailAsync cache
local headshotFailed = {} -- [userId] = os.clock() of the last failed request (retried after HEADSHOT_RETRY)
local headshotPending = {} -- [userId] = true while a request runs
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

-- The nameplate's avatar disc (built by LobbyBuilder; a nameplate without one is simply left alone).
local function avatarOf(index)
	local info = spots[index]
	if not info then
		return nil
	end
	local gui = info.Nameplate
	if typeof(gui) ~= "Instance" and typeof(info.NameLabel) == "Instance" then
		gui = info.NameLabel:FindFirstAncestorOfClass("BillboardGui")
	end
	if typeof(gui) ~= "Instance" then
		return nil
	end
	local disc = gui:FindFirstChild("Avatar", true)
	if disc and disc:IsA("GuiObject") then
		return disc
	end
	return nil
end

-- mode: "Free" (the "+"), "Owned" (silhouette) or "Headshot" (image = the thumbnail content).
local function setAvatar(index, mode, image)
	local disc = avatarOf(index)
	if not disc then
		return
	end
	pcall(function()
		local color = disc:GetAttribute(mode == "Free" and "FreeColor" or "OwnedColor")
		if typeof(color) == "Color3" then
			disc.BackgroundColor3 = color
		end
		local shot = disc:FindFirstChild("Headshot")
		local silhouette = disc:FindFirstChild("Silhouette")
		local free = disc:FindFirstChild("FreeIcon")
		if free then
			free.Visible = mode == "Free"
		end
		if silhouette then
			silhouette.Visible = mode == "Owned"
		end
		if shot then
			shot.Image = (mode == "Headshot" and image) or ""
			shot.Visible = mode == "Headshot"
		end
	end)
end

-- Shows the owner's headshot on their nameplate: cached per user, fetched once in the background (the call
-- yields and fails for Studio test players, so the silhouette stays as the fallback).
local function loadHeadshot(player, index)
	local userId = player.UserId
	local cached = headshots[userId]
	if cached then
		setAvatar(index, "Headshot", cached)
		return
	end
	local failedAt = headshotFailed[userId]
	if headshotPending[userId] or (failedAt and os.clock() - failedAt < HEADSHOT_RETRY) then
		return
	end
	headshotPending[userId] = true
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		headshotPending[userId] = nil
		if ok and type(content) == "string" and content ~= "" then
			headshots[userId] = content
			headshotFailed[userId] = nil
		else
			headshotFailed[userId] = os.clock()
			return
		end
		-- wherever this user owns a home now: matched by UserId, so a player who left and rejoined while the
		-- request ran (a new Player object) still gets it; a home freed meanwhile keeps its "+"
		for index, owner in pairs(owners) do
			if owner.UserId == userId and owner.Parent then
				setAvatar(index, "Headshot", content)
			end
		end
	end)
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

-- The tag floating above the pet (World text rule): a PIXEL-sized BillboardGui, so it reads the same at any
-- distance: the pet name (big, outlined) over a rarity pill in the rarity colour, on a compact navy plate with a
-- rarity-coloured outline that sizes itself to the text. Its bottom edge sits just over the bobbing pet.
local function tagLabel(parent, name, text, role, size, order)
	local label = Theme.Label(text, role, {
		Size = size,
		Stroke = 1, -- the glyph outline replaces the classic stroke
		Outline = 2.5,
		OutlineColor = INK,
		Props = {
			Name = name,
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, size + 4),
			TextWrapped = false,
			LayoutOrder = order,
		},
	})
	label.Parent = parent
	return label
end

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
	gui.Size = UDim2.fromOffset(TAG_W, TAG_H)
	gui.SizeOffset = Vector2.new(0, 0.5) -- the bottom edge sits on the anchor (+ TAG_LIFT)
	gui.StudsOffsetWorldSpace = Vector3.new(0, TAG_LIFT, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = TAG_RANGE
	gui.LightInfluence = 0
	gui.ClipsDescendants = false
	gui.Enabled = false

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 1)
	card.Position = UDim2.new(0.5, 0, 1, 0)
	card.Size = UDim2.fromOffset(140, 0)
	card.AutomaticSize = Enum.AutomaticSize.XY
	card.BackgroundColor3 = Color3.fromRGB(255, 255, 255) -- the gradient below sets the real colour
	card.BackgroundTransparency = 0.04
	card.BorderSizePixel = 0
	card.Parent = gui
	Theme.Gradient(card, Theme.Colors.PanelLight, Theme.Colors.Panel, 90)
	Theme.Corner(card, UDim.new(0, 14))
	local stroke = Theme.Stroke(card, Theme.Colors.PanelLight, 3.5, 0)
	stroke.Name = "RarityStroke"
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = card
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 3)
	layout.Parent = card

	local nameLabel = tagLabel(card, "PetName", "", "Title", TAG_NAME_PX, 1)

	local pill = Instance.new("Frame")
	pill.Name = "RarityPill"
	pill.Size = UDim2.fromOffset(0, TAG_RARITY_PX + 8)
	pill.AutomaticSize = Enum.AutomaticSize.XY
	pill.BackgroundColor3 = Theme.Colors.PanelLight
	pill.BorderSizePixel = 0
	pill.LayoutOrder = 2
	pill.Parent = card
	Theme.Corner(pill, UDim.new(0, 10))
	Theme.Stroke(pill, INK, 2.5, 0)
	local pillPad = Instance.new("UIPadding")
	pillPad.PaddingTop = UDim.new(0, 2)
	pillPad.PaddingBottom = UDim.new(0, 3)
	pillPad.PaddingLeft = UDim.new(0, 10)
	pillPad.PaddingRight = UDim.new(0, 10)
	pillPad.Parent = pill
	local rarityLabel = tagLabel(pill, "PetRarity", "", "Heading", TAG_RARITY_PX, 1)

	anchor.Parent = info.Folder or workspace
	gui.Parent = anchor
	return {
		Anchor = anchor,
		Gui = gui,
		NameLabel = nameLabel,
		RarityLabel = rarityLabel,
		RarityPill = pill,
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
		tag.RarityPill.BackgroundColor3 = color:Lerp(Theme.Colors.Panel, 0.2)
		-- a very dark rarity colour (Secret) would vanish against the navy plate: lift the outline
		local luma = 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
		tag.Stroke.Color = (luma < 0.35) and color:Lerp(Theme.Colors.Muted or Theme.Colors.White, 0.55) or color
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

local function wholeNumber(v, maxValue)
	if type(v) ~= "number" or v ~= v or v < 0 then
		return 0
	end
	if v == math.huge then
		return maxValue
	end
	return math.min(math.floor(v), maxValue)
end

-- Home Level + Prestige stars of a profile's Home (the live table: read only).
local function homeStatsOf(profile)
	local home = profile and profile.Home
	if type(home) ~= "table" then
		return 0, 0
	end
	local level = nil
	local catalog = loadShared("TycoonCatalog")
	if catalog and type(catalog.HomeLevelOf) == "function" then
		local ok, value = pcall(catalog.HomeLevelOf, home)
		if ok and type(value) == "number" then
			level = value
		end
	end
	if level == nil then
		level = home.Level
	end
	return wholeNumber(level, 100000), wholeNumber(home.Prestige, 100000)
end

-- "Home Level 12" / "Home Level 12 • ★★" / "Home Level 3 • ★ x7"
local function homeLine(level, stars)
	local text = "Home Level " .. tostring(level)
	if stars > 0 then
		local glyphs
		if stars <= MAX_STAR_GLYPHS then
			glyphs = string.rep(STAR, stars)
		else
			glyphs = STAR .. " x" .. tostring(stars)
		end
		text = text .. " " .. BULLET .. " " .. glyphs
	end
	return text
end

-- Re-reads one owner's profile; touches the labels / podium only when something changed.
local function refreshSpot(index)
	local owner = owners[index]
	if not owner or not owner.Parent then
		return
	end
	local profile = getProfile(owner)
	local level, stars = homeStatsOf(profile)
	local bestId = pickBestPet(profile)
	local name = displayNameOf(owner)

	local sig = name .. "|" .. tostring(level) .. "|" .. tostring(stars) .. "|" .. tostring(bestId)
	if lastSig[index] == sig then
		return
	end
	lastSig[index] = sig
	setLabels(index, name, homeLine(level, stars))
	setShowcasePet(index, bestId)
end

function SpotService.Refresh(player)
	local index = player and spotOf[player]
	if index then
		refreshSpot(index)
	end
end

-- Several changes in one frame produce a single refresh.
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
-- Gates, free plots
----------------------------------------------------------------------

local function validIndex(index)
	return type(index) == "number" and index == index and index == math.floor(index) and spots[index] ~= nil
end

-- The gate on the ground (LookVector = towards the street): SpotInfo.GateCFrame, else derived from the plot.
function SpotService.GateCFrame(info)
	if type(info) ~= "table" then
		return nil
	end
	if typeof(info.GateCFrame) == "CFrame" then
		return info.GateCFrame
	end
	if typeof(info.PlotCFrame) == "CFrame" then
		local size = tonumber(info.PlotSize) or Config.Lobby.PlotSize or 72
		return info.PlotCFrame * CFrame.new(0, 0, -size / 2)
	end
	return nil
end

-- Where a player without a plot is put: just outside the gate (street side), facing into the yard.
local function gateArrivalCFrame(info)
	local gate = SpotService.GateCFrame(info)
	if not gate then
		return info and info.SpawnCFrame or nil
	end
	local pos = (gate * CFrame.new(0, GATE_LIFT, -GATE_OUTSIDE)).Position
	local inward = -gate.LookVector
	local flat = Vector3.new(inward.X, 0, inward.Z)
	if flat.Magnitude < 1e-3 then
		return CFrame.new(pos)
	end
	return CFrame.lookAt(pos, pos + flat.Unit)
end

local function gatePosition(info)
	local gate = SpotService.GateCFrame(info)
	if gate then
		return gate.Position
	end
	if typeof(info.Center) == "Vector3" then
		return info.Center
	end
	if typeof(info.SpawnCFrame) == "CFrame" then
		return info.SpawnCFrame.Position
	end
	return nil
end

function SpotService.FindFreeSpot(position, preferIndex)
	if validIndex(preferIndex) and not owners[preferIndex] then
		return spots[preferIndex]
	end
	local best, bestDist = nil, math.huge
	for index = 1, spotCount do
		local info = spots[index]
		if info and not owners[index] then
			if typeof(position) ~= "Vector3" then
				return info -- the lowest free index
			end
			local at = gatePosition(info)
			local d = at and (at - position).Magnitude or math.huge
			if d < bestDist then
				best, bestDist = info, d
			end
		end
	end
	return best
end

local function lastSpotIndex(player)
	local profile = getProfile(player)
	local wanted = profile and profile.SpotIndex
	if validIndex(wanted) then
		return wanted
	end
	return nil
end

function SpotService.SuggestSpot(player)
	if not player then
		return nil, false
	end
	local index = spotOf[player]
	if index then
		return spots[index], true
	end
	local root = Util.GetRoot(player)
	return SpotService.FindFreeSpot(root and root.Position or nil, lastSpotIndex(player)), false
end

----------------------------------------------------------------------
-- Claim / release
----------------------------------------------------------------------

local function freeSpot(player)
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
		return nil
	end
	if owners[index] == player then
		owners[index] = nil
	end
	lastSig[index] = nil
	if player.Parent then
		pcall(function()
			player:SetAttribute(Config.Attr.SpotIndex, nil)
		end)
	end
	local info = spots[index]
	if info and info.Folder then
		pcall(function()
			info.Folder:SetAttribute("OwnerUserId", nil)
		end)
	end
	if shows[index] then
		setShowcasePet(index, nil)
	end
	setLabels(index, FREE_NAME, FREE_SUB)
	setAvatar(index, "Free")
	return index
end

function SpotService.Claim(player, index)
	if not initialized then
		return false, "Homes are not ready yet"
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") or not player.Parent or departed[player] then
		return false, "Not in the game"
	end
	if not validIndex(index) then
		return false, "Unknown home"
	end
	if spotOf[player] then
		if spotOf[player] == index then
			return false, "This is already your home"
		end
		return false, "You already have a home"
	end
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return false, "Finish your match first"
	end
	local owner = owners[index]
	if owner then
		if owner.Parent then
			return false, "This home belongs to " .. displayNameOf(owner)
		end
		freeSpot(owner) -- a stale owner (left without PlayerRemoving): free it now
	end

	owners[index] = player
	spotOf[player] = index
	lastSig[index] = nil
	pcall(function()
		player:SetAttribute(Config.Attr.SpotIndex, index)
	end)
	local info = spots[index]
	if info and info.Folder then
		pcall(function()
			info.Folder:SetAttribute("OwnerUserId", player.UserId)
		end)
	end

	-- remember the LAST plot (the welcome-back toast offers it again next time)
	local profile = getProfile(player)
	if profile and profile.SpotIndex ~= index then
		profile.SpotIndex = index
		if dataService and type(dataService.MarkDirty) == "function" then
			pcall(dataService.MarkDirty, player)
		end
	end

	if not shows[index] then
		shows[index] = makeShow(index)
	end
	setAvatar(index, "Owned")
	loadHeadshot(player, index)

	local list = {}
	conns[player] = list
	table.insert(list, player:GetAttributeChangedSignal(Config.Attr.EquippedPets):Connect(function()
		queueRefresh(player)
	end))
	refreshSpot(index)
	SpotService.Claimed:Fire(player, index)
	return true, nil
end

function SpotService.Release(player)
	if not player then
		return nil
	end
	local index = freeSpot(player)
	if index then
		SpotService.Released:Fire(player, index)
	end
	return index
end

----------------------------------------------------------------------
-- Join / leave
----------------------------------------------------------------------

local function hasProfile(player)
	if not dataService or type(dataService.GetProfile) ~= "function" then
		return true -- nothing to wait for
	end
	return getProfile(player) ~= nil
end

-- The join toast (side toast, never centred): the last plot when it is still free, any free gate otherwise.
local function scheduleWelcome(player)
	if welcomed[player] or not player.Parent or departed[player] then
		return
	end
	welcomed[player] = true
	task.delay(WELCOME_DELAY, function()
		if not player.Parent or departed[player] or spotOf[player] then
			return
		end
		local last = lastSpotIndex(player)
		if last and not owners[last] then
			notify(player, "Welcome back! Press E at your gate (home #" .. tostring(last) .. ").", "info", 6)
		elseif SpotService.FindFreeSpot(nil, nil) then
			notify(player, "Pick a free home: press E at its gate to claim it!", "info", 6)
		else
			notify(player, "Every home is taken right now - one frees up when a player leaves.", "info", 6)
		end
	end)
end

-- Waits (bounded) for the player's profile, then schedules the welcome toast. ProfileLoaded usually wins.
local function onPlayerAdded(player)
	task.spawn(function()
		local waited = 0
		while player.Parent and not hasProfile(player) and waited < PROFILE_WAIT do
			task.wait(0.25)
			waited = waited + 0.25
		end
		if player.Parent then
			scheduleWelcome(player)
		end
	end)
end

local function onPlayerRemoving(player)
	departed[player] = true
	lastGo[player] = nil
	welcomed[player] = nil
	SpotService.Release(player)
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

function SpotService.GetOwner(index)
	local owner = validIndex(index) and owners[index] or nil
	if owner and owner.Parent then
		return owner
	end
	return nil
end

function SpotService.GetSpotByIndex(index)
	if validIndex(index) then
		return spots[index]
	end
	return nil
end

function SpotService.GetSpots()
	return spots
end

-- Pivots the character home (claimed plot) or, without a plot, to the gate of the suggested free plot.
-- Ignored during a match. Returns true when the character was moved.
function SpotService.Teleport(player)
	if not player or not player.Parent then
		return false
	end
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return false
	end
	local humanoid = Util.GetHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	local info = SpotService.GetSpot(player)
	if info and typeof(info.SpawnCFrame) == "CFrame" then
		return placeCharacter(player.Character, info.SpawnCFrame)
	end
	local free = SpotService.SuggestSpot(player)
	local target = free and gateArrivalCFrame(free)
	if typeof(target) ~= "CFrame" then
		return false
	end
	return placeCharacter(player.Character, target)
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
	if not spotOf[player] and not SpotService.SuggestSpot(player) then
		notify(player, "Every home is taken right now - one frees up when a player leaves.", "bad", 3)
		return
	end
	local moved = SpotService.Teleport(player)
	if moved and not spotOf[player] then
		notify(player, "Press E at the gate to claim this home!", "info", 4)
	end
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
			setAvatar(index, "Free")
		end
	end

	-- Join toast once the profile is there (no auto-assignment: plots are claimed with E at the gate).
	if dataService and dataService.ProfileLoaded and type(dataService.ProfileLoaded.Connect) == "function" then
		dataService.ProfileLoaded:Connect(function(player)
			if player and player.Parent then
				scheduleWelcome(player)
			end
		end)
	end
	-- Pet changes show up on the podium immediately.
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
