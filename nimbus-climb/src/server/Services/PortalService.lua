-- PortalService (v3 polish): forms parties on the lobby portal pads, locks the members in until launch and
-- shows every portal's state on a readable billboard.
--
-- Standing inside a portal Zone (the "ready pad") puts a player in that portal's party. The first
-- player starts a countdown; a full party shortens it. When it reaches zero the party is handed to
-- MatchService.StartMatch. MatchService is passed in through Init (no require) so the two services
-- never form a circular dependency. One party per entry of Config.Difficulties, matched to
-- lobbyInfo.Portals[difficulty.Id] (no difficulty id is hard-coded here).
--
-- Lock-in (asked for after the playtest): a party member is LOCKED on the pad for the whole countdown.
--   * Their character parts move to the collision group NC_PortalLocked. Every pad has five invisible walls
--     (four sides + a ceiling) in NC_PortalWall, which collides ONLY with NC_PortalLocked: everybody else walks
--     straight through, and raycasts / overlap queries (Default group) never see the walls. Walking, jumping
--     and dashing (velocity based) all stop at the walls.
--   * Server safety net: the 5 Hz zone poll puts a locked player who is outside the zone anyway (flung,
--     teleported) back on the pad, with a side toast that explains the Leave button.
--   * The only way out is the Leave button of the party panel (Remotes.LeaveParty, validated + rate-limited):
--     unlock, LEAVE_LOCKOUT, and a step off the pad. Launch, a cancelled countdown, death, a match and leaving
--     the game unlock as well.
--   * While a countdown runs the side walls show a soft ForceField shimmer in the portal colour.
-- Billboard (World text rule, ARCHITECTURE_V3.md): a PIXEL-sized BillboardGui above each gate replaces the
-- studs-sized card LobbyBuilder made: difficulty name + stars, "2/4 players" and a status pill ("Step in to
-- play" / "Starting in 12"). The server writes a text only when it changes (at most once per second per
-- line) and mirrors the numbers as attributes on the portal model (PartyCount, PartyMax, Countdown).
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local PhysicsService = game:GetService("PhysicsService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)

local PortalService = {}

----------------------------------------------------------------------
-- Tunables local to this module
----------------------------------------------------------------------
local POLL = 0.2 -- zone poll period (5 Hz); also the safety-net reaction time
local STATE_INTERVAL = 1 -- PartyState refresh period
local LEAVE_LOCKOUT = 3 -- seconds a player cannot re-join after pressing Leave
local FAILED_LOCKOUT = 4 -- ... after a failed launch
local EJECT_DISTANCE = 12 -- studs the Leave button moves a player off the pad (outside the walls)
local ZONE_HYSTERESIS = 1.5 -- extra studs of tolerance for players already inside (no edge flicker)
local LEAVE_COOLDOWN = 0.5 -- LeaveParty rate limit per player
local PULL_TOAST_COOLDOWN = 5 -- seconds between two "press Leave" toasts after a safety-net pull

-- Lock-in walls. The inner faces sit ZONE_HYSTERESIS outside the zone, so a member's root always stays inside
-- the (hysteresis) zone and the safety net never fights the walls.
local LOCK_GROUP = "NC_PortalLocked"
local WALL_GROUP = "NC_PortalWall"
local WALL_THICKNESS = 2
local WALL_HEIGHT = 14 -- studs above the pad surface (a full jump tops out ~10 studs up)
local WALL_DEPTH = 2 -- studs the walls reach below the pad surface
local BARRIER_TRANSPARENCY = 0.55 -- side walls while a countdown runs (ForceField shimmer)
local PAD_ROOT_HEIGHT = 3.2 -- root height above the pad surface for a safety-net placement
local PAD_SPREAD = 2.5 -- members put back on the pad stand on a ring this wide

-- Billboard (pixels; World text rule: names >= 22 px, info lines >= 18 px, compact plate)
local BB = {
	Width = 380, -- transparent container; the plate inside is sized to its text
	Height = 150,
	MaxDistance = 120,
	Gap = 2.5, -- studs between the top of the gate and the bottom of the plate
	NameText = 32,
	InfoText = 21,
	StatusText = 25,
	PlateMinW = 190,
}

local STAR_FULL = "\226\152\133"
local STAR_EMPTY = "\226\152\134"
local MAX_STARS = 5

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local matchService = nil
local initialized = false
local running = false

local parties = {} -- portal id -> party
local order = {} -- portal ids in lobby order
local playerParty = {} -- Player -> portal id
local lockedUntil = {} -- Player -> clock deadline for re-joining
local mustExit = {} -- Player -> true until they have been seen outside every zone
local starting = {} -- Player -> true while a launched match is being built
local fullNotified = {} -- Player -> portal id they were told is full
local locks = {} -- Player -> { PortalId, Groups = { [BasePart] = previous group }, Conns }
local lastLeave = {} -- Player -> clock of the last accepted LeaveParty
local lastPullToast = {} -- Player -> clock of the last safety-net toast
local groupsReady = false

local remoteCache = {}

-- forward declaration (the lock's Died handler leaves the party)
local removeFromParty

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function clock()
	return os.clock()
end

local function copyList(list)
	local out = {}
	for i, v in ipairs(list) do
		out[i] = v
	end
	return out
end

local function removeValue(list, value)
	for i = #list, 1, -1 do
		if list[i] == value then
			table.remove(list, i)
		end
	end
end

local function nameOf(player)
	local n = player.DisplayName
	if type(n) ~= "string" or n == "" then
		n = player.Name
	end
	return n
end

local function isPlayer(value)
	return typeof(value) == "Instance" and value:IsA("Player")
end

local function getRemote(name)
	local cached = remoteCache[name]
	if cached then
		return cached
	end
	local ok, remote = pcall(Remotes.Get, name)
	if ok and remote then
		remoteCache[name] = remote
		return remote
	end
	return nil
end

local function fireClient(name, player, ...)
	if not player or player.Parent == nil then
		return
	end
	local remote = getRemote(name)
	if not remote then
		return
	end
	pcall(remote.FireClient, remote, player, ...)
end

local function notify(player, text, kind, duration)
	fireClient("Notify", player, text, kind or "info", duration or 3)
end

local function isInMatch(player)
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return true
	end
	if matchService and type(matchService.GetMatchOf) == "function" then
		local ok, match = pcall(matchService.GetMatchOf, player)
		if ok and match then
			return true
		end
	end
	return false
end

-- Root part of a living, non-downed character, or nil.
local function getAliveRoot(player)
	if player:GetAttribute(Config.Attr.Downed) == true then
		return nil
	end
	local char = player.Character
	if not char or not char.Parent then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 then
		return nil
	end
	return root
end

local function zoneAlive(zone)
	return zone ~= nil and zone.Parent ~= nil
end

-- Is `position` inside `zone` (grown by `pad` studs sideways)? The zone reaches a little below its floor and
-- up to the ceiling of the lock walls, so a jump never counts as leaving.
local function inZone(zone, position, pad)
	local rel = zone.CFrame:PointToObjectSpace(position)
	local hs = zone.Size * 0.5
	return math.abs(rel.X) <= hs.X + pad
		and math.abs(rel.Z) <= hs.Z + pad
		and rel.Y >= -hs.Y - 2
		and rel.Y <= hs.Y + 8
end

-- Which portal zone (if any) contains `position`. Players already in `hintId` get a slightly
-- larger zone so standing on the edge does not flicker in and out of the party.
local function zoneAt(position, hintId)
	for _, id in ipairs(order) do
		local zone = parties[id].Info.Zone
		if zoneAlive(zone) then
			local pad = 0
			if hintId == id then
				pad = ZONE_HYSTERESIS
			end
			if inZone(zone, position, pad) then
				return id
			end
		end
	end
	return nil
end

local function hex(color)
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

----------------------------------------------------------------------
-- Collision groups + lock walls
----------------------------------------------------------------------
-- NC_PortalWall collides with NC_PortalLocked only. Groups registered by other code later keep the engine
-- default (collidable), so this runs again whenever a pad gets locked (cheap, idempotent).
local function setupCollisionGroups()
	for _, name in ipairs({ LOCK_GROUP, WALL_GROUP }) do
		local registered = false
		pcall(function()
			registered = PhysicsService:IsCollisionGroupRegistered(name)
		end)
		if not registered then
			local ok, err = pcall(function()
				PhysicsService:RegisterCollisionGroup(name)
			end)
			if not ok and not groupsReady then
				warn("[PortalService] could not register collision group " .. name .. ": " .. tostring(err))
			end
		end
	end
	local names = { "Default" }
	pcall(function()
		for _, info in ipairs(PhysicsService:GetRegisteredCollisionGroups()) do
			if type(info) == "table" and type(info.name) == "string" and info.name ~= "Default" then
				table.insert(names, info.name)
			end
		end
	end)
	for _, name in ipairs(names) do
		if name ~= LOCK_GROUP then
			pcall(function()
				PhysicsService:CollisionGroupSetCollidable(WALL_GROUP, name, false)
			end)
		end
	end
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(WALL_GROUP, LOCK_GROUP, true)
	end)
	groupsReady = true
end

-- Four side walls + a ceiling around the zone, in the zone's own frame.
local function buildWalls(party)
	local zone = party.Info.Zone
	local parent = party.Info.Model or zone.Parent
	local old = parent:FindFirstChild("LockWalls")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "LockWalls"

	local hs = zone.Size * 0.5
	local ix, iz = hs.X + ZONE_HYSTERESIS, hs.Z + ZONE_HYSTERESIS -- inner faces
	local t = WALL_THICKNESS
	local floorY = -hs.Y -- pad surface in zone space
	local h = WALL_HEIGHT + WALL_DEPTH
	local cy = floorY - WALL_DEPTH + h / 2
	local specs = {
		{ "WallFront", CFrame.new(0, cy, -(iz + t / 2)), Vector3.new(2 * (ix + t), h, t), true },
		{ "WallBack", CFrame.new(0, cy, iz + t / 2), Vector3.new(2 * (ix + t), h, t), true },
		{ "WallLeft", CFrame.new(-(ix + t / 2), cy, 0), Vector3.new(t, h, 2 * iz), true },
		{ "WallRight", CFrame.new(ix + t / 2, cy, 0), Vector3.new(t, h, 2 * iz), true },
		{ "Ceiling", CFrame.new(0, floorY + WALL_HEIGHT + t / 2, 0), Vector3.new(2 * (ix + t), t, 2 * (iz + t)), false },
	}
	local sides = {}
	for _, spec in ipairs(specs) do
		local wall = Instance.new("Part")
		wall.Name = spec[1]
		wall.Anchored = true
		wall.CanCollide = true
		wall.CanTouch = false
		wall.CastShadow = false
		wall.Size = spec[3]
		wall.CFrame = zone.CFrame * spec[2]
		wall.Material = Enum.Material.ForceField
		wall.Color = party.Diff.Color
		wall.Transparency = 1
		wall.TopSurface = Enum.SurfaceType.Smooth
		wall.BottomSurface = Enum.SurfaceType.Smooth
		pcall(function()
			wall.CollisionGroup = WALL_GROUP
		end)
		if wall.CollisionGroup ~= WALL_GROUP then
			wall.CanCollide = false -- no group: a Default wall would block everybody; the safety net still holds the lock
		end
		wall:SetAttribute("PortalId", party.Id)
		wall.Parent = folder
		if spec[4] then
			table.insert(sides, wall)
		end
	end
	folder.Parent = parent
	party.Walls = folder
	party.SideWalls = sides
	party.BarrierOn = false
end

-- Side-wall shimmer on while the pad has a party, off when it is empty.
local function setBarrier(party, on)
	if party.BarrierOn == on or not party.SideWalls then
		return
	end
	party.BarrierOn = on
	for _, wall in ipairs(party.SideWalls) do
		if wall.Parent then
			wall.Transparency = on and BARRIER_TRANSPARENCY or 1
		end
	end
end

----------------------------------------------------------------------
-- Locking players
----------------------------------------------------------------------
local function lockPart(rec, inst)
	if inst:IsA("BasePart") and rec.Groups[inst] == nil then
		rec.Groups[inst] = inst.CollisionGroup
		pcall(function()
			inst.CollisionGroup = LOCK_GROUP
		end)
	end
end

local function unlockPlayer(player)
	local rec = locks[player]
	if not rec then
		return
	end
	locks[player] = nil
	for _, conn in ipairs(rec.Conns) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	for part, group in pairs(rec.Groups) do
		if part.Parent ~= nil then
			pcall(function()
				if part.CollisionGroup == LOCK_GROUP then
					part.CollisionGroup = group
				end
			end)
		end
	end
	if player.Parent ~= nil then
		player:SetAttribute("PortalLocked", nil)
	end
end

local function lockPlayer(player, id)
	unlockPlayer(player)
	setupCollisionGroups()
	local rec = { PortalId = id, Groups = {}, Conns = {} }
	locks[player] = rec
	local char = player.Character
	if char then
		for _, d in ipairs(char:GetDescendants()) do
			lockPart(rec, d)
		end
		-- accessories / tools added while locked
		table.insert(rec.Conns, char.DescendantAdded:Connect(function(d)
			if locks[player] == rec then
				lockPart(rec, d)
			end
		end))
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			table.insert(rec.Conns, hum.Died:Connect(function()
				if locks[player] == rec then
					removeFromParty(player)
				end
			end))
		end
	end
	table.insert(rec.Conns, player.CharacterRemoving:Connect(function()
		if locks[player] == rec then
			removeFromParty(player)
		end
	end))
	player:SetAttribute("PortalLocked", id)
end

-- A spot on the pad for member `player` (a small ring, so several pulls never stack players inside each other).
local function padCFrame(party, player)
	local zone = party.Info.Zone
	local hs = zone.Size * 0.5
	local index, count = 1, math.max(1, #party.Players)
	for i, p in ipairs(party.Players) do
		if p == player then
			index = i
		end
	end
	local radius = (count > 1) and PAD_SPREAD or 0
	local angle = (index - 1) / count * math.pi * 2
	local pos = zone.CFrame:PointToWorldSpace(Vector3.new(math.cos(angle) * radius, -hs.Y + PAD_ROOT_HEIGHT, math.sin(angle) * radius))
	local look = zone.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.new(pos, pos + flat.Unit)
end

-- Safety net: a locked player outside the zone goes straight back onto the pad.
local function returnToPad(player, party, t)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local cf = padCFrame(party, player)
	pcall(function()
		char:PivotTo(cf)
		root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
	end)
	if t - (lastPullToast[player] or -1e9) >= PULL_TOAST_COOLDOWN then
		lastPullToast[player] = t
		notify(player, "You're locked in the portal. Press Leave to step out.", "info", 4)
	end
end

----------------------------------------------------------------------
-- Billboard (pixel-sized, World text rule)
----------------------------------------------------------------------
local INK = Theme.Colors.TextStroke or Theme.Colors.Ink
local GOLD = Theme.Colors.Gold or Theme.Colors.Token
local STAR_OFF = Color3.fromRGB(150, 158, 186)

local function starText(filled)
	filled = math.max(0, math.min(MAX_STARS, math.floor(tonumber(filled) or 1)))
	local out = string.format('<font color="%s">%s</font>', hex(GOLD), string.rep(STAR_FULL, filled))
	if filled < MAX_STARS then
		out = out .. string.format('<font color="%s">%s</font>', hex(STAR_OFF), string.rep(STAR_EMPTY, MAX_STARS - filled))
	end
	return out
end

local function plateLabel(parent, name, text, role, size, color, outlineColor, order)
	local label = Theme.Label(text, role, {
		Size = size,
		Color = color,
		Stroke = 1, -- the glyph outline below replaces the classic stroke
		Outline = 2.5,
		OutlineColor = outlineColor or INK,
		Props = {
			Name = name,
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, size + 4),
			TextWrapped = false,
			LayoutOrder = order or 0,
		},
	})
	label.Parent = parent
	return label
end

local function listLayout(parent, direction, padding)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = direction
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, padding)
	layout.Parent = parent
	return layout
