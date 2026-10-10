-- HotbarController (client, v3): four item slots at the bottom-centre of the screen.
--
--   HotbarController.Init()
--   HotbarController.UseSlot(index)      -- same as pressing key `index` (1..4)
--
-- ScreenGui "NimbusHotbar" (display order 11, IgnoreGuiInset = false). Slots 1-3 follow ItemCatalog.List
-- (Heal Cloud, Shield Bubble, Phoenix Feather); slot 4 is a locked placeholder. Keys 1-4 (also the keypad)
-- and a tap / click use the item through the UseItem remote; the server validates everything.
-- Counts come from State and re-render on State.Changed. Items only work in matches, so the whole
-- bar is dimmed in the lobby (and while downed, or when a stack is empty); a used slot flashes, pops and
-- shows a short cooldown bar.
--
-- v3 readability rule: the bar is designed in 1080p pixels (80 px slots) under ONE UIScale of the screen
-- factor clamp(viewportY / 1080, 0.8, 1.25). On touch screens it never grows past the footprint the touch
-- RUN / DASH buttons keep clear of (MovementController: 280 x 64 px at clamp(min(w/1280, h/720), 0.75, 1.2))
-- and it slides left of Roblox's jump button on narrow phones; slots stay >= 48 px (touch friendly). The
-- count / key / hint texts grow in design pixels when the bar is scaled down, so they never render below
-- 14.5 px on screen.
-- Plain Lua 5.1-compatible syntax only. All text goes through Theme roles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent.Parent
local CloudUI = require(Client:WaitForChild("UI"):WaitForChild("CloudUI"))
local State = require(Client:WaitForChild("State"))

local okItems, ItemCatalog = pcall(function()
	return require(Shared:WaitForChild("ItemCatalog", 10))
end)
if not okItems or type(ItemCatalog) ~= "table" then
	warn("[HotbarController] ItemCatalog is unavailable: " .. tostring(ItemCatalog))
	ItemCatalog = { List = {}, ById = {} }
end

local HotbarController = {}

----------------------------------------------------------------------
-- Tunables (design pixels of a 1080p screen unless noted)
----------------------------------------------------------------------
local SLOT = 80
local GAP = 10
local BOTTOM = 14 -- screen px from the bottom edge
local TOUCH_BOTTOM = 16 -- screen px on touch devices (MovementController expects 16)
local JUMP_GAP = 8 -- clear space kept between the bar and Roblox's jump button (touch devices)
local SIDE_GAP = 6 -- the bar never slides closer than this to the left screen edge
local TOUCH_MIN_PX = 48 -- smallest on-screen slot
local MIN_TEXT_PX = 14.5 -- smallest on-screen text
local COUNT_TEXT = 22 -- design px of the "x3" stack count
local KEY_TEXT = 19 -- design px of the key chip number
local HINT_TEXT = 20 -- design px of the hint above the bar
local COOLDOWN = 0.8 -- seconds between two uses of the same slot
local HINT_SECONDS = 2.4
-- The touch-control footprint MovementController keeps clear of (keep in sync with it).
local MC_W, MC_H = 280, 64

local Colors = Theme.Colors
local NAVY = Colors.Navy or Colors.Ink
local MUTED = Colors.Muted or Colors.CloudShade
local KINDS = Theme.Kinds or {}
local LOCK_GLYPH = "\240\159\148\146"

local KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.KeypadOne] = 1,
	[Enum.KeyCode.KeypadTwo] = 2,
	[Enum.KeyCode.KeypadThree] = 3,
	[Enum.KeyCode.KeypadFour] = 4,
}

----------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------
local initialized = false
local LocalPlayer = nil
local gui = nil
local holder = nil
local holderScale = nil
local slots = {} -- index -> { Slot, Def, Punch (UIScale), Bar (cooldown frame), CoolUntil, LastCount, Count, Key }
local useRemote = nil
local hint = { Frame = nil, Label = nil, Limit = nil, Token = 0 }
local touchDevice = false
local warned = {}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function warnOnce(key, err)
	if not warned[key] then
		warned[key] = true
		warn("[HotbarController] " .. tostring(key) .. ": " .. tostring(err))
	end
