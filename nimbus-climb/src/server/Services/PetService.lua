-- PetService: pet ownership, roulette purchases, equipping and pet perks (ARCHITECTURE_V2.md s.2).
--
--   PetService.Init(lobbyInfo, deps)         deps = { DataService = }
--   PetService.BuyRoulette(player, rouletteId) -> ok, result|reason
--   PetService.Equip / Unequip(player, petId)  -> ok, reason
--   PetService.GetEquipped(player) -> {petId...}
--   PetService.GetPerks(player) -> {MaxHealth, TokenBonus, StaminaRegen, CheckpointHeal}
--   PetService.GetTokenMultiplier(player) -> number >= 1
--   PetService.PerksChanged                  Util.Signal, Fire(player)
--
-- Everything is server authoritative: the client only sends ids, we validate ownership, prices,
-- stack caps and slot limits, then write to the live profile and Sync it back.
--
-- Perk plumbing:
--   * attribute EquippedPets (csv)       -> every client draws that player's followers
--   * attribute PerkStaminaRegen         -> MovementController scales its stamina regen
--   * MaxHealth                          -> PlayerService (Main hands it GetPerks and calls RefreshMaxHealth
--                                           when PerksChanged fires), so this module never touches Humanoids
--   * TokenBonus / CheckpointHeal        -> read by MatchService through GetPerks / GetTokenMultiplier
-- perkState is updated BEFORE PerksChanged fires, so listeners always see the new numbers.
-- Equip / Unequip / BuyRoulette are refused while the player attribute InMatch is true, so the
-- loadout cannot be hot-swapped between token pickups and checkpoints.
--
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)
local DataService = require(script.Parent.DataService)

local PetService = {}
PetService.PerksChanged = Util.Signal()

local STRIP_LENGTH = 40 -- cosmetic roulette strip: the client scrolls it and stops on WIN_INDEX
local WIN_INDEX = 34
local REMOTE_COOLDOWN = 0.25 -- seconds per player per remote
local PROMPT_COOLDOWN = 0.5
local ANNOUNCE_DELAY = 5 -- seconds before the puller sees their own server-wide announcement
local MAX_ID_LENGTH = 48
local PROMPT_NAME = "RoulettePrompt"

----------------------------------------------------------------------
-- Optional collaborators (written by other modules; every use is guarded)
----------------------------------------------------------------------

local function loadShared(name)
	local module = Shared:FindFirstChild(name) or Shared:WaitForChild(name, 5)
	if not module then
		warn("[PetService] missing shared module: " .. name)
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[PetService] could not load " .. name .. ": " .. tostring(result))
	return nil
end

local PetCatalog = loadShared("PetCatalog")

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local roulettes = {} -- [id] = Config.Roulettes entry
for _, entry in ipairs(Config.Roulettes) do
	roulettes[entry.Id] = entry
end

local rarityOrder = {} -- [rarityId] = Order
for _, entry in ipairs(Config.Rarities) do
	rarityOrder[entry.Id] = entry.Order
end
local ANNOUNCE_ORDER = rarityOrder.Rare or 3

local perkState = {} -- [player] = { Perks = {...} }
local lastCall = {} -- [player] = { [key] = os.clock() }
local remotesConnected = false
local playersConnected = false
local promptObjects = {}

local ZERO_PERKS = { MaxHealth = 0, TokenBonus = 0, StaminaRegen = 0, CheckpointHeal = 0 }

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function isLivePlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function rateLimited(player, key, interval)
	local record = lastCall[player]
	if not record then
		record = {}
		lastCall[player] = record
	end
	local now = os.clock()
	local last = record[key]
	if last and now - last < interval then
		return true
	end
	record[key] = now
	return false
end

local function validId(id)
	return type(id) == "string" and #id > 0 and #id <= MAX_ID_LENGTH
end

-- Perks are read by MatchService at the moment of each pickup / checkpoint, so the loadout must not
-- change while a match runs (same rule as the roulette and the item shop).
local function inMatch(player)
	return player:GetAttribute(Config.Attr.InMatch) == true
end

local function fireClient(remoteName, player, ...)
	local ok, remote = pcall(Remotes.Get, remoteName)
	if ok and remote and player and player.Parent then
		remote:FireClient(player, ...)
	end
end

local function notify(player, text, kind, duration)
	fireClient("Notify", player, text, kind or "info", duration or 3)
end

