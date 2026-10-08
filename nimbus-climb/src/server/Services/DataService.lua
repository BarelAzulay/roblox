-- DataService: persists each player's lifetime Cloud Tokens.
--
-- * Everything works from an in-memory cache, so the game is fully playable when DataStores are
--   unavailable (Studio without "Enable Studio Access to API Services", Roblox outages, ...).
-- * Writes use UpdateAsync with a *delta* (tokens earned since the last confirmed save) instead
--   of overwriting the stored total. A failed load can therefore never wipe a player's saved
--   progress, and two servers touching the same player can never clobber each other.
-- * Public API is the one in ARCHITECTURE.md (Load/Save/StartAutosave/BindToClose/AddTokens/
--   GetTokens). Release() is an extra used by PlayerService to free the cache entry on leave.
--
-- Plain Lua 5.1-compatible syntax only.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local DataService = {}

local RETRY_DELAY = 1.5 -- seconds between the two attempts of a load/save
local MAX_TOKENS = 1000000000 -- sanity cap so a bug can never overflow the counter
local IS_STUDIO = RunService:IsStudio()

-- cache[userId] = {
--   Tokens = number,     -- current lifetime total (what the player sees)
--   Saved = number,      -- the part of Tokens the store is known to contain
--   Loaded = bool,       -- Load() finished
--   LoadFailed = bool,   -- the read failed; the next successful save adopts the stored total
--   Saving = bool,       -- a write is in flight (simple per-entry lock)
-- }
local cache = {}
local store = nil
local storeResolved = false
local storeDisabled = false -- true once the DataStore API is known to be unusable (Studio)
local autosaveStarted = false
local closeBound = false
local shuttingDown = false

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function keyFor(userId)
	return "u_" .. tostring(userId)
end

-- Any value -> non-negative integer within sane bounds.
local function sanitize(n)
	if type(n) ~= "number" or n ~= n then
		return 0
	end
	if n < 0 then
		return 0
	end
	if n > MAX_TOKENS then
		return MAX_TOKENS
	end
	return math.floor(n)
end

-- Records a DataStore failure. Studio without API access is expected, so it stays silent there.
local function noteFailure(what, err)
	local message = tostring(err)
	if
		string.find(message, "StudioAccessToApisNotAllowed", 1, true)
		or string.find(message, "Studio access to APIs", 1, true)
		or string.find(message, "Enable Studio Access", 1, true)
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

local function newEntry()
	return { Tokens = 0, Saved = 0, Loaded = false, LoadFailed = false, Saving = false }
end

local function ensureEntry(userId)
	local entry = cache[userId]
	if not entry then
		entry = newEntry()
		cache[userId] = entry
	end
	return entry
end

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

----------------------------------------------------------------------
-- Reading
----------------------------------------------------------------------

-- Returns ok:boolean, tokens:number. ok=false means "could not read the store".
local function readTokens(userId)
	for attempt = 1, 2 do
		local s = getStore()
		if not s then
			return false, 0
		end
		local ok, result = pcall(function()
			return s:GetAsync(keyFor(userId))
		end)
		if ok then
			if type(result) == "table" then
				return true, sanitize(result.Tokens)
			elseif type(result) == "number" then
				return true, sanitize(result)
			end
			return true, 0 -- brand-new player
		end
		noteFailure("load", result)
		if storeDisabled or attempt == 2 then
			break
		end
		task.wait(RETRY_DELAY)
	end
	return false, 0
end

local function loadInternal(player)
	local userId = player.UserId
	local existing = cache[userId]
	if existing and existing.Loaded then
		return { Tokens = existing.Tokens }
	end

	local ok, stored = readTokens(userId)

	-- The cache entry may have been created while we were waiting on the store (AddTokens before
	-- Load finished). Keep whatever it earned on top of the stored total.
	local entry = cache[userId]
	if entry then
		entry.Tokens = sanitize(entry.Tokens + stored)
		entry.Saved = stored
	else
		entry = newEntry()
		entry.Tokens = stored
		entry.Saved = stored
		cache[userId] = entry
	end
	entry.Loaded = true
	entry.LoadFailed = not ok

	return { Tokens = entry.Tokens }
end

