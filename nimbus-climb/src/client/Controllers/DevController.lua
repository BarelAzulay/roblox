-- DevController (client): the owner-only DEV button and its "Developer tools" side panel (Config.Dev; the server
-- half is server/Services/DevService.lua).
--
--   DevController.Init()
--   Extras (tests): DevController.Open(), DevController.Close(), DevController.IsOpen(), DevController.Relayout()
--
-- Everything here only exists while the LocalPlayer has the attribute NC_Dev = true (DevService sets it for the
-- game's owner, the Config.Dev.Admins and everyone testing in Studio). The attribute is watched; it is only a hint:
-- the server checks every command again.
--
-- ScreenGui "NimbusDev" (display order 15, IgnoreGuiInset = false), built the first time NC_Dev turns true:
--   * DevTile: a chunky cloud tile in the menu tiles' style (glossy face, thick navy outline, big "DEV") with the
--     TextButton "DevButton", docked to the RIGHT edge. Its spot is MEASURED, never guessed: the lowest free place
--     on the right edge that touches none of the menu column, the HUD blocks (NimbusHud panels + its published
--     TopRight geometry), the hotbar, the tutorial panel, the touch RUN / DASH buttons and Roblox's jump button,
--     and stays out of the middle of the screen. On a PC that is the bottom-right corner; on phones and tablets it
--     sits just above the thumb buttons. Re-checked twice a second and on every screen size change.
--   * DevPanel: a compact CloudUI panel docked to the right edge, never centred, titled "Developer tools":
--     "Give all pets", "+1M tokens" (Config.Dev.GrantTokens through Theme.ShortNumber), "Restart tutorial",
--     "Skip tutorial", "Reset my data" (the first tap turns it into "Are you sure?", a second tap within 4 s
--     sends it) and the note "Only you can see this". It takes the biggest free stretch of the right edge; when
--     that is short (a phone) the buttons scroll instead of shrinking the text. The tile hides while it is open.
-- Input: mouse, touch and gamepad. Both are Selectable TextButtons (Activated covers click, tap and gamepad A);
-- opening the panel with a gamepad selects its first button; B (ContextActionService, only while open), Esc, the
-- red X and the tile close it.
-- Readability rule: designed in 1080p pixels under one UIScale of the screen factor clamp(viewportY / 1080,
-- 0.8, 1.25): buttons 22 px, title 28 px, note 18 px -> never below 14 px on a phone.
-- Remote out: DevCommand(command, arg). Plain Lua 5.1-compatible syntax only. Fonts only via Theme roles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))

local Client = script.Parent.Parent
local CloudUI = require(Client:WaitForChild("UI"):WaitForChild("CloudUI"))

local DevController = {}

----------------------------------------------------------------------
-- Tunables (design pixels of a 1080p screen unless noted)
----------------------------------------------------------------------
local K = {
	ATTR = "NC_Dev",
	GUI_NAME = "NimbusDev",
	ORDER = 15, -- above the HUD (10), hotbar (11) and tutorial (12); below the menu windows (20) and toasts (30)
	EDGE = 12, -- KEEP IN SYNC with HudController.lua: EDGE and TOUCH_EDGE (screen px)
	TOUCH_EDGE = 20,
	GAP = 8, -- screen px kept free around every neighbour
	CENTRE_TOL = 0.145, -- the middle of the screen: |dx| < 14.5% of the width and |dy| < 14.5% of the height
	SCAN_STEP = 4, -- screen px between two candidate spots of the tile
	TILE = 84, -- same size as a menu tile
	TILE_TEXT = 30,
	PANEL_W = 340,
	TITLE_TEXT = 28,
	BUTTON_H = 50,
	BUTTON_TEXT = 22,
	NOTE_TEXT = 18,
	NOTE_H = 26,
	LIST_PAD = 10,
	LIST_GAP = 8,
	BUMPS = 28, -- room the panel's cloud bumps need above its top edge
	MIN_PANEL_H = 230, -- a free stretch shorter than this is not used (the panel may then cover thumb buttons)
	MIN_SCALE = 0.5, -- only for absurdly small windows
	POLL = 0.5, -- seconds between two layout checks
	CONFIRM_SECONDS = 4,
	SEND_GAP = 0.35, -- seconds between two commands sent from this panel
	BACK_ACTION = "NimbusDevBack",
}

