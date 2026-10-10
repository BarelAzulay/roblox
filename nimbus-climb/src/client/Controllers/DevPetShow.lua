-- DevPetShow (client): the developer's pet showcase. The server half is DevService ("/pet", "/pets", "/evolve",
-- "/clearpets"): it checks the permission and sends DevPetShow(action, payload) to the developer's own client.
--
--   DevPetShow.Init()
--   Extras (tests): DevPetShow.Handle(action, payload) (what the remote does), DevPetShow.Count() -> showcase pets
--                   in the world, DevPetShow.Busy() -> a lineup is being built or an evolution is playing,
--                   DevPetShow.Folder() -> the workspace folder (nil before the first pet)
--
-- The pets are built here with PetBuilder at Scale 1 (the size they have in the game) into the workspace folder
-- "DevPetShow": only this player sees them, and the server never has to replicate thousands of parts.
--   Spawn {PetId, Stage}    the pet at stage 0 (normal), 1 (evolved) or 2 (second evolution) in front of the player,
--                           facing them and hovering over the ground, beside the ones already there (they stay
--                           until Clear; the oldest goes past MAX_PETS)
--   Lineup {Stage, PetIds}  clears, builds every listed pet (one per frame) and stands them in rows in front of the
--                           player, all facing the same way; Low detail when the lineup would pass LINEUP_PARTS parts
--   Evolve {Steps}          clears, then plays the evolution animations (client/Controllers/EvolutionFx.lua) one
--                           after another in front of the player; Steps = { {PetId, From, To}, ... } with To = From + 1.
--                           A pet's line carries on with the evolved pet (normal -> evolved -> evolved II); after a
--                           short pause the next pet of a reel takes its place. The last one stays.
--   Clear {}                stops an evolution or a lineup and removes every showcase pet
-- Lineup, Evolve and Clear take over from whatever was running; Spawn adds to it. Resting pets get the tag
-- NC_Showcase (ShowcaseController makes them hover, flap, wag and blink) and a compact name tag (World text rule:
-- pixel-sized, 24 px name and 19 px info line, outlined, on a solid plate sized to its text, LightInfluence 0,
-- MaxDistance 120). Payloads are checked again here (catalog ids, stages each pet really has).
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local function optionalModule(parent, name)
	local module = parent:FindFirstChild(name) or parent:WaitForChild(name, 5)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[DevPetShow] failed to load " .. name .. ": " .. tostring(result))
	return nil
end

local PetBuilder = optionalModule(Shared, "PetBuilder")
local PetCatalog = optionalModule(Shared, "PetCatalog")
local EvolutionFx = optionalModule(script.Parent, "EvolutionFx")

local DevPetShow = {}

local K = {
	FOLDER = "DevPetShow",
	TAG = "NC_Showcase", -- ShowcaseController animates models with this tag
	MAX_PETS = 40,
	HOVER = 0.7, -- studs between a pet's lowest point and the ground
	BOB = 0.3, -- ShowcaseController hover amplitude (studs)
	AHEAD = 6, -- studs from the player to the nearest pet's edge
	GAP = 1.6, -- studs between two pets
	PER_ROW = 8,
	LINEUP_PARTS = 26000, -- above this a lineup is built at Low detail
	PARTS = { [0] = 350, [1] = 1560, [2] = 2000 }, -- High detail part caps per stage (PetBuilder header)
	LOOK = 0.6, -- seconds a pet is shown before it evolves
	STEP_PAUSE = 0.5, -- seconds between the two evolutions of one pet
	PAUSE = 1.8, -- seconds an evolved pet rests before the next pet of a reel
	NAME_PX = 24, -- World text rule: names >= 22 px, info lines >= 18 px (1080p design pixels)
	INFO_PX = 19,
	TAG_W = 280,
	TAG_H = 70,
	TAG_DISTANCE = 120,
	RAY = 90, -- studs searched down for the ground
}
local STAGE_NAMES = { [0] = "Normal", [1] = "Evolved", [2] = "Evolved II" }

