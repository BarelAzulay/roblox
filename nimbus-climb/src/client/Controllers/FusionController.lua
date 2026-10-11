-- FusionController (client, Phase 2): the Fusion Machine window (ARCHITECTURE_V3.md section 11 and the
-- FusionService / FusionController paragraph of the "Phase 2 build contract").
--
--   FusionController.Init()
--   FusionController.Open(tab, args)   tab = "Upgrade" | "Mix" | nil (the last one); args (optional) =
--                                       { Key = key (Upgrade input / first Mix pet), KeyB = key (second Mix pet) }
--   FusionController.Close()
--   Extras: FusionController.IsOpen() -> bool, FusionController.Plan() -> the preview the window shows
--           ({ Ok, Reason, Action, Inputs, ResultKey, ResultName, Rarity, Tier, Cost = {Currency, Amount}, Notes }),
--           FusionController.Select(keyA, keyB) (picks pets like clicks do), FusionController.Fuse() (the FUSE
--           button), FusionController.Opened / Closed (Util.Signal)
--
-- How it opens: E at the player's own Fusion Machine (the FusionPrompt HomeBuilder puts on Station_FusionMachine;
-- other players' prompts are disabled locally by HomeFx and ignored here), or OpenPanel("Fusion", {Tab =, Key =})
-- from the server / other windows. One window at a time: opening it closes the menu windows, and a menu window or the
-- Pet Index opening closes it. Esc, gamepad B, the red X or a click outside close it; so does walking away from the
-- machine (when it was opened there) and entering a match.
--
-- Layout (CloudUI panel, violet like the machine):
--   top     two tabs, UPGRADE and MIX, and the player's Cloud Tokens / Gems
--   left    "Your pets": a grid of pet tiles (ViewportFrame, name, "x3" copies, a gold star when equipped).
--           UPGRADE lists every regular pet that can still go up a finish (3 copies needed, the others dimmed);
--           MIX lists every regular pet (hybrids are one of a kind and cannot be fused again).
--   right   the preview: UPGRADE = the input (x3) -> the next finish (Golden / Rainbow) in a big ViewportFrame with
--           its x1.5 / x2.5 bonus; MIX = Body + Style -> a preview of the hybrid (PetKeys.DefOf of a stand-in
--           record: the real one gets its own random look seed), its blended name, rarity, elements, tier.
--           Then the notes (copies that are equipped / working at home are taken off first; why a fusion is not
--           possible), the cost (TycoonCatalog.FusionCost with the machine's discount; red when short) and FUSE.
-- FUSE sends Remotes.Fusion("Upgrade", key) / ("Mix", keyA, keyB); the server checks everything again and answers
-- with Fusion:FireClient("Result", {Ok, Key, Name, Reason...}). On success a short fusion animation plays: the inputs
-- fly into the centre, a flash and a confetti burst, the new pet pops in with a NEW! ribbon, and a burst of glowing
-- cubes leaves the machine's output pod (client-only parts, gone after a second).
-- Readability rule: designed in 1080p pixels (body 18-19, captions 18, buttons 22, titles 28-34) under ONE
-- UIScale = min(screen factor, fit); the window adapts between 800x456 and 1080x700 design pixels so landscape
-- phones keep >= 14 px text; every text has a stroke and sits on a solid panel. Pet viewports are attached under a
-- per-frame time budget (cached Low clones in the grid, High in the preview), all on CloudUI's one update loop.
-- Plain Lua 5.1-compatible syntax only. All text goes through Theme roles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local CollectionService = game:GetService("CollectionService")
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
		local module = Shared:FindFirstChild(name) or Shared:WaitForChild(name, 5)
		return module and require(module) or nil
	end)
	if ok and type(result) == "table" then
		return result
	end
	warn("[FusionController] " .. name .. " is unavailable: " .. tostring(result))
	return nil
end

local PetKeys = safeRequire("PetKeys")
local PetCatalog = safeRequire("PetCatalog")
local TycoonCatalog = safeRequire("TycoonCatalog")

local FusionController = {}
FusionController.Opened = Util.Signal()
FusionController.Closed = Util.Signal()

----------------------------------------------------------------------
-- Tunables (design pixels of a 1080p screen)
----------------------------------------------------------------------
local K = {
	PREF_W = 1080,
	PREF_H = 700,
	MIN_W = 800,
	MIN_H = 390,
	BUMPS = 28,
	MARGIN = 12,
	SHORT = 560, -- below this design height the compact layout is used (landscape phones)
	TOP_H = 54,
	TOP_H_SHORT = 44,
	-- portrait phones: the preview on top, the picker below (used when less than TALL_W design px are free)
	TALL_W = 700,
	PREF_W_TALL = 560,
	MIN_W_TALL = 360,
	PREF_H_TALL = 1000,
	MIN_H_TALL = 600,
	PREVIEW_TALL_H = 440,
	RESULT_TALL = 124,
	INPUT_TALL = 82,
	PICKER_W = 520,
	PICKER_W_NARROW = 396,
	NARROW = 960,
	GAP = 12,
	TILE_W = 112,
	TILE_H = 162,
	TILE_W_SHORT = 104,
	TILE_H_SHORT = 122,
	TILE_GAP = 10,
	RESULT = 176,
	RESULT_SHORT = 92,
	INPUT = 108,
	INPUT_SHORT = 68,
	TILE_BUDGET = 0.004, -- seconds of pet viewport building per frame (at least one per frame)
	TILES_MAX = 3,
	FUSE_TIMEOUT = 6, -- seconds the FUSE button waits for the server before it resets
	MACHINE_RANGE = 24, -- studs: the window closes when the player walks this far from the machine it opened at
	NEAR_RANGE = 30, -- studs: FUSE needs the player this close to their machine (the server allows a little more)
	BACK_ACTION = "NimbusFusionBack",
	DISPLAY_ORDER = 22, -- above NimbusMenu (20) and the Pet Index (21)
	PREVIEW_SEED = 4242, -- look seed of the Mix preview (the real hybrid draws its own)
}

local Colors = Theme.Colors
local WHITE = Colors.White
local NAVY = Colors.Navy or Colors.Ink
local MUTED = Colors.Muted or Colors.CloudShade
local GOLD = Colors.Gold or Colors.Token
local INK = Colors.TextStroke or Colors.Ink
local GOOD = Colors.Good
local BAD = Colors.Bad
local ACCENT = Color3.fromRGB(150, 104, 230) -- the machine's violet (title bar, tabs)
local INSET = Color3.fromRGB(20, 26, 66)
local TILE_FACE = Color3.fromRGB(58, 70, 136)
local TILE_SELECTED = Color3.fromRGB(110, 92, 196)
local WARN = Color3.fromRGB(255, 214, 110)
local TOKEN_INFO = Theme.Currency and Theme.Currency.Tokens or { Glyph = "\226\152\129", Color = GOLD }
local GEM_INFO = Theme.Currency and Theme.Currency.Gems or { Glyph = "\226\151\134", Color = Colors.Gem }
local TIER_COLORS = {
	Normal = Color3.fromRGB(150, 164, 196),
	Golden = Color3.fromRGB(240, 186, 60),
	Rainbow = Color3.fromRGB(214, 120, 230),
}
local G = {
	Crystal = "\240\159\148\174",
	Up = "\226\172\134",
	Dna = "\240\159\167\172",
	Arrow = "\226\150\182",
	Plus = "+",
	Star = "\226\152\133",
	Sparkle = "\226\156\168",
	Lock = "\240\159\148\146",
	Swap = "\226\135\132",
}
local NEXT_TIER = { Normal = "Golden", Golden = "Rainbow" }
local TIER_RANK = { Normal = 1, Golden = 2, Rainbow = 3 }

----------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------
local initialized = false
local LocalPlayer = nil
local warned = {}

local S = {
	Open = false,
	Built = false,
	Tab = "Upgrade",
	UpKey = nil, -- Upgrade input key
	MixA = nil, -- Mix: Body
	MixB = nil, -- Mix: Style
	Pending = nil, -- { Action, Token, At } while a request waits for the server
	Animating = false,
	Token = 0, -- bumps on every open / close (stale delayed callbacks check it)
	AtMachine = nil, -- the machine model the window was opened at (nil when opened from elsewhere)
	Tiles = {}, -- [key] = tile
	Queue = {}, -- tiles waiting for their viewport
	BackBound = false,
	Short = false,
	Narrow = false,
	Tall = false,
	Plan = nil,
	ResultSig = nil, -- what the result viewport shows (rebuilt only when it changes)
	InputSig = nil,
	FuseToken = 0,
}

local U = {} -- ui references

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function warnOnce(key, err)
	if not warned[key] then
		warned[key] = true
		warn("[FusionController] " .. tostring(key) .. ": " .. tostring(err))
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

local function tween(inst, seconds, goal, style, direction)
	return Util.Tween(inst, seconds, goal, style, direction)
end

local function inset(parent, name, props)
	local p = props or {}
	p.BackgroundColor3 = INSET
	p.BackgroundTransparency = 0.38
	local frame = makeFrame(parent, name, p)
	corner(frame, 12)
	stroke(frame, Colors.WellEdge or NAVY, 3, 0.15)
	return frame
end

local function commas(n)
	return Util.Commas(math.max(0, math.floor(tonumber(n) or 0)))
end

local function rarityAccent(rarityId)
	if rarityId == "Secret" then
		return Color3.fromRGB(150, 110, 232)
	end
	return CloudUI.RarityColor(rarityId)
end

