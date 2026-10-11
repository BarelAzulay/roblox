-- MenuController (client, v3 + Phase 2): the left menu of icon tiles and every window the player opens.
--
--   MenuController.Init()
--   MenuController.Open(panelId, args)   -- "Inventory" | "Pets" | "Index" | "Shop" | "Stats" | "Home" (what OpenPanel
--                                           does; args: Tab, RouletteId, Currency = "Gems", Action = "Feed", Key)
--   MenuController.Close()               -- closes whatever window / overlay is open
--   MenuController.WindowOpened          -- Util.Signal, Fire(windowId) whenever a window opens:
--                                           "Inventory", "Shop", "Stats", "Home" or "Index" (the tutorial listens)
--   Extra: MenuController.GetButton(id) -> the MenuButton_<id> tile (or nil; "Home" is the Spot tile)
--          MenuController.IsOpen() -> true while a window, the odds popup or the roulette stage is up
--          MenuController.IsPrewarmed(petId) -> true once that pet was pre-sculpted for the roulette strip
--          MenuController.OpenFeed(key) -> opens Pets with the Feed picker of that pet copy
--
-- Screen: ScreenGui "NimbusMenu" (display order 20, IgnoreGuiInset = false).
--   * Menu column, left-centre (the reference style): square-ish rounded icon tiles with a big glyph and a
--     bold label under each - Inventory, Pets, Index, Shop, Home and Stats. Each tile is a TextButton named
--     MenuButton_<Id> (Ids Inventory, Pets, Index, Shop, Spot, Stats: the Home tile keeps the v3 id "Spot" so saved
--     tutorial targets keep working) inside a frame Entry_<Id> of the frame "MenuColumn". The open window's tile
--     glows gold; a red "!" marks new pets and Pet Index rewards waiting to be claimed. On short screens (landscape
--     phones) the column becomes a 2 x 3 grid so it keeps a readable scale.
--   * Windows (CloudUI.Panel, centred because the player asked for them, nudged right only when the menu
--     column would cover them): Inventory (tabs Pets + Items, pet detail card with Equip / Unequip, Feed and
--     Place in Garden / Train in Gym), Shop (tabs Roulettes + Items + Gems, odds popup), Stats and Home. The Pet
--     Index is IndexController's window: the Index tile and OpenPanel("Index") open it. One window at a time;
--     Esc / gamepad B / the red X / the tile again / a click outside closes it. Gamepad B is bound
--     (ContextActionService, High priority, sunk) only while something is open, so it does not also fire
--     MovementController's dash.
--   * Phase 2 (ARCHITECTURE_V3.md "Phase 2 build contract", UI):
--       Home tile: with a claimed home it opens the Home window; without one it walks the player to a free gate
--       (Remotes.GoToSpot: the last plot when free, else the nearest) with a side hint "press E at the gate".
--       Home window: the house tier, Home Level and prestige stars, income per second (presses + Garden pets, the
--       prestige multiplier), the Collector's cash / cap with Collect, the prestige progress (Home Level x/40 and
--       the Sky Castle) with a confirmed Prestige button, Go home, and every station of TycoonCatalog with its
--       level (pips), what it does now -> next, the next price and Build / Upgrade (or why it is locked: "Reach
--       Home Level 10", "Needs the Villa", "Needs Cloud Press 2 Lv 2", "Unlocks at Prestige 1", "Coming soon").
--       The live numbers come from the plot folder's attributes (CollectorCash, CollectorCap, IncomePerSecond)
--       and the Cash attribute; everything is re-checked by the server (HomeAction "Upgrade" / "Collect" /
--       "Prestige" / "GoHome").
--       Pets panel: one slot per pet COPY key (shared/PetKeys: Normal, Golden, Rainbow, fused hybrids) with tier /
--       hybrid badges; the detail card shows the level and an XP bar, the stats scaled by rarity, level and tier
--       (PetCatalog.StatsOf), the perks x the tier bonus, where the pet works, and the buttons Feed (a food picker:
--       Snack / Meal / Feast with their XP and counts, Cook shortcuts and the Kitchen queue -> PetCare "Feed" /
--       "Cook"), Place in Garden (Economy pets -> HomeAction "GardenSet") and Train in Gym (Combat pets ->
--       PetCare "GymSet").
--       Shop Gems tab: the Gem packs (developer products with an id: MarketplaceService:PromptProductPurchase; the
--       server grants them in ProcessReceipt), the gems-only Secret Roulette and every roulette with a gem price,
--       each with its odds popup (always shown); hidden with a note while the PaidRandomItemsRestricted attribute
--       is true. A gem spin sends BuyRoulette(id, "Gems").
--   * Roulette stage: a scrolling strip of pet viewports that eases to the server result (RouletteResult),
--     then a reveal card with a rarity glow, a NEW! flag and an Equip button (a landscape card on short screens).
--   * v3 readability rule: everything is designed in 1080p pixels (body 18-19, captions >= 18, buttons 20+,
--     titles 28-34) under ONE UIScale per window = min(screen factor clamp(viewportY / 1080, 0.8, 1.25), fit).
--     Window sizes adapt between a minimum and a preferred design size and their columns scroll, so phones
--     keep the 0.8 scale instead of shrinking the text.
--   * Every window re-renders from State.Changed (and when the token count or the InMatch attribute
--     changes). Pet slots are kept per pet id and updated in place, so nothing is rebuilt or leaked; the
--     pet viewports of the Inventory grid, the odds popup and the roulette strip are attached under a per-frame
--     TIME budget (K.BUILD_BUDGET, at least one per frame), so neither a big collection nor a fresh client's
--     first-time pet sculpts hitch. The strip cells and odds tiles use PetBuilder's Low detail (the reveal card
--     stays High), and the roulette pools are sculpted ahead of time (one pet per frame) when the Shop opens and
--     when a spin is requested, so the spin itself only clones.
--   * Touch screens: the menu column never reaches Roblox's thumbstick (bottom-left); in landscape it sits in the
--     band between the top margin and the stick (2 x 3 grid with the labels on the tiles, or icon-only tiles
--     when labels would drop below 14 px).
--
-- Remotes used: OpenPanel, RouletteResult (in); BuyRoulette, EquipPet, UnequipPet, BuyItem, GoToSpot, HomeAction,
-- PetCare (out). Each remote action is sent at most every K.FIRE_GAP seconds (the server rate-limits as well).
-- Plain Lua 5.1-compatible syntax only. All text goes through Theme roles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local MarketplaceService = game:GetService("MarketplaceService")

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

-- Phase 2 modules (written by other engineers at the same time): optional, every use is guarded.
local function optionalShared(name)
	local module = Shared:FindFirstChild(name)
	if not module then
		local ok, found = pcall(function()
			return Shared:WaitForChild(name, 3)
		end)
		module = ok and found or nil
	end
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[MenuController] " .. name .. " is unavailable: " .. tostring(result))
	return nil
end

local PetKeys = optionalShared("PetKeys")
local TycoonCatalog = optionalShared("TycoonCatalog")

local MenuController = {}
MenuController.WindowOpened = Util.Signal()

