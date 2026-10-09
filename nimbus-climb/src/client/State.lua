-- State: the client's read-only mirror of the player's saved profile (pets, items, stats, perks, and the v3
-- Pet Index + tutorial progress).
--
--   State.Init()                 connects Remotes.ProfileSync and asks the server for a snapshot (safe to call twice)
--   State.Get() -> snapshot      never nil; the snapshot is replaced (never mutated by us) on every ProfileSync,
--                                so a table you hold stays internally consistent. Do not write to it.
--   State.Changed                Util.Signal; Fire(snapshot) after every ProfileSync
--   State.OwnedCount(petId)      State.IsEquipped(petId)     State.EquippedCount(petId)
--   State.ItemCount(itemId)      State.Tokens()  (reads the CloudTokens attribute, falls back to the snapshot)
--   v3 (ARCHITECTURE_V3.md sections 1 + 3):
--   State.IsDiscovered(petId)    true once the pet was ever owned / rolled (an owned pet always counts)
--   State.IsClaimed(groupId)     true once that Pet Index group reward was claimed
--
-- Extras (not part of the cross-module contract): State.IsLoaded(), State.Perks(), State.Stats(),
-- State.EquippedList(), State.TokensChanged (Signal, Fire(tokens) when the CloudTokens attribute changes),
-- State.DiscoveredCount(petIdList|nil), State.Tutorial() -> { Step, Done, Gifted }.
--
-- The snapshot shape (ARCHITECTURE_V2.md section 1 + ARCHITECTURE_V3.md section 1):
--   { Tokens, Pets = {[petId]=count}, Equipped = {petId,...}, Items = {[itemId]=count},
--     Stats = { Matches, Wins, TokensEarned, Spins, BestTimes = {[diffId]=sec} }, SpotIndex, Perks = {...},
--     Discovered = {[petId]=true}, IndexClaimed = {[groupId]=true}, Tutorial = { Step, Done, Gifted } }
-- Whatever arrives is sanitised here, so UI code can index it without nil/type checks.
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local State = {}

State.Changed = Util.Signal()
State.TokensChanged = Util.Signal()

