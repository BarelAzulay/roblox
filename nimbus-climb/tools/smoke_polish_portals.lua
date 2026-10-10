-- smoke_polish_portals.lua: the portal lock-in and the outside countdown (playtest polish, key "portals":
-- server/Services/PortalService.lua + the party panel of client/Controllers/HudController.lua).
-- Loaded by tools/smoke.py in BOTH worlds; ARGS.context picks the half:
--   polish_portals                 (server) the pixel-sized portal billboards (World text rule: pixel sizes, >= 22 px
--                                  names / >= 18 px info lines, outlines, compact solid plate, MaxDistance, above the
--                                  gate, the old studs-sized card gone), the lock walls (collision groups NC_PortalWall /
--                                  NC_PortalLocked: walls only collide with locked players, they enclose the pad on
--                                  every side and above), joining locks every character part, the server safety net
--                                  (walking out step by step, a teleport-fling far away, a launch into the sky) puts
--                                  the member back on the pad, the hysteresis edge is left alone, the billboard follows
--                                  the countdown and the head count (text written at most once per second, attributes),
--                                  Leave unlocks + ejects outside the walls + LEAVE_LOCKOUT + must step out first,
--                                  junk LeaveParty calls, death / leaving the game / CancelParty / a too-small party
--                                  (MinPlayers) unlock, a full party ("Full! Starting in N") launches and every member
--                                  is unlocked, a player in a match is never locked; the eye-level countdown face
--                                  (review: the billboard sits ~27 studs up, off-screen for a friend next to the pad):
--                                  a SurfaceGui in the gate's swirl facing the plaza, in front of the back lock wall,
--                                  8-14 studs up, numeral >= 3 studs, within 30 deg of the view centre of a friend 4
--                                  studs outside the walls (default camera, 10-20 deg pitch), hidden on an empty pad,
--                                  same seconds as the billboard (written once per second), 'Waiting...', 'Full! 4/4'
--   client_polish_portals          (client, 1920x1080) the party panel: big red Leave button beside the title, readable
--                                  countdown / hint / count, nothing overlaps, one LeaveParty per press, clear of the
--                                  screen middle and of the vitals
--   client_polish_portals_mobile   (phone world, 390x844 + 844x390 + 1024x768, touch) the Leave button is a >= 44 px
--                                  tall thumb target, readable (>= 14 px), clear of the touch buttons and the screen middle
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local CONTEXT = (ARGS and ARGS.context) or "server"

local LOCK_GROUP = "NC_PortalLocked"
local WALL_GROUP = "NC_PortalWall"

