-- smoke_release_client.lua: regression checks for the release-quality review of the client (v3 Phase 1 release pass).
-- tools/smoke.py runs (client world after smoke_client.lua / smoke_client_v2.lua, whose helpers it uses through KC):
--   client_release_pets         PetController in a busy lobby (6 players x 3 pets): every pet's static parts are welded
--                               to its anchored PrimaryPart (a pose is ONE root CFrame write, no PivotTo), only the
--                               wing / tail parts stay anchored for PetBuilder.Animate, no part changes its CFrame
--                               twice in a frame, welded parts follow the root, a pet whose Animate keeps failing gets
--                               its animated parts welded too (nothing trails behind), and pet models are built under
--                               a time budget (expensive first-time sculpts: one per frame)
--   client_release_roulette     MenuController: opening the Shop pre-sculpts the cheapest roulette's pets at the strip's
--                               Low detail (a few per frame), the spin strip's cells use Low detail and attach their
--                               viewports under the time budget (never 8 sculpts in the RouletteResult frame), the reveal
--                               card stays High, the odds popup uses Low tiles, and the odds / Inventory / Index loops
--                               build at most one expensive pet per frame (at most K.BUILD_MAX cheap clones)
--   client_release_touch_mobile (phone world, touch) the menu column never covers Roblox's thumbstick (844x390,
--                               667x375, 740x360, 932x430, 1024x768, 1180x820, 1366x1024) and keeps readable labels;
--                               the tutorial bubble / card never covers the HP + stamina card during the portal wait and
--                               the climb (an opened card is folded back when the match starts), never runs off the
--                               screen or over the hotbar; the menu pointer arrow never sits on a neighbouring tile or
--                               on the tutorial card, and the ring + arrow hide (and the card folds) while a window is open
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local fmt = string.format
local abs, max, min = math.abs, math.max, math.min

local S = {}

local function KC()
	return _G.KC
end

local function advance(seconds)
	Mock.Advance(seconds)
end

local function req(rel)
	return require(Mock.GetPath(ROOTS["shared"] .. "/" .. rel))
end

local function reqClient(rel)
	return require(Mock.GetPath(ROOTS["client"] .. "/" .. rel))
end

local function playerGui()
	return LocalPlayer:FindFirstChild("PlayerGui")
end

local function path(root, dotted)
	local cur = root
	for part in string.gmatch(dotted, "[^%.]+") do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(part)
	end
	return cur
end

local function shown(obj)
	return obj ~= nil and KC().isShown(obj)
end

-- a GuiObject's box in SCREEN pixels (the top bar inset added for IgnoreGuiInset = false guis)
local function screenRect(inst)
	local g = inst:FindFirstAncestorOfClass("ScreenGui")
	local dy = (g and not g.IgnoreGuiInset) and (Mock.TopInset or 0) or 0
	local p, s = inst.AbsolutePosition, inst.AbsoluteSize
	return { x0 = p.X, y0 = p.Y + dy, x1 = p.X + s.X, y1 = p.Y + s.Y + dy }
end

local function overlap(a, b)
	return a.x0 < b.x1 - 0.5 and a.x1 > b.x0 + 0.5 and a.y0 < b.y1 - 0.5 and a.y1 > b.y0 + 0.5
end

local function show(r)
	return fmt("x %.0f..%.0f y %.0f..%.0f", r.x0, r.x1, r.y0, r.y1)
end

