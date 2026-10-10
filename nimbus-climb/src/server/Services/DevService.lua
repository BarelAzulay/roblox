-- DevService: owner-only developer tools (Config.Dev). Lets the game's owner test everything: get every pet,
-- add tokens, restart / skip the tutorial and wipe their own data back to a brand-new player.
--
--   DevService.Init(deps)                          deps = { DataService, PetService, TutorialService, IndexService }
--                                                  (PetService is not needed: pets are written into the profile the
--                                                  way PetService does it, and ProfileRebased refreshes its attributes)
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
-- Allowed players get chat commands and two hints for their client, set on their PlayerGui (a PlayerGui only
-- replicates to its own player; an attribute on the Player itself would tell every client who the developers are):
--   NC_Dev = true            show the DEV button
--   NC_DevTutorial = true    show "Restart tutorial" (only when TutorialService has the Reload hook, see "tutorial")
-- They are only hints: the server checks the permission again on every command.
--
-- Commands (remote "DevCommand"(command, arg) or chat, case-insensitive):
--   allpets         one copy of every catalog pet the player does not own yet (Secret pets too), every pet marked
--                   discovered so the Pet Index fills up, then IndexService.Refresh
--   tokens [n]      DataService.AddTokens(n): n defaults to Config.Dev.GrantTokens, whole numbers only, clamped to
--                   1 .. Config.Dev.MaxTokensPerCommand (chat also takes "50,000", "50k", "1m")
--   reset           back to a brand-new player: tokens, pets, equipped pets, items, stats, Pet Index progress and
--                   rewards, Cash, Gems, home, pet levels (the lobby spot stays assigned for this session). The
--                   tutorial starts again as a new player's (gift and finish reward included: the reset took those
--                   tokens) when TutorialService has the Reload hook. Without it a tutorial that already paid its
--                   gift is ended as skipped, because every step from "spin" on needs the tokens and pets the reset
--                   just took (it would wait forever); an earlier tutorial carries on. Then
--                   DataService.ProfileRebased fires so PetService republishes the equipped pets / perks and
--                   IndexService forgets the completed groups. Refused during a match.
--   tutorial        replay the tutorial from step 1. Needs the hook TutorialService.Reload(player, { Replay = true }):
--                   it drops the running tutorial and reads it again from the profile; Replay = true means the
--                   finish reward is not paid again. The stored progress goes back to step 1 with Gifted kept, so
--                   the "spin" gift is not paid again either (rewards are never paid twice). Without the hook the
--                   command is refused, nothing changes, and the panel hides the button (NC_DevTutorial).
--   skiptutorial    mark the tutorial done without the finish reward (TutorialService.HandleEvent(player, "Skip"))
--   devhelp         two toasts listing the chat commands (the pet showcase ones, then the others)
-- The pet showcase (nothing is saved; the pets are built on the developer's OWN client only, by
-- client/Controllers/DevPetShow.lua, through the server -> client remote DevPetShow(action, payload)):
--   pet <pet> [stage]       one pet in front of you, at stage 0 (normal, the default), 1 (evolved) or 2 (second
--                           evolution, Epic pets and up). <pet> is its name or id, spaces and case do not matter and
--                           a unique part is enough ("/pet cloudy 2"); stage words: normal, evolved, evolved2 / max.
--                           -> Spawn { PetId, Stage }
--   pets [stage]            every pet (that has the stage) lined up in front of you -> Lineup { Stage, PetIds }
--   evolve <pet|all> [stage]   the evolution animation: with no stage the whole line (normal -> evolved, then ->
--                           evolved II for Epic+), 1 = normal -> evolved, 2 = evolved -> evolved II; "all" plays
--                           every pet's evolutions one after another -> Evolve { Steps = { {PetId, From, To}, ... } }
--   clearpets               removes the showcase pets and stops an evolution -> Clear {}
-- They need no loaded profile and run while it is provisional; they change no data.
-- After every change: DataService.MarkDirty + Sync (the menu updates at once) and a side toast "DEV: ..." (kind
-- "good"); refusals get a "bad" toast. Rate limit: 4 commands per 2 seconds per player. Every command is logged with
-- print("[NimbusClimb][Dev] ...") including the UserId. Nothing yields between reading and writing the profile.
--
-- Chat: "/allpets", "/tokens 50000", "/reset", "/tutorial", "/skiptutorial", "/pet cloudy dragon 2", "/pets 1",
-- "/evolve all", "/clearpets", "/devhelp", typed in the GAME's chat (not Studio's command bar). Two ways in, one
-- parser (onChatted): Player.Chatted of allowed players (the legacy chat), and one TextChatCommand per command
-- (PrimaryAlias "/<command>", children of TextChatService, made at Init when the place uses TextChatService):
-- the new chat only hands a "/" message to the game when a TextChatCommand claims it, and claimed commands stay
-- out of the public chat. Their Triggered event fires for every player; the permission check is the same.
-- The same text from the same player again within DUPLICATE_WINDOW seconds is dropped (both ways may fire).
-- Other "/" messages are left alone.
-- Studio auto grant: with Config.Dev.StudioAutoGrant in Studio, every allowed player gets allpets + tokens once per
-- server, right after their profile loads (a provisional profile waits until DataService.ProfileRebased says it
-- recovered).
-- The DevCommand listener is connected even when Config.Dev.Enabled is false (or DataService is missing): Roblox
-- queues every event fired at a RemoteEvent nobody listens to, so a switched-off build must still drop them at once
-- (Run rate-limits them and IsAllowed refuses everybody).
--
-- Persistence: DataService merges Discovered, IndexClaimed, Tutorial.Done / Gifted and best times so they only
-- ever grow (a gift can never be paid twice). reset and tutorial therefore call DataService.ResetFields for the
-- fields they rewind (reset: Discovered, IndexClaimed, best times and the rewound Tutorial; tutorial: Tutorial):
-- the next successful save writes the session's values over the stored ones, so the reset lasts with DataStores
-- on (the live game, Studio with API access) and a replay is not ended by the next autosave. Everything else
-- (tokens, pets, items, stats, ...) follows through the normal delta save.
-- While DataService.IsProvisional(player) (the profile's load failed during a DataStore outage and the real save
-- is still being read) only tokens and devhelp run: allpets, reset, tutorial and skiptutorial would work on stand-in
-- defaults, so they are refused with "your data is still loading".
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local DevService = {}

