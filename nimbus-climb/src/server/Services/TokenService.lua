-- TokenService: the cloud tokens. MakeTokenPart builds the visual (a glowing golden coin with a
-- little cloud puff on it), one shared Heartbeat driver gives the tokens right next to a player a
-- cheap spin + bob (see "Shared animation driver" for what that costs), and Watch() turns tokens
-- inside a match course into collectable pickups.
--
-- Animation cost: a server-side pose replicates to EVERY client (StreamingEnabled is off) and the
-- clients do not interpolate it, so the server only poses what a player can actually see, slowly.
-- If Config.Tokens.ClientAnimated is true the server does not animate at all and a client
-- controller is expected to spin/bob the coins locally instead (that costs the network nothing).
--
-- v2: golden bonus tokens. MakeTokenPart(position, parent, value) with value >= Config.Tokens.GoldenValue
-- builds a bigger (1.5x), paler-gold, brighter-sparkling coin with a flare disc and a glint star,
-- tagged BOTH Config.Tags.GoldenToken and Config.Tags.CloudToken. Watch() stays the only collector.
--
-- Plain Lua 5.1-compatible syntax only. No asset ids: Parts + built-in particle textures.
-- Palette: warm but calm golds (Theme.World.Token when available); nothing is pure white.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)

-- Theme is only used for its in-world palette; a broken UI kit must never take the tokens down.
local themeOk, Theme = pcall(require, Shared.Theme)
if not themeOk or type(Theme) ~= "table" then
	Theme = {}
end

local TokenService = {}

local TOKEN_TAG = Config.Tags.CloudToken
local GOLDEN_TAG = Config.Tags.GoldenToken
local DEFAULT_VALUE = Config.Tokens.DefaultValue
local GOLDEN_VALUE = Config.Tokens.GoldenValue
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

----------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------
local COIN_DIAMETER = 3.1
local COIN_THICKNESS = 0.55
local RIM_DIAMETER = 3.6
local RIM_THICKNESS = 0.4
local HALO_DIAMETER = 5.2

local ANIM_STEP = 1 / 15 -- the driver poses tokens at 15 Hz: a slow spin does not need more
local CULL_DISTANCE = 65 -- tokens farther than this from every player are left alone (not even looked at)
local PLAYER_REFRESH = 0.5 -- how often the driver re-reads player positions and re-picks the tokens to pose

local PICKUP_POLL = 0.12 -- backup proximity poll inside Watch()
local PICKUP_RADIUS = 3.2 -- studs from the character's root to the token centre
local GOLDEN_PICKUP_RADIUS = 4.4 -- golden tokens are bigger, so they are easier to grab
local COLLECT_FADE = 0.3

----------------------------------------------------------------------
-- Palette
----------------------------------------------------------------------
local WORLD = Theme.World or {}

local function colorOr(value, fallback)
	if typeof(value) == "Color3" then
		return value
	end
	return fallback
end

local GOLD = colorOr(WORLD.Token, Color3.fromRGB(232, 184, 62))
local GLOW = GOLD:Lerp(Color3.fromRGB(255, 240, 190), 0.45)
local AMBER = Color3.fromRGB(192, 124, 38)
local PUFF = Color3.fromRGB(218, 226, 240)

local GOLDEN_CORE = Color3.fromRGB(255, 236, 168) -- golden-white
local GOLDEN_RIM = Color3.fromRGB(232, 182, 72)
local GOLDEN_PUFF = Color3.fromRGB(246, 240, 214)
local GOLDEN_GLOW = Color3.fromRGB(255, 230, 150)

-- Everything that differs between a normal and a golden token.
local LOOKS = {
	normal = {
		scale = 1,
		core = GOLD,
		rim = AMBER,
		puff = PUFF,
		glow = GLOW,
		haloScale = 1,
		haloTransparency = 0.88,
		lightBrightness = 1.0,
		lightRange = 11,
		sparkleRate = 5,
		sparkleSize = 0.55,
		sparkleLife = NumberRange.new(0.9, 1.6),
		spin = 2.0, -- radians per second around the vertical axis
		bob = 0.45, -- bob amplitude in studs
	},
	golden = {
		scale = 1.5,
		core = GOLDEN_CORE,
		rim = GOLDEN_RIM,
		puff = GOLDEN_PUFF,
		glow = GOLDEN_GLOW,
		haloScale = 1.25,
		haloTransparency = 0.85,
		lightBrightness = 2.0,
		lightRange = 17,
		sparkleRate = 16,
		sparkleSize = 0.95,
		sparkleLife = NumberRange.new(1.1, 2.0),
		spin = 2.6,
		bob = 0.6,
	},
}

