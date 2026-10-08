-- CloudUI: the chunky "cloud" UI kit. Pet-Simulator-style panels (thick navy outline, glossy blue
-- fills, bright buttons, round icon buttons) made cloudier: soft sky-blue gradients, puffy bumps along
-- the top edge of every window, calmer colours. Everything is built from Frames / TextLabels /
-- UICorner / UIStroke / UIGradient / UIPadding / list+grid layouts. No images, no asset ids.
--
--   CloudUI.NewScreenGui(name, displayOrder) -> ScreenGui
--   CloudUI.Panel(props)      -> { Root, Body, Content, TitleLabel, Close, SetTitle, Destroy }
--   CloudUI.Button(props)     -> TextButton
--   CloudUI.IconButton(props) -> { Root, Button, SetBadge, SetGlyph, SetLabel, SetColor }
--   CloudUI.Bar(props)        -> { Root, Fill, Label, SetFraction, SetText, SetColor, GetFraction }
--   CloudUI.Slot(props)       -> { Root, Button, SetContent, SetSelected, SetCount, SetHotkey, ... }
--   CloudUI.Tabs(props)       -> { Root, Content, Add, Select, GetSelected, GetPage }
--   CloudUI.Grid(parent, cellSize, padding) -> ScrollingFrame (UIGridLayout, automatic canvas)
--   CloudUI.PetViewport(parent, petDef, size, opts) -> { Frame, Destroy, SetAnimated, SetExcited }
--   CloudUI.Pill(text, kind, parent) -> TextLabel
--   CloudUI.Tooltip(guiObject, textFn) -> disconnect function
--   CloudUI.RarityColor(rarityId) -> Color3
--
-- Conventions
--   * Every constructor accepts Name / Parent / Position / AnchorPoint / Size in its props and names
--     its instances for debugging. Text uses Theme font roles only.
--   * Buttons are plain TextButtons. Their state lives in attributes, so you can change it later:
--       button:SetAttribute("Disabled", true)   (or button.Active = false)   -> greyed out, callback ignored
--       button:SetAttribute("Style", "Gold")                                 -> re-skin
--     (CloudUI.SetDisabled / CloudUI.SetStyle do exactly that.) Setting button.Text just works.
--   * Hover / press feedback is a UIScale (1.04 / 0.95). UIScale grows around the AnchorPoint, so
--     centre-anchored buttons look best.
--   * ONE RenderStepped connection (CloudUI.Update) drives every pet viewport and the tooltip; it
--     disconnects itself when nothing needs it. Viewports of hidden or destroyed UI stop costing time.
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))

local CloudUI = {}

----------------------------------------------------------------------
-- Palette + tuning
----------------------------------------------------------------------
local Colors = Theme.Colors
local WHITE = Colors.White
local NAVY = Colors.Navy or Colors.Ink
local MUTED = Colors.Muted or Colors.CloudShade
local GOLD = Colors.Gold or Colors.Token

local BUTTON_COLORS = Theme.Buttons or {}
local KIND_COLORS = Theme.Kinds or {}

local HOVER_SCALE = 1.04
local PRESS_SCALE = 0.95
local FOV = 32 -- pet viewport camera
local TOOLTIP_DELAY = 0.35
local LONG_PRESS = 0.45

CloudUI.Palette = {
	Navy = NAVY,
	Gold = GOLD,
	Muted = MUTED,
	FrameTop = Colors.FrameTop,
	FrameBottom = Colors.FrameBottom,
	WellTop = Colors.WellTop,
	WellBottom = Colors.WellBottom,
	Mist = Colors.Mist,
	Buttons = BUTTON_COLORS,
}

-- Multiplier gradient for faces that carry TEXT. A UIGradient also tints the text of its TextLabel /
-- TextButton, so the gradient stays near white where the text sits and only darkens the "lip" band at
-- the bottom (hard step), which gives the glossy chunky 3-D look without recolouring the text.
local FACE_SEQUENCE = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
	ColorSequenceKeypoint.new(0.50, Color3.fromRGB(244, 246, 250)),
	ColorSequenceKeypoint.new(0.77, Color3.fromRGB(226, 232, 244)),
	ColorSequenceKeypoint.new(0.79, Color3.fromRGB(166, 174, 206)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 158, 192)),
})

----------------------------------------------------------------------
-- Small builders
----------------------------------------------------------------------
local function toUDim(value, default)
	if typeof(value) == "UDim" then
		return value
	end
	if type(value) == "number" then
		return UDim.new(0, value)
	end
	return default or UDim.new(0, 12)
end

local function toUDim2(value, default)
	if typeof(value) == "UDim2" then
		return value
	end
	if typeof(value) == "Vector2" then
		return UDim2.fromOffset(value.X, value.Y)
	end
	if type(value) == "number" then
		return UDim2.fromOffset(value, value)
	end
	return default
end

local function corner(parent, radius)
	return Util.Create("UICorner", { CornerRadius = toUDim(radius), Parent = parent })
end

