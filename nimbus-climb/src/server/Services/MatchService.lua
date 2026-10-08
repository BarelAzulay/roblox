-- MatchService: match lifecycle + team rules for Nimbus Climb.
--
-- One match = one procedurally generated sky course in its own arena slot, a party of 1-4 players,
-- and a single worker loop (task.spawn + task.wait(0.25)) that drives the state machine:
--
--   Setup -> Countdown (frozen on the start platform) -> Playing -> Ended (results) -> cleanup
--
-- Server-authoritative: checkpoints, revives, void handling, tokens, victory/defeat/timeout.
-- Everything a match creates (course, hazard loops, token watcher, event connections, player
-- attributes) is torn down in cleanupMatch(), always in the same order, every step in a pcall so a
-- single failure can never leak a slot.
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local MatchService = {}
MatchService.MatchEnded = Util.Signal() -- Fire(match, won:boolean)

----------------------------------------------------------------------
-- Tunables local to this module
----------------------------------------------------------------------
local TICK = 0.25 -- worker loop period (also the void / checkpoint / finish poll rate)
local STATE_INTERVAL = 0.5 -- MatchState broadcast period while counting down / playing (2 Hz)
local START_SPREAD = 4 -- scatter radius on the start platform (contract allows +-6)
local CHECKPOINT_SPREAD = 3.5 -- scatter radius on a checkpoint pad (pads are >= 14x14)
local FINISH_SPREAD = 7.5 -- scatter radius on the finish pad (pad is >= 28x28)
local RESPAWN_FIX_DELAY = 0.4 -- let PlayerService place + stat a fresh character before we adjust it
local MAX_TICK_ERRORS = 40 -- consecutive worker errors before a match is force-closed
local SHORT_RESPAWN_TIME = 1.5 -- Players.RespawnTime cap, so reset-button deaths are quick
local LAYOUT_ATTEMPTS = 4 -- tries to get a layout that passes ValidateLayout

----------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------
local deps = {}
local initialized = false
local slots = {} -- slot number -> match
local matches = {} -- match id -> match
local playerMatch = {} -- Player -> match
local nextMatchId = 0
local random = Random.new()
local remoteCache = {}

-- forward declarations (functions that reference each other)
local endMatch
local cleanupMatch
local detachPlayer
local reachCheckpoint
local markFinished
local broadcastState

----------------------------------------------------------------------
-- Small helpers
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

-- Call deps[name][fnName](...) defensively. Returns ok, result1, result2.
local function callDep(name, fnName, ...)
	local dep = deps[name]
	if not dep then
		return false
	end
	local fn = dep[fnName]
	if type(fn) ~= "function" then
		return false
	end
	local ok, a, b = pcall(fn, ...)
	if not ok then
		warn("[MatchService] " .. name .. "." .. fnName .. " failed: " .. tostring(a))
		return false
	end
	return true, a, b
end

local function setAttr(player, name, value)
	pcall(function()
		player:SetAttribute(name, value)
	end)
end

local function isDowned(player)
	return player:GetAttribute(Config.Attr.Downed) == true
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

local function notifyAll(match, text, kind, duration, except)
	for _, p in ipairs(match.Players) do
		if p ~= except then
			notify(p, text, kind, duration)
		end
	end
end

local function isMember(match, player)
	return playerMatch[player] == match
end

-- Humanoid + root of a living character, or nil, nil.
local function getLive(player)
	local char = player.Character
	if not char or not char.Parent then
		return nil, nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 then
		return nil, nil
	end
	return hum, root
end

local function teleportTo(player, cf)
	local char = player.Character
	if not char or not char.Parent then
		return false
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local ok = pcall(function()
		char:PivotTo(cf)
	end)
	if not ok then
		return false
	end
	pcall(function()
		root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
	end)
	return true
end

-- Place player `index` of `count` on a ring around `base`, with a little random jitter.
local function spreadCFrame(base, index, count, radius)
	count = math.max(count or 1, 1)
	local angle = ((index - 1) / count) * math.pi * 2 + math.pi / 4
	local x = math.cos(angle) * radius * 0.8 + random:NextNumber(-1, 1) * radius * 0.2
	local z = math.sin(angle) * radius * 0.8 + random:NextNumber(-1, 1) * radius * 0.2
	return base * CFrame.new(x, 0, z)
end

-- Random scatter around `base` (respawns).
local function jitterCFrame(base, radius)
	return base * CFrame.new(random:NextNumber(-radius, radius), 0, random:NextNumber(-radius, radius))
end

