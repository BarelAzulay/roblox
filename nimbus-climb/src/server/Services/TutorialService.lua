-- TutorialService: server-authoritative progress of the new-player tutorial (ARCHITECTURE_V3.md section 4).
--
--   TutorialService.Init(lobbyInfo, deps)     deps = { DataService, PetService, MatchService, SpotService, IndexService }
--   TutorialService.GetState(player) -> payload | nil       (the TutorialState payload below, a fresh copy)
--   TutorialService.HandleEvent(player, eventName) -> ok, reason      (what the TutorialEvent remote does)
--   TutorialService.StepCompleted              Util.Signal, Fire(player, stepId, stepIndex)
--   TutorialService.Finished                   Util.Signal, Fire(player, skipped)
--
-- Steps come from shared/TutorialSteps.lua. Progress lives in the profile (DataService.GetTutorial /
-- SetTutorial: { Step, Done, Gifted }) and only ever moves forward (DataService merges it the same way).
-- A step completes on what the SERVER observes:
--   NearSpot      2 Hz poll: the character within 14 studs (horizontally) of SpotService.GetSpot(player).Center
--   Rolled        PetService.Rolled (backup: Profile.Stats.Spins grew since the step began)
--   Equipped      the equipped list changed to a non-empty one (PetService.PerksChanged / attribute EquippedPets),
--                 or the client reports "PetsOpened" while a pet is equipped (a brand-new player's first pet is
--                 auto-equipped by the roulette, so opening Pets is how they "see" it)
--   MatchStarted  / MatchEnded: the player attribute InMatch turning true / false
--   Next / ShopOpened / IndexOpened: client reports through the TutorialEvent remote, accepted only when they
--                 match the CURRENT step. "Skip" ends the tutorial (Done = true, no finish reward); "Sync" asks for
--                 the current state again. The remote is type checked and rate limited.
-- Entering a Gift step grants Config.Tutorial.GiftTokens once (Tutorial.Gifted is stored first); completing the
-- last step grants Config.Tutorial.FinishReward once (Done is stored first). A step that cannot be done because a
-- service is missing (no PetService, no MatchService, no spot for this player) is passed automatically.
--
-- TutorialState payload (server -> that player, on join, on every change, on "Sync"):
--   { Step = n, Total = #Steps, Id, Title, Text, Target = {Kind, Id, Label, Position = Vector3|nil, SpotIndex},
--     CompleteOn, Hint, Button, Gift = bool, Done = bool, Completed = bool (finished this session), Skipped = bool,
--     Reward = tokens granted on completion }
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local TutorialService = {}
TutorialService.StepCompleted = Util.Signal()
TutorialService.Finished = Util.Signal()

local POLL_INTERVAL = 0.5 -- seconds (NearSpot / level checks run at 2 Hz)
local EVENT_COOLDOWN = 0.25 -- seconds per player between TutorialEvent requests
local SYNC_COOLDOWN = 1 -- seconds per player between "Sync" requests
local MAX_EVENT_LENGTH = 32
local NEAR_SPOT_RADIUS = 14 -- studs, horizontal
local NEAR_SPOT_HEIGHT = 24 -- studs of vertical slack (the root stands ~3 studs above the yard)
local NO_SPOT_GRACE = 10 -- seconds without a spot before the home step is passed
local TOKEN_GLYPH = "\226\152\129" -- cloud

-- client event -> the CompleteOn it can complete (Skip / Sync are handled separately)
local EVENT_COMPLETES = {
	Next = "Next",
	ShopOpened = "ShopOpened",
	IndexOpened = "IndexOpened",
	PetsOpened = "Equipped",
}

local KNOWN_COMPLETE_ON = {
	Next = true,
	NearSpot = true,
	ShopOpened = true,
	Rolled = true,
	Equipped = true,
	IndexOpened = true,
	MatchStarted = true,
	MatchEnded = true,
}

