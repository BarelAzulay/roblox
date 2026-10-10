-- NpcController (client): brings the lobby NPC pets to life and shows their dialog (ARCHITECTURE_V3.md section 5).
--
--   NpcController.Init()
--   NpcController.Open(npcId)    opens the dialog of that NPC (what its ProximityPrompt does)
--   NpcController.Close()
--   NpcController.IsOpen() -> bool, npcId | nil
--
-- Idle (client only, the server never moves an NPC): every model tagged NpcDialog.Tag ("NC_Npc") gets a gentle
-- bob, a slow sway, a slow turn toward the nearest player (and toward you while you talk), low-frequency wing
-- flaps through PetBuilder.Animate and a little hop on every new line. To keep this cheap, the pet's static parts
-- are welded (locally) to its anchored PrimaryPart once it has fully replicated, so a pose is ONE CFrame write
-- plus the animated groups (wings, tail...); NPCs further than 140 studs from the camera are frozen, those past
-- 70 studs update every other frame. One RenderStepped connection drives everything.
--
-- Dialog (ScreenGui "NimbusNpcDialog", display order 13): a side card at the BOTTOM-LEFT, above the HUD's
-- bottom-left stack (NimbusHud attribute BottomLeftTop) and right of the menu column when they would overlap,
-- never centred. It shows the NPC's name tab, a portrait viewport of the pet, its title, the line in a dark text
-- well with a typewriter reveal (numbers and key phrases highlighted), page dots, and Next / Close buttons.
-- Lines cycle (Next on the last line starts over). Triggering the prompt again (E) also advances; clicking the
-- text finishes the current line. The card closes when you walk away, die or enter a match.
-- Designed in 1080p pixels under a UIScale of Theme.ScreenFactor() (body 20, captions 16, buttons 20, name 28),
-- shrunk to fit short screens but never below 14 px text. Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))

local function optionalShared(name)
	local module = Shared:FindFirstChild(name) or Shared:WaitForChild(name, 5)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[NpcController] failed to load " .. name .. ": " .. tostring(result))
	return nil
end

local NpcDialog = optionalShared("NpcDialog")
local PetBuilder = optionalShared("PetBuilder")
local PetCatalog = optionalShared("PetCatalog")

local Client = script.Parent.Parent
local CloudUI = nil
do
	local ok, result = pcall(function()
		return require(Client:WaitForChild("UI"):WaitForChild("CloudUI"))
	end)
	if ok and type(result) == "table" then
		CloudUI = result
	end
end

local LocalPlayer = Players.LocalPlayer

local NpcController = {}

----------------------------------------------------------------------
-- Tunables (studs / seconds; UI sizes are design pixels of a 1080p screen)
----------------------------------------------------------------------
local K = {
	CULL = 140, -- NPCs further than this from the camera are frozen
	NEAR = 70, -- beyond this they update every other frame
	LOOK_RANGE = 26, -- they turn toward the nearest player within this distance
	MAX_TURN = math.rad(115),
	TURN_RATE = 2.2,
	TURN_SPEED = math.rad(80), -- max degrees per second: a slow, deliberate turn
	BOB_AMP = 0.22,
	BOB_PERIOD = 3.4,
	ROLL = math.rad(2.2),
	NOD = math.rad(2.6),
	HOP_TIME = 0.42,
	HOP_H = 0.55,
	FLAP = 0.4, -- PetBuilder.Animate flap speed multiplier while idle (about 0.8 beats a second)
	FLAP_TALK = 0.8,
	EXCITE_TALK = 0.35,
	TARGET_REFRESH = 0.25,
	CHECK_EVERY = 0.2,
	LAYOUT_EVERY = 0.5,
	CPS = 50, -- typewriter characters per second
	PAUSE_END = 0.22,
	PAUSE_MID = 0.09,
	READY_TIMEOUT = 12,
	-- dialog card
	W = 540, -- full card
	H = 216,
	W_MIN = 420, -- compact card for narrow screens (taller, so long lines still fit)
	H_COMPACT = 250,
	TAB_ABOVE = 24, -- the name tab rides this far above the card
	PAD = 14,
	PORTRAIT = 128,
	WELL_X = 158,
	WELL_TOP = 30,
	FOOTER_H = 42,
	TEXT = 20,
	NAME = 28,
	CAPTION = 20, -- the title under the portrait (wraps to two rows when needed)
	BUTTON = 20,
	MIN_SCALE = 0.7, -- every text of the card is >= 20 design px, so 20 * 0.7 = 14 px: the readability floor
	EDGE = 12,
	TOUCH_EDGE = 20,
	GAP = 10,
	MAX_DOTS = 6,
	DISPLAY_ORDER = 13,
	MAX_WIDTH_FRACTION = 0.62, -- on wide screens the card never reaches into the middle of the screen
	SMALL_WIDTH_FRACTION = 0.8, -- small screens have no middle to spare
	SMALL_SCREEN = 1100,
}

local TAU = math.pi * 2
local TAG = (NpcDialog and NpcDialog.Tag) or "NC_Npc"
local SETTINGS = (NpcDialog and NpcDialog.Settings) or {}
local CLOSE_DISTANCE = tonumber(SETTINGS.CloseDistance) or 16
local TOKEN_GLYPH = (Theme.Currency and Theme.Currency.Tokens and Theme.Currency.Tokens.Glyph) or "\226\152\129"

