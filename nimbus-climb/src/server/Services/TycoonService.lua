-- TycoonService: the tycoon homes (ARCHITECTURE_V3.md "Phase 2: Tycoon homes" + "Phase 2 build contract").
--
-- * Claiming: every free plot's gate carries a "Claim Home" ProximityPrompt named ClaimPrompt (HomeBuilder.PreparePlot
--   builds it; when HomeBuilder is missing or built none, this service puts a plain one on the gate). Pressing E
--   claims that plot for the session: one plot per player, refused during a match and while the save is still
--   loading. SpotService keeps the plot <-> player map (GetSpot answers the claimed plot). The SAVED progress is the
--   player's Home build (profile Home), not a plot number: it is rebuilt on whichever plot they claim. Leaving
--   releases the plot (the build is cleared, the gate reads "Claim Home" again). A claim also re-derives
--   Home.Level from the stations (TycoonCatalog.HomeLevelOf) when an older save disagrees. The gate's prompt must be
--   triggered from near the gate (its range + a little slack).
-- * Buy pads: HomeBuilder.SetPads shows TycoonCatalog.AvailablePads(home) as pads `Pad_<StationId>` with a
--   ProximityPrompt `BuyPrompt` (attributes StationId, OwnerUserId). A purchase (pad or the Home window's "Upgrade")
--   is validated here: the player owns that plot, the station is in AvailablePads and not locked
--   (TycoonCatalog.CheckPurchase), the price is paid with DataService.SpendCash and the level written with
--   DataService.MutateHome IN ONE NON-YIELDING STEP (the cash is refunded if the home write is refused). The station
--   then appears (HomeBuilder.SetStation; the client pops it in), the pads refresh and a side toast confirms it.
--   The Prestige pad (StationId "Prestige") routes to Prestige().
-- * Income: a 1 s server tick adds (presses + Economy pets in the Garden) x the prestige multiplier
--   (TycoonCatalog.IncomePerSecond) into Home.CollectorCash, capped by TycoonCatalog.CollectorCap (Collector +
--   Vault). Garden pets count only when their key is owned (as many copies as are placed) and they are Economy pets.
--   The Collector banks it with AddCash: its prompt (a ProximityPrompt named CollectPrompt, or any non-Buy prompt
--   inside the Station_Collector model; added here when HomeBuilder made none), a part named CollectPad inside the
--   Collector (step on it), or HomeAction "Collect".
-- * Offline earnings: when the profile loads, the Vault pays TycoonCatalog.OfflineEarnings for the time since
--   Home.LastSeen with AddCash and a "While you were away" side toast. LastSeen is written in the same step as the
--   payout (no double pay), then refreshed every 15 s while the player is online, with every purchase / prestige /
--   garden change (income rises from there) and on shutdown.
-- * House tiers (every 10 Home Levels: Villa 10, Manor 20, Sky Castle 30) and the station caps per tier come from
--   TycoonCatalog (lock reasons on the pads). Prestige (Home Level 40 + Sky Castle): stations reset except the decor
--   (KeepOnPrestige), Cash and the Collector reset, pets / food / garden choices are kept, +1 star (x1.25 income
--   each), a Gems reward (TycoonCatalog.PrestigeGems); at 1 star the Fusion Machine pad unlocks.
-- * GardenSet: Economy pets only; the key must be owned (one copy per slot) and not training in the Gym; the slot
--   must be unlocked by the Garden level; nil / "" clears the slot (any slot, also one a prestige locked again).
-- * Remote HomeAction(action, arg): "Upgrade" stationId, "GardenSet" {slot, key|nil} (also {Slot =, Key =}),
--   "Collect", "Prestige", "GoHome". Types, ranges and NaN are checked; every action is rate limited (a per-action
--   cooldown plus a per-player burst budget); refusals answer with a side toast (repeated texts are throttled).
-- * Replication: the plot folder (SpotInfo.Folder) carries attributes for the clients: HomeLevel, Prestige,
--   CollectorCash, CollectorCap, IncomePerSecond and GardenPets ("1=cat;3=fox@Golden"), written only when they
--   change. Nothing here moves parts every frame (HomeFx animates on the client).
--
-- Public API (the contract):
--   Init(lobbyInfo, deps)                deps = { DataService, PetService, SpotService }
--   GetPlot(player) -> SpotInfo | nil    GetHome(player) -> home copy | nil
--   Buy(player, stationId) -> ok, newLevel | reason
--   Collect(player) -> ok, amount | reason
--   Prestige(player) -> ok, stars | reason
--   IncomePerSecond(player) -> cash/s, { Press, Garden, Multiplier }
--   Signals HomeChanged(player), Claimed(player, spotInfo), Prestiged(player, stars)
-- Extras: Claim(player, index) -> ok, reason, Release(player), GardenSet(player, slot, key) -> ok, reason,
--   CollectorCap(player) -> cash, GoHome(player) -> moved, signal Released(player, spotInfo).
--
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local TycoonService = {}
TycoonService.HomeChanged = Util.Signal() -- Fire(player)
TycoonService.Claimed = Util.Signal() -- Fire(player, spotInfo)
TycoonService.Prestiged = Util.Signal() -- Fire(player, stars)
TycoonService.Released = Util.Signal() -- Fire(player, spotInfo)  (extra)

local TICK = 1 -- seconds between income ticks
local MAX_TICK_DT = 5 -- a stalled server never pays more than this many seconds in one tick
local LASTSEEN_EVERY = 15 -- seconds between Home.LastSeen refreshes while online (offline pay starts after 120 s)
local PROFILE_WAIT = 90 -- seconds a joining player's home is waited for (then ProfileRebased takes over)
local CLAIM_COOLDOWN = 0.5
local BUY_COOLDOWN = 0.2
local COLLECT_COOLDOWN = 0.5
local GARDEN_COOLDOWN = 0.2
local PRESTIGE_COOLDOWN = 1
local GOHOME_COOLDOWN = 0.5
local TOUCH_COOLDOWN = 1
local COLLECT_TOAST_GAP = 3 -- seconds between "banked" toasts while standing on the Collector pad
local BURST_SIZE = 10 -- HomeAction / prompt requests a player may send at once...
local BURST_REFILL = 5 -- ...refilled at this many per second
local TOAST_GAP = 1.5 -- the same refusal text is not repeated within this many seconds
local OFFLINE_TOAST_DELAY = 3 -- the HUD / toasts are up a moment after the profile loaded
local MAX_ID_LENGTH = 48
local MAX_ACTION_LENGTH = 24
local MAX_SLOT = 64
local GATE_PROMPT_LIFT = 3.5 -- the fallback ClaimPrompt anchor above the gate's ground point
local CLAIM_DISTANCE = 12
local CLAIM_SLACK = 15 -- studs past the prompt's MaxActivationDistance a claimer may stand (latency, big avatars)

local initialized = false
local running = false
local dataService = nil
local petService = nil
local spotService = nil
local homeBuilder = nil
local catalog = nil -- TycoonCatalog
local petKeys = nil -- PetKeys (optional)
local petCatalog = nil -- PetCatalog (optional)
local notifyRemote = nil
local spotList = {} -- [index] = SpotInfo (from lobbyInfo.Spots)

local plots = {} -- [Player] = index
local plotOwner = {} -- [index] = Player (this service's own view; survives SpotService's release order)
local built = {} -- [index] = { [stationId] = level } what HomeBuilder shows right now
local padSig = {} -- [index] = signature of the last SetPads
local shown = {} -- [index] = { Cash, Cap, Income, Level, Prestige, Garden } last replicated values
local fallbackPrompts = {} -- [index] = ClaimPrompt this service created (no HomeBuilder prompt)
local collectHooks = {} -- [index] = { [Instance] = true } collector prompts / pads already prepared
local lastTick = {} -- [Player] = os.clock() of the last income tick
local lastSeenAt = {} -- [Player] = os.clock() of the last LastSeen write
local offlineDone = {} -- [Player] = true once the offline earnings were settled for this session
local watching = {} -- [Player] = true while a join waiter runs
local cooldowns = {} -- [Player] = { [key] = os.clock() }
local budgets = {} -- [Player] = { Tokens, At }
local toastAt = {} -- [Player] = { [text] = os.clock() }
local departed = setmetatable({}, { __mode = "k" })
local hbWarned = {} -- [fnName] = count of warnings printed

----------------------------------------------------------------------
-- Modules (other agents write some of them: every use is guarded)
----------------------------------------------------------------------

local function requireModule(container, name)
	local module = container and container:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[TycoonService] could not load " .. name .. ": " .. tostring(result))
	return nil
end

-- Calls HomeBuilder[fnName](...) under pcall. Missing functions are skipped quietly.
local function hb(fnName, ...)
	if not homeBuilder or type(homeBuilder[fnName]) ~= "function" then
		return nil
	end
	local ok, result = pcall(homeBuilder[fnName], ...)
	if not ok then
		local n = (hbWarned[fnName] or 0) + 1
		hbWarned[fnName] = n
		if n <= 3 then
			warn("[TycoonService] HomeBuilder." .. fnName .. " failed: " .. tostring(result))
		end
		return nil
	end
	return result
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function isFinite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function notify(player, text, kind, seconds)
	if not player or not player.Parent or type(text) ~= "string" then
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

-- A refusal toast; the same text is not repeated within TOAST_GAP (spam clicks stay quiet).
local function toastOnce(player, text, kind)
	if type(text) ~= "string" or text == "" then
		return
	end
	local map = toastAt[player]
	if not map then
		map = {}
		toastAt[player] = map
	end
	local now = os.clock()
	local last = map[text]
	if last and now - last < TOAST_GAP then
		return
	end
	map[text] = now
	notify(player, text, kind or "bad", 3)
end

-- Per player per key cooldown.
local function cooldown(player, key, seconds)
	local map = cooldowns[player]
	if not map then
		map = {}
		cooldowns[player] = map
	end
	local now = os.clock()
	local last = map[key]
	if last and now - last < seconds then
		return false
	end
	map[key] = now
	return true
end

-- Per player burst budget shared by every HomeAction / prompt request.
local function spend(player)
	local now = os.clock()
	local b = budgets[player]
	if not b then
		b = { Tokens = BURST_SIZE, At = now }
		budgets[player] = b
	end
	b.Tokens = math.min(BURST_SIZE, b.Tokens + (now - b.At) * BURST_REFILL)
	b.At = now
	if b.Tokens < 1 then
		return false
	end
	b.Tokens = b.Tokens - 1
	return true
end

local function money(n)
	if catalog and type(catalog.FormatCash) == "function" then
		local ok, text = pcall(catalog.FormatCash, n)
		if ok and type(text) == "string" then
			return text
		end
	end
	return "$" .. tostring(math.floor(tonumber(n) or 0))
end

local function durationText(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if hours > 0 then
		if minutes > 0 then
			return hours .. "h " .. minutes .. "m"
		end
		return hours .. "h"
	end
	return math.max(1, minutes) .. " min"
end

-- 1.25 -> "1.25", 1.5625 -> "1.56", 2 -> "2"
local function multiplierText(mult)
	local text = string.format("%.2f", tonumber(mult) or 1)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text
end

local function isPlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent ~= nil and not departed[player]
end

local function getHome(player)
	if not dataService or type(dataService.GetHome) ~= "function" then
		return nil
	end
	local ok, home = pcall(dataService.GetHome, player)
	if ok and type(home) == "table" then
		return home
	end
	return nil
end

local function getProfile(player)
	if not dataService or type(dataService.GetProfile) ~= "function" then
		return nil
	end
	local ok, profile = pcall(dataService.GetProfile, player)
	if ok and type(profile) == "table" then
		return profile
	end
	return nil
end

local function mutateHome(player, fn)
	if not dataService or type(dataService.MutateHome) ~= "function" then
		return false
	end
	local ok, result = pcall(dataService.MutateHome, player, fn)
	return ok and result == true
end

local function getCash(player)
	if dataService and type(dataService.GetCash) == "function" then
		local ok, cash = pcall(dataService.GetCash, player)
		if ok and isFinite(cash) then
			return cash
		end
	end
	return 0
end

local function stationLevel(home, id)
	if catalog and type(catalog.StationLevel) == "function" then
		return catalog.StationLevel(home, id)
	end
	local v = type(home) == "table" and type(home.Stations) == "table" and home.Stations[id]
	return isFinite(v) and math.max(0, math.floor(v)) or 0
end

local function homeLevelOf(home)
	if catalog and type(catalog.HomeLevelOf) == "function" then
		return catalog.HomeLevelOf(home)
	end
	return 0
end

local function starsOf(home)
	local v = type(home) == "table" and home.Prestige
	if isFinite(v) and v > 0 then
		return math.floor(v)
	end
	return 0
end

local function stationName(id)
	local def = catalog and catalog.Get(id)
	return (def and def.Name) or tostring(id)
end

local function houseTierName(index)
	local tiers = catalog and catalog.HouseTiers
	local tier = type(tiers) == "table" and tiers[index]
	return (tier and tier.Name) or "house"
end

----------------------------------------------------------------------
-- Pets in the Garden
----------------------------------------------------------------------

local function validKeyString(key)
	return type(key) == "string" and key ~= "" and #key <= MAX_ID_LENGTH
end

-- def, tier of an Economy pet key; nil, nil, reason for junk keys, unknown pets and Combat pets.
local function economyDef(key, profile)
	if not validKeyString(key) then
		return nil, nil, "Unknown pet"
	end
	local def, tier = nil, "Normal"
	if petKeys and type(petKeys.Parse) == "function" then
		local parsed = petKeys.Parse(key)
		if not parsed then
			return nil, nil, "Unknown pet"
		end
		tier = parsed.Tier or "Normal"
		if type(petKeys.DefOf) == "function" then
			local ok, result = pcall(petKeys.DefOf, key, profile)
			if ok and type(result) == "table" then
				def = result
			end
		end
	elseif petCatalog and type(petCatalog.Get) == "function" then
		def = petCatalog.Get(key)
	end
	if type(def) ~= "table" then
		return nil, nil, "Unknown pet"
	end
	if def.Role ~= "Economy" then
		return nil, nil, "Only Economy pets can work in the Garden"
	end
	return def, tier, nil
end

local function ownedCount(profile, key)
	if not profile or not validKeyString(key) then
		return 0
	end
	if petKeys and type(petKeys.Count) == "function" then
		local ok, n = pcall(petKeys.Count, profile, key)
		if ok and isFinite(n) then
			return n
		end
		return 0
	end
	local n = type(profile.Pets) == "table" and profile.Pets[key]
	return isFinite(n) and n or 0
end

local function petLevel(player, key)
	if dataService and type(dataService.GetPetLevel) == "function" then
		local ok, level = pcall(dataService.GetPetLevel, player, key)
		if ok and isFinite(level) and level >= 1 then
			return math.floor(level)
		end
	end
	return 1
end

local function gardenSlots(home)
	if catalog and type(catalog.GardenSlots) == "function" then
		return catalog.GardenSlots(home)
	end
	return 0
end

-- The Garden entries that earn: unlocked slots only, owned keys (one copy per slot), Economy pets.
-- Returns { {Def, Level, Tier}... } (TycoonCatalog.PetIncome shapes) and { [slot] = key } of the valid ones.
local function gardenEntries(player, home, profile)
	local entries, valid = {}, {}
	local garden = type(home) == "table" and home.Garden
	if type(garden) ~= "table" then
		return entries, valid
	end
	local used = {}
	for slot = 1, math.min(gardenSlots(home), MAX_SLOT) do
		local key = garden[slot]
		if validKeyString(key) then
			local def, tier = economyDef(key, profile)
			if def then
				used[key] = (used[key] or 0) + 1
				if used[key] <= ownedCount(profile, key) then
					entries[#entries + 1] = { Def = def, Level = petLevel(player, key), Tier = tier }
					valid[slot] = key
				end
			end
		end
	end
	return entries, valid
end

-- income per second (prestige multiplier applied), parts, valid garden map
local function incomeOf(player, home)
	if not catalog or type(home) ~= "table" then
		return 0, { Press = 0, Garden = 0, Multiplier = 1 }, {}
	end
	local entries, valid = gardenEntries(player, home, getProfile(player))
	local ok, income, parts = pcall(catalog.IncomePerSecond, home, entries, starsOf(home))
	if not ok or not isFinite(income) or income < 0 then
		return 0, { Press = 0, Garden = 0, Multiplier = 1 }, valid
	end
	return income, parts, valid
end

-- The Collector cap. `valid` = the garden pets that really earn ({ [slot] = key }): only they may raise the cap
-- (TycoonCatalog.CollectorCap also counts the raw home.Garden keys at level 1).
local function capOf(home, income, valid)
	if not catalog then
		return 0
	end
	local garden = home.Garden
	home.Garden = valid or {}
	local ok, cap = pcall(catalog.CollectorCap, home, income)
	home.Garden = garden
	if ok and isFinite(cap) and cap >= 0 then
		return cap
	end
	return 0
end

----------------------------------------------------------------------
-- The plot in the world (HomeBuilder) + replicated attributes
----------------------------------------------------------------------

local function plotInfo(index)
	if spotService and type(spotService.GetSpotByIndex) == "function" then
		local info = spotService.GetSpotByIndex(index)
		if info then
			return info
		end
	end
	return spotList[index]
end

local function setFolderAttr(info, name, value)
	local folder = info and info.Folder
	if typeof(folder) ~= "Instance" then
		return
	end
	pcall(function()
		if folder:GetAttribute(name) ~= value then
			folder:SetAttribute(name, value)
		end
	end)
end

local function gardenText(valid)
	local slots = {}
	for slot in pairs(valid) do
		slots[#slots + 1] = slot
	end
	table.sort(slots)
	local parts = {}
	for _, slot in ipairs(slots) do
		parts[#parts + 1] = tostring(slot) .. "=" .. valid[slot]
	end
	return table.concat(parts, ";")
end

-- A ProximityPrompt to bank the Collector, when HomeBuilder's Collector has none.
local function onCollectorTouched(index, hit)
	local owner = plotOwner[index]
	local who = Util.PlayerFromPart(hit)
	if not owner or who ~= owner then
		return
	end
	if not cooldown(owner, "Touch", TOUCH_COOLDOWN) then
		return
	end
	TycoonService.Collect(owner, true)
end

local function prepareCollector(index, info)
	local folder = info and info.Folder
	if typeof(folder) ~= "Instance" then
		return
	end
	local hooks = collectHooks[index]
	if not hooks then
		hooks = setmetatable({}, { __mode = "k" }) -- also marks the plot as scanned (rescans follow station changes)
		collectHooks[index] = hooks
	end
	local station = nil
	for _, d in ipairs(folder:GetDescendants()) do
		if d.Name == "Station_Collector" and (d:IsA("Model") or d:IsA("BasePart") or d:IsA("Folder")) then
			station = d
			break
		end
	end
	if not station then
		return
	end
	local hasPrompt = false
	local firstPart = nil
	for _, d in ipairs(station:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name ~= "BuyPrompt" then
			hasPrompt = true
		elseif d:IsA("BasePart") then
			if not firstPart then
				firstPart = d
			end
			if (d.Name == "CollectPad" or d:GetAttribute("CollectPad") == true) and not hooks[d] then
				hooks[d] = true
				d.Touched:Connect(function(hit)
					onCollectorTouched(index, hit)
				end)
			end
		end
	end
	if station:IsA("BasePart") and not firstPart then
		firstPart = station
	end
	if not hasPrompt and station:IsA("Model") and station.PrimaryPart then
		firstPart = station.PrimaryPart
	end
	if not hasPrompt and firstPart and not hooks[station] then
		hooks[station] = true
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "CollectPrompt"
		prompt.ActionText = "Collect"
		prompt.ObjectText = "Collector"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt:SetAttribute("SpotIndex", index)
		prompt.Parent = firstPart
	end
end

-- Replicates the collector numbers (HomeBuilder.SetCollector + folder attributes) when they changed.
local function showCollector(index, cash, cap, income)
	local info = plotInfo(index)
	if not info then
		return
	end
	local s = shown[index]
	if not s then
		s = {}
		shown[index] = s
	end
	local whole = math.floor(math.max(0, cash or 0))
	local capWhole = math.floor(math.max(0, cap or 0))
	local rate = math.floor((income or 0) * 10 + 0.5) / 10
	if s.Cash ~= whole or s.Cap ~= capWhole then
		s.Cash, s.Cap = whole, capWhole
		hb("SetCollector", info, whole, capWhole)
		setFolderAttr(info, "CollectorCash", whole)
		setFolderAttr(info, "CollectorCap", capWhole)
	end
	if s.Income ~= rate then
		s.Income = rate
		setFolderAttr(info, "IncomePerSecond", rate)
	end
end

local function padSignature(pads)
	local parts = {}
	for i, pad in ipairs(pads) do
		parts[i] = tostring(pad.StationId) .. ":" .. tostring(pad.NextLevel) .. ":" .. tostring(pad.Price) .. ":" .. tostring(pad.Locked or "")
	end
	return table.concat(parts, "|")
end

-- Brings the plot in line with the home: stations (diff only), pads, collector, attributes, nameplate.
-- Returns true when a station changed.
local function syncPlot(player, home, income, valid)
	local index = plots[player]
	local info = index and plotInfo(index)
	if not info or type(home) ~= "table" or not catalog then
		return false
	end
	local map = built[index]
	if not map then
		map = {}
		built[index] = map
	end
	local changed = false
	for _, def in ipairs(catalog.Stations) do
		local id = def.Id
		local level = stationLevel(home, id)
		if (map[id] or 0) ~= level then
			map[id] = level
			hb("SetStation", info, id, level)
			changed = true
		end
	end
	if changed or not collectHooks[index] then
		prepareCollector(index, info)
	end
	local okPads, pads = pcall(catalog.AvailablePads, home)
	if okPads and type(pads) == "table" then
		local sig = padSignature(pads)
		if padSig[index] ~= sig then
			padSig[index] = sig
			hb("SetPads", info, pads)
		end
	end
	if income == nil then
		local parts
		income, parts, valid = incomeOf(player, home)
	end
	showCollector(index, home.CollectorCash, capOf(home, income, valid), income)
	local s = shown[index] or {}
	shown[index] = s
	local level, stars = homeLevelOf(home), starsOf(home)
	if s.Level ~= level or s.Prestige ~= stars then
		s.Level, s.Prestige = level, stars
		setFolderAttr(info, "HomeLevel", level)
		setFolderAttr(info, "Prestige", stars)
		if spotService and type(spotService.Refresh) == "function" then
			pcall(spotService.Refresh, player)
		end
	end
	local garden = gardenText(valid or {})
	if s.Garden ~= garden then
		s.Garden = garden
		setFolderAttr(info, "GardenPets", garden)
		hb("SetGarden", info, valid or {})
	end
	return changed
end

local function resetPlotState(index)
	built[index] = nil
	padSig[index] = nil
	shown[index] = nil
	collectHooks[index] = nil
end

local function clearPlotAttributes(info)
	for _, name in ipairs({ "HomeLevel", "Prestige", "CollectorCash", "CollectorCap", "IncomePerSecond", "GardenPets" }) do
		setFolderAttr(info, name, nil)
	end
end

----------------------------------------------------------------------
-- Gate prompts
----------------------------------------------------------------------

local function findPrompt(container, name)
	if typeof(container) ~= "Instance" then
		return nil
	end
	for _, d in ipairs(container:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == name then
			return d
		end
	end
	return nil
end

-- ClaimPrompts HomeBuilder built outside the spot folders, by their SpotIndex attribute (one scan at Init).
local function claimPromptsBySpot()
	local out = {}
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "ClaimPrompt" then
			local index = d:GetAttribute("SpotIndex")
			if type(index) == "number" then
				out[index] = d
			end
		end
	end
	return out
end

-- A plain ClaimPrompt on the gate when HomeBuilder did not build one (or is missing).
local function ensureClaimPrompt(index, info, existing)
	if findPrompt(info.Folder, "ClaimPrompt") or (existing and existing[index]) then
		return
	end
	local gate = nil
	if spotService and type(spotService.GateCFrame) == "function" then
		gate = spotService.GateCFrame(info)
	end
	if typeof(gate) ~= "CFrame" then
		gate = typeof(info.GateCFrame) == "CFrame" and info.GateCFrame or info.SpawnCFrame
	end
	if typeof(gate) ~= "CFrame" or typeof(info.Folder) ~= "Instance" then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Name = "ClaimAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = gate * CFrame.new(0, GATE_PROMPT_LIFT, 0)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ClaimPrompt"
	prompt.ActionText = "Claim Home"
	prompt.ObjectText = "Free home"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = CLAIM_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("SpotIndex", index)
	prompt.Parent = anchor
	anchor.Parent = info.Folder
	fallbackPrompts[index] = prompt
end

local function setFallbackPrompt(index, owner)
	local prompt = fallbackPrompts[index]
	if not prompt or not prompt.Parent then
		return
	end
	pcall(function()
		prompt.Enabled = owner == nil
		prompt.ObjectText = "Free home"
	end)
end

----------------------------------------------------------------------
-- Claim / release
----------------------------------------------------------------------

local function validIndex(index)
	return type(index) == "number" and index == index and index == math.floor(index) and plotInfo(index) ~= nil
end

function TycoonService.Claim(player, index)
	if not initialized or not spotService or type(spotService.Claim) ~= "function" then
		return false, "Homes are not ready yet"
	end
	if not isPlayer(player) then
		return false, "Not in the game"
	end
	if not validIndex(index) then
		return false, "Unknown home"
	end
	if plots[player] then
		if plots[player] == index then
			return false, "This is already your home"
		end
		return false, "You already have a home"
	end
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return false, "Finish your match first"
	end
	local home = getHome(player)
	if not home then
		return false, "Your home is still loading..."
	end
	local ok, reason = spotService.Claim(player, index)
	if not ok then
		return false, reason or "This home is taken"
	end
	local info = plotInfo(index)
	plots[player] = index
	plotOwner[index] = player
	lastTick[player] = os.clock()
	-- Home.Level always mirrors the stations (an old or hand-edited save may disagree)
	local level = homeLevelOf(home)
	if home.Level ~= level then
		mutateHome(player, function(live)
			live.Level = homeLevelOf(live)
			return true
		end)
	end

	-- a clean plot, then the saved build on top of it
	hb("ClearPlot", info)
	resetPlotState(index)
	hb("SetOwner", info, player)
	setFallbackPrompt(index, player)
	local income, _, valid = incomeOf(player, home)
	syncPlot(player, home, income, valid)

	TycoonService.Claimed:Fire(player, info)
	TycoonService.HomeChanged:Fire(player)
	if level > 0 then
		notify(player, "Welcome home! Rebuilt at Home Level " .. level .. ".", "good", 5)
	else
		notify(player, "Welcome home! Use the glowing pads to build.", "good", 6)
	end
	return true, nil
end

-- Clears this service's view of a plot and the build in the world (only while `player` still holds it).
local function dropPlot(player, index)
	if not index or plotOwner[index] ~= player then
		return nil
	end
	plotOwner[index] = nil
	if plots[player] == index then
		plots[player] = nil
	end
	local info = plotInfo(index)
	if info then
		hb("ClearPlot", info)
		hb("SetOwner", info, nil)
		clearPlotAttributes(info)
	end
	resetPlotState(index)
	setFallbackPrompt(index, nil)
	return info
end

function TycoonService.Release(player)
	if not player then
		return
	end
	local index = plots[player]
	plots[player] = nil
	local info = dropPlot(player, index)
	if spotService and type(spotService.Release) == "function" and spotService.GetSpot and spotService.GetSpot(player) then
		pcall(spotService.Release, player)
	end
	if info then
		TycoonService.Released:Fire(player, info)
	end
end

-- The prompt's world position (its part or attachment), or nil.
local function promptPosition(prompt)
	local parent = prompt.Parent
	if typeof(parent) ~= "Instance" then
		return nil
	end
	if parent:IsA("BasePart") then
		return parent.Position
	end
	if parent:IsA("Attachment") then
		return parent.WorldPosition
	end
	if parent:IsA("Model") then
		local ok, pivot = pcall(function()
			return parent:GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			return pivot.Position
		end
	end
	return nil
end

-- A claim needs the player AT the gate (the engine checks prompt range too; this also covers a stray trigger).
local function nearPrompt(player, prompt)
	local at = promptPosition(prompt)
	local root = Util.GetRoot(player)
	if not at or not root then
		return at == nil -- no position to compare: allow; no character: refuse
	end
	local reach = (tonumber(prompt.MaxActivationDistance) or CLAIM_DISTANCE) + CLAIM_SLACK
	return (root.Position - at).Magnitude <= reach
end

local function onClaimPrompt(player, index, prompt)
	if prompt and not nearPrompt(player, prompt) then
		return
	end
	if not cooldown(player, "Claim", CLAIM_COOLDOWN) or not spend(player) then
		return
	end
	local ok, reason = TycoonService.Claim(player, index)
	if not ok then
		toastOnce(player, reason or "You cannot claim this home", "bad")
	end
end

----------------------------------------------------------------------
-- Purchases
----------------------------------------------------------------------

local function milestoneToasts(player, before, after)
	local levelBefore, levelAfter = homeLevelOf(before), homeLevelOf(after)
	local houseBefore, houseAfter = stationLevel(before, "House"), stationLevel(after, "House")
	if houseAfter > houseBefore and houseAfter >= 2 then
		notify(player, houseTierName(houseAfter) .. " built! Stations can level higher.", "good", 5)
	end
	local tiers = catalog.HouseTiers or {}
	for i, tier in ipairs(tiers) do
		local need = tonumber(tier.HomeLevel) or 0
		if i >= 2 and need > 0 and levelBefore < need and levelAfter >= need and houseAfter < i then
			notify(player, "Home Level " .. need .. ": the " .. tostring(tier.Name) .. " can be built!", "good", 5)
		end
	end
	if type(catalog.CanPrestige) == "function" then
		local wasReady = catalog.CanPrestige(before)
		local isReady = catalog.CanPrestige(after)
		if isReady and not wasReady then
			notify(player, "Prestige is ready at your home!", "good", 6)
		end
	end
end

function TycoonService.Buy(player, stationId)
	if not initialized or not catalog then
		return false, "Homes are not ready yet"
	end
	if not isPlayer(player) then
		return false, "Not in the game"
	end
	if type(stationId) ~= "string" or #stationId > MAX_ID_LENGTH then
		return false, "Unknown station"
	end
	if stationId == "Prestige" then
		return TycoonService.Prestige(player)
	end
	local def = catalog.Get(stationId)
	if not def or def.Kind == "Prestige" then
		return false, "Unknown station"
	end
	if not plots[player] then
		return false, "Claim a home first (E at a free gate)"
	end
	local home = getHome(player)
	if not home then
		return false, "Your home is still loading..."
	end
	local ok, price, reason = catalog.CheckPurchase(home, stationId)
	if not ok then
		return false, reason or "Not available yet"
	end
	price = tonumber(price) or 0
	if not isFinite(price) or price < 0 then
		return false, "Not available yet"
	end
	price = math.ceil(price)
	if price > getCash(player) then
		return false, "Not enough Cash: need " .. money(price)
	end
	local level = stationLevel(home, stationId)

	-- check + pay + write in ONE non-yielding step (MutateHome runs fn synchronously)
	local spent = false
	local wrote = mutateHome(player, function(live)
		if stationLevel(live, stationId) ~= level then
			return false
		end
		local okLive, priceLive = catalog.CheckPurchase(live, stationId)
		if not okLive or math.ceil(tonumber(priceLive) or -1) ~= price then
			return false
		end
		if price > 0 then
			if not dataService.SpendCash(player, price) then
				return false
			end
			spent = true
		end
		if type(live.Stations) ~= "table" then
			live.Stations = {}
		end
		live.Stations[stationId] = level + 1
		live.Level = homeLevelOf(live)
		if offlineDone[player] then
			live.LastSeen = os.time() -- income just rose: the next offline payout starts from here
		end
		return true
	end)
	if not wrote then
		if spent then
			dataService.AddCash(player, price) -- the home write was refused: give the cash back
		end
		if price > getCash(player) then
			return false, "Not enough Cash: need " .. money(price)
		end
		return false, "Could not build that right now"
	end

	local after = getHome(player) or home
	syncPlot(player, after)
	local newLevel = level + 1
	if level == 0 then
		notify(player, "Built " .. stationName(stationId) .. "!" .. (price > 0 and (" (-" .. money(price) .. ")") or ""), "good", 3)
	else
		notify(player, stationName(stationId) .. " is now Lv " .. newLevel .. "! (-" .. money(price) .. ")", "good", 3)
	end
	milestoneToasts(player, home, after)
	TycoonService.HomeChanged:Fire(player)
	return true, newLevel
end

----------------------------------------------------------------------
-- Collector
----------------------------------------------------------------------

function TycoonService.Collect(player, quiet)
	if not initialized or not dataService then
		return false, "Homes are not ready yet"
	end
	if not isPlayer(player) then
		return false, "Not in the game"
	end
	local index = plots[player]
	if not index then
		return false, "Claim a home first (E at a free gate)"
	end
	local take = 0
	local ok = mutateHome(player, function(live)
		local cur = tonumber(live.CollectorCash) or 0
		if not isFinite(cur) or cur < 1 then
			return false
		end
		take = math.floor(cur)
		live.CollectorCash = cur - take
		return true
	end)
	if not ok or take < 1 then
		return false, "Nothing to collect yet"
	end
	if not dataService.AddCash(player, take) then
		mutateHome(player, function(live)
			live.CollectorCash = (tonumber(live.CollectorCash) or 0) + take
			return true
		end)
		return false, "Could not bank the Cash right now"
	end
	local home = getHome(player)
	if home then
		local s = shown[index]
		showCollector(index, home.CollectorCash, s and s.Cap or 0, s and s.Income or 0)
	end
	-- stepping on the pad banks every second: its toast shows at most every few seconds
	if not quiet or cooldown(player, "CollectToast", COLLECT_TOAST_GAP) then
		notify(player, "+" .. money(take) .. " banked", "good", 2.5)
	end
	return true, take
end

----------------------------------------------------------------------
-- Prestige
----------------------------------------------------------------------

function TycoonService.Prestige(player)
	if not initialized or not catalog then
		return false, "Homes are not ready yet"
	end
	if not isPlayer(player) then
		return false, "Not in the game"
	end
	if not plots[player] then
		return false, "Claim a home first (E at a free gate)"
	end
	local home = getHome(player)
	if not home then
		return false, "Your home is still loading..."
	end
	local can, reason = catalog.CanPrestige(home)
	if not can then
		return false, reason or "Not ready to prestige yet"
	end
	local stars = starsOf(home) + 1
	local gems = 0
	if type(catalog.PrestigeGems) == "function" then
		local okG, g = pcall(catalog.PrestigeGems, stars)
		if okG and isFinite(g) and g > 0 then
			gems = math.floor(g)
		end
	end

	-- reset stations (decor kept) + collector, +1 star; then Cash to 0 and the gems: one non-yielding step
	local wrote = mutateHome(player, function(live)
		if starsOf(live) ~= stars - 1 or not catalog.CanPrestige(live) then
			return false
		end
		if type(live.Stations) ~= "table" then
			live.Stations = {}
		end
		local keep = catalog.StationsAfterPrestige(live.Stations)
		local ids = {}
		for id in pairs(live.Stations) do
			ids[#ids + 1] = id
		end
		for _, id in ipairs(ids) do
			live.Stations[id] = keep[id] -- in place: Home.Rooms stays the same table
		end
		for id, level in pairs(keep) do
			live.Stations[id] = level
		end
		live.Prestige = stars
		live.CollectorCash = 0
		live.Level = homeLevelOf(live)
		if offlineDone[player] then
			live.LastSeen = os.time()
		end
		return true
	end)
	if not wrote then
		return false, "Could not prestige right now"
	end
	local cash = math.floor(getCash(player))
	if cash > 0 then
		dataService.SpendCash(player, cash)
	end
	if gems > 0 and type(dataService.AddGems) == "function" then
		dataService.AddGems(player, gems)
	end

	local after = getHome(player)
	if after then
		syncPlot(player, after)
	end
	local mult = 1
	if type(catalog.PrestigeMultiplier) == "function" then
		mult = catalog.PrestigeMultiplier(stars)
	end
	local text = "Prestige " .. stars .. "! Income x" .. multiplierText(mult) .. " forever"
	if gems > 0 then
		text = text .. ", +" .. gems .. " Gems"
	end
	notify(player, text .. ".", "good", 6)
	local fusionAt = catalog.Prestige and tonumber(catalog.Prestige.FusionUnlock) or 1
	if stars == fusionAt then
		notify(player, "Fusion Machine unlocked at your home!", "good", 6)
	end
	TycoonService.Prestiged:Fire(player, stars)
	TycoonService.HomeChanged:Fire(player)
	return true, stars
end

----------------------------------------------------------------------
-- Garden
----------------------------------------------------------------------

local function wholeSlot(slot)
	if type(slot) ~= "number" or slot ~= slot or slot == math.huge or slot == -math.huge then
		return nil
	end
	if slot ~= math.floor(slot) or slot < 1 or slot > MAX_SLOT then
		return nil
	end
	return slot
end

function TycoonService.GardenSet(player, slot, key)
	if not initialized or not catalog then
		return false, "Homes are not ready yet"
	end
	if not isPlayer(player) then
		return false, "Not in the game"
	end
	slot = wholeSlot(slot)
	if not slot then
		return false, "Unknown garden slot"
	end
	if key == "" or key == false then
		key = nil
	end
	if key ~= nil and not validKeyString(key) then
		return false, "Unknown pet"
	end
	local home = getHome(player)
	if not home then
		return false, "Your home is still loading..."
	end
	-- (clearing works on any slot: after a prestige the Garden is rebuilt from level 0 and its pets stay placed)
	if key ~= nil and slot > gardenSlots(home) then
		if gardenSlots(home) <= 0 then
			return false, "Build the Pet Garden first"
		end
		return false, "Garden slot locked: upgrade the Garden"
	end
	local profile = getProfile(player)
	local def = nil
	if key ~= nil then
		local tier, why
		def, tier, why = economyDef(key, profile)
		if not def then
			return false, why or "Only Economy pets can work in the Garden"
		end
	end

	local why = nil
	local wrote = mutateHome(player, function(live)
		if key ~= nil and slot > gardenSlots(live) then
			why = "Garden slot locked: upgrade the Garden"
			return false
		end
		if type(live.Garden) ~= "table" then
			live.Garden = {}
		end
		if key == nil then
			if live.Garden[slot] == nil then
				return false
			end
			live.Garden[slot] = nil
			return true
		end
		if live.Garden[slot] == key then
			return false
		end
		if type(live.Gym) == "table" then
			for _, k in pairs(live.Gym) do
				if k == key then
					why = "That pet is training in the Gym"
					return false
				end
			end
		end
		local uses = 1
		for s, k in pairs(live.Garden) do
			if s ~= slot and k == key then
				uses = uses + 1
			end
		end
		if uses > ownedCount(profile, key) then
			why = "You have no free copy of that pet"
			return false
		end
		live.Garden[slot] = key
		if offlineDone[player] then
			live.LastSeen = os.time()
		end
		return true
	end)
	if not wrote then
		if why then
			return false, why
		end
		return true, nil -- nothing to change (already there / already empty)
	end
	if plots[player] then
		local after = getHome(player)
		if after then
			syncPlot(player, after)
		end
	end
	if key ~= nil then
		local name = (def and (def.DisplayName or def.Name)) or key
		notify(player, tostring(name) .. " is working in your Garden!", "good", 3)
	end
	TycoonService.HomeChanged:Fire(player)
	return true, nil
end

----------------------------------------------------------------------
-- Public reads
----------------------------------------------------------------------

function TycoonService.GetPlot(player)
	local index = player and plots[player]
	if index then
		return plotInfo(index)
	end
	return nil
end

function TycoonService.GetHome(player)
	return getHome(player)
end

function TycoonService.IncomePerSecond(player)
	local home = getHome(player)
	if not home then
		return 0, { Press = 0, Garden = 0, Multiplier = 1 }
	end
	local income, parts = incomeOf(player, home)
	return income, parts
end

function TycoonService.CollectorCap(player)
	local home = getHome(player)
	if not home then
		return 0
	end
	local income, _, valid = incomeOf(player, home)
	return capOf(home, income, valid)
end

function TycoonService.GoHome(player)
	if not isPlayer(player) or not spotService or type(spotService.Teleport) ~= "function" then
		return false
	end
	if player:GetAttribute(Config.Attr.InMatch) == true then
		toastOnce(player, "Finish your match first", "bad")
		return false
	end
	local ok, moved = pcall(spotService.Teleport, player)
	moved = ok and moved == true
	if moved and not plots[player] then
		notify(player, "Press E at the gate to claim this home!", "info", 4)
	elseif not moved and not plots[player] then
		toastOnce(player, "Every home is taken right now.", "bad")
	end
	return moved
end

----------------------------------------------------------------------
-- Profile load: offline earnings, LastSeen
----------------------------------------------------------------------

local function touchLastSeen(player)
	lastSeenAt[player] = os.clock()
	local now = os.time()
	mutateHome(player, function(live)
		live.LastSeen = now
		return true
	end)
end

-- Runs once per session when the home is readable (profile loaded and not provisional).
local function onHomeLoaded(player)
	if not isPlayer(player) then
		return
	end
	local home = getHome(player)
	if not home then
		return -- not loaded yet / provisional: ProfileRebased brings us back
	end
	if offlineDone[player] then
		if plots[player] then
			syncPlot(player, home) -- the save was rebased: show what it holds now
			TycoonService.HomeChanged:Fire(player)
		end
		return
	end
	offlineDone[player] = true
	local now = os.time()
	local last = tonumber(home.LastSeen) or 0
	local amount, away = 0, 0
	if isFinite(last) and last > 0 and now > last then
		away = now - last
		local income = incomeOf(player, home)
		local ok, value = pcall(catalog.OfflineEarnings, home, away, income)
		if ok and isFinite(value) and value >= 1 then
			amount = math.floor(value)
		end
	end
	lastSeenAt[player] = os.clock() -- the periodic refresh takes over from here
	if amount < 1 and isFinite(last) and last > 0 then
		return -- nothing paid: the stored LastSeen may stay until the first refresh (no needless write)
	end
	-- (a home seen for the first time - a new or migrated save - gets its LastSeen right away)
	-- the payout and the new LastSeen in the same step: a second load can never pay the same absence again
	local wrote = mutateHome(player, function(live)
		live.LastSeen = now
		return true
	end)
	if wrote and dataService.AddCash(player, amount) then
		task.delay(OFFLINE_TOAST_DELAY, function()
			notify(player, "While you were away: +" .. money(amount) .. " (" .. durationText(away) .. ")", "good", 7)
		end)
	end
end

local function watchPlayer(player)
	if watching[player] or offlineDone[player] then
		return
	end
	watching[player] = true
	task.spawn(function()
		local waited = 0
		while isPlayer(player) and not offlineDone[player] and waited < PROFILE_WAIT do
			if getHome(player) then
				onHomeLoaded(player)
				break
			end
			task.wait(0.5)
			waited = waited + 0.5
		end
		watching[player] = nil
	end)
end

local function forget(player)
	plots[player] = nil
	lastTick[player] = nil
	lastSeenAt[player] = nil
	offlineDone[player] = nil
	watching[player] = nil
	cooldowns[player] = nil
	budgets[player] = nil
	toastAt[player] = nil
end

-- (LastSeen is NOT written here: DataService's leave save may already be running, and a change now would only
-- turn the entry into an orphan that needs another write. The periodic refresh keeps it within LASTSEEN_EVERY.)
local function onPlayerRemoving(player)
	departed[player] = true
	TycoonService.Release(player)
	forget(player)
end

----------------------------------------------------------------------
-- Income tick
----------------------------------------------------------------------

local function tickPlayer(player, index, now)
	local last = lastTick[player] or now
	local dt = math.max(0, math.min(now - last, MAX_TICK_DT))
	lastTick[player] = now
	local home = getHome(player)
	if not home then
		return
	end
	local income, _, valid = incomeOf(player, home)
	local cap = capOf(home, income, valid)
	local cash = tonumber(home.CollectorCash) or 0
	if income > 0 and dt > 0 and cash < cap then
		local gain = income * dt
		local wrote = mutateHome(player, function(live)
			local cur = tonumber(live.CollectorCash) or 0
			if not isFinite(cur) or cur < 0 then
				cur = 0
			end
			if cur >= cap then
				return false
			end
			live.CollectorCash = math.min(cap, cur + gain)
			return true
		end)
		if wrote then
			home.CollectorCash = math.min(cap, cash + gain)
		end
	end
	if syncPlot(player, home, income, valid) then
		TycoonService.HomeChanged:Fire(player) -- another module changed the stations (rebase, dev reset)
	end
	showCollector(index, home.CollectorCash, cap, income)
end

local function tickAll()
	local now = os.clock()
	for player, index in pairs(plots) do
		if player.Parent and not departed[player] then
			local ok, err = pcall(tickPlayer, player, index, now)
			if not ok then
				warn("[TycoonService] income tick failed: " .. tostring(err))
			end
		else
			TycoonService.Release(player)
			forget(player)
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if offlineDone[player] and now - (lastSeenAt[player] or 0) >= LASTSEEN_EVERY then
			touchLastSeen(player)
		end
	end
end

local function tickLoop()
	while running do
		task.wait(TICK)
		if not running then
			break
		end
		local ok, err = pcall(tickAll)
		if not ok then
			warn("[TycoonService] tick failed: " .. tostring(err))
		end
	end
end

----------------------------------------------------------------------
-- Prompts (one ProximityPromptService listener: prompts HomeBuilder rebuilds keep working)
----------------------------------------------------------------------

local function attrUp(inst, name, depth)
	local node = inst
	for _ = 1, depth or 10 do
		if typeof(node) ~= "Instance" or node == workspace or node == game then
			return nil
		end
		local v = node:GetAttribute(name)
		if v ~= nil then
			return v
		end
		node = node.Parent
	end
	return nil
end

-- The plot a prompt belongs to: its SpotIndex attribute (prompt or an ancestor), else the spot folder it is in.
local function plotIndexOf(inst)
	local index = attrUp(inst, "SpotIndex")
	if validIndex(index) then
		return index
	end
	for i, info in pairs(spotList) do
		if typeof(info.Folder) == "Instance" and inst:IsDescendantOf(info.Folder) then
			return i
		end
	end
	return nil
end

local function stationIdOf(prompt)
	local id = attrUp(prompt, "StationId", 6)
	if type(id) == "string" then
		return id
	end
	local node = prompt.Parent
	for _ = 1, 6 do
		if typeof(node) ~= "Instance" then
			break
		end
		local name = node.Name
		local padId = type(name) == "string" and name:match("^Pad_(.+)$")
		if padId then
			return padId
		end
		node = node.Parent
	end
	return nil
end

local function underCollector(prompt)
	if attrUp(prompt, "StationId", 6) == "Collector" then
		return true
	end
	local node = prompt.Parent
	for _ = 1, 6 do
		if typeof(node) ~= "Instance" then
			return false
		end
		if node.Name == "Station_Collector" then
			return true
		end
		node = node.Parent
	end
	return false
end

local function onBuyPrompt(player, prompt)
	local index = plots[player]
	if not index then
		return
	end
	local owner = attrUp(prompt, "OwnerUserId", 6)
	if owner ~= nil and owner ~= player.UserId then
		return -- someone else's pad (their prompts are disabled locally; never trust a stray trigger)
	end
	local promptPlot = plotIndexOf(prompt)
	if promptPlot ~= index then
		return
	end
	local stationId = stationIdOf(prompt)
	if type(stationId) ~= "string" then
		return
	end
	if not cooldown(player, "Buy", BUY_COOLDOWN) or not spend(player) then
		return
	end
	local ok, reason
	if stationId == "Prestige" then
		ok, reason = TycoonService.Prestige(player)
	else
		ok, reason = TycoonService.Buy(player, stationId)
	end
	if not ok then
		toastOnce(player, reason or "Not available yet", "bad")
	end
end

local function onCollectPrompt(player, prompt)
	local index = plots[player]
	if not index or plotIndexOf(prompt) ~= index then
		return
	end
	if not cooldown(player, "Collect", COLLECT_COOLDOWN) or not spend(player) then
		return
	end
	local ok, reason = TycoonService.Collect(player)
	if not ok then
		toastOnce(player, reason or "Nothing to collect yet", "info")
	end
end

local function onPromptTriggered(prompt, player)
	if typeof(prompt) ~= "Instance" or not isPlayer(player) then
		return
	end
	local name = prompt.Name
	if name == "ClaimPrompt" then
		local index = attrUp(prompt, "SpotIndex", 8)
		if not validIndex(index) then
			index = plotIndexOf(prompt)
		end
		if validIndex(index) then
			onClaimPrompt(player, index, prompt)
		end
	elseif name == "BuyPrompt" then
		onBuyPrompt(player, prompt)
	elseif name == "CollectPrompt" or underCollector(prompt) then
		onCollectPrompt(player, prompt)
	end
end

----------------------------------------------------------------------
-- Remote HomeAction(action, arg)
----------------------------------------------------------------------

local function gardenArgs(arg)
	if type(arg) ~= "table" then
		return nil, nil
	end
	local slot = arg.Slot
	local key = arg.Key
	if slot == nil then
		slot = arg[1]
	end
	if key == nil then
		key = arg[2]
	end
	return slot, key
end

local function onHomeAction(player, action, arg)
	if not isPlayer(player) or type(action) ~= "string" or #action > MAX_ACTION_LENGTH then
		return
	end
	if not spend(player) then
		return
	end
	if action == "Upgrade" then
		if type(arg) ~= "string" or #arg > MAX_ID_LENGTH or not cooldown(player, "Buy", BUY_COOLDOWN) then
			return
		end
		local ok, reason = TycoonService.Buy(player, arg)
		if not ok then
			toastOnce(player, reason or "Not available yet", "bad")
		end
	elseif action == "GardenSet" then
		if not cooldown(player, "Garden", GARDEN_COOLDOWN) then
			return
		end
		local slot, key = gardenArgs(arg)
		local ok, reason = TycoonService.GardenSet(player, slot, key)
		if not ok then
			toastOnce(player, reason or "You cannot place that pet", "bad")
		end
	elseif action == "Collect" then
		if not cooldown(player, "Collect", COLLECT_COOLDOWN) then
			return
		end
		local ok, reason = TycoonService.Collect(player)
		if not ok then
			toastOnce(player, reason or "Nothing to collect yet", "info")
		end
	elseif action == "Prestige" then
		if not cooldown(player, "Prestige", PRESTIGE_COOLDOWN) then
			return
		end
		local ok, reason = TycoonService.Prestige(player)
		if not ok then
			toastOnce(player, reason or "Not ready to prestige yet", "bad")
		end
	elseif action == "GoHome" then
		if not cooldown(player, "GoHome", GOHOME_COOLDOWN) then
			return
		end
		TycoonService.GoHome(player)
	end
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------

function TycoonService.Init(lobbyInfo, deps)
	if initialized then
		return
	end
	deps = deps or {}
	dataService = deps.DataService or requireModule(script.Parent, "DataService")
	petService = deps.PetService
	spotService = deps.SpotService or requireModule(script.Parent, "SpotService")
	catalog = requireModule(Shared, "TycoonCatalog")
	petKeys = requireModule(Shared, "PetKeys")
	petCatalog = requireModule(Shared, "PetCatalog")
	if not catalog then
		warn("[TycoonService] TycoonCatalog is missing: tycoon homes are disabled")
		return
	end
	if not dataService or type(dataService.MutateHome) ~= "function" then
		warn("[TycoonService] DataService has no Home API: tycoon homes are disabled")
		return
	end
	if not spotService or type(spotService.Claim) ~= "function" then
		warn("[TycoonService] SpotService cannot hand out plots: claiming is disabled")
	end
	initialized = true

	local list = lobbyInfo and lobbyInfo.Spots
	if type(list) == "table" then
		for index, info in pairs(list) do
			if type(index) == "number" and type(info) == "table" then
				spotList[index] = info
			end
		end
	end

	homeBuilder = requireModule(script.Parent, "HomeBuilder")
	if homeBuilder then
		hb("Init", lobbyInfo)
	else
		warn("[TycoonService] HomeBuilder is missing: plots get a plain claim prompt and no buildings")
	end
	local indices = {}
	for index in pairs(spotList) do
		indices[#indices + 1] = index
	end
	table.sort(indices)
	for _, index in ipairs(indices) do
		hb("PreparePlot", spotList[index])
	end
	local existing = nil
	if homeBuilder then
		local okScan, found = pcall(claimPromptsBySpot)
		existing = okScan and found or nil
	end
	for _, index in ipairs(indices) do
		local ok, err = pcall(ensureClaimPrompt, index, spotList[index], existing)
		if not ok then
			warn("[TycoonService] could not add a claim prompt: " .. tostring(err))
		end
	end

	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)
	local okRemote, remote = pcall(Remotes.Get, "HomeAction")
	if okRemote and remote then
		remote.OnServerEvent:Connect(onHomeAction)
	else
		warn("[TycoonService] HomeAction remote unavailable")
	end

	-- a plot released by SpotService itself (e.g. by another module) is cleared here too
	if spotService and spotService.Released and type(spotService.Released.Connect) == "function" then
		spotService.Released:Connect(function(player, index)
			if plotOwner[index] == player then
				local info = dropPlot(player, index)
				if info then
					TycoonService.Released:Fire(player, info)
				end
			end
		end)
	end

	if dataService.ProfileLoaded and type(dataService.ProfileLoaded.Connect) == "function" then
		dataService.ProfileLoaded:Connect(function(player)
			onHomeLoaded(player)
		end)
	end
	if dataService.ProfileRebased and type(dataService.ProfileRebased.Connect) == "function" then
		dataService.ProfileRebased:Connect(function(player)
			onHomeLoaded(player)
		end)
	end

	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		watchPlayer(player) -- players who joined before Init (PlayerService loads profiles first)
	end

	running = true
	task.spawn(tickLoop)
	game:BindToClose(function()
		running = false
		for _, player in ipairs(Players:GetPlayers()) do
			if offlineDone[player] then
				pcall(touchLastSeen, player)
			end
		end
	end)
end

return TycoonService
