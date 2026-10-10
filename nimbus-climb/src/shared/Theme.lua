-- Theme: fonts, colours, text sizes and tiny UI builders so every label in the game looks consistent.
-- v2: calmer, darker, clearer palette (late-afternoon cloud world), the in-world palette `Theme.World`
-- (LobbyBuilder / CourseBuilder / TokenService / HazardService) and the palette tokens of the chunky
-- "cloud" UI kit (client/UI/CloudUI.lua).
-- v3: the READABILITY RULE (ARCHITECTURE_V3.md): at 1920x1080 body text >= 18 px, small captions >= 15 px,
-- buttons >= 20 px, titles 28-44 px; everything scales with the screen height
-- (factor clamp(viewportY / 1080, 0.8, 1.25)) and nothing ever drops below 14 px. Every text gets a stroke
-- or sits on a solid panel.
--   * Theme.Sizes[role]          default size per font role at 1080p (applied by Theme.Style / Theme.Label)
--   * Theme.ScreenFactor()       the screen-height factor (1 on the server)
--   * Theme.ScaledSize(basePx)   basePx (a 1080p size) for the current screen, never below 14
--   * Theme.TextOutline(label)   a thick UIStroke around the glyphs (reads on light and busy backgrounds)
--   * Theme.Currency / Theme.ShortNumber(n)   currency glyphs + colours and "12.3K" style numbers
-- Two ways to follow the rule: put widgets designed in 1080p pixels under a UIScale of Theme.ScreenFactor()
-- (CloudUI.AutoScale does that), or give a loose label TextSize = Theme.ScaledSize(base). Never both.
-- Plain Lua 5.1-compatible syntax only. Safe to require on the server and on the client.

local Theme = {}

local function font(name, fallback)
	local ok, value = pcall(function()
		return Enum.Font[name]
	end)
	if ok and value then
		return value
	end
	local okFallback, fallbackValue = pcall(function()
		return Enum.Font[fallback or "GothamBold"]
	end)
	if okFallback and fallbackValue then
		return fallbackValue
	end
	return Enum.Font.GothamBold
end

-- Font roles. Use roles, never raw Enum.Font, anywhere in the game.
-- v3: Body and Label moved to the heavier Builder Sans cuts (far easier to read at small sizes on busy
-- backgrounds); the chunky display faces stay.
Theme.Fonts = {
	Title = font("FredokaOne"), -- logo, banners, portal names, window titles
	Display = font("FredokaOne"), -- big numbers: timer, countdown, currency counts
	Heading = font("GothamBlack", "GothamBold"), -- panel headers, captions, counts
	Body = font("BuilderSansBold", "GothamBold"), -- descriptions, dialog text
	Label = font("BuilderSansBold", "GothamMedium"), -- small captions
	Accent = font("LuckiestGuy", "FredokaOne"), -- damage numbers, "GO!"
	Script = font("Fondamento", "Nunito"), -- flavour text / taglines
	-- v2 additions
	Toast = font("LuckiestGuy", "FredokaOne"), -- side-of-screen system messages (cool, chunky)
	Button = font("FredokaOne", "GothamBlack"), -- text on chunky buttons and tabs
}

----------------------------------------------------------------------
-- Readability rule (v3)
----------------------------------------------------------------------
Theme.Readability = {
	RefHeight = 1080, -- sizes below are pixels on a 1920x1080 screen
	MinFactor = 0.8, -- phones / small windows
	MaxFactor = 1.25, -- 1440p and up
	MinPx = 14, -- nothing is ever rendered smaller
	Caption = 15,
	Body = 18,
	Button = 20,
	TitleMin = 28,
	TitleMax = 44,
}

-- Default TextSize per font role at 1080p (design pixels). Theme.Style uses them whenever the caller gives
-- no Size; widgets under a UIScale of Theme.ScreenFactor() then follow the rule automatically.
Theme.Sizes = {
	Title = 34,
	Display = 32,
	Heading = 22,
	Body = 19,
	Label = 16,
	Accent = 30,
	Script = 19,
	Toast = 18,
	Button = 22,
}

