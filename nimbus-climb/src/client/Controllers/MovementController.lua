-- MovementController (client): smooth run, stamina, dash, camera feel and mobile buttons.
--
--   MovementController.Init()
--   MovementController.GetDashCooldownFraction() -> number   -- 0 = ready .. 1 = just used
--
-- How it works
--   * Input is bound once with ContextActionService (high priority, so Shift never toggles
--     Roblox shift-lock and typing in a TextBox never triggers a dash).
--   * Everything that touches the character lives in a per-character context that is created on
--     CharacterAdded and torn down on CharacterRemoving / Died, so nothing leaks across respawns.
--   * WalkSpeed is "owned" by the server (PlayerService freezes/unfreezes it). We watch for
--     changes we did not make and treat that value as the base speed, so a frozen or Downed
--     player can never run or dash, and the server can still change the speed at any time.
--   * The dash is velocity-based: for DashDuration seconds the horizontal velocity of the
--     HumanoidRootPart is re-asserted every physics step while the vertical velocity is left alone.
-- Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)
local Util = require(Shared.Util)
local Remotes = require(Shared.Remotes)

local MovementController = {}

-- Luau/Lua 5.1 have math.atan2; Lua 5.3+ folds it into math.atan(y, x). Support both.
local atan2 = math.atan2 or function(y, x)
	return math.atan(y, x)
end

local LocalPlayer = Players.LocalPlayer
local P = Config.Physics
local ATTR = Config.Attr

----------------------------------------------------------------------
-- Tuning (feel only; gameplay numbers live in Config.Physics)
----------------------------------------------------------------------
local BASE_FOV = 70
local RUN_FOV_BOOST = 4 -- extra degrees at full run
local DASH_FOV_BOOST = 12 -- 70 -> 82 -> 70 punch
local PUNCH_ATTACK = 0.07 -- seconds to reach the peak
local PUNCH_TOTAL = 0.5 -- seconds until the punch has fully relaxed

local ZOOM_MAX = 40 -- LocalPlayer.CameraMaxZoomDistance

local EXHAUST_RESUME = 15 -- stamina needed to run again after hitting 0
local RUN_RAMP_UP = 9 -- exponential smoothing rates (1/s)
local RUN_RAMP_DOWN = 7
local RUN_REGEN_DELAY = 0.25 -- seconds after running before stamina regenerates
local DASH_REGEN_DELAY = 0.5
local DASH_BUFFER = 0.18 -- a dash pressed this close to "ready" is queued
local FROZEN_SPEED = 0.5 -- WalkSpeed below this means "frozen by the server"
local SPEED_EPS = 0.05 -- tolerance when comparing WalkSpeed with what we wrote
local MOVE_EPS = 0.1 -- MoveDirection magnitude that counts as "moving"

local LINE_COUNT = 18 -- screen speed lines
local BUTTON_ALPHA = 0.2
local BUTTON_ALPHA_LOCKED = 0.7

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local initialized = false
local ctx = nil -- active character context, nil when there is none
local bindToken = 0 -- bumps on every bind/unbind so stale async binds can abort

local stamina = P.MaxStamina
local lastMirrored = nil
local exhausted = false -- hit 0 stamina; blocked from running until EXHAUST_RESUME

local shiftHeld = false -- physical Shift key
local runToggled = false -- mobile button / gamepad L3
local runBlend = 0 -- 0 = walk speed .. 1 = full run speed

local baseSpeed = P.WalkSpeed -- WalkSpeed as set by the server
local lastWritten = nil -- the WalkSpeed value WE last wrote (nil = we are not overriding)
local regenBlockedUntil = 0

local cooldownEnd = 0
local dashBufferUntil = 0
local dash = nil -- { dir = Vector3, startTime = n, endTime = n } while dashing
local punchStart = -10

local dashRemote = nil
local ui = nil -- { holder, lines, flashToken, mobile } once the GUI is built

-- forward declarations
local unbindCharacter
local tryDash

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function isLocked()
	if LocalPlayer:GetAttribute(ATTR.Downed) == true then
		return true
	end
	return baseSpeed < FROZEN_SPEED
end

