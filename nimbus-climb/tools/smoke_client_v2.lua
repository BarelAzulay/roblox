-- smoke_client_v2.lua: client scenarios for the v2 UI (ARCHITECTURE_V2.md section 9), run in the client world of
-- tools/smoke.py after smoke_client.lua (which exports its helpers as the global KC):
--   client_ui_kit      CloudUI: every constructor of the kit, chunky style, shared update loop
--   client_state       State: ProfileSync mirror, defaults, sanitising, Changed / Tokens
--   client_menu        MenuController: 5 icon buttons, Inventory / Pets / Shop (roulettes + items) / Stats windows,
--                      the roulette spin + reveal, OpenPanel, Esc, one window at a time
--   client_hotbar      HotbarController: 4 slots, keys 1-4, dimmed in the lobby, UseItem remote, cooldown
--   client_pets        PetController: followers of every player, culling, snapping, clean-up
--   client_layout_rule NO text from the HUD / toasts / countdown / party / results / menu / hotbar in the middle of
--                      the screen at 1920x1080 (and, from client_mobile, at 390x844)
-- Plain Lua 5.1 syntax only.

local KC = _G.KC
local T = KC.T
local guarded = KC.guarded
local M = KC.M
local fmt = KC.fmt
local advance = KC.advance
local gui, isShown, texts, findText, allShownText = KC.gui, KC.isShown, KC.texts, KC.findText, KC.allShownText
local toClient, serverCalls, remotes = KC.toClient, KC.serverCalls, KC.remotes
local flushErrors, flushWarnings = KC.flushErrors, KC.flushWarnings
local centredTexts, describeCentred = KC.centredTexts, KC.describeCentred

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local abs, floor, max, min, huge = math.abs, math.floor, math.max, math.min, math.huge

local S = {}

local function env()
	return KC.env()
end

