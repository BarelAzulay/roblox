-- smoke_common.lua: result reporting shared by smoke_server.lua and smoke_client.lua.
-- Loaded by smoke.py before the scenario files; exposes the global SmokeCommon = { T = reporter, guarded = fn }.
-- Plain Lua 5.1 syntax only.

local T = { results = {}, section = "" }
_G.T = T

local function add(status, name, detail)
	T.results[#T.results + 1] = { status = status, section = T.section, name = tostring(name), detail = detail == nil and "" or tostring(detail) }
end
function T.ok(name, detail)
	add("ok", name, detail)
end
function T.fail(name, detail)
	add("fail", name, detail)
end
function T.warn(name, detail)
	add("warn", name, detail)
end
function T.info(name, detail)
	add("info", name, detail)
end
function T.check(cond, name, detail)
	if cond then
		add("ok", name)
	else
		add("fail", name, detail)
	end
	return cond and true or false
end
function T.near(actual, expected, tolerance, name)
	local ok = type(actual) == "number" and math.abs(actual - expected) <= tolerance
	if ok then
		add("ok", name)
	else
		add("fail", name, "expected " .. tostring(expected) .. " +- " .. tostring(tolerance) .. ", got " .. tostring(actual))
	end
	return ok
end
function T.eq(actual, expected, name)
	if actual == expected then
		add("ok", name)
		return true
	end
	add("fail", name, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
	return false
end
function T.section_(name)
	T.section = name
end

-- Counts many small cases and reports ONE result line (so 300 seeds do not produce 300 lines):
--   local t = T.tally("Easy: layouts are valid"); t:case(ok, "seed 5: reason"); ...; t:report()
-- A failure line shows "bad/total" and the first few examples.
function T.tally(name, maxExamples)
	local tally = { name = name, n = 0, bad = 0, examples = {}, max = maxExamples or 3 }
	function tally:case(ok, example)
		self.n = self.n + 1
		if not ok then
			self.bad = self.bad + 1
			if #self.examples < self.max then
				self.examples[#self.examples + 1] = tostring(example)
			end
		end
		return ok
	end
	function tally:report(extra)
		if self.bad == 0 then
			add("ok", self.name, extra)
		else
			add("fail", self.name, self.bad .. " of " .. self.n .. " failed" .. (extra and (" (" .. extra .. ")") or "") .. ": " .. table.concat(self.examples, " | "))
		end
		return self.bad == 0
	end
	return tally
end

-- true when `list` (array) contains `value`
function T.contains(list, value)
	for _, v in ipairs(list) do
		if v == value then
			return true
		end
	end
	return false
end

-- Numbers that are not NaN / inf.
function T.finite(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Runs fn() under xpcall; a Lua error becomes a failed check with a traceback.
local function guarded(name, fn)
	return function(...)
		T.section = name
		local args = { ... }
		local ok, err = xpcall(function()
			return fn(unpack(args))
		end, function(e)
			return debug.traceback(tostring(e), 2)
		end)
		if not ok then
			add("fail", name .. ": scenario aborted", err)
		end
		-- script errors raised in game threads
		return ok
	end
end


SmokeCommon = { T = T, guarded = guarded, add = add }
