-- PlayerService: per-player lifecycle, spawn placement, humanoid setup, leaderstats, lobby rules.
--
-- * PlayerAdded: attributes, leaderstats, saved tokens (via DataService).
-- * CharacterAdded: humanoid stats, placement (spawn provider or scattered lobby spawn),
--   brief spawn i-frames.
-- * 0.5s lobby loop: players who fall off the lobby are sent back (no damage), and the lobby
--   keeps everybody at full health.
-- * PlayerRemoving: save + cleanup.
--
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)

local DataService = require(script.Parent.DataService)
local DamageService = require(script.Parent.DamageService)

local PlayerService = {}

local SCATTER_RADIUS = 6 -- studs; lobby spawns are spread so players don't stack
local LOBBY_TICK = 0.5 -- seconds between lobby safety checks
local SPAWN_IFRAMES = 1.5 -- seconds of protection after every (re)spawn

local lobbySpawn = CFrame.new(Config.Lobby.Origin + Vector3.new(0, 3, 0))
local spawnProvider = nil -- fn(player) -> CFrame|nil
local initialized = false
local running = false
local perPlayer = {} -- [player] = { Conns = { RBXScriptConnection... } }
local rng = Random.new()

----------------------------------------------------------------------
-- Placement helpers
----------------------------------------------------------------------

-- A lobby spawn CFrame nudged to a random spot near the plaza centre.
local function scatteredLobbyCFrame()
	local angle = rng:NextNumber(0, math.pi * 2)
	local radius = math.sqrt(rng:NextNumber(0, 1)) * SCATTER_RADIUS
	return lobbySpawn * CFrame.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

-- Teleport a character and kill any leftover momentum.
local function placeCharacter(char, cframe)
	if not char or not char.Parent then
		return
	end
	local ok, err = pcall(function()
		char:PivotTo(cframe)
	end)
	if not ok then
		warn("[PlayerService] PivotTo failed: " .. tostring(err))
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if root then
		root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
	end
end

-- Roblox's built-in "Health" script slowly regenerates health, which would heal players during a
-- match (and un-pin downed players). DamageService is the only authority, so remove it.
local function removeDefaultRegen(char)
	local regen = char:WaitForChild("Health", 3)
	if regen and regen:IsA("Script") then
		regen:Destroy()
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function PlayerService.GetLobbySpawnCFrame()
	return lobbySpawn
end

function PlayerService.SetSpawnProvider(fn)
	if fn == nil or type(fn) == "function" then
		spawnProvider = fn
	else
		warn("[PlayerService] SetSpawnProvider expects a function or nil")
	end
end

-- WalkSpeed / JumpPower / MaxHealth / Health from Config. A downed player keeps their frozen
-- stats and their pinned health so a stray call can never "heal" them.
function PlayerService.ApplyHumanoidStats(player)
	local humanoid = Util.GetHumanoid(player)
	if not humanoid then
		return
	end
	humanoid.UseJumpPower = true
	humanoid.MaxHealth = Config.Physics.MaxHealth

	if player:GetAttribute(Config.Attr.Downed) == true then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	else
		humanoid.WalkSpeed = Config.Physics.WalkSpeed
		humanoid.JumpPower = Config.Physics.JumpPower
		humanoid.Health = humanoid.MaxHealth
	end

	-- Cosmetic: the custom HUD owns the health display, and auto-jump fights precise parkour.
	pcall(function()
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.AutoJumpEnabled = false
	end)
end

-- Clears InMatch/Downed, heals, and puts the player back on the lobby plaza.
function PlayerService.SendToLobby(player)
	if not player or not player.Parent then
		return
	end
	pcall(DamageService.ClearDowned, player)
	player:SetAttribute(Config.Attr.InMatch, false)
	player:SetAttribute(Config.Attr.Downed, false)

	local char = player.Character
	local humanoid = Util.GetHumanoid(player)
	if char and humanoid and humanoid.Health > 0 then
		PlayerService.ApplyHumanoidStats(player)
		placeCharacter(char, scatteredLobbyCFrame())
	end
	-- If the character is dead or missing, the respawn flow places the new one in the lobby
	-- (InMatch is false now, so the spawn provider returns nil).
end

----------------------------------------------------------------------
-- Character + player lifecycle
----------------------------------------------------------------------