local function round(parent)
	return Util.Create("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = parent })
end

local function stroke(parent, color, thickness, transparency)
	return Util.Create("UIStroke", {
		Color = color or NAVY,
		Thickness = thickness or 3,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

local function padding(parent, left, top, right, bottom)
	return Util.Create("UIPadding", {
		PaddingLeft = toUDim(left or 0),
		PaddingTop = toUDim(top or 0),
		PaddingRight = toUDim(right or 0),
		PaddingBottom = toUDim(bottom or 0),
		Parent = parent,
	})
end

local function gradient(parent, sequence, rotation)
	return Util.Create("UIGradient", { Color = sequence, Rotation = rotation or 90, Parent = parent })
end

local function frame(name, props, parent)
	local p = props or {}
	p.Name = name
	if p.BackgroundTransparency == nil then
		p.BackgroundTransparency = 1
	end
	p.BorderSizePixel = 0
	p.Parent = parent
	return Util.Create("Frame", p)
end

-- Soft translucent highlight strip near the top of a glossy face.
local function addShine(parent, heightScale, sideInset, transparency)
	local shine = Util.Create("Frame", {
		Name = "Shine",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = transparency or 0.82,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 3),
		Size = UDim2.new(1, -2 * (sideInset or 10), heightScale or 0.32, 0),
		Active = false,
		Parent = parent,
	})
	round(shine)
	return shine
end

local function titleCase(text)
	text = tostring(text or "")
	return text:sub(1, 1):upper() .. text:sub(2):lower()
end

local function styleBase(style)
	return BUTTON_COLORS[titleCase(style)] or BUTTON_COLORS.Green or Color3.fromRGB(96, 196, 108)
end

local function isStyleName(style)
	return BUTTON_COLORS[titleCase(style)] ~= nil
end

local function isShown(gui)
	local node = gui
	while node do
		if node:IsA("GuiObject") then
			if not node.Visible then
				return false
			end
		elseif node:IsA("LayerCollector") then
			return node.Enabled ~= false
		end
		node = node.Parent
	end
	return false
end

----------------------------------------------------------------------
-- Shared update loop (ONE RenderStepped connection for viewports + tooltip)
----------------------------------------------------------------------
local tickers = {}
local loopConnection = nil
local clockTime = 0

function CloudUI.Update(dt)
	clockTime = clockTime + dt
	for i = #tickers, 1, -1 do
		local ticker = tickers[i]
		if ticker.dead then
			table.remove(tickers, i)
		else
			local ok, err = pcall(ticker.fn, dt, clockTime)
			if not ok then
				ticker.dead = true
				warn("[CloudUI] update error: " .. tostring(err))
			end
		end
	end
	if #tickers == 0 and loopConnection then
		loopConnection:Disconnect()
		loopConnection = nil
	end
end

local function addTicker(fn)
	local ticker = { fn = fn, dead = false }
	table.insert(tickers, ticker)
	if not loopConnection then
		loopConnection = RunService.RenderStepped:Connect(CloudUI.Update)
	end
	return ticker
end

----------------------------------------------------------------------
-- Hover / press feedback
----------------------------------------------------------------------
-- Adds a UIScale to `button` and tweens it on hover and press. opts.OnState(hovering, pressing) is
-- called on every change so the caller can repaint colours.
local function attachFx(button, opts)
	opts = opts or {}
	local hoverScale = opts.Hover or HOVER_SCALE
	local pressScale = opts.Press or PRESS_SCALE
	local scale = Util.Create("UIScale", { Name = "FxScale", Scale = 1, Parent = button })
	local fx = { Hovering = false, Pressing = false }
	local running = nil

	local function refresh(seconds)
		local target = 1
		if fx.Pressing then
			target = pressScale
		elseif fx.Hovering then
			target = hoverScale
		end
		if running then
			running:Cancel()
		end
		running = Util.Tween(scale, seconds, { Scale = target }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		if opts.OnState then
			opts.OnState(fx.Hovering, fx.Pressing)
		end
	end

	button.MouseEnter:Connect(function()
		fx.Hovering = true
		refresh(0.12)
	end)
	button.MouseLeave:Connect(function()
		fx.Hovering = false
		fx.Pressing = false
		refresh(0.14)
	end)
	button.MouseButton1Down:Connect(function()
		fx.Pressing = true
		refresh(0.07)
	end)
	button.MouseButton1Up:Connect(function()
		fx.Pressing = false
		refresh(0.12)
	end)
	-- a finger that lifts never produces MouseLeave
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			fx.Hovering = false
			fx.Pressing = false
			refresh(0.12)
		end
	end)
	fx.Scale = scale
	return fx
end

----------------------------------------------------------------------
-- Screen gui
----------------------------------------------------------------------
function CloudUI.NewScreenGui(name, displayOrder)
	local player = Players.LocalPlayer
	local playerGui = player and player:WaitForChild("PlayerGui")
	local old = playerGui and playerGui:FindFirstChild(name)
	if old and old:IsA("ScreenGui") then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = displayOrder or 1
	gui.Parent = playerGui
	return gui
end

----------------------------------------------------------------------
-- Rarity
----------------------------------------------------------------------
function CloudUI.RarityColor(rarityId)
	local wanted = tostring(rarityId or ""):lower()
	for _, rarity in ipairs(Config.Rarities) do
		if rarity.Id:lower() == wanted then
			return rarity.Color
		end
	end
	return Config.Rarities[1].Color
end

----------------------------------------------------------------------
-- Button
----------------------------------------------------------------------
-- props: Text, Style ("Green"|"Pink"|"Red"|"Blue"|"Gold"|"Gray"), Size, Position, AnchorPoint,
--        Callback (called as Callback(button)), Parent, TextSize, Name, LayoutOrder, ZIndex
function CloudUI.Button(props)
	props = props or {}
	local state = { Style = isStyleName(props.Style) and titleCase(props.Style) or "Green" }

	local button = Util.Create("TextButton", {
		Name = props.Name or ("Button_" .. tostring(props.Text or "")),
		AutoButtonColor = false,
		Active = true, -- explicit: "Active == false" is how a button is switched off (see isDisabled)
		BorderSizePixel = 0,
		BackgroundColor3 = Theme.Lighten(styleBase(state.Style), 0.16),
		Size = props.Size or UDim2.fromOffset(150, 46),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.new(0, 0),
		LayoutOrder = props.LayoutOrder or 0,
		ZIndex = props.ZIndex or 1,
		Text = props.Text or "",
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	Theme.Style(button, "Button", { Size = props.TextSize or 22, Stroke = 0.1 })
	corner(button, 12)
	local outline = stroke(button, NAVY, 3, 0)
	gradient(button, FACE_SEQUENCE, 90)
	padding(button, 8, 0, 8, UDim.new(0.18, 0))
	addShine(button, 0.3, 8, 0.8)

	local fx
	local function isDisabled()
		return button:GetAttribute("Disabled") == true or button.Active == false
	end

	local function paint(seconds)
		local disabled = isDisabled()
		local base = styleBase(disabled and "Gray" or state.Style)
		local face = Theme.Lighten(base, 0.16)
		if not disabled and fx then
			if fx.Pressing then
				face = Theme.Darken(face, 0.1)
			elseif fx.Hovering then
				face = Theme.Lighten(face, 0.1)
			end
		end
		if seconds and seconds > 0 then
			Util.Tween(button, seconds, { BackgroundColor3 = face })
		else
			button.BackgroundColor3 = face
		end
		button.TextColor3 = disabled and Color3.fromRGB(214, 220, 234) or WHITE
		button.TextStrokeColor3 = Theme.Darken(base, 0.62)
		outline.Color = disabled and Theme.Darken(NAVY, 0.1) or NAVY
	end

	fx = attachFx(button, {
		OnState = function()
			paint(0.08)
		end,
	})
	paint(0)

	button:GetAttributeChangedSignal("Disabled"):Connect(function()
		paint(0.15)
	end)
	button:GetPropertyChangedSignal("Active"):Connect(function()
		paint(0.15)
	end)
	button:GetAttributeChangedSignal("Style"):Connect(function()
		local style = button:GetAttribute("Style")
		if type(style) == "string" and isStyleName(style) then
			state.Style = titleCase(style)
			paint(0.15)
		end
	end)

	if props.Callback then
		button.Activated:Connect(function()
			if isDisabled() then
				return
			end
			props.Callback(button)
		end)
	end

	button.Parent = props.Parent
	return button
end

function CloudUI.SetDisabled(button, disabled)
	if button then
		button:SetAttribute("Disabled", disabled and true or false)
	end
end

function CloudUI.SetStyle(button, style)
	if button then
		button:SetAttribute("Style", tostring(style))
	end
end

----------------------------------------------------------------------
-- Panel (window)
----------------------------------------------------------------------
-- Cloud bumps along the top edge: { x scale, diameter px, y offset px below the edge }.
local BUMPS = {
	{ 0.06, 30, 5 },
	{ 0.15, 44, 1 },
	{ 0.26, 34, 5 },
	{ 0.38, 50, 0 },
	{ 0.50, 38, 4 },
	{ 0.62, 52, 0 },
	{ 0.74, 34, 5 },
	{ 0.85, 46, 1 },
	{ 0.94, 30, 5 },
}
local OUTLINE_THICKNESS = 4

-- props: Name, Size, Position, AnchorPoint, Title, Closable, OnClose, Parent, Accent (Color3), Clouds (default true)
function CloudUI.Panel(props)
	props = props or {}
	local hasTitle = type(props.Title) == "string" and props.Title ~= ""
	local clouds = props.Clouds ~= false
	local accent = props.Accent
	if typeof(accent) ~= "Color3" then
		accent = BUTTON_COLORS.Blue or Color3.fromRGB(90, 158, 234)
	end

	local root = frame(props.Name or "CloudPanel", {
		Size = props.Size or UDim2.fromOffset(520, 380),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.new(0, 0),
		LayoutOrder = props.LayoutOrder or 0,
	})

	-- soft drop shadow
	local shadow = frame("Shadow", {
		BackgroundColor3 = Color3.fromRGB(8, 12, 32),
		BackgroundTransparency = 0.72,
		Position = UDim2.new(0, 0, 0, 7),
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 0,
	}, root)
	corner(shadow, 18)

	-- the frame colour at the top, tinted a little by the accent
	local frameTop = Colors.FrameTop:Lerp(accent, 0.12)
	local frameBottom = Colors.FrameBottom:Lerp(accent, 0.12)

	-- bump outlines (behind the body) and bump fills (in front of the body's top outline)
	if clouds then
		local back = frame("CloudOutline", { Size = UDim2.new(1, 0, 1, 0), ZIndex = 1 }, root)
		local front = frame("CloudPuffs", { Size = UDim2.new(1, 0, 1, 0), ZIndex = 3 }, root)
		for i, bump in ipairs(BUMPS) do
			local d = bump[2]
			local ring = frame("Ring" .. i, {
				BackgroundColor3 = NAVY,
				BackgroundTransparency = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(bump[1], 0, 0, bump[3]),
				Size = UDim2.fromOffset(d + 2 * OUTLINE_THICKNESS, d + 2 * OUTLINE_THICKNESS),
			}, back)
			round(ring)
			local puff = frame("Puff" .. i, {
				BackgroundColor3 = frameTop,
				BackgroundTransparency = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(bump[1], 0, 0, bump[3]),
				Size = UDim2.fromOffset(d, d),
			}, front)
			round(puff)
		end
	end

	local body = frame("Body", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0,
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 2,
		Active = true, -- sinks clicks so the world behind the window is not clicked
	}, root)
	corner(body, 16)
	stroke(body, NAVY, OUTLINE_THICKNESS, 0)
	gradient(body, ColorSequence.new(frameTop, frameBottom), 90)
	-- thin glossy highlight just inside the top edge
	local highlight = frame("Highlight", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.62,
		Position = UDim2.new(0, 14, 0, 6),
		Size = UDim2.new(1, -28, 0, 5),
	}, body)
	round(highlight)

	-- inner content well
	local topInset = hasTitle and 34 or 22
	local content = frame("Content", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0,
		Position = UDim2.new(0, 12, 0, topInset),
		Size = UDim2.new(1, -24, 1, -(topInset + 12)),
		ZIndex = 4,
	}, root)
	corner(content, 12)
	stroke(content, Colors.WellEdge or NAVY, 3, 0.1)
	gradient(content, ColorSequence.new(Colors.WellTop, Colors.WellBottom), 90)

	-- title ribbon straddling the top edge
	local titleLabel = nil
	if hasTitle then
		titleLabel = Theme.Label(props.Title, "Title", {
			Size = 24,
			Stroke = 0,
			StrokeColor = Theme.Darken(accent, 0.62),
			Props = {
				Name = "Title",
				BackgroundTransparency = 0,
				BackgroundColor3 = Theme.Lighten(accent, 0.14),
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0, 2),
				Size = UDim2.fromOffset(0, 42),
				AutomaticSize = Enum.AutomaticSize.X,
				TextXAlignment = Enum.TextXAlignment.Center,
				ZIndex = 6,
			},
		})
		corner(titleLabel, 14)
		stroke(titleLabel, NAVY, 3, 0)
		gradient(titleLabel, FACE_SEQUENCE, 90)
		padding(titleLabel, 28, 0, 28, UDim.new(0.18, 0))
		Util.Create("UISizeConstraint", { MinSize = Vector2.new(120, 42), Parent = titleLabel })
		addShine(titleLabel, 0.3, 12, 0.8)
		titleLabel.Parent = root
	end

	local panel = { Root = root, Body = body, Content = content, TitleLabel = titleLabel }

	function panel.Close()
		if props.OnClose then
			props.OnClose(panel)
		else
			root.Visible = false
		end
	end

	function panel.SetTitle(text)
		if titleLabel then
			titleLabel.Text = tostring(text)
		end
	end

	function panel.Destroy()
		root:Destroy()
	end

	if props.Closable then
		local closeButton = CloudUI.Button({
			Name = "Close",
			Text = "X",
			Style = "Red",
			TextSize = 22,
			Size = UDim2.fromOffset(40, 40),
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 8, 0, -14),
			ZIndex = 7,
			Callback = function()
				panel.Close()
			end,
			Parent = root,
		})
		panel.CloseButton = closeButton
	end

	root.Parent = props.Parent
	return panel
