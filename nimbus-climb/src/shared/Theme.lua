-- Theme: fonts, colours and tiny UI builders so every label in the game looks consistent.
-- Plain Lua 5.1-compatible syntax only.

local Theme = {}

local function font(name, fallback)
	local ok, value = pcall(function()
		return Enum.Font[name]
	end)
	if ok and value then
		return value
	end
	return Enum.Font[fallback or "GothamBold"]
end

-- Font roles. Use roles, never raw Enum.Font, anywhere in the game.
Theme.Fonts = {
	Title = font("FredokaOne"), -- logo, banners, portal names
	Display = font("FredokaOne"), -- big numbers: timer, countdown, token count
	Heading = font("GothamBlack", "GothamBold"), -- panel headers, buttons
	Body = font("Nunito", "GothamMedium"), -- descriptions, toasts
	Label = font("GothamMedium"), -- tiny captions
	Accent = font("LuckiestGuy", "FredokaOne"), -- damage numbers, "GO!"
	Script = font("Fondamento", "Nunito"), -- flavour text / taglines
}

Theme.Colors = {
	SkyTop = Color3.fromRGB(86, 154, 255),
	SkyBottom = Color3.fromRGB(255, 196, 214),
	Cloud = Color3.fromRGB(250, 252, 255),
	CloudShade = Color3.fromRGB(205, 220, 245),
	Storm = Color3.fromRGB(78, 84, 112),
	Ink = Color3.fromRGB(34, 40, 72), -- text outlines
	Panel = Color3.fromRGB(28, 36, 74),
	PanelLight = Color3.fromRGB(60, 74, 130),
	Token = Color3.fromRGB(255, 214, 82),
	TokenGlow = Color3.fromRGB(255, 244, 170),
	Health = Color3.fromRGB(96, 230, 140),
	HealthMid = Color3.fromRGB(255, 208, 84),
	HealthLow = Color3.fromRGB(255, 92, 110),
	Stamina = Color3.fromRGB(110, 190, 255),
	Good = Color3.fromRGB(120, 235, 160),
	Bad = Color3.fromRGB(255, 110, 120),
	White = Color3.fromRGB(255, 255, 255),
	Rainbow = {
		Color3.fromRGB(255, 107, 129),
		Color3.fromRGB(255, 177, 94),
		Color3.fromRGB(255, 232, 110),
		Color3.fromRGB(120, 230, 150),
		Color3.fromRGB(110, 190, 255),
		Color3.fromRGB(176, 140, 255),
	},
}

-- Colour for a health fraction 0..1 (green -> amber -> red).
function Theme.HealthColor(fraction)
	if fraction > 0.6 then
		return Theme.Colors.Health
	elseif fraction > 0.3 then
		return Theme.Colors.HealthMid
	end
	return Theme.Colors.HealthLow
end

-- Apply a font role + outline to any TextLabel/TextButton/TextBox.
-- opts: Size, Color, Stroke (0..1 transparency, default 0.55), Scaled (bool)
function Theme.Style(obj, role, opts)
	opts = opts or {}
	obj.Font = Theme.Fonts[role] or Theme.Fonts.Body
	obj.TextColor3 = opts.Color or Theme.Colors.White
	obj.TextStrokeColor3 = Theme.Colors.Ink
	obj.TextStrokeTransparency = opts.Stroke or 0.55
	if opts.Scaled then
		obj.TextScaled = true
	elseif opts.Size then
		obj.TextSize = opts.Size
	end
	return obj
end

-- Build a styled TextLabel. props are applied after styling so you can override anything.
-- Theme.Label("Hello", "Title", {Size = 36, Props = {Position = UDim2.new(0, 0, 0, 0)}})
function Theme.Label(text, role, opts)
	opts = opts or {}
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	Theme.Style(label, role, opts)
	if opts.Props then
		for key, value in pairs(opts.Props) do
			label[key] = value
		end
	end
	return label
end

function Theme.Corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or UDim.new(0, 12)
	c.Parent = parent
	return c
end

function Theme.Stroke(parent, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.Colors.Ink
	s.Thickness = thickness or 2
	s.Transparency = transparency or 0.2
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

-- Vertical two-colour gradient on a GuiObject.
function Theme.Gradient(parent, top, bottom, rotation)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = rotation or 90
	g.Parent = parent
	return g
end

-- Rounded translucent panel used for every HUD card.
function Theme.Panel(props)
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Theme.Colors.Panel
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	Theme.Corner(frame, UDim.new(0, 14))
	Theme.Stroke(frame, Theme.Colors.PanelLight, 2, 0.35)
	if props then
		for key, value in pairs(props) do
			frame[key] = value
		end
	end
	return frame
end

return Theme