-- Mirror stamina into the player attribute the HUD reads; throttled to avoid attribute spam.
local function mirrorStamina(force)
	local value = Util.Clamp(stamina, 0, P.MaxStamina)
	if lastMirrored ~= nil and not force then
		if value == lastMirrored then
			return
		end
		local atEdge = value <= 0 or value >= P.MaxStamina
		if not atEdge and math.abs(value - lastMirrored) < 0.1 then
			return
		end
	end
	lastMirrored = value
	LocalPlayer:SetAttribute(ATTR.Stamina, value)
end

local function applyCameraSettings()
	pcall(function()
		LocalPlayer.CameraMaxZoomDistance = ZOOM_MAX
	end)
end

local function tween(instance, seconds, goal, style, direction)
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
	local t = TweenService:Create(instance, info, goal)
	t:Play()
	return t
end

----------------------------------------------------------------------
-- GUI: screen speed lines + mobile buttons
----------------------------------------------------------------------
local function setMobileVisible(visible)
	if ui and ui.mobile then
		ui.mobile.Gui.Enabled = visible
	end
end

-- Short burst of white streaks radiating from the screen centre.
local function flashSpeedLines()
	if not ui or not ui.holder then
		return
	end
	ui.flashToken = ui.flashToken + 1
	local token = ui.flashToken
	ui.holder.Visible = true
	for _, line in ipairs(ui.lines) do
		local frame = line.Frame
		frame.Position = UDim2.fromScale(line.X, line.Y)
		frame.BackgroundTransparency = 0.35 + line.Alpha
		tween(frame, 0.34, { BackgroundTransparency = 1, Position = UDim2.fromScale(line.OutX, line.OutY) })
	end
	task.delay(0.4, function()
		if ui and ui.flashToken == token then
			ui.holder.Visible = false
		end
	end)
end

local function buildSpeedLines(playerGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "MovementFx"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 2
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local holder = Instance.new("Frame")
	holder.Name = "SpeedLines"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromScale(1, 1)
	holder.Visible = false
	holder.Parent = gui

	local rng = Random.new(11)
	local lines = {}
	for i = 1, LINE_COUNT do
		local angle = ((i - 1) / LINE_COUNT) * math.pi * 2 + rng:NextNumber(-0.09, 0.09)
		local radius = rng:NextNumber(0.3, 0.45)
		local cosA = math.cos(angle)
		local sinA = math.sin(angle)

		local frame = Instance.new("Frame")
		frame.Name = "Line"
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.BorderSizePixel = 0
		frame.BackgroundColor3 = Theme.Colors.White
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.fromOffset(rng:NextInteger(90, 170), rng:NextInteger(2, 4))
		-- aim the streak along the pixel-space direction of its position (assumes ~16:9)
		frame.Rotation = math.deg(atan2(sinA * 9, cosA * 16))
		frame.Parent = holder

		-- fade the inner end so the streak looks like it comes out of the distance
		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new(1, 0)
		gradient.Parent = frame

		table.insert(lines, {
			Frame = frame,
			X = 0.5 + cosA * radius,
			Y = 0.5 + sinA * radius,
			OutX = 0.5 + cosA * (radius + 0.07),
			OutY = 0.5 + sinA * (radius + 0.07),
			Alpha = rng:NextNumber(0, 0.25),
		})
	end

	gui.Parent = playerGui
	return holder, lines
end

-- Round button with a cooldown overlay (UIGradient with a hard edge, so it stays circular).
local function makeCircleButton(parent, name, text, diameter, position, accent, onPress)
	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(1, 1)
	button.Size = UDim2.fromOffset(diameter, diameter)
	button.Position = position
	button.BackgroundColor3 = Theme.Colors.Panel
	button.BackgroundTransparency = BUTTON_ALPHA
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = parent
	Theme.Corner(button, UDim.new(0.5, 0))
	local stroke = Theme.Stroke(button, accent, 3, 0.1)

	local scale = Instance.new("UIScale")
	scale.Parent = button

	local overlay = Instance.new("Frame")
	overlay.Name = "Cooldown"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Theme.Colors.Ink
	overlay.BorderSizePixel = 0
	overlay.Visible = false
	overlay.ZIndex = 2
	overlay.Parent = button
	Theme.Corner(overlay, UDim.new(0.5, 0))
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90 -- top (0) -> bottom (1)
	gradient.Parent = overlay

	local label = Theme.Label(text, "Heading", {
		Size = math.floor(diameter * 0.26),
		Props = { Size = UDim2.fromScale(1, 1), ZIndex = 3 },
	})
	label.Parent = button

	local handle = {
		Button = button,
		Stroke = stroke,
		Accent = accent,
		Overlay = overlay,
		Gradient = gradient,
		Label = label,
		LastFrac = nil,
	}

	local lastPress = 0
	button.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1 then
			local now = os.clock()
			tween(scale, 0.07, { Scale = 0.9 })
			if now - lastPress > 0.12 then -- guards against touch + emulated-mouse double events
				lastPress = now
				onPress()
			end
		end
	end)
	button.InputEnded:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1 then
			tween(scale, 0.18, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end
	end)

	return handle
