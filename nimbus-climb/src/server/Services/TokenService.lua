-- TokenService: the cloud tokens. MakeTokenPart builds the visual (a glowing golden coin with a
-- little white cloud puff on it), one shared Heartbeat driver spins and bobs every token near a
-- player, and Watch() turns tokens inside a match course into collectable pickups.
-- Plain Lua 5.1-compatible syntax only. No asset ids: Parts + built-in particle textures.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)
local Util = require(Shared.Util)

local TokenService = {}

local TOKEN_TAG = Config.Tags.CloudToken
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

----------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------
local COIN_DIAMETER = 3.1
local COIN_THICKNESS = 0.55
local RIM_DIAMETER = 3.6
local RIM_THICKNESS = 0.4
local HALO_DIAMETER = 5.2

local SPIN_SPEED = 2.0 -- radians per second around the vertical axis
local BOB_SPEED = 2.2 -- radians per second of the up/down sine
local BOB_AMPLITUDE = 0.45 -- studs
local ANIM_STEP = 1 / 30 -- the driver updates tokens at 30 Hz (replication cannot show more)
local CULL_DISTANCE = 220 -- tokens farther than this from every player are left alone
local PLAYER_REFRESH = 0.5 -- how often the driver re-reads player positions

local PICKUP_POLL = 0.12 -- backup proximity poll inside Watch()
local PICKUP_RADIUS = 3.2 -- studs from the character's root to the token centre
local COLLECT_FADE = 0.3

local GOLD = Theme.Colors.Token
local GLOW = Theme.Colors.TokenGlow
local AMBER = Color3.fromRGB(255, 168, 48)

----------------------------------------------------------------------
-- Shared animation driver
--   One Heartbeat connection for every token in the server. Each token gets an entry with its
--   base position and a random phase so neighbours never move in lockstep. Tokens that are
--   not in the workspace yet are skipped; tokens that were destroyed are dropped; tokens far
--   from every player are not touched at all (no CPU, no replication).
----------------------------------------------------------------------
local animated = {} -- token part -> { base, lastPos, phase, parented }
local driverConnection = nil
local nextStepAt = 0
local nextRefreshAt = 0
local playerPositions = {}
local phaseRng = Random.new()
local CULL_DISTANCE_SQ = CULL_DISTANCE * CULL_DISTANCE

local function refreshPlayerPositions(now)
	playerPositions = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local root = Util.GetRoot(player)
		if root then
			table.insert(playerPositions, root.Position)
		end
	end
	nextRefreshAt = now + PLAYER_REFRESH
end

local function nearAnyPlayer(position)
	for _, p in ipairs(playerPositions) do
		local d = position - p
		if d:Dot(d) <= CULL_DISTANCE_SQ then
			return true
		end
	end
	return false
end

local function stepTokens()
	local now = os.clock()
	if now < nextStepAt then
		return
	end
	nextStepAt = now + ANIM_STEP
	if next(animated) == nil then
		return
	end
	if now >= nextRefreshAt then
		refreshPlayerPositions(now)
	end

	for token, rec in pairs(animated) do
		if token.Parent == nil then
			-- removed from the tree (destroyed): forget it. Never-parented tokens just wait.
			if rec.parented then
				animated[token] = nil
			end
		elseif token:IsDescendantOf(Workspace) then
			-- Welded pieces only follow the root once the token is in the workspace.
			rec.parented = true
			local current = token.Position
			local moved = current - rec.lastPos
			if moved:Dot(moved) > 0.0625 then
				-- something else (e.g. the course was pivoted) moved it: follow along
				rec.base = rec.base + moved
			end
			if nearAnyPlayer(current) then
				local bob = math.sin(now * BOB_SPEED + rec.phase) * BOB_AMPLITUDE
				local position = Vector3.new(rec.base.X, rec.base.Y + bob, rec.base.Z)
				token.CFrame = CFrame.new(position) * CFrame.Angles(0, now * SPIN_SPEED + rec.phase, 0)
				rec.lastPos = position
			end
		end
	end
end

local function ensureDriver()
	if driverConnection then
		return
	end
	driverConnection = RunService.Heartbeat:Connect(function()
		local ok, err = pcall(stepTokens)
		if not ok then
			warn("[TokenService] animation step failed: " .. tostring(err))
		end
	end)
end

local function stopAnimating(token)
	animated[token] = nil
end

----------------------------------------------------------------------
-- The token visual
----------------------------------------------------------------------
-- A non-colliding decorative piece welded to the token root, positioned by `offset` (relative to
-- the root). Welded children follow every CFrame change of the anchored root.
local function addPiece(token, name, shape, size, offset, color, material, transparency)
	local piece = Instance.new("Part")
	piece.Name = name
	piece.Shape = shape
	piece.Size = size
	piece.Material = material
	piece.Color = color
	piece.Transparency = transparency or 0
	piece.Anchored = false
	piece.Massless = true
	piece.CanCollide = false
	piece.CanTouch = false
	piece.CanQuery = false
	piece.CastShadow = false
	piece.CFrame = token.CFrame * offset
	piece.Parent = token
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = token
	weld.Part1 = piece
	weld.Parent = piece
	return piece
