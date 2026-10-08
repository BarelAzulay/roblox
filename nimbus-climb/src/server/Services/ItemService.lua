-- ItemService: the item shop and usable match items (ARCHITECTURE_V2.md section 2).
--
--   ItemService.Init(lobbyInfo, deps)    deps = { DataService, DamageService, MatchService } (all optional;
--                                        siblings are required lazily). ItemService.SetMatchService(ms) also works.
--   ItemService.Buy(player, itemId, qty) -> ok, reason     lobby only, spends tokens, respects Config.Items.MaxCarry
--   ItemService.Use(player, itemId)      -> ok, reason     match only, alive, not downed
--
-- Items (ItemCatalog.List order):
--   heal_cloud       heals 40% of max health (refused at full health, nothing consumed)
--   shield_bubble    8 s of invulnerability + a soft bubble around the character
--   phoenix_feather  revives the nearest downed teammate of your match (50% health via DamageService.Revive);
--                    consumed only if someone was actually revived
--
-- The remotes BuyItem / UseItem are connected here: rate limited, type checked, known ids only.
-- Plain Lua 5.1-compatible syntax only.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)
local DataService = require(script.Parent.DataService)

local ItemService = {}

local HEAL_FRACTION = 0.4
local SHIELD_SECONDS = 8
local REMOTE_COOLDOWN = 0.25 -- seconds per player per remote
local USE_COOLDOWN = 0.6 -- after a successful use, so a double click cannot burn two items
local PROMPT_COOLDOWN = 0.5
local MAX_ID_LENGTH = 48
local PROMPT_NAME = "ItemShopPrompt"

----------------------------------------------------------------------
-- Optional collaborators (every use is guarded)
----------------------------------------------------------------------

local function loadShared(name)
	local module = Shared:FindFirstChild(name) or Shared:WaitForChild(name, 5)
	if not module then
		warn("[ItemService] missing shared module: " .. name)
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[ItemService] could not load " .. name .. ": " .. tostring(result))
	return nil
end

local ItemCatalog = loadShared("ItemCatalog")

local DamageService = nil
do
	local ok, result = pcall(require, script.Parent.DamageService)
	if ok and type(result) == "table" then
		DamageService = result
	end
end

local MatchService = nil
local matchResolved = false

-- MatchService is wired by Init(deps) or SetMatchService; as a last resort require the sibling.
local function getMatchService()
	if MatchService then
		return MatchService
	end
	if not matchResolved then
		matchResolved = true
		local ok, result = pcall(require, script.Parent.MatchService)
		if ok and type(result) == "table" then
			MatchService = result
		end
	end
	return MatchService
end

function ItemService.SetMatchService(matchService)
	MatchService = matchService
	matchResolved = true
end

----------------------------------------------------------------------
-- State + helpers
----------------------------------------------------------------------

local lastCall = {} -- [player] = { [key] = os.clock() }
local shields = {} -- [player] = { Bubble = Part|nil, Expires = os.clock() }
local useReadyAt = {} -- [player] = os.clock() after which the next Use is accepted
local remotesConnected = false
local playersConnected = false
local promptObject = nil

local function isLivePlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function rateLimited(player, key, interval)
	local record = lastCall[player]
	if not record then
		record = {}
		lastCall[player] = record
	end
	local now = os.clock()
	local last = record[key]
	if last and now - last < interval then
		return true
	end
	record[key] = now
	return false
end

local function fireClient(remoteName, player, ...)
	local ok, remote = pcall(Remotes.Get, remoteName)
	if ok and remote and player and player.Parent then
		remote:FireClient(player, ...)
	end
end

local function notify(player, text, kind, duration)
	fireClient("Notify", player, text, kind or "info", duration or 3)
end

local function isDowned(player)
	if player:GetAttribute(Config.Attr.Downed) == true then
		return true
	end
	if DamageService and type(DamageService.IsDowned) == "function" then
		local ok, result = pcall(DamageService.IsDowned, player)
		return ok and result == true
	end
	return false
end

