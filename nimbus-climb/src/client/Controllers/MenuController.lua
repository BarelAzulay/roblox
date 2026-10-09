-- MenuController (client, v2): the left-centre menu column and every window the player opens.
--
--   MenuController.Init()
--   MenuController.Open(panelId, args)   -- "Inventory" | "Pets" | "Shop" | "Stats" (what the OpenPanel remote does)
--   MenuController.Close()               -- closes whatever window / overlay is open
--
-- Screen: ScreenGui "NimbusMenu" (display order 20, IgnoreGuiInset = false).
--   * Menu column, left-centre: five round CloudUI.IconButtons - Inventory (items tab), Pets (pets tab),
--     Shop, Spot (fires GoToSpot) and Stats. A gold tab shows which window is open.
--   * Windows (CloudUI.Panel, centred because the player asked for them): Inventory (tabs Pets + Items,
--     pet detail card with Equip / Unequip), Shop (tabs Roulettes + Items, odds popup), Stats.
--     One window at a time, Esc / gamepad B / the red X / the menu button / a click outside closes it.
--     Gamepad B is bound (ContextActionService, High priority, sunk) only while something is open, so it does
--     not also fire MovementController's dash.
--   * Roulette stage: a scrolling strip of pet viewports that eases to the server result (RouletteResult),
--     then a reveal card with a rarity glow, a NEW! flag and an Equip button.
--   * Every window re-renders from State.Changed (and when the token count or the InMatch attribute
--     changes). Pet slots are kept per pet id and updated in place, so nothing is rebuilt or leaked; the
--     pet viewports of the Inventory grid are attached PETS_PER_FRAME at a time so a big collection never hitches.
--
-- Remotes used: OpenPanel, RouletteResult (in); BuyRoulette, EquipPet, UnequipPet, BuyItem, GoToSpot (out).
-- Plain Lua 5.1-compatible syntax only. All text goes through Theme roles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent.Parent
local CloudUI = require(Client:WaitForChild("UI"):WaitForChild("CloudUI"))
local State = require(Client:WaitForChild("State"))

-- The catalogs are written by other engineers: never let a broken one take the whole menu down.
local function safeRequire(name, fallback)
	local ok, result = pcall(function()
		return require(Shared:WaitForChild(name, 10))
	end)
	if ok and type(result) == "table" then
		return result
	end
	warn("[MenuController] " .. name .. " is unavailable: " .. tostring(result))
	return fallback
end

local PetCatalog = safeRequire("PetCatalog", {
	Pets = {},
	ById = {},
	Get = function()
		return nil
	end,
	GetOdds = function()
		return {}
	end,
	PerkLabel = function(key, value)
		return tostring(key) .. " " .. tostring(value)
	end,
})
local ItemCatalog = safeRequire("ItemCatalog", {
	List = {},
	ById = {},
	Get = function()
		return nil
	end,
})

local MenuController = {}

----------------------------------------------------------------------
-- Tunables + constants
----------------------------------------------------------------------
local REF_W, REF_H = 1280, 720
local EDGE, TOUCH_EDGE = 10, 20
local BTN = 56 -- diameter of a menu button
local COL_W = 68
local CAPTION_H = 18
local FIRE_GAP = 0.3 -- client-side spacing between two sends of the same remote
local HINT_SECONDS = 2.6
local WAIT_TIMEOUT = 7 -- seconds to wait for a RouletteResult
local COMPACT_BELOW = 560 -- gui height under which the menu captions are hidden
local PETS_PER_FRAME = 3 -- pet viewports the Inventory grid builds per frame (a PetBuilder model is 35-66 parts)
local BACK_ACTION = "NimbusMenuBack" -- ContextActionService action that owns gamepad B while something is closable

local WIN_SIZES = {
	Inventory = { 800, 540 },
	Shop = { 830, 540 },
	Stats = { 740, 480 },
}
local REVEAL_W, REVEAL_H = 380, 480
local STAGE_W, STAGE_H = 700, 292
local STRIP = { Cell = 116, W = 652, H = 150, Target = 34, MinCells = 42, Seconds = 5.6, Curve = 2.8 }

local Colors = Theme.Colors
local WHITE = Colors.White
local NAVY = Colors.Navy or Colors.Ink
local MUTED = Colors.Muted or Colors.CloudShade
local GOLD = Colors.Gold or Colors.Token
local GOOD = Colors.Good
local BAD = Colors.Bad
local WELL_EDGE = Colors.WellEdge or NAVY
local BUTTONS = Theme.Buttons or {}
local KINDS = Theme.Kinds or {}
local PURPLE = Color3.fromRGB(150, 122, 226)

-- Glyphs as UTF-8 byte escapes (the source stays plain ASCII).
local G = {
	Backpack = "\240\159\142\146",
	Paw = "\240\159\144\190",
	Money = "\240\159\146\176",
	House = "\240\159\143\160",
	Chart = "\240\159\147\138",
	Lock = "\240\159\148\146",
	Star = "\226\152\133",
	StarOutline = "\226\152\134",
	Cloud = "\226\152\129",
	Down = "\226\150\188",
	Dot = "\226\128\162",
	Dash = "\226\128\148",
	Check = "\226\156\147",
}

----------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------
local LocalPlayer = nil
local initialized = false
local gui = nil
local U = {} -- shared UI references (backdrop, column, hint ...)
local windows = {} -- id -> window table (see createWindow)
local openId = nil -- id of the window that is currently open
local warned = {}
local remoteCache = {}
local lastFire = {}
local touchDevice = false

local Spin = { Waiting = false, WaitToken = 0, Queue = {}, Stage = nil }
local Odds = { Gui = nil, Token = 0, Slots = {} }
local Badge = { LastPetTotal = nil }
local Back = { Bound = false, Busy = false, Swallowed = false } -- gamepad B binding state (see syncBackBinding)

-- forward declarations
local openWindow, closeWindow, toggleWindow, refreshOpenWindow, updateMenuActive
local requestSpin, closeStage, skipSpin, closeOdds, openOdds, showHint, handleBack, beginStage
local syncBackBinding

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function warnOnce(key, err)
	if not warned[key] then
		warned[key] = true
		warn("[MenuController] " .. tostring(key) .. ": " .. tostring(err))
	end
end

local function safe(key, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warnOnce(key, err)
	end
	return ok
end

local function makeFrame(parent, name, props)
	local p = props or {}
	p.Name = name
	if p.BackgroundTransparency == nil then
		p.BackgroundTransparency = 1
	end
	p.BorderSizePixel = 0
	p.Parent = parent
	return Util.Create("Frame", p)
end

-- Theme-styled TextLabel with optional property overrides.
local function makeText(parent, name, text, role, size, color, props)
	local p = { Name = name }
	if props then
		for key, value in pairs(props) do
			p[key] = value
		end
	end
	local label = Theme.Label(tostring(text), role, { Size = size, Color = color or WHITE, Stroke = 0.3, Props = p })
	label.Parent = parent
	return label
end

local function corner(parent, radius)
	return Theme.Corner(parent, UDim.new(0, radius or 12))
end

local function round(parent)
	return Theme.Corner(parent, UDim.new(0.5, 0))
end

local function stroke(parent, color, thickness, transparency)
	return Theme.Stroke(parent, color or NAVY, thickness or 3, transparency or 0)
end

local function pad(parent, left, top, right, bottom)
	return Util.Create("UIPadding", {
		PaddingLeft = UDim.new(0, left or 0),
		PaddingTop = UDim.new(0, top or 0),
		PaddingRight = UDim.new(0, right or 0),
		PaddingBottom = UDim.new(0, bottom or 0),
		Parent = parent,
	})
end

local function listLayout(parent, direction, gap, hAlign, vAlign)
	return Util.Create("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, gap or 0),
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
		Parent = parent,
	})
end

local function tween(inst, seconds, goal, style, direction)
	return Util.Tween(inst, seconds, goal, style, direction)
end

local function rarityOf(def)
	return CloudUI.RarityColor(def and def.Rarity)
end

local function rarityOrder(rarityId)
	for _, r in ipairs(Config.Rarities) do
		if r.Id == rarityId then
			return r.Order
		end
	end
	return 1
end

local function commas(n)
	return Util.Commas(tonumber(n) or 0)
end

local function cloudAmount(n)
	return G.Cloud .. " " .. commas(n)
end

local function inMatch()
	return LocalPlayer ~= nil and LocalPlayer:GetAttribute(Config.Attr.InMatch) == true
end

local function findRoulette(id)
	for _, r in ipairs(Config.Roulettes) do
		if r.Id == id then
			return r
		end
	end
	return nil
end

local function itemList()
	return ItemCatalog.List or {}
end