end

-- THE visual cloud token. position: world Vector3 (centre of the coin). parent: Instance or nil.
-- value: how many tokens it is worth (attribute "Value", default Config.Tokens.DefaultValue).
-- The returned Part is the coin: Anchored, CanCollide=false, tagged CloudToken.
function TokenService.MakeTokenPart(position, parent, value)
	ensureDriver()
	local phase = phaseRng:NextNumber(0, math.pi * 2)

	-- Roblox cylinders have their axis along X, so this is a coin standing on its edge; spinning
	-- it around the world Y axis shows both faces.
	local token = Instance.new("Part")
	token.Name = "CloudToken"
	token.Shape = Enum.PartType.Cylinder
	token.Size = Vector3.new(COIN_THICKNESS, COIN_DIAMETER, COIN_DIAMETER)
	token.Material = Enum.Material.Neon
	token.Color = GOLD
	token.Anchored = true
	token.CanCollide = false
	token.CanTouch = true
	token.CanQuery = false
	token.CastShadow = false
	token.CFrame = CFrame.new(position) * CFrame.Angles(0, phase, 0)
	token:SetAttribute("Value", value or Config.Tokens.DefaultValue)

	-- deeper amber rim peeking out behind the coin
	addPiece(token, "Rim", Enum.PartType.Cylinder,
		Vector3.new(RIM_THICKNESS, RIM_DIAMETER, RIM_DIAMETER), CFrame.new(0, 0, 0),
		AMBER, Enum.Material.SmoothPlastic, 0)

	-- the little white cloud puff, poking through both faces of the coin (local X is the thickness)
	addPiece(token, "PuffMiddle", Enum.PartType.Ball, Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, 0.22, 0),
		Theme.Colors.Cloud, Enum.Material.SmoothPlastic, 0)
	addPiece(token, "PuffLeft", Enum.PartType.Ball, Vector3.new(0.85, 0.85, 0.85), CFrame.new(0, -0.12, -0.7),
		Theme.Colors.Cloud, Enum.Material.SmoothPlastic, 0)
	addPiece(token, "PuffRight", Enum.PartType.Ball, Vector3.new(0.85, 0.85, 0.85), CFrame.new(0, -0.12, 0.7),
		Theme.Colors.Cloud, Enum.Material.SmoothPlastic, 0)

	-- soft translucent aura so tokens read from far away
	addPiece(token, "Halo", Enum.PartType.Ball, Vector3.new(HALO_DIAMETER, HALO_DIAMETER, HALO_DIAMETER),
		CFrame.new(0, 0, 0), GLOW, Enum.Material.Neon, 0.88)

	local light = Instance.new("PointLight")
	light.Name = "TokenLight"
	light.Color = GOLD
	light.Brightness = 1.2
	light.Range = 11
	light.Shadows = false
	light.Parent = token

	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Name = "Sparkles"
	sparkles.Texture = SPARKLE_TEXTURE
	sparkles.Color = ColorSequence.new(GLOW, GOLD)
	sparkles.LightEmission = 1
	sparkles.LightInfluence = 0
	sparkles.Rate = 5
	sparkles.Lifetime = NumberRange.new(0.9, 1.6)
	sparkles.Speed = NumberRange.new(0.4, 1.2)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Rotation = NumberRange.new(0, 360)
	sparkles.RotSpeed = NumberRange.new(-60, 60)
	sparkles.Acceleration = Vector3.new(0, 0.8, 0)
	sparkles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkles.Parent = token

	CollectionService:AddTag(token, TOKEN_TAG)
	animated[token] = { base = position, lastPos = position, phase = phase, parented = false }
	token.Parent = parent
	return token
end