-- Freeze / unfreeze a character: zero speed + jump AND anchored root (the client may fight a
-- WalkSpeed change by itself while sprinting, an anchored root cannot be argued with).
local function setFrozen(player, frozen)
	local char = player.Character
	if not char then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if hum then
		pcall(function()
			hum.UseJumpPower = true
			if frozen then
				hum.WalkSpeed = 0
				hum.JumpPower = 0
			elseif not isDowned(player) then
				hum.WalkSpeed = Config.Physics.WalkSpeed
				hum.JumpPower = Config.Physics.JumpPower
			end
		end)
	end
	if root then
		pcall(function()
			root.Anchored = frozen
		end)
	end
end

-- Is `pos` above/inside the footprint of a block `part` (used instead of Touched for reliability)?
local function isOverPart(part, pos, padXZ, below, above)
	local rel = part.CFrame:PointToObjectSpace(pos)
	local hs = part.Size * 0.5
	return math.abs(rel.X) <= hs.X + padXZ
		and math.abs(rel.Z) <= hs.Z + padXZ
		and rel.Y >= -(hs.Y + below)
		and rel.Y <= hs.Y + above
end

local function teamSpawnCFrame(match)
	local course = match.Course
	if match.Checkpoint >= 1 then
		local cp = course.Checkpoints[match.Checkpoint]
		if cp and cp.SpawnCFrame then
			return cp.SpawnCFrame
		end
	end
	return course.StartCFrame
end

-- Centre of the finish pad, standing height.
local function finishCFrame(match)
	local pad = match.Course.Finish
	if pad and pad.Parent then
		local p = pad.Position + Vector3.new(0, pad.Size.Y / 2 + 3.5, 0)
		return CFrame.new(p, p + Vector3.new(0, 0, 1))
	end
	return teamSpawnCFrame(match)
end

local function secondsLeft(match, t)
	t = t or clock()
	if match.State == "Countdown" then
		return math.max(0, math.ceil(match.CountdownEnd - t))
	elseif match.State == "Playing" then
		return math.max(0, math.ceil(match.Difficulty.TimeLimit - (t - match.StartedAt)))
	elseif match.State == "Ended" then
		return math.max(0, math.ceil((match.EndDeadline or t) - t))
	end
	return 0
end

----------------------------------------------------------------------
-- MatchState broadcast
----------------------------------------------------------------------
local function buildState(match, phase)
	local diff = match.Difficulty
	local members = {}
	for _, p in ipairs(match.Players) do
		local fraction = 0
		local hum = Util.GetHumanoid(p)
		if hum and hum.MaxHealth > 0 then
			fraction = Util.Clamp(hum.Health / hum.MaxHealth, 0, 1)
		end
		members[#members + 1] = {
			UserId = p.UserId,
			Name = nameOf(p),
			Health = fraction,
			Downed = isDowned(p),
			Finished = match.Finished[p] == true,
			Tokens = match.Tokens[p] or 0,
		}
	end
	return {
		Phase = phase,
		DifficultyId = diff.Id,
		DifficultyName = diff.DisplayName,
		Color = diff.Color,
		Seconds = secondsLeft(match),
		Checkpoint = match.Checkpoint,
		TotalCheckpoints = match.TotalCheckpoints,
		TokensCollected = match.TeamTokens,
		TotalTokens = (match.Course and match.Course.TotalTokens) or 0,
		Members = members,
	}
end

broadcastState = function(match)
	if match.State == "Setup" then
		return
	end
	local state = buildState(match, match.State)
	for _, p in ipairs(match.Players) do
		fireClient("MatchState", p, state)
	end
	match.LastStateAt = clock()
end

----------------------------------------------------------------------
-- Stop helpers (idempotent)
----------------------------------------------------------------------
local function stopHazards(match)
	local fn = match.StopHazards
	match.StopHazards = nil
	if fn then
		local ok, err = pcall(fn)
		if not ok then
			warn("[MatchService] hazard stop failed: " .. tostring(err))
		end
	end
end

local function stopTokens(match)
	local fn = match.StopTokens
	match.StopTokens = nil
	if fn then
		local ok, err = pcall(fn)
		if not ok then
			warn("[MatchService] token stop failed: " .. tostring(err))
		end
	end
end

local function destroyCourse(match)
	local course = match.Course
	if course and course.Folder then
		pcall(function()
			course.Folder:Destroy()
		end)
	end
	if match.Seed then
		-- belt and braces: a Build() that threw after parenting could leave an orphan folder
		local orphan = Workspace:FindFirstChild("Course_" .. tostring(match.Seed))
		if orphan then
			pcall(function()
				orphan:Destroy()
			end)
		end
	end
