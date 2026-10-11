-- smoke_p2_visual.lua: the Phase 2 visual pass (ARCHITECTURE_V3.md ART DIRECTION, Readability + World text rules,
-- "Phase 2 build contract"). Loaded by tools/smoke.py in BOTH worlds; ARGS.context picks the half:
--   p2visual_art    (server) the station art the visual pass reworked, level by level (HomeBuilder.BuildStationModel):
--                   the Fusion Machine keeps its contract parts (two tinted input pods + the output pod = 3 PodGlass,
--                   the Chamber, a Swirl of >= 3 parts, SwirlCenter, the FusionPrompt on an Attachment by the output
--                   pod) inside its 90-part budget, with breathing neon "Glow" parts, gold from level 2 and crystals
--                   at 3; every locked Garden bed carries a seedling; the Gym's ropes run along the back and the sides
--                   only (nothing between the yard and the training pets); the Sky Castle has its rose window
--   p2visual_plot   (server, booted) a private test plot: the staked-out house lot (owned, no House yet: stakes, a
--                   string, planks and bricks, no collisions, <= 12 parts; gone with the House, back after a prestige
--                   reset, kept by ClearPlot while owned, never on a free plot); a locked station's ghost is a
--                   ForceField hologram (light, no collisions, no prompts, <= 12 parts); the Prestige pad's sign says
--                   what the reset buys ("Reset: x1.25 income")
--   client_p2visual (client) HomeFx shows the sign of one of the local player's LOCKED pads only up close (its
--                   unlocked pads keep their signs from afar), Garden pets stand bigger than Gym pets; the Fusion
--                   window's locked card is opaque with a teaser line, a Mix pick mark sits in the tile's top-left
--                   corner clear of the pet; the Shop's Secret roulette hint is the short one-liner
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local CONTEXT = (ARGS and ARGS.context) or "server"

local abs, max, min, huge = math.abs, math.max, math.min, math.huge

