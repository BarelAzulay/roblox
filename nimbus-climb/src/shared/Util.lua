-- Util: small helpers used on both server and client. Plain Lua 5.1-compatible syntax only.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Util = {}

-- Instance.new + props + children in one call.
function Util.Create(className, props, children)
	local inst = Instance.new(className)
	if props then
		for key, value in pairs(props) do
			if key ~= "Parent" then
				inst[key] = value
			end
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	if props and props.Parent then
		inst.Parent = props.Parent -- parent last: one replication step
	end
	return inst
end

-- Minimal pure-Lua signal (no BindableEvent) so game logic is testable outside Roblox.
-- local s = Util.Signal(); local c = s:Connect(fn); s:Fire(...); c:Disconnect()
function Util.Signal()
	local signal = { _handlers = {} }
	function signal:Connect(fn)
		local handler = { fn = fn, connected = true }
		table.insert(self._handlers, handler)
		return {
			Connected = true,
			Disconnect = function(conn)
				conn.Connected = false
				handler.connected = false
			end,
		}
	end
	function signal:Fire(...)
		local snapshot = {}
		for i, h in ipairs(self._handlers) do
			snapshot[i] = h
		end
		local alive = {}
		for _, h in ipairs(self._handlers) do
			if h.connected then
				table.insert(alive, h)
			end
		end
		self._handlers = alive
		for _, h in ipairs(snapshot) do
			if h.connected then
				task.spawn(h.fn, ...)
			end
		end
	end
	function signal:Destroy()
		for _, h in ipairs(self._handlers) do
			h.connected = false
		end
		self._handlers = {}
	end
	return signal
end

function Util.Clamp(n, lo, hi)
	if n < lo then
		return lo
	elseif n > hi then
		return hi
	end
	return n
end

function Util.Lerp(a, b, t)
	return a + (b - a) * t
end

function Util.Round(n, decimals)
	local m = 10 ^ (decimals or 0)
	return math.floor(n * m + 0.5) / m
end

-- 125 -> "2:05"
function Util.FormatTime(seconds)
	seconds = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- 12345 -> "12,345"
function Util.Commas(n)
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return out
end

function Util.GetCharacter(player)
	return player and player.Character
end

function Util.GetHumanoid(player)
	local char = player and player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

function Util.GetRoot(player)
	local char = player and player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Part touched by a character -> that character's Player (or nil).
function Util.PlayerFromPart(part)
	if not part then
		return nil
	end
	local model = part:FindFirstAncestorOfClass("Model")
	if not model then
		return nil
	end
	return Players:GetPlayerFromCharacter(model)
end

function Util.Tween(instance, seconds, goal, style, direction)
	local info = TweenInfo.new(
		seconds,
		style or Enum.EasingStyle.Quad,
		direction or Enum.EasingDirection.Out
	)
	local tween = TweenService:Create(instance, info, goal)
	tween:Play()
	return tween
end

-- Deterministic RNG wrapper. rng:Float(a,b) rng:Int(a,b) rng:Chance(p) rng:Pick(list)
function Util.NewRng(seed)
	local random = Random.new(seed)
	local rng = {}
	function rng:Float(a, b)
		return random:NextNumber(a, b)
	end
	function rng:Int(a, b)
		return random:NextInteger(a, b)
	end
	function rng:Chance(p)
		return random:NextNumber() < p
	end
	function rng:Pick(list)
		return list[random:NextInteger(1, #list)]
	end
	return rng
end

return Util
