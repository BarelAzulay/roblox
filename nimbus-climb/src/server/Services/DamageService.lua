-- DamageService: the single source of truth for player health during a match.
--
-- * Damage only exists inside a match (attr InMatch). The lobby is safe.
-- * Humanoid.Health never reaches 0: a lethal hit puts the player in the DOWNED state instead
--   (health pinned at Config.Damage.DownedHealth, frozen, semi-transparent, with a floating
--   marker so teammates can find them). Teammates (via MatchService) call Revive.
-- * Two kinds of protection: the short "hit" i-frame window started by every normal hit, and
--   "granted" invulnerability (spawn, revive, finished pad). IgnoreIFrames bypasses only the hit
--   window (damage-over-time such as storms), never granted invulnerability.
-- * Extra (not in the ARCHITECTURE contract, used by PlayerService): ClearDowned(player).
-- * v2: damage kinds come straight from Config.Damage.Kinds (Void, Lightning, SpinBar, Storm,
--   Pendulum, Other); anything unknown is reported as "Other". Max health is owned by
--   PlayerService (pet perks raise it), so this module never writes Humanoid.MaxHealth: heals,
--   revives and health fractions are all relative to whatever the humanoid currently has.
--
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local DamageService = {}

-- Signal: Fire(player, sourceKind) when a player drops into the downed state.
DamageService.PlayerDowned = Util.Signal()

local DOWNED_TRANSPARENCY = 0.55
local REVIVE_IFRAMES = 2 -- seconds of protection after a revive
local MAX_KNOCKBACK = 90 -- studs/second, hard cap for any caller

-- states[player] = {
--   HitUntil = os.clock() time the post-hit window ends,
--   GrantUntil = os.clock() time granted invulnerability ends,
--   Downed = bool,
--   Originals = { [BasePart|Decal] = original Transparency },
--   Marker = BillboardGui|nil, MarkerTween = Tween|nil,
--   HealthConn = RBXScriptConnection|nil,   -- keeps downed health pinned
--   Conns = { connections to disconnect on leave },
-- }
local states = {}
local initialized = false
local damageRemote = nil

local kindSet = { Other = true }
for _, kind in ipairs(Config.Damage.Kinds or {}) do
	kindSet[kind] = true
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function getDamageRemote()
	if not damageRemote then
		local ok, remote = pcall(Remotes.Get, "DamageTaken")
		if ok then
			damageRemote = remote
		end
	end
	return damageRemote
end

local function isInMatch(player)
	return player:GetAttribute(Config.Attr.InMatch) == true
end

local function isValidNumber(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Restores the base movement stats on a humanoid (after revive / leaving the downed state).
local function restoreMovement(humanoid)
	humanoid.UseJumpPower = true
	humanoid.WalkSpeed = Config.Physics.WalkSpeed
	humanoid.JumpPower = Config.Physics.JumpPower
end

----------------------------------------------------------------------
-- Downed visuals: transparency + a pulsing marker above the head
----------------------------------------------------------------------

local function destroyMarker(s)
	if s.MarkerTween then
		s.MarkerTween:Cancel()
		s.MarkerTween = nil
	end
	if s.Marker then
		s.Marker:Destroy()
		s.Marker = nil
	end
end

-- Downed marker (World text rule): a PIXEL-sized tag over the head: "DOWNED" in a red pill over a hint line, on
-- a compact navy plate that sizes itself to the text (fixed sizes, outlined glyphs). AlwaysOnTop and a long
-- MaxDistance on purpose: teammates must spot a downed friend across the course. Static: per-frame visual
-- animation belongs to the client (replication rule), so the server no longer tweens the text.
local MARKER_TITLE_PX = 28
local MARKER_HINT_PX = 19

local function markerLabel(parent, name, text, role, size, outlineColor, order)
	local label = Theme.Label(text, role, {
		Size = size,
		Color = Theme.Colors.White,
		Stroke = 1, -- the glyph outline replaces the classic stroke
		Outline = 2.5,
		OutlineColor = outlineColor,
		Props = {
			Name = name,
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, size + 4),
			TextWrapped = false,
			LayoutOrder = order,
		},
	})
	label.Parent = parent
	return label
end

