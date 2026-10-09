-- Nimbus Climb client bootstrap (LocalScript).
--
-- 1. State.Init() (the client mirror of the saved profile: pets, items, stats) starts first.
-- 2. Then every client controller is required and initialised, in the order listed below.
--
-- Each step runs in its own thread inside pcall: controllers wait for remotes and GUIs inside Init, and one
-- slow, broken or missing controller must never delay or take down the others. A failure only logs a
-- warning. Threads are started in the order listed here, and task.spawn runs a new thread immediately until
-- it first yields, so State.Init() has already registered itself before the first controller starts.
-- Plain Lua 5.1-compatible syntax only.

local CONTROLLER_NAMES = {
	"MovementController",
	"HudController",
	"DamageFx",
	"NotifyController",
	"MenuController",
	"HotbarController",
	"PetController",
	"TokenFx",
	-- v3 (ARCHITECTURE_V3.md)
	"SkyDragonController",
	"IndexController",
	"NpcController",
	"TutorialController",
}

local TAG = "[NimbusClimb] "

local client = script.Parent

-- 1. State
task.spawn(function()
	local okRequire, State = pcall(function()
		return require(client:WaitForChild("State", 30))
	end)
	if not okRequire then
		warn(TAG .. "State failed to load: " .. tostring(State))
		return
	end
	if type(State) ~= "table" or type(State.Init) ~= "function" then
		warn(TAG .. "State has no Init function")
		return
	end
	local okInit, err = pcall(State.Init)
	if not okInit then
		warn(TAG .. "State.Init failed: " .. tostring(err))
	end
end)

-- 2. Controllers
local controllers = client:WaitForChild("Controllers")

for _, name in ipairs(CONTROLLER_NAMES) do
	task.spawn(function()
		local moduleScript = controllers:FindFirstChild(name)
		if not moduleScript then
			warn(TAG .. "missing client controller: " .. name)
			return
		end
		local okRequire, controller = pcall(require, moduleScript)
		if not okRequire then
			warn(TAG .. name .. " failed to load: " .. tostring(controller))
			return
		end
		if type(controller) ~= "table" or type(controller.Init) ~= "function" then
			warn(TAG .. name .. " has no Init function")
			return
		end
		local okInit, err = pcall(controller.Init)
		if not okInit then
			warn(TAG .. name .. ".Init failed: " .. tostring(err))
		end
	end)
end

print(TAG .. "client ready")