-- Never errors. Returns { Tokens = number } (defaults to 0).
function DataService.Load(player)
	if not player then
		return { Tokens = 0 }
	end
	local ok, result = pcall(loadInternal, player)
	if ok and type(result) == "table" then
		return result
	end
	if not ok then
		warn("[DataService] Load failed: " .. tostring(result))
	end
	return { Tokens = 0 }
end

----------------------------------------------------------------------
-- Writing
----------------------------------------------------------------------

-- Writes one cache entry. Returns true when the store is up to date afterwards.
local function saveEntry(userId)
	local entry = cache[userId]
	if not entry then
		return false
	end
	if not getStore() then
		return false -- DataStores unavailable: the in-memory cache is all we have
	end

	-- Wait for an in-flight save of the same entry (autosave vs. PlayerRemoving vs. BindToClose).
	local waited = 0
	while entry.Saving and waited < 20 do
		task.wait(0.25)
		waited = waited + 0.25
	end
	if entry.Saving then
		return false
	end

	if entry.Tokens == entry.Saved and not entry.LoadFailed then
		return true -- nothing new to write
	end

	entry.Saving = true
	local success = false

	for attempt = 1, 2 do
		local s = getStore()
		if not s then
			break
		end

		local snapshot = entry.Tokens
		local delta = snapshot - entry.Saved
		local result = nil

		local ok, err = pcall(function()
			result = s:UpdateAsync(keyFor(userId), function(old)
				-- Must be pure and non-yielding: UpdateAsync may call it more than once.
				local out = {}
				local base = 0
				if type(old) == "table" then
					for key, value in pairs(old) do
						out[key] = value
					end
					base = sanitize(old.Tokens)
				elseif type(old) == "number" then
					base = sanitize(old)
				end
				out.Tokens = sanitize(base + delta)
				out.UpdatedAt = os.time()
				return out
			end)
		end)

		if ok then
			local confirmed = snapshot
			if type(result) == "table" and type(result.Tokens) == "number" then
				confirmed = sanitize(result.Tokens)
			end
			local earnedSince = entry.Tokens - snapshot -- tokens collected while we were writing
			entry.Saved = confirmed
			if confirmed ~= snapshot then
				-- The store held a different total than we assumed (failed load, other server):
				-- adopt it so the player sees the real number.
				entry.Tokens = sanitize(confirmed + earnedSince)
				pushToPlayer(Players:GetPlayerByUserId(userId), entry.Tokens)
			end
			entry.LoadFailed = false
			success = true
			break
		end

		noteFailure("save", err)
		if storeDisabled then
			break
		end
		if attempt == 1 then
			task.wait(RETRY_DELAY)
		end
	end

	entry.Saving = false
	return success
end

-- Saves one player (pcall-safe, retries once, silent when DataStores are unavailable).
function DataService.Save(player)
	if not player then
		return false
	end
	local ok, result = pcall(saveEntry, player.UserId)
	if not ok then
		if not IS_STUDIO then
			warn("[DataService] Save errored: " .. tostring(result))
		end
		return false
	end
	return result == true
end

-- Frees the cache entry after the final save. Skipped if the same user already rejoined.
function DataService.Release(player)
	if not player then
		return
	end
	local userId = player.UserId
	local current = Players:GetPlayerByUserId(userId)
	if current and current ~= player then
		return
	end
	cache[userId] = nil
end

----------------------------------------------------------------------
-- Tokens
----------------------------------------------------------------------

function DataService.AddTokens(player, n)
	if not player or type(n) ~= "number" or n ~= n then
		return
	end
	local amount = math.floor(n + 0.5)
	if amount == 0 then
		return
	end
	local entry = ensureEntry(player.UserId)
	entry.Tokens = sanitize(entry.Tokens + amount)
	pushToPlayer(player, entry.Tokens)
end

function DataService.GetTokens(player)
	if not player then
		return 0
	end
	local entry = cache[player.UserId]
	if entry then
		return entry.Tokens
	end
	local attr = player:GetAttribute(Config.Attr.Tokens)
	if type(attr) == "number" then
		return attr
	end
	return 0
end

----------------------------------------------------------------------
-- Autosave + shutdown
----------------------------------------------------------------------

function DataService.StartAutosave()
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
			for _, player in ipairs(Players:GetPlayers()) do
				if shuttingDown then
					break
				end
				DataService.Save(player)
				task.wait(0.25) -- spread requests out to stay inside the DataStore budget
			end
		end
	end)
end

function DataService.BindToClose()
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
