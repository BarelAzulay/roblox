-- smoke_client_v2.lua: client scenarios for the v2 UI (ARCHITECTURE_V2.md section 9), run in the client world of
-- tools/smoke.py after smoke_client.lua (which exports its helpers as the global KC):
--   client_ui_kit      CloudUI: every constructor of the kit, chunky style, shared update loop
--   client_state       State: ProfileSync mirror, defaults, sanitising, Changed / Tokens
--   client_menu        MenuController: 6 icon tiles (v3), Inventory / Pets / Shop (roulettes + items) / Stats windows,
--                      the roulette spin + reveal, OpenPanel, Esc, one window at a time; v3 Pet Index window
--                      (IndexController: group tiles, ??? silhouettes, CLAIM -> IndexClaim, Unlocked: x/N, Stormfang art)
--                      and, once the catalog has elements, the element badges (Index cards + detail with Strong vs /
--                      Weak vs, the Elements help card, the Pets panel, the roulette odds list)
--   client_pets        PetController: followers of every player (High / Low detail), culling, snapping, clean-up;
--                      v3 NPC pets (NpcController idle + dialog through ProximityPromptService), the sky dragon and,
--                      once the Storm Altar is built, the client-side hover / pulse of the Stormfang showcase
--   client_hotbar      HotbarController: 4 slots, keys 1-4, dimmed in the lobby, UseItem remote, cooldown
--   client_tokens      TokenFx: the client-side coin spin + bob (rates, amplitude, culling, release of collected coins)
--   client_layout_rule NO text from the HUD / toasts / countdown / party / results / menu / hotbar in the middle of
--                      the screen at 1920x1080 (and, from client_mobile, at 390x844), and the v3 readability rule
--                      (every text on screen >= 15 px at 1920x1080, >= 14 px on phones)
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

