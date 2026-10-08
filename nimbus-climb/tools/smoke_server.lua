-- smoke_server.lua: scenarios for the server world of tools/smoke.py.
--
-- Globals provided by smoke.py: Mock (tools/robloxmock.lua), CONTRACT (tools/contract.json), ROOTS
-- (src directory name -> instance path), ARGS ({ seeds, verbose, quick }).
-- Every scenario is a function in the returned table; checks are reported through T.
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded

----------------------------------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local huge = math.huge

local S = {} -- the scenarios
local M = {} -- loaded modules by contract key ("server/Services/MatchService")
local errorCursor = 0 -- how many Mock.Errors have been reported already
local outputCursor = 0 -- same for warn() lines

local function fmt(v, n)
	return string.format("%." .. (n or 1) .. "f", v)
end

local function moduleInstance(key)
	local top, rest = key:match("^(%w+)/(.+)$")
	local rootPath = ROOTS[top]
	if not rootPath then
		return nil
	end
	local inst = Mock.GetPath(rootPath)
	for part in rest:gmatch("[^/]+") do
		inst = inst and inst:FindFirstChild(part)
	end
	return inst
end

local function mod(name)
	return M["server/Services/" .. name] or M["shared/" .. name]
end

-- Reports script errors (uncaught errors in game threads) that appeared since the last call.
local function flushErrors(context)
	for i = errorCursor + 1, #Mock.Errors do
		local e = Mock.Errors[i]
		T.fail((context or "game thread") .. " raised an error", e.msg .. "\n" .. tostring(e.trace or ""))
	end
	errorCursor = #Mock.Errors
end

-- warn() lines that look like failures (services warn on pcall failures)
local function flushWarnings(context, allow)
	for i = outputCursor + 1, #Mock.Output do
		local o = Mock.Output[i]
		if o.kind == "warn" then
			local ignore = false
			if allow then
				for _, pat in ipairs(allow) do
					if o.text:find(pat, 1, true) then
						ignore = true
					end
				end
			end
			if not ignore then
				T.warn((context or "warn()") .. ": " .. o.text)
			end
		end
	end
	outputCursor = #Mock.Output
end

local function advance(seconds)
	Mock.Advance(seconds)
end

local function waitFor(pred, maxSeconds)
	return Mock.AdvanceUntil(pred, maxSeconds or 30)
end

local function lastRemote(name, userId, afterIndex)
	local log = Mock.RemoteLog
	for i = #log, (afterIndex or 0) + 1, -1 do
		local e = log[i]
		if e.remote == name and (e.kind == "all" or (userId == nil or e.userId == userId)) and e.kind ~= "server" then
			return e, i
		end
	end
	return nil
end

