-- smoke_dev.lua: the owner-only developer tools (Config.Dev, server/Services/DevService.lua,
-- client/Controllers/DevController.lua). Loaded by tools/smoke.py in BOTH worlds; ARGS.context picks the half:
--   dev_tools          (server) who is a developer: a normal player in the live game is refused everything and
--                      nothing changes (also forged args and chat), no NC_Dev hint; Config.Dev.Admins; a
--                      group-owned game (rank 255, cached, a failing web call is not cached); the hints sit on the
--                      developer's PlayerGui, never on the Player (which every client can read); the owner
--                      (CreatorId) in the live game: allpets (every pet incl. Secret, all discovered, Index groups
--                      complete, ProfileSync), tokens (default, clamp, whole numbers only), the 4-per-2s rate limit,
--                      tutorial restart (refused and hidden while TutorialService has no Reload hook; with a stand-in
--                      hook: a replay that keeps the paid gift), skiptutorial (no finish reward), reset (refused in a
--                      match; back to a brand-new player; a tutorial that already paid its gift is skipped instead
--                      of waiting forever), chat commands, logging; Studio (everyone allowed, AllowInStudio /
--                      Enabled switches, StudioAutoGrant); a build with the tools switched off still listens on
--                      DevCommand (Roblox would queue the events otherwise) and refuses everything
--   client_dev         (client, 1920x1080 + other window sizes) the DEV button only exists with NC_Dev on the
--                      PlayerGui, sits on the right edge clear of the menu column / HUD / hotbar / tutorial panel,
--                      the toasts' room and the middle; the "Developer tools" side panel (never centred, readable,
--                      the newest toasts never cover it) and what each button sends; "Restart tutorial" only with
--                      NC_DevTutorial; the "Are you sure?" reset (a double click never resets, nor does a triple
--                      click on the DEV button); X / Esc / gamepad B; gamepad selection
--   client_dev_mobile  (phone world, 390x844 + 844x390 + 1024x768, touch) the button never covers the RUN / DASH /
--                      jump buttons; the panel stays out of the middle, readable and clear of the newest toasts
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local CONTEXT = (ARGS and ARGS.context) or "server"

local ATTR = "NC_Dev" -- PlayerGui attributes DevService sets for developers
local ATTR_TUTORIAL = "NC_DevTutorial"
local TAG = "[NimbusClimb][Dev]"