end

-- frac: 0 = hidden, 1 = fully dimmed, in between the dim area drains toward the bottom.
local function setCooldownOverlay(handle, frac)
	local q = math.floor(Util.Clamp(frac, 0, 1) * 40 + 0.5) / 40
	if handle.LastFrac == q then
		return
	end
	handle.LastFrac = q
	if q <= 0 then
		handle.Overlay.Visible = false
		return
	end
	handle.Overlay.Visible = true
	if q >= 1 then
		handle.Gradient.Transparency = NumberSequence.new(0.45)
		return
	end
	local edge = 1 - q -- strictly inside (0, 1) because q is a multiple of 1/40
	handle.Gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(edge, 1),
		NumberSequenceKeypoint.new(math.min(edge + 0.001, 0.9995), 0.45),
		NumberSequenceKeypoint.new(1, 0.45),
	})
end

local function denyFeedback(handle)
	if not handle then
		return
	end
	handle.Button.Rotation = 9
	tween(handle.Button, 0.35, { Rotation = 0 }, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
	handle.Stroke.Color = Theme.Colors.Bad
	tween(handle.Stroke, 0.4, { Color = handle.Accent })
end

local function toggleRun()
	if not ctx or isLocked() then
		return
	end
	if exhausted and not runToggled then
		denyFeedback(ui and ui.mobile and ui.mobile.run)
		return
	end
	runToggled = not runToggled
end

-- Mirrors Roblox's default TouchJump footprint: 70px when min(axis) <= 500, else 120px.
-- jumpRight = distance of the jump button's LEFT edge from the screen's right edge.
-- jumpTop   = distance of the jump button's TOP edge from the screen's bottom edge.
local function layoutMobileControls(m)
	local camera = workspace.CurrentCamera
	local vp = camera and camera.ViewportSize or Vector2.new(1280, 720)
	local small = math.min(vp.X, vp.Y) <= 500
	local jump = small and 70 or 120
	local jumpRight = jump * 1.5 - 10 -- 95 small / 170 large
	local jumpTop = small and (jump + 20) or (jump * 1.75) -- 90 small / 210 large
	-- DASH sits above the jump button; RUN sits to its left. The max() keeps the phone layout
	-- (-175 / -120) and only moves the buttons on big screens (tablets, unfolded foldables).
	m.dash.Button.Position = UDim2.new(1, -30, 1, -math.max(175, jumpTop + 16))
	m.run.Button.Position = UDim2.new(1, -math.max(120, jumpRight + 20), 1, -150)
end

local function buildMobileControls(playerGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "MobileControls"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 4
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- an arc above-left of the default jump button, within thumb reach; the exact offsets depend
	-- on the size of Roblox's jump button, so layoutMobileControls places them below
	local dashButton = makeCircleButton(gui, "DashButton", "DASH", 76, UDim2.new(1, -30, 1, -175), Theme.Colors.Stamina, function()
		tryDash()
	end)
	local runButton = makeCircleButton(gui, "RunButton", "RUN", 64, UDim2.new(1, -120, 1, -150), Theme.Colors.Good, function()
		toggleRun()
	end)

	local controls = {
		Gui = gui,
		dash = dashButton,
		run = runButton,
		locked = nil,
		runOn = nil,
		lowStamina = nil,
	}
	layoutMobileControls(controls)

	-- re-lay out when the viewport changes (rotation, window resize, foldables); the gui is built
	-- once and never destroyed, so the only connection to manage is the one on the current camera
	local cameraConn = nil
	local function bindCamera()
		if cameraConn then
			cameraConn:Disconnect()
			cameraConn = nil
		end
		local camera = workspace.CurrentCamera
		if camera then
			cameraConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				layoutMobileControls(controls)
			end)
		end
		layoutMobileControls(controls)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera)
	bindCamera()

	gui.Parent = playerGui
	return controls
