-- Nimbus Climb client bootstrap (LocalScript).
--
-- Requires the four client controllers and starts each of them. A controller that fails to load or
-- to initialise only logs a warning; the others keep running.
--
-- Each Init() runs in its own thread: controllers wait for remotes and GUIs inside Init, and one
-- slow controller must never delay the rest. Threads are started in the order listed here.

local CONTROLLER_NAMES = {
	"MovementController",
	"HudController",
	"DamageFx",
	"NotifyController",
}

local controllers = script.Parent:WaitForChild("Controllers")

for _, name in ipairs(CONTROLLER_NAMES) do
	local moduleScript = controllers:FindFirstChild(name)
	if not moduleScript then
		warn("[NimbusClimb] missing client controller: " .. name)
	else
		local okRequire, controller = pcall(require, moduleScript)
		if not okRequire then
			warn("[NimbusClimb] " .. name .. " failed to load: " .. tostring(controller))
		elseif type(controller) ~= "table" or type(controller.Init) ~= "function" then
			warn("[NimbusClimb] " .. name .. " has no Init function")
		else
			task.spawn(function()
				local okInit, err = pcall(controller.Init)
				if not okInit then
					warn("[NimbusClimb] " .. name .. ".Init failed: " .. tostring(err))
				end
			end)
		end
	end
end

print("[NimbusClimb] client ready")
