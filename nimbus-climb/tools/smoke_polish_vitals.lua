-- smoke_polish_vitals.lua: the HP / stamina vitals card of client/Controllers/HudController.lua (playtest polish,
-- key "vitals": "the HP and stamina UI looks kind of bad"). Client world only; tools/smoke.py runs:
--   client_polish_vitals         (1920x1080, keyboard) one cohesive card: a glossy outlined plate holding the heart
--                                badge + a thick HP tube (outline, gradient fill, highlight strip, white damage trail,
--                                hit flash + card shake, low-health pulse, big outlined "117 / 117" >= 24 px), the
--                                lightning badge + a matching stamina tube (smooth drain / refill, dims when empty) and
--                                the dash ring (the cooldown sweep follows MovementController, the face lights up when
--                                a dash is ready); the DOWNED state; every part inside the card, readable, bottom-left,
--                                clear of the hotbar, the menu column and the currency stack
--   client_polish_vitals_mobile  (phone world, touch: 390x844, 844x390, 1024x768) the card stays on screen, readable
--                                (>= 14 px), clear of the hotbar, the touch buttons, the menu column, the currency stack
--                                and the top-left panel (4-player party); short landscape screens get the compact card
--                                (the dash ring spans both rows, a visible gap above the hotbar)
--   client_polish_matchpanel_mobile  (phone world, touch: 844x390, 667x375, 390x844, 1024x768) the match panel: the
--                                token line sits under the tall Leave button, so its text never overlaps the timer or
--                                the countdown numeral (pop included; widths measured with 20 % slack for real fonts),
--                                stays inside the panel, clear of Leave and the checkpoint bar, readable
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local fmt = string.format

local S = {}

local function KC()
	return _G.KC
end

local function advance(seconds)
	Mock.Advance(seconds)
end

local function env()
	local Config, Util, Theme = KC().env()
	if not Config then
		Config = require(Mock.GetPath(ROOTS["shared"] .. "/Config"))
		Theme = require(Mock.GetPath(ROOTS["shared"] .. "/Theme"))
	end
	return Config, Theme
end

local function playerGui()
	return LocalPlayer:FindFirstChild("PlayerGui")
end

local function path(root, dotted)
	local cur = root
	for part in string.gmatch(dotted, "[^%.]+") do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(part)
	end
	return cur
end

local function shown(obj)
	return obj ~= nil and KC().isShown(obj)
end

-- product of the UIScales above `inst` (hover / press feedback excluded)
local function scaleOf(inst)
	local scale = 1
	local cur = inst
	while cur and cur ~= game do
		if cur:IsA("GuiObject") then
			for _, c in ipairs(cur:GetChildren()) do
				if c:IsA("UIScale") and c.Name ~= "FxScale" then
					scale = scale * c.Scale
				end
			end
		end
		cur = cur.Parent
	end
	return scale
end

-- a GuiObject's box in the coordinates of an IgnoreGuiInset = false gui
local function rect(inst)
	local g = inst:FindFirstAncestorOfClass("ScreenGui")
	local dy = (g and g.IgnoreGuiInset) and -(Mock.TopInset or 0) or 0
	local p, s = inst.AbsolutePosition, inst.AbsoluteSize
	return { x0 = p.X, y0 = p.Y + dy, x1 = p.X + s.X, y1 = p.Y + s.Y + dy }
end

local function overlap(a, b)
	return a.x0 < b.x1 - 0.5 and a.x1 > b.x0 + 0.5 and a.y0 < b.y1 - 0.5 and a.y1 > b.y0 + 0.5
end

local function strokeOf(inst)
	for _, c in ipairs(inst:GetChildren()) do
		if c:IsA("UIStroke") and c.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
			return c
		end
	end
	return nil
end

local function close(a, b, tol)
	return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= tol
end

local function sameColor(a, b, tol)
	return a and b and close(a.R, b.R, tol or 0.02) and close(a.G, b.G, tol or 0.02) and close(a.B, b.B, tol or 0.02)
end

