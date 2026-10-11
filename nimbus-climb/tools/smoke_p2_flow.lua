-- smoke_p2_flow.lua: the END-TO-END Phase 2 flow (ARCHITECTURE_V3.md "Phase 2: Tycoon homes" + "Phase 2 build
-- contract"): three simulated players play the tycoon homes together on the booted game, through the same doors a
-- client uses (ProximityPrompts, the HomeAction / PetCare / Fusion / BuyRoulette / TutorialEvent / EquipPet remotes,
-- the Collector pad, MarketplaceService.ProcessReceipt) while TycoonService, PetCareService, FusionService,
-- GemService, TutorialService, SpotService, HomeBuilder, PetService and DataService all run at once. Cash for the big
-- purchases comes from DataService.AddCash (a stand-in for hours of Collector income, like tools/sim_tycoon.py).
-- Loaded by tools/smoke.py in the SERVER world; the scenarios are chapters of ONE story and run in order (before the
-- care block: p2care_exploits leaves a dish cooking for p2care_shutdown):
--   p2flow_arrive        Ann (new), Ben (new, an account where paid random items are restricted) and Cid (a v3 /
--                        Phase 1 save: Home.Rooms reserve, finished basics, an old SpotIndex) join: nobody gets a
--                        plot, Cash / Gems attributes, the policy state, the join toasts ("Pick a free home" /
--                        "Welcome back! Press E at your gate (#n)"), Cid's migrated profile + ProfileSync and his
--                        tutorial resuming at the home chapter. Cid claims his old plot ('claim' -> 'press'). Ann
--                        plays the whole basics chapter: Next, the 'home' arrow to a free gate, GoToSpot, E at the
--                        gate, a lobby respawn at her home, the Shop, the gift spin (a forced Economy pet,
--                        auto-equipped), Pets, the Index, a real Easy match (claiming her plot meanwhile is refused),
--                        'done' pays the basics reward and the home chapter's 'claim' completes at once (she already
--                        has a home) -> 'press' points at her Press 1 pad. Ben skips the tutorial, claims a plot and
--                        can neither claim Ann's plot nor use her pads.
--   p2flow_build         Ann's home chapter + the care stations, with Ben building next door: the free Press 1 and
--                        Collector pads, both Collectors fill at the same time, Ben cannot bank Ann's Collector,
--                        stepping on it banks it ('collect' -> 'kitchen'); following the 'kitchen' arrow pad by pad
--                        (every pad on the way bought with E), the Garden on the way (an Economy pet placed with
--                        HomeAction GardenSet earns), E at the Kitchen counter cooks a Snack (Ben's E on it does
--                        nothing), feeding the pet through the PetCare remote levels it up and ends the home chapter
--                        (Cash reward once; the garden income follows the level); the Gym: role checks both ways, a
--                        Combat pet trains through PetCare GymSet and levels up from the Gym alone. Cid builds his
--                        Press 1 from the Home window (HomeAction Upgrade) and leaves: his save is a Phase 2 profile.
--   p2flow_prestige      Ann builds the home up pad by pad: the next house is refused below its Home Level (toast,
--                        nothing paid), Villa / Manor / Sky Castle at Home Level 10 / 20 / 30 (toasts), station caps per
--                        tier, until the Prestige pad unlocks; E on it: +1 star, the Gems reward, Cash 0, stations reset
--                        but decor, garden and gym choices kept (they stop earning / training until rebuilt), the plot
--                        and the nameplate follow. DataStore merge after the prestige: a stale server's late prestige-0
--                        write (an extra station level, +Cash, +Gems, +Snacks) lands before this server saves: the
--                        prestiged Home wins whole, the deltas add up, the live profile adopts the merged numbers.
--   p2flow_fusion_gems   After the prestige: rebuilding the way to the Fusion Machine, its pad unlocks, the garden pet
--                        earns x1.25; three copies (one working in the Garden, one equipped) fuse through the Fusion
--                        remote only next to the machine: the Golden copy takes over the garden slot and the
--                        equipped place and keeps the level; gem packs through ProcessReceipt (granted once, saved
--                        with the receipt, a retry grants nothing, a pack that is not created stays pending); the Storm
--                        Altar opens the Shop on the Secret roulette for Ann (a side toast for Ben); a gem spin of the
--                        Secret roulette (Mythic / Secret pet, discovered; refused for Ben, nothing charged); mixing that
--                        pet with the training Combat pet costs Gems and makes a hybrid record.
--   p2flow_rejoin        Ann leaves with two Snacks cooking (refunded into the leave save) and her plot is cleared;
--                        Cid rejoins ("Welcome back") and claims Ann's old plot (his Phase 2 build comes back there);
--                        Ann rejoins ("Pick a free home": her last plot is taken), every saved number is back, she claims
--                        another plot and the whole build is restored there (stations at their levels, the prestige
--                        star, GardenPets / GymPets, the Kitchen's cook prompts, income), an old gem receipt is still
--                        known. DataStore merge the other way: Ben's previous server lands a late Prestige-1 Home while
--                        he plays at Prestige 0 here: his session's station edit is void, his live Home and the plot in
--                        the world follow (stations, star, Prestige attribute, the Fusion Machine requirement).
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local K = _G.K
local CONTEXT = (ARGS and ARGS.context) or "server"

local S = {}
if CONTEXT ~= "server" then
	return S
end

local abs, floor, max, min = math.abs, math.floor, math.max, math.min
local advance, config, mod = K.advance, K.config, K.mod
local STAR = "\226\152\133"
local SECRET = "Secret"
local ALLOWED_WARNINGS = { "[DataService]", "[GemService]", "HomeBuilder is missing" }

-- the story's shared state (the scenarios are chapters of one flow)
local F = {
	ids = { Ann = 988001, Ben = 988002, Cid = 988003 },
	p = {}, -- name -> Player
	plot = {}, -- name -> plot index
	policy = {}, -- userId -> "allow" | "restrict"
}

----------------------------------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------------------------------
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

local function svc()
	return {
		Ty = requireAt("server/Services/TycoonService"),
		Care = requireAt("server/Services/PetCareService"),
		Fuse = requireAt("server/Services/FusionService"),
		Gems = requireAt("server/Services/GemService"),
		HB = requireAt("server/Services/HomeBuilder"),
		TSv = mod("TutorialService"),
		DataS = mod("DataService"),
		PetS = mod("PetService"),
		SS = mod("SpotService"),
		MS = mod("MatchService"),
		TC = requireAt("shared/TycoonCatalog"),
		PK = requireAt("shared/PetKeys"),
		PC = K.M["shared/PetCatalog"],
		Steps = requireAt("shared/TutorialSteps"),
	}
end

local function remote(name)
	return K.remoteFolder():FindFirstChild(name)
end

local function storeKey(userId)
	return config().Tokens.DataStoreName .. "/u_" .. userId
end

local function stored(userId)
	return Mock.DataStore.Data[storeKey(userId)]
end

local function spots()
	return (K.W.lobbyInfo and K.W.lobbyInfo.Spots) or {}
end

local function countKeys(map)
	local n = 0
	for _ in pairs(type(map) == "table" and map or {}) do
		n = n + 1
	end
	return n
end

local function mapText(map)
	local parts = {}
	for k, v in pairs(type(map) == "table" and map or {}) do
		parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function sameMap(a, b)
	return mapText(a) == mapText(b)
end

-- side toasts (Notify) to a player since `mark` whose text contains `needle` (plain text)
local function toasts(p, needle, mark, kind)
	local out = {}
	for _, e in ipairs(K.remotesFor("Notify", p.UserId, mark or 0)) do
		local text = tostring(e.args[1])
		if text:find(needle, 1, true) and (kind == nil or e.args[2] == kind) then
			out[#out + 1] = text
		end
	end
	return out
end

local function toasted(p, needle, mark, kind)
	return #toasts(p, needle, mark, kind) > 0
end

local function lastSnapshot(p, mark)
	local list = K.remotesFor("ProfileSync", p.UserId, mark or 0)
	local e = list[#list]
	return e and e.args[1] or nil
end

local function cash(p)
	return mod("DataService").GetCash(p)
end

local function gems(p)
	return mod("DataService").GetGems(p)
end

local function tokens(p)
	return mod("DataService").GetTokens(p)
end

local function home(p)
	local Ty = requireAt("server/Services/TycoonService")
	return Ty and Ty.GetHome(p) or nil
end

local function level(p, id)
	local h = home(p)
	return (h and h.Stations and h.Stations[id]) or 0
end

-- tops the balance up to `amount` (a stand-in for the Collector income of the time it takes)
local function fund(p, amount)
	local have = cash(p)
	if amount > have then
		mod("DataService").AddCash(p, amount - have)
	end
end

local function join(name, wait)
	local p = Mock.AddPlayer(name, F.ids[name])
	advance(wait or 1.0)
	F.p[name] = p
	return p
end

local function leave(p)
	if p and p.Parent then
		Mock.RemovePlayer(p)
	end
	advance(0.8)
end

-- runs fn() while PetCatalog.RollPet always answers `petId` (the roulettes read the field at call time; remote
-- handlers run right away in the mock, so a remote call inside fn rolls the forced pet)
local function withRoll(petId, fn)
	local PC = K.M["shared/PetCatalog"]
	local original = PC.RollPet
	PC.RollPet = function()
		return petId
	end
	local ok, err = pcall(fn)
	PC.RollPet = original
	if not ok then
		error(err, 0)
	end
end

-- a Common Economy and a Common Combat pet of the Cloud Roulette's pool
local function petsByRole(PC)
	local eco, combat = nil, nil
	for _, def in ipairs(PC.ListByRarity("Common")) do
		if def.Role == "Economy" and not eco then
			eco = def
		elseif def.Role == "Combat" and not combat then
			combat = def
		end
	end
	return eco, combat
end

-- PolicyService double (the mock has no GetPolicyInfoForPlayerAsync): installed only while the players join
local PolS = game:GetService("PolicyService")
local MPS = game:GetService("MarketplaceService")
local function installPolicy()
	PolS.GetPolicyInfoForPlayerAsync = function(_, player)
		local mode = F.policy[player.UserId] or "allow"
		return { ArePaidRandomItemsRestricted = mode == "restrict", IsPaidItemTradingAllowed = true }
	end
end
local function removePolicy()
	PolS.GetPolicyInfoForPlayerAsync = nil
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

----------------------------------------------------------------------------------------------------
-- plots, prompts, pads
----------------------------------------------------------------------------------------------------
local function attrUp(inst, name, depth)
	local node = inst
	for _ = 1, depth or 6 do
		if typeof(node) ~= "Instance" or node == workspace then
			return nil
		end
		local v = node:GetAttribute(name)
		if v ~= nil then
			return v
		end
		node = node.Parent
	end
	return nil
end

local function promptPosition(prompt)
	local parent = prompt and prompt.Parent
	if typeof(parent) ~= "Instance" then
		return nil
	end
	if parent:IsA("BasePart") then
		return parent.Position
	end
	if parent:IsA("Attachment") then
		return parent.WorldPosition
	end
	return nil
end

local function claimPromptOf(index)
	local info = spots()[index]
	if info and info.Folder then
		for _, d in ipairs(info.Folder:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.Name == "ClaimPrompt" then
				return d
			end
		end
	end
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "ClaimPrompt" and d:GetAttribute("SpotIndex") == index then
			return d
		end
	end
	return nil
end

-- walks to the gate (just outside it) and presses E on its ClaimPrompt
local function claim(p, index)
	local SS = mod("SpotService")
	local gate = SS.GateCFrame(spots()[index])
	if gate and p.Character then
		Mock.Teleport(p, gate * CFrame.new(0, 3, -5))
	end
	local prompt = claimPromptOf(index)
	if prompt then
		Mock.Trigger(prompt, p)
	end
	advance(0.6)
	return prompt ~= nil
end

local function freePlots(skip)
	local SS = mod("SpotService")
	local out = {}
	for i = 1, config().Lobby.SpotCount do
		if spots()[i] and not SS.GetOwner(i) and not (skip and skip[i]) then
			out[#out + 1] = i
		end
	end
	return out
end

-- the BuyPrompt of a station's pad on a plot (HomeBuilder's pads: the StationId attribute up the chain)
local function buyPrompt(info, id)
	if not info or not info.Folder then
		return nil
	end
	for _, d in ipairs(info.Folder:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "BuyPrompt" and attrUp(d, "StationId") == id then
			return d
		end
	end
	return nil
end

-- walks onto the pad and presses E (the prompt's cooldown is 0.2 s; one press per call)
local function pressPad(p, info, id)
	local prompt = buyPrompt(info, id)
	if not prompt then
		return false
	end
	local at = promptPosition(prompt)
	if at then
		Mock.Teleport(p, CFrame.new(at + Vector3.new(0, 3, 0)))
	end
	Mock.Trigger(prompt, p)
	advance(0.3)
	return true
end

local function stationModel(info, id)
	if not info or not info.Folder then
		return nil
	end
	for _, d in ipairs(info.Folder:GetDescendants()) do
		if d.Name == "Station_" .. id then
			return d
		end
	end
	return nil
end

local function stationIds(info)
	local out = {}
	if info and info.Folder then
		for _, d in ipairs(info.Folder:GetDescendants()) do
			local id = d.Name:match("^Station_(.+)$")
			if id then
				out[#out + 1] = id
			end
		end
	end
	table.sort(out)
	return out
end

local function pivotOf(model)
	if not model then
		return nil
	end
	if model:IsA("BasePart") then
		return model.CFrame
	end
	local ok, cf = pcall(function()
		return model:GetPivot()
	end)
	if ok then
		return cf
	end
	return nil
end

local function padPosition(info, id)
	local HB = requireAt("server/Services/HomeBuilder")
	local model = HB and HB.GetPad and HB.GetPad(info, id) or nil
	local cf = pivotOf(model)
	if cf then
		return cf.Position
	end
	local TC = requireAt("shared/TycoonCatalog")
	local def = TC and TC.Get(id)
	if def and def.Slot and def.Slot.Pad and info.PlotCFrame then
		return (info.PlotCFrame * def.Slot.Pad).Position
	end
	return nil
end

local function cookPrompt(info, foodId)
	if not info or not info.Folder then
		return nil
	end
	for _, d in ipairs(info.Folder:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "CookPrompt" and d:GetAttribute("FoodId") == foodId then
			return d
		end
	end
	return nil
end

local function collectPad(info)
	local st = stationModel(info, "Collector")
	return st and st:FindFirstChild("CollectPad", true) or nil
end

-- the cheapest unlocked, affordable-with-funding pad of a home (not the Prestige pad)
local function cheapestPad(TC, h)
	local best = nil
	for _, pad in ipairs(TC.AvailablePads(h)) do
		if not pad.Prestige and pad.Locked == nil and (not best or pad.Price < best.Price) then
			best = pad
		end
	end
	return best
end

----------------------------------------------------------------------------------------------------
-- tutorial
----------------------------------------------------------------------------------------------------
local function tut(p)
	local TSv = mod("TutorialService")
	return TSv and TSv.GetState(p) or nil
end

-- the current step id; "done!" once everything is finished (the basics' last step is called "done")
local function stepOf(p)
	local st = tut(p)
	if not st then
		return nil
	end
	if st.Done then
		return "done!"
	end
	return st.Id
end

local function tutEvent(p, eventName)
	advance(0.3) -- the remote is rate limited (0.25 s per player)
	Mock.FromClient(remote("TutorialEvent"), p, eventName)
	advance(0.3)
end

local function waitStep(p, id, seconds)
	K.waitFor(function()
		return stepOf(p) == id
	end, seconds or 3)
	return stepOf(p)
end

local function v3Profile(spotIndex, eco, combat)
	local now = os.time()
	return {
		Version = 2,
		Tokens = 340,
		Pets = { [eco] = 2, [combat] = 1 },
		Equipped = { eco },
		Items = { heal_cloud = 1 },
		Stats = { Matches = 6, Wins = 4, TokensEarned = 900, Spins = 3, BestTimes = { Easy = 95.5 } },
		SpotIndex = spotIndex,
		Discovered = { [eco] = true, [combat] = true },
		IndexClaimed = {},
		Tutorial = { Step = 10, Done = true, Gifted = true },
		-- the v3 reserve: Phase 1 saved these defaults (ARCHITECTURE_V3.md section 1)
		Cash = 0,
		Gems = 0,
		Home = { Level = 0, Rooms = {}, Prestige = 0 },
		PetLevels = {},
		UpdatedAt = now - 86400,
	}
end

----------------------------------------------------------------------------------------------------
-- p2flow_arrive
----------------------------------------------------------------------------------------------------
S.p2flow_arrive = guarded("p2flow_arrive", function()
	if not K.needBoot() then
		return
	end
	local X = svc()
	if not T.check(X.Ty and X.Care and X.Fuse and X.Gems and X.TC and X.PK and X.TSv and X.Steps and X.SS and X.MS and X.PetS,
		"flow: (precondition) TycoonService, PetCareService, FusionService, GemService, TutorialService and the Phase 2 catalogs load") then
		return
	end
	local Config = config()
	local DataS, SS, TSv, Ty, Gs = X.DataS, X.SS, X.TSv, X.Ty, X.Gems
	local ecoDef, combatDef = petsByRole(X.PC)
	if not T.check(ecoDef ~= nil and combatDef ~= nil, "flow: (precondition) the Cloud Roulette has a Common Economy and a Common Combat pet") then
		return
	end
	F.eco, F.combat = ecoDef.Id, combatDef.Id
	local errors0 = #Mock.Errors

	-- Cid played Phase 1: his save is a v3 profile (Home.Rooms reserve, finished basics, an auto-assigned plot)
	local free = freePlots()
	if not T.check(#free >= 3, "flow: (precondition) at least 3 plots are free", #free .. " free") then
		return
	end
	F.plot.Cid = free[#free]
	Mock.DataStore.Data[storeKey(F.ids.Cid)] = v3Profile(F.plot.Cid, F.eco, F.combat)
	F.policy[F.ids.Ben] = "restrict"

	installPolicy()
	local mark = K.logSize()
	local okJoin, errJoin = pcall(function()
		join("Ann")
		join("Ben")
		join("Cid")
	end)
	removePolicy() -- every account was looked up on join; the answers stay
	if not T.check(okJoin, "flow: three players join", tostring(errJoin)) then
		return
	end
	local ann, ben, cid = F.p.Ann, F.p.Ben, F.p.Cid
	advance(5) -- the join toasts come 4 s after the profile loaded

	-- nobody gets a plot on join
	for _, p in ipairs({ ann, ben, cid }) do
		T.check(SS.GetSpot(p) == nil and Ty.GetPlot(p) == nil and p:GetAttribute(Config.Attr.SpotIndex) == nil,
			"flow join: " .. p.Name .. " has no plot until pressing E at a gate")
	end
	T.check(ann:GetAttribute(Config.Attr.Cash) == 0 and ann:GetAttribute(Config.Attr.Gems) == 0 and ben:GetAttribute(Config.Attr.Cash) == 0,
		"flow join: new players show Cash 0 / Gems 0 on the HUD attributes")
	T.check(toasted(ann, "Pick a free home: press E at its gate", mark, "info") and toasted(ben, "Pick a free home", mark),
		"flow join: new players get the side toast 'Pick a free home: press E at its gate!'")
	T.check(not toasted(ann, "Welcome back", mark), "flow join: ...not 'Welcome back' (they never had a plot)")
	T.eq(Gs.PolicyState(ann), "Allowed", "flow join: Ann's account may buy random items (PolicyService)")
	T.eq(Gs.PolicyState(ben), "Restricted", "flow join: Ben's account may not (paid random items restricted)")
	T.check(ann:GetAttribute("PaidRandomItemsRestricted") == false and ben:GetAttribute("PaidRandomItemsRestricted") == true,
		"flow join: ...mirrored on the PaidRandomItemsRestricted attribute (the Shop hides gem roulettes for Ben)")
	local steps = X.Steps.Steps
	local stA = tut(ann)
	T.check(stA and stA.Id == "welcome" and stA.Step == 1 and stA.Total == #steps and stA.Done == false,
		"flow join: a new player's tutorial starts at 'welcome' (1/" .. #steps .. ")", stA and (tostring(stA.Id) .. " " .. tostring(stA.Step)) or "no state")

	-- Cid: the v3 profile migrated on load
	local cp = DataS.GetProfile(cid)
	if T.check(cp ~= nil, "flow migrate: (precondition) Cid's v3 profile loads") then
		local h = cp.Home
		T.check(type(h) == "table" and type(h.Stations) == "table" and h.Rooms == h.Stations and next(h.Stations) == nil
			and h.Prestige == 0 and h.Level == 0 and type(h.Garden) == "table" and type(h.Gym) == "table" and h.CollectorCash == 0,
			"flow migrate: Home.Rooms became the Phase 2 Home (Stations = Rooms, Garden, Gym, CollectorCash)")
		T.check(cp.Tokens == 340 and cp.Pets[F.eco] == 2 and cp.Pets[F.combat] == 1 and cp.Equipped[1] == F.eco and cp.Items.heal_cloud == 1
			and cp.Stats.Wins == 4 and cp.Stats.BestTimes.Easy == 95.5, "flow migrate: tokens, pets, equipped, items and stats are kept")
		T.check(type(cp.Food) == "table" and type(cp.Tiers) == "table" and type(cp.Hybrids) == "table" and type(cp.GemReceipts) == "table"
			and type(cp.PetLevels) == "table", "flow migrate: the new Phase 2 maps exist (Food, Tiers, Hybrids, GemReceipts, PetLevels)")
		T.check(cid:GetAttribute(Config.Attr.Cash) == 0 and cid:GetAttribute(Config.Attr.Gems) == 0 and cid:GetAttribute(Config.Attr.Tokens) == 340,
			"flow migrate: Cash / Gems / CloudTokens attributes")
		local snap = lastSnapshot(cid, mark)
		T.check(snap ~= nil and type(snap.Home) == "table" and snap.Home.Level == 0 and snap.Home.Prestige == 0 and type(snap.Home.Stations) == "table"
			and snap.Cash == 0 and type(snap.Food) == "table" and snap.Pets[F.eco] == 2,
			"flow migrate: Cid's ProfileSync carries the Phase 2 fields")
	end
	local stC = tut(cid)
	T.check(stC and stC.Id == "claim" and stC.Chapter == 2 and stC.Step == X.Steps.ChapterStart[2] and stC.Done == false,
		"flow migrate: a finished Phase 1 tutorial resumes at the home chapter ('claim')", stC and tostring(stC.Id) or "no state")
	T.check(toasted(cid, "Welcome back! Press E at your gate (#" .. F.plot.Cid .. ")", mark, "info"),
		"flow migrate: Cid's last plot (#" .. F.plot.Cid .. ") is free: 'Welcome back! Press E at your gate'")
	local sugg = SS.SuggestSpot(cid)
	T.check(sugg == spots()[F.plot.Cid], "flow migrate: ...and the guide / GoToSpot lead to that gate (SuggestSpot)")

	-- Cid claims his old plot: 'claim' -> 'press'
	claim(cid, F.plot.Cid)
	waitStep(cid, "press", 3)
	local cidInfo = spots()[F.plot.Cid]
	T.check(SS.GetSpot(cid) == cidInfo and cidInfo.Folder:GetAttribute("OwnerUserId") == cid.UserId, "flow migrate: E at his gate gives Cid his old plot")
	T.eq(stepOf(cid), "press", "flow migrate: ...and completes the tutorial's 'claim'")
	local stCp = tut(cid)
	local cidPad = padPosition(cidInfo, "Press1")
	T.check(stCp and stCp.Target and typeof(stCp.Target.Position) == "Vector3" and cidPad ~= nil and (stCp.Target.Position - cidPad).Magnitude < 1,
		"flow migrate: ...'press' points at the Press 1 pad of his plot")

	-- Ann: the basics chapter, start to end
	T.eq(TSv.HandleEvent(ann, "ShopOpened"), false, "flow tutorial: an event of another step is refused")
	tutEvent(ann, "Next")
	T.eq(stepOf(ann), "home", "flow tutorial: Next -> 'home'")
	local st = tut(ann)
	local target = st and st.Target
	F.plot.Ann = target and target.SpotIndex
	local gate = F.plot.Ann and SS.GateCFrame(spots()[F.plot.Ann])
	if not T.check(type(target) == "table" and target.Kind == "Spot" and gate ~= nil and SS.GetOwner(F.plot.Ann) == nil
		and typeof(target.Position) == "Vector3" and (target.Position - gate.Position).Magnitude < 1,
		"flow tutorial: 'home' points at the gate of a free plot", target and tostring(target.SpotIndex) or "no target") then
		return
	end
	Mock.FromClient(remote("GoToSpot"), ann)
	advance(0.6)
	T.check(K.root(ann) and K.planar(K.root(ann).Position, gate.Position) <= 12 and SS.GetSpot(ann) == nil,
		"flow tutorial: the Home button (GoToSpot) walks Ann to a free gate without claiming it")
	mark = K.logSize()
	claim(ann, F.plot.Ann)
	waitStep(ann, "shop", 3)
	local annInfo = spots()[F.plot.Ann]
	T.check(SS.GetSpot(ann) == annInfo and Ty.GetPlot(ann) == annInfo and ann:GetAttribute(Config.Attr.SpotIndex) == F.plot.Ann,
		"flow tutorial: E at the gate claims the plot")
	T.eq(stepOf(ann), "shop", "flow tutorial: ...and completes 'home'")
	T.check(toasted(ann, "Welcome home", mark, "good"), "flow tutorial: ...with the 'Welcome home' toast")
	advance(1.2)
	T.check(annInfo.NameLabel.Text == ann.DisplayName and annInfo.SubLabel.Text == "Home Level 0", "flow tutorial: the nameplate shows Ann / 'Home Level 0'",
		tostring(annInfo.NameLabel.Text) .. " / " .. tostring(annInfo.SubLabel.Text))
	-- a lobby respawn now lands at her home
	Mock.Kill(ann)
	local back = K.waitFor(function()
		return ann.Character ~= nil and K.hum(ann) ~= nil and K.hum(ann).Health > 0
	end, 12)
	advance(0.8)
	T.check(back and K.root(ann) ~= nil and K.planar(K.root(ann).Position, annInfo.SpawnCFrame.Position) <= 10,
		"flow tutorial: a lobby respawn lands at the claimed home", K.root(ann) and string.format("%.1f studs", K.planar(K.root(ann).Position, annInfo.SpawnCFrame.Position)) or "no character")

	tutEvent(ann, "ShopOpened")
	T.eq(stepOf(ann), "spin", "flow tutorial: the Shop opened -> 'spin'")
	T.eq(tokens(ann), Config.Tutorial.GiftTokens, "flow tutorial: ...Nimbus gifts " .. Config.Tutorial.GiftTokens .. " Cloud Tokens")
	mark = K.logSize()
	withRoll(F.eco, function()
		Mock.FromClient(remote("BuyRoulette"), ann, "Cloud")
	end)
	advance(0.5)
	local ap = DataS.GetProfile(ann)
	local rolled = K.lastRemote("RouletteResult", ann.UserId, mark)
	T.check(rolled and rolled.args[1] and rolled.args[1].Ok == true and rolled.args[1].PetId == F.eco and ap.Pets[F.eco] == 1 and tokens(ann) == 0,
		"flow tutorial: the gift pays a Cloud Roulette spin (BuyRoulette remote): " .. F.eco)
	T.eq(ann:GetAttribute(Config.Attr.EquippedPets), F.eco, "flow tutorial: ...the very first pet is equipped")
	T.eq(stepOf(ann), "equip", "flow tutorial: the spin completes 'spin'")
	tutEvent(ann, "PetsOpened")
	T.eq(stepOf(ann), "index", "flow tutorial: opening Pets with the pet equipped completes 'equip'")
	tutEvent(ann, "IndexOpened")
	T.eq(stepOf(ann), "portal", "flow tutorial: the Index opened -> 'portal'")
	local match = K.startMatch("Easy", { ann })
	K.waitFor(function()
		return ann:GetAttribute(Config.Attr.InMatch) == true and stepOf(ann) ~= "portal"
	end, 10)
	T.eq(stepOf(ann), "finish", "flow tutorial: a real Easy match starts -> 'finish'")
	-- while Ann climbs, her plot stays hers
	mark = K.logSize()
	claim(ben, F.plot.Ann)
	T.check(SS.GetOwner(F.plot.Ann) == ann and SS.GetSpot(ben) == nil, "flow tutorial: Ben cannot claim Ann's plot while she is away in a match")
	T.check(toasted(ben, "belongs to " .. ann.DisplayName, mark, "bad"), "flow tutorial: ...the toast names the owner")
	if match then
		X.MS.LeaveMatch(ann)
	end
	K.waitFor(function()
		return stepOf(ann) ~= "finish"
	end, 10)
	T.eq(stepOf(ann), "done", "flow tutorial: back from the match -> 'done'")
	advance(2)
	local t0 = tokens(ann)
	mark = K.logSize()
	tutEvent(ann, "Next")
	waitStep(ann, "press", 3)
	T.eq(tokens(ann), t0 + Config.Tutorial.FinishReward.Tokens, "flow tutorial: 'done' pays the basics reward (" .. Config.Tutorial.FinishReward.Tokens .. " tokens)")
	T.eq(stepOf(ann), "press", "flow tutorial: the home chapter's 'claim' completes at once (Ann already has a home) -> 'press'")
	local stP = tut(ann)
	local annPad = padPosition(annInfo, "Press1")
	T.check(stP and stP.Chapter == 2 and stP.Target and stP.Target.SpotIndex == F.plot.Ann and annPad ~= nil and typeof(stP.Target.Position) == "Vector3"
		and (stP.Target.Position - annPad).Magnitude < 1, "flow tutorial: ...the arrow points at the Press 1 pad of her plot")
	local stored1 = DataS.GetTutorial(ann)
	T.check(stored1 and stored1.Done == true and stored1.Step == X.Steps.IndexOf.press, "flow tutorial: the stored progress: basics done, Step = 'press'",
		stored1 and (tostring(stored1.Done) .. " / " .. tostring(stored1.Step)) or "nil")

	-- Ben: skips the tutorial, claims a plot, cannot touch Ann's
	local tb = tokens(ben)
	tutEvent(ben, "Skip")
	T.check(tut(ben) and tut(ben).Done == true and tokens(ben) == tb, "flow: Ben skips the tutorial (no rewards)")
	free = freePlots()
	F.plot.Ben = free[1]
	claim(ben, F.plot.Ben)
	local benInfo = spots()[F.plot.Ben]
	T.check(SS.GetSpot(ben) == benInfo and F.plot.Ben ~= F.plot.Ann and F.plot.Ben ~= F.plot.Cid, "flow: Ben claims a plot of his own (#" .. tostring(F.plot.Ben) .. ")")
	mark = K.logSize()
	claim(ben, F.plot.Cid)
	T.check(SS.GetSpot(ben) == benInfo and SS.GetOwner(F.plot.Cid) == cid and toasted(ben, "already have a home", mark, "bad"),
		"flow: a second claim is refused (one plot per player)")
	local annPress = buyPrompt(annInfo, "Press1")
	if T.check(annPress ~= nil and annPress:GetAttribute("OwnerUserId") == ann.UserId, "flow: Ann's Press 1 pad carries her OwnerUserId (HomeFx hides it for others)") then
		Mock.Trigger(annPress, ben)
		advance(0.3)
		T.check(level(ann, "Press1") == 0 and level(ben, "Press1") == 0, "flow: Ben's E on Ann's pad builds nothing (for nobody)")
	end
	T.check(SS.GetOwner(F.plot.Ann) == ann and SS.GetOwner(F.plot.Ben) == ben and SS.GetOwner(F.plot.Cid) == cid,
		"flow: three plots, three owners")
	local mine = 0
	for i = errors0 + 1, #Mock.Errors do
		mine = mine + 1
	end
	T.eq(mine, 0, "flow arrive: no script errors")
	K.flushErrors("p2flow_arrive")
	K.flushWarnings("p2flow_arrive", ALLOWED_WARNINGS)
end)

----------------------------------------------------------------------------------------------------
-- p2flow_build
----------------------------------------------------------------------------------------------------
S.p2flow_build = guarded("p2flow_build", function()
	if not K.needBoot() then
		return
	end
	local X = svc()
	local ann, ben, cid = F.p.Ann, F.p.Ben, F.p.Cid
	if not T.check(ann and ann.Parent and ben and ben.Parent and F.plot.Ann and F.plot.Ben and X.Ty and X.TC,
		"flow build: (precondition) Ann and Ben are in the game with their plots (p2flow_arrive)") then
		return
	end
	local Config = config()
	local DataS, Ty, TC, PK = X.DataS, X.Ty, X.TC, X.PK
	local annInfo, benInfo = spots()[F.plot.Ann], spots()[F.plot.Ben]

	-- the free Press 1 and Collector pads, on both plots
	local mark = K.logSize()
	pressPad(ann, annInfo, "Press1")
	T.check(level(ann, "Press1") == 1 and cash(ann) == 0, "flow build: E on the Press 1 pad builds it for free")
	T.check(toasted(ann, "Built Cloud Press 1", mark, "good"), "flow build: ...'Built Cloud Press 1!' toast")
	T.check(stationModel(annInfo, "Press1") ~= nil, "flow build: ...the press stands on Ann's plot (Station_Press1)")
	waitStep(ann, "collect", 3)
	T.eq(stepOf(ann), "collect", "flow build: building Press 1 completes 'press'")
	pressPad(ben, benInfo, "Press1")
	pressPad(ben, benInfo, "Collector")
	pressPad(ann, annInfo, "Collector")
	T.check(level(ann, "Collector") == 1 and level(ben, "Collector") == 1 and level(ben, "Press1") == 1, "flow build: both Collectors are built (free)")
	T.check(home(ann).Level == 2 and annInfo.Folder:GetAttribute("HomeLevel") == 2, "flow build: Home Level 2 (replicated on the plot folder)")
	DataS.MutateHome(ann, function(h)
		h.CollectorCash = 0
	end)
	DataS.MutateHome(ben, function(h)
		h.CollectorCash = 0
	end)
	advance(4.2)
	local ca, cb = home(ann).CollectorCash, home(ben).CollectorCash
	T.check(ca >= 15 and ca <= 25 and cb >= 15 and cb <= 25, "flow build: both Collectors fill at the same time (~5 Cash/s each)", ca .. " / " .. cb)
	T.eq(annInfo.Folder:GetAttribute("CollectorCash"), floor(home(ann).CollectorCash), "flow build: Ann's plot folder replicates her Collector amount")
	local pad = collectPad(annInfo)
	if T.check(pad ~= nil, "flow build: Ann's Collector has its CollectPad") then
		Mock.Touch(pad, K.root(ben))
		T.check(cash(ben) == 0 and home(ann).CollectorCash >= ca, "flow build: Ben stepping on Ann's Collector banks nothing")
		local before = cash(ann)
		local inside = floor(home(ann).CollectorCash)
		Mock.Touch(pad, K.root(ann))
		T.check(cash(ann) - before >= inside and inside > 0, "flow build: stepping on her Collector banks Ann's Cash", (cash(ann) - before) .. " of " .. inside)
		waitStep(ann, "kitchen", 3)
		T.eq(stepOf(ann), "kitchen", "flow build: banking completes 'collect'")
	end
	T.check(home(ben).CollectorCash >= cb and cash(ben) == 0, "flow build: Ben's Collector keeps his own Cash")

	-- the 'kitchen' arrow, pad by pad (the Garden is on the way: an Economy pet goes to work there)
	local path, lost, gardenIncome = {}, nil, nil
	for _ = 1, 30 do
		if stepOf(ann) ~= "kitchen" then
			break
		end
		local stK = tut(ann)
		local nextPad = nil
		for _, padDef in ipairs(TC.AvailablePads(home(ann))) do
			local pos = padPosition(annInfo, padDef.StationId)
			if padDef.Locked == nil and pos and stK.Target and typeof(stK.Target.Position) == "Vector3" and (pos - stK.Target.Position).Magnitude < 0.5 then
				nextPad = padDef
			end
		end
		if not nextPad then
			lost = tostring(stK and stK.Hint)
			break
		end
		fund(ann, nextPad.Price)
		local before = level(ann, nextPad.StationId)
		pressPad(ann, annInfo, nextPad.StationId)
		path[#path + 1] = nextPad.StationId
		if level(ann, nextPad.StationId) ~= before + 1 then
			lost = nextPad.StationId .. " was not built"
			break
		end
		if nextPad.StationId == "Garden" then
			local base = Ty.IncomePerSecond(ann)
			Mock.FromClient(remote("HomeAction"), ann, "GardenSet", { 1, F.eco })
			advance(1.2)
			gardenIncome = Ty.IncomePerSecond(ann) - base
			T.check(home(ann).Garden[1] == F.eco and abs(gardenIncome - TC.PetIncome(X.PC.Get(F.eco), 1)) < 1e-6,
				"flow build: the Economy pet placed in the Garden (HomeAction GardenSet) earns its Income", tostring(gardenIncome))
			T.eq(annInfo.Folder:GetAttribute("GardenPets"), "1=" .. F.eco, "flow build: ...shown on the plot (GardenPets)")
		end
	end
	T.check(lost == nil and path[#path] == "Kitchen", "flow build: following the 'kitchen' arrow pad by pad builds the Kitchen", table.concat(path, " > ") .. (lost and (" (lost: " .. lost .. ")") or ""))
	T.check(gardenIncome ~= nil, "flow build: ...with the Garden on the way")
	waitStep(ann, "feed", 3)
	T.eq(stepOf(ann), "feed", "flow build: the Kitchen completes 'kitchen'")

	-- the player's rule: the Fusion Machine pad is a locked silhouette until Prestige 1
	local fusionPrompt = buyPrompt(annInfo, "FusionMachine")
	local fusionPad = X.HB and X.HB.GetPad and X.HB.GetPad(annInfo, "FusionMachine") or nil
	if T.check(fusionPrompt ~= nil, "flow build: with the Kitchen built, the Fusion Machine pad appears") then
		T.check(fusionPrompt.Enabled == false and fusionPad ~= nil and fusionPad:GetAttribute("Locked") == "Unlocks at Prestige 1",
			"flow build: ...locked: 'Unlocks at Prestige 1' (its prompt is off)", fusionPad and tostring(fusionPad:GetAttribute("Locked")) or "no pad model")
		T.check(annInfo.Folder:FindFirstChild("Ghost_FusionMachine", true) ~= nil, "flow build: ...with the machine's silhouette on the yard")
		fund(ann, TC.PriceFor("FusionMachine", 1))
		local c = cash(ann)
		mark = K.logSize()
		Mock.Trigger(fusionPrompt, ann) -- (a forged press: the engine does not fire a disabled prompt)
		advance(0.3)
		T.check(level(ann, "FusionMachine") == 0 and cash(ann) == c and toasted(ann, "Unlocks at Prestige 1", mark, "bad"),
			"flow build: a forced press on it builds nothing, takes nothing and says why")
	end

	-- E at the Kitchen counter cooks a Snack (only for the owner)
	advance(1.2) -- PetCareService puts the cook prompts on its next tick
	local cook = cookPrompt(annInfo, "Snack")
	if T.check(cook ~= nil and cook:GetAttribute("OwnerUserId") == ann.UserId, "flow build: the Kitchen has Ann's 'Cook Snack' prompt") then
		fund(ann, 50)
		local c0, cBen = cash(ann), cash(ben)
		Mock.Trigger(cook, ben)
		advance(0.4)
		T.check(cash(ann) == c0 and cash(ben) == cBen and (ann:GetAttribute("KitchenQueue") or "") == "", "flow build: Ben's E on Ann's counter cooks nothing")
		local at = promptPosition(cook)
		if at then
			Mock.Teleport(ann, CFrame.new(at + Vector3.new(0, 0, -3)))
		end
		Mock.Trigger(cook, ann)
		advance(0.4)
		T.check(cash(ann) == c0 - TC.Foods.Snack.Price and ann:GetAttribute("KitchenQueue") == "Snack", "flow build: Ann's E cooks a Snack (Cash paid, KitchenQueue)",
			tostring(ann:GetAttribute("KitchenQueue")))
		K.waitFor(function()
			return DataS.GetFood(ann, "Snack") >= 1
		end, 12)
		T.eq(DataS.GetFood(ann, "Snack"), 1, "flow build: ...the Snack is done after its cook time")
		advance(1.2)
		local stF = tut(ann)
		T.check(stF and stF.Target and stF.Target.Kind == "Menu" and stF.Target.Id == "Pets", "flow build: with food, 'feed' points at the Pets button")
	end
	-- the Pets panel's Feed button (PetCare remote)
	mark = K.logSize()
	local c1 = cash(ann)
	local income1 = Ty.IncomePerSecond(ann)
	Mock.FromClient(remote("PetCare"), ann, "Feed", F.eco, "Snack")
	advance(0.6)
	local lv = DataS.GetPetLevel(ann, F.eco)
	T.check(DataS.GetFood(ann, "Snack") == 0 and lv == 2, "flow build: feeding the Snack (25 XP) levels the pet to 2", "level " .. tostring(lv))
	T.check(toasted(ann, "Lv 2", mark, "good"), "flow build: ...a level-up toast")
	local stDone = tut(ann)
	T.check(stDone and stDone.Done == true and stDone.Completed == true, "flow build: feeding a pet ends the home chapter (the whole tutorial is done)")
	T.eq(cash(ann), c1 + 1000, "flow build: ...the home chapter's Cash reward (once)")
	advance(1.2)
	T.check(Ty.IncomePerSecond(ann) > income1, "flow build: the garden income follows the pet's level", income1 .. " -> " .. Ty.IncomePerSecond(ann))

	-- the Gym: a Combat pet from the roulette trains there
	DataS.AddTokens(ann, 50)
	withRoll(F.combat, function()
		advance(0.3)
		Mock.FromClient(remote("BuyRoulette"), ann, "Cloud")
	end)
	advance(0.5)
	T.eq(PK.Count(DataS.GetProfile(ann), F.combat), 1, "flow gym: a Combat pet from the Cloud Roulette (" .. F.combat .. ")")
	fund(ann, TC.PriceFor("Gym", 1))
	pressPad(ann, annInfo, "Gym")
	T.check(level(ann, "Gym") == 1 and stationModel(annInfo, "Gym") ~= nil, "flow gym: the Gym pad builds the Gym")
	local arenaPrompt = buyPrompt(annInfo, "ArenaGate")
	local arenaPad = X.HB and X.HB.GetPad and X.HB.GetPad(annInfo, "ArenaGate") or nil
	T.check(arenaPrompt ~= nil and arenaPrompt.Enabled == false and arenaPad ~= nil and arenaPad:GetAttribute("Locked") == "Coming soon",
		"flow gym: ...and the Arena Gate pad shows up as 'Coming soon' (Phase 3)", arenaPad and tostring(arenaPad:GetAttribute("Locked")) or "no pad")
	mark = K.logSize()
	Mock.FromClient(remote("PetCare"), ann, "GymSet", 1, F.eco)
	advance(0.4)
	Mock.FromClient(remote("HomeAction"), ann, "GardenSet", { 1, F.combat })
	advance(0.4)
	T.check(home(ann).Gym[1] == nil and home(ann).Garden[1] == F.eco, "flow gym: an Economy pet cannot train and a Combat pet cannot work in the Garden")
	T.check(toasted(ann, "Only Combat pets", mark, "bad") and toasted(ann, "Only Economy pets", mark, "bad"), "flow gym: ...both refusals toast why")
	Mock.FromClient(remote("PetCare"), ann, "GymSet", 1, F.combat)
	advance(1.2)
	T.check(home(ann).Gym[1] == F.combat and annInfo.Folder:GetAttribute("GymPets") == "1=" .. F.combat, "flow gym: the Combat pet trains in Gym slot 1 (GymPets on the plot)",
		tostring(annInfo.Folder:GetAttribute("GymPets")))
	local g0 = DataS.GetPetLevel(ann, F.combat)
	advance(75) -- (XP is granted every 10 s)
	local g1, gx = DataS.GetPetLevel(ann, F.combat)
	T.check(g0 == 1 and g1 >= 2, "flow gym: a minute in a Lv 1 Gym levels it up (" .. TC.GymXpPerMinute(home(ann)) .. " XP per minute, " .. TC.XpToNext(1) .. " XP to Lv 2)",
		g0 .. " -> " .. tostring(g1) .. " (" .. tostring(gx) .. " xp)")

	-- Ben's home ran on its own the whole time
	T.check(cash(ben) == 0 and home(ben).CollectorCash > cb and level(ben, "Garden") == 0, "flow build: Ben's plot earned its own Cash meanwhile (nothing of Ann's)")
	-- the house tier caps the presses: Ben's Cottage takes Press 1 to Lv 6, the 7th level needs the Villa
	local cap = TC.MaxLevelAt("Press1", home(ben))
	local upTo = {}
	for _ = level(ben, "Press1") + 1, cap do
		local nextLv = level(ben, "Press1") + 1
		fund(ben, TC.PriceFor("Press1", nextLv))
		pressPad(ben, benInfo, "Press1")
		upTo[#upTo + 1] = level(ben, "Press1")
	end
	T.check(cap == 6 and level(ben, "Press1") == cap, "flow build: Ben levels his Press 1 to the Cottage's cap (Lv " .. tostring(cap) .. ") with E", table.concat(upTo, ","))
	local benPadModel = X.HB and X.HB.GetPad and X.HB.GetPad(benInfo, "Press1") or nil
	T.check(benPadModel ~= nil and benPadModel:GetAttribute("Locked") == "Needs the Villa" and buyPrompt(benInfo, "Press1").Enabled == false,
		"flow build: ...then its pad reads 'Needs the Villa' (prompt off)", benPadModel and tostring(benPadModel:GetAttribute("Locked")) or "no pad")
	fund(ben, TC.PriceFor("Press1", cap + 1))
	local cBen2 = cash(ben)
	mark = K.logSize()
	advance(1.6)
	pressPad(ben, benInfo, "Press1")
	T.check(level(ben, "Press1") == cap and cash(ben) == cBen2 and toasted(ben, "Needs the Villa", mark, "bad"), "flow build: ...and a forced press is refused with that reason (nothing paid)")
	DataS.SpendCash(ben, cash(ben)) -- (back to an empty wallet)

	-- Cid: his Press 1 from the Home window (HomeAction Upgrade), then he leaves: the save is a Phase 2 profile
	if cid and cid.Parent and F.plot.Cid then
		Mock.FromClient(remote("HomeAction"), cid, "Upgrade", "Press1")
		advance(0.6)
		T.eq(level(cid, "Press1"), 1, "flow migrate: Cid builds his Press 1 from the Home window (HomeAction Upgrade)")
		waitStep(cid, "collect", 3)
		T.eq(stepOf(cid), "collect", "flow migrate: ...his tutorial moves on ('collect')")
		leave(cid)
		advance(1.5)
		local rec = stored(F.ids.Cid) or {}
		local rh = type(rec.Home) == "table" and rec.Home or {}
		T.check(rec.Version == 2 and type(rh.Stations) == "table" and rh.Stations.Press1 == 1 and rh.Rooms == nil and rh.Prestige == 0 and rh.Level == 1,
			"flow migrate: Cid's save is a Phase 2 profile now (Home.Stations, no Rooms, Version 2)", mapText(rh.Stations))
		T.check(rec.SpotIndex == F.plot.Cid and type(rec.Tutorial) == "table" and rec.Tutorial.Step == X.Steps.IndexOf.collect and rec.Tokens == 340,
			"flow migrate: ...with his plot, tutorial progress and tokens")
		T.eq(spots()[F.plot.Cid].NameLabel.Text, "Free home", "flow migrate: his plot is free again")
	end
	K.flushErrors("p2flow_build")
	K.flushWarnings("p2flow_build", ALLOWED_WARNINGS)
end)

----------------------------------------------------------------------------------------------------
-- p2flow_prestige
----------------------------------------------------------------------------------------------------
S.p2flow_prestige = guarded("p2flow_prestige", function()
	if not K.needBoot() then
		return
	end
	local X = svc()
	local ann = F.p.Ann
	if not T.check(ann and ann.Parent and F.plot.Ann and level(ann, "Kitchen") >= 1, "flow prestige: (precondition) Ann has her plot with a Kitchen (p2flow_build)") then
		return
	end
	local DataS, Ty, TC, SS = X.DataS, X.Ty, X.TC, X.SS
	local annInfo = spots()[F.plot.Ann]
	local mark = K.logSize()

	-- pad by pad up to the Prestige pad (the next house first whenever it is open, then the cheapest pad)
	local problems, gateRefused = {}, {}
	local purchases = 0
	for _ = 1, 300 do
		local h = home(ann)
		if TC.CanPrestige(h) then
			break
		end
		local housePad = nil
		for _, padDef in ipairs(TC.AvailablePads(h)) do
			if padDef.StationId == "House" then
				housePad = padDef
			end
			if padDef.StationId == "House" and padDef.Locked and padDef.Locked:find("Reach Home Level", 1, true) and not gateRefused[padDef.NextLevel] then
				-- the next house below its Home Level: refused even with the Cash in hand
				gateRefused[padDef.NextLevel] = true
				fund(ann, padDef.Price)
				local c = cash(ann)
				local m = K.logSize()
				advance(1.6) -- (the same refusal text is not repeated within 1.5 s)
				pressPad(ann, annInfo, "House")
				if level(ann, "House") ~= padDef.Level or cash(ann) ~= c or not toasted(ann, padDef.Locked, m, "bad") then
					problems[#problems + 1] = "the " .. tostring(padDef.Title) .. " was not refused below " .. padDef.Locked
				end
			end
		end
		local best = (housePad and housePad.Locked == nil) and housePad or cheapestPad(TC, h)
		if not best then
			problems[#problems + 1] = "dead end at Home Level " .. TC.HomeLevelOf(h)
			break
		end
		fund(ann, best.Price)
		local c = cash(ann)
		local before = level(ann, best.StationId)
		if not pressPad(ann, annInfo, best.StationId) then
			problems[#problems + 1] = "no pad for " .. best.StationId
			break
		end
		purchases = purchases + 1
		if level(ann, best.StationId) ~= before + 1 or c - cash(ann) ~= best.Price then
			problems[#problems + 1] = best.StationId .. " Lv " .. (before + 1) .. ": paid " .. (c - cash(ann)) .. " of " .. tostring(best.Price)
			break
		end
	end
	local h = home(ann)
	T.check(#problems == 0, "flow prestige: " .. purchases .. " purchases with E on the pads, each for exactly its price", table.concat(problems, " | "))
	T.check(gateRefused[2] and gateRefused[3] and gateRefused[4], "flow prestige: the Villa, Manor and Sky Castle pads refuse below Home Level 10 / 20 / 30 (toast, nothing paid)",
		"refused: " .. mapText(gateRefused))
	for _, name in ipairs({ "Villa", "Manor", "Sky Castle" }) do
		T.check(toasted(ann, name .. " built!", mark, "good"), "flow prestige: '" .. name .. " built!' toast")
	end
	T.check(toasted(ann, "Prestige is ready", mark, "good"), "flow prestige: 'Prestige is ready at your home!' toast")
	T.check(TC.CanPrestige(h) and TC.HomeLevelOf(h) >= 40 and level(ann, "House") == 4, "flow prestige: the Sky Castle at Home Level " .. TC.HomeLevelOf(h))
	local prestigePad = buyPrompt(annInfo, "Prestige")
	if not T.check(prestigePad ~= nil, "flow prestige: the Prestige pad appears on the plot") then
		return
	end

	-- prestige with E on the pad
	DataS.AddCash(ann, 12345)
	DataS.Save(ann) -- the store holds the build of Home Level 40
	local before = {
		Cash = cash(ann), Gems = gems(ann), Stations = home(ann).Stations, Garden = home(ann).Garden, Gym = home(ann).Gym,
		Snack = DataS.GetFood(ann, "Snack"), Eco = X.PK.Count(DataS.GetProfile(ann), F.eco), Level = TC.HomeLevelOf(home(ann)),
	}
	F.preStored = stored(ann.UserId)
	mark = K.logSize()
	pressPad(ann, annInfo, "Prestige")
	local after = home(ann)
	T.check(after.Prestige == 1 and cash(ann) == 0 and gems(ann) == before.Gems + TC.PrestigeGems(1),
		"flow prestige: E on the Prestige pad: +1 star, Cash 0, +" .. TC.PrestigeGems(1) .. " Gems", tostring(after.Prestige) .. " / " .. cash(ann) .. " / " .. gems(ann))
	local wrong = {}
	for _, def in ipairs(TC.Stations) do
		local want = def.KeepOnPrestige and (before.Stations[def.Id] or 0) or 0
		if (after.Stations[def.Id] or 0) ~= want then
			wrong[#wrong + 1] = def.Id .. "=" .. tostring(after.Stations[def.Id])
		end
	end
	T.check(#wrong == 0, "flow prestige: stations reset, decor kept", table.concat(wrong, ","))
	T.check(sameMap(after.Garden, before.Garden) and sameMap(after.Gym, before.Gym) and DataS.GetFood(ann, "Snack") == before.Snack
		and X.PK.Count(DataS.GetProfile(ann), F.eco) == before.Eco, "flow prestige: garden and gym choices, food and pets are kept")
	T.check(toasted(ann, "Prestige 1!", mark, "good") and toasted(ann, "Fusion Machine unlocked", mark, "good"), "flow prestige: 'Prestige 1!' and 'Fusion Machine unlocked' toasts")
	advance(1.2)
	T.check(annInfo.SubLabel.Text:find(STAR, 1, true) ~= nil and annInfo.Folder:GetAttribute("Prestige") == 1, "flow prestige: the nameplate shows the star (Prestige attribute 1)", annInfo.SubLabel.Text)
	T.check(stationModel(annInfo, "Press1") == nil and stationModel(annInfo, "House") == nil and stationModel(annInfo, "Garden") == nil,
		"flow prestige: the reset stations leave the plot")
	T.eq(Ty.IncomePerSecond(ann), 0, "flow prestige: no presses, no Collector: the garden pet earns nothing until the Garden is rebuilt")
	advance(11) -- XP that piled up before the reset is granted on the next 10 s Gym grant
	local gLv, gXp = DataS.GetPetLevel(ann, F.combat)
	advance(25)
	local gLv2, gXp2 = DataS.GetPetLevel(ann, F.combat)
	T.check(gLv2 == gLv and gXp2 == gXp, "flow prestige: the pet in the reset Gym stops training", gLv .. "/" .. gXp .. " -> " .. gLv2 .. "/" .. gXp2)

	-- DataStore merge after the prestige: a stale server's late prestige-0 write lands before this server saves
	local rec = stored(ann.UserId)
	if T.check(type(rec) == "table" and type(rec.Home) == "table" and rec.Home.Prestige == 0, "flow merge: (precondition) the store still holds the prestige-0 build") then
		local stashCash, stashGems = rec.Cash or 0, rec.Gems or 0
		local stashSnack = (type(rec.Food) == "table" and rec.Food.Snack) or 0
		rec.Home.Stations.Vault = min(5, (rec.Home.Stations.Vault or 0) + 1)
		rec.Home.Level = (rec.Home.Level or 0) + 1
		rec.Cash = stashCash + 5000
		rec.Gems = stashGems + 7
		rec.Food = type(rec.Food) == "table" and rec.Food or {}
		rec.Food.Snack = stashSnack + 2
		DataS.Save(ann)
		local s = stored(ann.UserId) or {}
		local sh = type(s.Home) == "table" and s.Home or {}
		T.check(sh.Prestige == 1 and sameMap(sh.Stations, home(ann).Stations) and (sh.Stations.Vault or 0) == (home(ann).Stations.Vault or 0),
			"flow merge: the prestiged Home wins whole (the stale write's station levels do not come back)", mapText(sh.Stations))
		T.eq(s.Cash, 5000, "flow merge: Cash merges as a delta: the stale server's +5000 stays, the prestige reset took the rest")
		T.eq(s.Gems, stashGems + 7 + TC.PrestigeGems(1), "flow merge: Gems: the stale +7 plus the prestige reward")
		T.check(type(s.Food) == "table" and s.Food.Snack == stashSnack + 2, "flow merge: Food merges as a delta (+2 Snacks)")
		advance(0.6)
		T.check(cash(ann) == 5000 and ann:GetAttribute(config().Attr.Cash) == 5000 and gems(ann) == s.Gems and ann:GetAttribute(config().Attr.Gems) == s.Gems,
			"flow merge: the live profile adopts the merged balances (HUD attributes too)")
		T.check(home(ann).Prestige == 1 and stationModel(annInfo, "Vault") == nil and stationModel(annInfo, "Press1") == nil,
			"flow merge: ...and the plot keeps showing the prestiged home")
	end
	K.flushErrors("p2flow_prestige")
	K.flushWarnings("p2flow_prestige", ALLOWED_WARNINGS)
end)

----------------------------------------------------------------------------------------------------
-- p2flow_fusion_gems
----------------------------------------------------------------------------------------------------
S.p2flow_fusion_gems = guarded("p2flow_fusion_gems", function()
	if not K.needBoot() then
		return
	end
	local X = svc()
	local ann, ben = F.p.Ann, F.p.Ben
	if not T.check(ann and ann.Parent and home(ann) and home(ann).Prestige >= 1, "flow fusion: (precondition) Ann prestiged (p2flow_prestige)") then
		return
	end
	local Config = config()
	local DataS, Ty, TC, PK, Gs, FS = X.DataS, X.Ty, X.TC, X.PK, X.Gems, X.Fuse
	local annInfo = spots()[F.plot.Ann]
	local prof = DataS.GetProfile(ann)

	-- rebuild the way to the Fusion Machine
	local route = { "Press1", "Collector", "Press1", "Press2", "Press2", "Garden", "Kitchen" }
	local missed = {}
	for _, id in ipairs(route) do
		local lvBefore = level(ann, id)
		local price = TC.PriceFor(id, lvBefore + 1) or 0
		fund(ann, price)
		pressPad(ann, annInfo, id)
		if level(ann, id) ~= lvBefore + 1 then
			missed[#missed + 1] = id
		end
	end
	T.check(#missed == 0, "flow fusion: Ann rebuilds Press 1, the Collector, Press 2, the Garden and the Kitchen", table.concat(missed, ","))
	advance(1.2)
	local base = Ty.IncomePerSecond(ann)
	local _, parts = Ty.IncomePerSecond(ann)
	T.check(type(parts) == "table" and abs((parts.Multiplier or 0) - TC.PrestigeMultiplier(1)) < 1e-6 and (parts.Garden or 0) > 0,
		"flow fusion: the garden pet earns again, everything x" .. TC.PrestigeMultiplier(1), tostring(base))
	local okPad, priceFusion, lockFusion = TC.CheckPurchase(home(ann), "FusionMachine")
	T.check(okPad == true and buyPrompt(annInfo, "FusionMachine") ~= nil, "flow fusion: the Fusion Machine pad is unlocked (Prestige 1 + Kitchen)", tostring(lockFusion))
	fund(ann, priceFusion or 0)
	pressPad(ann, annInfo, "FusionMachine")
	local machine = stationModel(annInfo, "FusionMachine")
	if not T.check(level(ann, "FusionMachine") == 1 and machine ~= nil, "flow fusion: E on its pad builds the Fusion Machine") then
		return
	end

	-- three copies: one works in the Garden, one is equipped (with the Combat pet, so a pet stays equipped)
	DataS.AddTokens(ann, 100)
	for _ = 1, 2 do
		withRoll(F.eco, function()
			advance(0.3)
			Mock.FromClient(remote("BuyRoulette"), ann, "Cloud")
		end)
	end
	advance(0.4)
	Mock.FromClient(remote("EquipPet"), ann, F.combat)
	advance(0.4)
	T.check(PK.Count(prof, F.eco) == 3 and home(ann).Garden[1] == F.eco and prof.Equipped[1] == F.eco and prof.Equipped[2] == F.combat,
		"flow fusion: (precondition) 3 copies, one in the Garden; equipped: the pet + the Combat pet", PK.Count(prof, F.eco) .. " / {" .. table.concat(prof.Equipped, ",") .. "}")
	local level0 = DataS.GetPetLevel(ann, F.eco)
	local cost = TC.FusionCost("Upgrade", X.PC.Get(F.eco).Rarity, "Golden", 1)
	DataS.AddTokens(ann, (cost and cost.Tokens) or 0)
	local t0 = tokens(ann)

	-- the window works only at the machine (E at the machine opens it)
	Mock.Teleport(ann, K.W.lobbyInfo.SpawnCFrame)
	advance(0.3)
	local mark = K.logSize()
	Mock.FromClient(remote("Fusion"), ann, "Upgrade", F.eco)
	advance(0.3)
	T.check(PK.Count(prof, F.eco) == 3 and tokens(ann) == t0 and toasted(ann, "Walk up to your Fusion Machine", mark, "bad"),
		"flow fusion: a fusion request from the plaza is refused (walk up to the machine), nothing used")
	advance(1.0)
	local at = pivotOf(machine)
	Mock.Teleport(ann, at * CFrame.new(0, 3, -8))
	mark = K.logSize()
	Mock.FromClient(remote("Fusion"), ann, "Upgrade", F.eco)
	advance(0.6)
	local golden = PK.Make(F.eco, "Golden")
	T.check(PK.Count(prof, F.eco) == 0 and PK.Count(prof, golden) == 1, "flow fusion: Upgrade at the machine: 3 copies -> 1 " .. golden)
	T.eq(tokens(ann), t0 - ((cost and cost.Tokens) or 0), "flow fusion: ...for the TycoonCatalog cost in Cloud Tokens")
	T.eq(home(ann).Garden[1], golden, "flow fusion: ...the Golden copy took over the garden slot")
	T.check(prof.Equipped[1] == golden and prof.Equipped[2] == F.combat and ann:GetAttribute(Config.Attr.EquippedPets) == golden .. "," .. F.combat,
		"flow fusion: ...and the equipped place", table.concat(prof.Equipped, ","))
	T.eq(DataS.GetPetLevel(ann, golden), level0, "flow fusion: ...and keeps the level of its inputs")
	local results = K.remotesFor("Fusion", ann.UserId, mark)
	local res = results[#results]
	T.check(res and res.args[1] == "Result" and type(res.args[2]) == "table" and res.args[2].Ok == true and res.args[2].Key == golden,
		"flow fusion: the window gets Fusion('Result', {Ok, Key}) for its animation")
	advance(1.2)
	T.eq(annInfo.Folder:GetAttribute("GardenPets"), "1=" .. golden, "flow fusion: the plot shows the Golden pet in the Garden")
	local ecoDef = X.PC.Get(F.eco)
	local wantGarden = TC.PetIncome(ecoDef, level0, "Golden") * TC.PrestigeMultiplier(1)
	local _, parts2 = Ty.IncomePerSecond(ann)
	T.check(type(parts2) == "table" and abs((parts2.Garden or 0) - wantGarden) < 1e-6,
		"flow fusion: the Golden garden pet earns x1.5 (and the prestige x" .. TC.PrestigeMultiplier(1) .. ")", tostring(parts2 and parts2.Garden) .. " vs " .. wantGarden)

	-- gem packs (the owner pasted two product ids; restored below)
	local G = Config.Gems.Products
	local savedIds = {}
	for i, p in ipairs(G) do
		savedIds[i] = p.Id
	end
	local cb = MPS.ProcessReceipt
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet
	local okGems, errGems = pcall(function()
		T.check(type(cb) == "function", "flow gems: GemService set MarketplaceService.ProcessReceipt")
		G[2].Id, G[3].Id = 4398802, 4398803
		local function run(info)
			local box = spawnCall(cb, info)
			K.waitFor(function()
				return box.done
			end, 30)
			return box.done and box.ok and box.result or "error"
		end
		local g0 = gems(ann)
		local r1 = { PlayerId = ann.UserId, ProductId = G[2].Id, PurchaseId = "flow-ann-1", CurrencySpent = 99 }
		local r2 = { PlayerId = ann.UserId, ProductId = G[3].Id, PurchaseId = "flow-ann-2", CurrencySpent = 199 }
		T.eq(run(r1), GRANTED, "flow gems: Ann buys a " .. G[2].Name .. ": PurchaseGranted")
		T.eq(gems(ann), g0 + G[2].Gems, "flow gems: ...+" .. G[2].Gems .. " Gems")
		local rec = stored(ann.UserId) or {}
		T.check(rec.Gems == gems(ann) and type(rec.GemReceipts) == "table" and rec.GemReceipts[r1.PurchaseId] ~= nil and type(rec.Home) == "table" and rec.Home.Prestige == 1,
			"flow gems: ...saved with its receipt before PurchaseGranted (the prestiged home in the same record)")
		T.eq(run(r1), GRANTED, "flow gems: Roblox retries the same receipt: PurchaseGranted...")
		T.eq(gems(ann), g0 + G[2].Gems, "flow gems: ...and nothing is granted twice")
		T.eq(run(r2), GRANTED, "flow gems: a " .. G[3].Name .. " too")
		T.eq(gems(ann), g0 + G[2].Gems + G[3].Gems, "flow gems: ...+" .. G[3].Gems)
		T.eq(run({ PlayerId = ann.UserId, ProductId = 4398801, PurchaseId = "flow-ann-x" }), NOT_YET, "flow gems: a pack that is not created (id 0) stays pending")
		local gb = gems(ben)
		T.eq(run({ PlayerId = ben.UserId, ProductId = G[2].Id, PurchaseId = "flow-ben-1" }), GRANTED, "flow gems: Ben (random items restricted) can still buy Gems")
		T.check(gems(ben) == gb + G[2].Gems and gems(ann) == g0 + G[2].Gems + G[3].Gems, "flow gems: ...his Gems are his (Ann's untouched)")
		F.receipt = r1
	end)
	for i, p in ipairs(G) do
		p.Id = savedIds[i]
	end
	T.check(okGems, "flow gems: the purchase steps ran", tostring(errGems))

	-- the Storm Altar opens the Shop on the Secret roulette (Ann); Ben gets a side toast
	local altarPrompt = nil
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "StormAltarPrompt" then
			altarPrompt = d
		end
	end
	local secretId = Config.Gems.SecretRoulette.Id
	if T.check(altarPrompt ~= nil, "flow secret: the Storm Altar has its Summon prompt") then
		local where = promptPosition(altarPrompt)
		if where then
			Mock.Teleport(ann, CFrame.new(where + Vector3.new(0, 0, -6)))
			Mock.Teleport(ben, CFrame.new(where + Vector3.new(4, 0, -6)))
		end
		mark = K.logSize()
		Mock.Trigger(altarPrompt, ann)
		Mock.Trigger(altarPrompt, ben)
		advance(0.3)
		local opened = 0
		for _, e in ipairs(K.remotesFor("OpenPanel", ann.UserId, mark)) do
			if e.args[1] == "Shop" and type(e.args[2]) == "table" and e.args[2].RouletteId == secretId then
				opened = opened + 1
			end
		end
		T.eq(opened, 1, "flow secret: Ann's Summon opens the Shop on the Secret roulette")
		T.check(#K.remotesFor("OpenPanel", ben.UserId, mark) == 0 and toasted(ben, "not available", mark), "flow secret: Ben's account gets a side toast instead (no Shop)")
	end
	-- a gem spin of the Secret roulette (the Shop's Gems tab: BuyRoulette(id, "Gems"))
	local price = Config.Gems.SecretRoulette.GemPrice
	local gA, gB, pB = gems(ann), gems(ben), countKeys(DataS.GetProfile(ben).Pets)
	mark = K.logSize()
	Mock.FromClient(remote("BuyRoulette"), ann, secretId, "Gems")
	Mock.FromClient(remote("BuyRoulette"), ben, secretId, "Gems")
	advance(0.6)
	local spun = K.lastRemote("RouletteResult", ann.UserId, mark)
	local result = spun and spun.args[1]
	local won = type(result) == "table" and result.Ok == true and result.PetId or nil
	local wonDef = won and X.PC.Get(won)
	T.check(wonDef ~= nil and (wonDef.Rarity == "Mythic" or wonDef.Rarity == SECRET) and gems(ann) == gA - price and result.Currency == "Gems",
		"flow secret: Ann's Secret spin: a " .. tostring(wonDef and wonDef.Rarity) .. " pet for " .. price .. " Gems", tostring(won))
	T.check(won ~= nil and PK.Count(prof, won) >= 1 and prof.Discovered[won] == true, "flow secret: ...owned and discovered in the Pet Index")
	T.check(gems(ben) == gB and countKeys(DataS.GetProfile(ben).Pets) == pB, "flow secret: Ben's spin is refused, nothing charged")
	F.secretPet = won

	-- mixing the Secret-roulette pet with the training Combat pet (Mythic / Secret inputs cost Gems)
	if won then
		local mixCost = TC.FusionCost("Mix", wonDef.Rarity, nil, 1) or {}
		local gemsBefore, tokensBefore = gems(ann), tokens(ann)
		T.check(mixCost.Gems ~= nil, "flow fusion: a Mix with a " .. wonDef.Rarity .. " pet costs Gems", mapText(mixCost))
		advance(1.0)
		Mock.Teleport(ann, at * CFrame.new(0, 3, -8))
		mark = K.logSize()
		Mock.FromClient(remote("Fusion"), ann, "Mix", won, F.combat)
		advance(0.6)
		local hybridKey, record = nil, nil
		for uid, r in pairs(prof.Hybrids or {}) do
			if r.Body == won and r.Style == F.combat then
				hybridKey, record = "hyb:" .. uid, r
			end
		end
		T.check(hybridKey ~= nil and PK.Count(prof, hybridKey) == 1 and PK.Count(prof, F.combat) == 0 and PK.Count(prof, won) == 0,
			"flow fusion: Mix(" .. won .. ", " .. F.combat .. ") makes a hybrid record (both inputs used)", tostring(hybridKey))
		T.eq(gems(ann), gemsBefore - (mixCost.Gems or 0), "flow fusion: ...for " .. tostring(mixCost.Gems) .. " Gems (no tokens)")
		T.eq(tokens(ann), tokensBefore, "flow fusion: ...no Cloud Tokens taken")
		if record then
			T.check(record.Rarity == wonDef.Rarity and type(record.Elements) == "table" and #record.Elements >= 1 and type(record.Name) == "string",
				"flow fusion: ...the hybrid has the higher rarity, both elements and a blended name (" .. tostring(record.Name) .. ")")
			local def = PK.DefOf(hybridKey, prof)
			local gymNow = home(ann).Gym[1]
			if def and def.Role == "Combat" then
				T.eq(gymNow, hybridKey, "flow fusion: ...the Combat hybrid took over the Gym slot of its input")
			else
				T.eq(gymNow, nil, "flow fusion: ...the Gym slot of the used Combat pet is free")
			end
			T.check(prof.Equipped[2] == hybridKey, "flow fusion: ...and the equipped place of the Combat pet", table.concat(prof.Equipped, ","))
			F.hybrid = hybridKey
		end
	end
	K.flushErrors("p2flow_fusion_gems")
	K.flushWarnings("p2flow_fusion_gems", ALLOWED_WARNINGS)
end)

----------------------------------------------------------------------------------------------------
-- p2flow_rejoin
----------------------------------------------------------------------------------------------------
S.p2flow_rejoin = guarded("p2flow_rejoin", function()
	if not K.needBoot() then
		return
	end
	local X = svc()
	local ann, ben = F.p.Ann, F.p.Ben
	if not T.check(ann and ann.Parent and F.plot.Ann and home(ann) and home(ann).Prestige >= 1, "flow rejoin: (precondition) Ann prestiged and has her plot") then
		return
	end
	local Config = config()
	local DataS, Ty, TC, PK, SS = X.DataS, X.Ty, X.TC, X.PK, X.SS
	local DSt = Mock.DataStore
	local annOld = F.plot.Ann
	local annInfo = spots()[annOld]

	-- Ann orders two Snacks and leaves while they cook: the leave save gets the Cash back
	fund(ann, 2 * TC.Foods.Snack.Price)
	local beforeOrder = cash(ann)
	Mock.FromClient(remote("PetCare"), ann, "Cook", "Snack", 2)
	advance(0.4)
	T.check(cash(ann) == beforeOrder - 2 * TC.Foods.Snack.Price and ann:GetAttribute("KitchenQueue") == "Snack,Snack",
		"flow rejoin: (precondition) two Snacks cooking", tostring(ann:GetAttribute("KitchenQueue")))
	local keep = {
		Cash = beforeOrder, Gems = gems(ann), Tokens = tokens(ann), Home = home(ann), Food = DataS.GetFood(ann),
		Level = TC.HomeLevelOf(home(ann)), Golden = DataS.GetPetLevel(ann, PK.Make(F.eco, "Golden")),
		Hybrids = countKeys(DataS.GetProfile(ann).Hybrids), Tiers = mapText((DataS.GetProfile(ann).Tiers or {})[F.eco]),
		Income = Ty.IncomePerSecond(ann),
	}
	DSt.Latency = 0.2 -- a real DataStore call takes a moment: the refund lands while the leave save runs
	local okLeave = pcall(function()
		leave(ann)
		advance(4)
	end)
	DSt.Latency = 0
	local rec = stored(F.ids.Ann) or {}
	T.check(okLeave and rec.Cash == keep.Cash, "flow rejoin: leaving refunds the Snacks still cooking (into the save)", tostring(rec.Cash) .. " vs " .. keep.Cash)
	T.check(SS.GetOwner(annOld) == nil and annInfo.NameLabel.Text == "Free home" and annInfo.SubLabel.Text == "Press E at the gate" and #stationIds(annInfo) == 0
		and claimPromptOf(annOld) and claimPromptOf(annOld).Enabled == true, "flow rejoin: Ann's plot is released and cleared (Free home, no stations, the ClaimPrompt is back)",
		table.concat(stationIds(annInfo), ","))

	-- Cid comes back and takes Ann's old plot (his own last plot is free: "Welcome back")
	local mark = K.logSize()
	local cid = join("Cid")
	advance(5)
	T.check(toasted(cid, "Welcome back! Press E at your gate (#" .. tostring(F.plot.Cid) .. ")", mark), "flow rejoin: Cid gets 'Welcome back! Press E at your gate'")
	claim(cid, annOld)
	advance(1.2)
	T.check(SS.GetSpot(cid) == annInfo and level(cid, "Press1") == 1 and stationModel(annInfo, "Press1") ~= nil
		and annInfo.NameLabel.Text == cid.DisplayName and annInfo.SubLabel.Text == "Home Level 1",
		"flow rejoin: Cid claims Ann's old plot and his Phase 2 build comes back there", annInfo.SubLabel.Text)
	T.eq(stepOf(cid), "collect", "flow rejoin: ...his tutorial resumes where he left it")
	local stCid = tut(cid)
	local cidCollector = padPosition(annInfo, "Collector")
	T.check(stCid and stCid.Target and stCid.Target.SpotIndex == annOld and typeof(stCid.Target.Position) == "Vector3" and cidCollector ~= nil
		and (stCid.Target.Position - cidCollector).Magnitude < 1, "flow rejoin: ...and its arrow points at the Collector pad of his new plot",
		stCid and stCid.Target and tostring(stCid.Target.SpotIndex) or "no target")

	-- Ann rejoins: her last plot is taken now
	mark = K.logSize()
	ann = join("Ann")
	advance(5)
	T.check(toasted(ann, "Pick a free home", mark, "info") and not toasted(ann, "Welcome back", mark), "flow rejoin: Ann's last plot is taken: 'Pick a free home'")
	local prof = DataS.GetProfile(ann)
	T.check(cash(ann) == keep.Cash and gems(ann) == keep.Gems and tokens(ann) == keep.Tokens and ann:GetAttribute(Config.Attr.Cash) == keep.Cash,
		"flow rejoin: Cash (with the refund), Gems and tokens are back")
	T.check(sameMap(DataS.GetFood(ann), keep.Food) and DataS.GetPetLevel(ann, PK.Make(F.eco, "Golden")) == keep.Golden
		and countKeys(prof.Hybrids) == keep.Hybrids and mapText((prof.Tiers or {})[F.eco]) == keep.Tiers,
		"flow rejoin: food, pet levels, the Golden copy and the hybrid are back")
	T.check(tut(ann) and tut(ann).Done == true, "flow rejoin: the finished tutorial stays finished")
	local h = home(ann)
	T.check(h and h.Prestige == 1 and sameMap(h.Stations, keep.Home.Stations) and sameMap(h.Garden, keep.Home.Garden) and sameMap(h.Gym, keep.Home.Gym),
		"flow rejoin: the saved home is intact (prestige, stations, garden, gym)")
	local sugg = SS.SuggestSpot(ann)
	local newIndex = nil
	for i, info in pairs(spots()) do
		if info == sugg then
			newIndex = i
		end
	end
	if not T.check(newIndex ~= nil and newIndex ~= annOld and SS.GetOwner(newIndex) == nil, "flow rejoin: the guide suggests another free plot") then
		return
	end
	mark = K.logSize()
	claim(ann, newIndex)
	F.plot.Ann = newIndex
	local newInfo = spots()[newIndex]
	advance(1.5)
	T.check(SS.GetSpot(ann) == newInfo and toasted(ann, "Rebuilt at Home Level " .. keep.Level, mark, "good"), "flow rejoin: E at that gate: 'Welcome home! Rebuilt at Home Level " .. keep.Level .. "'")
	local miss = {}
	for id, lv in pairs(keep.Home.Stations) do
		local m = stationModel(newInfo, id)
		if lv > 0 and (not m or m:GetAttribute("Level") ~= lv) then
			miss[#miss + 1] = id
		end
	end
	T.check(#miss == 0, "flow rejoin: every saved station stands on the new plot at its level", table.concat(miss, ","))
	T.check(newInfo.Folder:GetAttribute("Prestige") == 1 and newInfo.Folder:GetAttribute("HomeLevel") == keep.Level and newInfo.SubLabel.Text:find(STAR, 1, true) ~= nil,
		"flow rejoin: the nameplate and plot attributes show Home Level " .. keep.Level .. " and the star", newInfo.SubLabel.Text)
	T.eq(newInfo.Folder:GetAttribute("GardenPets"), "1=" .. PK.Make(F.eco, "Golden"), "flow rejoin: the Golden pet works in the Garden again (GardenPets)")
	local cook = cookPrompt(newInfo, "Snack")
	T.check(cook ~= nil and cook:GetAttribute("OwnerUserId") == ann.UserId, "flow rejoin: the rebuilt Kitchen has Ann's cook prompt again")
	T.check(abs(Ty.IncomePerSecond(ann) - keep.Income) < 1e-6, "flow rejoin: the same income as before leaving", Ty.IncomePerSecond(ann) .. " vs " .. keep.Income)
	if F.receipt then
		local G = Config.Gems.Products
		local saved2 = G[2].Id
		G[2].Id = 4398802
		local box = spawnCall(MPS.ProcessReceipt, F.receipt)
		K.waitFor(function()
			return box.done
		end, 30)
		G[2].Id = saved2
		T.check(box.done and box.ok and box.result == Enum.ProductPurchaseDecision.PurchaseGranted and gems(ann) == keep.Gems,
			"flow rejoin: an old purchase retried after the rejoin is known (PurchaseGranted, nothing added)")
	end

	-- DataStore merge the other way: Ben's previous server lands a late Prestige-1 Home while he plays at Prestige 0
	if ben and ben.Parent and F.plot.Ben then
		local benInfo = spots()[F.plot.Ben]
		DataS.Save(ben)
		local brec = stored(ben.UserId)
		if T.check(type(brec) == "table" and type(brec.Home) == "table" and brec.Home.Prestige == 0, "flow merge 2: (precondition) Ben's save is at Prestige 0") then
			local b0 = brec.Cash or 0
			brec.Home = { Level = 5, Prestige = 1, Stations = { Press1 = 3, Collector = 1, DecorLamps = 1 }, Garden = {}, Gym = {}, CollectorCash = 0, LastSeen = os.time() }
			brec.Cash = b0 + 777
			fund(ben, TC.PriceFor("House", 1))
			pressPad(ben, benInfo, "House")
			T.eq(level(ben, "House"), 1, "flow merge 2: (here) Ben builds his Cottage at Prestige 0")
			local cashNow = cash(ben) -- the session's Cash change since the save is b0 -> cashNow
			local mk = K.logSize()
			DataS.Save(ben)
			local s = stored(ben.UserId) or {}
			local sh = type(s.Home) == "table" and s.Home or {}
			T.check(sh.Prestige == 1 and type(sh.Stations) == "table" and sh.Stations.Press1 == 3 and sh.Stations.DecorLamps == 1 and sh.Stations.House == nil,
				"flow merge 2: the stored higher prestige wins the whole Home (this server's Cottage is void)", mapText(sh.Stations))
			T.eq(s.Cash, (b0 + 777) + (cashNow - b0), "flow merge 2: Cash still merges as a delta (+777 from the other server, this server's change on top)")
			advance(2.5)
			T.eq(cash(ben), s.Cash, "flow merge 2: ...and the live balance adopts it")
			local bh = home(ben)
			T.check(bh and bh.Prestige == 1 and bh.Stations.Press1 == 3 and bh.Stations.DecorLamps == 1 and bh.Stations.House == nil, "flow merge 2: Ben's live Home adopts it")
			local p1 = stationModel(benInfo, "Press1")
			T.check(p1 ~= nil and p1:GetAttribute("Level") == 3 and stationModel(benInfo, "DecorLamps") ~= nil and stationModel(benInfo, "House") == nil,
				"flow merge 2: ...the plot in the world follows (Press 1 Lv 3, the lanterns, no Cottage)")
			T.check(benInfo.Folder:GetAttribute("Prestige") == 1 and benInfo.SubLabel.Text:find(STAR, 1, true) ~= nil, "flow merge 2: ...the star on his nameplate", benInfo.SubLabel.Text)
			T.check(#K.remotesFor("ProfileSync", ben.UserId, mk) >= 1, "flow merge 2: ...and his client gets the new snapshot")
			local okU, whyU = X.Fuse.Unlocked(ben)
			T.check(okU == false and tostring(whyU):find("Build the Fusion Machine", 1, true) ~= nil, "flow merge 2: the Fusion Machine now only needs to be built (Prestige 1 reached)", tostring(whyU))
		end
	end

	-- everyone leaves; the plots are free again
	leave(ann)
	leave(ben)
	leave(cid)
	advance(2)
	local still = {}
	for _, name in ipairs({ "Ann", "Ben", "Cid" }) do
		local idx = F.plot[name]
		if idx and SS.GetOwner(idx) ~= nil then
			still[#still + 1] = name .. "#" .. idx
		end
	end
	T.check(#still == 0 and SS.GetOwner(newIndex) == nil and SS.GetOwner(annOld) == nil, "flow end: every plot of the flow is free again", table.concat(still, ","))
	K.endAllMatches()
	K.flushErrors("p2flow_rejoin")
	K.flushWarnings("p2flow_rejoin", ALLOWED_WARNINGS)
end)

return S