----------------------------------------------------------------------
-- Tunables (design pixels of a 1080p screen unless noted)
----------------------------------------------------------------------
local K = {
	EDGE = 12, -- screen px between the column and the left edge
	TOUCH_EDGE = 20,
	TILE = 84, -- a menu tile (square)
	ENTRY_W = 100, -- tile + room for its label
	ENTRY_H = 98,
	GAP = 6, -- between two entries
	LABEL_TEXT = 19,
	MARGIN = 12, -- screen px kept free around a window
	BUMPS = 28, -- room the panels' cloud bumps need above the top edge
	NARROW = 1100, -- windows narrower than this (design px) use narrower side cards
	SHORT = 560, -- windows lower than this (design px) use their compact layout
	DETAIL_W = 340,
	DETAIL_W_NARROW = 296,
	FIRE_GAP = 0.3, -- client-side spacing between two sends of the same remote
	HINT_SECONDS = 2.8,
	WAIT_TIMEOUT = 7, -- seconds to wait for a RouletteResult
	-- pet viewports (Inventory grid, odds popup, roulette strip) are built under a TIME budget per frame: the first
	-- build of a frame always runs, more only while the frame has spent < BUILD_BUDGET s building, at most BUILD_MAX
	-- (a first-time High sculpt costs tens of ms, a cached clone a few: a count budget hitches on fresh clients)
	BUILD_BUDGET = 0.004,
	BUILD_MAX = 3,
	STRIP_DETAIL = "Low", -- roulette strip cells: small, static, moving fast (the reveal card keeps High)
	ODDS_DETAIL = "Low", -- 88 px odds tiles
	-- Roblox's touch thumbstick (bottom-left), gui px above the bottom edge: classic 70 px stick at 20 px on small
	-- screens (the dynamic stick's idle ring reaches ~93) and 120 px at 0.75 * 120 on large ones
	STICK_TOP_SMALL = 96,
	STICK_TOP_LARGE = 210,
	STICK_GAP = 8,
	MIN_LABEL_PX = 14, -- smallest on-screen menu label on phones / tablets (readability rule)
	GRID_ENTRY_H = 86, -- "Grid" layout: the label sits on the tile's bottom edge, so a row is shorter ...
	GRID_LABEL_Y = -8, -- ... (label centre this far above the tile's bottom; "Column": 2 px below it)
	BACK_ACTION = "NimbusMenuBack", -- ContextActionService action that owns gamepad B while something is closable
	CARD_H = 474, -- roulette card
	CARD_H_SHORT = 216,
	ITEM_CARD_H = 440,
	ITEM_CARD_H_SHORT = 214,
	SHOP_COMPACT = 650, -- Shop windows lower than this (design px) use the compact cards
}

-- Preferred / minimum design sizes of each window (W x H), the reveal card, the spin stage and its strip.
K.WIN = {
	Inventory = { 1180, 740, 800, 380 },
	Shop = { 1180, 740, 800, 380 },
	Stats = { 1080, 700, 800, 380 },
	Home = { 1180, 740, 800, 380 },
	Odds = { 780, 680, 600, 380 },
}
-- Portrait screens (a phone held upright): a window may get as narrow as TALL_MIN_W design px (and as tall as
-- TALL_MAX_H) so its text keeps the readability scale instead of shrinking to fit 800 px; windows narrower than
-- TALL switch to their single-column ("tall") layout.
K.TALL_MIN_W = 420
K.TALL_MAX_H = 1100
K.TALL = 760
-- Phase 2 (Home window, Pets actions, Gems tab)
K.HOME_LEFT_W = 350 -- the Home window's summary column
K.HOME_LEFT_W_NARROW = 300
K.STATION_ROW_H = 96
K.STATION_ROW_H_TALL = 132
K.LIVE_GAP = 0.25 -- seconds between two live refreshes of the Home window (collector / income tick every second)
K.GEM_PACK_H = 248
K.GEM_ROW_H = 120
K.FEED_W = 600
K.FEED_H = 470
K.RESTRICTED_ATTR = "PaidRandomItemsRestricted" -- GemService: true while gem roulettes are not allowed / unknown
K.KITCHEN_QUEUE_ATTR = "KitchenQueue" -- PetCareService: "Snack,Meal" (cooking first), "" when idle
K.KITCHEN_READY_ATTR = "KitchenReadyAt" -- workspace:GetServerTimeNow() when the current dish is done
K.REVEAL = { TallW = 480, TallH = 640, WideW = 790, WideH = 372 }
K.STAGE = { W = 920, H = 380 }
K.STRIP = { Cell = 150, W = 860, H = 190, Target = 34, MinCells = 42, Seconds = 5.6, Curve = 2.8 }

local Colors = Theme.Colors
local WHITE = Colors.White
local NAVY = Colors.Navy or Colors.Ink
local MUTED = Colors.Muted or Colors.CloudShade
local GOLD = Colors.Gold or Colors.Token
local INK = Colors.TextStroke or Colors.Ink
local GOOD = Colors.Good
local BAD = Colors.Bad
local WELL_EDGE = Colors.WellEdge or NAVY
local BUTTONS = Theme.Buttons or {}
local KINDS = Theme.Kinds or {}
local PURPLE = Color3.fromRGB(150, 122, 226)
local TEAL = Color3.fromRGB(70, 182, 196)
local INSET_COLOR = Color3.fromRGB(20, 30, 70)
local ROLE_COLORS = { Economy = Color3.fromRGB(96, 196, 108), Combat = Color3.fromRGB(228, 104, 96) }
local CURRENCY = Theme.Currency or {}
-- Phase 2 colours (one table: the main chunk stays under Lua's 200-local limit)
local C2 = {
	Cash = Colors.Cash or Color3.fromRGB(112, 204, 98),
	Gem = Colors.Gem or Color3.fromRGB(84, 196, 246),
	Tier = { Golden = Color3.fromRGB(246, 196, 64), Rainbow = Color3.fromRGB(226, 110, 214) },
	Hybrid = Color3.fromRGB(150, 110, 232),
	Xp = Color3.fromRGB(120, 200, 255),
	Lock = Color3.fromRGB(255, 206, 120), -- amber: why something is locked (reads on the dark wells)
	Secret = Color3.fromRGB(70, 90, 200),
	Kind = {
		Press = Color3.fromRGB(110, 170, 236),
		Collector = Color3.fromRGB(96, 196, 108),
		Garden = Color3.fromRGB(120, 196, 90),
		Kitchen = Color3.fromRGB(240, 150, 80),
		Gym = Color3.fromRGB(228, 104, 96),
		Vault = Color3.fromRGB(150, 160, 190),
		House = Color3.fromRGB(240, 186, 90),
		Fusion = Color3.fromRGB(150, 110, 232),
		Arena = Color3.fromRGB(200, 120, 90),
		Decor = Color3.fromRGB(226, 120, 170),
		Prestige = Color3.fromRGB(244, 196, 78),
	},
}

-- Glyphs as UTF-8 byte escapes (the source stays plain ASCII).
local G = {
	Backpack = "\240\159\142\146",
	Paw = "\240\159\144\190",
	Book = "\240\159\147\150",
	Money = "\240\159\146\176",
	House = "\240\159\143\160",
	Chart = "\240\159\147\138",
	Lock = "\240\159\148\146",
	Star = "\226\152\133",
	StarOutline = "\226\152\134",
	Cloud = "\226\152\129",
	Down = "\226\150\188",
	Dash = "\226\128\148",
	Sparkle = "\226\156\166",
	Gem = (CURRENCY.Gems and CURRENCY.Gems.Glyph) or "\226\151\134", -- black diamond
	Cash = (CURRENCY.Cash and CURRENCY.Cash.Glyph) or "$",
	Bullet = "\194\183", -- middle dot
	Check = "\226\156\147",
	Snack = "\240\159\141\170", -- cookie
	Meal = "\240\159\141\178", -- pot of food
	Feast = "\240\159\165\167", -- pie
	Food = "\240\159\141\150", -- meat on bone
	Seedling = "\240\159\140\177",
	Muscle = "\240\159\146\170",
	Hybrid = "\226\156\168", -- sparkles
	Storm = "\226\154\161", -- high voltage
	Robux = "R$",
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
local Net = { Warned = {}, Cache = {}, Last = {} } -- warnOnce keys, remote cache, last send per remote
local touchDevice = false

local Spin = { Waiting = false, WaitToken = 0, Queue = {}, Stage = nil, Last = nil }
-- per-frame build budget + roulette pool pre-sculpting (functions defined with the helpers below)
local Warm = { Queue = {}, Seen = {}, Done = {}, Running = false, Module = nil, Tried = false }
local Odds = { Gui = nil, Token = 0, Slots = {}, Holder = nil, Fit = nil }
local Badge = { LastPetTotal = nil }
local Back = { Bound = false, Busy = false, Swallowed = false } -- gamepad B binding state (see syncBackBinding)
local Index = { Module = nil, Tried = false } -- IndexController (loaded lazily, optional)
local Entries = {} -- id -> menu tile widgets
local Hint = { Frame = nil, Label = nil, Token = 0 }
-- Phase 2: the Home window's live plot watch, the Feed picker, the shop's Gems tab
local Home = { Folder = nil, Conns = {}, LiveAt = 0, LivePending = false }
local Feed = { Gui = nil, Key = nil, Token = 0 }
local Gems = { Prices = {}, PriceAsked = {} }

-- forward declarations
local openWindow, closeWindow, toggleWindow, refreshOpenWindow, updateMenuActive
local requestSpin, closeStage, skipSpin, closeOdds, openOdds, showHint, handleBack, beginStage
local syncBackBinding, closeIndex, relayoutMenu, closeFeed, openFeed, refreshHomeLive

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function warnOnce(key, err)
	if not Net.Warned[key] then
		Net.Warned[key] = true
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

-- Per-frame build budget for pet viewports: the first build of a frame always runs, the next ones only while the
-- frame has spent less than K.BUILD_BUDGET seconds and at most K.BUILD_MAX builds. Callers add 1 to Count per build.
function Warm.Budget()
	return { Start = os.clock(), Count = 0 }
end

function Warm.Allows(budget)
	return budget.Count < K.BUILD_MAX and (budget.Count == 0 or os.clock() - budget.Start < K.BUILD_BUDGET)
end

-- shared/PetBuilder, loaded lazily (the pre-sculpting below is optional: nil when it cannot load)
function Warm.Builder()
	if not Warm.Tried then
		Warm.Tried = true
		local ok, result = pcall(function()
			return require(Shared:WaitForChild("PetBuilder", 5))
		end)
		if ok and type(result) == "table" then
			Warm.Module = result
		end
	end
	return Warm.Module
end

-- Pre-sculpts pets at the strip's detail, a few per frame (time budget), so a roulette spin only clones cached
-- templates instead of sculpting on the frame a cell scrolls into view. `front` puts them first in the queue.
-- Paused while the roulette stage runs (its cells attach under their own budget).
function Warm.Pets(defs, front)
	if type(defs) ~= "table" or not Warm.Builder() then
		return
	end
	local fresh = {}
	for _, def in ipairs(defs) do
		local id = type(def) == "table" and def.Id or nil
		if type(id) == "string" and not Warm.Seen[id] then
			Warm.Seen[id] = true
			fresh[#fresh + 1] = def
		end
	end
	for i, def in ipairs(fresh) do
		if front then
			table.insert(Warm.Queue, i, def)
		else
			Warm.Queue[#Warm.Queue + 1] = def
		end
	end
	if Warm.Running or #Warm.Queue == 0 then
		return
	end
	Warm.Running = true
	task.spawn(function()
		task.wait() -- never in the frame that opens the Shop (it builds the window)
		while #Warm.Queue > 0 do
			if Spin.Stage then
				task.wait(0.25)
			else
				local budget = Warm.Budget()
				while #Warm.Queue > 0 and Warm.Allows(budget) do
					local def = table.remove(Warm.Queue, 1)
					local ok, model = pcall(Warm.Module.Build, def, { Detail = K.STRIP_DETAIL, Scale = 1 })
					if ok and typeof(model) == "Instance" then
						model:Destroy()
						Warm.Done[def.Id] = true
					end
					budget.Count = budget.Count + 1
				end
				task.wait()
			end
		end
		Warm.Running = false
	end)
end

-- the possible pets of one roulette (pre-sculpted when the Shop opens and when that roulette is requested)
function Warm.Roulette(rouletteId, front)
	if type(rouletteId) ~= "string" then
		return
	end
	if Warm.PossiblePets then
		-- (possiblePetsOf, set below: it also knows the gems-only Secret roulette)
		local ok, defs = pcall(Warm.PossiblePets, rouletteId)
		if ok then
			Warm.Pets(defs, front)
		end
		return
	end
	if type(PetCatalog.PossiblePets) ~= "function" then
		return
	end
	local ok, defs = pcall(PetCatalog.PossiblePets, rouletteId)
	if ok then
		Warm.Pets(defs, front)
	end
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

-- Theme-styled TextLabel (stroke + glyph outline, readable on any panel) with optional property overrides.
local function makeText(parent, name, text, role, size, color, props)
	local p = { Name = name }
	if props then
		for key, value in pairs(props) do
			p[key] = value
		end
	end
	local label = Theme.Label(tostring(text), role, {
		Size = size,
		Color = color or WHITE,
		Stroke = 0.25,
		StrokeColor = INK,
		Outline = 1.5,
		OutlineColor = INK,
		Props = p,
	})
	local faded = tonumber(p.TextTransparency)
	if faded and faded > 0 then
		local outline = label:FindFirstChild("TextOutline")
		if outline then
			outline.Transparency = math.min(1, faded + 0.2)
		end
	end
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

-- Vertical ScrollingFrame with an automatic canvas.
local function scroller(parent, name, props)
	local p = props or {}
	p.Name = name
	p.BackgroundTransparency = 1
	p.BorderSizePixel = 0
	p.CanvasSize = UDim2.new(0, 0, 0, 0)
	p.AutomaticCanvasSize = Enum.AutomaticSize.Y
	p.ScrollingDirection = Enum.ScrollingDirection.Y
	p.ScrollBarThickness = 10
	p.ScrollBarImageColor3 = Colors.FrameTop or Colors.Cloud
	p.ScrollBarImageTransparency = 0.1
	p.Parent = parent
	return Util.Create("ScrollingFrame", p)
end

local function tween(inst, seconds, goal, style, direction)
	return Util.Tween(inst, seconds, goal, style, direction)
end

-- The dark inset card used inside the windows.
local function makeInset(parent, name, props)
	local p = props or {}
	p.BackgroundColor3 = INSET_COLOR
	p.BackgroundTransparency = 0.42
	local inset = makeFrame(parent, name, p)
	corner(inset, 12)
	stroke(inset, WELL_EDGE, 3, 0.15)
	return inset
end

local function rarityOf(def)
	return CloudUI.RarityColor(def and def.Rarity)
end

-- A rarity colour that still reads on dark panels (the Secret rarity is near-black).
local function rarityText(def)
	if def and def.Rarity == "Secret" then
		return Color3.fromRGB(196, 168, 255)
	end
	return Theme.Lighten(rarityOf(def), 0.3)
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

-- Config.Gems.SecretRoulette (the gems-only roulette at the Storm Altar) or nil
local function secretRoulette()
	local gems = Config.Gems
	local s = type(gems) == "table" and gems.SecretRoulette or nil
	if type(s) == "table" and type(s.Id) == "string" and s.Id ~= "" then
		return s
	end
	return nil
end

-- A token roulette (Config.Roulettes) or the gems-only Secret roulette (GemsOnly = true, no token Price).
local function findRoulette(id)
	for _, r in ipairs(Config.Roulettes) do
		if r.Id == id then
			return r
		end
	end
	local s = secretRoulette()
	if s and s.Id == id then
		return {
			Id = s.Id,
			DisplayName = s.DisplayName or s.Id,
			Color = s.Color or Color3.fromRGB(70, 90, 200),
			Odds = type(s.Odds) == "table" and s.Odds or {},
			GemPrice = s.GemPrice,
			AllowSecret = s.AllowSecret == true,
			GemsOnly = true,
		}
	end
	return nil
end

-- the gem price of a roulette (Config.Gems.RouletteGemPrices, the Secret roulette's GemPrice) or nil
local function gemPriceOf(rouletteId)
	local gems = Config.Gems
	local prices = type(gems) == "table" and gems.RouletteGemPrices or nil
	local price = type(prices) == "table" and tonumber(prices[rouletteId]) or nil
	if not price then
		local s = secretRoulette()
		if s and s.Id == rouletteId then
			price = tonumber(s.GemPrice)
		end
	end
	if price and price >= 1 then
		return math.floor(price)
	end
	return nil
end

-- The rarity buckets of a gems-only roulette, the way GemService rolls them (rarity order, weight > 0, rarities
-- without pets skipped, Secret only with AllowSecret): { {Rarity, Weight, Pets} }, total weight.
local function gemsOnlyBuckets(roulette)
	local out, total = {}, 0
	if type(roulette) ~= "table" or type(roulette.Odds) ~= "table" or type(PetCatalog.ListByRarity) ~= "function" then
		return out, 0
	end
	local rarities = {}
	for _, r in ipairs(Config.Rarities) do
		rarities[#rarities + 1] = r
	end
	table.sort(rarities, function(a, b)
		return (a.Order or 0) < (b.Order or 0)
	end)
	for _, r in ipairs(rarities) do
		local w = tonumber(roulette.Odds[r.Id])
		if w and w > 0 and (r.Id ~= "Secret" or roulette.AllowSecret == true) then
			local ok, pets = pcall(PetCatalog.ListByRarity, r.Id)
			if ok and type(pets) == "table" and #pets > 0 then
				out[#out + 1] = { Rarity = r.Id, Weight = w, Pets = pets }
				total = total + w
			end
		end
	end
	return out, total
end

-- the pets a roulette can give (PetDefs)
local function possiblePetsOf(rouletteId)
	local roulette = findRoulette(rouletteId)
	if roulette and roulette.GemsOnly then
		local out = {}
		for _, bucket in ipairs((gemsOnlyBuckets(roulette))) do
			for _, def in ipairs(bucket.Pets) do
				out[#out + 1] = def
			end
		end
		return out
	end
	if type(PetCatalog.PossiblePets) == "function" then
		local ok, defs = pcall(PetCatalog.PossiblePets, rouletteId)
		if ok and type(defs) == "table" then
			return defs
		end
	end
	return {}
end

-- { {PetId, Rarity, Chance} } of a roulette (PetCatalog.GetOdds; the gems-only one mirrors GemService.GetOdds)
local function oddsOf(rouletteId)
	local roulette = findRoulette(rouletteId)
	if roulette and roulette.GemsOnly then
		local out = {}
		local buckets, total = gemsOnlyBuckets(roulette)
		if total > 0 then
			for _, bucket in ipairs(buckets) do
				local each = (bucket.Weight / total) / #bucket.Pets
				for _, def in ipairs(bucket.Pets) do
					out[#out + 1] = { PetId = def.Id, Rarity = bucket.Rarity, Chance = each }
				end
			end
		end
		return out
	end
	local ok, list = pcall(PetCatalog.GetOdds, rouletteId)
	if ok and type(list) == "table" then
		return list
	end
	return {}
end

Warm.PossiblePets = possiblePetsOf

-- "Open" (gem roulettes allowed), "Restricted" (PolicyService said no, or still checking) or "Unavailable" (no
-- gem system on this server: GemService never set the attribute)
local function gemRoulettesState()
	local value = LocalPlayer and LocalPlayer:GetAttribute(K.RESTRICTED_ATTR)
	if value == false then
		return "Open"
	elseif value == true then
		return "Restricted"
	end
	return "Unavailable"
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

-- Owned pet ids, rarest first (the catalog is sorted common -> secret).
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

-- Catalog pets discovered (v3: every pet ever owned or rolled; owned pets always count).
local function discoveredCount()
	local n = 0
	for _, def in ipairs(PetCatalog.Pets or {}) do
		local found
		if type(State.IsDiscovered) == "function" then
			found = State.IsDiscovered(def.Id)
		else
			found = State.OwnedCount(def.Id) > 0
		end
		if found then
			n = n + 1
		end
	end
	return n
end

local function catalogTotal()
	if type(PetCatalog.TotalCount) == "function" then
		local ok, n = pcall(PetCatalog.TotalCount)
		if ok and type(n) == "number" then
			return n
		end
	end
	return #(PetCatalog.Pets or {})
end

-- Element ids of a pet (v3 section 11), filtered by Config.Elements; empty while the catalog has none.
local function elementsOf(def)
	local info = Config.Elements and Config.Elements.Info
	if type(def) ~= "table" or type(info) ~= "table" then
		return {}
	end
	local raw = nil
	if type(PetCatalog.ElementsOf) == "function" then
		local ok, result = pcall(PetCatalog.ElementsOf, def)
		if ok then
			raw = result
		end
	end
	if raw == nil and type(PetCatalog.GetElements) == "function" then
		local ok, result = pcall(PetCatalog.GetElements, def.Id)
		if ok then
			raw = result
		end
	end
	if raw == nil then
		raw = def.Elements or def.Element
	end
	if type(raw) == "string" then
		raw = { raw }
	end
	local out, seen = {}, {}
	if type(raw) == "table" then
		for _, e in ipairs(raw) do
			if type(e) == "string" and info[e] and not seen[e] then
				seen[e] = true
				table.insert(out, e)
			end
		end
	end
	return out
end

-- CloudUI slots carry small count / key / marker texts (16-17 design px); at the phone scale (0.8) they
-- would render under 14 px, so the slots this menu makes get a size that stays readable.
local function readableSlot(slot)
	if not slot or not slot.Root then
		return slot
	end
	local count = slot.Root:FindFirstChild("Count", true)
	if count and count:IsA("TextLabel") and count.TextSize < 19 then
		count.TextSize = 19
		count.Size = UDim2.new(count.Size.X.Scale, count.Size.X.Offset, 0, 22)
	end
	for _, name in ipairs({ "Key", "Mark" }) do
		local label = slot.Root:FindFirstChild(name, true)
		if label and label:IsA("TextLabel") and label.TextSize < 18 then
			label.TextSize = 18
			local chip = label.Parent
			if chip and chip:IsA("GuiObject") and chip.Size.X.Offset < 28 then
				chip.Size = UDim2.fromOffset(28, 28)
			end
		end
	end
	return slot
end

-- CloudUI.Pill with a text size that stays >= 14 px at the phone scale (0.8).
local function readablePill(text, kind, parent)
	local pill = CloudUI.Pill(text, kind, parent)
	if pill then
		pill.TextSize = math.max(pill.TextSize, 18)
	end
	return pill
end

-- Coloured pill with the element name (no asset ids).
local function elementPill(parent, element, textSize, layoutOrder)
	local info = Config.Elements and Config.Elements.Info and Config.Elements.Info[element]
	local color = info and info.Color or Colors.PanelLight
	local dark = Theme.Darken(color, 0.62)
	local size = textSize or 17
	local pill = Theme.Label(element, "Heading", {
		Size = size,
		Color = WHITE,
		Stroke = 0.1,
		StrokeColor = dark,
		Outline = 1.5,
		OutlineColor = dark,
		Props = {
			Name = "Element_" .. element,
			BackgroundTransparency = 0,
			BackgroundColor3 = color,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, size + 9),
			LayoutOrder = layoutOrder or 0,
		},
	})
	round(pill)
	stroke(pill, NAVY, 2, 0)
	Theme.Gradient(pill, Color3.fromRGB(255, 255, 255), Color3.fromRGB(196, 204, 226), 90)
	pad(pill, 9, 0, 9, 1)
	pill.Parent = parent
	return pill
end

-- A solid coloured pill (tier / hybrid badges, "MAX", locks): white text with a dark outline of its own colour.
local function colorPill(parent, name, text, color, textSize, layoutOrder)
	local dark = Theme.Darken(color, 0.62)
	local size = textSize or 18
	local pill = Theme.Label(text, "Heading", {
		Size = size,
		Color = WHITE,
		Stroke = 0.1,
		StrokeColor = dark,
		Outline = 1.5,
		OutlineColor = dark,
		Props = {
			Name = name,
			BackgroundTransparency = 0,
			BackgroundColor3 = color,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, size + 9),
			LayoutOrder = layoutOrder or 0,
		},
	})
	round(pill)
	stroke(pill, NAVY, 2, 0)
	Theme.Gradient(pill, Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 206, 226), 90)
	pad(pill, 9, 0, 9, 1)
	pill.Parent = parent
	return pill
end

----------------------------------------------------------------------
-- Phase 2 data helpers: pet copy keys, levels, the home, Cash / Gems (fields of ONE local table, P2: the main chunk
-- is close to Lua's 200-local limit)
----------------------------------------------------------------------
local P2 = {}

P2.TIER_RANK = { Normal = 1, Golden = 2, Rainbow = 3 }

function P2.parseKey(key)
	if type(key) ~= "string" then
		return nil
	end
	if PetKeys and type(PetKeys.Parse) == "function" then
		local ok, parsed = pcall(PetKeys.Parse, key)
		if ok and type(parsed) == "table" then
			return parsed
		end
	end
	local base, tier = key:match("^(.-)@(%a+)$")
	base = base or key
	tier = tier or "Normal"
	if base:sub(1, 4) == "hyb:" then
		return { Key = key, HybridId = base:sub(5), Tier = tier }
	end
	return { Key = key, PetId = base, Tier = tier }
end

-- The definition of a pet copy: the catalog def (Normal), a tier def (Look.Finish), a merged hybrid def, or nil.
function P2.defOfKey(key)
	if type(key) ~= "string" then
		return nil
	end
	if type(State.DefOf) == "function" then
		local ok, def = pcall(State.DefOf, key)
		if ok and type(def) == "table" then
			return def
		end
	end
	return PetCatalog.Get(key)
end

function P2.tierOf(key, def)
	local t = type(def) == "table" and def.Tier or nil
	if t == "Golden" or t == "Rainbow" then
		return t
	end
	local parsed = P2.parseKey(key)
	if parsed and (parsed.Tier == "Golden" or parsed.Tier == "Rainbow") then
		return parsed.Tier
	end
	return "Normal"
end

function P2.isHybrid(key, def)
	if type(def) == "table" and def.IsHybrid == true then
		return true
	end
	return type(key) == "string" and key:sub(1, 4) == "hyb:"
end

-- x1 / x1.5 / x2.5 (perks and stats of tier copies; hybrids carry their own)
function P2.tierMultiplier(key, def)
	if type(def) == "table" and type(def.StatMultiplier) == "number" and def.StatMultiplier > 0 then
		return def.StatMultiplier
	end
	local tier = P2.tierOf(key, def)
	if tier == "Rainbow" then
		return 2.5
	elseif tier == "Golden" then
		return 1.5
	end
	return 1
end

function P2.displayName(key, def)
	def = def or P2.defOfKey(key)
	if type(def) ~= "table" then
		return tostring(key)
	end
	return tostring(def.DisplayName or def.Name or key)
end

-- Owned pet copies in grid order: rarest first; inside a rarity the hybrids, then the catalog pets (reverse catalog
-- order, a pet's Rainbow / Golden copies right before its Normal ones).
function P2.ownedKeys()
	local keys = nil
	if type(State.Keys) == "function" then
		local ok, list = pcall(State.Keys)
		if ok and type(list) == "table" then
			keys = list
		end
	end
	if not keys then
		keys = {}
		for _, def in ipairs(PetCatalog.Pets or {}) do
			keys[#keys + 1] = def.Id
		end
	end
	local info, out = {}, {}
	for i, key in ipairs(keys) do
		if type(key) == "string" and not info[key] and State.OwnedCount(key) > 0 then
			local def = P2.defOfKey(key)
			if def then
				info[key] = { Order = rarityOrder(def.Rarity), Hybrid = P2.isHybrid(key, def) and 1 or 0, Index = i }
				out[#out + 1] = key
			end
		end
	end
	table.sort(out, function(a, b)
		local x, y = info[a], info[b]
		if x.Order ~= y.Order then
			return x.Order > y.Order
		end
		if x.Hybrid ~= y.Hybrid then
			return x.Hybrid > y.Hybrid
		end
		return x.Index > y.Index
	end)
	return out
end

-- level, xp of a pet copy
function P2.petLevel(key)
	if type(State.PetLevel) == "function" then
		local ok, level, xp = pcall(State.PetLevel, key)
		if ok and type(level) == "number" then
			return math.max(1, math.floor(level)), tonumber(xp) or 0
		end
	end
	return 1, 0
end

-- XP from `level` to the next one (math.huge at the top of the curve)
function P2.xpToNext(level)
	if TycoonCatalog and type(TycoonCatalog.XpToNext) == "function" then
		local ok, n = pcall(TycoonCatalog.XpToNext, level)
		if ok and type(n) == "number" and n > 0 then
			return n
		end
	end
	return math.huge
end

function P2.levelCap(key, def)
	if type(PetCatalog.LevelCap) == "function" then
		local ok, cap = pcall(PetCatalog.LevelCap, def or key)
		if ok and type(cap) == "number" and cap >= 1 then
			return math.floor(cap)
		end
	end
	return (TycoonCatalog and tonumber(TycoonCatalog.MaxPetLevel)) or 50
end

-- the pet's stats at its level (rarity scale x level factor x tier), or nil without a catalog that knows stats
function P2.statsAt(def, level)
	if type(def) ~= "table" then
		return nil
	end
	if type(PetCatalog.StatsOf) == "function" then
		local ok, stats = pcall(PetCatalog.StatsOf, def, level)
		if ok and type(stats) == "table" then
			return stats
		end
	end
	if type(PetCatalog.GetStats) == "function" and type(def.Id) == "string" then
		local ok, stats = pcall(PetCatalog.GetStats, def.Id, level)
		if ok and type(stats) == "table" then
			return stats
		end
	end
	return nil
end

function P2.homeData()
	if type(State.Home) == "function" then
		local ok, home = pcall(State.Home)
		if ok and type(home) == "table" then
			return home
		end
	end
	return { Level = 0, Prestige = 0, Stations = {}, Garden = {}, Gym = {}, CollectorCash = 0 }
end

function P2.stationLevelOf(home, id)
	local stations = type(home) == "table" and home.Stations or nil
	local level = type(stations) == "table" and stations[id] or nil
	if type(level) == "number" and level == level then
		return math.max(0, math.floor(level))
	end
	return 0
end

-- true while the local player owns (claimed) a home plot this session
function P2.hasHome()
	return LocalPlayer ~= nil and type(LocalPlayer:GetAttribute(Config.Attr.SpotIndex)) == "number"
end

function P2.cashBalance()
	if type(State.Cash) == "function" then
		local ok, value = pcall(State.Cash)
		if ok and type(value) == "number" then
			return value
		end
	end
	return 0
end

function P2.gemBalance()
	if type(State.Gems) == "function" then
		local ok, value = pcall(State.Gems)
		if ok and type(value) == "number" then
			return value
		end
	end
	return 0
end

-- "$950", "$12.5K" (TycoonCatalog.FormatCash, the same text as the pad signs)
function P2.formatCash(n)
	if TycoonCatalog and type(TycoonCatalog.FormatCash) == "function" then
		local ok, text = pcall(TycoonCatalog.FormatCash, n)
		if ok and type(text) == "string" then
			return text
		end
	end
	return G.Cash .. Theme.ShortNumber(tonumber(n) or 0)
end

-- cash per second: one decimal below 100 ("$7.5"), FormatCash above
function P2.formatRate(n)
	n = tonumber(n) or 0
	if n ~= n or n < 0 then
		n = 0
	end
	if n < 100 then
		local text = string.format("%.1f", math.floor(n * 10 + 0.5) / 10)
		text = text:gsub("%.0$", "")
		return G.Cash .. text
	end
	return P2.formatCash(n)
end

function P2.gemAmount(n)
	return G.Gem .. " " .. commas(n)
end

function P2.foodList()
	local foods = TycoonCatalog and TycoonCatalog.Foods
	if type(foods) == "table" then
		return foods
	end
	return {}
end

function P2.foodCount(foodId)
	if type(State.FoodCount) == "function" then
		local ok, n = pcall(State.FoodCount, foodId)
		if ok and type(n) == "number" then
			return n
		end
	end
	return 0
end

function P2.foodGlyph(foodId)
	return G[foodId] or G.Food
end

-- slots of `map` ({[slot] = key}) that hold `key`, ascending
function P2.slotsHolding(map, key)
	local out = {}
	if type(map) == "table" then
		for slot, k in pairs(map) do
			if k == key and type(slot) == "number" then
				out[#out + 1] = slot
			end
		end
	end
	table.sort(out)
	return out
end

function P2.firstFreeSlot(map, count)
	for slot = 1, count do
		if type(map) ~= "table" or map[slot] == nil then
			return slot
		end
	end
	return nil
end

function P2.catalogCall(fnName, ...)
	if not TycoonCatalog or type(TycoonCatalog[fnName]) ~= "function" then
		return nil
	end
	local ok, a, b = pcall(TycoonCatalog[fnName], ...)
	if ok then
		return a, b
	end
	return nil
end

function P2.stationDef(id)
	local def = P2.catalogCall("Get", id)
	if type(def) == "table" then
		return def
	end
	return nil
end

----------------------------------------------------------------------
-- Remotes (sent at most every FIRE_GAP seconds each, the server rate-limits as well)
----------------------------------------------------------------------
local function getRemote(name)
	local cached = Net.Cache[name]
	if cached then
		return cached
	end
	local ok, remote = pcall(Remotes.Get, name)
	if ok and remote then
		Net.Cache[name] = remote
		return remote
	end
	return nil
end

-- Sends remote `name` with the given arguments unless the same `key` was sent less than K.FIRE_GAP seconds ago.
local function fireKeyed(key, name, ...)
	local now = os.clock()
	if Net.Last[key] and now - Net.Last[key] < K.FIRE_GAP then
		return false
	end
	local remote = getRemote(name)
	if not remote then
		return false
	end
	Net.Last[key] = now
	local args = { n = select("#", ...), ... }
	local ok = pcall(function()
		remote:FireServer(unpack(args, 1, args.n))
	end)
	return ok
end

local function fire(name, ...)
	return fireKeyed(name, name, ...)
end

----------------------------------------------------------------------
-- IndexController (optional module written next to this one)
----------------------------------------------------------------------
local function getIndex()
	if not Index.Tried then
		Index.Tried = true
		local moduleScript = script.Parent:FindFirstChild("IndexController")
		if moduleScript then
			local ok, result = pcall(require, moduleScript)
			if ok and type(result) == "table" then
				Index.Module = result
			else
				warnOnce("IndexController", result)
			end
		end
	end
	return Index.Module
end

local function indexOpen()
	local index = Index.Module
	if index and type(index.IsOpen) == "function" then
		local ok, open = pcall(index.IsOpen)
		return ok and open == true
	end
	return false
end

function closeIndex()
	local index = Index.Module
	if index and type(index.Close) == "function" and indexOpen() then
		safe("Index.Close", index.Close)
	end
end

----------------------------------------------------------------------
-- Screen size helpers
----------------------------------------------------------------------
local function guiSize()
	local size = gui and gui.AbsoluteSize or Vector2.new(1280, 720)
	if size.X < 2 or size.Y < 2 then
		return Vector2.new(1280, 720)
	end
	return size
end

local function screenFactor()
	local camera = workspace.CurrentCamera
	local vp = camera and camera.ViewportSize
	if vp and vp.Y > 2 then
		return Theme.ScreenFactor(vp.Y)
	end
	return Theme.ScreenFactor(guiSize().Y)
end

local function screenMargin()
	if touchDevice then
		return K.TOUCH_EDGE
	end
	return K.EDGE
end

-- Right edge (gui px) of the menu column.
local function columnRight()
	local column = U.Column
	if column and column.Visible and column.AbsoluteSize.X > 0 then
		return column.AbsolutePosition.X + column.AbsoluteSize.X
	end
	return 0
end

-- true on a portrait screen (a phone held upright): windows that support it use their single-column layout
local function portraitScreen()
	local area = guiSize()
	return area.X < area.Y
end

-- Size + scale + position for a design-pixel box: { w, h, scale, x, y } (x, y = centre in gui px).
-- The box gets its preferred size when the screen has room for it at the readability scale, shrinks
-- towards its minimum size first, and only then is scaled below the screen factor. It is centred on the
-- screen unless that would put it under the menu column; on small screens it may cover the column when
-- that buys a bigger (more readable) scale. `tallOk`: the box has a single-column layout, so on a portrait
-- screen it may get as narrow as K.TALL_MIN_W (and taller) instead of shrinking its text.
local function fitBox(prefW, prefH, minW, minH, tallOk)
	local area = guiSize()
	local factor = screenFactor()
	if tallOk and area.X < area.Y then
		minW = math.min(minW, K.TALL_MIN_W)
		prefH = math.max(prefH, K.TALL_MAX_H)
	end
	local freeH = area.Y - 2 * K.MARGIN
	local function solve(left)
		local freeW = area.X - left - 2 * K.MARGIN
		local w = Util.Clamp(math.floor(freeW / factor), minW, prefW)
		local h = Util.Clamp(math.floor((freeH - K.BUMPS * factor) / factor), minH, prefH)
		local scale = Util.Clamp(math.min(factor, freeW / w, freeH / h), 0.3, 1.25)
		return w, h, scale
	end
	local left = columnRight()
	local w, h, scale = solve(left)
	if left > 0 and scale < factor - 0.001 then
		local w2, h2, scale2 = solve(0)
		if scale2 > scale + 0.001 then
			w, h, scale, left = w2, h2, scale2, 0
		end
	end
	local half = w * scale / 2
	local x = math.max(area.X / 2, left + K.MARGIN + half)
	x = math.min(x, area.X - K.MARGIN - half)
	local halfH = h * scale / 2
	local y = math.min(area.Y / 2 + K.BUMPS * scale / 2, area.Y - K.MARGIN / 2 - halfH)
	y = math.max(y, halfH)
	return { w = w, h = h, scale = scale, x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
end

----------------------------------------------------------------------
-- Side hint (tiny message next to the menu column; never in the middle of the screen)
----------------------------------------------------------------------
local function buildHint()
	local frame = makeFrame(gui, "MenuHint", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 120, 0.5, 0),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.04,
		Visible = false,
		ZIndex = 9,
	})
	corner(frame, 12)
	stroke(frame, NAVY, 3, 0)
	Theme.Gradient(frame, Colors.PanelLight, Colors.Panel, 90)
	pad(frame, 14, 8, 14, 8)
	local label = makeText(frame, "Text", "", "Toast", 20, WHITE, {
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 10,
	})
	Hint.Limit = Util.Create("UISizeConstraint", { MaxSize = Vector2.new(300, 220), Parent = label })
	Hint.Frame = frame
	Hint.Label = label
	Hint.Scale = Util.Create("UIScale", { Name = "ReadScale", Scale = 1, Parent = frame })
end

function showHint(text, kind)
	if not Hint.Frame then
		return
	end
	Hint.Token = Hint.Token + 1
	local mine = Hint.Token
	local color = KINDS[kind or "info"] or KINDS.info or Colors.PanelLight
	Hint.Label.Text = tostring(text)
	Hint.Label.TextColor3 = Theme.Lighten(color, 0.55)
	Hint.Frame.Visible = true
	task.delay(K.HINT_SECONDS, function()
		if Hint.Token == mine and Hint.Frame then
			Hint.Frame.Visible = false
		end
	end)
end

----------------------------------------------------------------------
-- Window manager
-- window = { Id, Spec, Holder, Fit (UIScale), Pop (UIScale), Panel, Shown, Built, Dirty, Token, W, H,
--            Tab, Refresh = fn(), OnOpen = fn(args), OnClose = fn(), OnLayout = fn(w, h, narrow) }
----------------------------------------------------------------------
local function setBackdrop(on)
	local backdrop = U.Backdrop
	if not backdrop then
		return
	end
	U.BackdropOn = on
	if on then
		backdrop.Visible = true
		tween(backdrop, 0.18, { BackgroundTransparency = 0.55 })
	else
		tween(backdrop, 0.15, { BackgroundTransparency = 1 })
		task.delay(0.17, function()
			if not U.BackdropOn and backdrop.Parent then
				backdrop.Visible = false
			end
		end)
	end
end

-- The Pet Index (its own gui) replaced our window: drop our backdrop at once.
local function hideBackdropNow()
	if openId then
		return
	end
	U.BackdropOn = false
	if U.Backdrop then
		U.Backdrop.Visible = false
		U.Backdrop.BackgroundTransparency = 1
	end
end

local function layoutWindow(win)
	local size = K.WIN[win.Id] or { 1100, 700, 860, 420 }
	local box = fitBox(size[1], size[2], size[3], size[4], win.Spec.Tall == true)
	win.Holder.Size = UDim2.fromOffset(box.w, box.h)
	win.Holder.Position = UDim2.fromOffset(box.x, box.y)
	win.Fit.Scale = box.scale
	local changed = win.W ~= box.w or win.H ~= box.h
	win.W, win.H = box.w, box.h
	if changed and win.Built and win.OnLayout then
		safe("layout " .. win.Id, win.OnLayout, box.w, box.h, box.w < K.NARROW, box.h < K.SHORT, box.w < K.TALL)
	end
end

local function createWindow(spec)
	local size = K.WIN[spec.Id] or { 1100, 700, 860, 420 }
	local win = { Id = spec.Id, Spec = spec, Shown = false, Built = false, Dirty = true, Token = 0 }
	win.Holder = makeFrame(gui, "Window_" .. spec.Id, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 14),
		Size = UDim2.fromOffset(size[1], size[2]),
		Visible = false,
		ZIndex = 3,
	})
	win.Fit = Util.Create("UIScale", { Name = "Fit", Scale = 1, Parent = win.Holder })
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
	if win.OnLayout and win.W then
		safe("layout " .. win.Id, win.OnLayout, win.W, win.H, win.W < K.NARROW, win.H < K.SHORT, win.W < K.TALL)
	end
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
	elseif t:find("gem", 1, true) then
		if windowId == "Shop" then
			return "Gems"
		end
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
	closeIndex()
	if openId and openId ~= id then
		closeWindow(openId, true)
	end
	local wasShown = win.Shown
	win.Shown = true
	win.Token = win.Token + 1
	openId = id
	syncBackBinding()
	layoutWindow(win)
	ensureBuilt(win)
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
	if not wasShown then
		MenuController.WindowOpened:Fire(id)
		if id == "Shop" then
			-- sculpt the likely roulette pools ahead of the spin (the last one spun, then the cheapest)
			if Spin.Last then
				Warm.Roulette(Spin.Last)
			end
			local first = type(Config.Roulettes) == "table" and Config.Roulettes[1] or nil
			if type(first) == "table" then
				Warm.Roulette(first.Id)
			end
		end
	end
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
	elseif id == "Inventory" then
		closeFeed()
	end
	if instant then
		-- another window takes over right away (it keeps the backdrop; see hideBackdropNow)
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
	closeIndex()
end

-- Esc / gamepad B: close the topmost thing. Returns true when something was closed.
-- (The Pet Index handles Esc / B itself.)
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
	if Feed.Gui then
		closeFeed()
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
local function onBackAction(_name, inputState)
	if inputState == Enum.UserInputState.Begin then
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
				K.BACK_ACTION,
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
			ContextActionService:UnbindAction(K.BACK_ACTION)
		end)
	end
end

----------------------------------------------------------------------
-- Menu tiles (left-centre column; a 2 x 3 grid on short screens)
----------------------------------------------------------------------
local function menuActionInventory()
	toggleWindow("Inventory", { Tab = "Items" })
end

local function menuActionPets()
	toggleWindow("Inventory", { Tab = "Pets" })
end

local function openIndex(groupId)
	local index = getIndex()
	if not index or type(index.Open) ~= "function" then
		showHint("The Pet Index is getting ready. Try again soon!", "info")
		return
	end
	if Spin.Stage then
		return
	end
	closeOdds()
	if openId then
		closeWindow(openId, true)
	end
	hideBackdropNow()
	safe("Index.Open", index.Open, groupId)
end

local function menuActionIndex()
	if indexOpen() then
		closeIndex()
	else
		openIndex(nil)
	end
end

local function menuActionShop()
	if inMatch() then
		showHint("The shop is closed during a match.", "info")
		return
	end
	toggleWindow("Shop")
end

-- The Home tile (id "Spot"): the Home window once a home is claimed; before that it walks the player to a free
-- gate (Remotes.GoToSpot: the last plot when it is free, else the nearest free one) where E claims it.
local function menuActionSpot()
	if inMatch() then
		showHint("You cannot go home during a match.", "info")
		return
	end
	if P2.hasHome() then
		toggleWindow("Home")
		return
	end
	closeEverything()
	fire("GoToSpot")
	showHint("Press E at the gate to claim your home!", "info")
end

local function menuActionStats()
	toggleWindow("Stats")
end

local MENU = {
	{ Id = "Inventory", Label = "Inventory", Glyph = G.Backpack, Color = BUTTONS.Blue, Action = menuActionInventory },
	{ Id = "Pets", Label = "Pets", Glyph = G.Paw, Color = BUTTONS.Pink, Action = menuActionPets },
	{ Id = "Index", Label = "Index", Glyph = G.Book, Color = TEAL, Action = menuActionIndex },
	{ Id = "Shop", Label = "Shop", Glyph = G.Money, Color = BUTTONS.Gold, Action = menuActionShop },
	{ Id = "Spot", Label = "Home", Glyph = G.House, Color = BUTTONS.Green, Action = menuActionSpot },
	{ Id = "Stats", Label = "Stats", Glyph = G.Chart, Color = PURPLE, Action = menuActionStats },
}

-- Glossy chunky face: light top, the colour, then a hard darker lip at the bottom.
local function tileSequence(c)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Theme.Lighten(c, 0.34)),
		ColorSequenceKeypoint.new(0.5, Theme.Lighten(c, 0.05)),
		ColorSequenceKeypoint.new(0.78, Theme.Darken(c, 0.08)),
		ColorSequenceKeypoint.new(0.8, Theme.Darken(c, 0.32)),
		ColorSequenceKeypoint.new(1, Theme.Darken(c, 0.4)),
	})
end

local function paintTile(entry)
	local color = entry.Color
	if entry.Disabled then
		color = BUTTONS.Gray or MUTED
	end
	local face = color
	if not entry.Disabled then
		if entry.Pressing then
			face = Theme.Darken(color, 0.08)
		elseif entry.Hovering then
			face = Theme.Lighten(color, 0.1)
		end
	end
	entry.Gradient.Color = tileSequence(face)
	entry.Stroke.Color = entry.Active and GOLD or NAVY
	entry.Glow.Visible = entry.Active == true
	entry.Label.TextColor3 = entry.Active and Theme.Lighten(GOLD, 0.45) or WHITE
end

local function setTileFx(entry, target, seconds)
	if entry.FxTween then
		entry.FxTween:Cancel()
	end
	entry.FxTween = tween(entry.Fx, seconds, { Scale = target })
end

local function buildTile(column, spec, index)
	local entry = { Id = spec.Id, Color = spec.Color or BUTTONS.Blue or PURPLE }
	entry.Root = makeFrame(column, "Entry_" .. spec.Id, {
		Size = UDim2.fromOffset(K.ENTRY_W, K.ENTRY_H),
		LayoutOrder = index,
		ZIndex = 2,
	})
	-- the square tile (the tutorial rings the MenuButton_<Id> button)
	local button = Util.Create("TextButton", {
		Name = "MenuButton_" .. spec.Id,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = "",
		BackgroundColor3 = WHITE,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(K.TILE, K.TILE),
		ZIndex = 3,
		Parent = entry.Root,
	})
	entry.Button = button
	-- soft gold glow behind the tile of the open window (a sibling: children always draw above a parent)
	entry.Glow = makeFrame(entry.Root, "ActiveGlow", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, K.TILE / 2),
		Size = UDim2.fromOffset(K.TILE + 14, K.TILE + 14),
		BackgroundTransparency = 0.3,
		BackgroundColor3 = GOLD,
		Visible = false,
		ZIndex = 2,
	})
	corner(entry.Glow, 24)
	corner(button, 18)
	entry.Stroke = stroke(button, NAVY, 4, 0)
	entry.Gradient = Util.Create("UIGradient", { Rotation = 90, Parent = button })
	local gloss = makeFrame(button, "Gloss", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.72,
		Position = UDim2.fromOffset(8, 6),
		Size = UDim2.new(1, -16, 0.3, 0),
		ZIndex = 3,
	})
	corner(gloss, 10)
	-- two tiny pixel glints: a nod to the voxel world
	for i, glint in ipairs({ { 10, 9, 6 }, { 18, 9, 4 } }) do
		local pixel = makeFrame(button, "Glint" .. i, {
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0.15,
			Position = UDim2.fromOffset(glint[1], glint[2]),
			Size = UDim2.fromOffset(glint[3], glint[3]),
			ZIndex = 4,
		})
		pixel.BorderSizePixel = 0
	end
	local disc = makeFrame(button, "GlyphDisc", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.44, 0),
		Size = UDim2.new(0.66, 0, 0.66, 0),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.8,
		ZIndex = 3,
	})
	round(disc)
	entry.Glyph = Theme.Label(spec.Glyph, "Title", {
		Scaled = true,
		Stroke = 1,
		Props = {
			Name = "Glyph",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.43, 0),
			Size = UDim2.new(0.6, 0, 0.6, 0),
			ZIndex = 5,
		},
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 48, MinTextSize = 14, Parent = entry.Glyph })
	entry.Glyph.Parent = button
	-- bold label sitting on the bottom edge of the tile
	entry.Label = Theme.Label(spec.Label, "Button", {
		Size = K.LABEL_TEXT,
		Stroke = 0.1,
		StrokeColor = INK,
		Outline = 2.5,
		OutlineColor = INK,
		Props = {
			Name = "Label",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 1, 2),
			Size = UDim2.fromOffset(K.ENTRY_W + 4, 26),
			TextScaled = true,
			ZIndex = 6,
		},
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = K.LABEL_TEXT, MinTextSize = 14, Parent = entry.Label })
	entry.Label.Parent = button
	-- little red "!" dot
	entry.Badge = makeFrame(button, "Badge", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(28, 28),
		BackgroundTransparency = 0,
		BackgroundColor3 = BUTTONS.Red or BAD,
		Visible = false,
		ZIndex = 7,
	})
	round(entry.Badge)
	stroke(entry.Badge, NAVY, 2.5, 0)
	makeText(entry.Badge, "Mark", "!", "Button", 19, WHITE, { Size = UDim2.new(1, 0, 1, 0), ZIndex = 8 })

	entry.Fx = Util.Create("UIScale", { Name = "FxScale", Scale = 1, Parent = button })
	button.MouseEnter:Connect(function()
		entry.Hovering = true
		setTileFx(entry, 1.07, 0.12)
		entry.Glyph.Rotation = -10
		tween(entry.Glyph, 0.35, { Rotation = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		paintTile(entry)
	end)
	button.MouseLeave:Connect(function()
		entry.Hovering = false
		entry.Pressing = false
		setTileFx(entry, 1, 0.14)
		paintTile(entry)
	end)
	button.MouseButton1Down:Connect(function()
		entry.Pressing = true
		setTileFx(entry, 0.93, 0.07)
		paintTile(entry)
	end)
	button.MouseButton1Up:Connect(function()
		entry.Pressing = false
		setTileFx(entry, entry.Hovering and 1.07 or 1, 0.12)
		paintTile(entry)
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			entry.Hovering = false
			entry.Pressing = false
			setTileFx(entry, 1, 0.12)
			paintTile(entry)
		end
	end)
	button.Activated:Connect(function()
		safe("menu " .. spec.Id, spec.Action)
	end)
	-- compact (icon-only) tiles name themselves on hover / long-press
	CloudUI.Tooltip(button, function()
		if entry.Label.Visible then
			return nil
		end
		return spec.Label
	end)
	function entry.SetBadge(on)
		entry.Badge.Visible = on and true or false
	end
	paintTile(entry)
	Entries[spec.Id] = entry
	return entry
end

local function buildColumn()
	local column = makeFrame(gui, "MenuColumn", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, K.EDGE, 0.5, 0),
		Size = UDim2.fromOffset(K.ENTRY_W, #MENU * K.ENTRY_H + (#MENU - 1) * K.GAP),
		ZIndex = 2,
	})
	U.Column = column
	U.ColumnScale = Util.Create("UIScale", { Name = "ViewportScale", Scale = 1, Parent = column })
	for index, spec in ipairs(MENU) do
		buildTile(column, spec, index)
	end
end

-- Column layouts: "Column" (labelled tiles, one column), "Grid" (labelled tiles, 2 x 3, short landscape
-- screens; the labels sit on the tiles' bottom edge so the rows pack tighter), "Compact" (icon-only tiles in one
-- column, narrow portrait screens: a second column would reach the middle of the screen there, and a labelled
-- column would collide with the HUD corners) or "CompactGrid" (icon-only tiles, 2 x 3: short touch screens where
-- the band above Roblox's thumbstick cannot hold labelled tiles at a readable size).
local function setColumnLayout(mode)
	if U.ColumnMode == mode and U.ColumnLayout and U.ColumnLayout.Parent then
		return
	end
	if U.ColumnLayout then
		U.ColumnLayout:Destroy()
	end
	U.ColumnMode = mode
	local iconOnly = mode == "Compact" or mode == "CompactGrid"
	local entryH = K.ENTRY_H
	if iconOnly then
		entryH = K.TILE
	elseif mode == "Grid" then
		entryH = K.GRID_ENTRY_H
	end
	for _, entry in pairs(Entries) do
		entry.Root.Size = UDim2.fromOffset(K.ENTRY_W, entryH)
		entry.Label.Visible = not iconOnly
		entry.Label.Position = UDim2.new(0.5, 0, 1, (mode == "Grid") and K.GRID_LABEL_Y or 2)
	end
	if mode == "Grid" or mode == "CompactGrid" then
		U.ColumnLayout = Util.Create("UIGridLayout", {
			CellSize = UDim2.fromOffset(K.ENTRY_W, entryH),
			CellPadding = UDim2.fromOffset(K.GAP, K.GAP),
			FillDirection = Enum.FillDirection.Horizontal,
			FillDirectionMaxCells = 2,
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Top,
			Parent = U.Column,
		})
	else
		U.ColumnLayout = listLayout(U.Column, Enum.FillDirection.Vertical, K.GAP, Enum.HorizontalAlignment.Center)
	end
end

-- Top of the HUD's bottom-left block (vitals + currency pill) in gui px; on touch screens it is raised over
-- the thumbstick. Mirrors HudController's EDGE, TOUCH_RAISE_SMALL / LARGE, VITALS_H, STACK_GAP and CUR_H.
local function bottomBlockTop(area, factor)
	local raise = 12
	if touchDevice then
		local camera = workspace.CurrentCamera
		local vp = camera and camera.ViewportSize or area
		raise = (math.min(vp.X, vp.Y) <= 500) and 150 or 220
	end
	return area.Y - raise - (70 + 10 + 46 + 8) * factor
end

function relayoutMenu()
	if not gui or not U.Column then
		return
	end
	local area = guiSize()
	local factor = screenFactor()
	local margin = screenMargin()
	local n = #MENU
	local mode, cols = "Column", 1
	local scale = factor
	local entryH = K.ENTRY_H
	local columnTop = nil -- gui px of the column's top edge; nil = vertically centred on the screen
	local gridRows = math.ceil(n / 2)
	local gridH = gridRows * K.GRID_ENTRY_H + (gridRows - 1) * K.GAP
	local columnH = n * K.ENTRY_H + (n - 1) * K.GAP
	if area.X >= area.Y and touchDevice then
		-- touch landscape: Roblox's thumbstick owns the bottom-left corner, and a tile on top of it would take the
		-- thumb's touch (My Spot would teleport the player home). The column lives in the band between the top
		-- margin and the stick: one labelled column when it fits at the screen factor, else the 2 x 3 grid while
		-- its labels stay >= MIN_LABEL_PX, else icon-only tiles in a 2 x 3 grid.
		local camera = workspace.CurrentCamera
		local vp = camera and camera.ViewportSize or area
		local stickTop = area.Y - ((math.min(vp.X, vp.Y) <= 500) and K.STICK_TOP_SMALL or K.STICK_TOP_LARGE)
		local top = K.EDGE
		local avail = stickTop - K.STICK_GAP - top
		local labelScale = K.MIN_LABEL_PX / K.LABEL_TEXT
		local h
		if columnH * factor <= avail then
			h = columnH
		elseif math.min(factor, avail / gridH) >= labelScale then
			mode, cols, entryH = "Grid", 2, K.GRID_ENTRY_H
			h = gridH
			scale = math.min(factor, avail / gridH)
		else
			mode, cols, entryH = "CompactGrid", 2, K.TILE
			h = gridRows * K.TILE + (gridRows - 1) * K.GAP
			scale = Util.Clamp(avail / h, 0.4, factor)
		end
		columnTop = top + math.max(0, (avail - h * scale) / 2)
	elseif area.X >= area.Y then
		-- landscape: the HUD has room to step aside, the column only has to fit on the screen
		local avail = area.Y - 2 * margin
		if columnH * factor > avail then
			mode, cols, entryH = "Grid", 2, K.GRID_ENTRY_H
			if gridH * scale > avail then
				scale = math.max(0.4, avail / gridH)
			end
		end
	else
		-- portrait: stay between the HUD's top-left panel (the tallest is ~216 design px) and its
		-- bottom-left block, vertically centred
		local centre = area.Y / 2
		local top = margin + 222 * factor
		local half = math.min(centre - top, bottomBlockTop(area, factor) - 6 - centre)
		if columnH * factor > 2 * half then
			mode, entryH = "Compact", K.TILE
			local compactH = n * K.TILE + (n - 1) * K.GAP
			scale = Util.Clamp(2 * half / compactH, 0.4, factor)
		end
	end
	local rows = math.ceil(n / cols)
	local w = cols * K.ENTRY_W + (cols - 1) * K.GAP
	local h = rows * entryH + (rows - 1) * K.GAP
	setColumnLayout(mode)
	U.Column.Size = UDim2.fromOffset(w, h)
	U.ColumnScale.Scale = scale
	local hintY = UDim2.new(0, 0, 0.5, 0)
	if columnTop then
		U.Column.AnchorPoint = Vector2.new(0, 0)
		U.Column.Position = UDim2.new(0, margin, 0, math.floor(columnTop + 0.5))
		hintY = UDim2.new(0, 0, 0, math.floor(columnTop + h * scale / 2 + 0.5))
	else
		U.Column.AnchorPoint = Vector2.new(0, 0.5)
		U.Column.Position = UDim2.new(0, margin, 0.5, 0)
	end
	if Hint.Frame then
		-- next to the column, and never wide enough to reach the middle of the screen
		local hintLeft = margin + w * scale + 10
		local room = math.max(120, area.X * 0.34 - hintLeft - 28 * factor)
		Hint.Scale.Scale = factor
		Hint.Frame.Position = UDim2.new(0, hintLeft, hintY.Y.Scale, hintY.Y.Offset)
		Hint.Limit.MaxSize = Vector2.new(math.min(300, math.floor(room / factor)), 260)
	end
	for _, win in pairs(windows) do
		if win.Shown then
			layoutWindow(win)
		end
	end
	if Odds.Holder and Odds.Fit then
		local box = fitBox(K.WIN.Odds[1], K.WIN.Odds[2], K.WIN.Odds[3], K.WIN.Odds[4], true)
		Odds.Holder.Size = UDim2.fromOffset(box.w, box.h)
		Odds.Holder.Position = UDim2.fromOffset(box.x, box.y)
		Odds.Fit.Scale = box.scale
	end
	if Spin.Stage and Spin.Stage.Relayout then
		Spin.Stage.Relayout()
	end
end

local function setActive(id, on)
	local entry = Entries[id]
	if entry and entry.Active ~= (on and true or false) then
		entry.Active = on and true or false
		paintTile(entry)
	end
end

local function setDisabled(id, on)
	local entry = Entries[id]
	if entry and entry.Disabled ~= (on and true or false) then
		entry.Disabled = on and true or false
		paintTile(entry)
	end
end

function updateMenuActive()
	local invWin = windows.Inventory
	local invTab = invWin and invWin.Shown and invWin.Tab or nil
	setActive("Inventory", invTab == "Items")
	setActive("Pets", invTab == "Pets")
	setActive("Index", indexOpen())
	setActive("Shop", windows.Shop ~= nil and windows.Shop.Shown)
	setActive("Stats", windows.Stats ~= nil and windows.Stats.Shown)
	setActive("Spot", windows.Home ~= nil and windows.Home.Shown)
	if invWin and invWin.Shown and Entries.Pets then
		Entries.Pets.SetBadge(false)
	end
	-- the Spot and Shop tiles are greyed out in matches
	setDisabled("Spot", inMatch())
	setDisabled("Shop", inMatch())
end

-- Red dot on the Index tile while a completed group's reward waits.
local function refreshIndexBadge()
	local entry = Entries.Index
	local index = Index.Module
	if not entry or not index or type(index.ClaimableCount) ~= "function" then
		return
	end
	local ok, count = pcall(index.ClaimableCount)
	entry.SetBadge(ok and type(count) == "number" and count > 0)
end

local function gotoShopItems()
	if inMatch() then
		showHint("The shop is closed during a match.", "info")
		return
	end
	openWindow("Shop", { Tab = "Items" })
end

----------------------------------------------------------------------
-- Inventory window: tabs Pets + Items. Phase 2: one slot per pet COPY key (tier / hybrid badges, levels), the detail
-- card with level + XP, scaled stats and the Feed / Place in Garden / Train in Gym actions, and the Feed picker.
----------------------------------------------------------------------
local buildInventory -- (the window's helpers live in this do-block: Lua's 200-local limit of the main chunk)
do
	local RAINBOW = Colors.Rainbow or { Color3.fromRGB(232, 104, 120), Color3.fromRGB(98, 168, 232) }

	local function rainbowSequence()
		local keys = {}
		for i, c in ipairs(RAINBOW) do
			keys[#keys + 1] = ColorSequenceKeypoint.new((i - 1) / math.max(1, #RAINBOW - 1), c)
		end
		return ColorSequence.new(keys)
	end

	-- where a pet copy can work: { Place = "Garden" | "Gym", Station, Slots, Placed = {slot...}, Map } or nil
	local function workOf(key, def)
		if type(def) ~= "table" then
			return nil
		end
		local home = P2.homeData()
		if def.Role == "Economy" then
			local map = type(home.Garden) == "table" and home.Garden or {}
			return {
				Place = "Garden",
				Station = "Garden",
				Slots = P2.catalogCall("GardenSlots", home) or 0,
				Placed = P2.slotsHolding(map, key),
				Map = map,
			}
		elseif def.Role == "Combat" then
			local map = type(home.Gym) == "table" and home.Gym or {}
			return {
				Place = "Gym",
				Station = "Gym",
				Slots = P2.catalogCall("GymSlots", home) or 0,
				Placed = P2.slotsHolding(map, key),
				Map = map,
			}
		end
		return nil
	end

	local function usedSlots(map, slots)
		local n = 0
		for slot = 1, slots do
			if type(map) == "table" and map[slot] ~= nil then
				n = n + 1
			end
		end
		return n
	end

	-- dishes waiting in the Kitchen ({ "Snack", "Meal" }, the one cooking first) and seconds left on the first
	local function kitchenQueue()
		local raw = LocalPlayer and LocalPlayer:GetAttribute(K.KITCHEN_QUEUE_ATTR)
		local list = {}
		if type(raw) == "string" then
			for id in raw:gmatch("[^,]+") do
				list[#list + 1] = id
			end
		end
		local readyAt = LocalPlayer and LocalPlayer:GetAttribute(K.KITCHEN_READY_ATTR)
		local left = nil
		if type(readyAt) == "number" and readyAt > 0 then
			local ok, now = pcall(function()
				return workspace:GetServerTimeNow()
			end)
			if ok and type(now) == "number" then
				left = math.max(0, readyAt - now)
			end
		end
		return list, left
	end

	------------------------------------------------------------------
	-- Feed picker (an overlay over the Pets page)
	------------------------------------------------------------------
	local function feedRefresh()
		local F = Feed.Ui
		local key = Feed.Key
		if not F or not Feed.Gui or not key then
			return
		end
		local def = P2.defOfKey(key)
		if not def or State.OwnedCount(key) <= 0 then
			closeFeed()
			return
		end
		local level, xp = P2.petLevel(key)
		local cap = P2.levelCap(key, def)
		local need = P2.xpToNext(level)
		local capped = level >= cap
		F.Title.Text = "Feed " .. P2.displayName(key, def)
		F.Title.TextColor3 = rarityText(def)
		F.Level.Text = "Lv " .. level .. " / " .. cap
		if capped then
			F.Xp.SetFraction(1)
			F.Xp.SetText("MAX LEVEL")
			F.Xp.SetColor(GOLD)
		else
			F.Xp.SetFraction(need > 0 and need < math.huge and math.min(1, xp / need) or 0)
			F.Xp.SetText(commas(math.floor(xp)) .. " / " .. commas(need) .. " XP")
			F.Xp.SetColor(C2.Xp)
		end
		local home = P2.homeData()
		local kitchen = P2.stationLevelOf(home, "Kitchen")
		local cash = P2.cashBalance()
		local queue, left = kitchenQueue()
		local queueMax = 0
		local kdef = P2.stationDef("Kitchen")
		if kitchen >= 1 and kdef and type(kdef.Effects) == "table" then
			local e = kdef.Effects[math.min(kitchen, #kdef.Effects)]
			queueMax = tonumber(e and (e.Queue or e.Slots)) or 0
		end
		local anyFood = false
		for _, row in ipairs(F.Rows) do
			local food = row.Food
			local count = P2.foodCount(food.Id)
			anyFood = anyFood or count > 0
			row.Count.Text = "You have " .. count
			row.Count.TextColor3 = count > 0 and WHITE or MUTED
			CloudUI.SetDisabled(row.Feed, count <= 0 or capped or inMatch())
			local canCook = kitchen >= (tonumber(food.KitchenLevel) or 1)
			row.Cook.Visible = canCook
			row.CookLock.Visible = not canCook
			if canCook then
				row.Cook.Text = "Cook " .. P2.formatCash(food.Price)
				CloudUI.SetDisabled(row.Cook, cash < (tonumber(food.Price) or 0) or #queue >= queueMax or not P2.hasHome() or inMatch())
			else
				row.CookLock.Text = G.Lock .. " Kitchen Lv " .. tostring(food.KitchenLevel or 1)
				row.CookLock.TextWrapped = false
			end
		end
		-- the Kitchen line
		local text, color = nil, MUTED
		if kitchen < 1 then
			text = "Build the Kitchen at your home to cook pet food."
			color = C2.Lock
		elseif #queue > 0 then
			text = "Cooking " .. tostring(queue[1])
			if left then
				text = text .. " (" .. math.ceil(left) .. " s)"
			end
			if #queue > 1 then
				text = text .. "  " .. G.Bullet .. "  " .. (#queue - 1) .. " more queued"
			end
			color = Theme.Lighten(GOOD, 0.35)
		elseif not P2.hasHome() then
			text = "Claim your home to cook: press E at a free gate."
			color = C2.Lock
		else
			text = "Kitchen ready: cook a dish for " .. (anyFood and "more " or "") .. "XP!"
		end
		if capped then
			text = "This pet reached its max level (" .. cap .. " for a " .. tostring(def.Rarity) .. " pet)."
			color = GOLD
		end
		F.Kitchen.Text = text
		F.Kitchen.TextColor3 = color
	end

	function closeFeed()
		Feed.Token = Feed.Token + 1
		if Feed.Gui then
			Feed.Gui.Visible = false
		end
		Feed.Gui = nil
		Feed.Key = nil
		syncBackBinding()
	end

	local function buildFeed(page)
		local F = { Rows = {} }
		local root = makeFrame(page, "FeedPicker", {
			Size = UDim2.new(1, 0, 1, 0),
			Visible = false,
			ZIndex = 40,
		})
		F.Root = root
		local dim = Util.Create("TextButton", {
			Name = "Dim",
			AutoButtonColor = false,
			Text = "",
			BorderSizePixel = 0,
			BackgroundColor3 = Color3.fromRGB(8, 12, 32),
			BackgroundTransparency = 0.4,
			Size = UDim2.new(1, 0, 1, 0),
			ZIndex = 40,
			Parent = root,
		})
		corner(dim, 14)
		dim.Activated:Connect(function()
			closeFeed()
		end)
		local box = makeFrame(root, "Box", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.fromOffset(K.FEED_W, K.FEED_H),
			BackgroundTransparency = 0,
			BackgroundColor3 = Colors.Panel,
			ZIndex = 41,
		})
		corner(box, 16)
		stroke(box, NAVY, 4, 0)
		Theme.Gradient(box, Colors.PanelLight, Colors.Panel, 90)
		F.Box = box
		F.Title = makeText(box, "Title", "Feed", "Title", 28, WHITE, {
			Position = UDim2.fromOffset(18, 10),
			Size = UDim2.new(1, -150, 0, 36),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
			ZIndex = 42,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 28, MinTextSize = 20, Parent = F.Title })
		local back = CloudUI.Button({
			Name = "CloseFeed",
			Text = "Done",
			Style = "Blue",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -14, 0, 10),
			Size = UDim2.fromOffset(118, 44),
			TextSize = 22,
			Callback = function()
				closeFeed()
			end,
			Parent = box,
		})
		back.ZIndex = 42
		F.Level = makeText(box, "Level", "Lv 1", "Heading", 20, WHITE, {
			Position = UDim2.fromOffset(18, 58),
			Size = UDim2.fromOffset(110, 30),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 42,
		})
		F.Xp = CloudUI.Bar({
			Name = "XpBar",
			Position = UDim2.fromOffset(132, 58),
			Size = UDim2.new(1, -150, 0, 30),
			Height = 30,
			TextSize = 20,
			Color = C2.Xp,
			Parent = box,
		})
		F.Xp.Root.ZIndex = 42
		local list = makeFrame(box, "Foods", {
			Position = UDim2.fromOffset(14, 100),
			Size = UDim2.new(1, -28, 0, 3 * 86 + 2 * 8),
			ZIndex = 42,
		})
		listLayout(list, Enum.FillDirection.Vertical, 8)
		F.List = list
		for index, food in ipairs(P2.foodList()) do
			if index > 3 then
				break
			end
			local row = { Food = food }
			local frame = makeInset(list, "Food_" .. tostring(food.Id), {
				Size = UDim2.new(1, 0, 0, 86),
				LayoutOrder = index,
				ZIndex = 42,
			})
			row.Frame = frame
			local disc = makeFrame(frame, "Icon", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 10, 0.5, 0),
				Size = UDim2.fromOffset(60, 60),
				BackgroundTransparency = 0,
				BackgroundColor3 = C2.Kind.Kitchen,
				ZIndex = 43,
			})
			round(disc)
			stroke(disc, NAVY, 3, 0)
			Theme.Gradient(disc, Theme.Lighten(C2.Kind.Kitchen, 0.35), Theme.Darken(C2.Kind.Kitchen, 0.15), 90)
			makeText(disc, "Glyph", P2.foodGlyph(food.Id), "Title", 32, WHITE, { Size = UDim2.new(1, 0, 1, 0), ZIndex = 44 })
			row.Name = makeText(frame, "Name", tostring(food.Name or food.Id) .. "  +" .. commas(food.Xp) .. " XP", "Title", 22, WHITE, {
				Position = UDim2.fromOffset(80, 10),
				Size = UDim2.new(1, -360, 0, 30),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextScaled = true,
				ZIndex = 43,
			})
			Util.Create("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 18, Parent = row.Name })
			row.Count = makeText(frame, "Count", "", "Heading", 19, MUTED, {
				Position = UDim2.fromOffset(80, 46),
				Size = UDim2.new(1, -360, 0, 26),
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 43,
			})
			local buttons = makeFrame(frame, "Buttons", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -10, 0.5, 0),
				Size = UDim2.fromOffset(270, 52),
				ZIndex = 43,
			})
			row.Buttons = buttons
			row.Feed = CloudUI.Button({
				Name = "Feed",
				Text = "Feed",
				Style = "Green",
				Size = UDim2.fromOffset(104, 50),
				TextSize = 22,
				Callback = function()
					local key = Feed.Key
					if not key then
						return
					end
					if P2.foodCount(food.Id) <= 0 then
						showHint("No " .. tostring(food.Name) .. " left. Cook some at your Kitchen!", "info")
						return
					end
					fireKeyed("PetCare:Feed", "PetCare", "Feed", key, food.Id)
				end,
				Parent = buttons,
			})
			row.Feed.ZIndex = 44
			row.Cook = CloudUI.Button({
				Name = "Cook",
				Text = "Cook",
				Style = "Gold",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 0),
				Size = UDim2.fromOffset(156, 50),
				TextSize = 20,
				Callback = function()
					fireKeyed("PetCare:Cook", "PetCare", "Cook", food.Id, 1)
				end,
				Parent = buttons,
			})
			row.Cook.ZIndex = 44
			row.CookLock = makeText(buttons, "CookLock", "", "Heading", 18, C2.Lock, {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.fromOffset(156, 50),
				TextWrapped = true,
				Visible = false,
				ZIndex = 44,
			})
			F.Rows[#F.Rows + 1] = row
		end
		F.Kitchen = makeText(box, "Kitchen", "", "Body", 19, MUTED, {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 18, 1, -12),
			Size = UDim2.new(1, -36, 0, 48),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 42,
		})
		-- narrow pages (portrait phones): the buttons go under the food name
		function F.Layout(pageW)
			local narrowBox = pageW < K.FEED_W + 20
			local boxW = math.min(K.FEED_W, pageW - 16)
			local rowH = narrowBox and 132 or 86
			box.Size = UDim2.fromOffset(boxW, 100 + 3 * rowH + 2 * 8 + 70)
			list.Size = UDim2.new(1, -28, 0, 3 * rowH + 2 * 8)
			for _, row in ipairs(F.Rows) do
				row.Frame.Size = UDim2.new(1, 0, 0, rowH)
				if narrowBox then
					row.Name.Size = UDim2.new(1, -90, 0, 30)
					row.Count.Size = UDim2.new(1, -90, 0, 26)
					row.Buttons.AnchorPoint = Vector2.new(1, 1)
					row.Buttons.Position = UDim2.new(1, -10, 1, -8)
					row.Buttons.Size = UDim2.new(1, -90, 0, 50)
				else
					row.Name.Size = UDim2.new(1, -360, 0, 30)
					row.Count.Size = UDim2.new(1, -360, 0, 26)
					row.Buttons.AnchorPoint = Vector2.new(1, 0.5)
					row.Buttons.Position = UDim2.new(1, -10, 0.5, 0)
					row.Buttons.Size = UDim2.fromOffset(270, 52)
				end
			end
		end
		Feed.Ui = F
		return F
	end

	function openFeed(key)
		local F = Feed.Ui
		if not F or type(key) ~= "string" or State.OwnedCount(key) <= 0 then
			return false
		end
		Feed.Key = key
		Feed.Gui = F.Root
		Feed.Token = Feed.Token + 1
		local mine = Feed.Token
		F.Root.Visible = true
		syncBackBinding()
		local pop = F.Box:FindFirstChild("Pop") or Util.Create("UIScale", { Name = "Pop", Scale = 1, Parent = F.Box })
		pop.Scale = 0.9
		tween(pop, 0.18, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		safe("feed refresh", feedRefresh)
		-- the Kitchen countdown ticks while the picker is open
		task.spawn(function()
			while Feed.Token == mine and Feed.Gui do
				task.wait(0.5)
				if Feed.Token == mine and Feed.Gui then
					safe("feed refresh", feedRefresh)
				end
			end
		end)
		return true
	end

	------------------------------------------------------------------
	-- the window
	------------------------------------------------------------------
	function buildInventory(win)
		local content = win.Panel.Content
		local maxEquipped = Config.Pets.MaxEquipped
		local pets = {
			Slots = {}, -- key -> CloudUI slot in the grid
			EquipSlots = {}, -- 1..MaxEquipped -> small slots in the header
			EquipIds = {}, -- key shown by each header slot
			Selected = nil, -- the selected pet copy key
			DetailPet = nil,
			DetailViewport = nil,
			Pills = {},
			PillKey = nil,
			StatKey = nil,
			Order = {}, -- owned keys in grid order (rarest first)
			Ready = {}, -- key -> true once the grid slot got its pet viewport
			Filling = false, -- true while the staggered viewport builder is running
		}
		local itemRows = {} -- itemId -> { Slot, Owned, Parts }
		local W = {} -- widgets of the pets page
		local refreshInventory

		local tabs = CloudUI.Tabs({
			Name = "InventoryTabs",
			Parent = content,
			Position = UDim2.fromOffset(12, 10),
			Size = UDim2.new(1, -24, 1, -20),
			BarHeight = 50,
			TextSize = 22,
			OnSelect = function(name)
				win.Tab = name
				if name ~= "Pets" then
					closeFeed()
				end
				updateMenuActive()
			end,
		})
		win.Tabs = tabs

		------------------------------------------------------------------
		-- Pets page
		------------------------------------------------------------------
		local function selectedWork()
			local key = pets.Selected
			local def = key and P2.defOfKey(key)
			return key, def, workOf(key, def)
		end

		local function doWork()
			local key, def, work = selectedWork()
			if not key or not def then
				return
			end
			if inMatch() then
				showHint("Pets are busy climbing during a match.", "info")
				return
			end
			if not work then
				showHint("This pet has no job at home.", "info")
				return
			end
			if #work.Placed > 0 then
				if work.Place == "Garden" then
					fireKeyed("HomeAction:Garden", "HomeAction", "GardenSet", { Slot = work.Placed[#work.Placed] })
				else
					fireKeyed("PetCare:Gym", "PetCare", "GymSet", key)
				end
				return
			end
			if work.Slots <= 0 then
				showHint("Build the " .. (work.Place == "Garden" and "Pet Garden" or "Gym") .. " at your home first.", "info")
				return
			end
			local free = P2.firstFreeSlot(work.Map, work.Slots)
			if not free then
				showHint("Your " .. work.Place .. " is full (" .. work.Slots .. "/" .. work.Slots .. "). Upgrade it for more slots.", "info")
				return
			end
			if work.Place == "Garden" then
				fireKeyed("HomeAction:Garden", "HomeAction", "GardenSet", { Slot = free, Key = key })
			else
				fireKeyed("PetCare:Gym", "PetCare", "GymSet", 0, key)
			end
		end

		local function buildDetailCard(page)
			local card = makeInset(page, "Detail", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 0),
				Size = UDim2.new(0, K.DETAIL_W, 1, 0),
			})
			W.Detail = card
			W.DetailEmpty = makeText(card, "Hint", "Pick a pet to see its details.", "Body", 19, MUTED, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				Size = UDim2.new(1, -40, 0, 60),
				TextWrapped = true,
			})
			local body = makeFrame(card, "Body", { Size = UDim2.new(1, 0, 1, 0), Visible = false })
			W.DetailBody = body
			local scroll = scroller(body, "Info", {
				Position = UDim2.fromOffset(4, 4),
				Size = UDim2.new(1, -8, 1, -176),
			})
			W.InfoScroll = scroll
			pad(scroll, 10, 6, 14, 8)
			listLayout(scroll, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center)
			local view = makeFrame(scroll, "View", { Size = UDim2.new(1, 0, 0, 150), LayoutOrder = 1 })
			W.View = view
			W.Glow = makeFrame(view, "Glow", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				Size = UDim2.fromOffset(136, 136),
				BackgroundColor3 = GOLD,
				BackgroundTransparency = 0.78,
			})
			round(W.Glow)
			W.ViewportHolder = makeFrame(view, "ViewportHolder", { Size = UDim2.new(1, 0, 1, 0), ZIndex = 2 })
			W.Name = makeText(scroll, "Name", "", "Title", 30, WHITE, {
				Size = UDim2.new(1, 0, 0, 36),
				TextScaled = true,
				LayoutOrder = 2,
			})
			Util.Create("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 18, Parent = W.Name })
			W.MetaRow = makeFrame(scroll, "Meta", {
				Size = UDim2.new(1, 0, 0, 30),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 3,
			})
			local metaLayout = listLayout(W.MetaRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
			metaLayout.Wraps = true
			W.OwnedLabel = makeText(scroll, "Owned", "", "Heading", 19, MUTED, {
				Size = UDim2.new(1, 0, 0, 24),
				LayoutOrder = 4,
			})
			-- level + XP bar
			local levelRow = makeFrame(scroll, "LevelRow", { Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 5 })
			W.LevelRow = levelRow
			W.LevelText = makeText(levelRow, "Level", "Lv 1", "Heading", 20, WHITE, {
				Size = UDim2.fromOffset(92, 32),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			W.XpBar = CloudUI.Bar({
				Name = "XpBar",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.new(1, -96, 0, 28),
				Height = 28,
				TextSize = 18,
				Color = C2.Xp,
				Parent = levelRow,
			})
			-- stats at this level
			W.StatsRow = makeFrame(scroll, "Stats", {
				Size = UDim2.new(1, 0, 0, 28),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 6,
			})
			local statsLayout = listLayout(W.StatsRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
			statsLayout.Wraps = true
			W.RoleRow = makeFrame(scroll, "Role", { Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 7 })
			listLayout(W.RoleRow, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
			W.Special = makeText(W.RoleRow, "Special", "", "Heading", 18, GOLD, {
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromOffset(0, 26),
				LayoutOrder = 2,
			})
			W.Work = makeText(scroll, "Work", "", "Heading", 19, Theme.Lighten(GOOD, 0.35), {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				LayoutOrder = 8,
			})
			W.Blurb = makeText(scroll, "Blurb", "", "Body", 18, WHITE, {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				LayoutOrder = 9,
			})
			W.Perks = makeText(scroll, "Perks", "", "Heading", 19, Theme.Lighten(GOOD, 0.3), {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				LayoutOrder = 10,
			})
			-- buttons pinned to the bottom of the card: Equip | Unequip, then Feed | Garden / Gym
			local buttons = makeFrame(body, "Buttons", {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 10, 1, -52),
				Size = UDim2.new(1, -20, 0, 116),
			})
			W.Buttons = buttons
			W.EquipBtn = CloudUI.Button({
				Name = "Equip",
				Text = "Equip",
				Style = "Green",
				Size = UDim2.new(0.5, -6, 0.5, -4),
				TextSize = 22,
				Callback = function()
					if pets.Selected then
						fire("EquipPet", pets.Selected)
					end
				end,
				Parent = buttons,
			})
			W.UnequipBtn = CloudUI.Button({
				Name = "Unequip",
				Text = "Unequip",
				Style = "Pink",
				Size = UDim2.new(0.5, -6, 0.5, -4),
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 0),
				TextSize = 22,
				Callback = function()
					if pets.Selected then
						fire("UnequipPet", pets.Selected)
					end
				end,
				Parent = buttons,
			})
			W.FeedBtn = CloudUI.Button({
				Name = "FeedPet",
				Text = "Feed",
				Style = "Gold",
				Size = UDim2.new(0.5, -6, 0.5, -4),
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 0, 1, 0),
				TextSize = 22,
				Callback = function()
					if inMatch() then
						showHint("Pets eat at home, after the match.", "info")
						return
					end
					if pets.Selected then
						openFeed(pets.Selected)
					end
				end,
				Parent = buttons,
			})
			W.WorkBtn = CloudUI.Button({
				Name = "WorkPet",
				Text = "Place in Garden",
				Style = "Blue",
				Size = UDim2.new(0.5, -6, 0.5, -4),
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, 0, 1, 0),
				TextSize = 20,
				Callback = function()
					doWork()
				end,
				Parent = buttons,
			})
			W.WorkBtn.TextScaled = true
			Util.Create("UITextSizeConstraint", { MaxTextSize = 20, MinTextSize = 16, Parent = W.WorkBtn })
			W.Status = makeText(body, "Status", "", "Label", 18, MUTED, {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 10, 1, -4),
				Size = UDim2.new(1, -20, 0, 44),
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Center,
			})
		end

		local function buildPetsPage(page)
			W.Page = page
			local left = makeFrame(page, "Left", { Size = UDim2.new(1, -(K.DETAIL_W + 12), 1, 0) })
			W.Left = left

			local slotSize = 64
			local equipWidth = maxEquipped * slotSize + (maxEquipped - 1) * 8
			local header = makeFrame(left, "Header", { Size = UDim2.new(1, 0, 0, 76) })
			W.EquippedLabel = makeText(header, "EquippedLabel", "Equipped", "Heading", 24, WHITE, {
				Position = UDim2.fromOffset(4, 0),
				Size = UDim2.new(1, -(equipWidth + 12), 0, 30),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			W.PerksLabel = makeText(header, "TeamPerks", "", "Body", 18, MUTED, {
				Position = UDim2.fromOffset(4, 32),
				Size = UDim2.new(1, -(equipWidth + 12), 0, 44),
				TextWrapped = true,
				TextScaled = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
			})
			Util.Create("UITextSizeConstraint", { MaxTextSize = 18, MinTextSize = 16, Parent = W.PerksLabel })
			local equipRow = makeFrame(header, "EquippedSlots", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 2),
				Size = UDim2.fromOffset(equipWidth, slotSize + 4),
			})
			listLayout(equipRow, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
			for i = 1, maxEquipped do
				pets.EquipSlots[i] = readableSlot(CloudUI.Slot({
					Name = "Equipped" .. i,
					Size = UDim2.fromOffset(slotSize, slotSize),
					LayoutOrder = i,
					Parent = equipRow,
					Callback = function()
						local id = pets.EquipIds[i]
						if id then
							pets.Selected = id
							refreshInventory()
						end
					end,
				}))
			end

			local well = makeInset(left, "GridWell", {
				Position = UDim2.fromOffset(0, 84),
				Size = UDim2.new(1, 0, 1, -84),
			})
			W.GridWell = well
			W.Grid = CloudUI.Grid(well, UDim2.fromOffset(104, 104), 10)

			W.Empty = makeFrame(well, "Empty", { Size = UDim2.new(1, 0, 1, 0), Visible = false, ZIndex = 5 })
			listLayout(W.Empty, Enum.FillDirection.Vertical, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
			W.EmptyTitle = makeText(W.Empty, "Title", "No pets yet!", "Title", 32, WHITE, {
				Size = UDim2.new(1, -30, 0, 40),
				LayoutOrder = 1,
			})
			W.EmptyBody = makeText(W.Empty, "Body", "Spin a roulette in the Shop to hatch your first winged friend.", "Body", 20, MUTED, {
				Size = UDim2.new(1, -60, 0, 56),
				TextWrapped = true,
				LayoutOrder = 2,
			})
			W.EmptyButton = CloudUI.Button({
				Name = "OpenShop",
				Text = "Open Shop",
				Style = "Gold",
				Size = UDim2.fromOffset(220, 56),
				TextSize = 24,
				LayoutOrder = 3,
				Callback = function()
					menuActionShop()
				end,
				Parent = W.Empty,
			})

			buildDetailCard(page)
			buildFeed(page)
		end

		-- the tier / hybrid chip (top-left) and the level tag (bottom-left) of a grid slot
		local function paintSlotBadges(slot, key, def)
			if not slot.TierChip then
				local chip = makeFrame(slot.Button, "TierBadge", {
					Position = UDim2.fromOffset(4, 4),
					Size = UDim2.fromOffset(30, 30),
					BackgroundTransparency = 0,
					BackgroundColor3 = WHITE,
					Visible = false,
					ZIndex = 8,
				})
				round(chip)
				stroke(chip, NAVY, 2.5, 0)
				slot.TierGradient = Util.Create("UIGradient", { Rotation = 45, Parent = chip })
				slot.TierText = makeText(chip, "Mark", "", "Button", 18, WHITE, { Size = UDim2.new(1, 0, 1, 0), ZIndex = 9 })
				slot.TierChip = chip
				slot.LevelTag = makeText(slot.Button, "LevelTag", "", "Heading", 18, WHITE, {
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 6, 1, -2),
					Size = UDim2.fromOffset(60, 22),
					TextXAlignment = Enum.TextXAlignment.Left,
					Visible = false,
					ZIndex = 8,
				})
			end
			local tier = P2.tierOf(key, def)
			local hybrid = P2.isHybrid(key, def)
			if hybrid then
				slot.TierChip.Visible = true
				slot.TierGradient.Color = ColorSequence.new(Theme.Lighten(C2.Hybrid, 0.3), Theme.Darken(C2.Hybrid, 0.2))
				slot.TierText.Text = "H"
			elseif tier == "Rainbow" then
				slot.TierChip.Visible = true
				slot.TierGradient.Color = rainbowSequence()
				slot.TierText.Text = "R"
			elseif tier == "Golden" then
				slot.TierChip.Visible = true
				slot.TierGradient.Color = ColorSequence.new(Theme.Lighten(C2.Tier.Golden, 0.3), Theme.Darken(C2.Tier.Golden, 0.15))
				slot.TierText.Text = "G"
			else
				slot.TierChip.Visible = false
			end
			local level = P2.petLevel(key)
			slot.LevelTag.Visible = level > 1
			slot.LevelTag.Text = "Lv " .. level
		end

		local function setPills(def, key, color, elements)
			for _, pill in ipairs(pets.Pills) do
				pill:Destroy()
			end
			pets.Pills = {}
			local rarityPill = readablePill(def.Rarity, color, W.MetaRow)
			rarityPill.LayoutOrder = 1
			table.insert(pets.Pills, rarityPill)
			local tier = P2.tierOf(key, def)
			if tier ~= "Normal" then
				table.insert(pets.Pills, colorPill(W.MetaRow, "Tier_" .. tier, tier, C2.Tier[tier] or GOLD, 18, 2))
			end
			if P2.isHybrid(key, def) then
				table.insert(pets.Pills, colorPill(W.MetaRow, "Hybrid", "Hybrid", C2.Hybrid, 18, 3))
			end
			for i, element in ipairs(elements) do
				table.insert(pets.Pills, elementPill(W.MetaRow, element, 18, 3 + i))
			end
			if type(def.Role) == "string" then
				local rolePill = readablePill(def.Role, ROLE_COLORS[def.Role] or BUTTONS.Blue, W.RoleRow)
				rolePill.LayoutOrder = 1
				table.insert(pets.Pills, rolePill)
			end
		end

		-- stat chips at the pet's level: the role's own stats bright, the others dimmer
		local function setStats(def, level)
			local stats = P2.statsAt(def, level)
			local key = tostring(def.Id) .. "|" .. level
			if pets.StatKey == key then
				return
			end
			pets.StatKey = key
			for _, child in ipairs(W.StatsRow:GetChildren()) do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			W.StatsRow.Visible = stats ~= nil
			if not stats then
				return
			end
			local economy = def.Role == "Economy"
			local order = { "Income", "Power", "Health", "Speed" }
			local colors = {
				Income = C2.Cash,
				Power = Color3.fromRGB(236, 112, 96),
				Health = Color3.fromRGB(240, 120, 150),
				Speed = Color3.fromRGB(98, 172, 232),
			}
			for i, statKey in ipairs(order) do
				local value = tonumber(stats[statKey]) or 0
				local text
				if statKey == "Income" then
					text = "Income " .. P2.formatRate(value) .. "/s"
				else
					text = statKey .. " " .. commas(math.floor(value + 0.5))
				end
				local main = (statKey == "Income") == economy
				local color = main and colors[statKey] or Color3.fromRGB(88, 104, 150)
				colorPill(W.StatsRow, "Stat_" .. statKey, text, color, 18, i)
			end
		end

		local function renderDetail()
			local key = pets.Selected
			local def = key and P2.defOfKey(key) or nil
			local owned = def and State.OwnedCount(key) or 0
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
			if pets.DetailPet ~= key then
				if pets.DetailViewport then
					pets.DetailViewport.Destroy()
				end
				pets.DetailViewport = CloudUI.PetViewport(W.ViewportHolder, def, UDim2.new(1, 0, 1, 0), {
					Spin = "spin",
					ZIndex = 2,
				})
				pets.DetailPet = key
				pets.StatKey = nil
			end
			local tier = P2.tierOf(key, def)
			W.Glow.BackgroundColor3 = (tier ~= "Normal" and C2.Tier[tier]) or color
			W.Name.Text = P2.displayName(key, def)
			W.Name.TextColor3 = rarityText(def)

			-- rarity, tier, hybrid, element and role pills (rebuilt only when they change)
			local elements = elementsOf(def)
			local pillKey = tostring(key) .. "|" .. tostring(def.Rarity) .. "|" .. table.concat(elements, ",") .. "|" .. tostring(def.Role)
			if pets.PillKey ~= pillKey then
				setPills(def, key, color, elements)
				pets.PillKey = pillKey
			end
			local special = type(def.Special) == "table" and def.Special or nil
			W.Special.Text = special and (G.Sparkle .. " " .. tostring(special.Name or "Special")) or ""
			W.Special.Visible = special ~= nil
			W.RoleRow.Visible = special ~= nil or type(def.Role) == "string"

			local equipped = State.EquippedCount(key)
			local text = "Owned x" .. owned
			if equipped > 0 then
				text = text .. "   " .. G.Star .. " " .. equipped .. " equipped"
			end
			W.OwnedLabel.Text = text

			-- level + XP
			local level, xp = P2.petLevel(key)
			local cap = P2.levelCap(key, def)
			local need = P2.xpToNext(level)
			W.LevelText.Text = "Lv " .. level
			if level >= cap then
				W.XpBar.SetFraction(1)
				W.XpBar.SetText("MAX LEVEL")
				W.XpBar.SetColor(GOLD)
			else
				W.XpBar.SetFraction(need > 0 and need < math.huge and math.min(1, xp / need) or 0)
				W.XpBar.SetText(commas(math.floor(xp)) .. " / " .. commas(need) .. " XP")
				W.XpBar.SetColor(C2.Xp)
			end
			setStats(def, level)

			-- where it works
			local work = workOf(key, def)
			local workText, workColor = "", Theme.Lighten(GOOD, 0.35)
			if work and #work.Placed > 0 then
				if work.Place == "Garden" then
					workText = G.Seedling .. " Working in your Garden"
				else
					workText = G.Muscle .. " Training in your Gym"
				end
			end
			W.Work.Text = workText
			W.Work.TextColor3 = workColor
			W.Work.Visible = workText ~= ""

			W.Blurb.Text = def.Blurb or ""
			local mult = P2.tierMultiplier(key, def)
			local lines = {}
			if type(def.Perks) == "table" then
				local perkOrder = PetCatalog.PerkOrder or { "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }
				for _, perkKey in ipairs(perkOrder) do
					local value = def.Perks[perkKey]
					if type(value) == "number" and value ~= 0 then
						table.insert(lines, PetCatalog.PerkLabel(perkKey, value * mult))
					end
				end
			end
			if #lines > 0 then
				W.Perks.Text = table.concat(lines, "\n")
			else
				W.Perks.Text = "No perks"
			end

			-- buttons
			local totalEquipped = #State.Get().Equipped
			local canEquip = equipped < owned and totalEquipped < maxEquipped
			CloudUI.SetDisabled(W.EquipBtn, not canEquip)
			CloudUI.SetDisabled(W.UnequipBtn, equipped <= 0)
			CloudUI.SetDisabled(W.FeedBtn, inMatch())
			if work then
				local placed = #work.Placed > 0
				if work.Place == "Garden" then
					W.WorkBtn.Text = placed and "Leave Garden" or "Place in Garden"
				else
					W.WorkBtn.Text = placed and "Stop training" or "Train in Gym"
				end
				CloudUI.SetStyle(W.WorkBtn, placed and "Pink" or "Blue")
				local full = not placed and work.Slots > 0 and P2.firstFreeSlot(work.Map, work.Slots) == nil
				CloudUI.SetDisabled(W.WorkBtn, inMatch() or (not placed and (work.Slots <= 0 or full)))
				W.WorkBtn.Visible = true
			else
				W.WorkBtn.Visible = false
			end
			local status = ""
			if inMatch() then
				status = "Pets are locked during a match."
			elseif work and #work.Placed == 0 and work.Slots <= 0 then
				status = "Build the " .. (work.Place == "Garden" and "Pet Garden" or "Gym") .. " at home to put it to work."
			elseif work and #work.Placed == 0 and P2.firstFreeSlot(work.Map, work.Slots) == nil then
				status = "Your " .. work.Place .. " is full (" .. usedSlots(work.Map, work.Slots) .. "/" .. work.Slots .. ")."
			elseif equipped >= owned then
				status = "All your copies are equipped."
			elseif totalEquipped >= maxEquipped then
				status = "Your team is full. Unequip a pet first."
			end
			W.Status.Text = status
		end

		-- Content of a grid slot. The pet viewport (a PetBuilder model, a ViewportFrame and a Camera) is
		-- attached by fillPetSlots, a few per frame, so a big collection never builds ~30 models in the frame
		-- the Inventory opens (same idea as the odds popup). Until then a slot is its rarity tile.
		local function gridInfo(key, def, withPet)
			local info = {
				RarityColor = rarityOf(def),
				Name = P2.displayName(key, def) .. " (" .. tostring(def.Rarity) .. ")",
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
			-- one frame's share (time budget); returns true when slots are still waiting for their pet
			local function buildBatch()
				local budget = Warm.Budget()
				for _, key in ipairs(pets.Order) do
					local slot = pets.Slots[key]
					local def = P2.defOfKey(key)
					if slot and def and not pets.Ready[key] then
						if not Warm.Allows(budget) then
							return true
						end
						pets.Ready[key] = true
						slot.SetContent(gridInfo(key, def, true))
						slot.SetCount(State.OwnedCount(key)) -- pet slots hide "x1": needs the Pet content to be set first
						budget.Count = budget.Count + 1
					end
				end
				return false
			end
			pets.Filling = true
			task.spawn(function()
				-- the frame that opens the window already builds it (and the detail card's pet): start on the next one.
				-- Stops when the window closes; the next open refreshes it and resumes with what is still missing.
				task.wait()
				while win.Shown do
					local ok, more = pcall(buildBatch)
					if not ok then
						warnOnce("fill pets", more)
						break
					end
					if not more then
						break
					end
					task.wait()
				end
				pets.Filling = false
			end)
		end

		local function refreshPetsPage()
			local keys = P2.ownedKeys()
			local ownedSet = {}
			for _, key in ipairs(keys) do
				ownedSet[key] = true
			end
			local snapshot = State.Get()

			-- keep the selection valid: prefer an equipped pet, else the rarest one
			if not (pets.Selected and ownedSet[pets.Selected]) then
				pets.Selected = nil
				for _, key in ipairs(snapshot.Equipped) do
					if ownedSet[key] then
						pets.Selected = key
						break
					end
				end
				if not pets.Selected then
					pets.Selected = keys[1]
				end
			end

			-- drop slots of pets that are gone, add slots for new ones, update the rest in place
			for key, slot in pairs(pets.Slots) do
				if not ownedSet[key] then
					slot.Destroy()
					pets.Slots[key] = nil
					pets.Ready[key] = nil
				end
			end
			pets.Order = keys
			for index, key in ipairs(keys) do
				local def = P2.defOfKey(key)
				local slot = pets.Slots[key]
				if not slot then
					slot = readableSlot(CloudUI.Slot({
						Name = "Pet_" .. key,
						Size = UDim2.fromOffset(104, 104),
						Parent = W.Grid,
						Callback = function()
							pets.Selected = key
							refreshInventory()
						end,
					}))
					pets.Slots[key] = slot
				end
				slot.Root.LayoutOrder = index
				local ready = pets.Ready[key] == true
				local owned = State.OwnedCount(key)
				slot.SetContent(gridInfo(key, def, ready))
				if ready or owned > 1 then
					slot.SetCount(owned)
				else
					slot.SetCount(nil) -- a tile without its pet yet would show "x1"
				end
				if State.IsEquipped(key) then
					slot.SetMarker(G.Star, GOLD)
				else
					slot.SetMarker(nil)
				end
				slot.SetSelected(key == pets.Selected)
				paintSlotBadges(slot, key, def)
			end
			W.Grid.Visible = #keys > 0
			W.Empty.Visible = #keys == 0
			if #keys == 0 then
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
				local key = equipped[i]
				local def = key and P2.defOfKey(key) or nil
				if slot then
					if def then
						pets.EquipIds[i] = key
						slot.SetContent({ Pet = def, RarityColor = rarityOf(def), Name = P2.displayName(key, def), Blurb = def.Blurb })
						slot.SetSelected(key == pets.Selected)
					else
						pets.EquipIds[i] = nil
						slot.SetContent(nil)
						slot.SetSelected(false)
					end
				end
			end
			local perkParts = {}
			local order = PetCatalog.PerkOrder or { "MaxHealth", "TokenBonus", "StaminaRegen", "CheckpointHeal" }
			for _, perkKey in ipairs(order) do
				local value = snapshot.Perks[perkKey]
				if type(value) == "number" and value > 0 then
					table.insert(perkParts, PetCatalog.PerkLabel(perkKey, value))
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
			local list = scroller(page, "ItemList", { Size = UDim2.new(1, 0, 1, 0) })
			pad(list, 2, 2, 14, 8)
			listLayout(list, Enum.FillDirection.Vertical, 10)
			for index, def in ipairs(itemList()) do
				local row = makeInset(list, "Row_" .. def.Id, {
					Size = UDim2.new(1, 0, 0, 124),
					LayoutOrder = index,
				})
				local slot = readableSlot(CloudUI.Slot({
					Name = "Item_" .. def.Id,
					Size = UDim2.fromOffset(96, 96),
					Position = UDim2.fromOffset(14, 14),
					Hotkey = tostring(index),
					Parent = row,
				}))
				slot.SetContent({
					Glyph = def.Glyph,
					Color = def.Color,
					RarityColor = CloudUI.RarityColor(def.Rarity),
					Name = def.Name,
					Blurb = def.Blurb,
				})
				local nameLabel = makeText(row, "Name", def.Name, "Title", 26, Theme.Lighten(def.Color, 0.35), {
					Position = UDim2.fromOffset(126, 10),
					Size = UDim2.new(1, -350, 0, 32),
					TextXAlignment = Enum.TextXAlignment.Left,
				})
				local price = makeText(row, "Price", cloudAmount(def.Price) .. " each", "Heading", 20, Colors.Token, {
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -206, 0, 12),
					Size = UDim2.fromOffset(150, 28),
					TextXAlignment = Enum.TextXAlignment.Right,
				})
				local owned = makeText(row, "Owned", "", "Heading", 19, WHITE, {
					Position = UDim2.fromOffset(126, 44),
					Size = UDim2.new(1, -330, 0, 24),
					TextXAlignment = Enum.TextXAlignment.Left,
				})
				local blurb = makeText(row, "Blurb", def.Blurb or "", "Body", 18, MUTED, {
					Position = UDim2.fromOffset(126, 70),
					Size = UDim2.new(1, -330, 0, 48),
					TextWrapped = true,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top,
				})
				local more = CloudUI.Button({
					Name = "GetMore",
					Text = "Get more",
					Style = "Blue",
					Size = UDim2.fromOffset(176, 56),
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -14, 0.5, 0),
					TextSize = 22,
					Callback = gotoShopItems,
					Parent = row,
				})
				itemRows[def.Id] = {
					Slot = slot,
					Owned = owned,
					Def = def,
					Parts = { Row = row, Name = nameLabel, Price = price, Owned = owned, Blurb = blurb, More = more },
				}
			end

			-- the fourth hotbar key is reserved for later
			local locked = makeInset(list, "LockedRow", {
				Size = UDim2.new(1, 0, 0, 58),
				LayoutOrder = 50,
			})
			makeText(locked, "Text", G.Lock .. "  Slot " .. (#itemList() + 1) .. "   More items are coming soon.", "Heading", 19, MUTED, {
				Position = UDim2.fromOffset(16, 0),
				Size = UDim2.new(1, -32, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextWrapped = true,
			})
			makeText(list, "Tip", "Items only work during a match: press 1-" .. #itemList() .. " or tap the hotbar.", "Body", 18, MUTED, {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
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
			if Feed.Gui then
				safe("feed refresh", feedRefresh)
			end
		end

		tabs.Add("Pets", buildPetsPage)
		tabs.Add("Items", buildItemsPage)

		win.Refresh = refreshInventory
		win.OnOpen = function(args)
			local tab = normalizeTab("Inventory", args.Tab)
			if tab then
				tabs.Select(tab)
			end
			if type(args.Key) == "string" and State.OwnedCount(args.Key) > 0 then
				pets.Selected = args.Key
			end
			if args.Action == "Feed" then
				tabs.Select("Pets")
				task.defer(function()
					if win.Shown then
						refreshInventory()
						local key = pets.Selected
						if key then
							openFeed(key)
						else
							showHint("Hatch a pet first: spin a roulette in the Shop!", "info")
						end
					end
				end)
			end
		end
		win.OnLayout = function(w, _h, narrow, short, tall)
			local detailW = narrow and K.DETAIL_W_NARROW or K.DETAIL_W
			local buttonsH = short and 94 or 116
			if W.Detail then
				if tall then
					W.Detail.AnchorPoint = Vector2.new(0, 1)
					W.Detail.Position = UDim2.new(0, 0, 1, 0)
					W.Detail.Size = UDim2.new(1, 0, 0.56, -6)
				else
					W.Detail.AnchorPoint = Vector2.new(1, 0)
					W.Detail.Position = UDim2.new(1, 0, 0, 0)
					W.Detail.Size = UDim2.new(0, detailW, 1, 0)
				end
			end
			if W.Left then
				if tall then
					W.Left.Size = UDim2.new(1, 0, 0.44, -6)
				else
					W.Left.Size = UDim2.new(1, -(detailW + 12), 1, 0)
				end
			end
			if W.View then
				-- compact cards (landscape phones, portrait pages): a smaller pet, slimmer buttons and no status line,
				-- so the name stays in view above the pinned buttons
				local compact = short or tall
				W.View.Size = UDim2.new(1, 0, 0, compact and 96 or 150)
				W.Glow.Size = compact and UDim2.fromOffset(86, 86) or UDim2.fromOffset(136, 136)
				W.Buttons.Size = UDim2.new(1, -20, 0, buttonsH)
				W.Buttons.Position = UDim2.new(0, 10, 1, short and -8 or -52)
				W.Status.Visible = not short
				W.InfoScroll.Size = UDim2.new(1, -8, 1, -(buttonsH + (short and 16 or 60)))
			end
			if Feed.Ui and Feed.Ui.Layout and W.Page then
				local pageW = W.Page.AbsoluteSize.X
				local scale = win.Fit and win.Fit.Scale or 1
				local designW = (pageW > 0 and scale > 0) and (pageW / scale) or (w - 48)
				Feed.Ui.Layout(designW)
			end
			-- item rows: narrow (portrait) rows stack the text and put the button under it
			for _, row in pairs(itemRows) do
				local P = row.Parts
				if tall then
					P.Row.Size = UDim2.new(1, 0, 0, 188)
					P.Name.Size = UDim2.new(1, -140, 0, 32)
					P.Price.Visible = false
					P.Owned.Size = UDim2.new(1, -140, 0, 24)
					P.Blurb.Size = UDim2.new(1, -140, 0, 64)
					P.More.AnchorPoint = Vector2.new(1, 1)
					P.More.Position = UDim2.new(1, -14, 1, -12)
				else
					P.Row.Size = UDim2.new(1, 0, 0, 124)
					P.Name.Size = UDim2.new(1, -350, 0, 32)
					P.Price.Visible = true
					P.Owned.Size = UDim2.new(1, -330, 0, 24)
					P.Blurb.Size = UDim2.new(1, -330, 0, 48)
					P.More.AnchorPoint = Vector2.new(1, 0.5)
					P.More.Position = UDim2.new(1, -14, 0.5, 0)
				end
			end
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
	Odds.Holder = nil
	Odds.Fit = nil
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

	local box = fitBox(K.WIN.Odds[1], K.WIN.Odds[2], K.WIN.Odds[3], K.WIN.Odds[4], true)
	local holder = makeFrame(root, "Holder", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(box.x, box.y),
		Size = UDim2.fromOffset(box.w, box.h),
		ZIndex = 2,
	})
	Odds.Holder = holder
	Odds.Fit = Util.Create("UIScale", { Name = "Fit", Scale = box.scale, Parent = holder })
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

	local scroll = scroller(panel.Content, "OddsList", {
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(1, -16, 1, -16),
	})
	pad(scroll, 6, 4, 14, 8)
	listLayout(scroll, Enum.FillDirection.Vertical, 10)
	makeText(scroll, "Note", "Chance per spin. Pets of the same rarity share that rarity's chance equally.", "Body", 18, MUTED, {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		LayoutOrder = 0,
	})

	-- group the exact odds by rarity
	local groups = {}
	local byRarity = {}
	for _, entry in ipairs(oddsOf(rouletteId)) do
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
	local hasElements = false
	for _, def in ipairs(PetCatalog.Pets or {}) do
		if #elementsOf(def) > 0 then
			hasElements = true
			break
		end
	end
	local cellH = hasElements and 156 or 128

	-- built under the per-frame time budget (Low detail tiles) so opening the popup never hitches
	task.spawn(function()
		local budget = Warm.Budget()
		for index, group in ipairs(groups) do
			if Odds.Token ~= mine then
				return
			end
			local color = CloudUI.RarityColor(group.Rarity)
			local header = makeFrame(scroll, "Header_" .. group.Rarity, {
				Size = UDim2.new(1, -8, 0, 44),
				BackgroundTransparency = 0,
				BackgroundColor3 = Theme.Darken(color, 0.35),
				LayoutOrder = index * 2 - 1,
			})
			corner(header, 10)
			stroke(header, NAVY, 3, 0)
			makeText(header, "Rarity", group.Rarity, "Title", 24, rarityText({ Rarity = group.Rarity }), {
				Position = UDim2.fromOffset(14, 0),
				Size = UDim2.new(0.5, 0, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			makeText(header, "Chance", percentText(group.Total) .. "  total", "Heading", 19, WHITE, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -14, 0, 0),
				Size = UDim2.new(0.5, 0, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Right,
			})

			local cells = makeFrame(scroll, "Cells_" .. group.Rarity, {
				Size = UDim2.new(1, -8, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = index * 2,
			})
			Util.Create("UIGridLayout", {
				CellSize = UDim2.fromOffset(110, cellH),
				CellPadding = UDim2.fromOffset(8, 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
				Parent = cells,
			})
			for cellIndex, entry in ipairs(group.Entries) do
				if Odds.Token ~= mine then
					return
				end
				if not Warm.Allows(budget) then
					task.wait()
					if Odds.Token ~= mine then
						return
					end
					budget = Warm.Budget()
				end
				local def = PetCatalog.Get(entry.PetId)
				local cell = makeFrame(cells, "Cell_" .. tostring(entry.PetId), { LayoutOrder = cellIndex })
				if def then
					local slot = readableSlot(CloudUI.Slot({
						Name = "OddsPet",
						Size = UDim2.fromOffset(88, 88),
						AnchorPoint = Vector2.new(0.5, 0),
						Position = UDim2.new(0.5, 0, 0, 2),
						Parent = cell,
					}))
					slot.SetContent({ Pet = def, Detail = K.ODDS_DETAIL, RarityColor = color, Name = def.Name, Blurb = def.Blurb })
					table.insert(Odds.Slots, slot)
					local elements = elementsOf(def)
					if #elements > 0 then
						local row = makeFrame(cell, "Elements", {
							AnchorPoint = Vector2.new(0.5, 1),
							Position = UDim2.new(0.5, 0, 1, -30),
							Size = UDim2.new(1, 0, 0, 24),
						})
						listLayout(row, Enum.FillDirection.Horizontal, 3, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
						for i, element in ipairs(elements) do
							elementPill(row, element, 18, i)
						end
					end
				end
				makeText(cell, "Percent", percentText(entry.Chance), "Heading", 19, WHITE, {
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.new(0.5, 0, 1, -2),
					Size = UDim2.new(1, 0, 0, 24),
				})
				budget.Count = budget.Count + 1
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

local function buildRouletteCard(shop, parent, roulette, index)
	local color = roulette.Color
	local card = makeFrame(parent, "Roulette_" .. roulette.Id, {
		Size = UDim2.new(0.25, -9, 1, 0),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0,
		LayoutOrder = index,
	})
	corner(card, 16)
	local cardStroke = stroke(card, NAVY, 4, 0)
	Theme.Gradient(card, Theme.Darken(color, 0.28), Theme.Darken(color, 0.7), 90)

	-- name banner
	local banner = makeFrame(card, "Banner", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.new(1, -18, 0, 54),
		BackgroundTransparency = 0,
		BackgroundColor3 = Theme.Lighten(color, 0.1),
	})
	corner(banner, 12)
	stroke(banner, NAVY, 3, 0)
	local bannerText = makeText(banner, "Name", roulette.DisplayName, "Title", 24, WHITE, {
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -16, 1, 0),
		TextScaled = true,
		TextWrapped = true,
		TextStrokeColor3 = Theme.Darken(color, 0.65),
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 16, Parent = bannerText })

	-- the roulette "machine": glossy dome on a base
	local base = makeFrame(card, "Base", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 176),
		Size = UDim2.fromOffset(150, 18),
		BackgroundTransparency = 0,
		BackgroundColor3 = Theme.Darken(color, 0.55),
	})
	corner(base, 9)
	stroke(base, NAVY, 3, 0)
	local dome = makeFrame(card, "Dome", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 72),
		Size = UDim2.fromOffset(120, 120),
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
	local mark = makeText(dome, "Mark", "?", "Title", 64, WHITE, {
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
			{ Position = UDim2.new(0, 0, 0, -7) }
		)
	)

	local price = makeText(card, "Price", cloudAmount(roulette.Price), "Display", 34, Colors.Token, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 200),
		Size = UDim2.new(1, -12, 0, 40),
	})
	local best = bestRarityOf(roulette)
	local bestLabel = nil
	if best then
		bestLabel = makeText(card, "Best", "Up to " .. best, "Heading", 19, rarityText({ Rarity = best }), {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 242),
			Size = UDim2.new(1, -12, 0, 24),
			TextScaled = true,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 19, MinTextSize = 15, Parent = bestLabel })
	end
	local dots = makeFrame(card, "RarityDots", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 272),
		Size = UDim2.new(1, -12, 0, 18),
	})
	listLayout(dots, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	for _, r in ipairs(Config.Rarities) do
		local weight = roulette.Odds[r.Id]
		if type(weight) == "number" and weight > 0 then
			local dot = makeFrame(dots, "Dot_" .. r.Id, {
				Size = UDim2.fromOffset(16, 16),
				BackgroundTransparency = 0,
				BackgroundColor3 = r.Color,
				LayoutOrder = r.Order,
			})
			round(dot)
			stroke(dot, NAVY, 2, 0)
		end
	end

	local oddsButton = CloudUI.Button({
		Name = "Odds",
		Text = "Odds",
		Style = "Blue",
		Size = UDim2.fromOffset(136, 46),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 298),
		TextSize = 21,
		Callback = function()
			openOdds(roulette.Id)
		end,
		Parent = card,
	})
	local spinButton = CloudUI.Button({
		Name = "Spin",
		Text = "Spin",
		Style = "Green",
		Size = UDim2.new(1, -36, 0, 62),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 352),
		TextSize = 30,
		Callback = function()
			requestSpin(roulette.Id)
		end,
		Parent = card,
	})
	Util.Create("UISizeConstraint", { MaxSize = Vector2.new(190, 62), Parent = spinButton })
	local hint = makeText(card, "Hint", "", "Heading", 18, MUTED, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 420),
		Size = UDim2.new(1, -20, 0, 48),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 18, MinTextSize = 15, Parent = hint })
	return {
		Roulette = roulette,
		Root = card,
		Stroke = cardStroke,
		Spin = spinButton,
		Hint = hint,
		Parts = {
			Banner = banner,
			Base = base,
			Dome = dome,
			Mark = mark,
			Price = price,
			Best = bestLabel,
			Dots = dots,
			Odds = oddsButton,
			Spin = spinButton,
			Hint = hint,
		},
	}
