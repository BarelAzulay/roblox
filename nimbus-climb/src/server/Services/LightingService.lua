-- LightingService: owns the sky, atmosphere, post effects and global workspace rules.
--
-- v2 look ("late-afternoon calm"): the old golden-hour setup was blown out (bright ambient,
-- strong bloom, strong colour shifts). Everything here is tuned the other way round so that
-- cloud platforms, hazards and UI-in-the-world stay readable:
--   * lower sun brightness and ambient, slightly negative exposure,
--   * a blue-grey atmosphere with a soft peach horizon (no white-out haze),
--   * bloom only on genuinely bright accents (neon trims, tokens), tiny sun rays,
--   * a little extra contrast, a hint of saturation, a cool tint, depth of field off.
-- No asset ids anywhere: the stock sky textures stay, only the celestial bodies are tuned.
-- Lighting.Technology (ShadowMap) cannot be written from a script (plugin security), so it is set
-- by the "Lighting" node in default.project.json; ShadowSoftness and the environment scales
-- below only matter with that technology.
-- Plain Lua 5.1-compatible syntax only.

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
		ClockTime = 15.2, -- mid-late afternoon: the sun is still up but already soft
		-- A HIGHER latitude lowers the sun's path (a lower one pushes it towards the zenith). With
		-- ClockTime 15.2 the sun stands about 36 degrees up at latitude 28, 30 at Roblox's default
		-- (41.7) and 27 at 48: lower sun = longer, clearer shadows and ~10% less direct light on the
		-- platform tops than the default, which is what the "too bright" fix wants.
		GeographicLatitude = 48,
		Brightness = 1.5,
		Ambient = Color3.fromRGB(84, 96, 128),
		OutdoorAmbient = Color3.fromRGB(108, 120, 152),
		-- Colour shifts are added on top of the lit / shaded sides. Keep them very dim: the old
		-- values (hundreds of points) were a big part of the "way too bright" problem.
		ColorShift_Top = Color3.fromRGB(34, 26, 16),
		ColorShift_Bottom = Color3.fromRGB(8, 14, 30),
		EnvironmentDiffuseScale = 0.5,
		EnvironmentSpecularScale = 0.4,
		ExposureCompensation = -0.3,
		GlobalShadows = true,
		ShadowSoftness = 0.25,
		FogStart = 0,
		FogEnd = 100000, -- the Atmosphere does the distance haze instead of classic fog
	},
	Atmosphere = {
		Density = 0.3,
		Offset = 0.25,
		Color = Color3.fromRGB(158, 172, 200), -- blue-grey air
		Decay = Color3.fromRGB(226, 182, 160), -- soft peach horizon
		Glare = 0.2,
		Haze = 1.2,
	},
	Sky = {
		StarCount = 2500,
		CelestialBodiesShown = true,
		SunAngularSize = 14,
		MoonAngularSize = 9,
	},
	Bloom = {
		Enabled = true,
		Intensity = 0.12,
		Size = 16,
		Threshold = 1.8, -- only the brightest accents (neon, tokens) glow
	},
	SunRays = {
		Enabled = true,
		Intensity = 0.04,
		Spread = 0.6,
	},
	ColorCorrection = {
		Enabled = true,
		Brightness = -0.03,
		Contrast = 0.14,
		Saturation = 0.08,
		TintColor = Color3.fromRGB(232, 240, 255), -- soft cool tint
	},
	-- Depth of field is kept switched off (it blurs the course edges players need to read).
	DepthOfField = {
		Enabled = false,
		FarIntensity = 0.05,
		NearIntensity = 0,
		FocusDistance = 200,
		InFocusRadius = 160,
	},
}

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

	setProps(ensure("Atmosphere", "NimbusAtmosphere"), LOOK.Atmosphere)
	setProps(ensure("Sky", "NimbusSky"), LOOK.Sky)
	setProps(ensure("BloomEffect", "NimbusBloom"), LOOK.Bloom)
	setProps(ensure("SunRaysEffect", "NimbusSunRays"), LOOK.SunRays)
	setProps(ensure("ColorCorrectionEffect", "NimbusColor"), LOOK.ColorCorrection)
	setProps(ensure("DepthOfFieldEffect", "NimbusDepthOfField"), LOOK.DepthOfField)

	LightingService.ApplyWorldRules()
end

return LightingService
