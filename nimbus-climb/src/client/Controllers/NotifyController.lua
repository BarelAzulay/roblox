-- NotifyController (client, v3): the game's side-of-screen voice. Nothing here is ever centred.
--
--   NotifyController.Init()
--
-- Remotes handled
--   Notify(text, kind, duration)  -> compact toast stack on the RIGHT edge, from the top (below the HUD currency
--                                    stack when that sits top-right on a short screen, and below the top-left
--                                    panel on a narrow one). Max 4, 250 design px wide, newest on top, slide in
--                                    from the right, `Toast` role font at the readable 18 px, a coloured accent
--                                    bar + icon by kind (info|good|bad|token). Identical toasts that are still
--                                    showing are merged into "text x2".
--   MatchResult(result)           -> compact result card on the right edge (about 45% down): VICTORY!/DEFEAT in
--                                    the Title font with a gradient, difficulty + stars, time, tokens, bonus,
--                                    a small member list and a "Back to lobby in Ns" line. It closes when the
--                                    server clears MatchState (the player is back in the lobby), when the
--                                    player presses its X, or a few seconds after the countdown ends.
--   MatchState(nil)               -> closes the result card.
--   DashFx(userId)                -> a cheap puff + trail on that player's character (own dashes are ignored,
--                                    MovementController already shows those).
--
-- The GUI is "NimbusNotify" (display order 30, IgnoreGuiInset = false). Sizes follow the v3 readability rule:
-- panels are designed in 1080p pixels and carry a UIScale of Theme.ScreenFactor() (same as the HUD), inside
-- full-screen holder frames whose UIPadding is the screen margin, so scaling never detaches them from the edge.
-- Where the HUD sits is read from the attributes HudController publishes on the NimbusHud gui.
-- Plain Lua 5.1-compatible syntax only. All fonts come from Theme roles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent.Parent
local CloudUI = require(Client:WaitForChild("UI"):WaitForChild("CloudUI"))

local NotifyController = {}

local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------------------
-- Tuning (design px of a 1080p screen)
----------------------------------------------------------------------
-- toasts
local MAX_TOASTS = 4
local TOAST_W = 250
local TOAST_GAP = 8
local TOAST_TEXT_SIZE = 18
local TOAST_ICON = 30
local TOAST_BG = 0.06
local DEFAULT_DURATION = 3
local MIN_DURATION = 1.5
local MAX_DURATION = 8
local MAX_TOAST_CHARS = 90
local MIN_TOAST_H = 52 -- a one-line toast (design px)

-- KEEP IN SYNC with HudController.lua: EDGE and TOUCH_EDGE.
local EDGE = 12
local TOUCH_EDGE = 20
local HUD_GAP = 10 -- kept below the HUD pieces the stack has to clear

-- result card
local RESULT_W = 290
local RESULT_Y = 0.47 -- vertical position (fraction of the screen), right edge
-- On narrow (portrait) screens the scaled card reaches into the middle of the screen. The game must never say
-- anything there, so the card moves up until it sits above this central band (fractions of the screen size).
local CENTRE_BAND = 0.15
local CENTRE_MARGIN = 6
local CONFETTI_PIECES = 22

-- dash puffs of other players
local FX_MAX_DISTANCE = 140
local FX_MIN_INTERVAL = 0.2
local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"

local Colors = Theme.Colors
local WHITE = Colors.White
local NAVY = Colors.Navy or Colors.Ink
local MUTED = Colors.Muted or Colors.CloudShade
local GOLD = Colors.Gold or Colors.Token
local INK = Colors.TextStroke or Colors.Ink

local FALLBACK_KINDS = {
	info = Color3.fromRGB(90, 158, 234),
	good = Color3.fromRGB(96, 196, 108),
	bad = Color3.fromRGB(228, 90, 92),
	token = Color3.fromRGB(240, 188, 66),
}
local KIND_GLYPH = {
	info = "i",
	good = "\226\156\148", -- check mark
	bad = "!",
	token = "\226\152\129", -- cloud
}

local REASON_TEXT = {
	defeat = "The whole team went down",
	timeout = "Out of time",
	abandoned = "Match abandoned",
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local initialized = false
local rng = Random.new()
local UI = {} -- Gui, Stack, StackScale, ToastPad, ResultPad, ResultHolder
local scalers = {}
local toasts = {} -- live toasts, oldest first
local toastSerial = 0
local result = { Panel = nil, Serial = 0, Height = 0 } -- the open result card (Height: design px)
local lastDashFx = {}
local hud = { Gui = nil, Conn = nil } -- the NimbusHud gui whose layout attributes we follow

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local tween = Util.Tween

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

-- The readability factor: clamp(viewportY / 1080, 0.8, 1.25) (the HUD uses the same).
local function currentScale()
	return Theme.ScreenFactor(viewportSize().Y)
end

local function topInset()
	local okInset, inset = pcall(GuiService.GetGuiInset, GuiService)
	return (okInset and inset and inset.Y) or 0
end

local function hex(color)
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

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

-- Themed TextLabel. props may include Stroke (classic text stroke transparency), StrokeColor and Outline
-- (thickness of a glyph outline, Theme.TextOutline) plus any label property.
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
	if props then
		for key, value in pairs(props) do
			if key == "Stroke" then
				stroke = value
			elseif key == "StrokeColor" then
				strokeColor = value
			elseif key == "Outline" then
				outline = value
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
		OutlineColor = strokeColor or INK,
		Props = extra,
	})
	label.Parent = parent
	return label