end

local function guiSize()
	local size = gui and gui.AbsoluteSize or Vector2.new(1280, 720)
	if size.X < 2 or size.Y < 2 then
		return Vector2.new(1280, 720)
	end
	return size
end

local function viewportSize()
	local camera = workspace.CurrentCamera
	local vp = camera and camera.ViewportSize
	if vp and vp.X > 2 and vp.Y > 2 then
		return vp
	end
	return guiSize()
end

local function inMatch()
	return LocalPlayer ~= nil and LocalPlayer:GetAttribute(Config.Attr.InMatch) == true
end

local function isDowned()
	return LocalPlayer ~= nil and LocalPlayer:GetAttribute(Config.Attr.Downed) == true
end

local function slotCount()
	return math.max(1, math.floor(tonumber(Config.Items.HotbarSlots) or 4))
end

local function barWidth()
	local count = slotCount()
	return count * SLOT + (count - 1) * GAP
end

local function getUseRemote()
	if useRemote then
		return useRemote
	end
	local ok, remote = pcall(Remotes.Get, "UseItem")
	if ok and remote then
		useRemote = remote
	end
	return useRemote
end

-- Design text size that renders at least MIN_TEXT_PX on screen under `scale`.
local function readable(designPx, scale)
	if scale <= 0 then
		return designPx
	end
	return math.max(designPx, math.ceil(MIN_TEXT_PX / scale))
end

local function applyTextSizes(scale)
	local countSize = readable(COUNT_TEXT, scale)
	local keySize = readable(KEY_TEXT, scale)
	for _, entry in ipairs(slots) do
		if entry.Count then
			entry.Count.TextSize = countSize
			entry.Count.Size = UDim2.new(0.9, 0, 0, countSize + 2)
		end
		if entry.Key then
			entry.Key.TextSize = keySize
			local chip = entry.Key.Parent
			if chip and chip:IsA("GuiObject") then
				chip.Size = UDim2.fromOffset(keySize + 9, keySize + 9)
			end
		end
	end
	if hint.Label then
		local hintSize = readable(HINT_TEXT, scale)
		hint.Label.TextSize = hintSize
		if hint.Limit then
			hint.Limit.MaxSize = Vector2.new(math.floor(hintSize * 19), 200)
		end
	end
end

local function relayout()
	if not holder then
		return
	end
	local size = guiSize()
	local vp = viewportSize()
	local width = barWidth()
	local scale = Theme.ScreenFactor(vp.Y)
	local bottom = BOTTOM
	local shift = 0
	if touchDevice then
		bottom = TOUCH_BOTTOM
		-- stay inside the footprint the touch RUN / DASH buttons keep clear of
		local mcScale = Util.Clamp(math.min(vp.X / 1280, vp.Y / 720), 0.75, 1.2)
		scale = math.min(scale, MC_W * mcScale / width, MC_H * mcScale / SLOT)
		-- Roblox's own jump button sits bottom-right: its left edge is 1.5 J + 10 px from the right screen edge
		-- (J = 70 when the smaller screen axis is <= 500 px, else 120). On a narrow phone the centred bar would
		-- touch it, so it shrinks (never below the touch minimum) and slides left just far enough.
		local jump = math.min(vp.X, vp.Y) <= 500 and 70 or 120
		local reach = size.X - (jump * 1.5 + 10) - JUMP_GAP -- right-most x the bar may reach
		scale = math.min(scale, (reach - SIDE_GAP) / width)
	end
	-- never wider than the screen, never smaller than the touch minimum
	scale = math.min(scale, (size.X - 2 * SIDE_GAP) / width)
	scale = math.max(scale, TOUCH_MIN_PX / SLOT)
	holderScale.Scale = scale
	if touchDevice then
		local jump = math.min(vp.X, vp.Y) <= 500 and 70 or 120
		local reach = size.X - (jump * 1.5 + 10) - JUMP_GAP
		local half = width * scale / 2
		shift = math.min(0, reach - half - size.X / 2)
		shift = math.min(0, math.max(shift, half + SIDE_GAP - size.X / 2))
	end
	holder.Position = UDim2.new(0.5, math.floor(shift), 1, -bottom)
	applyTextSizes(scale)
