-- TutorialController (client): Nimbus the Cloudy Dragon guides a new player (ARCHITECTURE_V3.md section 4).
--
--   TutorialController.Init()
--   TutorialController.GetState() -> the last TutorialState payload (nil until one arrived)
--
-- What it shows (all client-side, nothing system-announced in the screen centre):
--   * Side panel (ScreenGui "NimbusTutorial", display order 12): a compact cloud card on the LEFT, below the HUD's
--     top-left panel area and right of the menu column (both MEASURED: NimbusHud attribute TopLeftBottom /
--     BottomLeftTop and NimbusMenu.MenuColumn / MenuButton_*). It holds a round portrait of Nimbus (PetBuilder
--     Cloudy Dragon in a ViewportFrame, gently flapping, livelier while talking), the step title, "Step 3/9",
--     progress pips, the typewriter text, a hint line with the live distance, a Next button (CompleteOn = "Next")
--     and a small "Skip tutorial" link that asks to confirm. Tapping the portrait folds the card into a bubble;
--     screens too small for the card get the bubble automatically. Designed in 1080p pixels under a UIScale of
--     Theme.ScreenFactor() (readability rule: body 20, captions 18, buttons 22, title 30 -> >= 14.4 px on phones).
--     Step completion: a voxel confetti burst from the portrait; the end of the tutorial: a bigger one.
--   * Guide arrow for world targets (Spot / Shop / Roulette / Portal, found by name under workspace.NimbusLobby,
--     the server's Target.Position as a fallback): a bouncing, spinning golden voxel arrow sculpted with
--     shared/Voxel.lua, a ring of floating voxel sparkles on the ground, a floating name + distance sign and a
--     dotted sparkle Beam from the HumanoidRootPart toward the target (workspace.ClientFx.TutorialGuide).
--   * Menu targets: a pulsing gold ring around MenuButton_<Id> and a small pixel-art arrow pointing at it
--     (ScreenGui "NimbusTutorialPointer", display order 21, above the menu).
--   * Hidden in a match except the "finish" step text; the guides only show in the lobby.
-- Events sent through TutorialEvent (the server validates them against the current step): "Next", "Skip",
-- "ShopOpened" / "IndexOpened" / "PetsOpened" (MenuController.WindowOpened / IndexController.WindowOpened, the
-- OpenPanel remote and clicks on the matching menu button) and "Sync" (asks for the state again).
-- Per-frame work runs in ONE RenderStepped connection, only while something is shown.
-- Plain Lua 5.1-compatible syntax only. All fonts come from Theme roles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))

local Client = script.Parent.Parent
local LocalPlayer = Players.LocalPlayer

local TutorialController = {}

----------------------------------------------------------------------
-- Tunables (design pixels of a 1080p screen unless noted)
----------------------------------------------------------------------
local K = {
	PANEL_W = 440,
	PANEL_MIN_W = 260,
	PAD = 14,
	PORTRAIT = 96,
	PORTRAIT_Y = -14, -- the portrait pops a little above the card
	HEADER_H = 96, -- card height above the text well
	WELL_PAD = 12,
	HINT_H = 26,
	FOOTER_H = 48,
	NAME_SIZE = 30,
	TITLE_SIZE = 22,
	BODY_SIZE = 20,
	CAPTION_SIZE = 18,
	BUTTON_SIZE = 22,
	NEXT_W = 150,
	BUTTON_H = 44,
	PIP = 12,
	PIP_GAP = 5,
	EDGE = 12,
	TOUCH_EDGE = 20,
	GAP = 10,
	MIDDLE = 0.15, -- the screen middle the panel keeps out of: |dx| < 15% width and |dy| < 15% height
	TYPE_CPS = 52, -- typewriter characters per second
	TYPE_DELAY = 0.2,
	FIRST_SHOW_DELAY = 1.2,
	PANEL_ORDER = 12, -- HUD 10, hotbar 11, windows 20, toasts 30
	POINTER_ORDER = 21, -- above the menu column
	EVENT_COOLDOWN = 0.35,
	NEXT_LOCK = 2.5,
	SKIP_LOCK = 3,
	LAYOUT_EVERY = 0.5,
	PORTRAIT_STEP = 1 / 30,
	FINALE_SECONDS = 4.5,
	-- world guide (studs)
	VOXEL = 0.36,
	ARROW_LIFT = 5, -- arrow centre above the target top (the arrow is ~7.6 studs tall: its tip clears the top)
	BOB = 0.7,
	SPIN = 1.5,
	TRAIL_MAX = 90,
	TRAIL_HIDE = 10,
	SPARKLES = 10,
	RESOLVE_RETRY = 2,
	-- confetti (gui px at factor 1)
	CONFETTI_SMALL = 26,
	CONFETTI_BIG = 64,
	GRAVITY = 820,
}

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local BULLET = "\194\187 " -- >>
local TOKEN_GLYPH = "\226\152\129" -- cloud

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local TC = Theme.Colors
local C = {
	Navy = TC.Navy or TC.Ink,
	Ink = TC.Ink,
	Stroke = TC.TextStroke or TC.Ink,
	White = TC.White,
	Gold = TC.Gold or TC.Token,
	Muted = TC.Muted or TC.Cloud,
	FrameTop = TC.FrameTop or TC.Cloud,
	FrameBottom = TC.FrameBottom or TC.CloudShade,
	WellTop = TC.WellTop or TC.PanelLight,
	WellBottom = TC.WellBottom or TC.Panel,
	WellEdge = TC.WellEdge or TC.Navy or TC.Ink,
	DiscTop = rgb(156, 204, 248),
	DiscBottom = rgb(96, 152, 224),
	ArrowLight = rgb(255, 226, 128),
	Arrow = rgb(246, 190, 64),
	ArrowDark = rgb(198, 132, 38),
	ArrowShine = rgb(255, 248, 222),
	Shadow = rgb(8, 12, 32),
	Confetti = {
		rgb(244, 196, 78),
		rgb(238, 126, 176),
		rgb(96, 196, 108),
		rgb(90, 158, 234),
		rgb(176, 120, 236),
		rgb(255, 236, 168),
		rgb(240, 150, 84),
	},
}

-- client event -> the CompleteOn it completes (mirrors TutorialService)
local EVENT_NEEDS = { Next = "Next", ShopOpened = "ShopOpened", IndexOpened = "IndexOpened", PetsOpened = "Equipped" }
-- window / panel ids (WindowOpened, OpenPanel, menu buttons) -> event
local WINDOW_EVENTS = { Shop = "ShopOpened", Index = "IndexOpened", Pets = "PetsOpened", Inventory = "PetsOpened" }
-- the menu button that leads to what the current step waits for
local HOOK_FOR = { ShopOpened = "Shop", IndexOpened = "Index", Equipped = "Pets" }
local WORLD_KINDS = { Spot = true, Shop = true, Roulette = true, Portal = true }
local DEFAULT_HINTS = {
	NearSpot = "Walk to your plot",
	ShopOpened = "Open the shop",
	Rolled = "Spin a roulette",
	Equipped = "Tap the glowing Pets button",
	IndexOpened = "Tap the glowing Index button",
	MatchStarted = "Step into the portal",
	MatchEnded = "Reach the finish",
}

