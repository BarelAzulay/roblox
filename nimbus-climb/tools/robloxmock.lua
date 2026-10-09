-- robloxmock.lua
--
-- A Roblox runtime mock for plain Lua (LuaJIT / Lua 5.1-5.5, e.g. through `lupa`). It is meant to run
-- the real game modules unmodified inside tools/smoke.py:
--
--   * Instances with class defaults, typed property checks, hierarchy events, attributes, tags,
--     Clone/Destroy semantics (a destroyed instance's Parent is locked, connections are cut, ...).
--   * Vector3 / CFrame / Color3 / UDim2 / ... with Roblox arithmetic, Enum proxies, Random (deterministic).
--   * A fake clock: task.wait / task.delay / task.defer / Heartbeat are driven by Mock.Step/Mock.Advance.
--   * Services: Players, Workspace (queries), RunService, TweenService, CollectionService, DataStore,
--     UserInputService, ContextActionService, ... and fake players with characters/humanoids.
--
-- It deliberately behaves like Roblox where Roblox is strict (Instance.new with a bad class errors,
-- wrong property types error, a destroyed Parent is locked, FireServer on the server errors ...) and is
-- permissive where only mock coverage is missing (unknown members are recorded in Mock.Diagnostics).
--
-- Usage (see smoke.py):  local Mock = dofile("tools/robloxmock.lua"); Mock.Configure{...}; Mock.SetContext("server")
--
-- Plain Lua 5.1 syntax only: this file must load on LuaJIT as well as on Lua 5.5 (tools/syntax.py).
--
-- NOTE for editors: a Lua function may hold at most 200 local variables and the main chunk of this file is close
-- to 170. New helpers that are only used inside one section belong in that section's `do ... end` block, and
-- datatype constructors are plain globals (Vector3 = {}) instead of locals for the same reason.

local Mock = {}

local rawtype = type
local rawget, rawset, rawequal = rawget, rawset, rawequal
local getmetatable, setmetatable = getmetatable, setmetatable
local select, pairs, ipairs, next, pcall, xpcall, error = select, pairs, ipairs, next, pcall, xpcall, error
local tostring, tonumber = tostring, tonumber
local floor, ceil, abs, sqrt, huge = math.floor, math.ceil, math.abs, math.sqrt, math.huge
local mmin, mmax, sin, cos, acos, asin = math.min, math.max, math.sin, math.cos, math.acos, math.asin
local atan2 = math.atan2 or function(y, x)
	return math.atan(y, x)
end
local realClock = os.clock
local realTime = os.time
local realDate = os.date
local unpack = table.unpack or unpack
local sformat = string.format
local tinsert, tremove, tconcat, tsort = table.insert, table.remove, table.concat, table.sort

Mock.RealClock = os.clock

Mock.Options = {
	StepSize = 1 / 30, -- seconds of fake time per Mock.Step
	SliceLimit = 30, -- real seconds one thread may run without yielding before it is aborted
	Watchdog = true, -- install debug hooks that abort runaway loops
	Echo = false, -- print() / warn() / script errors to stdout as they happen
	StrictMembers = false, -- unknown Instance members raise errors instead of being recorded
	Studio = true, -- RunService:IsStudio()
}

Mock.Errors = {} -- uncaught script errors: { msg=, trace=, time= }
Mock.Output = {} -- print / warn lines: { kind="print"|"warn", text=, time= }
Mock.Diagnostics = {} -- mock-level findings (unknown members, deprecated use ...): { kind=, key=, msg=, where=, count= }
local diagIndex = {}

-- Lua 5.2+ compatibility so the same file also runs on a non-LuaJIT engine.
table.unpack = table.unpack or unpack
_G.unpack = _G.unpack or table.unpack
local function pack(...)
	return { n = select("#", ...), ... }
end
if not table.pack then
	table.pack = pack
end
if not table.move then
	function table.move(a1, f, e, t, a2)
		a2 = a2 or a1
		if t > f then
			for i = e - f, 0, -1 do
				a2[t + i] = a1[f + i]
			end
		else
			for i = 0, e - f do
				a2[t + i] = a1[f + i]
			end
		end
		return a2
	end
end

local function compile(src, chunkname, env)
	if setfenv then
		local fn, err = loadstring(src, chunkname)
		if not fn then
			return nil, err
		end
		setfenv(fn, env)
		return fn
	end
	return load(src, chunkname, "t", env)
end

-- Where in the *game* code are we? (first stack frame outside this file)
local function callerLocation()
	for level = 2, 14 do
		local info = debug.getinfo(level, "Sl")
		if not info then
			break
		end
		local src = info.short_src or info.source or "?"
		if not src:find("robloxmock", 1, true) and not src:find("[C]", 1, true) and info.currentline and info.currentline > 0 then
			return src .. ":" .. info.currentline
		end
	end
	return "?"
end

local function diag(kind, key, msg)
	local id = kind .. "|" .. key
	local entry = diagIndex[id]
	if entry then
		entry.count = entry.count + 1
		return entry
	end
	entry = { kind = kind, key = key, msg = msg or key, where = callerLocation(), count = 1 }
	diagIndex[id] = entry
	Mock.Diagnostics[#Mock.Diagnostics + 1] = entry
	return entry
end
Mock.Diag = diag

----------------------------------------------------------------------------------------------------
-- Fake clock + scheduler (task library)
----------------------------------------------------------------------------------------------------
local EPOCH = 1767312000 -- 2026-01-02T00:00:00Z
local Clock = { now = 0, frame = 0 }
Mock.Clock = Clock

os.clock = function()
	return Clock.now
end
os.time = function(t)
	if t then
		return realTime(t)
	end
	return floor(EPOCH + Clock.now)
end
os.date = function(fmt, t)
	return realDate(fmt, t or os.time())
end
function tick()
	return EPOCH + Clock.now
end
function time()
	return Clock.now
end
elapsedTime = time

local Sched = { current = nil, sliceStart = 0, seq = 0, live = 0 }
local heap, heapN = {}, 0
local byThread = setmetatable({}, { __mode = "k" }) -- thread -> its pending heap entry

local function less(a, b)
	return a.t < b.t or (a.t == b.t and a.seq < b.seq)
end
local function heapPush(e)
	heapN = heapN + 1
	local i = heapN
	heap[i] = e
	while i > 1 do
		local p = floor(i / 2)
		if less(heap[i], heap[p]) then
			heap[i], heap[p] = heap[p], heap[i]
			i = p
		else
			break
		end
	end
end
local function heapPop()
	local top = heap[1]
	heap[1] = heap[heapN]
	heap[heapN] = nil
	heapN = heapN - 1
	local i = 1
	while true do
		local l, r, s = i * 2, i * 2 + 1, i
		if l <= heapN and less(heap[l], heap[s]) then
			s = l
		end
		if r <= heapN and less(heap[r], heap[s]) then
			s = r
		end
		if s == i then
			break
		end
		heap[i], heap[s] = heap[s], heap[i]
		i = s
	end
	return top
end

local function reportError(err, label)
	local msg, trace
	if rawtype(err) == "table" and err.msg then
		msg, trace = err.msg, err.trace
	else
		msg, trace = tostring(err), nil
	end
	local rec = { msg = msg, trace = trace or debug.traceback("", 2), time = Clock.now, label = label }
	Mock.Errors[#Mock.Errors + 1] = rec
	Mock.Output[#Mock.Output + 1] = { kind = "error", text = msg, time = Clock.now }
	if Mock.Options.Echo then
		io.stderr:write("[script error] " .. msg .. "\n")
	end
end
Mock.ReportError = reportError

local function errHandler(e)
	local text = rawtype(e) == "string" and e or tostring(e)
	return { msg = text, trace = debug.traceback(text, 2) }
end

local function watchdog()
	local now = realClock()
	if Mock.Deadline and now > Mock.Deadline then
		Mock.Deadline = nil
		error("mock deadline exceeded (test took too long)", 2)
	end
	-- Only a thread the fake scheduler is running can "forget to yield". (LuaJIT hooks are global, so this
	-- function also fires on the main thread that drives the scenarios: a scenario that crunches numbers for a
	-- minute without ever resuming a game thread is not a runaway game script. Mock.Deadline covers that case.)
	if Sched.current ~= nil and now - Sched.sliceStart > Mock.Options.SliceLimit then
		Sched.sliceStart = now
		error("script exhausted its execution budget (endless loop without task.wait?)", 2)
	end
end

local function newThread(fn)
	if rawtype(fn) ~= "function" then
		error("Argument 1 missing or nil", 3)
	end
	local co = coroutine.create(function(...)
		local args = pack(...)
		local ok, err = xpcall(function()
			return fn(unpack(args, 1, args.n))
		end, errHandler)
		if not ok then
			reportError(err, "thread")
		end
	end)
	if Mock.Options.Watchdog and debug.sethook then
		pcall(debug.sethook, co, watchdog, "", 200000)
	end
	return co
end

local function resume(co, ...)
	if coroutine.status(co) ~= "suspended" then
		return false
	end
	local prev = Sched.current
	Sched.current = co
	Sched.sliceStart = realClock()
	local ok, err = coroutine.resume(co, ...)
	Sched.current = prev
	if not ok then
		reportError(err, "resume")
	end
	return ok
end

local function schedule(co, t, extra)
	Sched.seq = Sched.seq + 1
	local e = { t = t, seq = Sched.seq, co = co, frame = Clock.frame, startedAt = Clock.now, extra = extra }
	byThread[co] = e
	Sched.live = Sched.live + 1
	heapPush(e)
	return e
end

local function isMainThread()
	local co, ismain = coroutine.running()
	return co == nil or ismain == true
end

local task = {}

function task.spawn(target, ...)
	if rawtype(target) == "thread" then
		resume(target, ...)
		return target
	end
	local co = newThread(target)
	resume(co, ...)
	return co
end

function task.defer(target, ...)
	local co = rawtype(target) == "thread" and target or newThread(target)
	local args = pack(...)
	-- runs at the next scheduler pass (same frame if we are inside Mock.Step, else the next step)
	local e = schedule(co, Clock.now)
	e.frame = Clock.frame - 1
	e.args = args
	return co
end

function task.wait(t)
	t = tonumber(t) or 0
	if t < 0 then
		t = 0
	end
	if isMainThread() then
		Mock.Advance(mmax(t, Mock.Options.StepSize))
		return t
	end
	local co = coroutine.running()
	local start = Clock.now
	schedule(co, start + t)
	coroutine.yield()
	return Clock.now - start
end

function task.delay(t, fn, ...)
	local args = pack(...)
	local co = newThread(function()
		task.wait(t)
		return fn(unpack(args, 1, args.n))
	end)
	resume(co)
	return co
end

function task.cancel(co)
	local e = byThread[co]
	if e then
		e.cancelled = true
		byThread[co] = nil
		Sched.live = Sched.live - 1
	end
	if rawtype(co) == "thread" and coroutine.status(co) == "suspended" then
		-- never resumed again: drop it from every waiting list by marking it dead
		Mock._cancelled = Mock._cancelled or setmetatable({}, { __mode = "k" })
		Mock._cancelled[co] = true
	end
end

function task.synchronize() end
function task.desynchronize() end

-- Run every due scheduler entry (called by Step; also usable after driver-initiated events).
local function runDue()
	local postponed
	local guard = 0
	while heapN > 0 and heap[1].t <= Clock.now do
		local e = heapPop()
		if e.cancelled then
			-- skip
		elseif e.frame >= Clock.frame then
			-- scheduled during this very frame (task.wait(0) loops): run next frame
			postponed = postponed or {}
			postponed[#postponed + 1] = e
		else
			if byThread[e.co] == e then
				byThread[e.co] = nil
				Sched.live = Sched.live - 1
			end
			guard = guard + 1
			if guard > 200000 then
				error("scheduler runaway (more than 200000 wakeups in one frame)")
			end
			if not (Mock._cancelled and Mock._cancelled[e.co]) then
				if e.args then
					resume(e.co, unpack(e.args, 1, e.args.n))
				else
					resume(e.co, Clock.now - e.startedAt)
				end
			end
		end
	end
	if postponed then
		for _, e in ipairs(postponed) do
			heapPush(e)
		end
	end
end

function Mock.PendingTasks()
	return Sched.live
end

function Mock.Flush()
	Clock.frame = Clock.frame + 1
	runDue()
end

-- Frame hooks (RunService signals are registered by the service section below)
Mock._frameHooks = {}

function Mock.Step(dt)
	dt = dt or Mock.Options.StepSize
	Clock.now = Clock.now + dt
	Clock.frame = Clock.frame + 1
	local hooks = Mock._frameHooks
	for i = 1, #hooks do
		hooks[i](dt)
	end
	runDue()
	if Mock._afterStep then
		Mock._afterStep(dt)
	end
end

function Mock.Advance(seconds, dt)
	dt = dt or Mock.Options.StepSize
	local steps = ceil(seconds / dt - 1e-9)
	for _ = 1, steps do
		Mock.Step(dt)
	end
end

-- Steps until pred() is true; returns true if it became true within maxSeconds of fake time.
function Mock.AdvanceUntil(pred, maxSeconds, dt)
	dt = dt or Mock.Options.StepSize
	local steps = ceil((maxSeconds or 60) / dt)
	if pred() then
		return true
	end
	for _ = 1, steps do
		Mock.Step(dt)
		if pred() then
			return true
		end
	end
	return false
end

if debug.sethook then
	function Mock.EnableMainWatchdog()
		pcall(debug.sethook, function()
			if Mock.Deadline and realClock() > Mock.Deadline then
				Mock.Deadline = nil
				error("mock deadline exceeded (test took too long)", 2)
			end
		end, "", 500000)
	end
end

----------------------------------------------------------------------------------------------------
-- print / warn / error plumbing
----------------------------------------------------------------------------------------------------
local function joinArgs(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	return tconcat(parts, " ")
end

function print(...)
	local text = joinArgs(...)
	Mock.Output[#Mock.Output + 1] = { kind = "print", text = text, time = Clock.now }
	if Mock.Options.Echo then
		io.stdout:write(text .. "\n")
	end
end

function warn(...)
	local text = joinArgs(...)
	Mock.Output[#Mock.Output + 1] = { kind = "warn", text = text, time = Clock.now, where = callerLocation() }
	if Mock.Options.Echo then
		io.stderr:write("[warn] " .. text .. "\n")
	end
end

-- Deprecated globals still exist in Roblox; they work but are recorded (check.mjs flags them statically).
function wait(t)
	diag("deprecated", "wait()", "global wait() is deprecated, use task.wait")
	return task.wait(t)
end
function spawn(fn)
	diag("deprecated", "spawn()", "global spawn() is deprecated, use task.spawn")
	return task.delay(0, fn)
end
function delay(t, fn)
	diag("deprecated", "delay()", "global delay() is deprecated, use task.delay")
	return task.delay(t, fn)
end

----------------------------------------------------------------------------------------------------
-- Signals (RBXScriptSignal / RBXScriptConnection)
----------------------------------------------------------------------------------------------------
local Live = { connections = 0 }
local AllSignals = setmetatable({}, { __mode = "k" })

local SignalMT, ConnMT = {}, {}
SignalMT.__index = SignalMT
ConnMT.__index = ConnMT
SignalMT.__tostring = function()
	return "Signal"
end
ConnMT.__tostring = function()
	return "Connection"
end

local function newSignal(name, onConnect)
	local s = setmetatable({ _name = name or "Signal", _conns = {}, _waiters = {}, _onConnect = onConnect }, SignalMT)
	AllSignals[s] = true
	return s
end

function SignalMT.Connect(self, fn)
	if rawtype(fn) ~= "function" then
		error("Attempt to connect failed: Passed value is not a function", 2)
	end
	local conn = setmetatable({ Connected = true, _fn = fn, _sig = self }, ConnMT)
	local conns = self._conns
	conns[#conns + 1] = conn
	Live.connections = Live.connections + 1
	if self._onConnect then
		self._onConnect(self, conn)
	end
	return conn
end
SignalMT.ConnectParallel = SignalMT.Connect

function SignalMT.Once(self, fn)
	local conn
	conn = self:Connect(function(...)
		if conn.Connected then
			conn:Disconnect()
			return fn(...)
		end
	end)
	return conn
end

function ConnMT.Disconnect(self)
	if not self.Connected then
		return
	end
	self.Connected = false
	Live.connections = Live.connections - 1
	local conns = self._sig._conns
	for i = #conns, 1, -1 do
		if conns[i] == self then
			tremove(conns, i)
			break
		end
	end
end
ConnMT.disconnect = nil

function SignalMT.Wait(self)
	if isMainThread() then
		-- driver code waiting on an event: step the clock until it fires (max 10 minutes of fake time)
		local fired, result = false, nil
		local c = self:Connect(function(...)
			fired = true
			result = pack(...)
		end)
		local ok = Mock.AdvanceUntil(function()
			return fired
		end, 600)
		c:Disconnect()
		if ok then
			return unpack(result, 1, result.n)
		end
		return nil
	end
	local co = coroutine.running()
	self._waiters[#self._waiters + 1] = co
	return coroutine.yield()
end

-- Mock-only: fire every handler (each in its own thread) and wake waiters.
function SignalMT.Fire(self, ...)
	local conns = self._conns
	local n = #conns
	if n > 0 then
		local snapshot = {}
		for i = 1, n do
			snapshot[i] = conns[i]
		end
		for i = 1, n do
			local c = snapshot[i]
			if c.Connected then
				task.spawn(c._fn, ...)
			end
		end
	end
	local waiters = self._waiters
	if #waiters > 0 then
		self._waiters = {}
		for _, co in ipairs(waiters) do
			if not (Mock._cancelled and Mock._cancelled[co]) then
				resume(co, ...)
			end
		end
	end
end

function SignalMT.DisconnectAll(self)
	local conns = self._conns
	for i = #conns, 1, -1 do
		local c = conns[i]
		c.Connected = false
		Live.connections = Live.connections - 1
		conns[i] = nil
	end
	self._waiters = {}
end

function SignalMT.HasListeners(self)
	return #self._conns > 0 or #self._waiters > 0
end

-- Connections currently alive, grouped by signal name (leak reports).
function Mock.ConnectionReport()
	local report = {}
	for s in pairs(AllSignals) do
		local n = #s._conns
		if n > 0 then
			report[s._name] = (report[s._name] or 0) + n
		end
	end
	return report
end
function Mock.LiveConnections()
	return Live.connections
end

Mock._newSignal = newSignal

----------------------------------------------------------------------------------------------------
-- typeof / type: mock datatypes behave like Roblox userdata
----------------------------------------------------------------------------------------------------
local UD = setmetatable({}, { __mode = "k" }) -- metatable -> Roblox type name
local function regType(mt, name)
	UD[mt] = name
end

function typeof(v)
	local t = rawtype(v)
	if t == "table" then
		local mt = getmetatable(v)
		local n = mt and UD[mt]
		if n then
			return n
		end
	end
	return t
end
local typeof = typeof

function type(v)
	local t = rawtype(v)
	if t == "table" then
		local mt = getmetatable(v)
		if mt and UD[mt] then
			return "userdata"
		end
	end
	return t
end

local function checkNum(v, what, argn)
	if rawtype(v) ~= "number" then
		error(sformat("invalid argument #%d to '%s' (number expected, got %s)", argn or 1, what, typeof(v)), 3)
	end
	return v
end

local function fmtNum(n)
	if n == floor(n) and abs(n) < 1e15 then
		return sformat("%d", n)
	end
	return sformat("%.6g", n)
end

----------------------------------------------------------------------------------------------------
-- Vector3 / Vector2
----------------------------------------------------------------------------------------------------
local V3mt, V3m = {}, {}
local V2mt, V2m = {}, {}
regType(V3mt, "Vector3")
regType(V2mt, "Vector2")

local function v3(x, y, z)
	return setmetatable({ X = x, Y = y, Z = z }, V3mt)
end
local function v2(x, y)
	return setmetatable({ X = x, Y = y }, V2mt)
end
local function isV3(v)
	return getmetatable(v) == V3mt
end
local function isV2(v)
	return getmetatable(v) == V2mt
end

local NAN = 0 / 0

V3mt.__index = function(self, k)
	local m = V3m[k]
	if m then
		return m
	end
	if k == "Magnitude" then
		return sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif k == "Unit" then
		local mag = sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		if mag == 0 then
			return v3(NAN, NAN, NAN)
		end
		return v3(self.X / mag, self.Y / mag, self.Z / mag)
	end
	error(tostring(k) .. " is not a valid member of Vector3", 2)
end
V3mt.__newindex = function(_, k)
	error("Unable to assign property " .. tostring(k) .. ". Vector3 is immutable", 2)
end
V3mt.__tostring = function(s)
	return fmtNum(s.X) .. ", " .. fmtNum(s.Y) .. ", " .. fmtNum(s.Z)
end
V3mt.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V3mt.__unm = function(a)
	return v3(-a.X, -a.Y, -a.Z)
end
V3mt.__add = function(a, b)
	if getmetatable(a) ~= V3mt or getmetatable(b) ~= V3mt then
		error("attempt to perform arithmetic (add) on " .. typeof(a) .. " and " .. typeof(b), 2)
	end
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3mt.__sub = function(a, b)
	if getmetatable(a) ~= V3mt or getmetatable(b) ~= V3mt then
		error("attempt to perform arithmetic (sub) on " .. typeof(a) .. " and " .. typeof(b), 2)
	end
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3mt.__mul = function(a, b)
	local ta, tb = rawtype(a), rawtype(b)
	if ta == "number" then
		return v3(a * b.X, a * b.Y, a * b.Z)
	elseif tb == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	elseif getmetatable(a) == V3mt and getmetatable(b) == V3mt then
		return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
	end
	error("attempt to perform arithmetic (mul) on " .. typeof(a) .. " and " .. typeof(b), 2)
end
V3mt.__div = function(a, b)
	local ta, tb = rawtype(a), rawtype(b)
	if ta == "number" then
		return v3(a / b.X, a / b.Y, a / b.Z)
	elseif tb == "number" then
		return v3(a.X / b, a.Y / b, a.Z / b)
	elseif getmetatable(a) == V3mt and getmetatable(b) == V3mt then
		return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
	end
	error("attempt to perform arithmetic (div) on " .. typeof(a) .. " and " .. typeof(b), 2)
end

function V3m.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function V3m.Cross(a, b)
	return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function V3m.Lerp(a, b, t)
	return v3(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
end
function V3m.Angle(a, b, axis)
	local ma = sqrt(a:Dot(a))
	local mb = sqrt(b:Dot(b))
	if ma == 0 or mb == 0 then
		return NAN
	end
	local c = a:Dot(b) / (ma * mb)
	c = mmax(-1, mmin(1, c))
	local ang = acos(c)
	if axis and a:Cross(b):Dot(axis) < 0 then
		ang = -ang
	end
	return ang
end
function V3m.FuzzyEq(a, b, eps)
	eps = eps or 1e-5
	return abs(a.X - b.X) <= eps and abs(a.Y - b.Y) <= eps and abs(a.Z - b.Z) <= eps
end
function V3m.Max(a, ...)
	local x, y, z = a.X, a.Y, a.Z
	for i = 1, select("#", ...) do
		local o = select(i, ...)
		x, y, z = mmax(x, o.X), mmax(y, o.Y), mmax(z, o.Z)
	end
	return v3(x, y, z)
end
function V3m.Min(a, ...)
	local x, y, z = a.X, a.Y, a.Z
	for i = 1, select("#", ...) do
		local o = select(i, ...)
		x, y, z = mmin(x, o.X), mmin(y, o.Y), mmin(z, o.Z)
	end
	return v3(x, y, z)
end
function V3m.Abs(a)
	return v3(abs(a.X), abs(a.Y), abs(a.Z))
end
function V3m.Floor(a)
	return v3(floor(a.X), floor(a.Y), floor(a.Z))
end
function V3m.Ceil(a)
	return v3(ceil(a.X), ceil(a.Y), ceil(a.Z))
end
local function sign(n)
	return n > 0 and 1 or (n < 0 and -1 or 0)
end
function V3m.Sign(a)
	return v3(sign(a.X), sign(a.Y), sign(a.Z))
end

Vector3 = {}
function Vector3.new(x, y, z)
	if x ~= nil and rawtype(x) ~= "number" then
		error("invalid argument #1 to 'new' (number expected, got " .. typeof(x) .. ")", 2)
	end
	if y ~= nil and rawtype(y) ~= "number" then
		error("invalid argument #2 to 'new' (number expected, got " .. typeof(y) .. ")", 2)
	end
	if z ~= nil and rawtype(z) ~= "number" then
		error("invalid argument #3 to 'new' (number expected, got " .. typeof(z) .. ")", 2)
	end
	return v3(x or 0, y or 0, z or 0)
end
Vector3.zero = v3(0, 0, 0)
Vector3.one = v3(1, 1, 1)
Vector3.xAxis = v3(1, 0, 0)
Vector3.yAxis = v3(0, 1, 0)
Vector3.zAxis = v3(0, 0, 1)
function Vector3.FromNormalId(n)
	local name = n.Name
	local map = { Right = v3(1, 0, 0), Left = v3(-1, 0, 0), Top = v3(0, 1, 0), Bottom = v3(0, -1, 0), Back = v3(0, 0, 1), Front = v3(0, 0, -1) }
	return map[name]
end
setmetatable(Vector3, {
	__index = function(_, k)
		error(tostring(k) .. " is not a valid member of Vector3", 2)
	end,
})

V2mt.__index = function(self, k)
	local m = V2m[k]
	if m then
		return m
	end
	if k == "Magnitude" then
		return sqrt(self.X * self.X + self.Y * self.Y)
	elseif k == "Unit" then
		local mag = sqrt(self.X * self.X + self.Y * self.Y)
		if mag == 0 then
			return v2(NAN, NAN)
		end
		return v2(self.X / mag, self.Y / mag)
	end
	error(tostring(k) .. " is not a valid member of Vector2", 2)
end
V2mt.__newindex = function(_, k)
	error("Unable to assign property " .. tostring(k) .. ". Vector2 is immutable", 2)
end
V2mt.__tostring = function(s)
	return fmtNum(s.X) .. ", " .. fmtNum(s.Y)
end
V2mt.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
V2mt.__unm = function(a)
	return v2(-a.X, -a.Y)
end
V2mt.__add = function(a, b)
	if getmetatable(a) ~= V2mt or getmetatable(b) ~= V2mt then
		error("attempt to perform arithmetic (add) on " .. typeof(a) .. " and " .. typeof(b), 2)
	end
	return v2(a.X + b.X, a.Y + b.Y)
end
V2mt.__sub = function(a, b)
	if getmetatable(a) ~= V2mt or getmetatable(b) ~= V2mt then
		error("attempt to perform arithmetic (sub) on " .. typeof(a) .. " and " .. typeof(b), 2)
	end
	return v2(a.X - b.X, a.Y - b.Y)
end
V2mt.__mul = function(a, b)
	if rawtype(a) == "number" then
		return v2(a * b.X, a * b.Y)
	elseif rawtype(b) == "number" then
		return v2(a.X * b, a.Y * b)
	elseif getmetatable(a) == V2mt and getmetatable(b) == V2mt then
		return v2(a.X * b.X, a.Y * b.Y)
	end
	error("attempt to perform arithmetic (mul) on " .. typeof(a) .. " and " .. typeof(b), 2)
end
V2mt.__div = function(a, b)
	if rawtype(a) == "number" then
		return v2(a / b.X, a / b.Y)
	elseif rawtype(b) == "number" then
		return v2(a.X / b, a.Y / b)
	elseif getmetatable(a) == V2mt and getmetatable(b) == V2mt then
		return v2(a.X / b.X, a.Y / b.Y)
	end
	error("attempt to perform arithmetic (div) on " .. typeof(a) .. " and " .. typeof(b), 2)
end
function V2m.Dot(a, b)
	return a.X * b.X + a.Y * b.Y
end
function V2m.Cross(a, b)
	return a.X * b.Y - a.Y * b.X
end
function V2m.Lerp(a, b, t)
	return v2(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t)
end
function V2m.Abs(a)
	return v2(abs(a.X), abs(a.Y))
end
function V2m.Floor(a)
	return v2(floor(a.X), floor(a.Y))
end
function V2m.FuzzyEq(a, b, eps)
	eps = eps or 1e-5
	return abs(a.X - b.X) <= eps and abs(a.Y - b.Y) <= eps
end
function V2m.Max(a, b)
	return v2(mmax(a.X, b.X), mmax(a.Y, b.Y))
end
function V2m.Min(a, b)
	return v2(mmin(a.X, b.X), mmin(a.Y, b.Y))
end

Vector2 = {}
function Vector2.new(x, y)
	if x ~= nil then
		checkNum(x, "new", 1)
	end
	if y ~= nil then
		checkNum(y, "new", 2)
	end
	return v2(x or 0, y or 0)
end
Vector2.zero = v2(0, 0)
Vector2.one = v2(1, 1)
Vector2.xAxis = v2(1, 0)
Vector2.yAxis = v2(0, 1)

Vector3int16 = { new = function(x, y, z)
	return v3(floor(x or 0), floor(y or 0), floor(z or 0))
end }
Vector2int16 = { new = function(x, y)
	return v2(floor(x or 0), floor(y or 0))
end }

----------------------------------------------------------------------------------------------------
-- CFrame
----------------------------------------------------------------------------------------------------
local cf, CF_IDENTITY
do
local CFmt, CFm = {}, {}
regType(CFmt, "CFrame")

cf = function(x, y, z, a, b, c, d, e, f, g, h, i)
	return setmetatable({ x = x, y = y, z = z, a = a, b = b, c = c, d = d, e = e, f = f, g = g, h = h, i = i }, CFmt)
end
local function isCF(v)
	return getmetatable(v) == CFmt
end
CF_IDENTITY = cf(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)

local function rotMul(l, r)
	return l.a * r.a + l.b * r.d + l.c * r.g,
		l.a * r.b + l.b * r.e + l.c * r.h,
		l.a * r.c + l.b * r.f + l.c * r.i,
		l.d * r.a + l.e * r.d + l.f * r.g,
		l.d * r.b + l.e * r.e + l.f * r.h,
		l.d * r.c + l.e * r.f + l.f * r.i,
		l.g * r.a + l.h * r.d + l.i * r.g,
		l.g * r.b + l.h * r.e + l.i * r.h,
		l.g * r.c + l.h * r.f + l.i * r.i
end

CFmt.__mul = function(l, r)
	local rm = getmetatable(r)
	if rm == CFmt then
		local a, b, c, d, e, f, g, h, i = rotMul(l, r)
		return cf(
			l.a * r.x + l.b * r.y + l.c * r.z + l.x,
			l.d * r.x + l.e * r.y + l.f * r.z + l.y,
			l.g * r.x + l.h * r.y + l.i * r.z + l.z,
			a, b, c, d, e, f, g, h, i
		)
	elseif rm == V3mt then
		return v3(
			l.a * r.X + l.b * r.Y + l.c * r.Z + l.x,
			l.d * r.X + l.e * r.Y + l.f * r.Z + l.y,
			l.g * r.X + l.h * r.Y + l.i * r.Z + l.z
		)
	end
	error("Attempt to multiply CFrame by " .. typeof(r), 2)
end
CFmt.__add = function(l, r)
	if getmetatable(l) == CFmt and getmetatable(r) == V3mt then
		return cf(l.x + r.X, l.y + r.Y, l.z + r.Z, l.a, l.b, l.c, l.d, l.e, l.f, l.g, l.h, l.i)
	end
	error("attempt to perform arithmetic (add) on " .. typeof(l) .. " and " .. typeof(r), 2)
end
CFmt.__sub = function(l, r)
	if getmetatable(l) == CFmt and getmetatable(r) == V3mt then
		return cf(l.x - r.X, l.y - r.Y, l.z - r.Z, l.a, l.b, l.c, l.d, l.e, l.f, l.g, l.h, l.i)
	end
	error("attempt to perform arithmetic (sub) on " .. typeof(l) .. " and " .. typeof(r), 2)
end
CFmt.__eq = function(l, r)
	return l.x == r.x and l.y == r.y and l.z == r.z and l.a == r.a and l.b == r.b and l.c == r.c and l.d == r.d
		and l.e == r.e and l.f == r.f and l.g == r.g and l.h == r.h and l.i == r.i
end
CFmt.__tostring = function(s)
	return tconcat({
		fmtNum(s.x), fmtNum(s.y), fmtNum(s.z), fmtNum(s.a), fmtNum(s.b), fmtNum(s.c),
		fmtNum(s.d), fmtNum(s.e), fmtNum(s.f), fmtNum(s.g), fmtNum(s.h), fmtNum(s.i),
	}, ", ")
end
CFmt.__newindex = function(_, k)
	error("Unable to assign property " .. tostring(k) .. ". CFrame is immutable", 2)
end
CFmt.__index = function(self, k)
	local m = CFm[k]
	if m then
		return m
	end
	if k == "Position" or k == "p" then
		return v3(self.x, self.y, self.z)
	elseif k == "X" then
		return self.x
	elseif k == "Y" then
		return self.y
	elseif k == "Z" then
		return self.z
	elseif k == "LookVector" then
		return v3(-self.c, -self.f, -self.i)
	elseif k == "RightVector" or k == "XVector" then
		return v3(self.a, self.d, self.g)
	elseif k == "UpVector" or k == "YVector" then
		return v3(self.b, self.e, self.h)
	elseif k == "ZVector" then
		return v3(self.c, self.f, self.i)
	elseif k == "Rotation" then
		return cf(0, 0, 0, self.a, self.b, self.c, self.d, self.e, self.f, self.g, self.h, self.i)
	end
	error(tostring(k) .. " is not a valid member of CFrame", 2)
end

function CFm.Inverse(s)
	return cf(
		-(s.a * s.x + s.d * s.y + s.g * s.z),
		-(s.b * s.x + s.e * s.y + s.h * s.z),
		-(s.c * s.x + s.f * s.y + s.i * s.z),
		s.a, s.d, s.g, s.b, s.e, s.h, s.c, s.f, s.i
	)
end
function CFm.ToWorldSpace(s, o)
	return s * o
end
function CFm.ToObjectSpace(s, o)
	return s:Inverse() * o
end
function CFm.PointToWorldSpace(s, v)
	return s * v
end
function CFm.PointToObjectSpace(s, v)
	return s:Inverse() * v
end
function CFm.VectorToWorldSpace(s, v)
	return v3(s.a * v.X + s.b * v.Y + s.c * v.Z, s.d * v.X + s.e * v.Y + s.f * v.Z, s.g * v.X + s.h * v.Y + s.i * v.Z)
end
function CFm.VectorToObjectSpace(s, v)
	return v3(s.a * v.X + s.d * v.Y + s.g * v.Z, s.b * v.X + s.e * v.Y + s.h * v.Z, s.c * v.X + s.f * v.Y + s.i * v.Z)
end
function CFm.GetComponents(s)
	return s.x, s.y, s.z, s.a, s.b, s.c, s.d, s.e, s.f, s.g, s.h, s.i
end
CFm.components = CFm.GetComponents
function CFm.FuzzyEq(s, o, eps)
	eps = eps or 1e-5
	local a1 = { s:GetComponents() }
	local a2 = { o:GetComponents() }
	for k = 1, 12 do
		if abs(a1[k] - a2[k]) > eps then
			return false
		end
	end
	return true
end
function CFm.ToEulerAnglesXYZ(s)
	local ry = asin(mmax(-1, mmin(1, s.c)))
	local rx = atan2(-s.f, s.i)
	local rz = atan2(-s.b, s.a)
	return rx, ry, rz
end
CFm.ToEulerAngles = CFm.ToEulerAnglesXYZ
function CFm.ToOrientation(s)
	local rx = asin(mmax(-1, mmin(1, -s.f)))
	local ry = atan2(s.c, s.i)
	local rz = atan2(s.d, s.e)
	return rx, ry, rz
end
CFm.ToEulerAnglesYXZ = CFm.ToOrientation
function CFm.Orthonormalize(s)
	return s
end

-- quaternion helpers (for Lerp / axis-angle)
local function toQuat(s)
	local tr = s.a + s.e + s.i
	local qx, qy, qz, qw
	if tr > 0 then
		local sq = sqrt(tr + 1) * 2
		qw = 0.25 * sq
		qx = (s.h - s.f) / sq
		qy = (s.c - s.g) / sq
		qz = (s.d - s.b) / sq
	elseif s.a > s.e and s.a > s.i then
		local sq = sqrt(1 + s.a - s.e - s.i) * 2
		qw = (s.h - s.f) / sq
		qx = 0.25 * sq
		qy = (s.b + s.d) / sq
		qz = (s.c + s.g) / sq
	elseif s.e > s.i then
		local sq = sqrt(1 + s.e - s.a - s.i) * 2
		qw = (s.c - s.g) / sq
		qx = (s.b + s.d) / sq
		qy = 0.25 * sq
		qz = (s.f + s.h) / sq
	else
		local sq = sqrt(1 + s.i - s.a - s.e) * 2
		qw = (s.d - s.b) / sq
		qx = (s.c + s.g) / sq
		qy = (s.f + s.h) / sq
		qz = 0.25 * sq
	end
	return qx, qy, qz, qw
end
local function fromQuat(px, py, pz, qx, qy, qz, qw)
	local n = sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
	if n == 0 then
		return cf(px, py, pz, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
	return cf(
		px, py, pz,
		1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw),
		2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw),
		2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)
	)
end
function CFm.Lerp(s, o, t)
	local ax, ay, az, aw = toQuat(s)
	local bx, by, bz, bw = toQuat(o)
	if ax * bx + ay * by + az * bz + aw * bw < 0 then
		bx, by, bz, bw = -bx, -by, -bz, -bw
	end
	return fromQuat(
		s.x + (o.x - s.x) * t, s.y + (o.y - s.y) * t, s.z + (o.z - s.z) * t,
		ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, aw + (bw - aw) * t
	)
end
function CFm.ToAxisAngle(s)
	local qx, qy, qz, qw = toQuat(s)
	if qw < 0 then
		qx, qy, qz, qw = -qx, -qy, -qz, -qw
	end
	local ang = 2 * acos(mmin(1, qw))
	local sn = sqrt(1 - qw * qw)
	if sn < 1e-6 then
		return v3(1, 0, 0), 0
	end
	return v3(qx / sn, qy / sn, qz / sn), ang
end

local function rotX(t)
	local c, s = cos(t), sin(t)
	return cf(0, 0, 0, 1, 0, 0, 0, c, -s, 0, s, c)
end
local function rotY(t)
	local c, s = cos(t), sin(t)
	return cf(0, 0, 0, c, 0, s, 0, 1, 0, -s, 0, c)
end
local function rotZ(t)
	local c, s = cos(t), sin(t)
	return cf(0, 0, 0, c, -s, 0, s, c, 0, 0, 0, 1)
end

local function lookAt(at, target, up)
	up = up or v3(0, 1, 0)
	local z = at - target
	local zl = sqrt(z.X * z.X + z.Y * z.Y + z.Z * z.Z)
	if zl < 1e-9 then
		return cf(at.X, at.Y, at.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	z = v3(z.X / zl, z.Y / zl, z.Z / zl)
	local x = V3m.Cross(up, z)
	local xl = sqrt(x.X * x.X + x.Y * x.Y + x.Z * x.Z)
	if xl < 1e-6 then
		-- looking straight along `up`: pick any perpendicular axis
		x = (abs(z.X) < 0.9) and v3(1, 0, 0) or v3(0, 0, 1)
		x = V3m.Cross(x, z)
		xl = sqrt(x.X * x.X + x.Y * x.Y + x.Z * x.Z)
	end
	x = v3(x.X / xl, x.Y / xl, x.Z / xl)
	local y = V3m.Cross(z, x)
	return cf(at.X, at.Y, at.Z, x.X, y.X, z.X, x.Y, y.Y, z.Y, x.Z, y.Z, z.Z)
end

CFrame = {}
function CFrame.new(...)
	local n = select("#", ...)
	if n == 0 then
		return CF_IDENTITY
	end
	local a1, a2, a3 = ...
	if n == 1 then
		if not isV3(a1) then
			error("invalid argument #1 to 'new' (Vector3 expected, got " .. typeof(a1) .. ")", 2)
		end
		return cf(a1.X, a1.Y, a1.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif n == 2 then
		if not (isV3(a1) and isV3(a2)) then
			error("invalid arguments to CFrame.new (expected Vector3, Vector3)", 2)
		end
		return lookAt(a1, a2)
	elseif n == 3 then
		checkNum(a1, "new", 1)
		checkNum(a2, "new", 2)
		checkNum(a3, "new", 3)
		return cf(a1, a2, a3, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif n == 7 then
		local x, y, z, qx, qy, qz, qw = ...
		return fromQuat(x, y, z, qx, qy, qz, qw)
	elseif n == 12 then
		return cf(...)
	end
	error("invalid number of arguments to CFrame.new (" .. n .. ")", 2)
end
function CFrame.Angles(rx, ry, rz)
	return rotX(rx or 0) * rotY(ry or 0) * rotZ(rz or 0)
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles
function CFrame.fromEulerAnglesYXZ(rx, ry, rz)
	return rotY(ry or 0) * rotX(rx or 0) * rotZ(rz or 0)
end
CFrame.fromOrientation = CFrame.fromEulerAnglesYXZ
function CFrame.lookAt(at, target, up)
	return lookAt(at, target, up)
end
function CFrame.fromAxisAngle(axis, angle)
	local u = axis.Unit
	local c, s = cos(angle), sin(angle)
	local t = 1 - c
	local x, y, z = u.X, u.Y, u.Z
	return cf(
		0, 0, 0,
		t * x * x + c, t * x * y - s * z, t * x * z + s * y,
		t * x * y + s * z, t * y * y + c, t * y * z - s * x,
		t * x * z - s * y, t * y * z + s * x, t * z * z + c
	)
end
function CFrame.fromMatrix(pos, vx, vy, vz)
	vz = vz or V3m.Cross(vx, vy)
	return cf(pos.X, pos.Y, pos.Z, vx.X, vy.X, vz.X, vx.Y, vy.Y, vz.Y, vx.Z, vy.Z, vz.Z)
end
CFrame.identity = CF_IDENTITY
setmetatable(CFrame, {
	__index = function(_, k)
		error(tostring(k) .. " is not a valid member of CFrame", 2)
	end,
})

end
----------------------------------------------------------------------------------------------------
-- Color3, UDim, UDim2, Rect, ranges and sequences
----------------------------------------------------------------------------------------------------
local C3mt, C3m = {}, {}
regType(C3mt, "Color3")
local function c3(r, g, b)
	return setmetatable({ R = r, G = g, B = b }, C3mt)
end
C3mt.__index = function(self, k)
	local m = C3m[k]
	if m then
		return m
	end
	error(tostring(k) .. " is not a valid member of Color3", 2)
end
C3mt.__newindex = function(_, k)
	error("Unable to assign property " .. tostring(k) .. ". Color3 is immutable", 2)
end
C3mt.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
C3mt.__tostring = function(s)
	return sformat("%.6g, %.6g, %.6g", s.R, s.G, s.B)
end
function C3m.Lerp(a, b, t)
	return c3(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end
function C3m.ToHSV(c)
	local mx, mn = mmax(c.R, c.G, c.B), mmin(c.R, c.G, c.B)
	local d = mx - mn
	local h = 0
	if d > 0 then
		if mx == c.R then
			h = ((c.G - c.B) / d) % 6
		elseif mx == c.G then
			h = (c.B - c.R) / d + 2
		else
			h = (c.R - c.G) / d + 4
		end
		h = h / 6
	end
	return h, (mx == 0) and 0 or d / mx, mx
end
function C3m.ToHex(c)
	return sformat("%02X%02X%02X", floor(c.R * 255 + 0.5), floor(c.G * 255 + 0.5), floor(c.B * 255 + 0.5))
end
Color3 = {}
function Color3.new(r, g, b)
	return c3(mmax(0, mmin(1, r or 0)), mmax(0, mmin(1, g or 0)), mmax(0, mmin(1, b or 0)))
end
function Color3.fromRGB(r, g, b)
	return c3(mmax(0, mmin(255, floor(r or 0))) / 255, mmax(0, mmin(255, floor(g or 0))) / 255, mmax(0, mmin(255, floor(b or 0))) / 255)
end
function Color3.fromHSV(h, s, v)
	h = (h % 1) * 6
	local i = floor(h)
	local f = h - i
	local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
	local m = { { v, t, p }, { q, v, p }, { p, v, t }, { p, q, v }, { t, p, v }, { v, p, q } }
	local c = m[(i % 6) + 1]
	return c3(c[1], c[2], c[3])
end
function Color3.fromHex(hex)
	hex = tostring(hex):gsub("#", "")
	local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
	if not (r and g and b) then
		error("Color3.fromHex: invalid hex string", 2)
	end
	return Color3.fromRGB(r, g, b)
end

local UDmt, UDm = {}, {}
local U2mt, U2m = {}, {}
regType(UDmt, "UDim")
regType(U2mt, "UDim2")
local function ud(s, o)
	return setmetatable({ Scale = s, Offset = o }, UDmt)
end
local function u2(xs, xo, ys, yo)
	local x, y = ud(xs, xo), ud(ys, yo)
	return setmetatable({ X = x, Y = y, Width = x, Height = y }, U2mt)
end
UDmt.__index = function(self, k)
	local m = UDm[k]
	if m then
		return m
	end
	error(tostring(k) .. " is not a valid member of UDim", 2)
end
UDmt.__newindex = function(_, k)
	error("Unable to assign property " .. tostring(k) .. ". UDim is immutable", 2)
end
UDmt.__eq = function(a, b)
	return a.Scale == b.Scale and a.Offset == b.Offset
end
UDmt.__add = function(a, b)
	return ud(a.Scale + b.Scale, a.Offset + b.Offset)
end
UDmt.__sub = function(a, b)
	return ud(a.Scale - b.Scale, a.Offset - b.Offset)
end
UDmt.__tostring = function(s)
	return fmtNum(s.Scale) .. ", " .. fmtNum(s.Offset)
end
U2mt.__index = function(self, k)
	local m = U2m[k]
	if m then
		return m
	end
	error(tostring(k) .. " is not a valid member of UDim2", 2)
end
U2mt.__newindex = function(_, k)
	error("Unable to assign property " .. tostring(k) .. ". UDim2 is immutable", 2)
end
U2mt.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
U2mt.__add = function(a, b)
	return u2(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset)
end
U2mt.__sub = function(a, b)
	return u2(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset)
end
U2mt.__tostring = function(s)
	return "{" .. tostring(s.X) .. "}, {" .. tostring(s.Y) .. "}"
end
function U2m.Lerp(a, b, t)
	return u2(
		a.X.Scale + (b.X.Scale - a.X.Scale) * t, a.X.Offset + (b.X.Offset - a.X.Offset) * t,
		a.Y.Scale + (b.Y.Scale - a.Y.Scale) * t, a.Y.Offset + (b.Y.Offset - a.Y.Offset) * t
	)
end
UDim = {}
function UDim.new(s, o)
	return ud(s or 0, o or 0)
end
UDim2 = {}
function UDim2.new(a, b, c, d)
	if getmetatable(a) == UDmt and getmetatable(b) == UDmt then
		return u2(a.Scale, a.Offset, b.Scale, b.Offset)
	end
	if a ~= nil then
		checkNum(a, "new", 1)
	end
	if b ~= nil then
		checkNum(b, "new", 2)
	end
	if c ~= nil then
		checkNum(c, "new", 3)
	end
	if d ~= nil then
		checkNum(d, "new", 4)
	end
	return u2(a or 0, b or 0, c or 0, d or 0)
end
function UDim2.fromScale(x, y)
	return u2(x or 0, 0, y or 0, 0)
end
function UDim2.fromOffset(x, y)
	return u2(0, x or 0, 0, y or 0)
end

do
Rect = {}
local RCmt = {}
regType(RCmt, "Rect")
RCmt.__index = function(self, k)
	if k == "Width" then
		return self.Max.X - self.Min.X
	elseif k == "Height" then
		return self.Max.Y - self.Min.Y
	end
	error(tostring(k) .. " is not a valid member of Rect", 2)
end
function Rect.new(a, b, c, d)
	local minv, maxv
	if isV2(a) then
		minv, maxv = a, b
	else
		minv, maxv = v2(a or 0, b or 0), v2(c or 0, d or 0)
	end
	return setmetatable({ Min = minv, Max = maxv }, RCmt)
end

local NRmt = {}
regType(NRmt, "NumberRange")
NRmt.__index = function(_, k)
	error(tostring(k) .. " is not a valid member of NumberRange", 2)
end
NRmt.__tostring = function(s)
	return fmtNum(s.Min) .. " " .. fmtNum(s.Max)
end
NumberRange = {}
function NumberRange.new(a, b)
	if rawtype(a) ~= "number" then
		error("invalid argument #1 to 'new' (number expected, got " .. typeof(a) .. ")", 2)
	end
	b = b == nil and a or b
	if rawtype(b) ~= "number" then
		error("invalid argument #2 to 'new' (number expected, got " .. typeof(b) .. ")", 2)
	end
	if a > b then
		error("NumberRange: min must be <= max", 2)
	end
	return setmetatable({ Min = a, Max = b }, NRmt)
end

local NSKmt, CSKmt, NSmt, CSmt = {}, {}, {}, {}
regType(NSKmt, "NumberSequenceKeypoint")
regType(CSKmt, "ColorSequenceKeypoint")
regType(NSmt, "NumberSequence")
regType(CSmt, "ColorSequence")
NumberSequenceKeypoint = {}
function NumberSequenceKeypoint.new(t, v, e)
	checkNum(t, "new", 1)
	checkNum(v, "new", 2)
	if t < 0 or t > 1 then
		error("NumberSequenceKeypoint time must be in [0, 1]", 2)
	end
	return setmetatable({ Time = t, Value = v, Envelope = e or 0 }, NSKmt)
end
ColorSequenceKeypoint = {}
function ColorSequenceKeypoint.new(t, c)
	checkNum(t, "new", 1)
	if getmetatable(c) ~= C3mt then
		error("invalid argument #2 to 'new' (Color3 expected, got " .. typeof(c) .. ")", 2)
	end
	if t < 0 or t > 1 then
		error("ColorSequenceKeypoint time must be in [0, 1]", 2)
	end
	return setmetatable({ Time = t, Value = c }, CSKmt)
end
local function checkKeypoints(kps, what)
	if #kps < 2 then
		error(what .. " must have at least 2 keypoints", 3)
	end
	if kps[1].Time ~= 0 then
		error(what .. ": first keypoint must be at time 0", 3)
	end
	if kps[#kps].Time ~= 1 then
		error(what .. ": last keypoint must be at time 1", 3)
	end
	for i = 2, #kps do
		if kps[i].Time < kps[i - 1].Time then
			error(what .. ": keypoints must be in ascending time order", 3)
		end
	end
end
NumberSequence = {}
function NumberSequence.new(a, b)
	local kps
	if rawtype(a) == "number" then
		kps = { NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b == nil and a or b) }
	elseif rawtype(a) == "table" and getmetatable(a) == nil then
		kps = a
		for _, k in ipairs(kps) do
			if getmetatable(k) ~= NSKmt then
				error("NumberSequence.new expects NumberSequenceKeypoint values", 2)
			end
		end
	else
		error("invalid argument #1 to 'new' (number or table of NumberSequenceKeypoint expected, got " .. typeof(a) .. ")", 2)
	end
	checkKeypoints(kps, "NumberSequence")
	return setmetatable({ Keypoints = kps }, NSmt)
end
ColorSequence = {}
function ColorSequence.new(a, b)
	local kps
	if getmetatable(a) == C3mt then
		kps = { ColorSequenceKeypoint.new(0, a), ColorSequenceKeypoint.new(1, b == nil and a or b) }
	elseif rawtype(a) == "table" and getmetatable(a) == nil then
		kps = a
		for _, k in ipairs(kps) do
			if getmetatable(k) ~= CSKmt then
				error("ColorSequence.new expects ColorSequenceKeypoint values", 2)
			end
		end
	else
		error("invalid argument #1 to 'new' (Color3 or table of ColorSequenceKeypoint expected, got " .. typeof(a) .. ")", 2)
	end
	checkKeypoints(kps, "ColorSequence")
	return setmetatable({ Keypoints = kps }, CSmt)
end
NSmt.__index = function(_, k)
	error(tostring(k) .. " is not a valid member of NumberSequence", 2)
end
CSmt.__index = function(_, k)
	error(tostring(k) .. " is not a valid member of ColorSequence", 2)
end

end
----------------------------------------------------------------------------------------------------
-- Enum
----------------------------------------------------------------------------------------------------
local enumItem, coerceEnum
do
local EnumTypeMT, EnumItemMT, EnumRootMT = {}, {}, {}
regType(EnumTypeMT, "Enum")
regType(EnumItemMT, "EnumItem")
regType(EnumRootMT, "Enums")

-- Enums whose complete member list is known: a wrong member name is an error, as in Roblox.
local CLOSED_ENUMS = {
	Material = "Plastic Wood Slate Concrete CorrodedMetal DiamondPlate Foil Grass Ice Marble Granite Brick Pebble Sand Fabric SmoothPlastic Metal WoodPlanks Cobblestone Air Water Rock Glacier Snow Sandstone Mud Basalt Ground CrackedLava Asphalt LeafyGrass Salt Limestone Pavement ForceField Glass Neon Cardboard Carpet CeramicTiles ClayRoofTiles RoofShingles Leather Plaster Rubber",
	EasingStyle = "Linear Sine Back Quad Quart Quint Bounce Elastic Exponential Circular Cubic",
	EasingDirection = "In Out InOut",
	PartType = "Ball Block Cylinder Wedge CornerWedge",
	ApplyStrokeMode = "Contextual Border",
	TextXAlignment = "Left Center Right",
	TextYAlignment = "Top Center Bottom",
	SortOrder = "Name Custom LayoutOrder",
	FillDirection = "Horizontal Vertical",
	HorizontalAlignment = "Center Left Right",
	VerticalAlignment = "Center Top Bottom",
	RaycastFilterType = "Exclude Include Blacklist Whitelist",
	PlaybackState = "Begin Delayed Playing Paused Completed Cancelled",
	NormalId = "Right Top Back Left Bottom Front",
	SurfaceType = "Smooth Glue Weld Studs Inlet Universal Hinge Motor SteppingMotor",
	CoreGuiType = "PlayerList Health Backpack Chat All EmotesMenu SelfView",
	HumanoidStateType = "FallingDown Ragdoll GettingUp Jumping Swimming Freefall Flying Landed Running RunningNoPhysics StrafingNoPhysics Climbing Seated PlatformStanding Dead Physics None",
	ZIndexBehavior = "Global Sibling",
	AutomaticSize = "None X Y XY",
	SizeConstraint = "RelativeXY RelativeXX RelativeYY",
	ParticleOrientation = "FacingCamera FacingCameraWorldUp VelocityParallel VelocityPerpendicular",
	ParticleEmitterShape = "Box Sphere Cylinder Disc",
	ParticleEmitterShapeStyle = "Volume Surface",
	ParticleEmitterShapeInOut = "Outward Inward InAndOut",
	Technology = "Legacy Voxel Compatibility ShadowMap Future",
	CameraType = "Fixed Watch Attach Track Follow Custom Scriptable Orbital",
	RigType = "R6 R15",
	HumanoidRigType = "R6 R15",
	HumanoidDisplayDistanceType = "Viewer Subject None",
	HumanoidHealthDisplayType = "DisplayWhenDamaged AlwaysOn AlwaysOff",
	RollOffMode = "Inverse Linear LinearSquare InverseTapered",
	ScaleType = "Stretch Slice Tile Fit Crop",
	AspectType = "FitWithinMaxSize ScaleWithParentSize",
	DominantAxis = "Width Height",
	BorderMode = "Outline Middle Inset",
	StartCorner = "TopLeft TopRight BottomLeft BottomRight",
	ScrollingDirection = "X Y XY",
	TextTruncate = "None AtEnd SplitWord",
	MouseBehavior = "Default LockCenter LockCurrentPosition",
	UserInputState = "Begin Change End Cancel None",
	ContextActionResult = "Pass Sink",
	LineJoinMode = "Round Bevel Miter",
	SurfaceGuiSizingMode = "FixedSize PixelsPerStud",
	ModelStreamingMode = "Default Atomic Persistent PersistentPerPlayer Nonatomic",
	CollisionFidelity = "Default Hull Box PreciseConvexDecomposition",
	RenderFidelity = "Automatic Precise Performance",
	ActuatorRelativeTo = "Attachment0 Attachment1 World",
}

-- Enum type names that exist (open lists: any member name is accepted).
local OPEN_ENUMS = {}
for name in ("KeyCode UserInputType Font FontWeight FontStyle ContextActionPriority DisplayDistanceType Axis Limb "
	.. "Platform DeviceType MembershipType ThumbnailType ThumbnailSize ProductPurchaseDecision InfoType AccessoryType "
	.. "BodyPart AnimationPriority CameraMode DevCameraOcclusionMode DevComputerMovementMode DevTouchMovementMode "
	.. "DevComputerCameraMovementMode DevTouchCameraMovementMode OverrideMouseIconBehavior StreamingIntegrityMode "
	.. "TextInputType TextureMode SelectionBehavior ScrollBarInset VerticalScrollBarPosition ElasticBehavior ButtonStyle "
	.. "FrameStyle TableMajorAxis UIFlexMode ItemLineAlignment MeshType ResamplerMode PathStatus PathWaypointAction "
	.. "TeleportState TeleportResult NetworkOwnership ReverbType Status ConnectionState RunContext TweenStatus "
	.. "ActuatorType EasingStyle JointType FormFactor Shape SecondaryUIFlag LevelOfDetailSetting AnimationRigType "
	.. "ChatVersion TextChatMessageStatus VRDeviceType AdornCullingMode HandlesStyle SelectionMode InputType "
	.. "GamepadType UITheme CenterDialogType CustomCameraMode LeftRight PlayerChatType RenderPriority "
	.. "SoundType CompletionState AssetType PrivilegeType MaterialPattern WaterDirection WrapLayer TerrainFace "
	.. "AvatarContextMenuOption AvatarJointUpgrade BreakpointRemoveReason ConnectionError NormalId"):gmatch("%S+") do
	OPEN_ENUMS[name] = true
end

local enumTypes = {}
local function getEnumType(name)
	local t = enumTypes[name]
	if t then
		return t
	end
	local closed = CLOSED_ENUMS[name]
	if not closed and not OPEN_ENUMS[name] and not CLOSED_ENUMS[name] then
		diag("unknown-enum", name, "Enum." .. tostring(name) .. " is not a known Roblox enum (typo? add it to OPEN_ENUMS in robloxmock.lua if it is real)")
	end
	t = setmetatable({ Name = name, _items = {}, _list = {}, _closed = closed ~= nil }, EnumTypeMT)
	enumTypes[name] = t
	if closed then
		local idx = 0
		for item in closed:gmatch("%S+") do
			local it = setmetatable({ Name = item, Value = idx, EnumType = t }, EnumItemMT)
			t._items[item] = it
			t._list[#t._list + 1] = it
			idx = idx + 1
		end
	end
	return t
end
EnumTypeMT.__index = function(self, k)
	local items = rawget(self, "_items")
	local it = items[k]
	if it then
		return it
	end
	if k == "GetEnumItems" then
		return function(t)
			local out = {}
			for i, v in ipairs(t._list) do
				out[i] = v
			end
			return out
		end
	elseif k == "FromName" then
		return function(t, name)
			return rawget(t, "_items")[name]
		end
	elseif k == "FromValue" then
		return function(t, value)
			for _, v in ipairs(t._list) do
				if v.Value == value then
					return v
				end
			end
			return nil
		end
	end
	if rawtype(k) ~= "string" then
		error(tostring(k) .. " is not a valid member of Enum." .. tostring(rawget(self, "Name")), 2)
	end
	if rawget(self, "_closed") then
		error(tostring(k) .. " is not a valid member of Enum." .. tostring(rawget(self, "Name")), 2)
	end
	local list = rawget(self, "_list")
	local newItem = setmetatable({ Name = k, Value = #list, EnumType = self }, EnumItemMT)
	items[k] = newItem
	list[#list + 1] = newItem
	return newItem
end
EnumTypeMT.__tostring = function(s)
	return "Enum." .. tostring(rawget(s, "Name"))
end
EnumItemMT.__index = function(self, k)
	if k == "IsA" then
		return function(it, typeName)
			return it.EnumType.Name == typeName
		end
	end
	error(tostring(k) .. " is not a valid member of EnumItem", 2)
end
EnumItemMT.__tostring = function(s)
	return "Enum." .. s.EnumType.Name .. "." .. s.Name
end
EnumItemMT.__newindex = function(_, k)
	error("Unable to assign property " .. tostring(k) .. ". EnumItem is read-only", 2)
end

Enum = setmetatable({}, EnumRootMT)
EnumRootMT.__index = function(_, name)
	if name == "GetEnums" then
		return function()
			local out = {}
			for _, t in pairs(enumTypes) do
				out[#out + 1] = t
			end
			return out
		end
	end
	return getEnumType(name)
end
EnumRootMT.__tostring = function()
	return "Enums"
end

enumItem = function(typeName, itemName)
	return getEnumType(typeName)[itemName]
end

-- Accept an EnumItem, or (like Roblox) the member name / numeric value; returns the EnumItem or nil.
coerceEnum = function(value, typeName)
	if typeof(value) == "EnumItem" then
		if value.EnumType.Name == typeName then
			return value
		end
		return nil
	end
	local t = getEnumType(typeName)
	if rawtype(value) == "string" then
		local ok, item = pcall(function()
			return t[value]
		end)
		return ok and item or nil
	elseif rawtype(value) == "number" then
		for _, v in ipairs(t._list) do
			if v.Value == value then
				return v
			end
		end
	end
	return nil
end

end
----------------------------------------------------------------------------------------------------
-- TweenInfo, Ray, params, Random, BrickColor, Font, DateTime, ...
----------------------------------------------------------------------------------------------------
do
local TImt = {}
regType(TImt, "TweenInfo")
TImt.__index = function(_, k)
	error(tostring(k) .. " is not a valid member of TweenInfo", 2)
end
TweenInfo = {}
function TweenInfo.new(time, style, direction, repeatCount, reverses, delayTime)
	if time ~= nil and rawtype(time) ~= "number" then
		error("invalid argument #1 to 'new' (number expected, got " .. typeof(time) .. ")", 2)
	end
	if style ~= nil and not coerceEnum(style, "EasingStyle") then
		error("invalid argument #2 to 'new' (EasingStyle expected, got " .. typeof(style) .. ")", 2)
	end
	if direction ~= nil and not coerceEnum(direction, "EasingDirection") then
		error("invalid argument #3 to 'new' (EasingDirection expected, got " .. typeof(direction) .. ")", 2)
	end
	if repeatCount ~= nil and rawtype(repeatCount) ~= "number" then
		error("invalid argument #4 to 'new' (number expected, got " .. typeof(repeatCount) .. ")", 2)
	end
	if reverses ~= nil and rawtype(reverses) ~= "boolean" then
		error("invalid argument #5 to 'new' (boolean expected, got " .. typeof(reverses) .. ")", 2)
	end
	if delayTime ~= nil and rawtype(delayTime) ~= "number" then
		error("invalid argument #6 to 'new' (number expected, got " .. typeof(delayTime) .. ")", 2)
	end
	return setmetatable({
		Time = time or 1,
		EasingStyle = coerceEnum(style or "Quad", "EasingStyle"),
		EasingDirection = coerceEnum(direction or "Out", "EasingDirection"),
		RepeatCount = repeatCount or 0,
		Reverses = reverses or false,
		DelayTime = delayTime or 0,
	}, TImt)
end

local Raymt, Raym = {}, {}
regType(Raymt, "Ray")
Raymt.__index = function(self, k)
	if Raym[k] then
		return Raym[k]
	end
	if k == "Unit" then
		return setmetatable({ Origin = self.Origin, Direction = self.Direction.Unit }, Raymt)
	end
	error(tostring(k) .. " is not a valid member of Ray", 2)
end
function Raym.ClosestPoint(r, p)
	local d = r.Direction
	local t = (p - r.Origin):Dot(d) / d:Dot(d)
	t = mmax(0, mmin(1, t))
	return r.Origin + d * t
end
function Raym.Distance(r, p)
	return (r:ClosestPoint(p) - p).Magnitude
end
Ray = {}
function Ray.new(origin, direction)
	return setmetatable({ Origin = origin, Direction = direction }, Raymt)
end

local function paramsClass(name, extra)
	local mt, m = {}, {}
	regType(mt, name)
	mt.__index = function(_, k)
		if m[k] then
			return m[k]
		end
		error(tostring(k) .. " is not a valid member of " .. name, 2)
	end
	mt.__newindex = function(self, k, v)
		if extra[k] == nil then
			error(tostring(k) .. " is not a valid member of " .. name, 2)
		end
		rawset(self, k, v)
	end
	function m.AddToFilter(self, items)
		local list = rawget(self, "FilterDescendantsInstances")
		local out = {}
		for i, v in ipairs(list) do
			out[i] = v
		end
		if rawtype(items) == "table" and typeof(items) ~= "Instance" then
			for _, v in ipairs(items) do
				out[#out + 1] = v
			end
		else
			out[#out + 1] = items
		end
		rawset(self, "FilterDescendantsInstances", out)
	end
	return {
		new = function()
			local o = { FilterDescendantsInstances = {}, FilterType = enumItem("RaycastFilterType", "Exclude"), CollisionGroup = "Default", RespectCanCollide = false, BruteForceAllSlow = false }
			for k, v in pairs(extra) do
				if o[k] == nil then
					o[k] = v
				end
			end
			return setmetatable(o, mt)
		end,
	}
end
RaycastParams = paramsClass("RaycastParams", { IgnoreWater = false, FilterDescendantsInstances = {}, FilterType = true, CollisionGroup = true, RespectCanCollide = true, BruteForceAllSlow = true })
OverlapParams = paramsClass("OverlapParams", { MaxParts = 0, FilterDescendantsInstances = {}, FilterType = true, CollisionGroup = true, RespectCanCollide = true, BruteForceAllSlow = true })

local PPmt = {}
regType(PPmt, "PhysicalProperties")
PhysicalProperties = {}
function PhysicalProperties.new(density, friction, elasticity, fw, ew)
	return setmetatable({ Density = density, Friction = friction, Elasticity = elasticity, FrictionWeight = fw or 1, ElasticityWeight = ew or 1 }, PPmt)
end

-- Random: MRG32k3a (L'Ecuyer) on doubles: deterministic, high quality, no bit operations needed.
local Rmt, Rm = {}, {}
regType(Rmt, "Random")
local M1, M2 = 4294967087, 4294944443
local autoSeed = 0
local function seedState(seed)
	seed = tonumber(seed) or 0
	local x = (seed % 4294967296)
	if x < 0 then
		x = x + 4294967296
	end
	local st = {}
	for i = 1, 6 do
		x = (x * 1664525 + 1013904223 + i * 2654435) % 4294967296
		x = (x * 22695477 + 1 + floor(seed / 4294967296)) % 4294967296
		local m = (i <= 3) and M1 or M2
		st[i] = (x % (m - 1)) + 1
	end
	return st
end
local function nextU(st)
	local p1 = 1403580 * st[2] - 810728 * st[1]
	p1 = p1 - floor(p1 / M1) * M1
	st[1], st[2], st[3] = st[2], st[3], p1
	local p2 = 527612 * st[6] - 1370589 * st[4]
	p2 = p2 - floor(p2 / M2) * M2
	st[4], st[5], st[6] = st[5], st[6], p2
	local d = p1 - p2
	if d <= 0 then
		d = d + M1
	end
	return d / (M1 + 1)
end
local function newRandom(seed)
	local st = seedState(seed)
	for _ = 1, 12 do
		nextU(st)
	end
	return setmetatable({ _st = st, _seed = seed }, Rmt)
end
Rmt.__index = function(self, k)
	if Rm[k] then
		return Rm[k]
	end
	error(tostring(k) .. " is not a valid member of Random", 2)
end
function Rm.NextNumber(self, a, b)
	local u = nextU(self._st)
	if a == nil then
		return u
	end
	if rawtype(a) ~= "number" or rawtype(b) ~= "number" then
		error("invalid argument to Random:NextNumber (min and max must both be numbers)", 2)
	end
	return a + u * (b - a)
end
function Rm.NextInteger(self, a, b)
	if rawtype(a) ~= "number" or rawtype(b) ~= "number" then
		error("invalid argument to Random:NextInteger (min and max must both be numbers)", 2)
	end
	if a > b then
		error("invalid argument #2 to 'NextInteger' (interval is empty)", 2)
	end
	return a + floor(nextU(self._st) * (b - a + 1))
end
function Rm.NextUnitVector(self)
	local z = nextU(self._st) * 2 - 1
	local t = nextU(self._st) * 2 * math.pi
	local r = sqrt(1 - z * z)
	return v3(r * cos(t), r * sin(t), z)
end
function Rm.Shuffle(self, list)
	for i = #list, 2, -1 do
		local j = 1 + floor(nextU(self._st) * i)
		list[i], list[j] = list[j], list[i]
	end
end
function Rm.Clone(self)
	local copy = setmetatable({ _st = { unpack(self._st) }, _seed = self._seed }, Rmt)
	return copy
end
Random = {}
function Random.new(seed)
	if seed == nil then
		autoSeed = autoSeed + 1
		seed = 1000003 * autoSeed + floor(Clock.now * 1000)
	end
	if rawtype(seed) ~= "number" then
		error("invalid argument #1 to 'new' (number expected, got " .. typeof(seed) .. ")", 2)
	end
	return newRandom(seed)
end

local globalRandom = newRandom(1234567)
math.random = function(a, b)
	local u = nextU(globalRandom._st)
	if a == nil then
		return u
	end
	if b == nil then
		return 1 + floor(u * a)
	end
	return a + floor(u * (b - a + 1))
end
math.randomseed = function(s)
	globalRandom = newRandom(tonumber(s) or 0)
end
end
math.clamp = function(n, lo, hi)
	if lo > hi then
		error("max must be greater than min", 2)
	end
	return n < lo and lo or (n > hi and hi or n)
end
math.sign = sign
math.round = function(n)
	return n >= 0 and floor(n + 0.5) or -floor(-n + 0.5)
end
math.noise = function(x, y, z)
	return (sin((x or 0) * 12.9898 + (y or 0) * 78.233 + (z or 0) * 37.719) * 0.5)
end
math.pow = math.pow or function(a, b)
	return a ^ b
end
math.atan2 = math.atan2 or atan2
math.log10 = math.log10 or function(x)
	return math.log(x) / math.log(10)
end
math.ldexp = nil
math.frexp = nil
math.cosh, math.sinh, math.tanh = nil, nil, nil

-- Luau string/table extensions used by Roblox code
function string.split(s, sep)
	sep = sep or ","
	local out, pos = {}, 1
	if sep == "" then
		for i = 1, #s do
			out[i] = s:sub(i, i)
		end
		return out
	end
	while true do
		local a, b = s:find(sep, pos, true)
		if not a then
			out[#out + 1] = s:sub(pos)
			break
		end
		out[#out + 1] = s:sub(pos, a - 1)
		pos = b + 1
	end
	return out
end
function table.find(t, v, init)
	for i = init or 1, #t do
		if t[i] == v then
			return i
		end
	end
	return nil
end
function table.clear(t)
	for k in pairs(t) do
		t[k] = nil
	end
end
function table.create(n, v)
	local t = {}
	if v ~= nil then
		for i = 1, n do
			t[i] = v
		end
	end
	return t
end
local frozenTables = setmetatable({}, { __mode = "k" })
function table.freeze(t)
	frozenTables[t] = true
	return t
end
function table.isfrozen(t)
	return frozenTables[t] == true
end
function table.clone(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return setmetatable(out, getmetatable(t))
end
function table.getn(t)
	return #t
end
table.getn = nil
table.maxn = nil

if not utf8 then
	utf8 = {
		charpattern = "[\0-\x7F\xC2-\xFD][\x80-\xBF]*",
		len = function(s)
			return #s
		end,
		char = function(...)
			local out = {}
			for i = 1, select("#", ...) do
				out[i] = string.char(select(i, ...) % 256)
			end
			return tconcat(out)
		end,
	}
end
if not bit32 then
	local bit = bit
	local function toU32(n)
		return n % 4294967296
	end
	if bit then
		bit32 = {
			band = function(a, b)
				return toU32(bit.band(a, b))
			end,
			bor = function(a, b)
				return toU32(bit.bor(a, b))
			end,
			bxor = function(a, b)
				return toU32(bit.bxor(a, b))
			end,
			bnot = function(a)
				return toU32(bit.bnot(a))
			end,
			lshift = function(a, n)
				return toU32(bit.lshift(a, n))
			end,
			rshift = function(a, n)
				return toU32(bit.rshift(a, n))
			end,
		}
	else
		bit32 = {}
	end
end
if debug then
	debug.profilebegin = debug.profilebegin or function() end
	debug.profileend = debug.profileend or function() end
end

do
local BCmt = {}
regType(BCmt, "BrickColor")
local BRICK_COLORS = {
	["Medium stone grey"] = { 163, 162, 165 },
	["White"] = { 242, 243, 243 },
	["Bright red"] = { 196, 40, 28 },
	["Bright blue"] = { 13, 105, 172 },
	["Bright yellow"] = { 245, 205, 48 },
	["Really black"] = { 17, 17, 17 },
	["Institutional white"] = { 248, 248, 248 },
	["Lime green"] = { 128, 187, 91 },
	["Bright green"] = { 75, 151, 75 },
	["Hot pink"] = { 255, 102, 204 },
	["Cyan"] = { 4, 175, 236 },
	["Deep orange"] = { 255, 130, 46 },
}
BrickColor = {}
local function makeBrick(name, rgb)
	rgb = rgb or { 163, 162, 165 }
	return setmetatable({ Name = name, Number = 194, r = rgb[1] / 255, g = rgb[2] / 255, b = rgb[3] / 255, Color = Color3.fromRGB(rgb[1], rgb[2], rgb[3]) }, BCmt)
end
BCmt.__index = function(self, k)
	if k == "R" then
		return self.r
	elseif k == "G" then
		return self.g
	elseif k == "B" then
		return self.b
	end
	error(tostring(k) .. " is not a valid member of BrickColor", 2)
end
BCmt.__eq = function(a, b)
	return a.Name == b.Name
end
BCmt.__tostring = function(s)
	return s.Name
end
function BrickColor.new(a, g, b)
	if rawtype(a) == "string" then
		return makeBrick(a, BRICK_COLORS[a])
	elseif getmetatable(a) == C3mt then
		return makeBrick("Custom", { floor(a.R * 255), floor(a.G * 255), floor(a.B * 255) })
	elseif rawtype(a) == "number" and g ~= nil then
		return makeBrick("Custom", { floor(a * 255), floor(g * 255), floor(b * 255) })
	end
	return makeBrick("Medium stone grey", BRICK_COLORS["Medium stone grey"])
end
function BrickColor.Random()
	return makeBrick("Bright red", BRICK_COLORS["Bright red"])
end
for name, rgb in pairs({ White = "White", Red = "Bright red", Blue = "Bright blue", Yellow = "Bright yellow", Black = "Really black", Green = "Bright green" }) do
	BrickColor[name] = function()
		return makeBrick(rgb, BRICK_COLORS[rgb])
	end
end

local Fontmt = {}
regType(Fontmt, "Font")
Fontmt.__index = function(_, k)
	error(tostring(k) .. " is not a valid member of Font", 2)
end
Font = {}
function Font.new(family, weight, style)
	return setmetatable({ Family = family, Weight = weight or enumItem("FontWeight", "Regular"), Style = style or enumItem("FontStyle", "Normal"), Bold = false }, Fontmt)
end
function Font.fromEnum(item)
	return setmetatable({ Family = "rbxasset://fonts/families/" .. tostring(item.Name) .. ".json", Weight = enumItem("FontWeight", "Regular"), Style = enumItem("FontStyle", "Normal"), Bold = false, _enum = item }, Fontmt)
end
Font.fromName = function(name)
	return Font.new("rbxasset://fonts/families/" .. tostring(name) .. ".json")
end
Font.fromId = function(id)
	return Font.new("rbxassetid://" .. tostring(id))
end

local DTmt = {}
regType(DTmt, "DateTime")
DTmt.__index = function(self, k)
	if k == "ToIsoDate" then
		return function(s)
			return realDate("!%Y-%m-%dT%H:%M:%SZ", s.UnixTimestamp)
		end
	elseif k == "FormatUniversalTime" or k == "FormatLocalTime" then
		return function(s, fmt)
			return realDate("!%Y-%m-%d %H:%M:%S", s.UnixTimestamp)
		end
	end
	error(tostring(k) .. " is not a valid member of DateTime", 2)
end
DateTime = {}
function DateTime.now()
	local t = EPOCH + Clock.now
	return setmetatable({ UnixTimestamp = floor(t), UnixTimestampMillis = floor(t * 1000) }, DTmt)
end
function DateTime.fromUnixTimestamp(s)
	return setmetatable({ UnixTimestamp = floor(s), UnixTimestampMillis = floor(s * 1000) }, DTmt)
end

local Region3mt = {}
regType(Region3mt, "Region3")
Region3 = {}
function Region3.new(minv, maxv)
	local size = maxv - minv
	return setmetatable({ CFrame = CFrame.new((minv + maxv) * 0.5), Size = size }, Region3mt)
end
Axes = { new = function()
	return {}
end }
Faces = { new = function()
	return {}
end }

end
local function proxyAny(name)
	return setmetatable({}, {
		__index = function(_, k)
			return proxyAny(name .. "." .. tostring(k))
		end,
		__call = function()
			return proxyAny(name .. "()")
		end,
		__tostring = function()
			return name
		end,
	})
end

----------------------------------------------------------------------------------------------------
-- Instances: state, classes, hierarchy
----------------------------------------------------------------------------------------------------
local STATE = {} -- unique key under which every instance keeps its private state
local InstMT = {}
regType(InstMT, "Instance")

local Classes = {} -- class name -> class record
local ClassOrder = {}
local Creatable = {} -- set of names Instance.new accepts (Mock.Configure fills it from roblox-api.json)
local CreatableConfigured = false
local AllInstances = setmetatable({}, { __mode = "k" })
local TagIndex = {} -- tag -> weak set of instances
local TagSignals = {} -- tag -> { added = signal, removed = signal }
local PendingWaits = {}

Mock.Viewport = nil -- set below (Vector2)
Mock.GuiEpoch = 0 -- bumped by every GUI property / hierarchy change (invalidates the layout caches)

local function isInstance(v)
	return rawtype(v) == "table" and getmetatable(v) == InstMT
end


-- Property spec constructors ---------------------------------------------------------------------
local function lazyDefault(ty, make)
	return { ty = ty, lazy = true, make = make }
end
local T = {}
function T.bool(d)
	return { ty = "boolean", def = d }
end
-- lo / hi (optional): the range the engine accepts. Writing outside it is clamped (like Roblox) and
-- recorded as an "out-of-range" diagnostic, which the smoke test treats as a failure.
function T.num(d, lo, hi)
	return { ty = "number", def = d, lo = lo, hi = hi }
end
function T.str(d)
	return { ty = "string", def = d }
end
function T.v3(x, y, z)
	return lazyDefault("Vector3", function()
		return v3(x or 0, y or 0, z or 0)
	end)
end
function T.v2(x, y)
	return lazyDefault("Vector2", function()
		return v2(x or 0, y or 0)
	end)
end
function T.rgb(r, g, b)
	return lazyDefault("Color3", function()
		return Color3.fromRGB(r, g, b)
	end)
end
function T.u2(xs, xo, ys, yo)
	return lazyDefault("UDim2", function()
		return u2(xs or 0, xo or 0, ys or 0, yo or 0)
	end)
end
function T.ud(s, o)
	return lazyDefault("UDim", function()
		return ud(s or 0, o or 0)
	end)
end
function T.cf()
	return lazyDefault("CFrame", function()
		return CF_IDENTITY
	end)
end
function T.enum(typeName, itemName)
	return lazyDefault("Enum." .. typeName, function()
		return enumItem(typeName, itemName)
	end)
end
function T.inst()
	return { ty = "Instance" }
end
function T.any(d)
	return { ty = "any", def = d }
end
function T.nr(a, b)
	return lazyDefault("NumberRange", function()
		return NumberRange.new(a, b)
	end)
end
function T.ns(v)
	return lazyDefault("NumberSequence", function()
		return NumberSequence.new(v)
	end)
end
function T.cs(r, g, b)
	return lazyDefault("ColorSequence", function()
		return ColorSequence.new(Color3.fromRGB(r, g, b))
	end)
end
function T.font()
	return lazyDefault("Font", function()
		return Font.fromEnum(enumItem("Font", "SourceSans"))
	end)
end
function T.brick()
	return lazyDefault("BrickColor", function()
		return BrickColor.new("Medium stone grey")
	end)
end

local function specDefault(spec)
	if spec.lazy then
		local v = spec.value
		if v == nil then
			v = spec.make()
			spec.value = v
		end
		return v
	end
	return spec.def
end

local function describe(ty)
	if ty:sub(1, 5) == "Enum." then
		return "Enum " .. ty:sub(6)
	end
	return ty
end

-- Returns ok, normalisedValue
local function conforms(ty, v)
	if ty == "any" then
		return true, v
	end
	local tv = typeof(v)
	if ty == "Instance" then
		return (v == nil or tv == "Instance"), v
	end
	if ty:sub(1, 5) == "Enum." then
		local item = coerceEnum(v, ty:sub(6))
		return item ~= nil, item
	end
	return tv == ty, v
end

-- Instance helpers ---------------------------------------------------------------------------------
local function className(inst)
	return inst[STATE].class.name
end

local function fullName(inst)
	local parts = {}
	local cur = inst
	while cur and cur ~= Mock.game do
		local st = cur[STATE]
		parts[#parts + 1] = st.name
		cur = st.parent
	end
	local out = {}
	for i = #parts, 1, -1 do
		out[#out + 1] = parts[i]
	end
	return tconcat(out, ".")
end
Mock.FullName = fullName

local function isInGame(inst)
	local cur = inst
	while cur do
		if cur == Mock.game then
			return true
		end
		cur = cur[STATE].parent
	end
	return false
end

local function removeFromList(list, item)
	for i = #list, 1, -1 do
		if list[i] == item then
			tremove(list, i)
			return true
		end
	end
	return false
end

local function findChildByName(st, name)
	local children = st.children
	for i = 1, #children do
		local c = children[i]
		if c[STATE].name == name then
			return c
		end
	end
	return nil
end

local function eachDescendant(inst, fn)
	local children = inst[STATE].children
	for i = 1, #children do
		local c = children[i]
		fn(c)
		eachDescendant(c, fn)
	end
end

local function getSignal(inst, st, name)
	local sig = st.signals[name]
	if not sig then
		local hook = nil
		if name == "Touched" or name == "TouchEnded" then
			hook = Mock._onTouchConnect
		end
		sig = newSignal(st.class.name .. "." .. name, hook)
		sig._owner = inst
		st.signals[name] = sig
	end
	return sig
end

local function fireEvent(st, name, ...)
	local sig = st.signals[name]
	if sig and (#sig._conns > 0 or #sig._waiters > 0) then
		sig:Fire(...)
	end
end

local function hasListeners(st, name)
	local sig = st.signals[name]
	return sig ~= nil and (#sig._conns > 0 or #sig._waiters > 0)
end

local function firePropChanged(inst, st, key)
	local ps = st.propSignals[key]
	if ps and (#ps._conns > 0 or #ps._waiters > 0) then
		ps:Fire()
	end
	if hasListeners(st, "Changed") then
		if key == "Value" and st.class.isA.ValueBase then
			st.signals.Changed:Fire(st.props.Value) -- ValueBase.Changed passes the new value
		else
			st.signals.Changed:Fire(key)
		end
	end
end

-- Tag signals for entering / leaving the DataModel
local function tagEvents(inst, entering)
	if next(TagSignals) == nil then
		return
	end
	local function visit(node)
		local nst = node[STATE]
		for tag in pairs(nst.tags) do
			local ts = TagSignals[tag]
			if ts then
				local sig = entering and ts.added or ts.removed
				if sig then
					sig:Fire(node)
				end
			end
		end
	end
	visit(inst)
	eachDescendant(inst, visit)
end

local function fireAncestry(inst, newParent)
	local st = inst[STATE]
	fireEvent(st, "AncestryChanged", inst, newParent)
	local children = st.children
	for i = 1, #children do
		fireAncestry(children[i], children[i][STATE].parent)
	end
end

local function ancestorsListening(parent, eventName)
	local cur = parent
	while cur do
		local pst = cur[STATE]
		if hasListeners(pst, eventName) then
			return true
		end
		cur = pst.parent
	end
	return false
end

local function setParentRaw(inst, st, newParent)
	local old = st.parent
	if old == newParent then
		return
	end
	local wasInGame = old ~= nil and isInGame(old)
	if old then
		-- DescendantRemoving on the old ancestors
		if ancestorsListening(old, "DescendantRemoving") then
			local cur = old
			while cur do
				local cst = cur[STATE]
				if hasListeners(cst, "DescendantRemoving") then
					cst.signals.DescendantRemoving:Fire(inst)
					eachDescendant(inst, function(d)
						cst.signals.DescendantRemoving:Fire(d)
					end)
				end
				cur = cst.parent
			end
		end
		removeFromList(old[STATE].children, inst)
	end
	st.parent = newParent
	if newParent then
		local pst = newParent[STATE]
		pst.children[#pst.children + 1] = inst
	end
	if st.class.guiish then
		Mock.GuiEpoch = Mock.GuiEpoch + 1
	end
	local nowInGame = newParent ~= nil and isInGame(newParent)
	if wasInGame and not nowInGame then
		tagEvents(inst, false)
	end
	fireAncestry(inst, newParent)
	if old then
		fireEvent(old[STATE], "ChildRemoved", inst)
	end
	if newParent then
		local pst = newParent[STATE]
		fireEvent(pst, "ChildAdded", inst)
		if ancestorsListening(newParent, "DescendantAdded") then
			local cur = newParent
			while cur do
				local cst = cur[STATE]
				if hasListeners(cst, "DescendantAdded") then
					cst.signals.DescendantAdded:Fire(inst)
					eachDescendant(inst, function(d)
						cst.signals.DescendantAdded:Fire(d)
					end)
				end
				cur = cst.parent
			end
		end
	end
	if nowInGame and not wasInGame then
		tagEvents(inst, true)
	end
	firePropChanged(inst, st, "Parent")
end

local function setParent(inst, st, newParent)
	if newParent ~= nil and not isInstance(newParent) then
		error("Unable to assign property Parent. Object expected, got " .. typeof(newParent), 3)
	end
	if st.destroyed then
		if newParent ~= nil then
			error(sformat("The Parent property of %s is locked, current parent: NULL, new parent %s", st.name, newParent[STATE].name), 3)
		end
		return
	end
	if newParent ~= nil then
		local nst = newParent[STATE]
		if nst.destroyed then
			error(sformat("The Parent property of %s is locked, current parent: %s, new parent %s", st.name, st.parent and st.parent[STATE].name or "NULL", nst.name), 3)
		end
		local a = newParent
		while a do
			if a == inst then
				error("Attempt to set " .. fullName(inst) .. " as its own ancestor or descendant", 3)
			end
			a = a[STATE].parent
		end
		if st.class.isService and newParent ~= Mock.game then
			error("Unable to set the Parent of a service", 3)
		end
	end
	setParentRaw(inst, st, newParent)
end

local function destroy(inst)
	local st = inst[STATE]
	if st.destroyed then
		return
	end
	fireEvent(st, "Destroying")
	if st.parent then
		setParentRaw(inst, st, nil)
	end
	st.destroyed = true
	local children = st.children
	for i = #children, 1, -1 do
		local c = children[i]
		if c then
			destroy(c)
		end
	end
	for _, sig in pairs(st.signals) do
		sig:DisconnectAll()
	end
	for _, sig in pairs(st.propSignals) do
		sig:DisconnectAll()
	end
	for _, sig in pairs(st.attrSignals) do
		sig:DisconnectAll()
	end
	if Mock._onDestroy then
		Mock._onDestroy(inst, st)
	end
end

-- Property access ------------------------------------------------------------------------------------
local function unknownMember(self, st, key)
	local msg = tostring(key) .. " is not a valid member of " .. st.class.name .. " \"" .. fullName(self) .. "\""
	if st.class.generic then
		diag("mock-gap", st.class.name .. "." .. tostring(key), "class " .. st.class.name .. " has no property model in robloxmock.lua; read of '" .. tostring(key) .. "' returned nil")
		return nil
	end
	if Mock.Options.StrictMembers then
		error(msg, 3)
	end
	diag("unknown-member", st.class.name .. "." .. tostring(key), msg)
	return nil
end

InstMT.__index = function(self, key)
	local st = self[STATE]
	local v = st.props[key]
	if v ~= nil then
		return v
	end
	local class = st.class
	local getter = class.getters[key]
	if getter then
		return getter(self, st)
	end
	local method = class.methods[key]
	if method then
		return method
	end
	local spec = class.propspec[key]
	if spec then
		if spec.lazy then
			return specDefault(spec)
		end
		return spec.def
	end
	if class.events[key] then
		return getSignal(self, st, key)
	end
	if rawtype(key) == "string" then
		local child = findChildByName(st, key)
		if child then
			return child
		end
	end
	return unknownMember(self, st, key)
end

InstMT.__newindex = function(self, key, value)
	local st = self[STATE]
	local class = st.class
	local setter = class.setters[key]
	if setter then
		return setter(self, st, value)
	end
	local spec = class.propspec[key]
	if spec then
		local ok, norm = conforms(spec.ty, value)
		if not ok then
			error(sformat("Unable to assign property %s. %s expected, got %s", tostring(key), describe(spec.ty), typeof(value)), 2)
		end
		if spec.ty == "number" and (spec.lo or spec.hi) then
			local clamped = norm
			if spec.lo and clamped < spec.lo then
				clamped = spec.lo
			end
			if spec.hi and clamped > spec.hi then
				clamped = spec.hi
			end
			if clamped ~= norm then
				diag("out-of-range", class.name .. "." .. key, class.name .. "." .. key .. " was set to " .. tostring(norm)
					.. " but Roblox only accepts " .. tostring(spec.lo) .. ".." .. tostring(spec.hi) .. " (clamped to " .. tostring(clamped) .. ")")
				norm = clamped
			end
		end
		local old = st.props[key]
		if old == nil then
			if spec.lazy then
				old = specDefault(spec)
			else
				old = spec.def
			end
		end
		if old ~= norm then
			st.props[key] = norm
			if class.guiish then
				Mock.GuiEpoch = Mock.GuiEpoch + 1
			end
			if st.onProp then
				st.onProp(self, st, key, norm)
			end
			firePropChanged(self, st, key)
		end
		return
	end
	if class.getters[key] or class.methods[key] or class.events[key] then
		error("Unable to assign property " .. tostring(key) .. ". Property is read only", 2)
	end
	if rawtype(key) ~= "string" then
		error("Unable to assign property " .. tostring(key) .. ". Invalid property name", 2)
	end
	local msg = tostring(key) .. " is not a valid member of " .. class.name .. " \"" .. fullName(self) .. "\""
	if class.generic then
		diag("mock-gap", class.name .. "." .. key, "class " .. class.name .. " has no property model in robloxmock.lua; wrote '" .. key .. "'")
	elseif Mock.Options.StrictMembers then
		error(msg, 2)
	else
		diag("unknown-member", class.name .. "." .. key, msg .. " (write)")
	end
	st.props[key] = value
end
InstMT.__tostring = function(self)
	return self[STATE].name
end

-- Class registry -------------------------------------------------------------------------------------
local function defclass(name, super, def)
	def = def or {}
	local class = {
		name = name,
		superName = super,
		own = def,
		creatable = def.creatable,
		isService = def.service,
		generic = def.generic,
	}
	Classes[name] = class
	ClassOrder[#ClassOrder + 1] = class
	return class
end

local function finalizeClass(class)
	if class.final then
		return class
	end
	local super = class.superName and Classes[class.superName] or nil
	if class.superName and not super then
		error("robloxmock: unknown superclass " .. class.superName .. " for " .. class.name)
	end
	if super then
		finalizeClass(super)
	end
	class.propspec, class.methods, class.events, class.getters, class.setters, class.isA = {}, {}, {}, {}, {}, { [class.name] = true }
	if super then
		for k, v in pairs(super.propspec) do
			class.propspec[k] = v
		end
		for k, v in pairs(super.methods) do
			class.methods[k] = v
		end
		for k, v in pairs(super.events) do
			class.events[k] = v
		end
		for k, v in pairs(super.getters) do
			class.getters[k] = v
		end
		for k, v in pairs(super.setters) do
			class.setters[k] = v
		end
		for k in pairs(super.isA) do
			class.isA[k] = true
		end
		class.inits = {}
		for i, f in ipairs(super.inits) do
			class.inits[i] = f
		end
	else
		class.inits = {}
	end
	local def = class.own
	for k, spec in pairs(def.props or {}) do
		-- each class gets its own copy so lazy caches are not shared incorrectly
		class.propspec[k] = spec
		class.getters[k] = nil
		class.setters[k] = nil
	end
	for k, f in pairs(def.methods or {}) do
		class.methods[k] = f
	end
	for _, e in ipairs(def.events or {}) do
		class.events[e] = true
	end
	for k, f in pairs(def.getters or {}) do
		class.getters[k] = f
		class.propspec[k] = nil
	end
	for k, f in pairs(def.setters or {}) do
		class.setters[k] = f
	end
	if def.init then
		class.inits[#class.inits + 1] = def.init
	end
	class.guiish = (class.isA.GuiBase2d or class.isA.UIBase) and true or false
	class.final = true
	return class
end

local function makeInstance(cname)
	local class = Classes[cname]
	if not class then
		-- A creatable class that robloxmock.lua has no model for: a generic, permissive Instance.
		class = defclass(cname, "Instance", { generic = true })
	end
	finalizeClass(class)
	local inst = setmetatable({}, InstMT)
	local st = {
		class = class,
		name = cname,
		parent = nil,
		children = {},
		props = {},
		attrs = {},
		tags = {},
		signals = {},
		propSignals = {},
		attrSignals = {},
		destroyed = false,
	}
	rawset(inst, STATE, st)
	AllInstances[inst] = true
	for _, init in ipairs(class.inits) do
		init(inst, st)
	end
	return inst
end
Mock.MakeInstance = makeInstance

Instance = {}
function Instance.new(cname, parent)
	if rawtype(cname) ~= "string" then
		error("Argument 1 missing or nil", 2)
	end
	if CreatableConfigured and not Creatable[cname] then
		error('Unable to create an Instance of type "' .. cname .. '"', 2)
	end
	local cls = Classes[cname]
	if cls and cls.creatable == false then
		error('Unable to create an Instance of type "' .. cname .. '"', 2)
	end
	local inst = makeInstance(cname)
	if parent ~= nil then
		setParent(inst, inst[STATE], parent)
	end
	return inst
end
setmetatable(Instance, {
	__index = function(_, k)
		error(tostring(k) .. " is not a valid member of Instance", 2)
	end,
})

function Mock.Configure(opts)
	opts = opts or {}
	if opts.creatableClasses then
		Creatable = {}
		for _, n in ipairs(opts.creatableClasses) do
			Creatable[n] = true
		end
		CreatableConfigured = true
	end
	if opts.services then
		Mock.KnownServices = {}
		for _, n in ipairs(opts.services) do
			Mock.KnownServices[n] = true
		end
	end
	if opts.options then
		for k, v in pairs(opts.options) do
			Mock.Options[k] = v
		end
	end
end

-- Instance methods -----------------------------------------------------------------------------------
local IM = {} -- methods shared by every Instance

function IM.Destroy(self)
	destroy(self)
end
IM.destroy = nil
function IM.Remove(self)
	diag("deprecated", "Instance:Remove()", "Instance:Remove() is deprecated, use :Destroy()")
	setParent(self, self[STATE], nil)
end
function IM.ClearAllChildren(self)
	local children = self[STATE].children
	for i = #children, 1, -1 do
		if children[i] then
			destroy(children[i])
		end
	end
end
function IM.GetChildren(self)
	local out = {}
	local children = self[STATE].children
	for i = 1, #children do
		out[i] = children[i]
	end
	return out
end
function IM.GetDescendants(self)
	local out = {}
	eachDescendant(self, function(d)
		out[#out + 1] = d
	end)
	return out
end
function IM.FindFirstChild(self, name, recursive)
	if rawtype(name) ~= "string" then
		error("Argument 1 missing or nil", 2)
	end
	local st = self[STATE]
	local c = findChildByName(st, name)
	if c or not recursive then
		return c
	end
	local found
	local function search(node)
		local children = node[STATE].children
		for i = 1, #children do
			if children[i][STATE].name == name then
				found = children[i]
				return true
			end
		end
		for i = 1, #children do
			if search(children[i]) then
				return true
			end
		end
		return false
	end
	search(self)
	return found
end
IM.FindFirstDescendant = function(self, name)
	return IM.FindFirstChild(self, name, true)
end
function IM.FindFirstChildOfClass(self, cname)
	local children = self[STATE].children
	for i = 1, #children do
		if children[i][STATE].class.name == cname then
			return children[i]
		end
	end
	return nil
end
function IM.FindFirstChildWhichIsA(self, cname, recursive)
	local children = self[STATE].children
	for i = 1, #children do
		if children[i][STATE].class.isA[cname] then
			return children[i]
		end
	end
	if recursive then
		for i = 1, #children do
			local r = IM.FindFirstChildWhichIsA(children[i], cname, true)
			if r then
				return r
			end
		end
	end
	return nil
end
function IM.FindFirstAncestor(self, name)
	local cur = self[STATE].parent
	while cur do
		if cur[STATE].name == name then
			return cur
		end
		cur = cur[STATE].parent
	end
	return nil
end
function IM.FindFirstAncestorOfClass(self, cname)
	local cur = self[STATE].parent
	while cur do
		if cur[STATE].class.name == cname then
			return cur
		end
		cur = cur[STATE].parent
	end
	return nil
end
function IM.FindFirstAncestorWhichIsA(self, cname)
	local cur = self[STATE].parent
	while cur do
		if cur[STATE].class.isA[cname] then
			return cur
		end
		cur = cur[STATE].parent
	end
	return nil
end
function IM.IsA(self, cname)
	return self[STATE].class.isA[cname] == true
end
function IM.IsDescendantOf(self, ancestor)
	if not isInstance(ancestor) then
		error("Argument 1 missing or nil", 2)
	end
	local cur = self[STATE].parent
	while cur do
		if cur == ancestor then
			return true
		end
		cur = cur[STATE].parent
	end
	return false
end
function IM.IsAncestorOf(self, descendant)
	return descendant ~= self and IM.IsDescendantOf(descendant, self)
end
function IM.GetFullName(self)
	return fullName(self)
end
function IM.GetDebugId(self)
	return tostring(self)
end
function IM.WaitForChild(self, name, timeout)
	if rawtype(name) ~= "string" then
		error("Argument 1 missing or nil", 2)
	end
	local st = self[STATE]
	local c = findChildByName(st, name)
	if c then
		return c
	end
	if isMainThread() then
		-- driver code: give other threads a chance to create it
		local ok = Mock.AdvanceUntil(function()
			return findChildByName(st, name) ~= nil
		end, timeout or 10)
		return ok and findChildByName(st, name) or nil
	end
	local co = coroutine.running()
	local done = false
	local entry = { inst = self, name = name, since = Clock.now, timeout = timeout }
	PendingWaits[entry] = true
	local conn
	local function finish(result)
		if done then
			return
		end
		done = true
		PendingWaits[entry] = nil
		if conn then
			conn:Disconnect()
		end
		resume(co, result)
	end
	conn = getSignal(self, st, "ChildAdded"):Connect(function(child)
		if child[STATE].name == name then
			finish(child)
		end
	end)
	if timeout then
		task.delay(timeout, function()
			finish(nil)
		end)
	else
		task.delay(5, function()
			if not done then
				diag("infinite-yield", fullName(self) .. ":WaitForChild(\"" .. name .. "\")", "Infinite yield possible on " .. fullName(self) .. ":WaitForChild(\"" .. name .. "\")")
			end
		end)
	end
	return coroutine.yield()
end
function IM.Clone(self)
	local st = self[STATE]
	if st.props.Archivable == false then
		return nil
	end
	local map = {} -- original -> clone, so references inside the cloned tree can be remapped (like Roblox does)
	local function cloneNode(node)
		local nst = node[STATE]
		if nst.props.Archivable == false then
			return nil
		end
		local copy = makeInstance(nst.class.name)
		map[node] = copy
		local cst = copy[STATE]
		cst.name = nst.name
		for k, v in pairs(nst.props) do
			cst.props[k] = v
		end
		for k, v in pairs(nst.attrs) do
			cst.attrs[k] = v
		end
		for tag in pairs(nst.tags) do
			cst.tags[tag] = true
			TagIndex[tag] = TagIndex[tag] or setmetatable({}, { __mode = "k" })
			TagIndex[tag][copy] = true
		end
		for _, child in ipairs(nst.children) do
			local cc = cloneNode(child)
			if cc then
				setParentRaw(cc, cc[STATE], copy)
			end
		end
		return copy
	end
	local root = cloneNode(self)
	-- Object-valued properties (Model.PrimaryPart, WeldConstraint.Part0/Part1, ObjectValue.Value ...) that point
	-- into the cloned tree now point at the clones
	if root then
		for _, copy in pairs(map) do
			local props = copy[STATE].props
			for k, v in pairs(props) do
				if rawtype(v) ~= "number" and rawtype(v) ~= "string" and rawtype(v) ~= "boolean" and isInstance(v) and map[v] then
					props[k] = map[v]
				end
			end
		end
	end
	return root
end

-- attributes
local ATTR_TYPES = {
	string = true, boolean = true, number = true, UDim = true, UDim2 = true, BrickColor = true, Color3 = true,
	Vector2 = true, Vector3 = true, NumberSequence = true, ColorSequence = true, NumberRange = true, Rect = true,
	Font = true, CFrame = true,
}
Mock._attrHooks = {}
function IM.SetAttribute(self, name, value)
	if rawtype(name) ~= "string" then
		error("Argument 1 missing or nil", 2)
	end
	if #name > 100 then
		error("Attribute name too long", 2)
	end
	if name:find("^RBX") then
		error("Attribute name cannot begin with RBX", 2)
	end
	if name:find("[^%w_ ]") then
		error("Attribute name can only contain alphanumeric characters, underscores and spaces: " .. name, 2)
	end
	if value ~= nil and not ATTR_TYPES[typeof(value)] then
		error("attempt to set attribute '" .. name .. "' to unsupported type '" .. typeof(value) .. "'", 2)
	end
	local st = self[STATE]
	local old = st.attrs[name]
	if old == value then
		return
	end
	st.attrs[name] = value
	local sig = st.attrSignals[name]
	if sig and #sig._conns + #sig._waiters > 0 then
		sig:Fire()
	end
	fireEvent(st, "AttributeChanged", name)
	local hook = Mock._onAttribute
	if hook then
		hook(self, st, name, value)
	end
end
function IM.GetAttribute(self, name)
	if rawtype(name) ~= "string" then
		error("Argument 1 missing or nil", 2)
	end
	return self[STATE].attrs[name]
end
function IM.GetAttributes(self)
	local out = {}
	for k, v in pairs(self[STATE].attrs) do
		out[k] = v
	end
	return out
end
function IM.GetAttributeChangedSignal(self, name)
	local st = self[STATE]
	local sig = st.attrSignals[name]
	if not sig then
		sig = newSignal(st.class.name .. ".AttributeChanged:" .. tostring(name))
		st.attrSignals[name] = sig
	end
	return sig
end
function IM.GetPropertyChangedSignal(self, prop)
	local st = self[STATE]
	local class = st.class
	if not (class.propspec[prop] or class.getters[prop] or class.setters[prop]) and not class.generic then
		error(tostring(prop) .. " is not a valid property name.", 2)
	end
	local sig = st.propSignals[prop]
	if not sig then
		sig = newSignal(class.name .. ".Changed:" .. tostring(prop))
		st.propSignals[prop] = sig
	end
	return sig
end

-- tags (Instance:AddTag etc. and CollectionService share this)
local function addTag(inst, tag)
	local st = inst[STATE]
	if st.tags[tag] then
		return
	end
	st.tags[tag] = true
	local set = TagIndex[tag]
	if not set then
		set = setmetatable({}, { __mode = "k" })
		TagIndex[tag] = set
	end
	set[inst] = true
	local ts = TagSignals[tag]
	if ts and ts.added and isInGame(inst) then
		ts.added:Fire(inst)
	end
end
local function removeTag(inst, tag)
	local st = inst[STATE]
	if not st.tags[tag] then
		return
	end
	st.tags[tag] = nil
	local set = TagIndex[tag]
	if set then
		set[inst] = nil
	end
	local ts = TagSignals[tag]
	if ts and ts.removed and isInGame(inst) then
		ts.removed:Fire(inst)
	end
end
function IM.AddTag(self, tag)
	addTag(self, tag)
end
function IM.RemoveTag(self, tag)
	removeTag(self, tag)
end
function IM.HasTag(self, tag)
	return self[STATE].tags[tag] == true
end
function IM.GetTags(self)
	local out = {}
	for tag in pairs(self[STATE].tags) do
		out[#out + 1] = tag
	end
	tsort(out)
	return out
end

Mock._internals = {
	STATE = STATE, getSignal = getSignal, fireEvent = fireEvent, hasListeners = hasListeners, destroy = destroy,
	setParent = setParent, setParentRaw = setParentRaw, isInGame = isInGame, findChildByName = findChildByName,
	eachDescendant = eachDescendant, addTag = addTag, removeTag = removeTag, TagIndex = TagIndex, TagSignals = TagSignals,
	firePropChanged = firePropChanged, className = className, isInstance = isInstance, PendingWaits = PendingWaits,
	AllInstances = AllInstances, resume = resume, fullName = fullName,
}

----------------------------------------------------------------------------------------------------
-- Class definitions
----------------------------------------------------------------------------------------------------
local touchRegistry = setmetatable({}, { __mode = "k" }) -- parts that have Touched/TouchEnded listeners
Mock._onTouchConnect = function(sig)
	local owner = sig._owner
	if owner then
		touchRegistry[owner] = true
	end
end
Mock._touchRegistry = touchRegistry

local function nanCheck(cfv, what)
	if cfv.x ~= cfv.x or cfv.y ~= cfv.y or cfv.z ~= cfv.z or cfv.a ~= cfv.a then
		diag("nan", what, "NaN assigned to " .. what .. " (a bad Unit / division by zero upstream?)")
	end
end

defclass("Instance", nil, {
	creatable = false,
	props = { Archivable = T.bool(true) },
	getters = {
		ClassName = function(_, st)
			return st.class.name
		end,
		Name = function(_, st)
			return st.name
		end,
		Parent = function(_, st)
			return st.parent
		end,
	},
	setters = {
		Name = function(self, st, v)
			if rawtype(v) ~= "string" then
				error("Unable to assign property Name. string expected, got " .. typeof(v), 3)
			end
			if st.name ~= v then
				st.name = v
				if st.class.guiish then
					Mock.GuiEpoch = Mock.GuiEpoch + 1
				end
				firePropChanged(self, st, "Name")
			end
		end,
		Parent = function(self, st, v)
			setParent(self, st, v)
		end,
	},
	methods = IM,
	events = { "Changed", "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "AncestryChanged", "Destroying", "AttributeChanged" },
})

-- group of parts that must move together with `part` (character body, rigid welds)
Mock._welds = setmetatable({}, { __mode = "k" }) -- part -> { [weldInstance] = true }
local function weldPartners(part)
	local out, seen, queue = {}, { [part] = true }, { part }
	local qi = 1
	while queue[qi] do
		local p = queue[qi]
		qi = qi + 1
		local set = Mock._welds[p]
		if set then
			for w in pairs(set) do
				local wst = w[STATE]
				if not wst.destroyed and wst.props.Enabled ~= false then
					local a, b = wst.props.Part0, wst.props.Part1
					local other = (a == p) and b or a
					if other and not seen[other] then
						seen[other] = true
						out[#out + 1] = other
						queue[#queue + 1] = other
					end
				end
			end
		end
	end
	return out
end

local function isCharacterRoot(part, st)
	if st.name ~= "HumanoidRootPart" then
		return false
	end
	local model = st.parent
	return model ~= nil and IM.FindFirstChildOfClass(model, "Humanoid") ~= nil
end

local function currentCFrame(st)
	return st.props.CFrame or CF_IDENTITY
end

local function applyCFrame(part, st, v, propagate)
	local old = currentCFrame(st)
	st.props.CFrame = v
	firePropChanged(part, st, "CFrame")
	firePropChanged(part, st, "Position")
	if propagate then
		local delta = v * old:Inverse()
		local moved = weldPartners(part)
		if isCharacterRoot(part, st) then
			for _, sib in ipairs(st.parent[STATE].children) do
				if sib ~= part and sib[STATE].class.isA.BasePart then
					moved[#moved + 1] = sib
				end
			end
		end
		for _, other in ipairs(moved) do
			local ost = other[STATE]
			applyCFrame(other, ost, delta * currentCFrame(ost), false)
		end
	end
end
Mock.ApplyCFrame = function(part, v)
	applyCFrame(part, part[STATE], v, true)
end

local function degrees(r)
	return r * 180 / math.pi
end

defclass("PVInstance", "Instance", { creatable = false })

local function modelParts(model)
	local out = {}
	eachDescendant(model, function(d)
		if d[STATE].class.isA.BasePart then
			out[#out + 1] = d
		end
	end)
	return out
end

local function partExtents(part)
	local st = part[STATE]
	local c = currentCFrame(st)
	local size = st.props.Size or v3(4, 1, 2)
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local ex = abs(c.a) * hx + abs(c.b) * hy + abs(c.c) * hz
	local ey = abs(c.d) * hx + abs(c.e) * hy + abs(c.f) * hz
	local ez = abs(c.g) * hx + abs(c.h) * hy + abs(c.i) * hz
	return c.x - ex, c.y - ey, c.z - ez, c.x + ex, c.y + ey, c.z + ez
end

local function boundingBox(model)
	local parts = modelParts(model)
	if #parts == 0 then
		return CF_IDENTITY, v3(0, 0, 0)
	end
	local x0, y0, z0, x1, y1, z1 = huge, huge, huge, -huge, -huge, -huge
	for _, p in ipairs(parts) do
		local ax, ay, az, bx, by, bz = partExtents(p)
		x0, y0, z0 = mmin(x0, ax), mmin(y0, ay), mmin(z0, az)
		x1, y1, z1 = mmax(x1, bx), mmax(y1, by), mmax(z1, bz)
	end
	return cf((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2, 1, 0, 0, 0, 1, 0, 0, 0, 1), v3(x1 - x0, y1 - y0, z1 - z0)
end

local function modelPivot(model)
	local st = model[STATE]
	local primary = st.props.PrimaryPart
	if primary and not primary[STATE].destroyed then
		local pst = primary[STATE]
		return currentCFrame(pst) * (pst.props.PivotOffset or CF_IDENTITY)
	end
	if st.props.WorldPivot then
		return st.props.WorldPivot
	end
	local box = boundingBox(model)
	return box
end

local function pivotTo(inst, target)
	if typeof(target) ~= "CFrame" then
		error("invalid argument #1 to 'PivotTo' (CFrame expected, got " .. typeof(target) .. ")", 3)
	end
	local st = inst[STATE]
	if st.class.isA.BasePart then
		Mock.ApplyCFrame(inst, target * (st.props.PivotOffset or CF_IDENTITY):Inverse())
		return
	end
	local pivot = modelPivot(inst)
	local delta = target * pivot:Inverse()
	-- With a PrimaryPart the primary is set EXACTLY from the target and the other parts keep their offset to
	-- it. (Composing `delta * current` for every part lets the rounding error of the transpose-as-inverse
	-- square itself on each call: after ~60 PivotTo calls a pet that is moved every frame becomes NaN, which
	-- real Roblox never does.)
	local primary = st.props.PrimaryPart
	local newPrimary, oldPrimaryInv
	if primary and not primary[STATE].destroyed then
		local pst = primary[STATE]
		newPrimary = target * (pst.props.PivotOffset or CF_IDENTITY):Inverse()
		oldPrimaryInv = currentCFrame(pst):Inverse()
	end
	for _, p in ipairs(modelParts(inst)) do
		local pst = p[STATE]
		if newPrimary and p == primary then
			applyCFrame(p, pst, newPrimary, false)
		elseif newPrimary then
			applyCFrame(p, pst, newPrimary * (oldPrimaryInv * currentCFrame(pst)), false)
		else
			applyCFrame(p, pst, delta * currentCFrame(pst), false)
		end
	end
	if st.props.WorldPivot then
		st.props.WorldPivot = target
	end
end

defclass("Model", "PVInstance", {
	creatable = true,
	props = { PrimaryPart = T.inst(), WorldPivot = T.cf(), ModelStreamingMode = T.enum("ModelStreamingMode", "Default"), LevelOfDetail = T.any("Automatic") },
	methods = {
		GetPivot = function(self)
			return modelPivot(self)
		end,
		PivotTo = function(self, cfv)
			pivotTo(self, cfv)
		end,
		MoveTo = function(self, pos)
			local pivot = modelPivot(self)
			pivotTo(self, cf(pos.X, pos.Y, pos.Z, pivot.a, pivot.b, pivot.c, pivot.d, pivot.e, pivot.f, pivot.g, pivot.h, pivot.i))
		end,
		SetPrimaryPartCFrame = function(self, cfv)
			diag("deprecated", "Model:SetPrimaryPartCFrame", "Model:SetPrimaryPartCFrame is deprecated, use PivotTo")
			pivotTo(self, cfv)
		end,
		GetBoundingBox = function(self)
			local c, s = boundingBox(self)
			return c, s
		end,
		GetExtentsSize = function(self)
			local _, s = boundingBox(self)
			return s
		end,
		GetScale = function()
			return 1
		end,
		ScaleTo = function() end,
	},
})
defclass("Actor", "Model", { creatable = true })
defclass("WorldModel", "Model", { creatable = true })

defclass("BasePart", "PVInstance", {
	creatable = false,
	props = {
		Anchored = T.bool(false), CanCollide = T.bool(true), CanTouch = T.bool(true), CanQuery = T.bool(true),
		CastShadow = T.bool(true), Massless = T.bool(false), Locked = T.bool(false), Transparency = T.num(0),
		Reflectance = T.num(0), Size = T.v3(4, 1, 2), Color = T.rgb(163, 162, 165),
		Material = T.enum("Material", "Plastic"), PivotOffset = T.cf(),
		AssemblyLinearVelocity = T.v3(0, 0, 0), AssemblyAngularVelocity = T.v3(0, 0, 0),
		CollisionGroup = T.str("Default"), CollisionGroupId = T.num(0), CustomPhysicalProperties = T.any(nil),
		RootPriority = T.num(0), MaterialVariant = T.str(""), EnableFluidForces = T.bool(true),
		TopSurface = T.enum("SurfaceType", "Smooth"), BottomSurface = T.enum("SurfaceType", "Smooth"),
		LeftSurface = T.enum("SurfaceType", "Smooth"), RightSurface = T.enum("SurfaceType", "Smooth"),
		FrontSurface = T.enum("SurfaceType", "Smooth"), BackSurface = T.enum("SurfaceType", "Smooth"),
	},
	getters = {
		CFrame = function(_, st)
			return currentCFrame(st)
		end,
		Position = function(_, st)
			local c = currentCFrame(st)
			return v3(c.x, c.y, c.z)
		end,
		Orientation = function(_, st)
			local rx, ry, rz = currentCFrame(st):ToOrientation()
			return v3(degrees(rx), degrees(ry), degrees(rz))
		end,
		Rotation = function(_, st)
			local rx, ry, rz = currentCFrame(st):ToOrientation()
			return v3(degrees(rx), degrees(ry), degrees(rz))
		end,
		Velocity = function(_, st)
			diag("deprecated", "BasePart.Velocity", "BasePart.Velocity is deprecated, use AssemblyLinearVelocity")
			return st.props.AssemblyLinearVelocity or v3(0, 0, 0)
		end,
		RotVelocity = function(_, st)
			diag("deprecated", "BasePart.RotVelocity", "BasePart.RotVelocity is deprecated, use AssemblyAngularVelocity")
			return st.props.AssemblyAngularVelocity or v3(0, 0, 0)
		end,
		Mass = function(_, st)
			local s = st.props.Size or v3(4, 1, 2)
			return s.X * s.Y * s.Z * 0.7
		end,
		AssemblyMass = function(_, st)
			local s = st.props.Size or v3(4, 1, 2)
			return s.X * s.Y * s.Z * 0.7
		end,
		AssemblyRootPart = function(self)
			return self
		end,
		BrickColor = function(_, st)
			local c = st.props.Color or Color3.fromRGB(163, 162, 165)
			return BrickColor.new(c)
		end,
	},
	setters = {
		CFrame = function(self, st, v)
			if typeof(v) ~= "CFrame" then
				error("Unable to assign property CFrame. CFrame expected, got " .. typeof(v), 3)
			end
			nanCheck(v, "CFrame")
			applyCFrame(self, st, v, true)
		end,
		Position = function(self, st, v)
			if typeof(v) ~= "Vector3" then
				error("Unable to assign property Position. Vector3 expected, got " .. typeof(v), 3)
			end
			local c = currentCFrame(st)
			local n = cf(v.X, v.Y, v.Z, c.a, c.b, c.c, c.d, c.e, c.f, c.g, c.h, c.i)
			nanCheck(n, "Position")
			applyCFrame(self, st, n, true)
		end,
		Orientation = function(self, st, v)
			local c = currentCFrame(st)
			local r = CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
			applyCFrame(self, st, cf(c.x, c.y, c.z, r.a, r.b, r.c, r.d, r.e, r.f, r.g, r.h, r.i), true)
		end,
		Velocity = function(self, st, v)
			diag("deprecated", "BasePart.Velocity", "BasePart.Velocity is deprecated, use AssemblyLinearVelocity")
			st.props.AssemblyLinearVelocity = v
		end,
		BrickColor = function(self, st, v)
			if typeof(v) ~= "BrickColor" then
				error("Unable to assign property BrickColor. BrickColor expected, got " .. typeof(v), 3)
			end
			st.props.Color = v.Color
			firePropChanged(self, st, "Color")
		end,
		Size = function(self, st, v)
			if typeof(v) ~= "Vector3" then
				error("Unable to assign property Size. Vector3 expected, got " .. typeof(v), 3)
			end
			st.props.Size = v
			firePropChanged(self, st, "Size")
		end,
	},
	events = { "Touched", "TouchEnded" },
	methods = {
		GetMass = function(self)
			return self.Mass
		end,
		ApplyImpulse = function(self, impulse)
			local st = self[STATE]
			local vel = st.props.AssemblyLinearVelocity or v3(0, 0, 0)
			local mass = self.Mass
			st.props.AssemblyLinearVelocity = vel + impulse * (1 / mass)
		end,
		ApplyImpulseAtPosition = function(self, impulse)
			self:ApplyImpulse(impulse)
		end,
		ApplyAngularImpulse = function() end,
		GetTouchingParts = function(self)
			local out = {}
			local set = Mock._touching and Mock._touching[self]
			if set then
				for other in pairs(set) do
					out[#out + 1] = other
				end
			end
			return out
		end,
		GetConnectedParts = function(self)
			return weldPartners(self)
		end,
		GetRootPart = function(self)
			return self
		end,
		GetNetworkOwner = function()
			return nil
		end,
		SetNetworkOwner = function(self)
			if Mock.Context ~= "server" then
				error("SetNetworkOwner can only be called from the server", 2)
			end
		end,
		SetNetworkOwnershipAuto = function() end,
		CanSetNetworkOwnership = function()
			return true
		end,
		IsGrounded = function()
			return false
		end,
		BreakJoints = function() end,
		CanCollideWith = function(self, other)
			return self.CanCollide and other.CanCollide
		end,
		GetJoints = function()
			return {}
		end,
		Resize = function()
			return true
		end,
		GetVelocityAtPosition = function(self)
			return self.AssemblyLinearVelocity
		end,
	},
})
defclass("Part", "BasePart", { creatable = true, props = { Shape = T.enum("PartType", "Block") } })
defclass("WedgePart", "BasePart", { creatable = true })
defclass("CornerWedgePart", "BasePart", { creatable = true })
defclass("TrussPart", "BasePart", { creatable = true })
defclass("SpawnLocation", "Part", { creatable = true, props = { Enabled = T.bool(true), Neutral = T.bool(true), Duration = T.num(10), AllowTeamChangeOnTouch = T.bool(false), TeamColor = T.brick() } })
defclass("Seat", "Part", { creatable = true, props = { Disabled = T.bool(false) } })
defclass("VehicleSeat", "BasePart", { creatable = true, props = { Disabled = T.bool(false), MaxSpeed = T.num(25), Torque = T.num(10), TurnSpeed = T.num(1), Throttle = T.num(0), Steer = T.num(0) } })
defclass("MeshPart", "BasePart", {
	creatable = true,
	props = { MeshId = T.str(""), TextureID = T.str(""), DoubleSided = T.bool(false), RenderFidelity = T.enum("RenderFidelity", "Automatic"), CollisionFidelity = T.enum("CollisionFidelity", "Default") },
})
defclass("UnionOperation", "BasePart", { creatable = true })
defclass("NegateOperation", "BasePart", { creatable = true })
defclass("Terrain", "BasePart", { creatable = false })

defclass("Folder", "Instance", { creatable = true })
defclass("Configuration", "Instance", { creatable = true })

-- Attachments
defclass("Attachment", "Instance", {
	creatable = true,
	props = { Visible = T.bool(false), Axis = T.v3(1, 0, 0), SecondaryAxis = T.v3(0, 1, 0), CFrame = T.cf() },
	getters = {
		Position = function(_, st)
			local c = st.props.CFrame or CF_IDENTITY
			return v3(c.x, c.y, c.z)
		end,
		WorldPosition = function(self, st)
			local c = st.props.CFrame or CF_IDENTITY
			local parent = st.parent
			if parent and parent[STATE].class.isA.BasePart then
				return currentCFrame(parent[STATE]) * v3(c.x, c.y, c.z)
			end
			return v3(c.x, c.y, c.z)
		end,
		WorldCFrame = function(self, st)
			local parent = st.parent
			local c = st.props.CFrame or CF_IDENTITY
			if parent and parent[STATE].class.isA.BasePart then
				return currentCFrame(parent[STATE]) * c
			end
			return c
		end,
		Orientation = function(_, st)
			local rx, ry, rz = (st.props.CFrame or CF_IDENTITY):ToOrientation()
			return v3(degrees(rx), degrees(ry), degrees(rz))
		end,
	},
	setters = {
		Position = function(self, st, v)
			if typeof(v) ~= "Vector3" then
				error("Unable to assign property Position. Vector3 expected, got " .. typeof(v), 3)
			end
			local c = st.props.CFrame or CF_IDENTITY
			st.props.CFrame = cf(v.X, v.Y, v.Z, c.a, c.b, c.c, c.d, c.e, c.f, c.g, c.h, c.i)
			firePropChanged(self, st, "Position")
		end,
	},
})
defclass("Bone", "Attachment", { creatable = true })

-- Joints
defclass("JointInstance", "Instance", { creatable = false, props = { Part0 = T.inst(), Part1 = T.inst(), C0 = T.cf(), C1 = T.cf(), Enabled = T.bool(true) } })
local function weldHook(self, st, key, value)
	if key == "Part0" or key == "Part1" then
		for _, p in pairs({ st.props.Part0, st.props.Part1 }) do
			if p then
				local set = Mock._welds[p]
				if not set then
					set = setmetatable({}, { __mode = "k" })
					Mock._welds[p] = set
				end
				set[self] = true
			end
		end
	end
end
for _, wname in ipairs({ "Weld", "ManualWeld", "Snap", "Glue", "ManualGlue", "Motor", "Motor6D" }) do
	defclass(wname, "JointInstance", {
		creatable = true,
		init = function(inst, st)
			st.onProp = weldHook
		end,
	})
end
defclass("WeldConstraint", "Instance", {
	creatable = true,
	props = { Part0 = T.inst(), Part1 = T.inst(), Enabled = T.bool(true) },
	init = function(inst, st)
		st.onProp = weldHook
	end,
})

-- Physics constraints used by the game (VectorForce: the wind gusts push players with one)
defclass("VectorForce", "Instance", {
	creatable = true,
	props = {
		Force = T.v3(0, 0, 0), Attachment0 = T.inst(), Attachment1 = T.inst(), ApplyAtCenterOfMass = T.bool(false),
		RelativeTo = T.enum("ActuatorRelativeTo", "Attachment0"), Visible = T.bool(false), Enabled = T.bool(true),
	},
})

-- Lights, effects
local lightProps = { Brightness = T.num(1), Color = T.rgb(255, 255, 255), Enabled = T.bool(true), Shadows = T.bool(false) }
defclass("Light", "Instance", { creatable = false, props = lightProps })
defclass("PointLight", "Light", { creatable = true, props = { Range = T.num(8) } })
defclass("SpotLight", "Light", { creatable = true, props = { Range = T.num(16), Angle = T.num(90), Face = T.enum("NormalId", "Front") } })
defclass("SurfaceLight", "Light", { creatable = true, props = { Range = T.num(16), Angle = T.num(90), Face = T.enum("NormalId", "Front") } })
defclass("ParticleEmitter", "Instance", {
	creatable = true,
	props = {
		Enabled = T.bool(true), Rate = T.num(20), Lifetime = T.nr(5, 10), Speed = T.nr(5, 5), Size = T.ns(1), Transparency = T.ns(0),
		Color = T.cs(255, 255, 255), LightEmission = T.num(0), LightInfluence = T.num(1), Texture = T.str(""), Acceleration = T.v3(0, 0, 0),
		Drag = T.num(0), EmissionDirection = T.enum("NormalId", "Top"), LockedToPart = T.bool(false), Rotation = T.nr(0, 0), RotSpeed = T.nr(0, 0),
		SpreadAngle = T.v2(0, 0), TimeScale = T.num(1), ZOffset = T.num(0), Orientation = T.enum("ParticleOrientation", "FacingCamera"),
		Shape = T.enum("ParticleEmitterShape", "Box"), ShapeStyle = T.enum("ParticleEmitterShapeStyle", "Volume"),
		ShapeInOut = T.enum("ParticleEmitterShapeInOut", "Outward"), ShapePartial = T.num(1), Squash = T.ns(0), VelocityInheritance = T.num(0),
		WindAffectsDrag = T.bool(false), Brightness = T.num(1),
	},
	methods = {
		Emit = function(self, count)
			if count ~= nil and rawtype(count) ~= "number" then
				error("invalid argument #1 to 'Emit' (number expected, got " .. typeof(count) .. ")", 2)
			end
			Mock.Stats_.particlesEmitted = Mock.Stats_.particlesEmitted + (count or 1)
		end,
		Clear = function() end,
	},
})
Mock.Stats_ = { particlesEmitted = 0 }
defclass("Trail", "Instance", {
	creatable = true,
	props = {
		Attachment0 = T.inst(), Attachment1 = T.inst(), Color = T.cs(255, 255, 255), Transparency = T.ns(0), Lifetime = T.num(2),
		Enabled = T.bool(true), LightEmission = T.num(0), LightInfluence = T.num(1), MinLength = T.num(0.1), MaxLength = T.num(0),
		WidthScale = T.ns(1), FaceCamera = T.bool(false), TextureLength = T.num(1), Texture = T.str(""), Brightness = T.num(1),
		TextureMode = T.any(nil),
	},
	methods = { Clear = function() end },
})
defclass("Beam", "Instance", {
	creatable = true,
	props = {
		Attachment0 = T.inst(), Attachment1 = T.inst(), Color = T.cs(255, 255, 255), Transparency = T.ns(0), Width0 = T.num(1), Width1 = T.num(1),
		Segments = T.num(10), CurveSize0 = T.num(0), CurveSize1 = T.num(0), FaceCamera = T.bool(false), LightEmission = T.num(0),
		LightInfluence = T.num(0), Texture = T.str(""), TextureLength = T.num(1), TextureSpeed = T.num(1), ZOffset = T.num(0), Enabled = T.bool(true),
		Brightness = T.num(1), TextureMode = T.any(nil),
	},
})
for _, n in ipairs({ "Fire", "Smoke", "Sparkles" }) do
	defclass(n, "Instance", { creatable = true, props = { Enabled = T.bool(true), Color = T.rgb(236, 139, 70), SecondaryColor = T.rgb(139, 80, 55), Size = T.num(5), Heat = T.num(9), TimeScale = T.num(1), Opacity = T.num(0.5), RiseVelocity = T.num(1), SparkleColor = T.rgb(144, 25, 255) } })
end
defclass("Explosion", "Instance", { creatable = true, props = { BlastPressure = T.num(500000), BlastRadius = T.num(4), DestroyJointRadiusPercent = T.num(1), ExplosionType = T.any(nil), Position = T.v3(0, 0, 0), Visible = T.bool(true) } })
defclass("Highlight", "Instance", {
	creatable = true,
	props = { Adornee = T.inst(), Enabled = T.bool(true), FillColor = T.rgb(255, 0, 0), FillTransparency = T.num(0.5), OutlineColor = T.rgb(255, 255, 255), OutlineTransparency = T.num(0), DepthMode = T.any(nil) },
})
defclass("ForceField", "Instance", { creatable = true, props = { Visible = T.bool(true) } })
defclass("Sound", "Instance", {
	creatable = true,
	props = { SoundId = T.str(""), Volume = T.num(0.5), Playing = T.bool(false), TimePosition = T.num(0), PlaybackSpeed = T.num(1), Looped = T.bool(false), RollOffMaxDistance = T.num(10000), RollOffMinDistance = T.num(10), PlayOnRemove = T.bool(false) },
	events = { "Ended", "Played", "Paused", "Resumed", "Stopped", "Loaded" },
	getters = {
		IsPlaying = function(_, st)
			return st.props.Playing == true
		end,
		IsLoaded = function()
			return true
		end,
		TimeLength = function()
			return 1
		end,
	},
	methods = {
		Play = function(self)
			self[STATE].props.Playing = true
		end,
		Stop = function(self)
			self[STATE].props.Playing = false
		end,
		Pause = function(self)
			self[STATE].props.Playing = false
		end,
		Resume = function(self)
			self[STATE].props.Playing = true
		end,
	},
})
defclass("Decal", "Instance", { creatable = true, props = { Texture = T.str(""), Face = T.enum("NormalId", "Front"), Transparency = T.num(0), Color3 = T.rgb(255, 255, 255), ZIndex = T.num(1) } })
defclass("Texture", "Decal", { creatable = true, props = { StudsPerTileU = T.num(2), StudsPerTileV = T.num(2), OffsetStudsU = T.num(0), OffsetStudsV = T.num(0) } })
defclass("SpecialMesh", "Instance", { creatable = true, props = { MeshId = T.str(""), TextureId = T.str(""), Scale = T.v3(1, 1, 1), Offset = T.v3(0, 0, 0), VertexColor = T.v3(1, 1, 1), MeshType = T.any(nil) } })
defclass("Sky", "Instance", {
	creatable = true,
	props = { StarCount = T.num(3000), CelestialBodiesShown = T.bool(true), SunAngularSize = T.num(21), MoonAngularSize = T.num(11), SunTextureId = T.str(""), MoonTextureId = T.str(""), SkyboxBk = T.str(""), SkyboxDn = T.str(""), SkyboxFt = T.str(""), SkyboxLf = T.str(""), SkyboxRt = T.str(""), SkyboxUp = T.str(""), SkyboxOrientation = T.v3(0, 0, 0) },
})
defclass("Atmosphere", "Instance", { creatable = true, props = { Density = T.num(0.395), Offset = T.num(0), Color = T.rgb(199, 170, 107), Decay = T.rgb(92, 60, 13), Glare = T.num(0), Haze = T.num(0) } })
defclass("Clouds", "Instance", { creatable = true, props = { Cover = T.num(0.5), Density = T.num(0.7), Color = T.rgb(255, 255, 255), Enabled = T.bool(true) } })
defclass("PostEffect", "Instance", { creatable = false, props = { Enabled = T.bool(true) } })
defclass("BloomEffect", "PostEffect", { creatable = true, props = { Intensity = T.num(1), Size = T.num(24), Threshold = T.num(0.5) } })
defclass("BlurEffect", "PostEffect", { creatable = true, props = { Size = T.num(24) } })
defclass("ColorCorrectionEffect", "PostEffect", { creatable = true, props = { Brightness = T.num(0), Contrast = T.num(0), Saturation = T.num(0), TintColor = T.rgb(255, 255, 255) } })
defclass("DepthOfFieldEffect", "PostEffect", { creatable = true, props = { FarIntensity = T.num(0.75), FocusDistance = T.num(0.05), InFocusRadius = T.num(10), NearIntensity = T.num(0.75) } })
defclass("SunRaysEffect", "PostEffect", { creatable = true, props = { Intensity = T.num(0.25), Spread = T.num(1) } })

-- Value objects
for _, spec in ipairs({
	{ "BoolValue", T.bool(false) }, { "IntValue", T.num(0) }, { "NumberValue", T.num(0) }, { "StringValue", T.str("") },
	{ "ObjectValue", T.inst() }, { "Color3Value", T.rgb(0, 0, 0) }, { "Vector3Value", T.v3(0, 0, 0) }, { "CFrameValue", T.cf() },
	{ "BrickColorValue", T.brick() },
}) do
	if spec[1] == "BoolValue" then
		defclass("ValueBase", "Instance", { creatable = false })
	end
	defclass(spec[1], "ValueBase", { creatable = true, props = { Value = spec[2] } })
end

-- Scripts and bindables
defclass("LuaSourceContainer", "Instance", { creatable = false })
defclass("BaseScript", "LuaSourceContainer", { creatable = false, props = { Disabled = T.bool(false), Enabled = T.bool(true), Source = T.str(""), RunContext = T.enum("RunContext", "Legacy") } })
defclass("Script", "BaseScript", { creatable = true })
defclass("LocalScript", "BaseScript", { creatable = true })
defclass("ModuleScript", "LuaSourceContainer", { creatable = true, props = { Source = T.str("") } })
defclass("BindableEvent", "Instance", {
	creatable = true,
	events = { "Event" },
	methods = {
		Fire = function(self, ...)
			getSignal(self, self[STATE], "Event"):Fire(...)
		end,
	},
})
defclass("BindableFunction", "Instance", {
	creatable = true,
	props = { OnInvoke = T.any(nil) },
	methods = {
		Invoke = function(self, ...)
			local cb = self[STATE].props.OnInvoke
			if cb then
				return cb(...)
			end
		end,
	},
})

local function checkRemoteArgs(remoteName, ...)
	local n = select("#", ...)
	local function scan(v, depth)
		local t = rawtype(v)
		if t == "function" or t == "thread" then
			error("Attempt to send a " .. t .. " through remote " .. remoteName .. " (functions cannot be replicated)", 4)
		elseif t == "table" and not UD[getmetatable(v) or UD] then
			if depth > 20 then
				error("Remote argument table is too deeply nested", 4)
			end
			for k, x in pairs(v) do
				local kt = rawtype(k)
				if kt ~= "string" and kt ~= "number" then
					error("Remote argument tables may only have string or number keys (remote " .. remoteName .. ")", 4)
				end
				scan(x, depth + 1)
			end
		end
	end
	for i = 1, n do
		scan((select(i, ...)), 0)
	end
end
Mock.RemoteLog = {}
local function logRemote(entry)
	entry.time = Clock.now
	Mock.RemoteLog[#Mock.RemoteLog + 1] = entry
	if Mock._onRemote then
		Mock._onRemote(entry)
	end
end
defclass("RemoteEvent", "Instance", {
	creatable = true,
	getters = {
		OnServerEvent = function(self, st)
			if Mock.Context ~= "server" then
				error("OnServerEvent can only be accessed from the server (remote " .. st.name .. ")", 3)
			end
			return getSignal(self, st, "OnServerEvent")
		end,
		OnClientEvent = function(self, st)
			if Mock.Context ~= "client" then
				error("OnClientEvent can only be accessed from the client (remote " .. st.name .. ")", 3)
			end
			return getSignal(self, st, "OnClientEvent")
		end,
	},
	methods = {
		FireServer = function(self, ...)
			if Mock.Context ~= "client" then
				error("FireServer can only be called from the client (remote " .. self[STATE].name .. ")", 2)
			end
			checkRemoteArgs(self[STATE].name, ...)
			logRemote({ kind = "server", remote = self[STATE].name, args = pack(...) })
		end,
		FireClient = function(self, player, ...)
			if Mock.Context ~= "server" then
				error("FireClient can only be called from the server (remote " .. self[STATE].name .. ")", 2)
			end
			if not isInstance(player) or not player[STATE].class.isA.Player then
				error("FireClient: argument 1 must be a Player (remote " .. self[STATE].name .. "), got " .. typeof(player), 2)
			end
			checkRemoteArgs(self[STATE].name, ...)
			logRemote({ kind = "client", remote = self[STATE].name, player = player, userId = player.UserId, args = pack(...) })
		end,
		FireAllClients = function(self, ...)
			if Mock.Context ~= "server" then
				error("FireAllClients can only be called from the server (remote " .. self[STATE].name .. ")", 2)
			end
			checkRemoteArgs(self[STATE].name, ...)
			logRemote({ kind = "all", remote = self[STATE].name, args = pack(...) })
		end,
	},
})
defclass("UnreliableRemoteEvent", "RemoteEvent", { creatable = true })
defclass("RemoteFunction", "Instance", {
	creatable = true,
	props = { OnServerInvoke = T.any(nil), OnClientInvoke = T.any(nil) },
	methods = {
		InvokeServer = function(self, ...)
			if Mock.Context ~= "client" then
				error("InvokeServer can only be called from the client", 2)
			end
			logRemote({ kind = "server", remote = self[STATE].name, args = pack(...), invoke = true })
		end,
		InvokeClient = function(self, player, ...)
			if Mock.Context ~= "server" then
				error("InvokeClient can only be called from the server", 2)
			end
			logRemote({ kind = "client", remote = self[STATE].name, player = player, args = pack(...), invoke = true })
		end,
	},
})

-- Misc gameplay classes
defclass("Camera", "Instance", {
	creatable = true,
	props = {
		FieldOfView = T.num(70), CameraType = T.enum("CameraType", "Fixed"), CameraSubject = T.inst(), CFrame = T.cf(), Focus = T.cf(),
		NearPlaneZ = T.num(-0.5), HeadLocked = T.bool(true), FieldOfViewMode = T.any(nil),
	},
	getters = {
		ViewportSize = function()
			return Mock.Viewport
		end,
	},
	methods = {
		WorldToViewportPoint = function(self, pos)
			return v3(Mock.Viewport.X / 2, Mock.Viewport.Y / 2, 10), true
		end,
		WorldToScreenPoint = function(self, pos)
			return v3(Mock.Viewport.X / 2, Mock.Viewport.Y / 2, 10), true
		end,
		ViewportPointToRay = function(self, x, y)
			return Ray.new(self.CFrame.Position, self.CFrame.LookVector)
		end,
		ScreenPointToRay = function(self, x, y)
			return Ray.new(self.CFrame.Position, self.CFrame.LookVector)
		end,
	},
})
defclass("ClickDetector", "Instance", { creatable = true, props = { MaxActivationDistance = T.num(32) }, events = { "MouseClick", "MouseHoverEnter", "MouseHoverLeave", "RightMouseClick" } })
defclass("ProximityPrompt", "Instance", { creatable = true, props = { ActionText = T.str("Interact"), ObjectText = T.str(""), HoldDuration = T.num(0), MaxActivationDistance = T.num(10), Enabled = T.bool(true), RequiresLineOfSight = T.bool(true), KeyboardKeyCode = T.any(nil) }, events = { "Triggered", "TriggerEnded", "PromptShown", "PromptHidden" } })
defclass("Team", "Instance", { creatable = true, props = { TeamColor = T.brick(), AutoAssignable = T.bool(true) } })
defclass("Tool", "Instance", { creatable = true, props = { CanBeDropped = T.bool(true), Enabled = T.bool(true), RequiresHandle = T.bool(true), ToolTip = T.str("") }, events = { "Activated", "Deactivated", "Equipped", "Unequipped" } })
defclass("Backpack", "Instance", { creatable = true })
defclass("Accessory", "Instance", { creatable = true })
defclass("Animator", "Instance", { creatable = true, methods = { LoadAnimation = function() return { Play = function() end, Stop = function() end, AdjustSpeed = function() end } end } })
defclass("Animation", "Instance", { creatable = true, props = { AnimationId = T.str("") } })
defclass("SurfaceAppearance", "Instance", { creatable = true })

----------------------------------------------------------------------------------------------------
-- GUI classes
----------------------------------------------------------------------------------------------------
Mock.Viewport = v2(1280, 720)

do
-- GUI layout engine -----------------------------------------------------------------------------------
-- Computes AbsoluteSize / AbsolutePosition the way Roblox does for the things this project uses:
--   * Position (scale + offset + AnchorPoint), Size (scale + offset, SizeConstraint), AutomaticSize (X / Y / XY,
--     Size acts as the minimum), UIPadding, UIScale (grows around the AnchorPoint, scales descendants' offsets),
--     UISizeConstraint, UIAspectRatioConstraint, UIListLayout (alignment, padding, wraps, sort order) and
--     UIGridLayout (cell size / padding / alignment; StartCorner is always TopLeft).
--   * Text objects measure their text with a fixed average glyph width (0.5 * TextSize), wrapping on spaces.
--   * Coordinates are relative to the top-left of the ScreenGui area. A ScreenGui with IgnoreGuiInset = false
--     starts below the top bar, so its area is Mock.Viewport minus Mock.TopInset in height (AbsolutePosition does
--     NOT include the inset, exactly like Roblox).
-- Not modelled: rotation, ScrollingFrame clipping, UIFlexItem, UIPageLayout / UITableLayout, TextScaled sizing.
-- Results are cached per instance and invalidated by Mock.GuiEpoch (any GUI property, name or parent change,
-- viewport change).
Mock.TopInset = 58

local layoutCache = setmetatable({}, { __mode = "k" })
local arrangeCache = setmetatable({}, { __mode = "k" })

local function prop(inst, key)
	local st = inst[STATE]
	local v = st.props[key]
	if v == nil then
		local spec = st.class.propspec[key]
		if spec then
			if spec.lazy then
				v = specDefault(spec)
			else
				v = spec.def
			end
		end
	end
	return v
end

local function enumName(item)
	return item and item.Name or ""
end

local function firstChildIs(inst, className)
	local children = inst[STATE].children
	for i = 1, #children do
		if children[i][STATE].class.isA[className] then
			return children[i]
		end
	end
	return nil
end

local function layerBox(inst)
	local st = inst[STATE]
	local isA = st.class.isA
	if isA.BillboardGui then
		local sz = prop(inst, "Size")
		return { x = 0, y = 0, w = sz.X.Offset + sz.X.Scale * 100, h = sz.Y.Offset + sz.Y.Scale * 100, s = 1 }
	elseif isA.SurfaceGui then
		local cs = prop(inst, "CanvasSize")
		return { x = 0, y = 0, w = cs.X, h = cs.Y, s = 1 }
	end
	local inset = 0
	if prop(inst, "IgnoreGuiInset") == false then
		inset = Mock.TopInset or 0
	end
	return { x = 0, y = 0, w = Mock.Viewport.X, h = mmax(0, Mock.Viewport.Y - inset), s = 1 }
end

local function utf8len(text)
	local _, n = text:gsub("[^\128-\191]", "")
	return n
end

-- width, height of a text object's text (limit = wrap width or nil)
local function textExtent(inst, limit)
	local text = prop(inst, "Text") or ""
	if prop(inst, "RichText") then
		text = text:gsub("<[^>]*>", "")
	end
	local size = prop(inst, "TextSize") or 14
	local charW = size * 0.5
	local lineH = size * (prop(inst, "LineHeight") or 1)
	local maxW, lines = 0, 0
	for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
		local len = utf8len(raw)
		if limit and limit > 0 and len * charW > limit then
			-- wrap on spaces
			local cur = 0
			local used = 0
			local rows = 1
			for word in raw:gmatch("%S+") do
				local wl = utf8len(word) * charW
				if cur > 0 and cur + charW + wl > limit then
					rows = rows + 1
					maxW = mmax(maxW, cur)
					cur = 0
				end
				if wl > limit then
					local extra = ceil(wl / limit) - 1
					rows = rows + extra
					maxW = mmax(maxW, limit)
					cur = wl - extra * limit
				else
					cur = (cur > 0) and (cur + charW + wl) or wl
				end
				used = used + 1
			end
			maxW = mmax(maxW, cur)
			lines = lines + rows
		else
			maxW = mmax(maxW, len * charW)
			lines = lines + 1
		end
	end
	return maxW, lines * lineH
end
Mock.TextExtent = textExtent

local function paddingPx(inst, w, h, s)
	local pad = firstChildIs(inst, "UIPadding")
	if not pad then
		return 0, 0, 0, 0
	end
	local l, r, t, b = prop(pad, "PaddingLeft"), prop(pad, "PaddingRight"), prop(pad, "PaddingTop"), prop(pad, "PaddingBottom")
	return l.Scale * w + l.Offset * s, r.Scale * w + r.Offset * s, t.Scale * h + t.Offset * s, b.Scale * h + b.Offset * s
end

-- the area available to the children of `inst` (box minus UIPadding)
local function contentOf(inst, box)
	local l, r, t, b = paddingPx(inst, box.w, box.h, box.s)
	return { x = box.x + l, y = box.y + t, w = mmax(0, box.w - l - r), h = mmax(0, box.h - t - b), s = box.s }
end

local function layoutChildren(inst, layout)
	local out = {}
	local children = inst[STATE].children
	for i = 1, #children do
		local c = children[i]
		local cst = c[STATE]
		if cst.class.isA.GuiObject and cst.props.Visible ~= false then
			out[#out + 1] = { inst = c, index = i }
		end
	end
	local byName = enumName(prop(layout, "SortOrder")) == "Name"
	for _, e in ipairs(out) do
		e.key = byName and e.inst[STATE].name or (prop(e.inst, "LayoutOrder") or 0)
	end
	tsort(out, function(a, b)
		if a.key ~= b.key then
			return a.key < b.key
		end
		return a.index < b.index
	end)
	return out
end

local function findLayout(inst)
	local children = inst[STATE].children
	for i = 1, #children do
		local isA = children[i][STATE].class.isA
		if isA.UIListLayout or isA.UIGridLayout then
			return children[i], isA.UIGridLayout and true or false
		end
	end
	return nil
end

local resolveSize, placeIn

local function alignOffset(kind, room)
	if kind == "Center" then
		return room / 2
	elseif kind == "Right" or kind == "Bottom" then
		return room
	end
	return 0
end

local function listArrange(inst, layout, pc)
	local vertical = enumName(prop(layout, "FillDirection")) ~= "Horizontal"
	local ha, va = enumName(prop(layout, "HorizontalAlignment")), enumName(prop(layout, "VerticalAlignment"))
	local pad = prop(layout, "Padding")
	local mainLimit = vertical and pc.h or pc.w
	local crossLimit = vertical and pc.w or pc.h
	local padPx = pad.Scale * mainLimit + pad.Offset * pc.s
	local wraps = prop(layout, "Wraps") == true
	local items = {}
	for _, e in ipairs(layoutChildren(inst, layout)) do
		local w, h = resolveSize(e.inst, pc, nil)
		items[#items + 1] = { inst = e.inst, w = w, h = h }
	end
	local lines = { { items = {}, main = 0, cross = 0 } }
	for _, it in ipairs(items) do
		local m = vertical and it.h or it.w
		local c = vertical and it.w or it.h
		local line = lines[#lines]
		local add = (#line.items > 0) and padPx or 0
		if wraps and #line.items > 0 and line.main + add + m > mainLimit + 0.5 then
			line = { items = {}, main = 0, cross = 0 }
			lines[#lines + 1] = line
			add = 0
		end
		line.items[#line.items + 1] = it
		line.main = line.main + add + m
		line.cross = mmax(line.cross, c)
	end
	local map = {}
	local mainAlign = vertical and va or ha
	local crossAlign = vertical and ha or va
	local crossBase = 0
	local cw, ch = 0, 0
	for li, line in ipairs(lines) do
		local cursor = alignOffset(mainAlign, mainLimit - line.main)
		local extent = wraps and line.cross or crossLimit
		for _, it in ipairs(line.items) do
			local m = vertical and it.h or it.w
			local c = vertical and it.w or it.h
			local cpos = crossBase + alignOffset(crossAlign, extent - c)
			if vertical then
				map[it.inst] = { x = cpos, y = cursor, w = it.w, h = it.h }
			else
				map[it.inst] = { x = cursor, y = cpos, w = it.w, h = it.h }
			end
			cursor = cursor + m + padPx
		end
		crossBase = crossBase + line.cross + ((li < #lines) and padPx or 0)
		if vertical then
			cw = mmax(cw, line.cross)
			ch = mmax(ch, line.main)
		else
			cw = mmax(cw, line.main)
			ch = mmax(ch, line.cross)
		end
	end
	if wraps then
		if vertical then
			cw = crossBase
		else
			ch = crossBase
		end
	end
	return { map = map, cw = cw, ch = ch }
end

local function gridArrange(inst, layout, pc)
	local cs, cp = prop(layout, "CellSize"), prop(layout, "CellPadding")
	local cellW = pc.w * cs.X.Scale + cs.X.Offset * pc.s
	local cellH = pc.h * cs.Y.Scale + cs.Y.Offset * pc.s
	local padX = pc.w * cp.X.Scale + cp.X.Offset * pc.s
	local padY = pc.h * cp.Y.Scale + cp.Y.Offset * pc.s
	local horizontal = enumName(prop(layout, "FillDirection")) ~= "Vertical"
	local ha, va = enumName(prop(layout, "HorizontalAlignment")), enumName(prop(layout, "VerticalAlignment"))
	local children = layoutChildren(inst, layout)
	local perLine
	if horizontal then
		perLine = mmax(1, floor((pc.w + padX) / mmax(cellW + padX, 0.001) + 1e-6))
	else
		perLine = mmax(1, floor((pc.h + padY) / mmax(cellH + padY, 0.001) + 1e-6))
	end
	local maxCells = prop(layout, "FillDirectionMaxCells") or 0
	if maxCells > 0 then
		perLine = mmin(perLine, maxCells)
	end
	local n = #children
	local lines = ceil(n / perLine)
	local mainCell, mainPad, crossCell, crossPad = cellW, padX, cellH, padY
	if not horizontal then
		mainCell, mainPad, crossCell, crossPad = cellH, padY, cellW, padX
	end
	local crossTotal = lines * crossCell + mmax(0, lines - 1) * crossPad
	local map = {}
	local cw, ch = 0, 0
	for i, e in ipairs(children) do
		local li = floor((i - 1) / perLine)
		local col = (i - 1) % perLine
		local inLine = mmin(perLine, n - li * perLine)
		local lineMain = inLine * mainCell + (inLine - 1) * mainPad
		local mainOff, crossOff
		if horizontal then
			mainOff = alignOffset(ha, pc.w - lineMain)
			crossOff = alignOffset(va, pc.h - crossTotal)
		else
			mainOff = alignOffset(va, pc.h - lineMain)
			crossOff = alignOffset(ha, pc.w - crossTotal)
		end
		local m = mainOff + col * (mainCell + mainPad)
		local c = crossOff + li * (crossCell + crossPad)
		if horizontal then
			map[e.inst] = { x = m, y = c, w = cellW, h = cellH }
		else
			map[e.inst] = { x = c, y = m, w = cellW, h = cellH }
		end
	end
	if horizontal then
		cw = mmin(n, perLine) * cellW + mmax(0, mmin(n, perLine) - 1) * padX
		ch = crossTotal
	else
		ch = mmin(n, perLine) * cellH + mmax(0, mmin(n, perLine) - 1) * padY
		cw = crossTotal
	end
	if n == 0 then
		cw, ch = 0, 0
	end
	return { map = map, cw = cw, ch = ch }
end

local function arrangement(inst, pc, cacheable)
	if cacheable then
		local c = arrangeCache[inst]
		if c and c.epoch == Mock.GuiEpoch then
			return c.res
		end
	end
	local layout, isGrid = findLayout(inst)
	local res = false
	if layout then
		if isGrid then
			res = gridArrange(inst, layout, pc)
		else
			res = listArrange(inst, layout, pc)
		end
	end
	if cacheable then
		arrangeCache[inst] = { epoch = Mock.GuiEpoch, res = res }
	end
	return res
end

-- size the object's content needs (AutomaticSize)
local function measureContent(inst, w, h, s)
	local st = inst[STATE]
	local l, r, t, b = paddingPx(inst, w, h, s)
	if st.isText then
		local limit = nil
		if prop(inst, "TextWrapped") then
			limit = mmax(0, w - l - r)
		end
		local tw, th = textExtent(inst, limit)
		return tw + l + r, th + t + b
	end
	-- The content is measured in the object's OWN (pre-UIScale) space with the parent's scale `s`: resolveSize
	-- multiplies the measured size by the object's UIScale afterwards. Measuring with s * ownScale as well
	-- applied the scale twice (a 304 px column at scale 0.72 came out 158 px tall instead of 219).
	local content = { x = 0, y = 0, w = mmax(0, w - l - r), h = mmax(0, h - t - b), s = s }
	local arr = arrangement(inst, content, false)
	if arr then
		return arr.cw + l + r, arr.ch + t + b
	end
	local mw, mh = 0, 0
	for _, c in ipairs(inst[STATE].children) do
		local cst = c[STATE]
		if cst.class.isA.GuiObject and cst.props.Visible ~= false then
			local box = placeIn(c, content, nil)
			mw = mmax(mw, box.x + box.w)
			mh = mmax(mh, box.y + box.h)
		end
	end
	return mw + r, mh + b
end

resolveSize = function(inst, pc, slot)
	local ownUi = firstChildIs(inst, "UIScale")
	local own = ownUi and prop(ownUi, "Scale") or 1
	local w, h
	if slot and slot.w then
		w, h = slot.w, slot.h
	else
		local sz = prop(inst, "Size")
		local basisW, basisH = pc.w, pc.h
		local constraint = enumName(prop(inst, "SizeConstraint"))
		if constraint == "RelativeXX" then
			basisH = pc.w
		elseif constraint == "RelativeYY" then
			basisW = pc.h
		end
		w = basisW * sz.X.Scale + sz.X.Offset * pc.s
		h = basisH * sz.Y.Scale + sz.Y.Offset * pc.s
		local auto = enumName(prop(inst, "AutomaticSize"))
		if auto ~= "None" and auto ~= "" then
			local cw, ch = measureContent(inst, mmax(0, w), mmax(0, h), pc.s)
			if auto == "X" or auto == "XY" then
				w = mmax(w, cw)
			end
			if auto == "Y" or auto == "XY" then
				h = mmax(h, ch)
			end
		end
	end
	local sc = firstChildIs(inst, "UISizeConstraint")
	if sc then
		local mn, mx = prop(sc, "MinSize"), prop(sc, "MaxSize")
		w = mmin(mmax(w, mn.X), mx.X)
		h = mmin(mmax(h, mn.Y), mx.Y)
	end
	local ar = firstChildIs(inst, "UIAspectRatioConstraint")
	if ar then
		local ratio = prop(ar, "AspectRatio")
		if ratio and ratio > 0 then
			if enumName(prop(ar, "AspectType")) == "ScaleWithParentSize" then
				if enumName(prop(ar, "DominantAxis")) == "Height" then
					w = h * ratio
				else
					h = w / ratio
				end
			elseif h > 0 and w / h > ratio then
				w = h * ratio
			elseif w > 0 then
				h = w / ratio
			end
		end
	end
	return mmax(0, w) * own, mmax(0, h) * own
end

placeIn = function(inst, pc, slot)
	local ownUi = firstChildIs(inst, "UIScale")
	local own = ownUi and prop(ownUi, "Scale") or 1
	local w, h = resolveSize(inst, pc, slot)
	local x, y
	if slot then
		x, y = pc.x + slot.x, pc.y + slot.y
	else
		local pos, anchor = prop(inst, "Position"), prop(inst, "AnchorPoint")
		x = pc.x + pc.w * pos.X.Scale + pos.X.Offset * pc.s - anchor.X * w
		y = pc.y + pc.h * pos.Y.Scale + pos.Y.Offset * pc.s - anchor.Y * h
	end
	return { x = x, y = y, w = w, h = h, s = pc.s * own }
end

local function computeBox(inst)
	local cached = layoutCache[inst]
	if cached and cached.epoch == Mock.GuiEpoch then
		return cached
	end
	local st = inst[STATE]
	local box
	if not st.class.isA.GuiObject then
		box = layerBox(inst)
	else
		local parent = st.parent
		local pc
		if parent and parent[STATE].class.isA.GuiBase2d then
			pc = contentOf(parent, computeBox(parent))
		else
			pc = { x = 0, y = 0, w = Mock.Viewport.X, h = Mock.Viewport.Y, s = 1 }
		end
		local arr = parent and parent[STATE].class.isA.GuiBase2d and arrangement(parent, pc, true) or false
		local slot = arr and arr.map[inst] or nil
		box = placeIn(inst, pc, slot)
		if parent and parent[STATE].class.isA.ScrollingFrame then
			-- children scroll with the canvas
			local cp = prop(parent, "CanvasPosition")
			box.x, box.y = box.x - cp.X, box.y - cp.Y
		end
	end
	box.epoch = Mock.GuiEpoch
	layoutCache[inst] = box
	return box
end
Mock.GuiBox = function(inst)
	local b = computeBox(inst)
	return { x = b.x, y = b.y, w = b.w, h = b.h, scale = b.s }
end
-- the size of the ScreenGui / BillboardGui / SurfaceGui area an object lives in (nil when detached)
Mock.GuiLayerSize = function(inst)
	local cur = inst
	while cur do
		if cur[STATE].class.isA.LayerCollector then
			local b = computeBox(cur)
			return v2(b.w, b.h)
		end
		cur = cur[STATE].parent
	end
	return nil
end

defclass("GuiBase", "Instance", { creatable = false })
defclass("GuiBase2d", "GuiBase", {
	creatable = false,
	getters = {
		AbsoluteSize = function(self)
			local b = computeBox(self)
			return v2(b.w, b.h)
		end,
		AbsolutePosition = function(self)
			local b = computeBox(self)
			return v2(b.x, b.y)
		end,
		AbsoluteRotation = function()
			return 0
		end,
	},
})

defclass("LayerCollector", "GuiBase2d", {
	creatable = false,
	props = { Enabled = T.bool(true), ResetOnSpawn = T.bool(true), ZIndexBehavior = T.enum("ZIndexBehavior", "Sibling") },
})
defclass("ScreenGui", "LayerCollector", {
	creatable = true,
	props = { DisplayOrder = T.num(0), IgnoreGuiInset = T.bool(false), OnTopOfCoreBlur = T.bool(false), ClipToDeviceSafeArea = T.bool(true), ScreenInsets = T.any(nil), SafeAreaCompatibility = T.any(nil) },
})
defclass("BillboardGui", "LayerCollector", {
	creatable = true,
	props = {
		Adornee = T.inst(), AlwaysOnTop = T.bool(false), Active = T.bool(false), Brightness = T.num(1), ClipsDescendants = T.bool(false),
		DistanceLowerLimit = T.num(0), DistanceUpperLimit = T.num(-1), DistanceStep = T.num(10), ExtentsOffset = T.v3(0, 0, 0),
		ExtentsOffsetWorldSpace = T.v3(0, 0, 0), LightInfluence = T.num(0), MaxDistance = T.num(huge), Size = T.u2(0, 100, 0, 100),
		SizeOffset = T.v2(0, 0), StudsOffset = T.v3(0, 0, 0), StudsOffsetWorldSpace = T.v3(0, 0, 0), PlayerToHideFrom = T.inst(),
	},
})
defclass("SurfaceGui", "LayerCollector", {
	creatable = true,
	props = {
		Adornee = T.inst(), AlwaysOnTop = T.bool(false), Active = T.bool(true), Brightness = T.num(1), CanvasSize = T.v2(800, 600),
		ClipsDescendants = T.bool(true), Face = T.enum("NormalId", "Front"), LightInfluence = T.num(1), PixelsPerStud = T.num(50),
		SizingMode = T.enum("SurfaceGuiSizingMode", "FixedSize"), ToolPunchThroughDistance = T.num(0), ZOffset = T.num(0),
	},
})
defclass("GuiObject", "GuiBase2d", {
	creatable = false,
	props = {
		Active = T.bool(false), AnchorPoint = T.v2(0, 0), AutomaticSize = T.enum("AutomaticSize", "None"), BackgroundColor3 = T.rgb(163, 162, 165),
		BackgroundTransparency = T.num(0), BorderColor3 = T.rgb(27, 42, 53), BorderMode = T.enum("BorderMode", "Outline"), BorderSizePixel = T.num(1),
		ClipsDescendants = T.bool(false), LayoutOrder = T.num(0), Position = T.u2(0, 0, 0, 0), Rotation = T.num(0), Selectable = T.bool(false),
		Size = T.u2(0, 0, 0, 0), SizeConstraint = T.enum("SizeConstraint", "RelativeXY"), Visible = T.bool(true), ZIndex = T.num(1),
		Interactable = T.bool(true), SelectionImageObject = T.inst(),
	},
	events = { "InputBegan", "InputEnded", "InputChanged", "MouseEnter", "MouseLeave", "MouseMoved", "MouseWheelForward", "MouseWheelBackward", "SelectionGained", "SelectionLost", "TouchTap", "TouchPan", "TouchPinch", "TouchLongPress", "TouchRotate", "TouchSwipe" },
	methods = {
		TweenPosition = function(self, pos)
			self.Position = pos
			return true
		end,
		TweenSize = function(self, size)
			self.Size = size
			return true
		end,
		TweenSizeAndPosition = function(self, size, pos)
			self.Size = size
			self.Position = pos
			return true
		end,
	},
})
defclass("Frame", "GuiObject", { creatable = true, props = { Style = T.any(nil) } })
defclass("CanvasGroup", "GuiObject", { creatable = true, props = { GroupTransparency = T.num(0), GroupColor3 = T.rgb(255, 255, 255) } })
defclass("ScrollingFrame", "GuiObject", {
	creatable = true,
	props = { CanvasSize = T.u2(0, 0, 2, 0), CanvasPosition = T.v2(0, 0), ScrollBarThickness = T.num(12), ScrollingEnabled = T.bool(true), AutomaticCanvasSize = T.enum("AutomaticSize", "None"), ScrollingDirection = T.enum("ScrollingDirection", "XY"), ScrollBarImageColor3 = T.rgb(0, 0, 0), ScrollBarImageTransparency = T.num(0) },
})
defclass("ViewportFrame", "GuiObject", { creatable = true, props = { CurrentCamera = T.inst(), ImageColor3 = T.rgb(255, 255, 255), ImageTransparency = T.num(0), Ambient = T.rgb(200, 200, 200), LightColor = T.rgb(140, 140, 140), LightDirection = T.v3(-1, -1, -1) } })
defclass("VideoFrame", "GuiObject", { creatable = true })

local function textBounds(self, st)
	local limit = nil
	if st.props.TextWrapped then
		limit = Mock.GuiBox(self).w
	end
	local w, h = Mock.TextExtent(self, limit)
	return v2(w, h)
end
local textProps = {
	Text = T.str(""), TextColor3 = T.rgb(27, 42, 53), TextSize = T.num(14, 1, 100), TextScaled = T.bool(false), TextWrapped = T.bool(false),
	TextXAlignment = T.enum("TextXAlignment", "Center"), TextYAlignment = T.enum("TextYAlignment", "Center"), Font = T.enum("Font", "SourceSans"),
	FontFace = T.font(), TextTransparency = T.num(0), TextStrokeColor3 = T.rgb(0, 0, 0), TextStrokeTransparency = T.num(1), RichText = T.bool(false),
	LineHeight = T.num(1), MaxVisibleGraphemes = T.num(-1), TextTruncate = T.enum("TextTruncate", "None"), LocalizationMatchIdentifier = T.str(""),
	TextDirection = T.any(nil), OpenTypeFeatures = T.str(""),
}
local textGetters = {
	TextBounds = textBounds,
	TextFits = function()
		return true
	end,
	ContentText = function(_, st)
		return st.props.Text or ""
	end,
}
local function textInit(inst, st)
	st.isText = true
	st.onProp = function(self, s, key, value)
		if key == "Font" then
			s.fontAssigned = true
			s.fontValue = value
		elseif key == "FontFace" then
			s.fontAssigned = true
			s.fontValue = value
		end
	end
end
local function copyProps(base, extra)
	local out = {}
	for k, v in pairs(base) do
		out[k] = v
	end
	for k, v in pairs(extra or {}) do
		out[k] = v
	end
	return out
end
defclass("TextLabel", "GuiObject", { creatable = true, props = textProps, getters = textGetters, init = textInit })
local buttonEvents = { "Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click", "MouseButton2Down", "MouseButton2Up", "TouchLongPress" }
defclass("TextButton", "GuiObject", {
	creatable = true,
	props = copyProps(textProps, { AutoButtonColor = T.bool(true), Modal = T.bool(false), Selected = T.bool(false), Style = T.any(nil) }),
	getters = textGetters,
	events = buttonEvents,
	init = textInit,
})
defclass("TextBox", "GuiObject", {
	creatable = true,
	props = copyProps(textProps, { ClearTextOnFocus = T.bool(true), MultiLine = T.bool(false), PlaceholderText = T.str(""), PlaceholderColor3 = T.rgb(178, 178, 178), ShowNativeInput = T.bool(true), TextEditable = T.bool(true), CursorPosition = T.num(-1), SelectionStart = T.num(-1) }),
	getters = textGetters,
	events = { "FocusLost", "Focused", "ReturnPressedFromOnScreenKeyboard" },
	methods = {
		CaptureFocus = function() end,
		ReleaseFocus = function() end,
		IsFocused = function()
			return false
		end,
	},
	init = textInit,
})
local imageProps = { Image = T.str(""), ImageColor3 = T.rgb(255, 255, 255), ImageTransparency = T.num(0), ImageRectOffset = T.v2(0, 0), ImageRectSize = T.v2(0, 0), ScaleType = T.enum("ScaleType", "Stretch"), SliceCenter = T.any(nil), SliceScale = T.num(1), TileSize = T.u2(1, 0, 1, 0), ResampleMode = T.any(nil) }
defclass("ImageLabel", "GuiObject", { creatable = true, props = imageProps })
defclass("ImageButton", "GuiObject", { creatable = true, props = copyProps(imageProps, { AutoButtonColor = T.bool(true), Modal = T.bool(false), Selected = T.bool(false) }), events = buttonEvents })

defclass("UIBase", "Instance", { creatable = false })
defclass("UICorner", "UIBase", { creatable = true, props = { CornerRadius = T.ud(0, 8) } })
defclass("UIStroke", "UIBase", {
	creatable = true,
	props = { ApplyStrokeMode = T.enum("ApplyStrokeMode", "Contextual"), Color = T.rgb(0, 0, 0), Enabled = T.bool(true), LineJoinMode = T.enum("LineJoinMode", "Round"), Thickness = T.num(1), Transparency = T.num(0) },
})
defclass("UIGradient", "UIBase", {
	creatable = true,
	props = { Color = T.cs(255, 255, 255), Enabled = T.bool(true), Offset = T.v2(0, 0), Rotation = T.num(0), Transparency = T.ns(0) },
})
local layoutProps = { FillDirection = T.enum("FillDirection", "Vertical"), HorizontalAlignment = T.enum("HorizontalAlignment", "Left"), VerticalAlignment = T.enum("VerticalAlignment", "Top"), SortOrder = T.enum("SortOrder", "Name"), Padding = T.ud(0, 0) }
defclass("UIListLayout", "UIBase", {
	creatable = true,
	props = copyProps(layoutProps, { Wraps = T.bool(false), ItemLineAlignment = T.any(nil), HorizontalFlex = T.any(nil), VerticalFlex = T.any(nil) }),
	getters = {
		AbsoluteContentSize = function()
			return v2(0, 0)
		end,
	},
})
defclass("UIGridLayout", "UIBase", {
	creatable = true,
	props = copyProps(layoutProps, { FillDirection = T.enum("FillDirection", "Horizontal"), CellSize = T.u2(0, 100, 0, 100), CellPadding = T.u2(0, 5, 0, 5), StartCorner = T.enum("StartCorner", "TopLeft"), FillDirectionMaxCells = T.num(0) }),
	getters = {
		AbsoluteContentSize = function()
			return v2(0, 0)
		end,
	},
})
defclass("UIPageLayout", "UIBase", { creatable = true, props = copyProps(layoutProps, { Animated = T.bool(true), Circular = T.bool(false), TweenTime = T.num(1) }) })
defclass("UITableLayout", "UIBase", { creatable = true })
defclass("UIPadding", "UIBase", { creatable = true, props = { PaddingBottom = T.ud(0, 0), PaddingLeft = T.ud(0, 0), PaddingRight = T.ud(0, 0), PaddingTop = T.ud(0, 0) } })
defclass("UIScale", "UIBase", { creatable = true, props = { Scale = T.num(1) } })
defclass("UIAspectRatioConstraint", "UIBase", { creatable = true, props = { AspectRatio = T.num(1), AspectType = T.enum("AspectType", "FitWithinMaxSize"), DominantAxis = T.enum("DominantAxis", "Width") } })
defclass("UISizeConstraint", "UIBase", { creatable = true, props = { MaxSize = T.v2(huge, huge), MinSize = T.v2(0, 0) } })
defclass("UITextSizeConstraint", "UIBase", { creatable = true, props = { MaxTextSize = T.num(100), MinTextSize = T.num(1) } })
defclass("UIFlexItem", "UIBase", { creatable = true })

defclass("BasePlayerGui", "Instance", { creatable = false })
defclass("PlayerGui", "BasePlayerGui", { creatable = false, methods = { GetGuiObjectsAtPosition = function() return {} end } })
defclass("PlayerScripts", "Instance", { creatable = false })
defclass("StarterGear", "Instance", { creatable = false })

end
----------------------------------------------------------------------------------------------------
-- Humanoid, Player, characters
----------------------------------------------------------------------------------------------------
local Players_ -- the Players service instance (set once created)
local loadCharacter -- forward

do
local function respawnDelay()
	return Players_ and Players_[STATE].props.RespawnTime or 5
end


local function killHumanoid(hum, st)
	if st.dead then
		return
	end
	st.dead = true
	st.humState = enumItem("HumanoidStateType", "Dead")
	fireEvent(st, "StateChanged", enumItem("HumanoidStateType", "Running"), st.humState)
	fireEvent(st, "Died")
	local char = st.parent
	if char and Players_ then
		local player = Mock.GetPlayerFromCharacter(char)
		if player and Players_[STATE].props.CharacterAutoLoads ~= false then
			task.delay(respawnDelay(), function()
				if not player[STATE].destroyed and player[STATE].props.Character == char then
					loadCharacter(player)
				end
			end)
		end
	end
end

defclass("Humanoid", "Instance", {
	creatable = true,
	props = {
		WalkSpeed = T.num(16), JumpPower = T.num(50), JumpHeight = T.num(7.2), UseJumpPower = T.bool(true), HipHeight = T.num(0),
		AutoRotate = T.bool(true), AutoJumpEnabled = T.bool(true), PlatformStand = T.bool(false), Sit = T.bool(false), Jump = T.bool(false),
		MoveDirection = T.v3(0, 0, 0), WalkToPoint = T.v3(0, 0, 0), WalkToPart = T.inst(), RigType = T.enum("RigType", "R15"),
		DisplayDistanceType = T.enum("HumanoidDisplayDistanceType", "Viewer"), HealthDisplayType = T.enum("HumanoidHealthDisplayType", "DisplayWhenDamaged"),
		HealthDisplayDistance = T.num(100), NameDisplayDistance = T.num(100), DisplayName = T.str(""), CameraOffset = T.v3(0, 0, 0),
		BreakJointsOnDeath = T.bool(true), RequiresNeck = T.bool(true), MaxSlopeAngle = T.num(89), FloorMaterial = T.enum("Material", "Air"),
		SeatPart = T.inst(), NameOcclusion = T.any(nil),
	},
	getters = {
		Health = function(_, st)
			local h = st.props.Health
			if h == nil then
				return 100
			end
			return h
		end,
		MaxHealth = function(_, st)
			local h = st.props.MaxHealth
			if h == nil then
				return 100
			end
			return h
		end,
		RootPart = function(self, st)
			local p = st.parent
			return p and IM.FindFirstChild(p, "HumanoidRootPart") or nil
		end,
	},
	setters = {
		Health = function(self, st, v)
			if rawtype(v) ~= "number" then
				error("Unable to assign property Health. number expected, got " .. typeof(v), 3)
			end
			if v ~= v then
				diag("nan", "Humanoid.Health", "NaN assigned to Humanoid.Health")
				return
			end
			if st.dead then
				return
			end
			local maxh = self.MaxHealth
			if v > maxh then
				v = maxh
			end
			if v < 0 then
				v = 0
			end
			local old = self.Health
			if v == old then
				return
			end
			st.props.Health = v
			firePropChanged(self, st, "Health")
			fireEvent(st, "HealthChanged", v)
			if Mock._onHealth then
				Mock._onHealth(self, st, v)
			end
			if v <= 0 then
				killHumanoid(self, st)
			end
		end,
		MaxHealth = function(self, st, v)
			if rawtype(v) ~= "number" then
				error("Unable to assign property MaxHealth. number expected, got " .. typeof(v), 3)
			end
			st.props.MaxHealth = v
			firePropChanged(self, st, "MaxHealth")
			if Mock._onHealth then
				Mock._onHealth(self, st, self.Health)
			end
			if self.Health > v then
				self.Health = v
			end
		end,
	},
	events = { "Died", "HealthChanged", "Running", "Jumping", "FreeFalling", "StateChanged", "Seated", "Touched", "MoveToFinished", "Climbing", "Swimming", "GettingUp", "FallingDown", "PlatformStanding" },
	methods = {
		TakeDamage = function(self, amount)
			if rawtype(amount) ~= "number" then
				error("invalid argument #1 to 'TakeDamage' (number expected, got " .. typeof(amount) .. ")", 2)
			end
			local st = self[STATE]
			local char = st.parent
			if char then
				for _, c in ipairs(char[STATE].children) do
					if c[STATE].class.name == "ForceField" and c[STATE].props.Visible ~= nil then
						return
					end
				end
			end
			if amount > 0 or self.Health < self.MaxHealth then
				self.Health = self.Health - amount
			end
		end,
		GetState = function(self)
			return self[STATE].humState or enumItem("HumanoidStateType", "Running")
		end,
		ChangeState = function(self, state)
			local st = self[STATE]
			local item = coerceEnum(state, "HumanoidStateType")
			if not item then
				error("invalid argument #1 to 'ChangeState' (HumanoidStateType expected)", 2)
			end
			st.humState = item
			if item.Name == "Dead" then
				self.Health = 0
			end
		end,
		SetStateEnabled = function() end,
		GetStateEnabled = function()
			return true
		end,
		MoveTo = function(self, pos)
			self[STATE].props.WalkToPoint = pos
			task.delay(0.1, function()
				fireEvent(self[STATE], "MoveToFinished", true)
			end)
		end,
		Move = function(self, dir)
			self[STATE].props.MoveDirection = dir
		end,
		EquipTool = function() end,
		UnequipTools = function() end,
		AddAccessory = function() end,
		GetAccessories = function()
			return {}
		end,
		LoadAnimation = function()
			return { Play = function() end, Stop = function() end, AdjustSpeed = function() end, Destroy = function() end }
		end,
		GetPlayingAnimationTracks = function()
			return {}
		end,
	},
	init = function(inst, st)
		st.humState = nil
	end,
})

local CHARACTER_PARTS = {
	{ "HumanoidRootPart", 2, 2, 1, 0, 0, 0 },
	{ "LowerTorso", 2, 0.4, 1, 0, -0.6, 0 },
	{ "UpperTorso", 2, 1.6, 1, 0, 0.5, 0 },
	{ "Head", 1.2, 1.2, 1.2, 0, 1.9, 0 },
	{ "LeftUpperArm", 1, 1.2, 1, -1.5, 0.9, 0 },
	{ "RightUpperArm", 1, 1.2, 1, 1.5, 0.9, 0 },
	{ "LeftHand", 1, 0.4, 1, -1.5, -0.2, 0 },
	{ "RightHand", 1, 0.4, 1, 1.5, -0.2, 0 },
	{ "LeftUpperLeg", 1, 1.2, 1, -0.5, -1.7, 0 },
	{ "RightUpperLeg", 1, 1.2, 1, 0.5, -1.7, 0 },
	{ "LeftFoot", 1, 0.5, 1, -0.5, -2.75, 0 },
	{ "RightFoot", 1, 0.5, 1, 0.5, -2.75, 0 },
}
Mock.CharacterPartNames = {}
for i, p in ipairs(CHARACTER_PARTS) do
	Mock.CharacterPartNames[i] = p[1]
end

local function buildCharacter(player, spawnCF)
	local char = makeInstance("Model")
	char[STATE].name = player[STATE].name
	local humanoid = makeInstance("Humanoid")
	humanoid[STATE].props.UseJumpPower = false -- like a fresh place: StarterPlayer.CharacterUseJumpPower is false
	humanoid[STATE].props.JumpHeight = 7.2
	local parts = {}
	for _, spec in ipairs(CHARACTER_PARTS) do
		local part = makeInstance("Part")
		local pst = part[STATE]
		pst.name = spec[1]
		pst.props.Size = v3(spec[2], spec[3], spec[4])
		pst.props.CFrame = spawnCF * cf(spec[5], spec[6], spec[7], 1, 0, 0, 0, 1, 0, 0, 0, 1)
		pst.props.Anchored = false
		if spec[1] == "HumanoidRootPart" then
			pst.props.Transparency = 1
		end
		pst.props.CanCollide = spec[1] == "HumanoidRootPart" and true or false
		if spec[1] == "Head" then
			pst.props.CanCollide = true
		end
		setParentRaw(part, pst, char)
		parts[spec[1]] = part
	end
	local att = makeInstance("Attachment")
	att[STATE].name = "RootRigAttachment"
	setParentRaw(att, att[STATE], parts.HumanoidRootPart)
	setParentRaw(humanoid, humanoid[STATE], char)
	local animator = makeInstance("Animator")
	setParentRaw(animator, animator[STATE], humanoid)
	char[STATE].props.PrimaryPart = parts.HumanoidRootPart
	-- Roblox characters carry the legacy "Health" script that regenerates 1% of MaxHealth per second.
	-- The mock emulates it (see regenStep) for as long as the script exists.
	if Mock.Context == "server" then
		local regen = makeInstance("Script")
		regen[STATE].name = "Health"
		setParentRaw(regen, regen[STATE], char)
	end
	return char
end

local function findSpawnCFrame()
	local ws = Mock.workspace
	if ws then
		local found
		eachDescendant(ws, function(d)
			if not found and d[STATE].class.name == "SpawnLocation" and d[STATE].props.Enabled ~= false then
				found = d
			end
		end)
		if found then
			local c = currentCFrame(found[STATE])
			return c * cf(0, 4, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
		end
	end
	return Mock.DefaultSpawn or cf(0, 6, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
end

-- Mirrors Roblox: ScreenGuis with ResetOnSpawn = true are removed on respawn (and re-cloned from StarterGui).
local function resetPlayerGui(player)
	local pg = IM.FindFirstChildOfClass(player, "PlayerGui")
	if not pg then
		return
	end
	for _, g in ipairs(IM.GetChildren(pg)) do
		local gst = g[STATE]
		if gst.class.isA.LayerCollector and gst.props.ResetOnSpawn ~= false then
			destroy(g)
		end
	end
	local starter = Mock.StarterGui
	if starter then
		for _, g in ipairs(IM.GetChildren(starter)) do
			if g[STATE].class.isA.LayerCollector then
				local copy = IM.Clone(g)
				if copy then
					setParent(copy, copy[STATE], pg)
				end
			end
		end
	end
end

loadCharacter = function(player)
	local pst = player[STATE]
	if pst.destroyed then
		return nil
	end
	local old = pst.props.Character
	if old then
		fireEvent(pst, "CharacterRemoving", old)
		destroy(old)
		pst.props.Character = nil
	end
	local spawnCF = pst.spawnOverride or findSpawnCFrame()
	pst.spawnOverride = nil
	local char = buildCharacter(player, spawnCF)
	setParent(char, char[STATE], Mock.workspace)
	pst.props.Character = char
	firePropChanged(player, pst, "Character")
	resetPlayerGui(player)
	fireEvent(pst, "CharacterAdded", char)
	return char
end
Mock.LoadCharacter = loadCharacter

defclass("Player", "Instance", {
	creatable = false,
	props = {
		UserId = T.num(0), DisplayName = T.str(""), Character = T.inst(), Team = T.inst(), TeamColor = T.brick(), Neutral = T.bool(true), AccountAge = T.num(1000),
		CameraMaxZoomDistance = T.num(128), CameraMinZoomDistance = T.num(0.5), CameraMode = T.any(nil), DevCameraOcclusionMode = T.any(nil),
		HealthDisplayDistance = T.num(100), NameDisplayDistance = T.num(100), RespawnLocation = T.inst(), MembershipType = T.any(nil), FollowUserId = T.num(0),
		CharacterAppearanceId = T.num(0), AutoJumpEnabled = T.bool(true), GameplayPaused = T.bool(false), ReplicationFocus = T.inst(), Guest = T.bool(false),
		LocaleId = T.str("en-us"), CanLoadCharacterAppearance = T.bool(true),
	},
	events = { "CharacterAdded", "CharacterRemoving", "CharacterAppearanceLoaded", "Chatted", "Idled" },
	methods = {
		LoadCharacter = function(self)
			if Mock.Context ~= "server" then
				error("LoadCharacter can only be called from the server", 2)
			end
			return loadCharacter(self)
		end,
		Kick = function(self, msg)
			Mock.KickedPlayers[#Mock.KickedPlayers + 1] = { player = self, message = msg }
			Mock.RemovePlayer(self)
		end,
		GetMouse = function()
			return setmetatable({ X = 0, Y = 0, Hit = CF_IDENTITY, Target = nil }, { __index = function() return nil end })
		end,
		IsFriendsWith = function()
			return false
		end,
		IsInGroup = function()
			return false
		end,
		GetRankInGroup = function()
			return 0
		end,
		GetRoleInGroup = function()
			return "Guest"
		end,
		GetNetworkPing = function()
			return 0.05
		end,
		ClearCharacterAppearance = function() end,
		HasAppearanceLoaded = function()
			return true
		end,
		LoadCharacterAppearance = function() end,
		DistanceFromCharacter = function(self, pos)
			local char = self[STATE].props.Character
			local root = char and IM.FindFirstChild(char, "HumanoidRootPart")
			if not root then
				return 0
			end
			return (root.Position - pos).Magnitude
		end,
		GetJoinData = function()
			return {}
		end,
		RequestStreamAroundAsync = function() end,
	},
	init = function(inst, st)
		for _, spec in ipairs({ { "PlayerGui", "PlayerGui" }, { "Backpack", "Backpack" }, { "PlayerScripts", "PlayerScripts" }, { "StarterGear", "StarterGear" } }) do
			local child = makeInstance(spec[2])
			child[STATE].name = spec[1]
			setParentRaw(child, child[STATE], inst)
		end
	end,
})
Mock.KickedPlayers = {}

function Mock.GetPlayerFromCharacter(model)
	if not Players_ then
		return nil
	end
	for _, p in ipairs(Players_[STATE].children) do
		if p[STATE].props.Character == model then
			return p
		end
	end
	return nil
end

end
----------------------------------------------------------------------------------------------------
-- Spatial queries + touch simulation
----------------------------------------------------------------------------------------------------
do
local function partFilterAllows(part, params)
	if not params then
		return true
	end
	if rawget(params, "RespectCanCollide") == true and part[STATE].props.CanCollide == false then
		return false
	end
	local list = rawget(params, "FilterDescendantsInstances") or {}
	local ftype = rawget(params, "FilterType")
	local include = ftype ~= nil and (ftype.Name == "Include" or ftype.Name == "Whitelist")
	local hit = false
	for i = 1, #list do
		local f = list[i]
		if f == part or (isInstance(f) and IM.IsDescendantOf(part, f)) then
			hit = true
			break
		end
	end
	if include then
		return hit
	end
	return not hit
end

local function worldParts()
	local out = {}
	if Mock.workspace then
		eachDescendant(Mock.workspace, function(d)
			if d[STATE].class.isA.BasePart then
				out[#out + 1] = d
			end
		end)
	end
	return out
end

-- Separating-axis test on the two boxes' own axes.
local function boxOverlap(cfA, sizeA, cfB, sizeB)
	local function oneWay(c1, s1, c2, s2)
		-- express box 2 in box 1's frame
		local inv = c1:Inverse()
		local rel = inv * c2
		local hx1, hy1, hz1 = s1.X / 2, s1.Y / 2, s1.Z / 2
		local hx2, hy2, hz2 = s2.X / 2, s2.Y / 2, s2.Z / 2
		local ex = abs(rel.a) * hx2 + abs(rel.b) * hy2 + abs(rel.c) * hz2
		local ey = abs(rel.d) * hx2 + abs(rel.e) * hy2 + abs(rel.f) * hz2
		local ez = abs(rel.g) * hx2 + abs(rel.h) * hy2 + abs(rel.i) * hz2
		return abs(rel.x) <= hx1 + ex and abs(rel.y) <= hy1 + ey and abs(rel.z) <= hz1 + ez
	end
	return oneWay(cfA, sizeA, cfB, sizeB) and oneWay(cfB, sizeB, cfA, sizeA)
end
Mock.BoxOverlap = boxOverlap

local function partSize(st)
	return st.props.Size or v3(4, 1, 2)
end

local function boundsInBox(cframe, size, params)
	local out = {}
	local maxParts = params and rawget(params, "MaxParts") or 0
	for _, part in ipairs(worldParts()) do
		local pst = part[STATE]
		if pst.props.CanQuery ~= false and partFilterAllows(part, params) then
			if boxOverlap(cframe, size, currentCFrame(pst), partSize(pst)) then
				out[#out + 1] = part
				if maxParts and maxParts > 0 and #out >= maxParts then
					break
				end
			end
		end
	end
	return out
end

local function boundsInRadius(position, radius, params)
	local out = {}
	local maxParts = params and rawget(params, "MaxParts") or 0
	for _, part in ipairs(worldParts()) do
		local pst = part[STATE]
		if pst.props.CanQuery ~= false and partFilterAllows(part, params) then
			local c = currentCFrame(pst)
			local s = partSize(pst)
			local local_ = c:PointToObjectSpace(position)
			local dx = mmax(abs(local_.X) - s.X / 2, 0)
			local dy = mmax(abs(local_.Y) - s.Y / 2, 0)
			local dz = mmax(abs(local_.Z) - s.Z / 2, 0)
			if dx * dx + dy * dy + dz * dz <= radius * radius then
				out[#out + 1] = part
				if maxParts and maxParts > 0 and #out >= maxParts then
					break
				end
			end
		end
	end
	return out
end

local RaycastResultMT = {}
regType(RaycastResultMT, "RaycastResult")
RaycastResultMT.__index = function(_, k)
	error(tostring(k) .. " is not a valid member of RaycastResult", 2)
end

local function raycast(origin, direction, params)
	if typeof(origin) ~= "Vector3" then
		error("invalid argument #1 to 'Raycast' (Vector3 expected, got " .. typeof(origin) .. ")", 3)
	end
	if typeof(direction) ~= "Vector3" then
		error("invalid argument #2 to 'Raycast' (Vector3 expected, got " .. typeof(direction) .. ")", 3)
	end
	if params ~= nil and typeof(params) ~= "RaycastParams" then
		error("invalid argument #3 to 'Raycast' (RaycastParams expected, got " .. typeof(params) .. ")", 3)
	end
	local best, bestT, bestN
	for _, part in ipairs(worldParts()) do
		local pst = part[STATE]
		if pst.props.CanQuery ~= false and partFilterAllows(part, params) then
			local c = currentCFrame(pst)
			local s = partSize(pst)
			local o = c:PointToObjectSpace(origin)
			local d = c:VectorToObjectSpace(direction)
			local tmin, tmax = 0, 1
			local axisHit, sgn = nil, 1
			local hs = { s.X / 2, s.Y / 2, s.Z / 2 }
			local oo = { o.X, o.Y, o.Z }
			local dd = { d.X, d.Y, d.Z }
			local ok = true
			for k = 1, 3 do
				if abs(dd[k]) < 1e-9 then
					if abs(oo[k]) > hs[k] then
						ok = false
						break
					end
				else
					local t1 = (-hs[k] - oo[k]) / dd[k]
					local t2 = (hs[k] - oo[k]) / dd[k]
					local nsgn = -1
					if t1 > t2 then
						t1, t2 = t2, t1
						nsgn = 1
					end
					if t1 > tmin then
						tmin = t1
						axisHit = k
						sgn = nsgn
					end
					if t2 < tmax then
						tmax = t2
					end
					if tmin > tmax then
						ok = false
						break
					end
				end
			end
			if ok and axisHit and (not bestT or tmin < bestT) then
				best, bestT = part, tmin
				local n = { 0, 0, 0 }
				n[axisHit] = sgn
				bestN = c:VectorToWorldSpace(v3(n[1], n[2], n[3]))
			end
		end
	end
	if not best then
		return nil
	end
	return setmetatable({
		Instance = best,
		Position = origin + direction * bestT,
		Normal = bestN,
		Material = best[STATE].props.Material or enumItem("Material", "Plastic"),
		Distance = bestT * direction.Magnitude,
	}, RaycastResultMT)
end

-- Touch simulation: fires Touched / TouchEnded between registered parts and character parts.
Mock.TouchSim = false
Mock._touching = setmetatable({}, { __mode = "k" })
local TOUCHER_NAMES = { HumanoidRootPart = true, LeftFoot = true, RightFoot = true, Head = true }

local function inWorkspace(inst)
	return Mock.workspace ~= nil and IM.IsDescendantOf(inst, Mock.workspace)
end

local function touchStep()
	if not Players_ then
		return
	end
	local touchers = {}
	for _, p in ipairs(Players_[STATE].children) do
		local char = p[STATE].props.Character
		if char and not char[STATE].destroyed then
			for _, c in ipairs(char[STATE].children) do
				if TOUCHER_NAMES[c[STATE].name] and c[STATE].class.isA.BasePart then
					touchers[#touchers + 1] = c
				end
			end
		end
	end
	for _, extra in ipairs(Mock.ExtraTouchers or {}) do
		touchers[#touchers + 1] = extra
	end
	for part in pairs(touchRegistry) do
		local pst = part[STATE]
		if pst.destroyed or not inWorkspace(part) then
			local set = Mock._touching[part]
			if set then
				for other in pairs(set) do
					set[other] = nil
					fireEvent(pst, "TouchEnded", other)
				end
			end
		elseif pst.props.CanTouch ~= false then
			local c = currentCFrame(pst)
			local s = partSize(pst)
			local radius = sqrt(s.X * s.X + s.Y * s.Y + s.Z * s.Z) / 2
			local set = Mock._touching[part]
			if not set then
				set = setmetatable({}, { __mode = "k" })
				Mock._touching[part] = set
			end
			for _, t in ipairs(touchers) do
				local tst = t[STATE]
				if t ~= part and t[STATE].parent ~= pst.parent then
					local tc = currentCFrame(tst)
					local ts = partSize(tst)
					local rr = radius + sqrt(ts.X * ts.X + ts.Y * ts.Y + ts.Z * ts.Z) / 2
					local dx, dy, dz = tc.x - c.x, tc.y - c.y, tc.z - c.z
					local near = dx * dx + dy * dy + dz * dz <= rr * rr
					local inside = near and boxOverlap(c, s, tc, ts)
					if inside and not set[t] then
						set[t] = true
						fireEvent(pst, "Touched", t)
						fireEvent(tst, "Touched", part)
					elseif not inside and set[t] then
						set[t] = nil
						fireEvent(pst, "TouchEnded", t)
						fireEvent(tst, "TouchEnded", part)
					end
				end
			end
			for other in pairs(set) do
				if other[STATE].destroyed then
					set[other] = nil
					fireEvent(pst, "TouchEnded", other)
				end
			end
		end
	end
end
local function regenStep(dt)
	if not Players_ then
		return
	end
	for _, p in ipairs(Players_[STATE].children) do
		local char = p[STATE].props.Character
		if char and not char[STATE].destroyed then
			local script_ = findChildByName(char[STATE], "Health")
			if script_ and not script_[STATE].destroyed then
				local h = IM.FindFirstChildOfClass(char, "Humanoid")
				if h and not h[STATE].dead and h.Health > 0 and h.Health < h.MaxHealth then
					local hst = h[STATE]
					hst.regenAcc = (hst.regenAcc or 0) + dt
					if hst.regenAcc >= 1 then
						hst.regenAcc = hst.regenAcc - 1
						h.Health = mmin(h.MaxHealth, h.Health + h.MaxHealth * 0.01)
					end
				end
			end
		end
	end
end
Mock._afterStep = function(dt)
	regenStep(dt)
	if Mock.TouchSim then
		touchStep()
	end
end

-- Manually report a touch (for tests that do not use the simulation).
function Mock.Touch(part, other)
	local set = Mock._touching[part]
	if not set then
		set = setmetatable({}, { __mode = "k" })
		Mock._touching[part] = set
	end
	set[other] = true
	fireEvent(part[STATE], "Touched", other)
end
function Mock.Untouch(part, other)
	local set = Mock._touching[part]
	if set then
		set[other] = nil
	end
	fireEvent(part[STATE], "TouchEnded", other)
end

Mock._spatial = { boundsInBox = boundsInBox, boundsInRadius = boundsInRadius, raycast = raycast, partSize = partSize }
end
----------------------------------------------------------------------------------------------------
-- Services
----------------------------------------------------------------------------------------------------
do
local function service(name, def)
	def = def or {}
	def.creatable = false
	def.service = true
	return defclass(name, "Instance", def)
end

service("DataModel", {
	props = { PlaceId = T.num(1), GameId = T.num(1), JobId = T.str("mock-job"), PlaceVersion = T.num(1), CreatorId = T.num(1), CreatorType = T.any(nil) },
	events = { "Loaded", "Close" },
	methods = {
		GetService = function(self, name)
			if rawtype(name) ~= "string" then
				error("Argument 1 missing or nil", 2)
			end
			local st = self[STATE]
			for _, c in ipairs(st.children) do
				if c[STATE].class.name == name then
					return c
				end
			end
			if Mock.KnownServices and not Mock.KnownServices[name] then
				error(name .. " is not a valid Service name", 2)
			end
			local svc = makeInstance(name)
			setParentRaw(svc, svc[STATE], self)
			if Mock._onService then
				Mock._onService(name, svc)
			end
			return svc
		end,
		FindService = function(self, name)
			for _, c in ipairs(self[STATE].children) do
				if c[STATE].class.name == name then
					return c
				end
			end
			return nil
		end,
		IsLoaded = function()
			return true
		end,
		BindToClose = function(self, fn)
			if Mock.Context ~= "server" then
				error("BindToClose can only be called from the server", 2)
			end
			if rawtype(fn) ~= "function" then
				error("invalid argument #1 to 'BindToClose' (function expected)", 2)
			end
			Mock.CloseCallbacks[#Mock.CloseCallbacks + 1] = fn
		end,
		GetObjects = function()
			return {}
		end,
	},
})
Mock.CloseCallbacks = {}

-- Runs every BindToClose callback (each in its own thread) and steps the clock until they finish.
function Mock.Shutdown(maxSeconds)
	local pending = #Mock.CloseCallbacks
	for _, fn in ipairs(Mock.CloseCallbacks) do
		task.spawn(function()
			local ok, err = pcall(fn)
			if not ok then
				reportError(err, "BindToClose")
			end
			pending = pending - 1
		end)
	end
	Mock.AdvanceUntil(function()
		return pending <= 0
	end, maxSeconds or 30)
	return pending <= 0
end

service("Workspace", {
	props = {
		Gravity = T.num(196.2), FallenPartsDestroyHeight = T.num(-500), StreamingEnabled = T.bool(false), AllowThirdPartySales = T.bool(false),
		CurrentCamera = T.inst(), Terrain = T.inst(), SignalBehavior = T.any(nil), GlobalWind = T.v3(0, 0, 0), AirDensity = T.num(0.0012),
		ClientAnimatorThrottling = T.any(nil), PhysicsSteppingMethod = T.any(nil), DistributedGameTime = T.num(0),
	},
	getters = {
		Terrain = function(self, st)
			return findChildByName(st, "Terrain")
		end,
	},
	methods = {
		GetPartBoundsInBox = function(self, cframe, size, params)
			if typeof(cframe) ~= "CFrame" or typeof(size) ~= "Vector3" then
				error("invalid arguments to GetPartBoundsInBox (CFrame, Vector3, OverlapParams?)", 2)
			end
			if params ~= nil and typeof(params) ~= "OverlapParams" then
				error("invalid argument #3 to 'GetPartBoundsInBox' (OverlapParams expected, got " .. typeof(params) .. ")", 2)
			end
			return Mock._spatial.boundsInBox(cframe, size, params)
		end,
		GetPartBoundsInRadius = function(self, position, radius, params)
			if typeof(position) ~= "Vector3" or rawtype(radius) ~= "number" then
				error("invalid arguments to GetPartBoundsInRadius (Vector3, number, OverlapParams?)", 2)
			end
			return Mock._spatial.boundsInRadius(position, radius, params)
		end,
		GetPartsInPart = function(self, part, params)
			local pst = part[STATE]
			return Mock._spatial.boundsInBox(currentCFrame(pst), Mock._spatial.partSize(pst), params)
		end,
		Raycast = function(self, origin, direction, params)
			return Mock._spatial.raycast(origin, direction, params)
		end,
		GetServerTimeNow = function()
			return EPOCH + Clock.now
		end,
		GetRealPhysicsFPS = function()
			return 60
		end,
		BulkMoveTo = function() end,
	},
})
defclass("Terrain", "BasePart", {
	creatable = false,
	-- Smooth-terrain API used to build soft cloud islands and ground. Voxel writes are not simulated; calls are
	-- recorded in Terrain[STATE].fills so tests can assert that terrain was written (count and materials).
	props = {
		Decoration = T.bool(false), WaterColor = T.rgb(12, 84, 92), WaterReflectance = T.num(1),
		WaterTransparency = T.num(0.3), WaterWaveSize = T.num(0.15), WaterWaveSpeed = T.num(10),
	},
	methods = {
		FillBlock = function(self, cf, size, material) local st = self[STATE]; st.fills = st.fills or {}; table.insert(st.fills, { kind = "Block", material = material }) end,
		FillBall = function(self, center, radius, material) local st = self[STATE]; st.fills = st.fills or {}; table.insert(st.fills, { kind = "Ball", material = material }) end,
		FillCylinder = function(self, cf, height, radius, material) local st = self[STATE]; st.fills = st.fills or {}; table.insert(st.fills, { kind = "Cylinder", material = material }) end,
		FillWedge = function(self, cf, size, material) local st = self[STATE]; st.fills = st.fills or {}; table.insert(st.fills, { kind = "Wedge", material = material }) end,
		FillRegion = function(self, region, resolution, material) local st = self[STATE]; st.fills = st.fills or {}; table.insert(st.fills, { kind = "Region", material = material }) end,
		Clear = function(self) self[STATE].fills = {} end,
		SetMaterialColor = function(self, material, color) local st = self[STATE]; st.materialColors = st.materialColors or {}; st.materialColors[tostring(material)] = color end,
		GetMaterialColor = function(self, material) local st = self[STATE]; return (st.materialColors and st.materialColors[tostring(material)]) or Color3.new(0.5, 0.5, 0.5) end,
	},
})

service("Players", {
	props = { CharacterAutoLoads = T.bool(true), RespawnTime = T.num(5), MaxPlayers = T.num(12), PreferredPlayers = T.num(12), BubbleChat = T.bool(false), ClassicChat = T.bool(false) },
	events = { "PlayerAdded", "PlayerRemoving", "PlayerMembershipChanged" },
	getters = {
		LocalPlayer = function()
			return Mock.LocalPlayer
		end,
		NumPlayers = function(_, st)
			return #st.children
		end,
	},
	methods = {
		GetPlayers = function(self)
			local out = {}
			for _, c in ipairs(self[STATE].children) do
				if c[STATE].class.isA.Player then
					out[#out + 1] = c
				end
			end
			return out
		end,
		GetPlayerByUserId = function(self, id)
			for _, c in ipairs(self[STATE].children) do
				if c[STATE].props.UserId == id then
					return c
				end
			end
			return nil
		end,
		GetPlayerFromCharacter = function(self, model)
			if model == nil then
				return nil
			end
			return Mock.GetPlayerFromCharacter(model)
		end,
		GetUserIdFromNameAsync = function(self, name)
			for _, c in ipairs(self[STATE].children) do
				if c[STATE].name == name then
					return c[STATE].props.UserId
				end
			end
			return 1
		end,
		GetNameFromUserIdAsync = function(self, id)
			local p = self:GetPlayerByUserId(id)
			return p and p.Name or "Player"
		end,
	},
	init = function(inst)
		Players_ = inst
		Mock.Players = inst
	end,
})

service("Lighting", {
	props = {
		Ambient = T.rgb(70, 70, 70), Brightness = T.num(2), ClockTime = T.num(14), ColorShift_Bottom = T.rgb(0, 0, 0), ColorShift_Top = T.rgb(0, 0, 0),
		EnvironmentDiffuseScale = T.num(0), EnvironmentSpecularScale = T.num(0), ExposureCompensation = T.num(0), FogColor = T.rgb(192, 192, 192),
		FogEnd = T.num(100000), FogStart = T.num(0), GeographicLatitude = T.num(41.73), GlobalShadows = T.bool(true), OutdoorAmbient = T.rgb(70, 70, 70),
		ShadowSoftness = T.num(0.2), Technology = T.enum("Technology", "ShadowMap"), LightingStyle = T.any(nil), PrioritizeLightingQuality = T.bool(false),
		Outlines = T.bool(false),
	},
	getters = {
		TimeOfDay = function(_, st)
			local t = st.props.ClockTime or 14
			return sformat("%02d:%02d:%02d", floor(t) % 24, floor((t % 1) * 60), floor((t * 3600) % 60))
		end,
	},
	setters = {
		TimeOfDay = function(self, st, v)
			local h, m, s = tostring(v):match("^(%d+):(%d+):?(%d*)$")
			if not h then
				error("Unable to assign property TimeOfDay. Invalid time string", 3)
			end
			st.props.ClockTime = tonumber(h) + tonumber(m) / 60 + (tonumber(s) or 0) / 3600
			firePropChanged(self, st, "ClockTime")
		end,
	},
	methods = {
		GetMinutesAfterMidnight = function(self)
			return self.ClockTime * 60
		end,
		SetMinutesAfterMidnight = function(self, m)
			self.ClockTime = m / 60
		end,
		GetSunDirection = function()
			return v3(0, 1, 0)
		end,
		GetMoonDirection = function()
			return v3(0, -1, 0)
		end,
	},
})
for _, n in ipairs({ "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService", "ServerStorage", "StarterPack", "Teams", "Chat", "SoundService", "TextChatService", "StarterPlayerScripts", "StarterCharacterScripts" }) do
	service(n, {})
end
service("StarterPlayer", { props = { CharacterWalkSpeed = T.num(16), CharacterJumpPower = T.num(50), CharacterJumpHeight = T.num(7.2), CharacterUseJumpPower = T.bool(false), CharacterMaxHealth = T.num(100), CameraMaxZoomDistance = T.num(128), CameraMinZoomDistance = T.num(0.5), AutoJumpEnabled = T.bool(true) } })
service("StarterGui", {
	props = { ScreenOrientation = T.any(nil), ShowDevelopmentGui = T.bool(true), ResetPlayerGuiOnSpawn = T.bool(true) },
	events = { "CoreGuiChangedSignal" },
	methods = {
		SetCoreGuiEnabled = function(self, coreType, enabled)
			if Mock.Context ~= "client" then
				-- allowed on the server too (affects new players) but nothing to do
			end
			if Mock.StarterGuiFailures and Mock.StarterGuiFailures > 0 then
				Mock.StarterGuiFailures = Mock.StarterGuiFailures - 1
				error("SetCoreGuiEnabled has not yet been registered by the CoreScripts", 2)
			end
			if typeof(coreType) ~= "EnumItem" or coreType.EnumType.Name ~= "CoreGuiType" then
				error("invalid argument #1 to 'SetCoreGuiEnabled' (CoreGuiType expected, got " .. typeof(coreType) .. ")", 2)
			end
			if rawtype(enabled) ~= "boolean" then
				error("invalid argument #2 to 'SetCoreGuiEnabled' (boolean expected, got " .. typeof(enabled) .. ")", 2)
			end
			Mock.CoreGui[coreType.Name] = enabled
			fireEvent(self[STATE], "CoreGuiChangedSignal", coreType, enabled)
		end,
		GetCoreGuiEnabled = function(self, coreType)
			local v = Mock.CoreGui[coreType.Name]
			if v == nil then
				return true
			end
			return v
		end,
		SetCore = function(self, name, value)
			Mock.CoreSettings[name] = value
		end,
		GetCore = function(self, name)
			return Mock.CoreSettings[name]
		end,
	},
})
Mock.CoreGui = {}
Mock.CoreSettings = {}

service("RunService", {
	getters = {
		RenderStepped = function(self, st)
			if Mock.Context ~= "client" then
				error("RenderStepped can only be used from a LocalScript (client)", 3)
			end
			return getSignal(self, st, "RenderStepped")
		end,
	},
	events = { "Heartbeat", "Stepped", "PreSimulation", "PostSimulation", "PreRender", "PreAnimation" },
	methods = {
		IsServer = function()
			return Mock.Context == "server"
		end,
		IsClient = function()
			return Mock.Context == "client"
		end,
		IsStudio = function()
			return Mock.Options.Studio
		end,
		IsRunning = function()
			return true
		end,
		IsRunMode = function()
			return false
		end,
		IsEdit = function()
			return false
		end,
		BindToRenderStep = function(self, name, priority, fn)
			if Mock.Context ~= "client" then
				error("BindToRenderStep can only be called from the client", 2)
			end
			if rawtype(fn) ~= "function" then
				error("invalid argument #3 to 'BindToRenderStep' (function expected)", 2)
			end
			Mock.RenderSteps[name] = { priority = priority, fn = fn }
		end,
		UnbindFromRenderStep = function(self, name)
			Mock.RenderSteps[name] = nil
		end,
		Pause = function() end,
		Run = function() end,
	},
})
Mock.RenderSteps = {}

service("CollectionService", {
	events = { "TagAdded", "TagRemoved" },
	methods = {
		AddTag = function(self, inst, tag)
			addTag(inst, tag)
		end,
		RemoveTag = function(self, inst, tag)
			removeTag(inst, tag)
		end,
		HasTag = function(self, inst, tag)
			return inst[STATE].tags[tag] == true
		end,
		GetTags = function(self, inst)
			return IM.GetTags(inst)
		end,
		GetTagged = function(self, tag)
			local out = {}
			local set = TagIndex[tag]
			if set then
				for inst in pairs(set) do
					local ist = inst[STATE]
					if not ist.destroyed and ist.tags[tag] and isInGame(inst) then
						out[#out + 1] = inst
					end
				end
			end
			return out
		end,
		GetAllTags = function()
			local out = {}
			for tag in pairs(TagIndex) do
				out[#out + 1] = tag
			end
			return out
		end,
		GetInstanceAddedSignal = function(self, tag)
			local ts = TagSignals[tag]
			if not ts then
				ts = {}
				TagSignals[tag] = ts
			end
			if not ts.added then
				ts.added = newSignal("CollectionService.InstanceAdded:" .. tag)
			end
			return ts.added
		end,
		GetInstanceRemovedSignal = function(self, tag)
			local ts = TagSignals[tag]
			if not ts then
				ts = {}
				TagSignals[tag] = ts
			end
			if not ts.removed then
				ts.removed = newSignal("CollectionService.InstanceRemoved:" .. tag)
			end
			return ts.removed
		end,
	},
})

service("Debris", {
	methods = {
		AddItem = function(self, item, lifetime)
			if not isInstance(item) then
				error("invalid argument #1 to 'AddItem' (Instance expected, got " .. typeof(item) .. ")", 2)
			end
			task.delay(lifetime or 10, function()
				if not item[STATE].destroyed then
					destroy(item)
				end
			end)
		end,
	},
})

-- Tween ------------------------------------------------------------------------------------------------
Mock.ActiveTweens = setmetatable({}, { __mode = "k" })
defclass("Tween", "Instance", {
	creatable = false,
	props = { Instance = T.inst(), TweenInfo = T.any(nil), PlaybackState = T.enum("PlaybackState", "Begin") },
	events = { "Completed" },
	methods = {
		Play = function(self)
			local st = self[STATE]
			local state = st.props.PlaybackState
			if state and state.Name == "Playing" then
				return
			end
			st.props.PlaybackState = enumItem("PlaybackState", "Playing")
			st.playId = (st.playId or 0) + 1
			local id = st.playId
			local info = st.info
			Mock.ActiveTweens[self] = true
			if info.RepeatCount >= 0 then
				local cycles = info.RepeatCount + 1
				local total = info.DelayTime + info.Time * cycles * (info.Reverses and 2 or 1)
				st.thread = task.delay(total, function()
					if st.playId ~= id then
						return
					end
					local target = st.target
					if not target[STATE].destroyed then
						if not info.Reverses then
							for prop, goal in pairs(st.goals) do
								target[prop] = goal
							end
						end
					end
					st.props.PlaybackState = enumItem("PlaybackState", "Completed")
					Mock.ActiveTweens[self] = nil
					fireEvent(st, "Completed", enumItem("PlaybackState", "Completed"))
				end)
			end
		end,
		Pause = function(self)
			local st = self[STATE]
			st.props.PlaybackState = enumItem("PlaybackState", "Paused")
			st.playId = (st.playId or 0) + 1
			if st.thread then
				task.cancel(st.thread)
				st.thread = nil
			end
			Mock.ActiveTweens[self] = nil
		end,
		Cancel = function(self)
			local st = self[STATE]
			local state = st.props.PlaybackState
			if not state or (state.Name ~= "Playing" and state.Name ~= "Paused") then
				return
			end
			st.props.PlaybackState = enumItem("PlaybackState", "Cancelled")
			st.playId = (st.playId or 0) + 1
			if st.thread then
				task.cancel(st.thread)
				st.thread = nil
			end
			Mock.ActiveTweens[self] = nil
			fireEvent(st, "Completed", enumItem("PlaybackState", "Cancelled"))
		end,
	},
})
local TWEENABLE = { number = true, Vector3 = true, Vector2 = true, CFrame = true, Color3 = true, UDim2 = true, UDim = true, Rect = true, boolean = true }
service("TweenService", {
	methods = {
		Create = function(self, instance, info, goals)
			if not isInstance(instance) then
				error("invalid argument #1 to 'Create' (Instance expected, got " .. typeof(instance) .. ")", 2)
			end
			if typeof(info) ~= "TweenInfo" then
				error("invalid argument #2 to 'Create' (TweenInfo expected, got " .. typeof(info) .. ")", 2)
			end
			if rawtype(goals) ~= "table" or isInstance(goals) then
				error("invalid argument #3 to 'Create' (table expected, got " .. typeof(goals) .. ")", 2)
			end
			local ist = instance[STATE]
			for prop, goal in pairs(goals) do
				local spec = ist.class.propspec[prop]
				local current
				local ok = pcall(function()
					current = instance[prop]
				end)
				if not (spec or ist.class.getters[prop]) and not ist.class.generic then
					error("TweenService:Create: " .. tostring(prop) .. " is not a valid property of " .. ist.class.name, 2)
				end
				if not TWEENABLE[typeof(goal)] then
					error("TweenService:Create: property " .. tostring(prop) .. " cannot be tweened to a " .. typeof(goal), 2)
				end
				if ok and current ~= nil and typeof(current) ~= typeof(goal) then
					error("TweenService:Create: property " .. tostring(prop) .. " expects " .. typeof(current) .. " but the goal is " .. typeof(goal), 2)
				end
			end
			local tw = makeInstance("Tween")
			local tst = tw[STATE]
			tst.target = instance
			tst.info = info
			tst.goals = goals
			tst.props.Instance = instance
			tst.props.TweenInfo = info
			return tw
		end,
		GetValue = function(self, alpha)
			return alpha
		end,
	},
})

-- DataStores -------------------------------------------------------------------------------------------
Mock.DataStore = { Data = {}, Fail = false, Unavailable = false, Latency = 0, Calls = 0, Writes = 0 }
local function storableCopy(v, depth)
	local t = rawtype(v)
	if t == "number" or t == "string" or t == "boolean" or v == nil then
		return v
	elseif t == "table" then
		if getmetatable(v) ~= nil and UD[getmetatable(v)] then
			error("104: Cannot store " .. typeof(v) .. " in data store. Data stores can only accept valid UTF-8 characters.", 0)
		end
		if (depth or 0) > 20 then
			error("105: Serialized value too deep", 0)
		end
		local out = {}
		for k, x in pairs(v) do
			local kt = rawtype(k)
			if kt ~= "string" and kt ~= "number" then
				error("104: Cannot store key of type " .. kt .. " in data store", 0)
			end
			out[k] = storableCopy(x, (depth or 0) + 1)
		end
		return out
	end
	error("104: Cannot store " .. t .. " in data store", 0)
end
local function dsGate(name)
	local cfg = Mock.DataStore
	cfg.Calls = cfg.Calls + 1
	if cfg.Latency > 0 and not isMainThread() then
		task.wait(cfg.Latency)
	end
	if cfg.Unavailable or cfg.Fail then
		if cfg.FailCount and cfg.FailCount > 0 then
			cfg.FailCount = cfg.FailCount - 1
			if cfg.FailCount == 0 then
				cfg.Fail = false
			end
		end
		error("502: API Services rejected request with error. (" .. name .. " failed: mock DataStore unavailable)", 0)
	end
end
local DSmt, DSm = {}, {}
regType(DSmt, "DataStore")
DSmt.__index = function(_, k)
	if DSm[k] then
		return DSm[k]
	end
	error(tostring(k) .. " is not a valid member of DataStore", 2)
end
function DSm.GetAsync(self, key)
	dsGate("GetAsync")
	return storableCopy(Mock.DataStore.Data[self._name .. "/" .. tostring(key)])
end
function DSm.SetAsync(self, key, value)
	dsGate("SetAsync")
	Mock.DataStore.Writes = Mock.DataStore.Writes + 1
	Mock.DataStore.Data[self._name .. "/" .. tostring(key)] = storableCopy(value)
	return "version"
end
function DSm.UpdateAsync(self, key, fn)
	dsGate("UpdateAsync")
	local full = self._name .. "/" .. tostring(key)
	local new = fn(storableCopy(Mock.DataStore.Data[full]))
	if new == nil then
		return nil
	end
	Mock.DataStore.Writes = Mock.DataStore.Writes + 1
	Mock.DataStore.Data[full] = storableCopy(new)
	return storableCopy(new)
end
function DSm.IncrementAsync(self, key, delta)
	dsGate("IncrementAsync")
	local full = self._name .. "/" .. tostring(key)
	local v = (Mock.DataStore.Data[full] or 0) + (delta or 1)
	Mock.DataStore.Data[full] = v
	return v
end
function DSm.RemoveAsync(self, key)
	dsGate("RemoveAsync")
	local full = self._name .. "/" .. tostring(key)
	local old = Mock.DataStore.Data[full]
	Mock.DataStore.Data[full] = nil
	return old
end
service("DataStoreService", {
	methods = {
		GetDataStore = function(self, name, scope)
			if rawtype(name) ~= "string" or name == "" then
				error("invalid argument #1 to 'GetDataStore' (non-empty string expected)", 2)
			end
			if Mock.DataStore.Unavailable then
				error("502: API Services rejected request with error. Studio access to APIs is not allowed (mock)", 0)
			end
			return setmetatable({ _name = name }, DSmt)
		end,
	},
})

-- Input ------------------------------------------------------------------------------------------------
local Inputmt = {}
regType(Inputmt, "InputObject")
Inputmt.__index = function(_, k)
	error(tostring(k) .. " is not a valid member of InputObject", 2)
end
function Mock.NewInput(keyCode, inputType, state, extra)
	local o = {
		KeyCode = keyCode and coerceEnum(keyCode, "KeyCode") or enumItem("KeyCode", "Unknown"),
		UserInputType = coerceEnum(inputType or "Keyboard", "UserInputType"),
		UserInputState = coerceEnum(state or "Begin", "UserInputState"),
		Position = v3(0, 0, 0),
		Delta = v3(0, 0, 0),
	}
	for k, v in pairs(extra or {}) do
		o[k] = v
	end
	return setmetatable(o, Inputmt)
end
Mock.KeysDown = {}
service("UserInputService", {
	props = {
		TouchEnabled = T.bool(false), KeyboardEnabled = T.bool(true), MouseEnabled = T.bool(true), GamepadEnabled = T.bool(false),
		AccelerometerEnabled = T.bool(false), GyroscopeEnabled = T.bool(false), VREnabled = T.bool(false), MouseBehavior = T.enum("MouseBehavior", "Default"),
		MouseIconEnabled = T.bool(true), ModalEnabled = T.bool(false), MouseDeltaSensitivity = T.num(1),
	},
	events = { "InputBegan", "InputEnded", "InputChanged", "TouchStarted", "TouchEnded", "TouchMoved", "TouchTap", "JumpRequest", "LastInputTypeChanged", "WindowFocused", "WindowFocusReleased", "GamepadConnected", "GamepadDisconnected", "TextBoxFocused", "TextBoxFocusReleased", "DeviceAccelerationChanged" },
	methods = {
		IsKeyDown = function(self, key)
			return Mock.KeysDown[typeof(key) == "EnumItem" and key.Name or key] == true
		end,
		IsMouseButtonPressed = function()
			return false
		end,
		GetFocusedTextBox = function()
			return nil
		end,
		GetMouseLocation = function()
			return v2(Mock.Viewport.X / 2, Mock.Viewport.Y / 2)
		end,
		GetLastInputType = function()
			return enumItem("UserInputType", "Keyboard")
		end,
		GetGamepadConnected = function()
			return false
		end,
		GetConnectedGamepads = function()
			return {}
		end,
		GetNavigationGamepads = function()
			return {}
		end,
		GetMouseDelta = function()
			return v2(0, 0)
		end,
		GetKeysPressed = function()
			return {}
		end,
		GetPlatform = function()
			return enumItem("Platform", "Windows")
		end,
		GetStringForKeyCode = function(self, kc)
			return kc.Name
		end,
	},
})
service("ContextActionService", {
	events = { "LocalToolEquipped", "LocalToolUnequipped" },
	methods = {
		BindAction = function(self, name, fn, createButton, ...)
			if rawtype(name) ~= "string" or rawtype(fn) ~= "function" then
				error("invalid arguments to BindAction (string, function, boolean, ...)", 2)
			end
			Mock.BoundActions[name] = { fn = fn, priority = 2000, inputs = pack(...), createButton = createButton }
		end,
		BindActionAtPriority = function(self, name, fn, createButton, priority, ...)
			if rawtype(name) ~= "string" or rawtype(fn) ~= "function" or rawtype(priority) ~= "number" then
				error("invalid arguments to BindActionAtPriority (string, function, boolean, number, ...)", 2)
			end
			Mock.BoundActions[name] = { fn = fn, priority = priority, inputs = pack(...), createButton = createButton }
		end,
		UnbindAction = function(self, name)
			Mock.BoundActions[name] = nil
		end,
		UnbindAllActions = function()
			Mock.BoundActions = {}
		end,
		GetBoundActionInfo = function(self, name)
			local a = Mock.BoundActions[name]
			return a and { priority = a.priority, stackOrder = 0 } or {}
		end,
		GetAllBoundActionInfo = function()
			return {}
		end,
		SetTitle = function() end,
		SetImage = function() end,
		SetDescription = function() end,
		SetPosition = function() end,
		GetButton = function()
			return nil
		end,
	},
})
Mock.BoundActions = {}
function Mock.TriggerAction(name, state, input)
	local a = Mock.BoundActions[name]
	if not a then
		return nil
	end
	return a.fn(name, coerceEnum(state, "UserInputState"), input or Mock.NewInput())
end

service("GuiService", {
	props = { MenuIsOpen = T.bool(false), SelectedObject = T.inst(), AutoSelectGuiEnabled = T.bool(true), TouchControlsEnabled = T.bool(true) },
	methods = {
		GetGuiInset = function()
			return v2(0, Mock.TopInset or 36), v2(0, 0)
		end,
		IsTenFootInterface = function()
			return false
		end,
	},
})
service("HttpService", {
	props = { HttpEnabled = T.bool(false) },
	methods = {
		GenerateGUID = function(self, wrap)
			local t = {}
			for i = 1, 32 do
				t[i] = sformat("%x", floor(math.random() * 16))
			end
			local s = tconcat(t)
			s = s:sub(1, 8) .. "-" .. s:sub(9, 12) .. "-" .. s:sub(13, 16) .. "-" .. s:sub(17, 20) .. "-" .. s:sub(21, 32)
			if wrap == false then
				return s
			end
			return "{" .. s .. "}"
		end,
		JSONEncode = function(self, value)
			local function enc(v)
				local t = rawtype(v)
				if t == "string" then
					return '"' .. v:gsub('[%c"\\]', function(c)
						return sformat("\\u%04x", c:byte())
					end) .. '"'
				elseif t == "number" or t == "boolean" then
					return tostring(v)
				elseif t == "nil" then
					return "null"
				elseif t == "table" then
					if #v > 0 or next(v) == nil then
						local parts = {}
						for i = 1, #v do
							parts[i] = enc(v[i])
						end
						return "[" .. tconcat(parts, ",") .. "]"
					end
					local parts = {}
					for k, x in pairs(v) do
						parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(x)
					end
					tsort(parts)
					return "{" .. tconcat(parts, ",") .. "}"
				end
				error("Can't convert " .. t .. " to JSON", 3)
			end
			return enc(value)
		end,
	},
})
service("TextService", {
	methods = {
		GetTextSize = function(self, text, size)
			return v2(#tostring(text) * (size or 14) * 0.5, size or 14)
		end,
	},
})
for _, n in ipairs({ "MarketplaceService", "TeleportService", "PhysicsService", "PathfindingService", "ProximityPromptService", "ContentProvider", "Stats", "SocialService", "BadgeService", "MessagingService", "MemoryStoreService", "GroupService", "AssetService", "InsertService", "LocalizationService", "VRService", "HapticService", "TestService", "VoiceChatService", "AvatarEditorService", "UserService", "PolicyService", "NotificationService", "AnalyticsService", "GamepadService", "MaterialService", "LogService", "CoreGui", "Selection", "StudioService", "ScriptContext", "NetworkClient", "UGCValidationService", "RbxAnalyticsService", "ChangeHistoryService", "CaptureService", "DraggerService", "AvatarChatService", "AdService" }) do
	if not Classes[n] then
		service(n, { generic = true })
	end
end
Classes.ContentProvider.own.methods = { PreloadAsync = function() end }
Classes.PhysicsService.own.methods = {
	RegisterCollisionGroup = function() end,
	CollisionGroupSetCollidable = function() end,
	CollisionGroupContainsPart = function() return false end,
	SetPartCollisionGroup = function() end,
}

end
----------------------------------------------------------------------------------------------------
-- World boot, mounting, require, players
----------------------------------------------------------------------------------------------------
local moduleCache = setmetatable({}, { __mode = "k" })
Mock.ModuleErrors = {}

local function makeEnv(scriptInst)
	return setmetatable({ script = scriptInst }, { __index = _G })
end

local function chunkNameOf(inst)
	local st = inst[STATE]
	return "=" .. (st.sourcePath or fullName(inst))
end

function require(target)
	if not isInstance(target) or not target[STATE].class.isA.ModuleScript then
		if rawtype(target) == "number" then
			error("Requiring assets by id is not allowed in this mock", 2)
		end
		error("Attempted to call require with invalid argument(s).", 2)
	end
	local entry = moduleCache[target]
	if entry then
		if entry.state == "loading" then
			error("Requested module was required recursively", 2)
		elseif entry.state == "error" then
			error("Requested module experienced an error while loading", 2)
		end
		return entry.value
	end
	entry = { state = "loading" }
	moduleCache[target] = entry
	local st = target[STATE]
	local fn, err = compile(st.props.Source or "", chunkNameOf(target), makeEnv(target))
	if not fn then
		entry.state = "error"
		Mock.ModuleErrors[#Mock.ModuleErrors + 1] = { module = fullName(target), message = tostring(err) }
		error(err, 0)
	end
	local results = pack(pcall(fn))
	if not results[1] then
		entry.state = "error"
		local e = results[2]
		Mock.ModuleErrors[#Mock.ModuleErrors + 1] = { module = fullName(target), message = rawtype(e) == "table" and tostring(e.msg or e) or tostring(e) }
		error(e, 0)
	end
	if results.n ~= 2 then
		entry.state = "error"
		Mock.ModuleErrors[#Mock.ModuleErrors + 1] = { module = fullName(target), message = "Module code did not return exactly one value" }
		error("Module code did not return exactly one value", 2)
	end
	entry.state = "done"
	entry.value = results[2]
	return entry.value
end

-- Runs a Script / LocalScript in its own thread (so it may task.wait); returns the thread.
function Mock.RunScript(scriptInst)
	local st = scriptInst[STATE]
	local fn, err = compile(st.props.Source or "", chunkNameOf(scriptInst), makeEnv(scriptInst))
	if not fn then
		reportError({ msg = tostring(err), trace = "" }, "compile")
		return nil
	end
	return task.spawn(fn)
end

-- spec = { name=, class=, source=, path=, children = { spec... } }
function Mock.Mount(parent, spec)
	local inst = makeInstance(spec.class or "Folder")
	local st = inst[STATE]
	st.name = spec.name
	if spec.source then
		st.props.Source = spec.source
		st.sourcePath = spec.path
	end
	for k, v in pairs(spec.props or {}) do
		st.props[k] = v
	end
	if parent then
		setParentRaw(inst, st, parent)
	end
	for _, child in ipairs(spec.children or {}) do
		Mock.Mount(inst, child)
	end
	return inst
end

-- Finds (or creates) a child path like "StarterPlayer/StarterPlayerScripts" below the DataModel.
function Mock.GetPath(path, createClass)
	local cur = Mock.game
	for part in tostring(path):gmatch("[^/%.]+") do
		local nxt = findChildByName(cur[STATE], part)
		if not nxt then
			local svc = nil
			if cur == Mock.game then
				local ok, s = pcall(function()
					return Mock.game:GetService(part)
				end)
				svc = ok and s or nil
			end
			if svc then
				nxt = svc
			else
				nxt = makeInstance(createClass or "Folder")
				nxt[STATE].name = part
				setParentRaw(nxt, nxt[STATE], cur)
			end
		end
		cur = nxt
	end
	return cur
end

local PRELOAD_SERVICES = { "Workspace", "Players", "Lighting", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "SoundService", "Teams", "Chat", "RunService", "TweenService", "CollectionService", "Debris", "DataStoreService", "UserInputService", "ContextActionService", "GuiService", "HttpService", "TextService" }
local nextUserId = 1000

function Mock.Boot(ctx, opts)
	opts = opts or {}
	Mock.Context = ctx
	local game_ = makeInstance("DataModel")
	game_[STATE].name = "Game"
	Mock.game = game_
	for _, n in ipairs(PRELOAD_SERVICES) do
		local svc = makeInstance(n)
		setParentRaw(svc, svc[STATE], game_)
	end
	local ws = game_:GetService("Workspace")
	Mock.workspace = ws
	Mock.StarterGui = game_:GetService("StarterGui")
	local sp = game_:GetService("StarterPlayer")
	for _, n in ipairs({ "StarterPlayerScripts", "StarterCharacterScripts" }) do
		local c = makeInstance(n)
		setParentRaw(c, c[STATE], sp)
	end
	local cam = makeInstance("Camera")
	cam[STATE].name = "Camera"
	setParentRaw(cam, cam[STATE], ws)
	ws[STATE].props.CurrentCamera = cam
	local terrain = makeInstance("Terrain")
	terrain[STATE].name = "Terrain"
	setParentRaw(terrain, terrain[STATE], ws)
	_G.game = game_
	_G.workspace = ws
	Mock.Lighting = game_:GetService("Lighting")
	Mock.RunService = game_:GetService("RunService")
	Mock.UserInputService = game_:GetService("UserInputService")

	-- per-frame signals
	local rs = Mock.RunService
	local rst = rs[STATE]
	Mock._frameHooks[#Mock._frameHooks + 1] = function(dt)
		local now = Clock.now
		if ctx == "client" then
			local steps = {}
			for name, entry in pairs(Mock.RenderSteps) do
				steps[#steps + 1] = { name = name, priority = entry.priority or 0, fn = entry.fn }
			end
			tsort(steps, function(a, b)
				if a.priority ~= b.priority then
					return a.priority < b.priority
				end
				return a.name < b.name
			end)
			for _, s in ipairs(steps) do
				task.spawn(s.fn, dt)
			end
			fireEvent(rst, "PreRender", dt)
			fireEvent(rst, "RenderStepped", dt)
		end
		fireEvent(rst, "Stepped", now, dt)
		fireEvent(rst, "PreSimulation", dt)
		fireEvent(rst, "Heartbeat", dt)
		fireEvent(rst, "PostSimulation", dt)
	end

	if opts.touch then
		local uis = game_:GetService("UserInputService")
		uis.TouchEnabled = true
		uis.KeyboardEnabled = false
		uis.MouseEnabled = false
	end
	if ctx == "client" then
		local lp = Mock.AddPlayer(opts.localName or "Tester", opts.localUserId or 1, { local_ = true })
		Mock.LocalPlayer = lp
	end
	return game_
end

function Mock.AddPlayer(name, userId, opts)
	opts = opts or {}
	nextUserId = nextUserId + 1
	local p = makeInstance("Player")
	local st = p[STATE]
	st.name = name
	st.props.UserId = userId or nextUserId
	st.props.DisplayName = name
	if opts.spawn then
		st.spawnOverride = opts.spawn
	end
	setParent(p, st, Players_)
	if Mock._onJoin then
		Mock._onJoin(p)
	end
	fireEvent(Players_[STATE], "PlayerAdded", p)
	if opts.character ~= false and not st.destroyed and Players_[STATE].props.CharacterAutoLoads ~= false then
		loadCharacter(p)
	end
	return p
end

function Mock.RemovePlayer(player)
	local st = player[STATE]
	if st.destroyed then
		return
	end
	fireEvent(Players_[STATE], "PlayerRemoving", player)
	local char = st.props.Character
	if char then
		fireEvent(st, "CharacterRemoving", char)
		destroy(char)
		st.props.Character = nil
	end
	if Mock._onLeave then
		Mock._onLeave(player)
	end
	destroy(player)
end

function Mock.Respawn(player)
	return loadCharacter(player)
end

function Mock.GetRoot(player)
	local char = player[STATE].props.Character
	return char and IM.FindFirstChild(char, "HumanoidRootPart") or nil
end
function Mock.GetHumanoid(player)
	local char = player[STATE].props.Character
	return char and IM.FindFirstChildOfClass(char, "Humanoid") or nil
end
-- Moves a player's character (pos is a Vector3 or CFrame).
function Mock.Teleport(player, target)
	local char = player[STATE].props.Character
	if not char then
		return false
	end
	if typeof(target) == "Vector3" then
		target = CFrame.new(target)
	end
	pivotTo(char, target)
	return true
end
-- Debug helper: kill the character (Humanoid.Health = 0).
function Mock.Kill(player)
	local hum = Mock.GetHumanoid(player)
	if hum then
		hum.Health = 0
	end
end

-- A mouse / touch click on a GuiButton: fires every click-ish event the way Roblox does.
function Mock.Click(button)
	local st = button[STATE]
	local fired = false
	if st.class.events.InputBegan then
		fireEvent(st, "InputBegan", Mock.NewInput("Unknown", "MouseButton1", "Begin"), false)
		fired = true
	end
	for _, name in ipairs({ "MouseButton1Down", "MouseButton1Up", "MouseButton1Click", "Activated", "TouchTap" }) do
		if st.class.events[name] then
			if name == "Activated" then
				fireEvent(st, name, Mock.NewInput("Unknown", "MouseButton1", "End"), 1)
			else
				fireEvent(st, name)
			end
			fired = true
		end
	end
	if st.class.events.InputEnded then
		fireEvent(st, "InputEnded", Mock.NewInput("Unknown", "MouseButton1", "End"), false)
	end
	return fired
end

-- Fires any event signal of an instance (e.g. a ProximityPrompt's Triggered, a Humanoid's Died ...).
function Mock.FireSignal(inst, name, ...)
	getSignal(inst, inst[STATE], name):Fire(...)
end
-- A player uses a ProximityPrompt (what the engine does when the key is pressed in range).
function Mock.Trigger(prompt, player)
	getSignal(prompt, prompt[STATE], "Triggered"):Fire(player)
end

-- Simulates a remote arriving at the other side
function Mock.FromClient(remote, player, ...)
	getSignal(remote, remote[STATE], "OnServerEvent"):Fire(player, ...)
end
function Mock.ToClient(remote, ...)
	getSignal(remote, remote[STATE], "OnClientEvent"):Fire(...)
end

----------------------------------------------------------------------------------------------------
-- Diagnostics helpers for the smoke test
----------------------------------------------------------------------------------------------------
function Mock.CountDescendants(root, className)
	local n = 0
	eachDescendant(root, function(d)
		if not className or d[STATE].class.isA[className] then
			n = n + 1
		end
	end)
	return n
end

function Mock.Stats()
	local live, ws = 0, 0
	for inst in pairs(AllInstances) do
		if not inst[STATE].destroyed then
			live = live + 1
		end
	end
	if Mock.workspace then
		ws = Mock.CountDescendants(Mock.workspace)
	end
	local tw = 0
	for t in pairs(Mock.ActiveTweens) do
		if not t[STATE].destroyed and not t[STATE].target[STATE].destroyed then
			tw = tw + 1
		end
	end
	local touch = 0
	for part in pairs(touchRegistry) do
		if not part[STATE].destroyed then
			touch = touch + 1
		end
	end
	local waits = 0
	for _ in pairs(PendingWaits) do
		waits = waits + 1
	end
	return {
		liveInstances = live,
		workspaceDescendants = ws,
		liveConnections = Live.connections,
		connections = Mock.ConnectionReport(),
		pendingTasks = Sched.live,
		playingTweens = tw,
		touchRegistry = touch,
		pendingWaits = waits,
		time = Clock.now,
		errors = #Mock.Errors,
	}
end

-- WaitForChild calls that never resolved (> `olderThan` seconds old)
function Mock.PendingWaitList(olderThan)
	local out = {}
	for e in pairs(PendingWaits) do
		if Clock.now - e.since >= (olderThan or 5) and not e.timeout then
			out[#out + 1] = fullName(e.inst) .. ':WaitForChild("' .. e.name .. '") pending for ' .. sformat("%.1fs", Clock.now - e.since)
		end
	end
	tsort(out)
	return out
end

-- Changes the screen size (rotation / resize / foldable) and fires Camera.ViewportSize changes like Roblox does.
function Mock.SetViewport(width, height)
	local old = Mock.Viewport
	Mock.Viewport = v2(width, height)
	Mock.GuiEpoch = Mock.GuiEpoch + 1
	local cam = Mock.workspace and Mock.workspace[STATE].props.CurrentCamera
	if cam then
		firePropChanged(cam, cam[STATE], "ViewportSize")
	end
	-- Every ScreenGui resizes with the viewport, so scripts that relayout on
	-- gui:GetPropertyChangedSignal("AbsoluteSize") (menu, hotbar) run exactly like in Roblox.
	if old == nil or old.X ~= width or old.Y ~= height then
		local lp = Mock.LocalPlayer
		local pg = lp and IM.FindFirstChild(lp, "PlayerGui")
		if pg then
			for _, g in ipairs({ unpack(pg[STATE].children) }) do
				if not g[STATE].destroyed and g[STATE].class.isA.ScreenGui then
					firePropChanged(g, g[STATE], "AbsoluteSize")
				end
			end
		end
	end
end

function Mock.FindDescendants(root, pred)
	local out = {}
	eachDescendant(root, function(d)
		if pred(d) then
			out[#out + 1] = d
		end
	end)
	return out
end

function Mock.IsDestroyed(inst)
	return inst[STATE].destroyed
end

-- All live text objects: returns list of { path, text, role } problems.
-- allowed: set (table keyed by EnumItem) of fonts that are acceptable (i.e. Theme.Fonts values).
function Mock.FontAudit(allowed)
	local problems, total = {}, 0
	for inst in pairs(AllInstances) do
		local st = inst[STATE]
		if st.isText and not st.destroyed and (isInGame(inst) or (st.parent ~= nil)) then
			-- ignore trees that were detached and abandoned (parent chain never reaches the DataModel)
			if isInGame(inst) then
				total = total + 1
				local text = st.props.Text or ""
				if text == "" and not st.fontAssigned then
					-- an empty label (e.g. a button whose caption is a child label) draws no glyphs
					text = nil
				end
				if text == nil then
					-- skip
				elseif not st.fontAssigned then
					problems[#problems + 1] = { path = fullName(inst), text = text, reason = "Font never set (default SourceSans); style it with Theme.Style/Theme.Label" }
				elseif allowed then
					local fv = st.fontValue
					local ok = allowed[fv]
					if not ok and typeof(fv) == "Font" and fv._enum then
						ok = allowed[fv._enum]
					end
					if not ok then
						problems[#problems + 1] = { path = fullName(inst), text = text, reason = "Font " .. tostring(fv) .. " is not a Theme font" }
					end
				end
			end
		end
	end
	tsort(problems, function(a, b)
		return a.path < b.path
	end)
	return problems, total
end

----------------------------------------------------------------------------------------------------
-- Serialisation (server -> client replay)
----------------------------------------------------------------------------------------------------
local function serialize(v, depth)
	depth = depth or 0
	local t = typeof(v)
	if t == "nil" then
		return "nil"
	elseif t == "number" then
		if v ~= v then
			return "(0/0)"
		elseif v == huge then
			return "math.huge"
		elseif v == -huge then
			return "(-math.huge)"
		end
		return sformat("%.17g", v)
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "string" then
		return sformat("%q", v)
	elseif t == "Vector3" then
		return sformat("Vector3.new(%.17g,%.17g,%.17g)", v.X, v.Y, v.Z)
	elseif t == "Vector2" then
		return sformat("Vector2.new(%.17g,%.17g)", v.X, v.Y)
	elseif t == "Color3" then
		return sformat("Color3.new(%.17g,%.17g,%.17g)", v.R, v.G, v.B)
	elseif t == "CFrame" then
		return "CFrame.new(" .. tconcat({ v:GetComponents() }, ",") .. ")"
	elseif t == "UDim2" then
		return sformat("UDim2.new(%.17g,%.17g,%.17g,%.17g)", v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset)
	elseif t == "EnumItem" then
		return "Enum." .. v.EnumType.Name .. "." .. v.Name
	elseif t == "Instance" then
		return sformat("%q", "<Instance " .. v[STATE].name .. ">")
	elseif t == "table" then
		if depth > 12 then
			return "nil"
		end
		local parts = {}
		local n = #v
		for i = 1, n do
			parts[#parts + 1] = serialize(v[i], depth + 1)
		end
		for k, x in pairs(v) do
			if not (rawtype(k) == "number" and k >= 1 and k <= n and k == floor(k)) then
				if rawtype(k) == "string" then
					parts[#parts + 1] = "[" .. sformat("%q", k) .. "]=" .. serialize(x, depth + 1)
				elseif rawtype(k) == "number" then
					parts[#parts + 1] = "[" .. sformat("%.17g", k) .. "]=" .. serialize(x, depth + 1)
				end
			end
		end
		return "{" .. tconcat(parts, ",") .. "}"
	end
	return "nil"
end
Mock.Serialize = serialize

function Mock.Deserialize(src)
	local fn, err = compile("return " .. src, "=deserialize", _G)
	if not fn then
		error(err)
	end
	return fn()
end

-- Server-side recording of everything a client would observe.
Mock.Replication = {}
function Mock.RecordReplication()
	local log = Mock.Replication
	Mock._onRemote = function(entry)
		if entry.kind == "client" or entry.kind == "all" then
			local args = {}
			for i = 1, entry.args.n do
				args[i] = serialize(entry.args[i])
			end
			log[#log + 1] = { time = Clock.now, kind = "remote", remote = entry.remote, target = entry.kind, userId = entry.userId, args = "{n=" .. entry.args.n .. "," .. tconcat((function()
				local parts = {}
				for i = 1, entry.args.n do
					parts[i] = "[" .. i .. "]=" .. args[i]
				end
				return parts
			end)(), ",") .. "}" }
		end
	end
	Mock._onAttribute = function(inst, st, name, value)
		if st.class.isA.Player then
			log[#log + 1] = { time = Clock.now, kind = "attr", userId = st.props.UserId, name = name, value = serialize(value) }
		end
	end
	Mock._onHealth = function(humanoid, st, health)
		local char = st.parent
		local player = char and Mock.GetPlayerFromCharacter(char)
		if player then
			log[#log + 1] = { time = Clock.now, kind = "health", userId = player[STATE].props.UserId, health = health, max = humanoid.MaxHealth }
		end
	end
	Mock._onJoin = function(p)
		log[#log + 1] = { time = Clock.now, kind = "join", userId = p[STATE].props.UserId, name = p[STATE].name }
	end
	Mock._onLeave = function(p)
		log[#log + 1] = { time = Clock.now, kind = "leave", userId = p[STATE].props.UserId }
	end
end

-- Client side: apply recorded entries at their original (fake) times.
function Mock.RunReplay(entries, endTime, onEntry, maxGap)
	local lastTime = entries[1] and entries[1].time or Clock.now
	for _, e in ipairs(entries) do
		-- long idle stretches are shortened to maxGap seconds (the client only needs the sequence of events)
		local gap = e.time - lastTime
		lastTime = e.time
		if gap > 0 then
			Mock.Advance(maxGap and mmin(gap, maxGap) or gap)
		end
		local lp = Mock.LocalPlayer
		local myId = lp and lp[STATE].props.UserId
		if e.kind == "remote" then
			if e.target == "all" or e.userId == myId then
				local remote = Mock.game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
				remote = remote and remote:FindFirstChild(e.remote)
				if remote then
					local args = Mock.Deserialize(e.args)
					getSignal(remote, remote[STATE], "OnClientEvent"):Fire(unpack(args, 1, args.n))
				end
			end
		elseif e.kind == "attr" then
			local target = Players_:GetPlayerByUserId(e.userId)
			if target then
				target:SetAttribute(e.name, Mock.Deserialize(e.value))
			end
		elseif e.kind == "health" then
			if e.userId == myId then
				local hum = Mock.GetHumanoid(lp)
				if hum then
					hum[STATE].props.MaxHealth = e.max
					hum.Health = e.health
				end
			end
		elseif e.kind == "join" then
			if e.userId ~= myId and not Players_:GetPlayerByUserId(e.userId) then
				Mock.AddPlayer(e.name, e.userId)
			end
		elseif e.kind == "leave" then
			local target = Players_:GetPlayerByUserId(e.userId)
			if target and e.userId ~= myId then
				Mock.RemovePlayer(target)
			end
		end
		if onEntry then
			onEntry(e)
		end
	end
	if endTime and not maxGap and endTime > Clock.now then
		Mock.Advance(endTime - Clock.now)
	end
end

----------------------------------------------------------------------------------------------------
-- Install the Roblox globals
----------------------------------------------------------------------------------------------------
local installed = {
	Vector3 = Vector3, Vector2 = Vector2, Vector3int16 = Vector3int16, Vector2int16 = Vector2int16, CFrame = CFrame, Color3 = Color3,
	UDim = UDim, UDim2 = UDim2, Rect = Rect, NumberRange = NumberRange, NumberSequence = NumberSequence,
	NumberSequenceKeypoint = NumberSequenceKeypoint, ColorSequence = ColorSequence, ColorSequenceKeypoint = ColorSequenceKeypoint,
	TweenInfo = TweenInfo, Ray = Ray, RaycastParams = RaycastParams, OverlapParams = OverlapParams, PhysicalProperties = PhysicalProperties,
	Random = Random, BrickColor = BrickColor, Font = Font, DateTime = DateTime, Region3 = Region3, Axes = Axes, Faces = Faces,
	Enum = Enum, Instance = Instance, task = task,
}
for k, v in pairs(installed) do
	_G[k] = v
end
_G.shared = _G.shared or {}
_G.settings = function()
	return proxyAny("settings")
end
_G.UserSettings = function()
	return proxyAny("UserSettings")
end
_G.version = function()
	return "0.0.0.mock"
end
_G.gcinfo = function()
	return collectgarbage("count")
end
_G.newproxy = function(addMeta)
	local p = {}
	if addMeta then
		return setmetatable(p, {})
	end
	return p
end
Mock.Globals = installed
Mock.Version = "1.0"
Mock.Internals = Mock._internals
Mock.Enum = Enum
Mock.Classes = Classes

return Mock
