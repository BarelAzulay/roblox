-- HudController: the Nimbus Climb heads-up display (v2).
--
--   HudController.Init()
--
-- One ScreenGui "NimbusHud" (display order 10, IgnoreGuiInset = false, built by CloudUI.NewScreenGui).
-- Nothing the game announces is ever drawn in the middle of the screen. The layout map:
--
--   top-left      Match panel (difficulty, timer, checkpoint bar, team chips, Leave button) with the
--                 pre-match countdown numerals shown INSIDE it; the lobby Party panel takes the same
--                 slot; the small title card slides in there at join and leaves after four seconds
--   top-right     Token pill: cloud coin + saved total (count-up, pop) and "+n" for this match
--   bottom-left   Vitals: heart badge + health bar (damage trail, low-health pulse, DOWNED state),
--                 stamina bar and a dash-ready pip. Raised on touch devices to clear the thumbstick.
--
-- The menu column (MenuController, left-centre, drawn above the HUD) is never covered: when the vitals or the
-- top-left panels would reach it on a short screen they move to its right (applyMargins).
-- Touch devices get bigger text and hit targets in the match / party panels (panelMetrics).
--
-- Every panel is a fixed-size design in "design pixels" with a UIScale (viewport / 1280x720) so the HUD
-- reads well from phones to 4K. The UIScale sits on the panel, the margins on full-screen holder frames
-- (UIPadding), so scaling never moves a panel away from its corner.
--
-- Data: Humanoid health, player attributes (CloudTokens, MatchTokens, InMatch, Downed, Stamina) and the
-- MatchState / PartyState remotes. Everything is nil-safe: no humanoid, no match, no party and a missing
-- MovementController all leave the HUD in a sensible idle state.
-- Plain Lua 5.1-compatible syntax only. All fonts come from Theme roles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

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
if not okState then
	State = nil
end

local HudController = {}

----------------------------------------------------------------------
-- Tunables (design pixels unless noted)
----------------------------------------------------------------------
-- KEEP IN SYNC with NotifyController.lua: REF_W/REF_H/MIN_SCALE/MAX_SCALE, EDGE, TOUCH_EDGE, PILL_H
-- (the toast stack starts just below the token pill).
local REF_W, REF_H = 1280, 720
local MIN_SCALE, MAX_SCALE = 0.7, 1.25
local EDGE = 10 -- margin to the screen edge
local TOUCH_EDGE = 20 -- larger side margin on touch devices (notches, rounded corners)
local TOUCH_RAISE_SMALL = 150 -- how far the vitals are lifted on phones (thumbstick room)
local TOUCH_RAISE_LARGE = 220 -- ... and on tablets

local VITALS_W, VITALS_H = 300, 54
local VITALS_MIN_W = 220 -- narrowest the vitals get squeezed on a small phone (see applyMargins)
local NOTICE_H = 24 -- the DOWNED notice sits this far above the vitals
local PILL_W, PILL_H = 214, 44
local PANEL_W = 270 -- match + party panels
local TITLE_W, TITLE_H = 236, 58
local CHIP_H, ROW_PITCH = 22, 24 -- team chip height and the distance between two chip rows

-- KEEP IN SYNC with MenuController.lua (COL_W, BTN, CAPTION_H, COMPACT_BELOW, the 0.72..1.2 column scale, the
-- 5 buttons, the 6 px gap). The left-centre menu column has display order 20, so it is drawn ABOVE this HUD:
-- whatever of ours would run into it (vitals, top-left panels) steps aside to its right (see applyMargins).
local MENU_COL_W, MENU_BTN, MENU_CAPTION_H, MENU_GAP = 68, 56, 18, 6
local MENU_BUTTONS = 5
local MENU_COMPACT_BELOW = 560 -- gui height under which the menu captions are hidden
local MENU_MIN_SCALE, MENU_MAX_SCALE = 0.72, 1.2
local MENU_CLEARANCE = 8 -- empty strip kept between the column and whatever steps aside for it
local SPAN_MARGIN = 4 -- two vertical spans closer than this count as touching
-- KEEP IN SYNC with MovementController.lua: on a small phone its DASH button starts 113 px from the right edge.
local DASH_CLEAR = 113 + 8
local SMALL_PHONE = 500 -- Roblox's own touch controls shrink when the smaller screen side is at most this

local LOW_HEALTH = 0.3 -- below this the heart pulses
local TITLE_CARD_SECONDS = 4
local LEAVE_CONFIRM_SECONDS = 3
local GO_SECONDS = 1.0 -- how long "GO!" replaces the timer

local Colors = Theme.Colors
local WHITE = Colors.White
local NAVY = Colors.Navy or Colors.Ink
local MUTED = Colors.Muted or Colors.CloudShade
local GOLD = Colors.Gold or Colors.Token
local HEART_RED = Color3.fromRGB(222, 86, 104)
local TRAIL_COLOR = Color3.fromRGB(240, 206, 214)

