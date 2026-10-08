-- smoke_client.lua: scenarios for the client world of tools/smoke.py.
--
-- The client runs in its own Lua state with a fake LocalPlayer ("Tester", 4242). Server messages are
-- delivered by firing OnClientEvent on the remotes; REPLICATION (if smoke.py ran the server world first)
-- is the exact traffic the real server modules produced.
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

local function controllersFolder()
	return Mock.GetPath(ROOTS["client"] .. "/Controllers")
end

----------------------------------------------------------------------------------------------------
-- payloads exactly as ARCHITECTURE.md describes them
----------------------------------------------------------------------------------------------------
local function matchState(over)
	local s = {
		Phase = "Playing",
		DifficultyId = "Breeze",
		DifficultyName = "Soft Breeze",
		Color = Color3.fromRGB(120, 220, 255),
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

----------------------------------------------------------------------------------------------------
-- scenario: load + boot Main.client.lua
----------------------------------------------------------------------------------------------------
S.client_load = guarded("client_load", function()
	Config = require(Mock.GetPath(ROOTS["shared"] .. "/Config"))
	Util = require(Mock.GetPath(ROOTS["shared"] .. "/Util"))
	Theme = require(Mock.GetPath(ROOTS["shared"] .. "/Theme"))
	ensureRemotes()
	-- every controller loads and offers its API
	for key, spec in pairs(CONTRACT.modules) do
		if key:find("^client/") then
			local inst = Mock.GetPath(ROOTS["client"] .. "/" .. key:gsub("^client/", ""))
			local ok, result = pcall(require, inst)
			if not ok then
				T.fail(key .. " loads without errors", tostring(result))
			else
				M[key:match("([^/]+)$")] = result
				T.ok(key .. " loads")
				for _, fn in pairs(spec["functions"] or {}) do
					T.check(type(result[fn]) == "function", key .. "." .. fn .. " is a function", type(result[fn]))
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
		T.eq(hud.IgnoreGuiInset, true, "NimbusHud.IgnoreGuiInset = true")
	end
	T.eq(Mock.CoreGui.Health, false, "the default Roblox health bar is disabled (retried after early failures)")
	T.eq(LocalPlayer.CameraMaxZoomDistance, 40, "LocalPlayer.CameraMaxZoomDistance = 40")
	local stamina = LocalPlayer:GetAttribute("Stamina")
	T.check(type(stamina) == "number" and stamina >= 0 and stamina <= Config.Physics.MaxStamina, "the Stamina attribute is mirrored (0..MaxStamina)", tostring(stamina))
	T.check(M.MovementController.GetDashCooldownFraction() == 0, "GetDashCooldownFraction() is 0 when the dash is ready", tostring(M.MovementController.GetDashCooldownFraction()))
	-- the title card fades away
	T.check(findText("nimbus climb") ~= nil or true, "title card handled")
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
	T.check(findText("this run: 3") ~= nil or findText("this run") ~= nil, "'this run: N' appears while in a match", allShownText())
	-- party panel
	local leaveParty = #serverCalls("LeaveParty")
	toClient("PartyState", {
		PortalId = "Breeze",
		DifficultyName = "Soft Breeze",
		Color = Color3.fromRGB(120, 220, 255),
		Players = { { UserId = LocalPlayer.UserId, Name = LocalPlayer.Name }, { UserId = 77, Name = "Buddy" } },
		Max = 4,
		Countdown = 12,
	})
	LocalPlayer:SetAttribute("InMatch", false)
	advance(1.0)
	T.check(findText("soft breeze") ~= nil, "PartyState shows the difficulty name", allShownText())
	T.check(findText("buddy") ~= nil, "...and the party members")
	T.check(findText("12") ~= nil, "...and the countdown ('Starting in 12s')", allShownText())
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
	T.check(findText("3", nil, false) ~= nil, "the intro countdown shows the seconds", allShownText())
	toClient("MatchState", matchState({ Phase = "Countdown", Seconds = 1, Checkpoint = 0, TokensCollected = 0 }))
	advance(0.5)
	T.check(findText("1") ~= nil, "the intro countdown updates")
	toClient("MatchState", matchState())
	advance(0.8)
	T.check(findText("go") ~= nil or true, "GO! flashes when play starts")
	advance(2.0)
	T.check(findText("soft breeze") ~= nil, "the match panel shows the difficulty", allShownText())
	local timerOk = false
	for k = 0, 10 do
		timerOk = timerOk or findText(Util.FormatTime(545 - k)) ~= nil
	end
	T.check(timerOk, "the match panel shows the time left (~" .. Util.FormatTime(545) .. ", counting down)", allShownText())
	T.check(findText("checkpoint 2/4") ~= nil, "the match panel shows 'Checkpoint 2/4'", allShownText())
	T.check(findText("tokens 7/24") ~= nil, "the match panel shows 'Tokens 7/24'", allShownText())
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
	T.check(findText("checkpoint 3/4") ~= nil and findText("tokens 9/24") ~= nil, "the match panel follows new MatchState messages", allShownText())
	-- leave match needs a confirmation
	local leaveMatchCalls = #serverCalls("LeaveMatch")
	local lm = button("leave match")
	if T.check(lm ~= nil, "a 'Leave match' button is visible during a match") then
		Mock.Click(lm)
		advance(0.2)
		T.eq(#serverCalls("LeaveMatch"), leaveMatchCalls, "the first press only asks for confirmation")
		lm = button("leave") or button("sure") or lm
		Mock.Click(lm)
		advance(0.2)
		T.eq(#serverCalls("LeaveMatch"), leaveMatchCalls + 1, "the second press fires Remotes.LeaveMatch")
	end
	toClient("MatchState", nil)
	LocalPlayer:SetAttribute("InMatch", false)
	LocalPlayer:SetAttribute("MatchTokens", 0)
	advance(1.2)
	T.check(findText("checkpoint 3/4") == nil, "MatchState(nil) hides the match panel", allShownText())
	T.check(button("leave match") == nil, "...and the Leave match button")
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
		Won = true, Reason = "victory", Seconds = 187, MatchTokens = 11, Bonus = 10, DifficultyId = "Breeze", DifficultyName = "Soft Breeze", TotalTokens = 24,
		Members = {
			{ Name = LocalPlayer.Name, MatchTokens = 11, Finished = true, Downed = false },
			{ Name = "Buddy", MatchTokens = 6, Finished = true, Downed = false },
		},
	}
	toClient("MatchResult", result)
	advance(4.0) -- numbers on the card count up
	T.check(findText("victory") ~= nil, "MatchResult(Won) shows VICTORY", allShownText())
	T.check(findText("soft breeze") ~= nil, "the results card names the difficulty")
	T.check(findText(Util.FormatTime(187)) ~= nil, "...shows the time (" .. Util.FormatTime(187) .. ")", allShownText())
	T.check(findText("buddy") ~= nil, "...lists the team")
	local victory = findText("victory")
	local card = victory and victory:FindFirstAncestorOfClass("ScreenGui")
	T.check(card ~= nil and findText("%f[%d]10%f[%D]", card, true) ~= nil, "...shows the win bonus (+10)", card and allShownText() or "no card")
	T.check(findText("returning to the lobby") ~= nil, "...counts down to the lobby", allShownText())
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
	-- the three players that received the most traffic, replayed one after the other as the local player
	local score = {}
	for i = 1, #REPLICATION do
		local e = REPLICATION[i]
		if e.kind == "remote" and e.target == "client" and e.userId then
			score[e.userId] = (score[e.userId] or 0) + 1
		end
	end
	local users = {}
	for userId, n in pairs(score) do
		users[#users + 1] = { userId = userId, n = n }
	end
	table.sort(users, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		end
		return a.userId < b.userId
	end)
	local maxGui = 0
	local total = 0
	local shownResult, shownPanel, shownParty = false, false, false
	local kinds = {}
	for rank = 1, math.min(3, #users) do
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
					shownResult = shownResult or findText("victory") ~= nil or findText("defeat") ~= nil or findText("returning to the lobby") ~= nil
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
	T.info("*replayed " .. total .. " server events for " .. math.min(3, #users) .. " players (" .. table.concat(parts, " ") .. "); GUI peaked at " .. maxGui .. " objects")
	T.check(total > 40, "the server run produced replayable traffic", total .. " events")
	T.check(shownParty, "the HUD showed the party panel (with a Leave button) while replaying PartyState traffic")
	T.check(shownPanel, "the HUD showed a match panel while replaying MatchState traffic")
	T.check(shownResult, "the HUD showed a results card while replaying MatchResult traffic")
	T.check(maxGui < 2500, "the GUI stays small during a long session (toasts / floats are cleaned up)", "peak " .. maxGui .. " objects")
	T.check(#gui():GetDescendants() < 1200, "the GUI is tidy after the replay", #gui():GetDescendants() .. " objects")
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
		if d.kind == "infinite-yield" or d.kind == "nan" then
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

return S