end

----------------------------------------------------------------------
-- Small hint above the bar (why a press did nothing)
----------------------------------------------------------------------
local function buildHint()
	local frame = Util.Create("Frame", {
		Name = "Hint",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -12),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = Colors.White, -- the gradient below multiplies this base colour
		BackgroundTransparency = 0.04,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 20,
		Parent = holder,
	})
	Theme.Corner(frame, UDim.new(0, 12))
	Theme.Stroke(frame, NAVY, 3, 0)
	Theme.Gradient(frame, Colors.PanelLight, Colors.Panel, 90)
	Util.Create("UIPadding", {
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		Parent = frame,
	})
	local label = Theme.Label("", "Toast", {
		Size = HINT_TEXT,
		Stroke = 0.2,
		Outline = 1.5,
		Props = {
			Name = "Text",
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, 0),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = 21,
		},
	})
	hint.Limit = Util.Create("UISizeConstraint", { MaxSize = Vector2.new(380, 200), Parent = label })
	label.Parent = frame
	hint.Frame = frame
	hint.Label = label
end

local function showHint(text, kind)
	if not hint.Frame then
		return
	end
	hint.Token = hint.Token + 1
	local mine = hint.Token
	local color = KINDS[kind or "info"] or KINDS.info or Colors.PanelLight
	hint.Label.Text = tostring(text)
	hint.Label.TextColor3 = Theme.Lighten(color, 0.55)
	hint.Frame.Visible = true
	task.delay(HINT_SECONDS, function()
		if hint.Token == mine and hint.Frame then
			hint.Frame.Visible = false
		end
	end)
end

----------------------------------------------------------------------
-- Slots
----------------------------------------------------------------------
local function itemForSlot(index)
	local list = ItemCatalog.List or {}
	return list[index]
end

