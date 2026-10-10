-- HudController: the Nimbus Climb heads-up display (v3).
--
--   HudController.Init()
--   HudController.GetLayout() -> { TopLeftRight, TopLeftBottom, TopRightBottom, BottomLeftTop, Scale, CurrencyMode }
--
-- One ScreenGui "NimbusHud" (display order 10, IgnoreGuiInset = false, built by CloudUI.NewScreenGui).
-- Nothing the game announces is ever drawn in the middle of the screen. The layout map:
--
--   top-left      Match panel (difficulty, timer, checkpoint bar, team chips, Leave button) with the
--                 pre-match countdown numerals shown INSIDE it; the lobby Party panel takes the same
--                 slot (portal name + a big red Leave button, the only way out of a locked portal; the
--                 countdown; the members; "Locked until launch" + the head count); the small title card
--                 slides in there at join and leaves after four seconds
--   bottom-left   Currency stack (Cloud Tokens now: cloud coin + big abbreviated number, "+n" while in a
--                 match; Cash and Gems rows appear by themselves once those player attributes exist),
--                 above the vitals card: heart badge + thick HP tube (white damage trail, hit flash + shake,
--                 low-health pulse, DOWNED state), lightning badge + stamina tube (dims when run dry) and
--                 the dash ring (cooldown sweep). Raised on touch devices to clear the thumbstick; short
--                 touch screens get a compact card (VG.Compact) so it never sits on the hotbar.
--   top-right     The currency stack moves here on short screens (landscape phones) where there is no
--                 room above the raised vitals; the toast stack (NotifyController) then starts below it.
--
-- Sizes follow the v3 readability rule: every panel is designed in 1080p pixels (body text >= 18, numbers
-- 30+, titles 26-34) and carries a UIScale of Theme.ScreenFactor() = clamp(viewportY / 1080, 0.8, 1.25), so
-- the smallest text is 14.4 px on a phone. The UIScale sits on the panel, the margins on full-screen holder
-- frames, so scaling never moves a panel away from its corner.
--
-- Neighbours are MEASURED, not guessed: the menu column (NimbusMenu.MenuColumn, left-centre, drawn above us)
-- and the touch RUN / DASH buttons (MobileControls). Whatever of ours would run into the column steps aside
-- to its right; the vitals and the currency stack never reach under the touch buttons. The geometry is
-- re-checked twice a second and on every viewport change, and published as attributes on the NimbusHud
-- gui (TopLeftRight, TopLeftBottom, TopRightBottom, BottomLeftTop, HudScale; gui-area pixels) so the
-- toasts and side panels can keep clear of the HUD.
--
-- Data: Humanoid health, player attributes (CloudTokens, MatchTokens, InMatch, Downed, Stamina, Cash, Gems)
-- and the MatchState / PartyState remotes. Everything is nil-safe: no humanoid, no match, no party, a
-- missing menu and a missing MovementController all leave the HUD in a sensible idle state.
-- Plain Lua 5.1-compatible syntax only. All fonts come from Theme roles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent.Parent
local CloudUI = require(Client:WaitForChild("UI"):WaitForChild("CloudUI"))
local okState, State = pcall(function()
	return require(Client:WaitForChild("State"))
end)
if not okState or type(State) ~= "table" then
	State = nil
end

local HudController = {}

----------------------------------------------------------------------
-- Tunables (design pixels of a 1080p screen unless noted)
----------------------------------------------------------------------
-- K: layout + timing constants (one table keeps the module well under Lua's 200-locals limit)
local K = {
	EDGE = 12, -- margin to the screen edge
	TOUCH_EDGE = 20, -- larger side margin on touch devices (notches, rounded corners)
	TOUCH_RAISE_SMALL = 150, -- gui px the vitals are lifted on phones (thumbstick room)
	TOUCH_RAISE_LARGE = 220, -- ... and on tablets
	TOUCH_RAISE_MIN = 64, -- short landscape phones lift less so the top-left panel still fits above
	SMALL_PHONE = 500, -- Roblox's own touch controls shrink when the smaller screen side is at most this

	VITALS_W = 340,
	VITALS_H = 93, -- the vitals card (see VG below for its inside)
	VITALS_MIN_W = 236, -- narrowest the vitals get squeezed on a small phone
	STACK_GAP = 10, -- between the vitals and the currency stack (scaled)

	CUR_W = 240, -- one currency pill
	CUR_H = 46,
	CUR_GAP = 10,
	CUR_MIN_W = 190,
	CUR_PAIR_MIN_W = 236, -- two compact pills side by side need this much
	COIN = 54, -- the round coin badge overlapping the pill's left end
	CHIP_W = 76, -- the "+n" match chip on the token pill
	COIN_COMPACT = 42, -- coin of a compact (paired) pill

	PANEL_W = 330, -- match + party panels
	PANEL_MIN_W = 272, -- ... squeezed this far on short screens (keeps their text out of the screen middle)
	CENTRE_TOL = 0.145, -- the screen middle: |dx| < 14.5% of the width and |dy| < 14.5% of the height
	TITLE_W = 300,
	TITLE_H = 78,

	-- Menu column fallback (only while MenuController's column cannot be measured): 6 tiles of the v3 menu.
	MENU_FALLBACK_W = 76,
	MENU_FALLBACK_ENTRY = 82,
	MENU_FALLBACK_GAP = 6,
	MENU_FALLBACK_COUNT = 6,
	MENU_CLEARANCE = 8, -- empty strip kept between the column and whatever steps aside for it
	SPAN_MARGIN = 4, -- two vertical spans closer than this count as touching
	BUTTON_CLEARANCE = 8, -- kept between our blocks and the touch RUN / DASH buttons

	LOW_HEALTH = 0.3, -- below this the heart beats and the card pulses red
	TRAIL_HOLD = 0.45, -- seconds the white damage trail waits before it catches up
	TRAIL_SPEED = 0.6, -- ... then drains this much of the bar per second
	HIT_SECONDS = 0.32, -- damage flash + card shake
	SHAKE_PX = 5,
	STAMINA_RECOVER = 15, -- after running dry the stamina row stays dimmed up to this (MovementController's resume point)
	TITLE_CARD_SECONDS = 4,
	LEAVE_CONFIRM_SECONDS = 3,
	GO_SECONDS = 1.0, -- how long "GO!" replaces the timer
	LAYOUT_POLL = 0.5, -- seconds between two geometry checks
}

-- VG: geometry of the vitals card in design px (1080p), width 236-340 (the bars stretch with it; the badges
-- and the dash ring keep their size). H = the layout slot, CARD_H = the card drawn in it (from the top).
-- Left column: the heart badge over the lightning badge, both overlapping the card's left edge like the coins
-- of the currency pills above (same column). Regular: the dash ring ends the stamina row. Compact (short touch
-- screens, landscape phones, where the slot sits right on the hotbar): a flatter card that leaves a gap at the
-- bottom of its slot, with a bigger dash ring at the right end spanning both rows.
local VG = {
	Regular = {
		H = K.VITALS_H, CARD_H = K.VITALS_H, CARD_X = 20, CARD_CORNER = 22,
		BADGE_X = 28, HEART = 52, HEART_Y = 26, HEART_TEXT = 34, BOLT = 36, BOLT_Y = 72,
		HP_X = 46, HP_Y = 8, HP_H = 36, HP_TEXT = 26, PAD_R = 10,
		ST_X = 40, ST_Y = 61, ST_H = 22,
		RING = 40, RING_Y = 71, RING_GAP = 8, RING_FACE = 22, RING_TEXT = 20, RING_SPAN = false,
	},
	Compact = {
		H = 80, CARD_H = 70, CARD_X = 18, CARD_CORNER = 20,
		BADGE_X = 24, HEART = 44, HEART_Y = 22, HEART_TEXT = 30, BOLT = 28, BOLT_Y = 54,
		HP_X = 40, HP_Y = 7, HP_H = 30, HP_TEXT = 23, PAD_R = 9,
		ST_X = 34, ST_Y = 45, ST_H = 18,
		RING = 46, RING_Y = 35, RING_GAP = 8, RING_FACE = 30, RING_TEXT = 22, RING_SPAN = true,
	},
	COMPACT_SPARE = 10, -- use Compact when Regular leaves less than this above the minimum touch raise
}

local Colors = Theme.Colors
local WHITE = Colors.White
local NAVY = Colors.Navy or Colors.Ink
local MUTED = Colors.Muted or Colors.CloudShade
local GOLD = Colors.Gold or Colors.Token
local INK = Colors.TextStroke or Colors.Ink
local HEART_RED = Color3.fromRGB(232, 84, 104)
-- VS: the vitals card's colours and the dash ring's sweep sequences
local VS = {
	BoltBlue = Color3.fromRGB(70, 156, 236),
	Edge = Theme.Darken(NAVY, 0.3), -- outline of the tubes and the dash ring
	TrackTop = Color3.fromRGB(12, 16, 40), -- the dark inset track of the tubes and the ring
	TrackBottom = Color3.fromRGB(40, 52, 104),
	Grey = Color3.fromRGB(128, 140, 168), -- a drained badge / a dash you cannot afford
	Arc = Color3.fromRGB(128, 214, 255), -- the bright cooldown sweep
	-- a hard step in the middle of each half-disc's gradient (partial sweep), or no step at all (full ring)
	Step = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.499, 0),
		NumberSequenceKeypoint.new(0.501, 1),
		NumberSequenceKeypoint.new(1, 1),
	}),
	Solid = NumberSequence.new(0),
}
local Vitals = {} -- builders and painters of the vitals card (one table keeps the chunk's locals down)
local CUR = Theme.Currency or {}

-- Currency rows, top to bottom. Tokens is always shown (and sits right above the HP bar); the others appear
-- once their player attribute exists (phase 2 sets them).
local CURRENCY_ORDER = {
	{ Id = "Cash", Attr = Config.Attr.Cash, Def = CUR.Cash },
	{ Id = "Gems", Attr = Config.Attr.Gems, Def = CUR.Gems },
	{ Id = "Tokens", Attr = Config.Attr.Tokens, Def = CUR.Tokens, Always = true, Run = true },
}

----------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------
local player = nil
local initialized = false
local startedAt = 0
local connections = {}
local warned = {}
local remoteCache = {}
local scalers = {} -- UIScale objects driven by the screen factor
local pads = {} -- UIPadding objects of the corner holders
local padTweens = {} -- running PaddingLeft tween per holder
local padGoals = {} -- last PaddingLeft requested per holder
local M = nil -- layout metrics of the match / party panels, see panelMetrics()
local movementModule = nil
local movementNextTry = 0
local layoutKey = nil
local layoutPoll = 0
local published = {} -- the geometry attributes on the gui

local UI = {} -- instance references
local Items = {} -- sliding panels, see present()
local Cur = {} -- currency rows by id: { Def, Attr, Row, Amount, AmountScale, CoinScale, Target, Display, Shown, Seen, Visible }

local S = {
	match = nil, party = nil, downed = false, currencyMode = "BottomLeft", panelW = K.PANEL_W,
	yieldToResult = false, -- a narrow screen with the result card open: the match panel steps away
}
local H = { -- health
	Char = nil, Humanoid = nil, Conns = {},
	Cur = 100, Max = 100, Target = 1, Fill = 1, Trail = 1,
	HoldUntil = 0, ColorKey = nil, Text = nil, Low = false,
	HitAt = -10, HitFx = false, -- last damage (flash + shake running while HitFx)
}
-- stamina + dash ring: Dim 0 = bright .. 1 = empty (eased), Charge = drawn cooldown sweep 0..1
local St = { Frac = 1, Dim = 0, DimDrawn = -1, Drained = false, Charge = -1, Ready = nil, Afford = nil }
local Tk = { RunSeen = 0 } -- the "+n" match chip
local Mt = { -- match panel bookkeeping
	Base = 0, At = 0, Phase = nil, Last = nil, GoUntil = 0, Rows = 1, Chips = {}, Count = 0,
}
local Pt = { -- party panel bookkeeping (Fit*: what the text sizes were last fitted for)
	Base = nil, At = 0, Rows = 1, Chips = {}, Count = 0, LastText = nil, LeaveLockUntil = 0,
	HintLong = "Locked until launch", HintShort = "Locked in", FitW = nil, FitTitle = nil, FitStatus = nil, FitHint = nil,
}
local LM = { ArmedUntil = 0, LockedUntil = 0 } -- leave-match confirmation
local TC = { Serial = 0, Shown = false } -- title card

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local tween = Util.Tween

local function track(conn)
	if conn then
		table.insert(connections, conn)
	end
	return conn
end

local function warnOnce(key, err)
	if not warned[key] then
		warned[key] = true
		warn("[HudController] " .. tostring(key) .. ": " .. tostring(err))
	end
end

-- pcall wrapper that reports each distinct failure once instead of spamming every frame.
local function guard(key, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warnOnce(key, err)
	end
	return ok
end

local function isTouchDevice()
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function viewportSize()
	local camera = workspace.CurrentCamera
	local vp = camera and camera.ViewportSize or Vector2.new(1920, 1080)
	if vp.X < 2 or vp.Y < 2 then
		return Vector2.new(1920, 1080)
	end
	return vp
end

-- The readability factor: clamp(viewportY / 1080, 0.8, 1.25).
local function currentScale()
	return Theme.ScreenFactor(viewportSize().Y)
end

local function topInset()
	local inset = 0
	pcall(function()
		inset = GuiService:GetGuiInset().Y
	end)
	return inset
end

local function hex(color)
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

local function fireRemote(name)
	local remote = remoteCache[name]
	if not remote then
		local ok, found = pcall(Remotes.Get, name)
		if ok and found then
			remote = found
			remoteCache[name] = found
		end
	end
	if remote then
		remote:FireServer()
	end
end

local function stars(count)
	return string.rep("\226\152\133", math.max(0, math.min(5, math.floor(tonumber(count) or 0))))
end

----------------------------------------------------------------------
-- UI builders
----------------------------------------------------------------------
local function newFrame(parent, name, props)
	local p = { Name = name, BackgroundTransparency = 1, BorderSizePixel = 0 }
	if props then
		for key, value in pairs(props) do
			p[key] = value
		end
	end
	p.Parent = parent
	return Util.Create("Frame", p)
end

-- Themed TextLabel. props may include Stroke (classic text stroke transparency) and Outline (thickness of a
-- glyph outline, Theme.TextOutline) plus any label property.
local function newText(parent, name, text, role, size, color, props)
	local extra = {
		Name = name,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}
	local stroke = 0.3
	local strokeColor = nil
	local outline = nil
	local outlineColor = nil
	if props then
		for key, value in pairs(props) do
			if key == "Stroke" then
				stroke = value
			elseif key == "StrokeColor" then
				strokeColor = value
			elseif key == "Outline" then
				outline = value
			elseif key == "OutlineColor" then
				outlineColor = value
			else
				extra[key] = value
			end
		end
	end
	local label = Theme.Label(text, role, {
		Size = size,
		Color = color,
		Stroke = stroke,
		StrokeColor = strokeColor,
		Outline = outline,
		OutlineColor = outlineColor or INK,
		Props = extra,
	})
	label.Parent = parent
	return label
end

local function round(inst)
	return Theme.Corner(inst, UDim.new(0.5, 0))
end

local function newScale(parent, value)
	local s = Instance.new("UIScale")
	s.Scale = value or 1
	s.Parent = parent
	return s
end

-- A UIScale driven by the screen factor (grows around the object's anchor point).
local function addViewportScale(root)
	local s = newScale(root, currentScale())
	s.Name = "ViewportScale"
	table.insert(scalers, s)
	return s
end

-- Springy "pop": jump a UIScale to `peak`, then ease back to 1.
local function pop(scaleObj, peak, seconds)
	if not scaleObj then
		return
	end
	scaleObj.Scale = peak
	tween(scaleObj, seconds or 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end

-- Face of a glossy round badge: a light top, the base colour, then a hard darker lip at the bottom.
local function badgeSequence(color, glow)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, glow),
		ColorSequenceKeypoint.new(0.55, color),
		ColorSequenceKeypoint.new(0.8, Theme.Darken(color, 0.08)),
		ColorSequenceKeypoint.new(0.82, Theme.Darken(color, 0.28)),
		ColorSequenceKeypoint.new(1, Theme.Darken(color, 0.32)),
	})
end

-- Glossy round badge (navy outline, soft shine). Returns the badge, its UIGradient and its UIStroke.
local function newBadge(parent, name, size, color, glow)
	local badge = newFrame(parent, name, {
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 0,
		BackgroundColor3 = WHITE,
	})
	round(badge)
	local stroke = Theme.Stroke(badge, NAVY, 3, 0)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = badgeSequence(color, glow)
	g.Parent = badge
	local shine = newFrame(badge, "Shine", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.1, 0),
		Size = UDim2.new(0.56, 0, 0.24, 0),
		BackgroundTransparency = 0.6,
		BackgroundColor3 = WHITE,
	})
	round(shine)
	return badge, g, stroke