local function pill(parent, name, text, color, layoutOrder)
	local label = makeText(parent, name, text, "Label", 18, WHITE, {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 30),
		BackgroundTransparency = 0,
		BackgroundColor3 = Theme.Darken(color, 0.25),
		LayoutOrder = layoutOrder or 0,
	})
	round(label)
	stroke(label, NAVY, 2, 0)
	pad(label, 12, 0, 12, 1)
	return label
end

----------------------------------------------------------------------
-- Pets, rules and costs (a mirror of FusionService: the server decides)
----------------------------------------------------------------------
local function parse(key)
	if not PetKeys or type(key) ~= "string" then
		return nil
	end
	local ok, parsed = pcall(PetKeys.Parse, key)
	if ok and type(parsed) == "table" then
		return parsed
	end
	return nil
end

local function defOf(key)
	local ok, def = pcall(State.DefOf, key)
	if ok and type(def) == "table" then
		return def
	end
	if PetKeys then
		local ok2, def2 = pcall(PetKeys.DefOf, key, State.Get())
		if ok2 and type(def2) == "table" then
			return def2
		end
	end
	return nil
end

local function catalogDef(petId)
	if PetCatalog and type(PetCatalog.Get) == "function" and type(petId) == "string" then
		local ok, def = pcall(PetCatalog.Get, petId)
		if ok and type(def) == "table" then
			return def
		end
	end
	return nil
end

local function nameOf(def, key)
	if type(def) == "table" then
		return tostring(def.DisplayName or def.Name or key)
	end
	return tostring(key)
end

local function owned(key)
	local ok, n = pcall(State.OwnedCount, key)
	if ok and type(n) == "number" then
		return n
	end
	return 0
end

local function equippedCount(key)
	local ok, n = pcall(State.EquippedCount, key)
	if ok and type(n) == "number" then
		return n
	end
	return 0
end

local function homeOf()
	local ok, home = pcall(State.Home)
	if ok and type(home) == "table" then
		return home
	end
	return { Level = 0, Prestige = 0, Stations = {}, Garden = {}, Gym = {} }
end

local function balance(currency)
	if currency == "Gems" then
		local ok, n = pcall(State.Gems)
		return (ok and type(n) == "number") and n or 0
	end
	local ok, n = pcall(State.Tokens)
	return (ok and type(n) == "number") and n or 0
end

local function copiesNeeded()
	local f = TycoonCatalog and TycoonCatalog.Fusion
	local n = type(f) == "table" and tonumber(rawget(f, "Copies")) or nil
	if n and n >= 2 then
		return math.floor(n)
	end
	return 3
end

local function unlockStars()
	local p = TycoonCatalog and TycoonCatalog.Prestige
	local n = type(p) == "table" and tonumber(p.FusionUnlock) or nil
	return n and math.floor(n) or 1
end

local function machineLevel()
	local stations = homeOf().Stations
	local lv = type(stations) == "table" and tonumber(stations.FusionMachine) or nil
	return lv and math.floor(lv) or 0
end

-- ok, reason
local function unlocked()
	local home = homeOf()
	local stars = tonumber(home.Prestige) or 0
	if stars < unlockStars() then
		return false, G.Lock .. " The Fusion Machine unlocks at Prestige " .. unlockStars()
	end
	if machineLevel() < 1 then
		return false, G.Lock .. " Build the Fusion Machine at your home first"
	end
	return true
end

local function costOf(action, rarity, tier)
	if not TycoonCatalog or type(TycoonCatalog.FusionCost) ~= "function" then
		return nil
	end
	local ok, cost = pcall(TycoonCatalog.FusionCost, action, rarity, tier, machineLevel())
	if not ok or type(cost) ~= "table" then
		return nil
	end
	if type(cost.Gems) == "number" and cost.Gems > 0 then
		return { Currency = "Gems", Amount = math.ceil(cost.Gems) }
	end
	if type(cost.Tokens) == "number" then
		return { Currency = "Tokens", Amount = math.ceil(cost.Tokens) }
	end
	return nil
end

local function rarityOrder(rarityId)
	for _, r in ipairs(Config.Rarities or {}) do
		if r.Id == rarityId then
			return r.Order or 0
		end
	end
	return 0
end

-- What taking these copies frees: notes for the player, and whether it would leave nothing equipped.
local function usageNotes(inputs)
	local snap = State.Get()
	local equippedTotal = type(snap.Equipped) == "table" and #snap.Equipped or 0
	local home = homeOf()
	local dropped, placedOff = 0, 0
	for _, input in ipairs(inputs) do
		local left = owned(input.Key) - input.Count
		dropped = dropped + math.max(0, equippedCount(input.Key) - left)
		local placed = 0
		for _, k in pairs(type(home.Garden) == "table" and home.Garden or {}) do
			if k == input.Key then
				placed = placed + 1
			end
		end
		for _, k in pairs(type(home.Gym) == "table" and home.Gym or {}) do
			if k == input.Key then
				placed = placed + 1
			end
		end
		placedOff = placedOff + math.max(0, placed - left)
	end
	-- every note has a Short form for the one-line layouts (landscape phones)
	local notes = {}
	if equippedTotal > 0 and dropped >= equippedTotal then
		return notes, "Those are your only equipped pets: unequip them or equip another pet first", "Equip another pet first"
	end
	if dropped > 0 then
		notes[#notes + 1] = {
			Text = dropped .. " equipped cop" .. (dropped == 1 and "y is" or "ies are") .. " taken off first; the new pet takes the slot",
			Short = "Unequips " .. dropped .. " cop" .. (dropped == 1 and "y" or "ies") .. " first",
			Color = WARN,
		}
	end
	if placedOff > 0 then
		notes[#notes + 1] = {
			Text = placedOff .. " cop" .. (placedOff == 1 and "y leaves" or "ies leave") .. " the Garden / Gym first; the new pet takes over",
			Short = placedOff .. " cop" .. (placedOff == 1 and "y leaves" or "ies leave") .. " the Garden / Gym first",
			Color = WARN,
		}
	end
	return notes, nil
end

