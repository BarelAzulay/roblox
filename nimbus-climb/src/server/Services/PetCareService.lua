-- PetCareService (Phase 2, care): the home's Kitchen, feeding and the Gym (ARCHITECTURE_V3.md "Phase 2: Tycoon homes"
-- items 3-4 and the PetCareService paragraph of the "Phase 2 build contract").
--
-- * Kitchen: Cook(foodId, qty) pays the food's Price in Cash (TycoonCatalog.Foods: Snack / Meal / Feast) and puts the
--   dishes in the Kitchen's cooking queue (at most TycoonCatalog Kitchen Effects[level].Queue dishes, cooking one
--   included). One dish cooks at a time, for TycoonCatalog.CookSecondsFor(foodId, kitchenLevel) seconds (better
--   Kitchens cook faster and unlock better recipes); a finished dish goes straight into the profile's Food
--   (DataService.AddFood). The queue lives on the server for the session and keeps cooking wherever the player is in
--   the server (a match, the lobby, ...). Ordering needs a claimed home with a Kitchen; the Cash check, the payment
--   and the queue write are one non-yielding step (an order for more than the Cash or the queue allows cooks what
--   fits). A player who leaves gets the Cash of the dishes that had not finished back. Toasts: "Cooking ..." on
--   order, a summary when the queue is done, and a progress toast at most every 30 s while a long queue cooks.
-- * Feeding: Feed(key, foodId) spends one food and gives that pet copy the food's Xp (DataService.AddPetXp). Pets
--   level along TycoonCatalog.XpToNext up to their LEVEL CAP (PetCatalog.LevelCap: by rarity, Common 20 ... Secret
--   50; TycoonCatalog may override the numbers). XP past the cap is not given and a capped pet is refused before any
--   food is used. A level-up answers with a side toast showing the new stats (PetCatalog.GetStats / StatsOf: Income
--   for Economy pets, Power / Health / Speed for Combat pets). Spending the food and writing the XP is one
--   non-yielding step: the food comes back if the XP could not be written.
-- * Gym: GymSet(slot, key|nil) puts a Combat pet copy in a Gym slot (slots unlock with the Gym level,
--   TycoonCatalog.GymSlots) or clears the slot. One slot per copy; a pet working in the Garden cannot train (and
--   TycoonService refuses Garden places for pets in the Gym). Training pets gain TycoonCatalog.GymXpPerMinute(home)
--   XP per minute each while the player is in the server with the home claimed (like the Collector's income),
--   granted every 10 s, up to their level cap; a pet that also sits in the Garden (old data) does not train.
-- * Kitchen prompts: on the player's own Station_Kitchen (HomeBuilder) this service adds one "Cook <food>"
--   ProximityPrompt per recipe the Kitchen can cook (CookPrompt, attributes FoodId / OwnerUserId; keys E / R / F,
--   hold 0.3 s) above the counter, and "Feed pets" (FeedPrompt) on its FeedBowl: every pet that follows the player
--   eats one food (the best food that does not overshoot its level cap). HomeFx disables other players' prompts
--   locally; the server checks the owner on every trigger. The prompts come back when the Kitchen is rebuilt.
-- * Replication: player attributes KitchenQueue ("Snack,Snack,Meal": the dish cooking first, "" when idle),
--   KitchenReadyAt (workspace:GetServerTimeNow() when the dish cooking now is done, 0 when idle) and
--   KitchenDishSeconds (that dish's cook time) for a Kitchen panel / progress bar; the plot folder gets GymPets
--   ("1=stormfang;2=cat@Golden": the pets training right now, like TycoonService's GardenPets) and
--   HomeBuilder.SetGym(spotInfo, { [slot] = key }) is called when HomeBuilder has such a function. Food, PetLevels
--   and Home.Gym reach the client through ProfileSync (DataService).
-- * Remote PetCare(action, a, b): "Cook" (foodId, qty = 1; or {FoodId =, Qty =}), "Feed" (key, foodId; or {Key =,
--   FoodId =}), "GymSet" (slot, key|nil; or {Slot =, Key =} / {slot, key}; slot nil / 0 with a key = the first free
--   slot; a key with no slot = take that pet out of the Gym). Types, lengths, ranges and NaN are checked; every
--   action has a cooldown plus a shared per-player burst budget; refusals answer with a side toast (repeated texts
--   are throttled). Nothing here moves parts (Replication rule).
--
-- Public API (the contract): Init(deps)   deps = { DataService, PetService, TycoonService }
-- Extras (TutorialService / Phase 3 battles / the UI may use them):
--   Cook(player, foodId, qty) -> ok, dishesOrdered | reason
--   Feed(player, key, foodId) -> ok, { Xp, Levels, Level, Cap } | reason
--   GymSet(player, slot, key) -> ok, reason
--   GrantXp(player, key, xp, source) -> xpGiven, levelsGained, reason   (cap-aware XP for other services)
--   LevelCap(player, key) -> n | nil          GetQueue(player) -> { { FoodId, ReadyIn }... }
--   Signals Cooked(player, foodId, count), Fed(player, key, foodId, levelsGained), LevelUp(player, key, level, source),
--   GymChanged(player)
--
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local PetCareService = {}
PetCareService.Cooked = Util.Signal() -- Fire(player, foodId, count): dishes delivered into the profile's Food
PetCareService.Fed = Util.Signal() -- Fire(player, key, foodId, levelsGained)
PetCareService.LevelUp = Util.Signal() -- Fire(player, key, newLevel, source)  source "Feed" | "Gym" | GrantXp's
PetCareService.GymChanged = Util.Signal() -- Fire(player)

local TICK = 1 -- seconds between kitchen / gym ticks
local MAX_TICK_DT = 5 -- a stalled server never trains more than this many seconds in one tick
local GYM_GRANT_EVERY = 10 -- seconds between Gym XP grants (each grant is one throttled profile sync)
local MAX_QTY = 100 -- dishes in one Cook request (the queue takes what fits)
local MAX_FOOD = 1000000 -- DataService keeps at most this many of one food
local COOK_COOLDOWN = 0.25
local FEED_COOLDOWN = 0.1
local GYM_COOLDOWN = 0.25
local PROMPT_COOLDOWN = 0.35
local BURST_SIZE = 12 -- PetCare requests a player may send at once...
local BURST_REFILL = 6 -- ...refilled at this many per second
local TOAST_GAP = 1.5 -- the same refusal text is not repeated within this many seconds
local KITCHEN_TOAST_GAP = 30 -- at most one progress toast this often while a long queue cooks
local MAX_TOAST_CHARS = 90 -- NotifyController shows up to 90 characters
local MAX_NAME_CHARS = 28 -- "Rainbow Starlight Unicorn" fits; the longest toast stays under 90 characters
local MAX_ACTION_LENGTH = 16
local MAX_ID_LENGTH = 48
local MAX_SLOT = 64
local PROMPT_RANGE = 10
local PROMPT_HOLD = 0.3
local PROMPT_SPACING = 3 -- studs between the cook prompts along the counter
local PROMPT_HEIGHT = 4.2 -- studs above the Kitchen's floor (the station origin) where the cook prompts float
local PROMPT_DEPTH = 1.0 -- station-local Z of the cook prompts: just in front of the counter (the front is -Z)
local FALLBACK_LEVEL_CAPS = { Common = 20, Uncommon = 25, Rare = 30, Epic = 35, Legendary = 40, Mythic = 45, Secret = 50 }
local FALLBACK_MAX_LEVEL = 50
local COOK_KEYS = {
	{ Keyboard = Enum.KeyCode.E, Gamepad = Enum.KeyCode.ButtonX },
	{ Keyboard = Enum.KeyCode.R, Gamepad = Enum.KeyCode.ButtonY },
	{ Keyboard = Enum.KeyCode.F, Gamepad = Enum.KeyCode.ButtonB },
}
local ATTR_QUEUE = "KitchenQueue"
local ATTR_READY = "KitchenReadyAt"
local ATTR_DISH = "KitchenDishSeconds"
local ATTR_GYM = "GymPets"
local CARE_SIG = "CareSig" -- attribute on the Kitchen model: which prompts this service built on it
local CARE_MARK = "CareMade" -- attribute on every attachment / prompt this service made

local initialized = false
local running = false
local dataService = nil
local petService = nil
local tycoonService = nil
local catalog = nil -- TycoonCatalog
local petKeys = nil -- PetKeys (optional)
local petCatalog = nil -- PetCatalog (optional)
local homeBuilder = nil -- HomeBuilder (optional: SetGym)
local notifyRemote = nil
local openPanelRemote = nil

local kitchens = {} -- [Player] = { Queue = { { FoodId, Price, Base, Started, Seconds }... }, Batch, BatchOrder, LastToast }
local gyms = {} -- [Player] = { Pending = { [key] = xp }, LastTick, LastGrant, Capped = { [key] = true } }
local gymShown = {} -- [Player] = { Folder = Instance, Text = string }
local cooldowns = {} -- [Player] = { [key] = os.clock() }
local budgets = {} -- [Player] = { Tokens, At }
local toastAt = {} -- [Player] = { [text] = os.clock() }
local departed = setmetatable({}, { __mode = "k" })

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function isFinite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isPlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent ~= nil and not departed[player]
end

local function requireModule(container, name)
	local module = container and container:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[PetCareService] could not load " .. name .. ": " .. tostring(result))
	return nil
end

-- cuts a text to n characters without splitting a UTF-8 character
local function clip(text, n)
	text = tostring(text)
	if #text <= n then
		return text
	end
	local cut = string.sub(text, 1, n - 3)
	cut = string.gsub(cut, "[\192-\255][\128-\191]*$", "")
	return cut .. "..."
end

local function remote(name)
	local ok, r = pcall(Remotes.Get, name)
	if ok then
		return r
	end
	return nil
end

local function notify(player, text, kind, seconds)
	if not isPlayer(player) or type(text) ~= "string" or text == "" then
		return
	end
	notifyRemote = notifyRemote or remote("Notify")
	if notifyRemote then
		pcall(function()
			notifyRemote:FireClient(player, clip(text, MAX_TOAST_CHARS), kind or "info", seconds or 3)
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

-- Per player burst budget shared by every PetCare request and care prompt.
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

local function serverNow()
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	if ok and isFinite(t) then
		return t
	end
	return os.time()
end

local function setAttr(inst, name, value)
	pcall(function()
		if inst:GetAttribute(name) ~= value then
			inst:SetAttribute(name, value)
		end
	end)
end

-- "Snack" -> "Snacks" (n ~= 1)
local function plural(name, n)
	name = tostring(name)
	if n == 1 then
		return name
	end
	return name .. "s"
end

-- 6 -> "6s", 72 -> "1m 12s", 3900 -> "1h 5m"
local function duration(seconds)
	local s = math.max(0, math.ceil(tonumber(seconds) or 0))
	if s < 60 then
		return s .. "s"
	end
	if s < 3600 then
		local m, r = math.floor(s / 60), s % 60
		if r == 0 then
			return m .. "m"
		end
		return m .. "m " .. r .. "s"
	end
	local h, m = math.floor(s / 3600), math.floor((s % 3600) / 60)
	if m == 0 then
		return h .. "h"
	end
	return h .. "h " .. m .. "m"
end

-- 1234 -> "1.2K" (stat numbers in toasts)
local function compact(n)
	n = tonumber(n) or 0
	if not isFinite(n) then
		return "0"
	end
	local a = math.abs(n)
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in ipairs(units) do
		if a >= u[1] then
			local x = n / u[1]
			local s
			if math.abs(x) >= 100 then
				s = string.format("%d", math.floor(x))
			else
				s = string.format("%.1f", math.floor(x * 10) / 10)
				s = string.gsub(s, "%.0$", "")
			end
			return s .. u[2]
		end
	end
	return tostring(math.floor(n + 0.5))
end

----------------------------------------------------------------------
-- Data access (DataService; every call guarded)
----------------------------------------------------------------------

local function dsCall(fnName, ...)
	if not dataService or type(dataService[fnName]) ~= "function" then
		return false, nil, nil
	end
	local ok, a, b = pcall(dataService[fnName], ...)
	if not ok then
		warn("[PetCareService] DataService." .. fnName .. " failed: " .. tostring(a))
		return false, nil, nil
	end
	return true, a, b
end

local function getProfile(player)
	local ok, profile = dsCall("GetProfile", player)
	if ok and type(profile) == "table" then
		return profile
	end
	return nil
end

local function getHome(player)
	local ok, home = dsCall("GetHome", player)
	if ok and type(home) == "table" then
		return home
	end
	return nil
end

-- true while the save is a stand-in (DataService refuses XP writes then)
local function isProvisional(player)
	if dataService and type(dataService.IsProvisional) == "function" then
		local ok, result = pcall(dataService.IsProvisional, player)
		return ok and result == true
	end
	return false
end

local function getCash(player)
	local ok, cash = dsCall("GetCash", player)
	if ok and isFinite(cash) and cash > 0 then
		return math.floor(cash)
	end
	return 0
end

local function spendCash(player, n)
	local ok, result = dsCall("SpendCash", player, n)
	return ok and result == true
end

local function addCash(player, n)
	local ok, result = dsCall("AddCash", player, n)
	return ok and result == true
end

local function getFood(player, foodId)
	local ok, n = dsCall("GetFood", player, foodId)
	if ok and isFinite(n) and n > 0 then
		return math.floor(n)
	end
	return 0
end

local function addFood(player, foodId, n)
	local ok, result = dsCall("AddFood", player, foodId, n)
	return ok and result == true
end

local function spendFood(player, foodId, n)
	local ok, result = dsCall("SpendFood", player, foodId, n)
	return ok and result == true
end

local function petLevel(player, key)
	local ok, level, xp = dsCall("GetPetLevel", player, key)
	if not ok or not isFinite(level) or level < 1 then
		level = 1
	end
	if not ok or not isFinite(xp) or xp < 0 then
		xp = 0
	end
	return math.floor(level), xp
end

local function addPetXp(player, key, xp)
	local ok, gained = dsCall("AddPetXp", player, key, xp)
	if ok and isFinite(gained) and gained > 0 then
		return math.floor(gained)
	end
	return 0
end

local function mutateHome(player, fn)
	local ok, result = dsCall("MutateHome", player, fn)
	return ok and result == true
end

----------------------------------------------------------------------
-- Catalog access (TycoonCatalog: foods, Kitchen / Gym effects, the XP curve)
----------------------------------------------------------------------

local function money(n)
	if catalog and type(catalog.FormatCash) == "function" then
		local ok, text = pcall(catalog.FormatCash, n)
		if ok and type(text) == "string" then
			return text
		end
	end
	return "$" .. tostring(math.floor(tonumber(n) or 0))
end

-- income per second: "$12.5/s" (one decimal under 1000)
local function rate(n)
	n = tonumber(n) or 0
	if not isFinite(n) or n < 0 then
		n = 0
	end
	if n < 1000 then
		local s = string.format("%.1f", math.floor(n * 10 + 0.5) / 10)
		s = string.gsub(s, "%.0$", "")
		return "$" .. s .. "/s"
	end
	return money(n) .. "/s"
end

local function foodDef(foodId)
	if type(foodId) ~= "string" or foodId == "" or #foodId > MAX_ID_LENGTH or not catalog then
		return nil
	end
	local def = nil
	if type(catalog.FoodById) == "function" then
		local ok, result = pcall(catalog.FoodById, foodId)
		if ok then
			def = result
		end
	end
	if type(def) ~= "table" and type(catalog.FoodsById) == "table" then
		def = catalog.FoodsById[foodId]
	end
	if type(def) ~= "table" or def.Id ~= foodId or not isFinite(def.Price) or def.Price < 0 or not isFinite(def.Xp) or def.Xp <= 0 then
		return nil
	end
	return def
end

local function foodList()
	local out = {}
	if catalog and type(catalog.Foods) == "table" then
		for _, f in ipairs(catalog.Foods) do
			if foodDef(f.Id) then
				out[#out + 1] = f
			end
		end
	end
	return out
end

local function stationLevel(home, id)
	if catalog and type(catalog.StationLevel) == "function" then
		local ok, level = pcall(catalog.StationLevel, home, id)
		if ok and isFinite(level) then
			return math.max(0, math.floor(level))
		end
	end
	local v = type(home) == "table" and type(home.Stations) == "table" and home.Stations[id]
	return isFinite(v) and math.max(0, math.floor(v)) or 0
end

local function kitchenEffects(level)
	if level < 1 or not catalog or type(catalog.EffectsOf) ~= "function" then
		return nil
	end
	local ok, eff = pcall(catalog.EffectsOf, "Kitchen", level)
	if ok and type(eff) == "table" then
		return eff
	end
	return nil
end

-- dishes the Kitchen's queue holds (the one cooking included)
local function queueSize(level)
	local eff = kitchenEffects(level)
	local n = eff and (eff.Queue or eff.Slots)
	if isFinite(n) and n >= 1 then
		return math.floor(n)
	end
	return level >= 1 and 1 or 0
end

local function cookSeconds(foodId, level)
	if not catalog or type(catalog.CookSecondsFor) ~= "function" then
		return nil
	end
	local ok, s = pcall(catalog.CookSecondsFor, foodId, level)
	if ok and isFinite(s) and s > 0 then
		return s
	end
	return nil
end

local function gymSlots(home)
	if catalog and type(catalog.GymSlots) == "function" then
		local ok, n = pcall(catalog.GymSlots, home)
		if ok and isFinite(n) and n > 0 then
			return math.min(math.floor(n), MAX_SLOT)
		end
	end
	return 0
end

local function gymXpPerMinute(home)
	if catalog and type(catalog.GymXpPerMinute) == "function" then
		local ok, n = pcall(catalog.GymXpPerMinute, home)
		if ok and isFinite(n) and n > 0 then
			return n
		end
	end
	return 0
end

-- XP from `level` to level + 1 (the TycoonCatalog curve; DataService's own fallback curve without it)
local function xpToNext(level)
	if catalog and type(catalog.XpToNext) == "function" then
		local ok, need = pcall(catalog.XpToNext, level)
		if ok and type(need) == "number" and need == need and need > 0 then
			return need
		end
	end
	return math.floor(40 * level ^ 1.35 + 0.5)
end

local function maxPetLevel()
	if petCatalog and type(petCatalog.MaxPetLevel) == "function" then
		local ok, n = pcall(petCatalog.MaxPetLevel)
		if ok and isFinite(n) and n >= 1 then
			return math.floor(n)
		end
	end
	if catalog then
		local px = type(catalog.PetXp) == "table" and catalog.PetXp or nil
		for _, v in ipairs({ catalog.MaxPetLevel or false, px and px.MaxLevel or false }) do
			if isFinite(v) and v >= 1 then
				return math.floor(v)
			end
		end
	end
	return FALLBACK_MAX_LEVEL
end

----------------------------------------------------------------------
-- Pets (keys, defs, ownership, levels and caps)
----------------------------------------------------------------------

local function validKeyString(key)
	if type(key) ~= "string" or key == "" or #key > MAX_ID_LENGTH then
		return false
	end
	if petKeys and type(petKeys.Parse) == "function" then
		local ok, parsed = pcall(petKeys.Parse, key)
		return ok and parsed ~= nil
	end
	return string.find(key, "^[%w_%-:@]+$") ~= nil
end

local function defOf(key, profile)
	if not validKeyString(key) then
		return nil
	end
	if petKeys and type(petKeys.DefOf) == "function" then
		local ok, def = pcall(petKeys.DefOf, key, profile)
		if ok and type(def) == "table" then
			return def
		end
		return nil
	end
	if petCatalog and type(petCatalog.Get) == "function" then
		local def = petCatalog.Get(key)
		if type(def) == "table" then
			return def
		end
	end
	return nil
end

local function ownedCount(profile, key)
	if type(profile) ~= "table" or not validKeyString(key) then
		return 0
	end
	if petKeys and type(petKeys.Count) == "function" then
		local ok, n = pcall(petKeys.Count, profile, key)
		if ok and isFinite(n) and n > 0 then
			return math.floor(n)
		end
		return 0
	end
	local n = type(profile.Pets) == "table" and profile.Pets[key]
	return isFinite(n) and math.max(0, math.floor(n)) or 0
end

local function petName(def, key)
	local name = type(def) == "table" and (def.DisplayName or def.Name) or nil
	if type(name) ~= "string" or name == "" then
		name = tostring(key)
	end
	return clip(name, MAX_NAME_CHARS)
end

-- the level feeding / the Gym can raise this pet to (PetCatalog.LevelCap by rarity, never above the curve's top)
local function levelCap(def)
	local top = maxPetLevel()
	local cap = nil
	if petCatalog and type(petCatalog.LevelCap) == "function" then
		local ok, n = pcall(petCatalog.LevelCap, def)
		if ok and isFinite(n) then
			cap = n
		end
	end
	if not cap and type(def) == "table" then
		cap = FALLBACK_LEVEL_CAPS[def.Rarity]
	end
	if not isFinite(cap) or cap < 1 then
		return top
	end
	return math.min(math.floor(cap), top)
end

-- XP the pet can still take before it reaches `cap`
local function xpRoom(level, xp, cap)
	if level >= cap then
		return 0
	end
	local total = 0
	for l = level, cap - 1 do
		local need = xpToNext(l)
		if not isFinite(need) then
			break
		end
		total = total + need
	end
	return math.max(0, total - (tonumber(xp) or 0))
end

local function statsOf(def, level)
	if not petCatalog or type(def) ~= "table" then
		return nil
	end
	local fn = petCatalog.StatsOf or petCatalog.GetStats
	if type(fn) ~= "function" then
		return nil
	end
	local ok, stats = pcall(fn, def, level)
	if ok and type(stats) == "table" then
		return stats
	end
	return nil
end

-- "Income $12.5/s" (Economy) / "Power 312, Health 1.2K, Speed 98" (Combat)
local function statsText(def, level)
	local stats = statsOf(def, level)
	if not stats then
		return ""
	end
	if def.Role == "Economy" then
		return "Income " .. rate(stats.Income)
	end
	return "Power " .. compact(stats.Power) .. ", Health " .. compact(stats.Health) .. ", Speed " .. compact(stats.Speed)
end

local function levelUpText(def, key, level, cap, source)
	local verb = (source == "Gym") and " trained to Lv " or " reached Lv "
	local text = petName(def, key) .. verb .. level
	if level >= cap then
		text = text .. " (max)"
	end
	local stats = statsText(def, level)
	if stats ~= "" then
		text = text .. "! " .. stats
	else
		text = text .. "!"
	end
	return text
end

-- Cap-aware XP. Returns xpGiven, levelsGained, reason (nil on success), and the new level / XP / cap / def.
local function grantXp(player, key, xp, source)
	-- whole XP only: DataService reads XP back as whole points, so a fraction could never be seen to arrive
	xp = isFinite(xp) and math.floor(xp) or 0
	if xp < 1 then
		return 0, 0, "No XP to give"
	end
	local profile = getProfile(player)
	if not profile or isProvisional(player) then
		return 0, 0, "Your save is still loading..."
	end
	local def = defOf(key, profile)
	if not def then
		return 0, 0, "Unknown pet"
	end
	if ownedCount(profile, key) < 1 then
		return 0, 0, "You do not own that pet"
	end
	local level, have = petLevel(player, key)
	local cap = levelCap(def)
	local room = xpRoom(level, have, cap)
	if room <= 0 then
		return 0, 0, petName(def, key) .. " is at its max level (Lv " .. cap .. ")", level, have, cap, def
	end
	local give = math.min(xp, room)
	local gained = addPetXp(player, key, give)
	local level2, have2 = petLevel(player, key)
	if gained == 0 and level2 == level and have2 == have then
		return 0, 0, "That pet cannot gain XP right now", level, have, cap, def
	end
	if level2 > level then
		PetCareService.LevelUp:Fire(player, key, level2, source)
	end
	return give, math.max(0, level2 - level), nil, level2, have2, cap, def
end

----------------------------------------------------------------------
-- Plots (TycoonService) and the Kitchen model
----------------------------------------------------------------------

local function plotOf(player)
	if tycoonService and type(tycoonService.GetPlot) == "function" then
		local ok, info = pcall(tycoonService.GetPlot, player)
		if ok and type(info) == "table" then
			return info
		end
	end
	return nil
end

-- Ordering food and Gym training need the claimed home (without TycoonService there are no plots to claim).
local function hasHome(player)
	if not tycoonService or type(tycoonService.GetPlot) ~= "function" then
		return true
	end
	return plotOf(player) ~= nil
end

local function kitchenModel(info)
	local folder = info and info.Folder
	if typeof(folder) ~= "Instance" then
		return nil
	end
	local homeFolder = folder:FindFirstChild("Home")
	local model = homeFolder and homeFolder:FindFirstChild("Station_Kitchen") or nil
	if not model and not homeFolder then
		model = folder:FindFirstChild("Station_Kitchen", true)
	end
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

----------------------------------------------------------------------
-- Kitchen: the cooking queue
----------------------------------------------------------------------

local function kitchenOf(player)
	local k = kitchens[player]
	if not k then
		k = { Queue = {}, Batch = {}, BatchOrder = {}, LastToast = -math.huge }
		kitchens[player] = k
	end
	return k
end

local function queuedOf(k, foodId)
	local n = 0
	for _, dish in ipairs(k.Queue) do
		if dish.FoodId == foodId then
			n = n + 1
		end
	end
	return n
end

-- the dish starts cooking at `at`, at the CURRENT Kitchen level (an upgrade speeds up the dishes still waiting;
-- a Kitchen reset by a prestige keeps the speed the dish was ordered at)
local function startDish(dish, at, level)
	dish.Started = at
	local s = (level and level >= 1) and cookSeconds(dish.FoodId, level) or nil
	if not isFinite(s) or s <= 0 then
		s = dish.Base
	end
	dish.Seconds = s
end

-- seconds until every dish in the queue is done
local function queueSeconds(k, now)
	local total = 0
	for i, dish in ipairs(k.Queue) do
		if i == 1 and dish.Started then
			total = total + math.max(0, dish.Started + dish.Seconds - now)
		else
			total = total + (dish.Seconds or dish.Base or 0)
		end
	end
	return total
end

local function publishKitchen(player, k)
	if not isPlayer(player) then
		return
	end
	local ids = {}
	for i, dish in ipairs(k.Queue) do
		ids[i] = dish.FoodId
	end
	local head = k.Queue[1]
	local readyAt, seconds = 0, 0
	if head and head.Started then
		seconds = math.floor(head.Seconds * 100 + 0.5) / 100
		readyAt = serverNow() + math.max(0, head.Started + head.Seconds - os.clock())
		readyAt = math.floor(readyAt * 100 + 0.5) / 100
	end
	setAttr(player, ATTR_QUEUE, table.concat(ids, ","))
	setAttr(player, ATTR_READY, readyAt)
	setAttr(player, ATTR_DISH, seconds)
end

-- "3 Snacks, 1 Meal"
local function batchText(k)
	local parts = {}
	for _, id in ipairs(k.BatchOrder) do
		local n = k.Batch[id] or 0
		if n > 0 then
			local def = foodDef(id)
			parts[#parts + 1] = n .. " " .. plural(def and def.Name or id, n)
		end
	end
	return table.concat(parts, ", ")
end

local function tickKitchen(player, k, now)
	if #k.Queue == 0 then
		return
	end
	local level = nil
	local function kitchenLevel()
		if level == nil then
			local home = getHome(player)
			level = home and stationLevel(home, "Kitchen") or 0
		end
		return level
	end
	if not k.Queue[1].Started then
		startDish(k.Queue[1], now, kitchenLevel())
	end
	local done, order = {}, {}
	local guard = 0
	while k.Queue[1] and guard < 256 do
		guard = guard + 1
		local dish = k.Queue[1]
		local finish = dish.Started + dish.Seconds
		if now < finish then
			break
		end
		if not addFood(player, dish.FoodId, 1) then
			break -- the profile is busy: this dish waits for the next tick
		end
		table.remove(k.Queue, 1)
		if not done[dish.FoodId] then
			done[dish.FoodId] = 0
			order[#order + 1] = dish.FoodId
		end
		done[dish.FoodId] = done[dish.FoodId] + 1
		local nextDish = k.Queue[1]
		if nextDish then
			startDish(nextDish, finish, kitchenLevel()) -- back to back: it started when the last one finished
		end
	end
	if #order == 0 then
		return
	end
	for _, id in ipairs(order) do
		if not k.Batch[id] then
			k.BatchOrder[#k.BatchOrder + 1] = id
		end
		k.Batch[id] = (k.Batch[id] or 0) + done[id]
		PetCareService.Cooked:Fire(player, id, done[id])
	end
	publishKitchen(player, k)
	if #k.Queue == 0 then
		notify(player, "Kitchen: " .. batchText(k) .. " ready! Feed your pets", "good", 4)
	elseif now - k.LastToast >= KITCHEN_TOAST_GAP then
		notify(player, "Kitchen: " .. batchText(k) .. " ready (" .. #k.Queue .. " still cooking)", "info", 3)
	else
		return
	end
	k.Batch, k.BatchOrder, k.LastToast = {}, {}, now
end

-- dishes still in the queue are refunded; finished ones were delivered by the tick
local function refundKitchen(player)
	local k = kitchens[player]
	kitchens[player] = nil
	if not k or #k.Queue == 0 then
		return
	end
	local total = 0
	for _, dish in ipairs(k.Queue) do
		total = total + (dish.Price or 0)
	end
	-- only while the save is still in memory (DataService keeps it until the leave save is done; a change made now
	-- travels with that save or with its retry)
	if total > 0 and getProfile(player) then
		addCash(player, total)
	end
end

local function wholeQty(qty)
	if qty == nil then
		return 1
	end
	if not isFinite(qty) or qty < 1 then
		return nil
	end
	return math.min(math.floor(qty), MAX_QTY)
end

function PetCareService.Cook(player, foodId, qty)
	if not initialized then
		return false, "The Kitchen is not ready yet"
	end
	if not isPlayer(player) then
		return false, "Not in the game"
	end
	local food = foodDef(foodId)
	if not food then
		return false, "Unknown food"
	end
	local wanted = wholeQty(qty)
	if not wanted then
		return false, "Pick how many to cook (1-" .. MAX_QTY .. ")"
	end
	local home = getHome(player)
	if not home then
		return false, "Your home is still loading..."
	end
	if not hasHome(player) then
		return false, "Claim your home first: press E at a free gate"
	end
	local level = stationLevel(home, "Kitchen")
	if level < 1 then
		return false, "Build the Kitchen first"
	end
	local need = isFinite(food.KitchenLevel) and food.KitchenLevel or 1
	if level < need then
		return false, "Upgrade the Kitchen to Lv " .. need .. " to cook " .. plural(food.Name, 2)
	end
	local k = kitchenOf(player)
	local size = queueSize(level)
	local free = size - #k.Queue
	if free <= 0 then
		return false, "The Kitchen is busy (" .. #k.Queue .. "/" .. size .. " cooking)"
	end
	local count = math.min(wanted, free)
	local limit = nil
	if count < wanted then
		limit = "Kitchen full"
	end
	local bag = getFood(player, food.Id) + queuedOf(k, food.Id)
	if bag + count > MAX_FOOD then
		count = MAX_FOOD - bag
		limit = "food bag full"
	end
	if count < 1 then
		return false, "Your food bag is full"
	end
	-- the Cash check, the payment and the queue write: one step, no yields in between
	local price = math.max(0, math.floor(food.Price))
	if price > 0 then
		local afford = math.floor(getCash(player) / price)
		if afford < count then
			count = afford
			limit = "not enough Cash for more"
		end
	end
	if count < 1 then
		return false, "Not enough Cash: a " .. food.Name .. " costs " .. money(price)
	end
	if not spendCash(player, price * count) then
		return false, "Not enough Cash: a " .. food.Name .. " costs " .. money(price)
	end
	local base = cookSeconds(food.Id, level) or (isFinite(food.CookSeconds) and food.CookSeconds > 0 and food.CookSeconds) or 5
	for _ = 1, count do
		k.Queue[#k.Queue + 1] = { FoodId = food.Id, Price = price, Base = base }
	end
	local now = os.clock()
	if not k.Queue[1].Started then
		startDish(k.Queue[1], now, level)
	end
	publishKitchen(player, k)
	local text = "Cooking " .. count .. " " .. plural(food.Name, count)
	if price > 0 then
		text = text .. " for " .. money(price * count)
	end
	local wait = queueSeconds(k, now) -- new dishes go to the end of the queue: this is when the order is done
	if count == 1 then
		text = text .. ": ready in " .. duration(wait)
	else
		text = text .. ": all ready in " .. duration(wait)
	end
	if limit then
		text = text .. " (" .. limit .. ")"
	end
	notify(player, text, "info", 3)
	k.LastToast = now
	return true, count
end

-- { { FoodId, ReadyIn }... } (ReadyIn = seconds until that dish is done)
function PetCareService.GetQueue(player)
	local out = {}
	local k = player and kitchens[player]
	if not k then
		return out
	end
	local now = os.clock()
	local t = 0
	for i, dish in ipairs(k.Queue) do
		if i == 1 and dish.Started then
			t = math.max(0, dish.Started + dish.Seconds - now)
		else
			t = t + (dish.Seconds or dish.Base or 0)
		end
		out[i] = { FoodId = dish.FoodId, ReadyIn = t }
	end
	return out
end

----------------------------------------------------------------------
-- Feeding
----------------------------------------------------------------------

local function feed(player, key, foodId)
	if not initialized then
		return false, "Feeding is not ready yet"
	end
	if not isPlayer(player) then
		return false, "Not in the game"
	end
	if not validKeyString(key) then
		return false, "Unknown pet"
	end
	local food = foodDef(foodId)
	if not food then
		return false, "Unknown food"
	end
	local profile = getProfile(player)
	if not profile or isProvisional(player) then
		return false, "Your save is still loading..."
	end
	local def = defOf(key, profile)
	if not def then
		return false, "Unknown pet"
	end
	if ownedCount(profile, key) < 1 then
		return false, "You do not own that pet"
	end
	local level, have = petLevel(player, key)
	local cap = levelCap(def)
	if xpRoom(level, have, cap) <= 0 then
		return false, petName(def, key) .. " is at its max level (Lv " .. cap .. ")"
	end
	if getFood(player, food.Id) < 1 then
		return false, "You have no " .. plural(food.Name, 2) .. ": cook some in your Kitchen"
	end
	-- spend the food and write the XP in one step (no yields); the food comes back when the XP was refused
	if not spendFood(player, food.Id, 1) then
		return false, "You have no " .. plural(food.Name, 2) .. ": cook some in your Kitchen"
	end
	local given, levels, why, newLevel, newXp = grantXp(player, key, food.Xp, "Feed")
	if given <= 0 then
		addFood(player, food.Id, 1)
		return false, why or "That pet cannot eat right now"
	end
	PetCareService.Fed:Fire(player, key, food.Id, levels)
	if levels > 0 then
		notify(player, levelUpText(def, key, newLevel, cap, "Feed"), "good", 5)
	else
		local need = xpToNext(newLevel)
		local progress = isFinite(need) and (" (" .. math.floor(newXp) .. "/" .. need .. " to Lv " .. (newLevel + 1) .. ")") or ""
		notify(player, petName(def, key) .. " ate a " .. food.Name .. ": +" .. math.floor(given) .. " XP" .. progress, "good", 3)
	end
	return true, { Xp = given, Levels = levels, Level = newLevel, Cap = cap }
end

function PetCareService.Feed(player, key, foodId)
	return feed(player, key, foodId)
end

-- the food a pet gets from the bowl: the best food the player has that does not overshoot the pet's cap (the
-- smallest one when every food would)
local function bowlFood(player, room)
	local best, smallest = nil, nil
	for _, f in ipairs(foodList()) do
		if getFood(player, f.Id) >= 1 then
			if f.Xp <= room and (not best or f.Xp > best.Xp) then
				best = f
			end
			if not smallest or f.Xp < smallest.Xp then
				smallest = f
			end
		end
	end
	return best or smallest
end

local function openPets(player)
	openPanelRemote = openPanelRemote or remote("OpenPanel")
	if openPanelRemote then
		pcall(function()
			openPanelRemote:FireClient(player, "Pets", { Tab = "Pets", Action = "Feed" })
		end)
	end
end

-- the FeedBowl: every pet that follows the player eats one food
local function feedFollowers(player)
	local profile = getProfile(player)
	if not profile then
		return false, "Your save is still loading..."
	end
	local keys = nil
	if petService and type(petService.GetEquipped) == "function" then
		local ok, list = pcall(petService.GetEquipped, player)
		if ok and type(list) == "table" then
			keys = list
		end
	end
	if not keys then
		keys = type(profile.Equipped) == "table" and profile.Equipped or {}
	end
	if #keys == 0 then
		openPets(player)
		return false, "Equip a pet: the pets that follow you eat from the bowl"
	end
	local anyFood = false
	for _, f in ipairs(foodList()) do
		if getFood(player, f.Id) >= 1 then
			anyFood = true
			break
		end
	end
	if not anyFood then
		return false, "No pet food yet: cook some at the Kitchen counter"
	end
	local fedCount, lastWhy = 0, nil
	local seen = {}
	for _, key in ipairs(keys) do
		if type(key) == "string" and not seen[key] then
			seen[key] = true
			local def = defOf(key, profile)
			if def then
				local level, have = petLevel(player, key)
				local room = xpRoom(level, have, levelCap(def))
				local food = room > 0 and bowlFood(player, room) or nil
				if food then
					local ok, result = feed(player, key, food.Id)
					if ok then
						fedCount = fedCount + 1
					else
						lastWhy = result
					end
				elseif room <= 0 then
					lastWhy = petName(def, key) .. " is at its max level (Lv " .. levelCap(def) .. ")"
				end
			end
		end
	end
	if fedCount == 0 then
		return false, lastWhy or "Your pets cannot eat right now"
	end
	return true, fedCount
end

----------------------------------------------------------------------
-- Gym
----------------------------------------------------------------------

local function gymOf(player)
	local g = gyms[player]
	if not g then
		g = { Pending = {}, Capped = {}, LastTick = nil, LastGrant = os.clock() }
		gyms[player] = g
	end
	return g
end

local function wholeSlot(slot)
	if type(slot) == "string" and #slot <= 3 and string.find(slot, "^%d+$") then
		slot = tonumber(slot)
	end
	if not isFinite(slot) or slot ~= math.floor(slot) or slot < 1 or slot > MAX_SLOT then
		return nil
	end
	return slot
end

local function gardenKeys(home)
	local set = {}
	if type(home) == "table" and type(home.Garden) == "table" then
		for _, key in pairs(home.Garden) do
			if type(key) == "string" then
				set[key] = true
			end
		end
	end
	return set
end

-- { [slot] = key } of the pets that really train: unlocked slots, owned Combat pets, once each, not in the Garden
local function trainingPets(home, profile)
	local out = {}
	local gym = type(home) == "table" and home.Gym
	if type(gym) ~= "table" then
		return out
	end
	local inGarden = gardenKeys(home)
	local seen = {}
	for slot = 1, gymSlots(home) do
		local key = gym[slot]
		if type(key) == "string" and not seen[key] and not inGarden[key] then
			seen[key] = true
			local def = defOf(key, profile)
			if def and def.Role == "Combat" and ownedCount(profile, key) >= 1 then
				out[slot] = key
			end
		end
	end
	return out
end

local function slotText(map)
	local slots = {}
	for slot in pairs(map) do
		slots[#slots + 1] = slot
	end
	table.sort(slots)
	local parts = {}
	for _, slot in ipairs(slots) do
		parts[#parts + 1] = tostring(slot) .. "=" .. map[slot]
	end
	return table.concat(parts, ";")
end

local function clearGymShown(player)
	local shown = gymShown[player]
	gymShown[player] = nil
	if shown and typeof(shown.Folder) == "Instance" then
		setAttr(shown.Folder, ATTR_GYM, nil)
		if shown.Info and homeBuilder and type(homeBuilder.SetGym) == "function" then
			pcall(homeBuilder.SetGym, shown.Info, {})
		end
	end
end

-- GymPets on the plot folder (+ HomeBuilder.SetGym when it exists), written only when it changes
local function publishGym(player, home, profile)
	local info = plotOf(player)
	local folder = info and info.Folder
	if typeof(folder) ~= "Instance" then
		clearGymShown(player)
		return
	end
	local shown = gymShown[player]
	if shown and shown.Folder ~= folder then
		clearGymShown(player)
		shown = nil
	end
	home = home or getHome(player)
	if not home then
		return
	end
	local valid = trainingPets(home, profile or getProfile(player))
	local text = slotText(valid)
	if shown and shown.Text == text then
		return
	end
	gymShown[player] = { Folder = folder, Info = info, Text = text }
	setAttr(folder, ATTR_GYM, text)
	if homeBuilder and type(homeBuilder.SetGym) == "function" then
		local ok, err = pcall(homeBuilder.SetGym, info, valid)
		if not ok then
			warn("[PetCareService] HomeBuilder.SetGym failed: " .. tostring(err))
		end
	end
end

-- pending Gym XP -> real XP (whole points; the fraction waits for the next grant)
local function grantGym(player, g)
	for key, pending in pairs(g.Pending) do
		local whole = math.floor(pending)
		if whole >= 1 then
			local given, levels, why, newLevel, _, cap, def = grantXp(player, key, whole, "Gym")
			if given > 0 then
				g.Pending[key] = pending - given
				if levels > 0 and def then
					notify(player, levelUpText(def, key, newLevel, cap, "Gym"), "good", 5)
				end
				if def and newLevel and cap and newLevel >= cap and not g.Capped[key] then
					g.Capped[key] = true
					notify(player, petName(def, key) .. " is at its max level: free its Gym slot for another pet", "info", 5)
				end
			else
				g.Pending[key] = nil
				if def and newLevel and cap and newLevel >= cap and not g.Capped[key] then
					g.Capped[key] = true
					notify(player, petName(def, key) .. " is at its max level: free its Gym slot for another pet", "info", 5)
				elseif why == "Your save is still loading..." then
					g.Pending[key] = pending -- keep it until the save is readable again
				end
			end
		end
	end
end

-- `claimed`: the home is claimed (training needs it, like the Collector's income); `home`: GetHome's copy or nil
local function tickGym(player, now, claimed, home)
	local g = gymOf(player)
	local last = g.LastTick or now
	local dt = math.max(0, math.min(now - last, MAX_TICK_DT))
	g.LastTick = now
	if claimed and dt > 0 then
		local perMinute = home and gymXpPerMinute(home) or 0
		if home and perMinute > 0 then
			local profile = getProfile(player)
			local valid = trainingPets(home, profile)
			for _, key in pairs(valid) do
				if not g.Capped[key] then
					g.Pending[key] = (g.Pending[key] or 0) + perMinute / 60 * dt
				end
			end
		end
	end
	if now - g.LastGrant >= GYM_GRANT_EVERY then
		g.LastGrant = now
		grantGym(player, g)
	end
end

function PetCareService.GymSet(player, slot, key)
	if not initialized then
		return false, "The Gym is not ready yet"
	end
	if not isPlayer(player) then
		return false, "Not in the game"
	end
	if key == "" or key == false then
		key = nil
	end
	if key ~= nil and not validKeyString(key) then
		return false, "Unknown pet"
	end
	local removeKey = nil
	if type(slot) == "string" and not wholeSlot(slot) then
		if key == nil and validKeyString(slot) then
			removeKey = slot -- GymSet(key): take that pet out of the Gym
			slot = nil
		else
			return false, "Unknown Gym slot"
		end
	end
	local auto = false
	if slot == nil or slot == 0 then
		if key == nil and removeKey == nil then
			return false, "Pick a pet to train"
		end
		auto = key ~= nil
		slot = nil
	else
		slot = wholeSlot(slot)
		if not slot then
			return false, "Unknown Gym slot"
		end
	end
	local home = getHome(player)
	if not home then
		return false, "Your home is still loading..."
	end
	local profile = getProfile(player)
	local def = nil
	if key ~= nil then
		local slots = gymSlots(home)
		if slots <= 0 then
			return false, "Build the Gym first"
		end
		if slot and slot > slots then
			return false, "Gym slot locked: upgrade the Gym"
		end
		def = defOf(key, profile)
		if not def then
			return false, "Unknown pet"
		end
		if def.Role ~= "Combat" then
			return false, "Only Combat pets can train in the Gym"
		end
		if ownedCount(profile, key) < 1 then
			return false, "You do not own that pet"
		end
	end

	local why, placed, removed, already = nil, nil, nil, false
	local wrote = mutateHome(player, function(live)
		if type(live.Gym) ~= "table" then
			live.Gym = {}
		end
		local gym = live.Gym
		if removeKey ~= nil then
			local found = false
			for s, k in pairs(gym) do
				if k == removeKey then
					gym[s] = nil
					found = true
				end
			end
			if not found then
				why = "That pet is not in the Gym"
				return false
			end
			removed = removeKey
			return true
		end
		if key == nil then
			if gym[slot] == nil then
				return false -- already empty
			end
			removed = gym[slot]
			gym[slot] = nil
			return true
		end
		local liveSlots = gymSlots(live)
		for _, k in pairs(type(live.Garden) == "table" and live.Garden or {}) do
			if k == key then
				why = "That pet is working in the Garden"
				return false
			end
		end
		local current = nil
		for s, k in pairs(gym) do
			if k == key then
				current = s
			end
		end
		local target = slot
		if auto then
			if current and type(current) == "number" and current <= liveSlots then
				already = true
				placed = current
				return false
			end
			for s = 1, liveSlots do
				if gym[s] == nil then
					target = s
					break
				end
			end
			if not target then
				why = "The Gym is full: upgrade it or free a slot"
				return false
			end
		end
		if target > liveSlots then
			why = "Gym slot locked: upgrade the Gym"
			return false
		end
		if gym[target] == key then
			already = true
			placed = target
			return false
		end
		if current ~= nil then
			gym[current] = nil -- one slot per pet: it moves
		end
		removed = gym[target]
		gym[target] = key
		placed = target
		return true
	end)
	if not wrote then
		if why then
			return false, why
		end
		if already and def then
			toastOnce(player, petName(def, key) .. " is already training", "info")
		end
		return true, nil -- nothing to change
	end
	local after = getHome(player)
	publishGym(player, after, getProfile(player))
	if key ~= nil then
		local g = gyms[player]
		if g then
			g.Capped[key] = nil
		end
		notify(player, petName(def, key) .. " is training in the Gym!", "good", 3)
	elseif removed then
		notify(player, petName(defOf(removed, profile), removed) .. " left the Gym", "info", 3)
	end
	PetCareService.GymChanged:Fire(player)
	return true, nil
end

----------------------------------------------------------------------
-- Kitchen prompts (Cook <food> above the counter, Feed pets at the FeedBowl)
----------------------------------------------------------------------

local function biggestPart(model)
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	local best, size = nil, -1
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local s = d.Size.X * d.Size.Y * d.Size.Z
			if s > size then
				best, size = d, s
			end
		end
	end
	return best
end

local function stationFrame(info, model)
	local def = catalog and type(catalog.Get) == "function" and catalog.Get("Kitchen") or nil
	local slot = def and def.Slot
	if typeof(info.PlotCFrame) == "CFrame" and slot and typeof(slot.CFrame) == "CFrame" then
		return info.PlotCFrame * slot.CFrame
	end
	return model:GetPivot()
end

local function newPrompt(parent, name, action, object, keys, ownerId)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.KeyboardKeyCode = keys.Keyboard
	prompt.GamepadKeyCode = keys.Gamepad
	prompt.HoldDuration = PROMPT_HOLD
	prompt.MaxActivationDistance = PROMPT_RANGE
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("OwnerUserId", ownerId)
	prompt:SetAttribute(CARE_MARK, true)
	prompt.Parent = parent
	return prompt
end

local function clearCarePrompts(model)
	for _, d in ipairs(model:GetDescendants()) do
		if d.Parent and d:GetAttribute(CARE_MARK) == true then
			d:Destroy()
		end
	end
end

-- Puts the cook prompts (one per recipe of this Kitchen level) and the bowl prompt on the owner's Kitchen.
local function ensurePrompts(player, info, home)
	local model = kitchenModel(info)
	if not model then
		return
	end
	local level = stationLevel(home, "Kitchen")
	local sig = tostring(level) .. ":" .. tostring(player.UserId)
	if model:GetAttribute(CARE_SIG) == sig then
		return
	end
	clearCarePrompts(model)
	local anchor = biggestPart(model)
	if not anchor then
		return
	end
	local frame = stationFrame(info, model)
	local recipes = {}
	for _, f in ipairs(foodList()) do
		if level >= (isFinite(f.KitchenLevel) and f.KitchenLevel or 1) then
			recipes[#recipes + 1] = f
		end
	end
	local n = math.min(#recipes, #COOK_KEYS)
	for i = 1, n do
		local f = recipes[i]
		local x = (i - (n + 1) / 2) * PROMPT_SPACING
		local att = Instance.new("Attachment")
		att.Name = "CookPoint_" .. f.Id
		att.CFrame = anchor.CFrame:ToObjectSpace(frame * CFrame.new(x, PROMPT_HEIGHT, PROMPT_DEPTH))
		att:SetAttribute(CARE_MARK, true)
		att.Parent = anchor
		local seconds = cookSeconds(f.Id, level) or f.CookSeconds or 0
		local prompt = newPrompt(att, "CookPrompt", "Cook " .. tostring(f.Name), money(f.Price) .. " - " .. duration(seconds), COOK_KEYS[i], player.UserId)
		prompt:SetAttribute("FoodId", f.Id)
		prompt:SetAttribute("StationId", "Kitchen")
	end
	local bowl = model:FindFirstChild("FeedBowl", true)
	if bowl and bowl:IsA("BasePart") then
		newPrompt(bowl, "FeedPrompt", "Feed pets", "Feeding bowl", COOK_KEYS[1], player.UserId)
	end
	model:SetAttribute(CARE_SIG, sig)
end

local function onPromptTriggered(prompt, player)
	if typeof(prompt) ~= "Instance" or not isPlayer(player) then
		return
	end
	local name = prompt.Name
	if name ~= "CookPrompt" and name ~= "FeedPrompt" then
		return
	end
	if prompt:GetAttribute(CARE_MARK) ~= true or prompt:GetAttribute("OwnerUserId") ~= player.UserId then
		return -- someone else's Kitchen (their prompts are disabled locally; never trust a stray trigger)
	end
	local info = plotOf(player)
	if not info or typeof(info.Folder) ~= "Instance" or not prompt:IsDescendantOf(info.Folder) then
		return
	end
	if not cooldown(player, "Prompt", PROMPT_COOLDOWN) or not spend(player) then
		return
	end
	local ok, reason
	if name == "CookPrompt" then
		ok, reason = PetCareService.Cook(player, prompt:GetAttribute("FoodId"), 1)
	else
		ok, reason = feedFollowers(player)
	end
	if not ok then
		toastOnce(player, reason or "Not now", "bad")
	end
end

----------------------------------------------------------------------
-- Extras
----------------------------------------------------------------------

-- Cap-aware XP for other services (battles in Phase 3): never past the pet's level cap. Returns xpGiven,
-- levelsGained, reason (nil when XP was given). A level-up fires LevelUp and shows the stats toast.
function PetCareService.GrantXp(player, key, xp, source)
	if not initialized then
		return 0, 0, "Pet care is not ready yet"
	end
	if not isPlayer(player) or not validKeyString(key) then
		return 0, 0, "Unknown pet"
	end
	local given, levels, why, newLevel, _, cap, def = grantXp(player, key, tonumber(xp), source or "Other")
	if levels > 0 and def then
		notify(player, levelUpText(def, key, newLevel, cap, source), "good", 5)
	end
	return given, levels, why
end

function PetCareService.LevelCap(player, key)
	local def = defOf(key, player and getProfile(player) or nil)
	if not def then
		return nil
	end
	return levelCap(def)
end

----------------------------------------------------------------------
-- Remote PetCare(action, a, b)
----------------------------------------------------------------------

local function onPetCare(player, action, a, b)
	if not isPlayer(player) or type(action) ~= "string" or #action > MAX_ACTION_LENGTH then
		return
	end
	if not spend(player) then
		return
	end
	if action == "Cook" then
		if not cooldown(player, "Cook", COOK_COOLDOWN) then
			return
		end
		local foodId, qty = a, b
		if type(a) == "table" then
			foodId = a.FoodId
			if foodId == nil then
				foodId = a[1]
			end
			qty = a.Qty
			if qty == nil then
				qty = a.Count
			end
			if qty == nil then
				qty = a[2]
			end
		end
		local ok, reason = PetCareService.Cook(player, foodId, qty)
		if not ok then
			toastOnce(player, reason or "You cannot cook that now", "bad")
		end
	elseif action == "Feed" then
		if not cooldown(player, "Feed", FEED_COOLDOWN) then
			return
		end
		local key, foodId = a, b
		if type(a) == "table" then
			key = a.Key
			if key == nil then
				key = a[1]
			end
			foodId = a.FoodId
			if foodId == nil then
				foodId = a[2]
			end
		end
		local ok, reason = feed(player, key, foodId)
		if not ok then
			toastOnce(player, reason or "That pet cannot eat now", "bad")
		end
	elseif action == "GymSet" then
		if not cooldown(player, "Gym", GYM_COOLDOWN) then
			return
		end
		local slot, key = a, b
		if type(a) == "table" then
			slot = a.Slot
			if slot == nil then
				slot = a[1]
			end
			key = a.Key
			if key == nil then
				key = a[2]
			end
		end
		local ok, reason = PetCareService.GymSet(player, slot, key)
		if not ok then
			toastOnce(player, reason or "That pet cannot train now", "bad")
		end
	end
end

----------------------------------------------------------------------
-- Tick + players
----------------------------------------------------------------------

local function tickPlayer(player, now)
	local k = kitchens[player]
	if k then
		tickKitchen(player, k, now)
	end
	local info = plotOf(player)
	local home = getHome(player) -- one copy per tick
	tickGym(player, now, hasHome(player), home)
	if info then
		if home then
			if stationLevel(home, "Kitchen") >= 1 then
				ensurePrompts(player, info, home)
			end
			publishGym(player, home, nil)
		end
	elseif gymShown[player] then
		clearGymShown(player)
	end
end

local function tickAll()
	local now = os.clock()
	for _, player in ipairs(Players:GetPlayers()) do
		if isPlayer(player) then
			local ok, err = pcall(tickPlayer, player, now)
			if not ok then
				warn("[PetCareService] tick failed: " .. tostring(err))
			end
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
			warn("[PetCareService] tick failed: " .. tostring(err))
		end
	end
end

local function onPlayerRemoving(player)
	departed[player] = true
	-- dishes that finished are delivered first, the rest is refunded (the Cash they cost)
	local k = kitchens[player]
	if k and #k.Queue > 0 then
		local ok, err = pcall(tickKitchen, player, k, os.clock())
		if not ok then
			warn("[PetCareService] last kitchen tick failed: " .. tostring(err))
		end
	end
	local ok, err = pcall(refundKitchen, player)
	if not ok then
		warn("[PetCareService] kitchen refund failed: " .. tostring(err))
	end
	clearGymShown(player)
	kitchens[player] = nil
	gyms[player] = nil
	cooldowns[player] = nil
	budgets[player] = nil
	toastAt[player] = nil
end

-- Server shutdown: refund every queue right away, then save those players once more. (DataService's own close
-- handler is bound earlier and may already have taken its snapshot; its per-entry save lock orders the two saves.)
local function onClose()
	local touched = {}
	for player, k in pairs(kitchens) do
		if #k.Queue > 0 then
			pcall(tickKitchen, player, k, os.clock())
			touched[#touched + 1] = player
		end
	end
	for _, player in ipairs(touched) do
		local ok, err = pcall(refundKitchen, player)
		if not ok then
			warn("[PetCareService] kitchen refund failed: " .. tostring(err))
		end
	end
	if #touched == 0 or not dataService or type(dataService.Save) ~= "function" then
		return
	end
	local pending = #touched
	for _, player in ipairs(touched) do
		task.spawn(function()
			pcall(dataService.Save, player)
			pending = pending - 1
		end)
	end
	local waited = 0
	while pending > 0 and waited < 20 do
		task.wait(0.1)
		waited = waited + 0.1
	end
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------

function PetCareService.Init(deps)
	if initialized then
		return
	end
	deps = deps or {}
	local services = script.Parent
	dataService = deps.DataService or requireModule(services, "DataService")
	petService = deps.PetService
	tycoonService = deps.TycoonService
	catalog = requireModule(Shared, "TycoonCatalog")
	petKeys = requireModule(Shared, "PetKeys")
	petCatalog = requireModule(Shared, "PetCatalog")
	if not catalog then
		warn("[PetCareService] TycoonCatalog is missing: the Kitchen, feeding and the Gym are disabled")
		return
	end
	if not dataService or type(dataService.AddPetXp) ~= "function" or type(dataService.AddFood) ~= "function" then
		warn("[PetCareService] DataService has no pet level / food API: the Kitchen, feeding and the Gym are disabled")
		return
	end
	homeBuilder = services and services:FindFirstChild("HomeBuilder") and requireModule(services, "HomeBuilder") or nil
	initialized = true

	local petCare = remote("PetCare")
	if petCare then
		petCare.OnServerEvent:Connect(onPetCare)
	else
		warn("[PetCareService] the PetCare remote is missing (Config.Remotes)")
	end
	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	local okClose, closeErr = pcall(function()
		game:BindToClose(onClose)
	end)
	if not okClose then
		warn("[PetCareService] BindToClose failed: " .. tostring(closeErr))
	end

	-- players who joined before Init need nothing special: their kitchen / gym state starts on the first tick
	running = true
	task.spawn(tickLoop)
end

return PetCareService