end

local function uiPadding(parent, top, side, bottom)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, top)
	pad.PaddingBottom = UDim.new(0, bottom)
	pad.PaddingLeft = UDim.new(0, side)
	pad.PaddingRight = UDim.new(0, side)
	pad.Parent = parent
	return pad
end

-- World height of the gate's top (the star gems), or a sensible height above the zone.
local function gateTopY(info)
	local top = nil
	local model = info.Model
	if model then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and (d.Name == "StarGem" or d.Name == "StarGemOff") then
				local y = d.Position.Y + 1.1
				if not top or y > top then
					top = y
				end
			end
		end
	end
	if not top and zoneAlive(info.Zone) then
		top = info.Zone.Position.Y + info.Zone.Size.Y * 0.5 + 10
	end
	return top
end

local function billboardAnchor(party)
	local info = party.Info
	local anchor = info.Model and info.Model:FindFirstChild("BillboardAnchor")
	if anchor and anchor:IsA("BasePart") then
		return anchor
	end
	anchor = Instance.new("Part")
	anchor.Name = "BillboardAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(info.Zone.Position + Vector3.new(0, 14, 0))
	anchor.Parent = info.Model or info.Zone.Parent
	return anchor
end

local function buildBillboard(party)
	local info = party.Info
	local diff = party.Diff
	local color = diff.Color
	local anchor = billboardAnchor(party)

	-- the old studs-sized card (text shrank with distance) goes away
	local old = info.Billboard
	if old and old.Parent and old ~= party.Billboard then
		old:Destroy()
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "PortalBillboard"
	gui.Size = UDim2.fromOffset(BB.Width, BB.Height)
	gui.SizeOffset = Vector2.new(0, 0.5) -- the container's bottom edge sits on the anchor point
	local topY = gateTopY(info)
	local offsetY = 0
	if topY then
		offsetY = topY + BB.Gap - anchor.Position.Y
	end
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.MaxDistance = BB.MaxDistance
	gui.ClipsDescendants = false
	gui.Adornee = anchor

	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.AnchorPoint = Vector2.new(0.5, 1)
	plate.Position = UDim2.new(0.5, 0, 1, 0)
	plate.Size = UDim2.fromOffset(BB.PlateMinW, 0)
	plate.AutomaticSize = Enum.AutomaticSize.XY
	plate.BackgroundColor3 = Color3.fromRGB(255, 255, 255) -- the gradient supplies the colour
	plate.BackgroundTransparency = 0.04
	plate.BorderSizePixel = 0
	Theme.Corner(plate, UDim.new(0, 16))
	Theme.Stroke(plate, Theme.Lighten(color, 0.15), 4, 0)
	Theme.Gradient(plate, Theme.Darken(color, 0.48), Theme.Darken(color, 0.72), 90)
	uiPadding(plate, 8, 18, 10)
	listLayout(plate, Enum.FillDirection.Vertical, 3)
	plate.Parent = gui

	local title = plateLabel(plate, "TitleLabel", diff.DisplayName or diff.Id, "Title", BB.NameText, Theme.Lighten(color, 0.6), Theme.Darken(color, 0.7), 1)

	local infoRow = Instance.new("Frame")
	infoRow.Name = "InfoRow"
	infoRow.BackgroundTransparency = 1
	infoRow.Size = UDim2.fromOffset(0, BB.InfoText + 4)
	infoRow.AutomaticSize = Enum.AutomaticSize.XY
	infoRow.LayoutOrder = 2
	listLayout(infoRow, Enum.FillDirection.Horizontal, 12)
	infoRow.Parent = plate
	local stars = plateLabel(infoRow, "StarLabel", "", "Heading", BB.InfoText, GOLD, INK, 1)
	stars.RichText = true
	stars.Text = starText(diff.Stars)
	local count = plateLabel(infoRow, "CountLabel", "0/" .. tostring(Config.Match.MaxPlayers) .. " players", "Heading", BB.InfoText, Theme.Colors.White, INK, 2)

	local pill = Instance.new("Frame")
	pill.Name = "StatusPill"
	pill.Size = UDim2.fromOffset(0, BB.StatusText + 10)
	pill.AutomaticSize = Enum.AutomaticSize.XY
	pill.BorderSizePixel = 0
	pill.BackgroundTransparency = 0
	pill.LayoutOrder = 3
	Theme.Corner(pill, UDim.new(0, 12))
	local pillStroke = Theme.Stroke(pill, INK, 2.5, 0)
	uiPadding(pill, 3, 14, 4)
	pill.Parent = plate
	local status = plateLabel(pill, "StatusLabel", "Step in to play", "Display", BB.StatusText, Theme.Colors.White, INK, 1)

	gui.Parent = anchor

	party.Billboard = gui
	party.Pill = pill
	party.PillStroke = pillStroke
	party.PillMode = nil
	-- keep the LobbyInfo contract (Billboard + labels) pointing at the live billboard
	info.Billboard = gui
	info.TitleLabel = title
	info.StarLabel = stars
	info.CountLabel = count
	info.StatusLabel = status