----------------------------------------------------------------------
-- Effects. Each returns ok, reasonOrMessage. None of them yields, so
-- "check the count, apply, consume" stays atomic.
----------------------------------------------------------------------

local function removeShield(player)
	local record = shields[player]
	if not record then
		return
	end
	shields[player] = nil
	local bubble = record.Bubble
	if bubble and bubble.Parent then
		Util.Tween(bubble, 0.4, { Transparency = 1 })
		Debris:AddItem(bubble, 0.5)
	end
end

local function makeBubble(player)
	local root = Util.GetRoot(player)
	local character = player.Character
	if not root or not character then
		return nil
	end
	local bubble = Instance.new("Part")
	bubble.Name = "ShieldBubble"
	bubble.Shape = Enum.PartType.Ball
	bubble.Size = Vector3.new(8, 8, 8)
	bubble.Material = Enum.Material.ForceField
	bubble.Color = Color3.fromRGB(120, 190, 235)
	bubble.Transparency = 0.25
	bubble.CastShadow = false
	bubble.CanCollide = false
	bubble.CanTouch = false
	bubble.CanQuery = false
	bubble.Massless = true
	bubble.Anchored = false
	bubble.CFrame = root.CFrame
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = bubble
	weld.Parent = bubble
	bubble.Parent = character
	return bubble
end

local function effectHeal(player, humanoid)
	if not DamageService or type(DamageService.Heal) ~= "function" then
		return false, "Healing is unavailable right now"
	end
	if humanoid.Health >= humanoid.MaxHealth - 0.01 then
		return false, "You are already at full health"
	end
	local ok, healed = pcall(DamageService.Heal, player, humanoid.MaxHealth * HEAL_FRACTION)
	if not ok or type(healed) ~= "number" or healed <= 0 then
		return false, "Could not heal right now"
	end
	return true, "Healed +" .. tostring(math.floor(healed + 0.5)) .. " HP"
end

local function effectShield(player)
	if not DamageService or type(DamageService.GrantInvulnerability) ~= "function" then
		return false, "Shields are unavailable right now"
	end
	local active = shields[player]
	if active and os.clock() < active.Expires and (active.Bubble == nil or active.Bubble.Parent ~= nil) then
		return false, "Your shield is still active"
	end
	removeShield(player)
	local ok = pcall(DamageService.GrantInvulnerability, player, SHIELD_SECONDS)
	if not ok then
		return false, "Could not raise the shield"
	end
	local record = { Bubble = makeBubble(player), Expires = os.clock() + SHIELD_SECONDS }
	shields[player] = record
	task.delay(SHIELD_SECONDS, function()
		if shields[player] == record then
			removeShield(player)
		end
	end)
	return true, "Shield up for " .. SHIELD_SECONDS .. " seconds"
end

-- Small ember burst where the teammate stands up.
local function phoenixBurst(player)
	local root = Util.GetRoot(player)
	if not root then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Name = "PhoenixBurst"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = root.CFrame
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/fire_main.dds"
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 190, 90), Color3.fromRGB(226, 92, 70))
	emitter.LightEmission = 0.6
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.6, 1.1)
	emitter.Speed = NumberRange.new(8, 16)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 10, 0)
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = anchor
	anchor.Parent = workspace
	emitter:Emit(28)
	Debris:AddItem(anchor, 2)
end

local function effectPhoenix(player, _, match)
	if not DamageService or type(DamageService.Revive) ~= "function" then
		return false, "Reviving is unavailable right now"
	end
	if not match or type(match.Players) ~= "table" then
		return false, "You are not in a match"
	end
	local ms = getMatchService()
	local myRoot = Util.GetRoot(player)
	local target = nil
	local bestDistance = math.huge
	for _, other in ipairs(match.Players) do
		if other ~= player and isLivePlayer(other) and isDowned(other) then
			local sameMatch = true
			if ms and type(ms.GetMatchOf) == "function" then
				local ok, theirs = pcall(ms.GetMatchOf, other)
				sameMatch = ok and theirs == match
			end
			if sameMatch then
				local root = Util.GetRoot(other)
				local distance = 1000000
				if root and myRoot then
					distance = (root.Position - myRoot.Position).Magnitude
				end
				if not target or distance < bestDistance then
					target = other
					bestDistance = distance
				end
			end
		end
	end
	if not target then
		return false, "No downed teammate to revive"
	end
	local ok = pcall(DamageService.Revive, target)
	if not ok or isDowned(target) then
		return false, "The feather could not revive them"
	end
	phoenixBurst(target)
	notify(target, player.DisplayName .. " revived you with a Phoenix Feather!", "good", 4)
	return true, "Revived " .. target.DisplayName .. "!"