----------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------
local player = nil
local initialized = false
local startedAt = 0
local connections = {}
local warned = {}
local remoteCache = {}
local scalers = {} -- UIScale objects driven by the viewport size
local pads = {} -- UIPadding objects of the corner holders
local padTweens = {} -- running PaddingLeft tween per holder
local padGoals = {} -- last PaddingLeft requested per holder
local M = nil -- layout metrics of the match / party panels, see panelMetrics()
local movementModule = nil
local movementNextTry = 0

local UI = {} -- instance references
local Items = {} -- sliding panels, see present()

local S = { match = nil, party = nil, downed = false }
local H = { -- health
	Char = nil, Humanoid = nil, Conns = {},
	Cur = 100, Max = 100, Target = 1, Fill = 1, Trail = 1,
	HoldUntil = 0, ColorKey = nil, Text = nil, Low = false,
}
local St = { Frac = 1, Charge = -1, PipReady = true, LowColor = false } -- stamina + dash pip
local Tk = { Target = 0, Display = 0, Shown = nil, Seen = false, RunSeen = 0 } -- token pill
local Mt = { -- match panel bookkeeping
	Base = 0, At = 0, Phase = nil, Last = nil, GoUntil = 0, Rows = 1, Chips = {}, Roster = nil,
}
local Pt = { Base = nil, At = 0, Rows = 1, Chips = {}, LastText = nil }
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
	local vp = camera and camera.ViewportSize or Vector2.new(REF_W, REF_H)
	if vp.X < 2 or vp.Y < 2 then
		return Vector2.new(REF_W, REF_H)
	end
	return vp
end

local function currentScale()
	local vp = viewportSize()
	return Util.Clamp(math.min(vp.X / REF_W, vp.Y / REF_H), MIN_SCALE, MAX_SCALE)
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

-- Themed TextLabel. props may include Stroke (text outline transparency) plus any label property.
local function newText(parent, name, text, role, size, color, props)
	local extra = {
		Name = name,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}
	local stroke = 0.3
	if props then
		for key, value in pairs(props) do
			if key == "Stroke" then
				stroke = value
			else
				extra[key] = value
			end
		end
	end
	local label = Theme.Label(text, role, { Size = size, Color = color, Stroke = stroke, Props = extra })
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

