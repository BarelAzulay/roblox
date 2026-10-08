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
