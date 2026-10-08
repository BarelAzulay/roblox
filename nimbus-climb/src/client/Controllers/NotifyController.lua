-- NotifyController (client): toasts, the end-of-match results card and other players' dash puffs.
--
--   NotifyController.Init()
--
-- Remotes handled
--   Notify(text, kind, duration)  -> toast stack, top-centre below the HUD match panel (positioned and
--                                    scaled like HudController does, max MAX_TOASTS). kind: info|good|bad|token.
--                                    Identical toasts that are still showing are merged into "text x2".
--   MatchResult(result)           -> big centred results card: VICTORY!/DEFEAT, difficulty, time, tokens,
--                                    win bonus, a member table and a "Returning to the lobby in Ns…"
--                                    countdown. It closes when the server clears MatchState (the player is
--                                    sent back to the lobby), when the player presses the X, or shortly after
--                                    the countdown reaches zero as a safety net.
--   MatchState(nil)               -> closes the results card.
--   DashFx(userId)                -> a cheap trail + puff on that player's character (own dashes are ignored,
--                                    MovementController already shows those).
--
-- Plain Lua 5.1-compatible syntax only. All fonts come from Theme.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local NotifyController = {}

local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------------------
-- Tuning
----------------------------------------------------------------------
-- toasts
local MAX_TOASTS = 4
local TOAST_HEIGHT = 46
local TOAST_GAP = 8
local TOAST_MAX_TEXT_W = 440
local TOAST_BG = 0.14
local TOAST_STROKE = 0.15
local TOAST_TEXT_STROKE = 0.55
local DEFAULT_DURATION = 3
local MAX_TOAST_TEXT = 120 -- bytes

-- Where the toast stack starts. HudController scales its whole layout by
-- s = clamp(min(vpY / DESIGN_H, vpX / DESIGN_W), MIN_SCALE, MAX_SCALE) and puts the match panel
-- (HUD_MATCH_H design px) just under the GUI inset, so the stack is placed (and scaled) the same way
-- instead of using a fixed pixel offset. KEEP THESE IN SYNC with the constants of the same meaning in
-- HudController.lua (DESIGN_W/H, MIN/MAX_SCALE, EDGE, TOUCH_SAFE, TOKEN_W, TOKEN_H_MATCH, MATCH_W/H).
local HUD_DESIGN_W = 1500
local HUD_DESIGN_H = 1080
local HUD_MIN_SCALE = 0.75
local HUD_MAX_SCALE = 2.5
local HUD_EDGE = 14 -- HudController EDGE: margin to the screen edge
local HUD_TOUCH_SAFE = 22 -- extra side margin on touch devices
local HUD_TOP_PAD = 6 -- design px between the GUI inset and the match panel
local HUD_MATCH_W = 520
local HUD_MATCH_MIN_W = 440
local HUD_MATCH_H = 126
local HUD_TOKEN_W = 214
local HUD_TOKEN_H_MATCH = 86 -- token counter height while in a match
local HUD_GAP = 10 -- design px between stacked HUD panels / below the match panel

-- results card
local CARD_W = 560
local PAD = 24
local CONTENT_W = CARD_W - PAD * 2
local TILE_W = 164
local TILE_GAP = 10
local ROW_H = 36
local ROW_GAP = 6
local MAX_ROWS = 8
local RESULT_GRACE = 3 -- seconds the card may outlive its countdown while waiting for the server

-- other players' dash puffs
local FX_MAX_DISTANCE = 160 -- studs from the camera
local FX_MIN_INTERVAL = 0.25 -- per player

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"

local KINDS = {
	info = { Color = Theme.Colors.Stamina, Glyph = "✦" },
	good = { Color = Theme.Colors.Good, Glyph = "✔" },
	bad = { Color = Theme.Colors.Bad, Glyph = "!" },
	token = { Color = Theme.Colors.Token, Glyph = "☁" },
}

