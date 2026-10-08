-- NotifyController (client, v2): the game's side-of-screen voice. Nothing here is ever centred.
--
--   NotifyController.Init()
--
-- Remotes handled
--   Notify(text, kind, duration)  -> compact toast stack on the RIGHT edge, just under the HUD token pill.
--                                    Max 4, 250 px wide, newest on top, slide in from the right, `Toast` role
--                                    font, coloured by kind (info|good|bad|token). Identical toasts that are
--                                    still showing are merged into "text x2".
--   MatchResult(result)           -> compact result card on the right edge (about 45% down): VICTORY!/DEFEAT in
--                                    the Title font with a gradient, difficulty + stars, time, tokens, bonus,
--                                    a small member list and a "Back to lobby in Ns" line. It closes when the
--                                    server clears MatchState (the player is back in the lobby), when the
--                                    player presses its X, or a few seconds after the countdown ends.
--   MatchState(nil)               -> closes the result card.
--   DashFx(userId)                -> a cheap puff + trail on that player's character (own dashes are ignored,
--                                    MovementController already shows those).
--
-- The GUI is "NimbusNotify" (display order 30, IgnoreGuiInset = false). Panels carry a UIScale driven by
-- the viewport (same formula as HudController) and sit inside full-screen holder frames whose UIPadding is
-- the screen margin, so scaling never detaches them from the edge.
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
-- Tuning
----------------------------------------------------------------------
-- toasts
local MAX_TOASTS = 4
local TOAST_W = 250
local TOAST_GAP = 6
local TOAST_TEXT_SIZE = 15
local TOAST_BG = 0.1
local DEFAULT_DURATION = 3
local MIN_DURATION = 1.5
local MAX_DURATION = 8
local MAX_TOAST_CHARS = 90

-- KEEP IN SYNC with HudController.lua: REF_W/REF_H/MIN_SCALE/MAX_SCALE, EDGE, TOUCH_EDGE and PILL_H.
-- The toast stack starts directly below the HUD token pill (top-right).
local REF_W, REF_H = 1280, 720
local MIN_SCALE, MAX_SCALE = 0.7, 1.25
local EDGE = 10
local TOUCH_EDGE = 20
local PILL_H = 44
local PILL_GAP = 8

-- result card
local RESULT_W = 264
local RESULT_Y = 0.47 -- vertical position (fraction of the screen), right edge
-- On narrow (portrait) screens the scaled card reaches into the middle of the screen. The game must never say
-- anything there, so the card moves up until it sits above this central band (fractions of the screen size).
local CENTRE_BAND = 0.15
local CENTRE_MARGIN = 6
local CONFETTI_PIECES = 18

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
local UI = {} -- Gui, Stack, StackScale, ToastPad, ResultPad
local scalers = {}
local toasts = {} -- live toasts, oldest first
local toastSerial = 0
local result = { Panel = nil, Serial = 0, Height = 0 } -- the open result card (Height: design px)
local lastDashFx = {}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local tween = Util.Tween

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

local function addViewportScale(root)
	local s = Instance.new("UIScale")
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

local function applyMargins()
	local side = isTouchDevice() and TOUCH_EDGE or EDGE
	local k = currentScale()
	if UI.ToastPad then
		UI.ToastPad.PaddingRight = UDim.new(0, side)
		UI.ToastPad.PaddingTop = UDim.new(0, math.floor(EDGE + (PILL_H + PILL_GAP) * k))
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
	if cardLeft >= vp.X * (0.5 + CENTRE_BAND) then
		return UDim2.new(xScale, 0, RESULT_Y, 0)
	end
	-- the ScreenGui area starts below the top bar (IgnoreGuiInset = false), so gui y = screen y - inset
	local okInset, inset = pcall(GuiService.GetGuiInset, GuiService)
	local top = (okInset and inset and inset.Y) or 0
	local half = (panelHeight or result.Height) * k / 2
	local ceiling = vp.Y * (0.5 - CENTRE_BAND) - CENTRE_MARGIN - half - top
	local floorY = (EDGE + PILL_H + PILL_GAP) * k + half -- keep clear of the token pill
	return UDim2.new(xScale, 0, 0, math.floor(math.max(ceiling, floorY)))
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
	local panel = result.Panel
	if panel and panel.Root and panel.Root.Parent then
		panel.Root.Position = resultPosition(1)
	end
end

