-- DamageFx (client, v2): everything the player sees and feels when they get hurt (or get paid).
--
--   DamageFx.Init()
--
-- What it does
--   * Remotes.DamageTaken(amount, kind): a SUBTLE coloured vignette on the screen EDGES only (four gradient
--     strips, no images; the middle of the screen stays clear), a short camera shake, and a small floating
--     "-12" number with a kind word ("ZAP!") that pops, rises and fades above the local player's head.
--   * Storm damage arrives four times a second, so it is merged into one gentle number every
--     STORM_INTERVAL seconds instead of spamming the screen.
--   * The MatchTokens player attribute going up pops a golden "+n ☁" above the head (golden tokens get a
--     bigger, paler pop).
--
-- Colours follow the calmer v2 palette: nothing flashes white, the lightning flash is a faint warm wash.
-- v3 readability rule: the floating texts are sized with Theme.ScaledSize (1080p sizes scaled by the screen
-- height, never below 14 px) and carry a thick glyph outline, so they read over sky, clouds and grass alike.
--
-- Camera shake
--   The shake is driven through Humanoid.CameraOffset by a RenderStepped connection that exists only
--   while there is shake left. Whenever the shake ends, the character goes away or the humanoid
--   changes, CameraOffset is put back to zero, so the camera can never stay displaced.
--
-- Plain Lua 5.1-compatible syntax only. All fonts come from Theme.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent.Parent
local CloudUI = require(Client:WaitForChild("UI"):WaitForChild("CloudUI"))

local DamageFx = {}

local LocalPlayer = Players.LocalPlayer
local ATTR = Config.Attr

----------------------------------------------------------------------
-- Tuning
----------------------------------------------------------------------
local STORM_INTERVAL = 0.6 -- seconds between merged storm damage numbers
local MAX_LIVE_FLOATS = 12 -- hard cap on simultaneous floating texts

local SHAKE_MAX = 0.8 -- studs of camera offset at full trauma
local SHAKE_DECAY = 2.6 -- trauma lost per second
local SHAKE_SPEED = 1.0 -- multiplier for the shake oscillation speed

-- 1080p design sizes of the floating texts (scaled per screen by Theme.ScaledSize)
local FLOAT_W = 260
local FLOAT_H = 120
local NUMBER_SIZE = 40
local NUMBER_SIZE_BIG = 48 -- hits of 25+
local WORD_SIZE = 24
local TOKEN_SIZE = 34
local TOKEN_SIZE_GOLDEN = 42

local Colors = Theme.Colors

-- Per damage kind: the word, the number colour, the vignette colour and how hard it shakes.
-- (All kinds of Config.Damage.Kinds are covered; anything unknown falls back to Other.)
local KIND_STYLE = {
	Void = {
		Word = "SPLASH",
		Color = Color3.fromRGB(190, 168, 242),
		Vignette = Color3.fromRGB(120, 88, 214),
		Shake = 0.5,
	},
	Lightning = {
		Word = "ZAP!",
		Color = Color3.fromRGB(244, 226, 134),
		Vignette = Color3.fromRGB(226, 196, 84),
		Shake = 0.8,
		Flash = true,
	},
	SpinBar = {
		Word = "WHACK!",
		Color = Color3.fromRGB(240, 156, 112),
		Vignette = Color3.fromRGB(214, 84, 76),
		Shake = 0.6,
	},
	Pendulum = {
		Word = "BONK!",
		Color = Color3.fromRGB(236, 170, 120),
		Vignette = Color3.fromRGB(206, 100, 80),
		Shake = 0.6,
	},
	Storm = {
		Word = "DRIZZLE",
		Color = Color3.fromRGB(150, 192, 238),
		Vignette = Color3.fromRGB(80, 118, 196),
		Shake = 0.1,
		Soft = true,
	},
	Other = {
		Word = "OOF!",
		Color = Colors.Bad,
		Vignette = Color3.fromRGB(204, 72, 92),
		Shake = 0.4,
	},
}

-- Smooth falloff for the vignette strips (strongest at the screen edge, clear towards the middle).
local VIGNETTE_FALLOFF = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.4, 0.6),
	NumberSequenceKeypoint.new(0.75, 0.9),
	NumberSequenceKeypoint.new(1, 1),
})

-- rotation: UIGradient offset 0 sits at the screen edge. 90 = top edge, -90 = bottom, 0 = left, 180 = right.
-- The strips are narrow: only the outer fifth of the screen is ever tinted.
local EDGE_DEFS = {
	{ Name = "Top", Anchor = Vector2.new(0, 0), Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 0.22), Rotation = 90 },
	{ Name = "Bottom", Anchor = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0.22), Rotation = -90 },
	{ Name = "Left", Anchor = Vector2.new(0, 0), Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(0.14, 1), Rotation = 0 },
	{ Name = "Right", Anchor = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(0.14, 1), Rotation = 180 },
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local initialized = false
local rng = Random.new()