-- The preview of the current selection (the same checks the server makes, in the same order).
local function computePlan()
	local plan = { Ok = false, Action = S.Tab, Notes = {} }
	local okUnlock, why = unlocked()
	if not okUnlock then
		plan.Reason = why
		plan.Locked = true
		return plan
	end
	if not PetKeys then
		plan.Reason = "Fusion is not available right now"
		return plan
	end
	if S.Tab == "Upgrade" then
		local key = S.UpKey
		local parsed = key and parse(key)
		if not parsed then
			plan.Reason = "Pick a pet with " .. copiesNeeded() .. " copies"
			plan.Empty = true
			return plan
		end
		local def = defOf(key)
		local base = catalogDef(parsed.PetId)
		local nextTier = NEXT_TIER[parsed.Tier]
		plan.Inputs = { { Key = key, Count = copiesNeeded() } }
		plan.InputDef = def
		if parsed.HybridId or not base then
			plan.Reason = "Hybrids are one of a kind: they cannot be upgraded"
			return plan
		end
		if not nextTier then
			plan.Reason = "Rainbow is the best finish: this pet cannot go higher"
			return plan
		end
		plan.Tier = nextTier
		plan.Rarity = base.Rarity
		plan.ResultKey = PetKeys.Make(parsed.PetId, nextTier)
		plan.ResultDef = plan.ResultKey and PetKeys.DefOf(plan.ResultKey) or nil
		plan.ResultName = nameOf(plan.ResultDef, plan.ResultKey)
		plan.Cost = costOf("Upgrade", base.Rarity, nextTier)
		local have = owned(key)
		if have < copiesNeeded() then
			plan.Reason = "You need " .. copiesNeeded() .. " copies of " .. nameOf(def, key) .. " (you have " .. have .. ")"
			return plan
		end
	elseif S.Tab == "Mix" then
		local a, b = S.MixA, S.MixB
		local pa, pb = a and parse(a), b and parse(b)
		plan.Inputs = {}
		if pa then
			plan.Inputs[#plan.Inputs + 1] = { Key = a, Count = 1 }
		end
		if pb then
			plan.Inputs[#plan.Inputs + 1] = { Key = b, Count = 1 }
		end
		if not pa or not pb then
			plan.Reason = "Pick two different pets to mix"
			plan.Empty = true
			return plan
		end
		if pa.HybridId or pb.HybridId then
			plan.Reason = "Hybrids cannot be mixed again: pick two regular pets"
			return plan
		end
		if pa.PetId == pb.PetId then
			plan.Reason = "Pick two different pets to mix"
			return plan
		end
		local baseA, baseB = catalogDef(pa.PetId), catalogDef(pb.PetId)
		if not baseA or not baseB then
			plan.Reason = "Unknown pet"
			return plan
		end
		local rarity = (rarityOrder(baseB.Rarity) > rarityOrder(baseA.Rarity)) and baseB.Rarity or baseA.Rarity
		local tier = ((TIER_RANK[pb.Tier] or 1) < (TIER_RANK[pa.Tier] or 1)) and pb.Tier or pa.Tier
		local name = "Hybrid"
		if type(PetKeys.BlendName) == "function" then
			local okName, blended = pcall(PetKeys.BlendName, baseA.Name, baseB.Name)
			if okName and type(blended) == "string" then
				name = blended
			end
		end
		local elements = {}
		for _, e in ipairs({ baseA.Element, baseB.Element }) do
			if type(e) == "string" and e ~= elements[1] then
				elements[#elements + 1] = e
			end
		end
		local record = { Body = pa.PetId, Style = pb.PetId, Tier = tier, Rarity = rarity, Name = name, Elements = elements, Seed = K.PREVIEW_SEED }
		local previewKey = PetKeys.HybridKey("preview", tier)
		local okDef, def = pcall(PetKeys.DefOf, previewKey, { Hybrids = { preview = record } })
		plan.ResultDef = okDef and def or nil
		plan.ResultName = (tier ~= "Normal" and (tier .. " ") or "") .. name
		plan.Rarity = rarity
		plan.Tier = tier
		plan.Elements = elements
		plan.Cost = costOf("Mix", rarity, nil)
		if owned(a) < 1 or owned(b) < 1 then
			plan.Reason = "You do not own those pets"
			return plan
		end
	else
		plan.Reason = "Pick a tab"
		return plan
	end
	if not plan.Cost then
		plan.Reason = "These pets cannot be fused"
		return plan
	end
	local notes, rule, ruleShort = usageNotes(plan.Inputs)
	plan.Notes = notes
	if rule then
		plan.Reason = rule
		plan.ReasonShort = ruleShort
		return plan
	end
	local have = balance(plan.Cost.Currency)
	plan.CanAfford = have >= plan.Cost.Amount
	if not plan.CanAfford then
		plan.Reason = "Not enough " .. ((plan.Cost.Currency == "Gems") and "Gems" or "Cloud Tokens") .. " (you have " .. commas(have) .. ")"
		return plan
	end
	if State.Get() and LocalPlayer and LocalPlayer:GetAttribute(Config.Attr.InMatch) == true then
		plan.Reason = "Fusion is closed during a match"
		return plan
	end
	plan.Ok = true
	return plan
end

----------------------------------------------------------------------
-- The machine in the world (the player's own Station_FusionMachine)
----------------------------------------------------------------------
local function myMachine()
	local uid = LocalPlayer and LocalPlayer.UserId
	if not uid then
		return nil
	end
	for _, home in ipairs(CollectionService:GetTagged("NC_Home")) do
		if home:GetAttribute("OwnerUserId") == uid then
			local station = home:FindFirstChild("Station_FusionMachine")
			if station then
				return station
			end
		end
	end
	return nil
end

local function rootPart()
	local character = LocalPlayer and LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart") or nil
end

local function distanceTo(model)
	local root = rootPart()
	if not root or not model or not model.Parent then
		return math.huge
	end
	local ok, pivot = pcall(function()
		return model:GetPivot()
	end)
	if not ok or typeof(pivot) ~= "CFrame" then
		return math.huge
	end
	return (root.Position - pivot.Position).Magnitude
end

-- the output pod (where the FusionPrompt rides), or the model's pivot
local function outputPoint(model)
	if not model then
		return nil
	end
	local prompt = model:FindFirstChild("FusionPrompt", true)
	local holder = prompt and prompt.Parent
	if holder and holder:IsA("Attachment") then
		return holder.WorldPosition
	end
	local ok, pivot = pcall(function()
		return model:GetPivot()
	end)
	if ok and typeof(pivot) == "CFrame" then
		return pivot.Position + Vector3.new(0, 3, 0)
	end
	return nil
end

----------------------------------------------------------------------
-- Layout (readability rule + fit)
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

local function fitWindow()
	local area = guiSize()
	local factor = Theme.ScreenFactor(viewportHeight())
	local freeW = area.X - 2 * K.MARGIN
	local freeH = area.Y - 2 * K.MARGIN
	-- a screen too narrow for the side-by-side window (portrait phones) gets the tall layout
	local tall = freeW / factor < K.TALL_W and freeH > freeW
	local minW, prefW = K.MIN_W, K.PREF_W
	local minH, prefH = K.MIN_H, K.PREF_H
	if tall then
		minW, prefW = K.MIN_W_TALL, K.PREF_W_TALL
		minH, prefH = K.MIN_H_TALL, K.PREF_H_TALL
	end
	local w = Util.Clamp(math.floor(freeW / factor), minW, prefW)
	local h = Util.Clamp(math.floor((freeH - K.BUMPS * factor) / factor), minH, prefH)
	local scale = Util.Clamp(math.min(factor, freeW / w, freeH / h), 0.3, 1.25)
	local y = math.min(area.Y / 2 + K.BUMPS * scale / 2, area.Y - K.MARGIN / 2 - h * scale / 2)
	return w, h, scale, area.X / 2, math.max(y, h * scale / 2), tall
end

local layoutPreview -- defined below

local function relayout()
	if not S.Built then
		return
	end
	local w, h, scale, x, y, tall = fitWindow()
	U.Holder.Size = UDim2.fromOffset(w, h)
	U.Fit.Scale = scale
	U.Holder.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	S.Tall = tall
	local short = h < K.SHORT and not tall
	S.Short = short
	S.Narrow = w < K.NARROW
	local pickerW = S.Narrow and K.PICKER_W_NARROW or K.PICKER_W
	local topH = short and K.TOP_H_SHORT or K.TOP_H
	U.Top.Size = UDim2.new(1, -20, 0, topH)
	U.Top.Position = UDim2.fromOffset(10, short and 6 or 10)
	local tabW = short and 176 or 196
	if tall then
		tabW = math.floor((w - 20 - 30) / 2)
	end
	for i, name in ipairs({ "Upgrade", "Mix" }) do
		local tab = U.Tabs[name]
		tab.Size = UDim2.fromOffset(tabW, short and 42 or 50)
		tab.Position = UDim2.fromOffset((i - 1) * (tabW + 10), short and 1 or 2)
		tab.TextSize = short and 22 or 24
	end
	-- (the tall layout has no room for the balance chips: the cost line turns red and says what is missing)
	U.Chips.Visible = not tall
	U.Chips.Size = UDim2.new(0, 360, 0, short and 40 or 44)
	U.Chips.Position = UDim2.new(1, 0, 0, short and 2 or 5)
	for _, chip in ipairs({ U.TokenChip, U.GemChip }) do
		chip.Size = UDim2.fromOffset(0, short and 40 or 44)
		chip.TextSize = short and 22 or 24
	end
	U.Body.Position = UDim2.fromOffset(10, topH + (short and 12 or 16))
	U.Body.Size = UDim2.new(1, -20, 1, -(topH + (short and 18 or 26)))
	if tall then
		U.Preview.Position = UDim2.new(0, 0, 0, 0)
		U.Preview.Size = UDim2.new(1, 0, 0, K.PREVIEW_TALL_H)
		U.Picker.Position = UDim2.new(0, 0, 0, K.PREVIEW_TALL_H + K.GAP)
		U.Picker.Size = UDim2.new(1, 0, 1, -(K.PREVIEW_TALL_H + K.GAP))
	else
		U.Picker.Position = UDim2.new(0, 0, 0, 0)
		U.Picker.Size = UDim2.new(0, pickerW, 1, 0)
		U.Preview.Position = UDim2.new(0, pickerW + K.GAP, 0, 0)
		U.Preview.Size = UDim2.new(1, -(pickerW + K.GAP), 1, 0)
	end
	U.PickerTitle.Size = UDim2.new(0.45, 0, 0, short and 28 or 32)
	U.PickerTitle.Position = UDim2.fromOffset(14, short and 4 or 8)
	U.PickerHint.Position = UDim2.new(1, -14, 0, short and 4 or 10)
	U.Grid.Position = UDim2.fromOffset(8, short and 36 or 46)
	U.Grid.Size = UDim2.new(1, -16, 1, -(short and 42 or 54))
	U.GridLayout.CellSize = UDim2.fromOffset(short and K.TILE_W_SHORT or K.TILE_W, short and K.TILE_H_SHORT or K.TILE_H)
	for _, tile in pairs(S.Tiles) do
		tile.Mode = nil
	end
	layoutPreview()
end

----------------------------------------------------------------------
-- Back button (gamepad B) while the window is open
----------------------------------------------------------------------
local function onBackAction(_name, inputState)
	if inputState == Enum.UserInputState.Begin and S.Open then
		FusionController.Close()
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
-- Pet tiles (left)
----------------------------------------------------------------------
local refresh -- defined below

-- keys the current tab lists, in display order
local function pickerKeys()
	local ok, keys = pcall(State.Keys)
	if not ok or type(keys) ~= "table" then
		keys = {}
	end
	local out = {}
	local need = copiesNeeded()
	for i, key in ipairs(keys) do
		local parsed = parse(key)
		if parsed and not parsed.HybridId then
			if S.Tab == "Mix" or NEXT_TIER[parsed.Tier] then
				out[#out + 1] = { Key = key, Order = i, Ready = owned(key) >= need }
			end
		end
	end
	if S.Tab == "Upgrade" then
		table.sort(out, function(a, b)
			if a.Ready ~= b.Ready then
				return a.Ready
			end
			return a.Order < b.Order
		end)
	end
	return out
end

local function destroyTileViewport(tile)
	if tile.Viewport then
		pcall(tile.Viewport.Destroy)
		tile.Viewport = nil
	end
end

local function buildTileViewport(tile)
	if tile.Viewport or not tile.Button.Parent then
		return
	end
	local def = defOf(tile.Key)
	if not def then
		return
	end
	tile.Viewport = CloudUI.PetViewport(tile.View, def, UDim2.new(1, 0, 1, 0), { Detail = "Low", Spin = "sway" })
end

local function onTileClicked(key)
	if S.Pending or S.Animating then
		return
	end
	if S.Tab == "Upgrade" then
		S.UpKey = (S.UpKey == key) and nil or key
	else
		if S.MixA == key then
			S.MixA = nil
		elseif S.MixB == key then
			S.MixB = nil
		elseif not S.MixA then
			S.MixA = key
		elseif not S.MixB then
			S.MixB = key
		else
			S.MixB = key
		end
	end
	refresh()
end

local function newTile(key)
	local tile = { Key = key }
	local button = Util.Create("TextButton", {
		Name = "Tile",
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		BackgroundColor3 = TILE_FACE,
		Parent = U.Grid,
	})
	corner(button, 12)
	tile.Stroke = stroke(button, NAVY, 3, 0)
	Theme.Gradient(button, Color3.fromRGB(255, 255, 255), Color3.fromRGB(196, 204, 230), 90)
	tile.Button = button
	tile.View = makeFrame(button, "View", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(1, -16, 0, 92),
	})
	tile.Name = makeText(button, "PetName", "", "Label", 18, WHITE, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -10, 0, 44),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	tile.Count = makeText(button, "Count", "x1", "Heading", 18, WHITE, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -5, 0, 5),
		Size = UDim2.fromOffset(46, 26),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(30, 40, 90),
		ZIndex = 3,
	})
	round(tile.Count)
	stroke(tile.Count, NAVY, 2, 0)
	tile.Equipped = makeText(button, "Equipped", G.Star, "Heading", 18, GOLD, {
		Position = UDim2.fromOffset(5, 5),
		Size = UDim2.fromOffset(26, 26),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(30, 40, 90),
		ZIndex = 3,
		Visible = false,
	})
	round(tile.Equipped)
	-- the Mix pick order (1 = Body, 2 = Style) sits in the top-left corner, clear of the pet's face
	tile.Mark = makeText(button, "Mark", "", "Title", 20, WHITE, {
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.fromOffset(30, 30),
		BackgroundTransparency = 0,
		BackgroundColor3 = ACCENT,
		ZIndex = 4,
		Visible = false,
	})
	round(tile.Mark)
	stroke(tile.Mark, NAVY, 2, 0)
	tile.Dim = makeFrame(button, "Dim", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 0.5,
		BackgroundColor3 = Color3.fromRGB(10, 14, 36),
		ZIndex = 2,
		Visible = false,
	})
	corner(tile.Dim, 12)
	button.Activated:Connect(function()
		safe("tile", onTileClicked, key)
	end)
	S.Tiles[key] = tile
	S.Queue[#S.Queue + 1] = tile
	return tile
end

local function paintTile(tile, order, ready)
	local def = defOf(tile.Key)
	local mode = S.Short and "Short" or "Wide"
	if tile.Mode ~= mode then
		tile.Mode = mode
		tile.View.Size = UDim2.new(1, -16, 0, S.Short and 64 or 92)
		tile.Name.Size = UDim2.new(1, -10, 0, S.Short and 26 or 44)
		tile.Name.TextWrapped = not S.Short
		tile.Name.Position = UDim2.new(0.5, 0, 1, S.Short and -4 or -6)
	end
	tile.Button.LayoutOrder = order
	tile.Name.Text = nameOf(def, tile.Key)
	local n = owned(tile.Key)
	tile.Count.Text = "x" .. n
	local need = copiesNeeded()
	if S.Tab == "Upgrade" then
		tile.Count.BackgroundColor3 = (n >= need) and Theme.Darken(GOOD, 0.35) or Color3.fromRGB(30, 40, 90)
		tile.Dim.Visible = n < need
	else
		tile.Count.BackgroundColor3 = Color3.fromRGB(30, 40, 90)
		tile.Dim.Visible = false
	end
	tile.Equipped.Visible = equippedCount(tile.Key) > 0
	local selected = false
	local mark = nil
	if S.Tab == "Upgrade" then
		selected = S.UpKey == tile.Key
	else
		if S.MixA == tile.Key then
			selected, mark = true, "1"
		elseif S.MixB == tile.Key then
			selected, mark = true, "2"
		end
	end
	tile.Button.BackgroundColor3 = selected and TILE_SELECTED or TILE_FACE
	tile.Stroke.Color = selected and GOLD or NAVY
	tile.Stroke.Thickness = selected and 4 or 3
	tile.Mark.Visible = mark ~= nil
	tile.Mark.Text = mark or ""
	-- the equipped star moves down a row while the pick mark holds the corner
	tile.Equipped.Position = UDim2.fromOffset(mark and 6 or 5, mark and 38 or 5)
	local rarity = type(def) == "table" and def.Rarity or nil
	if not selected and rarity then
		tile.Stroke.Color = Theme.Darken(rarityAccent(rarity), 0.35)
	end
end

local function refreshTiles()
	local list = pickerKeys()
	local wanted = {}
	for i, entry in ipairs(list) do
		wanted[entry.Key] = true
		local tile = S.Tiles[entry.Key] or newTile(entry.Key)
		paintTile(tile, i, entry.Ready)
	end
	for key, tile in pairs(S.Tiles) do
		if not wanted[key] then
			destroyTileViewport(tile)
			tile.Button:Destroy()
			S.Tiles[key] = nil
		end
	end
	U.Empty.Visible = #list == 0
	if S.Tab == "Upgrade" then
		U.Empty.Text = "No pets to upgrade yet. Roll more copies at the roulettes!"
		U.PickerHint.Text = "Pick a pet with " .. copiesNeeded() .. " copies"
	else
		U.Empty.Text = "You need at least two different pets to mix."
		U.PickerHint.Text = "Pick two different pets"
	end
end

-- pet viewports under a per-frame time budget
local function fillViewports()
	if #S.Queue == 0 then
		return
	end
	local started = os.clock()
	local built = 0
	while #S.Queue > 0 and built < K.TILES_MAX do
		local tile = table.remove(S.Queue, 1)
		if tile.Button.Parent then
			safe("viewport", buildTileViewport, tile)
			built = built + 1
		end
		if os.clock() - started > K.TILE_BUDGET then
			break
		end
	end
end

----------------------------------------------------------------------
-- Preview (right)
----------------------------------------------------------------------
local function slotFrame(parent, name, size)
	local holder = makeFrame(parent, name, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(44, 54, 116),
		ZIndex = 3,
	})
	corner(holder, 14)
	local s = stroke(holder, NAVY, 3, 0)
	Theme.Gradient(holder, Color3.fromRGB(255, 255, 255), Color3.fromRGB(176, 186, 220), 90)
	local view = makeFrame(holder, "View", { Size = UDim2.new(1, -8, 1, -8), Position = UDim2.fromOffset(4, 4), ZIndex = 4 })
	local q = makeText(holder, "Placeholder", "?", "Title", 40, MUTED, {
		Size = UDim2.new(1, 0, 1, 0),
		TextTransparency = 0.2,
		ZIndex = 4,
	})
	local scale = Util.Create("UIScale", { Name = "Pop", Scale = 1, Parent = holder })
	return { Frame = holder, View = view, Stroke = s, Placeholder = q, Scale = scale, Viewport = nil, Def = nil }
end

local function setSlotPet(slot, def, detail)
	if slot.Def == def and slot.Viewport then
		return
	end
	if slot.Viewport then
		pcall(slot.Viewport.Destroy)
		slot.Viewport = nil
	end
	slot.Def = def
	slot.Placeholder.Visible = def == nil
	if def then
		local ok, handle = pcall(CloudUI.PetViewport, slot.View, def, UDim2.new(1, 0, 1, 0), { Detail = detail or "High", Spin = "spin", ZIndex = 4 })
		if ok then
			slot.Viewport = handle
		end
	end
end

layoutPreview = function()
	if not U.Preview then
		return
	end
	local short = S.Short
	local result = short and K.RESULT_SHORT or K.RESULT
	local input = short and K.INPUT_SHORT or K.INPUT
	if S.Tall then
		result, input = K.RESULT_TALL, K.INPUT_TALL
	end
	local mix = S.Tab == "Mix"
	U.PreviewTitle.Visible = not short
	local rowY = short and 4 or (S.Tall and 54 or 66)
	local rowH = result + ((mix or not short) and 26 or 8)
	U.SlotRow.Position = UDim2.new(0, 0, 0, rowY)
	U.SlotRow.Size = UDim2.new(1, 0, 0, rowH)
	local cy = result / 2 + 4
	-- result on the right third, inputs on the left
	U.ResultSlot.Frame.Size = UDim2.fromOffset(result, result)
	U.ResultSlot.Frame.Position = UDim2.new(0.76, 0, 0, cy)
	U.Arrow.Position = UDim2.new(0.53, 0, 0, cy)
	for _, slot in ipairs(U.InSlots) do
		slot.Frame.Size = UDim2.fromOffset(input, input)
	end
	if not mix then
		-- three copies fanned out like a stack of cards
		local fan = short and 10 or 16
		U.InSlots[1].Frame.Position = UDim2.new(0.25, -fan, 0, cy - fan * 0.75)
		U.InSlots[2].Frame.Position = UDim2.new(0.25, 0, 0, cy)
		U.InSlots[3].Frame.Position = UDim2.new(0.25, fan, 0, cy + fan * 0.75)
		U.InSlots[1].Frame.Rotation = -6
		U.InSlots[3].Frame.Rotation = 6
		U.InSlots[2].Frame.Rotation = 0
		U.InSlots[1].Frame.Visible = true
		U.InSlots[3].Frame.Visible = true
		U.Plus.Visible = false
		U.CaptionA.Visible = false
		U.CaptionB.Visible = false
		U.Swap.Visible = false
	else
		local gap = input * 0.62
		U.InSlots[1].Frame.Position = UDim2.new(0.25, -gap, 0, cy)
		U.InSlots[2].Frame.Position = UDim2.new(0.25, gap, 0, cy)
		U.InSlots[1].Frame.Rotation = 0
		U.InSlots[2].Frame.Rotation = 0
		U.InSlots[3].Frame.Visible = false
		U.InSlots[1].Frame.Visible = true
		U.Plus.Visible = true
		U.Plus.Position = UDim2.new(0.25, 0, 0, cy)
		U.CaptionA.Visible = true
		U.CaptionB.Visible = true
		U.CaptionA.Position = UDim2.new(0.25, -gap, 0, cy + input / 2 + 2)
		U.CaptionB.Position = UDim2.new(0.25, gap, 0, cy + input / 2 + 2)
		U.Swap.Visible = S.MixA ~= nil and S.MixB ~= nil
		U.Swap.Position = UDim2.new(0.25, 0, 0, cy - input / 2 - 2)
	end
	local y = rowY + rowH + 2
	if short then
		-- no room for the pills: the name (in its rarity colour) and a summary line instead
		U.ResultName.Position = UDim2.new(0, 14, 0, y)
		U.ResultName.Size = UDim2.new(1, -28, 0, 30)
		U.ResultName.TextSize = 24
		U.Pills.Visible = false
		y = y + 32
	else
		U.Pills.Visible = true
		U.ResultName.Position = UDim2.new(0, 14, 0, y)
		U.ResultName.Size = UDim2.new(1, -28, 0, 36)
		U.ResultName.TextSize = 28
		y = y + 38
		U.Pills.Position = UDim2.new(0, 14, 0, y)
		U.Pills.Size = UDim2.new(1, -28, 0, 32)
		U.PillsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		y = y + 40
	end
	local compact = short or S.Tall
	local bottomH = short and 52 or 64
	U.Bottom.Size = UDim2.new(1, -28, 0, bottomH)
	U.Bottom.Position = UDim2.new(0, 14, 1, short and -6 or -12)
	U.Cost.TextSize = compact and 24 or 28
	U.FuseButton.Size = UDim2.fromOffset(compact and 170 or 214, short and 48 or 58)
	U.FuseButton.TextSize = compact and 24 or 28
	-- on a phone Roblox's jump button covers the bottom-right corner: FUSE goes to the left and the cost follows it
	-- (left-aligned right after the button), so the corner under the jump button stays empty
	local leftFuse = short and UserInputService.TouchEnabled
	S.CostOnly = leftFuse -- the cost shows without its "Cost:" label there (shorter, clear of the jump button)
	local fuseW = compact and 170 or 214
	U.FuseButton.AnchorPoint = leftFuse and Vector2.new(0, 0.5) or Vector2.new(1, 0.5)
	U.FuseButton.Position = leftFuse and UDim2.new(0, 0, 0.5, 0) or UDim2.new(1, 0, 0.5, 0)
	U.Cost.AnchorPoint = Vector2.new(0, 0.5)
	U.Cost.Position = leftFuse and UDim2.new(0, fuseW + 14, 0.5, 0) or UDim2.new(0, 0, 0.5, 0)
	U.Cost.TextXAlignment = Enum.TextXAlignment.Left
	U.Cost.Size = UDim2.new(1, -(fuseW + 14), 0, 40)
	U.Details.Position = UDim2.new(0, 14, 0, y)
	U.Details.Size = UDim2.new(1, -28, 1, -(y + bottomH + (short and 8 or 20)))
	U.ServerNote.Position = UDim2.new(0, 14, 1, -(bottomH + (short and 10 or 18)))
	-- the locked card: a smaller crystal and no teaser line on short screens
	if U.LockedSub then
		U.LockedSub.Visible = not short
		U.LockedIcon.Size = short and UDim2.fromOffset(64, 64) or UDim2.fromOffset(90, 90)
		U.LockedIcon.TextSize = short and 46 or 64
		U.LockedIcon.Position = UDim2.new(0.5, 0, short and 0.42 or 0.4, 0)
		U.LockedText.Position = UDim2.new(0.5, 0, short and 0.46 or 0.43, 0)
		U.LockedSub.Position = UDim2.new(0.5, 0, 0.43, 70)
	end
end

local function setNotes(plan)
	for _, child in ipairs(U.Details:GetChildren()) do
		if child:IsA("TextLabel") and child ~= U.Info then
			child:Destroy()
		end
	end
	U.Info.Visible = true
	S.NotesToken = (S.NotesToken or 0) + 1
	local mine = S.NotesToken
	local order = 1
	local function add(text, color)
		order = order + 1
		makeText(U.Details, "Note" .. order, text, "Body", 18, color or MUTED, {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = order,
		})
	end
	local lines = {}
	if plan.Reason and not plan.Empty then
		lines[#lines + 1] = { Text = plan.Reason, Short = plan.ReasonShort, Color = BAD }
	end
	for _, note in ipairs(plan.Notes or {}) do
		lines[#lines + 1] = note
	end
	if plan.Ok and not S.MachineNear then
		lines[#lines + 1] = { Text = "Walk up to your Fusion Machine to fuse", Color = WARN }
	end
	if S.Short or (S.Tall and #lines > 0) then
		-- one line only: the most important note replaces the summary / explanation
		local first = lines[1]
		if first then
			U.Info.Text = (S.Short and first.Short) or first.Text
			U.Info.TextColor3 = first.Color or MUTED
		end
		return
	end
	for _, line in ipairs(lines) do
		add(line.Text, line.Color)
	end
	-- when the explanation and the notes do not both fit (smaller screens, long names), the notes win: the general
	-- explanation steps aside instead of a warning being clipped at the bottom
	if #lines > 0 then
		local function fit()
			-- (a newer refresh owns the details now; the one-line layouts never hide their only line)
			if S.NotesToken ~= mine or S.Short or S.Tall or not U.Details or not U.Info.Parent then
				return
			end
			U.Info.Visible = true
			-- the stacked height of the lines (their absolute sizes plus the list padding)
			local scale = (U.Fit and U.Fit.Scale) or 1
			local used, n = 0, 0
			for _, child in ipairs(U.Details:GetChildren()) do
				if child:IsA("GuiObject") and child.Visible then
					used = used + child.AbsoluteSize.Y
					n = n + 1
				end
			end
			used = used + math.max(0, n - 1) * 6 * scale
			local room = U.Details.AbsoluteSize.Y
			if room > 0 and used > room + 1 then
				U.Info.Visible = false
			end
		end
		fit()
		task.defer(fit)
	end
end

local function renderPills(plan)
	for _, child in ipairs(U.Pills:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	if not plan.ResultDef then
		return
	end
	if plan.Rarity then
		pill(U.Pills, "Rarity", tostring(plan.Rarity), rarityAccent(plan.Rarity), 1)
	end
	if plan.Tier and plan.Tier ~= "Normal" then
		pill(U.Pills, "Tier", plan.Tier, TIER_COLORS[plan.Tier] or ACCENT, 2)
	end
	local elements = plan.Elements
	if not elements and type(plan.ResultDef) == "table" then
		elements = plan.ResultDef.Elements or { plan.ResultDef.Element }
	end
	for i, e in ipairs(elements or {}) do
		local info = Config.Elements and Config.Elements.Info and Config.Elements.Info[e]
		if info then
			pill(U.Pills, "Element" .. i, e, info.Color, 2 + i)
		end
	end
end

-- "Legendary  Frost + Flame" (the compact layout shows this line instead of the pills)
local function summaryText(plan)
	local parts = {}
	if plan.Rarity then
		parts[#parts + 1] = tostring(plan.Rarity)
	end
	if plan.Tier and plan.Tier ~= "Normal" then
		parts[#parts + 1] = plan.Tier
	end
	local elements = plan.Elements
	if not elements and type(plan.ResultDef) == "table" then
		elements = plan.ResultDef.Elements or { plan.ResultDef.Element }
	end
	if elements and #elements > 0 then
		parts[#parts + 1] = table.concat(elements, " + ")
	end
	return table.concat(parts, "  |  ")
end

local function infoText(plan)
	if S.Short then
		if plan.ResultDef then
			return summaryText(plan)
		end
		return (S.Tab == "Upgrade") and "3 copies fuse into the next finish" or "Two different pets make a new hybrid"
	end
	if S.Tab == "Upgrade" then
		if plan.Tier == "Golden" then
			return "3 copies become 1 Golden copy: stats and perks x1.5 and a gold shine."
		elseif plan.Tier == "Rainbow" then
			return "3 Golden copies become 1 Rainbow copy: stats and perks x2.5 and a rainbow shimmer."
		end
		return "3 copies of a pet fuse into its next finish: Golden (x1.5), then Rainbow (x2.5)."
	end
	if plan.ResultDef then
		return "Body gives the shape, Style the colours and wings. Stats: average x1.2. Every hybrid is unique!"
	end
	return "Mix two different pets into a brand-new hybrid with both elements."
end

local function renderPreview(plan)
	U.PreviewTitle.Text = (S.Tab == "Upgrade") and (G.Up .. " Upgrade") or (G.Dna .. " Mix")
	-- inputs
	local inputs = {}
	if S.Tab == "Upgrade" then
		local def = S.UpKey and defOf(S.UpKey) or nil
		local have = S.UpKey and owned(S.UpKey) or 0
		for i = 1, 3 do
			inputs[i] = (def and i <= math.max(1, math.min(have, 3))) and def or nil
		end
		U.InCount.Visible = def ~= nil
		U.InCount.Text = math.min(have, copiesNeeded()) .. "/" .. copiesNeeded()
		U.InCount.BackgroundColor3 = (have >= copiesNeeded()) and Theme.Darken(GOOD, 0.3) or Theme.Darken(BAD, 0.2)
	else
		inputs[1] = S.MixA and defOf(S.MixA) or nil
		inputs[2] = S.MixB and defOf(S.MixB) or nil
		U.InCount.Visible = false
	end
	for i, slot in ipairs(U.InSlots) do
		setSlotPet(slot, inputs[i], (S.Tab == "Upgrade" and i ~= 2) and "Low" or "High")
	end
	-- result
	if not S.Animating then
		setSlotPet(U.ResultSlot, plan.ResultDef, "High")
		U.ResultSlot.Stroke.Color = plan.Rarity and rarityAccent(plan.Rarity) or NAVY
	end
	U.ResultName.Text = plan.ResultName or ((S.Tab == "Upgrade") and "Pick a pet" or "Pick two pets")
	U.ResultName.TextColor3 = plan.ResultDef and (S.Short and plan.Rarity and Theme.Lighten(rarityAccent(plan.Rarity), 0.35) or WHITE) or MUTED
	renderPills(plan)
	U.Info.Text = infoText(plan)
	U.Info.TextColor3 = MUTED
	setNotes(plan)
	-- cost
	if plan.Cost then
		local info = (plan.Cost.Currency == "Gems") and GEM_INFO or TOKEN_INFO
		U.Cost.Text = (S.CostOnly and "" or "Cost: ") .. tostring(info.Glyph) .. " " .. commas(plan.Cost.Amount)
		U.Cost.TextColor3 = (plan.CanAfford == false) and BAD or (info.Color or GOLD)
	else
		U.Cost.Text = "Cost: -"
		U.Cost.TextColor3 = MUTED
	end
	local can = plan.Ok and S.MachineNear and not S.Pending and not S.Animating
	CloudUI.SetDisabled(U.FuseButton, not can)
	if S.Pending then
		U.FuseButton.Text = "Fusing..."
	else
		U.FuseButton.Text = G.Sparkle .. " FUSE"
	end
	U.Locked.Visible = plan.Locked == true
	if plan.Locked then
		U.LockedText.Text = plan.Reason or ""
	end
end

local function renderTop()
	U.TokenChip.Text = tostring(TOKEN_INFO.Glyph) .. " " .. Theme.ShortNumber(balance("Tokens"))
	U.GemChip.Text = tostring(GEM_INFO.Glyph) .. " " .. Theme.ShortNumber(balance("Gems"))
	for name, button in pairs(U.Tabs) do
		local on = name == S.Tab
		CloudUI.SetStyle(button, on and "Pink" or "Blue")
		local scale = button:FindFirstChild("TabScale")
		if scale then
			scale.Scale = on and 1 or 0.94
		end
	end
end

refresh = function()
	if not S.Built then
		return
	end
	-- drop selections the player no longer owns (fused away, traded...)
	if S.UpKey and owned(S.UpKey) < 1 then
		S.UpKey = nil
	end
	if S.MixA and owned(S.MixA) < 1 then
		S.MixA = nil
	end
	if S.MixB and owned(S.MixB) < 1 then
		S.MixB = nil
	end
	local machine = S.AtMachine or myMachine()
	S.MachineNear = machine ~= nil and distanceTo(machine) <= K.NEAR_RANGE
	if not machine and not myMachine() then
		-- no machine in the world to stand at (homes not built yet): the server decides
		S.MachineNear = true
	end
	renderTop()
	refreshTiles()
	layoutPreview()
	local plan = computePlan()
	S.Plan = plan
	renderPreview(plan)
end

----------------------------------------------------------------------
-- Fusing + the fusion animation
----------------------------------------------------------------------
local function burst(parent, color, amount, centre)
	local rng = Random.new()
	for i = 1, amount do
		local size = rng:NextInteger(9, 16)
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
		local distance = rng:NextNumber(70, 190)
		local target = UDim2.new(centre.X.Scale, centre.X.Offset + math.cos(angle) * distance, centre.Y.Scale, centre.Y.Offset + math.sin(angle) * distance * 0.7 - 20)
		local seconds = rng:NextNumber(0.6, 1.1)
		tween(piece, seconds, { Position = target, Rotation = piece.Rotation + rng:NextInteger(-200, 200) })
		tween(piece, seconds, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Debris:AddItem(piece, seconds + 0.1)
	end
end

-- glowing cubes bursting out of the machine's output pod (client-only parts)
local function machineBurst(color)
	local machine = S.AtMachine or myMachine()
	local at = outputPoint(machine)
	if not at then
		return
	end
	local folder = workspace:FindFirstChild("ClientFx") or workspace
	local rng = Random.new()
	for i = 1, 10 do
		local part = Instance.new("Part")
		part.Name = "FusionSpark"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = (i % 3 == 0) and GOLD or ((i % 3 == 1) and color or Theme.Lighten(color, 0.5))
		part.Size = Vector3.new(0.4, 0.4, 0.4)
		part.CFrame = CFrame.new(at)
		part.Parent = folder
		local dir = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(0.6, 1.6), rng:NextNumber(-1, 1)).Unit
		tween(part, 0.8, { CFrame = CFrame.new(at + dir * rng:NextNumber(3, 6)) * CFrame.Angles(rng:NextNumber(0, 3), rng:NextNumber(0, 3), 0), Transparency = 1, Size = Vector3.new(0.1, 0.1, 0.1) })
		Debris:AddItem(part, 0.9)
	end
	local flash = Instance.new("Part")
	flash.Name = "FusionFlash"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanTouch = false
	flash.CanQuery = false
	flash.CastShadow = false
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	flash.Color = Theme.Lighten(color, 0.4)
	flash.Size = Vector3.new(1, 1, 1)
	flash.Transparency = 0.2
	flash.CFrame = CFrame.new(at)
	flash.Parent = folder
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 14
	light.Brightness = 2
	light.Parent = flash
	tween(flash, 0.5, { Size = Vector3.new(5, 5, 5), Transparency = 1 })
	tween(light, 0.5, { Brightness = 0 })
	Debris:AddItem(flash, 0.6)
end

local function slotCentre(slot)
	return slot.Frame.Position
end

local function playFusion(resultKey, rarity)
	S.Animating = true
	local mine = S.Token
	local color = rarity and rarityAccent(rarity) or ACCENT
	local target = slotCentre(U.ResultSlot)
	-- 1) the inputs fly into the machine (the result slot), spinning and shrinking
	local starts = {}
	for i, slot in ipairs(U.InSlots) do
		if slot.Frame.Visible then
			starts[i] = { Position = slot.Frame.Position, Rotation = slot.Frame.Rotation }
			tween(slot.Frame, 0.45, { Position = target, Rotation = slot.Frame.Rotation + 180 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			tween(slot.Scale, 0.45, { Scale = 0.2 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end
	end
	tween(U.ResultSlot.Scale, 0.45, { Scale = 0.7 })
	task.delay(0.45, function()
		if S.Token ~= mine then
			return
		end
		-- 2) a flash and a burst
		U.Flash.Position = target
		U.Flash.Size = UDim2.fromOffset(40, 40)
		U.Flash.BackgroundTransparency = 0.1
		U.Flash.BackgroundColor3 = Theme.Lighten(color, 0.6)
		U.Flash.Visible = true
		tween(U.Flash, 0.35, { Size = UDim2.fromOffset(300, 300), BackgroundTransparency = 1 })
		burst(U.SlotRow, color, 26, target)
		safe("machine fx", machineBurst, color)
		for i, slot in ipairs(U.InSlots) do
			if starts[i] then
				slot.Frame.Visible = false
			end
		end
		-- 3) the new pet pops in
		local def = defOf(resultKey)
		if def then
			setSlotPet(U.ResultSlot, def, "High")
		end
		U.ResultSlot.Scale.Scale = 0.4
		tween(U.ResultSlot.Scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		U.ResultSlot.Stroke.Color = color
		U.NewTag.Visible = true
		U.NewTag.Rotation = -8
		U.NewTag.Position = UDim2.new(target.X.Scale, target.X.Offset + 50, 0, target.Y.Offset - 70)
		if def then
			U.ResultName.Text = nameOf(def, resultKey)
		end
		task.delay(1.6, function()
			if S.Token ~= mine then
				return
			end
			-- 4) back to picking
			for i, slot in ipairs(U.InSlots) do
				if starts[i] then
					slot.Frame.Position = starts[i].Position
					slot.Frame.Rotation = starts[i].Rotation
					slot.Scale.Scale = 1
					slot.Frame.Visible = true
				end
			end
			U.Flash.Visible = false
			U.NewTag.Visible = false
			S.Animating = false
			refresh()
		end)
	end)
end

local function resetAnimation()
	S.Animating = false
	if not S.Built then
		return
	end
	for _, slot in ipairs(U.InSlots) do
		slot.Scale.Scale = 1
	end
	U.ResultSlot.Scale.Scale = 1
	U.Flash.Visible = false
	U.NewTag.Visible = false
end

local fusionRemote = nil
local function getRemote()
	if fusionRemote then
		return fusionRemote
	end
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = folder and folder:FindFirstChild("Fusion")
	if remote and remote:IsA("RemoteEvent") then
		fusionRemote = remote
	end
	return fusionRemote
end

function FusionController.Fuse()
	if not S.Open or S.Pending or S.Animating then
		return false
	end
	local plan = computePlan()
	S.Plan = plan
	if not plan.Ok or not S.MachineNear then
		refresh()
		return false
	end
	local remote = getRemote()
	if not remote then
		warnOnce("remote", "the Fusion remote is missing")
		return false
	end
	S.FuseToken = S.FuseToken + 1
	local token = S.FuseToken
	S.Pending = { Action = plan.Action, Token = token, At = os.clock(), Inputs = plan.Inputs }
	if plan.Action == "Upgrade" then
		remote:FireServer("Upgrade", S.UpKey)
	else
		remote:FireServer("Mix", S.MixA, S.MixB)
	end
	-- the inputs glow while the machine works
	for _, slot in ipairs(U.InSlots) do
		if slot.Frame.Visible then
			slot.Stroke.Color = GOLD
		end
	end
	refresh()
	task.delay(K.FUSE_TIMEOUT, function()
		if S.Pending and S.Pending.Token == token then
			S.Pending = nil
			refresh()
		end
	end)
	return true
end

local function onResult(payload)
	if type(payload) ~= "table" then
		return
	end
	local pending = S.Pending
	S.Pending = nil
	if payload.Ok == true and type(payload.Key) == "string" then
		local key = payload.Key
		if not S.Built or not S.Open then
			return
		end
		-- the inputs are gone: start the next pick from the new pet when it can go on
		local parsed = parse(key)
		if S.Tab == "Upgrade" then
			S.UpKey = (parsed and NEXT_TIER[parsed.Tier]) and key or nil
		else
			S.MixA, S.MixB = nil, nil
		end
		local function play()
			if S.Open and S.Built then
				playFusion(key, payload.Rarity)
			end
		end
		if defOf(key) then
			play()
		else
			-- the profile snapshot with the new pet may land a moment after the answer
			local conn
			local done = false
			conn = State.Changed:Connect(function()
				if not done and defOf(key) then
					done = true
					conn:Disconnect()
					play()
				end
			end)
			task.delay(2, function()
				if not done then
					done = true
					conn:Disconnect()
					play()
				end
			end)
		end
	else
		if pending and S.Built then
			if not payload.Quiet then
				local reason = type(payload.Reason) == "string" and payload.Reason or "That fusion did not work"
				U.ServerNote.Text = reason
				U.ServerNote.Visible = true
				local mine = S.Token
				task.delay(4, function()
					if S.Token == mine and U.ServerNote then
						U.ServerNote.Visible = false
					end
				end)
			end
			refresh()
		end
	end
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local function setTab(tab)
	if tab ~= "Upgrade" and tab ~= "Mix" then
		return
	end
	if S.Tab ~= tab then
		S.Tab = tab
		resetAnimation()
		if U.Grid then
			U.Grid.CanvasPosition = Vector2.new(0, 0)
		end
	end
	refresh()
end

local function buildTop(content)
	local top = makeFrame(content, "Top", {
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, K.TOP_H),
	})
	U.Top = top
	U.Tabs = {}
	local x = 0
	for _, spec in ipairs({ { "Upgrade", G.Up .. " UPGRADE" }, { "Mix", G.Dna .. " MIX" } }) do
		local name = spec[1]
		local button = CloudUI.Button({
			Name = "Tab_" .. name,
			Text = spec[2],
			Style = "Blue",
			Size = UDim2.fromOffset(196, 50),
			Position = UDim2.fromOffset(x, 2),
			TextSize = 24,
			Callback = function()
				safe("tab", setTab, name)
			end,
			Parent = top,
		})
		Util.Create("UIScale", { Name = "TabScale", Scale = 1, Parent = button })
		U.Tabs[name] = button
		x = x + 208
	end
	local function chip(name, color)
		local label = makeText(top, name, "", "Display", 24, color, {
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 44),
			BackgroundTransparency = 0,
			BackgroundColor3 = Color3.fromRGB(26, 34, 78),
			LayoutOrder = 1,
		})
		round(label)
		stroke(label, NAVY, 3, 0)
		pad(label, 16, 0, 16, 2)
		return label
	end
	local chips = makeFrame(top, "Chips", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 5),
		Size = UDim2.new(0, 360, 0, 44),
	})
	Util.Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 8),
		Parent = chips,
	})
	U.Chips = chips
	U.TokenChip = chip("Tokens", TOKEN_INFO.Color or GOLD)
	U.TokenChip.Parent = chips
	U.TokenChip.LayoutOrder = 1
	U.GemChip = chip("Gems", GEM_INFO.Color or Colors.Gem)
	U.GemChip.Parent = chips
	U.GemChip.LayoutOrder = 2
end

local function buildPicker(body)
	local picker = inset(body, "Picker", { Size = UDim2.new(0, K.PICKER_W, 1, 0) })
	U.Picker = picker
	U.PickerTitle = makeText(picker, "Title", "Your pets", "Heading", 24, WHITE, {
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(0.45, 0, 0, 32),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	U.PickerHint = makeText(picker, "Hint", "", "Body", 18, MUTED, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 10),
		Size = UDim2.new(0.58, 0, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local grid = Util.Create("ScrollingFrame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(8, 46),
		Size = UDim2.new(1, -16, 1, -54),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = Colors.FrameTop or Colors.Cloud,
		ScrollBarImageTransparency = 0.1,
		Parent = picker,
	})
	pad(grid, 4, 4, 14, 8)
	U.Grid = grid
	U.GridLayout = Util.Create("UIGridLayout", {
		CellSize = UDim2.fromOffset(K.TILE_W, K.TILE_H),
		CellPadding = UDim2.fromOffset(K.TILE_GAP, K.TILE_GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		Parent = grid,
	})
	U.Empty = makeText(picker, "Empty", "", "Body", 19, MUTED, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(1, -60, 0, 80),
		TextWrapped = true,
		Visible = false,
	})
end

local function buildPreview(body)
	local preview = inset(body, "Preview", {
		Position = UDim2.new(0, K.PICKER_W + K.GAP, 0, 0),
		Size = UDim2.new(1, -(K.PICKER_W + K.GAP), 1, 0),
	})
	U.Preview = preview
	U.PreviewTitle = makeText(preview, "Title", "", "Title", 30, WHITE, {
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -28, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	U.SlotRow = makeFrame(preview, "Slots", { Size = UDim2.new(1, 0, 0, 190), ZIndex = 3 })
	U.InSlots = {}
	for i = 1, 3 do
		U.InSlots[i] = slotFrame(U.SlotRow, "Input" .. i, K.INPUT)
	end
	-- the middle card of the Upgrade stack sits on top
	U.InSlots[2].Frame.ZIndex = 5
	U.InCount = makeText(U.InSlots[2].Frame, "Copies", "0/3", "Heading", 20, WHITE, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.fromOffset(64, 30),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(30, 40, 90),
		ZIndex = 8,
		Visible = false,
	})
	round(U.InCount)
	stroke(U.InCount, NAVY, 2, 0)
	U.Plus = makeText(U.SlotRow, "Plus", G.Plus, "Title", 40, WHITE, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(40, 40),
		ZIndex = 6,
	})
	U.CaptionA = makeText(U.SlotRow, "Body", "Body", "Heading", 18, MUTED, {
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(110, 24),
	})
	U.CaptionB = makeText(U.SlotRow, "Style", "Style", "Heading", 18, MUTED, {
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(110, 24),
	})
	U.Swap = CloudUI.Button({
		Name = "Swap",
		Text = G.Swap,
		Style = "Blue",
		TextSize = 22,
		Size = UDim2.fromOffset(44, 36),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 7,
		Callback = function()
			if not S.Pending and not S.Animating then
				S.MixA, S.MixB = S.MixB, S.MixA
				safe("swap", refresh)
			end
		end,
		Parent = U.SlotRow,
	})
	local swapPad = U.Swap:FindFirstChildOfClass("UIPadding")
	if swapPad then
		swapPad.PaddingLeft = UDim.new(0, 0)
		swapPad.PaddingRight = UDim.new(0, 0)
	end
	U.Arrow = makeText(U.SlotRow, "Arrow", G.Arrow, "Title", 36, GOLD, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(44, 44),
		ZIndex = 4,
	})
	U.ResultSlot = slotFrame(U.SlotRow, "Result", K.RESULT)
	U.ResultSlot.Frame.ZIndex = 6
	U.Flash = makeFrame(U.SlotRow, "Flash", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BackgroundColor3 = WHITE,
		ZIndex = 11,
		Visible = false,
	})
	round(U.Flash)
	U.NewTag = makeText(U.SlotRow, "New", "NEW!", "Title", 26, WHITE, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(92, 38),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(232, 84, 120),
		ZIndex = 13,
		Visible = false,
	})
	corner(U.NewTag, 10)
	stroke(U.NewTag, NAVY, 3, 0)

	U.ResultName = makeText(preview, "ResultName", "", "Title", 28, WHITE, {
		Size = UDim2.new(1, -28, 0, 36),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	U.Pills = makeFrame(preview, "Pills", { Size = UDim2.new(1, -28, 0, 32) })
	U.PillsLayout = Util.Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 8),
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Parent = U.Pills,
	})
	-- the explanation and the notes share one list, so they never overlap
	U.Details = makeFrame(preview, "Details", { Size = UDim2.new(1, -28, 0, 100), ClipsDescendants = true })
	Util.Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
		Parent = U.Details,
	})
	U.Info = makeText(U.Details, "Info", "", "Body", 18, MUTED, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 1,
	})
	-- the cost and the FUSE button along the bottom
	local bottom = makeFrame(preview, "Bottom", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -12),
		Size = UDim2.new(1, -28, 0, 64),
	})
	U.Bottom = bottom
	U.Cost = makeText(bottom, "Cost", "Cost: -", "Display", 28, GOLD, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, -230, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	U.FuseButton = CloudUI.Button({
		Name = "Fuse",
		Text = G.Sparkle .. " FUSE",
		Style = "Green",
		TextSize = 28,
		Size = UDim2.fromOffset(214, 62),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Callback = function()
			safe("fuse", FusionController.Fuse)
		end,
		Parent = bottom,
	})
	U.ServerNote = makeText(preview, "ServerNote", "", "Body", 18, BAD, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -82),
		Size = UDim2.new(1, -28, 0, 26),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(40, 20, 50),
		TextWrapped = true,
		Visible = false,
		ZIndex = 6,
	})
	corner(U.ServerNote, 8)

	-- locked overlay (no Prestige / no machine yet): an opaque card (nothing of the preview shows through it) with the
	-- crystal, the reason and a line about what the machine will do
	U.Locked = makeFrame(preview, "Locked", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 0,
		BackgroundColor3 = WHITE, -- the gradient below colours it
		ZIndex = 20,
		Visible = false,
	})
	corner(U.Locked, 12)
	Theme.Gradient(U.Locked, Color3.fromRGB(58, 46, 120), Color3.fromRGB(18, 22, 56), 90)
	U.LockedIcon = makeText(U.Locked, "Icon", G.Crystal, "Title", 64, WHITE, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0.45, 0),
		Size = UDim2.fromOffset(90, 90),
		ZIndex = 21,
	})
	U.LockedText = makeText(U.Locked, "Text", "", "Heading", 24, WHITE, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.48, 0),
		Size = UDim2.new(1, -60, 0, 64),
		TextWrapped = true,
		ZIndex = 21,
	})
	U.LockedSub = makeText(U.Locked, "Sub", "Fuse 3 copies into a Golden or Rainbow pet, or mix two pets into a brand-new hybrid!",
		"Body", 19, Color3.fromRGB(196, 186, 240), {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0.48, 70),
			Size = UDim2.new(1, -60, 0, 52),
			TextWrapped = true,
			ZIndex = 21,
		})
