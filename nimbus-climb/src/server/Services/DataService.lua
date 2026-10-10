-- DataService: persistent player profile (tokens, pets, items, stats + v3 index / tutorial / tycoon
-- foundations) for Nimbus Climb.
--
-- Profile shape (ARCHITECTURE_V2.md section 1 + ARCHITECTURE_V3.md section 1):
--   { Version = 2, Tokens, Pets = {[petId]=count}, Equipped = {petId...}, Items = {[itemId]=count},
--     Stats = { Matches, Wins, TokensEarned, Spins, BestTimes = {[difficultyId]=seconds} }, SpotIndex,
--     -- v3
--     Discovered = {[petId]=true}, IndexClaimed = {[groupId]=true}, Tutorial = { Step, Done, Gifted },
--     Cash, Gems, Home = { Level, Rooms = {[roomId]=level}, Prestige }, PetLevels = {[petId]={Level, Xp}} }
--   The v3 fields are additive: a stored v2 profile simply lacks them and gets the defaults on load, and every
--   owned pet always counts as discovered (normalizeProfile + applyDelta keep that invariant). Version stays 2
--   because the stored layout of every v2 field is unchanged (older tooling keeps reading it).
--
-- Design notes
--   * Everything runs from an in-memory cache, so the game is fully playable when DataStores are
--     unavailable (Studio without "Enable Studio Access to API Services", Roblox outages, ...).
--   * Saves are DELTA based. The cache remembers `Base` (what the store is known to contain);
--     a save sends only "live minus base" and merges it into whatever is stored right now inside
--     UpdateAsync. A failed load can therefore never wipe a saved profile and two servers touching
--     the same player cannot clobber each other. After a failed load, the next save (or a
--     background retry) re-reads the store and merges the session on top of it.
--     v3 merge rules: Discovered / IndexClaimed only ever grow (set union); Tutorial merges
--     monotonically (Done and Gifted stick once true) so a second server can never replay the tutorial
--     gift; Cash / Gems travel as +/- deltas like Tokens; Home values and PetLevels entries are replaced
--     when the session changed them. The ONE exception is ResetFields (developer tools only): the fields
--     it names are written over the stored ones at the next successful save instead of merged.
--   * A PROVISIONAL profile (the load failed while the DataStore is reachable, e.g. an outage) holds
--     defaults, not the player's data. One-time rewards must not be decided from it: GetTutorial
--     answers nil and SetTutorial refuses until the background recovery read the real save (then
--     ProfileRebased fires and TutorialService starts from the stored progress), and
--     IsProvisional(player) lets IndexService / DevService refuse claims and resets meanwhile. That
--     is what keeps a failed load from replaying the tutorial gift / finish reward. Without a usable
--     store (Studio without API access) nothing is provisional: everything runs from memory.
--   * Forward compatibility: a save keeps every stored field this version does not know (top level,
--     inside Home and inside Stats) and a newer Version number, so a Phase 1 server still running after
--     a later phase is published never erases that phase's data (Stations, Food, Tiers, Hybrids, ...).
--   * v1 saves ({Tokens = n} in Config.Tokens.LegacyDataStoreName) are migrated once: when the v2
--     key is empty, the legacy key is read and its tokens become the starting balance. The legacy
--     store is never written.
--   * A leaving player's cache entry is only freed once the store holds everything it knows. If the
--     final save failed (outage, throttling, lock timeout, failed load that cannot be recovered), the
--     entry is kept as an "orphan": it is retried in the background with backoff, flushed by the
--     autosave sweep (which walks the cache, not the player list) and by BindToClose, and a quick
--     rejoin simply picks it up again. It is only dropped after a successful write or after
--     ORPHAN_TIMEOUT seconds. DataService alone makes this decision (Release); callers just call it.
--   * Extras beyond the documented API (used by PlayerService / PetService, harmless otherwise):
--     Release(player), Init(), ComputePerks(equippedIds), IsDiscovered(player, petId),
--     signal ProfileRebased(player, profile).
--   * v3 API: MarkDiscovered(player, petId) -> isNew (marks dirty; the caller Syncs, PetService does right
--     after a roll), GetTutorial(player) -> copy | nil until loaded (and while provisional),
--     SetTutorial(player, t) -> ok (MarkDirty + Sync; Gifted never goes back to false; false while
--     provisional). ProfileSync gains Discovered, IndexClaimed, Tutorial.
--     Extras: IsProvisional(player) -> bool; ResetFields(player, { Discovered, IndexClaimed, Tutorial,
--     BestTimes = true }) -> ok: the session's CURRENT values of those fields replace the stored ones at the
--     next successful save (DevService /reset and /tutorial; the caller changes the live values itself).
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
local MAX_KEY_LENGTH = 48
local REQUEST_COOLDOWN = 0.5 -- RequestProfile rate limit (seconds per player)
local ORPHAN_RETRY_FIRST = 10 -- seconds before the first background retry of an unsaved, departed profile
local ORPHAN_RETRY_MAX = 120 -- the retry delay doubles up to this
local ORPHAN_TIMEOUT = 1800 -- give up on (and drop) a departed profile that still cannot be saved after this long
local IS_STUDIO = RunService:IsStudio()
local STAT_KEYS = { "Matches", "Wins", "TokensEarned", "Spins" }
local MAX_TUTORIAL_STEP = 1000 -- sanity cap for Tutorial.Step (TutorialService clamps to its own step count)
local MAX_LEVEL = 100000 -- sanity cap for home / room / pet levels and prestige