end

local function round(inst)
	return Theme.Corner(inst, UDim.new(0.5, 0))
end

local function addViewportScale(root)
	local s = Instance.new("UIScale")
	s.Name = "ViewportScale"
	s.Scale = currentScale()
	s.Parent = root
	table.insert(scalers, s)
	return s
end

local function kindColor(kind)
	local name = "info"
	if type(kind) == "string" and FALLBACK_KINDS[string.lower(kind)] then
		name = string.lower(kind)
	end
	local fromTheme = Theme.Kinds and Theme.Kinds[name]
	return fromTheme or FALLBACK_KINDS[name], name
end

-- Cut a string to `maxChars` characters (UTF-8 aware) and add "..." when it was longer.
local function truncateText(text, maxChars)
	text = tostring(text or "")
	local okLen, len = pcall(utf8.len, text)
	if okLen and len then
		if len <= maxChars then
			return text
		end
		local okOff, offset = pcall(utf8.offset, text, maxChars + 1)
		if okOff and offset then
			return string.sub(text, 1, offset - 1) .. "..."
		end
	end
	if #text <= maxChars then
		return text
	end
	return string.sub(text, 1, maxChars) .. "..."
end

-- A transparent full-screen frame whose UIPadding is the screen margin.
local function newHolder(name)
	local holder = newFrame(UI.Gui, name, { Size = UDim2.fromScale(1, 1) })
	local pad = Instance.new("UIPadding")
	pad.Parent = holder
	return holder, pad
end

-- One layout attribute HudController publishes on NimbusHud (gui-area pixels, 0 = nothing there).
local function hudValue(name)
	local gui = hud.Gui
	if not gui or not gui.Parent then
		return 0
	end
	local value = gui:GetAttribute(name)
	if type(value) == "number" then
		return value
	end
	return 0
end

-- Lowest gui y a toast column whose left edge is at `toastLeft` (right edge `toastRight`) may reach: above the
-- centre band when the column reaches into it sideways (portrait phones), above the touch RUN / DASH buttons
-- under the column, and never into the lower quarter of the screen.
local function bottomLimitFor(toastLeft, toastRight)
	local vp = viewportSize()
	local inset = topInset()
	local limit = (vp.Y - inset) * 0.72
	if toastLeft < vp.X * (0.5 + CENTRE_BAND) and toastRight > vp.X * (0.5 - CENTRE_BAND) then
		limit = math.min(limit, vp.Y * (0.5 - CENTRE_BAND) - CENTRE_MARGIN - inset)
	end
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local mobile = playerGui and playerGui:FindFirstChild("MobileControls")
	if mobile and mobile:IsA("ScreenGui") and mobile.Enabled then
		local dy = mobile.IgnoreGuiInset and -inset or 0
		for _, d in ipairs(mobile:GetDescendants()) do
			if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and d.AbsoluteSize.X > 0 then
				local x0 = d.AbsolutePosition.X
				local x1 = x0 + d.AbsoluteSize.X
				if x1 > toastLeft and x0 < toastRight then
					limit = math.min(limit, d.AbsolutePosition.Y + dy - TOAST_GAP)
				end
			end
		end
	end
	return limit
end