end

-- Called every frame from the character step; only touches properties that changed.
local function updateMobileUi(locked)
	local m = ui and ui.mobile
	if not m then
		return
	end
	setCooldownOverlay(m.dash, MovementController.GetDashCooldownFraction())

	if m.locked ~= locked then
		m.locked = locked
		local alpha = BUTTON_ALPHA
		if locked then
			alpha = BUTTON_ALPHA_LOCKED
		end
		m.dash.Button.BackgroundTransparency = alpha
		m.run.Button.BackgroundTransparency = alpha
		m.runOn = nil -- force the run button to refresh its colours
	end

	if m.runOn ~= runToggled then
		m.runOn = runToggled
		if runToggled then
			tween(m.run.Button, 0.15, { BackgroundColor3 = Theme.Colors.Good:Lerp(Theme.Colors.Panel, 0.5) })
		else
			tween(m.run.Button, 0.15, { BackgroundColor3 = Theme.Colors.Panel })
		end
	end

	local lowStamina = stamina < P.DashStaminaCost
	if m.lowStamina ~= lowStamina then
		m.lowStamina = lowStamina
		if lowStamina then
			m.dash.Label.TextTransparency = 0.5
		else
			m.dash.Label.TextTransparency = 0
		end
	end
end

local function buildGui()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui", 30)
	if not playerGui then
		return
	end
	local built = { flashToken = 0 }
	local okLines, holder, lines = pcall(buildSpeedLines, playerGui)
	if okLines then
		built.holder = holder
		built.lines = lines
	else
		warn("[MovementController] speed lines failed: " .. tostring(holder))
	end
	if UserInputService.TouchEnabled then
		local okMobile, mobile = pcall(buildMobileControls, playerGui)
		if okMobile then
			built.mobile = mobile
		else
			warn("[MovementController] mobile controls failed: " .. tostring(mobile))
		end
	end
	ui = built
	if ctx then
		setMobileVisible(true)
	end
end

----------------------------------------------------------------------
-- Character effects (trail, dust, bursts)
----------------------------------------------------------------------
local function newEmitter(parent, props)
	local emitter = Instance.new("ParticleEmitter")
	for key, value in pairs(props) do
		emitter[key] = value
	end
	emitter.Parent = parent
	return emitter
end