-- A UIScale driven by the viewport size (grows around the object's anchor point).
local function addViewportScale(root)
	local s = newScale(root, currentScale())
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

-- The area GUIs with IgnoreGuiInset = false are laid out in (below the top bar). This is the very number
-- MenuController measures its column against, so the two always agree.
local function guiAreaSize()
	local size = UI.Gui and UI.Gui.AbsoluteSize
	if size and size.X >= 2 and size.Y >= 2 then
		return size
	end
	local vp = viewportSize()
	local inset = 0
	pcall(function()
		inset = GuiService:GetGuiInset().Y
	end)
	return Vector2.new(vp.X, math.max(2, vp.Y - inset))
end

-- Footprint of MenuController's column in gui pixels: it spans y = Top..Bottom against the left edge, and a
-- panel that has to step aside starts `Clear` pixels (column width + gap + a little air) further right.
local function menuColumn(area)
	local scale = Util.Clamp(math.min(area.X / REF_W, area.Y / REF_H), MENU_MIN_SCALE, MENU_MAX_SCALE)
	local entry = MENU_BTN
	if area.Y >= MENU_COMPACT_BELOW then
		entry = entry + MENU_CAPTION_H
	end
	local height = (MENU_BUTTONS * entry + (MENU_BUTTONS - 1) * MENU_GAP) * scale
	return {
		Top = (area.Y - height) / 2,
		Bottom = (area.Y + height) / 2,
		Clear = (MENU_COL_W + MENU_GAP) * scale + MENU_CLEARANCE,
	}
end

-- Design height of whatever currently occupies the top-left slot (0 while nothing does).
local function topLeftHeight()
	local h = 0
	if Items.Match and Items.Match.Shown and UI.Match then
		h = math.max(h, UI.Match.Root.Size.Y.Offset)
	end
	if Items.Party and Items.Party.Shown and UI.Party then
		h = math.max(h, UI.Party.Root.Size.Y.Offset)
	end
	if Items.Title and Items.Title.Shown then
		h = math.max(h, TITLE_H)
	end
	return h
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
		return -- already there, or already easing there (MatchState calls this at 2 Hz)
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

-- Re-apply the screen margins. Touch devices get larger side margins and a raised bottom-left corner.
-- On short screens the menu column (left-centre, drawn above us) reaches into both left corners; the vitals
-- and the top-left panels then start to its right instead of underneath it:
--   * phone landscape 844x390: column y 56-276, vitals y 144-182, top-left panels y 10-125;
--   * tablet 1024x768: column y 197-512, vitals y 447-490;
--   * small portrait phone 375x667: column y 163-447, vitals y 421-459.
-- `animate` eases the top-left shift (used when a panel appears or changes height).
local function applyMargins(animate)
	local touch = isTouchDevice()
	local side = touch and TOUCH_EDGE or EDGE
	local vp = viewportSize()
	local k = currentScale()
	local area = guiAreaSize()
	local column = menuColumn(area)
	local raise = EDGE
	if touch then
		raise = (math.min(vp.X, vp.Y) <= SMALL_PHONE) and TOUCH_RAISE_SMALL or TOUCH_RAISE_LARGE
	end

	-- vitals (bottom-left), including the DOWNED notice above them
	local vitalsLeft = side
	local vitalsW = VITALS_W
	local vitalsBottom = area.Y - raise
	local vitalsTop = vitalsBottom - (VITALS_H + NOTICE_H) * k
	if vitalsTop < column.Bottom + SPAN_MARGIN and vitalsBottom > column.Top - SPAN_MARGIN then
		vitalsLeft = side + column.Clear
		if touch and math.min(vp.X, vp.Y) <= SMALL_PHONE then
			-- a narrow portrait phone has little room right of the column: shorten the bars so the dash pip
			-- (their right end) stays left of MovementController's DASH button
			local room = (vp.X - DASH_CLEAR) - vitalsLeft
			vitalsW = Util.Clamp(math.floor(room / k), VITALS_MIN_W, VITALS_W)
		end
	end
	if UI.Vitals then
		UI.Vitals.Size = UDim2.fromOffset(vitalsW, VITALS_H)
	end

	-- top-left panels
	local topLeft = side
	local topH = topLeftHeight()
	if topH > 0 and EDGE + topH * k + SPAN_MARGIN > column.Top then
		topLeft = side + column.Clear
	end

	setPadding("TopLeft", topLeft, EDGE, 0, 0, animate)
	setPadding("TopRight", 0, EDGE, side, 0)
	setPadding("BottomLeft", vitalsLeft, 0, 0, raise)
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
	applyMargins()
end

-- Layout numbers of the match / party panels (design px). Touch devices get bigger text and hit targets: the
-- panels are drawn at no more than 0.7 on a phone, so 14 / 13 px text ends up at about 9 px. Chosen once, when the
-- HUD is built, because the panels are built from them. The panels may only grow a little: on a 667x375 phone
-- only ~129 px are left above the raised vitals and a 4-player match panel needs ~125 of them (it needed 120
-- before the taller checkpoint bar). So the bigger Leave button overlaps the token line's old spot instead of
-- adding a row: the token line moves left of it.
local function panelMetrics(touch)
	local m = {
		LeaveW = 66, LeaveH = 22, LeaveText = 14, -- "Leave" buttons
		CpH = 14, CpText = nil, -- checkpoint bar height and label size (nil: the bar picks)
		NameText = 13, -- team chip names
		TokensInset = 0, -- how far the "7/24" token line stays clear of the right edge
		PartyTeamY = 28,
	}
	if touch then
		m.LeaveW, m.LeaveH, m.LeaveText = 72, 32, 16
		m.CpH, m.CpText = 20, 14
		m.NameText = 15
		m.TokensInset = m.LeaveW + 6 -- the taller Leave button owns the top-right corner
		m.PartyTeamY = 36
	end
	m.TeamY = 52 + m.CpH + 4
	m.MatchBaseH = m.TeamY + 40 -- 34 frame insets + 8 margins + rows
	m.PartyBaseH = m.PartyTeamY + 68
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
-- Build: vitals (bottom-left)
----------------------------------------------------------------------
local function buildVitals(holder)
	local root = newFrame(holder, "Vitals", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.fromOffset(VITALS_W, VITALS_H),
	})
	addViewportScale(root)
	UI.Vitals = root

	-- health bar (CloudUI.Bar) with a lagging damage trail between the track and the fill
	local hpBar = CloudUI.Bar({
		Name = "HealthBar",
		Height = 28,
		Color = Colors.Health,
		Label = "100 / 100",
		Position = UDim2.fromOffset(26, 0),
		Size = UDim2.new(1, -26, 0, 28),
		Parent = root,
	})
	UI.HpBar = hpBar
	local inner = hpBar.Root:FindFirstChild("Inner") or hpBar.Root
	local trail = newFrame(inner, "DamageTrail", {
		BackgroundColor3 = TRAIL_COLOR,
		BackgroundTransparency = 0.2,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 0,
	})
	round(trail)
	UI.Trail = trail

	-- stamina bar + dash pip
	local stBar = CloudUI.Bar({
		Name = "StaminaBar",
		Height = 14,
		Color = Colors.Stamina,
		Position = UDim2.fromOffset(26, 32),
		Size = UDim2.new(1, -26 - 34, 0, 14),
		Parent = root,
	})
	UI.StBar = stBar

	local pip = newFrame(root, "DashPip", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0, 40),
		Size = UDim2.fromOffset(28, 28),
		BackgroundTransparency = 0,
		BackgroundColor3 = WHITE,
		ZIndex = 3,
	})
	round(pip)
	UI.PipStroke = Theme.Stroke(pip, NAVY, 3, 0)
	UI.PipGradient = Instance.new("UIGradient")
	UI.PipGradient.Rotation = 90
	UI.PipGradient.Color = ColorSequence.new(Theme.Darken(Colors.Stamina, 0.6))
	UI.PipGradient.Parent = pip
	UI.PipScale = newScale(pip, 1)
	UI.PipGlyph = newText(pip, "Glyph", "\194\187", "Display", 18, WHITE, {
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 4,
	})

	-- heart badge overlapping the left end of both bars
	local heart = newFrame(root, "Heart", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(24, 27),
		Size = UDim2.fromOffset(46, 46),
		BackgroundTransparency = 0,
		BackgroundColor3 = WHITE,
		ZIndex = 6,
	})
	round(heart)
	Theme.Stroke(heart, NAVY, 3, 0)
	Theme.Gradient(heart, Theme.Lighten(HEART_RED, 0.25), Theme.Darken(HEART_RED, 0.2), 90)
	UI.HeartScale = newScale(heart, 1)
	UI.Heart = heart
	UI.HeartGlyph = newText(heart, "Glyph", "\226\153\165", "Display", 27, WHITE, {
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 7,
	})

	-- "DOWNED" notice, small, just above the bars
	UI.DownedNotice = newText(root, "DownedNotice", "DOWNED - wait for a teammate!", "Toast", 16, Colors.Bad, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 30, 0, -4),
		Size = UDim2.new(1, -30, 0, 20),
		Stroke = 0.1,
		Visible = false,
	})