end

----------------------------------------------------------------------
-- Bar
----------------------------------------------------------------------
-- props: Size, Color, Label, Parent, Height, Position, AnchorPoint, Name
function CloudUI.Bar(props)
	props = props or {}
	local height = props.Height or 22
	local color = props.Color or Colors.Health
	local fraction = 1

	local root = frame(props.Name or "CloudBar", {
		BackgroundColor3 = Color3.fromRGB(32, 44, 92),
		BackgroundTransparency = 0,
		Size = props.Size or UDim2.new(1, 0, 0, height),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.new(0, 0),
		LayoutOrder = props.LayoutOrder or 0,
	})
	round(root)
	stroke(root, Theme.Darken(NAVY, 0.3), 3, 0)

	local inner = frame("Inner", {
		Position = UDim2.new(0, 3, 0, 3),
		Size = UDim2.new(1, -6, 1, -6),
	}, root)

	local fill = frame("Fill", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0,
		Size = UDim2.new(1, 0, 1, 0),
	}, inner)
	round(fill)
	local fillGradient = gradient(fill, ColorSequence.new(Theme.Lighten(color, 0.3), Theme.Darken(color, 0.12)), 90)
	addShine(fill, 0.34, 6, 0.72)

	local textSize = Util.Clamp(height - 8, 11, 20)
	local label = Theme.Label(props.Label or "", "Heading", {
		Size = textSize,
		Stroke = 0.1,
		Props = {
			Name = "Text",
			Size = UDim2.new(1, 0, 1, 0),
			ZIndex = 3,
			TextXAlignment = Enum.TextXAlignment.Center,
		},
	})
	label.Parent = root

	local bar = { Root = root, Fill = fill, Label = label }
	local running = nil

	function bar.SetFraction(value, animate)
		fraction = Util.Clamp(tonumber(value) or 0, 0, 1)
		local size = UDim2.new(fraction, 0, 1, 0)
		if running then
			running:Cancel()
			running = nil
		end
		if animate then
			running = Util.Tween(fill, 0.25, { Size = size }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		else
			fill.Size = size
		end
	end

	function bar.GetFraction()
		return fraction
	end

	function bar.SetText(text)
		label.Text = tostring(text or "")
	end

	function bar.SetColor(newColor)
		if typeof(newColor) ~= "Color3" then
			return
		end
		color = newColor
		fillGradient.Color = ColorSequence.new(Theme.Lighten(color, 0.3), Theme.Darken(color, 0.12))
	end

	root.Parent = props.Parent
	return bar
end

----------------------------------------------------------------------
-- Pill
----------------------------------------------------------------------
local function kindColor(kind)
	if typeof(kind) == "Color3" then
		return kind
	end
	if type(kind) == "string" then
		local found = KIND_COLORS[kind:lower()]
		if found then
			return found
		end
		return CloudUI.RarityColor(kind)
	end
	return KIND_COLORS.info or Color3.fromRGB(90, 158, 234)
end

-- kind: "info" | "good" | "bad" | "token" | a rarity id ("Epic") | a Color3
function CloudUI.Pill(text, kind, parent)
	local color = kindColor(kind)
	local pill = Theme.Label(tostring(text or ""), "Heading", {
		Size = 14,
		Stroke = 0.15,
		StrokeColor = Theme.Darken(color, 0.6),
		Props = {
			Name = "Pill",
			BackgroundTransparency = 0,
			BackgroundColor3 = Theme.Lighten(color, 0.14),
			BorderSizePixel = 0,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 24),
			TextXAlignment = Enum.TextXAlignment.Center,
		},
	})
	round(pill)
	stroke(pill, NAVY, 2, 0)
	gradient(pill, FACE_SEQUENCE, 90)
	padding(pill, 10, 0, 10, UDim.new(0.14, 0))
	Util.Create("UISizeConstraint", { MinSize = Vector2.new(30, 24), Parent = pill })
	addShine(pill, 0.3, 8, 0.78)
	pill.Parent = parent
	return pill