end

----------------------------------------------------------------------
-- Party bookkeeping
----------------------------------------------------------------------
-- Effective launch deadline: the normal timer, or the short "party is full" timer if sooner.
local function effectiveDeadline(party)
	local d = party.BaseDeadline
	if d and party.FullDeadline and party.FullDeadline < d then
		d = party.FullDeadline
	end
	return d
end

local function countdownOf(party, t)
	local d = effectiveDeadline(party)
	if not d then
		return nil
	end
	return math.max(0, math.ceil(d - (t or clock())))
end

local function isFull(party)
	return #party.Players >= Config.Match.MaxPlayers
end

-- Recompute the timers after a join/leave.
local function onMembershipChanged(party)
	local t = clock()
	local n = #party.Players
	setBarrier(party, n > 0)
	if n == 0 then
		party.BaseDeadline = nil
		party.FullDeadline = nil
		return
	end
	if not party.BaseDeadline then
		party.BaseDeadline = t + Config.Match.PartyCountdown
	end
	if isFull(party) then
		if not party.FullDeadline then
			party.FullDeadline = t + Config.Match.FullPartyCountdown
		end
	else
		party.FullDeadline = nil
	end
end

local function setText(label, text, cacheKey, party)
	if party[cacheKey] == text then
		return
	end
	party[cacheKey] = text
	if label then
		pcall(function()
			label.Text = text
		end)
	end
