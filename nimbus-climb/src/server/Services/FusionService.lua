-- FusionService (Phase 2, fusion): the Fusion Machine on the player's home plot (ARCHITECTURE_V3.md section 11 and the
-- FusionService paragraph of the "Phase 2 build contract").
--
-- * UPGRADE (key): 3 copies of the same key -> 1 copy of the next tier: Normal -> Golden (x1.5 stats / perks) ->
--   Rainbow (x2.5). Costs TycoonCatalog.FusionCost("Upgrade", rarity, targetTier, machineLevel) (Cloud Tokens; the
--   machine's TokenDiscount lowers them). Hybrids are one of a kind (one copy each), so they cannot be upgraded.
-- * MIX (keyA, keyB): two different catalog pets -> a brand-new hybrid record (PetKeys "hyb:<uid>"): Body = the first
--   pet (species, body colour, eyes, special), Style = the second (colours, wings, accessory), Elements = both
--   (deduplicated), Rarity = the higher of the two, Name = PetKeys.BlendName ("Pip Penguin" + "Ember Phoenix" ->
--   "Pengnix"), a random look Seed (PetBuilder varies the blend with it; PetService publishes it for other clients),
--   Tier = the LOWER tier of the two inputs (two Golden pets make a Golden hybrid, so no finish is ever gained for
--   free). Stats = the parents' average x1.2 (PetKeys.DefOf). Costs TycoonCatalog.FusionCost("Mix", higherRarity, nil,
--   machineLevel): Tokens, Gems for Mythic / Secret inputs. A hybrid cannot be mixed again (its record only names
--   two catalog parents). At most MAX_HYBRIDS hybrids per profile.
-- * Requirements (every request): the profile is loaded and not provisional, the player is not in a match,
--   Home.Prestige >= TycoonCatalog.Prestige.FusionUnlock (1) and Home.Stations.FusionMachine >= 1. Requests through the
--   remote must also come from near the player's own Fusion Machine (the window opens with E at the machine).
-- * Copies in use: inputs are taken from free copies first. A copy that is equipped, working in the Garden or training
--   in the Gym is taken off first (never consumed while in use), and the result takes over the freed place (the
--   equipped slot; the Garden slot for an Economy result, the Gym slot for a Combat one). If the inputs are the player's
--   ONLY equipped pets (fusing would leave nothing equipped) the fusion is refused: unequip them or equip another pet.
-- * Levels: an upgraded copy keeps the level of its inputs (the target key's level is raised to it, never lowered);
--   a hybrid starts at the average level of its parents.
-- * Atomic: every check runs first; then the inputs are removed, the result added and the price paid in ONE
--   non-yielding step (anything unexpected restores the pets and nothing is charged). Then PetService.Refresh
--   republishes the equipped attributes / perks and the profile is synced.
-- * Remote Fusion(action, a, b): "Upgrade" (key), "Mix" (keyA, keyB). Types, lengths and keys are validated; a
--   per-player cooldown plus a burst budget rate-limit it; refusals answer with a side toast (repeats throttled).
--   The server answers on the same RemoteEvent: Fusion:FireClient(player, "Result", { Ok, Action, Key, Name, Rarity,
--   Tier, Reason, Consumed = {key...} }) so the window can play its fusion animation (FusionController).
--
-- Public API (the contract): Init(deps)   deps = { DataService, PetService, TycoonService }
-- Extras: Upgrade(player, key) -> ok, resultKey | reason
--         Mix(player, keyA, keyB) -> ok, resultKey | reason
--         Preview(player, action, a, b) -> ok, plan | reason   (no changes; plan = { Action, Cost = {Tokens|Gems = n},
--                                          ResultKey (Upgrade; nil for Mix: the uid is drawn on fusing), ResultName,
--                                          Rarity, Tier, Inputs = { {Key, Count} }, Freed = { Equipped, Garden, Gym } })
--         Unlocked(player) -> ok, reason, { Prestige, MachineLevel }
--         Fused  Util.Signal Fire(player, action, resultKey, consumedKeys)
--
-- Plain Lua 5.1-compatible syntax only. Nothing here yields between a check and its write.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local FusionService = {}
FusionService.Fused = Util.Signal() -- Fire(player, action, resultKey, consumedKeys)

local COPIES = 3 -- Upgrade input copies (TycoonCatalog.Fusion.Copies overrides it)
local MAX_HYBRIDS = 100 -- hybrids one profile may hold (not in Config / TycoonCatalog: local constant)
local FUSE_COOLDOWN = 0.75 -- seconds between two fusions of one player
local BURST_SIZE = 6 -- Fusion requests a player may send at once...
local BURST_REFILL = 2 -- ...refilled at this many per second
local TOAST_GAP = 1.5 -- the same refusal text is not repeated within this many seconds
local MACHINE_RANGE = 36 -- studs: remote requests must come from near the player's own Fusion Machine
local MAX_ACTION_LENGTH = 16
local MAX_KEY_LENGTH = 48
local MAX_NAME_CHARS = 30
local DEFAULT_UNLOCK = 1 -- prestige stars that unlock the machine (TycoonCatalog.Prestige.FusionUnlock)
local MACHINE_ID = "FusionMachine"
local TIER_RANK = { Normal = 1, Golden = 2, Rainbow = 3 }
local NEXT_TIER = { Normal = "Golden", Golden = "Rainbow" }

local initialized = false
local dataService = nil
local petService = nil
local tycoonService = nil
local petKeys = nil
local petCatalog = nil
local catalog = nil -- TycoonCatalog
local homeBuilder = nil
local homeBuilderTried = false
local fusionRemote = nil
local notifyRemote = nil
local rng = nil

local cooldowns = {} -- [Player] = os.clock() of the last accepted fusion request
local budgets = {} -- [Player] = { Tokens, At }
local toastAt = {} -- [Player] = { [text] = os.clock() }

----------------------------------------------------------------------
-- Modules (written by other engineers: every use is guarded)
----------------------------------------------------------------------

local function requireModule(container, name)
	local module = container and container:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[FusionService] could not load " .. name .. ": " .. tostring(result))
	return nil
end

local function getHomeBuilder()
	if not homeBuilderTried then
		homeBuilderTried = true
		homeBuilder = requireModule(script.Parent, "HomeBuilder")
	end
	return homeBuilder
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function isFinite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isPlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function clip(text, n)
	text = tostring(text or "")
	if #text > n then
		return string.sub(text, 1, n - 1) .. "."
	end
	return text
end

local function notify(player, text, kind, seconds)
	if not player or not player.Parent or type(text) ~= "string" or text == "" then
		return
	end
	if not notifyRemote then
		local ok, remote = pcall(Remotes.Get, "Notify")
		if ok then
			notifyRemote = remote
		end
	end
	if notifyRemote then
		pcall(function()
			notifyRemote:FireClient(player, text, kind or "info", seconds or 3)
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

-- Per player burst budget shared by every Fusion request.
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

local function cooldownReady(player)
	local now = os.clock()
	local last = cooldowns[player]
	if last and now - last < FUSE_COOLDOWN then
		return false
	end
	cooldowns[player] = now
	return true
end

local function reply(player, payload)
	if not fusionRemote or not player or not player.Parent then
		return
	end
	pcall(function()
		fusionRemote:FireClient(player, "Result", payload)
	end)
end

local function copyList(list)
	local out = {}
	for i, v in ipairs(type(list) == "table" and list or {}) do
		out[i] = v
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

local function random()
	if not rng then
		rng = Random.new(math.floor((os.clock() * 1000003) % 2147483647) + 7)
	end
	return rng
end

----------------------------------------------------------------------
-- Data access
----------------------------------------------------------------------

local function dsCall(fnName, ...)
	if not dataService or type(dataService[fnName]) ~= "function" then
		return false, nil
	end
	local ok, result = pcall(dataService[fnName], ...)
	if not ok then
		warn("[FusionService] DataService." .. fnName .. " failed: " .. tostring(result))
		return false, nil
	end
	return true, result
end

local function getProfile(player)
	local ok, profile = dsCall("GetProfile", player)
	if ok and type(profile) == "table" then
		return profile
	end
	return nil
end

local function isProvisional(player)
	local ok, result = dsCall("IsProvisional", player)
	return ok and result == true
end

local function getHome(player)
	local ok, home = dsCall("GetHome", player)
	if ok and type(home) == "table" then
		return home
	end
	return nil
end

local function inMatch(player)
	return player:GetAttribute(Config.Attr.InMatch) == true
end

local function balanceOf(player, currency)
	local fnName = (currency == "Gems") and "GetGems" or "GetTokens"
	local ok, n = dsCall(fnName, player)
	if ok and isFinite(n) then
		return n
	end
	return 0
end

local function parseKey(key)
	if type(key) ~= "string" or key == "" or #key > MAX_KEY_LENGTH or not petKeys then
		return nil
	end
	local ok, parsed = pcall(petKeys.Parse, key)
	if ok and type(parsed) == "table" then
		return parsed
	end
	return nil
end

local function defOf(key, profile)
	if not petKeys or type(petKeys.DefOf) ~= "function" then
		return nil
	end
	local ok, def = pcall(petKeys.DefOf, key, profile)
	if ok and type(def) == "table" then
		return def
	end
	return nil
end

local function catalogDef(petId)
	if not petCatalog or type(petCatalog.Get) ~= "function" then
		return nil
	end
	local ok, def = pcall(petCatalog.Get, petId)
	if ok and type(def) == "table" then
		return def
	end
	return nil
end

local function countOf(profile, key)
	if not petKeys then
		return 0
	end
	local ok, n = pcall(petKeys.Count, profile, key)
	if ok and isFinite(n) then
		return n
	end
	return 0
end

local function maxStack()
	local n = Config.Pets and tonumber(Config.Pets.MaxPerStack)
	if n and n >= 1 then
		return math.floor(n)
	end
	return 99
end

local function rarityOrder(rarityId)
	for _, r in ipairs(Config.Rarities or {}) do
		if r.Id == rarityId then
			return r.Order or 0
		end
	end
	return 0
end

local function higherRarity(a, b)
	if rarityOrder(b) > rarityOrder(a) then
		return b
	end
	return a
end

local function displayName(def, key)
	if type(def) == "table" then
		return clip(def.DisplayName or def.Name or key, MAX_NAME_CHARS)
	end
	return clip(key, MAX_NAME_CHARS)
end

local function unlockStars()
	local p = catalog and catalog.Prestige
	local n = type(p) == "table" and tonumber(p.FusionUnlock) or nil
	if n and n >= 0 then
		return math.floor(n)
	end
	return DEFAULT_UNLOCK
end

local function copiesNeeded()
	local f = catalog and catalog.Fusion
	local n = type(f) == "table" and tonumber(rawget(f, "Copies")) or nil
	if n and n >= 2 and n == math.floor(n) then
		return n
	end
	return COPIES
end

-- { Tokens = n } | { Gems = n } | nil
local function costOf(action, rarity, tier, machineLevel)
	if not catalog or type(catalog.FusionCost) ~= "function" then
		return nil
	end
	local ok, cost = pcall(catalog.FusionCost, action, rarity, tier, machineLevel)
	if not ok or type(cost) ~= "table" then
		return nil
	end
	local out = nil
	if isFinite(cost.Gems) and cost.Gems > 0 then
		out = { Gems = math.ceil(cost.Gems) }
	elseif isFinite(cost.Tokens) and cost.Tokens >= 0 then
		out = { Tokens = math.ceil(cost.Tokens) }
	end
	return out
end

local function currencyOf(cost)
	if cost.Gems then
		return "Gems", cost.Gems
	end
	return "Tokens", cost.Tokens or 0
end

local function priceText(cost)
	local currency, amount = currencyOf(cost)
	if currency == "Gems" then
		return tostring(amount) .. " Gems"
	end
	return tostring(amount) .. " Cloud Tokens"
end

local function levelOf(profile, key)
	local levels = type(profile.PetLevels) == "table" and profile.PetLevels or {}
	local raw = levels[key]
	if type(raw) == "table" and isFinite(raw.Level) and raw.Level >= 1 then
		return math.floor(raw.Level)
	elseif isFinite(raw) and raw >= 1 then
		return math.floor(raw)
	end
	return 1
end

----------------------------------------------------------------------
-- Requirements
----------------------------------------------------------------------

local function machineLevelOf(home)
	local stations = type(home) == "table" and home.Stations
	local lv = type(stations) == "table" and stations[MACHINE_ID] or nil
	if isFinite(lv) and lv >= 1 then
		return math.floor(lv)
	end
	return 0
end

local function prestigeOf(home)
	local p = type(home) == "table" and home.Prestige or nil
	if isFinite(p) and p >= 0 then
		return math.floor(p)
	end
	return 0
end

-- ok, reason, info { Prestige, MachineLevel }, home, profile
local function checkUnlocked(player)
	if not initialized then
		return false, "The Fusion Machine is not ready yet"
	end
	if not isPlayer(player) then
		return false, "Not in the game"
	end
	local profile = getProfile(player)
	if not profile then
		return false, "Your data is still loading..."
	end
	if isProvisional(player) then
		return false, "Your save is still loading: try again in a moment"
	end
	local home = getHome(player)
	if not home then
		return false, "Your home is still loading..."
	end
	local info = { Prestige = prestigeOf(home), MachineLevel = machineLevelOf(home) }
	local need = unlockStars()
	if info.Prestige < need then
		return false, "The Fusion Machine unlocks at Prestige " .. need, info
	end
	if info.MachineLevel < 1 then
		return false, "Build the Fusion Machine at your home first", info
	end
	if inMatch(player) then
		return false, "Fusion is closed during a match", info
	end
	return true, nil, info, home, profile
end

----------------------------------------------------------------------
-- Planning: which copies a fusion takes and what it frees
----------------------------------------------------------------------

local function sortedSlots(map, key)
	local out = {}
	for slot, k in pairs(type(map) == "table" and map or {}) do
		if k == key then
			out[#out + 1] = slot
		end
	end
	table.sort(out, function(a, b)
		if type(a) == type(b) then
			return a > b -- the highest slots are freed first
		end
		return type(a) == "string"
	end)
	return out
end

-- Takes `n` copies of each input key: { equippedIdx = {i = true}, garden = {slot...}, gym = {slot...} } of what must
-- be freed, or nil, reason when the copies are not there.
local function planUse(profile, home, inputs)
	local freeEq, freeGarden, freeGym = {}, {}, {}
	for _, input in ipairs(inputs) do
		local key, n = input.Key, input.Count
		local owned = countOf(profile, key)
		if owned < n then
			return nil, input.Short
		end
		local left = owned - n
		-- equipped copies beyond what is left are taken off (the last equipped ones first)
		local eqIdx = {}
		for i, k in ipairs(type(profile.Equipped) == "table" and profile.Equipped or {}) do
			if k == key then
				eqIdx[#eqIdx + 1] = i
			end
		end
		local dropEq = #eqIdx - left
		for j = #eqIdx, 1, -1 do
			if dropEq <= 0 then
				break
			end
			freeEq[eqIdx[j]] = true
			dropEq = dropEq - 1
		end
		-- placed copies (Garden + Gym share the copies) beyond what is left leave their slot (Gym first)
		local gymSlots = sortedSlots(home.Gym, key)
		local gardenSlots = sortedSlots(home.Garden, key)
		local dropPlaced = #gymSlots + #gardenSlots - left
		for _, slot in ipairs(gymSlots) do
			if dropPlaced <= 0 then
				break
			end
			freeGym[#freeGym + 1] = slot
			dropPlaced = dropPlaced - 1
		end
		for _, slot in ipairs(gardenSlots) do
			if dropPlaced <= 0 then
				break
			end
			freeGarden[#freeGarden + 1] = slot
			dropPlaced = dropPlaced - 1
		end
	end
	return { Equipped = freeEq, Garden = freeGarden, Gym = freeGym }
end

local function countKeys(set)
	local n = 0
	for _ in pairs(set) do
		n = n + 1
	end
	return n
end

-- The "never leave the player with no pet" rule. ok, reason
local function checkEquippedRule(profile, freed)
	local equipped = type(profile.Equipped) == "table" and profile.Equipped or {}
	local total = #equipped
	local dropped = countKeys(freed.Equipped)
	if total > 0 and dropped >= total then
		return false, "Those are your only equipped pets: unequip them or equip another pet first"
	end
	return true
end

-- ok, plan | reason. plan = { Action, Inputs = {{Key, Count}}, Cost, Currency, Price, ResultKey, ResultName, Rarity,
-- Tier, Record (Mix), Freed, Profile, Home, MachineLevel, Level }
local function buildPlan(player, action, a, b)
	local ok, reason, info, home, profile = checkUnlocked(player)
	if not ok then
		return false, reason
	end
	if not petKeys then
		return false, "Fusion is not available right now"
	end
	local plan = { Action = action, Profile = profile, Home = home, MachineLevel = info.MachineLevel }
	if action == "Upgrade" then
		local parsed = parseKey(a)
		if not parsed then
			return false, "Pick a pet to upgrade"
		end
		if parsed.HybridId then
			return false, "Hybrids are one of a kind: they cannot be upgraded"
		end
		local nextTier = NEXT_TIER[parsed.Tier]
		if not nextTier then
			return false, "Rainbow is the best finish: this pet cannot go higher"
		end
		local def = defOf(a, profile)
		local base = catalogDef(parsed.PetId)
		if not def or not base then
			return false, "Unknown pet"
		end
		local need = copiesNeeded()
		local have = countOf(profile, a)
		if have < need then
			return false, "You need " .. need .. " copies of " .. displayName(def, a) .. " (you have " .. have .. ")"
		end
		local resultKey = petKeys.Make(parsed.PetId, nextTier)
		if not resultKey then
			return false, "Unknown pet"
		end
		if countOf(profile, resultKey) + 1 > maxStack() then
			return false, "You already have the most copies of that finish"
		end
		local cost = costOf("Upgrade", base.Rarity, nextTier, info.MachineLevel)
		if not cost then
			return false, "This pet cannot be fused"
		end
		plan.Inputs = { { Key = a, Count = need, Short = "You need " .. need .. " copies of " .. displayName(def, a) } }
		plan.ResultKey = resultKey
		plan.ResultName = clip(nextTier .. " " .. tostring(base.Name), MAX_NAME_CHARS + 8)
		plan.Rarity = base.Rarity
		plan.Tier = nextTier
		plan.Cost = cost
		plan.Level = levelOf(profile, a)
		plan.Role = base.Role
	elseif action == "Mix" then
		local pa, pb = parseKey(a), parseKey(b)
		if not pa or not pb then
			return false, "Pick two pets to mix"
		end
		if pa.HybridId or pb.HybridId then
			return false, "Hybrids cannot be mixed again: pick two regular pets"
		end
		if pa.PetId == pb.PetId then
			return false, "Pick two different pets to mix"
		end
		local defA, defB = defOf(a, profile), defOf(b, profile)
		local baseA, baseB = catalogDef(pa.PetId), catalogDef(pb.PetId)
		if not defA or not defB or not baseA or not baseB then
			return false, "Unknown pet"
		end
		if countOf(profile, a) < 1 then
			return false, "You do not own " .. displayName(defA, a)
		end
		if countOf(profile, b) < 1 then
			return false, "You do not own " .. displayName(defB, b)
		end
		local hybrids = type(profile.Hybrids) == "table" and profile.Hybrids or {}
		if countKeys(hybrids) >= MAX_HYBRIDS then
			return false, "Your hybrid collection is full (" .. MAX_HYBRIDS .. ")"
		end
		local rarity = higherRarity(baseA.Rarity, baseB.Rarity)
		local cost = costOf("Mix", rarity, nil, info.MachineLevel)
		if not cost then
			return false, "These pets cannot be mixed"
		end
		local tier = pa.Tier
		if (TIER_RANK[pb.Tier] or 1) < (TIER_RANK[tier] or 1) then
			tier = pb.Tier
		end
		local elements = {}
		local seen = {}
		for _, e in ipairs({ baseA.Element, baseB.Element }) do
			if type(e) == "string" and not seen[e] then
				seen[e] = true
				elements[#elements + 1] = e
			end
		end
		local name = nil
		if type(petKeys.BlendName) == "function" then
			local okName, blended = pcall(petKeys.BlendName, baseA.Name, baseB.Name)
			if okName and type(blended) == "string" and blended ~= "" then
				name = clip(blended, 24)
			end
		end
		plan.Inputs = {
			{ Key = a, Count = 1, Short = "You do not own " .. displayName(defA, a) },
			{ Key = b, Count = 1, Short = "You do not own " .. displayName(defB, b) },
		}
		plan.Record = { Body = pa.PetId, Style = pb.PetId, Elements = elements, Name = name, Rarity = rarity, Tier = tier }
		plan.ResultName = name or "Hybrid"
		plan.Rarity = rarity
		plan.Tier = tier
		plan.Cost = cost
		plan.Level = math.max(1, math.floor((levelOf(profile, a) + levelOf(profile, b)) / 2))
	else
		return false, "Unknown fusion"
	end
	local freed, short = planUse(profile, home, plan.Inputs)
	if not freed then
		return false, short or "You do not have those pets"
	end
	local okRule, why = checkEquippedRule(profile, freed)
	if not okRule then
		return false, why
	end
	plan.Freed = freed
	local currency, price = currencyOf(plan.Cost)
	plan.Currency, plan.Price = currency, price
	if balanceOf(player, currency) < price then
		if currency == "Gems" then
			return false, "Not enough Gems: this fusion costs " .. priceText(plan.Cost)
		end
		return false, "Not enough Cloud Tokens: this fusion costs " .. priceText(plan.Cost)
	end
	return true, plan
end

----------------------------------------------------------------------
-- Execution (one non-yielding step)
----------------------------------------------------------------------

local function petIdsOf(plan)
	local ids = {}
	for _, input in ipairs(plan.Inputs) do
		local parsed = parseKey(input.Key)
		if parsed and parsed.PetId then
			ids[#ids + 1] = parsed.PetId
		end
	end
	if plan.ResultKey then
		local parsed = parseKey(plan.ResultKey)
		if parsed and parsed.PetId then
			ids[#ids + 1] = parsed.PetId
		end
	end
	return ids
end

-- What the step below may touch: the input / result entries of Pets and Tiers (hybrid inputs are refused, the new
-- hybrid record is removed by uid) and the equipped list.
local function takeSnapshot(profile, plan)
	local snap = { Pets = {}, Tiers = {}, Equipped = copyList(profile.Equipped) }
	local pets = type(profile.Pets) == "table" and profile.Pets or {}
	local tiers = type(profile.Tiers) == "table" and profile.Tiers or {}
	for _, id in ipairs(petIdsOf(plan)) do
		snap.Pets[id] = { Value = pets[id] }
		snap.Tiers[id] = { Value = deepCopy(tiers[id]) }
	end
	return snap
end

local function restoreSnapshot(profile, snap, newUid)
	if type(profile.Pets) ~= "table" then
		profile.Pets = {}
	end
	for id, box in pairs(snap.Pets) do
		profile.Pets[id] = box.Value
	end
	if next(snap.Tiers) ~= nil then
		if type(profile.Tiers) ~= "table" then
			profile.Tiers = {}
		end
		for id, box in pairs(snap.Tiers) do
			profile.Tiers[id] = box.Value
		end
	end
	if newUid and type(profile.Hybrids) == "table" then
		profile.Hybrids[newUid] = nil
	end
	local eq = type(profile.Equipped) == "table" and profile.Equipped or {}
	for i = #eq, 1, -1 do
		eq[i] = nil
	end
	for i, k in ipairs(snap.Equipped) do
		eq[i] = k
	end
	profile.Equipped = eq
end

local function spendCurrency(player, currency, price)
	if price <= 0 then
		return true
	end
	local fnName = (currency == "Gems") and "SpendGems" or "SpendTokens"
	local ok, result = dsCall(fnName, player, price)
	return ok and result == true
end

local function writeLevel(profile, key, level)
	if not isFinite(level) or level <= 1 then
		return
	end
	if type(profile.PetLevels) ~= "table" then
		profile.PetLevels = {}
	end
	local cur = levelOf(profile, key)
	if level > cur then
		profile.PetLevels[key] = { Level = math.floor(level), Xp = 0 }
	end
end

-- The new equipped list: freed entries out, the result in the first freed place.
local function rebuildEquipped(profile, freed, resultKey)
	local eq = type(profile.Equipped) == "table" and profile.Equipped or {}
	local out = {}
	local placed = false
	for i, k in ipairs(eq) do
		if freed.Equipped[i] then
			if not placed and resultKey then
				out[#out + 1] = resultKey
				placed = true
			end
		else
			out[#out + 1] = k
		end
	end
	for i = #eq, 1, -1 do
		eq[i] = nil
	end
	local cap = (Config.Pets and Config.Pets.MaxEquipped) or 3
	for i, k in ipairs(out) do
		if i <= cap then
			eq[i] = k
		end
	end
	profile.Equipped = eq
	return placed
end

-- Clears the freed Garden / Gym slots; the result takes the first freed slot that fits its role.
local function freeHomeSlots(player, freed, resultKey, resultRole)
	if #freed.Garden == 0 and #freed.Gym == 0 then
		return true, nil
	end
	local placedIn = nil
	local ok, wrote = dsCall("MutateHome", player, function(home)
		if type(home.Garden) ~= "table" then
			home.Garden = {}
		end
		if type(home.Gym) ~= "table" then
			home.Gym = {}
		end
		for _, slot in ipairs(freed.Garden) do
			home.Garden[slot] = nil
		end
		for _, slot in ipairs(freed.Gym) do
			home.Gym[slot] = nil
		end
		if resultKey then
			-- smallest freed slot of the fitting kind
			local function first(list)
				local best = nil
				for _, s in ipairs(list) do
					if type(s) == "number" and (best == nil or s < best) then
						best = s
					end
				end
				return best
			end
			local function holds(map)
				for _, k in pairs(map) do
					if k == resultKey then
						return true
					end
				end
				return false
			end
			-- (a key never works in the Garden and trains in the Gym at the same time: TycoonService / PetCareService)
			if resultRole == "Economy" and #freed.Garden > 0 and not holds(home.Gym) then
				local slot = first(freed.Garden)
				if slot then
					home.Garden[slot] = resultKey
					placedIn = "Garden"
				end
			elseif resultRole == "Combat" and #freed.Gym > 0 and not holds(home.Garden) then
				local slot = first(freed.Gym)
				if slot then
					home.Gym[slot] = resultKey
					placedIn = "Gym"
				end
			end
		end
		return true
	end)
	if not ok or wrote ~= true then
		warn("[FusionService] could not free the Garden / Gym slots of the fused pets")
		return false, nil
	end
	return true, placedIn
end

local function newHybridUid(profile)
	local seed = random():NextInteger(0, 2147483646)
	local uid = nil
	if type(petKeys.NewHybridId) == "function" then
		local ok, result = pcall(petKeys.NewHybridId, profile, seed)
		if ok and type(result) == "string" then
			uid = result
		end
	end
	return uid
end

-- Runs a plan. ok, resultKey | reason
local function execute(player, plan)
	local profile = plan.Profile
	if getProfile(player) ~= profile then
		return false, "Your data changed: try again"
	end
	local resultKey = plan.ResultKey
	local uid = nil
	local record = nil
	if plan.Action == "Mix" then
		uid = newHybridUid(profile)
		if not uid then
			return false, "Could not make a new hybrid: try again"
		end
		record = deepCopy(plan.Record)
		record.Seed = random():NextInteger(1, 999999)
		resultKey = petKeys.HybridKey(uid, plan.Tier)
		if not resultKey then
			return false, "Could not make a new hybrid: try again"
		end
	end

	-- everything below runs without yielding: the inputs leave, the result arrives and the price is paid together
	local snap = takeSnapshot(profile, plan)
	local consumed = {}
	local okStep, err = pcall(function()
		for _, input in ipairs(plan.Inputs) do
			if not petKeys.Remove(profile, input.Key, input.Count) then
				error("remove " .. input.Key, 0)
			end
			consumed[#consumed + 1] = input.Key
		end
		local added
		if record then
			added = petKeys.Add(profile, resultKey, 1, record)
		else
			added = petKeys.Add(profile, resultKey, 1)
		end
		if not added then
			error("add " .. tostring(resultKey), 0)
		end
		if not spendCurrency(player, plan.Currency, plan.Price) then
			error("price", 0)
		end
	end)
	if not okStep then
		restoreSnapshot(profile, snap, uid)
		if err == "price" then
			if plan.Currency == "Gems" then
				return false, "Not enough Gems"
			end
			return false, "Not enough Cloud Tokens"
		end
		warn("[FusionService] fusion rolled back: " .. tostring(err))
		return false, "The fusion fizzled: nothing was used"
	end
	-- the result takes over the places the inputs left
	rebuildEquipped(profile, plan.Freed, resultKey)
	writeLevel(profile, resultKey, plan.Level)
	local def = defOf(resultKey, profile)
	local role = (type(def) == "table" and def.Role) or plan.Role
	freeHomeSlots(player, plan.Freed, resultKey, role)
	dsCall("MarkDirty", player)
	return true, resultKey, def, consumed
end

local function finish(player, plan, resultKey, def, consumed)
	-- republish the equipped attributes and perks (PetService also re-validates the list), then the snapshot
	local refreshed = false
	if petService and type(petService.Refresh) == "function" then
		local ok = pcall(petService.Refresh, player)
		refreshed = ok
	end
	if not refreshed and petService and type(petService.GetPerks) == "function" then
		-- an older PetService: at least keep the attribute other clients draw from in step
		local profile = getProfile(player)
		if profile then
			pcall(function()
				player:SetAttribute(Config.Attr.EquippedPets, table.concat(profile.Equipped, ","))
			end)
		end
	end
	dsCall("Sync", player)
	local name = displayName(def, resultKey)
	local rarity = (type(def) == "table" and def.Rarity) or plan.Rarity
	if plan.Action == "Mix" then
		notify(player, "New hybrid: " .. name .. " (" .. tostring(rarity) .. ")!", "good", 4)
	else
		notify(player, "Fusion complete: " .. name .. "!", "good", 4)
	end
	reply(player, {
		Ok = true,
		Action = plan.Action,
		Key = resultKey,
		Name = name,
		Rarity = rarity,
		Tier = plan.Tier,
		Consumed = consumed,
	})
	FusionService.Fused:Fire(player, plan.Action, resultKey, consumed)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function FusionService.Unlocked(player)
	local ok, reason, info = checkUnlocked(player)
	return ok, reason, info
end

function FusionService.Preview(player, action, a, b)
	if action ~= "Upgrade" and action ~= "Mix" then
		return false, "Unknown fusion"
	end
	local ok, plan = buildPlan(player, action, a, b)
	if not ok then
		return false, plan
	end
	local inputs = {}
	for i, input in ipairs(plan.Inputs) do
		inputs[i] = { Key = input.Key, Count = input.Count }
	end
	local garden, gym = {}, {}
	for i, s in ipairs(plan.Freed.Garden) do
		garden[i] = s
	end
	for i, s in ipairs(plan.Freed.Gym) do
		gym[i] = s
	end
	return true, {
		Action = plan.Action,
		Cost = deepCopy(plan.Cost),
		ResultKey = plan.ResultKey,
		ResultName = plan.ResultName,
		Rarity = plan.Rarity,
		Tier = plan.Tier,
		Inputs = inputs,
		Freed = { Equipped = countKeys(plan.Freed.Equipped), Garden = garden, Gym = gym },
	}
end

local function run(player, action, a, b)
	local ok, plan = buildPlan(player, action, a, b)
	if not ok then
		return false, plan
	end
	local done, resultKey, def, consumed = execute(player, plan)
	if not done then
		return false, resultKey
	end
	finish(player, plan, resultKey, def, consumed)
	return true, resultKey
end

function FusionService.Upgrade(player, key)
	return run(player, "Upgrade", key, nil)
end

function FusionService.Mix(player, keyA, keyB)
	return run(player, "Mix", keyA, keyB)
end

----------------------------------------------------------------------
-- Remote Fusion(action, a, b)
----------------------------------------------------------------------

local function machineModel(player)
	if not tycoonService or type(tycoonService.GetPlot) ~= "function" then
		return nil, "unknown"
	end
	local ok, info = pcall(tycoonService.GetPlot, player)
	if not ok or type(info) ~= "table" then
		return nil, "noplot"
	end
	local hbm = getHomeBuilder()
	if hbm and type(hbm.GetStation) == "function" then
		local okStation, model = pcall(hbm.GetStation, info, MACHINE_ID)
		if okStation and typeof(model) == "Instance" and model.Parent then
			return model, nil
		end
	end
	local folder = info.Folder
	if typeof(folder) == "Instance" then
		local model = folder:FindFirstChild("Station_" .. MACHINE_ID, true)
		if model then
			return model, nil
		end
	end
	return nil, "nomodel"
end

local function modelPosition(model)
	if model:IsA("Model") then
		local ok, pivot = pcall(model.GetPivot, model)
		if ok and typeof(pivot) == "CFrame" then
			return pivot.Position
		end
	elseif model:IsA("BasePart") then
		return model.Position
	end
	return nil
end

-- ok, reason: remote requests come from the window at the player's own machine
local function nearMachine(player)
	local model, why = machineModel(player)
	if not model then
		if why == "noplot" then
			return false, "Claim your home and use its Fusion Machine"
		end
		return true -- no plot service / no machine model to measure (HomeBuilder missing): the data checks decide
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local at = modelPosition(model)
	if not root or not at then
		return false, "Walk up to your Fusion Machine"
	end
	if (root.Position - at).Magnitude > MACHINE_RANGE then
		return false, "Walk up to your Fusion Machine"
	end
	return true
end

local function validKeyArg(v)
	return type(v) == "string" and v ~= "" and #v <= MAX_KEY_LENGTH
end

local function onFusionRemote(player, action, a, b)
	if not isPlayer(player) or type(action) ~= "string" or #action > MAX_ACTION_LENGTH then
		return
	end
	if not spend(player) then
		return
	end
	if action ~= "Upgrade" and action ~= "Mix" then
		return
	end
	if not validKeyArg(a) or (action == "Mix" and not validKeyArg(b)) then
		reply(player, { Ok = false, Action = action, Reason = "Pick the pets to fuse" })
		return
	end
	if action == "Upgrade" then
		b = nil
	end
	if not cooldownReady(player) then
		reply(player, { Ok = false, Action = action, Reason = "One fusion at a time", Quiet = true })
		return
	end
	local okNear, whyNear = nearMachine(player)
	if not okNear then
		toastOnce(player, whyNear, "bad")
		reply(player, { Ok = false, Action = action, Reason = whyNear })
		return
	end
	local ok, result = run(player, action, a, b)
	if not ok then
		toastOnce(player, result or "That fusion is not possible", "bad")
		reply(player, { Ok = false, Action = action, Reason = result })
	end
end

local function forget(player)
	cooldowns[player] = nil
	budgets[player] = nil
	toastAt[player] = nil
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------

function FusionService.Init(deps)
	if initialized then
		return
	end
	deps = type(deps) == "table" and deps or {}
	dataService = deps.DataService or requireModule(script.Parent, "DataService")
	petService = deps.PetService or requireModule(script.Parent, "PetService")
	tycoonService = deps.TycoonService
	petKeys = requireModule(Shared, "PetKeys")
	petCatalog = requireModule(Shared, "PetCatalog")
	catalog = requireModule(Shared, "TycoonCatalog")
	if not dataService or type(dataService.GetProfile) ~= "function" then
		warn("[FusionService] DataService is missing: the Fusion Machine is disabled")
		return
	end
	if not petKeys or type(petKeys.Add) ~= "function" or type(petKeys.Remove) ~= "function" then
		warn("[FusionService] PetKeys is missing: the Fusion Machine is disabled")
		return
	end
	if not catalog or type(catalog.FusionCost) ~= "function" then
		warn("[FusionService] TycoonCatalog has no fusion costs: the Fusion Machine is disabled")
		return
	end
	initialized = true
	local ok, remote = pcall(Remotes.Get, "Fusion")
	if ok and remote then
		fusionRemote = remote
		remote.OnServerEvent:Connect(onFusionRemote)
	else
		warn("[FusionService] the Fusion remote is missing: fusing only works from server code")
	end
	-- no per-player state to set up for players already in the game: everything is read from their profile on use
	Players.PlayerRemoving:Connect(forget)
end

return FusionService