local vignette = nil -- { holder, edges, tweens, flash, flashTween, token }
local liveFloats = 0

local shake = { trauma = 0, clock = 0, conn = nil, humanoid = nil, px = 0, py = 0 }

local stormAccum = 0
local stormLastShow = -10
local stormScheduled = false

local lastMatchTokens = 0

----------------------------------------------------------------------
-- Screen vignette
----------------------------------------------------------------------
local function buildScreenGui()
	local gui = CloudUI.NewScreenGui("NimbusDamageFx", 5) -- below the HUD (10)

	local holder = Instance.new("Frame")
	holder.Name = "Vignette"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromScale(1, 1)
	holder.Visible = false
	holder.Parent = gui

	local edges = {}
	for _, def in ipairs(EDGE_DEFS) do
		local edge = Instance.new("Frame")
		edge.Name = def.Name
		edge.AnchorPoint = def.Anchor
		edge.Position = def.Position
		edge.Size = def.Size
		edge.BorderSizePixel = 0
		edge.BackgroundColor3 = KIND_STYLE.Other.Vignette
		edge.BackgroundTransparency = 1
		edge.Parent = holder

		local gradient = Instance.new("UIGradient")
		gradient.Rotation = def.Rotation
		gradient.Transparency = VIGNETTE_FALLOFF
		gradient.Parent = edge

		table.insert(edges, edge)
	end

	-- faint warm wash used for lightning (never a white-out)
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Color3.fromRGB(240, 228, 190)
	flash.BackgroundTransparency = 1
	flash.Visible = false
	flash.Parent = gui

	vignette = { holder = holder, edges = edges, tweens = {}, flash = flash, flashTween = nil, token = 0 }
end

-- Fade the kind-coloured edges from startT to invisible over 'seconds'.
local function flashVignette(color, startT, seconds)
	local v = vignette
	if not v then
		return
	end
	v.token = v.token + 1
	local token = v.token
	v.holder.Visible = true
	for i, edge in ipairs(v.edges) do
		-- a running tween would overwrite the value we set below, so stop it first
		local old = v.tweens[i]
		if old then
			old:Cancel()
		end
		edge.BackgroundColor3 = color
		edge.BackgroundTransparency = startT
		v.tweens[i] = Util.Tween(edge, seconds, { BackgroundTransparency = 1 })
	end
	task.delay(seconds + 0.05, function()
		if vignette and vignette.token == token then
			vignette.holder.Visible = false
		end
	end)
end

local function flashScreen(startT, seconds)
	local v = vignette
	if not v then
		return
	end
	if v.flashTween then
		v.flashTween:Cancel()
	end
	v.flash.Visible = true
	v.flash.BackgroundTransparency = startT
	local tween = Util.Tween(v.flash, seconds, { BackgroundTransparency = 1 })
	v.flashTween = tween
	task.delay(seconds + 0.05, function()
		if vignette and vignette.flashTween == tween then
			vignette.flash.Visible = false
		end
	end)
end

----------------------------------------------------------------------
-- Camera shake (Humanoid.CameraOffset, always restored)
----------------------------------------------------------------------
local function stopShake()
	if shake.conn then
		shake.conn:Disconnect()
		shake.conn = nil
	end
	shake.trauma = 0
	local humanoid = shake.humanoid
	shake.humanoid = nil
	if humanoid then
		pcall(function()
			humanoid.CameraOffset = Vector3.new(0, 0, 0)
		end)
	end
end

local function stepShake(dt)
	local humanoid = shake.humanoid
	if not humanoid or not humanoid.Parent then
		stopShake()
		return
	end
	shake.trauma = shake.trauma - SHAKE_DECAY * dt
	if shake.trauma <= 0 then
		stopShake()
		return
	end
	shake.clock = shake.clock + dt * SHAKE_SPEED
	local t = shake.clock
	local magnitude = shake.trauma * shake.trauma * SHAKE_MAX
	-- two incommensurate sines per axis read as noise without needing a random value per frame
	local x = (math.sin(t * 41 + shake.px) + 0.6 * math.sin(t * 67 + shake.py)) / 1.6
	local y = (math.sin(t * 53 + shake.py) + 0.6 * math.sin(t * 79 + shake.px)) / 1.6
	humanoid.CameraOffset = Vector3.new(x * magnitude, y * magnitude, 0)
end

