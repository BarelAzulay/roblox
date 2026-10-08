-- LightingService: owns the sky, atmosphere and global workspace settings.
-- Golden-hour candy sky: warm sun, lavender haze, soft bloom. No asset ids anywhere.
-- Plain Lua 5.1-compatible syntax only.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local LightingService = {}

-- Assign every property in `props` to `inst`; a property that does not exist (or is not
-- scriptable on this engine version) only produces a warning instead of breaking boot.
local function setProps(inst, props)
	for key, value in pairs(props) do
		local ok, err = pcall(function()
			inst[key] = value
		end)
		if not ok then
			warn("[LightingService] could not set " .. inst.ClassName .. "." .. tostring(key) .. ": " .. tostring(err))
		end
	end
end

-- Reuse the first child of `className` under Lighting, otherwise create one. This makes
-- Init() idempotent and keeps a place that already ships a Sky/Atmosphere from doubling up.
local function ensure(className, name)
	local inst = Lighting:FindFirstChildOfClass(className)
	if not inst then
		inst = Instance.new(className)
		inst.Name = name
		inst.Parent = Lighting
	end
	return inst
end

function LightingService.Init()
	-- Core lighting: golden hour with a pink/blue split ambient.
	setProps(Lighting, {
		ClockTime = 17.5,
		GeographicLatitude = 15,
		Brightness = 2.3,
		Ambient = Color3.fromRGB(128, 112, 150),
		OutdoorAmbient = Color3.fromRGB(152, 142, 188),
		ColorShift_Top = Color3.fromRGB(255, 208, 172),
		ColorShift_Bottom = Color3.fromRGB(150, 170, 255),
		EnvironmentDiffuseScale = 0.7,
		EnvironmentSpecularScale = 0.45,
		ExposureCompensation = 0.1,
		GlobalShadows = true,
		ShadowSoftness = 0.4,
		FogStart = 0,
		FogEnd = 100000, -- the Atmosphere does the distance haze instead
	})

	-- Atmosphere: lavender air that fades into a pink horizon.
	local atmosphere = ensure("Atmosphere", "NimbusAtmosphere")
	setProps(atmosphere, {
		Density = 0.3,
		Offset = 0.22,
		Color = Color3.fromRGB(214, 198, 255),
		Decay = Color3.fromRGB(255, 166, 184),
		Glare = 0.45,
		Haze = 1.5,
	})

	-- Sky: keep the stock skybox textures (no asset ids), only tune the celestial bodies.
	local sky = ensure("Sky", "NimbusSky")
	setProps(sky, {
		StarCount = 3000,
		CelestialBodiesShown = true,
		SunAngularSize = 20,
		MoonAngularSize = 11,
	})

	-- Post effects, all kept gentle so the pastel clouds stay readable.
	local bloom = ensure("BloomEffect", "NimbusBloom")
	setProps(bloom, {
		Enabled = true,
		Intensity = 0.5,
		Size = 30,
		Threshold = 0.95,
	})

	local sunRays = ensure("SunRaysEffect", "NimbusSunRays")
	setProps(sunRays, {
		Enabled = true,
		Intensity = 0.16,
		Spread = 0.85,
	})

	local colorCorrection = ensure("ColorCorrectionEffect", "NimbusColor")
	setProps(colorCorrection, {
		Enabled = true,
		Brightness = 0.02,
		Contrast = 0.1,
		Saturation = 0.18,
		TintColor = Color3.fromRGB(255, 246, 240),
	})

	-- Very subtle far blur: distant clouds soften, everything near the player stays sharp.
	local dof = ensure("DepthOfFieldEffect", "NimbusDepthOfField")
	setProps(dof, {
		Enabled = true,
		FarIntensity = 0.15,
		NearIntensity = 0,
		FocusDistance = 120,
		InFocusRadius = 90,
	})

	-- Global physics / world rules. StreamingEnabled is deliberately left alone (false).
	setProps(Workspace, {
		Gravity = Config.Physics.Gravity,
		FallenPartsDestroyHeight = -2000,
	})
	setProps(Players, {
		CharacterAutoLoads = true,
	})
end

return LightingService