-- Where the toast column goes: { Top, Right (padding from the right edge), Bottom (lowest y) } in gui px.
-- Normally the top-right corner (below the HUD's currency stack when that sits there). On a short screen
-- where not even one toast fits between that stack and the touch buttons, the column moves to the left of
-- the stack instead; on a narrow screen it also stays below the top-left panel when the two would overlap.
local function toastPlacement()
	local side = isTouchDevice() and TOUCH_EDGE or EDGE
	local k = currentScale()
	local vp = viewportSize()
	local width = TOAST_W * k
	local right = side
	local top = EDGE
	local rightBottom = hudValue("TopRightBottom")
	if rightBottom > 0 then
		top = rightBottom + HUD_GAP
		local left = vp.X - right - width
		local room = (bottomLimitFor(left, vp.X - right) - top) / math.max(0.01, k)
		local stackLeft = hudValue("TopRightLeft")
		if room < MIN_TOAST_H and stackLeft > 0 then
			right = math.max(side, vp.X - stackLeft + HUD_GAP)
			top = EDGE
		end
	end
	local toastLeft = vp.X - right - width
	local leftRight = hudValue("TopLeftRight")
	if leftRight > 0 and leftRight > toastLeft - 4 then
		top = math.max(top, hudValue("TopLeftBottom") + HUD_GAP)
	end
	return {
		Top = math.floor(top),
		Right = math.floor(right),
		Bottom = bottomLimitFor(toastLeft, vp.X - right),
	}
end

-- Conservative height of a toast in design px (wide glyphs, word wrap slack).
local function estimateToastHeight(text)
	local width = TOAST_W - 24 - (TOAST_ICON + 10)
	local perLine = math.max(1, math.floor(width / (TOAST_TEXT_SIZE * 0.62)))
	local okLen, len = pcall(utf8.len, tostring(text or ""))
	if not okLen or type(len) ~= "number" then
		len = #tostring(text or "")
	end
	local lines = math.max(1, math.ceil(len / perLine))
	return math.max(44, lines * math.ceil(TOAST_TEXT_SIZE * 1.15) + 16)
end

local dismissToast -- defined below

-- Keeps the newest toasts that fit above the column's lowest allowed y (always at least the newest one).
local function trimToasts()
	if #toasts == 0 then
		return
	end
	local k = currentScale()
	local place = toastPlacement()
	local budget = (place.Bottom - place.Top) / math.max(0.01, k)
	local used = 0
	local kept = 0
	local drop = {}
	for i = #toasts, 1, -1 do -- newest first
		local toast = toasts[i]
		local h = estimateToastHeight(toast.Label.Text)
		if kept > 0 then
			h = h + TOAST_GAP
		end
		if kept >= 1 and used + h > budget then
			for j = i, 1, -1 do
				table.insert(drop, toasts[j])
			end
			break
		end
		used = used + h
		kept = kept + 1
	end
	for _, toast in ipairs(drop) do
		dismissToast(toast)
	end
end

local function applyMargins()
	local side = isTouchDevice() and TOUCH_EDGE or EDGE
	if UI.ToastPad then
		local place = toastPlacement()
		UI.ToastPad.PaddingRight = UDim.new(0, place.Right)
		UI.ToastPad.PaddingTop = UDim.new(0, place.Top)
	end
	if UI.ResultPad then
		UI.ResultPad.PaddingRight = UDim.new(0, side)
	end
end

-- Position of the (right-edge) result card: `xScale` 1 = on screen, > 1 = parked off screen. The card sits at
-- RESULT_Y of the screen height; when the screen is so narrow that the scaled card reaches into the centre band
-- it is lifted above that band instead (never below it: the thumb controls live there).
local function resultPosition(xScale, panelHeight)
	local vp = viewportSize()
	local k = currentScale()
	local side = isTouchDevice() and TOUCH_EDGE or EDGE
	local cardLeft = vp.X - side - RESULT_W * k
	local half = (panelHeight or result.Height) * k / 2
	if cardLeft >= vp.X * (0.5 + CENTRE_BAND) then
		-- keep clear of a top-right currency stack on short screens
		local floorY = hudValue("TopRightBottom") + HUD_GAP + half
		local y = (vp.Y - topInset()) * RESULT_Y
		if y >= floorY then
			return UDim2.new(xScale, 0, RESULT_Y, 0)
		end
		return UDim2.new(xScale, 0, 0, math.floor(floorY))
	end
	-- the ScreenGui area starts below the top bar (IgnoreGuiInset = false), so gui y = screen y - inset
	local ceiling = vp.Y * (0.5 - CENTRE_BAND) - CENTRE_MARGIN - half - topInset()
	local floorY = math.max(EDGE, hudValue("TopRightBottom") + HUD_GAP) + half
	return UDim2.new(xScale, 0, 0, math.floor(math.max(ceiling, floorY)))
end

-- Tells the HUD where the open result card starts (gui x of its left edge; 0 = no card), so on a narrow
-- screen it can tuck the match panel away instead of drawing both on top of each other.
local function publishResultCard()
	if not UI.Gui then
		return
	end
	local value = 0
	if result.Panel and result.Panel.Root and result.Panel.Root.Parent then
		local side = isTouchDevice() and TOUCH_EDGE or EDGE
		value = math.floor(viewportSize().X - side - RESULT_W * currentScale())
	end
	if UI.Gui:GetAttribute("ResultCardLeft") ~= value then
		UI.Gui:SetAttribute("ResultCardLeft", value)
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
	applyMargins()
	trimToasts()
	local panel = result.Panel
	if panel and panel.Root and panel.Root.Parent then
		panel.Root.Position = resultPosition(1)
	end
	publishResultCard()
end

-- Follow the HUD's layout attributes (the HUD may be built before or after us, and rebuilt).
local function bindHud(gui)
	if hud.Gui == gui then
		return
	end
	if hud.Conn then
		hud.Conn:Disconnect()
		hud.Conn = nil
	end
	hud.Gui = gui
	if gui then
		hud.Conn = gui.AttributeChanged:Connect(function()
			pcall(relayout)
		end)
	end
	pcall(relayout)
end

local function watchHud()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end
	local existing = playerGui:FindFirstChild("NimbusHud")
	if existing and existing:IsA("ScreenGui") then
		bindHud(existing)
	end
	playerGui.ChildAdded:Connect(function(child)
		if child.Name == "NimbusHud" and child:IsA("ScreenGui") then
			bindHud(child)
		end
	end)
end

----------------------------------------------------------------------
-- Toasts
----------------------------------------------------------------------
-- a = 0 fully visible .. 1 fully faded
local function setToastAlpha(toast, a, seconds)
	local goals = {
		{ toast.Card, { BackgroundTransparency = TOAST_BG + (1 - TOAST_BG) * a } },
		{ toast.Stroke, { Transparency = a } },
		{ toast.Accent, { BackgroundTransparency = a } },
		{ toast.Label, { TextTransparency = a, TextStrokeTransparency = 0.3 + 0.7 * a } },
		{ toast.Icon, { BackgroundTransparency = a } },
		{ toast.IconStroke, { Transparency = a } },
		{ toast.IconGlyph, { TextTransparency = a, TextStrokeTransparency = 0.2 + 0.8 * a } },
	}
	for _, entry in ipairs(goals) do
		if entry[1] then
			if seconds and seconds > 0 then
				tween(entry[1], seconds, entry[2], Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			else
				for key, value in pairs(entry[2]) do
					entry[1][key] = value
				end
			end
		end
	end
end

function dismissToast(toast)
	if toast.Dead then
		return
	end
	toast.Dead = true
	for i, live in ipairs(toasts) do
		if live == toast then
			table.remove(toasts, i)
			break
		end
	end
	tween(toast.Card, 0.22, { Position = UDim2.new(0, TOAST_W + 40, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	setToastAlpha(toast, 1, 0.22)
	task.delay(0.25, function()
		local slot = toast.Slot
		if not slot or not slot.Parent then
			return
		end
		-- collapse the gap smoothly instead of popping the stack
		local scale = UI.StackScale and UI.StackScale.Scale or 1
		local height = slot.AbsoluteSize.Y / math.max(0.01, scale)
		slot.AutomaticSize = Enum.AutomaticSize.None
		slot.Size = UDim2.new(1, 0, 0, height)
		tween(slot, 0.15, { Size = UDim2.new(1, 0, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		task.delay(0.18, function()
			if slot.Parent then
				slot:Destroy()
			end
		end)
	end)
end

local function scheduleExpiry(toast, duration)
	toast.Expiry = os.clock() + duration
	task.delay(duration + 0.02, function()
		if not toast.Dead and os.clock() >= toast.Expiry then
			dismissToast(toast)
		end
	end)
end

local function refreshToastText(toast)
	local text = toast.Text
	if toast.Count > 1 then
		text = text .. "  x" .. tostring(toast.Count)
	end
	toast.Label.Text = text
end

local function toastTextColor(color)
	return Theme.Lighten(color, 0.55)
end

local function buildToast(text, kind)
	local color, kindName = kindColor(kind)
	toastSerial = toastSerial + 1

	-- the slot is the list item (it keeps its place while the card slides); the card is what moves
	local slot = newFrame(UI.Stack, "ToastSlot", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = -toastSerial, -- newest on top
	})
	local card = newFrame(slot, "Toast", {
		Position = UDim2.new(0, TOAST_W + 40, 0, 0),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BackgroundColor3 = Colors.Panel,
	})
	Theme.Corner(card, UDim.new(0, 12))
	local stroke = Theme.Stroke(card, Theme.Darken(color, 0.25), 2.5, 1)
	Util.Create("UISizeConstraint", { MinSize = Vector2.new(0, 44), Parent = card })
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = card

	-- coloured accent bar at the left edge (inside the padding box, pulled out towards the card edge)
	local accent = newFrame(card, "Accent", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, -10, 0.5, 0),
		Size = UDim2.fromOffset(5, TOAST_ICON),
		BackgroundTransparency = 1,
		BackgroundColor3 = color,
	})
	round(accent)

	local icon = newFrame(card, "Icon", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(TOAST_ICON, TOAST_ICON),
		BackgroundTransparency = 1,
		BackgroundColor3 = Theme.Darken(color, 0.1),
	})
	round(icon)
	local iconStroke = Theme.Stroke(icon, Theme.Darken(color, 0.55), 2, 1)
	local glyph = newText(icon, "Glyph", KIND_GLYPH[kindName] or "i", "Heading", 18, WHITE, {
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
		StrokeColor = Theme.Darken(color, 0.6),
		Stroke = 1,
	})

	local label = newText(card, "Text", text, "Toast", TOAST_TEXT_SIZE, toastTextColor(color), {
		Position = UDim2.new(0, TOAST_ICON + 10, 0, 0),
		Size = UDim2.new(1, -(TOAST_ICON + 10), 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextTransparency = 1,
		StrokeColor = INK,
		Stroke = 1,
	})

	return {
		Slot = slot, Card = card, Stroke = stroke, Accent = accent, Icon = icon, IconStroke = iconStroke,
		IconGlyph = glyph, Label = label, Text = text, Kind = kindName, Count = 1, Dead = false, Expiry = 0,
		Color = color,
	}
end

local function addToast(text, kind, duration)
	if not UI.Stack then
		return
	end
	text = truncateText(text, MAX_TOAST_CHARS)
	if text == "" then
		return
	end
	duration = Util.Clamp(tonumber(duration) or DEFAULT_DURATION, MIN_DURATION, MAX_DURATION)

	-- merge an identical toast that is still showing
	local _, kindName = kindColor(kind)
	for _, live in ipairs(toasts) do
		if not live.Dead and live.Text == text and live.Kind == kindName then
			live.Count = live.Count + 1
			refreshToastText(live)
			live.Label.TextColor3 = WHITE
			tween(live.Label, 0.35, { TextColor3 = toastTextColor(live.Color) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			scheduleExpiry(live, duration)
			return
		end
	end

	local toast = buildToast(text, kind)
	table.insert(toasts, toast)
	-- never more than MAX_TOASTS (and never further down than the screen allows): the oldest leave first
	while #toasts > MAX_TOASTS do
		dismissToast(toasts[1])
	end
	trimToasts()

	toast.Card.Position = UDim2.new(0, TOAST_W + 40, 0, 0)
	tween(toast.Card, 0.38, { Position = UDim2.new(0, 0, 0, 0) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	setToastAlpha(toast, 0, 0.2)
	scheduleExpiry(toast, duration)
end

local function buildToastStack()
	local holder, pad = newHolder("ToastHolder")
	UI.ToastPad = pad
	local stack = newFrame(holder, "ToastStack", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(TOAST_W, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.VerticalAlignment = Enum.VerticalAlignment.Top
	list.Padding = UDim.new(0, TOAST_GAP)
	list.Parent = stack
	UI.Stack = stack
	UI.StackScale = addViewportScale(stack)
end

----------------------------------------------------------------------
-- Result card
----------------------------------------------------------------------
local function closeResults(immediate)
	local panel = result.Panel
	result.Serial = result.Serial + 1
	result.Panel = nil
	publishResultCard()
	if not panel or not panel.Root or not panel.Root.Parent then
		return
	end
	if immediate then
		panel.Destroy()
		return
	end
	tween(panel.Root, 0.3, { Position = resultPosition(1.8) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.35, function()
		if panel.Root.Parent then
			panel.Destroy()
		end
	end)
end

-- Count a label up from 0 to `target`. The serial stops it if the card closed meanwhile.
local function countUp(label, target, delay, seconds, format, serial)
	task.spawn(function()
		task.wait(delay)
		local started = os.clock()
		while true do
			if result.Serial ~= serial or not label.Parent then
				return
			end
			local a = (os.clock() - started) / seconds
			if a >= 1 then
				label.Text = format(target)
				return
			end
			local eased = 1 - (1 - a) * (1 - a) * (1 - a)
			label.Text = format(math.floor(target * eased + 0.5))
			task.wait(0.03)
		end
	end)
end

-- Square "pixel" confetti (the voxel world's little sparkle) falling over the card.
local function burstConfetti(root, serial)
	local palette = Theme.World and Theme.World.Rainbow or Colors.Rainbow
	for i = 1, CONFETTI_PIECES do
		local x = rng:NextNumber(0.06, 0.94)
		local startY = rng:NextNumber(-6, 18)
		local px = rng:NextInteger(6, 10)
		local piece = newFrame(root, "Confetti", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(x, 0, 0, startY),
			Size = UDim2.fromOffset(px, px),
			BackgroundTransparency = 1,
			BackgroundColor3 = palette[(i % #palette) + 1],
			Rotation = rng:NextInteger(0, 3) * 90,
			ZIndex = 12,
		})
		task.delay(rng:NextNumber(0.2, 0.7), function()
			if result.Serial ~= serial or not piece.Parent then
				return
			end
			piece.BackgroundTransparency = 0
			local fall = rng:NextNumber(130, 220)
			tween(piece, rng:NextNumber(0.9, 1.4), {
				Position = UDim2.new(Util.Clamp(x + rng:NextNumber(-0.12, 0.12), 0.02, 0.98), 0, 0, startY + fall),
				Rotation = piece.Rotation + rng:NextInteger(-2, 2) * 90,
				BackgroundTransparency = 1,
			}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(1.5, function()
				if piece.Parent then
					piece:Destroy()
				end
			end)
		end)
	end
end

local function normaliseMembers(list)
	local out = {}
	if type(list) == "table" then
		for _, m in ipairs(list) do
			if type(m) == "table" then
				table.insert(out, {
					Name = tostring(m.Name or "?"),
					Tokens = math.max(0, math.floor(tonumber(m.MatchTokens) or 0)),
					Finished = m.Finished == true,
					Downed = m.Downed == true,
				})
			end
			if #out >= 4 then
				break
			end
		end
	end
	return out
end

local function isLocalName(name)
	return name == LocalPlayer.Name or name == LocalPlayer.DisplayName
end

local function buildResults(data)
	local won = data.Won == true
	local diff = Config.GetDifficulty and Config.GetDifficulty(data.DifficultyId) or nil
	local diffColor = (diff and diff.Color) or Colors.Stamina
	local starCount = tonumber(data.Stars) or (diff and diff.Stars) or 0
	local members = normaliseMembers(data.Members)
	local showMembers = #members > 1
	local reason = (not won) and REASON_TEXT[tostring(data.Reason or "defeat")] or nil

	-- fixed vertical layout (inner coordinates)
	local TITLE_H, DIFF_H, REASON_H, ROW_H, MEMBER_H, FOOT_H = 46, 26, 24, 32, 26, 28
	local y = 0
	local titleY = y
	y = y + TITLE_H
	local diffY = y
	y = y + DIFF_H
	local reasonY = y
	if reason then
		y = y + REASON_H
	end
	y = y + 8
	local statsY = y
	y = y + ROW_H * 3 + 4
	local membersY = y
	if showMembers then
		y = y + #members * MEMBER_H + 6
	end
	local footY = y
	y = y + FOOT_H
	local insetTop, _, insetBottom = CloudUI.ContentInset(false, true)
	local panelH = insetTop + insetBottom + 10 + y
	result.Height = panelH

	local accent = won and (Theme.Buttons and Theme.Buttons.Gold or GOLD) or Color3.fromRGB(118, 130, 204)
	local panel = CloudUI.Panel({
		Name = "ResultCard",
		Size = UDim2.fromOffset(RESULT_W, panelH),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = resultPosition(1.8, panelH),
		Accent = accent,
		Closable = true,
		OnClose = function()
			closeResults(false)
		end,
		Parent = UI.ResultHolder,
	})
	panel.Body.Active = false
	addViewportScale(panel.Root)
	local inner = newFrame(panel.Content, "Inner", {
		Position = UDim2.new(0, 12, 0, 5),
		Size = UDim2.new(1, -24, 1, -10),
	})

	-- headline with a gradient (the label itself stays white, the gradient colours it)
	local headline = newText(inner, "Headline", won and "VICTORY!" or "DEFEAT", "Title", 40, WHITE, {
		Position = UDim2.fromOffset(0, titleY),
		Size = UDim2.new(1, 0, 0, TITLE_H),
		TextXAlignment = Enum.TextXAlignment.Center,
		Stroke = 0.1,
		Outline = 3,
	})
	if won then
		Theme.Gradient(headline, Colors.TokenGlow, Colors.Token, 90)
	else
		Theme.Gradient(headline, Color3.fromRGB(196, 208, 246), Color3.fromRGB(132, 142, 216), 90)
	end

	-- difficulty + stars
	local diffText = tostring(data.DifficultyName or data.DifficultyId or "")
	if starCount > 0 then
		diffText = diffText .. "  <font color=\"" .. hex(GOLD) .. "\">" .. string.rep("\226\152\133", math.min(5, starCount)) .. "</font>"
	end
	newText(inner, "Difficulty", diffText, "Heading", 21, Theme.Lighten(diffColor, 0.3), {
		Position = UDim2.fromOffset(0, diffY),
		Size = UDim2.new(1, 0, 0, DIFF_H),
		TextXAlignment = Enum.TextXAlignment.Center,
		RichText = true,
		Stroke = 0.2,
		Outline = 1.5,
	})
	if reason then
		newText(inner, "Reason", reason, "Body", 18, MUTED, {
			Position = UDim2.fromOffset(0, reasonY),
			Size = UDim2.new(1, 0, 0, REASON_H),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Stroke = 0.35,
		})
	end

	-- stats
	local serial = result.Serial
	local function statRow(index, caption, valueText, valueColor)
		local rowY = statsY + (index - 1) * ROW_H
		local bar = newFrame(inner, "Row" .. caption, {
			Position = UDim2.fromOffset(0, rowY),
			Size = UDim2.new(1, 0, 0, ROW_H - 4),
			BackgroundTransparency = 0.45,
			BackgroundColor3 = Colors.Ink,
		})
		Theme.Corner(bar, UDim.new(0, 9))
		newText(bar, "Caption", caption, "Body", 18, MUTED, {
			Position = UDim2.new(0, 10, 0, 0),
			Size = UDim2.new(0.45, 0, 1, 0),
			Stroke = 0.35,
		})
		return newText(bar, "Value", valueText, "Heading", 20, valueColor, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 0),
			Size = UDim2.new(0.55, 0, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			Stroke = 0.2,
			Outline = 1.5,
		})
	end

	-- MatchTokens is what was PAID OUT to this player (pet TokenBonus and rounding carry included), while
	-- TotalTokens is the course's raw token value, so the two must not be shown as "own / total" ("48 / 24"
	-- with a +100% pet). The row shows the personal payout on its own, like the member list below.
	local ownTokens = math.max(0, math.floor(tonumber(data.MatchTokens) or 0))
	local bonus = math.max(0, math.floor(tonumber(data.Bonus) or 0))
	local seconds = tonumber(data.Seconds) or 0

	statRow(1, "Time", Util.FormatTime(seconds), WHITE)
	local tokenValue = statRow(2, "Tokens", "0 \226\152\129", Colors.TokenGlow)
	local bonusValue = statRow(3, "Win bonus", bonus > 0 and "+0 \226\152\129" or "-", bonus > 0 and GOLD or MUTED)
	countUp(tokenValue, ownTokens, 0.45, 0.8, function(n)
		return tostring(n) .. " \226\152\129"
	end, serial)
	if bonus > 0 then
		countUp(bonusValue, bonus, 0.9, 0.7, function(n)
			return "+" .. tostring(n) .. " \226\152\129"
		end, serial)
	end

	-- members
	if showMembers then
		for i, m in ipairs(members) do
			local row = newFrame(inner, "Member" .. i, {
				Position = UDim2.fromOffset(0, membersY + (i - 1) * MEMBER_H),
				Size = UDim2.new(1, 0, 0, MEMBER_H),
			})
			local mine = isLocalName(m.Name)
			newText(row, "Name", m.Name, "Body", 18, mine and Colors.TokenGlow or WHITE, {
				Position = UDim2.new(0, 6, 0, 0),
				Size = UDim2.new(1, -104, 1, 0),
				TextTruncate = Enum.TextTruncate.AtEnd,
				Stroke = 0.35,
			})
			newText(row, "Tokens", "\226\152\129 " .. tostring(m.Tokens), "Heading", 18, Colors.TokenGlow, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -28, 0, 0),
				Size = UDim2.fromOffset(70, MEMBER_H),
				TextXAlignment = Enum.TextXAlignment.Right,
				Stroke = 0.3,
			})
			local stateText = ""
			local stateColor = WHITE
			if m.Finished then
				stateText = "\226\156\148"
				stateColor = Colors.Good
			elseif m.Downed then
				stateText = "\226\152\160" -- skull and crossbones
				stateColor = Colors.Bad
			end
			newText(row, "State", stateText, "Heading", 18, stateColor, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -4, 0, 0),
				Size = UDim2.fromOffset(20, MEMBER_H),
				TextXAlignment = Enum.TextXAlignment.Center,
				Stroke = 0.3,
			})
		end
	end

	-- footer: countdown to the lobby
	local footer = newText(inner, "Footer", "", "Toast", 19, Colors.Cloud, {
		Position = UDim2.fromOffset(0, footY),
		Size = UDim2.new(1, 0, 0, FOOT_H),
		TextXAlignment = Enum.TextXAlignment.Center,
		Stroke = 0.2,
		Outline = 1.5,
	})

	return panel, footer, serial
end

local function showResults(data)
	if type(data) ~= "table" or not UI.ResultHolder then
		return
	end
	closeResults(true)
	result.Serial = result.Serial + 1
	local ok, panel, footer, serial = pcall(buildResults, data)
	if not ok then
		warn("[NotifyController] result card failed: " .. tostring(panel))
		return
	end
	result.Panel = panel
	publishResultCard()

	tween(panel.Root, 0.5, { Position = resultPosition(1) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	if data.Won == true then
		burstConfetti(panel.Root, serial)
	end

	-- "Back to lobby in Ns"
	task.spawn(function()
		local deadline = os.clock() + (Config.Match.EndScreenSeconds or 10)
		while result.Serial == serial and footer.Parent do
			local left = math.ceil(deadline - os.clock())
			if left <= 0 then
				footer.Text = "Going back to the lobby..."
				break
			end
			footer.Text = "Back to lobby in " .. tostring(left) .. "s"
			task.wait(0.2)
		end
		-- safety net: the server normally clears MatchState (which closes the card) right about now
		task.wait(5)
		if result.Serial == serial then
			closeResults(false)
		end
	end)
end

local function buildResultHolder()
	local holder, pad = newHolder("ResultHolder")
	UI.ResultHolder = holder
	UI.ResultPad = pad
end

----------------------------------------------------------------------
-- Other players' dash puffs
----------------------------------------------------------------------
local function newEmitter(parent, props)
	local emitter = Instance.new("ParticleEmitter")
	for key, value in pairs(props) do
		emitter[key] = value
	end
	emitter.Parent = parent
	return emitter
end

local function dashPuff(player)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - root.Position).Magnitude > FX_MAX_DISTANCE then
		return
	end

	local feetOffset = 3
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 then
		feetOffset = humanoid.HipHeight + root.Size.Y * 0.5
	end
	feetOffset = Util.Clamp(feetOffset, 2, 5)

	local instances = {}
	local soft = Theme.Lighten(Colors.Stamina, 0.55)

	local feet = Instance.new("Attachment")
	feet.Name = "NC_DashFeet"
	feet.Position = Vector3.new(0, -feetOffset + 0.2, 0)
	feet.Parent = root
	table.insert(instances, feet)

	local puff = newEmitter(feet, {
		Name = "NC_DashPuff",
		Texture = TEX_SMOKE,
		Color = ColorSequence.new(Colors.Cloud, Colors.CloudShade),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 3.2),
		}),
		Lifetime = NumberRange.new(0.35, 0.6),
		Speed = NumberRange.new(5, 10),
		SpreadAngle = Vector2.new(70, 70),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
		Drag = 3,
		LightEmission = 0.05,
		LockedToPart = false,
		Rate = 0,
		Enabled = false,
	})
	puff:Emit(7)

	local sparks = newEmitter(root, {
		Name = "NC_DashSparks",
		Texture = TEX_SPARKLES,
		Color = ColorSequence.new(soft, Colors.Stamina),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.8),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Lifetime = NumberRange.new(0.25, 0.45),
		Speed = NumberRange.new(8, 18),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 4,
		LightEmission = 0.8,
		LockedToPart = false,
		Rate = 0,
		Enabled = false,
	})
	sparks:Emit(6)
	table.insert(instances, sparks)

	-- a short ribbon through the torso while the dash lasts
	local top = Instance.new("Attachment")
	top.Name = "NC_DashTrailTop"
	top.Position = Vector3.new(0, 1.2, 0)
	top.Parent = root
	local bottom = Instance.new("Attachment")
	bottom.Name = "NC_DashTrailBottom"
	bottom.Position = Vector3.new(0, -1.4, 0)
	bottom.Parent = root
	table.insert(instances, top)
	table.insert(instances, bottom)

	local trail = Instance.new("Trail")
	trail.Name = "NC_DashTrail"
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = 0.3
	trail.MinLength = 0.1
	trail.FaceCamera = true
	trail.LightEmission = 0.5
	trail.Color = ColorSequence.new(soft, Colors.Stamina)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	trail.Parent = root
	table.insert(instances, trail)

	task.delay(Config.Physics.DashDuration + 0.08, function()
		pcall(function()
			trail.Enabled = false
		end)
	end)
	task.delay(1.2, function()
		for _, inst in ipairs(instances) do
			pcall(function()
				inst:Destroy()
			end)
		end
	end)
end

local function onDashFx(userId)
	if type(userId) ~= "number" or userId == LocalPlayer.UserId then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	local now = os.clock()
	local last = lastDashFx[userId]
	if last and now - last < FX_MIN_INTERVAL then
		return
	end
	lastDashFx[userId] = now
	dashPuff(player)
end

----------------------------------------------------------------------
-- Remote handlers + wiring
----------------------------------------------------------------------
local function onNotify(text, kind, duration)
	addToast(text, kind, duration)
end

local function onMatchResult(data)
	showResults(data)
end

local function onMatchState(state)
	-- the server clears MatchState when it sends the player back to the lobby
	if state == nil then
		closeResults(false)
	end
end

-- Remotes.Get yields until the folder replicates, so every hook runs in its own thread.
local function hook(name, handler)
	task.spawn(function()
		local ok, remote = pcall(Remotes.Get, name)
		if not ok or not remote then
			warn("[NotifyController] remote " .. name .. " unavailable: " .. tostring(remote))
			return
		end
		remote.OnClientEvent:Connect(function(...)
			local okCall, err = pcall(handler, ...)
			if not okCall then
				warn("[NotifyController] " .. name .. " handler failed: " .. tostring(err))
			end
		end)
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
				pcall(relayout)
			end)
		end
		pcall(relayout)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bind)
	bind()
	task.delay(0.5, function()
		pcall(relayout)
	end)
	task.delay(2, function()
		pcall(relayout)
	end)
end

function NotifyController.Init()
	if initialized then
		return
	end
	initialized = true
	if not LocalPlayer then
		return
	end

	-- hook the remotes first so nothing sent while the GUI builds is lost to a yield
	hook("Notify", onNotify)
	hook("MatchResult", onMatchResult)
	hook("MatchState", onMatchState)
	hook("DashFx", onDashFx)

	local ok, err = pcall(function()
		UI.Gui = CloudUI.NewScreenGui("NimbusNotify", 30)
		buildResultHolder() -- first: toasts are created afterwards, so they draw on top of the card
		buildToastStack()
		applyMargins()
		hookCamera()
	end)
	if not ok then
		warn("[NotifyController] GUI setup failed: " .. tostring(err))
	end
	task.spawn(function()
		local okHud, hudErr = pcall(watchHud)
		if not okHud then
			warn("[NotifyController] could not follow the HUD layout: " .. tostring(hudErr))
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastDashFx[player.UserId] = nil
	end)
end

return NotifyController