DevService.Commands = { "allpets", "tokens", "reset", "tutorial", "skiptutorial", "pet", "pets", "evolve", "clearpets", "devhelp" }

local TAG = "[NimbusClimb][Dev] "
local ATTR = "NC_Dev" -- PlayerGui attribute: true for developers (a hint for the client's DEV button)
local ATTR_TUTORIAL = "NC_DevTutorial" -- PlayerGui attribute: true when "Restart tutorial" works in this build
local PLAYER_GUI_WAIT = 10 -- seconds to wait for a joining player's PlayerGui
local RATE_COUNT = 4 -- commands ...
local RATE_WINDOW = 2 -- ... per this many seconds, per player
local MAX_COMMAND_LENGTH = 32
local MAX_CHAT_LENGTH = 200
local DUPLICATE_WINDOW = 0.35 -- seconds: one chat line seen twice (Player.Chatted + TextChatCommand) runs once
local GROUP_OWNER_RANK = 255
local TOAST_SECONDS = 4
local HELP_SECONDS = 8

local KNOWN = {}
for _, name in ipairs(DevService.Commands) do
	KNOWN[name] = true
end
-- the commands that still run while the profile is provisional (see the persistence note)
local PROVISIONAL_OK = { tokens = true, devhelp = true, pet = true, pets = true, evolve = true, clearpets = true }
-- the pet showcase never touches the profile, so it does not wait for it
local NO_PROFILE = { pet = true, pets = true, evolve = true, clearpets = true }
-- the commands that take a value, and its type (tokens: a number; the showcase: the rest of the chat line)
local ARG_KIND = { tokens = "number", pet = "string", pets = "string", evolve = "string" }
local MAX_ARG_LENGTH = 48
local STAGE_NAMES = { [0] = "Normal", [1] = "Evolved", [2] = "Evolved II" }
local STAGE_WORDS = {
	["0"] = 0, normal = 0, base = 0,
	["1"] = 1, evolved = 1, evo = 1, e1 = 1,
	["2"] = 2, evolved2 = 2, evo2 = 2, e2 = 2, ii = 2, second = 2, max = 2,
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
	warn("[DevService] could not load " .. name .. ": " .. tostring(result))
	return nil
end

local PetCatalog = loadModule(Shared, "PetCatalog")
local PetBuilder = nil -- loaded on the first showcase command (MaxEvolution)
local DataService = nil
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
local devs = {} -- [player] = true: allowed when they joined (only decides who hears "slow down"; never a permission)
local recent = {} -- [player] = { os.clock() of the commands accepted in the current window }
local rateWarned = {} -- [player] = os.clock() of the last "slow down" toast
local chatConns = {} -- [player] = Chatted connection
local lastChat = {} -- [player] = { Text, At }: the last chat line handled (duplicates are dropped)
local chatCommandsMade = false
local autoGranted = {} -- [userId] = true once the Studio auto grant ran in this server
local initialized = false
local ready = false -- Init finished with the tools on (Config.Dev.Enabled and a DataService)

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

-- true while the player's profile holds stand-in defaults (its load failed during a DataStore outage)
local function isProvisional(player)
	if not hasFunction(DataService, "IsProvisional") then
		return false
	end
	local ok, provisional = pcall(DataService.IsProvisional, player)
	return ok and provisional == true
end

-- Asks DataService to write the session's values of these fields over the stored ones at the next save (they are
-- merged so they only ever grow otherwise, which would undo the reset). See the persistence note in the header.
local function overwriteStored(player, fields)
	if not hasFunction(DataService, "ResetFields") then
		return
	end
	local ok, err = pcall(DataService.ResetFields, player, fields)
	if not ok then
		warn("[DevService] DataService.ResetFields failed: " .. tostring(err))
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

-- TutorialService.Reload(player, opts): drops the running tutorial and reads it again from the profile
-- (opts.Replay = true: do not pay the finish reward again). nil while TutorialService has no such hook.
local function tutorialReloader()
	if hasFunction(TutorialService, "Reload") then
		return TutorialService.Reload
	end
	return nil
end

-- Puts the stored tutorial back to step 1 and lets TutorialService read it again.
-- A reset is a brand-new player (the gift's tokens are gone, so the gift and the finish reward are paid again);
-- a restart is a replay: Gifted stays as it is and Replay asks TutorialService not to pay the finish reward again.
local function rewindTutorial(player, profile, reload, isReset)
	local tutorial = tableField(profile, "Tutorial")
	tutorial.Step = 1
	tutorial.Done = false
	if isReset then
		tutorial.Gifted = false
	end
	if reload then
		local ok, err = pcall(reload, player, { Replay = not isReset })
		if not ok then
			warn("[DevService] TutorialService.Reload failed: " .. tostring(err))
		end
	end
end

-- Reset without the Reload hook: a tutorial that already paid its gift is skipped (no finish reward), because
-- every step from "spin" on needs the tokens and pets the reset just took. Returns the note for the toast.
local function settleTutorialAfterReset(player, profile)
	local tutorial = profile.Tutorial
	if type(tutorial) ~= "table" or tutorial.Gifted ~= true or tutorial.Done == true then
		return "" -- not started on the gift yet (it carries on and pays the gift) or already finished
	end
	if not hasFunction(TutorialService, "HandleEvent") then
		return ""
	end
	local ok, skipped = pcall(TutorialService.HandleEvent, player, "Skip")
	if not ok then
		warn("[DevService] TutorialService.HandleEvent failed: " .. tostring(skipped))
		return ""
	end
	if skipped == true then
		return " (tutorial skipped)"
	end
	return ""
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
	-- the tutorial: a new player's again when TutorialService can re-read it (or the build has none); otherwise
	-- it must not wait forever on a step that needs what was just wiped
	local tutorialNote = ""
	local rewound = reload ~= nil or not TutorialService
	-- the grow-only fields are written over the store at the next save (the store would merge them back otherwise)
	overwriteStored(player, { Discovered = true, IndexClaimed = true, BestTimes = true, Tutorial = rewound })
	if rewound then
		rewindTutorial(player, profile, reload, true)
	else
		tutorialNote = settleTutorialAfterReset(player, profile)
	end
	-- the profile changed underneath every other service: PetService republishes the equipped pets and perks,
	-- IndexService forgets the completed groups (execute() then marks it dirty and syncs it to the client)
	if hasSignal(DataService, "ProfileRebased") then
		DataService.ProfileRebased:Fire(player, profile)
	end
	return true, "data reset: you are a brand-new player" .. tutorialNote, true
end

local function cmdTutorial(player, profile)
	local reload = tutorialReloader()
	if not reload then
		return false, "Restart tutorial is not in this build yet"
	end
	overwriteStored(player, { Tutorial = true }) -- Done would otherwise stick in the store and end the replay
	rewindTutorial(player, profile, reload, false)
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

----------------------------------------------------------------------
-- The pet showcase (pet / pets / evolve / clearpets): validated here, built on the developer's own client
----------------------------------------------------------------------

-- 2 for Epic pets and up (PetBuilder.MaxEvolution; the same rule when PetBuilder cannot load)
local function maxEvolution(def)
	if PetBuilder == nil then
		PetBuilder = loadModule(Shared, "PetBuilder") or false
	end
	if PetBuilder and hasFunction(PetBuilder, "MaxEvolution") then
		local ok, top = pcall(PetBuilder.MaxEvolution, def)
		if ok and (top == 1 or top == 2) then
			return top
		end
	end
	local r = def.Rarity
	return (r == "Epic" or r == "Legendary" or r == "Mythic" or r == "Secret") and 2 or 1
end

local function squash(text)
	return (string.gsub(string.lower(tostring(text)), "[^%a%d]", ""))
end

-- "cloudy dragon 2" -> "cloudy dragon", 2 (nil when the last word is not a stage)
local function splitStage(text)
	text = tostring(text or "")
	local head, last = string.match(text, "^%s*(.-)%s*(%S+)%s*$")
	if last then
		local stage = STAGE_WORDS[string.lower(last)]
		if stage ~= nil then
			return head, stage
		end
	end
	return (string.match(text, "^%s*(.-)%s*$")), nil
end

-- A catalog pet by id or name: exact first, then the one pet whose id or name contains the text.
local function findPet(text)
	local key = squash(text)
	if key == "" then
		return nil, "which pet? like /pet cloudy dragon 2"
	end
	local partial = {}
	for _, def in ipairs(PetCatalog.Pets) do
		if type(def) == "table" and type(def.Id) == "string" then
			local id, name = squash(def.Id), squash(def.Name or def.Id)
			if id == key or name == key then
				return def
			end
			if string.find(id, key, 1, true) or string.find(name, key, 1, true) then
				partial[#partial + 1] = def
			end
		end
	end
	if #partial == 1 then
		return partial[1]
	end
	local shown = string.sub(tostring(text), 1, 24)
	if #partial == 0 then
		return nil, "no pet called '" .. shown .. "'"
	end
	local names = {}
	for i = 1, math.min(4, #partial) do
		names[i] = tostring(partial[i].Name or partial[i].Id)
	end
	return nil, "'" .. shown .. "' could be " .. table.concat(names, ", ") .. ((#partial > 4) and ", ..." or "")
end

local function nameOf(def)
	return tostring(def.Name or def.Id)
end

-- Sends the showcase action to the developer's own client.
local function showPets(player, action, payload)
	local okRemote, remote = pcall(Remotes.Get, "DevPetShow")
	if not (okRemote and remote) then
		return false
	end
	local sent = pcall(function()
		remote:FireClient(player, action, payload)
	end)
	return sent
end

local function needCatalog()
	return PetCatalog ~= nil and type(PetCatalog.Pets) == "table"
end

local function cmdPet(player, _, arg)
	if not needCatalog() then
		return false, "the pet catalog is missing"
	end
	local text, stage = splitStage(arg)
	local def, err = findPet(text)
	if not def then
		return false, err
	end
	stage = stage or 0
	if stage > maxEvolution(def) then
		return false, nameOf(def) .. " has no second evolution (Epic pets and up)"
	end
	if not showPets(player, "Spawn", { PetId = def.Id, Stage = stage }) then
		return false, "the DevPetShow remote is missing"
	end
	return true, nameOf(def) .. " (" .. STAGE_NAMES[stage] .. ") in front of you; /clearpets removes it", false
end

local function cmdPets(player, _, arg)
	if not needCatalog() then
		return false, "the pet catalog is missing"
	end
	local text, stage = splitStage(arg)
	if text ~= "" then
		return false, "/pets takes only a stage: /pets, /pets 1 or /pets 2"
	end
	stage = stage or 0
	local ids = {}
	for _, def in ipairs(PetCatalog.Pets) do
		if type(def) == "table" and type(def.Id) == "string" and maxEvolution(def) >= stage then
			ids[#ids + 1] = def.Id
		end
	end
	if not showPets(player, "Lineup", { Stage = stage, PetIds = ids }) then
		return false, "the DevPetShow remote is missing"
	end
	return true, #ids .. " pets (" .. STAGE_NAMES[stage] .. ") lined up in front of you; /clearpets removes them", false
end

-- The evolutions of one pet: no stage = its whole line, 1 = normal -> evolved, 2 = evolved -> evolved II.
local function stepsOf(def, stage, steps)
	local top = maxEvolution(def)
	local from, to = 0, top
	if stage == 1 then
		from, to = 0, 1
	elseif stage == 2 then
		from, to = 1, 2
	end
	for s = from + 1, math.min(to, top) do
		steps[#steps + 1] = { PetId = def.Id, From = s - 1, To = s }
	end
end

local function cmdEvolve(player, _, arg)
	if not needCatalog() then
		return false, "the pet catalog is missing"
	end
	local text, stage = splitStage(arg)
	if stage == 0 then
		return false, "evolve to 1 (Evolved) or 2 (Evolved II), like /evolve cloudy dragon 2"
	end
	local steps = {}
	local label
	if squash(text) == "all" then
		for _, def in ipairs(PetCatalog.Pets) do
			if type(def) == "table" and type(def.Id) == "string" then
				stepsOf(def, stage, steps)
			end
		end
		label = #steps .. " evolutions one after another"
	else
		if squash(text) == "" then
			return false, "which pet? like /evolve cloudy dragon, or /evolve all"
		end
		local def, err = findPet(text)
		if not def then
			return false, err
		end
		if stage == 2 and maxEvolution(def) < 2 then
			return false, nameOf(def) .. " has no second evolution (Epic pets and up)"
		end
		stepsOf(def, stage, steps)
		label = nameOf(def) .. " evolving"
		if #steps > 1 then
			label = label .. " twice (Evolved, then Evolved II)"
		else
			label = label .. " to " .. STAGE_NAMES[steps[1].To]
		end
	end
	if not showPets(player, "Evolve", { Steps = steps }) then
		return false, "the DevPetShow remote is missing"
	end
	return true, label .. "; /clearpets stops it", false
end

local function cmdClearPets(player)
	if not showPets(player, "Clear", {}) then
		return false, "the DevPetShow remote is missing"
	end
	return true, "showcase pets removed", false
end

-- Two toasts (each fits a side toast): the pet showcase commands first, then the others.
local function cmdHelp(player)
	notify(player, "DEV: /pet <name> [0-2]  /pets [0-2]  /evolve <name|all> [1-2]  /clearpets", "info", HELP_SECONDS)
	if tutorialReloader() then
		return true, "/allpets  /tokens 50000  /reset  /tutorial  /skiptutorial  /devhelp", false
	end
	return true, "/allpets  /tokens 50000  /reset  /skiptutorial  /devhelp", false
end

local HANDLERS = {
	allpets = cmdAllPets,
	tokens = cmdTokens,
	reset = cmdReset,
	tutorial = cmdTutorial,
	skiptutorial = cmdSkipTutorial,
	pet = cmdPet,
	pets = cmdPets,
	evolve = cmdEvolve,
	clearpets = cmdClearPets,
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
	-- only "tokens" (a number) and the showcase commands (a short text) take a value
	local kind = ARG_KIND[name]
	if arg ~= nil and (type(arg) ~= kind or (kind == "string" and #arg > MAX_ARG_LENGTH)) then
		log(player, source, name, arg, "refused: bad value")
		if name == "tokens" then
			notify(player, "DEV: tokens needs a whole number, like /tokens 50000", "bad")
		elseif kind == "string" then
			notify(player, "DEV: " .. name .. " needs a short text, like /pet cloudy dragon 2", "bad")
		else
			notify(player, "DEV: " .. name .. " takes no value", "bad")
		end
		return false, "bad value"
	end
	local profile = getProfile(player)
	if not profile and not NO_PROFILE[name] then
		log(player, source, name, arg, "refused: profile not loaded")
		notify(player, "DEV: your data is still loading, try again", "bad")
		return false, "profile not loaded"
	end
	-- a provisional profile holds stand-in defaults (failed load during an outage): only additive commands make sense
	if not PROVISIONAL_OK[name] and isProvisional(player) then
		log(player, source, name, arg, "refused: profile provisional")
		notify(player, "DEV: your data is still loading, try again", "bad")
		return false, "profile provisional"
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
		if devs[player] and (rateWarned[player] == nil or now - rateWarned[player] >= RATE_WINDOW) then
			rateWarned[player] = now
			log(player, source, command, arg, "refused: rate limit")
			notify(player, "DEV: slow down (" .. RATE_COUNT .. " commands every " .. RATE_WINDOW .. " seconds)", "bad", 3)
		end
		return false, "rate limited"
	end
	if not ready then
		return false, "developer tools are off" -- switched off or no DataService: dropped without a word
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
	-- the same line through both ways in (Player.Chatted and a TextChatCommand) runs once
	local now = os.clock()
	local last = lastChat[player]
	if last and last.Text == message and now - last.At < DUPLICATE_WINDOW then
		return
	end
	lastChat[player] = { Text = message, At = now }
	local arg = nil
	if word == "tokens" and rest ~= "" then
		arg = parseAmount(rest)
		if arg == nil then
			arg = rest -- not a number: Run refuses it with a "bad" toast
		end
	elseif ARG_KIND[word] == "string" and rest ~= "" then
		arg = rest -- the showcase commands read the rest of the line (pet name and stage)
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

-- The new chat (TextChatService) only hands a "/" message to the game when a TextChatCommand claims it: one per
-- command. Skipped for the legacy chat and wherever TextChatCommand cannot be made.
local function makeChatCommands()
	if chatCommandsMade then
		return
	end
	chatCommandsMade = true
	local okService, tcs = pcall(function()
		return game:GetService("TextChatService")
	end)
	if not okService or not tcs then
		return
	end
	local okVersion, version = pcall(function()
		return tcs.ChatVersion
	end)
	if okVersion and version ~= nil and version ~= Enum.ChatVersion.TextChatService then
		return -- the legacy chat: Player.Chatted sees every message
	end
	for _, name in ipairs(DevService.Commands) do
		local ok = pcall(function()
			local command = Instance.new("TextChatCommand")
			command.Name = "NimbusDev_" .. name
			command.PrimaryAlias = "/" .. name
			command.Triggered:Connect(function(source, text)
				local okPlayer, player = pcall(function()
					return Players:GetPlayerByUserId(source.UserId)
				end)
				if okPlayer and player then
					onChatted(player, text)
				end
			end)
			command.Parent = tcs
		end)
		if not ok then
			return -- no TextChatCommand here (an old engine, a test world): Player.Chatted still works
		end
	end
	print(TAG .. "chat commands registered with TextChatService")
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
	-- a provisional profile (failed load during an outage) waits: ProfileRebased brings it back here once it recovered
	if autoGranted[player.UserId] or not getProfile(player) or isProvisional(player) then
		return
	end
	local allowed = DevService.IsAllowed(player)
	-- checked again after IsAllowed: the join handler, ProfileLoaded and ProfileRebased can all get here
	if not allowed or autoGranted[player.UserId] or not isLivePlayer(player) or not getProfile(player) or isProvisional(player) then
		return
	end
	autoGranted[player.UserId] = true
	execute(player, "allpets", nil, "studio auto grant")
	execute(player, "tokens", nil, "studio auto grant")
end

-- The hints for the developer's own client go on their PlayerGui, which replicates to that player only.
local function publishHints(player)
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", PLAYER_GUI_WAIT)
	if not isLivePlayer(player) then
		return
	end
	if not playerGui then
		warn("[DevService] no PlayerGui for " .. who(player) .. ": the DEV button stays hidden (chat commands work)")
		return
	end
	playerGui:SetAttribute(ATTR, true)
	if tutorialReloader() then
		playerGui:SetAttribute(ATTR_TUTORIAL, true)
	else
		playerGui:SetAttribute(ATTR_TUTORIAL, nil)
	end
end

local function onPlayerAdded(player)
	task.spawn(function()
		local allowed = DevService.IsAllowed(player)
		if not allowed or not isLivePlayer(player) then
			return
		end
		devs[player] = true
		connectChat(player)
		print(TAG .. "developer tools on for " .. who(player) .. " (DEV button, /devhelp)")
		autoGrant(player)
		publishHints(player)
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
	lastChat[player] = nil
	rankCache[player] = nil
	devs[player] = nil
	recent[player] = nil
	rateWarned[player] = nil
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------

-- The DevCommand listener. Connected even when the tools are off: Roblox queues the events of a RemoteEvent
-- without a listener, so an exploiter could otherwise fill that queue in a switched-off build.
local function connectRemote()
	local okRemote, remote = pcall(Remotes.Get, "DevCommand")
	if not (okRemote and remote) then
		warn("[DevService] DevCommand remote is missing: " .. tostring(remote))
		return
	end
	remote.OnServerEvent:Connect(function(player, command, arg)
		local ok, err = pcall(DevService.Run, player, command, arg, "button")
		if not ok then
			warn("[DevService] DevCommand failed: " .. tostring(err))
		end
	end)
end

function DevService.Init(deps)
	if initialized then
		return
	end
	initialized = true
	deps = type(deps) == "table" and deps or {}
	local services = script.Parent
	DataService = deps.DataService or loadModule(services, "DataService")
	TutorialService = deps.TutorialService
	IndexService = deps.IndexService
	if not PetCatalog then
		PetCatalog = loadModule(Shared, "PetCatalog")
	end
	connectRemote()
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	if devConfig().Enabled ~= true then
		print(TAG .. "developer tools are switched off (Config.Dev.Enabled)")
		return
	end
	if not DataService then
		warn("[DevService] DataService is missing: developer tools are off")
		return
	end
	ready = true
	makeChatCommands()

	if hasSignal(DataService, "ProfileLoaded") then
		DataService.ProfileLoaded:Connect(function(player)
			autoGrant(player)
		end)
	end
	if hasSignal(DataService, "ProfileRebased") then
		DataService.ProfileRebased:Connect(function(player)
			autoGrant(player) -- a profile that loaded provisionally gets its Studio grant once it recovered
		end)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

return DevService