----------------------------------------------------------------------
-- Collection effect
----------------------------------------------------------------------
-- Sparkle burst + expanding glow bubble (both parented to `effectParent` so they vanish with the
-- course), while the coin itself pops upward, fades and is destroyed.
local function playCollectEffect(token, effectParent)
	local position = token.Position

	local burst = Instance.new("Part")
	burst.Name = "TokenBurst"
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanTouch = false
	burst.CanQuery = false
	burst.CastShadow = false
	burst.Transparency = 1
	burst.Size = Vector3.new(1, 1, 1)
	burst.CFrame = CFrame.new(position)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(GLOW, GOLD)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.45, 0.85)
	emitter.Speed = NumberRange.new(12, 24)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 3
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Acceleration = Vector3.new(0, -8, 0)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.7, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = burst
	burst.Parent = effectParent
	emitter:Emit(24)
	Debris:AddItem(burst, 1.5)

	local bubble = Instance.new("Part")
	bubble.Name = "TokenBubble"
	bubble.Shape = Enum.PartType.Ball
	bubble.Size = Vector3.new(1.5, 1.5, 1.5)
	bubble.Material = Enum.Material.Neon
	bubble.Color = GLOW
	bubble.Transparency = 0.35
	bubble.Anchored = true
	bubble.CanCollide = false
	bubble.CanTouch = false
	bubble.CanQuery = false
	bubble.CastShadow = false
	bubble.CFrame = CFrame.new(position)
	bubble.Parent = effectParent
	Util.Tween(bubble, 0.35, { Size = Vector3.new(7, 7, 7), Transparency = 1 },
		Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	Debris:AddItem(bubble, 0.6)

	-- the coin itself: float up, fade every piece, dim the light, stop the sparkles
	for _, d in ipairs(token:GetDescendants()) do
		if d:IsA("BasePart") then
			Util.Tween(d, COLLECT_FADE, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		elseif d:IsA("PointLight") then
			Util.Tween(d, COLLECT_FADE, { Brightness = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = false
		end
	end
	Util.Tween(token, COLLECT_FADE, {
		Transparency = 1,
		CFrame = token.CFrame + Vector3.new(0, 3, 0),
	}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	Debris:AddItem(token, COLLECT_FADE + 0.15)
end

----------------------------------------------------------------------
-- Watch: make the tokens of one match course collectable
----------------------------------------------------------------------
-- container: the course Folder/Model. matchHandle = { AddTokens = function(player, n) end }.
-- Returns stopFn (idempotent): disconnects every Touched/poll/descendant hook.
function TokenService.Watch(container, matchHandle)
	if not container then
		warn("[TokenService] Watch called without a container")
		return function() end
	end

	local stopped = false
	local tokens = {} -- token part -> Touched connection
	local collected = {} -- token part -> true; a token is only ever collected once
	local connections = {} -- container-level connections

	local function forget(token)
		local conn = tokens[token]
		if conn then
			conn:Disconnect()
		end
		tokens[token] = nil
		stopAnimating(token)
	end

	-- Claim the token for `player`: effect, destroy, credit. Safe against being called twice.
	local function tryCollect(token, player)
		if stopped or collected[token] then
			return
		end
		if not token.Parent or token:GetAttribute("Collected") then
			return
		end
		if not player or player.Parent == nil then
			return -- the player left
		end
		if player:GetAttribute(Config.Attr.Downed) == true then
			return -- downed players cannot pick things up
		end
		local humanoid = Util.GetHumanoid(player)
		if not humanoid or humanoid.Health <= 0 then
			return
		end

		-- claim it first: everything below may yield or error, the token must stay claimed
		collected[token] = true
		token:SetAttribute("Collected", true)
		forget(token)

		local value = token:GetAttribute("Value")
		if type(value) ~= "number" then
			value = Config.Tokens.DefaultValue
		end
		value = math.max(1, math.floor(value + 0.5))

		if container.Parent then
			local ok, err = pcall(playCollectEffect, token, container)
			if not ok then
				warn("[TokenService] collect effect failed: " .. tostring(err))
				token:Destroy()
			end
		else
			token:Destroy()
		end

		if matchHandle and type(matchHandle.AddTokens) == "function" then
			local ok, err = pcall(matchHandle.AddTokens, player, value)
			if not ok then
				warn("[TokenService] AddTokens failed: " .. tostring(err))
			end
		end
	end

	local function register(inst)
		if stopped or tokens[inst] or collected[inst] then
			return
		end
		if not inst:IsA("BasePart") or not CollectionService:HasTag(inst, TOKEN_TAG) then
			return
		end
		tokens[inst] = inst.Touched:Connect(function(hit)
			if stopped or collected[inst] then
				return
			end
			local player = Util.PlayerFromPart(hit)
			if player then
				tryCollect(inst, player)
			end
		end)
	end

	for _, d in ipairs(container:GetDescendants()) do
		register(d)
	end
	table.insert(connections, container.DescendantAdded:Connect(register))

	-- Backup for Touched: anchored, spinning parts occasionally miss a fast-moving character, so
	-- also collect when a living player's root is within PICKUP_RADIUS of a token.
	local radiusSq = PICKUP_RADIUS * PICKUP_RADIUS
	task.spawn(function()
		while not stopped do
			task.wait(PICKUP_POLL)
			if stopped then
				break
			end
			local nearby = {}
			for _, player in ipairs(Players:GetPlayers()) do
				local root = Util.GetRoot(player)
				if root then
					table.insert(nearby, { player = player, position = root.Position })
				end
			end
			if #nearby > 0 then
				for token in pairs(tokens) do
					if token.Parent and not collected[token] then
						local tp = token.Position
						for _, entry in ipairs(nearby) do
							local d = tp - entry.position
							if d:Dot(d) <= radiusSq then
								tryCollect(token, entry.player)
								break
							end
						end
					end
				end
			end
		end
	end)

	return function()
		if stopped then
			return
		end
		stopped = true
		for token in pairs(tokens) do
			forget(token)
		end
		tokens = {}
		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
		connections = {}
	end
end

-- Start the shared animation driver (also started lazily by MakeTokenPart). Idempotent.
function TokenService.Init()
	ensureDriver()
end

return TokenService
