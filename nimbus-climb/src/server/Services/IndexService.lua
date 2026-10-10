-- IndexService: Pet Index group rewards (ARCHITECTURE_V3.md section 3).
--
--   IndexService.Init(deps)                       deps = { DataService =, PetService = }
--   IndexService.CanClaim(player, groupId) -> bool, reason
--   IndexService.Claim(player, groupId)    -> ok, reason
--   IndexService.Completed                        Util.Signal, Fire(player, groupId) when a group becomes complete
--                                                 (its last pet was just discovered; the tutorial may listen)
--   Extras: IndexService.Claimed (Util.Signal, Fire(player, groupId, tokens) after a successful claim),
--           IndexService.GetProgress(player) -> { [groupId] = { Found, Total, Complete, Claimed, Reward } }
--
-- A group is one rarity (PetCatalog.IndexGroups). It is complete when every pet in it is in the profile's
-- Discovered set; its Config.Index reward can be claimed once (Profile.IndexClaimed[groupId] = true). Claims wait
-- while DataService.IsProvisional(player) (a load that failed during an outage: the defaults cannot tell which
-- rewards were already claimed).
-- Everything is server authoritative: the client only sends a group id through the IndexClaim remote, which
-- is type checked and rate limited; the reward goes through DataService.AddTokens, then the profile is synced.
--
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local IndexService = {}
IndexService.Completed = Util.Signal()
IndexService.Claimed = Util.Signal()

local CLAIM_COOLDOWN = 0.5 -- seconds per player between IndexClaim requests
local MAX_ID_LENGTH = 48
local REMINDER_DELAY = 8 -- seconds after joining before the "unclaimed reward" reminder toast

----------------------------------------------------------------------
-- Collaborators (resolved defensively: other modules may be missing or broken)
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
	warn("[IndexService] could not load " .. name .. ": " .. tostring(result))
	return nil
end

local PetCatalog = loadModule(Shared, "PetCatalog")
local DataService = nil
local PetService = nil

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local groups = {} -- array of { Id, Rarity, Pets = {PetDef...}, Reward } in rarity order
local groupById = {} -- [groupId] = group
local groupOfPet = {} -- [petId] = groupId

local completeState = {} -- [player] = { [groupId] = true } groups already complete (edge detection)
local lastClaim = {} -- [player] = os.clock() of the last accepted IndexClaim
local reminded = {} -- [player] = true once the unclaimed-reward reminder was sent this session
local initialized = false

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function isLivePlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function fireClient(remoteName, player, ...)
	local ok, remote = pcall(Remotes.Get, remoteName)
	if ok and remote and player and player.Parent then
		remote:FireClient(player, ...)
	end
end

local function notify(player, text, kind, duration)
	fireClient("Notify", player, text, kind or "info", duration or 4)
end

local function commas(n)
	local ok, text = pcall(Util.Commas, n)
	if ok and type(text) == "string" then
		return text
	end
	return tostring(n)
end

-- (Re)builds the group tables from the catalog (static data, so once is enough).
local function buildGroups()
	groups, groupById, groupOfPet = {}, {}, {}
	if not PetCatalog or type(PetCatalog.IndexGroups) ~= "function" then
		return
	end
	local ok, list = pcall(PetCatalog.IndexGroups)
	if not ok or type(list) ~= "table" then
		warn("[IndexService] PetCatalog.IndexGroups failed: " .. tostring(list))
		return
	end
	for _, group in ipairs(list) do
		if type(group) == "table" and type(group.Id) == "string" and type(group.Pets) == "table" and #group.Pets > 0 then
			table.insert(groups, group)
			groupById[group.Id] = group
			for _, def in ipairs(group.Pets) do
				if type(def) == "table" and type(def.Id) == "string" then
					groupOfPet[def.Id] = group.Id
				end
			end
		end
	end
end

-- Token reward of a group (Config.Index is the source of truth; the catalog copy is a fallback).
local function rewardTokens(group)
	local index = Config.Index
	local rewards = type(index) == "table" and index.Rewards
	local reward = type(rewards) == "table" and rewards[group.Id]
	if type(reward) ~= "table" then
		reward = group.Reward
	end
	local tokens = type(reward) == "table" and reward.Tokens
	if type(tokens) == "number" and tokens == tokens and tokens > 0 and tokens < math.huge then
		return math.floor(tokens)
	end
	return 0
end