local function onCharacterAdded(player, char)
	local humanoid = char:WaitForChild("Humanoid", 10)
	local root = char:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not root then
		return
	end
	-- The player may have left or respawned again while we waited.
	if not player.Parent or player.Character ~= char or not char.Parent then
		return
	end

	PlayerService.ApplyHumanoidStats(player)

	local target = nil
	if spawnProvider then
		local ok, result = pcall(spawnProvider, player)
		if ok then
			if typeof(result) == "CFrame" then
				target = result
			end
		else
			warn("[PlayerService] spawn provider failed: " .. tostring(result))
		end
	end
	if not target then
		target = scatteredLobbyCFrame()
	end
	placeCharacter(char, target)

	DamageService.GrantInvulnerability(player, SPAWN_IFRAMES)
	task.spawn(removeDefaultRegen, char)
end

local function setupPlayer(player)
	if perPlayer[player] then
		return
	end
	local record = { Conns = {} }
	perPlayer[player] = record

	-- Attributes first so the HUD never reads nil.
	player:SetAttribute(Config.Attr.Tokens, 0)
	player:SetAttribute(Config.Attr.MatchTokens, 0)
	player:SetAttribute(Config.Attr.InMatch, false)
	player:SetAttribute(Config.Attr.Downed, false)

	-- leaderstats.Tokens mirrors the CloudTokens attribute.
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local tokensValue = Instance.new("IntValue")
	tokensValue.Name = "Tokens"
	tokensValue.Value = 0
	tokensValue.Parent = stats
	stats.Parent = player

	table.insert(
		record.Conns,
		player:GetAttributeChangedSignal(Config.Attr.Tokens):Connect(function()
			local value = player:GetAttribute(Config.Attr.Tokens)
			if type(value) == "number" then
				tokensValue.Value = math.floor(value)
			end
		end)
	)

	-- Connect before the (yielding) data load so an early character is not missed.
	table.insert(
		record.Conns,
		player.CharacterAdded:Connect(function(char)
			onCharacterAdded(player, char)
		end)
	)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end

	-- Saved data. DataService.Load never errors; the pcall is belt and braces.
	pcall(DataService.Load, player)
	if not player.Parent then
		-- Left while loading: PlayerRemoving may already have run its save, so free the cache.
		pcall(DataService.Release, player)
		return
	end
	local tokens = DataService.GetTokens(player)
	player:SetAttribute(Config.Attr.Tokens, tokens)
	tokensValue.Value = math.floor(tokens)
end

local function onPlayerRemoving(player)
	local record = perPlayer[player]
	perPlayer[player] = nil
	if record then
		for _, conn in ipairs(record.Conns) do
			conn:Disconnect()
		end
	end
	pcall(DataService.Save, player)
	pcall(DataService.Release, player)
end

----------------------------------------------------------------------
-- Lobby rules
----------------------------------------------------------------------

local function lobbyTick()
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute(Config.Attr.InMatch) ~= true then
			local char = player.Character
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				-- Fell off the cloud village: back to the plaza, no damage.
				if root.Position.Y < Config.Lobby.KillY then
					placeCharacter(char, scatteredLobbyCFrame())
				end
				-- The lobby is safe: keep everybody topped up.
				if humanoid.Health < humanoid.MaxHealth then
					humanoid.Health = humanoid.MaxHealth
				end
			end
		end
	end
end

local function lobbyLoop()
	while running do
		task.wait(LOBBY_TICK)
		if not running then
			break
		end
		local ok, err = pcall(lobbyTick)
		if not ok then
			warn("[PlayerService] lobby loop error: " .. tostring(err))
		end
	end
end

function PlayerService.Init(lobbyInfo)
	if initialized then
		return
	end
	initialized = true

	if type(lobbyInfo) == "table" and typeof(lobbyInfo.SpawnCFrame) == "CFrame" then
		lobbySpawn = lobbyInfo.SpawnCFrame
	else
		warn("[PlayerService] no lobbyInfo.SpawnCFrame; using the default lobby origin")
	end

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(setupPlayer, player)
	end

	running = true
	task.spawn(lobbyLoop)
	game:BindToClose(function()
		running = false -- stop the lobby loop on shutdown
	end)
end

return PlayerService