end

local function buildWindow()
	if S.Built then
		return true
	end
	local holder = makeFrame(U.Gui, "Window_Fusion", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.fromOffset(K.PREF_W, K.PREF_H),
		Visible = false,
		ZIndex = 3,
	})
	U.Holder = holder
	U.Fit = Util.Create("UIScale", { Name = "Fit", Scale = 1, Parent = holder })
	local panel = CloudUI.Panel({
		Name = "FusionPanel",
		Title = G.Crystal .. " Fusion Machine",
		Closable = true,
		Accent = ACCENT,
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		OnClose = function()
			FusionController.Close()
		end,
		Parent = holder,
	})
	U.Panel = panel
	U.Pop = Util.Create("UIScale", { Name = "Pop", Scale = 1, Parent = panel.Root })
	local content = panel.Content
	buildTop(content)
	U.Body = makeFrame(content, "Body", {
		Position = UDim2.fromOffset(10, K.TOP_H + 16),
		Size = UDim2.new(1, -20, 1, -(K.TOP_H + 26)),
	})
	buildPicker(U.Body)
	buildPreview(U.Body)
	S.Built = true
	relayout()
	return true
end

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

-- the menu windows and the Pet Index share the screen: one window at a time
local function closeOthers()
	local controllers = script.Parent
	for _, name in ipairs({ "MenuController", "IndexController" }) do
		local module = controllers:FindFirstChild(name)
		if module then
			local ok, mod = pcall(require, module)
			if ok and type(mod) == "table" and type(mod.Close) == "function" then
				pcall(mod.Close)
			end
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function FusionController.IsOpen()
	return S.Open
