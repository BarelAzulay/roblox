-- DataService: persistent player profile (tokens, pets, items, stats, the v3 Pet Index / tutorial and the Phase 2
-- tycoon: Cash, Gems, Home, Food, pet levels, tier copies and fused hybrids) for Nimbus Climb.
--
-- Profile shape (ARCHITECTURE_V2.md section 1, ARCHITECTURE_V3.md section 1 + section 11 + "Phase 2 build contract"):
--   { Version = 2, Tokens, Pets = {[petId]=count}, Equipped = {key...}, Items = {[itemId]=count},
--     Stats = { Matches, Wins, TokensEarned, Spins, BestTimes = {[difficultyId]=seconds} }, SpotIndex,
--     -- v3
--     Discovered = {[petId]=true}, IndexClaimed = {[groupId]=true}, Tutorial = { Step, Done, Gifted },
--     -- Phase 2
--     Cash, Gems,
--     Home = { Level, Prestige, Stations = {[stationId]=level}, Garden = {[slot]=key}, Gym = {[slot]=key},
--              CollectorCash, LastSeen },
--     Food = {[foodId]=count}, PetLevels = {[key]={Level, Xp}}, Tiers = {[petId]={Golden=n, Rainbow=n}},
--     Hybrids = {[uid]={Body, Style, Elements, Name, Rarity, Tier}}, GemReceipts = {[purchaseId]=os.time()},
--     Teams = (reserved for Phase 3: plain data, saved whole) }
--   Pet copies are identified by keys (shared/PetKeys.lua): "petId" (Normal), "petId@Golden", "petId@Rainbow",
--   "hyb:<uid>"; Equipped, PetLevels, Garden and Gym hold keys. Every plain petId of an old profile is a valid key.
--   Garden / Gym slots are whole numbers 1..64 (other valid string slot names are kept as they are).
--   Home.Rooms (the v3 reserve) was migrated into Home.Stations: in the live profile Home.Rooms is the SAME table as
--   Home.Stations (old code that touches Rooms still works); it is never written to the store again.
--   Every field is additive: a stored v2 / v3 profile lacks the newer fields and gets the defaults on load, and every
--   owned pet (Normal or tier copy) always counts as discovered. Version stays 2: no stored v2 field changed its
--   layout, so older tooling keeps reading it (older servers keep the new fields as foreign data, see below).
--
-- Design notes
--   * Everything runs from an in-memory cache, so the game is fully playable when DataStores are
--     unavailable (Studio without "Enable Studio Access to API Services", Roblox outages, ...).
--   * Saves are DELTA based. The cache remembers `Base` (what the store is known to contain);
--     a save sends only "live minus base" and merges it into whatever is stored right now inside
--     UpdateAsync. A failed load can therefore never wipe a saved profile and two servers touching
--     the same player cannot clobber each other. After a failed load, the next save (or a
--     background retry) re-reads the store and merges the session on top of it.
--     Merge rules: Discovered / IndexClaimed only ever grow (set union); Tutorial merges monotonically (Done and
--     Gifted stick once true) so a second server can never replay the tutorial gift; Tokens / Cash / Gems / Food
--     counts / Home.CollectorCash travel as +/- deltas; Home.Stations / Garden / Gym, Tiers, Hybrids and PetLevels
--     are replaced PER KEY when the session changed that key; GemReceipts only grow (bounded to the newest 100);
--     Teams are replaced whole. Home: a HIGHER Home.Prestige wins the whole Home (prestige resets the stations, so
--     the other side's per-station changes are void); at equal prestige the Home merges per key (Level replaced,
--     LastSeen the later one). The ONE exception is ResetFields (developer tools only): the fields it names are
--     written over the stored ones at the next successful save instead of merged.
--   * A PROVISIONAL profile (the load failed while the DataStore is reachable, e.g. an outage) holds
--     defaults, not the player's data. One-time rewards must not be decided from it: GetTutorial
--     answers nil and SetTutorial refuses until the background recovery read the real save (then
--     ProfileRebased fires and TutorialService starts from the stored progress), and
--     IsProvisional(player) lets IndexService / DevService refuse claims and resets meanwhile. That
--     is what keeps a failed load from replaying the tutorial gift / finish reward. Per-key data would be
--     overwritten by stand-in values the same way, so GetHome answers nil, MutateHome only lets delta-safe changes
--     (CollectorCash, LastSeen) through and AddPetXp / MarkReceipt refuse while provisional. Without a usable
--     store (Studio without API access) nothing is provisional: everything runs from memory.
--   * Forward compatibility: a save keeps every stored field this version does not know (top level,
--     inside Home and inside Stats) and a newer Version number, so a server still running an older build after
--     a later phase is published never erases that phase's data.
--   * v1 saves ({Tokens = n} in Config.Tokens.LegacyDataStoreName) are migrated once: when the v2
--     key is empty, the legacy key is read and its tokens become the starting balance. The legacy
--     store is never written.
--   * A leaving player's cache entry is only freed once the store holds everything it knows. If the
--     final save failed (outage, throttling, lock timeout, failed load that cannot be recovered), the
--     entry is kept as an "orphan": it is retried in the background with backoff, flushed by the
--     autosave sweep (which walks the cache, not the player list) and by BindToClose, and a quick
--     rejoin simply picks it up again. It is only dropped after a successful write or after
--     ORPHAN_TIMEOUT seconds. DataService alone makes this decision (Release); callers just call it.
--   * The store never holds a sparse array: Garden / Gym are written as arrays with "" for empty slots (or a map
--     with string keys when a slot has a name); empty Phase 2 maps (Food, Tiers, Hybrids, GemReceipts, Teams) are
--     left out of the record. ProfileSync uses the same slot encoding (client State decodes it).
--
-- Public API
--   Load(player) -> live profile, GetProfile(player), MarkDirty(player), Sync(player), Save(player),
--   StartAutosave(), BindToClose(), AddTokens / SpendTokens / GetTokens, RecordMatch, signal ProfileLoaded.
--   v3: MarkDiscovered(player, petId) -> isNew (marks dirty; the caller Syncs, PetService does right after a roll),
--     GetTutorial(player) -> copy | nil until loaded (and while provisional), SetTutorial(player, t) -> ok
--     (MarkDirty + Sync; Gifted never goes back to false; false while provisional).
--   Phase 2 (all mark the profile dirty; never yield; the balance checks and writes are atomic):
--     GetHome(player) -> deep copy of Home (Garden / Gym keyed by slot number) | nil until loaded / while provisional
--     MutateHome(player, fn) -> ok      fn(home) edits the LIVE Home table and must not yield. It runs under pcall:
--                                       an error, or fn returning false, restores the Home as it was (-> false).
--                                       Afterwards the Home is sanitised in place; a change the client can see
--                                       (anything but CollectorCash / LastSeen) is synced (throttled, see below).
--     AddCash(player, n) -> ok          n > 0 (fractions allowed: income math; the store keeps whole units)
--     SpendCash(player, n) -> ok        false (nothing taken) when the balance is short; never negative
--     GetCash(player) -> whole cash
--     AddGems / SpendGems / GetGems     the same for Gems (whole numbers)
--     AddFood(player, foodId, n) -> ok, SpendFood(player, foodId, n) -> ok, GetFood(player, foodId) -> count
--                                       (GetFood(player) -> a copy of the whole map); Food changes are synced
--     GetPetLevel(player, key) -> level, xp       (1, 0 for a pet that never gained XP)
--     AddPetXp(player, key, xp) -> levelsGained   owned copies only; the curve is TycoonCatalog.XpToNext(level)
--                                       (a local fallback when that module is missing); synced
--     The player attributes Config.Attr.Cash / Config.Attr.Gems mirror the (whole) balances for the HUD.
--   ProfileSync snapshot: Tokens, Pets, Equipped, Items, Stats, SpotIndex, Perks, Discovered, IndexClaimed,
--     Tutorial + Phase 2: Cash, Gems, Home { Level, Prestige, Stations, Garden, Gym, CollectorCash } (slot maps
--     encoded like the store), Food, Tiers, Hybrids, PetLevels. Plain tables, never shared with the live profile.
--   Extras (used by PetService / IndexService / DevService / GemService, harmless otherwise): Release(player), Init(),
--     ComputePerks(equippedKeys, profile|nil), IsDiscovered(player, petId), IsProvisional(player),
--     ResetFields(player, { Discovered, IndexClaimed, Tutorial, BestTimes, Home, Tiers, Hybrids, PetLevels = true })
--     -> ok (the session's CURRENT values of those fields replace the stored ones at the next successful save),
--     HasReceipt(player, purchaseId) -> bool | nil, MarkReceipt(player, purchaseId) -> true (new: grant now) |
--     false (already processed: grant nothing) | nil (not decidable now: profile not loaded or provisional -> answer
--     NotProcessedYet), SyncSoon(player) (a throttled Sync: at most one snapshot per 0.25 s, trailing call kept),
--     signal ProfileRebased(player, profile).
--
-- Plain Lua 5.1-compatible syntax only.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local DataService = {}

-- Fired after a profile finished loading: (player, profile). Handlers run on their own thread.
DataService.ProfileLoaded = Util.Signal()
-- Fired when the live profile was replaced by newer stored data (recovered failed load, or another
-- server changed the save): (player, profile). PetService re-validates its attributes on this.
DataService.ProfileRebased = Util.Signal()

local PROFILE_VERSION = 2
local RETRY_DELAY = 1.5 -- seconds between the two attempts of a read/write
local MAX_COUNT = 1000000000 -- sanity cap for tokens and stats
local MAX_CASH = 1000000000000000 -- 1e15: tycoon money grows large; still an exact integer in a double
local MAX_FOOD = 1000000 -- per food type
local MAX_KEY_LENGTH = 48
local MAX_SLOT = 64 -- Garden / Gym slot numbers 1..MAX_SLOT
local MAX_RECEIPTS = 100 -- GemReceipts keeps the newest processed purchase ids
local MAX_TIME = 100000000000 -- sanity cap for os.time() stamps (LastSeen, receipts)
local REQUEST_COOLDOWN = 0.5 -- RequestProfile rate limit (seconds per player)
local SYNC_GAP = 0.25 -- SyncSoon: at most one snapshot per this many seconds per player
local ORPHAN_RETRY_FIRST = 10 -- seconds before the first background retry of an unsaved, departed profile
local ORPHAN_RETRY_MAX = 120 -- the retry delay doubles up to this
local ORPHAN_TIMEOUT = 1800 -- give up on (and drop) a departed profile that still cannot be saved after this long
local IS_STUDIO = RunService:IsStudio()
local STAT_KEYS = { "Matches", "Wins", "TokensEarned", "Spins" }
local MAX_TUTORIAL_STEP = 1000 -- sanity cap for Tutorial.Step (TutorialService clamps to its own step count)
local MAX_LEVEL = 100000 -- sanity cap for home / station / pet levels and prestige
local DEFAULT_MAX_PET_LEVEL = 100 -- AddPetXp cap when TycoonCatalog does not name one
local PLAIN_DEPTH = 5 -- Teams (reserved) are kept as plain data up to this depth
local TIER_NAMES = { "Golden", "Rainbow" }
local VALID_TIER = { Normal = true, Golden = true, Rainbow = true }

-- Fields ResetFields may write over the store (everything else already follows a reset through the normal delta).
-- GemReceipts are deliberately not resettable: they keep developer-product purchases from being granted twice.
local OVERWRITABLE = {
	Discovered = true, IndexClaimed = true, Tutorial = true, BestTimes = true,
	Home = true, Tiers = true, Hybrids = true, PetLevels = true,
}
-- Stored keys this version owns. Anything else in a stored profile belongs to a newer phase and is written back
-- untouched by every save (see keepForeign).
local KNOWN_TOP = {
	Version = true, Tokens = true, Pets = true, Equipped = true, Items = true, Stats = true, SpotIndex = true,
	Discovered = true, IndexClaimed = true, Tutorial = true, Cash = true, Gems = true, Home = true, PetLevels = true,
	Food = true, Tiers = true, Hybrids = true, GemReceipts = true, Teams = true,
	UpdatedAt = true,
}
local KNOWN_HOME = {
	Level = true, Rooms = true, Prestige = true, Stations = true, Garden = true, Gym = true, CollectorCash = true,
	LastSeen = true,
}
local KNOWN_STATS = { Matches = true, Wins = true, TokensEarned = true, Spins = true, BestTimes = true }

-- cache[userId] = {
--   Profile = live profile table (what every other module reads and mutates),
--   Base = profile the store is known to contain (delta reference),
--   Owner = the Player instance the entry was last announced to (a quick rejoin gets a new one),
--   Loaded, Loading, LoadFailed, Saving, Dirty, RecoveryScheduled = bool flags,
--   Orphan = true while the player is gone but the entry still holds unsaved progress,
--   OrphanSince = os.clock() when it became an orphan, OrphanScheduled = a background retry loop runs,
--   Overwrite = { [field] = true } fields ResetFields asked to write over the store (nil when none is pending;
--     cleared only after a successful write, so orphan retries and BindToClose carry it too),
--   OverwriteGen = counter bumped by every ResetFields (a reset during an in-flight save stays pending),
--   LastSync = os.clock() of the last ProfileSync, SyncQueued = a trailing SyncSoon is scheduled
-- }
local cache = {}
local store = nil
local storeResolved = false
local legacyStore = nil
local legacyResolved = false
local storeDisabled = false -- true once the DataStore API is known to be unusable (Studio)
local autosaveStarted = false
local closeBound = false
local shuttingDown = false
local playerHooked = false
local requestHooked = false
local remoteCache = {}
local lastRequest = {} -- [userId] = os.clock() of the last accepted RequestProfile

----------------------------------------------------------------------
-- Optional shared modules (written by other engineers; resolved lazily, every use is guarded)
----------------------------------------------------------------------

local optionalModules = {}
local function getShared(name)
	local entry = optionalModules[name]
	if entry == nil then
		entry = false
		local module = Shared:FindFirstChild(name)
		if module then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				entry = result
			else
				warn("[DataService] " .. name .. " failed to load: " .. tostring(result))
			end
		end
		optionalModules[name] = entry
	end
	return entry or nil
end

local function getPetCatalog()
	return getShared("PetCatalog")
end

local function getPetKeys()
	return getShared("PetKeys")
end

local function getTycoonCatalog()
	return getShared("TycoonCatalog")
end

-- resolve PetKeys now (DataService's pure merge code counts equipped copies with it inside UpdateAsync)
getPetKeys()

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function keyFor(userId)
	return "u_" .. tostring(userId)
end

local function isFinite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Any value -> non-negative integer within sane bounds.
local function sanitize(n)
	if not isFinite(n) or n < 0 then
		return 0
	end
	if n > MAX_COUNT then
		return MAX_COUNT
	end
	return math.floor(n)
end

local function clampCount(n, maxCount)
	local value = sanitize(n)
	if value > maxCount then
		return maxCount
	end
	return value
end

-- Cash -> whole units in 0..MAX_CASH (the store and the snapshot hold whole cash).
local function sanitizeCash(n)
	if not isFinite(n) or n < 0 then
		return 0
	end
	if n > MAX_CASH then
		return MAX_CASH
	end
	return math.floor(n)
end

-- Cash for the LIVE profile: clamped, fractions kept (per-second income accumulates in fractions).
local function clampCash(n)
	if not isFinite(n) or n < 0 then
		return 0
	end
	if n > MAX_CASH then
		return MAX_CASH
	end
	return n
end

local function sanitizeTime(n)
	if not isFinite(n) or n < 0 then
		return 0
	end
	if n > MAX_TIME then
		return MAX_TIME
	end
	return math.floor(n)
end

-- Seconds for BestTimes: finite, > 0, rounded to 1/100 s. Returns nil when unusable.
local function sanitizeSeconds(n)
	if not isFinite(n) or n <= 0 or n > 10000000 then
		return nil
	end
	return math.floor(n * 100 + 0.5) / 100
end

local function validKey(key)
	return type(key) == "string" and #key > 0 and #key <= MAX_KEY_LENGTH
end

-- hybrid uids: letters, digits, "_" and "-" (they live inside keys and csv attributes)
local function validUid(uid)
	return type(uid) == "string" and #uid >= 1 and #uid <= 24 and string.find(uid, "^[%w_%-]+$") ~= nil
end

local function copyMap(map)
	local out = {}
	if type(map) ~= "table" then
		return out
	end
	for key, value in pairs(map) do
		out[key] = value
	end
	return out
end

local function copyList(list)
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	for i, value in ipairs(list) do
		out[i] = value
	end
	return out
end

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = deepCopy(v)
	end
	return out
end

local function deepEqual(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function mapsEqual(a, b)
	for key, value in pairs(a) do
		if b[key] ~= value then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function listsEqual(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function tableOr(t)
	if type(t) == "table" then
		return t
	end
	return {}
end

----------------------------------------------------------------------
-- Profile construction / validation
----------------------------------------------------------------------

local function newTutorial()
	return { Step = 1, Done = false, Gifted = false }
end

-- Home.Rooms is the same table as Home.Stations (the v3 name, kept for old code).
local function newHome()
	local stations = {}
	return {
		Level = 0,
		Prestige = 0,
		Stations = stations,
		Rooms = stations,
		Garden = {},
		Gym = {},
		CollectorCash = 0,
		LastSeen = 0,
	}
end

local function newProfile()
	return {
		Version = PROFILE_VERSION,
		Tokens = 0,
		Pets = {},
		Equipped = {},
		Items = {},
		Stats = { Matches = 0, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = {} },
		SpotIndex = nil,
		-- v3 (ARCHITECTURE_V3.md section 1)
		Discovered = {},
		IndexClaimed = {},
		Tutorial = newTutorial(),
		-- Phase 2 (ARCHITECTURE_V3.md "Phase 2 build contract"); Teams is reserved for Phase 3
		Cash = 0,
		Gems = 0,
		Home = newHome(),
		PetLevels = {},
		Food = {},
		Tiers = {},
		Hybrids = {},
		GemReceipts = {},
		Teams = {},
	}
end

-- Untrusted tutorial table -> a clean copy { Step >= 1, Done, Gifted }.
local function cleanTutorial(raw)
	local t = newTutorial()
	if type(raw) == "table" then
		local step = raw.Step
		if isFinite(step) and step >= 1 then
			t.Step = math.min(math.floor(step), MAX_TUTORIAL_STEP)
		end
		t.Done = raw.Done == true
		t.Gifted = raw.Gifted == true
	end
	return t
end

local function tutorialsEqual(a, b)
	return a.Step == b.Step and a.Done == b.Done and a.Gifted == b.Gifted
end

-- Untrusted pet level entry -> { Level >= 1, Xp >= 0 } (a bare number is read as the level), or nil.
local function cleanPetLevel(raw)
	local level, xp
	if type(raw) == "table" then
		level, xp = raw.Level, raw.Xp
	elseif isFinite(raw) then
		level, xp = raw, 0
	else
		return nil
	end
	if not isFinite(level) or level < 1 then
		level = 1
	end
	return { Level = math.min(math.floor(level), MAX_LEVEL), Xp = sanitize(xp) }
end

local function copyPetLevels(map)
	local out = {}
	for id, entry in pairs(tableOr(map)) do
		local clean = validKey(id) and cleanPetLevel(entry)
		if clean then
			out[id] = clean
		end
	end
	return out
end

-- { [validKey] = 1..cap } (zero / junk entries dropped)
local function cleanCounts(raw, cap)
	local out = {}
	for key, value in pairs(tableOr(raw)) do
		if validKey(key) and isFinite(value) then
			local n = clampCount(value, cap)
			if n > 0 then
				out[key] = n
			end
		end
	end
	return out
end

-- Garden / Gym slot id: a whole number 1..MAX_SLOT (also from a numeric string), or a valid string name.
local function slotId(key)
	local n = key
	if type(key) == "string" and string.find(key, "^%d+$") then
		n = tonumber(key)
	end
	if type(n) == "number" then
		if n == n and n >= 1 and n <= MAX_SLOT and n == math.floor(n) then
			return n
		end
		return nil
	end
	if validKey(key) then
		return key
	end
	return nil
end

-- Untrusted slot map (map, list, or a stored array with "" holes) -> { [slot] = key }.
local function cleanSlots(raw)
	local out = {}
	for key, value in pairs(tableOr(raw)) do
		local slot = slotId(key)
		if slot ~= nil and validKey(value) then
			out[slot] = value
		end
	end
	return out
end

-- { [slot] = key } -> a storable / sendable table: an array with "" for empty slots when every slot is a number,
-- otherwise a map with string keys (stores and remotes mangle sparse arrays).
local function encodeSlots(map)
	local allNumbers, maxSlot = true, 0
	for slot in pairs(map) do
		if type(slot) == "number" then
			if slot > maxSlot then
				maxSlot = slot
			end
		else
			allNumbers = false
		end
	end
	local out = {}
	if allNumbers then
		for i = 1, maxSlot do
			out[i] = map[i] or ""
		end
	else
		for slot, key in pairs(map) do
			out[tostring(slot)] = key
		end
	end
	return out
end

local function cleanStations(raw)
	local out = {}
	for key, value in pairs(tableOr(raw)) do
		if validKey(key) and isFinite(value) then
			local level = clampCount(value, MAX_LEVEL)
			if level > 0 then
				out[key] = level
			end
		end
	end
	return out
end

-- Untrusted home -> a clean home (whole numbers). `migrate`: stored data, so the v3 reserve Home.Rooms is folded
-- into Stations (the higher level wins). The live profile is never migrated again: there Rooms IS Stations.
local function cleanHome(raw, migrate)
	local h = tableOr(raw)
	local home = newHome()
	home.Level = clampCount(h.Level, MAX_LEVEL)
	home.Prestige = clampCount(h.Prestige, MAX_LEVEL)
	local stations = h.Stations
	if type(stations) ~= "table" and not migrate then
		stations = h.Rooms -- a live home whose Stations table was dropped: Rooms is the same table
	end
	for key, level in pairs(cleanStations(stations)) do
		home.Stations[key] = level
	end
	if migrate and type(h.Rooms) == "table" and h.Rooms ~= h.Stations then
		for key, level in pairs(cleanStations(h.Rooms)) do
			if level > (home.Stations[key] or 0) then
				home.Stations[key] = level
			end
		end
	end
	home.Garden = cleanSlots(h.Garden)
	home.Gym = cleanSlots(h.Gym)
	home.CollectorCash = sanitizeCash(h.CollectorCash)
	home.LastSeen = sanitizeTime(h.LastSeen)
	return home
end

local function homesEqual(a, b)
	return a.Level == b.Level
		and a.Prestige == b.Prestige
		and a.CollectorCash == b.CollectorCash
		and a.LastSeen == b.LastSeen
		and mapsEqual(a.Stations, b.Stations)
		and mapsEqual(a.Garden, b.Garden)
		and mapsEqual(a.Gym, b.Gym)
end

-- what the client sees of a home (CollectorCash / LastSeen changes alone are not worth a snapshot)
local function homeVisiblyEqual(a, b)
	return a.Level == b.Level
		and a.Prestige == b.Prestige
		and mapsEqual(a.Stations, b.Stations)
		and mapsEqual(a.Garden, b.Garden)
		and mapsEqual(a.Gym, b.Gym)
end

-- { [petId] = { Golden = n, Rainbow = n } } with positive counts only
local function cleanTiers(raw)
	local out = {}
	local cap = Config.Pets.MaxPerStack
	for petId, entry in pairs(tableOr(raw)) do
		if validKey(petId) and type(entry) == "table" then
			local clean = nil
			for _, tier in ipairs(TIER_NAMES) do
				local n = isFinite(entry[tier]) and clampCount(entry[tier], cap) or 0
				if n > 0 then
					clean = clean or {}
					clean[tier] = n
				end
			end
			if clean then
				out[petId] = clean
			end
		end
	end
	return out
end

-- One fused hybrid record { Body, Style, Elements, Name?, Rarity?, Tier } (+ up to 8 extra scalar fields the fusion
-- code may keep, e.g. a look seed), or nil. Lenient on purpose: the store keeps what the game made.
local function cleanHybrid(raw)
	if type(raw) ~= "table" or not validKey(raw.Body) or not validKey(raw.Style) then
		return nil
	end
	local rec = { Body = raw.Body, Style = raw.Style, Elements = {}, Tier = "Normal" }
	if VALID_TIER[raw.Tier] then
		rec.Tier = raw.Tier
	end
	local seen = {}
	for _, e in ipairs(tableOr(raw.Elements)) do
		if validKey(e) and not seen[e] and #rec.Elements < 4 then
			seen[e] = true
			rec.Elements[#rec.Elements + 1] = e
		end
	end
	if type(raw.Name) == "string" and #raw.Name >= 1 and #raw.Name <= 32 then
		rec.Name = raw.Name
	end
	if validKey(raw.Rarity) then
		rec.Rarity = raw.Rarity
	end
	local extras = 0
	for k, v in pairs(raw) do
		if rec[k] == nil and k ~= "Name" and k ~= "Rarity" and type(k) == "string" and #k <= 24 and extras < 8 then
			if isFinite(v) or type(v) == "boolean" or (type(v) == "string" and #v <= 64) then
				rec[k] = v
				extras = extras + 1
			end
		end
	end
	return rec
end

local function cleanHybrids(raw)
	local out = {}
	for uid, rec in pairs(tableOr(raw)) do
		local clean = validUid(uid) and cleanHybrid(rec)
		if clean then
			out[uid] = clean
		end
	end
	return out
end

-- Trims a receipt map (in place) to MAX_RECEIPTS entries by evicting the oldest ones (ties: the smaller id).
-- Ids in `keep` (the receipts just processed) are never evicted, so a fresh receipt always survives its own save.
local function trimReceipts(map, keep)
	local list = {}
	local total = 0
	for id, t in pairs(map) do
		total = total + 1
		if not (keep and keep[id]) then
			list[#list + 1] = { Id = id, T = t }
		end
	end
	if total <= MAX_RECEIPTS then
		return map
	end
	table.sort(list, function(a, b)
		if a.T ~= b.T then
			return a.T < b.T
		end
		return a.Id < b.Id
	end)
	local i = 1
	while total > MAX_RECEIPTS and list[i] do
		map[list[i].Id] = nil
		total = total - 1
		i = i + 1
	end
	return map
end

-- { [purchaseId] = os.time() of processing } (a stored `true` counts as time 0). `trim`: bounded to MAX_RECEIPTS
-- (stored data); the live map is bounded by MarkReceipt and copied whole, so a fresh receipt always reaches the delta.
local function cleanReceipts(raw, trim)
	local out = {}
	for id, value in pairs(tableOr(raw)) do
		if validKey(id) then
			if value == true then
				out[id] = 0
			elseif isFinite(value) then
				out[id] = sanitizeTime(value)
			end
		end
	end
	if trim then
		trimReceipts(out)
	end
	return out
end

-- Reserved data (Teams): plain copy (strings, finite numbers, booleans; string / number keys), depth-limited.
local function cleanPlain(raw, depth)
	depth = depth or 0
	local t = type(raw)
	if t == "string" then
		if #raw <= 200 then
			return raw
		end
		return nil
	elseif t == "boolean" then
		return raw
	elseif t == "number" then
		if isFinite(raw) then
			return raw
		end
		return nil
	elseif t ~= "table" or depth >= PLAIN_DEPTH then
		return nil
	end
	local out = {}
	local n = 0
	for k, v in pairs(raw) do
		local kt = type(k)
		if (kt == "string" and #k <= MAX_KEY_LENGTH) or (kt == "number" and isFinite(k)) then
			local clean = cleanPlain(v, depth + 1)
			if clean ~= nil and n < 64 then
				out[k] = clean
				n = n + 1
			end
		end
	end
	return out
end

-- Teams (reserved for Phase 3): always a table of plain data
local function cleanTeams(raw)
	local t = cleanPlain(raw)
	if type(t) ~= "table" then
		return {}
	end
	return t
end

-- Set-like map { [key] = true } with valid keys only (a stored list of ids is accepted as well).
local function cleanSet(raw)
	local out = {}
	if type(raw) ~= "table" then
		return out
	end
	for key, value in pairs(raw) do
		if validKey(key) and value == true then
			out[key] = true
		elseif type(key) == "number" and validKey(value) then
			out[value] = true
		end
	end
	return out
end

-- Every owned pet counts as discovered (v3 migration rule, kept as an invariant): Normal copies and tier copies.
local function discoverOwned(profile)
	for id, count in pairs(profile.Pets) do
		if validKey(id) and type(count) == "number" and count > 0 then
			profile.Discovered[id] = true
		end
	end
	for id in pairs(tableOr(profile.Tiers)) do
		if validKey(id) then
			profile.Discovered[id] = true
		end
	end
end

-- copies of `key` the profile owns (PetKeys.Count; plain Pets counts without that module)
local function ownedCount(profile, key)
	local keys = getPetKeys()
	if keys and type(keys.Count) == "function" then
		local ok, n = pcall(keys.Count, profile, key)
		if ok and type(n) == "number" then
			return n
		end
		return 0
	end
	local pets = tableOr(profile.Pets)
	local n = pets[key]
	if type(n) == "number" then
		return n
	end
	return 0
end

-- Drops equipped keys that are not owned, are over their owned count, or exceed the slot limit.
-- (Runs after Pets, Tiers and Hybrids are final: tier and hybrid copies count too.)
local function normalizeEquipped(profile)
	local out = {}
	local used = {}
	local maxEquipped = Config.Pets.MaxEquipped
	for _, id in ipairs(profile.Equipped) do
		if type(id) == "string" and #out < maxEquipped then
			local owned = ownedCount(profile, id)
			local count = used[id] or 0
			if count < owned then
				used[id] = count + 1
				table.insert(out, id)
			end
		end
	end
	profile.Equipped = out
end

-- Live (possibly messy) profile -> clean profile with whole numbers. Read defensively: other modules mutate it.
local function copyProfile(p)
	local out = newProfile()
	out.Tokens = p.Tokens
	out.Pets = copyMap(p.Pets)
	out.Equipped = copyList(p.Equipped)
	out.Items = copyMap(p.Items)
	for _, key in ipairs(STAT_KEYS) do
		out.Stats[key] = p.Stats[key]
	end
	out.Stats.BestTimes = copyMap(p.Stats.BestTimes)
	out.SpotIndex = p.SpotIndex
	-- v3
	out.Tiers = cleanTiers(p.Tiers) -- before discoverOwned: tier copies count as discovered too
	out.Discovered = cleanSet(p.Discovered)
	discoverOwned(out) -- a pet granted without MarkDiscovered still saves as discovered
	out.IndexClaimed = cleanSet(p.IndexClaimed)
	out.Tutorial = cleanTutorial(p.Tutorial)
	-- Phase 2
	out.Cash = sanitizeCash(p.Cash)
	out.Gems = sanitize(p.Gems)
	out.Home = cleanHome(p.Home, false)
	out.PetLevels = copyPetLevels(p.PetLevels)
	out.Food = cleanCounts(p.Food, MAX_FOOD)
	out.Hybrids = cleanHybrids(p.Hybrids)
	out.GemReceipts = cleanReceipts(p.GemReceipts)
	out.Teams = cleanTeams(p.Teams)
	return out
end

-- Untrusted stored value (nil / number / v1 table / v2 table / v3 table / Phase 2 table) -> clean profile. Pure.
local function normalizeProfile(raw)
	local p = newProfile()
	if type(raw) == "number" then
		p.Tokens = sanitize(raw)
		return p
	end
	if type(raw) ~= "table" then
		return p
	end
	p.Tokens = sanitize(raw.Tokens)
	if type(raw.Pets) == "table" then
		for id, n in pairs(raw.Pets) do
			if validKey(id) then
				local count = clampCount(n, Config.Pets.MaxPerStack)
				if count > 0 then
					p.Pets[id] = count
				end
			end
		end
	end
	if type(raw.Items) == "table" then
		for id, n in pairs(raw.Items) do
			if validKey(id) then
				local count = clampCount(n, Config.Items.MaxCarry)
				if count > 0 then
					p.Items[id] = count
				end
			end
		end
	end
	if type(raw.Equipped) == "table" then
		for _, id in ipairs(raw.Equipped) do
			if type(id) == "string" then
				table.insert(p.Equipped, id)
			end
		end
	end
	if type(raw.Stats) == "table" then
		for _, key in ipairs(STAT_KEYS) do
			p.Stats[key] = sanitize(raw.Stats[key])
		end
		if type(raw.Stats.BestTimes) == "table" then
			for id, seconds in pairs(raw.Stats.BestTimes) do
				local clean = sanitizeSeconds(seconds)
				if validKey(id) and clean then
					p.Stats.BestTimes[id] = clean
				end
			end
		end
	end
	local spot = raw.SpotIndex
	if isFinite(spot) and spot >= 1 and spot <= Config.Lobby.SpotCount and spot == math.floor(spot) then
		p.SpotIndex = spot
	end
	-- Phase 2 copies first: the equipped list may hold tier / hybrid keys
	p.Tiers = cleanTiers(raw.Tiers)
	p.Hybrids = cleanHybrids(raw.Hybrids)
	normalizeEquipped(p)
	-- v3 fields (absent in v2 saves: the defaults from newProfile stay)
	p.Discovered = cleanSet(raw.Discovered)
	discoverOwned(p) -- migration: owned pets count as discovered
	p.IndexClaimed = cleanSet(raw.IndexClaimed)
	p.Tutorial = cleanTutorial(raw.Tutorial)
	p.Cash = sanitizeCash(raw.Cash)
	p.Gems = sanitize(raw.Gems)
	p.Home = cleanHome(raw.Home, true) -- migration: the v3 reserve Home.Rooms becomes Home.Stations
	p.PetLevels = copyPetLevels(raw.PetLevels)
	p.Food = cleanCounts(raw.Food, MAX_FOOD)
	p.GemReceipts = cleanReceipts(raw.GemReceipts, true)
	p.Teams = cleanTeams(raw.Teams)
	return p
end

-- Both arguments are clean profiles (normalizeProfile / copyProfile results).
local function profilesEqual(a, b)
	if a.Tokens ~= b.Tokens or a.SpotIndex ~= b.SpotIndex then
		return false
	end
	if not listsEqual(a.Equipped, b.Equipped) then
		return false
	end
	if not mapsEqual(a.Pets, b.Pets) or not mapsEqual(a.Items, b.Items) then
		return false
	end
	for _, key in ipairs(STAT_KEYS) do
		if a.Stats[key] ~= b.Stats[key] then
			return false
		end
	end
	if not mapsEqual(a.Stats.BestTimes, b.Stats.BestTimes) then
		return false
	end
	-- v3
	if a.Cash ~= b.Cash or a.Gems ~= b.Gems then
		return false
	end
	if not mapsEqual(a.Discovered, b.Discovered) or not mapsEqual(a.IndexClaimed, b.IndexClaimed) then
		return false
	end
	if not tutorialsEqual(a.Tutorial, b.Tutorial) then
		return false
	end
	-- Phase 2
	if not homesEqual(a.Home, b.Home) or not mapsEqual(a.Food, b.Food) or not mapsEqual(a.GemReceipts, b.GemReceipts) then
		return false
	end
	return deepEqual(a.PetLevels, b.PetLevels)
		and deepEqual(a.Tiers, b.Tiers)
		and deepEqual(a.Hybrids, b.Hybrids)
		and deepEqual(a.Teams, b.Teams)
end

----------------------------------------------------------------------
-- Delta merge (the heart of the safe-save design)
----------------------------------------------------------------------

local function diffCounts(live, base)
	local out = {}
	for id, n in pairs(live) do
		local delta = n - (base[id] or 0)
		if delta ~= 0 then
			out[id] = delta
		end
	end
	for id, n in pairs(base) do
		if live[id] == nil then
			out[id] = -n
		end
	end
	return out
end

-- Keys the session added to a grow-only set (removals never travel).
local function diffSet(live, base)
	local out = {}
	local b = tableOr(base)
	for key, value in pairs(tableOr(live)) do
		if value and not b[key] and validKey(key) then
			out[key] = true
		end
	end
	return out
end

-- Per-key replacements of a clean map: key -> new value, or false when the session removed it.
local function diffReplace(live, base, equal)
	local out = {}
	for key, value in pairs(live) do
		if base[key] == nil or not equal(value, base[key]) then
			out[key] = value
		end
	end
	for key in pairs(base) do
		if live[key] == nil then
			out[key] = false
		end
	end
	return out
end

local function sameValue(a, b)
	return a == b
end

local function samePetLevel(a, b)
	return a.Level == b.Level and a.Xp == b.Xp
end

-- Untrusted best-times map -> { [difficultyId] = seconds } with valid keys and sane seconds only.
local function cleanBestTimes(raw)
	local out = {}
	for id, seconds in pairs(tableOr(raw)) do
		local clean = sanitizeSeconds(seconds)
		if validKey(id) and clean then
			out[id] = clean
		end
	end
	return out
end

-- The values a pending ResetFields writes over the store: the session's CURRENT values of those fields.
local function overwriteValues(live, overwrite)
	if type(overwrite) ~= "table" then
		return nil
	end
	local out = {}
	if overwrite.Discovered then
		out.Discovered = cleanSet(live.Discovered)
	end
	if overwrite.IndexClaimed then
		out.IndexClaimed = cleanSet(live.IndexClaimed)
	end
	if overwrite.Tutorial then
		out.Tutorial = cleanTutorial(live.Tutorial)
	end
	if overwrite.BestTimes then
		out.BestTimes = cleanBestTimes(type(live.Stats) == "table" and live.Stats.BestTimes)
	end
	if overwrite.Home then
		out.Home = cleanHome(live.Home, false)
	end
	if overwrite.Tiers then
		out.Tiers = cleanTiers(live.Tiers)
	end
	if overwrite.Hybrids then
		out.Hybrids = cleanHybrids(live.Hybrids)
	end
	if overwrite.PetLevels then
		out.PetLevels = copyPetLevels(live.PetLevels)
	end
	if next(out) == nil then
		return nil
	end
	return out
end

-- The Home delta, or nil when the session did not change the Home. Whole = the session's complete home (it wins
-- when its prestige is higher than the stored one); the rest is the per-key merge used at equal prestige.
local function diffHome(liveRaw, baseRaw)
	local live, base = cleanHome(liveRaw, false), cleanHome(baseRaw, false)
	if homesEqual(live, base) then
		return nil
	end
	local d = {
		Whole = live,
		Prestige = live.Prestige,
		Level = nil,
		Stations = diffReplace(live.Stations, base.Stations, sameValue),
		Garden = diffReplace(live.Garden, base.Garden, sameValue),
		Gym = diffReplace(live.Gym, base.Gym, sameValue),
		CollectorCash = live.CollectorCash - base.CollectorCash,
		LastSeen = nil,
	}
	if live.Level ~= base.Level then
		d.Level = live.Level
	end
	if live.LastSeen ~= base.LastSeen then
		d.LastSeen = live.LastSeen
	end
	return d
end

-- What changed between `base` and `live`. Counters travel as +/- deltas, "best" values as
-- candidates, sets as additions, lists / single values as replacements. `live` may be the raw live
-- profile, so every v3 / Phase 2 field is read defensively. `overwrite` (the entry's pending ResetFields, or nil)
-- adds d.Overwrite: whole fields that replace the stored ones before anything else is merged.
local function diffProfiles(live, base, overwrite)
	local d = {
		Tokens = live.Tokens - base.Tokens,
		Pets = diffCounts(live.Pets, base.Pets),
		Items = diffCounts(live.Items, base.Items),
		Stats = {},
		BestTimes = {},
		Equipped = nil,
		HasSpot = false,
		SpotIndex = nil,
		-- v3
		Discovered = diffSet(live.Discovered, base.Discovered),
		IndexClaimed = diffSet(live.IndexClaimed, base.IndexClaimed),
		Tutorial = nil,
		-- whole units only (like copyProfile), so a fractional live balance can never keep a delta alive
		Cash = sanitizeCash(live.Cash) - sanitizeCash(base.Cash),
		Gems = sanitize(live.Gems) - sanitize(base.Gems),
		PetLevels = diffReplace(copyPetLevels(live.PetLevels), copyPetLevels(base.PetLevels), samePetLevel),
		-- Phase 2
		Home = diffHome(live.Home, base.Home),
		Food = diffCounts(cleanCounts(live.Food, MAX_FOOD), cleanCounts(base.Food, MAX_FOOD)),
		Tiers = diffReplace(cleanTiers(live.Tiers), cleanTiers(base.Tiers), deepEqual),
		Hybrids = diffReplace(cleanHybrids(live.Hybrids), cleanHybrids(base.Hybrids), deepEqual),
		GemReceipts = {},
		Teams = nil,
		Overwrite = overwriteValues(live, overwrite),
	}
	for _, key in ipairs(STAT_KEYS) do
		local delta = live.Stats[key] - base.Stats[key]
		if delta ~= 0 then
			d.Stats[key] = delta
		end
	end
	for id, seconds in pairs(live.Stats.BestTimes) do
		if base.Stats.BestTimes[id] ~= seconds then
			d.BestTimes[id] = seconds
		end
	end
	if not listsEqual(live.Equipped, base.Equipped) then
		d.Equipped = copyList(live.Equipped)
	end
	if live.SpotIndex ~= base.SpotIndex then
		d.HasSpot = true
		d.SpotIndex = live.SpotIndex
	end
	local liveTutorial = cleanTutorial(live.Tutorial)
	if not tutorialsEqual(liveTutorial, cleanTutorial(base.Tutorial)) then
		d.Tutorial = liveTutorial
	end
	local baseReceipts = cleanReceipts(base.GemReceipts)
	for id, t in pairs(cleanReceipts(live.GemReceipts)) do
		if baseReceipts[id] == nil then
			d.GemReceipts[id] = t
		end
	end
	local liveTeams = cleanTeams(live.Teams)
	if not deepEqual(liveTeams, cleanTeams(base.Teams)) then
		d.Teams = liveTeams
	end
	return d
end

local function isEmptyDelta(d)
	return d.Tokens == 0
		and next(d.Pets) == nil
		and next(d.Items) == nil
		and next(d.Stats) == nil
		and next(d.BestTimes) == nil
		and d.Equipped == nil
		and not d.HasSpot
		and next(d.Discovered) == nil
		and next(d.IndexClaimed) == nil
		and d.Tutorial == nil
		and d.Cash == 0
		and d.Gems == 0
		and next(d.PetLevels) == nil
		and d.Home == nil
		and next(d.Food) == nil
		and next(d.Tiers) == nil
		and next(d.Hybrids) == nil
		and next(d.GemReceipts) == nil
		and d.Teams == nil
		and d.Overwrite == nil
end

local function applyCounts(target, deltas, maxCount)
	for id, delta in pairs(deltas) do
		local value = clampCount((target[id] or 0) + delta, maxCount)
		if value > 0 then
			target[id] = value
		else
			target[id] = nil
		end
	end
end

local function applyReplace(target, changes)
	for key, value in pairs(changes) do
		if value == false then
			target[key] = nil
		else
			target[key] = deepCopy(value)
		end
	end
end

-- Home merge: a higher prestige wins the whole Home; at equal prestige the session's changes merge per key.
local function applyHome(out, dh)
	if not dh then
		return
	end
	local stored = out.Home
	if dh.Prestige > stored.Prestige then
		out.Home = cleanHome(dh.Whole, false) -- the session prestiged past the store
		return
	end
	if stored.Prestige > dh.Prestige then
		return -- another server prestiged past this session: its stations were reset, the session's edits are void
	end
	if dh.Level ~= nil then
		stored.Level = dh.Level
	end
	applyReplace(stored.Stations, dh.Stations)
	applyReplace(stored.Garden, dh.Garden)
	applyReplace(stored.Gym, dh.Gym)
	stored.CollectorCash = sanitizeCash(stored.CollectorCash + dh.CollectorCash)
	if dh.LastSeen ~= nil and dh.LastSeen > stored.LastSeen then
		stored.LastSeen = dh.LastSeen
	end
end

-- stored profile + delta -> new profile. Pure (runs inside UpdateAsync, which may retry it).
local function applyDelta(stored, d)
	local out = copyProfile(stored)
	-- a pending ResetFields first replaces whole fields, so the union / sticky / best-of / prestige merges below
	-- cannot bring the stored values back (they then merge the session's own changes onto the replaced value)
	local o = d.Overwrite
	if o then
		if o.Discovered then
			out.Discovered = copyMap(o.Discovered)
		end
		if o.IndexClaimed then
			out.IndexClaimed = copyMap(o.IndexClaimed)
		end
		if o.Tutorial then
			out.Tutorial = cleanTutorial(o.Tutorial)
		end
		if o.BestTimes then
			out.Stats.BestTimes = copyMap(o.BestTimes)
		end
		if o.Home then
			out.Home = cleanHome(o.Home, false)
		end
		if o.Tiers then
			out.Tiers = deepCopy(o.Tiers)
		end
		if o.Hybrids then
			out.Hybrids = deepCopy(o.Hybrids)
		end
		if o.PetLevels then
			out.PetLevels = deepCopy(o.PetLevels)
		end
	end
	out.Tokens = sanitize(out.Tokens + d.Tokens)
	applyCounts(out.Pets, d.Pets, Config.Pets.MaxPerStack)
	applyCounts(out.Items, d.Items, Config.Items.MaxCarry)
	for key, delta in pairs(d.Stats) do
		out.Stats[key] = sanitize(out.Stats[key] + delta)
	end
	for id, seconds in pairs(d.BestTimes) do
		local current = out.Stats.BestTimes[id]
		if current == nil or seconds < current then
			out.Stats.BestTimes[id] = seconds
		end
	end
	if d.Equipped then
		out.Equipped = copyList(d.Equipped)
	end
	if d.HasSpot then
		out.SpotIndex = d.SpotIndex
	end
	-- v3
	for id in pairs(d.Discovered) do
		out.Discovered[id] = true
	end
	for id in pairs(d.IndexClaimed) do
		out.IndexClaimed[id] = true
	end
	if d.Tutorial then
		-- the session's step wins; Done and Gifted stick once true (the gift can never be paid twice)
		out.Tutorial = {
			Step = d.Tutorial.Step,
			Done = d.Tutorial.Done or out.Tutorial.Done,
			Gifted = d.Tutorial.Gifted or out.Tutorial.Gifted,
		}
	end
	out.Cash = sanitizeCash(out.Cash + d.Cash)
	out.Gems = sanitize(out.Gems + d.Gems)
	applyReplace(out.PetLevels, d.PetLevels)
	-- Phase 2
	if not (o and o.Home) then
		applyHome(out, d.Home) -- an overwritten Home already is the session's whole Home
	end
	applyCounts(out.Food, d.Food, MAX_FOOD)
	applyReplace(out.Tiers, d.Tiers)
	applyReplace(out.Hybrids, d.Hybrids)
	for id, t in pairs(d.GemReceipts) do
		local current = out.GemReceipts[id]
		if current == nil or t > current then
			out.GemReceipts[id] = t
		end
	end
	trimReceipts(out.GemReceipts, d.GemReceipts)
	if d.Teams then
		out.Teams = deepCopy(d.Teams)
	end
	-- last: the owned copies (Pets, Tiers, Hybrids) are final now
	normalizeEquipped(out)
	discoverOwned(out)
	return out
end

-- Clean profile -> the table written to the store (no Rooms alias, slot maps encoded, empty Phase 2 maps left out).
local function toStored(p)
	local stats = { BestTimes = copyMap(p.Stats.BestTimes) }
	for _, key in ipairs(STAT_KEYS) do
		stats[key] = p.Stats[key]
	end
	local h = p.Home
	local rec = {
		Version = PROFILE_VERSION,
		Tokens = p.Tokens,
		Pets = copyMap(p.Pets),
		Equipped = copyList(p.Equipped),
		Items = copyMap(p.Items),
		Stats = stats,
		SpotIndex = p.SpotIndex,
		Discovered = copyMap(p.Discovered),
		IndexClaimed = copyMap(p.IndexClaimed),
		Tutorial = cleanTutorial(p.Tutorial),
		Cash = p.Cash,
		Gems = p.Gems,
		Home = {
			Level = h.Level,
			Prestige = h.Prestige,
			Stations = copyMap(h.Stations),
			Garden = encodeSlots(h.Garden),
			Gym = encodeSlots(h.Gym),
			CollectorCash = h.CollectorCash,
			LastSeen = h.LastSeen,
		},
		PetLevels = deepCopy(p.PetLevels),
	}
	if next(p.Food) ~= nil then
		rec.Food = copyMap(p.Food)
	end
	if next(p.Tiers) ~= nil then
		rec.Tiers = deepCopy(p.Tiers)
	end
	if next(p.Hybrids) ~= nil then
		rec.Hybrids = deepCopy(p.Hybrids)
	end
	if next(p.GemReceipts) ~= nil then
		rec.GemReceipts = copyMap(p.GemReceipts)
	end
	if next(p.Teams) ~= nil then
		rec.Teams = deepCopy(p.Teams)
	end
	return rec
end

-- Forward compatibility (runs inside UpdateAsync, so it stays pure): `record` was rebuilt from the keys this
-- version knows, so it gets back every stored key it does not own (top level, inside Home and inside Stats) and
-- a newer Version number. An older server still running after a later phase is published then never erases that
-- phase's data. Known keys are never copied back (a cleared SpotIndex must stay cleared, spent Food stays spent).
local function keepForeign(record, old)
	if type(old) ~= "table" then
		return record
	end
	for key, value in pairs(old) do
		if not KNOWN_TOP[key] then
			record[key] = value
		end
	end
	if type(old.Home) == "table" then
		for key, value in pairs(old.Home) do
			if not KNOWN_HOME[key] then
				record.Home[key] = value
			end
		end
	end
	if type(old.Stats) == "table" then
		for key, value in pairs(old.Stats) do
			if not KNOWN_STATS[key] then
				record.Stats[key] = value
			end
		end
	end
	if isFinite(old.Version) and old.Version > PROFILE_VERSION then
		record.Version = old.Version
	end
	return record
end

-- Clears `t` and copies `src` into it (deep copies of table values).
local function refill(t, src)
	for key in pairs(copyMap(t)) do
		t[key] = nil
	end
	for key, value in pairs(src) do
		t[key] = deepCopy(value)
	end
end

-- The table at holder[field], created when missing (replaceContents works in place).
local function ensureTable(holder, field)
	local t = holder[field]
	if type(t) ~= "table" then
		t = {}
		holder[field] = t
	end
	return t
end

-- Writes a clean home into the live home table IN PLACE (other modules may hold it); Rooms stays Stations.
local function writeHome(target, src)
	target.Level = src.Level
	target.Prestige = src.Prestige
	local stations = ensureTable(target, "Stations")
	refill(stations, src.Stations)
	target.Rooms = stations
	refill(ensureTable(target, "Garden"), src.Garden)
	refill(ensureTable(target, "Gym"), src.Gym)
	target.CollectorCash = src.CollectorCash
	target.LastSeen = src.LastSeen
end

-- Overwrites the fields of `target` with `src` IN PLACE (other modules may hold the table).
local function replaceContents(target, src)
	target.Version = PROFILE_VERSION
	target.Tokens = src.Tokens
	target.SpotIndex = src.SpotIndex
	for _, field in ipairs({ "Pets", "Items", "Discovered", "IndexClaimed", "PetLevels", "Food", "Tiers", "Hybrids", "GemReceipts" }) do
		refill(ensureTable(target, field), src[field])
	end
	local equipped = ensureTable(target, "Equipped")
	for i = #equipped, 1, -1 do
		equipped[i] = nil
	end
	for i, id in ipairs(src.Equipped) do
		equipped[i] = id
	end
	local stats = ensureTable(target, "Stats")
	for _, key in ipairs(STAT_KEYS) do
		stats[key] = src.Stats[key]
	end
	refill(ensureTable(stats, "BestTimes"), src.Stats.BestTimes)
	-- v3 / Phase 2
	target.Cash = src.Cash
	target.Gems = src.Gems
	local tutorial = ensureTable(target, "Tutorial")
	tutorial.Step = src.Tutorial.Step
	tutorial.Done = src.Tutorial.Done
	tutorial.Gifted = src.Tutorial.Gifted
	writeHome(ensureTable(target, "Home"), src.Home)
	target.Teams = deepCopy(src.Teams)
end

-- Moves the live profile onto freshly read store data while keeping everything the session did
-- since `fromBase`. `newBase` becomes the new "known to be in the store" reference. A pending ResetFields
-- keeps the session's values of its fields (they are still to be written over the store).
local function rebase(entry, fromBase, stored, newBase)
	local d = diffProfiles(entry.Profile, fromBase, entry.Overwrite)
	local merged = applyDelta(stored, d)
	replaceContents(entry.Profile, merged)
	entry.Base = copyProfile(newBase)
end

----------------------------------------------------------------------
-- Player mirrors + remotes
----------------------------------------------------------------------

-- Mirror a token total onto the player (attribute for the HUD, leaderstats for the leaderboard).
local function pushToPlayer(player, value)
	if not player or not player.Parent then
		return
	end
	player:SetAttribute(Config.Attr.Tokens, value)
	local stats = player:FindFirstChild("leaderstats")
	local tokensValue = stats and stats:FindFirstChild("Tokens")
	if tokensValue then
		tokensValue.Value = value
	end
end

-- Mirror the Cash / Gems balances (whole units) onto the player for the HUD currency stack.
local function pushCurrencies(player, profile)
	if not player or not player.Parent or type(profile) ~= "table" then
		return
	end
	if Config.Attr.Cash then
		player:SetAttribute(Config.Attr.Cash, sanitizeCash(profile.Cash))
	end
	if Config.Attr.Gems then
		player:SetAttribute(Config.Attr.Gems, sanitize(profile.Gems))
	end
end

local function pushAll(player, profile)
	pushToPlayer(player, profile.Tokens)
	pushCurrencies(player, profile)
end

local function getRemote(name)
	local cached = remoteCache[name]
	if cached and cached.Parent then
		return cached
	end
	local ok, remote = pcall(Remotes.Get, name)
	if ok and remote then
		remoteCache[name] = remote
		return remote
	end
	return nil
end

local PERK_KEYS = { "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }

-- Perk totals of a list of keys: each copy's perks x its tier multiplier (PetKeys.DefOf + StatMultiplier), each total
-- capped and rounded like PetCatalog.SumPerks (so Normal-only lists give exactly the same numbers).
local function sumKeyPerks(keys, equipped, profile)
	local sums = {}
	for _, key in ipairs(PERK_KEYS) do
		sums[key] = 0
	end
	for _, key in ipairs(equipped) do
		local ok, def = pcall(keys.DefOf, key, profile)
		if ok and type(def) == "table" and type(def.Perks) == "table" then
			local mult = 1
			if def.Tier ~= nil and type(keys.StatMultiplier) == "function" then
				local okMult, m = pcall(keys.StatMultiplier, def.Tier)
				if okMult and isFinite(m) and m > 0 then
					mult = m
				end
			end
			for perk, value in pairs(def.Perks) do
				if sums[perk] ~= nil and type(value) == "number" then
					sums[perk] = sums[perk] + value * mult
				end
			end
		end
	end
	local caps = Config.Pets.PerkCaps
	for perk, total in pairs(sums) do
		local cap = caps[perk]
		if type(cap) == "number" and total > cap then
			total = cap
		end
		sums[perk] = math.floor(total * 10000 + 0.5) / 10000
	end
	return sums
end

-- Equipped keys -> { MaxHealth, TokenBonus, StaminaRegen, CheckpointHeal } (summed, capped). `profile` is needed for
-- hybrid keys (their record); plain pet ids and tier keys work without it.
function DataService.ComputePerks(equipped, profile)
	local perks = { MaxHealth = 0, TokenBonus = 0, StaminaRegen = 0, CheckpointHeal = 0 }
	if type(equipped) ~= "table" then
		return perks
	end
	local summed = nil
	local keys = getPetKeys()
	if keys and type(keys.DefOf) == "function" then
		local ok, result = pcall(sumKeyPerks, keys, equipped, profile)
		if ok then
			summed = result
		end
	end
	if not summed then
		local catalog = getPetCatalog()
		if catalog and type(catalog.SumPerks) == "function" then
			local ok, result = pcall(catalog.SumPerks, equipped)
			if ok and type(result) == "table" then
				summed = result
			end
		end
	end
	if type(summed) == "table" then
		for _, key in ipairs(PERK_KEYS) do
			local value = summed[key]
			if isFinite(value) and value > 0 then
				local cap = Config.Pets.PerkCaps[key]
				if cap and value > cap then
					value = cap
				end
				perks[key] = value
			end
		end
	end
	return perks
end

-- Discovered ids for the client (owned pets always included): only pets the catalog knows (a retired
-- pet must not count towards "Unlocked: x/N"). Without a catalog the set is sent unfiltered.
local function discoveredSnapshot(profile)
	local set = cleanSet(profile.Discovered)
	for id, count in pairs(tableOr(profile.Pets)) do
		if validKey(id) and type(count) == "number" and count > 0 then
			set[id] = true
		end
	end
	for id in pairs(cleanTiers(profile.Tiers)) do
		set[id] = true
	end
	local catalog = getPetCatalog()
	if not catalog or type(catalog.Get) ~= "function" then
		return set
	end
	local out = {}
	for id in pairs(set) do
		local ok, def = pcall(catalog.Get, id)
		if ok and def then
			out[id] = true
		end
	end
	return out
end

-- What the client sees of the Home (slot maps encoded like the store; no LastSeen).
local function homeSnapshot(rawHome)
	local h = cleanHome(rawHome, false)
	return {
		Level = h.Level,
		Prestige = h.Prestige,
		Stations = h.Stations,
		Garden = encodeSlots(h.Garden),
		Gym = encodeSlots(h.Gym),
		CollectorCash = h.CollectorCash,
	}
end

-- Plain-table snapshot for the client (no Instances, no shared references).
local function buildSnapshot(profile)
	local stats = profile.Stats
	return {
		Tokens = profile.Tokens,
		Pets = copyMap(profile.Pets),
		Equipped = copyList(profile.Equipped),
		Items = copyMap(profile.Items),
		Stats = {
			Matches = stats.Matches,
			Wins = stats.Wins,
			TokensEarned = stats.TokensEarned,
			Spins = stats.Spins,
			BestTimes = copyMap(stats.BestTimes),
		},
		SpotIndex = profile.SpotIndex,
		Perks = DataService.ComputePerks(profile.Equipped, profile),
		-- v3
		Discovered = discoveredSnapshot(profile),
		IndexClaimed = cleanSet(profile.IndexClaimed),
		Tutorial = cleanTutorial(profile.Tutorial),
		-- Phase 2
		Cash = sanitizeCash(profile.Cash),
		Gems = sanitize(profile.Gems),
		Home = homeSnapshot(profile.Home),
		Food = cleanCounts(profile.Food, MAX_FOOD),
		Tiers = cleanTiers(profile.Tiers),
		Hybrids = cleanHybrids(profile.Hybrids),
		PetLevels = copyPetLevels(profile.PetLevels),
	}
end

----------------------------------------------------------------------
-- DataStore access
----------------------------------------------------------------------

-- Records a DataStore failure. Studio without API access is expected, so it stays silent there.
local function noteFailure(what, err)
	local message = tostring(err)
	if
		string.find(message, "StudioAccessToApisNotAllowed", 1, true)
		or string.find(message, "Studio access to APIs", 1, true)
		or string.find(message, "Enable Studio Access", 1, true)
		or string.find(message, "publish this place", 1, true) -- an unpublished place in Studio
	then
		storeDisabled = true -- stop hammering an API that will keep refusing us
		return
	end
	if not IS_STUDIO then
		warn(string.format("[DataService] %s failed: %s", what, message))
	end
end

-- The DataStore object, or nil when unavailable. Resolved lazily and only once.
local function getStore()
	if storeDisabled then
		return nil
	end
	if not storeResolved then
		storeResolved = true
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(Config.Tokens.DataStoreName)
		end)
		if ok then
			store = result
		else
			noteFailure("GetDataStore", result)
		end
	end
	return store
end

-- true while the entry holds stand-in defaults: its load failed although the store is usable (an outage), and the
-- recovery has not read the real save yet. Without a usable store (Studio without API access) the in-memory
-- profile is all there is, so it is never provisional.
local function isProvisional(entry)
	return entry ~= nil and entry.LoadFailed == true and getStore() ~= nil
end

local function getLegacyStore()
	if storeDisabled then
		return nil
	end
	if not legacyResolved then
		legacyResolved = true
		local name = Config.Tokens.LegacyDataStoreName
		if type(name) == "string" and name ~= "" then
			local ok, result = pcall(function()
				return DataStoreService:GetDataStore(name)
			end)
			if ok then
				legacyStore = result
			else
				noteFailure("GetDataStore(legacy)", result)
			end
		end
	end
	return legacyStore
end

-- GetAsync with one retry. Returns ok:boolean, value.
local function readKey(dataStore, key)
	for attempt = 1, 2 do
		local ok, result = pcall(function()
			return dataStore:GetAsync(key)
		end)
		if ok then
			return true, result
		end
		noteFailure("load", result)
		if storeDisabled or attempt == 2 then
			break
		end
		task.wait(RETRY_DELAY)
	end
	return false, nil
end

-- Reads a player's stored profile.
-- Returns ok, profile|nil, migrated. ok=false means "could not read" (nothing may be assumed).
-- profile == nil with ok=true means a brand-new player. migrated=true means the profile was built
-- from a v1 save and the v2 key does not exist yet.
local function fetchProfile(userId)
	local s = getStore()
	if not s then
		return false, nil, false
	end
	local ok, raw = readKey(s, keyFor(userId))
	if not ok then
		return false, nil, false
	end
	if raw ~= nil then
		return true, normalizeProfile(raw), false
	end
	-- Nothing in v2: look for a v1 save to migrate.
	local legacy = getLegacyStore()
	if legacy then
		local okLegacy, old = readKey(legacy, keyFor(userId))
		if not okLegacy then
			return false, nil, false
		end
		if old ~= nil then
			local migrated = newProfile()
			if type(old) == "table" then
				migrated.Tokens = sanitize(old.Tokens)
			else
				migrated.Tokens = sanitize(old)
			end
			return true, migrated, true
		end
	end
	return true, nil, false
end

----------------------------------------------------------------------
-- Cache entries, locking, loading
----------------------------------------------------------------------

local function ensureEntry(userId)
	local entry = cache[userId]
	if not entry then
		entry = {
			Profile = newProfile(),
			Base = newProfile(),
			Loaded = false,
			Loading = false,
			LoadFailed = false,
			Saving = false,
			Dirty = false,
			RecoveryScheduled = false,
			Orphan = false,
			OrphanSince = 0,
			OrphanScheduled = false,
		}
		cache[userId] = entry
	end
	return entry
end

-- Waits (bounded) for an in-flight load to finish.
local function waitForLoad(entry)
	local waited = 0
	while entry.Loading and waited < 40 do
		task.wait(0.1)
		waited = waited + 0.1
	end
end

-- Simple per-entry write lock (autosave vs. PlayerRemoving vs. BindToClose vs. recovery).
local function acquire(entry)
	local waited = 0
	while entry.Saving and waited < 20 do
		task.wait(0.25)
		waited = waited + 0.25
	end
	if entry.Saving then
		return false
	end
	entry.Saving = true
	return true
end

local function loadEntry(player)
	local userId = player.UserId
	local entry = ensureEntry(userId)
	if entry.Loaded then
		return entry, false
	end
	if entry.Loading then
		waitForLoad(entry)
		return entry, false
	end

	entry.Loading = true
	local fetched, stored, migrated = false, nil, false
	local pok, a, b, c = pcall(fetchProfile, userId)
	if pok then
		fetched, stored, migrated = a, b, c
	else
		warn("[DataService] fetch errored: " .. tostring(a))
	end

	if fetched then
		-- Anything the session did before the load finished (early AddTokens) is kept on top.
		local source = stored or newProfile()
		local newBase = newProfile()
		if stored and not migrated then
			newBase = source
		end
		rebase(entry, entry.Base, source, newBase)
		entry.LoadFailed = false
	else
		entry.LoadFailed = true -- play on with defaults; saves/recovery merge with the real data later
	end
	entry.Loaded = true
	entry.Loading = false
	return entry, true
end

-- Tells the player's systems that the live profile changed underneath them.
local function announceRebase(userId, entry)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	pushAll(player, entry.Profile)
	DataService.Sync(player)
	DataService.ProfileRebased:Fire(player, entry.Profile)
end

-- Re-reads the store for an entry whose load failed and merges the session on top of it.
-- Caller holds the entry lock. Returns true on success.
local function recover(entry, userId)
	local fetched, stored, migrated = fetchProfile(userId)
	if not fetched then
		return false
	end
	local source = stored or newProfile()
	local newBase = newProfile()
	if stored and not migrated then
		newBase = source
	end
	rebase(entry, entry.Base, source, newBase)
	entry.LoadFailed = false
	announceRebase(userId, entry)
	return true
end

-- After a failed load, keep retrying in the background so the player gets their pets back.
local function scheduleRecovery(userId)
	local entry = cache[userId]
	if not entry or entry.RecoveryScheduled or storeDisabled then
		return
	end
	entry.RecoveryScheduled = true
	task.spawn(function()
		local delays = { 20, 40, 80, 160, 300 }
		for _, seconds in ipairs(delays) do
			task.wait(seconds)
			if cache[userId] ~= entry or not entry.LoadFailed or shuttingDown or storeDisabled then
				break
			end
			if not Players:GetPlayerByUserId(userId) then
				break
			end
			if acquire(entry) then
				local ok, err = pcall(recover, entry, userId)
				entry.Saving = false
				if not ok then
					warn("[DataService] recovery errored: " .. tostring(err))
				end
			end
		end
		entry.RecoveryScheduled = false
	end)
end

----------------------------------------------------------------------
-- Saving
----------------------------------------------------------------------

-- Body of a save; the caller holds the entry lock. Returns true when the store is up to date.
local function writeEntry(entry, userId)
	if entry.LoadFailed then
		if not recover(entry, userId) then
			return false -- never write blind: it could hide a v1 save or a v2 profile we could not read
		end
	end

	for attempt = 1, 2 do
		local s = getStore()
		if not s then
			return false
		end

		local overwriteGen = entry.OverwriteGen
		local snapshot = copyProfile(entry.Profile)
		local delta = diffProfiles(snapshot, entry.Base, entry.Overwrite)
		if isEmptyDelta(delta) then
			entry.Dirty = false
			return true
		end

		local result = nil
		local ok, err = pcall(function()
			result = s:UpdateAsync(keyFor(userId), function(old)
				-- Must be pure and non-yielding: UpdateAsync may call it more than once.
				local record = keepForeign(toStored(applyDelta(normalizeProfile(old), delta)), old)
				record.UpdatedAt = os.time()
				return record
			end)
		end)

		if ok then
			entry.Dirty = false
			if delta.Overwrite and entry.OverwriteGen == overwriteGen then
				entry.Overwrite = nil -- written; a ResetFields during the write stays pending for the next save
			end
			if type(result) == "table" then
				local confirmed = normalizeProfile(result)
				if profilesEqual(confirmed, snapshot) then
					entry.Base = snapshot
				else
					-- The store held something different from what we assumed (another server,
					-- a recovered load): adopt it and re-apply whatever changed since the snapshot.
					rebase(entry, snapshot, confirmed, confirmed)
					announceRebase(userId, entry)
				end
			else
				entry.Base = snapshot
			end
			return true
		end

		noteFailure("save", err)
		if storeDisabled then
			return false
		end
		if attempt == 1 then
			task.wait(RETRY_DELAY)
		end
	end
	return false
end

local function saveEntry(userId)
	local entry = cache[userId]
	if not entry then
		return false
	end
	waitForLoad(entry)
	if not getStore() then
		return false -- DataStores unavailable: the in-memory cache is all we have
	end
	if not acquire(entry) then
		return false
	end
	local ok, result = pcall(writeEntry, entry, userId)
	entry.Saving = false
	if not ok then
		if not IS_STUDIO then
			warn("[DataService] Save errored: " .. tostring(result))
		end
		return false
	end
	return result == true
end

-- pcall-safe save by user id (the player may be gone: orphaned entries are saved this way too).
local function safeSave(userId)
	local ok, result = pcall(saveEntry, userId)
	if not ok then
		if not IS_STUDIO then
			warn("[DataService] Save errored: " .. tostring(result))
		end
		return false
	end
	return result == true
end

-- Saves one player (pcall-safe, retries once, silent when DataStores are unavailable).
function DataService.Save(player)
	if not player then
		return false
	end
	return safeSave(player.UserId)
end

-- true when the store already holds everything the entry knows (nothing could be lost by dropping it).
-- An unreadable comparison counts as "not clean": keeping data is always the safe direction.
local function entryIsClean(entry)
	local ok, empty = pcall(function()
		return isEmptyDelta(diffProfiles(entry.Profile, entry.Base, entry.Overwrite))
	end)
	return ok and empty == true
end

-- After a save attempt on a departed player's entry: drop it once it is safe (clean) or hopeless
-- (store unusable, or unsaved for ORPHAN_TIMEOUT seconds). A rejoined player owns the entry again.
local function settleOrphan(userId, entry)
	if cache[userId] ~= entry or not entry.Orphan or Players:GetPlayerByUserId(userId) then
		return
	end
	if entryIsClean(entry) then
		cache[userId] = nil
	elseif storeDisabled or os.clock() - entry.OrphanSince >= ORPHAN_TIMEOUT then
		warn(string.format("[DataService] giving up on unsaved progress of user %s", tostring(userId)))
		cache[userId] = nil
	end
end

-- Background retry (with backoff) for a departed player's unsaved entry. One loop per entry; it ends
-- when the entry is saved/dropped, the player rejoined (Load clears Orphan), or the server shuts down
-- (BindToClose makes the last attempt).
local function scheduleOrphanFlush(userId, entry)
	if entry.OrphanScheduled or shuttingDown then
		return
	end
	entry.OrphanScheduled = true
	task.spawn(function()
		local delay = ORPHAN_RETRY_FIRST
		while true do
			task.wait(delay)
			delay = math.min(delay * 2, ORPHAN_RETRY_MAX)
			if shuttingDown or cache[userId] ~= entry or not entry.Orphan then
				break
			end
			safeSave(userId)
			settleOrphan(userId, entry)
			if cache[userId] ~= entry or not entry.Orphan then
				break
			end
		end
		entry.OrphanScheduled = false
	end)
end

-- The player left: frees the cache entry, but ONLY when the store holds everything it knows. A failed
-- final save (outage, throttling, lock timeout, a load that never succeeded) would otherwise throw away
-- the only copy of the session's progress, so a dirty entry stays behind as an orphan and keeps being
-- retried (see the header). Skipped if the same user already rejoined.
function DataService.Release(player)
	if not player then
		return
	end
	local userId = player.UserId
	local current = Players:GetPlayerByUserId(userId)
	if current and current ~= player then
		return
	end
	lastRequest[userId] = nil
	local entry = cache[userId]
	if not entry then
		return
	end
	if storeDisabled or entryIsClean(entry) then
		cache[userId] = nil -- nothing can be (or is left to be) saved
		return
	end
	if not entry.Orphan then
		entry.Orphan = true
		entry.OrphanSince = os.clock()
	end
	scheduleOrphanFlush(userId, entry)
end

----------------------------------------------------------------------
-- Hooks: leave handler + RequestProfile
----------------------------------------------------------------------

local function onPlayerRemoving(player)
	-- PlayerService also saves (it does not release: Release is decided here); doing it here as well
	-- means a missing call can never lose data or leak the cache entry. Saving twice is a no-op
	-- (empty delta). Release keeps the entry when this save failed, see DataService.Release.
	task.spawn(function()
		DataService.Save(player)
		DataService.Release(player)
	end)
end

local function hook()
	if not playerHooked then
		playerHooked = true
		Players.PlayerRemoving:Connect(onPlayerRemoving)
	end
	if not requestHooked then
		local remote = getRemote("RequestProfile")
		if remote then
			requestHooked = true
			remote.OnServerEvent:Connect(function(player)
				local userId = player.UserId
				local now = os.clock()
				local last = lastRequest[userId]
				if last and now - last < REQUEST_COOLDOWN then
					return
				end
				lastRequest[userId] = now
				DataService.Sync(player)
			end)
		end
	end
end

-- Optional explicit init (Load / StartAutosave / BindToClose do the same lazily).
function DataService.Init()
	hook()
end

----------------------------------------------------------------------
-- Public API: loading + profile access
----------------------------------------------------------------------

-- Never errors. Returns the LIVE profile (mutate, then MarkDirty + Sync).
function DataService.Load(player)
	if not player then
		return newProfile()
	end
	hook()
	local ok, entry, didLoad = pcall(loadEntry, player)
	if not ok or not entry then
		warn("[DataService] Load failed: " .. tostring(entry))
		local fallback = ensureEntry(player.UserId)
		fallback.Loading = false
		fallback.Loaded = true
		fallback.LoadFailed = true
		scheduleRecovery(player.UserId) -- provisional until the real save is read (see the header)
		return fallback.Profile
	end
	-- A quick rejoin can find the previous session's entry still in memory (its final save was in
	-- flight): the profile is current, but the NEW Player instance still needs its attributes.
	if didLoad or entry.Owner ~= player then
		entry.Owner = player
		entry.Orphan = false -- the (re)joined player owns the entry again; the orphan retry loop stands down
		pushAll(player, entry.Profile)
		if entry.LoadFailed then
			scheduleRecovery(player.UserId)
		end
		DataService.Sync(player)
		DataService.ProfileLoaded:Fire(player, entry.Profile)
	end
	return entry.Profile
end

-- The live profile table, or nil until Load finished.
function DataService.GetProfile(player)
	local entry = player and cache[player.UserId]
	if entry and entry.Loaded then
		return entry.Profile
	end
	return nil
end

function DataService.MarkDirty(player)
	local entry = player and cache[player.UserId]
	if entry then
		entry.Dirty = true
	end
end

-- Fires ProfileSync(snapshot) to that player (no-op until the profile is loaded).
function DataService.Sync(player)
	if not player or not player.Parent then
		return
	end
	local entry = cache[player.UserId]
	if not entry or not entry.Loaded then
		return
	end
	local remote = getRemote("ProfileSync")
	if not remote then
		return
	end
	entry.LastSync = os.clock()
	local ok, err = pcall(function()
		remote:FireClient(player, buildSnapshot(entry.Profile))
	end)
	if not ok then
		warn("[DataService] Sync failed: " .. tostring(err))
	end
end

-- Extra: a throttled Sync for frequent small changes (food, pet XP, home edits): sends now when the last snapshot
-- is at least SYNC_GAP seconds old, otherwise once at the end of that window (several calls -> one snapshot).
function DataService.SyncSoon(player)
	local entry = player and cache[player.UserId]
	if not entry or not entry.Loaded or entry.SyncQueued then
		return
	end
	local elapsed = os.clock() - (entry.LastSync or -math.huge)
	if elapsed >= SYNC_GAP then
		DataService.Sync(player)
		return
	end
	entry.SyncQueued = true
	task.delay(SYNC_GAP - elapsed, function()
		entry.SyncQueued = false
		if cache[player.UserId] == entry then
			DataService.Sync(player)
		end
	end)
end

----------------------------------------------------------------------
-- v3: Pet Index discovery + tutorial progress
----------------------------------------------------------------------

-- Marks a pet as discovered (seen in the Pet Index). Returns true only the first time. Marks the
-- profile dirty but does not Sync: the caller does (PetService syncs right after every roll).
function DataService.MarkDiscovered(player, petId)
	if not player or not validKey(petId) then
		return false
	end
	local catalog = getPetCatalog()
	if catalog and type(catalog.Get) == "function" then
		local ok, def = pcall(catalog.Get, petId)
		if ok and not def then
			return false -- unknown pet id
		end
	end
	local entry = cache[player.UserId]
	if not entry then
		return false
	end
	local discovered = entry.Profile.Discovered
	if type(discovered) ~= "table" then
		discovered = {}
		entry.Profile.Discovered = discovered
	end
	if discovered[petId] == true then
		return false
	end
	discovered[petId] = true
	entry.Dirty = true
	return true
end

-- Extra: true when the player has discovered (ever owned / rolled) that pet.
function DataService.IsDiscovered(player, petId)
	local entry = player and cache[player.UserId]
	if not entry or type(petId) ~= "string" then
		return false
	end
	local discovered = entry.Profile.Discovered
	return type(discovered) == "table" and discovered[petId] == true
end

-- Extra: true while the player's profile is a stand-in (its load failed during a DataStore outage and the real
-- save has not been read yet). One-time rewards (tutorial gift, Index claims) and developer resets wait for it.
function DataService.IsProvisional(player)
	local entry = player and cache[player.UserId]
	return entry ~= nil and entry.Loaded == true and isProvisional(entry)
end

-- A copy of the tutorial progress { Step, Done, Gifted }, or nil until the profile is loaded. Also nil while the
-- profile is provisional: its defaults would start a returning player's tutorial again (gift and finish reward
-- included). TutorialService keeps polling and starts from the real progress once the recovery fired
-- ProfileRebased.
function DataService.GetTutorial(player)
	local entry = player and cache[player.UserId]
	if not entry or not entry.Loaded or isProvisional(entry) then
		return nil
	end
	return cleanTutorial(entry.Profile.Tutorial)
end

-- Stores tutorial progress (MarkDirty + Sync). Step is clamped to a whole number >= 1; Done and Gifted
-- stick once true (the store merges them the same way, so a gift can never be paid twice).
-- Returns true when stored (false until the profile is loaded, while it is provisional, or for a non-table
-- argument).
function DataService.SetTutorial(player, tutorial)
	if not player or type(tutorial) ~= "table" then
		return false
	end
	local entry = cache[player.UserId]
	if not entry or not entry.Loaded or isProvisional(entry) then
		return false
	end
	local profile = entry.Profile
	local current = cleanTutorial(profile.Tutorial)
	local wanted = cleanTutorial(tutorial)
	local live = profile.Tutorial
	if type(live) ~= "table" then
		live = {}
		profile.Tutorial = live
	end
	live.Step = wanted.Step
	live.Done = wanted.Done or current.Done
	live.Gifted = wanted.Gifted or current.Gifted
	entry.Dirty = true
	DataService.Sync(player)
	return true
end

-- Extra (developer tools only): the session's CURRENT values of the named fields (Discovered, IndexClaimed,
-- Tutorial, BestTimes, Home, Tiers, Hybrids, PetLevels; fields = { Discovered = true, ... }) replace the stored ones
-- at the next successful save instead of being merged (those merges only ever grow, or a higher stored prestige would
-- win the Home back, so a /reset or /tutorial would otherwise come back with the next save). The caller changes the
-- live values itself; everything after this call merges on top of them as usual. Pending until a save succeeds
-- (orphan retries and BindToClose carry it). Returns true when recorded (false until the profile is loaded, while it
-- is provisional, or without a known field).
function DataService.ResetFields(player, fields)
	if not player or type(fields) ~= "table" then
		return false
	end
	local entry = cache[player.UserId]
	if not entry or not entry.Loaded or isProvisional(entry) then
		return false
	end
	local pending = {}
	for key in pairs(entry.Overwrite or {}) do
		pending[key] = true
	end
	local any = false
	for key, on in pairs(fields) do
		if on == true and OVERWRITABLE[key] then
			pending[key] = true
			any = true
		end
	end
	if not any then
		return false
	end
	entry.Overwrite = pending
	entry.OverwriteGen = (entry.OverwriteGen or 0) + 1
	entry.Dirty = true
	return true
end

----------------------------------------------------------------------
-- Tokens
----------------------------------------------------------------------

-- Adds earned tokens (n > 0; spending goes through SpendTokens). Also counts Stats.TokensEarned.
function DataService.AddTokens(player, n)
	if not player or not isFinite(n) then
		return
	end
	local amount = math.floor(n + 0.5)
	if amount <= 0 then
		return
	end
	local entry = cache[player.UserId]
	if not entry then
		if not player.Parent then
			return -- a player who already left (and was released) must not recreate a cache entry
		end
		hook()
		entry = ensureEntry(player.UserId)
	end
	local profile = entry.Profile
	profile.Tokens = sanitize(profile.Tokens + amount)
	profile.Stats.TokensEarned = sanitize(profile.Stats.TokensEarned + amount)
	entry.Dirty = true
	pushToPlayer(player, profile.Tokens)
end

-- true if the tokens were taken. Never goes negative.
function DataService.SpendTokens(player, n)
	if not player or not isFinite(n) or n < 0 then
		return false
	end
	local amount = math.ceil(n)
	local entry = cache[player.UserId]
	if not entry then
		return amount == 0
	end
	local profile = entry.Profile
	if amount > profile.Tokens then
		return false
	end
	if amount == 0 then
		return true
	end
	profile.Tokens = profile.Tokens - amount
	entry.Dirty = true
	pushToPlayer(player, profile.Tokens)
	return true
end

function DataService.GetTokens(player)
	if not player then
		return 0
	end
	local entry = cache[player.UserId]
	if entry then
		return entry.Profile.Tokens
	end
	local attr = player:GetAttribute(Config.Attr.Tokens)
	if type(attr) == "number" then
		return attr
	end
	return 0
end

----------------------------------------------------------------------
-- Phase 2: Cash + Gems (delta-saved like Tokens; mirrored on the player attributes)
----------------------------------------------------------------------

-- The cache entry for a currency change (created like AddTokens does when the load has not finished yet).
local function currencyEntry(player)
	local entry = cache[player.UserId]
	if not entry then
		if not player.Parent then
			return nil
		end
		hook()
		entry = ensureEntry(player.UserId)
	end
	return entry
end

-- Adds cash (n > 0; fractions are kept in the live balance, the store and the HUD see whole units).
function DataService.AddCash(player, n)
	if not player or not isFinite(n) or n <= 0 then
		return false
	end
	local entry = currencyEntry(player)
	if not entry then
		return false
	end
	local profile = entry.Profile
	profile.Cash = clampCash((isFinite(profile.Cash) and profile.Cash or 0) + n)
	entry.Dirty = true
	pushCurrencies(player, profile)
	return true
end

-- true if the cash was taken (whole units, n rounded up). Never goes negative; check and write do not yield.
function DataService.SpendCash(player, n)
	if not player or not isFinite(n) or n < 0 then
		return false
	end
	local amount = math.ceil(n)
	local entry = cache[player.UserId]
	if not entry then
		return amount == 0
	end
	local profile = entry.Profile
	local balance = clampCash(profile.Cash)
	if amount > balance then
		return false
	end
	if amount == 0 then
		return true
	end
	profile.Cash = balance - amount
	entry.Dirty = true
	pushCurrencies(player, profile)
	return true
end

function DataService.GetCash(player)
	if not player then
		return 0
	end
	local entry = cache[player.UserId]
	if entry then
		return sanitizeCash(entry.Profile.Cash)
	end
	local attr = Config.Attr.Cash and player:GetAttribute(Config.Attr.Cash)
	if type(attr) == "number" then
		return attr
	end
	return 0
end

-- Adds gems (whole numbers; n rounded to the nearest whole, must be >= 1).
function DataService.AddGems(player, n)
	if not player or not isFinite(n) then
		return false
	end
	local amount = math.floor(n + 0.5)
	if amount <= 0 then
		return false
	end
	local entry = currencyEntry(player)
	if not entry then
		return false
	end
	local profile = entry.Profile
	profile.Gems = sanitize(sanitize(profile.Gems) + amount)
	entry.Dirty = true
	pushCurrencies(player, profile)
	return true
end

-- true if the gems were taken (n rounded up). Never goes negative.
function DataService.SpendGems(player, n)
	if not player or not isFinite(n) or n < 0 then
		return false
	end
	local amount = math.ceil(n)
	local entry = cache[player.UserId]
	if not entry then
		return amount == 0
	end
	local profile = entry.Profile
	local balance = sanitize(profile.Gems)
	if amount > balance then
		return false
	end
	if amount == 0 then
		return true
	end
	profile.Gems = balance - amount
	entry.Dirty = true
	pushCurrencies(player, profile)
	return true
end

function DataService.GetGems(player)
	if not player then
		return 0
	end
	local entry = cache[player.UserId]
	if entry then
		return sanitize(entry.Profile.Gems)
	end
	local attr = Config.Attr.Gems and player:GetAttribute(Config.Attr.Gems)
	if type(attr) == "number" then
		return attr
	end
	return 0
end

----------------------------------------------------------------------
-- Phase 2: Food (delta-saved counts)
----------------------------------------------------------------------

local function wholeAmount(n)
	if n == nil then
		return 1
	end
	if not isFinite(n) then
		return nil
	end
	local amount = math.floor(n + 0.5)
	if amount < 1 then
		return nil
	end
	return amount
end

-- Adds n (default 1) of a food. false for junk ids / amounts or before the profile loaded. Capped per type.
function DataService.AddFood(player, foodId, n)
	local amount = wholeAmount(n)
	if not player or not validKey(foodId) or not amount then
		return false
	end
	local entry = cache[player.UserId]
	if not entry or not entry.Loaded then
		return false
	end
	local food = ensureTable(entry.Profile, "Food")
	local have = isFinite(food[foodId]) and sanitize(food[foodId]) or 0
	food[foodId] = math.min(have + amount, MAX_FOOD)
	entry.Dirty = true
	DataService.SyncSoon(player)
	return true
end

-- Takes n (default 1) of a food: false (nothing taken) when fewer are owned.
function DataService.SpendFood(player, foodId, n)
	local amount = wholeAmount(n)
	if not player or not validKey(foodId) or not amount then
		return false
	end
	local entry = cache[player.UserId]
	if not entry or not entry.Loaded then
		return false
	end
	local food = ensureTable(entry.Profile, "Food")
	local have = isFinite(food[foodId]) and sanitize(food[foodId]) or 0
	if have < amount then
		return false
	end
	if have - amount > 0 then
		food[foodId] = have - amount
	else
		food[foodId] = nil
	end
	entry.Dirty = true
	DataService.SyncSoon(player)
	return true
end

-- Count of one food, or (foodId nil) a copy of the whole { [foodId] = count } map.
function DataService.GetFood(player, foodId)
	local entry = player and cache[player.UserId]
	local food = entry and tableOr(entry.Profile.Food) or {}
	if foodId == nil then
		return cleanCounts(food, MAX_FOOD)
	end
	if not validKey(foodId) then
		return 0
	end
	return isFinite(food[foodId]) and sanitize(food[foodId]) or 0
end

----------------------------------------------------------------------
-- Phase 2: pet levels (per key, replaced per key on save)
----------------------------------------------------------------------

-- XP needed to go from `level` to level + 1 (TycoonCatalog.XpToNext; a local curve without it).
local function xpToNext(level)
	local catalog = getTycoonCatalog()
	if catalog and type(catalog.XpToNext) == "function" then
		local ok, need = pcall(catalog.XpToNext, level)
		if ok and need == math.huge then
			return need -- the top of the curve: no further level
		end
		if ok and isFinite(need) and need > 0 then
			return need
		end
	end
	return math.floor(40 * level ^ 1.35 + 0.5)
end

local function maxPetLevel()
	local catalog = getTycoonCatalog()
	if catalog then
		local fromXp = type(catalog.PetXp) == "table" and catalog.PetXp.MaxLevel or nil
		for _, v in ipairs({ catalog.MaxPetLevel or false, catalog.PetMaxLevel or false, fromXp or false }) do
			if isFinite(v) and v >= 1 then
				return math.min(math.floor(v), MAX_LEVEL)
			end
		end
	end
	return DEFAULT_MAX_PET_LEVEL
end

-- level, xp of a pet key (1, 0 when it never gained XP or the profile is not loaded).
function DataService.GetPetLevel(player, key)
	local entry = player and cache[player.UserId]
	if not entry or not validKey(key) then
		return 1, 0
	end
	local clean = cleanPetLevel(tableOr(entry.Profile.PetLevels)[key])
	if not clean then
		return 1, 0
	end
	return clean.Level, clean.Xp
end

-- Adds XP to an OWNED pet copy and levels it up along the XP curve (capped at the max level, where XP stops).
-- Returns how many levels it gained (0 when refused: junk, not owned, not loaded, provisional profile).
function DataService.AddPetXp(player, key, xp)
	if not player or not validKey(key) or not isFinite(xp) or xp <= 0 then
		return 0
	end
	local entry = cache[player.UserId]
	if not entry or not entry.Loaded or isProvisional(entry) then
		return 0
	end
	local profile = entry.Profile
	if ownedCount(profile, key) <= 0 then
		return 0
	end
	local levels = ensureTable(profile, "PetLevels")
	local raw = levels[key]
	local level, have = 1, 0
	if type(raw) == "table" then
		if isFinite(raw.Level) and raw.Level >= 1 then
			level = math.min(math.floor(raw.Level), MAX_LEVEL)
		end
		if isFinite(raw.Xp) and raw.Xp > 0 then
			have = raw.Xp
		end
	elseif isFinite(raw) and raw >= 1 then
		level = math.min(math.floor(raw), MAX_LEVEL)
	end
	local cap = maxPetLevel()
	local total = have + xp
	local gained = 0
	while level < cap do
		local need = xpToNext(level)
		if total < need then
			break
		end
		total = total - need
		level = level + 1
		gained = gained + 1
	end
	if level >= cap then
		total = 0 -- at the top of the curve XP stops counting
	end
	levels[key] = { Level = level, Xp = math.min(total, MAX_COUNT) }
	entry.Dirty = true
	DataService.SyncSoon(player)
	return gained
end

----------------------------------------------------------------------
-- Phase 2: Home (Stations / Garden / Gym per key, CollectorCash as a delta, a higher prestige wins the whole Home)
----------------------------------------------------------------------

-- The live Home table, repaired in place when another module dropped one of its parts. Rooms stays Stations.
local function liveHome(profile)
	local home = profile.Home
	if type(home) ~= "table" then
		home = newHome()
		profile.Home = home
	end
	if type(home.Stations) ~= "table" then
		home.Stations = type(home.Rooms) == "table" and home.Rooms or {}
	end
	home.Rooms = home.Stations
	ensureTable(home, "Garden")
	ensureTable(home, "Gym")
	return home
end

-- After MutateHome: sanitises the live home IN PLACE (keeps the fraction of CollectorCash).
local function repairHome(home)
	local collector = clampCash(home.CollectorCash)
	writeHome(home, cleanHome(home, false))
	home.CollectorCash = collector
end

-- A deep copy of the Home ({ Level, Prestige, Stations, Garden, Gym, CollectorCash, LastSeen }; Garden / Gym keyed
-- by slot number), or nil until the profile is loaded and while it is provisional (its Home would be defaults).
function DataService.GetHome(player)
	local entry = player and cache[player.UserId]
	if not entry or not entry.Loaded or isProvisional(entry) then
		return nil
	end
	local home = liveHome(entry.Profile)
	local copy = cleanHome(home, false)
	copy.CollectorCash = clampCash(home.CollectorCash)
	return copy
end

-- fn(home) edits the live Home table (no yields). An error, or fn returning false, restores the Home and answers
-- false. While the profile is provisional only CollectorCash / LastSeen may change (they merge as a delta / the
-- later time; stations from stand-in defaults would overwrite the real ones): anything else is rolled back.
function DataService.MutateHome(player, fn)
	if not player or type(fn) ~= "function" then
		return false
	end
	local entry = cache[player.UserId]
	if not entry or not entry.Loaded then
		return false
	end
	local home = liveHome(entry.Profile)
	local before = cleanHome(home, false)
	local beforeCollector = home.CollectorCash
	local ok, result = pcall(fn, home)
	local function restore()
		writeHome(home, before)
		home.CollectorCash = clampCash(beforeCollector)
	end
	if not ok then
		warn("[DataService] MutateHome callback errored (home restored): " .. tostring(result))
		restore()
		return false
	end
	if result == false then
		restore()
		return false
	end
	repairHome(home)
	local after = cleanHome(home, false)
	local visible = not homeVisiblyEqual(before, after)
	if visible and isProvisional(entry) then
		restore()
		return false
	end
	entry.Dirty = true
	if visible then
		DataService.SyncSoon(player)
	end
	return true
end

----------------------------------------------------------------------
-- Phase 2: developer-product receipts (GemService: idempotent ProcessReceipt)
----------------------------------------------------------------------

-- true when that purchase id was already processed for the player; nil when that cannot be known yet (profile not
-- loaded, or provisional).
function DataService.HasReceipt(player, purchaseId)
	local entry = player and cache[player.UserId]
	if not entry or not entry.Loaded or isProvisional(entry) or not validKey(purchaseId) then
		return nil
	end
	return tableOr(entry.Profile.GemReceipts)[purchaseId] ~= nil
end

-- Records a processed purchase id. true = new (grant it now, in the same step), false = already processed (grant
-- nothing, the purchase is done), nil = cannot decide now (not loaded / provisional: answer NotProcessedYet).
-- The receipt and the granted gems travel in the same save (one UpdateAsync).
function DataService.MarkReceipt(player, purchaseId)
	local entry = player and cache[player.UserId]
	if not entry or not entry.Loaded or isProvisional(entry) or not validKey(purchaseId) then
		return nil
	end
	local receipts = ensureTable(entry.Profile, "GemReceipts")
	if receipts[purchaseId] ~= nil then
		return false
	end
	receipts[purchaseId] = sanitizeTime(os.time())
	trimReceipts(receipts, { [purchaseId] = true })
	entry.Dirty = true
	return true
end

----------------------------------------------------------------------
-- Stats
----------------------------------------------------------------------

-- Called by MatchService for every member at match end. `won` = finished on a victory.
function DataService.RecordMatch(player, difficultyId, won, seconds)
	local entry = player and cache[player.UserId]
	if not entry then
		return
	end
	local stats = entry.Profile.Stats
	stats.Matches = sanitize(stats.Matches + 1)
	if won == true then
		stats.Wins = sanitize(stats.Wins + 1)
		local clean = sanitizeSeconds(seconds)
		if clean and type(difficultyId) == "string" and Config.GetDifficulty(difficultyId) then
			local best = stats.BestTimes[difficultyId]
			if best == nil or clean < best then
				stats.BestTimes[difficultyId] = clean
			end
		end
	end
	entry.Dirty = true
end

----------------------------------------------------------------------
-- Autosave + shutdown
----------------------------------------------------------------------

function DataService.StartAutosave()
	hook()
	if autosaveStarted then
		return
	end
	autosaveStarted = true
	task.spawn(function()
		while not shuttingDown do
			local interval = Config.Tokens.AutosaveSeconds or 90
			local slept = 0
			-- Sleep in one-second slices so shutdown ends the loop promptly.
			while slept < interval and not shuttingDown do
				task.wait(1)
				slept = slept + 1
			end
			if shuttingDown then
				break
			end
			-- Walk the cache, not Players:GetPlayers(): entries of players who already left but could
			-- not be saved yet (orphans) must keep being flushed.
			local userIds = {}
			for userId in pairs(cache) do
				table.insert(userIds, userId)
			end
			for _, userId in ipairs(userIds) do
				if shuttingDown then
					break
				end
				local entry = cache[userId]
				if entry then
					safeSave(userId)
					if entry.Orphan then
						settleOrphan(userId, entry)
					end
					task.wait(0.25) -- spread requests out to stay inside the DataStore budget
				end
			end
		end
	end)
end

function DataService.BindToClose()
	hook()
	if closeBound then
		return
	end
	closeBound = true
	game:BindToClose(function()
		shuttingDown = true
		local userIds = {}
		for userId in pairs(cache) do
			table.insert(userIds, userId)
		end
		local pending = #userIds
		for _, userId in ipairs(userIds) do
			task.spawn(function()
				pcall(saveEntry, userId)
				pending = pending - 1
			end)
		end
		-- Roblox gives BindToClose ~30s; leave a margin.
		local waited = 0
		while pending > 0 and waited < 25 do
			task.wait(0.1)
			waited = waited + 0.1
		end
	end)
end

return DataService