-- the colour of a UIGradient at time t (linear between keypoints)
local function gradientAt(g, t)
	local kps = g.Color.Keypoints
	for i = 1, #kps - 1 do
		local a, b = kps[i], kps[i + 1]
		if t >= a.Time and t <= b.Time then
			local f = (b.Time > a.Time) and (t - a.Time) / (b.Time - a.Time) or 0
			return a.Value:Lerp(b.Value, f)
		end
	end
	return kps[#kps].Value
end

-- the card's parts by name (nil fields when missing)
local function card()
	local hud = playerGui() and playerGui():FindFirstChild("NimbusHud")
	local vitals = path(hud, "BottomLeft.Vitals")
	local body = path(vitals, "Body")
	local hp = path(body, "HealthBar")
	local st = path(body, "StaminaBar")
	local ring = path(body, "DashRing")
	local c = {
		Hud = hud, Vitals = vitals, Body = body, Card = path(body, "Card"),
		Hp = hp, HpFill = path(hp, "Inner.Fill"), Trail = path(hp, "Inner.DamageTrail"), Flash = path(hp, "Inner.Fill.Flash"),
		HpText = path(hp, "Text"), St = st, StFill = path(st, "Inner.Fill"),
		Ring = ring, Right = path(ring, "Sweep.HalfRight.Disc"), Left = path(ring, "Sweep.HalfLeft.Disc"),
		Glyph = path(ring, "Face.Glyph"), Heart = path(body, "Heart"), Bolt = path(body, "StaminaBadge"),
		Notice = path(body, "DownedNotice"),
	}
	c.HeartScale = c.Heart and c.Heart:FindFirstChildOfClass("UIScale")
	c.CardStroke = c.Card and strokeOf(c.Card)
	return c
end

local function fraction(fill)
	return fill and fill.Size.X.Scale or -1
end

local function setHealth(max, health)
	local h = KC().hum()
	if h then
		h.MaxHealth = max
		h.Health = health
	end
end

local function startRun()
	local h = KC().hum()
	if h then
		h.MoveDirection = Vector3.new(0, 0, -1)
	end
	Mock.KeysDown.LeftShift = true
	Mock.TriggerAction("NimbusRun", "Begin", Mock.NewInput("LeftShift", "Keyboard", "Begin"))
end

local function stopRun()
	Mock.KeysDown.LeftShift = false
	Mock.TriggerAction("NimbusRun", "End", Mock.NewInput("LeftShift", "Keyboard", "End"))
	local h = KC().hum()
	if h then
		h.MoveDirection = Vector3.new(0, 0, 0)
	end
end

local function dash()
	local h = KC().hum()
	if h then
		h.MoveDirection = Vector3.new(0, 0, -1)
	end
	Mock.TriggerAction("NimbusDash", "Begin", Mock.NewInput("Q", "Keyboard", "Begin"))
	advance(0.05)
	Mock.TriggerAction("NimbusDash", "End", Mock.NewInput("Q", "Keyboard", "End"))
	if h then
		h.MoveDirection = Vector3.new(0, 0, 0)
	end
end

local function resetState()
	LocalPlayer:SetAttribute("Downed", false)
	LocalPlayer:SetAttribute("InMatch", false)
	pcall(KC().toClient, "MatchState", nil)
	pcall(KC().toClient, "PartyState", nil)
	stopRun()
	advance(0.8)
	setHealth(117, 117)
	advance(4) -- stamina back to full, the dash cooled down, the trail caught up
end

-- the gradient sequence of a sweep half: "step" (hard step at 0.5) or "solid"
local function sweepKind(disc)
	local g = disc and disc:FindFirstChildOfClass("UIGradient")
	if not g then
		return "none"
	end
	local kps = g.Transparency.Keypoints
	local allZero = true
	for _, kp in ipairs(kps) do
		if kp.Value > 0.001 then
			allZero = false
		end
	end
	if allZero then
		return "solid"
	end
	if #kps == 4 and kps[2].Value < 0.01 and kps[3].Value > 0.99 and kps[2].Time > 0.45 and kps[3].Time < 0.55 then
		return "step"
	end
	return "other"
end

local function rotationOf(disc)
	local g = disc and disc:FindFirstChildOfClass("UIGradient")
	return g and g.Rotation or -1
end

-- every shown text of the card is at least floorPx on screen; returns the list of offenders
local function smallTexts(root, floorPx)
	local small = {}
	for _, d in ipairs(root:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and shown(d) and tostring(d.Text) ~= "" then
			local px = d.TextSize * scaleOf(d)
			if d.TextScaled then
				local limit = d:FindFirstChildOfClass("UITextSizeConstraint")
				px = (limit and limit.MinTextSize or 1) * scaleOf(d)
			end
			if px < floorPx - 0.01 then
				small[#small + 1] = fmt("%s %.1f px", d.Name, px)
			end
		end
	end
	return small
end

-- the card's own parts stay inside the Vitals box (the layout's slot), strokes allowed
local function partsInside(c, slack)
	local box = rect(c.Vitals)
	local out = {}
	for _, d in ipairs(c.Body:GetDescendants()) do
		if d:IsA("GuiObject") and shown(d) and d.AbsoluteSize.X > 0 then
			local r = rect(d)
			if r.x0 < box.x0 - slack or r.x1 > box.x1 + slack or r.y0 < box.y0 - slack or r.y1 > box.y1 + slack then
				out[#out + 1] = d.Name
			end
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- desktop: the card, its animation and its states
----------------------------------------------------------------------------------------------------
S.client_polish_vitals = guarded("client_polish_vitals", function()
	local Config, Theme = env()
	local MC = KC().M and KC().M.MovementController
	resetState()
	local c = card()
	if not T.check(c.Vitals ~= nil and c.Card ~= nil and c.Hp ~= nil and c.St ~= nil and c.Ring ~= nil and c.Heart ~= nil and c.Bolt ~= nil,
		"vitals: one card holds the heart badge, the HP tube, the lightning badge, the stamina tube and the dash ring") then
		return
	end

	-- 1. the look: chunky outlined plate, thick outlined tubes with a gradient fill + highlight strip, shapes not glyphs
	local plateStroke = c.CardStroke
	T.check(plateStroke ~= nil and plateStroke.Thickness >= 3 and c.Card:FindFirstChildOfClass("UICorner") ~= nil and c.Card:FindFirstChildOfClass("UIGradient") ~= nil,
		"vitals: the card is a rounded glossy plate with a thick dark outline")
	local k = scaleOf(c.Hp)
	T.check(c.Hp.AbsoluteSize.Y / k >= 34 and strokeOf(c.Hp) ~= nil and strokeOf(c.Hp).Thickness >= 3, "vitals: the HP tube is thick (>= 34 design px) with a rounded dark outline",
		fmt("%.0f design px", c.Hp.AbsoluteSize.Y / k))
	T.check(c.St.AbsoluteSize.Y / k >= 18 and strokeOf(c.St) ~= nil, "vitals: the stamina tube matches it (>= 18 design px, same outline), not a thin afterthought",
		fmt("%.0f design px", c.St.AbsoluteSize.Y / k))
	local fillGradient = c.HpFill and c.HpFill:FindFirstChildOfClass("UIGradient")
	T.check(fillGradient ~= nil and fillGradient.Rotation == 90 and #fillGradient.Color.Keypoints >= 3 and c.HpFill:FindFirstChild("Shine") ~= nil,
		"vitals: the HP fill has a soft top-to-bottom gradient and a highlight strip")
	local heartShape = path(c.Heart, "HeartShape")
	local tip = path(heartShape, "Tip")
	T.check(heartShape ~= nil and tip ~= nil and close(tip.Rotation, 45, 0.1) and path(heartShape, "LobeL") ~= nil and path(heartShape, "LobeR") ~= nil,
		"vitals: the heart badge draws a real heart (a turned square + two lobes)")
	local boltShape = path(c.Bolt, "Bolt")
	T.check(boltShape ~= nil and #boltShape:GetChildren() == 3, "vitals: the stamina badge draws a lightning bolt")
	T.check(c.Heart.AbsoluteSize.X / k >= 44 and c.Bolt.AbsoluteSize.X / k >= 28 and c.Ring.AbsoluteSize.X / k >= 34, "vitals: badges and the dash ring are chunky")

	-- 2. the number: big, outlined, the Display font
	T.check(c.HpText ~= nil and tostring(c.HpText.Text) == "117 / 117", "vitals: the HP tube reads '117 / 117'", c.HpText and tostring(c.HpText.Text))
	local outline = c.HpText and c.HpText:FindFirstChild("TextOutline")
	T.check(c.HpText.TextSize * scaleOf(c.HpText) >= 24 and c.HpText.Font == Theme.Fonts.Display and outline ~= nil and outline.Thickness >= 2,
		"vitals: the HP number is big (>= 24 px at 1080p), Display font, with a thick outline (Readability rule)",
		fmt("%.1f px", c.HpText.TextSize * scaleOf(c.HpText)))
	local small = smallTexts(c.Vitals, 15)
	T.check(#small == 0, "vitals: every text of the card is >= 15 px at 1920x1080", table.concat(small, ", "))
	T.check(fillGradient and sameColor(gradientAt(fillGradient, 0.4), Theme.Colors.Health, 0.03), "vitals: full health is green")

	-- 3. place: bottom-left, inside its slot, clear of the hotbar, the menu column and the currency stack
	local vp = Mock.Viewport
	local box = rect(c.Vitals)
	T.check(box.x0 >= 0 and box.y1 <= vp.Y and (box.x0 + box.x1) / 2 < vp.X * 0.3 and (box.y0 + box.y1) / 2 > vp.Y * 0.75, "vitals: the card sits bottom-left",
		fmt("%.0f,%.0f - %.0f,%.0f", box.x0, box.y0, box.x1, box.y1))
	local outside = partsInside(c, 4 * k)
	T.check(#outside == 0, "vitals: every part of the card stays inside its layout slot", table.concat(outside, ", "))
	local cardBox = rect(c.Card)
	T.check(cardBox.x0 > box.x0 + 8 * k and rect(c.Heart).x0 < cardBox.x0, "vitals: the heart badge overlaps the card's left edge (like the coins above)")
	for _, other in ipairs({ { "NimbusHotbar.Hotbar", "the hotbar" }, { "NimbusMenu.MenuColumn", "the menu column" }, { "NimbusHud.BottomLeft.Currency", "the currency stack" } }) do
		local o = path(playerGui(), other[1])
		if o and shown(o) then
			T.check(not overlap(box, rect(o)), "vitals: the card never covers " .. other[2])
		end
	end
	T.check(c.Hud:GetAttribute("BottomLeftTop") ~= nil and c.Hud:GetAttribute("BottomLeftTop") <= rect(c.Vitals).y0 + 1, "vitals: the HUD still publishes BottomLeftTop above the card",
		tostring(c.Hud:GetAttribute("BottomLeftTop")))

	-- 4. a hit: the bar flashes, the card shakes, the white trail waits and then catches up
	setHealth(117, 100)
	advance(1.5)
	setHealth(117, 47)
	advance(0.06)
	c = card()
	T.check(c.Flash ~= nil and c.Flash.BackgroundTransparency < 0.6, "vitals: a hit flashes the HP fill white", c.Flash and fmt("%.2f", c.Flash.BackgroundTransparency))
	local off = c.Body.Position
	T.check(math.abs(off.X.Offset) + math.abs(off.Y.Offset) > 0.2, "vitals: ...and gives the card a short shake", tostring(off))
	T.check(c.HpText.Text == "47 / 117", "vitals: the number drops to '47 / 117' at once", tostring(c.HpText.Text))
	advance(0.3)
	local trailNow, fillNow = fraction(c.Trail), fraction(c.HpFill)
	T.check(trailNow > 100 / 117 - 0.03 and fillNow < 0.5, "vitals: the white damage trail waits where the bar was while the fill drops",
		fmt("trail %.2f, fill %.2f", trailNow, fillNow))
	T.check(c.Trail and c.Trail.BackgroundColor3.R > 0.95 and c.Trail.BackgroundColor3.B > 0.95 and c.Trail.BackgroundTransparency < 0.2, "vitals: the trail is white")
	advance(0.5)
	T.check(c.Flash.BackgroundTransparency > 0.99 and c.Body.Position.X.Offset == 0 and c.Body.Position.Y.Offset == 0, "vitals: the flash and the shake are over after a moment")
	advance(2)
	T.check(close(fraction(c.Trail), fraction(c.HpFill), 0.01) and close(fraction(c.HpFill), 47 / 117, 0.01), "vitals: the trail catches up with the fill",
		fmt("trail %.2f, fill %.2f", fraction(c.Trail), fraction(c.HpFill)))
	T.check(sameColor(gradientAt(fillGradient, 0.4), Theme.Colors.HealthMid, 0.03), "vitals: 40% health turns the fill amber")

	-- 5. low health (< 30%): the heart beats, the outline glows red, the fill is red
	setHealth(117, 18)
	advance(0.5)
	local maxScale, minScale, maxRed = 0, 9, 0
	local navy = Theme.Colors.Navy
	for _ = 1, 40 do
		advance(1 / 30)
		local s = c.HeartScale and c.HeartScale.Scale or 1
		maxScale = math.max(maxScale, s)
		minScale = math.min(minScale, s)
		maxRed = math.max(maxRed, c.CardStroke.Color.R - navy.R)
	end
	T.check(maxScale > 1.08 and minScale < 1.03, "vitals: below 30% the heart beats", fmt("scale %.2f..%.2f", minScale, maxScale))
	T.check(maxRed > 0.25, "vitals: ...and the card's outline pulses red", fmt("+%.2f red", maxRed))
	T.check(sameColor(gradientAt(fillGradient, 0.4), Theme.Colors.HealthLow, 0.03), "vitals: low health turns the fill red")
	setHealth(117, 117)
	advance(1.5)
	T.check(c.HeartScale.Scale == 1 and c.Heart.Rotation == 0 and sameColor(c.CardStroke.Color, navy, 0.01), "vitals: healed: the pulse stops, the outline is navy again")

	-- 6. stamina drains and refills smoothly, and dims when empty
	advance(4)
	local stBefore = fraction(c.StFill)
	startRun()
	local maxStep, last = 0, stBefore
	for _ = 1, 30 do
		advance(1 / 30)
		local f = fraction(c.StFill)
		maxStep = math.max(maxStep, math.abs(f - last))
		last = f
	end
	T.check(stBefore > 0.99 and last < stBefore - 0.08 and maxStep < 0.05, "vitals: running drains the stamina tube smoothly",
		fmt("%.2f -> %.2f, biggest frame step %.3f", stBefore, last, maxStep))
	-- run dry (MovementController then stops the run until stamina is back to 15)
	local stamina = LocalPlayer:GetAttribute(Config.Attr.Stamina)
	for _ = 1, 300 do
		advance(1 / 30)
		stamina = LocalPlayer:GetAttribute(Config.Attr.Stamina)
		if type(stamina) == "number" and stamina <= 0 then
			break
		end
	end
	advance(0.15)
	local boltPart = boltShape and boltShape:FindFirstChildWhichIsA("GuiObject")
	T.check(type(stamina) == "number" and stamina <= 0 and fraction(c.StFill) < 0.05, "vitals: the stamina tube empties", fmt("%s, fill %.2f", tostring(stamina), fraction(c.StFill)))
	advance(0.3)
	T.check(boltPart ~= nil and boltPart.BackgroundTransparency > 0.4 and sweepKind(c.Right) == "solid" and c.Right.BackgroundColor3.B < 0.8,
		"vitals: ...the lightning badge dims and the dash ring greys out while drained",
		boltPart and fmt("bolt transparency %.2f, stamina %.1f", boltPart.BackgroundTransparency, LocalPlayer:GetAttribute(Config.Attr.Stamina) or -1))
	stopRun()
	advance(6)
	T.check(fraction(c.StFill) > 0.98 and boltPart.BackgroundTransparency < 0.01, "vitals: stamina refills and the badge lights up again",
		fmt("%.2f / %.2f", fraction(c.StFill), boltPart.BackgroundTransparency))

	-- 7. the dash ring follows the cooldown
	T.check(sweepKind(c.Right) == "solid" and sweepKind(c.Left) == "solid" and c.Glyph.TextTransparency < 0.01, "vitals: dash ready: a full ring and a lit face")
	local before = fraction(c.StFill)
	dash()
	advance(1 / 30)
	local cost = (Config.Physics.DashStaminaCost or 35) / (Config.Physics.MaxStamina or 100)
	T.check(fraction(c.StFill) > before - cost + 0.05, "vitals: the dash cost eases out of the stamina tube (no jump)", fmt("%.2f", fraction(c.StFill)))
	advance(0.4)
	local cd = MC and MC.GetDashCooldownFraction and MC.GetDashCooldownFraction() or -1
	local angle = (1 - cd) * 360
	T.check(cd > 0.2 and cd < 0.95, "vitals: the dash is cooling down (precondition)", fmt("%.2f", cd))
	T.check(sweepKind(c.Right) == "step" and sweepKind(c.Left) == "step", "vitals: while it cools down the ring is a partial sweep")
	T.check(close(rotationOf(c.Right), math.min(angle, 180), 14) and close(rotationOf(c.Left), math.max(angle, 180), 14),
		"vitals: the sweep angle follows MovementController's cooldown (clockwise from 12 o'clock)",
		fmt("cooldown %.2f -> %.0f deg; right %.0f, left %.0f", cd, angle, rotationOf(c.Right), rotationOf(c.Left)))
	T.check(c.Glyph.TextTransparency > 0.2, "vitals: the face is dim until the dash is back")
	advance(2.2)
	T.check(sweepKind(c.Right) == "solid" and c.Glyph.TextTransparency < 0.01 and close(fraction(c.StFill), 1, 0.3), "vitals: the ring closes and the face lights up when the dash is ready")

	-- 8. downed: the notice takes the stamina row, the heart shows "!", the outline turns red
	LocalPlayer:SetAttribute("Downed", true)
	advance(0.6)
	T.check(shown(c.Notice) and tostring(c.Notice.Text):lower():find("wait for a teammate", 1, true) ~= nil and c.HpText.Text == "DOWNED", "vitals: downed: 'DOWNED' + 'Wait for a teammate!'")
	T.check(not shown(c.St) and not shown(c.Ring) and not shown(c.Bolt) and shown(path(c.Heart, "Glyph")) and not shown(heartShape),
		"vitals: ...the stamina row makes room and the heart badge shows '!'")
	T.check(sameColor(c.CardStroke.Color, Theme.Colors.Bad, 0.01), "vitals: ...and the card's outline is red")
	small = smallTexts(c.Vitals, 15)
	T.check(#small == 0, "vitals: the downed texts are readable too", table.concat(small, ", "))
	LocalPlayer:SetAttribute("Downed", false)
	advance(0.6)
	T.check(not shown(c.Notice) and shown(c.St) and shown(c.Ring) and shown(c.Bolt) and shown(heartShape) and sameColor(c.CardStroke.Color, navy, 0.01),
		"vitals: revived: the card is back to normal")

	-- 9. in a match the card keeps its place (the match panel lives top-left)
	LocalPlayer:SetAttribute("InMatch", true)
	KC().toClient("MatchState", KC().matchState({}))
	advance(1)
	local inMatch = rect(c.Vitals)
	local panel = path(c.Hud, "TopLeft.MatchPanel")
	T.check(close(inMatch.y1, box.y1, 1) and (panel == nil or not shown(panel) or not overlap(rect(panel), inMatch)), "vitals: in a match the card stays put, clear of the match panel")
	resetState()
	KC().flushErrors("polish vitals")
	KC().flushWarnings("polish vitals")
end)

----------------------------------------------------------------------------------------------------
-- phones and tablets
----------------------------------------------------------------------------------------------------
S.client_polish_vitals_mobile = guarded("client_polish_vitals_mobile", function()
	local mobile = playerGui():FindFirstChild("MobileControls")
	T.check(mobile ~= nil and mobile.Enabled, "vitals (phone): the touch controls are on screen (precondition)")
	resetState()
	for _, size in ipairs({ { 390, 844 }, { 844, 390 }, { 1024, 768 } }) do
		Mock.SetViewport(size[1], size[2])
		advance(1.2)
		for _, players in ipairs({ 0, 4 }) do
			if players > 0 then
				local list = {}
				for i = 1, players do
					list[i] = { UserId = (i == 1) and LocalPlayer.UserId or (7100 + i), Name = (i == 1) and LocalPlayer.Name or ("Friend" .. i) }
				end
				KC().toClient("PartyState", { PortalId = "Hard", DifficultyName = "Hard", Color = Color3.fromRGB(226, 150, 74), Players = list, Max = 4, Countdown = 9, Locked = true })
				advance(1.0)
			end
			local label = fmt("vitals (%dx%d%s)", size[1], size[2], players > 0 and ", 4-player party" or "")
			local c = card()
			if T.check(shown(c.Vitals) and shown(c.Card), label .. ": the card is shown") then
				local vp = Mock.Viewport
				local box = rect(c.Vitals)
				local k = scaleOf(c.Card)
				T.check(box.x0 >= 0 and box.x1 <= vp.X and box.y0 >= 0 and box.y1 <= vp.Y - (Mock.TopInset or 0), label .. ": inside the screen",
					fmt("%.0f,%.0f - %.0f,%.0f", box.x0, box.y0, box.x1, box.y1))
				local small = smallTexts(c.Vitals, 14)
				T.check(#small == 0 and c.HpText.TextSize * scaleOf(c.HpText) >= 18, label .. ": readable (>= 14 px, the HP number >= 18 px)", table.concat(small, ", "))
				local outside = partsInside(c, 4 * k)
				T.check(#outside == 0, label .. ": every part stays inside the card's slot", table.concat(outside, ", "))
				local others = { { "NimbusHotbar.Hotbar", "the hotbar" }, { "NimbusMenu.MenuColumn", "the menu column" }, { "NimbusHud.BottomLeft.Currency", "the currency stack" },
					{ "NimbusHud.TopRight.Currency", "the currency stack" }, { "NimbusHud.TopLeft.PartyPanel", "the party panel" } }
				for _, other in ipairs(others) do
					local o = path(playerGui(), other[1])
					if o and shown(o) then
						T.check(not overlap(box, rect(o)), label .. ": clear of " .. other[2])
					end
				end
				local hit = {}
				for _, d in ipairs(mobile:GetDescendants()) do
					if (d:IsA("TextButton") or d:IsA("ImageButton")) and shown(d) and overlap(rect(d), box) then
						hit[#hit + 1] = d.Name
					end
				end
				T.check(#hit == 0, label .. ": clear of the touch buttons", table.concat(hit, ", "))
				-- the visible card (outline included) leaves a gap above the hotbar when it sits right over it
				local hotbar = path(playerGui(), "NimbusHotbar.Hotbar")
				if hotbar and shown(hotbar) then
					local hb, cb = rect(hotbar), rect(c.Card)
					local stroke = c.CardStroke and c.CardStroke.Thickness * k or 0
					if cb.x0 < hb.x1 and cb.x1 > hb.x0 then
						T.check(cb.y1 + stroke <= hb.y0 - 2, label .. ": a visible gap between the card and the hotbar", fmt("card bottom %.1f, hotbar top %.1f", cb.y1 + stroke, hb.y0))
					end
				end
				local compact = c.Card.AbsoluteSize.Y < c.Vitals.AbsoluteSize.Y - 2
				if size[2] < 500 then
					T.check(compact and c.Ring.AbsoluteSize.Y > 0.55 * c.Card.AbsoluteSize.Y, label .. ": a short screen gets the compact card (the dash ring spans both rows)")
				else
					T.check(not compact, label .. ": a tall screen keeps the regular card")
				end
			end
			if players > 0 then
				KC().toClient("PartyState", nil)
				advance(0.8)
			end
		end
	end
	Mock.SetViewport(390, 844)
	advance(0.8)
	KC().flushErrors("polish vitals phone")
	KC().flushWarnings("polish vitals phone")
end)

----------------------------------------------------------------------------------------------------
-- the match panel on touch screens (review: on landscape phones the token line, inset left of the tall Leave
-- button, ran into the timer "8:58" and covered the countdown numeral with "Get ready!")
----------------------------------------------------------------------------------------------------
-- the on-screen box of a label's TEXT (its alignment inside the label box), widened by `slack` for real fonts
-- (the mock measures a flat 0.5 em per character; FredokaOne digits run ~0.6 em)
local function textRect(label, slack)
	local r = rect(label)
	local k = scaleOf(label)
	local b = label.TextBounds
	local w, h = b.X * k * (slack or 1), b.Y * k
	local ax = label.TextXAlignment
	local x0
	if ax == Enum.TextXAlignment.Right then
		x0 = r.x1 - w
	elseif ax == Enum.TextXAlignment.Center then
		x0 = (r.x0 + r.x1 - w) / 2
	else
		x0 = r.x0
	end
	local cy = (r.y0 + r.y1) / 2
	return { x0 = x0, y0 = cy - h / 2, x1 = x0 + w, y1 = cy + h / 2 }
end

S.client_polish_matchpanel_mobile = guarded("client_polish_matchpanel_mobile", function()
	local SLACK = 1.2
	resetState()
	for _, size in ipairs({ { 844, 390 }, { 667, 375 }, { 390, 844 }, { 1024, 768 } }) do
		Mock.SetViewport(size[1], size[2])
		advance(1.2)
		local label = fmt("match panel (%dx%d, touch)", size[1], size[2])
		LocalPlayer:SetAttribute("InMatch", true)
		KC().toClient("MatchState", KC().matchState({}))
		advance(1.5)
		local inner = path(playerGui(), "NimbusHud.TopLeft.MatchPanel.Content.Inner")
		local timer, tokens = path(inner, "Timer"), path(inner, "Tokens")
		local leave = inner and inner:FindFirstChild("LeaveMatch", true)
		local cp = path(inner, "CheckpointBar")
		if T.check(inner ~= nil and shown(timer) and shown(tokens) and leave ~= nil and shown(cp), label .. ": the timer, the token line, Leave and the checkpoint bar are shown") then
			local tt, kt = textRect(timer, SLACK), textRect(tokens, SLACK)
			T.check(tostring(tokens.Text):find("7/24", 1, true) ~= nil and kt.x0 >= tt.x1 + 4,
				label .. ": the token count and the timer text never overlap (" .. SLACK .. "x the measured width)",
				fmt("'%s' ends at %.0f, '%s' starts at %.0f", timer.Text, tt.x1, tokens.Text, kt.x0))
			local ib = rect(inner)
			T.check(kt.x0 >= ib.x0 and kt.x1 <= ib.x1 + 1, label .. ": the token text stays inside the panel", fmt("%.0f-%.0f in %.0f-%.0f", kt.x0, kt.x1, ib.x0, ib.x1))
			local lb, cb, kb = rect(leave), rect(cp), rect(tokens)
			T.check(not overlap(kb, lb) and not overlap(kb, cb) and not overlap(tt, lb), label .. ": the token line is clear of the Leave button and the checkpoint bar (and the timer of Leave)",
				fmt("tokens y %.0f-%.0f, Leave y %.0f-%.0f, checkpoints from %.0f", kb.y0, kb.y1, lb.y0, lb.y1, cb.y0))
			T.check(tokens.TextSize * scaleOf(tokens) >= 14 and timer.TextSize * scaleOf(timer) >= 14 and lb.y1 - lb.y0 >= 30,
				label .. ": readable (>= 14 px) with a thumb-sized Leave button", fmt("tokens %.1f px, Leave %.0f px tall", tokens.TextSize * scaleOf(tokens), lb.y1 - lb.y0))

			-- the pre-match countdown: the numeral (popping in at 1.7x) and "Get ready!"
			KC().toClient("MatchState", KC().matchState({ Phase = "Countdown", Seconds = 3, Checkpoint = 0, TokensCollected = 0 }))
			advance(0.05)
			local worst = math.huge
			local detail = ""
			for _ = 1, 4 do
				local nt, gt = textRect(timer, SLACK), textRect(tokens, SLACK)
				local gap = gt.x0 - nt.x1
				if gap < worst then
					worst = gap
					detail = fmt("'%s' x%.2f ends at %.0f, '%s' starts at %.0f", timer.Text, scaleOf(timer), nt.x1, tokens.Text, gt.x0)
				end
				advance(0.15)
			end
			T.check(tokens.Text == "Get ready!" and tonumber(timer.Text) ~= nil and worst >= 4, label .. ": the countdown numeral (pop included) stays clear of 'Get ready!'", detail)
		end
		LocalPlayer:SetAttribute("InMatch", false)
		KC().toClient("MatchState", nil)
		advance(1)
	end
	Mock.SetViewport(390, 844)
	advance(0.8)
	resetState()
	KC().flushErrors("polish match panel phone")
	KC().flushWarnings("polish match panel phone")
end)

return S
