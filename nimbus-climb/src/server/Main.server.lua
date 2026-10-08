-- Main (Script): boots every server service in the order defined in ARCHITECTURE.md / V2.
-- Each step runs under pcall + warn so one failing service can never brick the whole server.
-- Plain Lua 5.1-compatible syntax only.
--
-- Boot order (v2):
--   Remotes -> Lighting -> Lobby -> Damage -> Token -> Data (autosave / BindToClose)
--   -> Pet / Item / Spot services (they subscribe to profile events)
--   -> Player service (this is what starts loading profiles, so it comes after the subscribers)
--   -> Match -> Portals -> Dash relay

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)

local Services = script.Parent:WaitForChild("Services")

local TAG = "[NimbusClimb] "

----------------------------------------------------------------------
-- Boot helpers
----------------------------------------------------------------------

-- Require a service module; returns nil (and warns) instead of erroring.
local function loadService(name)
	local moduleScript = Services:FindFirstChild(name) or Services:WaitForChild(name, 3)
	if not moduleScript then
		warn(TAG .. "service module missing: " .. name)
		return nil
	end
	local ok, result = pcall(require, moduleScript)
	if not ok then
		warn(TAG .. "failed to load " .. name .. ": " .. tostring(result))
		return nil
	end
	return result
end

-- Call module[funcName](...) under pcall. Returns (result, success).
local function call(label, module, funcName, ...)
	if type(module) ~= "table" or type(module[funcName]) ~= "function" then
		warn(TAG .. label .. " skipped (module or function unavailable)")
		return nil, false
	end
	local ok, result = pcall(module[funcName], ...)
	if not ok then
		warn(TAG .. label .. " failed: " .. tostring(result))
		return nil, false
	end
	return result, true
end

-- Run an arbitrary function under pcall + warn.
local function step(label, fn)
	local ok, err = pcall(fn)
	if not ok then
		warn(TAG .. label .. " failed: " .. tostring(err))
	end
	return ok
end

-- True when module[name] is a Util.Signal-like object.
local function hasSignal(module, name)
	return type(module) == "table" and type(module[name]) == "table" and type(module[name].Connect) == "function"
end

