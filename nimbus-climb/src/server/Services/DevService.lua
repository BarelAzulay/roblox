-- DevService: owner-only developer tools (Config.Dev). Lets the game's owner test everything: get every pet,
-- add tokens, restart / skip the tutorial and wipe their own data back to a brand-new player.
--
--   DevService.Init(deps)                          deps = { DataService, PetService, TutorialService, IndexService }
--   DevService.IsAllowed(player) -> bool           may yield ONCE per player for a group-owned game (group rank)
--   DevService.Run(player, command, arg, source) -> ok, message
--                                                  the ONE entry point of the DevCommand remote and of chat:
--                                                  rate limit, permission check, validation, then the command
--   DevService.Commands                            the command names, in help order
--
-- Who is a developer (checked again on EVERY command; the client is never trusted):
--   Config.Dev.Enabled and (
--       (Config.Dev.AllowInStudio and RunService:IsStudio())          everyone while testing in Roblox Studio
--    or the game's owner: game.CreatorType == User and UserId == game.CreatorId,
--       or for a group-owned game the group's owner (GetRankInGroup(CreatorId) == 255, pcall, cached per player)
--    or player.UserId is listed in Config.Dev.Admins )
-- Allowed players get the attribute NC_Dev = true (only a hint for the client's DEV button) and chat commands.
--
-- Commands (remote "DevCommand"(command, arg) or chat, case-insensitive):
--   allpets         one copy of every catalog pet the player does not own yet (Secret pets too), every pet marked
--                   discovered so the Pet Index fills up, then IndexService.Refresh
--   tokens [n]      DataService.AddTokens(n): n defaults to Config.Dev.GrantTokens, whole numbers only, clamped to
--                   1 .. Config.Dev.MaxTokensPerCommand (chat also takes "50,000", "50k", "1m")
--   reset           back to a brand-new player: tokens, pets, equipped pets, items, stats, Pet Index progress and
--                   rewards, Cash, Gems, home, pet levels (the lobby spot stays assigned for this session); the
--                   tutorial restarts too (see "tutorial"). Refused during a match.
--   tutorial        restart the tutorial from step 1: the stored progress goes back to a new player's, then
--                   TutorialService re-reads it through its Reload / Refresh / Restart(player) hook (the first that
--                   exists). Without such a hook the running tutorial cannot be rewound, so the command is refused
--                   and nothing changes.
--   skiptutorial    mark the tutorial done without the finish reward (TutorialService.HandleEvent(player, "Skip"))
--   devhelp         a toast listing the chat commands
-- After every change: DataService.MarkDirty + Sync (the menu updates at once) and a side toast "DEV: ..." (kind
-- "good"); refusals get a "bad" toast. Rate limit: 4 commands per 2 seconds per player. Every command is logged with
-- print("[NimbusClimb][Dev] ...") including the UserId. Nothing yields between reading and writing the profile.
--
-- Chat: Player.Chatted (fires for the legacy chat and for TextChatService) of allowed players; "/allpets",
-- "/tokens 50000", "/reset", "/tutorial", "/skiptutorial", "/devhelp". Other "/" messages are left alone.
-- Studio auto grant: with Config.Dev.StudioAutoGrant in Studio, every allowed player gets allpets + tokens once per
-- server, right after their profile loads.
--
-- Persistence note: DataService merges Discovered, IndexClaimed, Tutorial.Done / Gifted and best times so they only
-- ever grow (a gift can never be paid twice). With DataStores ON, a reset or tutorial restart of those fields
-- therefore only lasts until the next save; everything else (tokens, pets, items, stats, ...) is reset for good.
-- In Studio without API access (the default) everything is in memory anyway.
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local DevService = {}

DevService.Commands = { "allpets", "tokens", "reset", "tutorial", "skiptutorial", "devhelp" }

local TAG = "[NimbusClimb][Dev] "
local ATTR = "NC_Dev" -- player attribute: true for developers (a hint for the client's DEV button)
local RATE_COUNT = 4 -- commands ...
local RATE_WINDOW = 2 -- ... per this many seconds, per player
local MAX_COMMAND_LENGTH = 32
local MAX_CHAT_LENGTH = 200
local GROUP_OWNER_RANK = 255
local TOAST_SECONDS = 4
local HELP_SECONDS = 8

local KNOWN = {}
for _, name in ipairs(DevService.Commands) do
	KNOWN[name] = true
end

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
	warn("[DevService] could not load " .. name .. ": " .. tostring(result))
	return nil
end

local PetCatalog = loadModule(Shared, "PetCatalog")
local DataService = nil
local PetService = nil
local TutorialService = nil
local IndexService = nil

local function hasFunction(module, name)
	return type(module) == "table" and type(module[name]) == "function"
end

local function hasSignal(module, name)
	return type(module) == "table" and type(module[name]) == "table" and type(module[name].Connect) == "function"
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local rankCache = {} -- [player] = true / false: group owner (only successful GetRankInGroup answers are cached)
local recent = {} -- [player] = { os.clock() of the commands accepted in the current window }
local rateWarned = {} -- [player] = os.clock() of the last "slow down" toast
local chatConns = {} -- [player] = Chatted connection
local autoGranted = {} -- [userId] = true once the Studio auto grant ran in this server
local initialized = false

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function isLivePlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function devConfig()
	if type(Config.Dev) == "table" then
		return Config.Dev
	end
	return {}
end

local function isWhole(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n == math.floor(n)
end

local function commas(n)
	local ok, text = pcall(Util.Commas, n)
	if ok and type(text) == "string" then
		return text
	end
	return tostring(n)
end

local function who(player)
	return "UserId " .. tostring(player.UserId) .. " (" .. tostring(player.Name) .. ")"
end

-- An untrusted command name made safe for the log.
local function printable(value)
	if type(value) ~= "string" then
		return "<" .. type(value) .. ">"
	end
	return (string.gsub(string.sub(value, 1, MAX_COMMAND_LENGTH), "[^%w_%-]", "?"))
end

local function log(player, source, command, arg, outcome)
	local argText = ""
	if arg ~= nil then
		if type(arg) == "number" then
			argText = " " .. tostring(arg)
		else
			argText = " <" .. type(arg) .. ">"
		end
	end
	print(TAG .. who(player) .. " via " .. tostring(source) .. ": " .. printable(command) .. argText .. " -> " .. outcome)
end

local function notify(player, text, kind, duration)
	if not isLivePlayer(player) then
		return
	end
	local ok, remote = pcall(Remotes.Get, "Notify")
	if ok and remote then
		local sent, err = pcall(function()
			remote:FireClient(player, text, kind or "info", duration or TOAST_SECONDS)
		end)
		if not sent then
			warn("[DevService] Notify failed: " .. tostring(err))
		end
	end
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

local function markDirtyAndSync(player)
	if hasFunction(DataService, "MarkDirty") then
		DataService.MarkDirty(player)
	end
	if hasFunction(DataService, "Sync") then
		DataService.Sync(player)
	end
end

-- Empties a table in place (other modules may hold a reference to it).
local function wipe(t)
	if type(t) ~= "table" then
		return
	end
	for key in pairs(t) do
		t[key] = nil
	end
end

-- The profile table at holder[field], created when missing.
local function tableField(holder, field)
	local t = holder[field]
	if type(t) ~= "table" then
		t = {}
		holder[field] = t
	end
	return t
end

----------------------------------------------------------------------
-- Who may use the tools
----------------------------------------------------------------------

-- Owner of a group-owned game: rank 255 in that group. GetRankInGroup is a web call, so it runs in a pcall and
-- only a real answer is cached (a failure is tried again on the next command).
local function isGroupOwner(player, groupId)
	if type(groupId) ~= "number" or groupId <= 0 then
		return false
	end
	local cached = rankCache[player]
	if cached ~= nil then
		return cached
	end
	local ok, rank = pcall(function()
		return player:GetRankInGroup(groupId)
	end)
	if not ok then
		print(TAG .. "could not read the group rank of " .. who(player) .. ": " .. tostring(rank))
		return false
	end
	local owner = rank == GROUP_OWNER_RANK
	if player.Parent == Players then
		rankCache[player] = owner -- never cache a player who left while we asked
	end
	return owner
end

local function isOwner(player)
	local creatorType = game.CreatorType
	local creatorId = game.CreatorId
	if creatorType == Enum.CreatorType.User then
		return type(creatorId) == "number" and creatorId > 0 and player.UserId == creatorId
	elseif creatorType == Enum.CreatorType.Group then
		return isGroupOwner(player, creatorId)
	end
	return false
end

local function isAdmin(player, admins)
	if type(admins) ~= "table" then
		return false
	end
	for key, value in pairs(admins) do
		-- a list of UserIds (numbers or digit strings), or a map { [UserId] = true }
		if tonumber(value) == player.UserId or (value == true and tonumber(key) == player.UserId) then
			return true
		end
	end
	return false
end

function DevService.IsAllowed(player)
	if not isLivePlayer(player) then
		return false
	end
	local dev = devConfig()
	if dev.Enabled ~= true then
		return false
	end
	if dev.AllowInStudio == true and RunService:IsStudio() then
		return true
	end
	if isAdmin(player, dev.Admins) then
		return true
	end
	return isOwner(player)
end

-- Sliding window: true when another command fits into the last RATE_WINDOW seconds.
local function takeSlot(player)
	local now = os.clock()
	local kept = {}
	for _, at in ipairs(recent[player] or {}) do
		if now - at < RATE_WINDOW then
			kept[#kept + 1] = at
		end
	end
	if #kept >= RATE_COUNT then
		recent[player] = kept
		return false
	end
	kept[#kept + 1] = now
	recent[player] = kept
	return true
end

----------------------------------------------------------------------
-- Commands. Each one: (player, profile, arg) -> ok, message, changed. None of them yields.
----------------------------------------------------------------------

-- The TutorialService function that re-reads a player's progress from the profile (nil when it has none).
local function tutorialReloader()
	for _, name in ipairs({ "Reload", "Refresh", "Restart" }) do
		if hasFunction(TutorialService, name) then
			return TutorialService[name]
		end
	end
	return nil
end

-- Puts the stored tutorial progress back to a new player's and lets TutorialService pick it up.
local function rewindTutorial(player, profile, reload)
	local tutorial = tableField(profile, "Tutorial")
	tutorial.Step = 1
	tutorial.Done = false
	tutorial.Gifted = false
	if reload then
		local ok, err = pcall(reload, player)
		if not ok then
			warn("[DevService] TutorialService reload failed: " .. tostring(err))
		end
	end
end

local function cmdAllPets(player, profile)
	if not PetCatalog or type(PetCatalog.Pets) ~= "table" then
		return false, "the pet catalog is missing"
	end
	local pets = tableField(profile, "Pets")
	local added, total = 0, 0
	for _, def in ipairs(PetCatalog.Pets) do
		if type(def) == "table" and type(def.Id) == "string" then
			total = total + 1
			local owned = pets[def.Id]
			if type(owned) ~= "number" or owned < 1 then
				pets[def.Id] = 1
				added = added + 1
			end
			if hasFunction(DataService, "MarkDiscovered") then
				DataService.MarkDiscovered(player, def.Id)
			end
		end
	end
	if hasFunction(IndexService, "Refresh") then
		local ok, err = pcall(IndexService.Refresh, player)
		if not ok then
			warn("[DevService] IndexService.Refresh failed: " .. tostring(err))
		end
	end
	if added == 0 then
		return true, "you already own all " .. total .. " pets", false
	end
	return true, "you got " .. added .. " new pets: all " .. total .. " are yours!", true
end

local function cmdTokens(player, profile, arg)
	local dev = devConfig()
	local amount = arg
	if amount == nil then
		amount = isWhole(dev.GrantTokens) and dev.GrantTokens or 1000000
	end
	if not isWhole(amount) then
		return false, "tokens needs a whole number, like /tokens 50000"
	end
	local maxAmount = isWhole(dev.MaxTokensPerCommand) and dev.MaxTokensPerCommand or 100000000
	amount = math.max(1, math.min(amount, math.max(1, maxAmount)))
	if not hasFunction(DataService, "AddTokens") then
		return false, "tokens are unavailable right now"
	end
	DataService.AddTokens(player, amount)
	return true, "+" .. commas(amount) .. " Cloud Tokens", true
end

local function cmdReset(player, profile)
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return false, "leave the match first, then reset"
	end
	local reload = tutorialReloader()
	-- tokens through the public API so the HUD attribute and the leaderboard follow
	if hasFunction(DataService, "SpendTokens") and hasFunction(DataService, "GetTokens") then
		DataService.SpendTokens(player, DataService.GetTokens(player))
	end
	profile.Tokens = 0
	wipe(tableField(profile, "Pets"))
	wipe(tableField(profile, "Equipped"))
	wipe(tableField(profile, "Items"))
	local stats = tableField(profile, "Stats")
	stats.Matches, stats.Wins, stats.TokensEarned, stats.Spins = 0, 0, 0, 0
	wipe(tableField(stats, "BestTimes"))
	wipe(tableField(profile, "Discovered"))
	wipe(tableField(profile, "IndexClaimed"))
	profile.Cash = 0
	profile.Gems = 0
	local home = tableField(profile, "Home")
	home.Level, home.Prestige = 0, 0
	wipe(tableField(home, "Rooms"))
	wipe(tableField(profile, "PetLevels"))
	for _, attr in ipairs({ Config.Attr.Cash, Config.Attr.Gems }) do
		if attr and player:GetAttribute(attr) ~= nil then
			player:SetAttribute(attr, 0)
		end
	end
	-- the tutorial only restarts when TutorialService can re-read it (otherwise it stays as it is: consistent)
	local tutorialNote = ""
	if reload or not TutorialService then
		rewindTutorial(player, profile, reload)
	else
		tutorialNote = " (the tutorial restart is not in this build yet)"
	end
	-- the profile changed underneath every other service: PetService republishes the equipped pets and perks,
	-- IndexService forgets the completed groups (execute() then marks it dirty and syncs it to the client)
	if hasSignal(DataService, "ProfileRebased") then
		DataService.ProfileRebased:Fire(player, profile)
	end
	return true, "your data is reset: you are a brand-new player" .. tutorialNote, true
end

local function cmdTutorial(player, profile)
	local reload = tutorialReloader()
	if TutorialService and not reload then
		return false, "Restart tutorial is not in this build yet"
	end
	rewindTutorial(player, profile, reload)
	return true, "the tutorial starts again from step 1", true
end

local function cmdSkipTutorial(player, profile)
	if hasFunction(TutorialService, "HandleEvent") then
		local ok, success, reason = pcall(TutorialService.HandleEvent, player, "Skip")
		if not ok then
			warn("[DevService] TutorialService.HandleEvent failed: " .. tostring(success))
			return false, "the tutorial could not be skipped"
		end
		if success ~= true then
			return false, string.lower(tostring(reason or "the tutorial could not be skipped"))
		end
		return true, "tutorial skipped (no finish reward)", true
	end
	-- no TutorialService in this build: just store it as done
	local tutorial = tableField(profile, "Tutorial")
	if tutorial.Done == true then
		return false, "the tutorial is already finished"
	end
	tutorial.Done = true
	return true, "tutorial skipped (no finish reward)", true
end

local function cmdHelp()
	return true, "/allpets  /tokens 50000  /reset  /tutorial  /skiptutorial  /devhelp", false
end

local HANDLERS = {
	allpets = cmdAllPets,
	tokens = cmdTokens,
	reset = cmdReset,
	tutorial = cmdTutorial,
	skiptutorial = cmdSkipTutorial,
	devhelp = cmdHelp,
}

-- Validates and runs one command for an allowed player. Returns ok, message.
local function execute(player, command, arg, source)
	if type(command) ~= "string" or #command == 0 or #command > MAX_COMMAND_LENGTH then
		log(player, source, command, arg, "refused: bad command")
		notify(player, "DEV: that is not a command", "bad")
		return false, "bad command"
	end
	local name = string.lower(command)
	local handler = HANDLERS[name]
	if not handler then
		log(player, source, command, arg, "refused: unknown command")
		notify(player, "DEV: unknown command '" .. printable(command) .. "' (try /devhelp)", "bad")
		return false, "unknown command"
	end
	-- only "tokens" takes a value, and only a number
	if arg ~= nil and (name ~= "tokens" or type(arg) ~= "number") then
		log(player, source, name, arg, "refused: bad value")
		if name == "tokens" then
			notify(player, "DEV: tokens needs a whole number, like /tokens 50000", "bad")
		else
			notify(player, "DEV: " .. name .. " takes no value", "bad")
		end
		return false, "bad value"
	end
	local profile = getProfile(player)
	if not profile then
		log(player, source, name, arg, "refused: profile not loaded")
		notify(player, "DEV: your data is still loading, try again", "bad")
		return false, "profile not loaded"
	end
	local pok, ok, message, changed = pcall(handler, player, profile, arg)
	if not pok then
		warn("[DevService] " .. name .. " failed: " .. tostring(ok))
		log(player, source, name, arg, "error")
		notify(player, "DEV: " .. name .. " went wrong, see the output", "bad")
		return false, "error"
	end
	message = tostring(message or "")
	if not ok then
		log(player, source, name, arg, "refused: " .. message)
		notify(player, "DEV: " .. message, "bad")
		return false, message
	end
	if changed then
		markDirtyAndSync(player)
	end
	log(player, source, name, arg, "ok: " .. message)
	if name == "devhelp" then
		notify(player, "DEV: " .. message, "info", HELP_SECONDS)
	else
		notify(player, "DEV: " .. message, changed and "good" or "info")
	end
	return true, message
end

-- The one entry point of the DevCommand remote and of chat.
function DevService.Run(player, command, arg, source)
	if not isLivePlayer(player) then
		return false, "player unavailable"
	end
	source = tostring(source or "remote")
	if not takeSlot(player) then
		-- a developer gets one "slow down" toast per window; nobody else hears anything
		local now = os.clock()
		if player:GetAttribute(ATTR) == true and (rateWarned[player] == nil or now - rateWarned[player] >= RATE_WINDOW) then
			rateWarned[player] = now
			log(player, source, command, arg, "refused: rate limit")
			notify(player, "DEV: slow down (" .. RATE_COUNT .. " commands every " .. RATE_WINDOW .. " seconds)", "bad", 3)
		end
		return false, "rate limited"
	end
	local allowed = DevService.IsAllowed(player) -- may yield once for a group game; nothing is held meanwhile
	if not isLivePlayer(player) then
		return false, "player unavailable"
	end
	if not allowed then
		log(player, source, command, arg, "refused: not a developer")
		return false, "not allowed"
	end
	return execute(player, command, arg, source)
end

----------------------------------------------------------------------
-- Chat
----------------------------------------------------------------------

-- "50000", "50,000", "50k", "1.5m" -> number (nil when it is not a number)
local function parseAmount(text)
	local s = string.gsub(string.lower(text), "[,_%s]", "")
	local digits, suffix = string.match(s, "^(%-?[%d%.]+)([kmb]?)$")
	local n = tonumber(digits)
	if not n then
		return nil
	end
	if suffix == "k" then
		n = n * 1000
	elseif suffix == "m" then
		n = n * 1000000
	elseif suffix == "b" then
		n = n * 1000000000
	end
	return n
end

local function onChatted(player, message)
	if type(message) ~= "string" or #message > MAX_CHAT_LENGTH then
		return
	end
	local word, rest = string.match(message, "^%s*/(%S+)%s*(.-)%s*$")
	if not word then
		return
	end
	word = string.lower(word)
	if not KNOWN[word] then
		return -- not one of ours (/e dance, /w name ...): leave it alone
	end
	local arg = nil
	if word == "tokens" and rest ~= "" then
		arg = parseAmount(rest)
		if arg == nil then
			arg = rest -- not a number: Run refuses it with a "bad" toast
		end
	end
	local ok, err = pcall(DevService.Run, player, word, arg, "chat")
	if not ok then
		warn("[DevService] chat command failed: " .. tostring(err))
	end
end

local function connectChat(player)
	if chatConns[player] then
		return
	end
	chatConns[player] = player.Chatted:Connect(function(message)
		onChatted(player, message)
	end)
end

----------------------------------------------------------------------
-- Players
----------------------------------------------------------------------

-- Studio auto grant: every pet + GrantTokens tokens once per server, after the profile loaded.
local function autoGrant(player)
	local dev = devConfig()
	if dev.StudioAutoGrant ~= true or not RunService:IsStudio() or not isLivePlayer(player) then
		return
	end
	if autoGranted[player.UserId] or not getProfile(player) then
		return
	end
	local allowed = DevService.IsAllowed(player)
	-- checked again after IsAllowed: the join handler and ProfileLoaded can both get here
	if not allowed or autoGranted[player.UserId] or not isLivePlayer(player) or not getProfile(player) then
		return
	end
	autoGranted[player.UserId] = true
	execute(player, "allpets", nil, "studio auto grant")
	execute(player, "tokens", nil, "studio auto grant")
end

local function onPlayerAdded(player)
	task.spawn(function()
		local allowed = DevService.IsAllowed(player)
		if not allowed or not isLivePlayer(player) then
			return
		end
		player:SetAttribute(ATTR, true)
		connectChat(player)
		print(TAG .. "developer tools on for " .. who(player) .. " (DEV button, /devhelp)")
		autoGrant(player)
	end)
end

local function onPlayerRemoving(player)
	local conn = chatConns[player]
	if conn then
		pcall(function()
			conn:Disconnect()
		end)
	end
	chatConns[player] = nil
	rankCache[player] = nil
	recent[player] = nil
	rateWarned[player] = nil
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------

function DevService.Init(deps)
	if initialized then
		return
	end
	initialized = true
	deps = type(deps) == "table" and deps or {}
	local services = script.Parent
	DataService = deps.DataService or loadModule(services, "DataService")
	PetService = deps.PetService or loadModule(services, "PetService")
	TutorialService = deps.TutorialService
	IndexService = deps.IndexService
	if not PetCatalog then
		PetCatalog = loadModule(Shared, "PetCatalog")
	end
	if devConfig().Enabled ~= true then
		print(TAG .. "developer tools are switched off (Config.Dev.Enabled)")
		return
	end
	if not DataService then
		warn("[DevService] DataService is missing: developer tools are off")
		return
	end

	local okRemote, remote = pcall(Remotes.Get, "DevCommand")
	if okRemote and remote then
		remote.OnServerEvent:Connect(function(player, command, arg)
			local ok, err = pcall(DevService.Run, player, command, arg, "button")
			if not ok then
				warn("[DevService] DevCommand failed: " .. tostring(err))
			end
		end)
	else
		warn("[DevService] DevCommand remote is missing: " .. tostring(remote))
	end

	if hasSignal(DataService, "ProfileLoaded") then
		DataService.ProfileLoaded:Connect(function(player)
			autoGrant(player)
		end)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

return DevService