end

----------------------------------------------------------------------
-- Build: token pill (top-right)
----------------------------------------------------------------------
local function buildTokens(holder)
	local root = newFrame(holder, "TokenPill", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(PILL_W, PILL_H),
	})
	addViewportScale(root)
	UI.TokenPill = root

	local body = newFrame(root, "Body", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 0,
		BackgroundColor3 = WHITE,
	})
	round(body)
	Theme.Stroke(body, NAVY, 3, 0)
	Theme.Gradient(body, Colors.PanelLight, Colors.Panel, 90)
	local shine = newFrame(body, "Shine", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 6, 0, 3),
		Size = UDim2.new(1, -52, 0, 6),
		BackgroundTransparency = 0.82,
		BackgroundColor3 = WHITE,
	})
	round(shine)

	-- gold cloud coin
	local coin = newFrame(body, "Coin", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(PILL_H - 6, PILL_H - 6),
		BackgroundTransparency = 0,
		BackgroundColor3 = WHITE,
		ZIndex = 3,
	})
	round(coin)
	Theme.Stroke(coin, NAVY, 3, 0)
	Theme.Gradient(coin, Colors.TokenGlow, Colors.Token, 90)
	UI.CoinScale = newScale(coin, 1)
	newText(coin, "Glyph", "\226\152\129", "Display", 22, WHITE, {
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 4,
		Stroke = 0.1,
	})

	UI.TokenCount = newText(body, "Count", "0", "Display", 26, WHITE, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, PILL_H + 4, 0.5, 0),
		Size = UDim2.new(1, -(PILL_H + 4) - 8, 1, -4),
		ZIndex = 3,
	})
	UI.CountScale = newScale(UI.TokenCount, 1)

	-- "+n" this match, only while in a match
	local chip = newFrame(body, "RunChip", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(64, 26),
		BackgroundTransparency = 0.15,
		BackgroundColor3 = Theme.Darken(Colors.Token, 0.55),
		Visible = false,
		ZIndex = 3,
	})
	round(chip)
	Theme.Stroke(chip, Colors.Token, 2, 0.2)
	UI.RunChip = chip
	UI.RunLabel = newText(chip, "Run", "+0", "Accent", 17, Colors.TokenGlow, {
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 4,
	})
	UI.RunScale = newScale(UI.RunLabel, 1)
end

