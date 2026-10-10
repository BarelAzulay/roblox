-- IndexController (client, v3): the Pet Index window (ARCHITECTURE_V3.md section 3, 10 and 11).
--
--   IndexController.Init()
--   IndexController.Open(groupId|nil)    -- groupId = a rarity id ("Common" .. "Secret"); nil = last / best group
--   IndexController.Close()
--   Extras: IndexController.IsOpen() -> bool, IndexController.ClaimableCount() -> n,
--           IndexController.Opened (Util.Signal, Fire(groupId) when the window opens),
--           IndexController.Closed (Util.Signal, Fire() when it closes)
--
-- MenuController opens it from the menu "Index" tile and from OpenPanel("Index"), and relays Opened as
-- MenuController.WindowOpened("Index") (the tutorial listens there). This module never requires
-- MenuController (no require cycle).
--
-- Layout (cloud-styled through CloudUI, like the reference "Pet Index" window):
--   title bar "Pet Index" + red X
--   left    vertical group list: one rarity-coloured gradient tile per rarity group with "3/6" progress,
--           a check when its reward is claimed and a red "!" when it can be claimed; an "Elements" card button
--   centre  group header with an x/N progress bar, a grid of pet tiles (ViewportFrame of the pet; pets not
--           discovered yet are black silhouettes via ViewportFrame.ImageColor3 = (0, 0, 0) with a "???"
--           caption), and the rewards box ("Rewards:" + the token amount) with a CLAIM button (green when
--           claimable, grey otherwise, "Claimed" when done) -> Remotes.IndexClaim(groupId)
--   right   detail card: big viewport, name or "???", rarity, element badge with "Strong vs / Weak vs",
--           Role, stats and the special attack once discovered (Stormfang also shows its 2D art banner)
--   footer  "Unlocked: x/N" over every pet in the catalog
-- The window is designed in 1080p pixels (readability rule: body 19, captions >= 18, buttons 22+, titles
-- 28-34) under ONE UIScale = min(screen factor, fit); its size adapts between 900x420 and 1240x760 design
-- pixels so phones keep a readable scale, every column scrolls when space is short.
-- Pet viewports are built under a per-frame time budget (only for the shown group), silhouettes never animate,
-- and every viewport runs on CloudUI's one shared update loop. Esc / gamepad B / the X / a click outside closes it.
--
-- Remotes: IndexClaim (out, rate-limited here and validated + rate-limited by the server).
-- Plain Lua 5.1-compatible syntax only. All text goes through Theme roles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Util = require(Shared:WaitForChild("Util"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent.Parent
local CloudUI = require(Client:WaitForChild("UI"):WaitForChild("CloudUI"))
local State = require(Client:WaitForChild("State"))

local function safeRequire(name)
	local ok, result = pcall(function()
		return require(Shared:WaitForChild(name, 10))
	end)
	if ok and type(result) == "table" then
		return result
	end
	warn("[IndexController] " .. name .. " is unavailable: " .. tostring(result))
	return nil
end

local PetCatalog = safeRequire("PetCatalog") or { Pets = {}, Get = function() return nil end }

local IndexController = {}
IndexController.Opened = Util.Signal()
IndexController.Closed = Util.Signal()

----------------------------------------------------------------------
-- Tunables (design pixels of a 1080p screen)
----------------------------------------------------------------------
local K = {
	PREF_W = 1240,
	PREF_H = 760,
	MIN_W = 800,
	MIN_H = 380,
	BUMPS = 28, -- room the panel's cloud bumps like to have above its top edge
	MARGIN = 12, -- screen px kept free around the window
	NARROW = 1100, -- below this design width the side columns get narrower
	SHORT = 560, -- below this design height the compact layout is used (landscape phones)
	GROUP_W = 236,
	GROUP_W_NARROW = 184,
	DETAIL_W = 336,
	DETAIL_W_NARROW = 264,
	GAP = 12,
	TILE_W = 126,
	TILE_H = 154,
	TILE_W_NARROW = 114,
	TILE_H_NARROW = 142,
	TILE_H_SHORT = 132,
	TILE_GAP = 10,
	HEADER_H = 58,
	HEADER_H_SHORT = 48,
	REWARD_H = 96,
	REWARD_H_SHORT = 62,
	FOOTER_H = 46,
	VIEW_H = 180,
	VIEW_H_SHORT = 140,
	GROUP_TILE_H = 72,
	GROUP_TILE_H_SHORT = 60,
	ELEMENTS_BTN_H = 52,
	ELEMENTS_BTN_H_SHORT = 44,
	-- pet viewports are attached under a per-frame TIME budget: the first of a frame always, more only while the
	-- frame has spent < TILE_BUDGET s and at most TILES_MAX (a first-time High sculpt of ~350 parts costs tens of
	-- ms, a cached clone a few: a fixed count hitched on fresh clients)
	TILE_BUDGET = 0.004,
	TILES_MAX = 3,
	CLAIM_GAP = 0.6, -- seconds between two IndexClaim sends
	CLAIM_TIMEOUT = 5, -- seconds the CLAIM button waits for the server before it resets
	BACK_ACTION = "NimbusIndexBack",
	DISPLAY_ORDER = 21, -- above NimbusMenu (20): on small screens the window may cover the menu column
}

local Colors = Theme.Colors
local WHITE = Colors.White
local NAVY = Colors.Navy or Colors.Ink
local MUTED = Colors.Muted or Colors.CloudShade
local GOLD = Colors.Gold or Colors.Token
local INK = Colors.TextStroke or Colors.Ink
local GOOD = Colors.Good
local BAD = Colors.Bad
local BUTTONS = Theme.Buttons or {}
local ACCENT = Color3.fromRGB(70, 182, 196) -- the Index teal (menu tile + title bar)
local INSET = Color3.fromRGB(20, 30, 70)
local SILHOUETTE = Color3.new(0, 0, 0)
local TOKEN_GLYPH = (Theme.Currency and Theme.Currency.Tokens and Theme.Currency.Tokens.Glyph) or "\226\152\129"
local ROLE_COLORS = { Economy = Color3.fromRGB(96, 196, 108), Combat = Color3.fromRGB(228, 104, 96) }
local G = {
	Check = "\226\156\147",
	Star = "\226\152\133",
	Arrow = "\226\150\182", -- right-pointing triangle
	Swap = "\226\135\132", -- left-right arrows
	Book = "\240\159\147\150",
	Sparkle = "\226\156\166",
}

----------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------
local initialized = false
local LocalPlayer = nil
local U = {} -- UI references
local S = {
	Built = false,
	Open = false,
	Token = 0, -- bumps on every open / close (cancels stale delays)
	GroupId = nil, -- selected group
	PetId = nil, -- selected pet
	Groups = {}, -- PetCatalog.IndexGroups() result
	GroupById = {},
	GroupTiles = {}, -- groupId -> tile widgets
	Tiles = {}, -- petId -> tile widgets of the shown group
	TileOrder = {},
	Filling = false,
	DetailKey = nil, -- "<petId>|<discovered>" of the detail viewport
	DetailViewport = nil,
	DetailPills = {},
	PillKey = nil,
	Narrow = false,
	ClaimPending = nil, -- groupId while a claim waits for the server
	ClaimToken = 0,
	LastClaim = 0,
	BackBound = false,
	ElementsShown = false,
	StatMax = nil,
}
local warned = {}
local claimRemote = nil

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function warnOnce(key, err)
	if not warned[key] then
		warned[key] = true
		warn("[IndexController] " .. tostring(key) .. ": " .. tostring(err))
	end
end

local function safe(key, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warnOnce(key, err)
	end
	return ok
end

local function makeFrame(parent, name, props)
	local p = props or {}
	p.Name = name
	if p.BackgroundTransparency == nil then
		p.BackgroundTransparency = 1
	end
	p.BorderSizePixel = 0
	p.Parent = parent
	return Util.Create("Frame", p)
end

-- Theme-styled TextLabel with a readable stroke + glyph outline.
local function makeText(parent, name, text, role, size, color, props)
	local p = { Name = name }
	if props then
		for key, value in pairs(props) do
			p[key] = value
		end
	end
	local label = Theme.Label(tostring(text), role, {
		Size = size,
		Color = color or WHITE,
		Stroke = 0.25,
		StrokeColor = INK,
		Outline = 1.5,
		OutlineColor = INK,
		Props = p,
	})
	-- faint decorative text keeps a faint outline (an opaque outline around see-through text looks wrong)
	local faded = tonumber(p.TextTransparency)
	if faded and faded > 0 then
		local outline = label:FindFirstChild("TextOutline")
		if outline then
			outline.Transparency = math.min(1, faded + 0.2)
		end
	end
	label.Parent = parent
	return label
end

local function corner(parent, radius)
	return Theme.Corner(parent, UDim.new(0, radius or 12))
end

local function round(parent)
	return Theme.Corner(parent, UDim.new(0.5, 0))
end

local function stroke(parent, color, thickness, transparency)
	return Theme.Stroke(parent, color or NAVY, thickness or 3, transparency or 0)
end

local function pad(parent, left, top, right, bottom)
	return Util.Create("UIPadding", {
		PaddingLeft = UDim.new(0, left or 0),
		PaddingTop = UDim.new(0, top or 0),
		PaddingRight = UDim.new(0, right or 0),
		PaddingBottom = UDim.new(0, bottom or 0),
		Parent = parent,
	})
end

local function listLayout(parent, direction, gap, hAlign, vAlign)
	return Util.Create("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, gap or 0),
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
		Parent = parent,
	})
end

local function scroller(parent, name, props)
	local p = props or {}
	p.Name = name
	p.BackgroundTransparency = 1
	p.BorderSizePixel = 0
	p.CanvasSize = UDim2.new(0, 0, 0, 0)
	p.AutomaticCanvasSize = Enum.AutomaticSize.Y
	p.ScrollingDirection = Enum.ScrollingDirection.Y
	p.ScrollBarThickness = 10
	p.ScrollBarImageColor3 = Colors.FrameTop or Colors.Cloud
	p.ScrollBarImageTransparency = 0.1
	p.Parent = parent
	return Util.Create("ScrollingFrame", p)
end

local function tween(inst, seconds, goal, style, direction)
	return Util.Tween(inst, seconds, goal, style, direction)
end

local function inset(parent, name, props)
	local p = props or {}
	p.BackgroundColor3 = INSET
	p.BackgroundTransparency = 0.42
	local frame = makeFrame(parent, name, p)
	corner(frame, 12)
	stroke(frame, Colors.WellEdge or NAVY, 3, 0.15)
	return frame
end

local function rarityColor(rarityId)
	return CloudUI.RarityColor(rarityId)
end

-- A rarity colour that still reads as a colour on dark panels (the Secret rarity is near-black).
local function rarityAccent(rarityId)
	local color = rarityColor(rarityId)
	if rarityId == "Secret" then
		return Color3.fromRGB(150, 110, 232)
	end
	return color
end

local function commas(n)
	return Util.Commas(tonumber(n) or 0)
end

----------------------------------------------------------------------
-- Data helpers
----------------------------------------------------------------------
local function loadGroups()
	local groups = {}
	if type(PetCatalog.IndexGroups) == "function" then
		local ok, result = pcall(PetCatalog.IndexGroups)
		if ok and type(result) == "table" then
			groups = result
		end
	end
	if #groups == 0 then
		-- older catalog: one group per rarity from the pet list
		local byRarity = {}
		for _, def in ipairs(PetCatalog.Pets or {}) do
			local id = def.Rarity
			if type(id) == "string" then
				if not byRarity[id] then
					local rewards = Config.Index and Config.Index.Rewards or {}
					byRarity[id] = { Id = id, Rarity = id, Pets = {}, Reward = rewards[id] or { Tokens = 0 } }
				end
				table.insert(byRarity[id].Pets, def)
			end
		end
		for _, r in ipairs(Config.Rarities) do
			if byRarity[r.Id] then
				table.insert(groups, byRarity[r.Id])
			end
		end
	end
	local clean = {}
	for _, group in ipairs(groups) do
		if type(group) == "table" and type(group.Id) == "string" and type(group.Pets) == "table" and #group.Pets > 0 then
			table.insert(clean, group)
		end
	end
	S.Groups = clean
	S.GroupById = {}
	for _, group in ipairs(clean) do
		S.GroupById[group.Id] = group
	end
end

local function totalPets()
	if type(PetCatalog.TotalCount) == "function" then
		local ok, n = pcall(PetCatalog.TotalCount)
		if ok and type(n) == "number" then
			return n
		end
	end
	return #(PetCatalog.Pets or {})
end

local function unlockedCount()
	local n = 0
	for _, def in ipairs(PetCatalog.Pets or {}) do
		if State.IsDiscovered(def.Id) then
			n = n + 1
		end
	end
	return n
end

-- found, total, complete, claimed, claimable
local function groupStatus(group)
	local found = 0
	for _, def in ipairs(group.Pets) do
		if State.IsDiscovered(def.Id) then
			found = found + 1
		end
	end
	local total = #group.Pets
	local complete = total > 0 and found >= total
	local claimed = State.IsClaimed(group.Id)
	return found, total, complete, claimed, complete and not claimed
end

local function rewardTokens(group)
	local reward = group and group.Reward
	if type(reward) ~= "table" then
		local rewards = Config.Index and Config.Index.Rewards
		reward = rewards and group and rewards[group.Id]
	end
	if type(reward) == "table" and type(reward.Tokens) == "number" then
		return reward.Tokens
	end
	return 0
end

-- Element ids of a pet (v3 section 11), filtered by Config.Elements; empty while the catalog has none.
local function elementsOf(def)
	local info = Config.Elements and Config.Elements.Info
	if type(def) ~= "table" or type(info) ~= "table" then
		return {}
	end
	local raw = nil
	if type(PetCatalog.ElementsOf) == "function" then
		local ok, result = pcall(PetCatalog.ElementsOf, def)
		if ok then
			raw = result
		end
	end
	if raw == nil and type(PetCatalog.GetElements) == "function" then
		local ok, result = pcall(PetCatalog.GetElements, def.Id)
		if ok then
			raw = result
		end
	end
	if raw == nil then
		raw = def.Elements or def.Element
	end
	if type(raw) == "string" then
		raw = { raw }
	end
	local out, seen = {}, {}
	if type(raw) == "table" then
		for _, e in ipairs(raw) do
			if type(e) == "string" and info[e] and not seen[e] then
				seen[e] = true
				table.insert(out, e)
			end
		end
	end
	return out
end

local function elementColor(element)
	local info = Config.Elements and Config.Elements.Info and Config.Elements.Info[element]
	return info and info.Color or Colors.PanelLight
end

-- "Strong vs Flame  /  Weak vs Storm" for one element.
local function matchupText(element)
	local strongMap = Config.Elements and Config.Elements.Strong
	if type(strongMap) ~= "table" then
		return ""
	end
	local strong = {}
	for _, e in ipairs(strongMap[element] or {}) do
		table.insert(strong, e)
	end
	local weak = {}
	for attacker, list in pairs(strongMap) do
		for _, e in ipairs(list) do
			if e == element then
				table.insert(weak, attacker)
			end
		end
	end
	table.sort(weak)
	local parts = {}
	if #strong > 0 then
		table.insert(parts, "Strong vs " .. table.concat(strong, ", "))
	end
	if #weak > 0 then
		table.insert(parts, "Weak vs " .. table.concat(weak, ", "))
	end
	return table.concat(parts, "   " .. "/" .. "   ")
end

-- The highest base stat of the catalog per key at level 1 (bar lengths are relative to it).
local function statMax()
	if S.StatMax then
		return S.StatMax
	end
	local out = {}
	local keys = PetCatalog.StatOrder or { "Income", "Power", "Health", "Speed" }
	for _, key in ipairs(keys) do
		out[key] = 1
	end
	if type(PetCatalog.GetStats) == "function" then
		for _, def in ipairs(PetCatalog.Pets or {}) do
			local ok, stats = pcall(PetCatalog.GetStats, def.Id, 1)
			if ok and type(stats) == "table" then
				for _, key in ipairs(keys) do
					local v = stats[key]
					if type(v) == "number" and v > out[key] then
						out[key] = v
					end
				end
			end
		end
	end
	S.StatMax = out
	return out
end

-- Where a pet can be found ("Cloud Roulette, Storm Roulette"), or nil.
local function sourcesText(def)
	if type(PetCatalog.PossiblePets) ~= "function" then
		return nil
	end
	local names = {}
	for _, roulette in ipairs(Config.Roulettes or {}) do
		local ok, list = pcall(PetCatalog.PossiblePets, roulette.Id)
		if ok and type(list) == "table" then
			for _, entry in ipairs(list) do
				if entry == def or (type(entry) == "table" and entry.Id == def.Id) then
					table.insert(names, roulette.DisplayName or roulette.Id)
					break
				end
			end
		end
	end
	if #names == 0 then
		return nil
	end
	return table.concat(names, ", ")
end

local function getClaimRemote()
	if claimRemote then
		return claimRemote
	end
	local ok, remote = pcall(Remotes.Get, "IndexClaim")
	if ok and remote then
		claimRemote = remote
	end
	return claimRemote
end

----------------------------------------------------------------------
-- Visual helpers
----------------------------------------------------------------------
-- CloudUI.Pill with a text size that stays >= 14 px at the phone scale (0.8).
local function readablePill(text, kind, parent)
	local pill = CloudUI.Pill(text, kind, parent)
	if pill then
		pill.TextSize = math.max(pill.TextSize, 18)
	end
	return pill
end

-- Small coloured pill with the element name (no asset ids).
local function elementPill(parent, element, textSize, layoutOrder)
	local color = elementColor(element)
	local dark = Theme.Darken(color, 0.62)
	local pill = Theme.Label(element, "Heading", {
		Size = textSize or 17,
		Color = WHITE,
		Stroke = 0.1,
		StrokeColor = dark,
		Outline = 1.5,
		OutlineColor = dark,
		Props = {
			Name = "Element_" .. element,
			BackgroundTransparency = 0,
			BackgroundColor3 = color,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, (textSize or 17) + 9),
			LayoutOrder = layoutOrder or 0,
			ZIndex = 4,
		},
	})
	round(pill)
	stroke(pill, NAVY, 2, 0)
	Theme.Gradient(pill, Color3.fromRGB(255, 255, 255), Color3.fromRGB(196, 204, 226), 90)
	pad(pill, 9, 0, 9, 1)
	pill.Parent = parent
	return pill
end

-- Confetti squares flying out of `centre` (a UDim2 inside `parent`).
local function burst(parent, color, amount, centre)
	local rng = Random.new()
	for i = 1, amount do
		local size = rng:NextInteger(8, 14)
		local pieceColor = color
		if i % 3 == 0 then
			pieceColor = GOLD
		elseif i % 3 == 1 then
			pieceColor = Theme.Lighten(color, 0.5)
		end
		local piece = makeFrame(parent, "Confetti", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = centre,
			Size = UDim2.fromOffset(size, size),
			BackgroundTransparency = 0,
			BackgroundColor3 = pieceColor,
			Rotation = rng:NextInteger(0, 90),
			ZIndex = 12,
		})
		corner(piece, 2)
		local angle = rng:NextNumber(0, math.pi * 2)
		local distance = rng:NextNumber(60, 170)
		local target = UDim2.new(
			centre.X.Scale,
			centre.X.Offset + math.cos(angle) * distance,
			centre.Y.Scale,
			centre.Y.Offset + math.sin(angle) * distance * 0.7 - 20
		)
		local seconds = rng:NextNumber(0.6, 1.1)
		tween(piece, seconds, { Position = target, Rotation = piece.Rotation + rng:NextInteger(-200, 200) })
		tween(piece, seconds, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Debris:AddItem(piece, seconds + 0.1)
	end
end

----------------------------------------------------------------------
-- Layout (readability rule + fit, keeps clear of the menu column)
----------------------------------------------------------------------
local function guiSize()
	local size = U.Gui and U.Gui.AbsoluteSize or Vector2.new(1280, 720)
	if size.X < 2 or size.Y < 2 then
		return Vector2.new(1280, 720)
	end
	return size
end

local function viewportHeight()
	local camera = workspace.CurrentCamera
	local vp = camera and camera.ViewportSize
	if vp and vp.Y > 2 then
		return vp.Y
	end
	return guiSize().Y
end

-- Right edge (gui px) of MenuController's column when it is on screen, else 0.
local function menuColumnRight()
	local pg = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local menu = pg and pg:FindFirstChild("NimbusMenu")
	local column = menu and menu:FindFirstChild("MenuColumn")
	if column and column:IsA("GuiObject") and column.Visible and menu:IsA("ScreenGui") and menu.Enabled then
		local right = column.AbsolutePosition.X + column.AbsoluteSize.X
		if right > 0 and right < guiSize().X * 0.5 then
			return right
		end
	end
	return 0
end

local function renderFooter()
	local total = totalPets()
	local unlocked = unlockedCount()
	if U.FooterText then
		U.FooterText.Text = string.format("Unlocked: %d/%d", unlocked, total)
		U.FooterFill.Size = UDim2.new(total > 0 and unlocked / total or 0, 0, 1, 0)
		U.FooterPercent.Text = string.format("%d%%", total > 0 and math.floor(unlocked / total * 100) or 0)
	end
	-- the compact layout has no footer: the title carries the count
	if U.Panel then
		if S.Short then
			U.Panel.SetTitle(string.format("%s Pet Index   Unlocked: %d/%d", G.Book, unlocked, total))
		else
			U.Panel.SetTitle(G.Book .. " Pet Index")
		end
	end
end

-- Design size + scale + centre of the window. The window gets its preferred size when the screen has room
-- at the readability scale, shrinks towards its minimum size first and only then is scaled below the screen
-- factor; it keeps clear of the menu column unless covering the column buys a bigger (more readable) scale.
local function fitWindow()
	local area = guiSize()
	local factor = Theme.ScreenFactor(viewportHeight())
	local freeH = area.Y - 2 * K.MARGIN
	local function solve(left)
		local freeW = area.X - left - 2 * K.MARGIN
		local w = Util.Clamp(math.floor(freeW / factor), K.MIN_W, K.PREF_W)
		local h = Util.Clamp(math.floor((freeH - K.BUMPS * factor) / factor), K.MIN_H, K.PREF_H)
		local scale = Util.Clamp(math.min(factor, freeW / w, freeH / h), 0.3, 1.25)
		return w, h, scale
	end
	local left = menuColumnRight()
	local w, h, scale = solve(left)
	if left > 0 and scale < factor - 0.001 then
		local w2, h2, scale2 = solve(0)
		if scale2 > scale + 0.001 then
			w, h, scale, left = w2, h2, scale2, 0
		end
	end
	local half = w * scale / 2
	local x = math.max(area.X / 2, left + K.MARGIN + half)
	x = math.min(x, area.X - K.MARGIN - half)
	local halfH = h * scale / 2
	local y = math.min(area.Y / 2 + K.BUMPS * scale / 2, area.Y - K.MARGIN / 2 - halfH)
	y = math.max(y, halfH)
	return w, h, scale, x, y
end

local function relayout()
	if not S.Built then
		return
	end
	local w, h, scale, x, y = fitWindow()
	U.Holder.Size = UDim2.fromOffset(w, h)
	U.Fit.Scale = scale
	U.Holder.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))

	-- narrow windows get narrower side columns, short ones the compact layout
	local narrow = w < K.NARROW
	local short = h < K.SHORT
	S.Narrow, S.Short = narrow, short
	local groupW = narrow and K.GROUP_W_NARROW or K.GROUP_W
	local detailW = narrow and K.DETAIL_W_NARROW or K.DETAIL_W
	local headerH = short and K.HEADER_H_SHORT or K.HEADER_H
	local rewardH = short and K.REWARD_H_SHORT or K.REWARD_H
	local footerH = short and 0 or K.FOOTER_H
	U.Main.Size = UDim2.new(1, -20, 1, -(20 + footerH))
	U.Footer.Visible = not short
	U.Groups.Size = UDim2.new(0, groupW, 1, 0)
	U.Detail.Size = UDim2.new(0, detailW, 1, 0)
	U.Centre.Position = UDim2.new(0, groupW + K.GAP, 0, 0)
	U.Centre.Size = UDim2.new(1, -(groupW + detailW + 2 * K.GAP), 1, 0)
	U.Header.Size = UDim2.new(1, 0, 0, headerH)
	U.GridWell.Position = UDim2.fromOffset(0, headerH + 8)
	U.GridWell.Size = UDim2.new(1, 0, 1, -(headerH + 8 + rewardH + 8))
	U.Rewards.Size = UDim2.new(1, 0, 0, rewardH)
	U.RewardSub.Visible = not short
	U.RewardLabel.Visible = not (short and narrow)
	if short then
		U.RewardLabel.AnchorPoint = Vector2.new(0, 0.5)
		U.RewardLabel.Position = UDim2.new(0, 14, 0.5, 0)
		U.RewardAmount.AnchorPoint = Vector2.new(0, 0.5)
		U.RewardAmount.Position = UDim2.new(0, narrow and 14 or 128, 0.5, 0)
		U.RewardAmount.Size = UDim2.new(1, -(narrow and 180 or 294), 0, 34)
		U.ClaimButton.Size = UDim2.fromOffset(150, 52)
		U.ClaimGlow.Size = UDim2.fromOffset(150 + 14, 52 + 10)
		U.ClaimGlow.Position = UDim2.new(1, -14 - 75, 0.5, 0)
	else
		U.RewardLabel.AnchorPoint = Vector2.new(0, 0)
		U.RewardLabel.Position = UDim2.fromOffset(16, 8)
		U.RewardAmount.AnchorPoint = Vector2.new(0, 0)
		U.RewardAmount.Position = UDim2.fromOffset(140, 6)
		U.RewardAmount.Size = UDim2.new(1, -350, 0, 32)
		U.ClaimButton.Size = UDim2.fromOffset(184, 60)
		U.ClaimGlow.Size = UDim2.fromOffset(184 + 16, 60 + 16)
		U.ClaimGlow.Position = UDim2.new(1, -14 - 92, 0.5, 0)
	end
	if U.ElementsCard then
		U.ElementsCard.Size = UDim2.new(1, 0, 1, -(rewardH + 8))
	end
	U.View.Size = UDim2.new(1, 0, 0, short and K.VIEW_H_SHORT or K.VIEW_H)
	local tileH = short and K.GROUP_TILE_H_SHORT or K.GROUP_TILE_H
	for _, tile in pairs(S.GroupTiles) do
		tile.Button.Size = UDim2.new(1, -10, 0, tileH)
	end
	if U.ElementsButton then
		local buttonH = short and K.ELEMENTS_BTN_H_SHORT or K.ELEMENTS_BTN_H
		U.ElementsButton.Size = UDim2.new(1, -10, 0, buttonH)
		U.GroupList.Size = UDim2.new(1, 0, 1, -(buttonH + 8))
	end
	local petW = narrow and K.TILE_W_NARROW or K.TILE_W
	local petH = narrow and K.TILE_H_NARROW or K.TILE_H
	if short then
		petH = math.min(petH, K.TILE_H_SHORT)
	end
	U.GridLayout.CellSize = UDim2.fromOffset(petW, petH)
	renderFooter()