-- the remote calls of one kind made after the first `count` of them (count = #serverCalls(name) taken earlier)
local function callsAfter(name, count)
	local all = serverCalls(name)
	local out = {}
	for i = (count or 0) + 1, #all do
		out[#out + 1] = all[i]
	end
	return out
end

local function descendantNamed(root, name)
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == name then
			return d
		end
	end
	return nil
end

local function allNamed(root, name)
	local out = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == name then
			out[#out + 1] = d
		end
	end
	return out
end

-- true when a shown label under `root` contains the number n (thousands separators ignored: '1,000' == 1000)
local function hasNumber(root, n)
	for _, d in ipairs(texts(root, true)) do
		if (tostring(d.Text):gsub("[,%s]", "")):find(tostring(n), 1, true) then
			return true
		end
	end
	return false
end

local function countGui()
	return #gui():GetDescendants()
end

local function press(keyName, processed)
	Mock.FireSignal(UserInputService, "InputBegan", Mock.NewInput(keyName, "Keyboard", "Begin"), processed or false)
end

-- a profile snapshot like the server's ProfileSync
local function snapshot(over)
	local snap = {
		Tokens = 600,
		Pets = { cloudy_dragon = 2, pebble_pup = 1, biscuit_bear = 3 },
		Equipped = { "cloudy_dragon", "biscuit_bear" },
		Items = { heal_cloud = 2, phoenix_feather = 1 },
		Stats = { Matches = 12, Wins = 7, TokensEarned = 900, Spins = 5, BestTimes = { Easy = 123.4 } },
		SpotIndex = 3,
		Perks = { MaxHealth = 0.12, TokenBonus = 0.25, StaminaRegen = 0, CheckpointHeal = 0.02 },
	}
	for k, v in pairs(over or {}) do
		snap[k] = v
	end
	return snap
end

local function feed(over)
	LocalPlayer:SetAttribute("CloudTokens", (over and over.Tokens) or 600)
	toClient("ProfileSync", snapshot(over))
	advance(0.3)
end

local function resetMatchState()
	toClient("MatchState", nil)
	toClient("PartyState", nil)
	LocalPlayer:SetAttribute("InMatch", false)
	LocalPlayer:SetAttribute("Downed", false)
	LocalPlayer:SetAttribute("MatchTokens", 0)
	advance(1.2)
end

----------------------------------------------------------------------------------------------------
-- scenario: the UI kit
----------------------------------------------------------------------------------------------------
S.client_ui_kit = guarded("client_ui_kit", function()
	local Config, Util, Theme = env()
	local CloudUI, PetCatalog = M.CloudUI, require(Mock.GetPath(ROOTS["shared"] .. "/PetCatalog"))
	local PetBuilder = require(Mock.GetPath(ROOTS["shared"] .. "/PetBuilder"))
	if not CloudUI then
		T.fail("client_ui_kit needs CloudUI (see client_load)")
		return
	end
	local playerGui = gui()

	-- screen gui
	local g = CloudUI.NewScreenGui("SmokeKit", 40)
	T.check(g:IsA("ScreenGui") and g.Parent == playerGui and g.Name == "SmokeKit", "NewScreenGui(name, order) creates a ScreenGui in PlayerGui")
	T.check(g.ResetOnSpawn == false and g.IgnoreGuiInset == false and g.ZIndexBehavior == Enum.ZIndexBehavior.Sibling and g.DisplayOrder == 40, "...with ResetOnSpawn = false, IgnoreGuiInset = false, Sibling z-order and the given DisplayOrder")
	local again = CloudUI.NewScreenGui("SmokeKit", 41)
	local copies = 0
	for _, c in ipairs(playerGui:GetChildren()) do
		if c.Name == "SmokeKit" then
			copies = copies + 1
		end
	end
	T.eq(copies, 1, "calling NewScreenGui twice with a name replaces the old gui (no duplicates)")
	g = again

	-- panel
	local closed = 0
	local panel = CloudUI.Panel({
		Name = "KitPanel", Size = UDim2.fromOffset(520, 340), Position = UDim2.new(0.5, 0, 0.5, 0), AnchorPoint = Vector2.new(0.5, 0.5),
		Title = "Hello Sky", Closable = true, OnClose = function()
			closed = closed + 1
		end, Parent = g,
	})
	T.check(panel.Root ~= nil and panel.Root:IsA("Frame") and panel.Root.Parent == g and panel.Content:IsA("Frame") and panel.Content:IsDescendantOf(panel.Root), "Panel returns { Root, Content, TitleLabel, Close }")
	T.check(panel.TitleLabel ~= nil and panel.TitleLabel.Text == "Hello Sky", "...with the title text")
	T.check(type(panel.Close) == "function", "...and a Close function")
	local body = panel.Root:FindFirstChild("Body")
	local stroke = body and body:FindFirstChildOfClass("UIStroke")
	T.check(stroke ~= nil and stroke.Thickness >= 3 and stroke.Thickness <= 4, "panels have a thick (3-4 px) outline", stroke and tostring(stroke.Thickness) or "no UIStroke")
	if stroke then
		local c = stroke.Color
		T.check(c.R + c.G + c.B < 1.2 and c.B >= c.R, "...in a dark navy", tostring(c))
	end
	local corner = body and body:FindFirstChildOfClass("UICorner")
	T.check(corner ~= nil and corner.CornerRadius.Offset >= 14 and corner.CornerRadius.Offset <= 18, "...with 14-18 px rounded corners", corner and tostring(corner.CornerRadius) or "no UICorner")
	local grad = body and body:FindFirstChildOfClass("UIGradient")
	T.check(grad ~= nil, "...a soft gradient fill")
	local puffs = panel.Root:FindFirstChild("CloudPuffs")
	T.check(puffs ~= nil and #puffs:GetChildren() >= 5, "...and cloud bumps along the top edge", puffs and (#puffs:GetChildren() .. " bumps") or "none")
	local plain = CloudUI.Panel({ Name = "NoClouds", Clouds = false, Size = UDim2.fromOffset(200, 100), Parent = g })
	T.check(plain.Root:FindFirstChild("CloudPuffs") == nil and plain.TitleLabel == nil and plain.Root:FindFirstChild("Close", true) == nil, "Clouds = false / no title / not closable: no bumps, ribbon or red X")
	local x = panel.Root:FindFirstChild("Close", true)
	if T.check(x ~= nil and x:IsA("TextButton") and x.Text == "X", "a closable panel has a red X button") then
		local c = x.BackgroundColor3
		T.check(c.R > c.G + 0.12 and c.R > c.B, "...and it is red", tostring(c))
		Mock.Click(x)
		advance(0.1)
		T.eq(closed, 1, "...clicking it calls OnClose")
	end
	panel.Close()
	T.eq(closed, 2, "Panel.Close() calls OnClose too")
	local hider = CloudUI.Panel({ Name = "Hider", Closable = true, Size = UDim2.fromOffset(200, 100), Parent = g })
	hider.Close()
	T.eq(hider.Root.Visible, false, "without OnClose, Close() hides the panel")

	-- buttons
	local styles = { "Green", "Pink", "Red", "Blue", "Gold" }
	local faces, hits = {}, {}
	for _, style in ipairs(styles) do
		local b = CloudUI.Button({ Text = style, Style = style, Size = UDim2.fromOffset(140, 44), Parent = g, Callback = function()
			hits[style] = (hits[style] or 0) + 1
		end })
		faces[style] = b.BackgroundColor3
		Mock.Click(b)
		advance(0.05)
	end
	local allOnce = true
	for _, style in ipairs(styles) do
		allOnce = allOnce and hits[style] == 1
	end
	T.check(allOnce, "Button styles Green / Pink / Red / Blue / Gold each fire their Callback once per click")
	local distinct, names = 0, {}
	for _, style in ipairs(styles) do
		local key = string.format("%.2f,%.2f,%.2f", faces[style].R, faces[style].G, faces[style].B)
		if not names[key] then
			names[key] = true
			distinct = distinct + 1
		end
	end
	T.eq(distinct, 5, "...and look different")
	T.check(faces.Green.G > faces.Green.R and faces.Green.G > faces.Green.B, "Green is green")
	T.check(faces.Gold.R > faces.Gold.B and faces.Gold.G > faces.Gold.B, "Gold is gold")
	local fired = 0
	local btn = CloudUI.Button({ Text = "Go", Style = "Green", Size = UDim2.fromOffset(120, 40), AnchorPoint = Vector2.new(0.5, 0.5), Parent = g, Callback = function()
		fired = fired + 1
	end })
	btn:SetAttribute("Disabled", true)
	Mock.Click(btn)
	advance(0.05)
	T.eq(fired, 0, "a Disabled button ignores clicks")
	btn:SetAttribute("Disabled", false)
	Mock.Click(btn)
	advance(0.05)
	T.eq(fired, 1, "...and works again when enabled")
	local before = btn.BackgroundColor3
	btn:SetAttribute("Style", "Red")
	advance(0.4)
	T.check(btn.BackgroundColor3 ~= before, "setting the Style attribute re-skins a button")
	local fxScale = btn:FindFirstChild("FxScale")
	if fxScale then
		Mock.FireSignal(btn, "MouseEnter")
		advance(0.4)
		T.near(fxScale.Scale, 1.04, 0.02, "hovering grows a button to 1.04")
		Mock.FireSignal(btn, "MouseButton1Down")
		advance(0.4)
		T.near(fxScale.Scale, 0.95, 0.02, "pressing squashes it to 0.95")
		Mock.FireSignal(btn, "MouseButton1Up")
		Mock.FireSignal(btn, "MouseLeave")
		advance(0.4)
		T.near(fxScale.Scale, 1, 0.02, "...and it settles back to 1")
	else
		T.fail("buttons have a UIScale for the hover / press tween")
	end

	-- icon button
	local pressed = 0
	local icon = CloudUI.IconButton({ Glyph = "B", Label = "Bag", Color = "Blue", Callback = function()
		pressed = pressed + 1
	end, Badge = true, Parent = g })
	T.check(icon.Root ~= nil and icon.Button ~= nil and icon.Button:IsA("TextButton"), "IconButton returns { Root, Button }")
	local joined = {}
	for _, d in ipairs(icon.Root:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			joined[#joined + 1] = d.Text
		end
	end
	local text = table.concat(joined, "|")
	T.check(text:find("B", 1, true) ~= nil and text:find("Bag", 1, true) ~= nil, "...showing the glyph and the caption below it", text)
	T.check(abs(icon.Button.AbsoluteSize.X - icon.Button.AbsoluteSize.Y) < 2, "...the button itself is round (square + full corner radius)", tostring(icon.Button.AbsoluteSize))
	Mock.Click(icon.Button)
	advance(0.05)
	T.eq(pressed, 1, "...and clicking it calls the Callback")

	-- bar
	local bar = CloudUI.Bar({ Size = UDim2.fromOffset(200, 22), Color = Color3.fromRGB(90, 200, 120), Label = "HP", Parent = g })
	T.check(bar.Root and bar.Fill and type(bar.SetFraction) == "function" and type(bar.SetText) == "function" and type(bar.SetColor) == "function", "Bar returns { Root, Fill, SetFraction, SetText, SetColor }")
	bar.SetFraction(0.5)
	T.near(bar.Fill.Size.X.Scale, 0.5, 0.001, "SetFraction(0.5) fills half the bar")
	bar.SetFraction(1.7)
	T.near(bar.Fill.Size.X.Scale, 1, 0.001, "...clamped to 1")
	bar.SetFraction(-3)
	T.near(bar.Fill.Size.X.Scale, 0, 0.001, "...and to 0")
	bar.SetFraction(0.25, true)
	advance(0.5)
	T.near(bar.Fill.Size.X.Scale, 0.25, 0.01, "an animated SetFraction reaches its goal")
	bar.SetText("78 / 100")
	T.check(descendantNamed(bar.Root, "Text") ~= nil and descendantNamed(bar.Root, "Text").Text == "78 / 100", "SetText shows the text")
	bar.SetColor(Color3.fromRGB(220, 60, 60))
	T.check(true, "SetColor accepts a Color3")

	-- slot
	local slotClicks = 0
	local slot = CloudUI.Slot({ Size = UDim2.fromOffset(72, 72), Hotkey = "2", Parent = g, Callback = function()
		slotClicks = slotClicks + 1
	end })
	T.check(slot.Root and slot.Button and type(slot.SetContent) == "function" and type(slot.SetSelected) == "function" and type(slot.SetCount) == "function" and type(slot.SetHotkey) == "function", "Slot returns { Root, Button, SetContent, SetSelected, SetCount, SetHotkey }")
	slot.SetContent({ Glyph = "S", Color = Color3.fromRGB(100, 200, 255), RarityColor = Config.Rarities[3].Color, Name = "Thing" })
	local slotTexts = {}
	for _, d in ipairs(slot.Root:GetDescendants()) do
		if d:IsA("TextLabel") and isShown(d) then
			slotTexts[#slotTexts + 1] = d.Text
		end
	end
	T.check(table.concat(slotTexts, "|"):find("S", 1, true) ~= nil and table.concat(slotTexts, "|"):find("2", 1, true) ~= nil, "SetContent shows the glyph, and SetHotkey the key", table.concat(slotTexts, "|"))
	slot.SetCount(7)
	T.check(descendantNamed(slot.Root, "Count") ~= nil and tostring(descendantNamed(slot.Root, "Count").Text):find("7") ~= nil, "SetCount(7) shows 'x7'", descendantNamed(slot.Root, "Count") and descendantNamed(slot.Root, "Count").Text or "no Count label")
	slot.SetSelected(true)
	slot.SetSelected(false)
	Mock.Click(slot.Button)
	advance(0.05)
	T.eq(slotClicks, 1, "clicking a slot calls its Callback")
	local dragon = PetCatalog.Get(CONTRACT.v2.mascotPetId)
	slot.SetContent({ Pet = dragon, RarityColor = Config.Rarities[6].Color })
	advance(0.3)
	local vp = slot.Root:FindFirstChildWhichIsA("ViewportFrame", true)
	T.check(vp ~= nil and vp:FindFirstChildWhichIsA("Model", true) ~= nil, "a slot with Pet shows a ViewportFrame holding the pet model")
	slot.SetContent(nil)
	advance(0.3)
	T.check(slot.Root:FindFirstChildWhichIsA("ViewportFrame", true) == nil, "...which is removed again by SetContent(nil)")

	-- tabs
	local built = {}
	local selectedNames = {}
	local tabs = CloudUI.Tabs({ Size = UDim2.fromOffset(400, 240), Parent = g, OnSelect = function(name)
		selectedNames[#selectedNames + 1] = name
	end })
	T.check(tabs.Root and tabs.Content and type(tabs.Add) == "function" and type(tabs.Select) == "function", "Tabs returns { Root, Content, Add, Select }")
	local pageA = tabs.Add("Alpha", function(page)
		built.Alpha = page
	end)
	local pageB = tabs.Add("Beta", function(page)
		built.Beta = page
	end)
	T.check(built.Alpha == pageA and built.Beta == pageB and pageA:IsA("Frame"), "Add(name, builderFn) calls builderFn(page) and returns the page")
	T.check(pageA.Visible == true and pageB.Visible == false, "the first tab is selected")
	tabs.Select("Beta")
	T.check(pageA.Visible == false and pageB.Visible == true, "Select(name) switches pages")
	tabs.Select("Nope")
	T.check(pageB.Visible == true, "selecting an unknown tab changes nothing")
	local tabButtons = {}
	for _, d in ipairs(tabs.Root:GetDescendants()) do
		if d:IsA("TextButton") then
			tabButtons[d.Text] = d
		end
	end
	T.check(tabButtons.Alpha ~= nil and tabButtons.Beta ~= nil, "each tab has a button in the strip")
	if tabButtons.Alpha then
		Mock.Click(tabButtons.Alpha)
		advance(0.05)
		T.check(pageA.Visible == true and pageB.Visible == false, "clicking a tab button selects it")
	end

	-- grid
	local gridParent = Instance.new("Frame")
	gridParent.Size = UDim2.fromOffset(400, 200)
	gridParent.Parent = g
	local grid = CloudUI.Grid(gridParent, 80, 8)
	T.check(grid:IsA("ScrollingFrame") and grid:FindFirstChildOfClass("UIGridLayout") ~= nil, "Grid returns a ScrollingFrame with a UIGridLayout")
	T.eq(grid:FindFirstChildOfClass("UIGridLayout").CellSize.X.Offset, 80, "...with the requested cell size")
	for i = 1, 30 do
		local cell = Instance.new("Frame")
		cell.LayoutOrder = i
		cell.Parent = grid
	end
	advance(0.2)
	local last = grid:GetChildren()
	local lastCell
	for _, c in ipairs(last) do
		if c:IsA("Frame") and c.LayoutOrder == 30 then
			lastCell = c
		end
	end
	T.check(lastCell ~= nil and lastCell.AbsolutePosition.Y > grid.AbsolutePosition.Y + 80, "...which wraps its cells into rows", lastCell and tostring(lastCell.AbsolutePosition) or "no cell")
	T.eq(grid.AutomaticCanvasSize, Enum.AutomaticSize.Y, "...and sizes its canvas automatically (AutomaticCanvasSize = Y)")

	-- pet viewports: ONE shared RenderStepped connection
	local statsBefore = Mock.Stats().connections["RunService.RenderStepped"] or 0
	local viewports = {}
	for i = 1, 8 do
		viewports[i] = CloudUI.PetViewport(g, PetCatalog.Pets[i], 96)
	end
	advance(0.3)
	local statsWith = Mock.Stats().connections["RunService.RenderStepped"] or 0
	T.check(statsWith - statsBefore <= 1, "8 PetViewports share ONE RenderStepped connection", statsBefore .. " -> " .. statsWith)
	local first = viewports[1]
	T.check(first.Frame ~= nil and first.Frame:IsA("ViewportFrame") and type(first.Destroy) == "function", "PetViewport returns { Frame, Destroy } with a ViewportFrame")
	T.check(first.Frame.CurrentCamera ~= nil, "...with a camera")
	local model = first.Frame:FindFirstChildWhichIsA("Model", true)
	if T.check(model ~= nil and model:FindFirstChild("WingL", true) ~= nil, "...showing the PetBuilder model (with wings)") then
		local rot0 = model.PrimaryPart.CFrame
		local wing0 = model:FindFirstChild("WingL", true).CFrame
		advance(1.0)
		local rot1 = model.PrimaryPart.CFrame
		local wing1 = model:FindFirstChild("WingL", true).CFrame
		T.check((rot1.LookVector - rot0.LookVector).Magnitude > 0.05 or (rot1.Position - rot0.Position).Magnitude > 0.01, "...which spins slowly")
		T.check((model.PrimaryPart.CFrame:ToObjectSpace(wing1).Position - model.PrimaryPart.CFrame:ToObjectSpace(wing0).Position).Magnitude > 0.001 or (wing1.Position - wing0.Position).Magnitude > 0.001, "...and flaps its wings")
	end
	for _, v in ipairs(viewports) do
		v.Destroy()
	end
	advance(0.5)
	local statsAfter = Mock.Stats().connections["RunService.RenderStepped"] or 0
	T.check(statsAfter <= statsBefore, "destroying the viewports releases the shared RenderStepped connection", statsBefore .. " -> " .. statsAfter)
	local byId = CloudUI.PetViewport(g, CONTRACT.v2.mascotPetId, 64)
	T.check(byId.Frame:FindFirstChildWhichIsA("Model", true) ~= nil, "PetViewport also accepts a pet id")
	byId.Destroy()
	local unknown = CloudUI.PetViewport(g, "no_such_pet", 64)
	T.check(unknown.Frame ~= nil, "PetViewport(unknown id) does not raise")
	unknown.Destroy()

	-- pill, tooltip, rarity colour
	local pill = CloudUI.Pill("Epic", "Epic", g)
	T.check(pill:IsA("TextLabel") and pill.Text == "Epic", "Pill returns a TextLabel with the text")
	for _, kind in ipairs({ "info", "good", "bad", "token" }) do
		local p = CloudUI.Pill(kind, kind, g)
		T.check(p.BackgroundColor3 ~= nil, "Pill kind '" .. kind .. "' works")
	end
	for _, r in ipairs(Config.Rarities) do
		T.check(CloudUI.RarityColor(r.Id) == r.Color, "RarityColor('" .. r.Id .. "') is the Config colour")
	end
	T.check(CloudUI.RarityColor("epic") == Config.Rarities[4].Color, "RarityColor is case-insensitive")
	T.check(typeof(CloudUI.RarityColor("???")) == "Color3", "RarityColor of an unknown id still returns a colour")
	local tipTarget = Instance.new("Frame")
	tipTarget.Size = UDim2.fromOffset(60, 60)
	tipTarget.Position = UDim2.fromOffset(100, 300)
	tipTarget.Parent = g
	local disconnect = CloudUI.Tooltip(tipTarget, "A helpful hint")
	T.check(type(disconnect) == "function", "Tooltip returns a disconnect function")
	Mock.FireSignal(tipTarget, "MouseEnter", 120, 320)
	advance(0.8)
	T.check(findText("a helpful hint") ~= nil, "hovering shows the tooltip text")
	Mock.FireSignal(tipTarget, "MouseLeave")
	advance(0.4)
	T.check(findText("a helpful hint") == nil, "...and leaving hides it")
	disconnect()

	-- fonts: everything built above uses Theme fonts
	local allowed = {}
	for _, font in pairs(Theme.Fonts) do
		allowed[font] = true
	end
	local problems = Mock.FontAudit(allowed)
	T.check(#problems == 0, "every text of the kit uses a Theme font", #problems > 0 and (problems[1].path .. ": " .. problems[1].reason) or "")
	g:Destroy()
	advance(0.5)
	T.check(playerGui:FindFirstChild("SmokeKit") == nil, "the scratch gui is gone")
	flushErrors("client_ui_kit")
	flushWarnings("client_ui_kit")
end)

----------------------------------------------------------------------------------------------------
-- scenario: State
----------------------------------------------------------------------------------------------------
S.client_state = guarded("client_state", function()
	local Config = env()
	local State = M.State
	if not State then
		T.fail("client_state needs State (see client_load)")
		return
	end
	T.eq(State.IsLoaded and State.IsLoaded(), false, "before the first ProfileSync State is not loaded")
	local snap0 = State.Get()
	T.check(type(snap0) == "table" and type(snap0.Pets) == "table" and type(snap0.Equipped) == "table" and type(snap0.Items) == "table" and type(snap0.Stats) == "table" and type(snap0.Perks) == "table",
		"State.Get() never returns nil: defaults { Tokens, Pets, Equipped, Items, Stats, Perks }")
	T.check(snap0.Stats.Matches == 0 and snap0.Stats.Wins == 0 and type(snap0.Stats.BestTimes) == "table" and snap0.Perks.MaxHealth == 0 and snap0.Perks.TokenBonus == 0, "...with zeroed stats and perks")
	T.check(State.OwnedCount("cloudy_dragon") == 0 and State.EquippedCount("cloudy_dragon") == 0 and State.IsEquipped("cloudy_dragon") == false and State.ItemCount("heal_cloud") == 0, "...and nothing owned")
	T.check(#serverCalls("RequestProfile") >= 2, "State asks for the profile (RequestProfile) and retries while no snapshot arrived", #serverCalls("RequestProfile") .. " requests")
	local requestsBefore = #serverCalls("RequestProfile")
	State.Init()
	State.Init()
	T.eq(#serverCalls("RequestProfile"), requestsBefore, "State.Init() is safe to call twice (no second request)")

	-- tokens come from the attribute
	local tokenEvents = {}
	local tokenConn = State.TokensChanged and State.TokensChanged:Connect(function(n)
		tokenEvents[#tokenEvents + 1] = n
	end)
	LocalPlayer:SetAttribute("CloudTokens", 77)
	advance(0.1)
	T.eq(State.Tokens(), 77, "State.Tokens() reads the CloudTokens attribute")
	T.eq(State.Get().Tokens, 77, "...and the snapshot follows it")
	T.check(#tokenEvents >= 1 and tokenEvents[#tokenEvents] == 77, "(TokensChanged fires)", tostring(tokenEvents[#tokenEvents]))
	if tokenConn then
		tokenConn:Disconnect()
	end

	-- a ProfileSync
	local changes = 0
	local lastSnap
	local conn = State.Changed:Connect(function(s)
		changes = changes + 1
		lastSnap = s
	end)
	toClient("ProfileSync", snapshot())
	advance(0.1)
	T.eq(changes, 1, "State.Changed fires once per ProfileSync")
	T.check(lastSnap == State.Get(), "...with the new snapshot")
	T.eq(State.IsLoaded and State.IsLoaded(), true, "...and State is loaded now")
	T.eq(State.OwnedCount("cloudy_dragon"), 2, "OwnedCount reads the stack size")
	T.eq(State.OwnedCount("nobody"), 0, "...0 for pets that are not owned")
	T.check(State.IsEquipped("cloudy_dragon") and State.IsEquipped("biscuit_bear") and not State.IsEquipped("pebble_pup"), "IsEquipped lists the equipped pets")
	T.eq(State.EquippedCount("cloudy_dragon"), 1, "EquippedCount counts copies")
	T.eq(State.ItemCount("heal_cloud"), 2, "ItemCount")
	T.eq(State.ItemCount("shield_bubble"), 0, "...0 for items not carried")
	T.eq(State.Get().Stats.Wins, 7, "Stats are mirrored")
	T.eq(State.Get().Stats.BestTimes.Easy, 123.4, "...also the best times")
	T.near(State.Get().Perks.TokenBonus, 0.25, 1e-9, "...and the perks")
	T.eq(State.Get().SpotIndex, 3, "...and the SpotIndex")
	-- snapshots are replaced, never mutated
	local old = State.Get()
	toClient("ProfileSync", snapshot({ Pets = { cloudy_dragon = 5 }, Equipped = {}, Items = {} }))
	advance(0.1)
	T.check(old.Pets.cloudy_dragon == 2 and State.Get().Pets.cloudy_dragon == 5 and old ~= State.Get(), "a held snapshot is never mutated by a later sync")
	T.eq(changes, 2, "...and Changed fired again")
	-- messy data is sanitised
	toClient("ProfileSync", { Tokens = -4, Pets = { a = -3, b = 2.7, c = "x", [5] = 1 }, Equipped = { 5, "dragon", {} }, Items = "none", Stats = { Matches = "x", BestTimes = { Easy = "slow" } }, Perks = { MaxHealth = 0 / 0 } })
	advance(0.1)
	local messy = State.Get()
	T.check(type(messy.Pets) == "table" and messy.Pets.a == nil and messy.Pets.c == nil and messy.Pets.b == 2, "messy ProfileSync data is sanitised (pet counts)")
	T.check(#messy.Equipped == 1 and messy.Equipped[1] == "dragon", "...(equipped ids)")
	T.check(type(messy.Items) == "table" and type(messy.Stats.Matches) == "number" and messy.Stats.BestTimes.Easy == nil and messy.Perks.MaxHealth == 0, "...(items, stats, perks)")
	toClient("ProfileSync", "garbage")
	toClient("ProfileSync", nil)
	advance(0.1)
	T.check(type(State.Get()) == "table", "a non-table ProfileSync is ignored")
	conn:Disconnect()
	-- no more retries after the first snapshot
	local requests = #serverCalls("RequestProfile")
	advance(40)
	T.eq(#serverCalls("RequestProfile"), requests, "once a snapshot has arrived State stops asking for one")
	feed()
	flushErrors("client_state")
	flushWarnings("client_state")
end)

----------------------------------------------------------------------------------------------------
-- scenario: the menu + windows
----------------------------------------------------------------------------------------------------
local function windowOf(name)
	local menu = gui():FindFirstChild("NimbusMenu")
	return menu and menu:FindFirstChild(name)
end

local function visibleWindows()
	local out = {}
	local menu = gui():FindFirstChild("NimbusMenu")
	for _, c in ipairs(menu and menu:GetChildren() or {}) do
		if c.Name:find("^Window_") and c:IsA("GuiObject") and c.Visible then
			out[#out + 1] = c.Name
		end
	end
	return out
end

local function clickEntry(name)
	local entry = windowOf("MenuColumn") and windowOf("MenuColumn"):FindFirstChild("Entry_" .. name)
	local button = entry and entry:FindFirstChildWhichIsA("TextButton", true)
	if button then
		Mock.Click(button)
		advance(0.5)
	end
	return button
end

S.client_menu = guarded("client_menu", function()
	local Config, Util, Theme = env()
	local PetCatalog = require(Mock.GetPath(ROOTS["shared"] .. "/PetCatalog"))
	local ItemCatalog = require(Mock.GetPath(ROOTS["shared"] .. "/ItemCatalog"))
	local Menu = M.MenuController
	local menu = gui():FindFirstChild("NimbusMenu")
	if not T.check(menu ~= nil and menu:IsA("ScreenGui"), "MenuController builds the ScreenGui 'NimbusMenu'") then
		return
	end
	resetMatchState()
	feed()
	local vp = Mock.Viewport

	-- the column
	local column = menu:FindFirstChild("MenuColumn")
	if T.check(column ~= nil, "the menu column exists") then
		local names = { "Inventory", "Pets", "Shop", "Spot", "Stats" }
		local entries = {}
		for _, n in ipairs(names) do
			entries[n] = column:FindFirstChild("Entry_" .. n)
		end
		T.check(entries.Inventory and entries.Pets and entries.Shop and entries.Spot and entries.Stats, "...with five entries: Inventory, Pets, Shop, Spot, Stats")
		local ordered = true
		for i = 2, #names do
			if entries[names[i]] and entries[names[i - 1]] and entries[names[i]].AbsolutePosition.Y <= entries[names[i - 1]].AbsolutePosition.Y then
				ordered = false
			end
		end
		T.check(ordered, "...stacked top to bottom in that order")
		local cx = column.AbsolutePosition.X + column.AbsoluteSize.X / 2
		local cy = column.AbsolutePosition.Y + column.AbsoluteSize.Y / 2
		T.check(cx < vp.X * 0.12, "the column is on the left edge", string.format("centre x %.2f of the screen", cx / vp.X))
		T.check(cy > vp.Y * 0.3 and cy < vp.Y * 0.7, "...vertically centred ('left-centre')", string.format("centre y %.2f of the screen", cy / vp.Y))
		for _, n in ipairs(names) do
			local b = entries[n] and entries[n]:FindFirstChildWhichIsA("TextButton", true)
			T.check(b ~= nil and b.AbsoluteSize.X >= 44 and abs(b.AbsoluteSize.X - b.AbsoluteSize.Y) < 3, "Entry_" .. n .. " is a round icon button (>= 44 px)", b and tostring(b.AbsoluteSize) or "no button")
		end
	end
	T.eq(#visibleWindows(), 0, "no window is open at rest")

	-- Pets window
	clickEntry("Pets")
	T.eq(table.concat(visibleWindows(), ","), "Window_Inventory", "the Pets button opens the Inventory window")
	local inv = windowOf("Window_Inventory")
	if inv and inv.Visible then
		local cxw = inv.AbsolutePosition.X + inv.AbsoluteSize.X / 2
		local cyw = inv.AbsolutePosition.Y + inv.AbsoluteSize.Y / 2
		T.check(abs(cxw - vp.X / 2) < vp.X * 0.05 and abs(cyw - vp.Y / 2) < vp.Y * 0.1, "windows open centred on the screen", string.format("centre %.2f,%.2f", cxw / vp.X, cyw / vp.Y))
		T.check(findText("equipped 2/3", inv) ~= nil, "the Pets tab shows 'Equipped 2/3'", allShownText())
		T.check(findText("inventory", inv) ~= nil, "...in a window titled Inventory")
		local tabsFound = findText("^pets$", inv, true) ~= nil and findText("^items$", inv, true) ~= nil
		T.check(tabsFound, "...with the tabs Pets and Items")
		local grid = descendantNamed(inv, "CloudGrid")
		local slots = {}
		for _, c in ipairs(grid and grid:GetChildren() or {}) do
			if c.Name:find("^Pet_") then
				slots[c.Name] = c
			end
		end
		T.check(slots.Pet_cloudy_dragon and slots.Pet_pebble_pup and slots.Pet_biscuit_bear, "the grid shows a slot for every owned pet (and only those)", (function()
			local n = 0
			for _ in pairs(slots) do
				n = n + 1
			end
			return n .. " slots"
		end)())
		local function slotText(slot)
			local out = {}
			for _, d in ipairs(slot:GetDescendants()) do
				if (d:IsA("TextLabel") or d:IsA("TextButton")) and isShown(d) then
					out[#out + 1] = d.Text
				end
			end
			return table.concat(out, "|")
		end
		T.check(slots.Pet_cloudy_dragon and slotText(slots.Pet_cloudy_dragon):find("x2", 1, true) ~= nil, "...with the stack count (x2)", slots.Pet_cloudy_dragon and slotText(slots.Pet_cloudy_dragon) or "")
		local starOf = slots.Pet_cloudy_dragon and slotText(slots.Pet_cloudy_dragon):find("\226\152\133", 1, true)
		local noStar = slots.Pet_pebble_pup and not slotText(slots.Pet_pebble_pup):find("\226\152\133", 1, true)
		T.check(starOf ~= nil and noStar, "...a star on equipped pets only", (slots.Pet_cloudy_dragon and slotText(slots.Pet_cloudy_dragon) or "") .. " / " .. (slots.Pet_pebble_pup and slotText(slots.Pet_pebble_pup) or ""))
		T.check(slots.Pet_cloudy_dragon and slots.Pet_cloudy_dragon:FindFirstChildWhichIsA("ViewportFrame", true) ~= nil, "...and the pet in a ViewportFrame")
		-- select a pet
		local pick = slots.Pet_pebble_pup and slots.Pet_pebble_pup:FindFirstChildWhichIsA("TextButton", true)
		if T.check(pick ~= nil, "slots are clickable") then
			Mock.Click(pick)
			advance(0.5)
			local def = PetCatalog.Get("pebble_pup")
			T.check(findText(def.Name:lower(), inv) ~= nil and findText(def.Rarity:lower(), inv) ~= nil, "selecting a pet shows its name and rarity in the detail card", allShownText())
			local detail = descendantNamed(inv, "Detail")
			T.check(detail ~= nil and detail:FindFirstChildWhichIsA("ViewportFrame", true) ~= nil, "...with a big spinning pet viewport")
			local perkLines = {}
			for key, value in pairs(def.Perks) do
				perkLines[#perkLines + 1] = PetCatalog.PerkLabel(key, value)
			end
			local shown = true
			for _, line in ipairs(perkLines) do
				shown = shown and findText(line:lower(), inv) ~= nil
			end
			T.check(shown, "...and its perks (PetCatalog.PerkLabel)", table.concat(perkLines, " / "))
			local mark = #serverCalls("EquipPet")
			local equip = descendantNamed(inv, "Equip")
			if T.check(equip ~= nil and equip:IsA("TextButton") and isShown(equip), "an Equip button is shown for an unequipped pet") then
				Mock.Click(equip)
				advance(0.2)
				local calls = callsAfter("EquipPet", mark)
				T.check(#calls == 1 and calls[1].args[1] == "pebble_pup", "Equip fires Remotes.EquipPet(petId)", #calls .. " calls")
			end
			-- an equipped pet offers Unequip
			local pick2 = slots.Pet_biscuit_bear and slots.Pet_biscuit_bear:FindFirstChildWhichIsA("TextButton", true)
			if pick2 then
				Mock.Click(pick2)
				advance(0.5)
				local un = descendantNamed(inv, "Unequip")
				local mark2 = #serverCalls("UnequipPet")
				if T.check(un ~= nil and isShown(un), "an equipped pet offers an Unequip button") then
					Mock.Click(un)
					advance(0.2)
					local calls = callsAfter("UnequipPet", mark2)
					T.check(#calls == 1 and calls[1].args[1] == "biscuit_bear", "Unequip fires Remotes.UnequipPet(petId)", #calls .. " calls")
				end
			end
		end
		-- items tab
		local itemsTab = descendantNamed(inv, "Tab_Items")
		if itemsTab then
			Mock.Click(itemsTab)
			advance(0.4)
			local rows = {}
			for _, def in ipairs(ItemCatalog.List) do
				rows[def.Id] = descendantNamed(inv, "Row_" .. def.Id)
			end
			T.check(rows.heal_cloud and rows.shield_bubble and rows.phoenix_feather, "the Items tab has a row for each item")
			T.check(rows.heal_cloud and findText("heal cloud", rows.heal_cloud) ~= nil and findText("x2", rows.heal_cloud) ~= nil, "...with its name and the carried count", rows.heal_cloud and allShownText() or "")
			T.check(rows.heal_cloud and findText("30", rows.heal_cloud) ~= nil, "...and the price")
		else
			T.fail("the Inventory window has an Items tab (Tab_Items)")
		end
	end

	-- one window at a time + Esc + toggle
	clickEntry("Shop")
	T.eq(table.concat(visibleWindows(), ","), "Window_Shop", "opening the Shop closes the Inventory (one window at a time)")
	press("Escape")
	advance(0.5)
	T.eq(#visibleWindows(), 0, "Esc closes the open window")
	clickEntry("Stats")
	T.eq(table.concat(visibleWindows(), ","), "Window_Stats", "the Stats button opens the Stats window")
	clickEntry("Stats")
	T.eq(#visibleWindows(), 0, "pressing the menu button again closes its window")
	clickEntry("Stats")
	local closeX = windowOf("Window_Stats") and descendantNamed(windowOf("Window_Stats"), "Close")
	if T.check(closeX ~= nil, "windows have a red X") then
		Mock.Click(closeX)
		advance(0.5)
		T.eq(#visibleWindows(), 0, "...which closes them")
	end

	-- Stats
	clickEntry("Stats")
	local stats = windowOf("Window_Stats")
	if stats and stats.Visible then
		local function tile(name)
			local t = descendantNamed(stats, "Tile_" .. name)
			local v = t and t:FindFirstChild("Value")
			return v and v.Text
		end
		T.eq(tile("Matches"), "12", "Stats: matches played")
		T.eq(tile("Wins"), "7", "Stats: victories")
		T.eq(tile("WinRate"), "58%", "Stats: win rate (7 of 12)")
		T.check(tostring(tile("Earned")):find("900") ~= nil, "Stats: tokens earned", tostring(tile("Earned")))
		T.eq(tile("Spins"), "5", "Stats: roulette spins")
		T.check(tostring(tile("Found")):find("3") ~= nil and tostring(tile("Found")):find("26") ~= nil, "Stats: pets discovered 3 / 26", tostring(tile("Found")))
		for _, diff in ipairs(Config.Difficulties) do
			T.check(descendantNamed(stats, "Row_" .. diff.Id) ~= nil, "Stats: a best-time row for " .. diff.Id)
		end
		T.check(findText("2:03", stats) ~= nil, "Stats: the best Easy time (2:03)")
		T.check(findText("+12% max health", stats) ~= nil, "Stats: the pet perks", allShownText())
	end
	press("Escape")
	advance(0.5)

	-- Spot button
	local mark = #serverCalls("GoToSpot")
	clickEntry("Spot")
	T.eq(#serverCalls("GoToSpot"), mark + 1, "the Spot button fires Remotes.GoToSpot")
	T.eq(#visibleWindows(), 0, "...without opening a window")

	-- Shop: roulettes
	clickEntry("Shop")
	local shop = windowOf("Window_Shop")
	if shop and shop.Visible then
		T.check(findText("cloud shop", shop) ~= nil, "the Shop window is titled 'Cloud Shop'")
		T.check(findText("☁ 600", shop) ~= nil or findText("600", shop) ~= nil, "...and shows the token balance", allShownText())
		local cards = {}
		for _, r in ipairs(Config.Roulettes) do
			cards[r.Id] = descendantNamed(shop, "Roulette_" .. r.Id)
			T.check(cards[r.Id] ~= nil, "a card for the " .. r.DisplayName)
			if cards[r.Id] then
				T.check(findText(r.DisplayName:lower(), cards[r.Id]) ~= nil and hasNumber(cards[r.Id], r.Price), r.Id .. ": name and price (" .. r.Price .. ")")
			end
		end
		local order = true
		for i = 2, #Config.Roulettes do
			local a, b = cards[Config.Roulettes[i - 1].Id], cards[Config.Roulettes[i].Id]
			if a and b and b.AbsolutePosition.X <= a.AbsolutePosition.X then
				order = false
			end
		end
		T.check(order, "...in price order from left to right")
		local cloudSpin = cards.Cloud and descendantNamed(cards.Cloud, "Spin")
		local celestialSpin = cards.Celestial and descendantNamed(cards.Celestial, "Spin")
		T.check(cloudSpin and cloudSpin:GetAttribute("Disabled") ~= true and cloudSpin.Active ~= false, "Spin is enabled when the player can pay (600 >= 50)")
		T.check(celestialSpin and (celestialSpin:GetAttribute("Disabled") == true or celestialSpin.Active == false), "...and disabled when tokens are short (600 < 5000)")
		local m0 = #serverCalls("BuyRoulette")
		if celestialSpin then
			Mock.Click(celestialSpin)
			advance(0.3)
		end
		T.eq(#serverCalls("BuyRoulette"), m0, "clicking a disabled Spin sends nothing")
		if cloudSpin then
			Mock.Click(cloudSpin)
			advance(0.3)
		end
		local buy = callsAfter("BuyRoulette", m0)
		T.check(#buy == 1 and buy[1].args[1] == "Cloud", "clicking Spin fires Remotes.BuyRoulette(rouletteId)", #buy .. " calls")
		-- odds popup
		local odds = cards.Sky and descendantNamed(cards.Sky, "Odds")
		if T.check(odds ~= nil, "each card has an Odds button") then
			Mock.Click(odds)
			advance(0.5)
			local popup = menu:FindFirstChild("OddsPopup")
			T.check(popup ~= nil and popup.Visible, "the Odds button opens a popup")
			local list = PetCatalog.GetOdds("Sky")
			local percentOk, sum, missing = 0, 0, 0
			for _, o in ipairs(list) do
				local cell = popup and descendantNamed(popup, "Cell_" .. o.PetId)
				local label = cell and descendantNamed(cell, "Percent")
				local shown = label and tonumber((tostring(label.Text):gsub("%%", "")))
				if shown == nil then
					missing = missing + 1
				elseif abs(shown - o.Chance * 100) <= 0.06 then
					percentOk = percentOk + 1
				end
				sum = sum + o.Chance * 100
			end
			T.check(missing == 0 and percentOk == #list, "...with every possible pet and its chance in percent (PetCatalog.GetOdds)", missing .. " pets missing, " .. percentOk .. " of " .. #list .. " chances right")
			local totals = 0
			for _, d in ipairs(popup and popup:GetDescendants() or {}) do
				if d.Name == "Chance" and d:IsA("TextLabel") then
					totals = totals + (tonumber((tostring(d.Text):match("^([%d%.]+)%%"))) or 0)
				end
			end
			T.check(abs(totals - 100) < 0.6, "...and the rarity totals add up to 100%", fmt(totals, 2))
			press("Escape")
			advance(0.5)
		end
		-- items
		local tab = descendantNamed(shop, "Tab_Items")
		if tab then
			Mock.Click(tab)
			advance(0.4)
			for _, def in ipairs(ItemCatalog.List) do
				local card = descendantNamed(shop, "Item_" .. def.Id)
				if T.check(card ~= nil, "an item card for " .. def.Name) then
					T.check(findText(def.Name:lower(), card) ~= nil and hasNumber(card, def.Price), def.Id .. ": name and price (" .. def.Price .. ")")
					local buyBtn = descendantNamed(card, "Buy")
					local b0 = #serverCalls("BuyItem")
					if buyBtn then
						advance(0.4) -- the menu spaces two sends of one remote by 0.3 s
						Mock.Click(buyBtn)
						advance(0.4)
					end
					local calls = callsAfter("BuyItem", b0)
					local hintLabel = descendantNamed(card, "Hint")
					T.check(#calls == 1 and calls[1].args[1] == def.Id and (calls[1].args[2] == nil or calls[1].args[2] == 1), "Buy fires Remotes.BuyItem(" .. def.Id .. ", 1)",
						#calls .. " calls; Buy disabled=" .. tostring(buyBtn and buyBtn:GetAttribute("Disabled")) .. ", hint '" .. tostring(hintLabel and hintLabel.Text) .. "', in bag " .. KC.M.State.ItemCount(def.Id) .. ", tokens " .. KC.M.State.Tokens())
				end
			end
		else
			T.fail("the Shop has an Items tab (Tab_Items)")
		end
	end
	press("Escape")
	advance(0.5)

	-- OpenPanel remote
	toClient("OpenPanel", "Shop", { Tab = "Roulette", RouletteId = "Storm" })
	advance(0.6)
	T.eq(table.concat(visibleWindows(), ","), "Window_Shop", "OpenPanel('Shop', { Tab = 'Roulette' }) opens the Shop")
	local page = windowOf("Window_Shop") and descendantNamed(windowOf("Window_Shop"), "Page_Roulettes")
	T.check(page ~= nil and page.Visible, "...on the Roulettes tab")
	toClient("OpenPanel", "Shop", { Tab = "Items" })
	advance(0.6)
	local itemsPage = windowOf("Window_Shop") and descendantNamed(windowOf("Window_Shop"), "Page_Items")
	T.check(itemsPage ~= nil and itemsPage.Visible, "OpenPanel('Shop', { Tab = 'Items' }) shows the Items tab")
	press("Escape")
	advance(0.5)
	toClient("OpenPanel", "NoSuchPanel", nil)
	toClient("OpenPanel", 5, 5)
	advance(0.3)
	T.eq(#visibleWindows(), 0, "OpenPanel with an unknown panel id is ignored")
	-- during a match no shop window
	LocalPlayer:SetAttribute("InMatch", true)
	advance(0.3)
	toClient("OpenPanel", "Shop", { Tab = "Items" })
	advance(0.6)
	T.eq(#visibleWindows(), 0, "OpenPanel('Shop') is ignored during a match")
	LocalPlayer:SetAttribute("InMatch", false)
	clickEntry("Pets")
	T.eq(#visibleWindows(), 1, "a window is open...")
	LocalPlayer:SetAttribute("InMatch", true)
	advance(0.6)
	T.eq(#visibleWindows(), 0, "...and every window closes when a match starts")
	LocalPlayer:SetAttribute("InMatch", false)
	advance(0.3)

	-- roulette result: spin strip, reveal card
	local rid = "Cloud"
	local possible = PetCatalog.PossiblePets(rid)
	local strip = {}
	for i = 1, 40 do
		strip[i] = possible[(i % #possible) + 1].Id
	end
	local winner = possible[1].Id
	strip[34] = winner
	local guiBefore = countGui()
	toClient("RouletteResult", { Ok = true, RouletteId = rid, PetId = winner, IsNew = true, Count = 1, Tokens = 550, Strip = strip })
	advance(0.8)
	local peakViewports = 0
	for _ = 1, 40 do
		advance(0.25)
		local n = 0
		for _, d in ipairs(gui():GetDescendants()) do
			if d:IsA("ViewportFrame") then
				n = n + 1
			end
		end
		peakViewports = max(peakViewports, n)
	end
	local winnerDef = PetCatalog.Get(winner)
	T.check(findText(winnerDef.Name:lower()) ~= nil, "the roulette reveal names the won pet", allShownText())
	T.check(findText("new!") ~= nil or findText("new") ~= nil, "...and flags it NEW!", allShownText())
	T.check(peakViewports <= 40, "the spin strip never builds all 40 viewports at once", "peak " .. peakViewports .. " viewports")
	local revealEquip
	for _, d in ipairs(gui():GetDescendants()) do
		if d:IsA("TextButton") and d.Text:lower():find("equip") and isShown(d) and not d.Name:find("Unequip") and d.Text:lower() ~= "unequip" then
			revealEquip = d
		end
	end
	if T.check(revealEquip ~= nil, "the reveal card offers an Equip button") then
		local e0 = #serverCalls("EquipPet")
		Mock.Click(revealEquip)
		advance(0.3)
		local calls = callsAfter("EquipPet", e0)
		T.check(#calls == 1 and calls[1].args[1] == winner, "...which fires Remotes.EquipPet(won pet)", #calls .. " calls")
	end
	press("Escape")
	advance(0.6)
	press("Escape")
	advance(0.6)
	-- failures and junk never raise
	toClient("RouletteResult", { Ok = false, Reason = "Not enough cloud tokens", RouletteId = rid, Tokens = 10 })
	toClient("RouletteResult", { Ok = true, RouletteId = rid, PetId = winner, IsNew = false, Count = 3, Tokens = 5 })
	toClient("RouletteResult", "junk")
	toClient("RouletteResult", { Ok = true, RouletteId = "NoSuchRoulette", PetId = "ghost", Strip = {} })
	advance(8)
	press("Escape")
	advance(0.6)
	press("Escape")
	advance(0.6)
	T.check(true, "failed, short and malformed RouletteResults do not raise")

	-- rebuilds from State without leaks
	clickEntry("Pets")
	advance(0.5)
	local baseline = countGui()
	for i = 1, 25 do
		toClient("ProfileSync", snapshot({ Tokens = 600 + i }))
		advance(0.1)
	end
	advance(0.5)
	T.check(countGui() <= baseline + 30, "re-rendering on State.Changed does not leak GUI objects (25 syncs)", baseline .. " -> " .. countGui())
	press("Escape")
	advance(0.6)
	-- no stale slots after a pet is gone
	clickEntry("Pets")
	toClient("ProfileSync", snapshot({ Pets = { cloudy_dragon = 1 }, Equipped = { "cloudy_dragon" } }))
	advance(0.6)
	local inv2 = windowOf("Window_Inventory")
	local staleCount = 0
	for _, c in ipairs(inv2 and descendantNamed(inv2, "CloudGrid") and descendantNamed(inv2, "CloudGrid"):GetChildren() or {}) do
		if c.Name:find("^Pet_") then
			staleCount = staleCount + 1
		end
	end
	T.eq(staleCount, 1, "no stale slots: after the profile shrinks the grid shows only the owned pet")
	press("Escape")
	advance(0.6)
	feed()
	T.check(Menu and type(Menu.Open) == "function" and type(Menu.Close) == "function", "MenuController.Open / Close are public")
	flushErrors("client_menu")
	flushWarnings("client_menu")
end)

----------------------------------------------------------------------------------------------------
-- scenario: the hotbar
----------------------------------------------------------------------------------------------------
S.client_hotbar = guarded("client_hotbar", function()
	local Config = env()
	local ItemCatalog = require(Mock.GetPath(ROOTS["shared"] .. "/ItemCatalog"))
	local HB = M.HotbarController
	local g = gui():FindFirstChild("NimbusHotbar")
	if not T.check(g ~= nil and g:IsA("ScreenGui"), "HotbarController builds the ScreenGui 'NimbusHotbar'") then
		return
	end
	resetMatchState()
	feed({ Items = { heal_cloud = 2, phoenix_feather = 1 } })
	local vp = Mock.Viewport
	T.eq(g.DisplayOrder, 11, "its DisplayOrder is 11")
	local bar = g:FindFirstChild("Hotbar")
	local slots = {}
	for i = 1, Config.Items.HotbarSlots do
		slots[i] = bar and bar:FindFirstChild("Hotbar" .. i)
	end
	T.check(slots[1] and slots[2] and slots[3] and slots[4], "four slots Hotbar1 .. Hotbar4")
	if bar then
		local cx = bar.AbsolutePosition.X + bar.AbsoluteSize.X / 2
		T.check(abs(cx - vp.X / 2) < vp.X * 0.03, "the bar is centred horizontally", string.format("%.2f", cx / vp.X))
		T.check(bar.AbsolutePosition.Y + bar.AbsoluteSize.Y > vp.Y * 0.88, "...at the bottom of the screen", string.format("bottom at %.2f", (bar.AbsolutePosition.Y + bar.AbsoluteSize.Y) / vp.Y))
	end
	local function glyph(slot)
		local d = slot and descendantNamed(slot, "Glyph")
		return d and d.Text
	end
	local function count(slot)
		local d = slot and descendantNamed(slot, "Count")
		return d and d.Text, d and isShown(d)
	end
	for i, def in ipairs(ItemCatalog.List) do
		T.eq(glyph(slots[i]), def.Glyph, "slot " .. i .. " shows the glyph of " .. def.Id .. " (ItemCatalog.List order)")
	end
	T.check(glyph(slots[4]) ~= nil and glyph(slots[4]) ~= glyph(slots[1]), "slot 4 is a locked placeholder", tostring(glyph(slots[4])))
	T.check(count(slots[1]) == "x2" and count(slots[2]) == "x0" and count(slots[3]) == "x1", "counts come from State (x2, x0, x1)", tostring(count(slots[1])) .. "," .. tostring(count(slots[2])) .. "," .. tostring(count(slots[3])))
	for i = 1, 4 do
		local key = slots[i] and descendantNamed(slots[i], "Key")
		T.eq(key and key.Text, tostring(i), "slot " .. i .. " is labelled with the key " .. i)
	end
	local function dimmed(slot)
		local d = slot and descendantNamed(slot, "Dim")
		return d and isShown(d)
	end
	T.check(dimmed(slots[1]) == true, "in the lobby the item slots are dimmed (items only work in matches)")
	local mark = #serverCalls("UseItem")
	press("One")
	advance(0.2)
	T.eq(#serverCalls("UseItem"), mark, "pressing 1 in the lobby sends nothing")
	local hint = bar and descendantNamed(bar, "Hint")
	T.check(hint ~= nil and isShown(hint) and findText("match", bar, false) ~= nil, "...it explains why instead ('Items only work during a match')", allShownText())

	-- in a match
	LocalPlayer:SetAttribute("InMatch", true)
	advance(0.5)
	T.check(dimmed(slots[1]) == false, "in a match a slot with items is lit")
	T.check(dimmed(slots[2]) == true, "...an empty one stays dimmed")
	mark = #serverCalls("UseItem")
	press("One")
	advance(0.2)
	local calls = callsAfter("UseItem", mark)
	T.check(#calls == 1 and calls[1].args[1] == "heal_cloud", "key 1 fires Remotes.UseItem('heal_cloud')", #calls .. " calls")
	local cool = slots[1] and descendantNamed(slots[1], "Cooldown")
	T.check(cool ~= nil and isShown(cool), "...and a cooldown bar runs on the slot")
	press("One")
	advance(0.1)
	T.eq(#callsAfter("UseItem", mark), 1, "pressing again during the cooldown does nothing")
	advance(1.2)
	press("One")
	advance(0.1)
	T.eq(#callsAfter("UseItem", mark), 2, "...and works again after it")
	advance(1.2)
	mark = #serverCalls("UseItem")
	press("Two")
	advance(0.2)
	T.eq(#callsAfter("UseItem", mark), 0, "an item the player does not have is not sent (x0)")
	press("Four")
	advance(0.2)
	T.eq(#callsAfter("UseItem", mark), 0, "the locked slot 4 sends nothing")
	press("Three", true)
	advance(0.2)
	T.eq(#callsAfter("UseItem", mark), 0, "keys already used by the game (processed) are ignored")
	press("KeypadThree")
	advance(0.2)
	local c3 = callsAfter("UseItem", mark)
	T.check(#c3 == 1 and c3[1].args[1] == "phoenix_feather", "the keypad works too (KeypadThree -> phoenix_feather)", #c3 .. " calls")
	advance(1.2)
	-- tap / click
	mark = #serverCalls("UseItem")
	local button = slots[1] and slots[1]:FindFirstChild("Button")
	if button then
		Mock.Click(button)
		advance(0.2)
	end
	T.eq(#callsAfter("UseItem", mark), 1, "tapping a slot uses the item as well")
	-- downed
	advance(1.2)
	LocalPlayer:SetAttribute("Downed", true)
	advance(0.4)
	mark = #serverCalls("UseItem")
	press("One")
	advance(0.2)
	T.eq(#callsAfter("UseItem", mark), 0, "a downed player cannot use items (nothing is sent)")
	T.check(dimmed(slots[1]) == true, "...and the slots are dimmed")
	LocalPlayer:SetAttribute("Downed", false)
	LocalPlayer:SetAttribute("InMatch", false)
	advance(0.4)
	-- the API
	T.check(HB and type(HB.UseSlot) == "function", "HotbarController.UseSlot(index) is public")
	mark = #serverCalls("UseItem")
	LocalPlayer:SetAttribute("InMatch", true)
	advance(0.4)
	HB.UseSlot(1)
	advance(0.2)
	T.eq(#callsAfter("UseItem", mark), 1, "UseSlot(1) fires UseItem like the key does")
	HB.UseSlot(9)
	T.check(true, "UseSlot of a missing slot is harmless")
	LocalPlayer:SetAttribute("InMatch", false)
	-- counts follow the profile
	feed({ Items = { heal_cloud = 5 } })
	T.eq((count(slots[1])), "x5", "counts follow ProfileSync (x5)")
	feed()
	flushErrors("client_hotbar")
	flushWarnings("client_hotbar")
end)

----------------------------------------------------------------------------------------------------
-- scenario: pet followers
----------------------------------------------------------------------------------------------------
S.client_pets = guarded("client_pets", function()
	local Config = env()
	local PC = require(Mock.GetPath(ROOTS["shared"] .. "/PetCatalog"))
	local PetController = M.PetController
	if not T.check(PetController ~= nil, "PetController loads") then
		return
	end
	local function folder()
		return workspace:FindFirstChild("ClientPets")
	end
	local function modelsOf(player)
		local f = folder() and folder():FindFirstChild(tostring(player.UserId))
		local out = {}
		for _, c in ipairs(f and f:GetChildren() or {}) do
			if c:IsA("Model") then
				out[#out + 1] = c
			end
		end
		return out
	end
	local function myRoot()
		return KC.root()
	end
	local function distanceTo(model, root)
		return (model:GetPivot().Position - root.Position).Magnitude
	end
	T.check(folder() ~= nil, "workspace.ClientPets exists")
	T.eq(PetController.GetPetCount(), 0, "no pets without an EquippedPets attribute")
	local dragon, bear, pup = "cloudy_dragon", "biscuit_bear", "pebble_pup"
	LocalPlayer:SetAttribute("EquippedPets", dragon .. "," .. bear)
	advance(1.5)
	T.eq(PetController.GetPetCount(), 2, "EquippedPets 'cloudy_dragon,biscuit_bear' makes two followers")
	local mine = modelsOf(LocalPlayer)
	T.eq(#mine, 2, "...in workspace.ClientPets/<UserId>")
	if #mine == 2 then
		local ok = true
		for _, m in ipairs(mine) do
			ok = ok and m:FindFirstChild("WingL", true) ~= nil and m.PrimaryPart ~= nil
			for _, d in ipairs(m:GetDescendants()) do
				if d:IsA("BasePart") and (d.CanCollide or d.CanTouch or d.CanQuery or not d.Anchored) then
					ok = false
				end
			end
		end
		T.check(ok, "...PetBuilder models with wings, visual only (no collision / touch / query, anchored)")
		-- they hover beside the owner
		local root = myRoot()
		advance(3)
		local close = true
		local detail = {}
		for _, m in ipairs(mine) do
			local off = m:GetPivot().Position - root.Position
			local horiz = math.sqrt(off.X * off.X + off.Z * off.Z)
			detail[#detail + 1] = string.format("%.1f/%.1f", horiz, off.Y)
			if horiz < 2 or horiz > 7 or off.Y < -1 or off.Y > 5 then
				close = false
			end
		end
		T.check(close, "followers hover 2-7 studs beside and up to 5 studs above the owner", table.concat(detail, " "))
		if #mine == 2 then
			T.check((mine[1]:GetPivot().Position - mine[2]:GetPivot().Position).Magnitude > 1.5, "...each in its own slot (not on top of each other)")
		end
		-- motion: the owner walks, the pets follow with easing
		local start = root.Position
		for step = 1, 30 do
			Mock.Teleport(LocalPlayer, start + Vector3.new(step * 1.2, 0, 0))
			advance(0.05)
		end
		advance(0.1)
		local lag = distanceTo(mine[1], myRoot())
		T.check(lag < 12, "followers keep up with a walking owner", string.format("%.1f studs behind", lag))
		advance(3)
		T.check(distanceTo(mine[1], myRoot()) < 8, "...and settle beside the owner again", string.format("%.1f studs", distanceTo(mine[1], myRoot())))
		-- teleport far: pets snap to the owner instead of flying across the map
		Mock.Teleport(LocalPlayer, myRoot().Position + Vector3.new(400, 120, -300))
		advance(0.4)
		T.check(distanceTo(mine[1], myRoot()) < 12 and distanceTo(mine[2], myRoot()) < 12, "after a teleport the pets are back at the owner within 0.4 s", string.format("%.1f / %.1f", distanceTo(mine[1], myRoot()), distanceTo(mine[2], myRoot())))
		-- no per-frame garbage: the number of instances stays flat
		local before = Mock.CountDescendants(folder())
		advance(5)
		T.eq(Mock.CountDescendants(folder()), before, "followers allocate no instances while they fly")
	end

	-- changing the list
	LocalPlayer:SetAttribute("EquippedPets", dragon .. ",ghost_pet,," .. pup)
	advance(1.5)
	T.eq(PetController.GetPetCount(), 2, "ids unknown to PetCatalog (and empty entries) are ignored")
	LocalPlayer:SetAttribute("EquippedPets", dragon .. "," .. bear .. "," .. pup .. ",biscuit_bear,cloudy_dragon")
	advance(1.5)
	T.check(PetController.GetPetCount() <= Config.Pets.MaxEquipped, "at most Config.Pets.MaxEquipped (" .. Config.Pets.MaxEquipped .. ") followers are drawn", tostring(PetController.GetPetCount()))
	LocalPlayer:SetAttribute("EquippedPets", dragon)
	advance(1.5)
	T.eq(PetController.GetPetCount(), 1, "unequipping removes the follower")
	T.eq(#modelsOf(LocalPlayer), 1, "...and destroys its model")
	LocalPlayer:SetAttribute("EquippedPets", "")
	advance(1.0)
	T.eq(PetController.GetPetCount(), 0, "an empty list removes every follower")
	T.eq(#modelsOf(LocalPlayer), 0, "...and models")

	-- respawn: pets are rebuilt for the new character
	LocalPlayer:SetAttribute("EquippedPets", dragon .. "," .. bear)
	advance(1.5)
	Mock.Kill(LocalPlayer)
	advance(0.8)
	local mid = PetController.GetPetCount()
	Mock.Respawn(LocalPlayer)
	advance(2.5)
	T.eq(PetController.GetPetCount(), 2, "after the owner respawns the pets are rebuilt (2 followers)")
	T.check(mid <= 2, "...and never duplicated while the character was gone", tostring(mid))
	local newRoot = myRoot()
	local mineAfter = modelsOf(LocalPlayer)
	T.check(#mineAfter == 2 and distanceTo(mineAfter[1], newRoot) < 12, "...beside the NEW character", mineAfter[1] and string.format("%.1f studs", distanceTo(mineAfter[1], newRoot)) or "no model")

	-- other players: shown when near, culled when far, removed when they leave
	local other = Mock.AddPlayer("Friend", 6001)
	advance(1.0)
	local friendRoot = Mock.GetRoot(other)
	Mock.Teleport(other, myRoot().Position + Vector3.new(30, 0, 0))
	other:SetAttribute("EquippedPets", pup .. "," .. dragon)
	advance(2.0)
	T.eq(#modelsOf(other), 2, "another player's pets are drawn too (EquippedPets of every player)")
	Mock.Teleport(other, myRoot().Position + Vector3.new(400, 0, 0))
	advance(2.0)
	T.eq(#modelsOf(other), 0, "...but only within ~150 studs: far players' pets are culled")
	T.check(PetController.GetPetCount() >= 2, "(the local player's pets are always drawn)", tostring(PetController.GetPetCount()))
	Mock.Teleport(other, myRoot().Position + Vector3.new(60, 0, 0))
	advance(2.0)
	T.eq(#modelsOf(other), 2, "...and come back when the player is close again")
	Mock.RemovePlayer(other)
	advance(1.5)
	T.check(folder() and folder():FindFirstChild("6001") == nil, "a player who leaves takes their pets with them")
	-- far away local player: always rendered
	Mock.Teleport(LocalPlayer, Vector3.new(9000, 500, 9000))
	advance(1.5)
	T.eq(#modelsOf(LocalPlayer), 2, "the local player's pets are drawn wherever they are")

	-- Stop
	local before = Mock.CountDescendants(workspace)
	PetController.Stop()
	advance(0.5)
	T.eq(PetController.GetPetCount(), 0, "PetController.Stop() removes every follower")
	T.check(Mock.CountDescendants(workspace) < before, "...and their models")
	LocalPlayer:SetAttribute("EquippedPets", dragon)
	advance(1.0)
	T.eq(PetController.GetPetCount(), 0, "...and stops reacting to attribute changes")
	PetController.Init()
	advance(1.5)
	T.eq(PetController.GetPetCount(), 1, "Init() after Stop() starts again")
	LocalPlayer:SetAttribute("EquippedPets", "")
	advance(1.0)
	Mock.Teleport(LocalPlayer, Vector3.new(0, 20, 0))
	advance(0.5)
	flushErrors("client_pets")
	flushWarnings("client_pets")
end)

----------------------------------------------------------------------------------------------------
-- scenario: the "nothing in the middle of the screen" rule
----------------------------------------------------------------------------------------------------
-- Drives every kind of system message the HUD / Notify / Menu controllers can show and asserts that no text
-- sits within centreTolerance of the screen centre, and that each kind lives where the layout map puts it.
-- product of the UIScales on the way up: design pixels = absolute pixels / scale
local function scaleOf(inst)
	local scale = 1
	local cur = inst
	while cur and cur ~= game do
		if cur:IsA("GuiObject") then
			for _, c in ipairs(cur:GetChildren()) do
				if c:IsA("UIScale") and c.Name ~= "FxScale" and c.Name ~= "Pop" then
					scale = scale * c.Scale
				end
			end
		end
		cur = cur.Parent
	end
	return scale
end

local function layoutRule(label)
	local Config = env()
	local tol = CONTRACT.v2.centreTolerance
	local vp = Mock.Viewport
	local function check(state)
		local list = centredTexts(tol)
		T.check(#list == 0, label .. ": nothing is shown in the middle of the screen (" .. state .. ")", describeCentred(list))
	end
	local function zoneOf(inst)
		return (inst.AbsolutePosition.X + inst.AbsoluteSize.X / 2) / vp.X, (inst.AbsolutePosition.Y + inst.AbsoluteSize.Y / 2) / vp.Y
	end
	resetMatchState()
	feed()
	advance(1.0)
	check("at rest in the lobby")

	-- HP / token pill / menu column / hotbar sit at their corners
	local vitals = gui().NimbusHud.BottomLeft:FindFirstChild("Vitals")
	local pill = gui().NimbusHud.TopRight:FindFirstChild("TokenPill")
	if vitals then
		local x, y = zoneOf(vitals)
		T.check(x < 0.45 and y > 0.6, label .. ": the HP bar is bottom-left", string.format("centre %.2f,%.2f", x, y))
	end
	if pill then
		local x, y = zoneOf(pill)
		T.check(x > 0.55 and y < 0.2, label .. ": the token pill is top-right", string.format("centre %.2f,%.2f", x, y))
	end

	-- toasts
	for i = 1, 6 do
		toClient("Notify", "Toast number " .. i .. " with a longer text to check wrapping", ({ "info", "good", "bad", "token" })[i % 4 + 1], 8)
		advance(0.15)
	end
	advance(0.8)
	check("six toasts")
	local toasts = {}
	for _, d in ipairs(texts(nil, true)) do
		if tostring(d.Text):find("^Toast number") then
			toasts[#toasts + 1] = d
		end
	end
	T.check(#toasts >= 1 and #toasts <= 4, label .. ": at most 4 toasts are stacked", #toasts .. " shown")
	local allRight, smallText, narrow = true, true, true
	for _, d in ipairs(toasts) do
		local x = zoneOf(d)
		allRight = allRight and x > 0.6
		smallText = smallText and d.TextSize >= 13 and d.TextSize <= 18
		narrow = narrow and d.AbsoluteSize.X / scaleOf(d) <= 252
	end
	T.check(allRight, label .. ": toasts stack along the right edge", #toasts > 0 and string.format("first at x %.2f", zoneOf(toasts[1])) or "none")
	T.check(smallText, label .. ": toast text is small (14-17 px)", #toasts > 0 and tostring(toasts[1].TextSize) or "none")
	T.check(narrow, label .. ": toasts are at most 250 design px wide", #toasts > 0 and tostring(toasts[1].AbsoluteSize.X) or "none")
	advance(10)

	-- party panel
	toClient("PartyState", {
		PortalId = "Hard", DifficultyName = "Hard", Color = Config.GetDifficulty("Hard").Color,
		Players = { { UserId = LocalPlayer.UserId, Name = LocalPlayer.Name }, { UserId = 77, Name = "Buddy" } }, Max = 4, Countdown = 9,
	})
	advance(1.0)
	check("party panel")
	local startingIn = findText("starting in")
	if startingIn then
		local x, y = zoneOf(startingIn)
		T.check(x < 0.45 and y < 0.3, label .. ": the party status is in the top-left corner", string.format("centre %.2f,%.2f", x, y))
	else
		T.fail(label .. ": the party panel shows 'Starting in Ns'", allShownText())
	end
	toClient("PartyState", nil)
	advance(0.8)

	-- match: countdown, playing, downed, checkpoint toast
	LocalPlayer:SetAttribute("InMatch", true)
	toClient("MatchState", KC.matchState({ Phase = "Countdown", Seconds = 3, Checkpoint = 0, TokensCollected = 0 }))
	advance(0.7)
	check("match countdown '3'")
	local numeral = findText("^3$", gui().NimbusHud, true)
	if numeral then
		local x, y = zoneOf(numeral)
		T.check(x < 0.45 and y < 0.3, label .. ": the countdown numerals are inside the match panel (top-left)", string.format("centre %.2f,%.2f", x, y))
	else
		T.fail(label .. ": the countdown shows the seconds inside the HUD", allShownText())
	end
	toClient("MatchState", KC.matchState({ Phase = "Countdown", Seconds = 1, Checkpoint = 0, TokensCollected = 0 }))
	advance(0.7)
	check("match countdown '1'")
	toClient("MatchState", KC.matchState())
	advance(3.0)
	check("playing")
	toClient("Notify", "Checkpoint 2/4 reached!", "good", 4)
	advance(0.6)
	check("checkpoint toast")
	LocalPlayer:SetAttribute("Downed", true)
	advance(1.0)
	check("downed")
	LocalPlayer:SetAttribute("Downed", false)
	toClient("DamageTaken", 20, "Lightning")
	advance(0.4)
	check("damage flash")
	advance(2.5)
	LocalPlayer:SetAttribute("MatchTokens", 4)
	advance(0.5)
	check("tokens collected")

	-- result card
	toClient("MatchResult", {
		Won = true, Reason = "victory", Seconds = 187, MatchTokens = 11, Bonus = 10, DifficultyId = "Hard", DifficultyName = "Hard", Stars = 3, TotalTokens = 24,
		Members = { { Name = LocalPlayer.Name, MatchTokens = 11, Finished = true, Downed = false }, { Name = "Buddy", MatchTokens = 6, Finished = true, Downed = false } },
	})
	advance(4.5)
	check("victory card")
	local victory = findText("victory")
	if victory then
		local x, y = zoneOf(victory)
		T.check(x > 0.6, label .. ": the result card sits on the right side", string.format("centre %.2f,%.2f", x, y))
		local card = victory
		while card and card.Parent and not card.Name:find("Result") and card.Parent:IsA("GuiObject") do
			card = card.Parent
		end
		local w = card and card:IsA("GuiObject") and card.AbsoluteSize.X / scaleOf(card) or 0
		T.check(w > 0 and w <= 300, label .. ": ...and is compact (at most 300 design px wide)", string.format("%.0f design px", w))
	else
		T.fail(label .. ": the result card shows VICTORY", allShownText())
	end
	toClient("MatchState", nil)
	advance(1.5)
	toClient("MatchResult", {
		Won = false, Reason = "defeat", Seconds = 90, MatchTokens = 2, Bonus = 0, DifficultyId = "Hard", DifficultyName = "Hard", Stars = 3, TotalTokens = 24,
		Members = { { Name = LocalPlayer.Name, MatchTokens = 2, Finished = false, Downed = true } },
	})
	advance(2.5)
	check("defeat card")
	toClient("MatchState", nil)
	LocalPlayer:SetAttribute("InMatch", false)
	LocalPlayer:SetAttribute("MatchTokens", 0)
	advance(2.0)
	check("after the match")

	-- the menu: icons at rest, a window only when the player asks for it
	local before = #centredTexts(tol)
	T.check(before == 0, label .. ": the menu column and hotbar are not in the middle", describeCentred(centredTexts(tol)))
end

S.client_layout_rule = guarded("client_layout_rule", function()
	T.eq(Mock.Viewport.X, 1920, "the client world has a simulated 1920x1080 screen")
	-- self-test: the rule really catches a centred text, and ignores one on the side
	do
		local probe = Instance.new("ScreenGui")
		probe.Name = "SmokeCentre"
		probe.IgnoreGuiInset = true
		probe.Parent = gui()
		local mid = Instance.new("TextLabel")
		mid.Size = UDim2.fromOffset(300, 60)
		mid.AnchorPoint = Vector2.new(0.5, 0.5)
		mid.Position = UDim2.fromScale(0.5, 0.5)
		mid.Text = "GO GO GO"
		mid.Parent = probe
		advance(0.1)
		T.check(#centredTexts(CONTRACT.v2.centreTolerance) >= 1, "rule self-test: a label in the screen middle is detected")
		mid.Position = UDim2.fromScale(0.9, 0.1)
		advance(0.1)
		T.check(#centredTexts(CONTRACT.v2.centreTolerance) == 0, "rule self-test: the same label in the top-right corner is fine")
		probe:Destroy()
		advance(0.1)
	end
	layoutRule("1920x1080")
	flushErrors("client_layout_rule")
	flushWarnings("client_layout_rule")
end)

-- also used by client_mobile (390x844)
KC.layoutRule = layoutRule

return S