end

-- Sets AnchorPoint / Position / Size (and the optional text alignment) of one card part.
local function place(inst, anchorX, anchorY, position, size, align)
	if not inst then
		return
	end
	inst.AnchorPoint = Vector2.new(anchorX, anchorY)
	inst.Position = position
	inst.Size = size
	if align and (inst:IsA("TextLabel") or inst:IsA("TextButton")) then
		inst.TextXAlignment = align
	end
end

-- Roulette card: the tall machine card, or a compact one (short windows: landscape phones) that keeps the
-- Spin button in view without scrolling.
local function layoutRouletteCard(card, compact)
	local P = card.Parts
	local left, centre = Enum.TextXAlignment.Left, Enum.TextXAlignment.Center
	if compact then
		place(P.Banner, 0.5, 0, UDim2.new(0.5, 0, 0, 8), UDim2.new(1, -16, 0, 42))
		place(P.Dome, 0, 0, UDim2.fromOffset(12, 54), UDim2.fromOffset(66, 66))
		place(P.Base, 0, 0, UDim2.fromOffset(6, 110), UDim2.fromOffset(78, 12))
		place(P.Price, 0, 0, UDim2.fromOffset(88, 56), UDim2.new(1, -96, 0, 36), left)
		place(P.Best, 0, 0, UDim2.fromOffset(88, 94), UDim2.new(1, -96, 0, 22), left)
		place(P.Odds, 0, 0, UDim2.fromOffset(10, 130), UDim2.fromOffset(92, 48))
		place(P.Spin, 1, 0, UDim2.new(1, -10, 0, 130), UDim2.new(1, -122, 0, 48))
		place(P.Hint, 0.5, 0, UDim2.new(0.5, 0, 0, 182), UDim2.new(1, -16, 0, 30))
		P.Hint.TextScaled = true -- one or two short lines must fit the compact card
		P.Mark.TextSize = 40
	else
		place(P.Banner, 0.5, 0, UDim2.new(0.5, 0, 0, 10), UDim2.new(1, -18, 0, 54))
		place(P.Dome, 0.5, 0, UDim2.new(0.5, 0, 0, 72), UDim2.fromOffset(120, 120))
		place(P.Base, 0.5, 0, UDim2.new(0.5, 0, 0, 176), UDim2.fromOffset(150, 18))
		place(P.Price, 0.5, 0, UDim2.new(0.5, 0, 0, 200), UDim2.new(1, -12, 0, 40), centre)
		place(P.Best, 0.5, 0, UDim2.new(0.5, 0, 0, 242), UDim2.new(1, -12, 0, 24), centre)
		place(P.Odds, 0.5, 0, UDim2.new(0.5, 0, 0, 298), UDim2.fromOffset(136, 46))
		place(P.Spin, 0.5, 0, UDim2.new(0.5, 0, 0, 352), UDim2.new(1, -36, 0, 62))
		place(P.Hint, 0.5, 0, UDim2.new(0.5, 0, 0, 420), UDim2.new(1, -20, 0, 48))
		P.Hint.TextScaled = false
		P.Mark.TextSize = 64
	end
	P.Dots.Visible = not compact