local BOB_SPEED = 2.2 -- radians per second of the up/down sine

----------------------------------------------------------------------
-- Shared animation driver
--   One Heartbeat connection for every token in the server. Each token gets an entry with its
--   base position and a random phase so neighbours never move in lockstep.
--
--   Cost model (why it is built like this): the coin is an anchored root plus welded pieces, and
--   every pose is a CFrame write that replicates to every client, once per part of the moving
--   assembly. A Saint course has ~95 tokens (~20 golden, ~620 parts). Posing every token (6 parts,
--   golden 9) at 30 Hz was ~18k part updates per second for the whole server (measured on generated
--   courses with the smoke mock). Now only tokens within CULL_DISTANCE of a player are posed, at
--   15 Hz, and the aura (a sphere, so spinning never changes how it looks) is not part of the
--   moving assembly (5 parts per coin, 8 per golden one): ~1.4k updates per second with one player
--   on Saint, ~3.7k-4.2k with four (Easy: ~5k before, ~0.3k-1.9k now). The tokens that are not
--   posed are only looked at every PLAYER_REFRESH seconds (that is when the short list of tokens
--   to pose is rebuilt); the per-step work is a plain walk over that list.
--
--   Tokens that are not in the workspace yet wait; tokens that were destroyed are dropped.
--   Config.Tokens.ClientAnimated = true switches the whole driver off (clients animate locally).
----------------------------------------------------------------------
local SERVER_ANIMATION = Config.Tokens.ClientAnimated ~= true

local animated = {} -- token part -> { base, lastPos, phase, parented, spin, bob }
local active = {} -- array of the token parts near a player, rebuilt by refreshActive()
local driverConnection = nil
local nextStepAt = 0
local nextRefreshAt = 0
local phaseRng = Random.new()
local CULL_DISTANCE_SQ = CULL_DISTANCE * CULL_DISTANCE

-- If something else moved the token (e.g. its course was pivoted), follow along instead of
-- snapping it back to the old place.
local function followExternalMove(token, rec)
	local moved = token.Position - rec.lastPos
	if moved:Dot(moved) > 0.0625 then
		rec.base = rec.base + moved
		rec.lastPos = rec.lastPos + moved
	end
end