end

local EFFECTS = {
	heal_cloud = effectHeal,
	shield_bubble = effectShield,
	phoenix_feather = effectPhoenix,
}

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function ItemService.Buy(player, itemId, qty)
	if not isLivePlayer(player) then
		return false, "Player unavailable"
	end
	if type(itemId) ~= "string" or #itemId > MAX_ID_LENGTH then
		return false, "Unknown item"
	end
	if qty == nil then
		qty = 1
	end
	local maxCarry = Config.Items.MaxCarry
	if type(qty) ~= "number" or qty ~= qty or qty < 1 or qty > maxCarry or qty % 1 ~= 0 then
		return false, "Invalid amount"
	end
	local def = ItemCatalog and ItemCatalog.Get(itemId)
	if not def then
		return false, "Unknown item"
	end
	if type(def.Price) ~= "number" or def.Price < 0 then
		return false, "That item is not for sale"
	end
	if player:GetAttribute(Config.Attr.InMatch) == true then
		return false, "The shop is closed during a match"
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return false, "Your data is still loading"
	end

	local have = profile.Items[itemId] or 0
	local room = maxCarry - have
	if room <= 0 then
		return false, "You already carry the maximum (" .. maxCarry .. ")"
	end
	if qty > room then
		return false, "You can only carry " .. room .. " more"
	end
	local total = math.floor(def.Price * qty)
	if DataService.GetTokens(player) < total then
		return false, "Not enough cloud tokens"
	end
	if not DataService.SpendTokens(player, total) then
		return false, "Not enough cloud tokens"
	end
	profile.Items[itemId] = have + qty
	DataService.MarkDirty(player)
	DataService.Sync(player)
	return true
end

function ItemService.Use(player, itemId)
	if not isLivePlayer(player) then
		return false, "Player unavailable"
	end
	if type(itemId) ~= "string" or #itemId > MAX_ID_LENGTH then
		return false, "Unknown item"
	end
	local effect = EFFECTS[itemId]
	if not effect or not ItemCatalog or not ItemCatalog.Get(itemId) then
		return false, "Unknown item"
	end
	if player:GetAttribute(Config.Attr.InMatch) ~= true then
		return false, "Items only work inside a match"
	end
	if isDowned(player) then
		return false, "You can not use items while downed"
	end
	local humanoid = Util.GetHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return false, "You are not alive"
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return false, "Your data is still loading"
	end
	if (profile.Items[itemId] or 0) <= 0 then
		return false, "You do not have that item"
	end
	local readyAt = useReadyAt[player]
	if readyAt and os.clock() < readyAt then
		return false, "Please wait a moment"
	end

	-- The match must exist and still be running.
	local match = nil
	local ms = getMatchService()
	if ms and type(ms.GetMatchOf) == "function" then
		local ok, found = pcall(ms.GetMatchOf, player)
		if ok then
			match = found
		end
		if not match then
			return false, "You are not in a match"
		end
		if match.State == "Ended" or match.Stopped == true then
			return false, "The match is over"
		end
	end

	local ok, success, message = pcall(effect, player, humanoid, match)
	if not ok then
		warn("[ItemService] " .. itemId .. " errored: " .. tostring(success))
		return false, "Something went wrong"
	end
	if not success then
		return false, message
	end

	useReadyAt[player] = os.clock() + USE_COOLDOWN

	-- Consume exactly one (the effect did not yield, but re-read anyway).
	local remaining = (profile.Items[itemId] or 0) - 1
	if remaining > 0 then
		profile.Items[itemId] = remaining
	else
		profile.Items[itemId] = nil
	end
	DataService.MarkDirty(player)
	DataService.Sync(player)
	notify(player, message, "good", 2.5)
	return true