-- Builds everything under the HumanoidRootPart; returns the fx table and a list to destroy.
local function buildCharacterFx(humanoid, root)
	local fx = {}
	local instances = {}

	local feetOffset = 3
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		feetOffset = humanoid.HipHeight + root.Size.Y * 0.5
	end
	feetOffset = Util.Clamp(feetOffset, 2, 5)

	local feet = Instance.new("Attachment")
	feet.Name = "NC_Feet"
	feet.Position = Vector3.new(0, -feetOffset + 0.15, 0)
	feet.Parent = root
	table.insert(instances, feet)

	-- soft footstep dust (toggled while running on the ground)
	fx.dust = newEmitter(feet, {
		Name = "NC_RunDust",
		Texture = TEX_SMOKE,
		Color = ColorSequence.new(Theme.Colors.Cloud, Theme.Colors.CloudShade),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(1, 2.2),
		}),
		Lifetime = NumberRange.new(0.35, 0.65),
		Speed = NumberRange.new(1, 3),
		SpreadAngle = Vector2.new(35, 35),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-45, 45),
		Acceleration = Vector3.new(0, 3, 0),
		EmissionDirection = Enum.NormalId.Top,
		LightEmission = 0.15,
		LockedToPart = false,
		Rate = 20,
		Enabled = false,
	})

	-- bigger puff for landings and the dash take-off (manual :Emit only)
	fx.puff = newEmitter(feet, {
		Name = "NC_Puff",
		Texture = TEX_SMOKE,
		Color = ColorSequence.new(Theme.Colors.Cloud, Theme.Colors.CloudShade),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 3.4),
		}),
		Lifetime = NumberRange.new(0.4, 0.7),
		Speed = NumberRange.new(6, 11),
		SpreadAngle = Vector2.new(80, 80),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
		Drag = 3,
		Acceleration = Vector3.new(0, 2, 0),
		EmissionDirection = Enum.NormalId.Top,
		LightEmission = 0.1,
		LockedToPart = false,
		Rate = 0,
		Enabled = false,
	})

	-- sparkle burst for the dash
	fx.sparks = newEmitter(root, {
		Name = "NC_DashSparks",
		Texture = TEX_SPARKLES,
		Color = ColorSequence.new(Theme.Colors.White, Theme.Colors.Stamina),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.9),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Lifetime = NumberRange.new(0.25, 0.45),
		Speed = NumberRange.new(10, 22),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 4,
		LightEmission = 1,
		LockedToPart = false,
		Rate = 0,
		Enabled = false,
	})
	table.insert(instances, fx.dust)
	table.insert(instances, fx.puff)
	table.insert(instances, fx.sparks)

	-- trail through the torso, only enabled while dashing
	local top = Instance.new("Attachment")
	top.Name = "NC_TrailTop"
	top.Position = Vector3.new(0, 1.2, 0)
	top.Parent = root
	local bottom = Instance.new("Attachment")
	bottom.Name = "NC_TrailBottom"
	bottom.Position = Vector3.new(0, -1.4, 0)
	bottom.Parent = root
	table.insert(instances, top)
	table.insert(instances, bottom)

	local trail = Instance.new("Trail")
	trail.Name = "NC_DashTrail"
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = 0.32
	trail.MinLength = 0.1
	trail.FaceCamera = true
	trail.LightEmission = 0.7
	trail.Color = ColorSequence.new(Theme.Colors.White, Theme.Colors.Stamina)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	trail.Enabled = false
	trail.Parent = root
	fx.trail = trail
	table.insert(instances, trail)

	return fx, instances
end

----------------------------------------------------------------------
-- Dash
----------------------------------------------------------------------
-- Horizontal unit vector: move input if any, else the camera look, else the body facing.
-- Second return value tells whether the player was actually steering.
local function computeDashDirection(humanoid, root)
	local md = humanoid.MoveDirection
	local flat = Vector3.new(md.X, 0, md.Z)
	if flat.Magnitude > MOVE_EPS then
		return flat.Unit, true
	end
	local camera = workspace.CurrentCamera
	if camera then
		local look = camera.CFrame.LookVector
		flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.05 then
			return flat.Unit, false
		end
	end
	local facing = root.CFrame.LookVector
	flat = Vector3.new(facing.X, 0, facing.Z)
	if flat.Magnitude > 0.05 then
		return flat.Unit, false
	end
	return Vector3.new(0, 0, 1), false
end

-- Returns nil when a dash may start, otherwise a short reason string.
local function dashBlockedReason()
	local c = ctx
	if not c then
		return "nochar"
	end
	local humanoid = c.humanoid
	if humanoid.Health <= 0 or humanoid.Sit or humanoid.PlatformStand then
		return "state"
	end
	if isLocked() then
		return "locked"
	end
	if dash then
		return "dashing"
	end
	if os.clock() < cooldownEnd then
		return "cooldown"
	end
	if stamina < P.DashStaminaCost then
		return "stamina"
	end
	return nil
end

-- Stop the dash. Normally the character is handed a sane post-dash speed so it does not keep
-- flying at DashSpeed (the course generator assumes the dash ends at run speed). With halt = true
-- (Downed / frozen by the server) the horizontal velocity is simply cancelled.
local function endDash(halt)
	local d = dash
	if not d then
		return
	end
	dash = nil
	local c = ctx
	if not c then
		return
	end
	local root = c.root
	local humanoid = c.humanoid
	if not root.Parent or humanoid.Health <= 0 then
		return
	end
	local exitSpeed = 0
	if not halt then
		exitSpeed = humanoid.WalkSpeed
		if humanoid.FloorMaterial == Enum.Material.Air then
			exitSpeed = math.max(exitSpeed, P.RunSpeed)
		end
		exitSpeed = math.min(exitSpeed, P.DashSpeed)
	end
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(d.dir.X * exitSpeed, v.Y, d.dir.Z * exitSpeed)
end