-- Fields ResetFields may write over the store (everything else already follows a reset through the normal delta).
local OVERWRITABLE = { Discovered = true, IndexClaimed = true, Tutorial = true, BestTimes = true }
-- Stored keys this version owns. Anything else in a stored profile belongs to a newer phase and is written back
-- untouched by every save (see keepForeign).
local KNOWN_TOP = {
	Version = true, Tokens = true, Pets = true, Equipped = true, Items = true, Stats = true, SpotIndex = true,
	Discovered = true, IndexClaimed = true, Tutorial = true, Cash = true, Gems = true, Home = true, PetLevels = true,
	UpdatedAt = true,
}
local KNOWN_HOME = { Level = true, Rooms = true, Prestige = true }
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
--   OverwriteGen = counter bumped by every ResetFields (a reset during an in-flight save stays pending)
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

----------------------------------------------------------------------
-- Profile construction / validation
----------------------------------------------------------------------

local function newTutorial()
	return { Step = 1, Done = false, Gifted = false }
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
		-- v3 (ARCHITECTURE_V3.md section 1); Cash / Gems / Home / PetLevels are reserved for phases 2 and 3
		Discovered = {},
		IndexClaimed = {},
		Tutorial = newTutorial(),
		Cash = 0,
		Gems = 0,
		Home = { Level = 0, Rooms = {}, Prestige = 0 },
		PetLevels = {},
	}
end

local function tableOr(t)
	if type(t) == "table" then
		return t
	end
	return {}
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

local function cleanRooms(map)
	local out = {}
	for key, value in pairs(tableOr(map)) do
		if validKey(key) and isFinite(value) then
			out[key] = clampCount(value, MAX_LEVEL)
		end
	end
	return out
end

local function copyHome(home)
	local h = tableOr(home)
	return {
		Level = clampCount(h.Level, MAX_LEVEL),
		Rooms = cleanRooms(h.Rooms),
		Prestige = clampCount(h.Prestige, MAX_LEVEL),
	}
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

-- Every owned pet counts as discovered (v3 migration rule, kept as an invariant).
local function discoverOwned(profile)
	for id, count in pairs(profile.Pets) do
		if validKey(id) and type(count) == "number" and count > 0 then
			profile.Discovered[id] = true
		end
	end
end

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
	-- v3 (read defensively: other modules mutate the live profile)
	out.Discovered = cleanSet(p.Discovered)
	discoverOwned(out) -- a pet granted without MarkDiscovered still saves as discovered
	out.IndexClaimed = cleanSet(p.IndexClaimed)
	out.Tutorial = cleanTutorial(p.Tutorial)
	out.Cash = sanitize(p.Cash)
	out.Gems = sanitize(p.Gems)
	out.Home = copyHome(p.Home)
	out.PetLevels = copyPetLevels(p.PetLevels)
	return out
end

