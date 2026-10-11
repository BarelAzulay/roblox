-- smoke_economy.lua: server scenarios for the v2 economy and lobby systems (ARCHITECTURE_V2.md sections 1-3, 5):
--   spots              SpotService (Phase 2: claimed with E at the gate): no plot on join / claim / free on leave /
--                      the last plot offered again / none when full / nameplates ('Home Level n') / showcase podium
--                      (built still, animated by the client) / teleport and the GoToSpot remote
--                      + v3 tutorial flow (TutorialService: every basics step from welcome to done, the home step =
--                      claiming a plot at its gate, gift once, finish reward once, the home chapter starting after the
--                      basics, skip, persistence, remote validation)
--   economy            DataService + PetService: spend / refund / stack cap / equip limits / perks /
--                      EquippedPets attribute / rate limiting / argument checks / prompts / stats
--                      + v3 Pet Index flow (MarkDiscovered, PetService.Rolled, IndexService.Completed / CanClaim /
--                      Claim, the IndexClaim remote: once per group, the Config.Index reward, persistence)
--   items              ItemService: buy rules and the three item effects (heal, shield, phoenix revive)
--   match_locks        items are refused during the match countdown (nothing consumed); pets are locked during matches
--   profile_sync       the ProfileSync snapshot shape, when it is sent, and that it is a copy
--   migration          v1 -> v2 save migration and untrusted stored data
--   match_difficulties the full match lifecycle for all five difficulties (victory + defeat, stars, bonus, stats)
--   match_pets         pet perks inside a match (token bonus with fair rounding, checkpoint heal, max health)
--
-- Loaded by smoke.py after smoke_server.lua, which exports its helper kit as the global K.
-- Plain Lua 5.1 syntax only.

local K = _G.K
local T = K.T
local guarded = K.guarded
local M = K.M
local W = K.W
local V = K.V
local fmt = K.fmt
local mod = K.mod
local config = K.config
local advance = K.advance
local waitFor = K.waitFor
local hum, root = K.hum, K.root
local flushErrors, flushWarnings = K.flushErrors, K.flushWarnings
local freshPlayers, removePlayers = K.freshPlayers, K.removePlayers
local remotesFor, lastRemote, logSize, notified = K.remotesFor, K.lastRemote, K.logSize, K.notified
local remoteFolder, needBoot = K.remoteFolder, K.needBoot
local MS, DS = K.MS, K.DS
local startMatch, toPlaying, endAllMatches = K.startMatch, K.toPlaying, K.endAllMatches
local planar, distance = K.planar, K.distance

local Players = game:GetService("Players")
local S = {}

local TOKENS_WORD = "Cloud Tokens" -- the nameplate info line spells the currency out (World text polish)
local BULLET = "\226\128\162"
local abs, floor, max, min = math.abs, math.floor, math.max, math.min

----------------------------------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------------------------------
local function profileOf(p)
	return mod("DataService").GetProfile(p)
end

-- sets the exact token balance through the public API (AddTokens / SpendTokens)
local function setTokens(p, n)
	local D = mod("DataService")
	local cur = D.GetTokens(p)
	if n > cur then
		D.AddTokens(p, n - cur)
	elseif n < cur then
		D.SpendTokens(p, cur - n)
	end
end

-- hands out pets the way a purchase would, without rolling (profile mutation + MarkDirty + Sync)
local function grant(p, petId, count)
	local prof = profileOf(p)
	prof.Pets[petId] = count
	mod("DataService").MarkDirty(p)
	mod("DataService").Sync(p)
end

-- runs fn() while PetCatalog.RollPet always answers `petId` (PetService reads the field at call time)
local function withRoll(petId, fn)
	local PC = M["shared/PetCatalog"]
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

local function petOfRarity(rarity, n)
	local list = M["shared/PetCatalog"].ListByRarity(rarity)
	return list[n or 1].Id
end

local function joinWithId(name, userId)
	local p = Mock.AddPlayer(name, userId)
	advance(0.8)
	return p
end

local function equippedAttr(p)
	return p:GetAttribute("EquippedPets")
end