end

----------------------------------------------------------------------
-- Icon button (round, with a caption below)
----------------------------------------------------------------------
-- props: Glyph (short text), Label (caption), Color (Color3 or style name), Callback, Parent, Size
--        (whole widget, default 64x84; the circle's diameter is the widget width, and with a caption the
--        widget is made at least width + 22 px tall so the caption never overlaps its neighbours),
--        Badge (bool), Position, AnchorPoint, Name, LayoutOrder
function CloudUI.IconButton(props)
	props = props or {}
	local hasLabel = type(props.Label) == "string" and props.Label ~= ""
	local labelHeight = 20
	local color = props.Color
	if type(color) == "string" then
		color = styleBase(color)
	elseif typeof(color) ~= "Color3" then
		color = BUTTON_COLORS.Blue or Color3.fromRGB(90, 158, 234)
	end

	local widgetSize = props.Size or UDim2.fromOffset(64, hasLabel and 84 or 64)
	if hasLabel and widgetSize.X.Scale == 0 and widgetSize.Y.Scale == 0 then
		local minHeight = widgetSize.X.Offset + labelHeight + 2
		if widgetSize.Y.Offset < minHeight then
			widgetSize = UDim2.fromOffset(widgetSize.X.Offset, minHeight)
		end
	end

	local root = frame(props.Name or ("IconButton_" .. tostring(props.Label or props.Glyph or "")), {
		Size = widgetSize,
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.new(0, 0),
		LayoutOrder = props.LayoutOrder or 0,
	})

	local holder = frame("CircleHolder", {
		Size = UDim2.new(1, 0, 1, hasLabel and -labelHeight or 0),
	}, root)

	local button = Util.Create("TextButton", {
		Name = "Button",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = "",
		BackgroundColor3 = WHITE,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(1, -8, 1, -8),
		Parent = holder,
	})
	Util.Create("UIAspectRatioConstraint", { AspectRatio = 1, Parent = button })
	round(button)
	local outline = stroke(button, NAVY, 4, 0)
	local faceGradient = gradient(button, ColorSequence.new(Theme.Lighten(color, 0.3), color), 90)

	-- darker crescent at the bottom for the chunky look (the circle has no text, so a real gradient is fine)
	local function applyColor(c)
		color = c
		faceGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Lighten(c, 0.34)),
			ColorSequenceKeypoint.new(0.5, Theme.Lighten(c, 0.06)),
			ColorSequenceKeypoint.new(0.76, Theme.Darken(c, 0.1)),
			ColorSequenceKeypoint.new(0.78, Theme.Darken(c, 0.34)),
			ColorSequenceKeypoint.new(1, Theme.Darken(c, 0.4)),
		})
	end
	applyColor(color)

	local shine = Util.Create("Frame", {
		Name = "Shine",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.78,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.1, 0),
		Size = UDim2.new(0.54, 0, 0.24, 0),
		Parent = button,
	})
	round(shine)

	local glyph = Theme.Label(tostring(props.Glyph or ""), "Title", {
		Scaled = true,
		Stroke = 0,
		StrokeColor = Theme.Darken(color, 0.65),
		Props = {
			Name = "Glyph",
			Position = UDim2.new(0.5, 0, 0.44, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.new(0.56, 0, 0.56, 0),
			ZIndex = 2,
		},
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 56, MinTextSize = 8, Parent = glyph })
	glyph.Parent = button

	local caption = nil
	if hasLabel then
		caption = Theme.Label(props.Label, "Heading", {
			Size = 14,
			Stroke = 0,
			Props = {
				Name = "Caption",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, 0),
				Size = UDim2.new(1.2, 0, 0, labelHeight),
				TextTruncate = Enum.TextTruncate.AtEnd,
			},
		})
		caption.Parent = root
	end

	-- little red "!" dot
	local badge = frame("Badge", {
		BackgroundColor3 = BUTTON_COLORS.Red or Color3.fromRGB(228, 90, 92),
		BackgroundTransparency = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.86, 0, 0.14, 0),
		Size = UDim2.fromOffset(20, 20),
		ZIndex = 4,
		Visible = props.Badge == true,
	}, button)
	round(badge)
	stroke(badge, NAVY, 2, 0)
	local badgeText = Theme.Label("!", "Button", {
		Size = 14,
		Stroke = 0.2,
		Props = { Name = "Mark", Size = UDim2.new(1, 0, 1, 0) },
	})
	badgeText.Parent = badge

	local function paint(hovering, pressing)
		local face = color
		if pressing then
			face = Theme.Darken(color, 0.08)
		elseif hovering then
			face = Theme.Lighten(color, 0.1)
		end
		faceGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Lighten(face, 0.34)),
			ColorSequenceKeypoint.new(0.5, Theme.Lighten(face, 0.06)),
			ColorSequenceKeypoint.new(0.76, Theme.Darken(face, 0.1)),
			ColorSequenceKeypoint.new(0.78, Theme.Darken(face, 0.34)),
			ColorSequenceKeypoint.new(1, Theme.Darken(face, 0.4)),
		})
		outline.Color = NAVY
	end
	attachFx(button, {
		Hover = 1.07,
		Press = 0.93,
		OnState = paint,
	})

	if props.Callback then
		button.Activated:Connect(function()
			props.Callback(button)
		end)
	end

	local widget = { Root = root, Button = button, Glyph = glyph, Caption = caption }

	function widget.SetBadge(on)
		badge.Visible = on and true or false
	end

	function widget.SetGlyph(text)
		glyph.Text = tostring(text or "")
	end

	function widget.SetLabel(text)
		if caption then
			caption.Text = tostring(text or "")
		end
	end

	function widget.SetColor(newColor)
		if typeof(newColor) == "Color3" then
			applyColor(newColor)
			glyph.TextStrokeColor3 = Theme.Darken(newColor, 0.65)
		end
	end

	root.Parent = props.Parent
	return widget