-- Runtime tables (kept in a few tables so the module stays far below Lua's 200-locals limit)
local UI = {} -- panel + pointer instances
local S = { clock = 0, layoutTimer = 0, hintTimer = 0, typing = false } -- panel state
local P = { yaw = 0.38, side = -1, dist = 6, height = 3, accum = 0, excitedUntil = 0 } -- portrait
local M = { findTimer = 0 } -- menu pointer
local W = { built = false, active = false, resolveTimer = 0, labelTimer = 0 } -- world guide
local R = { last = {}, hooked = {} } -- remotes + hooks
local Fx = { pool = {}, live = 0 } -- confetti
local Mods = {} -- optional modules: name -> table | false
local warned = {}

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function warnOnce(key, message)
	if not warned[key] then
		warned[key] = true
		warn("[TutorialController] " .. tostring(message))
	end
end

local function safe(key, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warnOnce(key, key .. " failed: " .. tostring(err))
	end
	return ok
end

local function loadModule(container, name, timeout)
	if not container then
		return nil
	end
	local inst = container:FindFirstChild(name)
	if not inst and timeout then
		local okWait, found = pcall(function()
			return container:WaitForChild(name, timeout)
		end)
		if okWait then
			inst = found
		end
	end
	if not inst then
		return nil
	end
	local ok, result = pcall(require, inst)
	if ok and type(result) == "table" then
		return result
	end
	warnOnce("load" .. name, "could not load " .. name .. ": " .. tostring(result))
	return nil
end

-- Optional collaborators, loaded on first use (missing ones simply switch a feature off).
local function mod(name)
	local cached = Mods[name]
	if cached == nil then
		local loaded
		if name == "CloudUI" then
			loaded = loadModule(Client:FindFirstChild("UI"), "CloudUI", 5)
		elseif name == "MenuController" or name == "IndexController" then
			loaded = loadModule(script.Parent, name)
		else
			loaded = loadModule(Shared, name, 5)
		end
		cached = loaded or false
		Mods[name] = cached
	end
	return cached or nil
end

local function make(className, name, props, parent)
	local inst = Instance.new(className)
	inst.Name = name
	if props then
		for key, value in pairs(props) do
			inst[key] = value
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- A transparent, borderless Frame unless props say otherwise.
local function box(name, props, parent)
	props = props or {}
	if props.BackgroundTransparency == nil then
		props.BackgroundTransparency = 1
	end
	props.BorderSizePixel = 0
	return make("Frame", name, props, parent)
end

local function corner(parent, px)
	return make("UICorner", "Corner", { CornerRadius = UDim.new(0, px) }, parent)
end

local function round(parent)
	return make("UICorner", "Corner", { CornerRadius = UDim.new(0.5, 0) }, parent)
end

local function stroke(parent, color, thickness, transparency)
	return make("UIStroke", "Stroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function gradient(parent, top, bottom)
	return make("UIGradient", "Gradient", { Color = ColorSequence.new(top, bottom), Rotation = 90 }, parent)
end

-- A Theme-styled label with a thick glyph outline (reads on any background).
local function label(parent, name, text, role, size, color, props)
	local obj = Theme.Label(text, role, {
		Size = size,
		Color = color or C.White,
		Stroke = 1,
		Outline = 2,
		OutlineColor = C.Stroke,
	})
	obj.Name = name
	if props then
		for key, value in pairs(props) do
			obj[key] = value
		end
	end
	obj.Parent = parent
	return obj
end

-- Chunky cloud button (CloudUI.Button when available, a Theme-styled fallback otherwise).
local function button(props)
	local CloudUI = mod("CloudUI")
	if CloudUI and type(CloudUI.Button) == "function" then
		local ok, made = pcall(CloudUI.Button, props)
		if ok and made then
			return made
		end
	end
	local base = (Theme.Buttons and Theme.Buttons[props.Style or "Green"]) or C.Gold
	local obj = make("TextButton", props.Name or "Button", {
		AutoButtonColor = true,
		BorderSizePixel = 0,
		BackgroundColor3 = base,
		Size = props.Size,
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.new(0, 0),
		Text = props.Text or "",
	})
	Theme.Style(obj, "Button", { Size = props.TextSize or K.BUTTON_SIZE, Stroke = 1, Outline = 2, OutlineColor = C.Stroke })
	corner(obj, 12)
	stroke(obj, C.Navy, 3, 0)
	if props.Callback then
		obj.Activated:Connect(function()
			if obj:GetAttribute("Disabled") ~= true then
				props.Callback(obj)
			end
		end)
	end
	obj.Parent = props.Parent
	return obj
end

local function setDisabled(obj, disabled)
	if not obj then
		return
	end
	local CloudUI = mod("CloudUI")
	if CloudUI and type(CloudUI.SetDisabled) == "function" then
		pcall(CloudUI.SetDisabled, obj, disabled)
	else
		obj:SetAttribute("Disabled", disabled and true or false)
		obj.AutoButtonColor = not disabled
	end
end

local function setStyle(obj, style)
	local CloudUI = mod("CloudUI")
	if obj and CloudUI and type(CloudUI.SetStyle) == "function" then
		pcall(CloudUI.SetStyle, obj, style)
	elseif obj and Theme.Buttons and Theme.Buttons[style] then
		obj.BackgroundColor3 = Theme.Buttons[style]
	end
end

local function tween(inst, seconds, goal, style, direction)
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
	local t = TweenService:Create(inst, info, goal)
	t:Play()
	return t
end

local function inMatch()
	return LocalPlayer:GetAttribute(Config.Attr.InMatch) == true
end

local function playerGui()
	return LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

local function topInset()
	local inset = 0
	pcall(function()
		inset = GuiService:GetGuiInset().Y
	end)
	return inset
end

-- y shift that converts another ScreenGui's AbsolutePosition into ours (ours does not ignore the inset).
local function insetShift(gui)
	if gui and gui:IsA("ScreenGui") and gui.IgnoreGuiInset then
		return -topInset()
	end
	return 0
end

local function shownIn(inst, rootGui)
	local node = inst
	while node and node ~= rootGui do
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		node = node.Parent
	end
	if rootGui and rootGui:IsA("ScreenGui") and not rootGui.Enabled then
		return false
	end
	return node == rootGui
end

local function rectOf(inst, dy)
	local p, s = inst.AbsolutePosition, inst.AbsoluteSize
	return { x0 = p.X, y0 = p.Y + dy, x1 = p.X + s.X, y1 = p.Y + s.Y + dy }
end

local function guiArea()
	local size = UI.Gui and UI.Gui.AbsoluteSize
	if size and size.X > 1 and size.Y > 1 then
		return size
	end
	local camera = Workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 1 then
		return Vector2.new(camera.ViewportSize.X, camera.ViewportSize.Y - topInset())
	end
	return Vector2.new(1280, 660)
end

local function rootPart()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function firstRouletteId()
	local list = Config.Roulettes
	if type(list) == "table" and type(list[1]) == "table" and type(list[1].Id) == "string" then
		return list[1].Id
	end
	return "Cloud"
end

local function graphemeCount(text)
	if utf8 and type(utf8.len) == "function" then
		local ok, n = pcall(utf8.len, text)
		if ok and type(n) == "number" then
			return n
		end
	end
	return #text
end

----------------------------------------------------------------------
-- Remotes
----------------------------------------------------------------------
local function getRemote(name)
	local folder = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:WaitForChild("Remotes", 15)
	if not folder then
		return nil
	end
	local remote = folder:FindFirstChild(name) or folder:WaitForChild(name, 10)
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end
	return nil
end

-- Sends a tutorial event. Window / Next events go out only when the current step waits for them.
local function fireEvent(name)
	if not R.event then
		return false
	end
	if name ~= "Sync" and name ~= "Skip" then
		local st = S.state
		if not st or st.Done or EVENT_NEEDS[name] ~= st.CompleteOn then
			return false
		end
	end
	local now = os.clock()
	local last = R.last[name]
	if last and now - last < K.EVENT_COOLDOWN then
		return false
	end
	R.last[name] = now
	local ok = pcall(function()
		R.event:FireServer(name)
	end)
	return ok
end

local function onWindowOpened(windowId)
	local event = WINDOW_EVENTS[tostring(windowId)]
	if event then
		fireEvent(event)
	end
end

----------------------------------------------------------------------
-- Panel: measuring + layout
----------------------------------------------------------------------
-- Height of the wrapped body text (design px). TextService wraps at the frame width; a result wider than the
-- frame means it did not wrap, so a per-line estimate is used instead.
local function bodyHeight(text, width)
	local perLine = math.max(8, math.floor(width / (K.BODY_SIZE * 0.52)))
	local estimate = math.max(1, math.ceil(#text / perLine)) * math.ceil(K.BODY_SIZE * 1.2) + 6
	local ok, size = pcall(function()
		return TextService:GetTextSize(text, K.BODY_SIZE, Theme.Fonts.Body, Vector2.new(width, 10000))
	end)
	if ok and size and size.Y > 0 and size.X <= width + 1 then
		return math.ceil(size.Y) + 6
	end
	return estimate
end

local function hintShown()
	local st = S.state
	return st ~= nil and not st.Done and st.CompleteOn ~= "Next" and not S.finale
end

local function footerShown()
	return not S.finale
end

-- Design-pixel height of the expanded panel at `width` (cached per width + text).
local function panelHeight(width)
	local text = S.fullText or ""
	local key = tostring(width) .. "|" .. text .. "|" .. tostring(hintShown()) .. "|" .. tostring(footerShown())
	if S.heightKey == key then
		return S.heightValue, S.bodyValue
	end
	local textWidth = width - 2 * K.PAD - 2 * K.WELL_PAD
	local bodyH = bodyHeight(text, textWidth)
	local h = K.HEADER_H + 10 + bodyH + 8 + K.PAD
	if hintShown() then
		h = h + K.HINT_H + 4
	end
	if footerShown() then
		h = h + K.FOOTER_H
	end
	S.heightKey, S.heightValue, S.bodyValue = key, h, bodyH
	return h, bodyH
end

-- MenuController's column (or the union of its MenuButton_* tiles) in our gui coordinates.
local function menuRect()
	local pg = playerGui()
	local menuGui = pg and pg:FindFirstChild("NimbusMenu")
	if not (menuGui and menuGui:IsA("ScreenGui") and menuGui.Enabled) then
		return nil
	end
	local dy = insetShift(menuGui)
	local column = menuGui:FindFirstChild("MenuColumn", true)
	if column and column:IsA("GuiObject") and column.AbsoluteSize.X > 0 and shownIn(column, menuGui) then
		return rectOf(column, dy)
	end
	local found = nil
	for _, d in ipairs(menuGui:GetDescendants()) do
		if d:IsA("GuiObject") and string.sub(d.Name, 1, 11) == "MenuButton_" and d.AbsoluteSize.X > 0 and shownIn(d, menuGui) then
			local r = rectOf(d, dy)
			if found then
				found.x0, found.y0 = math.min(found.x0, r.x0), math.min(found.y0, r.y0)
				found.x1, found.y1 = math.max(found.x1, r.x1), math.max(found.y1, r.y1)
			else
				found = r
			end
		end
	end
	return found
end

-- HUD neighbours: bottom of the top-left panel area and top of the bottom-left block (0 / nil when absent).
local function hudBounds(area)
	local pg = playerGui()
	local hud = pg and pg:FindFirstChild("NimbusHud")
	local topLeftBottom, bottomLeftTop = 0, area.Y
	if hud and hud:IsA("ScreenGui") and hud.Enabled then
		local dy = insetShift(hud)
		local a = tonumber(hud:GetAttribute("TopLeftBottom"))
		if a and a > 0 then
			topLeftBottom = a + dy
		end
		local b = tonumber(hud:GetAttribute("BottomLeftTop"))
		if b and b > 0 then
			bottomLeftTop = b + dy
		end
	end
	return topLeftBottom, bottomLeftTop
end

local function collapsed()
	if S.finale then
		return false
	end
	if S.manual == "collapsed" then
		return true
	end
	return S.manual ~= "expanded" and S.autoCollapse == true
end

-- Applies the inner geometry of the panel for a design width / height.
local function applyGeometry(width, height, bodyH)
	UI.Root.Size = UDim2.fromOffset(width, height)
	UI.Body.Size = UDim2.new(1, -2 * K.WELL_PAD, 0, bodyH)
	UI.TypeSkip.Size = UI.Body.Size
	UI.Hint.Position = UDim2.fromOffset(K.WELL_PAD, 10 + bodyH + 4)
	UI.Hint.Visible = hintShown()
	UI.Footer.Visible = footerShown()
	-- narrow cards drop the counter pill (the pips still show the progress) so the name keeps its room
	local x0 = K.PAD + K.PORTRAIT + 12
	local roomy = width - x0 - 150 >= 96
	UI.CounterPill.Visible = roomy
	if roomy then
		UI.Name.Size = UDim2.new(1, -(x0 + 150), 0, 34)
	else
		UI.Name.Size = UDim2.new(1, -(x0 + 56), 0, 34)
	end
	-- pips shrink when many steps share a narrow header
	local total = #UI.PipList
	if total > 0 then
		local room = width - (K.PAD + K.PORTRAIT + 12) - K.PAD
		local pip = math.max(6, math.min(K.PIP, math.floor(room / total) - K.PIP_GAP))
		for _, pipFrame in ipairs(UI.PipList) do
			pipFrame.Size = UDim2.fromOffset(pip, pip)
		end
	end
end

local function layout()
	if not UI.Root then
		return
	end
	local area = guiArea()
	local k = Theme.ScreenFactor()
	if UI.Scale.Scale ~= k then
		UI.Scale.Scale = k
	end
	if UI.PointerScale and UI.PointerScale.Scale ~= k then
		UI.PointerScale.Scale = k
	end
	local edge = UserInputService.TouchEnabled and K.TOUCH_EDGE or K.EDGE
	local inset = topInset()
	local screenH = area.Y + inset
	local midX0 = area.X * (0.5 - K.MIDDLE)
	local midY0 = screenH * (0.5 - K.MIDDLE) - inset
	local midY1 = screenH * (0.5 + K.MIDDLE) - inset
	local hudTop, hudBottom = hudBounds(area)
	local column = menuRect()
	-- the portrait pokes PORTRAIT_Y above the card: the card starts that much lower
	local top = edge
	if hudTop > 0 then
		top = math.max(edge, hudTop + K.GAP * k)
	end
	top = top - K.PORTRAIT_Y * k
	local bottomLimit = math.min(area.Y - edge, hudBottom - K.GAP * k)

	local function leftFor(t, h)
		if column and t < column.y1 + K.GAP * k and t + h > column.y0 - K.GAP * k then
			return math.max(edge, column.x1 + K.GAP * k)
		end
		return edge
	end

	-- expanded card: as wide as allowed, never into the screen middle, never under the bottom-left HUD
	local width = K.PANEL_W
	local h = panelHeight(width) * k
	local left = leftFor(top, h)
	local maxW = math.floor((area.X - left - edge) / k)
	if width > maxW then
		width = maxW
		h = panelHeight(width) * k
		left = leftFor(top, h)
	end
	if left + width * k > midX0 and top + h > midY0 and top < midY1 then
		width = math.floor((midX0 - left) / k)
		h = panelHeight(math.max(width, K.PANEL_MIN_W)) * k
		left = leftFor(top, h)
	end
	local fits = width >= K.PANEL_MIN_W and top + h <= bottomLimit
	width = math.max(width, K.PANEL_MIN_W)
	S.autoCollapse = not fits

	local designH, bodyH = panelHeight(width)
	if collapsed() then
		left = leftFor(top, (K.PORTRAIT + K.PORTRAIT_Y) * k)
	end
	applyGeometry(width, designH, bodyH)
	UI.Main.Visible = not collapsed()
	UI.Badge.Visible = collapsed()
	UI.TapTag.Visible = collapsed() and S.manual == nil

	local goal = UDim2.fromOffset(math.floor(left + 0.5), math.floor(top + 0.5))
	if S.placed ~= goal then
		S.placed = goal
		if UI.Root.Visible and S.hasPlaced then
			tween(UI.Root, 0.25, { Position = goal })
		else
			UI.Root.Position = goal
		end
		S.hasPlaced = true
	end

	-- floating sign above the world arrow follows the readability rule too
	if W.labelGui then
		W.labelGui.Size = UDim2.fromOffset(math.floor(230 * k), math.floor(66 * k))
	end
end

----------------------------------------------------------------------
-- Panel: building
----------------------------------------------------------------------
local PUFFS = { { 0.34, 30, -3 }, { 0.44, 40, -7 }, { 0.54, 28, -2 } } -- x scale, diameter, centre y

local function buildPips(total)
	for _, old in ipairs(UI.PipList) do
		old:Destroy()
	end
	UI.PipList = {}
	for i = 1, total do
		local pip = box("Pip" .. i, {
			BackgroundTransparency = 0,
			BackgroundColor3 = C.Navy,
			Size = UDim2.fromOffset(K.PIP, K.PIP),
			LayoutOrder = i,
		}, UI.Pips)
		corner(pip, 3)
		stroke(pip, C.Navy, 2, 0)
		UI.PipList[i] = pip
	end
end

local function paintPips(current, allDone)
	for i, pip in ipairs(UI.PipList) do
		if allDone or i < current then
			pip.BackgroundColor3 = C.Gold
			pip.BackgroundTransparency = 0
		elseif i == current then
			pip.BackgroundColor3 = C.White
			pip.BackgroundTransparency = 0
		else
			pip.BackgroundColor3 = C.WellBottom
			pip.BackgroundTransparency = 0.15
		end
	end
end

local function buildPortrait(parent)
	local holder = box("Portrait", {
		Size = UDim2.fromOffset(K.PORTRAIT, K.PORTRAIT),
		Position = UDim2.fromOffset(K.PAD, K.PORTRAIT_Y),
		ZIndex = 2,
	}, parent)
	local disc = box("Disc", { BackgroundTransparency = 0, BackgroundColor3 = C.White, Size = UDim2.fromScale(1, 1) }, holder)
	round(disc)
	stroke(disc, C.Navy, 4, 0)
	gradient(disc, C.DiscTop, C.DiscBottom)
	-- a soft cloud bank behind Nimbus
	local bank = box("CloudBank", {
		BackgroundTransparency = 0.2,
		BackgroundColor3 = C.FrameTop,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -3),
		Size = UDim2.new(0.86, 0, 0.3, 0),
	}, disc)
	round(bank)
	local view = make("ViewportFrame", "Nimbus", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
		Ambient = rgb(186, 192, 218),
		LightColor = rgb(255, 246, 232),
		LightDirection = Vector3.new(-0.4, -0.8, 1),
	}, holder)
	round(view)
	local ring = box("Ring", { Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6) }, holder)
	round(ring)
	stroke(ring, C.Gold, 3, 0)
	local toggle = make("TextButton", "Toggle", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromScale(1, 1),
	}, holder)
	-- "!" badge, shown while the card is folded away
	local badge = box("Badge", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.Gold,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -8, 0, 10),
		Size = UDim2.fromOffset(30, 30),
		Visible = false,
	}, holder)
	round(badge)
	stroke(badge, C.Navy, 3, 0)
	label(badge, "Mark", "!", "Title", 22, C.White, { Size = UDim2.fromScale(1, 1) })
	-- "Tap me!" tag beside the bubble when the screen is too small for the card
	local tag = box("TapTag", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.Navy,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(1, 8, 0.5, 0),
		Size = UDim2.fromOffset(104, 34),
		Visible = false,
	}, holder)
	corner(tag, 10)
	stroke(tag, C.Gold, 2, 0)
	label(tag, "Text", "Tap me!", "Heading", K.CAPTION_SIZE, C.Gold, { Size = UDim2.fromScale(1, 1) })
	UI.Portrait, UI.View, UI.Toggle, UI.Badge, UI.TapTag = holder, view, toggle, badge, tag