-- "+12% Max Health" lines of a pet, in catalog order.
local function perkLines(def)
	local lines = {}
	if type(def) ~= "table" or type(def.Perks) ~= "table" then
		return lines
	end
	local order = PetCatalog.PerkOrder or { "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }
	for _, key in ipairs(order) do
		local value = def.Perks[key]
		if type(value) == "number" and value ~= 0 then
			table.insert(lines, PetCatalog.PerkLabel(key, value))
		end
	end
	return lines
end

local function percentText(chance)
	local pct = (tonumber(chance) or 0) * 100
	local text
	if pct >= 10 then
		text = string.format("%.1f", pct)
	elseif pct >= 1 then
		text = string.format("%.2f", pct)
	else
		text = string.format("%.3f", pct)
	end
	if text:find(".", 1, true) then
		text = text:gsub("0+$", "")
		text = text:gsub("%.$", "")
	end
	return text .. "%"
end

local function starText(count)
	count = Util.Clamp(math.floor(tonumber(count) or 0), 0, 5)
	return string.rep(G.Star, count) .. string.rep(G.StarOutline, 5 - count)
end

local function petRankMap()
	local rank = {}
	for index, def in ipairs(PetCatalog.Pets or {}) do
		rank[def.Id] = index
	end
	return rank
end

-- Owned pet ids, rarest first (the catalog is sorted common -> mythic).
local function ownedPetIds()
	local out = {}
	local pets = PetCatalog.Pets or {}
	for index = #pets, 1, -1 do
		local def = pets[index]
		if State.OwnedCount(def.Id) > 0 then
			table.insert(out, def.Id)
		end
	end
	return out
end

local function petTotals()
	local distinct, total = 0, 0
	for id, count in pairs(State.Get().Pets) do
		if PetCatalog.Get(id) then
			distinct = distinct + 1
			total = total + count
		end
	end
	return distinct, total
end

----------------------------------------------------------------------
-- Remotes (sent at most every FIRE_GAP seconds each, the server rate-limits as well)
----------------------------------------------------------------------
local function getRemote(name)
	local cached = remoteCache[name]
	if cached then
		return cached
	end
	local ok, remote = pcall(Remotes.Get, name)
	if ok and remote then
		remoteCache[name] = remote
		return remote
	end
	return nil
end

local function fire(name, a, b)
	local now = os.clock()
	if lastFire[name] and now - lastFire[name] < FIRE_GAP then
		return false
	end
	local remote = getRemote(name)
	if not remote then
		return false
	end
	lastFire[name] = now
	local ok = pcall(function()
		remote:FireServer(a, b)
	end)
	return ok
end

----------------------------------------------------------------------
-- Screen size helpers
----------------------------------------------------------------------
local function guiSize()
	local size = gui and gui.AbsoluteSize or Vector2.new(REF_W, REF_H)
	if size.X < 2 or size.Y < 2 then
		return Vector2.new(REF_W, REF_H)
	end
	return size
end

-- Scale that makes a w x h window (plus its title ribbon) fit the screen.
local function fitScale(w, h)
	local size = guiSize()
	local k = math.min((size.X - 40) / (w + 24), (size.Y - 20) / (h + 56), 1.2)
	return Util.Clamp(k, 0.3, 1.2)
end

local function screenMargin()
	if touchDevice then
		return TOUCH_EDGE
	end
	return EDGE
end

----------------------------------------------------------------------
-- Side hint (tiny message next to the menu column; never in the middle of the screen)
----------------------------------------------------------------------
local Hint = { Frame = nil, Label = nil, Token = 0 }

local function buildHint()
	local frame = makeFrame(gui, "MenuHint", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 90, 0.5, 0),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = Colors.Panel,
		BackgroundTransparency = 0.06,
		Visible = false,
		ZIndex = 9,
	})
	corner(frame, 10)
	stroke(frame, NAVY, 3, 0)
	pad(frame, 12, 7, 12, 7)
	local label = makeText(frame, "Text", "", "Toast", 15, WHITE, {
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	Util.Create("UISizeConstraint", { MaxSize = Vector2.new(230, 200), Parent = label })
	Hint.Frame = frame
	Hint.Label = label
end

function showHint(text, kind)
	if not Hint.Frame then
		return
	end
	Hint.Token = Hint.Token + 1
	local mine = Hint.Token
	local color = KINDS[kind or "info"] or KINDS.info or Colors.PanelLight
	Hint.Label.Text = tostring(text)
	Hint.Label.TextColor3 = Theme.Lighten(color, 0.45)
	Hint.Frame.Visible = true
	task.delay(HINT_SECONDS, function()
		if Hint.Token == mine and Hint.Frame then
			Hint.Frame.Visible = false
		end
	end)
end

----------------------------------------------------------------------
-- Window manager
-- window = { Id, Holder, Fit (UIScale), Pop (UIScale), Panel, Shown, Built, Dirty, Token,
--            Tab, Refresh = fn(), OnOpen = fn(args), OnClose = fn() }
----------------------------------------------------------------------
local function setBackdrop(on)
	local backdrop = U.Backdrop
	if not backdrop then
		return
	end
	U.BackdropOn = on
	if on then
		backdrop.Visible = true
		tween(backdrop, 0.18, { BackgroundTransparency = 0.6 })
	else
		tween(backdrop, 0.15, { BackgroundTransparency = 1 })
		task.delay(0.17, function()
			if not U.BackdropOn and backdrop.Parent then
				backdrop.Visible = false
			end
		end)
	end
end

local function createWindow(spec)
	local size = WIN_SIZES[spec.Id] or { 760, 500 }
	local win = { Id = spec.Id, Spec = spec, Shown = false, Built = false, Dirty = true, Token = 0 }
	win.Holder = makeFrame(gui, "Window_" .. spec.Id, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 14),
		Size = UDim2.fromOffset(size[1], size[2]),
		Visible = false,
		ZIndex = 3,
	})
	win.Fit = Util.Create("UIScale", { Name = "Fit", Scale = fitScale(size[1], size[2]), Parent = win.Holder })
	win.Size = size
	win.Panel = CloudUI.Panel({
		Name = spec.Id .. "Panel",
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Title = spec.Title,
		Closable = true,
		Accent = spec.Accent,
		OnClose = function()
			closeWindow(spec.Id)
		end,
		Parent = win.Holder,
	})
	win.Pop = Util.Create("UIScale", { Name = "Pop", Scale = 1, Parent = win.Panel.Root })
	windows[spec.Id] = win
	return win
end

local function ensureBuilt(win)
	if win.Built then
		return
	end
	win.Built = true
	safe("build " .. win.Id, win.Spec.Build, win)
end

local function refreshWindow(win)
	if not win or not win.Built then
		return
	end
	if win.Shown then
		win.Dirty = false
		if win.Refresh then
			safe("refresh " .. win.Id, win.Refresh)
		end
	else
		win.Dirty = true
	end
end

function refreshOpenWindow()
	if openId then
		refreshWindow(windows[openId])
	end
end

local function normalizeTab(windowId, tab)
	if type(tab) ~= "string" then
		return nil
	end
	local t = tab:lower()
	if t:find("roul", 1, true) then
		return "Roulettes"
	elseif t:find("item", 1, true) then
		return "Items"
	elseif t:find("pet", 1, true) then
		if windowId == "Inventory" then
			return "Pets"
		end
	end
	return nil
end

function openWindow(id, args)
	local win = windows[id]
	if not win or Spin.Stage then
		return
	end
	args = type(args) == "table" and args or {}
	ensureBuilt(win)
	if openId and openId ~= id then
		closeWindow(openId, true)
	end
	local wasShown = win.Shown
	win.Shown = true
	win.Token = win.Token + 1
	openId = id
	syncBackBinding()
	win.Fit.Scale = fitScale(win.Size[1], win.Size[2])
	win.Holder.Visible = true
	if not wasShown then
		win.Pop.Scale = 0.86
		tween(win.Pop, 0.22, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end
	setBackdrop(true)
	if win.OnOpen then
		safe("open " .. id, win.OnOpen, args)
	end
	refreshWindow(win)
	updateMenuActive()
end

function closeWindow(id, instant)
	local win = windows[id]
	if not win or not win.Shown then
		return
	end
	win.Shown = false
	win.Token = win.Token + 1
	local mine = win.Token
	if openId == id then
		openId = nil
	end
	syncBackBinding()
	if win.OnClose then
		safe("close " .. id, win.OnClose)
	end
	if id == "Shop" then
		closeOdds()
	end
	if instant then
		win.Holder.Visible = false
	else
		tween(win.Pop, 0.12, { Scale = 0.9 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.13, function()
			if win.Token == mine and not win.Shown then
				win.Holder.Visible = false
			end
		end)
		if not openId then
			setBackdrop(false)
		end
	end
	updateMenuActive()
end

-- Button behaviour: open, or close when this exact view is already showing.
function toggleWindow(id, args)
	local win = windows[id]
	if not win then
		return
	end
	local wantTab = args and normalizeTab(id, args.Tab) or nil
	if win.Shown and (wantTab == nil or win.Tab == wantTab) then
		closeWindow(id)
	else
		openWindow(id, args)
	end
end

local function closeEverything()
	Spin.Queue = {} -- pets from queued results are already in the collection, just skip their shows
	if Spin.Stage then
		closeStage()
	end
	closeOdds()
	if openId then
		closeWindow(openId)
	end
end

-- Esc / gamepad B: close the topmost thing. Returns true when something was closed.
function handleBack()
	if Spin.Stage then
		if Spin.Stage.Phase == "reveal" then
			closeStage()
		else
			skipSpin()
		end
		return true
	end
	if Odds.Gui then
		closeOdds()
		return true
	end
	if openId then
		closeWindow(openId)
		return true
	end
	return false
end

-- Gamepad B is also the dash button (MovementController binds "NimbusDash" at Default priority), and
-- UserInputService.InputBegan cannot stop that action. So B is owned here through ContextActionService at
-- High priority, but only while something closable is open: the press then closes it and is sunk, so
-- the character does not dash (or spend stamina / start the cooldown) on the same press. With nothing open
-- the binding is gone and B dashes as usual. Esc stays on the plain InputBegan path (onInput).
local function onBackAction(_name, state)
	if state == Enum.UserInputState.Begin then
		Back.Busy = true
		local ok, handled = pcall(handleBack)
		Back.Busy = false
		if not ok then
			warnOnce("back", handled)
			handled = false
		end
		Back.Swallowed = handled == true
		if Back.Swallowed then
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end
	-- release / cancel: sink it when the press was ours, so nothing below sees half a press
	local swallowed = Back.Swallowed
	Back.Swallowed = false
	if swallowed then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- Binds B while a window, the odds popup or the roulette stage is open and unbinds it when none is.
-- Called after every change of openId / Odds.Gui / Spin.Stage.
function syncBackBinding()
	local wanted = openId ~= nil or Odds.Gui ~= nil or Spin.Stage ~= nil
	if wanted == Back.Bound then
		return
	end
	if wanted then
		Back.Bound = true
		local ok, err = pcall(function()
			ContextActionService:BindActionAtPriority(
				BACK_ACTION,
				onBackAction,
				false,
				Enum.ContextActionPriority.High.Value,
				Enum.KeyCode.ButtonB
			)
		end)
		if not ok then
			warnOnce("bind back", err)
		end
	elseif Back.Busy then
		-- the press that closed the last thing is still being dispatched: unbind right after it
		task.defer(syncBackBinding)
	else
		Back.Bound = false
		pcall(function()
			ContextActionService:UnbindAction(BACK_ACTION)
		end)
	end
end

----------------------------------------------------------------------
-- Menu column (left-centre)
----------------------------------------------------------------------
local Entries = {} -- { Id, Root, Icon, Caption, Active }

local function menuActionInventory()
	toggleWindow("Inventory", { Tab = "Items" })
end

local function menuActionPets()
	toggleWindow("Inventory", { Tab = "Pets" })
end

local function menuActionShop()
	if inMatch() then
		showHint("The shop is closed during a match.", "info")
		return
	end
	toggleWindow("Shop")
end

local function menuActionSpot()
	if inMatch() then
		showHint("You cannot go home during a match.", "info")
		return
	end
	local spot = LocalPlayer:GetAttribute(Config.Attr.SpotIndex)
	if spot == nil and State.Get().SpotIndex == nil then
		showHint("You have no spot yet. Try again in a moment.", "info")
		return
	end
	closeEverything()
	fire("GoToSpot")
end

local function menuActionStats()
	toggleWindow("Stats")
end

local MENU = {
	{ Id = "Inventory", Label = "Inventory", Glyph = G.Backpack, Color = BUTTONS.Blue, Action = menuActionInventory },
	{ Id = "Pets", Label = "Pets", Glyph = G.Paw, Color = BUTTONS.Pink, Action = menuActionPets },
	{ Id = "Shop", Label = "Shop", Glyph = G.Money, Color = BUTTONS.Gold, Action = menuActionShop },
	{ Id = "Spot", Label = "My Spot", Glyph = G.House, Color = BUTTONS.Green, Action = menuActionSpot },
	{ Id = "Stats", Label = "Stats", Glyph = G.Chart, Color = PURPLE, Action = menuActionStats },
}

local function buildColumn()
	local column = makeFrame(gui, "MenuColumn", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, EDGE, 0.5, 0),
		Size = UDim2.fromOffset(COL_W, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 2,
	})
	listLayout(column, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center)
	U.Column = column
	U.ColumnScale = Util.Create("UIScale", { Name = "ViewportScale", Scale = 1, Parent = column })

	for index, spec in ipairs(MENU) do
		local entry = { Id = spec.Id }
		entry.Root = makeFrame(column, "Entry_" .. spec.Id, {
			Size = UDim2.fromOffset(COL_W, BTN + CAPTION_H),
			LayoutOrder = index,
		})
		entry.Icon = CloudUI.IconButton({
			Name = "Menu_" .. spec.Id,
			Glyph = spec.Glyph,
			Color = spec.Color,
			Size = UDim2.fromOffset(BTN, BTN),
			Position = UDim2.new(0.5, 0, 0, 0),
			AnchorPoint = Vector2.new(0.5, 0),
			Callback = function()
				safe("menu " .. spec.Id, spec.Action)
			end,
			Parent = entry.Root,
		})
		entry.Caption = makeText(entry.Root, "Caption", spec.Label, "Heading", 13, WHITE, {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, 0),
			Size = UDim2.new(1, 30, 0, CAPTION_H),
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextStrokeTransparency = 0.1,
		})
		entry.Active = makeFrame(entry.Root, "ActiveTab", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, -7, 0, BTN / 2),
			Size = UDim2.fromOffset(6, 32),
			BackgroundTransparency = 0,
			BackgroundColor3 = GOLD,
			Visible = false,
		})
		round(entry.Active)
		stroke(entry.Active, NAVY, 2, 0)
		Entries[spec.Id] = entry
	end
