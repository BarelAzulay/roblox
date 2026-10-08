-- Main (Script): boots every server service in the order defined in ARCHITECTURE.md.
-- Each step runs under pcall + warn so one failing service can never brick the whole server.
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
local HazardService = loadService("HazardService")
local CourseBuilder = loadService("CourseBuilder")
local MatchService = loadService("MatchService")
local PortalService = loadService("PortalService")

----------------------------------------------------------------------
-- 2. Boot order from ARCHITECTURE.md
----------------------------------------------------------------------

call("LightingService.Init", LightingService, "Init")

local lobbyInfo = call("LobbyBuilder.Build", LobbyBuilder, "Build")

call("DamageService.Init", DamageService, "Init")
call("TokenService.Init", TokenService, "Init")
call("PlayerService.Init", PlayerService, "Init", lobbyInfo)
call("DataService.StartAutosave", DataService, "StartAutosave")
call("DataService.BindToClose", DataService, "BindToClose")

call("MatchService.Init", MatchService, "Init", {
	PlayerService = PlayerService,
	DamageService = DamageService,
	DataService = DataService,
	HazardService = HazardService,
	TokenService = TokenService,
	CourseBuilder = CourseBuilder,
})

-- Respawns inside a match go to the team checkpoint; MatchService returns nil otherwise (lobby).
if type(MatchService) == "table" and type(MatchService.GetRespawnCFrame) == "function" then
	call("PlayerService.SetSpawnProvider", PlayerService, "SetSpawnProvider", MatchService.GetRespawnCFrame)
else
	warn(TAG .. "no spawn provider: players will always respawn in the lobby")
end

call("PortalService.Init", PortalService, "Init", lobbyInfo, MatchService)

----------------------------------------------------------------------
-- 3. Dash relay: validate the cooldown server-side, then show the trail to everyone
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

print(TAG .. "ready")