end

local function buildPixelArrow(parent)
	-- a chunky left-pointing pixel arrow: navy outline, three gold shades and a glint pixel
	local cols, rows, cell = 17, 11, 4
	local function inside(r, c)
		if r < 0 or r >= rows or c < 0 or c >= cols then
			return false
		end
		local head = c <= 7 and c >= math.abs(r - 5)
		local shaft = r >= 3 and r <= 7 and c >= 6
		return head or shaft
	end
	local palette = { o = C.Navy, L = C.ArrowLight, G = C.Arrow, D = C.ArrowDark, W = C.ArrowShine }
	for r = 0, rows - 1 do
		local runKey, runStart = nil, 0
		for c = 0, cols do
			local key = nil
			if c < cols and inside(r, c) then
				local edgeCell = not (inside(r - 1, c) and inside(r + 1, c) and inside(r, c - 1) and inside(r, c + 1))
				if edgeCell then
					key = "o"
				elseif r == 4 and c == 3 then
					key = "W"
				elseif r <= 4 then
					key = "L"
				elseif r == 5 then
					key = "G"
				else
					key = "D"
				end
			end
			if key ~= runKey then
				if runKey then
					box("Px" .. r .. "_" .. runStart, {
						BackgroundTransparency = 0,
						BackgroundColor3 = palette[runKey],
						Position = UDim2.fromOffset(runStart * cell, r * cell),
						Size = UDim2.fromOffset((c - runStart) * cell, cell),
					}, parent)
				end
				runKey, runStart = key, c
			end
		end
	end
	parent.Size = UDim2.fromOffset(cols * cell, rows * cell)
end

local function buildPointer()
	local pg = playerGui()
	local gui = make("ScreenGui", "NimbusTutorialPointer", {
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = K.POINTER_ORDER,
	}, nil)
	local ring = box("Ring", { AnchorPoint = Vector2.new(0.5, 0.5), Visible = false, Active = false }, gui)
	corner(ring, 18)
	UI.RingStroke = stroke(ring, C.Gold, 4, 0)
	local glow = box("Glow", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 12, 1, 12),
		Active = false,
	}, ring)
	corner(glow, 22)
	UI.GlowStroke = stroke(glow, C.ArrowLight, 3, 0.5)
	local inner = box("Inner", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -8, 1, -8),
		Active = false,
	}, ring)
	corner(inner, 14)
	stroke(inner, C.Navy, 2, 0.2)
	local arrow = box("Arrow", { AnchorPoint = Vector2.new(0, 0.5), Visible = false, Active = false }, gui)
	buildPixelArrow(arrow)
	UI.PointerScale = make("UIScale", "ReadScale", { Scale = 1 }, arrow)
	UI.PointerGui, UI.Ring, UI.Arrow = gui, ring, arrow
	gui.Parent = pg