-- Drops equipped ids that are not owned, are over their owned count, or exceed the slot limit.
local function normalizeEquipped(profile)
	local out = {}
	local used = {}
	local maxEquipped = Config.Pets.MaxEquipped
	for _, id in ipairs(profile.Equipped) do
		if type(id) == "string" and #out < maxEquipped then
			local owned = profile.Pets[id] or 0
			local count = used[id] or 0
			if count < owned then
				used[id] = count + 1
				table.insert(out, id)
			end
		end
	end
	profile.Equipped = out
end

-- Untrusted stored value (nil / number / v1 table / v2 table / v3 table) -> clean profile. Pure.
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
	normalizeEquipped(p)
	-- v3 fields (absent in v2 saves: the defaults from newProfile stay)
	p.Discovered = cleanSet(raw.Discovered)
	discoverOwned(p) -- migration: owned pets count as discovered
	p.IndexClaimed = cleanSet(raw.IndexClaimed)
	p.Tutorial = cleanTutorial(raw.Tutorial)
	p.Cash = sanitize(raw.Cash)
	p.Gems = sanitize(raw.Gems)
	p.Home = copyHome(raw.Home)
	p.PetLevels = copyPetLevels(raw.PetLevels)
	return p
end

local function petLevelsEqual(a, b)
	for id, entry in pairs(a) do
		local other = b[id]
		if not other or other.Level ~= entry.Level or other.Xp ~= entry.Xp then
			return false
		end
	end
	for id in pairs(b) do
		if a[id] == nil then
			return false
		end
	end
	return true
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
	if a.Home.Level ~= b.Home.Level or a.Home.Prestige ~= b.Home.Prestige or not mapsEqual(a.Home.Rooms, b.Home.Rooms) then
		return false
	end
	return petLevelsEqual(a.PetLevels, b.PetLevels)
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
	if next(out) == nil then
		return nil
	end
	return out
end