local SUBTITLES = {
	victory = "Every climber reached the summit!",
	defeat = "The whole team was knocked out of the sky.",
	timeout = "The storm outlasted the clock.",
	abandoned = "The team drifted away.",
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local initialized = false

local toastHolder = nil -- Frame that toasts live in
local holderScale = nil -- UIScale on toastHolder (follows the HUD scale)
local toasts = {} -- alive toasts, oldest first
local pendingToasts = {} -- Notify calls that arrived before the GUI existed

local current = nil -- the results card that is showing, if any
local lastDashFx = {} -- [userId] = os.clock() of the last puff

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
-- Set properties instantly (seconds <= 0) or tween them.
local function applyProps(inst, props, seconds)
	if seconds and seconds > 0 then
		return Util.Tween(inst, seconds, props)
	end
	for key, value in pairs(props) do
		inst[key] = value
	end
	return nil
end

local function makeLabel(parent, text, role, size, color, props)
	local label = Theme.Label(text, role, { Size = size, Color = color, Props = props })
	label.Parent = parent
	return label
end

-- Cut text to at most maxBytes without ever splitting a multi-byte UTF-8 character.
local function truncateText(text, maxBytes)
	if #text <= maxBytes then
		return text
	end
	local cut = maxBytes
	while cut > 0 do
		local b = string.byte(text, cut + 1)
		if b and b >= 128 and b < 192 then
			cut = cut - 1 -- the next byte continues a character: back up to its start
		else
			break
		end
	end
	return string.sub(text, 1, cut)
end

local function getPlayerGui()
	return LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

local function newScreenGui(name, displayOrder)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = displayOrder
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	return gui
end

----------------------------------------------------------------------
-- Toasts
----------------------------------------------------------------------
-- a = 0 fully visible, a = 1 fully transparent
local function setToastAlpha(toast, a, seconds)
	applyProps(toast.Frame, { BackgroundTransparency = Util.Lerp(TOAST_BG, 1, a) }, seconds)
	applyProps(toast.Stroke, { Transparency = Util.Lerp(TOAST_STROKE, 1, a) }, seconds)
	applyProps(toast.IconBg, { BackgroundTransparency = a }, seconds)
	applyProps(toast.IconLabel, { TextTransparency = a }, seconds)
	applyProps(toast.Label, {
		TextTransparency = a,
		TextStrokeTransparency = Util.Lerp(TOAST_TEXT_STROKE, 1, a),
	}, seconds)
end

local function toastY(index)
	return (index - 1) * (TOAST_HEIGHT + TOAST_GAP)
end

-- Slide every alive toast into its slot (index 1 = top = oldest).
local function layoutToasts()
	for i, toast in ipairs(toasts) do
		Util.Tween(
			toast.Frame,
			0.3,
			{ Position = UDim2.new(0.5, 0, 0, toastY(i)) },
			Enum.EasingStyle.Quint,
			Enum.EasingDirection.Out
		)
	end
end

local function dismissToast(toast)
	if not toast.Alive then
		return
	end
	toast.Alive = false
	for i, t in ipairs(toasts) do
		if t == toast then
			table.remove(toasts, i)
			break
		end
	end
	setToastAlpha(toast, 1, 0.25)
	Util.Tween(
		toast.Frame,
		0.25,
		{ Position = UDim2.new(0.5, 0, 0, toast.Frame.Position.Y.Offset - 14) },
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.In
	)
	task.delay(0.3, function()
		if toast.Frame.Parent then
			toast.Frame:Destroy()
		end
	end)
	layoutToasts()
end

local function scheduleExpiry(toast, duration)
	toast.Token = toast.Token + 1
	local token = toast.Token
	task.delay(duration, function()
		if toast.Alive and toast.Token == token then
			dismissToast(toast)
		end
	end)
end

local function pulseToast(toast)
	if toast.ScaleTween then
		toast.ScaleTween:Cancel()
	end
	toast.Scale.Scale = 1.12
	toast.ScaleTween = Util.Tween(toast.Scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end

local function buildToast(text, kindName)
	local kind = KINDS[kindName]

	local frame = Instance.new("Frame")
	frame.Name = "Toast"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.fromOffset(0, TOAST_HEIGHT)
	frame.BackgroundColor3 = Theme.Colors.Panel
	frame.BackgroundTransparency = TOAST_BG
	frame.BorderSizePixel = 0
	Theme.Corner(frame, UDim.new(0.5, 0))
	local stroke = Theme.Stroke(frame, kind.Color, 2, TOAST_STROKE)

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 20)
	padding.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = frame

	-- round coloured badge with a glyph
	local iconBg = Instance.new("Frame")
	iconBg.Name = "Icon"
	iconBg.LayoutOrder = 1
	iconBg.Size = UDim2.fromOffset(30, 30)
	iconBg.BackgroundColor3 = kind.Color
	iconBg.BorderSizePixel = 0
	iconBg.Parent = frame
	Theme.Corner(iconBg, UDim.new(0.5, 0))
	local iconLabel = makeLabel(iconBg, kind.Glyph, "Heading", 18, Theme.Colors.Ink, {
		Size = UDim2.fromScale(1, 1),
		TextStrokeTransparency = 1,
	})

	local label = makeLabel(frame, text, "Body", 21, Theme.Colors.White, {
		LayoutOrder = 2,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(TOAST_MAX_TEXT_W, TOAST_HEIGHT)
	limit.Parent = label

	local scale = Instance.new("UIScale")
	scale.Parent = frame

	return {
		Frame = frame,
		Stroke = stroke,
		IconBg = iconBg,
		IconLabel = iconLabel,
		Label = label,
		Scale = scale,
		ScaleTween = nil,
		Text = text,
		Kind = kindName,
		Count = 1,
		Alive = true,
		Token = 0,
	}
end

local function addToast(text, kindName, duration)
	if not toastHolder then
		if #pendingToasts < 8 then
			table.insert(pendingToasts, { text, kindName, duration })
		end
		return
	end

	text = tostring(text or "")
	if text == "" then
		return
	end
	text = truncateText(text, MAX_TOAST_TEXT)
	if type(kindName) ~= "string" or not KINDS[kindName] then
		kindName = "info"
	end
	duration = Util.Clamp(tonumber(duration) or DEFAULT_DURATION, 1, 12)

	-- the same message again while it is still on screen: bump a counter instead of stacking
	for i = #toasts, 1, -1 do
		local existing = toasts[i]
		if existing.Alive and existing.Text == text and existing.Kind == kindName then
			existing.Count = existing.Count + 1
			existing.Label.Text = text .. " ×" .. existing.Count
			scheduleExpiry(existing, duration)
			pulseToast(existing)
			return
		end
	end

	-- the stack is full: the oldest toast makes room
	while #toasts >= MAX_TOASTS do
		dismissToast(toasts[1])
	end

	local toast = buildToast(text, kindName)
	local slot = #toasts + 1
	table.insert(toasts, toast)

	-- start a little above the slot, invisible and small, then settle in
	toast.Frame.Position = UDim2.new(0.5, 0, 0, toastY(slot) - 18)
	toast.Scale.Scale = 0.85
	setToastAlpha(toast, 1, 0)
	toast.Frame.Parent = toastHolder

	setToastAlpha(toast, 0, 0.25)
	toast.ScaleTween = Util.Tween(toast.Scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	layoutToasts()
	if kindName == "bad" then
		toast.Frame.Rotation = 3
		Util.Tween(toast.Frame, 0.55, { Rotation = 0 }, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
	end
	scheduleExpiry(toast, duration)
end

-- Place and scale the toast stack for a viewport of size vp, mirroring HudController.relayout:
-- the stack starts a gap below the match panel (and below the token counter when HudController tucks
-- it under the match panel on narrow screens) and uses the same UIScale as the HUD.
local function applyHolderLayout(vp)
	if not toastHolder or not holderScale then
		return
	end
	local s = Util.Clamp(math.min(vp.Y / HUD_DESIGN_H, vp.X / HUD_DESIGN_W), HUD_MIN_SCALE, HUD_MAX_SCALE)

	local insetY = 0
	pcall(function()
		insetY = GuiService:GetGuiInset().Y
	end)

	-- same "narrow" test as HudController (token counter does not fit beside the match panel)
	local side = 0
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		side = HUD_TOUCH_SAFE
	end
	local effW = vp.X / s -- viewport width in design pixels
	local matchW = math.floor(Util.Clamp(effW - 2 * (HUD_EDGE + side), HUD_MATCH_MIN_W, HUD_MATCH_W))
	local belowDesign = HUD_TOP_PAD + HUD_MATCH_H + HUD_GAP
	if effW < matchW + 2 * (HUD_TOKEN_W + HUD_EDGE) then
		belowDesign = belowDesign + HUD_TOKEN_H_MATCH + HUD_GAP
	end

	holderScale.Scale = s
	-- a UIScale also scales its parent's size: pre-divide the width so the stack still spans the screen
	-- (toasts are centred on it); the height is in design px and scales with the toasts
	toastHolder.Size = UDim2.new(1 / s, 0, 0, toastY(MAX_TOASTS + 1))
	-- the holder's own Position is not affected by its UIScale: this is real screen pixels
	toastHolder.Position = UDim2.fromOffset(0, math.floor(insetY + belowDesign * s + 0.5))
end

local function layoutHolder()
	local camera = workspace.CurrentCamera
	local vp = camera and camera.ViewportSize or Vector2.new(1280, 720)
	if vp.X < 8 or vp.Y < 8 then
		return -- the viewport can be 1x1 at startup: the next change / delayed re-check fixes it
	end
	applyHolderLayout(vp)
end

-- Keep the stack in step with the HUD whenever the viewport changes (same pattern as
-- HudController.hookCamera).
local function hookToastCamera()
	local cameraConn = nil
	local function bind()
		if cameraConn then
			cameraConn:Disconnect()
			cameraConn = nil
		end
		local camera = workspace.CurrentCamera
		if camera then
			cameraConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(layoutHolder)
		end
		layoutHolder()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bind)
	bind()
	task.delay(0.5, layoutHolder)
	task.delay(2, layoutHolder)
end

local function buildToastGui()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui", 30)
	if not playerGui then
		return
	end
	local gui = newScreenGui("NimbusToasts", 20)

	local holder = Instance.new("Frame")
	holder.Name = "Stack"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Name = "HolderScale"
	scale.Parent = holder

	gui.Parent = playerGui
	toastHolder = holder
	holderScale = scale

	-- sane placement until the real viewport is known, then follow the camera
	applyHolderLayout(Vector2.new(1280, 720))
	hookToastCamera()

	local queued = pendingToasts
	pendingToasts = {}
	for _, args in ipairs(queued) do
		addToast(args[1], args[2], args[3])
	end
end

----------------------------------------------------------------------
-- Results card
----------------------------------------------------------------------
local function closeResults(immediate)
	local r = current
	if not r then
		return
	end
	current = nil
	r.Alive = false
	for _, conn in ipairs(r.Conns) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	if immediate then
		pcall(function()
			r.Gui:Destroy()
		end)
		return
	end
	Util.Tween(r.Dim, 0.35, { BackgroundTransparency = 1 })
	Util.Tween(r.Pop, 0.3, { Scale = 0.05 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	task.delay(0.4, function()
		pcall(function()
			r.Gui:Destroy()
		end)
	end)
end

-- Count a label up from 0 to 'target' (format(n) -> string). Stops by itself when the label is destroyed.
local function countUp(label, target, delay, seconds, format)
	label.Text = format(0)
	if target <= 0 then
		return
	end
	task.spawn(function()
		task.wait(delay)
		local startAt = os.clock()
		while label.Parent do
			local t = (os.clock() - startAt) / seconds
			if t >= 1 then
				break
			end
			local eased = 1 - (1 - t) * (1 - t)
			label.Text = format(math.floor(target * eased + 0.5))
			task.wait()
		end
		if label.Parent then
			label.Text = format(target)
		end
	end)
end

-- A falling burst of coloured paper behind the card (victory only).
local function burstConfetti(r, count, delay)
	local rng = Random.new()
	local colors = Theme.Colors.Rainbow
	for _ = 1, count do
		task.delay(delay + rng:NextNumber(0, 0.9), function()
			if not r.Alive or not r.Confetti.Parent then
				return
			end
			local x = rng:NextNumber(0.02, 0.98)
			local piece = Instance.new("Frame")
			piece.AnchorPoint = Vector2.new(0.5, 0.5)
			piece.BorderSizePixel = 0
			piece.Size = UDim2.fromOffset(rng:NextInteger(7, 12), rng:NextInteger(10, 18))
			piece.BackgroundColor3 = colors[rng:NextInteger(1, #colors)]
			piece.Position = UDim2.fromScale(x, -0.05)
			piece.Rotation = rng:NextNumber(0, 360)
			piece.Parent = r.Confetti

			local fall = rng:NextNumber(2.2, 3.8)
			Util.Tween(piece, fall, {
				Position = UDim2.fromScale(x + rng:NextNumber(-0.12, 0.12), 1.08),
				Rotation = piece.Rotation + rng:NextNumber(-540, 540),
			}, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
			task.delay(fall + 0.1, function()
				if piece.Parent then
					piece:Destroy()
				end
			end)
		end)
	end
end

local function makeTile(parent, index, caption, valueText, valueColor)
	local tile = Instance.new("Frame")
	tile.Name = "Tile" .. index
	tile.Position = UDim2.fromOffset((index - 1) * (TILE_W + TILE_GAP), 0)
	tile.Size = UDim2.fromOffset(TILE_W, 74)
	tile.BackgroundColor3 = Theme.Colors.PanelLight
	tile.BackgroundTransparency = 0.45
	tile.BorderSizePixel = 0
	tile.Parent = parent
	Theme.Corner(tile, UDim.new(0, 12))

	makeLabel(tile, caption, "Label", 13, Theme.Colors.CloudShade, {
		Position = UDim2.fromOffset(0, 9),
		Size = UDim2.new(1, 0, 0, 16),
	})
	-- TextScaled keeps long values ("☁ 124 / 240") inside the tile; the constraint caps the size
	local value = makeLabel(tile, valueText, "Display", 30, valueColor, {
		Position = UDim2.fromOffset(8, 28),
		Size = UDim2.new(1, -16, 0, 38),
		TextScaled = true,
	})
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 30
	cap.MinTextSize = 12
	cap.Parent = value
	return value
end

local function normaliseMembers(list)
	local out = {}
	if type(list) == "table" then
		for _, m in ipairs(list) do
			if type(m) == "table" and #out < MAX_ROWS then
				table.insert(out, {
					Name = tostring(m.Name or "Climber"),
					MatchTokens = tonumber(m.MatchTokens) or 0,
					Finished = m.Finished == true,
					Downed = m.Downed == true,
				})
			end
		end
	end
	table.sort(out, function(a, b)
		if a.Finished ~= b.Finished then
			return a.Finished
		end
		if a.MatchTokens ~= b.MatchTokens then
			return a.MatchTokens > b.MatchTokens
		end
		return a.Name < b.Name
	end)
	return out
end

local function isLocalName(name)
	return name == LocalPlayer.DisplayName or name == LocalPlayer.Name
end

-- Build the whole results GUI (not yet parented). Returns the runtime record for 'current'.
local function buildResults(result)
	local won = result.Won == true
	local reason = tostring(result.Reason or "")
	if reason == "" then
		if won then
			reason = "victory"
		else
			reason = "defeat"
		end
	end
	local diff = Config.GetDifficulty(result.DifficultyId)
	local diffName = result.DifficultyName
	if type(diffName) ~= "string" or diffName == "" then
		if diff then
			diffName = diff.DisplayName
		else
			diffName = "Sky Course"
		end
	end
	local diffColor = Theme.Colors.Stamina
	local stars = 0
	if diff then
		diffColor = diff.Color
		stars = diff.Stars or 0
	end
	local seconds = tonumber(result.Seconds) or 0
	local tokens = math.floor(tonumber(result.MatchTokens) or 0)
	local totalTokens = math.floor(tonumber(result.TotalTokens) or 0)
	local bonus = math.floor(tonumber(result.Bonus) or 0)
	local members = normaliseMembers(result.Members)

	local accent = Theme.Colors.Bad
	local titleText = "DEFEAT"
	local titleTop = Color3.fromRGB(205, 214, 255)
	local titleBottom = Color3.fromRGB(150, 120, 235)
	local subtitle = SUBTITLES[reason]
	if won then
		accent = Theme.Colors.Token
		titleText = "VICTORY!"
		titleTop = Color3.fromRGB(255, 244, 170)
		titleBottom = Color3.fromRGB(255, 150, 120)
		subtitle = subtitle or SUBTITLES.victory
	else
		subtitle = subtitle or SUBTITLES.defeat
	end

	-- vertical layout (card-local pixels)
	local tilesY = 160
	local tableY = 248
	local rowsY = tableY + 22
	local rowCount = math.max(1, #members)
	local rowsEnd = rowsY + rowCount * (ROW_H + ROW_GAP) - ROW_GAP
	local countdownY = rowsEnd + 14
	local cardH = countdownY + 24 + 20

	local gui = newScreenGui("NimbusResults", 15)

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Theme.Colors.Ink
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	dim.Parent = gui

	local confetti = Instance.new("Frame")
	confetti.Name = "Confetti"
	confetti.BackgroundTransparency = 1
	confetti.BorderSizePixel = 0
	confetti.ClipsDescendants = true
	confetti.Size = UDim2.fromScale(1, 1)
	confetti.ZIndex = 2
	confetti.Parent = gui

	-- holder: fits the card to the screen; card: does the pop-in
	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(CARD_W, cardH)
	holder.ZIndex = 3
	holder.Parent = gui
	local fit = Instance.new("UIScale")
	fit.Parent = holder

	local card = Theme.Panel({
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 0.06,
	})
	card.Parent = holder
	Theme.Gradient(card, Color3.fromRGB(255, 255, 255), Color3.fromRGB(185, 196, 230), 90)
	local cardStroke = card:FindFirstChildOfClass("UIStroke")
	if cardStroke then
		cardStroke.Color = accent
		cardStroke.Thickness = 3
		cardStroke.Transparency = 0.1
	end
	local pop = Instance.new("UIScale")
	pop.Scale = 0.6
	pop.Parent = card

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(PAD, 0)
	content.Size = UDim2.new(0, CONTENT_W, 1, 0)
	content.Parent = card

	-- header
	local title = makeLabel(content, titleText, "Title", 56, Theme.Colors.White, {
		Position = UDim2.fromOffset(0, 14),
		Size = UDim2.new(1, 0, 0, 64),
		TextStrokeTransparency = 0.3,
	})
	Theme.Gradient(title, titleTop, titleBottom, 90)

	makeLabel(content, subtitle, "Script", 20, Theme.Colors.Cloud, {
		Position = UDim2.fromOffset(0, 80),
		Size = UDim2.new(1, 0, 0, 24),
	})

	local diffText = diffName
	if stars > 0 then
		diffText = diffText .. "   " .. string.rep("★", stars) .. string.rep("☆", math.max(0, 3 - stars))
	end
	makeLabel(content, diffText, "Heading", 22, diffColor, {
		Position = UDim2.fromOffset(0, 108),
		Size = UDim2.new(1, 0, 0, 28),
	})

	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.BackgroundColor3 = Theme.Colors.PanelLight
	divider.BackgroundTransparency = 0.35
	divider.BorderSizePixel = 0
	divider.Position = UDim2.fromOffset(0, 146)
	divider.Size = UDim2.new(1, 0, 0, 2)
	divider.Parent = content

	-- stat tiles
	local tiles = Instance.new("Frame")
	tiles.Name = "Tiles"
	tiles.BackgroundTransparency = 1
	tiles.Position = UDim2.fromOffset(0, tilesY)
	tiles.Size = UDim2.new(1, 0, 0, 74)
	tiles.Parent = content

	makeTile(tiles, 1, "TIME", Util.FormatTime(seconds), Theme.Colors.White)
	local tokenValue = makeTile(tiles, 2, "CLOUD TOKENS", "☁ 0", Theme.Colors.Token)
	local bonusColor = Theme.Colors.Good
	local bonusStart = "+0 ☁"
	if bonus <= 0 then
		bonusColor = Theme.Colors.CloudShade
		bonusStart = "—"
	end
	local bonusValue = makeTile(tiles, 3, "WIN BONUS", bonusStart, bonusColor)

	local function formatTokens(n)
		if totalTokens > 0 then
			return "☁ " .. n .. " / " .. totalTokens
		end
		return "☁ " .. n
	end
	countUp(tokenValue, tokens, 0.45, 0.9, formatTokens)
	if bonus > 0 then
		countUp(bonusValue, bonus, 0.8, 0.7, function(n)
			return "+" .. n .. " ☁"
		end)
	end

	-- member table
	makeLabel(content, "CLIMBER", "Label", 12, Theme.Colors.CloudShade, {
		Position = UDim2.fromOffset(16, tableY),
		Size = UDim2.fromOffset(200, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	makeLabel(content, "TOKENS", "Label", 12, Theme.Colors.CloudShade, {
		Position = UDim2.fromOffset(280, tableY),
		Size = UDim2.fromOffset(100, 18),
	})
	makeLabel(content, "STATUS", "Label", 12, Theme.Colors.CloudShade, {
		Position = UDim2.fromOffset(CONTENT_W - 16 - 130, tableY),
		Size = UDim2.fromOffset(130, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local rows = {}
	if #members == 0 then
		-- the server always sends members, but never show an empty box
		members = { { Name = LocalPlayer.DisplayName, MatchTokens = tokens, Finished = false, Downed = false } }
	end
	for i, m in ipairs(members) do
		local me = isLocalName(m.Name)
		local y = rowsY + (i - 1) * (ROW_H + ROW_GAP)

		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.Position = UDim2.fromOffset(0, y)
		row.Size = UDim2.new(1, 0, 0, ROW_H)
		row.BorderSizePixel = 0
		row.BackgroundColor3 = Theme.Colors.PanelLight
		row.BackgroundTransparency = 0.55
		row.Visible = false
		row.Parent = content
		Theme.Corner(row, UDim.new(0, 10))
		if me then
			row.BackgroundColor3 = accent:Lerp(Theme.Colors.Panel, 0.65)
			row.BackgroundTransparency = 0.2
			Theme.Stroke(row, accent, 1.5, 0.35)
		end

		local nameText = m.Name
		if me then
			nameText = nameText .. " (you)"
		end
		makeLabel(row, nameText, "Body", 20, Theme.Colors.White, {
			Position = UDim2.fromOffset(16, 0),
			Size = UDim2.new(0, 250, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		makeLabel(row, "☁ " .. math.floor(m.MatchTokens), "Display", 20, Theme.Colors.Token, {
			Position = UDim2.fromOffset(280, 0),
			Size = UDim2.new(0, 100, 1, 0),
		})

		local statusText = "Didn't finish"
		local statusColor = Theme.Colors.CloudShade
		if m.Finished then
			statusText = "✔ Finished"
			statusColor = Theme.Colors.Good
		elseif m.Downed then
			statusText = "Downed"
			statusColor = Theme.Colors.Bad
		end
		makeLabel(row, statusText, "Heading", 15, statusColor, {
			Position = UDim2.new(1, -16 - 130, 0, 0),
			Size = UDim2.new(0, 130, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
		})

		table.insert(rows, { Frame = row, Y = y })
	end

	-- countdown
	local countdown = makeLabel(content, "", "Body", 18, Theme.Colors.Cloud, {
		Position = UDim2.fromOffset(0, countdownY),
		Size = UDim2.new(1, 0, 0, 24),
	})

	-- small close button
	local hide = Instance.new("TextButton")
	hide.Name = "Hide"
	hide.AnchorPoint = Vector2.new(1, 0)
	hide.Position = UDim2.new(1, -12, 0, 12)
	hide.Size = UDim2.fromOffset(30, 30)
	hide.BackgroundTransparency = 1
	hide.AutoButtonColor = false
	hide.Text = "✕"
	Theme.Style(hide, "Heading", { Size = 18, Color = Theme.Colors.CloudShade })
	hide.Parent = card

	local function updateFit()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local vp = camera.ViewportSize
		local s = math.min(vp.X / (CARD_W + 40), vp.Y / (cardH + 40), 1.15)
		fit.Scale = Util.Clamp(s, 0.45, 1.15)
	end
	updateFit()

	local record = {
		Gui = gui,
		Dim = dim,
		Confetti = confetti,
		Pop = pop,
		Countdown = countdown,
		Rows = rows,
		Hide = hide,
		Conns = {},
		Alive = true,
		Won = won,
		Deadline = os.clock() + Config.Match.EndScreenSeconds,
		UpdateFit = updateFit,
	}
	return record
end

local function showResults(result)
	closeResults(true)
	if type(result) ~= "table" then
		return
	end
	local playerGui = getPlayerGui()
	if not playerGui then
		return
	end
	local okBuild, r = pcall(buildResults, result)
	if not okBuild then
		warn("[NotifyController] results card failed: " .. tostring(r))
		return
	end
	current = r
	r.Gui.Parent = playerGui

	-- keep the card on screen when the window is resized
	local camera = workspace.CurrentCamera
	if camera then
		table.insert(r.Conns, camera:GetPropertyChangedSignal("ViewportSize"):Connect(r.UpdateFit))
	end
	table.insert(r.Conns, r.Hide.Activated:Connect(function()
		closeResults(false)
	end))

	-- entrance
	Util.Tween(r.Dim, 0.4, { BackgroundTransparency = 0.45 })
	Util.Tween(r.Pop, 0.45, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	for i, row in ipairs(r.Rows) do
		row.Frame.Position = UDim2.fromOffset(40, row.Y)
		task.delay(0.35 + (i - 1) * 0.1, function()
			if r.Alive and row.Frame.Parent then
				row.Frame.Visible = true
				Util.Tween(
					row.Frame,
					0.35,
					{ Position = UDim2.fromOffset(0, row.Y) },
					Enum.EasingStyle.Quint,
					Enum.EasingDirection.Out
				)
			end
		end)
	end
	if r.Won then
		burstConfetti(r, 40, 0.25)
		burstConfetti(r, 30, 1.6)
	end

	-- countdown back to the lobby
	task.spawn(function()
		while r.Alive and r.Countdown.Parent do
			local remaining = r.Deadline - os.clock()
			if remaining > 0 then
				r.Countdown.Text = string.format("Returning to the lobby in %ds…", math.ceil(remaining))
			else
				r.Countdown.Text = "Returning to the lobby…"
				if remaining < -RESULT_GRACE then
					closeResults(false) -- the server never cleared MatchState: do not hang around forever
					return
				end
			end
			task.wait(0.2)
		end
	end)
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

	local feet = Instance.new("Attachment")
	feet.Name = "NC_DashFeet"
	feet.Position = Vector3.new(0, -feetOffset + 0.2, 0)
	feet.Parent = root
	table.insert(instances, feet)

	local puff = newEmitter(feet, {
		Name = "NC_DashPuff",
		Texture = TEX_SMOKE,
		Color = ColorSequence.new(Theme.Colors.Cloud, Theme.Colors.CloudShade),
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
		LightEmission = 0.1,
		LockedToPart = false,
		Rate = 0,
		Enabled = false,
	})
	puff:Emit(7)

	local sparks = newEmitter(root, {
		Name = "NC_DashSparks",
		Texture = TEX_SPARKLES,
		Color = ColorSequence.new(Theme.Colors.White, Theme.Colors.Stamina),
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
		LightEmission = 1,
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
	trail.LightEmission = 0.7
	trail.Color = ColorSequence.new(Theme.Colors.White, Theme.Colors.Stamina)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
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
-- Remote handlers
----------------------------------------------------------------------
local function onNotify(text, kind, duration)
	addToast(text, kind, duration)
end

local function onMatchResult(result)
	showResults(result)
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

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function NotifyController.Init()
	if initialized then
		return
	end
	initialized = true
	if not LocalPlayer then
		return
	end

	task.spawn(function()
		local ok, err = pcall(buildToastGui)
		if not ok then
			warn("[NotifyController] toast GUI failed: " .. tostring(err))
		end
	end)

	hook("Notify", onNotify)
	hook("MatchResult", onMatchResult)
	hook("MatchState", onMatchState)
	hook("DashFx", onDashFx)

	Players.PlayerRemoving:Connect(function(player)
		lastDashFx[player.UserId] = nil
	end)
end

return NotifyController