----------------------------------------------------------------------
-- Build: team / party chips (shared by the match and party panels)
----------------------------------------------------------------------
-- A small name plate: name, optional state glyph, optional mini health bar.
local function newChip(parent, index, withHealth)
	local frame = newFrame(parent, "Chip" .. tostring(index), {
		BackgroundTransparency = 0.25,
		BackgroundColor3 = Colors.Ink,
		Size = UDim2.fromOffset(100, CHIP_H),
		LayoutOrder = index,
		Visible = false,
	})
	Theme.Corner(frame, UDim.new(0, 8))
	local stroke = Theme.Stroke(frame, Colors.PanelLight, 1.5, 0.35)
	local name = newText(frame, "Name", "", "Body", M.NameText, WHITE, {
		Position = UDim2.new(0, 7, 0, 0),
		Size = UDim2.new(1, -30, 1, withHealth and -4 or 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.45,
	})
	local state = newText(frame, "State", "", "Heading", 13, WHITE, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 0),
		Size = UDim2.fromOffset(20, withHealth and (CHIP_H - 4) or CHIP_H),
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	local fill = nil
	if withHealth then
		local track_ = newFrame(frame, "HpTrack", {
			Position = UDim2.new(0, 7, 1, -6),
			Size = UDim2.new(1, -14, 0, 4),
			BackgroundTransparency = 0.2,
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
	local gap = 4
	local cellW = math.floor((width - gap * (cols - 1)) / cols)
	local rows = math.max(1, math.ceil(count / cols))
	for i, chip in ipairs(chips) do
		if i <= count then
			local col = (i - 1) % cols
			local row = math.floor((i - 1) / cols)
			chip.Frame.Position = UDim2.fromOffset(col * (cellW + gap), row * ROW_PITCH)
			chip.Frame.Size = UDim2.fromOffset(cellW, CHIP_H)
			chip.Frame.Visible = true
		else
			chip.Frame.Visible = false
		end
	end
	return rows
end

----------------------------------------------------------------------
-- Build: match panel (top-left)
----------------------------------------------------------------------
-- Panel heights without team rows are M.MatchBaseH / M.PartyBaseH (110 / 96 on desktop), see panelMetrics().
local function buildMatch(holder)
	local panel = CloudUI.Panel({
		Name = "MatchPanel",
		Size = UDim2.fromOffset(PANEL_W, M.MatchBaseH + ROW_PITCH),
		Accent = Colors.Stamina,
		Parent = holder,
	})
	panel.Body.Active = false -- the HUD never swallows camera drags
	addViewportScale(panel.Root)
	UI.Match = panel
	Items.Match = newItem(panel.Root, UDim2.new(-1.5, 0, 0, 0))

	local inner = newFrame(panel.Content, "Inner", {
		Position = UDim2.new(0, 8, 0, 4),
		Size = UDim2.new(1, -16, 1, -8),
	})
	UI.MatchInner = inner

	-- row A: difficulty (+ stars) and the Leave button
	UI.MatchTitle = newText(inner, "Difficulty", "", "Title", 19, WHITE, {
		Size = UDim2.new(1, -(M.LeaveW + 8), 0, 22),
		RichText = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.2,
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
	UI.Timer = newText(inner, "Timer", "0:00", "Display", 26, WHITE, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0, 36),
		Size = UDim2.new(0.5, 0, 0, 28),
		Stroke = 0.2,
	})
	UI.TimerScale = newScale(UI.Timer, 1)
	UI.MatchTokens = newText(inner, "Tokens", "", "Toast", 16, Colors.TokenGlow, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -M.TokensInset, 0, 36),
		Size = UDim2.new(0.52, 0, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Right,
		Stroke = 0.2,
	})
	UI.TokensScale = newScale(UI.MatchTokens, 1)

	-- checkpoint progress
	UI.CpBar = CloudUI.Bar({
		Name = "CheckpointBar",
		Height = M.CpH,
		Color = Colors.Stamina,
		Label = "Checkpoint 0/0",
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.new(1, 0, 0, M.CpH),
		Parent = inner,
	})
	if M.CpText and UI.CpBar.Label then
		UI.CpBar.Label.TextSize = M.CpText -- the bar's own pick (height - 8, at least 11) is too small at phone scale
	end

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
		Size = UDim2.fromOffset(PANEL_W, M.PartyBaseH + ROW_PITCH),
		Accent = Colors.Good,
		Parent = holder,
	})
	panel.Body.Active = false
	addViewportScale(panel.Root)
	UI.Party = panel
	Items.Party = newItem(panel.Root, UDim2.new(-1.5, 0, 0, 0))

	local inner = newFrame(panel.Content, "Inner", {
		Position = UDim2.new(0, 8, 0, 4),
		Size = UDim2.new(1, -16, 1, -8),
	})
	UI.PartyInner = inner

	UI.PartyTitle = newText(inner, "Title", "Party", "Title", 19, WHITE, {
		Size = UDim2.new(1, -(M.LeaveW + 8), 0, 22),
		RichText = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.2,
	})
	CloudUI.Button({
		Name = "LeaveParty",
		Text = "Leave",
		Style = "Pink",
		TextSize = M.LeaveText,
		Size = UDim2.fromOffset(M.LeaveW, M.LeaveH),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -M.LeaveW / 2, 0, M.LeaveH / 2),
		Callback = function()
			fireRemote("LeaveParty")
		end,
		Parent = inner,
	})
	UI.PartyTeam = newFrame(inner, "Players", {
		Position = UDim2.fromOffset(0, M.PartyTeamY),
		Size = UDim2.new(1, 0, 0, ROW_PITCH),
	})
	UI.PartyStatus = newText(inner, "Status", "Waiting for players...", "Toast", 16, Colors.TokenGlow, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, -52, 0, 22),
		Stroke = 0.2,
	})
	UI.PartyStatusScale = newScale(UI.PartyStatus, 1)
	UI.PartyCount = newText(inner, "Count", "0/4", "Heading", 15, MUTED, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, 0),
		Size = UDim2.fromOffset(50, 22),
		TextXAlignment = Enum.TextXAlignment.Right,
	})
