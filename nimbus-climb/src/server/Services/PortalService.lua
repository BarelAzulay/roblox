-- PortalService: forms parties on the lobby portal pads and launches matches.
--
-- Standing inside a portal Zone (the "ready pad") puts a player in that portal's party. The first
-- player starts a countdown; a full party shortens it. When it reaches zero the party is handed to
-- MatchService.StartMatch. MatchService is passed in through Init (no require) so the two services
-- never form a circular dependency.
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local PortalService = {}

----------------------------------------------------------------------
-- Tunables local to this module
----------------------------------------------------------------------
local POLL = 0.2 -- zone poll period (5 Hz)
local STATE_INTERVAL = 1 -- PartyState refresh period
local LEAVE_LOCKOUT = 3 -- seconds a player cannot re-join after pressing Leave
local FAILED_LOCKOUT = 4 -- ... after a failed launch
local EJECT_DISTANCE = 12 -- studs the Leave button moves a player off the pad
local ZONE_HYSTERESIS = 1.5 -- extra studs of tolerance for players already inside (no edge flicker)

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

local remoteCache = {}

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

-- Which portal zone (if any) contains `position`. Players already in `hintId` get a slightly
-- larger zone so standing on the edge does not flicker in and out of the party.
local function zoneAt(position, hintId)
	for _, id in ipairs(order) do
		local zone = parties[id].Info.Zone
		if zone and zone.Parent then
			local rel = zone.CFrame:PointToObjectSpace(position)
			local hs = zone.Size * 0.5
			local pad = 0
			if hintId == id then
				pad = ZONE_HYSTERESIS
			end
			if math.abs(rel.X) <= hs.X + pad
				and math.abs(rel.Z) <= hs.Z + pad
				and rel.Y >= -hs.Y - 2
				and rel.Y <= hs.Y + 8
			then
				return id
			end
		end
	end
	return nil
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

-- Billboard above the portal: "2 / 4" and a status line.
local function refreshLabels(party)
	local info = party.Info
	local n = #party.Players
	local max = Config.Match.MaxPlayers
	setText(info.CountLabel, string.format("%d / %d", n, max), "LastCount", party)

	local status
	if n == 0 then
		status = "Waiting for players..."
	elseif n < Config.Match.MinPlayers then
		status = "Waiting for players..."
	else
		local seconds = countdownOf(party) or 0
		if isFull(party) then
			status = string.format("Party full! %ds", seconds)
		else
			status = string.format("Starting in %ds", seconds)
		end
	end
	setText(info.StatusLabel, status, "LastStatus", party)
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
	onMembershipChanged(party)
	refreshLabels(party)
	sendPartyState(party) -- everybody's list changed
	return true
end

local function removeFromParty(player)
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

----------------------------------------------------------------------
-- Launching a match
----------------------------------------------------------------------
local function launch(party)
	local members = copyList(party.Players)

	-- clear the party first: from here on these players belong to MatchService
	for _, p in ipairs(members) do
		playerParty[p] = nil
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
		-- not enough players: keep waiting with a fresh timer
		party.BaseDeadline = t + Config.Match.PartyCountdown
		party.FullDeadline = nil
		onMembershipChanged(party)
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

	local zoneId = nil
	if not isInMatch(player) then
		local root = getAliveRoot(player)
		if root then
			zoneId = zoneAt(root.Position, current)
		end
	end

	-- walked out (or died / got sent away): leave the party
	if current and current ~= zoneId then
		removeFromParty(player)
		current = nil
	end

	if zoneId == nil then
		mustExit[player] = nil
		fullNotified[player] = nil
		return
	end

	if not current then
		local until_ = lockedUntil[player]
		if until_ and t >= until_ then
			lockedUntil[player] = nil
			until_ = nil
		end
		if until_ == nil and not mustExit[player] then
			addToParty(player, zoneId)
		end
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
-- Leave button: remove from the party and step the player off the pad
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
	local id = playerParty[player]
	if not id then
		return
	end
	removeFromParty(player)
	lockedUntil[player] = clock() + LEAVE_LOCKOUT
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

	local portals = (lobbyInfo and lobbyInfo.Portals) or {}
	for _, diff in ipairs(Config.Difficulties) do
		local info = portals[diff.Id]
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
		refreshLabels(parties[id])
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
	end)

	running = true
	task.spawn(pollLoop)
end

-- Leave the current party (no-op when not in one). No lockout, no teleport.
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

-- Stops the poll loop (not needed in normal play; handy for tests / shutdown).
function PortalService.Stop()
	running = false
end

return PortalService
