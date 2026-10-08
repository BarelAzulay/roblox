-- HudController: the Nimbus Climb heads-up display.
--
--   HudController.Init()
--
-- One ScreenGui "NimbusHud" (ResetOnSpawn = false, IgnoreGuiInset = true) whose contents live in a
-- single "Root" frame carrying a UIScale, so every number below is a *design pixel* and the whole HUD
-- scales from phones to 4K. Layout (all fonts come from Theme roles):
--
--   bottom-left   Vitals    health bar (lagging damage trail, low-health pulse), stamina bar, dash pip,
--                           "DOWNED" pill (bottom-centre instead on touch devices: thumbstick room)
--   top-right     Tokens    golden cloud counter (count-up + pop), "this run" line while in a match
--   top-centre    Match     difficulty, timer, checkpoint + token progress, compact team list
--   centre        Countdown giant 3-2-1-GO!, plus the title card at join
--   mid-left      Party     lobby party panel (Leave button) / "Leave match" (press twice to confirm)
--
-- Data sources: Humanoid health, player attributes (CloudTokens, MatchTokens, InMatch, Downed,
-- Stamina) and the PartyState / MatchState remotes. Everything is nil-safe: no humanoid, no match, no
-- party and a missing MovementController all leave the HUD in a sensible idle state.
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local HudController = {}

----------------------------------------------------------------------
-- Tunables (design pixels unless noted)
----------------------------------------------------------------------
local DESIGN_W = 1500 -- reference viewport the UIScale is derived from
local DESIGN_H = 1080
local MIN_SCALE = 0.75
local MAX_SCALE = 2.5
local EDGE = 14 -- margin to the screen edge
local TOUCH_SAFE = 22 -- extra side margin on touch devices (notches, rounded corners)

local VITALS_W, VITALS_H = 340, 88
local TOKEN_W, TOKEN_H, TOKEN_H_MATCH = 214, 62, 86
local MATCH_W, MATCH_H = 520, 126
local PARTY_W = 280
local LOW_HEALTH = 0.3 -- below this the health bar pulses
local TITLE_CARD_SECONDS = 4
local LEAVE_CONFIRM_SECONDS = 3

local Colors = Theme.Colors
local WHITE = Colors.White
local DOWNED_TEXT = "DOWNED \226\128\148 wait for a teammate!" -- em dash as UTF-8 bytes

----------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------
local player = nil
local initialized = false
local startedAt = 0
local connections = {} -- long-lived connections (for tidiness; the HUD lives for the whole session)
local warned = {}
local remoteCache = {}
local buttonState = setmetatable({}, { __mode = "k" })

local UI = {} -- instance references
local Items = {} -- panels that slide in/out (see present())

local S = { match = nil, party = nil, downed = false, downedShown = false, downedAt = 0 }
local H = { -- health
	Char = nil, Humanoid = nil, Conns = {},
	Cur = 100, Max = 100, Target = 1, Fill = 1, Trail = 1,
	Hold = 0, Flash = 0, Pop = 0, Low = 0, ShakeUntil = 0, Shaking = false,
	Color = Colors.Health, Text = "", NextSync = 0,
}
local St = { Frac = 1, Active = -10, Vis = 0, PipCharged = true } -- stamina + dash pip
local Tk = { Target = 0, Display = 0, Shown = nil, Seen = false, RunVisible = false, RunCount = nil }
local Mt = { -- match panel bookkeeping
	Phase = nil, Base = 0, At = 0, Limit = nil, TimerText = nil, Cp = nil, Tokens = nil,
	TotalCp = nil, Ticks = {}, DifficultyId = nil, Color = Colors.Stamina, Chips = {},
}
local Pt = { Rows = {}, Total = nil, PrevCountdown = nil } -- party panel bookkeeping
local CD = { Serial = 0, Last = nil } -- countdown overlay
local LM = { ArmedUntil = 0, LockedUntil = 0 } -- leave-match confirmation

local movementModule = nil
local movementTries = 0
local movementNextTry = 0

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local tween = Util.Tween

local function clamp(n, lo, hi)
	return Util.Clamp(n, lo, hi)
end

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

----------------------------------------------------------------------
-- UI builders
----------------------------------------------------------------------
local function newFrame(parent, props)
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	if props then
		for k, v in pairs(props) do
			f[k] = v
		end
	end
	f.Parent = parent
	return f
end

-- Themed TextLabel. props may include Stroke (text outline transparency) plus any label property.
local function newText(parent, text, role, size, color, props)
	props = props or {}
	local extra = {
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}
	for k, v in pairs(props) do
		if k ~= "Stroke" then
			extra[k] = v
		end
	end
	local label = Theme.Label(text, role, { Size = size, Color = color, Stroke = props.Stroke, Props = extra })
	label.Parent = parent
	return label
end

-- Heavy rounded outline that follows the glyphs (UIStroke in Contextual mode). Used on big text.
local function textStroke(label, thickness, transparency)
	label.TextStrokeTransparency = 1
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Color = Colors.Ink
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.Parent = label
	return stroke
end

local function newScale(parent)
	local s = Instance.new("UIScale")
	s.Parent = parent
	return s
end

local function newList(parent, props)
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	if props then
		for k, v in pairs(props) do
			l[k] = v
		end
	end
	l.Parent = parent
	return l
end

local function newPadding(parent, px)
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	p.PaddingTop = UDim.new(0, px)
	p.PaddingBottom = UDim.new(0, px)
	p.Parent = parent
	return p
end

-- Rounded capsule bar. Returns track, fill. The fill carries a soft top-to-bottom gradient + gloss
-- strip, so recolouring BackgroundColor3 keeps the glassy look.
local function makeBar(parent, props, fillColor)
	local track_ = newFrame(parent, {
		Name = "Track",
		BackgroundColor3 = Colors.Ink,
		BackgroundTransparency = 0.35,
		ClipsDescendants = true,
	})
	for k, v in pairs(props or {}) do
		track_[k] = v
	end
	Theme.Corner(track_, UDim.new(0.5, 0))
	local fill = newFrame(track_, {
		Name = "Fill",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 0,
		BackgroundColor3 = fillColor or Colors.Health,
		ZIndex = 2,
	})
	Theme.Corner(fill, UDim.new(0.5, 0))
	Theme.Gradient(fill, WHITE, Color3.fromRGB(196, 204, 222), 90)
	local gloss = newFrame(fill, {
		Name = "Gloss",
		Position = UDim2.new(0.08, 0, 0, 2),
		Size = UDim2.new(0.84, 0, 0.34, 0),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.76,
	})
	Theme.Corner(gloss, UDim.new(0.5, 0))
	return track_, fill
end

local function paintButton(btn)
	local st = buttonState[btn]
	if not st then
		return
	end
	local color = st.Base
	if st.Down then
		color = color:Lerp(Colors.Ink, 0.28)
	elseif st.Hover then
		color = color:Lerp(WHITE, 0.2)
	end
	btn.BackgroundColor3 = color
	btn.BackgroundTransparency = st.Hover and 0 or 0.1
end

local function setButtonColor(btn, color)
	local st = buttonState[btn]
	if st then
		st.Base = color
		paintButton(btn)
	end
end

