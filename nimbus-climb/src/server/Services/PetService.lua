-- PetService: pet ownership, roulette purchases, equipping and pet perks (ARCHITECTURE_V2.md s.2).
--
--   PetService.Init(lobbyInfo, deps)         deps = { DataService = }
--   PetService.BuyRoulette(player, rouletteId, currency|nil) -> ok, result|reason
--                                            currency: nil = the roulette's own ("Tokens"; the gems-only Secret
--                                            roulette: "Gems"), "Tokens" or "Gems" (also { Currency = ... })
--   PetService.Equip / Unequip(player, key)    -> ok, reason
--   PetService.GetEquipped(player) -> {key...}
--   PetService.GetPerks(player) -> {MaxHealth, TokenBonus, StaminaRegen, CheckpointHeal}
--   PetService.GetTokenMultiplier(player) -> number >= 1
--   PetService.PerksChanged                  Util.Signal, Fire(player)
--   PetService.Rolled                        Util.Signal, Fire(player, petId) after every successful roll (v3)
--   Extra (Phase 2): PetService.Refresh(player) -> changed   re-validates the equipped list against what the player
--                    owns (after FusionService / DevService removed copies: excess or vanished keys are unequipped),
--                    republishes the attributes and perks, MarkDirty + Sync when something changed.
--
-- v3 (ARCHITECTURE_V3.md section 3): every successful roll marks the pet as discovered for the Pet Index
-- (DataService.MarkDiscovered) before the ProfileSync goes out; RouletteResult.IsNew keeps meaning "first time
-- owned" and the payload also carries NewDiscovery (first time in the Index). Owned pets are re-checked as
-- discovered whenever a profile loads or is rebased.
--
-- Phase 2 (ARCHITECTURE_V3.md "Pet keys"): a pet COPY is a key (shared/PetKeys.lua): "petId" (Normal),
-- "petId@Golden", "petId@Rainbow", "hyb:<uid>" (a fused hybrid). Equip / Unequip take keys; an old plain petId is
-- the Normal key, so old callers keep working (Unequip(petId) also takes off a tier copy of that pet when no Normal
-- copy is equipped). Perks and the token multiplier sum PetKeys.DefOf(key).Perks x PetKeys.StatMultiplier(tier)
-- (DataService.ComputePerks), capped as before. The roulette still adds Normal copies (Pets[petId] + 1).
--
-- Phase 2 gems (ARCHITECTURE_V3.md "GemService"): a roulette can also be paid in Gems. GemService (looked up when
-- needed, so it may be missing) owns the gem prices (Config.Gems.RouletteGemPrices, the same odds as with tokens), the
-- PolicyService paid-random-items check and the gems-only Secret roulette (Config.Gems.SecretRoulette, rolled by
-- GemService.RollPet); its Quote is taken first, then the shared roll charges the Gems (DataService.SpendGems) and
-- grants in one non-yielding step. A gem roll without GemService, for a restricted (or not yet checked) account or
-- for a roulette without a gem price is refused before anything is charged. Secret pets only ever come out of a
-- roulette with AllowSecret = true: a Secret result of any other roulette is refused (nothing charged). The
-- BuyRoulette remote takes the optional currency as its second argument; RouletteResult gains Currency, Price, Gems.
--
-- Everything is server authoritative: the client only sends ids, we validate ownership, prices,
-- stack caps and slot limits, then write to the live profile and Sync it back.
--
-- Perk plumbing:
--   * attribute EquippedPets (csv of keys)   -> every client draws that player's followers
--   * attribute EquippedHybrids              -> the looks of the equipped hybrids (other clients cannot see the
--                                               owner's profile): "uid=Body/Style/Tier/Rarity[/Seed];..." -- set
--                                               BEFORE EquippedPets, only once a player ever equips a hybrid
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
PetService.Rolled = Util.Signal()

local STRIP_LENGTH = 40 -- cosmetic roulette strip: the client scrolls it and stops on WIN_INDEX
local WIN_INDEX = 34
local REMOTE_COOLDOWN = 0.25 -- seconds per player per remote
local PROMPT_COOLDOWN = 0.5
local ANNOUNCE_DELAY = 5 -- seconds before the puller sees their own server-wide announcement
local MAX_ID_LENGTH = 48
local PROMPT_NAME = "RoulettePrompt"
local HYBRID_ATTR = "EquippedHybrids" -- not in Config.Attr (lead-owned): the looks of equipped hybrids, see the header
local SECRET_RARITY = "Secret" -- Secret pets come only from a roulette with AllowSecret = true (Phase 2 gems)
local MAX_CURRENCY_LENGTH = 16

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
local PetKeys = loadShared("PetKeys")

-- GemService (Phase 2, gems) is looked up when a gem roll needs it: an optional module that Main loads after this one
-- (requiring it here at load time would tie the two to their load order).
local gemModule = nil
local function getGemService()
	if gemModule then
		return gemModule
	end
	local inst = script.Parent:FindFirstChild("GemService")
	if not inst then
		return nil
	end
	local ok, result = pcall(require, inst)
	if ok and type(result) == "table" then
		gemModule = result
		return result
	end
	return nil
end

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

-- every owned copy (Normal, tiers, hybrids): the very first pet ever is equipped automatically
local function totalPets(profile)
	local n = 0
	for _, count in pairs(profile.Pets) do
		n = n + count
	end
	for _, entry in pairs(type(profile.Tiers) == "table" and profile.Tiers or {}) do
		if type(entry) == "table" then
			for _, count in pairs(entry) do
				if type(count) == "number" then
					n = n + count
				end
			end
		end
	end
	for _ in pairs(type(profile.Hybrids) == "table" and profile.Hybrids or {}) do
		n = n + 1
	end
	return n
end

-- PetKeys.Parse(key) or nil (a plain petId when PetKeys is missing)
local function parseKey(key)
	if PetKeys and type(PetKeys.Parse) == "function" then
		local ok, parsed = pcall(PetKeys.Parse, key)
		if ok then
			return parsed
		end
		return nil
	end
	if validId(key) then
		return { Key = key, PetId = key, Tier = "Normal" }
	end
	return nil
end

-- The definition of a key (PetKeys.DefOf: catalog def, tier def or hybrid def), or nil for unknown keys.
-- Without PetKeys plain ids resolve through PetCatalog; without either nothing can be called unknown (true).
local function defOf(key, profile)
	if PetKeys and type(PetKeys.DefOf) == "function" then
		local ok, def = pcall(PetKeys.DefOf, key, profile)
		if ok and type(def) == "table" then
			return def
		end
		return nil
	end
	if PetCatalog and type(PetCatalog.Get) == "function" then
		local ok, def = pcall(PetCatalog.Get, key)
		if ok and type(def) == "table" then
			return def
		end
		return nil
	end
	return true
end

-- copies of `key` the profile owns
local function ownedCount(profile, key)
	if PetKeys and type(PetKeys.Count) == "function" then
		local ok, n = pcall(PetKeys.Count, profile, key)
		if ok and type(n) == "number" then
			return n
		end
		return 0
	end
	local n = profile.Pets[key]
	if type(n) == "number" then
		return n
	end
	return 0
end

-- "uid=Body/Style/Tier/Rarity[/Seed];..." for the equipped hybrids (what other clients need to draw them)
local function hybridLooks(profile)
	local parts, seen = {}, {}
	local hybrids = type(profile.Hybrids) == "table" and profile.Hybrids or {}
	for _, key in ipairs(profile.Equipped) do
		local parsed = parseKey(key)
		local uid = parsed and parsed.HybridId
		local rec = uid and hybrids[uid]
		if uid and not seen[uid] and type(rec) == "table" and type(rec.Body) == "string" and type(rec.Style) == "string" then
			seen[uid] = true
			local fields = { rec.Body, rec.Style, parsed.Tier, type(rec.Rarity) == "string" and rec.Rarity or "" }
			if type(rec.Seed) == "number" and rec.Seed == rec.Seed then
				fields[5] = tostring(math.floor(rec.Seed))
			end
			local text = uid .. "=" .. table.concat(fields, "/")
			if not string.find(text, "[,;]") then
				parts[#parts + 1] = text
			end
		end
	end
	return table.concat(parts, ";")
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
	local perks = copyPerks(DataService.ComputePerks(profile.Equipped, profile))
	perkState[player] = { Perks = perks }
	-- the hybrid looks first: a client that sees the new EquippedPets can already draw every hybrid in it
	local looks = hybridLooks(profile)
	local currentLooks = player:GetAttribute(HYBRID_ATTR)
	if looks ~= "" or (currentLooks ~= nil and currentLooks ~= "") then
		if currentLooks ~= looks then
			player:SetAttribute(HYBRID_ATTR, looks)
		end
	end
	player:SetAttribute(Config.Attr.EquippedPets, table.concat(profile.Equipped, ","))
	player:SetAttribute(Config.Attr.PerkStaminaRegen, perks.StaminaRegen)
	if not silent then
		PetService.PerksChanged:Fire(player)
	end
end

-- Drops equipped keys that are unknown (pets that left the catalog, hybrids whose record is gone) or owned fewer
-- times than they are equipped (copies fused away), and trims to the slot limit. Returns true if anything changed.
local function validateEquipped(profile)
	if type(profile.Equipped) ~= "table" then
		profile.Equipped = {}
	end
	local kept = {}
	local used = {}
	for _, key in ipairs(profile.Equipped) do
		if type(key) == "string" and #kept < Config.Pets.MaxEquipped and defOf(key, profile) then
			local n = (used[key] or 0) + 1
			if n <= ownedCount(profile, key) then
				used[key] = n
				table.insert(kept, key)
			end
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

-- Pet Index: marks a pet as discovered. Returns true the first time. Safe when DataService predates v3.
local function markDiscovered(player, petId)
	if type(DataService.MarkDiscovered) ~= "function" then
		return false
	end
	local ok, isNew = pcall(DataService.MarkDiscovered, player, petId)
	if not ok then
		warn("[PetService] MarkDiscovered errored: " .. tostring(isNew))
		return false
	end
	return isNew == true
end

-- Every owned pet counts as discovered (DataService migrates stored profiles; this also covers pets
-- granted outside the roulette).
local function discoverOwned(player, profile)
	for petId, count in pairs(profile.Pets) do
		if type(count) == "number" and count > 0 then
			markDiscovered(player, petId)
		end
	end
	-- tier copies count for their base pet (the Index lists base pets)
	for petId, entry in pairs(type(profile.Tiers) == "table" and profile.Tiers or {}) do
		if type(entry) == "table" then
			markDiscovered(player, petId)
		end
	end
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
	discoverOwned(player, profile) -- the ProfileSync snapshot already lists owned pets, so no extra Sync
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

function PetService.Equip(player, key)
	if not isLivePlayer(player) then
		return false, "Player unavailable"
	end
	if inMatch(player) then
		return false, "Pets are locked during a match"
	end
	if not validId(key) or not parseKey(key) then
		return false, "Unknown pet"
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return false, "Your data is still loading"
	end
	if not defOf(key, profile) then
		return false, "Unknown pet"
	end
	local owned = ownedCount(profile, key)
	if owned <= 0 then
		return false, "You do not own that pet"
	end
	local equipped = profile.Equipped
	if #equipped >= Config.Pets.MaxEquipped then
		return false, "All " .. Config.Pets.MaxEquipped .. " pet slots are full"
	end
	if countOf(equipped, key) >= owned then
		return false, "All your copies are already equipped"
	end
	table.insert(equipped, key)
	finishEquipChange(player)
	return true
end

-- Takes one copy of `key` off (the last one equipped). A plain petId also matches a tier copy of that pet when no
-- Normal copy is equipped (old callers only know pet ids).
function PetService.Unequip(player, key)
	if not isLivePlayer(player) then
		return false, "Player unavailable"
	end
	if inMatch(player) then
		return false, "Pets are locked during a match"
	end
	if not validId(key) then
		return false, "Unknown pet"
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return false, "Your data is still loading"
	end
	local equipped = profile.Equipped
	for i = #equipped, 1, -1 do
		if equipped[i] == key then
			table.remove(equipped, i)
			finishEquipChange(player)
			return true
		end
	end
	local parsed = parseKey(key)
	if parsed and parsed.PetId and parsed.Tier == "Normal" then
		for i = #equipped, 1, -1 do
			local other = parseKey(equipped[i])
			if other and other.PetId == parsed.PetId then
				table.remove(equipped, i)
				finishEquipChange(player)
				return true
			end
		end
	end
	return false, "That pet is not equipped"
end

-- Extra: re-validates the equipped list against what the player owns now (FusionService / DevService call it after
-- removing copies), republishes the attributes and perks. Returns true when the list changed.
function PetService.Refresh(player)
	if not isLivePlayer(player) then
		return false
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return false
	end
	local changed = validateEquipped(profile)
	refreshPlayer(player, false)
	if changed then
		DataService.MarkDirty(player)
		DataService.Sync(player)
	end
	return changed
end

----------------------------------------------------------------------
-- Public API: roulette
----------------------------------------------------------------------

-- Cosmetic strip: STRIP_LENGTH pet ids drawn like real rolls (so it shows realistic rarities),
-- with the real result at WIN_INDEX. `roll` = the roulette's roll (PetCatalog.RollPet when nil).
local function buildStrip(rouletteId, resultId, seed, roll)
	local rng = Util.NewRng(seed)
	local strip = {}
	for i = 1, STRIP_LENGTH do
		local id = nil
		local ok, rolled = pcall(roll or PetCatalog.RollPet, rouletteId, rng)
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

-- Copies of a pet in any form (Normal + tier copies): IsNew keeps meaning "first time owned".
local function ownedAnyForm(profile, petId)
	local n = profile.Pets[petId] or 0
	local entry = type(profile.Tiers) == "table" and profile.Tiers[petId]
	if type(entry) == "table" then
		for _, count in pairs(entry) do
			if type(count) == "number" and count > 0 then
				n = n + count
			end
		end
	end
	return n
end

-- The roll every way of paying shares (Cloud Tokens, or Gems through GemService's quote).
-- Roll first (pure), then check the stack cap, then charge() -> ok, reason (must not yield): a capped pull costs
-- nothing, which is the same outcome as "charge, refund, fail". Nothing between the charge and the grant yields, so
-- check + charge + grant is atomic. Grants ONE Normal copy (key = petId). `roll` (optional) replaces
-- PetCatalog.RollPet(rouletteId, rng) for roulettes the catalog does not list (the gems-only Secret roulette).
-- `opts` = { AllowSecret = bool (only then may a Secret pet come out), Currency = "Tokens"|"Gems", Price = n }.
-- Returns ok, result|reason.
local function rollAndGrant(player, profile, rouletteId, charge, roll, opts)
	opts = type(opts) == "table" and opts or {}
	local seed = (os.time() + player.UserId + profile.Stats.Spins + math.floor(os.clock() * 1000)) % 2147483647
	local rolledOk, petId = pcall(roll or PetCatalog.RollPet, rouletteId, Util.NewRng(seed))
	if not rolledOk or type(petId) ~= "string" then
		return false, "The roulette jammed, try again"
	end
	local def = PetCatalog.Get(petId)
	if not def then
		return false, "The roulette jammed, try again"
	end
	if def.Rarity == SECRET_RARITY and opts.AllowSecret ~= true then
		-- Secret pets only come from the gems-only Secret roulette: never from any other one, whatever it rolled
		return false, "The roulette jammed, try again"
	end
	local owned = profile.Pets[petId] or 0
	if owned >= Config.Pets.MaxPerStack then
		return false, "You already own the maximum of " .. def.Name
	end
	local everOwned = ownedAnyForm(profile, petId)
	local charged, reason = charge()
	if not charged then
		return false, reason or "Not enough cloud tokens"
	end

	-- Nothing below yields, so the check + charge + grant is atomic.
	local firstPetEver = totalPets(profile) == 0
	profile.Pets[petId] = owned + 1
	profile.Stats.Spins = profile.Stats.Spins + 1
	if firstPetEver and #profile.Equipped < Config.Pets.MaxEquipped then
		table.insert(profile.Equipped, petId)
	end
	local newDiscovery = markDiscovered(player, petId) -- before the Sync, so the snapshot shows it in the Index
	DataService.MarkDirty(player)
	refreshPlayer(player, false)
	DataService.Sync(player)

	local result = {
		Ok = true,
		RouletteId = rouletteId,
		PetId = petId,
		Key = petId, -- the copy's key (a roulette always grants a Normal copy)
		IsNew = everOwned == 0,
		NewDiscovery = newDiscovery,
		Count = owned + 1,
		Tokens = DataService.GetTokens(player),
		Strip = buildStrip(rouletteId, petId, seed + 7919, roll),
	}
	if opts.Currency then
		result.Currency = opts.Currency -- what paid this spin ("Tokens" | "Gems") and how much
		result.Price = opts.Price
	end
	if type(DataService.GetGems) == "function" then
		result.Gems = DataService.GetGems(player)
	end
	fireClient("RouletteResult", player, result)
	announcePull(player, def)
	PetService.Rolled:Fire(player, petId)
	return true, result
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
	return rollAndGrant(player, profile, rouletteId, function()
		if DataService.SpendTokens(player, price) then
			return true
		end
		return false, "Not enough cloud tokens"
	end)
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
