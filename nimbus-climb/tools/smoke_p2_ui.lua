-- smoke_p2_ui.lua: Phase 2 UI (ARCHITECTURE_V3.md "Phase 2 build contract", UI): the Home tile + Home window, the Pets
-- panel actions (Feed picker, Place in Garden, Train in Gym, tier / hybrid badges, levels, scaled stats), the Shop's
-- Gems tab, the Index Fusions tab (client/Controllers/MenuController.lua, IndexController.lua), the appended home
-- chapter of the tutorial (shared/TutorialSteps.lua, server/Services/TutorialService.lua) and the NPC tips
-- (shared/NpcDialog.lua). Loaded by tools/smoke.py in BOTH worlds; ARGS.context picks the half:
--   p2ui_content        (server, content) the home chapter is appended after the nine basics (ids, chapters, ChapterEnd,
--                       known CompleteOn, Station of every "Built" step, home targets); NPC tips: every NPC has 3-5
--                       lines that fit the dialog (<= 125 bytes, no rich-text characters), the Kitchen tip is Granny
--                       Owl's, the Gym tip Coach Corgi's, and Fusion, Prestige and Gems are explained with the real
--                       numbers of TycoonCatalog / Config.Gems
--   p2ui_tutorial       (server, booted) a player who finished the basics resumes at "claim": the arrow points at a
--                       free gate, E claims (-> "press": the arrow points at the Press 1 pad of the claimed plot),
--                       building Press 1 (-> "collect": first the free Collector pad, then the Collector itself),
--                       banking the Collector (-> "kitchen": the arrow walks the pads on the way to the Kitchen, each
--                       one buyable), the Kitchen (-> "feed": the Kitchen while there is no food, then the Pets menu
--                       button), feeding a pet ends the chapter: Done, the Cash reward paid once, kept after a rejoin;
--                       a skipped tutorial never resumes; a new player's "home" step completes by claiming a plot;
--                       events of another step are refused
--   client_p2ui         (client) the Home tile (MenuButton_Spot, "Home"): GoToSpot + a side hint without a home, the
--                       Home window with one: every station row, live Collector / income numbers from the plot folder,
--                       Upgrade / Collect / Go home / a confirmed Prestige send HomeAction, locked stations show why;
--                       Pets: per-copy slots with tier / hybrid chips and levels, the Feed picker (Feed / Cook ->
--                       PetCare), Place in Garden / Leave Garden (HomeAction GardenSet), Train in Gym (PetCare GymSet);
--                       Shop Gems tab: the Secret roulette with its odds, a gem spin sends BuyRoulette(id, "Gems"), the
--                       paid-random-items policy hides gem roulettes; the Index Fusions tab lists the fused copies and
--                       is not a reward group; every text of these windows is >= 18 design px; no script errors
--   client_p2ui_mobile  (phone 390x844) the same windows keep every text >= 14 px on screen
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local CONTEXT = (ARGS and ARGS.context) or "server"

local abs, floor, max, min = math.abs, math.floor, math.max, math.min

local function countKeys(map)
	local n = 0
	for _ in pairs(type(map) == "table" and map or {}) do
		n = n + 1
	end
	return n
end