local function createMarker(s, char)
	local anchor = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
	if not anchor then
		return
	end
	local ink = Theme.Colors.TextStroke or Theme.Colors.Ink
	local red = Theme.Colors.Bad

	local gui = Instance.new("BillboardGui")
	gui.Name = "NimbusDownedMarker"
	gui.Size = UDim2.fromOffset(320, 100)
	gui.SizeOffset = Vector2.new(0, 0.5) -- the bottom edge sits 2.2 studs over the head's centre
	gui.StudsOffset = Vector3.new(0, 2.2, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 250
	gui.LightInfluence = 0
	gui.ClipsDescendants = false

	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.AnchorPoint = Vector2.new(0.5, 1)
	plate.Position = UDim2.new(0.5, 0, 1, 0)
	plate.Size = UDim2.fromOffset(120, 0)
	plate.AutomaticSize = Enum.AutomaticSize.XY
	plate.BackgroundColor3 = Theme.Colors.Panel
	plate.BackgroundTransparency = 0.06
	plate.BorderSizePixel = 0
	plate.Parent = gui
	Theme.Corner(plate, UDim.new(0, 14))
	Theme.Stroke(plate, red, 3, 0)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 7)
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = plate
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 3)
	layout.Parent = plate

	local pill = Instance.new("Frame")
	pill.Name = "TitlePill"
	pill.Size = UDim2.fromOffset(0, MARKER_TITLE_PX + 8)
	pill.AutomaticSize = Enum.AutomaticSize.XY
	pill.BackgroundColor3 = red
	pill.BorderSizePixel = 0
	pill.LayoutOrder = 1
	pill.Parent = plate
	Theme.Corner(pill, UDim.new(0, 12))
	Theme.Stroke(pill, ink, 2.5, 0)
	local pillPad = Instance.new("UIPadding")
	pillPad.PaddingTop = UDim.new(0, 2)
	pillPad.PaddingBottom = UDim.new(0, 2)
	pillPad.PaddingLeft = UDim.new(0, 14)
	pillPad.PaddingRight = UDim.new(0, 14)
	pillPad.Parent = pill
	markerLabel(pill, "Title", "DOWNED", "Accent", MARKER_TITLE_PX, Theme.Darken(red, 0.6), 1)

	markerLabel(plate, "Hint", "reach the next checkpoint!", "Body", MARKER_HINT_PX, ink, 2)

	gui.Parent = anchor
	s.Marker = gui
	s.MarkerTween = nil
end

local function applyDownedLook(s, char)
	s.Originals = {}
	for _, inst in ipairs(char:GetDescendants()) do
		-- The root part is already fully transparent; leave it (and any invisible part) alone.
		if (inst:IsA("BasePart") and inst.Name ~= "HumanoidRootPart") or inst:IsA("Decal") then
			s.Originals[inst] = inst.Transparency
			if inst.Transparency < DOWNED_TRANSPARENCY then
				inst.Transparency = DOWNED_TRANSPARENCY
			end
		end
	end
	createMarker(s, char)
end

local function restoreLook(s)
	for inst, original in pairs(s.Originals) do
		if inst.Parent then
			inst.Transparency = original
		end
	end
	s.Originals = {}
	destroyMarker(s)
end

-- A small green sparkle burst at the revived player's feet.
local function reviveBurst(player)
	local root = Util.GetRoot(player)
	if not root then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "NimbusReviveFx"
	attachment.Parent = root

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(Theme.Colors.Good, Theme.Colors.White)
	emitter.LightEmission = 1
	emitter.Lifetime = NumberRange.new(0.8, 1.3)
	emitter.Speed = NumberRange.new(8, 16)
	emitter.SpreadAngle = Vector2.new(360, 360)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.1),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Rate = 0
	emitter.Parent = attachment
	emitter:Emit(28)
	Debris:AddItem(attachment, 2.5)
end

----------------------------------------------------------------------
-- Downed state transitions
----------------------------------------------------------------------

local function enterDowned(player, s, char, humanoid, kind)
	s.Downed = true
	humanoid.UseJumpPower = true
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.Health = Config.Damage.DownedHealth
	player:SetAttribute(Config.Attr.Downed, true)
	applyDownedLook(s, char)

	-- Keep health pinned: the default regen script (or anything else) must not heal a downed
	-- player and must never push them to 0.
	if s.HealthConn then
		s.HealthConn:Disconnect()
	end
	s.HealthConn = humanoid.HealthChanged:Connect(function(health)
		if s.Downed and health > Config.Damage.DownedHealth and humanoid.Parent then
			humanoid.Health = Config.Damage.DownedHealth
		end
	end)

	DamageService.PlayerDowned:Fire(player, kind)
