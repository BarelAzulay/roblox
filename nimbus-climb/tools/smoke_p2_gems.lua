-- smoke_p2_gems.lua: Phase 2 gems (ARCHITECTURE_V3.md "Phase 2: Tycoon homes" -> Economy, and the GemService paragraph
-- of the "Phase 2 build contract": server/Services/GemService.lua, the gem / Secret roulette path of PetService and the
-- Storm Altar's prompt). Loaded by tools/smoke.py in the SERVER world:
--   p2gems_odds       (pure) the GemService API; Config.Gems (gem packs: product id 0 = hidden; gem prices of the
--                     token roulettes; the gems-only Secret roulette); gem roulette definitions (copies); odds that sum
--                     to 100% and equal the token roulettes' (PetCatalog.GetOdds) or Config.Gems.SecretRoulette's
--                     shares; Secret pets only from the Secret roulette (thousands of rolls of every token roulette with
--                     both roll functions never give one; the Secret roulette gives only Mythic / Secret pets, at its
--                     odds, and every Secret pet can come out)
--   p2gems_receipts   (booted) MarketplaceService.ProcessReceipt is GemService's; with pasted product ids a purchase
--                     grants its Gems ONCE, saved with the receipt before PurchaseGranted: a second call, two calls at
--                     once, a rejoin and an 80-character purchase id grant nothing more; NotProcessedYet (nothing
--                     granted) for an unknown or not-created product, malformed receipts, a buyer who is not here and a
--                     profile that is not loaded after the wait (then granted once when it is) or provisional (granted
--                     once after the recovery); a loading profile is waited for; a failed save answers NotProcessedYet
--                     and the retry PurchaseGranted without a second grant (Studio: PurchaseGranted); PromptPurchase:
--                     created packs by index or product id only, a 1 s cooldown, never in a match, never raises
--   p2gems_policy     (booted) PolicyService.GetPolicyInfoForPlayerAsync -> PolicyState + the player attribute
--                     PaidRandomItemsRestricted; restricted, failing, odd and still-running lookups: no gem roll at
--                     all (API and remote, nothing charged), token roulettes stay open; a failed lookup is retried and
--                     then allows; no PolicyService answer at all = never allowed
--   p2gems_roulettes  (booted) every gem price charged exactly (Gems, not tokens), RouletteResult Currency / Price /
--                     Gems with a valid strip, not enough Gems, the Secret roulette takes Gems only, a forced Secret pull
--                     (Stormfang: discovered, IsNew, auto-equipped as the first pet), real Secret pulls (Mythic / Secret,
--                     strip from the Secret pool), a Secret result of a token roulette refused (both currencies, nothing
--                     charged), a gem pull into a full stack costs nothing, junk currencies, in a match, the remote
--                     (2nd argument, rate limit, junk), GemService.Roll
--   p2gems_altar      (booted) the Storm Altar prompt ("Summon"): opens the Shop on the Secret roulette for an allowed
--                     account (OpenPanel to that player only, rate-limited, no toast), a side toast for a restricted
--                     account, the phase 1 "awakens soon" toast while the account is still being checked, forged
--                     triggers ignored
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local K = _G.K
local CONTEXT = (ARGS and ARGS.context) or "server"

local S = {}
if CONTEXT ~= "server" then
	return S
end

local abs, floor = math.abs, math.floor
local SECRET = "Secret"
local ATTR = "PaidRandomItemsRestricted" -- GemService's player attribute: true = hide / refuse gem-priced roulettes
local STRIP_LENGTH, WIN_INDEX = 40, 34
local STORMFANG = (CONTRACT and CONTRACT.v3 and CONTRACT.v3.stormfang and CONTRACT.v3.stormfang.petId) or "stormfang"

local function advance(seconds)
	K.advance(seconds)
end

local function requireAt(key)
	local inst = K.moduleInstance(key)
	if not inst then
		return nil
	end
	local ok, result = pcall(require, inst)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

local function GS()
	return requireAt("server/Services/GemService")
end
local function PC()
	return K.M["shared/PetCatalog"] or requireAt("shared/PetCatalog")
end
local function DS()
	return K.mod("DataService")
end
local function PS()
	return K.mod("PetService")
end

local function remote(name)
	local folder = K.remoteFolder()
	return folder and folder:FindFirstChild(name) or nil
end

local function gemsConfig()
	return K.config().Gems
end

local function secretId()
	local G = gemsConfig()
	return (type(G) == "table" and type(G.SecretRoulette) == "table" and G.SecretRoulette.Id) or "Secret"
end

local function gemPrice(rouletteId)
	local G = gemsConfig()
	return type(G) == "table" and type(G.RouletteGemPrices) == "table" and G.RouletteGemPrices[rouletteId] or nil
end

local function isSecretPet(petId)
	local def = PC() and PC().Get(petId)
	return def ~= nil and def.Rarity == SECRET
end

----------------------------------------------------------------------------------------------------
-- doubles for the engine services the mock leaves empty (installed per scenario, always removed again)
----------------------------------------------------------------------------------------------------
local PolS = game:GetService("PolicyService")
local MPS = game:GetService("MarketplaceService")
local policyModes = {} -- [userId] = "allow" | "restrict" | "error" | "nofield" | "slow"

local function installPolicy(default)
	PolS.GetPolicyInfoForPlayerAsync = function(_, player)
		local mode = policyModes[player.UserId] or default
		if mode == "error" then
			error("HTTP 503 (smoke: PolicyService outage)")
		end
		if mode == "slow" then
			task.wait(3)
			mode = "allow"
		end
		if mode == "nofield" then
			return { AllowedExternalLinkReferences = {}, IsPaidItemTradingAllowed = true }
		end
		return { ArePaidRandomItemsRestricted = mode == "restrict", IsPaidItemTradingAllowed = true }
	end
end

local function removeDoubles()
	PolS.GetPolicyInfoForPlayerAsync = nil
	MPS.PromptProductPurchase = nil
end

----------------------------------------------------------------------------------------------------
-- players and money
----------------------------------------------------------------------------------------------------
local userSeq = 0
local joinedIds = {} -- [userId] = true: every player this file added (the Secret log clean-up below)

local function joinAs(prefix, mode, wait)
	userSeq = userSeq + 1
	local uid = 985000 + userSeq
	policyModes[uid] = mode
	joinedIds[uid] = true
	local p = Mock.AddPlayer(prefix .. userSeq, uid)
	advance(wait or 1.0)
	return p
end

local function leaveAll(list)
	for _, p in ipairs(list) do
		if p and p.Parent then
			Mock.RemovePlayer(p)
		end
	end
	advance(0.8)
end

local function profileOf(p)
	return DS().GetProfile(p)
end

local function petCount(p)
	local n = 0
	local prof = profileOf(p)
	for _, c in pairs(prof and prof.Pets or {}) do
		n = n + c
	end
	return n
end

local function setGems(p, n)
	local D = DS()
	local cur = D.GetGems(p)
	if n > cur then
		D.AddGems(p, n - cur)
	elseif n < cur then
		D.SpendGems(p, cur - n)
	end
end

local function setTokens(p, n)
	local D = DS()
	local cur = D.GetTokens(p)
	if n > cur then
		D.AddTokens(p, n - cur)
	elseif n < cur then
		D.SpendTokens(p, cur - n)
	end
end

local function wallet(p)
	local prof = profileOf(p)
	return { Gems = DS().GetGems(p), Tokens = DS().GetTokens(p), Pets = petCount(p), Spins = prof and prof.Stats.Spins or -1 }
end

local function sameWallet(a, b)
	return a.Gems == b.Gems and a.Tokens == b.Tokens and a.Pets == b.Pets and a.Spins == b.Spins
end

local function stored(userId)
	return Mock.DataStore.Data[K.config().Tokens.DataStoreName .. "/u_" .. userId]
end

-- runs fn(...) in its own thread (it may yield): box.done / box.ok / box.result
local function spawnCall(fn, ...)
	local box = { done = false }
	local args = { n = select("#", ...), ... }
	task.spawn(function()
		local ok, result = pcall(fn, unpack(args, 1, args.n))
		box.ok, box.result, box.done = ok, result, true
	end)
	return box
end

-- A RouletteResult checked like tools/smoke_server.lua's payload check, with the strip against the roulette's own pool
-- (GemService.PossiblePets also knows the gems-only Secret roulette).
local function resultProblems(res, rouletteId)
	local out = {}
	if type(res) ~= "table" or res.Ok ~= true then
		return { "not Ok: " .. tostring(type(res) == "table" and res.Reason or res) }
	end
	if res.RouletteId ~= rouletteId then
		out[#out + 1] = "RouletteId " .. tostring(res.RouletteId)
	end
	if type(res.PetId) ~= "string" or type(res.IsNew) ~= "boolean" or type(res.Count) ~= "number" or res.Count < 1 or type(res.Tokens) ~= "number" or res.Tokens < 0 then
		out[#out + 1] = "PetId / IsNew / Count / Tokens"
	end
	if type(res.Strip) ~= "table" or #res.Strip ~= STRIP_LENGTH then
		out[#out + 1] = "Strip has " .. tostring(type(res.Strip) == "table" and #res.Strip or res.Strip) .. " entries"
	else
		if res.Strip[WIN_INDEX] ~= res.PetId then
			out[#out + 1] = "Strip[" .. WIN_INDEX .. "] is " .. tostring(res.Strip[WIN_INDEX])
		end
		local possible = {}
		for _, def in ipairs(GS().PossiblePets(rouletteId)) do
			possible[def.Id] = true
		end
		for i, id in ipairs(res.Strip) do
			if not possible[id] then
				out[#out + 1] = "Strip[" .. i .. "] = " .. tostring(id) .. " cannot come out of " .. tostring(rouletteId)
				break
			end
		end
	end
	return out
end

-- tools/smoke_server.lua's final payload check validates every RouletteResult strip against
-- PetCatalog.PossiblePets(RouletteId), and PetCatalog does not list the gems-only Secret roulette (it lives in
-- Config.Gems.SecretRoulette and GemService rolls it). The Secret spins of this file are checked above with the Secret
-- pool (resultProblems); they are taken out of the shared logs here so the older check (and the client replay of the
-- traffic, whose menu does not draw that roulette yet) do not misread them. Nothing is removed once PetCatalog knows
-- the Secret roulette.
local function forgetSecretSpins()
	local Pc = PC()
	if Pc and type(Pc.PossiblePets) == "function" and #Pc.PossiblePets(secretId()) > 0 then
		return 0
	end
	local removed = 0
	local log = Mock.RemoteLog
	for i = #log, 1, -1 do
		local e = log[i]
		local a = e.args and e.args[1]
		if e.remote == "RouletteResult" and joinedIds[e.userId] and type(a) == "table" and a.Ok == true and a.RouletteId == secretId() then
			table.remove(log, i)
			removed = removed + 1
		end
	end
	local rep = Mock.Replication or {}
	local needle = string.format("%q", secretId())
	for i = #rep, 1, -1 do
		local e = rep[i]
		if e.kind == "remote" and e.remote == "RouletteResult" and joinedIds[e.userId] and type(e.args) == "string" and string.find(e.args, needle, 1, true) then
			table.remove(rep, i)
		end
	end
	return removed
end

local ALLOWED_WARNINGS = { "[GemService]", "[DataService]" }

----------------------------------------------------------------------------------------------------
-- p2gems_odds (pure)
----------------------------------------------------------------------------------------------------
S.p2gems_odds = guarded("p2gems_odds", function()
	local Gs, Pc, Config = GS(), PC(), K.config()
	if not T.check(type(Gs) == "table", "gems: server/Services/GemService.lua loads") then
		return
	end
	local missing = {}
	for _, name in ipairs({ "Init", "ProcessReceipt", "PromptPurchase", "GetProducts", "GetProduct", "PolicyState", "IsRestricted",
		"SecretRouletteState", "GetRoulette", "ListRoulettes", "RoulettePrice", "Quote", "Roll", "RollPet", "GetOdds", "GetRarityOdds", "PossiblePets" }) do
		if type(Gs[name]) ~= "function" then
			missing[#missing + 1] = name
		end
	end
	T.check(#missing == 0, "gems: GemService exposes its API", table.concat(missing, ", "))
	T.check(type(Gs.GemsPurchased) == "table" and type(Gs.GemsPurchased.Connect) == "function" and type(Gs.GemsPurchased.Fire) == "function", "gems: GemService.GemsPurchased is a signal")
	T.check(type(Gs.ProfileWaitSeconds) == "number" and Gs.ProfileWaitSeconds >= 5, "gems: ProcessReceipt waits a few seconds for a loading profile (ProfileWaitSeconds)")

	-- Config.Gems
	local G = Config.Gems
	if not T.check(type(G) == "table" and type(G.Products) == "table" and type(G.RouletteGemPrices) == "table" and type(G.SecretRoulette) == "table",
		"gems: Config.Gems has Products, RouletteGemPrices and SecretRoulette") then
		return
	end
	local bad, created = {}, 0
	for i, p in ipairs(G.Products) do
		if type(p) ~= "table" or type(p.Id) ~= "number" or p.Id < 0 or p.Id ~= floor(p.Id) or type(p.Gems) ~= "number" or p.Gems < 1 or p.Gems ~= floor(p.Gems) or type(p.Name) ~= "string" then
			bad[#bad + 1] = "#" .. i
		elseif p.Id > 0 then
			created = created + 1
		end
	end
	T.check(#G.Products >= 1 and #bad == 0, "gems: every gem pack has a whole product Id >= 0, whole Gems >= 1 and a Name", table.concat(bad, ", "))
	T.eq(#Gs.GetProducts(), created, "gems: GetProducts lists only created packs (product id 0 = not created yet: hidden)")
	local savedIds = {}
	for i, p in ipairs(G.Products) do
		savedIds[i] = p.Id
	end
	local okP, errP = pcall(function()
		for i, p in ipairs(G.Products) do
			p.Id = (i == 1) and 0 or (4200000 + i)
		end
		local list = Gs.GetProducts()
		T.check(#list == #G.Products - 1 and list[1].Index == 2 and list[1].ProductId == 4200002 and list[1].Gems == G.Products[2].Gems and list[1].Name == G.Products[2].Name,
			"gems: a pack shows up once its product id is pasted into Config (the id 0 one stays hidden)")
		local byIndex, byId = Gs.GetProduct(2), Gs.GetProduct(4200003)
		T.check(byIndex and byIndex.ProductId == 4200002 and byId and byId.Index == 3, "gems: GetProduct finds a pack by its index or by its product id")
		T.check(Gs.GetProduct(1) and Gs.GetProduct(1).Created == false and Gs.GetProduct(2).Created == true, "gems: ...and tells whether it is created")
		local junkFound = false
		for _, ref in ipairs({ 0, -1, 1.5, "2", {}, true, 0 / 0, math.huge, 99999 }) do
			if Gs.GetProduct(ref) ~= nil then
				junkFound = true
			end
		end
		T.check(not junkFound and Gs.GetProduct(nil) == nil, "gems: GetProduct refuses junk references")
	end)
	for i, p in ipairs(G.Products) do
		p.Id = savedIds[i]
	end
	if not okP then
		error(errP, 0)
	end

	-- gem roulettes
	local sr = G.SecretRoulette
	local priced = 0
	for _, r in ipairs(Config.Roulettes) do
		local price = G.RouletteGemPrices[r.Id]
		local def = Gs.GetRoulette(r.Id)
		if price ~= nil then
			priced = priced + 1
			T.check(def ~= nil and def.GemPrice == price and def.GemsOnly == false and def.AllowSecret == false and Gs.RoulettePrice(r.Id) == price and def.DisplayName == r.DisplayName,
				"gems: the " .. r.Id .. " roulette also costs " .. tostring(price) .. " Gems (Config.Gems.RouletteGemPrices), no Secret pets")
		else
			T.check(def == nil and Gs.RoulettePrice(r.Id) == nil, "gems: the " .. r.Id .. " roulette has no gem price")
		end
	end
	local sdef = Gs.GetRoulette(sr.Id)
	T.check(sdef ~= nil and sdef.GemsOnly == true and sdef.AllowSecret == true and sdef.GemPrice == sr.GemPrice and Gs.RoulettePrice(sr.Id) == sr.GemPrice,
		"gems: the gems-only " .. tostring(sr.Id) .. " roulette costs " .. tostring(sr.GemPrice) .. " Gems and allows Secret pets")
	T.check(Gs.GetRoulette("NoSuchRoulette") == nil and Gs.GetRoulette(nil) == nil and Gs.GetRoulette(5) == nil and Gs.RoulettePrice("NoSuchRoulette") == nil,
		"gems: unknown roulettes have no gem price")
	local all = Gs.ListRoulettes()
	T.check(#all == priced + 1 and all[#all].Id == sr.Id and (priced == 0 or all[1].Id == Config.Roulettes[1].Id),
		"gems: ListRoulettes = the priced token roulettes in shop order, then the Secret roulette", #all .. " roulettes")
	if sdef then
		local savedOdds = sr.Odds[SECRET]
		sdef.GemPrice = 1
		sdef.Odds[SECRET] = 1000
		T.check(Gs.GetRoulette(sr.Id).GemPrice == sr.GemPrice and sr.Odds[SECRET] == savedOdds, "gems: GetRoulette hands out copies (the Config cannot be changed through them)")
	end

	-- odds: always showable, sum to 100%, the token roulettes' are PetCatalog's
	local function chanceSum(list)
		local s = 0
		for _, e in ipairs(list) do
			s = s + e.Chance
		end
		return s
	end
	for _, def in ipairs(all) do
		local odds = Gs.GetOdds(def.Id)
		T.check(#odds > 0 and abs(chanceSum(odds) - 1) < 1e-9 and abs(chanceSum(Gs.GetRarityOdds(def.Id)) - 1) < 1e-9,
			"gems: the " .. def.Id .. " roulette's odds can always be shown (per pet and per rarity, 100% in total)")
		if not def.GemsOnly then
			local cat = Pc.GetOdds(def.Id)
			local same = #cat == #odds
			for i = 1, math.min(#cat, #odds) do
				if cat[i].PetId ~= odds[i].PetId or abs(cat[i].Chance - odds[i].Chance) > 1e-12 then
					same = false
				end
			end
			T.check(same, "gems: ...paid with Gems the " .. def.Id .. " roulette has exactly its Cloud Token odds")
		end
	end
	local totalWeight = 0
	for rarity, w in pairs(sr.Odds) do
		if type(w) == "number" and w > 0 and #Pc.ListByRarity(rarity) > 0 then
			totalWeight = totalWeight + w
		end
	end
	local rarityOk = true
	for _, e in ipairs(Gs.GetRarityOdds(sr.Id)) do
		if abs(e.Chance - sr.Odds[e.Rarity] / totalWeight) > 1e-12 or e.Count ~= #Pc.ListByRarity(e.Rarity) then
			rarityOk = false
		end
	end
	T.check(rarityOk and #Gs.GetRarityOdds(sr.Id) >= 1, "gems: the Secret roulette's rarity shares are Config.Gems.SecretRoulette.Odds (Mythic 85 / Secret 15 -> 85% / 15%)")

	-- Secret pets only from the Secret roulette
	local secretPets = Pc.ListByRarity(SECRET)
	if not T.check(#secretPets >= 3, "gems: (precondition) the catalog has Secret pets") then
		return
	end
	local inPools = {}
	for _, r in ipairs(Config.Roulettes) do
		for _, list in ipairs({ Pc.PossiblePets(r.Id), Gs.PossiblePets(r.Id) }) do
			for _, def in ipairs(list) do
				if def.Rarity == SECRET then
					inPools[#inPools + 1] = r.Id .. ":" .. def.Id
				end
			end
		end
	end
	T.check(#inPools == 0, "gems: no token roulette lists a Secret pet (PetCatalog and GemService pools)", table.concat(inPools, ", "))
	local pool, poolRarities = {}, {}
	for _, def in ipairs(Gs.PossiblePets(sr.Id)) do
		pool[def.Id] = true
		poolRarities[def.Rarity] = true
	end
	local allSecrets = true
	for _, def in ipairs(secretPets) do
		allSecrets = allSecrets and pool[def.Id] == true
	end
	local foreign = false
	for rarity in pairs(poolRarities) do
		if type(sr.Odds[rarity]) ~= "number" or sr.Odds[rarity] <= 0 then
			foreign = true
		end
	end
	T.check(allSecrets and not foreign, "gems: the Secret roulette's pool holds every Secret pet and only rarities its odds name")

	local Util = requireAt("shared/Util")
	local rng = Util.NewRng(424242)
	local leaks = T.tally("gems: Secret pets only from the Secret roulette: 1500 rolls x 2 roll functions of every token roulette never give one")
	for _, r in ipairs(Config.Roulettes) do
		local found = nil
		for _ = 1, 1500 do
			local a, b = Pc.RollPet(r.Id, rng), Gs.RollPet(r.Id, rng)
			if isSecretPet(a) or isSecretPet(b) or a == nil or b == nil then
				found = tostring(a) .. " / " .. tostring(b)
			end
		end
		leaks:case(found == nil, r.Id .. ": " .. tostring(found))
	end
	leaks:report()
	local rolls, secrets, wrong, seen = 6000, 0, 0, {}
	for _ = 1, rolls do
		local id = Gs.RollPet(sr.Id, rng)
		local def = id and Pc.Get(id)
		if not def or not pool[id] then
			wrong = wrong + 1
		elseif def.Rarity == SECRET then
			secrets = secrets + 1
			seen[id] = true
		end
	end
	T.eq(wrong, 0, "gems: " .. rolls .. " Secret roulette rolls only give pets of its pool (Mythic / Secret)")
	local want = (sr.Odds[SECRET] or 0) / totalWeight
	T.near(secrets / rolls, want, 0.025, "gems: ...Secret pets at the advertised share (" .. string.format("%.0f%%", want * 100) .. ")")
	local missed = {}
	for _, def in ipairs(secretPets) do
		if not seen[def.Id] then
			missed[#missed + 1] = def.Id
		end
	end
	T.check(#missed == 0, "gems: ...and every Secret pet can come out (Stormfang too)", table.concat(missed, ", "))
	T.check(Gs.RollPet(sr.Id, Util.NewRng(7)) == Gs.RollPet(sr.Id, Util.NewRng(7)), "gems: a Secret roll is deterministic for a given seed (the cosmetic strip relies on it)")
	T.check(type(Gs.RollPet(sr.Id)) == "string" and Gs.RollPet("NoSuchRoulette", rng) == nil and Gs.RollPet(nil) == nil and #Gs.GetOdds("NoSuchRoulette") == 0 and #Gs.PossiblePets(nil) == 0,
		"gems: RollPet works without an rng and refuses unknown roulettes")
	K.flushErrors("p2gems_odds")
end)

----------------------------------------------------------------------------------------------------
-- p2gems_receipts (booted)
----------------------------------------------------------------------------------------------------
S.p2gems_receipts = guarded("p2gems_receipts", function()
	if not K.needBoot() then
		return
	end
	local Gs, DataS, Config = GS(), DS(), K.config()
	if not T.check(type(Gs) == "table", "gem receipts: GemService loads") then
		return
	end
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet
	local cb = MPS.ProcessReceipt
	T.check(type(cb) == "function", "gem receipts: GemService.Init set MarketplaceService.ProcessReceipt")
	if type(cb) ~= "function" then
		cb = Gs.ProcessReceipt
	end

	local G = Config.Gems
	local DSt = Mock.DataStore
	local saved = { Ids = {}, Studio = Mock.Options.Studio, Fail = DSt.Fail, Latency = DSt.Latency }
	for i, p in ipairs(G.Products) do
		saved.Ids[i] = p.Id
	end
	local players = {}
	local purchased = {}
	local conn = Gs.GemsPurchased:Connect(function(player, gems, productId, purchaseId)
		purchased[#purchased + 1] = { Player = player, Gems = gems, ProductId = productId, PurchaseId = purchaseId }
	end)

	local okRun, errRun = pcall(function()
		-- the owner pasted the product ids of every pack but the first
		for i, p in ipairs(G.Products) do
			p.Id = (i == 1) and 0 or (4300000 + i)
		end
		local pack, big = G.Products[2], G.Products[3]
		local seq = 0
		local function receipt(player, product, purchaseId)
			seq = seq + 1
			return { PlayerId = player.UserId, ProductId = product.Id, PurchaseId = purchaseId or ("smoke-purchase-" .. seq), CurrencySpent = 49, PlaceIdWherePurchased = 1 }
		end
		local function run(info)
			local box = spawnCall(cb, info)
			K.waitFor(function()
				return box.done
			end, 60)
			if not box.done then
				return "unfinished"
			end
			if not box.ok then
				return "error: " .. tostring(box.result)
			end
			return box.result
		end

		local p = joinAs("GemBuyer")
		players[#players + 1] = p
		T.check(profileOf(p) ~= nil and DataS.IsProvisional(p) ~= true, "gem receipts: (precondition) the buyer's profile is loaded")
		local g0 = DataS.GetGems(p)
		local mark = K.logSize()
		local r1 = receipt(p, pack)
		T.eq(run(r1), GRANTED, "gem receipts: buying a created pack answers PurchaseGranted")
		T.eq(DataS.GetGems(p), g0 + pack.Gems, "gem receipts: ...and adds its " .. pack.Gems .. " Gems")
		T.eq(p:GetAttribute(Config.Attr.Gems), g0 + pack.Gems, "gem receipts: ...mirrored on the Gems attribute (the HUD)")
		T.check(K.notified(p, "Gems", "good", mark), "gem receipts: ...with a thank-you side toast (Notify, good)")
		T.check(#purchased == 1 and purchased[1].Player == p and purchased[1].Gems == pack.Gems and purchased[1].ProductId == pack.Id and purchased[1].PurchaseId == r1.PurchaseId,
			"gem receipts: ...GemsPurchased fires once (player, gems, productId, purchaseId)")
		local rec = stored(p.UserId)
		T.check(type(rec) == "table" and rec.Gems == g0 + pack.Gems and type(rec.GemReceipts) == "table" and rec.GemReceipts[r1.PurchaseId] ~= nil,
			"gem receipts: ...saved BEFORE PurchaseGranted: the store holds the Gems and the receipt together", rec and ("stored Gems " .. tostring(rec.Gems)) or "nothing stored")

		T.eq(run(r1), GRANTED, "gem receipts: the same receipt again (Roblox retries) answers PurchaseGranted...")
		T.eq(DataS.GetGems(p), g0 + pack.Gems, "gem receipts: ...without a second grant")
		T.eq(#purchased, 1, "gem receipts: ...and without a second GemsPurchased")

		DSt.Latency = 0.5 -- the first call is still saving when the second one arrives
		local r2 = receipt(p, big)
		local a, b = spawnCall(cb, r2), spawnCall(cb, r2)
		K.waitFor(function()
			return a.done and b.done
		end, 60)
		DSt.Latency = saved.Latency
		T.check(a.result == GRANTED and b.result == GRANTED, "gem receipts: two calls for one purchase at the same time both answer PurchaseGranted", tostring(a.result) .. " / " .. tostring(b.result))
		T.eq(DataS.GetGems(p), g0 + pack.Gems + big.Gems, "gem receipts: ...and grant it once")

		local gNow = DataS.GetGems(p)
		T.eq(run({ PlayerId = p.UserId, ProductId = 999999901, PurchaseId = "smoke-unknown" }), NOT_YET, "gem receipts: a product Config.Gems.Products does not list answers NotProcessedYet")
		T.eq(run({ PlayerId = p.UserId, ProductId = 0, PurchaseId = "smoke-zero" }), NOT_YET, "gem receipts: ...so does product id 0 (a pack not created yet)")
		local junk = {
			n = 9,
			nil,
			{},
			{ PlayerId = p.UserId, ProductId = pack.Id },
			{ PlayerId = p.UserId, ProductId = pack.Id, PurchaseId = "" },
			{ PlayerId = "someone", ProductId = pack.Id, PurchaseId = "smoke-j1" },
			{ PlayerId = p.UserId, ProductId = 0 / 0, PurchaseId = "smoke-j2" },
			{ PlayerId = p.UserId, ProductId = pack.Id, PurchaseId = {} },
			"receipt",
			5,
		}
		local answers = {}
		for i = 1, junk.n do
			local ans = run(junk[i])
			if ans ~= NOT_YET then
				answers[#answers + 1] = "#" .. i .. " " .. tostring(ans)
			end
		end
		T.check(#answers == 0, "gem receipts: malformed receipts answer NotProcessedYet (no error)", table.concat(answers, ", "))
		T.eq(DataS.GetGems(p), gNow, "gem receipts: ...and none of these grants anything")
		T.eq(run({ PlayerId = 985999999, ProductId = pack.Id, PurchaseId = "smoke-away" }), NOT_YET,
			"gem receipts: a buyer who is not in this server: NotProcessedYet (Roblox asks again when they join)")

		-- an 80-character purchase id (longer than DataService keeps)
		local long = string.rep("9f3c", 20)
		local gL = DataS.GetGems(p)
		local ansL1 = run(receipt(p, pack, long))
		local ansL2 = run(receipt(p, pack, long))
		T.check(ansL1 == GRANTED and ansL2 == GRANTED and DataS.GetGems(p) == gL + pack.Gems, "gem receipts: an 80-character purchase id is granted once (its short key is found again)")
		local longKeys = {}
		for id in pairs(profileOf(p).GemReceipts or {}) do
			if #id > 48 then
				longKeys[#longKeys + 1] = id
			end
		end
		T.check(#longKeys == 0, "gem receipts: every receipt key fits DataService's 48 characters", table.concat(longKeys, ", "))

		-- a rejoin: the saved receipts come back with the profile
		local uid, gBefore = p.UserId, DataS.GetGems(p)
		leaveAll({ p })
		advance(1)
		local back = Mock.AddPlayer("GemBuyerAgain", uid)
		players[#players + 1] = back
		advance(1.2)
		T.eq(DataS.GetGems(back), gBefore, "gem receipts: (rejoin) the bought Gems were saved")
		T.eq(run(r1), GRANTED, "gem receipts: after a rejoin an old purchase answers PurchaseGranted...")
		T.eq(DataS.GetGems(back), gBefore, "gem receipts: ...and grants nothing (its id came back with the saved GemReceipts)")

		-- a profile that is still loading is waited for
		DSt.Latency = 2
		userSeq = userSeq + 1
		local slowId = 985000 + userSeq
		joinedIds[slowId] = true
		local slow = Mock.AddPlayer("GemSlowLoad" .. userSeq, slowId)
		players[#players + 1] = slow
		local boxS = spawnCall(cb, receipt(slow, pack, "smoke-slow-1"))
		advance(0.5)
		T.check(not boxS.done and profileOf(slow) == nil and DataS.GetGems(slow) == 0, "gem receipts: a purchase that arrives while the profile is still loading waits (nothing granted yet)")
		K.waitFor(function()
			return boxS.done
		end, 40)
		DSt.Latency = saved.Latency
		T.eq(boxS.result, GRANTED, "gem receipts: ...and is granted once the profile has loaded")
		T.eq(DataS.GetGems(slow), pack.Gems, "gem receipts: ...exactly once")
		T.eq(run(receipt(slow, pack, "smoke-slow-1")), GRANTED, "gem receipts: (retry of that purchase) PurchaseGranted...")
		T.eq(DataS.GetGems(slow), pack.Gems, "gem receipts: ...and nothing more")

		-- ...but only for ProfileWaitSeconds: then NotProcessedYet, and a later retry grants it once
		DSt.Latency = Gs.ProfileWaitSeconds + 6
		userSeq = userSeq + 1
		local lateId = 985000 + userSeq
		joinedIds[lateId] = true
		local late = Mock.AddPlayer("GemLateLoad" .. userSeq, lateId)
		players[#players + 1] = late
		local rLate = receipt(late, pack, "smoke-late-1")
		local boxL = spawnCall(cb, rLate)
		K.waitFor(function()
			return boxL.done
		end, Gs.ProfileWaitSeconds + 3)
		DSt.Latency = saved.Latency
		T.check(boxL.done and boxL.result == NOT_YET and profileOf(late) == nil, "gem receipts: a profile that is still not loaded after " .. Gs.ProfileWaitSeconds .. " s: NotProcessedYet",
			tostring(boxL.result))
		T.eq(DataS.GetGems(late), 0, "gem receipts: ...nothing granted (no receipt marked)")
		local loaded = K.waitFor(function()
			return profileOf(late) ~= nil
		end, 60)
		T.check(loaded, "gem receipts: (precondition) the slow profile loads in the end")
		T.eq(run(rLate), GRANTED, "gem receipts: Roblox's next call grants it...")
		T.eq(run(rLate), GRANTED, "gem receipts: ...(and a further one)...")
		T.eq(DataS.GetGems(late), pack.Gems, "gem receipts: ...exactly once")

		-- a provisional profile (the load failed during an outage): never decided from stand-in defaults
		DSt.Fail = true
		local prov = joinAs("GemOutage", nil, 4)
		players[#players + 1] = prov
		T.check(DataS.IsProvisional(prov) == true, "gem receipts: (precondition) a load during an outage leaves a provisional profile")
		local rProv = receipt(prov, pack, "smoke-outage-1")
		local boxP = spawnCall(cb, rProv)
		advance(3)
		T.check(not boxP.done, "gem receipts: a purchase for a provisional profile waits...")
		K.waitFor(function()
			return boxP.done
		end, Gs.ProfileWaitSeconds + 3)
		T.check(boxP.done and boxP.result == NOT_YET, "gem receipts: ...then answers NotProcessedYet", tostring(boxP.result))
		T.eq(DataS.GetGems(prov), 0, "gem receipts: ...without granting anything")
		DSt.Fail = saved.Fail
		local recovered = K.waitFor(function()
			return DataS.IsProvisional(prov) ~= true
		end, 60)
		T.check(recovered, "gem receipts: (precondition) the recovery reads the real save once the store is back")
		T.eq(run(rProv), GRANTED, "gem receipts: after the recovery the purchase is granted...")
		T.eq(run(rProv), GRANTED, "gem receipts: ...(a retry)...")
		T.eq(DataS.GetGems(prov), pack.Gems, "gem receipts: ...exactly once")

		-- a failed save: NotProcessedYet on a live server, the retry is granted without a second grant
		Mock.Options.Studio = false
		local fs = joinAs("GemSaveFail")
		players[#players + 1] = fs
		DSt.Fail = true
		local rF = receipt(fs, pack, "smoke-savefail-1")
		T.eq(run(rF), NOT_YET, "gem receipts: (live server) when the save fails the purchase answers NotProcessedYet...")
		T.eq(DataS.GetGems(fs), pack.Gems, "gem receipts: ...the Gems are in the session already (with the receipt, in the next save)")
		DSt.Fail = saved.Fail
		T.eq(run(rF), GRANTED, "gem receipts: Roblox's retry saves and answers PurchaseGranted...")
		T.eq(DataS.GetGems(fs), pack.Gems, "gem receipts: ...without granting it twice")
		local recF = stored(fs.UserId)
		T.check(type(recF) == "table" and recF.Gems == pack.Gems and type(recF.GemReceipts) == "table" and recF.GemReceipts["smoke-savefail-1"] ~= nil,
			"gem receipts: ...and the store now holds the receipt with the Gems")
		Mock.Options.Studio = true
		DSt.Fail = true
		T.eq(run(receipt(fs, pack, "smoke-savefail-2")), GRANTED, "gem receipts: in Studio a failed save still answers PurchaseGranted (test purchases cost nothing)")
		DSt.Fail = saved.Fail
		T.eq(DataS.GetGems(fs), 2 * pack.Gems, "gem receipts: ...granted once")
		Mock.Options.Studio = saved.Studio

		-- PromptPurchase: a validated request
		local calls = {}
		MPS.PromptProductPurchase = function(_, player, productId)
			calls[#calls + 1] = { Player = player, ProductId = productId }
		end
		local q = joinAs("GemPrompt")
		players[#players + 1] = q
		local ok1, why1 = Gs.PromptPurchase(q, 2)
		T.check(ok1 == true and #calls == 1 and calls[1].Player == q and calls[1].ProductId == pack.Id,
			"gem prompt: PromptPurchase(player, index) opens Roblox's purchase window for that pack's product id", tostring(why1))
		T.check(Gs.PromptPurchase(q, 2) == false and #calls == 1, "gem prompt: ...at most once a second per player")
		advance(1.1)
		T.check(Gs.PromptPurchase(q, big.Id) == true and #calls == 2 and calls[2].ProductId == big.Id, "gem prompt: a pack can also be named by its product id")
		advance(1.1)
		local ok4, why4 = Gs.PromptPurchase(q, 1)
		T.check(ok4 == false and #calls == 2 and tostring(why4):lower():find("not on sale", 1, true) ~= nil, "gem prompt: a pack whose product id is still 0 is never offered", tostring(why4))
		local opened = false
		for _, ref in ipairs({ 0, -1, 2.5, 99, "2", {}, true, 0 / 0, math.huge }) do
			advance(1.1)
			if Gs.PromptPurchase(q, ref) then
				opened = true
			end
		end
		T.check(not opened and #calls == 2, "gem prompt: junk references open nothing")
		T.check(Gs.PromptPurchase(nil, 2) == false and Gs.PromptPurchase("GemPrompt", 2) == false and Gs.PromptPurchase(workspace, 2) == false and #calls == 2,
			"gem prompt: ...nor does a request without a real player")
		q:SetAttribute(Config.Attr.InMatch, true)
		advance(1.1)
		T.check(Gs.PromptPurchase(q, 2) == false and #calls == 2, "gem prompt: no purchase window during a match")
		q:SetAttribute(Config.Attr.InMatch, false)
		MPS.PromptProductPurchase = function()
			error("smoke: the purchase window failed")
		end
		advance(1.1)
		local okE, whyE = Gs.PromptPurchase(q, 2)
		T.check(okE == false and type(whyE) == "string", "gem prompt: a failing purchase window is reported, not raised", tostring(whyE))
		T.eq(DataS.GetGems(q), 0, "gem prompt: prompting never grants Gems (only ProcessReceipt does)")
	end)

	-- restore everything this scenario changed
	conn:Disconnect()
	for i, p in ipairs(G.Products) do
		p.Id = saved.Ids[i]
	end
	Mock.Options.Studio = saved.Studio
	DSt.Fail, DSt.Latency = saved.Fail, saved.Latency
	removeDoubles()
	leaveAll(players)
	if not okRun then
		error(errRun, 0)
	end
	K.flushErrors("p2gems_receipts")
	K.flushWarnings("p2gems_receipts", ALLOWED_WARNINGS)
end)

----------------------------------------------------------------------------------------------------
-- p2gems_policy (booted)
----------------------------------------------------------------------------------------------------
S.p2gems_policy = guarded("p2gems_policy", function()
	if not K.needBoot() then
		return
	end
	local Gs, DataS, PetS, Config = GS(), DS(), PS(), K.config()
	if not T.check(type(Gs) == "table", "gem policy: GemService loads") then
		return
	end
	local players = {}
	local okRun, errRun = pcall(function()
		installPolicy("allow")
		local allowed = joinAs("GemAllowed", "allow")
		local restricted = joinAs("GemRestricted", "restrict")
		local failing = joinAs("GemPolicyDown", "error")
		local odd = joinAs("GemPolicyOdd", "nofield")
		players = { allowed, restricted, failing, odd }
		T.eq(Gs.PolicyState(allowed), "Allowed", "gem policy: ArePaidRandomItemsRestricted = false -> Allowed")
		T.eq(allowed:GetAttribute(ATTR), false, "gem policy: ...player attribute " .. ATTR .. " = false (the Shop may show gem roulettes)")
		T.eq(Gs.PolicyState(restricted), "Restricted", "gem policy: ArePaidRandomItemsRestricted = true -> Restricted")
		T.eq(restricted:GetAttribute(ATTR), true, "gem policy: ...attribute " .. ATTR .. " = true (the Shop hides them)")
		T.eq(Gs.PolicyState(failing), "Checking", "gem policy: a failing lookup (pcall) leaves the account unchecked")
		T.eq(failing:GetAttribute(ATTR), true, "gem policy: ...which counts as restricted")
		T.eq(Gs.PolicyState(odd), "Restricted", "gem policy: an answer without ArePaidRandomItemsRestricted counts as restricted")
		T.check(Gs.IsRestricted(restricted) and Gs.IsRestricted(failing) and Gs.IsRestricted(odd) and not Gs.IsRestricted(allowed), "gem policy: IsRestricted agrees")

		for _, p in ipairs({ restricted, failing, odd }) do
			setGems(p, 5000)
			setTokens(p, 1000)
		end
		local tally = T.tally("gem policy: restricted / unchecked accounts cannot roll with Gems (BuyRoulette with Gems or the Secret roulette, GemService.Roll / Quote): refused, nothing charged")
		for _, p in ipairs({ restricted, failing, odd }) do
			for _, call in ipairs({ { "Cloud", "Gems" }, { "Celestial", "gems" }, { secretId() }, { secretId(), "Gems" }, { "Sky", { Currency = "Gems" } } }) do
				local before = wallet(p)
				local ok, why = PetS.BuyRoulette(p, call[1], call[2])
				local said = type(why) == "table" and ("rolled " .. tostring(why.PetId)) or tostring(why)
				tally:case(ok == false and type(why) == "string" and sameWallet(before, wallet(p)), p.Name .. " " .. tostring(call[1]) .. ": " .. said)
			end
			local before = wallet(p)
			local okQ = Gs.Quote(p, "Cloud")
			local okR = Gs.Roll(p, secretId())
			tally:case(okQ == false and okR == false and sameWallet(before, wallet(p)), p.Name .. " Quote / Roll")
		end
		tally:report()
		local _, whyR = PetS.BuyRoulette(restricted, "Cloud", "Gems")
		T.check(tostring(whyR):lower():find("not available", 1, true) ~= nil, "gem policy: ...a restricted account is told gem roulettes are not available there", tostring(whyR))
		local _, whyF = PetS.BuyRoulette(failing, "Cloud", "Gems")
		T.check(tostring(whyF):lower():find("try again", 1, true) ~= nil, "gem policy: ...an unchecked one to try again in a moment", tostring(whyF))

		local R = remote("BuyRoulette")
		advance(0.4)
		local mark = K.logSize()
		Mock.FromClient(R, restricted, secretId())
		advance(0.1)
		local ans = K.lastRemote("RouletteResult", restricted.UserId, mark)
		local a1 = ans and ans.args[1]
		T.check(type(a1) == "table" and a1.Ok == false and type(a1.Reason) == "string" and a1.Currency == "Gems" and a1.Gems == 5000,
			"gem policy: the BuyRoulette remote answers a refused Secret spin with RouletteResult(Ok = false, Reason, Currency = Gems, Gems)")
		T.eq(DataS.GetGems(restricted), 5000, "gem policy: ...and charges nothing")

		local cloud = Config.Roulettes[1]
		local okTok = PetS.BuyRoulette(restricted, cloud.Id)
		T.check(okTok == true and DataS.GetTokens(restricted) == 1000 - cloud.Price and DataS.GetGems(restricted) == 5000,
			"gem policy: token roulettes stay open to a restricted account (Cloud Tokens are earned, not bought)")

		-- the failing lookup is retried with a backoff, then the account is allowed
		policyModes[failing.UserId] = "allow"
		local recovered = K.waitFor(function()
			return Gs.PolicyState(failing) == "Allowed"
		end, 20)
		T.check(recovered and failing:GetAttribute(ATTR) == false, "gem policy: a failed lookup is retried and then allows the account (attribute false)")
		local price = gemPrice(cloud.Id)
		local okAfter = PetS.BuyRoulette(failing, cloud.Id, "Gems")
		T.check(okAfter == true and price ~= nil and DataS.GetGems(failing) == 5000 - price, "gem policy: ...which can roll with Gems now")

		-- a lookup that is still running
		local slow = joinAs("GemPolicySlow", "slow", 0.5)
		players[#players + 1] = slow
		setGems(slow, 100)
		T.eq(Gs.PolicyState(slow), "Checking", "gem policy: while the lookup runs the account is unchecked")
		local okSlow = PetS.BuyRoulette(slow, cloud.Id, "Gems")
		T.check(okSlow == false and DataS.GetGems(slow) == 100, "gem policy: ...and cannot roll with Gems yet")
		K.waitFor(function()
			return Gs.PolicyState(slow) == "Allowed"
		end, 10)
		T.eq(Gs.PolicyState(slow), "Allowed", "gem policy: ...until the answer arrives")

		-- no PolicyService answer at all: never allowed
		removeDoubles()
		local blind = joinAs("GemPolicyBlind", nil)
		players[#players + 1] = blind
		advance(5)
		T.check(Gs.PolicyState(blind) ~= "Allowed" and blind:GetAttribute(ATTR) == true, "gem policy: without any PolicyService answer nobody is allowed (fails closed)")
		T.check(Gs.PolicyState(nil) ~= "Allowed" and Gs.IsRestricted("someone") == true and Gs.IsRestricted(workspace) == true, "gem policy: non-players are never allowed")
	end)
	removeDoubles()
	leaveAll(players)
	if not okRun then
		error(errRun, 0)
	end
	K.flushErrors("p2gems_policy")
	K.flushWarnings("p2gems_policy", ALLOWED_WARNINGS)
end)

----------------------------------------------------------------------------------------------------
-- p2gems_roulettes (booted)
----------------------------------------------------------------------------------------------------
S.p2gems_roulettes = guarded("p2gems_roulettes", function()
	if not K.needBoot() then
		return
	end
	local Gs, DataS, PetS, Pc, Config = GS(), DS(), PS(), PC(), K.config()
	if not T.check(type(Gs) == "table", "gem roulettes: GemService loads") then
		return
	end
	local players = {}
	local originalGemRoll, originalCatRoll = Gs.RollPet, Pc.RollPet
	local originalSecretOdds = Config.Gems.SecretRoulette.Odds
	local okRun, errRun = pcall(function()
		installPolicy("allow")
		local p = joinAs("GemRoller", "allow")
		players[#players + 1] = p
		T.eq(Gs.PolicyState(p), "Allowed", "gem roulettes: (precondition) the roller's account may buy random items")
		local prof = profileOf(p)
		setTokens(p, 0)

		-- the forced Secret pull first, so it is the player's first pet (auto-equipped)
		local sId, sPrice = secretId(), Config.Gems.SecretRoulette.GemPrice
		setGems(p, sPrice + 10)
		Gs.RollPet = function()
			return STORMFANG
		end
		local mark = K.logSize()
		local okS, resS = PetS.BuyRoulette(p, sId)
		Gs.RollPet = originalGemRoll
		T.check(okS == true, "gem roulettes: the Secret roulette needs no currency argument (gems only)", tostring(type(resS) == "table" and resS.Reason or resS))
		T.eq(DataS.GetGems(p), 10, "gem roulettes: ...and charges exactly its " .. tostring(sPrice) .. " Gems")
		T.eq(prof.Pets[STORMFANG], 1, "gem roulettes: a Secret pull grants the pet (forced: Stormfang)")
		if type(resS) == "table" then
			local problems = resultProblems(resS, sId)
			T.check(#problems == 0, "gem roulettes: ...RouletteResult has the documented shape (strip from the Secret pool, won pet at " .. WIN_INDEX .. ")", table.concat(problems, ", "))
			T.check(resS.IsNew == true and resS.NewDiscovery == true and resS.Currency == "Gems" and resS.Price == sPrice and resS.Gems == 10 and resS.Tokens == 0,
				"gem roulettes: ...IsNew, NewDiscovery, Currency = Gems, Price, the Gems balance")
		end
		T.check(type(DataS.IsDiscovered) ~= "function" or DataS.IsDiscovered(p, STORMFANG) == true, "gem roulettes: ...the Secret pet is discovered in the Pet Index")
		T.eq(prof.Equipped[1], STORMFANG, "gem roulettes: ...and, as the very first pet, equipped")
		local sent = K.lastRemote("RouletteResult", p.UserId, mark)
		T.check(sent ~= nil and type(sent.args[1]) == "table" and sent.args[1].PetId == STORMFANG and sent.args[1].RouletteId == sId, "gem roulettes: ...RouletteResult is fired to the buyer")

		-- every priced token roulette
		setGems(p, 20000)
		local cases = T.tally("gem roulettes: every token roulette with a gem price charges exactly that many Gems (no tokens), grants one non-Secret pet of its pool, answers Currency / Price / Gems")
		for _, r in ipairs(Config.Roulettes) do
			local price = gemPrice(r.Id)
			if price then
				advance(0.3)
				local before = wallet(p)
				local okR, res = PetS.BuyRoulette(p, r.Id, "Gems")
				local after = wallet(p)
				local problems = resultProblems(res, r.Id)
				local good = okR == true and #problems == 0 and after.Gems == before.Gems - price and after.Tokens == before.Tokens and after.Pets == before.Pets + 1
					and after.Spins == before.Spins + 1 and res.Currency == "Gems" and res.Price == price and res.Gems == after.Gems and not isSecretPet(res.PetId)
				cases:case(good, r.Id .. ": " .. table.concat(problems, ", ") .. " gems " .. before.Gems .. " -> " .. after.Gems)
			end
		end
		cases:report()

		-- refusals that cost nothing
		setGems(p, 1)
		local before = wallet(p)
		local okPoor, whyPoor = PetS.BuyRoulette(p, "Sky", "Gems")
		T.check(okPoor == false and tostring(whyPoor):lower():find("gems", 1, true) ~= nil and sameWallet(before, wallet(p)), "gem roulettes: not enough Gems: refused, nothing charged", tostring(whyPoor))
		setGems(p, 5000)
		setTokens(p, 100000)
		before = wallet(p)
		local okTok, whyTok = PetS.BuyRoulette(p, sId, "Tokens")
		T.check(okTok == false and tostring(whyTok):lower():find("gems only", 1, true) ~= nil and sameWallet(before, wallet(p)), "gem roulettes: the Secret roulette takes Gems only (Cloud Tokens refused)", tostring(whyTok))
		local junkTally = T.tally("gem roulettes: junk currencies are refused ('Unknown currency'), nothing charged")
		for _, cur in ipairs({ "Robux", 5, true, { Currency = "Diamonds" }, string.rep("g", 40), "" }) do
			local b = wallet(p)
			local okJ, whyJ = PetS.BuyRoulette(p, "Cloud", cur)
			junkTally:case(okJ == false and tostring(whyJ):lower():find("currency", 1, true) ~= nil and sameWallet(b, wallet(p)), tostring(cur) .. ": " .. tostring(whyJ))
		end
		junkTally:report()
		p:SetAttribute(Config.Attr.InMatch, true)
		before = wallet(p)
		local okMatch = PetS.BuyRoulette(p, sId)
		local okMatch2 = PetS.BuyRoulette(p, "Cloud", "Gems")
		p:SetAttribute(Config.Attr.InMatch, false)
		T.check(okMatch == false and okMatch2 == false and sameWallet(before, wallet(p)), "gem roulettes: no gem spins during a match")
		setTokens(p, 0)

		-- real Secret pulls: Mythic or Secret pets of the Secret pool
		setGems(p, 3 * sPrice)
		local pulls = T.tally("gem roulettes: 3 real Secret pulls give Mythic / Secret pets of the Secret pool (strip from that pool) for " .. tostring(sPrice) .. " Gems each")
		for i = 1, 3 do
			advance(0.3)
			local g = DataS.GetGems(p)
			local okP, res = PetS.BuyRoulette(p, sId, "Gems")
			local problems = resultProblems(res, sId)
			local def = type(res) == "table" and Pc.Get(res.PetId)
			pulls:case(okP == true and #problems == 0 and def ~= nil and (def.Rarity == "Mythic" or def.Rarity == SECRET) and DataS.GetGems(p) == g - sPrice,
				"pull " .. i .. ": " .. table.concat(problems, ", ") .. " " .. tostring(def and def.Rarity))
		end
		pulls:report()

		-- a Secret result of a token roulette is refused whatever paid for it
		local secretPet = Pc.ListByRarity(SECRET)[1].Id
		local ownedSecret = prof.Pets[secretPet] or 0
		Pc.RollPet = function()
			return secretPet
		end
		setGems(p, 1000)
		setTokens(p, 1000)
		before = wallet(p)
		local okG1 = PetS.BuyRoulette(p, "Cloud", "Gems")
		advance(0.3)
		local okG2 = PetS.BuyRoulette(p, "Cloud")
		Pc.RollPet = originalCatRoll
		T.check(okG1 == false and okG2 == false and sameWallet(before, wallet(p)) and (prof.Pets[secretPet] or 0) == ownedSecret,
			"gem roulettes: Secret pets only from the Secret roulette: a token roulette whose roll came out Secret is refused (Gems or Cloud Tokens), nothing charged")

		-- odds are always shown: a roulette whose odds cannot be listed is not sold, and the altar does not offer it
		local sr = Config.Gems.SecretRoulette
		local savedOdds = sr.Odds
		sr.Odds = {}
		setGems(p, 5000)
		before = wallet(p)
		local okNoOdds = PetS.BuyRoulette(p, sId)
		local altarState = Gs.SecretRouletteState(p)
		sr.Odds = savedOdds
		T.check(okNoOdds == false and sameWallet(before, wallet(p)) and altarState == "Unavailable",
			"gem roulettes: a roulette whose odds cannot be shown is not sold (nothing charged) and the Storm Altar does not offer it", tostring(altarState))
		T.eq(Gs.SecretRouletteState(p), "Open", "gem roulettes: ...with its odds back the Secret roulette is open again")

		-- a gem pull into a full stack costs nothing
		local common = Pc.ListByRarity("Common")[1].Id
		local savedCount = prof.Pets[common]
		prof.Pets[common] = Config.Pets.MaxPerStack
		Pc.RollPet = function()
			return common
		end
		before = DataS.GetGems(p)
		local okCap = PetS.BuyRoulette(p, "Cloud", "Gems")
		Pc.RollPet = originalCatRoll
		prof.Pets[common] = savedCount
		DataS.MarkDirty(p)
		T.check(okCap == false and DataS.GetGems(p) == before, "gem roulettes: a gem pull into a full stack (" .. Config.Pets.MaxPerStack .. ") is refused and costs nothing")

		-- the remote: the currency is its 2nd argument, rate limited, junk answered without errors
		local cloudPrice = gemPrice("Cloud")
		setGems(p, 100)
		setTokens(p, 0)
		local R = remote("BuyRoulette")
		advance(0.5)
		mark = K.logSize()
		Mock.FromClient(R, p, "Cloud", "Gems")
		Mock.FromClient(R, p, "Cloud", "Gems")
		advance(0.1)
		T.eq(DataS.GetGems(p), 100 - cloudPrice, "gem roulettes: the BuyRoulette remote takes the currency as its 2nd argument (rate limited: two calls in 0.25 s charge once)")
		local answer = K.lastRemote("RouletteResult", p.UserId, mark)
		T.check(answer and type(answer.args[1]) == "table" and answer.args[1].Ok == true and answer.args[1].Currency == "Gems", "gem roulettes: ...answered with RouletteResult(Ok, Currency = Gems)")
		local errs = #Mock.Errors
		before = wallet(p)
		for _, junk in ipairs({ 5, true, {}, string.rep("x", 300), "Robux" }) do
			advance(0.3)
			Mock.FromClient(R, p, "Cloud", junk)
			advance(0.3)
			Mock.FromClient(R, p, sId, junk)
		end
		advance(0.3)
		T.check(#Mock.Errors == errs and sameWallet(before, wallet(p)), "gem roulettes: junk currencies through the remote raise nothing and cost nothing")
		advance(0.3)
		local okRoll, resRoll = Gs.Roll(p, "Cloud")
		T.check(okRoll == true and type(resRoll) == "table" and resRoll.Currency == "Gems" and DataS.GetGems(p) == before.Gems - cloudPrice, "gem roulettes: GemService.Roll(player, id) is a gem-paid spin")
		local removed = forgetSecretSpins()
		if removed > 0 then
			T.info("*gem roulettes: " .. removed .. " Secret RouletteResults checked here and taken out of the shared logs (PetCatalog does not list the Secret roulette)")
		end
	end)
	Gs.RollPet = originalGemRoll
	Pc.RollPet = originalCatRoll
	Config.Gems.SecretRoulette.Odds = originalSecretOdds
	removeDoubles()
	leaveAll(players)
	forgetSecretSpins()
	if not okRun then
		error(errRun, 0)
	end
	K.flushErrors("p2gems_roulettes")
	K.flushWarnings("p2gems_roulettes", ALLOWED_WARNINGS)
end)

----------------------------------------------------------------------------------------------------
-- p2gems_altar (booted)
----------------------------------------------------------------------------------------------------
S.p2gems_altar = guarded("p2gems_altar", function()
	if not K.needBoot() then
		return
	end
	local prompt = nil
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "StormAltarPrompt" then
			prompt = d
		end
	end
	if not T.check(prompt ~= nil, "gem altar: the Storm Altar has its prompt (StormAltarPrompt)") then
		return
	end
	T.check(prompt.ObjectText == "Storm Altar" and prompt.ActionText == "Summon" and prompt.HoldDuration <= 0.5 and prompt.Enabled ~= false,
		"gem altar: the prompt reads 'Summon' / 'Storm Altar' and is quick to use", tostring(prompt.ActionText))
	local players = {}
	local okRun, errRun = pcall(function()
		installPolicy("allow")
		local a = joinAs("AltarAllowed", "allow")
		local b = joinAs("AltarRestricted", "restrict")
		local c = joinAs("AltarChecking", "error")
		players = { a, b, c }
		local function opens(p, mark)
			local out = {}
			for _, e in ipairs(K.remotesFor("OpenPanel", p.UserId, mark)) do
				local args = e.args[2]
				if e.args[1] == "Shop" and type(args) == "table" and args.RouletteId == secretId() then
					out[#out + 1] = e
				end
			end
			return out
		end
		local function toasts(p, mark, needle)
			local out = {}
			for _, e in ipairs(K.remotesFor("Notify", p.UserId, mark)) do
				if tostring(e.args[1]):lower():find(needle, 1, true) then
					out[#out + 1] = e
				end
			end
			return out
		end
		local mark = K.logSize()
		Mock.Trigger(prompt, a)
		advance(0.1)
		local first = opens(a, mark)
		T.check(#first == 1 and first[1].kind ~= "all", "gem altar: an allowed account's Summon opens the Shop on the Secret roulette (OpenPanel to that player only)", #first .. " OpenPanel")
		T.eq(#opens(b, mark) + #opens(c, mark), 0, "gem altar: ...nobody else's Shop opens")
		T.eq(#toasts(a, mark, "awakens soon"), 0, "gem altar: ...and no 'awakens soon' toast any more")
		Mock.Trigger(prompt, a)
		advance(0.1)
		T.eq(#opens(a, mark), 1, "gem altar: ...rate-limited per player")
		advance(0.6)
		Mock.Trigger(prompt, a)
		advance(0.1)
		T.eq(#opens(a, mark), 2, "gem altar: ...and it opens again a moment later")

		Mock.Trigger(prompt, b)
		advance(0.1)
		local denied = toasts(b, mark, "not available")
		local sideKinds = { info = true, good = true, bad = true, token = true }
		T.check(#denied == 1 and sideKinds[denied[1].args[2]] == true and denied[1].kind ~= "all" and #opens(b, mark) == 0,
			"gem altar: a restricted account gets a side toast that the Secret Roulette is not available there (no Shop)")

		Mock.Trigger(prompt, c)
		advance(0.1)
		T.check(#toasts(c, mark, "awakens soon") == 1 and #opens(c, mark) == 0, "gem altar: while the account is still being checked the phase 1 'awakens soon' toast is sent (no Shop)")

		advance(3.5) -- past every per-player cooldown
		local mark2 = K.logSize()
		local errorsBefore = #Mock.Errors
		Mock.FireSignal(prompt, "Triggered", nil)
		Mock.FireSignal(prompt, "Triggered", a.Name)
		Mock.FireSignal(prompt, "Triggered", workspace)
		advance(0.3)
		local stray = 0
		for _, p in ipairs({ a, b, c }) do
			stray = stray + #K.remotesFor("OpenPanel", p.UserId, mark2) + #K.remotesFor("Notify", p.UserId, mark2)
		end
		local broadcast = 0
		for _, e in ipairs(K.remotesFor("OpenPanel", nil, mark2)) do
			if e.kind == "all" then
				broadcast = broadcast + 1
			end
		end
		T.check(stray == 0 and broadcast == 0 and #Mock.Errors == errorsBefore, "gem altar: forged prompt triggers (nil, a string, a non-player) do nothing and raise nothing",
			stray .. " messages, " .. (#Mock.Errors - errorsBefore) .. " errors")
	end)
	removeDoubles()
	leaveAll(players)
	if not okRun then
		error(errRun, 0)
	end
	K.flushErrors("p2gems_altar")
	K.flushWarnings("p2gems_altar", ALLOWED_WARNINGS)
end)

return S