end

----------------------------------------------------------------------
-- Back button (gamepad B) while the window is open
----------------------------------------------------------------------
local function onBackAction(_name, inputState)
	if inputState == Enum.UserInputState.Begin and S.Open then
		IndexController.Close()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function syncBackBinding()
	if S.Open == S.BackBound then
		return
	end
	S.BackBound = S.Open
	if S.Open then
		local ok, err = pcall(function()
			ContextActionService:BindActionAtPriority(K.BACK_ACTION, onBackAction, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonB)
		end)
		if not ok then
			warnOnce("bind back", err)
		end
	else
		task.defer(function()
			if not S.BackBound then
				pcall(function()
					ContextActionService:UnbindAction(K.BACK_ACTION)
				end)
			end
		end)
	end
end

----------------------------------------------------------------------
-- Group list (left)
----------------------------------------------------------------------
local refreshAll, selectGroup, selectPet, renderDetail, showElements

local function buildGroupTile(group, index)
	local color = rarityColor(group.Rarity)
	local accent = rarityAccent(group.Rarity)
	local tile = { Group = group }
	local button = Util.Create("TextButton", {
		Name = "Group_" .. group.Id,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = "",
		BackgroundColor3 = WHITE,
		Size = UDim2.new(1, -10, 0, K.GROUP_TILE_H),
		LayoutOrder = index,
		Parent = U.GroupList,
	})
	corner(button, 14)
	tile.Stroke = stroke(button, NAVY, 3, 0)
	-- rarity art: a diagonal gradient, a pale gloss band and a big faint glyph on the right
	local top, bottom = Theme.Lighten(color, 0.12), Theme.Darken(color, 0.42)
	if group.Rarity == "Secret" then
		top, bottom = Color3.fromRGB(118, 78, 196), Color3.fromRGB(26, 34, 70)
	end
	local gradient = Util.Create("UIGradient", {
		Color = ColorSequence.new(top, bottom),
		Rotation = 60,
		Parent = button,
	})
	tile.Gradient = gradient
	local gloss = makeFrame(button, "Gloss", {
		BackgroundTransparency = 0.8,
		BackgroundColor3 = WHITE,
		Position = UDim2.fromOffset(8, 4),
		Size = UDim2.new(1, -16, 0, 10),
	})
	round(gloss)
	makeText(button, "Art", G.Star, "Title", 38, Theme.Lighten(accent, 0.5), {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 0),
		Size = UDim2.fromOffset(40, 40),
		TextTransparency = 0.45,
		TextStrokeTransparency = 1,
		Rotation = 12,
	})
	-- name on top, then a slim progress bar with the "3/6" count at its right end
	tile.Name = makeText(button, "GroupName", group.Rarity, "Title", 24, WHITE, {
		Position = UDim2.fromOffset(12, 4),
		Size = UDim2.new(1, -52, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
		ZIndex = 2,
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 17, Parent = tile.Name })
	tile.Progress = makeText(button, "Progress", "0/0", "Heading", 19, WHITE, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -4),
		Size = UDim2.fromOffset(58, 24),
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 2,
	})
	local track = makeFrame(button, "Track", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -11),
		Size = UDim2.new(1, -80, 0, 10),
		BackgroundTransparency = 0.2,
		BackgroundColor3 = Color3.fromRGB(14, 20, 52),
		ZIndex = 2,
	})
	round(track)
	stroke(track, NAVY, 1.5, 0)
	tile.Fill = makeFrame(track, "Fill", {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundTransparency = 0,
		BackgroundColor3 = Theme.Lighten(accent, 0.35),
		ZIndex = 3,
	})
	round(tile.Fill)
	-- top-right corner: a check when claimed, a red "!" when the reward waits
	tile.Badge = makeFrame(button, "Badge", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -8, 0, 8),
		Size = UDim2.fromOffset(28, 28),
		BackgroundTransparency = 0,
		BackgroundColor3 = BUTTONS.Red or BAD,
		Visible = false,
		ZIndex = 4,
	})
	round(tile.Badge)
	stroke(tile.Badge, NAVY, 2.5, 0)
	tile.BadgeText = makeText(tile.Badge, "Mark", "!", "Button", 19, WHITE, {
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 5,
	})
	tile.Pop = Util.Create("UIScale", { Name = "Pop", Scale = 1, Parent = button })
	button.MouseEnter:Connect(function()
		tween(tile.Pop, 0.12, { Scale = 1.03 })
	end)
	button.MouseLeave:Connect(function()
		tween(tile.Pop, 0.12, { Scale = 1 })
	end)
	button.Activated:Connect(function()
		safe("select group", selectGroup, group.Id)
	end)
	tile.Button = button
	S.GroupTiles[group.Id] = tile
	return tile