end

-- Glossy coin badge: newBadge plus a glyph.
local function newCoin(parent, name, size, color, glow, glyph, glyphSize)
	local coin = newBadge(parent, name, size, color, glow)
	newText(coin, "Glyph", glyph, "Display", glyphSize, WHITE, {
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.new(0, 0, 0, -1),
		Stroke = 0.2,
		StrokeColor = Theme.Darken(color, 0.6),
		Outline = 2,
		OutlineColor = Theme.Darken(color, 0.6),
		ZIndex = 2,
	})
	return coin
end

-- Slide a panel in/out between item.Rest and item.Hidden (both UDim2).
local function present(item, show)
	if not item or not item.Root or item.Shown == show then
		return
	end
	item.Shown = show
	local root = item.Root
	if show then
		root.Position = item.Hidden
		root.Visible = true
		tween(root, 0.4, { Position = item.Rest }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	else
		tween(root, 0.22, { Position = item.Hidden }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.28, function()
			if not item.Shown and root.Parent then
				root.Visible = false
			end
		end)
	end
end

local function newItem(root, hidden)
	root.Visible = false
	return { Root = root, Shown = false, Rest = root.Position, Hidden = hidden }
end

-- A transparent full-screen frame whose UIPadding is the screen margin of one corner.
local function newHolder(gui, name)
	local holder = newFrame(gui, name, { Size = UDim2.fromScale(1, 1) })
	local pad = Instance.new("UIPadding")
	pad.Parent = holder
	pads[name] = pad
	return holder
end

-- The area GUIs with IgnoreGuiInset = false are laid out in (below the top bar).
local function guiAreaSize()
	local size = UI.Gui and UI.Gui.AbsoluteSize
	if size and size.X >= 2 and size.Y >= 2 then
		return size
	end
	local vp = viewportSize()
	return Vector2.new(vp.X, math.max(2, vp.Y - topInset()))
end

----------------------------------------------------------------------
-- Neighbour geometry (measured)
----------------------------------------------------------------------
local function playerGui()
	return player and player:FindFirstChildOfClass("PlayerGui")
end

-- y offset that converts a gui's AbsolutePosition into our gui-area coordinates
local function insetShift(gui)
	if gui and gui:IsA("ScreenGui") and gui.IgnoreGuiInset then
		return -topInset()
	end
	return 0
end

local function rectOf(inst, dy)
	local p, s = inst.AbsolutePosition, inst.AbsoluteSize
	return { x0 = p.X, y0 = p.Y + dy, x1 = p.X + s.X, y1 = p.Y + s.Y + dy }
end

local function shownIn(inst, root)
	local node = inst
	while node and node ~= root do
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		node = node.Parent
	end
	return true
end

-- MenuController's left-centre column in our coordinates (nil when there is none to avoid).
local function menuRect(area)
	local pg = playerGui()
	local menuGui = pg and pg:FindFirstChild("NimbusMenu")
	if menuGui and menuGui:IsA("ScreenGui") then
		if not menuGui.Enabled then
			return nil
		end
		local dy = insetShift(menuGui)
		local column = menuGui:FindFirstChild("MenuColumn") or menuGui:FindFirstChild("MenuColumn", true)
		if column and column:IsA("GuiObject") and shownIn(column, menuGui) and column.AbsoluteSize.X > 0 then
			return rectOf(column, dy)
		end
		-- no column frame: the union of the menu buttons
		local box = nil
		for _, d in ipairs(menuGui:GetDescendants()) do
			if d:IsA("GuiObject") and string.sub(d.Name, 1, 11) == "MenuButton_" and d.AbsoluteSize.X > 0 and shownIn(d, menuGui) then
				local r = rectOf(d, dy)
				if box then
					box.x0, box.y0 = math.min(box.x0, r.x0), math.min(box.y0, r.y0)
					box.x1, box.y1 = math.max(box.x1, r.x1), math.max(box.y1, r.y1)
				else
					box = r
				end
			end
		end
		if box then
			return box
		end
	end
	-- not built yet: a generous estimate of the v3 column (vertically centred against the left edge)
	local s = Util.Clamp(math.min(area.X / 1280, area.Y / 720), 0.72, 1.2)
	local height = (K.MENU_FALLBACK_COUNT * K.MENU_FALLBACK_ENTRY + (K.MENU_FALLBACK_COUNT - 1) * K.MENU_FALLBACK_GAP) * s
	return { x0 = 0, y0 = (area.Y - height) / 2, x1 = (K.MENU_FALLBACK_W + K.MENU_FALLBACK_GAP) * s, y1 = (area.Y + height) / 2 }
end

-- The touch RUN / DASH buttons (MovementController) in our coordinates.
local function mobileRects()
	local out = {}
	local pg = playerGui()
	local mobile = pg and pg:FindFirstChild("MobileControls")
	if not (mobile and mobile:IsA("ScreenGui") and mobile.Enabled) then
		return out
	end
	local dy = insetShift(mobile)
	for _, d in ipairs(mobile:GetDescendants()) do
		if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.AbsoluteSize.X > 0 and shownIn(d, mobile) then
			table.insert(out, rectOf(d, dy))
		end
	end
	return out
end

local function rectKey(r)
	if not r then
		return "-"
	end
	return string.format("%d,%d,%d,%d", math.floor(r.x0), math.floor(r.y0), math.floor(r.x1), math.floor(r.y1))
end

----------------------------------------------------------------------
-- Layout
----------------------------------------------------------------------
-- What currently occupies the top-left slot: a match / party panel, the title card, and the design height
-- (0 while nothing does).
local function topLeftState()
	local hasPanel, hasTitle, h = false, false, 0
	if Items.Match and Items.Match.Shown and UI.Match then
		hasPanel = true
		h = math.max(h, UI.Match.Root.Size.Y.Offset)
	end
	if Items.Party and Items.Party.Shown and UI.Party then
		hasPanel = true
		h = math.max(h, UI.Party.Root.Size.Y.Offset)
	end
	if Items.Title and Items.Title.Shown then
		hasTitle = true
		h = math.max(h, K.TITLE_H)
	end
	return hasPanel, hasTitle, h
end

-- The currencies shown right now, top to bottom. In a match only Cloud Tokens count (and the stack stays
-- small next to the match panel); in the lobby every currency the player has.
local function visibleCurrencies()
	local list = {}
	local inMatch = S.match ~= nil or (player and player:GetAttribute(Config.Attr.InMatch) == true)
	for _, entry in ipairs(CURRENCY_ORDER) do
		local c = Cur[entry.Id]
		if c and c.Available and (c.Always or not inMatch) then
			table.insert(list, c)
		end
	end
	return list
end

-- Rows of a currency stack style: "Column" = one pill per row, "Pairs" = two compact pills per row (a last
-- single pill gets the full width).
local function stackRows(count, style)
	if style == "Pairs" then
		return math.ceil(count / 2)
	end
	return count
end

local function stackHeight(count, style)
	local rows = math.max(1, stackRows(count, style))
	return rows * K.CUR_H + (rows - 1) * K.CUR_GAP
end

-- Sets one corner holder's margins. The left margin eases to its new value when `animate` is set (a panel that
-- is showing grows a row and must not hop sideways); everything else snaps.
local function setPadding(name, left, top, right, bottom, animate)
	local pad = pads[name]
	if not pad then
		return
	end
	pad.PaddingTop = UDim.new(0, top)
	pad.PaddingRight = UDim.new(0, right)
	pad.PaddingBottom = UDim.new(0, bottom)
	if padGoals[name] == left then
		return -- already there, or already easing there
	end
	padGoals[name] = left
	local running = padTweens[name]
	if running then
		running:Cancel()
		padTweens[name] = nil
	end
	local goal = UDim.new(0, left)
	if animate and math.abs(pad.PaddingLeft.Offset - left) > 0.5 then
		padTweens[name] = tween(pad, 0.25, { PaddingLeft = goal })
	else
		pad.PaddingLeft = goal
	end
end

local function publish(name, value)
	value = math.floor((tonumber(value) or 0) + 0.5)
	if published[name] ~= value and UI.Gui then
		published[name] = value
		UI.Gui:SetAttribute(name, value)
	end
end

local layoutCurrencyRows -- (style, width) -> places the rows; defined with the currency code below
local setPanelWidth -- (designWidth) -> resizes the match / party panels; defined with the panels below
local setVitalsGeometry -- (VG.Regular | VG.Compact) -> places the vitals card's parts; defined with the card