end

----------------------------------------------------------------------
-- Build: title card (top-left, small)
----------------------------------------------------------------------
local function buildTitleCard(holder)
	local card = newFrame(holder, "TitleCard", {
		Size = UDim2.fromOffset(TITLE_W, TITLE_H),
		BackgroundTransparency = 0.12,
		BackgroundColor3 = WHITE, -- the gradient below supplies the colour
		Visible = false,
	})
	Theme.Corner(card, UDim.new(0, 16))
	Theme.Stroke(card, NAVY, 3, 0)
	Theme.Gradient(card, Colors.PanelLight, Colors.Panel, 90)
	addViewportScale(card)
	UI.TitleCard = card
	Items.Title = newItem(card, UDim2.new(-1.5, 0, 0, 0))

	-- a little gold cloud coin at the left
	local coin = newFrame(card, "Coin", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
		Size = UDim2.fromOffset(40, 40),
		BackgroundTransparency = 0,
		BackgroundColor3 = WHITE,
	})
	round(coin)
	Theme.Stroke(coin, NAVY, 3, 0)
	Theme.Gradient(coin, Colors.TokenGlow, Colors.Token, 90)
	newText(coin, "Glyph", "\226\152\129", "Display", 24, WHITE, {
		TextXAlignment = Enum.TextXAlignment.Center,
		Stroke = 0.1,
	})

	local title = newText(card, "Title", string.upper(tostring(Config.GameName)), "Title", 24, WHITE, {
		Position = UDim2.new(0, 56, 0, 6),
		Size = UDim2.new(1, -64, 0, 28),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.15,
	})
	Theme.Gradient(title, Colors.Cloud, Colors.TokenGlow, 90)
	newText(card, "Tagline", tostring(Config.Tagline), "Script", 14, Colors.Muted or Colors.Cloud, {
		Position = UDim2.new(0, 56, 0, 33),
		Size = UDim2.new(1, -64, 0, 18),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Stroke = 0.4,
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
	task.wait(TITLE_CARD_SECONDS)
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
		-- took damage: hold the trail a moment, flash the heart
		H.HoldUntil = os.clock() + 0.45
		pop(UI.HeartScale, 1.3, 0.35)
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
	if UI.HeartGlyph then
		UI.HeartGlyph.Text = downed and "!" or "\226\153\165"
	end
	H.ColorKey = nil -- repaint the bar
	refreshHealthText()
end

local function updateHealth(dt, now)
	if not UI.HpBar then
		return
	end
	-- the fill chases the target quickly, the trail waits and then drains
	local diff = H.Target - H.Fill
	if math.abs(diff) > 0.0005 then
		H.Fill = H.Fill + diff * (1 - math.exp(-dt * 14))
	else
		H.Fill = H.Target
	end
	UI.HpBar.SetFraction(H.Fill, false)

	if H.Trail > H.Fill then
		if now >= H.HoldUntil then
			H.Trail = math.max(H.Fill, H.Trail - dt * 0.55)
		end
	else
		H.Trail = H.Fill
	end
	UI.Trail.Size = UDim2.fromScale(H.Trail, 1)

	-- colour: green -> amber -> red, red while downed
	local key = "ok"
	local color = Theme.HealthColor(H.Target)
	if S.downed then
		key = "down"
		color = Colors.Bad
	elseif H.Target <= LOW_HEALTH then
		key = "low"
	elseif H.Target <= 0.6 then
		key = "mid"
	end
	if key ~= H.ColorKey then
		H.ColorKey = key
		UI.HpBar.SetColor(color)
	end

	-- low-health heartbeat
	local low = (H.Target <= LOW_HEALTH) and not S.downed
	if low then
		local beat = math.max(0, math.sin(now * 7.5))
		UI.Heart.Rotation = math.sin(now * 3.7) * 3
		UI.HeartScale.Scale = 1 + 0.14 * beat * beat
		H.Low = true
	elseif H.Low then
		H.Low = false
		UI.Heart.Rotation = 0
		UI.HeartScale.Scale = 1
	end
	if S.downed then
		UI.DownedNotice.TextTransparency = 0.1 + 0.25 * (0.5 + 0.5 * math.sin(now * 5))
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
-- Stamina + dash pip
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

-- Fills the pip from the bottom: dark above `charge`, bright below it (a hard-stop gradient).
local function paintPip(charge, ready)
	local bright = ready and Theme.Lighten(Colors.Stamina, 0.15) or Colors.Stamina
	local dark = Theme.Darken(Colors.Stamina, 0.65)
	if charge >= 0.99 then
		UI.PipGradient.Color = ColorSequence.new(bright)
	elseif charge <= 0.01 then
		UI.PipGradient.Color = ColorSequence.new(dark)
	else
		local edge = 1 - charge
		UI.PipGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, dark),
			ColorSequenceKeypoint.new(edge, dark),
			ColorSequenceKeypoint.new(math.min(0.999, edge + 0.001), bright),
			ColorSequenceKeypoint.new(1, bright),
		})
	end