end

----------------------------------------------------------------------
-- Tokens
----------------------------------------------------------------------
local function addTokens(match, player, n)
	if match.State ~= "Playing" or match.Stopped then
		return
	end
	if not isMember(match, player) then
		return
	end
	n = math.floor((tonumber(n) or 0) + 0.5)
	if n < 1 then
		return
	end
	local total = (match.Tokens[player] or 0) + n
	match.Tokens[player] = total
	match.TeamTokens = match.TeamTokens + n
	setAttr(player, Config.Attr.MatchTokens, total)
	callDep("DataService", "AddTokens", player, n)
	local label = "+" .. n .. " cloud token"
	if n ~= 1 then
		label = label .. "s"
	end
	notify(player, label, "token", 2)
end

----------------------------------------------------------------------
-- Checkpoints, finish, void
----------------------------------------------------------------------
reachCheckpoint = function(match, index, byPlayer)
	if match.State ~= "Playing" or match.Stopped then
		return
	end
	if index <= match.Checkpoint then
		return
	end
	local cp = match.Course.Checkpoints[index]
	if not cp then
		return
	end
	match.Checkpoint = index
	notifyAll(match, string.format("Checkpoint %d/%d reached!", index, match.TotalCheckpoints), "good", 3.5)

	-- heal everyone who is up, collect the downed
	local downedList = {}
	for _, p in ipairs(copyList(match.Players)) do
		if isMember(match, p) then
			if isDowned(p) then
				table.insert(downedList, p)
			else
				callDep("DamageService", "HealFraction", p, Config.Damage.CheckpointHealFraction)
			end
		end
	end

	-- lift up the downed teammates right here
	for i, p in ipairs(downedList) do
		teleportTo(p, spreadCFrame(cp.SpawnCFrame, i, #downedList, CHECKPOINT_SPREAD))
		callDep("DamageService", "Revive", p)
		local who = "your team"
		if byPlayer and byPlayer ~= p then
			who = nameOf(byPlayer)
		end
		notify(p, "Revived by " .. who .. "!", "good", 3)
	end
	if #downedList > 0 then
		notifyAll(match, "Teammates are back on their feet!", "good", 3)
	end
	broadcastState(match)
end

local function onCheckpointTouched(match, index, hit)
	if match.State ~= "Playing" or match.Stopped then
		return
	end
	local player = Util.PlayerFromPart(hit)
	if not player or not isMember(match, player) then
		return
	end
	if isDowned(player) or match.Finished[player] then
		return
	end
	local hum = Util.GetHumanoid(player)
	if not hum or hum.Health <= 0 then
		return
	end
	reachCheckpoint(match, index, player)
end

markFinished = function(match, player)
	if match.State ~= "Playing" or match.Finished[player] then
		return
	end
	if isDowned(player) or not isMember(match, player) then
		return
	end
	match.Finished[player] = true
	match.FinishCount = match.FinishCount + 1
	-- park them safely on the pad and keep them out of harm's way
	teleportTo(player, spreadCFrame(finishCFrame(match), match.FinishCount, Config.Match.MaxPlayers, FINISH_SPREAD))
	setFrozen(player, true)
	callDep("DamageService", "GrantInvulnerability", player, 3)
	notify(player, "You made it! Wait here for your team.", "good", 4)
	notifyAll(match, nameOf(player) .. " reached the finish!", "good", 3, player)
	broadcastState(match)
end

local function onFinishTouched(match, hit)
	if match.State ~= "Playing" or match.Stopped then
		return
	end
	local player = Util.PlayerFromPart(hit)
	if not player or not isMember(match, player) then
		return
	end
	local hum = Util.GetHumanoid(player)
	if not hum or hum.Health <= 0 then
		return
	end
	markFinished(match, player)
end

-- Player fell below the course. Damage them (unless downed / finished), then bring them back.
local function handleVoid(match, player, wasDowned, finished)
	if finished then
		teleportTo(player, finishCFrame(match))
		return
	end
	if not wasDowned then
		local dmg = Config.Damage.VoidDamage[match.DifficultyId] or 20
		callDep("DamageService", "Damage", player, dmg, "Void", { IgnoreIFrames = true })
	end
	teleportTo(player, jitterCFrame(teamSpawnCFrame(match), CHECKPOINT_SPREAD))
	if not isDowned(player) then
		callDep("DamageService", "GrantInvulnerability", player, 1.5)
	end
end

----------------------------------------------------------------------
-- Per-player hooks: character respawn + death
----------------------------------------------------------------------
local function attachDied(match, player, hum)
	local rec = match.Recs[player]
	if not rec then
		return
	end
	if rec.DiedConn then
		rec.DiedConn:Disconnect()
		rec.DiedConn = nil
	end
	rec.DiedConn = hum.Died:Connect(function()
		if match.Stopped or not isMember(match, player) then
			return
		end
		-- a KO'd character that dies for real (reset button) comes back healthy at the checkpoint
		setAttr(player, Config.Attr.Downed, false)
		broadcastState(match)
	end)
end

local function onCharacterAdded(match, player, char)
	task.spawn(function()
		local hum = char:WaitForChild("Humanoid", 10)
		local root = char:WaitForChild("HumanoidRootPart", 10)
		if not hum or not root then
			return
		end
		if not isMember(match, player) or match.Stopped then
			return
		end
		attachDied(match, player, hum)

		task.wait(RESPAWN_FIX_DELAY)
		if match.Stopped or not isMember(match, player) then
			return
		end
		if player.Character ~= char or hum.Parent == nil or hum.Health <= 0 then
			return
		end

		-- PlayerService normally already placed us via GetRespawnCFrame; make sure.
		local finished = match.Finished[player] == true
		local target = teamSpawnCFrame(match)
		if finished then
			target = finishCFrame(match)
		end
		if (root.Position - target.Position).Magnitude > 80 then
			if finished then
				teleportTo(player, spreadCFrame(target, 1, Config.Match.MaxPlayers, FINISH_SPREAD))
			else
				teleportTo(player, jitterCFrame(target, CHECKPOINT_SPREAD))
			end
		end

		-- respawn rule: back at the checkpoint immediately, 50% health, no penalty
		setAttr(player, Config.Attr.Downed, false)
		callDep("DamageService", "SetHealthFraction", player, Config.Damage.ReviveHealthFraction)
		callDep("DamageService", "GrantInvulnerability", player, 2)
		if match.State == "Countdown" or finished then
			setFrozen(player, true)
		end
	end)
end

local function hookPlayer(match, player)
	local rec = match.Recs[player]
	if not rec then
		return
	end
	table.insert(rec.Conns, player.CharacterAdded:Connect(function(char)
		onCharacterAdded(match, player, char)
	end))
	local char = player.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			attachDied(match, player, hum)
		end
	end
end

----------------------------------------------------------------------
-- Membership
----------------------------------------------------------------------
local function enrollPlayer(match, player, index, count)
	playerMatch[player] = match
	match.Tokens[player] = 0
	match.Recs[player] = { Conns = {} }
	-- InMatch first: the lobby watchdog would otherwise yank a player standing at y=800 home
	setAttr(player, Config.Attr.InMatch, true)
	setAttr(player, Config.Attr.Downed, false)
	setAttr(player, Config.Attr.MatchTokens, 0)
	callDep("DamageService", "SetHealthFraction", player, 1)
	callDep("DamageService", "GrantInvulnerability", player, Config.Match.IntroCountdown + 2)
	teleportTo(player, spreadCFrame(match.Course.StartCFrame, index, count, START_SPREAD))
	setFrozen(player, true)
	hookPlayer(match, player)
end

-- Remove a player from a match and (optionally) send them home. Does not end the match.
detachPlayer = function(match, player, toLobby)
	if playerMatch[player] ~= match then
		return
	end
	playerMatch[player] = nil
	removeValue(match.Players, player)
	match.Alive[player] = nil
	local rec = match.Recs[player]
	match.Recs[player] = nil
	if rec then
		for _, conn in ipairs(rec.Conns) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		if rec.DiedConn then
			pcall(function()
				rec.DiedConn:Disconnect()
			end)
		end
	end
	if player.Parent == nil then
		return -- they left the game, nothing to restore
	end

	local wasDowned = isDowned(player)
	setFrozen(player, false)
	if wasDowned then
		-- silently leave the downed state (restores look + walk speed); fall back to a full Revive
		local cleared = callDep("DamageService", "ClearDowned", player)
		if not cleared then
			callDep("DamageService", "Revive", player)
		end
	end
	setAttr(player, Config.Attr.InMatch, false)
	setAttr(player, Config.Attr.Downed, false)
	setAttr(player, Config.Attr.MatchTokens, 0)
	fireClient("MatchState", player, nil)
	if toLobby then
		callDep("PlayerService", "ApplyHumanoidStats", player)
		callDep("PlayerService", "SendToLobby", player)
	end
end

----------------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------------
cleanupMatch = function(match)
	if match.CleanedUp then
		return
	end
	match.CleanedUp = true
	match.Stopped = true
	if match.State ~= "Ended" then
		match.State = "Ended"
	end
	if not match.Reason then
		match.Reason = "abandoned"
	end

	-- 1. stop everything that runs inside the course
	stopHazards(match)
	stopTokens(match)

	-- 2. event connections owned by the match
	for _, conn in ipairs(match.Connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	match.Connections = {}

	-- 3. players home (each in its own pcall so one bad character cannot strand the rest)
	for _, p in ipairs(copyList(match.Players)) do
		local ok, err = pcall(detachPlayer, match, p, true)
		if not ok then
			warn("[MatchService] detach failed: " .. tostring(err))
			playerMatch[p] = nil
		end
	end
	match.Players = {}
	match.Alive = {}

	-- 4. the course itself
	destroyCourse(match)

	-- 5. free the slot
	if slots[match.Slot] == match then
		slots[match.Slot] = nil
	end
	matches[match.Id] = nil

	-- 6. tell the world
	MatchService.MatchEnded:Fire(match, match.Won == true)
end

----------------------------------------------------------------------
-- Ending a match (victory / defeat / timeout / abandoned)
----------------------------------------------------------------------
endMatch = function(match, won, reason)
	if match.Stopped or match.State == "Ended" then
		return
	end
	local t = clock()
	local playSeconds = 0
	if match.StartedAt then
		playSeconds = t - match.StartedAt
	end
	if reason == "timeout" then
		playSeconds = match.Difficulty.TimeLimit
	end
	match.State = "Ended"
	match.Won = won
	match.Reason = reason
	match.EndedAt = t
	stopTokens(match)

	if reason == "abandoned" or #match.Players == 0 then
		cleanupMatch(match)
		return
	end

	-- victory bonus goes to everybody who made it to the finish
	local bonusValue = 0
	if won then
		bonusValue = Config.Match.TokenBonusOnWin[match.DifficultyId] or 0
	end
	local bonuses = {}
	for _, p in ipairs(match.Players) do
		if won and bonusValue > 0 and match.Finished[p] then
			bonuses[p] = bonusValue
			callDep("DataService", "AddTokens", p, bonusValue)
		end
	end

	local members = {}
	for _, p in ipairs(match.Players) do
		members[#members + 1] = {
			Name = nameOf(p),
			MatchTokens = match.Tokens[p] or 0,
			Finished = match.Finished[p] == true,
			Downed = isDowned(p),
		}
	end
	local diff = match.Difficulty
	for _, p in ipairs(match.Players) do
		fireClient("MatchResult", p, {
			Won = won,
			Reason = reason,
			Seconds = math.floor(playSeconds + 0.5),
			MatchTokens = match.Tokens[p] or 0,
			Bonus = bonuses[p] or 0,
			DifficultyId = diff.Id,
			DifficultyName = diff.DisplayName,
			TotalTokens = (match.Course and match.Course.TotalTokens) or 0,
			Members = members,
		})
		callDep("DamageService", "GrantInvulnerability", p, 2)
	end

	match.EndDeadline = t + Config.Match.EndScreenSeconds
	broadcastState(match)
end

----------------------------------------------------------------------
-- The worker loop
----------------------------------------------------------------------
local function refreshAlive(match)
	local alive = {}
	for _, p in ipairs(match.Players) do
		if not isDowned(p) then
			alive[p] = true
		end
	end
	match.Alive = alive
end

local function beginPlaying(match, t)
	match.State = "Playing"
	match.StartedAt = t
	match.LastStateAt = 0
	for _, p in ipairs(copyList(match.Players)) do
		if isMember(match, p) and not match.Finished[p] then
			setFrozen(p, false)
		end
	end
	notifyAll(match, "Go! Climb together, and nobody gets left behind.", "good", 3.5)
	broadcastState(match)
end

local function processPlayerPlaying(match, player)
	local hum, root = getLive(player)
	if not hum or not root then
		return
	end
	local course = match.Course
	local downed = isDowned(player)
	local finished = match.Finished[player] == true

	if root.Position.Y < course.KillY then
		handleVoid(match, player, downed, finished)
		return
	end
	if downed or finished then
		return
	end

	-- checkpoints: highest unreached one the player is standing on
	local pos = root.Position
	for index = match.MaxCheckpoint, match.Checkpoint + 1, -1 do
		local cp = course.Checkpoints[index]
		if cp and cp.Part and cp.Part.Parent and isOverPart(cp.Part, pos, 2, 2, 9) then
			reachCheckpoint(match, index, player)
			break
		end
	end

	local pad = course.Finish
	if pad and pad.Parent and isOverPart(pad, pos, 1, 2, 9) then
		markFinished(match, player)
	end
end

local function tickPlaying(match, t)
	for _, player in ipairs(copyList(match.Players)) do
		if isMember(match, player) and match.State == "Playing" and not match.Stopped then
			local ok, err = pcall(processPlayerPlaying, match, player)
			if not ok then
				warn("[MatchService] player tick failed: " .. tostring(err))
			end
			if match.Finished[player] then
				callDep("DamageService", "GrantInvulnerability", player, 1)
			end
		end
	end
	if match.State ~= "Playing" or match.Stopped then
		return
	end

	refreshAlive(match)
	local aliveCount = 0
	local finishedAlive = 0
	for p in pairs(match.Alive) do
		aliveCount = aliveCount + 1
		if match.Finished[p] then
			finishedAlive = finishedAlive + 1
		end
	end

	if aliveCount > 0 and finishedAlive == aliveCount then
		endMatch(match, true, "victory")
		return
	end
	if aliveCount == 0 then
		endMatch(match, false, "defeat")
		return
	end

	local limit = match.Difficulty.TimeLimit
	local left = limit - (t - match.StartedAt)
	if left <= 0 then
		endMatch(match, false, "timeout")
		return
	end
	if limit > 150 and left <= 60 and not match.Warned60 then
		match.Warned60 = true
		notifyAll(match, "One minute left!", "bad", 4)
	end

	if t - match.LastStateAt >= STATE_INTERVAL then
		broadcastState(match)
	end
end

local function tickEnded(match, t)
	for _, player in ipairs(copyList(match.Players)) do
		if isMember(match, player) then
			callDep("DamageService", "GrantInvulnerability", player, 1)
			local hum, root = getLive(player)
			if hum and root and root.Position.Y < match.Course.KillY then
				-- no damage on the results screen, just bring them back
				if match.Finished[player] then
					teleportTo(player, finishCFrame(match))
				else
					teleportTo(player, jitterCFrame(teamSpawnCFrame(match), CHECKPOINT_SPREAD))
				end
			end
		end
	end
	if t >= (match.EndDeadline or t) then
		cleanupMatch(match)
		return
	end
	if t - match.LastStateAt >= STATE_INTERVAL then
		broadcastState(match)
	end
end

local function tickMatch(match)
	local t = clock()
	if #match.Players == 0 then
		if match.State ~= "Ended" then
			match.State = "Ended"
			match.Won = false
			match.Reason = "abandoned"
		end
		cleanupMatch(match)
		return
	end
	refreshAlive(match)

	if match.State == "Countdown" then
		if t >= match.CountdownEnd then
			beginPlaying(match, t)
		else
			local remaining = math.ceil(match.CountdownEnd - t)
			if remaining ~= match.LastCountdown then
				match.LastCountdown = remaining
				broadcastState(match)
			end
		end
	elseif match.State == "Playing" then
		tickPlaying(match, t)
	elseif match.State == "Ended" then
		tickEnded(match, t)
	end
end

local function runMatch(match)
	local errors = 0
	while not match.Stopped do
		local ok, err = pcall(tickMatch, match)
		if ok then
			errors = 0
		else
			errors = errors + 1
			warn("[MatchService] tick error (match " .. tostring(match.Id) .. "): " .. tostring(err))
			if errors >= MAX_TICK_ERRORS then
				warn("[MatchService] closing broken match " .. tostring(match.Id))
				pcall(cleanupMatch, match)
				break
			end
		end
		task.wait(TICK)
	end
end

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------
local function allocateSlot()
	for s = 1, Config.Match.MaxConcurrent do
		if slots[s] == nil then
			return s
		end
	end
	return nil
end

-- Generate (and validate) a layout, build the course, attach hazards + token pickup, and hook the
-- checkpoint / finish touch events. Errors propagate to the caller (StartMatch cleans up).
local function setupCourse(match)
	local CB = deps.CourseBuilder
	if not CB or type(CB.GenerateLayout) ~= "function" or type(CB.Build) ~= "function" then
		error("CourseBuilder dependency missing")
	end
	match.Origin = Config.Match.ArenaOrigin + Vector3.new((match.Slot - 1) * Config.Match.SlotSpacing, 0, 0)

	local layout = nil
	for attempt = 1, LAYOUT_ATTEMPTS do
		local seed = os.time() + match.Slot * 101 + match.Id * 7 + attempt
		local okLayout, result = pcall(CB.GenerateLayout, match.DifficultyId, seed)
		if okLayout and type(result) == "table" then
			layout = result
			match.Seed = result.Seed or seed
			local valid = true
			if type(CB.ValidateLayout) == "function" then
				local okValid, isValid, problems = pcall(CB.ValidateLayout, result)
				if okValid and isValid == false then
					valid = false
					local first = "?"
					if type(problems) == "table" and problems[1] then
						first = tostring(problems[1])
					end
					warn("[MatchService] layout seed " .. tostring(seed) .. " failed validation: " .. first)
				end
			end
			if valid then
				break
			end
		else
			warn("[MatchService] GenerateLayout failed: " .. tostring(result))
		end
	end
	if not layout then
		error("could not generate a course layout")
	end

	local okBuild, info = pcall(CB.Build, layout, match.Origin, Workspace)
	if not okBuild or type(info) ~= "table" then
		error("course build failed: " .. tostring(info))
	end
	match.Layout = layout
	match.Course = info
	if not info.StartCFrame or not info.Finish then
		error("course is missing its start or finish")
	end

	local maxCheckpoint = 0
	local count = 0
	for index in pairs(info.Checkpoints or {}) do
		count = count + 1
		if index > maxCheckpoint then
			maxCheckpoint = index
		end
	end
	info.Checkpoints = info.Checkpoints or {}
	match.TotalCheckpoints = count
	match.MaxCheckpoint = maxCheckpoint

	-- hazards pause unless the match is actually being played
	local hazardHandle = {
		IsActive = function()
			return match.State == "Playing" and not match.Stopped
		end,
	}
	local HS = deps.HazardService
	if HS and type(HS.Attach) == "function" then
		local okH, stopH = pcall(HS.Attach, info.Folder, hazardHandle)
		if okH and type(stopH) == "function" then
			match.StopHazards = stopH
		elseif not okH then
			warn("[MatchService] HazardService.Attach failed: " .. tostring(stopH))
		end
	end

	local TS = deps.TokenService
	if TS and type(TS.Watch) == "function" then
		local tokenHandle = {
			AddTokens = function(player, n)
				addTokens(match, player, n)
			end,
		}
		local okT, stopT = pcall(TS.Watch, info.Folder, tokenHandle)
		if okT and type(stopT) == "function" then
			match.StopTokens = stopT
		elseif not okT then
			warn("[MatchService] TokenService.Watch failed: " .. tostring(stopT))
		end
	end

	-- Touched gives instant feedback, the 4 Hz proximity poll in the worker loop is the backup.
	for index, cp in pairs(info.Checkpoints) do
		if cp.Part then
			table.insert(match.Connections, cp.Part.Touched:Connect(function(hit)
				onCheckpointTouched(match, index, hit)
			end))
		end
	end
	table.insert(match.Connections, info.Finish.Touched:Connect(function(hit)
		onFinishTouched(match, hit)
	end))
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function MatchService.Init(d)
	deps = d or deps or {}
	if initialized then
		return
	end
	initialized = true

	-- Reset-button deaths should respawn quickly (the match rule is "back at the checkpoint").
	pcall(function()
		if Players.RespawnTime > SHORT_RESPAWN_TIME then
			Players.RespawnTime = SHORT_RESPAWN_TIME
		end
	end)

	local okRemote, leaveRemote = pcall(Remotes.Get, "LeaveMatch")
	if okRemote and leaveRemote then
		leaveRemote.OnServerEvent:Connect(function(player)
			MatchService.LeaveMatch(player)
		end)
	else
		warn("[MatchService] LeaveMatch remote unavailable")
	end

	Players.PlayerRemoving:Connect(function(player)
		local match = playerMatch[player]
		if match then
			detachPlayer(match, player, false)
			if #match.Players == 0 and not match.CleanedUp then
				if match.State ~= "Ended" then
					match.State = "Ended"
					match.Won = false
					match.Reason = "abandoned"
				end
				cleanupMatch(match)
			end
		end
	end)

	local dmg = deps.DamageService
	if dmg and dmg.PlayerDowned and type(dmg.PlayerDowned.Connect) == "function" then
		dmg.PlayerDowned:Connect(function(player)
			local match = playerMatch[player]
			if not match or match.State ~= "Playing" or match.Stopped then
				return
			end
			notifyAll(match, nameOf(player) .. " is down! Reach the next checkpoint to lift them up.", "bad", 4, player)
			broadcastState(match)
		end)
	end
end

-- Start a match for `players` on the lowest free slot. Returns the match, or nil when no arena
-- slot is free / the course could not be built.
function MatchService.StartMatch(difficultyId, players)
	if not initialized then
		warn("[MatchService] StartMatch before Init")
		return nil
	end
	local diff = Config.GetDifficulty(difficultyId)
	if not diff then
		warn("[MatchService] unknown difficulty " .. tostring(difficultyId))
		return nil
	end

	local candidates = {}
	local seen = {}
	for _, p in ipairs(players or {}) do
		if p and p.Parent ~= nil and not seen[p] and not playerMatch[p] and #candidates < Config.Match.MaxPlayers then
			seen[p] = true
			table.insert(candidates, p)
		end
	end
	if #candidates == 0 then
		return nil
	end

	local slot = allocateSlot()
	if not slot then
		return nil
	end

	nextMatchId = nextMatchId + 1
	local match = {
		Id = nextMatchId,
		DifficultyId = diff.Id,
		Difficulty = diff,
		Slot = slot,
		Players = {},
		Alive = {},
		State = "Setup",
		Checkpoint = 0,
		TotalCheckpoints = 0,
		MaxCheckpoint = 0,
		StartedAt = nil,
		Course = nil,
		Won = false,
		Reason = nil,
		TeamTokens = 0,
		FinishCount = 0,
		LastStateAt = 0,
		Tokens = {}, -- Player -> tokens this match
		Finished = {}, -- Player -> true
		Recs = {}, -- Player -> { Conns, DiedConn }
		Connections = {}, -- match-level connections (checkpoint / finish Touched)
		Stopped = false,
		CleanedUp = false,
	}
	slots[slot] = match -- reserve the slot before anything can yield
	matches[match.Id] = match

	local okSetup, errSetup = pcall(setupCourse, match)
	if not okSetup then
		warn("[MatchService] setup failed: " .. tostring(errSetup))
		match.Stopped = true
		stopHazards(match)
		stopTokens(match)
		for _, conn in ipairs(match.Connections) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		destroyCourse(match)
		slots[slot] = nil
		matches[match.Id] = nil
		return nil
	end

	-- players may have left while the course was being built
	local present = {}
	for _, p in ipairs(candidates) do
		if p.Parent ~= nil and not playerMatch[p] then
			table.insert(present, p)
		end
	end
	if #present == 0 then
		match.Won = false
		match.Reason = "abandoned"
		cleanupMatch(match)
		return nil
	end

	match.Players = present
	for i, p in ipairs(present) do
		local ok, err = pcall(enrollPlayer, match, p, i, #present)
		if not ok then
			warn("[MatchService] enroll failed for " .. tostring(p.Name) .. ": " .. tostring(err))
		end
	end
	refreshAlive(match)

	match.State = "Countdown"
	match.CountdownEnd = clock() + Config.Match.IntroCountdown
	match.LastCountdown = math.ceil(Config.Match.IntroCountdown)
	broadcastState(match)

	for _, p in ipairs(present) do
		notify(p, "Welcome to " .. diff.DisplayName .. "! Get ready...", "info", 3)
	end

	task.spawn(runMatch, match)
	return match
end

function MatchService.GetMatchOf(player)
	return playerMatch[player]
end

-- SpawnProvider for PlayerService: team checkpoint spawn (scattered), nil => lobby spawn.
function MatchService.GetRespawnCFrame(player)
	local match = playerMatch[player]
	if not match or match.Stopped or not match.Course then
		return nil
	end
	if match.Finished[player] then
		return spreadCFrame(finishCFrame(match), random:NextInteger(1, 4), 4, FINISH_SPREAD)
	end
	local spread = CHECKPOINT_SPREAD
	if match.Checkpoint < 1 then
		spread = START_SPREAD
	end
	return jitterCFrame(teamSpawnCFrame(match), spread)
end

-- Player goes back to the lobby; the match carries on without them (or closes if they were last).
function MatchService.LeaveMatch(player)
	local match = playerMatch[player]
	if not match then
		return
	end
	local name = nameOf(player)
	detachPlayer(match, player, true)
	if #match.Players == 0 then
		if match.State ~= "Ended" then
			match.State = "Ended"
			match.Won = false
			match.Reason = "abandoned"
		end
		cleanupMatch(match)
	else
		notifyAll(match, name .. " left the match.", "info", 3)
		broadcastState(match)
	end
end

return MatchService