local function samePerks(a, b)
	for _, key in ipairs({ "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }) do
		if abs((a[key] or 0) - (b[key] or 0)) > 1e-6 then
			return false, key
		end
	end
	return true
end

local function snapshots(p, fromIndex)
	local out = {}
	for _, e in ipairs(remotesFor("ProfileSync", p.UserId, fromIndex or 0)) do
		out[#out + 1] = e.args[1]
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- v3: the Pet Index claim flow (ARCHITECTURE_V3.md sections 1 + 3), run inside the economy scenario
----------------------------------------------------------------------------------------------------
local function indexFlow()
	local Config = config()
	local DataS, PS, IS = mod("DataService"), mod("PetService"), mod("IndexService")
	local PC = M["shared/PetCatalog"]
	if not T.check(type(IS) == "table" and type(IS.Claim) == "function" and type(IS.CanClaim) == "function", "Pet Index: IndexService is loaded") then
		return
	end
	local R = remoteFolder()
	local p = freshPlayers(1, "Collector")[1]
	local prof = profileOf(p)
	T.check(type(prof.Discovered) == "table" and next(prof.Discovered) == nil and type(prof.IndexClaimed) == "table" and next(prof.IndexClaimed) == nil,
		"Pet Index: a new profile starts with empty Discovered / IndexClaimed sets")
	local commons = PC.ListByRarity("Common")
	local reward = Config.Index.Rewards.Common.Tokens
	-- MarkDiscovered
	T.eq(DataS.MarkDiscovered(p, commons[1].Id), true, "Pet Index: MarkDiscovered returns true for a new pet")
	T.eq(DataS.MarkDiscovered(p, commons[1].Id), false, "Pet Index: ...and false when it was discovered before")
	T.eq(DataS.MarkDiscovered(p, "ghost_pet"), false, "Pet Index: MarkDiscovered ignores unknown pet ids")
	T.check(prof.Discovered[commons[1].Id] == true and prof.Discovered.ghost_pet == nil, "Pet Index: Profile.Discovered records it")
	-- a roll discovers the pet and fires PetService.Rolled(player, petId)
	setTokens(p, 2000)
	local rolled
	local rc = PS.Rolled:Connect(function(who, id)
		if who == p then
			rolled = id
		end
	end)
	withRoll(commons[2].Id, function()
		PS.BuyRoulette(p, Config.Roulettes[1].Id)
	end)
	advance(0.1)
	rc:Disconnect()
	T.eq(rolled, commons[2].Id, "Pet Index: a successful roll fires PetService.Rolled(player, petId)")
	T.eq(prof.Discovered[commons[2].Id], true, "Pet Index: ...and marks the pet discovered")
	-- an incomplete group cannot be claimed
	local ok, why = IS.CanClaim(p, "Common")
	T.check(ok == false and type(why) == "string", "Pet Index: CanClaim is false while the group is incomplete", tostring(why))
	local tokens = DataS.GetTokens(p)
	T.eq(select(1, IS.Claim(p, "Common")), false, "Pet Index: Claim of an incomplete group fails")
	T.eq(DataS.GetTokens(p), tokens, "Pet Index: ...and pays nothing")
	-- completing the group through a roll fires IndexService.Completed once and a side toast
	for i = 3, #commons - 1 do
		DataS.MarkDiscovered(p, commons[i].Id)
	end
	local completed = {}
	local cc = IS.Completed:Connect(function(who, groupId)
		if who == p then
			completed[#completed + 1] = groupId
		end
	end)
	local mark = logSize()
	withRoll(commons[#commons].Id, function()
		PS.BuyRoulette(p, Config.Roulettes[1].Id)
	end)
	advance(0.3)
	T.check(#completed == 1 and completed[1] == "Common", "Pet Index: discovering the last Common fires IndexService.Completed(player, 'Common') once", table.concat(completed, ","))
	T.check(notified(p, "Common", nil, mark), "Pet Index: ...and tells the player the reward can be claimed")
	withRoll(commons[1].Id, function()
		PS.BuyRoulette(p, Config.Roulettes[1].Id)
	end)
	advance(0.3)
	cc:Disconnect()
	T.eq(#completed, 1, "Pet Index: rolling another Common later does not fire Completed again")
	ok = IS.CanClaim(p, "Common")
	T.eq(ok, true, "Pet Index: CanClaim is true once every Common is discovered")
	-- claim through the remote: pays the Config.Index reward exactly once
	tokens = DataS.GetTokens(p)
	advance(0.6)
	mark = logSize()
	Mock.FromClient(R.IndexClaim, p, "Common")
	advance(0.2)
	T.eq(DataS.GetTokens(p), tokens + reward, "Pet Index: the IndexClaim remote pays Config.Index.Rewards.Common (" .. reward .. " tokens)")
	T.eq(prof.IndexClaimed.Common, true, "Pet Index: ...and records Profile.IndexClaimed.Common")
	local snaps = snapshots(p, mark)
	T.check(#snaps >= 1 and snaps[#snaps].IndexClaimed and snaps[#snaps].IndexClaimed.Common == true, "Pet Index: ...and syncs the profile (ProfileSync.IndexClaimed)")
	T.check(notified(p, "%+" .. reward, nil, mark) or notified(p, tostring(reward), nil, mark), "Pet Index: ...with a side toast naming the reward")
	-- once only: a quick repeat is rate limited, a later one is refused
	Mock.FromClient(R.IndexClaim, p, "Common")
	advance(0.7)
	mark = logSize()
	Mock.FromClient(R.IndexClaim, p, "Common")
	advance(0.2)
	T.eq(DataS.GetTokens(p), tokens + reward, "Pet Index: a group reward pays only once")
	T.check(notified(p, "claimed", "bad", mark), "Pet Index: ...a second claim is answered with 'Already claimed'")
	local ok2, why2 = IS.CanClaim(p, "Common")
	T.check(ok2 == false and tostring(why2):lower():find("claimed") ~= nil, "Pet Index: CanClaim after the claim is false ('Already claimed')", tostring(why2))
	-- owned pets always count as discovered (ARCHITECTURE_V3.md section 1)
	local uncommons = PC.ListByRarity("Uncommon")
	for _, def in ipairs(uncommons) do
		prof.Pets[def.Id] = 1
	end
	DataS.MarkDirty(p)
	T.eq(select(1, IS.CanClaim(p, "Uncommon")), true, "Pet Index: owning every Uncommon completes that group (owned = discovered)")
	-- untrusted input never raises and pays nothing
	tokens = DataS.GetTokens(p)
	local errs = #Mock.Errors
	for _, junk in ipairs({ 5, true, { "Common" }, string.rep("x", 400), "", "NoSuchGroup" }) do
		advance(0.6)
		Mock.FromClient(R.IndexClaim, p, junk)
	end
	advance(0.6)
	Mock.FromClient(R.IndexClaim, p)
	advance(0.3)
	T.eq(#Mock.Errors, errs, "Pet Index: IndexClaim with garbage arguments raises no errors")
	T.eq(DataS.GetTokens(p), tokens, "Pet Index: ...and pays nothing")
	T.eq(select(1, IS.Claim(p, CONTRACT.v3.secretRarity)), false, "Pet Index: the Secret group cannot be claimed without its pets")
	-- the claim survives a rejoin (persisted, no second payout)
	removePlayers({ p })
	advance(1.5)
	local again = joinWithId(p.Name, p.UserId)
	advance(0.5)
	local ok3 = IS.CanClaim(again, "Common")
	T.check(ok3 == false and profileOf(again).IndexClaimed.Common == true, "Pet Index: the claim is saved (a rejoin cannot claim the same group again)")
	removePlayers({ again })
end

----------------------------------------------------------------------------------------------------
-- v3: the tutorial step flow (ARCHITECTURE_V3.md section 4), run inside the spots scenario (the home step walks to
-- the player's own spot)
----------------------------------------------------------------------------------------------------
local function tutorialFlow()
	local Config = config()
	local TS, DataS, PS, SS = mod("TutorialService"), mod("DataService"), mod("PetService"), mod("SpotService")
	local Steps = M["shared/TutorialSteps"]
	if not T.check(type(TS) == "table" and type(TS.HandleEvent) == "function" and type(TS.GetState) == "function" and type(Steps) == "table", "Tutorial: TutorialService (HandleEvent / GetState) and TutorialSteps are loaded") then
		return
	end
	local ids = {}
	for i, step in ipairs(Steps.Steps) do
		ids[i] = step.Id
	end
	-- the nine basics keep their indices (the saved progress is the step index); Phase 2 appends the home chapter
	T.eq(table.concat(ids, ",", 1, math.min(9, #ids)), "welcome,home,shop,spin,equip,index,portal,finish,done", "Tutorial: the nine documented basics come first, in order")
	T.check(#ids > 9 and Steps.Steps[10].Chapter == 2, "Tutorial: the Phase 2 home chapter is appended after them", #ids .. " steps")
	local R = remoteFolder()
	local gift = Config.Tutorial.GiftTokens
	local finishReward = Config.Tutorial.FinishReward.Tokens
	local function stepId(p)
		local st = TS.GetState(p)
		return st and st.Id
	end
	local function send(p, eventName)
		advance(0.3) -- the remote is rate limited (0.25 s per player)
		Mock.FromClient(R.TutorialEvent, p, eventName)
		advance(0.2)
	end
	local mark = logSize()
	local p = joinWithId("Newbie", 940001)
	advance(0.5)
	local first = lastRemote("TutorialState", p.UserId, mark)
	local st = first and first.args[1]
	T.check(st ~= nil and #V.tutorialState(st) == 0 and st.Step == 1 and st.Id == "welcome" and st.Done == false and st.Total == #Steps.Steps,
		"Tutorial: a new player gets TutorialState { Step = 1, Id = 'welcome', Total = " .. #Steps.Steps .. ", Done = false } on join", st and table.concat(V.tutorialState(st), "; ") or "no state")
	-- events are validated against the CURRENT step only
	local okWrong = TS.HandleEvent(p, "ShopOpened")
	T.eq(okWrong, false, "Tutorial: an event for another step is refused")
	T.eq(stepId(p), "welcome", "Tutorial: ...and does not advance")
	send(p, "Next")
	T.eq(stepId(p), "home", "Tutorial: Next completes 'welcome'")
	-- home (Phase 2): the arrow leads to a free gate; pressing E there claims the plot
	local function claimTarget(label)
		local target = TS.GetState(p) and TS.GetState(p).Target
		local index = type(target) == "table" and target.SpotIndex or nil
		local spot = index and W.lobbyInfo.Spots[index]
		local gate = spot and SS.GateCFrame(spot)
		T.check(type(target) == "table" and target.Kind == "Spot" and gate ~= nil and typeof(target.Position) == "Vector3"
			and (target.Position - gate.Position).Magnitude < 1 and SS.GetOwner(index) == nil,
			"Tutorial: the '" .. label .. "' target is the gate of a free plot (Position = its gate, SpotIndex)")
		return spot, gate
	end
	local function pressE(spot, gate)
		Mock.Teleport(p, gate * CFrame.new(0, 3, -5))
		for _, d in ipairs(spot.Folder:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.Name == "ClaimPrompt" then
				Mock.Trigger(d, p)
			end
		end
	end
	local spot, gate = claimTarget("home")
	if T.check(spot ~= nil, "Tutorial: there is a free plot for the new player") then
		advance(1.5)
		T.eq(stepId(p), "home", "Tutorial: 'home' waits until the player claims a plot")
		pressE(spot, gate)
		waitFor(function()
			return stepId(p) ~= "home"
		end, 3)
		T.eq(stepId(p), "shop", "Tutorial: E at the gate claims the plot and completes 'home'")
	end
	-- shop -> spin: the gift is granted once on entering the spin step
	local tokens = DataS.GetTokens(p)
	mark = logSize()
	send(p, "ShopOpened")
	T.eq(stepId(p), "spin", "Tutorial: the client's ShopOpened completes 'shop'")
	T.eq(DataS.GetTokens(p), tokens + gift, "Tutorial: entering 'spin' gifts Config.Tutorial.GiftTokens (" .. gift .. ")")
	T.eq(DataS.GetTutorial(p).Gifted, true, "Tutorial: ...and stores Tutorial.Gifted")
	T.check(notified(p, "Nimbus", nil, mark), "Tutorial: ...with a side toast from Nimbus")
	-- leaving and rejoining on the spin step never pays the gift twice
	removePlayers({ p })
	advance(1.5)
	p = joinWithId("Newbie", 940001)
	advance(0.5)
	T.eq(stepId(p), "spin", "Tutorial: progress survives a rejoin (back on 'spin')")
	T.eq(DataS.GetTokens(p), tokens + gift, "Tutorial: ...and the gift is not paid again")
	-- spin: a real roulette spin with the gift
	local okSpin = PS.BuyRoulette(p, Config.Roulettes[1].Id)
	advance(0.5)
	T.eq(okSpin, true, "Tutorial: the gift pays for a Cloud Roulette spin")
	T.eq(stepId(p), "equip", "Tutorial: a successful roll completes 'spin' (PetService.Rolled)")
	-- equip: the first pet is auto-equipped, so opening Pets with a pet equipped completes the step
	send(p, "PetsOpened")
	T.eq(stepId(p), "index", "Tutorial: opening Pets with a pet equipped completes 'equip'")
	send(p, "IndexOpened")
	T.eq(stepId(p), "portal", "Tutorial: the client's IndexOpened completes 'index'")
	local portalTarget = TS.GetState(p) and TS.GetState(p).Target
	local easy = W.lobbyInfo and W.lobbyInfo.Portals and W.lobbyInfo.Portals.Easy
	T.check(type(portalTarget) == "table" and portalTarget.Kind == "Portal" and portalTarget.Id == "Easy" and easy ~= nil and typeof(portalTarget.Position) == "Vector3" and (portalTarget.Position - easy.Center).Magnitude < 1,
		"Tutorial: the 'portal' target carries the Easy portal's position for the guide arrow")
	-- portal / finish: InMatch true, then false
	local m = startMatch("Easy", { p })
	waitFor(function()
		return p:GetAttribute(Config.Attr.InMatch) == true and stepId(p) ~= "portal"
	end, 10)
	T.eq(stepId(p), "finish", "Tutorial: starting a match completes 'portal' (InMatch turned true)")
	if m then
		MS().LeaveMatch(p)
	end
	waitFor(function()
		return stepId(p) ~= "finish"
	end, 10)
	T.eq(stepId(p), "done", "Tutorial: the end of the match completes 'finish' (InMatch turned false)")
	-- done: Next pays the basics reward once; the home chapter follows (its 'claim' is already done: the plot)
	advance(2)
	tokens = DataS.GetTokens(p)
	local finished = {}
	local fc = type(TS.Finished) == "table" and TS.Finished:Connect(function(who, skipped)
		if who == p then
			finished[#finished + 1] = skipped
		end
	end)
	mark = logSize()
	send(p, "Next")
	waitFor(function()
		return stepId(p) ~= "done"
	end, 3)
	local after = TS.GetState(p)
	T.check(after and after.Done == false and after.Chapter == 2 and after.Id == "claim",
		"Tutorial: Next on 'done' ends the basics; the home chapter starts at 'claim' (the plot was released when the player left)", after and tostring(after.Id) or "no state")
	T.eq(DataS.GetTokens(p), tokens + finishReward, "Tutorial: finishing the basics pays Config.Tutorial.FinishReward (" .. finishReward .. " tokens)")
	local last = lastRemote("TutorialState", p.UserId, mark)
	T.check(last and last.args[1] and last.args[1].Chapter == 2 and #V.tutorialState(last.args[1]) == 0, "Tutorial: ...and sends the home chapter's TutorialState")
	spot, gate = claimTarget("claim")
	if spot then
		pressE(spot, gate)
		waitFor(function()
			return stepId(p) ~= "claim"
		end, 3)
	end
	T.eq(stepId(p), "press", "Tutorial: E at the gate completes 'claim' -> 'press'")
	send(p, "Next")
	T.eq(DataS.GetTokens(p), tokens + finishReward, "Tutorial: the basics reward is paid only once")
	T.check(DataS.GetTutorial(p).Done == true, "Tutorial: Tutorial.Done is stored once the basics are finished")
	removePlayers({ p })
	advance(1.5)
	p = joinWithId("Newbie", 940001)
	advance(0.5)
	T.check(TS.GetState(p) and TS.GetState(p).Id == "press" and DataS.GetTokens(p) == tokens + finishReward,
		"Tutorial: after a rejoin the home chapter resumes ('press'), the basics are not replayed nor paid again")
	send(p, "Skip")
	T.check(TS.GetState(p) and TS.GetState(p).Done == true and DataS.GetTokens(p) == tokens + finishReward, "Tutorial: Skip ends the rest (Done = true, nothing paid)")
	if fc then
		fc:Disconnect()
		T.check(#finished == 1 and finished[1] == true, "Tutorial: TutorialService.Finished fires once, when the whole tutorial ends (here: skipped)")
	end
	removePlayers({ p })

	-- skip: ends the tutorial without the finish reward or the gift
	local q = joinWithId("Skipper", 940002)
	advance(0.5)
	tokens = DataS.GetTokens(q)
	send(q, "Skip")
	T.check(TS.GetState(q) and TS.GetState(q).Done == true, "Tutorial: Skip ends the tutorial (Done = true)")
	T.eq(DataS.GetTokens(q), tokens, "Tutorial: skipping pays neither the gift nor the finish reward")
	T.eq(DataS.GetTutorial(q).Done, true, "Tutorial: ...and is stored")
	-- rate limit + garbage
	local errs = #Mock.Errors
	for _, junk in ipairs({ 5, true, { "Next" }, string.rep("x", 400), "", "Hack" }) do
		advance(0.3)
		Mock.FromClient(R.TutorialEvent, q, junk)
	end
	advance(0.3)
	Mock.FromClient(R.TutorialEvent, q)
	advance(0.3)
	T.eq(#Mock.Errors, errs, "Tutorial: TutorialEvent with garbage arguments raises no errors")
	mark = logSize()
	Mock.FromClient(R.TutorialEvent, q, "Sync")
	Mock.FromClient(R.TutorialEvent, q, "Sync")
	advance(0.2)
	T.eq(#remotesFor("TutorialState", q.UserId, mark), 1, "Tutorial: 'Sync' answers with the current state and is rate limited")
	removePlayers({ q })
end

----------------------------------------------------------------------------------------------------
-- scenario: spots
----------------------------------------------------------------------------------------------------
S.spots = guarded("spots", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local SS, DataS, PS = mod("SpotService"), mod("DataService"), mod("PetService")
	local PC, PB = M["shared/PetCatalog"], M["shared/PetBuilder"]
	local info = W.lobbyInfo
	local count = Config.Lobby.SpotCount
	local CS = game:GetService("CollectionService")
	local function taken()
		local set, n = {}, 0
		for _, p in ipairs(Players:GetPlayers()) do
			local sp = SS.GetSpot(p)
			if sp then
				set[sp.Index] = p
				n = n + 1
			end
		end
		return set, n
	end
	local function lowestFree()
		local set = taken()
		for i = 1, count do
			if not set[i] then
				return i
			end
		end
		return nil
	end
	local function subOf(i)
		return info.Spots[i].SubLabel.Text
	end
	-- Phase 2 (ARCHITECTURE_V3.md "Phase 2: Tycoon homes"): nobody gets a plot on join; a plot is claimed with E at
	-- its gate (the gate's ClaimPrompt, handled by TycoonService) and released when the owner leaves
	local function claimAt(p, index)
		local sp = index and info.Spots[index]
		if not sp then
			return nil
		end
		local gate = SS.GateCFrame(sp)
		if gate then
			Mock.Teleport(p, gate * CFrame.new(0, 3, -5))
		end
		for _, d in ipairs(sp.Folder:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.Name == "ClaimPrompt" then
				Mock.Trigger(d, p)
			end
		end
		advance(0.6)
		return SS.GetSpot(p)
	end
	local function indexOf(sp)
		return sp and sp.Index or nil
	end

	-- the baseline player
	local alice = W.alice
	if not alice or not alice.Parent then
		alice = freshPlayers(1, "Alice")[1]
		W.alice = alice
	end
	T.eq(SS.GetSpot(alice), nil, "a player who joined owns no spot until pressing E at a gate (Phase 2)")
	T.eq(alice:GetAttribute("SpotIndex"), nil, "...and has no SpotIndex attribute")
	local aSpot = claimAt(alice, lowestFree())
	if T.check(aSpot ~= nil, "E at the gate of a free plot claims it") then
		T.eq(alice:GetAttribute("SpotIndex"), aSpot.Index, "attribute SpotIndex = the owned spot's index")
		T.eq(aSpot, info.Spots[aSpot.Index], "GetSpot returns the SpotInfo from LobbyInfo.Spots")
		T.eq(profileOf(alice).SpotIndex, aSpot.Index, "the spot index is stored in the profile (the last plot)")
		advance(1.2)
		T.eq(aSpot.NameLabel.Text, alice.DisplayName, "the nameplate shows the owner's display name")
		T.eq(aSpot.SubLabel.Text, "Home Level 0", "the sub label reads 'Home Level <n>' (Phase 2: the tycoon home)")
	end
	local freeLabels = 0
	for i = 1, count do
		if info.Spots[i].NameLabel.Text == "Free home" and info.Spots[i].SubLabel.Text == "Press E at the gate" then
			freeLabels = freeLabels + 1
		end
	end
	local _, owned = taken()
	T.eq(freeLabels, count - owned, "every unowned spot reads 'Free home' / 'Press E at the gate' (" .. owned .. " of " .. count .. " are owned)")

	-- new players get no plot; they claim a free one, never one that is taken
	local before = lowestFree()
	local bob = freshPlayers(1, "Bob")[1]
	T.eq(SS.GetSpot(bob), nil, "a new player has no spot until claiming one")
	claimAt(bob, aSpot and aSpot.Index)
	T.check(SS.GetSpot(bob) == nil and (aSpot == nil or SS.GetOwner(aSpot.Index) == alice), "...never one that is taken (Alice keeps hers)")
	advance(0.6)
	local bobSpot = claimAt(bob, before)
	T.check(bobSpot ~= nil and bobSpot.Index == before, "a new player claims a free spot (" .. tostring(before) .. ")", bobSpot and tostring(bobSpot.Index))
	local bobIndex = bobSpot and bobSpot.Index
	if bobSpot then
		advance(1.2)
		T.eq(bobSpot.NameLabel.Text, bob.DisplayName, "Bob's nameplate shows Bob")
		T.check(info.Spots[bobIndex].Folder:IsDescendantOf(info.Folder), "spots live inside the lobby folder")
	end
	-- first spawn is on the plaza, not at a plot
	local fresh = freshPlayers(1, "Fresh")[1]
	T.check(planar(root(fresh).Position, info.SpawnCFrame.Position) <= 14, "the first spawn is on the plaza", fmt(planar(root(fresh).Position, info.SpawnCFrame.Position)))
	removePlayers({ fresh })

	-- leaving frees the spot
	Mock.RemovePlayer(bob)
	advance(1.0)
	if bobIndex then
		T.eq(info.Spots[bobIndex].NameLabel.Text, "Free home", "leaving frees the spot: nameplate back to 'Free home'")
		T.eq(subOf(bobIndex), "Press E at the gate", "...and 'Press E at the gate'")
		T.check(info.Spots[bobIndex].Folder:FindFirstChild("ShowcasePet", true) == nil, "...and the podium is empty")
		local reused = freshPlayers(1, "Reuse")[1]
		T.check(claimAt(reused, bobIndex) ~= nil and SS.GetSpot(reused).Index == bobIndex, "a freed spot can be claimed again")
		removePlayers({ reused })
	end

	-- the last plot: X, Y, Z claim spots; X and Y leave; Y comes back: the guide (SuggestSpot) offers Y's old plot
	local X = joinWithId("Xavier", 910001)
	local Y = joinWithId("Yara", 910002)
	local Z = joinWithId("Zed", 910003)
	local xi = indexOf(claimAt(X, lowestFree()))
	local yi = indexOf(claimAt(Y, lowestFree()))
	local zi = indexOf(claimAt(Z, lowestFree()))
	T.check(xi and yi and zi and xi < yi and yi < zi, "three players claim three different spots", tostring(xi) .. "," .. tostring(yi) .. "," .. tostring(zi))
	Mock.RemovePlayer(X)
	Mock.RemovePlayer(Y)
	advance(2.5) -- both saved
	T.check(taken()[xi] == nil and taken()[yi] == nil, "both spots are free after they left")
	local mark = logSize()
	local Y2 = joinWithId("Yara", 910002)
	advance(5) -- the join toast comes a moment after the profile loaded
	T.eq(indexOf(SS.SuggestSpot(Y2)), yi, "a returning player is guided back to the previous plot even though a lower one is free (" .. tostring(yi) .. ")")
	T.check(notified(Y2, "Welcome back", "info", mark), "...with the 'Welcome back! Press E at your gate' toast")
	T.eq(SS.GetSpot(Y2), nil, "...and nothing is claimed before E is pressed")
	claimAt(Y2, yi)
	T.eq(indexOf(SS.GetSpot(Y2)), yi, "E at that gate claims it again")
	-- the previous plot taken by someone else -> another free plot is suggested
	local W1 = freshPlayers(1, "Walter")[1]
	local w1 = indexOf(claimAt(W1, xi))
	T.eq(w1, xi, "a newcomer claims Xavier's old spot")
	local X2 = joinWithId("Xavier", 910001)
	local sugg = indexOf(SS.SuggestSpot(X2))
	T.check(sugg ~= nil and sugg ~= xi and SS.GetOwner(sugg) == nil, "when the previous spot is taken the guide suggests another free plot", tostring(sugg) .. " (previous " .. tostring(xi) .. ")")
	local x2 = indexOf(claimAt(X2, sugg))
	T.check(x2 ~= nil and x2 == sugg, "...which can be claimed")
	T.eq(profileOf(X2).SpotIndex, x2, "...and the new index is stored")

	-- full: every plot claimed, the next player gets none
	local fillers = {}
	local guard = 0
	while select(2, taken()) < count and guard < count + 4 do
		guard = guard + 1
		local f = freshPlayers(1, "Fill")[1]
		fillers[#fillers + 1] = f
		claimAt(f, lowestFree())
	end
	local _, ownedNow = taken()
	T.eq(ownedNow, count, "all " .. count .. " spots can be owned at the same time")
	local extra = freshPlayers(1, "Extra")[1]
	T.eq(SS.GetSpot(extra), nil, "with every spot taken a newcomer gets none (GetSpot = nil)")
	T.eq(extra:GetAttribute("SpotIndex"), nil, "...and no SpotIndex attribute")
	T.check(root(extra) ~= nil, "...but still spawns normally")
	T.eq(SS.Teleport(extra), false, "SpotService.Teleport is a no-op without a spot and without a free plot")
	mark = logSize()
	local before2 = root(extra).Position
	Mock.FromClient(remoteFolder().GoToSpot, extra)
	advance(0.3)
	T.check(distance(root(extra).Position, before2) < 1, "GoToSpot without a spot does not move the player")
	T.check(notified(extra, "Every home is taken", "bad", mark), "...it answers with a small toast instead")
	-- a spot that frees up can be claimed by the waiting player
	local leaver = fillers[#fillers]
	local leaverIndex = SS.GetSpot(leaver).Index
	Mock.RemovePlayer(leaver)
	fillers[#fillers] = nil
	advance(1.5)
	T.eq(SS.GetSpot(extra), nil, "a freed spot is not handed out automatically (Phase 2: claimed with E)")
	T.eq(indexOf(SS.SuggestSpot(extra)), leaverIndex, "...the guide leads the waiting player to it")
	claimAt(extra, leaverIndex)
	T.check(SS.GetSpot(extra) ~= nil and SS.GetSpot(extra).Index == leaverIndex, "...and E at its gate claims it", tostring(SS.GetSpot(extra) and SS.GetSpot(extra).Index))
	T.eq(extra:GetAttribute("SpotIndex"), leaverIndex, "...and the SpotIndex attribute follows")
	removePlayers(fillers)
	removePlayers({ extra, W1, X2, Y2, Z })
	advance(1.0)

	-- teleport + GoToSpot
	local P = alice
	local sp = SS.GetSpot(P)
	if sp then
		Mock.Teleport(P, info.SpawnCFrame)
		advance(0.3)
		T.eq(SS.Teleport(P), true, "SpotService.Teleport(player) succeeds")
		T.check(planar(root(P).Position, sp.SpawnCFrame.Position) <= 8 and abs(root(P).Position.Y - sp.SpawnCFrame.Position.Y) <= 6, "...and puts the player on their spot", fmt(planar(root(P).Position, sp.SpawnCFrame.Position)))
		advance(0.6)
		Mock.Teleport(P, info.SpawnCFrame)
		advance(0.3)
		Mock.FromClient(remoteFolder().GoToSpot, P)
		advance(0.1)
		T.check(planar(root(P).Position, sp.SpawnCFrame.Position) <= 8, "the GoToSpot remote teleports the player to their spot")
		Mock.Teleport(P, info.SpawnCFrame)
		advance(0.05)
		Mock.FromClient(remoteFolder().GoToSpot, P)
		advance(0.05)
		T.check(planar(root(P).Position, info.SpawnCFrame.Position) <= 6, "GoToSpot is rate limited (a second call inside 0.25 s is ignored)")
		advance(0.5)
		P:SetAttribute("InMatch", true)
		Mock.Teleport(P, info.SpawnCFrame)
		advance(0.3)
		T.eq(SS.Teleport(P), false, "Teleport is refused during a match")
		Mock.FromClient(remoteFolder().GoToSpot, P)
		advance(0.3)
		T.check(planar(root(P).Position, info.SpawnCFrame.Position) <= 6, "GoToSpot is ignored during a match")
		P:SetAttribute("InMatch", false)
		advance(0.3)
	end

	-- nameplate follows the home; showcase podium shows the best pet (built standing still, animated by the client)
	local Q = freshPlayers(1, "Showy")[1]
	local qs = claimAt(Q, lowestFree())
	if not T.check(qs ~= nil, "showcase owner has a spot") then
		removePlayers({ Q })
		return
	end
	local common, mythic = petOfRarity("Common", 1), CONTRACT.v2.mascotPetId
	local common2 = petOfRarity("Common", 2)
	T.check(qs.Folder:FindFirstChild("ShowcasePet", true) == nil, "a player without pets has an empty podium")
	local okTy, Tycoon = pcall(require, K.moduleInstance("server/Services/TycoonService"))
	if okTy and type(Tycoon) == "table" and type(Tycoon.Buy) == "function" then
		Tycoon.Buy(Q, "Press1")
		advance(1.6)
		T.eq(qs.SubLabel.Text, "Home Level 1", "the nameplate follows the Home Level (Press 1 built)")
	end
	grant(Q, common, 2)
	advance(1.6)
	local show1 = qs.Folder:FindFirstChild("ShowcasePet", true)
	if T.check(show1 ~= nil and show1:IsA("Model"), "the podium shows a pet model once the owner has a pet") then
		local def = PC.Get(common)
		local pos = show1:GetPivot().Position
		T.check(planar(pos, qs.PodiumCFrame.Position) <= 4 and pos.Y > qs.PodiumCFrame.Position.Y, "...standing/hovering above the podium", tostring(pos) .. " vs " .. tostring(qs.PodiumCFrame.Position))
		local want = PB.GetHeight(def) * 1.4
		local got = show1:GetExtentsSize().Y
		T.check(abs(got - want) <= want * 0.25, "...at scale 1.4", fmt(got, 2) .. " vs " .. fmt(want, 2))
		T.check(show1:FindFirstChild("WingL", true) ~= nil, "...built by PetBuilder (it has wings)")
		-- Replication rule (Phase 2 podium): the server builds it standing still, every part Anchored, and tags it for
		-- ShowcaseController, which hovers / turns it on each client
		local anchored, partCount = 0, 0
		for _, d in ipairs(show1:GetDescendants()) do
			if d:IsA("BasePart") then
				partCount = partCount + 1
				if d.Anchored and not d.CanCollide then
					anchored = anchored + 1
				end
			end
		end
		T.check(partCount > 0 and anchored == partCount, "every part of the podium pet is Anchored and non-colliding", anchored .. " of " .. partCount)
		T.check(CS:HasTag(show1, "NC_Showcase") and show1:GetAttribute("Ready") == true and type(show1:GetAttribute("HoverAmp")) == "number",
			"...tagged NC_Showcase (Ready, HoverAmp) for the client animation")
		local look0, at0 = show1:GetPivot().LookVector, show1:GetPivot().Position
		Mock.Teleport(Q, qs.SpawnCFrame)
		advance(2.0)
		T.check((show1:GetPivot().LookVector - look0).Magnitude < 1e-6 and (show1:GetPivot().Position - at0).Magnitude < 1e-6,
			"the server never moves the showcase (no CFrame writes, even with its owner next to it)")
		local tagText = {}
		for _, d in ipairs(qs.Folder:GetDescendants()) do
			if d:IsA("TextLabel") then
				tagText[#tagText + 1] = tostring(d.Text)
			end
		end
		local joined = table.concat(tagText, " | ")
		T.check(joined:find(def.Name, 1, true) ~= nil and joined:find("Common", 1, true) ~= nil, "a small tag names the pet and its rarity", joined)
	end
	-- not rebuilt for an equal-or-lower pet
	grant(Q, common2, 1)
	advance(1.6)
	local show2 = qs.Folder:FindFirstChild("ShowcasePet", true)
	T.check(show2 ~= nil and show2 == show1, "the showcase model is not rebuilt when the best pet stays the same")
	-- mythic owned but only a common equipped: the best owned pet is shown
	grant(Q, mythic, 1)
	advance(1.8)
	local show3 = qs.Folder:FindFirstChild("ShowcasePet", true)
	T.check(show3 ~= nil and show3 ~= show1, "a better pet replaces the model")
	if show3 then
		local texts = {}
		for _, d in ipairs(qs.Folder:GetDescendants()) do
			if d:IsA("TextLabel") then
				texts[#texts + 1] = tostring(d.Text)
			end
		end
		local joined = table.concat(texts, " | ")
		T.check(joined:find("Cloudy Dragon", 1, true) ~= nil and joined:find("Mythic", 1, true) ~= nil, "...and the tag names the Cloudy Dragon (Mythic)", joined)
	end
	-- all pets gone -> empty podium again
	local prof = profileOf(Q)
	prof.Pets = {}
	prof.Equipped = {}
	DataS.MarkDirty(Q)
	DataS.Sync(Q)
	advance(1.8)
	T.check(qs.Folder:FindFirstChild("ShowcasePet", true) == nil, "the podium empties when the owner has no pets")
	Mock.RemovePlayer(Q)
	advance(1.2)
	T.eq(qs.NameLabel.Text, "Free home", "the showcase owner leaving frees the nameplate too")
	T.check(qs.Folder:FindFirstChild("ShowcasePet", true) == nil, "...and removes the showcase pet")
	tutorialFlow()
	flushErrors("spots")
	flushWarnings("spots")
end)

----------------------------------------------------------------------------------------------------
-- scenario: economy (DataService + PetService)
----------------------------------------------------------------------------------------------------
S.economy = guarded("economy", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local DataS, PS = mod("DataService"), mod("PetService")
	local PC = M["shared/PetCatalog"]

	-- ProfileLoaded fires with the profile
	local loaded
	local conn = DataS.ProfileLoaded:Connect(function(player, profile)
		loaded = { player, profile }
	end)
	local p = freshPlayers(1, "Eco")[1]
	conn:Disconnect()
	T.check(loaded ~= nil and loaded[1] == p and type(loaded[2]) == "table", "DataService.ProfileLoaded fires (player, profile) after the load")

	-- defaults
	local prof = DataS.GetProfile(p)
	if not T.check(type(prof) == "table", "DataService.GetProfile returns the profile after the load") then
		return
	end
	T.check(loaded and loaded[2] == prof, "ProfileLoaded passes the LIVE profile table")
	T.eq(DataS.GetProfile(p), prof, "GetProfile always returns the same live table")
	T.eq(DataS.Load(p), prof, "calling Load again returns the same live profile (idempotent)")
	T.eq(prof.Version, 2, "Profile.Version = 2")
	T.check(prof.Tokens == 0 and next(prof.Pets) == nil and #prof.Equipped == 0 and next(prof.Items) == nil, "a new profile starts with 0 tokens and no pets / items")
	T.check(prof.Stats.Matches == 0 and prof.Stats.Wins == 0 and prof.Stats.TokensEarned == 0 and prof.Stats.Spins == 0 and next(prof.Stats.BestTimes) == nil, "...and zeroed stats")
	T.eq(DataS.GetProfile(nil), nil, "GetProfile(nil) is nil")

	-- tokens: add / spend / never negative
	DataS.AddTokens(p, 100)
	T.eq(p:GetAttribute("CloudTokens"), 100, "AddTokens updates the CloudTokens attribute")
	T.eq(p.leaderstats.Tokens.Value, 100, "...and leaderstats.Tokens")
	T.eq(prof.Stats.TokensEarned, 100, "...and Stats.TokensEarned")
	DataS.AddTokens(p, -5)
	DataS.AddTokens(p, 0)
	DataS.AddTokens(p, 0 / 0)
	DataS.AddTokens(p, math.huge)
	T.eq(DataS.GetTokens(p), 100, "AddTokens ignores negative, zero, NaN and infinite amounts")
	T.eq(DataS.SpendTokens(p, 30), true, "SpendTokens(30) succeeds with 100 tokens")
	T.eq(DataS.GetTokens(p), 70, "...and takes exactly 30")
	T.eq(p:GetAttribute("CloudTokens"), 70, "...also on the attribute")
	T.eq(DataS.SpendTokens(p, 71), false, "SpendTokens fails when the balance is too small")
	T.eq(DataS.GetTokens(p), 70, "...and takes nothing")
	T.eq(DataS.SpendTokens(p, -5), false, "SpendTokens(-5) is refused (no free tokens through a negative price)")
	T.eq(DataS.SpendTokens(p, 0 / 0), false, "SpendTokens(NaN) is refused")
	T.eq(DataS.GetTokens(p), 70, "refused spends leave the balance alone")
	T.eq(DataS.SpendTokens(p, 70), true, "spending the whole balance works")
	T.eq(DataS.GetTokens(p), 0, "...and lands on exactly 0")
	T.eq(DataS.SpendTokens(p, 1), false, "SpendTokens at 0 tokens fails (never negative)")
	T.eq(DataS.GetTokens(p), 0, "the balance never goes below 0")

	-- BuyRoulette: refusals
	local cloud = Config.Roulettes[1]
	local ok, why = PS.BuyRoulette(p, cloud.Id)
	T.check(ok == false and type(why) == "string", "BuyRoulette without tokens fails with a reason", tostring(why))
	T.eq(next(prof.Pets), nil, "...and gives no pet")
	setTokens(p, 1000)
	T.eq(select(1, PS.BuyRoulette(p, "NoSuchRoulette")), false, "BuyRoulette of an unknown roulette fails")
	T.eq(select(1, PS.BuyRoulette(p, nil)), false, "BuyRoulette(nil) fails")
	T.eq(select(1, PS.BuyRoulette(p, 5)), false, "BuyRoulette(5) fails")
	p:SetAttribute("InMatch", true)
	T.eq(select(1, PS.BuyRoulette(p, cloud.Id)), false, "BuyRoulette is refused during a match")
	p:SetAttribute("InMatch", false)
	T.eq(DataS.GetTokens(p), 1000, "refused purchases cost nothing")

	-- BuyRoulette: a real pull, forced to a known Common so the checks are exact
	local common = petOfRarity("Common", 1)
	local perksChanged = 0
	local pc = PS.PerksChanged:Connect(function(who)
		if who == p then
			perksChanged = perksChanged + 1
		end
	end)
	local mark = logSize()
	local res
	withRoll(common, function()
		ok, res = PS.BuyRoulette(p, cloud.Id)
	end)
	T.eq(ok, true, "BuyRoulette succeeds with enough tokens")
	T.eq(DataS.GetTokens(p), 1000 - cloud.Price, "...and charges exactly the roulette price (" .. cloud.Price .. ")")
	T.eq(prof.Pets[common], 1, "...adds the pet to Profile.Pets")
	T.eq(prof.Stats.Spins, 1, "...counts the spin in Stats.Spins")
	if type(res) == "table" then
		local problems = V.rouletteResult(res)
		T.check(#problems == 0, "the returned result has the documented shape", table.concat(problems, ", "))
		T.check(res.PetId == common and res.IsNew == true and res.Count == 1 and res.Tokens == 1000 - cloud.Price and res.RouletteId == cloud.Id, "result: PetId / IsNew / Count / Tokens / RouletteId")
		T.eq(#res.Strip, 40, "the cosmetic strip lists 40 pets")
		T.eq(res.Strip[34], common, "...with the won pet at index 34")
	end
	local sent = lastRemote("RouletteResult", p.UserId, mark)
	T.check(sent ~= nil and sent.args[1] and sent.args[1].PetId == common, "RouletteResult is fired to the buyer")
	T.check(#snapshots(p, mark) >= 1, "ProfileSync follows every purchase")
	T.eq(prof.Equipped[1], common, "the first pet ever owned is equipped automatically")
	T.eq(#prof.Equipped, 1, "...only that one")
	T.eq(equippedAttr(p), common, "attribute EquippedPets = the equipped ids as csv")
	T.check(type(p:GetAttribute("PerkStaminaRegen")) == "number", "attribute PerkStaminaRegen is a number")
	T.check(perksChanged >= 1, "PerksChanged fires when a pet is equipped")
	-- second pull of the same pet: not new, count 2, not auto-equipped again
	withRoll(common, function()
		ok, res = PS.BuyRoulette(p, cloud.Id)
	end)
	T.check(ok and res.IsNew == false and res.Count == 2 and prof.Pets[common] == 2, "pulling the same pet again stacks it (x2, not new)")
	T.eq(#prof.Equipped, 1, "...and does not equip it again automatically")
	-- stack cap: refunded / not charged, nothing added
	prof.Pets[common] = Config.Pets.MaxPerStack
	local tokensBefore, spinsBefore = DataS.GetTokens(p), prof.Stats.Spins
	withRoll(common, function()
		ok, why = PS.BuyRoulette(p, cloud.Id)
	end)
	T.eq(ok, false, "a pull that would exceed the stack cap (" .. Config.Pets.MaxPerStack .. ") fails")
	T.eq(DataS.GetTokens(p), tokensBefore, "...and the price is refunded")
	T.eq(prof.Pets[common], Config.Pets.MaxPerStack, "...the stack stays at the cap")
	T.eq(prof.Stats.Spins, spinsBefore, "...and the spin is not counted")
	prof.Pets[common] = 2

	-- real RNG: many spins, always valid, exact accounting
	setTokens(p, 5000)
	local spins, bad = 0, 0
	local before = prof.Stats.Spins
	local possible = {}
	for _, def in ipairs(PC.PossiblePets(cloud.Id)) do
		possible[def.Id] = true
	end
	for _ = 1, 40 do
		local o, r = PS.BuyRoulette(p, cloud.Id)
		if o and type(r) == "table" and possible[r.PetId] then
			spins = spins + 1
		else
			bad = bad + 1
		end
		advance(0.05)
	end
	T.eq(bad, 0, "40 real spins of the " .. cloud.Id .. " roulette only give pets it can drop")
	T.eq(DataS.GetTokens(p), 5000 - 40 * cloud.Price, "...and cost exactly 40 x " .. cloud.Price)
	T.eq(prof.Stats.Spins, before + 40, "...and Stats.Spins counts them")
	local total = 0
	for _, n in pairs(prof.Pets) do
		total = total + n
	end
	T.check(total == 2 + 40, "every pull ended up in Profile.Pets", total .. " pets owned")

	-- rare pulls are announced to the others
	local witness = freshPlayers(1, "Witness")[1]
	local rare = petOfRarity("Rare", 1)
	mark = logSize()
	setTokens(p, 1000)
	withRoll(rare, function()
		PS.BuyRoulette(p, cloud.Id)
	end)
	advance(0.3)
	local def = PC.Get(rare)
	T.check(notified(witness, "pulled", "good", mark) and notified(witness, def.Name, "good", mark), "a Rare+ pull is announced to everyone else ('<Name> pulled <Pet>!')")
	T.check(not notified(p, "pulled", nil, mark), "...but the puller sees it only after the reveal")
	advance(5.5)
	T.check(notified(p, "pulled", "good", mark), "...the puller gets it ~5 s later")
	mark = logSize()
	withRoll(common, function()
		PS.BuyRoulette(p, cloud.Id)
	end)
	advance(6)
	T.check(not notified(witness, "pulled", nil, mark), "a Common pull is not announced")
	removePlayers({ witness })

	-- equip / unequip rules
	prof.Pets = {}
	prof.Equipped = {}
	local a, b, c, d = petOfRarity("Common", 1), petOfRarity("Common", 2), petOfRarity("Uncommon", 1), petOfRarity("Rare", 1)
	grant(p, a, 1)
	grant(p, b, 2)
	grant(p, c, 1)
	grant(p, d, 1)
	perksChanged = 0
	T.eq(select(1, PS.Equip(p, "ghost")), false, "Equip of an unknown pet fails")
	T.eq(select(1, PS.Equip(p, PC.ListByRarity("Epic")[1].Id)), false, "Equip of a pet the player does not own fails")
	T.eq(select(1, PS.Equip(p, nil)), false, "Equip(nil) fails")
	T.eq(select(1, PS.Equip(p, a)), true, "Equip of an owned pet works")
	T.eq(select(1, PS.Equip(p, a)), false, "...but the same pet cannot be equipped more often than owned (x1)")
	T.eq(select(1, PS.Equip(p, b)), true, "an x2 stack can be equipped once...")
	T.eq(select(1, PS.Equip(p, b)), true, "...and twice (a petId may appear at most `count` times)")
	T.eq(#prof.Equipped, Config.Pets.MaxEquipped, "now " .. Config.Pets.MaxEquipped .. " pets are equipped")
	local okFull, whyFull = PS.Equip(p, c)
	T.check(okFull == false and type(whyFull) == "string", "equipping beyond Config.Pets.MaxEquipped fails with a reason", tostring(whyFull))
	T.check(perksChanged >= 3, "PerksChanged fires for every change", perksChanged .. " events")
	T.eq(equippedAttr(p), table.concat(prof.Equipped, ","), "EquippedPets attribute always equals Profile.Equipped")
	local listed = PS.GetEquipped(p)
	T.check(#listed == 3 and listed[1] == a, "GetEquipped lists the equipped ids in order")
	listed[1] = "tampered"
	T.eq(PS.GetEquipped(p)[1], a, "GetEquipped returns a copy")
	T.eq(select(1, PS.Unequip(p, c)), false, "Unequip of a pet that is not equipped fails")
	T.eq(select(1, PS.Unequip(p, "ghost")), false, "Unequip of an unknown pet fails")
	T.eq(select(1, PS.Unequip(p, a)), true, "Unequip works")
	T.eq(#prof.Equipped, 2, "...and frees the slot")
	T.eq(equippedAttr(p), table.concat(prof.Equipped, ","), "...the attribute follows")
	T.eq(select(1, PS.Equip(p, c)), true, "a freed slot can be used by another pet")

	-- perks: sums, caps, health
	prof.Equipped = {}
	grant(p, CONTRACT.v2.mascotPetId, 3)
	for _ = 1, 3 do
		PS.Equip(p, CONTRACT.v2.mascotPetId)
	end
	advance(0.5)
	local perks = PS.GetPerks(p)
	local want = PC.SumPerks(prof.Equipped)
	T.check(samePerks(perks, want), "GetPerks equals PetCatalog.SumPerks of the equipped pets")
	T.near(perks.TokenBonus, 0.75, 1e-6, "three Cloudy Dragons give +75% cloud tokens")
	T.near(PS.GetTokenMultiplier(p), 1.75, 1e-6, "GetTokenMultiplier = 1 + TokenBonus")
	T.near(hum(p).MaxHealth, Config.Physics.MaxHealth * (1 + perks.MaxHealth), 0.6, "the MaxHealth perk raises Humanoid.MaxHealth")
	local np = freshPlayers(1, "NoPets")[1]
	T.check(PS.GetTokenMultiplier(np) == 1, "a player without pets has multiplier 1 (>= 1 always)")
	removePlayers({ np })
	perks.TokenBonus = 99
	T.near(PS.GetPerks(p).TokenBonus, 0.75, 1e-6, "GetPerks returns a copy")
	-- caps (raise the slot limit for this test only; the snapshots it produces break the slot rule on purpose, so
	-- they are dropped from the remote log afterwards instead of failing the whole-run payload audit)
	local capMark = logSize()
	local slots = Config.Pets.MaxEquipped
	Config.Pets.MaxEquipped = 10
	grant(p, CONTRACT.v2.mascotPetId, 10)
	prof.Equipped = {}
	for _ = 1, 10 do
		PS.Equip(p, CONTRACT.v2.mascotPetId)
	end
	advance(0.5)
	perks = PS.GetPerks(p)
	Config.Pets.MaxEquipped = slots
	T.near(perks.MaxHealth, Config.Pets.PerkCaps.MaxHealth, 1e-6, "perks are capped: MaxHealth stops at " .. Config.Pets.PerkCaps.MaxHealth)
	T.near(perks.TokenBonus, Config.Pets.PerkCaps.TokenBonus, 1e-6, "perks are capped: TokenBonus stops at " .. Config.Pets.PerkCaps.TokenBonus)
	T.near(PS.GetTokenMultiplier(p), 1 + Config.Pets.PerkCaps.TokenBonus, 1e-6, "...so the multiplier is capped too")
	while #prof.Equipped > 0 do
		PS.Unequip(p, prof.Equipped[1])
	end
	advance(0.3)
	for i = #Mock.RemoteLog, capMark + 1, -1 do
		if Mock.RemoteLog[i].remote == "ProfileSync" and Mock.RemoteLog[i].userId == p.UserId then
			table.remove(Mock.RemoteLog, i)
		end
	end
	T.near(PS.GetPerks(p).TokenBonus, 0, 1e-6, "unequipping everything removes the perks again")
	-- a stamina-regen pet publishes the attribute
	local regenPet
	for _, def2 in ipairs(PC.Pets) do
		if (def2.Perks.StaminaRegen or 0) > 0 then
			regenPet = def2
			break
		end
	end
	if regenPet then
		grant(p, regenPet.Id, 1)
		prof.Equipped = {}
		T.eq(select(1, PS.Equip(p, regenPet.Id)), true, "equip the stamina pet " .. regenPet.Id)
		T.near(p:GetAttribute("PerkStaminaRegen") or -1, regenPet.Perks.StaminaRegen, 1e-6, "attribute PerkStaminaRegen = the StaminaRegen perk")
		PS.Unequip(p, regenPet.Id)
		T.near(p:GetAttribute("PerkStaminaRegen") or -1, 0, 1e-6, "...and returns to 0 after unequipping")
	end
	pc:Disconnect()

	-- remotes: rate limits, type checks, ids
	prof.Pets = {}
	prof.Equipped = {}
	grant(p, a, 1)
	grant(p, c, 1)
	setTokens(p, 500)
	advance(0.5)
	local R = remoteFolder()
	local errs = #Mock.Errors
	mark = logSize()
	Mock.FromClient(R.EquipPet, p, a)
	advance(0.05)
	T.eq(prof.Equipped[1], a, "the EquipPet remote equips an owned pet")
	Mock.FromClient(R.EquipPet, p, c)
	advance(0.05)
	T.eq(#prof.Equipped, 1, "EquipPet is rate limited (0.25 s per player)")
	advance(0.3)
	Mock.FromClient(R.EquipPet, p, c)
	advance(0.05)
	T.eq(#prof.Equipped, 2, "...and works again after the cooldown")
	advance(0.3)
	Mock.FromClient(R.UnequipPet, p, c)
	advance(0.05)
	T.eq(#prof.Equipped, 1, "the UnequipPet remote unequips")
	for _, junk in ipairs({ 5, true, { "x" }, string.rep("a", 500), "" }) do
		advance(0.3)
		Mock.FromClient(R.EquipPet, p, junk)
		Mock.FromClient(R.UnequipPet, p, junk)
		Mock.FromClient(R.BuyRoulette, p, junk)
	end
	Mock.FromClient(R.EquipPet, p)
	advance(0.3)
	Mock.FromClient(R.BuyRoulette, p)
	advance(0.3)
	T.eq(#Mock.Errors, errs, "remotes with garbage arguments raise no errors")
	T.eq(DataS.GetTokens(p), 500, "...and cost nothing")
	T.eq(#prof.Equipped, 1, "...and change nothing")
	-- BuyRoulette remote: rate limited, failure answered with a RouletteResult
	advance(0.5)
	mark = logSize()
	Mock.FromClient(R.BuyRoulette, p, cloud.Id)
	Mock.FromClient(R.BuyRoulette, p, cloud.Id)
	advance(0.1)
	T.eq(DataS.GetTokens(p), 500 - cloud.Price, "BuyRoulette is rate limited: two calls inside 0.25 s charge once")
	local first = lastRemote("RouletteResult", p.UserId, mark)
	T.check(first and first.args[1] and first.args[1].Ok == true, "the remote answers a purchase with RouletteResult(Ok = true)")
	advance(0.4)
	mark = logSize()
	Mock.FromClient(R.BuyRoulette, p, "NoSuchRoulette")
	advance(0.1)
	local fail = lastRemote("RouletteResult", p.UserId, mark)
	T.check(fail and fail.args[1] and fail.args[1].Ok == false and type(fail.args[1].Reason) == "string", "an unknown roulette id is answered with RouletteResult(Ok = false, Reason)")
	setTokens(p, 0)
	advance(0.4)
	mark = logSize()
	Mock.FromClient(R.BuyRoulette, p, cloud.Id)
	advance(0.1)
	fail = lastRemote("RouletteResult", p.UserId, mark)
	T.check(fail and fail.args[1] and fail.args[1].Ok == false and tostring(fail.args[1].Reason):lower():find("token") ~= nil, "too few tokens: Ok = false with a reason that mentions tokens", fail and fail.args[1] and fail.args[1].Reason)

	-- shop prompts
	local info = W.lobbyInfo
	for _, r in ipairs(Config.Roulettes) do
		local prompt = info.Shop.Roulettes[r.Id].PromptPart:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			mark = logSize()
			advance(0.7)
			Mock.Trigger(prompt, p)
			advance(0.1)
			local e = lastRemote("OpenPanel", p.UserId, mark)
			T.check(e ~= nil and e.args[1] == "Shop" and type(e.args[2]) == "table" and e.args[2].Tab == "Roulette" and e.args[2].RouletteId == r.Id, "triggering the " .. r.Id .. " machine opens the Shop on its roulette tab", e and (tostring(e.args[1]) .. " " .. tostring(e.args[2] and e.args[2].Tab) .. " " .. tostring(e.args[2] and e.args[2].RouletteId)))
		end
	end
	local itemPrompt = info.Shop.ItemShop.PromptPart:FindFirstChildOfClass("ProximityPrompt")
	if itemPrompt then
		mark = logSize()
		advance(0.7)
		Mock.Trigger(itemPrompt, p)
		advance(0.1)
		local e = lastRemote("OpenPanel", p.UserId, mark)
		T.check(e ~= nil and e.args[1] == "Shop" and type(e.args[2]) == "table" and e.args[2].Tab == "Items", "triggering the item counter opens the Shop on its Items tab")
	end

	-- stats
	prof.Stats = { Matches = 0, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = {} }
	DataS.RecordMatch(p, "Easy", true, 123.4)
	T.check(prof.Stats.Matches == 1 and prof.Stats.Wins == 1 and prof.Stats.BestTimes.Easy == 123.4, "RecordMatch(win) counts the match, the win and the best time")
	DataS.RecordMatch(p, "Easy", true, 150)
	T.check(prof.Stats.Matches == 2 and prof.Stats.Wins == 2 and prof.Stats.BestTimes.Easy == 123.4, "a slower win keeps the best time")
	DataS.RecordMatch(p, "Easy", true, 99.5)
	T.eq(prof.Stats.BestTimes.Easy, 99.5, "a faster win improves it")
	DataS.RecordMatch(p, "Easy", false, 30)
	T.check(prof.Stats.Matches == 4 and prof.Stats.Wins == 3 and prof.Stats.BestTimes.Easy == 99.5, "a loss counts the match only")
	DataS.RecordMatch(p, "Saint", true, 500)
	T.eq(prof.Stats.BestTimes.Saint, 500, "best times are kept per difficulty")
	DataS.RecordMatch(p, "NoSuchDifficulty", true, 10)
	DataS.RecordMatch(p, "Hard", true, 0 / 0)
	DataS.RecordMatch(p, "Hard", true, -4)
	T.check(prof.Stats.BestTimes.NoSuchDifficulty == nil and prof.Stats.BestTimes.Hard == nil, "unknown difficulties and bad times are not recorded as best times")
	DataS.RecordMatch(nil, "Easy", true, 1)
	T.check(true, "RecordMatch(nil) is harmless")
	removePlayers({ p })
	indexFlow()
	flushErrors("economy")
	flushWarnings("economy")
end)

----------------------------------------------------------------------------------------------------
-- scenario: items
----------------------------------------------------------------------------------------------------
S.items = guarded("items", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local IS, DataS = mod("ItemService"), mod("DataService")
	local IC = M["shared/ItemCatalog"]
	local players = freshPlayers(3, "Item")
	local a, b, c = players[1], players[2], players[3]
	local prof = profileOf(a)
	local heal, shield, phoenix = IC.Get("heal_cloud"), IC.Get("shield_bubble"), IC.Get("phoenix_feather")

	-- buying
	setTokens(a, 1000)
	local mark = logSize()
	T.eq(select(1, IS.Buy(a, "heal_cloud", 1)), true, "Buy(heal_cloud, 1) works")
	T.eq(prof.Items.heal_cloud, 1, "...and adds one to Profile.Items")
	T.eq(DataS.GetTokens(a), 1000 - heal.Price, "...for exactly its price (" .. heal.Price .. ")")
	T.check(#snapshots(a, mark) >= 1, "...and sends a ProfileSync")
	T.eq(select(1, IS.Buy(a, "heal_cloud", 4)), true, "buying up to MaxCarry (" .. Config.Items.MaxCarry .. ") works")
	T.eq(prof.Items.heal_cloud, Config.Items.MaxCarry, "...the stack is now full")
	local tokens = DataS.GetTokens(a)
	local ok, why = IS.Buy(a, "heal_cloud", 1)
	T.check(ok == false and type(why) == "string", "buying beyond MaxCarry fails with a reason", tostring(why))
	T.eq(DataS.GetTokens(a), tokens, "...and costs nothing")
	T.eq(select(1, IS.Buy(a, "shield_bubble", Config.Items.MaxCarry + 1)), false, "a quantity above MaxCarry fails")
	T.eq(select(1, IS.Buy(a, "shield_bubble", 0)), false, "quantity 0 fails")
	T.eq(select(1, IS.Buy(a, "shield_bubble", -2)), false, "a negative quantity fails")
	T.eq(select(1, IS.Buy(a, "shield_bubble", 1.5)), false, "a fractional quantity fails")
	T.eq(select(1, IS.Buy(a, "shield_bubble", "3")), false, "a string quantity fails")
	T.eq(select(1, IS.Buy(a, "no_such_item", 1)), false, "an unknown item fails")
	T.eq(select(1, IS.Buy(a, nil, 1)), false, "Buy(nil) fails")
	T.eq(DataS.GetTokens(a), tokens, "all refused purchases are free")
	T.eq(select(1, IS.Buy(a, "shield_bubble")), true, "qty defaults to 1")
	T.eq(prof.Items.shield_bubble, 1, "...one shield")
	setTokens(a, 10)
	T.eq(select(1, IS.Buy(a, "phoenix_feather", 1)), false, "Buy with too few tokens fails")
	T.eq(DataS.GetTokens(a), 10, "...and keeps the tokens")
	setTokens(a, 1000)
	a:SetAttribute("InMatch", true)
	T.eq(select(1, IS.Buy(a, "phoenix_feather", 1)), false, "Buy is refused during a match")
	a:SetAttribute("InMatch", false)
	T.eq(select(1, IS.Buy(a, "phoenix_feather", 2)), true, "buy 2 phoenix feathers")
	T.eq(DataS.GetTokens(a), 1000 - 2 * phoenix.Price, "...at 2 x " .. phoenix.Price)
	-- the BuyItem remote
	local R = remoteFolder()
	setTokens(b, 500)
	advance(0.4)
	mark = logSize()
	Mock.FromClient(R.BuyItem, b, "heal_cloud", 2)
	advance(0.1)
	T.eq(profileOf(b).Items.heal_cloud, 2, "the BuyItem remote buys")
	T.check(notified(b, "Heal Cloud", "good", mark), "...and confirms with a toast")
	Mock.FromClient(R.BuyItem, b, "heal_cloud", 1)
	advance(0.05)
	T.eq(profileOf(b).Items.heal_cloud, 2, "BuyItem is rate limited")
	advance(0.4)
	local errs = #Mock.Errors
	for _, junk in ipairs({ 5, true, { "x" }, string.rep("a", 400) }) do
		Mock.FromClient(R.BuyItem, b, junk, 1)
		advance(0.3)
		Mock.FromClient(R.UseItem, b, junk)
		advance(0.3)
	end
	Mock.FromClient(R.BuyItem, b, "heal_cloud", "many")
	advance(0.3)
	Mock.FromClient(R.BuyItem, b, "heal_cloud", {})
	advance(0.3)
	T.eq(#Mock.Errors, errs, "BuyItem / UseItem with garbage arguments raise no errors")
	T.eq(profileOf(b).Items.heal_cloud, 2, "...and change nothing")

	-- using: not in a match
	local okUse, whyUse = IS.Use(a, "heal_cloud")
	T.check(okUse == false and type(whyUse) == "string", "Use outside a match fails with a reason", tostring(whyUse))
	T.eq(prof.Items.heal_cloud, Config.Items.MaxCarry, "...and consumes nothing")
	T.eq(select(1, IS.Use(a, "no_such_item")), false, "Use of an unknown item fails")

	-- in a match
	local m = startMatch("Easy", players)
	if not T.check(m ~= nil, "items: an Easy match starts") then
		removePlayers(players)
		return
	end
	toPlaying(m)
	K.waitNotInvulnerable(a)
	K.waitNotInvulnerable(b)
	K.waitNotInvulnerable(c)
	-- heal
	T.eq(select(1, IS.Use(a, "heal_cloud")), false, "heal_cloud at full health is refused")
	T.eq(prof.Items.heal_cloud, Config.Items.MaxCarry, "...and not consumed")
	DS().SetHealthFraction(a, 0.3)
	mark = logSize()
	T.eq(select(1, IS.Use(a, "heal_cloud")), true, "heal_cloud works when hurt")
	T.near(hum(a).Health, 30 + 0.4 * hum(a).MaxHealth, 1.5, "...and heals 40% of max health")
	T.eq(prof.Items.heal_cloud, Config.Items.MaxCarry - 1, "...consuming exactly one")
	T.check(#snapshots(a, mark) >= 1, "...with a ProfileSync")
	T.check(notified(a, ".", "good", mark), "...and a toast")
	T.eq(select(1, IS.Use(a, "heal_cloud")), false, "a second use inside the cooldown is refused (no double click burns)")
	advance(0.8)
	DS().SetHealthFraction(a, 0.1)
	advance(0.8)
	T.eq(select(1, IS.Use(a, "heal_cloud")), true, "...but works again after the short cooldown")
	-- shield
	advance(0.8)
	T.eq(DS().IsInvulnerable(a), false, "before the shield nothing protects the player")
	T.eq(select(1, IS.Use(a, "shield_bubble")), true, "shield_bubble works")
	T.eq(DS().IsInvulnerable(a), true, "...making the player invulnerable")
	T.eq(DS().Damage(a, 20, "Other"), false, "...so hits do nothing")
	advance(7.0)
	T.eq(DS().IsInvulnerable(a), true, "...for about 8 seconds")
	advance(1.4)
	T.eq(DS().IsInvulnerable(a), false, "...and no longer after 8.4 s")
	T.eq(prof.Items.shield_bubble, nil, "the used-up item disappears from the profile (count 0 -> nil)")
	T.eq(select(1, IS.Use(a, "shield_bubble")), false, "using an item the player does not have fails")
	-- phoenix: nobody downed
	local nobody = IS.Use(a, "phoenix_feather")
	T.eq(nobody, false, "phoenix_feather without a downed teammate is refused")
	T.eq(prof.Items.phoenix_feather, 2, "...and not consumed")
	-- two downed teammates: the nearest is revived
	K.waitNotInvulnerable(b)
	K.waitNotInvulnerable(c)
	Mock.Teleport(a, m.Course.StartCFrame.Position + Vector3.new(0, 4, 0))
	Mock.Teleport(b, m.Course.StartCFrame.Position + Vector3.new(6, 4, 0))
	Mock.Teleport(c, m.Course.StartCFrame.Position + Vector3.new(0, 4, 18))
	advance(0.3)
	DS().Damage(b, 999, "Other", { IgnoreIFrames = true })
	DS().Damage(c, 999, "Other", { IgnoreIFrames = true })
	advance(0.5)
	T.check(DS().IsDowned(b) and DS().IsDowned(c), "two teammates are downed")
	mark = logSize()
	profileOf(b).Items.phoenix_feather = 1
	T.eq(select(1, IS.Use(b, "phoenix_feather")), false, "a downed player cannot use items")
	T.eq(profileOf(b).Items.phoenix_feather, 1, "...and nothing is consumed")
	profileOf(b).Items.phoenix_feather = nil
	advance(0.8)
	T.eq(select(1, IS.Use(a, "phoenix_feather")), true, "phoenix_feather revives a downed teammate")
	T.check(not DS().IsDowned(b) and DS().IsDowned(c), "...the NEAREST one (b, 6 studs) and not the farther one (c, 18 studs)")
	T.near(hum(b).Health, hum(b).MaxHealth * Config.Damage.ReviveHealthFraction, 3, "...with 50% health")
	T.eq(b:GetAttribute("Downed"), false, "...Downed attribute cleared")
	T.eq(prof.Items.phoenix_feather, 1, "the feather is consumed")
	T.check(notified(b, "revived", "good", mark), "the revived player is told who helped")
	advance(0.8)
	T.eq(select(1, IS.Use(a, "phoenix_feather")), true, "the second feather revives the other teammate")
	T.check(not DS().IsDowned(c), "...c is up")
	T.eq(prof.Items.phoenix_feather, nil, "all feathers are used up")
	-- the UseItem remote
	profileOf(b).Items.heal_cloud = 2
	DS().SetHealthFraction(b, 0.2)
	K.waitNotInvulnerable(b)
	advance(0.4)
	Mock.FromClient(R.UseItem, b, "heal_cloud")
	advance(0.1)
	T.eq(profileOf(b).Items.heal_cloud, 1, "the UseItem remote uses an item")
	-- leave: items no longer work
	endAllMatches(players)
	advance(1)
	T.eq(select(1, IS.Use(a, "heal_cloud")), false, "items stop working after the match")
	removePlayers(players)
	flushErrors("items")
	flushWarnings("items")
end)

----------------------------------------------------------------------------------------------------
-- scenario: match locks (items during the countdown, pets during a match)
--
--   * ItemService.Use is refused while the match is still in State "Countdown" (or Setup): the intro freeze already
--     grants invulnerability, so a shield or heal used then would be burned for nothing. Nothing is consumed and no
--     cooldown starts, so the same item works the moment the match reaches "Playing".
--   * PetService.Equip / Unequip return false, "Pets are locked during a match" while InMatch is true (countdown and
--     play alike; the pets in a match must be the ones the player entered with) and work again after the match.
----------------------------------------------------------------------------------------------------
S.match_locks = guarded("match_locks", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local IS, PS, DataS = mod("ItemService"), mod("PetService"), mod("DataService")
	local R = remoteFolder()
	local players = freshPlayers(2, "Lock")
	local a, b = players[1], players[2]
	local prof = profileOf(a)
	local petA, petB = petOfRarity("Common", 1), petOfRarity("Common", 2)
	grant(a, petA, 1)
	grant(a, petB, 1)
	prof.Items.heal_cloud = 2
	prof.Items.shield_bubble = 2
	DataS.MarkDirty(a)
	DataS.Sync(a)
	local perksChanged = 0
	local conn = PS.PerksChanged:Connect(function()
		perksChanged = perksChanged + 1
	end)
	T.eq(select(1, PS.Equip(a, petA)), true, "locks: a pet can be equipped in the lobby")
	T.eq(equippedAttr(a), petA, "...and the EquippedPets attribute follows")
	local baseline = perksChanged

	-- inside the countdown
	local m = startMatch("Easy", players)
	if not T.check(m ~= nil, "locks: an Easy match starts") then
		conn:Disconnect()
		removePlayers(players)
		return
	end
	T.eq(m.State, "Countdown", "locks: the match is in its intro countdown")
	T.eq(a:GetAttribute("InMatch"), true, "locks: InMatch is true")
	DS().SetHealthFraction(a, 0.5)
	local healthBefore = hum(a).Health
	local mark = logSize()
	local ok, why = IS.Use(a, "heal_cloud")
	T.check(ok == false and type(why) == "string" and why:lower():find("countdown", 1, true) ~= nil, "locks: heal_cloud is refused during the countdown (with the reason)", tostring(ok) .. " " .. tostring(why))
	T.eq(prof.Items.heal_cloud, 2, "...the heal_cloud count is unchanged")
	T.near(hum(a).Health, healthBefore, 0.01, "...and so is the health")
	ok, why = IS.Use(a, "shield_bubble")
	T.check(ok == false and type(why) == "string" and why:lower():find("countdown", 1, true) ~= nil, "locks: shield_bubble is refused during the countdown", tostring(ok) .. " " .. tostring(why))
	T.eq(prof.Items.shield_bubble, 2, "...the shield_bubble count is unchanged")
	Mock.FromClient(R.UseItem, a, "heal_cloud")
	advance(0.1)
	T.eq(prof.Items.heal_cloud, 2, "...also through the UseItem remote")
	T.eq(#snapshots(a, mark), 0, "...and nothing is synced (no profile change)")
	-- pets
	ok, why = PS.Equip(a, petB)
	T.check(ok == false and why == "Pets are locked during a match", "locks: Equip is refused during the countdown with 'Pets are locked during a match'", tostring(ok) .. " " .. tostring(why))
	ok, why = PS.Unequip(a, petA)
	T.check(ok == false and why == "Pets are locked during a match", "locks: Unequip is refused during the countdown", tostring(ok) .. " " .. tostring(why))
	T.eq(table.concat(prof.Equipped, ","), petA, "...Profile.Equipped is unchanged")
	T.eq(equippedAttr(a), petA, "...and so is the EquippedPets attribute")
	advance(0.3)
	Mock.FromClient(R.EquipPet, a, petB)
	advance(0.3)
	Mock.FromClient(R.UnequipPet, a, petA)
	advance(0.3)
	T.eq(table.concat(prof.Equipped, ","), petA, "...also through the EquipPet / UnequipPet remotes")
	T.eq(perksChanged, baseline, "...and PerksChanged never fired")

	-- play: items work right away (the refusal did not start a cooldown), pets stay locked
	T.check(toPlaying(m), "locks: the match reaches Playing")
	K.waitNotInvulnerable(a)
	ok, why = IS.Use(a, "heal_cloud")
	T.check(ok == true, "locks: the same heal_cloud works once the match is Playing", tostring(why))
	T.eq(prof.Items.heal_cloud, 1, "...consuming exactly one")
	ok, why = PS.Equip(a, petB)
	T.check(ok == false and why == "Pets are locked during a match", "locks: Equip is still refused while playing", tostring(why))
	T.eq(table.concat(prof.Equipped, ","), petA, "...nothing changed")

	-- after the match both work again
	endAllMatches(players)
	advance(1.5)
	T.eq(a:GetAttribute("InMatch"), false, "locks: InMatch is false after the match")
	T.eq(select(1, PS.Equip(a, petB)), true, "locks: Equip works again after the match")
	T.eq(table.concat(prof.Equipped, ","), petA .. "," .. petB, "...both pets are equipped")
	T.eq(select(1, PS.Unequip(a, petA)), true, "locks: Unequip works again after the match")
	T.eq(table.concat(prof.Equipped, ","), petB, "...only the second pet is left")
	T.check(perksChanged > baseline, "...and PerksChanged fires for the real changes")
	T.eq(select(1, IS.Use(a, "heal_cloud")), false, "locks: items stay unusable outside a match")

	-- the attribute alone locks too (it is what the rule reads), and clearing it unlocks
	b:SetAttribute("InMatch", true)
	grant(b, petA, 1)
	T.eq(select(1, PS.Equip(b, petA)), false, "locks: InMatch = true alone refuses Equip")
	b:SetAttribute("InMatch", false)
	T.eq(select(1, PS.Equip(b, petA)), true, "...and InMatch = false allows it")

	conn:Disconnect()
	removePlayers(players)
	flushErrors("match_locks")
	flushWarnings("match_locks")
end)

----------------------------------------------------------------------------------------------------
-- scenario: ProfileSync
----------------------------------------------------------------------------------------------------
S.profile_sync = guarded("profile_sync", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local DataS, PS, IS = mod("DataService"), mod("PetService"), mod("ItemService")
	local mark = logSize()
	local p = Mock.AddPlayer("Syncer", 920001)
	advance(1.0)
	local snaps = snapshots(p, mark)
	T.check(#snaps >= 1, "a ProfileSync is sent on join (after the load)", #snaps .. " snapshots")
	local first = snaps[1]
	if T.check(first ~= nil, "the first snapshot exists") then
		local problems = V.profileSync(first)
		T.check(#problems == 0, "the join snapshot has the documented shape", table.concat(problems, "; "))
		T.check(first.Tokens == 0 and next(first.Pets) == nil and #first.Equipped == 0 and next(first.Items) == nil, "a new player's snapshot is empty")
		local perks = first.Perks
		T.check(perks and perks.MaxHealth == 0 and perks.TokenBonus == 0 and perks.StaminaRegen == 0 and perks.CheckpointHeal == 0, "...with all four perks at 0")
		T.check(first.SpotIndex == nil or type(first.SpotIndex) == "number", "SpotIndex is a number or absent")
		-- v3: Discovered, IndexClaimed, Tutorial travel in the snapshot (Phase 2: Cash / Gems too, and their attributes)
		T.check(type(first.Discovered) == "table" and next(first.Discovered) == nil and type(first.IndexClaimed) == "table" and next(first.IndexClaimed) == nil,
			"v3: the join snapshot carries empty Discovered / IndexClaimed sets")
		T.check(type(first.Tutorial) == "table" and first.Tutorial.Step == 1 and first.Tutorial.Done == false and first.Tutorial.Gifted == false, "v3: ...and Tutorial = { Step = 1, Done = false, Gifted = false }")
		T.check(p:GetAttribute(Config.Attr.Cash) == 0 and p:GetAttribute(Config.Attr.Gems) == 0 and first.Cash == 0 and first.Gems == 0,
			"Phase 2: a new player's Cash / Gems attributes (the HUD currency stack) and snapshot read 0")
	end
	-- RequestProfile
	mark = logSize()
	Mock.FromClient(remoteFolder().RequestProfile, p)
	advance(0.1)
	T.eq(#snapshots(p, mark), 1, "RequestProfile answers with a fresh ProfileSync")
	Mock.FromClient(remoteFolder().RequestProfile, p)
	advance(0.1)
	T.eq(#snapshots(p, mark), 1, "...and is rate limited")
	advance(0.7)
	Mock.FromClient(remoteFolder().RequestProfile, p)
	advance(0.1)
	T.eq(#snapshots(p, mark), 2, "...but answers again after the cooldown")
	-- mutations push a snapshot
	setTokens(p, 600)
	local prof = profileOf(p)
	grant(p, CONTRACT.v2.mascotPetId, 2)
	grant(p, petOfRarity("Common", 1), 1)
	advance(0.3)
	mark = logSize()
	PS.Equip(p, CONTRACT.v2.mascotPetId)
	local afterEquip = snapshots(p, mark)
	T.check(#afterEquip >= 1, "Equip sends a ProfileSync")
	local last = afterEquip[#afterEquip]
	T.check(last and last.Equipped[1] == CONTRACT.v2.mascotPetId and last.Perks.TokenBonus > 0, "...that already contains the new equip and its perks")
	mark = logSize()
	IS.Buy(p, "heal_cloud", 2)
	local afterBuy = snapshots(p, mark)
	T.check(#afterBuy >= 1 and afterBuy[#afterBuy].Items.heal_cloud == 2, "buying an item sends a ProfileSync with the new count")
	mark = logSize()
	PS.BuyRoulette(p, Config.Roulettes[1].Id)
	local afterSpin = snapshots(p, mark)
	T.check(#afterSpin >= 1 and afterSpin[#afterSpin].Stats.Spins == 1, "buying a roulette sends a ProfileSync with Stats.Spins = 1")
	-- snapshots are copies: no table is shared with the live profile, and an old snapshot does not change later
	local snap = afterSpin[#afterSpin]
	if snap then
		T.check(snap.Pets ~= prof.Pets and snap.Equipped ~= prof.Equipped and snap.Items ~= prof.Items and snap.Stats ~= prof.Stats and snap.Stats.BestTimes ~= prof.Stats.BestTimes
			and snap.Discovered ~= prof.Discovered and snap.IndexClaimed ~= prof.IndexClaimed and snap.Tutorial ~= prof.Tutorial,
			"a snapshot shares no table with the live profile")
		T.check(snap.Discovered[CONTRACT.v2.mascotPetId] == true, "v3: owned pets appear in the snapshot's Discovered set")
		local petsInSnap, itemsInSnap = 0, snap.Items.heal_cloud
		for _, n in pairs(snap.Pets) do
			petsInSnap = petsInSnap + n
		end
		grant(p, petOfRarity("Epic", 1), 4)
		profileOf(p).Items.heal_cloud = 5
		profileOf(p).Stats.Wins = profileOf(p).Stats.Wins + 1
		local petsNow = 0
		for _, n in pairs(snap.Pets) do
			petsNow = petsNow + n
		end
		T.check(petsNow == petsInSnap and snap.Items.heal_cloud == itemsInSnap and snap.Pets[petOfRarity("Epic", 1)] == nil, "...so an old snapshot does not follow later profile changes")
		profileOf(p).Items.heal_cloud = itemsInSnap
		profileOf(p).Stats.Wins = profileOf(p).Stats.Wins - 1
		profileOf(p).Pets[petOfRarity("Epic", 1)] = nil
	end
	-- the whole log so far is well-formed
	local bad = 0
	local firstBad
	for _, e in ipairs(remotesFor("ProfileSync", nil, 0)) do
		local problems = V.profileSync(e.args[1])
		if #problems > 0 then
			bad = bad + 1
			firstBad = firstBad or table.concat(problems, "; ")
		end
	end
	T.check(bad == 0, "every ProfileSync of the run so far matches the documented shape", bad .. " bad, first: " .. tostring(firstBad))
	-- tokens travel through the attribute, not the snapshot
	local tokensNow = p:GetAttribute("CloudTokens")
	DataS.AddTokens(p, 7)
	T.eq(p:GetAttribute("CloudTokens"), tokensNow + 7, "token changes are visible through the CloudTokens attribute")
	removePlayers({ p })
	flushErrors("profile_sync")
	flushWarnings("profile_sync")
end)

----------------------------------------------------------------------------------------------------
-- scenario: v1 -> v2 migration + untrusted stored data
----------------------------------------------------------------------------------------------------
S.migration = guarded("migration", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local DataS = mod("DataService")
	local v2 = Config.Tokens.DataStoreName
	local v1 = Config.Tokens.LegacyDataStoreName
	local data = Mock.DataStore.Data
	-- a v1 save becomes the v2 starting balance
	data[v1 .. "/u_930001"] = { Tokens = 123 }
	local p = joinWithId("Veteran", 930001)
	T.eq(p:GetAttribute("CloudTokens"), 123, "a v1 save ({ Tokens = 123 } in " .. v1 .. ") is migrated: CloudTokens = 123")
	T.eq(p.leaderstats.Tokens.Value, 123, "...also on leaderstats")
	local prof = profileOf(p)
	T.check(prof and prof.Version == 2 and next(prof.Pets) == nil and prof.Stats.Spins == 0, "...inside an otherwise empty v2 profile")
	DataS.AddTokens(p, 10)
	Mock.RemovePlayer(p)
	advance(2.0)
	local stored = data[v2 .. "/u_930001"]
	T.check(type(stored) == "table" and stored.Version == 2 and stored.Tokens == 133, "leaving writes the v2 profile under " .. v2 .. " (Version 2, Tokens 133)", stored and ("Version " .. tostring(stored.Version) .. " Tokens " .. tostring(stored.Tokens)) or "nothing stored")
	T.check(type(data[v1 .. "/u_930001"]) == "table" and data[v1 .. "/u_930001"].Tokens == 123, "the legacy v1 key is never modified")
	local again = joinWithId("Veteran", 930001)
	T.eq(again:GetAttribute("CloudTokens"), 133, "rejoining reads the v2 save (the v1 tokens are not added a second time)")
	DataS.SpendTokens(again, 100)
	Mock.RemovePlayer(again)
	advance(2.0)
	local third = joinWithId("Veteran", 930001)
	T.eq(third:GetAttribute("CloudTokens"), 33, "spent tokens stay spent: the old v1 value does not come back")
	removePlayers({ third })
	advance(1.0)

	-- garbage in the legacy save
	data[v1 .. "/u_930002"] = { Tokens = -50 }
	data[v1 .. "/u_930003"] = { Tokens = "lots" }
	data[v1 .. "/u_930004"] = 77 -- a bare number
	local g1 = joinWithId("G1", 930002)
	local g2 = joinWithId("G2", 930003)
	local g3 = joinWithId("G3", 930004)
	T.eq(g1:GetAttribute("CloudTokens"), 0, "a negative v1 balance becomes 0")
	T.eq(g2:GetAttribute("CloudTokens"), 0, "a non-numeric v1 balance becomes 0")
	T.eq(g3:GetAttribute("CloudTokens"), 77, "a bare-number v1 save is accepted")
	removePlayers({ g1, g2, g3 })
	advance(1.0)

	-- untrusted v2 data is normalised on load
	local PC = M["shared/PetCatalog"]
	local a, b = petOfRarity("Common", 1), petOfRarity("Uncommon", 1)
	data[v2 .. "/u_930005"] = {
		Version = 2, Tokens = 5.9, SpotIndex = 99,
		Pets = { [a] = 500, [b] = 1, ghost_pet = 3, negative = -4, zero = 0 },
		Equipped = { a, a, b, b, "ghost_pet", a, "not_owned" },
		Items = { heal_cloud = 40, shield_bubble = -1 },
		Stats = { Matches = -3, Wins = "x", TokensEarned = 12, Spins = 2.7, BestTimes = { Easy = 88.8, Hard = -1 } },
	}
	local h = joinWithId("Hostile", 930005)
	local hp = profileOf(h)
	T.check(hp ~= nil, "a profile with hostile stored data loads")
	if hp then
		T.eq(hp.Tokens, 5, "fractional tokens are floored")
		T.eq(hp.Pets[a], Config.Pets.MaxPerStack, "pet counts are clamped to MaxPerStack")
		T.check(hp.Pets.negative == nil and hp.Pets.zero == nil, "non-positive pet counts are dropped")
		T.eq(hp.Items.heal_cloud, Config.Items.MaxCarry, "item counts are clamped to MaxCarry")
		T.eq(hp.Items.shield_bubble, nil, "negative item counts are dropped")
		T.check(#hp.Equipped <= Config.Pets.MaxEquipped, "Equipped is trimmed to Config.Pets.MaxEquipped", #hp.Equipped .. " entries")
		local used = {}
		local legal = true
		for _, id in ipairs(hp.Equipped) do
			used[id] = (used[id] or 0) + 1
			if used[id] > (hp.Pets[id] or 0) or not PC.Get(id) then
				legal = false
			end
		end
		T.check(legal, "...every entry is owned (at most `count` times) and a known pet", table.concat(hp.Equipped, ","))
		T.check(hp.SpotIndex == nil or (hp.SpotIndex >= 1 and hp.SpotIndex <= Config.Lobby.SpotCount), "an out-of-range SpotIndex is not trusted", tostring(hp.SpotIndex))
		T.check(hp.Stats.Matches == 0 and hp.Stats.Wins == 0 and hp.Stats.TokensEarned == 12 and hp.Stats.Spins == 2, "stats are sanitised to non-negative integers")
		T.check(hp.Stats.BestTimes.Easy == 88.8 and hp.Stats.BestTimes.Hard == nil, "best times keep valid entries only")
		T.eq(h:GetAttribute("EquippedPets"), table.concat(hp.Equipped, ","), "the EquippedPets attribute is set from the validated Equipped list on load")
	end
	removePlayers({ h })
	advance(1.0)

	-- v3 (ARCHITECTURE_V3.md section 1): a stored v2 profile gains the v3 fields with their defaults, owned pets count
	-- as discovered, and hostile v3 values are cleaned
	data[v2 .. "/u_930008"] = { Version = 2, Tokens = 9, Pets = { [a] = 2, [b] = 1 }, Equipped = { a }, Items = {}, Stats = { Matches = 1, Wins = 1, TokensEarned = 9, Spins = 3, BestTimes = {} } }
	local old = joinWithId("OldTimer", 930008)
	local op = profileOf(old)
	if T.check(op ~= nil, "v3 migration: a v2 profile without the v3 fields loads") then
		T.check(op.Discovered[a] == true and op.Discovered[b] == true, "v3 migration: pets owned at migration time count as discovered")
		T.check(type(op.IndexClaimed) == "table" and next(op.IndexClaimed) == nil, "v3 migration: IndexClaimed starts empty")
		T.check(type(op.Tutorial) == "table" and op.Tutorial.Step == 1 and op.Tutorial.Done == false and op.Tutorial.Gifted == false, "v3 migration: Tutorial = { Step = 1, Done = false, Gifted = false }")
		T.check(op.Cash == 0 and op.Gems == 0 and type(op.Home) == "table" and op.Home.Level == 0 and op.Home.Prestige == 0 and type(op.Home.Rooms) == "table" and type(op.PetLevels) == "table",
			"v3 migration: the phase 2/3 reserves exist with defaults (Cash 0, Gems 0, Home Level 0 / Prestige 0, PetLevels {})")
		T.eq(op.Tokens, 9, "v3 migration: the v2 fields are untouched")
	end
	removePlayers({ old })
	advance(1.0)
	local storedOld = data[v2 .. "/u_930008"]
	T.check(type(storedOld) == "table" and type(storedOld.Discovered) == "table" and storedOld.Discovered[a] == true and type(storedOld.Tutorial) == "table",
		"v3 migration: the save written on leave contains Discovered and Tutorial")
	data[v2 .. "/u_930009"] = {
		Version = 2, Tokens = 1, Pets = { [a] = 1 }, Equipped = {}, Items = {}, Stats = { Matches = 0, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = {} },
		Discovered = { [b] = true, junk = "yes", [5] = a }, IndexClaimed = { Common = true, Bogus = 7 },
		Tutorial = { Step = -5, Done = "yes", Gifted = 1 }, Cash = -40, Gems = 0 / 0, Home = { Level = "max", Rooms = { Kitchen = 3, [7] = 1 }, Prestige = -2 },
		PetLevels = { [a] = { Level = -3, Xp = -10 }, [b] = 4 },
	}
	local hv = joinWithId("HostileV3", 930009)
	local hp3 = profileOf(hv)
	if T.check(hp3 ~= nil, "v3: a profile with hostile v3 fields loads") then
		T.check(hp3.Discovered[a] == true and hp3.Discovered[b] == true and hp3.Discovered.junk == nil, "v3: Discovered keeps true entries (and owned pets), drops junk values")
		T.check(hp3.IndexClaimed.Common == true and hp3.IndexClaimed.Bogus == nil, "v3: IndexClaimed keeps true entries only")
		T.check(hp3.Tutorial.Step == 1 and hp3.Tutorial.Done == false and hp3.Tutorial.Gifted == false, "v3: a hostile Tutorial table is reset to { Step = 1, Done = false, Gifted = false }")
		T.check(hp3.Cash == 0 and hp3.Gems == 0 and hp3.Home.Level == 0 and hp3.Home.Prestige == 0 and hp3.Home.Rooms.Kitchen == 3, "v3: Cash / Gems / Home are sanitised to non-negative integers")
		T.check(hp3.PetLevels[a] and hp3.PetLevels[a].Level == 1 and hp3.PetLevels[a].Xp == 0 and hp3.PetLevels[b] and hp3.PetLevels[b].Level == 4, "v3: PetLevels entries are sanitised ({ Level >= 1, Xp >= 0 })")
	end
	removePlayers({ hv })
	advance(1.0)

	-- an Equipped list with an id the catalog no longer knows loses it on load
	data[v2 .. "/u_930006"] = { Version = 2, Tokens = 1, Pets = { [a] = 1, retired_pet = 1 }, Equipped = { "retired_pet", a }, Items = {}, Stats = { Matches = 0, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = {} } }
	local r = joinWithId("Retiree", 930006)
	local rp = profileOf(r)
	T.check(rp and #rp.Equipped == 1 and rp.Equipped[1] == a, "pets that left the catalog are removed from Equipped on load", rp and table.concat(rp.Equipped, ","))
	T.eq(r:GetAttribute("EquippedPets"), a, "...and from the EquippedPets attribute")
	removePlayers({ r })

	-- a failing DataStore does not lose the legacy save
	Mock.DataStore.Fail = true
	local f = Mock.AddPlayer("Offline", 930007)
	advance(5)
	Mock.DataStore.Fail = false
	T.check(f.Parent ~= nil and root(f) ~= nil, "a DataStore outage during the load lets the player in")
	T.eq(f:GetAttribute("CloudTokens"), 0, "...with 0 tokens")
	removePlayers({ f })
	advance(3)
	flushErrors("migration")
	flushWarnings("migration", { "DataStore", "Load", "load", "Save", "save", "DataService" })
end)

----------------------------------------------------------------------------------------------------
-- scenario: the match lifecycle on all five difficulties
----------------------------------------------------------------------------------------------------
S.match_difficulties = guarded("match_difficulties", function()
	if not needBoot() then
		return
	end
	local Config = config()
	for _, diff in ipairs(Config.Difficulties) do
		local players = freshPlayers(2, "Lv" .. diff.Id)
		local a, b = players[1], players[2]
		local tag = diff.Id .. ": "
		-- start through the portal like a real game for the first and last level, directly for the others
		local m
		if diff.Id == "Saint" then
			K.enterPortal(a, diff.Id)
			K.enterPortal(b, diff.Id)
			local started = waitFor(function()
				return MS().GetMatchOf(a) ~= nil
			end, Config.Match.PartyCountdown + 6)
			T.check(started, tag .. "the party launches from the portal")
			m = MS().GetMatchOf(a)
			advance(0.2)
		else
			m = startMatch(diff.Id, players)
		end
		if not T.check(m ~= nil, tag .. "a match starts") then
			removePlayers(players)
		else
			local st = K.state(a)
			T.check(st ~= nil and st.Phase == "Countdown" and st.DifficultyId == diff.Id and st.DifficultyName == diff.DisplayName, tag .. "MatchState carries the difficulty id and name during the intro")
			T.check(st ~= nil and st.Color == diff.Color, tag .. "MatchState.Color is the difficulty colour")
			T.eq(st and st.TotalCheckpoints, diff.Stages, tag .. "TotalCheckpoints = Stages (" .. diff.Stages .. ")")
			T.check(m.Course.TotalTokens > 0 and st and st.TotalTokens == m.Course.TotalTokens, tag .. "TotalTokens = the course's token value (" .. tostring(m.Course.TotalTokens) .. ")")
			T.eq(#K.tagged(Config.Tags.Checkpoint, m.Course.Folder), diff.Stages, tag .. "the course has one tagged checkpoint per stage")
			T.check(type(m.Course.Archetype) == "string" and type(m.Course.Themes) == "table" and #m.Course.Themes == diff.Stages, tag .. "CourseInfo.Archetype / Themes are set (" .. tostring(m.Course.Archetype) .. ")")
			T.check(toPlaying(m), tag .. "the intro ends and play starts")
			advance(0.4)
			st = K.state(a)
			T.check(st and st.Seconds > diff.TimeLimit - 20 and st.Seconds <= diff.TimeLimit, tag .. "the timer starts at the difficulty's TimeLimit (" .. diff.TimeLimit .. " s)", st and tostring(st.Seconds))
			local problems = V.matchState(st)
			T.check(#problems == 0, tag .. "MatchState payload is valid", table.concat(problems, ", "))
			K.waitNotInvulnerable(a)
			K.waitNotInvulnerable(b)
			-- void damage of this difficulty
			local mark = logSize()
			Mock.Teleport(b, Vector3.new(m.Course.StartCFrame.Position.X, m.Course.KillY - 30, m.Course.StartCFrame.Position.Z))
			advance(1.2)
			local vd = remotesFor("DamageTaken", b.UserId, mark)[1]
			T.check(vd ~= nil and vd.args[2] == "Void" and vd.args[1] == Config.Damage.VoidDamage[diff.Id], tag .. "the void deals VoidDamage (" .. Config.Damage.VoidDamage[diff.Id] .. ")", vd and (tostring(vd.args[1]) .. " " .. tostring(vd.args[2])))
			-- run every checkpoint in order
			local ordered = true
			for i = 1, diff.Stages do
				local cp = m.Course.Checkpoints[i]
				Mock.Teleport(a, cp.Part.Position + Vector3.new(0, 3.5, 0))
				Mock.Teleport(b, cp.Part.Position + Vector3.new(0, 3.5, 0))
				advance(0.55)
				if m.Checkpoint ~= i then
					ordered = false
				end
			end
			T.check(ordered and m.Checkpoint == diff.Stages, tag .. "all " .. diff.Stages .. " checkpoints are reached in order", "match.Checkpoint = " .. tostring(m.Checkpoint))
			-- win
			local fin = m.Course.Finish
			mark = logSize()
			local before = {
				a = profileOf(a) and profileOf(a).Stats.Matches, b = profileOf(b) and profileOf(b).Stats.Matches,
				wins = profileOf(a) and profileOf(a).Stats.Wins, tokens = a:GetAttribute("CloudTokens"),
			}
			Mock.Teleport(a, fin.Position + Vector3.new(0, fin.Size.Y / 2 + 3.5, 0))
			advance(0.5)
			Mock.Teleport(b, fin.Position + Vector3.new(0, fin.Size.Y / 2 + 3.5, 0))
			advance(1.2)
			local res = K.lastRemote("MatchResult", a.UserId, mark)
			if T.check(res ~= nil, tag .. "MatchResult is sent on victory") then
				local r = res.args[1]
				local problems2 = V.matchResult(r)
				T.check(#problems2 == 0, tag .. "MatchResult payload is valid", table.concat(problems2, ", "))
				T.check(r.Won == true and r.Reason == "victory" and r.DifficultyId == diff.Id, tag .. "MatchResult: Won / victory / DifficultyId")
				T.eq(r.Stars, diff.Stars, tag .. "MatchResult.Stars = " .. diff.Stars)
				T.eq(r.Bonus, Config.Match.TokenBonusOnWin[diff.Id], tag .. "MatchResult.Bonus = TokenBonusOnWin (" .. Config.Match.TokenBonusOnWin[diff.Id] .. ")")
				T.eq(r.TotalTokens, m.Course.TotalTokens, tag .. "MatchResult.TotalTokens")
				local delta = a:GetAttribute("CloudTokens") - before.tokens
				T.check(delta >= Config.Match.TokenBonusOnWin[diff.Id] and delta <= Config.Match.TokenBonusOnWin[diff.Id] + 8, tag .. "the win bonus is added to the lifetime tokens", "gained " .. tostring(delta))
				local sa, sb = profileOf(a).Stats, profileOf(b).Stats
				T.check(sa.Matches == before.a + 1 and sb.Matches == before.b + 1, tag .. "RecordMatch counts the match for both players")
				T.check(sa.Wins == before.wins + 1, tag .. "...a win for each finisher")
				T.check(sa.BestTimes[diff.Id] ~= nil and abs(sa.BestTimes[diff.Id] - r.Seconds) <= 2, tag .. "...and the best time (" .. tostring(sa.BestTimes[diff.Id]) .. " vs " .. tostring(r.Seconds) .. ")")
			end
			advance(Config.Match.EndScreenSeconds + 1.5)
			K.lobbyCheck(a, tag .. "winner")
			T.eq(#K.courseFolders(), 0, tag .. "the course is destroyed after the match")
			removePlayers(players)
		end

		-- defeat on the same difficulty
		local losers = freshPlayers(2, "Lo" .. diff.Id)
		local m2 = startMatch(diff.Id, losers)
		if m2 then
			toPlaying(m2)
			K.waitNotInvulnerable(losers[1])
			K.waitNotInvulnerable(losers[2])
			local mark = logSize()
			DS().Damage(losers[1], 9999, "Lightning", { IgnoreIFrames = true })
			DS().Damage(losers[2], 9999, "Storm", { IgnoreIFrames = true })
			advance(1.2)
			local res = K.lastRemote("MatchResult", losers[1].UserId, mark)
			T.check(res ~= nil and res.args[1].Won == false and res.args[1].Reason == "defeat" and res.args[1].Stars == diff.Stars and res.args[1].Bonus == 0, tag .. "everybody downed: defeat with Stars and no bonus")
			local prof = profileOf(losers[1])
			T.check(prof and prof.Stats.Matches >= 1 and prof.Stats.Wins == 0, tag .. "a defeat counts the match but no win")
			advance(Config.Match.EndScreenSeconds + 1.5)
			K.lobbyCheck(losers[1], tag .. "loser")
		else
			T.fail(tag .. "a second match starts for the defeat test")
		end
		endAllMatches(losers)
		removePlayers(losers)
		flushErrors("match_difficulties " .. diff.Id)
	end
	-- timeout on a difficulty with a shortened limit
	local hard = Config.GetDifficulty("Hard")
	local original = hard.TimeLimit
	local limit = ARGS.quick and 30 or 60
	hard.TimeLimit = limit
	local one = freshPlayers(1, "Slowpoke")
	local m3 = startMatch("Hard", one)
	if m3 then
		toPlaying(m3)
		local mark = logSize()
		local saved = Mock.Options.StepSize
		Mock.Options.StepSize = 0.2
		local reached = waitFor(function()
			return m3.State == "Ended"
		end, limit + 10)
		Mock.Options.StepSize = saved
		local res = K.lastRemote("MatchResult", one[1].UserId, mark)
		T.check(reached and res ~= nil and res.args[1].Reason == "timeout" and res.args[1].Stars == hard.Stars and res.args[1].DifficultyId == "Hard", "Hard: the time limit ends the match with Reason = timeout and Stars")
	end
	hard.TimeLimit = original
	endAllMatches(one)
	removePlayers(one)
	flushErrors("match_difficulties")
	flushWarnings("match_difficulties")
end)

----------------------------------------------------------------------------------------------------
-- scenario: pets inside a match
----------------------------------------------------------------------------------------------------
S.match_pets = guarded("match_pets", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local DataS, PS = mod("DataService"), mod("PetService")
	local PC = M["shared/PetCatalog"]
	local players = freshPlayers(3, "PetMatch")
	local a, b, c = players[1], players[2], players[3]
	local dragon = CONTRACT.v2.mascotPetId
	-- a: three dragons (+75% tokens, +36% health); b: the best checkpoint-heal pet; c: no pets
	grant(a, dragon, 3)
	for _ = 1, 3 do
		PS.Equip(a, dragon)
	end
	local healPet
	for _, def in ipairs(PC.Pets) do
		if (def.Perks.CheckpointHeal or 0) > 0 and (not healPet or def.Perks.CheckpointHeal > healPet.Perks.CheckpointHeal) then
			healPet = def
		end
	end
	if T.check(healPet ~= nil, "the catalog has a pet with a CheckpointHeal perk") then
		grant(b, healPet.Id, 3)
		for _ = 1, 3 do
			PS.Equip(b, healPet.Id)
		end
	end
	advance(0.4)
	local perksA, perksB = PS.GetPerks(a), PS.GetPerks(b)
	local m = startMatch("Easy", players)
	if not T.check(m ~= nil, "pets: a match starts") then
		removePlayers(players)
		return
	end
	toPlaying(m)
	advance(0.4)
	T.near(hum(a).MaxHealth, Config.Physics.MaxHealth * (1 + perksA.MaxHealth), 0.6, "the MaxHealth perk is active in the match (a: " .. fmt(hum(a).MaxHealth, 1) .. ")")
	T.near(hum(a).Health, hum(a).MaxHealth, 1.0, "...and the player starts the match with full (boosted) health")
	T.near(hum(c).MaxHealth, Config.Physics.MaxHealth, 0.01, "a player without pets keeps the base MaxHealth")
	K.waitNotInvulnerable(a)
	K.waitNotInvulnerable(b)
	K.waitNotInvulnerable(c)

	-- tokens: n x value-1 pickups pay floor(n * multiplier) over time (fractional carry), nothing is lost
	local tokens = {}
	for _, tk in ipairs(K.tagged(Config.Tags.CloudToken, m.Course.Folder)) do
		if (tk:GetAttribute("Value") or 1) == 1 then
			tokens[#tokens + 1] = tk
		end
	end
	table.sort(tokens, function(x, y)
		return x.Position.Z < y.Position.Z
	end)
	-- pick tokens with nothing else (golden tokens have a bigger pickup radius) within 8 studs, so one teleport
	-- collects exactly one token
	local everything = K.tagged(Config.Tags.CloudToken, m.Course.Folder)
	local function isolated(tk, minGap)
		for _, o in ipairs(everything) do
			if o ~= tk and o.Parent ~= nil and (o.Position - tk.Position).Magnitude < minGap then
				return false
			end
		end
		return true
	end
	local picked = {}
	for _, tk in ipairs(tokens) do
		if isolated(tk, 8) and #picked < 8 then
			picked[#picked + 1] = tk
		end
	end
	T.check(#picked >= 6, "pets: found well separated value-1 tokens", #picked .. " found")
	local multA = PS.GetTokenMultiplier(a)
	local baseA = a:GetAttribute("CloudTokens")
	local earnedA = profileOf(a).Stats.TokensEarned
	for _, tk in ipairs(picked) do
		Mock.Teleport(a, tk.Position)
		advance(0.75)
	end
	local collected = #picked
	local expectA = floor(collected * multA + 1e-9)
	local gotA = a:GetAttribute("MatchTokens")
	T.check(abs(gotA - expectA) <= 1, "a (x" .. fmt(multA, 2) .. "): " .. collected .. " single tokens pay about floor(" .. collected .. " x " .. fmt(multA, 2) .. ") = " .. expectA .. " (fractions carry over)", "MatchTokens = " .. tostring(gotA))
	T.check(gotA > collected, "...which is more than without the pets", tostring(gotA))
	T.eq(a:GetAttribute("CloudTokens"), baseA + gotA, "...and the lifetime tokens grow by the same payout")
	T.check(profileOf(a).Stats.TokensEarned >= earnedA + gotA, "Stats.TokensEarned counts the boosted payout", tostring(profileOf(a).Stats.TokensEarned) .. " vs " .. earnedA .. " + " .. gotA)
	local st = K.state(a)
	T.check(st and st.TokensCollected == collected, "MatchState.TokensCollected counts the team's BASE value (never above TotalTokens)", st and (tostring(st.TokensCollected) .. " vs " .. collected))
	T.eq(c:GetAttribute("MatchTokens"), 0, "a teammate who collected nothing has MatchTokens = 0")
	-- a player without pets: every token pays exactly its value
	local mine = {}
	for _, tk in ipairs(tokens) do
		if tk.Parent ~= nil and isolated(tk, 8) and #mine < 4 then
			mine[#mine + 1] = tk
		end
	end
	for _, tk in ipairs(mine) do
		Mock.Teleport(c, tk.Position)
		advance(0.75)
	end
	T.check(#mine >= 2, "pets: found separated tokens for the pet-less teammate", #mine .. " found")
	T.eq(c:GetAttribute("MatchTokens"), #mine, "without pets every token pays exactly its value (" .. #mine .. " tokens)")

	-- checkpoint heal: base + CheckpointHeal perk
	local cp1 = m.Course.Checkpoints[1]
	DS().SetHealthFraction(c, 0.3)
	DS().SetHealthFraction(b, 0.3)
	local hpC, hpB = hum(c).Health, hum(b).Health
	local maxB = hum(b).MaxHealth
	Mock.Teleport(a, cp1.Part.Position + Vector3.new(0, 3.5, 0))
	advance(0.8)
	T.eq(m.Checkpoint, 1, "pets: checkpoint 1 reached")
	local healC = hum(c).Health - hpC
	local healB = hum(b).Health - hpB
	T.near(healC, Config.Damage.CheckpointHealFraction * hum(c).MaxHealth, 2, "a player without pets heals CheckpointHealFraction at a checkpoint")
	if healPet then
		local want = min(1, Config.Damage.CheckpointHealFraction * (1 + perksB.CheckpointHeal)) * maxB
		T.near(healB, want, 2.5, "a player with CheckpointHeal pets heals more: CheckpointHealFraction x (1 + " .. fmt(perksB.CheckpointHeal, 2) .. ") of max health", "healed " .. fmt(healB, 1) .. ", expected " .. fmt(want, 1))
		T.check(healB > healC + 1, "...clearly more than without pets (" .. fmt(healB, 1) .. " vs " .. fmt(healC, 1) .. ")")
	end

	-- a leaver records nothing, the others record the match
	local statsC = profileOf(c).Stats.Matches
	MS().LeaveMatch(c)
	advance(0.8)
	T.eq(profileOf(c).Stats.Matches, statsC, "a player who leaves mid-match records no match")
	-- win with a and b
	for i = 2, Config.GetDifficulty("Easy").Stages do
		local cp = m.Course.Checkpoints[i]
		Mock.Teleport(a, cp.Part.Position + Vector3.new(0, 3.5, 0))
		Mock.Teleport(b, cp.Part.Position + Vector3.new(0, 3.5, 0))
		advance(0.55)
	end
	local fin = m.Course.Finish
	local lifetime = a:GetAttribute("CloudTokens")
	local statsA, statsB = profileOf(a).Stats.Matches, profileOf(b).Stats.Matches
	local mark = logSize()
	Mock.Teleport(a, fin.Position + Vector3.new(0, fin.Size.Y / 2 + 3.5, 0))
	Mock.Teleport(b, fin.Position + Vector3.new(0, fin.Size.Y / 2 + 3.5, 0))
	advance(1.2)
	local res = K.lastRemote("MatchResult", a.UserId, mark)
	T.check(res ~= nil and res.args[1].Won == true, "pets: the team wins")
	if res then
		T.eq(res.args[1].Bonus, Config.Match.TokenBonusOnWin.Easy, "the win bonus is not multiplied by pet perks (" .. Config.Match.TokenBonusOnWin.Easy .. ")")
		T.eq(a:GetAttribute("CloudTokens"), lifetime + Config.Match.TokenBonusOnWin.Easy, "...it is added as is")
		T.eq(res.args[1].MatchTokens, a:GetAttribute("MatchTokens"), "MatchResult.MatchTokens is the boosted payout")
	end
	T.check(profileOf(a).Stats.Matches == statsA + 1 and profileOf(b).Stats.Matches == statsB + 1, "RecordMatch runs for both finishers")
	advance(Config.Match.EndScreenSeconds + 1.5)
	T.near(hum(a).MaxHealth, Config.Physics.MaxHealth * (1 + perksA.MaxHealth), 0.6, "the MaxHealth perk survives the return to the lobby")
	endAllMatches(players)
	removePlayers(players)
	flushErrors("match_pets")
	flushWarnings("match_pets")
end)

return S