end

local function onNextPressed()
	if S.typing then
		S.typeShown = S.typeTotal -- first press reveals the whole line
		return
	end
	if os.clock() < (S.nextLockUntil or 0) then
		return
	end
	if fireEvent("Next") then
		S.nextLockUntil = os.clock() + K.NEXT_LOCK
		setDisabled(UI.Next, true)
	end
end

local function setConfirming(on)
	S.confirming = on and true or false
	UI.Confirm.Visible = S.confirming
	UI.SkipLink.Visible = not S.confirming
	UI.Next.Visible = not S.confirming and S.state ~= nil and S.state.CompleteOn == "Next" and not S.state.Done
end

local function buildPanel()
	local pg = playerGui()
	local gui = make("ScreenGui", "NimbusTutorial", {
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = K.PANEL_ORDER,
	}, nil)
	UI.Gui = gui
	local root = box("TutorialPanel", { Size = UDim2.fromOffset(K.PANEL_W, 260), Visible = false }, gui)
	UI.Root = root
	UI.Scale = make("UIScale", "ReadScale", { Scale = 1 }, root)
	local slide = box("Slide", { Size = UDim2.fromScale(1, 1) }, root)
	UI.Slide = slide

	local main = box("Main", { Size = UDim2.fromScale(1, 1), ZIndex = 1 }, slide)
	UI.Main = main
	local shadow = box("Shadow", {
		BackgroundTransparency = 0.62,
		BackgroundColor3 = C.Shadow,
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	}, main)
	corner(shadow, 18)
	local rings = box("PuffRings", { Size = UDim2.fromScale(1, 1), ZIndex = 2 }, main)
	local card = box("Card", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.White,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Active = true, -- clicks on the card never fall through to the world
	}, main)
	corner(card, 18)
	stroke(card, C.Navy, 4, 0)
	gradient(card, C.FrameTop, C.FrameBottom)
	local rim = box("Rim", { Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6) }, card)
	corner(rim, 15)
	stroke(rim, Theme.Lighten(C.FrameTop, 0.55), 2, 0.35)
	local gloss = box("Gloss", {
		BackgroundTransparency = 0.62,
		BackgroundColor3 = C.White,
		Position = UDim2.fromOffset(K.PAD + K.PORTRAIT + 8, 6),
		Size = UDim2.new(1, -(2 * K.PAD + K.PORTRAIT + 16), 0, 5),
	}, card)
	round(gloss)
	local puffs = box("Puffs", { Size = UDim2.fromScale(1, 1), ZIndex = 4 }, main)
	for i, spec in ipairs(PUFFS) do
		local d = spec[2]
		local ringFrame = box("Ring" .. i, {
			BackgroundTransparency = 0,
			BackgroundColor3 = C.Navy,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(spec[1], 0, 0, spec[3]),
			Size = UDim2.fromOffset(d + 8, d + 8),
		}, rings)
		round(ringFrame)
		local puff = box("Puff" .. i, {
			BackgroundTransparency = 0,
			BackgroundColor3 = C.FrameTop,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(spec[1], 0, 0, spec[3]),
			Size = UDim2.fromOffset(d, d),
		}, puffs)
		round(puff)
		local tuft = box("Tuft", {
			BackgroundTransparency = 0.6,
			BackgroundColor3 = C.White,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.42, 0, 0.14, 0),
			Size = UDim2.new(0.5, 0, 0.3, 0),
		}, puff)
		round(tuft)
	end

	-- header: name, step title, pips, counter pill, fold button
	local header = box("Header", { Size = UDim2.new(1, 0, 0, K.HEADER_H), ZIndex = 5 }, main)
	local x0 = K.PAD + K.PORTRAIT + 12
	UI.Name = label(header, "GuideName", "Nimbus", "Title", K.NAME_SIZE, C.Gold, {
		Position = UDim2.fromOffset(x0, 12),
		Size = UDim2.new(1, -(x0 + 150), 0, 34),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	UI.StepTitle = label(header, "StepTitle", "", "Heading", K.TITLE_SIZE, C.White, {
		Position = UDim2.fromOffset(x0, 46),
		Size = UDim2.new(1, -(x0 + K.PAD), 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	UI.Pips = box("Pips", { Position = UDim2.fromOffset(x0, 76), Size = UDim2.new(1, -(x0 + K.PAD), 0, K.PIP + 2) }, header)
	make("UIListLayout", "List", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, K.PIP_GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}, UI.Pips)
	UI.PipList = {}
	local pill = box("Counter", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.Navy,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(K.PAD + 44), 0, 12),
		Size = UDim2.fromOffset(104, 32),
	}, header)
	corner(pill, 10)
	stroke(pill, C.Gold, 2, 0)
	UI.Counter = label(pill, "Text", "Step 1/1", "Heading", K.CAPTION_SIZE, C.White, { Size = UDim2.fromScale(1, 1) })
	UI.CounterPill = pill
	local fold = make("TextButton", "Fold", {
		BackgroundColor3 = Theme.Buttons and Theme.Buttons.Blue or C.WellTop,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Text = "",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -K.PAD, 0, 12),
		Size = UDim2.fromOffset(36, 32),
	}, header)
	corner(fold, 10)
	stroke(fold, C.Navy, 3, 0)
	box("Bar", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.White,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.56),
		Size = UDim2.fromOffset(16, 5),
	}, fold)
	UI.Fold = fold

	-- text well
	local well = box("Well", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.White,
		Position = UDim2.fromOffset(K.PAD, K.HEADER_H),
		Size = UDim2.new(1, -2 * K.PAD, 1, -(K.HEADER_H + K.PAD)),
		ZIndex = 6,
	}, main)
	corner(well, 12)
	stroke(well, C.WellEdge, 3, 0.05)
	gradient(well, C.WellTop, C.WellBottom)
	UI.Well = well
	UI.Body = label(well, "Body", "", "Body", K.BODY_SIZE, C.White, {
		Position = UDim2.fromOffset(K.WELL_PAD, 10),
		Size = UDim2.new(1, -2 * K.WELL_PAD, 0, 60),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	UI.TypeSkip = make("TextButton", "TypeSkip", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Position = UI.Body.Position,
		Size = UI.Body.Size,
	}, well)
	UI.Hint = label(well, "Hint", "", "Label", K.CAPTION_SIZE, C.Gold, {
		Position = UDim2.fromOffset(K.WELL_PAD, 70),
		Size = UDim2.new(1, -2 * K.WELL_PAD, 0, K.HINT_H),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local footer = box("Footer", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, K.WELL_PAD, 1, -6),
		Size = UDim2.new(1, -2 * K.WELL_PAD, 0, K.FOOTER_H),
		ZIndex = 2,
	}, well)
	UI.Footer = footer
	local skip = make("TextButton", "SkipLink", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(132, 34),
		Text = "Skip tutorial",
		TextXAlignment = Enum.TextXAlignment.Left,
	}, footer)
	Theme.Style(skip, "Label", { Size = K.CAPTION_SIZE, Color = C.Muted, Stroke = 1, Outline = 2, OutlineColor = C.Stroke })
	box("Underline", {
		BackgroundTransparency = 0.35,
		BackgroundColor3 = C.Muted,
		Position = UDim2.new(0, 0, 1, -5),
		Size = UDim2.new(0, 104, 0, 2),
	}, skip)
	UI.SkipLink = skip
	UI.Next = button({
		Name = "Next",
		Text = "Next",
		Style = "Green",
		TextSize = K.BUTTON_SIZE,
		Size = UDim2.fromOffset(K.NEXT_W, K.BUTTON_H),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Callback = onNextPressed,
		Parent = footer,
	})

	local confirm = box("Confirm", { Size = UDim2.fromScale(1, 1), Visible = false }, footer)
	UI.Confirm = confirm
	label(confirm, "Question", "Skip the tutorial?", "Body", 19, C.White, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, -196, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
	})
	UI.ConfirmYes = button({
		Name = "ConfirmSkip",
		Text = "Skip",
		Style = "Red",
		TextSize = 20,
		Size = UDim2.fromOffset(92, 40),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -100, 0.5, 0),
		Callback = function()
			if fireEvent("Skip") then
				S.skipLockUntil = os.clock() + K.SKIP_LOCK
				setDisabled(UI.ConfirmYes, true)
			end
		end,
		Parent = confirm,
	})
	button({
		Name = "ConfirmStay",
		Text = "Stay",
		Style = "Blue",
		TextSize = 20,
		Size = UDim2.fromOffset(92, 40),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Callback = function()
			setConfirming(false)
		end,
		Parent = confirm,
	})

	buildPortrait(slide)

	-- confetti layer (gui pixels, no UIScale)
	UI.Fx = box("Confetti", { Size = UDim2.fromScale(1, 1), ZIndex = 50, Active = false }, gui)

	-- input
	skip.Activated:Connect(function()
		setConfirming(true)
	end)
	UI.TypeSkip.Activated:Connect(function()
		if S.typing then
			S.typeShown = S.typeTotal
		end
	end)
	UI.Toggle.Activated:Connect(function()
		if collapsed() then
			S.manual = "expanded"
		else
			S.manual = "collapsed"
		end
		safe("layout", layout)
	end)
	fold.Activated:Connect(function()
		S.manual = "collapsed"
		safe("layout", layout)
	end)

	gui.Parent = pg
end