-- A tiny cloud platform so players are never dropped into the void if the lobby failed to build.
local function buildEmergencyLobby()
	local origin = Config.Lobby.Origin
	local platform = Instance.new("Part")
	platform.Name = "NimbusEmergencyPlaza"
	platform.Anchored = true
	platform.Shape = Enum.PartType.Cylinder
	platform.Material = Enum.Material.SmoothPlastic
	platform.Color = Color3.fromRGB(150, 168, 200)
	platform.Size = Vector3.new(2, 120, 120) -- cylinder axis is X: rotate it flat below
	platform.CFrame = CFrame.new(origin - Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	platform.Parent = Workspace
	return platform
end

-- Services index lobbyInfo.Portals / .Spots / .Shop directly: make sure those always exist.
local function normaliseLobbyInfo(info)
	if type(info) ~= "table" then
		warn(TAG .. "LobbyBuilder.Build returned nothing; using an emergency plaza")
		local platform = buildEmergencyLobby()
		info = {
			Folder = platform,
			SpawnCFrame = CFrame.new(Config.Lobby.Origin + Vector3.new(0, 4, 0)),
		}
	end
	if type(info.Portals) ~= "table" then
		info.Portals = {}
	end
	if type(info.Spots) ~= "table" then
		info.Spots = {}
	end
	if type(info.Shop) ~= "table" then
		info.Shop = {}
	end
	if type(info.Shop.Roulettes) ~= "table" then
		info.Shop.Roulettes = {}
	end
	return info
end

-- Global world rules. LightingService applies them too; this copy makes sure they hold even if
-- that service failed to load.
local function applyWorldRules()
	pcall(function()
		Workspace.Gravity = Config.Physics.Gravity
	end)
	pcall(function()
		Workspace.FallenPartsDestroyHeight = -2000
	end)
end

-- Spawn gate. Building the lobby takes a moment; a player who joins meanwhile would spawn at the
-- world origin, far below the village, and fall into the void. So characters are held back until
-- the lobby, PlayerService and the spawn providers are ready, then released (CharacterAutoLoads
-- ends up true, as the contract says; players who joined in the meantime get their character now).
local spawnsReleased = false
local releaseTimer = nil -- safety net: releases the gate even if a boot step stalls

local function holdSpawns()
	if spawnsReleased then
		return -- the safety timer already opened the gate; never close it again
	end
	pcall(function()
		Players.CharacterAutoLoads = false
	end)
end

local function releaseSpawns()
	if spawnsReleased then
		return
	end
	spawnsReleased = true
	if releaseTimer then
		pcall(task.cancel, releaseTimer)
		releaseTimer = nil
	end
	pcall(function()
		Players.CharacterAutoLoads = true
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Parent and not player.Character then
			task.spawn(function()
				local ok, err = pcall(function()
					player:LoadCharacter()
				end)
				if not ok then
					warn(TAG .. "LoadCharacter failed for " .. player.Name .. ": " .. tostring(err))
				end
			end)
		end
	end
end

----------------------------------------------------------------------
-- 0. Close the spawn gate first thing; a timer guarantees it opens even if a boot step stalls
----------------------------------------------------------------------

step("Hold spawns", holdSpawns)
releaseTimer = task.delay(30, function()
	releaseTimer = nil
	releaseSpawns()
end)

----------------------------------------------------------------------
-- 1. Remotes must exist before any service that grabs them
----------------------------------------------------------------------

step("Remotes.Init", function()
	Remotes.Init()
end)

local LightingService = loadService("LightingService")
local LobbyBuilder = loadService("LobbyBuilder")
local DamageService = loadService("DamageService")
local TokenService = loadService("TokenService")
local DataService = loadService("DataService")
local PlayerService = loadService("PlayerService")
local PetService = loadService("PetService")
local ItemService = loadService("ItemService")
local SpotService = loadService("SpotService")
local HazardService = loadService("HazardService")
local CourseBuilder = loadService("CourseBuilder")
local MatchService = loadService("MatchService")
local PortalService = loadService("PortalService")

----------------------------------------------------------------------
-- 2. World: lighting, lobby, damage, tokens, persistence
----------------------------------------------------------------------

call("LightingService.Init", LightingService, "Init")
step("World rules", applyWorldRules)

-- LightingService re-enables CharacterAutoLoads (contract); keep the gate closed until the end.
step("Hold spawns", holdSpawns)

local lobbyInfo = call("LobbyBuilder.Build", LobbyBuilder, "Build")
lobbyInfo = normaliseLobbyInfo(lobbyInfo)

call("DamageService.Init", DamageService, "Init")
call("TokenService.Init", TokenService, "Init")
call("DataService.StartAutosave", DataService, "StartAutosave")
call("DataService.BindToClose", DataService, "BindToClose")

----------------------------------------------------------------------
-- 3. Economy + spots (subscribe to profile events BEFORE PlayerService starts loading profiles)
----------------------------------------------------------------------

call("PetService.Init", PetService, "Init", lobbyInfo, {
	DataService = DataService,
})

call("ItemService.Init", ItemService, "Init", lobbyInfo, {
	DataService = DataService,
	DamageService = DamageService,
	MatchService = MatchService, -- module table; ItemService only asks it for matches at use time
})

call("SpotService.Init", SpotService, "Init", lobbyInfo, {
	DataService = DataService,
	PetService = PetService,
})

----------------------------------------------------------------------
-- 4. Players: providers first, then Init (which loads profiles and places characters)
----------------------------------------------------------------------

-- Respawns inside a match go to the team checkpoint; MatchService returns nil otherwise (lobby).
if type(MatchService) == "table" and type(MatchService.GetRespawnCFrame) == "function" then
	call("PlayerService.SetSpawnProvider", PlayerService, "SetSpawnProvider", MatchService.GetRespawnCFrame)
else
	warn(TAG .. "no spawn provider: players will always respawn in the lobby")
end

-- Lobby respawns (after the first spawn) go to the owner's spot when they have one.
if type(SpotService) == "table" and type(SpotService.GetSpot) == "function" then
	call("PlayerService.SetHomeProvider", PlayerService, "SetHomeProvider", function(player)
		local spot = SpotService.GetSpot(player)
		if spot then
			return spot.SpawnCFrame
		end
		return nil
	end)
end

-- Pet perks raise max health; a refresh keeps the health fraction.
if type(PetService) == "table" and type(PetService.GetPerks) == "function" then
	call("PlayerService.SetPerkProvider", PlayerService, "SetPerkProvider", PetService.GetPerks)
	if hasSignal(PetService, "PerksChanged") then
		step("PerksChanged wiring", function()
			PetService.PerksChanged:Connect(function(player)
				if type(PlayerService) == "table" and type(PlayerService.RefreshMaxHealth) == "function" then
					local ok, err = pcall(PlayerService.RefreshMaxHealth, player)
					if not ok then
						warn(TAG .. "RefreshMaxHealth failed: " .. tostring(err))
					end
				end
			end)
		end)
	end
else
	warn(TAG .. "no pet perks: max health stays at the base value")
end

call("PlayerService.Init", PlayerService, "Init", lobbyInfo)

----------------------------------------------------------------------
-- 5. Match flow
----------------------------------------------------------------------

call("MatchService.Init", MatchService, "Init", {
	PlayerService = PlayerService,
	DamageService = DamageService,
	DataService = DataService,
	HazardService = HazardService,
	TokenService = TokenService,
	CourseBuilder = CourseBuilder,
	PetService = PetService,
})

if type(ItemService) == "table" and type(ItemService.SetMatchService) == "function" then
	call("ItemService.SetMatchService", ItemService, "SetMatchService", MatchService)
end

call("PortalService.Init", PortalService, "Init", lobbyInfo, MatchService)

----------------------------------------------------------------------
-- 6. Dash relay: validate the cooldown server-side, then show the trail to everyone
----------------------------------------------------------------------

step("Dash remote", function()
	local dashRemote = Remotes.Get("Dash")
	local dashFx = Remotes.Get("DashFx")
	local lastDash = {} -- [player] = os.clock() of the last accepted dash
	-- The client enforces the exact cooldown; allow 20% slack for latency and frame timing.
	local minInterval = Config.Physics.DashCooldown * 0.8

	dashRemote.OnServerEvent:Connect(function(player)
		if player:GetAttribute(Config.Attr.Downed) == true then
			return
		end
		local char = player.Character
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return
		end
		local now = os.clock()
		local last = lastDash[player]
		if last and now - last < minInterval then
			return
		end
		lastDash[player] = now
		dashFx:FireAllClients(player.UserId)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastDash[player] = nil
	end)
end)

-- Everything is wired: let characters spawn (providers are set, the lobby exists).
step("Release spawns", releaseSpawns)

print(TAG .. "ready")