end

local function updateStamina(dt, now)
	if not UI.StBar then
		return
	end
	local maxSt = Config.Physics.MaxStamina or 100
	local value = player:GetAttribute(Config.Attr.Stamina)
	if type(value) ~= "number" then
		value = maxSt
	end
	local target = Util.Clamp(value / maxSt, 0, 1)
	St.Frac = St.Frac + (target - St.Frac) * (1 - math.exp(-dt * 18))
	if math.abs(target - St.Frac) < 0.002 then
		St.Frac = target
	end
	UI.StBar.SetFraction(St.Frac, false)

	local low = target < 0.15
	if low or St.LowColor then
		St.LowColor = low
		local color = Colors.Stamina
		if low then
			color = Colors.Stamina:Lerp(Colors.HealthLow, 0.5 + 0.5 * math.sin(now * 10))
		end
		UI.StBar.SetColor(color)
	end

	-- dash pip: fills as the cooldown elapses and as stamina refills enough for a dash
	local cd = dashCooldownFraction(now)
	local cost = Config.Physics.DashStaminaCost or 35
	local afford = Util.Clamp(value / cost, 0, 1)
	local charge = (1 - cd) * afford
	local ready = (cd <= 0.001) and (value >= cost)
	if math.abs(charge - St.Charge) > 0.02 or ready ~= St.PipReady then
		St.Charge = charge
		paintPip(charge, ready)
		UI.PipStroke.Color = ready and Theme.Lighten(Colors.Stamina, 0.2) or NAVY
		UI.PipGlyph.TextTransparency = ready and 0 or 0.4
		if ready and not St.PipReady then
			pop(UI.PipScale, 1.35, 0.3)
		end
		St.PipReady = ready
	end
end

----------------------------------------------------------------------
-- Cloud tokens
----------------------------------------------------------------------
local function readTokens()
	local value = nil
	if State then
		local ok, result = pcall(State.Tokens)
		if ok then
			value = result
		end
	end
	if type(value) ~= "number" then
		value = tonumber(player:GetAttribute(Config.Attr.Tokens)) or 0
	end
	return math.max(0, math.floor(value))
end

local function matchTokensNow()
	return math.max(0, math.floor(tonumber(player:GetAttribute(Config.Attr.MatchTokens)) or 0))
end

local function inMatchNow()
	return S.match ~= nil or player:GetAttribute(Config.Attr.InMatch) == true
end