local BUTTONS = Theme.Buttons or {}
local Colors = Theme.Colors
local WHITE = Colors.White
local NAVY = Colors.Navy or Colors.Ink
local INK = Colors.TextStroke or Colors.Ink
local DEV_COLOR = Theme.Mix(Colors.Storm, BUTTONS.Blue or Color3.fromRGB(90, 158, 234), 0.3) -- slate blue

local LocalPlayer = nil
local initialized = false
local enabled = false
local panelOpen = false
local pollSerial = 0
local lastSend = -math.huge
local warned = {}

local UI = {} -- Gui, Tile, TileScale, TileButton, TileFx, Panel, PanelRoot, PanelScale, List, Buttons = {}, ResetButton
local Reset = { Until = 0, Serial = 0 }
local Back = { Bound = false }
local applied = {} -- last values written by relayout (only changes are written)

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function warnOnce(key, err)
	if not warned[key] then
		warned[key] = true
		warn("[DevController] " .. tostring(key) .. ": " .. tostring(err))
	end
end

local function guard(key, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warnOnce(key, err)
	end
	return ok
end

local function devConfig()
	if type(Config.Dev) == "table" then
		return Config.Dev
	end
	return {}
end

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

local function topInset()
	local inset = 0
	pcall(function()
		inset = GuiService:GetGuiInset().Y
	end)
	return inset
end

-- The area GUIs with IgnoreGuiInset = false are laid out in (below the top bar).
local function guiAreaSize()
	local size = UI.Gui and UI.Gui.AbsoluteSize
	if size and size.X >= 2 and size.Y >= 2 then
		return size
	end
	local vp = viewportSize()
	return Vector2.new(vp.X, math.max(2, vp.Y - topInset()))
end

local function usingGamepad()
	local ok, kind = pcall(function()
		return UserInputService:GetLastInputType()
	end)
	return ok and kind ~= nil and string.find(tostring(kind), "Gamepad", 1, true) ~= nil
end

local function corner(parent, radius)
	return Util.Create("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

local function stroke(parent, color, thickness)
	return Util.Create("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

local function plainFrame(parent, name, props)
	local frame = Util.Create("Frame", { Name = name, BackgroundTransparency = 1, BorderSizePixel = 0 })
	for key, value in pairs(props or {}) do
		frame[key] = value
	end
	frame.Parent = parent
	return frame
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
local function devRemote()
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = folder and folder:FindFirstChild("DevCommand")
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end
	return nil
end

-- Fires DevCommand(command, arg). Returns true when it was sent (a quick double tap is dropped).
local function send(command, arg)
	local now = os.clock()
	if now - lastSend < K.SEND_GAP then
		return false
	end
	local remote = devRemote()
	if not remote then
		warnOnce("remote", "the DevCommand remote is missing")
		return false
	end
	lastSend = now
	remote:FireServer(command, arg)
	return true
end

local function grantTokens()
	local amount = tonumber(devConfig().GrantTokens)
	if not amount or amount ~= amount or amount < 1 then
		amount = 1000000
	end
	return math.floor(amount)
end

local function tokensLabel()
	local amount = grantTokens()
	local text = nil
	if type(Theme.ShortNumber) == "function" then
		local ok, short = pcall(Theme.ShortNumber, amount)
		if ok and type(short) == "string" then
			text = short
		end
	end
	return "+" .. (text or Util.Commas(amount)) .. " tokens"
end

local function disarmReset()
	Reset.Until = 0
	Reset.Serial = Reset.Serial + 1
	if UI.ResetButton then
		UI.ResetButton.Text = "Reset my data"
	end
end

-- First tap arms the button ("Are you sure?"), a second tap within CONFIRM_SECONDS sends the reset.
local function onResetPressed()
	local now = os.clock()
	if Reset.Until > now then
		if send("reset") then
			disarmReset()
		end
		return
	end
	Reset.Until = now + K.CONFIRM_SECONDS
	Reset.Serial = Reset.Serial + 1
	local serial = Reset.Serial
	UI.ResetButton.Text = "Are you sure?"
	task.delay(K.CONFIRM_SECONDS, function()
		if Reset.Serial == serial then
			disarmReset()
		end
	end)
end

----------------------------------------------------------------------
-- Building
----------------------------------------------------------------------
-- Glossy chunky face (same recipe as the menu tiles): light top, the colour, then a darker lip at the bottom.
local function tileSequence(c)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Theme.Lighten(c, 0.34)),
		ColorSequenceKeypoint.new(0.5, Theme.Lighten(c, 0.05)),
		ColorSequenceKeypoint.new(0.78, Theme.Darken(c, 0.08)),
		ColorSequenceKeypoint.new(0.8, Theme.Darken(c, 0.32)),
		ColorSequenceKeypoint.new(1, Theme.Darken(c, 0.4)),
	})
