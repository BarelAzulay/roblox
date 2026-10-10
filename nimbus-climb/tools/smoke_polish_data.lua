-- smoke_polish_data.lua: release-quality fixes of the save system (server/Services/DataService.lua with
-- IndexService.lua and DevService.lua). Server world only (listed in server_files of tools/smoke.py), it runs after
-- data_orphans and before shutdown (the autosave and the orphan retries must still be running):
--   polish_data_outage     a returning player whose LOAD failed (DataStore outage) holds stand-in defaults: the profile
--                          is provisional (DataService.IsProvisional), GetTutorial answers nil, SetTutorial refuses,
--                          TutorialService starts nothing (no 'welcome', no gift, no finish reward), Index claims and
--                          the developer reset / tutorial / allpets wait ("still loading"; tokens still work); after
--                          the recovery the veteran's real progress is back (finished tutorial, 1000 tokens, claimed
--                          group still claimed) and a brand-new player whose load failed gets 'welcome' right away;
--                          the stored profile never gains a replayed gift or a lower Tutorial.Step. Studio without API
--                          access (no usable store) is never provisional: the tutorial runs from memory.
--   polish_data_dev_reset  the owner's /reset and /tutorial in the live game (DataStores on) survive the next autosave:
--                          Discovered, IndexClaimed, best times and the tutorial are written over the stored ones
--                          (DataService.ResetFields), the replayed tutorial keeps running (not ended halfway by a
--                          rebase), /tutorial keeps the paid gift paid; a reset whose save fails (outage) is kept
--                          pending through the orphan retries; a normal save still never shrinks those fields
--   polish_data_fwdcompat  a save keeps every stored field this version does not know (a Phase 2 profile: Version 3,
--                          Home.Stations / CollectorCash / LastSeen, Food, Hybrids, Tiers, Teams, Stats.Trophies) and
--                          the newer Version, while known fields still follow the Phase 1 rules
-- Plain Lua 5.1 syntax only.

local K = _G.K
local T = K.T
local guarded = K.guarded
local advance, mod, config = K.advance, K.mod, K.config

local S = {}

local function count(map)
	local n = 0
	for _, v in pairs(map or {}) do
		if v then
			n = n + 1
		end
	end
	return n
end

local function storeKey(userId)
	return config().Tokens.DataStoreName .. "/u_" .. userId
end

local function stored(userId)
	return Mock.DataStore.Data[storeKey(userId)]
end

local function tutorialText(t)
	if type(t) ~= "table" then
		return tostring(t)
	end
	return "{ Step " .. tostring(t.Step) .. ", Done " .. tostring(t.Done) .. ", Gifted " .. tostring(t.Gifted) .. " }"
end

local function stepCount()
	local Steps = K.M["shared/TutorialSteps"]
	return (Steps and type(Steps.Steps) == "table") and #Steps.Steps or 9
end

local function indexGroup(groupId)
	local PC = K.M["shared/PetCatalog"]
	if not PC or type(PC.IndexGroups) ~= "function" then
		return nil
	end
	for _, group in ipairs(PC.IndexGroups()) do
		if group.Id == groupId then
			return group
		end
	end
	return nil
end

local function statsOf(extra)
	local s = { Matches = 4, Wins = 2, TokensEarned = 1000, Spins = 3, BestTimes = {} }
	for key, value in pairs(extra or {}) do
		s[key] = value
	end
	return s
end