-- v3 elements (ARCHITECTURE_V3.md section 11): a pet's element ids the way the game resolves them
-- (PetCatalog.ElementsOf, then GetElements, then def.Element); {} while the catalog has no elements yet
local function petElements(PetCatalog, def)
	if type(def) ~= "table" then
		return {}
	end
	local raw
	if type(PetCatalog.ElementsOf) == "function" then
		local ok, got = pcall(PetCatalog.ElementsOf, def)
		raw = ok and got or nil
	end
	if raw == nil and type(PetCatalog.GetElements) == "function" then
		local ok, got = pcall(PetCatalog.GetElements, def.Id)
		raw = ok and got or nil
	end
	if raw == nil then
		raw = def.Elements or def.Element
	end
	if type(raw) == "string" then
		raw = { raw }
	end
	local out = {}
	for _, e in ipairs(type(raw) == "table" and raw or {}) do
		if type(e) == "string" then
			out[#out + 1] = e
		end
	end
	return out
end

-- the shown element badge of `element` under `root`: a label reading the element name on a pill coloured with
-- Config.Elements.Info[element].Color (the label itself or one of its two closest GUI ancestors); nil when none.
-- `skip(label)` -> true ignores a label (e.g. the badges on the grid cards when the detail view is checked).
local function elementBadge(root, element, skip)
	local Config = KC.env()
	local info = Config.Elements and Config.Elements.Info and Config.Elements.Info[element]
	local want = info and info.Color
	if not root or not want then
		return nil
	end
	local function close(c)
		return typeof(c) == "Color3" and math.sqrt(((c.R - want.R) * 255) ^ 2 + ((c.G - want.G) * 255) ^ 2 + ((c.B - want.B) * 255) ^ 2) <= 45
	end
	for _, d in ipairs(texts(root, true)) do
		if (tostring(d.Text):gsub("<[^>]*>", "")):lower():find(element:lower(), 1, true) and not (skip and skip(d)) then
			local cur, depth = d, 0
			while cur and cur:IsA("GuiObject") and depth <= 2 do
				if cur.BackgroundTransparency < 0.5 and close(cur.BackgroundColor3) then
					return d
				end
				cur, depth = cur.Parent, depth + 1
			end
		end
	end
	return nil
end

-- failure detail for elementBadge: what the labels reading the element name look like (or that there are none)
local function describeBadge(root, element)
	if not root then
		return "no container"
	end
	local out = {}
	for _, d in ipairs(texts(root, true)) do
		if (tostring(d.Text):gsub("<[^>]*>", "")):lower():find(element:lower(), 1, true) and #out < 3 then
			local c = d.BackgroundColor3
			out[#out + 1] = string.format("'%s' background (%d, %d, %d) transparency %.2f", tostring(d.Text), floor(c.R * 255 + 0.5), floor(c.G * 255 + 0.5), floor(c.B * 255 + 0.5), d.BackgroundTransparency)
		end
	end
	return #out > 0 and table.concat(out, "; ") or ("no shown label reads '" .. element .. "'")
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
	-- v3 (ARCHITECTURE_V3.md section 1): the Pet Index + tutorial progress travel in the snapshot
	toClient("ProfileSync", snapshot({ Discovered = { pebble_pup = true, eclipse_dragon = true, junk = "yes" }, IndexClaimed = { Common = true, Rare = false }, Tutorial = { Step = 4, Done = false, Gifted = true } }))
	advance(0.1)
	T.check(State.IsDiscovered("pebble_pup") and State.IsDiscovered("eclipse_dragon"), "v3: State.IsDiscovered reads Discovered")
	T.check(State.IsDiscovered("biscuit_bear"), "v3: ...an owned pet always counts as discovered")
	T.check(not State.IsDiscovered("starlight_unicorn") and not State.IsDiscovered("junk") and not State.IsDiscovered(nil), "v3: ...undiscovered ids and junk values do not")
	T.check(State.IsClaimed("Common") and not State.IsClaimed("Rare") and not State.IsClaimed("Epic") and not State.IsClaimed(nil), "v3: State.IsClaimed reads IndexClaimed (true entries only)")
	if type(State.Tutorial) == "function" then
		local tut = State.Tutorial()
		T.check(type(tut) == "table" and tut.Step == 4 and tut.Gifted == true and tut.Done == false, "v3: State.Tutorial() mirrors the saved tutorial progress")
	end
	toClient("ProfileSync", snapshot({ Discovered = "lots", IndexClaimed = 5, Tutorial = "x" }))
	advance(0.1)
	T.check(not State.IsDiscovered("eclipse_dragon") and not State.IsClaimed("Common"), "v3: messy Discovered / IndexClaimed values are sanitised to empty sets")
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

-- v3: the Pet Index window (IndexController, ARCHITECTURE_V3.md sections 3, 10 and 11), opened from the menu tile.
local function indexWindowChecks(PetCatalog)
	local Config = env()
	local Index, Menu = M.IndexController, M.MenuController
	if not T.check(type(Index) == "table" and type(Index.Open) == "function", "Pet Index: IndexController loaded") then
		return
	end
	local commons = PetCatalog.ListByRarity("Common")
	local discovered = {}
	for _, def in ipairs(commons) do
		discovered[def.Id] = true
	end
	local mythics = PetCatalog.ListByRarity("Mythic")
	local hidden -- an undiscovered Mythic
	for _, def in ipairs(mythics) do
		if def.Id ~= CONTRACT.v2.mascotPetId then
			hidden = def
		end
	end
	-- every Common discovered (claimable), the mascot owned (discovered), the other Mythic not
	feed({ Discovered = discovered, IndexClaimed = {} })
	local opened = {}
	local conn = Menu and Menu.WindowOpened and Menu.WindowOpened:Connect(function(id)
		opened[#opened + 1] = id
	end)
	clickEntry("Index")
	advance(1.2)
	local indexGui = gui():FindFirstChild("NimbusIndex")
	local window = indexGui and descendantNamed(indexGui, "Window_Index")
	T.check(Index.IsOpen and Index.IsOpen() and window ~= nil and isShown(window), "Pet Index: the Index tile opens the Pet Index window (ScreenGui NimbusIndex)")
	T.check(T.contains(opened, "Index"), "Pet Index: ...and MenuController.WindowOpened fires 'Index' (the tutorial listens)", table.concat(opened, ","))
	T.eq(#visibleWindows(), 0, "Pet Index: ...and no menu window is open behind it")
	if not window then
		if conn then
			conn:Disconnect()
		end
		return
	end
	T.check(findText("pet index", window) ~= nil, "Pet Index: the window is titled 'Pet Index'")
	do
		local small, measured = KC.smallTexts(15)
		T.check(#small == 0 and measured > 0, "Pet Index: every text on screen is readable (>= 15 px at 1920x1080)", #small .. " of " .. measured .. " too small: " .. table.concat(small, "; ", 1, math.min(#small, 6)))
	end
	-- one group tile per rarity group with its x/N progress
	local groups = PetCatalog.IndexGroups()
	local tilesOk, missing = true, {}
	for _, group in ipairs(groups) do
		local tile = descendantNamed(window, "Group_" .. group.Id)
		local found = 0
		for _, def in ipairs(group.Pets) do
			if discovered[def.Id] or def.Id == CONTRACT.v2.mascotPetId or def.Id == "pebble_pup" or def.Id == "biscuit_bear" then
				found = found + 1
			end
		end
		local want = found .. "/" .. #group.Pets
		if not tile or findText(want, tile) == nil then
			tilesOk = false
			missing[#missing + 1] = group.Id .. " (" .. want .. ")"
		end
	end
	T.check(tilesOk, "Pet Index: a group tile per rarity (Group_<Id>) showing 'found/N'", table.concat(missing, ", "))
	local total = PetCatalog.TotalCount()
	local unlocked = 0
	for _, def in ipairs(PetCatalog.Pets) do
		if discovered[def.Id] or def.Id == CONTRACT.v2.mascotPetId or def.Id == "pebble_pup" or def.Id == "biscuit_bear" then
			unlocked = unlocked + 1
		end
	end
	T.check(findText("unlocked: " .. unlocked .. "/" .. total, window) ~= nil, "Pet Index: the footer reads 'Unlocked: " .. unlocked .. "/" .. total .. "' (every pet in the catalog)", allShownText():sub(1, 300))
	-- the Mythic group: the mascot is shown by name, the undiscovered Mythic is a black ??? silhouette
	Index.Open("Mythic")
	advance(1.5)
	local mascotTile = descendantNamed(window, "IndexPet_" .. CONTRACT.v2.mascotPetId)
	T.check(mascotTile ~= nil and findText(PetCatalog.Get(CONTRACT.v2.mascotPetId).Name:lower(), mascotTile) ~= nil, "Pet Index: a discovered pet's tile shows its name")
	if hidden then
		local tile = descendantNamed(window, "IndexPet_" .. hidden.Id)
		local vp = tile and tile:FindFirstChildWhichIsA("ViewportFrame", true)
		T.check(tile ~= nil and findText("???", tile) ~= nil and findText(hidden.Name:lower(), tile) == nil, "Pet Index: an undiscovered pet's tile reads '???' (no name)")
		T.check(vp ~= nil and vp.ImageColor3.R == 0 and vp.ImageColor3.G == 0 and vp.ImageColor3.B == 0, "Pet Index: ...over a black silhouette (ViewportFrame.ImageColor3 = 0, 0, 0)", vp and tostring(vp.ImageColor3) or "no viewport")
	end
	local mascotVp = mascotTile and mascotTile:FindFirstChildWhichIsA("ViewportFrame", true)
	T.check(mascotVp ~= nil and mascotVp.ImageColor3.R > 0.9, "Pet Index: discovered pets are drawn in colour")
	-- the claim button: grey for an incomplete group, green CLAIM for a complete one, 'Claimed' when done
	local claim = descendantNamed(window, "Claim")
	local before = #serverCalls("IndexClaim")
	if claim then
		Mock.Click(claim)
		advance(0.3)
	end
	T.eq(#serverCalls("IndexClaim"), before, "Pet Index: CLAIM on an incomplete group sends nothing")
	Index.Open("Common")
	advance(1)
	claim = descendantNamed(window, "Claim")
	T.check(claim ~= nil and isShown(claim) and tostring(claim.Text):upper():find("CLAIM") ~= nil, "Pet Index: a complete group offers CLAIM", claim and claim.Text or "no button")
	T.check(hasNumber(window, Config.Index.Rewards.Common.Tokens), "Pet Index: the rewards box shows the Config.Index reward (" .. Config.Index.Rewards.Common.Tokens .. ")")
	advance(0.7)
	if claim then
		Mock.Click(claim)
		advance(0.3)
	end
	local calls = callsAfter("IndexClaim", before)
	T.check(#calls == 1 and calls[1].args[1] == "Common", "Pet Index: CLAIM fires Remotes.IndexClaim('Common')", #calls .. " calls")
	if claim then
		Mock.Click(claim)
		advance(0.2)
	end
	T.eq(#callsAfter("IndexClaim", before), 1, "Pet Index: ...once (no double send while the server answers)")
	feed({ Discovered = discovered, IndexClaimed = { Common = true } })
	advance(0.5)
	claim = descendantNamed(window, "Claim")
	T.check(claim ~= nil and tostring(claim.Text):lower():find("claimed") ~= nil, "Pet Index: after the server confirms, the button reads 'Claimed'", claim and claim.Text or "")
	-- Stormfang's 2D art banner (Config.Art.StormfangImage) once discovered (ARCHITECTURE_V3.md section 10)
	local storm = PetCatalog.Get(CONTRACT.v3.stormfang.petId)
	if storm then
		local function bannerShown()
			for _, d in ipairs(window:GetDescendants()) do
				if (d:IsA("ImageLabel") or d:IsA("ImageButton")) and d.Image == Config.Art.StormfangImage and isShown(d) then
					return true
				end
			end
			return false
		end
		Index.Open(storm.Rarity)
		advance(1)
		local tile = descendantNamed(window, "IndexPet_" .. storm.Id)
		local pick = tile and (tile:IsA("GuiButton") and tile or tile:FindFirstChildWhichIsA("TextButton", true) or tile:FindFirstChildWhichIsA("ImageButton", true))
		if pick then
			Mock.Click(pick)
			advance(0.5)
		end
		T.check(not bannerShown(), "Pet Index: Stormfang's art banner stays hidden while it is undiscovered")
		local disc = {}
		for k, v in pairs(discovered) do
			disc[k] = v
		end
		disc[storm.Id] = true
		feed({ Discovered = disc, IndexClaimed = { Common = true } })
		advance(0.5)
		if pick then
			Mock.Click(pick)
			advance(0.5)
		end
		T.check(bannerShown(), "Pet Index: once discovered, Stormfang's detail card shows the player's art (Config.Art.StormfangImage)")
	end
	-- v3 elements (ARCHITECTURE_V3.md section 11): coloured element pills on discovered cards (never on ??? cards), the
	-- detail view with "Strong vs X / Weak vs Y", and the "Elements" help card with the whole chart
	local mascotDef = PetCatalog.Get(CONTRACT.v2.mascotPetId)
	local mascotElement = petElements(PetCatalog, mascotDef)[1]
	if mascotElement then
		feed({ Discovered = discovered, IndexClaimed = { Common = true } })
		Index.Open("Mythic")
		advance(1.5)
		local tile = descendantNamed(window, "IndexPet_" .. mascotDef.Id)
		T.check(tile ~= nil and elementBadge(tile, mascotElement) ~= nil, "Pet Index: a discovered pet's card shows its element badge (" .. mascotElement .. ", coloured from Config.Elements.Info)", describeBadge(tile, mascotElement))
		if hidden then
			local hiddenElement = petElements(PetCatalog, hidden)[1]
			local hiddenTile = descendantNamed(window, "IndexPet_" .. hidden.Id)
			T.check(hiddenTile ~= nil and (hiddenElement == nil or findText(hiddenElement:lower(), hiddenTile) == nil), "Pet Index: an undiscovered card does not give away its element", hiddenElement)
		end
		local pick = tile and (tile:IsA("GuiButton") and tile or tile:FindFirstChildWhichIsA("TextButton", true) or tile:FindFirstChildWhichIsA("ImageButton", true))
		if pick then
			Mock.Click(pick)
			advance(0.6)
		end
		-- what the chart says about the mascot's element (Config.Elements.Strong: attacker -> defenders)
		local strongMap = Config.Elements.Strong or {}
		local strong, weak = {}, {}
		for _, e in ipairs(strongMap[mascotElement] or {}) do
			strong[#strong + 1] = e
		end
		for attacker, list in pairs(strongMap) do
			for _, e in ipairs(list) do
				if e == mascotElement then
					weak[#weak + 1] = attacker
				end
			end
		end
		local matchup = {}
		for _, d in ipairs(texts(window, true)) do
			local t = (tostring(d.Text):gsub("<[^>]*>", "")):lower()
			if t:find("strong vs", 1, true) or t:find("weak vs", 1, true) then
				matchup[#matchup + 1] = t
			end
		end
		local joined = table.concat(matchup, "\n")
		local matchupOk = #matchup > 0
		for _, e in ipairs(strong) do
			matchupOk = matchupOk and joined:find("strong vs[^\n/]*" .. e:lower()) ~= nil
		end
		for _, e in ipairs(weak) do
			matchupOk = matchupOk and joined:find("weak vs[^\n/]*" .. e:lower()) ~= nil
		end
		local function onCard(d)
			local cur = d
			while cur and cur ~= window do
				if cur.Name:find("^IndexPet_") then
					return true
				end
				cur = cur.Parent
			end
			return false
		end
		T.check(matchupOk and elementBadge(window, mascotElement, onCard) ~= nil, "Pet Index: the detail view shows the element badge with 'Strong vs " .. table.concat(strong, ", ") .. " / Weak vs " .. table.concat(weak, ", ") .. "'", joined ~= "" and joined or allShownText():sub(1, 300))
		-- the Elements help card: every element of the chart (opened by its button when it is not shown already)
		local function missingElements()
			local out = {}
			for _, e in ipairs(Config.Elements.Order or {}) do
				if not findText(e:lower(), window) then
					out[#out + 1] = e
				end
			end
			return out
		end
		local helpButton
		for _, d in ipairs(window:GetDescendants()) do
			if d:IsA("GuiButton") and isShown(d) and (d.Name == "Elements" or (d:IsA("TextButton") and (tostring(d.Text):gsub("<[^>]*>", "")):lower():find("^%s*elements%s*$") ~= nil)) then
				helpButton = d
				break
			end
		end
		local toggled = false
		if #missingElements() > 0 and helpButton then
			Mock.Click(helpButton)
			advance(0.6)
			toggled = true
		end
		local missing = missingElements()
		T.check(#missing == 0, "Pet Index: an 'Elements' help card shows the chart with all " .. #(Config.Elements.Order or {}) .. " elements", "missing: " .. table.concat(missing, ", "))
		if toggled and isShown(helpButton) then
			Mock.Click(helpButton)
			advance(0.4)
		end
	end
	-- Esc closes; OpenPanel("Index") opens it again
	press("Escape")
	advance(0.6)
	T.check(not Index.IsOpen(), "Pet Index: Esc closes the window")
	toClient("OpenPanel", "Index", nil)
	advance(0.8)
	T.check(Index.IsOpen(), "Pet Index: OpenPanel('Index') opens it")
	press("Escape")
	advance(0.6)
	if conn then
		conn:Disconnect()
	end
	feed()
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
		-- v3 (ARCHITECTURE_V3.md section 9): six icon tiles, MenuButton_<Id> inside Entry_<Id>
		local names = CONTRACT.v3.menuEntries
		local entries = {}
		local present, buttonsOk = 0, true
		for _, n in ipairs(names) do
			entries[n] = column:FindFirstChild("Entry_" .. n)
			if entries[n] then
				present = present + 1
				local b = entries[n]:FindFirstChild("MenuButton_" .. n, true)
				buttonsOk = buttonsOk and b ~= nil and b:IsA("TextButton")
			end
		end
		local extra = 0
		for _, c in ipairs(column:GetChildren()) do
			if c.Name:find("^Entry_") then
				extra = extra + 1
			end
		end
		T.check(present == #names and extra == #names, "...with six entries: " .. table.concat(names, ", "), present .. " of " .. #names .. " found, " .. extra .. " entries in total")
		T.check(buttonsOk, "...each tile is a TextButton named MenuButton_<Id> (the tutorial rings it)")
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
			T.check(b ~= nil and b.AbsoluteSize.X >= 44 and abs(b.AbsoluteSize.X - b.AbsoluteSize.Y) < 3, "Entry_" .. n .. " is a square icon tile (>= 44 px)", b and tostring(b.AbsoluteSize) or "no button")
		end
	end
	T.eq(#visibleWindows(), 0, "no window is open at rest")

	-- Pets window
	clickEntry("Pets")
	T.eq(table.concat(visibleWindows(), ","), "Window_Inventory", "the Pets button opens the Inventory window")
	local inv = windowOf("Window_Inventory")
	if inv and inv.Visible then
		do
			local small, measured = KC.smallTexts(15)
			T.check(#small == 0 and measured > 0, "Inventory window: every text on screen is readable (>= 15 px at 1920x1080)", #small .. " of " .. measured .. " too small: " .. table.concat(small, "; ", 1, math.min(#small, 6)))
		end
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
			-- v3 (ARCHITECTURE_V3.md section 11): the Pets panel shows the selected pet's element badge
			local element = petElements(PetCatalog, def)[1]
			if element then
				T.check(detail ~= nil and elementBadge(detail, element) ~= nil, "...and its element badge (" .. element .. ", coloured from Config.Elements.Info)", describeBadge(detail, element))
			end
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
		do
			local small, measured = KC.smallTexts(15)
			T.check(#small == 0 and measured > 0, "Stats window: every text on screen is readable (>= 15 px at 1920x1080)", #small .. " of " .. measured .. " too small: " .. table.concat(small, "; ", 1, math.min(#small, 6)))
		end
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
		local total = PetCatalog.TotalCount()
		T.check(tostring(tile("Found")):find("3") ~= nil and tostring(tile("Found")):find(tostring(total)) ~= nil, "Stats: pets discovered 3 / " .. total .. " (PetCatalog.TotalCount())", tostring(tile("Found")))
		for _, diff in ipairs(Config.Difficulties) do
			T.check(descendantNamed(stats, "Row_" .. diff.Id) ~= nil, "Stats: a best-time row for " .. diff.Id)
		end
		T.check(findText("2:03", stats) ~= nil, "Stats: the best Easy time (2:03)")
		T.check(findText("+12% max health", stats) ~= nil, "Stats: the pet perks", allShownText())
	end
	press("Escape")
	advance(0.5)

	-- v3: the Pet Index window
	indexWindowChecks(PetCatalog)

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
		do
			local small, measured = KC.smallTexts(15)
			T.check(#small == 0 and measured > 0, "Shop window: every text on screen is readable (>= 15 px at 1920x1080)", #small .. " of " .. measured .. " too small: " .. table.concat(small, "; ", 1, math.min(#small, 6)))
		end
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
			-- v3 (ARCHITECTURE_V3.md section 11): every pet of the odds list wears its element badge
			if #list > 0 and petElements(PetCatalog, PetCatalog.Get(list[1].PetId))[1] then
				local badges = T.tally("...and every pet of the odds list shows its element badge (Config.Elements.Info colour)")
				for _, o in ipairs(list) do
					local cell = popup and descendantNamed(popup, "Cell_" .. o.PetId)
					local element = petElements(PetCatalog, PetCatalog.Get(o.PetId))[1]
					badges:case(element ~= nil and elementBadge(cell, element) ~= nil, o.PetId .. ": " .. tostring(element) .. (cell and "" or " (no cell)"))
				end
				badges:report()
			end
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
-- v3: the NPC pets on this client (NpcController, ARCHITECTURE_V3.md section 5). The client world has no server, so the
-- real NpcService builds the six NPCs here, standing in for replication; then the controller idles them and shows the
-- dialog when the local player triggers a Talk prompt (ProximityPromptService.PromptTriggered).
local function npcClientChecks()
	local Config = env()
	local NC = M.NpcController
	local ND = require(Mock.GetPath(ROOTS["shared"] .. "/NpcDialog"))
	local services = Mock.GetPath(ROOTS["server"]):FindFirstChild("Services")
	local npcModule = services and services:FindFirstChild("NpcService")
	if not T.check(type(NC) == "table" and type(NC.Open) == "function" and npcModule ~= nil, "NPC: NpcController loaded and NpcService available to build the NPCs") then
		return
	end
	local NS = require(npcModule)
	local here = Config.Lobby.Origin + Vector3.new(0, 3, 0)
	local spots = {}
	for i = 1, CONTRACT.v3.npcCount do
		local a = (i - 1) * math.pi * 2 / CONTRACT.v3.npcCount
		local pos = Config.Lobby.Origin + Vector3.new(math.cos(a) * 30, 0, math.sin(a) * 30)
		spots[i] = CFrame.lookAt(pos, Vector3.new(Config.Lobby.Origin.X, pos.Y, Config.Lobby.Origin.Z))
	end
	Mock.Teleport(LocalPlayer, here)
	local cam = workspace.CurrentCamera
	cam.CFrame = CFrame.lookAt(here + Vector3.new(0, 12, 40), here)
	NS.Init({ NpcSpots = spots })
	advance(2)
	local holder = workspace:FindFirstChild("NimbusNpcs")
	local first = ND.Npcs[1]
	local model = holder and holder:FindFirstChild("Npc_" .. first.Id)
	if not T.check(model ~= nil, "NPC: the six NPC models exist on the client") then
		return
	end
	-- idle: the client bobs / turns the pet (the server never moves it)
	local pet = model:FindFirstChild("Pet")
	local root = pet and pet.PrimaryPart
	Mock.Teleport(LocalPlayer, spots[1].Position + spots[1].LookVector * 7 + Vector3.new(0, 3, 0))
	advance(0.5)
	local positions = {}
	for i = 1, 20 do
		advance(0.1)
		positions[i] = root and root.CFrame or CFrame.new()
	end
	local moved = 0
	for i = 2, #positions do
		moved = math.max(moved, (positions[i].Position - positions[1].Position).Magnitude, (positions[i].LookVector - positions[1].LookVector).Magnitude)
	end
	T.check(root ~= nil and moved > 0.02 and moved < 3, "NPC: the client idles the NPC pet (gentle bob / turn)", "moved " .. fmt(moved, 3))
	-- the dialog: triggered by the local player through ProximityPromptService.PromptTriggered
	local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
	local other = Mock.AddPlayer("Stranger", 6101)
	advance(0.5)
	if prompt then
		Mock.Trigger(prompt, other)
		advance(0.5)
	end
	T.check(not NC.IsOpen(), "NPC: another player's prompt does not open the local dialog")
	if prompt then
		Mock.Trigger(prompt, LocalPlayer)
		advance(0.5)
	end
	local open, openId = NC.IsOpen()
	T.check(open == true and openId == first.Id, "NPC: triggering the Talk prompt opens the NPC's dialog", tostring(openId))
	local dlg = gui():FindFirstChild("NimbusNpcDialog")
	local line = dlg and descendantNamed(dlg, "Line")
	advance(6) -- let the typewriter finish
	local function shownLine()
		return line and (tostring(line.Text):gsub("<[^>]*>", "")) or ""
	end
	T.check(dlg ~= nil and findText(first.Name:lower(), dlg) ~= nil, "NPC: the dialog shows the NPC's name", dlg and allShownText():sub(1, 200) or "no dialog gui")
	T.check(shownLine():find(first.Lines[1]:sub(1, 24), 1, true) ~= nil, "NPC: ...and its first line", shownLine())
	-- a side card at the bottom-left, never in the middle of the screen
	local card = line
	while card and card.Parent and card.Parent:IsA("GuiObject") do
		card = card.Parent
	end
	if card and card:IsA("GuiObject") then
		local vp = Mock.Viewport
		local cx = (card.AbsolutePosition.X + card.AbsoluteSize.X / 2) / vp.X
		local cy = (card.AbsolutePosition.Y + card.AbsoluteSize.Y / 2) / vp.Y
		T.check(cx < 0.45 and cy > 0.5, "NPC: the dialog is a side card at the bottom-left", string.format("centre %.2f,%.2f", cx, cy))
	end
	T.check(#centredTexts(CONTRACT.v2.centreTolerance) == 0, "NPC: nothing is shown in the middle of the screen while talking", describeCentred(centredTexts(CONTRACT.v2.centreTolerance)))
	do
		local small, measured = KC.smallTexts(15)
		T.check(#small == 0 and measured > 0, "NPC dialog: every text on screen is readable (>= 15 px at 1920x1080)", #small .. " of " .. measured .. " too small: " .. table.concat(small, "; ", 1, math.min(#small, 6)))
	end
	-- Next: the next line, cycling back to the first
	local nextButton = dlg and descendantNamed(dlg, "Button_Next")
	if nextButton then
		Mock.Click(nextButton)
	else
		NC.Advance()
	end
	advance(6)
	T.check(shownLine():find(first.Lines[2]:sub(1, 24), 1, true) ~= nil, "NPC: Next shows the second line", shownLine())
	for _ = 2, #first.Lines do
		NC.Advance()
		advance(6)
	end
	T.check(shownLine():find(first.Lines[1]:sub(1, 24), 1, true) ~= nil, "NPC: after the last line Next starts over", shownLine())
	-- Close, and walking away closes it too
	local closeButton = dlg and descendantNamed(dlg, "Button_Close")
	if closeButton then
		Mock.Click(closeButton)
	else
		NC.Close()
	end
	advance(0.8)
	T.check(not NC.IsOpen(), "NPC: Close closes the dialog")
	NC.Open(first.Id)
	advance(0.5)
	T.check(NC.IsOpen(), "NPC: NpcController.Open(npcId) opens it again")
	Mock.Teleport(LocalPlayer, spots[1].Position + spots[1].LookVector * 60 + Vector3.new(0, 3, 0))
	advance(1.5)
	T.check(not NC.IsOpen(), "NPC: walking away closes the dialog")
	Mock.RemovePlayer(other)
	if holder then
		holder:Destroy()
	end
	advance(1)
	Mock.Teleport(LocalPlayer, Vector3.new(0, 20, 0))
	cam.CFrame = CFrame.new()
	advance(0.5)
end

-- v3: the Sage Dragon in the sky (SkyDragonController, ARCHITECTURE_V3.md section 7 + ART DIRECTION).
local function skyDragonChecks()
	local Config = env()
	local SD = M.SkyDragonController
	if not T.check(type(SD) == "table" and type(SD.GetModel) == "function", "Sky dragon: SkyDragonController loaded (GetModel)") then
		return
	end
	local cam = workspace.CurrentCamera
	cam.CFrame = CFrame.lookAt(Config.Lobby.Origin + Vector3.new(0, 20, 80), Config.Lobby.Origin)
	advance(1)
	local model = SD.GetModel()
	local fx = workspace:FindFirstChild("ClientFx")
	if not T.check(model ~= nil and model:IsA("Model") and fx ~= nil and model:IsDescendantOf(fx), "Sky dragon: the dragon Model lives in workspace.ClientFx") then
		return
	end
	local parts = {}
	local flagsOk = true
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			parts[#parts + 1] = d
			flagsOk = flagsOk and d.Anchored and not d.CanCollide and not d.CanTouch and not d.CanQuery and not d.CastShadow
		end
	end
	T.check(#parts <= CONTRACT.v3.partBudget.skyDragon and #parts >= 60, "Sky dragon: built within ~" .. CONTRACT.v3.partBudget.skyDragon .. " parts", #parts .. " parts")
	T.check(flagsOk, "Sky dragon: every part is anchored with collisions, touches, queries and shadows off")
	local function centre()
		local sum = Vector3.new(0, 0, 0)
		for _, p in ipairs(parts) do
			sum = sum + p.Position
		end
		return sum / math.max(1, #parts)
	end
	local instances = Mock.CountDescendants(model)
	local bulk0 = Mock.BulkMoves or 0
	local c0 = centre()
	local track, minH, maxH = 0, huge, -huge
	local last = c0
	for _ = 1, 40 do
		advance(0.25)
		local c = centre()
		track = track + (c - last).Magnitude
		last = c
		local h = c.Y - Config.Lobby.Origin.Y
		minH, maxH = min(minH, h), max(maxH, h)
	end
	T.check(track > 40, "Sky dragon: it flies (the body travels " .. fmt(track, 0) .. " studs in 10 s)")
	T.check(minH >= 90 and maxH <= 280, "Sky dragon: high above the lobby (120-240 studs, the body's centre at " .. fmt(minH, 0) .. "-" .. fmt(maxH, 0) .. ")")
	T.check(SD.IsPaused == nil or SD.IsPaused() == false, "Sky dragon: not paused while the camera is at the lobby")
	T.eq(Mock.CountDescendants(model), instances, "Sky dragon: no instances are created while it flies")
	T.check((Mock.BulkMoves or 0) > bulk0, "Sky dragon: the parts are moved with workspace:BulkMoveTo", tostring((Mock.BulkMoves or 0) - bulk0) .. " calls")
	-- frozen when the camera is far away (the player is in a match)
	cam.CFrame = CFrame.new(Config.Match.ArenaOrigin + Vector3.new(0, 20, 0))
	advance(0.5)
	local frozen = centre()
	advance(2)
	T.check((centre() - frozen).Magnitude < 0.01, "Sky dragon: frozen while the camera is far from the lobby")
	if SD.IsPaused then
		T.eq(SD.IsPaused(), true, "Sky dragon: IsPaused() reports it")
	end
	cam.CFrame = CFrame.new()
	advance(0.5)
end

-- v3: the Stormfang showcase on the Storm Altar (ARCHITECTURE_V3.md section 10). The server builds it standing still;
-- the client hovers / pulses it (ShowcaseController, NPC-controller style). The client world has no server, so the
-- real LobbyBuilder + StormAltar build it here, standing in for replication. Checked once the altar is in the build.
local function showcaseChecks()
	local PC = require(Mock.GetPath(ROOTS["shared"] .. "/PetCatalog"))
	local services = Mock.GetPath(ROOTS["server"]):FindFirstChild("Services")
	local altarModule = services and services:FindFirstChild("StormAltar")
	local lobbyModule = services and services:FindFirstChild("LobbyBuilder")
	if not altarModule or not lobbyModule or not PC.Get(CONTRACT.v3.stormfang.petId) then
		T.info("*Storm Altar showcase: not in this build yet (needs server/Services/StormAltar and the stormfang pet)")
		return
	end
	-- what the stand-in builds add to the workspace (right away, before any controller runs) is removed afterwards
	local existing, built = {}, {}
	for _, c in ipairs(workspace:GetChildren()) do
		existing[c] = true
	end
	local function noteBuilt()
		for _, c in ipairs(workspace:GetChildren()) do
			if not existing[c] and not c:IsA("Camera") and not c:IsA("Terrain") then
				existing[c] = true
				built[#built + 1] = c
			end
		end
	end
	local function cleanUp()
		for _, c in ipairs(built) do
			c:Destroy()
		end
	end
	local okL, info = pcall(function()
		return require(lobbyModule).Build()
	end)
	noteBuilt()
	if not okL or type(info) ~= "table" then
		cleanUp()
		T.warn("Storm Altar showcase: LobbyBuilder.Build could not run in the client world, the client animation is not checked", tostring(info))
		return
	end
	local okA, err = pcall(function()
		return require(altarModule).Build(info)
	end)
	noteBuilt()
	local showcase = workspace:FindFirstChild("StormfangShowcase", true)
	if not okA or not showcase then
		T.warn("Storm Altar showcase: StormAltar.Build did not build a StormfangShowcase in the client world, the client animation is not checked", tostring(err))
	else
		-- stand next to the altar, looking at it
		local at = showcase:GetPivot().Position
		local look = typeof(info.AltarSite) == "CFrame" and info.AltarSite.LookVector or Vector3.new(0, 0, -1)
		Mock.Teleport(LocalPlayer, at + look * 24 + Vector3.new(0, 3, 0))
		local cam = workspace.CurrentCamera
		cam.CFrame = CFrame.lookAt(at + look * 40 + Vector3.new(0, 12, 0), at)
		advance(1)
		local neon = {}
		for _, d in ipairs(showcase:GetDescendants()) do
			if d:IsA("BasePart") and d.Material == Enum.Material.Neon then
				neon[#neon + 1] = { part = d, t = d.Transparency, c = d.Color }
			end
		end
		local instances = Mock.CountDescendants(showcase)
		local p0 = showcase:GetPivot()
		local moved, pulsed = 0, false
		for _ = 1, 20 do
			advance(0.1)
			local p = showcase:GetPivot()
			moved = max(moved, (p.Position - p0.Position).Magnitude, (p.LookVector - p0.LookVector).Magnitude)
			for _, n in ipairs(neon) do
				local c = n.part.Color
				if abs(n.part.Transparency - n.t) > 0.02 or abs(c.R - n.c.R) + abs(c.G - n.c.G) + abs(c.B - n.c.B) > 0.02 then
					pulsed = true
				end
			end
		end
		T.check((moved > 0.02 or pulsed) and moved < 6, "Storm Altar: the client hovers / pulses the Stormfang showcase", "moved " .. fmt(moved, 3) .. ", neon pulse " .. tostring(pulsed))
		T.eq(Mock.CountDescendants(showcase), instances, "Storm Altar: no instances are created while the showcase is animated")
		cam.CFrame = CFrame.new()
	end
	-- clean up what stood in for replication
	cleanUp()
	Mock.Teleport(LocalPlayer, Vector3.new(0, 20, 0))
	advance(0.5)
end

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
	-- v3 level of detail: your own pets are High detail, other players' followers Low (ARCHITECTURE_V3.md ART DIRECTION)
	do
		local lowOk, highOk, detail = true, true, {}
		for _, m in ipairs(modelsOf(other)) do
			local n = Mock.CountDescendants(m, "BasePart")
			detail[#detail + 1] = "other " .. n
			lowOk = lowOk and n <= CONTRACT.v3.partBudget.petLow
		end
		for _, m in ipairs(modelsOf(LocalPlayer)) do
			local n = Mock.CountDescendants(m, "BasePart")
			detail[#detail + 1] = "mine " .. n
			highOk = highOk and n > CONTRACT.v3.partBudget.petLow and n <= CONTRACT.v3.partBudget.petHigh
		end
		T.check(lowOk, "other players' followers use PetBuilder Detail Low (<= " .. CONTRACT.v3.partBudget.petLow .. " parts each)", table.concat(detail, ", "))
		T.check(highOk, "the local player's own pets use Detail High (<= " .. CONTRACT.v3.partBudget.petHigh .. " parts)", table.concat(detail, ", "))
	end
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
	npcClientChecks()
	skyDragonChecks()
	showcaseChecks()
	flushErrors("client_pets")
	flushWarnings("client_pets")
end)

----------------------------------------------------------------------------------------------------
-- scenario: TokenFx (the client-side coin spin + bob)
----------------------------------------------------------------------------------------------------
-- With Config.Tokens.ClientAnimated = true the server leaves the coins still (server side: scenario `hazards`,
-- "TokenService does not animate") and TokenFx poses them on this client every frame:
--   * every CloudToken part of the workspace (also ones that appear later) spins around Y and bobs; X/Z never change
--   * normal coins: spin 2.0 rad/s, bob +-0.45 studs; golden coins (GoldenToken tag): 2.6 rad/s, +-0.6 studs
--   * the yaw the server built the coin with is the phase, so neighbours do not move in lockstep
--   * only coins within ~140 studs of the camera are posed (the rest are not even touched)
--   * a coin that is being collected (attribute Collected), destroyed, or no longer tagged is let go of for good
--   * one RenderStepped connection for all coins, no instances created per frame, Init() is idempotent
-- With the flag false TokenFx must stay passive and leave every coin exactly where the server put it.
S.client_tokens = guarded("client_tokens", function()
	local Config = env()
	local CollectionService = game:GetService("CollectionService")
	local TokenFx = M.TokenFx
	if not T.check(TokenFx ~= nil and type(TokenFx.Init) == "function", "TokenFx loads and has Init") then
		return
	end
	local animated = Config.Tokens.ClientAnimated == true
	local camera = workspace.CurrentCamera
	if not T.check(camera ~= nil, "the workspace has a CurrentCamera") then
		return
	end
	local cameraBefore = camera.CFrame
	local eye = Vector3.new(6000, 300, 0)
	camera.CFrame = CFrame.new(eye)

	local holder = Instance.new("Folder")
	holder.Name = "SmokeCoins"
	holder.Parent = workspace
	local function makeCoin(offset, golden, yaw)
		local coin = Instance.new("Part")
		coin.Name = golden and "SmokeGoldenCoin" or "SmokeCoin"
		coin.Anchored = true
		coin.CanCollide = false
		coin.CFrame = CFrame.new(eye + offset) * CFrame.Angles(0, yaw or 0, 0)
		-- like TokenService.MakeTokenPart: both tags first, then into the world (TokenFx reads the golden tag
		-- the moment it sees the CloudToken tag)
		CollectionService:AddTag(coin, Config.Tags.CloudToken)
		if golden then
			CollectionService:AddTag(coin, Config.Tags.GoldenToken)
		end
		coin.Parent = holder
		return coin
	end
	local function yawOf(part)
		local look = part.CFrame.LookVector
		return math.atan2(-look.X, -look.Z)
	end
	local function wrap(a)
		return (a + math.pi) % (2 * math.pi) - math.pi
	end

	local normal = makeCoin(Vector3.new(30, 0, 0), false, 0.0)
	local neighbour = makeCoin(Vector3.new(30, 0, 8), false, 1.9)
	local golden = makeCoin(Vector3.new(0, 0, 30), true, 0.7)
	local far = makeCoin(Vector3.new(0, 0, 400), false, 0.4)
	local farBefore = far.CFrame
	local normalBase, goldenBase = normal.Position, golden.Position

	if not animated then
		advance(1.5)
		T.check(normal.CFrame == CFrame.new(eye + Vector3.new(30, 0, 0)) * CFrame.Angles(0, 0.0, 0) and golden.CFrame == CFrame.new(eye + Vector3.new(0, 0, 30)) * CFrame.Angles(0, 0.7, 0),
			"Config.Tokens.ClientAnimated is false: TokenFx leaves the coins exactly where the server put them")
	else
		-- the first pose snaps a coin from the server's yaw to now * spin + yaw: take the baseline after it, then
		-- sample two whole bob periods (2 * 2pi / 2.2 = 5.7 s) every frame (1/30 s)
		advance(1 / 30)
		local clock0 = os.clock()
		local last = { n = yawOf(normal), g = yawOf(golden) }
		local turned = { n = 0, g = 0 }
		local lo = { n = math.huge, g = math.huge }
		local hi = { n = -math.huge, g = -math.huge }
		local drift = 0
		local lockstep = true
		local meanDy = { n = 0, g = 0 }
		local samples = 0
		for _ = 1, 171 do
			advance(1 / 30)
			samples = samples + 1
			local yn, yg = yawOf(normal), yawOf(golden)
			turned.n = turned.n + wrap(yn - last.n)
			turned.g = turned.g + wrap(yg - last.g)
			last.n, last.g = yn, yg
			local dn, dg = normal.Position.Y - normalBase.Y, golden.Position.Y - goldenBase.Y
			lo.n, hi.n = math.min(lo.n, dn), math.max(hi.n, dn)
			lo.g, hi.g = math.min(lo.g, dg), math.max(hi.g, dg)
			meanDy.n, meanDy.g = meanDy.n + dn, meanDy.g + dg
			drift = math.max(drift,
				math.abs(normal.Position.X - normalBase.X), math.abs(normal.Position.Z - normalBase.Z),
				math.abs(golden.Position.X - goldenBase.X), math.abs(golden.Position.Z - goldenBase.Z))
			if math.abs((neighbour.Position.Y - (eye.Y)) - dn) > 0.02 then
				lockstep = false
			end
		end
		local elapsed = os.clock() - clock0
		T.near(turned.n / elapsed, 2.0, 0.2, "a normal coin spins at about 2.0 rad/s")
		T.near(turned.g / elapsed, 2.6, 0.2, "a golden coin spins faster, about 2.6 rad/s")
		T.check(hi.n <= 0.46 and lo.n >= -0.46 and hi.n - lo.n >= 0.7, "a normal coin bobs +-0.45 studs around its base", "range " .. fmt(lo.n, 2) .. " .. " .. fmt(hi.n, 2))
		T.check(hi.g <= 0.61 and lo.g >= -0.61 and hi.g - lo.g >= 0.95, "a golden coin bobs +-0.6 studs around its base", "range " .. fmt(lo.g, 2) .. " .. " .. fmt(hi.g, 2))
		T.check(math.abs(meanDy.n / samples) < 0.04 and math.abs(meanDy.g / samples) < 0.05, "...centred on the base height (the coin does not sink or rise over time)", fmt(meanDy.n / samples, 3) .. " / " .. fmt(meanDy.g / samples, 3))
		T.check(drift < 1e-3, "X and Z never change (spin and bob only)", "drift " .. fmt(drift, 4))
		T.check(not lockstep, "a neighbour with another starting yaw bobs out of step (the server's yaw is the phase)")
		T.check(far.CFrame == farBefore, "a coin 400 studs from the camera is not posed (culled, untouched)")

		-- the camera comes closer: the far coin starts to move
		camera.CFrame = CFrame.new(eye + Vector3.new(0, 0, 380))
		advance(0.5)
		T.check(far.CFrame ~= farBefore, "...and is posed as soon as the camera is within range")
		camera.CFrame = CFrame.new(eye)
		advance(0.3)

		-- a coin that appears later is picked up; one root-level connection serves every coin
		local stats0 = Mock.Stats().connections["RunService.RenderStepped"] or 0
		local late, lateStart = {}, {}
		for i = 1, 20 do
			late[i] = makeCoin(Vector3.new(-20 + i, 0, -30), i % 5 == 0, i * 0.3)
			lateStart[i] = late[i].CFrame
		end
		advance(0.5)
		T.check(late[1].CFrame ~= lateStart[1] and late[20].CFrame ~= lateStart[20], "coins added after Init are spun too")
		local stats1 = Mock.Stats().connections["RunService.RenderStepped"] or 0
		T.eq(stats1, stats0, "20 more coins add no RenderStepped connection (one shared driver)")
		TokenFx.Init()
		T.eq(Mock.Stats().connections["RunService.RenderStepped"] or 0, stats0, "a second Init() adds no connection either")
		local count = Mock.CountDescendants(workspace)
		advance(2)
		T.eq(Mock.CountDescendants(workspace), count, "posing the coins allocates no instances")

		-- let go: collected, untagged, destroyed
		local pickedUp = late[1]
		pickedUp:SetAttribute("Collected", true)
		advance(0.1)
		local server = pickedUp.CFrame * CFrame.new(0, 4, 0) -- what the server's pickup animation does
		pickedUp.CFrame = server
		advance(0.5)
		T.check(pickedUp.CFrame == server, "a coin with the Collected attribute is no longer posed (the pickup animation owns it)")
		local untagged = late[2]
		CollectionService:RemoveTag(untagged, Config.Tags.CloudToken)
		advance(0.1)
		local frozen = untagged.CFrame
		advance(0.5)
		T.check(untagged.CFrame == frozen, "a coin that loses its CloudToken tag is no longer posed")
		late[3]:Destroy()
		advance(0.5)
		local others = late[4].CFrame
		advance(0.3)
		T.check(late[4].CFrame ~= others, "destroying a coin does not stop the others")

		-- v3: the soft Halo (an anchored, unwelded child of the coin, built by TokenService) bobs WITH the coin
		local haloCoin = makeCoin(Vector3.new(12, 0, -12), false, 0.3)
		local halo = Instance.new("Part")
		halo.Name = "Halo"
		halo.Shape = Enum.PartType.Ball
		halo.Anchored = true
		halo.CanCollide = false
		halo.Size = Vector3.new(3, 3, 3)
		halo.Transparency = 0.8
		halo.CFrame = CFrame.new(haloCoin.Position)
		halo.Parent = haloCoin
		advance(1)
		local offset0 = halo.Position - haloCoin.Position
		local worst, bobbed = 0, 0
		local y0 = haloCoin.Position.Y
		for _ = 1, 45 do
			advance(1 / 30)
			worst = math.max(worst, ((halo.Position - haloCoin.Position) - offset0).Magnitude)
			bobbed = math.max(bobbed, math.abs(haloCoin.Position.Y - y0))
		end
		T.check(bobbed > 0.1 and worst < 0.02, "the coin's Halo moves with the coin (it never stays behind)", "coin bobbed " .. fmt(bobbed, 2) .. ", halo offset changed by " .. fmt(worst, 3))
	end

	holder:Destroy()
	camera.CFrame = cameraBefore
	advance(0.3)
	flushErrors("client_tokens")
	flushWarnings("client_tokens")
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

-- ARCHITECTURE_V3.md readability rule: text on screen never shrinks below `floor` px (TextSize x every UIScale above it).
-- Returns the offenders as "path (size px) 'text'" strings, smallest first, and the number of texts measured.
local function smallTexts(floorPx)
	local out, measured = {}, 0
	for _, d in ipairs(texts(nil, true)) do
		local owner = d:FindFirstAncestorOfClass("ScreenGui")
		local world = d:FindFirstAncestorOfClass("BillboardGui") or d:FindFirstAncestorOfClass("SurfaceGui")
		local t = tostring(d.Text):gsub("<[^>]*>", "")
		if owner and not world and t:gsub("%s", "") ~= "" and d.AbsoluteSize.X > 0 and d.AbsoluteSize.Y > 0 then
			local px = d.TextScaled and d.AbsoluteSize.Y or d.TextSize * scaleOf(d)
			measured = measured + 1
			if px < floorPx - 0.01 then
				out[#out + 1] = { px = px, text = string.format("%s (%.1f px) '%s'", d:GetFullName():gsub("^Players%.[^.]+%.PlayerGui%.", ""), px, t:sub(1, 24)) }
			end
		end
	end
	table.sort(out, function(a, b)
		return a.px < b.px
	end)
	local lines = {}
	for i, o in ipairs(out) do
		lines[i] = o.text
	end
	return lines, measured
end
KC.smallTexts = smallTexts

local function layoutRule(label)
	local Config = env()
	local tol = CONTRACT.v2.centreTolerance
	local vp = Mock.Viewport
	-- readability rule (ARCHITECTURE_V3.md): at 1920x1080 even small captions are >= 15 px; phones never below 14 px
	local floorPx = (vp.Y >= 1000) and 15 or 14
	local function check(state)
		local list = centredTexts(tol)
		T.check(#list == 0, label .. ": nothing is shown in the middle of the screen (" .. state .. ")", describeCentred(list))
		local small, measured = smallTexts(floorPx)
		T.check(#small == 0 and measured > 0, label .. ": every text on screen is readable, >= " .. floorPx .. " px (" .. state .. ")", #small .. " of " .. measured .. " too small: " .. table.concat(small, "; ", 1, math.min(#small, 6)))
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