end

----------------------------------------------------------------------
-- Remotes (client -> server)
----------------------------------------------------------------------

local function connectRemotes()
	if remotesConnected then
		return
	end
	local okBuy, buyRemote = pcall(Remotes.Get, "BuyItem")
	local okUse, useRemote = pcall(Remotes.Get, "UseItem")
	if not (okBuy and okUse) then
		warn("[ItemService] item remotes are missing (did Remotes.Init run?)")
		return
	end
	remotesConnected = true

	buyRemote.OnServerEvent:Connect(function(player, itemId, qty)
		if rateLimited(player, "BuyItem", REMOTE_COOLDOWN) then
			return
		end
		if type(itemId) ~= "string" or #itemId > MAX_ID_LENGTH then
			return
		end
		if qty ~= nil and type(qty) ~= "number" then
			return
		end
		local ok, success, reason = pcall(ItemService.Buy, player, itemId, qty)
		if not ok then
			warn("[ItemService] Buy errored: " .. tostring(success))
			notify(player, "Something went wrong", "bad", 3)
		elseif success then
			local def = ItemCatalog and ItemCatalog.Get(itemId)
			local amount = qty or 1
			notify(player, "Bought " .. tostring(amount) .. " x " .. (def and def.Name or itemId), "good", 2.5)
		else
			notify(player, tostring(reason), "bad", 3)
		end
	end)

	useRemote.OnServerEvent:Connect(function(player, itemId)
		if rateLimited(player, "UseItem", REMOTE_COOLDOWN) then
			return
		end
		if type(itemId) ~= "string" or #itemId > MAX_ID_LENGTH then
			return
		end
		local ok, success, reason = pcall(ItemService.Use, player, itemId)
		if not ok then
			warn("[ItemService] Use errored: " .. tostring(success))
		elseif not success and reason then
			notify(player, tostring(reason), "bad", 2.5)
		end
	end)
end

local function connectPlayers()
	if playersConnected then
		return
	end
	playersConnected = true
	Players.PlayerRemoving:Connect(function(player)
		lastCall[player] = nil
		shields[player] = nil
		useReadyAt[player] = nil
	end)
end

----------------------------------------------------------------------
-- Item shop counter in the lobby
----------------------------------------------------------------------

local function buildPrompt(lobbyInfo)
	if promptObject and promptObject.Parent then
		promptObject:Destroy()
	end
	promptObject = nil

	local shop = type(lobbyInfo) == "table" and lobbyInfo.Shop
	local itemShop = type(shop) == "table" and shop.ItemShop
	local part = type(itemShop) == "table" and itemShop.PromptPart
	if not part or typeof(part) ~= "Instance" then
		warn("[ItemService] lobbyInfo.Shop.ItemShop.PromptPart missing: no item shop prompt created")
		return
	end
	local old = part:FindFirstChild(PROMPT_NAME)
	if old then
		old:Destroy()
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "Open"
	prompt.ObjectText = "Item Shop"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	promptObject = prompt

	prompt.Triggered:Connect(function(player)
		if not isLivePlayer(player) then
			return
		end
		if player:GetAttribute(Config.Attr.InMatch) == true then
			return
		end
		if rateLimited(player, "Prompt", PROMPT_COOLDOWN) then
			return
		end
		fireClient("OpenPanel", player, "Shop", { Tab = "Items" })
	end)
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------

function ItemService.Init(lobbyInfo, deps)
	if type(deps) == "table" then
		if deps.DataService then
			DataService = deps.DataService
		end
		if deps.DamageService then
			DamageService = deps.DamageService
		end
		if deps.MatchService then
			ItemService.SetMatchService(deps.MatchService)
		end
	end
	if not ItemCatalog then
		warn("[ItemService] ItemCatalog is missing: the item shop is disabled")
	end
	connectRemotes()
	connectPlayers()
	buildPrompt(lobbyInfo)
end

return ItemService