local C = {
	White = Theme.Colors.White,
	Navy = Theme.Colors.Navy or Theme.Colors.Ink,
	FrameTop = Theme.Colors.FrameTop or Color3.fromRGB(176, 212, 244),
	FrameBottom = Theme.Colors.FrameBottom or Color3.fromRGB(112, 158, 216),
	WellTop = Theme.Colors.WellTop or Color3.fromRGB(60, 96, 164),
	WellBottom = Theme.Colors.WellBottom or Color3.fromRGB(40, 68, 128),
	WellEdge = Theme.Colors.WellEdge or Color3.fromRGB(22, 34, 82),
	Gold = Theme.Colors.Gold or Color3.fromRGB(244, 196, 78),
	Shadow = Color3.fromRGB(14, 20, 46),
	DotOff = Color3.fromRGB(70, 96, 150),
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local recs = {} -- array of NPC records
local byModel = {} -- [model] = record
local pending = {} -- [model] = true while waiting for it to replicate
local talkedTo = {} -- [npcId] = true once the local player has talked to it (hides the "!" badge)
local promptServiceHooked = false
local lastTrigger = {} -- [prompt] = clock of the last accepted trigger (guards double events)

local clock = 0
local loopConn = nil
local targetTimer = 0
local checkTimer = 0
local layoutTimer = 0
local initialized = false

local UI = {}
local dialog = {
	Open = false,
	Rec = nil,
	Lines = nil,
	Index = 1,
	Chars = {},
	Total = 0,
	Shown = 0,
	Timer = 0,
	Typing = false,
	Viewport = nil,
	SlideTween = nil,
	PendingOpen = nil, -- an NPC model whose prompt was used before it finished replicating
	Width = nil,
}

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function make(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props) do
		inst[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(parent, px)
	return make("UICorner", { CornerRadius = UDim.new(0, px) }, parent)
end

local function stroke(parent, color, thickness, transparency)
	return make("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function box(name, props, parent)
	local f = make("Frame", { Name = name, BackgroundTransparency = 1, BorderSizePixel = 0 }, nil)
	for k, v in pairs(props) do
		f[k] = v
	end
	if parent then
		f.Parent = parent
	end
	return f
end

local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

local function hex(c)
	return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function playerGui()
	return LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

local function localRoot()
	local char = LocalPlayer and LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function topInset()
	local ok, inset = pcall(function()
		return GuiService:GetGuiInset()
	end)
	if ok and typeof(inset) == "Vector2" then
		return inset.Y
	end
	return 0
end

-- y offset that converts another gui's AbsolutePosition into our gui-area coordinates
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

local function rectOf(inst, dy)
	local p, s = inst.AbsolutePosition, inst.AbsoluteSize
	return { x0 = p.X, y0 = p.Y + dy, x1 = p.X + s.X, y1 = p.Y + s.Y + dy }
end

----------------------------------------------------------------------
-- Rich text: numbers and key phrases of a line are highlighted
----------------------------------------------------------------------
local function escapeRich(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function isWordChar(ch)
	return ch ~= nil and ch ~= "" and string.find(ch, "^[%w]") ~= nil
end

-- returns richText, plainText
local function richLine(text, def, accent)
	text = tostring(text or "")
	local spans = {}
	local function free(s, e)
		for i = 1, #spans do
			local sp = spans[i]
			if s <= sp[2] and e >= sp[1] then
				return false
			end
		end
		return true
	end
	local keyColor = hex(accent:Lerp(Color3.new(1, 1, 1), 0.55))
	local numColor = hex(Color3.fromRGB(255, 214, 102))
	-- key phrases, longest first, whole words only
	local keys = {}
	if def and type(def.Keywords) == "table" then
		for _, k in ipairs(def.Keywords) do
			if type(k) == "string" and k ~= "" then
				keys[#keys + 1] = k
			end
		end
	end
	table.sort(keys, function(a, b)
		return #a > #b
	end)
	for _, k in ipairs(keys) do
		local init = 1
		while true do
			local s, e = string.find(text, k, init, true)
			if not s then
				break
			end
			local before = s > 1 and string.sub(text, s - 1, s - 1) or ""
			local after = string.sub(text, e + 1, e + 1)
			if not isWordChar(before) and not isWordChar(after) and free(s, e) then
				spans[#spans + 1] = { s, e, keyColor }
			end
			init = e + 1
		end
	end
	-- words painted in their own colour (element names), lightened to read on the dark well
	if def and type(def.ColorWords) == "table" then
		for word, color in pairs(def.ColorWords) do
			if type(word) == "string" and word ~= "" and typeof(color) == "Color3" then
				local wordColor = hex(color:Lerp(Color3.new(1, 1, 1), 0.3))
				local from = 1
				while true do
					local s, e = string.find(text, word, from, true)
					if not s then
						break
					end
					local before = s > 1 and string.sub(text, s - 1, s - 1) or ""
					if not isWordChar(before) and not isWordChar(string.sub(text, e + 1, e + 1)) and free(s, e) then
						spans[#spans + 1] = { s, e, wordColor }
					end
					from = e + 1
				end
			end
		end
	end
	-- numbers: "+10", "x1.5", "1,000 ☁", "40%", "1.6"
	local init = 1
	while true do
		local s, e = string.find(text, "[%+x]?%d[%d,%.]*%%?", init)
		if not s then
			break
		end
		if string.sub(text, s, s) == "x" and s > 1 and isWordChar(string.sub(text, s - 1, s - 1)) then
			s = s + 1 -- an "x" glued to a word is not a multiplier
		end
		while e > s and string.find(string.sub(text, e, e), "[,%.]") do
			e = e - 1
		end
		local glyph = " " .. TOKEN_GLYPH
		if string.sub(text, e + 1, e + #glyph) == glyph then
			e = e + #glyph
		end
		if free(s, e) then
			spans[#spans + 1] = { s, e, numColor }
		end
		init = e + 1
	end
	table.sort(spans, function(a, b)
		return a[1] < b[1]
	end)
	local out = {}
	local pos = 1
	for _, sp in ipairs(spans) do
		out[#out + 1] = escapeRich(string.sub(text, pos, sp[1] - 1))
		out[#out + 1] = '<font color="' .. sp[3] .. '">' .. escapeRich(string.sub(text, sp[1], sp[2])) .. "</font>"
		pos = sp[2] + 1
	end
	out[#out + 1] = escapeRich(string.sub(text, pos))
	return table.concat(out), text
end

-- UTF-8 characters of `text` into `into` (reused table); returns the count
local function splitChars(text, into)
	for i = #into, 1, -1 do
		into[i] = nil
	end
	local n = 0
	for ch in string.gmatch(text, "[\1-\127\194-\244][\128-\191]*") do
		n = n + 1
		into[n] = ch
	end
	return n
end

local function charDelay(ch)
	local d = 1 / K.CPS
	if ch == "." or ch == "!" or ch == "?" then
		d = d + K.PAUSE_END
	elseif ch == "," or ch == ":" then
		d = d + K.PAUSE_MID
	end
	return d
end

----------------------------------------------------------------------
-- NPC records
----------------------------------------------------------------------
local function countParts(model)
	local n = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			n = n + 1
		end
	end
	return n
end

local function isComplete(model)
	if model:GetAttribute("Ready") ~= true then
		return false
	end
	local wanted = model:GetAttribute("PetParts")
	if type(wanted) ~= "number" then
		return true -- an NPC without a pet
	end
	local pet = model:FindFirstChild("Pet")
	if not pet then
		return false
	end
	local root = pet.PrimaryPart or pet:FindFirstChild("Body")
	return root ~= nil and countParts(pet) >= wanted
end

-- Parts that PetBuilder.Animate re-poses every call (wings, tail, halo...). Eyelids ("lid" groups) only change
-- transparency, so they stay welded to the body like everything else.
local function isAnimatedPart(part)
	local spec = part:GetAttribute("PB_G")
	if type(spec) ~= "string" then
		return false
	end
	local kind = string.match(spec, "^[^:]*:([^:]*)")
	return kind ~= "lid"
end

-- Welds every static part of the pet to its anchored root (local to this client): a pose is then one CFrame
-- write on the root. Returns true when the whole pet is welded.
local function weldStatic(pet, root)
	local ok, err = pcall(function()
		local inv = root.CFrame:Inverse()
		for _, part in ipairs(pet:GetDescendants()) do
			if part:IsA("BasePart") and part ~= root and not isAnimatedPart(part) then
				local weld = Instance.new("Weld")
				weld.Name = "NpcIdleWeld"
				weld.Part0 = root
				weld.Part1 = part
				weld.C0 = inv * part.CFrame
				weld.C1 = CFrame.new()
				weld.Parent = part
				part.Anchored = false
			end
		end
		root.Anchored = true
	end)
	if not ok then
		warn("[NpcController] could not weld an NPC pet, using PivotTo: " .. tostring(err))
	end
	return ok
end

local function scaleNameplate(rec)
	local gui = rec.Nameplate
	if not gui or not gui.Parent then
		return
	end
	local w = tonumber(gui:GetAttribute("BaseWidth"))
	local h = tonumber(gui:GetAttribute("BaseHeight"))
	local plate = gui:FindFirstChild("Plate")
	if not (w and h and plate and plate:IsA("GuiObject")) then
		return
	end
	local f = Theme.ScreenFactor()
	gui.Size = UDim2.fromOffset(math.floor(w * f + 0.5), math.floor(h * f + 0.5))
	local scale = plate:FindFirstChild("ReadScale")
	if not (scale and scale:IsA("UIScale")) then
		scale = make("UIScale", { Name = "ReadScale" }, plate)
	end
	scale.Scale = f
end

local function refreshBadge(rec)
	if rec.Badge then
		rec.Badge.Visible = not talkedTo[rec.Id]
	end
end

local onPrompt -- forward declaration (the dialog section defines it)
local ensureLoop

local function removeRec(rec)
	for i = #recs, 1, -1 do
		if recs[i] == rec then
			table.remove(recs, i)
		end
	end
	if rec.Model then
		byModel[rec.Model] = nil
	end
	if rec.PromptConn then
		rec.PromptConn:Disconnect()
		rec.PromptConn = nil
	end
	if dialog.Open and dialog.Rec == rec then
		NpcController.Close()
	end
end

local function setup(model)
	if byModel[model] or not model.Parent then
		return
	end
	local id = model:GetAttribute("NpcId")
	if type(id) ~= "string" then
		return
	end
	local rec = {
		Model = model,
		Id = id,
		Def = NpcDialog and NpcDialog.Get(id) or nil,
		Yaw = 0,
		Phase = (#recs * 1.37) % TAU,
		Skip = 0,
		Frame = 0,
		HopT = nil,
		Target = nil,
		AnimOpts = { Flap = K.FLAP, Excited = 0 },
		Accent = model:GetAttribute("Accent"),
	}
	if typeof(rec.Accent) ~= "Color3" then
		rec.Accent = (rec.Def and rec.Def.Accent) or Color3.fromRGB(120, 180, 236)
	end
	local pet = model:FindFirstChild("Pet")
	local root = pet and (pet.PrimaryPart or pet:FindFirstChild("Body"))
	if pet and root and root:IsA("BasePart") then
		rec.Pet = pet
		rec.Root = root
		rec.Base = root.CFrame
		rec.Welded = weldStatic(pet, root)
	end
	local promptPart = model:FindFirstChild("PromptPart")
	rec.Center = (promptPart and promptPart:IsA("BasePart") and promptPart.Position) or (rec.Base and rec.Base.Position)
		or model:GetPivot().Position
	rec.Prompt = model:FindFirstChild("TalkPrompt", true)
	rec.Nameplate = model:FindFirstChild("Nameplate", true)
	rec.Badge = rec.Nameplate and rec.Nameplate:FindFirstChild("Badge", true) or nil
	scaleNameplate(rec)
	refreshBadge(rec)
	if not promptServiceHooked and rec.Prompt and rec.Prompt:IsA("ProximityPrompt") then
		-- ProximityPromptService.PromptTriggered is unavailable: listen on the prompt itself
		local prompt = rec.Prompt
		rec.PromptConn = prompt.Triggered:Connect(function(player)
			onPrompt(prompt, player)
		end)
	end
	recs[#recs + 1] = rec
	byModel[model] = rec
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(game) and byModel[model] == rec then
			removeRec(rec)
		end
	end)
	ensureLoop()
	if dialog.PendingOpen == model then
		dialog.PendingOpen = nil
		task.defer(function()
			if byModel[model] == rec then
				NpcController.Open(rec.Id)
			end
		end)
	end
end

local function track(model)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end
	if byModel[model] or pending[model] then
		return
	end
	pending[model] = true
	task.spawn(function()
		local waited = 0
		while waited < K.READY_TIMEOUT and model.Parent and not isComplete(model) do
			task.wait(0.2)
			waited = waited + 0.2
		end
		pending[model] = nil
		if model.Parent then
			local ok, err = pcall(setup, model)
			if not ok then
				warn("[NpcController] NPC setup failed: " .. tostring(err))
			end
		end
	end)
end

local function recByPrompt(prompt)
	for _, rec in ipairs(recs) do
		if rec.Prompt == prompt then
			return rec
		end
	end
	-- a prompt we have not seen yet (the NPC is still replicating): find its NPC model
	local node = prompt
	while node and node ~= Workspace do
		local rec = byModel[node]
		if rec then
			return rec
		end
		node = node.Parent
	end
	return nil
end

----------------------------------------------------------------------
-- Idle animation
----------------------------------------------------------------------
local function refreshTargets()
	local roots = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			roots[#roots + 1] = root
		end
	end
	local mine = localRoot()
	for _, rec in ipairs(recs) do
		local best, bestD = nil, K.LOOK_RANGE
		if dialog.Open and dialog.Rec == rec and mine then
			best = mine
		elseif rec.Center then
			for _, root in ipairs(roots) do
				local d = (root.Position - rec.Center).Magnitude
				if d < bestD then
					best, bestD = root, d
				end
			end
		end
		rec.Target = best
	end
end

local function poseNpc(rec, dt)
	local base = rec.Base
	-- slow turn toward the target (or back to the walkway)
	local desired = 0
	local target = rec.Target
	if target and target.Parent then
		local v = base:PointToObjectSpace(target.Position)
		if v.X * v.X + v.Z * v.Z > 0.25 then
			desired = clamp(math.atan2(-v.X, -v.Z), -K.MAX_TURN, K.MAX_TURN)
		end
	end
	local turn = (desired - rec.Yaw) * (1 - math.exp(-dt * K.TURN_RATE))
	local maxStep = K.TURN_SPEED * dt
	rec.Yaw = rec.Yaw + clamp(turn, -maxStep, maxStep)

	local talking = dialog.Open and dialog.Rec == rec
	local t = clock + rec.Phase
	local y = math.sin(t * TAU / K.BOB_PERIOD) * K.BOB_AMP
	if rec.HopT then
		rec.HopT = rec.HopT + dt
		local u = rec.HopT / K.HOP_TIME
		if u >= 1 then
			rec.HopT = nil
		else
			y = y + 4 * u * (1 - u) * K.HOP_H
		end
	end
	local pitch = 0
	if talking then
		local amount = 0.35
		if dialog.Typing then
			amount = 1
		end
		pitch = math.sin(t * 7.5) * K.NOD * amount
	end
	local roll = math.sin(t * 0.83) * K.ROLL
	local cf = base * CFrame.new(0, y, 0) * CFrame.Angles(0, rec.Yaw, 0) * CFrame.Angles(pitch, 0, roll)
	if rec.Welded then
		rec.Root.CFrame = cf
	else
		rec.Pet:PivotTo(cf)
	end

	local opts = rec.AnimOpts
	if talking then
		opts.Flap = K.FLAP_TALK
		opts.Excited = K.EXCITE_TALK
	else
		opts.Flap = K.FLAP
		opts.Excited = 0
	end
	if PetBuilder and PetBuilder.Animate then
		local ok = pcall(PetBuilder.Animate, rec.Pet, clock, opts)
		if not ok then
			rec.Pet = nil -- a broken rig: keep the NPC still from now on
		end
	end
end

-- distance from an NPC to the viewer: the camera or the local character, whichever is closer
local function viewDistance(pos, camPos, rootPos)
	local d = math.huge
	if camPos then
		d = (pos - camPos).Magnitude
	end
	if rootPos then
		d = math.min(d, (pos - rootPos).Magnitude)
	end
	if d == math.huge then
		return 0
	end
	return d
end

local function stepNpcs(dt, camPos, rootPos)
	for i = 1, #recs do
		local rec = recs[i]
		if rec.Pet and rec.Root and rec.Root.Parent then
			local d = viewDistance(rec.Base.Position, camPos, rootPos)
			if d <= K.CULL then
				rec.Frame = rec.Frame + 1
				rec.Skip = rec.Skip + dt
				if d <= K.NEAR or rec.Frame % 2 == 0 then
					local step = math.min(rec.Skip, 0.1)
					rec.Skip = 0
					poseNpc(rec, step)
				end
				if rec.Badge and rec.Badge.Visible and d <= K.NEAR then
					rec.Badge.Rotation = math.sin(clock * 4 + rec.Phase) * 12 -- a little "new tips" wiggle
				end
			else
				rec.Skip = 0
			end
		end
	end
end

----------------------------------------------------------------------
-- Dialog UI
----------------------------------------------------------------------
local function newButton(text, style, size, callback, parent)
	if CloudUI and CloudUI.Button then
		local ok, button = pcall(CloudUI.Button, {
			Name = "Button_" .. text,
			Text = text,
			Style = style,
			Size = size,
			TextSize = K.BUTTON,
			Callback = callback,
			Parent = parent,
		})
		if ok and button then
			return button
		end
	end
	local button = make("TextButton", {
		Name = "Button_" .. text,
		Size = size,
		AutoButtonColor = true,
		BorderSizePixel = 0,
		BackgroundColor3 = (Theme.Buttons and Theme.Buttons[style]) or Color3.fromRGB(96, 196, 108),
		Text = text,
	}, nil)
	Theme.Style(button, "Button", { Size = K.BUTTON, Outline = 2 })
	corner(button, 12)
	stroke(button, C.Navy, 3)
	button.Activated:Connect(function()
		callback(button)
	end)
	button.Parent = parent
	return button
end

-- cloud bumps on the top edge, right of the name tab: { x offset from the right edge, diameter, y offset }
local PUFFS = { { -96, 34, 3 }, { -60, 46, -1 }, { -24, 30, 4 } }

local function buildDialog()
	local gui
	if CloudUI and CloudUI.NewScreenGui then
		gui = CloudUI.NewScreenGui("NimbusNpcDialog", K.DISPLAY_ORDER)
	else
		local pg = playerGui()
		local old = pg and pg:FindFirstChild("NimbusNpcDialog")
		if old then
			old:Destroy()
		end
		gui = make("ScreenGui", {
			Name = "NimbusNpcDialog",
			ResetOnSpawn = false,
			IgnoreGuiInset = false,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			DisplayOrder = K.DISPLAY_ORDER,
		}, pg)
	end
	UI.Gui = gui

	local root = box("NpcDialog", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, K.EDGE, 1, -220),
		Size = UDim2.fromOffset(K.W, K.H),
		Visible = false,
	}, gui)
	UI.Root = root
	UI.Scale = make("UIScale", { Name = "ReadScale", Scale = 1 }, root)

	local slide = box("Slide", { Size = UDim2.fromScale(1, 1) }, root)
	UI.Slide = slide

	local shadow = box("Shadow", {
		BackgroundTransparency = 0.6,
		BackgroundColor3 = C.Shadow,
		Position = UDim2.fromOffset(0, 7),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	}, slide)
	corner(shadow, 20)

	-- cloud puffs along the top-right edge (navy rings behind, pale puffs in front of the card's outline)
	local rings = box("PuffRings", { Size = UDim2.fromScale(1, 1), ZIndex = 2 }, slide)
	local puffs = box("Puffs", { Size = UDim2.fromScale(1, 1), ZIndex = 4 }, slide)
	for i, spec in ipairs(PUFFS) do
		local d = spec[2]
		local ring = box("Ring" .. i, {
			BackgroundTransparency = 0,
			BackgroundColor3 = C.Navy,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(1, spec[1], 0, spec[3]),
			Size = UDim2.fromOffset(d + 8, d + 8),
			ZIndex = 2,
		}, rings)
		corner(ring, 999)
		local puff = box("Puff" .. i, {
			BackgroundTransparency = 0,
			BackgroundColor3 = C.FrameTop,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(1, spec[1], 0, spec[3]),
			Size = UDim2.fromOffset(d, d),
			ZIndex = 4,
		}, puffs)
		corner(puff, 999)
	end

	local card = box("Card", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.White,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Active = true, -- clicks on the card never fall through to the world
	}, slide)
	corner(card, 20)
	stroke(card, C.Navy, 4)
	Theme.Gradient(card, C.FrameTop, C.FrameBottom, 90)
	local rim = box("Rim", { Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6), ZIndex = 3 }, card)
	corner(rim, 17)
	stroke(rim, Theme.Lighten(C.FrameTop, 0.55), 2, 0.35)
	UI.Card = card

	-- portrait: accent tile with the pet's viewport and a couple of pixel glints
	local portrait = box("Portrait", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.White,
		Position = UDim2.fromOffset(K.PAD, 16),
		Size = UDim2.fromOffset(K.PORTRAIT, K.PORTRAIT),
		ZIndex = 5,
	}, card)
	corner(portrait, 18)
	stroke(portrait, C.Navy, 3)
	UI.PortraitGradient = Theme.Gradient(portrait, C.FrameTop, C.FrameBottom, 90)
	UI.Portrait = portrait
	UI.PortraitHolder = box("Holder", { Size = UDim2.fromScale(1, 1), ZIndex = 6 }, portrait)
	box("Glint", {
		BackgroundTransparency = 0.25,
		BackgroundColor3 = C.White,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(8, 8),
		ZIndex = 7,
	}, portrait)
	box("Glint2", {
		BackgroundTransparency = 0.45,
		BackgroundColor3 = C.White,
		Position = UDim2.fromOffset(20, 10),
		Size = UDim2.fromOffset(4, 4),
		ZIndex = 7,
	}, portrait)

	-- title caption under the portrait
	local titlePill = box("TitlePill", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.Navy,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromOffset(K.PAD + K.PORTRAIT / 2, 16 + K.PORTRAIT + 8),
		Size = UDim2.fromOffset(K.PORTRAIT + 8, 46),
		ZIndex = 6,
	}, card)
	corner(titlePill, 12)
	UI.TitleStroke = stroke(titlePill, C.Gold, 2)
	UI.Title = Theme.Label("", "Label", {
		Size = K.CAPTION,
		Stroke = 0.3,
		Outline = 1.5,
		Props = {
			Name = "Title",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -10, 1, -4),
			TextWrapped = true,
			LineHeight = 0.9,
			ZIndex = 7,
		},
	})
	UI.Title.Parent = titlePill

	-- name tab riding on the top edge
	local nameTab = box("NameTab", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.White,
		Position = UDim2.fromOffset(K.WELL_X, -22),
		Size = UDim2.fromOffset(250, 46),
		ZIndex = 8,
	}, slide)
	corner(nameTab, 14)
	stroke(nameTab, C.Navy, 3)
	UI.NameGradient = Theme.Gradient(nameTab, C.FrameTop, C.FrameBottom, 90)
	UI.NameTab = nameTab
	UI.Name = Theme.Label("", "Title", {
		Scaled = true,
		Stroke = 0.2,
		Outline = 2,
		Props = {
			Name = "Name",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -20, 1, -10),
			ZIndex = 9,
		},
	})
	make("UITextSizeConstraint", { MaxTextSize = K.NAME, MinTextSize = 20 }, UI.Name)
	UI.Name.Parent = nameTab

	-- the text well (dark, high contrast) with a speech tail toward the portrait
	local tail = box("Tail", {
		BackgroundTransparency = 0,
		BackgroundColor3 = C.WellTop,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(K.WELL_X, K.WELL_TOP + 34),
		Size = UDim2.fromOffset(16, 16),
		Rotation = 45,
		ZIndex = 5,
	}, card)
	stroke(tail, C.WellEdge, 2)
	local well = make("TextButton", {
		Name = "Well",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = C.White,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(K.WELL_X, K.WELL_TOP),
		Size = UDim2.new(1, -(K.WELL_X + K.PAD), 1, -(K.WELL_TOP + K.FOOTER_H + 18)),
		ZIndex = 6,
	}, card)
	corner(well, 14)
	stroke(well, C.WellEdge, 2)
	Theme.Gradient(well, C.WellTop, C.WellBottom, 90)
	UI.Well = well
	local line = Theme.Label("", "Body", {
		Size = K.TEXT,
		Stroke = 0.55,
		Props = {
			Name = "Line",
			RichText = true,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromOffset(14, 10),
			Size = UDim2.new(1, -28, 1, -36), -- the bottom row of the well holds the page dots
			LineHeight = 1.05,
			ZIndex = 7,
		},
	})
	line.Parent = well
	UI.Line = line
	local more = Theme.Label("\226\150\188", "Label", { -- down triangle: "there is more"
		Size = 20,
		Color = C.Gold,
		Stroke = 0.3,
		Props = {
			Name = "More",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -10, 1, -6),
			Size = UDim2.fromOffset(20, 20),
			Visible = false,
			ZIndex = 8,
		},
	})
	more.Parent = well
	UI.More = more

	-- page dots in the bottom row of the well
	local dots = box("Dots", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -6),
		Size = UDim2.fromOffset(K.MAX_DOTS * 18, 16),
		ZIndex = 8,
	}, well)
	UI.Dots = {}
	for i = 1, K.MAX_DOTS do
		local dot = box("Dot" .. i, {
			BackgroundTransparency = 0,
			BackgroundColor3 = C.DotOff,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset((i - 1) * 18 + 7, 8),
			Size = UDim2.fromOffset(10, 10),
			ZIndex = 9,
			Visible = false,
		}, dots)
		corner(dot, 999)
		stroke(dot, C.Navy, 2)
		UI.Dots[i] = dot
	end

	-- footer: Close, Next (right-aligned under the well)
	local footer = box("Footer", {
		Position = UDim2.new(0, K.WELL_X, 1, -(K.FOOTER_H + 12)),
		Size = UDim2.new(1, -(K.WELL_X + K.PAD), 0, K.FOOTER_H),
		ZIndex = 6,
	}, card)

	UI.Next = newButton("Next", "Green", UDim2.fromOffset(118, K.FOOTER_H), function()
		NpcController.Advance()
	end, footer)
	UI.Next.AnchorPoint = Vector2.new(1, 0.5)
	UI.Next.Position = UDim2.new(1, 0, 0.5, 0)
	UI.Next.ZIndex = 8
	UI.Close = newButton("Close", "Pink", UDim2.fromOffset(110, K.FOOTER_H), function()
		NpcController.Close()
	end, footer)
	UI.Close.AnchorPoint = Vector2.new(1, 0.5)
	UI.Close.Position = UDim2.new(1, -128, 0.5, 0)
	UI.Close.ZIndex = 8

	well.Activated:Connect(function()
		if dialog.Typing then
			NpcController.Advance()
		end
	end)
end

----------------------------------------------------------------------
-- Dialog layout (bottom-left, above the HUD, clear of the menu column)
----------------------------------------------------------------------
local function menuColumnRect()
	local pg = playerGui()
	local menu = pg and pg:FindFirstChild("NimbusMenu")
	if not (menu and menu:IsA("ScreenGui") and menu.Enabled) then
		return nil
	end
	local dy = insetShift(menu)
	local column = menu:FindFirstChild("MenuColumn", true)
	if column and column:IsA("GuiObject") and shownIn(column, menu) and column.AbsoluteSize.X > 0 then
		return rectOf(column, dy)
	end
	local rect = nil
	for _, d in ipairs(menu:GetDescendants()) do
		if d:IsA("GuiObject") and string.sub(d.Name, 1, 11) == "MenuButton_" and d.AbsoluteSize.X > 0 and shownIn(d, menu) then
			local r = rectOf(d, dy)
			if rect then
				rect.x0, rect.y0 = math.min(rect.x0, r.x0), math.min(rect.y0, r.y0)
				rect.x1, rect.y1 = math.max(rect.x1, r.x1), math.max(rect.y1, r.y1)
			else
				rect = r
			end
		end
	end
	return rect
end

local function tutorialRect()
	local pg = playerGui()
	local gui = pg and pg:FindFirstChild("NimbusTutorial")
	if not (gui and gui:IsA("ScreenGui") and gui.Enabled) then
		return nil
	end
	local panel = gui:FindFirstChild("TutorialPanel", true)
	if panel and panel:IsA("GuiObject") and shownIn(panel, gui) and panel.AbsoluteSize.X > 0 then
		return rectOf(panel, insetShift(gui))
	end
	return nil
end

-- Fits the card into the box left..rightLimit x topLimit..bottom (gui px): returns scale, design width, design
-- height. Narrow boxes get the compact card; the scale may come out below K.MIN_SCALE (= does not fit).
local function fitCard(left, bottom, topLimit, rightLimit, f)
	local availW, availH = rightLimit - left, bottom - topLimit
	if availW <= 0 or availH <= 0 then
		return 0, K.W_MIN, K.H_COMPACT
	end
	local scale = f
	local w = K.W
	if w * scale > availW then
		w = math.max(K.W_MIN, math.floor(availW / scale))
		if w * scale > availW then
			scale = availW / w
		end
	end
	local h = K.H
	if w < K.W - 60 then
		h = K.H_COMPACT
	end
	if (h + K.TAB_ABOVE) * scale > availH then
		scale = availH / (h + K.TAB_ABOVE)
	end
	return scale, w, h
end

local function layoutDialog()
	local gui, root = UI.Gui, UI.Root
	if not (gui and root) then
		return
	end
	local area = gui.AbsoluteSize
	if area.X < 2 or area.Y < 2 then
		local cam = Workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
		area = Vector2.new(vp.X, math.max(2, vp.Y - topInset()))
	end
	local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local edge = touch and K.TOUCH_EDGE or K.EDGE
	local f = Theme.ScreenFactor()
	local rightLimit = area.X * K.MAX_WIDTH_FRACTION
	if area.X < K.SMALL_SCREEN then
		rightLimit = math.max(rightLimit, area.X * K.SMALL_WIDTH_FRACTION)
	end
	rightLimit = math.min(rightLimit, area.X - edge)

	-- bottom: just above the HUD's bottom-left stack (or an estimate of it); top: below the top-left panel
	local pg = playerGui()
	local hud = pg and pg:FindFirstChild("NimbusHud")
	local bottom = area.Y - edge - 190 * f
	local topLimit = edge
	if hud and hud:IsA("ScreenGui") then
		local shift = insetShift(hud)
		local blt = hud:GetAttribute("BottomLeftTop")
		if type(blt) == "number" and blt > 0 then
			bottom = blt + shift - K.GAP
		end
		local tlb = hud:GetAttribute("TopLeftBottom")
		if type(tlb) == "number" and tlb > 0 then
			topLimit = tlb + shift + K.GAP
		end
	end
	bottom = clamp(bottom, 60, area.Y - edge)

	-- 1) bottom-left above the HUD, stepping aside from the menu column / the tutorial card on our rows
	local column = menuColumnRect()
	local tut = tutorialRect()
	local left = edge
	local probeTop = bottom - (K.H + K.TAB_ABOVE) * f
	local function sharesRows(r)
		return r ~= nil and r.y1 > probeTop and r.y0 < bottom
	end
	if sharesRows(column) then
		left = math.max(left, column.x1 + K.GAP)
	end
	if sharesRows(tut) and tut.x0 < left + K.W * f then
		local alt = tut.x1 + K.GAP
		if alt + K.W_MIN * K.MIN_SCALE <= rightLimit then
			left = math.max(left, alt)
		end
	end
	local scale, w, h = fitCard(left, bottom, topLimit, rightLimit, f)
	local x, y = left, bottom
	if scale < K.MIN_SCALE and column and column.y0 > topLimit then
		-- 2) narrow screens: above the menu column, from the left edge
		local b2 = column.y0 - K.GAP
		local s2, w2, h2 = fitCard(edge, b2, topLimit, area.X - edge, f)
		if s2 >= K.MIN_SCALE then
			scale, w, h, x, y = s2, w2, h2, edge, b2
		end
	end
	scale = math.max(K.MIN_SCALE, scale) -- never below readable text, even if the card then overlaps a little
	root.Size = UDim2.fromOffset(w, h)
	root.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	UI.Scale.Scale = scale
	if UI.NameTab then
		UI.NameTab.Size = UDim2.fromOffset(math.min(250, w - K.WELL_X - 104), 46)
	end
	dialog.Width = w
end

----------------------------------------------------------------------
-- Dialog flow
----------------------------------------------------------------------
local function setDots(count, index)
	for i, dot in ipairs(UI.Dots or {}) do
		dot.Visible = i <= count
		if i == index then
			dot.BackgroundColor3 = C.Gold
			dot.Size = UDim2.fromOffset(13, 13)
		else
			dot.BackgroundColor3 = C.DotOff
			dot.Size = UDim2.fromOffset(10, 10)
		end
	end
end

local function finishTyping()
	dialog.Typing = false
	dialog.Shown = dialog.Total
	if UI.Line then
		UI.Line.MaxVisibleGraphemes = -1
	end
	if UI.More then
		UI.More.Visible = true
	end
end

local function showLine(index)
	local lines = dialog.Lines
	if not lines or #lines == 0 then
		return
	end
	local n = #lines
	dialog.Index = ((index - 1) % n) + 1
	local rec = dialog.Rec
	local rich, plain = richLine(lines[dialog.Index], rec and rec.Def, (rec and rec.Accent) or C.Gold)
	UI.Line.Text = rich
	dialog.Total = splitChars(plain, dialog.Chars)
	dialog.Shown = 0
	dialog.Timer = 0
	dialog.Typing = dialog.Total > 0
	UI.Line.MaxVisibleGraphemes = 0
	UI.More.Visible = false
	setDots(math.min(n, K.MAX_DOTS), math.min(dialog.Index, K.MAX_DOTS))
	if UI.Next then
		if dialog.Index >= n then
			UI.Next.Text = "Again"
		else
			UI.Next.Text = "Next"
		end
	end
	if rec then
		rec.HopT = 0
	end
	if not dialog.Typing then
		finishTyping()
	end
end

local function stepTypewriter(dt)
	if not dialog.Typing then
		return
	end
	dialog.Timer = dialog.Timer + dt
	local changed = false
	while dialog.Typing do
		local nextChar = dialog.Chars[dialog.Shown + 1]
		local need = charDelay(nextChar)
		if dialog.Timer < need then
			break
		end
		dialog.Timer = dialog.Timer - need
		dialog.Shown = dialog.Shown + 1
		changed = true
		if dialog.Shown >= dialog.Total then
			finishTyping()
		end
	end
	if changed and dialog.Typing then
		UI.Line.MaxVisibleGraphemes = dialog.Shown
	end
end

local function setPortrait(rec)
	if dialog.Viewport then
		pcall(dialog.Viewport.Destroy)
		dialog.Viewport = nil
	end
	local holder = UI.PortraitHolder
	if not holder then
		return
	end
	for _, child in ipairs(holder:GetChildren()) do
		child:Destroy()
	end
	local petId = rec.Model and rec.Model:GetAttribute("PetId")
	local petDef = nil
	if PetCatalog and type(PetCatalog.Get) == "function" and type(petId) == "string" then
		petDef = PetCatalog.Get(petId)
	end
	if petDef and CloudUI and CloudUI.PetViewport then
		local ok, handle = pcall(CloudUI.PetViewport, holder, petDef, UDim2.fromScale(1, 1), {
			Spin = "sway",
			Flap = 0.7,
			Detail = "High",
			ZIndex = 6,
		})
		if ok and handle then
			dialog.Viewport = handle
			return
		end
	end
	-- no viewport: the NPC's initial on the accent tile
	local name = (rec.Def and rec.Def.Name) or rec.Id
	local initial = Theme.Label(string.sub(tostring(name), 1, 1), "Title", {
		Size = 64,
		Outline = 3,
		Props = { Name = "Initial", Size = UDim2.fromScale(1, 1), ZIndex = 7 },
	})
	initial.Parent = holder
end

local function setPromptText(rec, text)
	if rec and rec.Prompt and rec.Prompt.Parent then
		pcall(function()
			rec.Prompt.ActionText = text
		end)
	end
end

local function slideTo(visible)
	local slide = UI.Slide
	if not slide then
		return
	end
	if dialog.SlideTween then
		pcall(function()
			dialog.SlideTween:Cancel()
		end)
		dialog.SlideTween = nil
	end
	local hidden = UDim2.fromOffset(-((dialog.Width or K.W) + 80), 0)
	if visible then
		UI.Root.Visible = true
		slide.Position = hidden
		dialog.SlideTween = Util.Tween(slide, 0.32, { Position = UDim2.fromOffset(0, 0) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	else
		local tween = Util.Tween(slide, 0.2, { Position = hidden }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		dialog.SlideTween = tween
		tween.Completed:Connect(function()
			if not dialog.Open and dialog.SlideTween == tween then
				UI.Root.Visible = false
			end
		end)
	end
end

local function openRec(rec)
	if not rec or not UI.Root then
		return
	end
	local lines = (rec.Def and rec.Def.Lines) or (NpcDialog and NpcDialog.GetLines(rec.Id)) or {}
	if #lines == 0 then
		lines = { "Hello there, climber!" }
	end
	local switching = dialog.Open and dialog.Rec ~= rec
	if dialog.Open and dialog.Rec == rec then
		return
	end
	if switching then
		setPromptText(dialog.Rec, "Talk")
	end
	dialog.Open = true
	dialog.Rec = rec
	dialog.Lines = lines
	talkedTo[rec.Id] = true
	refreshBadge(rec)
	setPromptText(rec, "Next")

	local def = rec.Def or {}
	local accent = rec.Accent or C.Gold
	UI.Name.Text = def.Name or rec.Model:GetAttribute("NpcName") or rec.Id
	UI.Title.Text = def.Title or rec.Model:GetAttribute("Title") or ""
	UI.TitleStroke.Color = accent
	local nameTop = accent:Lerp(Color3.new(1, 1, 1), 0.25)
	local nameBottom = accent:Lerp(Color3.fromRGB(26, 30, 52), 0.22)
	UI.NameGradient.Color = ColorSequence.new(nameTop, nameBottom)
	UI.PortraitGradient.Color = ColorSequence.new(accent:Lerp(Color3.new(1, 1, 1), 0.55), accent:Lerp(Color3.new(1, 1, 1), 0.12))
	setPortrait(rec)
	layoutDialog()
	layoutTimer = 0
	checkTimer = 0
	refreshTargets()
	showLine(1)
	if not switching then
		slideTo(true)
	end
	ensureLoop()
end

function NpcController.Open(npcId)
	for _, rec in ipairs(recs) do
		if rec.Id == npcId then
			openRec(rec)
			return true
		end
	end
	return false
end

function NpcController.Close()
	if not dialog.Open then
		return
	end
	local rec = dialog.Rec
	dialog.Open = false
	dialog.Rec = nil
	dialog.Typing = false
	setPromptText(rec, "Talk")
	if dialog.Viewport then
		pcall(dialog.Viewport.Destroy)
		dialog.Viewport = nil
	end
	slideTo(false)
	refreshTargets()
end

-- Next: finish the current line, or go to the next one (wrapping to the first).
function NpcController.Advance()
	if not dialog.Open then
		return
	end
	if dialog.Typing then
		finishTyping()
	else
		showLine(dialog.Index + 1)
	end
end

function NpcController.IsOpen()
	if dialog.Open and dialog.Rec then
		return true, dialog.Rec.Id
	end
	return false, nil
end

onPrompt = function(prompt, player)
	if player ~= nil and player ~= LocalPlayer then
		return
	end
	if typeof(prompt) ~= "Instance" then
		return
	end
	local rec = recByPrompt(prompt)
	if not rec then
		local id = prompt:GetAttribute("NpcId")
		if type(id) ~= "string" then
			return
		end
		local model = prompt:FindFirstAncestorOfClass("Model")
		while model and model:GetAttribute("NpcId") ~= id do
			model = model:FindFirstAncestorOfClass("Model")
		end
		if not model then
			return
		end
		dialog.PendingOpen = model -- opens as soon as the NPC has fully replicated
		track(model)
		return
	end
	local now = clock
	if lastTrigger[prompt] and now - lastTrigger[prompt] < 0.15 then
		return
	end
	lastTrigger[prompt] = now
	if dialog.Open and dialog.Rec == rec then
		NpcController.Advance()
	else
		openRec(rec)
	end
end

-- Closes the dialog when the player walked away, died or left the lobby.
local function checkDialog()
	if not dialog.Open then
		return
	end
	local rec = dialog.Rec
	local root = localRoot()
	local char = LocalPlayer and LocalPlayer.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not rec or not rec.Model.Parent or not root or (humanoid and humanoid.Health <= 0) then
		NpcController.Close()
		return
	end
	if LocalPlayer:GetAttribute(Config.Attr.InMatch) == true then
		NpcController.Close()
		return
	end
	local center = rec.Center
	if center then
		local d = root.Position - center
		if Vector3.new(d.X, 0, d.Z).Magnitude > CLOSE_DISTANCE or math.abs(d.Y) > CLOSE_DISTANCE then
			NpcController.Close()
		end
	end
end

----------------------------------------------------------------------
-- Frame loop
----------------------------------------------------------------------
local function onFrame(dt)
	dt = math.min(tonumber(dt) or 0, 0.25)
	clock = clock + dt
	targetTimer = targetTimer + dt
	if targetTimer >= K.TARGET_REFRESH then
		targetTimer = 0
		refreshTargets()
	end
	local cam = Workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or nil
	local root = localRoot()
	stepNpcs(dt, camPos, root and root.Position or nil)

	if dialog.Open then
		stepTypewriter(dt)
		if UI.More and UI.More.Visible then
			UI.More.Position = UDim2.new(1, -10, 1, -6 - math.abs(math.sin(clock * 5)) * 4)
		end
		checkTimer = checkTimer + dt
		if checkTimer >= K.CHECK_EVERY then
			checkTimer = 0
			checkDialog()
		end
		layoutTimer = layoutTimer + dt
		if layoutTimer >= K.LAYOUT_EVERY then
			layoutTimer = 0
			layoutDialog()
		end
	end
end

ensureLoop = function()
	if loopConn then
		return
	end
	loopConn = RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(onFrame, dt)
		if not ok then
			warn("[NpcController] frame error: " .. tostring(err))
		end
	end)
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
local function onViewportChanged()
	for _, rec in ipairs(recs) do
		scaleNameplate(rec)
	end
	if dialog.Open then
		layoutDialog()
	end
end

function NpcController.Init()
	if initialized then
		return
	end
	initialized = true
	if not NpcDialog then
		warn("[NpcController] shared/NpcDialog is unavailable: NPC dialogs are disabled")
	end

	local okUi, errUi = pcall(buildDialog)
	if not okUi then
		warn("[NpcController] dialog UI failed: " .. tostring(errUi))
	end

	-- prompts: the service-wide signal (one connection for every NPC)
	local okHook = pcall(function()
		local signal = ProximityPromptService.PromptTriggered
		if signal then
			signal:Connect(function(prompt, player)
				onPrompt(prompt, player)
			end)
			promptServiceHooked = true
		end
	end)
	if not okHook then
		promptServiceHooked = false
	end

	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(model)
		pending[model] = nil
		local rec = byModel[model]
		if rec then
			removeRec(rec)
		end
	end)
	for _, model in ipairs(CollectionService:GetTagged(TAG)) do
		track(model)
	end

	-- readable nameplates on every screen + dialog relayout
	local cameraConn = nil
	local function bindCamera()
		if cameraConn then
			cameraConn:Disconnect()
			cameraConn = nil
		end
		local cam = Workspace.CurrentCamera
		if cam then
			cameraConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(onViewportChanged)
		end
		onViewportChanged()
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera)
	bindCamera()

	if LocalPlayer then
		LocalPlayer.CharacterRemoving:Connect(function()
			NpcController.Close()
		end)
		LocalPlayer:GetAttributeChangedSignal(Config.Attr.InMatch):Connect(function()
			if LocalPlayer:GetAttribute(Config.Attr.InMatch) == true then
				NpcController.Close()
			end
		end)
	end
end

return NpcController