-- Lays out the four corners. Inputs are measured every time; when nothing changed since the last call the
-- work is skipped (it runs twice a second). `animate` eases the top-left shift; `force` skips the check.
--   * desktop 1920x1080 (scale 1): vitals y 940-1010 (gui), the token pill right above them, panels top-left;
--   * phone landscape 844x390 (scale 0.8): vitals lifted ~90 px, the currency stack moves top-right;
--   * phone portrait 390x844: vitals lifted 150 px, squeezed between the menu column and the DASH button;
--     three currencies pair up (two compact pills per row) so the stack stays out of the screen centre.
local function applyMargins(animate, force)
	if not UI.Gui or not M then
		return
	end
	local touch = isTouchDevice()
	local side = touch and K.TOUCH_EDGE or K.EDGE
	local vp = viewportSize()
	local k = currentScale()
	local area = guiAreaSize()
	local inset = math.max(0, vp.Y - area.Y)
	local column = menuRect(area)
	local buttons = touch and mobileRects() or {}
	local hasPanel, hasTitle, topH = topLeftState()
	local currencies = visibleCurrencies()

	local parts = { area.X, area.Y, vp.X, vp.Y, k, touch and 1 or 0, hasPanel and 1 or 0, hasTitle and 1 or 0, topH, rectKey(column) }
	for _, c in ipairs(currencies) do
		table.insert(parts, c.Id)
	end
	for _, r in ipairs(buttons) do
		table.insert(parts, rectKey(r))
	end
	local key = table.concat(parts, "|")
	if not force and key == layoutKey and not animate then
		return
	end
	layoutKey = key

	local function clearOfColumn(top, bottom)
		if column and top < column.y1 + K.SPAN_MARGIN and bottom > column.y0 - K.SPAN_MARGIN then
			return math.max(side, column.x1 + K.MENU_CLEARANCE)
		end
		return side
	end
	local function rightLimit(top, bottom)
		local limit = area.X - side
		for _, r in ipairs(buttons) do
			if top < r.y1 + K.BUTTON_CLEARANCE and bottom > r.y0 - K.BUTTON_CLEARANCE then
				limit = math.min(limit, r.x0 - K.BUTTON_CLEARANCE)
			end
		end
		return limit
	end
	-- the middle of the screen the game must never write into (the layout rule), in gui-area pixels
	local band = {
		x0 = vp.X * (0.5 - K.CENTRE_TOL), x1 = vp.X * (0.5 + K.CENTRE_TOL),
		y0 = vp.Y * (0.5 - K.CENTRE_TOL) - inset, y1 = vp.Y * (0.5 + K.CENTRE_TOL) - inset,
	}
	local function inBand(x0, x1, y0, y1)
		return x0 < band.x1 and x1 > band.x0 and y0 < band.y1 and y1 > band.y0
	end

	-- how high the bottom-left block sits, and how tall the vitals card is
	local raise = K.EDGE
	local geometry = VG.Regular
	if touch then
		local want = (math.min(vp.X, vp.Y) <= K.SMALL_PHONE) and K.TOUCH_RAISE_SMALL or K.TOUCH_RAISE_LARGE
		-- short landscape screens: keep room for the tallest top-left panel (4-player match) above the vitals;
		-- when the regular card would sit right on the hotbar, the compact card takes its place
		local room = area.Y - K.EDGE - M.TopReserve * k - K.STACK_GAP * k
		if room - VG.Regular.H * k < K.TOUCH_RAISE_MIN + VG.COMPACT_SPARE then
			geometry = VG.Compact
		end
		raise = math.floor(Util.Clamp(math.min(want, room - geometry.H * k), K.TOUCH_RAISE_MIN, want))
	end
	if setVitalsGeometry then
		setVitalsGeometry(geometry)
	end
	local vitalsH = geometry.H

	-- vitals and the currency stack share one left edge (the column above them or beside them)
	local vitalsBottom = area.Y - raise
	local vitalsTop = vitalsBottom - vitalsH * k
	local curBottom = vitalsTop - K.STACK_GAP * k
	local reserveBottom = K.EDGE + M.TopReserve * k + K.STACK_GAP * k
	local n = math.max(1, #currencies)

	-- currency stack: above the vitals as a column, else paired up, else in the top-right corner
	local mode, style = "TopRight", (n >= 3) and "Pairs" or "Column"
	local blockLeft = clearOfColumn(vitalsTop, vitalsBottom)
	local curLeft = blockLeft
	local curW = K.CUR_W
	local candidates = { "Column" }
	if n >= 2 then
		table.insert(candidates, "Pairs")
	end
	for _, candidate in ipairs(candidates) do
		local h = stackHeight(n, candidate) * k
		local top = curBottom - h
		local left = math.max(blockLeft, clearOfColumn(top, curBottom))
		local minW = (candidate == "Pairs") and K.CUR_PAIR_MIN_W or K.CUR_MIN_W
		local w = math.floor(Util.Clamp((rightLimit(top, curBottom) - left) / k, minW, K.CUR_W))
		if inBand(left, left + w * k, top, curBottom) then
			-- a slightly narrower stack may stay clear of the middle
			w = math.max(minW, math.floor(math.min(w, (band.x0 - left) / k)))
		end
		if top >= reserveBottom and not inBand(left, left + w * k, top, curBottom) then
			mode, style, curLeft, curW = "BottomLeft", candidate, left, w
			break
		end
	end
	if mode == "BottomLeft" then
		blockLeft = curLeft
	end

	local vitalsRoom = rightLimit(vitalsTop, vitalsBottom) - blockLeft
	local vitalsW = math.floor(Util.Clamp(vitalsRoom / k, K.VITALS_MIN_W, K.VITALS_W))
	if UI.Vitals then
		UI.Vitals.Size = UDim2.fromOffset(vitalsW, vitalsH)
		UI.Vitals.Position = UDim2.new(0, blockLeft, 1, -raise)
	end

	local stackH = stackHeight(n, style)
	local topRightBottom, topRightLeft = 0, 0
	local bottomLeftTop = vitalsTop
	if UI.Currency then
		if layoutCurrencyRows then
			layoutCurrencyRows(currencies, style, curW)
		end
		UI.Currency.Size = UDim2.fromOffset(curW, stackH)
		if mode == "BottomLeft" then
			UI.Currency.Parent = UI.BottomLeft
			UI.Currency.AnchorPoint = Vector2.new(0, 1)
			UI.Currency.Position = UDim2.new(0, curLeft, 1, -(raise + (vitalsH + K.STACK_GAP) * k))
			bottomLeftTop = curBottom - stackH * k
		else
			UI.Currency.Parent = UI.TopRight
			UI.Currency.AnchorPoint = Vector2.new(1, 0)
			UI.Currency.Position = UDim2.new(1, -side, 0, K.EDGE)
			topRightBottom = K.EDGE + stackH * k
			topRightLeft = area.X - side - curW * k
		end
	end
	S.currencyMode = mode

	-- top-left panels: right of the menu column when they would reach it, and on short screens no wider than
	-- what keeps their text out of the middle of the screen
	local topLeft = side
	local panelW = K.PANEL_W
	if topH > 0 then
		topLeft = clearOfColumn(K.EDGE, K.EDGE + topH * k)
		if K.EDGE + topH * k > band.y0 then
			panelW = math.floor(Util.Clamp((band.x0 - topLeft - 4) / k, K.PANEL_MIN_W, K.PANEL_W))
		end
	end
	if setPanelWidth then
		setPanelWidth(panelW)
	end
	setPadding("TopLeft", topLeft, K.EDGE, 0, 0, animate)
	setPadding("TopRight", 0, 0, 0, 0)
	setPadding("BottomLeft", 0, 0, 0, 0)

	-- tell the neighbours (toasts, side panels) where the HUD is, in gui-area pixels
	local topW = 0
	if hasPanel then
		topW = panelW
	end
	if hasTitle then
		topW = math.max(topW, K.TITLE_W)
	end
	publish("HudScale100", k * 100)
	publish("TopLeftRight", topH > 0 and (topLeft + topW * k) or 0)
	publish("TopLeftBottom", topH > 0 and (K.EDGE + topH * k) or 0)
	publish("TopRightBottom", topRightBottom)
	publish("TopRightLeft", topRightLeft)
	publish("BottomLeftTop", bottomLeftTop)
	if UI.Gui:GetAttribute("CurrencyMode") ~= mode then
		UI.Gui:SetAttribute("CurrencyMode", mode)
	end
end

local function relayout()
	local k = currentScale()
	for i = #scalers, 1, -1 do
		local s = scalers[i]
		if s.Parent then
			s.Scale = k
		else
			table.remove(scalers, i)
		end
	end
	applyMargins(false, true)
end

-- Layout numbers of the match / party panels (design px, 1080p). Text is 18+ everywhere, so it stays
-- >= 14 px on a phone; touch devices get a taller Leave button (it then owns the top-right corner of the
-- match panel and the token line drops under it, at the full right edge: squeezed inset left of the button,
-- it ran into the timer / countdown numeral on landscape phones).
local function panelMetrics(touch)
	local m = {
		LeaveW = 88, LeaveH = 32, LeaveText = 20,
		TitleH = 32, TitleText = 28,
		TimerY = 52, TimerH = 38, TimerText = 34, CountText = 42,
		TokensText = 22, TokensY = 52, TokensH = 38, -- the token line (centre y) shares the timer row
		CpY = 76, CpH = 24, CpText = 18,
		ChipH = 30, RowPitch = 34, NameText = 18, StateText = 18,
		-- party panel (a locked portal: Leave is the only way out, so it is big and sits beside the title),
		-- then the countdown row, the member chips and a "Locked until launch" line with the head count
		PartyLeaveW = 116, PartyLeaveNarrowW = 100, PartyLeaveH = 46, PartyLeaveText = 24, -- narrow: squeezed panels
		PartyStatusH = 30, PartyStatusText = 22, PartyHintH = 24, PartyHintText = 18, PartyCountW = 58,
	}
	if touch then
		m.LeaveW, m.LeaveH = 92, 40
		-- right under the Leave button (y 41-69): clear of it, of the checkpoint bar (76+) and of the timer text
		m.TokensY, m.TokensH = m.LeaveH + 15, 28
		m.PartyLeaveH, m.PartyLeaveText = 56, 26 -- a fat thumb target (>= 44 px on screen at the 0.8 phone scale)
	end
	m.TeamY = m.CpY + m.CpH + 8
	m.PartyTeamY = m.PartyLeaveH + 6 + m.PartyStatusH + 6
	-- panel = content inset top (cloud bumps) + bottom pad + the inner frame's 6 px top / bottom margins
	local insetTop, _, insetBottom = CloudUI.ContentInset(false, true)
	m.Frame = insetTop + insetBottom + 12
	m.MatchBaseH = m.Frame + m.TeamY - (m.RowPitch - m.ChipH) -- + RowPitch per chip row
	m.PartyBaseH = m.Frame + m.PartyTeamY - (m.RowPitch - m.ChipH) + 6 + m.PartyHintH -- + RowPitch per chip row
	m.TopReserve = math.max(m.MatchBaseH, m.PartyBaseH) + 2 * m.RowPitch -- the tallest top-left panel (4 players)
	return m
end

----------------------------------------------------------------------
-- Default CoreGui (health bar + player list)
----------------------------------------------------------------------
local HIDDEN_CORE = { Enum.CoreGuiType.Health, Enum.CoreGuiType.PlayerList }

-- Separate pcalls so a failure on one does not skip the other.
local function hideDefaultCoreGui()
	local allOk = true
	for _, coreType in ipairs(HIDDEN_CORE) do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(coreType, false)
		end)
		allOk = allOk and ok
	end
	return allOk
end

local function disableDefaultHealth()
	task.spawn(function()
		for _ = 1, 60 do
			if hideDefaultCoreGui() then
				task.wait(3) -- the core scripts may re-enable them while loading: apply once more
				hideDefaultCoreGui()
				return
			end
			task.wait(0.5)
		end
	end)
	pcall(function()
		track(StarterGui.CoreGuiChangedSignal:Connect(function(coreType, enabled)
			if enabled and (coreType == Enum.CoreGuiType.Health or coreType == Enum.CoreGuiType.PlayerList) then
				pcall(function()
					StarterGui:SetCoreGuiEnabled(coreType, false)
				end)
			end
		end))
	end)
end

----------------------------------------------------------------------
-- Build: vitals card (bottom-left)
----------------------------------------------------------------------
-- One card in the style of the currency pills: a glossy navy plate with a thick outline; the heart badge
-- beside a thick HP tube ("117 / 117", white damage trail, hit flash + card shake, low-health pulse); the
-- lightning badge beside a matching stamina tube (eases on drain / refill, dims when run dry); the dash ring
-- (a sweep that fills clockwise while the dash recharges). Shapes are Frames (no font glyphs, no images);
-- the parts are placed by setVitalsGeometry (VG.Regular / VG.Compact).

-- Glossy fill of a vitals tube: a soft light top, the base colour, a gentle darker band at the bottom.
function Vitals.BarSequence(color)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Theme.Lighten(color, 0.45)),
		ColorSequenceKeypoint.new(0.4, color),
		ColorSequenceKeypoint.new(0.72, Theme.Darken(color, 0.05)),
		ColorSequenceKeypoint.new(0.76, Theme.Darken(color, 0.2)),
		ColorSequenceKeypoint.new(1, Theme.Darken(color, 0.24)),
	})
end