local function parts(root)
	local out = {}
	if not root then
		return out
	end
	if root:IsA("BasePart") then
		out[#out + 1] = root
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			out[#out + 1] = d
		end
	end
	return out
end

local function named(root, name)
	local out = {}
	for _, p in ipairs(parts(root)) do
		if p.Name == name then
			out[#out + 1] = p
		end
	end
	return out
end

local function find(root, name, className)
	if not root then
		return nil
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == name and (not className or d:IsA(className)) then
			return d
		end
	end
	return nil
end

local function plainText(root)
	local out = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TextLabel") then
			out[#out + 1] = d.Text
		end
	end
	return table.concat(out, " | ")
end

-- model height (studs) over its visible parts
local function height(root)
	local y0, y1 = huge, -huge
	for _, p in ipairs(parts(root)) do
		if p.Transparency < 1 then
			local h = p.Size.Y / 2
			y0, y1 = min(y0, p.Position.Y - h), max(y1, p.Position.Y + h)
		end
	end
	return (y1 > y0) and (y1 - y0) or 0
end

----------------------------------------------------------------------------------------------------
-- server half
----------------------------------------------------------------------------------------------------
local function serverScenarios()
	local K = _G.K
	local S = {}

	local function requireAt(key)
		local inst = K.moduleInstance(key)
		if not inst then
			return nil
		end
		local ok, result = pcall(require, inst)
		if ok and type(result) == "table" then
			return result
		end
		return nil
	end

	S.p2visual_art = guarded("p2visual_art", function()
		local HB = requireAt("server/Services/HomeBuilder")
		local TC = requireAt("shared/TycoonCatalog")
		if not (type(HB) == "table" and type(HB.BuildStationModel) == "function" and type(TC) == "table") then
			T.warn("visual art: HomeBuilder.BuildStationModel or TycoonCatalog missing, skipped")
			return
		end

		-- the Fusion Machine at every level
		local fusion = T.tally("visual art: the Fusion Machine keeps its contract parts at every level (3 PodGlass, Chamber, Swirl >= 3 parts, FusionPrompt by the output pod) in <= 90 parts")
		local look = T.tally("visual art: the Fusion Machine reads at a glance (two differently tinted input pods, >= 3 breathing neon Glow parts, gold from level 2, crystals at 3)")
		local def = TC.Get("FusionMachine")
		for level = 1, (def and def.MaxLevel or 3) do
			local ok, m = pcall(HB.BuildStationModel, "FusionMachine", level)
			if not ok or typeof(m) ~= "Instance" then
				fusion:case(false, "level " .. level .. ": " .. tostring(m))
			else
				local list = parts(m)
				local pods = named(m, "PodGlass")
				local swirl = m:FindFirstChild("Swirl")
				local prompt = find(m, "FusionPrompt", "ProximityPrompt")
				local att = prompt and prompt.Parent
				local output = nil
				for _, p in ipairs(pods) do
					if not output or p.Size.Y < output.Size.Y then
						output = p -- the output pod's dome is the low one
					end
				end
				local near = att ~= nil and att:IsA("Attachment") and output ~= nil and (att.WorldPosition - output.Position).Magnitude <= 2
				fusion:case(#pods == 3 and find(m, "Chamber", "BasePart") ~= nil and swirl ~= nil and #parts(swirl) >= 3 and near and #list <= 90,
					"level " .. level .. ": " .. #pods .. " pods, " .. #list .. " parts, prompt by the output " .. tostring(near))
				local tints = {}
				for _, p in ipairs(pods) do
					if p ~= output then
						tints[#tints + 1] = p.Color
					end
				end
				local differ = #tints == 2 and (abs(tints[1].R - tints[2].R) + abs(tints[1].G - tints[2].G) + abs(tints[1].B - tints[2].B)) > 0.2
				local glows = 0
				for _, p in ipairs(named(m, "Glow")) do
					if p.Material == Enum.Material.Neon then
						glows = glows + 1
					end
				end
				local gold = #named(m, "Gold") > 0
				local crystals = #named(m, "Crystal")
				look:case(differ and glows >= 3 and (level < 2 or gold) and (level < 3 or crystals >= 3),
					"level " .. level .. ": tints differ " .. tostring(differ) .. ", " .. glows .. " glows, gold " .. tostring(gold) .. ", " .. crystals .. " crystals")
			end
		end
		fusion:report()
		look:report()

		-- the Garden: a seedling on every locked bed
		local garden = T.tally("visual art: every locked Pet Garden bed carries a seedling (Stem + Sprout), open beds none")
		local gdef = TC.Get("Garden")
		local places = (gdef and gdef.Slot and gdef.Slot.Spots) and #gdef.Slot.Spots or 8
		for level = 1, (gdef and gdef.MaxLevel or 8) do
			local ok, m = pcall(HB.BuildStationModel, "Garden", level)
			if ok and typeof(m) == "Instance" then
				local stems, sprouts = #named(m, "Stem"), #named(m, "Sprout")
				garden:case(stems == places - level and sprouts == places - level, "level " .. level .. ": " .. stems .. " stems, " .. sprouts .. " sprouts")
			else
				garden:case(false, "level " .. level .. ": " .. tostring(m))
			end
		end
		garden:report()

		-- the Gym: the ropes never run between the yard (front, -Z) and the training places
		local gym = T.tally("visual art: the Gym's ring ropes run along the back and the sides only (the yard sees the training pets)")
		local ydef = TC.Get("Gym")
		local spotZ = 0
		for _, p in ipairs((ydef and ydef.Slot and ydef.Slot.Spots) or {}) do
			spotZ = max(spotZ, p.Z)
		end
		for level = 1, (ydef and ydef.MaxLevel or 5) do
			local ok, m = pcall(HB.BuildStationModel, "Gym", level)
			if ok and typeof(m) == "Instance" then
				local bad, sides = nil, 0
				for _, p in ipairs(parts(m)) do
					if p.Name == "Rope" or p.Name == "Rope2" then
						if p.Size.X >= p.Size.Z then
							if p.Position.Z <= spotZ then
								bad = p.Name .. " at z " .. string.format("%.1f", p.Position.Z)
							end
						else
							sides = sides + 1
						end
					end
				end
				gym:case(bad == nil and (level < 4 or sides >= 2), "level " .. level .. ": " .. tostring(bad or (sides .. " side ropes")))
			else
				gym:case(false, "level " .. level .. ": " .. tostring(m))
			end
		end
		gym:report()

		-- the Sky Castle's facade centrepiece
		local okH, castle = pcall(HB.BuildStationModel, "House", 4)
		if okH and typeof(castle) == "Instance" then
			local rose = 0
			for _, p in ipairs(named(castle, "WarmWindow")) do
				if abs(p.Position.X) < 2.5 and p.Position.Y > 9.5 and p.Position.Y < 14.5 then
					rose = rose + 1
				end
			end
			T.check(rose >= 1 and #parts(castle) <= 150, "visual art: the Sky Castle has a lit rose window over its gate (within its 150 parts)", rose .. " pieces, " .. #parts(castle) .. " parts")
		end
	end)

	S.p2visual_plot = guarded("p2visual_plot", function()
		local HB = requireAt("server/Services/HomeBuilder")
		local TC = requireAt("shared/TycoonCatalog")
		if not (type(HB) == "table" and type(TC) == "table") then
			T.warn("visual plot: HomeBuilder or TycoonCatalog missing, skipped")
			return
		end
		local root = Instance.new("Folder")
		root.Name = "SmokeVisualHomes"
		root.Parent = workspace
		local spotFolder = Instance.new("Folder")
		spotFolder.Name = "Spot_93"
		spotFolder.Parent = root
		local plotCF = CFrame.new(-4000, 300, -4000) * CFrame.Angles(0, math.rad(-90), 0)
		local spot = { Index = 93, PlotCFrame = plotCF, PlotSize = TC.PlotSize, Center = plotCF.Position, Folder = spotFolder }
		local home = HB.PreparePlot(spot)
		if not T.check(typeof(home) == "Instance", "visual plot: PreparePlot makes a test plot") then
			root:Destroy()
			return
		end
		T.check(home:FindFirstChild("HouseLot") == nil, "visual plot: a free plot has no house lot (the lobby's part budget)")
		local owner = Mock.AddPlayer("VisualSmoke", 963777)
		K.advance(0.5)
		HB.SetOwner(spot, owner)
		local lot = home:FindFirstChild("HouseLot")
		local solid = false
		for _, p in ipairs(parts(lot)) do
			if p.CanCollide or p.CanTouch or p.CanQuery then
				solid = true
			end
		end
		T.check(lot ~= nil and #parts(lot) > 0 and #parts(lot) <= 12 and not solid and #named(lot, "Stake") == 4 and #named(lot, "String") == 4,
			"visual plot: a claimed plot without a House shows the staked-out house lot (4 stakes, a string, planks, bricks; <= 12 parts, no collisions)",
			lot and (#parts(lot) .. " parts") or "none")
		if lot then
			-- the lot sits on the House slot
			local slot = plotCF * TC.Get("House").Slot.CFrame
			local c = Vector3.new(0, 0, 0)
			local n = 0
			for _, p in ipairs(named(lot, "Stake")) do
				c = c + p.Position
				n = n + 1
			end
			c = c / max(1, n)
			local loc = slot:PointToObjectSpace(c)
			T.check(abs(loc.X) < 2 and abs(loc.Z) < 4, "visual plot: ...where the house will stand (the House slot)", string.format("%.1f, %.1f", loc.X, loc.Z))
		end
		HB.SetStation(spot, "Collector", 1)
		T.check(home:FindFirstChild("HouseLot") ~= nil, "visual plot: other stations leave the lot alone")
		HB.SetStation(spot, "House", 1)
		T.check(home:FindFirstChild("HouseLot") == nil, "visual plot: building the House clears the lot")
		HB.SetStation(spot, "House", 0)
		T.check(home:FindFirstChild("HouseLot") ~= nil, "visual plot: the lot is back when the House resets (a prestige)")
		HB.ClearPlot(spot)
		T.check(home:FindFirstChild("HouseLot") ~= nil, "visual plot: ClearPlot keeps the lot while the plot is owned (like the paths)")

		-- a ghost for a station that unlocks later: a ForceField hologram
		local fusionPad = nil
		for _, pad in ipairs(TC.AvailablePads({ Stations = { Press1 = 3, Press2 = 2, Collector = 1, House = 1, Garden = 1, Kitchen = 1 }, Prestige = 0 })) do
			if pad.StationId == "FusionMachine" then
				fusionPad = pad
			end
		end
		if fusionPad and fusionPad.Locked then
			HB.SetPads(spot, { fusionPad })
			local ghost = home:FindFirstChild("Ghost_FusionMachine")
			local holo, bad = 0, nil
			for _, p in ipairs(parts(ghost)) do
				if p.Material == Enum.Material.ForceField and p.Transparency < 0.9 and (p.Color.R + p.Color.G + p.Color.B) > 1.2 then
					holo = holo + 1
				end
				if p.CanCollide or p.CanQuery or p.CanTouch then
					bad = p.Name
				end
			end
			T.check(ghost ~= nil and holo == #parts(ghost) and holo > 0 and holo <= 12 and bad == nil and find(ghost, "BuyPrompt") == nil,
				"visual plot: a station that unlocks later shows a light ForceField hologram (no collisions, no prompts, <= 12 parts)", ghost and (holo .. " of " .. #parts(ghost)) or "no ghost")
		else
			T.warn("visual plot: the Fusion Machine pad is not locked in the test home, ghost check skipped")
		end

		-- the Prestige pad says what the reset buys
		local prestigePad = {
			StationId = "Prestige", Prestige = true, NextLevel = 1, Level = 0, MaxLevel = 1, Price = 0,
			Title = "Prestige 1", Name = "Prestige", Kind = "Prestige", LevelText = "0 -> 1", Icon = "*",
		}
		HB.SetPads(spot, { prestigePad })
		local pad = home:FindFirstChild("Pads") and home.Pads:FindFirstChild("Pad_Prestige")
		local sign = pad and find(pad, "PadSign", "BillboardGui")
		local text = sign and plainText(sign) or ""
		local mult = (type(TC.Prestige) == "table" and tonumber(TC.Prestige.IncomeMultiplier)) or 1.25
		local want = "x" .. (string.format("%.2f", mult):gsub("0+$", ""):gsub("%.$", ""))
		T.check(text:find("Prestige 1", 1, true) ~= nil and text:find(want, 1, true) ~= nil and text:find("income", 1, true) ~= nil,
			"visual plot: the Prestige pad's sign says what the reset buys ('Reset: " .. want .. " income')", text)

		HB.SetOwner(spot, nil)
		T.check(home:FindFirstChild("HouseLot") == nil, "visual plot: freeing the plot removes the lot")
		root:Destroy()
		Mock.RemovePlayer(owner)
		K.advance(0.2)
	end)

	return S
end

----------------------------------------------------------------------------------------------------
-- client half
----------------------------------------------------------------------------------------------------
local function clientScenarios()
	local KC = _G.KC
	local S = {}
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local LocalPlayer = Players.LocalPlayer
	local advance = KC and KC.advance or function(s)
		Mock.Advance(s)
	end

	local function moduleAt(top, rest)
		local inst = Mock.GetPath(ROOTS[top] .. "/" .. rest)
		if not inst then
			return nil
		end
		local ok, result = pcall(require, inst)
		return ok and type(result) == "table" and result or nil
	end

	local function pg()
		return LocalPlayer:FindFirstChildOfClass("PlayerGui")
	end

	local function toClient(name, ...)
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local remote = remotes and remotes:FindFirstChild(name)
		if remote then
			Mock.ToClient(remote, ...)
		end
	end

	local function snapshot(prestige, fusion)
		return {
			Tokens = 12450,
			Pets = { pebble_pup = 3, honey_bunny = 1, pip_penguin = 1, mallow_kitten = 1, maple_fox = 1, cloudy_dragon = 1 },
			Equipped = { "cloudy_dragon" },
			Items = {},
			Stats = { Matches = 0, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = {} },
			Perks = { MaxHealth = 0, TokenBonus = 0, StaminaRegen = 0, CheckpointHeal = 0 },
			Discovered = { pebble_pup = true, honey_bunny = true, pip_penguin = true },
			IndexClaimed = {},
			Tutorial = { Step = 15, Done = true, Gifted = true },
			Cash = 48250, Gems = 1820,
			Home = { Level = 20, Prestige = prestige, Stations = { Press1 = 5, Collector = 2, House = 2, Kitchen = 1, FusionMachine = fusion }, Garden = {}, Gym = {}, CollectorCash = 0 },
			Food = {},
			Tiers = {},
			Hybrids = {},
			PetLevels = {},
		}
	end

	S.client_p2visual = guarded("client_p2visual", function()
		local outputBefore, errorsBefore = #Mock.Output, #Mock.Errors
		local HF = (KC and KC.M and KC.M.HomeFx) or moduleAt("client", "Controllers/HomeFx")
		local HB = moduleAt("server", "Services/HomeBuilder")
		local TC = moduleAt("shared", "TycoonCatalog")

		-- HomeFx: the local player's locked pads show their sign only up close
		if HF and HB and TC then
			HF.Init()
			local root = Instance.new("Folder")
			root.Name = "SmokeVisualClient"
			root.Parent = workspace
			local base = CFrame.new(3000, 300, -3000)
			local folder = Instance.new("Folder")
			folder.Name = "Spot_86"
			folder.Parent = root
			local spot = { Index = 86, PlotCFrame = base, PlotSize = TC.PlotSize, Center = base.Position, Folder = folder }
			HB.PreparePlot(spot)
			HB.SetOwner(spot, LocalPlayer)
			local state = { Stations = { Press1 = 6, Press2 = 3, Collector = 2, House = 1, Garden = 2, Kitchen = 1, Gym = 1 }, Prestige = 0 }
			HB.BuildHome(spot, state)
			HB.SetPads(spot, TC.AvailablePads(state))
			HB.SetStation(spot, "Garden", 2)
			HB.SetStation(spot, "Gym", 1)
			local petId = "pebble_pup"
			folder:SetAttribute("GardenPets", "1=" .. petId)
			folder:SetAttribute("GymPets", "1=" .. petId)
			local character = LocalPlayer.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			local savedHrp = hrp and hrp.CFrame
			local savedAnchored = hrp and hrp.Anchored
			if hrp then
				hrp.Anchored = true -- stand still where the test puts the player (no falling off the test plot)
			end
			local cam = workspace.CurrentCamera
			local savedCam = cam and cam.CFrame
			local function standAt(pos)
				if hrp then
					hrp.CFrame = CFrame.new(pos)
				end
				if cam then
					cam.CFrame = CFrame.lookAt(pos + Vector3.new(0, 20, -30), pos)
				end
			end
			-- far away: at the gate of the plot looking in from the street (the yard's far corner is > 60 studs off)
			standAt(base * Vector3.new(0, 4, -TC.PlotSize / 2 - 6))
			advance(1.0)
			local signs = {}
			for _, d in ipairs(folder:GetDescendants()) do
				if d:IsA("BillboardGui") and d.Name == "PadSign" then
					local pad = d:FindFirstAncestorWhichIsA("Model")
					while pad and pad:GetAttribute("StationId") == nil do
						pad = pad.Parent and pad.Parent:FindFirstAncestorWhichIsA("Model")
					end
					if pad then
						signs[#signs + 1] = { Gui = d, Pad = pad, Locked = (pad:GetAttribute("Locked") or "") ~= "" }
					end
				end
			end
			local focus = hrp and hrp.Position or (cam and cam.CFrame.Position)
			local farLocked, farLockedShown, unlockedShown, unlocked = 0, 0, 0, 0
			local nearest, nearestD = nil, huge
			for _, s in ipairs(signs) do
				local anchor = s.Gui.Adornee or s.Gui.Parent
				local d = (anchor.Position - focus).Magnitude
				if s.Locked then
					if d > 40 then
						farLocked = farLocked + 1
						if s.Gui.Enabled then
							farLockedShown = farLockedShown + 1
						end
					end
					if d > 40 and d < nearestD then
						nearest, nearestD = s, d
					end
				else
					unlocked = unlocked + 1
					if s.Gui.Enabled then
						unlockedShown = unlockedShown + 1
					end
				end
			end
			T.check(farLocked > 0 and farLockedShown == 0, "HomeFx: the local player's locked pads keep their lock signs hidden from afar (the yard shows what can be bought now)",
				farLockedShown .. " of " .. farLocked .. " far locked signs shown")
			T.check(unlocked > 0 and unlockedShown == unlocked, "HomeFx: ...while its unlocked pads keep their signs", unlockedShown .. " of " .. unlocked)
			if nearest then
				local anchor = nearest.Gui.Adornee or nearest.Gui.Parent
				standAt(anchor.Position + Vector3.new(4, 3, 4))
				advance(0.6)
				T.check(nearest.Gui.Enabled, "HomeFx: walking up to a locked pad shows its sign (the lock reason)")
				standAt(anchor.Position + Vector3.new(80, 3, 80))
				advance(0.6)
				T.check(not nearest.Gui.Enabled, "HomeFx: ...and walking away hides it again")
			end
			-- garden pets stand bigger than gym pets (5 studs between cushions, 3 between targets)
			standAt(base * Vector3.new(0, 4, -10))
			advance(1.5)
			local pets = workspace:FindFirstChild("ClientFx") and workspace.ClientFx:FindFirstChild("HomePets")
			local gardenH, gymH = 0, 0
			for _, m in ipairs(pets and pets:GetChildren() or {}) do
				if m:GetAttribute("PetKey") == petId then
					if m.Name == "GardenPet" then
						gardenH = max(gardenH, height(m))
					elseif m.Name == "GymPet" then
						gymH = max(gymH, height(m))
					end
				end
			end
			T.check(gardenH > 0 and gymH > 0 and gardenH > gymH * 1.08, "HomeFx: Garden pets stand full size, Gym pets a little smaller (their places are closer)",
				string.format("garden %.2f, gym %.2f", gardenH, gymH))
			if hrp and savedHrp then
				hrp.CFrame = savedHrp
				hrp.Anchored = savedAnchored
			end
			if cam and savedCam then
				cam.CFrame = savedCam
			end
			root:Destroy()
			advance(0.3)
		else
			T.warn("visual client: HomeFx / HomeBuilder / TycoonCatalog missing, HomeFx checks skipped")
		end

		-- the Fusion window
		local FC = (KC and KC.M and KC.M.FusionController) or moduleAt("client", "Controllers/FusionController")
		if FC and type(FC.Open) == "function" then
			LocalPlayer:SetAttribute("InMatch", false)
			toClient("ProfileSync", snapshot(0, 0))
			advance(0.4)
			FC.Open("Upgrade", {})
			advance(0.6)
			local window = pg() and find(pg(), "Window_Fusion")
			local locked = window and find(window, "Locked")
			local sub = locked and locked:FindFirstChild("Sub")
			T.check(locked ~= nil and locked.Visible and locked.BackgroundTransparency == 0 and sub ~= nil and sub.Visible and sub.Text ~= "",
				"Fusion window: before the machine, an opaque locked card (nothing of the preview shows through) with a teaser line")
			FC.Close()
			advance(0.3)
			toClient("ProfileSync", snapshot(1, 1))
			advance(0.4)
			FC.Open("Mix", {})
			advance(0.4)
			if type(FC.Select) == "function" then
				FC.Select("pip_penguin", "honey_bunny")
			end
			advance(0.6)
			local marks = {}
			for _, d in ipairs(window and window:GetDescendants() or {}) do
				if d.Name == "Mark" and d:IsA("TextLabel") and d.Visible then
					marks[#marks + 1] = d
				end
			end
			local cornerOk = #marks >= 1
			for _, mark in ipairs(marks) do
				local tile = mark.Parent
				local view = tile and tile:FindFirstChild("View")
				local mp, ms = mark.AbsolutePosition, mark.AbsoluteSize
				local tp = tile.AbsolutePosition
				local inCorner = mp.X - tp.X <= 12 and mp.Y - tp.Y <= 12
				local clear = true
				if view then
					local c = view.AbsolutePosition + view.AbsoluteSize / 2
					clear = not (c.X >= mp.X and c.X <= mp.X + ms.X and c.Y >= mp.Y and c.Y <= mp.Y + ms.Y)
				end
				if not (inCorner and clear) then
					cornerOk = false
				end
			end
			T.check(cornerOk, "Fusion window: the Mix pick marks (1 = Body, 2 = Style) sit in the tile's top-left corner, clear of the pet", #marks .. " marks")
			FC.Close()
			advance(0.3)
		else
			T.warn("visual client: FusionController missing, Fusion window checks skipped")
		end

		-- the Shop's Secret roulette hint: the short one-liner
		local MC = (KC and KC.M and KC.M.MenuController) or moduleAt("client", "Controllers/MenuController")
		if MC and type(MC.Open) == "function" then
			local restricted = LocalPlayer:GetAttribute("PaidRandomItemsRestricted")
			LocalPlayer:SetAttribute("PaidRandomItemsRestricted", false) -- GemService: gem roulettes allowed here
			LocalPlayer:SetAttribute("Gems", 99999)
			toClient("ProfileSync", snapshot(1, 1))
			advance(0.3)
			MC.Open("Shop", { Tab = "Gems" })
			advance(0.8)
			local card = pg() and find(pg(), "GemRoulette_Secret")
			local hint = card and find(card, "Hint", "TextLabel")
			if card and card.Visible and hint then
				T.check(hint.Text == "" or (#hint.Text <= 32 and hint.Text:find("Mythic or Secret", 1, true) ~= nil) or hint.Text:find("closed", 1, true) ~= nil or hint.Text:find("Need", 1, true) ~= nil,
					"Shop Gems tab: the Secret roulette's hint is the short one-liner (no orphan word on a second line)", hint.Text)
			else
				T.info("Shop Gems tab: the Secret roulette card is not shown here (policy / config), hint check skipped")
			end
			if type(MC.Close) == "function" then
				MC.Close()
			end
			LocalPlayer:SetAttribute("Gems", nil)
			LocalPlayer:SetAttribute("PaidRandomItemsRestricted", restricted)
			advance(0.3)
		end

		local warned = nil
		for i = outputBefore + 1, #Mock.Output do
			local o = Mock.Output[i]
			if o.kind == "warn" and (o.text:find("HomeFx", 1, true) or o.text:find("FusionController", 1, true)) then
				warned = o.text
			end
		end
		T.check(warned == nil and #Mock.Errors == errorsBefore, "visual client: no errors or warnings from HomeFx / FusionController", tostring(warned))
		if KC and KC.flushErrors then
			KC.flushErrors("client_p2visual")
		end
	end)

	return S
end

if CONTEXT == "server" then
	return serverScenarios()
end
return clientScenarios()