----------------------------------------------------------------------
-- Portrait: PetBuilder Cloudy Dragon in the viewport
----------------------------------------------------------------------
local function setupPortraitModel()
	local view = UI.View
	if not view or P.model then
		return
	end
	local Steps = mod("TutorialSteps")
	local guide = Steps and type(Steps.Guide) == "table" and Steps.Guide or {}
	local petId = type(guide.PetId) == "string" and guide.PetId or "cloudy_dragon"
	local PetBuilder = mod("PetBuilder")
	local PetCatalog = mod("PetCatalog")
	local def = nil
	if PetCatalog and type(PetCatalog.Get) == "function" then
		local okDef, found = pcall(PetCatalog.Get, petId)
		if okDef and type(found) == "table" then
			def = found
		end
	end
	local model = nil
	if def and PetBuilder and type(PetBuilder.Build) == "function" then
		local okBuild, built = pcall(PetBuilder.Build, def, { Detail = "High", Scale = 1 })
		if okBuild and typeof(built) == "Instance" then
			model = built
		else
			warnOnce("portrait", "PetBuilder.Build failed: " .. tostring(built))
		end
	end
	if not model then
		-- no pet art available: a friendly cloud glyph instead of an empty bubble
		label(view.Parent, "Fallback", TOKEN_GLYPH, "Title", 52, C.White, { Size = UDim2.fromScale(1, 1), ZIndex = 3 })
		return
	end
	model.Parent = view
	pcall(function()
		model:PivotTo(CFrame.new())
	end)
	P.builder = PetBuilder
	if type(PetBuilder.Animate) == "function" then
		pcall(PetBuilder.Animate, model, 0.3, { Flap = 0.8 })
	end
	local center, height = Vector3.new(0, 1.2, 0), 2.6
	local okBox, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if okBox and cf and size then
		center, height = cf.Position, math.max(0.5, size.Y)
	end
	-- pets face -Z; if this model's eyes sit on +Z, film that side instead
	local sum, count = 0, 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and string.find(string.lower(d.Name), "eye", 1, true) then
			sum = sum + (d.Position.Z - center.Z)
			count = count + 1
		end
	end
	if count > 0 and sum / count > 0.05 then
		P.side = 1
		view.LightDirection = Vector3.new(-0.4, -0.8, -1)
	end
	P.model = model
	P.height = height
	P.focus = center + Vector3.new(0, height * 0.1, 0)
	P.dist = (height * 0.62) / math.tan(math.rad(15)) -- the whole head, horns included, and a hint of wings
	P.camera = make("Camera", "PortraitCamera", { FieldOfView = 30 }, view)
	view.CurrentCamera = P.camera
end

local function updatePortrait(dt, t)
	if not P.model or not P.camera then
		return
	end
	P.accum = P.accum + dt
	if P.accum < K.PORTRAIT_STEP then
		return
	end
	P.accum = 0
	local excited = 0
	if t < P.excitedUntil then
		excited = 1
	elseif S.typing then
		excited = 0.35
	end
	local a = P.yaw + math.sin(t * 0.55) * 0.12
	local bob = math.sin(t * 1.7) * P.height * 0.03
	local focus = P.focus + Vector3.new(0, bob, 0)
	local offset = Vector3.new(math.sin(a) * P.dist, P.dist * 0.1, math.cos(a) * P.dist * P.side)
	P.camera.CFrame = CFrame.lookAt(focus + offset, focus)
	if P.builder and type(P.builder.Animate) == "function" then
		local ok = pcall(P.builder.Animate, P.model, t, { Flap = 0.7 + excited * 1.1, Excited = excited })
		if not ok then
			P.builder = nil
		end
	end
end

