-- Remotes: one place that creates (server) / fetches (client) every RemoteEvent.
-- Remotes.Get("Notify") works on both sides. Names come from Config.Remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

local Remotes = {}

local folder

local function getFolder()
	if folder then
		return folder
	end
	if RunService:IsServer() then
		folder = ReplicatedStorage:FindFirstChild("Remotes")
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = "Remotes"
			folder.Parent = ReplicatedStorage
		end
	else
		folder = ReplicatedStorage:WaitForChild("Remotes")
	end
	return folder
end

-- Server: call once at boot to create every remote before clients ask for them.
function Remotes.Init()
	assert(RunService:IsServer(), "Remotes.Init is server-only")
	local f = getFolder()
	for _, name in ipairs(Config.Remotes) do
		if not f:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = f
		end
	end
end

function Remotes.Get(name)
	local f = getFolder()
	if RunService:IsServer() then
		local remote = f:FindFirstChild(name)
		assert(remote, "Unknown remote (did you call Remotes.Init?): " .. tostring(name))
		return remote
	end
	return f:WaitForChild(name)
end

return Remotes
