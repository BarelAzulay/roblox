-- GemService (Phase 2, gems): Gems, the premium currency bought with Robux, and the gem-priced roulettes
-- (ARCHITECTURE_V3.md "Phase 2: Tycoon homes" -> Economy, and the GemService paragraph of the "Phase 2 build contract").
--
-- * Developer products: Config.Gems.Products = { {Id, Gems, Name}... }. Id 0 means the owner has not created that
--   product yet (Creator Hub -> the experience -> Monetization -> Developer Products, then paste its id into Config):
--   such a pack is hidden and never sold.
-- * ProcessReceipt: MarketplaceService.ProcessReceipt is set here and nowhere else (Roblox allows one callback per
--   server). Idempotent through the profile's GemReceipts (DataService.MarkReceipt): the purchase id and the gems are
--   written to the live profile in ONE non-yielding step, then the profile is saved (one UpdateAsync carries both),
--   and only a successful save answers PurchaseGranted. So a purchase is granted once per purchase id: a second call
--   (Roblox retries, another server after a rejoin) finds the receipt and grants nothing; a lost save loses the receipt
--   together with the gems, and the retry grants them again. While the profile is not loaded yet (or provisional:
--   the load failed, the real save is unknown) the callback waits up to ProfileWaitSeconds, then answers
--   NotProcessedYet and Roblox asks again later. Unknown product, malformed receipt, player not in this server, failed
--   save: NotProcessedYet. In Studio a failed save still answers PurchaseGranted (test purchases cost nothing and the
--   gems are already in the session).
-- * PromptPurchase(player, ref): a validated request (live player, not in a match, a CREATED product picked by its
--   index in Config.Gems.Products or by its product id, a 1 s cooldown) -> MarketplaceService:PromptProductPurchase.
--   A client may also prompt by itself: Gems are only ever granted by ProcessReceipt. Config.Remotes has no gem remote
--   yet; when the lead adds "BuyGems" (ref) it is connected here (rate-limited, numbers only).
-- * PolicyService: GetPolicyInfoForPlayerAsync (pcall) on join, retried with backoff by ONE loop ->
--   ArePaidRandomItemsRestricted. Until the answer is known, or when it is true (or missing), the player counts as
--   restricted: every gem-priced roulette (token roulettes paid with Gems, the gems-only Secret roulette) is refused,
--   and the player attribute PaidRandomItemsRestricted (true while restricted or unknown) tells the client to hide them.
--   Buying Gems themselves stays possible (a fixed amount is not a random item); Cloud Token roulettes are untouched.
-- * Gem roulettes: every token roulette with a price in Config.Gems.RouletteGemPrices (the same odds as with Cloud
--   Tokens) and the gems-only Secret roulette (Config.Gems.SecretRoulette, AllowSecret = true: the ONLY source of
--   Secret pets) at the Storm Altar. PetService.BuyRoulette(player, rouletteId, "Gems") charges and grants atomically;
--   this module quotes the price and checks the policy. Odds are always available: GetOdds / GetRarityOdds give the
--   exact numbers the roll uses, and a roulette whose odds cannot be listed is not sold.
--
-- Public API
--   GemService.Init(deps)                         deps = { DataService, PetService } (players already in game too)
--   GemService.ProcessReceipt(receiptInfo) -> Enum.ProductPurchaseDecision     (yields: profile wait + save)
--   GemService.PromptPurchase(player, ref) -> ok, reason    ref = product index (1..n) or developer product id
--   GemService.GetProducts() -> { {Index, ProductId, Gems, Name}... }   created products only (Id ~= 0)
--   GemService.GetProduct(ref) -> {Index, ProductId, Gems, Name, Created} | nil
--   GemService.PolicyState(player) -> "Allowed" | "Restricted" | "Checking"
--   GemService.IsRestricted(player) -> bool                  true unless the policy said "Allowed"
--   GemService.SecretRouletteState(player) -> "Open" | "Restricted" | "Checking" | "Unavailable"   (the Storm Altar)
--   GemService.GetRoulette(id) -> {Id, DisplayName, GemPrice, Color, AllowSecret, GemsOnly, Odds} | nil   (a copy)
--   GemService.ListRoulettes() -> {def...}   token roulettes with a gem price (Config.Roulettes order), then gems-only
--   GemService.RoulettePrice(id) -> gems | nil
--   GemService.Quote(player, id) -> ok, {RouletteId, DisplayName, Price, AllowSecret, GemsOnly, Roll} | reason
--                                    (never yields; Roll = nil for token roulettes: PetCatalog.RollPet rolls them)
--   GemService.Roll(player, id) -> ok, result|reason    a gem-paid spin = PetService.BuyRoulette(player, id, "Gems")
--   GemService.RollPet(id, rng) -> petId | nil      token roulettes: PetCatalog.RollPet; gems-only: the same rules
--   GemService.GetOdds(id) -> {{PetId, Rarity, Chance}...}, GetRarityOdds(id) -> {{Rarity, Chance, Count}...},
--   GemService.PossiblePets(id) -> {PetDef...}               (the shapes PetCatalog uses)
--   GemService.GemsPurchased   Util.Signal Fire(player, gems, productId, purchaseId) after a granted purchase
--   GemService.ProfileWaitSeconds = 12                       how long ProcessReceipt waits for a loading profile
--
-- Plain Lua 5.1-compatible syntax only. Nothing here yields between a check and its write.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local PolicyService = game:GetService("PolicyService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local GemService = {}
GemService.GemsPurchased = Util.Signal() -- Fire(player, gems, productId, purchaseId)
GemService.ProfileWaitSeconds = 12

-- Names that are not in Config (lead-owned): local constants, listed as deviations.
local RESTRICTED_ATTR = "PaidRandomItemsRestricted" -- player attribute: true = hide / refuse gem-priced roulettes
local PURCHASE_REMOTE = "BuyGems" -- (ref) connected only once Config.Remotes lists it

local SECRET_RARITY = "Secret"
local PROMPT_COOLDOWN = 1 -- seconds between two purchase prompts of one player
local REMOTE_COOLDOWN = 0.5
local PROFILE_POLL = 0.5 -- ProcessReceipt: seconds between two looks at a loading profile
local MAX_GEMS_PER_PRODUCT = 10000000
local MAX_GEM_PRICE = 1000000000
local MAX_RECEIPT_KEY = 48 -- DataService keeps GemReceipts keys of 1..48 characters
local POLICY_RETRY = { 5, 15, 45, 120 } -- seconds before the retries of a failed policy lookup...
local POLICY_RETRY_LATER = 300 -- ...then every this many seconds
local POLICY_TICK = 2 -- the retry loop looks for due lookups this often
local POLICY_KICK_GAP = 5 -- an on-demand lookup (a refused gem roll) at most this often per player
local THANKS_SECONDS = 5

local initialized = false
local dataRef = nil
local petRef = nil
local catalogRef = nil
local catalogTried = false

local policy = {} -- [Player] = { State = "Checking"|"Allowed"|"Restricted", Busy, Fails, NextTry, LastTry }
local promptAt = {} -- [Player] = os.clock() of the last purchase prompt
local lastCall = {} -- [Player] = { [key] = os.clock() }
local warned = {} -- [key] = true: one warning per problem per server

----------------------------------------------------------------------
-- Collaborators (every use is guarded: other engineers write them)
----------------------------------------------------------------------

local function requireIn(container, name)
	local module = container and container:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[GemService] could not load " .. name .. ": " .. tostring(result))
	return nil
end

local function getData()
	if not dataRef then
		dataRef = requireIn(script.Parent, "DataService")
	end
	return dataRef
end

local function getCatalog()
	if not catalogTried then
		catalogTried = true
		catalogRef = requireIn(Shared, "PetCatalog")
	end
	return catalogRef
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function isFinite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function wholeNumber(n)
	if not isFinite(n) or n ~= math.floor(n) then
		return nil
	end
	return n
end

local function isPlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function warnOnce(key, text)
	if warned[key] then
		return
	end
	warned[key] = true
	warn(text)
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

local function notify(player, text, kind, duration)
	local ok, remote = pcall(Remotes.Get, "Notify")
	if ok and remote and player and player.Parent then
		remote:FireClient(player, text, kind or "info", duration or 3)
	end
end

local function gemConfig()
	if type(Config.Gems) == "table" then
		return Config.Gems
	end
	return {}
end

----------------------------------------------------------------------
-- Developer products
----------------------------------------------------------------------

-- Every well-formed entry of Config.Gems.Products (read each time: the list is tiny and tests may change it).
local function readProducts()
	local out = {}
	local list = gemConfig().Products
	if type(list) ~= "table" then
		return out
	end
	for index, entry in ipairs(list) do
		if type(entry) == "table" then
			local id = wholeNumber(entry.Id)
			local amount = wholeNumber(entry.Gems)
			if id and id >= 0 and amount and amount >= 1 and amount <= MAX_GEMS_PER_PRODUCT then
				local name = entry.Name
				if type(name) ~= "string" or name == "" then
					name = Util.Commas(amount) .. " Gems"
				end
				out[#out + 1] = { Index = index, ProductId = id, Gems = amount, Name = name, Created = id > 0 }
			end
		end
	end
	return out
end

local function copyProduct(p)
	return { Index = p.Index, ProductId = p.ProductId, Gems = p.Gems, Name = p.Name, Created = p.Created }
end

-- The first CREATED product with that developer product id.
local function productById(productId)
	for _, p in ipairs(readProducts()) do
		if p.Created and p.ProductId == productId then
			return p
		end
	end
	return nil
end

-- ref = an index into Config.Gems.Products (1..n) or a created product's id.
local function productByRef(ref)
	local n = wholeNumber(ref)
	if not n or n < 1 then
		return nil
	end
	local list = readProducts()
	for _, p in ipairs(list) do
		if p.Index == n then
			return p
		end
	end
	for _, p in ipairs(list) do
		if p.Created and p.ProductId == n then
			return p
		end
	end
	return nil
end

function GemService.GetProducts()
	local out = {}
	for _, p in ipairs(readProducts()) do
		if p.Created then
			out[#out + 1] = { Index = p.Index, ProductId = p.ProductId, Gems = p.Gems, Name = p.Name }
		end
	end
	return out
end

function GemService.GetProduct(ref)
	local p = productByRef(ref)
	if p then
		return copyProduct(p)
	end
	return nil
end

----------------------------------------------------------------------
-- PolicyService: paid random items
----------------------------------------------------------------------

local function publishPolicy(player, entry)
	if player.Parent ~= Players then
		return
	end
	local restricted = entry.State ~= "Allowed"
	if player:GetAttribute(RESTRICTED_ATTR) ~= restricted then
		player:SetAttribute(RESTRICTED_ATTR, restricted)
	end
end

-- The engine's lookup function, or nil where the API is missing (it never is on Roblox; offline test doubles).
local function policyApi()
	local ok, fn = pcall(function()
		return PolicyService.GetPolicyInfoForPlayerAsync
	end)
	if ok and type(fn) == "function" then
		return fn
	end
	return nil
end

-- One lookup (yields inside the PolicyService call). A failure keeps a known answer and schedules a retry.
local function lookupPolicy(player)
	local entry = policy[player]
	if not entry or entry.Busy then
		return
	end
	local fn = policyApi()
	if not fn then
		return -- no API (offline test doubles): stays "Checking", i.e. restricted
	end
	entry.Busy = true
	entry.LastTry = os.clock()
	local ok, info = pcall(fn, PolicyService, player)
	entry.Busy = false
	if policy[player] ~= entry or player.Parent ~= Players then
		return
	end
	if ok and type(info) == "table" then
		local flag = info.ArePaidRandomItemsRestricted
		if flag == false then
			entry.State = "Allowed"
		else
			entry.State = "Restricted" -- true, or an answer without the field: the careful side
			if flag ~= true then
				warnOnce("policy-shape", "[GemService] PolicyService answered without ArePaidRandomItemsRestricted: gem roulettes stay locked")
			end
		end
		entry.Fails = 0
		entry.NextTry = nil
	else
		entry.Fails = entry.Fails + 1
		entry.NextTry = os.clock() + (POLICY_RETRY[entry.Fails] or POLICY_RETRY_LATER)
		warnOnce("policy-fail", "[GemService] PolicyService lookup failed (" .. tostring(info) .. "): gem roulettes stay locked for that player until a retry succeeds")
	end
	publishPolicy(player, entry)
end

local function startPolicy(player)
	local entry = policy[player]
	if entry then
		return entry
	end
	entry = { State = "Checking", Busy = false, Fails = 0, NextTry = nil, LastTry = nil }
	policy[player] = entry
	publishPolicy(player, entry)
	task.spawn(lookupPolicy, player)
	return entry
end

-- A refused gem roll while the answer is unknown asks again now (not before POLICY_KICK_GAP since the last try).
local function kickPolicy(player)
	local entry = policy[player]
	if not entry or entry.Busy or entry.State ~= "Checking" then
		return
	end
	if entry.LastTry and os.clock() - entry.LastTry < POLICY_KICK_GAP then
		return
	end
	entry.NextTry = nil
	task.spawn(lookupPolicy, player)
end

-- One loop for every retry (no thread per player, nothing left behind when players leave).
local function policyLoop()
	while true do
		task.wait(POLICY_TICK)
		local now = os.clock()
		local due = {}
		for player, entry in pairs(policy) do
			if not entry.Busy and entry.NextTry and now >= entry.NextTry then
				due[#due + 1] = player
			end
		end
		for _, player in ipairs(due) do
			local entry = policy[player]
			if entry and player.Parent == Players then
				entry.NextTry = nil
				task.spawn(lookupPolicy, player)
			end
		end
	end
end

function GemService.PolicyState(player)
	if not isPlayer(player) then
		return "Checking"
	end
	return startPolicy(player).State
end

function GemService.IsRestricted(player)
	return GemService.PolicyState(player) ~= "Allowed"
end

----------------------------------------------------------------------
-- Gem roulettes: definitions, odds, rolls
----------------------------------------------------------------------

local function tokenRoulette(rouletteId)
	for _, r in ipairs(Config.Roulettes) do
		if r.Id == rouletteId then
			return r
		end
	end
	return nil
end

-- Roulettes that exist only for Gems (today: the Secret roulette at the Storm Altar).
local function gemsOnlySources()
	local out = {}
	local secret = gemConfig().SecretRoulette
	if type(secret) == "table" and type(secret.Id) == "string" and secret.Id ~= "" then
		out[1] = secret
	end
	return out
end

local function gemsOnlySource(rouletteId)
	if tokenRoulette(rouletteId) then
		return nil -- a token roulette id always means the token roulette
	end
	for _, src in ipairs(gemsOnlySources()) do
		if src.Id == rouletteId then
			return src
		end
	end
	return nil
end

local function validPrice(n)
	n = wholeNumber(n)
	if n and n >= 1 and n <= MAX_GEM_PRICE then
		return n
	end
	return nil
end

local function makeDef(src, price, gemsOnly)
	local odds = {}
	if type(src.Odds) == "table" then
		for rarity, weight in pairs(src.Odds) do
			odds[rarity] = weight
		end
	end
	return {
		Id = src.Id,
		DisplayName = (type(src.DisplayName) == "string" and src.DisplayName ~= "") and src.DisplayName or src.Id,
		GemPrice = price,
		Color = src.Color,
		AllowSecret = src.AllowSecret == true,
		GemsOnly = gemsOnly,
		Odds = odds,
	}
end

function GemService.GetRoulette(rouletteId)
	if type(rouletteId) ~= "string" then
		return nil
	end
	local token = tokenRoulette(rouletteId)
	if token then
		local prices = gemConfig().RouletteGemPrices
		local price = type(prices) == "table" and validPrice(prices[rouletteId]) or nil
		if not price then
			return nil
		end
		return makeDef(token, price, false)
	end
	local src = gemsOnlySource(rouletteId)
	if src then
		local price = validPrice(src.GemPrice)
		if not price then
			return nil
		end
		return makeDef(src, price, true)
	end
	return nil
end

function GemService.ListRoulettes()
	local out = {}
	for _, r in ipairs(Config.Roulettes) do
		local def = GemService.GetRoulette(r.Id)
		if def then
			out[#out + 1] = def
		end
	end
	for _, src in ipairs(gemsOnlySources()) do
		local def = GemService.GetRoulette(src.Id)
		if def then
			out[#out + 1] = def
		end
	end
	return out
end

function GemService.RoulettePrice(rouletteId)
	local def = GemService.GetRoulette(rouletteId)
	return def and def.GemPrice or nil
end

local sortedRarities = nil
local function rarityOrder()
	if not sortedRarities then
		sortedRarities = {}
		for _, r in ipairs(Config.Rarities) do
			sortedRarities[#sortedRarities + 1] = r
		end
		table.sort(sortedRarities, function(a, b)
			return (a.Order or 0) < (b.Order or 0)
		end)
	end
	return sortedRarities
end

local function petsOfRarity(rarityId)
	local catalog = getCatalog()
	if not catalog or type(catalog.ListByRarity) ~= "function" then
		return {}
	end
	local ok, list = pcall(catalog.ListByRarity, rarityId)
	if ok and type(list) == "table" then
		return list
	end
	return {}
end

-- Rarity buckets a gems-only roulette can produce (PetCatalog's rules: rarity order, weight > 0, rarities without
-- pets skipped, Secret only with AllowSecret = true) -> { {Rarity, Weight, Pets} }, total weight.
local function oddsEntries(src)
	local entries, total = {}, 0
	if type(src) ~= "table" or type(src.Odds) ~= "table" then
		return entries, 0
	end
	for _, r in ipairs(rarityOrder()) do
		local w = src.Odds[r.Id]
		if isFinite(w) and w > 0 and (r.Id ~= SECRET_RARITY or src.AllowSecret == true) then
			local pets = petsOfRarity(r.Id)
			if #pets > 0 then
				entries[#entries + 1] = { Rarity = r.Id, Weight = w, Pets = pets }
				total = total + w
			end
		end
	end
	return entries, total
end

-- Calls PetCatalog[fnName](rouletteId) for a token roulette; returns the table or {}.
local function fromCatalog(fnName, rouletteId)
	local catalog = getCatalog()
	if not catalog or type(catalog[fnName]) ~= "function" then
		return {}
	end
	local ok, result = pcall(catalog[fnName], rouletteId)
	if ok and type(result) == "table" then
		return result
	end
	return {}
end

-- rng: anything with :Float(a, b) and :Int(a, b) (Util.NewRng); math.random without one.
function GemService.RollPet(rouletteId, rng)
	if type(rouletteId) ~= "string" then
		return nil
	end
	if tokenRoulette(rouletteId) then
		local catalog = getCatalog()
		if catalog and type(catalog.RollPet) == "function" then
			return catalog.RollPet(rouletteId, rng)
		end
		return nil
	end
	local entries, total = oddsEntries(gemsOnlySource(rouletteId))
	if #entries == 0 or total <= 0 then
		return nil
	end
	local r
	if type(rng) == "table" and type(rng.Float) == "function" then
		r = rng:Float(0, total)
	else
		r = math.random() * total
	end
	local picked = entries[#entries] -- also covers r landing on the very end
	local acc = 0
	for _, e in ipairs(entries) do
		acc = acc + e.Weight
		if r < acc then
			picked = e
			break
		end
	end
	local pets = picked.Pets
	local idx
	if type(rng) == "table" and type(rng.Int) == "function" then
		idx = rng:Int(1, #pets)
	else
		idx = math.random(1, #pets)
	end
	idx = math.floor(tonumber(idx) or 1)
	if idx < 1 then
		idx = 1
	elseif idx > #pets then
		idx = #pets
	end
	return pets[idx].Id
end

-- Exact per-pet chances: the rarity's share split evenly between its pets (what RollPet does).
function GemService.GetOdds(rouletteId)
	if type(rouletteId) ~= "string" then
		return {}
	end
	if tokenRoulette(rouletteId) then
		return fromCatalog("GetOdds", rouletteId)
	end
	local out = {}
	local entries, total = oddsEntries(gemsOnlySource(rouletteId))
	if total <= 0 then
		return out
	end
	for _, e in ipairs(entries) do
		local each = (e.Weight / total) / #e.Pets
		for _, def in ipairs(e.Pets) do
			out[#out + 1] = { PetId = def.Id, Rarity = e.Rarity, Chance = each }
		end
	end
	return out
end

function GemService.GetRarityOdds(rouletteId)
	if type(rouletteId) ~= "string" then
		return {}
	end
	if tokenRoulette(rouletteId) then
		return fromCatalog("GetRarityOdds", rouletteId)
	end
	local out = {}
	local entries, total = oddsEntries(gemsOnlySource(rouletteId))
	if total <= 0 then
		return out
	end
	for _, e in ipairs(entries) do
		out[#out + 1] = { Rarity = e.Rarity, Chance = e.Weight / total, Count = #e.Pets }
	end
	return out
end

function GemService.PossiblePets(rouletteId)
	if type(rouletteId) ~= "string" then
		return {}
	end
	if tokenRoulette(rouletteId) then
		return fromCatalog("PossiblePets", rouletteId)
	end
	local out = {}
	local entries = oddsEntries(gemsOnlySource(rouletteId))
	for _, e in ipairs(entries) do
		for _, def in ipairs(e.Pets) do
			out[#out + 1] = def
		end
	end
	return out
end

-- The price and roll of a gem-paid spin, after the policy check. Never yields (PetService calls it right before its
-- atomic charge + grant). ok, quote | reason.
function GemService.Quote(player, rouletteId)
	local def = GemService.GetRoulette(rouletteId)
	if not def then
		return false, "That roulette cannot be paid with Gems"
	end
	local state = GemService.PolicyState(player)
	if state == "Restricted" then
		return false, "Gem roulettes are not available on your account"
	elseif state ~= "Allowed" then
		kickPolicy(player)
		return false, "Checking your account, try again in a moment"
	end
	-- odds are always shown: a roulette whose odds cannot be listed is not sold
	if #GemService.GetOdds(def.Id) == 0 then
		return false, "That roulette is unavailable right now"
	end
	return true, {
		RouletteId = def.Id,
		DisplayName = def.DisplayName,
		Price = def.GemPrice,
		AllowSecret = def.AllowSecret,
		GemsOnly = def.GemsOnly,
		Roll = def.GemsOnly and GemService.RollPet or nil,
	}
end

-- Extra: a gem-paid spin through PetService (the same path as the BuyRoulette remote with "Gems").
function GemService.Roll(player, rouletteId)
	local pets = petRef or requireIn(script.Parent, "PetService")
	if not pets or type(pets.BuyRoulette) ~= "function" then
		return false, "Pets are unavailable right now"
	end
	return pets.BuyRoulette(player, rouletteId, "Gems")
end

-- What the Storm Altar's prompt does for this player: open the Secret roulette, explain the restriction, or (gem
-- system still checking the account / roulette missing) show the "awakens soon" toast.
function GemService.SecretRouletteState(player)
	local src = gemsOnlySources()[1]
	if not src or not GemService.GetRoulette(src.Id) or #GemService.GetOdds(src.Id) == 0 then
		return "Unavailable"
	end
	local state = GemService.PolicyState(player)
	if state == "Allowed" then
		return "Open"
	elseif state == "Restricted" then
		return "Restricted"
	end
	kickPolicy(player)
	return "Checking"
end

----------------------------------------------------------------------
-- Purchases
----------------------------------------------------------------------

function GemService.PromptPurchase(player, ref)
	if not isPlayer(player) then
		return false, "Player unavailable"
	end
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return false, "The shop is closed during a match"
	end
	local product = productByRef(ref)
	if not product then
		return false, "Unknown gem pack"
	end
	if not product.Created then
		return false, "That gem pack is not on sale yet"
	end
	local now = os.clock()
	local last = promptAt[player]
	if last and now - last < PROMPT_COOLDOWN then
		return false, "Please wait a moment"
	end
	promptAt[player] = now
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, product.ProductId)
	end)
	if not ok then
		warnOnce("prompt", "[GemService] PromptProductPurchase failed: " .. tostring(err))
		return false, "The purchase window could not open"
	end
	return true
end

-- The key GemReceipts stores for a purchase id (DataService keeps keys of 1..48 characters; a longer id becomes a
-- stable short form: its first characters plus two hashes of the whole id).
local function hashOf(s, mult, modulus)
	local h = 0
	for i = 1, #s do
		h = (h * mult + string.byte(s, i)) % modulus
	end
	return h
end

local function receiptKey(purchaseId)
	if isFinite(purchaseId) then
		purchaseId = string.format("%.0f", purchaseId)
	end
	if type(purchaseId) ~= "string" or purchaseId == "" then
		return nil
	end
	if #purchaseId <= MAX_RECEIPT_KEY then
		return purchaseId
	end
	return string.sub(purchaseId, 1, 28) .. "#" .. string.format("%08x%08x", hashOf(purchaseId, 31, 2147483647), hashOf(purchaseId, 131, 2147483629))
end

-- Takes a receipt back out of the live profile (only when the gems could not be added in the same step).
local function unmarkReceipt(data, player, key)
	local profile = type(data.GetProfile) == "function" and data.GetProfile(player) or nil
	local receipts = type(profile) == "table" and profile.GemReceipts or nil
	if type(receipts) == "table" then
		receipts[key] = nil
	end
end

function GemService.ProcessReceipt(receiptInfo)
	local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	if type(receiptInfo) ~= "table" then
		return NOT_YET
	end
	local userId = wholeNumber(receiptInfo.PlayerId)
	local productId = wholeNumber(receiptInfo.ProductId)
	local key = receiptKey(receiptInfo.PurchaseId)
	if not userId or not productId or not key then
		warnOnce("receipt-shape", "[GemService] a malformed receipt was not granted (Roblox keeps it pending)")
		return NOT_YET
	end
	local product = productById(productId)
	if not product then
		warnOnce("product-" .. tostring(productId), "[GemService] receipt for developer product " .. tostring(productId)
			.. ", which Config.Gems.Products does not list: not granted (Roblox keeps it pending)")
		return NOT_YET
	end
	local data = getData()
	if not data or type(data.MarkReceipt) ~= "function" or type(data.AddGems) ~= "function" then
		warnOnce("receipt-data", "[GemService] DataService has no MarkReceipt / AddGems: purchases stay pending")
		return NOT_YET
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return NOT_YET -- not in this server: Roblox asks again when they join one
	end

	-- Was it granted before? Only a loaded, non-provisional profile can tell (MarkReceipt answers nil until then).
	local marked = data.MarkReceipt(player, key)
	local waited = 0
	while marked == nil and player.Parent == Players and waited < GemService.ProfileWaitSeconds do
		task.wait(PROFILE_POLL)
		waited = waited + PROFILE_POLL
		marked = data.MarkReceipt(player, key)
	end
	if marked == nil then
		return NOT_YET
	end
	if marked == true then
		-- a new purchase: the gems go in now, in the same step as the receipt (nothing yields in between)
		if not data.AddGems(player, product.Gems) then
			unmarkReceipt(data, player, key)
			warnOnce("receipt-grant", "[GemService] could not add the Gems of a purchase: it stays pending")
			return NOT_YET
		end
		notify(player, "+" .. Util.Commas(product.Gems) .. " Gems! Thank you for your support!", "good", THANKS_SECONDS)
		GemService.GemsPurchased:Fire(player, product.Gems, productId, key)
	end
	-- Durable before Roblox hears "done": the save carries the receipt and the gems together (a duplicate call saves
	-- too: an earlier save of this purchase may have failed).
	if type(data.Save) == "function" then
		local okSave, saved = pcall(data.Save, player)
		if okSave and saved == true then
			return GRANTED
		end
	end
	if RunService:IsStudio() then
		return GRANTED -- Studio test purchases cost nothing; the gems are in the session
	end
	return NOT_YET
end

-- The callback Roblox calls (a wrapper: an error answers NotProcessedYet instead of breaking the purchase queue).
local function receiptCallback(receiptInfo)
	local ok, result = pcall(GemService.ProcessReceipt, receiptInfo)
	if ok and result ~= nil then
		return result
	end
	if not ok then
		warn("[GemService] ProcessReceipt errored: " .. tostring(result))
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

----------------------------------------------------------------------
-- Init: config check, receipt callback, the optional purchase remote, players
----------------------------------------------------------------------

local function checkConfig()
	local gems = gemConfig()
	local list = type(gems.Products) == "table" and gems.Products or {}
	local valid = readProducts()
	if #valid ~= #list then
		warn("[GemService] " .. (#list - #valid) .. " entries of Config.Gems.Products are malformed (need Id >= 0, Gems >= 1)")
	end
	local seen, onSale = {}, 0
	for _, p in ipairs(valid) do
		if p.Created then
			onSale = onSale + 1
			if seen[p.ProductId] then
				warn("[GemService] developer product " .. p.ProductId .. " is listed twice in Config.Gems.Products (the first entry counts)")
			end
			seen[p.ProductId] = true
		end
	end
	if type(gems.RouletteGemPrices) == "table" then
		for id, price in pairs(gems.RouletteGemPrices) do
			if not tokenRoulette(id) then
				warn("[GemService] Config.Gems.RouletteGemPrices names an unknown roulette: " .. tostring(id))
			elseif not validPrice(price) then
				warn("[GemService] Config.Gems.RouletteGemPrices." .. tostring(id) .. " is not a whole number of Gems >= 1")
			end
		end
	end
	for _, src in ipairs(gemsOnlySources()) do
		if not validPrice(src.GemPrice) then
			warn("[GemService] " .. tostring(src.Id) .. " roulette: GemPrice must be a whole number of Gems >= 1")
		elseif #GemService.GetOdds(src.Id) == 0 then
			warn("[GemService] " .. tostring(src.Id) .. " roulette has no odds with pets in them: it is not sold")
		end
	end
	print(string.format("[GemService] %d of %d gem packs on sale%s", onSale, #list,
		onSale < #list and " (product id 0 = not created yet: paste the developer product ids into Config.Gems.Products)" or ""))
end

local function connectPurchaseRemote()
	local listed = false
	for _, name in ipairs(Config.Remotes) do
		if name == PURCHASE_REMOTE then
			listed = true
		end
	end
	if not listed then
		return
	end
	local ok, remote = pcall(Remotes.Get, PURCHASE_REMOTE)
	if not ok or not remote then
		return
	end
	remote.OnServerEvent:Connect(function(player, ref)
		if rateLimited(player, PURCHASE_REMOTE, REMOTE_COOLDOWN) then
			return
		end
		if type(ref) ~= "number" then
			return
		end
		local okCall, success, reason = pcall(GemService.PromptPurchase, player, ref)
		if not okCall then
			warn("[GemService] PromptPurchase errored: " .. tostring(success))
		elseif not success and reason then
			notify(player, tostring(reason), "bad", 3)
		end
	end)
end

local function onPlayerAdded(player)
	if isPlayer(player) then
		startPolicy(player)
	end
end

local function onPlayerRemoving(player)
	policy[player] = nil
	promptAt[player] = nil
	lastCall[player] = nil
end

function GemService.Init(deps)
	if type(deps) == "table" then
		if type(deps.DataService) == "table" then
			dataRef = deps.DataService
		end
		if type(deps.PetService) == "table" then
			petRef = deps.PetService -- PetService pulls prices / the policy from here; kept for later callers
		end
	end
	if initialized then
		return
	end
	initialized = true
	getCatalog()
	local okCheck, errCheck = pcall(checkConfig)
	if not okCheck then
		warn("[GemService] config check failed: " .. tostring(errCheck))
	end
	local okSet, errSet = pcall(function()
		MarketplaceService.ProcessReceipt = receiptCallback
	end)
	if not okSet then
		warn("[GemService] could not set MarketplaceService.ProcessReceipt: " .. tostring(errSet))
	end
	connectPurchaseRemote()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	task.spawn(policyLoop)
end

return GemService