local function countOf(list, id)
	local n = 0
	for _, value in ipairs(list) do
		if value == id then
			n = n + 1
		end
	end
	return n
end

local function totalPets(profile)
	local n = 0
	for _, count in pairs(profile.Pets) do
		n = n + count
	end
	return n
end

local function copyPerks(perks)
	return {
		MaxHealth = perks.MaxHealth or 0,
		TokenBonus = perks.TokenBonus or 0,
		StaminaRegen = perks.StaminaRegen or 0,
		CheckpointHeal = perks.CheckpointHeal or 0,
	}
end

----------------------------------------------------------------------
-- Perks + attributes
----------------------------------------------------------------------

-- Recomputes perks from the profile and publishes the attributes. `silent` skips PerksChanged.
local function refreshPlayer(player, silent)
	if not isLivePlayer(player) then
		return
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end
	local perks = copyPerks(DataService.ComputePerks(profile.Equipped))
	perkState[player] = { Perks = perks }
	player:SetAttribute(Config.Attr.EquippedPets, table.concat(profile.Equipped, ","))
	player:SetAttribute(Config.Attr.PerkStaminaRegen, perks.StaminaRegen)
	if not silent then
		PetService.PerksChanged:Fire(player)
	end
end

-- Drops equipped ids the catalog does not know (removed pets). Returns true if anything changed.
local function validateEquipped(profile)
	if not PetCatalog or type(PetCatalog.Get) ~= "function" then
		return false
	end
	local kept = {}
	for _, id in ipairs(profile.Equipped) do
		local ok, def = pcall(PetCatalog.Get, id)
		if ok and def then
			table.insert(kept, id)
		end
	end
	if #kept == #profile.Equipped then
		return false
	end
	for i = #profile.Equipped, 1, -1 do
		profile.Equipped[i] = nil
	end
	for i, id in ipairs(kept) do
		profile.Equipped[i] = id
	end
	return true
end

local function onProfileReady(player)
	if not isLivePlayer(player) then
		return
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end
	local changed = validateEquipped(profile)
	refreshPlayer(player, false)
	if changed then
		DataService.MarkDirty(player)
		DataService.Sync(player)
	end
end

local function finishEquipChange(player)
	DataService.MarkDirty(player)
	refreshPlayer(player, false)
	DataService.Sync(player)
end

----------------------------------------------------------------------
-- Public API: perks
----------------------------------------------------------------------

function PetService.GetEquipped(player)
	local profile = player and DataService.GetProfile(player)
	local out = {}
	if profile then
		for i, id in ipairs(profile.Equipped) do
			out[i] = id
		end
	end
	return out
end

function PetService.GetPerks(player)
	local state = player and perkState[player]
	if state then
		return copyPerks(state.Perks)
	end
	return copyPerks(ZERO_PERKS)
end

function PetService.GetTokenMultiplier(player)
	local state = player and perkState[player]
	local bonus = state and state.Perks.TokenBonus or 0
	if type(bonus) ~= "number" or bonus ~= bonus or bonus < 0 then
		bonus = 0
	end
	return 1 + bonus
end

----------------------------------------------------------------------
-- Public API: equip / unequip
----------------------------------------------------------------------

function PetService.Equip(player, petId)
	if not isLivePlayer(player) then
		return false, "Player unavailable"
	end
	if inMatch(player) then
		return false, "Pets are locked during a match"
	end
	if not validId(petId) then
		return false, "Unknown pet"
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return false, "Your data is still loading"
	end
	if PetCatalog and type(PetCatalog.Get) == "function" and not PetCatalog.Get(petId) then
		return false, "Unknown pet"
	end
	local owned = profile.Pets[petId] or 0
	if owned <= 0 then
		return false, "You do not own that pet"
	end
	local equipped = profile.Equipped
	if #equipped >= Config.Pets.MaxEquipped then
		return false, "All " .. Config.Pets.MaxEquipped .. " pet slots are full"
	end
	if countOf(equipped, petId) >= owned then
		return false, "All your copies are already equipped"
	end
	table.insert(equipped, petId)
	finishEquipChange(player)
	return true
end

function PetService.Unequip(player, petId)
	if not isLivePlayer(player) then
		return false, "Player unavailable"
	end
	if inMatch(player) then
		return false, "Pets are locked during a match"
	end
	if not validId(petId) then
		return false, "Unknown pet"
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return false, "Your data is still loading"
	end
	local equipped = profile.Equipped
	for i = #equipped, 1, -1 do
		if equipped[i] == petId then
			table.remove(equipped, i)
			finishEquipChange(player)
			return true
		end
	end
	return false, "That pet is not equipped"