end

----------------------------------------------------------------------
-- Tooltip (one shared label, follows the mouse; long-press on touch)
----------------------------------------------------------------------
local tip = nil

local function ensureTip()
	if tip then
		return tip
	end
	local gui = CloudUI.NewScreenGui("CloudUITooltip", 60)
	gui.IgnoreGuiInset = true
	local label = Theme.Label("", "Body", {
		Size = 16,
		Stroke = 0.35,
		Props = {
			Name = "Tip",
			Visible = false,
			BackgroundTransparency = 0.05,
			BackgroundColor3 = Colors.Panel,
			BorderSizePixel = 0,
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, 0),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = 10,
		},
	})
	corner(label, 8)
	stroke(label, Colors.FrameTop or Colors.Cloud, 2, 0.15)
	padding(label, 10, 7, 10, 7)
	Util.Create("UISizeConstraint", { MaxSize = Vector2.new(280, 400), Parent = label })
	label.Parent = gui
	tip = { Gui = gui, Label = label, Owner = nil, Mode = "mouse", Ticker = nil }
	return tip
end

local function mouseLocation()
	local ok, pos = pcall(function()
		return UserInputService:GetMouseLocation()
	end)
	if ok and pos then
		return pos
	end
	return Vector2.new(0, 0)
end

local function hideTip(owner)
	if not tip or not tip.Owner then
		return
	end
	if owner and tip.Owner ~= owner then
		return
	end
	tip.Owner = nil
	tip.Label.Visible = false
	if tip.Ticker then
		tip.Ticker.dead = true
		tip.Ticker = nil
	end
end

local function placeTip()
	if not tip or not tip.Owner then
		return
	end
	local owner = tip.Owner
	if not owner.Parent or not isShown(owner) then
		hideTip(owner)
		return
	end
	local label = tip.Label
	local screen = tip.Gui.AbsoluteSize
	local size = label.AbsoluteSize
	local x, y
	if tip.Mode == "mouse" then
		local m = mouseLocation()
		x = m.X + 16
		y = m.Y + 22
		if screen.Y > 0 and y + size.Y > screen.Y - 6 then
			y = m.Y - size.Y - 14
		end
	else
		local pos = owner.AbsolutePosition
		local osize = owner.AbsoluteSize
		x = pos.X + osize.X * 0.5 - size.X * 0.5
		y = pos.Y - size.Y - 8
		if y < 6 then
			y = pos.Y + osize.Y + 8
		end
	end
	if screen.X > 0 then
		x = Util.Clamp(x, 6, math.max(6, screen.X - size.X - 6))
	end
	label.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
end

local function showTip(owner, text, mode)
	local t = ensureTip()
	hideTip()
	t.Owner = owner
	t.Mode = mode or "mouse"
	t.Label.Text = text
	t.Label.Visible = true
	placeTip()
	t.Ticker = addTicker(placeTip)
end

-- textFn: function() -> string|nil (or a plain string). Returns a function that removes the tooltip.
function CloudUI.Tooltip(guiObject, textFn)
	if not guiObject then
		return function() end
	end
	local token = 0
	local hovering = false
	local pressing = false
	local connections = {}

	local function resolve()
		local text = textFn
		if type(textFn) == "function" then
			local ok, value = pcall(textFn)
			text = ok and value or nil
		end
		if type(text) == "string" and text ~= "" then
			return text
		end
		return nil
	end

	table.insert(
		connections,
		guiObject.MouseEnter:Connect(function()
			hovering = true
			token = token + 1
			local mine = token
			task.delay(TOOLTIP_DELAY, function()
				if hovering and token == mine then
					local text = resolve()
					if text then
						showTip(guiObject, text, "mouse")
					end
				end
			end)
		end)
	)
	table.insert(
		connections,
		guiObject.MouseLeave:Connect(function()
			hovering = false
			token = token + 1
			hideTip(guiObject)
		end)
	)
	table.insert(
		connections,
		guiObject.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				pressing = true
				token = token + 1
				local mine = token
				task.delay(LONG_PRESS, function()
					if pressing and token == mine then
						local text = resolve()
						if text then
							showTip(guiObject, text, "object")
							task.delay(2.4, function()
								hideTip(guiObject)
							end)
						end
					end
				end)
			end
		end)
	)
	table.insert(
		connections,
		guiObject.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				pressing = false
				token = token + 1
			end
		end)
	)
	if guiObject:IsA("GuiButton") then
		table.insert(
			connections,
			guiObject.MouseButton1Down:Connect(function()
				token = token + 1
				hideTip(guiObject)
			end)
		)
	end

	return function()
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		connections = {}
		hideTip(guiObject)
	end
