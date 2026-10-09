-- TokenFx: spins and bobs the cloud coins on this client only. The server leaves the coins still when
-- Config.Tokens.ClientAnimated is true (TokenService), so nothing here replicates and it costs the
-- network nothing. The motion matches TokenService's old server-side driver.
-- Plain Lua 5.1-compatible syntax only.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local TokenFx = {}

local NORMAL = { spin = 2.0, bob = 0.45 } -- radians per second / studs
local GOLDEN = { spin = 2.6, bob = 0.6 }
local BOB_SPEED = 2.2 -- radians per second of the up/down sine
local CULL_DISTANCE = 140 -- only coins this close to the camera are posed (other matches are far away)
local CULL_DISTANCE_SQ = CULL_DISTANCE * CULL_DISTANCE

local coins = {} -- coin part -> { base = Vector3, phase = number, spin = number, bob = number }
local started = false

local function add(part)
	if coins[part] or not part:IsA("BasePart") then
		return
	end
	local look = NORMAL
	if CollectionService:HasTag(part, Config.Tags.GoldenToken) then
		look = GOLDEN
	end
	-- the server built the coin at its base position with a random yaw: reuse that yaw as the phase
	local _, yaw = part.CFrame:ToEulerAnglesYXZ()
	coins[part] = { base = part.Position, phase = yaw, spin = look.spin, bob = look.bob }
end

local function step()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local now = os.clock()
	for part, coin in pairs(coins) do
		if part.Parent == nil or part:GetAttribute("Collected") then
			coins[part] = nil -- gone, or being collected: the server's pickup animation takes over
		else
			local d = coin.base - eye
			if d:Dot(d) <= CULL_DISTANCE_SQ then
				local y = coin.base.Y + math.sin(now * BOB_SPEED + coin.phase) * coin.bob
				part.CFrame = CFrame.new(coin.base.X, y, coin.base.Z) * CFrame.Angles(0, now * coin.spin + coin.phase, 0)
			end
		end
	end
end

function TokenFx.Init()
	if started or Config.Tokens.ClientAnimated ~= true then
		return
	end
	started = true
	local tag = Config.Tags.CloudToken
	CollectionService:GetInstanceAddedSignal(tag):Connect(add)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(part)
		coins[part] = nil
	end)
	for _, part in ipairs(CollectionService:GetTagged(tag)) do
		add(part)
	end
	RunService.RenderStepped:Connect(step)
end

return TokenFx