----------------------------------------------------------------------------------------------------
-- server half
----------------------------------------------------------------------------------------------------
local function serverScenarios()
	local S = {}
	local K = _G.K
	local advance, config, mod, waitFor = K.advance, K.config, K.mod, K.waitFor

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

	------------------------------------------------------------------------------------------------
	-- p2ui_content
	------------------------------------------------------------------------------------------------
	S.p2ui_content = guarded("p2ui_content", function()
		local Steps = requireAt("shared/TutorialSteps")
		local TC = requireAt("shared/TycoonCatalog")
		local ND = requireAt("shared/NpcDialog")
		local Config = config()
		if not T.check(type(Steps) == "table" and type(Steps.Steps) == "table", "p2ui: shared/TutorialSteps loads") then
			return
		end
		local ids = {}
		for i, step in ipairs(Steps.Steps) do
			ids[i] = step.Id
		end
		T.eq(table.concat(ids, ","), "welcome,home,shop,spin,equip,index,portal,finish,done,claim,press,collect,kitchen,feed",
			"p2ui: the home chapter (claim, press, collect, kitchen, feed) is appended after the nine basics")
		local start = Steps.ChapterStart and Steps.ChapterStart[2]
		T.eq(start, 10, "p2ui: chapter 2 starts at step 10 (a finished Phase 1 tutorial stored Step = 10)")
		local known = { Next = true, NearSpot = true, ShopOpened = true, Rolled = true, Equipped = true, IndexOpened = true,
			MatchStarted = true, MatchEnded = true, Claimed = true, Built = true, Collected = true, Fed = true }
		local bad, ends = {}, {}
		for i, step in ipairs(Steps.Steps) do
			if not known[step.CompleteOn] then
				bad[#bad + 1] = step.Id .. ":" .. tostring(step.CompleteOn)
			end
			if step.CompleteOn == "Built" and not (TC and TC.Get(step.Station)) then
				bad[#bad + 1] = step.Id .. " builds unknown station " .. tostring(step.Station)
			end
			if (step.Chapter or 1) == 2 and i < start then
				bad[#bad + 1] = step.Id .. " is a chapter 2 step inside chapter 1"
			end
			if step.ChapterEnd then
				ends[#ends + 1] = step.Id
			end
			if type(step.Text) ~= "string" or #step.Text < 20 or #step.Text > 200 then
				bad[#bad + 1] = step.Id .. " text length " .. tostring(step.Text and #step.Text)
			end
		end
		T.check(#bad == 0, "p2ui: every step has a known CompleteOn, a real station and a short text", table.concat(bad, "; "))
		T.eq(table.concat(ends, ","), "done,feed", "p2ui: each chapter ends on one ChapterEnd step (done, feed)")
		local byId = {}
		for _, step in ipairs(Steps.Steps) do
			byId[step.Id] = step
		end
		T.check(byId.home and byId.home.CompleteOn == "Claimed" and byId.home.Target and byId.home.Target.Gate == true,
			"p2ui: the basics' 'home' step now leads to a free gate and completes on a claim (E at the gate)")
		T.check(byId.claim.CompleteOn == "Claimed" and byId.press.Station == "Press1" and byId.collect.CompleteOn == "Collected"
			and byId.kitchen.Station == "Kitchen" and byId.kitchen.Target.Path == true and byId.feed.CompleteOn == "Fed"
			and byId.feed.Target.Food == true, "p2ui: claim -> Press 1 -> collect -> Kitchen (following the pad path) -> feed")

		-- NPC tips
		if not T.check(type(ND) == "table" and type(ND.Npcs) == "table" and #ND.Npcs == 6, "p2ui: shared/NpcDialog has the six NPCs") then
			return
		end
		local long, lineCounts = {}, {}
		local all = {}
		for _, npc in ipairs(ND.Npcs) do
			local n = #(npc.Lines or {})
			if n < 3 or n > 5 then
				lineCounts[#lineCounts + 1] = npc.Id .. "=" .. n
			end
			for i, line in ipairs(npc.Lines or {}) do
				if #line > 125 or line:find("[<>&]") then
					long[#long + 1] = npc.Id .. "#" .. i .. " (" .. #line .. ")"
				end
				all[npc.Id] = (all[npc.Id] or "") .. " " .. line
			end
		end
		T.check(#lineCounts == 0, "p2ui: every NPC has 3-5 lines", table.concat(lineCounts, ", "))
		T.check(#long == 0, "p2ui: every NPC line fits the dialog well (<= 125 bytes, no rich-text characters)", table.concat(long, ", "))
		local function says(id, ...)
			local text = all[id] or ""
			for _, needle in ipairs({ ... }) do
				if not text:find(needle, 1, true) then
					return false, needle
				end
			end
			return true
		end
		local snack = TC and TC.Foods and TC.Foods.Snack
		T.check(says("granny_owl", "Kitchen", "Feed", snack and (tostring(snack.Xp) .. " XP") or "XP"),
			"p2ui: Granny Owl explains the Kitchen and feeding (with the Snack's real XP)")
		local gym1 = TC and TC.EffectsOf and TC.EffectsOf("Gym", 1)
		T.check(says("coach_corgi", "Gym", "Train in Gym", gym1 and (tostring(gym1.XpPerMinute) .. " XP a minute") or "XP"),
			"p2ui: Coach Corgi explains the Gym (with its real XP per minute)")
		local P = TC and TC.Prestige or {}
		T.check(says("mayor_panda", "free gate", "Prestige", "Home Level " .. tostring(P.HomeLevel or 40), tostring(P.GemReward or 100) .. " Gems"),
			"p2ui: Mayor Panda explains claiming a home and Prestige (Home Level " .. tostring(P.HomeLevel) .. ", the Gems reward)")
		local Util = requireAt("shared/Util")
		local secret = Config.Gems and Config.Gems.SecretRoulette
		local secretPrice = (secret and Util and Util.Commas) and Util.Commas(secret.GemPrice) or "1,500"
		T.check(says("professor_axolotl", "Fusion Machine", "Golden", "Rainbow", "hybrid", "Storm Altar", secretPrice .. " Gems"),
			"p2ui: Professor Axolotl explains the Fusion Machine and the Secret roulette's Gem price")
		T.check(says("granny_owl", "Gems"), "p2ui: Granny Owl mentions spinning roulettes with Gems")
	end)

	------------------------------------------------------------------------------------------------
	-- p2ui_tutorial
	------------------------------------------------------------------------------------------------
	local userSeq = 0
	local function join(prefix)
		userSeq = userSeq + 1
		local p = Mock.AddPlayer(prefix .. userSeq, 967000 + userSeq)
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

	-- the world position of a pad on a plot (HomeBuilder's model, else the catalog slot)
	local function padPosition(HB, TC, info, id)
		local model = HB and HB.GetPad and HB.GetPad(info, id)
		if model then
			local ok, cf = pcall(function()
				return model:GetPivot()
			end)
			if ok and cf then
				return cf.Position
			end
		end
		local def = TC.Get(id)
		if def and def.Slot and def.Slot.Pad and info.PlotCFrame then
			return (info.PlotCFrame * def.Slot.Pad).Position
		end
		return nil
	end

	S.p2ui_tutorial = guarded("p2ui_tutorial", function()
		if not K.needBoot() then
			return
		end
		local Config = config()
		local TSv = mod("TutorialService")
		local DataS = mod("DataService")
		local SS = mod("SpotService")
		local Ty = requireAt("server/Services/TycoonService")
		local Care = requireAt("server/Services/PetCareService")
		local HB = requireAt("server/Services/HomeBuilder")
		local Steps = requireAt("shared/TutorialSteps")
		local TC = requireAt("shared/TycoonCatalog")
		local PK = requireAt("shared/PetKeys")
		if not T.check(TSv and DataS and SS and Ty and Care and Steps and TC and PK and type(TSv.Reload) == "function",
			"p2ui tutorial: TutorialService (Reload), TycoonService, PetCareService, TycoonCatalog and PetKeys are loaded") then
			return
		end
		local errors0 = #Mock.Errors
		local start = Steps.ChapterStart[2]
		local function state(p)
			return TSv.GetState(p)
		end
		local function stepId(p)
			local st = state(p)
			return st and not st.Done and st.Id or (st and st.Done and "done!") or nil
		end

		-- a player who finished the basics resumes at the home chapter
		local p = join("HomeTut")
		T.check(DataS.SetTutorial(p, { Step = start, Done = true, Gifted = true }) == true, "p2ui tutorial: the finished-basics progress is stored")
		TSv.Reload(p)
		advance(0.3)
		T.eq(stepId(p), "claim", "p2ui tutorial: a finished Phase 1 tutorial (Step 10, Done) resumes at 'claim'")
		local st = state(p)
		T.check(st and st.Chapter == 2 and st.Step == start and st.Total == #Steps.Steps, "p2ui tutorial: ...as chapter 2, step " .. start .. "/" .. #Steps.Steps)
		local target = st and st.Target
		local suggestion = SS.SuggestSpot(p)
		local gate = suggestion and SS.GateCFrame(suggestion)
		T.check(type(target) == "table" and target.Kind == "Spot" and typeof(target.Position) == "Vector3" and gate ~= nil
			and (target.Position - gate.Position).Magnitude < 1 and type(target.SpotIndex) == "number",
			"p2ui tutorial: the 'claim' arrow points at the gate of a free plot (Kind Spot, Position, SpotIndex)")
		local index = target and target.SpotIndex
		if not T.check(index ~= nil and SS.GetOwner(index) == nil, "p2ui tutorial: the suggested plot is free") then
			leave(p)
			return
		end
		claim(p, index)
		waitFor(function()
			return stepId(p) ~= "claim"
		end, 3)
		T.eq(stepId(p), "press", "p2ui tutorial: E at the gate completes 'claim'")
		local info = SS.GetSpot(p)
		st = state(p)
		local pressPad = info and padPosition(HB, TC, info, "Press1")
		T.check(st and st.Target and st.Target.Kind == "Spot" and st.Target.SpotIndex == index and typeof(st.Target.Position) == "Vector3"
			and pressPad ~= nil and (st.Target.Position - pressPad).Magnitude < 1,
			"p2ui tutorial: the 'press' arrow points at the Cloud Press 1 pad of the claimed plot")
		local okBuy = Ty.Buy(p, "Press1")
		advance(0.6)
		T.check(okBuy == true, "p2ui tutorial: Press 1 is bought (free)")
		T.eq(stepId(p), "collect", "p2ui tutorial: building Press 1 completes 'press'")
		st = state(p)
		local collectorPad = padPosition(HB, TC, info, "Collector")
		T.check(st and st.Target and collectorPad and (st.Target.Position - collectorPad).Magnitude < 1 and tostring(st.Hint):find("Collector", 1, true),
			"p2ui tutorial: 'collect' first points at the free Collector pad", st and tostring(st.Hint))
		Ty.Buy(p, "Collector")
		advance(0.6)
		st = state(p)
		T.check(st and st.Id == "collect" and st.Target and collectorPad and (st.Target.Position - collectorPad).Magnitude > 0.5
			and tostring(st.Hint):find("Step on the Collector", 1, true),
			"p2ui tutorial: ...then at the built Collector itself ('Step on the Collector')", st and tostring(st.Hint))
		advance(4) -- the presses fill the Collector (1 s income tick)
		local home = DataS.GetHome(p)
		T.check(home and (tonumber(home.CollectorCash) or 0) >= 1, "p2ui tutorial: the Collector filled up", home and tostring(home.CollectorCash))
		T.eq(stepId(p), "collect", "p2ui tutorial: income alone does not complete 'collect'")
		local okCollect = Ty.Collect(p)
		advance(0.6)
		T.check(okCollect == true, "p2ui tutorial: the Collector is banked")
		T.eq(stepId(p), "kitchen", "p2ui tutorial: banking the Collector completes 'collect'")

		-- kitchen: the arrow names the next pad on the way, every one of them buyable
		DataS.AddCash(p, 5000000)
		advance(0.6)
		local path, lost = {}, nil
		for _ = 1, 40 do
			if stepId(p) ~= "kitchen" then
				break
			end
			st = state(p)
			local padId = nil
			for _, pad in ipairs(TC.AvailablePads(DataS.GetHome(p))) do
				local pos = padPosition(HB, TC, info, pad.StationId)
				if not pad.Locked and pos and st.Target and typeof(st.Target.Position) == "Vector3" and (pos - st.Target.Position).Magnitude < 0.5 then
					padId = pad.StationId
				end
			end
			if not padId then
				lost = tostring(st and st.Hint)
				break
			end
			path[#path + 1] = padId
			Ty.Buy(p, padId)
			advance(0.5)
		end
		T.check(lost == nil and #path >= 2 and path[#path] == "Kitchen", "p2ui tutorial: following the 'kitchen' arrow from pad to pad builds the Kitchen",
			table.concat(path, " > ") .. (lost and (" (lost at: " .. lost .. ")") or ""))
		T.eq(stepId(p), "feed", "p2ui tutorial: building the Kitchen completes 'kitchen'")
		st = state(p)
		T.check(st and st.Target and st.Target.Kind == "Spot" and tostring(st.Hint):find("Cook", 1, true),
			"p2ui tutorial: without food, 'feed' points at the Kitchen ('Cook a Snack')", st and tostring(st.Hint))
		local okCook = Care.Cook(p, "Snack", 1)
		T.check(okCook == true, "p2ui tutorial: a Snack is ordered at the Kitchen")
		waitFor(function()
			return (DataS.GetFood(p, "Snack") or 0) > 0
		end, 20)
		advance(1.2)
		st = state(p)
		T.check(st and st.Target and st.Target.Kind == "Menu" and st.Target.Id == "Pets", "p2ui tutorial: with food, 'feed' points at the Pets menu button")
		local prof = DataS.GetProfile(p)
		PK.Add(prof, "pebble_pup", 1)
		DataS.MarkDirty(p)
		local cash0 = DataS.GetCash(p)
		local okFeed = Care.Feed(p, "pebble_pup", "Snack")
		advance(0.6)
		T.check(okFeed == true, "p2ui tutorial: the pet is fed")
		st = state(p)
		T.check(st and st.Done == true and st.Completed == true, "p2ui tutorial: feeding a pet ends the home chapter (Done)")
		T.eq(DataS.GetCash(p), cash0 + 1000, "p2ui tutorial: ...and pays the home chapter's Cash reward once")
		T.eq(DataS.GetTutorial(p).Step, #Steps.Steps + 1, "p2ui tutorial: the stored Step is one past the end (a later chapter resumes there)")
		TSv.HandleEvent(p, "Next")
		TSv.HandleEvent(p, "Skip")
		T.eq(DataS.GetCash(p), cash0 + 1000, "p2ui tutorial: nothing is paid twice")
		local userId, name = p.UserId, p.Name
		leave(p)
		advance(1.5)
		p = Mock.AddPlayer(name, userId)
		advance(1.2)
		T.check(state(p) and state(p).Done == true, "p2ui tutorial: the finished chapter stays finished after a rejoin")
		leave(p)

		-- a skipped tutorial never resumes
		local q = join("Skipper")
		DataS.SetTutorial(q, { Step = 1000, Done = true, Gifted = false })
		TSv.Reload(q)
		advance(0.3)
		T.check(state(q) and state(q).Done == true, "p2ui tutorial: a skipped tutorial (Step 1000) does not start the home chapter")
		leave(q)

		-- a new player: the basics' "home" step completes by claiming a plot at its gate
		local n = join("Newbie")
		T.eq(stepId(n), "welcome", "p2ui tutorial: a new player starts at 'welcome'")
		T.eq(TSv.HandleEvent(n, "ShopOpened"), false, "p2ui tutorial: an event of another step is refused")
		TSv.HandleEvent(n, "Next")
		advance(0.3)
		T.eq(stepId(n), "home", "p2ui tutorial: Next -> 'home'")
		st = state(n)
		T.check(st and st.Target and st.Target.Kind == "Spot" and typeof(st.Target.Position) == "Vector3" and type(st.Target.SpotIndex) == "number",
			"p2ui tutorial: 'home' points at a free gate")
		if st and st.Target and st.Target.SpotIndex then
			claim(n, st.Target.SpotIndex)
			waitFor(function()
				return stepId(n) ~= "home"
			end, 3)
		end
		T.eq(stepId(n), "shop", "p2ui tutorial: claiming the plot completes 'home'")
		leave(n)

		local mine = 0
		for i = errors0 + 1, #Mock.Errors do
			if tostring(Mock.Errors[i].msg):find("Tutorial", 1, true) then
				mine = mine + 1
			end
		end
		T.eq(mine, 0, "p2ui tutorial: no script errors from TutorialService")
	end)

	return S
end

----------------------------------------------------------------------------------------------------
-- client half
----------------------------------------------------------------------------------------------------
local function clientScenarios()
	local S = {}
	local KC = _G.KC
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local LocalPlayer = Players.LocalPlayer
	local advance = KC and KC.advance or function(s)
		Mock.Advance(s)
	end

	local function moduleAt(top, rest)
		local inst = Mock.GetPath(ROOTS[top] .. "/" .. rest)
		if not inst then
			return nil
		end
		local ok, result = pcall(require, inst)
		return ok and type(result) == "table" and result or nil
	end

	local function pg()
		return LocalPlayer:FindFirstChildOfClass("PlayerGui")
	end

	local function find(root, name)
		for _, d in ipairs(root and root:GetDescendants() or {}) do
			if d.Name == name then
				return d
			end
		end
		return nil
	end

	local function shown(obj)
		local cur = obj
		while cur and cur ~= game do
			if cur:IsA("LayerCollector") then
				if cur.Enabled == false then
					return false
				end
			elseif cur:IsA("GuiObject") and cur.Visible == false then
				return false
			end
			cur = cur.Parent
		end
		return true
	end

	local function toClient(name, ...)
		Mock.ToClient(ReplicatedStorage:WaitForChild("Remotes"):FindFirstChild(name), ...)
	end

	-- the phone world's first scenario boots the client; run on its own (--only), this one does it
	local function bootIfNeeded()
		if not ReplicatedStorage:FindFirstChild("Remotes") then
			local Config = moduleAt("shared", "Config")
			local folder = Instance.new("Folder")
			folder.Name = "Remotes"
			for _, n in ipairs(Config.Remotes) do
				local r = Instance.new("RemoteEvent")
				r.Name = n
				r.Parent = folder
			end
			folder.Parent = ReplicatedStorage
		end
		if not (pg() and pg():FindFirstChild("NimbusMenu")) then
			Mock.RunScript(Mock.GetPath(ROOTS["client"] .. "/Main"))
			advance(3)
		end
	end

	local function calls(name, mark)
		local out = {}
		for i = (mark or 0) + 1, #Mock.RemoteLog do
			local e = Mock.RemoteLog[i]
			if e.kind == "server" and e.remote == name then
				out[#out + 1] = e
			end
		end
		return out
	end

	local function disabled(button)
		return button == nil or button:GetAttribute("Disabled") == true or button.Active == false
	end

	-- a profile in the middle of the tycoon (or the castle variant ready to prestige)
	local function snapshot(variant)
		local home
		if variant == "castle" then
			home = {
				Level = 41, Prestige = 1,
				Stations = { Press1 = 10, Press2 = 10, Press3 = 8, Press4 = 6, Collector = 5, Garden = 5, Kitchen = 4, Gym = 4, Vault = 4, House = 4, FusionMachine = 1 },
				Garden = { "honey_bunny", "" }, Gym = { "" }, CollectorCash = 500,
			}
		else
			home = {
				Level = 20, Prestige = 1,
				Stations = { Press1 = 5, Press2 = 3, Collector = 3, Garden = 2, Kitchen = 2, Gym = 1, Vault = 1, House = 2, DecorLamps = 1 },
				Garden = { "honey_bunny", "" }, Gym = { "cloudy_dragon" }, CollectorCash = 1840,
			}
		end
		return {
			Tokens = 12450,
			Pets = { pebble_pup = 3, honey_bunny = 1, pip_penguin = 1, mallow_kitten = 1, maple_fox = 1, cloudy_dragon = 1, sleepy_owl = 1 },
			Equipped = { "cloudy_dragon" },
			Items = {},
			Stats = { Matches = 0, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = {} },
			Perks = { MaxHealth = 0, TokenBonus = 0, StaminaRegen = 0, CheckpointHeal = 0 },
			Discovered = { pebble_pup = true, honey_bunny = true, pip_penguin = true },
			IndexClaimed = {},
			Tutorial = { Step = 15, Done = true, Gifted = true },
			Cash = 48250, Gems = 1820,
			Home = home,
			Food = { Snack = 4, Meal = 1 },
			Tiers = { pebble_pup = { Golden = 2 }, maple_fox = { Rainbow = 1 } },
			Hybrids = { hc1 = { Body = "pip_penguin", Style = "maple_fox", Elements = { "Frost", "Flame" }, Name = "Pipfox", Rarity = "Uncommon", Tier = "Normal", Seed = 3 } },
			PetLevels = { ["pebble_pup@Golden"] = { Level = 12, Xp = 300 }, cloudy_dragon = { Level = 18, Xp = 100 } },
		}
	end

	local plot = nil
	local function setHome(variant)
		local Config = moduleAt("shared", "Config")
		local lobby = workspace:FindFirstChild("NimbusLobby")
		if not lobby then
			lobby = Instance.new("Folder")
			lobby.Name = "NimbusLobby"
			lobby.Parent = workspace
		end
		if not plot then
			plot = Instance.new("Folder")
			plot.Name = "Spot_07"
			plot:SetAttribute("SpotIndex", 7)
			plot.Parent = lobby
		end
		plot:SetAttribute("CollectorCash", 1840)
		plot:SetAttribute("CollectorCap", 6000)
		plot:SetAttribute("IncomePerSecond", 38.5)
		LocalPlayer:SetAttribute(Config.Attr.SpotIndex, 7)
		LocalPlayer:SetAttribute(Config.Attr.Cash, 48250)
		LocalPlayer:SetAttribute(Config.Attr.Gems, 1820)
		LocalPlayer:SetAttribute(Config.Attr.InMatch, false)
		toClient("ProfileSync", snapshot(variant))
		advance(0.4)
	end

	-- texts under `root` smaller than `floorPx` design px (TextScaled ones by their UITextSizeConstraint minimum, or
	-- their box height when they have none)
	local function smallTexts(root, floorPx)
		local out = {}
		for _, d in ipairs(root:GetDescendants()) do
			if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and shown(d) then
				local size = d.TextSize
				if d.TextScaled then
					local c = d:FindFirstChildOfClass("UITextSizeConstraint")
					if c then
						size = c.MinTextSize
					else
						local box = Mock.GuiBox(d)
						size = (box and box.scale and box.scale > 0) and (box.h / box.scale) or 0
					end
				end
				if size < floorPx - 0.01 then
					out[#out + 1] = d.Name .. "=" .. tostring(size)
				end
			end
		end
		return out
	end

	-- texts under `root` smaller than `floorPx` ON SCREEN (design size x the cumulative UIScale)
	local function smallOnScreen(root, floorPx)
		local out = {}
		for _, d in ipairs(root:GetDescendants()) do
			if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and shown(d) then
				local box = Mock.GuiBox(d)
				local scale = (box and box.scale) or 1
				local size = d.TextSize
				if d.TextScaled then
					local c = d:FindFirstChildOfClass("UITextSizeConstraint")
					size = c and c.MinTextSize or ((box and scale > 0) and box.h / scale or 0)
				end
				if size * scale < floorPx - 0.05 then
					out[#out + 1] = string.format("%s=%.1f", d.Name, size * scale)
				end
			end
		end
		return out
	end

	S.client_p2ui = guarded("client_p2ui", function()
		local MC = (KC and KC.M and KC.M.MenuController) or moduleAt("client", "Controllers/MenuController")
		local IC = (KC and KC.M and KC.M.IndexController) or moduleAt("client", "Controllers/IndexController")
		local Config = moduleAt("shared", "Config")
		local TC = moduleAt("shared", "TycoonCatalog")
		if not T.check(type(MC) == "table" and type(MC.Open) == "function" and type(MC.GetButton) == "function" and TC ~= nil,
			"p2ui menu: MenuController (Open / GetButton) and TycoonCatalog load") then
			return
		end
		MC.Init()
		if IC and IC.Init then
			IC.Init()
		end
		local errors0 = #Mock.Errors
		local menu = pg():FindFirstChild("NimbusMenu")

		-- the Home tile
		local tile = MC.GetButton("Home")
		local label = tile and tile:FindFirstChild("Label", true)
		T.check(tile ~= nil and tile.Name == "MenuButton_Spot" and label and label.Text == "Home",
			"p2ui menu: the Home tile is MenuButton_Spot labelled 'Home' (GetButton('Home'))")
		LocalPlayer:SetAttribute(Config.Attr.SpotIndex, nil)
		LocalPlayer:SetAttribute(Config.Attr.InMatch, false)
		advance(0.2)
		local mark = #Mock.RemoteLog
		Mock.Click(tile)
		advance(0.3)
		local hint = menu and menu:FindFirstChild("MenuHint")
		T.check(#calls("GoToSpot", mark) == 1 and hint and hint.Visible and tostring(find(hint, "Text") and find(hint, "Text").Text):find("Press E", 1, true),
			"p2ui menu: without a home the Home tile walks to a free gate (GoToSpot) with a side hint 'Press E at the gate'")
		local win = menu and menu:FindFirstChild("Window_Home")
		T.check(win == nil or not win.Visible, "p2ui menu: ...and opens no window")

		-- the Home window
		setHome("mid")
		local opened = {}
		local conn = MC.WindowOpened:Connect(function(id)
			opened[#opened + 1] = id
		end)
		Mock.Click(tile)
		advance(0.6)
		win = menu:FindFirstChild("Window_Home")
		T.check(win and win.Visible and table.concat(opened, ",") == "Home", "p2ui menu: with a claimed home the tile opens the Home window (WindowOpened 'Home')", table.concat(opened, ","))
		conn:Disconnect()
		local missing = {}
		for _, def in ipairs(TC.Stations) do
			if not find(win, "Station_" .. def.Id) then
				missing[#missing + 1] = def.Id
			end
		end
		T.check(#missing == 0, "p2ui menu: the Home window lists every station of TycoonCatalog", table.concat(missing, ", "))
		local houseName = find(win, "Tier")
		local homeLevel = find(win, "HomeLevel")
		T.check(houseName and houseName.Text == "Villa" and homeLevel and homeLevel.Text == "Home Level 20",
			"p2ui menu: the house tier and the Home Level show", (houseName and houseName.Text or "?") .. " / " .. (homeLevel and homeLevel.Text or "?"))
		local income = find(win, "PerSecond")
		local bar = find(win, "CollectorBar")
		T.check(income and income.Text:find("38.5", 1, true) and bar and find(bar, "Text") and find(bar, "Text").Text:find("1,840", 1, true),
			"p2ui menu: income per second and the Collector's cash come from the plot folder", (income and income.Text or "?"))
		plot:SetAttribute("CollectorCash", 2500)
		advance(0.5)
		T.check(bar and find(bar, "Text") and find(bar, "Text").Text:find("2,500", 1, true), "p2ui menu: ...and follow its live attributes",
			bar and find(bar, "Text") and find(bar, "Text").Text or "")
		local mult = find(win, "Multiplier")
		T.check(mult and mult.Visible and mult.Text == "x1.25", "p2ui menu: the prestige multiplier tag shows x1.25 for one star")
		-- Upgrade / Build / locks
		local press1 = find(win, "Station_Press1")
		local upgrade = press1 and find(press1, "Upgrade")
		mark = #Mock.RemoteLog
		T.check(upgrade and upgrade.Visible and not disabled(upgrade), "p2ui menu: an affordable upgrade is enabled")
		if upgrade then
			Mock.Click(upgrade)
			advance(0.2)
		end
		local hc = calls("HomeAction", mark)
		T.check(#hc == 1 and hc[1].args[1] == "Upgrade" and hc[1].args[2] == "Press1", "p2ui menu: Upgrade sends HomeAction('Upgrade', stationId)")
		local press4 = find(win, "Station_Press4")
		local lock = press4 and find(press4, "Locked")
		T.check(lock and lock.Visible and lock.Text:find("Needs", 1, true) and not (find(press4, "Upgrade") and find(press4, "Upgrade").Visible),
			"p2ui menu: a locked station shows why instead of a button", lock and lock.Text or "")
		local vault = find(win, "Station_Vault")
		local vaultButton = vault and find(vault, "Upgrade")
		T.check(vaultButton and disabled(vaultButton), "p2ui menu: an upgrade the player cannot afford is disabled")
		mark = #Mock.RemoteLog
		local collect = find(win, "Collect")
		if collect then
			Mock.Click(collect)
			advance(0.2)
		end
		hc = calls("HomeAction", mark)
		T.check(#hc == 1 and hc[1].args[1] == "Collect", "p2ui menu: Collect sends HomeAction('Collect')")
		local prestige = find(win, "Prestige")
		T.check(prestige and disabled(prestige), "p2ui menu: Prestige is disabled before Home Level 40 + the Sky Castle")
		-- castle: the confirmed prestige
		setHome("castle")
		advance(0.3)
		T.check(prestige and not disabled(prestige), "p2ui menu: Prestige is enabled once the home is ready")
		Mock.Click(prestige)
		advance(0.3)
		local confirm = find(win, "PrestigeConfirm")
		local gain = confirm and find(confirm, "Line_Gain")
		T.check(confirm and confirm.Visible and gain and find(gain, "Text").Text:find("Star 2", 1, true), "p2ui menu: Prestige asks first (what resets, what stays, star 2)")
		mark = #Mock.RemoteLog
		Mock.Click(find(confirm, "ConfirmPrestige"))
		advance(0.2)
		hc = calls("HomeAction", mark)
		T.check(#hc == 1 and hc[1].args[1] == "Prestige" and not confirm.Visible, "p2ui menu: confirming sends HomeAction('Prestige')")
		-- Go home (in the title bar)
		setHome("mid")
		mark = #Mock.RemoteLog
		Mock.Click(find(win, "GoHome"))
		advance(0.4)
		hc = calls("HomeAction", mark)
		T.check(#hc == 1 and hc[1].args[1] == "GoHome" and not MC.IsOpen(), "p2ui menu: Go home sends HomeAction('GoHome') and closes the window")
		MC.Open("Home")
		advance(0.5)
		local small = smallTexts(win, 18)
		T.check(#small == 0, "p2ui menu: every text of the Home window is >= 18 design px", table.concat(small, ", "))

		-- Pets panel
		MC.Open("Pets", { Key = "pebble_pup@Golden" })
		advance(0.8)
		local inv = menu:FindFirstChild("Window_Inventory")
		local goldSlot = find(inv, "Pet_pebble_pup@Golden")
		local hybSlot = find(inv, "Pet_hyb:hc1")
		local rainbow = find(inv, "Pet_maple_fox@Rainbow")
		local function chipText(slot)
			local chip = slot and find(slot, "TierBadge")
			return chip and chip.Visible and find(chip, "Mark") and find(chip, "Mark").Text or ""
		end
		T.check(chipText(goldSlot) == "G" and chipText(hybSlot) == "H" and chipText(rainbow) == "R",
			"p2ui pets: one slot per copy key with tier / hybrid chips (G, R, H)")
		local levelTag = goldSlot and find(goldSlot, "LevelTag")
		T.check(levelTag and levelTag.Visible and levelTag.Text == "Lv 12", "p2ui pets: the slot shows the copy's level")
		local nameLabel = find(inv, "Detail") and find(find(inv, "Detail"), "Name")
		T.check(nameLabel and nameLabel.Text == "Golden Pebble Pup", "p2ui pets: the detail card shows the selected copy", nameLabel and nameLabel.Text or "")
		local tierPill = find(inv, "Tier_Golden")
		local xpBar = find(find(inv, "Detail"), "XpBar")
		T.check(tierPill ~= nil and xpBar ~= nil and find(xpBar, "Text") and find(xpBar, "Text").Text:find("300", 1, true),
			"p2ui pets: the tier pill and the XP bar (300 / next) show")
		local PC = moduleAt("shared", "PetCatalog")
		local stats = PC and PC.GetStats and PC.GetStats("pebble_pup", 12, "Golden")
		local incomePill = find(inv, "Stat_Income")
		local want = stats and string.format("%.1f", floor(stats.Income * 10 + 0.5) / 10) or "?"
		want = (want:gsub("%.0$", ""))
		T.check(stats and incomePill and incomePill.Text:find("$" .. want, 1, true),
			"p2ui pets: stats are scaled by rarity, level and tier (PetCatalog.GetStats)", (incomePill and incomePill.Text or "") .. " want $" .. want)
		-- the Feed picker
		mark = #Mock.RemoteLog
		Mock.Click(find(inv, "FeedPet"))
		advance(0.4)
		local picker = find(inv, "FeedPicker")
		T.check(picker and picker.Visible, "p2ui pets: Feed opens the food picker")
		local snackRow = picker and find(picker, "Food_Snack")
		Mock.Click(snackRow and find(snackRow, "Feed"))
		advance(0.4)
		Mock.Click(snackRow and find(snackRow, "Cook"))
		advance(0.2)
		local pc = calls("PetCare", mark)
		T.check(#pc == 2 and pc[1].args[1] == "Feed" and pc[1].args[2] == "pebble_pup@Golden" and pc[1].args[3] == "Snack"
			and pc[2].args[1] == "Cook" and pc[2].args[2] == "Snack", "p2ui pets: Feed / Cook in the picker send PetCare('Feed', key, food) / PetCare('Cook', food, 1)")
		small = smallTexts(picker, 18)
		T.check(#small == 0, "p2ui pets: every text of the Feed picker is >= 18 design px", table.concat(small, ", "))
		Mock.Click(find(picker, "CloseFeed"))
		advance(0.3)
		T.check(not picker.Visible, "p2ui pets: Done closes the picker")
		-- Garden / Gym
		local work = find(inv, "WorkPet")
		MC.Open("Pets", { Key = "honey_bunny" })
		advance(0.3)
		mark = #Mock.RemoteLog
		T.check(work and work.Text == "Leave Garden", "p2ui pets: a pet working in the Garden offers 'Leave Garden'", work and work.Text or "")
		Mock.Click(work)
		advance(0.3)
		hc = calls("HomeAction", mark)
		T.check(#hc == 1 and hc[1].args[1] == "GardenSet" and type(hc[1].args[2]) == "table" and hc[1].args[2].Slot == 1 and hc[1].args[2].Key == nil,
			"p2ui pets: ...which clears its slot (HomeAction GardenSet {Slot = 1})")
		MC.Open("Pets", { Key = "pebble_pup" })
		advance(0.3)
		mark = #Mock.RemoteLog
		T.check(work.Text == "Place in Garden" and not disabled(work), "p2ui pets: an Economy pet offers 'Place in Garden'")
		Mock.Click(work)
		advance(0.3)
		hc = calls("HomeAction", mark)
		T.check(#hc == 1 and hc[1].args[1] == "GardenSet" and hc[1].args[2].Slot == 2 and hc[1].args[2].Key == "pebble_pup",
			"p2ui pets: ...into the first free slot (GardenSet {Slot = 2, Key})")
		MC.Open("Pets", { Key = "mallow_kitten" })
		advance(0.3)
		T.check(work.Text == "Train in Gym" and disabled(work), "p2ui pets: a Combat pet offers 'Train in Gym' (disabled while the Gym is full)")
		toClient("ProfileSync", (function()
			local s = snapshot("mid")
			s.Home.Gym = { "" }
			return s
		end)())
		advance(0.4)
		mark = #Mock.RemoteLog
		Mock.Click(work)
		advance(0.3)
		pc = calls("PetCare", mark)
		T.check(#pc == 1 and pc[1].args[1] == "GymSet" and pc[1].args[3] == "mallow_kitten", "p2ui pets: Train in Gym sends PetCare('GymSet', slot, key)")
		small = smallTexts(inv, 18)
		T.check(#small == 0, "p2ui pets: every text of the Pets page is >= 18 design px", table.concat(small, ", "))

		-- Shop Gems tab
		LocalPlayer:SetAttribute("PaidRandomItemsRestricted", false)
		MC.Open("Shop", { Tab = "Gems" })
		advance(0.6)
		local shop = menu:FindFirstChild("Window_Shop")
		local page = find(shop, "Page_Gems")
		local secret = page and find(page, "GemRoulette_Secret")
		T.check(page and page.Visible and secret and secret.Visible, "p2ui shop: OpenPanel('Shop', {Tab = 'Gems'}) shows the Gems tab with the Secret roulette")
		local chances = secret and find(secret, "Chances")
		local mythic = chances and find(chances, "Chance_Mythic")
		local secretChance = chances and find(chances, "Chance_Secret")
		T.check(mythic and secretChance and mythic.Text:find("85%", 1, true) and secretChance.Text:find("15%", 1, true),
			"p2ui shop: the Secret roulette shows its odds (Mythic 85%, Secret 15%)")
		mark = #Mock.RemoteLog
		Mock.Click(find(secret, "Spin"))
		advance(0.3)
		local br = calls("BuyRoulette", mark)
		T.check(#br == 1 and br[1].args[1] == "Secret" and br[1].args[2] == "Gems", "p2ui shop: a gem spin sends BuyRoulette('Secret', 'Gems')")
		toClient("RouletteResult", { Ok = false, Reason = "test" })
		advance(0.3)
		local cloudGem = find(page, "GemRoulette_Cloud")
		T.check(cloudGem ~= nil, "p2ui shop: token roulettes with a gem price are offered for Gems too")
		LocalPlayer:SetAttribute("PaidRandomItemsRestricted", true)
		advance(0.3)
		local notice = find(page, "GemNotice")
		T.check(not secret.Visible and notice and notice.Visible, "p2ui shop: where paid random items are restricted the gem roulettes hide behind a notice")
		LocalPlayer:SetAttribute("PaidRandomItemsRestricted", false)
		advance(0.2)
		small = smallTexts(page, 18)
		T.check(#small == 0, "p2ui shop: every text of the Gems tab is >= 18 design px", table.concat(small, ", "))
		MC.Close()
		advance(0.3)
		MC.Open("Shop", { RouletteId = "Secret" })
		advance(0.5)
		T.check(page.Visible, "p2ui shop: OpenPanel('Shop', {RouletteId = 'Secret'}) (the Storm Altar) opens the Gems tab")
		MC.Close()
		advance(0.3)

		-- Index Fusions tab
		if T.check(IC ~= nil and type(IC.Open) == "function", "p2ui index: IndexController loads") then
			local claimable = IC.ClaimableCount()
			IC.Open("Fusions")
			advance(0.6)
			local index = pg():FindFirstChild("NimbusIndex")
			local tileF = index and find(index, "Group_Fusions")
			local grid = index and find(index, "PetGrid")
			local keys = {}
			for _, d in ipairs(grid and grid:GetChildren() or {}) do
				local key = d.Name:match("^IndexPet_(.+)$")
				if key then
					keys[#keys + 1] = key
				end
			end
			table.sort(keys)
			T.check(tileF ~= nil and table.concat(keys, ",") == "hyb:hc1,maple_fox@Rainbow,pebble_pup@Golden",
				"p2ui index: Open('Fusions') lists the fused copies (hybrids, Golden, Rainbow)", table.concat(keys, ","))
			local title = index and find(index, "GroupTitle")
			T.check(title and title.Text:find("Fusions", 1, true), "p2ui index: ...under a 'Fusions' header")
			T.eq(IC.ClaimableCount(), claimable, "p2ui index: fusions are not part of the group rewards")
			local claimButton = index and find(index, "Claim")
			T.check(claimButton and not disabled(claimButton) and claimButton.Text ~= "CLAIM", "p2ui index: the rewards box leads to the Fusion Machine / the Home window instead of a claim")
			small = smallTexts(index, 18)
			T.check(#small == 0, "p2ui index: every text of the Index is >= 18 design px", table.concat(small, ", "))
			IC.Close()
			advance(0.3)
		end

		-- clean up for the scenarios after this one
		MC.Close()
		LocalPlayer:SetAttribute(Config.Attr.SpotIndex, nil)
		LocalPlayer:SetAttribute("PaidRandomItemsRestricted", nil)
		if plot then
			plot:Destroy()
			plot = nil
		end
		advance(0.3)
		local mine = {}
		for i = errors0 + 1, #Mock.Errors do
			local msg = tostring(Mock.Errors[i].msg)
			if msg:find("MenuController", 1, true) or msg:find("IndexController", 1, true) then
				mine[#mine + 1] = msg:sub(1, 160)
			end
		end
		T.check(#mine == 0, "p2ui: no script errors from MenuController / IndexController", table.concat(mine, " | "))
		if KC and KC.flushErrors then
			KC.flushErrors("client_p2ui")
		end
	end)

	S.client_p2ui_mobile = guarded("client_p2ui_mobile", function()
		local MC = moduleAt("client", "Controllers/MenuController")
		local IC = moduleAt("client", "Controllers/IndexController")
		if not T.check(type(MC) == "table" and type(MC.Open) == "function", "p2ui phone: MenuController loads") then
			return
		end
		bootIfNeeded()
		MC.Init()
		if IC and IC.Init then
			IC.Init()
		end
		setHome("mid")
		local menu = pg():FindFirstChild("NimbusMenu")
		local function check(label, root)
			local small = smallOnScreen(root, 14)
			T.check(#small == 0, "p2ui phone 390x844: every text of " .. label .. " is >= 14 px on screen", table.concat(small, ", "))
		end
		MC.Open("Home")
		advance(0.8)
		check("the Home window", menu:FindFirstChild("Window_Home"))
		MC.Open("Pets", { Key = "pebble_pup@Golden" })
		advance(0.8)
		check("the Pets page", menu:FindFirstChild("Window_Inventory"))
		MC.Open("Feed", { Key = "pebble_pup@Golden" })
		advance(0.8)
		check("the Feed picker", menu:FindFirstChild("Window_Inventory"))
		LocalPlayer:SetAttribute("PaidRandomItemsRestricted", false)
		MC.Open("Shop", { Tab = "Gems" })
		advance(0.8)
		check("the Gems tab", menu:FindFirstChild("Window_Shop"))
		MC.Close()
		advance(0.3)
		if IC and IC.Open then
			IC.Open("Fusions")
			advance(0.8)
			check("the Index (Fusions)", pg():FindFirstChild("NimbusIndex"))
			IC.Open("Common")
			advance(0.8)
			check("the Index (Common)", pg():FindFirstChild("NimbusIndex"))
			IC.Close()
		end
		MC.Close()
		LocalPlayer:SetAttribute("SpotIndex", nil)
		LocalPlayer:SetAttribute("PaidRandomItemsRestricted", nil)
		if plot then
			plot:Destroy()
			plot = nil
		end
		advance(0.3)
	end)

	return S
end

if CONTEXT == "server" then
	return serverScenarios()
end
return clientScenarios()