end

function FusionController.Plan()
	return S.Plan
end

function FusionController.Select(keyA, keyB)
	if S.Tab == "Upgrade" then
		S.UpKey = keyA
	else
		S.MixA, S.MixB = keyA, keyB
	end
	if S.Built then
		refresh()
	end
end

function FusionController.Open(tab, args)
	if not initialized then
		FusionController.Init()
	end
	if not U.Gui then
		return
	end
	if LocalPlayer and LocalPlayer:GetAttribute(Config.Attr.InMatch) == true then
		return
	end
	if not buildWindow() then
		return
	end
	args = type(args) == "table" and args or {}
	if tab == "Upgrade" or tab == "Mix" then
		S.Tab = tab
	end
	if type(args.Key) == "string" then
		if S.Tab == "Upgrade" then
			S.UpKey = args.Key
		else
			S.MixA = args.Key
			S.MixB = type(args.KeyB) == "string" and args.KeyB or S.MixB
		end
	end
	if typeof(args.Machine) == "Instance" then
		S.AtMachine = args.Machine
	elseif not S.Open then
		S.AtMachine = nil
	end
	local wasOpen = S.Open
	if not wasOpen then
		closeOthers()
	end
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
	safe("refresh", refresh)
	if not wasOpen then
		FusionController.Opened:Fire(S.Tab)
	end