local function clamp(n, lo, hi)
	if n < lo then
		return lo
	elseif n > hi then
		return hi
	end
	return n
end

local function viewportHeight()
	local ok, height = pcall(function()
		local camera = workspace.CurrentCamera
		return camera and camera.ViewportSize.Y or 0
	end)
	if ok and type(height) == "number" then
		return height
	end
	return 0
end

local function isClient()
	local ok, result = pcall(function()
		return game:GetService("RunService"):IsClient()
	end)
	return ok and result == true
end

-- The screen-height factor of the readability rule: clamp(viewportY / 1080, 0.8, 1.25).
-- `height` (optional) overrides the measured viewport height. On the server (no screen) it is 1.
function Theme.ScreenFactor(height)
	local r = Theme.Readability
	local h = tonumber(height)
	if not h then
		if not isClient() then
			return 1
		end
		h = viewportHeight()
	end
	if not h or h < 2 then
		return 1
	end
	return clamp(h / r.RefHeight, r.MinFactor, r.MaxFactor)
end

-- A 1080p pixel size scaled for the current screen, rounded, never below `minPx` (default 14).
-- Use it for text that is NOT under a UIScale (tooltips, billboards, loose labels).
function Theme.ScaledSize(basePx, minPx)
	local base = tonumber(basePx) or Theme.Readability.Body
	local floorPx = tonumber(minPx) or Theme.Readability.MinPx
	return math.max(floorPx, math.floor(base * Theme.ScreenFactor() + 0.5))
end

-- Default size of a role (1080p design pixels).
function Theme.RoleSize(role)
	return Theme.Sizes[role] or Theme.Sizes.Body
end

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

	-- v3 additions
	TextStroke = rgb(16, 22, 50), -- the thick glyph outline (Theme.TextOutline), a touch darker than Ink
	TextDark = rgb(30, 40, 82), -- text that sits directly on a pale fill (Mist slots, light pills)
	TitleBar = rgb(98, 160, 236), -- default window title bar (CloudUI.Panel without an Accent)
	Cash = rgb(112, 204, 98),
	CashGlow = rgb(196, 240, 150),
	Gem = rgb(84, 196, 246),
	GemGlow = rgb(186, 236, 255),
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

