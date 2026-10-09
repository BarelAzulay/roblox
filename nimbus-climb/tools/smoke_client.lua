-- smoke_client.lua: scenarios for the client world of tools/smoke.py.
--
-- The client runs in its own Lua state with a fake LocalPlayer ("Tester", 4242). Server messages are
-- delivered by firing OnClientEvent on the remotes; REPLICATION (if smoke.py ran the server world first)
-- is the exact traffic the real server modules produced.
-- v3: client_hud also drives the tutorial side panel (TutorialController) with TutorialState payloads; client_mobile
-- checks the six-tile menu in its three layouts (labelled column, 2 x 3 grid on short landscape screens, icon-only
-- column on narrow portrait screens).
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
local huge = math.huge

local S = {}
local M = {} -- controllers by short name
local Config, Util, Theme

local errorCursor = 0
local outputCursor = 0

local function fmt(v, n)
	return string.format("%." .. (n or 1) .. "f", v)
end

local function advance(seconds)
	Mock.Advance(seconds)
end

local function flushErrors(context)
	for i = errorCursor + 1, #Mock.Errors do
		local e = Mock.Errors[i]
		T.fail((context or "client thread") .. " raised an error", e.msg .. "\n" .. tostring(e.trace or ""))
	end
	errorCursor = #Mock.Errors
end

local function flushWarnings(context)
	for i = outputCursor + 1, #Mock.Output do
		local o = Mock.Output[i]
		if o.kind == "warn" then
			T.fail((context or "warn()") .. ": " .. o.text)
		end
	end
	outputCursor = #Mock.Output
end

local function gui()
	return LocalPlayer:FindFirstChild("PlayerGui")
end

-- A GUI object counts as shown when it and all its GUI ancestors are visible and not fully faded.
local function isShown(obj)
	local cur = obj
	while cur and cur ~= game do
		if cur:IsA("LayerCollector") then
			if cur.Enabled == false then
				return false
			end
		elseif cur:IsA("GuiObject") then
			if cur.Visible == false then
				return false
			end
		end
		cur = cur.Parent
	end
	if obj:IsA("TextLabel") or obj:IsA("TextButton") then
		if obj.TextTransparency >= 0.95 then
			return false
		end
	end
	return true
end