local PERK_KEYS = { "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }
local STAT_KEYS = { "Matches", "Wins", "TokensEarned", "Spins" }
local RETRY_DELAYS = { 2, 4, 8, 15 } -- seconds between RequestProfile retries while no snapshot arrived
local MAX_ID_LENGTH = 64 -- ids longer than this are junk
local MAX_TUTORIAL_STEP = 1000

local current = nil -- the live snapshot (always a table once the module is loaded)
local loaded = false -- true after the first ProfileSync
local initialised = false
local requestRemote = nil

----------------------------------------------------------------------
-- Sanitising
----------------------------------------------------------------------
local function num(value, default)
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return default
end

local function validId(key)
	return type(key) == "string" and key ~= "" and #key <= MAX_ID_LENGTH
end

-- { [id] = positive integer count } from a possibly messy table.
local function countMap(raw)
	local out = {}
	if type(raw) == "table" then
		for key, value in pairs(raw) do
			if type(key) == "string" and type(value) == "number" and value >= 1 then
				out[key] = math.floor(value)
			end
		end
	end
	return out
end

-- { [id] = true } from a set ({id = true}), a count map ({id = 2}) or a plain list ({"a", "b"}).
local function idSet(raw)
	local out = {}
	if type(raw) ~= "table" then
		return out
	end
	for key, value in pairs(raw) do
		if validId(key) and (value == true or (type(value) == "number" and value > 0)) then
			out[key] = true
		elseif type(key) == "number" and validId(value) then
			out[value] = true
		end
	end
	return out
end

local function newTutorial()
	return { Step = 1, Done = false, Gifted = false }
end

local function cleanTutorial(raw)
	local t = newTutorial()
	if type(raw) == "table" then
		local step = num(raw.Step, 1)
		if step >= 1 then
			t.Step = math.min(math.floor(step), MAX_TUTORIAL_STEP)
		end
		t.Done = raw.Done == true
		t.Gifted = raw.Gifted == true
	end
	return t
end

local function newSnapshot()
	local perks = {}
	for _, key in ipairs(PERK_KEYS) do
		perks[key] = 0
	end
	local stats = { BestTimes = {} }
	for _, key in ipairs(STAT_KEYS) do
		stats[key] = 0
	end
	return {
		Tokens = 0,
		Pets = {},
		Equipped = {},
		Items = {},
		Stats = stats,
		SpotIndex = nil,
		Perks = perks,
		-- v3
		Discovered = {},
		IndexClaimed = {},
		Tutorial = newTutorial(),
	}
end

local function normalise(raw)
	local snap = newSnapshot()
	if type(raw) ~= "table" then
		return snap
	end
	snap.Tokens = math.max(0, math.floor(num(raw.Tokens, 0)))
	snap.Pets = countMap(raw.Pets)
	snap.Items = countMap(raw.Items)
	if type(raw.Equipped) == "table" then
		for _, id in ipairs(raw.Equipped) do
			if type(id) == "string" then
				table.insert(snap.Equipped, id)
			end
		end
	end
	if type(raw.Stats) == "table" then
		for _, key in ipairs(STAT_KEYS) do
			snap.Stats[key] = num(raw.Stats[key], 0)
		end
		if type(raw.Stats.BestTimes) == "table" then
			for id, seconds in pairs(raw.Stats.BestTimes) do
				if type(id) == "string" and type(seconds) == "number" then
					snap.Stats.BestTimes[id] = seconds
				end
			end
		end
	end
	if type(raw.Perks) == "table" then
		for _, key in ipairs(PERK_KEYS) do
			snap.Perks[key] = num(raw.Perks[key], 0)
		end
	end
	snap.SpotIndex = num(raw.SpotIndex, nil)

	-- v3: every owned pet counts as discovered, even when the server's set lags behind
	snap.Discovered = idSet(raw.Discovered)
	for id in pairs(snap.Pets) do
		if validId(id) then
			snap.Discovered[id] = true
		end
	end
	snap.IndexClaimed = idSet(raw.IndexClaimed)
	snap.Tutorial = cleanTutorial(raw.Tutorial)
	return snap
end

current = newSnapshot()

----------------------------------------------------------------------
-- Reading
----------------------------------------------------------------------
local function attributeTokens()
	local player = Players.LocalPlayer
	if not player then
		return nil
	end
	local value = player:GetAttribute(Config.Attr.Tokens)
	if type(value) == "number" then
		return value
	end
	return nil
end

function State.Get()
	-- keep the token field in step with the replicated attribute (the attribute changes before the sync)
	local tokens = attributeTokens()
	if tokens ~= nil and current.Tokens ~= tokens then
		current.Tokens = tokens
	end
	return current
end

function State.IsLoaded()
	return loaded
end

function State.OwnedCount(petId)
	return current.Pets[petId] or 0
end

function State.EquippedCount(petId)
	local n = 0
	for _, id in ipairs(current.Equipped) do
		if id == petId then
			n = n + 1
		end
	end
	return n
end

function State.IsEquipped(petId)
	return State.EquippedCount(petId) > 0
end

function State.ItemCount(itemId)
	return current.Items[itemId] or 0
end

function State.Tokens()
	local tokens = attributeTokens()
	if tokens ~= nil then
		return tokens
	end
	return current.Tokens or 0
end

function State.Perks()
	return current.Perks
end

function State.Stats()
	return current.Stats
end

-- A copy, so callers may sort / edit it freely.
function State.EquippedList()
	local out = {}
	for i, id in ipairs(current.Equipped) do
		out[i] = id
	end
	return out
end

-- v3: Pet Index
function State.IsDiscovered(petId)
	if type(petId) ~= "string" then
		return false
	end
	return current.Discovered[petId] == true or (current.Pets[petId] or 0) > 0
end

function State.IsClaimed(groupId)
	if type(groupId) ~= "string" then
		return false
	end
	return current.IndexClaimed[groupId] == true
end

-- How many of `petIds` (a list of ids or of PetDefs) are discovered; without a list, every discovered id.
function State.DiscoveredCount(petIds)
	local n = 0
	if type(petIds) == "table" then
		for _, entry in ipairs(petIds) do
			local id = entry
			if type(entry) == "table" then
				id = entry.Id
			end
			if State.IsDiscovered(id) then
				n = n + 1
			end
		end
		return n
	end
	for _ in pairs(current.Discovered) do
		n = n + 1
	end
	return n
end

-- v3: tutorial progress as saved in the profile (TutorialState carries the live step text).
function State.Tutorial()
	return current.Tutorial
end

----------------------------------------------------------------------
-- Server traffic
----------------------------------------------------------------------
local function apply(raw)
	if type(raw) ~= "table" then
		return
	end
	current = normalise(raw)
	loaded = true
	State.Changed:Fire(State.Get())
end

local function request()
	if requestRemote then
		pcall(function()
			requestRemote:FireServer()
		end)
	end
end

function State.Init()
	if initialised then
		return
	end
	initialised = true

	local okSync, syncRemote = pcall(Remotes.Get, "ProfileSync")
	if okSync and syncRemote then
		syncRemote.OnClientEvent:Connect(apply)
	else
		warn("[State] ProfileSync remote is unavailable: " .. tostring(syncRemote))
	end
	local okReq, req = pcall(Remotes.Get, "RequestProfile")
	if okReq and req then
		requestRemote = req
	else
		warn("[State] RequestProfile remote is unavailable: " .. tostring(req))
	end

	local player = Players.LocalPlayer
	if player then
		player:GetAttributeChangedSignal(Config.Attr.Tokens):Connect(function()
			State.TokensChanged:Fire(State.Tokens())
		end)
	end

	request()
	-- the first sync may have been sent before we were listening: ask again until one arrives
	task.spawn(function()
		for _, seconds in ipairs(RETRY_DELAYS) do
			task.wait(seconds)
			if loaded then
				return
			end
			request()
		end
	end)
end

return State