end

local function setModelAttr(party, name, value)
	local model = party.Info.Model
	if model and model.Parent and model:GetAttribute(name) ~= value then
		model:SetAttribute(name, value)
	end
end

-- Status pill colours: the portal colour while idle, gold while a countdown runs.
local function setPillMode(party, mode)
	if party.PillMode == mode or not party.Pill then
		return
	end
	party.PillMode = mode
	local base = (mode == "Countdown") and GOLD or Theme.Darken(party.Diff.Color, 0.2)
	party.Pill.BackgroundColor3 = base
	party.PillStroke.Color = Theme.Darken(base, 0.7)
	local outline = party.Info.StatusLabel and party.Info.StatusLabel:FindFirstChild("TextOutline")
	if outline then
		outline.Color = Theme.Darken(base, 0.66)
	end
end

-- Billboard above the portal: "2/4 players" and the status pill.
local function refreshLabels(party)
	local info = party.Info
	local n = #party.Players
	local max = Config.Match.MaxPlayers
	setText(info.CountLabel, string.format("%d/%d players", n, max), "LastCount", party)

	local status, mode
	local seconds = countdownOf(party)
	if n == 0 then
		status, mode = "Step in to play", "Idle"
	elseif n < Config.Match.MinPlayers then
		status, mode = "Waiting for players...", "Idle"
	elseif isFull(party) then
		status, mode = string.format("Full! Starting in %d", seconds or 0), "Countdown"
	else
		status, mode = string.format("Starting in %d", seconds or 0), "Countdown"
	end
	setText(info.StatusLabel, status, "LastStatus", party)
	setPillMode(party, mode)
	setModelAttr(party, "PartyCount", n)
	setModelAttr(party, "PartyMax", max)
	if n > 0 then
		setModelAttr(party, "Countdown", seconds)
	else
		setModelAttr(party, "Countdown", nil)
	end