-- Rounded pill button in the Heading font with hover / press feedback.
local function makeButton(parent, text, color, props)
	local btn = Instance.new("TextButton")
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.Text = text
	Theme.Style(btn, "Heading", { Size = 17 })
	for k, v in pairs(props or {}) do
		btn[k] = v
	end
	Theme.Corner(btn, UDim.new(0, 12))
	Theme.Stroke(btn, WHITE, 1.5, 0.75)
	buttonState[btn] = { Base = color, Hover = false, Down = false }
	paintButton(btn)
	btn.MouseEnter:Connect(function()
		buttonState[btn].Hover = true
		paintButton(btn)
	end)
	btn.MouseLeave:Connect(function()
		buttonState[btn].Hover = false
		buttonState[btn].Down = false
		paintButton(btn)
	end)
	btn.MouseButton1Down:Connect(function()
		buttonState[btn].Down = true
		paintButton(btn)
	end)
	btn.MouseButton1Up:Connect(function()
		buttonState[btn].Down = false
		paintButton(btn)
	end)
	btn.Parent = parent
	return btn
end

-- Springy "pop": jump a UIScale to `peak`, then ease back to 1.
local function pop(scaleObj, peak, seconds)
	if not scaleObj then
		return
	end
	scaleObj.Scale = peak
	tween(scaleObj, seconds or 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end

-- Slide a panel in/out between item.Rest and item.Hidden (both UDim2, set by relayout()).
local function present(item, show)
	if not item or not item.Frame or item.Shown == show then
		return
	end
	item.Shown = show
	local frame = item.Frame
	if show then
		frame.Position = item.Hidden
		frame.Visible = true
		tween(frame, 0.45, { Position = item.Rest }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	else
		tween(frame, 0.25, { Position = item.Hidden }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.3, function()
			if not item.Shown and frame.Parent then
				frame.Visible = false
			end
		end)
	end
end

local function newItem(frame)
	frame.Visible = false
	return { Frame = frame, Shown = false, Rest = frame.Position, Hidden = frame.Position }
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

----------------------------------------------------------------------
-- Default CoreGui health bar
----------------------------------------------------------------------
local function disableDefaultHealth()
	task.spawn(function()
		for _ = 1, 60 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
			end)
			if ok then
				-- apply once more a little later in case the core scripts re-enabled it while loading
				task.wait(3)
				pcall(function()
					StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
				end)
				return
			end
			task.wait(0.5)
		end
	end)
	pcall(function()
		track(StarterGui.CoreGuiChangedSignal:Connect(function(coreType, enabled)
			if coreType == Enum.CoreGuiType.Health and enabled then
				pcall(function()
					StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
				end)
			end
		end))
	end)
end

----------------------------------------------------------------------
-- Build: vitals (health, stamina, dash pip, downed pill)
----------------------------------------------------------------------
local function buildVitals(parent)
	local holder = newFrame(parent, {
		Name = "Vitals",
		Size = UDim2.new(0, VITALS_W, 0, VITALS_H),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, EDGE, 1, -EDGE),
	})
	UI.VitalsHolder = holder

	local panel = Theme.Panel({ Name = "VitalsPanel", Size = UDim2.new(1, 0, 1, 0) })
	panel.Parent = holder
	UI.VitalsPanel = panel
	UI.VitalsStroke = panel:FindFirstChildOfClass("UIStroke") or Theme.Stroke(panel, Colors.PanelLight, 2, 0.35)

	-- heart badge
	local badge = newFrame(panel, {
		Name = "HeartBadge",
		Size = UDim2.new(0, 58, 0, 58),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		BackgroundColor3 = Colors.Ink,
		BackgroundTransparency = 0.25,
	})
	Theme.Corner(badge, UDim.new(0.5, 0))
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = badge
	UI.BadgeStroke = Theme.Stroke(badge, Colors.Health, 2, 0.1)
	UI.Heart = newText(badge, "\226\153\165", "Display", 36, Colors.Health, { -- heart
		Name = "Heart",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -1),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	UI.HeartScale = newScale(UI.Heart)

	-- right column
	local col = newFrame(panel, {
		Name = "Bars",
		Position = UDim2.new(0, 82, 0, 0),
		Size = UDim2.new(1, -94, 1, 0),
	})
	newText(col, "HEALTH", "Label", 13, Colors.CloudShade, {
		Name = "Caption",
		Position = UDim2.new(0, 2, 0, 7),
		Size = UDim2.new(0.5, 0, 0, 16),
	})
	newText(col, player and player.DisplayName or "", "Script", 16, Colors.TokenGlow, {
		Name = "PlayerName",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -2, 0, 6),
		Size = UDim2.new(0.5, 0, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local track_, fill = makeBar(col, {
		Name = "HealthTrack",
		Position = UDim2.new(0, 0, 0, 25),
		Size = UDim2.new(1, 0, 0, 30),
	}, Colors.Health)
	UI.HealthTrack = track_
	UI.HealthFill = fill
	local trail = newFrame(track_, {
		Name = "Trail",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.fromRGB(255, 214, 222),
		BackgroundTransparency = 0.1,
		ZIndex = 1,
	})
	Theme.Corner(trail, UDim.new(0.5, 0))
	UI.HealthTrail = trail
	UI.HealthText = newText(track_, "100 / 100", "Display", 20, WHITE, {
		Name = "HealthText",
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 5,
		Stroke = 0.25,
	})

	-- stamina row: thin bar + dash pip
	local row = newFrame(col, { Name = "StaminaRow", Position = UDim2.new(0, 0, 0, 59), Size = UDim2.new(1, 0, 0, 22) })
	local sTrack, sFill = makeBar(row, {
		Name = "StaminaTrack",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, -30, 0, 8),
	}, Colors.Stamina)
	UI.StaminaTrack = sTrack
	UI.StaminaFill = sFill

	local pip = newFrame(row, {
		Name = "DashPip",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -11, 0.5, 0),
		Size = UDim2.new(0, 22, 0, 22),
		BackgroundColor3 = Colors.Ink,
		BackgroundTransparency = 0.2,
		ClipsDescendants = true,
	})
	Theme.Corner(pip, UDim.new(0.3, 0))
	UI.PipStroke = Theme.Stroke(pip, Colors.Stamina, 1.5, 0.2)
	UI.PipScale = newScale(pip)
	UI.PipFill = newFrame(pip, {
		Name = "Charge",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Colors.Stamina,
		BackgroundTransparency = 0.3,
	})
	Theme.Corner(UI.PipFill, UDim.new(0.3, 0))
	UI.PipGlyph = newText(pip, "\194\187", "Heading", 18, WHITE, { -- double chevron
		Name = "Glyph",
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 3,
		Stroke = 0.4,
	})

	-- "DOWNED" pill floating above the panel
	local pill = newFrame(holder, {
		Name = "DownedPill",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -8),
		Size = UDim2.new(0, 360, 0, 34),
		BackgroundColor3 = Color3.fromRGB(120, 28, 52),
		BackgroundTransparency = 0.12,
		Visible = false,
	})
	Theme.Corner(pill, UDim.new(0.5, 0))
	Theme.Stroke(pill, Colors.HealthLow, 2, 0.1)
	UI.DownedPill = pill
	UI.DownedScale = newScale(pill)
	newText(pill, DOWNED_TEXT, "Accent", 17, Colors.HealthLow:Lerp(WHITE, 0.55), {
		Name = "DownedText",
		TextXAlignment = Enum.TextXAlignment.Center,
		Stroke = 0.2,
	})