-- The number shrinks to fit the room left beside the optional "+n" chip.
local function setCountText(n)
	local text = Util.Commas(n)
	local avail = PILL_W - (PILL_H + 4) - 10
	if UI.RunChip.Visible then
		avail = avail - 70
	end
	local size = Util.Clamp(math.floor(avail / (math.max(1, #text) * 0.56)), 14, 26)
	UI.TokenCount.Text = text
	UI.TokenCount.TextSize = size
end

local function refreshRunChip()
	local inMatch = inMatchNow()
	if inMatch ~= UI.RunChip.Visible then
		UI.RunChip.Visible = inMatch
		setCountText(Tk.Shown or Tk.Display)
	end
	local count = matchTokensNow()
	if count ~= Tk.RunSeen then
		local grew = count > Tk.RunSeen
		Tk.RunSeen = count
		UI.RunLabel.Text = "+" .. Util.Commas(count)
		if grew then
			pop(UI.RunScale, 1.3, 0.35)
		end
	end
end

local function onTokensChanged()
	local v = readTokens()
	local early = (os.clock() - startedAt) < 4 -- the saved total arrives right after joining: no fanfare
	if not Tk.Seen or early or v < Tk.Target then
		Tk.Seen = true
		Tk.Target = v
		Tk.Display = v
		return
	end
	if v > Tk.Target then
		Tk.Target = v
		pop(UI.CoinScale, 1.3, 0.4)
		pop(UI.CountScale, 1.2, 0.4)
	end
end

local function updateTokens(dt)
	local diff = Tk.Target - Tk.Display
	if diff ~= 0 then
		Tk.Display = Tk.Display + diff * (1 - math.exp(-dt * 7))
		if math.abs(Tk.Target - Tk.Display) < 0.5 then
			Tk.Display = Tk.Target
		end
	end
	local shown = math.floor(Tk.Display + 0.5)
	if shown ~= Tk.Shown then
		Tk.Shown = shown
		setCountText(shown)
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

local function resizePanel(panel, base, rows)
	local h = base + rows * ROW_PITCH
	panel.Root.Size = UDim2.fromOffset(PANEL_W, h)
	-- a taller panel may now reach the menu column (or a shorter one no longer does)
	applyMargins(true)
end

local function updateTeam(members)
	local count = math.min(#members, 4)
	ensureChips(Mt.Chips, UI.Team, count, true)
	local rows = layoutChips(Mt.Chips, count, PANEL_W - 24 - 16)
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
		setTimerText(tostring(n), numeralColor(n), 32)
	elseif phase == "Playing" then
		if now < Mt.GoUntil then
			setTimerText("GO!", Colors.Good, 32)
			return
		end
		local color = WHITE
		if remaining <= 30 then
			color = Colors.Bad:Lerp(WHITE, 0.5 + 0.5 * math.sin(now * 6))
		elseif remaining <= 60 then
			color = Colors.HealthMid
		end
		setTimerText(Util.FormatTime(remaining), color, 26)
	else
		setTimerText("Match over", Colors.Muted or WHITE, 22)
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
	LM.ArmedUntil = now + LEAVE_CONFIRM_SECONDS
	button.Text = "Sure?"
	CloudUI.SetStyle(button, "Red")
	task.delay(LEAVE_CONFIRM_SECONDS + 0.05, function()
		if LM.ArmedUntil > 0 and os.clock() >= LM.ArmedUntil then
			disarmLeave()
		end
	end)
end

local function refreshVisibility()
	local hasMatch = S.match ~= nil
	local showParty = S.party ~= nil and not hasMatch and player:GetAttribute(Config.Attr.InMatch) ~= true
	present(Items.Match, hasMatch)
	present(Items.Party, showParty)
	if hasMatch or showParty then
		hideTitleCard()
	end
	applyMargins(true) -- the top-left slot is taken or free: step aside for the menu column only when needed
	if UI.RunChip then
		refreshRunChip()
	end
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
		Mt.GoUntil = now + GO_SECONDS
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
	local diff = Config.GetDifficulty(state.DifficultyId)
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
		local left = math.max(0, math.ceil(Pt.Base - (now - Pt.At) - 0.001))
		return "Starting in " .. tostring(left) .. "s"
	elseif count >= max then
		return "Party full!"
	end
	return "Waiting for players..."
end

local function updatePartyClock(now)
	if not S.party or not UI.PartyStatus then
		return
	end
	local text = partyStatusText(now)
	if text ~= Pt.LastText then
		Pt.LastText = text
		UI.PartyStatus.Text = text
		if string.sub(text, 1, 8) == "Starting" then
			pop(UI.PartyStatusScale, 1.12, 0.25)
		end
	end
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
	UI.PartyTitle.Text = tostring(state.DifficultyName or "?") .. " Party"
	UI.PartyTitle.TextColor3 = Theme.Lighten(color, 0.25)

	local list = type(state.Players) == "table" and state.Players or {}
	local count = math.min(#list, 4)
	ensureChips(Pt.Chips, UI.PartyTeam, count, false)
	local rows = layoutChips(Pt.Chips, count, PANEL_W - 24 - 16)
	if rows ~= Pt.Rows then
		Pt.Rows = rows
		UI.PartyTeam.Size = UDim2.new(1, 0, 0, rows * ROW_PITCH)
		UI.PartyStatus.Position = UDim2.new(0, 0, 1, 0)
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

----------------------------------------------------------------------
-- Frame loop
----------------------------------------------------------------------
local function onRender(dt)
	local now = os.clock()
	guard("health", updateHealth, dt, now)
	guard("stamina", updateStamina, dt, now)
	guard("tokens", updateTokens, dt)
	guard("match clock", updateMatchClock, now)
	guard("party clock", updatePartyClock, now)
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

	buildVitals(bottomLeft)
	buildTokens(topRight)
	buildMatch(topLeft)
	buildParty(topLeft)
	buildTitleCard(topLeft)
	applyMargins()
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
			end)
		end
		guard("relayout", relayout)
	end
	track(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bind))
	bind()
	-- the viewport can still be 1x1 right at startup: re-check shortly afterwards
	task.delay(0.5, function()
		guard("relayout", relayout)
	end)
	task.delay(2, function()
		guard("relayout", relayout)
	end)
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
	track(player:GetAttributeChangedSignal(attr.Tokens):Connect(function()
		guard("tokens attr", onTokensChanged)
	end))
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
		setDowned(player:GetAttribute(attr.Downed) == true)
	end))
	if State and State.TokensChanged then
		pcall(function()
			track(State.TokensChanged:Connect(function()
				guard("tokens attr", onTokensChanged)
			end))
		end)
	end
	onTokensChanged() -- snaps the counter to the current value (or 0)
	Tk.Seen = (player:GetAttribute(attr.Tokens) ~= nil) -- no attribute yet: snap to the saved total when it lands
	Tk.Shown = nil
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