local function remotesFor(name, userId, fromIndex)
	local out = {}
	local log = Mock.RemoteLog
	for i = (fromIndex or 0) + 1, #log do
		local e = log[i]
		if e.remote == name and e.kind ~= "server" and (userId == nil or e.userId == userId or e.kind == "all") then
			out[#out + 1] = e
		end
	end
	return out
end

local function joinPlayer(name, userId)
	local p = Mock.AddPlayer(name, userId)
	advance(0.6)
	return p
end

local function hum(player)
	return Mock.GetHumanoid(player)
end
local function root(player)
	return Mock.GetRoot(player)
end

local function partsOfCharacter(player)
	local out = {}
	local char = player.Character
	if char then
		for _, d in ipairs(char:GetDescendants()) do
			if d:IsA("BasePart") then
				out[#out + 1] = d
			end
		end
	end
	return out
end

local function config()
	return M["shared/Config"]
end

----------------------------------------------------------------------------------------------------
-- scenario: the mock itself behaves like Roblox where the game code depends on it
----------------------------------------------------------------------------------------------------
S.mock_selftest = guarded("mock_selftest", function()
	local function raises(fn, pattern)
		local ok, err = pcall(fn)
		return not ok and (pattern == nil or tostring(err):find(pattern, 1, true) ~= nil), tostring(err)
	end
	-- datatypes
	local v = Vector3.new(3, 4, 0)
	T.eq(v.Magnitude, 5, "Vector3.Magnitude")
	T.check(v.Unit == Vector3.new(0.6, 0.8, 0), "Vector3.Unit and ==")
	T.check(v + Vector3.new(1, 1, 1) == Vector3.new(4, 5, 1) and v * 2 == Vector3.new(6, 8, 0) and 2 * v == v * 2 and v / 2 == Vector3.new(1.5, 2, 0), "Vector3 arithmetic")
	T.eq(Vector3.new(1, 0, 0):Dot(Vector3.new(0, 1, 0)), 0, "Vector3:Dot")
	T.check(Vector3.new(1, 0, 0):Cross(Vector3.new(0, 1, 0)) == Vector3.new(0, 0, 1), "Vector3:Cross")
	T.check(raises(function()
		return v + 1
	end, "arithmetic"), "Vector3 + number is an error")
	T.eq(typeof(v), "Vector3", "typeof(Vector3)")
	T.eq(type(v), "userdata", "type(Vector3) is userdata (like Roblox)")
	local cf = CFrame.new(10, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
	T.check((cf * Vector3.new(0, 0, 0) - Vector3.new(10, 0, 0)).Magnitude < 1e-9, "CFrame * Vector3 (translation)")
	T.check(((cf * Vector3.new(0, 0, -5)) - Vector3.new(5, 0, 0)).Magnitude < 1e-6, "CFrame rotation: yaw 90 degrees turns -Z into -X")
	T.check((cf:Inverse() * cf):FuzzyEq(CFrame.new()), "CFrame:Inverse")
	T.check((CFrame.lookAt(Vector3.new(0, 0, 0), Vector3.new(0, 0, -10)).LookVector - Vector3.new(0, 0, -1)).Magnitude < 1e-6, "CFrame.lookAt")
	T.check((cf:PointToObjectSpace(Vector3.new(10, 0, -3)) - Vector3.new(3, 0, 0)).Magnitude < 1e-6, "CFrame:PointToObjectSpace")
	T.check(Color3.fromRGB(255, 128, 0).G > 0.49 and Color3.fromRGB(255, 128, 0).G < 0.51, "Color3.fromRGB")
	T.check(UDim2.new(0.5, 10, 1, -4).X.Offset == 10 and UDim2.fromScale(1, 1).Y.Scale == 1, "UDim2")
	T.check(raises(function()
		return NumberSequence.new({ NumberSequenceKeypoint.new(0.2, 1), NumberSequenceKeypoint.new(1, 0) })
	end, "time 0"), "NumberSequence must start at time 0")
	T.check(raises(function()
		return TweenInfo.new(1, Enum.Material.Neon)
	end), "TweenInfo.new validates its EasingStyle argument")
	T.check(raises(function()
		return Enum.Material.Cloud
	end, "not a valid member"), "unknown Enum.Material member is an error")
	T.eq(Enum.Material.Neon, Enum.Material.Neon, "enum items are interned")
	-- Random is deterministic and well spread
	local a, b = Random.new(42), Random.new(42)
	local same = true
	for _ = 1, 50 do
		same = same and a:NextInteger(1, 1000) == b:NextInteger(1, 1000)
	end
	T.check(same, "Random.new(seed) is deterministic")
	local buckets = { 0, 0, 0, 0 }
	local r = Random.new(7)
	for _ = 1, 4000 do
		local k = 1 + math.floor(r:NextNumber() * 4)
		buckets[k] = buckets[k] + 1
	end
	T.check(buckets[1] > 850 and buckets[2] > 850 and buckets[3] > 850 and buckets[4] > 850, "Random is evenly distributed", table.concat(buckets, ","))
	local first = {}
	for seed = 1, 5 do
		first[#first + 1] = Random.new(seed):NextNumber()
	end
	T.check(first[1] ~= first[2] and first[2] ~= first[3] and math.abs(first[1] - first[2]) > 0.001, "consecutive seeds give unrelated first values", table.concat(first, ","))
	-- instances
	local part = Instance.new("Part")
	T.check(raises(function()
		part.Size = 5
	end, "Vector3 expected"), "property assignments are type-checked")
	T.check(raises(function()
		part.Material = Enum.Font.Gotham
	end), "an enum property rejects items of another enum")
	T.check(raises(function()
		Instance.new("UIAspectRatio")
	end, "Unable to create"), "Instance.new rejects classes Roblox cannot create")
	local folder = Instance.new("Folder")
	local added = 0
	folder.ChildAdded:Connect(function()
		added = added + 1
	end)
	part.Parent = folder
	T.eq(added, 1, "ChildAdded fires on reparenting")
	T.eq(folder:FindFirstChild(part.Name), part, "FindFirstChild")
	part:Destroy()
	T.check(part.Parent == nil, "Destroy sets Parent to nil")
	T.check(raises(function()
		part.Parent = folder
	end, "locked"), "a destroyed instance cannot be re-parented (Parent locked)")
	T.check(raises(function()
		local p2 = Instance.new("Part")
		p2.Parent = p2
	end), "an instance cannot parent itself")
	local model = Instance.new("Model")
	local c1 = Instance.new("Part", model)
	local clone = model:Clone()
	T.check(clone ~= model and #clone:GetChildren() == 1 and clone:GetChildren()[1] ~= c1, "Clone copies the whole tree")
	-- attributes
	local holder = Instance.new("Folder")
	local changes = 0
	holder:GetAttributeChangedSignal("N"):Connect(function()
		changes = changes + 1
	end)
	holder:SetAttribute("N", 1)
	holder:SetAttribute("N", 1)
	holder:SetAttribute("N", 2)
	T.eq(changes, 2, "attribute change signals only fire on real changes")
	T.check(raises(function()
		holder:SetAttribute("Bad", {})
	end), "attributes reject tables")
	T.check(raises(function()
		holder:SetAttribute("bad-name", 1)
	end), "attribute names are validated")
	-- tags
	local tagged_ = Instance.new("Part")
	local seen = 0
	CollectionService:GetInstanceAddedSignal("SmokeTag"):Connect(function()
		seen = seen + 1
	end)
	tagged_:AddTag("SmokeTag")
	tagged_.Parent = workspace
	T.eq(seen, 1, "GetInstanceAddedSignal fires when a tagged instance enters the game")
	T.eq(#CollectionService:GetTagged("SmokeTag"), 1, "CollectionService:GetTagged")
	tagged_:Destroy()
	T.eq(#CollectionService:GetTagged("SmokeTag"), 0, "destroyed instances are not returned by GetTagged")
	-- signals + scheduler
	local fired = {}
	local sig = Instance.new("BindableEvent")
	local c = sig.Event:Connect(function(x)
		fired[#fired + 1] = x
	end)
	sig:Fire(1)
	c:Disconnect()
	sig:Fire(2)
	T.check(#fired == 1 and fired[1] == 1, "disconnected handlers do not run")
	local waited
	task.spawn(function()
		waited = sig.Event:Wait()
	end)
	sig:Fire("w")
	T.eq(waited, "w", "Signal:Wait returns the fired arguments")
	local order = {}
	task.spawn(function()
		order[#order + 1] = "a"
		task.wait(0.5)
		order[#order + 1] = "c"
	end)
	order[#order + 1] = "b"
	advance(1)
	T.eq(table.concat(order), "abc", "task.spawn runs immediately until the first yield; task.wait resumes later")
	local t0 = os.clock()
	advance(2)
	T.near(os.clock() - t0, 2, 0.05, "os.clock follows the fake clock")
	local survived
	task.spawn(function()
		local ok = pcall(function()
			task.wait(0.2)
			survived = "yielded inside pcall"
		end)
	end)
	advance(0.5)
	T.eq(survived, "yielded inside pcall", "task.wait works inside pcall (like Luau)")
	local delayed = false
	local th = task.delay(1, function()
		delayed = true
	end)
	task.cancel(th)
	advance(2)
	T.eq(delayed, false, "task.cancel stops a delayed task")
	local errBefore = #Mock.Errors
	task.spawn(function()
		error("expected test error")
	end)
	T.check(#Mock.Errors == errBefore + 1, "errors inside task.spawn are recorded, not thrown")
	Mock.Errors[#Mock.Errors] = nil
	errorCursor = #Mock.Errors
	-- tweens complete on the fake clock
	local tp = Instance.new("Part")
	local tw = game:GetService("TweenService"):Create(tp, TweenInfo.new(0.5), { Transparency = 1 })
	local completed
	tw.Completed:Connect(function(state)
		completed = state
	end)
	tw:Play()
	advance(0.7)
	T.check(tp.Transparency == 1 and completed == Enum.PlaybackState.Completed, "TweenService tweens reach their goal and fire Completed")
	T.check(raises(function()
		game:GetService("TweenService"):Create(tp, TweenInfo.new(1), { Transparency = Vector3.new() })
	end), "TweenService:Create rejects goals of the wrong type")
	-- remotes respect the side they run on
	local re = Instance.new("RemoteEvent")
	T.check(raises(function()
		re:FireServer()
	end, "client"), "FireServer on the server is an error")
	T.check(raises(function()
		re:FireClient({})
	end), "FireClient needs a Player")
	-- world queries
	local box = Instance.new("Part")
	box.Anchored = true
	box.Size = Vector3.new(10, 2, 10)
	box.Position = Vector3.new(500, 5000, 500)
	box.Parent = workspace
	local hits = workspace:GetPartBoundsInBox(CFrame.new(500, 5000, 500), Vector3.new(4, 4, 4))
	T.check(#hits == 1 and hits[1] == box, "GetPartBoundsInBox finds overlapping parts")
	local params = OverlapParams.new()
	params.FilterDescendantsInstances = { box }
	T.eq(#workspace:GetPartBoundsInBox(CFrame.new(500, 5000, 500), Vector3.new(4, 4, 4), params), 0, "OverlapParams exclude filters")
	local ray = workspace:Raycast(Vector3.new(500, 5010, 500), Vector3.new(0, -20, 0))
	T.check(ray ~= nil and ray.Instance == box and math.abs(ray.Position.Y - 5001) < 1e-6 and ray.Normal == Vector3.new(0, 1, 0), "Workspace:Raycast hits the top face")
	box:Destroy()
	-- modules
	T.check(raises(function()
		require(Instance.new("Folder"))
	end), "require() only accepts ModuleScripts")
	-- DataStore deep-copies and rejects Roblox types
	local ds = game:GetService("DataStoreService"):GetDataStore("SelfTest")
	local data = { n = 1 }
	ds:SetAsync("k", data)
	data.n = 2
	T.eq(ds:GetAsync("k").n, 1, "DataStore stores copies")
	T.check(raises(function()
		ds:SetAsync("bad", { v = Vector3.new() })
	end), "DataStore rejects Vector3 values")
	-- v2: ProximityPrompt fixtures, GUI layout engine, ViewportFrame
	local prompt = Instance.new("ProximityPrompt")
	local triggeredBy
	prompt.Triggered:Connect(function(who)
		triggeredBy = who
	end)
	Mock.Trigger(prompt, Players:GetPlayers()[1] or "nobody")
	T.check(triggeredBy ~= nil, "Mock.Trigger fires ProximityPrompt.Triggered with the player")
	local vp = Instance.new("ViewportFrame")
	local world = Instance.new("WorldModel")
	local vcam = Instance.new("Camera")
	world.Parent = vp
	vcam.Parent = vp
	vp.CurrentCamera = vcam
	T.check(vp.CurrentCamera == vcam and vp:IsA("GuiObject"), "ViewportFrame accepts a Camera and a WorldModel")
	local function px(v)
		return math.floor(v + 0.5)
	end
	local savedViewport = Mock.Viewport
	Mock.SetViewport(1920, 1080)
	local gui = Instance.new("ScreenGui")
	gui.IgnoreGuiInset = true
	local centred = Instance.new("Frame")
	centred.Size = UDim2.new(0, 200, 0, 100)
	centred.Position = UDim2.new(0.5, 0, 0.5, 0)
	centred.AnchorPoint = Vector2.new(0.5, 0.5)
	centred.Parent = gui
	T.check(px(centred.AbsolutePosition.X) == 860 and px(centred.AbsolutePosition.Y) == 490 and centred.AbsoluteSize.X == 200, "layout: centre-anchored frame at 1920x1080", tostring(centred.AbsolutePosition))
	gui.IgnoreGuiInset = false
	T.check(px(centred.AbsolutePosition.Y) == px((1080 - Mock.TopInset) / 2 - 50), "layout: IgnoreGuiInset = false shrinks the ScreenGui area by the top bar", tostring(centred.AbsolutePosition))
	gui.IgnoreGuiInset = true
	centred.Position = UDim2.new(0, 10, 0, 20)
	centred.AnchorPoint = Vector2.new(0, 0)
	T.check(centred.AbsolutePosition.X == 10 and centred.AbsolutePosition.Y == 20, "layout: results follow property changes (cache invalidation)", tostring(centred.AbsolutePosition))
	local padded = Instance.new("Frame")
	padded.Size = UDim2.new(0, 400, 0, 300)
	padded.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingTop, pad.PaddingRight, pad.PaddingBottom = UDim.new(0, 10), UDim.new(0, 20), UDim.new(0, 30), UDim.new(0, 40)
	pad.Parent = padded
	local inner = Instance.new("Frame")
	inner.Size = UDim2.new(1, 0, 1, 0)
	inner.Parent = padded
	T.check(inner.AbsoluteSize.X == 360 and inner.AbsoluteSize.Y == 240 and inner.AbsolutePosition.X == 10 and inner.AbsolutePosition.Y == 20, "layout: UIPadding shrinks the children's area", tostring(inner.AbsoluteSize) .. " at " .. tostring(inner.AbsolutePosition))
	local scaled = Instance.new("Frame")
	scaled.Size = UDim2.new(0, 100, 0, 50)
	scaled.AnchorPoint = Vector2.new(1, 1)
	scaled.Position = UDim2.new(1, -10, 1, -10)
	scaled.Parent = gui
	local us = Instance.new("UIScale")
	us.Scale = 2
	us.Parent = scaled
	local kid = Instance.new("Frame")
	kid.Size = UDim2.new(0, 10, 0, 10)
	kid.Parent = scaled
	T.check(scaled.AbsoluteSize.X == 200 and px(scaled.AbsolutePosition.X) == 1920 - 10 - 200 and px(scaled.AbsolutePosition.Y) == 1080 - 10 - 100, "layout: UIScale grows an object around its AnchorPoint", tostring(scaled.AbsolutePosition) .. " " .. tostring(scaled.AbsoluteSize))
	T.check(kid.AbsoluteSize.X == 20, "layout: UIScale also scales the offsets of the children", tostring(kid.AbsoluteSize))
	local list = Instance.new("Frame")
	list.Size = UDim2.new(0, 200, 0, 400)
	list.Parent = gui
	local ll = Instance.new("UIListLayout")
	ll.Padding = UDim.new(0, 5)
	ll.SortOrder = Enum.SortOrder.LayoutOrder
	ll.HorizontalAlignment = Enum.HorizontalAlignment.Center
	ll.VerticalAlignment = Enum.VerticalAlignment.Center
	ll.Parent = list
	local rows = {}
	for i = 1, 3 do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(0, 100, 0, 20)
		row.LayoutOrder = 4 - i
		row.Parent = list
		rows[i] = row
	end
	local lp = list.AbsolutePosition
	T.check(px(rows[1].AbsolutePosition.Y - lp.Y) == 215 and px(rows[2].AbsolutePosition.Y - lp.Y) == 190, "layout: UIListLayout stacks children in LayoutOrder (rows 25 studs apart)", tostring(rows[1].AbsolutePosition.Y - lp.Y))
	T.check(px(rows[3].AbsolutePosition.Y - lp.Y) == px((400 - 70) / 2) and px(rows[3].AbsolutePosition.X - lp.X) == 50, "layout: UIListLayout centres a vertical stack and its rows", tostring(rows[3].AbsolutePosition - lp))
	local grid = Instance.new("Frame")
	grid.Size = UDim2.new(0, 230, 0, 300)
	grid.Parent = gui
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.new(0, 50, 0, 50)
	gl.CellPadding = UDim2.new(0, 10, 0, 10)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = grid
	local cells = {}
	for i = 1, 9 do
		local cell = Instance.new("Frame")
		cell.LayoutOrder = i
		cell.Parent = grid
		cells[i] = cell
	end
	local gp = grid.AbsolutePosition
	T.check(cells[1].AbsoluteSize.X == 50 and px(cells[4].AbsolutePosition.X - gp.X) == 180 and px(cells[5].AbsolutePosition.Y - gp.Y) == 60 and px(cells[5].AbsolutePosition.X - gp.X) == 0, "layout: UIGridLayout wraps rows of 4 cells (230 wide)", tostring(cells[4].AbsolutePosition - gp) .. " " .. tostring(cells[5].AbsolutePosition - gp))
	local auto = Instance.new("TextLabel")
	auto.AutomaticSize = Enum.AutomaticSize.Y
	auto.Size = UDim2.new(0, 100, 0, 0)
	auto.TextSize = 20
	auto.TextWrapped = true
	auto.Text = "alpha beta gamma delta epsilon zeta"
	auto.Parent = gui
	T.check(auto.AbsoluteSize.Y >= 40 and auto.AbsoluteSize.X == 100, "layout: AutomaticSize.Y grows a wrapped TextLabel", tostring(auto.AbsoluteSize))
	local box = Instance.new("Frame")
	box.AutomaticSize = Enum.AutomaticSize.XY
	box.Size = UDim2.new(0, 0, 0, 0)
	box.Parent = gui
	local b1 = Instance.new("Frame")
	b1.Size = UDim2.new(0, 70, 0, 30)
	b1.Position = UDim2.new(0, 10, 0, 5)
	b1.Parent = box
	T.check(box.AbsoluteSize.X == 80 and box.AbsoluteSize.Y == 35, "layout: AutomaticSize.XY wraps the children", tostring(box.AbsoluteSize))
	Mock.SetViewport(390, 844)
	T.check(px(Mock.GuiBox(gui).w) == 390, "layout: Mock.SetViewport changes every ScreenGui")
	Mock.Viewport = savedViewport
	Mock.GuiEpoch = Mock.GuiEpoch + 1
	-- DataStore keys are "<store>/<key>" so legacy saves can be seeded
	Mock.DataStore.Data["SelfTest/seed"] = { n = 7 }
	T.eq(ds:GetAsync("seed").n, 7, "Mock.DataStore.Data['<store>/<key>'] seeds a store")
	Mock.DataStore.Data["SelfTest/seed"] = nil
	Mock.DataStore.Data["SelfTest/k"] = nil
	flushErrors("mock selftest")
end)

----------------------------------------------------------------------------------------------------
-- scenario: load every module
----------------------------------------------------------------------------------------------------

S.load_modules = guarded("load_modules", function()
	local keys = {}
	for key in pairs(CONTRACT.modules) do
		if not key:find("^client/") then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	-- shared first, then the rest (a module may require its siblings)
	table.sort(keys, function(a, b)
		local sa, sb = a:find("^shared/") and 0 or 1, b:find("^shared/") and 0 or 1
		if sa ~= sb then
			return sa < sb
		end
		return a < b
	end)
	local loaded = 0
	for _, key in ipairs(keys) do
		local inst = moduleInstance(key)
		if not inst then
			T.fail(key .. " exists", "no ModuleScript at " .. key .. " (default.project.json mounts src/ for Rojo)")
		else
			local ok, result = pcall(require, inst)
			if ok and type(result) == "table" then
				M[key] = result
				loaded = loaded + 1
				T.ok(key .. " loads")
			elseif ok then
				T.fail(key .. " returns a table", "returned " .. type(result))
			else
				T.fail(key .. " loads without errors", tostring(result))
			end
		end
	end
	for _, script in ipairs(CONTRACT.scripts or {}) do
		local inst = moduleInstance(script)
		T.check(inst ~= nil and (inst:IsA("Script") or inst:IsA("LocalScript")), script .. " exists as a script", "missing " .. script)
	end
	T.info("*loaded " .. loaded .. " shared/server modules")
	flushErrors("module load")
end)

----------------------------------------------------------------------------------------------------
-- scenario: public API of every module (tools/contract.json == ARCHITECTURE.md)
----------------------------------------------------------------------------------------------------
local function isCallable(v)
	if type(v) == "function" then
		return true
	end
	local mt = type(v) == "table" and getmetatable(v)
	return mt ~= nil and type(mt) == "table" and type(mt.__call) == "function"
end

S.contract = guarded("contract", function()
	local problems = 0
	for key, spec in pairs(CONTRACT.modules) do
		local m = M[key]
		if m then
			for _, name in pairs(spec["functions"] or {}) do
				if not isCallable(m[name]) then
					problems = problems + 1
					T.fail(key .. "." .. name .. " is a function", "got " .. type(m[name]))
				end
			end
			for _, name in pairs(spec["signals"] or {}) do
				local s = m[name]
				if type(s) ~= "table" or not isCallable(s.Connect) or not isCallable(s.Fire) then
					problems = problems + 1
					T.fail(key .. "." .. name .. " is a signal (Connect + Fire)", "got " .. type(s))
				else
					local got
					local conn = s:Connect(function(...)
						got = { ... }
					end)
					s:Fire("probe", 1)
					advance(0.1)
					conn:Disconnect()
					T.check(got ~= nil and got[1] == "probe", key .. "." .. name .. " delivers events", "handler did not run")
				end
			end
			for _, name in pairs(spec.fields or {}) do
				if m[name] == nil then
					problems = problems + 1
					T.fail(key .. "." .. name .. " exists", "nil")
				end
			end
		end
	end
	T.check(problems == 0, "all modules expose their ARCHITECTURE.md API", problems .. " member(s) missing")
	-- Theme: every font role exists and is an Enum.Font item
	local Theme = M["shared/Theme"]
	if Theme then
		for _, role in ipairs({ "Title", "Display", "Heading", "Body", "Label", "Accent", "Script" }) do
			T.check(typeof(Theme.Fonts[role]) == "EnumItem", "Theme.Fonts." .. role .. " is a font", tostring(Theme.Fonts[role]))
		end
	end
end)

----------------------------------------------------------------------------------------------------
-- shared scenario state + helpers (the layout and course scenarios live in smoke_content.lua)
----------------------------------------------------------------------------------------------------
local W = { lobbyInfo = nil, matches = 0 } -- world state shared by the scenarios

local function tagged(tag, container)
	local out = {}
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		if container == nil or inst:IsDescendantOf(container) then
			out[#out + 1] = inst
		end
	end
	return out
end

local function courseFolders()
	local out = {}
	for _, c in ipairs(workspace:GetChildren()) do
		if c.Name:find("^Course_") then
			out[#out + 1] = c
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- scenario: boot the real Main.server.lua
----------------------------------------------------------------------------------------------------
local function pathOf(inst)
	return inst:GetFullName()
end

S.boot = guarded("boot", function()
	local Config = config()
	local LB = mod("LobbyBuilder")
	local origBuild = LB.Build
	LB.Build = function(...)
		local info = origBuild(...)
		W.lobbyInfo = info
		return info
	end
	Mock.RecordReplication()
	Mock.TouchSim = true
	local mainScript = moduleInstance("server/Main")
	T.check(mainScript ~= nil, "server/Main.server.lua is mounted as a Script")
	local before = #Mock.Output
	outputCursor = #Mock.Output
	W.bootStart = Mock.RealClock()
	Mock.RunScript(mainScript)
	advance(2)
	LB.Build = origBuild
	W.bootSeconds = Mock.RealClock() - W.bootStart
	local ready = false
	for i = before + 1, #Mock.Output do
		if Mock.Output[i].text:find("[NimbusClimb] ready", 1, true) then
			ready = true
		end
	end
	T.check(ready, "Main.server.lua prints '[NimbusClimb] ready'")
	T.info("*server boot took " .. fmt(W.bootSeconds, 2) .. "s real time")
	flushWarnings("boot")
	flushErrors("boot")

	-- remotes
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	T.check(folder ~= nil, "ReplicatedStorage.Remotes exists")
	if folder then
		for _, name in ipairs(Config.Remotes) do
			local r = folder:FindFirstChild(name)
			T.check(r ~= nil and r:IsA("RemoteEvent"), "remote " .. name .. " is a RemoteEvent", r and r.ClassName or "missing")
		end
	end

	-- lighting + global settings: the v2 "late-afternoon calm" look (ARCHITECTURE_V2.md section 6)
	local Lighting = game:GetService("Lighting")
	T.near(Lighting.ClockTime, 15.2, 1.0, "Lighting.ClockTime is late afternoon (~15.2)")
	T.near(Lighting.Brightness, 1.5, 0.45, "Lighting.Brightness is lowered (~1.5)")
	local function rgb255(c)
		return c.R * 255, c.G * 255, c.B * 255
	end
	local function nearColor(c, r, g, b, tol, name)
		local cr, cg, cb = rgb255(c)
		T.check(math.abs(cr - r) <= tol and math.abs(cg - g) <= tol and math.abs(cb - b) <= tol, name, string.format("got %.0f,%.0f,%.0f expected ~%d,%d,%d", cr, cg, cb, r, g, b))
	end
	nearColor(Lighting.Ambient, 84, 96, 128, 24, "Lighting.Ambient is a dim blue (~84,96,128)")
	nearColor(Lighting.OutdoorAmbient, 108, 120, 152, 24, "Lighting.OutdoorAmbient is a dim blue (~108,120,152)")
	T.check(Lighting.ExposureCompensation <= -0.1 and Lighting.ExposureCompensation >= -0.6, "Lighting.ExposureCompensation is slightly negative (~-0.3)", tostring(Lighting.ExposureCompensation))
	T.near(Lighting.EnvironmentDiffuseScale, 0.5, 0.25, "Lighting.EnvironmentDiffuseScale ~0.5")
	T.near(Lighting.EnvironmentSpecularScale, 0.4, 0.25, "Lighting.EnvironmentSpecularScale ~0.4")
	T.eq(Lighting.GlobalShadows, true, "Lighting.GlobalShadows is on")
	T.near(Lighting.ShadowSoftness, 0.25, 0.15, "Lighting.ShadowSoftness ~0.25 (soft shadows)")
	for _, cls in ipairs({ "Atmosphere", "BloomEffect", "SunRaysEffect", "ColorCorrectionEffect" }) do
		T.check(Lighting:FindFirstChildOfClass(cls) ~= nil, "Lighting has " .. cls)
	end
	T.check(Lighting:FindFirstChildOfClass("Sky") ~= nil, "Lighting has a Sky")
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if atm then
		T.near(atm.Density, 0.3, 0.12, "Atmosphere.Density ~0.3")
		T.near(atm.Offset, 0.25, 0.15, "Atmosphere.Offset ~0.25")
		T.near(atm.Glare, 0.2, 0.2, "Atmosphere.Glare ~0.2")
		T.near(atm.Haze, 1.2, 0.8, "Atmosphere.Haze ~1.2")
		local cr, cg, cb = rgb255(atm.Color)
		T.check(cb >= cr, "Atmosphere.Color is blue-grey", string.format("%.0f,%.0f,%.0f", cr, cg, cb))
		local dr, dg, db = rgb255(atm.Decay)
		T.check(dr >= db, "Atmosphere.Decay is a soft peach", string.format("%.0f,%.0f,%.0f", dr, dg, db))
	end
	local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	if bloom then
		T.check(bloom.Intensity <= 0.3 and bloom.Threshold >= 1.2, "Bloom is subtle (Intensity <= 0.3, Threshold >= 1.2)", "Intensity " .. bloom.Intensity .. " Threshold " .. bloom.Threshold)
		T.near(bloom.Size, 16, 10, "Bloom.Size ~16")
	end
	local rays = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if rays then
		T.check(rays.Intensity <= 0.1, "SunRays are faint (<= 0.1)", tostring(rays.Intensity))
	end
	local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if cc then
		T.near(cc.Contrast, 0.14, 0.12, "ColorCorrection.Contrast ~0.14")
		T.near(cc.Saturation, 0.08, 0.12, "ColorCorrection.Saturation ~0.08 (not neon)")
		T.near(cc.Brightness, -0.03, 0.06, "ColorCorrection.Brightness ~-0.03")
	end
	local dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	T.check(dof == nil or dof.Enabled == false or (dof.FarIntensity <= 0.2 and dof.NearIntensity <= 0.2), "DepthOfField is off or extremely subtle")
	T.near(workspace.Gravity, Config.Physics.Gravity, 0.001, "workspace.Gravity == Config.Physics.Gravity")
	T.eq(workspace.FallenPartsDestroyHeight, -2000, "FallenPartsDestroyHeight is -2000")
	T.eq(Players.CharacterAutoLoads, true, "Players.CharacterAutoLoads is true")
	T.eq(workspace.StreamingEnabled, false, "StreamingEnabled stays false")
	-- LightingService.Init is idempotent
	local LS = mod("LightingService")
	local atmBefore = #Lighting:GetChildren()
	pcall(LS.Init)
	T.eq(#Lighting:GetChildren(), atmBefore, "LightingService.Init is idempotent (no duplicate effects)")
	W.baseline = Mock.Stats()
	W.baselineChildren = {}
	for _, c in ipairs(workspace:GetChildren()) do
		W.baselineChildren[#W.baselineChildren + 1] = c.Name
	end
end)

----------------------------------------------------------------------------------------------------
-- scenario: the lobby (v2: five gates, 16 spots, shop island)
----------------------------------------------------------------------------------------------------
-- World palette rules (ARCHITECTURE_V2.md): no pure-white parts, Neon only for small accents.
-- Returns { parts = n, white = {paths}, neon = {paths}, neonCount = n }.
local function paletteAudit(container, limits)
	limits = limits or {}
	local maxNeonFace = limits.maxNeonFace or 160 -- studs^2 of the largest face of an opaque Neon part
	local out = { parts = 0, white = {}, bigNeon = {}, neonCount = 0, whiteCount = 0, bigNeonCount = 0 }
	for _, d in ipairs(container:GetDescendants()) do
		if d:IsA("BasePart") and not d:IsA("Terrain") then
			out.parts = out.parts + 1
			local c = d.Color
			local size = d.Size
			if c.R >= 0.975 and c.G >= 0.975 and c.B >= 0.975 and d.Transparency < 0.9 and math.max(size.X, size.Y, size.Z) >= 2.5 then
				out.whiteCount = out.whiteCount + 1
				if #out.white < 5 then
					out.white[#out.white + 1] = d:GetFullName() .. " " .. tostring(size)
				end
			end
			if d.Material == Enum.Material.Neon then
				out.neonCount = out.neonCount + 1
				local a, b, cc = size.X, size.Y, size.Z
				local face = math.max(a * b, a * cc, b * cc)
				if d.Shape == Enum.PartType.Ball or d.Shape == Enum.PartType.Cylinder then
					-- a ball / cylinder shows its biggest circle, not the bounding face
					face = math.max(a, b, cc) ^ 2 * 0.785
				end
				if face > maxNeonFace and d.Transparency < 0.5 then
					out.bigNeonCount = out.bigNeonCount + 1
					if #out.bigNeon < 5 then
						out.bigNeon[#out.bigNeon + 1] = d:GetFullName() .. " " .. tostring(size)
					end
				end
			end
		end
	end
	return out
end

local function shortPath(inst)
	local name = inst:GetFullName()
	return (name:gsub("^Game%.", ""))
end

local function textsUnder(inst)
	local out = {}
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			out[#out + 1] = tostring(d.Text)
		end
	end
	return out
end

local function plainText(list)
	return (table.concat(list, "\n"):gsub("<[^>]*>", ""))
end

local function countStars(list)
	local n = 0
	for _, t in ipairs(list) do
		local _, c = tostring(t):gsub("\226\152\133", "")
		n = math.max(n, c)
	end
	return n
end

local function colorDistance255(a, b)
	return math.sqrt(((a.R - b.R) * 255) ^ 2 + ((a.G - b.G) * 255) ^ 2 + ((a.B - b.B) * 255) ^ 2)
end

-- Is there a collidable surface right under `pos` (within `depth` studs)?
local function groundBelow(pos, depth)
	local params = RaycastParams.new()
	params.RespectCanCollide = true
	local hit = workspace:Raycast(pos + Vector3.new(0, 3, 0), Vector3.new(0, -(depth or 14), 0), params)
	return hit ~= nil, hit
end

S.lobby = guarded("lobby", function()
	local Config = config()
	local info = W.lobbyInfo
	if not T.check(type(info) == "table", "LobbyBuilder.Build() returned a LobbyInfo table", "boot did not run or Main did not call LobbyBuilder.Build") then
		return
	end
	local folder = info.Folder
	T.check(typeof(folder) == "Instance" and folder.Name == "NimbusLobby" and folder.Parent == workspace, "LobbyInfo.Folder is workspace.NimbusLobby")
	T.check(typeof(info.SpawnCFrame) == "CFrame", "LobbyInfo.SpawnCFrame is a CFrame")
	if typeof(info.SpawnCFrame) == "CFrame" then
		local p = info.SpawnCFrame.Position
		local horiz = math.sqrt((p.X - Config.Lobby.Origin.X) ^ 2 + (p.Z - Config.Lobby.Origin.Z) ^ 2)
		T.check(horiz <= Config.Lobby.PlazaRadius, "spawn is on the plaza", "horizontal distance " .. fmt(horiz))
		T.check(math.abs(p.Y - (Config.Lobby.Origin.Y + 3)) <= 4, "spawn is ~3 studs above the plaza surface", "y=" .. fmt(p.Y))
		T.check(groundBelow(p, 12), "the plaza spawn stands on a solid surface")
	end
	-- size + budget
	local parts = Mock.CountDescendants(folder, "BasePart")
	T.check(parts < 2500, "lobby has fewer than 2500 parts", parts .. " parts")
	T.check(parts > 800, "the v2 lobby is big (more than 800 parts)", parts .. " parts")
	T.info("*lobby: " .. parts .. " parts, " .. Mock.CountDescendants(folder) .. " instances, " .. Mock.CountDescendants(folder, "ParticleEmitter") .. " emitters, " .. Mock.CountDescendants(folder, "PointLight") .. " lights")
	local loose, bigCasters = 0, 0
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("BasePart") then
			if not d.Anchored then
				loose = loose + 1
			end
			if d.CastShadow and math.max(d.Size.X, d.Size.Y, d.Size.Z) < 1.5 then
				bigCasters = bigCasters + 1
			end
		end
	end
	T.check(loose == 0, "all lobby parts are Anchored", loose .. " unanchored")
	T.check(bigCasters <= parts * 0.05, "small lobby parts have CastShadow = false (at most 5% exceptions)", bigCasters .. " small parts cast shadows")
	T.check(#tagged(Config.Tags.CloudToken, folder) == 0, "decorative lobby tokens are not tagged CloudToken (no collection in the lobby)")
	local spawns = 0
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("SpawnLocation") then
			spawns = spawns + 1
		end
	end
	T.eq(spawns, 0, "no SpawnLocation is used (players are placed with SpawnCFrame)")
	-- palette
	local pal = paletteAudit(folder)
	T.check(pal.whiteCount == 0, "no lobby part is pure white", pal.whiteCount .. " parts, e.g. " .. table.concat(pal.white, "; "))
	T.check(pal.bigNeonCount == 0, "Neon is used for small accents only (no big opaque Neon surfaces)", pal.bigNeonCount .. " big parts, e.g. " .. table.concat(pal.bigNeon, "; "))
	T.check(pal.neonCount >= 6, "lobby has neon accents (arch, portal rings)", pal.neonCount .. " neon parts")
	T.check(Mock.CountDescendants(folder, "ParticleEmitter") >= 3, "lobby has particle emitters (portal swirls, fireflies)")
	T.check(Mock.CountDescendants(folder, "PointLight") >= 3, "lobby has point lights (portals, lanterns)")
	local prompts = Mock.CountDescendants(folder, "ProximityPrompt")
	T.check(prompts >= #Config.Roulettes + 1, "PetService / ItemService created the shop ProximityPrompts", prompts .. " prompts")

	-- portals: one per difficulty
	local nPortals = 0
	for _ in pairs(info.Portals or {}) do
		nPortals = nPortals + 1
	end
	T.eq(nPortals, #Config.Difficulties, "LobbyInfo.Portals holds exactly one portal per difficulty")
	for _, id in ipairs(CONTRACT.v2.oldDifficultyIds) do
		T.check(info.Portals[id] == nil, "no portal for the removed difficulty " .. id)
	end
	local lastAngle
	for _, diff in ipairs(Config.Difficulties) do
		local p = info.Portals and info.Portals[diff.Id]
		if T.check(type(p) == "table", "portal " .. diff.Id .. " exists in LobbyInfo.Portals") then
			T.eq(p.Id, diff.Id, diff.Id .. ": PortalInfo.Id")
			local zone = p.Zone
			if T.check(typeof(zone) == "Instance" and zone:IsA("BasePart"), diff.Id .. ": Zone is a BasePart") then
				T.check(zone.CanCollide == false, diff.Id .. ": Zone is not collidable")
				T.check(zone.Size.X >= 10 and zone.Size.X <= 22 and zone.Size.Z >= 10 and zone.Size.Z <= 22 and zone.Size.Y >= 3 and zone.Size.Y <= 12, diff.Id .. ": Zone is ~14x6x14", tostring(zone.Size))
				T.check(zone:IsDescendantOf(folder), diff.Id .. ": Zone lives in the lobby folder")
				T.check(typeof(p.Center) == "Vector3" and (p.Center - zone.Position).Magnitude < 3, diff.Id .. ": Center is the zone centre")
				local horiz = math.sqrt((zone.Position.X - Config.Lobby.Origin.X) ^ 2 + (zone.Position.Z - Config.Lobby.Origin.Z) ^ 2)
				T.check(math.abs(horiz - Config.Lobby.PortalRingRadius) <= 12, diff.Id .. ": portal sits on the ring (radius " .. Config.Lobby.PortalRingRadius .. ")", "horizontal distance " .. fmt(horiz))
				T.check(groundBelow(zone.Position, 14), diff.Id .. ": the portal pad has solid ground under it")
				-- gates are ordered Easy -> Saint around the plaza
				local angle = math.atan2(zone.Position.Z - Config.Lobby.Origin.Z, zone.Position.X - Config.Lobby.Origin.X)
				if lastAngle ~= nil then
					T.check(math.abs(angle - lastAngle) > 0.2, diff.Id .. ": portals do not overlap each other")
				end
				lastAngle = angle
				-- a Neon trim in the difficulty colour near the gate
				local best = 1e9
				for _, d in ipairs(folder:GetDescendants()) do
					if d:IsA("BasePart") and d.Material == Enum.Material.Neon then
						local dx, dz = d.Position.X - zone.Position.X, d.Position.Z - zone.Position.Z
						if dx * dx + dz * dz < 18 * 18 then
							best = math.min(best, colorDistance255(d.Color, diff.Color))
						end
					end
				end
				T.check(best <= 70, diff.Id .. ": the gate has a Neon trim in the difficulty colour", "closest neon colour distance " .. fmt(best, 0))
			end
			T.check(typeof(p.Billboard) == "Instance" and p.Billboard:IsA("BillboardGui"), diff.Id .. ": Billboard is a BillboardGui")
			for _, labelName in ipairs({ "TitleLabel", "CountLabel", "StatusLabel" }) do
				local l = p[labelName]
				T.check(typeof(l) == "Instance" and l:IsA("TextLabel") and l:IsDescendantOf(p.Billboard), diff.Id .. ": " .. labelName .. " is a TextLabel inside the Billboard")
			end
			if p.TitleLabel then
				T.check(tostring(p.TitleLabel.Text):lower():find(diff.DisplayName:lower(), 1, true) ~= nil, diff.Id .. ": title shows the difficulty name", p.TitleLabel.Text)
			end
			if p.CountLabel then
				T.check(tostring(p.CountLabel.Text):find("0") ~= nil and tostring(p.CountLabel.Text):find(tostring(Config.Match.MaxPlayers)) ~= nil, diff.Id .. ": CountLabel starts at '0 / " .. Config.Match.MaxPlayers .. " players'", p.CountLabel.Text)
			end
			T.eq(countStars(textsUnder(p.Billboard)), diff.Stars, diff.Id .. ": billboard shows " .. diff.Stars .. " star(s)")
		end
	end

	-- spots: personal cloud homes on the outer ring
	local nSpots, maxIndex = 0, 0
	for index in pairs(info.Spots or {}) do
		nSpots = nSpots + 1
		maxIndex = math.max(maxIndex, index)
	end
	T.eq(nSpots, Config.Lobby.SpotCount, "LobbyInfo.Spots has Config.Lobby.SpotCount (" .. Config.Lobby.SpotCount .. ") spots")
	T.eq(maxIndex, Config.Lobby.SpotCount, "spot indices run 1.." .. Config.Lobby.SpotCount)
	local centres = {}
	local spotProblems = T.tally("every SpotInfo has Index/Folder/Center/SpawnCFrame/NameLabel/SubLabel/PodiumCFrame on solid ground")
	local ringProblems = T.tally("spots stand on the outer ring (radius " .. Config.Lobby.SpotRingRadius .. ")")
	local freeProblems = T.tally("unowned spots read 'Free spot' / 'Step in to claim'")
	for i = 1, Config.Lobby.SpotCount do
		local sp = info.Spots and info.Spots[i]
		if sp then
			local ok = sp.Index == i and typeof(sp.Folder) == "Instance" and sp.Folder:IsDescendantOf(folder) and typeof(sp.Center) == "Vector3" and typeof(sp.SpawnCFrame) == "CFrame"
				and typeof(sp.NameLabel) == "Instance" and sp.NameLabel:IsA("TextLabel") and typeof(sp.SubLabel) == "Instance" and sp.SubLabel:IsA("TextLabel") and typeof(sp.PodiumCFrame) == "CFrame"
			spotProblems:case(ok, "spot " .. i .. " has a malformed SpotInfo")
			if ok then
				spotProblems:case(groundBelow(sp.SpawnCFrame.Position, 14), "spot " .. i .. ": no solid ground under SpawnCFrame")
				spotProblems:case((sp.PodiumCFrame.Position - sp.Center).Magnitude < 40, "spot " .. i .. ": podium is far from the spot centre")
				spotProblems:case(sp.NameLabel:IsDescendantOf(sp.Folder) or sp.NameLabel:IsDescendantOf(folder), "spot " .. i .. ": nameplate is outside the lobby")
				local horiz = math.sqrt((sp.Center.X - Config.Lobby.Origin.X) ^ 2 + (sp.Center.Z - Config.Lobby.Origin.Z) ^ 2)
				ringProblems:case(math.abs(horiz - Config.Lobby.SpotRingRadius) <= 30, "spot " .. i .. " is " .. fmt(horiz) .. " from the origin")
				freeProblems:case(sp.NameLabel.Text == "Free spot" and sp.SubLabel.Text == "Step in to claim", "spot " .. i .. " reads '" .. sp.NameLabel.Text .. "' / '" .. sp.SubLabel.Text .. "'")
				for j = 1, #centres do
					if (centres[j] - sp.Center).Magnitude < 20 then
						spotProblems:case(false, "spots " .. j .. " and " .. i .. " overlap")
					end
				end
				centres[#centres + 1] = sp.Center
				T.check(sp.SpawnCFrame.Position.Y > Config.Lobby.KillY + 40, "spot " .. i .. ": spawn is well above the lobby kill plane")
			end
		end
	end
	spotProblems:report()
	ringProblems:report()
	freeProblems:report()

	-- shop island: four roulette machines + the item counter
	local shop = info.Shop
	if T.check(type(shop) == "table", "LobbyInfo.Shop exists") then
		local shopCentre = Config.Lobby.Origin + Config.Lobby.ShopOffset
		for _, r in ipairs(Config.Roulettes) do
			local m = shop.Roulettes and shop.Roulettes[r.Id]
			if T.check(type(m) == "table", "roulette machine " .. r.Id .. " exists") then
				T.eq(m.Id, r.Id, r.Id .. ": machine Id")
				T.check(typeof(m.PromptPart) == "Instance" and m.PromptPart:IsA("BasePart"), r.Id .. ": PromptPart is a BasePart")
				T.check(typeof(m.Center) == "Vector3" and typeof(m.Model) == "Instance", r.Id .. ": Center and Model are set")
				if typeof(m.Center) == "Vector3" then
					local d = math.sqrt((m.Center.X - shopCentre.X) ^ 2 + (m.Center.Z - shopCentre.Z) ^ 2)
					T.check(d <= 60, r.Id .. ": the machine stands on the shop island", "distance " .. fmt(d))
					T.check(groundBelow(m.PromptPart.Position, 14), r.Id .. ": ground under the machine's prompt part")
				end
				if typeof(m.Model) == "Instance" then
					local text = plainText(textsUnder(m.Model))
					T.check(text:lower():find(r.DisplayName:lower():gsub("%s+", "%%s+")) ~= nil or text:lower():find(r.Id:lower(), 1, true) ~= nil, r.Id .. ": the machine shows its name", text)
					local priceText = tostring(r.Price):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
					T.check(text:find(priceText, 1, true) ~= nil or text:find(tostring(r.Price), 1, true) ~= nil, r.Id .. ": the machine shows its price " .. priceText, text)
					local best = 1e9
					for _, d in ipairs(m.Model:GetDescendants()) do
						if d:IsA("BasePart") then
							best = math.min(best, colorDistance255(d.Color, r.Color))
						end
					end
					T.check(best <= 60, r.Id .. ": the machine is built in the roulette colour", "closest part colour distance " .. fmt(best, 0))
				end
				local prompt = m.PromptPart:FindFirstChildOfClass("ProximityPrompt")
				if T.check(prompt ~= nil, r.Id .. ": PetService put a ProximityPrompt on the PromptPart") then
					T.eq(prompt.ActionText, "Open", r.Id .. ": prompt ActionText")
					T.eq(prompt.ObjectText, r.DisplayName, r.Id .. ": prompt ObjectText")
					T.eq(prompt.HoldDuration, 0, r.Id .. ": prompt HoldDuration")
					T.eq(prompt.MaxActivationDistance, 12, r.Id .. ": prompt MaxActivationDistance")
					T.eq(prompt.RequiresLineOfSight, false, r.Id .. ": prompt RequiresLineOfSight")
				end
			end
		end
		local stall = shop.ItemShop
		if T.check(type(stall) == "table", "the item shop counter exists") then
			T.check(typeof(stall.PromptPart) == "Instance" and stall.PromptPart:IsA("BasePart"), "ItemShop.PromptPart is a BasePart")
			T.check(typeof(stall.Center) == "Vector3" and typeof(stall.Model) == "Instance", "ItemShop Center and Model are set")
			local prompt = stall.PromptPart and stall.PromptPart:FindFirstChildOfClass("ProximityPrompt")
			T.check(prompt ~= nil and prompt.HoldDuration == 0, "ItemService put a ProximityPrompt on the item counter")
		end
	end

	-- signs
	local all = plainText(textsUnder(folder)):upper()
	T.check(all:find(Config.GameName:upper(), 1, true) ~= nil, "welcome sign shows the game name '" .. Config.GameName .. "'")
	for _, kw in ipairs({ "SHIFT", "DASH", "SPACE", "PORTAL" }) do
		T.check(all:find(kw, 1, true) ~= nil, "'How to play' board mentions " .. kw)
	end
	flushErrors("lobby")
end)

----------------------------------------------------------------------------------------------------
-- payload schemas (ARCHITECTURE.md): validated for every remote message
----------------------------------------------------------------------------------------------------
local V = {}
local function isNum(v)
	return type(v) == "number" and v == v
end
local function isStr(v)
	return type(v) == "string"
end
local function isBool(v)
	return type(v) == "boolean"
end

function V.matchState(st)
	local p = {}
	if type(st) ~= "table" then
		return { "payload is " .. type(st) .. ", expected a table or nil" }
	end
	if not (st.Phase == "Countdown" or st.Phase == "Playing" or st.Phase == "Ended") then
		p[#p + 1] = "Phase " .. tostring(st.Phase)
	end
	if not isStr(st.DifficultyId) then
		p[#p + 1] = "DifficultyId"
	end
	if not isStr(st.DifficultyName) then
		p[#p + 1] = "DifficultyName"
	end
	if typeof(st.Color) ~= "Color3" then
		p[#p + 1] = "Color is " .. typeof(st.Color)
	end
	for _, k in ipairs({ "Seconds", "Checkpoint", "TotalCheckpoints", "TokensCollected", "TotalTokens" }) do
		if not isNum(st[k]) then
			p[#p + 1] = k .. " is " .. typeof(st[k])
		end
	end
	if type(st.Members) ~= "table" then
		p[#p + 1] = "Members"
	else
		for i, m in ipairs(st.Members) do
			if not (isNum(m.UserId) and isStr(m.Name) and isNum(m.Health) and m.Health >= 0 and m.Health <= 1 and isBool(m.Downed) and isBool(m.Finished) and isNum(m.Tokens)) then
				p[#p + 1] = "Members[" .. i .. "] malformed"
			end
		end
	end
	return p
end

function V.matchResult(r)
	local p = {}
	if type(r) ~= "table" then
		return { "payload is " .. type(r) }
	end
	if not isBool(r.Won) then
		p[#p + 1] = "Won"
	end
	if not (r.Reason == "victory" or r.Reason == "defeat" or r.Reason == "timeout" or r.Reason == "abandoned") then
		p[#p + 1] = "Reason " .. tostring(r.Reason)
	end
	for _, k in ipairs({ "Seconds", "MatchTokens", "Bonus", "TotalTokens" }) do
		if not isNum(r[k]) then
			p[#p + 1] = k .. " is " .. typeof(r[k])
		end
	end
	if not isStr(r.DifficultyId) or not isStr(r.DifficultyName) then
		p[#p + 1] = "DifficultyId/DifficultyName"
	end
	if type(r.Members) ~= "table" then
		p[#p + 1] = "Members"
	else
		for i, m in ipairs(r.Members) do
			if not (isStr(m.Name) and isNum(m.MatchTokens) and isBool(m.Finished) and isBool(m.Downed)) then
				p[#p + 1] = "Members[" .. i .. "] malformed"
			end
		end
	end
	return p
end

function V.partyState(st)
	local p = {}
	if type(st) ~= "table" then
		return { "payload is " .. type(st) }
	end
	if not isStr(st.PortalId) or not isStr(st.DifficultyName) then
		p[#p + 1] = "PortalId/DifficultyName"
	end
	if typeof(st.Color) ~= "Color3" then
		p[#p + 1] = "Color"
	end
	if not isNum(st.Max) then
		p[#p + 1] = "Max"
	end
	if st.Countdown ~= nil and not isNum(st.Countdown) then
		p[#p + 1] = "Countdown"
	end
	if type(st.Players) ~= "table" then
		p[#p + 1] = "Players"
	else
		for i, m in ipairs(st.Players) do
			if not (isNum(m.UserId) and isStr(m.Name)) then
				p[#p + 1] = "Players[" .. i .. "] malformed"
			end
		end
	end
	return p
end

local NOTIFY_KINDS = { info = true, good = true, bad = true, token = true }
function V.entry(e, Config)
	local a = e.args
	local out = {}
	if e.remote == "MatchState" then
		if a[1] ~= nil then
			out = V.matchState(a[1])
		end
	elseif e.remote == "MatchResult" then
		out = V.matchResult(a[1])
	elseif e.remote == "PartyState" then
		if a[1] ~= nil then
			out = V.partyState(a[1])
		end
	elseif e.remote == "Notify" then
		if not isStr(a[1]) then
			out[#out + 1] = "text is " .. typeof(a[1])
		end
		if not NOTIFY_KINDS[a[2]] then
			out[#out + 1] = "kind " .. tostring(a[2])
		end
		if not isNum(a[3]) then
			out[#out + 1] = "duration is " .. typeof(a[3])
		end
	elseif e.remote == "DamageTaken" then
		if not isNum(a[1]) or a[1] <= 0 then
			out[#out + 1] = "amount " .. tostring(a[1])
		end
		local okKind = false
		for _, k in ipairs(Config.Damage.Kinds) do
			okKind = okKind or k == a[2]
		end
		if not okKind then
			out[#out + 1] = "kind " .. tostring(a[2])
		end
	elseif e.remote == "DashFx" then
		if not isNum(a[1]) then
			out[#out + 1] = "userId is " .. typeof(a[1])
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- more helpers
----------------------------------------------------------------------------------------------------
local function MS()
	return mod("MatchService")
end
local function DS()
	return mod("DamageService")
end

local playerSeq = 0
local function freshPlayers(n, prefix)
	local out = {}
	for i = 1, n do
		playerSeq = playerSeq + 1
		out[i] = joinPlayer((prefix or "P") .. playerSeq, 9000 + playerSeq)
	end
	return out
end

local function removePlayers(list)
	for _, p in ipairs(list) do
		if p.Parent then
			Mock.RemovePlayer(p)
		end
	end
	advance(0.5)
end

-- ends every running match (leaves, never leaks a slot into the next scenario)
local function endAllMatches(players)
	for _, p in ipairs(players or Players:GetPlayers()) do
		if p.Parent and MS().GetMatchOf(p) then
			MS().LeaveMatch(p)
		end
	end
	advance(1)
end

local function remoteFolder()
	return ReplicatedStorage:FindFirstChild("Remotes")
end

local function state(player)
	local e = lastRemote("MatchState", player.UserId)
	return e and e.args[1]
end

local function startMatch(id, players)
	local m = MS().StartMatch(id, players)
	advance(0.2)
	return m
end

local function toPlaying(match)
	return waitFor(function()
		return match.State == "Playing"
	end, config().Match.IntroCountdown + 4)
end

local function distance(a, b)
	return (a - b).Magnitude
end

local function planar(a, b)
	return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
end

local function notified(player, pattern, kind, fromIndex)
	for _, e in ipairs(remotesFor("Notify", player.UserId, fromIndex or 0)) do
		if tostring(e.args[1]):find(pattern) and (kind == nil or e.args[2] == kind) then
			return true
		end
	end
	return false
end

local function logSize()
	return #Mock.RemoteLog
end

local function waitNotInvulnerable(player)
	return waitFor(function()
		return not DS().IsInvulnerable(player)
	end, 12)
end

local function maxHealth(player)
	return hum(player).MaxHealth
end


-- Scenarios after "boot" need the lobby (Main.server.lua must have run). One clear failure instead of a cascade.
local function needBoot()
	if W.lobbyInfo == nil then
		T.fail("skipped: Main.server.lua did not build the lobby (see 'boot' / 'load_modules' above)")
		return false
	end
	return true
end

----------------------------------------------------------------------------------------------------
-- scenario: players join the lobby
----------------------------------------------------------------------------------------------------
S.players = guarded("players", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local info = W.lobbyInfo
	local alice = Mock.AddPlayer("Alice", 101)
	advance(0.6)
	W.alice = alice
	T.eq(alice:GetAttribute("CloudTokens"), 0, "new player starts with CloudTokens = 0")
	T.eq(alice:GetAttribute("MatchTokens"), 0, "MatchTokens = 0")
	T.eq(alice:GetAttribute("InMatch"), false, "InMatch = false")
	T.eq(alice:GetAttribute("Downed"), false, "Downed = false")
	local ls = alice:FindFirstChild("leaderstats")
	T.check(ls ~= nil and ls:FindFirstChild("Tokens") ~= nil and ls.Tokens:IsA("IntValue"), "leaderstats.Tokens IntValue exists")
	local h = hum(alice)
	if T.check(h ~= nil, "Alice has a Humanoid") then
		T.near(h.WalkSpeed, Config.Physics.WalkSpeed, 0.01, "WalkSpeed = Config.Physics.WalkSpeed")
		T.near(h.JumpPower, Config.Physics.JumpPower, 0.01, "JumpPower = Config.Physics.JumpPower")
		T.eq(h.UseJumpPower, true, "UseJumpPower is enabled")
		T.near(h.MaxHealth, Config.Physics.MaxHealth, 0.01, "MaxHealth = Config.Physics.MaxHealth")
		T.near(h.Health, h.MaxHealth, 0.01, "spawns with full health")
	end
	local r = root(alice)
	if T.check(r ~= nil, "Alice has a HumanoidRootPart") and info then
		local d = planar(r.Position, info.SpawnCFrame.Position)
		T.check(d <= 10, "spawns scattered around the lobby spawn", "horizontal distance " .. fmt(d))
		T.check(math.abs(r.Position.Y - info.SpawnCFrame.Position.Y) <= 6, "spawns at plaza height", "dy " .. fmt(r.Position.Y - info.SpawnCFrame.Position.Y))
	end
	T.eq(alice.Character:FindFirstChild("Health"), nil, "the default regen 'Health' script is removed from the character")
	-- spawn protection
	local fresh = Mock.AddPlayer("Fresh", 102)
	advance(0.3)
	T.check(DS().IsInvulnerable(fresh), "a fresh spawn has i-frames (DamageService.GrantInvulnerability)")
	Mock.RemovePlayer(fresh)
	advance(0.2)
	-- the lobby is safe
	T.eq(DS().Damage(alice, 25, "Other"), false, "DamageService.Damage returns false in the lobby")
	T.near(hum(alice).Health, hum(alice).MaxHealth, 0.01, "no damage taken in the lobby")
	hum(alice).Health = 40
	advance(1.2)
	T.near(hum(alice).Health, hum(alice).MaxHealth, 0.01, "the lobby restores health to full")
	-- falling off the cloud village
	Mock.Teleport(alice, Vector3.new(0, Config.Lobby.KillY - 80, 0))
	advance(1.2)
	T.check(root(alice).Position.Y > Config.Lobby.KillY, "falling below Lobby.KillY returns the player to the plaza", "y=" .. fmt(root(alice).Position.Y))
	T.near(hum(alice).Health, hum(alice).MaxHealth, 0.01, "the lobby fall costs no health")
	-- tokens + leaderstats
	local DataService = mod("DataService")
	DataService.AddTokens(alice, 5)
	advance(0.2)
	T.eq(alice:GetAttribute("CloudTokens"), 5, "DataService.AddTokens updates the CloudTokens attribute")
	T.eq(ls.Tokens.Value, 5, "leaderstats.Tokens mirrors CloudTokens")
	T.eq(DataService.GetTokens(alice), 5, "DataService.GetTokens")
	-- a character reset in the lobby respawns in the lobby
	Mock.Kill(alice)
	T.check(waitFor(function()
		return alice.Character ~= nil and hum(alice) ~= nil and hum(alice).Health > 0
	end, Config.Match and 12 or 12), "a reset character respawns")
	advance(0.8)
	local SpotService = mod("SpotService")
	local spot = SpotService and SpotService.GetSpot(alice)
	if T.check(spot ~= nil, "Alice owns a lobby spot (assigned after her profile loaded)") then
		T.check(root(alice) ~= nil and planar(root(alice).Position, spot.SpawnCFrame.Position) <= 10, "a lobby respawn lands at the owner's own spot", root(alice) and fmt(planar(root(alice).Position, spot.SpawnCFrame.Position)))
	else
		T.check(root(alice) ~= nil and planar(root(alice).Position, info.SpawnCFrame.Position) <= 10, "the respawn lands in the lobby")
	end
	T.near(hum(alice).MaxHealth, Config.Physics.MaxHealth, 0.01, "respawned character gets the Config stats again")
	flushErrors("players")
	flushWarnings("players")
end)

----------------------------------------------------------------------------------------------------
-- scenario: portals + parties
----------------------------------------------------------------------------------------------------
local function enterPortal(player, id)
	local zone = W.lobbyInfo.Portals[id].Zone
	Mock.Teleport(player, CFrame.new(zone.Position + Vector3.new(0, 0, 0)))
end

local function leavePortalArea(player)
	Mock.Teleport(player, W.lobbyInfo.SpawnCFrame)
end

S.portals = guarded("portals", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local PortalService = mod("PortalService")
	local alice = W.alice
	if not alice or not alice.Parent then
		alice = freshPlayers(1, "Alice")[1]
	end
	leavePortalArea(alice)
	advance(0.6)
	-- every one of the five gates forms its own party (no hard-coded ids in PortalService)
	for _, diff in ipairs(Config.Difficulties) do
		local mark0 = logSize()
		enterPortal(alice, diff.Id)
		advance(1.3)
		for _, other in ipairs(Config.Difficulties) do
			local expect = (other.Id == diff.Id) and 1 or 0
			T.eq(#PortalService.GetParty(other.Id).Players, expect, diff.Id .. ": standing in the " .. diff.Id .. " gate fills only that party (" .. other.Id .. ")")
		end
		local entries0 = remotesFor("PartyState", alice.UserId, mark0)
		local last0 = entries0[#entries0]
		if T.check(last0 ~= nil and last0.args[1] ~= nil, diff.Id .. ": the member receives PartyState") then
			local st0 = last0.args[1]
			T.eq(st0.PortalId, diff.Id, diff.Id .. ": PartyState.PortalId")
			T.eq(st0.DifficultyName, diff.DisplayName, diff.Id .. ": PartyState.DifficultyName")
			T.check(st0.Color == diff.Color, diff.Id .. ": PartyState.Color is the difficulty colour")
		end
		T.check(tostring(W.lobbyInfo.Portals[diff.Id].CountLabel.Text):find("1") ~= nil, diff.Id .. ": its CountLabel shows 1 player", W.lobbyInfo.Portals[diff.Id].CountLabel.Text)
		leavePortalArea(alice)
		advance(0.8)
		T.eq(#PortalService.GetParty(diff.Id).Players, 0, diff.Id .. ": leaving empties the party")
	end
	local info = W.lobbyInfo.Portals.Medium
	-- stepping onto the pad joins the party
	local mark = logSize()
	enterPortal(alice, "Medium")
	advance(0.6)
	local party = PortalService.GetParty("Medium")
	T.check(#party.Players == 1 and party.Players[1] == alice, "standing in the zone joins the portal party")
	T.check(type(party.Countdown) == "number" and party.Countdown > 0 and party.Countdown <= Config.Match.PartyCountdown, "the party countdown starts at PartyCountdown", tostring(party.Countdown))
	T.check(tostring(info.CountLabel.Text):find("1") and tostring(info.CountLabel.Text):find(tostring(Config.Match.MaxPlayers)), "CountLabel shows 1 / " .. Config.Match.MaxPlayers, info.CountLabel.Text)
	T.check(tostring(info.StatusLabel.Text):lower():find("start") ~= nil, "StatusLabel shows the countdown", info.StatusLabel.Text)
	local others = PortalService.GetParty("Easy")
	T.eq(#others.Players, 0, "other portals stay empty")
	advance(1.2)
	local entries = remotesFor("PartyState", alice.UserId, mark)
	T.check(#entries >= 2, "PartyState is sent to the member (every second)", #entries .. " messages")
	local last = entries[#entries]
	if last and last.args[1] then
		local problems = V.partyState(last.args[1])
		T.check(#problems == 0, "PartyState payload matches ARCHITECTURE.md", table.concat(problems, ", "))
		T.eq(last.args[1].PortalId, "Medium", "PartyState.PortalId")
		T.eq(last.args[1].Max, Config.Match.MaxPlayers, "PartyState.Max")
		T.check(#last.args[1].Players == 1 and last.args[1].Players[1].UserId == alice.UserId, "PartyState lists the member")
	end
	-- walking out leaves the party
	mark = logSize()
	leavePortalArea(alice)
	advance(0.8)
	T.eq(#PortalService.GetParty("Medium").Players, 0, "walking out of the zone leaves the party")
	local gone = remotesFor("PartyState", alice.UserId, mark)
	T.check(#gone >= 1 and gone[#gone].args[1] == nil and gone[#gone].args.n >= 1, "PartyState(nil) is sent when leaving")
	T.check(tostring(info.CountLabel.Text):find("0") ~= nil, "CountLabel back to 0 players", info.CountLabel.Text)
	-- the Leave button: removed + lockout + moved off the pad
	enterPortal(alice, "Medium")
	advance(0.6)
	T.eq(#PortalService.GetParty("Medium").Players, 1, "re-entering joins again")
	Mock.FromClient(remoteFolder().LeaveParty, alice)
	advance(0.3)
	T.eq(#PortalService.GetParty("Medium").Players, 0, "LeaveParty removes the player from the party")
	local d = planar(root(alice).Position, W.lobbyInfo.Portals.Medium.Center)
	T.check(d >= 8, "LeaveParty moves the player ~12 studs away from the portal", "distance " .. fmt(d))
	enterPortal(alice, "Medium")
	advance(1.0)
	T.eq(#PortalService.GetParty("Medium").Players, 0, "the 3 s re-join lockout is respected")
	leavePortalArea(alice)
	advance(3)
	enterPortal(alice, "Medium")
	advance(0.8)
	T.eq(#PortalService.GetParty("Medium").Players, 1, "after the lockout the player can join again")
	PortalService.RemovePlayer(alice)
	T.eq(#PortalService.GetParty("Medium").Players, 0, "PortalService.RemovePlayer")
	leavePortalArea(alice)
	advance(0.6)
	-- a full party: shortened countdown + 5th player is told it is full
	local four = freshPlayers(Config.Match.MaxPlayers, "Climber")
	for _, p in ipairs(four) do
		enterPortal(p, "Saint")
		advance(0.3)
	end
	advance(0.5)
	local tp = PortalService.GetParty("Saint")
	T.eq(#tp.Players, Config.Match.MaxPlayers, "a party holds MaxPlayers")
	T.check(tp.Countdown ~= nil and tp.Countdown <= Config.Match.FullPartyCountdown + 1, "a full party uses the short countdown", tostring(tp.Countdown))
	T.check(tostring(W.lobbyInfo.Portals.Saint.StatusLabel.Text):lower():find("full") ~= nil, "StatusLabel says the party is full", W.lobbyInfo.Portals.Saint.StatusLabel.Text)
	local fifth = freshPlayers(1, "Late")[1]
	mark = logSize()
	enterPortal(fifth, "Saint")
	advance(0.8)
	T.eq(#PortalService.GetParty("Saint").Players, Config.Match.MaxPlayers, "a 5th player cannot join a full party")
	T.check(notified(fifth, "full", "bad", mark), "the 5th player gets a 'Party is full' toast")
	-- the party launches a match
	local started = waitFor(function()
		return MS().GetMatchOf(four[1]) ~= nil
	end, Config.Match.FullPartyCountdown + 6)
	T.check(started, "the party launches a match when the countdown ends")
	if started then
		local m = MS().GetMatchOf(four[1])
		T.eq(m.DifficultyId, "Saint", "the match uses the portal's difficulty")
		T.eq(#m.Players, Config.Match.MaxPlayers, "all four party members are in the match")
		T.eq(#PortalService.GetParty("Saint").Players, 0, "the party is cleared after launch")
		T.check(m.Slot == 1, "first match uses slot 1", tostring(m.Slot))
		for _, p in ipairs(four) do
			T.eq(p:GetAttribute("InMatch"), true, p.Name .. ": InMatch = true after launch")
		end
	end
	endAllMatches(four)
	removePlayers(four)
	removePlayers({ fifth })
	flushErrors("portals")
	flushWarnings("portals")
end)

----------------------------------------------------------------------------------------------------
-- scenario: damage / downed / revive / checkpoint / void / tokens inside a running match
----------------------------------------------------------------------------------------------------
local function transparencyOf(player)
	local head = player.Character and player.Character:FindFirstChild("Head")
	return head and head.Transparency or -1
end

-- Returns a token with no neighbour closer than ~7 studs (so a single teleport collects exactly one), and all tokens.
local function firstToken(match)
	local Config = config()
	local list = tagged(Config.Tags.CloudToken, match.Course.Folder)
	table.sort(list, function(a, b)
		return a.Position.Z < b.Position.Z
	end)
	local best, bestGap = list[1], -1
	for _, t in ipairs(list) do
		local gap = huge
		for _, o in ipairs(list) do
			if o ~= t then
				gap = math.min(gap, (o.Position - t.Position).Magnitude)
			end
		end
		if gap >= 7 then
			return t, list
		end
		if gap > bestGap then
			best, bestGap = t, gap
		end
	end
	return best, list
end

S.damage_rules = guarded("damage_rules", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local players = freshPlayers(2, "Dmg")
	local a, b = players[1], players[2]
	local m = startMatch("Easy", players)
	if not T.check(m ~= nil, "MatchService.StartMatch('Easy', {a, b}) returns a match") then
		removePlayers(players)
		return
	end
	W.matches = W.matches + 1
	-- fields of the match object (ARCHITECTURE.md)
	T.check(type(m.Id) == "number" and m.DifficultyId == "Easy" and type(m.Slot) == "number" and type(m.Players) == "table" and type(m.Checkpoint) == "number" and type(m.State) == "string" and type(m.Course) == "table", "match has Id / DifficultyId / Slot / Players / State / Course / Checkpoint")
	T.eq(MS().GetMatchOf(a), m, "GetMatchOf returns the match for a member")
	T.eq(MS().GetMatchOf(Mock.AddPlayer("Outsider", 5555)), nil, "GetMatchOf is nil for a lobby player")
	advance(0.3)
	-- intro
	T.eq(a:GetAttribute("InMatch"), true, "InMatch is true in a match")
	T.eq(a:GetAttribute("MatchTokens"), 0, "MatchTokens reset to 0")
	T.check(distance(root(a).Position, m.Course.StartCFrame.Position) <= 12, "players start on the start platform", fmt(distance(root(a).Position, m.Course.StartCFrame.Position)))
	T.check(hum(a).WalkSpeed == 0 or root(a).Anchored, "players are frozen during the intro countdown")
	local ms = state(a)
	T.check(ms ~= nil and ms.Phase == "Countdown", "MatchState Phase = Countdown during the intro", ms and ms.Phase)
	T.check(DS().IsInvulnerable(a), "players are protected during the intro")
	T.check(toPlaying(m), "the match reaches Playing after IntroCountdown")
	advance(0.3)
	T.check(hum(a).WalkSpeed == Config.Physics.WalkSpeed and not root(a).Anchored, "players are unfrozen when play starts", "WalkSpeed " .. tostring(hum(a).WalkSpeed))
	ms = state(a)
	T.check(ms ~= nil and ms.Phase == "Playing", "MatchState Phase = Playing", ms and ms.Phase)
	if ms then
		local problems = V.matchState(ms)
		T.check(#problems == 0, "MatchState payload matches ARCHITECTURE.md", table.concat(problems, ", "))
		T.eq(ms.TotalCheckpoints, Config.GetDifficulty("Easy").Stages, "MatchState.TotalCheckpoints = Stages")
		T.eq(ms.TotalTokens, m.Course.TotalTokens, "MatchState.TotalTokens = course tokens")
		T.eq(#ms.Members, 2, "MatchState lists both members")
		T.check(ms.Seconds > 0 and ms.Seconds <= Config.GetDifficulty("Easy").TimeLimit, "MatchState.Seconds is the time left", tostring(ms.Seconds))
	end
	-- broadcast rate ~2 Hz
	local mark = logSize()
	advance(2.05)
	local n = #remotesFor("MatchState", a.UserId, mark)
	T.check(n >= 3 and n <= 6, "MatchState is broadcast at ~2 Hz while playing", n .. " messages in 2 s")

	-- tokens
	local token, allTokens = firstToken(m)
	if T.check(token ~= nil, "the course contains cloud tokens") then
		local value = token:GetAttribute("Value") or 1
		mark = logSize()
		local cloudBefore = a:GetAttribute("CloudTokens")
		Mock.Teleport(a, token.Position)
		advance(1.0)
		T.check(token.Parent == nil, "a touched token is destroyed")
		T.eq(a:GetAttribute("MatchTokens"), value, "MatchTokens increases by the token Value")
		T.eq(a:GetAttribute("CloudTokens"), cloudBefore + value, "CloudTokens (lifetime) increases as well")
		T.check(notified(a, "^%+%d+ cloud token", "token", mark), "a '+n cloud token(s)' toast is sent (pickups within 0.6 s share one toast)")
		T.eq(b:GetAttribute("MatchTokens"), 0, "the other player's MatchTokens is unchanged")
		advance(0.6)
		ms = state(a)
		T.check(ms and ms.TokensCollected == value, "MatchState.TokensCollected counts team tokens", ms and ms.TokensCollected)
		-- a token can only be collected once, even if touched again
		Mock.Teleport(a, token.Position)
		advance(0.3)
		T.eq(a:GetAttribute("MatchTokens"), value, "a token is never collected twice")
	end
	-- moving a downed/absent toucher does not collect tokens
	Mock.Teleport(a, m.Course.StartCFrame)
	advance(0.4)

	-- damage rules
	T.check(waitNotInvulnerable(a), "spawn protection expires")
	waitNotInvulnerable(b)
	mark = logSize()
	T.eq(DS().Damage(a, 30, "SpinBar", { KnockbackFrom = root(a).Position + Vector3.new(3, 0, 0), Knockback = 55 }), true, "Damage(30, 'SpinBar') applies")
	T.near(hum(a).Health, 70, 0.01, "health drops by the damage amount")
	local dmgMsg = remotesFor("DamageTaken", a.UserId, mark)[1]
	T.check(dmgMsg ~= nil and dmgMsg.args[1] == 30 and dmgMsg.args[2] == "SpinBar", "DamageTaken(30, 'SpinBar') is sent to the victim only", dmgMsg and (tostring(dmgMsg.args[1]) .. "," .. tostring(dmgMsg.args[2])))
	T.eq(#remotesFor("DamageTaken", b.UserId, mark), 0, "teammates do not receive DamageTaken")
	T.check(DS().IsInvulnerable(a), "a hit starts the i-frame window")
	T.eq(DS().Damage(a, 10, "Other"), false, "a second hit inside the i-frames is ignored")
	T.eq(DS().Damage(a, 5, "Storm", { IgnoreIFrames = true }), true, "IgnoreIFrames bypasses the hit window")
	T.near(hum(a).Health, 65, 0.01, "IgnoreIFrames damage applied")
	advance(Config.Damage.IFrames + 0.2)
	T.eq(DS().Damage(a, 10, "Lightning"), true, "damage works again after IFrames")
	T.eq(DS().Damage(a, -10, "Other"), false, "negative damage is rejected")
	T.eq(DS().Damage(a, 0, "Other"), false, "zero damage is rejected")
	T.eq(DS().Damage(a, 0 / 0, "Other"), false, "NaN damage is rejected")
	local kn = root(a).AssemblyLinearVelocity
	T.check(type(kn.Magnitude) == "number", "knockback keeps the velocity valid")
	-- healing
	hum(a).Health = hum(a).Health -- no-op
	local healed = DS().Heal(a, 20)
	T.near(healed, 20, 0.01, "Heal returns the amount healed")
	T.near(hum(a).Health, 75, 0.01, "Heal raises health")
	T.near(DS().Heal(a, 1000), 25, 0.01, "Heal never exceeds MaxHealth and returns the real amount")
	T.near(DS().Heal(a, 5), 0, 0.001, "Heal at full health heals 0")
	DS().SetHealthFraction(a, 0.5)
	T.near(hum(a).Health, 50, 0.5, "SetHealthFraction(0.5)")
	DS().HealFraction(a, 0.1)
	T.near(hum(a).Health, 60, 0.5, "HealFraction(0.1) heals 10% of max")

	-- downed
	local downedEvents = {}
	local conn = DS().PlayerDowned:Connect(function(p, kind)
		downedEvents[#downedEvents + 1] = { p, kind }
	end)
	DS().SetHealthFraction(b, 0.4)
	advance(Config.Damage.IFrames + 0.1)
	mark = logSize()
	T.eq(DS().Damage(b, 500, "Void", { IgnoreIFrames = true }), true, "a lethal hit succeeds")
	advance(0.3)
	conn:Disconnect()
	T.eq(b:GetAttribute("Downed"), true, "a lethal hit sets the Downed attribute")
	T.check(hum(b).Health >= 1 - 1e-6 and hum(b).Health <= Config.Damage.DownedHealth + 1e-6, "health is pinned at DownedHealth (never 0)", tostring(hum(b).Health))
	T.eq(hum(b).WalkSpeed, 0, "downed: WalkSpeed = 0")
	T.eq(hum(b).JumpPower, 0, "downed: JumpPower = 0")
	T.eq(DS().IsDowned(b), true, "IsDowned")
	T.check(transparencyOf(b) >= 0.5, "downed players are semi-transparent", tostring(transparencyOf(b)))
	T.check(#downedEvents == 1 and downedEvents[1][1] == b and downedEvents[1][2] == "Void", "PlayerDowned fires (player, kind)", #downedEvents .. " events")
	T.eq(DS().Damage(b, 10, "Other", { IgnoreIFrames = true }), false, "downed players ignore damage")
	T.near(DS().Heal(b, 50), 0, 0.001, "Heal does not lift a downed player")
	advance(3)
	T.check(hum(b).Health <= Config.Damage.DownedHealth + 1e-6, "a downed player stays pinned (no regen)", tostring(hum(b).Health))
	T.check(Mock.PendingTasks() >= 0, "scheduler alive")
	ms = state(a)
	local bm
	for _, mem in ipairs(ms and ms.Members or {}) do
		if mem.UserId == b.UserId then
			bm = mem
		end
	end
	T.check(bm ~= nil and bm.Downed == true, "MatchState marks the downed member")
	T.check(notified(a, "down", "bad", mark), "teammates are told that someone is down")
	-- alive teammate may still play: the match goes on
	T.eq(m.State, "Playing", "the match continues while one player is still up")

	-- checkpoint: heal + revive + notify
	local cp1 = m.Course.Checkpoints[1]
	T.check(cp1 ~= nil and cp1.Part ~= nil, "Course.Checkpoints[1] exists")
	DS().SetHealthFraction(a, 0.4)
	mark = logSize()
	Mock.Teleport(a, cp1.Part.Position + Vector3.new(0, 3.5, 0))
	advance(0.8)
	T.eq(m.Checkpoint, 1, "touching checkpoint 1 sets match.Checkpoint")
	T.check(notified(a, "Checkpoint 1/" .. Config.GetDifficulty("Easy").Stages .. " reached", "good", mark), "'Checkpoint 1/N reached!' toast (good)")
	T.near(hum(a).Health, 40 + 100 * Config.Damage.CheckpointHealFraction, 2, "alive members heal CheckpointHealFraction at a checkpoint")
	T.eq(b:GetAttribute("Downed"), false, "the downed teammate is revived at the checkpoint")
	T.near(hum(b).Health, 100 * Config.Damage.ReviveHealthFraction, 3, "revived players return with ReviveHealthFraction health")
	T.eq(hum(b).WalkSpeed, Config.Physics.WalkSpeed, "revived: WalkSpeed restored")
	T.eq(hum(b).JumpPower, Config.Physics.JumpPower, "revived: JumpPower restored")
	T.near(transparencyOf(b), 0, 0.01, "revived: transparency restored")
	T.check(distance(root(b).Position, cp1.SpawnCFrame.Position) <= 14, "revived players are moved to the checkpoint", fmt(distance(root(b).Position, cp1.SpawnCFrame.Position)))
	T.check(DS().IsInvulnerable(b), "revive grants i-frames")
	T.eq(DS().IsDowned(b), false, "IsDowned is false after the revive")
	-- reaching an older checkpoint again changes nothing
	local before = logSize()
	Mock.Teleport(a, cp1.Part.Position + Vector3.new(0, 3.5, 0))
	advance(0.6)
	T.eq(m.Checkpoint, 1, "re-touching a checkpoint does not move it")
	T.eq(#remotesFor("Notify", a.UserId, before) >= 0, true, "no crash on re-touch")

	-- void
	waitNotInvulnerable(b)
	waitNotInvulnerable(a)
	local hpBefore = hum(b).Health
	mark = logSize()
	local voidDamage = Config.Damage.VoidDamage.Easy
	Mock.Teleport(b, Vector3.new(m.Course.StartCFrame.Position.X, m.Course.KillY - 30, m.Course.StartCFrame.Position.Z + 40))
	advance(1.2)
	T.check(root(b).Position.Y > m.Course.KillY + 5, "falling below KillY teleports the player back", "y=" .. fmt(root(b).Position.Y) .. " killY=" .. fmt(m.Course.KillY))
	T.check(distance(root(b).Position, cp1.SpawnCFrame.Position) <= 14, "...to the team checkpoint", fmt(distance(root(b).Position, cp1.SpawnCFrame.Position)))
	local vd = remotesFor("DamageTaken", b.UserId, mark)[1]
	T.check(vd ~= nil and vd.args[2] == "Void" and vd.args[1] == voidDamage, "the void deals VoidDamage[" .. "Easy" .. "] as 'Void'", vd and (tostring(vd.args[1]) .. " " .. tostring(vd.args[2])))
	T.near(hum(b).Health, hpBefore - voidDamage, 1.5, "void damage is applied to health")
	-- cleanup
	endAllMatches(players)
	T.check(MS().GetMatchOf(a) == nil, "LeaveMatch removes the player from the match")
	T.eq(a:GetAttribute("InMatch"), false, "InMatch = false after leaving")
	removePlayers(players)
	flushErrors("damage_rules")
	flushWarnings("damage_rules")
end)

----------------------------------------------------------------------------------------------------
-- scenario: victory
----------------------------------------------------------------------------------------------------
local function lobbyCheck(player, label)
	local Config = config()
	T.eq(player:GetAttribute("InMatch"), false, label .. ": InMatch = false after the match")
	T.eq(player:GetAttribute("Downed"), false, label .. ": Downed = false after the match")
	T.eq(player:GetAttribute("MatchTokens"), 0, label .. ": MatchTokens reset after the match")
	local r, h = root(player), hum(player)
	if r and h then
		local d = distance(r.Position, W.lobbyInfo.SpawnCFrame.Position)
		T.check(d <= 25, label .. ": back on the lobby plaza", "distance " .. fmt(d))
		T.near(h.Health, h.MaxHealth, 0.5, label .. ": healed to full")
		T.eq(h.WalkSpeed, Config.Physics.WalkSpeed, label .. ": WalkSpeed restored")
		T.check(not r.Anchored, label .. ": root is not left anchored")
	else
		T.fail(label .. ": has a living character in the lobby")
	end
end

S.match_victory = guarded("match_victory", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local players = freshPlayers(2, "Win")
	local a, b = players[1], players[2]
	-- start through the portal, like a real game
	for _, p in ipairs(players) do
		enterPortal(p, "Easy")
		advance(0.3)
	end
	local started = waitFor(function()
		return MS().GetMatchOf(a) ~= nil
	end, Config.Match.PartyCountdown + 6)
	if not T.check(started, "an Easy party launches via the portal") then
		removePlayers(players)
		return
	end
	local m = MS().GetMatchOf(a)
	local ended = {}
	local conn = MS().MatchEnded:Connect(function(match, won)
		ended[#ended + 1] = { match, won }
	end)
	-- the intro: countdown seconds go down
	local seconds = {}
	local lastSeen
	local deadline = Mock.Clock.now + Config.Match.IntroCountdown + 3
	while m.State ~= "Playing" and Mock.Clock.now < deadline do
		advance(0.25)
		local st = state(a)
		if st and st.Phase == "Countdown" and st.Seconds ~= lastSeen then
			lastSeen = st.Seconds
			seconds[#seconds + 1] = st.Seconds
		end
	end
	T.check(#seconds >= 3, "the intro broadcasts a countdown", table.concat(seconds, ","))
	local descending = true
	for i = 2, #seconds do
		if seconds[i] >= seconds[i - 1] then
			descending = false
		end
	end
	T.check(descending, "countdown seconds count down", table.concat(seconds, ","))
	T.check(seconds[1] ~= nil and seconds[1] <= Config.Match.IntroCountdown, "countdown starts at IntroCountdown", tostring(seconds[1]))
	T.eq(m.State, "Playing", "the match reaches Playing")
	advance(0.5)
	local tokenA = 0
	-- collect a couple of tokens with each player, then run through the stages
	local _, tokens = firstToken(m)
	for i = 1, math.min(3, #tokens) do
		Mock.Teleport(a, tokens[i].Position)
		advance(0.5)
	end
	local want = a:GetAttribute("MatchTokens")
	T.check(want >= 1, "tokens were collected on the way", tostring(want))
	-- walk through every checkpoint in order
	for i = 1, Config.GetDifficulty("Easy").Stages do
		local cp = m.Course.Checkpoints[i]
		Mock.Teleport(b, cp.Part.Position + Vector3.new(0, 3.5, 0))
		Mock.Teleport(a, cp.Part.Position + Vector3.new(0, 3.5, 0))
		advance(0.6)
		T.eq(m.Checkpoint, i, "checkpoint " .. i .. " is reached in order")
	end
	-- only one player finishes: the match keeps going
	local fin = m.Course.Finish
	local mark = logSize()
	Mock.Teleport(a, fin.Position + Vector3.new(0, fin.Size.Y / 2 + 3.5, 0))
	advance(1.0)
	T.eq(m.State, "Playing", "victory needs ALL alive players at the finish")
	local st = state(b)
	local fm
	for _, mem in ipairs(st and st.Members or {}) do
		if mem.UserId == a.UserId then
			fm = mem
		end
	end
	T.check(fm ~= nil and fm.Finished == true, "the first finisher is marked Finished in MatchState")
	T.check(root(a).Anchored or hum(a).WalkSpeed == 0, "a finished player is frozen on the pad")
	T.check(DS().IsInvulnerable(a), "a finished player is invulnerable")
	local lifetimeBefore = {
		a = a:GetAttribute("CloudTokens"),
		b = b:GetAttribute("CloudTokens"),
	}
	mark = logSize()
	Mock.Teleport(b, fin.Position + Vector3.new(0, fin.Size.Y / 2 + 3.5, 0))
	advance(1.0)
	T.check(m.State == "Ended" or ended[1] ~= nil, "the match ends when every alive player has finished", m.State)
	-- result
	local res = lastRemote("MatchResult", a.UserId, mark)
	if T.check(res ~= nil, "MatchResult is sent to each member") then
		local r = res.args[1]
		local problems = V.matchResult(r)
		T.check(#problems == 0, "MatchResult payload matches ARCHITECTURE.md", table.concat(problems, ", "))
		T.eq(r.Won, true, "MatchResult.Won")
		T.eq(r.Reason, "victory", "MatchResult.Reason = victory")
		T.eq(r.Bonus, Config.Match.TokenBonusOnWin.Easy, "MatchResult.Bonus = TokenBonusOnWin")
		T.eq(r.DifficultyId, "Easy", "MatchResult.DifficultyId")
		T.eq(r.DifficultyName, Config.GetDifficulty("Easy").DisplayName, "MatchResult.DifficultyName")
		T.eq(r.TotalTokens, m.Course.TotalTokens, "MatchResult.TotalTokens")
		T.eq(r.MatchTokens, want, "MatchResult.MatchTokens is the player's own count")
		T.eq(#r.Members, 2, "MatchResult.Members lists both players")
		T.check(r.Seconds > 0, "MatchResult.Seconds is the play time", tostring(r.Seconds))
	end
	T.check(lastRemote("MatchResult", b.UserId, mark) ~= nil, "the second member also receives MatchResult")
	T.eq(a:GetAttribute("CloudTokens"), lifetimeBefore.a + Config.Match.TokenBonusOnWin.Easy, "the win bonus is added to the lifetime tokens")
	T.eq(b:GetAttribute("CloudTokens"), lifetimeBefore.b + Config.Match.TokenBonusOnWin.Easy, "...for every finished player")
	local endState = state(a)
	T.check(endState ~= nil and endState.Phase == "Ended", "MatchState Phase = Ended on the results screen", endState and endState.Phase)
	-- back to the lobby
	advance(Config.Match.EndScreenSeconds + 1.5)
	T.eq(MS().GetMatchOf(a), nil, "the match is gone after EndScreenSeconds")
	local mstate = lastRemote("MatchState", a.UserId)
	T.check(mstate ~= nil and mstate.args[1] == nil and mstate.args.n >= 1, "MatchState(nil) is sent when the match is over")
	lobbyCheck(a, "winner A")
	lobbyCheck(b, "winner B")
	T.check(#courseFolders() == 0, "the course folder is destroyed", #courseFolders() .. " Course_* folders left")
	T.check(#ended == 1 and ended[1][2] == true, "MatchEnded fires once with won = true", #ended .. " events")
	conn:Disconnect()
	-- the slot is free again
	local again = startMatch("Easy", { a })
	T.check(again ~= nil and again.Slot == m.Slot, "the slot is reused for the next match", again and tostring(again.Slot))
	endAllMatches({ a })
	removePlayers(players)
	flushErrors("match_victory")
	flushWarnings("match_victory")
end)

----------------------------------------------------------------------------------------------------
-- scenario: defeat (everybody downed)
----------------------------------------------------------------------------------------------------
S.match_defeat = guarded("match_defeat", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local players = freshPlayers(2, "Lose")
	local a, b = players[1], players[2]
	local m = startMatch("Easy", players)
	if not T.check(m ~= nil, "defeat: match starts") then
		removePlayers(players)
		return
	end
	local ended = {}
	local conn = MS().MatchEnded:Connect(function(match, won)
		ended[#ended + 1] = { match, won }
	end)
	toPlaying(m)
	waitNotInvulnerable(a)
	waitNotInvulnerable(b)
	T.eq(DS().Damage(a, 999, "Lightning", { IgnoreIFrames = true }), true, "player A goes down")
	advance(1.0)
	T.eq(m.State, "Playing", "one player down: the team plays on")
	local mark = logSize()
	T.eq(DS().Damage(b, 999, "Storm", { IgnoreIFrames = true }), true, "player B goes down")
	advance(1.0)
	T.check(m.State == "Ended", "everybody downed: the match is over", m.State)
	local res = lastRemote("MatchResult", a.UserId, mark)
	if T.check(res ~= nil, "defeat: MatchResult is sent") then
		local r = res.args[1]
		T.eq(r.Won, false, "defeat: Won = false")
		T.eq(r.Reason, "defeat", "defeat: Reason = defeat")
		T.eq(r.Bonus, 0, "defeat: no bonus")
		local problems = V.matchResult(r)
		T.check(#problems == 0, "defeat: payload matches ARCHITECTURE.md", table.concat(problems, ", "))
		local downed = 0
		for _, mem in ipairs(r.Members) do
			if mem.Downed then
				downed = downed + 1
			end
		end
		T.eq(downed, 2, "defeat: Members are reported Downed")
	end
	local lifetime = a:GetAttribute("CloudTokens")
	advance(Config.Match.EndScreenSeconds + 1.5)
	T.eq(MS().GetMatchOf(a), nil, "defeat: match removed after the results screen")
	lobbyCheck(a, "loser A")
	lobbyCheck(b, "loser B")
	T.eq(a:GetAttribute("CloudTokens"), lifetime, "defeat: no win bonus is paid")
	T.eq(DS().IsDowned(a), false, "defeat: nobody stays downed in the lobby")
	T.check(transparencyOf(a) <= 0.01, "defeat: character is opaque again", tostring(transparencyOf(a)))
	T.check(#courseFolders() == 0, "defeat: course destroyed")
	T.check(#ended == 1 and ended[1][2] == false, "MatchEnded fires with won = false")
	conn:Disconnect()
	removePlayers(players)
	flushErrors("match_defeat")
	flushWarnings("match_defeat")
end)

----------------------------------------------------------------------------------------------------
-- scenario: time limit
----------------------------------------------------------------------------------------------------
S.match_timeout = guarded("match_timeout", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local diff = Config.GetDifficulty("Easy")
	local players = freshPlayers(1, "Slow")
	local a = players[1]
	local original = diff.TimeLimit
	local limit = ARGS.quick and 45 or original
	diff.TimeLimit = limit
	local m = startMatch("Easy", players)
	if not T.check(m ~= nil, "timeout: match starts") then
		diff.TimeLimit = original
		removePlayers(players)
		return
	end
	toPlaying(m)
	advance(2)
	local st = state(a)
	T.check(st ~= nil and st.Seconds > 0 and st.Seconds <= limit and st.Seconds >= limit - 6, "the timer counts down from TimeLimit", st and tostring(st.Seconds))
	local mark = logSize()
	local saved = Mock.Options.StepSize
	Mock.Options.StepSize = 0.2
	local reached = waitFor(function()
		return m.State == "Ended"
	end, limit + 10)
	Mock.Options.StepSize = saved
	diff.TimeLimit = original
	T.check(reached, "the match ends when the time limit expires", m.State)
	local res = lastRemote("MatchResult", a.UserId, mark)
	if T.check(res ~= nil, "timeout: MatchResult sent") then
		local r = res.args[1]
		T.eq(r.Reason, "timeout", "timeout: Reason = timeout")
		T.eq(r.Won, false, "timeout: Won = false")
		T.eq(r.Bonus, 0, "timeout: no bonus")
	end
	advance(Config.Match.EndScreenSeconds + 1.5)
	T.eq(MS().GetMatchOf(a), nil, "timeout: match removed")
	lobbyCheck(a, "timeout player")
	T.check(#courseFolders() == 0, "timeout: course destroyed")
	removePlayers(players)
	flushErrors("match_timeout")
	flushWarnings("match_timeout")
end)

----------------------------------------------------------------------------------------------------
-- scenario: everybody leaves the game (abandoned)
----------------------------------------------------------------------------------------------------
S.match_abandon = guarded("match_abandon", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local players = freshPlayers(2, "Ghost")
	local a, b = players[1], players[2]
	local m = startMatch("Medium", players)
	if not T.check(m ~= nil, "abandon: Medium match starts") then
		removePlayers(players)
		return
	end
	local ended = {}
	local conn = MS().MatchEnded:Connect(function(match, won)
		ended[#ended + 1] = { match, won }
	end)
	toPlaying(m)
	advance(1)
	local slot = m.Slot
	local mark = logSize()
	Mock.RemovePlayer(a)
	advance(0.6)
	T.eq(m.State, "Playing", "one player leaving does not end the match")
	T.eq(#m.Players, 1, "the leaver is dropped from match.Players")
	Mock.RemovePlayer(b)
	advance(1.5)
	T.check(#courseFolders() == 0, "everybody gone: the course is destroyed", #courseFolders() .. " folders left")
	T.check(#ended == 1 and ended[1][2] == false, "everybody gone: MatchEnded(false) fires", #ended .. " events")
	T.eq(MS().GetMatchOf(a), nil, "abandoned: GetMatchOf is nil")
	local results = remotesFor("MatchResult", nil, mark)
	T.eq(#results, 0, "an abandoned match ends quietly (no MatchResult)")
	local fresh = freshPlayers(1, "Next")[1]
	local nextMatch = startMatch("Easy", { fresh })
	T.check(nextMatch ~= nil and nextMatch.Slot == slot, "the slot of an abandoned match is free again", nextMatch and tostring(nextMatch.Slot))
	conn:Disconnect()
	endAllMatches({ fresh })
	removePlayers({ fresh })
	flushErrors("match_abandon")
	flushWarnings("match_abandon")
end)

----------------------------------------------------------------------------------------------------
-- scenario: leaving via the HUD button (LeaveMatch remote)
----------------------------------------------------------------------------------------------------
S.match_leave = guarded("match_leave", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local players = freshPlayers(2, "Quit")
	local a, b = players[1], players[2]
	local m = startMatch("Easy", players)
	if not T.check(m ~= nil, "leave: match starts") then
		removePlayers(players)
		return
	end
	toPlaying(m)
	advance(0.5)
	local mark = logSize()
	Mock.FromClient(remoteFolder().LeaveMatch, b)
	advance(0.6)
	T.eq(MS().GetMatchOf(b), nil, "LeaveMatch remote: the player leaves the match")
	lobbyCheck(b, "leaver")
	T.eq(m.State, "Playing", "the match continues for the others")
	T.eq(#m.Players, 1, "match.Players shrinks")
	T.check(notified(a, "left", nil, mark), "the remaining player is told someone left")
	local ms = lastRemote("MatchState", b.UserId, mark)
	T.check(ms ~= nil and ms.args[1] == nil, "the leaver gets MatchState(nil)")
	MS().LeaveMatch(b) -- not in a match: must be a no-op
	Mock.FromClient(remoteFolder().LeaveMatch, b)
	advance(0.3)
	T.check(true, "LeaveMatch is a no-op for lobby players")
	Mock.FromClient(remoteFolder().LeaveMatch, a)
	advance(1.0)
	T.eq(MS().GetMatchOf(a), nil, "the last player leaves")
	T.check(#courseFolders() == 0, "leave: course destroyed when the last player leaves")
	lobbyCheck(a, "last leaver")
	removePlayers(players)
	flushErrors("match_leave")
	flushWarnings("match_leave")
end)

----------------------------------------------------------------------------------------------------
-- scenario: reset-button death inside a match
----------------------------------------------------------------------------------------------------
S.match_death = guarded("match_death", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local players = freshPlayers(2, "Reset")
	local a, b = players[1], players[2]
	local m = startMatch("Easy", players)
	if not T.check(m ~= nil, "death: match starts") then
		removePlayers(players)
		return
	end
	toPlaying(m)
	advance(0.5)
	local cp1 = m.Course.Checkpoints[1]
	Mock.Teleport(b, cp1.Part.Position + Vector3.new(0, 3.5, 0))
	advance(0.8)
	T.eq(m.Checkpoint, 1, "death: checkpoint 1 reached")
	local old = a.Character
	Mock.Kill(a)
	T.check(waitFor(function()
		return a.Character ~= nil and a.Character ~= old and hum(a) ~= nil and hum(a).Health > 0
	end, 12), "death: the player respawns (RespawnTime is short in matches)")
	advance(1.0)
	T.eq(MS().GetMatchOf(a), m, "death: still part of the match")
	T.eq(a:GetAttribute("InMatch"), true, "death: InMatch stays true")
	T.eq(a:GetAttribute("Downed"), false, "death: not downed after the respawn")
	local r, h = root(a), hum(a)
	T.check(r ~= nil and distance(r.Position, cp1.SpawnCFrame.Position) <= 14, "death: respawn at the team checkpoint", r and fmt(distance(r.Position, cp1.SpawnCFrame.Position)))
	T.check(h ~= nil and h.Health >= 0.4 * h.MaxHealth and h.Health <= 0.65 * h.MaxHealth, "death: respawn with ~50% health", h and tostring(h.Health))
	T.eq(h.WalkSpeed, Config.Physics.WalkSpeed, "death: movement stats are applied to the new character")
	T.eq(m.State, "Playing", "death: the match goes on")
	-- death while downed: no zombie state
	waitNotInvulnerable(a)
	DS().Damage(a, 999, "Other", { IgnoreIFrames = true })
	advance(0.5)
	T.eq(DS().IsDowned(a), true, "death: downed again")
	local old2 = a.Character
	Mock.Kill(a)
	T.check(waitFor(function()
		return a.Character ~= nil and a.Character ~= old2 and hum(a) ~= nil and hum(a).Health > 0
	end, 12), "death: a downed player who resets respawns")
	advance(1.0)
	T.eq(a:GetAttribute("Downed"), false, "death: the respawn clears Downed")
	T.eq(hum(a).WalkSpeed, Config.Physics.WalkSpeed, "death: the respawn can move again")
	endAllMatches(players)
	removePlayers(players)
	flushErrors("match_death")
	flushWarnings("match_death")
end)

----------------------------------------------------------------------------------------------------
-- scenario: concurrent matches / slots
----------------------------------------------------------------------------------------------------
S.match_slots = guarded("match_slots", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local n = Config.Match.MaxConcurrent
	local players = freshPlayers(n + 1, "Slot")
	local matches = {}
	local slotsSeen = {}
	local before = Mock.Stats()
	for i = 1, n do
		local m = MS().StartMatch(Config.Difficulties[(i - 1) % #Config.Difficulties + 1].Id, { players[i] })
		if not m then
			T.fail("match " .. i .. " of " .. n .. " starts")
		else
			matches[#matches + 1] = m
			slotsSeen[m.Slot] = (slotsSeen[m.Slot] or 0) + 1
			local expectX = Config.Match.ArenaOrigin.X + (m.Slot - 1) * Config.Match.SlotSpacing
			local startX = m.Course.StartCFrame.Position.X
			T.check(math.abs(startX - expectX) <= 40, "slot " .. m.Slot .. " course sits at ArenaOrigin + (slot-1)*SlotSpacing", "x=" .. fmt(startX) .. " expected ~" .. expectX)
		end
		advance(0.1)
	end
	local distinct = 0
	for slot, count in pairs(slotsSeen) do
		distinct = distinct + 1
		T.eq(count, 1, "slot " .. slot .. " is used once")
	end
	T.eq(distinct, n, n .. " concurrent matches use " .. n .. " different slots")
	local extra = MS().StartMatch("Easy", { players[n + 1] })
	T.eq(extra, nil, "StartMatch returns nil when all " .. n .. " slots are busy")
	-- portal: busy arenas
	local mark = logSize()
	local late = players[n + 1]
	enterPortal(late, "Easy")
	local told = waitFor(function()
		return notified(late, "busy", "bad", mark)
	end, Config.Match.PartyCountdown + 6)
	T.check(told, "a full server answers the portal party with 'All sky arenas are busy'")
	leavePortalArea(late)
	advance(5)
	-- free the middle slot: it is reused first
	local middle = matches[3]
	local middleSlot = middle.Slot
	MS().LeaveMatch(players[3])
	advance(1)
	local reuse = MS().StartMatch("Easy", { players[3] })
	T.check(reuse ~= nil and reuse.Slot == middleSlot, "the lowest free slot is reused", reuse and tostring(reuse.Slot))
	-- everything torn down
	T.check(#courseFolders() == n, n .. " course folders exist while the matches run", #courseFolders() .. "")
	endAllMatches(players)
	advance(2)
	T.eq(#courseFolders(), 0, "all course folders are destroyed after the matches")
	local after = Mock.Stats()
	T.info("*after " .. n .. " matches: connections " .. after.liveConnections .. " (before " .. before.liveConnections .. "), pending tasks " .. after.pendingTasks .. " (before " .. before.pendingTasks .. ")")
	removePlayers(players)
	flushErrors("match_slots")
	flushWarnings("match_slots")
end)

----------------------------------------------------------------------------------------------------
-- scenario: HazardService behaviours on a Saint course
----------------------------------------------------------------------------------------------------
local function pickHazardSeed(CB)
	local want = { "SpinBarPlatform", "StormPlatform", "LightningPlatform", "Vanishing", "Moving", "Bounce", "PlateBridge" }
	local bestSeed, bestScore = 1, -1
	for seed = 1, 60 do
		local layout = CB.GenerateLayout("Saint", seed)
		local have = {}
		for _, st in ipairs(layout.Steps) do
			have[st.Kind] = true
		end
		local score = 0
		for _, k in ipairs(want) do
			if have[k] then
				score = score + 1
			end
		end
		if score > bestScore then
			bestSeed, bestScore = seed, score
		end
		if score == #want then
			break
		end
	end
	return bestSeed
end

-- Root position of a character standing on `part` (feet 0.1 stud inside the surface so the touch registers).
local function topOf(part)
	return part.Position + Vector3.new(0, part.Size.Y / 2 + 2.9, 0)
end

S.hazards = guarded("hazards", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local CB, HS = mod("CourseBuilder"), mod("HazardService")
	local players = freshPlayers(1, "Haz")
	local a = players[1]
	a:SetAttribute("InMatch", true)
	advance(2.0) -- spawn i-frames
	local layout = CB.GenerateLayout("Saint", pickHazardSeed(CB))
	local holder = Instance.new("Folder")
	holder.Name = "SmokeHazards"
	holder.Parent = workspace
	local info = CB.Build(layout, Vector3.new(0, 3000, 0), holder)
	local active = true
	local staticParts = {}
	for _, d in ipairs(info.Folder:GetDescendants()) do
		staticParts[d] = true
	end
	local baseStats = Mock.Stats()
	local stop = HS.Attach(info.Folder, { IsActive = function() return active end })
	T.check(type(stop) == "function", "HazardService.Attach returns a stop function")
	advance(0.5)
	local function dmgEntries(kind, fromIndex)
		local out = {}
		for _, e in ipairs(remotesFor("DamageTaken", a.UserId, fromIndex)) do
			if e.args[2] == kind then
				out[#out + 1] = e
			end
		end
		return out
	end
	local function away()
		Mock.Teleport(a, Vector3.new(0, 3000 - 200, 0) + Vector3.new(500, 0, 0))
		advance(0.1)
	end
	local function reset()
		DS().SetHealthFraction(a, 1)
		advance(Config.Damage.IFrames + 0.3)
	end

	-- SpinBar
	local bars = tagged(Config.Tags.SpinBar, info.Folder)
	if #bars > 0 then
		local bar = bars[1]
		local c0 = bar.CFrame
		advance(0.5)
		T.check(bar.CFrame ~= c0, "SpinBar rotates", "CFrame unchanged")
		T.check((bar.CFrame.Position - c0.Position).Magnitude < 0.01, "SpinBar rotates around its own axis (position stays)")
		local mark = logSize()
		local dmg = bar:GetAttribute("Damage") or 15
		Mock.Teleport(a, bar.Position)
		advance(0.8)
		local hits = dmgEntries("SpinBar", mark)
		T.check(#hits >= 1 and hits[1].args[1] == dmg, "touching a SpinBar deals its Damage as 'SpinBar'", #hits .. " hits, first " .. (hits[1] and tostring(hits[1].args[1]) or "-") .. " expected " .. dmg)
		away()
		reset()
		-- paused hazards are harmless and frozen
		active = false
		mark = logSize()
		local c1 = bar.CFrame
		Mock.Teleport(a, bar.Position)
		advance(1.0)
		T.eq(#dmgEntries("SpinBar", mark), 0, "hazards do nothing while matchHandle.IsActive() is false")
		T.check(bar.CFrame == c1 or (bar.CFrame.Position - c1.Position).Magnitude < 0.01, "paused SpinBars stop turning", "")
		active = true
		away()
		reset()
	else
		T.warn("hazards: the sampled course has no SpinBar")
	end

	-- MovingCloud
	local movers = tagged(Config.Tags.MovingCloud, info.Folder)
	if #movers > 0 then
		local cloud = movers[1]
		local offset = cloud:GetAttribute("EndOffset")
		local period = cloud:GetAttribute("Period") or 3
		local lo, hi = Vector3.new(huge, huge, huge), Vector3.new(-huge, -huge, -huge)
		local sawVelocity = false
		for _ = 1, math.floor(period * 30 * 2.2) do
			advance(1 / 30)
			local p = cloud.Position
			lo = Vector3.new(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z))
			hi = Vector3.new(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z))
			if cloud.AssemblyLinearVelocity.Magnitude > 0.2 then
				sawVelocity = true
			end
		end
		local travelled = (hi - lo).Magnitude
		if typeof(offset) == "Vector3" then
			T.check(math.abs(travelled - offset.Magnitude) <= offset.Magnitude * 0.15 + 0.3, "MovingCloud travels EndOffset back and forth", "travelled " .. fmt(travelled) .. ", EndOffset " .. fmt(offset.Magnitude))
		else
			T.check(travelled > 1, "MovingCloud moves", "travelled " .. fmt(travelled))
		end
		-- passengers: either the server carries them or the cloud publishes its velocity as a moving surface
		Mock.Teleport(a, topOf(cloud))
		advance(0.1)
		local startRoot, startCloud = root(a).Position, cloud.Position
		advance(period / 4)
		local movedRoot = root(a).Position - startRoot
		local movedCloud = cloud.Position - startCloud
		if movedCloud.Magnitude > 1 then
			local carried = (movedRoot - movedCloud).Magnitude <= movedCloud.Magnitude * 0.5 + 0.5
			T.check(carried or sawVelocity, "players standing on a MovingCloud are carried (CFrame nudge or published AssemblyLinearVelocity)", "cloud moved " .. fmt(movedCloud.Magnitude) .. ", player " .. fmt(movedRoot.Magnitude) .. ", velocity seen: " .. tostring(sawVelocity))
		end
		away()
	end

	-- StormCloud
	local storms = tagged(Config.Tags.StormCloud, info.Folder)
	if #storms > 0 then
		local storm = storms[1]
		local dps = storm:GetAttribute("DPS") or 8
		local mark = logSize()
		Mock.Teleport(a, storm.Position)
		advance(2.1)
		local hits = dmgEntries("Storm", mark)
		local total = 0
		for _, e in ipairs(hits) do
			total = total + e.args[1]
		end
		T.check(#hits >= 4, "players inside a StormCloud are hit repeatedly (4 Hz ticks)", #hits .. " hits in 2 s")
		T.check(total >= dps * 1.2 and total <= dps * 2.6, "StormCloud deals ~DPS per second", "total " .. fmt(total) .. " over 2 s with DPS " .. dps)
		away()
		reset()
		mark = logSize()
		advance(1.0)
		T.eq(#dmgEntries("Storm", mark), 0, "no storm damage outside the cloud")
	end

	-- LightningZone
	local zones = tagged(Config.Tags.LightningZone, info.Folder)
	if #zones > 0 then
		local zone = zones[1]
		local interval = zone:GetAttribute("Interval") or 4
		local warning = zone:GetAttribute("Warning") or 1.2
		local dmg = zone:GetAttribute("Damage") or 28
		local mark = logSize()
		Mock.Teleport(a, Vector3.new(zone.Position.X, zone.Position.Y, zone.Position.Z))
		-- a warning disc / bolt is any part above the zone's footprint that the course did not have before Attach
		local known = staticParts
		local reach = math.max(zone.Size.X, zone.Size.Z) / 2 + 3
		local function newPartHere()
			for _, d in ipairs(info.Folder:GetDescendants()) do
				if not known[d] and d:IsA("BasePart") then
					local dx, dz = d.Position.X - zone.Position.X, d.Position.Z - zone.Position.Z
					if math.sqrt(dx * dx + dz * dz) <= reach then
						return true
					end
				end
			end
			return false
		end
		local firstPartAt, hitAt, hit
		local startedAt = Mock.Clock.now
		local deadline = Mock.Clock.now + interval * 2 + warning + 3
		while Mock.Clock.now < deadline do
			advance(0.05)
			if not firstPartAt and newPartHere() then
				firstPartAt = Mock.Clock.now
			end
			hit = dmgEntries("Lightning", mark)[1]
			if hit then
				hitAt = Mock.Clock.now
				break
			end
			-- keep the player fed so the test cannot kill them before the first strike
			DS().SetHealthFraction(a, 1)
		end
		T.check(hit ~= nil, "a LightningZone strikes players inside its radius", "no 'Lightning' damage within " .. fmt(interval * 2 + warning + 3) .. " s")
		-- the warning must be on screen before the bolt; if we saw it appear fresh it must last about Warning seconds
		local warned = firstPartAt ~= nil and hitAt ~= nil and firstPartAt < hitAt
		if warned and firstPartAt > startedAt + 0.2 then
			warned = hitAt - firstPartAt >= warning * 0.6
		end
		T.check(warned, "a LightningZone shows a warning (new parts above the zone) before it strikes", firstPartAt and hitAt and ("warning at " .. fmt(firstPartAt, 2) .. ", strike at " .. fmt(hitAt, 2) .. ", Warning attr " .. warning) or "no warning parts seen")
		if hit then
			T.near(hit.args[1], dmg, 0.01, "lightning deals its Damage attribute")
		end
		away()
		reset()
		local function tempParts()
			local n = 0
			for _, d in ipairs(info.Folder:GetDescendants()) do
				local lname = d.Name:lower()
				if d:IsA("BasePart") and lname ~= "strikemark" and (lname:find("bolt") or lname:find("strike") or lname:find("flash")) then
					n = n + 1
				end
			end
			return n
		end
		local peak = 0
		for _ = 1, 24 do
			advance(interval / 2)
			peak = math.max(peak, tempParts())
		end
		T.check(peak <= 90, "lightning bolts / warning discs are short-lived (bounded count)", "peak " .. peak .. " temporary parts")
		W.tempParts = tempParts
	end

	-- VanishCloud
	local vanish = tagged(Config.Tags.VanishCloud, info.Folder)
	if #vanish > 0 then
		local cloud = vanish[1]
		local delay = cloud:GetAttribute("VanishDelay") or 0.9
		local back = cloud:GetAttribute("ReturnDelay") or 3.5
		Mock.Teleport(a, topOf(cloud))
		advance(delay + 0.8)
		Mock.Teleport(a, Vector3.new(500, 2800, 0))
		T.check(cloud.CanCollide == false, "a VanishCloud turns non-solid after VanishDelay", "CanCollide " .. tostring(cloud.CanCollide))
		T.check(cloud.Transparency >= 0.8, "...and fades out", "Transparency " .. tostring(cloud.Transparency))
		advance(back + 2)
		T.check(cloud.CanCollide == true, "a VanishCloud returns after ReturnDelay", "CanCollide " .. tostring(cloud.CanCollide))
		T.check(cloud.Transparency <= 0.3, "...and becomes visible again", "Transparency " .. tostring(cloud.Transparency))
		away()
	end

	-- BouncePad
	local pads = tagged(Config.Tags.BouncePad, info.Folder)
	if #pads > 0 then
		local pad = pads[1]
		local power = pad:GetAttribute("Power") or 90
		root(a).AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		Mock.Teleport(a, topOf(pad))
		advance(0.3)
		T.near(root(a).AssemblyLinearVelocity.Y, power, 1, "a BouncePad launches players with Power")
		root(a).AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		Mock.Touch(pad, root(a))
		advance(0.05)
		T.near(root(a).AssemblyLinearVelocity.Y, 0, 0.5, "BouncePad has a 0.3 s debounce")

		-- LaunchSpeed: a moving player keeps their heading but leaves at the pad's horizontal speed;
		-- a (nearly) standing player bounces straight up
		local speed = pad:GetAttribute("LaunchSpeed")
		if T.check(type(speed) == "number" and speed > 0, "BouncePads carry a LaunchSpeed attribute", tostring(speed)) then
			advance(0.5)
			root(a).AssemblyLinearVelocity = Vector3.new(3, 0, 4) -- 5 studs/s along (0.6, 0, 0.8)
			Mock.Touch(pad, root(a))
			advance(0.05)
			local v = root(a).AssemblyLinearVelocity
			T.near(v.Y, power, 1, "a moving player still gets the full Power")
			T.near(math.sqrt(v.X * v.X + v.Z * v.Z), speed, 0.5, "a moving player leaves a BouncePad at LaunchSpeed")
			T.near(v.X, speed * 0.6, 0.5, "...keeping the heading (X)")
			T.near(v.Z, speed * 0.8, 0.5, "...keeping the heading (Z)")
			advance(0.5)
			root(a).AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			Mock.Touch(pad, root(a))
			advance(0.05)
			v = root(a).AssemblyLinearVelocity
			T.near(v.Y, power, 1, "a standing player gets the full Power")
			T.near(math.sqrt(v.X * v.X + v.Z * v.Z), 0, 0.5, "a standing player bounces straight up")
		end
		away()
	end

	-- PressurePlate + PlateBridge
	local plates = tagged(Config.Tags.PressurePlate, info.Folder)
	if #plates > 0 then
		local plate = plates[1]
		local id = plate:GetAttribute("BridgeId")
		local bridges = {}
		for _, b in ipairs(tagged(Config.Tags.PlateBridge, info.Folder)) do
			if b:GetAttribute("BridgeId") == id then
				bridges[#bridges + 1] = b
			end
		end
		T.check(id ~= nil and #bridges >= 1, "plate and bridge share a BridgeId", tostring(id))
		local function solid()
			for _, b in ipairs(bridges) do
				if b.CanCollide then
					return true
				end
			end
			return false
		end
		advance(0.5)
		T.check(not solid(), "bridges are not solid while nobody stands on the plate")
		Mock.Teleport(a, topOf(plate))
		advance(0.8)
		T.check(solid(), "standing on a PressurePlate makes its PlateBridge solid")
		local visible = false
		for _, b in ipairs(bridges) do
			visible = visible or b.Transparency < 0.5
		end
		T.check(visible, "...and visible")
		away()
		advance(0.4)
		T.check(solid(), "the bridge stays ~1 s after the last player leaves")
		advance(2.5)
		T.check(not solid(), "the bridge retracts after the plate is released")
	end

	-- stop: nothing keeps running
	stop()
	advance(0.3)
	local statsAfterStop = Mock.Stats()
	local bar = bars[1]
	local c2 = bar and bar.CFrame
	local mark = logSize()
	if bar then
		Mock.Teleport(a, bar.Position)
	end
	advance(1.0)
	if bar then
		T.check(bar.CFrame == c2, "after stopFn() SpinBars no longer turn")
		T.eq(#dmgEntries("SpinBar", mark), 0, "after stopFn() hazards no longer hurt")
	end
	T.check(statsAfterStop.connections["RunService.Heartbeat"] == baseStats.connections["RunService.Heartbeat"], "stopFn() disconnects the Heartbeat driver", tostring(statsAfterStop.connections["RunService.Heartbeat"]) .. " vs " .. tostring(baseStats.connections["RunService.Heartbeat"]))
	pcall(stop) -- idempotent
	away()
	advance(6)
	if W.tempParts then
		local left = W.tempParts()
		T.check(left <= 2, "after stopFn() no lightning bolts / discs linger", left .. " temporary parts after 6 s")
		W.tempParts = nil
	end
	holder:Destroy()
	advance(10)
	local final = Mock.Stats()
	T.check(final.pendingTasks <= baseStats.pendingTasks + 1, "hazard threads end after stopFn + Destroy", "pending " .. final.pendingTasks .. " vs " .. baseStats.pendingTasks)
	removePlayers(players)
	flushErrors("hazards")
	flushWarnings("hazards")
end)

----------------------------------------------------------------------------------------------------
-- scenario: DataStore persistence
----------------------------------------------------------------------------------------------------
local function storedTokens(userId)
	local entry = Mock.DataStore.Data["NimbusClimb_v1/u_" .. userId]
	return entry and entry.Tokens
end

S.persistence = guarded("persistence", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local DataService = mod("DataService")
	Mock.DataStore.Latency = 0.15
	local p = Mock.AddPlayer("Saver", 777001)
	advance(1.0)
	T.eq(p:GetAttribute("CloudTokens"), 0, "a brand-new player has 0 tokens")
	DataService.AddTokens(p, 12)
	T.eq(DataService.GetTokens(p), 12, "tokens are kept in memory")
	Mock.RemovePlayer(p)
	advance(1.5)
	T.eq(storedTokens(777001), 12, "PlayerRemoving saves { Tokens = n } under 'NimbusClimb_v1' / 'u_<UserId>'", tostring(storedTokens(777001)))
	local again = Mock.AddPlayer("Saver", 777001)
	advance(1.2)
	T.eq(again:GetAttribute("CloudTokens"), 12, "a returning player gets the saved tokens")
	T.eq(again:FindFirstChild("leaderstats") and again.leaderstats.Tokens.Value, 12, "...also on leaderstats")
	-- autosave
	DataService.AddTokens(again, 3)
	local writes = Mock.DataStore.Writes
	advance(Config.Tokens.AutosaveSeconds + 5)
	T.check(Mock.DataStore.Writes > writes, "autosave writes dirty data every AutosaveSeconds", "no writes in " .. (Config.Tokens.AutosaveSeconds + 5) .. " s")
	T.eq(storedTokens(777001), 15, "autosave stores the new total", tostring(storedTokens(777001)))
	-- DataStore outage: never blocks or crashes the game
	Mock.DataStore.Fail = true
	local outage = Mock.AddPlayer("Offline", 777002)
	advance(2.5)
	T.check(outage.Parent ~= nil and root(outage) ~= nil, "a DataStore outage does not stop players from joining")
	T.eq(outage:GetAttribute("CloudTokens"), 0, "...they start with 0 tokens")
	DataService.AddTokens(outage, 4)
	T.eq(outage:GetAttribute("CloudTokens"), 4, "tokens still work in memory during an outage")
	Mock.RemovePlayer(outage)
	advance(3)
	Mock.DataStore.Fail = false
	local noExtraErrors = #Mock.Errors == errorCursor
	T.check(noExtraErrors, "DataStore failures raise no script errors")
	flushErrors("persistence")
	Mock.DataStore.Latency = 0
	-- the value for the saver must survive the outage untouched
	Mock.RemovePlayer(again)
	advance(1.5)
	T.eq(storedTokens(777001), 15, "the stored total survives an outage")
	flushWarnings("persistence", { "DataStore", "save", "load", "Save", "Load" })
end)

----------------------------------------------------------------------------------------------------
-- scenario: Dash relay (Main.server.lua)
----------------------------------------------------------------------------------------------------
S.dash_relay = guarded("dash_relay", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local p = freshPlayers(1, "Dasher")[1]
	local dash = remoteFolder().Dash
	local mark = logSize()
	Mock.FromClient(dash, p)
	advance(0.05)
	local fx = remotesFor("DashFx", nil, mark)
	T.check(#fx == 1 and fx[1].kind == "all" and fx[1].args[1] == p.UserId, "Dash -> DashFx:FireAllClients(userId)", #fx .. " messages")
	Mock.FromClient(dash, p)
	advance(0.05)
	T.eq(#remotesFor("DashFx", nil, mark), 1, "a dash inside the cooldown is ignored")
	advance(Config.Physics.DashCooldown)
	Mock.FromClient(dash, p)
	advance(0.05)
	T.eq(#remotesFor("DashFx", nil, mark), 2, "dashing works again after the cooldown")
	removePlayers({ p })
	flushErrors("dash_relay")
end)

----------------------------------------------------------------------------------------------------
-- scenario: server shutdown saves everybody
----------------------------------------------------------------------------------------------------
S.shutdown = guarded("shutdown", function()
	if not needBoot() then
		return
	end
	local DataService = mod("DataService")
	local p = Mock.AddPlayer("LastOut", 777003)
	advance(1.0)
	DataService.AddTokens(p, 9)
	Mock.DataStore.Latency = 0.2
	local finished = Mock.Shutdown(30)
	Mock.DataStore.Latency = 0
	T.check(finished, "all BindToClose callbacks finish within 30 s")
	T.eq(storedTokens(777003), 9, "BindToClose saves players that are still online", tostring(storedTokens(777003)))
	flushErrors("shutdown")
end)

----------------------------------------------------------------------------------------------------
-- scenario: whole-run invariants
----------------------------------------------------------------------------------------------------
function S.export_replication()
	return Mock.Replication
end

S.final_checks = guarded("final_checks", function()
	local Config = config()
	-- 1. every remote payload follows ARCHITECTURE.md
	local counts, bad = {}, {}
	local allowed = {}
	for _, n in ipairs(Config.Remotes) do
		allowed[n] = true
	end
	for _, e in ipairs(Mock.RemoteLog) do
		counts[e.remote] = (counts[e.remote] or 0) + 1
		if not allowed[e.remote] then
			bad[#bad + 1] = "unknown remote " .. tostring(e.remote)
		elseif e.kind ~= "server" then
			local problems = V.entry(e, Config)
			if #problems > 0 and #bad < 8 then
				bad[#bad + 1] = e.remote .. ": " .. table.concat(problems, ", ")
			end
		end
	end
	local parts = {}
	for name, n in pairs(counts) do
		parts[#parts + 1] = name .. "=" .. n
	end
	table.sort(parts)
	T.info("*server->client traffic: " .. table.concat(parts, "  "))
	T.check(#bad == 0, "every remote message uses a Config.Remotes name and the documented payload", table.concat(bad, "\n"))
	for _, name in ipairs({ "Notify", "DamageTaken", "PartyState", "MatchState", "MatchResult", "DashFx" }) do
		T.check((counts[name] or 0) > 0, "the run exercised the " .. name .. " remote")
	end

	-- 2. fonts: every text object uses a Theme font
	local Theme = M["shared/Theme"]
	local allowedFonts = {}
	for role, font in pairs(Theme.Fonts) do
		allowedFonts[font] = true
	end
	local problems, total = Mock.FontAudit(allowedFonts)
	T.info("*font audit: " .. total .. " live text objects checked")
	local shown = {}
	for i = 1, math.min(8, #problems) do
		shown[i] = problems[i].path .. " [" .. problems[i].text .. "]: " .. problems[i].reason
	end
	T.check(#problems == 0, "every TextLabel/TextButton/TextBox is styled through Theme", #problems .. " unstyled:\n" .. table.concat(shown, "\n"))

	-- 3. nothing left behind: no matches, no course folders, no stray threads/connections
	removePlayers(Players:GetPlayers())
	advance(5)
	T.eq(#courseFolders(), 0, "no Course_* folder remains in workspace")
	local leftovers = {}
	local known = {}
	for _, n in ipairs(W.baselineChildren or {}) do
		known[n] = true
	end
	for _, c in ipairs(workspace:GetChildren()) do
		if W.baselineChildren and not known[c.Name] and not c:IsA("Camera") then
			leftovers[#leftovers + 1] = c.Name
		end
	end
	T.check(#leftovers == 0, "workspace contains only the lobby (+Terrain/Camera) after all matches", table.concat(leftovers, ", "))
	advance(5)
	local stats = Mock.Stats()
	local base = W.baseline or stats
	local grew = {}
	for name, n in pairs(stats.connections) do
		local b = base.connections[name] or 0
		-- Players.* events keep one connection per service; other counts must not grow with matches
		if n > b + 2 then
			grew[#grew + 1] = name .. " " .. b .. " -> " .. n
		end
	end
	table.sort(grew)
	T.check(#grew == 0, "no event connections leak across matches", table.concat(grew, ", "))
	T.check(stats.pendingTasks <= base.pendingTasks + 3, "no scheduler threads leak across matches", "pending " .. stats.pendingTasks .. " vs baseline " .. base.pendingTasks)
	T.check(stats.playingTweens <= base.playingTweens + 2, "no looping tweens leak across matches", "playing " .. stats.playingTweens .. " vs baseline " .. base.playingTweens)
	T.check(stats.touchRegistry <= base.touchRegistry + 40, "no Touched listeners leak across matches", "registry " .. stats.touchRegistry .. " vs baseline " .. base.touchRegistry)
	local waits = Mock.PendingWaitList(5)
	T.check(#waits == 0, "no WaitForChild waits forever (infinite yield)", table.concat(waits, "; "))

	-- 4. mock findings (things real Roblox would reject or warn about)
	local seen = {}
	for _, d in ipairs(Mock.Diagnostics) do
		local line = d.kind .. ": " .. d.msg .. " (x" .. d.count .. ", first at " .. d.where .. ")"
		if d.kind == "unknown-member" then
			T.warn("mock: " .. line, "reading a member that does not exist errors in Roblox; if it is a real property, add it to robloxmock.lua")
		elseif d.kind == "infinite-yield" or d.kind == "nan" or d.kind == "out-of-range" then
			T.fail("mock: " .. line)
		elseif d.kind == "deprecated" then
			T.warn("mock: " .. line)
		elseif d.kind == "mock-gap" then
			seen[#seen + 1] = d.key
		elseif d.kind == "unknown-enum" then
			T.warn("mock: " .. line)
		else
			T.warn("mock: " .. line)
		end
	end
	if #seen > 0 then
		T.info("mock coverage gaps (classes without a property model): " .. table.concat(seen, ", "))
	end
	T.check(#Mock.ModuleErrors == 0, "no module raised an error while loading", #Mock.ModuleErrors > 0 and Mock.ModuleErrors[1].message or "")
	flushErrors("final")
	flushWarnings("final")
	T.info("*simulated " .. fmt(Mock.Clock.now, 0) .. " s of game time")
end)

----------------------------------------------------------------------------------------------------
-- helpers exported to smoke_content.lua / smoke_economy.lua (they run in the same Lua state)
----------------------------------------------------------------------------------------------------
_G.K = {
	S = S, W = W, M = M, T = T, V = V, guarded = guarded,
	fmt = fmt, mod = mod, config = config, advance = advance, waitFor = waitFor, moduleInstance = moduleInstance,
	lastRemote = lastRemote, remotesFor = remotesFor, joinPlayer = joinPlayer, hum = hum, root = root,
	flushErrors = flushErrors, flushWarnings = flushWarnings, freshPlayers = freshPlayers, removePlayers = removePlayers,
	endAllMatches = endAllMatches, remoteFolder = remoteFolder, state = state, startMatch = startMatch, toPlaying = toPlaying,
	distance = distance, planar = planar, notified = notified, logSize = logSize, waitNotInvulnerable = waitNotInvulnerable,
	tagged = tagged, courseFolders = courseFolders, enterPortal = enterPortal, leavePortalArea = leavePortalArea,
	firstToken = firstToken, needBoot = needBoot, paletteAudit = paletteAudit, groundBelow = groundBelow,
	textsUnder = textsUnder, plainText = plainText, countStars = countStars, colorDistance255 = colorDistance255,
	shortPath = shortPath, MS = MS, DS = DS, lobbyCheck = lobbyCheck, transparencyOf = transparencyOf, storedTokens = storedTokens,
	resetCursors = function()
		errorCursor = #Mock.Errors
		outputCursor = #Mock.Output
	end,
}

return S
