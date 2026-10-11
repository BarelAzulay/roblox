-- TutorialService: server-authoritative progress of the new-player tutorial (ARCHITECTURE_V3.md section 4 and the
-- Phase 2 "Tutorial" paragraph: claim a home, buy the first Cloud Press, collect the Cash, build the Kitchen, feed a
-- pet).
--
--   TutorialService.Init(lobbyInfo, deps)     deps = { DataService, PetService, MatchService, SpotService, IndexService,
--                                                      TycoonService, PetCareService }  (missing ones are looked up)
--   TutorialService.GetState(player) -> payload | nil       (the TutorialState payload below, a fresh copy)
--   TutorialService.HandleEvent(player, eventName) -> ok, reason      (what the TutorialEvent remote does)
--   TutorialService.Reload(player, opts) -> ok   drops the running tutorial and reads it again from the profile
--                                                (opts.Replay = true: no chapter rewards again; the developer tools)
--   TutorialService.StepCompleted              Util.Signal, Fire(player, stepId, stepIndex)
--   TutorialService.Finished                   Util.Signal, Fire(player, skipped)
--
-- Steps come from shared/TutorialSteps.lua, in CHAPTERS (1 = the basics, 2 = the tycoon home). Progress lives in the
-- profile (DataService.GetTutorial / SetTutorial: { Step, Done, Gifted }); DataService merges Done and Gifted so they
-- stick once true, so the stored fields mean:
--   Done = false              chapter 1 is running at Step
--   Done = true, Step inside a later chapter (2..)   chapter 1 is behind the player and that chapter runs at Step
--                             (a player who finished the Phase 1 tutorial has Step = 10: the home chapter starts there)
--   Done = true, Step = #Steps + 1   everything finished (a chapter added later starts from there)
--   Done = true, Step = SKIPPED_STEP (or a chapter-1 step: old saves)   skipped: no tutorial any more
-- Completing a step marked ChapterEnd pays that chapter's reward once (the step is stored BEFORE paying, so a crash
-- can never pay twice): chapter 1 = Config.Tutorial.FinishReward (tokens), chapter 2 = HOME_FINISH_CASH Cash.
--
-- A step completes on what the SERVER observes:
--   Claimed       the player owns a home plot (SpotService.GetSpot; TycoonService.Claimed / the SpotIndex attribute
--                 for an instant answer, a 2 Hz poll as the backup)
--   Built         the saved home has the step's Station at level >= 1 (DataService.GetHome; TycoonService.HomeChanged)
--   Collected     the Collector emptied into the balance: Home.CollectorCash went down while Cash went up (the Cash
--                 attribute changing + the poll; purchases, income ticks and offline pay never look like that)
--   Fed           PetCareService.Fed (the Pets panel's Feed or the Kitchen's bowl)
--   NearSpot      2 Hz poll: the character within 14 studs (horizontally) of SpotService.GetSpot(player).Center
--   Rolled        PetService.Rolled (backup: Profile.Stats.Spins grew since the step began)
--   Equipped      the equipped list changed to a non-empty one (PetService.PerksChanged / attribute EquippedPets),
--                 or the client reports "PetsOpened" while a pet is equipped
--   MatchStarted  / MatchEnded: the player attribute InMatch turning true / false
--   Next / ShopOpened / IndexOpened: client reports through the TutorialEvent remote, accepted only when they
--                 match the CURRENT step. "Skip" ends the tutorial (no reward, no later chapter); "Sync" asks for the
--                 current state again. The remote is type checked and rate limited.
-- Entering a Gift step grants Config.Tutorial.GiftTokens once (Tutorial.Gifted is stored first). A step that cannot
-- be done in this server because a service is missing (no PetService, MatchService, TycoonService, PetCareService)
-- is passed automatically, and so is a "Claimed" step while every plot stays taken for a minute.
--
-- Guide targets of the home steps are resolved HERE (the client only knows the lobby names): the gate of the plot to
-- claim (the claimed plot, else the last plot when free, else the nearest free one; pinned while it stays free so
-- the arrow does not hop between plots), a buy pad on the own plot (HomeBuilder.GetPad, else the TycoonCatalog slot),
-- the next pad on the way to a station (its prerequisites first), a built station (the Collector's CollectPad, the
-- Kitchen's counter), or the Pets menu button once the player has food to feed. They are sent as
-- { Kind = "Spot", Position, SpotIndex, Label } (or { Kind = "Menu", Id = "Pets" }) with a matching Hint, and the
-- poll re-sends the state whenever the target or the hint changes.
--
-- TutorialState payload (server -> that player, on join, on every change, on "Sync"):
--   { Step = n, Total = #Steps, Id, Title, Text, Target = {Kind, Id, Label, Position = Vector3|nil, SpotIndex},
--     CompleteOn, Hint, Button, Gift = bool, Chapter, Done = bool, Completed = bool (finished this session),
--     Skipped = bool, Reward = tokens granted on completion }
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

local POLL_INTERVAL = 0.5 -- seconds (NearSpot / level checks / target refresh run at 2 Hz)
local EVENT_COOLDOWN = 0.25 -- seconds per player between TutorialEvent requests
local SYNC_COOLDOWN = 1 -- seconds per player between "Sync" requests
local MAX_EVENT_LENGTH = 32
local NEAR_SPOT_RADIUS = 14 -- studs, horizontal
local NEAR_SPOT_HEIGHT = 24 -- studs of vertical slack (the root stands ~3 studs above the yard)
local NO_SPOT_GRACE = 10 -- seconds without a spot before a NearSpot step is passed
local NO_FREE_GRACE = 60 -- seconds without any free plot before a Claimed step is passed
local SKIPPED_STEP = 1000 -- Tutorial.Step of a skipped tutorial (DataService caps Step at 1000): no later chapter
-- Not in Config (lead-owned): the home chapter's reward, paid once when the "feed" step completes.
local HOME_FINISH_CASH = 1000
local STATION_FRONT_GAP = 2.5 -- studs in front of a station's footprint where its guide arrow stands
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
	-- Phase 2 (the home chapter)
	Claimed = true,
	Built = true,
	Collected = true,
	Fed = true,
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
local TycoonService = nil
local PetCareService = nil
local HomeBuilder = nil -- read-only lookups of pads / stations (GetPad / GetStation)
local TycoonCatalog = nil
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
local tracks = {} -- [player] = track (see newTrack)
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

local function commas(n)
	return Util.Commas(math.floor(tonumber(n) or 0))
end

local function money(n)
	return "$" .. commas(n)
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
				local t = raw.Target
				target = {
					Kind = t.Kind,
					Id = t.Id,
					Label = t.Label,
					Gate = t.Gate == true,
					Pad = type(t.Pad) == "string" and t.Pad or nil,
					Station = type(t.Station) == "string" and t.Station or nil,
					Path = t.Path == true,
					Food = t.Food == true,
				}
			end
			local chapter = tonumber(raw.Chapter) or 1
			table.insert(steps, {
				Id = raw.Id,
				Chapter = math.max(1, math.floor(chapter)),
				ChapterEnd = raw.ChapterEnd == true,
				Title = type(raw.Title) == "string" and raw.Title or "",
				Text = type(raw.Text) == "string" and raw.Text or "",
				Target = target,
				CompleteOn = completeOn,
				Station = type(raw.Station) == "string" and raw.Station or nil,
				Gift = raw.Gift == true,
				Hint = type(raw.Hint) == "string" and raw.Hint or nil,
				Button = type(raw.Button) == "string" and raw.Button or nil,
			})
		end
	end
end

local function chapterOf(index)
	local step = steps[index]
	return step and step.Chapter or 1
end

-- true when a stored "Done" tutorial whose Step is `index` still has something to show (a later chapter)
local function resumable(index)
	return type(index) == "number" and index >= 1 and index <= #steps and chapterOf(index) > 1
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

-- the saved home (a copy) or nil
local function getHome(player)
	if not hasFunction(DataService, "GetHome") then
		return nil
	end
	local ok, home = pcall(DataService.GetHome, player)
	if ok and type(home) == "table" then
		return home
	end
	return nil
end

local function getCash(player)
	if hasFunction(DataService, "GetCash") then
		local ok, cash = pcall(DataService.GetCash, player)
		if ok and type(cash) == "number" then
			return cash
		end
	end
	local attr = Config.Attr.Cash and player:GetAttribute(Config.Attr.Cash)
	if type(attr) == "number" then
		return attr
	end
	return 0
end

local function stationLevel(home, id)
	local stations = type(home) == "table" and home.Stations
	local level = type(stations) == "table" and stations[id]
	if type(level) == "number" and level == level then
		return level
	end
	return 0
end

local function collectorCash(home)
	local cash = type(home) == "table" and tonumber(home.CollectorCash) or 0
	if cash ~= cash then
		return 0
	end
	return cash
end

local function foodTotal(player)
	if not hasFunction(DataService, "GetFood") then
		return 0
	end
	local ok, food = pcall(DataService.GetFood, player)
	local total = 0
	if ok and type(food) == "table" then
		for _, n in pairs(food) do
			if type(n) == "number" and n > 0 then
				total = total + n
			end
		end
	end
	return total
end

local function stationDef(id)
	if not TycoonCatalog or type(id) ~= "string" then
		return nil
	end
	local ok, def = pcall(TycoonCatalog.Get, id)
	if ok and type(def) == "table" then
		return def
	end
	return nil
end

----------------------------------------------------------------------
-- Guide targets
----------------------------------------------------------------------

-- World position of a Phase 1 step target (nil when unknown); the client also finds the models by name.
local function lobbyPosition(player, target)
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

local function spotIndexOf(info)
	if type(info) ~= "table" then
		return nil
	end
	if type(info.Index) == "number" then
		return info.Index
	end
	local folder = info.Folder
	if typeof(folder) == "Instance" then
		local index = folder:GetAttribute("SpotIndex")
		if type(index) == "number" then
			return index
		end
	end
	return nil
end

local function spotByIndex(index)
	if type(index) ~= "number" then
		return nil
	end
	if hasFunction(SpotService, "GetSpotByIndex") then
		local ok, info = pcall(SpotService.GetSpotByIndex, index)
		if ok and type(info) == "table" then
			return info
		end
	end
	local spots = lobby and lobby.Spots
	if type(spots) == "table" and type(spots[index]) == "table" then
		return spots[index]
	end
	return nil
end

local function ownerOf(index)
	if hasFunction(SpotService, "GetOwner") then
		local ok, owner = pcall(SpotService.GetOwner, index)
		if ok then
			return owner
		end
	end
	return nil
end

local function gatePosition(info)
	if hasFunction(SpotService, "GateCFrame") then
		local ok, cf = pcall(SpotService.GateCFrame, info)
		if ok and typeof(cf) == "CFrame" then
			return cf.Position
		end
	end
	if typeof(info.GateCFrame) == "CFrame" then
		return info.GateCFrame.Position
	end
	if typeof(info.Center) == "Vector3" then
		return info.Center
	end
	return nil
end

-- The gate of the plot to claim: { Kind, Position, SpotIndex, Label } or nil. The suggestion is pinned on the track
-- while that plot stays free (the nearest free plot changes as the player walks).
local function gateTarget(player, track)
	local own = getSpot(player)
	if own then
		local position = typeof(own.Center) == "Vector3" and own.Center or gatePosition(own)
		return { Kind = "Spot", SpotIndex = spotIndexOf(own), Position = position, Label = "Your Home" }
	end
	local info = nil
	if track.GateIndex and ownerOf(track.GateIndex) == nil then
		info = spotByIndex(track.GateIndex)
	end
	if not info and hasFunction(SpotService, "SuggestSpot") then
		local ok, suggestion = pcall(SpotService.SuggestSpot, player)
		if ok and type(suggestion) == "table" then
			info = suggestion
		end
	end
	if not info then
		track.GateIndex = nil
		return nil
	end
	track.GateIndex = spotIndexOf(info)
	local position = gatePosition(info)
	if not position then
		return nil
	end
	return { Kind = "Spot", SpotIndex = track.GateIndex, Position = position, Label = "Free home" }
end

-- A model's pivot position, or nil.
local function pivotOf(model)
	if typeof(model) ~= "Instance" then
		return nil
	end
	local ok, cf = pcall(function()
		if model:IsA("Model") then
			return model:GetPivot()
		elseif model:IsA("BasePart") then
			return model.CFrame
		end
		return nil
	end)
	if ok and typeof(cf) == "CFrame" then
		return cf.Position
	end
	return nil
end

local function homeBuilderCall(fnName, spot, id)
	if not hasFunction(HomeBuilder, fnName) then
		return nil
	end
	local ok, result = pcall(HomeBuilder[fnName], spot, id)
	if ok and typeof(result) == "Instance" then
		return result
	end
	return nil
end

-- the buy pad of `id` on the claimed plot (HomeBuilder's model, else the catalog slot)
local function padPosition(spot, id)
	local at = pivotOf(homeBuilderCall("GetPad", spot, id))
	if at then
		return at
	end
	local def = stationDef(id)
	if def and type(def.Slot) == "table" and typeof(def.Slot.Pad) == "CFrame" and typeof(spot.PlotCFrame) == "CFrame" then
		return (spot.PlotCFrame * def.Slot.Pad).Position
	end
	return nil
end

-- where a built station's arrow stands: the Collector's CollectPad, else just in front of the station's footprint
local function stationPosition(spot, id)
	local model = homeBuilderCall("GetStation", spot, id)
	if model then
		local pad = model:FindFirstChild("CollectPad", true)
		if pad and pad:IsA("BasePart") then
			return pad.Position
		end
	end
	local def = stationDef(id)
	if def and type(def.Slot) == "table" and typeof(def.Slot.CFrame) == "CFrame" and typeof(spot.PlotCFrame) == "CFrame" then
		local depth = typeof(def.Slot.Footprint) == "Vector3" and def.Slot.Footprint.Z or 8
		return (spot.PlotCFrame * def.Slot.CFrame * CFrame.new(0, 0, -(depth / 2 + STATION_FRONT_GAP))).Position
	end
	return pivotOf(model)
end

local function padsById(home)
	local byId = {}
	if not TycoonCatalog or not hasFunction(TycoonCatalog, "AvailablePads") then
		return byId
	end
	local ok, pads = pcall(TycoonCatalog.AvailablePads, home)
	if ok and type(pads) == "table" then
		for _, pad in ipairs(pads) do
			if type(pad) == "table" and type(pad.StationId) == "string" then
				byId[pad.StationId] = pad
			end
		end
	end
	return byId
end

-- The pad to buy next on the way to station `goal`: its own pad when it can be bought, else (depth first, in
-- catalog order) a prerequisite's. nil when nothing on the way can be bought right now.
local function padToward(home, byId, goal, depth, seen)
	if depth > 8 or seen[goal] then
		return nil
	end
	seen[goal] = true
	local pad = byId[goal]
	if pad and not pad.Locked then
		return pad
	end
	local def = stationDef(goal)
	if not def or type(def.Requires) ~= "table" then
		return nil
	end
	local keys = {}
	for key in pairs(def.Requires) do
		if stationDef(key) and key ~= "Prestige" then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys, function(a, b)
		local da, db = stationDef(a), stationDef(b)
		return (da.Order or 0) < (db.Order or 0)
	end)
	for _, key in ipairs(keys) do
		if stationLevel(home, key) < (tonumber(def.Requires[key]) or 0) then
			local found = padToward(home, byId, key, depth + 1, seen)
			if found then
				return found
			end
		end
	end
	return nil
end

local function cheapestPad(byId)
	local best = nil
	for _, pad in pairs(byId) do
		if not pad.Locked and not pad.Prestige and type(pad.Price) == "number" then
			if not best or pad.Price < best.Price or (pad.Price == best.Price and pad.StationId < best.StationId) then
				best = pad
			end
		end
	end
	return best
end

local function padText(pad)
	local def = stationDef(pad.StationId)
	local name = (def and def.Name) or pad.Name or pad.StationId
	local price = tonumber(pad.Price) or 0
	local cost = price > 0 and (" for " .. money(price)) or " (free)"
	if (tonumber(pad.Level) or 0) > 0 then
		return name .. " Lv " .. tostring(pad.NextLevel) .. cost
	end
	return name .. cost
end

-- target, hint for a home step (Kind "Spot" targets with a Pad / Station / Gate / Food field)
local function homeTarget(player, track, step)
	local t = step.Target
	if t.Gate then
		local target = gateTarget(player, track)
		if target then
			track.NoFree = false
			if target.Label == "Your Home" then
				return target, "Your home is claimed!"
			end
			return target, step.Hint
		end
		track.NoFree = true
		return nil, "Every home is taken: wait for a free gate"
	end
	local spot = getSpot(player)
	if not spot then
		-- every other home step happens on the player's own plot: claim one first
		return gateTarget(player, track), "Claim a home first: press E at a free gate"
	end
	local home = getHome(player) or {}
	local index = spotIndexOf(spot)
	if t.Food then
		local kitchen = t.Station or "Kitchen"
		if foodTotal(player) > 0 then
			return { Kind = "Menu", Id = "Pets", Label = "Pets" }, "Open Pets and press Feed"
		end
		if stationLevel(home, kitchen) >= 1 then
			return { Kind = "Spot", SpotIndex = index, Position = stationPosition(spot, kitchen), Label = t.Label or "Kitchen" },
				"Cook a Snack at the Kitchen (press E)"
		end
		local byId = padsById(home)
		local pad = padToward(home, byId, kitchen, 0, {}) or cheapestPad(byId)
		if pad then
			return { Kind = "Spot", SpotIndex = index, Position = padPosition(spot, pad.StationId), Label = padText(pad) },
				"Build the Kitchen first"
		end
		return nil, step.Hint
	end
	local stationId = t.Station
	if stationId and stationLevel(home, stationId) >= 1 then
		local label = t.Label or stationId
		local hint = step.Hint
		if step.CompleteOn == "Collected" then
			hint = "Step on the Collector to bank your Cash"
		end
		return { Kind = "Spot", SpotIndex = index, Position = stationPosition(spot, stationId), Label = label }, hint
	end
	local goal = t.Pad
	if not goal then
		return nil, step.Hint
	end
	local byId = padsById(home)
	local pad = byId[goal]
	if t.Path then
		local next = padToward(home, byId, goal, 0, {})
		if not next and not (pad and not pad.Locked) then
			next = cheapestPad(byId)
		end
		if next and next.StationId ~= goal then
			return { Kind = "Spot", SpotIndex = index, Position = padPosition(spot, next.StationId), Label = "Next: " .. padText(next) },
				"Next: " .. padText(next)
		end
	end
	local hint = step.Hint
	if step.CompleteOn == "Collected" then
		hint = "Build the free Collector pad"
	elseif pad and not pad.Locked and t.Path then
		hint = "Build " .. padText(pad)
	elseif pad and pad.Locked then
		hint = tostring(pad.Locked)
	end
	return { Kind = "Spot", SpotIndex = index, Position = padPosition(spot, goal), Label = t.Label or goal }, hint
end

-- The target (sent to the client) and the hint of the current step.
local function resolveStep(player, track, step)
	local target = step.Target
	if not target then
		return nil, step.Hint
	end
	if target.Kind == "Spot" and (target.Gate or target.Pad or target.Station or target.Food) then
		local ok, out, hint = pcall(homeTarget, player, track, step)
		if not ok then
			return nil, step.Hint
		end
		if out and out.Kind == "Spot" and typeof(out.Position) ~= "Vector3" then
			out.Position = nil
		end
		return out, hint
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
	local ok, position = pcall(lobbyPosition, player, out)
	if ok and typeof(position) == "Vector3" then
		out.Position = position
	end
	return out, step.Hint
end

local function targetSignature(target, hint)
	if not target then
		return "none|" .. tostring(hint)
	end
	local p = typeof(target.Position) == "Vector3" and target.Position or nil
	return table.concat({
		tostring(target.Kind),
		tostring(target.Id),
		tostring(target.SpotIndex),
		tostring(target.Label),
		p and string.format("%.0f,%.0f,%.0f", p.X, p.Y, p.Z) or "-",
		tostring(hint),
	}, "|")
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
	local target, hint = nil, step.Hint
	if not track.Done then
		target, hint = resolveStep(player, track, step)
		track.TargetSig = targetSignature(target, hint)
	end
	return {
		Step = index,
		Total = total,
		Id = step.Id,
		Title = step.Title,
		Text = formatText(step.Text),
		Target = target,
		CompleteOn = step.CompleteOn,
		Hint = hint,
		Button = step.Button,
		Gift = step.Gift,
		Chapter = step.Chapter,
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
		Done = track.Done == true or track.BaseDone == true,
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

local function addCash(player, amount)
	if amount <= 0 or not hasFunction(DataService, "AddCash") then
		return false
	end
	local ok, result = pcall(DataService.AddCash, player, amount)
	if not ok then
		warn("[TutorialService] AddCash failed: " .. tostring(result))
		return false
	end
	return result ~= false
end

-- Pays the reward of a finished chapter (the progress is already stored). Returns the tokens paid (for the payload).
local function payChapter(player, track, chapter)
	if track.Replay then
		return 0
	end
	if chapter <= 1 then
		local amount = finishTokens()
		if amount > 0 and addTokens(player, amount) then
			notify(player, "Basics complete! +" .. amount .. " " .. TOKEN_GLYPH .. " from Nimbus", "good", 6)
			return amount
		end
		return 0
	end
	if HOME_FINISH_CASH > 0 and addCash(player, HOME_FINISH_CASH) then
		notify(player, "Home tutorial complete! +" .. money(HOME_FINISH_CASH) .. " Cash from Nimbus", "good", 6)
	end
	return 0
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
	track.NoFreeTime = 0
	track.Collected = false
	track.CashSeen = getCash(player)
	track.CollectorSeen = collectorCash(getHome(player))
	track.TargetSig = nil
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
	local chapter = chapterOf(math.min(track.Step, #steps))
	track.Done = true
	track.BaseDone = true
	if skipped then
		track.Skipped = true
		track.Step = SKIPPED_STEP -- no later chapter either
	else
		track.Completed = true
		track.Step = #steps + 1 -- one past the end: a chapter appended later starts from here
	end
	local stored = persist(player, track)
	if not skipped and stored then
		track.Reward = payChapter(player, track, chapter)
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
	local chapterDone = step.ChapterEnd == true or chapterOf(index + 1) ~= step.Chapter
	track.Step = index + 1
	if chapterDone then
		track.BaseDone = true -- the stored Done flips with the first chapter and sticks
	end
	local stored = enterStep(player, track)
	if not stored then
		stored = persist(player, track)
	end
	if chapterDone and step.ChapterEnd == true and stored then
		payChapter(player, track, step.Chapter)
	end
	sendState(player, track)
end

local function homeReady()
	return TycoonService ~= nil and TycoonCatalog ~= nil and hasFunction(DataService, "GetHome")
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
	elseif kind == "Claimed" then
		return TycoonService == nil or not hasFunction(SpotService, "GetSpot") or (track.NoFreeTime or 0) >= NO_FREE_GRACE
	elseif kind == "Built" then
		return not homeReady() or stationDef(step.Station) == nil
	elseif kind == "Collected" then
		return not homeReady() or not hasFunction(DataService, "GetCash")
	elseif kind == "Fed" then
		return not hasSignal(PetCareService, "Fed")
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
	elseif kind == "Claimed" then
		return getSpot(player) ~= nil
	elseif kind == "Built" then
		return step.Station ~= nil and stationLevel(getHome(player), step.Station) >= 1
	elseif kind == "Collected" then
		return track.Collected == true
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

-- "Collected": the Collector emptied into the balance since the last look (Cash up AND Home.CollectorCash down).
local function checkCollected(player)
	local track = tracks[player]
	local step = currentStep(track)
	if not step or step.CompleteOn ~= "Collected" then
		return
	end
	local cash = getCash(player)
	local collector = collectorCash(getHome(player))
	if cash > (track.CashSeen or math.huge) and collector < (track.CollectorSeen or -math.huge) then
		track.Collected = true
	end
	track.CashSeen = cash
	track.CollectorSeen = collector
	if track.Collected then
		settle(player, track)
	end
end

-- Re-sends the state when a home step's target or hint changed (a pad got built, food arrived, a plot was taken).
local function refreshTarget(player, track)
	local step = currentStep(track)
	local t = step and step.Target
	if not t or not (t.Gate or t.Pad or t.Station or t.Food) then
		return
	end
	local ok, target, hint = pcall(resolveStep, player, track, step)
	if not ok then
		return
	end
	if targetSignature(target, hint) ~= track.TargetSig then
		sendState(player, track)
	end
end

----------------------------------------------------------------------
-- Players
----------------------------------------------------------------------

local function newTrack(stored)
	local step = math.max(1, math.floor(tonumber(stored.Step) or 1))
	local track = {
		Step = step,
		Done = false,
		BaseDone = stored.Done == true,
		Gifted = stored.Gifted == true,
		Completed = false,
		Skipped = false,
		Reward = 0,
		NoSpotTime = 0,
		NoFreeTime = 0,
	}
	if not track.BaseDone then
		if track.Step > #steps then
			track.Step = #steps -- steps were removed since: land on the last one
		end
	elseif not resumable(track.Step) then
		track.Done = true -- finished (or skipped): nothing left to show
	end
	return track
end

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
	local track = newTrack(stored)
	tracks[player] = track
	if not track.Done then
		enterStep(player, track)
	end
	sendState(player, track)
	settle(player, track)
	return true
end

-- Drops the running tutorial and reads it again from the profile (used by the developer tools after they rewind
-- the stored tutorial). opts.Replay = true marks a replay of a tutorial that was already finished once: its chapter
-- rewards are not paid again. Returns true when the player's tutorial is running again.
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

-- The stored profile changed under us (recovered load / another server): merge forward, never back.
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
	local fresh = newTrack(stored)
	local changed = false
	if fresh.Gifted and not track.Gifted then
		track.Gifted = true
	end
	if fresh.BaseDone and not track.BaseDone then
		track.BaseDone = true
	end
	if not track.Done then
		if fresh.Done then
			-- finished or skipped elsewhere: it ends here too
			track.Done = true
			track.Step = fresh.Step
			changed = true
		elseif fresh.Step > track.Step then
			track.Step = math.min(fresh.Step, #steps)
			enterStep(player, track)
			changed = true
		end
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
	-- a claimed plot: complete "Claimed" at once and point the home steps at the new plot
	table.insert(conns, player:GetAttributeChangedSignal(Config.Attr.SpotIndex):Connect(function()
		local track = tracks[player]
		local step = currentStep(track)
		if step then
			track.NoSpotTime = 0
			settle(player, track)
			track = tracks[player]
			if track and currentStep(track) then
				refreshTarget(player, track)
			end
		end
	end))
	if Config.Attr.Cash then
		table.insert(conns, player:GetAttributeChangedSignal(Config.Attr.Cash):Connect(function()
			checkCollected(player)
		end))
	end
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
-- Poll loop (2 Hz): level checks, grace timers, home targets, profiles that loaded without a signal
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
	elseif step.CompleteOn == "Claimed" then
		if track.NoFree and not getSpot(player) and not inMatch(player) then
			track.NoFreeTime = (track.NoFreeTime or 0) + dt
		else
			track.NoFreeTime = 0
		end
	elseif step.CompleteOn == "Collected" then
		checkCollected(player)
		track = tracks[player]
		if not currentStep(track) then
			return
		end
	end
	settle(player, track)
	track = tracks[player]
	if track and currentStep(track) and not inMatch(player) then
		refreshTarget(player, track)
	end
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

-- settles the current step of `player` (a signal said something changed)
local function nudge(player)
	local track = typeof(player) == "Instance" and tracks[player] or nil
	if track and not track.Done then
		settle(player, track)
		track = tracks[player]
		if track and currentStep(track) then
			refreshTarget(player, track)
		end
	end
end

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
	-- Phase 2 (Main initialises these after this service: only their signals are used before then)
	TycoonService = deps.TycoonService or loadModule(services, "TycoonService")
	PetCareService = deps.PetCareService or loadModule(services, "PetCareService")
	HomeBuilder = loadModule(services, "HomeBuilder")
	TycoonCatalog = loadModule(Shared, "TycoonCatalog")

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

	-- the home chapter
	if hasSignal(TycoonService, "Claimed") then
		TycoonService.Claimed:Connect(function(player)
			nudge(player)
		end)
	end
	if hasSignal(TycoonService, "HomeChanged") then
		TycoonService.HomeChanged:Connect(function(player)
			nudge(player)
		end)
	end
	if hasSignal(TycoonService, "Released") then
		TycoonService.Released:Connect(function(player)
			nudge(player)
		end)
	end
	if hasSignal(PetCareService, "Fed") then
		PetCareService.Fed:Connect(function(player)
			local track = typeof(player) == "Instance" and tracks[player] or nil
			local step = currentStep(track)
			if step and step.CompleteOn == "Fed" then
				advance(player, track)
				settle(player, track)
			end
		end)
	end
	if hasSignal(PetCareService, "Cooked") then
		PetCareService.Cooked:Connect(function(player)
			nudge(player) -- food arrived: the feed step now points at the Pets button
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