end

----------------------------------------------------------------------
-- Build: cloud token counter (top-right)
----------------------------------------------------------------------
local function buildTokens(parent)
	local panel = Theme.Panel({
		Name = "TokenPanel",
		Size = UDim2.new(0, TOKEN_W, 0, TOKEN_H),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -EDGE, 0, 0),
	})
	panel.Parent = parent
	UI.TokenPanel = panel

	local ring = newFrame(panel, {
		Name = "IconRing",
		Size = UDim2.new(0, 42, 0, 42),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 33, 0, 31),
		BackgroundColor3 = Colors.Ink,
		BackgroundTransparency = 0.2,
	})
	Theme.Corner(ring, UDim.new(0.5, 0))
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = ring
	Theme.Stroke(ring, Colors.Token, 2, 0.1)
	UI.TokenRingScale = newScale(ring)
	newText(ring, "\226\152\129", "Display", 30, Colors.Token, { -- cloud
		Name = "Cloud",
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.new(0, 0, 0, -1),
	})

	UI.TokenCount = newText(panel, "0", "Display", 30, WHITE, {
		Name = "Count",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 64, 0, 21),
		Size = UDim2.new(1, -74, 0, 34),
		Stroke = 0.35,
	})
	UI.TokenCountScale = newScale(UI.TokenCount)
	newText(panel, "CLOUD TOKENS", "Label", 12, Colors.CloudShade, {
		Name = "Caption",
		Position = UDim2.new(0, 64, 0, 39),
		Size = UDim2.new(1, -74, 0, 14),
	})
	UI.RunLabel = newText(panel, "this run: 0", "Body", 16, Colors.TokenGlow, {
		Name = "RunLabel",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 64, 0, 68),
		Size = UDim2.new(1, -74, 0, 20),
		Visible = false,
	})
	UI.RunScale = newScale(UI.RunLabel)
end

----------------------------------------------------------------------
-- Build: match panel (top-centre)
----------------------------------------------------------------------
local function buildMatch(parent)
	local panel = Theme.Panel({
		Name = "MatchPanel",
		Size = UDim2.new(0, MATCH_W, 0, MATCH_H),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
	})
	panel.Parent = parent
	UI.MatchPanel = panel

	-- difficulty-coloured cap on the panel's top edge
	UI.MatchStrip = newFrame(panel, {
		Name = "Strip",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.new(0.36, 0, 0, 5),
		BackgroundColor3 = Colors.Stamina,
		BackgroundTransparency = 0,
	})
	Theme.Corner(UI.MatchStrip, UDim.new(0.5, 0))

	local nameRow = newFrame(panel, { Name = "NameRow", Position = UDim2.new(0, 16, 0, 9), Size = UDim2.new(0.62, 0, 0, 36) })
	newList(nameRow, {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 10),
	})
	UI.MatchName = newText(nameRow, "", "Title", 28, WHITE, {
		Name = "Difficulty",
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
	})
	UI.MatchStars = newText(nameRow, "", "Heading", 18, Colors.Token, {
		Name = "Stars",
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
	})

	UI.MatchTimer = newText(panel, "0:00", "Display", 34, WHITE, {
		Name = "Timer",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 7),
		Size = UDim2.new(0, 150, 0, 38),
		TextXAlignment = Enum.TextXAlignment.Right,
		Stroke = 0.3,
	})

	-- two progress columns: checkpoints | tokens
	local cols = newFrame(panel, { Name = "Progress", Position = UDim2.new(0, 16, 0, 48), Size = UDim2.new(1, -32, 0, 32) })
	local colA = newFrame(cols, { Name = "CheckpointCol", Size = UDim2.new(0.5, -9, 1, 0) })
	local colB = newFrame(cols, { Name = "TokenCol", Position = UDim2.new(0.5, 9, 0, 0), Size = UDim2.new(0.5, -9, 1, 0) })

	UI.CpLabel = newText(colA, "Checkpoint 0/0", "Heading", 15, WHITE, { Name = "Label", Size = UDim2.new(1, 0, 0, 16) })
	UI.CpScale = newScale(UI.CpLabel)
	UI.CpTrack, UI.CpFill = makeBar(colA, { Position = UDim2.new(0, 0, 0, 21), Size = UDim2.new(1, 0, 0, 10) }, Colors.Stamina)
	UI.CpFill.Size = UDim2.new(0, 0, 1, 0)

	UI.TokLabel = newText(colB, "Tokens 0/0", "Heading", 15, Colors.TokenGlow, {
		Name = "Label",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0, 8),
		Size = UDim2.new(1, 0, 0, 16),
	})
	UI.TokScale = newScale(UI.TokLabel)
	UI.TokTrack, UI.TokFill = makeBar(colB, { Position = UDim2.new(0, 0, 0, 21), Size = UDim2.new(1, 0, 0, 10) }, Colors.Token)
	UI.TokFill.Size = UDim2.new(0, 0, 1, 0)

	-- compact team row
	UI.Team = newFrame(panel, { Name = "Team", Position = UDim2.new(0, 16, 0, 86), Size = UDim2.new(1, -32, 0, 32) })
	newList(UI.Team, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
	})

	Items.Match = newItem(panel)
end

----------------------------------------------------------------------
-- Build: party panel + leave-match button (mid-left)
----------------------------------------------------------------------
local function onLeavePartyPressed()
	if os.clock() < (Pt.LockedUntil or 0) then
		return
	end
	Pt.LockedUntil = os.clock() + 1.0
	if UI.PartyStatus then
		UI.PartyStatus.Text = "Leaving\226\128\166" -- ellipsis
	end
	fireRemote("LeaveParty")
end