end

-- Compact screens drop the captions; the whole column is scaled with the screen like the HUD.
local function relayoutMenu()
	if not gui or not U.Column then
		return
	end
	local size = guiSize()
	local compact = size.Y < COMPACT_BELOW
	local scale = Util.Clamp(math.min(size.X / REF_W, size.Y / REF_H), 0.72, 1.2)
	U.ColumnScale.Scale = scale
	local margin = screenMargin()
	U.Column.Position = UDim2.new(0, margin, 0.5, 0)
	for _, entry in pairs(Entries) do
		entry.Caption.Visible = not compact
		entry.Root.Size = UDim2.fromOffset(COL_W, compact and BTN or (BTN + CAPTION_H))
	end
	if Hint.Frame then
		Hint.Frame.Position = UDim2.new(0, margin + (COL_W + 6) * scale, 0.5, 0)
	end
	for _, win in pairs(windows) do
		if win.Shown then
			win.Fit.Scale = fitScale(win.Size[1], win.Size[2])
		end
	end
	if Spin.Stage and Spin.Stage.Relayout then
		Spin.Stage.Relayout()
	end
end

function updateMenuActive()
	local invWin = windows.Inventory
	local invTab = invWin and invWin.Shown and invWin.Tab or nil
	local function mark(id, on)
		local entry = Entries[id]
		if entry then
			entry.Active.Visible = on and true or false
		end
	end
	mark("Inventory", invTab == "Items")
	mark("Pets", invTab == "Pets")
	mark("Shop", windows.Shop ~= nil and windows.Shop.Shown)
	mark("Stats", windows.Stats ~= nil and windows.Stats.Shown)
	if invWin and invWin.Shown and Entries.Pets then
		Entries.Pets.Icon.SetBadge(false)
	end
	-- the Spot button is greyed out in matches
	local spotEntry = Entries.Spot
	if spotEntry then
		spotEntry.Icon.SetColor(inMatch() and BUTTONS.Gray or BUTTONS.Green)
	end
	local shopEntry = Entries.Shop
	if shopEntry then
		shopEntry.Icon.SetColor(inMatch() and BUTTONS.Gray or BUTTONS.Gold)
	end
end

----------------------------------------------------------------------
-- Shared card look for the dark inset panels used inside the windows
----------------------------------------------------------------------
local INSET_COLOR = Color3.fromRGB(20, 30, 70)

local function makeInset(parent, name, props)
	local p = props or {}
	p.BackgroundColor3 = INSET_COLOR
	p.BackgroundTransparency = 0.45
	local inset = makeFrame(parent, name, p)
	corner(inset, 12)
	stroke(inset, WELL_EDGE, 3, 0.2)
	return inset
end

local function gotoShopItems()
	if inMatch() then
		showHint("The shop is closed during a match.", "info")
		return
	end
	openWindow("Shop", { Tab = "Items" })
end