local function paintSlot(entry)
	local slot = entry.Slot
	local def = entry.Def
	if not def then
		slot.SetCount(nil)
		slot.SetDimmed(true)
		return
	end
	local count = State.ItemCount(def.Id)
	slot.SetCount(count)
	-- a bigger stack than before: little celebration (not for the very first profile load)
	if State.IsLoaded == nil or State.IsLoaded() then
		if entry.LastCount ~= nil and count > entry.LastCount then
			slot.Flash()
			entry.Punch.Scale = 1.14
			Util.Tween(entry.Punch, 0.3, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end
		entry.LastCount = count
	end
	local usable = inMatch() and (not isDowned()) and count > 0
	local cooling = os.clock() < entry.CoolUntil
	slot.SetDimmed((not usable) or cooling)
end

local function refresh()
	for _, entry in ipairs(slots) do
		paintSlot(entry)
	end
end

local function startCooldown(entry)
	entry.CoolUntil = os.clock() + COOLDOWN
	entry.Bar.Visible = true
	entry.Bar.Size = UDim2.new(1, -14, 0, 6)
	Util.Tween(entry.Bar, COOLDOWN, { Size = UDim2.new(0, 0, 0, 6) }, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	paintSlot(entry)
	task.delay(COOLDOWN + 0.02, function()
		if entry.Bar and entry.Bar.Parent then
			entry.Bar.Visible = false
			paintSlot(entry)
		end
	end)
end

-- Press feedback for a slot that cannot be used right now.
local function shake(entry)
	local punch = entry.Punch
	punch.Scale = 0.88
	Util.Tween(punch, 0.25, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end

function HotbarController.UseSlot(index)
	local entry = slots[index]
	if not entry then
		return
	end
	local def = entry.Def
	if not def then
		shake(entry)
		showHint("This slot is locked. More items are coming!", "info")
		return
	end
	if not inMatch() then
		shake(entry)
		showHint("Items only work during a match.", "info")
		return
	end
	if isDowned() then
		shake(entry)
		showHint("You cannot use items while downed.", "bad")
		return
	end
	if State.ItemCount(def.Id) <= 0 then
		shake(entry)
		showHint("No " .. def.Name .. " left. Buy more in the shop!", "info")
		return
	end
	if os.clock() < entry.CoolUntil then
		return
	end
	local remote = getUseRemote()
	if not remote then
		return
	end
	local ok = pcall(function()
		remote:FireServer(def.Id)
	end)
	if not ok then
		return
	end
	entry.Slot.Flash()
	entry.Punch.Scale = 0.86
	Util.Tween(entry.Punch, 0.3, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	startCooldown(entry)
end

local function buildSlots()
	local count = slotCount()
	holder.Size = UDim2.fromOffset(barWidth(), SLOT)
	for index = 1, count do
		local def = itemForSlot(index)
		local slot = CloudUI.Slot({
			Name = "Hotbar" .. index,
			Size = UDim2.fromOffset(SLOT, SLOT),
			-- centre-anchored so the pop animation grows around the middle of the slot
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset((index - 1) * (SLOT + GAP) + SLOT / 2, SLOT / 2),
			Hotkey = tostring(index),
			Callback = function()
				HotbarController.UseSlot(index)
			end,
			Parent = holder,
		})
		if def then
			slot.SetContent({
				Glyph = def.Glyph,
				Color = def.Color,
				RarityColor = CloudUI.RarityColor(def.Rarity),
				Name = def.Name .. "  [" .. index .. "]",
				Blurb = def.Blurb,
			})
		else
			slot.SetContent({
				Glyph = LOCK_GLYPH,
				Color = MUTED,
				Name = "Locked slot",
				Blurb = "More items are coming soon.",
			})
		end

		local punch = Util.Create("UIScale", { Name = "Punch", Scale = 1, Parent = slot.Root })
		local bar = Util.Create("Frame", {
			Name = "Cooldown",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -6),
			Size = UDim2.new(1, -14, 0, 6),
			BackgroundColor3 = Colors.Gold or Colors.Token,
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 10,
			Parent = slot.Root,
		})
		Theme.Corner(bar, UDim.new(0.5, 0))
		Theme.Stroke(bar, NAVY, 1.5, 0)
		-- the kit's count / key labels, resized by relayout so they stay readable at any scale
		local countLabel = slot.Root:FindFirstChild("Count", true)
		local keyLabel = slot.Root:FindFirstChild("Key", true)
		if countLabel and not countLabel:IsA("TextLabel") then
			countLabel = nil
		end
		if keyLabel and not keyLabel:IsA("TextLabel") then
			keyLabel = nil
		end
		slots[index] = {
			Slot = slot,
			Def = def,
			Punch = punch,
			Bar = bar,
			CoolUntil = 0,
			LastCount = nil,
			Count = countLabel,
			Key = keyLabel,
		}
	end
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
function HotbarController.Init()
	if initialized then
		return
	end
	initialized = true
	LocalPlayer = Players.LocalPlayer
	touchDevice = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	pcall(State.Init)

	gui = CloudUI.NewScreenGui("NimbusHotbar", 11)
	holder = Util.Create("Frame", {
		Name = "Hotbar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -BOTTOM),
		Size = UDim2.fromOffset(barWidth(), SLOT),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = gui,
	})
	holderScale = Util.Create("UIScale", { Name = "ViewportScale", Scale = 1, Parent = holder })

	buildSlots()
	buildHint()
	relayout()
	refresh()

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local ok, err = pcall(relayout)
		if not ok then
			warnOnce("relayout", err)
		end
	end)
	State.Changed:Connect(function()
		local ok, err = pcall(refresh)
		if not ok then
			warnOnce("refresh", err)
		end
	end)
	for _, attribute in ipairs({ Config.Attr.InMatch, Config.Attr.Downed }) do
		LocalPlayer:GetAttributeChangedSignal(attribute):Connect(function()
			local ok, err = pcall(refresh)
			if not ok then
				warnOnce("attribute", err)
			end
		end)
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local index = KEYS[input.KeyCode]
		if index then
			local ok, err = pcall(HotbarController.UseSlot, index)
			if not ok then
				warnOnce("key", err)
			end
		end
	end)

	task.spawn(getUseRemote)
end

return HotbarController
