-- smoke_p2_tycoon.lua: Phase 2 tycoon homes (ARCHITECTURE_V3.md "Phase 2: Tycoon homes" + "Phase 2 build contract":
-- server/Services/TycoonService.lua and the claim-by-E SpotService). Loaded by tools/smoke.py in the SERVER world;
-- every scenario runs on the booted game (Main.server.lua), with or without HomeBuilder (when HomeBuilder's pads are
-- missing, a stand-in BuyPrompt with the contract attributes is triggered instead):
--   p2tycoon_claim      TycoonService API + signals; nobody gets a plot on join (no SpotIndex, GetSpot nil, a side
--                       toast "press E at its gate"); every plot has a ClaimPrompt; free nameplates read "Free home" /
--                       "Press E at the gate"; E claims (GetSpot / GetPlot / attribute / folder owner / Claimed fires /
--                       nameplate "Home Level 0" with the owner's name); double claim, someone else's plot, claiming in a
--                       match and prompt spam are refused; GoToSpot: home when claimed, else just outside the nearest
--                       free gate; leaving releases the plot (nameplate free again, attributes cleared)
--   p2tycoon_progress   a full simulated progression on one plot: the free Press 1 + Collector from the pad, the 1 s
--                       income tick into the Collector (Vault cap respected), banking with HomeAction "Collect", a
--                       greedy buyer funded with AddCash who buys every cheapest unlocked pad (exact Cash per purchase,
--                       +1 Home Level each, the world build follows) until the Prestige pad unlocks; house tiers gated
--                       every 10 Home Levels ("Reach Home Level 10" refused even with the Cash), tier caps, the Garden
--                       (Economy pets earn with the prestige multiplier); Prestige: Cash and stations reset, decor and
--                       garden kept, +1 star (nameplate), Gems reward, x1.25 income, the Fusion Machine unlocks
--   p2tycoon_exploits   buying on someone else's plot (prompt + remote), buying without a plot, junk / negative / NaN /
--                       huge / wrong-type HomeAction arguments, GardenSet abuse (Combat pets, unowned keys, a second slot
--                       for a single copy, a pet in the Gym, locked slots, NaN slots), spam (one purchase per cooldown,
--                       one Collect payout, the burst budget), prestige before it is ready; Cash never goes negative
--   p2tycoon_offline    leave -> the plot is released; the saved LastSeen pays the Vault's offline earnings on rejoin with
--                       a "While you were away" toast (paid once); the saved build is restored on another plot
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local K = _G.K
local CONTEXT = (ARGS and ARGS.context) or "server"

local abs, floor = math.abs, math.floor

local S = {}
if CONTEXT ~= "server" then
	return S
end

local advance, config, mod = K.advance, K.config, K.mod
local STAR = "\226\152\133"

local function near(a, b, tol)
	return type(a) == "number" and type(b) == "number" and abs(a - b) <= (tol or 1e-6)
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

local function TS()
	return requireAt("server/Services/TycoonService")
end
local function TC()
	return requireAt("shared/TycoonCatalog")
end
local function PK()
	return requireAt("shared/PetKeys")
end

local userSeq = 0
local function join(prefix)
	userSeq = userSeq + 1
	local p = Mock.AddPlayer(prefix .. userSeq, 962000 + userSeq)
	advance(1.0)
	return p
end

local function rejoin(name, userId)
	local p = Mock.AddPlayer(name, userId)
	advance(1.0)
	return p
end

local function leave(p)
	if p and p.Parent then
		Mock.RemovePlayer(p)
	end
	advance(0.6)
end

local function spots()
	return (K.W.lobbyInfo and K.W.lobbyInfo.Spots) or {}
end

local function freeIndex(skip)
	local SS = mod("SpotService")
	for i = 1, config().Lobby.SpotCount do
		if spots()[i] and not SS.GetOwner(i) and i ~= skip then
			return i
		end
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

-- The BuyPrompt of a station's pad on a plot: HomeBuilder's, or a stand-in with the contract attributes.
local function buyPromptOf(index, stationId, ownerId)
	local info = spots()[index]
	for _, d in ipairs(info.Folder:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "BuyPrompt" then
			local node, id = d, nil
			for _ = 1, 6 do
				if not node then
					break
				end
				id = node:GetAttribute("StationId")
				if id ~= nil then
					break
				end
				node = node.Parent
			end
			if id == stationId then
				return d, false
			end
		end
	end
	local pad = Instance.new("Model")
	pad.Name = "Pad_" .. stationId
	pad:SetAttribute("StationId", stationId)
	pad:SetAttribute("OwnerUserId", ownerId)
	local part = Instance.new("Part")
	part.Name = "PadBase"
	part.Anchored = true
	part.Parent = pad
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BuyPrompt"
	prompt.ActionText = "Buy"
	prompt.HoldDuration = 0.25
	prompt:SetAttribute("StationId", stationId)
	prompt:SetAttribute("OwnerUserId", ownerId)
	prompt.Parent = part
	pad.Parent = info.Folder
	return prompt, true
end

local function remote(name)
	return K.remoteFolder():FindFirstChild(name)
end

local function homeAction(p, action, arg)
	Mock.FromClient(remote("HomeAction"), p, action, arg)
end

local function stationModels(index)
	local out = {}
	local info = spots()[index]
	for _, d in ipairs(info.Folder:GetDescendants()) do
		local id = d.Name:match("^Station_(.+)$")
		if id and (d:IsA("Model") or d:IsA("Folder") or d:IsA("BasePart")) then
			out[id] = d
		end
	end
	return out
end

local function hasHomeBuilder()
	return K.moduleInstance("server/Services/HomeBuilder") ~= nil
end

local function cashOf(p)
	return mod("DataService").GetCash(p)
end

local function stationsText(home)
	local parts = {}
	for id, lv in pairs((home and home.Stations) or {}) do
		parts[#parts + 1] = id .. "=" .. tostring(lv)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

-- an Economy and a Combat pet from the catalog (not Secret: plain roulette pets)
local function petsByRole()
	local PC = K.M["shared/PetCatalog"]
	local eco, combat = nil, nil
	for _, def in ipairs(PC.Pets) do
		if def.Rarity ~= "Secret" then
			if def.Role == "Economy" and not eco then
				eco = def
			elseif def.Role == "Combat" and not combat then
				combat = def
			end
		end
	end
	return eco, combat
end

local function givePet(p, key, n)
	local DataS = mod("DataService")
	local prof = DataS.GetProfile(p)
	local ok = PK().Add(prof, key, n or 1)
	DataS.MarkDirty(p)
	return ok
end

-- walks to the gate (just outside it, like a player) and presses E on its ClaimPrompt
local function claim(p, index)
	local prompt = claimPromptOf(index)
	local SS = mod("SpotService")
	local gate = SS.GateCFrame(spots()[index])
	if gate and p.Character then
		Mock.Teleport(p, gate * CFrame.new(0, 3, -5))
	end
	if prompt then
		Mock.Trigger(prompt, p)
	end
	advance(0.6) -- past the claim cooldown
	return prompt ~= nil
end

----------------------------------------------------------------------------------------------------
-- p2tycoon_claim
----------------------------------------------------------------------------------------------------
S.p2tycoon_claim = guarded("p2tycoon_claim", function()
	if not K.needBoot() then
		return
	end
	local Config = config()
	local SS = mod("SpotService")
	local Ty = TS()
	if not T.check(Ty ~= nil, "tycoon: server/Services/TycoonService.lua loads") then
		return
	end
	for _, fn in ipairs({ "Init", "GetPlot", "GetHome", "Buy", "Collect", "Prestige", "IncomePerSecond", "Claim", "Release", "GardenSet" }) do
		T.check(type(Ty[fn]) == "function", "tycoon: TycoonService." .. fn .. " is a function")
	end
	for _, sig in ipairs({ "HomeChanged", "Claimed", "Prestiged" }) do
		T.check(type(Ty[sig]) == "table" and type(Ty[sig].Connect) == "function", "tycoon: signal TycoonService." .. sig)
	end
	for _, fn in ipairs({ "Claim", "Release", "GetOwner", "GetSpotByIndex", "FindFreeSpot", "SuggestSpot", "GateCFrame" }) do
		T.check(type(SS[fn]) == "function", "tycoon: SpotService." .. fn .. " is a function")
	end
	T.check(remote("HomeAction") ~= nil, "tycoon: the HomeAction remote exists")

	-- every plot has a ClaimPrompt and free plots read "Free home" / "Press E at the gate"
	local count = Config.Lobby.SpotCount
	local prompts = T.tally("tycoon: every plot's gate has a ClaimPrompt (SpotIndex attribute)")
	local labels = T.tally("tycoon: every free plot reads 'Free home' / 'Press E at the gate'")
	for i = 1, count do
		local info = spots()[i]
		if info then
			local prompt = claimPromptOf(i)
			prompts:case(prompt ~= nil and (prompt:GetAttribute("SpotIndex") == i or prompt:IsDescendantOf(info.Folder)), "plot " .. i)
			if not SS.GetOwner(i) then
				labels:case(info.NameLabel.Text == "Free home" and info.SubLabel.Text == "Press E at the gate",
					"plot " .. i .. ": " .. tostring(info.NameLabel.Text) .. " / " .. tostring(info.SubLabel.Text))
			end
		end
	end
	prompts:report()
	labels:report()

	-- join: no plot, a side toast tells them to press E
	local mark = K.logSize()
	local a = join("TyClaimA")
	T.check(SS.GetSpot(a) == nil and a:GetAttribute(Config.Attr.SpotIndex) == nil and Ty.GetPlot(a) == nil,
		"tycoon: joining does not hand out a plot (GetSpot nil, no SpotIndex attribute)")
	advance(5)
	T.check(K.notified(a, "press E at its gate", nil, mark), "tycoon: a new player gets the side toast 'Pick a free home: press E at its gate'")

	-- GoToSpot without a plot: just outside the nearest free gate
	local root = K.root(a)
	local suggested = SS.SuggestSpot(a)
	Mock.FromClient(remote("GoToSpot"), a)
	advance(0.5)
	local gate = suggested and SS.GateCFrame(suggested)
	T.check(gate ~= nil and root ~= nil and K.planar(K.root(a).Position, gate.Position) <= 10 and SS.GetSpot(a) == nil,
		"tycoon: GoToSpot without a plot puts the player just outside a free gate (and claims nothing)",
		gate and K.root(a) and string.format("%.1f studs from the gate", K.planar(K.root(a).Position, gate.Position)) or "no gate")

	-- E at the gate claims it
	local index = freeIndex()
	local claimedArgs = nil
	local conn = Ty.Claimed:Connect(function(p, info)
		claimedArgs = { p, info }
	end)
	mark = K.logSize()
	T.check(claim(a, index), "tycoon: (precondition) plot " .. tostring(index) .. " has a ClaimPrompt")
	conn:Disconnect()
	local info = spots()[index]
	T.check(SS.GetSpot(a) == info and Ty.GetPlot(a) == info and a:GetAttribute(Config.Attr.SpotIndex) == index,
		"tycoon: E at the gate claims the plot (GetSpot, GetPlot, SpotIndex attribute)")
	T.check(SS.GetOwner(index) == a and info.Folder:GetAttribute("OwnerUserId") == a.UserId, "tycoon: ...the plot folder carries OwnerUserId")
	T.check(claimedArgs ~= nil and claimedArgs[1] == a and claimedArgs[2] == info, "tycoon: TycoonService.Claimed fired (player, spotInfo)")
	T.check(mod("DataService").GetProfile(a).SpotIndex == index, "tycoon: the profile remembers the last plot (SpotIndex)")
	advance(1.2)
	T.eq(info.NameLabel.Text, a.DisplayName, "tycoon: the nameplate shows the owner")
	T.eq(info.SubLabel.Text, "Home Level 0", "tycoon: ...and 'Home Level 0' for a new home")
	T.check(K.notified(a, "Welcome home", "good", mark), "tycoon: a 'Welcome home' side toast")
	T.eq(claimPromptOf(index).Enabled, false, "tycoon: the gate's ClaimPrompt turns off once the plot is claimed")

	-- double claim, someone else's plot, claiming in a match, spam
	local other = freeIndex(index)
	mark = K.logSize()
	claim(a, other)
	T.check(SS.GetSpot(a) == info and SS.GetOwner(other) == nil, "tycoon: a second claim is refused (one plot per player)")
	T.check(K.notified(a, "already have a home", "bad", mark), "tycoon: ...with a toast")
	local b = join("TyClaimB")
	mark = K.logSize()
	claim(b, index)
	T.check(SS.GetOwner(index) == a and SS.GetSpot(b) == nil, "tycoon: nobody can claim a plot that is taken")
	T.check(K.notified(b, "belongs to", "bad", mark), "tycoon: ...the toast names the owner")
	b:SetAttribute(Config.Attr.InMatch, true)
	claim(b, other)
	T.check(SS.GetSpot(b) == nil and SS.GetOwner(other) == nil, "tycoon: claiming is refused during a match")
	b:SetAttribute(Config.Attr.InMatch, false)
	Mock.Teleport(b, config().Lobby.Origin + Vector3.new(0, 4, 0))
	Mock.Trigger(claimPromptOf(other), b)
	advance(0.6)
	T.check(SS.GetSpot(b) == nil and SS.GetOwner(other) == nil, "tycoon: a ClaimPrompt triggered from far away (the plaza) claims nothing")
	local gateOther = SS.GateCFrame(spots()[other])
	Mock.Teleport(b, gateOther * CFrame.new(0, 3, -5))
	local prompt = claimPromptOf(other)
	for _ = 1, 25 do
		Mock.Trigger(prompt, b)
	end
	local third = freeIndex(other)
	Mock.Teleport(b, SS.GateCFrame(spots()[third]) * CFrame.new(0, 3, -5))
	Mock.Trigger(claimPromptOf(third), b)
	advance(0.6)
	T.check(SS.GetSpot(b) == spots()[other] and SS.GetOwner(third) == nil, "tycoon: 25 claim presses in one frame claim exactly one plot")

	-- GoToSpot with a plot: home
	Mock.FromClient(remote("GoToSpot"), a)
	advance(0.5)
	T.check(K.planar(K.root(a).Position, info.SpawnCFrame.Position) <= 6, "tycoon: GoToSpot with a plot goes home (the plot's spawn)")
	advance(0.5)
	homeAction(b, "GoHome")
	advance(0.5)
	T.check(K.planar(K.root(b).Position, spots()[other].SpawnCFrame.Position) <= 6, "tycoon: HomeAction 'GoHome' goes home too")

	-- leaving releases the plot
	leave(b)
	advance(1.2)
	local oi = spots()[other]
	T.check(SS.GetOwner(other) == nil and oi.NameLabel.Text == "Free home" and oi.SubLabel.Text == "Press E at the gate"
		and oi.Folder:GetAttribute("OwnerUserId") == nil and oi.Folder:GetAttribute("HomeLevel") == nil,
		"tycoon: leaving releases the plot ('Free home' / 'Press E at the gate', attributes cleared)")
	local stale = 0
	for _ in pairs(stationModels(other)) do
		stale = stale + 1
	end
	T.eq(stale, 0, "tycoon: ...and no station of the old build stays on it")
	T.eq(claimPromptOf(other).Enabled, true, "tycoon: ...and back on when the plot is released")
	local c = join("TyClaimC")
	claim(c, other)
	T.check(SS.GetSpot(c) == oi, "tycoon: a released plot can be claimed again")
	leave(c)
	leave(a)
	T.check(SS.GetOwner(index) == nil, "tycoon: (cleanup) plots free again")
	K.flushErrors("p2tycoon_claim")
	K.flushWarnings("p2tycoon_claim", { "HomeBuilder is missing" })
end)

----------------------------------------------------------------------------------------------------
-- p2tycoon_progress
----------------------------------------------------------------------------------------------------
S.p2tycoon_progress = guarded("p2tycoon_progress", function()
	if not K.needBoot() then
		return
	end
	local Config = config()
	local SS, DataS = mod("SpotService"), mod("DataService")
	local Ty, Cat = TS(), TC()
	if not Ty or not Cat then
		T.fail("tycoon: TycoonService and TycoonCatalog load")
		return
	end
	local p = join("TyProg")
	local index = freeIndex()
	claim(p, index)
	local info = spots()[index]
	if not T.check(SS.GetSpot(p) == info, "tycoon progress: (precondition) the plot is claimed") then
		leave(p)
		return
	end
	local withBuilder = hasHomeBuilder()
	T.info("*HomeBuilder " .. (withBuilder and "present: pads and stations are HomeBuilder's" or "absent: stand-in BuyPrompts"))

	-- the free first press from its pad (E on the BuyPrompt)
	local cash0 = cashOf(p)
	local prompt, fake = buyPromptOf(index, "Press1", p.UserId)
	if withBuilder then
		T.check(not fake and prompt:GetAttribute("OwnerUserId") == p.UserId, "tycoon progress: the claim put HomeBuilder's Press 1 pad (BuyPrompt, OwnerUserId) on the plot")
	end
	Mock.Trigger(prompt, p)
	advance(0.3)
	local home = Ty.GetHome(p)
	T.check(home and home.Stations.Press1 == 1 and cashOf(p) == cash0, "tycoon progress: the first Cloud Press is free from its pad (BuyPrompt)",
		stationsText(home))
	if fake then
		prompt.Parent.Parent:Destroy()
	end
	prompt, fake = buyPromptOf(index, "Collector", p.UserId)
	Mock.Trigger(prompt, p)
	advance(0.3)
	if fake then
		prompt.Parent.Parent:Destroy()
	end
	home = Ty.GetHome(p)
	T.check(home.Stations.Collector == 1 and home.Level == 2, "tycoon progress: the Collector (free) next: Home Level 2", stationsText(home))
	if withBuilder then
		local models = stationModels(index)
		T.check(models.Press1 ~= nil and models.Collector ~= nil and models.Press1:GetAttribute("Level") == 1,
			"tycoon progress: the stations stand on the plot (Station_Press1 / Station_Collector, Level attribute)")
	end

	-- income tick into the Collector
	local income = Ty.IncomePerSecond(p)
	T.check(near(income, 5, 1e-6), "tycoon progress: IncomePerSecond = Press 1 L1 (5 Cash/s)", tostring(income))
	DataS.MutateHome(p, function(h)
		h.CollectorCash = 0
	end)
	advance(4.05)
	home = Ty.GetHome(p)
	T.check(home.CollectorCash >= 15 - 0.01 and home.CollectorCash <= 25 + 0.01, "tycoon progress: the 1 s tick fills the Collector (~5/s)", tostring(home.CollectorCash))
	T.eq(info.Folder:GetAttribute("CollectorCash"), floor(home.CollectorCash), "tycoon progress: the plot folder replicates CollectorCash")
	T.check(near(info.Folder:GetAttribute("IncomePerSecond"), 5, 0.05), "tycoon progress: ...and IncomePerSecond")
	local before = cashOf(p)
	local inCollector = floor(home.CollectorCash)
	local mark = K.logSize()
	homeAction(p, "Collect")
	advance(0.1)
	home = Ty.GetHome(p)
	T.eq(cashOf(p) - before, inCollector, "tycoon progress: HomeAction 'Collect' banks the whole Cash of the Collector")
	T.check(home.CollectorCash < 1 + income * 1.5, "tycoon progress: ...the Collector is empty afterwards (at most one new tick)", tostring(home.CollectorCash))
	T.check(K.notified(p, "banked", "good", mark), "tycoon progress: ...with a 'banked' side toast")

	-- the cap (Collector + Vault)
	local cap = Ty.CollectorCap(p)
	DataS.MutateHome(p, function(h)
		h.CollectorCash = cap - 2
	end)
	advance(3.1)
	home = Ty.GetHome(p)
	T.check(near(home.CollectorCash, cap, 1e-6), "tycoon progress: the Collector stops at its cap (" .. cap .. ")", tostring(home.CollectorCash))
	homeAction(p, "Collect")
	advance(0.6)

	-- the Collector's own prompt / step-on pad (HomeBuilder's, or added here when the Collector model has none)
	local station, cp, pad = nil, nil, nil
	if withBuilder then
		station = stationModels(index).Collector
		for _, d in ipairs(station and station:GetDescendants() or {}) do
			if d:IsA("ProximityPrompt") and d.Name ~= "BuyPrompt" then
				cp = d
			elseif d.Name == "CollectPad" and d:IsA("BasePart") then
				pad = d
			end
		end
		T.check(cp ~= nil and pad ~= nil, "tycoon progress: HomeBuilder's Collector has a Collect prompt and a CollectPad")
	else
		station = Instance.new("Model")
		station.Name = "Station_Collector"
		station:SetAttribute("StationId", "Collector")
		local body = Instance.new("Part")
		body.Name = "Body"
		body.Anchored = true
		body.Parent = station
		station.PrimaryPart = body
		pad = Instance.new("Part")
		pad.Name = "CollectPad"
		pad.Anchored = true
		pad.Parent = station
		station.Parent = info.Folder
		DataS.AddCash(p, Cat.PriceFor("Press1", 2))
		Ty.Buy(p, "Press1") -- a station change rescans the plot
		cp = body:FindFirstChild("CollectPrompt")
		T.check(cp ~= nil and cp:IsA("ProximityPrompt") and cp.ActionText == "Collect", "tycoon progress: a Collector without a prompt gets a 'Collect' prompt")
	end
	if station then
		if cp then
			DataS.MutateHome(p, function(h)
				h.CollectorCash = 30
			end)
			local c0 = cashOf(p)
			Mock.Trigger(cp, p)
			T.eq(cashOf(p) - c0, 30, "tycoon progress: E at the Collector banks it")
			advance(0.6)
		end
		local stranger = join("TyStranger")
		DataS.MutateHome(p, function(h)
			h.CollectorCash = 20
		end)
		local c1 = cashOf(p)
		if cp then
			Mock.Trigger(cp, stranger)
		end
		if pad then
			Mock.Touch(pad, K.root(stranger))
		end
		T.check(cashOf(p) == c1 and cashOf(stranger) == 0 and Ty.GetHome(p).CollectorCash >= 20, "tycoon progress: nobody else can bank someone's Collector")
		if pad then
			Mock.Touch(pad, K.root(p))
			T.check(cashOf(p) - c1 >= 20, "tycoon progress: stepping on the Collector pad banks it", tostring(cashOf(p) - c1))
		end
		leave(stranger)
		if not withBuilder then
			station:Destroy()
		end
	end

	-- greedy buyer: AddCash stands in for hours of income; always buys the cheapest unlocked pad
	local Eco, Combat = petsByRole()
	local purchases, problems, deadEnd = 0, {}, nil
	local sawHouseGate, sawTierCap, gardenDone = false, false, false
	local gardenIncome = nil
	for _ = 1, 400 do
		home = Ty.GetHome(p)
		if Cat.CanPrestige(home) then
			break
		end
		local best = nil
		for _, pad in ipairs(Cat.AvailablePads(home)) do
			if not pad.Prestige then
				if pad.Locked == nil then
					if not best or pad.Price < best.Price then
						best = pad
					end
				elseif pad.StationId == "House" and pad.Locked:find("Reach Home Level", 1, true) and not sawHouseGate then
					-- the house tier gate: refused even with the Cash in hand
					sawHouseGate = true
					DataS.AddCash(p, pad.Price)
					local c = cashOf(p)
					local ok, reason = Ty.Buy(p, "House")
					local h2 = Ty.GetHome(p)
					if ok or cashOf(p) ~= c or h2.Stations.House ~= home.Stations.House or not tostring(reason):find("Reach Home Level", 1, true) then
						problems[#problems + 1] = "house gate bypassed at Home Level " .. Cat.HomeLevelOf(home) .. " (" .. tostring(reason) .. ")"
					end
					DataS.SpendCash(p, pad.Price)
				elseif pad.Locked:find("Needs the", 1, true) and pad.StationId:find("^Press") then
					sawTierCap = true
				end
			end
		end
		if not best then
			deadEnd = "Home Level " .. Cat.HomeLevelOf(home) .. ": " .. stationsText(home)
			break
		end
		if best.Price > 0 then
			DataS.AddCash(p, best.Price)
		end
		local c = cashOf(p)
		local level = Cat.StationLevel(home, best.StationId)
		local ok, result = Ty.Buy(p, best.StationId)
		local after = Ty.GetHome(p)
		purchases = purchases + 1
		if not ok then
			problems[#problems + 1] = best.StationId .. " refused: " .. tostring(result)
		elseif c - cashOf(p) ~= best.Price or Cat.StationLevel(after, best.StationId) ~= level + 1 or after.Level ~= Cat.HomeLevelOf(after)
			or Cat.HomeLevelOf(after) ~= Cat.HomeLevelOf(home) + 1 then
			problems[#problems + 1] = best.StationId .. ": paid " .. (c - cashOf(p)) .. " of " .. best.Price .. ", level " .. Cat.StationLevel(after, best.StationId)
		end
		-- the Garden: an Economy pet earns there
		if ok and not gardenDone and Cat.GardenSlots(after) >= 1 and Eco then
			gardenDone = true
			givePet(p, Eco.Id, 1)
			local base = Ty.IncomePerSecond(p)
			Mock.FromClient(remote("HomeAction"), p, "GardenSet", { 1, Eco.Id })
			advance(0.3)
			local h3 = Ty.GetHome(p)
			gardenIncome = Ty.IncomePerSecond(p) - base
			T.check(h3.Garden[1] == Eco.Id and near(gardenIncome, Cat.PetIncome(Eco, 1), 1e-6),
				"tycoon progress: an Economy pet placed in the Garden (HomeAction GardenSet) earns its Income x rarity",
				tostring(h3.Garden[1]) .. " +" .. tostring(gardenIncome))
			T.eq(info.Folder:GetAttribute("GardenPets"), "1=" .. Eco.Id, "tycoon progress: the plot folder replicates GardenPets")
		end
	end
	T.check(#problems == 0, "tycoon progress: every purchase takes exactly its price and adds one Home Level (" .. purchases .. " purchases)",
		table.concat(problems, " | "))
	T.check(deadEnd == nil, "tycoon progress: no dead end on the way to Prestige", deadEnd)
	T.check(sawHouseGate, "tycoon progress: the next house is refused below its Home Level ('Reach Home Level 10')")
	T.check(sawTierCap, "tycoon progress: station caps follow the house tier ('Needs the Villa')")
	home = Ty.GetHome(p)
	T.check(Cat.CanPrestige(home) and Cat.StationLevel(home, "House") == 4 and Cat.HomeLevelOf(home) >= 40,
		"tycoon progress: the Sky Castle and Home Level 40 reached (" .. Cat.HomeLevelOf(home) .. ")")
	local _, _, fusionReason = Cat.CheckPurchase(home, "FusionMachine")
	T.check(fusionReason == "Unlocks at Prestige 1", "tycoon progress: the Fusion Machine is locked before Prestige 1", tostring(fusionReason))
	if withBuilder then
		local models = stationModels(index)
		local miss = {}
		for id, lv in pairs(home.Stations) do
			if lv > 0 and (not models[id] or models[id]:GetAttribute("Level") ~= lv) then
				miss[#miss + 1] = id
			end
		end
		T.check(#miss == 0, "tycoon progress: every built station stands on the plot at its level", table.concat(miss, ","))
	end
	advance(1.2)
	T.eq(info.SubLabel.Text, "Home Level " .. Cat.HomeLevelOf(home), "tycoon progress: the nameplate follows the Home Level")

	-- Prestige
	DataS.AddCash(p, 12345)
	local gemsBefore = DataS.GetGems(p)
	local decor = {}
	for _, def in ipairs(Cat.Stations) do
		if def.KeepOnPrestige then
			decor[def.Id] = Cat.StationLevel(home, def.Id)
		end
	end
	local pres = nil
	local conn = Ty.Prestiged:Connect(function(pl, stars)
		pres = { pl, stars }
	end)
	mark = K.logSize()
	homeAction(p, "Prestige")
	advance(0.3)
	conn:Disconnect()
	local after = Ty.GetHome(p)
	T.check(after.Prestige == 1 and pres ~= nil and pres[1] == p and pres[2] == 1, "tycoon prestige: +1 star and Prestiged(player, 1)")
	T.eq(cashOf(p), 0, "tycoon prestige: Cash resets to 0")
	T.eq(DataS.GetGems(p) - gemsBefore, Cat.PrestigeGems(1), "tycoon prestige: the Gems reward")
	local wrong = {}
	for _, def in ipairs(Cat.Stations) do
		local want = decor[def.Id] or 0
		if Cat.StationLevel(after, def.Id) ~= want then
			wrong[#wrong + 1] = def.Id .. "=" .. Cat.StationLevel(after, def.Id)
		end
	end
	T.check(#wrong == 0, "tycoon prestige: stations reset, decor kept", table.concat(wrong, ","))
	T.check(after.CollectorCash == 0 and after.Level == Cat.HomeLevelOf(after), "tycoon prestige: the Collector is emptied, Home Level = the decor")
	T.check(Eco == nil or after.Garden[1] == Eco.Id, "tycoon prestige: garden choices are kept")
	T.check(K.notified(p, "Prestige 1", "good", mark), "tycoon prestige: a side toast")
	advance(1.2)
	T.check(info.SubLabel.Text:find(STAR, 1, true) ~= nil, "tycoon prestige: the nameplate shows a prestige star", info.SubLabel.Text)
	if withBuilder then
		local models = stationModels(index)
		T.check(models.Press1 == nil and models.House == nil, "tycoon prestige: the reset stations leave the plot")
	end

	-- x1.25 income, the Fusion Machine unlocks
	Ty.Buy(p, "Press1")
	Ty.Buy(p, "Collector")
	local inc = Ty.IncomePerSecond(p)
	local gardenNow = Cat.GardenSlots(Ty.GetHome(p)) > 0 and (gardenIncome or 0) or 0
	T.check(near(inc, (5 + gardenNow) * 1.25, 1e-6), "tycoon prestige: income x1.25 per star", tostring(inc))
	local probe = Ty.GetHome(p)
	probe.Stations.Kitchen = 1 -- a copy: the Fusion Machine's tree needs the Kitchen
	local okFusion, _, reason2 = Cat.CheckPurchase(probe, "FusionMachine")
	T.check(okFusion == true, "tycoon prestige: the Fusion Machine pad unlocks at Prestige 1 (with its Kitchen)", tostring(reason2))
	DataS.MutateHome(p, function(h)
		h.CollectorCash = 0
	end)
	advance(4.05)
	local cc = Ty.GetHome(p).CollectorCash
	T.check(cc >= 3 * 6.25 - 0.01 and cc <= 5 * 6.25 + 0.01, "tycoon prestige: the Collector fills at the multiplied rate", tostring(cc))
	leave(p)
	K.flushErrors("p2tycoon_progress")
	K.flushWarnings("p2tycoon_progress", { "HomeBuilder is missing" })
end)

----------------------------------------------------------------------------------------------------
-- p2tycoon_exploits
----------------------------------------------------------------------------------------------------
S.p2tycoon_exploits = guarded("p2tycoon_exploits", function()
	if not K.needBoot() then
		return
	end
	local SS, DataS = mod("SpotService"), mod("DataService")
	local Ty, Cat = TS(), TC()
	if not Ty or not Cat then
		T.fail("tycoon: TycoonService and TycoonCatalog load")
		return
	end
	local a = join("TyOwner")
	local b = join("TyThief")
	local ia = freeIndex()
	claim(a, ia)
	local ib = freeIndex(ia)
	claim(b, ib)
	Ty.Buy(a, "Press1")
	Ty.Buy(a, "Collector")
	advance(0.3)

	-- buying on someone else's plot
	DataS.AddCash(b, 5000)
	local homeA = Ty.GetHome(a)
	local cashB = cashOf(b)
	local prompt, fake = buyPromptOf(ia, "Press1", a.UserId)
	Mock.Trigger(prompt, b)
	advance(0.3)
	T.check(Ty.GetHome(a).Stations.Press1 == homeA.Stations.Press1 and cashOf(b) == cashB and (Ty.GetHome(b).Stations.Press1 or 0) == 0,
		"tycoon exploits: a BuyPrompt on someone else's plot buys nothing (for nobody)")
	if fake then
		-- a stand-in pad that claims to be the thief's, inside the owner's plot
		prompt:SetAttribute("OwnerUserId", b.UserId)
		prompt.Parent.Parent:SetAttribute("OwnerUserId", b.UserId)
		Mock.Trigger(prompt, b)
		advance(0.3)
		T.check(Ty.GetHome(a).Stations.Press1 == homeA.Stations.Press1 and cashOf(b) == cashB and (Ty.GetHome(b).Stations.Press1 or 0) == 0,
			"tycoon exploits: ...even when the pad's OwnerUserId names the thief (the plot decides)")
		prompt.Parent.Parent:Destroy()
	end
	T.check(SS.GetOwner(ia) == a, "tycoon exploits: the plot still belongs to its owner")

	-- no plot: no purchases
	local c = join("TyNoPlot")
	DataS.AddCash(c, 1000)
	homeAction(c, "Upgrade", "Press1")
	advance(0.3)
	local okNo, reasonNo = Ty.Buy(c, "Press1")
	T.check(not okNo and (Ty.GetHome(c).Stations.Press1 or 0) == 0 and cashOf(c) == 1000 and tostring(reasonNo):find("Claim a home", 1, true) ~= nil,
		"tycoon exploits: no purchases without a claimed plot", tostring(reasonNo))

	-- junk HomeAction arguments
	local junk = {
		{ 5, "Press1" }, { nil, nil }, { {}, "x" }, { string.rep("U", 500), "Press1" },
		{ "Upgrade", 0 / 0 }, { "Upgrade", -1 }, { "Upgrade", math.huge }, { "Upgrade", {} }, { "Upgrade", "Nope" },
		{ "Upgrade", string.rep("x", 1000) }, { "Upgrade", "Prestige" }, { "Upgrade", "ArenaGate" }, { "Upgrade", "FusionMachine" },
		{ "GardenSet", 0 / 0 }, { "GardenSet", { 0 / 0, "x" } }, { "GardenSet", { -1, "x" } }, { "GardenSet", { math.huge } },
		{ "GardenSet", { "1", "x" } }, { "GardenSet", { 1.5, "x" } }, { "GardenSet", "1" }, { "GardenSet", { Slot = {}, Key = {} } },
		{ "Prestige", {} }, { "GoHome", 0 / 0 }, { "Teleport", 1 }, { "AddCash", 1e9 },
	}
	local cashA, cashC = cashOf(a), cashOf(c)
	local before = stationsText(Ty.GetHome(a))
	for i, args in ipairs(junk) do
		homeAction(a, args[1], args[2])
		homeAction(c, args[1], args[2])
		if i % 4 == 0 then
			advance(0.6)
		end
	end
	advance(0.6)
	T.check(stationsText(Ty.GetHome(a)) == before and cashOf(a) == cashA and cashOf(c) == cashC and cashOf(a) >= 0,
		"tycoon exploits: junk / negative / NaN / huge / wrong-type HomeAction arguments change nothing",
		stationsText(Ty.GetHome(a)) .. " cash " .. cashOf(a))

	-- spam: one purchase per cooldown, the burst budget
	local price2 = Cat.PriceFor("Press1", 2)
	DataS.AddCash(a, price2 * 3)
	local cash1 = cashOf(a)
	for _ = 1, 50 do
		homeAction(a, "Upgrade", "Press1")
	end
	advance(0.05)
	T.check(Ty.GetHome(a).Stations.Press1 == 2 and cash1 - cashOf(a) == price2, "tycoon exploits: 50 'Upgrade' requests in one frame buy exactly one level",
		"level " .. tostring(Ty.GetHome(a).Stations.Press1) .. ", paid " .. (cash1 - cashOf(a)))
	advance(1.0)
	DataS.MutateHome(a, function(h)
		h.CollectorCash = 40.5
	end)
	cash1 = cashOf(a)
	for _ = 1, 30 do
		homeAction(a, "Collect")
		Ty.Collect(a)
	end
	local left = Ty.GetHome(a).CollectorCash
	T.check(cashOf(a) - cash1 == 40 and near(left, 0.5, 1e-6), "tycoon exploits: 60 collects in one frame pay the Collector out once (whole Cash only)",
		"paid " .. (cashOf(a) - cash1) .. ", left " .. tostring(left))
	advance(2.0)

	-- not enough cash: refused, nothing taken; never negative
	local need = Cat.PriceFor("Press1", 3)
	local have = cashOf(a)
	if have >= need then
		DataS.SpendCash(a, have - need + 1)
	end
	have = cashOf(a)
	local okPoor, whyPoor = Ty.Buy(a, "Press1")
	T.check(not okPoor and cashOf(a) == have and Ty.GetHome(a).Stations.Press1 == 2 and tostring(whyPoor):find("Not enough Cash", 1, true) ~= nil,
		"tycoon exploits: a purchase without enough Cash is refused and takes nothing", tostring(whyPoor))

	-- prestige before it is ready
	local okP, whyP = Ty.Prestige(a)
	T.check(not okP and Ty.GetHome(a).Prestige == 0 and cashOf(a) == have, "tycoon exploits: Prestige before Home Level 40 + Sky Castle is refused", tostring(whyP))

	-- GardenSet abuse
	local Eco, Combat = petsByRole()
	DataS.MutateHome(a, function(h)
		h.Stations.Press2 = 2
		h.Stations.Garden = 1
		h.Level = Cat.HomeLevelOf(h)
	end)
	advance(1.2)
	if Eco and Combat then
		givePet(a, Eco.Id, 1)
		givePet(a, Combat.Id, 1)
		local ok1 = Ty.GardenSet(a, 1, Combat.Id)
		local ok2, why2 = Ty.GardenSet(a, 1, "ghost_pet_404")
		local ok3, why3 = Ty.GardenSet(a, 2, Eco.Id)
		local ok4 = Ty.GardenSet(a, 1, Eco.Id)
		local ok5, why5 = Ty.GardenSet(a, 1, Eco.Id .. "@Golden")
		local h = Ty.GetHome(a)
		T.check(not ok1 and not ok2 and h.Garden[1] == Eco.Id, "tycoon exploits: GardenSet refuses Combat pets and unknown keys", tostring(why2))
		T.check(not ok3 and tostring(why3):find("locked", 1, true) ~= nil, "tycoon exploits: GardenSet refuses a slot the Garden level has not unlocked", tostring(why3))
		T.check(ok4 and not ok5, "tycoon exploits: GardenSet refuses a tier copy the player does not own", tostring(why5))
		DataS.MutateHome(a, function(hh)
			hh.Stations.Garden = 2
		end)
		local ok6, why6 = Ty.GardenSet(a, 2, Eco.Id)
		T.check(not ok6 and tostring(why6):find("no free copy", 1, true) ~= nil and Ty.GetHome(a).Garden[2] == nil,
			"tycoon exploits: one copy cannot work in two garden slots", tostring(why6))
		givePet(a, Eco.Id, 1)
		DataS.MutateHome(a, function(hh)
			hh.Garden[1] = nil
			hh.Gym[1] = Eco.Id
		end)
		local ok7, why7 = Ty.GardenSet(a, 1, Eco.Id)
		T.check(not ok7 and tostring(why7):find("Gym", 1, true) ~= nil, "tycoon exploits: a pet training in the Gym cannot be placed in the Garden", tostring(why7))
		DataS.MutateHome(a, function(hh)
			hh.Gym[1] = nil
		end)
		local ok8 = Ty.GardenSet(a, 1, Eco.Id)
		local ok9 = Ty.GardenSet(a, 1, nil)
		T.check(ok8 and ok9 and Ty.GetHome(a).Garden[1] == nil, "tycoon exploits: GardenSet places and clears (nil) a slot")
		local okN = Ty.GardenSet(a, 0 / 0, Eco.Id)
		local okM = Ty.GardenSet(a, 999, Eco.Id)
		T.check(not okN and not okM, "tycoon exploits: NaN / out-of-range garden slots are refused")
		-- a garden pet that is no longer owned stops earning
		Ty.GardenSet(a, 1, Eco.Id)
		local with = Ty.IncomePerSecond(a)
		local prof = DataS.GetProfile(a)
		PK().Remove(prof, Eco.Id, PK().Count(prof, Eco.Id))
		local without = Ty.IncomePerSecond(a)
		T.check(without < with, "tycoon exploits: a garden pet that left the inventory stops earning", with .. " -> " .. without)
	else
		T.fail("tycoon exploits: (precondition) the catalog has an Economy and a Combat pet")
	end
	T.check(cashOf(a) >= 0 and cashOf(b) >= 0 and cashOf(c) >= 0, "tycoon exploits: Cash never goes negative")
	leave(a)
	leave(b)
	leave(c)
	K.flushErrors("p2tycoon_exploits")
	K.flushWarnings("p2tycoon_exploits", { "HomeBuilder is missing" })
end)

----------------------------------------------------------------------------------------------------
-- p2tycoon_offline
----------------------------------------------------------------------------------------------------
S.p2tycoon_offline = guarded("p2tycoon_offline", function()
	if not K.needBoot() then
		return
	end
	local SS, DataS = mod("SpotService"), mod("DataService")
	local Ty, Cat = TS(), TC()
	if not Ty or not Cat then
		T.fail("tycoon: TycoonService and TycoonCatalog load")
		return
	end
	local name, userId = "TyOffline", 963501
	local p = rejoin(name, userId)
	local first = freeIndex()
	claim(p, first)
	DataS.MutateHome(p, function(h)
		h.Stations.Press1 = 3
		h.Stations.Collector = 1
		h.Stations.Press2 = 2
		h.Stations.Vault = 1
		h.Level = Cat.HomeLevelOf(h)
	end)
	advance(1.2)
	local home = Ty.GetHome(p)
	local income = Ty.IncomePerSecond(p)
	T.check(income > 0 and Cat.StationLevel(home, "Vault") == 1, "tycoon offline: (precondition) a home with a Vault earns", tostring(income))
	advance(16) -- the periodic LastSeen refresh (every 15 s while online)
	local seen = Ty.GetHome(p).LastSeen or 0
	T.check(seen > 0 and os.time() - seen <= 16, "tycoon offline: LastSeen is refreshed while the player is online", tostring(seen))
	leave(p)
	advance(1.0)
	T.check(SS.GetOwner(first) == nil, "tycoon offline: leaving released the plot")
	local key = config().Tokens.DataStoreName .. "/u_" .. userId
	local rec = Mock.DataStore.Data[key]
	if not T.check(rec ~= nil and type(rec.Home) == "table" and (rec.Home.LastSeen or 0) > 0, "tycoon offline: the save holds Home.LastSeen") then
		return
	end
	local away = 2 * 3600
	rec.Home.LastSeen = os.time() - away
	local want = Cat.OfflineEarnings(home, away, income)
	local mark = K.logSize()
	p = rejoin(name, userId)
	local cashAfterJoin = cashOf(p)
	advance(4.0)
	T.check(want > 0 and abs(cashAfterJoin - (rec.Cash or 0) - want) <= math.max(2, want * 0.01),
		"tycoon offline: the Vault pays its offline earnings on rejoin (" .. want .. ")", "cash " .. cashAfterJoin .. " stored " .. tostring(rec.Cash))
	T.check(K.notified(p, "While you were away", "good", mark), "tycoon offline: a 'While you were away' side toast")
	local cash2 = cashOf(p)
	advance(2)
	T.eq(cashOf(p), cash2, "tycoon offline: paid once (LastSeen moved on)")
	T.check(K.notified(p, "Welcome back! Press E at your gate", "info", mark), "tycoon offline: a returning player whose last plot is free gets 'Welcome back! Press E at your gate'")
	T.check(SS.GetSpot(p) == nil and SS.SuggestSpot(p) == spots()[first], "tycoon offline: ...and GoToSpot / the guide lead to that gate (SuggestSpot), nothing is claimed yet")

	-- the saved build comes back on whichever plot is claimed
	local blocker = join("TyBlock")
	claim(blocker, first)
	local second = freeIndex(first)
	claim(p, second)
	local restored = Ty.GetHome(p)
	T.check(SS.GetSpot(p) == spots()[second] and restored.Stations.Press1 == 3 and restored.Stations.Vault == 1,
		"tycoon offline: the saved build is restored on another plot")
	if hasHomeBuilder() then
		local models = stationModels(second)
		T.check(models.Press1 and models.Press1:GetAttribute("Level") == 3 and models.Vault ~= nil, "tycoon offline: ...its stations stand on the new plot")
	end
	advance(1.2)
	T.eq(spots()[second].SubLabel.Text, "Home Level " .. Cat.HomeLevelOf(restored), "tycoon offline: ...and its nameplate shows the Home Level")
	leave(blocker)
	leave(p)
	K.flushErrors("p2tycoon_offline")
	K.flushWarnings("p2tycoon_offline", { "HomeBuilder is missing" })
end)

return S