end

----------------------------------------------------------------------
-- Pet viewport
----------------------------------------------------------------------
local PetBuilderModule = nil
local PetCatalogModule = nil
local petBuilderTried = false
local petCatalogTried = false
local viewportCounter = 0

local function getPetBuilder()
	if not petBuilderTried then
		petBuilderTried = true
		local ok, result = pcall(function()
			return require(Shared:WaitForChild("PetBuilder", 5))
		end)
		if ok and type(result) == "table" then
			PetBuilderModule = result
		else
			warn("[CloudUI] PetBuilder is unavailable: " .. tostring(result))
		end
	end
	return PetBuilderModule
end

local function getPetCatalog()
	if not petCatalogTried then
		petCatalogTried = true
		local ok, result = pcall(function()
			return require(Shared:WaitForChild("PetCatalog", 5))
		end)
		if ok and type(result) == "table" then
			PetCatalogModule = result
		end
	end
	return PetCatalogModule
end

-- A ViewportFrame showing a PetBuilder model that spins slowly and flaps. All viewports share the one
-- CloudUI.Update loop; hidden viewports skip work and destroyed ones unregister themselves.
-- size: UDim2 | Vector2 | number (square pixels) | nil (fill the parent)
-- opts: Position, AnchorPoint, ZIndex, Animate (default true), Spin ("spin"|"sway"|"none", default "spin"),
--       Flap (speed multiplier), Excited (0..1)
function CloudUI.PetViewport(parent, petDef, size, opts)
	opts = opts or {}
	viewportCounter = viewportCounter + 1
	local phase = (viewportCounter * 0.83) % 6.28

	if type(petDef) == "string" then
		local catalog = getPetCatalog()
		petDef = catalog and catalog.Get(petDef) or nil
	end

	local viewport = Util.Create("ViewportFrame", {
		Name = "PetViewport",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = toUDim2(size, UDim2.new(1, 0, 1, 0)),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.new(0, 0),
		ZIndex = opts.ZIndex or 1,
		Ambient = Color3.fromRGB(176, 182, 206),
		LightColor = Color3.fromRGB(255, 246, 232),
		LightDirection = Vector3.new(-0.4, -0.8, 1), -- shines towards +Z: onto a model's -Z "front" (see side)
	})
	local camera = Util.Create("Camera", { FieldOfView = FOV, Parent = viewport })
	viewport.CurrentCamera = camera

	local animOpts = { Flap = opts.Flap or 1, Excited = opts.Excited or 0 }
	local animated = opts.Animate ~= false
	local spinMode = opts.Spin or "spin"
	local angle = 0.55
	local dead = false
	local model = nil
	local builder = nil

	local center = Vector3.new(0, 1, 0)
	local halfH, halfW = 1.5, 1.8
	local lastAspect = 1
	local side = -1 -- which side of the model the camera sits on: -1 = the -Z side (Roblox models face -Z)

	if petDef then
		builder = getPetBuilder()
		if builder then
			local ok, built = pcall(builder.Build, petDef, { Scale = 1 })
			if ok and typeof(built) == "Instance" then
				model = built
			else
				warn("[CloudUI] PetBuilder.Build failed: " .. tostring(built))
			end
		end
	end

	local function fit()
		local abs = viewport.AbsoluteSize
		local aspect = 1
		if abs.X > 0 and abs.Y > 0 then
			aspect = abs.X / abs.Y
		end
		lastAspect = aspect
		local t = math.tan(math.rad(FOV) / 2)
		local dist = math.max(halfH * 1.2 / t, halfW * 1.08 / (t * aspect))
		camera.CFrame = CFrame.lookAt(center + Vector3.new(0, halfH * 0.12, dist * side), center)
	end

	-- Pets face -Z like every Roblox model (CFrame.lookAt convention). If a model's eyes turn out to sit
	-- on its +Z side instead, put the camera (and the light) there so the viewport shows the face.
	-- Expects the model to be posed at the origin with an identity pivot.
	local function detectSide(m, c)
		local sum, count = 0, 0
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") and d.Name:lower():find("eye", 1, true) then
				sum = sum + (d.Position.Z - c.Z)
				count = count + 1
			end
		end
		if count > 0 and sum / count > 0.05 then
			return 1
		end
		return -1
	end

	local function pose(t, dt)
		if not model or not model.Parent then
			return
		end
		if spinMode == "spin" then
			angle = angle + dt * 0.8
		elseif spinMode == "sway" then
			angle = 0.5 + math.sin(t * 1.1 + phase) * 0.55
		end
		local bob = math.sin(t * 2.2 + phase) * halfH * 0.035
		model:PivotTo(CFrame.new(center + Vector3.new(0, bob, 0)) * CFrame.Angles(0, angle, 0) * CFrame.new(-center))
		pcall(builder.Animate, model, t + phase, animOpts)
	end

	if model then
		model.Parent = viewport
		pcall(function()
			model:PivotTo(CFrame.new())
		end)
		pcall(builder.Animate, model, 0.35, animOpts)
		local ok, cf, bbox = pcall(function()
			return model:GetBoundingBox()
		end)
		if ok and cf and bbox then
			center = cf.Position
			halfH = math.max(0.5, bbox.Y * 0.5)
			halfW = math.max(0.5, math.max(bbox.X, bbox.Z) * 0.5)
			local okSide, found = pcall(detectSide, model, center)
			if okSide and found then
				side = found
				viewport.LightDirection = Vector3.new(-0.4, -0.8, -side)
			end
		end
		pose(0.35, 0)
	else
		-- no model available: a friendly placeholder instead of an empty frame
		local name = petDef and petDef.Name or "?"
		local fallback = Theme.Label(tostring(name):sub(1, 1), "Title", {
			Scaled = true,
			Stroke = 0.2,
			Props = { Name = "Fallback", Size = UDim2.new(1, 0, 1, 0) },
		})
		fallback.Parent = viewport
	end
	fit()

	local handle = { Frame = viewport, Model = model }
	local ticker = nil
	local visibilityTimer = 1
	local stepTimer = 0
	local orphanTime = 0
	local shown = false

	function handle.Destroy()
		if dead then
			return
		end
		dead = true
		if ticker then
			ticker.dead = true
		end
		if model then
			model:Destroy()
			model = nil
		end
		viewport:Destroy()
	end

	function handle.SetAnimated(on)
		animated = on and true or false
		if not animated and model then
			angle = 0.55
			pose(0.35, 0)
		end
	end

	function handle.SetExcited(amount)
		animOpts.Excited = Util.Clamp(tonumber(amount) or 0, 0, 1)
	end

	if model then
		ticker = addTicker(function(dt, t)
			if dead then
				return
			end
			visibilityTimer = visibilityTimer + dt
			if visibilityTimer >= 0.25 then
				local elapsed = visibilityTimer
				visibilityTimer = 0
				if viewport:IsDescendantOf(game) then
					orphanTime = 0
				else
					orphanTime = orphanTime + elapsed
				end
				if orphanTime > 1.5 then
					handle.Destroy()
					return
				end
				shown = isShown(viewport)
				if shown then
					local abs = viewport.AbsoluteSize
					if abs.X > 0 and abs.Y > 0 and math.abs(abs.X / abs.Y - lastAspect) > 0.02 then
						fit()
					end
				end
			end
			if not shown or not animated then
				return
			end
			stepTimer = stepTimer + dt
			if stepTimer < 1 / 40 then
				return
			end
			local step = stepTimer
			stepTimer = 0
			pose(t, step)
		end)
	end

	viewport.Parent = parent
	return handle
