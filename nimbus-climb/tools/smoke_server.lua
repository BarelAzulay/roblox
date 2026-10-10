-- smoke_server.lua: scenarios for the server world of tools/smoke.py.
--
-- Globals provided by smoke.py: Mock (tools/robloxmock.lua), CONTRACT (tools/contract.json), ROOTS
-- (src directory name -> instance path), ARGS ({ seeds, verbose, quick }).
-- Every scenario is a function in the returned table; checks are reported through T.
-- v3: boot checks the brighter, warmer lighting; lobby checks the voxel lobby budget, the Portal_<Id> / Roulette_<Id>
-- tutorial targets, the empty flat home yards, LobbyInfo.NpcSpots / AltarSite / AltarDock, the six NPC pets
-- (workspace.NimbusNpcs, own part budget, Talk prompts, never moved by the server) and, once built, the Storm Altar;
-- final_checks validates every ProfileSync (Discovered / IndexClaimed / Tutorial) and TutorialState payload.
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
	local PPS = game:GetService("ProximityPromptService")
	local serviceSaw, serviceBy, shown, hidden
	local c1 = PPS.PromptTriggered:Connect(function(p, who)
		serviceSaw, serviceBy = p, who
	end)
	local c2 = PPS.PromptShown:Connect(function(p, inputType)
		shown = { p, inputType }
	end)
	local c3 = PPS.PromptHidden:Connect(function(p)
		hidden = p
	end)
	Mock.Trigger(prompt, Players:GetPlayers()[1] or "nobody")
	advance(0.05)
	T.check(triggeredBy ~= nil, "Mock.Trigger fires ProximityPrompt.Triggered with the player")
	T.check(serviceSaw == prompt and serviceBy == triggeredBy, "...and ProximityPromptService.PromptTriggered(prompt, player)", tostring(serviceSaw))
	Mock.ShowPrompt(prompt)
	Mock.HidePrompt(prompt)
	advance(0.05)
	T.check(shown ~= nil and shown[1] == prompt and shown[2] == Enum.ProximityPromptInputType.Keyboard and hidden == prompt, "Mock.ShowPrompt / HidePrompt fire PromptShown(prompt, inputType) / PromptHidden(prompt)")
	c1:Disconnect()
	c2:Disconnect()
	c3:Disconnect()
	T.check(prompt.Style == Enum.ProximityPromptStyle.Default and prompt.Exclusivity == Enum.ProximityPromptExclusivity.OnePerButton, "ProximityPrompt.Style / Exclusivity defaults")
	-- GuiButton is the abstract base of TextButton and ImageButton
	T.check(Instance.new("TextButton"):IsA("GuiButton") and Instance.new("ImageButton"):IsA("GuiButton") and not Instance.new("TextLabel"):IsA("GuiButton"), "TextButton / ImageButton are GuiButtons (TextLabel is not)")
	T.check(raises(function()
		return Instance.new("GuiButton")
	end), "GuiButton cannot be created (abstract class)")
	T.check(Instance.new("ImageButton").AutoButtonColor == true and Instance.new("TextButton").Modal == false, "GuiButton properties (AutoButtonColor, Modal) on both button classes")
	-- WorldRoot:BulkMoveTo really moves the parts (the sky dragon poses every part with one call per frame)
	local bulkA, bulkB = Instance.new("Part"), Instance.new("Part")
	bulkA.Anchored, bulkB.Anchored = true, true
	bulkA.Parent, bulkB.Parent = workspace, workspace
	local moved = 0
	local mc = bulkA:GetPropertyChangedSignal("CFrame"):Connect(function()
		moved = moved + 1
	end)
	workspace:BulkMoveTo({ bulkA, bulkB }, { CFrame.new(1, 2, 3), CFrame.new(4, 5, 6) * CFrame.Angles(0, 1, 0) }, Enum.BulkMoveMode.FireCFrameChanged)
	advance(0.05)
	T.check(bulkA.Position == Vector3.new(1, 2, 3) and (bulkB.Position - Vector3.new(4, 5, 6)).Magnitude < 1e-9 and math.abs(bulkB.CFrame.LookVector.X + math.sin(1)) < 1e-6, "workspace:BulkMoveTo sets every part's CFrame", tostring(bulkA.Position) .. " / " .. tostring(bulkB.Position))
	T.check(moved >= 1, "...and fires CFrame changed (BulkMoveMode.FireCFrameChanged)")
	mc:Disconnect()
	T.check(raises(function()
		workspace:BulkMoveTo({ bulkA, bulkB }, { CFrame.new() })
	end), "BulkMoveTo rejects lists of different length")
	T.check(raises(function()
		workspace:BulkMoveTo({ bulkA }, { Vector3.new() })
	end), "BulkMoveTo rejects a non-CFrame")
	T.check(raises(function()
		workspace:BulkMoveTo({ bulkA }, { CFrame.new() }, Enum.Material.Neon)
	end), "BulkMoveTo rejects an eventMode that is not an Enum.BulkMoveMode")
	local wm = Instance.new("WorldModel")
	bulkB.Parent = wm
	wm:BulkMoveTo({ bulkB }, { CFrame.new(7, 7, 7) })
	T.check(bulkB.Position == Vector3.new(7, 7, 7), "WorldModel:BulkMoveTo works too (ViewportFrame worlds)")
	bulkA:Destroy()
	wm:Destroy()
	T.check(Enum.BulkMoveMode.FireAllEvents ~= nil and raises(function()
		return Enum.BulkMoveMode.Typo
	end), "Enum.BulkMoveMode is a known (closed) enum")
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
	-- AutomaticSize + UIScale on the SAME object (the left menu column): the content is measured once in the object's own
	-- space and the scale is applied once afterwards. Applying it twice made a 304 px column 158 px tall instead of 219 and
	-- moved its centre-anchored top edge down by ~30 px, so overlap checks against it were too lenient on phones.
	local column = Instance.new("Frame")
	column.AnchorPoint = Vector2.new(0, 0.5)
	column.Position = UDim2.new(0, 10, 0.5, 0)
	column.Size = UDim2.new(0, 68, 0, 0)
	column.AutomaticSize = Enum.AutomaticSize.Y
	column.Parent = gui
	local colLayout = Instance.new("UIListLayout")
	colLayout.Padding = UDim.new(0, 6)
	colLayout.SortOrder = Enum.SortOrder.LayoutOrder
	colLayout.Parent = column
	local colScale = Instance.new("UIScale")
	colScale.Scale = 0.72
	colScale.Parent = column
	local colRows = {}
	for i = 1, 5 do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(0, 68, 0, 56)
		row.LayoutOrder = i
		row.Parent = column
		colRows[i] = row
	end
	T.near(column.AbsoluteSize.Y, (5 * 56 + 4 * 6) * 0.72, 0.01, "layout: AutomaticSize + UIScale measure the content once (304 px at scale 0.72 = 218.9 px)")
	T.near(column.AbsoluteSize.X, 68 * 0.72, 0.01, "layout: ...and scale the fixed width once")
	T.near(column.AbsolutePosition.Y + column.AbsoluteSize.Y / 2, 540, 0.01, "layout: ...so a (0, 0.5)-anchored column stays vertically centred")
	T.near(colRows[2].AbsolutePosition.Y - colRows[1].AbsolutePosition.Y, (56 + 6) * 0.72, 0.01, "layout: ...with scaled row pitch")
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
		if not inst and CONTRACT.modules[key].optional then
			-- Main loads it only when present (ARCHITECTURE_V3.md): absent is fine, present must work
			T.info("*" .. key .. " is optional and not in this build yet")
		elseif not inst then
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
			-- 'pending': members another engineer adds this round; absent as a whole is fine, partly landed is not
			local pending = spec.pending
			if type(pending) == "table" then
				local landed, absent = {}, {}
				for _, kind in ipairs({ "functions", "signals", "fields" }) do
					for _, name in ipairs(pending[kind] or {}) do
						if m[name] ~= nil then
							landed[#landed + 1] = name
							local ok = (kind == "fields") or (kind == "functions" and isCallable(m[name])) or (kind == "signals" and type(m[name]) == "table" and isCallable(m[name].Connect) and isCallable(m[name].Fire))
							if not ok then
								problems = problems + 1
								T.fail(key .. "." .. name .. " is a " .. kind:sub(1, -2) .. " (tools/contract.json pending group)", "got " .. type(m[name]))
							end
						else
							absent[#absent + 1] = name
						end
					end
				end
				if #landed == 0 then
					T.info("*" .. key .. ": " .. table.concat(absent, ", ") .. " not in this build yet (" .. tostring(pending._comment or "pending") .. ")")
				elseif #absent > 0 then
					problems = problems + 1
					T.fail(key .. ": the whole pending group is defined", table.concat(landed, ", ") .. " defined but " .. table.concat(absent, ", ") .. " missing")
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

	-- lighting + global settings: v3 "slightly brighter and warmer" than the v2 late-afternoon calm look
	-- (ARCHITECTURE_V3.md section 6: ClockTime ~14.5, Brightness ~2.0, warmer ColorShift_Top, OutdoorAmbient a little
	-- higher, Bloom stays subtle, no blow-out)
	local Lighting = game:GetService("Lighting")
	T.near(Lighting.ClockTime, CONTRACT.v3.lighting.ClockTime, 0.75, "Lighting.ClockTime is early afternoon (~14.5)")
	T.near(Lighting.Brightness, CONTRACT.v3.lighting.Brightness, 0.35, "Lighting.Brightness is a little brighter than v2 (~2.0)")
	local function rgb255(c)
		return c.R * 255, c.G * 255, c.B * 255
	end
	local function nearColor(c, r, g, b, tol, name)
		local cr, cg, cb = rgb255(c)
		T.check(math.abs(cr - r) <= tol and math.abs(cg - g) <= tol and math.abs(cb - b) <= tol, name, string.format("got %.0f,%.0f,%.0f expected ~%d,%d,%d", cr, cg, cb, r, g, b))
	end
	nearColor(Lighting.Ambient, 96, 104, 130, 24, "Lighting.Ambient is a soft blue (~96,104,130)")
	do
		-- v2 had OutdoorAmbient ~108,120,152: v3 lifts it a little (no black voxel creases) without washing out
		local r, g, b = rgb255(Lighting.OutdoorAmbient)
		T.check(r + g + b > 108 + 120 + 152 + 10 and math.max(r, g, b) <= 190 and b >= r, "Lighting.OutdoorAmbient is a little higher than v2 and stays a soft blue", string.format("%.0f,%.0f,%.0f", r, g, b))
		local tr, tg, tb = rgb255(Lighting.ColorShift_Top)
		T.check(tr > tb + 15 and tr >= tg, "Lighting.ColorShift_Top is warm (a golden sun)", string.format("%.0f,%.0f,%.0f", tr, tg, tb))
	end
	T.check(Lighting.ExposureCompensation <= 0.05 and Lighting.ExposureCompensation >= -0.6, "Lighting.ExposureCompensation is about neutral (no blow-out)", tostring(Lighting.ExposureCompensation))
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
				if d.Shape == Enum.PartType.Ball then
					-- a ball shows its biggest circle, not the bounding face
					face = math.max(a, b, cc) ^ 2 * 0.785
				elseif d.Shape == Enum.PartType.Cylinder then
					-- Roblox cylinders run along X (Size.X = length, Size.Y / Size.Z = diameter). What a viewer sees is
					-- either the round cap (a flat disc: pi/4 * d^2) or the long side (length * diameter, a rod);
					-- squaring the longest dimension would count a thin 0.55 x 17.2 rod as a 231 stud^2 slab.
					local diameter = math.max(b, cc)
					face = math.max(a * diameter, 0.785 * diameter * diameter)
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

local function hdist(a, b)
	return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
end

-- Notify messages sent to one player since log index `mark` whose text contains `needle` (plain search).
local function notifiedSince(player, needle, mark)
	for i = (mark or 0) + 1, #Mock.RemoteLog do
		local e = Mock.RemoteLog[i]
		if e.remote == "Notify" and e.kind ~= "server" and (e.kind == "all" or e.userId == player.UserId) and tostring(e.args[1]):lower():find(needle:lower(), 1, true) then
			return e
		end
	end
	return nil
end

local function partCFrames(root)
	local out = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			out[d] = d.CFrame
		end
	end
	return out
end

local function movedParts(before)
	local n = 0
	for part, cf in pairs(before) do
		if part.Parent and not part.CFrame:FuzzyEq(cf) then
			n = n + 1
		end
	end
	return n
end

-- ARCHITECTURE_V3.md section 5: the six NPC pets (shared/NpcDialog data, NpcService models in workspace.NimbusNpcs).
local function npcChecks(info)
	local Config = config()
	local ND, PC, PB, NS = mod("NpcDialog"), mod("PetCatalog"), mod("PetBuilder"), mod("NpcService")
	if not T.check(type(ND) == "table" and type(ND.Npcs) == "table", "shared/NpcDialog lists the NPC pets") then
		return
	end
	T.eq(#ND.Npcs, CONTRACT.v3.npcCount, "NpcDialog has " .. CONTRACT.v3.npcCount .. " NPCs")
	local data = T.tally("every NPC has a unique Id, a Name, a catalog PetId, Scale ~" .. CONTRACT.v3.npcScale .. " and 3-5 short plain-text lines")
	local seen, allLines = {}, {}
	for _, npc in ipairs(ND.Npcs) do
		local lines = type(npc.Lines) == "table" and npc.Lines or {}
		local linesOk = #lines >= 3 and #lines <= 5
		for _, line in ipairs(lines) do
			linesOk = linesOk and type(line) == "string" and #line >= 8 and #line <= 240 and not line:find("[<>&]")
			allLines[#allLines + 1] = tostring(line)
		end
		local ok = type(npc.Id) == "string" and not seen[npc.Id] and type(npc.Name) == "string" and #npc.Name > 2 and PC.Get(npc.PetId) ~= nil
			and type(npc.Scale) == "number" and math.abs(npc.Scale - CONTRACT.v3.npcScale) <= 0.3 and linesOk and ND.Get(npc.Id) == npc
		data:case(ok, tostring(npc.Id) .. ": Name " .. tostring(npc.Name) .. ", PetId " .. tostring(npc.PetId) .. ", Scale " .. tostring(npc.Scale) .. ", " .. #lines .. " lines")
		seen[tostring(npc.Id)] = true
		T.check(not tostring(npc.Name):lower():find("nimbus", 1, true), tostring(npc.Id) .. ": Nimbus is the tutorial guide, not an NPC")
	end
	data:report()
	T.check(ND.Get("no_such_npc") == nil, "NpcDialog.Get of an unknown id is nil")
	local text = table.concat(allLines, "\n"):lower()
	T.check(text:find("storm altar", 1, true) ~= nil and text:find("secret", 1, true) ~= nil, "an NPC tip mentions the Storm Altar and Secret pets (ARCHITECTURE_V3.md section 10)")
	T.check(text:find("element", 1, true) ~= nil, "an NPC explains pet elements (ARCHITECTURE_V3.md section 11)")
	T.check(text:find("index", 1, true) ~= nil and text:find("dash", 1, true) ~= nil, "the NPC tips cover the Pet Index and the controls (dash)")

	local holder = workspace:FindFirstChild("NimbusNpcs")
	if not T.check(holder ~= nil, "NpcService builds workspace.NimbusNpcs") then
		return
	end
	local models = {}
	for _, inst in ipairs(CollectionService:GetTagged(ND.Tag)) do
		if inst:IsDescendantOf(holder) then
			models[#models + 1] = inst
		end
	end
	T.eq(#models, #ND.Npcs, "every NPC model is tagged " .. ND.Tag .. " inside workspace.NimbusNpcs")
	local npcParts = Mock.CountDescendants(holder, "BasePart")
	T.check(npcParts <= CONTRACT.v3.partBudget.npcs, "the six NPCs stay within " .. CONTRACT.v3.partBudget.npcs .. " parts (budgeted apart from the lobby)", npcParts .. " parts")
	T.info("*NPCs: " .. #models .. " models, " .. npcParts .. " parts")
	local built = T.tally("every NPC: attribute NpcId, a Talk prompt (ObjectText = Name, HoldDuration 0, distance " .. CONTRACT.v3.npcPromptDistance .. "), a nameplate and a High-detail pet at Scale ~" .. CONTRACT.v3.npcScale .. " on its NPC spot")
	local firstPrompt, firstId
	for i, npc in ipairs(ND.Npcs) do
		local model = holder:FindFirstChild("Npc_" .. npc.Id)
		local why = "missing model Npc_" .. npc.Id
		local ok = model ~= nil and model:GetAttribute("NpcId") == npc.Id and CollectionService:HasTag(model, ND.Tag)
		if ok then
			local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
			local plate = model:FindFirstChildWhichIsA("BillboardGui", true)
			local pet = model:FindFirstChild("Pet")
			local petDef = PC.Get(npc.PetId)
			local petParts = pet and Mock.CountDescendants(pet, "BasePart") or 0
			local height = pet and pet:GetExtentsSize().Y or 0
			local want = petDef and PB.GetHeight(petDef) * (npc.Scale or CONTRACT.v3.npcScale) or 0
			local spot = type(info.NpcSpots) == "table" and info.NpcSpots[i]
			local pivot = model:GetPivot().Position
			ok = prompt ~= nil and prompt.ActionText == "Talk" and prompt.ObjectText == npc.Name and prompt.HoldDuration == 0 and prompt.MaxActivationDistance == CONTRACT.v3.npcPromptDistance
				and plate ~= nil and plainText(textsUnder(plate)):find(npc.Name, 1, true) ~= nil
				and pet ~= nil and petParts <= CONTRACT.v3.partBudget.petHigh and petParts > 0 and math.abs(height - want) <= want * 0.25
				and (typeof(spot) ~= "CFrame" or hdist(pivot, spot.Position) <= 4)
			why = string.format("prompt %s (%s / %s / hold %s / %s), nameplate %s, pet %d parts, height %.2f vs %.2f, %s from its spot",
				tostring(prompt ~= nil), prompt and prompt.ActionText or "-", prompt and prompt.ObjectText or "-", prompt and tostring(prompt.HoldDuration) or "-", prompt and tostring(prompt.MaxActivationDistance) or "-",
				tostring(plate ~= nil), petParts, height, want, typeof(spot) == "CFrame" and fmt(hdist(pivot, spot.Position)) or "?")
			if prompt and not firstPrompt then
				firstPrompt, firstId = prompt, npc.Id
			end
		end
		built:case(ok, npc.Id .. ": " .. why)
	end
	built:report()
	local loose = 0
	for _, d in ipairs(holder:GetDescendants()) do
		if d:IsA("BasePart") and not d.Anchored then
			loose = loose + 1
		end
	end
	T.eq(loose, 0, "every NPC part is anchored")
	-- the server never animates an NPC (the client idles them)
	local before = partCFrames(holder)
	advance(2)
	T.eq(movedParts(before), 0, "the server never moves an NPC part (client-side idle animation only)")
	-- the prompt reaches NpcService.Talked
	if firstPrompt and type(NS) == "table" and type(NS.Talked) == "table" then
		local p = Mock.AddPlayer("NpcTalker", 975001)
		advance(0.6)
		local got
		local conn = NS.Talked:Connect(function(who, id)
			got = { who, id }
		end)
		Mock.Trigger(firstPrompt, p)
		advance(0.1)
		conn:Disconnect()
		T.check(got ~= nil and got[1] == p and got[2] == firstId, "triggering an NPC's Talk prompt fires NpcService.Talked(player, npcId)", got and tostring(got[2]) or "no event")
		Mock.RemovePlayer(p)
		advance(0.5)
	end
end

-- ARCHITECTURE_V3.md section 10: the Storm Altar landmark (built by the optional StormAltar service).
local function stormAltarChecks(info, folder)
	local Config = config()
	local altar
	for _, d in ipairs(workspace:GetDescendants()) do
		if d.Name == "StormAltar" and d:IsA("Model") then
			altar = d
			break
		end
	end
	if not altar then
		if moduleInstance("server/Services/StormAltar") then
			T.fail("the StormAltar service builds a Model named StormAltar")
		else
			T.warn("the Storm Altar is not in this build yet (optional StormAltar service, ARCHITECTURE_V3.md section 10)")
		end
		return
	end
	local showcase = altar:FindFirstChild("StormfangShowcase", true) or workspace:FindFirstChild("StormfangShowcase", true)
	local parts, glass, cyanNeon, navy = 0, 0, 0, 0
	for _, d in ipairs(altar:GetDescendants()) do
		if d:IsA("BasePart") and not (showcase and d:IsDescendantOf(showcase)) then
			parts = parts + 1
			local c = d.Color
			if d.Material == Enum.Material.Glass then
				glass = glass + 1
			end
			if d.Material == Enum.Material.Neon and c.B > 0.7 and c.G > 0.45 and c.R < 0.5 then
				cyanNeon = cyanNeon + 1
			end
			if colorDistance255(c, Color3.fromRGB(46, 58, 102)) <= 45 then
				navy = navy + 1
			end
		end
	end
	T.check(parts <= CONTRACT.v3.partBudget.stormAltar and parts >= 30, "the Storm Altar stays within " .. CONTRACT.v3.partBudget.stormAltar .. " parts (showcase pet excluded)", parts .. " parts")
	T.check(navy >= 6, "the Storm Altar stands on a dark navy storm-cloud island", navy .. " navy parts")
	T.check(cyanNeon >= 6 and glass >= 6, "tall cyan crystal shards (Neon core + Glass) ring the dais", cyanNeon .. " cyan neon, " .. glass .. " glass parts")
	local lights, blue = 0, 0
	for _, d in ipairs(altar:GetDescendants()) do
		if d:IsA("PointLight") then
			lights = lights + 1
			if d.Color.B > d.Color.R + 0.2 and d.Brightness <= 4 then
				blue = blue + 1
			end
		end
	end
	T.check(lights >= 1 and blue == lights, "soft electric-blue PointLights", lights .. " lights, " .. blue .. " soft blue")
	if typeof(info.AltarSite) == "CFrame" then
		T.check(hdist(altar:GetPivot().Position, info.AltarSite.Position) <= 45, "the Storm Altar is built at LobbyInfo.AltarSite")
	end
	if T.check(showcase ~= nil and showcase:IsA("Model"), "a big Stormfang showcase (Model StormfangShowcase) prowls on the altar") then
		local n = Mock.CountDescendants(showcase, "BasePart")
		T.check(n <= CONTRACT.v3.partBudget.showcasePet and n > 0, "...built with PetBuilder at High detail (<= " .. CONTRACT.v3.partBudget.showcasePet .. " parts)", n .. " parts")
		local def = mod("PetCatalog").Get(CONTRACT.v3.stormfang.petId)
		if def then
			local want = mod("PetBuilder").GetHeight(def) * 3
			T.check(math.abs(showcase:GetExtentsSize().Y - want) <= want * 0.3, "...at Scale ~3", fmt(showcase:GetExtentsSize().Y, 2) .. " studs tall vs ~" .. fmt(want, 2))
		end
		local before = partCFrames(showcase)
		advance(2)
		T.eq(movedParts(before), 0, "...and the server never animates it (client-side hover / pulse)")
	end
	local sign = altar:FindFirstChild("StormAltarSign", true) or workspace:FindFirstChild("StormAltarSign", true)
	if T.check(sign ~= nil, "the poster StormAltarSign exists") then
		T.check(plainText(textsUnder(sign)):upper():find("STORM ALTAR", 1, true) ~= nil, "...reading 'STORM ALTAR'", plainText(textsUnder(sign)))
		local art = false
		for _, d in ipairs(sign:GetDescendants()) do
			if (d:IsA("ImageLabel") or d:IsA("ImageButton")) and d.Image == Config.Art.StormfangImage then
				art = true
			elseif (d:IsA("Decal") or d:IsA("Texture")) and d.Texture == Config.Art.StormfangImage then
				art = true
			end
		end
		T.check(art, "...and showing the player's Stormfang art (Config.Art.StormfangImage)")
	end
	local prompt
	for _, d in ipairs(altar:GetDescendants()) do
		if d:IsA("ProximityPrompt") and (tostring(d.ObjectText) .. " " .. tostring(d.ActionText)):lower():find("storm altar", 1, true) then
			prompt = d
		end
	end
	if T.check(prompt ~= nil, "the altar has a 'Storm Altar' ProximityPrompt") then
		local p = Mock.AddPlayer("AltarVisitor", 975002)
		advance(0.6)
		local mark = #Mock.RemoteLog
		Mock.Trigger(prompt, p)
		advance(0.3)
		T.check(notifiedSince(p, "awakens soon", mark) ~= nil, "triggering it shows the side toast 'The Storm Altar awakens soon ...' (phase 1)")
		Mock.RemovePlayer(p)
		advance(0.5)
	end
end

-- ARCHITECTURE_V3.md sections 4-6 and 10: named tutorial targets, home plots with an empty flat yard, the NPC spots,
-- the six NPC pets (workspace.NimbusNpcs) and, once it is built, the Storm Altar landmark.
local function lobbyV3(info, folder)
	local Config = config()
	-- tutorial targets keep their names: Portal_<Id> / Roulette_<Id> models under workspace.NimbusLobby
	for _, diff in ipairs(Config.Difficulties) do
		local model = folder:FindFirstChild("Portal_" .. diff.Id, true)
		local p = info.Portals and info.Portals[diff.Id]
		if T.check(model ~= nil and model:IsA("Model"), "Portal_" .. diff.Id .. " is a Model in the lobby (tutorial arrow target)", model and model.ClassName or "missing") then
			T.check(p and p.Zone and hdist(model:GetPivot().Position, p.Zone.Position) <= 20, "Portal_" .. diff.Id .. " stands at its portal zone")
		end
	end
	for _, r in ipairs(Config.Roulettes) do
		local m = info.Shop and info.Shop.Roulettes and info.Shop.Roulettes[r.Id]
		local model = folder:FindFirstChild("Roulette_" .. r.Id, true)
		T.check(model ~= nil and model:IsA("Model") and m ~= nil and m.Model == model, "Roulette_" .. r.Id .. " is the roulette machine Model (tutorial arrow target)", model and model:GetFullName() or "missing")
	end
	-- home plots: a flat PlotSize square yard whose centre stays EMPTY for the phase-2 home
	local plots = T.tally("every SpotInfo has PlotCFrame / PlotSize and its folder carries the SpotIndex attribute")
	local yards = T.tally("the centre of every home yard is flat and empty (room for the phase-2 home)")
	local params = OverlapParams.new()
	do
		-- audit self-test: a block dropped into the first yard centre must be found by the same query
		local sp = info.Spots and info.Spots[1]
		if sp and typeof(sp.PlotCFrame) == "CFrame" then
			local probe = Instance.new("Part")
			probe.Anchored = true
			probe.Size = Vector3.new(4, 4, 4)
			probe.CFrame = sp.PlotCFrame * CFrame.new(3, 2.5, -2)
			probe.Parent = folder
			local found = false
			for _, part in ipairs(workspace:GetPartBoundsInBox(sp.PlotCFrame * CFrame.new(0, 6.5, 0), Vector3.new(Config.Lobby.PlotSize / 2, 11, Config.Lobby.PlotSize / 2), params)) do
				found = found or part == probe
			end
			probe:Destroy()
			T.check(found, "yard audit self-test: a block in the yard centre is detected")
		end
	end
	for i = 1, Config.Lobby.SpotCount do
		local sp = info.Spots and info.Spots[i]
		if sp then
			local ok = typeof(sp.PlotCFrame) == "CFrame" and sp.PlotSize == Config.Lobby.PlotSize and typeof(sp.Folder) == "Instance" and sp.Folder:GetAttribute("SpotIndex") == i
			plots:case(ok, "spot " .. i .. ": PlotCFrame " .. typeof(sp.PlotCFrame) .. ", PlotSize " .. tostring(sp.PlotSize) .. ", SpotIndex attr " .. tostring(typeof(sp.Folder) == "Instance" and sp.Folder:GetAttribute("SpotIndex")))
			if typeof(sp.PlotCFrame) == "CFrame" then
				local half = Config.Lobby.PlotSize / 4
				local flat, note = true, ""
				for _, dx in ipairs({ -half, 0, half }) do
					for _, dz in ipairs({ -half, 0, half }) do
						local pos = (sp.PlotCFrame * CFrame.new(dx, 0, dz)).Position
						local hit, result = groundBelow(pos + Vector3.new(0, 1, 0), 8)
						if not hit or math.abs(result.Position.Y - sp.PlotCFrame.Position.Y) > 0.35 then
							flat = false
							note = string.format("no flat ground at (%d, %d): %s", dx, dz, hit and fmt(result.Position.Y - sp.PlotCFrame.Position.Y, 2) or "nothing")
						end
					end
				end
				local inside = workspace:GetPartBoundsInBox(sp.PlotCFrame * CFrame.new(0, 6.5, 0), Vector3.new(Config.Lobby.PlotSize / 2, 11, Config.Lobby.PlotSize / 2), params)
				local blockers = {}
				for _, part in ipairs(inside) do
					if part:IsDescendantOf(folder) and part.Transparency < 1 then
						blockers[#blockers + 1] = part.Name
					end
				end
				yards:case(flat and #blockers == 0, "spot " .. i .. ": " .. note .. (#blockers > 0 and (" " .. #blockers .. " parts in the yard centre, e.g. " .. table.concat(blockers, ", ", 1, math.min(3, #blockers))) or ""))
			end
		end
	end
	plots:report()
	yards:report()
	-- NPC spots: six ground-level CFrames on the plaza, apart from each other
	local spots = info.NpcSpots
	if T.check(type(spots) == "table" and #spots == CONTRACT.v3.npcCount, "LobbyInfo.NpcSpots holds " .. CONTRACT.v3.npcCount .. " CFrames", type(spots) == "table" and (#spots .. " entries") or tostring(spots)) then
		local spotTally = T.tally("every NPC spot is a CFrame on solid plaza ground, at least 10 studs from the others")
		for i, cf in ipairs(spots) do
			local ok = typeof(cf) == "CFrame"
			local why = "not a CFrame"
			if ok then
				local horiz = hdist(cf.Position, Config.Lobby.Origin)
				ok = horiz <= Config.Lobby.PlazaRadius + 12 and groundBelow(cf.Position + Vector3.new(0, 1, 0), 8)
				why = "distance " .. fmt(horiz) .. " from the plaza centre, ground " .. tostring(groundBelow(cf.Position + Vector3.new(0, 1, 0), 8))
				for j = 1, i - 1 do
					if typeof(spots[j]) == "CFrame" and hdist(spots[j].Position, cf.Position) < 10 then
						ok, why = false, "only " .. fmt(hdist(spots[j].Position, cf.Position)) .. " studs from spot " .. j
					end
				end
			end
			spotTally:case(ok, "NPC spot " .. i .. ": " .. why)
		end
		spotTally:report()
	end
	-- the v3 LobbyInfo keys and their types (tools/contract.json v3.lobbyInfo; the Storm Altar site is reserved by
	-- LobbyBuilder and used by the optional StormAltar service)
	for key, ty in pairs(CONTRACT.v3.lobbyInfo) do
		if key:sub(1, 1) ~= "_" then
			local optional = ty:sub(-1) == "?"
			local want = optional and ty:sub(1, -2) or ty
			local got = typeof(info[key])
			T.check(got == want or (optional and info[key] == nil), "LobbyInfo." .. key .. " is a " .. want .. (optional and " (or nil)" or ""), got)
		end
	end
	if typeof(info.AltarSite) == "CFrame" then
		local site = info.AltarSite
		local toPlaza = Vector3.new(Config.Lobby.Origin.X - site.Position.X, 0, Config.Lobby.Origin.Z - site.Position.Z)
		T.check(toPlaza.Magnitude > Config.Lobby.PlazaRadius and site.LookVector:Dot(toPlaza.Unit) > 0.7, "the Storm Altar site is at the lobby edge, facing the plaza", "distance " .. fmt(toPlaza.Magnitude))
	end
	npcChecks(info)
	stormAltarChecks(info, folder)
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
	-- size + budget (ARCHITECTURE_V3.md ART DIRECTION: the detailed voxel lobby stays <= ~6000 parts after merging; the
	-- Storm Altar has its own budget and the NPC pets live in workspace.NimbusNpcs, so neither counts here)
	local altarParts = 0
	for _, d in ipairs(folder:GetDescendants()) do
		if d.Name == "StormAltar" and d:IsA("Model") then
			altarParts = altarParts + Mock.CountDescendants(d, "BasePart")
		end
	end
	local parts = Mock.CountDescendants(folder, "BasePart") - altarParts
	T.check(parts <= CONTRACT.v3.partBudget.lobby, "lobby has at most " .. CONTRACT.v3.partBudget.lobby .. " parts (Storm Altar excluded)", parts .. " parts")
	T.check(parts > 2000, "the v3 voxel lobby is detailed (more than 2000 parts)", parts .. " parts")
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
	-- palette: first prove the audit itself (a thin neon rod is not a slab; a big neon disc / pillar / ball / block is)
	do
		local probe = Instance.new("Folder")
		local function neon(name, shape, size)
			local part = Instance.new("Part")
			part.Name = name
			part.Material = Enum.Material.Neon
			part.Shape = shape
			part.Size = size
			part.Parent = probe
		end
		neon("ThinRod", Enum.PartType.Cylinder, Vector3.new(17.2, 0.55, 0.55)) -- CourseBuilder LavaStreak: length along X
		neon("SmallBlock", Enum.PartType.Block, Vector3.new(4, 4, 4))
		local ok = paletteAudit(probe, { maxNeonFace = 220 })
		T.eq(ok.neonCount, 2, "palette audit self-test: counts the neon parts")
		T.eq(ok.bigNeonCount, 0, "palette audit self-test: a 0.55 x 17.2 neon rod (face ~9.5 studs^2) is not a big neon surface")
		neon("BigDisc", Enum.PartType.Cylinder, Vector3.new(0.5, 20, 20)) -- 314 studs^2 cap
		neon("BigPillar", Enum.PartType.Cylinder, Vector3.new(40, 6, 6)) -- 240 studs^2 side
		neon("BigBall", Enum.PartType.Ball, Vector3.new(20, 20, 20)) -- 314 studs^2 circle
		neon("BigBlock", Enum.PartType.Block, Vector3.new(20, 20, 1)) -- 400 studs^2 face
		T.eq(paletteAudit(probe, { maxNeonFace = 220 }).bigNeonCount, 4, "palette audit self-test: a big disc, pillar, ball and block are all flagged")
		probe:Destroy()
	end
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
	local freeProblems = T.tally("unowned spots read 'Free home' / 'Step in to claim'")
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
				freeProblems:case(sp.NameLabel.Text == "Free home" and sp.SubLabel.Text == "Step in to claim", "spot " .. i .. " reads '" .. sp.NameLabel.Text .. "' / '" .. sp.SubLabel.Text .. "'")
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

	lobbyV3(info, folder)

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
	local diff = isStr(r.DifficultyId) and config().GetDifficulty(r.DifficultyId)
	if not diff then
		p[#p + 1] = "DifficultyId " .. tostring(r.DifficultyId) .. " is not a Config.Difficulties id"
	elseif r.Stars ~= diff.Stars then
		p[#p + 1] = "Stars is " .. tostring(r.Stars) .. ", expected " .. diff.Stars
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

-- ARCHITECTURE_V2.md section 1: the ProfileSync snapshot. Plain tables only (no Instances), capped perks.
function V.profileSync(s)
	local Config = config()
	local PC = M["shared/PetCatalog"]
	local p = {}
	if type(s) ~= "table" then
		return { "payload is " .. type(s) }
	end
	local function plain(v, path)
		local t = typeof(v)
		if t == "table" then
			for k, x in pairs(v) do
				plain(x, path .. "." .. tostring(k))
			end
		elseif t ~= "number" and t ~= "string" and t ~= "boolean" then
			p[#p + 1] = path .. " is a " .. t .. " (a snapshot holds plain data only)"
		end
	end
	plain(s, "snapshot")
	local function int(v, lo, hi)
		return type(v) == "number" and v == v and v == math.floor(v) and v >= lo and v <= hi
	end
	if not int(s.Tokens, 0, 1e9) then
		p[#p + 1] = "Tokens is " .. tostring(s.Tokens)
	end
	if type(s.Pets) ~= "table" then
		p[#p + 1] = "Pets is not a table"
	else
		for id, n in pairs(s.Pets) do
			if type(id) ~= "string" or not int(n, 1, Config.Pets.MaxPerStack) then
				p[#p + 1] = "Pets[" .. tostring(id) .. "] = " .. tostring(n)
			end
		end
	end
	if type(s.Equipped) ~= "table" then
		p[#p + 1] = "Equipped is not a table"
	else
		if #s.Equipped > Config.Pets.MaxEquipped then
			p[#p + 1] = "Equipped lists " .. #s.Equipped .. " pets (max " .. Config.Pets.MaxEquipped .. ")"
		end
		local used = {}
		for i, id in ipairs(s.Equipped) do
			used[id] = (used[id] or 0) + 1
			if type(id) ~= "string" or used[id] > ((type(s.Pets) == "table" and s.Pets[id]) or 0) then
				p[#p + 1] = "Equipped[" .. i .. "] = " .. tostring(id) .. " is not owned that often"
			end
		end
		local keys = 0
		for _ in pairs(s.Equipped) do
			keys = keys + 1
		end
		if keys ~= #s.Equipped then
			p[#p + 1] = "Equipped is not an array"
		end
	end
	if type(s.Items) ~= "table" then
		p[#p + 1] = "Items is not a table"
	else
		for id, n in pairs(s.Items) do
			if type(id) ~= "string" or not int(n, 0, Config.Items.MaxCarry) then
				p[#p + 1] = "Items[" .. tostring(id) .. "] = " .. tostring(n)
			end
		end
	end
	local st = s.Stats
	if type(st) ~= "table" then
		p[#p + 1] = "Stats is not a table"
	else
		for _, k in ipairs({ "Matches", "Wins", "TokensEarned", "Spins" }) do
			if not int(st[k], 0, 1e12) then
				p[#p + 1] = "Stats." .. k .. " = " .. tostring(st[k])
			end
		end
		if type(st.BestTimes) ~= "table" then
			p[#p + 1] = "Stats.BestTimes is not a table"
		else
			for id, sec in pairs(st.BestTimes) do
				if not Config.GetDifficulty(id) or type(sec) ~= "number" or sec <= 0 then
					p[#p + 1] = "Stats.BestTimes[" .. tostring(id) .. "] = " .. tostring(sec)
				end
			end
		end
		if type(st.Wins) == "number" and type(st.Matches) == "number" and st.Wins > st.Matches then
			p[#p + 1] = "Stats.Wins " .. st.Wins .. " exceeds Stats.Matches " .. st.Matches
		end
	end
	if s.SpotIndex ~= nil and not int(s.SpotIndex, 1, Config.Lobby.SpotCount) then
		p[#p + 1] = "SpotIndex = " .. tostring(s.SpotIndex)
	end
	-- v3 (ARCHITECTURE_V3.md section 1): Discovered / IndexClaimed sets of known ids, the tutorial progress
	if type(s.Discovered) ~= "table" then
		p[#p + 1] = "Discovered is not a table"
	else
		for id, v in pairs(s.Discovered) do
			if v ~= true or (PC and not PC.Get(id)) then
				p[#p + 1] = "Discovered[" .. tostring(id) .. "] = " .. tostring(v)
			end
		end
		for id in pairs(type(s.Pets) == "table" and s.Pets or {}) do
			if s.Discovered[id] ~= true and PC and PC.Get(id) then
				p[#p + 1] = "owned pet " .. tostring(id) .. " is not in Discovered (owned pets always count as discovered)"
			end
		end
	end
	if type(s.IndexClaimed) ~= "table" then
		p[#p + 1] = "IndexClaimed is not a table"
	else
		for id, v in pairs(s.IndexClaimed) do
			if v ~= true or (PC and type(PC.GetRarity) == "function" and not PC.GetRarity(id)) then
				p[#p + 1] = "IndexClaimed[" .. tostring(id) .. "] = " .. tostring(v)
			end
		end
	end
	local tut = s.Tutorial
	if type(tut) ~= "table" or not int(tut.Step, 1, 1000) or not isBool(tut.Done) or not isBool(tut.Gifted) then
		p[#p + 1] = "Tutorial is not { Step = int >= 1, Done = bool, Gifted = bool }"
	end
	if type(s.Perks) ~= "table" then
		p[#p + 1] = "Perks is not a table"
	else
		for key, cap in pairs(Config.Pets.PerkCaps) do
			local v = s.Perks[key]
			if type(v) ~= "number" or v ~= v or v < 0 or v > cap + 1e-9 then
				p[#p + 1] = "Perks." .. key .. " = " .. tostring(v) .. " (0.." .. cap .. ")"
			end
		end
		if PC and type(s.Equipped) == "table" then
			local want = PC.SumPerks(s.Equipped)
			for key in pairs(Config.Pets.PerkCaps) do
				if type(s.Perks[key]) == "number" and math.abs(s.Perks[key] - (want[key] or 0)) > 1e-6 then
					p[#p + 1] = "Perks." .. key .. " = " .. s.Perks[key] .. " but the equipped pets sum to " .. tostring(want[key])
				end
			end
		end
	end
	return p
end

-- ARCHITECTURE_V2.md section 2: RouletteResult { Ok, Reason, RouletteId, PetId, IsNew, Count, Tokens, Strip }
function V.rouletteResult(r)
	local PC = M["shared/PetCatalog"]
	local p = {}
	if type(r) ~= "table" then
		return { "payload is " .. type(r) }
	end
	if not isBool(r.Ok) then
		p[#p + 1] = "Ok is " .. typeof(r.Ok)
		return p
	end
	if r.Ok then
		if not isStr(r.RouletteId) or not isStr(r.PetId) or not isBool(r.IsNew) or not isNum(r.Count) or r.Count < 1 or not isNum(r.Tokens) or r.Tokens < 0 then
			p[#p + 1] = "RouletteId / PetId / IsNew / Count / Tokens"
		end
		if type(r.Strip) ~= "table" or #r.Strip < 34 then
			p[#p + 1] = "Strip has " .. tostring(type(r.Strip) == "table" and #r.Strip or r.Strip) .. " entries (needs >= 34)"
		elseif PC and isStr(r.RouletteId) then
			local possible = {}
			for _, def in ipairs(PC.PossiblePets(r.RouletteId)) do
				possible[def.Id] = true
			end
			if r.Strip[34] ~= r.PetId then
				p[#p + 1] = "Strip[34] is " .. tostring(r.Strip[34]) .. ", not the won pet " .. tostring(r.PetId)
			end
			for i, id in ipairs(r.Strip) do
				if not possible[id] then
					p[#p + 1] = "Strip[" .. i .. "] = " .. tostring(id) .. " cannot come out of " .. tostring(r.RouletteId)
					break
				end
			end
		end
	elseif not isStr(r.Reason) then
		p[#p + 1] = "a failed spin needs a Reason string"
	end
	return p
end

-- ARCHITECTURE_V3.md section 4: TutorialState { Step, Total = #Steps, Id, Text, Target, Done } (+ documented extras).
local TARGET_KINDS = { Spot = true, Shop = true, Roulette = true, Portal = true, Menu = true }
function V.tutorialState(st)
	local p = {}
	if type(st) ~= "table" then
		return { "payload is " .. type(st) }
	end
	local steps = M["shared/TutorialSteps"] and M["shared/TutorialSteps"].Steps
	if not (isNum(st.Step) and st.Step >= 1 and st.Step == math.floor(st.Step)) then
		p[#p + 1] = "Step is " .. tostring(st.Step)
	end
	if not (isNum(st.Total) and (steps == nil or st.Total == #steps)) then
		p[#p + 1] = "Total is " .. tostring(st.Total) .. (steps and (", expected #Steps = " .. #steps) or "")
	end
	if isNum(st.Step) and isNum(st.Total) and st.Step > st.Total then
		p[#p + 1] = "Step " .. st.Step .. " > Total " .. st.Total
	end
	if not isStr(st.Id) or (steps and isNum(st.Step) and steps[st.Step] and steps[st.Step].Id ~= st.Id) then
		p[#p + 1] = "Id " .. tostring(st.Id) .. " is not TutorialSteps.Steps[Step].Id"
	end
	if not isStr(st.Text) or #st.Text < 8 or st.Text:find("{%a+}") then
		p[#p + 1] = "Text is missing or has an unfilled {placeholder}: " .. tostring(st.Text)
	end
	if not isBool(st.Done) then
		p[#p + 1] = "Done is " .. typeof(st.Done)
	end
	if st.Target ~= nil and (type(st.Target) ~= "table" or not TARGET_KINDS[st.Target.Kind]) then
		p[#p + 1] = "Target.Kind is " .. tostring(type(st.Target) == "table" and st.Target.Kind or st.Target)
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
	elseif e.remote == "ProfileSync" then
		out = V.profileSync(a[1])
	elseif e.remote == "RouletteResult" then
		out = V.rouletteResult(a[1])
	elseif e.remote == "TutorialState" then
		out = V.tutorialState(a[1])
	elseif e.remote == "OpenPanel" then
		if not isStr(a[1]) then
			out[#out + 1] = "panelId is " .. typeof(a[1])
		end
		if a[2] ~= nil and type(a[2]) ~= "table" then
			out[#out + 1] = "args is " .. typeof(a[2])
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
		-- v3 lock-in: members cannot walk out (smoke_polish_portals.lua); RemovePlayer frees the seat without a lockout
		PortalService.RemovePlayer(alice)
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
	-- v3 lock-in: walking out is not possible, the server puts the member back on the pad
	leavePortalArea(alice)
	advance(0.8)
	T.eq(#PortalService.GetParty("Medium").Players, 1, "a locked member cannot walk out of the zone (still in the party)")
	T.check(planar(root(alice).Position, info.Center) <= 9, "the safety net puts a locked member back on the pad", "distance " .. fmt(planar(root(alice).Position, info.Center)))
	-- leaving the party (RemovePlayer: no lockout, no teleport) sends PartyState(nil)
	mark = logSize()
	PortalService.RemovePlayer(alice)
	leavePortalArea(alice)
	advance(0.8)
	T.eq(#PortalService.GetParty("Medium").Players, 0, "leaving the party empties it")
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
-- scenario: MatchService fall rule (stacked laps)
--
-- Laps of a Spiral / overlapping course are stacked 15-40 studs above each other, so a missed jump usually lands on a
-- LOWER lap long before the KillY plane and the player was stranded behind the team. The rule: per player the server
-- remembers the height they last stood at; touching ground again MORE than 12 studs below it after being in the air is a
-- fall, treated exactly like a void fall (VoidDamage + back to the team checkpoint, once). It must never fire
--   * mid-air (only a landing is judged), on a teleport / respawn from ground to ground (no poll moved down in the air),
--     on ordinary hops (< 12 studs: stairs, cannon landings are <= 3-4 below the pad), bounce / cannon flights,
--   * for downed players, or relative to the TEAM checkpoint (stragglers on the previous stage are 15+ studs below it).
-- In Ended state the same landing is rescued for free (no damage).
-- The floors are test slabs far away from the course: the mock raycast (GROUND_REACH 6) finds them like real parts.
----------------------------------------------------------------------------------------------------
S.fall_rule = guarded("fall_rule", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local Workspace = game:GetService("Workspace")
	local players = freshPlayers(2, "Fall")
	local a, b = players[1], players[2]
	local m = startMatch("Easy", players)
	if not T.check(m ~= nil, "fall rule: an Easy match starts") then
		removePlayers(players)
		return
	end
	toPlaying(m)
	waitNotInvulnerable(a) -- the start protection would absorb the void hit
	waitNotInvulnerable(b)
	advance(0.6)
	local voidDamage = Config.Damage.VoidDamage.Easy
	local killY = m.Course.KillY
	local startPos = m.Course.StartCFrame.Position
	local STAND = 3 -- a standing root is ~3 studs above the floor top
	local arena = Instance.new("Folder")
	arena.Name = "FallRuleArena"
	arena.Parent = Workspace
	local lane = 0
	local function floorAt(topY)
		lane = lane + 1
		local f = Instance.new("Part")
		f.Name = "FallFloor" .. lane
		f.Anchored = true
		f.CanCollide = true
		f.Size = Vector3.new(60, 2, 60)
		f.Position = Vector3.new(startPos.X + 900 + lane * 80, topY - 1, startPos.Z)
		f.Parent = arena
		return f
	end
	local function topOf(f)
		return f.Position.Y + f.Size.Y / 2
	end
	local function standOn(f)
		return Vector3.new(f.Position.X, topOf(f) + STAND, f.Position.Z)
	end
	local function above(f, height)
		return Vector3.new(f.Position.X, topOf(f) + height, f.Position.Z)
	end
	-- teleports the player and sets the vertical speed, then lets the 4 Hz match poll look at it
	local function step(player, pos, vy, polls)
		Mock.Teleport(player, pos)
		root(player).AssemblyLinearVelocity = Vector3.new(0, vy or 0, 0)
		advance(0.3 * (polls or 1))
	end
	local function voidsSince(player, mark)
		local n = 0
		for _, e in ipairs(remotesFor("DamageTaken", player.UserId, mark)) do
			if e.args[2] == "Void" and e.args[1] == voidDamage then
				n = n + 1
			end
		end
		return n
	end
	local function atCheckpoint(player)
		local r = root(player)
		return r ~= nil and distance(r.Position, startPos) <= 14
	end
	local function fresh(player)
		DS().SetHealthFraction(player, 1)
		return logSize()
	end
	-- no fall: no Void damage, the player was not moved (still where the last step put them)
	local function expectStay(label, player, mark, where)
		T.eq(voidsSince(player, mark), 0, label .. ": no void damage")
		T.check(distance(root(player).Position, where) <= 1, label .. ": the player is not moved", fmt(distance(root(player).Position, where)))
		T.near(hum(player).Health, hum(player).MaxHealth, 0.5, label .. ": health untouched")
	end
	-- fall: exactly one VoidDamage hit, back at the team checkpoint (Start while Checkpoint == 0), then no repeat
	local function expectFall(label, player, mark)
		advance(0.9) -- more polls: the rescue happens ONCE and clears the memory
		T.eq(voidsSince(player, mark), 1, label .. ": exactly one void hit")
		T.check(atCheckpoint(player), label .. ": back at the team checkpoint", fmt(distance(root(player).Position, startPos)))
		T.near(hum(player).Health, hum(player).MaxHealth - voidDamage, 1.5, label .. ": VoidDamage[Easy] (" .. voidDamage .. ") is applied")
	end

	local T0 = killY + 150 -- the "upper lap"
	T.eq(m.Checkpoint, 0, "fall rule: the team starts at the Start platform (checkpoint 0)")

	-- 1. a missed jump onto a lap 20 studs lower
	do
		local up, low = floorAt(T0), floorAt(T0 - 20)
		local mark = fresh(a)
		step(a, standOn(up), 0, 2)
		expectStay("stand on the upper lap", a, mark, standOn(up))
		step(a, above(low, 14), -60, 1) -- falling over the lower lap
		T.eq(voidsSince(a, mark), 0, "20 studs lower: nothing happens in mid-air")
		T.check(distance(root(a).Position, above(low, 14)) <= 1, "...the player is not rescued before landing")
		step(a, standOn(low), 0, 1)
		expectFall("20 studs lower", a, mark)
		T.check(a:GetAttribute("Downed") == false and m.State == "Playing", "...one fall does not down the player or end the match")
	end

	-- 2. every hop below 12 studs is fine, each measured from the LAST standing height (stairs down: 3 x 11 = 33)
	do
		local f0, f1, f2, f3 = floorAt(T0), floorAt(T0 - 11), floorAt(T0 - 22), floorAt(T0 - 33)
		local mark = fresh(a)
		step(a, standOn(f0), 0, 2)
		step(a, above(f1, 10), -45, 1)
		step(a, standOn(f1), 0, 2)
		expectStay("hop 11 studs down", a, mark, standOn(f1))
		step(a, above(f2, 10), -45, 1)
		step(a, standOn(f2), 0, 2)
		expectStay("another 11 down (22 below the first lap)", a, mark, standOn(f2))
		step(a, above(f3, 10), -45, 1)
		step(a, standOn(f3), 0, 2)
		expectStay("and another 11 down (33 below)", a, mark, standOn(f3))
	end

	-- 3. the limit is a strict 12 studs: 11.5 is a hop, 12.5 a fall
	do
		local f0, near = floorAt(T0), floorAt(T0 - 11.5)
		local mark = fresh(a)
		step(a, standOn(f0), 0, 2)
		step(a, above(near, 10), -45, 1)
		step(a, standOn(near), 0, 2)
		expectStay("11.5 studs lower", a, mark, standOn(near))
		local g0, far = floorAt(T0), floorAt(T0 - 12.5)
		step(a, standOn(g0), 0, 2)
		step(a, above(far, 10), -45, 1)
		step(a, standOn(far), 0, 1)
		expectFall("12.5 studs lower", a, mark)
	end

	-- 4. ground to ground without a poll in the air (teleport, respawn, lag spike): never read as a fall
	do
		local up, low = floorAt(T0), floorAt(T0 - 30)
		local mark = fresh(a)
		step(a, standOn(up), 0, 2)
		step(a, standOn(low), 0, 2)
		expectStay("teleport 30 studs down from ground to ground", a, mark, standOn(low))
		-- ...and the new height is the reference from now on
		local lower = floorAt(T0 - 30 - 5)
		step(a, above(lower, 10), -45, 1)
		step(a, standOn(lower), 0, 2)
		expectStay("then a 5 stud hop from the new height", a, mark, standOn(lower))
	end

	-- 5. a long drop over empty space is never judged mid-air (only KillY punishes it); the LANDING is judged
	do
		local up, low = floorAt(T0), floorAt(T0 - 40)
		local mark = fresh(a)
		step(a, standOn(up), 0, 2)
		for i = 1, 3 do
			step(a, above(up, -15 - 12 * i), -100, 1) -- 15..51 studs below the upper lap, nothing under the feet
			T.eq(voidsSince(a, mark), 0, "falling through empty space, poll " .. i .. ": no judgement in mid-air")
		end
		step(a, standOn(low), 0, 1)
		expectFall("40 studs lower after a long drop", a, mark)
	end

	-- 6. a jump (rising / apex, no poll moving down) that ends on a lower lap is a teleport-like landing: no fall
	do
		local up, low = floorAt(T0), floorAt(T0 - 25)
		local mark = fresh(a)
		step(a, standOn(up), 0, 2)
		step(a, above(up, 9), 60, 1) -- rising
		step(a, above(up, 12), 0, 1) -- apex
		step(a, standOn(low), 0, 2)
		expectStay("rising / apex polls only", a, mark, standOn(low))
	end

	-- 7. a poll that catches the fall right above the floor (> 30 studs/s down) is never judged itself, the settled one is
	do
		local up, low = floorAt(T0), floorAt(T0 - 22)
		local mark = fresh(a)
		step(a, standOn(up), 0, 2)
		step(a, above(low, 4), -70, 1) -- 4 studs above the lower floor, falling fast: the ray finds a floor
		T.eq(voidsSince(a, mark), 0, "fast fall right above the floor: that poll is not judged")
		step(a, standOn(low), 0, 1)
		expectFall("settled on the lower lap after a fast fall", a, mark)
	end

	-- 8. bounce pads / cannons / dashes: flights up and a few studs down are safe, and landing higher moves the reference up
	do
		local pad, high, deep = floorAt(T0), floorAt(T0 + 9), floorAt(T0 + 9 - 13)
		local mark = fresh(a)
		step(a, standOn(pad), 0, 2)
		step(a, above(pad, 40), 90, 1) -- bounce: rising fast
		step(a, above(high, 30), 0, 1) -- apex
		step(a, above(high, 12), -45, 1) -- coming down onto a platform 9 studs higher
		step(a, standOn(high), 0, 2)
		expectStay("bounce onto a platform 9 studs higher", a, mark, standOn(high))
		-- the reference moved up with the landing: 13 studs below the HIGH platform is a fall (only 4 below the pad)
		step(a, above(deep, 12), -60, 1)
		step(a, standOn(deep), 0, 1)
		expectFall("13 studs below the platform the bounce landed on", a, mark)
		-- a cannon flight ends at most ~3-4 studs below its pad
		local launch, land = floorAt(T0), floorAt(T0 - 4)
		mark = fresh(a)
		step(a, standOn(launch), 0, 2)
		step(a, above(launch, 25), 70, 1)
		step(a, above(land, 12), -50, 1)
		step(a, standOn(land), 0, 2)
		expectStay("cannon landing 4 studs below the take-off", a, mark, standOn(land))
	end

	-- 9. the reference is the player's OWN last standing height, not the team checkpoint (stragglers on an earlier stage
	--    stand far below it): these slabs are ~30 studs below the Start platform that is the team checkpoint
	do
		local low1, low2 = floorAt(killY + 30), floorAt(killY + 27)
		T.check(topOf(low1) < startPos.Y - 20, "fall rule: the straggler floors are far below the team checkpoint", fmt(topOf(low1)) .. " vs " .. fmt(startPos.Y))
		local mark = fresh(a)
		step(a, standOn(low1), 0, 2)
		step(a, above(low2, 10), -45, 1)
		step(a, standOn(low2), 0, 2)
		expectStay("3 stud hop on a stage far below the team checkpoint", a, mark, standOn(low2))
	end

	-- 10. a respawned character starts with a clean slate: without that the respawn at the team checkpoint (90 studs below
	--     the remembered height, memory says "airborne") would count as a fall
	do
		local up, low = floorAt(T0), floorAt(T0 - 30)
		local mark = fresh(a)
		step(a, standOn(up), 0, 2)
		step(a, above(low, 14), -60, 1) -- in the air, remembered as airborne
		local old = a.Character
		Mock.Kill(a)
		T.check(waitFor(function()
			return a.Character ~= nil and a.Character ~= old and hum(a) ~= nil and hum(a).Health > 0
		end, 12), "respawn: the character is replaced")
		advance(1.2)
		T.eq(voidsSince(a, mark), 0, "respawn: coming back at the team checkpoint is not a fall")
		fresh(a)
		step(a, standOn(low), 0, 2) -- a ground-to-ground "landing" 30 below the old reference
		expectStay("first landing of a respawned character", a, mark, standOn(low))
	end

	-- 11. downed players are not judged (they wait frozen for a revive)
	do
		local up, low = floorAt(T0), floorAt(T0 - 30)
		waitNotInvulnerable(b)
		step(b, standOn(up), 0, 2)
		DS().Damage(b, 999, "Other", { IgnoreIFrames = true })
		advance(0.5)
		T.eq(DS().IsDowned(b), true, "downed player: b is downed")
		local mark = logSize()
		step(b, above(low, 14), -60, 1)
		step(b, standOn(low), 0, 2)
		T.eq(voidsSince(b, mark), 0, "downed player: a landing on a lower lap is not a fall (no void damage)")
		T.check(distance(root(b).Position, standOn(low)) <= 1, "...and they are not moved")
	end

	-- 12. the match is over (Ended): the same landing is rescued for free
	do
		local up, low = floorAt(T0), floorAt(T0 - 30)
		local mark = fresh(a)
		step(a, standOn(up), 0, 2)
		m.StartedAt = m.StartedAt - Config.GetDifficulty("Easy").TimeLimit - 5 -- the clock ran out
		advance(0.8)
		T.eq(m.State, "Ended", "ended: the time limit ended the match")
		step(a, standOn(up), 0, 2)
		step(a, above(low, 14), -60, 1)
		step(a, standOn(low), 0, 1)
		advance(0.9)
		T.check(atCheckpoint(a), "ended: a landing on a lower lap brings the player back to the team checkpoint", fmt(distance(root(a).Position, startPos)))
		T.eq(voidsSince(a, mark), 0, "...without any damage (results screen)")
	end

	arena:Destroy()
	endAllMatches(players)
	removePlayers(players)
	flushErrors("fall_rule")
	flushWarnings("fall_rule")
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
-- scenario: DataStore persistence
----------------------------------------------------------------------------------------------------
local function storedProfile(userId)
	return Mock.DataStore.Data[config().Tokens.DataStoreName .. "/u_" .. userId]
end

local function storedTokens(userId)
	local entry = storedProfile(userId)
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
	T.eq(storedTokens(777001), 12, "PlayerRemoving saves the profile under Config.Tokens.DataStoreName / 'u_<UserId>'", tostring(storedTokens(777001)))
	local saved = storedProfile(777001)
	T.check(type(saved) == "table" and saved.Version == 2 and type(saved.Pets) == "table" and type(saved.Equipped) == "table" and type(saved.Items) == "table" and type(saved.Stats) == "table",
		"the stored profile is a v2 profile (Version, Tokens, Pets, Equipped, Items, Stats)", saved and ("Version " .. tostring(saved.Version)) or "nothing stored")
	T.check(Mock.DataStore.Data[Config.Tokens.LegacyDataStoreName .. "/u_777001"] == nil, "the legacy v1 store is never written")
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
-- scenario: DataService orphan retention (a player who leaves during a DataStore outage)
--
-- The cache entry of a leaving player used to be dropped right after the final save, even when that save failed:
-- the session's tokens / pets were lost for good, and a quick rejoin during the outage started from a stale or empty
-- profile. Now a dirty entry stays behind as an "orphan": a rejoin gets it back, a background retry (backoff, 10 s
-- first) and the autosave sweep flush it, BindToClose flushes it (see the `shutdown` scenario), and it is dropped only
-- after a successful write or after ORPHAN_TIMEOUT (30 minutes) with a "giving up" warning.
----------------------------------------------------------------------------------------------------
S.data_orphans = guarded("data_orphans", function()
	if not needBoot() then
		return
	end
	local Config = config()
	local DataService = mod("DataService")
	local DSt = Mock.DataStore
	local function key(id)
		return Config.Tokens.DataStoreName .. "/u_" .. id
	end
	local function join(name, userId)
		local p = Mock.AddPlayer(name, userId)
		advance(1.5)
		return p
	end
	-- simulates a write by another server: the next join must read exactly this
	local function setStored(userId, tokens)
		local e = DSt.Data[key(userId)]
		if e then
			e.Tokens = tokens
		else
			DSt.Data[key(userId)] = { Version = 2, Tokens = tokens }
		end
	end

	-- A: leaves during the outage with 12 unsaved tokens; a quick rejoin during the outage gets them back; leaves again;
	--    the background retry stores them once the store is back and the entry is released after that
	local a = join("OrphanA", 880001)
	DataService.AddTokens(a, 12)
	DSt.Fail = true
	Mock.RemovePlayer(a)
	advance(6)
	T.eq(storedTokens(880001), nil, "orphan A: nothing is stored while the DataStore is down")
	local a2 = join("OrphanA", 880001)
	T.eq(a2:GetAttribute("CloudTokens"), 12, "orphan A: a quick rejoin during the outage gets the unsaved tokens back (CloudTokens)")
	T.eq(DataService.GetTokens(a2), 12, "...and DataService.GetTokens agrees")
	T.eq(a2:FindFirstChild("leaderstats") and a2.leaderstats.Tokens.Value, 12, "...and the leaderboard too")
	Mock.RemovePlayer(a2)
	advance(6)
	DSt.Fail = false
	advance(40)
	T.eq(storedTokens(880001), 12, "orphan A: the background retry stores the tokens once the DataStore is back", tostring(storedTokens(880001)))
	setStored(880001, 99)
	local a3 = join("OrphanA", 880001)
	T.eq(a3:GetAttribute("CloudTokens"), 99, "orphan A: after the successful flush the entry is released (the next join reads the store afresh)")
	Mock.RemovePlayer(a3)
	advance(2)

	-- B: the LOAD failed (outage), the session earned 4 tokens and left during the outage; the store holds 7.
	--    The failed-load session is merged on top of the stored profile, never over it.
	DSt.Data[key(880002)] = { Version = 2, Tokens = 7 }
	DSt.Fail = true
	local b = Mock.AddPlayer("OrphanB", 880002)
	advance(4)
	DataService.AddTokens(b, 4)
	Mock.RemovePlayer(b)
	advance(8)
	T.eq(storedTokens(880002), 7, "orphan B: the stored profile is untouched during the outage")
	DSt.Fail = false
	advance(40)
	T.eq(storedTokens(880002), 11, "orphan B: the failed-load session is merged on top of the stored 7 tokens (7 + 4)", tostring(storedTokens(880002)))

	-- C: a clean leave (the store holds everything) frees the entry at once, so the next join reads the store
	local c = join("CleanC", 880003)
	DataService.AddTokens(c, 5)
	Mock.RemovePlayer(c)
	advance(2)
	T.eq(storedTokens(880003), 5, "clean C: a normal leave saves")
	setStored(880003, 50)
	local c2 = join("CleanC", 880003)
	T.eq(c2:GetAttribute("CloudTokens"), 50, "clean C: the entry was released on leave (the next join sees what is in the store)")
	Mock.RemovePlayer(c2)
	advance(2)

	-- E: a hopeless store: the orphan is dropped only after ORPHAN_TIMEOUT (30 minutes), with a warning, and the server
	--    keeps working. Before that it is still there (a rejoin after 10 minutes still gets the tokens).
	DSt.Fail = true
	local e = join("OrphanE", 880005)
	DataService.AddTokens(e, 5)
	Mock.RemovePlayer(e)
	advance(600)
	local e2 = join("OrphanE", 880005)
	T.eq(e2:GetAttribute("CloudTokens"), 5, "orphan E: still retained after 10 minutes of outage")
	Mock.RemovePlayer(e2)
	advance(2000)
	local gaveUp = false
	for _, o in ipairs(Mock.Output) do
		if o.kind == "warn" and o.text:find("giving up", 1, true) then
			gaveUp = true
		end
	end
	T.check(gaveUp, "orphan E: giving up after the timeout is logged")
	DSt.Fail = false
	local e3 = join("OrphanE", 880005)
	T.eq(e3:GetAttribute("CloudTokens"), 0, "orphan E: the dropped entry is gone (a fresh profile, no stale memory leak)")
	Mock.RemovePlayer(e3)
	advance(2)

	flushErrors("data_orphans")
	flushWarnings("data_orphans", { "[DataService]" })
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
	-- an orphan (left during a DataStore outage, still unsaved) must be flushed by BindToClose as well
	local d = Mock.AddPlayer("OrphanD", 880004)
	advance(1.5)
	DataService.AddTokens(d, 8)
	Mock.DataStore.Fail = true
	Mock.RemovePlayer(d)
	advance(6)
	T.eq(storedTokens(880004), nil, "shutdown: an orphan has nothing stored while the DataStore is down")
	Mock.DataStore.Fail = false
	local p = Mock.AddPlayer("LastOut", 777003)
	advance(1.0)
	DataService.AddTokens(p, 9)
	Mock.DataStore.Latency = 0.2
	local finished = Mock.Shutdown(30)
	Mock.DataStore.Latency = 0
	T.check(finished, "all BindToClose callbacks finish within 30 s")
	T.eq(storedTokens(777003), 9, "BindToClose saves players that are still online", tostring(storedTokens(777003)))
	T.eq(storedTokens(880004), 8, "BindToClose also flushes orphans (players who left during an outage)", tostring(storedTokens(880004)))
	flushErrors("shutdown")
	flushWarnings("shutdown", { "[DataService]" })
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
	for _, name in ipairs({ "Notify", "DamageTaken", "PartyState", "MatchState", "MatchResult", "DashFx", "ProfileSync", "RouletteResult", "TutorialState" }) do
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