end

local function buildPartyState(party)
	local list = {}
	for _, p in ipairs(party.Players) do
		list[#list + 1] = { UserId = p.UserId, Name = nameOf(p) }
	end
	return {
		PortalId = party.Id,
		DifficultyName = party.Diff.DisplayName,
		Color = party.Diff.Color,
		Players = list,
		Max = Config.Match.MaxPlayers,
		Countdown = countdownOf(party),
		Locked = true, -- members stay on the pad until launch; Leave is the only way out
	}
end

local function sendPartyState(party)
	if #party.Players == 0 then
		return
	end
	local state = buildPartyState(party)
	for _, p in ipairs(party.Players) do
		fireClient("PartyState", p, state)
	end
	party.LastStateAt = clock()
end

local function addToParty(player, id)
	local party = parties[id]
	if not party then
		return false
	end
	if isFull(party) then
		if fullNotified[player] ~= id then
			fullNotified[player] = id
			notify(player, "Party is full", "bad", 3)
		end
		return false
	end
	table.insert(party.Players, player)
	playerParty[player] = id
	fullNotified[player] = nil
	lockPlayer(player, id)
	onMembershipChanged(party)
	refreshLabels(party)
	sendPartyState(party) -- everybody's list changed
	notify(player, "You're in the " .. tostring(party.Diff.DisplayName) .. " portal! Press Leave to step out.", "info", 4)
	return true
end

-- Leave the party (no lockout, no teleport) and unlock.
removeFromParty = function(player)
	unlockPlayer(player)
	local id = playerParty[player]
	if not id then
		return
	end
	playerParty[player] = nil
	local party = parties[id]
	if not party then
		return
	end
	removeValue(party.Players, player)
	onMembershipChanged(party)
	refreshLabels(party)
	fireClient("PartyState", player, nil)
	sendPartyState(party)
end

-- Cancel a countdown: everybody is unlocked and leaves; they step out before they can join again.
local function cancelParty(party, message)
	local members = copyList(party.Players)
	local t = clock()
	for _, p in ipairs(members) do
		removeFromParty(p)
		lockedUntil[p] = t + LEAVE_LOCKOUT
		mustExit[p] = true
		if message then
			notify(p, message, "info", 4)
		end
	end
	return #members
end

----------------------------------------------------------------------
-- Launching a match
----------------------------------------------------------------------
local function launch(party)
	local members = copyList(party.Players)

	-- clear the party first: from here on these players belong to MatchService
	for _, p in ipairs(members) do
		playerParty[p] = nil
		unlockPlayer(p)
		starting[p] = true
		fireClient("PartyState", p, nil)
	end
	party.Players = {}
	onMembershipChanged(party)
	refreshLabels(party)

	task.spawn(function()
		local match = nil
		if matchService and type(matchService.StartMatch) == "function" then
			local ok, result = pcall(matchService.StartMatch, party.Id, members)
			if ok then
				match = result
			else
				warn("[PortalService] StartMatch failed: " .. tostring(result))
			end
		else
			warn("[PortalService] MatchService unavailable")
		end

		local t = clock()
		for _, p in ipairs(members) do
			starting[p] = nil
			if not match and p.Parent ~= nil then
				notify(p, "All sky arenas are busy, try again soon", "bad", 4)
				-- stop the pad from instantly re-forming the same party
				lockedUntil[p] = t + FAILED_LOCKOUT
				mustExit[p] = true
			end
		end
	end)
end

-- Per-party timer: launch when the deadline passes.
local function updateParty(party, t)
	-- drop anybody who vanished without us noticing
	for _, p in ipairs(copyList(party.Players)) do
		if p.Parent == nil then
			removeFromParty(p)
		end
	end

	local n = #party.Players
	if n > 0 and not zoneAlive(party.Info.Zone) then
		cancelParty(party, nil) -- the pad itself is gone
		n = 0
	end
	if n == 0 then
		refreshLabels(party)
		return
	end

	local deadline = effectiveDeadline(party)
	if deadline and t >= deadline then
		if n >= Config.Match.MinPlayers then
			launch(party)
			return
		end
		-- not enough players: the countdown is cancelled (nobody stays locked in an endless wait)
		cancelParty(party, "Not enough players to start. Step in again!")
		refreshLabels(party)
		return
	end

	refreshLabels(party)
	if t - (party.LastStateAt or 0) >= STATE_INTERVAL then
		sendPartyState(party)
	end
end

----------------------------------------------------------------------
-- Poll loop
----------------------------------------------------------------------
local function pollPlayer(player, t)
	if starting[player] then
		return
	end
	local current = playerParty[player]
	local inMatch = isInMatch(player)
	local root = nil
	if not inMatch then
		root = getAliveRoot(player)
	end

	if current then
		local party = parties[current]
		if inMatch or not root or not party then
			-- died, downed, no character, or pulled into a match: the seat (and the lock) ends here
			removeFromParty(player)
			current = nil
		elseif not zoneAlive(party.Info.Zone) then
			return -- updateParty cancels this party
		elseif inZone(party.Info.Zone, root.Position, ZONE_HYSTERESIS) then
			if not locks[player] then
				lockPlayer(player, current) -- a fresh character mid-countdown (should not happen, but never leave a member unlocked)
			end
			return
		else
			-- safety net: locked members cannot walk, jump, dash or get flung out
			returnToPad(player, party, t)
			return
		end
	end

	local zoneId = nil
	if root then
		zoneId = zoneAt(root.Position, nil)
	end
	if zoneId == nil then
		mustExit[player] = nil
		fullNotified[player] = nil
		return
	end

	local until_ = lockedUntil[player]
	if until_ and t >= until_ then
		lockedUntil[player] = nil
		until_ = nil
	end
	if until_ == nil and not mustExit[player] then
		addToParty(player, zoneId)
	end
end

local function pollOnce()
	local t = clock()
	for _, player in ipairs(Players:GetPlayers()) do
		local ok, err = pcall(pollPlayer, player, t)
		if not ok then
			warn("[PortalService] player poll failed: " .. tostring(err))
		end
	end
	for _, id in ipairs(order) do
		local ok, err = pcall(updateParty, parties[id], t)
		if not ok then
			warn("[PortalService] party update failed: " .. tostring(err))
		end
	end
end

local function pollLoop()
	while running do
		local ok, err = pcall(pollOnce)
		if not ok then
			warn("[PortalService] poll error: " .. tostring(err))
		end
		task.wait(POLL)
	end
end

----------------------------------------------------------------------
-- Leave button: unlock, remove from the party and step the player off the pad
----------------------------------------------------------------------
local function ejectFromPad(player, id)
	local party = parties[id]
	local root = Util.GetRoot(player)
	if not party or not root then
		return
	end
	local zone = party.Info.Zone
	local center = party.Info.Center
	if not center and zone then
		center = zone.Position
	end
	if not center then
		return
	end

	-- Move toward the plaza centre (the pads sit near the plaza rim, "outward" would be the void).
	local toPlaza = Vector3.new(Config.Lobby.Origin.X - center.X, 0, Config.Lobby.Origin.Z - center.Z)
	if toPlaza.Magnitude < 0.001 then
		toPlaza = Vector3.new(0, 0, 1)
	end
	local dir = toPlaza.Unit
	local target = center + dir * EJECT_DISTANCE

	local y = root.Position.Y
	pcall(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { player.Character }
		local hit = Workspace:Raycast(Vector3.new(target.X, root.Position.Y + 6, target.Z), Vector3.new(0, -40, 0), params)
		if hit then
			y = hit.Position.Y + 3.2
		end
	end)

	local pos = Vector3.new(target.X, y, target.Z)
	pcall(function()
		player.Character:PivotTo(CFrame.new(pos, pos + dir))
		root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
	end)
end

local function onLeaveParty(player)
	if not isPlayer(player) then
		return
	end
	local id = playerParty[player]
	if not id then
		return
	end
	local t = clock()
	if t - (lastLeave[player] or -1e9) < LEAVE_COOLDOWN then
		return
	end
	lastLeave[player] = t
	removeFromParty(player) -- unlocks first, so the step off the pad never meets a wall
	lockedUntil[player] = t + LEAVE_LOCKOUT
	mustExit[player] = true
	ejectFromPad(player, id)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
-- lobbyInfo: LobbyBuilder.Build() result; matchServiceArg: the MatchService module.
function PortalService.Init(lobbyInfo, matchServiceArg)
	matchService = matchServiceArg or matchService
	if initialized then
		return
	end
	initialized = true

	local okGroups, errGroups = pcall(setupCollisionGroups)
	if not okGroups then
		warn("[PortalService] collision groups: " .. tostring(errGroups))
	end

	local portals = (lobbyInfo and lobbyInfo.Portals) or {}
	for _, diff in ipairs(Config.Difficulties) do
		local info = portals[diff.Id]
		if info and not info.Zone then
			warn("[PortalService] portal " .. diff.Id .. " has no Zone")
			info = nil
		end
		if info then
			parties[diff.Id] = {
				Id = diff.Id,
				Info = info,
				Diff = diff,
				Players = {},
				BaseDeadline = nil,
				FullDeadline = nil,
				LastStateAt = 0,
			}
			table.insert(order, diff.Id)
		else
			warn("[PortalService] lobby has no portal for " .. diff.Id)
		end
	end
	for _, id in ipairs(order) do
		local party = parties[id]
		local okWalls, errWalls = pcall(buildWalls, party)
		if not okWalls then
			warn("[PortalService] lock walls for " .. id .. ": " .. tostring(errWalls))
		end
		local okBoard, errBoard = pcall(buildBillboard, party)
		if not okBoard then
			warn("[PortalService] billboard for " .. id .. ": " .. tostring(errBoard))
		end
		refreshLabels(party)
	end

	local okRemote, leaveRemote = pcall(Remotes.Get, "LeaveParty")
	if okRemote and leaveRemote then
		leaveRemote.OnServerEvent:Connect(onLeaveParty)
	else
		warn("[PortalService] LeaveParty remote unavailable")
	end

	Players.PlayerRemoving:Connect(function(player)
		removeFromParty(player)
		lockedUntil[player] = nil
		mustExit[player] = nil
		starting[player] = nil
		fullNotified[player] = nil
		lastLeave[player] = nil
		lastPullToast[player] = nil
	end)

	running = true
	task.spawn(pollLoop)
end

-- Leave the current party (no-op when not in one) and unlock. No lockout, no teleport.
function PortalService.RemovePlayer(player)
	removeFromParty(player)
end

function PortalService.GetParty(portalId)
	local party = parties[portalId]
	if not party then
		return { Players = {}, Countdown = nil }
	end
	return { Players = copyList(party.Players), Countdown = countdownOf(party) }
end

-- true, portalId while `player` is locked inside a portal pad (waiting for its countdown).
function PortalService.IsLocked(player)
	local rec = locks[player]
	if rec then
		return true, rec.PortalId
	end
	return false, nil
end

-- Cancels a running countdown: every member is unlocked and removed (they must step out before re-joining).
-- Returns how many players were in the party.
function PortalService.CancelParty(portalId, message)
	local party = parties[portalId]
	if not party then
		return 0
	end
	local n = cancelParty(party, message)
	refreshLabels(party)
	return n
end

-- Stops the poll loop and releases everybody (not needed in normal play; handy for tests / shutdown).
function PortalService.Stop()
	running = false
	for _, id in ipairs(order) do
		pcall(PortalService.CancelParty, id, nil)
	end
end

return PortalService