local function addShake(amount)
	if amount <= 0 then
		return
	end
	local humanoid = Util.GetHumanoid(LocalPlayer)
	if not humanoid then
		return
	end
	if shake.humanoid ~= humanoid then
		stopShake() -- gives the previous humanoid (if any) its camera back
		shake.humanoid = humanoid
		shake.px = rng:NextNumber(0, 6.28)
		shake.py = rng:NextNumber(0, 6.28)
	end
	shake.trauma = math.min(1, shake.trauma + amount)
	if not shake.conn then
		shake.conn = RunService.RenderStepped:Connect(stepShake)
	end
end

----------------------------------------------------------------------
-- Floating texts (damage numbers, token pops)
----------------------------------------------------------------------
-- The part floating text hangs above, plus how many studs higher to start for that part.
local function getAnchor()
	local char = LocalPlayer.Character
	if not char then
		return nil, 0
	end
	local head = char:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head, 0
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root, 1.5
	end
	return nil, 0
end

-- cfg: Text, Word (optional kind word), Color, WordColor, TextSize, Rise, Life, StartX, StartY,
--      Gradient = { top, bottom } (optional; tints the number with a UIGradient)
local function spawnFloat(cfg)
	if liveFloats >= MAX_LIVE_FLOATS then
		return
	end
	local anchor, bias = getAnchor()
	if not anchor then
		return
	end
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end

	local startOffset = Vector3.new(cfg.StartX or 0, (cfg.StartY or 2.6) + bias, 0)
	local endOffset = startOffset + Vector3.new(0, cfg.Rise or 3, 0)
	local life = cfg.Life or 1.1
	local factor = Theme.ScreenFactor()

	local board = Instance.new("BillboardGui")
	board.Name = "NC_FloatText"
	board.Adornee = anchor
	board.AlwaysOnTop = true
	board.LightInfluence = 0
	board.ResetOnSpawn = false
	board.Size = UDim2.fromOffset(math.floor(FLOAT_W * factor), math.floor(FLOAT_H * factor))
	board.StudsOffset = startOffset

	-- the scale pop lives on an inner frame so the billboard itself keeps its size
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = board

	local scale = Instance.new("UIScale")
	scale.Scale = 0.3
	scale.Parent = root

	local texts = {}
	local outlines = {}
	local textSize = Theme.ScaledSize(cfg.TextSize or NUMBER_SIZE)
	local outlineColor = Theme.Darken(cfg.Color or Colors.Bad, 0.72)
	local number = Theme.Label(cfg.Text, "Accent", {
		Size = textSize,
		Color = cfg.Color,
		Stroke = 0.1,
		StrokeColor = outlineColor,
		Outline = 3,
		OutlineColor = outlineColor,
		Props = {
			Name = "Number",
			Size = UDim2.new(1, 0, 0, math.floor(textSize * 1.3)),
			Position = UDim2.new(0, 0, 0.5, -math.floor(textSize * 0.5)),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
		},
	})
	number.Parent = root
	table.insert(texts, number)
	table.insert(outlines, number:FindFirstChild("TextOutline"))
	if cfg.Gradient then
		-- UIGradient multiplies the text colour, so the label itself must be white
		number.TextColor3 = Colors.White
		Theme.Gradient(number, cfg.Gradient[1], cfg.Gradient[2], 90)
	end

	if cfg.Word then
		local wordSize = Theme.ScaledSize(WORD_SIZE)
		local wordColor = cfg.WordColor or cfg.Color
		local wordOutline = Theme.Darken(wordColor or Colors.Bad, 0.72)
		local word = Theme.Label(cfg.Word, "Accent", {
			Size = wordSize,
			Color = wordColor,
			Stroke = 0.15,
			StrokeColor = wordOutline,
			Outline = 2,
			OutlineColor = wordOutline,
			Props = {
				Name = "Word",
				Size = UDim2.new(1, 0, 0, math.floor(wordSize * 1.3)),
				Position = UDim2.new(0, 0, 0.5, -math.floor(textSize * 0.5 + wordSize * 1.25)),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Center,
			},
		})
		word.Parent = root
		table.insert(texts, word)
		table.insert(outlines, word:FindFirstChild("TextOutline"))
	end

	board.Parent = playerGui
	liveFloats = liveFloats + 1

	Util.Tween(scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	Util.Tween(board, life, { StudsOffset = endOffset }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	task.delay(life * 0.55, function()
		if not board.Parent then
			return
		end
		for _, label in ipairs(texts) do
			Util.Tween(label, life * 0.45, { TextTransparency = 1, TextStrokeTransparency = 1 })
		end
		for _, outline in ipairs(outlines) do
			if outline then
				Util.Tween(outline, life * 0.45, { Transparency = 1 })
			end
		end
	end)
	task.delay(life + 0.1, function()
		liveFloats = math.max(0, liveFloats - 1)
		if board.Parent then
			board:Destroy()
		end
	end)
end

local function spawnDamageNumber(amount, kind)
	local style = KIND_STYLE[kind] or KIND_STYLE.Other
	local n = math.max(1, math.floor(amount + 0.5))
	local size = NUMBER_SIZE
	if n >= 25 then
		size = NUMBER_SIZE_BIG
	end
	spawnFloat({
		Text = "-" .. n,
		Word = style.Word,
		Color = style.Color,
		WordColor = Theme.Lighten(style.Color, 0.3),
		TextSize = size,
		Rise = 3,
		Life = 1.05,
		StartX = rng:NextNumber(-1.1, 1.1),
		StartY = 2.6,
	})
end

local function spawnTokenPop(delta)
	local golden = delta >= (Config.Tokens.GoldenValue or 5)
	spawnFloat({
		Text = "+" .. delta .. " \226\152\129",
		Color = Colors.Token,
		Gradient = golden and { Colors.White:Lerp(Colors.TokenGlow, 0.4), Colors.TokenGlow }
			or { Colors.TokenGlow, Colors.Token },
		TextSize = golden and TOKEN_SIZE_GOLDEN or TOKEN_SIZE,
		Rise = 3.2,
		Life = 1.2,
		StartX = rng:NextNumber(-1.4, 1.4),
		StartY = 3.4,
	})
end

----------------------------------------------------------------------
-- Storm merging
----------------------------------------------------------------------
local function showStormNumber()
	stormScheduled = false
	if stormAccum <= 0 then
		return
	end
	local total = stormAccum
	stormAccum = 0
	stormLastShow = os.clock()
	spawnDamageNumber(total, "Storm")
end

local function queueStormNumber(amount)
	stormAccum = stormAccum + amount
	if stormScheduled then
		return
	end
	stormScheduled = true
	local remaining = stormLastShow + STORM_INTERVAL - os.clock()
	if remaining <= 0.02 then
		showStormNumber()
	else
		task.delay(remaining, showStormNumber)
	end
end

----------------------------------------------------------------------
-- Remote handlers
----------------------------------------------------------------------
local function onDamageTaken(amount, kind)
	amount = tonumber(amount) or 0
	if amount <= 0 then
		return
	end
	if type(kind) ~= "string" or not KIND_STYLE[kind] then
		kind = "Other"
	end
	local style = KIND_STYLE[kind]

	-- subtle: even the hardest hit only reaches a medium tint at the very edge
	local strength = Util.Clamp(amount / 30, 0.2, 1)
	local startT = Util.Lerp(0.82, 0.4, strength)
	local seconds = 0.45 + strength * 0.35
	if style.Soft then
		startT = 0.86
		seconds = 0.4
	end
	flashVignette(style.Vignette, startT, seconds)
	if style.Flash then
		flashScreen(0.78, 0.25)
	end
	addShake(style.Shake * Util.Clamp(0.5 + amount / 40, 0.5, 1.2))

	if kind == "Storm" then
		queueStormNumber(amount)
	else
		spawnDamageNumber(amount, kind)
	end
end

local function onMatchTokensChanged()
	local value = tonumber(LocalPlayer:GetAttribute(ATTR.MatchTokens)) or 0
	local delta = value - lastMatchTokens
	lastMatchTokens = value
	if delta > 0 then
		spawnTokenPop(math.floor(delta + 0.5))
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function DamageFx.Init()
	if initialized then
		return
	end
	initialized = true
	if not LocalPlayer then
		return
	end

	task.spawn(function()
		local ok, err = pcall(buildScreenGui)
		if not ok then
			warn("[DamageFx] vignette setup failed: " .. tostring(err))
		end
	end)

	-- Remotes.Get yields until the folder replicates, so never block Init on it
	task.spawn(function()
		local ok, remote = pcall(Remotes.Get, "DamageTaken")
		if not ok or not remote then
			warn("[DamageFx] DamageTaken remote unavailable: " .. tostring(remote))
			return
		end
		remote.OnClientEvent:Connect(function(amount, kind)
			local okFx, err = pcall(onDamageTaken, amount, kind)
			if not okFx then
				warn("[DamageFx] damage feedback failed: " .. tostring(err))
			end
		end)
	end)

	-- "+n ☁" whenever the match token count goes up
	lastMatchTokens = tonumber(LocalPlayer:GetAttribute(ATTR.MatchTokens)) or 0
	LocalPlayer:GetAttributeChangedSignal(ATTR.MatchTokens):Connect(function()
		local ok, err = pcall(onMatchTokensChanged)
		if not ok then
			warn("[DamageFx] token pop failed: " .. tostring(err))
		end
	end)

	-- never leave the camera displaced across respawns
	LocalPlayer.CharacterRemoving:Connect(function()
		stopShake()
	end)
end

return DamageFx