local function buildParty(parent)
	local panel = Theme.Panel({
		Name = "PartyPanel",
		Size = UDim2.new(0, PARTY_W, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, EDGE, 0.5, 0),
	})
	panel.Parent = parent
	UI.PartyPanel = panel
	newPadding(panel, 14)
	newList(panel, { Padding = UDim.new(0, 8) })

	local head = newFrame(panel, { Name = "Header", Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 1 })
	UI.PartyTitle = newText(head, "Party", "Heading", 19, WHITE, {
		Name = "Title",
		Size = UDim2.new(1, -64, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	UI.PartyCount = newText(head, "0 / 4", "Display", 21, Colors.TokenGlow, {
		Name = "Count",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 60, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	UI.PartyRows = newFrame(panel, {
		Name = "Players",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
	})
	newList(UI.PartyRows, { Padding = UDim.new(0, 3) })

	UI.PartyStatus = newText(panel, "Waiting for players\226\128\166", "Heading", 16, Colors.CloudShade, {
		Name = "Status",
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 3,
	})
	UI.PartyStatusScale = newScale(UI.PartyStatus)

	local barHolder = newFrame(panel, { Name = "CountdownBar", Size = UDim2.new(1, 0, 0, 10), LayoutOrder = 4 })
	UI.PartyBarTrack, UI.PartyBarFill = makeBar(barHolder, { Size = UDim2.new(1, 0, 1, 0) }, Colors.Good)
	UI.PartyBarFill.Size = UDim2.new(0, 0, 1, 0)

	UI.PartyLeave = makeButton(panel, "Leave", Color3.fromRGB(150, 60, 84), {
		Name = "Leave",
		Size = UDim2.new(1, 0, 0, 38),
		LayoutOrder = 5,
	})
	track(UI.PartyLeave.Activated:Connect(onLeavePartyPressed))

	Items.Party = newItem(panel)
end

local function resetLeaveMatchButton()
	LM.ArmedUntil = 0
	if UI.LeaveBtn then
		UI.LeaveBtn.Text = "Leave match"
		setButtonColor(UI.LeaveBtn, Color3.fromRGB(150, 60, 84))
	end
end

local function onLeaveMatchPressed()
	local now = os.clock()
	if now < LM.LockedUntil then
		return
	end
	if LM.ArmedUntil > now then
		-- second press inside the window: really leave
		LM.LockedUntil = now + 2
		LM.ArmedUntil = 0
		UI.LeaveBtn.Text = "Leaving\226\128\166"
		setButtonColor(UI.LeaveBtn, Colors.PanelLight)
		fireRemote("LeaveMatch")
		return
	end
	LM.ArmedUntil = now + LEAVE_CONFIRM_SECONDS
	UI.LeaveBtn.Text = "Press again to leave"
	setButtonColor(UI.LeaveBtn, Color3.fromRGB(205, 60, 80))
	local armed = LM.ArmedUntil
	task.delay(LEAVE_CONFIRM_SECONDS + 0.05, function()
		if LM.ArmedUntil == armed and LM.ArmedUntil ~= 0 then
			resetLeaveMatchButton()
		end
	end)
end

local function buildLeaveMatch(parent)
	local btn = makeButton(parent, "Leave match", Color3.fromRGB(150, 60, 84), {
		Name = "LeaveMatch",
		Size = UDim2.new(0, 190, 0, 40),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, EDGE, 0.5, 0),
		TextSize = 16,
	})
	UI.LeaveBtn = btn
	track(btn.Activated:Connect(onLeaveMatchPressed))
	Items.Leave = newItem(btn)
end

----------------------------------------------------------------------
-- Build: countdown overlay
----------------------------------------------------------------------
local function buildCountdown(parent)
	local frame = newFrame(parent, {
		Name = "Countdown",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.36, 0),
		Size = UDim2.new(0, 640, 0, 300),
		Visible = false,
	})
	UI.Countdown = frame
	UI.CountNumber = newText(frame, "3", "Accent", 200, WHITE, {
		Name = "Number",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.new(1, 0, 0, 230),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	UI.CountStroke = textStroke(UI.CountNumber, 9, 0)
	UI.CountScale = newScale(UI.CountNumber)
	UI.CountSub = newText(frame, "", "Script", 34, WHITE, {
		Name = "Sub",
		Position = UDim2.new(0, 0, 0, 236),
		Size = UDim2.new(1, 0, 0, 44),
		TextXAlignment = Enum.TextXAlignment.Center,
		Stroke = 0.2,
	})
end

----------------------------------------------------------------------
-- Layout / responsiveness
----------------------------------------------------------------------
local function positionTokenPanel()
	if not UI.TokenPanel then
		return
	end
	-- portrait phones: no room beside the match panel, so tuck the counter underneath it
	local y = 0
	if UI.Narrow and S.match then
		y = MATCH_H + 10
	end
	UI.TokenPanel.Position = UDim2.new(1, -(EDGE + (UI.Side or 0)), 0, y)
end

local function relayout()
	if not UI.Gui or not UI.Scale then
		return
	end
	local camera = workspace.CurrentCamera
	local vp = camera and camera.ViewportSize or Vector2.new(1280, 720)
	if vp.X < 8 or vp.Y < 8 then
		return
	end
	local s = clamp(math.min(vp.Y / DESIGN_H, vp.X / DESIGN_W), MIN_SCALE, MAX_SCALE)
	UI.Scale.Scale = s
	-- a UIScale also scales its parent's size: pre-divide so Root still covers the whole screen
	UI.Root.Size = UDim2.new(1 / s, 0, 1 / s, 0)

	local insetY = 0
	pcall(function()
		local topLeft = GuiService:GetGuiInset()
		insetY = topLeft.Y
	end)
	local topPad = insetY / s + 6
	UI.Top.Position = UDim2.new(0, 0, 0, topPad)
	UI.Top.Size = UDim2.new(1, 0, 1, -topPad)

	local touch = isTouchDevice()
	local side = touch and TOUCH_SAFE or 0
	local effW = vp.X / s -- viewport width in design pixels
	UI.Side = side
	UI.EffW = effW
	-- the match panel narrows a little on tall/narrow screens (the team row adapts to its width)
	local matchW = math.floor(clamp(effW - 2 * (EDGE + side), 440, MATCH_W))
	UI.MatchW = matchW
	UI.MatchPanel.Size = UDim2.new(0, matchW, 0, MATCH_H)
	UI.Narrow = effW < (matchW + 2 * (TOKEN_W + EDGE))

	-- vitals: bottom-left, or bottom-centre on touch so the thumbstick keeps the left edge
	if touch then
		UI.VitalsHolder.AnchorPoint = Vector2.new(0.5, 1)
		UI.VitalsHolder.Position = UDim2.new(0.5, 0, 1, -EDGE)
	else
		UI.VitalsHolder.AnchorPoint = Vector2.new(0, 1)
		UI.VitalsHolder.Position = UDim2.new(0, EDGE, 1, -EDGE)
	end

	local function setRest(item, rest, hidden)
		if not item then
			return
		end
		item.Rest = rest
		item.Hidden = hidden
		item.Frame.Position = item.Shown and rest or hidden
	end
	setRest(Items.Match, UDim2.new(0.5, 0, 0, 0), UDim2.new(0.5, 0, 0, -(MATCH_H + 70)))
	local leftRest = UDim2.new(0, EDGE + side, 0.5, 0)
	local leftHidden = UDim2.new(0, -(PARTY_W + 60), 0.5, 0)
	setRest(Items.Party, leftRest, leftHidden)
	setRest(Items.Leave, leftRest, leftHidden)

	positionTokenPanel()
end

----------------------------------------------------------------------
-- Health
----------------------------------------------------------------------
local function syncHealth(snap)
	local hum = H.Humanoid
	if not hum or not hum.Parent then
		return
	end
	local maxHp = hum.MaxHealth
	if type(maxHp) ~= "number" or maxHp <= 0 then
		maxHp = Config.Physics.MaxHealth
	end
	local cur = clamp(hum.Health, 0, maxHp)
	local frac = cur / maxHp
	local prevFrac = H.Target
	H.Cur = cur
	H.Max = maxHp
	H.Target = frac
	local now = os.clock()
	if snap then
		H.Fill = frac
		H.Trail = frac
		H.Hold = 0
		H.Flash = 0
		H.Pop = 0
		H.Color = Theme.HealthColor(frac)
	elseif frac < prevFrac - 0.0005 then
		-- took damage: hold the trail briefly, flash the bar, shake the panel, bump the heart
		H.Hold = now + 0.45
		H.Flash = 1
		H.ShakeUntil = now + 0.3
		H.Pop = 0.3
	elseif frac > prevFrac + 0.02 then
		-- healed / revived: a gentle brighten and heart bump
		H.Flash = math.max(H.Flash, 0.45)
		H.Pop = math.max(H.Pop, 0.15)
	end
	local text = tostring(math.floor(cur + 0.999)) .. " / " .. tostring(math.floor(maxHp + 0.5))
	if text ~= H.Text then
		H.Text = text
		UI.HealthText.Text = text
	end
end

local function unbindHumanoid()
	for _, c in ipairs(H.Conns) do
		c:Disconnect()
	end
	H.Conns = {}
	H.Humanoid = nil
end

local function bindCharacter(char)
	unbindHumanoid()
	H.Char = char
	if not char then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 10)
	if not hum or H.Char ~= char or not hum:IsA("Humanoid") then
		return
	end
	H.Humanoid = hum
	table.insert(H.Conns, hum.HealthChanged:Connect(function()
		syncHealth(false)
	end))
	table.insert(H.Conns, hum:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		syncHealth(false)
	end))
	syncHealth(true) -- respawn: snap, no trail
end

local function updateHealth(dt, now)
	-- cheap safety net in case a HealthChanged event is ever missed
	if now >= H.NextSync then
		H.NextSync = now + 0.5
		local hum = H.Humanoid
		if hum and hum.Parent and (math.abs(hum.Health - H.Cur) > 0.01 or hum.MaxHealth ~= H.Max) then
			syncHealth(false)
		end
	end

	-- fill chases the target quickly (the tween on HealthChanged); the trail lags behind on damage
	H.Fill = H.Fill + (H.Target - H.Fill) * (1 - math.exp(-dt * 16))
	if math.abs(H.Target - H.Fill) < 0.0005 then
		H.Fill = H.Target
	end
	if H.Trail < H.Fill then
		H.Trail = H.Fill
	elseif now >= H.Hold then
		H.Trail = H.Trail + (H.Fill - H.Trail) * (1 - math.exp(-dt * 3.5))
		if H.Trail - H.Fill < 0.0008 then
			H.Trail = H.Fill
		end
	end

	H.Color = H.Color:Lerp(Theme.HealthColor(H.Fill), 1 - math.exp(-dt * 9))
	H.Flash = math.max(0, H.Flash - dt * 4)
	H.Pop = math.max(0, H.Pop - dt * 1.2)
	local shown = H.Color:Lerp(WHITE, H.Flash * 0.65)

	UI.HealthFill.Size = UDim2.new(H.Fill, 0, 1, 0)
	UI.HealthTrail.Size = UDim2.new(H.Trail, 0, 1, 0)
	UI.HealthFill.BackgroundColor3 = shown
	UI.Heart.TextColor3 = shown
	UI.BadgeStroke.Color = H.Color

	-- low-health pulse (<30%): panel outline throbs red, heart beats
	local lowTarget = (H.Target < LOW_HEALTH) and 1 or 0
	H.Low = H.Low + (lowTarget - H.Low) * (1 - math.exp(-dt * 6))
	local beat = 0
	if H.Low > 0.01 then
		beat = math.max(0, math.sin(now * 7.5))
		beat = beat * beat
	end
	UI.HeartScale.Scale = 1 + H.Pop + 0.2 * beat * H.Low
	UI.VitalsStroke.Color = Colors.PanelLight:Lerp(Colors.HealthLow, H.Low * (0.3 + 0.7 * beat))
	UI.VitalsStroke.Transparency = 0.35 - 0.3 * H.Low * beat

	-- damage shake
	if now < H.ShakeUntil then
		local amp = 5 * (H.ShakeUntil - now) / 0.3
		UI.VitalsPanel.Position = UDim2.new(0, math.random(-100, 100) / 100 * amp, 0, math.random(-100, 100) / 100 * amp)
		H.Shaking = true
	elseif H.Shaking then
		H.Shaking = false
		UI.VitalsPanel.Position = UDim2.new(0, 0, 0, 0)
	end
end

local function setDowned(on)
	S.downed = on
	if S.downedShown == on then
		return
	end
	S.downedShown = on
	S.downedAt = os.clock()
	if on then
		UI.DownedPill.Visible = true
		UI.DownedScale.Scale = 0.5
		tween(UI.DownedScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	else
		tween(UI.DownedScale, 0.2, { Scale = 0.01 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.22, function()
			if not S.downedShown and UI.DownedPill.Parent then
				UI.DownedPill.Visible = false
			end
		end)
	end
end

local function updateDownedPulse(now)
	if S.downedShown and now - S.downedAt > 0.45 then
		UI.DownedScale.Scale = 1 + 0.03 * math.sin(now * 6)
	end
end

----------------------------------------------------------------------
-- Stamina + dash pip
----------------------------------------------------------------------
local function dashCooldownFraction(now)
	if not movementModule then
		if movementTries >= 6 or now < movementNextTry then
			return 0
		end
		movementTries = movementTries + 1
		movementNextTry = now + 1.5
		local parent = script and script.Parent
		local mod = parent and parent:FindFirstChild("MovementController")
		if mod and mod:IsA("ModuleScript") then
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
		return clamp(value, 0, 1)
	end
	return 0
end

local function updateStamina(dt, now)
	local maxSt = Config.Physics.MaxStamina
	local value = player:GetAttribute(Config.Attr.Stamina)
	if type(value) ~= "number" then
		value = maxSt
	end
	local target = clamp(value / maxSt, 0, 1)
	St.Frac = St.Frac + (target - St.Frac) * (1 - math.exp(-dt * 18))
	if math.abs(target - St.Frac) < 0.002 then
		St.Frac = target
	end

	-- the bar fades to a faint sliver when full and idle
	if target < 0.999 or math.abs(St.Frac - target) > 0.01 then
		St.Active = now
	end
	local want = (now - St.Active < 1.6) and 1 or 0
	St.Vis = St.Vis + (want - St.Vis) * (1 - math.exp(-dt * 5))

	local color = Colors.Stamina
	if target < 0.15 then
		color = Colors.Stamina:Lerp(Colors.HealthLow, 0.5 + 0.5 * math.sin(now * 10))
	end
	UI.StaminaFill.Size = UDim2.new(St.Frac, 0, 1, 0)
	UI.StaminaFill.BackgroundColor3 = color
	UI.StaminaFill.BackgroundTransparency = 0.45 * (1 - St.Vis)
	UI.StaminaTrack.BackgroundTransparency = 0.35 + 0.35 * (1 - St.Vis)

	-- dash pip: fills as the cooldown elapses and as stamina refills enough for a dash
	local cd = dashCooldownFraction(now)
	local cost = Config.Physics.DashStaminaCost
	local afford = clamp(value / cost, 0, 1)
	local charge = (1 - cd) * afford
	local charged = (cd <= 0.001) and (value >= cost)
	UI.PipFill.Size = UDim2.new(1, 0, charge, 0)
	UI.PipFill.BackgroundTransparency = charged and 0 or 0.35
	UI.PipGlyph.TextColor3 = charged and WHITE or Colors.CloudShade
	UI.PipStroke.Color = charged and Colors.Stamina or Colors.PanelLight
	if charged and not St.PipCharged then
		pop(UI.PipScale, 1.35, 0.3)
	end
	St.PipCharged = charged
end

----------------------------------------------------------------------
-- Cloud tokens
----------------------------------------------------------------------
local function setCountText(n)
	local text = Util.Commas(n)
	local len = #text
	UI.TokenCount.Text = text
	-- long numbers shrink a little so they never spill out of the panel
	if len <= 7 then
		UI.TokenCount.TextSize = 30
	elseif len <= 10 then
		UI.TokenCount.TextSize = 25
	else
		UI.TokenCount.TextSize = 20
	end
end

local function floatText(text)
	local label = newText(UI.TokenPanel, text, "Accent", 26, Colors.Token, {
		Name = "Float",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0, 28),
		Size = UDim2.new(0, 90, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 10,
		Stroke = 0.15,
	})
	tween(label, 1.0, {
		Position = UDim2.new(1, -12, 0, -10),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	task.delay(1.1, function()
		if label.Parent then
			label:Destroy()
		end
	end)
end

local function onTokensChanged()
	local v = math.max(0, math.floor(tonumber(player:GetAttribute(Config.Attr.Tokens)) or 0))
	local early = (os.clock() - startedAt) < 4 -- the saved total arrives right after joining: no fanfare
	if not Tk.Seen or early or v < Tk.Target then
		Tk.Seen = true
		Tk.Target = v
		Tk.Display = v
		return
	end
	if v > Tk.Target then
		local delta = v - Tk.Target
		Tk.Target = v
		pop(UI.TokenRingScale, 1.3, 0.4)
		pop(UI.TokenCountScale, 1.22, 0.4)
		floatText("+" .. tostring(delta))
	end
end

local function updateTokens(dt, now)
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

local function refreshRunLabel()
	local inMatch = (S.match ~= nil) or (player:GetAttribute(Config.Attr.InMatch) == true)
	if inMatch ~= Tk.RunVisible then
		Tk.RunVisible = inMatch
		UI.RunLabel.Visible = inMatch
		tween(UI.TokenPanel, 0.25, { Size = UDim2.new(0, TOKEN_W, 0, inMatch and TOKEN_H_MATCH or TOKEN_H) })
	end
	local n = math.max(0, math.floor(tonumber(player:GetAttribute(Config.Attr.MatchTokens)) or 0))
	local text = "this run: " .. tostring(n)
	if UI.RunLabel.Text ~= text then
		local grew = Tk.RunCount ~= nil and n > Tk.RunCount
		Tk.RunCount = n
		UI.RunLabel.Text = text
		if grew then
			pop(UI.RunScale, 1.25, 0.35)
		end
	end
end

----------------------------------------------------------------------
-- Visibility of the state-driven panels
----------------------------------------------------------------------
local function refreshVisibility()
	local hasMatch = S.match ~= nil
	local phase = hasMatch and S.match.Phase or nil
	present(Items.Match, hasMatch)
	present(Items.Leave, hasMatch and phase ~= "Ended")
	local inMatchAttr = player:GetAttribute(Config.Attr.InMatch) == true
	present(Items.Party, S.party ~= nil and not hasMatch and not inMatchAttr)
	refreshRunLabel()
	positionTokenPanel()
end

----------------------------------------------------------------------
-- Countdown overlay
----------------------------------------------------------------------
local function hideCountdown()
	CD.Serial = CD.Serial + 1
	CD.Last = nil
	if UI.Countdown then
		UI.Countdown.Visible = false
	end
end

-- Show one big "number" (3, 2, 1, GO!) with a scale punch. hold = seconds before it fades away.
local function punchCountdown(text, color, sub, hold)
	CD.Serial = CD.Serial + 1
	local serial = CD.Serial
	UI.Countdown.Visible = true
	UI.CountNumber.Text = text
	UI.CountNumber.TextColor3 = color
	UI.CountNumber.TextTransparency = 0.4
	UI.CountStroke.Transparency = 0.4
	UI.CountSub.Text = sub
	UI.CountSub.TextTransparency = 0
	UI.CountScale.Scale = 1.8
	tween(UI.CountScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	tween(UI.CountNumber, 0.2, { TextTransparency = 0 })
	tween(UI.CountStroke, 0.2, { Transparency = 0 })
	task.delay(hold, function()
		if CD.Serial ~= serial then
			return
		end
		tween(UI.CountNumber, 0.35, { TextTransparency = 1 })
		tween(UI.CountStroke, 0.35, { Transparency = 1 })
		tween(UI.CountSub, 0.35, { TextTransparency = 1 })
		tween(UI.CountScale, 0.35, { Scale = 1.35 })
		task.delay(0.4, function()
			if CD.Serial == serial then
				UI.Countdown.Visible = false
			end
		end)
	end)
end

local function updateCountdown(phase, prevPhase, seconds)
	if phase == "Countdown" then
		local n = math.ceil((tonumber(seconds) or 0) - 0.01)
		if n >= 1 and n ~= CD.Last then
			CD.Last = n
			local rainbow = Colors.Rainbow
			local color = rainbow[5]
			if n == 3 then
				color = rainbow[3]
			elseif n == 2 then
				color = rainbow[2]
			elseif n == 1 then
				color = rainbow[1]
			end
			punchCountdown(tostring(n), color, n <= 3 and "Ready\226\128\166" or "Get ready\226\128\166", 2.5)
		end
	elseif phase == "Playing" and prevPhase == "Countdown" then
		CD.Last = nil
		punchCountdown("GO!", Colors.Rainbow[4], "Climb together!", 0.9)
	elseif phase == "Ended" or prevPhase == nil then
		-- match over, or we joined mid-run: make sure no stale number is left on screen
		hideCountdown()
	end
	-- (Playing -> Playing updates leave a running "GO!" alone; it fades by itself)
end

----------------------------------------------------------------------
-- Match panel
----------------------------------------------------------------------
local function ensureChip(i)
	local chip = Mt.Chips[i]
	if chip then
		return chip
	end
	local frame = newFrame(UI.Team, {
		Name = "Chip" .. tostring(i),
		Size = UDim2.new(0, 118, 1, 0),
		BackgroundColor3 = Colors.Ink,
		BackgroundTransparency = 0.4,
		LayoutOrder = i,
	})
	Theme.Corner(frame, UDim.new(0, 8))
	local stroke = Theme.Stroke(frame, Colors.PanelLight, 1.5, 0.5)
	local name = newText(frame, "", "Body", 15, WHITE, {
		Name = "Name",
		Position = UDim2.new(0, 8, 0, 1),
		Size = UDim2.new(1, -34, 0, 18),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local state = newText(frame, "", "Heading", 14, WHITE, {
		Name = "State",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 1),
		Size = UDim2.new(0, 24, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	local hpTrack, hpFill = makeBar(frame, {
		Position = UDim2.new(0, 8, 1, -11),
		Size = UDim2.new(1, -16, 0, 6),
	}, Colors.Health)
	hpFill.Size = UDim2.new(1, 0, 1, 0)
	chip = { Frame = frame, Stroke = stroke, Name = name, State = state, Fill = hpFill, Track = hpTrack }
	Mt.Chips[i] = chip
	return chip
end

local function updateTeam(members)
	local count = #members
	local innerW = (UI.MatchW or MATCH_W) - 32
	local gap = 6
	local chipW = 118
	if count > 0 then
		chipW = math.floor(clamp((innerW - gap * (count - 1)) / count, 64, 118))
	end
	local selfId = player.UserId
	for i = 1, count do
		local m = members[i]
		local chip = ensureChip(i)
		chip.Frame.Visible = true
		chip.Frame.Size = UDim2.new(0, chipW, 1, 0)
		local name = tostring(m.Name or "?")
		if chip.Name.Text ~= name then
			chip.Name.Text = name
		end
		local glyph = ""
		if m.Finished then
			glyph = "\226\156\148" -- check mark
		elseif m.Downed then
			glyph = "\240\159\146\128" -- skull
		end
		if chip.State.Text ~= glyph then
			chip.State.Text = glyph
		end
		local isSelf = (m.UserId == selfId)
		chip.Name.TextColor3 = isSelf and Colors.TokenGlow or WHITE
		chip.Name.TextTransparency = m.Downed and 0.35 or 0
		chip.Stroke.Color = isSelf and Colors.Token or (m.Finished and Colors.Good or Colors.PanelLight)
		chip.Stroke.Transparency = isSelf and 0.1 or 0.5
		local frac = clamp(tonumber(m.Health) or 0, 0, 1)
		local fillColor = Theme.HealthColor(frac)
		if m.Downed then
			fillColor = Colors.Storm
		elseif m.Finished then
			fillColor = Colors.Good
			frac = 1
		end
		chip.Fill.BackgroundColor3 = fillColor
		tween(chip.Fill, 0.4, { Size = UDim2.new(frac, 0, 1, 0) })
	end
	for i = count + 1, #Mt.Chips do
		Mt.Chips[i].Frame.Visible = false
	end
end

local function rebuildTicks(total)
	for _, t in ipairs(Mt.Ticks) do
		t:Destroy()
	end
	Mt.Ticks = {}
	Mt.TotalCp = total
	if total < 2 or total > 24 then
		return
	end
	for i = 1, total - 1 do
		local tick = newFrame(UI.CpTrack, {
			Name = "Tick",
			Position = UDim2.new(i / total, -1, 0, 0),
			Size = UDim2.new(0, 2, 1, 0),
			BackgroundColor3 = Colors.Ink,
			BackgroundTransparency = 0.35,
			ZIndex = 3,
		})
		table.insert(Mt.Ticks, tick)
	end
end

local function flashFill(fill, color)
	fill.BackgroundColor3 = WHITE
	tween(fill, 0.6, { BackgroundColor3 = color })
end

local function stateColor(state, diff)
	if typeof(state.Color) == "Color3" then
		return state.Color
	end
	if diff and diff.Color then
		return diff.Color
	end
	return Colors.Stamina
end

local function clearMatch()
	S.match = nil
	Mt.Phase = nil
	Mt.Cp = nil
	Mt.Tokens = nil
	Mt.TimerText = nil
	Mt.DifficultyId = nil
	resetLeaveMatchButton()
	LM.LockedUntil = 0
	hideCountdown()
	refreshVisibility()
end

local function applyMatchState(state)
	if type(state) ~= "table" then
		clearMatch()
		return
	end
	local prevPhase = Mt.Phase
	S.match = state
	local phase = state.Phase
	local diff = Config.GetDifficulty(state.DifficultyId)
	local color = stateColor(state, diff)
	Mt.Color = color

	-- header: difficulty name (in its colour), stars
	if Mt.DifficultyId ~= state.DifficultyId then
		Mt.DifficultyId = state.DifficultyId
		local stars = diff and diff.Stars or 0
		UI.MatchStars.Text = string.rep("\226\152\133", stars) .. string.rep("\226\152\134", math.max(0, 3 - stars))
	end
	local dname = tostring(state.DifficultyName or (diff and diff.DisplayName) or "Match")
	if UI.MatchName.Text ~= dname then
		UI.MatchName.Text = dname
	end
	UI.MatchName.TextColor3 = color
	UI.MatchStrip.BackgroundColor3 = color

	-- timer bookkeeping (interpolated locally between the 2 Hz updates)
	Mt.Phase = phase
	Mt.Base = tonumber(state.Seconds) or 0
	Mt.At = os.clock()
	Mt.Limit = diff and diff.TimeLimit or nil

	-- checkpoint progress
	local cp = math.max(0, math.floor(tonumber(state.Checkpoint) or 0))
	local totalCp = math.max(0, math.floor(tonumber(state.TotalCheckpoints) or 0))
	if Mt.TotalCp ~= totalCp then
		rebuildTicks(totalCp)
	end
	UI.CpLabel.Text = "Checkpoint " .. tostring(cp) .. "/" .. tostring(totalCp)
	tween(UI.CpFill, 0.5, { Size = UDim2.new(totalCp > 0 and clamp(cp / totalCp, 0, 1) or 0, 0, 1, 0) })
	if Mt.Cp ~= nil and cp > Mt.Cp then
		flashFill(UI.CpFill, color) -- checkpoint reached: white flash fading back to the tint
		pop(UI.CpScale, 1.2, 0.4)
	else
		UI.CpFill.BackgroundColor3 = color
	end
	Mt.Cp = cp

	-- token progress
	local got = math.max(0, math.floor(tonumber(state.TokensCollected) or 0))
	local totalTok = math.max(0, math.floor(tonumber(state.TotalTokens) or 0))
	UI.TokLabel.Text = "Tokens " .. tostring(got) .. "/" .. tostring(totalTok)
	tween(UI.TokFill, 0.5, { Size = UDim2.new(totalTok > 0 and clamp(got / totalTok, 0, 1) or 0, 0, 1, 0) })
	if Mt.Tokens ~= nil and got > Mt.Tokens then
		flashFill(UI.TokFill, Colors.Token)
		pop(UI.TokScale, 1.2, 0.4)
	end
	Mt.Tokens = got

	-- team
	local members = state.Members
	if type(members) ~= "table" then
		members = {}
	end
	updateTeam(members)

	updateCountdown(phase, prevPhase, state.Seconds)
	refreshVisibility()
end

local function updateTimer(dt, now)
	if not S.match then
		return
	end
	local phase = Mt.Phase
	local remaining
	if phase == "Playing" then
		remaining = math.max(0, Mt.Base - (now - Mt.At))
	elseif phase == "Countdown" then
		remaining = Mt.Limit
	else
		remaining = Mt.Base
	end
	local text = remaining and Util.FormatTime(remaining) or "--:--"
	if text ~= Mt.TimerText then
		Mt.TimerText = text
		UI.MatchTimer.Text = text
	end
	local color = WHITE
	if phase == "Ended" then
		color = Colors.CloudShade
	elseif phase == "Countdown" then
		color = Colors.CloudShade
	elseif remaining and remaining <= 20 then
		color = Colors.HealthLow:Lerp(WHITE, 0.5 + 0.5 * math.sin(now * 8))
	elseif remaining and remaining <= 60 then
		color = Colors.HealthMid
	end
	UI.MatchTimer.TextColor3 = color
end

----------------------------------------------------------------------
-- Party panel
----------------------------------------------------------------------
local function ensurePartyRow(i)
	local row = Pt.Rows[i]
	if row then
		return row
	end
	row = newText(UI.PartyRows, "", "Body", 17, WHITE, {
		Name = "Row" .. tostring(i),
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = i,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	Pt.Rows[i] = row
	return row
end

local function applyPartyState(state)
	if type(state) ~= "table" then
		S.party = nil
		Pt.Total = nil
		Pt.PrevCountdown = nil
		refreshVisibility()
		return
	end
	local firstTime = (S.party == nil)
	S.party = state

	local diff = Config.GetDifficulty(state.PortalId)
	local color = (typeof(state.Color) == "Color3") and state.Color or (diff and diff.Color) or WHITE
	local dname = tostring(state.DifficultyName or (diff and diff.DisplayName) or "Party")
	UI.PartyTitle.Text = "Party \226\128\147 " .. dname -- en dash
	UI.PartyTitle.TextColor3 = color

	local players = state.Players
	if type(players) ~= "table" then
		players = {}
	end
	local maxPlayers = math.floor(tonumber(state.Max) or Config.Match.MaxPlayers)
	maxPlayers = clamp(math.max(maxPlayers, #players), 1, 8)
	UI.PartyCount.Text = tostring(#players) .. " / " .. tostring(maxPlayers)

	local selfId = player.UserId
	for i = 1, maxPlayers do
		local row = ensurePartyRow(i)
		row.Visible = true
		local p = players[i]
		if p then
			row.Font = Theme.Fonts.Body
			row.TextSize = 17
			row.TextTransparency = 0
			row.TextColor3 = (p.UserId == selfId) and Colors.TokenGlow or WHITE
			row.Text = "\226\151\143  " .. tostring(p.Name or "?") -- bullet
		else
			row.Font = Theme.Fonts.Script
			row.TextSize = 16
			row.TextTransparency = 0.35
			row.TextColor3 = Colors.CloudShade
			row.Text = "\226\151\139  waiting\226\128\166" -- hollow bullet
		end
	end
	for i = maxPlayers + 1, #Pt.Rows do
		Pt.Rows[i].Visible = false
	end

	-- status line + countdown bar
	local cd = tonumber(state.Countdown)
	if cd then
		Pt.Total = math.max(Pt.Total or 0, cd, 1)
		local secs = math.max(0, math.ceil(cd - 0.01))
		local full = #players >= maxPlayers
		UI.PartyStatus.Text = (full and "Party full! " or "") .. "Starting in " .. tostring(secs) .. "s"
		local urgent = secs <= 5
		UI.PartyStatus.TextColor3 = urgent and Colors.HealthMid or Colors.Good
		UI.PartyBarFill.BackgroundColor3 = urgent and Colors.HealthMid or Colors.Good
		tween(UI.PartyBarFill, 1.0, { Size = UDim2.new(clamp(cd / Pt.Total, 0, 1), 0, 1, 0) }, Enum.EasingStyle.Linear)
		if urgent and Pt.PrevCountdown ~= secs then
			pop(UI.PartyStatusScale, 1.12, 0.3)
		end
		Pt.PrevCountdown = secs
	else
		Pt.Total = nil
		Pt.PrevCountdown = nil
		UI.PartyStatus.Text = "Waiting for players\226\128\166"
		UI.PartyStatus.TextColor3 = Colors.CloudShade
		tween(UI.PartyBarFill, 0.3, { Size = UDim2.new(0, 0, 1, 0) })
	end

	if firstTime then
		Pt.LockedUntil = 0
	end
	refreshVisibility()
end

----------------------------------------------------------------------
-- Per-frame loop
----------------------------------------------------------------------
local function onRender(dt)
	local now = os.clock()
	guard("health", updateHealth, dt, now)
	guard("stamina", updateStamina, dt, now)
	guard("tokens", updateTokens, dt, now)
	guard("timer", updateTimer, dt, now)
	guard("downed", updateDownedPulse, now)
end

----------------------------------------------------------------------
-- Title card
----------------------------------------------------------------------
local function playTitleCard()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	task.wait(0.5)
	if not UI.Root or not UI.Root.Parent then
		return
	end

	-- text sizes follow the available width so the title also fits narrow (portrait) screens
	local effW = UI.EffW or DESIGN_W
	local titleSize = math.floor(clamp(effW * 0.11, 44, 104))
	local tagSize = math.floor(clamp(effW * 0.032, 20, 36))
	local titleH = math.floor(titleSize * 1.16)
	local card = newFrame(UI.Root, {
		Name = "TitleCard",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.26, 0),
		Size = UDim2.new(0, math.floor(math.min(900, effW - 24)), 0, titleH + tagSize + 28),
	})
	local cardScale = newScale(card)
	cardScale.Scale = 0.85

	local title = newText(card, string.upper(Config.GameName), "Title", titleSize, WHITE, {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, titleH),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
	})
	local titleStroke = textStroke(title, 6, 1)
	local keys = {}
	local rainbow = Colors.Rainbow
	for i, c in ipairs(rainbow) do
		table.insert(keys, ColorSequenceKeypoint.new((i - 1) / (#rainbow - 1), c:Lerp(WHITE, 0.2)))
	end
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(keys)
	grad.Parent = title

	local line = newFrame(card, {
		Name = "Divider",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, titleH + 4),
		Size = UDim2.new(0, math.floor(math.min(420, effW * 0.4)), 0, 3),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 1,
	})
	local lineGrad = Instance.new("UIGradient")
	lineGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	lineGrad.Parent = line

	local tagline = newText(card, "\226\156\166  " .. tostring(Config.Tagline) .. "  \226\156\166", "Script", tagSize, Colors.TokenGlow, {
		Name = "Tagline",
		Position = UDim2.new(0, 0, 0, titleH + 16),
		Size = UDim2.new(1, 0, 0, tagSize + 10),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})

	-- fade in
	tween(cardScale, 0.9, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	tween(title, 0.9, { TextTransparency = 0 })
	tween(titleStroke, 0.9, { Transparency = 0 })
	tween(line, 0.9, { BackgroundTransparency = 0.1 })
	tween(tagline, 0.9, { TextTransparency = 0, TextStrokeTransparency = 0.3 })

	task.wait(TITLE_CARD_SECONDS - 0.8 - 0.1)

	-- fade out
	tween(title, 0.8, { TextTransparency = 1 })
	tween(titleStroke, 0.8, { Transparency = 1 })
	tween(line, 0.8, { BackgroundTransparency = 1 })
	tween(tagline, 0.8, { TextTransparency = 1, TextStrokeTransparency = 1 })
	tween(card, 0.8, { Position = UDim2.new(0.5, 0, 0.23, 0) })
	task.wait(0.9)
	card:Destroy()
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local function buildGui()
	local playerGui = player:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("NimbusHud")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "NimbusHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	UI.Gui = gui

	local root = newFrame(gui, { Name = "Root", Size = UDim2.new(1, 0, 1, 0) })
	UI.Root = root
	UI.Scale = newScale(root)
	UI.Top = newFrame(root, { Name = "TopArea", Size = UDim2.new(1, 0, 1, 0) })

	buildVitals(root)
	buildTokens(UI.Top)
	buildMatch(UI.Top)
	buildParty(root)
	buildLeaveMatch(root)
	buildCountdown(root)

	gui.Parent = playerGui
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
		guard("run label", refreshRunLabel)
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
	local savedTotal = player:GetAttribute(attr.Tokens)
	onTokensChanged() -- snaps the counter to the current value (or 0)
	Tk.Seen = (savedTotal ~= nil) -- no attribute yet: the saved total is still on its way, snap to it too
	refreshRunLabel()
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