local function texts(root, onlyShown)
	local out = {}
	for _, d in ipairs((root or gui()):GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and (not onlyShown or isShown(d)) then
			out[#out + 1] = d
		end
	end
	return out
end

-- first shown label whose Text matches `pattern` (case-insensitive plain-text search unless regex = true)
local function findText(pattern, root, regex)
	if not regex then
		pattern = pattern:lower()
	end
	for _, d in ipairs(texts(root, true)) do
		local t = tostring(d.Text):lower()
		if regex then
			if t:find(pattern) then
				return d
			end
		elseif t:find(pattern, 1, true) then
			return d
		end
	end
	return nil
end

local function allShownText()
	local out = {}
	for _, d in ipairs(texts(nil, true)) do
		out[#out + 1] = tostring(d.Text)
	end
	return table.concat(out, " | ")
end

local function button(pattern)
	pattern = pattern:lower()
	for _, d in ipairs(gui():GetDescendants()) do
		if d:IsA("TextButton") and tostring(d.Text):lower():find(pattern, 1, true) and isShown(d) then
			return d
		end
	end
	return nil
end

-- first TextButton called `name` anywhere in PlayerGui (shown or not)
local function namedButton(name)
	for _, d in ipairs(gui():GetDescendants()) do
		if d:IsA("TextButton") and d.Name == name then
			return d
		end
	end
	return nil
end

local function remotes()
	return ReplicatedStorage:FindFirstChild("Remotes")
end

local function toClient(name, ...)
	Mock.ToClient(remotes()[name], ...)
end

local function serverCalls(name, fromIndex)
	local out = {}
	for i = (fromIndex or 0) + 1, #Mock.RemoteLog do
		local e = Mock.RemoteLog[i]
		if e.kind == "server" and e.remote == name then
			out[#out + 1] = e
		end
	end
	return out
end

local function hum()
	return Mock.GetHumanoid(LocalPlayer)
end
local function root()
	return Mock.GetRoot(LocalPlayer)
end

local function ensureRemotes()
	if remotes() then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "Remotes"
	for _, n in ipairs(Config.Remotes) do
		local r = Instance.new("RemoteEvent")
		r.Name = n
		r.Parent = folder
	end
	folder.Parent = ReplicatedStorage
end

local function descendantOf(root, name)
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == name then
			return d
		end
	end
	return nil
end

local function controllersFolder()
	return Mock.GetPath(ROOTS["client"] .. "/Controllers")
end

----------------------------------------------------------------------------------------------------
-- payloads exactly as ARCHITECTURE.md / ARCHITECTURE_V2.md describe them
----------------------------------------------------------------------------------------------------
local function matchState(over)
	local easy = Config.GetDifficulty("Easy")
	local s = {
		Phase = "Playing",
		DifficultyId = easy.Id,
		DifficultyName = easy.DisplayName,
		Color = easy.Color,
		Seconds = 545,
		Checkpoint = 2,
		TotalCheckpoints = 4,
		TokensCollected = 7,
		TotalTokens = 24,
		Members = {
			{ UserId = LocalPlayer.UserId, Name = LocalPlayer.Name, Health = 0.78, Downed = false, Finished = false, Tokens = 3 },
			{ UserId = 77, Name = "Buddy", Health = 0.4, Downed = false, Finished = true, Tokens = 4 },
			{ UserId = 78, Name = "Fallen", Health = 0.01, Downed = true, Finished = false, Tokens = 0 },
		},
	}
	for k, v in pairs(over or {}) do
		s[k] = v
	end
	return s
end

-- Shown text labels whose centre lies inside the middle of the screen (|dx| < tol * width, |dy| < tol * height).
-- ARCHITECTURE_V2.md: nothing the GAME says (toasts, countdown, party status, results, title card) may sit there.
local function centredTexts(tol)
	local vp = Mock.Viewport
	local W, H = vp.X, vp.Y
	local out = {}
	for _, d in ipairs(texts(nil, true)) do
		local t = tostring(d.Text):gsub("<[^>]*>", "")
		if t:gsub("%s", "") ~= "" and d.AbsoluteSize.X > 0 and d.AbsoluteSize.Y > 0 then
			local cx = d.AbsolutePosition.X + d.AbsoluteSize.X / 2
			local cy = d.AbsolutePosition.Y + d.AbsoluteSize.Y / 2
			-- AbsolutePosition is relative to the ScreenGui area, which starts below the top bar unless
			-- IgnoreGuiInset is true: convert to screen space so "the middle" is the middle of what the player sees
			local owner = d:FindFirstAncestorOfClass("ScreenGui")
			if owner and owner.IgnoreGuiInset == false then
				cy = cy + (Mock.TopInset or 0)
			end
			if math.abs(cx - W / 2) < tol * W and math.abs(cy - H / 2) < tol * H then
				out[#out + 1] = {
					path = d:GetFullName():gsub("^Players%.[^.]+%.PlayerGui%.", ""),
					text = t,
					x = cx / W,
					y = cy / H,
				}
			end
		end
	end
	return out
end

local function describeCentred(list)
	local parts = {}
	for i = 1, math.min(5, #list) do
		parts[i] = string.format("%s '%s' at %.2f,%.2f", list[i].path, list[i].text:sub(1, 30), list[i].x, list[i].y)
	end
	return table.concat(parts, "; ")
end

----------------------------------------------------------------------------------------------------
-- scenario: load + boot Main.client.lua
----------------------------------------------------------------------------------------------------
S.client_load = guarded("client_load", function()
	Config = require(Mock.GetPath(ROOTS["shared"] .. "/Config"))
	Util = require(Mock.GetPath(ROOTS["shared"] .. "/Util"))
	Theme = require(Mock.GetPath(ROOTS["shared"] .. "/Theme"))
	ensureRemotes()
	-- every controller loads and offers its API (an optional one may be absent: Main skips it quietly)
	local function findModule(key)
		local inst = Mock.GetPath(ROOTS["client"])
		for part in key:gsub("^client/", ""):gmatch("[^/]+") do
			inst = inst and inst:FindFirstChild(part)
		end
		return inst
	end
	for key, spec in pairs(CONTRACT.modules) do
		local inst = key:find("^client/") and findModule(key)
		if key:find("^client/") and not inst then
			if spec.optional then
				T.info("*" .. key .. " is optional and not in this build yet")
			else
				T.fail(key .. " exists", "no ModuleScript at " .. key)
			end
		elseif key:find("^client/") then
			local ok, result = pcall(require, inst)
			if not ok then
				T.fail(key .. " loads without errors", tostring(result))
			else
				M[key:match("([^/]+)$")] = result
				T.ok(key .. " loads")
				for _, fn in pairs(spec["functions"] or {}) do
					T.check(type(result[fn]) == "function", key .. "." .. fn .. " is a function", type(result[fn]))
				end
				for _, name in pairs(spec["signals"] or {}) do
					local sig = result[name]
					T.check(type(sig) == "table" and type(sig.Connect) == "function" and type(sig.Fire) == "function", key .. "." .. name .. " is a signal (Connect + Fire)", type(sig))
				end
				for _, name in pairs(spec.fields or {}) do
					T.check(result[name] ~= nil, key .. "." .. name .. " exists")
				end
			end
		end
	end
	flushErrors("controller load")

	-- boot like Roblox would: run the LocalScript. The first two core-gui attempts fail like they do
	-- while the CoreScripts are still starting.
	Mock.StarterGuiFailures = 2
	local main = Mock.GetPath(ROOTS["client"] .. "/Main")
	T.check(main:IsA("LocalScript"), "client/Main.client.lua is a LocalScript")
	Mock.RunScript(main)
	advance(1.5)
	local ready = false
	for _, o in ipairs(Mock.Output) do
		if o.text:find("client ready", 1, true) then
			ready = true
		end
	end
	T.check(ready, "Main.client.lua reports that the client is ready")
	flushWarnings("client boot")
	flushErrors("client boot")
	advance(3)

	local hud = gui():FindFirstChild("NimbusHud")
	if T.check(hud ~= nil and hud:IsA("ScreenGui"), "HudController builds the ScreenGui 'NimbusHud'") then
		T.eq(hud.ResetOnSpawn, false, "NimbusHud.ResetOnSpawn = false")
		T.eq(hud.IgnoreGuiInset, false, "NimbusHud.IgnoreGuiInset = false (v2: IgnoreGuiInset = false everywhere)")
		T.eq(hud.DisplayOrder, 10, "NimbusHud.DisplayOrder = 10")
		T.eq(hud.ZIndexBehavior, Enum.ZIndexBehavior.Sibling, "NimbusHud.ZIndexBehavior = Sibling")
	end
	-- every ScreenGui the game builds: the documented display orders, never reset on spawn, and every one
	-- that carries text respects the top bar inset
	local wantedOrder = { NimbusHud = 10, NimbusHotbar = 11, NimbusMenu = 20, NimbusNotify = 30 }
	for _, g in ipairs(gui():GetChildren()) do
		if g:IsA("ScreenGui") then
			T.eq(g.ResetOnSpawn, false, g.Name .. ".ResetOnSpawn = false")
			if wantedOrder[g.Name] then
				T.eq(g.DisplayOrder, wantedOrder[g.Name], g.Name .. ".DisplayOrder = " .. wantedOrder[g.Name])
			end
			local hasText = false
			for _, d in ipairs(g:GetDescendants()) do
				if d:IsA("TextLabel") or d:IsA("TextButton") then
					hasText = true
					break
				end
			end
			if hasText and g.Name ~= "MobileControls" then
				T.eq(g.IgnoreGuiInset, false, g.Name .. ".IgnoreGuiInset = false (it carries text)")
			end
		end
	end
	for name, order in pairs(wantedOrder) do
		T.check(gui():FindFirstChild(name) ~= nil, "ScreenGui " .. name .. " exists (display order " .. order .. ")")
	end
	-- the title card is on screen right after joining: it is a small banner, never in the middle
	do
		local title = findText("nimbus climb")
		T.check(title ~= nil, "the title card ('NIMBUS CLIMB') is shown after joining", allShownText())
		T.check(#centredTexts(CONTRACT.v2.centreTolerance) == 0, "...and nothing is shown in the middle of the screen while it is up", describeCentred(centredTexts(CONTRACT.v2.centreTolerance)))
		if title then
			local vp = Mock.Viewport
			local cx = title.AbsolutePosition.X + title.AbsoluteSize.X / 2
			local cy = title.AbsolutePosition.Y + title.AbsoluteSize.Y / 2
			T.check(cx < vp.X * 0.4 and cy < vp.Y * 0.25, "the title card is a small banner in the top-left corner", string.format("centre at %.2f,%.2f of the screen", cx / vp.X, cy / vp.Y))
		end
	end
	T.eq(Mock.CoreGui.Health, false, "the default Roblox health bar is disabled (retried after early failures)")
	T.eq(LocalPlayer.CameraMaxZoomDistance, 40, "LocalPlayer.CameraMaxZoomDistance = 40")
	local stamina = LocalPlayer:GetAttribute("Stamina")
	T.check(type(stamina) == "number" and stamina >= 0 and stamina <= Config.Physics.MaxStamina, "the Stamina attribute is mirrored (0..MaxStamina)", tostring(stamina))
	T.check(M.MovementController.GetDashCooldownFraction() == 0, "GetDashCooldownFraction() is 0 when the dash is ready", tostring(M.MovementController.GetDashCooldownFraction()))
	-- the title card fades away
	advance(6)
	T.check(findText("nimbus climb") == nil, "the 'NIMBUS CLIMB' title card fades out after a few seconds", allShownText())
	-- initial HUD state
	T.check(findText("100 / 100") ~= nil, "health text shows '100 / 100' for a full-health player", allShownText())
	T.check(button("leave") == nil, "no Leave buttons while in the lobby with no party")
	flushWarnings("client idle")
	flushErrors("client idle")
end)

----------------------------------------------------------------------------------------------------
-- scenario: movement (run, stamina, dash, downed lock, respawn)
----------------------------------------------------------------------------------------------------
local function press(action, state)
	return Mock.TriggerAction(action, state, Mock.NewInput(action == "NimbusDash" and "Q" or "LeftShift", "Keyboard", state))
end

S.client_input = guarded("client_input", function()
	if not M.MovementController then
		T.fail("skipped: MovementController did not load (see client_load)")
		return
	end
	local MC = M.MovementController
	local P = Config.Physics
	local h = hum()
	T.check(h ~= nil, "the local character exists")
	T.check(Mock.BoundActions.NimbusRun ~= nil and Mock.BoundActions.NimbusDash ~= nil, "run and dash are bound through ContextActionService", "bound: " .. (function()
		local t = {}
		for k in pairs(Mock.BoundActions) do
			t[#t + 1] = k
		end
		return table.concat(t, ",")
	end)())
	-- walk
	h.WalkSpeed = P.WalkSpeed
	h.MoveDirection = Vector3.new(0, 0, -1)
	advance(0.5)
	T.near(h.WalkSpeed, P.WalkSpeed, 0.5, "walking keeps WalkSpeed at Config.Physics.WalkSpeed")
	-- run
	local staminaBefore = LocalPlayer:GetAttribute("Stamina")
	Mock.KeysDown.LeftShift = true
	press("NimbusRun", "Begin")
	advance(1.5)
	T.check(h.WalkSpeed > P.WalkSpeed + 6, "holding Shift raises WalkSpeed toward RunSpeed", "WalkSpeed " .. fmt(h.WalkSpeed))
	T.check(h.WalkSpeed <= P.RunSpeed + 0.5, "...but never above RunSpeed", "WalkSpeed " .. fmt(h.WalkSpeed))
	local staminaRunning = LocalPlayer:GetAttribute("Stamina")
	T.check(staminaRunning < staminaBefore - 10, "running drains stamina", staminaBefore .. " -> " .. tostring(staminaRunning))
	Mock.KeysDown.LeftShift = false
	press("NimbusRun", "End")
	advance(1.2)
	T.near(h.WalkSpeed, P.WalkSpeed, 1.5, "releasing Shift returns to walking speed")
	advance(3)
	T.check(LocalPlayer:GetAttribute("Stamina") > staminaRunning + 5, "stamina regenerates when not running", staminaRunning .. " -> " .. tostring(LocalPlayer:GetAttribute("Stamina")))
	-- run until exhausted: running stops, stamina never negative
	Mock.KeysDown.LeftShift = true
	press("NimbusRun", "Begin")
	advance(P.MaxStamina / P.RunStaminaDrain + 3)
	T.check(LocalPlayer:GetAttribute("Stamina") >= 0, "stamina never goes negative", tostring(LocalPlayer:GetAttribute("Stamina")))
	T.check(h.WalkSpeed < P.RunSpeed - 3, "an exhausted player can no longer run", "WalkSpeed " .. fmt(h.WalkSpeed))
	Mock.KeysDown.LeftShift = false
	press("NimbusRun", "End")
	advance(8)
	-- dash
	h.MoveDirection = Vector3.new(0, 0, -1)
	local mark = #Mock.RemoteLog
	local staminaPre = LocalPlayer:GetAttribute("Stamina")
	local fovBefore = workspace.CurrentCamera.FieldOfView
	root().AssemblyLinearVelocity = Vector3.new(0, 0, 0)
	press("NimbusDash", "Begin")
	advance(0.05)
	local calls = serverCalls("Dash", mark)
	T.eq(#calls, 1, "pressing the dash key fires the Dash remote once")
	local v = root().AssemblyLinearVelocity
	T.check(math.sqrt(v.X * v.X + v.Z * v.Z) >= P.DashSpeed * 0.7, "the dash sets a high horizontal velocity", "horizontal speed " .. fmt(math.sqrt(v.X * v.X + v.Z * v.Z)))
	T.check(v.Z < 0, "the dash goes in MoveDirection", tostring(v))
	local peakFov = workspace.CurrentCamera.FieldOfView
	for _ = 1, 8 do
		advance(0.03)
		peakFov = math.max(peakFov, workspace.CurrentCamera.FieldOfView)
	end
	T.check(peakFov >= fovBefore + 6, "the dash punches the camera FOV", fmt(fovBefore) .. " -> " .. fmt(peakFov))
	T.check(MC.GetDashCooldownFraction() > 0.6, "GetDashCooldownFraction() is near 1 right after a dash", tostring(MC.GetDashCooldownFraction()))
	T.check(LocalPlayer:GetAttribute("Stamina") <= staminaPre - P.DashStaminaCost + 5, "the dash costs DashStaminaCost stamina", staminaPre .. " -> " .. tostring(LocalPlayer:GetAttribute("Stamina")))
	press("NimbusDash", "Begin")
	advance(0.05)
	T.eq(#serverCalls("Dash", mark), 1, "a second dash inside the cooldown is ignored")
	advance(P.DashCooldown + 0.2)
	T.near(MC.GetDashCooldownFraction(), 0, 0.05, "the cooldown fraction returns to 0")
	advance(2)
	T.near(root().AssemblyLinearVelocity.X, 0, 40, "dash velocity ends after DashDuration")
	press("NimbusDash", "Begin")
	advance(0.1)
	T.eq(#serverCalls("Dash", mark), 2, "the dash works again after the cooldown")
	advance(P.DashCooldown + 3)
	-- downed players cannot run or dash
	LocalPlayer:SetAttribute("Downed", true)
	h.WalkSpeed = 0
	advance(0.3)
	local before = #serverCalls("Dash")
	press("NimbusDash", "Begin")
	advance(0.2)
	T.eq(#serverCalls("Dash"), before, "a downed player cannot dash")
	Mock.KeysDown.LeftShift = true
	press("NimbusRun", "Begin")
	advance(0.8)
	T.check(h.WalkSpeed < 1, "a downed / frozen player cannot run", "WalkSpeed " .. fmt(h.WalkSpeed))
	Mock.KeysDown.LeftShift = false
	press("NimbusRun", "End")
	LocalPlayer:SetAttribute("Downed", false)
	h.WalkSpeed = P.WalkSpeed
	advance(P.DashCooldown + 1)
	-- a respawn re-binds everything (and Roblox deletes ScreenGuis that keep ResetOnSpawn = true)
	local connBefore = Mock.LiveConnections()
	local guisBefore = {}
	for _, g in ipairs(gui():GetChildren()) do
		if g:IsA("ScreenGui") then
			guisBefore[#guisBefore + 1] = g.Name
		end
	end
	local oldChar = LocalPlayer.Character
	Mock.Kill(LocalPlayer)
	Mock.Advance(1)
	Mock.Respawn(LocalPlayer)
	advance(2)
	T.check(LocalPlayer.Character ~= oldChar and hum() ~= nil, "the character respawned")
	local lost = {}
	for _, name in ipairs(guisBefore) do
		if not gui():FindFirstChild(name) then
			lost[#lost + 1] = name
		end
	end
	T.check(#lost == 0, "all ScreenGuis survive a respawn (ResetOnSpawn = false)", "lost: " .. table.concat(lost, ", "))
	hum().MoveDirection = Vector3.new(1, 0, 0)
	local calls2 = #serverCalls("Dash")
	press("NimbusDash", "Begin")
	advance(0.2)
	T.eq(#serverCalls("Dash"), calls2 + 1, "dash works on the new character after a respawn")
	advance(P.DashCooldown + 2)
	Mock.Kill(LocalPlayer)
	advance(1)
	Mock.Respawn(LocalPlayer)
	advance(2)
	T.check(Mock.LiveConnections() <= connBefore + 6, "respawning does not leak connections", Mock.LiveConnections() .. " vs " .. connBefore)
	flushWarnings("client input")
	flushErrors("client input")
end)

----------------------------------------------------------------------------------------------------
-- scenario: HUD driven by server messages
----------------------------------------------------------------------------------------------------
-- v3: the HUD currency stack (ARCHITECTURE_V3.md section 9): Cloud Tokens now (big abbreviated number), Cash and Gems
-- rows appear by themselves once phase 2 sets those attributes.
local function currencyChecks()
	local hud = gui():FindFirstChild("NimbusHud")
	local tokens = hud and descendantOf(hud, "Currency_Tokens")
	if not T.check(tokens ~= nil and isShown(tokens), "HUD: the currency stack shows the Cloud Tokens row") then
		return
	end
	local function row(id)
		return descendantOf(hud, "Currency_" .. id)
	end
	local before = LocalPlayer:GetAttribute(Config.Attr.Tokens)
	T.check((row("Cash") == nil or not isShown(row("Cash"))) and (row("Gems") == nil or not isShown(row("Gems"))), "HUD: Cash / Gems rows stay hidden while those attributes are unset (phase 1)")
	LocalPlayer:SetAttribute(Config.Attr.Tokens, 1250000)
	advance(2.5) -- the number counts up to the new balance
	T.check(findText("1.25m", tokens) ~= nil, "HUD: a big balance is abbreviated (1,250,000 -> 1.25M)", allShownText():sub(1, 200))
	LocalPlayer:SetAttribute(Config.Attr.Tokens, 8421)
	advance(2.5)
	T.check(findText("8,421", tokens) ~= nil, "HUD: a small balance is shown in full (8,421)")
	local vp = Mock.Viewport
	local vitals = hud:FindFirstChild("BottomLeft") and hud.BottomLeft:FindFirstChild("Vitals")
	local cx = (tokens.AbsolutePosition.X + tokens.AbsoluteSize.X / 2) / vp.X
	local cy = (tokens.AbsolutePosition.Y + tokens.AbsoluteSize.Y / 2) / vp.Y
	T.check(cx < 0.45 and cy > 0.5 and (vitals == nil or tokens.AbsolutePosition.Y + tokens.AbsoluteSize.Y <= vitals.AbsolutePosition.Y + 1), "HUD: the currency stack sits bottom-left, above the HP bar", string.format("centre %.2f,%.2f", cx, cy))
	LocalPlayer:SetAttribute(Config.Attr.Cash, 1500)
	LocalPlayer:SetAttribute(Config.Attr.Gems, 12)
	advance(0.8)
	local cash, gems = row("Cash"), row("Gems")
	T.check(cash ~= nil and isShown(cash) and findText("1,500", cash) ~= nil and gems ~= nil and isShown(gems) and findText("12", gems) ~= nil, "HUD: Cash / Gems rows appear once their attributes exist (phase 2 ready)")
	LocalPlayer:SetAttribute(Config.Attr.Cash, nil)
	LocalPlayer:SetAttribute(Config.Attr.Gems, nil)
	LocalPlayer:SetAttribute(Config.Attr.Tokens, before)
	advance(0.8)
	T.check(not isShown(row("Cash")) and not isShown(row("Gems")), "HUD: ...and hide again when the attributes are removed")
end

-- v3: the tutorial side panel (TutorialController, ARCHITECTURE_V3.md section 4), fed with TutorialState payloads
-- built from shared/TutorialSteps exactly like TutorialService builds them.
local function tutorialPayload(Steps, index, over)
	local step = Steps.Steps[index]
	local text = step.Text:gsub("{GiftTokens}", tostring(Config.Tutorial.GiftTokens))
	text = text:gsub("{FinishTokens}", tostring(Config.Tutorial.FinishReward.Tokens))
	local st = {
		Step = index, Total = #Steps.Steps, Id = step.Id, Title = step.Title, Text = text, Target = step.Target,
		CompleteOn = step.CompleteOn, Hint = step.Hint, Button = step.Button, Gift = step.Gift == true,
		Done = false, Completed = false, Skipped = false, Reward = 0,
	}
	for k, v in pairs(over or {}) do
		st[k] = v
	end
	return st
end

local function tutorialClientChecks()
	local TC = M.TutorialController
	local Steps = require(Mock.GetPath(ROOTS["shared"] .. "/TutorialSteps"))
	if not T.check(type(TC) == "table" and type(TC.GetState) == "function", "Tutorial panel: TutorialController loaded") then
		return
	end
	local tol = CONTRACT.v2.centreTolerance
	local vp = Mock.Viewport
	local function events(from)
		local out = {}
		for _, e in ipairs(serverCalls("TutorialEvent", from)) do
			out[#out + 1] = tostring(e.args[1])
		end
		return out
	end
	toClient("TutorialState", tutorialPayload(Steps, 1))
	advance(5)
	local tg = gui():FindFirstChild("NimbusTutorial")
	local counter = tg and findText("step 1/" .. #Steps.Steps, tg)
	T.check(tg ~= nil and counter ~= nil, "Tutorial panel: a TutorialState shows the side panel with 'Step 1/" .. #Steps.Steps .. "'", allShownText():sub(1, 300))
	if not counter then
		return
	end
	T.check(findText(Steps.Steps[1].Title:lower(), tg) ~= nil, "Tutorial panel: ...the step title")
	T.check(findText(Steps.Steps[1].Text:sub(1, 24):lower(), tg) ~= nil, "Tutorial panel: ...and Nimbus' text")
	local cx = (counter.AbsolutePosition.X + counter.AbsoluteSize.X / 2) / vp.X
	T.check(cx < 0.4, "Tutorial panel: it sits on the left side", string.format("centre x %.2f", cx))
	T.check(#centredTexts(tol) == 0, "Tutorial panel: nothing is shown in the middle of the screen", describeCentred(centredTexts(tol)))
	if _G.KC and _G.KC.smallTexts then
		local small, measured = _G.KC.smallTexts(15)
		T.check(#small == 0 and measured > 0, "Tutorial panel: every text on screen is readable (>= 15 px at 1920x1080)", #small .. " of " .. measured .. " too small: " .. table.concat(small, "; ", 1, math.min(#small, 6)))
	end
	local portrait = tg:FindFirstChildWhichIsA("ViewportFrame", true)
	T.check(portrait ~= nil and portrait:FindFirstChildWhichIsA("Model", true) ~= nil, "Tutorial panel: a ViewportFrame portrait of Nimbus (a PetBuilder model)")
	-- Next fires TutorialEvent("Next") (the first press may only finish the typewriter)
	local nextButton
	for _, d in ipairs(tg:GetDescendants()) do
		if d:IsA("TextButton") and d.Name == "Next" then
			nextButton = d
		end
	end
	local mark = #Mock.RemoteLog
	if T.check(nextButton ~= nil and isShown(nextButton), "Tutorial panel: a Next button on a 'Next' step") then
		Mock.Click(nextButton)
		advance(0.4)
		if #events(mark) == 0 then
			Mock.Click(nextButton)
			advance(0.4)
		end
	end
	T.check(T.contains(events(mark), "Next"), "Tutorial panel: Next fires Remotes.TutorialEvent('Next')", table.concat(events(mark), ","))
	-- the shop step: the Shop window opening is reported as ShopOpened
	toClient("TutorialState", tutorialPayload(Steps, 3))
	advance(2)
	T.check(nextButton == nil or not isShown(nextButton), "Tutorial panel: no Next button while the step waits for an action")
	mark = #Mock.RemoteLog
	if M.MenuController then
		M.MenuController.Open("Shop")
		advance(0.6)
		M.MenuController.Close()
		advance(0.6)
	end
	T.check(T.contains(events(mark), "ShopOpened"), "Tutorial panel: opening the Shop sends TutorialEvent('ShopOpened')", table.concat(events(mark), ","))
	-- a menu target: a pulsing ring around MenuButton_Pets
	toClient("TutorialState", tutorialPayload(Steps, 5))
	advance(2.5)
	local pointer = gui():FindFirstChild("NimbusTutorialPointer")
	local ring = pointer and pointer:FindFirstChild("Ring")
	local petsButton
	for _, d in ipairs(gui():GetDescendants()) do
		if d.Name == "MenuButton_Pets" then
			petsButton = d
		end
	end
	if T.check(ring ~= nil and isShown(ring) and petsButton ~= nil, "Tutorial panel: a Menu target rings the menu button (NimbusTutorialPointer)") then
		local rc = ring.AbsolutePosition + ring.AbsoluteSize / 2
		local bc = petsButton.AbsolutePosition + petsButton.AbsoluteSize / 2
		local function shift(inst)
			local owner = inst:FindFirstAncestorOfClass("ScreenGui")
			return (owner and owner.IgnoreGuiInset) and 0 or (Mock.TopInset or 0)
		end
		T.check((Vector2.new(rc.X, rc.Y + shift(ring)) - Vector2.new(bc.X, bc.Y + shift(petsButton))).Magnitude < 12, "Tutorial panel: ...centred on MenuButton_Pets", tostring(rc) .. " vs " .. tostring(bc))
	end
	-- a world target: a 3D arrow + dotted beam in workspace.ClientFx (client-side parts only)
	local portalPos = Config.Lobby.Origin + Vector3.new(60, 0, 40)
	toClient("TutorialState", tutorialPayload(Steps, 7, { Target = { Kind = "Portal", Id = "Easy", Label = "Easy Portal", Position = portalPos } }))
	advance(2.5)
	local fx = workspace:FindFirstChild("ClientFx")
	local guide = fx and fx:FindFirstChild("TutorialGuide")
	local beam = guide and guide:FindFirstChildWhichIsA("Beam", true)
	local solid = 0
	for _, d in ipairs(guide and guide:GetDescendants() or {}) do
		if d:IsA("BasePart") and (d.CanCollide or d.CanTouch or d.CanQuery or not d.Anchored) then
			solid = solid + 1
		end
	end
	T.check(guide ~= nil and beam ~= nil and solid == 0, "Tutorial panel: a world target gets the guide arrow and a dotted Beam in workspace.ClientFx (visual only)", tostring(guide) .. " beam " .. tostring(beam) .. ", " .. solid .. " solid parts")
	-- in a match only the 'finish' step stays on screen
	LocalPlayer:SetAttribute("InMatch", true)
	advance(1.5)
	T.check(not isShown(counter), "Tutorial panel: hidden in a match (step 'portal')")
	toClient("TutorialState", tutorialPayload(Steps, 8))
	advance(2)
	T.check(isShown(counter) and findText("step 8/", tg) ~= nil, "Tutorial panel: ...except the 'finish' step text", allShownText():sub(1, 200))
	LocalPlayer:SetAttribute("InMatch", false)
	advance(1)
	-- Skip asks to confirm, then fires TutorialEvent('Skip')
	local skipLink = descendantOf(tg, "SkipLink")
	mark = #Mock.RemoteLog
	if T.check(skipLink ~= nil and isShown(skipLink), "Tutorial panel: a small 'Skip tutorial' link") then
		Mock.Click(skipLink)
		advance(0.4)
		T.check(not T.contains(events(mark), "Skip"), "Tutorial panel: Skip asks to confirm first", table.concat(events(mark), ","))
		local yes = descendantOf(tg, "ConfirmSkip")
		if yes then
			Mock.Click(yes)
			advance(0.4)
		end
		T.check(T.contains(events(mark), "Skip"), "Tutorial panel: confirming fires TutorialEvent('Skip')", table.concat(events(mark), ","))
	end
	-- done: the panel and the guides go away
	toClient("TutorialState", tutorialPayload(Steps, 9, { Done = true, Skipped = true }))
	advance(6)
	T.check(not isShown(counter), "Tutorial panel: Done hides the panel")
	T.check(guide == nil or guide.Parent == nil or not (beam and beam.Enabled), "Tutorial panel: ...and the world guide")
end

S.client_hud = guarded("client_hud", function()
	if gui() == nil or gui():FindFirstChild("NimbusHud") == nil then
		T.fail("skipped: there is no NimbusHud (HudController failed to start, see client_load)")
		return
	end
	local h = hum()
	h.MaxHealth = 100
	h.Health = 100
	advance(0.5)
	-- health
	h.Health = 78
	advance(1.0)
	T.check(findText("78 / 100") ~= nil, "health text follows Humanoid.Health ('78 / 100')", allShownText())
	h.Health = 20
	advance(1.0)
	T.check(findText("20 / 100") ~= nil, "low health text ('20 / 100')", allShownText())
	h.Health = 100
	advance(0.8)
	-- downed
	LocalPlayer:SetAttribute("Downed", true)
	advance(0.8)
	T.check(findText("downed") ~= nil, "the HUD announces the DOWNED state", allShownText())
	LocalPlayer:SetAttribute("Downed", false)
	advance(0.8)
	T.check(findText("wait for a teammate") == nil, "the downed message disappears after the revive")
	-- tokens
	LocalPlayer:SetAttribute("CloudTokens", 42)
	advance(2.0)
	T.check(findText("42") ~= nil, "the cloud token counter shows CloudTokens", allShownText())
	LocalPlayer:SetAttribute("CloudTokens", 1234)
	advance(2.5)
	T.check(findText("1234") ~= nil or findText("1,234") ~= nil, "the token counter handles 4 digits", allShownText())
	LocalPlayer:SetAttribute("InMatch", true)
	LocalPlayer:SetAttribute("MatchTokens", 3)
	advance(1.5)
	T.check(findText("+3", nil, false) ~= nil, "the token pill shows the match tokens ('+3') while in a match", allShownText())
	-- party panel
	local leaveParty = #serverCalls("LeaveParty")
	toClient("PartyState", {
		PortalId = "Medium",
		DifficultyName = "Medium",
		Color = Config.GetDifficulty("Medium").Color,
		Players = { { UserId = LocalPlayer.UserId, Name = LocalPlayer.Name }, { UserId = 77, Name = "Buddy" } },
		Max = 4,
		Countdown = 12,
	})
	LocalPlayer:SetAttribute("InMatch", false)
	advance(1.0)
	T.check(findText("medium") ~= nil, "PartyState shows the difficulty name", allShownText())
	T.check(findText("buddy") ~= nil, "...and the party members")
	T.check(findText("starting in") ~= nil, "...and the countdown ('Starting in Ns')", allShownText())
	local leaveBtn = button("leave")
	if T.check(leaveBtn ~= nil, "a Leave button is visible in the party panel") then
		Mock.Click(leaveBtn)
		advance(0.2)
		T.eq(#serverCalls("LeaveParty"), leaveParty + 1, "pressing Leave fires Remotes.LeaveParty")
	end
	toClient("PartyState", nil)
	advance(1.0)
	T.check(button("leave") == nil, "PartyState(nil) hides the party panel")
	-- match: countdown, panel, team list, results of leaving
	LocalPlayer:SetAttribute("InMatch", true)
	toClient("MatchState", matchState({ Phase = "Countdown", Seconds = 3, Checkpoint = 0, TokensCollected = 0 }))
	advance(0.6)
	local matchPanel = gui().NimbusHud.TopLeft.MatchPanel
	T.check(findText("^3$", matchPanel, true) ~= nil, "the intro countdown shows the seconds inside the match panel (a '3')", allShownText())
	toClient("MatchState", matchState({ Phase = "Countdown", Seconds = 1, Checkpoint = 0, TokensCollected = 0 }))
	advance(0.5)
	T.check(findText("^1$", matchPanel, true) ~= nil and findText("^3$", matchPanel, true) == nil, "the intro countdown updates (3 -> 1)", allShownText())
	toClient("MatchState", matchState())
	advance(2.8)
	T.check(findText("^%d$", matchPanel, true) == nil, "the countdown numeral is gone once play starts (the timer shows m:ss again)", allShownText())
	T.check(findText("easy") ~= nil, "the match panel shows the difficulty", allShownText())
	local timerOk = false
	for k = 0, 10 do
		timerOk = timerOk or findText(Util.FormatTime(545 - k)) ~= nil
	end
	T.check(timerOk, "the match panel shows the time left (~" .. Util.FormatTime(545) .. ", counting down)", allShownText())
	T.check(findText("checkpoint 2/4") ~= nil, "the match panel shows 'Checkpoint 2/4'", allShownText())
	T.check(findText("7/24") ~= nil, "the match panel shows the token progress ('7/24')", allShownText())
	T.check(findText("buddy") ~= nil and findText("fallen") ~= nil, "the team list shows the other members", allShownText())
	local skull = false
	for _, d in ipairs(texts(nil, true)) do
		if tostring(d.Text):find("\240\159\146\128") or tostring(d.Text):find("\226\152\160") then
			skull = true
		end
	end
	T.check(skull, "downed team members get a skull mark")
	-- the time keeps ticking down with each message
	toClient("MatchState", matchState({ Seconds = 544, Checkpoint = 3, TokensCollected = 9 }))
	advance(0.8)
	T.check(findText("checkpoint 3/4") ~= nil and findText("9/24") ~= nil, "the match panel follows new MatchState messages", allShownText())
	-- leave match needs a confirmation (the compact Leave button inside the match panel, named LeaveMatch)
	local leaveMatchCalls = #serverCalls("LeaveMatch")
	local lm = namedButton("LeaveMatch")
	if T.check(lm ~= nil and isShown(lm), "a 'Leave' button is visible in the match panel during a match") then
		Mock.Click(lm)
		advance(0.2)
		T.eq(#serverCalls("LeaveMatch"), leaveMatchCalls, "the first press only asks for confirmation")
		T.check(tostring(lm.Text):lower():find("sure") ~= nil, "...the button turns into 'Sure?'", lm.Text)
		Mock.Click(lm)
		advance(0.2)
		T.eq(#serverCalls("LeaveMatch"), leaveMatchCalls + 1, "the second press fires Remotes.LeaveMatch")
	end
	toClient("MatchState", nil)
	LocalPlayer:SetAttribute("InMatch", false)
	LocalPlayer:SetAttribute("MatchTokens", 0)
	advance(1.2)
	T.check(findText("checkpoint 3/4") == nil, "MatchState(nil) hides the match panel", allShownText())
	local lm2 = namedButton("LeaveMatch")
	T.check(lm2 == nil or not isShown(lm2), "...and the Leave button")
	currencyChecks()
	tutorialClientChecks()
	flushWarnings("client hud")
	flushErrors("client hud")
end)

----------------------------------------------------------------------------------------------------
-- scenario: toasts, results card, other players' dashes
----------------------------------------------------------------------------------------------------
S.client_notify = guarded("client_notify", function()
	toClient("Notify", "Hello sky climbers", "good", 3)
	advance(0.5)
	T.check(findText("hello sky climbers") ~= nil, "Notify shows a toast", allShownText())
	advance(5)
	T.check(findText("hello sky climbers") == nil, "...and removes it after its duration")
	for i = 1, 7 do
		toClient("Notify", "Toast number " .. i, i % 2 == 0 and "bad" or "info", 6)
		advance(0.1)
	end
	advance(0.6)
	local shown = 0
	for i = 1, 7 do
		if findText("toast number " .. i) then
			shown = shown + 1
		end
	end
	T.check(shown <= 4 and shown >= 1, "at most 4 toasts are stacked", shown .. " visible")
	advance(9)
	toClient("Notify", "+1 cloud token", "token", 2)
	advance(0.4)
	T.check(findText("+1 cloud token") ~= nil, "token toasts work")
	advance(4)
	-- results
	local result = {
		Won = true, Reason = "victory", Seconds = 187, MatchTokens = 11, Bonus = 10, DifficultyId = "Easy", DifficultyName = "Easy", Stars = 1, TotalTokens = 24,
		Members = {
			{ Name = LocalPlayer.Name, MatchTokens = 11, Finished = true, Downed = false },
			{ Name = "Buddy", MatchTokens = 6, Finished = true, Downed = false },
		},
	}
	toClient("MatchResult", result)
	advance(4.0) -- numbers on the card count up
	T.check(findText("victory") ~= nil, "MatchResult(Won) shows VICTORY", allShownText())
	T.check(findText("easy") ~= nil, "the results card names the difficulty")
	T.check(findText(Util.FormatTime(187)) ~= nil, "...shows the time (" .. Util.FormatTime(187) .. ")", allShownText())
	T.check(findText("buddy") ~= nil, "...lists the team")
	local victory = findText("victory")
	local card = victory and victory:FindFirstAncestorOfClass("ScreenGui")
	T.check(card ~= nil and findText("%f[%d]10%f[%D]", card, true) ~= nil, "...shows the win bonus (+10)", card and allShownText() or "no card")
	T.check(findText("back to lobby in") ~= nil, "...counts down to the lobby ('Back to lobby in Ns')", allShownText())
	toClient("MatchState", nil)
	advance(1.5)
	T.check(findText("victory") == nil, "MatchState(nil) closes the results card", allShownText())
	result.Won, result.Reason, result.Bonus = false, "defeat", 0
	toClient("MatchResult", result)
	advance(1.2)
	T.check(findText("defeat") ~= nil and findText("victory") == nil, "MatchResult(defeat) shows DEFEAT", allShownText())
	toClient("MatchState", nil)
	advance(1.5)
	result.Reason = "timeout"
	toClient("MatchResult", result)
	advance(1.0)
	T.check(findText("victory") == nil, "a timeout result is not shown as a victory")
	toClient("MatchState", nil)
	advance(1.5)
	-- other players' dash
	local other = Mock.AddPlayer("Other", 55)
	advance(1)
	local before = Mock.CountDescendants(workspace)
	toClient("DashFx", LocalPlayer.UserId)
	advance(0.2)
	local own = Mock.CountDescendants(workspace)
	toClient("DashFx", 55)
	advance(0.2)
	local theirs = Mock.CountDescendants(workspace)
	T.check(theirs > own, "DashFx for another player spawns an effect near their character", own .. " -> " .. theirs)
	T.check(own - before <= 1, "DashFx for the local player is ignored (MovementController shows it)", before .. " -> " .. own)
	advance(4)
	T.check(Mock.CountDescendants(workspace) <= before + 2, "dash effects clean themselves up", Mock.CountDescendants(workspace) .. " vs " .. before)
	toClient("DashFx", 424242) -- unknown player: no crash
	advance(0.2)
	Mock.RemovePlayer(other)
	flushWarnings("client notify")
	flushErrors("client notify")
end)

----------------------------------------------------------------------------------------------------
-- scenario: damage feedback
----------------------------------------------------------------------------------------------------
-- Billboards can live in workspace or (the usual way for client-only effects) in PlayerGui.
local function billboards()
	local out = {}
	for _, root in ipairs({ workspace, gui() }) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BillboardGui") then
				out[#out + 1] = d
			end
		end
	end
	return out
end

local function floatingTexts()
	local out = {}
	for _, b in ipairs(billboards()) do
		for _, t in ipairs(b:GetDescendants()) do
			if t:IsA("TextLabel") and isShown(t) then
				out[#out + 1] = tostring(t.Text)
			end
		end
	end
	return table.concat(out, " | ")
end

S.client_damage = guarded("client_damage", function()
	local h = hum()
	local guiBefore = #gui():GetDescendants()
	local peakOffset = 0
	toClient("DamageTaken", 25, "SpinBar")
	for _ = 1, 20 do
		advance(0.03)
		peakOffset = math.max(peakOffset, h.CameraOffset.Magnitude)
	end
	T.check(floatingTexts():find("25", 1, true) ~= nil, "a floating damage number appears above the head", floatingTexts())
	T.check(floatingTexts():upper():find("WHACK") ~= nil, "SpinBar hits say WHACK!", floatingTexts())
	T.check(peakOffset > 0.02, "the camera shakes (Humanoid.CameraOffset)", "peak " .. fmt(peakOffset, 3))
	advance(3)
	T.near(h.CameraOffset.Magnitude, 0, 0.001, "the camera offset is restored after the shake")
	T.check(floatingTexts():find("25", 1, true) == nil, "floating numbers fade away")
	for kind, word in pairs({ Lightning = "ZAP", Void = "SPLASH", Storm = "DRIZZLE" }) do
		toClient("DamageTaken", 8, kind)
		advance(0.3)
		T.check(floatingTexts():upper():find(word, 1, true) ~= nil, kind .. " hits say " .. word, floatingTexts())
		advance(3)
	end
	-- storm ticks arrive 4x per second and must not flood the screen
	for _ = 1, 12 do
		toClient("DamageTaken", 2, "Storm")
		advance(0.25)
	end
	local live = #billboards()
	T.check(live <= 14, "storm damage is merged (at most 14 floating texts)", live .. " billboards")
	advance(4)
	-- tokens
	LocalPlayer:SetAttribute("MatchTokens", 0)
	advance(0.2)
	LocalPlayer:SetAttribute("MatchTokens", 2)
	advance(0.3)
	T.check(floatingTexts():find("+2", 1, true) ~= nil, "collecting tokens pops a floating '+2'", floatingTexts())
	advance(4)
	-- dying while effects are on screen is harmless
	toClient("DamageTaken", 30, "Lightning")
	Mock.Kill(LocalPlayer)
	advance(1)
	Mock.Respawn(LocalPlayer)
	advance(3)
	T.near(hum().CameraOffset.Magnitude, 0, 0.001, "no camera offset is left over after a death mid-shake")
	T.check(#gui():GetDescendants() <= guiBefore + 40, "damage effects do not pile up GUI objects", #gui():GetDescendants() .. " vs " .. guiBefore)
	flushWarnings("client damage")
	flushErrors("client damage")
end)

----------------------------------------------------------------------------------------------------
-- scenario: replay of the real server traffic
----------------------------------------------------------------------------------------------------
local function replayFor(userId)
	local picked = {}
	for i = 1, #REPLICATION do
		local e = REPLICATION[i]
		if e.kind == "remote" then
			if e.target == "all" or e.userId == userId then
				picked[#picked + 1] = e
			end
		elseif (e.kind == "attr" or e.kind == "health") and e.userId == userId then
			picked[#picked + 1] = e
		end
	end
	return picked
end

S.client_replay = guarded("client_replay", function()
	if gui() == nil or gui():FindFirstChild("NimbusHud") == nil then
		T.fail("skipped: there is no NimbusHud (HudController failed to start, see client_load)")
		return
	end
	if REPLICATION == nil then
		T.warn("no server replication log: run the server scenarios first")
		return
	end
	-- a few players with different traffic, replayed one after the other as the local player: the busiest one,
	-- and whoever got the most PartyState / MatchResult / RouletteResult / OpenPanel messages
	local score, byKind = {}, {}
	for i = 1, #REPLICATION do
		local e = REPLICATION[i]
		if e.kind == "remote" and e.target == "client" and e.userId then
			score[e.userId] = (score[e.userId] or 0) + 1
			byKind[e.remote] = byKind[e.remote] or {}
			byKind[e.remote][e.userId] = (byKind[e.remote][e.userId] or 0) + 1
		end
	end
	local function best(counts)
		local pick, top = nil, 0
		for userId, n in pairs(counts or {}) do
			if n > top or (n == top and pick and userId < pick) then
				pick, top = userId, n
			end
		end
		return pick
	end
	local users, seenUser = {}, {}
	for _, userId in ipairs({ best(score), best(byKind.PartyState), best(byKind.MatchResult), best(byKind.RouletteResult), best(byKind.OpenPanel) }) do
		if userId and not seenUser[userId] then
			seenUser[userId] = true
			users[#users + 1] = { userId = userId, n = score[userId] }
		end
	end
	-- the menu draws one pet viewport per distinct owned pet, so the GUI size depends on the profile: compare
	-- before / after with the same small profile
	local function smallProfile()
		LocalPlayer:SetAttribute("CloudTokens", 600)
		toClient("ProfileSync", {
			Tokens = 600, Pets = { cloudy_dragon = 2, pebble_pup = 1, biscuit_bear = 3 }, Equipped = { "cloudy_dragon" }, Items = { heal_cloud = 2 },
			Stats = { Matches = 1, Wins = 1, TokensEarned = 5, Spins = 1, BestTimes = {} }, Perks = { MaxHealth = 0.12, TokenBonus = 0.25, StaminaRegen = 0, CheckpointHeal = 0 },
		})
		advance(1.5)
	end
	smallProfile()
	local function guiBreakdown()
		local parts = {}
		for _, g in ipairs(gui():GetChildren()) do
			local line = g.Name .. " " .. #g:GetDescendants()
			if g.Name == "NimbusMenu" then
				-- one level deeper: which window / layer holds the objects
				local inner = {}
				for _, c in ipairs(g:GetChildren()) do
					for _, cc in ipairs(c:GetChildren()) do
						local n = #cc:GetDescendants()
						if n > 60 then
							inner[#inner + 1] = c.Name .. "." .. cc.Name .. " " .. n
						end
					end
				end
				if #inner > 0 then
					line = line .. " (" .. table.concat(inner, ", ") .. ")"
				end
			end
			parts[#parts + 1] = line
		end
		return table.concat(parts, ", ")
	end
	local baselineGui = #gui():GetDescendants()
	local baselineBreakdown = guiBreakdown()
	local maxGui = 0
	local total = 0
	local shownResult, shownPanel, shownParty = false, false, false
	local kinds = {}
	for rank = 1, #users do
		local picked = replayFor(users[rank].userId)
		local me = LocalPlayer.UserId
		local mapped = {}
		for i, e in ipairs(picked) do
			local copy = {}
			for k, v in pairs(e) do
				copy[k] = v
			end
			if copy.userId == users[rank].userId then
				copy.userId = me
			end
			mapped[i] = copy
		end
		total = total + #mapped
		LocalPlayer:SetAttribute("InMatch", false)
		Mock.RunReplay(mapped, nil, function(e)
			if e.kind == "remote" then
				kinds[e.remote] = (kinds[e.remote] or 0) + 1
				if e.remote == "MatchResult" then
					advance(1.0)
					shownResult = shownResult or findText("victory") ~= nil or findText("defeat") ~= nil or findText("back to lobby in") ~= nil
				elseif e.remote == "MatchState" and not shownPanel then
					advance(0.5)
					shownPanel = shownPanel or findText("checkpoint") ~= nil
				elseif e.remote == "PartyState" and not shownParty then
					advance(0.3)
					shownParty = shownParty or button("leave") ~= nil
				end
			end
			maxGui = math.max(maxGui, #gui():GetDescendants())
		end, 4)
		advance(12)
		flushWarnings("client replay")
		flushErrors("client replay")
	end
	local parts = {}
	for k, v in pairs(kinds) do
		parts[#parts + 1] = k .. "=" .. v
	end
	table.sort(parts)
	T.info("*replayed " .. total .. " server events for " .. #users .. " players (" .. table.concat(parts, " ") .. "); GUI peaked at " .. maxGui .. " objects")
	T.check(total > 40, "the server run produced replayable traffic", total .. " events")
	T.check(shownParty, "the HUD showed the party panel (with a Leave button) while replaying PartyState traffic")
	T.check(shownPanel, "the HUD showed a match panel while replaying MatchState traffic")
	T.check(shownResult, "the HUD showed a results card while replaying MatchResult traffic")
	LocalPlayer:SetAttribute("InMatch", false)
	LocalPlayer:SetAttribute("Downed", false)
	toClient("MatchState", nil)
	toClient("PartyState", nil)
	-- roulette results queue up on the client and a reveal card stays up until the player dismisses it: Esc closes the
	-- stage (which starts the next queued result), then the open window. Dismiss until nothing is left.
	local idle = 0
	for _ = 1, 150 do
		Mock.FireSignal(game:GetService("UserInputService"), "InputBegan", Mock.NewInput("Escape", "Keyboard", "Begin"), false)
		advance(0.4)
		if gui():FindFirstChild("RouletteStage", true) then
			idle = 0
		else
			idle = idle + 1
			if idle >= 2 then
				break
			end
		end
	end
	T.check(gui():FindFirstChild("RouletteStage", true) == nil, "every queued roulette result can be dismissed with Esc", "a RouletteStage is still on screen after 150 presses")
	smallProfile()
	advance(2.0)
	T.check(maxGui < baselineGui + 4000, "the GUI stays small during a long session (toasts / floats are cleaned up)", "peak " .. maxGui .. " objects, " .. baselineGui .. " before (" .. baselineBreakdown .. ")")
	T.check(#gui():GetDescendants() <= baselineGui + 120, "the GUI is tidy after the replay (no growth from toasts, result cards, roulette reveals)", #gui():GetDescendants() .. " objects after, " .. baselineGui .. " before; now: " .. guiBreakdown() .. "; before: " .. baselineBreakdown)
end)

----------------------------------------------------------------------------------------------------
-- scenario: final invariants of the client run
----------------------------------------------------------------------------------------------------
S.client_final = guarded("client_final", function()
	local allowed = {}
	for _, font in pairs(Theme.Fonts) do
		allowed[font] = true
	end
	local problems, total = Mock.FontAudit(allowed)
	T.info("*font audit: " .. total .. " live text objects checked")
	local shown = {}
	for i = 1, math.min(8, #problems) do
		shown[i] = problems[i].path .. " [" .. problems[i].text .. "]: " .. problems[i].reason
	end
	T.check(#problems == 0, "every client TextLabel/TextButton uses a Theme font", #problems .. " unstyled:\n" .. table.concat(shown, "\n"))
	local waits = Mock.PendingWaitList(5)
	T.check(#waits == 0, "no WaitForChild waits forever on the client", table.concat(waits, "; "))
	for _, d in ipairs(Mock.Diagnostics) do
		local line = d.kind .. ": " .. d.msg .. " (x" .. d.count .. ", first at " .. d.where .. ")"
		if d.kind == "infinite-yield" or d.kind == "nan" or d.kind == "out-of-range" then
			T.fail("mock: " .. line)
		elseif d.kind ~= "mock-gap" then
			T.warn("mock: " .. line)
		end
	end
	T.check(#Mock.ModuleErrors == 0, "no client module raised an error while loading", #Mock.ModuleErrors > 0 and Mock.ModuleErrors[1].message or "")
	flushErrors("client final")
	flushWarnings("client final")
	T.info("*simulated " .. fmt(Mock.Clock.now, 0) .. " s of client time")
end)

----------------------------------------------------------------------------------------------------
-- scenario: touch devices (runs in a second client world with TouchEnabled)
----------------------------------------------------------------------------------------------------
S.client_mobile = guarded("client_mobile", function()
	Config = require(Mock.GetPath(ROOTS["shared"] .. "/Config"))
	Theme = require(Mock.GetPath(ROOTS["shared"] .. "/Theme"))
	ensureRemotes()
	Mock.RunScript(Mock.GetPath(ROOTS["client"] .. "/Main"))
	advance(3)
	local mobile = gui():FindFirstChild("MobileControls")
	if not T.check(mobile ~= nil and mobile:IsA("ScreenGui"), "TouchEnabled devices get a ScreenGui 'MobileControls'") then
		flushErrors("client mobile")
		return
	end
	local run, dash
	for _, d in ipairs(mobile:GetDescendants()) do
		if d:IsA("TextButton") then
			local caption = tostring(d.Text) .. " " .. d.Name
			for _, c in ipairs(d:GetDescendants()) do
				if c:IsA("TextLabel") then
					caption = caption .. " " .. tostring(c.Text)
				end
			end
			caption = caption:upper()
			if caption:find("DASH") then
				dash = d
			elseif caption:find("RUN") then
				run = d
			end
		end
	end
	T.check(run ~= nil, "a RUN button exists")
	if T.check(dash ~= nil, "a DASH button exists") then
		hum().MoveDirection = Vector3.new(0, 0, -1)
		local mark = #Mock.RemoteLog
		Mock.Click(dash)
		advance(0.2)
		T.eq(#serverCalls("Dash", mark), 1, "tapping DASH fires the Dash remote")
	end
	if run then
		local before = hum().WalkSpeed
		Mock.Click(run)
		advance(1.5)
		T.check(hum().WalkSpeed > before + 5, "tapping RUN toggles running", before .. " -> " .. hum().WalkSpeed)
		Mock.Click(run)
		advance(1.5)
		T.near(hum().WalkSpeed, Config.Physics.WalkSpeed, 1.5, "tapping RUN again stops running")
	end
	-- Layout: RUN and DASH must never sit on top of Roblox's default jump button (TouchJump: 120 px, left edge
	-- 170 px / top edge 210 px from the right / bottom screen edge on big screens, 70 px (95 / 90) on small ones),
	-- on the hotbar, on the HP bar, on the token pill or on the menu column. Rectangles are {x0, y0, x1, y1} in pixels.
	if run and dash then
		-- Screen-space rectangle. AbsolutePosition is relative to the owning ScreenGui's area, which starts below the
		-- top bar unless IgnoreGuiInset is true (MobileControls does, the HUD / hotbar / menu do not), so rectangles of
		-- different guis are only comparable once the inset is added for the guis that respect it.
		local function rectOf(inst)
			local p, s2 = inst.AbsolutePosition, inst.AbsoluteSize
			local dy = 0
			local owner = inst:FindFirstAncestorOfClass("ScreenGui")
			if owner and owner.IgnoreGuiInset == false then
				dy = Mock.TopInset or 0
			end
			return { x0 = p.X, y0 = p.Y + dy, x1 = p.X + s2.X, y1 = p.Y + s2.Y + dy }
		end
		local function overlaps(a, b)
			return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1
		end
		local function show(r)
			return string.format("x %d..%d, y %d..%d", r.x0, r.x1, r.y0, r.y1)
		end
		local function jumpRect(w, h)
			if math.min(w, h) <= 500 then
				return { x0 = w - 95, y0 = h - 90, x1 = w - 95 + 70, y1 = h - 90 + 70 }
			end
			return { x0 = w - 170, y0 = h - 210, x1 = w - 170 + 120, y1 = h - 210 + 120 }
		end
		local function guiPart(path)
			local cur = gui()
			for part in path:gmatch("[^.]+") do
				cur = cur and cur:FindFirstChild(part)
			end
			return cur
		end
		local function checkLayout(label, w, h)
			Mock.SetViewport(w, h)
			advance(0.4)
			local d, r = rectOf(dash), rectOf(run)
			local jump = jumpRect(w, h)
			T.check(not overlaps(d, jump), label .. ": DASH does not cover the jump button", show(d) .. " vs jump " .. show(jump))
			T.check(not overlaps(r, jump), label .. ": RUN does not cover the jump button", show(r) .. " vs jump " .. show(jump))
			T.check(not overlaps(d, r), label .. ": DASH and RUN do not overlap", show(d) .. " vs " .. show(r))
			for name, rect in pairs({ DASH = d, RUN = r }) do
				T.check(rect.x0 >= 0 and rect.y0 >= 0 and rect.x1 <= w and rect.y1 <= h, label .. ": " .. name .. " is fully on screen", show(rect))
			end
			for _, other in ipairs({ { "NimbusHotbar.Hotbar", "the hotbar" }, { "NimbusHud.BottomLeft.Vitals", "the HP bar" }, { "NimbusHud.TopRight.TokenPill", "the token pill" }, { "NimbusMenu.MenuColumn", "the menu column" } }) do
				local inst = guiPart(other[1])
				if inst then
					local o = rectOf(inst)
					T.check(not overlaps(d, o), label .. ": DASH does not cover " .. other[2], show(d) .. " vs " .. show(o))
					T.check(not overlaps(r, o), label .. ": RUN does not cover " .. other[2], show(r) .. " vs " .. show(o))
				end
			end
			-- The menu column against the other HUD pieces at EVERY size (it is scaled and centred by MenuController, so
			-- a wrong size in the mock would hide a real overlap; the geometry check below pins the size itself).
			local menuColumn = guiPart("NimbusMenu.MenuColumn")
			if menuColumn then
				local col = rectOf(menuColumn)
				T.check(col.x0 >= 0 and col.y0 >= 0 and col.x1 <= w and col.y1 <= h, label .. ": the menu column is fully on screen", show(col))
				for _, other in ipairs({ { "NimbusHud.BottomLeft.Vitals", "the HP bar" }, { "NimbusHotbar.Hotbar", "the hotbar" }, { "NimbusHud.TopRight.TokenPill", "the token pill" } }) do
					local inst = guiPart(other[1])
					if inst and inst.Visible ~= false then
						local o = rectOf(inst)
						T.check(not overlaps(col, o), label .. ": the menu column does not cover " .. other[2], show(col) .. " vs " .. show(o))
					end
				end
				-- MenuController (v3, ARCHITECTURE_V3.md section 9): six tiles under ONE UIScale, anchored (0, 0.5), laid out as
				-- "Column" (labelled tiles in one column), "Grid" (labelled tiles, 2 x 3, short landscape screens) or "Compact"
				-- (icon-only tiles in one column, narrow portrait screens). Its size must be the laid-out entries plus the scaled
				-- gaps, scaled once (the mock used to apply the UIScale twice: 158 px instead of 219 on a 844x390 phone), and it
				-- must sit vertically centred in the ScreenGui area.
				local entries, sum = {}, 0
				for _, entry in ipairs(menuColumn:GetChildren()) do
					if entry:IsA("GuiObject") and entry.Name:find("^Entry_") then
						entries[#entries + 1] = entry
						sum = sum + entry.AbsoluteSize.Y
					end
				end
				local count = #entries
				local colScale = menuColumn:FindFirstChildOfClass("UIScale")
				local factor = colScale and colScale.Scale or 1
				local gridLayout = menuColumn:FindFirstChildOfClass("UIGridLayout")
				local xs, labelsShown = {}, 0
				for _, entry in ipairs(entries) do
					xs[math.floor(entry.AbsolutePosition.X + 0.5)] = true
					for _, d in ipairs(entry:GetDescendants()) do
						if d:IsA("TextLabel") and isShown(d) and tostring(d.Text):gsub("%s", "") ~= "" and d.AbsoluteSize.Y > 0 then
							labelsShown = labelsShown + 1
						end
					end
				end
				local columns = 0
				for _ in pairs(xs) do
					columns = columns + 1
				end
				-- icon-only tiles are square (entry height == tile width); labelled tiles are taller than wide
				local designH = count > 0 and entries[1].AbsoluteSize.Y / factor or 0
				local designW = count > 0 and entries[1].AbsoluteSize.X / factor or 0
				local mode = gridLayout and "Grid" or (designH < designW - 4 and "Compact" or "Column")
				T.info("*" .. label .. ": menu layout " .. mode .. " (" .. columns .. " column(s), scale " .. fmt(factor, 2) .. ", entry " .. fmt(designW, 0) .. "x" .. fmt(designH, 0) .. " design px, " .. labelsShown .. " texts shown)")
				if T.check(count == #CONTRACT.v3.menuEntries, label .. ": the menu column has six entries", tostring(count)) then
					local expected
					if gridLayout then
						local rows = math.ceil(count / 2)
						expected = (rows * gridLayout.CellSize.Y.Offset + (rows - 1) * gridLayout.CellPadding.Y.Offset) * factor
						T.eq(columns, 2, label .. ": the grid layout is 2 x 3 (two columns)")
					else
						expected = sum + 6 * (count - 1) * factor
						T.eq(columns, 1, label .. ": the list layouts keep one column")
					end
					T.check(math.abs(menuColumn.AbsoluteSize.Y - expected) <= 1.5, label .. ": the menu column height is its entries + gaps, scaled once", fmt(menuColumn.AbsoluteSize.Y, 1) .. " px vs " .. fmt(expected, 1))
					if mode == "Compact" then
						T.check(w < h, label .. ": icon-only tiles are used on portrait screens only")
						local named = 0
						for _, entry in ipairs(entries) do
							local l = entry:FindFirstChild("Label", true)
							if l and isShown(l) then
								named = named + 1
							end
						end
						T.eq(named, 0, label .. ": icon-only tiles hide their labels")
					end
					T.check(mode ~= "Grid" or w > h, label .. ": the 2 x 3 grid is used on landscape screens only")
					if mode == "Column" or mode == "Grid" then
						local smallest = math.huge
						for _, entry in ipairs(entries) do
							for _, d in ipairs(entry:GetDescendants()) do
								if d:IsA("TextLabel") and isShown(d) and not d.TextScaled then
									smallest = math.min(smallest, d.TextSize * factor)
								end
							end
						end
						T.check(smallest >= 14, label .. ": menu tile labels stay readable (>= 14 px on screen)", fmt(smallest, 1) .. " px")
					end
				end
				local area = Mock.GuiLayerSize(menuColumn)
				if area then
					local centre = menuColumn.AbsolutePosition.Y + menuColumn.AbsoluteSize.Y / 2
					T.check(math.abs(centre - area.Y / 2) <= 1.5, label .. ": the menu column is vertically centred in the screen area", fmt(centre, 1) .. " vs " .. fmt(area.Y / 2, 1))
				end
			end
			local hotbar, vitals = guiPart("NimbusHotbar.Hotbar"), guiPart("NimbusHud.BottomLeft.Vitals")
			if hotbar and vitals then
				T.check(not overlaps(rectOf(hotbar), rectOf(vitals)), label .. ": the hotbar and the HP bar do not overlap", show(rectOf(hotbar)) .. " vs " .. show(rectOf(vitals)))
				T.check(not overlaps(rectOf(hotbar), jump), label .. ": the hotbar does not cover the jump button", show(rectOf(hotbar)) .. " vs jump " .. show(jump))
			end
		end
		checkLayout("390x844 phone", 390, 844)
		checkLayout("844x390 phone landscape", 844, 390)
		checkLayout("800x400", 800, 400)
		checkLayout("1280x720", 1280, 720)
		-- the HP bar is raised on touch so the thumbstick can be used (bottom-left)
		local vitals = guiPart("NimbusHud.BottomLeft.Vitals")
		if vitals then
			Mock.SetViewport(390, 844)
			advance(0.4)
			local v = rectOf(vitals)
			T.check(844 - v.y1 >= 120, "390x844: the HP bar is raised on touch devices (the thumbstick area stays free)", show(v))
		end
		Mock.SetViewport(390, 844) -- leave the world as we found it
		advance(0.2)
	end

	-- touch-friendly hotbar (slots >= 48 px) and a menu column that fits on a phone
	local hotbar = gui():FindFirstChild("NimbusHotbar")
	if hotbar then
		local smallest = math.huge
		for _, d in ipairs(hotbar:GetDescendants()) do
			if d.Name:find("^Hotbar%d$") and d:IsA("GuiObject") then
				smallest = math.min(smallest, d.AbsoluteSize.X, d.AbsoluteSize.Y)
			end
		end
		T.check(smallest >= 48, "390x844: hotbar slots are at least 48 px (touch friendly)", "smallest slot " .. fmt(smallest, 0) .. " px")
	end
	local column = gui():FindFirstChild("NimbusMenu") and gui().NimbusMenu:FindFirstChild("MenuColumn")
	if column then
		local p, sz = column.AbsolutePosition, column.AbsoluteSize
		T.check(p.X >= 0 and p.Y >= 0 and p.X + sz.X <= 390 and p.Y + sz.Y <= 844, "390x844: the menu column fits on screen", tostring(p) .. " " .. tostring(sz))
		for _, other in ipairs({ { "NimbusHud.BottomLeft.Vitals", "the HP bar" }, { "NimbusHotbar.Hotbar", "the hotbar" }, { "NimbusHud.TopRight.TokenPill", "the token pill" } }) do
			local cur = gui()
			for part in other[1]:gmatch("[^.]+") do
				cur = cur and cur:FindFirstChild(part)
			end
			if cur then
				local a, b = cur.AbsolutePosition, cur.AbsoluteSize
				local overlap = p.X < a.X + b.X and a.X < p.X + sz.X and p.Y < a.Y + b.Y and a.Y < p.Y + sz.Y
				T.check(not overlap, "390x844: the menu column does not cover " .. other[2], tostring(p) .. " " .. tostring(sz) .. " vs " .. tostring(a) .. " " .. tostring(b))
			end
		end
	end
	-- the "nothing in the middle of the screen" rule on a phone
	if _G.KC and _G.KC.layoutRule then
		Mock.SetViewport(390, 844)
		advance(0.3)
		_G.KC.layoutRule("390x844")
	end

	local fontBad = 0
	local allowed = {}
	for _, font in pairs(Theme.Fonts) do
		allowed[font] = true
	end
	local problems = Mock.FontAudit(allowed)
	T.check(#problems == 0, "mobile buttons use Theme fonts", #problems > 0 and (problems[1].path .. ": " .. problems[1].reason) or "")
	flushWarnings("client mobile")
	flushErrors("client mobile")
end)

----------------------------------------------------------------------------------------------------
-- helpers exported to smoke_client_v2.lua (same Lua state)
----------------------------------------------------------------------------------------------------
_G.KC = {
	S = S, M = M, T = T, guarded = guarded, fmt = fmt, advance = advance,
	flushErrors = flushErrors, flushWarnings = flushWarnings,
	gui = gui, isShown = isShown, texts = texts, findText = findText, allShownText = allShownText,
	button = button, namedButton = namedButton, remotes = remotes, toClient = toClient, serverCalls = serverCalls,
	hum = hum, root = root, ensureRemotes = ensureRemotes, matchState = matchState,
	centredTexts = centredTexts, describeCentred = describeCentred,
	env = function()
		return Config, Util, Theme
	end,
}

return S