end

local function buildTile(gui)
	local tile = plainFrame(gui, "DevTile", {
		AnchorPoint = Vector2.new(1, 1),
		Size = UDim2.fromOffset(K.TILE, K.TILE),
		Position = UDim2.new(1, -K.EDGE, 1, -K.EDGE),
		ZIndex = 2,
	})
	UI.Tile = tile
	UI.TileScale = Util.Create("UIScale", { Name = "ReadScale", Scale = 1, Parent = tile })

	local button = Util.Create("TextButton", {
		Name = "DevButton",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = "",
		BackgroundColor3 = WHITE,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Selectable = true,
		ZIndex = 3,
		Parent = tile,
	})
	UI.TileButton = button
	corner(button, 18)
	local outline = stroke(button, NAVY, 4)
	local face = Util.Create("UIGradient", { Rotation = 90, Color = tileSequence(DEV_COLOR), Parent = button })
	local gloss = plainFrame(button, "Gloss", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.72,
		Position = UDim2.fromOffset(8, 6),
		Size = UDim2.new(1, -16, 0.3, 0),
		ZIndex = 3,
	})
	corner(gloss, 10)
	-- two tiny pixel glints, like the menu tiles (a nod to the voxel world)
	for i, glint in ipairs({ { 10, 9, 6 }, { 18, 9, 4 } }) do
		plainFrame(button, "Glint" .. i, {
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0.15,
			Position = UDim2.fromOffset(glint[1], glint[2]),
			Size = UDim2.fromOffset(glint[3], glint[3]),
			ZIndex = 4,
		})
	end
	local label = Theme.Label("DEV", "Title", {
		Size = K.TILE_TEXT,
		Stroke = 0.1,
		StrokeColor = INK,
		Outline = 2.5,
		OutlineColor = INK,
		Props = {
			Name = "Label",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.45),
			Size = UDim2.new(1, -8, 0, 36),
			ZIndex = 5,
		},
	})
	label.Parent = button

	-- hover / press feedback (same feel as the menu tiles)
	local fx = Util.Create("UIScale", { Name = "FxScale", Scale = 1, Parent = button })
	local state = { Hovering = false, Pressing = false }
	local function paint()
		local color = DEV_COLOR
		local scale = 1
		if state.Pressing then
			color = Theme.Darken(DEV_COLOR, 0.08)
			scale = 0.93
		elseif state.Hovering then
			color = Theme.Lighten(DEV_COLOR, 0.1)
			scale = 1.07
		end
		face.Color = tileSequence(color)
		outline.Color = NAVY
		Util.Tween(fx, 0.1, { Scale = scale })
	end
	button.MouseEnter:Connect(function()
		state.Hovering = true
		paint()
	end)
	button.MouseLeave:Connect(function()
		state.Hovering, state.Pressing = false, false
		paint()
	end)
	button.MouseButton1Down:Connect(function()
		state.Pressing = true
		paint()
	end)
	button.MouseButton1Up:Connect(function()
		state.Pressing = false
		paint()
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			state.Hovering, state.Pressing = false, false
			paint()
		end
	end)
	button.Activated:Connect(function()
		guard("open", DevController.Open)
	end)
	CloudUI.Tooltip(button, function()
		return "Developer tools (only you)"
	end)
end

-- Design height of the whole panel when nothing is cut off.
local function fullPanelHeight(count)
	local top, _, bottom = CloudUI.ContentInset(true)
	local list = 2 * K.LIST_PAD + count * (K.BUTTON_H + K.LIST_GAP) + K.NOTE_H
	return top + list + bottom