local function getProfile(player)
	if not DataService or type(DataService.GetProfile) ~= "function" then
		return nil
	end
	local ok, profile = pcall(DataService.GetProfile, player)
	if ok and type(profile) == "table" then
		return profile
	end
	return nil
end

-- found, total for one group of a profile (an owned pet always counts as discovered).
local function groupProgress(profile, group)
	local discovered = type(profile.Discovered) == "table" and profile.Discovered or {}
	local owned = type(profile.Pets) == "table" and profile.Pets or {}
	local found = 0
	for _, def in ipairs(group.Pets) do
		local count = owned[def.Id]
		if discovered[def.Id] == true or (type(count) == "number" and count > 0) then
			found = found + 1
		end
	end
	return found, #group.Pets
end

local function isClaimed(profile, groupId)
	return type(profile.IndexClaimed) == "table" and profile.IndexClaimed[groupId] == true
end

local function isComplete(profile, group)
	local found, total = groupProgress(profile, group)
	return total > 0 and found >= total
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function IndexService.CanClaim(player, groupId)
	if not isLivePlayer(player) then
		return false, "Player unavailable"
	end
	if type(groupId) ~= "string" or #groupId == 0 or #groupId > MAX_ID_LENGTH then
		return false, "Unknown Index group"
	end
	if not DataService or #groups == 0 then
		return false, "The Pet Index is unavailable right now"
	end
	local group = groupById[groupId]
	if not group then
		return false, "Unknown Index group"
	end
	local profile = getProfile(player)
	if not profile then
		return false, "Your data is still loading"
	end
	-- a profile whose load failed (DataStore outage) holds defaults: its IndexClaimed cannot tell what was claimed
	if type(DataService.IsProvisional) == "function" then
		local okProvisional, provisional = pcall(DataService.IsProvisional, player)
		if okProvisional and provisional == true then
			return false, "Your data is still loading"
		end
	end
	if isClaimed(profile, groupId) then
		return false, "Already claimed"
	end
	local found, total = groupProgress(profile, group)
	if found < total then
		return false, string.format("Discover every %s pet first (%d/%d)", groupId, found, total)
	end
	if rewardTokens(group) <= 0 then
		return false, "This group has no reward"
	end
	return true
end

function IndexService.Claim(player, groupId)
	local ok, reason = IndexService.CanClaim(player, groupId)
	if not ok then
		return false, reason
	end
	local group = groupById[groupId]
	local profile = getProfile(player)
	if not group or not profile then
		return false, "Your data is still loading"
	end
	local tokens = rewardTokens(group)
	-- Nothing below yields: the claimed flag is written before the tokens, so a claim pays exactly once.
	if type(profile.IndexClaimed) ~= "table" then
		profile.IndexClaimed = {}
	end
	profile.IndexClaimed[groupId] = true
	if type(DataService.AddTokens) == "function" then
		DataService.AddTokens(player, tokens)
	end
	if type(DataService.MarkDirty) == "function" then
		DataService.MarkDirty(player)
	end
	if type(DataService.Sync) == "function" then
		DataService.Sync(player)
	end
	notify(player, "Pet Index: " .. groupId .. " complete! +" .. commas(tokens) .. " Cloud Tokens", "token", 4)
	IndexService.Claimed:Fire(player, groupId, tokens)
	return true
end

-- Extra: per-group progress for a player (empty table until the profile is loaded).
function IndexService.GetProgress(player)
	local out = {}
	local profile = player and getProfile(player)
	if not profile then
		return out
	end
	for _, group in ipairs(groups) do
		local found, total = groupProgress(profile, group)
		out[group.Id] = {
			Found = found,
			Total = total,
			Complete = total > 0 and found >= total,
			Claimed = isClaimed(profile, group.Id),
			Reward = rewardTokens(group),
		}
	end
	return out
end

----------------------------------------------------------------------
-- Completion tracking (Completed signal + side toasts)
----------------------------------------------------------------------

-- Remembers which groups are complete right now without announcing them (join / rebase).
local function primePlayer(player)
	local profile = getProfile(player)
	if not profile then
		return
	end
	local state = {}
	local unclaimed = 0
	for _, group in ipairs(groups) do
		if isComplete(profile, group) then
			state[group.Id] = true
			if not isClaimed(profile, group.Id) and rewardTokens(group) > 0 then
				unclaimed = unclaimed + 1
			end
		end
	end
	completeState[player] = state
	-- once per session: a gentle side toast when a finished group still waits for its reward
	if unclaimed > 0 and not reminded[player] then
		reminded[player] = true
		task.delay(REMINDER_DELAY, function()
			if isLivePlayer(player) then
				local text = "You have an unclaimed Pet Index reward! Open the Index to claim it."
				if unclaimed > 1 then
					text = "You have " .. unclaimed .. " unclaimed Pet Index rewards! Open the Index to claim them."
				end
				notify(player, text, "good", 5)
			end
		end)
	end