-- What changed between `base` and `live`. Counters travel as +/- deltas, "best" values as
-- candidates, sets as additions, lists / single values as replacements. `live` may be the raw live
-- profile, so every v3 field is read defensively. `overwrite` (the entry's pending ResetFields, or nil)
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
		Cash = sanitize(live.Cash) - sanitize(base.Cash),
		Gems = sanitize(live.Gems) - sanitize(base.Gems),
		HomeLevel = nil,
		HomePrestige = nil,
		Rooms = nil,
		PetLevels = nil,
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
	local liveHome, baseHome = copyHome(live.Home), copyHome(base.Home)
	if liveHome.Level ~= baseHome.Level then
		d.HomeLevel = liveHome.Level
	end
	if liveHome.Prestige ~= baseHome.Prestige then
		d.HomePrestige = liveHome.Prestige
	end
	d.Rooms = diffReplace(liveHome.Rooms, baseHome.Rooms, sameValue)
	d.PetLevels = diffReplace(copyPetLevels(live.PetLevels), copyPetLevels(base.PetLevels), samePetLevel)
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
		and d.HomeLevel == nil
		and d.HomePrestige == nil
		and next(d.Rooms) == nil
		and next(d.PetLevels) == nil
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
		elseif type(value) == "table" then
			target[key] = copyMap(value)
		else
			target[key] = value
		end
	end
end

-- stored profile + delta -> new profile. Pure (runs inside UpdateAsync, which may retry it).
local function applyDelta(stored, d)
	local out = copyProfile(stored)
	-- a pending ResetFields first replaces whole fields, so the union / sticky / best-of merges below cannot
	-- bring the stored values back (they then merge the session's own changes onto the replaced value)
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
	normalizeEquipped(out)
	-- v3
	for id in pairs(d.Discovered) do
		out.Discovered[id] = true
	end
	discoverOwned(out)
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
	out.Cash = sanitize(out.Cash + d.Cash)
	out.Gems = sanitize(out.Gems + d.Gems)
	if d.HomeLevel ~= nil then
		out.Home.Level = d.HomeLevel
	end
	if d.HomePrestige ~= nil then
		out.Home.Prestige = d.HomePrestige
	end
	applyReplace(out.Home.Rooms, d.Rooms)
	applyReplace(out.PetLevels, d.PetLevels)
	return out
end

-- Forward compatibility (runs inside UpdateAsync, so it stays pure): `merged` was rebuilt from the keys this
-- version knows, so it gets back every stored key it does not own (top level, inside Home and inside Stats) and
-- a newer Version number. A Phase 1 server still running after a later phase is published then never erases that
-- phase's data. Known keys are never copied back (a cleared SpotIndex must stay cleared).
local function keepForeign(merged, old)
	if type(old) ~= "table" then
		return merged
	end
	for key, value in pairs(old) do
		if not KNOWN_TOP[key] then
			merged[key] = value
		end
	end
	if type(old.Home) == "table" then
		for key, value in pairs(old.Home) do
			if not KNOWN_HOME[key] then
				merged.Home[key] = value
			end
		end
	end
	if type(old.Stats) == "table" then
		for key, value in pairs(old.Stats) do
			if not KNOWN_STATS[key] then
				merged.Stats[key] = value
			end
		end
	end
	if isFinite(old.Version) and old.Version > PROFILE_VERSION then
		merged.Version = old.Version
	end
	return merged
end

-- Clears `t` and copies `src` into it (one level deep for table values).
local function refill(t, src)
	for key in pairs(copyMap(t)) do
		t[key] = nil
	end
	for key, value in pairs(src) do
		if type(value) == "table" then
			t[key] = copyMap(value)
		else
			t[key] = value
		end
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

-- Overwrites the fields of `target` with `src` IN PLACE (other modules may hold the table).
local function replaceContents(target, src)
	target.Version = PROFILE_VERSION
	target.Tokens = src.Tokens
	target.SpotIndex = src.SpotIndex
	for _, field in ipairs({ "Pets", "Items", "Discovered", "IndexClaimed", "PetLevels" }) do
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
	-- v3
	target.Cash = src.Cash
	target.Gems = src.Gems
	local tutorial = ensureTable(target, "Tutorial")
	tutorial.Step = src.Tutorial.Step
	tutorial.Done = src.Tutorial.Done
	tutorial.Gifted = src.Tutorial.Gifted
	local home = ensureTable(target, "Home")
	home.Level = src.Home.Level
	home.Prestige = src.Home.Prestige
	refill(ensureTable(home, "Rooms"), src.Home.Rooms)
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

-- PetCatalog is written by another module; resolve it lazily and tolerate its absence.
local catalogResolved = false
local petCatalog = nil
local function getPetCatalog()
	if not catalogResolved then
		catalogResolved = true
		local module = Shared:FindFirstChild("PetCatalog")
		if module then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				petCatalog = result
			else
				warn("[DataService] PetCatalog failed to load: " .. tostring(result))
			end
		end
	end
	return petCatalog
end

local PERK_KEYS = { "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }

-- Equipped pet ids -> { MaxHealth, TokenBonus, StaminaRegen, CheckpointHeal } (summed, capped).
function DataService.ComputePerks(equipped)
	local perks = { MaxHealth = 0, TokenBonus = 0, StaminaRegen = 0, CheckpointHeal = 0 }
	local catalog = getPetCatalog()
	if catalog and type(catalog.SumPerks) == "function" and type(equipped) == "table" then
		local ok, summed = pcall(catalog.SumPerks, equipped)
		if ok and type(summed) == "table" then
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
		Perks = DataService.ComputePerks(profile.Equipped),
		-- v3
		Discovered = discoveredSnapshot(profile),
		IndexClaimed = cleanSet(profile.IndexClaimed),
		Tutorial = cleanTutorial(profile.Tutorial),
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
	pushToPlayer(player, entry.Profile.Tokens)
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
				local merged = keepForeign(applyDelta(normalizeProfile(old), delta), old)
				merged.UpdatedAt = os.time()
				return merged
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
		pushToPlayer(player, entry.Profile.Tokens)
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
	local ok, err = pcall(function()
		remote:FireClient(player, buildSnapshot(entry.Profile))
	end)
	if not ok then
		warn("[DataService] Sync failed: " .. tostring(err))
	end
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
-- Tutorial, BestTimes; fields = { Discovered = true, ... }) replace the stored ones at the next successful save
-- instead of being merged (those merges only ever grow, so a /reset or /tutorial would otherwise come back with
-- the next save). The caller changes the live values itself; everything after this call merges on top of them as
-- usual. Pending until a save succeeds (orphan retries and BindToClose carry it). Returns true when recorded
-- (false until the profile is loaded, while it is provisional, or without a known field).
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