end

----------------------------------------------------------------------
-- Slot (inventory / hotbar cell with a rarity border)
----------------------------------------------------------------------
local function petKey(info)
	if type(info) ~= "table" then
		return nil
	end
	local pet = info.Pet
	if type(pet) == "table" then
		return pet.Id
	elseif type(pet) == "string" then
		return pet
	end
	return nil
end

-- props: Size (default 72x72), Position, AnchorPoint, Parent, Callback, Hotkey, Name, LayoutOrder
-- info = { Glyph, Color, Pet = PetDef, RarityColor, Name, Blurb }
function CloudUI.Slot(props)
	props = props or {}
	local info = nil
	local selected = false
	local dimmed = false
	local hovering = false
	local viewportHandle = nil

	local root = frame(props.Name or "CloudSlot", {
		Size = props.Size or UDim2.fromOffset(72, 72),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.new(0, 0),
		LayoutOrder = props.LayoutOrder or 0,
	})

	local button = Util.Create("TextButton", {
		Name = "Button",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = "",
		BackgroundColor3 = WHITE,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 1, 0),
		Parent = root,
	})
	corner(button, 12)
	local outline = stroke(button, NAVY, 3, 0)
	local fill = gradient(button, ColorSequence.new(Colors.Mist, Colors.MistDeep), 90)

	local content = frame("Content", { Size = UDim2.new(1, 0, 1, 0) }, button)

	local countLabel = Theme.Label("", "Heading", {
		Size = 15,
		Stroke = 0,
		Props = {
			Name = "Count",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -5, 1, -3),
			Size = UDim2.new(0.8, 0, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Right,
			Visible = false,
			ZIndex = 5,
		},
	})
	countLabel.Parent = button

	local hotkeyChip = frame("Hotkey", {
		BackgroundColor3 = Colors.Panel,
		BackgroundTransparency = 0.1,
		Position = UDim2.new(0, 4, 0, 4),
		Size = UDim2.fromOffset(20, 20),
		ZIndex = 5,
		Visible = false,
	}, button)
	corner(hotkeyChip, 6)
	stroke(hotkeyChip, NAVY, 2, 0)
	local hotkeyLabel = Theme.Label("", "Heading", {
		Size = 13,
		Stroke = 0.2,
		Props = { Name = "Key", Size = UDim2.new(1, 0, 1, 0) },
	})
	hotkeyLabel.Parent = hotkeyChip

	local markerChip = frame("Marker", {
		BackgroundColor3 = GOLD,
		BackgroundTransparency = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 4),
		Size = UDim2.fromOffset(22, 22),
		ZIndex = 5,
		Visible = false,
	}, button)
	round(markerChip)
	stroke(markerChip, NAVY, 2, 0)
	local markerLabel = Theme.Label("", "Heading", {
		Size = 14,
		Stroke = 0.2,
		Props = { Name = "Mark", Size = UDim2.new(1, 0, 1, 0) },
	})
	markerLabel.Parent = markerChip

	local dimOverlay = frame("Dim", {
		BackgroundColor3 = Color3.fromRGB(14, 20, 52),
		BackgroundTransparency = 0.5,
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 6,
		Visible = false,
	}, button)
	corner(dimOverlay, 12)

	local flashOverlay = frame("Flash", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 7,
	}, button)
	corner(flashOverlay, 12)

	local function paint()
		local rarity = info and info.RarityColor
		if selected then
			outline.Color = GOLD
			outline.Thickness = 4
		else
			outline.Color = rarity or NAVY
			outline.Thickness = 3
		end
		if not info then
			fill.Color = ColorSequence.new(Color3.fromRGB(78, 108, 166), Color3.fromRGB(56, 82, 138))
			return
		end
		local tint = rarity or info.Color or Colors.MistDeep
		local top = Colors.Mist
		local bottom = Colors.MistDeep:Lerp(tint, rarity and 0.55 or 0.35)
		if selected then
			top = Theme.Lighten(top, 0.4)
		end
		fill.Color = ColorSequence.new(top, bottom)
	end

	local function clearContent()
		if viewportHandle then
			viewportHandle.Destroy()
			viewportHandle = nil
		end
		for _, child in ipairs(content:GetChildren()) do
			child:Destroy()
		end
	end

	local fx = attachFx(button, {
		Hover = 1.06,
		Press = 0.94,
		OnState = function(isHover)
			hovering = isHover
			if viewportHandle then
				viewportHandle.SetAnimated(hovering or selected)
				viewportHandle.SetExcited(hovering and 0.8 or 0)
			end
		end,
	})

	local slot = { Root = root, Button = button, Fx = fx }

	function slot.SetContent(newInfo)
		-- Windows re-render on every State.Changed: keep the (expensive) pet model when the same pet is shown again.
		local keepKey = viewportHandle ~= nil and petKey(info) or nil
		if keepKey ~= nil and keepKey == petKey(newInfo) then
			info = newInfo
			paint()
			return
		end
		clearContent()
		info = newInfo
		if info then
			if info.Pet then
				viewportHandle = CloudUI.PetViewport(content, info.Pet, UDim2.new(1, -8, 1, -8), {
					Position = UDim2.new(0.5, 0, 0.5, 0),
					AnchorPoint = Vector2.new(0.5, 0.5),
					Animate = hovering or selected,
					Spin = "sway",
				})
			elseif info.Glyph then
				local glyph = Theme.Label(tostring(info.Glyph), "Title", {
					Scaled = true,
					Stroke = 0.1,
					Color = info.Color or NAVY,
					StrokeColor = Theme.Darken(info.Color or NAVY, 0.7),
					Props = {
						Name = "Glyph",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.new(0.5, 0, 0.46, 0),
						Size = UDim2.new(0.62, 0, 0.62, 0),
					},
				})
				Util.Create("UITextSizeConstraint", { MaxTextSize = 44, MinTextSize = 8, Parent = glyph })
				glyph.Parent = content
			end
		end
		paint()
	end

	function slot.SetSelected(on)
		selected = on and true or false
		paint()
		if viewportHandle then
			viewportHandle.SetAnimated(hovering or selected)
		end
	end

	-- Pet slots hide counts of 1 ("x1" is noise); item slots always show their count.
	function slot.SetCount(n)
		if type(n) ~= "number" then
			countLabel.Visible = false
			return
		end
		local isPet = info ~= nil and info.Pet ~= nil
		countLabel.Text = "x" .. tostring(math.floor(n))
		countLabel.Visible = (not isPet) or n > 1
	end

	function slot.SetHotkey(text)
		local value = text and tostring(text) or ""
		hotkeyLabel.Text = value
		hotkeyChip.Visible = value ~= ""
	end

	-- small corner chip, e.g. "*" for an equipped pet; nil hides it
	function slot.SetMarker(text, color)
		local value = text and tostring(text) or ""
		markerLabel.Text = value
		markerChip.Visible = value ~= ""
		if typeof(color) == "Color3" then
			markerChip.BackgroundColor3 = color
		end
	end

	function slot.SetDimmed(on)
		dimmed = on and true or false
		dimOverlay.Visible = dimmed
	end

	-- quick white flash, e.g. after an item was used
	function slot.Flash()
		flashOverlay.BackgroundTransparency = 0.35
		Util.Tween(flashOverlay, 0.35, { BackgroundTransparency = 1 })
	end

	function slot.Destroy()
		clearContent()
		root:Destroy()
	end

	CloudUI.Tooltip(button, function()
		if not info or not info.Name then
			return nil
		end
		if info.Blurb then
			return tostring(info.Name) .. "\n" .. tostring(info.Blurb)
		end
		return tostring(info.Name)
	end)

	if props.Callback then
		button.Activated:Connect(function()
			props.Callback(slot)
		end)
	end

	slot.SetHotkey(props.Hotkey)
	slot.SetContent(nil)
	root.Parent = props.Parent
	return slot