end

local function buildPanel(gui)
	local specs = {
		{ Id = "allpets", Text = "Give all pets", Style = "Green" },
		{ Id = "tokens", Text = tokensLabel(), Style = "Gold" },
		{ Id = "tutorial", Text = "Restart tutorial", Style = "Blue" },
		{ Id = "skiptutorial", Text = "Skip tutorial", Style = "Pink" },
		{ Id = "reset", Text = "Reset my data", Style = "Red" },
	}
	UI.FullHeight = fullPanelHeight(#specs)
	local panel = CloudUI.Panel({
		Name = "DevPanel",
		Title = "Developer tools",
		TitleSize = K.TITLE_TEXT,
		Closable = true,
		OnClose = function()
			DevController.Close()
		end,
		Accent = DEV_COLOR,
		AnchorPoint = Vector2.new(1, 1),
		Size = UDim2.fromOffset(K.PANEL_W, UI.FullHeight),
		Position = UDim2.new(1, -K.EDGE, 1, -K.EDGE),
		Parent = gui,
	})
	UI.Panel = panel
	UI.PanelRoot = panel.Root
	UI.PanelRoot.Visible = false
	UI.PanelScale = Util.Create("UIScale", { Name = "ReadScale", Scale = 1, Parent = panel.Root })

	local list = Util.Create("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = WHITE,
		ZIndex = 5,
		Parent = panel.Content,
	})
	UI.List = list
	Util.Create("UIPadding", {
		PaddingTop = UDim.new(0, K.LIST_PAD),
		PaddingBottom = UDim.new(0, K.LIST_PAD),
		PaddingLeft = UDim.new(0, K.LIST_PAD),
		PaddingRight = UDim.new(0, K.LIST_PAD + 4),
		Parent = list,
	})
	Util.Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, K.LIST_GAP),
		Parent = list,
	})

	UI.Buttons = {}
	for index, spec in ipairs(specs) do
		local id = spec.Id
		local callback
		if id == "reset" then
			callback = function()
				guard("reset", onResetPressed)
			end
		elseif id == "tokens" then
			callback = function()
				send("tokens", grantTokens())
			end
		else
			callback = function()
				send(id)
			end
		end
		local button = CloudUI.Button({
			Name = "Dev_" .. id,
			Text = spec.Text,
			Style = spec.Style,
			Size = UDim2.new(1, 0, 0, K.BUTTON_H),
			TextSize = K.BUTTON_TEXT,
			LayoutOrder = index,
			ZIndex = 6,
			Callback = callback,
			Parent = list,
		})
		button.Selectable = true
		UI.Buttons[id] = button
		UI.Buttons[index] = button
		if id == "reset" then
			UI.ResetButton = button
		end
	end
	local note = Theme.Label("Only you can see this", "Label", {
		Size = K.NOTE_TEXT,
		Color = Colors.Muted or WHITE,
		Stroke = 0.3,
		Outline = 1.5,
		Props = {
			Name = "Note",
			Size = UDim2.new(1, 0, 0, K.NOTE_H),
			LayoutOrder = #specs + 1,
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = 6,
		},
	})
	note.Parent = list
end

local function build()
	if UI.Gui and UI.Gui.Parent then
		return
	end
	local gui = CloudUI.NewScreenGui(K.GUI_NAME, K.ORDER)
	gui.Enabled = false
	UI.Gui = gui
	applied = {}
	buildTile(gui)
	buildPanel(gui)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		guard("relayout", DevController.Relayout)
	end)
end

----------------------------------------------------------------------
-- Layout: measured neighbours (all rectangles in our gui-area pixels)
----------------------------------------------------------------------
local function playerGui()
	return LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

-- y offset that converts a gui's AbsolutePosition into our gui-area coordinates
local function insetShift(gui)
	if gui and gui:IsA("ScreenGui") and gui.IgnoreGuiInset then
		return -topInset()
	end
	return 0
end

local function shownIn(inst, root)
	local node = inst
	while node and node ~= root do
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		node = node.Parent
	end
	return true
end