-- A chunky tube: dark inset track with a rounded outline, an optional white damage trail behind a gradient
-- fill with a highlight strip, a white flash layer on the fill and an optional centred number.
-- opts: Color, Trail (bool), Text. Placed and sized by setVitalsGeometry.
function Vitals.NewBar(parent, name, opts)
	local root = newFrame(parent, name, {
		BackgroundTransparency = 0,
		BackgroundColor3 = WHITE,
		ZIndex = 2,
	})
	round(root)
	Theme.Stroke(root, VS.Edge, 3, 0)
	Theme.Gradient(root, VS.TrackTop, VS.TrackBottom, 90)

	local inner = newFrame(root, "Inner", {
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
	})
	local trail = nil
	if opts.Trail then
		trail = newFrame(inner, "DamageTrail", {
			BackgroundTransparency = 0.04,
			BackgroundColor3 = WHITE,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 1,
		})
		round(trail)
	end
	local fill = newFrame(inner, "Fill", {
		BackgroundTransparency = 0,
		BackgroundColor3 = WHITE,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
	})
	round(fill)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = Vitals.BarSequence(opts.Color)
	gradient.Parent = fill
	local shine = newFrame(fill, "Shine", {
		Position = UDim2.new(0, 7, 0.1, 0),
		Size = UDim2.new(1, -14, 0.26, 0),
		BackgroundTransparency = 0.45,
		BackgroundColor3 = WHITE,
		ZIndex = 3,
	})
	round(shine)
	local flash = newFrame(fill, "Flash", {
		BackgroundTransparency = 1,
		BackgroundColor3 = WHITE,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
	})
	round(flash)
	local label = nil
	if opts.Text then
		label = newText(root, "Text", opts.Text, "Display", 26, WHITE, {
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(0, -1),
			Stroke = 0.1,
			Outline = 2.5,
			ZIndex = 6,
		})
	end

	local bar = { Root = root, Inner = inner, Fill = fill, Trail = trail, Flash = flash, Label = label }
	local shownFill, shownTrail = -1, -1
	function bar.SetFraction(value)
		value = Util.Clamp(tonumber(value) or 0, 0, 1)
		if value == shownFill then
			return
		end
		shownFill = value
		fill.Size = UDim2.fromScale(value, 1)
		-- the highlight strip is inset: it only fits once the fill is wider than tall
		local size = inner.AbsoluteSize
		shine.Visible = size.X * value >= size.Y
	end
	function bar.SetTrail(value)
		value = Util.Clamp(tonumber(value) or 0, 0, 1)
		if trail and value ~= shownTrail then
			shownTrail = value
			trail.Size = UDim2.fromScale(value, 1)
		end
	end
	function bar.SetColor(color)
		gradient.Color = Vitals.BarSequence(color)
	end
	function bar.Invalidate()
		shownFill = -1 -- the size changed: re-check the highlight strip on the next SetFraction
	end
	function bar.SetText(text)
		if label then
			label.Text = tostring(text or "")
		end
	end
	return bar
end

-- A heart from a square turned 45 degrees and two round lobes, filling `fraction` of its square parent.
-- Everything is in scale units, so it follows the badge's size.
function Vitals.HeartShape(parent, name, fraction, color, zIndex)
	local box = newFrame(parent, name, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(fraction, fraction),
		ZIndex = zIndex,
	})
	-- side a = 1 / (1 + sqrt(2) / 2) of the box width; lobes centred on the upper edges of the turned square
	local a, cy, d = 0.5858, 0.5431, 0.2071
	local tip = newFrame(box, "Tip", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, cy),
		Size = UDim2.fromScale(a, a),
		Rotation = 45,
		BackgroundTransparency = 0,
		BackgroundColor3 = color,
		ZIndex = zIndex,
	})
	Theme.Corner(tip, UDim.new(0, 2))
	for i, side in ipairs({ -1, 1 }) do
		local lobe = newFrame(box, (i == 1) and "LobeL" or "LobeR", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5 + side * d, cy - d),
			Size = UDim2.fromScale(a, a),
			BackgroundTransparency = 0,
			BackgroundColor3 = color,
			ZIndex = zIndex,
		})
		round(lobe)
	end
	return box
end

-- A chunky lightning bolt (a zig-zag of three rounded bars) filling `fraction` of its square parent.
function Vitals.BoltShape(parent, name, fraction, color, zIndex)
	local box = newFrame(parent, name, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(fraction, fraction),
		ZIndex = zIndex,
	})
	-- centre x, centre y, width, height (fractions of the box), rotation
	local parts = {
		{ 0.47, 0.27, 0.29, 0.62, 25 },
		{ 0.5, 0.5, 0.62, 0.24, -12 },
		{ 0.53, 0.73, 0.29, 0.62, 25 },
	}
	for i, p in ipairs(parts) do
		local part = newFrame(box, "Part" .. i, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(p[1], p[2]),
			Size = UDim2.fromScale(p[3], p[4]),
			Rotation = p[5],
			BackgroundTransparency = 0,
			BackgroundColor3 = color,
			ZIndex = zIndex,
		})
		Theme.Corner(part, UDim.new(0, 2))
	end
	return box
end

function Vitals.SetShapeTransparency(box, transparency)
	for _, part in ipairs(box:GetChildren()) do
		if part:IsA("GuiObject") then
			part.BackgroundTransparency = transparency
		end
	end
end

-- The dash ring: a round face with the dash glyph inside a ring whose sweep fills clockwise from 12 o'clock
-- as the cooldown runs out. The sweep is two half-discs, each clipped to its half of the ring, with a
-- hard-step transparency gradient turned to the sweep angle (see setSweep). Sized by setVitalsGeometry.
function Vitals.NewDashRing(parent)
	local root = newFrame(parent, "DashRing", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 0,
		BackgroundColor3 = WHITE,
		ZIndex = 3,
	})
	round(root)
	Theme.Stroke(root, VS.Edge, 3, 0)
	Theme.Gradient(root, VS.TrackTop, VS.TrackBottom, 90)
	local sweep = newFrame(root, "Sweep", {
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
	})
	local halves = {}
	for i, side in ipairs({ "Right", "Left" }) do
		local clip = newFrame(sweep, "Half" .. side, {
			Position = UDim2.fromScale((side == "Right") and 0.5 or 0, 0),
			Size = UDim2.fromScale(0.5, 1),
			ClipsDescendants = true,
		})
		local disc = newFrame(clip, "Disc", {
			Position = UDim2.fromScale((side == "Right") and -1 or 0, 0),
			Size = UDim2.fromScale(2, 1),
			BackgroundTransparency = 0,
			BackgroundColor3 = VS.Arc,
		})
		round(disc)
		local g = Instance.new("UIGradient")
		g.Transparency = VS.Solid
		g.Parent = disc
		halves[i] = { Disc = disc, Gradient = g }
	end
	local face, faceGradient, faceStroke = newBadge(root, "Face", 20, Colors.Stamina, Theme.Lighten(Colors.Stamina, 0.45))
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.ZIndex = 2
	faceStroke.Thickness = 2
	local glyph = newText(face, "Glyph", "\194\187", "Display", 20, WHITE, {
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(1, -2),
		Stroke = 0.2,
		StrokeColor = Theme.Darken(Colors.Stamina, 0.7),
		Outline = 2,
		OutlineColor = Theme.Darken(Colors.Stamina, 0.7),
		ZIndex = 2,
	})
	return {
		Root = root, Halves = halves, Face = face, FaceGradient = faceGradient, Glyph = glyph,
		GlyphOutline = glyph:FindFirstChild("TextOutline"), Scale = newScale(root, 1), Solid = true,
	}
end

-- Places every part of the card for one geometry (VG.Regular or VG.Compact); a no-op when unchanged.
setVitalsGeometry = function(g)
	if UI.VitalsGeometry == g or not UI.HpBar then
		return
	end
	UI.VitalsGeometry = g
	UI.Card.Position = UDim2.fromOffset(g.CARD_X, 0)
	UI.Card.Size = UDim2.new(1, -g.CARD_X, 0, g.CARD_H)
	UI.CardCorner.CornerRadius = UDim.new(0, g.CARD_CORNER)
	UI.RimCorner.CornerRadius = UDim.new(0, g.CARD_CORNER - 2)

	-- the ring ends the stamina row, or (RING_SPAN) both rows
	local ringRoom = g.RING + g.RING_GAP
	UI.HpBar.Root.Position = UDim2.fromOffset(g.HP_X, g.HP_Y)
	UI.HpBar.Root.Size = UDim2.new(1, -(g.HP_X + g.PAD_R + (g.RING_SPAN and ringRoom or 0)), 0, g.HP_H)
	UI.HpBar.Label.TextSize = g.HP_TEXT
	UI.StBar.Root.Position = UDim2.fromOffset(g.ST_X, g.ST_Y)
	UI.StBar.Root.Size = UDim2.new(1, -(g.ST_X + g.PAD_R + ringRoom), 0, g.ST_H)
	UI.HpBar.Invalidate()
	UI.StBar.Invalidate()

	local ring = UI.Ring
	ring.Root.Position = UDim2.new(1, -(g.PAD_R + g.RING / 2), 0, g.RING_Y)
	ring.Root.Size = UDim2.fromOffset(g.RING, g.RING)
	ring.Face.Size = UDim2.fromOffset(g.RING_FACE, g.RING_FACE)
	ring.Glyph.TextSize = g.RING_TEXT

	UI.Heart.Position = UDim2.fromOffset(g.BADGE_X, g.HEART_Y)
	UI.Heart.Size = UDim2.fromOffset(g.HEART, g.HEART)
	UI.HeartGlyph.TextSize = g.HEART_TEXT
	UI.Bolt.Badge.Position = UDim2.fromOffset(g.BADGE_X, g.BOLT_Y)
	UI.Bolt.Badge.Size = UDim2.fromOffset(g.BOLT, g.BOLT)

	UI.DownedNotice.Position = UDim2.fromOffset(g.CARD_X + 12, g.ST_Y - 5)
	UI.DownedNotice.Size = UDim2.new(1, -(g.CARD_X + 12 + g.PAD_R), 0, g.ST_H + 10)
end

local function buildVitals(holder)
	local root = newFrame(holder, "Vitals", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, K.EDGE, 1, -K.EDGE),
		Size = UDim2.fromOffset(K.VITALS_W, K.VITALS_H),
	})
	addViewportScale(root)
	UI.Vitals = root
	-- the layout owns the root's position; the damage shake nudges this full-size body instead
	local body = newFrame(root, "Body", { Size = UDim2.fromScale(1, 1) })
	UI.VitalsBody = body

	-- the card plate: the currency pills' glossy navy with a thin light bevel inside the outline
	local card = newFrame(body, "Card", {
		BackgroundTransparency = 0.04,
		BackgroundColor3 = WHITE,
	})
	UI.Card = card
	UI.CardCorner = Theme.Corner(card)
	UI.CardStroke = Theme.Stroke(card, NAVY, 3, 0)
	Theme.Gradient(card, Colors.PanelLight, Colors.Panel, 90)
	local rim = newFrame(card, "Rim", {
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
	})
	UI.RimCorner = Theme.Corner(rim)
	Theme.Stroke(rim, WHITE, 1.5, 0.82)

	-- health tube with the damage trail, then the thinner stamina tube (ends left of the dash ring)
	UI.HpBar = Vitals.NewBar(body, "HealthBar", { Color = Colors.Health, Trail = true, Text = "100 / 100" })
	UI.StBar = Vitals.NewBar(body, "StaminaBar", { Color = Colors.Stamina })
	UI.Ring = Vitals.NewDashRing(body)

	-- lightning badge (under the heart), then the heart badge on top
	local bolt, boltGradient = newBadge(body, "StaminaBadge", 36, VS.BoltBlue, Theme.Lighten(VS.BoltBlue, 0.45))
	bolt.AnchorPoint = Vector2.new(0.5, 0.5)
	bolt.ZIndex = 5
	local boltShadow = Vitals.BoltShape(bolt, "BoltShadow", 0.68, Theme.Darken(VS.BoltBlue, 0.6), 2)
	boltShadow.Position = UDim2.new(0.5, 0, 0.5, 2)
	UI.Bolt = {
		Badge = bolt, Gradient = boltGradient, Shadow = boltShadow,
		Shape = Vitals.BoltShape(bolt, "Bolt", 0.68, WHITE, 3),
	}

	local heart = newBadge(body, "Heart", 52, HEART_RED, Theme.Lighten(HEART_RED, 0.38))
	heart.AnchorPoint = Vector2.new(0.5, 0.5)
	heart.ZIndex = 6
	UI.HeartShadow = Vitals.HeartShape(heart, "HeartShadow", 0.58, Theme.Darken(HEART_RED, 0.6), 2)
	UI.HeartShadow.Position = UDim2.new(0.5, 0, 0.5, 3)
	UI.HeartShape = Vitals.HeartShape(heart, "HeartShape", 0.58, WHITE, 3)
	UI.HeartScale = newScale(heart, 1)
	UI.Heart = heart
	UI.HeartGlyph = newText(heart, "Glyph", "!", "Display", 34, WHITE, {
		TextXAlignment = Enum.TextXAlignment.Center,
		Stroke = 0.2,
		StrokeColor = Theme.Darken(HEART_RED, 0.6),
		Outline = 2.5,
		OutlineColor = Theme.Darken(HEART_RED, 0.6),
		Visible = false,
		ZIndex = 4,
	})

	-- "Wait for a teammate!" replaces the stamina row while downed (no running or dashing then anyway)
	UI.DownedNotice = newText(body, "DownedNotice", "Wait for a teammate!", "Display", 21, Colors.Bad, {
		TextXAlignment = Enum.TextXAlignment.Center,
		TextScaled = true,
		Stroke = 0.1,
		Outline = 2,
		Visible = false,
		ZIndex = 5,
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 18, Parent = UI.DownedNotice })
	setVitalsGeometry(VG.Regular)