end

local function refreshGroupTiles()
	for _, group in ipairs(S.Groups) do
		local tile = S.GroupTiles[group.Id]
		if tile then
			local found, total, complete, claimed, claimable = groupStatus(group)
			tile.Progress.Text = string.format("%d/%d", found, total)
			tile.Fill.Size = UDim2.new(total > 0 and found / total or 0, 0, 1, 0)
			local selected = S.GroupId == group.Id
			tile.Stroke.Color = selected and GOLD or NAVY
			tile.Stroke.Thickness = selected and 4 or 3
			if claimable then
				tile.Badge.Visible = true
				tile.Badge.BackgroundColor3 = BUTTONS.Red or BAD
				tile.BadgeText.Text = "!"
			elseif claimed then
				tile.Badge.Visible = true
				tile.Badge.BackgroundColor3 = BUTTONS.Green or GOOD
				tile.BadgeText.Text = G.Check
			else
				tile.Badge.Visible = false
			end
			tile.Progress.TextColor3 = complete and Theme.Lighten(GOOD, 0.45) or WHITE
		end
	end
end

----------------------------------------------------------------------
-- Pet grid (centre)
----------------------------------------------------------------------
local function destroyTileViewport(tile)
	if tile.Viewport then
		pcall(tile.Viewport.Destroy)
		tile.Viewport = nil
	end