end

-- After a discovery: fires Completed for every group that just became complete.
local function checkCompletions(player, petId)
	if not isLivePlayer(player) then
		return
	end
	local profile = getProfile(player)
	if not profile then
		return
	end
	local state = completeState[player]
	if not state then
		state = {}
		completeState[player] = state
	end
	-- the rolled pet's group first (the common case), then the rest (cheap: a handful of groups)
	local order = {}
	local first = type(petId) == "string" and groupOfPet[petId]
	if first and groupById[first] then
		table.insert(order, groupById[first])
	end
	for _, group in ipairs(groups) do
		if group.Id ~= first then
			table.insert(order, group)
		end
	end
	for _, group in ipairs(order) do
		if not state[group.Id] and isComplete(profile, group) then
			state[group.Id] = true
			if not isClaimed(profile, group.Id) then
				local tokens = rewardTokens(group)
				if tokens > 0 then
					notify(player, "Pet Index: every " .. group.Id .. " pet found! Claim " .. commas(tokens) .. " tokens in the Index.", "good", 5)
				end
			end
			IndexService.Completed:Fire(player, group.Id)
		end
	end
end

-- Extra: re-checks a player's groups after a discovery that did not come through PetService.Rolled.
function IndexService.Refresh(player, petId)
	checkCompletions(player, petId)
end

----------------------------------------------------------------------
-- Remote + lifecycle wiring
----------------------------------------------------------------------

local function connectRemote()
	local ok, remote = pcall(Remotes.Get, "IndexClaim")
	if not ok or not remote then
		warn("[IndexService] remote IndexClaim is missing (did Remotes.Init run?)")
		return
	end
	remote.OnServerEvent:Connect(function(player, groupId)
		if not isLivePlayer(player) then
			return
		end
		local now = os.clock()
		local last = lastClaim[player]
		if last and now - last < CLAIM_COOLDOWN then
			return
		end
		lastClaim[player] = now
		if type(groupId) ~= "string" or #groupId == 0 or #groupId > MAX_ID_LENGTH then
			return
		end
		local pok, success, reason = pcall(IndexService.Claim, player, groupId)
		if not pok then
			warn("[IndexService] Claim errored: " .. tostring(success))
			notify(player, "Something went wrong, try again", "bad", 3)
			return
		end
		if not success and reason then
			notify(player, tostring(reason), "bad", 3)
		end
	end)
end

local function hasSignal(module, name)
	return type(module) == "table" and type(module[name]) == "table" and type(module[name].Connect) == "function"
end

local function connectSignals()
	if hasSignal(PetService, "Rolled") then
		PetService.Rolled:Connect(function(player, petId)
			checkCompletions(player, petId)
		end)
	else
		warn("[IndexService] PetService.Rolled is missing: Index completions are only checked on claim")
	end
	if hasSignal(DataService, "ProfileLoaded") then
		DataService.ProfileLoaded:Connect(function(player)
			primePlayer(player)
		end)
	end
	if hasSignal(DataService, "ProfileRebased") then
		DataService.ProfileRebased:Connect(function(player)
			primePlayer(player)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		completeState[player] = nil
		lastClaim[player] = nil
		reminded[player] = nil
	end)
	-- players whose profile loaded before Init
	for _, player in ipairs(Players:GetPlayers()) do
		if getProfile(player) then
			task.spawn(primePlayer, player)
		end
	end
end

function IndexService.Init(deps)
	if initialized then
		return
	end
	initialized = true
	if type(deps) == "table" then
		DataService = deps.DataService
		PetService = deps.PetService
	end
	local services = script.Parent
	if type(DataService) ~= "table" then
		DataService = loadModule(services, "DataService")
	end
	if type(PetService) ~= "table" then
		PetService = loadModule(services, "PetService")
	end
	if not PetCatalog then
		PetCatalog = loadModule(Shared, "PetCatalog")
	end
	buildGroups()
	if #groups == 0 then
		warn("[IndexService] no Pet Index groups (PetCatalog missing?): claims are refused")
	end
	if not DataService then
		warn("[IndexService] DataService is missing: claims are refused")
	end
	connectRemote()
	connectSignals()
end

return IndexService
