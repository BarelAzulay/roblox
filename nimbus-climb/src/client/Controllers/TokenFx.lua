-- TokenFx: spins and bobs the cloud coins on this client only. The server leaves the coins still when
-- Config.Tokens.ClientAnimated is true (TokenService), so nothing here replicates and it costs the
-- network nothing. The motion matches TokenService's old server-side driver.
-- v3: the coin is a voxel coin (TokenService): its root block is posed here and every other block is welded
-- to it, so the whole coin spins; the soft "Halo" sphere is an anchored, unwelded child of the root that this
-- controller bobs along with the coin (it never needs to spin).
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

local HALO_RETRY = 0.5 -- seconds between looks for a halo that has not replicated yet

-- coin part -> { base, phase, spin, bob, halo = BasePart|nil, haloOffset = Vector3, nextHaloLook = number }
local coins = {}
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
	coins[part] = { base = part.Position, phase = yaw, spin = look.spin, bob = look.bob, nextHaloLook = 0 }
end

-- The glowing "Halo" ball is an anchored child of the coin (TokenService builds it unwelded so it never has to
-- spin). It must still bob with the coin, so remember where it sits relative to the coin's base position.
-- Children can replicate after the tag does, so look again a few times a second until it shows up.
local function findHalo(part, coin, now)
	if now < coin.nextHaloLook then
		return
	end
	coin.nextHaloLook = now + HALO_RETRY
	local halo = part:FindFirstChild("Halo")
	if halo and halo:IsA("BasePart") then
		coin.halo = halo
		coin.haloOffset = halo.Position - coin.base
	end
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
				local lift = math.sin(now * BOB_SPEED + coin.phase) * coin.bob
				part.CFrame = CFrame.new(coin.base.X, coin.base.Y + lift, coin.base.Z) * CFrame.Angles(0, now * coin.spin + coin.phase, 0)
				local halo = coin.halo
				if halo == nil or halo.Parent ~= part then
					coin.halo = nil
					findHalo(part, coin, now)
					halo = coin.halo
				end
				if halo then
					local o = coin.haloOffset
					halo.CFrame = CFrame.new(coin.base.X + o.X, coin.base.Y + o.Y + lift, coin.base.Z + o.Z)
				end
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