local function playDashFx(c)
	local fx = c.fx
	local now = os.clock()
	if fx.trail then
		fx.trail.Enabled = true
		c.trailOffAt = now + P.DashDuration + 0.06
	end
	if fx.puff then
		fx.puff:Emit(8)
	end
	if fx.sparks then
		fx.sparks:Emit(10)
	end
	flashSpeedLines()
end

function tryDash()
	local reason = dashBlockedReason()
	if reason == "cooldown" then
		-- queue a press that arrives just before the cooldown ends so it still feels instant
		local now = os.clock()
		if cooldownEnd - now <= DASH_BUFFER and stamina >= P.DashStaminaCost then
			dashBufferUntil = now + DASH_BUFFER
		end
		return false
	elseif reason == "stamina" then
		denyFeedback(ui and ui.mobile and ui.mobile.dash)
		return false
	elseif reason ~= nil then
		return false
	end

	local c = ctx
	local humanoid = c.humanoid
	local root = c.root
	local now = os.clock()
	local dir, steering = computeDashDirection(humanoid, root)

	stamina = stamina - P.DashStaminaCost
	if stamina <= 0 then
		stamina = 0
		exhausted = true
		runToggled = false
	end
	regenBlockedUntil = now + DASH_REGEN_DELAY
	cooldownEnd = now + P.DashCooldown
	dashBufferUntil = 0
	dash = { dir = dir, startTime = now, endTime = now + P.DashDuration }
	punchStart = now
	mirrorStamina(false)

	-- face the dash when the player was not steering (the humanoid already turns toward input)
	if not steering then
		local pos = root.Position
		root.CFrame = CFrame.new(pos, pos + dir)
	end
	-- apply immediately so the press feels instant; Stepped keeps re-asserting it afterwards
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(dir.X * P.DashSpeed, v.Y, dir.Z * P.DashSpeed)

	playDashFx(c)
	if dashRemote then
		pcall(function()
			dashRemote:FireServer()
		end)
	end
	return true
end

-- Runs just before every physics step while a character is bound.
local function onStepped()
	local d = dash
	if not d then
		return
	end
	local c = ctx
	if not c or not c.root.Parent then
		dash = nil
		return
	end
	if isLocked() then
		endDash(true)
		return
	end
	if os.clock() >= d.endTime then
		endDash(false)
		return
	end
	local root = c.root
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(d.dir.X * P.DashSpeed, v.Y, d.dir.Z * P.DashSpeed)
end

----------------------------------------------------------------------
-- Per-frame update (run, stamina, effects, camera)
----------------------------------------------------------------------
local function dashPunchValue(now)
	local t = now - punchStart
	if t < 0 or t >= PUNCH_TOTAL then
		return 0
	end
	if t < PUNCH_ATTACK then
		return t / PUNCH_ATTACK
	end
	local u = (t - PUNCH_ATTACK) / (PUNCH_TOTAL - PUNCH_ATTACK)
	return 1 - u * u * (3 - 2 * u) -- smoothstep release
end