local folder = nil
local pets = {} -- { { Model, Pos = Vector3 (root, flat), Radius } } resting showcase pets, oldest first
local generation = 0 -- Lineup / Evolve / Clear bump it: a running lineup or evolution stops when it changes
local current = nil -- the EvolutionFx handle that is playing
local busy = 0
local initialized = false

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function getFolder()
	if folder and folder.Parent then
		return folder
	end
	folder = Workspace:FindFirstChild(K.FOLDER)
	if not (folder and folder:IsA("Folder")) then
		folder = Instance.new("Folder")
		folder.Name = K.FOLDER
		folder.Parent = Workspace
	end
	return folder
end

local function defOf(id)
	if type(id) ~= "string" or not PetCatalog then
		return nil
	end
	local ok, def = pcall(PetCatalog.Get, id)
	if ok and type(def) == "table" then
		return def
	end
	return nil
end

local function maxStage(def)
	local ok, top = pcall(PetBuilder.MaxEvolution, def)
	if ok and (top == 1 or top == 2) then
		return top
	end
	return 1
end

local function validStage(def, stage)
	return type(stage) == "number" and stage == math.floor(stage) and stage >= 0 and stage <= maxStage(def)
end

local function rarityColor(rarity)
	for _, r in ipairs(Config.Rarities or {}) do
		if r.Id == rarity and typeof(r.Color) == "Color3" then
			if rarity == "Secret" then
				return Color3.fromRGB(150, 236, 255) -- the dark Secret colour does not show on the navy plate
			end
			return r.Color
		end
	end
	return Theme.Colors.Gold
end

-- The player's position and the flat direction they look at.
local function playerFrame()
	local player = Players.LocalPlayer
	local char = player and player.Character
	local root = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
	local cf
	if root and root:IsA("BasePart") then
		cf = root.CFrame
	else
		local cam = Workspace.CurrentCamera
		cf = cam and cam.CFrame or CFrame.new(0, 300, 0)
	end
	local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if look.Magnitude < 0.01 then
		look = Vector3.new(0, 0, -1)
	end
	return cf.Position, look.Unit, char
end