end

----------------------------------------------------------------------
-- Public API: roulette
----------------------------------------------------------------------

-- Cosmetic strip: STRIP_LENGTH pet ids drawn like real rolls (so it shows realistic rarities),
-- with the real result at WIN_INDEX.
local function buildStrip(rouletteId, resultId, seed)
	local rng = Util.NewRng(seed)
	local strip = {}
	for i = 1, STRIP_LENGTH do
		local id = nil
		local ok, rolled = pcall(PetCatalog.RollPet, rouletteId, rng)
		if ok and type(rolled) == "string" then
			id = rolled
		end
		strip[i] = id or resultId
	end
	strip[WIN_INDEX] = resultId
	return strip
end

-- Tells the server about a rare pull. Everybody else sees it at once; the puller sees it after
-- the reveal animation so it does not spoil the result.
local function announcePull(player, def)
	local order = rarityOrder[def.Rarity] or 0
	if order < ANNOUNCE_ORDER then
		return
	end
	local text = player.DisplayName .. " pulled " .. def.Name .. "!"
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			notify(other, text, "good", 4)
		end
	end
	task.delay(ANNOUNCE_DELAY, function()
		if player.Parent then
			notify(player, text, "good", 4)
		end
	end)
end

function PetService.BuyRoulette(player, rouletteId)
	if not isLivePlayer(player) then
		return false, "Player unavailable"
	end
	if type(rouletteId) ~= "string" then
		return false, "Unknown roulette"
	end
	local roulette = roulettes[rouletteId]
	if not roulette then
		return false, "Unknown roulette"
	end
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return false, "The shop is closed during a match"
	end
	if not PetCatalog or type(PetCatalog.RollPet) ~= "function" or type(PetCatalog.Get) ~= "function" then
		return false, "Pets are unavailable right now"
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return false, "Your data is still loading"
	end
	local price = roulette.Price
	if DataService.GetTokens(player) < price then
		return false, "Not enough cloud tokens"
	end

	-- Roll first (pure), then check the stack cap, then charge: a capped pull costs nothing,
	-- which is the same outcome as "charge, refund, fail".
	local seed = (os.time() + player.UserId + profile.Stats.Spins + math.floor(os.clock() * 1000)) % 2147483647
	local rolledOk, petId = pcall(PetCatalog.RollPet, rouletteId, Util.NewRng(seed))
	if not rolledOk or type(petId) ~= "string" then
		return false, "The roulette jammed, try again"
	end
	local def = PetCatalog.Get(petId)
	if not def then
		return false, "The roulette jammed, try again"
	end
	local owned = profile.Pets[petId] or 0
	if owned >= Config.Pets.MaxPerStack then
		return false, "You already own the maximum of " .. def.Name
	end
	if not DataService.SpendTokens(player, price) then
		return false, "Not enough cloud tokens"
	end

	-- Nothing below yields, so the check + charge + grant is atomic.
	local firstPetEver = totalPets(profile) == 0
	profile.Pets[petId] = owned + 1
	profile.Stats.Spins = profile.Stats.Spins + 1
	if firstPetEver and #profile.Equipped < Config.Pets.MaxEquipped then
		table.insert(profile.Equipped, petId)
	end
	DataService.MarkDirty(player)
	refreshPlayer(player, false)
	DataService.Sync(player)

	local result = {
		Ok = true,
		RouletteId = rouletteId,
		PetId = petId,
		IsNew = owned == 0,
		Count = owned + 1,
		Tokens = DataService.GetTokens(player),
		Strip = buildStrip(rouletteId, petId, seed + 7919),
	}
	fireClient("RouletteResult", player, result)
	announcePull(player, def)
	return true, result
end

----------------------------------------------------------------------
-- Remotes (client -> server). Rate limited and type checked.
----------------------------------------------------------------------