end

----------------------------------------------------------------------
-- Build: currency stack (bottom-left above the vitals, or top-right on short screens)
----------------------------------------------------------------------
local function buildCurrencyRow(parent, entry)
	local def = entry.Def or {}
	local color = def.Color or Colors.Token
	local glow = def.Glow or Colors.TokenGlow
	local row = newFrame(parent, "Currency_" .. entry.Id, {
		Size = UDim2.fromOffset(K.CUR_W, K.CUR_H),
		Visible = false,
	})

	-- the pill (its left end hides behind the coin)
	local body = newFrame(row, "Body", {
		BackgroundTransparency = 0.04,
		BackgroundColor3 = WHITE,
	})
	round(body)
	Theme.Stroke(body, NAVY, 3, 0)
	Theme.Gradient(body, Colors.PanelLight, Colors.Panel, 90)
	local shine = newFrame(body, "Shine", {
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 0.82,
		BackgroundColor3 = WHITE,
	})
	round(shine)
	-- a thin coloured rim at the bottom of the pill ties it to its coin colour
	local lip = newFrame(body, "Lip", {
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundTransparency = 0.45,
		BackgroundColor3 = color,
	})
	round(lip)

	local coin = newCoin(row, "Coin", K.COIN, color, glow, def.Glyph or "?", 30)
	coin.AnchorPoint = Vector2.new(0, 0.5)
	coin.Position = UDim2.new(0, 0, 0.5, 0)
	coin.ZIndex = 3

	local amount = newText(row, "Amount", "0", "Display", 32, WHITE, {
		AnchorPoint = Vector2.new(0, 0.5),
		Stroke = 0.15,
		Outline = 2.5,
		ZIndex = 3,
	})

	local c = {
		Id = entry.Id, Def = def, Attr = entry.Attr, Always = entry.Always == true,
		Row = row, Body = body, Shine = shine, Lip = lip, Coin = coin, CoinGlyph = coin:FindFirstChild("Glyph"),
		Amount = amount, AmountScale = newScale(amount, 1), CoinScale = newScale(coin, 1),
		Target = 0, Display = 0, Shown = nil, Seen = false, Available = false, ChipShown = false,
		Width = K.CUR_W, Compact = nil,
	}

	if entry.Run then
		local chip = newFrame(row, "RunChip", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -7, 0.5, 0),
			Size = UDim2.fromOffset(K.CHIP_W, 32),
			BackgroundTransparency = 0.05,
			BackgroundColor3 = Theme.Darken(color, 0.5),
			Visible = false,
			ZIndex = 4,
		})
		round(chip)
		Theme.Stroke(chip, color, 2, 0.1)
		c.Chip = chip
		c.RunLabel = newText(chip, "Run", "+0", "Accent", 21, glow, {
			TextXAlignment = Enum.TextXAlignment.Center,
			Stroke = 0.2,
			Outline = 1.5,
			ZIndex = 5,
		})
		c.RunScale = newScale(c.RunLabel, 1)
	end
	return c
end

-- Inner geometry of one pill: a full pill has the big coin, a compact (paired) one a smaller coin.
local function setRowGeometry(c, compact)
	if c.Compact == compact then
		return
	end
	c.Compact = compact
	local coinSize = compact and K.COIN_COMPACT or K.COIN
	c.Coin.Size = UDim2.fromOffset(coinSize, coinSize)
	if c.CoinGlyph then
		c.CoinGlyph.TextSize = compact and 24 or 30
	end
	c.Body.Position = UDim2.fromOffset(math.floor(coinSize * 0.4), 0)
	c.Body.Size = UDim2.new(1, -math.floor(coinSize * 0.4), 1, 0)
	c.Shine.Position = UDim2.new(0.5, math.floor(coinSize * 0.25), 0, 4)
	c.Shine.Size = UDim2.new(1, -math.floor(coinSize * 0.9), 0, 7)
	c.Lip.Position = UDim2.new(0.5, math.floor(coinSize * 0.25), 1, -4)
	c.Lip.Size = UDim2.new(1, -math.floor(coinSize * 0.9), 0, 3)
	c.Amount.Position = UDim2.new(0, coinSize + 8, 0.5, -1)
end

local function buildCurrency(holder)
	local root = newFrame(holder, "Currency", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, K.EDGE, 1, -K.EDGE - K.VITALS_H - K.STACK_GAP),
		Size = UDim2.fromOffset(K.CUR_W, K.CUR_H),
	})
	addViewportScale(root)
	UI.Currency = root
	for _, entry in ipairs(CURRENCY_ORDER) do
		if entry.Attr ~= nil or entry.Always then
			Cur[entry.Id] = buildCurrencyRow(root, entry)
		end
	end
end

----------------------------------------------------------------------
-- Build: team / party chips (shared by the match and party panels)
----------------------------------------------------------------------
-- A small name plate: name, optional state glyph, optional mini health bar.
local function newChip(parent, index, withHealth)
	local frame = newFrame(parent, "Chip" .. tostring(index), {
		BackgroundTransparency = 0.15,
		BackgroundColor3 = Colors.Ink,
		Size = UDim2.fromOffset(120, M.ChipH),
		LayoutOrder = index,
		Visible = false,
	})
	Theme.Corner(frame, UDim.new(0, 9))
	local stroke = Theme.Stroke(frame, Colors.PanelLight, 2, 0.2)
	local name = newText(frame, "Name", "", "Body", M.NameText, WHITE, {
		Position = UDim2.new(0, 8, 0, withHealth and -2 or 0),
		-- party chips (no health) never show a state glyph: their names get that room too
		Size = UDim2.new(1, withHealth and -34 or -16, 1, withHealth and -4 or 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.3,
	})
	local state = newText(frame, "State", "", "Heading", M.StateText, WHITE, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, withHealth and -2 or 0),
		Size = UDim2.new(0, 24, 1, withHealth and -4 or 0),
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	local fill = nil
	if withHealth then
		local track_ = newFrame(frame, "HpTrack", {
			Position = UDim2.new(0, 8, 1, -8),
			Size = UDim2.new(1, -16, 0, 5),
			BackgroundTransparency = 0.1,
			BackgroundColor3 = Colors.Panel,
		})
		round(track_)
		fill = newFrame(track_, "Fill", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 0,
			BackgroundColor3 = Colors.Health,
		})
		round(fill)
	end
	return { Frame = frame, Stroke = stroke, Name = name, State = state, Fill = fill }
end

-- Lays out `count` chips in a grid of two columns inside a holder `width` wide. Returns the row count.
local function layoutChips(chips, count, width)
	local cols = (count >= 2) and 2 or 1
	local gap = 6
	local cellW = math.floor((width - gap * (cols - 1)) / cols)
	local rows = math.max(1, math.ceil(count / cols))
	for i, chip in ipairs(chips) do
		if i <= count then
			local col = (i - 1) % cols
			local row = math.floor((i - 1) / cols)
			chip.Frame.Position = UDim2.fromOffset(col * (cellW + gap), row * M.RowPitch)
			chip.Frame.Size = UDim2.fromOffset(cellW, M.ChipH)
			chip.Frame.Visible = true
		else
			chip.Frame.Visible = false
		end
	end
	return rows
end

-- inner width of the match / party panels (panel - frame pads - inner margins)
local function innerWidth()
	return S.panelW - 2 * CloudUI.Metrics.Pad - 20
end

----------------------------------------------------------------------
-- Build: match panel (top-left)
----------------------------------------------------------------------
local function buildMatch(holder)
	local panel = CloudUI.Panel({
		Name = "MatchPanel",
		Size = UDim2.fromOffset(S.panelW, M.MatchBaseH + M.RowPitch),
		Accent = Colors.Stamina,
		Parent = holder,
	})
	panel.Body.Active = false -- the HUD never swallows camera drags
	addViewportScale(panel.Root)
	UI.Match = panel
	Items.Match = newItem(panel.Root, UDim2.new(-1.5, 0, 0, 0))

	local inner = newFrame(panel.Content, "Inner", {
		Position = UDim2.new(0, 10, 0, 6),
		Size = UDim2.new(1, -20, 1, -12),
	})
	UI.MatchInner = inner

	-- row A: difficulty (+ stars) and the Leave button
	UI.MatchTitle = newText(inner, "Difficulty", "", "Title", M.TitleText, WHITE, {
		Size = UDim2.new(1, -(M.LeaveW + 8), 0, M.TitleH),
		RichText = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.15,
		Outline = 2,
	})
	UI.LeaveBtn = CloudUI.Button({
		Name = "LeaveMatch",
		Text = "Leave",
		Style = "Pink",
		TextSize = M.LeaveText,
		Size = UDim2.fromOffset(M.LeaveW, M.LeaveH),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -M.LeaveW / 2, 0, M.LeaveH / 2),
		Callback = function(button)
			HudController._onLeaveMatch(button)
		end,
		Parent = inner,
	})

	-- row B: timer / countdown numerals (left), token progress (right)
	UI.Timer = newText(inner, "Timer", "0:00", "Display", M.TimerText, WHITE, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0, M.TimerY),
		Size = UDim2.new(0.5, 0, 0, M.TimerH),
		Stroke = 0.15,
		Outline = 2.5,
	})
	UI.TimerScale = newScale(UI.Timer, 1)
	UI.MatchTokens = newText(inner, "Tokens", "", "Toast", M.TokensText, Colors.TokenGlow, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0, M.TokensY),
		Size = UDim2.new(0.55, 0, 0, M.TokensH),
		TextXAlignment = Enum.TextXAlignment.Right,
		Stroke = 0.15,
		Outline = 2,
	})
	UI.TokensScale = newScale(UI.MatchTokens, 1)

	-- checkpoint progress
	UI.CpBar = CloudUI.Bar({
		Name = "CheckpointBar",
		Height = M.CpH,
		TextSize = M.CpText,
		Color = Colors.Stamina,
		Label = "Checkpoint 0/0",
		Position = UDim2.fromOffset(0, M.CpY),
		Size = UDim2.new(1, 0, 0, M.CpH),
		Parent = inner,
	})

	-- team chips
	UI.Team = newFrame(inner, "Team", {
		Position = UDim2.fromOffset(0, M.TeamY),
		Size = UDim2.new(1, 0, 1, -M.TeamY),
	})
end

----------------------------------------------------------------------
-- Build: party panel (top-left, lobby only)
----------------------------------------------------------------------
local function buildParty(holder)
	local panel = CloudUI.Panel({
		Name = "PartyPanel",
		Size = UDim2.fromOffset(S.panelW, M.PartyBaseH + M.RowPitch),
		Accent = Colors.Good,
		Parent = holder,
	})
	panel.Body.Active = false
	addViewportScale(panel.Root)
	UI.Party = panel
	Items.Party = newItem(panel.Root, UDim2.new(-1.5, 0, 0, 0))

	local inner = newFrame(panel.Content, "Inner", {
		Position = UDim2.new(0, 10, 0, 6),
		Size = UDim2.new(1, -20, 1, -12),
	})
	UI.PartyInner = inner

	-- row A: the portal's name and the big red Leave button (the only way out of a locked portal)
	UI.PartyTitle = newText(inner, "Title", "Party", "Title", M.TitleText, WHITE, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0, M.PartyLeaveH / 2),
		Size = UDim2.new(1, -(M.PartyLeaveW + 8), 0, M.TitleH),
		RichText = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.15,
		Outline = 2,
	})
	UI.PartyLeave = CloudUI.Button({
		Name = "LeaveParty",
		Text = "Leave",
		Style = "Red",
		TextSize = M.PartyLeaveText,
		Size = UDim2.fromOffset(M.PartyLeaveW, M.PartyLeaveH),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -M.PartyLeaveW / 2, 0, M.PartyLeaveH / 2),
		Callback = function()
			-- one request per press (the server rate-limits too)
			local now = os.clock()
			if now >= Pt.LeaveLockUntil then
				Pt.LeaveLockUntil = now + 0.8
				fireRemote("LeaveParty")
			end
		end,
		Parent = inner,
	})
	-- row B: the countdown, full width so "Full! Starting in 3s" fits on a phone too
	UI.PartyStatus = newText(inner, "Status", "Waiting for players...", "Display", M.PartyStatusText, Colors.TokenGlow, {
		Position = UDim2.fromOffset(0, M.PartyLeaveH + 6),
		Size = UDim2.new(1, 0, 0, M.PartyStatusH),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.15,
		Outline = 2,
	})
	UI.PartyStatusScale = newScale(UI.PartyStatus, 1)
	-- row C: the members
	UI.PartyTeam = newFrame(inner, "Players", {
		Position = UDim2.fromOffset(0, M.PartyTeamY),
		Size = UDim2.new(1, 0, 0, M.RowPitch),
	})
	-- row D: why the pad holds you (the walls) + the head count
	UI.PartyHint = newText(inner, "Hint", "Locked until launch", "Label", M.PartyHintText, MUTED, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, -(M.PartyCountW + 6), 0, M.PartyHintH),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.2,
		Outline = 1.5,
	})
	UI.PartyCount = newText(inner, "Count", "0/4", "Heading", 21, WHITE, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, 0),
		Size = UDim2.fromOffset(M.PartyCountW, M.PartyHintH),
		TextXAlignment = Enum.TextXAlignment.Right,
		Stroke = 0.2,
		Outline = 1.5,
	})