local function step(dt)
	local c = ctx
	if not c then
		return
	end
	local humanoid = c.humanoid
	local root = c.root
	if not humanoid.Parent or not root.Parent or humanoid.Health <= 0 then
		unbindCharacter()
		return
	end
	local now = os.clock()
	dt = Util.Clamp(dt, 0, 0.1)

	-- 1. Whatever WalkSpeed we did not write ourselves belongs to the server (freeze, revive...).
	local current = humanoid.WalkSpeed
	if lastWritten == nil or math.abs(current - lastWritten) > SPEED_EPS then
		baseSpeed = current
		lastWritten = nil
	end

	-- 2. Lockout: Downed or frozen players cannot run or dash.
	local locked = isLocked()
	if locked then
		if dash then
			endDash(true)
		end
		runToggled = false
		runBlend = 0 -- snap back to the server's speed immediately
		dashBufferUntil = 0
	end

	-- 3. Run + stamina.
	local moving = humanoid.MoveDirection.Magnitude > MOVE_EPS
	local wantsRun = (shiftHeld or runToggled) and not locked
	local running = wantsRun and moving and not exhausted and stamina > 0 and not humanoid.Sit
	if dash then
		running = false
	end
	if running then
		stamina = stamina - P.RunStaminaDrain * dt
		regenBlockedUntil = math.max(regenBlockedUntil, now + RUN_REGEN_DELAY)
		if stamina <= 0 then
			stamina = 0
			exhausted = true
			runToggled = false
			running = false
		end
	elseif now >= regenBlockedUntil then
		stamina = math.min(P.MaxStamina, stamina + P.StaminaRegen * dt)
	end
	if exhausted and stamina >= EXHAUST_RESUME then
		exhausted = false
	end
	mirrorStamina(false)

	-- 4. Smooth run blend (held steady while dashing so the speed does not dip afterwards).
	if not dash then
		local target = 0
		if running then
			target = 1
		end
		local rate = RUN_RAMP_DOWN
		if target > runBlend then
			rate = RUN_RAMP_UP
		end
		runBlend = runBlend + (target - runBlend) * (1 - math.exp(-rate * dt))
		if math.abs(target - runBlend) < 0.005 then
			runBlend = target
		end
	end

	-- 5. Write WalkSpeed: server base speed + run boost. Stop touching it when not running.
	if baseSpeed >= FROZEN_SPEED and runBlend > 0.001 then
		local runTarget = math.max(baseSpeed, P.RunSpeed)
		local speed = baseSpeed + (runTarget - baseSpeed) * runBlend
		humanoid.WalkSpeed = speed
		lastWritten = speed
	elseif lastWritten ~= nil then
		humanoid.WalkSpeed = baseSpeed
		lastWritten = nil
	end

	-- 6. Dash end (Stepped normally does this; this is the safety net) and queued dash.
	if dash and now >= dash.endTime then
		endDash(false)
	end
	if dashBufferUntil > 0 then
		if now >= dashBufferUntil then
			dashBufferUntil = 0
		elseif now >= cooldownEnd and not dash then
			dashBufferUntil = 0
			tryDash()
		end
	end

	-- 7. Effects: trail off, dust, landing puff.
	local fx = c.fx
	if fx.trail and fx.trail.Enabled and not dash and now >= c.trailOffAt then
		fx.trail.Enabled = false
	end
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	local wantDust = grounded and moving and runBlend > 0.5
	if wantDust ~= c.dustOn then
		c.dustOn = wantDust
		fx.dust.Enabled = wantDust
	end
	local vy = root.AssemblyLinearVelocity.Y
	if grounded and not c.wasGrounded and c.lastVy < -30 then
		fx.puff:Emit(Util.Clamp(math.floor(-c.lastVy / 8), 3, 10))
	end
	c.wasGrounded = grounded
	c.lastVy = vy

	-- 8. Camera FOV: widen while running, punch on dash.
	local camera = workspace.CurrentCamera
	if camera then
		local fov = BASE_FOV + RUN_FOV_BOOST * runBlend + DASH_FOV_BOOST * dashPunchValue(now)
		if c.lastFov == nil or math.abs(fov - c.lastFov) > 0.01 then
			camera.FieldOfView = fov
			c.lastFov = fov
		end
	end

	-- 9. Mobile button visuals.
	updateMobileUi(locked)
end

----------------------------------------------------------------------
-- Character lifecycle
----------------------------------------------------------------------
function unbindCharacter()
	bindToken = bindToken + 1 -- cancels any bind that is still waiting for children
	local c = ctx
	if not c then
		return
	end
	ctx = nil -- first, so re-entrant calls (Died + CharacterRemoving) are harmless

	dash = nil
	dashBufferUntil = 0
	runToggled = false
	runBlend = 0

	for _, conn in ipairs(c.conns) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	c.conns = {}

	-- give the server's WalkSpeed back untouched if we had it overridden
	if lastWritten ~= nil then
		pcall(function()
			if c.humanoid.Parent then
				c.humanoid.WalkSpeed = baseSpeed
			end
		end)
	end
	lastWritten = nil

	for _, inst in ipairs(c.instances) do
		pcall(function()
			inst:Destroy()
		end)
	end
	c.instances = {}

	local camera = workspace.CurrentCamera
	if camera and c.lastFov ~= nil and c.lastFov ~= BASE_FOV then
		pcall(function()
			camera.FieldOfView = BASE_FOV
		end)
	end
	setMobileVisible(false)
end