end

function FusionController.Close()
	if not S.Open then
		return
	end
	S.Open = false
	S.Token = S.Token + 1
	local mine = S.Token
	S.AtMachine = nil
	resetAnimation()
	syncBackBinding()
	tween(U.Pop, 0.12, { Scale = 0.9 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.13, function()
		if S.Token == mine and not S.Open and U.Holder then
			U.Holder.Visible = false
		end
	end)
	setBackdrop(false)
	FusionController.Closed:Fire()
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
local function onPromptTriggered(prompt)
	if typeof(prompt) ~= "Instance" or prompt.Name ~= "FusionPrompt" then
		return
	end
	local owner = prompt:GetAttribute("OwnerUserId")
	if owner ~= nil and LocalPlayer and owner ~= LocalPlayer.UserId then
		return -- someone else's machine (its prompt is disabled locally anyway)
	end
	local model = prompt:FindFirstAncestor("Station_FusionMachine")
	FusionController.Open(nil, { Machine = model })
end

local function connectOthers()
	local controllers = script.Parent
	local function hook(name, signalName)
		local module = controllers:FindFirstChild(name)
		if not module then
			return
		end
		local ok, mod = pcall(require, module)
		local signal = ok and type(mod) == "table" and mod[signalName]
		if type(signal) == "table" and type(signal.Connect) == "function" then
			signal:Connect(function()
				FusionController.Close()
			end)
		end
	end
	hook("MenuController", "WindowOpened")
	hook("IndexController", "Opened")
end

function FusionController.Init()
	if initialized then
		return
	end
	initialized = true
	LocalPlayer = Players.LocalPlayer
	pcall(State.Init)

	local gui = CloudUI.NewScreenGui("NimbusFusion", K.DISPLAY_ORDER)
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
		FusionController.Close()
	end)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if S.Built then
			safe("relayout", relayout)
		end
	end)

	State.Changed:Connect(function()
		if S.Open and not S.Animating then
			safe("State.Changed", refresh)
		end
	end)
	for _, signalName in ipairs({ "TokensChanged", "GemsChanged" }) do
		local signal = State[signalName]
		if type(signal) == "table" and type(signal.Connect) == "function" then
			signal:Connect(function()
				if S.Open and not S.Animating then
					safe("balance", refresh)
				end
			end)
		end
	end
	if LocalPlayer then
		LocalPlayer:GetAttributeChangedSignal(Config.Attr.InMatch):Connect(function()
			if LocalPlayer:GetAttribute(Config.Attr.InMatch) == true then
				FusionController.Close()
			end
		end)
	end

	UserInputService.InputBegan:Connect(function(input)
		if S.Open and input.KeyCode == Enum.KeyCode.Escape then
			FusionController.Close()
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		safe("prompt", onPromptTriggered, prompt)
	end)

	task.spawn(function()
		local okOpen, openRemote = pcall(Remotes.Get, "OpenPanel")
		if okOpen and openRemote then
			openRemote.OnClientEvent:Connect(function(panelId, args)
				if type(panelId) == "string" and panelId:lower() == "fusion" then
					local tab = type(args) == "table" and args.Tab or nil
					safe("OpenPanel", FusionController.Open, tab, args)
				end
			end)
		end
		local okFusion, remote = pcall(Remotes.Get, "Fusion")
		if okFusion and remote then
			fusionRemote = remote
			remote.OnClientEvent:Connect(function(kind, payload)
				if kind == "Result" then
					safe("result", onResult, payload)
				end
			end)
		end
	end)
	task.defer(function()
		safe("hooks", connectOthers)
	end)

	-- one light loop: pet viewports under a time budget, and the walk-away check (4 times a second)
	local checkAt = 0
	RunService.Heartbeat:Connect(function()
		if not S.Open then
			return
		end
		fillViewports()
		local now = os.clock()
		if now < checkAt then
			return
		end
		checkAt = now + 0.25
		if S.AtMachine then
			if distanceTo(S.AtMachine) > K.MACHINE_RANGE then
				FusionController.Close()
				return
			end
		end
		if S.Pending == nil and not S.Animating then
			local machine = S.AtMachine or myMachine()
			local near = machine == nil or distanceTo(machine) <= K.NEAR_RANGE
			if near ~= S.MachineNear then
				safe("near", refresh)
			end
		end
	end)
end

return FusionController