----------------------------------------------------------------------
-- Collaborators (other engineers' modules: every use is guarded)
----------------------------------------------------------------------

local function loadModule(parent, name)
	local module = parent and parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[TutorialService] could not load " .. name .. ": " .. tostring(result))
	return nil
end

local TutorialSteps = loadModule(Shared, "TutorialSteps")

local DataService = nil
local PetService = nil
local MatchService = nil
local SpotService = nil
local lobby = nil

local function hasSignal(module, name)
	return type(module) == "table" and type(module[name]) == "table" and type(module[name].Connect) == "function"
end

local function hasFunction(module, name)
	return type(module) == "table" and type(module[name]) == "function"
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local steps = {} -- validated copy of TutorialSteps.Steps
local tracks = {} -- [player] = { Step, Done, Gifted, Completed, Skipped, Reward, SpinsBase, LastEquipped, NoSpotTime }
local playerConns = {} -- [player] = { RBXScriptConnection... }
local lastEvent = {} -- [player] = os.clock() of the last accepted TutorialEvent
local lastSync = {} -- [player] = os.clock() of the last answered "Sync"
local initialized = false
local running = false

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function isLivePlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function fireClient(remoteName, player, ...)
	if not isLivePlayer(player) then
		return
	end
	local okGet, remote = pcall(Remotes.Get, remoteName)
	if not okGet or not remote then
		return
	end
	local args = { n = select("#", ...), ... }
	local ok, err = pcall(function()
		remote:FireClient(player, unpack(args, 1, args.n))
	end)
	if not ok then
		warn("[TutorialService] " .. remoteName .. " failed: " .. tostring(err))
	end
end

local function notify(player, text, kind, duration)
	fireClient("Notify", player, text, kind or "info", duration or 4)
end

local function positiveInt(n)
	if type(n) == "number" and n == n and n > 0 and n < math.huge then
		return math.floor(n)
	end
	return 0
end

local function giftTokens()
	local t = type(Config.Tutorial) == "table" and Config.Tutorial or {}
	return positiveInt(t.GiftTokens)
end

local function finishTokens()
	local t = type(Config.Tutorial) == "table" and Config.Tutorial or {}
	local reward = t.FinishReward
	if type(reward) == "table" then
		return positiveInt(reward.Tokens)
	end
	return positiveInt(reward)
end

local function formatText(text)
	text = tostring(text or "")
	text = text:gsub("{GiftTokens}", tostring(giftTokens()))
	text = text:gsub("{FinishTokens}", tostring(finishTokens()))
	return text
end

-- Copies TutorialSteps.Steps into a clean local list (bad entries are dropped, unknown CompleteOn -> "Next").
local function buildSteps()
	steps = {}
	local source = type(TutorialSteps) == "table" and TutorialSteps.Steps
	if type(source) ~= "table" then
		return
	end
	for _, raw in ipairs(source) do
		if type(raw) == "table" and type(raw.Id) == "string" then
			local completeOn = raw.CompleteOn
			if not KNOWN_COMPLETE_ON[completeOn] then
				completeOn = "Next"
			end
			local target = nil
			if type(raw.Target) == "table" and type(raw.Target.Kind) == "string" then
				target = { Kind = raw.Target.Kind, Id = raw.Target.Id, Label = raw.Target.Label }
			end
			table.insert(steps, {
				Id = raw.Id,
				Title = type(raw.Title) == "string" and raw.Title or "",
				Text = type(raw.Text) == "string" and raw.Text or "",
				Target = target,
				CompleteOn = completeOn,
				Gift = raw.Gift == true,
				Hint = type(raw.Hint) == "string" and raw.Hint or nil,
				Button = type(raw.Button) == "string" and raw.Button or nil,
			})
		end
	end
end

local function inMatch(player)
	return player:GetAttribute(Config.Attr.InMatch) == true
end

local function getProfile(player)
	if not hasFunction(DataService, "GetProfile") then
		return nil
	end
	local ok, profile = pcall(DataService.GetProfile, player)
	if ok and type(profile) == "table" then
		return profile
	end
	return nil
end

local function spinsOf(player)
	local profile = getProfile(player)
	local stats = profile and profile.Stats
	if type(stats) == "table" and type(stats.Spins) == "number" then
		return stats.Spins
	end
	return 0
end

-- The equipped list as a csv (profile first, the replicated attribute as a fallback).
local function equippedCsv(player)
	local profile = getProfile(player)
	if profile and type(profile.Equipped) == "table" then
		local ids = {}
		for _, id in ipairs(profile.Equipped) do
			if type(id) == "string" then
				table.insert(ids, id)
			end
		end
		return table.concat(ids, ",")
	end
	local attr = player:GetAttribute(Config.Attr.EquippedPets)
	if type(attr) == "string" then
		return attr
	end
	return ""
end

local function getSpot(player)
	if not hasFunction(SpotService, "GetSpot") then
		return nil
	end
	local ok, spot = pcall(SpotService.GetSpot, player)
	if ok and type(spot) == "table" then
		return spot
	end
	return nil
end

local function rootOf(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function firstRouletteId()
	local list = Config.Roulettes
	if type(list) == "table" and type(list[1]) == "table" and type(list[1].Id) == "string" then
		return list[1].Id
	end
	return "Cloud"
end

-- World position of a step target (nil when unknown); the client also finds the models by name.
local function targetPosition(player, target)
	local kind = target.Kind
	if kind == "Spot" then
		local spot = getSpot(player)
		if spot and typeof(spot.Center) == "Vector3" then
			return spot.Center
		end
	elseif kind == "Portal" then
		local portals = lobby and lobby.Portals
		local info = type(portals) == "table" and portals[target.Id or "Easy"]
		if type(info) == "table" and typeof(info.Center) == "Vector3" then
			return info.Center
		end
	elseif kind == "Roulette" or kind == "Shop" then
		local shop = lobby and lobby.Shop
		local roulettes = type(shop) == "table" and shop.Roulettes
		local info = type(roulettes) == "table" and roulettes[target.Id or firstRouletteId()]
		if type(info) == "table" and typeof(info.Center) == "Vector3" then
			return info.Center
		end
	end
	return nil
end

local function targetFor(player, step)
	local target = step.Target
	if not target then
		return nil
	end
	local out = { Kind = target.Kind, Id = target.Id, Label = target.Label }
	if out.Kind == "Shop" and out.Id == nil then
		out.Id = firstRouletteId()
	end
	if out.Kind == "Spot" then
		local index = player:GetAttribute(Config.Attr.SpotIndex)
		if type(index) == "number" then
			out.SpotIndex = index
		end
	end
	local ok, position = pcall(targetPosition, player, out)
	if ok and typeof(position) == "Vector3" then
		out.Position = position
	end
	return out
end

local function currentStep(track)
	if not track or track.Done then
		return nil
	end
	return steps[track.Step]
end

----------------------------------------------------------------------
-- State payload + persistence
----------------------------------------------------------------------

local function buildPayload(player, track)
	local total = #steps
	local index = math.max(1, math.min(track.Step, total))
	local step = steps[index]
	return {
		Step = index,
		Total = total,
		Id = step.Id,
		Title = step.Title,
		Text = formatText(step.Text),
		Target = targetFor(player, step),
		CompleteOn = step.CompleteOn,
		Hint = step.Hint,
		Button = step.Button,
		Gift = step.Gift,
		Done = track.Done == true,
		Completed = track.Completed == true,
		Skipped = track.Skipped == true,
		Reward = track.Reward or 0,
	}
end

local function sendState(player, track)
	if not isLivePlayer(player) or not track or #steps == 0 then
		return
	end
	fireClient("TutorialState", player, buildPayload(player, track))
end

-- Writes the progress to the profile. Returns true when stored.
local function persist(player, track)
	if not hasFunction(DataService, "SetTutorial") then
		return false
	end
	local ok, stored = pcall(DataService.SetTutorial, player, {
		Step = track.Step,
		Done = track.Done == true,
		Gifted = track.Gifted == true,
	})
	return ok and stored == true
end

local function addTokens(player, amount)
	if amount <= 0 or not hasFunction(DataService, "AddTokens") then
		return false
	end
	local ok, err = pcall(DataService.AddTokens, player, amount)
	if not ok then
		warn("[TutorialService] AddTokens failed: " .. tostring(err))
	end
	return ok
end

----------------------------------------------------------------------
-- Step flow
----------------------------------------------------------------------

-- Called whenever a player arrives on a step (also on load): baselines + the one-time gift.
-- Returns true when it already stored the progress (the gift step does).
local function enterStep(player, track)
	local step = currentStep(track)
	if not step then
		return false
	end
	track.SpinsBase = spinsOf(player)
	track.LastEquipped = equippedCsv(player)
	track.NoSpotTime = 0
	if step.Gift and not track.Gifted then
		local amount = giftTokens()
		track.Gifted = true
		-- Gifted is stored BEFORE the tokens are paid: a crash in between can never pay twice
		if persist(player, track) then
			if amount > 0 and addTokens(player, amount) then
				notify(player, "Nimbus gave you " .. amount .. " " .. TOKEN_GLYPH .. " Cloud Tokens!", "token", 5)
			end
			return true
		end
		track.Gifted = false -- not stored: try again on the next load
	end
	return false
end

local function finish(player, track, skipped)
	if track.Done then
		return
	end
	track.Done = true
	if skipped then
		track.Skipped = true
	else
		track.Completed = true
		track.Step = #steps + 1 -- one past the end: later phases can append steps and resume from here
	end
	local stored = persist(player, track)
	if not skipped and stored and not track.Replay then
		local amount = finishTokens()
		if amount > 0 and addTokens(player, amount) then
			track.Reward = amount
			notify(player, "Tutorial complete! +" .. amount .. " " .. TOKEN_GLYPH .. " from Nimbus", "good", 6)
		end
	elseif skipped then
		notify(player, "Tutorial skipped. Nimbus is cheering for you!", "info", 4)
	end
	sendState(player, track)
	TutorialService.Finished:Fire(player, skipped == true)
end

-- Completes the current step and moves on (the last step finishes the tutorial).
local function advance(player, track)
	local step = currentStep(track)
	if not step then
		return
	end
	local index = track.Step
	TutorialService.StepCompleted:Fire(player, step.Id, index)
	if index >= #steps then
		finish(player, track, false)
		return
	end
	track.Step = index + 1
	if not enterStep(player, track) then
		persist(player, track)
	end
	sendState(player, track)
end

-- True when a step cannot be done in this server (a service is missing) and should be passed.
local function impossible(player, track, step)
	local kind = step.CompleteOn
	if kind == "Rolled" or kind == "Equipped" then
		return PetService == nil
	elseif kind == "NearSpot" then
		return not hasFunction(SpotService, "GetSpot") or (track.NoSpotTime or 0) >= NO_SPOT_GRACE
	elseif kind == "MatchStarted" or kind == "MatchEnded" then
		return MatchService == nil
	end
	return false
end

local function nearSpot(player)
	local spot = getSpot(player)
	local root = rootOf(player)
	if not spot or not root or typeof(spot.Center) ~= "Vector3" then
		return false
	end
	local offset = root.Position - spot.Center
	local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
	return flat <= NEAR_SPOT_RADIUS and math.abs(offset.Y) <= NEAR_SPOT_HEIGHT
end

-- Level-based completion checks (state the server can see right now).
local function satisfied(player, track, step)
	local kind = step.CompleteOn
	if kind == "MatchStarted" then
		return inMatch(player)
	elseif kind == "MatchEnded" then
		return not inMatch(player)
	elseif kind == "NearSpot" then
		return not inMatch(player) and nearSpot(player)
	elseif kind == "Rolled" then
		return spinsOf(player) > (track.SpinsBase or math.huge)
	end
	return false
end

-- Advances through every step that is already complete (bounded by the step count).
local function settle(player, track)
	for _ = 1, #steps + 1 do
		local step = currentStep(track)
		if not step or not isLivePlayer(player) then
			return
		end
		if not (satisfied(player, track, step) or impossible(player, track, step)) then
			return
		end
		advance(player, track)
	end
end

-- Equip changes: complete "Equipped" when the list changed to a non-empty one.
local function onEquipChanged(player)
	local track = tracks[player]
	if not track or track.Done then
		return
	end
	local csv = equippedCsv(player)
	if csv == track.LastEquipped then
		return
	end
	track.LastEquipped = csv
	local step = currentStep(track)
	if step and step.CompleteOn == "Equipped" and csv ~= "" then
		advance(player, track)
		settle(player, track)
	end
end

----------------------------------------------------------------------
-- Players
----------------------------------------------------------------------

-- Creates the player's track from the stored progress. Returns true once loaded.
local function loadPlayer(player)
	if tracks[player] then
		return true
	end
	if #steps == 0 or not isLivePlayer(player) or not hasFunction(DataService, "GetTutorial") then
		return false
	end
	local ok, stored = pcall(DataService.GetTutorial, player)
	if not ok or type(stored) ~= "table" then
		return false -- profile not loaded yet
	end
	local step = tonumber(stored.Step) or 1
	step = math.max(1, math.floor(step))
	local track = {
		Step = step,
		Done = stored.Done == true,
		Gifted = stored.Gifted == true,
		Completed = false,
		Skipped = false,
		Reward = 0,
		NoSpotTime = 0,
	}
	if not track.Done and track.Step > #steps then
		track.Step = #steps -- steps were removed since: land on the last one
	end
	tracks[player] = track
	if not track.Done then
		enterStep(player, track)
	end
	sendState(player, track)
	settle(player, track)
	return true
end

-- The stored profile changed under us (recovered load / another server): merge forward, never back.
-- Drops the running tutorial and reads it again from the profile (used by the developer tools after they rewind
-- the stored tutorial). opts.Replay = true marks a replay of a tutorial that was already finished once: its finish
-- reward is not paid again. Returns true when the player's tutorial is running again.
local function reloadPlayer(player, opts)
	if not isLivePlayer(player) then
		return false
	end
	tracks[player] = nil
	local ok = loadPlayer(player)
	local track = tracks[player]
	if track and type(opts) == "table" and opts.Replay == true then
		track.Replay = true
	end
	return ok == true
end

local function onProfileRebased(player)
	local track = tracks[player]
	if not track then
		loadPlayer(player)
		return
	end
	if not hasFunction(DataService, "GetTutorial") then
		return
	end
	local ok, stored = pcall(DataService.GetTutorial, player)
	if not ok or type(stored) ~= "table" then
		return
	end
	local changed = false
	if stored.Gifted == true and not track.Gifted then
		track.Gifted = true
	end
	if stored.Done == true and not track.Done then
		track.Done = true
		changed = true
	end
	local step = tonumber(stored.Step)
	if step and not track.Done and step > track.Step then
		track.Step = math.min(math.floor(step), #steps)
		enterStep(player, track)
		changed = true
	end
	if changed then
		sendState(player, track)
		settle(player, track)
	end
end

local function disconnectPlayer(player)
	local conns = playerConns[player]
	if conns then
		for _, conn in ipairs(conns) do
			pcall(function()
				conn:Disconnect()
			end)
		end
	end
	playerConns[player] = nil
end

local function onPlayerAdded(player)
	if playerConns[player] then
		return
	end
	local conns = {}
	playerConns[player] = conns
	table.insert(conns, player:GetAttributeChangedSignal(Config.Attr.InMatch):Connect(function()
		local track = tracks[player]
		if track then
			settle(player, track)
		end
	end))
	table.insert(conns, player:GetAttributeChangedSignal(Config.Attr.EquippedPets):Connect(function()
		onEquipChanged(player)
	end))
	-- the spot is assigned after the profile loads: refresh the arrow target when it arrives
	table.insert(conns, player:GetAttributeChangedSignal(Config.Attr.SpotIndex):Connect(function()
		local track = tracks[player]
		local step = currentStep(track)
		if step and step.Target and step.Target.Kind == "Spot" then
			track.NoSpotTime = 0
			sendState(player, track)
		end
	end))
	task.spawn(loadPlayer, player)
end

local function onPlayerRemoving(player)
	disconnectPlayer(player)
	tracks[player] = nil
	lastEvent[player] = nil
	lastSync[player] = nil
end

----------------------------------------------------------------------
-- Client events
----------------------------------------------------------------------

function TutorialService.HandleEvent(player, eventName)
	if not isLivePlayer(player) then
		return false, "Player unavailable"
	end
	if type(eventName) ~= "string" or #eventName > MAX_EVENT_LENGTH then
		return false, "Bad event"
	end
	local track = tracks[player]
	if not track then
		if not loadPlayer(player) then
			return false, "Not loaded"
		end
		track = tracks[player]
	end
	if eventName == "Sync" then
		sendState(player, track)
		return true
	end
	if track.Done then
		return false, "Tutorial already finished"
	end
	if eventName == "Skip" then
		finish(player, track, true)
		return true
	end
	local completes = EVENT_COMPLETES[eventName]
	if not completes then
		return false, "Unknown event"
	end
	local step = currentStep(track)
	if not step or step.CompleteOn ~= completes then
		return false, "Not the current step"
	end
	if completes == "Equipped" and equippedCsv(player) == "" then
		return false, "Equip a pet first"
	end
	advance(player, track)
	settle(player, track)
	return true
end

local function onTutorialEvent(player, eventName)
	if type(eventName) ~= "string" or #eventName > MAX_EVENT_LENGTH then
		return
	end
	local now = os.clock()
	if eventName == "Sync" then
		local last = lastSync[player]
		if last and now - last < SYNC_COOLDOWN then
			return
		end
		lastSync[player] = now
	else
		local last = lastEvent[player]
		if last and now - last < EVENT_COOLDOWN then
			return
		end
		lastEvent[player] = now
	end
	local ok, err = pcall(TutorialService.HandleEvent, player, eventName)
	if not ok then
		warn("[TutorialService] event " .. eventName .. " failed: " .. tostring(err))
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function TutorialService.Reload(player, opts)
	return reloadPlayer(player, opts)
end

function TutorialService.GetState(player)
	local track = player and tracks[player]
	if not track or #steps == 0 then
		return nil
	end
	return buildPayload(player, track)
end

-- Stops the poll loop (tests / shutdown). Tracks stay readable.
function TutorialService.Stop()
	running = false
end

----------------------------------------------------------------------
-- Poll loop (2 Hz): NearSpot, the no-spot grace, level checks, profiles that loaded without a signal
----------------------------------------------------------------------

local function pollPlayer(player, dt)
	local track = tracks[player]
	if not track then
		loadPlayer(player)
		return
	end
	local step = currentStep(track)
	if not step then
		return
	end
	if step.CompleteOn == "NearSpot" then
		if getSpot(player) then
			track.NoSpotTime = 0
		elseif not inMatch(player) then
			track.NoSpotTime = (track.NoSpotTime or 0) + dt
		end
	end
	settle(player, track)
end

local function pollLoop()
	local last = os.clock()
	while running do
		task.wait(POLL_INTERVAL)
		if not running then
			break
		end
		local now = os.clock()
		local dt = math.min(now - last, 2)
		last = now
		for _, player in ipairs(Players:GetPlayers()) do
			local ok, err = pcall(pollPlayer, player, dt)
			if not ok then
				warn("[TutorialService] poll failed: " .. tostring(err))
			end
		end
	end
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------

function TutorialService.Init(lobbyInfo, deps)
	if initialized then
		return
	end
	initialized = true
	deps = type(deps) == "table" and deps or {}
	lobby = type(lobbyInfo) == "table" and lobbyInfo or nil
	local services = script.Parent
	DataService = deps.DataService or loadModule(services, "DataService")
	PetService = deps.PetService or loadModule(services, "PetService")
	MatchService = deps.MatchService or loadModule(services, "MatchService")
	SpotService = deps.SpotService or loadModule(services, "SpotService")

	buildSteps()
	if #steps == 0 then
		warn("[TutorialService] no tutorial steps (shared/TutorialSteps missing?): tutorial disabled")
		return
	end
	if not DataService then
		warn("[TutorialService] DataService unavailable: tutorial disabled")
		return
	end

	-- remote: client-observed events
	local okRemote, remote = pcall(Remotes.Get, "TutorialEvent")
	if okRemote and remote then
		remote.OnServerEvent:Connect(onTutorialEvent)
	else
		warn("[TutorialService] TutorialEvent remote missing: " .. tostring(remote))
	end

	-- profile lifecycle
	if hasSignal(DataService, "ProfileLoaded") then
		DataService.ProfileLoaded:Connect(function(player)
			loadPlayer(player)
		end)
	end
	if hasSignal(DataService, "ProfileRebased") then
		DataService.ProfileRebased:Connect(function(player)
			onProfileRebased(player)
		end)
	end

	-- pets
	if hasSignal(PetService, "Rolled") then
		PetService.Rolled:Connect(function(player)
			local track = tracks[player]
			local step = currentStep(track)
			if step and step.CompleteOn == "Rolled" then
				advance(player, track)
				settle(player, track)
			end
		end)
	end
	if hasSignal(PetService, "PerksChanged") then
		PetService.PerksChanged:Connect(function(player)
			onEquipChanged(player)
		end)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	running = true
	task.spawn(pollLoop)
end

return TutorialService