end

----------------------------------------------------------------------
-- Build: title card (top-left, small)
----------------------------------------------------------------------
local function buildTitleCard(holder)
	local card = newFrame(holder, "TitleCard", {
		Size = UDim2.fromOffset(K.TITLE_W, K.TITLE_H),
		BackgroundTransparency = 0.06,
		BackgroundColor3 = WHITE, -- the gradient below supplies the colour
		Visible = false,
	})
	Theme.Corner(card, UDim.new(0, 16))
	Theme.Stroke(card, NAVY, 4, 0)
	Theme.Gradient(card, Colors.PanelLight, Colors.Panel, 90)
	addViewportScale(card)
	UI.TitleCard = card
	Items.Title = newItem(card, UDim2.new(-1.5, 0, 0, 0))

	local gloss = newFrame(card, "Gloss", {
		Position = UDim2.new(0, 10, 0, 5),
		Size = UDim2.new(1, -20, 0, 9),
		BackgroundTransparency = 0.84,
		BackgroundColor3 = WHITE,
	})
	round(gloss)

	-- a gold cloud coin at the left
	local coin = newCoin(card, "Coin", 54, Colors.Token, Colors.TokenGlow, "\226\152\129", 30)
	coin.AnchorPoint = Vector2.new(0, 0.5)
	coin.Position = UDim2.new(0, 11, 0.5, 0)

	local title = newText(card, "Title", string.upper(tostring(Config.GameName)), "Title", 32, WHITE, {
		Position = UDim2.new(0, 74, 0, 6),
		Size = UDim2.new(1, -84, 0, 38),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.1,
		Outline = 2.5,
	})
	Theme.Gradient(title, Colors.Cloud, Colors.TokenGlow, 90)
	newText(card, "Tagline", tostring(Config.Tagline), "Script", 19, Colors.Muted or Colors.Cloud, {
		Position = UDim2.new(0, 74, 0, 44),
		Size = UDim2.new(1, -84, 0, 24),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.3,
		Outline = 1.5,
	})
end

local function hideTitleCard()
	if TC.Shown then
		TC.Shown = false
		TC.Serial = TC.Serial + 1
		present(Items.Title, false)
		applyMargins(true)
	end
end

local function playTitleCard()
	task.wait(1.5)
	if not Items.Title or S.match ~= nil or S.party ~= nil then
		return
	end
	TC.Serial = TC.Serial + 1
	local serial = TC.Serial
	TC.Shown = true
	present(Items.Title, true)
	applyMargins(true)
	task.wait(K.TITLE_CARD_SECONDS)
	if TC.Serial == serial and TC.Shown then
		TC.Shown = false
		present(Items.Title, false)
		applyMargins(true)
	end
end

----------------------------------------------------------------------
-- Health
----------------------------------------------------------------------
local function refreshHealthText()
	local text
	if S.downed then
		text = "DOWNED"
	else
		text = string.format("%d / %d", math.ceil(H.Cur - 0.001), math.ceil(H.Max - 0.001))
	end
	if text ~= H.Text and UI.HpBar then
		H.Text = text
		UI.HpBar.SetText(text)
	end
end

local function onHealth(health, snap)
	local humanoid = H.Humanoid
	local max = (humanoid and humanoid.MaxHealth) or H.Max
	if type(max) ~= "number" or max < 1 then
		max = 1
	end
	local cur = Util.Clamp(tonumber(health) or 0, 0, max)
	local frac = cur / max
	if snap then
		H.Fill = frac
		H.Trail = frac
	elseif frac < H.Target - 0.0005 then
		-- took damage: the white trail holds a moment, the bar flashes, the card shakes, the heart pops
		local now = os.clock()
		H.HoldUntil = now + K.TRAIL_HOLD
		H.HitAt = now
		if not H.Low then
			pop(UI.HeartScale, 1.25, 0.35)
		end
	end
	H.Target = frac
	H.Cur = cur
	H.Max = max
	if frac > H.Trail then
		H.Trail = frac
	end
	refreshHealthText()
end

local function setDowned(downed)
	if S.downed == downed then
		return
	end
	S.downed = downed
	if UI.DownedNotice then
		UI.DownedNotice.Visible = downed
	end
	-- the stamina row (bar, badge, dash ring) makes room for the notice
	if UI.StBar then
		UI.StBar.Root.Visible = not downed
	end
	if UI.Ring then
		UI.Ring.Root.Visible = not downed
	end
	if UI.Bolt then
		UI.Bolt.Badge.Visible = not downed
	end
	if UI.HeartShape then
		UI.HeartShape.Visible = not downed
		UI.HeartShadow.Visible = not downed
		UI.HeartGlyph.Visible = downed
	end
	if UI.CardStroke then
		UI.CardStroke.Color = downed and Colors.Bad or NAVY
	end
	H.ColorKey = nil -- repaint the bar
	refreshHealthText()
end

local function updateHealth(dt, now)
	if not UI.HpBar then
		return
	end
	-- the fill chases the target quickly, the trail waits and then catches up
	local diff = H.Target - H.Fill
	if math.abs(diff) > 0.0005 then
		H.Fill = H.Fill + diff * (1 - math.exp(-dt * 14))
	else
		H.Fill = H.Target
	end
	UI.HpBar.SetFraction(H.Fill)
	if H.Trail > H.Fill then
		if now >= H.HoldUntil then
			H.Trail = math.max(H.Fill, H.Trail - dt * K.TRAIL_SPEED)
		end
	else
		H.Trail = H.Fill
	end
	UI.HpBar.SetTrail(H.Trail)

	-- colour: green -> amber -> red, red while downed
	local key = "ok"
	local color = Theme.HealthColor(H.Target)
	if S.downed then
		key = "down"
		color = Colors.Bad
	elseif H.Target <= K.LOW_HEALTH then
		key = "low"
	elseif H.Target <= 0.6 then
		key = "mid"
	end
	if key ~= H.ColorKey then
		H.ColorKey = key
		UI.HpBar.SetColor(color)
	end

	-- a hit: a white flash on the fill and a short shake of the card, both fading out
	local flash = UI.HpBar.Flash
	local since = now - H.HitAt
	if since >= 0 and since < K.HIT_SECONDS then
		local k = 1 - since / K.HIT_SECONDS
		flash.BackgroundTransparency = 1 - 0.85 * k
		local amp = K.SHAKE_PX * k
		UI.VitalsBody.Position = UDim2.fromOffset(math.sin(since * 70) * amp, math.cos(since * 52) * amp * 0.5)
		H.HitFx = true
	elseif H.HitFx then
		H.HitFx = false
		flash.BackgroundTransparency = 1
		UI.VitalsBody.Position = UDim2.fromOffset(0, 0)
	end

	-- low health: the heart beats, the fill breathes and the card's outline glows red with the beat
	local low = (H.Target <= K.LOW_HEALTH) and not S.downed
	if low then
		local beat = math.max(0, math.sin(now * 7.5))
		beat = beat * beat
		UI.Heart.Rotation = math.sin(now * 3.7) * 4
		UI.HeartScale.Scale = 1 + 0.16 * beat
		UI.CardStroke.Color = NAVY:Lerp(Colors.HealthLow, 0.25 + 0.65 * beat)
		if not H.HitFx then
			flash.BackgroundTransparency = 1 - 0.3 * beat
		end
		H.Low = true
	elseif H.Low then
		H.Low = false
		UI.Heart.Rotation = 0
		UI.HeartScale.Scale = 1
		UI.CardStroke.Color = S.downed and Colors.Bad or NAVY
		if not H.HitFx then
			flash.BackgroundTransparency = 1
		end
	end
	if S.downed then
		UI.DownedNotice.TextTransparency = 0.05 + 0.2 * (0.5 + 0.5 * math.sin(now * 5))
	end
end

local function unbindHumanoid()
	for _, conn in ipairs(H.Conns) do
		conn:Disconnect()
	end
	H.Conns = {}
	H.Humanoid = nil
end

local function bindCharacter(char)
	unbindHumanoid()
	H.Char = char
	local humanoid = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 10)
	if not humanoid or H.Char ~= char then
		return
	end
	H.Humanoid = humanoid
	table.insert(H.Conns, humanoid.HealthChanged:Connect(function(health)
		guard("health", onHealth, health, false)
	end))
	table.insert(H.Conns, humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		guard("max health", onHealth, humanoid.Health, true)
	end))
	guard("health", onHealth, humanoid.Health, true)
end

----------------------------------------------------------------------
-- Stamina + dash ring
----------------------------------------------------------------------
local function dashCooldownFraction(now)
	if not movementModule then
		if now < movementNextTry then
			return 0
		end
		movementNextTry = now + 2
		local controllers = script.Parent
		local mod = controllers and controllers:FindFirstChild("MovementController")
		if mod then
			local ok, result = pcall(require, mod)
			if ok and type(result) == "table" then
				movementModule = result
			end
		end
		if not movementModule then
			return 0
		end
	end
	local fn = movementModule.GetDashCooldownFraction
	if type(fn) ~= "function" then
		return 0
	end
	local ok, value = pcall(fn)
	if ok and type(value) == "number" then
		return Util.Clamp(value, 0, 1)
	end
	return 0
end

-- Turns the two half-disc gradients so the ring shows `charge` (0..1) clockwise from 12 o'clock. A gradient
-- at Rotation r hides the half-plane its direction points into, so the right half shows the arc for
-- r = 0..180 and the left half the rest for r = 180..360.
function Vitals.SetSweep(charge)
	local ring = UI.Ring
	local solid = charge >= 0.999
	if solid ~= ring.Solid then
		ring.Solid = solid
		local sequence = solid and VS.Solid or VS.Step
		for _, half in ipairs(ring.Halves) do
			half.Gradient.Transparency = sequence
		end
	end
	if not solid then
		local angle = Util.Clamp(charge, 0, 1) * 360
		ring.Halves[1].Gradient.Rotation = math.min(angle, 180)
		ring.Halves[2].Gradient.Rotation = math.max(angle, 180)
	end
end

-- Ready: a bright face inside a full bright ring; recharging: a dark face, the sweep filling; out of
-- stamina for a dash: the sweep turns grey.
function Vitals.PaintRing(ready, afford)
	local ring = UI.Ring
	local sweepColor = afford and VS.Arc or VS.Grey
	for _, half in ipairs(ring.Halves) do
		half.Disc.BackgroundColor3 = sweepColor
	end
	if ready then
		ring.FaceGradient.Color = badgeSequence(Colors.Stamina, Theme.Lighten(Colors.Stamina, 0.45))
	else
		ring.FaceGradient.Color = badgeSequence(Theme.Darken(Colors.Stamina, 0.55), Theme.Darken(Colors.Stamina, 0.35))
	end
	ring.Glyph.TextTransparency = ready and 0 or 0.35
	if ring.GlyphOutline then
		ring.GlyphOutline.Transparency = ready and 0 or 0.5 -- a glyph outline does not fade with its text
	end
end

-- dim 0 = bright .. 1 = empty: the tube greys out and the lightning badge fades
function Vitals.PaintStaminaDim(dim)
	local base = VS.BoltBlue:Lerp(VS.Grey, 0.85 * dim)
	UI.Bolt.Gradient.Color = badgeSequence(base, Theme.Lighten(base, 0.45))
	Vitals.SetShapeTransparency(UI.Bolt.Shape, 0.5 * dim)
	Vitals.SetShapeTransparency(UI.Bolt.Shadow, 0.5 * dim)
	UI.StBar.SetColor(Colors.Stamina:Lerp(VS.Grey, 0.7 * dim))
end

local function updateStamina(dt, now)
	if not UI.StBar or not UI.Ring then
		return
	end
	local physics = Config.Physics or {}
	local maxSt = physics.MaxStamina or 100
	local value = player:GetAttribute(Config.Attr.Stamina)
	if type(value) ~= "number" then
		value = maxSt
	end
	local target = Util.Clamp(value / maxSt, 0, 1)
	St.Frac = St.Frac + (target - St.Frac) * (1 - math.exp(-dt * 18))
	if math.abs(target - St.Frac) < 0.002 then
		St.Frac = target
	end
	UI.StBar.SetFraction(St.Frac)

	-- dim: a little below one dash's cost, fully once run dry until running is possible again (eased,
	-- repainted on change only)
	local cost = physics.DashStaminaCost or 35
	if value <= 0.5 then
		St.Drained = true
	elseif value >= K.STAMINA_RECOVER then
		St.Drained = false
	end
	local dimGoal = 0
	if St.Drained then
		dimGoal = 1
	elseif value < cost then
		dimGoal = 0.35
	end
	St.Dim = St.Dim + (dimGoal - St.Dim) * (1 - math.exp(-dt * 10))
	if math.abs(dimGoal - St.Dim) < 0.01 then
		St.Dim = dimGoal
	end
	if math.abs(St.Dim - St.DimDrawn) > 0.02 or (St.Dim == dimGoal and St.DimDrawn ~= dimGoal) then
		St.DimDrawn = St.Dim
		Vitals.PaintStaminaDim(St.Dim)
	end

	-- dash ring: the sweep follows the cooldown, the face lights up once a dash is possible
	local cd = dashCooldownFraction(now)
	local charge = 1 - cd
	if math.abs(charge - St.Charge) > 0.004 then
		St.Charge = charge
		Vitals.SetSweep(charge)
	end
	local afford = value >= cost
	local ready = (cd <= 0.001) and afford
	if ready ~= St.Ready or afford ~= St.Afford then
		if ready and St.Ready == false then
			pop(UI.Ring.Scale, 1.3, 0.3)
		end
		St.Ready = ready
		St.Afford = afford
		Vitals.PaintRing(ready, afford)
	end