-- Currencies (v3): glyph, attribute name (Config.Attr values) and the coin colours used by the HUD stack,
-- the shop and price tags. Cash and Gems arrive with the tycoon phase.
Theme.Currency = {
	Tokens = {
		Id = "Tokens",
		Name = "Cloud Tokens",
		Attr = "CloudTokens",
		Glyph = "\226\152\129", -- cloud
		Color = rgb(238, 190, 62),
		Glow = rgb(250, 224, 132),
	},
	Cash = {
		Id = "Cash",
		Name = "Cash",
		Attr = "Cash",
		Glyph = "$",
		Color = rgb(112, 204, 98),
		Glow = rgb(196, 240, 150),
	},
	Gems = {
		Id = "Gems",
		Name = "Gems",
		Attr = "Gems",
		Glyph = "\226\151\134", -- black diamond
		Color = rgb(84, 196, 246),
		Glow = rgb(186, 236, 255),
	},
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
-- Numbers
----------------------------------------------------------------------
local SUFFIXES = { "K", "M", "B", "T", "Qa", "Qi" }

local function commas(n)
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return out
end

local function trimDecimals(text)
	if text:find("%.") then
		text = text:gsub("0+$", "")
		text = text:gsub("%.$", "")
	end
	return text
end

-- Big-number display: below `fullBelow` (default 10000) with thousands separators ("9,999"), above it
-- three significant digits plus a suffix ("12.3K", "456K", "1.23M", "7B"). Digits are truncated, never
-- rounded up, so the display never claims more than the player has.
function Theme.ShortNumber(n, fullBelow)
	n = tonumber(n) or 0
	if n ~= n then -- NaN
		n = 0
	end
	local sign = ""
	if n < 0 then
		sign = "-"
		n = -n
	end
	n = math.floor(n)
	if n < (tonumber(fullBelow) or 10000) then
		return sign .. commas(n)
	end
	local value = n
	local index = 0
	while value >= 1000 and index < #SUFFIXES do
		value = value / 1000
		index = index + 1
	end
	if index == 0 then
		return sign .. commas(n)
	end
	local text
	if value >= 100 then
		text = tostring(math.floor(value))
	elseif value >= 10 then
		text = trimDecimals(string.format("%.1f", math.floor(value * 10) / 10))
	else
		text = trimDecimals(string.format("%.2f", math.floor(value * 100) / 100))
	end
	return sign .. text .. SUFFIXES[index]
end

----------------------------------------------------------------------
-- Text + small GUI builders
----------------------------------------------------------------------

-- Thick outline around the GLYPHS of a text object (a UIStroke in Contextual mode). Reuses an existing
-- outline made by this function. Use it on labels without a border stroke (a UIStroke in Border mode
-- outlines the box instead; CloudUI puts both on its buttons).
function Theme.TextOutline(obj, thickness, color, transparency)
	if not obj then
		return nil
	end
	local outline = obj:FindFirstChild("TextOutline")
	if not (outline and outline:IsA("UIStroke")) then
		outline = Instance.new("UIStroke")
		outline.Name = "TextOutline"
		outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		outline.LineJoinMode = Enum.LineJoinMode.Round
		outline.Parent = obj
	end
	outline.Color = color or Theme.Colors.TextStroke
	outline.Thickness = thickness or 2
	outline.Transparency = transparency or 0
	return outline
end

-- Apply a font role + outline to any TextLabel/TextButton/TextBox.
-- opts: Size (design px; default Theme.Sizes[role]), Color, Stroke (0..1 transparency of the classic text
--       stroke, default 0.4), StrokeColor, Scaled (bool), Outline (thickness: adds Theme.TextOutline),
--       OutlineColor, OnLight (bool: dark text stroke at full strength for pale or busy backgrounds)
function Theme.Style(obj, role, opts)
	opts = opts or {}
	obj.Font = Theme.Fonts[role] or Theme.Fonts.Body
	obj.TextColor3 = opts.Color or Theme.Colors.White
	obj.TextStrokeColor3 = opts.StrokeColor or Theme.Colors.Ink
	local stroke = opts.Stroke
	if stroke == nil then
		stroke = opts.OnLight and 0 or 0.4
	end
	obj.TextStrokeTransparency = stroke
	if opts.Scaled then
		obj.TextScaled = true
	elseif opts.Size then
		obj.TextSize = opts.Size
	else
		obj.TextSize = Theme.RoleSize(role)
	end
	if opts.Outline then
		local thickness = tonumber(opts.Outline) or 2
		Theme.TextOutline(obj, thickness, opts.OutlineColor or opts.StrokeColor or Theme.Colors.TextStroke, 0)
	end
	return obj
end

-- Build a styled TextLabel. props are applied after styling so you can override anything.
-- Theme.Label("Hello", "Title", {Size = 36, Outline = 2, Props = {Position = UDim2.new(0, 0, 0, 0)}})
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

-- Rounded dark card used for compact HUD elements (windows use CloudUI.Panel). v3: a solid card (text on
-- it always reads), a thick navy outline and a soft top-to-bottom gradient.
function Theme.Panel(props)
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Theme.Colors.White
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	Theme.Corner(frame, UDim.new(0, 14))
	Theme.Stroke(frame, Theme.Colors.Navy, 3, 0)
	Theme.Gradient(frame, Theme.Colors.PanelLight, Theme.Colors.Panel, 90)
	if props then
		for key, value in pairs(props) do
			frame[key] = value
		end
	end
	return frame
end

return Theme