local function bindCharacter(char)
	unbindCharacter()
	local token = bindToken

	local humanoid = char:WaitForChild("Humanoid", 10)
	local root = char:WaitForChild("HumanoidRootPart", 10)
	if token ~= bindToken then
		return -- a newer bind/unbind happened while we waited
	end
	if not humanoid or not root or not humanoid:IsA("Humanoid") or not root:IsA("BasePart") then
		return
	end
	if humanoid.Health <= 0 or not char:IsDescendantOf(game) then
		return
	end

	-- fresh state for this life
	stamina = P.MaxStamina
	exhausted = false
	runToggled = false
	runBlend = 0
	baseSpeed = humanoid.WalkSpeed
	lastWritten = nil
	regenBlockedUntil = 0
	dashBufferUntil = 0
	dash = nil
	mirrorStamina(true)
	applyCameraSettings()

	local fx, instances = buildCharacterFx(humanoid, root)
	local c = {
		char = char,
		humanoid = humanoid,
		root = root,
		conns = {},
		instances = instances,
		fx = fx,
		dustOn = false,
		wasGrounded = true,
		lastVy = 0,
		trailOffAt = 0,
		lastFov = nil,
	}
	ctx = c

	table.insert(c.conns, RunService.Stepped:Connect(onStepped))
	table.insert(c.conns, RunService.RenderStepped:Connect(step))
	table.insert(c.conns, humanoid.Died:Connect(function()
		if ctx == c then
			unbindCharacter()
		end
	end))
	table.insert(c.conns, char.AncestryChanged:Connect(function()
		if ctx == c and not char:IsDescendantOf(game) then
			unbindCharacter()
		end
	end))

	setMobileVisible(true)
end

----------------------------------------------------------------------
-- Input (ContextActionService)
----------------------------------------------------------------------
local function onRunAction(_name, state, input)
	local isToggleKey = input ~= nil and input.KeyCode == Enum.KeyCode.ButtonL3
	if state == Enum.UserInputState.Begin then
		if UserInputService:GetFocusedTextBox() ~= nil then
			return Enum.ContextActionResult.Pass
		end
		if isToggleKey then
			toggleRun()
		else
			shiftHeld = true
		end
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		if not isToggleKey then
			shiftHeld = false
		end
	end
	return Enum.ContextActionResult.Sink
end

local function onDashAction(_name, state)
	if state == Enum.UserInputState.Begin then
		if UserInputService:GetFocusedTextBox() == nil then
			tryDash()
		end
	end
	return Enum.ContextActionResult.Sink
end

local function bindInput()
	-- High priority beats Roblox's shift-lock (Medium), so Shift is ours alone.
	ContextActionService:BindActionAtPriority(
		"NimbusRun",
		onRunAction,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.LeftShift,
		Enum.KeyCode.RightShift,
		Enum.KeyCode.ButtonL3
	)
	ContextActionService:BindActionAtPriority(
		"NimbusDash",
		onDashAction,
		false,
		Enum.ContextActionPriority.Default.Value,
		Enum.KeyCode.Q,
		Enum.KeyCode.ButtonB
	)

	-- never leave Shift "stuck" when focus moves away from the game
	UserInputService.WindowFocusReleased:Connect(function()
		shiftHeld = false
	end)
	UserInputService.TextBoxFocused:Connect(function()
		shiftHeld = false
	end)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function MovementController.GetDashCooldownFraction()
	local remaining = cooldownEnd - os.clock()
	if remaining <= 0 then
		return 0
	end
	return Util.Clamp(remaining / P.DashCooldown, 0, 1)
end

function MovementController.Init()
	if initialized then
		return
	end
	initialized = true
	if not LocalPlayer then
		return
	end

	stamina = P.MaxStamina
	mirrorStamina(true)
	applyCameraSettings()
	bindInput()

	-- Remotes.Get yields until the folder replicates, so never block Init on it
	task.spawn(function()
		local ok, remote = pcall(Remotes.Get, "Dash")
		if ok then
			dashRemote = remote
		else
			warn("[MovementController] Dash remote unavailable: " .. tostring(remote))
		end
	end)
	task.spawn(buildGui)

	LocalPlayer.CharacterAdded:Connect(function(char)
		bindCharacter(char)
	end)
	LocalPlayer.CharacterRemoving:Connect(function()
		unbindCharacter()
	end)
	if LocalPlayer.Character then
		task.spawn(bindCharacter, LocalPlayer.Character)
	end
end

return MovementController