-- Re-read the player positions and rebuild `active`. Also forgets tokens that were in the world and
-- are gone (destroyed, or their course folder was: that leaves Parent set, hence IsDescendantOf).
local function refreshActive(now)
	nextRefreshAt = now + PLAYER_REFRESH
	local positions = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local root = Util.GetRoot(player)
		if root then
			positions[#positions + 1] = root.Position
		end
	end

	active = {}
	for token, rec in pairs(animated) do
		if token.Parent == nil or not token:IsDescendantOf(Workspace) then
			-- Not in the world. Never-parented tokens just wait; one that WAS in the world and is gone
			-- is forgotten so this table never keeps dead tokens alive.
			if rec.parented then
				animated[token] = nil
			end
		else
			-- Welded pieces only follow the root once the token is in the workspace.
			rec.parented = true
			followExternalMove(token, rec)
			local base = rec.base
			for _, position in ipairs(positions) do
				local d = base - position
				if d:Dot(d) <= CULL_DISTANCE_SQ then
					active[#active + 1] = token
					break
				end
			end
		end
	end
end

local function stepTokens()
	local now = os.clock()
	if now < nextStepAt then
		return
	end
	-- steady cadence: schedule from the previous due time, so a frame that lands a hair early does not
	-- cost a whole extra frame; after a hitch do not try to catch up
	nextStepAt = nextStepAt + ANIM_STEP
	if nextStepAt <= now then
		nextStepAt = now + ANIM_STEP
	end
	if next(animated) == nil then
		return
	end
	if now >= nextRefreshAt then
		refreshActive(now)
	end

	for i = 1, #active do
		local token = active[i]
		local rec = animated[token] -- nil once collected / forgotten since the last refresh
		if rec and token.Parent ~= nil then
			followExternalMove(token, rec)
			local base = rec.base
			local bob = math.sin(now * BOB_SPEED + rec.phase) * rec.bob
			local position = Vector3.new(base.X, base.Y + bob, base.Z)
			token.CFrame = CFrame.new(position) * CFrame.Angles(0, now * rec.spin + rec.phase, 0)
			rec.lastPos = position
		end
	end
end

local function ensureDriver()
	if driverConnection or not SERVER_ANIMATION then
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
-- static = true: the piece is anchored and NOT welded, so it stays where it is when the root is posed
-- (only for shapes that look the same whatever the coin does, e.g. the spherical aura).
local function addPiece(token, name, shape, size, offset, color, material, transparency, static)
	local piece = Instance.new("Part")
	piece.Name = name
	piece.Shape = shape
	piece.Size = size
	piece.Material = material
	piece.Color = color
	piece.Transparency = transparency or 0
	piece.Anchored = static == true
	piece.Massless = true
	piece.CanCollide = false
	piece.CanTouch = false
	piece.CanQuery = false
	piece.CastShadow = false
	piece.CFrame = token.CFrame * offset
	piece.Parent = token
	if not static then
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = token
		weld.Part1 = piece
		weld.Parent = piece
	end
	return piece
end

-- True when `value` makes a token golden.
local function isGoldenValue(value)
	return type(value) == "number" and value >= GOLDEN_VALUE
end

-- THE visual cloud token. position: world Vector3 (centre of the coin). parent: Instance or nil.
-- value: how many tokens it is worth (attribute "Value", default Config.Tokens.DefaultValue).
-- value >= Config.Tokens.GoldenValue makes a golden token (also tagged GoldenToken).
-- The returned Part is the coin: Anchored, CanCollide=false, tagged CloudToken.
function TokenService.MakeTokenPart(position, parent, value)
	ensureDriver()
	if type(value) ~= "number" or value ~= value then
		value = DEFAULT_VALUE
	end
	local golden = isGoldenValue(value)
	local look = golden and LOOKS.golden or LOOKS.normal
	local s = look.scale
	local phase = phaseRng:NextNumber(0, math.pi * 2)

	-- Roblox cylinders have their axis along X, so this is a coin standing on its edge; spinning
	-- it around the world Y axis shows both faces.
	local token = Instance.new("Part")
	token.Name = golden and "GoldenCloudToken" or "CloudToken"
	token.Shape = Enum.PartType.Cylinder
	token.Size = Vector3.new(COIN_THICKNESS * s, COIN_DIAMETER * s, COIN_DIAMETER * s)
	token.Material = Enum.Material.Neon
	token.Color = look.core
	token.Anchored = true
	token.CanCollide = false
	token.CanTouch = true
	token.CanQuery = false
	token.CastShadow = false
	token.CFrame = CFrame.new(position) * CFrame.Angles(0, phase, 0)
	token:SetAttribute("Value", value)
	if golden then
		token:SetAttribute("Golden", true)
	end

	-- deeper rim peeking out behind the coin
	addPiece(token, "Rim", Enum.PartType.Cylinder,
		Vector3.new(RIM_THICKNESS * s, RIM_DIAMETER * s, RIM_DIAMETER * s), CFrame.new(0, 0, 0),
		look.rim, Enum.Material.SmoothPlastic, 0)

	-- the little cloud puff, poking through both faces of the coin (local X is the thickness)
	addPiece(token, "PuffMiddle", Enum.PartType.Ball, Vector3.new(1.2 * s, 1.2 * s, 1.2 * s),
		CFrame.new(0, 0.22 * s, 0), look.puff, Enum.Material.SmoothPlastic, 0)
	addPiece(token, "PuffLeft", Enum.PartType.Ball, Vector3.new(0.85 * s, 0.85 * s, 0.85 * s),
		CFrame.new(0, -0.12 * s, -0.7 * s), look.puff, Enum.Material.SmoothPlastic, 0)
	addPiece(token, "PuffRight", Enum.PartType.Ball, Vector3.new(0.85 * s, 0.85 * s, 0.85 * s),
		CFrame.new(0, -0.12 * s, 0.7 * s), look.puff, Enum.Material.SmoothPlastic, 0)

	-- soft translucent aura so tokens read from far away. A sphere looks the same however the coin turns
	-- and it is 2.6+ studs in radius against a 0.45-0.6 stud bob, so it stays put (static) instead of
	-- being re-posed with the coin: one replicated part less per coin and per pose.
	local haloSize = HALO_DIAMETER * look.haloScale * s
	addPiece(token, "Halo", Enum.PartType.Ball, Vector3.new(haloSize, haloSize, haloSize),
		CFrame.new(0, 0, 0), look.glow, Enum.Material.Neon, look.haloTransparency, true)

	if golden then
		-- a big thin flare disc behind the coin and a four-point glint star across its face
		addPiece(token, "Flare", Enum.PartType.Cylinder, Vector3.new(0.12, 8.4, 8.4), CFrame.new(0, 0, 0),
			GOLDEN_GLOW, Enum.Material.Neon, 0.84)
		addPiece(token, "GlintVertical", Enum.PartType.Block, Vector3.new(0.1, 7.4, 0.28), CFrame.new(0, 0, 0),
			GOLDEN_GLOW, Enum.Material.Neon, 0.5)
		addPiece(token, "GlintHorizontal", Enum.PartType.Block, Vector3.new(0.1, 0.28, 7.4), CFrame.new(0, 0, 0),
			GOLDEN_GLOW, Enum.Material.Neon, 0.5)
	end

	local light = Instance.new("PointLight")
	light.Name = "TokenLight"
	light.Color = look.core
	light.Brightness = look.lightBrightness
	light.Range = look.lightRange
	light.Shadows = false
	light.Parent = token

	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Name = "Sparkles"
	sparkles.Texture = SPARKLE_TEXTURE
	sparkles.Color = ColorSequence.new(look.glow, look.rim)
	sparkles.LightEmission = 1
	sparkles.LightInfluence = 0
	sparkles.Rate = look.sparkleRate
	sparkles.Lifetime = look.sparkleLife
	sparkles.Speed = NumberRange.new(0.4, golden and 2.2 or 1.2)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Rotation = NumberRange.new(0, 360)
	sparkles.RotSpeed = NumberRange.new(-60, 60)
	sparkles.Acceleration = Vector3.new(0, 0.8, 0)
	sparkles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, look.sparkleSize),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, golden and 0.05 or 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkles.Parent = token

	CollectionService:AddTag(token, TOKEN_TAG)
	if golden then
		CollectionService:AddTag(token, GOLDEN_TAG)
	end
	if SERVER_ANIMATION then
		animated[token] = {
			base = position,
			lastPos = position,
			phase = phase,
			parented = false,
			spin = look.spin,
			bob = look.bob,
		}
	end
	token.Parent = parent
	return token
end

----------------------------------------------------------------------
-- Collection effect
----------------------------------------------------------------------
-- Sparkle burst + expanding glow bubble (both parented to `effectParent` so they vanish with the
-- course), while the coin itself pops upward, fades and is destroyed. Golden tokens get a bigger
-- burst and an expanding ground ring on top.
local function playCollectEffect(token, effectParent, golden)
	local position = token.Position
	local glow = golden and GOLDEN_GLOW or GLOW
	local core = golden and GOLDEN_RIM or GOLD

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
	emitter.Color = ColorSequence.new(glow, core)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.45, golden and 1.1 or 0.85)
	emitter.Speed = NumberRange.new(12, golden and 30 or 24)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 3
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Acceleration = Vector3.new(0, -8, 0)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, golden and 1.3 or 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.7, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = burst
	burst.Parent = effectParent
	emitter:Emit(golden and 44 or 22)
	Debris:AddItem(burst, 1.6)

	local bubble = Instance.new("Part")
	bubble.Name = "TokenBubble"
	bubble.Shape = Enum.PartType.Ball
	bubble.Size = Vector3.new(1.5, 1.5, 1.5)
	bubble.Material = Enum.Material.Neon
	bubble.Color = glow
	bubble.Transparency = 0.5
	bubble.Anchored = true
	bubble.CanCollide = false
	bubble.CanTouch = false
	bubble.CanQuery = false
	bubble.CastShadow = false
	bubble.CFrame = CFrame.new(position)
	bubble.Parent = effectParent
	local bubbleSize = golden and 11 or 7
	Util.Tween(bubble, 0.35, { Size = Vector3.new(bubbleSize, bubbleSize, bubbleSize), Transparency = 1 },
		Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	Debris:AddItem(bubble, 0.6)

	if golden then
		-- flat ring racing outwards at the token's height
		local ring = Instance.new("Part")
		ring.Name = "TokenRing"
		ring.Shape = Enum.PartType.Cylinder
		ring.Size = Vector3.new(0.2, 2, 2)
		ring.Material = Enum.Material.Neon
		ring.Color = GOLDEN_GLOW
		ring.Transparency = 0.45
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanTouch = false
		ring.CanQuery = false
		ring.CastShadow = false
		ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
		ring.Parent = effectParent
		Util.Tween(ring, 0.6, { Size = Vector3.new(0.2, 16, 16), Transparency = 1 },
			Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		Debris:AddItem(ring, 0.9)
	end

	-- the coin itself: float up, fade every piece, dim the light, stop the sparkles
	local lift = Vector3.new(0, golden and 4 or 3, 0)
	for _, d in ipairs(token:GetDescendants()) do
		if d:IsA("BasePart") then
			local goal = { Transparency = 1 }
			if d.Anchored then
				-- the unwelded aura does not follow the coin: lift it by hand
				goal.CFrame = d.CFrame + lift
			end
			Util.Tween(d, COLLECT_FADE, goal, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		elseif d:IsA("PointLight") then
			Util.Tween(d, COLLECT_FADE, { Brightness = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = false
		end
	end
	Util.Tween(token, COLLECT_FADE, {
		Transparency = 1,
		CFrame = token.CFrame + lift,
	}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	Debris:AddItem(token, COLLECT_FADE + 0.15)
end

----------------------------------------------------------------------
-- Watch: make the tokens of one match course collectable
----------------------------------------------------------------------
local function isGoldenToken(token)
	return CollectionService:HasTag(token, GOLDEN_TAG) or token:GetAttribute("Golden") == true
end

-- container: the course Folder/Model. matchHandle = { AddTokens = function(player, n) end }.
-- Returns stopFn (idempotent): disconnects every Touched/poll/descendant hook.
function TokenService.Watch(container, matchHandle)
	if not container then
		warn("[TokenService] Watch called without a container")
		return function() end
	end

	local stopped = false
	local tokens = {} -- token part -> { conn = Touched connection, radiusSq = pickup radius squared }
	local collected = {} -- token part -> true; a token is only ever collected once
	local connections = {} -- container-level connections

	local function forget(token)
		local rec = tokens[token]
		if rec and rec.conn then
			rec.conn:Disconnect()
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
		local golden = isGoldenToken(token)
		forget(token)

		local value = token:GetAttribute("Value")
		if type(value) ~= "number" or value ~= value then
			if golden then
				value = GOLDEN_VALUE
			else
				value = DEFAULT_VALUE
			end
		end
		value = math.max(1, math.floor(value + 0.5))

		if container.Parent then
			local ok, err = pcall(playCollectEffect, token, container, golden)
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
		local radius = PICKUP_RADIUS
		if isGoldenToken(inst) then
			radius = GOLDEN_PICKUP_RADIUS
		end
		tokens[inst] = {
			radiusSq = radius * radius,
			conn = inst.Touched:Connect(function(hit)
				if stopped or collected[inst] then
					return
				end
				local player = Util.PlayerFromPart(hit)
				if player then
					tryCollect(inst, player)
				end
			end),
		}
	end

	for _, d in ipairs(container:GetDescendants()) do
		register(d)
	end
	table.insert(connections, container.DescendantAdded:Connect(register))

	-- Backup for Touched: anchored, spinning parts occasionally miss a fast-moving character, so
	-- also collect when a living player's root is within the pickup radius of a token.
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
				for token, rec in pairs(tokens) do
					if token.Parent and not collected[token] then
						local tp = token.Position
						for _, entry in ipairs(nearby) do
							local d = tp - entry.position
							if d:Dot(d) <= rec.radiusSq then
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

-- Start the shared animation driver (also started lazily by MakeTokenPart). Idempotent. Does nothing
-- when Config.Tokens.ClientAnimated is true (the clients spin and bob the coins).
function TokenService.Init()
	ensureDriver()
end

return TokenService