end

local function paintTile(tile)
	local def = tile.Def
	local discovered = State.IsDiscovered(def.Id)
	local selected = S.PetId == def.Id
	local color = rarityAccent(def.Rarity)
	if discovered then
		tile.Gradient.Color = ColorSequence.new(Theme.Lighten(color, 0.55), Theme.Darken(color, 0.12))
		tile.Caption.Text = def.Name
		tile.Caption.TextColor3 = WHITE
	else
		tile.Gradient.Color = ColorSequence.new(Color3.fromRGB(112, 132, 182), Color3.fromRGB(64, 80, 132))
		tile.Caption.Text = "???"
		tile.Caption.TextColor3 = MUTED
	end
	tile.Stroke.Color = selected and GOLD or (discovered and Theme.Darken(color, 0.25) or NAVY)
	tile.Stroke.Thickness = selected and 4 or 3
	if tile.Viewport then
		local frame = tile.Viewport.Frame
		if frame then
			frame.ImageColor3 = discovered and Color3.new(1, 1, 1) or SILHOUETTE
		end
		if tile.BuiltDiscovered ~= discovered then
			-- the pet was just discovered: rebuild with the discovered settings
			destroyTileViewport(tile)
		elseif discovered then
			tile.Viewport.SetAnimated(selected or tile.Hover)
		end
	end
	-- element badge, only once discovered (the tile has room for one; the detail card lists them all)
	local elements = discovered and elementsOf(def) or {}
	if #elements > 1 then
		elements = { elements[1] }
	end
	local key = table.concat(elements, ",")
	if tile.ElementKey ~= key then
		tile.ElementKey = key
		for _, child in ipairs(tile.Elements:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for i, element in ipairs(elements) do
			elementPill(tile.Elements, element, 18, i)
		end
	end
end

local function buildTileViewport(tile)
	local def = tile.Def
	local discovered = State.IsDiscovered(def.Id)
	local handle = CloudUI.PetViewport(tile.Art, def, UDim2.new(1, 0, 1, 0), {
		Animate = false,
		Spin = discovered and "sway" or "none",
		ZIndex = 3,
	})
	if not handle then
		return
	end
	if handle.Frame then
		handle.Frame.ImageColor3 = discovered and Color3.new(1, 1, 1) or SILHOUETTE
	end
	tile.Viewport = handle
	tile.BuiltDiscovered = discovered
	if discovered and (S.PetId == def.Id or tile.Hover) then
		handle.SetAnimated(true)
	end
end

-- Attaches the missing viewports while the window is open, under the per-frame time budget (K.TILE_BUDGET).
local function fillViewports()
	if S.Filling then
		return
	end
	S.Filling = true
	task.spawn(function()
		task.wait() -- the frame that opens the window already builds it (and the detail card's pet)
		while S.Open do
			local built, start, more = 0, os.clock(), false
			for _, id in ipairs(S.TileOrder) do
				local tile = S.Tiles[id]
				if tile and not tile.Viewport and tile.Button.Parent and (built >= K.TILES_MAX or (built > 0 and os.clock() - start >= K.TILE_BUDGET)) then
					more = true
					break
				end
				if tile and not tile.Viewport and tile.Button.Parent then
					local ok, err = pcall(buildTileViewport, tile)
					if not ok or not tile.Viewport then
						-- never retry a broken build every frame: park a no-op handle
						if not ok then
							warnOnce("tile viewport", err)
						end
						tile.Viewport = { Destroy = function() end, SetAnimated = function() end }
						tile.BuiltDiscovered = State.IsDiscovered(id)
					end
					built = built + 1
				end
			end
			if not more then
				break
			end
			task.wait()
		end
		S.Filling = false
	end)
end

local function clearTiles()
	for _, tile in pairs(S.Tiles) do
		destroyTileViewport(tile)
		tile.Button:Destroy()
	end
	S.Tiles = {}
	S.TileOrder = {}
end

local function buildTile(def, index)
	local tile = { Def = def, Hover = false }
	local button = Util.Create("TextButton", {
		Name = "IndexPet_" .. def.Id,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = "",
		BackgroundColor3 = WHITE,
		LayoutOrder = index,
		Parent = U.Grid,
	})
	corner(button, 14)
	tile.Stroke = stroke(button, NAVY, 3, 0)
	tile.Gradient = Util.Create("UIGradient", { Rotation = 90, Parent = button })
	local gloss = makeFrame(button, "Gloss", {
		BackgroundTransparency = 0.78,
		BackgroundColor3 = WHITE,
		Position = UDim2.fromOffset(7, 5),
		Size = UDim2.new(1, -14, 0.22, 0),
	})
	corner(gloss, 9)
	tile.Art = makeFrame(button, "Art", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(1, -12, 1, -44),
		ZIndex = 2,
	})
	local band = makeFrame(button, "NameBand", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -5),
		Size = UDim2.new(1, -10, 0, 32),
		BackgroundTransparency = 0.25,
		BackgroundColor3 = Color3.fromRGB(16, 24, 60),
		ZIndex = 3,
	})
	corner(band, 9)
	tile.Caption = makeText(band, "Caption", "???", "Heading", 18, WHITE, {
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.new(1, -8, 1, 0),
		TextScaled = true,
		ZIndex = 4,
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 18, MinTextSize = 13, Parent = tile.Caption })
	tile.Elements = makeFrame(button, "Elements", {
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.new(1, -12, 0, 26),
		ZIndex = 4,
	})
	listLayout(tile.Elements, Enum.FillDirection.Horizontal, 3, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
	tile.Pop = Util.Create("UIScale", { Name = "Pop", Scale = 1, Parent = button })
	button.MouseEnter:Connect(function()
		tile.Hover = true
		tween(tile.Pop, 0.12, { Scale = 1.05 })
		if tile.Viewport and tile.BuiltDiscovered then
			tile.Viewport.SetAnimated(true)
		end
	end)
	button.MouseLeave:Connect(function()
		tile.Hover = false
		tween(tile.Pop, 0.12, { Scale = 1 })
		if tile.Viewport and tile.BuiltDiscovered then
			tile.Viewport.SetAnimated(S.PetId == def.Id)
		end
	end)
	button.Activated:Connect(function()
		safe("select pet", selectPet, def.Id)
	end)
	tile.Button = button
	S.Tiles[def.Id] = tile
	table.insert(S.TileOrder, def.Id)
	paintTile(tile)
	return tile
end

local function refreshTiles()
	for _, tile in pairs(S.Tiles) do
		paintTile(tile)
	end
	fillViewports()
end

local function renderHeader()
	local group = S.GroupById[S.GroupId]
	if not group then
		return
	end
	local found, total, complete = groupStatus(group)
	local accent = rarityAccent(group.Rarity)
	U.GroupTitle.Text = group.Rarity .. " Pets"
	U.GroupTitle.TextColor3 = Theme.Lighten(accent, 0.4)
	U.HeaderFill.Size = UDim2.new(total > 0 and found / total or 0, 0, 1, 0)
	U.HeaderFill.BackgroundColor3 = complete and (BUTTONS.Green or GOOD) or Theme.Lighten(accent, 0.15)
	U.HeaderCount.Text = string.format("%d/%d", found, total)
end

local function renderRewards()
	local group = S.GroupById[S.GroupId]
	if not group then
		return
	end
	local found, total, complete, claimed, claimable = groupStatus(group)
	U.RewardAmount.Text = TOKEN_GLYPH .. " " .. commas(rewardTokens(group))
	local button = U.ClaimButton
	local pending = S.ClaimPending == group.Id and not claimed
	if claimed then
		U.RewardSub.Text = "Reward claimed. Great collecting!"
		button.Text = "Claimed"
		CloudUI.SetStyle(button, "Gray")
		CloudUI.SetDisabled(button, true)
	elseif pending then
		U.RewardSub.Text = "Claiming your reward..."
		button.Text = "..."
		CloudUI.SetStyle(button, "Green")
		CloudUI.SetDisabled(button, true)
	elseif claimable then
		U.RewardSub.Text = "Every " .. group.Rarity .. " pet found. Claim it!"
		button.Text = "CLAIM"
		CloudUI.SetStyle(button, "Green")
		CloudUI.SetDisabled(button, false)
	else
		U.RewardSub.Text = string.format("Discover all %d %s pets (%d to go).", total, group.Rarity, total - found)
		button.Text = "CLAIM"
		CloudUI.SetStyle(button, "Gray")
		CloudUI.SetDisabled(button, true)
	end
	U.RewardSub.TextColor3 = claimable and Theme.Lighten(GOOD, 0.45) or MUTED
	-- a soft glow pulses behind the button while the reward waits
	if claimable and not pending then
		U.ClaimGlow.Visible = true
		if not U.ClaimPulse then
			U.ClaimGlow.BackgroundTransparency = 0.75
			U.ClaimPulse = TweenService:Create(
				U.ClaimGlow,
				TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ BackgroundTransparency = 0.2 }
			)
			U.ClaimPulse:Play()
		end
	else
		if U.ClaimPulse then
			U.ClaimPulse:Cancel()
			U.ClaimPulse = nil
		end
		U.ClaimGlow.Visible = false
	end