end

----------------------------------------------------------------------
-- Tabs
----------------------------------------------------------------------
-- props: Parent, Size, Position, AnchorPoint, Name, BarHeight, OnSelect(name)
-- Add(name, builderFn): creates the page frame, calls builderFn(page) immediately (errors are
-- warned, not thrown) and returns the page. The first tab added is selected.
function CloudUI.Tabs(props)
	props = props or {}
	local barHeight = props.BarHeight or 38

	local root = frame(props.Name or "CloudTabs", {
		Size = props.Size or UDim2.new(1, 0, 1, 0),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.new(0, 0),
		LayoutOrder = props.LayoutOrder or 0,
	})
	local bar = frame("TabBar", { Size = UDim2.new(1, 0, 0, barHeight) }, root)
	Util.Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 8),
		Parent = bar,
	})
	local content = frame("TabContent", {
		Position = UDim2.new(0, 0, 0, barHeight + 8),
		Size = UDim2.new(1, 0, 1, -(barHeight + 8)),
	}, root)

	local pages = {}
	local buttons = {}
	local selected = nil
	local count = 0

	local activeFace = Theme.Lighten(BUTTON_COLORS.Blue or Color3.fromRGB(90, 158, 234), 0.1)
	local idleFace = Color3.fromRGB(88, 112, 166)

	local function paintTab(name, animate)
		local button = buttons[name]
		if not button then
			return
		end
		local on = (name == selected)
		local face = on and activeFace or idleFace
		local textColor = on and WHITE or MUTED
		if animate then
			Util.Tween(button, 0.14, { BackgroundColor3 = face, TextColor3 = textColor })
		else
			button.BackgroundColor3 = face
			button.TextColor3 = textColor
		end
	end

	local tabs = { Root = root, Content = content, Bar = bar }

	function tabs.Select(name)
		if not pages[name] then
			return
		end
		local changed = selected ~= name
		selected = name
		for pageName, page in pairs(pages) do
			page.Visible = (pageName == name)
			paintTab(pageName, true)
		end
		if changed and props.OnSelect then
			props.OnSelect(name)
		end
	end

	function tabs.Add(name, builderFn)
		count = count + 1
		local page = frame("Page_" .. tostring(name), {
			Size = UDim2.new(1, 0, 1, 0),
			Visible = false,
		}, content)
		pages[name] = page

		local button = Util.Create("TextButton", {
			Name = "Tab_" .. tostring(name),
			AutoButtonColor = false,
			BorderSizePixel = 0,
			BackgroundColor3 = idleFace,
			Text = tostring(name),
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 0, barHeight - 4),
			LayoutOrder = count,
		})
		Theme.Style(button, "Button", { Size = 18, Color = MUTED, Stroke = 0.1 })
		button.TextStrokeColor3 = Theme.Darken(idleFace, 0.6)
		corner(button, 11)
		stroke(button, NAVY, 3, 0)
		gradient(button, FACE_SEQUENCE, 90)
		padding(button, 18, 0, 18, UDim.new(0.16, 0))
		Util.Create("UISizeConstraint", { MinSize = Vector2.new(72, 0), Parent = button })
		button.Activated:Connect(function()
			tabs.Select(name)
		end)
		button.Parent = bar
		buttons[name] = button
		paintTab(name, false)

		if builderFn then
			local ok, err = pcall(builderFn, page)
			if not ok then
				warn("[CloudUI] tab '" .. tostring(name) .. "' builder failed: " .. tostring(err))
			end
		end
		if not selected then
			tabs.Select(name)
		end
		return page
	end

	function tabs.GetSelected()
		return selected
	end

	function tabs.GetPage(name)
		return pages[name]
	end

	function tabs.GetButton(name)
		return buttons[name]
	end

	root.Parent = props.Parent
	return tabs
end

----------------------------------------------------------------------
-- Grid
----------------------------------------------------------------------
-- cellSize: UDim2 | Vector2 | number; padding: number (px) | UDim2
function CloudUI.Grid(parent, cellSize, cellPadding)
	local cell = toUDim2(cellSize, UDim2.fromOffset(80, 80))
	local pad = toUDim2(cellPadding, UDim2.fromOffset(8, 8))

	local scroll = Util.Create("ScrollingFrame", {
		Name = "CloudGrid",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Colors.FrameTop or Colors.Cloud,
		ScrollBarImageTransparency = 0.1,
	})
	padding(scroll, 8, 8, 8, 8)
	Util.Create("UIGridLayout", {
		Name = "Layout",
		CellSize = cell,
		CellPadding = pad,
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		Parent = scroll,
	})
	scroll.Parent = parent
	return scroll
end

return CloudUI