local function connectRemotes()
	if remotesConnected then
		return
	end
	local okBuy, buyRemote = pcall(Remotes.Get, "BuyRoulette")
	local okEquip, equipRemote = pcall(Remotes.Get, "EquipPet")
	local okUnequip, unequipRemote = pcall(Remotes.Get, "UnequipPet")
	if not (okBuy and okEquip and okUnequip) then
		warn("[PetService] pet remotes are missing (did Remotes.Init run?)")
		return
	end
	remotesConnected = true

	buyRemote.OnServerEvent:Connect(function(player, rouletteId)
		if rateLimited(player, "BuyRoulette", REMOTE_COOLDOWN) then
			return
		end
		if type(rouletteId) ~= "string" or #rouletteId > MAX_ID_LENGTH then
			return
		end
		local ok, success, info = pcall(PetService.BuyRoulette, player, rouletteId)
		if not ok then
			warn("[PetService] BuyRoulette errored: " .. tostring(success))
			success, info = false, "Something went wrong, try again"
		end
		if not success then
			fireClient("RouletteResult", player, {
				Ok = false,
				Reason = tostring(info),
				RouletteId = rouletteId,
				Tokens = DataService.GetTokens(player),
			})
		end
	end)

	local function handleEquip(remoteName, fn)
		return function(player, petId)
			if rateLimited(player, remoteName, REMOTE_COOLDOWN) then
				return
			end
			if type(petId) ~= "string" or #petId > MAX_ID_LENGTH then
				return
			end
			local ok, success, reason = pcall(fn, player, petId)
			if not ok then
				warn("[PetService] " .. remoteName .. " errored: " .. tostring(success))
				return
			end
			if not success and reason then
				notify(player, tostring(reason), "bad", 3)
			end
		end
	end
	equipRemote.OnServerEvent:Connect(handleEquip("EquipPet", PetService.Equip))
	unequipRemote.OnServerEvent:Connect(handleEquip("UnequipPet", PetService.Unequip))
end

----------------------------------------------------------------------
-- Roulette machines in the lobby: one ProximityPrompt each
----------------------------------------------------------------------

local function buildPrompts(lobbyInfo)
	for _, prompt in ipairs(promptObjects) do
		if prompt.Parent then
			prompt:Destroy()
		end
	end
	promptObjects = {}

	local shop = type(lobbyInfo) == "table" and lobbyInfo.Shop
	local machines = type(shop) == "table" and shop.Roulettes
	if type(machines) ~= "table" then
		warn("[PetService] lobbyInfo.Shop.Roulettes missing: no roulette prompts created")
		return
	end

	for _, roulette in ipairs(Config.Roulettes) do
		local machine = machines[roulette.Id]
		local part = type(machine) == "table" and machine.PromptPart
		if part and typeof(part) == "Instance" then
			local old = part:FindFirstChild(PROMPT_NAME)
			if old then
				old:Destroy()
			end
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = PROMPT_NAME
			prompt.ActionText = "Open"
			prompt.ObjectText = roulette.DisplayName
			prompt.HoldDuration = 0
			prompt.MaxActivationDistance = 12
			prompt.RequiresLineOfSight = false
			prompt.Parent = part
			table.insert(promptObjects, prompt)

			local rouletteId = roulette.Id
			prompt.Triggered:Connect(function(player)
				if not isLivePlayer(player) then
					return
				end
				if player:GetAttribute(Config.Attr.InMatch) == true then
					return
				end
				if rateLimited(player, "Prompt_" .. rouletteId, PROMPT_COOLDOWN) then
					return
				end
				fireClient("OpenPanel", player, "Shop", { Tab = "Roulette", RouletteId = rouletteId })
			end)
		else
			warn("[PetService] no PromptPart for roulette " .. tostring(roulette.Id))
		end
	end
end

----------------------------------------------------------------------
-- Player lifecycle
----------------------------------------------------------------------

local function onPlayerAdded(player)
	if DataService.GetProfile(player) then
		task.spawn(onProfileReady, player)
	end
end

local function connectPlayers()
	if playersConnected then
		return
	end
	playersConnected = true

	DataService.ProfileLoaded:Connect(function(player)
		onProfileReady(player)
	end)
	DataService.ProfileRebased:Connect(function(player)
		onProfileReady(player)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		perkState[player] = nil
		lastCall[player] = nil
	end)
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------

function PetService.Init(lobbyInfo, deps)
	if type(deps) == "table" then
		if deps.DataService then
			DataService = deps.DataService
		end
	end
	if type(DataService.Init) == "function" then
		pcall(DataService.Init)
	end
	if not PetCatalog then
		warn("[PetService] PetCatalog is missing: roulettes and equipping are limited")
	end
	connectRemotes()
	connectPlayers()
	buildPrompts(lobbyInfo)
end

return PetService