end

----------------------------------------------------------------------
-- Currencies
----------------------------------------------------------------------
local function readCurrency(c)
	local value = nil
	if c.Id == "Tokens" and State and type(State.Tokens) == "function" then
		local ok, result = pcall(State.Tokens)
		if ok then
			value = result
		end
	end
	if type(value) ~= "number" and c.Attr then
		value = tonumber(player:GetAttribute(c.Attr))
	end
	if type(value) ~= "number" or value ~= value then
		value = 0
	end
	return math.max(0, math.floor(value))
end

local function matchTokensNow()
	return math.max(0, math.floor(tonumber(player:GetAttribute(Config.Attr.MatchTokens)) or 0))
end

local function inMatchNow()
	return S.match ~= nil or player:GetAttribute(Config.Attr.InMatch) == true
end

-- The number shrinks to fit the room left beside the coin and the optional "+n" chip.
local function setAmountText(c, n)
	local text = Theme.ShortNumber(n)
	local coinSize = c.Compact and K.COIN_COMPACT or K.COIN
	local chip = c.ChipShown and (K.CHIP_W + 6) or 0
	local avail = c.Width - (coinSize + 8) - 10 - chip
	local size = Util.Clamp(math.floor(avail / (math.max(1, #text) * 0.6)), 18, 32)
	c.Amount.Text = text
	c.Amount.TextSize = size
	c.Amount.Size = UDim2.new(1, -(coinSize + 8) - 10 - chip, 1, -2)
end

-- Places the rows of `list` (top to bottom) in a stack `width` design px wide: "Column" = one pill per row,
-- "Pairs" = two compact pills per row (a last single pill gets the full width). Other rows are hidden.
layoutCurrencyRows = function(list, style, width)
	local shown = {}
	for _, c in ipairs(list) do
		shown[c] = true
	end
	for _, entry in ipairs(CURRENCY_ORDER) do
		local c = Cur[entry.Id]
		if c and not shown[c] then
			c.Row.Visible = false
		end
	end
	local y = 0
	local i = 1
	while i <= #list do
		local pair = style == "Pairs" and i < #list
		local items = pair and { list[i], list[i + 1] } or { list[i] }
		local w = pair and math.floor((width - K.CUR_GAP) / 2) or width
		for j, c in ipairs(items) do
			local x = (j - 1) * (w + K.CUR_GAP)
			c.Row.Position = UDim2.fromOffset(x, y)
			c.Row.Size = UDim2.fromOffset(w, K.CUR_H)
			c.Row.Visible = true
			local resized = c.Width ~= w
			c.Width = w
			setRowGeometry(c, pair)
			if resized or c.Shown == nil then
				setAmountText(c, c.Shown or c.Display)
			end
		end
		i = i + #items
		y = y + K.CUR_H + K.CUR_GAP
	end
end

-- Cash / Gems become available once their attribute exists (Tokens always is).
local function refreshCurrencyVisibility()
	local changed = false
	for _, entry in ipairs(CURRENCY_ORDER) do
		local c = Cur[entry.Id]
		if c then
			local available = c.Always or (c.Attr ~= nil and type(player:GetAttribute(c.Attr)) == "number")
			if available ~= c.Available then
				c.Available = available
				changed = true
				if available then
					c.Seen = false
					c.Shown = nil
					pop(c.CoinScale, 1.35, 0.45)
				end
			end
		end
	end
	if changed then
		applyMargins(false, true)
	end
end

local function onCurrencyChanged(c)
	if not c.Available then
		return
	end
	local v = readCurrency(c)
	local early = (os.clock() - startedAt) < 4 -- the saved totals arrive right after joining: no fanfare
	if not c.Seen or early or v < c.Target then
		c.Seen = true
		c.Target = v
		c.Display = v
		return
	end
	if v > c.Target then
		c.Target = v
		pop(c.CoinScale, 1.3, 0.4)
		pop(c.AmountScale, 1.2, 0.4)
	end
end

local function refreshRunChip()
	local c = Cur.Tokens
	if not c or not c.Chip then
		return
	end
	local inMatch = inMatchNow()
	if inMatch ~= c.ChipShown then
		c.ChipShown = inMatch
		c.Chip.Visible = inMatch
		setAmountText(c, c.Shown or c.Display)
	end
	local count = matchTokensNow()
	if count ~= Tk.RunSeen then
		local grew = count > Tk.RunSeen
		Tk.RunSeen = count
		c.RunLabel.Text = "+" .. Theme.ShortNumber(count)
		if grew then
			pop(c.RunScale, 1.3, 0.35)
		end
	end
end

local function updateCurrencies(dt)
	for _, entry in ipairs(CURRENCY_ORDER) do
		local c = Cur[entry.Id]
		if c and c.Available then
			local diff = c.Target - c.Display
			if diff ~= 0 then
				c.Display = c.Display + diff * (1 - math.exp(-dt * 7))
				if math.abs(c.Target - c.Display) < 0.5 then
					c.Display = c.Target
				end
			end
			local shown = math.floor(c.Display + 0.5)
			if shown ~= c.Shown then
				c.Shown = shown
				setAmountText(c, shown)
			end
		end
	end
end

----------------------------------------------------------------------
-- Match panel
----------------------------------------------------------------------
local function ensureChips(list, parent, count, withHealth)
	for i = #list + 1, count do
		list[i] = newChip(parent, i, withHealth)
	end
end

-- Short screens squeeze the match / party panels a little (applyMargins decides); the chips follow.
setPanelWidth = function(width)
	if width == S.panelW then
		return
	end
	S.panelW = width
	for _, panel in ipairs({ UI.Match, UI.Party }) do
		if panel then
			panel.Root.Size = UDim2.fromOffset(width, panel.Root.Size.Y.Offset)
		end
	end
	layoutChips(Mt.Chips, Mt.Count, innerWidth())
	layoutChips(Pt.Chips, Pt.Count, innerWidth())
end

local function resizePanel(panel, base, rows)
	local h = base + rows * M.RowPitch
	panel.Root.Size = UDim2.fromOffset(S.panelW, h)
	-- a taller panel may now reach the menu column (or a shorter one no longer does)
	applyMargins(true)
end

local function updateTeam(members)
	local count = math.min(#members, 4)
	Mt.Count = count
	ensureChips(Mt.Chips, UI.Team, count, true)
	local rows = layoutChips(Mt.Chips, count, innerWidth())
	if rows ~= Mt.Rows then
		Mt.Rows = rows
		resizePanel(UI.Match, M.MatchBaseH, rows)
	end
	local localId = player.UserId
	for i = 1, count do
		local m = type(members[i]) == "table" and members[i] or {}
		local chip = Mt.Chips[i]
		local isMe = (m.UserId == localId)
		chip.Name.Text = tostring(m.Name or "?")
		chip.Name.TextColor3 = isMe and Colors.TokenGlow or WHITE
		local frac = Util.Clamp(tonumber(m.Health) or 0, 0, 1)
		chip.Fill.Size = UDim2.fromScale(frac, 1)
		chip.Fill.BackgroundColor3 = Theme.HealthColor(frac)
		if m.Finished then
			chip.State.Text = "\226\156\148"
			chip.State.TextColor3 = Colors.Good
			chip.Stroke.Color = Colors.Good
		elseif m.Downed then
			chip.State.Text = "\226\152\160" -- skull and crossbones
			chip.State.TextColor3 = Colors.Bad
			chip.Stroke.Color = Colors.Bad
		else
			chip.State.Text = ""
			chip.Stroke.Color = isMe and GOLD or Colors.PanelLight
		end
	end
end

local function updateTokensLine(state)
	local text = "\226\152\129 " .. tostring(math.floor(tonumber(state.TokensCollected) or 0))
		.. "/" .. tostring(math.floor(tonumber(state.TotalTokens) or 0))
	if UI.MatchTokens.Text ~= text then
		local grew = Mt.TokensSeen ~= nil and (tonumber(state.TokensCollected) or 0) > Mt.TokensSeen
		Mt.TokensSeen = tonumber(state.TokensCollected) or 0
		UI.MatchTokens.Text = text
		if grew then
			pop(UI.TokensScale, 1.2, 0.3)
		end
	end
end

-- Timer / countdown numerals. Runs every frame for the interpolated clock.
local function numeralColor(n)
	local rainbow = Colors.Rainbow
	if n == 3 then
		return rainbow[3]
	elseif n == 2 then
		return rainbow[2]
	elseif n == 1 then
		return rainbow[1]
	end
	return rainbow[5]
end

local function setTimerText(text, color, size)
	if UI.Timer.Text ~= text then
		UI.Timer.Text = text
	end
	UI.Timer.TextColor3 = color
	if UI.Timer.TextSize ~= size then
		UI.Timer.TextSize = size
	end
end

local function updateMatchClock(now)
	local state = S.match
	if not state or not UI.Timer then
		return
	end
	local phase = state.Phase
	local remaining = math.max(0, Mt.Base - (now - Mt.At))
	if phase == "Countdown" then
		local n = math.max(1, math.ceil(remaining - 0.05))
		if n ~= Mt.Last then
			Mt.Last = n
			UI.MatchTokens.Text = "Get ready!"
			pop(UI.TimerScale, 1.7, 0.5)
		end
		setTimerText(tostring(n), numeralColor(n), M.CountText)
	elseif phase == "Playing" then
		if now < Mt.GoUntil then
			setTimerText("GO!", Colors.Good, M.CountText)
			return
		end
		local color = WHITE
		if remaining <= 30 then
			color = Colors.Bad:Lerp(WHITE, 0.5 + 0.5 * math.sin(now * 6))
		elseif remaining <= 60 then
			color = Colors.HealthMid
		end
		setTimerText(Util.FormatTime(remaining), color, M.TimerText)
	else
		setTimerText("Match over", Colors.Muted or WHITE, 26)
	end
end

local function disarmLeave()
	LM.ArmedUntil = 0
	if UI.LeaveBtn then
		UI.LeaveBtn.Text = "Leave"
		CloudUI.SetStyle(UI.LeaveBtn, "Pink")
	end
end

-- "Leave" in the match panel needs two presses within a few seconds.
function HudController._onLeaveMatch(button)
	local now = os.clock()
	if now < LM.LockedUntil then
		return
	end
	if now < LM.ArmedUntil then
		LM.LockedUntil = now + 1
		disarmLeave()
		fireRemote("LeaveMatch")
		return
	end
	LM.ArmedUntil = now + K.LEAVE_CONFIRM_SECONDS
	button.Text = "Sure?"
	CloudUI.SetStyle(button, "Red")
	task.delay(K.LEAVE_CONFIRM_SECONDS + 0.05, function()
		if LM.ArmedUntil > 0 and os.clock() >= LM.ArmedUntil then
			disarmLeave()
		end
	end)
end

local function refreshVisibility()
	local hasMatch = S.match ~= nil
	local showParty = S.party ~= nil and not hasMatch and player:GetAttribute(Config.Attr.InMatch) ~= true
	present(Items.Match, hasMatch and not S.yieldToResult)
	present(Items.Party, showParty)
	if hasMatch or showParty then
		hideTitleCard()
	end
	applyMargins(true) -- the top-left slot is taken or free: step aside for the menu column only when needed
	refreshRunChip()
end

local function clearMatch()
	S.match = nil
	Mt.Phase = nil
	Mt.Last = nil
	Mt.GoUntil = 0
	Mt.TokensSeen = nil
	disarmLeave()
	refreshVisibility()
end

local function applyMatchState(state)
	if type(state) ~= "table" then
		clearMatch()
		return
	end
	local now = os.clock()
	local prevPhase = Mt.Phase
	local phase = state.Phase
	S.match = state
	Mt.Phase = phase
	Mt.Base = tonumber(state.Seconds) or 0
	Mt.At = now
	if phase == "Playing" and prevPhase == "Countdown" then
		Mt.GoUntil = now + K.GO_SECONDS
		Mt.Last = nil
		UI.TimerScale.Scale = 1.7
		tween(UI.TimerScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end
	if phase ~= "Countdown" then
		Mt.Last = nil
	end

	local color = state.Color
	if typeof(color) ~= "Color3" then
		color = Colors.Stamina
	end
	local diff = Config.GetDifficulty and Config.GetDifficulty(state.DifficultyId) or nil
	local starText = ""
	if diff then
		starText = "  <font color=\"" .. hex(GOLD) .. "\">" .. stars(diff.Stars) .. "</font>"
	end
	UI.MatchTitle.Text = tostring(state.DifficultyName or state.DifficultyId or "Match") .. starText
	UI.MatchTitle.TextColor3 = Theme.Lighten(color, 0.25)

	local total = math.max(1, math.floor(tonumber(state.TotalCheckpoints) or 1))
	local cp = Util.Clamp(math.floor(tonumber(state.Checkpoint) or 0), 0, total)
	UI.CpBar.SetColor(color)
	UI.CpBar.SetFraction(cp / total, true)
	UI.CpBar.SetText(string.format("Checkpoint %d/%d", cp, total))

	if phase ~= "Countdown" then
		updateTokensLine(state)
	end
	UI.LeaveBtn.Visible = (phase ~= "Ended")

	if type(state.Members) == "table" then
		updateTeam(state.Members)
	end
	refreshVisibility()
	updateMatchClock(now)
end

----------------------------------------------------------------------
-- Party panel
----------------------------------------------------------------------
local function partyStatusText(now)
	local party = S.party
	if not party then
		return ""
	end
	local count = type(party.Players) == "table" and #party.Players or 0
	local max = tonumber(party.Max) or Config.Match.MaxPlayers
	if party.Countdown ~= nil and Pt.Base ~= nil then
		local left = math.ceil(Pt.Base - (now - Pt.At) - 0.001)
		if left < 1 then
			return "Launching..." -- the server hands the party to the match any moment now
		end
		if count >= max then
			return "Full! Starting in " .. tostring(left) .. "s"
		end
		return "Starting in " .. tostring(left) .. "s"
	elseif count >= max then
		return "Party full!"
	end
	return "Waiting for players..."
end

-- Does `text` fit `width` design px at `size` in `font`? (measured by the engine; +5 px for the glyph outline)
local function textFits(text, font, size, width)
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, size, font, Vector2.new(4000, 400))
	end)
	return not ok or typeof(bounds) ~= "Vector2" or bounds.X + 5 <= width
end

-- The largest of `sizes` (design px, largest first) at which `text` fits; the smallest one otherwise.
local function fittingSize(text, font, sizes, width)
	for _, size in ipairs(sizes) do
		if textFits(text, font, size, width) then
			return size
		end
	end
	return sizes[#sizes]
end

-- A squeezed panel (short screens, beside the menu column) shrinks the title / countdown a little and shortens
-- the hint instead of cutting "Medium" down to "Medi...". Runs only when a text or the panel width changed.
local function fitPartyTexts()
	local title, status = UI.PartyTitle.Text, UI.PartyStatus.Text
	if Pt.FitW == S.panelW and Pt.FitTitle == title and Pt.FitStatus == status and Pt.FitHint == Pt.HintLong then
		return
	end
	Pt.FitW, Pt.FitTitle, Pt.FitStatus, Pt.FitHint = S.panelW, title, status, Pt.HintLong
	local inner = innerWidth()
	-- a squeezed panel gives the title a little of the Leave button's width (the button stays a big target)
	local leaveW = (inner < 260) and M.PartyLeaveNarrowW or M.PartyLeaveW
	if UI.PartyLeave.Size.X.Offset ~= leaveW then
		UI.PartyLeave.Size = UDim2.fromOffset(leaveW, M.PartyLeaveH)
		UI.PartyLeave.Position = UDim2.new(1, -leaveW / 2, 0, M.PartyLeaveH / 2)
		UI.PartyTitle.Size = UDim2.new(1, -(leaveW + 8), 0, M.TitleH)
	end
	UI.PartyTitle.TextSize = fittingSize(title, UI.PartyTitle.Font, { M.TitleText, 26, 24, 22 }, inner - leaveW - 8)
	UI.PartyStatus.TextSize = fittingSize(status, UI.PartyStatus.Font, { M.PartyStatusText, 20, 19 }, inner)
	if textFits(Pt.HintLong, UI.PartyHint.Font, M.PartyHintText, inner - M.PartyCountW - 6) then
		UI.PartyHint.Text = Pt.HintLong
	else
		UI.PartyHint.Text = Pt.HintShort
	end
end

local function updatePartyClock(now)
	if not S.party or not UI.PartyStatus then
		return
	end
	local text = partyStatusText(now)
	if text ~= Pt.LastText then
		Pt.LastText = text
		UI.PartyStatus.Text = text
		if string.find(text, "Starting in", 1, true) then
			pop(UI.PartyStatusScale, 1.12, 0.25)
		end
	end
	fitPartyTexts()
end

local function applyPartyState(state)
	if type(state) ~= "table" then
		S.party = nil
		Pt.Base = nil
		Pt.LastText = nil
		refreshVisibility()
		return
	end
	local now = os.clock()
	S.party = state
	if state.Countdown ~= nil then
		Pt.Base = tonumber(state.Countdown) or 0
		Pt.At = now
	else
		Pt.Base = nil
	end

	local color = state.Color
	if typeof(color) ~= "Color3" then
		color = Colors.Good
	end
	UI.PartyTitle.Text = tostring(state.DifficultyName or "?")
	UI.PartyTitle.TextColor3 = Theme.Lighten(color, 0.25)
	-- members are held on the pad by the portal walls until launch (PortalService); Leave is the way out
	if state.Locked == false then
		Pt.HintLong, Pt.HintShort = "In the portal party", "In a party"
	else
		Pt.HintLong, Pt.HintShort = "Locked until launch", "Locked in"
	end
	UI.PartyHint.Text = Pt.HintLong
	Pt.FitHint = nil -- fitPartyTexts (via updatePartyClock below) picks the long or short hint

	local list = type(state.Players) == "table" and state.Players or {}
	local count = math.min(#list, 4)
	Pt.Count = count
	ensureChips(Pt.Chips, UI.PartyTeam, count, false)
	local rows = layoutChips(Pt.Chips, count, innerWidth())
	if rows ~= Pt.Rows then
		Pt.Rows = rows
		UI.PartyTeam.Size = UDim2.new(1, 0, 0, rows * M.RowPitch)
		resizePanel(UI.Party, M.PartyBaseH, rows)
	end
	for i = 1, count do
		local entry = type(list[i]) == "table" and list[i] or {}
		local chip = Pt.Chips[i]
		local isMe = (entry.UserId == player.UserId)
		chip.Name.Text = tostring(entry.Name or "?")
		chip.Name.TextColor3 = isMe and Colors.TokenGlow or WHITE
		chip.Stroke.Color = isMe and GOLD or Colors.PanelLight
	end
	UI.PartyCount.Text = string.format("%d/%d", #list, tonumber(state.Max) or Config.Match.MaxPlayers)
	Pt.LastText = nil
	updatePartyClock(now)
	refreshVisibility()
end

-- NotifyController publishes the left edge of its open result card; where it would cover the match panel
-- (portrait phones) the panel slides away until the card closes.
local function checkResultCard()
	local pg = playerGui()
	local notifyGui = pg and pg:FindFirstChild("NimbusNotify")
	local left = notifyGui and notifyGui:GetAttribute("ResultCardLeft")
	if type(left) ~= "number" then
		left = 0
	end
	local right = (padGoals.TopLeft or K.EDGE) + S.panelW * currentScale()
	local yield = left > 0 and right > left - 8
	if yield ~= S.yieldToResult then
		S.yieldToResult = yield
		refreshVisibility()
	end
end

----------------------------------------------------------------------
-- Frame loop
----------------------------------------------------------------------
local function onRender(dt)
	local now = os.clock()
	guard("health", updateHealth, dt, now)
	guard("stamina", updateStamina, dt, now)
	guard("currencies", updateCurrencies, dt)
	guard("match clock", updateMatchClock, now)
	guard("party clock", updatePartyClock, now)
	layoutPoll = layoutPoll + dt
	if layoutPoll >= K.LAYOUT_POLL then
		layoutPoll = 0
		guard("layout", applyMargins, false, false) -- neighbours (menu column, touch buttons) may have moved
		guard("result card", checkResultCard)
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
-- Where the HUD currently is (gui-area pixels of an IgnoreGuiInset = false ScreenGui; 0 = nothing there).
function HudController.GetLayout()
	return {
		TopLeftRight = published.TopLeftRight or 0,
		TopLeftBottom = published.TopLeftBottom or 0,
		TopRightBottom = published.TopRightBottom or 0,
		BottomLeftTop = published.BottomLeftTop or 0,
		Scale = currentScale(),
		CurrencyMode = S.currencyMode,
	}
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local function buildGui()
	M = panelMetrics(isTouchDevice())
	local gui = CloudUI.NewScreenGui("NimbusHud", 10)
	UI.Gui = gui

	local topLeft = newHolder(gui, "TopLeft")
	local topRight = newHolder(gui, "TopRight")
	local bottomLeft = newHolder(gui, "BottomLeft")
	UI.TopRight = topRight
	UI.BottomLeft = bottomLeft

	buildVitals(bottomLeft)
	buildCurrency(bottomLeft)
	buildMatch(topLeft)
	buildParty(topLeft)
	buildTitleCard(topLeft)
	refreshCurrencyVisibility()
	applyMargins(false, true)
end

local function hookRemote(name, handler)
	task.spawn(function()
		local ok, remote = pcall(Remotes.Get, name)
		if not ok or not remote then
			warnOnce("remote " .. name, remote)
			return
		end
		remoteCache[name] = remote
		if handler then
			track(remote.OnClientEvent:Connect(handler))
		end
	end)
end

local function hookCamera()
	local cameraConn = nil
	local function bind()
		if cameraConn then
			cameraConn:Disconnect()
			cameraConn = nil
		end
		local camera = workspace.CurrentCamera
		if camera then
			cameraConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				guard("relayout", relayout)
				-- the menu and the touch controls lay themselves out on the same signal: measure them again
				task.delay(0.1, function()
					guard("relayout", relayout)
				end)
			end)
		end
		guard("relayout", relayout)
	end
	track(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bind))
	bind()
	if UI.Gui then
		track(UI.Gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			guard("relayout", relayout)
		end))
	end
	-- the viewport can still be 1x1 right at startup: re-check shortly afterwards
	task.delay(0.5, function()
		guard("relayout", relayout)
	end)
	task.delay(2, function()
		guard("relayout", relayout)
	end)
end

local function hookCurrencies()
	for _, entry in ipairs(CURRENCY_ORDER) do
		local c = Cur[entry.Id]
		if c and c.Attr then
			track(player:GetAttributeChangedSignal(c.Attr):Connect(function()
				guard("currency visibility", refreshCurrencyVisibility)
				guard("currency " .. c.Id, onCurrencyChanged, c)
			end))
		end
	end
	if State and State.TokensChanged and Cur.Tokens then
		pcall(function()
			track(State.TokensChanged:Connect(function()
				guard("currency Tokens", onCurrencyChanged, Cur.Tokens)
			end))
		end)
	end
	-- snap every counter to its current value (or 0)
	for _, entry in ipairs(CURRENCY_ORDER) do
		local c = Cur[entry.Id]
		if c then
			guard("currency " .. c.Id, onCurrencyChanged, c)
			-- no attribute yet: snap to the saved total when it lands
			c.Seen = c.Attr ~= nil and player:GetAttribute(c.Attr) ~= nil
			c.Shown = nil
		end
	end
end

function HudController.Init()
	if initialized then
		return
	end
	player = Players.LocalPlayer
	if not player then
		return
	end
	initialized = true
	startedAt = os.clock()

	disableDefaultHealth()
	buildGui()
	hookCamera()

	-- player attributes
	local attr = Config.Attr
	hookCurrencies()
	track(player:GetAttributeChangedSignal(attr.MatchTokens):Connect(function()
		guard("run chip", refreshRunChip)
	end))
	track(player:GetAttributeChangedSignal(attr.InMatch):Connect(function()
		if player:GetAttribute(attr.InMatch) ~= true and S.match ~= nil then
			guard("in match", clearMatch) -- back in the lobby: drop a stale match view
		else
			guard("in match", refreshVisibility)
		end
	end))
	track(player:GetAttributeChangedSignal(attr.Downed):Connect(function()
		guard("downed", setDowned, player:GetAttribute(attr.Downed) == true)
	end))
	refreshRunChip()
	if player:GetAttribute(attr.Downed) == true then
		setDowned(true)
	end

	-- character / humanoid (respawn safe)
	track(player.CharacterAdded:Connect(function(char)
		task.spawn(bindCharacter, char)
	end))
	track(player.CharacterRemoving:Connect(function(char)
		if H.Char == char then
			unbindHumanoid()
			H.Char = nil
		end
	end))
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end

	-- server state
	hookRemote("MatchState", function(state)
		guard("match state", applyMatchState, state)
	end)
	hookRemote("PartyState", function(state)
		guard("party state", applyPartyState, state)
	end)
	hookRemote("LeaveParty", nil)
	hookRemote("LeaveMatch", nil)

	track(RunService.RenderStepped:Connect(onRender))
	task.spawn(function()
		guard("title card", playTitleCard)
	end)
end

return HudController