-- y of the ground under pos (the player's feet when nothing is found)
local function groundAt(pos, char, fallback)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { getFolder() }
	if char then
		ignore[#ignore + 1] = char
	end
	params.FilterDescendantsInstances = ignore
	local ok, hit = pcall(function()
		return Workspace:Raycast(pos + Vector3.new(0, 8, 0), Vector3.new(0, -K.RAY, 0), params)
	end)
	if ok and hit then
		return hit.Position.Y
	end
	return fallback
end

-- The built pet's extent around its root (PetBuilder builds the root at the origin): lowest and highest point,
-- and the horizontal radius from the root.
local function extentOf(model)
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if not ok or typeof(cf) ~= "CFrame" then
		return -1.5, 1.5, 2
	end
	local root = model.PrimaryPart
	local rel = root and root.CFrame:PointToObjectSpace(cf.Position) or cf.Position
	local bottom = rel.Y - size.Y / 2
	local top = rel.Y + size.Y / 2
	local radius = math.max(math.abs(rel.X) + size.X / 2, math.abs(rel.Z) + size.Z / 2)
	return bottom, top, radius
end

local function build(def, stage, detail)
	local ok, model = pcall(PetBuilder.Build, def, { Detail = detail or "High", Evolved = (stage > 0) and stage or nil })
	if not ok or typeof(model) ~= "Instance" or not model.PrimaryPart then
		warn("[DevPetShow] could not build " .. tostring(def.Id) .. " stage " .. tostring(stage) .. ": " .. tostring(model))
		return nil
	end
	model.Name = "DevPet_" .. tostring(def.Id) .. "_" .. stage
	model:SetAttribute("DevPetStage", stage)
	return model
end

-- Root CFrame of a pet standing at flat position `spot` (its lowest point HOVER above the ground), facing `facing`.
local function poseAt(spot, bottom, facing, char, fallbackY)
	local ground = groundAt(Vector3.new(spot.X, fallbackY + 4, spot.Z), char, fallbackY)
	local pos = Vector3.new(spot.X, ground + K.HOVER - bottom, spot.Z)
	return CFrame.lookAt(pos, pos + facing), ground
end

local function nameTag(model, def, stage, top)
	local root = model.PrimaryPart
	if not root then
		return
	end
	local k = 1
	local okScale, factor = pcall(Theme.ScreenFactor)
	if okScale and type(factor) == "number" and factor > 0 then
		k = factor
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "DevPetTag"
	gui.Size = UDim2.fromOffset(math.floor(K.TAG_W * k), math.floor(K.TAG_H * k))
	gui.StudsOffsetWorldSpace = Vector3.new(0, top + 1.4, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = K.TAG_DISTANCE
	gui.ClipsDescendants = false
	gui.Adornee = root
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.BackgroundColor3 = Theme.Colors.Navy
	card.BackgroundTransparency = 0.04
	card.BorderSizePixel = 0
	card.AnchorPoint = Vector2.new(0.5, 1)
	card.Position = UDim2.fromScale(0.5, 1)
	card.Size = UDim2.fromOffset(0, 0)
	card.AutomaticSize = Enum.AutomaticSize.XY
	card.Parent = gui
	Theme.Corner(card, UDim.new(0, 12))
	Theme.Stroke(card, rarityColor(def.Rarity), 3, 0)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = card
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 1)
	list.Parent = card
	local scale = Instance.new("UIScale")
	scale.Name = "ReadScale"
	scale.Scale = k
	scale.Parent = card
	local name = Theme.Label(tostring(def.Name or def.Id), "Heading", { Size = K.NAME_PX, Color = Theme.Colors.White, Outline = 2 })
	name.Name = "Name"
	name.AutomaticSize = Enum.AutomaticSize.XY
	name.Size = UDim2.fromOffset(0, K.NAME_PX + 4)
	name.TextWrapped = false
	name.LayoutOrder = 1
	name.Parent = card
	local info = Theme.Label(STAGE_NAMES[stage] .. "  \226\128\162  " .. tostring(def.Rarity or ""), "Label", { Size = K.INFO_PX, Color = rarityColor(def.Rarity), Outline = 2 })
	info.Name = "Info"
	info.AutomaticSize = Enum.AutomaticSize.XY
	info.Size = UDim2.fromOffset(0, K.INFO_PX + 4)
	info.TextWrapped = false
	info.LayoutOrder = 2
	info.Parent = card
	gui.Parent = root
end

-- A pet at rest: name tag, then ShowcaseController brings it to life.
local function rest(model, def, stage, pos, radius)
	local _, top = extentOf(model)
	model:SetAttribute("Ready", true)
	model:SetAttribute("HoverAmp", K.BOB)
	nameTag(model, def, stage, top)
	CollectionService:AddTag(model, K.TAG)
	pets[#pets + 1] = { Model = model, Pos = Vector3.new(pos.X, 0, pos.Z), Radius = radius }
	while #pets > K.MAX_PETS do
		local old = table.remove(pets, 1)
		pcall(function()
			old.Model:Destroy()
		end)
	end
end

local function clearAll()
	if current then
		pcall(current.Stop)
		current = nil
	end
	for _, rec in ipairs(pets) do
		pcall(function()
			rec.Model:Destroy()
		end)
	end
	pets = {}
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			pcall(function()
				child:Destroy()
			end)
		end
	end
end

-- The first free spot on the line in front of the player (nearest the middle first).
local function freeSpot(origin, look, radius)
	local right = Vector3.new(-look.Z, 0, look.X)
	local base = Vector3.new(origin.X, 0, origin.Z) + look * (K.AHEAD + radius)
	for i = 0, 40 do
		local side = (i == 0) and 0 or (((i % 2 == 1) and 1 or -1) * math.ceil(i / 2))
		local spot = base + right * side * (radius + K.GAP)
		local free = true
		for _, rec in ipairs(pets) do
			if rec.Model.Parent and (rec.Pos - spot).Magnitude < rec.Radius + radius + K.GAP * 0.5 then
				free = false
				break
			end
		end
		if free then
			return spot
		end
	end
	return base
end

----------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------
local function spawnPet(payload)
	local def = defOf(payload.PetId)
	if not def or not validStage(def, payload.Stage) then
		return false
	end
	local model = build(def, payload.Stage, "High")
	if not model then
		return false
	end
	local origin, look, char = playerFrame()
	local bottom, _, radius = extentOf(model)
	local spot = freeSpot(origin, look, radius)
	local pose = poseAt(spot, bottom, -look, char, origin.Y - 3)
	model:PivotTo(pose)
	model.Parent = getFolder()
	rest(model, def, payload.Stage, spot, radius)
	return true
end

local function lineup(payload, gen)
	local stage = payload.Stage
	if type(payload.PetIds) ~= "table" or type(stage) ~= "number" then
		return false
	end
	local defs = {}
	for _, id in ipairs(payload.PetIds) do
		local def = defOf(id)
		if def and validStage(def, stage) then
			defs[#defs + 1] = def
		end
	end
	if #defs == 0 then
		return false
	end
	busy = busy + 1
	local detail = (#defs * (K.PARTS[stage] or 350) > K.LINEUP_PARTS) and "Low" or "High"
	-- build them all first (one per frame), then stand them in rows
	local built = {}
	local maxR = 1
	for _, def in ipairs(defs) do
		if gen ~= generation then
			break
		end
		local model = build(def, stage, detail)
		if model then
			local bottom, _, radius = extentOf(model)
			built[#built + 1] = { Model = model, Def = def, Bottom = bottom, Radius = radius }
			maxR = math.max(maxR, radius)
		end
		task.wait()
	end
	if gen ~= generation then
		for _, b in ipairs(built) do
			pcall(function()
				b.Model:Destroy()
			end)
		end
		busy = busy - 1
		return false
	end
	local origin, look, char = playerFrame()
	local right = Vector3.new(-look.Z, 0, look.X)
	local perRow = math.min(K.PER_ROW, #built)
	local pitch = maxR * 2 + K.GAP
	local parent = getFolder()
	for i, b in ipairs(built) do
		local row = math.floor((i - 1) / perRow)
		local col = (i - 1) % perRow
		local inRow = math.min(perRow, #built - row * perRow)
		local spot = Vector3.new(origin.X, 0, origin.Z) + look * (K.AHEAD + maxR + row * (pitch + K.GAP)) + right * ((col - (inRow - 1) / 2) * pitch)
		local pose = poseAt(spot, b.Bottom, -look, char, origin.Y - 3)
		b.Model:PivotTo(pose)
		b.Model.Parent = parent
		rest(b.Model, b.Def, stage, spot, b.Radius)
	end
	busy = busy - 1
	return true
end

-- Groups the steps into chains: consecutive steps of one pet where each starts where the previous ended.
local function chainsOf(steps)
	local chains = {}
	local last = nil
	for _, st in ipairs(steps) do
		if type(st) == "table" then
			local def = defOf(st.PetId)
			if def and validStage(def, st.From) and validStage(def, st.To) and st.To == st.From + 1 then
				if last and last.Def == def and last.To == st.From then
					last.Steps[#last.Steps + 1] = st
					last.To = st.To
				else
					last = { Def = def, From = st.From, To = st.To, Steps = { st } }
					chains[#chains + 1] = last
				end
			end
		end
	end
	return chains
end

local function evolveReel(payload, gen)
	if type(payload.Steps) ~= "table" or not EvolutionFx then
		return false
	end
	local chains = chainsOf(payload.Steps)
	if #chains == 0 then
		return false
	end
	busy = busy + 1
	local onShow = nil -- the model resting from the previous chain
	for ci, chain in ipairs(chains) do
		if gen ~= generation then
			break
		end
		if onShow then
			task.wait(K.PAUSE)
			if gen ~= generation then
				break
			end
			pcall(function()
				onShow:Destroy()
			end)
			onShow = nil
		end
		-- every stage of the chain is built first: the biggest one decides where it stands
		local models = {}
		local bottom, radius = 0, 1
		for stage = chain.From, chain.To do
			local m = build(chain.Def, stage, "High")
			if not m then
				break
			end
			models[stage] = m
			local b, _, r = extentOf(m)
			bottom, radius = math.min(bottom, b), math.max(radius, r)
			task.wait()
		end
		if gen ~= generation or not models[chain.To] then
			for _, m in pairs(models) do
				pcall(function()
					m:Destroy()
				end)
			end
			break
		end
		local origin, look, char = playerFrame()
		local spot = Vector3.new(origin.X, 0, origin.Z) + look * (K.AHEAD + radius)
		local pose, ground = poseAt(spot, bottom, -look, char, origin.Y - 3)
		local parent = getFolder()
		local model = models[chain.From]
		model:PivotTo(pose)
		model.Parent = parent
		task.wait(K.LOOK)
		for si, st in ipairs(chain.Steps) do
			if gen ~= generation then
				break
			end
			if si > 1 then
				task.wait(K.STEP_PAUSE)
				if gen ~= generation then
					break
				end
			end
			local toModel = models[st.To]
			local okColors, a, b = pcall(PetBuilder.EvolutionColors, chain.Def, st.To)
			local handle = EvolutionFx.Play(model, toModel, pose, {
				Parent = parent,
				Colors = okColors and { a, b } or nil,
				Stage = st.To,
				Ground = ground,
			})
			current = handle
			while not handle.Done do
				if gen ~= generation then
					pcall(handle.Stop)
					break
				end
				task.wait(0.1)
			end
			if current == handle then
				current = nil
			end
			model = toModel
		end
		-- a stage built but never shown (stopped part-way) goes away
		for _, m in pairs(models) do
			if m ~= model then
				pcall(function()
					m:Destroy()
				end)
			end
		end
		if gen ~= generation then
			pcall(function()
				model:Destroy()
			end)
			break
		end
		if ci == #chains then
			rest(model, chain.Def, chain.To, spot, radius)
		else
			onShow = model
		end
	end
	if onShow and gen ~= generation then
		pcall(function()
			onShow:Destroy()
		end)
	end
	busy = busy - 1
	return true
end

function DevPetShow.Handle(action, payload)
	if type(action) ~= "string" then
		return false
	end
	payload = type(payload) == "table" and payload or {}
	if not (PetBuilder and PetCatalog) then
		warn("[DevPetShow] PetBuilder / PetCatalog are missing")
		return false
	end
	if action == "Spawn" then
		local ok, result = pcall(spawnPet, payload)
		if not ok then
			warn("[DevPetShow] Spawn failed: " .. tostring(result))
		end
		return ok and result == true
	end
	if action ~= "Lineup" and action ~= "Evolve" and action ~= "Clear" then
		return false
	end
	generation = generation + 1
	local gen = generation
	clearAll()
	if action == "Clear" then
		return true
	end
	task.spawn(function()
		local fn = (action == "Lineup") and lineup or evolveReel
		local ok, err = pcall(fn, payload, gen)
		if not ok then
			warn("[DevPetShow] " .. action .. " failed: " .. tostring(err))
			busy = math.max(0, busy - 1)
		end
	end)
	return true
end

function DevPetShow.Count()
	local n = 0
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") then
				n = n + 1
			end
		end
	end
	return n
end

function DevPetShow.Busy()
	return busy > 0
end

function DevPetShow.Folder()
	return folder
end

function DevPetShow.Init()
	if initialized then
		return
	end
	initialized = true
	local ok, remote = pcall(Remotes.Get, "DevPetShow")
	if not (ok and remote) then
		warn("[DevPetShow] the DevPetShow remote is missing")
		return
	end
	remote.OnClientEvent:Connect(function(action, payload)
		DevPetShow.Handle(action, payload)
	end)
end

return DevPetShow