-- a DevService hint for `p` (it lives on the PlayerGui, which only that player's client receives)
local function hint(p, name)
	local pg = p:FindFirstChildOfClass("PlayerGui")
	return pg and pg:GetAttribute(name or ATTR)
end

local function count(map)
	local n = 0
	for _, v in pairs(map or {}) do
		if v then
			n = n + 1
		end
	end
	return n
end

----------------------------------------------------------------------------------------------------
-- server world
----------------------------------------------------------------------------------------------------
local function serverScenarios()
	local K = _G.K
	local S = {}
	local advance, mod, config = K.advance, K.mod, K.config

	local OWNER_ID = 31337
	local GROUP_ID = 4040

	-- "DEV: ..." toasts sent to `p` after RemoteLog index `mark`: { text, kind }
	local function devToasts(p, mark)
		local out = {}
		for _, e in ipairs(K.remotesFor("Notify", p.UserId, mark or 0)) do
			local text = tostring(e.args[1])
			if text:sub(1, 4) == "DEV:" then
				out[#out + 1] = { text = text, kind = e.args[2] }
			end
		end
		return out
	end
	local function lastToast(p, mark)
		local list = devToasts(p, mark)
		return list[#list] or { text = "(no DEV toast)", kind = nil }
	end

	-- every command is spaced out so the 4-per-2-seconds limit never hides a result (except in the rate test)
	local function send(p, command, arg)
		advance(0.55)
		local mark = K.logSize()
		Mock.FromClient(K.remoteFolder().DevCommand, p, command, arg)
		advance(0.15)
		return mark
	end
	local function chat(p, text)
		advance(0.55)
		local mark = K.logSize()
		Mock.FireSignal(p, "Chatted", text)
		advance(0.15)
		return mark
	end
	local function join(list, name, userId)
		local p = Mock.AddPlayer(name, userId)
		advance(1)
		list[#list + 1] = p
		return p
	end

	-- what a refused command must leave untouched
	local function snapshotOf(p)
		local prof = mod("DataService").GetProfile(p)
		local tut = type(prof.Tutorial) == "table" and prof.Tutorial or {}
		local stats = prof.Stats or {}
		return {
			Tokens = prof.Tokens, Pets = count(prof.Pets), Discovered = count(prof.Discovered), Equipped = #prof.Equipped,
			Items = count(prof.Items), Claimed = count(prof.IndexClaimed), Wins = stats.Wins, Spins = stats.Spins,
			Step = tut.Step, Done = tut.Done, Gifted = tut.Gifted, Attr = p:GetAttribute("CloudTokens"),
		}
	end
	local function same(a, b)
		for key, value in pairs(a) do
			if b[key] ~= value then
				return false, key .. ": " .. tostring(value) .. " -> " .. tostring(b[key])
			end
		end
		return true, ""
	end
	-- a print() line since Mock.Output index `from` that contains every needle
	local function printed(needles, from)
		for i = (from or 0) + 1, #Mock.Output do
			local o = Mock.Output[i]
			if o.kind == "print" then
				local all = true
				for _, needle in ipairs(needles) do
					if not o.text:find(needle, 1, true) then
						all = false
						break
					end
				end
				if all then
					return o.text
				end
			end
		end
		return nil
	end

	local function nonOwner(Dev, joined)
		local stranger = join(joined, "DevStranger", 92001)
		T.eq(hint(stranger), nil, "DEV live game: a normal player gets no NC_Dev hint")
		T.eq(Dev.IsAllowed(stranger), false, "DEV live game: DevService.IsAllowed is false for a normal player")
		local before = snapshotOf(stranger)
		local mark0 = K.logSize()
		local attempts = {
			{ "allpets" }, { "tokens", 50000 }, { "tokens" }, { "reset" }, { "tutorial" }, { "skiptutorial" }, { "devhelp" },
			{ "ALLPETS" }, { "tokens", "99999999" }, { "tokens", 1 / 0 }, { "tokens", 0 / 0 }, { { "allpets" } }, { 42 },
			{ nil }, { string.rep("x", 5000) }, { "allpets", { Force = true } },
		}
		for _, a in ipairs(attempts) do
			send(stranger, a[1], a[2])
		end
		for _, line in ipairs({ "/allpets", "/tokens 50000", "/reset", "/devhelp" }) do
			chat(stranger, line)
		end
		advance(2.1)
		local okRun, why = Dev.Run(stranger, "allpets", nil, "smoke")
		T.check(okRun == false, "DEV live game: DevService.Run refuses a normal player", tostring(why))
		local after = snapshotOf(stranger)
		local unchanged, diff = same(before, after)
		T.check(unchanged, "DEV live game: every command of a normal player is refused and changes nothing (" .. #attempts .. " remote calls incl. forged args, chat)", diff)
		T.eq(#devToasts(stranger, mark0), 0, "DEV live game: ...and they get no DEV toast")
		T.eq(hint(stranger), nil, "DEV live game: ...and NC_Dev stays unset")
		return stranger
	end

	local function admins(Dev, Config, joined)
		Config.Dev.Admins = { 92002 }
		local admin = join(joined, "DevAdmin", 92002)
		T.eq(hint(admin), true, "DEV live game: a UserId in Config.Dev.Admins gets NC_Dev (on their PlayerGui)")
		T.eq(admin:GetAttribute(ATTR), nil, "DEV live game: ...and nothing on the Player itself, which every client can read (nobody learns who the developers are)")
		Config.Dev.Admins = { "92002" }
		T.eq(Dev.IsAllowed(admin), true, "DEV live game: Admins may also list the UserId as text")
		Config.Dev.Admins = {}
		T.eq(Dev.IsAllowed(admin), false, "DEV live game: the permission is checked live (removed from Admins -> refused)")
	end

	local function groupGame(Dev, Config, joined, stranger)
		local playerClass = Mock.Classes and Mock.Classes.Player
		local methods = playerClass and playerClass.methods
		if type(methods) ~= "table" or type(methods.GetRankInGroup) ~= "function" then
			T.info("*the mock's Player:GetRankInGroup cannot be patched: group-owner checks skipped")
			return
		end
		local calls = 0
		methods.GetRankInGroup = function(self, groupId)
			calls = calls + 1
			if self.UserId == 92011 then
				error("HTTP 503 (mock outage)")
			end
			if self.UserId == 92010 and groupId == GROUP_ID then
				return 255
			end
			return 0
		end
		local probeOk, probe = pcall(function()
			return stranger:GetRankInGroup(GROUP_ID)
		end)
		if not (probeOk and probe == 0 and calls == 1) then
			T.info("*the mock's Player:GetRankInGroup cannot be patched: group-owner checks skipped")
			return
		end
		game.CreatorType = Enum.CreatorType.Group
		game.CreatorId = GROUP_ID
		local groupOwner = join(joined, "DevGroupOwner", 92010)
		T.eq(hint(groupOwner), true, "DEV group game: the group's owner (rank 255) gets NC_Dev")
		local c0 = calls
		T.eq(Dev.IsAllowed(groupOwner), true, "DEV group game: IsAllowed is true for the group's owner")
		T.eq(calls, c0, "DEV group game: ...and the rank is cached (no second GetRankInGroup)")
		T.eq(Dev.IsAllowed(stranger), false, "DEV group game: a member below rank 255 is refused")
		local flaky = join(joined, "DevFlaky", 92011)
		T.eq(hint(flaky), nil, "DEV group game: a failing GetRankInGroup counts as 'not allowed' (no script error)")
		methods.GetRankInGroup = function()
			calls = calls + 1
			return 255
		end
		T.eq(Dev.IsAllowed(flaky), true, "DEV group game: ...and the failure is not cached (asked again next time)")
		game.CreatorType = Enum.CreatorType.User
		game.CreatorId = OWNER_ID
	end

	local function ownerCommands(Dev, Config, joined)
		local DataS, PS, IS, TS = mod("DataService"), mod("PetService"), mod("IndexService"), mod("TutorialService")
		local PC = K.M["shared/PetCatalog"]
		local R = K.remoteFolder()
		local outputMark = #Mock.Output
		local owner = join(joined, "DevOwner", OWNER_ID)
		T.eq(hint(owner), true, "DEV live game: the game's owner (UserId == game.CreatorId) gets NC_Dev = true on their PlayerGui")
		T.eq(owner:GetAttribute(ATTR), nil, "DEV live game: ...and the Player itself carries no NC_Dev")
		T.eq(Dev.IsAllowed(owner), true, "DEV live game: IsAllowed is true for the owner")
		local prof = DataS.GetProfile(owner)
		local function tokens()
			return DataS.GetTokens(owner)
		end

		-- allpets
		local groups = (IS and type(PC.IndexGroups) == "function") and PC.IndexGroups() or {}
		local completed = {}
		local conn = (IS and IS.Completed) and IS.Completed:Connect(function(who, groupId)
			if who == owner then
				completed[#completed + 1] = groupId
			end
		end)
		local mark = send(owner, "allpets")
		advance(0.2)
		local missing, undiscovered, extra, secrets = {}, {}, {}, 0
		for _, def in ipairs(PC.Pets) do
			if (prof.Pets[def.Id] or 0) < 1 then
				missing[#missing + 1] = def.Id
			elseif prof.Pets[def.Id] ~= 1 then
				extra[#extra + 1] = def.Id .. " x" .. tostring(prof.Pets[def.Id])
			end
			if prof.Discovered[def.Id] ~= true then
				undiscovered[#undiscovered + 1] = def.Id
			end
			if def.Rarity == "Secret" then
				secrets = secrets + 1
			end
		end
		T.check(#missing == 0, "DEV allpets: the owner now owns every catalog pet (" .. #PC.Pets .. ", " .. secrets .. " of them Secret)", table.concat(missing, ", "))
		T.check(#extra == 0, "DEV allpets: ...one copy of each", table.concat(extra, ", "))
		T.check(#undiscovered == 0, "DEV allpets: ...every one marked discovered (the Pet Index fills)", table.concat(undiscovered, ", "))
		local syncs = K.remotesFor("ProfileSync", owner.UserId, mark)
		local snap = syncs[#syncs] and syncs[#syncs].args[1]
		T.check(type(snap) == "table" and count(snap.Pets) == #PC.Pets and count(snap.Discovered) == #PC.Pets,
			"DEV allpets: ...and a ProfileSync updates the menu at once", snap and (count(snap.Pets) .. " pets, " .. count(snap.Discovered) .. " discovered") or "no ProfileSync")
		if IS and type(IS.GetProgress) == "function" then
			local open = {}
			for groupId, info in pairs(IS.GetProgress(owner)) do
				if not info.Complete then
					open[#open + 1] = groupId .. " " .. tostring(info.Found) .. "/" .. tostring(info.Total)
				end
			end
			T.check(#open == 0, "DEV allpets: ...every Pet Index group is complete", table.concat(open, ", "))
			T.eq(#completed, #groups, "DEV allpets: ...IndexService.Refresh fires Completed for every group")
		end
		if conn then
			conn:Disconnect()
		end
		local toast = lastToast(owner, mark)
		T.check(toast.kind == "good", "DEV allpets: the owner gets a side toast 'DEV: ...' (good)", toast.text)
		mark = send(owner, "allpets")
		toast = lastToast(owner, mark)
		T.check(count(prof.Pets) == #PC.Pets and prof.Pets[PC.Pets[1].Id] == 1 and toast.kind == "info",
			"DEV allpets: running it again adds nothing ('you already own all ...', info)", toast.text)

		-- tokens
		local grant = Config.Dev.GrantTokens
		local cap = Config.Dev.MaxTokensPerCommand
		local t0 = tokens()
		mark = send(owner, "tokens", 50000)
		T.eq(tokens() - t0, 50000, "DEV tokens 50000: adds exactly 50,000 tokens")
		T.eq(owner:GetAttribute("CloudTokens"), tokens(), "DEV tokens: the HUD attribute follows")
		toast = lastToast(owner, mark)
		T.check(toast.kind == "good" and toast.text:find("50,000", 1, true) ~= nil, "DEV tokens: toast 'DEV: +50,000 Cloud Tokens' (good)", toast.text)
		t0 = tokens()
		send(owner, "tokens")
		T.eq(tokens() - t0, grant, "DEV tokens: no number -> Config.Dev.GrantTokens (" .. tostring(grant) .. ")")
		t0 = tokens()
		send(owner, "tokens", -5)
		T.eq(tokens() - t0, 1, "DEV tokens -5: clamped up to 1")
		t0 = tokens()
		send(owner, "tokens", 1e12)
		T.eq(tokens() - t0, cap, "DEV tokens 1e12: clamped to Config.Dev.MaxTokensPerCommand (" .. tostring(cap) .. ")")
		local refusedOk = true
		local details = {}
		for _, bad in ipairs({ 2.5, "5000", 1 / 0, -1 / 0, 0 / 0, { 5 }, true }) do
			t0 = tokens()
			mark = send(owner, "tokens", bad)
			toast = lastToast(owner, mark)
			if tokens() ~= t0 or toast.kind ~= "bad" then
				refusedOk = false
				details[#details + 1] = tostring(bad) .. " -> +" .. tostring(tokens() - t0) .. " / " .. tostring(toast.kind)
			end
		end
		T.check(refusedOk, "DEV tokens: non-whole / non-number amounts (2.5, '5000', inf, nan, table, bool) are refused with a 'bad' toast", table.concat(details, "; "))

		-- the rate limit: 4 commands per 2 seconds
		advance(2.5)
		t0 = tokens()
		mark = K.logSize()
		for _ = 1, 7 do
			Mock.FromClient(R.DevCommand, owner, "tokens", 1)
		end
		advance(0.1)
		T.eq(tokens() - t0, 4, "DEV rate limit: 7 commands at once -> only 4 run (4 per 2 seconds)")
		local slow = 0
		for _, t in ipairs(devToasts(owner, mark)) do
			if t.text:lower():find("slow down", 1, true) then
				slow = slow + 1
			end
		end
		T.eq(slow, 1, "DEV rate limit: ...with one 'slow down' toast, not one per dropped command")
		advance(2.1)
		t0 = tokens()
		Mock.FromClient(R.DevCommand, owner, "tokens", 1)
		advance(0.1)
		T.eq(tokens() - t0, 1, "DEV rate limit: ...and commands run again 2 seconds later")

		-- unknown / malformed commands
		mark = send(owner, "fly")
		toast = lastToast(owner, mark)
		T.check(toast.kind == "bad" and toast.text:lower():find("unknown", 1, true) ~= nil, "DEV: an unknown command gets a 'bad' toast", toast.text)
		mark = send(owner, { "allpets" })
		T.eq(lastToast(owner, mark).kind, "bad", "DEV: a command that is not a string gets a 'bad' toast")
		mark = send(owner, "reset", "now")
		T.eq(lastToast(owner, mark).kind, "bad", "DEV: a command that takes no value refuses one ('reset', 'now')")

		-- tutorial restart: needs the hook TutorialService.Reload(player, opts) to re-read the progress
		local reloader = TS and TS.Reload
		local function tutorialState()
			return TS and type(TS.GetState) == "function" and TS.GetState(owner) or nil
		end
		local st = tutorialState()
		if TS then
			T.check(st ~= nil and st.Done == false, "DEV tutorial: (precondition) the owner's tutorial is running", st and ("step " .. tostring(st.Step) .. " done " .. tostring(st.Done)) or "no state")
		end
		local before = snapshotOf(owner)
		mark = send(owner, "tutorial")
		toast = lastToast(owner, mark)
		if reloader then
			local stored = DataS.GetTutorial(owner)
			T.check(stored.Step == 1 and stored.Done == false and stored.Gifted == before.Gifted and toast.kind == "good",
				"DEV tutorial: the tutorial restarts from step 1 (a replay: the gift stays paid)", toast.text)
			local state = tutorialState()
			T.check(state and state.Step == 1 and state.Done == false, "DEV tutorial: ...and TutorialService follows (TutorialState step 1)")
			T.eq(hint(owner, ATTR_TUTORIAL), true, "DEV tutorial: NC_DevTutorial tells the panel to show 'Restart tutorial'")
		else
			local unchanged, diff = same(before, snapshotOf(owner))
			T.check(unchanged and toast.kind == "bad", "DEV tutorial: without the TutorialService.Reload hook the restart is refused and nothing changes", diff .. " " .. toast.text)
			T.eq(hint(owner, ATTR_TUTORIAL), nil, "DEV tutorial: ...and NC_DevTutorial stays unset, so the panel hides 'Restart tutorial'")
			T.info("*TutorialService has no Reload(player, opts) yet: 'Restart tutorial' stays hidden and refused until it does")
		end

		-- skip
		local tokensBefore = tokens()
		mark = send(owner, "skiptutorial")
		toast = lastToast(owner, mark)
		local stored = DataS.GetTutorial(owner)
		T.check(stored and stored.Done == true and toast.kind == "good", "DEV skiptutorial: the tutorial is stored as done", toast.text)
		if TS then
			local state = tutorialState()
			T.check(state and state.Done == true and state.Skipped == true, "DEV skiptutorial: ...TutorialService ends it as skipped")
		end
		T.eq(tokens(), tokensBefore, "DEV skiptutorial: ...without the finish reward")
		mark = send(owner, "skiptutorial")
		T.eq(lastToast(owner, mark).kind, "bad", "DEV skiptutorial: skipping a finished tutorial again is refused ('bad' toast)")
		if reloader then
			send(owner, "tutorial")
			local again = DataS.GetTutorial(owner)
			T.check(again.Step == 1 and again.Done == false, "DEV tutorial: a finished tutorial can be restarted too")
		end

		-- reset: give the owner things to lose first
		advance(0.6)
		local equipId = PC.Pets[1].Id
		local okEquip = PS.Equip(owner, equipId)
		T.check(okEquip == true and owner:GetAttribute("EquippedPets") ~= "", "DEV reset: (precondition) a pet is equipped")
		local IC = K.M["shared/ItemCatalog"]
		local itemId = IC and IC.List and IC.List[1] and IC.List[1].Id
		if itemId then
			prof.Items[itemId] = 2
		end
		prof.Stats.Wins = 3
		prof.Stats.BestTimes.Easy = 99
		prof.IndexClaimed.Common = true
		prof.Cash, prof.Gems = 120, 7
		prof.Home.Level = 2
		prof.PetLevels[equipId] = { Level = 3, Xp = 10 }
		-- refused in a match
		owner:SetAttribute(Config.Attr.InMatch, true)
		before = snapshotOf(owner)
		mark = send(owner, "reset")
		local unchanged, diff = same(before, snapshotOf(owner))
		T.check(unchanged and lastToast(owner, mark).kind == "bad", "DEV reset: refused during a match (nothing changes)", diff)
		owner:SetAttribute(Config.Attr.InMatch, false)
		advance(0.2)
		local spot = owner:GetAttribute(Config.Attr.SpotIndex)
		local tutorialBefore = DataS.GetTutorial(owner)
		mark = send(owner, "reset")
		advance(0.2)
		toast = lastToast(owner, mark)
		local left = {}
		local function expect(cond, what)
			if not cond then
				left[#left + 1] = what
			end
		end
		expect(prof.Tokens == 0 and tokens() == 0, "tokens " .. tostring(prof.Tokens))
		expect(owner:GetAttribute("CloudTokens") == 0, "CloudTokens attribute")
		expect(next(prof.Pets) == nil, "pets")
		expect(#prof.Equipped == 0, "equipped")
		expect(owner:GetAttribute("EquippedPets") == "", "EquippedPets attribute")
		expect(next(prof.Items) == nil, "items")
		expect(prof.Stats.Wins == 0 and prof.Stats.Matches == 0 and prof.Stats.Spins == 0 and prof.Stats.TokensEarned == 0, "stats")
		expect(next(prof.Stats.BestTimes) == nil, "best times")
		expect(next(prof.Discovered) == nil, "discovered")
		expect(next(prof.IndexClaimed) == nil, "index rewards")
		expect(prof.Cash == 0 and prof.Gems == 0, "cash / gems")
		expect(prof.Home.Level == 0 and next(prof.PetLevels) == nil, "home / pet levels")
		T.check(#left == 0 and toast.kind == "good", "DEV reset: back to a brand-new player (tokens, pets, equipped, items, stats, Index, cash, gems, home)", table.concat(left, ", ") .. " / " .. toast.text)
		T.eq(owner:GetAttribute(Config.Attr.SpotIndex), spot, "DEV reset: ...the lobby spot stays assigned")
		syncs = K.remotesFor("ProfileSync", owner.UserId, mark)
		snap = syncs[#syncs] and syncs[#syncs].args[1]
		T.check(type(snap) == "table" and snap.Tokens == 0 and count(snap.Pets) == 0 and count(snap.Discovered) == 0, "DEV reset: ...and the menu is synced at once")
		if IS and type(IS.GetProgress) == "function" then
			local found = 0
			for _, info in pairs(IS.GetProgress(owner)) do
				found = found + (info.Found or 0)
			end
			T.eq(found, 0, "DEV reset: ...the Pet Index is empty again")
		end
		local tutorialAfter = DataS.GetTutorial(owner)
		if reloader then
			T.check(tutorialAfter.Step == 1 and tutorialAfter.Done == false and tutorialAfter.Gifted == false, "DEV reset: ...and the tutorial restarts as a new player's")
		else
			T.check(tutorialAfter.Step == tutorialBefore.Step and tutorialAfter.Done == tutorialBefore.Done,
				"DEV reset: ...a finished tutorial stays finished while TutorialService cannot reload it", toast.text)
		end

		-- chat (case-insensitive)
		mark = chat(owner, "/ALLPETS")
		T.eq(count(prof.Pets), #PC.Pets, "DEV chat: '/ALLPETS' gives every pet again")
		t0 = tokens()
		chat(owner, "/tokens 50000")
		T.eq(tokens() - t0, 50000, "DEV chat: '/tokens 50000' adds 50,000")
		t0 = tokens()
		chat(owner, "  /Tokens 1.5m ")
		T.eq(tokens() - t0, 1500000, "DEV chat: '/Tokens 1.5m' adds 1,500,000")
		t0 = tokens()
		mark = chat(owner, "/tokens lots")
		T.check(tokens() == t0 and lastToast(owner, mark).kind == "bad", "DEV chat: '/tokens lots' is refused with a 'bad' toast")
		mark = chat(owner, "/devhelp")
		toast = lastToast(owner, mark)
		local help = toast.text:lower()
		T.check(help:find("/allpets", 1, true) and help:find("/tokens", 1, true) and help:find("/reset", 1, true) and help:find("/skiptutorial", 1, true)
			and (help:find("/tutorial", 1, true) ~= nil) == (reloader ~= nil),
			"DEV chat: '/devhelp' answers with a toast listing the commands that work in this build", toast.text)
		mark = chat(owner, "/e dance")
		chat(owner, "hello /allpets")
		T.eq(#devToasts(owner, mark), 0, "DEV chat: other messages and other '/' commands are left alone")

		-- the restart path itself, with a stand-in TutorialService.Reload(player, opts) hook (the real one is the
		-- tutorial owner's to write)
		if TS and not reloader then
			local savedTutorial = DataS.GetTutorial(owner)
			local calls = {}
			TS.Reload = function(player, opts)
				calls[#calls + 1] = { player = player, opts = opts }
			end
			prof.Tutorial.Gifted = true -- as if the "spin" gift had been paid
			mark = send(owner, "tutorial")
			local t = DataS.GetTutorial(owner)
			local call = calls[1]
			T.check(t.Step == 1 and t.Done == false and call and call.player == owner and lastToast(owner, mark).kind == "good",
				"DEV tutorial: with a TutorialService.Reload hook the stored progress goes back to step 1 and the hook is called", lastToast(owner, mark).text)
			T.check(t.Gifted == true and call and type(call.opts) == "table" and call.opts.Replay == true,
				"DEV tutorial: ...as a replay: the paid gift stays paid and Reload gets { Replay = true } (no finish reward again)", "Gifted " .. tostring(t.Gifted))
			mark = send(owner, "reset")
			t = DataS.GetTutorial(owner)
			call = calls[2]
			T.check(t.Step == 1 and t.Done == false and t.Gifted == false and call and call.player == owner and type(call.opts) == "table" and call.opts.Replay ~= true,
				"DEV reset: with the hook the tutorial starts as a new player's (gift and finish reward again: the reset took those tokens)", "Gifted " .. tostring(t.Gifted))
			Config.Dev.Admins = { 92040 }
			local late = join(joined, "DevLateJoiner", 92040)
			T.eq(hint(late, ATTR_TUTORIAL), true, "DEV tutorial: a developer joining while the hook exists gets NC_DevTutorial ('Restart tutorial' shown)")
			Config.Dev.Admins = {}
			TS.Reload = nil
			local live = prof.Tutorial
			live.Step, live.Done, live.Gifted = savedTutorial.Step, savedTutorial.Done, savedTutorial.Gifted
		end

		-- every DEV toast reads in full (NotifyController cuts toasts at 90 characters)
		local long = {}
		for _, t in ipairs(devToasts(owner, 0)) do
			if #t.text > 90 then
				long[#long + 1] = t.text
			end
		end
		T.check(#long == 0, "DEV: every DEV toast fits in a side toast (<= 90 characters)", table.concat(long, " | "))

		-- logging
		T.check(printed({ TAG, tostring(OWNER_ID), "allpets", "ok" }, outputMark) ~= nil, "DEV: commands are logged with print('" .. TAG .. " ...') including the UserId")
		T.check(printed({ TAG, "92001", "refused" }, 0) ~= nil, "DEV: refused commands of other players are logged with their UserId")
		return owner
	end

	-- a reset while TutorialService has no Reload hook: a tutorial that already paid its "spin" gift would wait
	-- forever for the tokens and pets the reset takes, so it is skipped; one that has not reached the gift carries on
	local function resetMidTutorial(Config, joined)
		local DataS, TS = mod("DataService"), mod("TutorialService")
		local Steps = K.M["shared/TutorialSteps"]
		if not TS or TS.Reload or type(TS.GetState) ~= "function" or not (Steps and Steps.Steps) then
			return -- with the hook a reset restarts the tutorial (checked with the owner)
		end
		local spinIndex = nil
		for i, step in ipairs(Steps.Steps) do
			if step.Id == "spin" then
				spinIndex = i
			end
		end
		if not T.check(spinIndex ~= nil, "DEV reset: (precondition) the tutorial has a 'spin' step") then
			return
		end
		Config.Dev.Admins = { 92030, 92031 }
		local gifted = join(joined, "DevTutorSpin", 92030)
		local early = join(joined, "DevTutorEarly", 92031)
		DataS.SetTutorial(gifted, { Step = spinIndex, Done = false, Gifted = true })
		DataS.ProfileRebased:Fire(gifted, DataS.GetProfile(gifted))
		advance(0.2)
		local st = TS.GetState(gifted)
		T.check(st and st.Id == "spin" and st.Done == false, "DEV reset: (precondition) a tutorial on the 'spin' step with its gift paid", st and tostring(st.Id) or "no state")
		local mark = send(gifted, "reset")
		local t = DataS.GetTutorial(gifted)
		st = TS.GetState(gifted)
		local toast = lastToast(gifted, mark)
		T.check(t.Done == true and st and st.Skipped == true and toast.kind == "good" and toast.text:find("tutorial skipped", 1, true) ~= nil,
			"DEV reset: a tutorial that already paid its gift is skipped instead of waiting forever for the wiped tokens / pets (the toast says so)", toast.text)
		T.eq(DataS.GetTokens(gifted), 0, "DEV reset: ...without paying the finish reward")
		local before = DataS.GetTutorial(early)
		mark = send(early, "reset")
		local after = DataS.GetTutorial(early)
		st = TS.GetState(early)
		toast = lastToast(early, mark)
		T.check(after.Done == false and after.Step == before.Step and st and st.Done == false and toast.text:find("skipped", 1, true) == nil,
			"DEV reset: a tutorial that has not reached its gift carries on (the gift is still to come)", toast.text)
		Config.Dev.Admins = {}
	end

	-- Config.Dev.Enabled = false: DevService must still listen on DevCommand, or Roblox queues every event an
	-- exploiter fires at it. A second copy of the module (fresh state) starts switched off on a stand-in remote.
	local function switchedOff(Config, owner)
		local DataS = mod("DataService")
		local inst = K.moduleInstance("server/Services/DevService")
		local R = K.remoteFolder()
		local live = R:FindFirstChild("DevCommand")
		local probe = Instance.new("RemoteEvent")
		local clone = inst:Clone()
		local function listeners()
			return Mock.ConnectionReport()["RemoteEvent.OnServerEvent"] or 0
		end
		local before = listeners()
		live.Name = "DevCommandLive"
		probe.Name = "DevCommand"
		probe.Parent = R
		clone.Name = "DevServiceSwitchedOff"
		clone.Parent = inst.Parent
		Config.Dev.Enabled = false
		local ok, err = pcall(function()
			local OffDev = require(clone)
			OffDev.Init({ DataService = DataS, TutorialService = mod("TutorialService"), IndexService = mod("IndexService") })
			T.eq(listeners() - before, 1, "DEV switched off (Config.Dev.Enabled = false): DevService still listens on DevCommand, so no event waits in Roblox's queue")
			local t0 = DataS.GetTokens(owner)
			local mark = K.logSize()
			for _ = 1, 6 do
				Mock.FromClient(probe, owner, "tokens", 50)
				Mock.FromClient(probe, owner, string.rep("x", 5000))
			end
			advance(0.2)
			T.check(DataS.GetTokens(owner) == t0 and #devToasts(owner, mark) == 0, "DEV switched off: ...and it drops every DevCommand at once, the owner's too (no tokens, no toast)")
			local okRun = OffDev.Run(owner, "tokens", 5, "smoke")
			T.eq(okRun, false, "DEV switched off: ...DevService.Run refuses everything")
		end)
		Config.Dev.Enabled = true
		probe:Destroy()
		clone:Destroy()
		live.Name = "DevCommand"
		if not ok then
			error(err, 0)
		end
	end

	local function studio(Dev, Config, joined, owner)
		local DataS = mod("DataService")
		local PC = K.M["shared/PetCatalog"]
		Mock.Options.Studio = true
		local tester = join(joined, "DevStudioTester", 92020)
		T.eq(hint(tester), true, "DEV Studio: everyone testing in Studio gets the tools (Config.Dev.AllowInStudio)")
		T.eq(count(DataS.GetProfile(tester).Pets), 0, "DEV Studio: StudioAutoGrant is off by default: nothing is granted on join")
		local t0 = DataS.GetTokens(tester)
		send(tester, "tokens", 777)
		T.eq(DataS.GetTokens(tester) - t0, 777, "DEV Studio: a Studio tester can run commands")
		Config.Dev.AllowInStudio = false
		t0 = DataS.GetTokens(tester)
		send(tester, "tokens", 5)
		T.eq(DataS.GetTokens(tester), t0, "DEV Studio: with AllowInStudio = false only the owner may (NC_Dev is just a hint, the server checks again)")
		T.eq(Dev.IsAllowed(owner), true, "DEV Studio: ...the owner still may")
		Config.Dev.AllowInStudio = true
		Config.Dev.Enabled = false
		T.eq(Dev.IsAllowed(owner), false, "DEV: Config.Dev.Enabled = false switches the tools off for everybody")
		Config.Dev.Enabled = true
		Config.Dev.StudioAutoGrant = true
		local auto = join(joined, "DevAutoGrant", 92021)
		advance(1)
		local prof = DataS.GetProfile(auto)
		T.check(prof ~= nil and count(prof.Pets) == #PC.Pets and count(prof.Discovered) == #PC.Pets, "DEV StudioAutoGrant: a Studio tester starts with every pet", prof and count(prof.Pets) or "no profile")
		T.check(DataS.GetTokens(auto) >= Config.Dev.GrantTokens and DataS.GetTokens(auto) < 2 * Config.Dev.GrantTokens,
			"DEV StudioAutoGrant: ...and Config.Dev.GrantTokens tokens, once", tostring(DataS.GetTokens(auto)))
	end

	S.dev_tools = guarded("dev_tools", function()
		if not K.needBoot() then
			return
		end
		local Config = config()
		local inst = K.moduleInstance("server/Services/DevService")
		if not T.check(inst ~= nil, "DEV: server/Services/DevService.lua is in the build") then
			return
		end
		local okLoad, Dev = pcall(require, inst)
		if not T.check(okLoad and type(Dev) == "table", "DEV: DevService loads", tostring(Dev)) then
			return
		end
		for _, fn in ipairs({ "Init", "IsAllowed", "Run" }) do
			T.check(type(Dev[fn]) == "function", "DEV: DevService." .. fn .. " is a function")
		end
		if not T.check(type(Config.Dev) == "table", "DEV: Config.Dev exists") then
			return
		end
		local R = K.remoteFolder()
		if not T.check(R ~= nil and R:FindFirstChild("DevCommand") ~= nil, "DEV: the DevCommand remote exists") then
			return
		end

		local saved = { Studio = Mock.Options.Studio, CreatorId = game.CreatorId, CreatorType = game.CreatorType, Dev = {} }
		for key, value in pairs(Config.Dev) do
			saved.Dev[key] = value
		end
		local methods = Mock.Classes and Mock.Classes.Player and Mock.Classes.Player.methods
		local savedRank = methods and methods.GetRankInGroup
		local joined = {}
		local ok, err = pcall(function()
			-- the published game: not Studio, owned by OWNER_ID
			Mock.Options.Studio = false
			game.CreatorType = Enum.CreatorType.User
			game.CreatorId = OWNER_ID
			local stranger = nonOwner(Dev, joined)
			admins(Dev, Config, joined)
			groupGame(Dev, Config, joined, stranger)
			local owner = ownerCommands(Dev, Config, joined)
			resetMidTutorial(Config, joined)
			switchedOff(Config, owner)
			studio(Dev, Config, joined, owner)
		end)
		Mock.Options.Studio = saved.Studio
		game.CreatorId = saved.CreatorId
		game.CreatorType = saved.CreatorType
		for key in pairs(Config.Dev) do
			Config.Dev[key] = nil
		end
		for key, value in pairs(saved.Dev) do
			Config.Dev[key] = value
		end
		if methods and savedRank then
			methods.GetRankInGroup = savedRank
		end
		K.removePlayers(joined)
		if not ok then
			error(err, 0)
		end
		K.flushErrors("dev tools")
		K.flushWarnings("dev tools")
	end)

	return S
end

----------------------------------------------------------------------------------------------------
-- client worlds
----------------------------------------------------------------------------------------------------
local function clientScenarios()
	local KC = _G.KC
	local S = {}
	local Players = game:GetService("Players")
	local UserInputService = game:GetService("UserInputService")
	local GuiService = game:GetService("GuiService")
	local LocalPlayer = Players.LocalPlayer

	local function advance(seconds)
		Mock.Advance(seconds)
	end
	local function shared(name)
		return require(Mock.GetPath(ROOTS["shared"] .. "/" .. name))
	end
	local function playerGui()
		return LocalPlayer:FindFirstChild("PlayerGui")
	end
	local function devGui()
		return playerGui():FindFirstChild("NimbusDev")
	end
	local function named(root, name)
		if not root then
			return nil
		end
		for _, d in ipairs(root:GetDescendants()) do
			if d.Name == name then
				return d
			end
		end
		return nil
	end
	local function shown(obj)
		return obj ~= nil and KC.isShown(obj)
	end
	local function controller()
		local inst = Mock.GetPath(ROOTS["client"] .. "/Controllers/DevController")
		return inst and require(inst)
	end

	-- a GUI object's box in the coordinates of a gui with IgnoreGuiInset = false (below the top bar)
	local function rect(inst)
		local g = inst:FindFirstAncestorOfClass("ScreenGui")
		local dy = (g and g.IgnoreGuiInset) and -(Mock.TopInset or 0) or 0
		local p, s = inst.AbsolutePosition, inst.AbsoluteSize
		return { x0 = p.X, y0 = p.Y + dy, x1 = p.X + s.X, y1 = p.Y + s.Y + dy }
	end
	local function overlap(a, b)
		return a.x0 < b.x1 - 0.5 and a.x1 > b.x0 + 0.5 and a.y0 < b.y1 - 0.5 and a.y1 > b.y0 + 0.5
	end
	local function area()
		return Vector2.new(Mock.Viewport.X, Mock.Viewport.Y - (Mock.TopInset or 0))
	end
	-- the middle of the screen (CONTRACT v2 centre tolerance), in the same coordinates
	local function band()
		local tol = CONTRACT.v2.centreTolerance
		local vp, inset = Mock.Viewport, Mock.TopInset or 0
		return { x0 = vp.X * (0.5 - tol), x1 = vp.X * (0.5 + tol), y0 = vp.Y * (0.5 - tol) - inset, y1 = vp.Y * (0.5 + tol) - inset }
	end
	-- what the DEV button must never touch: { label, r }
	local function neighbours()
		local out = {}
		local pg = playerGui()
		local function add(label, inst)
			if inst and inst:IsA("GuiObject") and KC.isShown(inst) and inst.AbsoluteSize.X > 0 and inst.AbsoluteSize.Y > 0 then
				out[#out + 1] = { label = label, r = rect(inst) }
			end
		end
		local menu = pg:FindFirstChild("NimbusMenu")
		add("menu column", menu and menu:FindFirstChild("MenuColumn"))
		local hud = pg:FindFirstChild("NimbusHud")
		if hud then
			for _, holder in ipairs(hud:GetChildren()) do
				for _, c in ipairs(holder:GetChildren()) do
					add("HUD " .. c.Name, c)
				end
			end
		end
		local hotbar = pg:FindFirstChild("NimbusHotbar")
		add("hotbar", hotbar and hotbar:FindFirstChild("Hotbar"))
		local tutorial = pg:FindFirstChild("NimbusTutorial")
		add("tutorial panel", tutorial and tutorial:FindFirstChild("TutorialPanel"))
		local mobile = pg:FindFirstChild("MobileControls")
		if mobile and mobile.Enabled then
			for _, d in ipairs(mobile:GetDescendants()) do
				if d:IsA("TextButton") then
					add("touch " .. d.Name, d)
				end
			end
			-- Roblox's own jump button is not in the mock: its footprint as MovementController assumes it
			local vp = Mock.Viewport
			local small = math.min(vp.X, vp.Y) <= 500
			local size = small and 70 or 120
			local bottom = small and 20 or size * 0.75
			local inset = Mock.TopInset or 0
			out[#out + 1] = { label = "jump button", r = { x0 = vp.X - (size * 1.5 + 10), y0 = vp.Y - bottom - size - inset, x1 = vp.X - (size * 0.5 + 10), y1 = vp.Y - bottom - inset } }
		end
		return out
	end
	local function scaleOf(inst)
		local scale = 1
		local cur = inst
		while cur and cur ~= game do
			if cur:IsA("GuiObject") then
				for _, c in ipairs(cur:GetChildren()) do
					if c:IsA("UIScale") and c.Name ~= "FxScale" then
						scale = scale * c.Scale
					end
				end
			end
			cur = cur.Parent
		end
		return scale
	end
	-- shown texts of the DEV gui smaller than floorPx on screen
	local function smallDevTexts(floorPx)
		local out, measured = {}, 0
		for _, d in ipairs(devGui():GetDescendants()) do
			if (d:IsA("TextLabel") or d:IsA("TextButton")) and KC.isShown(d) and tostring(d.Text):gsub("%s", "") ~= "" then
				local px = d.TextScaled and d.AbsoluteSize.Y or d.TextSize * scaleOf(d)
				measured = measured + 1
				if px < floorPx - 0.01 then
					out[#out + 1] = string.format("%s %.1f px", tostring(d.Text):sub(1, 20), px)
				end
			end
		end
		return out, measured
	end
	local function lastCall(from)
		local calls = KC.serverCalls("DevCommand", from)
		return calls[#calls], #calls
	end
	local function logSize()
		return #Mock.RemoteLog
	end

	-- the DEV tile on the current screen: shown, right edge, inside the screen, clear of everything, readable
	local function checkTile(label, floorPx)
		local button = named(devGui(), "DevButton")
		if not T.check(shown(button), label .. ": the DEV button is shown") then
			return
		end
		local r, a, b = rect(named(devGui(), "DevTile")), area(), band()
		T.check(r.x0 >= -0.5 and r.y0 >= -0.5 and r.x1 <= a.X + 0.5 and r.y1 <= a.Y + 0.5, label .. ": the DEV button is fully on screen", string.format("%d,%d - %d,%d of %dx%d", r.x0, r.y0, r.x1, r.y1, a.X, a.Y))
		T.check((r.x0 + r.x1) / 2 > a.X * 0.62, label .. ": the DEV button sits on the right edge", string.format("x %d - %d", r.x0, r.x1))
		local hits = {}
		for _, n in ipairs(neighbours()) do
			if overlap(r, n.r) then
				hits[#hits + 1] = n.label
			end
		end
		T.check(#hits == 0, label .. ": the DEV button touches none of the menu column, HUD, hotbar, tutorial panel, touch buttons", table.concat(hits, ", "))
		T.check(not overlap(r, b), label .. ": the DEV button stays out of the middle of the screen")
		local small = smallDevTexts(floorPx)
		T.check(#small == 0, label .. ": the DEV button text is readable (>= " .. floorPx .. " px)", table.concat(small, "; "))
		T.info(string.format("%s: DEV button at %d,%d - %d,%d (gui area %dx%d)", label, r.x0, r.y0, r.x1, r.y1, a.X, a.Y))
	end

	-- DevService's hints live on the PlayerGui (a PlayerGui replicates to its own player only)
	local function setHint(name, value)
		playerGui():SetAttribute(name, value)
	end

	-- NimbusNotify's toast column: its frame and the shown toast cards, newest first
	local function toastStack()
		local notify = playerGui():FindFirstChild("NimbusNotify")
		return notify and named(notify, "ToastStack")
	end
	local function toastCards()
		local stack = toastStack()
		local slots = {}
		for _, slot in ipairs(stack and stack:GetChildren() or {}) do
			local card = slot:FindFirstChild("Toast")
			if card and KC.isShown(card) and card.AbsoluteSize.Y > 0 then
				slots[#slots + 1] = { order = slot.LayoutOrder, card = card }
			end
		end
		table.sort(slots, function(a, b)
			return a.order < b.order
		end)
		local out = {}
		for i, s in ipairs(slots) do
			out[i] = s.card
		end
		return out
	end
	-- what "Give all pets" makes the server send: three Pet Index toasts, then the DEV answer (the newest)
	local ALLPETS_TOASTS = {
		{ "Pet Index: every Common pet found! Claim 500 tokens in the Index.", "good" },
		{ "Pet Index: every Rare pet found! Claim 1,500 tokens in the Index.", "good" },
		{ "Pet Index: every Epic pet found! Claim 4,000 tokens in the Index.", "good" },
		{ "DEV: you got 30 new pets: all 31 are yours!", "good" },
	}
	local function showAllpetsToasts()
		for _, t in ipairs(ALLPETS_TOASTS) do
			KC.toClient("Notify", t[1], t[2], 1.5)
		end
		advance(0.6) -- the cards slide in
	end
	local function clearToasts()
		advance(2.5) -- every test toast lasts 1.5 s
	end

	-- The open panel and the side toasts: on screens with room for both, the two newest toasts (the DEV answer
	-- on top) cover no part of the panel. On a very short screen (`toastsFit` false) that cannot be: reported only.
	local function checkPanelToasts(label, toastsFit)
		local panel = named(devGui(), "DevPanel")
		if not shown(panel) then
			return
		end
		showAllpetsToasts()
		local cards = toastCards()
		local pr = rect(panel)
		local hits = {}
		for i = 1, math.min(2, #cards) do
			local r = rect(cards[i])
			if overlap(pr, r) then
				hits[#hits + 1] = string.format("toast %d at %d,%d - %d,%d", i, r.x0, r.y0, r.x1, r.y1)
			end
		end
		if toastsFit then
			T.check(#cards >= 2 and #hits == 0, label .. ": the two newest side toasts (the DEV answer on top) leave the open panel readable",
				#cards .. " toasts; " .. table.concat(hits, ", ") .. string.format(" / panel %d,%d - %d,%d", pr.x0, pr.y0, pr.x1, pr.y1))
		else
			T.info(string.format("*%s: too short for the panel below the toasts: %d of the 2 newest toasts overlap it (panel %d,%d - %d,%d)", label, #hits, pr.x0, pr.y0, pr.x1, pr.y1))
		end
		clearToasts()
	end

	local function checkPanel(label, floorPx, onPc)
		local panel = named(devGui(), "DevPanel")
		if not T.check(shown(panel), label .. ": the DEV button opens the 'Developer tools' panel") then
			return
		end
		T.check(KC.findText("Developer tools", devGui()) ~= nil, label .. ": the panel is titled 'Developer tools'")
		T.check(not shown(named(devGui(), "DevButton")), label .. ": the DEV button hides while the panel is open")
		local r, a = rect(panel), area()
		T.check(r.x0 >= -0.5 and r.x1 <= a.X + 0.5 and r.y0 >= -0.5 and r.y1 <= a.Y + 0.5, label .. ": the panel is fully on screen", string.format("%d,%d - %d,%d of %dx%d", r.x0, r.y0, r.x1, r.y1, a.X, a.Y))
		T.check(a.X - r.x1 <= 24, label .. ": the panel is docked to the right edge (a side panel)", string.format("right edge at %d of %d", r.x1, a.X))
		T.check(not overlap(r, band()), label .. ": the panel is never in the middle of the screen", string.format("%d,%d - %d,%d", r.x0, r.y0, r.x1, r.y1))
		local hits = {}
		for _, n in ipairs(neighbours()) do
			if overlap(r, n.r) then
				hits[#hits + 1] = n.label
			end
		end
		if onPc then
			T.check(#hits == 0, label .. ": the open panel covers none of the menu column, HUD, hotbar, tutorial panel", table.concat(hits, ", "))
		else
			T.info(label .. ": while open the panel covers: " .. (#hits == 0 and "nothing" or table.concat(hits, ", ")))
		end
		local small, measured = smallDevTexts(floorPx)
		T.check(#small == 0 and measured >= 6, label .. ": every text of the panel is readable (>= " .. floorPx .. " px)", #small .. " small: " .. table.concat(small, "; "))
		local scale = named(panel, "ReadScale")
		T.info(string.format("%s: panel at %d,%d - %d,%d, design height %d, scale %.2f", label, r.x0, r.y0, r.x1, r.y1, panel.Size.Y.Offset, scale and scale.Scale or 0))
	end

	-- The closed tile and the side toasts: clear of the two newest toasts whenever the screen has room for that.
	local function checkTileToasts(label, toastsFit)
		local tile = named(devGui(), "DevTile")
		if not shown(named(devGui(), "DevButton")) then
			return
		end
		showAllpetsToasts()
		local cards = toastCards()
		local tr = rect(tile)
		local hits = 0
		for i = 1, math.min(2, #cards) do
			if overlap(tr, rect(cards[i])) then
				hits = hits + 1
			end
		end
		if toastsFit then
			T.check(#cards >= 2 and hits == 0, label .. ": the two newest side toasts never cover the DEV button", #cards .. " toasts, " .. hits .. " overlap")
		else
			T.info(string.format("*%s: too short for the DEV button below the toasts: %d of the 2 newest toasts overlap it", label, hits))
		end
		clearToasts()
	end

	S.client_dev = guarded("client_dev", function()
		local Config = shared("Config")
		local Theme = shared("Theme")
		local Dev = controller()
		if not T.check(type(Dev) == "table" and type(Dev.Init) == "function", "DEV: client/Controllers/DevController.lua loads") then
			return
		end
		Mock.SetViewport(1920, 1080)
		setHint(ATTR, nil)
		setHint(ATTR_TUTORIAL, nil)
		advance(0.5)
		T.check(not shown(named(playerGui(), "DevButton")), "DEV: no DEV button without the NC_Dev attribute")
		-- the old place of the hint (the Player, which every client can read) means nothing any more
		LocalPlayer:SetAttribute(ATTR, true)
		advance(0.6)
		T.check(not shown(named(playerGui(), "DevButton")), "DEV: NC_Dev on the Player itself (readable by every client) shows nothing: the hint lives on the PlayerGui")
		LocalPlayer:SetAttribute(ATTR, nil)
		setHint(ATTR, true)
		advance(1)
		local g = devGui()
		if not T.check(g ~= nil and g:IsA("ScreenGui"), "DEV: NC_Dev = true on the PlayerGui builds the ScreenGui 'NimbusDev'") then
			return
		end
		T.eq(g.ResetOnSpawn, false, "DEV: NimbusDev.ResetOnSpawn = false")
		T.eq(g.IgnoreGuiInset, false, "DEV: NimbusDev.IgnoreGuiInset = false (it carries text)")
		checkTile("DEV 1920x1080", 15)
		local tile = rect(named(g, "DevTile"))
		local a = area()
		T.check(a.Y - tile.y1 <= 40 and a.X - tile.x1 <= 40, "DEV 1920x1080: on a PC the DEV button takes the bottom-right corner", string.format("%d,%d - %d,%d", tile.x0, tile.y0, tile.x1, tile.y1))
		checkTileToasts("DEV 1920x1080", true)

		-- a double (or triple) click on the DEV tile: the panel opens where the tile was, so the next clicks land
		-- on its buttons ('Reset my data' is right there on a PC); they are ignored for a moment
		local mark = logSize()
		Mock.Click(named(g, "DevButton"))
		advance(0.12)
		local reset = named(g, "Dev_reset")
		local tileOverReset = reset ~= nil and shown(reset) and overlap(tile, rect(reset))
		for _ = 1, 2 do
			if reset then
				Mock.Click(reset)
			end
			advance(0.12)
		end
		advance(0.3)
		local _, sent = lastCall(mark)
		T.check(reset ~= nil and sent == 0 and reset.Text == "Reset my data",
			"DEV panel: a triple click on the DEV button (the last clicks landing on 'Reset my data') opens the panel and nothing else",
			(reset and reset.Text or "no reset button") .. " / sent " .. sent)
		T.info("DEV 1920x1080: 'Reset my data' " .. (tileOverReset and "lies under" or "is clear of") .. " the closed DEV button's spot")

		-- the panel and what every button sends
		advance(0.2)
		checkPanel("DEV 1920x1080", 15, true)
		T.check(type(Dev.IsOpen) == "function" and Dev.IsOpen() == true, "DEV: DevController.IsOpen() is true while the panel is open")
		-- 'Restart tutorial' only when the server says it works (NC_DevTutorial)
		local restart = named(g, "Dev_tutorial")
		T.check(restart ~= nil and not shown(restart), "DEV panel: no 'Restart tutorial' button while the server has no tutorial restart (NC_DevTutorial unset)")
		local heightWithout = named(g, "DevPanel").Size.Y.Offset
		setHint(ATTR_TUTORIAL, true)
		advance(0.6)
		T.check(shown(restart) and named(g, "DevPanel").Size.Y.Offset > heightWithout, "DEV panel: NC_DevTutorial = true shows 'Restart tutorial' (and the panel grows for it)",
			heightWithout .. " -> " .. named(g, "DevPanel").Size.Y.Offset)
		local grantLabel = "+" .. Theme.ShortNumber(Config.Dev.GrantTokens) .. " tokens"
		local expected = {
			{ "Dev_allpets", "Give all pets", "allpets" },
			{ "Dev_tokens", grantLabel, "tokens", Config.Dev.GrantTokens },
			{ "Dev_tutorial", "Restart tutorial", "tutorial" },
			{ "Dev_skiptutorial", "Skip tutorial", "skiptutorial" },
		}
		for _, e in ipairs(expected) do
			local button = named(g, e[1])
			if T.check(shown(button) and button.Text == e[2], "DEV panel: a big '" .. e[2] .. "' button", button and button.Text) then
				mark = logSize()
				Mock.Click(button)
				advance(0.4)
				local call, n = lastCall(mark)
				T.check(n == 1 and call.args[1] == e[3] and call.args[2] == e[4], "DEV panel: '" .. e[2] .. "' sends DevCommand('" .. e[3] .. "'" .. (e[4] and (", " .. tostring(e[4])) or "") .. ")",
					call and (tostring(call.args[1]) .. ", " .. tostring(call.args[2]) .. " x" .. n) or "nothing sent")
			end
		end
		T.check(KC.findText("Only you can see this", g) ~= nil, "DEV panel: the note 'Only you can see this'")
		-- reset needs a second, separate tap
		if T.check(shown(reset) and reset.Text == "Reset my data", "DEV panel: a 'Reset my data' button", reset and reset.Text) then
			mark = logSize()
			Mock.Click(reset)
			advance(0.12)
			local _, n = lastCall(mark)
			T.check(n == 0 and reset.Text == "Are you sure?", "DEV panel: the first tap on 'Reset my data' only asks 'Are you sure?'", reset.Text .. " / sent " .. n)
			Mock.Click(reset)
			advance(0.12)
			_, n = lastCall(mark)
			T.check(n == 0 and reset.Text == "Are you sure?", "DEV panel: a double click on 'Reset my data' (taps 0.12 s apart) only arms it: nothing is sent", reset.Text .. " / sent " .. n)
			advance(0.5)
			Mock.Click(reset)
			advance(0.4)
			local call
			call, n = lastCall(mark)
			T.check(n == 1 and call.args[1] == "reset" and reset.Text == "Reset my data", "DEV panel: a separate second tap (0.7 s later) sends DevCommand('reset')", call and tostring(call.args[1]) or "nothing sent")
			mark = logSize()
			Mock.Click(reset)
			advance(4.6)
			_, n = lastCall(mark)
			T.check(n == 0 and reset.Text == "Reset my data", "DEV panel: an unconfirmed reset disarms itself after a few seconds", reset.Text .. " / sent " .. n)
		end
		-- a quick double tap sends once
		mark = logSize()
		Mock.Click(named(g, "Dev_allpets"))
		Mock.Click(named(g, "Dev_allpets"))
		advance(0.4)
		local _, n = lastCall(mark)
		T.eq(n, 1, "DEV panel: a double tap sends the command once")
		checkPanelToasts("DEV 1920x1080", true)

		-- closing: X, Esc, gamepad B
		Mock.Click(named(named(g, "DevPanel"), "Close"))
		advance(0.3)
		T.check(not shown(named(g, "DevPanel")) and shown(named(g, "DevButton")), "DEV panel: the red X closes it and the DEV button comes back")
		Mock.Click(named(g, "DevButton"))
		advance(0.3)
		Mock.FireSignal(UserInputService, "InputBegan", Mock.NewInput("Escape", "Keyboard", "Begin"), false)
		advance(0.3)
		T.check(not shown(named(g, "DevPanel")), "DEV panel: Esc closes it")
		local uisClass = Mock.Classes and Mock.Classes.UserInputService
		local uisMethods = uisClass and uisClass.methods
		local savedLast = uisMethods and uisMethods.GetLastInputType
		if savedLast then
			uisMethods.GetLastInputType = function()
				return Enum.UserInputType.Gamepad1
			end
			Mock.Click(named(g, "DevButton"))
			advance(0.3)
			T.check(GuiService.SelectedObject == named(g, "Dev_allpets"), "DEV panel: opened with a gamepad, the first button is selected", tostring(GuiService.SelectedObject))
			T.check(Mock.BoundActions["NimbusDevBack"] ~= nil, "DEV panel: gamepad B is bound while it is open")
			Mock.TriggerAction("NimbusDevBack", "Begin", Mock.NewInput("ButtonB", "Gamepad1", "Begin"))
			advance(0.3)
			T.check(not shown(named(g, "DevPanel")), "DEV panel: gamepad B closes it")
			T.check(GuiService.SelectedObject == named(g, "DevButton"), "DEV panel: ...and the selection goes back to the DEV button", tostring(GuiService.SelectedObject))
			T.check(Mock.BoundActions["NimbusDevBack"] == nil, "DEV panel: ...and B is released again (it dashes as usual)")
			uisMethods.GetLastInputType = savedLast
			GuiService.SelectedObject = nil
		else
			T.info("*the mock's GetLastInputType cannot be patched: gamepad checks skipped")
		end
		T.check(named(g, "DevButton").Selectable == true and named(g, "Dev_allpets").Selectable == true, "DEV: the button and the panel buttons are Selectable (gamepad)")

		-- other window sizes (desktop): the tile stays clear, the panel stays at the side, the toasts stay readable
		for _, size in ipairs({ { 1280, 720, true }, { 1024, 768, true }, { 844, 390, false }, { 390, 844, false } }) do
			Mock.SetViewport(size[1], size[2])
			advance(1.2)
			local label = "DEV " .. size[1] .. "x" .. size[2]
			local floorPx = size[2] >= 1000 and 15 or 14
			checkTile(label, floorPx)
			-- (844x390: with the Phase 2 currency stack - Cloud Tokens, Cash, Gems - only the newest toast fits under
			-- it, so the "two newest toasts" check is reported only there, like the open panel's below)
			checkTileToasts(label, size[1] ~= 844)
			Mock.Click(named(g, "DevButton"))
			advance(0.6)
			checkPanel(label, floorPx, size[3])
			checkPanelToasts(label, size[1] ~= 844)
			Dev.Close()
			advance(0.3)
		end
		Mock.SetViewport(1920, 1080)
		advance(1)

		-- NC_Dev removed: everything goes away
		Mock.Click(named(g, "DevButton"))
		advance(0.3)
		setHint(ATTR, nil)
		advance(0.6)
		T.check(not shown(named(g, "DevButton")) and not shown(named(g, "DevPanel")), "DEV: removing NC_Dev hides the button and the panel")
		T.check(Mock.BoundActions["NimbusDevBack"] == nil, "DEV: ...and releases gamepad B")
		setHint(ATTR_TUTORIAL, nil)
		KC.flushErrors("dev client")
		KC.flushWarnings("dev client")
	end)

	S.client_dev_mobile = guarded("client_dev_mobile", function()
		local Dev = controller()
		if not T.check(type(Dev) == "table", "DEV (phone): DevController loads") then
			return
		end
		local mobile = playerGui():FindFirstChild("MobileControls")
		T.check(mobile ~= nil and mobile.Enabled, "DEV (phone): the touch RUN / DASH buttons are on screen (precondition)")
		setHint(ATTR, true)
		for _, size in ipairs({ { 390, 844, true }, { 844, 390, false }, { 1024, 768, true } }) do
			Mock.SetViewport(size[1], size[2])
			advance(1.2)
			local label = "DEV phone " .. size[1] .. "x" .. size[2]
			if size[1] == 1024 then
				label = "DEV tablet 1024x768"
			end
			checkTile(label, 14)
			checkTileToasts(label, size[3])
			Mock.Click(named(devGui(), "DevButton"))
			advance(0.6)
			checkPanel(label, 14, false)
			checkPanelToasts(label, size[3])
			Dev.Close()
			advance(0.3)
		end
		Mock.SetViewport(390, 844)
		setHint(ATTR, nil)
		advance(0.6)
		T.check(not shown(named(devGui(), "DevButton")), "DEV (phone): removing NC_Dev hides the button")
		KC.flushErrors("dev phone")
		KC.flushWarnings("dev phone")
	end)

	return S
end

if CONTEXT == "server" then
	return serverScenarios()
end
return clientScenarios()