local function addRect(list, inst, root, dy)
	if not (inst and inst:IsA("GuiObject")) then
		return
	end
	local p, s = inst.AbsolutePosition, inst.AbsoluteSize
	if s.X <= 0 or s.Y <= 0 or not shownIn(inst, root) then
		return
	end
	list[#list + 1] = { x0 = p.X, y0 = p.Y + dy, x1 = p.X + s.X, y1 = p.Y + s.Y + dy }
end

local function enabledGui(pg, name)
	local gui = pg:FindFirstChild(name)
	if gui and gui:IsA("ScreenGui") and gui.Enabled then
		return gui
	end
	return nil
end

-- Everything the DEV tile must never touch. Also returns the bottom of the HUD's top-right block (0 if none)
-- and its left edge.
local function neighbours(area)
	local out = {}
	local topRightBottom, topRightLeft = 0, area.X
	local pg = playerGui()
	if not pg then
		return out, topRightBottom, topRightLeft
	end
	local menu = enabledGui(pg, "NimbusMenu")
	if menu then
		addRect(out, menu:FindFirstChild("MenuColumn"), menu, insetShift(menu))
	end
	local hud = enabledGui(pg, "NimbusHud")
	if hud then
		local dy = insetShift(hud)
		for _, holder in ipairs(hud:GetChildren()) do
			if holder:IsA("GuiObject") and holder.Visible then
				for _, panel in ipairs(holder:GetChildren()) do
					addRect(out, panel, hud, dy)
				end
			end
		end
		local trb = tonumber(hud:GetAttribute("TopRightBottom")) or 0
		if trb > 0 then
			topRightBottom = trb
			topRightLeft = tonumber(hud:GetAttribute("TopRightLeft")) or 0
			out[#out + 1] = { x0 = topRightLeft, y0 = 0, x1 = area.X, y1 = trb }
		end
	end
	local hotbar = enabledGui(pg, "NimbusHotbar")
	if hotbar then
		addRect(out, hotbar:FindFirstChild("Hotbar"), hotbar, insetShift(hotbar))
	end
	local tutorial = enabledGui(pg, "NimbusTutorial")
	if tutorial then
		addRect(out, tutorial:FindFirstChild("TutorialPanel"), tutorial, insetShift(tutorial))
	end
	-- touch RUN / DASH (MovementController)
	local mobile = enabledGui(pg, "MobileControls")
	if mobile then
		local dy = insetShift(mobile)
		for _, d in ipairs(mobile:GetDescendants()) do
			if d:IsA("TextButton") or d:IsA("ImageButton") then
				addRect(out, d, mobile, dy)
			end
		end
	end
	-- Roblox's own jump button; when it cannot be measured, the footprint MovementController assumes
	-- (KEEP IN SYNC with MovementController.lua layoutMobileControls)
	local measured = false
	local touchGui = enabledGui(pg, "TouchGui")
	if touchGui then
		local jump = touchGui:FindFirstChild("JumpButton", true)
		if jump then
			local before = #out
			addRect(out, jump, touchGui, insetShift(touchGui))
			measured = #out > before
		end
	end
	if not measured and isTouchDevice() then
		local vp = viewportSize()
		local small = math.min(vp.X, vp.Y) <= 500
		local size = small and 70 or 120
		local bottom = small and 20 or size * 0.75
		local dy = area.Y - vp.Y -- screen -> gui area (minus the top bar)
		out[#out + 1] = {
			x0 = vp.X - (size * 1.5 + 10),
			y0 = vp.Y - bottom - size + dy,
			x1 = vp.X - (size * 0.5 + 10),
			y1 = vp.Y - bottom + dy,
		}
	end
	return out, topRightBottom, topRightLeft
end

-- The middle of the screen the game never writes into (same band as the HUD), in gui-area pixels.
local function centreBand(area)
	local vp = viewportSize()
	local inset = math.max(0, vp.Y - area.Y)
	local tol = K.CENTRE_TOL
	return {
		x0 = vp.X * (0.5 - tol),
		x1 = vp.X * (0.5 + tol),
		y0 = vp.Y * (0.5 - tol) - inset,
		y1 = vp.Y * (0.5 + tol) - inset,
	}
end

local function touches(a, b, gap)
	return a.x0 < b.x1 + gap and a.x1 > b.x0 - gap and a.y0 < b.y1 + gap and a.y1 > b.y0 - gap
end

-- Bottom-right corner (gui px) of the tile: the lowest free spot on the right edge.
local function placeTile(area, side, size, list, band)
	local right = area.X - side
	local y1 = area.Y - side
	while y1 - size >= side do
		local rect = { x0 = right - size, y0 = y1 - size, x1 = right, y1 = y1 }
		local free = not touches(rect, band, 0)
		if free then
			for _, r in ipairs(list) do
				if touches(rect, r, K.GAP) then
					free = false
					break
				end
			end
		end
		if free then
			return right, y1
		end
		y1 = y1 - K.SCAN_STEP
	end
	-- no free spot at all (a tiny window): the top-right corner
	return right, math.min(area.Y - side, side + size)
end

-- Free vertical stretches [y0, y1] of the column [x0, x1] between top and bottom.
local function freeStretches(x0, x1, top, bottom, blockers)
	local spans = {}
	for _, r in ipairs(blockers) do
		if r.x0 < x1 + K.GAP and r.x1 > x0 - K.GAP and r.y1 + K.GAP > top and r.y0 - K.GAP < bottom then
			spans[#spans + 1] = { r.y0 - K.GAP, r.y1 + K.GAP }
		end
	end
	table.sort(spans, function(a, b)
		return a[1] < b[1]
	end)
	local out = {}
	local cursor = top
	for _, span in ipairs(spans) do
		if span[1] > cursor then
			out[#out + 1] = { cursor, math.min(span[1], bottom) }
		end
		cursor = math.max(cursor, span[2])
	end
	if cursor < bottom then
		out[#out + 1] = { cursor, bottom }
	end
	return out
end

-- The tallest free stretch (the lower one on a tie); nil when none is at least minH tall.
local function bestStretch(stretches, minH)
	local best = nil
	for _, s in ipairs(stretches) do
		local h = s[2] - s[1]
		if h >= minH and (best == nil or h >= best[2] - best[1]) then
			best = s
		end
	end
	return best
end

-- Bottom-right corner, design height and scale of the open panel.
local function placePanel(area, side, factor, list, band, topRightBottom, topRightLeft)
	local scale = math.max(K.MIN_SCALE, math.min(factor, (area.X - 2 * side) / K.PANEL_W))
	local right = area.X - side
	local left = right - K.PANEL_W * scale
	local top = side
	if topRightBottom > 0 and topRightLeft < right then
		top = math.max(top, topRightBottom + K.GAP) -- the HUD's top-right block always stays visible
	end
	top = top + K.BUMPS * scale
	local bottom = area.Y - side
	local minH = math.min(K.MIN_PANEL_H * scale, bottom - top)
	local bandBlock = {}
	if left < band.x1 and right > band.x0 then
		bandBlock[1] = { x0 = left, x1 = right, y0 = band.y0 + K.GAP, y1 = band.y1 - K.GAP }
	end
	local everything = {}
	for _, r in ipairs(list) do
		everything[#everything + 1] = r
	end
	if bandBlock[1] then
		everything[#everything + 1] = bandBlock[1]
	end
	-- 1. clear of everything; 2. out of the screen middle only (may cover thumb buttons while open); 3. anywhere
	local stretch = bestStretch(freeStretches(left, right, top, bottom, everything), minH)
		or bestStretch(freeStretches(left, right, top, bottom, bandBlock), minH)
		or { top, bottom }
	local height = math.min(UI.FullHeight or 400, (stretch[2] - stretch[1]) / scale)
	return right, stretch[2], height, scale
end

local function setIfChanged(key, inst, prop, value)
	if applied[key] ~= value then
		applied[key] = value
		inst[prop] = value
	end
end

function DevController.Relayout()
	if not UI.Gui or not enabled then
		return
	end
	local area = guiAreaSize()
	local factor = Theme.ScreenFactor(viewportSize().Y)
	local side = isTouchDevice() and K.TOUCH_EDGE or K.EDGE
	local list, topRightBottom, topRightLeft = neighbours(area)
	local band = centreBand(area)
	local tx, ty = placeTile(area, side, K.TILE * factor, list, band)
	setIfChanged("tileScale", UI.TileScale, "Scale", factor)
	setIfChanged("tilePos", UI.Tile, "Position", UDim2.fromOffset(math.floor(tx + 0.5), math.floor(ty + 0.5)))
	if panelOpen then
		local px, py, height, scale = placePanel(area, side, factor, list, band, topRightBottom, topRightLeft)
		setIfChanged("panelScale", UI.PanelScale, "Scale", scale)
		setIfChanged("panelSize", UI.PanelRoot, "Size", UDim2.fromOffset(K.PANEL_W, math.floor(height)))
		setIfChanged("panelPos", UI.PanelRoot, "Position", UDim2.fromOffset(math.floor(px + 0.5), math.floor(py + 0.5)))
	end
end

----------------------------------------------------------------------
-- Open / close
----------------------------------------------------------------------
local function onBackAction(_name, inputState)
	if inputState == Enum.UserInputState.Begin and panelOpen then
		DevController.Close()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function bindBack(on)
	if on == Back.Bound then
		return
	end
	Back.Bound = on
	if on then
		guard("bind back", function()
			ContextActionService:BindActionAtPriority(K.BACK_ACTION, onBackAction, false, Enum.ContextActionPriority.High.Value + 1, Enum.KeyCode.ButtonB)
		end)
	else
		pcall(function()
			ContextActionService:UnbindAction(K.BACK_ACTION)
		end)
	end
end

local function selectionInside(root)
	local selected = GuiService.SelectedObject
	return selected ~= nil and root ~= nil and selected:IsDescendantOf(root)
end

function DevController.IsOpen()
	return panelOpen
end

function DevController.Open()
	if not enabled or not UI.PanelRoot then
		return false
	end
	if panelOpen then
		DevController.Close()
		return false
	end
	panelOpen = true
	disarmReset()
	UI.PanelRoot.Visible = true
	UI.Tile.Visible = false
	DevController.Relayout()
	bindBack(true)
	if usingGamepad() and UI.Buttons[1] then
		pcall(function()
			GuiService.SelectedObject = UI.Buttons[1]
		end)
	end
	return true
end

function DevController.Close()
	if not panelOpen then
		return
	end
	panelOpen = false
	disarmReset()
	local hadSelection = selectionInside(UI.PanelRoot)
	if UI.PanelRoot then
		UI.PanelRoot.Visible = false
	end
	if UI.Tile then
		UI.Tile.Visible = enabled
	end
	bindBack(false)
	if hadSelection then
		pcall(function()
			GuiService.SelectedObject = (enabled and usingGamepad()) and UI.TileButton or nil
		end)
	end
	DevController.Relayout()
end

----------------------------------------------------------------------
-- NC_Dev on / off
----------------------------------------------------------------------
local function startPolling()
	pollSerial = pollSerial + 1
	local serial = pollSerial
	task.spawn(function()
		while enabled and serial == pollSerial do
			guard("relayout", DevController.Relayout)
			task.wait(K.POLL)
		end
	end)
end

local function setEnabled(on)
	if on == enabled then
		return
	end
	if on then
		if not guard("build", build) then
			return
		end
		enabled = true
		UI.Gui.Enabled = true
		UI.Tile.Visible = not panelOpen
		applied = {}
		startPolling()
	else
		DevController.Close()
		enabled = false
		pollSerial = pollSerial + 1
		if UI.Gui then
			UI.Gui.Enabled = false
		end
	end
end

local function refreshFlag()
	setEnabled(LocalPlayer ~= nil and LocalPlayer:GetAttribute(K.ATTR) == true)
end

function DevController.Init()
	if initialized then
		return
	end
	initialized = true
	LocalPlayer = Players.LocalPlayer
	if not LocalPlayer then
		return
	end
	LocalPlayer:GetAttributeChangedSignal(K.ATTR):Connect(function()
		guard("NC_Dev", refreshFlag)
	end)
	UserInputService.InputBegan:Connect(function(input)
		if panelOpen and input.KeyCode == Enum.KeyCode.Escape then
			DevController.Close()
		end
	end)
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			guard("relayout", DevController.Relayout)
		end)
	end
	guard("NC_Dev", refreshFlag)
end

return DevController