end

-- Leaves the downed state bookkeeping (visuals + attribute). Does not touch health or speed.
local function leaveDownedState(player, s)
	if not s.Downed then
		return false
	end
	s.Downed = false -- before touching anything else: the HealthChanged guard checks this
	if s.HealthConn then
		s.HealthConn:Disconnect()
		s.HealthConn = nil
	end
	restoreLook(s)
	if player.Parent then
		player:SetAttribute(Config.Attr.Downed, false)
	end
	return true
end

-- The character is going away (death, reset, respawn): drop everything tied to it.
local function resetCharacterState(player, s)
	s.HitUntil = 0
	s.GrantUntil = 0
	leaveDownedState(player, s)
end

----------------------------------------------------------------------
-- Per-player tracking
----------------------------------------------------------------------

local function newState()
	return {
		HitUntil = 0,
		GrantUntil = 0,
		Downed = false,
		Originals = {},
		Marker = nil,
		MarkerTween = nil,
		HealthConn = nil,
		Conns = {},
	}
end

local function track(player)
	local existing = states[player]
	if existing then
		return existing
	end
	if not player or not player.Parent then
		return nil
	end

	local s = newState()
	states[player] = s

	-- CharacterRemoving fires before the next CharacterAdded, so clearing here can never wipe the
	-- spawn i-frames PlayerService grants to the fresh character.
	table.insert(
		s.Conns,
		player.CharacterRemoving:Connect(function()
			resetCharacterState(player, s)
		end)
	)

	-- Leaving the match (SendToLobby, abandon) must never leave a player stuck downed.
	table.insert(
		s.Conns,
		player:GetAttributeChangedSignal(Config.Attr.InMatch):Connect(function()
			if not isInMatch(player) then
				DamageService.ClearDowned(player)
			end
		end)
	)

	-- If something outside this module flips the Downed attribute off, follow along.
	table.insert(
		s.Conns,
		player:GetAttributeChangedSignal(Config.Attr.Downed):Connect(function()
			if s.Downed and player:GetAttribute(Config.Attr.Downed) ~= true then
				DamageService.ClearDowned(player)
			end
		end)
	)

	return s
end

local function untrack(player)
	local s = states[player]
	if not s then
		return
	end
	states[player] = nil
	for _, conn in ipairs(s.Conns) do
		conn:Disconnect()
	end
	s.Conns = {}
	s.Downed = false
	if s.HealthConn then
		s.HealthConn:Disconnect()
		s.HealthConn = nil
	end
	destroyMarker(s)
	s.Originals = {}
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function DamageService.Init()
	if initialized then
		return
	end
	initialized = true
	getDamageRemote() -- resolve early (Remotes.Init has already run in Main)
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(untrack)
	for _, player in ipairs(Players:GetPlayers()) do
		track(player)
	end
end

-- Pushes the player away from the given point (horizontal) with a small pop upwards.
local function applyKnockback(root, from, strength)
	strength = Util.Clamp(strength, 0, MAX_KNOCKBACK)
	local away = root.Position - from
	local dir = Vector3.new(away.X, 0, away.Z)
	if dir.Magnitude < 0.05 then
		local look = root.CFrame.LookVector
		dir = Vector3.new(-look.X, 0, -look.Z)
	end
	if dir.Magnitude < 0.05 then
		dir = Vector3.new(0, 0, 1)
	end
	dir = dir.Unit
	local velocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity =
		Vector3.new(dir.X * strength, math.max(velocity.Y, strength * 0.45), dir.Z * strength)
end