----------------------------------------------------------------------------------------------------
-- scenario: a failed load is provisional (no tutorial replay, no second gift / finish reward / Index reward)
----------------------------------------------------------------------------------------------------
S.polish_data_outage = guarded("polish_data_outage", function()
	if not K.needBoot() then
		return
	end
	local DataS, TS, IS = mod("DataService"), mod("TutorialService"), mod("IndexService")
	local DSt = Mock.DataStore
	-- the behaviour checks below run even without the API, so they also catch the bug itself
	T.check(type(DataS.IsProvisional) == "function", "outage: DataService.IsProvisional(player) exists")
	local function provisional(p)
		return type(DataS.IsProvisional) == "function" and DataS.IsProvisional(p) == true
	end
	local common = indexGroup("Common")
	if not T.check(common ~= nil and #common.Pets > 0, "outage: (precondition) the Pet Index has a Common group") then
		return
	end
	local VET, NEW = 941001, 941002
	local doneStep = stepCount() + 1
	local discovered = {}
	for _, def in ipairs(common.Pets) do
		discovered[def.Id] = true
	end
	DSt.Data[storeKey(VET)] = {
		Version = 2, Tokens = 1000, Pets = {}, Equipped = {}, Items = {}, Stats = statsOf(),
		Discovered = discovered, IndexClaimed = { Common = true }, Tutorial = { Step = doneStep, Done = true, Gifted = true },
	}
	DSt.Data[storeKey(NEW)] = nil

	-- both join while every DataStore call fails
	DSt.Fail = true
	local mark = K.logSize()
	local vet = Mock.AddPlayer("OutageVeteran", VET)
	local new = Mock.AddPlayer("OutageNewbie", NEW)
	advance(4)
	T.check(DataS.GetProfile(vet) ~= nil and provisional(vet) and provisional(new),
		"outage: a profile whose load failed while the store is reachable is provisional (DataService.IsProvisional)")
	T.eq(DataS.GetTutorial(vet), nil, "outage: GetTutorial answers nil for a provisional profile (its defaults would restart a veteran's tutorial)")
	T.eq(DataS.SetTutorial(vet, { Step = 4, Done = false, Gifted = true }), false, "outage: SetTutorial refuses while provisional")
	T.eq(TS.GetState(vet), nil, "outage: TutorialService starts no tutorial for the veteran (no 'welcome' from stand-in defaults)")
	T.eq(TS.GetState(new), nil, "outage: ...nor for a player whose load failed (unknown until the save is read)")
	T.eq(#K.remotesFor("TutorialState", VET, mark), 0, "outage: ...so no TutorialState is sent")
	-- play the new-player guide as far as the gift like the veteran would: Next, walk to the plot, open the Shop
	local okNext = TS.HandleEvent(vet, "Next")
	T.eq(okNext, false, "outage: a client tutorial event does nothing")
	local SS = mod("SpotService")
	local spot = SS and type(SS.GetSpot) == "function" and SS.GetSpot(vet)
	if spot and typeof(spot.Center) == "Vector3" then
		Mock.Teleport(vet, CFrame.new(spot.Center + Vector3.new(0, 3, 0)))
	end
	advance(1.5) -- the 2 Hz poll keeps trying
	T.eq(TS.GetState(vet), nil, "outage: ...and the 2 Hz poll does not start it either")
	advance(0.3)
	TS.HandleEvent(vet, "ShopOpened")
	T.eq(DataS.GetTokens(vet), 0, "outage: no tutorial gift was paid (the 'spin' step was never entered)")

	-- the Index: the Common group completed in-session (rolls during the outage) cannot be claimed from defaults
	local prof = DataS.GetProfile(vet)
	for _, def in ipairs(common.Pets) do
		prof.Pets[def.Id] = 1
		DataS.MarkDiscovered(vet, def.Id)
	end
	local okCan, why = IS.CanClaim(vet, "Common")
	T.check(okCan == false and tostring(why):lower():find("loading", 1, true) ~= nil,
		"outage: IndexService.CanClaim refuses a provisional profile ('Your data is still loading')", tostring(okCan) .. " " .. tostring(why))
	local okClaim = IS.Claim(vet, "Common")
	T.check(okClaim == false and DataS.GetTokens(vet) == 0, "outage: ...and Claim pays nothing", "tokens " .. tostring(DataS.GetTokens(vet)))

	-- the developer tools: only additive commands run on a provisional profile
	local Config = config()
	local Dev = require(K.moduleInstance("server/Services/DevService"))
	local saved = { Studio = Mock.Options.Studio, Admins = Config.Dev.Admins, Enabled = Config.Dev.Enabled }
	local okDev, errDev = pcall(function()
		Mock.Options.Studio = false
		Config.Dev.Enabled = true
		Config.Dev.Admins = { VET }
		local petsBefore = count(prof.Pets)
		advance(0.6)
		local okReset, msgReset = Dev.Run(vet, "reset", nil, "smoke")
		T.check(okReset == false and count(prof.Pets) == petsBefore, "outage: the developer /reset is refused while provisional (nothing is wiped)", tostring(msgReset))
		advance(0.6)
		T.eq((Dev.Run(vet, "tutorial", nil, "smoke")), false, "outage: ...so is /tutorial")
		advance(0.6)
		T.eq((Dev.Run(vet, "allpets", nil, "smoke")), false, "outage: ...and /allpets (it would add copies of pets the real save already has)")
		advance(0.6)
		local okTokens = Dev.Run(vet, "tokens", 5, "smoke")
		T.check(okTokens == true and DataS.GetTokens(vet) == 5, "outage: ...while /tokens (additive) still works", "tokens " .. tostring(DataS.GetTokens(vet)))
	end)
	Mock.Options.Studio = saved.Studio
	Config.Dev.Admins = saved.Admins
	Config.Dev.Enabled = saved.Enabled
	if not okDev then
		error(errDev, 0)
	end

	-- the store comes back: the background recovery reads the real saves (first retry after 20 s)
	DSt.Fail = false
	local recovered = K.waitFor(function()
		return not provisional(vet) and not provisional(new) and DataS.GetTutorial(vet) ~= nil and DataS.GetTutorial(vet).Done == true
	end, 40)
	T.check(recovered, "outage: the recovery reads the real saves once the store is back (no longer provisional)")
	advance(1)
	local t = DataS.GetTutorial(vet)
	T.check(t and t.Step == doneStep and t.Done == true and t.Gifted == true, "outage: the veteran's stored tutorial progress is back (finished)", tutorialText(t))
	local st = TS.GetState(vet)
	T.check(st ~= nil and st.Done == true, "outage: TutorialService starts from the real progress: the veteran's tutorial stays finished", st and tostring(st.Id) or "no state")
	local stNew = TS.GetState(new)
	T.check(stNew ~= nil and stNew.Id == "welcome" and stNew.Done == false, "outage: a brand-new player whose load failed gets 'welcome' right after the recovery",
		stNew and tostring(stNew.Id) or "no state")
	T.eq(DataS.GetTokens(vet), 1005, "outage: the veteran has the stored 1000 tokens plus the in-session 5 (no gift, no finish reward)")
	local okAgain, whyAgain = IS.CanClaim(vet, "Common")
	T.check(okAgain == false and whyAgain == "Already claimed", "outage: the group claimed before the outage stays claimed", tostring(whyAgain))

	K.removePlayers({ vet, new })
	advance(2)
	local saveVet = stored(VET)
	T.check(type(saveVet) == "table" and saveVet.Tokens == 1005, "outage: the stored balance is 1000 + 5 (no replayed gift merged in)", saveVet and tostring(saveVet.Tokens) or "nothing stored")
	local sTut = saveVet and saveVet.Tutorial
	T.check(type(sTut) == "table" and sTut.Step == doneStep and sTut.Done == true and sTut.Gifted == true,
		"outage: the stored tutorial is untouched (Tutorial.Step did not go back)", tutorialText(sTut))
	T.check(saveVet and type(saveVet.IndexClaimed) == "table" and saveVet.IndexClaimed.Common == true, "outage: the stored Index claim is kept")

	-- Studio without API access: no usable store, so nothing is provisional and the tutorial runs from memory. A
	-- second copy of DataService (fresh state) sees the DataStore API refused like Studio does.
	local inst = K.moduleInstance("server/Services/DataService")
	local clone = inst:Clone()
	clone.Name = "DataServiceStudioNoApi"
	clone.Parent = inst.Parent
	local p = Mock.AddPlayer("StudioNoApi", 941003)
	advance(1.5)
	DSt.Unavailable = true
	local okStudio, errStudio = pcall(function()
		local D2 = require(clone)
		D2.Load(p)
		T.check(type(D2.IsProvisional) == "function" and D2.IsProvisional(p) == false, "Studio without API access: a profile that could not be read is not provisional (there is no store to wait for)")
		local t2 = D2.GetTutorial(p)
		T.check(type(t2) == "table" and t2.Step == 1 and t2.Done == false, "Studio without API access: ...GetTutorial answers, so the tutorial runs from memory", tutorialText(t2))
		T.eq(D2.SetTutorial(p, { Step = 2, Done = false, Gifted = false }), true, "Studio without API access: ...and SetTutorial stores the progress in memory")
	end)
	DSt.Unavailable = false
	K.removePlayers({ p })
	clone:Destroy()
	if not okStudio then
		error(errStudio, 0)
	end
	K.flushErrors("polish_data_outage")
	K.flushWarnings("polish_data_outage", { "[DataService]" })
end)

----------------------------------------------------------------------------------------------------
-- scenario: the developer /reset and /tutorial last with DataStores on
----------------------------------------------------------------------------------------------------
S.polish_data_dev_reset = guarded("polish_data_dev_reset", function()
	if not K.needBoot() then
		return
	end
	local Config = config()
	local DataS, TS = mod("DataService"), mod("TutorialService")
	local PC = K.M["shared/PetCatalog"]
	local DSt = Mock.DataStore
	T.check(type(DataS.ResetFields) == "function", "dev reset: DataService.ResetFields(player, fields) exists") -- the behaviour checks run anyway
	if not T.check(TS and type(TS.Reload) == "function" and type(TS.GetState) == "function", "dev reset: (precondition) TutorialService has the Reload hook") then
		return
	end
	local Dev = require(K.moduleInstance("server/Services/DevService"))
	local OWNER = 941101
	local doneStep = stepCount() + 1
	local autosave = (Config.Tokens.AutosaveSeconds or 90) + 5
	local pets, discovered = {}, {}
	for _, def in ipairs(PC.Pets) do
		pets[def.Id] = 1
		discovered[def.Id] = true
	end
	DSt.Data[storeKey(OWNER)] = {
		Version = 2, Tokens = 500, Pets = pets, Equipped = {}, Items = {}, Stats = statsOf({ BestTimes = { Easy = 55 } }),
		Discovered = discovered, IndexClaimed = { Common = true, Uncommon = true }, Tutorial = { Step = doneStep, Done = true, Gifted = true },
	}
	local saved = { Studio = Mock.Options.Studio, CreatorId = game.CreatorId, CreatorType = game.CreatorType, Enabled = Config.Dev.Enabled }
	local joined = {}
	local ok, err = pcall(function()
		-- the published game, owned by OWNER, DataStores on
		Mock.Options.Studio = false
		game.CreatorType = Enum.CreatorType.User
		game.CreatorId = OWNER
		Config.Dev.Enabled = true
		local owner = Mock.AddPlayer("DataResetOwner", OWNER)
		joined[#joined + 1] = owner
		advance(1.5)
		local function run(command, arg)
			advance(0.6)
			return Dev.Run(owner, command, arg, "smoke")
		end
		local function stepId()
			local st = TS.GetState(owner)
			return st and st.Id, st and st.Done
		end
		local prof = DataS.GetProfile(owner)
		T.check(prof ~= nil and count(prof.Discovered) == #PC.Pets and DataS.GetTutorial(owner).Done == true,
			"dev reset: (precondition) the owner's save has every pet discovered and a finished tutorial")

		-- /reset, Next, one autosave
		T.eq((run("reset")), true, "dev reset: /reset runs for the owner in the live game")
		local id, done = stepId()
		T.check(id == "welcome" and done == false, "dev reset: (precondition) the tutorial restarts on 'welcome'", tostring(id))
		T.eq((TS.HandleEvent(owner, "Next")), true, "dev reset: (precondition) Next moves the replay on")
		local mark = K.logSize()
		advance(autosave)
		local live = DataS.GetTutorial(owner)
		local s = stored(OWNER) or {}
		local left = {}
		local function expect(cond, what)
			if not cond then
				left[#left + 1] = what
			end
		end
		expect(count(s.Discovered) == 0, "Discovered " .. count(s.Discovered))
		expect(count(s.Pets) == 0, "Pets " .. count(s.Pets))
		expect(count(s.IndexClaimed) == 0, "IndexClaimed " .. count(s.IndexClaimed))
		expect(type(s.Stats) == "table" and count(s.Stats.BestTimes) == 0, "BestTimes")
		expect(s.Tokens == 0, "Tokens " .. tostring(s.Tokens))
		expect(type(s.Tutorial) == "table" and s.Tutorial.Step == live.Step and s.Tutorial.Step >= 2 and s.Tutorial.Done == false and s.Tutorial.Gifted == false,
			"Tutorial " .. tutorialText(s.Tutorial) .. " (live " .. tutorialText(live) .. ")")
		T.check(#left == 0, "dev reset: after the next autosave the STORED profile is a brand-new player's (Discovered, Index rewards, best times, tutorial at the replay's step)",
			table.concat(left, ", "))
		left = {}
		expect(count(prof.Discovered) == 0, "Discovered " .. count(prof.Discovered))
		expect(count(prof.IndexClaimed) == 0, "IndexClaimed " .. count(prof.IndexClaimed))
		expect(count(prof.Stats.BestTimes) == 0, "BestTimes")
		expect(live.Step >= 2 and live.Done == false and live.Gifted == false, "Tutorial " .. tutorialText(live))
		T.check(#left == 0, "dev reset: ...and the save did not merge the old values back into the live profile", table.concat(left, ", "))
		id, done = stepId()
		T.check(id ~= nil and id ~= "welcome" and done == false, "dev reset: ...the replayed tutorial keeps running (past 'welcome', not ended halfway)", tostring(id) .. " done " .. tostring(done))
		local endedLate = false
		for _, e in ipairs(K.remotesFor("TutorialState", OWNER, mark)) do
			if type(e.args[1]) == "table" and e.args[1].Done == true then
				endedLate = true
			end
		end
		T.check(not endedLate, "dev reset: ...no TutorialState with Done = true reached the client after the save")
		local syncs = K.remotesFor("ProfileSync", OWNER, mark)
		local snap = syncs[#syncs] and syncs[#syncs].args[1]
		T.check(snap == nil or (count(snap.Discovered) == 0 and count(snap.Pets) == 0), "dev reset: ...and no ProfileSync brought 'Unlocked 30/30' back")

		-- /tutorial after a finished tutorial whose gift was paid: a replay that keeps the gift paid
		T.eq((run("skiptutorial")), true, "dev tutorial: (precondition) the tutorial is skipped")
		DataS.SetTutorial(owner, { Step = 2, Done = true, Gifted = true }) -- as if the gift had been paid
		T.eq(DataS.Save(owner), true, "dev tutorial: (precondition) the finished tutorial is saved")
		T.check(stored(OWNER).Tutorial.Done == true and stored(OWNER).Tutorial.Gifted == true, "dev tutorial: (precondition) the store holds Done = true, Gifted = true")
		T.eq((run("tutorial")), true, "dev tutorial: /tutorial runs")
		mark = K.logSize()
		advance(autosave)
		local st = stored(OWNER).Tutorial
		T.check(type(st) == "table" and st.Step == 1 and st.Done == false and st.Gifted == true,
			"dev tutorial: after the next autosave the store holds the replay (Step 1, Done = false) with the gift still paid", tutorialText(st))
		id, done = stepId()
		T.check(id == "welcome" and done == false, "dev tutorial: ...and the replay is still running ('welcome', Done = false)", tostring(id) .. " done " .. tostring(done))
		live = DataS.GetTutorial(owner)
		T.check(live.Done == false and live.Gifted == true, "dev tutorial: ...the live progress agrees", tutorialText(live))

		-- a reset whose save fails (outage) stays pending: it leaves as an orphan and the retry writes it
		T.eq((run("allpets")), true, "dev reset: (precondition) /allpets")
		T.eq(DataS.Save(owner), true, "dev reset: (precondition) every pet is saved")
		T.eq(count(stored(OWNER).Discovered), #PC.Pets, "dev reset: (precondition) the store has every pet discovered")
		DSt.Fail = true
		T.eq((run("reset")), true, "dev reset: /reset during a DataStore outage (the profile loaded fine)")
		T.eq(DataS.Save(owner), false, "dev reset: (precondition) the save fails during the outage")
		Mock.RemovePlayer(owner)
		advance(6)
		T.eq(count(stored(OWNER).Discovered), #PC.Pets, "dev reset: (precondition) nothing was written during the outage")
		DSt.Fail = false
		advance(40)
		s = stored(OWNER)
		T.check(count(s.Discovered) == 0 and count(s.Pets) == 0 and s.Tutorial.Done == false and s.Tutorial.Gifted == false,
			"dev reset: the reset stays pending through the failed save and the orphan retry writes it once the store is back",
			"Discovered " .. count(s.Discovered) .. ", Pets " .. count(s.Pets) .. ", Tutorial " .. tutorialText(s.Tutorial))

		-- without ResetFields the grow-only rule still holds (a normal save never shrinks those fields)
		local back = Mock.AddPlayer("DataResetOwner", OWNER)
		joined[#joined + 1] = back
		advance(1.5)
		T.eq((Dev.Run(back, "allpets", nil, "smoke")), true, "grow-only: (precondition) /allpets")
		T.eq(DataS.Save(back), true, "grow-only: (precondition) saved")
		local liveBack = DataS.GetProfile(back)
		for _, field in ipairs({ "Discovered", "Pets", "Equipped" }) do
			for key in pairs(liveBack[field]) do
				liveBack[field][key] = nil
			end
		end
		DataS.MarkDirty(back)
		DataS.Save(back)
		local sb = stored(OWNER)
		T.check(count(sb.Pets) == 0 and count(sb.Discovered) == #PC.Pets,
			"grow-only: without ResetFields a save never removes discovered pets (the union rule stays; the pets themselves go)",
			"Pets " .. count(sb.Pets) .. ", Discovered " .. count(sb.Discovered))
	end)
	Mock.Options.Studio = saved.Studio
	game.CreatorId = saved.CreatorId
	game.CreatorType = saved.CreatorType
	Config.Dev.Enabled = saved.Enabled
	DSt.Fail = false
	K.removePlayers(joined)
	advance(2)
	if not ok then
		error(err, 0)
	end
	K.flushErrors("polish_data_dev_reset")
	K.flushWarnings("polish_data_dev_reset", { "[DataService]" })
end)

----------------------------------------------------------------------------------------------------
-- scenario: saves keep the fields of later phases (forward compatibility)
----------------------------------------------------------------------------------------------------
S.polish_data_fwdcompat = guarded("polish_data_fwdcompat", function()
	if not K.needBoot() then
		return
	end
	local DataS = mod("DataService")
	local DSt = Mock.DataStore
	local ID = 941201
	local doneStep = stepCount() + 1
	DSt.Data[storeKey(ID)] = {
		Version = 3, Tokens = 50, Pets = {}, Equipped = { "ghost_pet" }, Items = {},
		Stats = statsOf({ Trophies = 12 }),
		Discovered = {}, IndexClaimed = {}, Tutorial = { Step = doneStep, Done = true, Gifted = true },
		Cash = 1234, Gems = 80,
		Home = {
			Level = 7, Prestige = 1, Rooms = {},
			Stations = { Press1 = 4, Kitchen = 2 }, Garden = { "pebble_pup" }, CollectorCash = 900, LastSeen = 1700000000,
		},
		PetLevels = {},
		Food = { Snack = 3 },
		Hybrids = { h1 = { Body = "penguin", Style = "phoenix", Elements = { "Frost", "Flame" }, Name = "Pengnix", Rarity = "Rare", Tier = "Golden" } },
		Tiers = { pebble_pup = { Golden = 1 } },
		Teams = { { "a", "b", "c" } },
	}
	local p = Mock.AddPlayer("PhaseTwoSave", ID)
	advance(1.5)
	DataS.AddTokens(p, 1)
	K.removePlayers({ p })
	advance(2)
	local s = stored(ID) or {}
	T.eq(s.Tokens, 51, "forward compat: (precondition) the Phase 1 server saved its change (50 + 1 tokens)")
	local home = type(s.Home) == "table" and s.Home or {}
	T.check(home.Level == 7 and home.Prestige == 1 and s.Cash == 1234 and s.Gems == 80, "forward compat: Cash, Gems, Home.Level and Prestige are kept")
	T.check(type(home.Stations) == "table" and home.Stations.Press1 == 4 and home.Stations.Kitchen == 2 and home.CollectorCash == 900 and home.LastSeen == 1700000000
		and type(home.Garden) == "table" and home.Garden[1] == "pebble_pup",
		"forward compat: unknown Home fields (Stations, Garden, CollectorCash, LastSeen) survive a Phase 1 save")
	T.check(type(s.Food) == "table" and s.Food.Snack == 3, "forward compat: an unknown top-level field (Food) survives")
	T.check(type(s.Hybrids) == "table" and type(s.Hybrids.h1) == "table" and s.Hybrids.h1.Name == "Pengnix" and type(s.Hybrids.h1.Elements) == "table" and s.Hybrids.h1.Elements[2] == "Flame",
		"forward compat: ...Hybrids (fused pets) survive whole")
	T.check(type(s.Tiers) == "table" and type(s.Tiers.pebble_pup) == "table" and s.Tiers.pebble_pup.Golden == 1, "forward compat: ...Tiers survive")
	T.check(type(s.Teams) == "table" and type(s.Teams[1]) == "table" and s.Teams[1][3] == "c", "forward compat: ...Teams survive")
	T.check(type(s.Stats) == "table" and s.Stats.Trophies == 12, "forward compat: an unknown Stats field (Trophies) survives")
	T.eq(s.Version, 3, "forward compat: a newer Version number is kept (never lowered to 2)")
	local ghost = false
	for _, id in ipairs(type(s.Equipped) == "table" and s.Equipped or {}) do
		if id == "ghost_pet" then
			ghost = true
		end
	end
	T.check(not ghost, "forward compat: known fields still follow the Phase 1 rules (an equipped pet that is not owned is dropped, never copied back)")
	-- a plain Phase 1 profile keeps Version 2 (nothing is bumped)
	local q = Mock.AddPlayer("PhaseOneSave", 941202)
	advance(1.5)
	DataS.AddTokens(q, 2)
	K.removePlayers({ q })
	advance(2)
	local s2 = stored(941202)
	T.check(type(s2) == "table" and s2.Version == 2 and s2.Tokens == 2 and s2.Food == nil, "forward compat: a Phase 1 profile stays Version 2 with nothing added")
	K.flushErrors("polish_data_fwdcompat")
	K.flushWarnings("polish_data_fwdcompat", { "[DataService]" })
end)

return S