-- Counts PetBuilder.Build calls per mock frame while `fn` runs. costly = seconds every call adds to os.clock()
-- (a first-time sculpt), so the game's time budgets see expensive builds. Returns { Total, MaxPerFrame, Calls }.
local function measureBuilds(costly, fn)
	local PetBuilder = req("PetBuilder")
	local realBuild = PetBuilder.Build
	local mockClock = os.clock
	local extra = 0
	local perFrame, calls = {}, {}
	PetBuilder.Build = function(def, opts)
		extra = extra + (costly or 0)
		local frame = Mock.Clock.frame
		perFrame[frame] = (perFrame[frame] or 0) + 1
		calls[#calls + 1] = { Id = type(def) == "table" and def.Id or tostring(def), Detail = type(opts) == "table" and opts.Detail or nil, Frame = frame }
		return realBuild(def, opts)
	end
	if costly and costly > 0 then
		os.clock = function()
			return mockClock() + extra
		end
	end
	local ok, err = pcall(fn)
	PetBuilder.Build = realBuild
	os.clock = mockClock
	if not ok then
		error(err, 0)
	end
	local total, most = 0, 0
	for _, n in pairs(perFrame) do
		total = total + n
		most = max(most, n)
	end
	return { Total = total, MaxPerFrame = most, Calls = calls }
end

-- the PetBuilder models shown inside ViewportFrames under `root`
local function viewportModels(root)
	local out = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Model") and d:GetAttribute("PB_Detail") ~= nil and d:FindFirstAncestorOfClass("ViewportFrame") then
			out[#out + 1] = d
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- PetController: welded rigs, one write per part per frame, Animate fallback, build time budget
----------------------------------------------------------------------------------------------------
-- PetBuilder.Animate re-poses these: a PB_G group (not the "lid" eyelids) with a PB_Base pose
local function isAnimatedPart(part)
	local spec = part:GetAttribute("PB_G")
	if type(spec) ~= "string" or type(part:GetAttribute("PB_Base")) ~= "string" then
		return false
	end
	return string.match(spec, "^[^:]*:([^:]*)") ~= "lid"
end

local function weldOf(part, root)
	local w = part:FindFirstChild("PetFollowWeld")
	if w and w:IsA("Weld") and w.Part0 == root and w.Part1 == part then
		return w
	end
	return nil
end

local function petModels()
	local folder = workspace:FindFirstChild("ClientPets")
	local out = {}
	for _, d in ipairs(folder and folder:GetDescendants() or {}) do
		if d:IsA("Model") and d.PrimaryPart then
			out[#out + 1] = d
		end
	end
	return out
end

S.client_release_pets = guarded("client_release_pets", function()
	local PC = KC().M.PetController
	local PetBuilder = req("PetBuilder")
	if not T.check(PC ~= nil, "release pets: PetController loaded") then
		return
	end
	T.check(type(PC.GetMoveStats) == "function", "release pets: PetController.GetMoveStats exists")
	local trio = "cloudy_dragon,biscuit_bear,pebble_pup"
	Mock.Teleport(LocalPlayer, Vector3.new(0, 40, 0))
	LocalPlayer:SetAttribute("EquippedPets", "")
	advance(0.5)

	-- 1. build time budget: expensive first-time sculpts are built one per frame, cheap clones a few per frame
	local others = {}
	local costly = measureBuilds(0.03, function()
		LocalPlayer:SetAttribute("EquippedPets", trio)
		local p = Mock.AddPlayer("Budget1", 8101)
		others[#others + 1] = p
		advance(0.6)
		Mock.Teleport(p, Mock.GetRoot(LocalPlayer).Position + Vector3.new(30, 0, 0))
		p:SetAttribute("EquippedPets", trio)
		advance(1.5)
	end)
	T.check(costly.Total >= 6 and costly.MaxPerFrame == 1, "release pets: expensive pet builds run one per frame (time budget, not a fixed count)",
		fmt("%d builds, at most %d in one frame", costly.Total, costly.MaxPerFrame))
	for _, p in ipairs(others) do
		p:SetAttribute("EquippedPets", "")
	end
	LocalPlayer:SetAttribute("EquippedPets", "")
	advance(0.6)
	local cheap = measureBuilds(0, function()
		LocalPlayer:SetAttribute("EquippedPets", trio)
		others[1]:SetAttribute("EquippedPets", trio)
		advance(1.0)
	end)
	T.check(cheap.Total >= 6 and cheap.MaxPerFrame > 1 and cheap.MaxPerFrame <= 3, "release pets: cached clones are built a few per frame (at most 3)",
		fmt("%d builds, at most %d in one frame", cheap.Total, cheap.MaxPerFrame))

	-- 2. a busy lobby: 6 players with 3 pets each, 30 studs around the viewer (inside the every-frame LOD ring)
	for i = 2, 5 do
		others[i] = Mock.AddPlayer("Lobby" .. i, 8100 + i)
	end
	advance(0.8)
	local centre = Mock.GetRoot(LocalPlayer).Position
	for i, p in ipairs(others) do
		local a = i / #others * math.pi * 2
		Mock.Teleport(p, centre + Vector3.new(math.cos(a) * 30, 0, math.sin(a) * 30))
		p:SetAttribute("EquippedPets", trio)
	end
	advance(3)
	local models = petModels()
	T.check(#models == 3 * (#others + 1), "release pets: 6 players x 3 pets are drawn", #models .. " models")

	-- structure: anchored root, static parts welded to it, animated parts anchored for Animate
	local bad, statics, animated, parts = {}, 0, 0, 0
	for _, m in ipairs(models) do
		local root = m.PrimaryPart
		if not root.Anchored then
			bad[#bad + 1] = m.Name .. ": root not anchored"
		end
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") and d ~= root then
				parts = parts + 1
				if isAnimatedPart(d) then
					animated = animated + 1
					if not d.Anchored or weldOf(d, root) then
						bad[#bad + 1] = m.Name .. "." .. d.Name .. " (animated) is welded"
					end
				else
					statics = statics + 1
					if d.Anchored or not weldOf(d, root) then
						bad[#bad + 1] = m.Name .. "." .. d.Name .. " (static) is not welded to the root"
					end
				end
			end
		end
	end
	T.check(#bad == 0 and statics > 0 and animated > 0, "release pets: static parts are welded to the anchored PrimaryPart, only the animated parts stay anchored",
		fmt("%d static, %d animated; %s", statics, animated, table.concat(bad, "; ", 1, min(#bad, 4))))

	-- per frame: one root write per pet (no PivotTo) and no part written twice
	advance(0.2)
	local stats = type(PC.GetMoveStats) == "function" and PC.GetMoveStats() or { Rigid = 0, Pivot = -1 }
	T.check(stats.Pivot == 0 and stats.Rigid == #models, "release pets: every pet is posed by one root CFrame write (no PivotTo)", fmt("rigid %d, pivot %d, models %d", stats.Rigid, stats.Pivot, #models))
	local counts, conns = {}, {}
	for _, m in ipairs(models) do
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") then
				conns[#conns + 1] = d:GetPropertyChangedSignal("CFrame"):Connect(function()
					local key = d
					local frame = Mock.Clock.frame
					local rec = counts[key]
					if not rec or rec.Frame ~= frame then
						rec = { Frame = frame, N = 0, Max = rec and rec.Max or 0 }
						counts[key] = rec
					end
					rec.N = rec.N + 1
					if rec.N > rec.Max then
						rec.Max = rec.N
					end
				end)
			end
		end
	end
	advance(0.5)
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	local twice, seen = 0, 0
	for _, rec in pairs(counts) do
		seen = seen + 1
		if rec.Max > 1 then
			twice = twice + 1
		end
	end
	T.check(seen > 0 and twice == 0, "release pets: no pet part changes its CFrame twice in one frame (PivotTo + Animate wrote ~1,300 parts twice)",
		fmt("%d parts moved, %d written twice in a frame", seen, twice))

	-- welded parts follow the root
	local drift = 0
	for _, m in ipairs(models) do
		local root = m.PrimaryPart
		for _, d in ipairs(m:GetDescendants()) do
			local w = d:IsA("BasePart") and weldOf(d, root)
			if w then
				drift = max(drift, ((root.CFrame * w.C0).Position - d.Position).Magnitude)
			end
		end
	end
	T.check(drift < 0.01, "release pets: welded parts follow the moving root", fmt("largest offset error %.4f studs", drift))

	-- Animate keeps failing: after 3 failures the animated parts are welded in place and follow the root too
	local realAnimate = PetBuilder.Animate
	PetBuilder.Animate = function()
		error("smoke: Animate broken on purpose", 0)
	end
	local okRun, err = pcall(advance, 0.5)
	PetBuilder.Animate = realAnimate
	if not okRun then
		error(err, 0)
	end
	local mine = {}
	for _, m in ipairs(petModels()) do
		if m.Parent and m.Parent.Name == tostring(LocalPlayer.UserId) then
			mine[#mine + 1] = m
		end
	end
	local loose, offsets = 0, {}
	for _, m in ipairs(mine) do
		local root = m.PrimaryPart
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") and d ~= root then
				if d.Anchored then
					loose = loose + 1
				end
				if isAnimatedPart(d) then
					offsets[#offsets + 1] = { Part = d, Root = root, Off = root.CFrame:ToObjectSpace(d.CFrame) }
				end
			end
		end
	end
	T.check(#mine == 3 and loose == 0, "release pets: when Animate keeps failing the animated parts are welded too", fmt("%d own pets, %d parts still anchored", #mine, loose))
	Mock.Teleport(LocalPlayer, Mock.GetRoot(LocalPlayer).Position + Vector3.new(12, 0, 6))
	advance(1.0)
	local worst = 0
	for _, o in ipairs(offsets) do
		local now = o.Root.CFrame:ToObjectSpace(o.Part.CFrame)
		worst = max(worst, (now.Position - o.Off.Position).Magnitude)
	end
	T.check(#offsets > 0 and worst < 0.01, "release pets: ...and keep their place on the pet while it flies (nothing trails behind)", fmt("%d parts, worst drift %.4f studs", #offsets, worst))

	-- clean up: rebuild healthy pets, remove the extra players
	LocalPlayer:SetAttribute("EquippedPets", "")
	for _, p in ipairs(others) do
		Mock.RemovePlayer(p)
	end
	advance(1.0)
	T.eq(PC.GetPetCount(), 0, "release pets: clean-up leaves no follower")
	KC().flushErrors("release pets")
	KC().flushWarnings("release pets")
end)

----------------------------------------------------------------------------------------------------
-- MenuController: roulette pre-sculpting, Low strip cells, time-budgeted viewport loops
----------------------------------------------------------------------------------------------------
local function resetMenus()
	pcall(KC().toClient, "OpenPanel", "close", nil)
	local MC = KC().M.MenuController
	if MC and MC.Close then
		pcall(MC.Close)
	end
	local IC = KC().M.IndexController
	if IC and IC.Close then
		pcall(IC.Close)
	end
	advance(0.8)
end

S.client_release_roulette = guarded("client_release_roulette", function()
	local Config = KC().env()
	local MC = KC().M.MenuController
	local PetCatalog = req("PetCatalog")
	local budget = CONTRACT.v3 and CONTRACT.v3.partBudget or { petLow = 120 }
	if not T.check(MC ~= nil, "release roulette: MenuController loaded") then
		return
	end
	T.check(type(MC.IsPrewarmed) == "function" and type(MC.IsOpen) == "function", "release roulette: MenuController.IsPrewarmed / IsOpen exist")
	local function isOpen()
		if type(MC.IsOpen) ~= "function" then
			return nil
		end
		return MC.IsOpen()
	end
	resetMenus()
	LocalPlayer:SetAttribute("InMatch", false)
	LocalPlayer:SetAttribute("CloudTokens", 5000)
	advance(0.3)

	-- 1. opening the Shop pre-sculpts the cheapest roulette's pets at Low, a few per frame
	local cheapest = Config.Roulettes[1].Id
	local pool = PetCatalog.PossiblePets(cheapest)
	local warm = measureBuilds(0, function()
		KC().toClient("OpenPanel", "Shop", nil)
		advance(3)
	end)
	local missing = {}
	for _, def in ipairs(pool) do
		if not (type(MC.IsPrewarmed) == "function" and MC.IsPrewarmed(def.Id)) then
			missing[#missing + 1] = def.Id
		end
	end
	T.check(#pool > 0 and #missing == 0, "release roulette: opening the Shop pre-sculpts every pet of the " .. cheapest .. " roulette",
		#missing .. " of " .. #pool .. " missing: " .. table.concat(missing, ", ", 1, min(#missing, 5)))
	local notLow = 0
	for _, c in ipairs(warm.Calls) do
		if c.Detail ~= "Low" then
			notLow = notLow + 1
		end
	end
	T.check(warm.MaxPerFrame <= 3 and notLow == 0, "release roulette: ...at the strip's Low detail, a few per frame (at most 3)",
		fmt("%d builds (%d not Low), at most %d in a frame", warm.Total, notLow, warm.MaxPerFrame))

	-- 2. the odds popup: Low tiles, one expensive build per frame
	local shop = path(playerGui(), "NimbusMenu.Window_Shop")
	local card = shop and shop:FindFirstChild("Roulette_" .. cheapest, true)
	local oddsButton = card and card:FindFirstChild("Odds", true)
	if T.check(oddsButton ~= nil and oddsButton:IsA("GuiButton"), "release roulette: the " .. cheapest .. " card has an Odds button") then
		local odds = measureBuilds(0.03, function()
			Mock.Click(oddsButton)
			advance(2.5)
		end)
		T.check(odds.Total > 0 and odds.MaxPerFrame == 1, "release roulette: the odds popup builds one expensive pet per frame",
			fmt("%d builds, at most %d in a frame", odds.Total, odds.MaxPerFrame))
		local menu = path(playerGui(), "NimbusMenu")
		local highs, lows = 0, 0
		for _, m in ipairs(viewportModels(menu)) do
			if m:FindFirstAncestor("OddsPanel") then
				if m:GetAttribute("PB_Detail") == "Low" then
					lows = lows + 1
				else
					highs = highs + 1
				end
			end
		end
		T.check(lows > 0 and highs == 0, "release roulette: the odds tiles use PetBuilder's Low detail", fmt("%d Low, %d High", lows, highs))
		T.check(isOpen() == true, "release roulette: MenuController.IsOpen() is true while the odds popup is up")
	end
	resetMenus()
	local stillOpen = {}
	for _, c in ipairs(path(playerGui(), "NimbusMenu"):GetChildren()) do
		if c:IsA("GuiObject") and c.Visible and (c.Name:find("^Window_") or c.Name == "OddsPopup" or c.Name == "RouletteStage") then
			stillOpen[#stillOpen + 1] = c.Name
		end
	end
	T.check(isOpen() == false, "release roulette: ...and false once everything is closed", table.concat(stillOpen, ", "))

	-- 3. the spin: Low strip cells attached under the budget, the reveal card High
	local strip = {}
	for i = 1, 42 do
		strip[i] = pool[(i * 7) % #pool + 1].Id
	end
	local winner = pool[1].Id
	strip[34] = winner
	local spin = measureBuilds(0.03, function()
		KC().toClient("RouletteResult", { Ok = true, RouletteId = cheapest, PetId = winner, IsNew = false, Count = 2, Tokens = 4950, Strip = strip })
		advance(1.0)
	end)
	T.check(spin.Total > 0 and spin.MaxPerFrame == 1, "release roulette: the spin strip attaches one expensive pet viewport per frame (was 8 in the RouletteResult frame)",
		fmt("%d builds, at most %d in a frame", spin.Total, spin.MaxPerFrame))
	local stage = path(playerGui(), "NimbusMenu.RouletteStage")
	local cellModels, lowCells = 0, 0
	if T.check(stage ~= nil, "release roulette: the roulette stage is up") then
		for _, m in ipairs(viewportModels(stage)) do
			if m:FindFirstAncestor("StripClip") then
				cellModels = cellModels + 1
				local parts = Mock.CountDescendants(m, "BasePart")
				if m:GetAttribute("PB_Detail") == "Low" and parts <= budget.petLow then
					lowCells = lowCells + 1
				end
			end
		end
		T.check(cellModels > 0 and lowCells == cellModels, "release roulette: the strip cells use Low detail (<= " .. budget.petLow .. " parts)", fmt("%d of %d cells", lowCells, cellModels))
		T.check(isOpen() == true, "release roulette: MenuController.IsOpen() is true during the spin")
	end
	advance(8)
	stage = path(playerGui(), "NimbusMenu.RouletteStage")
	local revealHigh = false
	for _, m in ipairs(stage and viewportModels(stage) or {}) do
		if not m:FindFirstAncestor("StripClip") and m:GetAttribute("PB_Detail") == "High" then
			revealHigh = true
		end
	end
	T.check(revealHigh, "release roulette: the reveal card keeps the High detail pet")
	resetMenus()

	-- 4. Inventory grid and Pet Index: one expensive build per frame, a few cheap clones per frame
	local owned = {}
	for i, def in ipairs(PetCatalog.Pets) do
		if i <= 14 then
			owned[def.Id] = 1
		end
	end
	LocalPlayer:SetAttribute("CloudTokens", 600)
	KC().toClient("ProfileSync", {
		Tokens = 600, Pets = owned, Equipped = {}, Items = {}, Stats = { Matches = 1, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = {} },
		SpotIndex = 3, Perks = {}, Discovered = owned, IndexClaimed = {}, Tutorial = { Step = 9, Done = true, Gifted = true },
	})
	advance(0.5)
	local inv = measureBuilds(0.03, function()
		KC().toClient("OpenPanel", "Pets", nil)
		advance(2.0)
	end)
	T.check(inv.Total > 0 and inv.MaxPerFrame == 1, "release roulette: the Inventory grid builds one expensive pet per frame", fmt("%d builds, at most %d in a frame", inv.Total, inv.MaxPerFrame))
	resetMenus()
	local inv2 = measureBuilds(0, function()
		KC().toClient("OpenPanel", "Index", nil)
		advance(2.0)
	end)
	T.check(inv2.Total > 0 and inv2.MaxPerFrame <= 3, "release roulette: the Pet Index attaches at most 3 cheap viewports per frame", fmt("%d builds, at most %d in a frame", inv2.Total, inv2.MaxPerFrame))
	resetMenus()
	local idx = measureBuilds(0.03, function()
		KC().toClient("OpenPanel", "Index", { GroupId = "Rare" })
		advance(2.0)
	end)
	T.check(idx.Total > 0 and idx.MaxPerFrame == 1, "release roulette: the Pet Index builds one expensive pet per frame", fmt("%d builds, at most %d in a frame", idx.Total, idx.MaxPerFrame))
	resetMenus()
	KC().flushErrors("release roulette")
	KC().flushWarnings("release roulette")
end)

----------------------------------------------------------------------------------------------------
-- touch screens: the menu vs Roblox's thumbstick, the tutorial vs the HP card, the menu pointer
----------------------------------------------------------------------------------------------------
-- Roblox's stock thumbsticks in screen px: the classic TouchThumbstick and the DynamicThumbstick's idle ring
local function stickRects(w, h)
	if min(w, h) <= 500 then
		return { { x0 = 25, y0 = h - 90, x1 = 95, y1 = h - 20 }, { x0 = 29, y0 = h - 93, x1 = 103, y1 = h - 19 } }
	end
	return { { x0 = 60, y0 = h - 210, x1 = 180, y1 = h - 90 }, { x0 = 58, y0 = h - 186, x1 = 206, y1 = h - 38 } }
end

local function scaleOf(inst)
	local scale = 1
	local cur = inst
	while cur and cur ~= game do
		if cur:IsA("GuiObject") then
			for _, c in ipairs(cur:GetChildren()) do
				if c:IsA("UIScale") then
					scale = scale * c.Scale
				end
			end
		end
		cur = cur.Parent
	end
	return scale
end

local function tutorialPayload(index)
	local Config = KC().env()
	local Steps = req("TutorialSteps")
	local step = Steps.Steps[index]
	local text = tostring(step.Text or "")
	text = text:gsub("{GiftTokens}", tostring(Config.Tutorial and Config.Tutorial.GiftTokens or 0))
	text = text:gsub("{FinishTokens}", tostring(Config.Tutorial and Config.Tutorial.FinishReward and Config.Tutorial.FinishReward.Tokens or 0))
	return {
		Step = index, Total = #Steps.Steps, Id = step.Id, Title = step.Title, Text = text, Target = step.Target,
		CompleteOn = step.CompleteOn, Hint = step.Hint, Button = step.Button, Gift = step.Gift == true,
		Done = false, Completed = false, Skipped = false, Reward = 0,
	}
end

-- what the tutorial shows: the whole card when it is unfolded, else the portrait bubble
local function tutorialRect()
	local root = path(playerGui(), "NimbusTutorial.TutorialPanel")
	if not (root and shown(root)) then
		return nil, nil
	end
	local main = root:FindFirstChild("Main", true)
	if main and shown(main) then
		return screenRect(root), "card"
	end
	local portrait = root:FindFirstChild("Portrait", true)
	return portrait and screenRect(portrait) or nil, "bubble"
end

S.client_release_touch_mobile = guarded("client_release_touch_mobile", function()
	if not T.check(UserInputService.TouchEnabled, "release touch: the phone world is a touch device (precondition)") then
		return
	end
	local MC = reqClient("Controllers/MenuController")
	local Config = req("Config")

	-- 1. the menu column vs Roblox's thumbstick, readable labels
	for _, size in ipairs({ { 844, 390 }, { 667, 375 }, { 740, 360 }, { 932, 430 }, { 1024, 768 }, { 1180, 820 }, { 1366, 1024 } }) do
		local w, h = size[1], size[2]
		Mock.SetViewport(w, h)
		advance(0.6)
		local label = fmt("release touch %dx%d", w, h)
		local column = path(playerGui(), "NimbusMenu.MenuColumn")
		if T.check(column ~= nil and shown(column), label .. ": the menu column is shown") then
			local hits, small = {}, {}
			for _, d in ipairs(column:GetDescendants()) do
				if d:IsA("GuiButton") and d.Name:find("^MenuButton_") and shown(d) then
					local r = screenRect(d)
					for _, stick in ipairs(stickRects(w, h)) do
						if overlap(r, stick) then
							hits[#hits + 1] = d.Name .. " " .. show(r)
							break
						end
					end
				elseif d:IsA("TextLabel") and d.Name == "Label" and shown(d) then
					local limit = d:FindFirstChildOfClass("UITextSizeConstraint")
					local px = (d.TextScaled and limit and limit.MaxTextSize or d.TextSize) * scaleOf(d)
					if px < 14 - 0.01 then
						small[#small + 1] = fmt("%s %.1f px", d.Parent.Name, px)
					end
				end
			end
			T.check(#hits == 0, label .. ": no menu tile covers Roblox's thumbstick (classic stick or dynamic ring)", table.concat(hits, "; "))
			T.check(#small == 0, label .. ": the tile labels shown stay >= 14 px", table.concat(small, ", "))
			local c = screenRect(column)
			T.check(c.x0 >= 0 and c.y0 >= (Mock.TopInset or 0) and c.x1 <= w and c.y1 <= h, label .. ": the column is on screen, below the top bar", show(c))
		end
	end

	-- 2. the tutorial vs the HP / stamina card: portal wait, opened card, the climb
	local TC = reqClient("Controllers/TutorialController")
	for _, size in ipairs({ { 844, 390 }, { 667, 375 }, { 740, 360 } }) do
		local w, h = size[1], size[2]
		Mock.SetViewport(w, h)
		LocalPlayer:SetAttribute("InMatch", false)
		KC().toClient("MatchState", nil)
		KC().toClient("PartyState", nil)
		KC().toClient("TutorialState", tutorialPayload(7))
		advance(2.5)
		local label = fmt("release touch %dx%d", w, h)
		local vitals = path(playerGui(), "NimbusHud.BottomLeft.Vitals")
		local hotbar = path(playerGui(), "NimbusHotbar.Hotbar")
		-- lobbyCard: the card the player opened in the lobby, where nothing can hurt them and the hotbar is idle: it
		-- may cover the vitals card and the hotbar, but never Roblox's thumbstick, the touch buttons or the menu
		local function checkClear(what, lobbyCard)
			local r, kind = tutorialRect()
			if not T.check(r ~= nil, label .. " " .. what .. ": the tutorial is shown") then
				return nil
			end
			T.check(r.x0 >= -0.5 and r.y0 >= (Mock.TopInset or 0) - 0.5 and r.x1 <= w + 0.5 and r.y1 <= h + 0.5, label .. " " .. what .. ": the tutorial " .. kind .. " stays on screen", show(r))
			if lobbyCard then
				local hits = {}
				for _, stick in ipairs(stickRects(w, h)) do
					if overlap(r, stick) then
						hits[#hits + 1] = "thumbstick"
					end
				end
				local mobile = path(playerGui(), "MobileControls")
				for _, d in ipairs(mobile and mobile:GetDescendants() or {}) do
					if d:IsA("GuiButton") and shown(d) and overlap(r, screenRect(d)) then
						hits[#hits + 1] = d.Name
					end
				end
				local column = path(playerGui(), "NimbusMenu.MenuColumn")
				if column and shown(column) and overlap(r, screenRect(column)) then
					hits[#hits + 1] = "menu column"
				end
				T.check(#hits == 0, label .. " " .. what .. ": the card stays clear of the thumbstick, the touch buttons and the menu", table.concat(hits, ", ") .. " " .. show(r))
				return kind
			end
			if vitals and shown(vitals) then
				T.check(not overlap(r, screenRect(vitals)), label .. " " .. what .. ": the tutorial " .. kind .. " leaves the HP / stamina card visible", show(r) .. " vs " .. show(screenRect(vitals)))
			end
			if hotbar and shown(hotbar) then
				T.check(not overlap(r, screenRect(hotbar)), label .. " " .. what .. ": the tutorial " .. kind .. " leaves the hotbar visible", show(r) .. " vs " .. show(screenRect(hotbar)))
			end
			local party = path(playerGui(), "NimbusHud.TopLeft.PartyPanel")
			if party and shown(party) then
				T.check(not overlap(r, screenRect(party)), label .. " " .. what .. ": the tutorial " .. kind .. " stays clear of the party panel", show(r))
			end
			return kind
		end
		checkClear("lobby")
		-- the player opens the card in the lobby: readable, never over the hotbar or off the screen
		local toggle = path(playerGui(), "NimbusTutorial.TutorialPanel.Slide.Portrait.Toggle")
		local _, kind0 = tutorialRect()
		if kind0 == "bubble" and toggle then
			Mock.Click(toggle)
			advance(0.8)
		end
		local kind1 = checkClear("opened in the lobby", true)
		T.check(kind1 == "card", label .. ": tapping the bubble in the lobby opens the card (its text, Next and Skip stay reachable)")
		local nextOrSkip = path(playerGui(), "NimbusTutorial.TutorialPanel")
		nextOrSkip = nextOrSkip and nextOrSkip:FindFirstChild("SkipLink", true)
		if nextOrSkip then
			local sr = screenRect(nextOrSkip)
			T.check(shown(nextOrSkip) and sr.y1 <= h + 0.5 and sr.y0 >= 0, label .. ": ...the Skip link is on screen", show(sr))
		end
		-- portal wait with the party panel
		KC().toClient("PartyState", { PortalId = "Easy", DifficultyName = "Easy", Color = Color3.fromRGB(96, 190, 140),
			Players = { { UserId = LocalPlayer.UserId, Name = LocalPlayer.Name } }, Max = 4, Countdown = 12 })
		advance(1.5)
		checkClear("portal wait")
		-- the match starts: the card opened in the lobby is folded back, nothing covers the HP card
		KC().toClient("PartyState", nil)
		LocalPlayer:SetAttribute("InMatch", true)
		KC().toClient("MatchState", KC().matchState({}))
		KC().toClient("TutorialState", tutorialPayload(8))
		advance(1.5)
		local kind2 = checkClear("climb")
		T.check(kind2 == "bubble", label .. ": the climb starts with the bubble (the lobby's opened card does not follow into the match)", tostring(kind2))
		if toggle and shown(toggle) then
			Mock.Click(toggle)
			advance(0.8)
			checkClear("climb, bubble tapped")
		end
		LocalPlayer:SetAttribute("InMatch", false)
		KC().toClient("MatchState", nil)
		advance(0.5)
	end

	-- 3. the menu pointer on the landscape phone grid, and windows on top
	Mock.SetViewport(844, 390)
	advance(0.6)
	for _, step in ipairs({ 5, 6 }) do
		KC().toClient("TutorialState", tutorialPayload(step))
		advance(2.5)
		local target = tutorialPayload(step).Target.Id
		local label = fmt("release touch 844x390 step %d (%s)", step, target)
		local ring = path(playerGui(), "NimbusTutorialPointer.Ring")
		local arrow = path(playerGui(), "NimbusTutorialPointer.Arrow")
		local button = MC.GetButton and MC.GetButton(target)
		if T.check(ring ~= nil and shown(ring) and button ~= nil, label .. ": the ring marks the menu button") then
			local rr, br = screenRect(ring), screenRect(button)
			T.check(abs((rr.x0 + rr.x1) - (br.x0 + br.x1)) < 3 and abs((rr.y0 + rr.y1) - (br.y0 + br.y1)) < 3, label .. ": ...centred on MenuButton_" .. target)
			if arrow and shown(arrow) then
				-- the arrow's box after its Rotation (multiples of 90 degrees)
				local a = screenRect(arrow)
				local cx, cy = (a.x0 + a.x1) / 2, (a.y0 + a.y1) / 2
				local hw, hh = (a.x1 - a.x0) / 2, (a.y1 - a.y0) / 2
				if abs(arrow.Rotation % 180) > 45 then
					hw, hh = hh, hw
				end
				local box = { x0 = cx - hw, y0 = cy - hh, x1 = cx + hw, y1 = cy + hh }
				local hits = {}
				for _, other in ipairs(path(playerGui(), "NimbusMenu"):GetDescendants()) do
					if other:IsA("GuiButton") and other.Name:find("^MenuButton_") and other ~= button and shown(other) and overlap(box, screenRect(other)) then
						hits[#hits + 1] = other.Name
					end
				end
				T.check(#hits == 0, label .. ": the arrow does not sit on another menu tile", table.concat(hits, ", ") .. " " .. show(box))
				local tr = tutorialRect()
				T.check(not (tr and overlap(box, tr)), label .. ": the arrow does not sit on the tutorial card / bubble", show(box) .. " vs " .. (tr and show(tr) or "-"))
			else
				T.info("*" .. label .. ": no free side for the arrow, the ring alone marks the button")
			end
		end
		-- a window on top: ring + arrow hidden, the card folded; back when it closes
		KC().toClient("OpenPanel", "Stats", nil)
		advance(1.0)
		T.check(not shown(ring) and not (arrow and shown(arrow)), label .. ": the ring and arrow hide while a window is open (they drew over the Stats window)")
		local _, kindOpen = tutorialRect()
		T.check(kindOpen ~= "card", label .. ": the tutorial card folds while a window is open", tostring(kindOpen))
		KC().toClient("OpenPanel", "close", nil)
		advance(1.2)
		T.check(shown(ring), label .. ": ...and the ring comes back when the window closes")
	end

	-- leave the world as we found it
	KC().toClient("TutorialState", { Step = 9, Total = 9, Id = "done", Text = "", Done = true, Completed = false, Skipped = true, Reward = 0 })
	Mock.SetViewport(390, 844)
	advance(1.0)
	KC().flushErrors("release touch")
	KC().flushWarnings("release touch")
end)

return S
