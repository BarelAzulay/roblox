-- LightingService: owns the sky, atmosphere, post effects, the soft moving sky clouds and the global
-- workspace rules.
--
-- v3 look ("bright, warm afternoon", ARCHITECTURE_V3.md section 6): the player found the v2 world a bit
-- sad. The sun is now higher, brighter and warmer, the shade a little lighter, colours a touch richer,
-- while everything stays readable:
--   * ClockTime ~14.5 with a warm ColorShift_Top: sunlit voxel tops read golden-white, shaded sides cool,
--   * OutdoorAmbient a little higher (no black shadows on the voxel creases),
--   * exposure kept slightly negative so the near-white cloud voxels never blow out,
--   * a light sky-blue atmosphere with a soft peach horizon, gentle glare,
--   * bloom stays subtle (only neon trims and tokens glow), faint sun rays,
--   * real moving sky clouds (workspace.Terrain.Clouds) for depth above the lobby.
-- No asset ids anywhere: the stock sky textures stay, only the celestial bodies are tuned.
-- Lighting.Technology (ShadowMap) cannot be written from a script (plugin security), so it is set by
-- the "Lighting" node in default.project.json; ShadowSoftness and the environment scales below only
-- matter with that technology.
-- Plain Lua 5.1-compatible syntax only. Init() is idempotent.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local LightingService = {}

-- The tuned values live in one table so the whole mood can be adjusted in one place.
local LOOK = {
	Lighting = {
		ClockTime = 14.5, -- early afternoon: a high, friendly sun
		-- A lower latitude lifts the sun's path. At 34 degrees and 14:30 the sun stands roughly 50 degrees
		-- up: voxel tops are well lit, sides still get readable shade and shadows stay short and crisp.
		GeographicLatitude = 34,
		Brightness = 2.0,
		Ambient = Color3.fromRGB(98, 106, 132),
		OutdoorAmbient = Color3.fromRGB(132, 138, 160), -- a little higher than v2: no black creases
		-- Colour shifts are added on top of the lit / shaded sides: a warm sun, a cool sky bounce.
		ColorShift_Top = Color3.fromRGB(66, 50, 26),
		ColorShift_Bottom = Color3.fromRGB(14, 20, 40),
		EnvironmentDiffuseScale = 0.6,
		EnvironmentSpecularScale = 0.35,
		ExposureCompensation = -0.15, -- brighter than v2 (-0.3) yet the cloud whites keep their shades
		GlobalShadows = true,
		ShadowSoftness = 0.3,
		FogStart = 0,
		FogEnd = 100000, -- the Atmosphere does the distance haze instead of classic fog
	},
	Atmosphere = {
		Density = 0.28,
		Offset = 0.25,
		Color = Color3.fromRGB(178, 198, 228), -- light sky-blue air
		Decay = Color3.fromRGB(238, 200, 170), -- soft warm peach horizon
		Glare = 0.25,
		Haze = 1.0,
	},
	Sky = {
		StarCount = 2500,
		CelestialBodiesShown = true,
		SunAngularSize = 16,
		MoonAngularSize = 9,
	},
	Bloom = {
		Enabled = true,
		Intensity = 0.16,
		Size = 18,
		Threshold = 1.6, -- only the brightest accents (neon, tokens) glow
	},
	SunRays = {
		Enabled = true,
		Intensity = 0.06,
		Spread = 0.6,
	},
	ColorCorrection = {
		Enabled = true,
		Brightness = 0,
		Contrast = 0.1,
		Saturation = 0.14, -- a little richer than v2: "more colour in the world", still not neon
		TintColor = Color3.fromRGB(255, 250, 242), -- the faintest warm tint
	},
	-- Depth of field is kept switched off (it blurs the course edges players need to read).
	DepthOfField = {
		Enabled = false,
		FarIntensity = 0.05,
		NearIntensity = 0,
		FocusDistance = 200,
		InFocusRadius = 160,
	},
	-- Real moving sky clouds (workspace.Terrain.Clouds): soft, half cover, never a grey overcast.
	Clouds = {
		Enabled = true,
		Cover = 0.5,
		Density = 0.6,
		Color = Color3.fromRGB(240, 244, 252),
	},
}

LightingService.Look = LOOK

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

-- Reuse the first child of `className` under `parent`, otherwise create one. This makes Init()
-- idempotent and keeps a place that already ships a Sky/Atmosphere from doubling up.
local function ensure(parent, className, name)
	local inst = parent:FindFirstChildOfClass(className)
	if not inst then
		inst = Instance.new(className)
		inst.Name = name
		inst.Parent = parent
	end
	return inst
end

-- workspace.Terrain.Clouds (skipped quietly when the engine has no Terrain or no Clouds class).
local function applyClouds()
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if not terrain then
		return
	end
	local ok, err = pcall(function()
		setProps(ensure(terrain, "Clouds", "NimbusClouds"), LOOK.Clouds)
	end)
	if not ok then
		warn("[LightingService] sky clouds skipped: " .. tostring(err))
	end
end

-- Global physics / world rules. StreamingEnabled is deliberately left alone (false).
function LightingService.ApplyWorldRules()
	setProps(Workspace, {
		Gravity = Config.Physics.Gravity,
		FallenPartsDestroyHeight = -2000, -- far below the lobby kill plane and every course kill plane
	})
	setProps(Players, {
		CharacterAutoLoads = true,
	})
end

function LightingService.Init()
	setProps(Lighting, LOOK.Lighting)

	setProps(ensure(Lighting, "Atmosphere", "NimbusAtmosphere"), LOOK.Atmosphere)
	setProps(ensure(Lighting, "Sky", "NimbusSky"), LOOK.Sky)
	setProps(ensure(Lighting, "BloomEffect", "NimbusBloom"), LOOK.Bloom)
	setProps(ensure(Lighting, "SunRaysEffect", "NimbusSunRays"), LOOK.SunRays)
	setProps(ensure(Lighting, "ColorCorrectionEffect", "NimbusColor"), LOOK.ColorCorrection)
	setProps(ensure(Lighting, "DepthOfFieldEffect", "NimbusDepthOfField"), LOOK.DepthOfField)
	applyClouds()

	LightingService.ApplyWorldRules()
end

return LightingService