-- Returns true if damage was applied.
-- opts: { IgnoreIFrames = bool, KnockbackFrom = Vector3?, Knockback = number? }
function DamageService.Damage(player, amount, sourceKind, opts)
	if not player or not player.Parent or not isValidNumber(amount) or amount <= 0 then
		return false
	end
	local s = states[player] or track(player)
	if not s then
		return false
	end
	opts = opts or {}

	if not isInMatch(player) then
		return false -- the lobby is safe
	end
	if s.Downed then
		return false -- downed players ignore further damage
	end

	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	local now = os.clock()
	if now < s.GrantUntil then
		return false
	end
	if not opts.IgnoreIFrames and now < s.HitUntil then
		return false
	end

	local kind = "Other"
	if kindSet[sourceKind] then
		kind = sourceKind
	end

	local downedHealth = Config.Damage.DownedHealth
	local after = humanoid.Health - amount
	local goesDown = after <= downedHealth
	if goesDown then
		after = downedHealth -- health must never reach 0
	end
	humanoid.Health = after

	if not opts.IgnoreIFrames then
		s.HitUntil = now + Config.Damage.IFrames
	end

	local remote = getDamageRemote()
	if remote then
		pcall(function()
			remote:FireClient(player, Util.Round(amount, 1), kind)
		end)
	end

	if goesDown then
		enterDowned(player, s, char, humanoid, kind)
	elseif root and typeof(opts.KnockbackFrom) == "Vector3" then
		local strength = 40
		if isValidNumber(opts.Knockback) then
			strength = opts.Knockback
		end
		applyKnockback(root, opts.KnockbackFrom, strength)
	end

	return true
end

-- Returns the amount actually healed. Downed players are not healed (use Revive).
function DamageService.Heal(player, amount)
	if not player or not isValidNumber(amount) or amount <= 0 then
		return 0
	end
	local s = states[player]
	if s and s.Downed then
		return 0
	end
	local humanoid = Util.GetHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return 0
	end
	local before = humanoid.Health
	local after = math.min(humanoid.MaxHealth, before + amount)
	if after <= before then
		return 0
	end
	humanoid.Health = after
	return after - before
end

function DamageService.HealFraction(player, fraction)
	if not isValidNumber(fraction) then
		return 0
	end
	local humanoid = Util.GetHumanoid(player)
	if not humanoid then
		return 0
	end
	return DamageService.Heal(player, humanoid.MaxHealth * fraction)
end

-- Sets health to a fraction of max (never below DownedHealth; ignored while downed).
function DamageService.SetHealthFraction(player, fraction)
	if not player or not isValidNumber(fraction) then
		return
	end
	local s = states[player]
	if s and s.Downed then
		return
	end
	local humanoid = Util.GetHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local target = humanoid.MaxHealth * Util.Clamp(fraction, 0, 1)
	humanoid.Health = Util.Clamp(target, Config.Damage.DownedHealth, humanoid.MaxHealth)
end

function DamageService.GrantInvulnerability(player, seconds)
	if not player or not isValidNumber(seconds) or seconds <= 0 then
		return
	end
	local s = states[player] or track(player)
	if not s then
		return
	end
	local untilTime = os.clock() + seconds
	if untilTime > s.GrantUntil then
		s.GrantUntil = untilTime
	end
end

function DamageService.IsInvulnerable(player)
	local s = states[player]
	if not s then
		return false
	end
	local now = os.clock()
	return now < s.GrantUntil or now < s.HitUntil
end

function DamageService.IsDowned(player)
	local s = states[player]
	return s ~= nil and s.Downed == true
end

-- Downed -> back on their feet with ReviveHealthFraction health and 2s of protection.
function DamageService.Revive(player)
	local s = player and states[player]
	if not s or not s.Downed then
		return
	end
	leaveDownedState(player, s)

	local humanoid = Util.GetHumanoid(player)
	if humanoid and humanoid.Health > 0 then
		restoreMovement(humanoid)
		-- MaxHealth stays as PlayerService set it (it includes pet perks).
		humanoid.Health = humanoid.MaxHealth * Config.Damage.ReviveHealthFraction
	end
	DamageService.GrantInvulnerability(player, REVIVE_IFRAMES)
	reviveBurst(player)
end

-- Extra: silently leaves the downed state (no health change, no i-frames, no effects).
-- PlayerService.SendToLobby uses it; it is also triggered when InMatch turns false.
function DamageService.ClearDowned(player)
	local s = player and states[player]
	if not s or not s.Downed then
		return
	end
	leaveDownedState(player, s)
	local humanoid = Util.GetHumanoid(player)
	if humanoid and humanoid.Health > 0 then
		restoreMovement(humanoid)
	end
end

return DamageService