end

local function buildItemCard(parent, def, index, count)
	local card = makeFrame(parent, "Item_" .. def.Id, {
		Size = UDim2.new(1 / count, -8, 1, 0),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0,
		LayoutOrder = index,
	})
	corner(card, 16)
	stroke(card, NAVY, 4, 0)
	Theme.Gradient(card, Theme.Darken(def.Color, 0.28), Theme.Darken(def.Color, 0.7), 90)

	local slot = readableSlot(CloudUI.Slot({
		Name = "ItemSlot",
		Size = UDim2.fromOffset(104, 104),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Hotkey = tostring(index),
		Parent = card,
	}))
	slot.SetContent({
		Glyph = def.Glyph,
		Color = def.Color,
		RarityColor = CloudUI.RarityColor(def.Rarity),
		Name = def.Name,
		Blurb = def.Blurb,
	})
	local nameLabel = makeText(card, "Name", def.Name, "Title", 26, Theme.Lighten(def.Color, 0.4), {
		Position = UDim2.fromOffset(0, 128),
		Size = UDim2.new(1, 0, 0, 32),
	})
	local blurb = makeText(card, "Blurb", def.Blurb or "", "Body", 18, WHITE, {
		Position = UDim2.fromOffset(16, 164),
		Size = UDim2.new(1, -32, 0, 70),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	local owned = makeText(card, "Owned", "", "Heading", 19, MUTED, {
		Position = UDim2.fromOffset(0, 238),
		Size = UDim2.new(1, 0, 0, 24),
	})
	local price = makeText(card, "Price", cloudAmount(def.Price), "Display", 32, Colors.Token, {
		Position = UDim2.fromOffset(0, 264),
		Size = UDim2.new(1, 0, 0, 38),
	})
	local buy = CloudUI.Button({
		Name = "Buy",
		Text = "Buy +1",
		Style = "Green",
		Size = UDim2.new(1, -40, 0, 58),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 310),
		TextSize = 26,
		Callback = function()
			if inMatch() then
				showHint("The shop is closed during a match.", "info")
				return
			end
			fire("BuyItem", def.Id, 1)
		end,
		Parent = card,
	})
	Util.Create("UISizeConstraint", { MaxSize = Vector2.new(210, 58), Parent = buy })
	local hint = makeText(card, "Hint", "", "Heading", 18, MUTED, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 376),
		Size = UDim2.new(1, -20, 0, 48),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	return {
		Def = def,
		Slot = slot,
		Owned = owned,
		Buy = buy,
		Hint = hint,
		Parts = { Slot = slot.Root, Name = nameLabel, Blurb = blurb, Owned = owned, Price = price, Buy = buy, Hint = hint },
	}
end

-- Item card: tall, or compact for short windows (the Buy button stays in view).
local function layoutItemCard(card, compact)
	local P = card.Parts
	local left, centre = Enum.TextXAlignment.Left, Enum.TextXAlignment.Center
	if compact then
		place(P.Slot, 0, 0, UDim2.fromOffset(12, 12), UDim2.fromOffset(78, 78))
		place(P.Name, 0, 0, UDim2.fromOffset(100, 10), UDim2.new(1, -108, 0, 30), left)
		place(P.Owned, 0, 0, UDim2.fromOffset(100, 42), UDim2.new(1, -108, 0, 22), left)
		place(P.Price, 0, 0, UDim2.fromOffset(100, 64), UDim2.new(1, -108, 0, 30), left)
		place(P.Buy, 0.5, 0, UDim2.new(0.5, 0, 0, 102), UDim2.new(1, -24, 0, 50))
		place(P.Hint, 0.5, 0, UDim2.new(0.5, 0, 0, 158), UDim2.new(1, -16, 0, 48))
	else
		place(P.Slot, 0.5, 0, UDim2.new(0.5, 0, 0, 16), UDim2.fromOffset(104, 104))
		place(P.Name, 0, 0, UDim2.fromOffset(0, 128), UDim2.new(1, 0, 0, 32), centre)
		place(P.Owned, 0, 0, UDim2.fromOffset(0, 238), UDim2.new(1, 0, 0, 24), centre)
		place(P.Price, 0, 0, UDim2.fromOffset(0, 264), UDim2.new(1, 0, 0, 38), centre)
		place(P.Buy, 0.5, 0, UDim2.new(0.5, 0, 0, 310), UDim2.new(1, -40, 0, 58))
		place(P.Hint, 0.5, 0, UDim2.new(0.5, 0, 0, 376), UDim2.new(1, -20, 0, 48))
	end
	P.Blurb.Visible = not compact
end

local function buildShop(win)
	local content = win.Panel.Content
	local shop = { Cards = {}, ItemCards = {}, Bobs = {} }
	local W = {}

	local tabs = CloudUI.Tabs({
		Name = "ShopTabs",
		Parent = content,
		Position = UDim2.fromOffset(12, 10),
		Size = UDim2.new(1, -24, 1, -20),
		BarHeight = 50,
		TextSize = 22,
		OnSelect = function(name)
			win.Tab = name
			updateMenuActive()
			if win.Refresh and win.Built then
				safe("shop tab", win.Refresh)
			end
		end,
	})
	win.Tabs = tabs

	-- token balance (Gems on the Gems tab), right of the tab strip
	local balance = makeFrame(content, "Balance", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 12),
		Size = UDim2.fromOffset(230, 44),
		BackgroundColor3 = Colors.Panel,
		BackgroundTransparency = 0.05,
		ZIndex = 8,
	})
	round(balance)
	stroke(balance, NAVY, 3, 0)
	W.Balance = makeText(balance, "Amount", "", "Display", 26, Colors.Token, {
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -16, 1, 0),
		TextScaled = true,
		ZIndex = 9,
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 26, MinTextSize = 16, Parent = W.Balance })

	local function buildRoulettePage(page)
		local scroll = scroller(page, "Cards", { Size = UDim2.new(1, 0, 1, 0) })
		pad(scroll, 2, 2, 12, 6)
		local row = makeFrame(scroll, "Row", { Size = UDim2.new(1, 0, 0, K.CARD_H) })
		W.RouletteRow = row
		W.RouletteLayout = listLayout(row, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
		for index, roulette in ipairs(Config.Roulettes) do
			shop.Cards[roulette.Id] = buildRouletteCard(shop, row, roulette, index)
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
				hintColor = Theme.Lighten(BAD, 0.35)
			end
			card.Spin.Text = label
			CloudUI.SetDisabled(card.Spin, disabled)
			card.Hint.Text = hint
			card.Hint.TextColor3 = hintColor
		end
	end

	local function buildItemsPage(page)
		local scroll = scroller(page, "Cards", { Size = UDim2.new(1, 0, 1, 0) })
		pad(scroll, 2, 2, 12, 6)
		listLayout(scroll, Enum.FillDirection.Vertical, 10)
		local list = itemList()
		local row = makeFrame(scroll, "Row", { Size = UDim2.new(1, 0, 0, K.ITEM_CARD_H), LayoutOrder = 1 })
		W.ItemRow = row
		W.ItemLayout = listLayout(row, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
		for index, def in ipairs(list) do
			shop.ItemCards[def.Id] = buildItemCard(row, def, index, math.max(3, #list))
		end
		makeText(scroll, "Tip", "Items only work during a match. Use them from the hotbar with keys 1-" .. #list .. " or by tapping.", "Body", 18, MUTED, {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			LayoutOrder = 2,
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
				hintColor = Theme.Lighten(BAD, 0.35)
			end
			card.Buy.Text = label
			CloudUI.SetDisabled(card.Buy, disabled)
			card.Hint.Text = hint
			card.Hint.TextColor3 = hintColor
		end
	end

	------------------------------------------------------------------
	-- Gems page (Phase 2): gem packs (developer products), the Secret roulette, roulettes priced in Gems
	------------------------------------------------------------------
	shop.GemCards = {} -- rouletteId -> { Roulette, Root, Stroke, Spin, Odds, Hint, Price, Parts }
	shop.Packs = {} -- { Product, Root, Price, Buy }
	local G2 = {} -- widgets of the Gems page

	local function createdProducts()
		local out = {}
		local gems = Config.Gems
		for index, product in ipairs(type(gems) == "table" and gems.Products or {}) do
			local id = type(product) == "table" and tonumber(product.Id) or nil
			if id and id > 0 and tonumber(product.Gems) then
				out[#out + 1] = { Index = index, Id = math.floor(id), Gems = math.floor(product.Gems), Name = tostring(product.Name or "Gems") }
			end
		end
		return out
	end

	-- the Robux price of a developer product (MarketplaceService:GetProductInfo, asked once, in the background)
	local function askPrice(productId)
		if Gems.PriceAsked[productId] then
			return
		end
		Gems.PriceAsked[productId] = true
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
			end)
			if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
				Gems.Prices[productId] = math.floor(tonumber(info.PriceInRobux))
				refreshWindow(windows.Shop)
			end
		end)
	end

	local function buyPack(product)
		if inMatch() then
			showHint("The shop is closed during a match.", "info")
			return
		end
		local now = os.clock()
		if Gems.LastPrompt and now - Gems.LastPrompt < 1 then
			return
		end
		Gems.LastPrompt = now
		local ok = pcall(function()
			MarketplaceService:PromptProductPurchase(LocalPlayer, product.Id)
		end)
		if not ok then
			showHint("The Robux store did not open. Try again in a moment.", "bad")
		end
	end

	local function sectionTitle(parent, name, text, order)
		local header = makeFrame(parent, name, {
			Size = UDim2.new(1, 0, 0, 36),
			LayoutOrder = order,
		})
		makeText(header, "Title", text, "Title", 26, WHITE, {
			Position = UDim2.fromOffset(4, 0),
			Size = UDim2.new(1, -8, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		return header
	end

	local function gemDome(parent, color, size)
		local dome = makeFrame(parent, "Dome", {
			Size = UDim2.fromOffset(size, size),
			BackgroundTransparency = 0,
			BackgroundColor3 = WHITE,
		})
		round(dome)
		stroke(dome, NAVY, 3, 0)
		Theme.Gradient(dome, Theme.Lighten(color, 0.5), Theme.Darken(color, 0.1), 90)
		local shine = makeFrame(dome, "Shine", {
			Position = UDim2.fromScale(0.16, 0.1),
			Size = UDim2.fromScale(0.36, 0.2),
			BackgroundTransparency = 0.6,
			BackgroundColor3 = WHITE,
			Rotation = -28,
		})
		round(shine)
		return dome
	end

	-- a roulette priced in Gems: the Secret one (big storm card) or a token roulette (row)
	local function buildGemRoulette(parent, roulette, order, big)
		local color = roulette.Color or C2.Secret
		local card = makeFrame(parent, "GemRoulette_" .. roulette.Id, {
			Size = UDim2.new(1, 0, 0, big and 214 or K.GEM_ROW_H),
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0,
			LayoutOrder = order,
		})
		corner(card, 16)
		local cardStroke = stroke(card, big and Color3.fromRGB(63, 200, 255) or NAVY, big and 4 or 3, 0)
		if big then
			Theme.Gradient(card, Color3.fromRGB(58, 70, 140), Color3.fromRGB(20, 24, 56), 90)
		else
			Theme.Gradient(card, Theme.Darken(color, 0.3), Theme.Darken(color, 0.68), 90)
		end
		local P = {}
		local domeSize = big and 116 or 80
		P.Dome = gemDome(card, color, domeSize)
		P.Dome.AnchorPoint = Vector2.new(0, 0.5)
		P.Dome.Position = UDim2.new(0, 14, 0.5, 0)
		P.Mark = makeText(P.Dome, "Mark", big and G.Storm or "?", "Title", big and 56 or 40, WHITE, {
			Size = UDim2.new(1, 0, 1, 0),
			ZIndex = 3,
		})
		local textX = domeSize + 30
		P.Name = makeText(card, "Name", roulette.DisplayName or roulette.Id, "Title", big and 30 or 24, WHITE, {
			Position = UDim2.fromOffset(textX, big and 12 or 10),
			Size = UDim2.new(1, -(textX + 330), 0, big and 38 or 30),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = big and 30 or 24, MinTextSize = 18, Parent = P.Name })
		local blurbText
		if big then
			blurbText = "The only way to summon Secret pets like Stormfang!"
		else
			local best = bestRarityOf(roulette)
			blurbText = best and ("Up to " .. best .. ", the same odds as with Cloud Tokens") or "The same odds as with Cloud Tokens"
		end
		P.Blurb = makeText(card, "Blurb", blurbText, "Body", 19, MUTED, {
			Position = UDim2.fromOffset(textX, big and 52 or 42),
			Size = UDim2.new(1, -(textX + 330), 0, big and 50 or 26),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		-- the rarity chances (always shown), as coloured chips
		P.Chances = makeFrame(card, "Chances", {
			Position = UDim2.fromOffset(textX, big and 106 or 72),
			Size = UDim2.new(1, -(textX + 330), 0, 30),
			AutomaticSize = Enum.AutomaticSize.Y,
		})
		local chanceLayout = listLayout(P.Chances, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		chanceLayout.Wraps = true
		local total = 0
		for _, w in pairs(roulette.Odds or {}) do
			total = total + (tonumber(w) or 0)
		end
		local chipOrder = 0
		for _, r in ipairs(Config.Rarities) do
			local w = tonumber((roulette.Odds or {})[r.Id])
			if w and w > 0 and total > 0 and (big or rarityOrder(r.Id) >= 3) then
				chipOrder = chipOrder + 1
				local chipColor = r.Id == "Secret" and C2.Hybrid or r.Color
				colorPill(P.Chances, "Chance_" .. r.Id, r.Id .. " " .. percentText(w / total), chipColor, 18, chipOrder)
			end
		end
		-- price + buttons (right)
		P.Right = makeFrame(card, "Buy", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Size = UDim2.fromOffset(310, big and 170 or 96),
		})
		P.Price = makeText(P.Right, "Price", P2.gemAmount(gemPriceOf(roulette.Id) or 0), "Display", big and 32 or 28, Theme.Lighten(C2.Gem, 0.2), {
			Size = UDim2.new(1, 0, 0, big and 40 or 34),
			TextXAlignment = Enum.TextXAlignment.Right,
		})
		local buttons = makeFrame(P.Right, "Buttons", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, big and 48 or 40),
			Size = UDim2.new(1, 0, 0, 54),
		})
		listLayout(buttons, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
		P.Odds = CloudUI.Button({
			Name = "Odds",
			Text = "Odds",
			Style = "Blue",
			Size = UDim2.fromOffset(112, 48),
			TextSize = 21,
			LayoutOrder = 1,
			Callback = function()
				openOdds(roulette.Id)
			end,
			Parent = buttons,
		})
		P.Spin = CloudUI.Button({
			Name = "Spin",
			Text = "Spin",
			Style = big and "Gold" or "Green",
			Size = UDim2.fromOffset(big and 170 or 150, 54),
			TextSize = 26,
			LayoutOrder = 2,
			Callback = function()
				requestSpin(roulette.Id, "Gems")
			end,
			Parent = buttons,
		})
		P.Buttons = buttons
		P.Hint = makeText(P.Right, "Hint", "", "Heading", 18, MUTED, {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, 0, 1, 0),
			Size = UDim2.new(1, 0, 0, big and 56 or 0),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Right,
			Visible = big,
		})
		local entry = { Roulette = roulette, Root = card, Stroke = cardStroke, Spin = P.Spin, Hint = P.Hint, Price = P.Price, Parts = P, Big = big }
		shop.GemCards[roulette.Id] = entry
		return entry
	end

	local function buildPack(parent, product, order)
		local card = makeFrame(parent, "Pack_" .. product.Index, {
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0,
			LayoutOrder = order,
		})
		corner(card, 16)
		stroke(card, NAVY, 4, 0)
		Theme.Gradient(card, Theme.Darken(C2.Gem, 0.25), Theme.Darken(C2.Gem, 0.68), 90)
		local disc = makeFrame(card, "Disc", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 12),
			Size = UDim2.fromOffset(70, 70),
			BackgroundTransparency = 0,
			BackgroundColor3 = C2.Gem,
		})
		round(disc)
		stroke(disc, NAVY, 3, 0)
		Theme.Gradient(disc, Theme.Lighten(C2.Gem, 0.5), Theme.Darken(C2.Gem, 0.15), 90)
		makeText(disc, "Glyph", G.Gem, "Title", 44, WHITE, { Size = UDim2.new(1, 0, 1, 0) })
		local name = makeText(card, "Name", product.Name, "Title", 22, WHITE, {
			Position = UDim2.fromOffset(8, 88),
			Size = UDim2.new(1, -16, 0, 28),
			TextScaled = true,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 18, Parent = name })
		makeText(card, "Amount", P2.gemAmount(product.Gems), "Display", 30, Theme.Lighten(C2.Gem, 0.25), {
			Position = UDim2.fromOffset(0, 116),
			Size = UDim2.new(1, 0, 0, 36),
		})
		local price = makeText(card, "Robux", "", "Heading", 19, MUTED, {
			Position = UDim2.fromOffset(0, 154),
			Size = UDim2.new(1, 0, 0, 24),
		})
		local buy = CloudUI.Button({
			Name = "Buy",
			Text = "Buy",
			Style = "Green",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -10),
			Size = UDim2.new(1, -28, 0, 48),
			TextSize = 22,
			Callback = function()
				buyPack(product)
			end,
			Parent = card,
		})
		Util.Create("UISizeConstraint", { MaxSize = Vector2.new(180, 48), Parent = buy })
		local entry = { Product = product, Root = card, Price = price, Buy = buy }
		shop.Packs[#shop.Packs + 1] = entry
		askPrice(product.Id)
		return entry
	end

	local function buildGemsPage(page)
		local scroll = scroller(page, "Gems", { Size = UDim2.new(1, 0, 1, 0) })
		pad(scroll, 2, 2, 14, 8)
		listLayout(scroll, Enum.FillDirection.Vertical, 10)
		G2.Scroll = scroll

		-- gem packs
		sectionTitle(scroll, "PacksTitle", G.Gem .. " Gem packs", 1)
		local products = createdProducts()
		if #products > 0 then
			local packs = makeFrame(scroll, "Packs", {
				Size = UDim2.new(1, 0, 0, K.GEM_PACK_H),
				LayoutOrder = 2,
			})
			G2.PacksLayout = Util.Create("UIGridLayout", {
				CellSize = UDim2.new(0.25, -8, 0, K.GEM_PACK_H),
				CellPadding = UDim2.fromOffset(10, 10),
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Parent = packs,
			})
			G2.Packs = packs
			for i, product in ipairs(products) do
				buildPack(packs, product, i)
			end
		else
			local soon = makeInset(scroll, "PacksSoon", { Size = UDim2.new(1, 0, 0, 64), LayoutOrder = 2 })
			makeText(soon, "Text", G.Gem .. "  Gem packs open soon! You can still earn Gems by prestiging your home.", "Heading", 19, MUTED, {
				Position = UDim2.fromOffset(16, 0),
				Size = UDim2.new(1, -32, 1, 0),
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
			})
		end

		-- the Secret roulette (gems only) and the token roulettes priced in Gems
		G2.Roulettes = {}
		local secret = secretRoulette() and findRoulette(secretRoulette().Id) or nil
		local order = 3
		G2.SecretTitle = sectionTitle(scroll, "SecretTitle", G.Storm .. " Storm Altar", order)
		G2.Roulettes[#G2.Roulettes + 1] = G2.SecretTitle
		if secret and gemPriceOf(secret.Id) then
			order = order + 1
			G2.Roulettes[#G2.Roulettes + 1] = buildGemRoulette(scroll, secret, order, true).Root
		end
		order = order + 1
		local rouletteTitle = sectionTitle(scroll, "GemRoulettesTitle", "Roulettes for Gems", order)
		G2.Roulettes[#G2.Roulettes + 1] = rouletteTitle
		for _, roulette in ipairs(Config.Roulettes) do
			if gemPriceOf(roulette.Id) then
				order = order + 1
				G2.Roulettes[#G2.Roulettes + 1] = buildGemRoulette(scroll, roulette, order, false).Root
			end
		end
		-- the policy notice (shown instead of the roulettes while they are not allowed)
		G2.Notice = makeInset(scroll, "GemNotice", { Size = UDim2.new(1, 0, 0, 84), LayoutOrder = 4, Visible = false })
		G2.NoticeText = makeText(G2.Notice, "Text", "", "Heading", 19, C2.Lock, {
			Position = UDim2.fromOffset(16, 0),
			Size = UDim2.new(1, -32, 1, 0),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		makeText(scroll, "Tip", "Every roulette shows its exact odds (Odds button). Gems are bought with Robux and never expire.", "Body", 18, MUTED, {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			LayoutOrder = 100,
		})
	end

	local function refreshGemsPage()
		local gems = P2.gemBalance()
		local state = gemRoulettesState()
		local match = inMatch()
		for _, packEntry in ipairs(shop.Packs) do
			local robux = Gems.Prices[packEntry.Product.Id]
			packEntry.Price.Text = robux and (G.Robux .. " " .. commas(robux)) or "for Robux"
			CloudUI.SetDisabled(packEntry.Buy, match)
		end
		local open = state == "Open"
		for _, inst in ipairs(G2.Roulettes or {}) do
			inst.Visible = open
		end
		if G2.Notice then
			G2.Notice.Visible = not open
			if state == "Restricted" then
				G2.NoticeText.Text = G.Lock .. "  Gem roulettes are not available on this account right now. Gem packs and Cloud Token roulettes still work."
			else
				G2.NoticeText.Text = G.Storm .. "  Gem roulettes and the Secret Roulette open soon at the Storm Altar!"
			end
		end
		for _, card in pairs(shop.GemCards) do
			local price = gemPriceOf(card.Roulette.Id) or 0
			card.Price.Text = P2.gemAmount(price)
			local label, hint, disabled = "Spin", "", false
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
			elseif gems < price then
				disabled = true
				hint = "Need " .. P2.gemAmount(price - gems) .. " more"
				hintColor = Theme.Lighten(BAD, 0.35)
			elseif card.Big then
				hint = "Odds: Mythic or Secret on every spin"
			end
			card.Spin.Text = label
			CloudUI.SetDisabled(card.Spin, disabled or not open)
			card.Hint.Text = hint
			card.Hint.TextColor3 = hintColor
			card.Price.TextColor3 = gems < price and Theme.Lighten(BAD, 0.35) or Theme.Lighten(C2.Gem, 0.2)
		end
	end

	-- wide: 4 packs per row, the roulette text left of the buttons; tall (portrait): 2 packs per row, the price
	-- and buttons under the text
	local function layoutGemsPage(_w, tall)
		if G2.Packs then
			local rows = math.ceil(#shop.Packs / (tall and 2 or 4))
			G2.PacksLayout.CellSize = UDim2.new(tall and 0.5 or 0.25, -8, 0, K.GEM_PACK_H)
			G2.Packs.Size = UDim2.new(1, 0, 0, rows * K.GEM_PACK_H + math.max(0, rows - 1) * 10)
		end
		for _, card in pairs(shop.GemCards) do
			local P = card.Parts
			local big = card.Big
			local domeSize = big and 116 or 80
			if tall then
				local textX = (big and 96 or 74) + 22
				P.Dome.Size = UDim2.fromOffset(big and 96 or 74, big and 96 or 74)
				P.Dome.AnchorPoint = Vector2.new(0, 0)
				P.Dome.Position = UDim2.fromOffset(12, 12)
				P.Name.Position = UDim2.fromOffset(textX, 12)
				P.Name.Size = UDim2.new(1, -(textX + 12), 0, 32)
				P.Blurb.Position = UDim2.fromOffset(textX, 46)
				P.Blurb.Size = UDim2.new(1, -(textX + 12), 0, big and 50 or 48)
				P.Chances.Position = UDim2.fromOffset(12, big and 120 or 128)
				P.Chances.Size = UDim2.new(1, -24, 0, 30)
				P.Right.AnchorPoint = Vector2.new(0.5, 1)
				P.Right.Position = UDim2.new(0.5, 0, 1, -10)
				P.Right.Size = UDim2.new(1, -24, 0, big and 110 or 96)
				card.Root.Size = UDim2.new(1, 0, 0, big and 300 or 270)
			else
				local textX = domeSize + 30
				P.Dome.Size = UDim2.fromOffset(domeSize, domeSize)
				P.Dome.AnchorPoint = Vector2.new(0, 0.5)
				P.Dome.Position = UDim2.new(0, 14, 0.5, 0)
				P.Name.Position = UDim2.fromOffset(textX, big and 12 or 10)
				P.Name.Size = UDim2.new(1, -(textX + 330), 0, big and 38 or 30)
				P.Blurb.Position = UDim2.fromOffset(textX, big and 52 or 42)
				P.Blurb.Size = UDim2.new(1, -(textX + 330), 0, big and 50 or 26)
				P.Chances.Position = UDim2.fromOffset(textX, big and 106 or 72)
				P.Chances.Size = UDim2.new(1, -(textX + 330), 0, 30)
				P.Right.AnchorPoint = Vector2.new(1, 0.5)
				P.Right.Position = UDim2.new(1, -14, 0.5, 0)
				P.Right.Size = UDim2.fromOffset(310, big and 170 or 96)
				card.Root.Size = UDim2.new(1, 0, 0, big and 214 or K.GEM_ROW_H)
			end
		end
	end

	tabs.Add("Roulettes", buildRoulettePage)
	tabs.Add("Items", buildItemsPage)
	tabs.Add("Gems", buildGemsPage)

	-- gold outline on the roulette the player walked up to (OpenPanel passes RouletteId)
	local function focusCard(rouletteId)
		local card = shop.Cards[rouletteId] or shop.GemCards[rouletteId]
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
		if win.Tab == "Gems" then
			W.Balance.Text = P2.gemAmount(P2.gemBalance())
			W.Balance.TextColor3 = Theme.Lighten(C2.Gem, 0.2)
		else
			W.Balance.Text = cloudAmount(State.Tokens())
			W.Balance.TextColor3 = Colors.Token
		end
		refreshRouletteCards()
		refreshItemCards()
		refreshGemsPage()
	end
	-- compact cards when the tall ones would not fit the page (landscape phones); one card per row on portrait
	-- screens (the tall layout), with the balance pill above the tabs
	win.OnLayout = function(w, h, _narrow, _short, tall)
		local compact = h < K.SHOP_COMPACT or tall == true
		for _, card in pairs(shop.Cards) do
			layoutRouletteCard(card, compact)
		end
		for _, card in pairs(shop.ItemCards) do
			layoutItemCard(card, compact)
		end
		local function stack(row, layout, cards, cardH, count, wideSize)
			if not row or not layout then
				return
			end
			if tall then
				layout.FillDirection = Enum.FillDirection.Vertical
				for _, card in pairs(cards) do
					card.Root.Size = UDim2.new(1, 0, 0, cardH)
				end
				row.Size = UDim2.new(1, 0, 0, count * cardH + math.max(0, count - 1) * 12)
			else
				layout.FillDirection = Enum.FillDirection.Horizontal
				for _, card in pairs(cards) do
					card.Root.Size = wideSize
				end
				row.Size = UDim2.new(1, 0, 0, cardH)
			end
		end
		local roulettes, items = 0, 0
		for _ in pairs(shop.Cards) do
			roulettes = roulettes + 1
		end
		for _ in pairs(shop.ItemCards) do
			items = items + 1
		end
		stack(W.RouletteRow, W.RouletteLayout, shop.Cards, compact and K.CARD_H_SHORT or K.CARD_H, roulettes, UDim2.new(0.25, -9, 1, 0))
		stack(W.ItemRow, W.ItemLayout, shop.ItemCards, compact and K.ITEM_CARD_H_SHORT or K.ITEM_CARD_H, items, UDim2.new(1 / math.max(3, items), -8, 1, 0))
		tabs.Root.Position = UDim2.fromOffset(12, tall and 62 or 10)
		tabs.Root.Size = UDim2.new(1, -24, 1, tall and -72 or -20)
		layoutGemsPage(w, tall == true)
	end
	win.OnOpen = function(args)
		local tab = normalizeTab("Shop", args.Tab)
		local target = type(args.RouletteId) == "string" and findRoulette(args.RouletteId) or nil
		if not tab and (args.Currency == "Gems" or (target and target.GemsOnly)) then
			tab = "Gems"
		end
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

	-- left: stat tiles + pet perks
	local left = scroller(content, "Left", {
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.new(0.55, -21, 1, -28),
	})
	pad(left, 2, 2, 12, 6)
	listLayout(left, Enum.FillDirection.Vertical, 10)
	local grid = makeFrame(left, "Tiles", {
		Size = UDim2.new(1, 0, 0, 4 * 94 + 3 * 10),
		LayoutOrder = 1,
	})
	Util.Create("UIGridLayout", {
		CellSize = UDim2.new(0.5, -5, 0, 94),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	local TILES = {
		{ "Matches", "Matches played", WHITE },
		{ "Wins", "Victories", Theme.Lighten(GOOD, 0.25) },
		{ "WinRate", "Win rate", WHITE },
		{ "Tokens", "Cloud tokens", Colors.Token },
		{ "Earned", "Tokens earned", Colors.Token },
		{ "Spins", "Roulette spins", WHITE },
		{ "Found", "Pets discovered", Theme.Lighten(PURPLE, 0.35) },
		{ "Owned", "Pets owned", WHITE },
	}
	for index, spec in ipairs(TILES) do
		local tile = makeInset(grid, "Tile_" .. spec[1], { LayoutOrder = index })
		local value = makeText(tile, "Value", "0", "Display", 34, spec[3], {
			Position = UDim2.fromOffset(14, 8),
			Size = UDim2.new(1, -28, 0, 42),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 34, MinTextSize = 18, Parent = value })
		makeText(tile, "Caption", spec[2], "Heading", 18, MUTED, {
			Position = UDim2.fromOffset(14, 56),
			Size = UDim2.new(1, -28, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		tiles[spec[1]] = value
	end

	local perks = makeInset(left, "Perks", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
	})
	pad(perks, 14, 10, 14, 12)
	listLayout(perks, Enum.FillDirection.Vertical, 4)
	makeText(perks, "Title", "Pet perks", "Heading", 22, WHITE, {
		Size = UDim2.new(1, 0, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
	})
	local perksLabel = makeText(perks, "Lines", "", "Body", 19, Theme.Lighten(GOOD, 0.25), {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
	})

	-- right: best time per difficulty
	local right = makeInset(content, "BestTimes", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14),
		Size = UDim2.new(0.45, -21, 1, -28),
	})
	local list = scroller(right, "List", {
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.new(1, -12, 1, -12),
	})
	pad(list, 8, 4, 14, 8)
	listLayout(list, Enum.FillDirection.Vertical, 8)
	makeText(list, "Title", "Best times", "Title", 28, WHITE, {
		Size = UDim2.new(1, 0, 0, 36),
		LayoutOrder = 0,
	})
	for index, difficulty in ipairs(Config.Difficulties) do
		local row = makeFrame(list, "Row_" .. difficulty.Id, {
			Size = UDim2.new(1, 0, 0, 66),
			BackgroundTransparency = 0,
			BackgroundColor3 = Theme.Darken(difficulty.Color, 0.55),
			LayoutOrder = index,
		})
		corner(row, 12)
		stroke(row, NAVY, 3, 0)
		local bar = makeFrame(row, "Bar", {
			Position = UDim2.fromOffset(6, 8),
			Size = UDim2.new(0, 7, 1, -16),
			BackgroundTransparency = 0,
			BackgroundColor3 = difficulty.Color,
		})
		round(bar)
		makeText(row, "Name", difficulty.DisplayName, "Title", 24, Theme.Lighten(difficulty.Color, 0.45), {
			Position = UDim2.fromOffset(22, 5),
			Size = UDim2.new(0.55, -22, 0, 30),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		makeText(row, "Stars", starText(difficulty.Stars), "Heading", 18, GOLD, {
			Position = UDim2.fromOffset(22, 36),
			Size = UDim2.new(0.55, -22, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		rows[difficulty.Id] = makeText(row, "Time", "--:--", "Display", 30, WHITE, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -14, 0, 0),
			Size = UDim2.new(0.45, 0, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
		})
	end

	win.OnLayout = function(_w, _h, _narrow, _short, tall)
		if tall then
			left.Position = UDim2.fromOffset(14, 14)
			left.Size = UDim2.new(1, -28, 0.6, -21)
			right.AnchorPoint = Vector2.new(0, 1)
			right.Position = UDim2.new(0, 14, 1, -14)
			right.Size = UDim2.new(1, -28, 0.4, -21)
		else
			left.Position = UDim2.fromOffset(14, 14)
			left.Size = UDim2.new(0.55, -21, 1, -28)
			right.AnchorPoint = Vector2.new(1, 0)
			right.Position = UDim2.new(1, -14, 0, 14)
			right.Size = UDim2.new(0.45, -21, 1, -28)
		end
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
		local _, total = petTotals()
		tiles.Found.Text = string.format("%d / %d", discoveredCount(), catalogTotal())
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
			perksLabel.TextColor3 = Theme.Lighten(GOOD, 0.25)
		else
			perksLabel.Text = "No perks yet. Equip a pet in your inventory!"
			perksLabel.TextColor3 = MUTED
		end
	end
end

----------------------------------------------------------------------
-- Home window (Phase 2): the house, income, the Collector, prestige, and every station with its upgrade
----------------------------------------------------------------------
local buildHome -- (the window's helpers live in this do-block: Lua's 200-local limit of the main chunk)
do
	local HOME_SECTIONS = {
		{ Id = "Money", Title = "Money makers", Kinds = { Press = true, Collector = true, Vault = true } },
		{ Id = "Pets", Title = "Pets at home", Kinds = { Garden = true, Kitchen = true, Gym = true, Fusion = true } },
		{ Id = "House", Title = "House", Kinds = { House = true, Arena = true } },
		{ Id = "Decor", Title = "Decor", Kinds = { Decor = true } },
	}

	local function shortPercent(fraction)
		local p = (tonumber(fraction) or 0) * 100
		if math.abs(p - math.floor(p + 0.5)) < 0.05 then
			return tostring(math.floor(p + 0.5)) .. "%"
		end
		return string.format("%.1f%%", p)
	end

	local function shortNumber(n)
		n = tonumber(n) or 0
		if math.abs(n - math.floor(n + 0.5)) < 1e-6 then
			return tostring(math.floor(n + 0.5))
		end
		return (string.format("%.2f", n):gsub("0+$", ""):gsub("%.$", ""))
	end

	-- What a station does at `level` (a short phrase), or nil.
	local function effectText(def, level)
		if type(def) ~= "table" or type(def.Effects) ~= "table" or level < 1 then
			return nil
		end
		local e = def.Effects[math.min(level, def.MaxLevel or level)]
		if type(e) ~= "table" then
			return nil
		end
		local kind = def.Kind
		if kind == "Press" then
			return P2.formatRate(e.Income) .. "/s"
		elseif kind == "Collector" then
			if (tonumber(e.Bonus) or 0) > 0 then
				return "+" .. shortPercent(e.Bonus) .. " press Cash"
			end
			return "Banks press Cash"
		elseif kind == "Garden" then
			local slots = tonumber(e.Slots) or 0
			return slots .. (slots == 1 and " pet slot" or " pet slots")
		elseif kind == "Kitchen" then
			return tostring(e.Queue or e.Slots or 0) .. " dishes, x" .. shortNumber(e.CookSpeed or 1) .. " speed"
		elseif kind == "Gym" then
			return tostring(e.Slots or 0) .. " slots, " .. tostring(e.XpPerMinute or 0) .. " XP/min"
		elseif kind == "Vault" then
			return shortPercent(e.OfflinePercent) .. " for " .. tostring(e.OfflineHours or 0) .. "h away"
		elseif kind == "House" then
			return tostring(e.Name or e.Tier or "")
		elseif kind == "Fusion" then
			if (tonumber(e.TokenDiscount) or 0) > 0 then
				return "-" .. shortPercent(e.TokenDiscount) .. " fusion cost"
			end
			return "Fuse pets"
		elseif kind == "Arena" then
			return "Pet battles"
		elseif kind == "Decor" then
			return tostring(e.Style or "Decor") .. " style"
		end
		return nil
	end

	-- "Needs Cloud Press 2 Lv 2" for a station whose tree is not met yet (nil when it is)
	local function treeReason(def, home)
		if type(def) ~= "table" or type(def.Requires) ~= "table" then
			return nil
		end
		local keys = {}
		for key in pairs(def.Requires) do
			if key ~= "Prestige" and P2.stationDef(key) and key ~= "House" then
				keys[#keys + 1] = key
			end
		end
		table.sort(keys, function(a, b)
			return (P2.stationDef(a).Order or 0) < (P2.stationDef(b).Order or 0)
		end)
		for _, key in ipairs(keys) do
			local need = tonumber(def.Requires[key]) or 0
			if P2.stationLevelOf(home, key) < need then
				local other = P2.stationDef(key)
				local name = other and other.Name or key
				if need <= 1 then
					return "Needs the " .. name
				end
				return "Needs " .. name .. " Lv " .. need
			end
		end
		return nil
	end

	-- the Garden pets that earn (Economy pets in unlocked slots), as TycoonCatalog.IncomePerSecond entries
	local function gardenEntries(home)
		local entries = {}
		local slots = P2.catalogCall("GardenSlots", home) or 0
		local garden = type(home.Garden) == "table" and home.Garden or {}
		for slot = 1, slots do
			local key = garden[slot]
			if type(key) == "string" then
				local def = P2.defOfKey(key)
				if def and def.Role == "Economy" and State.OwnedCount(key) > 0 then
					entries[#entries + 1] = { Def = def, Level = (P2.petLevel(key)) }
				end
			end
		end
		return entries
	end

	-- cash/s, { Press, Garden, Multiplier } computed here (the plot's IncomePerSecond attribute wins when present)
	local function homeIncome(home)
		local total, parts = P2.catalogCall("IncomePerSecond", home, gardenEntries(home))
		if type(total) ~= "number" then
			return 0, { Press = 0, Garden = 0, Multiplier = 1 }
		end
		if type(parts) ~= "table" then
			parts = { Press = total, Garden = 0, Multiplier = 1 }
		end
		return total, parts
	end

	-- the local player's plot folder (workspace.NimbusLobby ... Spot_NN, attribute SpotIndex), or nil
	local function plotFolder()
		local index = LocalPlayer and LocalPlayer:GetAttribute(Config.Attr.SpotIndex)
		if type(index) ~= "number" then
			return nil
		end
		local folder = Home.Folder
		if folder and folder.Parent and folder:GetAttribute("SpotIndex") == index then
			return folder
		end
		folder = nil
		local lobby = workspace:FindFirstChild("NimbusLobby")
		if lobby then
			local named = lobby:FindFirstChild(string.format("Spot_%02d", index), true)
			if named and named:GetAttribute("SpotIndex") == index then
				folder = named
			end
		end
		Home.Folder = folder
		return folder
	end

	-- collector cash, cap, income/s, income parts: the plot's live attributes, else computed from the synced home
	local function homeLive(home)
		local folder = plotFolder()
		local localIncome, parts = homeIncome(home)
		local income = folder and folder:GetAttribute("IncomePerSecond")
		if type(income) ~= "number" then
			income = localIncome
		end
		local cash = folder and folder:GetAttribute("CollectorCash")
		if type(cash) ~= "number" then
			cash = tonumber(home.CollectorCash) or 0
		end
		local cap = folder and folder:GetAttribute("CollectorCap")
		if type(cap) ~= "number" then
			cap = P2.catalogCall("CollectorCap", home, income) or 0
		end
		return cash, cap, income, parts
	end

	local function prestigeStars(n)
		n = math.max(0, math.floor(tonumber(n) or 0))
		if n == 0 then
			return "No stars yet"
		elseif n <= 5 then
			return string.rep(G.Star, n)
		end
		return G.Star .. " x" .. n
	end

	function buildHome(win)
		local content = win.Panel.Content
		local H = { Rows = {}, Sections = {}, Pads = {}, Tall = false, Cards = {} }
		win.HomeUi = H

		-- left: the summary column (scrolls on short screens); right: the station list
		local left = scroller(content, "Summary", {
			Position = UDim2.fromOffset(12, 12),
			Size = UDim2.new(0, K.HOME_LEFT_W, 1, -24),
		})
		pad(left, 2, 2, 12, 6)
		listLayout(left, Enum.FillDirection.Vertical, 10)
		H.Left = left
		local list = scroller(content, "Stations", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 12),
			Size = UDim2.new(1, -(K.HOME_LEFT_W + 36), 1, -24),
		})
		pad(list, 2, 2, 14, 8)
		listLayout(list, Enum.FillDirection.Vertical, 8)
		H.List = list

		------------------------------------------------------------------
		-- summary cards
		------------------------------------------------------------------
		local function card(name, order, height)
			local c = makeInset(left, name, {
				Size = UDim2.new(1, 0, 0, height),
				LayoutOrder = order,
			})
			H.Cards[#H.Cards + 1] = c
			return c
		end

		-- house: tier, Home Level, stars, the next house
		local house = card("HouseCard", 1, 132)
		local disc = makeFrame(house, "HouseDisc", {
			Position = UDim2.fromOffset(12, 14),
			Size = UDim2.fromOffset(72, 72),
			BackgroundTransparency = 0,
			BackgroundColor3 = C2.Kind.House,
		})
		round(disc)
		stroke(disc, NAVY, 3, 0)
		Theme.Gradient(disc, Theme.Lighten(C2.Kind.House, 0.35), Theme.Darken(C2.Kind.House, 0.2), 90)
		H.HouseGlyph = makeText(disc, "Glyph", G.House, "Title", 40, WHITE, { Size = UDim2.new(1, 0, 1, 0) })
		H.HouseName = makeText(house, "Tier", "Cottage", "Title", 30, Theme.Lighten(C2.Kind.House, 0.4), {
			Position = UDim2.fromOffset(96, 10),
			Size = UDim2.new(1, -106, 0, 36),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 20, Parent = H.HouseName })
		H.HomeLevel = makeText(house, "HomeLevel", "Home Level 0", "Heading", 21, WHITE, {
			Position = UDim2.fromOffset(96, 46),
			Size = UDim2.new(1, -106, 0, 26),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		H.Stars = makeText(house, "Stars", "", "Heading", 20, GOLD, {
			Position = UDim2.fromOffset(96, 72),
			Size = UDim2.new(1, -106, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		H.NextHouse = makeText(house, "NextHouse", "", "Body", 18, MUTED, {
			Position = UDim2.fromOffset(14, 100),
			Size = UDim2.new(1, -28, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 18, MinTextSize = 16, Parent = H.NextHouse })

		-- income per second
		local income = card("IncomeCard", 2, 104)
		makeText(income, "Caption", "Income", "Heading", 19, MUTED, {
			Position = UDim2.fromOffset(14, 8),
			Size = UDim2.new(1, -28, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		H.Income = makeText(income, "PerSecond", G.Cash .. "0/s", "Display", 36, C2.Cash, {
			Position = UDim2.fromOffset(14, 32),
			Size = UDim2.new(1, -28, 0, 40),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 36, MinTextSize = 22, Parent = H.Income })
		H.IncomeParts = makeText(income, "Parts", "", "Body", 18, MUTED, {
			Position = UDim2.fromOffset(14, 74),
			Size = UDim2.new(1, -28, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 18, MinTextSize = 16, Parent = H.IncomeParts })

		-- the Collector: cash waiting / cap, Collect
		local collector = card("CollectorCard", 3, 146)
		makeText(collector, "Caption", "Collector", "Heading", 19, MUTED, {
			Position = UDim2.fromOffset(14, 8),
			Size = UDim2.new(0.5, -14, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		H.CollectorCap = makeText(collector, "Cap", "", "Heading", 18, MUTED, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -14, 0, 8),
			Size = UDim2.new(0.5, 0, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Right,
		})
		H.CollectorBar = CloudUI.Bar({
			Name = "CollectorBar",
			Position = UDim2.fromOffset(14, 36),
			Size = UDim2.new(1, -28, 0, 32),
			Height = 32,
			TextSize = 22,
			Color = C2.Cash,
			Parent = collector,
		})
		H.CollectButton = CloudUI.Button({
			Name = "Collect",
			Text = "Collect",
			Style = "Green",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 80),
			Size = UDim2.new(1, -28, 0, 52),
			TextSize = 24,
			Callback = function()
				if not P2.hasHome() then
					showHint("Claim a home first: press E at a free gate.", "info")
					return
				end
				fireKeyed("HomeAction:Collect", "HomeAction", "Collect")
			end,
			Parent = collector,
		})

		-- prestige: stars, Home Level progress, the requirement, the reward, the button
		local prestige = card("PrestigeCard", 4, 214)
		H.PrestigeTitle = makeText(prestige, "Caption", "Prestige", "Heading", 19, MUTED, {
			Position = UDim2.fromOffset(14, 8),
			Size = UDim2.new(1, -28, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		H.PrestigeBar = CloudUI.Bar({
			Name = "PrestigeBar",
			Position = UDim2.fromOffset(14, 36),
			Size = UDim2.new(1, -28, 0, 30),
			Height = 30,
			TextSize = 20,
			Color = GOLD,
			Parent = prestige,
		})
		H.PrestigeNeed = makeText(prestige, "Need", "", "Heading", 18, C2.Lock, {
			Position = UDim2.fromOffset(14, 72),
			Size = UDim2.new(1, -28, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 18, MinTextSize = 16, Parent = H.PrestigeNeed })
		H.PrestigeReward = makeText(prestige, "Reward", "", "Body", 18, MUTED, {
			Position = UDim2.fromOffset(14, 98),
			Size = UDim2.new(1, -28, 0, 46),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		H.PrestigeButton = CloudUI.Button({
			Name = "Prestige",
			Text = "Prestige",
			Style = "Gold",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -12),
			Size = UDim2.new(1, -28, 0, 52),
			TextSize = 24,
			Callback = function()
				if H.ShowConfirm then
					H.ShowConfirm(true)
				end
			end,
			Parent = prestige,
		})

		H.GoHome = CloudUI.Button({
			Name = "GoHome",
			Text = G.House .. " Go home",
			Style = "Blue",
			Size = UDim2.new(1, 0, 0, 54),
			TextSize = 24,
			LayoutOrder = 5,
			Callback = function()
				if inMatch() then
					showHint("You cannot go home during a match.", "info")
					return
				end
				if fireKeyed("HomeAction:GoHome", "HomeAction", "GoHome") then
					closeWindow("Home")
				end
			end,
			Parent = left,
		})
		H.Cards[#H.Cards + 1] = H.GoHome

		------------------------------------------------------------------
		-- station rows
		------------------------------------------------------------------
		local function requestUpgrade(row)
			local pad = H.Pads[row.Id]
			if inMatch() then
				showHint("Homes are closed during a match.", "info")
				return
			end
			if not P2.hasHome() then
				showHint("Claim a home first: press E at a free gate.", "info")
				return
			end
			if not pad then
				return
			end
			if pad.Locked then
				showHint(tostring(pad.Locked), "info")
				return
			end
			local price = tonumber(pad.Price) or 0
			local cash = P2.cashBalance()
			if cash < price then
				showHint("You need " .. P2.formatCash(price - cash) .. " more Cash.", "bad")
				return
			end
			if fireKeyed("HomeAction:Upgrade:" .. row.Id, "HomeAction", "Upgrade", row.Id) then
				row.PendingAt = os.clock()
				row.PendingLevel = P2.stationLevelOf(P2.homeData(), row.Id)
				if H.Refresh then
					H.Refresh()
				end
			end
		end

		local function buildRow(def, parent, order)
			local color = C2.Kind[def.Kind] or BUTTONS.Blue
			local row = { Id = def.Id, Def = def, Pips = {} }
			local frame = makeInset(parent, "Station_" .. def.Id, {
				Size = UDim2.new(1, 0, 0, K.STATION_ROW_H),
				LayoutOrder = order,
			})
			row.Frame = frame
			row.Disc = makeFrame(frame, "Icon", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 12, 0.5, 0),
				Size = UDim2.fromOffset(64, 64),
				BackgroundTransparency = 0,
				BackgroundColor3 = color,
			})
			corner(row.Disc, 16)
			stroke(row.Disc, NAVY, 3, 0)
			Theme.Gradient(row.Disc, Theme.Lighten(color, 0.35), Theme.Darken(color, 0.2), 90)
			makeText(row.Disc, "Glyph", tostring(def.Icon or G.House), "Title", 34, WHITE, { Size = UDim2.new(1, 0, 1, 0) })
			row.Name = makeText(frame, "Name", def.Name, "Title", 24, WHITE, {
				Position = UDim2.fromOffset(88, 6),
				Size = UDim2.new(1, -360, 0, 30),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextScaled = true,
			})
			Util.Create("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 18, Parent = row.Name })
			row.Level = makeText(frame, "Level", "Lv 0/" .. tostring(def.MaxLevel), "Heading", 19, MUTED, {
				Position = UDim2.fromOffset(88, 38),
				Size = UDim2.fromOffset(96, 24),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			row.PipRow = makeFrame(frame, "Pips", {
				Position = UDim2.fromOffset(186, 42),
				Size = UDim2.fromOffset(170, 16),
			})
			listLayout(row.PipRow, Enum.FillDirection.Horizontal, 3, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
			for i = 1, math.min(def.MaxLevel or 1, 10) do
				local pip = makeFrame(row.PipRow, "Pip" .. i, {
					Size = UDim2.fromOffset(13, 13),
					BackgroundTransparency = 0,
					BackgroundColor3 = Color3.fromRGB(14, 20, 52),
					LayoutOrder = i,
				})
				corner(pip, 3)
				stroke(pip, NAVY, 1.5, 0)
				row.Pips[i] = pip
			end
			row.Info = makeText(frame, "Info", "", "Body", 18, MUTED, {
				Position = UDim2.fromOffset(88, 64),
				Size = UDim2.new(1, -360, 0, 24),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			})
			-- right block: price + button, a lock reason, or MAX
			row.Right = makeFrame(frame, "Action", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.fromOffset(330, 76),
			})
			row.Price = makeText(row.Right, "Price", "", "Display", 26, C2.Cash, {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 0, 0.5, 0),
				Size = UDim2.fromOffset(150, 32),
				TextXAlignment = Enum.TextXAlignment.Right,
				TextScaled = true,
			})
			Util.Create("UITextSizeConstraint", { MaxTextSize = 26, MinTextSize = 18, Parent = row.Price })
			row.Button = CloudUI.Button({
				Name = "Upgrade",
				Text = "Upgrade",
				Style = "Green",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.fromOffset(164, 54),
				TextSize = 22,
				Callback = function()
					requestUpgrade(row)
				end,
				Parent = row.Right,
			})
			row.Lock = makeText(row.Right, "Locked", "", "Heading", 18, C2.Lock, {
				Size = UDim2.new(1, 0, 1, 0),
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Right,
				Visible = false,
			})
			row.Max = colorPill(row.Right, "Max", "MAX", GOLD, 20, 1)
			row.Max.AnchorPoint = Vector2.new(1, 0.5)
			row.Max.Position = UDim2.new(1, 0, 0.5, 0)
			row.Max.Visible = false
			H.Rows[def.Id] = row
			return row
		end

		local order = 0
		local stations = TycoonCatalog and TycoonCatalog.Stations or {}
		for _, section in ipairs(HOME_SECTIONS) do
			order = order + 1
			local header = makeFrame(list, "Section_" .. section.Id, {
				Size = UDim2.new(1, 0, 0, 34),
				LayoutOrder = order,
			})
			makeText(header, "Title", section.Title, "Title", 24, WHITE, {
				Position = UDim2.fromOffset(6, 0),
				Size = UDim2.new(1, -12, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			H.Sections[#H.Sections + 1] = header
			for _, def in ipairs(stations) do
				if type(def) == "table" and section.Kinds[def.Kind] then
					order = order + 1
					buildRow(def, list, order)
				end
			end
		end
		if not TycoonCatalog then
			H.Missing = makeText(list, "Missing", "Your home is getting ready. Try again in a moment!", "Body", 20, MUTED, {
				Size = UDim2.new(1, 0, 0, 60),
				TextWrapped = true,
				LayoutOrder = 1,
			})
		end

		------------------------------------------------------------------
		-- prestige confirmation (resets stations and Cash)
		------------------------------------------------------------------
		local confirm = makeFrame(content, "PrestigeConfirm", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 0.35,
			BackgroundColor3 = Color3.fromRGB(8, 12, 32),
			Visible = false,
			ZIndex = 30,
		})
		corner(confirm, 14)
		local box = makeFrame(confirm, "Box", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.fromOffset(520, 300),
			BackgroundTransparency = 0,
			BackgroundColor3 = Colors.Panel,
			ZIndex = 31,
		})
		corner(box, 16)
		stroke(box, GOLD, 4, 0)
		Theme.Gradient(box, Colors.PanelLight, Colors.Panel, 90)
		Util.Create("UISizeConstraint", { MaxSize = Vector2.new(520, 300), Parent = box })
		H.ConfirmBox = box
		makeText(box, "Title", G.Star .. " Prestige now?", "Title", 30, GOLD, {
			Position = UDim2.fromOffset(16, 14),
			Size = UDim2.new(1, -32, 0, 38),
			ZIndex = 32,
		})
		H.ConfirmText = makeText(box, "Text", "", "Body", 19, WHITE, {
			Position = UDim2.fromOffset(20, 60),
			Size = UDim2.new(1, -40, 0, 140),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = 32,
		})
		local buttons = makeFrame(box, "Buttons", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -16),
			Size = UDim2.new(1, -32, 0, 56),
			ZIndex = 32,
		})
		listLayout(buttons, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		local yes = CloudUI.Button({
			Name = "ConfirmPrestige",
			Text = "Prestige!",
			Style = "Gold",
			Size = UDim2.fromOffset(200, 54),
			TextSize = 24,
			LayoutOrder = 1,
			Callback = function()
				H.ShowConfirm(false)
				if inMatch() then
					showHint("Finish your match first.", "info")
					return
				end
				fireKeyed("HomeAction:Prestige", "HomeAction", "Prestige")
			end,
			Parent = buttons,
		})
		yes.ZIndex = 33
		local no = CloudUI.Button({
			Name = "CancelPrestige",
			Text = "Not yet",
			Style = "Blue",
			Size = UDim2.fromOffset(170, 54),
			TextSize = 22,
			LayoutOrder = 2,
			Callback = function()
				H.ShowConfirm(false)
			end,
			Parent = buttons,
		})
		no.ZIndex = 33

		function H.ShowConfirm(on)
			if on then
				local home = P2.homeData()
				local ok = P2.catalogCall("CanPrestige", home)
				if not ok then
					showHint("Not ready to prestige yet.", "info")
					return
				end
				local stars = math.floor(tonumber(home.Prestige) or 0)
				local P = TycoonCatalog and TycoonCatalog.Prestige or {}
				local gems = P2.catalogCall("PrestigeGems", stars + 1) or P.GemReward or 0
				local text = "Your Cash and stations start over. Your pets, food and decor stay.\nYou get star " .. (stars + 1)
					.. ": x" .. shortNumber(P.IncomeMultiplier or 1.25) .. " income forever and " .. P2.gemAmount(gems) .. " Gems."
				if stars == 0 then
					text = text .. " The Fusion Machine unlocks!"
				end
				H.ConfirmText.Text = text
			end
			confirm.Visible = on == true
		end

		------------------------------------------------------------------
		-- refresh
		------------------------------------------------------------------
		local function paintRow(row, home, cash)
			local def = row.Def
			local level = P2.stationLevelOf(home, def.Id)
			local maxLevel = def.MaxLevel or 1
			local cap = P2.catalogCall("MaxLevelAt", def.Id, home) or maxLevel
			local pad = H.Pads[def.Id]
			local color = C2.Kind[def.Kind] or BUTTONS.Blue
			if row.PendingAt and (level ~= row.PendingLevel or os.clock() - row.PendingAt > 3) then
				row.PendingAt = nil
			end
			-- name (the House shows its tier)
			if def.Kind == "House" then
				local tier = level >= 1 and P2.catalogCall("HouseTier", level) or nil
				row.Name.Text = "House: " .. ((tier and tier.Name) or "not built")
			end
			row.Level.Text = "Lv " .. level .. "/" .. maxLevel
			row.Level.TextColor3 = level >= maxLevel and GOLD or MUTED
			for i, pip in ipairs(row.Pips) do
				if i <= level then
					pip.BackgroundColor3 = Theme.Lighten(color, 0.25)
				elseif i <= cap then
					pip.BackgroundColor3 = Color3.fromRGB(36, 50, 100)
				else
					pip.BackgroundColor3 = Color3.fromRGB(14, 20, 52)
				end
			end
			-- what it does now -> next
			local now = effectText(def, level)
			local nextText = level < maxLevel and effectText(def, level + 1) or nil
			local info
			if level < 1 then
				info = nextText and ("Build: " .. nextText) or (def.Blurb or "")
			elseif nextText and nextText ~= now and now then
				-- "+10% press Cash -> +20% press Cash" reads as "+10% -> +20% press Cash"
				local a1, aRest = now:match("^(%S+)(%s.+)$")
				local b1, bRest = nextText:match("^(%S+)(%s.+)$")
				if a1 and b1 and aRest == bRest then
					info = a1 .. " -> " .. b1 .. aRest
				else
					info = now .. " -> " .. nextText
				end
			else
				info = now or (def.Blurb or "")
			end
			row.Info.Text = info
			row.Info.TextColor3 = MUTED
			-- right block
			local lock = nil
			if level >= maxLevel then
				row.Max.Visible = true
				row.Button.Visible = false
				row.Price.Visible = false
				row.Lock.Visible = false
				return
			end
			row.Max.Visible = false
			if pad then
				lock = pad.Locked
			else
				lock = treeReason(def, home) or "Not unlocked yet"
			end
			if lock then
				row.Button.Visible = false
				row.Price.Visible = false
				row.Lock.Visible = true
				row.Lock.Text = G.Lock .. " " .. tostring(lock)
				return
			end
			row.Lock.Visible = false
			row.Button.Visible = true
			row.Price.Visible = true
			local price = tonumber(pad.Price) or 0
			row.Price.Text = price > 0 and P2.formatCash(price) or "FREE"
			local short = price > cash
			row.Price.TextColor3 = short and Theme.Lighten(BAD, 0.35) or C2.Cash
			local pending = row.PendingAt ~= nil
			row.Button.Text = pending and "..." or (level < 1 and "Build" or "Upgrade")
			CloudUI.SetStyle(row.Button, level < 1 and "Gold" or "Green")
			CloudUI.SetDisabled(row.Button, short or pending or inMatch() or not P2.hasHome())
		end

		local function paintSummary(home)
			local tierIndex, tier = P2.catalogCall("HouseTierOf", home)
			local houseLevel = P2.stationLevelOf(home, "House")
			local tiers = TycoonCatalog and TycoonCatalog.HouseTiers or {}
			local homeLevel = P2.catalogCall("HomeLevelOf", home) or tonumber(home.Level) or 0
			local stars = math.floor(tonumber(home.Prestige) or 0)
			if houseLevel < 1 then
				H.HouseName.Text = "Empty yard"
			else
				H.HouseName.Text = (type(tier) == "table" and tier.Name) or "Cottage"
			end
			H.HouseGlyph.Text = (type(tier) == "table" and tier.Icon) or G.House
			H.HomeLevel.Text = "Home Level " .. homeLevel
			H.Stars.Text = prestigeStars(stars)
			H.Stars.TextColor3 = stars > 0 and GOLD or MUTED
			local nextTier = tiers[(houseLevel >= 1 and (tierIndex or 1) or 0) + 1]
			if houseLevel < 1 then
				H.NextHouse.Text = "Build your Cottage from the House pad"
			elseif type(nextTier) == "table" then
				H.NextHouse.Text = "Next: " .. tostring(nextTier.Name) .. " at Home Level " .. tostring(nextTier.HomeLevel)
			else
				H.NextHouse.Text = "Your " .. ((type(tier) == "table" and tier.Name) or "house") .. " is complete!"
			end
			-- prestige
			local P = TycoonCatalog and TycoonCatalog.Prestige or {}
			local need = tonumber(P.HomeLevel) or 40
			H.PrestigeTitle.Text = "Prestige  " .. G.Star .. " " .. stars .. "  ->  " .. (stars + 1)
			H.PrestigeBar.SetFraction(need > 0 and math.min(1, homeLevel / need) or 0)
			H.PrestigeBar.SetText("Home Level " .. math.min(homeLevel, need) .. "/" .. need)
			local ok, reason = P2.catalogCall("CanPrestige", home)
			if ok then
				H.PrestigeNeed.Text = G.Check .. " Ready to prestige!"
				H.PrestigeNeed.TextColor3 = Theme.Lighten(GOOD, 0.35)
			else
				H.PrestigeNeed.Text = G.Lock .. " " .. tostring(reason or "Not ready yet")
				H.PrestigeNeed.TextColor3 = C2.Lock
			end
			local gems = P2.catalogCall("PrestigeGems", stars + 1) or P.GemReward or 0
			local reward = "Reward: x" .. shortNumber(P.IncomeMultiplier or 1.25) .. " income forever and " .. commas(gems) .. " Gems"
			if stars < (tonumber(P.FusionUnlock) or 1) then
				reward = "Reward: x" .. shortNumber(P.IncomeMultiplier or 1.25) .. " income forever, " .. commas(gems)
					.. " Gems and the Fusion Machine"
			end
			H.PrestigeReward.Text = reward
			CloudUI.SetDisabled(H.PrestigeButton, not ok or inMatch() or not P2.hasHome())
			CloudUI.SetDisabled(H.GoHome, inMatch())
		end

		function H.Live()
			local home = P2.homeData()
			local cash, cap, income, parts = homeLive(home)
			H.Income.Text = P2.formatRate(income) .. "/s"
			local bits = {}
			if type(parts) == "table" then
				local mult = tonumber(parts.Multiplier) or 1
				local press, garden = tonumber(parts.Press) or 0, tonumber(parts.Garden) or 0
				-- the server's live total wins: split it the way the local numbers split
				if press + garden > 0 and income > 0 then
					local k = income / (press + garden)
					press, garden = press * k, garden * k
				end
				bits[#bits + 1] = "Presses " .. P2.formatRate(press)
				bits[#bits + 1] = "Pets " .. P2.formatRate(garden)
				if mult > 1.0001 then
					bits[#bits + 1] = "x" .. shortNumber(math.floor(mult * 100 + 0.5) / 100)
				end
			end
			H.IncomeParts.Text = table.concat(bits, "  " .. G.Bullet .. "  ")
			cap = math.max(0, tonumber(cap) or 0)
			cash = math.max(0, tonumber(cash) or 0)
			H.CollectorBar.SetFraction(cap > 0 and math.min(1, cash / cap) or 0)
			H.CollectorBar.SetText(P2.formatCash(cash))
			if P2.stationLevelOf(home, "Collector") < 1 then
				H.CollectorCap.Text = "Not built"
			else
				H.CollectorCap.Text = "Max " .. P2.formatCash(cap)
			end
			local full = cap > 0 and cash >= cap
			H.CollectorBar.SetColor(full and GOLD or C2.Cash)
			CloudUI.SetDisabled(H.CollectButton, cash < 1 or not P2.hasHome() or inMatch())
			H.CollectButton.Text = full and "Collect (full!)" or "Collect"
		end

		function H.Refresh()
			local home = P2.homeData()
			local cash = P2.cashBalance()
			H.Pads = {}
			for _, padInfo in ipairs(P2.catalogCall("AvailablePads", home) or {}) do
				if type(padInfo) == "table" and type(padInfo.StationId) == "string" then
					H.Pads[padInfo.StationId] = padInfo
				end
			end
			for _, row in pairs(H.Rows) do
				paintRow(row, home, cash)
			end
			paintSummary(home)
			H.Live()
		end

		-- wide: summary column + list; tall (portrait): one scrolling column, summary first
		function H.Layout(w, _h, narrow, short, tall)
			local leftW = narrow and K.HOME_LEFT_W_NARROW or K.HOME_LEFT_W
			if tall ~= H.Tall then
				H.Tall = tall
				for i, c in ipairs(H.Cards) do
					c.Parent = tall and list or left
					c.LayoutOrder = tall and (i - 100) or i
				end
			end
			left.Visible = not tall
			if tall then
				list.Position = UDim2.new(1, -10, 0, 10)
				list.Size = UDim2.new(1, -20, 1, -20)
			else
				left.Size = UDim2.new(0, leftW, 1, -24)
				list.Position = UDim2.new(1, -12, 0, 12)
				list.Size = UDim2.new(1, -(leftW + 36), 1, -24)
			end
			local rowH = tall and K.STATION_ROW_H_TALL or K.STATION_ROW_H
			for _, row in pairs(H.Rows) do
				row.Frame.Size = UDim2.new(1, 0, 0, rowH)
				if tall then
					row.Disc.AnchorPoint = Vector2.new(0, 0)
					row.Disc.Position = UDim2.fromOffset(10, 10)
					row.Disc.Size = UDim2.fromOffset(56, 56)
					row.Name.Position = UDim2.fromOffset(78, 6)
					row.Name.Size = UDim2.new(1, -88, 0, 30)
					row.Level.Position = UDim2.fromOffset(78, 38)
					row.PipRow.Position = UDim2.fromOffset(176, 42)
					row.Info.Position = UDim2.fromOffset(78, 62)
					row.Info.Size = UDim2.new(1, -88, 0, 24)
					row.Right.AnchorPoint = Vector2.new(1, 1)
					row.Right.Position = UDim2.new(1, -10, 1, -6)
					row.Right.Size = UDim2.new(1, -88, 0, 40)
					row.Button.Size = UDim2.fromOffset(150, 40)
					row.Price.Size = UDim2.new(1, -160, 1, 0)
				else
					row.Disc.AnchorPoint = Vector2.new(0, 0.5)
					row.Disc.Position = UDim2.new(0, 12, 0.5, 0)
					row.Disc.Size = UDim2.fromOffset(64, 64)
					row.Name.Position = UDim2.fromOffset(88, 6)
					row.Name.Size = UDim2.new(1, -(88 + (narrow and 300 or 340)), 0, 30)
					row.Level.Position = UDim2.fromOffset(88, 38)
					row.PipRow.Position = UDim2.fromOffset(186, 42)
					row.Info.Position = UDim2.fromOffset(88, 64)
					row.Info.Size = UDim2.new(1, -(88 + (narrow and 300 or 340)), 0, 24)
					row.Right.AnchorPoint = Vector2.new(1, 0.5)
					row.Right.Position = UDim2.new(1, -12, 0.5, 0)
					row.Right.Size = UDim2.fromOffset(narrow and 290 or 330, 76)
					row.Button.Size = UDim2.fromOffset(narrow and 140 or 164, 54)
					row.Price.Size = UDim2.new(1, -((narrow and 140 or 164) + 12), 0, 32)
				end
			end
			box.Size = UDim2.fromOffset(math.min(520, w - 40), tall and 340 or 300)
		end

		win.Refresh = H.Refresh
		win.OnLayout = function(w, h, narrow, short, tall)
			H.Layout(w, h, narrow, short, tall)
		end
		win.OnOpen = function()
			H.ShowConfirm(false)
			Home.Folder = nil
			for _, conn in ipairs(Home.Conns) do
				conn:Disconnect()
			end
			Home.Conns = {}
			local folder = plotFolder()
			if folder then
				Home.Conns[#Home.Conns + 1] = folder.AttributeChanged:Connect(function(name)
					if name == "CollectorCash" or name == "CollectorCap" or name == "IncomePerSecond" or name == "HomeLevel" or name == "Prestige" then
						refreshHomeLive()
					end
				end)
			end
		end
		win.OnClose = function()
			H.ShowConfirm(false)
			for _, conn in ipairs(Home.Conns) do
				conn:Disconnect()
			end
			Home.Conns = {}
		end
	end

	-- Live numbers of the open Home window (the Collector fills every second): at most every K.LIVE_GAP seconds.
	function refreshHomeLive()
		local win = windows.Home
		local H = win and win.HomeUi
		if not H or not win.Shown then
			return
		end
		local now = os.clock()
		if now - Home.LiveAt < K.LIVE_GAP then
			if not Home.LivePending then
				Home.LivePending = true
				task.delay(K.LIVE_GAP, function()
					Home.LivePending = false
					refreshHomeLive()
				end)
			end
			return
		end
		Home.LiveAt = now
		safe("home live", H.Live)
	end
end

----------------------------------------------------------------------
-- Roulette flow: BuyRoulette -> RouletteResult -> scrolling strip -> reveal card
----------------------------------------------------------------------
local function refreshShopWindow()
	refreshWindow(windows.Shop)
end

-- currency: nil / "Tokens" (the roulette's Cloud Token price) or "Gems" (Config.Gems; the gems-only Secret roulette
-- is always paid in Gems). The server checks the price, the balance and the paid-random-items policy again.
function requestSpin(rouletteId, currency)
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
	if roulette.GemsOnly then
		currency = "Gems"
	end
	if currency == "Gems" then
		local price = gemPriceOf(rouletteId)
		if not price then
			return
		end
		if gemRoulettesState() ~= "Open" then
			showHint("Gem roulettes are not available on this account right now.", "info")
			return
		end
		if P2.gemBalance() < price then
			showHint("You need " .. P2.gemAmount(price) .. " Gems for that roulette.", "bad")
			return
		end
		if not fire("BuyRoulette", rouletteId, "Gems") then
			return
		end
	else
		currency = "Tokens"
		if State.Tokens() < roulette.Price then
			showHint("You need " .. cloudAmount(roulette.Price) .. " for that roulette.", "bad")
			return
		end
		if not fire("BuyRoulette", rouletteId) then
			return
		end
	end
	-- the answer takes a round trip: use it to sculpt this pool first
	Spin.Last = rouletteId
	Spin.LastCurrency = currency
	Warm.Roulette(rouletteId, true)
	Spin.Waiting = true
	Spin.WaitToken = Spin.WaitToken + 1
	local mine = Spin.WaitToken
	refreshShopWindow()
	task.delay(K.WAIT_TIMEOUT, function()
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
		local size = rng:NextInteger(8, 15)
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
		local distance = rng:NextNumber(80, 230)
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
		if cell.Viewport then
			pcall(cell.Viewport.Destroy)
		end
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

-- Reveal card layout: tall (portrait card) when the screen has the height, else a landscape card.
local function revealLayout()
	local factor = screenFactor()
	local area = guiSize()
	local tall = (area.Y - 2 * K.MARGIN) / factor >= K.REVEAL.TallH + K.BUMPS
	if tall then
		return {
			Wide = false,
			W = K.REVEAL.TallW,
			H = K.REVEAL.TallH,
			View = UDim2.new(0.5, 0, 0, 150),
			ViewSize = 260,
			Name = { UDim2.fromOffset(0, 292), UDim2.new(1, 0, 0, 40), Enum.TextXAlignment.Center },
			Meta = { UDim2.fromOffset(0, 338), UDim2.new(1, 0, 0, 30), Enum.HorizontalAlignment.Center },
			Perks = { UDim2.fromOffset(16, 378), UDim2.new(1, -32, 0, 72), Enum.TextXAlignment.Center },
			Buttons = { UDim2.fromOffset(0, 462), UDim2.new(1, 0, 0, 60), Enum.HorizontalAlignment.Center },
		}
	end
	return {
		Wide = true,
		W = K.REVEAL.WideW,
		H = K.REVEAL.WideH,
		View = UDim2.new(0, 170, 0.5, 0),
		ViewSize = 240,
		Name = { UDim2.fromOffset(340, 14), UDim2.new(1, -356, 0, 42), Enum.TextXAlignment.Left },
		Meta = { UDim2.fromOffset(340, 62), UDim2.new(1, -356, 0, 30), Enum.HorizontalAlignment.Left },
		Perks = { UDim2.fromOffset(340, 100), UDim2.new(1, -356, 0, 84), Enum.TextXAlignment.Left },
		Buttons = { UDim2.fromOffset(340, 196), UDim2.new(1, -356, 0, 60), Enum.HorizontalAlignment.Left },
	}
end

local function fitStage(w, h)
	local area = guiSize()
	local factor = screenFactor()
	return Util.Clamp(math.min(factor, (area.X - 2 * K.MARGIN) / w, (area.Y - 2 * K.MARGIN) / h), 0.3, 1.25)
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
	-- what paid this spin (RouletteResult.Currency; a gems-only roulette is always Gems)
	stage.Currency = (result.Currency == "Gems" or (roulette and roulette.GemsOnly)) and "Gems" or "Tokens"
	Spin.Stage = stage
	syncBackBinding()
	closeOdds()
	closeIndex()
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
			stage.StripFit.Scale = fitStage(K.STAGE.W, K.STAGE.H)
		end
		if stage.RevealFit and stage.RevealSize then
			stage.RevealFit.Scale = fitStage(stage.RevealSize[1], stage.RevealSize[2])
		end
	end

	------------------------------------------------------------------
	-- the strip: server-provided list, repaired where it is invalid, with the winner at K.STRIP.Target
	------------------------------------------------------------------
	local pool = {}
	if roulette then
		pool = possiblePetsOf(roulette.Id)
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
	for i = 1, math.max(#raw, K.STRIP.MinCells) do
		local id = raw[i]
		if type(id) ~= "string" or not PetCatalog.Get(id) then
			id = randomPetId()
		end
		strip[i] = id
	end
	local target = K.STRIP.Target
	strip[target] = def.Id
	local cellW = K.STRIP.Cell
	local startX = 0
	local endX = (target - 1) * cellW + cellW / 2 - K.STRIP.W / 2 + rng:NextNumber(-cellW * 0.26, cellW * 0.26)

	local stripHolder = makeFrame(root, "StripHolder", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 6),
		Size = UDim2.fromOffset(K.STAGE.W, K.STAGE.H),
		ZIndex = 2,
	})
	stage.StripFit = Util.Create("UIScale", { Name = "Fit", Scale = fitStage(K.STAGE.W, K.STAGE.H), Parent = stripHolder })
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

	local pointer = makeText(sc, "Pointer", G.Down, "Title", 36, GOLD, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(50, 40),
		ZIndex = 7,
	})
	local clip = makeFrame(sc, "StripClip", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 40),
		Size = UDim2.fromOffset(K.STRIP.W, K.STRIP.H),
		BackgroundTransparency = 0.35,
		BackgroundColor3 = Color3.fromRGB(14, 22, 58),
		ClipsDescendants = true,
		ZIndex = 2,
	})
	corner(clip, 14)
	stroke(clip, WELL_EDGE, 3, 0)
	local band = makeFrame(clip, "Band", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.fromOffset(cellW, K.STRIP.H - 6),
		BackgroundTransparency = 0.88,
		BackgroundColor3 = GOLD,
		ZIndex = 5,
	})
	corner(band, 14)
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
			Size = UDim2.new(0, 110, 1, 0),
			BackgroundTransparency = 0,
			BackgroundColor3 = Color3.fromRGB(14, 22, 58),
			ZIndex = 6,
		})
		Util.Create("UIGradient", { Transparency = sequence, Parent = fade })
	end
	local status = makeText(sc, "Status", "Spinning...", "Heading", 22, MUTED, {
		Position = UDim2.fromOffset(18, 242),
		Size = UDim2.new(1, -170, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	CloudUI.Button({
		Name = "Skip",
		Text = "Skip",
		Style = "Blue",
		Size = UDim2.fromOffset(126, 46),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 240),
		TextSize = 21,
		Callback = function()
			skipSpin()
		end,
		Parent = sc,
	})

	-- cells are created only while they are near the window (one viewport per visible pet). A cell's frame
	-- (rarity colours) appears at once; its pet viewport (PetBuilder Low: small, static, moving fast) is attached
	-- under the per-frame time budget, so a pet that was never sculpted on this client cannot stall the strip.
	local cells = stage.Cells
	local function destroyCell(index)
		local cell = cells[index]
		if cell then
			cells[index] = nil
			if cell.Viewport then
				pcall(cell.Viewport.Destroy)
			end
			cell.Frame:Destroy()
		end
	end
	local function attachViewport(cell)
		if cell.Viewport then
			return
		end
		cell.Viewport = CloudUI.PetViewport(cell.Frame, cell.Def, UDim2.new(1, -8, 1, -24), {
			Position = UDim2.new(0.5, 0, 0, 4),
			AnchorPoint = Vector2.new(0.5, 0),
			Animate = false,
			Spin = "sway",
			Detail = K.STRIP_DETAIL,
			ZIndex = 2,
		})
	end
	local function makeCell(index)
		local cellDef = PetCatalog.Get(strip[index])
		local color = rarityOf(cellDef)
		local frame = makeFrame(clip, "Cell" .. index, {
			Size = UDim2.fromOffset(cellW - 10, K.STRIP.H - 18),
			BackgroundTransparency = 0,
			BackgroundColor3 = WHITE,
			ZIndex = 2,
		})
		corner(frame, 14)
		local frameStroke = stroke(frame, color, 3, 0)
		Theme.Gradient(frame, Colors.Mist, Colors.MistDeep:Lerp(color, 0.5), 90)
		local tag = makeFrame(frame, "RarityBar", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -6),
			Size = UDim2.new(1, -24, 0, 10),
			BackgroundTransparency = 0,
			BackgroundColor3 = color,
		})
		round(tag)
		local cell = { Frame = frame, Viewport = nil, Stroke = frameStroke, Def = cellDef }
		cells[index] = cell
		return cell
	end
	local function layoutCells(x)
		local first = math.max(1, math.floor(x / cellW))
		local last = math.min(#strip, math.floor((x + K.STRIP.W) / cellW) + 2)
		for index = first, last do
			local cell = cells[index] or makeCell(index)
			cell.Frame.Position = UDim2.fromOffset(math.floor((index - 1) * cellW - x + 5 + 0.5), 9)
		end
		for index in pairs(cells) do
			if index < first or index > last then
				destroyCell(index)
			end
		end
		-- pet viewports, nearest to the pointer first, under the frame's build budget
		local budget = Warm.Budget()
		local centre = (x + K.STRIP.W / 2) / cellW + 0.5
		while Warm.Allows(budget) do
			local best, bestD = nil, math.huge
			for index, cell in pairs(cells) do
				if not cell.Viewport then
					local d = math.abs(index - centre)
					if d < bestD then
						best, bestD = cell, d
					end
				end
			end
			if not best then
				break
			end
			attachViewport(best)
			budget.Count = budget.Count + 1
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
			if stage.Currency == "Gems" then
				local price = gemPriceOf(roulette.Id) or 0
				stage.AgainBtn.Text = "Again " .. P2.gemAmount(price)
				CloudUI.SetDisabled(stage.AgainBtn, P2.gemBalance() < price or inMatch() or gemRoulettesState() ~= "Open")
			else
				stage.AgainBtn.Text = "Again " .. cloudAmount(roulette.Price)
				CloudUI.SetDisabled(stage.AgainBtn, State.Tokens() < roulette.Price or inMatch())
			end
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

		local L = revealLayout()
		stage.RevealSize = { L.W, L.H }
		local holder = makeFrame(root, "RevealHolder", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 6),
			Size = UDim2.fromOffset(L.W, L.H),
			ZIndex = 2,
		})
		stage.RevealFit = Util.Create("UIScale", { Name = "Fit", Scale = fitStage(L.W, L.H), Parent = holder })
		local panel = CloudUI.Panel({
			Name = "RevealPanel",
			Title = string.upper(def.Rarity),
			Closable = true,
			Accent = def.Rarity == "Secret" and PURPLE or rarityColor,
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
		local glowColor = def.Rarity == "Secret" and PURPLE or rarityColor

		-- slowly turning rays + soft glow discs behind the pet (stronger for rarer pets), clipped to the card
		local fxLayer = makeFrame(c, "RevealFx", {
			Size = UDim2.new(1, 0, 1, 0),
			ClipsDescendants = true,
			ZIndex = 1,
		})
		local raySize = L.ViewSize + 80
		local rays = makeFrame(fxLayer, "Rays", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = L.View,
			Size = UDim2.fromOffset(raySize, raySize),
			ZIndex = 1,
		})
		stage.Rays = rays
		local rayCount = 3 + order
		for i = 1, rayCount do
			local ray = makeFrame(rays, "Ray" .. i, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				Size = UDim2.new(0, 22, 1, 0),
				Rotation = (i - 1) * 180 / rayCount,
				BackgroundTransparency = 0.78 - order * 0.015,
				BackgroundColor3 = Theme.Lighten(glowColor, 0.4),
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
		for i, disc in ipairs({ { 1.0, 0.86 }, { 0.78, 0.8 }, { 0.58, 0.72 } }) do
			local glow = makeFrame(fxLayer, "Glow" .. i, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = L.View,
				Size = UDim2.fromOffset(L.ViewSize * disc[1], L.ViewSize * disc[1]),
				BackgroundTransparency = disc[2],
				BackgroundColor3 = Theme.Lighten(glowColor, 0.3),
				ZIndex = 1,
			})
			round(glow)
		end

		stage.RevealViewport = CloudUI.PetViewport(c, def, UDim2.fromOffset(L.ViewSize, L.ViewSize), {
			Position = L.View,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Spin = "spin",
			Excited = 1,
			Flap = 1.5,
			ZIndex = 3,
		})

		-- NEW! flag (or the stack size for a duplicate)
		local isNew = result.IsNew == true
		local flag = makeFrame(c, "Flag", {
			Position = UDim2.fromOffset(10, 14),
			Size = UDim2.fromOffset(104, 40),
			Rotation = -10,
			BackgroundTransparency = 0,
			BackgroundColor3 = isNew and GOLD or BUTTONS.Blue,
			ZIndex = 6,
		})
		corner(flag, 10)
		stroke(flag, NAVY, 3, 0)
		local flagText = "NEW!"
		if not isNew then
			flagText = "x" .. tostring(math.floor(tonumber(result.Count) or State.OwnedCount(def.Id)))
		end
		makeText(flag, "Text", flagText, "Accent", 26, WHITE, {
			Size = UDim2.new(1, 0, 1, 0),
			ZIndex = 7,
			TextStrokeColor3 = Theme.Darken(isNew and GOLD or BUTTONS.Blue, 0.65),
		})

		local nameLabel = makeText(c, "Name", def.Name, "Title", 34, rarityText(def), {
			Position = L.Name[1],
			Size = L.Name[2],
			TextXAlignment = L.Name[3],
			TextScaled = true,
			ZIndex = 4,
		})
		Util.Create("UITextSizeConstraint", { MaxTextSize = 34, MinTextSize = 20, Parent = nameLabel })
		local meta = makeFrame(c, "Meta", { Position = L.Meta[1], Size = L.Meta[2], ZIndex = 4 })
		listLayout(meta, Enum.FillDirection.Horizontal, 8, L.Meta[3], Enum.VerticalAlignment.Center)
		local pill = readablePill(def.Rarity, rarityColor, meta)
		pill.LayoutOrder = 1
		for i, element in ipairs(elementsOf(def)) do
			elementPill(meta, element, 18, 1 + i)
		end
		makeText(meta, "Owned", "You own x" .. tostring(math.floor(tonumber(result.Count) or State.OwnedCount(def.Id))), "Heading", 19, MUTED, {
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 26),
			LayoutOrder = 10,
			ZIndex = 4,
		})
		local lines = perkLines(def)
		local perkText = "No perks"
		if #lines > 0 then
			perkText = table.concat(lines, "\n")
		end
		makeText(c, "Perks", perkText, "Heading", 19, Theme.Lighten(GOOD, 0.3), {
			Position = L.Perks[1],
			Size = L.Perks[2],
			TextXAlignment = L.Perks[3],
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = 4,
		})

		local buttons = makeFrame(c, "Buttons", { Position = L.Buttons[1], Size = L.Buttons[2], ZIndex = 4 })
		listLayout(buttons, Enum.FillDirection.Horizontal, 12, L.Buttons[3], Enum.VerticalAlignment.Center)
		stage.EquipBtn = CloudUI.Button({
			Name = "Equip",
			Text = "Equip",
			Style = "Green",
			Size = UDim2.fromOffset(172, 58),
			TextSize = 26,
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
				Size = UDim2.fromOffset(204, 58),
				TextSize = 22,
				LayoutOrder = 2,
				Callback = function()
					local rouletteId = roulette.Id
					local currency = stage.Currency
					closeStage()
					task.defer(requestSpin, rouletteId, currency)
				end,
				Parent = buttons,
			})
		end
		updateReveal()

		-- confetti: more for rarer pets
		local amounts = { 10, 14, 20, 28, 36, 46, 56 }
		local amount = amounts[Util.Clamp(order, 1, #amounts)]
		task.delay(0.2, function()
			if Spin.Stage == stage and stage.Phase == "reveal" then
				burst(c, glowColor, amount, L.View)
			end
		end)
		if order >= 5 then
			task.delay(0.65, function()
				if Spin.Stage == stage and stage.Phase == "reveal" then
					burst(c, glowColor, amount, L.View)
				end
			end)
		end
	end

	------------------------------------------------------------------
	-- animation loop (client-only UI motion)
	------------------------------------------------------------------
	local function land()
		stage.Phase = "land"
		stage.LandedAt = os.clock()
		local winner = cells[target]
		if winner then
			attachViewport(winner) -- (normally attached long before it lands)
			winner.Stroke.Color = GOLD
			winner.Stroke.Thickness = 5
			winner.Frame.ZIndex = 4
			local grow = Util.Create("UIScale", { Scale = 1, Parent = winner.Frame })
			tween(grow, 0.35, { Scale = 1.1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			if winner.Viewport then
				winner.Viewport.SetAnimated(true)
				winner.Viewport.SetExcited(1)
			end
		end
		status.Text = def.Rarity .. "!"
		status.TextColor3 = rarityText(def)
		band.BackgroundTransparency = 0.7
		pointer.Rotation = 0
	end

	local function step(dt)
		if stage.Phase == "spin" then
			if stage.Skip then
				stage.Elapsed = K.STRIP.Seconds
			end
			stage.Elapsed = stage.Elapsed + dt
			local t = Util.Clamp(stage.Elapsed / K.STRIP.Seconds, 0, 1)
			local p = 1 - (1 - t) ^ K.STRIP.Curve
			stage.X = startX + (endX - startX) * p
			layoutCells(stage.X)
			local tick = math.floor((stage.X + K.STRIP.W / 2) / cellW)
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
-- OpenPanel(panelId, args): the server opens windows (roulette / item shop prompts, the tutorial).
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
	elseif key == "pets" or key == "feed" then
		openWindow("Inventory", { Tab = "Pets", Action = (key == "feed") and "Feed" or args.Action, Key = args.Key })
	elseif key == "home" or key == "spot" then
		if inMatch() then
			return
		end
		if P2.hasHome() then
			openWindow("Home", args)
		else
			menuActionSpot()
		end
	elseif key == "index" then
		local groupId = args.GroupId or args.Group or args.Rarity
		openIndex(type(groupId) == "string" and groupId or nil)
	elseif key == "stats" then
		openWindow("Stats", args)
	elseif key == "close" then
		closeEverything()
	end
end

local function onStateChanged()
	-- red dot on the Pets tile when the collection grew while the inventory was closed
	local _, total = petTotals()
	local inventory = windows.Inventory
	if Badge.LastPetTotal ~= nil and total > Badge.LastPetTotal and not (inventory and inventory.Shown) then
		if Entries.Pets then
			Entries.Pets.SetBadge(true)
		end
	end
	Badge.LastPetTotal = total
	refreshIndexBadge()

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

-- the claimed plot changed (claimed / released): the Home window follows, or closes when the home is gone
local function onSpotChanged()
	Home.Folder = nil
	local win = windows.Home
	if win and win.Shown then
		if P2.hasHome() then
			if win.OnOpen then
				safe("home rebind", win.OnOpen, {})
			end
			refreshWindow(win)
		else
			closeWindow("Home")
		end
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

-- The Pet Index lives in IndexController: keep one window at a time, light the Index tile and relay
-- its opening as WindowOpened("Index").
local function connectIndex()
	local index = getIndex()
	if not index then
		return
	end
	if type(index.Opened) == "table" and type(index.Opened.Connect) == "function" then
		index.Opened:Connect(function()
			if openId then
				closeWindow(openId, true)
			end
			hideBackdropNow()
			closeOdds()
			updateMenuActive()
			MenuController.WindowOpened:Fire("Index")
		end)
	end
	if type(index.Closed) == "table" and type(index.Closed.Connect) == "function" then
		index.Closed:Connect(function()
			updateMenuActive()
		end)
	end
	refreshIndexBadge()
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

function MenuController.GetButton(id)
	if id == "Home" then
		id = "Spot" -- the Home tile keeps the v3 id
	end
	local entry = Entries[id]
	return entry and entry.Button or nil
end

-- Opens Pets with the Feed picker of that pet copy (key; nil = the selected / first pet).
function MenuController.OpenFeed(key)
	if initialized then
		onOpenPanel("Pets", { Action = "Feed", Key = key })
	end
end

-- true while a window, the odds popup or the roulette stage covers the screen (the tutorial folds its card and
-- hides its menu pointer meanwhile)
function MenuController.IsOpen()
	return openId ~= nil or Odds.Gui ~= nil or Spin.Stage ~= nil
end

-- Debug helper (smoke tests): true once `petId` was pre-sculpted at the roulette strip's detail.
function MenuController.IsPrewarmed(petId)
	return Warm.Done[petId] == true
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

	-- click-outside layer behind the windows (the menu column stays above it)
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
	createWindow({ Id = "Inventory", Title = "Inventory", Accent = BUTTONS.Blue, Build = buildInventory, Tall = true })
	createWindow({ Id = "Shop", Title = "Cloud Shop", Accent = BUTTONS.Gold, Build = buildShop, Tall = true })
	createWindow({ Id = "Stats", Title = "Stats", Accent = PURPLE, Build = buildStats, Tall = true })
	createWindow({ Id = "Home", Title = G.House .. " My Home", Accent = BUTTONS.Green, Build = buildHome, Tall = true })
	relayoutMenu()
	updateMenuActive()

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		safe("relayout", relayoutMenu)
	end)
	State.Changed:Connect(function()
		safe("State.Changed", onStateChanged)
	end)
	LocalPlayer:GetAttributeChangedSignal(Config.Attr.Tokens):Connect(function()
		safe("Tokens", onTokensChanged)
	end)
	LocalPlayer:GetAttributeChangedSignal(Config.Attr.InMatch):Connect(function()
		safe("InMatch", onMatchFlagChanged)
	end)
	-- Phase 2: Cash / Gems balances (prices turn red / green), the gem roulette policy, the claimed plot
	for _, signalName in ipairs({ "CashChanged", "GemsChanged" }) do
		local signal = State[signalName]
		if type(signal) == "table" and type(signal.Connect) == "function" then
			signal:Connect(function()
				safe(signalName, onTokensChanged)
			end)
		end
	end
	LocalPlayer:GetAttributeChangedSignal(K.RESTRICTED_ATTR):Connect(function()
		safe("policy", refreshShopWindow)
	end)
	LocalPlayer:GetAttributeChangedSignal(Config.Attr.SpotIndex):Connect(function()
		safe("SpotIndex", onSpotChanged)
	end)
	UserInputService.InputBegan:Connect(function(input)
		safe("input", onInput, input)
	end)

	-- remember the collection size so only later growth shows the "new pet" dot
	local _, total = petTotals()
	if State.IsLoaded and State.IsLoaded() then
		Badge.LastPetTotal = total
	end

	safe("connect index", connectIndex)
	task.spawn(connectRemotes)
end

return MenuController
