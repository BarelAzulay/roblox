-- Theme: fonts, colours and tiny UI builders so every label in the game looks consistent.
-- v2: calmer, darker, clearer palette (late-afternoon cloud world), the in-world palette
-- `Theme.World` (used by LobbyBuilder / CourseBuilder / TokenService / HazardService) and the
-- palette tokens the chunky "cloud" UI kit (client/UI/CloudUI.lua) is built from.
-- Plain Lua 5.1-compatible syntax only. Safe to require on the server and on the client.

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
	Title = font("FredokaOne"), -- logo, banners, portal names, window ribbons
	Display = font("FredokaOne"), -- big numbers: timer, countdown, token count
	Heading = font("GothamBlack", "GothamBold"), -- panel headers, captions, counts
	Body = font("Nunito", "GothamMedium"), -- descriptions
	Label = font("GothamMedium"), -- tiny captions
	Accent = font("LuckiestGuy", "FredokaOne"), -- damage numbers, "GO!"
	Script = font("Fondamento", "Nunito"), -- flavour text / taglines
	-- v2 additions
	Toast = font("LuckiestGuy", "FredokaOne"), -- small side-of-screen system messages (cool, chunky)
	Button = font("FredokaOne", "GothamBlack"), -- text on chunky buttons and tabs
}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

Theme.Colors = {
	-- Existing keys (other modules depend on every one of them) with the calmer v2 values.
	SkyTop = rgb(66, 116, 192),
	SkyBottom = rgb(212, 164, 184),
	Cloud = rgb(214, 224, 240),
	CloudShade = rgb(150, 168, 200),
	Storm = rgb(54, 60, 88),
	Ink = rgb(26, 32, 64), -- text outlines
	Panel = rgb(30, 40, 80), -- dark HUD cards
	PanelLight = rgb(64, 84, 142),
	Token = rgb(238, 190, 62),
	TokenGlow = rgb(250, 224, 132),
	Health = rgb(92, 206, 128),
	HealthMid = rgb(238, 190, 72),
	HealthLow = rgb(236, 88, 100),
	Stamina = rgb(98, 172, 232),
	Good = rgb(108, 208, 144),
	Bad = rgb(240, 102, 112),
	White = rgb(255, 255, 255), -- text only
	Rainbow = {
		rgb(232, 104, 120),
		rgb(240, 160, 88),
		rgb(240, 208, 98),
		rgb(104, 200, 142),
		rgb(98, 168, 232),
		rgb(160, 130, 232),
	},

	-- v2 UI-kit tokens (CloudUI)
	Navy = rgb(24, 34, 78), -- thick outlines around panels, buttons, slots
	Outline = rgb(24, 34, 78), -- alias of Navy
	FrameTop = rgb(176, 212, 244), -- outer window frame, top colour
	FrameBottom = rgb(112, 158, 216), -- outer window frame, bottom colour
	WellTop = rgb(60, 96, 164), -- inner content well, top colour
	WellBottom = rgb(40, 68, 128), -- inner content well, bottom colour
	WellEdge = rgb(22, 34, 82),
	Mist = rgb(226, 234, 246), -- pale cloud used for slot fills (never pure white)
	MistDeep = rgb(176, 196, 228),
	Gold = rgb(244, 196, 78),
	-- Secondary text on dark wells. 4.6:1 on WellTop, 7.1:1 on WellBottom, 5.5:1 on PanelLight
	-- (the old (176,192,222) gave only 3.4:1 on WellTop); still clearly dimmer than White.
	Muted = rgb(212, 224, 246),
}

-- Base colours of the glossy button styles (CloudUI.Button / IconButton).
Theme.Buttons = {
	Green = rgb(96, 196, 108),
	Pink = rgb(238, 126, 176),
	Red = rgb(228, 90, 92),
	Blue = rgb(90, 158, 234),
	Gold = rgb(244, 190, 70),
	Gray = rgb(144, 156, 180),
}

-- Pill / toast colours by kind.
Theme.Kinds = {
	info = rgb(90, 158, 234),
	good = rgb(96, 196, 108),
	bad = rgb(228, 90, 92),
	token = rgb(240, 188, 66),
}

-- In-world palette for Parts (lobby, courses, tokens, hazards). Calm, never pure white; platform
-- tops are clearly lighter than their sides, hazards are a distinct dark red/purple, checkpoints
-- teal. Trim colours are per difficulty id (Config.Difficulties order) and also by index.
Theme.World = {
	-- Peaks are 214 / 184 / 150 on purpose: the same ceiling LobbyBuilder clamps to, so the lobby
	-- and every course platform (and the Start/Finish pads) share one calm palette and the blue
	-- channel does not clip towards white-cyan under the late-afternoon sun.
	CloudTop = rgb(183, 194, 214),
	CloudSide = rgb(135, 152, 184),
	CloudShadow = rgb(96, 113, 150),
	Hazard = rgb(160, 62, 94),
	HazardGlow = rgb(222, 100, 124),
	Checkpoint = rgb(62, 172, 152),
	Token = rgb(238, 194, 86),
	Storm = rgb(58, 64, 94),
	Wind = rgb(150, 198, 226),
	Water = rgb(96, 156, 214),
	Trim = {
		Easy = rgb(96, 190, 140),
		Medium = rgb(96, 160, 224),
		Hard = rgb(226, 150, 74),
		Extreme = rgb(214, 92, 104),
		Saint = rgb(150, 110, 220), -- violet, mirrors Config.Difficulties Saint (gold is reserved for stars/tokens)
		rgb(96, 190, 140),
		rgb(96, 160, 224),
		rgb(226, 150, 74),
		rgb(214, 92, 104),
		rgb(150, 110, 220),
	},
	Rainbow = {
		rgb(206, 96, 112),
		rgb(214, 148, 84),
		rgb(214, 190, 96),
		rgb(100, 174, 128),
		rgb(92, 150, 206),
		rgb(142, 118, 206),
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

----------------------------------------------------------------------
-- Colour helpers (shading stays navy-tinted so shadows feel cool, not muddy)
----------------------------------------------------------------------
local SHADE_TARGET = Color3.fromRGB(14, 20, 52)
local LIGHT_TARGET = Color3.fromRGB(238, 244, 255)

function Theme.Mix(a, b, t)
	return a:Lerp(b, t)
end

-- k in 0..1: how far towards the dark navy shade.
function Theme.Darken(color, k)
	return color:Lerp(SHADE_TARGET, k)
end

-- k in 0..1: how far towards soft pale cloud (never pure white).
function Theme.Lighten(color, k)
	return color:Lerp(LIGHT_TARGET, k)
end

----------------------------------------------------------------------
-- Text + small GUI builders
----------------------------------------------------------------------

-- Apply a font role + outline to any TextLabel/TextButton/TextBox.
-- opts: Size, Color, Stroke (0..1 transparency, default 0.55), StrokeColor, Scaled (bool)
function Theme.Style(obj, role, opts)
	opts = opts or {}
	obj.Font = Theme.Fonts[role] or Theme.Fonts.Body
	obj.TextColor3 = opts.Color or Theme.Colors.White
	obj.TextStrokeColor3 = opts.StrokeColor or Theme.Colors.Ink
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

-- Rounded translucent dark card used for compact HUD elements (windows use CloudUI.Panel).
function Theme.Panel(props)
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Theme.Colors.Panel
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	Theme.Corner(frame, UDim.new(0, 14))
	Theme.Stroke(frame, Theme.Colors.Navy, 3, 0.15)
	if props then
		for key, value in pairs(props) do
			frame[key] = value
		end
	end
	return frame
end

return Theme