----------------------------------------------------------------------
-- Toasts
----------------------------------------------------------------------
-- a = 0 fully visible .. 1 fully faded
local function setToastAlpha(toast, a, seconds)
	local goals = {
		{ toast.Card, { BackgroundTransparency = TOAST_BG + (1 - TOAST_BG) * a } },
		{ toast.Stroke, { Transparency = a } },
		{ toast.Label, { TextTransparency = a, TextStrokeTransparency = 0.35 + 0.65 * a } },
		{ toast.Icon, { BackgroundTransparency = a } },
		{ toast.IconGlyph, { TextTransparency = a, TextStrokeTransparency = 0.35 + 0.65 * a } },
	}
	for _, entry in ipairs(goals) do
		if seconds and seconds > 0 then
			tween(entry[1], seconds, entry[2], Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		else
			for key, value in pairs(entry[2]) do
				entry[1][key] = value
			end
		end
	end
end

local function dismissToast(toast)
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
	local stroke = Theme.Stroke(card, Theme.Lighten(color, 0.1), 2, 1)
	Util.Create("UISizeConstraint", { MinSize = Vector2.new(0, 34), Parent = card })
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = card

	local icon = newFrame(card, "Icon", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(24, 24),
		BackgroundTransparency = 1,
		BackgroundColor3 = Theme.Darken(color, 0.15),
	})
	round(icon)
	local glyph = newText(icon, "Glyph", KIND_GLYPH[kindName] or "i", "Heading", 15, WHITE, {
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})

	local label = newText(card, "Text", text, "Toast", TOAST_TEXT_SIZE, Theme.Lighten(color, 0.4), {
		Position = UDim2.new(0, 32, 0, 0),
		Size = UDim2.new(1, -32, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Stroke = 1,
	})

	return {
		Slot = slot, Card = card, Stroke = stroke, Icon = icon, IconGlyph = glyph, Label = label,
		Text = text, Kind = kindName, Count = 1, Dead = false, Expiry = 0, Color = color,
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
			tween(live.Label, 0.35, { TextColor3 = Theme.Lighten(live.Color, 0.4) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			scheduleExpiry(live, duration)
			return
		end
	end

	local toast = buildToast(text, kind)
	table.insert(toasts, toast)
	-- never more than MAX_TOASTS: the oldest one leaves first
	while #toasts > MAX_TOASTS do
		dismissToast(toasts[1])
	end

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

local function burstConfetti(root, serial)
	local palette = Theme.World and Theme.World.Rainbow or Colors.Rainbow
	for i = 1, CONFETTI_PIECES do
		local x = rng:NextNumber(0.08, 0.92)
		local startY = rng:NextNumber(-4, 16)
		local piece = newFrame(root, "Confetti", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(x, 0, 0, startY),
			Size = UDim2.fromOffset(rng:NextInteger(5, 8), rng:NextInteger(7, 11)),
			BackgroundTransparency = 1,
			BackgroundColor3 = palette[(i % #palette) + 1],
			Rotation = rng:NextInteger(0, 359),
			ZIndex = 12,
		})
		task.delay(rng:NextNumber(0.2, 0.7), function()
			if result.Serial ~= serial or not piece.Parent then
				return
			end
			piece.BackgroundTransparency = 0
			local fall = rng:NextNumber(110, 190)
			tween(piece, rng:NextNumber(0.9, 1.4), {
				Position = UDim2.new(Util.Clamp(x + rng:NextNumber(-0.12, 0.12), 0.02, 0.98), 0, 0, startY + fall),
				Rotation = piece.Rotation + rng:NextInteger(-320, 320),
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
	local diff = Config.GetDifficulty(data.DifficultyId)
	local diffColor = (diff and diff.Color) or Colors.Stamina
	local starCount = tonumber(data.Stars) or (diff and diff.Stars) or 0
	local members = normaliseMembers(data.Members)
	local showMembers = #members > 1
	local reason = (not won) and REASON_TEXT[tostring(data.Reason or "defeat")] or nil

	-- fixed vertical layout (inner coordinates)
	local TITLE_H, DIFF_H, REASON_H, ROW_H, MEMBER_H, FOOT_H = 36, 18, 16, 20, 18, 22
	local y = 0
	local titleY = y
	y = y + TITLE_H
	local diffY = y
	y = y + DIFF_H
	local reasonY = y
	if reason then
		y = y + REASON_H
	end
	y = y + 6
	local statsY = y
	y = y + ROW_H * 3 + 4
	local membersY = y
	if showMembers then
		y = y + #members * MEMBER_H + 4
	end
	local footY = y
	y = y + FOOT_H
	local panelH = 34 + 8 + y
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
		Position = UDim2.new(0, 10, 0, 4),
		Size = UDim2.new(1, -20, 1, -8),
	})

	-- headline with a gradient (the label itself stays white, the gradient colours it)
	local headline = newText(inner, "Headline", won and "VICTORY!" or "DEFEAT", "Title", 32, WHITE, {
		Position = UDim2.fromOffset(0, titleY),
		Size = UDim2.new(1, 0, 0, TITLE_H),
		TextXAlignment = Enum.TextXAlignment.Center,
		Stroke = 0.1,
	})
	if won then
		Theme.Gradient(headline, Colors.TokenGlow, Colors.Token, 90)
	else
		Theme.Gradient(headline, Color3.fromRGB(190, 204, 244), Color3.fromRGB(128, 138, 214), 90)
	end

	-- difficulty + stars
	local diffText = tostring(data.DifficultyName or data.DifficultyId or "")
	if starCount > 0 then
		diffText = diffText .. "  <font color=\"" .. hex(GOLD) .. "\">" .. string.rep("\226\152\133", math.min(5, starCount)) .. "</font>"
	end
	newText(inner, "Difficulty", diffText, "Heading", 15, Theme.Lighten(diffColor, 0.3), {
		Position = UDim2.fromOffset(0, diffY),
		Size = UDim2.new(1, 0, 0, DIFF_H),
		TextXAlignment = Enum.TextXAlignment.Center,
		RichText = true,
	})
	if reason then
		newText(inner, "Reason", reason, "Body", 13, MUTED, {
			Position = UDim2.fromOffset(0, reasonY),
			Size = UDim2.new(1, 0, 0, REASON_H),
			TextXAlignment = Enum.TextXAlignment.Center,
			Stroke = 0.5,
		})
	end

	-- stats
	local serial = result.Serial
	local function statRow(index, caption, valueText, valueColor)
		local rowY = statsY + (index - 1) * ROW_H
		local bar = newFrame(inner, "Row" .. caption, {
			Position = UDim2.fromOffset(0, rowY),
			Size = UDim2.new(1, 0, 0, ROW_H - 2),
			BackgroundTransparency = 0.7,
			BackgroundColor3 = Colors.Ink,
		})
		Theme.Corner(bar, UDim.new(0, 8))
		newText(bar, "Caption", caption, "Body", 14, MUTED, {
			Position = UDim2.new(0, 8, 0, 0),
			Size = UDim2.new(0.4, 0, 1, 0),
			Stroke = 0.5,
		})
		return newText(bar, "Value", valueText, "Heading", 15, valueColor, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 0),
			Size = UDim2.new(0.6, 0, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			Stroke = 0.3,
		})
	end

	local ownTokens = math.max(0, math.floor(tonumber(data.MatchTokens) or 0))
	local totalTokens = math.max(0, math.floor(tonumber(data.TotalTokens) or 0))
	local bonus = math.max(0, math.floor(tonumber(data.Bonus) or 0))
	local seconds = tonumber(data.Seconds) or 0

	statRow(1, "Time", Util.FormatTime(seconds), WHITE)
	local tokenValue = statRow(2, "Tokens", "0 / " .. tostring(totalTokens), Colors.TokenGlow)
	local bonusValue = statRow(3, "Win bonus", bonus > 0 and "+0 \226\152\129" or "-", bonus > 0 and GOLD or MUTED)
	countUp(tokenValue, ownTokens, 0.45, 0.8, function(n)
		return tostring(n) .. " / " .. tostring(totalTokens)
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
			newText(row, "Name", m.Name, "Body", 13, mine and Colors.TokenGlow or WHITE, {
				Position = UDim2.new(0, 6, 0, 0),
				Size = UDim2.new(1, -86, 1, 0),
				TextTruncate = Enum.TextTruncate.AtEnd,
				Stroke = 0.5,
			})
			newText(row, "Tokens", "\226\152\129 " .. tostring(m.Tokens), "Heading", 13, Colors.TokenGlow, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -24, 0, 0),
				Size = UDim2.fromOffset(58, MEMBER_H),
				TextXAlignment = Enum.TextXAlignment.Right,
				Stroke = 0.5,
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
			newText(row, "State", stateText, "Heading", 13, stateColor, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -4, 0, 0),
				Size = UDim2.fromOffset(16, MEMBER_H),
				TextXAlignment = Enum.TextXAlignment.Center,
			})
		end
	end

	-- footer: countdown to the lobby
	local footer = newText(inner, "Footer", "", "Toast", 15, Colors.Cloud, {
		Position = UDim2.fromOffset(0, footY),
		Size = UDim2.new(1, 0, 0, FOOT_H),
		TextXAlignment = Enum.TextXAlignment.Center,
		Stroke = 0.3,
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

	Players.PlayerRemoving:Connect(function(player)
		lastDashFx[player.UserId] = nil
	end)
end

return NotifyController