----------------------------------------------------------------------
-- Inventory window: tabs Pets + Items
----------------------------------------------------------------------
local function buildInventory(win)
	local content = win.Panel.Content
	local maxEquipped = Config.Pets.MaxEquipped
	local pets = {
		Slots = {}, -- petId -> CloudUI slot in the grid
		EquipSlots = {}, -- 1..MaxEquipped -> small slots in the header
		EquipIds = {}, -- pet id shown by each header slot
		Selected = nil,
		DetailPet = nil,
		DetailViewport = nil,
		PillRarity = nil,
		Pill = nil,
		Order = {}, -- owned pet ids in grid order (rarest first)
		Ready = {}, -- petId -> true once the grid slot got its pet viewport
		Filling = false, -- true while the staggered viewport builder is running
	}
	local itemRows = {} -- itemId -> { Slot, Owned }
	local W = {} -- widgets of the pets page
	local refreshInventory

	local tabs = CloudUI.Tabs({
		Name = "InventoryTabs",
		Parent = content,
		Position = UDim2.fromOffset(10, 8),
		Size = UDim2.new(1, -20, 1, -16),
		OnSelect = function(name)
			win.Tab = name
			updateMenuActive()
		end,
	})
	win.Tabs = tabs

	------------------------------------------------------------------
	-- Pets page
	------------------------------------------------------------------
	local function buildPetsPage(page)
		local left = makeFrame(page, "Left", { Size = UDim2.new(0, 468, 1, 0) })

		local equipWidth = maxEquipped * 48 + (maxEquipped - 1) * 6
		local header = makeFrame(left, "Header", { Size = UDim2.new(1, 0, 0, 62) })
		W.EquippedLabel = makeText(header, "EquippedLabel", "Equipped", "Heading", 20, WHITE, {
			Position = UDim2.fromOffset(4, 0),
			Size = UDim2.new(1, -(equipWidth + 12), 0, 26),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		W.PerksLabel = makeText(header, "TeamPerks", "", "Body", 13, MUTED, {
			Position = UDim2.fromOffset(4, 27),
			Size = UDim2.new(1, -(equipWidth + 12), 0, 34),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		local equipRow = makeFrame(header, "EquippedSlots", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.fromOffset(equipWidth, 52),
		})
		listLayout(equipRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
		for i = 1, maxEquipped do
			pets.EquipSlots[i] = CloudUI.Slot({
				Name = "Equipped" .. i,
				Size = UDim2.fromOffset(48, 48),
				LayoutOrder = i,
				Parent = equipRow,
				Callback = function()
					local id = pets.EquipIds[i]
					if id then
						pets.Selected = id
						refreshInventory()
					end
				end,
			})
		end

		local well = makeInset(left, "GridWell", {
			Position = UDim2.fromOffset(0, 68),
			Size = UDim2.new(1, 0, 1, -68),
		})
		W.Grid = CloudUI.Grid(well, UDim2.fromOffset(80, 80), 8)

		W.Empty = makeFrame(well, "Empty", { Size = UDim2.new(1, 0, 1, 0), Visible = false, ZIndex = 5 })
		listLayout(W.Empty, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		W.EmptyTitle = makeText(W.Empty, "Title", "No pets yet!", "Title", 28, WHITE, {
			Size = UDim2.new(1, -30, 0, 36),
			LayoutOrder = 1,
		})
		W.EmptyBody = makeText(W.Empty, "Body", "Spin a roulette in the Shop to hatch your first winged friend.", "Body", 16, MUTED, {
			Size = UDim2.new(1, -60, 0, 52),
			TextWrapped = true,
			LayoutOrder = 2,
		})
		W.EmptyButton = CloudUI.Button({
			Name = "OpenShop",
			Text = "Open Shop",
			Style = "Gold",
			Size = UDim2.fromOffset(180, 46),
			LayoutOrder = 3,
			Callback = function()
				menuActionShop()
			end,
			Parent = W.Empty,
		})

		-- detail card
		local card = makeInset(page, "Detail", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(0, 272, 1, 0),
		})
		W.DetailEmpty = makeText(card, "Hint", "Pick a pet to see its details.", "Body", 16, MUTED, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.new(1, -40, 0, 60),
			TextWrapped = true,
		})
		local body = makeFrame(card, "Body", { Size = UDim2.new(1, 0, 1, 0), Visible = false })
		W.DetailBody = body
		W.Glow = makeFrame(body, "Glow", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 16),
			Size = UDim2.fromOffset(150, 150),
			BackgroundColor3 = GOLD,
			BackgroundTransparency = 0.78,
		})
		round(W.Glow)
		W.ViewportHolder = makeFrame(body, "ViewportHolder", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 6),
			Size = UDim2.fromOffset(240, 170),
		})
		W.Name = makeText(body, "Name", "", "Title", 25, WHITE, {
			Position = UDim2.fromOffset(0, 180),
			Size = UDim2.new(1, 0, 0, 30),
		})
		W.MetaRow = makeFrame(body, "Meta", {
			Position = UDim2.fromOffset(0, 212),
			Size = UDim2.new(1, 0, 0, 26),
		})
		listLayout(W.MetaRow, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		W.OwnedLabel = makeText(W.MetaRow, "Owned", "", "Heading", 14, MUTED, {
			Size = UDim2.fromOffset(120, 24),
			LayoutOrder = 2,
		})
		W.Blurb = makeText(body, "Blurb", "", "Body", 14, WHITE, {
			Position = UDim2.fromOffset(14, 242),
			Size = UDim2.new(1, -28, 0, 58),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		W.Perks = makeText(body, "Perks", "", "Heading", 15, Theme.Lighten(GOOD, 0.2), {
			Position = UDim2.fromOffset(14, 302),
			Size = UDim2.new(1, -28, 0, 44),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		W.EquipBtn = CloudUI.Button({
			Name = "Equip",
			Text = "Equip",
			Style = "Green",
			Size = UDim2.fromOffset(122, 42),
			Position = UDim2.new(0, 10, 0, 354),
			TextSize = 20,
			Callback = function()
				if pets.Selected then
					fire("EquipPet", pets.Selected)
				end
			end,
			Parent = body,
		})
		W.UnequipBtn = CloudUI.Button({
			Name = "Unequip",
			Text = "Unequip",
			Style = "Pink",
			Size = UDim2.fromOffset(122, 42),
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 354),
			TextSize = 20,
			Callback = function()
				if pets.Selected then
					fire("UnequipPet", pets.Selected)
				end
			end,
			Parent = body,
		})
		W.Status = makeText(body, "Status", "", "Label", 12, MUTED, {
			Position = UDim2.fromOffset(10, 402),
			Size = UDim2.new(1, -20, 0, 18),
		})
	end

	local function renderDetail()
		local id = pets.Selected
		local def = id and PetCatalog.Get(id) or nil
		local owned = def and State.OwnedCount(id) or 0
		if not def or owned <= 0 then
			W.DetailBody.Visible = false
			W.DetailEmpty.Visible = true
			if pets.DetailViewport then
				pets.DetailViewport.Destroy()
				pets.DetailViewport = nil
				pets.DetailPet = nil
			end
			return
		end
		W.DetailBody.Visible = true
		W.DetailEmpty.Visible = false

		local color = rarityOf(def)
		if pets.DetailPet ~= id then
			if pets.DetailViewport then
				pets.DetailViewport.Destroy()
			end
			pets.DetailViewport = CloudUI.PetViewport(W.ViewportHolder, def, UDim2.new(1, 0, 1, 0), {
				Spin = "spin",
				ZIndex = 2,
			})
			pets.DetailPet = id
		end
		W.Glow.BackgroundColor3 = color
		W.Name.Text = def.Name
		W.Name.TextColor3 = Theme.Lighten(color, 0.3)
		if pets.PillRarity ~= def.Rarity then
			if pets.Pill then
				pets.Pill:Destroy()
			end
			pets.Pill = CloudUI.Pill(def.Rarity, def.Rarity, W.MetaRow)
			pets.Pill.LayoutOrder = 1
			pets.PillRarity = def.Rarity
		end

		local equipped = State.EquippedCount(id)
		local text = "Owned x" .. owned
		if equipped > 0 then
			text = text .. "  " .. G.Star .. equipped
		end
		W.OwnedLabel.Text = text
		W.Blurb.Text = def.Blurb or ""
		local lines = perkLines(def)
		if #lines > 0 then
			W.Perks.Text = table.concat(lines, "\n")
		else
			W.Perks.Text = "No perks"
		end

		local totalEquipped = #State.Get().Equipped
		local canEquip = equipped < owned and totalEquipped < maxEquipped
		CloudUI.SetDisabled(W.EquipBtn, not canEquip)
		CloudUI.SetDisabled(W.UnequipBtn, equipped <= 0)
		local status = ""
		if equipped >= owned then
			status = "All your copies are equipped."
		elseif totalEquipped >= maxEquipped then
			status = "Your team is full. Unequip a pet first."
		end
		W.Status.Text = status
	end

	-- Content of a grid slot. The pet viewport (a PetBuilder model of 35-66 parts, a ViewportFrame and a
	-- Camera) is attached by fillPetSlots, a few per frame, so a big collection never builds ~30 models in
	-- the frame the Inventory opens (same idea as the odds popup). Until then a slot is its rarity tile.
	local function gridInfo(def, withPet)
		local info = {
			RarityColor = rarityOf(def),
			Name = def.Name .. " (" .. def.Rarity .. ")",
			Blurb = def.Blurb,
		}
		if withPet then
			info.Pet = def
		end
		return info
	end

	local function fillPetSlots()
		if pets.Filling then
			return
		end
		local function buildBatch()
			local built = 0
			for _, id in ipairs(pets.Order) do
				local slot = pets.Slots[id]
				local def = PetCatalog.Get(id)
				if slot and def and not pets.Ready[id] then
					pets.Ready[id] = true
					slot.SetContent(gridInfo(def, true))
					slot.SetCount(State.OwnedCount(id)) -- pet slots hide "x1": needs the Pet content to be set first
					built = built + 1
					if built >= PETS_PER_FRAME then
						break
					end
				end
			end
			return built
		end
		pets.Filling = true
		task.spawn(function()
			-- stops when the window closes; the next open refreshes it and resumes with what is still missing
			while win.Shown do
				local ok, built = pcall(buildBatch)
				if not ok then
					warnOnce("fill pets", built)
					break
				end
				if built < PETS_PER_FRAME then
					break
				end
				task.wait()
			end
			pets.Filling = false
		end)
	end

	local function refreshPetsPage()
		local ids = ownedPetIds()
		local ownedSet = {}
		for _, id in ipairs(ids) do
			ownedSet[id] = true
		end
		local snapshot = State.Get()

		-- keep the selection valid: prefer an equipped pet, else the rarest one
		if not (pets.Selected and ownedSet[pets.Selected]) then
			pets.Selected = nil
			for _, id in ipairs(snapshot.Equipped) do
				if ownedSet[id] then
					pets.Selected = id
					break
				end
			end
			if not pets.Selected then
				pets.Selected = ids[1]
			end
		end

		-- drop slots of pets that are gone, add slots for new ones, update the rest in place
		for id, slot in pairs(pets.Slots) do
			if not ownedSet[id] then
				slot.Destroy()
				pets.Slots[id] = nil
				pets.Ready[id] = nil
			end
		end
		pets.Order = ids
		for index, id in ipairs(ids) do
			local def = PetCatalog.Get(id)
			local slot = pets.Slots[id]
			if not slot then
				slot = CloudUI.Slot({
					Name = "Pet_" .. id,
					Size = UDim2.fromOffset(80, 80),
					Parent = W.Grid,
					Callback = function()
						pets.Selected = id
						refreshInventory()
					end,
				})
				pets.Slots[id] = slot
			end
			slot.Root.LayoutOrder = index
			local ready = pets.Ready[id] == true
			local owned = State.OwnedCount(id)
			slot.SetContent(gridInfo(def, ready))
			if ready or owned > 1 then
				slot.SetCount(owned)
			else
				slot.SetCount(nil) -- a tile without its pet yet would show "x1"
			end
			if State.IsEquipped(id) then
				slot.SetMarker(G.Star, GOLD)
			else
				slot.SetMarker(nil)
			end
			slot.SetSelected(id == pets.Selected)
		end
		W.Grid.Visible = #ids > 0
		W.Empty.Visible = #ids == 0
		if #ids == 0 then
			local loaded = (State.IsLoaded == nil) or State.IsLoaded()
			if loaded then
				W.EmptyTitle.Text = "No pets yet!"
				W.EmptyBody.Text = "Spin a roulette in the Shop to hatch your first winged friend."
			else
				W.EmptyTitle.Text = "Loading..."
				W.EmptyBody.Text = "Fetching your pets from the clouds."
			end
			W.EmptyButton.Visible = loaded
		end

		-- header: equipped count, team perks, equipped mini slots
		local equipped = snapshot.Equipped
		W.EquippedLabel.Text = string.format("Equipped %d/%d", #equipped, maxEquipped)
		for i = 1, maxEquipped do
			local slot = pets.EquipSlots[i]
			local id = equipped[i]
			local def = id and PetCatalog.Get(id) or nil
			if slot then
				if def then
					pets.EquipIds[i] = id
					slot.SetContent({ Pet = def, RarityColor = rarityOf(def), Name = def.Name, Blurb = def.Blurb })
					slot.SetSelected(id == pets.Selected)
				else
					pets.EquipIds[i] = nil
					slot.SetContent(nil)
					slot.SetSelected(false)
				end
			end
		end
		local perkParts = {}
		local order = PetCatalog.PerkOrder or { "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }
		for _, key in ipairs(order) do
			local value = snapshot.Perks[key]
			if type(value) == "number" and value > 0 then
				table.insert(perkParts, PetCatalog.PerkLabel(key, value))
			end
		end
		if #perkParts > 0 then
			W.PerksLabel.Text = "Team perks: " .. table.concat(perkParts, "   ")
		else
			W.PerksLabel.Text = "Equip pets to gain perks."
		end

		fillPetSlots() -- last: the first batch of grid viewports is built right here, the rest follow per frame
	end

	------------------------------------------------------------------
	-- Items page
	------------------------------------------------------------------
	local function buildItemsPage(page)
		listLayout(page, Enum.FillDirection.Vertical, 8)
		for index, def in ipairs(itemList()) do
			local row = makeInset(page, "Row_" .. def.Id, {
				Size = UDim2.new(1, 0, 0, 92),
				LayoutOrder = index,
			})
			local slot = CloudUI.Slot({
				Name = "Item_" .. def.Id,
				Size = UDim2.fromOffset(72, 72),
				Position = UDim2.fromOffset(10, 10),
				Hotkey = tostring(index),
				Parent = row,
			})
			slot.SetContent({
				Glyph = def.Glyph,
				Color = def.Color,
				RarityColor = CloudUI.RarityColor(def.Rarity),
				Name = def.Name,
				Blurb = def.Blurb,
			})
			makeText(row, "Name", def.Name, "Title", 22, Theme.Lighten(def.Color, 0.35), {
				Position = UDim2.fromOffset(96, 8),
				Size = UDim2.new(1, -330, 0, 28),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			makeText(row, "Price", cloudAmount(def.Price) .. " each", "Heading", 16, Colors.Token, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -180, 0, 10),
				Size = UDim2.fromOffset(130, 24),
				TextXAlignment = Enum.TextXAlignment.Right,
			})
			local owned = makeText(row, "Owned", "", "Heading", 15, WHITE, {
				Position = UDim2.fromOffset(96, 37),
				Size = UDim2.new(1, -290, 0, 20),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			makeText(row, "Blurb", def.Blurb or "", "Body", 13, MUTED, {
				Position = UDim2.fromOffset(96, 58),
				Size = UDim2.new(1, -290, 0, 30),
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
			})
			CloudUI.Button({
				Name = "GetMore",
				Text = "Get more",
				Style = "Blue",
				Size = UDim2.fromOffset(150, 44),
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				TextSize = 20,
				Callback = gotoShopItems,
				Parent = row,
			})
			itemRows[def.Id] = { Slot = slot, Owned = owned, Def = def }
		end

		-- the fourth hotbar key is reserved for later
		local locked = makeInset(page, "LockedRow", {
			Size = UDim2.new(1, 0, 0, 52),
			LayoutOrder = 50,
		})
		makeText(locked, "Text", G.Lock .. "  Slot " .. (#itemList() + 1) .. "   More items are coming soon.", "Heading", 16, MUTED, {
			Position = UDim2.fromOffset(16, 0),
			Size = UDim2.new(1, -32, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		makeText(page, "Tip", "Items only work during a match: press 1-" .. #itemList() .. " or tap the hotbar.", "Body", 14, MUTED, {
			Size = UDim2.new(1, 0, 0, 24),
			LayoutOrder = 60,
		})
	end

	local function refreshItemsPage()
		local maxCarry = Config.Items.MaxCarry
		for id, row in pairs(itemRows) do
			local count = State.ItemCount(id)
			row.Slot.SetCount(count)
			row.Slot.SetDimmed(count <= 0)
			row.Owned.Text = string.format("In bag: %d / %d", count, maxCarry)
		end
	end

	function refreshInventory()
		refreshPetsPage()
		renderDetail()
		refreshItemsPage()
	end

	tabs.Add("Pets", buildPetsPage)
	tabs.Add("Items", buildItemsPage)

	win.Refresh = refreshInventory
	win.OnOpen = function(args)
		local tab = normalizeTab("Inventory", args.Tab)
		if tab then
			tabs.Select(tab)
		end
	end
end

----------------------------------------------------------------------
-- Odds popup (opened from a roulette card; pets grouped by rarity with their exact chances)
----------------------------------------------------------------------
function closeOdds()
	Odds.Token = Odds.Token + 1
	for _, slot in ipairs(Odds.Slots) do
		pcall(slot.Destroy)
	end
	Odds.Slots = {}
	if Odds.Gui then
		Odds.Gui:Destroy()
		Odds.Gui = nil
	end
	syncBackBinding()
end

function openOdds(rouletteId)
	local roulette = findRoulette(rouletteId)
	if not roulette or not gui then
		return
	end
	closeOdds()
	Odds.Token = Odds.Token + 1
	local mine = Odds.Token

	local root = makeFrame(gui, "OddsPopup", { Size = UDim2.new(1, 0, 1, 0), ZIndex = 8 })
	Odds.Gui = root
	syncBackBinding()
	local dim = Util.Create("TextButton", {
		Name = "Backdrop",
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		BackgroundColor3 = Color3.fromRGB(8, 12, 32),
		BackgroundTransparency = 0.45,
		Size = UDim2.new(1, 0, 1, 0),
		Parent = root,
	})
	dim.Activated:Connect(function()
		closeOdds()
	end)

	local width, height = 620, 500
	local holder = makeFrame(root, "Holder", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 14),
		Size = UDim2.fromOffset(width, height),
		ZIndex = 2,
	})
	Util.Create("UIScale", { Name = "Fit", Scale = fitScale(width, height), Parent = holder })
	local panel = CloudUI.Panel({
		Name = "OddsPanel",
		Title = roulette.DisplayName .. " Odds",
		Closable = true,
		Accent = roulette.Color,
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		OnClose = function()
			closeOdds()
		end,
		Parent = holder,
	})
	local pop = Util.Create("UIScale", { Name = "Pop", Scale = 0.88, Parent = panel.Root })
	tween(pop, 0.2, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

	local scroll = Util.Create("ScrollingFrame", {
		Name = "OddsList",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(1, -16, 1, -16),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Colors.FrameTop or Colors.Cloud,
		Parent = panel.Content,
	})
	pad(scroll, 4, 2, 6, 6)
	listLayout(scroll, Enum.FillDirection.Vertical, 10)
	makeText(scroll, "Note", "Chance per spin. Pets of the same rarity share that rarity's chance equally.", "Body", 14, MUTED, {
		Size = UDim2.new(1, -8, 0, 36),
		TextWrapped = true,
		LayoutOrder = 0,
	})

	-- group the exact odds by rarity
	local groups = {}
	local byRarity = {}
	for _, entry in ipairs(PetCatalog.GetOdds(rouletteId)) do
		local group = byRarity[entry.Rarity]
		if not group then
			group = { Rarity = entry.Rarity, Total = 0, Entries = {} }
			byRarity[entry.Rarity] = group
			table.insert(groups, group)
		end
		group.Total = group.Total + entry.Chance
		table.insert(group.Entries, entry)
	end
	table.sort(groups, function(a, b)
		return rarityOrder(a.Rarity) > rarityOrder(b.Rarity)
	end)

	-- built a few pets per frame so opening the popup never hitches
	task.spawn(function()
		local built = 0
		for index, group in ipairs(groups) do
			if Odds.Token ~= mine then
				return
			end
			local color = CloudUI.RarityColor(group.Rarity)
			local header = makeFrame(scroll, "Header_" .. group.Rarity, {
				Size = UDim2.new(1, -8, 0, 36),
				BackgroundTransparency = 0,
				BackgroundColor3 = Theme.Darken(color, 0.35),
				LayoutOrder = index * 2 - 1,
			})
			corner(header, 10)
			stroke(header, NAVY, 3, 0)
			makeText(header, "Rarity", group.Rarity, "Title", 21, Theme.Lighten(color, 0.4), {
				Position = UDim2.fromOffset(12, 0),
				Size = UDim2.new(0.5, 0, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			makeText(header, "Chance", percentText(group.Total) .. "  total", "Heading", 16, WHITE, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -12, 0, 0),
				Size = UDim2.new(0.5, 0, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Right,
			})

			local cells = makeFrame(scroll, "Cells_" .. group.Rarity, {
				Size = UDim2.new(1, -8, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = index * 2,
			})
			Util.Create("UIGridLayout", {
				CellSize = UDim2.fromOffset(84, 100),
				CellPadding = UDim2.fromOffset(6, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
				Parent = cells,
			})
			for cellIndex, entry in ipairs(group.Entries) do
				if Odds.Token ~= mine then
					return
				end
				local def = PetCatalog.Get(entry.PetId)
				local cell = makeFrame(cells, "Cell_" .. tostring(entry.PetId), { LayoutOrder = cellIndex })
				if def then
					local slot = CloudUI.Slot({
						Name = "OddsPet",
						Size = UDim2.fromOffset(66, 66),
						AnchorPoint = Vector2.new(0.5, 0),
						Position = UDim2.new(0.5, 0, 0, 2),
						Parent = cell,
					})
					slot.SetContent({ Pet = def, RarityColor = color, Name = def.Name, Blurb = def.Blurb })
					table.insert(Odds.Slots, slot)
				end
				makeText(cell, "Percent", percentText(entry.Chance), "Heading", 14, WHITE, {
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.new(0.5, 0, 1, -2),
					Size = UDim2.new(1, 0, 0, 20),
				})
				built = built + 1
				if built % 3 == 0 then
					task.wait()
				end
			end
		end
	end)
end

----------------------------------------------------------------------
-- Shop window: tabs Roulettes + Items
----------------------------------------------------------------------
local function bestRarityOf(roulette)
	local bestId, bestOrder = nil, 0
	for _, r in ipairs(Config.Rarities) do
		local weight = roulette.Odds[r.Id]
		if type(weight) == "number" and weight > 0 and r.Order > bestOrder then
			bestId, bestOrder = r.Id, r.Order
		end
	end
	return bestId
end

local function buildShop(win)
	local content = win.Panel.Content
	local shop = { Cards = {}, ItemCards = {}, Bobs = {} }
	local W = {}

	local tabs = CloudUI.Tabs({
		Name = "ShopTabs",
		Parent = content,
		Position = UDim2.fromOffset(10, 8),
		Size = UDim2.new(1, -20, 1, -16),
		OnSelect = function(name)
			win.Tab = name
			updateMenuActive()
		end,
	})
	win.Tabs = tabs

	-- token balance, right of the tab strip
	local balance = makeFrame(content, "Balance", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 11),
		Size = UDim2.fromOffset(190, 34),
		BackgroundColor3 = Colors.Panel,
		BackgroundTransparency = 0.08,
		ZIndex = 8,
	})
	round(balance)
	stroke(balance, NAVY, 3, 0)
	W.Balance = makeText(balance, "Amount", "", "Display", 22, Colors.Token, {
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(1, -12, 1, 0),
		ZIndex = 9,
	})

	------------------------------------------------------------------
	-- Roulette cards
	------------------------------------------------------------------
	local function buildRouletteCard(parent, roulette, index)
		local color = roulette.Color
		local card = makeFrame(parent, "Roulette_" .. roulette.Id, {
			Size = UDim2.fromOffset(186, 424),
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0,
			LayoutOrder = index,
		})
		corner(card, 14)
		local cardStroke = stroke(card, NAVY, 4, 0)
		Theme.Gradient(card, Theme.Darken(color, 0.3), Theme.Darken(color, 0.7), 90)

		-- name banner
		local banner = makeFrame(card, "Banner", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 8),
			Size = UDim2.new(1, -16, 0, 46),
			BackgroundTransparency = 0,
			BackgroundColor3 = Theme.Lighten(color, 0.1),
		})
		corner(banner, 10)
		stroke(banner, NAVY, 3, 0)
		local bannerText = makeText(banner, "Name", roulette.DisplayName, "Title", 20, WHITE, {
			Position = UDim2.fromOffset(6, 0),
			Size = UDim2.new(1, -12, 1, 0),
			TextScaled = true,
			TextWrapped = true,
			TextStrokeTransparency = 0.1,
			TextStrokeColor3 = Theme.Darken(color, 0.65),
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 10, Parent = bannerText })

		-- the roulette "machine": glossy dome on a base
		local base = makeFrame(card, "Base", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 142),
			Size = UDim2.fromOffset(124, 16),
			BackgroundTransparency = 0,
			BackgroundColor3 = Theme.Darken(color, 0.55),
		})
		corner(base, 8)
		stroke(base, NAVY, 3, 0)
		local dome = makeFrame(card, "Dome", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 58),
			Size = UDim2.fromOffset(100, 100),
			BackgroundTransparency = 0,
			BackgroundColor3 = WHITE,
		})
		round(dome)
		stroke(dome, NAVY, 4, 0)
		Theme.Gradient(dome, Theme.Lighten(color, 0.5), Theme.Darken(color, 0.08), 90)
		local shine = makeFrame(dome, "Shine", {
			Position = UDim2.fromScale(0.16, 0.1),
			Size = UDim2.fromScale(0.36, 0.2),
			BackgroundTransparency = 0.6,
			BackgroundColor3 = WHITE,
			Rotation = -28,
		})
		round(shine)
		local mark = makeText(dome, "Mark", "?", "Title", 54, WHITE, {
			Size = UDim2.new(1, 0, 1, 0),
			ZIndex = 3,
			TextStrokeTransparency = 0,
			TextStrokeColor3 = Theme.Darken(color, 0.65),
		})
		table.insert(
			shop.Bobs,
			TweenService:Create(
				mark,
				TweenInfo.new(1.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Position = UDim2.new(0, 0, 0, -6) }
			)
		)

		makeText(card, "Price", cloudAmount(roulette.Price), "Display", 28, Colors.Token, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 168),
			Size = UDim2.new(1, -12, 0, 34),
			TextStrokeTransparency = 0.1,
		})

		local best = bestRarityOf(roulette)
		if best then
			makeText(card, "Best", "Up to " .. best, "Heading", 15, Theme.Lighten(CloudUI.RarityColor(best), 0.35), {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 204),
				Size = UDim2.new(1, -12, 0, 22),
			})
		end
		local dots = makeFrame(card, "RarityDots", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 230),
			Size = UDim2.new(1, -12, 0, 14),
		})
		listLayout(dots, Enum.FillDirection.Horizontal, 5, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		for _, r in ipairs(Config.Rarities) do
			local weight = roulette.Odds[r.Id]
			if type(weight) == "number" and weight > 0 then
				local dot = makeFrame(dots, "Dot_" .. r.Id, {
					Size = UDim2.fromOffset(14, 14),
					BackgroundTransparency = 0,
					BackgroundColor3 = r.Color,
					LayoutOrder = r.Order,
				})
				round(dot)
				stroke(dot, NAVY, 2, 0)
			end
		end

		CloudUI.Button({
			Name = "Odds",
			Text = "Odds",
			Style = "Blue",
			Size = UDim2.fromOffset(110, 34),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 254),
			TextSize = 18,
			Callback = function()
				openOdds(roulette.Id)
			end,
			Parent = card,
		})
		local spinButton = CloudUI.Button({
			Name = "Spin",
			Text = "Spin",
			Style = "Green",
			Size = UDim2.fromOffset(150, 54),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 298),
			TextSize = 28,
			Callback = function()
				requestSpin(roulette.Id)
			end,
			Parent = card,
		})
		local hint = makeText(card, "Hint", "", "Heading", 13, MUTED, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 360),
			Size = UDim2.new(1, -20, 0, 50),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		return { Roulette = roulette, Root = card, Stroke = cardStroke, Spin = spinButton, Hint = hint }
	end

	local function buildRoulettePage(page)
		local row = makeFrame(page, "Row", { Size = UDim2.new(1, 0, 1, 0) })
		listLayout(row, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
		for index, roulette in ipairs(Config.Roulettes) do
			shop.Cards[roulette.Id] = buildRouletteCard(row, roulette, index)
		end
	end

	local function refreshRouletteCards()
		local tokens = State.Tokens()
		local match = inMatch()
		for _, card in pairs(shop.Cards) do
			local short = card.Roulette.Price - tokens
			local label, hint, disabled = "Spin", "Hatches a random winged pet.", false
			local hintColor = MUTED
			if match then
				disabled = true
				hint = "The shop is closed during matches."
			elseif Spin.Waiting then
				disabled = true
				label = "..."
				hint = "Spinning up..."
			elseif Spin.Stage then
				disabled = true
				hint = ""
			elseif short > 0 then
				disabled = true
				hint = "Need " .. commas(short) .. " " .. G.Cloud .. " more"
				hintColor = Theme.Lighten(BAD, 0.3)
			end
			card.Spin.Text = label
			CloudUI.SetDisabled(card.Spin, disabled)
			card.Hint.Text = hint
			card.Hint.TextColor3 = hintColor
		end
	end

	------------------------------------------------------------------
	-- Item cards
	------------------------------------------------------------------
	local function buildItemCard(parent, def, index)
		local card = makeFrame(parent, "Item_" .. def.Id, {
			Size = UDim2.fromOffset(254, 392),
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0,
			LayoutOrder = index,
		})
		corner(card, 14)
		stroke(card, NAVY, 4, 0)
		Theme.Gradient(card, Theme.Darken(def.Color, 0.3), Theme.Darken(def.Color, 0.7), 90)

		local slot = CloudUI.Slot({
			Name = "ItemSlot",
			Size = UDim2.fromOffset(96, 96),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 16),
			Hotkey = tostring(index),
			Parent = card,
		})
		slot.SetContent({
			Glyph = def.Glyph,
			Color = def.Color,
			RarityColor = CloudUI.RarityColor(def.Rarity),
			Name = def.Name,
			Blurb = def.Blurb,
		})
		makeText(card, "Name", def.Name, "Title", 24, Theme.Lighten(def.Color, 0.4), {
			Position = UDim2.fromOffset(0, 122),
			Size = UDim2.new(1, 0, 0, 32),
			TextStrokeTransparency = 0.1,
		})
		makeText(card, "Blurb", def.Blurb or "", "Body", 14, WHITE, {
			Position = UDim2.fromOffset(16, 156),
			Size = UDim2.new(1, -32, 0, 66),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		local owned = makeText(card, "Owned", "", "Heading", 16, MUTED, {
			Position = UDim2.fromOffset(0, 226),
			Size = UDim2.new(1, 0, 0, 22),
		})
		makeText(card, "Price", cloudAmount(def.Price), "Display", 28, Colors.Token, {
			Position = UDim2.fromOffset(0, 250),
			Size = UDim2.new(1, 0, 0, 34),
			TextStrokeTransparency = 0.1,
		})
		local buy = CloudUI.Button({
			Name = "Buy",
			Text = "Buy +1",
			Style = "Green",
			Size = UDim2.fromOffset(170, 52),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 294),
			TextSize = 24,
			Callback = function()
				if inMatch() then
					showHint("The shop is closed during a match.", "info")
					return
				end
				fire("BuyItem", def.Id, 1)
			end,
			Parent = card,
		})
		local hint = makeText(card, "Hint", "", "Heading", 13, MUTED, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 350),
			Size = UDim2.new(1, -20, 0, 36),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		return { Def = def, Slot = slot, Owned = owned, Buy = buy, Hint = hint }
	end

	local function buildItemsPage(page)
		local row = makeFrame(page, "Row", { Size = UDim2.new(1, 0, 0, 392) })
		listLayout(row, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
		for index, def in ipairs(itemList()) do
			shop.ItemCards[def.Id] = buildItemCard(row, def, index)
		end
		makeText(page, "Tip", "Items only work during a match. Use them from the hotbar with keys 1-" .. #itemList() .. " or by tapping.", "Body", 14, MUTED, {
			Position = UDim2.fromOffset(0, 398),
			Size = UDim2.new(1, 0, 0, 26),
		})
	end

	local function refreshItemCards()
		local tokens = State.Tokens()
		local match = inMatch()
		local maxCarry = Config.Items.MaxCarry
		for id, card in pairs(shop.ItemCards) do
			local count = State.ItemCount(id)
			card.Owned.Text = string.format("In bag: %d / %d", count, maxCarry)
			card.Slot.SetCount(count)
			card.Slot.SetDimmed(count <= 0)
			local label, hint, disabled = "Buy +1", "", false
			local hintColor = MUTED
			if match then
				disabled = true
				hint = "The shop is closed during matches."
			elseif count >= maxCarry then
				disabled = true
				label = "Full"
				hint = "You carry the maximum already."
			elseif tokens < card.Def.Price then
				disabled = true
				hint = "Need " .. commas(card.Def.Price - tokens) .. " " .. G.Cloud .. " more"
				hintColor = Theme.Lighten(BAD, 0.3)
			end
			card.Buy.Text = label
			CloudUI.SetDisabled(card.Buy, disabled)
			card.Hint.Text = hint
			card.Hint.TextColor3 = hintColor
		end
	end

	tabs.Add("Roulettes", buildRoulettePage)
	tabs.Add("Items", buildItemsPage)

	-- gold outline on the roulette the player walked up to (OpenPanel passes RouletteId)
	local function focusCard(rouletteId)
		local card = shop.Cards[rouletteId]
		if not card then
			return
		end
		card.Stroke.Color = GOLD
		card.Stroke.Thickness = 7
		task.delay(2.6, function()
			if card.Root.Parent then
				card.Stroke.Color = NAVY
				card.Stroke.Thickness = 4
			end
		end)
	end

	win.Refresh = function()
		W.Balance.Text = cloudAmount(State.Tokens())
		refreshRouletteCards()
		refreshItemCards()
	end
	win.OnOpen = function(args)
		local tab = normalizeTab("Shop", args.Tab)
		if not tab and type(args.RouletteId) == "string" then
			tab = "Roulettes"
		end
		if tab then
			tabs.Select(tab)
		end
		if type(args.RouletteId) == "string" then
			focusCard(args.RouletteId)
		end
		for _, bob in ipairs(shop.Bobs) do
			bob:Play()
		end
	end
	win.OnClose = function()
		for _, bob in ipairs(shop.Bobs) do
			bob:Cancel()
		end
	end
end

----------------------------------------------------------------------
-- Stats window
----------------------------------------------------------------------
local function buildStats(win)
	local content = win.Panel.Content
	local tiles = {} -- key -> value label
	local rows = {} -- difficulty id -> time label
	local perksLabel

	-- left: stat tiles + pet perks
	local left = makeFrame(content, "Left", {
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.new(0, 360, 1, -28),
	})
	local grid = makeFrame(left, "Tiles", { Size = UDim2.new(1, 0, 0, 320) })
	Util.Create("UIGridLayout", {
		CellSize = UDim2.fromOffset(176, 74),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	local TILES = {
		{ "Matches", "Matches played", WHITE },
		{ "Wins", "Victories", Theme.Lighten(GOOD, 0.2) },
		{ "WinRate", "Win rate", WHITE },
		{ "Tokens", "Cloud tokens", Colors.Token },
		{ "Earned", "Tokens earned", Colors.Token },
		{ "Spins", "Roulette spins", WHITE },
		{ "Found", "Pets discovered", Theme.Lighten(PURPLE, 0.3) },
		{ "Owned", "Pets owned", WHITE },
	}
	for index, spec in ipairs(TILES) do
		local tile = makeInset(grid, "Tile_" .. spec[1], { LayoutOrder = index })
		local value = makeText(tile, "Value", "0", "Display", 28, spec[3], {
			Position = UDim2.fromOffset(10, 6),
			Size = UDim2.new(1, -20, 0, 38),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
			TextStrokeTransparency = 0.15,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 28, MinTextSize = 12, Parent = value })
		makeText(tile, "Caption", spec[2], "Heading", 14, MUTED, {
			Position = UDim2.fromOffset(10, 46),
			Size = UDim2.new(1, -20, 0, 20),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		tiles[spec[1]] = value
	end

	local perks = makeInset(left, "Perks", {
		Position = UDim2.fromOffset(0, 330),
		Size = UDim2.new(1, 0, 1, -330),
	})
	makeText(perks, "Title", "Pet perks", "Heading", 16, WHITE, {
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	perksLabel = makeText(perks, "Lines", "", "Body", 14, Theme.Lighten(GOOD, 0.2), {
		Position = UDim2.fromOffset(12, 30),
		Size = UDim2.new(1, -24, 1, -34),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	-- right: best time per difficulty
	local right = makeInset(content, "BestTimes", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14),
		Size = UDim2.new(0, 316, 1, -28),
	})
	makeText(right, "Title", "Best times", "Title", 24, WHITE, {
		Position = UDim2.fromOffset(0, 8),
		Size = UDim2.new(1, 0, 0, 32),
	})
	local list = makeFrame(right, "List", {
		Position = UDim2.fromOffset(12, 48),
		Size = UDim2.new(1, -24, 1, -58),
	})
	listLayout(list, Enum.FillDirection.Vertical, 8)
	for index, difficulty in ipairs(Config.Difficulties) do
		local row = makeFrame(list, "Row_" .. difficulty.Id, {
			Size = UDim2.new(1, 0, 0, 56),
			BackgroundTransparency = 0,
			BackgroundColor3 = Theme.Darken(difficulty.Color, 0.55),
			LayoutOrder = index,
		})
		corner(row, 10)
		stroke(row, NAVY, 3, 0)
		local bar = makeFrame(row, "Bar", {
			Position = UDim2.fromOffset(5, 6),
			Size = UDim2.new(0, 6, 1, -12),
			BackgroundTransparency = 0,
			BackgroundColor3 = difficulty.Color,
		})
		round(bar)
		makeText(row, "Name", difficulty.DisplayName, "Title", 21, Theme.Lighten(difficulty.Color, 0.45), {
			Position = UDim2.fromOffset(20, 4),
			Size = UDim2.new(0.5, -20, 0, 26),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		makeText(row, "Stars", starText(difficulty.Stars), "Heading", 14, GOLD, {
			Position = UDim2.fromOffset(20, 30),
			Size = UDim2.new(0.5, -20, 0, 20),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		rows[difficulty.Id] = makeText(row, "Time", "--:--", "Display", 26, WHITE, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 0),
			Size = UDim2.new(0.5, 0, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
		})
	end

	win.Refresh = function()
		local snapshot = State.Get()
		local stats = snapshot.Stats
		local matches = stats.Matches or 0
		local wins = stats.Wins or 0
		tiles.Matches.Text = commas(matches)
		tiles.Wins.Text = commas(wins)
		if matches > 0 then
			tiles.WinRate.Text = string.format("%d%%", math.floor(wins / matches * 100 + 0.5))
		else
			tiles.WinRate.Text = G.Dash
		end
		tiles.Tokens.Text = cloudAmount(State.Tokens())
		tiles.Earned.Text = cloudAmount(stats.TokensEarned or 0)
		tiles.Spins.Text = commas(stats.Spins or 0)
		local distinct, total = petTotals()
		tiles.Found.Text = string.format("%d / %d", distinct, #(PetCatalog.Pets or {}))
		tiles.Owned.Text = commas(total)

		for id, label in pairs(rows) do
			local seconds = stats.BestTimes[id]
			if type(seconds) == "number" and seconds > 0 then
				label.Text = Util.FormatTime(seconds)
				label.TextColor3 = WHITE
			else
				label.Text = "--:--"
				label.TextColor3 = MUTED
			end
		end

		local lines = {}
		local order = PetCatalog.PerkOrder or { "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }
		for _, key in ipairs(order) do
			local value = snapshot.Perks[key]
			if type(value) == "number" and value > 0 then
				table.insert(lines, PetCatalog.PerkLabel(key, value))
			end
		end
		if #lines > 0 then
			perksLabel.Text = table.concat(lines, "     ")
			perksLabel.TextColor3 = Theme.Lighten(GOOD, 0.2)
		else
			perksLabel.Text = "No perks yet. Equip a pet in your inventory!"
			perksLabel.TextColor3 = MUTED
		end
	end
end

----------------------------------------------------------------------
-- Roulette flow: BuyRoulette -> RouletteResult -> scrolling strip -> reveal card
----------------------------------------------------------------------
local function refreshShopWindow()
	refreshWindow(windows.Shop)
end

function requestSpin(rouletteId)
	if Spin.Waiting or Spin.Stage then
		return
	end
	local roulette = findRoulette(rouletteId)
	if not roulette then
		return
	end
	if inMatch() then
		showHint("The shop is closed during a match.", "info")
		return
	end
	if State.Tokens() < roulette.Price then
		showHint("You need " .. cloudAmount(roulette.Price) .. " for that roulette.", "bad")
		return
	end
	if not fire("BuyRoulette", rouletteId) then
		return
	end
	Spin.Waiting = true
	Spin.WaitToken = Spin.WaitToken + 1
	local mine = Spin.WaitToken
	refreshShopWindow()
	task.delay(WAIT_TIMEOUT, function()
		if Spin.Waiting and Spin.WaitToken == mine then
			Spin.Waiting = false
			refreshShopWindow()
			showHint("The roulette did not answer. Try again.", "bad")
		end
	end)
end

-- Confetti squares flying out of `centre` (a UDim2 inside `parent`).
local function burst(parent, color, amount, centre)
	local rng = Random.new()
	for i = 1, amount do
		local size = rng:NextInteger(7, 13)
		local pick = i % 3
		local pieceColor = Theme.Lighten(color, 0.5)
		if pick == 0 then
			pieceColor = GOLD
		elseif pick == 1 then
			pieceColor = color
		end
		local piece = makeFrame(parent, "Confetti", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = centre,
			Size = UDim2.fromOffset(size, size),
			BackgroundTransparency = 0,
			BackgroundColor3 = pieceColor,
			Rotation = rng:NextInteger(0, 90),
			ZIndex = 10,
		})
		if i % 2 == 0 then
			round(piece)
		else
			corner(piece, 2)
		end
		local angle = rng:NextNumber(0, math.pi * 2)
		local distance = rng:NextNumber(70, 200)
		local target = UDim2.new(
			centre.X.Scale,
			centre.X.Offset + math.cos(angle) * distance,
			centre.Y.Scale,
			centre.Y.Offset + math.sin(angle) * distance * 0.8 - 24
		)
		local seconds = rng:NextNumber(0.7, 1.2)
		tween(piece, seconds, { Position = target, Rotation = piece.Rotation + rng:NextInteger(-220, 220) })
		tween(piece, seconds, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Debris:AddItem(piece, seconds + 0.1)
	end
end

-- Closes the stage (strip or reveal card) and starts the next queued result, if any.
function closeStage()
	local stage = Spin.Stage
	if not stage then
		return
	end
	Spin.Stage = nil
	syncBackBinding()
	stage.Phase = "closed"
	if stage.Conn then
		stage.Conn:Disconnect()
		stage.Conn = nil
	end
	for _, cell in pairs(stage.Cells) do
		pcall(cell.Viewport.Destroy)
	end
	stage.Cells = {}
	if stage.RevealViewport then
		pcall(stage.RevealViewport.Destroy)
		stage.RevealViewport = nil
	end
	if stage.Root then
		stage.Root:Destroy()
		stage.Root = nil
	end
	refreshShopWindow()
	local nextResult = table.remove(Spin.Queue, 1)
	if nextResult then
		task.delay(0.15, function()
			if not Spin.Stage then
				beginStage(nextResult)
			end
		end)
	end
end

function skipSpin()
	local stage = Spin.Stage
	if stage and stage.Phase ~= "reveal" then
		stage.Skip = true
	end
end

function beginStage(result)
	local def = PetCatalog.Get(result.PetId)
	if not def or not gui then
		showHint("A new pet joined your collection!", "good")
		return
	end
	local roulette = findRoulette(result.RouletteId)
	local rarityColor = rarityOf(def)
	local accent = roulette and roulette.Color or rarityColor
	local stage = { Phase = "spin", Def = def, Result = result, Cells = {}, Elapsed = 0, X = 0, Tick = 0 }
	Spin.Stage = stage
	syncBackBinding()
	closeOdds()
	refreshShopWindow()

	local root = makeFrame(gui, "RouletteStage", { Size = UDim2.new(1, 0, 1, 0), ZIndex = 20 })
	stage.Root = root
	local dim = Util.Create("TextButton", {
		Name = "Dim",
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		BackgroundColor3 = Color3.fromRGB(8, 12, 32),
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		Parent = root,
	})
	tween(dim, 0.25, { BackgroundTransparency = 0.3 })

	stage.Relayout = function()
		if stage.StripFit then
			stage.StripFit.Scale = fitScale(STAGE_W, STAGE_H)
		end
		if stage.RevealFit then
			stage.RevealFit.Scale = fitScale(REVEAL_W, REVEAL_H)
		end
	end

	------------------------------------------------------------------
	-- the strip: server-provided list, repaired where it is invalid, with the winner at STRIP.Target
	------------------------------------------------------------------
	local pool = {}
	if roulette and PetCatalog.PossiblePets then
		pool = PetCatalog.PossiblePets(roulette.Id) or {}
	end
	if #pool == 0 then
		pool = PetCatalog.Pets or {}
	end
	local rng = Random.new()
	local function randomPetId()
		if #pool == 0 then
			return def.Id
		end
		return pool[rng:NextInteger(1, #pool)].Id
	end
	local raw = type(result.Strip) == "table" and result.Strip or {}
	local strip = {}
	for i = 1, math.max(#raw, STRIP.MinCells) do
		local id = raw[i]
		if type(id) ~= "string" or not PetCatalog.Get(id) then
			id = randomPetId()
		end
		strip[i] = id
	end
	local target = STRIP.Target
	strip[target] = def.Id
	local cellW = STRIP.Cell
	local startX = 0
	local endX = (target - 1) * cellW + cellW / 2 - STRIP.W / 2 + rng:NextNumber(-cellW * 0.26, cellW * 0.26)

	local stripHolder = makeFrame(root, "StripHolder", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 14),
		Size = UDim2.fromOffset(STAGE_W, STAGE_H),
		ZIndex = 2,
	})
	stage.StripFit = Util.Create("UIScale", { Name = "Fit", Scale = fitScale(STAGE_W, STAGE_H), Parent = stripHolder })
	local stripPanel = CloudUI.Panel({
		Name = "StripPanel",
		Title = roulette and roulette.DisplayName or "Roulette",
		Closable = false,
		Accent = accent,
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = stripHolder,
	})
	local stripPop = Util.Create("UIScale", { Name = "Pop", Scale = 0.8, Parent = stripPanel.Root })
	tween(stripPop, 0.32, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local sc = stripPanel.Content

	local pointer = makeText(sc, "Pointer", G.Down, "Title", 30, GOLD, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(44, 36),
		ZIndex = 7,
		TextStrokeTransparency = 0,
	})
	local clip = makeFrame(sc, "StripClip", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 36),
		Size = UDim2.fromOffset(STRIP.W, STRIP.H),
		BackgroundTransparency = 0.35,
		BackgroundColor3 = Color3.fromRGB(14, 22, 58),
		ClipsDescendants = true,
		ZIndex = 2,
	})
	corner(clip, 12)
	stroke(clip, WELL_EDGE, 3, 0)
	local band = makeFrame(clip, "Band", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.fromOffset(cellW, STRIP.H - 6),
		BackgroundTransparency = 0.88,
		BackgroundColor3 = GOLD,
		ZIndex = 5,
	})
	corner(band, 12)
	stroke(band, GOLD, 3, 0)
	for i = 1, 2 do
		local name = "FadeRight"
		local sequence = NumberSequence.new(1, 0)
		if i == 1 then
			name = "FadeLeft"
			sequence = NumberSequence.new(0, 1)
		end
		local fade = makeFrame(clip, name, {
			AnchorPoint = Vector2.new(i - 1, 0),
			Position = UDim2.new(i - 1, 0, 0, 0),
			Size = UDim2.new(0, 90, 1, 0),
			BackgroundTransparency = 0,
			BackgroundColor3 = Color3.fromRGB(14, 22, 58),
			ZIndex = 6,
		})
		Util.Create("UIGradient", { Transparency = sequence, Parent = fade })
	end
	local status = makeText(sc, "Status", "Spinning...", "Heading", 18, MUTED, {
		Position = UDim2.fromOffset(14, 198),
		Size = UDim2.new(1, -140, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	CloudUI.Button({
		Name = "Skip",
		Text = "Skip",
		Style = "Blue",
		Size = UDim2.fromOffset(96, 32),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 196),
		TextSize = 18,
		Callback = function()
			skipSpin()
		end,
		Parent = sc,
	})

	-- cells are created only while they are near the window (one viewport per visible pet)
	local cells = stage.Cells
	local function destroyCell(index)
		local cell = cells[index]
		if cell then
			cells[index] = nil
			pcall(cell.Viewport.Destroy)
			cell.Frame:Destroy()
		end
	end
	local function makeCell(index)
		local cellDef = PetCatalog.Get(strip[index])
		local color = rarityOf(cellDef)
		local frame = makeFrame(clip, "Cell" .. index, {
			Size = UDim2.fromOffset(cellW - 8, STRIP.H - 16),
			BackgroundTransparency = 0,
			BackgroundColor3 = WHITE,
			ZIndex = 2,
		})
		corner(frame, 12)
		local frameStroke = stroke(frame, color, 3, 0)
		Theme.Gradient(frame, Colors.Mist, Colors.MistDeep:Lerp(color, 0.5), 90)
		local viewport = CloudUI.PetViewport(frame, cellDef, UDim2.new(1, -6, 1, -20), {
			Position = UDim2.new(0.5, 0, 0, 3),
			AnchorPoint = Vector2.new(0.5, 0),
			Animate = false,
			Spin = "sway",
			ZIndex = 2,
		})
		local tag = makeFrame(frame, "RarityBar", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -5),
			Size = UDim2.new(1, -20, 0, 8),
			BackgroundTransparency = 0,
			BackgroundColor3 = color,
		})
		round(tag)
		local cell = { Frame = frame, Viewport = viewport, Stroke = frameStroke }
		cells[index] = cell
		return cell
	end
	local function layoutCells(x)
		local first = math.max(1, math.floor(x / cellW))
		local last = math.min(#strip, math.floor((x + STRIP.W) / cellW) + 2)
		for index = first, last do
			local cell = cells[index] or makeCell(index)
			cell.Frame.Position = UDim2.fromOffset(math.floor((index - 1) * cellW - x + 4 + 0.5), 8)
		end
		for index in pairs(cells) do
			if index < first or index > last then
				destroyCell(index)
			end
		end
	end
	layoutCells(startX)

	------------------------------------------------------------------
	-- reveal card
	------------------------------------------------------------------
	local function updateReveal()
		if stage.Phase ~= "reveal" or not stage.EquipBtn then
			return
		end
		local equipped = State.EquippedCount(def.Id)
		local owned = State.OwnedCount(def.Id)
		local total = #State.Get().Equipped
		if equipped > 0 and equipped >= owned then
			stage.EquipBtn.Text = "Equipped"
			CloudUI.SetDisabled(stage.EquipBtn, true)
		elseif total >= Config.Pets.MaxEquipped then
			stage.EquipBtn.Text = "Team full"
			CloudUI.SetDisabled(stage.EquipBtn, true)
		else
			stage.EquipBtn.Text = "Equip"
			CloudUI.SetDisabled(stage.EquipBtn, false)
		end
		if stage.AgainBtn and roulette then
			stage.AgainBtn.Text = "Again " .. cloudAmount(roulette.Price)
			CloudUI.SetDisabled(stage.AgainBtn, State.Tokens() < roulette.Price or inMatch())
		end
	end
	stage.UpdateReveal = updateReveal

	local function showReveal()
		stage.Phase = "reveal"
		for index in pairs(cells) do
			destroyCell(index)
		end
		stripHolder:Destroy()
		stage.StripFit = nil

		local flash = makeFrame(root, "Flash", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 0.45,
			BackgroundColor3 = Theme.Lighten(rarityColor, 0.6),
			ZIndex = 9,
		})
		tween(flash, 0.55, { BackgroundTransparency = 1 })
		Debris:AddItem(flash, 0.7)

		local holder = makeFrame(root, "RevealHolder", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 14),
			Size = UDim2.fromOffset(REVEAL_W, REVEAL_H),
			ZIndex = 2,
		})
		stage.RevealFit = Util.Create("UIScale", { Name = "Fit", Scale = fitScale(REVEAL_W, REVEAL_H), Parent = holder })
		local panel = CloudUI.Panel({
			Name = "RevealPanel",
			Title = string.upper(def.Rarity),
			Closable = true,
			Accent = rarityColor,
			Size = UDim2.new(1, 0, 1, 0),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			OnClose = function()
				closeStage()
			end,
			Parent = holder,
		})
		local pop = Util.Create("UIScale", { Name = "Pop", Scale = 0.5, Parent = panel.Root })
		tween(pop, 0.5, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		local c = panel.Content
		local order = rarityOrder(def.Rarity)

		-- slowly turning rays + soft glow discs behind the pet (stronger for rarer pets)
		local rays = makeFrame(c, "Rays", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 128),
			Size = UDim2.fromOffset(330, 330),
			ZIndex = 1,
		})
		stage.Rays = rays
		local rayCount = 3 + order
		for i = 1, rayCount do
			local ray = makeFrame(rays, "Ray" .. i, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				Size = UDim2.fromOffset(18, 330),
				Rotation = (i - 1) * 180 / rayCount,
				BackgroundTransparency = 0.78 - order * 0.015,
				BackgroundColor3 = Theme.Lighten(rarityColor, 0.4),
				ZIndex = 1,
			})
			Util.Create("UIGradient", {
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.5, 0),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Parent = ray,
			})
		end
		local discs = { { 260, 0.86 }, { 204, 0.8 }, { 150, 0.72 } }
		for i, disc in ipairs(discs) do
			local glow = makeFrame(c, "Glow" .. i, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0, 128),
				Size = UDim2.fromOffset(disc[1], disc[1]),
				BackgroundTransparency = disc[2],
				BackgroundColor3 = Theme.Lighten(rarityColor, 0.3),
				ZIndex = 1,
			})
			round(glow)
		end

		stage.RevealViewport = CloudUI.PetViewport(c, def, UDim2.fromOffset(230, 230), {
			Position = UDim2.new(0.5, 0, 0, 128),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Spin = "spin",
			Excited = 1,
			Flap = 1.5,
			ZIndex = 3,
		})

		-- NEW! flag (or the stack size for a duplicate)
		local isNew = result.IsNew == true
		local flag = makeFrame(c, "Flag", {
			Position = UDim2.fromOffset(8, 12),
			Size = UDim2.fromOffset(88, 32),
			Rotation = -10,
			BackgroundTransparency = 0,
			BackgroundColor3 = isNew and GOLD or BUTTONS.Blue,
			ZIndex = 6,
		})
		corner(flag, 9)
		stroke(flag, NAVY, 3, 0)
		local flagText = "NEW!"
		if not isNew then
			flagText = "x" .. tostring(math.floor(tonumber(result.Count) or State.OwnedCount(def.Id)))
		end
		makeText(flag, "Text", flagText, "Accent", 20, WHITE, {
			Size = UDim2.new(1, 0, 1, 0),
			ZIndex = 7,
			TextStrokeTransparency = 0.1,
			TextStrokeColor3 = Theme.Darken(isNew and GOLD or BUTTONS.Blue, 0.65),
		})

		makeText(c, "Name", def.Name, "Title", 30, Theme.Lighten(rarityColor, 0.3), {
			Position = UDim2.fromOffset(0, 252),
			Size = UDim2.new(1, 0, 0, 38),
			ZIndex = 4,
			TextStrokeTransparency = 0.1,
		})
		local meta = makeFrame(c, "Meta", { Position = UDim2.fromOffset(0, 294), Size = UDim2.new(1, 0, 0, 26), ZIndex = 4 })
		listLayout(meta, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		local pill = CloudUI.Pill(def.Rarity, def.Rarity, meta)
		pill.LayoutOrder = 1
		makeText(meta, "Owned", "You own x" .. tostring(math.floor(tonumber(result.Count) or State.OwnedCount(def.Id))), "Heading", 14, MUTED, {
			Size = UDim2.fromOffset(120, 24),
			LayoutOrder = 2,
			ZIndex = 4,
		})
		local lines = perkLines(def)
		local perkText = "No perks"
		if #lines > 0 then
			perkText = table.concat(lines, "\n")
		end
		makeText(c, "Perks", perkText, "Heading", 15, Theme.Lighten(GOOD, 0.2), {
			Position = UDim2.fromOffset(14, 326),
			Size = UDim2.new(1, -28, 0, 44),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = 4,
		})

		local buttons = makeFrame(c, "Buttons", {
			Position = UDim2.fromOffset(0, 378),
			Size = UDim2.new(1, 0, 0, 48),
			ZIndex = 4,
		})
		listLayout(buttons, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		stage.EquipBtn = CloudUI.Button({
			Name = "Equip",
			Text = "Equip",
			Style = "Green",
			Size = UDim2.fromOffset(150, 46),
			TextSize = 22,
			LayoutOrder = 1,
			Callback = function()
				fire("EquipPet", def.Id)
			end,
			Parent = buttons,
		})
		if roulette then
			stage.AgainBtn = CloudUI.Button({
				Name = "Again",
				Text = "Again",
				Style = "Gold",
				Size = UDim2.fromOffset(170, 46),
				TextSize = 20,
				LayoutOrder = 2,
				Callback = function()
					local rouletteId = roulette.Id
					closeStage()
					task.defer(requestSpin, rouletteId)
				end,
				Parent = buttons,
			})
		end
		updateReveal()

		-- confetti: more for rarer pets
		local amounts = { 8, 12, 18, 26, 34, 44 }
		local amount = amounts[Util.Clamp(order, 1, #amounts)]
		task.delay(0.2, function()
			if Spin.Stage == stage and stage.Phase == "reveal" then
				burst(c, rarityColor, amount, UDim2.new(0.5, 0, 0, 128))
			end
		end)
		if order >= 5 then
			task.delay(0.65, function()
				if Spin.Stage == stage and stage.Phase == "reveal" then
					burst(c, rarityColor, amount, UDim2.new(0.5, 0, 0, 128))
				end
			end)
		end
	end

	------------------------------------------------------------------
	-- animation loop
	------------------------------------------------------------------
	local function land()
		stage.Phase = "land"
		stage.LandedAt = os.clock()
		local winner = cells[target]
		if winner then
			winner.Stroke.Color = GOLD
			winner.Stroke.Thickness = 5
			winner.Frame.ZIndex = 4
			local grow = Util.Create("UIScale", { Scale = 1, Parent = winner.Frame })
			tween(grow, 0.35, { Scale = 1.1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			winner.Viewport.SetAnimated(true)
			winner.Viewport.SetExcited(1)
		end
		status.Text = def.Rarity .. "!"
		status.TextColor3 = Theme.Lighten(rarityColor, 0.35)
		band.BackgroundTransparency = 0.7
		pointer.Rotation = 0
	end

	local function step(dt)
		if stage.Phase == "spin" then
			if stage.Skip then
				stage.Elapsed = STRIP.Seconds
			end
			stage.Elapsed = stage.Elapsed + dt
			local t = Util.Clamp(stage.Elapsed / STRIP.Seconds, 0, 1)
			local p = 1 - (1 - t) ^ STRIP.Curve
			stage.X = startX + (endX - startX) * p
			layoutCells(stage.X)
			local tick = math.floor((stage.X + STRIP.W / 2) / cellW)
			if tick ~= stage.Tick then
				stage.Tick = tick
				pointer.Rotation = 16
			end
			pointer.Rotation = pointer.Rotation * math.max(0, 1 - dt * 11)
			if t >= 1 then
				land()
			end
		elseif stage.Phase == "land" then
			if stage.Skip or os.clock() - stage.LandedAt > 0.95 then
				showReveal()
			end
		elseif stage.Phase == "reveal" then
			if stage.Rays then
				stage.Rays.Rotation = (stage.Rays.Rotation + dt * 22) % 360
			end
		end
	end

	stage.Conn = RunService.RenderStepped:Connect(function(dt)
		if Spin.Stage ~= stage then
			return
		end
		local ok, err = pcall(step, dt)
		if not ok then
			warnOnce("stage", err)
			if stage.Phase == "reveal" or stage.Failed then
				closeStage()
			else
				stage.Failed = true
				if not pcall(showReveal) then
					closeStage()
				end
			end
		end
	end)
end

local function onRouletteResult(result)
	Spin.Waiting = false
	Spin.WaitToken = Spin.WaitToken + 1
	if type(result) ~= "table" then
		refreshShopWindow()
		return
	end
	if result.Ok == false or type(result.PetId) ~= "string" then
		local reason = "The spin failed."
		if type(result.Reason) == "string" and result.Reason ~= "" then
			reason = result.Reason
		end
		showHint(reason, "bad")
		refreshShopWindow()
		return
	end
	if Spin.Stage then
		table.insert(Spin.Queue, result)
	else
		beginStage(result)
	end
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
-- OpenPanel(panelId, args): the server opens windows (roulette / item shop prompts).
local function onOpenPanel(panelId, args)
	if type(panelId) ~= "string" then
		return
	end
	args = type(args) == "table" and args or {}
	local key = panelId:lower()
	if key == "shop" then
		if inMatch() then
			return
		end
		openWindow("Shop", args)
	elseif key == "inventory" or key == "items" then
		openWindow("Inventory", args)
	elseif key == "pets" then
		openWindow("Inventory", { Tab = "Pets" })
	elseif key == "stats" then
		openWindow("Stats", args)
	elseif key == "close" then
		closeEverything()
	end
end

local function onStateChanged()
	-- red dot on the Pets button when the collection grew while the inventory was closed
	local _, total = petTotals()
	local inventory = windows.Inventory
	if Badge.LastPetTotal ~= nil and total > Badge.LastPetTotal and not (inventory and inventory.Shown) then
		if Entries.Pets then
			Entries.Pets.Icon.SetBadge(true)
		end
	end
	Badge.LastPetTotal = total

	for _, win in pairs(windows) do
		refreshWindow(win)
	end
	if Spin.Stage and Spin.Stage.UpdateReveal then
		safe("reveal", Spin.Stage.UpdateReveal)
	end
end

local function onTokensChanged()
	refreshOpenWindow()
	if Spin.Stage and Spin.Stage.UpdateReveal then
		safe("reveal", Spin.Stage.UpdateReveal)
	end
end

local function onMatchFlagChanged()
	if inMatch() then
		closeEverything()
	end
	updateMenuActive()
	refreshOpenWindow()
end

-- Escape only: gamepad B goes through the "NimbusMenuBack" action (syncBackBinding), because it must not
-- also reach MovementController's dash.
local function onInput(input)
	if input.KeyCode == Enum.KeyCode.Escape then
		handleBack()
	end
end

local function connectRemotes()
	local okOpen, openRemote = pcall(Remotes.Get, "OpenPanel")
	if okOpen and openRemote then
		openRemote.OnClientEvent:Connect(function(panelId, args)
			safe("OpenPanel", onOpenPanel, panelId, args)
		end)
	else
		warn("[MenuController] OpenPanel remote is unavailable: " .. tostring(openRemote))
	end
	local okSpin, spinRemote = pcall(Remotes.Get, "RouletteResult")
	if okSpin and spinRemote then
		spinRemote.OnClientEvent:Connect(function(result)
			safe("RouletteResult", onRouletteResult, result)
		end)
	else
		warn("[MenuController] RouletteResult remote is unavailable: " .. tostring(spinRemote))
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function MenuController.Open(panelId, args)
	if initialized then
		onOpenPanel(panelId, args)
	end
end

function MenuController.Close()
	if initialized then
		closeEverything()
	end
end

function MenuController.Init()
	if initialized then
		return
	end
	initialized = true
	LocalPlayer = Players.LocalPlayer
	touchDevice = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	pcall(State.Init)

	gui = CloudUI.NewScreenGui("NimbusMenu", 20)

	-- click-outside layer behind the windows
	U.Backdrop = Util.Create("TextButton", {
		Name = "Backdrop",
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		BackgroundColor3 = Color3.fromRGB(8, 12, 32),
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		Visible = false,
		ZIndex = 1,
		Parent = gui,
	})
	U.Backdrop.Activated:Connect(function()
		if openId then
			closeWindow(openId)
		end
	end)

	buildHint()
	buildColumn()
	createWindow({ Id = "Inventory", Title = "Inventory", Accent = BUTTONS.Blue, Build = buildInventory })
	createWindow({ Id = "Shop", Title = "Cloud Shop", Accent = BUTTONS.Gold, Build = buildShop })
	createWindow({ Id = "Stats", Title = "Stats", Accent = PURPLE, Build = buildStats })
	relayoutMenu()
	updateMenuActive()

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayoutMenu)
	State.Changed:Connect(function()
		safe("State.Changed", onStateChanged)
	end)
	LocalPlayer:GetAttributeChangedSignal(Config.Attr.Tokens):Connect(function()
		safe("Tokens", onTokensChanged)
	end)
	LocalPlayer:GetAttributeChangedSignal(Config.Attr.InMatch):Connect(function()
		safe("InMatch", onMatchFlagChanged)
	end)
	UserInputService.InputBegan:Connect(function(input)
		safe("input", onInput, input)
	end)

	-- remember the collection size so only later growth shows the "new pet" dot
	local _, total = petTotals()
	if State.IsLoaded and State.IsLoaded() then
		Badge.LastPetTotal = total
	end

	task.spawn(connectRemotes)
end

return MenuController