----------------------------------------------------------------------
-- Confetti (voxel squares), pooled
----------------------------------------------------------------------
local function burst(big)
	if not UI.Fx or not UI.Portrait then
		return
	end
	local k = Theme.ScreenFactor()
	local origin = UI.Portrait.AbsolutePosition + UI.Portrait.AbsoluteSize * 0.5 - UI.Fx.AbsolutePosition
	local count = big and K.CONFETTI_BIG or K.CONFETTI_SMALL
	for i = 1, count do
		local piece = nil
		for _, p in ipairs(Fx.pool) do
			if not p.alive then
				piece = p
				break
			end
		end
		if not piece then
			if #Fx.pool >= K.CONFETTI_BIG * 2 then
				break
			end
			local frameObj = box("Bit", { BackgroundTransparency = 0, AnchorPoint = Vector2.new(0.5, 0.5), Visible = false }, UI.Fx)
			piece = { frame = frameObj, alive = false }
			table.insert(Fx.pool, piece)
		end
		local angle = -0.25 - math.random() * 2.2 -- up and to the right, away from the screen edge
		local speed = (big and 300 or 230) + math.random() * (big and 340 or 220)
		local px = math.floor((5 + math.random() * 6) * k + 0.5)
		piece.alive = true
		piece.x, piece.y = origin.X, origin.Y
		piece.vx = math.cos(angle) * speed * k + 40 * k
		piece.vy = math.sin(angle) * speed * k
		piece.rot = math.random() * 90
		piece.vr = (math.random() - 0.5) * 720
		piece.age = 0
		piece.life = 1.1 + math.random() * (big and 0.9 or 0.5)
		local f = piece.frame
		f.BackgroundColor3 = C.Confetti[(i % #C.Confetti) + 1]
		f.Size = UDim2.fromOffset(px, px)
		f.BackgroundTransparency = 0
		f.Position = UDim2.fromOffset(piece.x, piece.y)
		f.Visible = true
	end
	Fx.live = 0
	for _, p in ipairs(Fx.pool) do
		if p.alive then
			Fx.live = Fx.live + 1
		end
	end
end

local function updateConfetti(dt)
	if Fx.live <= 0 then
		return
	end
	local k = Theme.ScreenFactor()
	local live = 0
	for _, p in ipairs(Fx.pool) do
		if p.alive then
			p.age = p.age + dt
			if p.age >= p.life then
				p.alive = false
				p.frame.Visible = false
			else
				p.vy = p.vy + K.GRAVITY * k * dt
				p.vx = p.vx * (1 - math.min(0.9, 1.4 * dt))
				p.x = p.x + p.vx * dt
				p.y = p.y + p.vy * dt
				p.rot = p.rot + p.vr * dt
				local f = p.frame
				f.Position = UDim2.fromOffset(p.x, p.y)
				f.Rotation = p.rot
				local fade = (p.age - p.life * 0.65) / (p.life * 0.35)
				if fade > 0 then
					f.BackgroundTransparency = math.min(1, fade)
				end
				live = live + 1
			end
		end
	end
	Fx.live = live
end

local function celebrate(big)
	P.excitedUntil = S.clock + (big and 2.6 or 1.4)
	if S.shown then
		safe("burst", burst, big)
	end
	if UI.Portrait then
		-- a happy hop of the portrait
		local base = UDim2.fromOffset(K.PAD, K.PORTRAIT_Y)
		UI.Portrait.Position = base
		local up = tween(UI.Portrait, 0.14, { Position = UDim2.fromOffset(K.PAD, K.PORTRAIT_Y - 10) })
		up.Completed:Connect(function()
			tween(UI.Portrait, 0.32, { Position = base }, Enum.EasingStyle.Bounce)
		end)
	end
end

----------------------------------------------------------------------
-- Panel: content + visibility
----------------------------------------------------------------------
local function setVisibleGraphemes(n)
	if S.noGraphemes then
		if n < 0 then
			UI.Body.Text = S.fullText or ""
		else
			UI.Body.Text = string.sub(S.fullText or "", 1, n)
		end
		return
	end
	local ok = pcall(function()
		UI.Body.MaxVisibleGraphemes = n
	end)
	if not ok then
		S.noGraphemes = true
		setVisibleGraphemes(n)
	end
end

local function startTyping(text)
	S.fullText = text
	UI.Body.Text = text
	S.typeTotal = graphemeCount(text)
	S.typeShown = 0
	S.typeDelay = K.TYPE_DELAY
	S.typing = true
	setVisibleGraphemes(0)
end

local function updateTypewriter(dt)
	if not S.typing then
		return
	end
	if S.typeDelay > 0 then
		S.typeDelay = S.typeDelay - dt
		return
	end
	S.typeShown = S.typeShown + dt * K.TYPE_CPS
	if S.typeShown >= S.typeTotal then
		S.typing = false
		setVisibleGraphemes(-1)
	else
		setVisibleGraphemes(math.floor(S.typeShown))
	end
end

local function hintText()
	local st = S.state
	if not st then
		return ""
	end
	local text = st.Hint or DEFAULT_HINTS[st.CompleteOn] or ""
	if W.active and W.distance then
		if W.distance <= K.TRAIL_HIDE then
			text = text .. "  \194\183  you're here!"
		else
			text = text .. "  \194\183  " .. math.floor(W.distance + 0.5) .. " studs"
		end
	end
	return BULLET .. text
end

-- Fills the panel with the current step (called when the step changes).
local function renderStep()
	local st = S.state
	if not st or not UI.Root then
		return
	end
	UI.StepTitle.Text = st.Title ~= "" and st.Title or "Nimbus says"
	UI.Counter.Text = "Step " .. st.Step .. "/" .. st.Total
	if #UI.PipList ~= st.Total then
		buildPips(st.Total)
	end
	paintPips(st.Step, false)
	UI.Hint.Text = hintText()
	local isNext = st.CompleteOn == "Next"
	UI.Next.Text = st.Button or "Next"
	setStyle(UI.Next, st.Step >= st.Total and "Gold" or "Green")
	setDisabled(UI.Next, false)
	setDisabled(UI.ConfirmYes, false)
	S.nextLockUntil = 0
	setConfirming(false)
	UI.Next.Visible = isNext
	S.heightKey = nil
	startTyping(st.Text)
	safe("layout", layout)
end

local function renderFinale(reward)
	S.finale = true
	S.typing = false
	UI.StepTitle.Text = "All done!"
	UI.Counter.Text = "Complete!"
	paintPips(0, true)
	local text = "You know the basics now. Happy climbing, see you in the clouds!"
	if type(reward) == "number" and reward > 0 then
		text = "+" .. reward .. " " .. TOKEN_GLYPH .. " Cloud Tokens are yours! You know the basics now. Happy climbing!"
	end
	S.heightKey = nil
	startTyping(text)
	S.typeShown = 0
	safe("layout", layout)
end

local function panelWanted()
	if S.finale then
		return S.clock < (S.finaleUntil or 0)
	end
	local st = S.state
	if not st or st.Done then
		return false
	end
	if S.clock < (S.showAfter or 0) then
		return false
	end
	if inMatch() and st.CompleteOn ~= "MatchEnded" then
		return false
	end
	return true
end

local function setPanelShown(on)
	if not UI.Root then
		return
	end
	if on == S.shown then
		return
	end
	S.shown = on
	local k = math.max(0.1, UI.Scale.Scale)
	local hiddenX = -math.floor((UI.Root.AbsolutePosition.X / k) + UI.Root.Size.X.Offset + 40)
	if on then
		safe("layout", layout)
		UI.Root.Visible = true
		UI.Slide.Position = UDim2.fromOffset(hiddenX, 0)
		tween(UI.Slide, 0.45, { Position = UDim2.fromOffset(0, 0) }, Enum.EasingStyle.Back)
		if S.typing then
			S.typeDelay = math.max(S.typeDelay or 0, 0.35) -- let the card arrive before talking
		end
	else
		local out = tween(UI.Slide, 0.3, { Position = UDim2.fromOffset(hiddenX, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		out.Completed:Connect(function()
			if not S.shown and UI.Root then
				UI.Root.Visible = false
			end
		end)
	end
end

----------------------------------------------------------------------
-- Menu pointer: pulsing ring + pixel arrow at MenuButton_<Id>
----------------------------------------------------------------------
local function findMenuButton(id)
	local pg = playerGui()
	if not pg or type(id) ~= "string" then
		return nil
	end
	local names = { "MenuButton_" .. id, "Menu_" .. id }
	for _, name in ipairs(names) do
		for _, d in ipairs(pg:GetDescendants()) do
			if d.Name == name and d:IsA("GuiObject") and d.AbsoluteSize.X > 0 then
				local owner = d:FindFirstAncestorOfClass("ScreenGui")
				if owner and owner ~= UI.Gui and owner ~= UI.PointerGui and shownIn(d, owner) then
					return d
				end
			end
		end
	end
	return nil
end

local function isButton(obj)
	return obj:IsA("TextButton") or obj:IsA("ImageButton")
end

-- The button itself, or the first button inside a tile frame.
local function clickable(obj)
	if isButton(obj) then
		return obj
	end
	for _, d in ipairs(obj:GetDescendants()) do
		if isButton(d) then
			return d
		end
	end
	return nil
end

-- Hooks clicks on the menu button that leads to what the current step waits for.
local function refreshClickHook()
	local st = S.state
	local id = st and not st.Done and HOOK_FOR[st.CompleteOn] or nil
	if id ~= M.hookId or (M.hookConn and not (M.hookButton and M.hookButton.Parent)) then
		if M.hookConn then
			M.hookConn:Disconnect()
			M.hookConn = nil
		end
		M.hookId = id
		M.hookButton = nil
	end
	if id and not M.hookConn then
		local found = findMenuButton(id)
		local target = found and clickable(found)
		if target then
			M.hookButton = target
			M.hookConn = target.Activated:Connect(function()
				task.delay(0.35, onWindowOpened, id)
			end)
		end
	end
end

local function hidePointer()
	if UI.Ring and UI.Ring.Visible then
		UI.Ring.Visible = false
	end
	if UI.Arrow and UI.Arrow.Visible then
		UI.Arrow.Visible = false
	end
end

local function updateMenuPointer(dt, t)
	local st = S.state
	local want = st and not st.Done and not S.finale and st.Target and st.Target.Kind == "Menu" and S.shown and not inMatch()
	M.findTimer = M.findTimer - dt
	if M.findTimer <= 0 then
		M.findTimer = 1
		safe("menu hook", refreshClickHook)
		if want then
			local valid = M.button and M.button.Parent and M.buttonId == st.Target.Id
			if valid then
				local owner = M.button:FindFirstAncestorOfClass("ScreenGui")
				valid = owner ~= nil and shownIn(M.button, owner)
			end
			if not valid then
				M.button = findMenuButton(st.Target.Id)
				M.buttonId = st.Target.Id
			end
		end
	end
	if not want or not M.button or not M.button.Parent then
		hidePointer()
		return
	end
	local owner = M.button:FindFirstAncestorOfClass("ScreenGui")
	local r = rectOf(M.button, insetShift(owner))
	local w, h = r.x1 - r.x0, r.y1 - r.y0
	if w <= 0 or h <= 0 then
		hidePointer()
		return
	end
	local k = Theme.ScreenFactor()
	local pulse = (math.sin(t * 4.2) + 1) * 0.5
	local pad = (5 + 5 * pulse) * k
	UI.Ring.Position = UDim2.fromOffset((r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5)
	UI.Ring.Size = UDim2.fromOffset(w + 2 * pad, h + 2 * pad)
	UI.RingStroke.Transparency = 0.25 * pulse
	UI.GlowStroke.Transparency = 0.3 + 0.55 * pulse
	UI.Arrow.Position = UDim2.fromOffset(r.x1 + (8 + 7 * (math.sin(t * 5) + 1) * 0.5) * k, (r.y0 + r.y1) * 0.5)
	UI.Ring.Visible = true
	UI.Arrow.Visible = true
end

----------------------------------------------------------------------
-- World guide: voxel arrow, sparkle ring, sign and dotted beam
----------------------------------------------------------------------
local function clientFx()
	local folder = Workspace:FindFirstChild("ClientFx")
	if not folder then
		folder = make("Folder", "ClientFx", nil, Workspace)
	end
	return folder
end

local function finishArrowPart(part)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Massless = true
end

-- The golden guide arrow, sculpted with the voxel kit (a stepped-block arrow when the kit is missing).
local function buildArrowModel()
	local Voxel = mod("Voxel")
	local model = nil
	if Voxel and type(Voxel.NewGrid) == "function" and type(Voxel.Build) == "function" then
		local ok, built = pcall(function()
			local g = Voxel.NewGrid(24)
			-- head: a round cone pointing down with a lighter lip at its base
			Voxel.Shape(g, { Kind = "Cone", A = { 0, 9, 0 }, B = { 0, -0.5, 0 }, Radius = 6.4, Key = "Gold" })
			Voxel.Shape(g, { Kind = "Torus", Center = { 0, 9.2, 0 }, Radius = 5.8, Thickness = 0.8, Key = "Rim" })
			-- shaft: a rounded column with a soft dome on top
			Voxel.Shape(g, { Kind = "RoundBox", Center = { 0, 14.5, 0 }, Size = { 5, 11, 5 }, Round = 1.6, Key = "Gold" })
			Voxel.Shape(g, { Kind = "Ellipsoid", Center = { 0, 19.5, 0 }, Radius = { 2.4, 1.2, 2.4 }, Key = "Rim" })
			-- glints on the front-left edge
			Voxel.Shape(g, { Kind = "Box", Center = { -1, 14, -2 }, Size = { 1, 8, 1 }, Key = "Shine", Op = "Paint" })
			Voxel.Shape(g, { Kind = "Box", Center = { -2, 6.5, -4 }, Size = { 1, 3, 3 }, Key = "Shine", Op = "Paint" })
			Voxel.Shade(g, { Skip = { Shine = true }, DarkAt = -0.7, LightAt = 0.5, Noise = 0.03, Seed = 11 })
			return Voxel.Build(g, {
				VoxelSize = K.VOXEL,
				Palette = {
					Gold = C.Arrow,
					Gold_Light = C.ArrowLight,
					Gold_Dark = C.ArrowDark,
					Rim = rgb(255, 232, 150),
					Rim_Light = rgb(255, 244, 196),
					Rim_Dark = rgb(222, 170, 70),
					Shine = C.ArrowShine,
				},
				Center = true,
				Name = "GuideArrow",
				MaxParts = 110,
				CastShadow = false,
			})
		end)
		if ok and typeof(built) == "Instance" then
			model = built
		else
			warnOnce("arrow", "voxel arrow failed: " .. tostring(built))
		end
	end
	if not model then
		model = make("Model", "GuideArrow", nil, nil)
		-- a stepped head (tip at the bottom) under a block shaft
		local widths = { 0.8, 1.8, 3.0, 4.2 }
		for i, w in ipairs(widths) do
			make("Part", "Head" .. i, {
				Size = Vector3.new(w, 1, w),
				Color = (i % 2 == 0) and C.ArrowDark or C.Arrow,
				Material = Enum.Material.SmoothPlastic,
				CFrame = CFrame.new(0, i - 4.5, 0),
			}, model)
		end
		make("Part", "Shaft", {
			Size = Vector3.new(1.8, 4, 1.8),
			Color = C.ArrowLight,
			Material = Enum.Material.SmoothPlastic,
			CFrame = CFrame.new(0, 2.5, 0),
		}, model)
	end
	local parts, offsets = {}, {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			finishArrowPart(d)
			table.insert(parts, d)
			table.insert(offsets, d.CFrame)
		end
	end
	local glowPart = parts[1]
	if glowPart then
		make("PointLight", "Glow", { Color = C.ArrowLight, Brightness = 1.4, Range = 12, Shadows = false }, glowPart)
	end
	return model, parts, offsets
end

local function buildWorldGuide()
	W.built = true
	local folder = make("Folder", "TutorialGuide", nil, nil)
	W.folder = folder
	local model, parts, offsets = buildArrowModel()
	model.Parent = folder
	W.arrowParts, W.arrowOffsets = parts, offsets

	W.sparkles = {}
	for i = 1, K.SPARKLES do
		local bit = make("Part", "Sparkle" .. i, {
			Size = Vector3.new(0.6, 0.6, 0.6),
			Color = (i % 2 == 0) and C.ArrowLight or C.ArrowShine,
			Material = Enum.Material.Neon,
			Transparency = 0.1,
		}, folder)
		finishArrowPart(bit)
		W.sparkles[i] = bit
	end

	-- the dotted trail: Beam from the player's root to an anchor near the target
	local trailEnd = make("Part", "TrailEnd", { Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1 }, folder)
	finishArrowPart(trailEnd)
	W.trailEnd = trailEnd
	W.a1 = make("Attachment", "A1", nil, trailEnd)
	local beam = make("Beam", "GuideTrail", {
		Attachment1 = W.a1,
		Texture = SPARKLE_TEXTURE,
		TextureMode = Enum.TextureMode.Wrap,
		TextureLength = 2.6,
		TextureSpeed = 1.1,
		Width0 = 1.5,
		Width1 = 1.5,
		FaceCamera = true,
		LightEmission = 0.8,
		LightInfluence = 0,
		Segments = 10,
		Color = ColorSequence.new(C.ArrowLight, C.ArrowShine),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(0.7, 0.25),
			NumberSequenceKeypoint.new(1, 0.85),
		}),
	}, trailEnd)
	W.beam = beam

	-- floating sign with the target's name and the distance
	local anchor = make("Part", "SignAnchor", { Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1 }, folder)
	finishArrowPart(anchor)
	W.labelAnchor = anchor
	local k = Theme.ScreenFactor()
	local signGui = make("BillboardGui", "GuideSign", {
		Size = UDim2.fromOffset(math.floor(230 * k), math.floor(66 * k)),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 4000,
		ClipsDescendants = false,
	}, anchor)
	W.labelGui = signGui
	local card = box("Card", {
		BackgroundTransparency = 0.06,
		BackgroundColor3 = C.Navy,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
	}, signGui)
	corner(card, 12)
	stroke(card, C.Gold, 2, 0)
	W.signName = label(card, "Name", "", "Heading", Theme.ScaledSize(20), C.Gold, {
		Position = UDim2.fromScale(0.04, 0.06),
		Size = UDim2.fromScale(0.92, 0.5),
		TextScaled = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	W.signDistance = label(card, "Distance", "", "Label", Theme.ScaledSize(17), C.White, {
		Position = UDim2.fromScale(0.04, 0.54),
		Size = UDim2.fromScale(0.92, 0.4),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
end

local function setWorldActive(on)
	if not W.built then
		return
	end
	if on == W.active then
		return
	end
	W.active = on
	if on then
		W.folder.Parent = clientFx()
	else
		W.folder.Parent = nil
		W.distance = nil
	end
end

local function ensureTrailAttachment()
	local root = rootPart()
	if not root or not W.beam then
		return
	end
	local a0 = root:FindFirstChild("TutorialTrail")
	if not (a0 and a0:IsA("Attachment")) then
		a0 = make("Attachment", "TutorialTrail", { Position = Vector3.new(0, -2.2, 0) }, root)
	end
	if W.beam.Attachment0 ~= a0 then
		W.beam.Attachment0 = a0
	end
end

-- Bounding box of a Model / BasePart / Folder (cf, size) or nil.
local function boundsOf(inst)
	if inst:IsA("Model") then
		local ok, cf, size = pcall(function()
			return inst:GetBoundingBox()
		end)
		if ok and cf and size then
			return cf, size
		end
		return nil
	end
	if inst:IsA("BasePart") then
		return inst.CFrame, inst.Size
	end
	local lo, hi = nil, nil
	local n = 0
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			n = n + 1
			if n > 4000 then
				break
			end
			local p, s = d.Position, d.Size * 0.5
			local a, b = p - s, p + s
			if lo then
				lo = Vector3.new(math.min(lo.X, a.X), math.min(lo.Y, a.Y), math.min(lo.Z, a.Z))
				hi = Vector3.new(math.max(hi.X, b.X), math.max(hi.Y, b.Y), math.max(hi.Z, b.Z))
			else
				lo, hi = a, b
			end
		end
	end
	if not lo then
		return nil
	end
	return CFrame.new((lo + hi) * 0.5), hi - lo
end

local function findSpotFolder(lobby, index)
	if not lobby or type(index) ~= "number" then
		return nil
	end
	local named = lobby:FindFirstChild(string.format("Spot_%02d", index), true)
	if named and named:GetAttribute("SpotIndex") == index then
		return named
	end
	for _, d in ipairs(lobby:GetDescendants()) do
		if (d:IsA("Folder") or d:IsA("Model")) and d:GetAttribute("SpotIndex") == index then
			return d
		end
	end
	return nil
end

-- Where the guide points: { Ground = Vector3, ArrowAt = Vector3, Radius, Name } or nil.
local function resolveTarget(target)
	local lobby = Workspace:FindFirstChild("NimbusLobby")
	local kind = target.Kind
	local name = target.Label
	local server = typeof(target.Position) == "Vector3" and target.Position or nil
	local ground, arrowAt, radius = nil, nil, 6
	local model = nil
	if kind == "Spot" then
		radius = 9
		name = name or "Your Home"
		local index = target.SpotIndex
		if type(index) ~= "number" then
			index = LocalPlayer:GetAttribute(Config.Attr.SpotIndex)
		end
		ground = server
		if not ground then
			local folder = findSpotFolder(lobby, index)
			local plot = folder and folder:FindFirstChild("Plot")
			if plot and plot:IsA("Model") then
				local okPivot, pivot = pcall(function()
					return plot:GetPivot()
				end)
				if okPivot and pivot then
					ground = pivot.Position
				end
			elseif folder then
				local cf, size = boundsOf(folder)
				if cf then
					ground = cf.Position - Vector3.new(0, size.Y * 0.5, 0)
				end
			end
		end
		if ground then
			arrowAt = ground + Vector3.new(0, 6, 0)
		end
	else
		local id = target.Id
		if kind == "Portal" then
			radius = 7
			id = id or "Easy"
			model = lobby and lobby:FindFirstChild("Portal_" .. tostring(id), true)
			if not name then
				local diff = Config.GetDifficulty and Config.GetDifficulty(id)
				name = (diff and diff.DisplayName or tostring(id)) .. " Portal"
			end
		else
			radius = 5
			id = id or firstRouletteId()
			model = lobby and lobby:FindFirstChild("Roulette_" .. tostring(id), true)
			if not name then
				name = kind == "Shop" and "Cloud Shop" or (tostring(id) .. " Roulette")
			end
		end
		if model then
			local cf, size = boundsOf(model)
			if cf then
				local c = cf.Position
				arrowAt = Vector3.new(c.X, c.Y + size.Y * 0.5, c.Z)
				ground = server or Vector3.new(c.X, c.Y - size.Y * 0.5, c.Z)
			end
		end
		if not ground and server then
			ground = server
			arrowAt = server + Vector3.new(0, 8, 0)
		end
	end
	if not ground or not arrowAt then
		return nil
	end
	return { Ground = ground, ArrowAt = arrowAt, Radius = radius, Name = name or "" }
end

local function targetKey(target)
	local p = typeof(target.Position) == "Vector3" and target.Position or Vector3.new()
	return table.concat({
		tostring(target.Kind),
		tostring(target.Id),
		tostring(target.SpotIndex),
		string.format("%.0f,%.0f,%.0f", p.X, p.Y, p.Z),
	}, "|")
end

local function updateWorldGuide(dt, t)
	local st = S.state
	local target = st and st.Target
	local want = st and not st.Done and not S.finale and S.shown and target and WORLD_KINDS[target.Kind] and not inMatch()
	if not want then
		setWorldActive(false)
		return
	end
	if not W.built then
		local ok = safe("world guide", buildWorldGuide)
		if not ok then
			return
		end
	end
	local key = targetKey(target)
	W.resolveTimer = W.resolveTimer - dt
	if key ~= W.key or (not W.resolved and W.resolveTimer <= 0) then
		W.key = key
		W.resolveTimer = K.RESOLVE_RETRY
		local ok, resolved = pcall(resolveTarget, target)
		W.resolved = ok and resolved or nil
		if W.resolved then
			W.signName.Text = W.resolved.Name
		end
	end
	local goal = W.resolved
	if not goal then
		setWorldActive(false)
		return
	end
	setWorldActive(true)

	-- arrow: bob + spin above the target
	local bob = math.sin(t * 3.1) * K.BOB
	local top = goal.ArrowAt + Vector3.new(0, K.ARROW_LIFT + bob, 0)
	local cf = CFrame.new(top) * CFrame.Angles(0, t * K.SPIN, 0)
	local parts, offsets = W.arrowParts, W.arrowOffsets
	for i = 1, #parts do
		parts[i].CFrame = cf * offsets[i]
	end
	W.labelAnchor.CFrame = CFrame.new(top + Vector3.new(0, 6.2, 0))

	-- sparkle ring on the ground
	local n = #W.sparkles
	for i = 1, n do
		local a = t * 0.7 + i * (6.2832 / n)
		local y = 0.9 + math.sin(t * 3 + i) * 0.35
		local p = goal.Ground + Vector3.new(math.cos(a) * goal.Radius, y, math.sin(a) * goal.Radius)
		W.sparkles[i].CFrame = CFrame.new(p) * CFrame.Angles(t * 1.3 + i, t * 0.9, 0)
	end

	-- dotted trail from the player toward the target (capped, fading out)
	local root = rootPart()
	W.labelTimer = W.labelTimer - dt
	if root then
		local from = root.Position
		local flat = Vector3.new(goal.Ground.X - from.X, 0, goal.Ground.Z - from.Z)
		local dist = flat.Magnitude
		W.distance = dist
		local endPos = goal.Ground + Vector3.new(0, 1, 0)
		if dist > K.TRAIL_MAX then
			endPos = Vector3.new(from.X, from.Y - 2, from.Z) + flat.Unit * K.TRAIL_MAX
		end
		W.trailEnd.CFrame = CFrame.new(endPos)
		W.beam.Enabled = dist > K.TRAIL_HIDE
		if W.labelTimer <= 0 then
			W.labelTimer = 0.25
			ensureTrailAttachment()
			if dist <= K.TRAIL_HIDE then
				W.signDistance.Text = "You're here!"
			else
				W.signDistance.Text = math.floor(dist + 0.5) .. " studs away"
			end
		end
	else
		W.beam.Enabled = false
		W.distance = nil
	end
end

----------------------------------------------------------------------
-- State handling
----------------------------------------------------------------------
local function sanitize(payload)
	local st = {
		Step = math.max(1, math.floor(tonumber(payload.Step) or 1)),
		Total = math.max(1, math.floor(tonumber(payload.Total) or 1)),
		Id = type(payload.Id) == "string" and payload.Id or "",
		Title = type(payload.Title) == "string" and payload.Title or "",
		Text = type(payload.Text) == "string" and payload.Text or "",
		CompleteOn = type(payload.CompleteOn) == "string" and payload.CompleteOn or nil,
		Hint = type(payload.Hint) == "string" and payload.Hint or nil,
		Button = type(payload.Button) == "string" and payload.Button or nil,
		Done = payload.Done == true,
		Completed = payload.Completed == true,
		Skipped = payload.Skipped == true,
		Reward = tonumber(payload.Reward) or 0,
		Target = nil,
	}
	if st.Step > st.Total then
		st.Total = st.Step
	end
	if type(payload.Target) == "table" and type(payload.Target.Kind) == "string" then
		local t = payload.Target
		st.Target = {
			Kind = t.Kind,
			Id = (type(t.Id) == "string") and t.Id or nil,
			Label = (type(t.Label) == "string") and t.Label or nil,
			Position = (typeof(t.Position) == "Vector3") and t.Position or nil,
			SpotIndex = (type(t.SpotIndex) == "number") and t.SpotIndex or nil,
		}
	end
	-- older servers: fill in what the shared step list knows
	local Steps = mod("TutorialSteps")
	local index = Steps and type(Steps.IndexOf) == "table" and Steps.IndexOf[st.Id]
	local def = index and Steps.Steps[index]
	if type(def) == "table" then
		st.CompleteOn = st.CompleteOn or def.CompleteOn
		st.Hint = st.Hint or def.Hint
		st.Button = st.Button or def.Button
		if st.Title == "" and type(def.Title) == "string" then
			st.Title = def.Title
		end
	end
	st.CompleteOn = st.CompleteOn or "Next"
	return st
end

local function ensureLoop()
	if R.loop then
		return
	end
	R.loop = RunService.RenderStepped:Connect(function(dt)
		TutorialController.Step(dt)
	end)
end

local function applyState(payload)
	if type(payload) ~= "table" or not UI.Root then
		return
	end
	local prev = S.state
	local st = sanitize(payload)
	S.state = st
	if st.Done then
		if st.Completed and prev and not prev.Done and not S.finale then
			-- just finished: a last word from Nimbus, a big burst, then the card leaves
			S.finaleUntil = S.clock + K.FINALE_SECONDS
			renderFinale(st.Reward)
			if not S.shown then
				setPanelShown(true)
			end
			celebrate(true)
		elseif not S.finale then
			setPanelShown(false)
		end
		ensureLoop()
		return
	end
	local changed = not prev or prev.Done or prev.Id ~= st.Id or prev.Step ~= st.Step or prev.Text ~= st.Text
	if changed then
		local advanced = prev ~= nil and not prev.Done and st.Step > prev.Step
		if S.manual == "collapsed" then
			S.manual = nil -- new words from Nimbus unfold the card again (an expanded card stays expanded)
		end
		renderStep()
		if advanced then
			celebrate(false)
		end
		if R.checkOpenWindows then
			task.defer(R.checkOpenWindows)
		end
	else
		UI.Hint.Text = hintText()
	end
	if not prev then
		S.showAfter = S.clock + K.FIRST_SHOW_DELAY
	end
	W.key = nil -- re-resolve the world target (the position may have arrived)
	M.findTimer = 0
	ensureLoop()
end

-- One frame of every tutorial visual (RenderStepped). Public so tests can drive it.
function TutorialController.Step(dt)
	dt = math.min(tonumber(dt) or 0, 0.25)
	S.clock = S.clock + dt
	local t = S.clock

	S.layoutTimer = S.layoutTimer + dt
	if S.layoutTimer >= K.LAYOUT_EVERY then
		S.layoutTimer = 0
		safe("layout", layout)
	end
	if S.finale and S.clock >= (S.finaleUntil or 0) and S.shown then
		setPanelShown(false)
	end
	local wanted = panelWanted()
	if wanted ~= (S.shown == true) then
		setPanelShown(wanted)
	end
	if S.shown then
		safe("typewriter", updateTypewriter, dt)
		if not collapsed() then
			safe("portrait", updatePortrait, dt, t)
		end
		S.hintTimer = S.hintTimer - dt
		if S.hintTimer <= 0 then
			S.hintTimer = 0.25
			if UI.Hint.Visible then
				UI.Hint.Text = hintText()
			end
			if (S.nextLockUntil or 0) > 0 and os.clock() >= S.nextLockUntil then
				S.nextLockUntil = 0
				setDisabled(UI.Next, false)
			end
			if (S.skipLockUntil or 0) > 0 and os.clock() >= S.skipLockUntil then
				S.skipLockUntil = 0
				setDisabled(UI.ConfirmYes, false)
			end
			-- the current pip breathes
			local st = S.state
			local pip = st and not S.finale and UI.PipList[st.Step]
			if pip then
				pip.BackgroundTransparency = (math.sin(t * 6) + 1) * 0.2
			end
		end
		if UI.Badge.Visible then
			UI.Badge.Rotation = math.sin(t * 5) * 10
		end
	end
	safe("menu pointer", updateMenuPointer, dt, t)
	safe("world guide", updateWorldGuide, dt, t)
	safe("confetti", updateConfetti, dt)

	-- nothing left to show: stop the loop until the next state
	local st = S.state
	if st and st.Done and not S.shown and Fx.live <= 0 and not W.active and R.loop then
		R.loop:Disconnect()
		R.loop = nil
		hidePointer()
	end
end

function TutorialController.GetState()
	return S.state
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
-- { module, signal, fixed window id (nil: the signal passes the window id) }
local WINDOW_SIGNALS = {
	{ "MenuController", "WindowOpened", nil },
	{ "IndexController", "WindowOpened", nil },
	{ "IndexController", "Opened", "Index" },
}

local function hookWindowSignals()
	for _, spec in ipairs(WINDOW_SIGNALS) do
		local key = spec[1] .. "." .. spec[2]
		if not R.hooked[key] then
			local m = mod(spec[1])
			local signal = m and m[spec[2]]
			if type(signal) == "table" and type(signal.Connect) == "function" then
				R.hooked[key] = true
				local fixed = spec[3]
				signal:Connect(function(windowId)
					onWindowOpened(fixed or windowId)
				end)
			end
		end
	end
	local indexHooked = R.hooked["IndexController.Opened"] or R.hooked["IndexController.WindowOpened"] or not mod("IndexController")
	return R.hooked["MenuController.WindowOpened"] == true and indexHooked == true
end

-- A window the step asks for may already be open when the step begins.
local function checkOpenWindows()
	local st = S.state
	if st and not st.Done and st.CompleteOn == "IndexOpened" then
		local IndexController = mod("IndexController")
		if IndexController and type(IndexController.IsOpen) == "function" then
			local ok, open = pcall(IndexController.IsOpen)
			if ok and open == true then
				onWindowOpened("Index")
			end
		end
	end
end

function TutorialController.Init()
	if R.initialized then
		return
	end
	R.initialized = true
	R.checkOpenWindows = function()
		safe("open windows", checkOpenWindows)
	end
	if not LocalPlayer then
		return
	end
	local okBuild, err = pcall(function()
		buildPanel()
		buildPointer()
	end)
	if not okBuild then
		warn("[TutorialController] could not build the panel: " .. tostring(err))
		return
	end
	safe("layout", layout)

	-- screen changes re-flow the panel right away
	local function watchCamera()
		local camera = Workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				safe("layout", layout)
			end)
		end
	end
	watchCamera()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	LocalPlayer:GetAttributeChangedSignal(Config.Attr.InMatch):Connect(function()
		M.findTimer = 0
		W.key = nil
	end)

	task.spawn(function()
		R.event = getRemote("TutorialEvent")
		local stateRemote = getRemote("TutorialState")
		if stateRemote then
			stateRemote.OnClientEvent:Connect(function(payload)
				safe("state", applyState, payload)
			end)
		else
			warnOnce("remote", "TutorialState remote missing: tutorial panel disabled")
			return
		end
		local openPanel = getRemote("OpenPanel")
		if openPanel then
			openPanel.OnClientEvent:Connect(function(panelId)
				onWindowOpened(panelId)
			end)
		end
		-- ask for the state (the join-time push may have arrived before we listened)
		fireEvent("Sync")
		for _, pause in ipairs({ 2, 4, 8, 15 }) do
			task.wait(pause)
			if S.state then
				break
			end
			R.last.Sync = nil
			fireEvent("Sync")
		end
	end)

	-- the portrait model (first sculpt can take a moment) and the window signals of the menu
	task.defer(function()
		safe("portrait", setupPortraitModel)
	end)
	task.spawn(function()
		for _ = 1, 30 do
			local ok, done = pcall(hookWindowSignals)
			if ok and done then
				break
			end
			task.wait(2)
		end
	end)
end

return TutorialController