end

----------------------------------------------------------------------
-- Detail card (right)
----------------------------------------------------------------------
local function clearDetailPills()
	for _, pill in ipairs(S.DetailPills) do
		if pill.Parent then
			pill:Destroy()
		end
	end
	S.DetailPills = {}
end

function renderDetail()
	local def = S.PetId and PetCatalog.Get(S.PetId) or nil
	if not def then
		U.DetailBody.Visible = false
		U.DetailEmpty.Visible = true
		if S.DetailViewport then
			pcall(S.DetailViewport.Destroy)
			S.DetailViewport = nil
			S.DetailKey = nil
		end
		return
	end
	U.DetailBody.Visible = true
	U.DetailEmpty.Visible = false
	local discovered = State.IsDiscovered(def.Id)
	local accent = rarityAccent(def.Rarity)

	-- viewport: spinning when discovered, a still black silhouette otherwise
	local key = def.Id .. "|" .. tostring(discovered)
	if S.DetailKey ~= key then
		if S.DetailViewport then
			pcall(S.DetailViewport.Destroy)
			S.DetailViewport = nil
		end
		local ok, handle = pcall(CloudUI.PetViewport, U.ViewHolder, def, UDim2.new(1, 0, 1, 0), {
			Animate = discovered,
			Spin = discovered and "spin" or "none",
			ZIndex = 4,
		})
		if ok and handle then
			S.DetailViewport = handle
			if handle.Frame then
				handle.Frame.ImageColor3 = discovered and Color3.new(1, 1, 1) or SILHOUETTE
			end
		else
			warnOnce("detail viewport", handle)
		end
		S.DetailKey = key
	end
	for _, glow in ipairs(U.Glows) do
		glow.BackgroundColor3 = Theme.Lighten(accent, 0.25)
	end
	U.Mystery.Visible = not discovered

	-- Stormfang (the player's own creature) shows its 2D art once discovered
	local art = Config.Art and Config.Art.StormfangImage
	U.Banner.Visible = discovered and def.Id == "stormfang" and type(art) == "string" and art ~= ""
	if U.Banner.Visible then
		U.Banner.Image = art
	end

	U.Name.Text = discovered and def.Name or "???"
	U.Name.TextColor3 = discovered and Theme.Lighten(accent, 0.45) or MUTED

	-- meta: rarity, element and role pills (rebuilt only when they change)
	local elements = discovered and elementsOf(def) or {}
	local role = discovered and def.Role or nil
	local pillKey = tostring(def.Rarity) .. "|" .. table.concat(elements, ",") .. "|" .. tostring(role)
	if S.PillKey ~= pillKey then
		S.PillKey = pillKey
		clearDetailPills()
		local rarityPill = readablePill(def.Rarity, rarityColor(def.Rarity), U.Meta)
		rarityPill.LayoutOrder = 1
		table.insert(S.DetailPills, rarityPill)
		for i, element in ipairs(elements) do
			table.insert(S.DetailPills, elementPill(U.Meta, element, 18, 1 + i))
		end
		if role then
			local rolePill = readablePill(role, ROLE_COLORS[role] or BUTTONS.Blue, U.Meta)
			rolePill.LayoutOrder = 50
			table.insert(S.DetailPills, rolePill)
		end
	end
	U.RoleBlurb.Visible = role ~= nil
	if role then
		local blurbs = PetCatalog.RoleBlurbs or {}
		U.RoleBlurb.Text = blurbs[role] or ""
	end

	-- stats: real numbers once discovered, locked "?" rows before
	local stats = nil
	if discovered and type(PetCatalog.GetStats) == "function" then
		local ok, result = pcall(PetCatalog.GetStats, def.Id, 1)
		if ok and type(result) == "table" then
			stats = result
		end
	end
	local maxes = statMax()
	for statKey, row in pairs(U.StatRows) do
		local value = stats and stats[statKey]
		if type(value) == "number" then
			row.Value.Text = commas(math.floor(value + 0.5))
			row.Value.TextColor3 = WHITE
			row.Fill.Size = UDim2.new(Util.Clamp(value / (maxes[statKey] or 1), 0.04, 1), 0, 1, 0)
		else
			row.Value.Text = "?"
			row.Value.TextColor3 = MUTED
			row.Fill.Size = UDim2.new(0, 0, 1, 0)
		end
	end

	-- special attack
	local special = discovered and type(def.Special) == "table" and def.Special or nil
	U.Special.Visible = special ~= nil
	if special then
		U.SpecialName.Text = tostring(special.Name or "Special")
		local color = typeof(special.Color) == "Color3" and special.Color or GOLD
		U.SpecialName.TextColor3 = Theme.Lighten(color, 0.35)
		U.SpecialKind.Text = tostring(special.Kind or "")
		U.SpecialKind.Visible = special.Kind ~= nil
	end

	-- element matchups
	local matchups = {}
	for _, element in ipairs(elements) do
		local text = matchupText(element)
		if text ~= "" then
			table.insert(matchups, element .. ": " .. text)
		end
	end
	U.Matchup.Visible = #matchups > 0
	U.Matchup.Text = table.concat(matchups, "\n")

	-- blurb or how to find it
	if discovered then
		U.Info.Text = tostring(def.Blurb or "")
		U.Info.TextColor3 = WHITE
		local owned = State.OwnedCount(def.Id)
		U.Owned.Visible = true
		if owned > 0 then
			U.Owned.Text = "You own x" .. owned
			U.Owned.TextColor3 = Theme.Lighten(GOOD, 0.4)
		else
			U.Owned.Text = "Discovered"
			U.Owned.TextColor3 = MUTED
		end
	else
		local where = sourcesText(def)
		if def.Rarity == "Secret" then
			U.Info.Text = "A Secret pet. It will be summoned at the Storm Altar with Gems."
		elseif where then
			U.Info.Text = "Not discovered yet. Found in: " .. where .. "."
		else
			U.Info.Text = "Not discovered yet."
		end
		U.Info.TextColor3 = MUTED
		U.Owned.Visible = false
	end
end

----------------------------------------------------------------------
-- Selection
----------------------------------------------------------------------
function selectPet(petId)
	S.PetId = petId
	for _, tile in pairs(S.Tiles) do
		paintTile(tile)
	end
	renderDetail()
end

local function defaultPetOf(group)
	-- the first discovered pet, else the first one
	for _, def in ipairs(group.Pets) do
		if State.IsDiscovered(def.Id) then
			return def.Id
		end
	end
	return group.Pets[1] and group.Pets[1].Id or nil
end

function selectGroup(groupId)
	local group = S.GroupById[groupId]
	if not group then
		return
	end
	local changed = S.GroupId ~= groupId or #S.TileOrder == 0
	S.GroupId = groupId
	if S.ElementsShown then
		showElements(false)
	end
	if changed then
		clearTiles()
		for index, def in ipairs(group.Pets) do
			buildTile(def, index)
		end
		U.Grid.CanvasPosition = Vector2.new(0, 0)
		local keep = false
		for _, def in ipairs(group.Pets) do
			if def.Id == S.PetId then
				keep = true
			end
		end
		if not keep then
			S.PetId = defaultPetOf(group)
		end
	end
	refreshGroupTiles()
	renderHeader()
	renderRewards()
	selectPet(S.PetId)
	fillViewports()
end

local function defaultGroup()
	-- a reward waiting first, then the first group still missing pets, else the first group
	for _, group in ipairs(S.Groups) do
		local _, _, _, _, claimable = groupStatus(group)
		if claimable then
			return group.Id
		end
	end
	for _, group in ipairs(S.Groups) do
		local _, _, complete = groupStatus(group)
		if not complete then
			return group.Id
		end
	end
	return S.Groups[1] and S.Groups[1].Id or nil
end

function refreshAll()
	if not S.Built then
		return
	end
	refreshGroupTiles()
	refreshTiles()
	renderHeader()
	renderRewards()
	renderFooter()
	renderDetail()
end

----------------------------------------------------------------------
-- Claim
----------------------------------------------------------------------
local function requestClaim()
	local group = S.GroupById[S.GroupId]
	if not group then
		return
	end
	local _, _, _, _, claimable = groupStatus(group)
	if not claimable or S.ClaimPending then
		return
	end
	local now = os.clock()
	if now - S.LastClaim < K.CLAIM_GAP then
		return
	end
	local remote = getClaimRemote()
	if not remote then
		return
	end
	S.LastClaim = now
	local ok = pcall(function()
		remote:FireServer(group.Id)
	end)
	if not ok then
		return
	end
	S.ClaimPending = group.Id
	S.ClaimToken = S.ClaimToken + 1
	local mine = S.ClaimToken
	renderRewards()
	task.delay(K.CLAIM_TIMEOUT, function()
		if S.ClaimToken == mine and S.ClaimPending then
			S.ClaimPending = nil
			if S.Built then
				renderRewards()
			end
		end
	end)
end

----------------------------------------------------------------------
-- Elements help card (the element wheel, section 11)
----------------------------------------------------------------------
local function elementCycle()
	local elements = Config.Elements
	if type(elements) ~= "table" or type(elements.Order) ~= "table" or type(elements.Strong) ~= "table" then
		return {}, {}
	end
	local cycle, inCycle = {}, {}
	local current = elements.Order[1]
	while current and not inCycle[current] and #cycle < #elements.Order do
		inCycle[current] = true
		table.insert(cycle, current)
		local nextList = elements.Strong[current]
		current = type(nextList) == "table" and nextList[1] or nil
	end
	if current ~= cycle[1] then
		-- not a closed wheel: show everything as plain pairs instead
		cycle, inCycle = {}, {}
	end
	local rest = {}
	for _, e in ipairs(elements.Order) do
		if not inCycle[e] then
			table.insert(rest, e)
		end
	end
	return cycle, rest
end

local function buildElementsCard()
	local card = makeFrame(U.Centre, "ElementsCard", {
		Size = UDim2.new(1, 0, 1, -(K.REWARD_H + 8)),
		BackgroundTransparency = 0.05,
		BackgroundColor3 = Color3.fromRGB(26, 38, 86),
		Visible = false,
		ZIndex = 20,
	})
	corner(card, 14)
	stroke(card, NAVY, 3, 0)
	U.ElementsCard = card
	local scroll = scroller(card, "Scroll", {
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.new(1, -12, 1, -12),
		ZIndex = 21,
	})
	pad(scroll, 10, 8, 14, 10)
	listLayout(scroll, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Center)
	makeText(scroll, "Title", "Elements", "Title", 30, WHITE, {
		Size = UDim2.new(1, 0, 0, 36),
		LayoutOrder = 1,
		ZIndex = 22,
	})
	makeText(scroll, "Explain", "Every pet has an element. In battles an element deals x1.5 damage to the one its arrow points at, and only x0.75 back.", "Body", 19, MUTED, {
		Size = UDim2.new(1, -10, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		LayoutOrder = 2,
		ZIndex = 22,
	})
	local cycle, rest = elementCycle()
	if #cycle >= 3 then
		local wheel = makeFrame(scroll, "Wheel", {
			Size = UDim2.new(1, 0, 0, 330),
			LayoutOrder = 3,
			ZIndex = 22,
		})
		Util.Create("UISizeConstraint", { MaxSize = Vector2.new(400, 330), Parent = wheel })
		local n = #cycle
		for i, element in ipairs(cycle) do
			local angle = math.rad(-90 + (i - 1) * 360 / n)
			local holder = makeFrame(wheel, "Slot_" .. element, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5 + math.cos(angle) * 0.35, 0, 0.5 + math.sin(angle) * 0.38, 0),
				Size = UDim2.fromOffset(100, 34),
				ZIndex = 22,
			})
			listLayout(holder, Enum.FillDirection.Horizontal, 0, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
			elementPill(holder, element, 18, 1)
			-- arrow half way to the next element, pointing clockwise (screen y grows downwards)
			local mid = angle + math.rad(180 / n)
			makeText(wheel, "Arrow" .. i, G.Arrow, "Title", 24, GOLD, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5 + math.cos(mid) * 0.41, 0, 0.5 + math.sin(mid) * 0.43, 0),
				Size = UDim2.fromOffset(28, 28),
				Rotation = math.deg(mid) + 90,
				ZIndex = 23,
			})
		end
		makeText(wheel, "Centre", "beats", "Script", 20, MUTED, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.fromOffset(120, 30),
			ZIndex = 22,
		})
	end
	-- the rest as mutual pairs (Celestial <-> Shadow)
	local strongMap = Config.Elements and Config.Elements.Strong or {}
	local done = {}
	local order = 4
	for _, element in ipairs(rest) do
		if not done[element] then
			done[element] = true
			local partner = type(strongMap[element]) == "table" and strongMap[element][1] or nil
			local row = makeFrame(scroll, "Pair_" .. element, {
				Size = UDim2.new(1, 0, 0, 36),
				LayoutOrder = order,
				ZIndex = 22,
			})
			order = order + 1
			listLayout(row, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
			elementPill(row, element, 18, 1)
			if partner and partner ~= element then
				done[partner] = true
				makeText(row, "Both", G.Swap, "Title", 24, GOLD, { Size = UDim2.fromOffset(34, 32), LayoutOrder = 2, ZIndex = 22 })
				elementPill(row, partner, 18, 3)
			end
		end
	end
	local back = CloudUI.Button({
		Name = "CloseElements",
		Text = "Back to pets",
		Style = "Blue",
		Size = UDim2.fromOffset(220, 52),
		TextSize = 22,
		LayoutOrder = 50,
		ZIndex = 22,
		Callback = function()
			showElements(false)
		end,
		Parent = scroll,
	})
	back.ZIndex = 22
end

function showElements(on)
	if not U.ElementsCard then
		if not on then
			return
		end
		buildElementsCard()
	end
	S.ElementsShown = on and true or false
	U.ElementsCard.Visible = S.ElementsShown
	if U.ElementsButton then
		U.ElementsButton.Text = S.ElementsShown and "Pets" or "Elements"
	end
end

----------------------------------------------------------------------
-- Window construction
----------------------------------------------------------------------
local function buildCentre(centre)
	-- header: group name + progress bar "x/N"
	local header = inset(centre, "GroupHeader", { Size = UDim2.new(1, 0, 0, K.HEADER_H) })
	U.Header = header
	U.GroupTitle = makeText(header, "GroupTitle", "", "Title", 28, WHITE, {
		Position = UDim2.fromOffset(16, 0),
		Size = UDim2.new(0.5, -16, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 28, MinTextSize = 18, Parent = U.GroupTitle })
	local track = makeFrame(header, "Progress", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.new(0.46, 0, 0, 30),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(14, 20, 52),
	})
	round(track)
	stroke(track, NAVY, 3, 0)
	U.HeaderFill = makeFrame(track, "Fill", {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundTransparency = 0,
		BackgroundColor3 = GOOD,
	})
	round(U.HeaderFill)
	Theme.Gradient(U.HeaderFill, Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 198, 222), 90)
	U.HeaderCount = makeText(track, "Count", "0/0", "Display", 22, WHITE, {
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 3,
	})

	-- the pet grid
	local well = inset(centre, "GridWell", {
		Position = UDim2.fromOffset(0, K.HEADER_H + 8),
		Size = UDim2.new(1, 0, 1, -(K.HEADER_H + 8 + K.REWARD_H + 8)),
	})
	U.GridWell = well
	U.Grid = scroller(well, "PetGrid", {
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(1, -8, 1, -8),
	})
	pad(U.Grid, 8, 8, 12, 8)
	U.GridLayout = Util.Create("UIGridLayout", {
		CellSize = UDim2.fromOffset(K.TILE_W, K.TILE_H),
		CellPadding = UDim2.fromOffset(K.TILE_GAP, K.TILE_GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = U.Grid,
	})

	-- rewards box + CLAIM
	local rewards = inset(centre, "Rewards", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, K.REWARD_H),
	})
	U.Rewards = rewards
	U.RewardLabel = makeText(rewards, "Label", "Rewards:", "Heading", 22, WHITE, {
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.fromOffset(120, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	U.RewardAmount = makeText(rewards, "Amount", "", "Display", 30, Colors.Token, {
		Position = UDim2.fromOffset(140, 6),
		Size = UDim2.new(1, -350, 0, 32),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	U.RewardSub = makeText(rewards, "Sub", "", "Body", 18, MUTED, {
		Position = UDim2.fromOffset(16, 44),
		Size = UDim2.new(1, -230, 0, 44),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	-- the glow is a sibling behind the button (the button's own UIScale is its hover effect)
	U.ClaimGlow = makeFrame(rewards, "ClaimGlow", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 0.6,
		BackgroundColor3 = Theme.Lighten(BUTTONS.Green or GOOD, 0.35),
		Visible = false,
		ZIndex = 1,
	})
	corner(U.ClaimGlow, 18)
	U.ClaimButton = CloudUI.Button({
		Name = "Claim",
		Text = "CLAIM",
		Style = "Gray",
		Size = UDim2.fromOffset(184, 60),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		TextSize = 26,
		ZIndex = 2,
		Callback = function()
			safe("claim", requestClaim)
		end,
		Parent = rewards,
	})
end

local function buildDetail(detail)
	U.DetailEmpty = makeText(detail, "Hint", "Pick a pet to see its card.", "Body", 19, MUTED, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(1, -40, 0, 60),
		TextWrapped = true,
	})
	local body = scroller(detail, "DetailBody", {
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(1, -8, 1, -8),
		Visible = false,
	})
	U.DetailBody = body
	pad(body, 10, 8, 14, 12)
	listLayout(body, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center)

	-- big viewport with a soft rarity glow and a "?" behind silhouettes
	local view = makeFrame(body, "View", { Size = UDim2.new(1, 0, 0, K.VIEW_H), LayoutOrder = 1 })
	U.View = view
	U.Glows = {}
	for i, disc in ipairs({ { 0.96, 0.84 }, { 0.72, 0.76 } }) do
		-- square discs sized by the view's height (the view is shorter in the compact layout)
		local glow = makeFrame(view, "Glow" .. i, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.fromScale(disc[1], disc[1]),
			BackgroundTransparency = disc[2],
			BackgroundColor3 = GOLD,
		})
		Util.Create("UIAspectRatioConstraint", { AspectRatio = 1, DominantAxis = Enum.DominantAxis.Height, Parent = glow })
		round(glow)
		table.insert(U.Glows, glow)
	end
	U.Mystery = makeText(view, "Mystery", "?", "Title", 100, Color3.fromRGB(120, 140, 196), {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.fromScale(0.6, 0.6),
		TextTransparency = 0.6,
		TextStrokeTransparency = 1,
		ZIndex = 2,
	})
	U.ViewHolder = makeFrame(view, "ViewHolder", { Size = UDim2.new(1, 0, 1, 0), ZIndex = 3 })

	U.Banner = Util.Create("ImageLabel", {
		Name = "ArtBanner",
		BackgroundColor3 = Color3.fromRGB(16, 22, 50),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 128),
		ScaleType = Enum.ScaleType.Crop,
		Visible = false,
		LayoutOrder = 2,
		Parent = body,
	})
	corner(U.Banner, 12)
	stroke(U.Banner, Color3.fromRGB(63, 200, 255), 3, 0)

	U.Name = makeText(body, "Name", "", "Title", 30, WHITE, {
		Size = UDim2.new(1, 0, 0, 36),
		TextScaled = true,
		LayoutOrder = 3,
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 18, Parent = U.Name })
	-- rarity, role and element pills share one row that wraps when the card is narrow
	U.Meta = makeFrame(body, "Meta", {
		Size = UDim2.new(1, 0, 0, 30),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 4,
	})
	local metaLayout = listLayout(U.Meta, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	metaLayout.Wraps = true
	U.RoleBlurb = makeText(body, "RoleBlurb", "", "Body", 18, MUTED, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		LayoutOrder = 6,
	})

	-- stats: label, bar, value
	local statsBox = inset(body, "Stats", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 7,
	})
	pad(statsBox, 10, 6, 10, 6)
	listLayout(statsBox, Enum.FillDirection.Vertical, 4)
	U.StatRows = {}
	local statKeys = PetCatalog.StatOrder or { "Income", "Power", "Health", "Speed" }
	local statNames = PetCatalog.StatNames or {}
	local statColors = {
		Income = Color3.fromRGB(112, 204, 98),
		Power = Color3.fromRGB(236, 112, 96),
		Health = Color3.fromRGB(240, 120, 150),
		Speed = Color3.fromRGB(98, 172, 232),
	}
	for i, statKey in ipairs(statKeys) do
		local row = makeFrame(statsBox, "Stat_" .. statKey, { Size = UDim2.new(1, 0, 0, 24), LayoutOrder = i })
		makeText(row, "Label", statNames[statKey] or statKey, "Heading", 18, WHITE, {
			Size = UDim2.new(0, 86, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local bar = makeFrame(row, "Bar", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 90, 0.5, 0),
			Size = UDim2.new(1, -150, 0, 12),
			BackgroundTransparency = 0.1,
			BackgroundColor3 = Color3.fromRGB(14, 20, 52),
		})
		round(bar)
		local fill = makeFrame(bar, "Fill", {
			Size = UDim2.new(0, 0, 1, 0),
			BackgroundTransparency = 0,
			BackgroundColor3 = statColors[statKey] or GOLD,
		})
		round(fill)
		local value = makeText(row, "Value", "?", "Heading", 18, WHITE, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(0, 54, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
		})
		U.StatRows[statKey] = { Fill = fill, Value = value }
	end

	-- special attack
	local special = inset(body, "Special", {
		Size = UDim2.new(1, 0, 0, 58),
		LayoutOrder = 8,
	})
	U.Special = special
	makeText(special, "Caption", G.Sparkle .. " SPECIAL", "Heading", 18, GOLD, {
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.new(1, -20, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	U.SpecialName = makeText(special, "SpecialName", "", "Title", 22, WHITE, {
		Position = UDim2.fromOffset(10, 26),
		Size = UDim2.new(1, -110, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
	})
	Util.Create("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 16, Parent = U.SpecialName })
	U.SpecialKind = makeText(special, "Kind", "", "Heading", 18, MUTED, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 28),
		Size = UDim2.fromOffset(90, 24),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	U.Matchup = makeText(body, "Matchup", "", "Body", 18, Theme.Lighten(BUTTONS.Blue or MUTED, 0.5), {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		LayoutOrder = 9,
	})
	U.Info = makeText(body, "Info", "", "Body", 19, WHITE, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		LayoutOrder = 10,
	})
	U.Owned = makeText(body, "Owned", "", "Heading", 19, MUTED, {
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = 11,
	})
end

local function buildWindow()
	if S.Built then
		return true
	end
	loadGroups()
	if #S.Groups == 0 then
		warnOnce("groups", "the pet catalog has no Index groups")
		return false
	end

	local holder = makeFrame(U.Gui, "Window_Index", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.fromOffset(K.PREF_W, K.PREF_H),
		Visible = false,
		ZIndex = 3,
	})
	U.Holder = holder
	U.Fit = Util.Create("UIScale", { Name = "Fit", Scale = 1, Parent = holder })
	local panel = CloudUI.Panel({
		Name = "IndexPanel",
		Title = G.Book .. " Pet Index",
		Closable = true,
		Accent = ACCENT,
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		OnClose = function()
			IndexController.Close()
		end,
		Parent = holder,
	})
	U.Panel = panel
	U.Pop = Util.Create("UIScale", { Name = "Pop", Scale = 1, Parent = panel.Root })
	local content = panel.Content

	local main = makeFrame(content, "Main", {
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 1, -(20 + K.FOOTER_H)),
	})
	U.Main = main

	-- left: group list + Elements button
	local hasElements = type(Config.Elements) == "table" and type(Config.Elements.Order) == "table"
	U.Groups = makeFrame(main, "Groups", { Size = UDim2.new(0, K.GROUP_W, 1, 0) })
	local listHeight = hasElements and -(K.ELEMENTS_BTN_H + 8) or 0
	U.GroupList = scroller(U.Groups, "GroupList", { Size = UDim2.new(1, 0, 1, listHeight) })
	pad(U.GroupList, 4, 6, 10, 6)
	listLayout(U.GroupList, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center)
	for index, group in ipairs(S.Groups) do
		buildGroupTile(group, index)
	end
	if hasElements then
		U.ElementsButton = CloudUI.Button({
			Name = "Elements",
			Text = "Elements",
			Style = "Blue",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, 0),
			Size = UDim2.new(1, -10, 0, K.ELEMENTS_BTN_H),
			TextSize = 22,
			Callback = function()
				safe("elements", showElements, not S.ElementsShown)
			end,
			Parent = U.Groups,
		})
	end

	-- centre: header, grid, rewards
	U.Centre = makeFrame(main, "Centre", {
		Position = UDim2.new(0, K.GROUP_W + K.GAP, 0, 0),
		Size = UDim2.new(1, -(K.GROUP_W + K.DETAIL_W + 2 * K.GAP), 1, 0),
	})
	buildCentre(U.Centre)

	-- right: detail card
	U.Detail = inset(main, "Detail", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, K.DETAIL_W, 1, 0),
	})
	buildDetail(U.Detail)

	-- footer: "Unlocked: x/N" over every pet
	local footer = makeFrame(content, "Footer", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -6),
		Size = UDim2.new(1, -20, 0, K.FOOTER_H - 6),
	})
	U.Footer = footer
	U.FooterText = makeText(footer, "Unlocked", "Unlocked: 0/0", "Title", 26, WHITE, {
		Size = UDim2.new(0, 260, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local track = makeFrame(footer, "Bar", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 270, 0.5, 0),
		Size = UDim2.new(1, -350, 0, 18),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(14, 20, 52),
	})
	round(track)
	stroke(track, NAVY, 3, 0)
	U.FooterFill = makeFrame(track, "Fill", {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundTransparency = 0,
		BackgroundColor3 = GOLD,
	})
	round(U.FooterFill)
	Theme.Gradient(U.FooterFill, Color3.fromRGB(255, 255, 255), Color3.fromRGB(206, 196, 170), 90)
	U.FooterPercent = makeText(footer, "Percent", "0%", "Display", 24, GOLD, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 70, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	S.Built = true
	relayout()
	return true
end

----------------------------------------------------------------------
-- Open / close
----------------------------------------------------------------------
local function setBackdrop(on)
	local backdrop = U.Backdrop
	if not backdrop then
		return
	end
	if on then
		backdrop.Visible = true
		tween(backdrop, 0.18, { BackgroundTransparency = 0.55 })
	else
		tween(backdrop, 0.15, { BackgroundTransparency = 1 })
		local mine = S.Token
		task.delay(0.17, function()
			if S.Token == mine and not S.Open and backdrop.Parent then
				backdrop.Visible = false
			end
		end)
	end
end

function IndexController.IsOpen()
	return S.Open
end

function IndexController.ClaimableCount()
	if #S.Groups == 0 then
		loadGroups()
	end
	local n = 0
	for _, group in ipairs(S.Groups) do
		local _, _, _, _, claimable = groupStatus(group)
		if claimable then
			n = n + 1
		end
	end
	return n
end

function IndexController.Open(groupId)
	if not initialized then
		IndexController.Init()
	end
	if not U.Gui then
		return
	end
	if not buildWindow() then
		return
	end
	local target = nil
	if type(groupId) == "string" then
		if S.GroupById[groupId] then
			target = groupId
		else
			-- accept any capitalisation ("common")
			for id in pairs(S.GroupById) do
				if id:lower() == groupId:lower() then
					target = id
				end
			end
		end
	end
	if not target and not S.Open then
		-- no group asked for: a waiting reward first, else where the player left off
		for _, group in ipairs(S.Groups) do
			local _, _, _, _, claimable = groupStatus(group)
			if claimable and not target then
				target = group.Id
			end
		end
	end
	target = target or S.GroupId or defaultGroup()
	local wasOpen = S.Open
	S.Open = true
	S.Token = S.Token + 1
	syncBackBinding()
	relayout()
	U.Holder.Visible = true
	if not wasOpen then
		U.Pop.Scale = 0.86
		tween(U.Pop, 0.22, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		setBackdrop(true)
	end
	safe("select", selectGroup, target)
	safe("refresh", refreshAll)
	if not wasOpen then
		IndexController.Opened:Fire(target)
	end
end

function IndexController.Close()
	if not S.Open then
		return
	end
	S.Open = false
	S.Token = S.Token + 1
	local mine = S.Token
	syncBackBinding()
	if U.ClaimPulse then
		U.ClaimPulse:Cancel()
		U.ClaimPulse = nil
	end
	tween(U.Pop, 0.12, { Scale = 0.9 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.13, function()
		if S.Token == mine and not S.Open and U.Holder then
			U.Holder.Visible = false
		end
	end)
	setBackdrop(false)
	IndexController.Closed:Fire()
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
local function onStateChanged()
	if not S.Built then
		return
	end
	local group = S.ClaimPending and S.GroupById[S.ClaimPending]
	if group and State.IsClaimed(group.Id) then
		-- the server confirmed the claim: celebrate on the rewards box
		S.ClaimPending = nil
		S.ClaimToken = S.ClaimToken + 1
		if S.Open and S.GroupId == group.Id and U.Rewards then
			burst(U.Rewards, rarityAccent(group.Rarity), 26, UDim2.new(1, -106, 0.5, 0))
		end
	end
	if S.Open then
		refreshAll()
	end
end

function IndexController.Init()
	if initialized then
		return
	end
	initialized = true
	LocalPlayer = Players.LocalPlayer
	pcall(State.Init)

	local gui = CloudUI.NewScreenGui("NimbusIndex", K.DISPLAY_ORDER)
	U.Gui = gui
	U.Backdrop = Util.Create("TextButton", {
		Name = "Backdrop",
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		BackgroundColor3 = Color3.fromRGB(8, 12, 32),
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		Visible = false,
		ZIndex = 1,
		Parent = gui,
	})
	U.Backdrop.Activated:Connect(function()
		IndexController.Close()
	end)

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if S.Built then
			safe("relayout", relayout)
		end
	end)
	State.Changed:Connect(function()
		safe("State.Changed", onStateChanged)
	end)
	if LocalPlayer then
		LocalPlayer:GetAttributeChangedSignal(Config.Attr.InMatch):Connect(function()
			if LocalPlayer:GetAttribute(Config.Attr.InMatch) == true then
				IndexController.Close()
			end
		end)
	end
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape and S.Open then
			IndexController.Close()
		end
	end)
	task.spawn(getClaimRemote)
end

return IndexController