----------------------------------------------------------------------------------------------------
-- server world
----------------------------------------------------------------------------------------------------
local function serverScenarios()
	local K = _G.K
	local S = {}
	local advance, mod, config, fmt = K.advance, K.mod, K.config, K.fmt

	local function PS()
		return mod("PortalService")
	end
	local function infoOf(id)
		return K.W.lobbyInfo.Portals[id]
	end
	local function partyCount(id)
		return #PS().GetParty(id).Players
	end
	local function charParts(p)
		local out = {}
		if p.Character then
			for _, d in ipairs(p.Character:GetDescendants()) do
				if d:IsA("BasePart") then
					out[#out + 1] = d
				end
			end
		end
		return out
	end
	-- every / no character part in the lock group
	local function allLocked(p)
		local parts = charParts(p)
		for _, part in ipairs(parts) do
			if part.CollisionGroup ~= LOCK_GROUP then
				return false
			end
		end
		return #parts > 0
	end
	local function noneLocked(p)
		for _, part in ipairs(charParts(p)) do
			if part.CollisionGroup == LOCK_GROUP then
				return false
			end
		end
		return true
	end
	local function isLocked(p)
		local locked = PS().IsLocked(p)
		return locked == true
	end
	-- root position in the zone's own space
	local function rel(id, p)
		local r = K.root(p)
		return r and infoOf(id).Zone.CFrame:PointToObjectSpace(r.Position) or Vector3.new(1e6, 1e6, 1e6)
	end
	local function onPad(id, p, tol)
		local r = rel(id, p)
		local hs = infoOf(id).Zone.Size * 0.5
		return math.abs(r.X) <= hs.X + tol and math.abs(r.Z) <= hs.Z + tol and r.Y > -hs.Y - 2 and r.Y < hs.Y + 8
	end
	local function leave(p, ...)
		Mock.FromClient(K.remoteFolder().LeaveParty, p, ...)
	end
	local function statusText(id)
		return tostring(infoOf(id).StatusLabel and infoOf(id).StatusLabel.Text or "")
	end
	local function countText(id)
		return tostring(infoOf(id).CountLabel and infoOf(id).CountLabel.Text or "")
	end
	local function sideWalls(id)
		local out = {}
		local folder = infoOf(id).Model and infoOf(id).Model:FindFirstChild("LockWalls")
		if folder then
			for _, w in ipairs(folder:GetChildren()) do
				if w:IsA("BasePart") and w.Name ~= "Ceiling" then
					out[#out + 1] = w
				end
			end
		end
		return out
	end
	local function barrierShown(id)
		local walls = sideWalls(id)
		if #walls == 0 then
			return false
		end
		for _, w in ipairs(walls) do
			if w.Transparency >= 1 then
				return false
			end
		end
		return true
	end
	local function insideBox(part, pos)
		local r = part.CFrame:PointToObjectSpace(pos)
		local hs = part.Size * 0.5
		return math.abs(r.X) <= hs.X and math.abs(r.Y) <= hs.Y and math.abs(r.Z) <= hs.Z
	end
	local function lastPartyState(p, mark)
		local list = K.remotesFor("PartyState", p.UserId, mark)
		return list[#list]
	end
	-- the eye-level countdown face (SurfaceGui in the gate's swirl) and its labels
	local function faceOf(id)
		local info = infoOf(id)
		local part = info and (info.CountdownFace or (info.Model and info.Model:FindFirstChild("CountdownFace")))
		local gui = part and part:FindFirstChildWhichIsA("SurfaceGui")
		if not gui then
			return nil
		end
		return {
			Part = part,
			Gui = gui,
			Num = gui:FindFirstChild("NumeralLabel", true),
			Top = gui:FindFirstChild("TopLabel", true),
			Count = gui:FindFirstChild("CountLabel", true),
			Disc = gui:FindFirstChild("Disc", true),
		}
	end
	local function faceShown(id)
		local f = faceOf(id)
		return f ~= nil and f.Gui.Enabled == true
	end
	local function faceText(id, key)
		local f = faceOf(id)
		local label = f and f[key]
		return label and tostring(label.Text) or ""
	end
	-- a label's text height in studs on a SurfaceGui (UIScales included)
	local function letterStuds(label, gui)
		local k = 1
		local cur = label
		while cur and cur ~= gui do
			for _, c in ipairs(cur:GetChildren()) do
				if c:IsA("UIScale") then
					k = k * c.Scale
				end
			end
			cur = cur.Parent
		end
		return label.TextSize * k / gui.PixelsPerStud
	end

	-- A tiny Roblox-like collision-group registry patched into the mock's PhysicsService for one test (the mock's
	-- own PhysicsService methods are no-ops). A group "NC_TestPets" is registered first, like another system would.
	local function withCollisionRegistry(fn)
		local methods = Mock.Classes.PhysicsService.methods
		local names = { "IsCollisionGroupRegistered", "RegisterCollisionGroup", "GetRegisteredCollisionGroups", "CollisionGroupSetCollidable", "CollisionGroupsAreCollidable" }
		local saved = {}
		for _, n in ipairs(names) do
			saved[n] = methods[n]
		end
		local groups = { Default = true, NC_TestPets = true }
		local order = { "Default", "NC_TestPets" }
		local pair = {}
		local function key(a, b)
			if a > b then
				a, b = b, a
			end
			return a .. "|" .. b
		end
		local function collides(a, b)
			local v = pair[key(a, b)]
			if v == nil then
				return true -- engine default: groups collide
			end
			return v
		end
		methods.IsCollisionGroupRegistered = function(_, name)
			return groups[name] == true
		end
		methods.RegisterCollisionGroup = function(_, name)
			if groups[name] then
				error("collision group " .. tostring(name) .. " already exists")
			end
			groups[name] = true
			order[#order + 1] = name
		end
		methods.GetRegisteredCollisionGroups = function()
			local out = {}
			for i, n in ipairs(order) do
				out[i] = { name = n, id = i - 1, mask = 0 }
			end
			return out
		end
		methods.CollisionGroupSetCollidable = function(_, a, b, on)
			if not groups[a] or not groups[b] then
				error("unknown collision group")
			end
			pair[key(a, b)] = on and true or false
		end
		methods.CollisionGroupsAreCollidable = function(_, a, b)
			return collides(a, b)
		end
		local ok, err = pcall(fn, collides, groups)
		for _, n in ipairs(names) do
			methods[n] = saved[n]
		end
		if not ok then
			error(err, 0)
		end
	end

	S.polish_portals = guarded("polish_portals", function()
		if not K.needBoot() then
			return
		end
		local Config = config()
		local Theme = require(Mock.GetPath(ROOTS["shared"] .. "/Theme"))
		local Portal = PS()
		local MS = K.MS
		T.check(type(Portal.IsLocked) == "function" and type(Portal.CancelParty) == "function", "PortalService exposes IsLocked / CancelParty")
		local fonts = {}
		for _, f in pairs(Theme.Fonts) do
			fonts[f] = true
		end

		------------------------------------------------------------------------------------------
		-- 1. billboards (World text rule) + lock walls, on every portal
		------------------------------------------------------------------------------------------
		local boards = T.tally("every portal billboard is PIXEL-sized (offset UDim2), LightInfluence 0, not AlwaysOnTop, MaxDistance 60-130")
		local single = T.tally("the old studs-sized portal card is gone (one BillboardGui per portal)")
		local textRule = T.tally("billboard texts: not TextScaled, outlined, Theme fonts, names >= 22 px, info lines >= 18 px")
		local plates = T.tally("the billboard plate is solid, auto-sized to its text and compact (fits the container)")
		local above = T.tally("the billboard floats just above the gate (over the star gems, readable from outside)")
		local idle = T.tally("an idle portal reads '<Name>', '0/" .. Config.Match.MaxPlayers .. " players' and 'Step in to play'")
		local faces = T.tally("every portal has an eye-level CountdownFace: an invisible part (no collision / query / touch / shadow) with a SurfaceGui on its Front face (40-60 px per stud, LightInfluence 0, not AlwaysOnTop), hidden on an empty pad")
		local faceSpot = T.tally("the face sits in the gate's swirl, facing the plaza, just in front of the back lock wall (inside the enclosure), 8-14 studs above the pad")
		local faceLetters = T.tally("face letters: the numeral >= 3 studs tall (TextSize x UIScale / px per stud), 'Starting in' >= 1 stud, the head count >= 0.6 stud; outlined, not TextScaled, Theme fonts")
		local eyeLevel = T.tally("a friend 4 studs outside the front lock wall, default camera (12.5 studs behind the head, pitched 10/15/20 deg down), has the whole numeral within 30 deg of the view centre (vertical half-FOV 35 deg)")
		local eyeWorst, boardWorst = 0, 0
		local walls = T.tally("five lock walls per pad in NC_PortalWall: anchored, collidable, no Touched, no shadow, invisible while idle")
		local enclose = T.tally("the walls enclose the pad on all sides (just outside the zone) and above (clear of a full jump)")
		for _, diff in ipairs(Config.Difficulties) do
			local id = diff.Id
			local info = infoOf(id)
			local gui = info and info.Billboard
			if info and gui and gui:IsA("BillboardGui") then
				boards:case(gui.Size.X.Scale == 0 and gui.Size.Y.Scale == 0 and gui.Size.X.Offset > 0 and gui.LightInfluence == 0 and gui.AlwaysOnTop == false and gui.MaxDistance >= 60 and gui.MaxDistance <= 130, id .. ": size " .. tostring(gui.Size) .. " maxDistance " .. tostring(gui.MaxDistance))
				local n = 0
				for _, d in ipairs(info.Model:GetDescendants()) do
					if d:IsA("BillboardGui") then
						n = n + 1
					end
				end
				single:case(n == 1, id .. ": " .. n .. " BillboardGuis in Portal_" .. id)
				for _, d in ipairs(gui:GetDescendants()) do
					if d:IsA("TextLabel") then
						local floor = (d == info.TitleLabel) and 22 or 18
						local outlined = d:FindFirstChild("TextOutline") ~= nil or d.TextStrokeTransparency < 0.5
						textRule:case(not d.TextScaled and d.TextSize >= floor and outlined and fonts[d.Font] == true, id .. ": " .. d.Name .. " (" .. tostring(d.TextSize) .. " px, scaled " .. tostring(d.TextScaled) .. ")")
					end
				end
				local plate = gui:FindFirstChild("Plate")
				if plate then
					local size = plate.AbsoluteSize
					plates:case(plate.BackgroundTransparency <= 0.1 and plate.AutomaticSize == Enum.AutomaticSize.XY and size.X > 0 and size.X <= gui.Size.X.Offset and size.Y <= gui.Size.Y.Offset, id .. ": plate " .. fmt(size.X, 0) .. "x" .. fmt(size.Y, 0) .. " in " .. tostring(gui.Size))
				else
					plates:case(false, id .. ": no Plate frame")
				end
				local anchor = gui.Adornee
				local starTop = nil
				for _, d in ipairs(info.Model:GetDescendants()) do
					if d:IsA("BasePart") and (d.Name == "StarGem" or d.Name == "StarGemOff") then
						starTop = math.max(starTop or -1e9, d.Position.Y)
					end
				end
				if anchor and anchor:IsA("BasePart") then
					local y = anchor.Position.Y + gui.StudsOffsetWorldSpace.Y
					local dz = y - info.Zone.Position.Y
					above:case((starTop == nil or y >= starTop) and dz >= 8 and dz <= 40, id .. ": plate bottom " .. fmt(dz) .. " studs above the pad centre")
				else
					above:case(false, id .. ": no Adornee")
				end
				idle:case(tostring(info.TitleLabel and info.TitleLabel.Text) == diff.DisplayName and countText(id) == "0/" .. Config.Match.MaxPlayers .. " players" and statusText(id) == "Step in to play", id .. ": '" .. tostring(info.TitleLabel and info.TitleLabel.Text) .. "' / '" .. countText(id) .. "' / '" .. statusText(id) .. "'")
			else
				boards:case(false, id .. ": no BillboardGui in LobbyInfo")
			end

			-- the eye-level countdown face
			local face = faceOf(id)
			if info and face and face.Num and face.Top and face.Count then
				local part, gui = face.Part, face.Gui
				faces:case(part.Anchored and not part.CanCollide and not part.CanQuery and not part.CanTouch and not part.CastShadow and part.Transparency >= 1
					and gui.Face == Enum.NormalId.Front and gui.Adornee == part and gui.SizingMode == Enum.SurfaceGuiSizingMode.PixelsPerStud
					and gui.PixelsPerStud >= 40 and gui.PixelsPerStud <= 60 and gui.LightInfluence == 0 and gui.AlwaysOnTop == false and gui.Enabled == false,
					id .. ": " .. tostring(gui.PixelsPerStud) .. " px per stud, enabled " .. tostring(gui.Enabled))
				local zone = info.Zone
				local hs = zone.Size * 0.5
				local rel = zone.CFrame:PointToObjectSpace(part.Position)
				local above = rel.Y + hs.Y
				local toPlaza = Vector3.new(config().Lobby.Origin.X - part.Position.X, 0, config().Lobby.Origin.Z - part.Position.Z)
				local facing = toPlaza.Magnitude > 0 and part.CFrame.LookVector:Dot(toPlaza.Unit) or -1
				local back = info.Model:FindFirstChild("LockWalls") and info.Model.LockWalls:FindFirstChild("WallBack")
				local backInner = back and (zone.CFrame:PointToObjectSpace(back.Position).Z - back.Size.Z * 0.5) or math.huge
				local swirl = info.Model:FindFirstChild("SwirlCore")
				local inRing = true
				if swirl then
					local sr = swirl.CFrame:PointToObjectSpace(part.Position)
					inRing = math.abs(sr.X) < 0.5 and math.abs(sr.Y) < 0.5 and sr.Z <= -0.3 and sr.Z >= -2.5
				end
				local inWall = false
				for _, w in ipairs(info.Model.LockWalls and info.Model.LockWalls:GetChildren() or {}) do
					inWall = inWall or insideBox(w, part.Position) or insideBox(w, part.Position + part.CFrame.LookVector * part.Size.Z * 0.5)
				end
				faceSpot:case(inRing and facing > 0.9 and rel.Z + part.Size.Z * 0.5 <= backInner + 0.01 and not inWall and above >= 8 and above <= 14,
					id .. string.format(": %.1f studs up, facing %.2f, front %.2f vs back wall %.2f, in ring %s, in a wall %s", above, facing, rel.Z - part.Size.Z * 0.5, backInner, tostring(inRing), tostring(inWall)))
				local okText = true
				for _, d in ipairs(gui:GetDescendants()) do
					if d:IsA("TextLabel") then
						okText = okText and not d.TextScaled and fonts[d.Font] == true and (d:FindFirstChild("TextOutline") ~= nil or d.TextStrokeTransparency < 0.5)
					end
				end
				local num, top, cnt = letterStuds(face.Num, gui), letterStuds(face.Top, gui), letterStuds(face.Count, gui)
				faceLetters:case(okText and num >= 3 and top >= 1 and cnt >= 0.6, id .. string.format(": numeral %.2f, top %.2f, count %.2f studs", num, top, cnt))
				-- the numeral's world extent: its centre on the canvas (top-left origin), the face's top edge in world space
				local pps = gui.PixelsPerStud
				local cy = (face.Num.AbsolutePosition.Y + face.Num.AbsoluteSize.Y * 0.5) / pps
				local faceTop = rel.Y + part.Size.Y * 0.5
				local numTop, numBottom = faceTop - cy + num * 0.5, faceTop - cy - num * 0.5
				local front = back and info.Model.LockWalls:FindFirstChild("WallFront")
				local frontOuter = front and (zone.CFrame:PointToObjectSpace(front.Position).Z - front.Size.Z * 0.5) or -(hs.Z + 3.5)
				local viewerZ = frontOuter - 4
				local focusY = -hs.Y + 4.5 -- head height above the pad surface (zone space)
				local worst, worstAt = 0, ""
				for _, pitch in ipairs({ 10, 15, 20 }) do
					local p = math.rad(pitch)
					local camY, camZ = focusY + 12.5 * math.sin(p), viewerZ - 12.5 * math.cos(p)
					for _, y in ipairs({ numTop, numBottom }) do
						local off = math.deg(math.abs(math.atan2(y - camY, rel.Z - camZ) + p))
						if off > worst then
							worst, worstAt = off, string.format("%d deg pitch", pitch)
						end
					end
				end
				local boardInfo = ""
				local bgui = info.Billboard
				if bgui and bgui.Adornee then
					local by = bgui.Adornee.Position.Y + bgui.StudsOffsetWorldSpace.Y - (zone.Position.Y - hs.Y)
					local p = math.rad(15)
					local camY, camZ = focusY + hs.Y + 12.5 * math.sin(p), viewerZ - 12.5 * math.cos(p)
					local bz = zone.CFrame:PointToObjectSpace(bgui.Adornee.Position).Z
					local boardDeg = math.deg(math.atan2(by - camY, bz - camZ) + p)
					boardWorst = math.max(boardWorst, boardDeg)
					boardInfo = string.format("; the billboard's bottom edge: %.0f deg", boardDeg)
				end
				eyeWorst = math.max(eyeWorst, worst)
				eyeLevel:case(worst <= 30, id .. string.format(": numeral up to %.1f deg from the view centre (%s), viewer %.1f studs from the gate%s", worst, worstAt, (swirl and zone.CFrame:PointToObjectSpace(swirl.Position).Z or rel.Z) - viewerZ, boardInfo))
			else
				faces:case(false, id .. ": no CountdownFace with NumeralLabel / TopLabel / CountLabel")
			end

			-- lock walls
			local folder = info and info.Model and info.Model:FindFirstChild("LockWalls")
			local list = folder and folder:GetChildren() or {}
			local okWalls = #list == 5
			for _, w in ipairs(list) do
				okWalls = okWalls and w:IsA("BasePart") and w.CollisionGroup == WALL_GROUP and w.Anchored and w.CanCollide and not w.CanTouch and not w.CastShadow and w.Transparency >= 1
			end
			walls:case(okWalls, id .. ": " .. #list .. " walls")
			if folder and info then
				local zone = info.Zone
				local hs = zone.Size * 0.5
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Include
				params.FilterDescendantsInstances = { folder }
				local floorY = -hs.Y
				local horizontal = true
				for _, h in ipairs({ 0.5, 3, 6, 9, 12 }) do
					for a = 0, 7 do
						local ang = a * math.pi / 4
						local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
						local origin = zone.CFrame:PointToWorldSpace(Vector3.new(0, floorY + h, 0))
						local world = zone.CFrame:VectorToWorldSpace(dir)
						local hit = workspace:Raycast(origin, world * 40, params)
						local reach = math.max(math.abs(dir.X) > 0.01 and hs.X / math.abs(dir.X) or 1e9, 0)
						reach = math.min(reach, math.abs(dir.Z) > 0.01 and hs.Z / math.abs(dir.Z) or 1e9)
						local d = hit and (hit.Position - origin).Magnitude or 1e9
						if not (hit and d >= reach and d <= reach * 1.5 + 4) then
							horizontal = false
						end
					end
				end
				local up = workspace:Raycast(zone.CFrame:PointToWorldSpace(Vector3.new(0, floorY + 1, 0)), zone.CFrame.UpVector * 40, params)
				local ceiling = up and (up.Position - zone.CFrame:PointToWorldSpace(Vector3.new(0, floorY, 0))).Magnitude or -1
				enclose:case(horizontal and ceiling >= 12 and ceiling <= 18, id .. ": sides " .. tostring(horizontal) .. ", ceiling " .. fmt(ceiling) .. " studs above the pad")
			else
				enclose:case(false, id .. ": no LockWalls")
			end
		end
		boards:report()
		faces:report()
		faceSpot:report()
		faceLetters:report()
		eyeLevel:report(string.format("numeral at most %.1f deg off centre; the high billboard's bottom edge would be %.0f deg up at 15 deg pitch", eyeWorst, boardWorst))
		single:report()
		textRule:report()
		plates:report()
		above:report()
		idle:report()
		walls:report()
		enclose:report()

		------------------------------------------------------------------------------------------
		-- 2. joining locks the player in (collision groups as Roblox would apply them)
		------------------------------------------------------------------------------------------
		local players = K.freshPlayers(2, "Lock")
		local a, b = players[1], players[2]
		local hard = infoOf("Hard")
		local zone = hard.Zone
		withCollisionRegistry(function(collides, groups)
			local mark = K.logSize()
			K.enterPortal(a, "Hard")
			advance(0.6)
			T.eq(partyCount("Hard"), 1, "stepping into the Hard portal joins its party")
			T.check(isLocked(a), "the member is locked (PortalService.IsLocked)")
			T.eq(a:GetAttribute("PortalLocked"), "Hard", "the PortalLocked attribute names the portal")
			T.check(allLocked(a), "every character part is in the NC_PortalLocked collision group")
			T.check(groups[LOCK_GROUP] == true and groups[WALL_GROUP] == true, "the two collision groups are registered")
			T.check(collides(WALL_GROUP, LOCK_GROUP), "the walls collide with locked players")
			T.check(not collides(WALL_GROUP, "Default"), "the walls never collide with the Default group (everyone else walks through)")
			T.check(not collides(WALL_GROUP, "NC_TestPets"), "...nor with groups other systems registered (pets, ...)")
			T.check(collides(LOCK_GROUP, "Default"), "locked players still stand on the ground (NC_PortalLocked x Default)")
			T.check(barrierShown("Hard"), "the side walls shimmer (ForceField) while the countdown runs")
			T.check(K.notified(a, "Leave", "info", mark), "a side toast tells the member how to get out (Leave)")
			local st = lastPartyState(a, mark)
			T.check(st ~= nil and type(st.args[1]) == "table" and st.args[1].Locked == true, "PartyState says Locked = true")
			-- an accessory added while locked joins the lock group
			local hat = Instance.new("Part")
			hat.Name = "LockTestHat"
			hat.Parent = a.Character
			advance(0.05)
			T.eq(hat.CollisionGroup, LOCK_GROUP, "a part added to the character while locked is locked too")
		end)

		------------------------------------------------------------------------------------------
		-- 3. the server safety net
		------------------------------------------------------------------------------------------
		-- walking out step by step (the mock has no physics: the walls are checked above, the net must undo it)
		local mark = K.logSize()
		for step = 1, 8 do
			Mock.Teleport(a, zone.CFrame * CFrame.new(0, 0, -(4 + step * 1.6)))
			advance(1 / 30)
		end
		advance(0.4)
		T.check(onPad("Hard", a, 0.6) and partyCount("Hard") == 1 and isLocked(a), "walking out does not work: the member is back on the pad, still in the party and locked", "rel " .. tostring(rel("Hard", a)))
		T.check(K.notified(a, "locked in the portal", "info", mark), "...and a side toast explains the Leave button")
		-- a teleport-fling far away (exploit / physics fling)
		Mock.Teleport(a, zone.Position + Vector3.new(260, 140, -60))
		K.root(a).AssemblyLinearVelocity = Vector3.new(0, 180, 90)
		advance(0.4)
		T.check(onPad("Hard", a, 0.6) and partyCount("Hard") == 1 and isLocked(a), "a teleport-fling is undone within one poll: back on the pad", "rel " .. tostring(rel("Hard", a)))
		T.check(K.root(a).AssemblyLinearVelocity.Magnitude < 1, "...with the fling velocity cleared", tostring(K.root(a).AssemblyLinearVelocity))
		-- launched straight up through the ceiling
		Mock.Teleport(a, zone.Position + Vector3.new(0, 45, 0))
		advance(0.4)
		T.check(onPad("Hard", a, 0.6), "a launch over the ceiling is undone as well", "rel " .. tostring(rel("Hard", a)))
		-- the hysteresis edge (inside the walls, just outside the plain zone) is left alone
		local edge = zone.CFrame * CFrame.new(zone.Size.X * 0.5 + 0.8, 0, 0)
		Mock.Teleport(a, edge)
		advance(0.5)
		T.check((K.root(a).Position - edge.Position).Magnitude < 0.5 and partyCount("Hard") == 1, "standing at the pad's edge (inside the walls) is fine: no pull, still in the party")

		------------------------------------------------------------------------------------------
		-- 4. the billboard follows the countdown and the head count
		------------------------------------------------------------------------------------------
		local function shownSeconds()
			return tonumber(string.match(statusText("Hard"), "Starting in (%d+)"))
		end
		local cd = PS().GetParty("Hard").Countdown
		local shown = shownSeconds()
		T.check(shown ~= nil and cd ~= nil and math.abs(shown - cd) <= 1, "the billboard shows 'Starting in N' with the party countdown", statusText("Hard") .. " vs " .. tostring(cd))
		T.eq(countText("Hard"), "1/" .. Config.Match.MaxPlayers .. " players", "the billboard shows the players inside (1/" .. Config.Match.MaxPlayers .. ")")
		local pill = hard.Billboard:FindFirstChild("StatusPill", true)
		T.check(pill ~= nil and pill.BackgroundColor3 == (Theme.Colors.Gold or Theme.Colors.Token), "the status pill turns gold while counting down")
		T.eq(hard.Model:GetAttribute("PartyCount"), 1, "Portal_Hard attribute PartyCount = 1")
		T.check(math.abs((hard.Model:GetAttribute("Countdown") or -99) - (cd or 0)) <= 1, "Portal_Hard attribute Countdown follows the timer", tostring(hard.Model:GetAttribute("Countdown")))
		-- the eye-level face next to the pad shows the same countdown
		local faceNum = tonumber(faceText("Hard", "Num"))
		T.check(faceShown("Hard") and faceText("Hard", "Top") == "Starting in" and faceNum ~= nil and shown ~= nil and math.abs(faceNum - shown) <= 1
			and faceText("Hard", "Count") == "1/" .. Config.Match.MaxPlayers .. " players",
			"the eye-level face appears with 'Starting in', the billboard's seconds and '1/" .. Config.Match.MaxPlayers .. " players'",
			faceText("Hard", "Top") .. " / " .. faceText("Hard", "Num") .. " / " .. faceText("Hard", "Count"))
		local hardFace = faceOf("Hard")
		local rim = hardFace and hardFace.Disc and hardFace.Disc:FindFirstChildWhichIsA("UIStroke")
		T.check(rim ~= nil and rim.Color == (Theme.Colors.Gold or Theme.Colors.Token), "the face's badge rim turns gold while counting down")
		local writes, faceWrites = 0, 0
		local conn = hard.StatusLabel:GetPropertyChangedSignal("Text"):Connect(function()
			writes = writes + 1
		end)
		local faceConn = hardFace and hardFace.Num:GetPropertyChangedSignal("Text"):Connect(function()
			faceWrites = faceWrites + 1
		end)
		advance(3.0)
		conn:Disconnect()
		if faceConn then
			faceConn:Disconnect()
		end
		T.check(writes >= 2 and writes <= 4, "the server rewrites the status at most once per second (" .. writes .. " writes in 3 s)")
		T.check(faceWrites >= 2 and faceWrites <= 4, "...and the face's numeral too (" .. faceWrites .. " writes in 3 s)")
		local later = shownSeconds()
		T.check(shown ~= nil and later ~= nil and shown - later >= 2 and shown - later <= 4, "the countdown on the billboard goes down", tostring(shown) .. " -> " .. tostring(later))
		T.check(later ~= nil and tonumber(faceText("Hard", "Num")) ~= nil and math.abs(tonumber(faceText("Hard", "Num")) - later) <= 1, "the face counts down with it", faceText("Hard", "Num") .. " vs " .. tostring(later))
		-- a second player
		K.enterPortal(b, "Hard")
		advance(0.6)
		T.eq(countText("Hard"), "2/" .. Config.Match.MaxPlayers .. " players", "a second member: '2/" .. Config.Match.MaxPlayers .. " players'")
		T.eq(faceText("Hard", "Count"), "2/" .. Config.Match.MaxPlayers .. " players", "...on the face as well")
		T.check(isLocked(b) and allLocked(b), "the second member is locked as well")

		------------------------------------------------------------------------------------------
		-- 5. Leave: unlock + eject outside the walls
		------------------------------------------------------------------------------------------
		mark = K.logSize()
		leave(a)
		advance(0.3)
		T.check(not isLocked(a) and noneLocked(a) and a:GetAttribute("PortalLocked") == nil, "Leave unlocks (collision groups restored, attribute cleared)")
		T.eq(partyCount("Hard"), 1, "Leave removes only the leaver")
		local gone = lastPartyState(a, mark)
		T.check(gone ~= nil and gone.args[1] == nil, "the leaver gets PartyState(nil)")
		local r = rel("Hard", a)
		local flat = math.sqrt(r.X * r.X + r.Z * r.Z)
		local inWall = false
		for _, w in ipairs(hard.Model.LockWalls:GetChildren()) do
			inWall = inWall or insideBox(w, K.root(a).Position)
		end
		T.check(flat >= zone.Size.X * 0.5 + 3.5 and not inWall, "Leave steps the player off the pad, outside the walls", "distance " .. fmt(flat))
		advance(0.6)
		T.check(not isLocked(a) and partyCount("Hard") == 1, "the safety net leaves a player who pressed Leave alone")

		------------------------------------------------------------------------------------------
		-- 6. death (before the Hard countdown ends), then the Leave lockout on the empty pad
		------------------------------------------------------------------------------------------
		Mock.Kill(b)
		advance(0.3)
		T.check(not isLocked(b) and partyCount("Hard") == 0, "dying unlocks and leaves the party")
		T.check(not barrierShown("Hard"), "an empty pad hides the barrier shimmer")
		T.eq(statusText("Hard"), "Step in to play", "an empty portal's billboard says 'Step in to play'")
		T.eq(hard.Model:GetAttribute("Countdown"), nil, "...and its Countdown attribute is cleared")
		T.check(not faceShown("Hard"), "...and the eye-level face hides again")

		-- (the Leave step put her outside the zone, so only the lockout holds her back; the "must step out first"
		-- rule is covered by the CancelParty test below)
		K.enterPortal(a, "Hard")
		advance(1.0)
		T.check(partyCount("Hard") == 0 and not isLocked(a), "LEAVE_LOCKOUT: stepping straight back in does not re-join")
		advance(2.5)
		T.check(partyCount("Hard") == 1 and isLocked(a), "after LEAVE_LOCKOUT walking in joins (and locks) again")
		Portal.RemovePlayer(a)
		K.leavePortalArea(a)
		T.check(not isLocked(a) and noneLocked(a), "PortalService.RemovePlayer unlocks")
		leave(a, "junk", 42, { Evil = true })
		leave(a)
		advance(0.4)
		T.check(not isLocked(a) and partyCount("Hard") == 0, "LeaveParty with junk arguments / outside a party is ignored")
		K.waitFor(function()
			return b.Character ~= nil and K.hum(b) ~= nil and K.hum(b).Health > 0
		end, 12)
		advance(0.6)
		T.check(not isLocked(b) and partyCount("Hard") == 0, "the respawned player is free (not in the party)")

		------------------------------------------------------------------------------------------
		-- 7. leaving the game, CancelParty and a too-small party unlock
		------------------------------------------------------------------------------------------
		local c = K.freshPlayers(1, "Quitter")[1]
		K.enterPortal(c, "Easy")
		advance(0.6)
		T.check(isLocked(c), "precondition: the Easy member is locked")
		Mock.RemovePlayer(c)
		advance(0.4)
		T.check(not isLocked(c) and partyCount("Easy") == 0, "leaving the game unlocks and empties the seat")

		local d = K.freshPlayers(1, "Cancel")[1]
		K.enterPortal(d, "Medium")
		advance(0.6)
		T.check(isLocked(d), "precondition: the Medium member is locked")
		mark = K.logSize()
		local cancelled = Portal.CancelParty("Medium", "The portal closed")
		advance(0.3)
		T.check(cancelled == 1 and not isLocked(d) and noneLocked(d) and partyCount("Medium") == 0, "CancelParty unlocks everyone and empties the party")
		T.check(K.notified(d, "portal closed", "info", mark), "...with a side toast")
		advance(4)
		T.check(partyCount("Medium") == 0 and not isLocked(d), "after a cancel a player still on the pad must step out before re-joining")
		K.leavePortalArea(d)
		advance(0.5)

		local minBefore = Config.Match.MinPlayers
		local okMin, errMin = pcall(function()
			Config.Match.MinPlayers = 2
			K.enterPortal(d, "Extreme")
			advance(0.6)
			T.check(isLocked(d) and statusText("Extreme"):lower():find("waiting") ~= nil, "a party below MinPlayers waits (locked, 'Waiting for players...')", statusText("Extreme"))
			T.check(faceShown("Extreme") and faceText("Extreme", "Top") == "Waiting..." and tonumber(faceText("Extreme", "Num")) ~= nil, "...and the face says 'Waiting...' over the seconds left", faceText("Extreme", "Top"))
			mark = K.logSize()
			local released = K.waitFor(function()
				return not isLocked(d)
			end, Config.Match.PartyCountdown + 3)
			T.check(released and partyCount("Extreme") == 0, "when the countdown ends without enough players it is cancelled and the member unlocked")
			T.check(K.notified(d, "Not enough players", "info", mark), "...with a 'Not enough players' toast")
		end)
		Config.Match.MinPlayers = minBefore
		T.check(okMin, "MinPlayers cancel scenario ran", tostring(errMin))
		K.leavePortalArea(d)
		advance(0.5)

		------------------------------------------------------------------------------------------
		-- 8. a full party: "Full! Starting in N", launch unlocks everyone; nobody in a match is ever locked
		------------------------------------------------------------------------------------------
		local four = K.freshPlayers(Config.Match.MaxPlayers, "Squad")
		for _, p in ipairs(four) do
			K.enterPortal(p, "Saint")
			advance(0.25)
		end
		advance(0.3)
		local allIn = partyCount("Saint") == Config.Match.MaxPlayers
		for _, p in ipairs(four) do
			allIn = allIn and isLocked(p)
		end
		T.check(allIn, "four players fill the Saint party, all locked")
		T.check(statusText("Saint"):find("Full! Starting in %d") ~= nil, "a full party's billboard reads 'Full! Starting in N'", statusText("Saint"))
		T.eq(countText("Saint"), Config.Match.MaxPlayers .. "/" .. Config.Match.MaxPlayers .. " players", "...and '" .. Config.Match.MaxPlayers .. "/" .. Config.Match.MaxPlayers .. " players'")
		T.check(faceShown("Saint") and faceText("Saint", "Top") == "Starting in" and faceText("Saint", "Count") == "Full! " .. Config.Match.MaxPlayers .. "/" .. Config.Match.MaxPlayers
			and tonumber(faceText("Saint", "Num")) ~= nil and tonumber(faceText("Saint", "Num")) <= Config.Match.FullPartyCountdown,
			"the face of a full party: 'Starting in', the short countdown and 'Full! " .. Config.Match.MaxPlayers .. "/" .. Config.Match.MaxPlayers .. "'",
			faceText("Saint", "Top") .. " / " .. faceText("Saint", "Num") .. " / " .. faceText("Saint", "Count"))
		local started = K.waitFor(function()
			return MS().GetMatchOf(four[1]) ~= nil
		end, Config.Match.FullPartyCountdown + 6)
		T.check(started, "the full party launches")
		if started then
			local free = true
			for _, p in ipairs(four) do
				free = free and not isLocked(p) and noneLocked(p) and p:GetAttribute("PortalLocked") == nil
			end
			T.check(free, "launching unlocks every member (collision groups restored before the match)")
			T.eq(statusText("Saint"), "Step in to play", "the billboard is back to 'Step in to play' after the launch")
			T.eq(countText("Saint"), "0/" .. Config.Match.MaxPlayers .. " players", "...and '0/" .. Config.Match.MaxPlayers .. " players'")
			T.check(not barrierShown("Saint"), "...and the barrier is off")
			T.check(not faceShown("Saint"), "...and the face is hidden")
			-- a player in a match standing in a portal zone (as the server sees it) is refused
			K.enterPortal(four[2], "Easy")
			advance(0.6)
			T.check(partyCount("Easy") == 0 and not isLocked(four[2]), "a player in a match is never put in a party or locked")
		end
		K.endAllMatches(four)
		advance(1)
		local home = true
		for _, p in ipairs(four) do
			home = home and not isLocked(p) and noneLocked(p)
		end
		T.check(home, "back in the lobby after the match: nobody is locked")

		K.removePlayers(four)
		K.removePlayers({ a, b, d })
		K.flushErrors("polish portals")
		K.flushWarnings("polish portals")
	end)

	return S
end

----------------------------------------------------------------------------------------------------
-- client world
----------------------------------------------------------------------------------------------------
local function clientScenarios()
	local KC = _G.KC
	local S = {}
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer

	local function advance(seconds)
		Mock.Advance(seconds)
	end
	local function playerGui()
		return LocalPlayer:FindFirstChild("PlayerGui")
	end
	local function named(root, name)
		if not root then
			return nil
		end
		for _, d in ipairs(root:GetDescendants()) do
			if d.Name == name then
				return d
			end
		end
		return nil
	end
	local function shown(obj)
		return obj ~= nil and KC.isShown(obj)
	end
	local function rect(inst)
		local g = inst:FindFirstAncestorOfClass("ScreenGui")
		local dy = (g and g.IgnoreGuiInset) and -(Mock.TopInset or 0) or 0
		local p, s = inst.AbsolutePosition, inst.AbsoluteSize
		return { x0 = p.X, y0 = p.Y + dy, x1 = p.X + s.X, y1 = p.Y + s.Y + dy }
	end
	local function overlap(a, b)
		return a.x0 < b.x1 - 0.5 and a.x1 > b.x0 + 0.5 and a.y0 < b.y1 - 0.5 and a.y1 > b.y0 + 0.5
	end
	local function band()
		local tol = CONTRACT.v2.centreTolerance
		local vp, inset = Mock.Viewport, Mock.TopInset or 0
		return { x0 = vp.X * (0.5 - tol), x1 = vp.X * (0.5 + tol), y0 = vp.Y * (0.5 - tol) - inset, y1 = vp.Y * (0.5 + tol) - inset }
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
	local function partyState(n, countdown, max)
		local list = { { UserId = LocalPlayer.UserId, Name = LocalPlayer.Name } }
		local names = { "Buddy", "Skye", "Nimbus Fan" }
		for i = 2, n do
			list[i] = { UserId = 7000 + i, Name = names[i - 1] or ("P" .. i) }
		end
		return {
			PortalId = "Extreme", DifficultyName = "Extreme", Color = Color3.fromRGB(214, 92, 104),
			Players = list, Max = max or 4, Countdown = countdown, Locked = true,
		}
	end

	-- one party-panel audit at the current viewport; floorPx = smallest allowed on-screen text
	local function audit(label, floorPx, minButtonH, minButtonW)
		local hud = playerGui():FindFirstChild("NimbusHud")
		local panel = named(hud, "PartyPanel")
		local leaveBtn = named(panel, "LeaveParty")
		if not T.check(panel ~= nil and shown(leaveBtn) and leaveBtn:IsA("TextButton"), label .. ": the party panel shows a Leave button") then
			return nil
		end
		local k = scaleOf(leaveBtn)
		local box = rect(leaveBtn)
		T.check(tostring(leaveBtn.Text) == "Leave", label .. ": the button says 'Leave'", tostring(leaveBtn.Text))
		T.check(box.y1 - box.y0 >= minButtonH and box.x1 - box.x0 >= minButtonW, label .. ": the Leave button is big (>= " .. minButtonW .. "x" .. minButtonH .. " px on screen)", string.format("%.0fx%.0f", box.x1 - box.x0, box.y1 - box.y0))
		T.check(leaveBtn.TextSize >= 22 and leaveBtn.TextSize * k >= floorPx, label .. ": the Leave text is big (>= 22 design px, " .. floorPx .. "+ px on screen)", string.format("%d design px -> %.1f px", leaveBtn.TextSize, leaveBtn.TextSize * k))
		local panelBox = rect(panel)
		T.check(box.x0 >= panelBox.x0 - 1 and box.x1 <= panelBox.x1 + 1 and box.y0 >= panelBox.y0 - 1 and box.y1 <= panelBox.y1 + 1, label .. ": the Leave button sits inside the party panel")
		-- the texts of the panel: readable and not on top of each other / the button
		local texts = {}
		for _, d in ipairs(panel:GetDescendants()) do
			if (d:IsA("TextLabel") or d:IsA("TextButton")) and shown(d) and tostring(d.Text) ~= "" then
				texts[#texts + 1] = d
			end
		end
		local small, clash = {}, {}
		for i, t in ipairs(texts) do
			local px = t.TextSize * scaleOf(t)
			if px < floorPx - 0.01 then
				small[#small + 1] = t.Name .. string.format(" %.1f px", px)
			end
			if t ~= leaveBtn and not t:IsDescendantOf(leaveBtn) and overlap(rect(t), box) then
				clash[#clash + 1] = t.Name .. " x Leave"
			end
			for j = i + 1, #texts do
				local u = texts[j]
				if not t:IsDescendantOf(leaveBtn) and not u:IsDescendantOf(leaveBtn) and not t:IsAncestorOf(u) and not u:IsAncestorOf(t) and t.Parent ~= nil and overlap(rect(t), rect(u)) and not (t.Parent.Name:find("^Chip") and u.Parent == t.Parent) then
					clash[#clash + 1] = t.Name .. " x " .. u.Name
				end
			end
		end
		T.check(#small == 0, label .. ": every party panel text is >= " .. floorPx .. " px", table.concat(small, ", "))
		T.check(#clash == 0, label .. ": no party panel text overlaps another one or the Leave button", table.concat(clash, ", "))
		-- the countdown line fits its row (estimated 0.5 em per glyph, like the mock's text metrics)
		local status = named(panel, "Status")
		if status then
			local need = Mock.TextExtent(status) * scaleOf(status)
			T.check(need <= status.AbsoluteSize.X + 1, label .. ": the countdown line fits ('" .. tostring(status.Text) .. "')", string.format("needs %.0f px, has %.0f", need, status.AbsoluteSize.X))
		end
		-- out of the middle of the screen, clear of the vitals and the touch buttons
		local b = band()
		T.check(not overlap(box, b), label .. ": the Leave button stays out of the middle of the screen")
		local vitals = named(hud, "Vitals")
		if vitals and shown(vitals) then
			T.check(not overlap(panelBox, rect(vitals)), label .. ": the party panel never covers the HP / stamina block")
		end
		local mobile = playerGui():FindFirstChild("MobileControls")
		if mobile and mobile.Enabled then
			local hit = {}
			for _, d in ipairs(mobile:GetDescendants()) do
				if (d:IsA("TextButton") or d:IsA("ImageButton")) and shown(d) and overlap(rect(d), panelBox) then
					hit[#hit + 1] = d.Name
				end
			end
			T.check(#hit == 0, label .. ": the party panel clears the touch buttons", table.concat(hit, ", "))
		end
		return leaveBtn, panel
	end

	local function reset()
		LocalPlayer:SetAttribute("InMatch", false)
		KC.toClient("MatchState", nil)
		KC.toClient("PartyState", nil)
		advance(0.8)
	end

	S.client_polish_portals = guarded("client_polish_portals", function()
		reset()
		KC.toClient("PartyState", partyState(2, 12))
		advance(1.0)
		local leaveBtn = audit("party panel 1920x1080", 15, 44, 108)
		T.check(KC.findText("starting in 12s") ~= nil or KC.findText("starting in 11s") ~= nil, "the panel counts down ('Starting in 12s')", KC.allShownText())
		T.check(KC.findText("locked until launch") ~= nil, "the panel explains the lock ('Locked until launch')")
		T.check(KC.findText("2/4") ~= nil, "the panel shows the head count ('2/4')")
		if leaveBtn then
			local before = #KC.serverCalls("LeaveParty")
			Mock.Click(leaveBtn)
			Mock.Click(leaveBtn)
			advance(0.2)
			T.eq(#KC.serverCalls("LeaveParty"), before + 1, "a double click sends ONE LeaveParty")
			advance(1.0)
			Mock.Click(leaveBtn)
			advance(0.2)
			T.eq(#KC.serverCalls("LeaveParty"), before + 2, "a later press sends another one")
		end
		-- a full party (4 chips, the tallest panel)
		KC.toClient("PartyState", partyState(4, 3))
		advance(1.0)
		T.check(KC.findText("full! starting in") ~= nil, "a full party reads 'Full! Starting in Ns'", KC.allShownText())
		audit("full party 1920x1080", 15, 44, 108)
		for _, size in ipairs({ { 1280, 720 }, { 2560, 1440 } }) do
			Mock.SetViewport(size[1], size[2])
			advance(1.2)
			audit("full party " .. size[1] .. "x" .. size[2], 14, 36, 90)
		end
		Mock.SetViewport(1920, 1080)
		advance(0.6)
		KC.toClient("PartyState", nil)
		advance(1.0)
		T.check(not shown(named(playerGui(), "LeaveParty")), "PartyState(nil) hides the panel and its Leave button")
		KC.flushErrors("polish portals client")
		KC.flushWarnings("polish portals client")
	end)

	S.client_polish_portals_mobile = guarded("client_polish_portals_mobile", function()
		reset()
		local mobile = playerGui():FindFirstChild("MobileControls")
		T.check(mobile ~= nil and mobile.Enabled, "(phone) the touch controls are on screen (precondition)")
		for _, size in ipairs({ { 390, 844 }, { 844, 390 }, { 1024, 768 } }) do
			Mock.SetViewport(size[1], size[2])
			advance(1.2)
			for _, n in ipairs({ 2, 4 }) do
				KC.toClient("PartyState", partyState(n, 9))
				advance(1.0)
				local label = "phone " .. size[1] .. "x" .. size[2] .. " (" .. n .. " players)"
				local leaveBtn = audit(label, 14, 44, 76) -- a squeezed panel trims the button to 100 design px wide
				if leaveBtn and n == 2 then
					local before = #KC.serverCalls("LeaveParty")
					Mock.Click(leaveBtn)
					advance(0.2)
					T.eq(#KC.serverCalls("LeaveParty"), before + 1, label .. ": a tap on Leave fires LeaveParty")
					advance(0.8)
				end
			end
			KC.toClient("PartyState", nil)
			advance(0.8)
		end
		Mock.SetViewport(390, 844)
		advance(0.6)
		KC.flushErrors("polish portals phone")
		KC.flushWarnings("polish portals phone")
	end)

	return S
end

if CONTEXT == "server" then
	return serverScenarios()
end
return clientScenarios()
