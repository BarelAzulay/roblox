-- smoke_p2_fusion.lua: Phase 2 Fusion Machine (ARCHITECTURE_V3.md section 11 and the FusionService / FusionController
-- paragraph of the "Phase 2 build contract"): server/Services/FusionService.lua, client/Controllers/FusionController.lua
-- and the PetBuilder finishes / hybrid looks (shared/PetBuilder.lua). Loaded by tools/smoke.py in BOTH worlds;
-- ARGS.context picks the half:
--   p2fusion_looks     (server, content) Golden / Rainbow copies of several pets at High and Low: budgets, PB_Finish,
--                      a gold body with unchanged eyes, metallic accents, glowing sparkle stars that pulse, a gold
--                      sparkle emitter; a Rainbow copy has many hues, only a few hue-cycling parts and a rainbow
--                      emitter, and Animate cycles their hue (throttled, other parts untouched); fused hybrids: every
--                      Body species x every Style species builds within the budgets at High and Low (Normal, Golden,
--                      Rainbow), carries PB_Hybrid, the Style species adds a feature (it differs from the same merged
--                      look without the trait), the seed varies the look, the same seed rebuilds the same look, and
--                      no hybrid feature floats (no more isolated parts than the Body pet has)
--   p2fusion_upgrade   (server, booted) FusionService API; requirements (Prestige 1, the Fusion Machine, not in a match,
--                      loaded profile); Upgrade 3 copies -> Golden -> Rainbow (counts, the exact TycoonCatalog cost with
--                      the machine discount, toast, the "Result" answer, ProfileSync, Fused signal, levels kept);
--                      refusals change nothing (2 copies, Rainbow, hybrids, short of tokens, junk keys)
--   p2fusion_mix       (server, booted) Mix: the hybrid record (Body, Style, both elements, blended name, higher
--                      rarity, the lower tier, a look seed), inputs gone, Token cost / Gem cost for Mythic + Secret
--                      inputs, PetKeys.DefOf of the result (stats = average x1.2), the hybrid level = the parents'
--                      average; refusals (same pet twice, hybrid inputs, short of gems, a full hybrid collection)
--   p2fusion_exploits  (server, booted) equipped copies are taken off first and the result takes their slot; the
--                      "only equipped pets" rule and its way out; Garden / Gym copies are freed and the result takes
--                      the slot; atomic (a full result stack refuses before anything changes); the Fusion remote:
--                      junk arguments, spam (one fusion per cooldown), no home claimed, too far from the machine, near it
--   client_p2fusion    (client) FusionController: the NimbusFusion window opens with OpenPanel("Fusion") and with E on
--                      the player's own FusionPrompt (not on someone else's), the plan mirrors the server (result,
--                      cost, rules), FUSE sends Fusion("Upgrade" / "Mix", ...), the fusion animation plays on the
--                      server's "Result" (NEW! tag, then back to picking), a refusal shows its reason, hybrids are not
--                      offered, readable text sizes (>= 18 design px), the menu / a match closes it, no errors
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded
local CONTEXT = (ARGS and ARGS.context) or "server"

local abs, floor, max, min = math.abs, math.floor, math.max, math.min

local function fmt(v, n)
	if type(v) ~= "number" then
		return tostring(v)
	end
	return string.format("%." .. (n or 2) .. "f", v)
end

local function parts(root)
	local out = {}
	if not root then
		return out
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			out[#out + 1] = d
		end
	end
	return out
end

local function signature(model)
	local list = {}
	for _, p in ipairs(parts(model)) do
		local pos = p.Position
		list[#list + 1] = string.format("%s:%.2f,%.2f,%.2f:%.2f,%.2f,%.2f:%s", p.Name, p.Size.X, p.Size.Y, p.Size.Z, pos.X, pos.Y, pos.Z, p.Color:ToHex())
	end
	table.sort(list)
	return table.concat(list, ";")
end

local function countKeys(map)
	local n = 0
	for _ in pairs(type(map) == "table" and map or {}) do
		n = n + 1
	end
	return n
end

-- world-space axis-aligned bounds of a (possibly rotated) part
local function aabb(p)
	local cf, s = p.CFrame, p.Size
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local hx = (abs(r00) * s.X + abs(r01) * s.Y + abs(r02) * s.Z) / 2
	local hy = (abs(r10) * s.X + abs(r11) * s.Y + abs(r12) * s.Z) / 2
	local hz = (abs(r20) * s.X + abs(r21) * s.Y + abs(r22) * s.Z) / 2
	local c = cf.Position
	return c.X - hx, c.Y - hy, c.Z - hz, c.X + hx, c.Y + hy, c.Z + hz
end

-- parts that touch no other visible part (the invisible root and the floating-by-design aura / halo excluded)
local function isolated(model)
	local list = {}
	for _, p in ipairs(parts(model)) do
		local n = p.Name
		if not (n == "Body" and p.Transparency >= 1) and not n:find("^Aura") and not n:find("^Halo") then
			list[#list + 1] = { p, { aabb(p) } }
		end
	end
	local tol = 0.03
	local out = {}
	for i, a in ipairs(list) do
		local ba = a[2]
		local touching = false
		for j, b in ipairs(list) do
			if i ~= j then
				local bb = b[2]
				if ba[1] <= bb[4] + tol and bb[1] <= ba[4] + tol and ba[2] <= bb[5] + tol and bb[2] <= ba[5] + tol and ba[3] <= bb[6] + tol and bb[3] <= ba[6] + tol then
					touching = true
					break
				end
			end
		end
		if not touching then
			out[#out + 1] = a[1].Name
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- server half
----------------------------------------------------------------------------------------------------
local function serverScenarios()
	local K = _G.K
	local S = {}
	local advance, config, mod = K.advance, K.config, K.mod

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

	local function PB()
		return requireAt("shared/PetBuilder")
	end
	local function PK()
		return requireAt("shared/PetKeys")
	end
	local function PC()
		return requireAt("shared/PetCatalog")
	end
	local function TC()
		return requireAt("shared/TycoonCatalog")
	end
	local function FS()
		return requireAt("server/Services/FusionService")
	end
	local function DS()
		return mod("DataService")
	end
	local function PS()
		return mod("PetService")
	end

	-- one catalog pet per species (the first in catalog order)
	local function speciesReps()
		local reps, seen = {}, {}
		for _, def in ipairs(PC().Pets) do
			local sp = def.Look.Species
			if not seen[sp] then
				seen[sp] = true
				reps[#reps + 1] = def
			end
		end
		return reps
	end

	------------------------------------------------------------------------------------------------
	-- p2fusion_looks (content)
	------------------------------------------------------------------------------------------------
	S.p2fusion_looks = guarded("p2fusion_looks", function()
		local B, Keys, Cat = PB(), PK(), PC()
		if not T.check(B ~= nil and Keys ~= nil and Cat ~= nil, "fusion looks: PetBuilder, PetKeys and PetCatalog load") then
			return
		end
		local Neon, Metal = Enum.Material.Neon, Enum.Material.Metal
		local sample = { "pebble_pup", "mallow_kitten", "cloudy_dragon", "candy_unicorn", "pip_penguin", "stormfang", "ember_phoenix" }
		local fin = T.tally("fusion looks: Golden / Rainbow copies build at High (<= 350 parts) and Low (<= 120) and carry PB_Finish (Normal copies none)")
		local goldBody = T.tally("fusion looks: a Golden copy's biggest body part turns gold (warm hue, saturated) and most of its colours change")
		local eyes = T.tally("fusion looks: finishes keep the eye colours (iris, pupil, shine, glint parts unchanged)")
		local sparks = T.tally("fusion looks: a Golden copy has glowing sparkle stars (GoldSpark, Neon, pulsing) and a gold FinishSparkles emitter")
		local rainbow = T.tally("fusion looks: a Rainbow copy shows many hues, at most 10 (High) / 4 (Low) hue-cycling parts, and a FinishSparkles emitter")
		local metal = 0
		for _, id in ipairs(sample) do
			local base = Cat.Get(id)
			for _, detail in ipairs({ "High", "Low" }) do
				local cap = (detail == "High") and 350 or 120
				local normal = B.Build(base, { Detail = detail })
				local g = B.Build(Keys.DefOf(id .. "@Golden"), { Detail = detail })
				local r = B.Build(Keys.DefOf(id .. "@Rainbow"), { Detail = detail })
				local ng, nr = #parts(g), #parts(r)
				fin:case(ng <= cap and nr <= cap, id .. " " .. detail .. ": " .. ng .. " / " .. nr .. " parts")
				fin:case(normal:GetAttribute("PB_Finish") == nil and g:GetAttribute("PB_Finish") == "Golden" and r:GetAttribute("PB_Finish") == "Rainbow", id .. " " .. detail .. ": PB_Finish")
				-- gold body
				local biggest, vol = nil, -1
				for _, p in ipairs(parts(g)) do
					local v = p.Size.X * p.Size.Y * p.Size.Z
					if p.Transparency < 1 and v > vol then
						biggest, vol = p, v
					end
				end
				local h, s = 0, 0
				if biggest then
					h, s = biggest.Color:ToHSV()
				end
				local changed, total = 0, 0
				local normalColors = {}
				for _, p in ipairs(parts(normal)) do
					normalColors[p.Color:ToHex()] = true
				end
				for _, p in ipairs(parts(g)) do
					if p.Transparency < 1 then
						total = total + 1
						if not normalColors[p.Color:ToHex()] then
							changed = changed + 1
						end
					end
				end
				goldBody:case(biggest ~= nil and h >= 0.06 and h <= 0.17 and s >= 0.3 and changed >= total * 0.5,
					id .. " " .. detail .. ": hue " .. fmt(h) .. " sat " .. fmt(s) .. ", " .. changed .. "/" .. total .. " recoloured")
				-- eyes unchanged: every eye part (iris, pupil, shine, glint) keeps its colour
				local function eyeColors(m)
					local out = {}
					for _, p in ipairs(parts(m)) do
						local base = p.Name:match("^(Eye%a+)")
						if base and base ~= "EyeLid" then
							out[base] = out[base] or p.Color:ToHex()
						end
					end
					return out
				end
				local ne, ge, re = eyeColors(normal), eyeColors(g), eyeColors(r)
				local same = next(ne) ~= nil
				for name, c in pairs(ne) do
					if ge[name] ~= c or re[name] ~= c then
						same = false
					end
				end
				local list = {}
				for name, c in pairs(ne) do
					list[#list + 1] = name .. "=" .. c .. "/" .. tostring(ge[name]) .. "/" .. tostring(re[name])
				end
				eyes:case(same, id .. " " .. detail .. ": " .. table.concat(list, " "))
				-- sparkles + emitter
				local stars, pulsing = 0, 0
				for _, p in ipairs(parts(g)) do
					if p.Name:find("^GoldSpark") then
						stars = stars + 1
						if p.Material == Neon and type(p:GetAttribute("PB_Pulse")) == "number" then
							pulsing = pulsing + 1
						end
					end
					if p.Material == Metal then
						metal = metal + 1
					end
				end
				local gEmit = g.PrimaryPart and g.PrimaryPart:FindFirstChild("FinishSparkles")
				sparks:case(stars >= 1 and pulsing == stars and gEmit ~= nil and gEmit:IsA("ParticleEmitter"), id .. " " .. detail .. ": " .. stars .. " stars, " .. pulsing .. " pulsing, emitter " .. tostring(gEmit ~= nil))
				-- rainbow
				local hues, cycling = {}, 0
				for _, p in ipairs(parts(r)) do
					local ph, ps, pv = p.Color:ToHSV()
					if ps >= 0.3 and pv >= 0.85 then
						hues[floor(ph * 12) % 12] = true
					end
					if type(p:GetAttribute("PB_Hue")) == "number" then
						cycling = cycling + 1
					end
				end
				local limit = (detail == "High") and 10 or 4
				local rEmit = r.PrimaryPart and r.PrimaryPart:FindFirstChild("FinishSparkles")
				rainbow:case(countKeys(hues) >= ((detail == "High") and 4 or 3) and cycling >= 1 and cycling <= limit and rEmit ~= nil,
					id .. " " .. detail .. ": " .. countKeys(hues) .. " hues, " .. cycling .. " cycling, emitter " .. tostring(rEmit ~= nil))
				normal:Destroy()
				g:Destroy()
				r:Destroy()
			end
		end
		fin:report()
		goldBody:report()
		eyes:report()
		sparks:report()
		rainbow:report()
		T.check(metal > 0, "fusion looks: Golden copies have metallic gold accents (Metal parts: claws, horns, beaks, wing edges...)", metal .. " metal parts over the sample")

		-- Animate: the Rainbow hue cycle (client side) is throttled and only touches the flagged parts
		local r = B.Build(Keys.DefOf("pebble_pup@Rainbow"))
		local flagged, other = nil, nil
		for _, p in ipairs(parts(r)) do
			if type(p:GetAttribute("PB_Hue")) == "number" then
				flagged = flagged or p
			elseif p.Transparency < 1 and p.Name ~= "Body" and not p:GetAttribute("PB_Pulse") then
				other = other or p
			end
		end
		if T.check(flagged ~= nil and other ~= nil, "fusion looks: (precondition) a Rainbow model has hue-cycling and plain parts") then
			B.Animate(r, 10)
			local c1, o1 = flagged.Color, other.Color
			B.Animate(r, 10.02)
			local c2 = flagged.Color
			B.Animate(r, 10.6)
			local c3, o3 = flagged.Color, other.Color
			local h1 = c1:ToHSV()
			local h3, s3, v3 = c3:ToHSV()
			local _, s1, v1 = c1:ToHSV()
			T.check(c1 == c2 and c1 ~= c3, "fusion looks: Animate cycles a Rainbow part's hue at most ~12 times a second (two calls 0.02 s apart change nothing)", c1:ToHex() .. " " .. c2:ToHex() .. " " .. c3:ToHex())
			T.check(abs(s3 - s1) < 0.02 and abs(v3 - v1) < 0.02 and abs(h3 - h1) > 0.05, "fusion looks: ...only the hue turns (saturation and brightness stay)")
			T.check(o1 == o3, "fusion looks: ...and the other parts keep their colour")
		end
		r:Destroy()

		-- hybrids: every Body species x every Style species (Normal, High + Low), Golden / Rainbow on a diagonal
		local reps = speciesReps()
		local budget = T.tally("fusion looks: every Body species x Style species hybrid builds within the budgets (High <= 350, Low <= 120) and carries PB_Hybrid")
		local trait = T.tally("fusion looks: the Style species adds its feature (the hybrid differs from the same merged look without the trait)")
		local floats = T.tally("fusion looks: no hybrid feature floats (a hybrid has no more isolated parts than its Body pet)")
		local uid = 0
		local bodyIsolated = {}
		for _, a in ipairs(reps) do
			local m = B.Build(a)
			bodyIsolated[a.Id] = #isolated(m)
			m:Destroy()
		end
		local builds = 0
		for ai, a in ipairs(reps) do
			for bi, b in ipairs(reps) do
				if a ~= b then
					uid = uid + 1
					local tier = "Normal"
					if (ai + bi) % 7 == 0 then
						tier = "Golden"
					elseif (ai + bi) % 7 == 3 then
						tier = "Rainbow"
					end
					local id = "s" .. uid
					local prof = { Hybrids = { [id] = { Body = a.Id, Style = b.Id, Tier = tier, Seed = uid * 13 } } }
					local def = Keys.DefOf(Keys.HybridKey(id, tier), prof)
					for _, detail in ipairs({ "High", "Low" }) do
						local ok, m = pcall(B.Build, def, { Detail = detail })
						builds = builds + 1
						if not ok then
							budget:case(false, a.Id .. " + " .. b.Id .. " " .. detail .. ": " .. tostring(m))
						else
							local n = #parts(m)
							budget:case(n <= ((detail == "High") and 350 or 120) and m:GetAttribute("PB_Hybrid") == true, a.Id .. " + " .. b.Id .. " " .. tier .. " " .. detail .. ": " .. n .. " parts")
							if detail == "High" then
								local iso = isolated(m)
								floats:case(#iso <= bodyIsolated[a.Id], a.Id .. " + " .. b.Id .. ": " .. #iso .. " isolated (" .. table.concat(iso, ",") .. ") vs " .. bodyIsolated[a.Id])
								if tier == "Normal" then
									-- the same merged look without the trait
									local plain = {}
									for k, v in pairs(def) do
										plain[k] = v
									end
									local look = {}
									for k, v in pairs(def.Look) do
										look[k] = v
									end
									look.Hybrid = nil
									look.Seed = nil
									plain.Look = look
									plain.Id = def.Id .. "_plain"
									local okP, pm = pcall(B.Build, plain)
									if okP then
										local sameParts = signature(pm):gsub("Pet_[^;]*", "") == signature(m):gsub("Pet_[^;]*", "")
										trait:case(not sameParts, a.Id .. " + " .. b.Id .. ": looks exactly like the merged look without its trait")
										pm:Destroy()
									end
								end
							end
							m:Destroy()
						end
					end
				end
			end
			B.ClearCache()
		end
		budget:report(builds .. " builds")
		trait:report()
		floats:report()

		-- seeds: a different seed varies the look, the same seed rebuilds the same look
		local function hybridSig(body, style, seed)
			local prof = { Hybrids = { seedtest = { Body = body, Style = style, Seed = seed } } }
			local m = B.Build(Keys.DefOf("hyb:seedtest", prof))
			local sig = signature(m)
			m:Destroy()
			return sig
		end
		local pairsToTry = { { "pebble_pup", "maple_fox" }, { "pip_penguin", "ember_phoenix" }, { "mallow_kitten", "bubble_axolotl" }, { "cloudy_dragon", "twilight_dragon" } }
		local varied, stable = T.tally("fusion looks: two seeds give two different looks"), T.tally("fusion looks: the same seed always gives the same look (deterministic, also after ClearCache)")
		for _, pr in ipairs(pairsToTry) do
			local s1 = hybridSig(pr[1], pr[2], 11)
			local s2 = hybridSig(pr[1], pr[2], 977)
			B.ClearCache()
			local s1b = hybridSig(pr[1], pr[2], 11)
			varied:case(s1 ~= s2, pr[1] .. " + " .. pr[2])
			stable:case(s1 == s1b, pr[1] .. " + " .. pr[2])
		end
		varied:report()
		stable:report()

		-- the Style can come from Look.StyleId alone (no StyleDef: e.g. a def built from the EquippedHybrids attribute)
		local prof = { Hybrids = { solo = { Body = "pebble_pup", Style = "bubble_axolotl", Seed = 5 } } }
		local def = Keys.DefOf("hyb:solo", prof)
		local bare = {}
		for k, v in pairs(def) do
			bare[k] = v
		end
		bare.StyleDef = nil
		bare.BodyDef = nil
		B.ClearCache()
		local m1 = B.Build(def)
		local s1 = signature(m1)
		B.ClearCache()
		local m2 = B.Build(bare)
		T.check(s1 == signature(m2), "fusion looks: a hybrid def without StyleDef finds its Style parent through Look.StyleId (same look)")
		m1:Destroy()
		m2:Destroy()
		B.ClearCache()
	end)

	------------------------------------------------------------------------------------------------
	-- booted helpers
	------------------------------------------------------------------------------------------------
	local userSeq = 0
	local function join(prefix)
		userSeq = userSeq + 1
		local p = Mock.AddPlayer(prefix .. userSeq, 974000 + userSeq)
		advance(1.0)
		return p
	end

	local function leave(p)
		if p and p.Parent then
			Mock.RemovePlayer(p)
		end
		advance(0.6)
	end

	-- Home.Prestige and Home.Stations (only the given ones) straight into the save
	local function setHome(p, prestige, stations)
		return DS().MutateHome(p, function(h)
			h.Prestige = prestige
			for id in pairs(h.Stations) do
				h.Stations[id] = nil
			end
			for id, lv in pairs(stations or {}) do
				h.Stations[id] = lv
			end
			local Cat = TC()
			if Cat and type(Cat.HomeLevelOf) == "function" then
				h.Level = Cat.HomeLevelOf(h)
			end
		end)
	end

	local function give(p, key, n)
		local prof = DS().GetProfile(p)
		local ok = PK().Add(prof, key, n or 1)
		DS().MarkDirty(p)
		return ok
	end

	local function count(p, key)
		return PK().Count(DS().GetProfile(p), key)
	end

	local function toasted(p, needle, mark)
		for _, e in ipairs(K.remotesFor("Notify", p.UserId, mark or 0)) do
			if string.find(tostring(e.args[1]), needle, 1, true) then
				return true
			end
		end
		return false
	end

	local function results(p, mark)
		local out = {}
		for _, e in ipairs(K.remotesFor("Fusion", p.UserId, mark or 0)) do
			if e.args[1] == "Result" and type(e.args[2]) == "table" then
				out[#out + 1] = e.args[2]
			end
		end
		return out
	end

	local function lastSnapshot(p, mark)
		local list = K.remotesFor("ProfileSync", p.UserId, mark or 0)
		local e = list[#list]
		return e and e.args[1] or nil
	end

	local function tokenCost(action, rarity, tier, level)
		local c = TC().FusionCost(action, rarity, tier, level)
		return c and c.Tokens, c and c.Gems
	end

	local function remote(name)
		return K.remoteFolder():FindFirstChild(name)
	end

	local function fuseRemote(p, ...)
		Mock.FromClient(remote("Fusion"), p, ...)
	end

	-- a ready fuser: Prestige 1 + Fusion Machine level `level` and plenty of tokens / gems
	local function readyPlayer(prefix, level)
		local p = join(prefix)
		setHome(p, 1, { FusionMachine = level or 1, Kitchen = 1 })
		DS().AddTokens(p, 1000000)
		DS().AddGems(p, 1000)
		return p
	end

	------------------------------------------------------------------------------------------------
	-- p2fusion_upgrade
	------------------------------------------------------------------------------------------------
	S.p2fusion_upgrade = guarded("p2fusion_upgrade", function()
		if not K.needBoot() then
			return
		end
		local F, DataS, Keys, Cat = FS(), DS(), PK(), TC()
		if not T.check(type(F) == "table" and type(F.Init) == "function", "fusion: server/Services/FusionService.lua loads with Init (the contract)") then
			return
		end
		for _, fn in ipairs({ "Upgrade", "Mix", "Preview", "Unlocked" }) do
			T.check(type(F[fn]) == "function", "fusion: FusionService." .. fn .. " is a function")
		end
		T.check(type(F.Fused) == "table" and type(F.Fused.Connect) == "function", "fusion: FusionService.Fused is a signal")
		local fired = {}
		F.Fused:Connect(function(player, action, key)
			fired[#fired + 1] = { player, action, key }
		end)

		local p = join("Fuser")
		local prof = DataS.GetProfile(p)
		if not T.check(prof ~= nil, "fusion: (precondition) the profile loads") then
			return
		end
		give(p, "pebble_pup", 3)
		DataS.AddTokens(p, 100000)
		local tokens0 = DataS.GetTokens(p)

		-- requirements
		local ok, why = F.Upgrade(p, "pebble_pup")
		T.check(not ok and tostring(why):find("Prestige", 1, true) ~= nil and count(p, "pebble_pup") == 3 and DataS.GetTokens(p) == tokens0,
			"fusion: refused before Prestige 1 (nothing used)", tostring(why))
		setHome(p, 1, {})
		ok, why = F.Upgrade(p, "pebble_pup")
		T.check(not ok and tostring(why):find("Fusion Machine", 1, true) ~= nil and count(p, "pebble_pup") == 3, "fusion: refused without the Fusion Machine station", tostring(why))
		setHome(p, 1, { FusionMachine = 1, Kitchen = 1 })
		local okU, whyU, info = F.Unlocked(p)
		T.check(okU == true and type(info) == "table" and info.Prestige == 1 and info.MachineLevel == 1, "fusion: Unlocked() with Prestige 1 and the machine", tostring(whyU))
		p:SetAttribute(config().Attr.InMatch, true)
		ok, why = F.Upgrade(p, "pebble_pup")
		T.check(not ok and tostring(why):lower():find("match", 1, true) ~= nil and count(p, "pebble_pup") == 3, "fusion: refused during a match", tostring(why))
		p:SetAttribute(config().Attr.InMatch, false)

		-- preview
		local okP, plan = F.Preview(p, "Upgrade", "pebble_pup")
		local want = tokenCost("Upgrade", "Common", "Golden", 1)
		T.check(okP and type(plan) == "table" and plan.ResultKey == "pebble_pup@Golden" and plan.Cost and plan.Cost.Tokens == want and plan.Tier == "Golden",
			"fusion: Preview(Upgrade) names the result, the tier and the TycoonCatalog cost (and changes nothing)", okP and plan and tostring(plan.ResultKey) .. " " .. tostring(plan.Cost and plan.Cost.Tokens) or tostring(plan))
		T.check(count(p, "pebble_pup") == 3 and DataS.GetTokens(p) == tokens0, "fusion: ...Preview changed nothing")

		-- Upgrade: 3 Normal -> 1 Golden
		local lv = Keys.Make("pebble_pup")
		prof.PetLevels = prof.PetLevels or {}
		prof.PetLevels[lv] = { Level = 7, Xp = 3 }
		local mark = K.logSize()
		ok, why = F.Upgrade(p, "pebble_pup")
		advance(0.3)
		T.check(ok == true and why == "pebble_pup@Golden", "fusion: Upgrade(3 Normal copies) -> the Golden key", tostring(why))
		T.check(count(p, "pebble_pup") == 0 and count(p, "pebble_pup@Golden") == 1 and type(prof.Tiers.pebble_pup) == "table" and prof.Tiers.pebble_pup.Golden == 1,
			"fusion: ...the 3 copies are gone and Tiers[petId].Golden = 1")
		T.eq(DataS.GetTokens(p), tokens0 - want, "fusion: ...the exact TycoonCatalog.FusionCost(Upgrade, rarity, Golden, machine level) in Cloud Tokens was paid")
		T.check(toasted(p, "Golden Pebble Pup", mark), "fusion: ...a side toast names the new pet")
		local res = results(p, mark)
		T.check(#res == 1 and res[1].Ok == true and res[1].Key == "pebble_pup@Golden" and res[1].Action == "Upgrade", "fusion: ...the server answers Fusion(\"Result\", {Ok, Key, Action}) for the window", #res .. " results")
		local snap = lastSnapshot(p, mark)
		T.check(snap ~= nil and type(snap.Tiers) == "table" and type(snap.Tiers.pebble_pup) == "table" and snap.Tiers.pebble_pup.Golden == 1 and (snap.Pets.pebble_pup == nil or snap.Pets.pebble_pup == 0),
			"fusion: ...the ProfileSync shows the new copy")
		T.check(#fired >= 1 and fired[#fired][1] == p and fired[#fired][2] == "Upgrade" and fired[#fired][3] == "pebble_pup@Golden", "fusion: ...Fused fires (player, action, key)")
		local glevel = prof.PetLevels["pebble_pup@Golden"]
		T.check(type(glevel) == "table" and glevel.Level == 7, "fusion: ...the upgraded copy keeps its level (PetLevels of the result raised to the inputs' level)", glevel and tostring(glevel.Level) or "none")

		-- Golden -> Rainbow, with the machine discount at level 3
		setHome(p, 1, { FusionMachine = 3, Kitchen = 1 })
		give(p, "pebble_pup@Golden", 2)
		local t1 = DataS.GetTokens(p)
		local wantR = tokenCost("Upgrade", "Common", "Rainbow", 3)
		ok, why = F.Upgrade(p, "pebble_pup@Golden")
		T.check(ok == true and why == "pebble_pup@Rainbow" and count(p, "pebble_pup@Golden") == 0 and count(p, "pebble_pup@Rainbow") == 1, "fusion: Upgrade(3 Golden copies) -> Rainbow", tostring(why))
		T.check(DataS.GetTokens(p) == t1 - wantR and wantR < tokenCost("Upgrade", "Common", "Rainbow", 1), "fusion: ...a level-3 machine's TokenDiscount makes it cheaper", tostring(t1 - DataS.GetTokens(p)) .. " paid, " .. tostring(wantR) .. " wanted")

		-- refusals change nothing
		local function unchanged(label, fn)
			local before = {
				Normal = count(p, "pebble_pup"), Golden = count(p, "pebble_pup@Golden"), Rainbow = count(p, "pebble_pup@Rainbow"),
				Tokens = DataS.GetTokens(p), Gems = DataS.GetGems(p), Hybrids = countKeys(prof.Hybrids),
			}
			local okR, whyR = fn()
			local same = count(p, "pebble_pup") == before.Normal and count(p, "pebble_pup@Golden") == before.Golden and count(p, "pebble_pup@Rainbow") == before.Rainbow
				and DataS.GetTokens(p) == before.Tokens and DataS.GetGems(p) == before.Gems and countKeys(prof.Hybrids) == before.Hybrids
			T.check(okR ~= true and same and type(whyR) == "string" and whyR ~= "", "fusion: refused, nothing changed: " .. label, tostring(whyR))
		end
		give(p, "pebble_pup", 2)
		unchanged("only 2 copies", function()
			return F.Upgrade(p, "pebble_pup")
		end)
		give(p, "pebble_pup@Rainbow", 2)
		unchanged("Rainbow is the best finish", function()
			return F.Upgrade(p, "pebble_pup@Rainbow")
		end)
		unchanged("a junk key", function()
			return F.Upgrade(p, "no such pet!")
		end)
		unchanged("an unknown pet", function()
			return F.Upgrade(p, "not_a_pet")
		end)
		unchanged("a non-string key", function()
			return F.Upgrade(p, 42)
		end)
		Keys.Add(prof, "hyb:upg1", 1, { Body = "pebble_pup", Style = "maple_fox" })
		unchanged("a hybrid (one of a kind)", function()
			return F.Upgrade(p, "hyb:upg1")
		end)
		give(p, "pebble_pup", 1)
		DataS.SpendTokens(p, DataS.GetTokens(p))
		unchanged("not enough Cloud Tokens", function()
			return F.Upgrade(p, "pebble_pup")
		end)
		local okBad = pcall(F.Upgrade, nil, "pebble_pup")
		T.check(okBad, "fusion: Upgrade(nil player) does not error")
		leave(p)
	end)

	------------------------------------------------------------------------------------------------
	-- p2fusion_mix
	------------------------------------------------------------------------------------------------
	S.p2fusion_mix = guarded("p2fusion_mix", function()
		if not K.needBoot() then
			return
		end
		local F, DataS, Keys, PCat = FS(), DS(), PK(), PC()
		if not F then
			T.fail("fusion: FusionService missing")
			return
		end
		local p = readyPlayer("Mixer", 1)
		local prof = DataS.GetProfile(p)
		give(p, "pip_penguin", 1)
		give(p, "ember_phoenix", 1)
		local penguin, phoenix = PCat.Get("pip_penguin"), PCat.Get("ember_phoenix")
		prof.PetLevels = prof.PetLevels or {}
		prof.PetLevels.pip_penguin = { Level = 4, Xp = 0 }
		prof.PetLevels.ember_phoenix = { Level = 9, Xp = 0 }
		local tokens0, gems0 = DataS.GetTokens(p), DataS.GetGems(p)
		local mark = K.logSize()
		local ok, key = F.Mix(p, "pip_penguin", "ember_phoenix")
		advance(0.3)
		local parsed = ok and Keys.Parse(key)
		T.check(ok == true and parsed ~= nil and parsed.HybridId ~= nil and parsed.Tier == "Normal", "fusion: Mix(two different pets) -> a hybrid key", tostring(key))
		local rec = parsed and prof.Hybrids[parsed.HybridId]
		local blended = Keys.BlendName(penguin.Name, phoenix.Name)
		T.check(type(rec) == "table" and rec.Body == "pip_penguin" and rec.Style == "ember_phoenix", "fusion: ...the record names Body (the first pet) and Style (the second)")
		T.check(type(rec) == "table" and type(rec.Elements) == "table" and #rec.Elements == 2 and rec.Elements[1] == penguin.Element and rec.Elements[2] == phoenix.Element,
			"fusion: ...Elements = both parents' elements", rec and table.concat(rec.Elements or {}, "+") or "")
		T.check(type(rec) == "table" and rec.Name == blended and rec.Rarity == "Legendary" and rec.Tier == "Normal" and type(rec.Seed) == "number",
			"fusion: ...a blended name (" .. tostring(blended) .. "), the higher rarity, the tier and a look seed", rec and (tostring(rec.Name) .. " " .. tostring(rec.Rarity) .. " " .. tostring(rec.Seed)) or "")
		T.check(count(p, "pip_penguin") == 0 and count(p, "ember_phoenix") == 0 and count(p, key) == 1, "fusion: ...both inputs are gone, the hybrid is owned once")
		local want = tokenCost("Mix", "Legendary", nil, 1)
		T.check(DataS.GetTokens(p) == tokens0 - want and DataS.GetGems(p) == gems0, "fusion: ...it cost TycoonCatalog.FusionCost(Mix, the higher rarity) in Cloud Tokens", tostring(tokens0 - DataS.GetTokens(p)) .. " vs " .. tostring(want))
		local def = Keys.DefOf(key, prof)
		local avgOk = def and def.IsHybrid and def.Stats and abs(def.Stats.Income - (penguin.Stats.Income + phoenix.Stats.Income) / 2 * 1.2) < 1e-6
		T.check(avgOk, "fusion: ...PetKeys.DefOf(result): a hybrid with stats = the parents' average x1.2")
		local hl = prof.PetLevels[key]
		T.check(type(hl) == "table" and hl.Level == floor((4 + 9) / 2), "fusion: ...the hybrid starts at its parents' average level", hl and tostring(hl.Level) or "none")
		T.check(toasted(p, tostring(blended), mark), "fusion: ...a side toast names the hybrid")
		local snap = lastSnapshot(p, mark)
		T.check(snap ~= nil and type(snap.Hybrids) == "table" and type(snap.Hybrids[parsed.HybridId]) == "table", "fusion: ...the ProfileSync carries the hybrid record")
		local res = results(p, mark)
		T.check(#res == 1 and res[1].Ok and res[1].Key == key and res[1].Action == "Mix", "fusion: ...the Result answer names the hybrid key")

		-- tiers: the LOWER tier of the two inputs
		give(p, "maple_fox@Golden", 1)
		give(p, "mallow_kitten", 1)
		ok, key = F.Mix(p, "maple_fox@Golden", "mallow_kitten")
		T.check(ok and Keys.TierOf(key) == "Normal" and count(p, "maple_fox@Golden") == 0, "fusion: Golden + Normal -> a Normal hybrid (no finish gained for free)", tostring(key))
		give(p, "maple_fox@Golden", 1)
		give(p, "mallow_kitten@Golden", 1)
		ok, key = F.Mix(p, "maple_fox@Golden", "mallow_kitten@Golden")
		T.check(ok and Keys.TierOf(key) == "Golden" and count(p, key) == 1, "fusion: Golden + Golden -> a Golden hybrid", tostring(key))

		-- Mythic / Secret inputs cost Gems
		give(p, "cloudy_dragon", 1)
		give(p, "pebble_pup", 1)
		local t1, g1 = DataS.GetTokens(p), DataS.GetGems(p)
		local _, gemsWant = tokenCost("Mix", "Mythic", nil, 1)
		ok, key = F.Mix(p, "pebble_pup", "cloudy_dragon")
		T.check(ok and type(gemsWant) == "number" and DataS.GetGems(p) == g1 - gemsWant and DataS.GetTokens(p) == t1, "fusion: a Mythic input makes the Mix cost Gems (tokens untouched)", tostring(g1 - DataS.GetGems(p)) .. " gems")

		-- refusals
		local function unchanged(label, fn)
			local snapCounts = {}
			for k, n in pairs(Keys.Owned(prof)) do
				snapCounts[k] = n
			end
			local t, g = DataS.GetTokens(p), DataS.GetGems(p)
			local okR, whyR = fn()
			local same = DataS.GetTokens(p) == t and DataS.GetGems(p) == g
			for k, n in pairs(Keys.Owned(prof)) do
				if snapCounts[k] ~= n then
					same = false
				end
			end
			for k in pairs(snapCounts) do
				if Keys.Count(prof, k) == 0 then
					same = false
				end
			end
			T.check(okR ~= true and same and type(whyR) == "string" and whyR ~= "", "fusion: Mix refused, nothing changed: " .. label, tostring(whyR))
		end
		give(p, "pebble_pup", 1)
		give(p, "pebble_pup@Golden", 1)
		unchanged("the same pet twice (Normal + Golden copy)", function()
			return F.Mix(p, "pebble_pup", "pebble_pup@Golden")
		end)
		unchanged("a hybrid as an input", function()
			return F.Mix(p, key, "pebble_pup")
		end)
		unchanged("a pet the player does not own", function()
			return F.Mix(p, "pebble_pup", "starlight_unicorn")
		end)
		unchanged("junk keys", function()
			return F.Mix(p, "pebble_pup", { "x" })
		end)
		give(p, "starlight_unicorn", 1)
		DataS.SpendGems(p, DataS.GetGems(p))
		unchanged("not enough Gems (Mythic input)", function()
			return F.Mix(p, "pebble_pup", "starlight_unicorn")
		end)
		-- a full hybrid collection
		DataS.AddGems(p, 500)
		local added = {}
		for i = 1, 100 do
			local id = "full" .. i
			if Keys.Add(prof, "hyb:" .. id, 1, { Body = "pebble_pup", Style = "maple_fox" }) then
				added[#added + 1] = id
			end
		end
		unchanged("a full hybrid collection (" .. countKeys(prof.Hybrids) .. " hybrids)", function()
			return F.Mix(p, "pebble_pup", "starlight_unicorn")
		end)
		for _, id in ipairs(added) do
			prof.Hybrids[id] = nil
		end
		ok, key = F.Mix(p, "pebble_pup", "starlight_unicorn")
		T.check(ok == true, "fusion: ...and it works again once there is room", tostring(key))
		leave(p)
	end)

	------------------------------------------------------------------------------------------------
	-- p2fusion_exploits
	------------------------------------------------------------------------------------------------
	S.p2fusion_exploits = guarded("p2fusion_exploits", function()
		if not K.needBoot() then
			return
		end
		local F, DataS, Keys, PCat = FS(), DS(), PK(), PC()
		local Pets = PS()
		if not F then
			T.fail("fusion: FusionService missing")
			return
		end
		local Config = config()

		-- equipped copies are taken off first; the result takes their slot
		local p = readyPlayer("Equipper", 1)
		local prof = DataS.GetProfile(p)
		give(p, "mallow_kitten", 4)
		give(p, "honey_bunny", 1)
		for _ = 1, 2 do
			Pets.Equip(p, "mallow_kitten")
		end
		Pets.Equip(p, "honey_bunny")
		T.check(#prof.Equipped == 3, "fusion: (precondition) 2 kittens + 1 bunny equipped", table.concat(prof.Equipped, ","))
		local ok, key = F.Upgrade(p, "mallow_kitten")
		advance(0.2)
		local kittens, golden, bunny = 0, 0, 0
		for _, k in ipairs(prof.Equipped) do
			if k == "mallow_kitten" then
				kittens = kittens + 1
			elseif k == "mallow_kitten@Golden" then
				golden = golden + 1
			elseif k == "honey_bunny" then
				bunny = bunny + 1
			end
		end
		T.check(ok and count(p, "mallow_kitten") == 1 and kittens == 1 and golden == 1 and bunny == 1,
			"fusion: equipped copies are unequipped before they are used, the result takes the freed slot (4 kittens, 2 equipped -> 1 kitten + 1 Golden equipped)", table.concat(prof.Equipped, ","))
		local attr = p:GetAttribute(Config.Attr.EquippedPets) or ""
		T.check(string.find(attr, "mallow_kitten@Golden", 1, true) ~= nil, "fusion: ...the EquippedPets attribute follows (PetService.Refresh)", attr)
		leave(p)

		-- the "only equipped pets" rule
		p = readyPlayer("OnlyEquipped", 1)
		prof = DataS.GetProfile(p)
		give(p, "biscuit_bear", 3)
		for _ = 1, 3 do
			Pets.Equip(p, "biscuit_bear")
		end
		local before = DataS.GetTokens(p)
		ok, key = F.Upgrade(p, "biscuit_bear")
		T.check(not ok and tostring(key):find("equipped", 1, true) ~= nil and count(p, "biscuit_bear") == 3 and #prof.Equipped == 3 and DataS.GetTokens(p) == before,
			"fusion: refused when the inputs are the player's only equipped pets (nothing changed)", tostring(key))
		for _ = 1, 3 do
			Pets.Unequip(p, "biscuit_bear")
		end
		ok, key = F.Upgrade(p, "biscuit_bear")
		T.check(ok and count(p, "biscuit_bear@Golden") == 1 and #prof.Equipped == 0, "fusion: ...after unequipping them it works", tostring(key))
		leave(p)

		-- Garden / Gym copies are freed first and the result takes over the slot
		p = readyPlayer("Gardener", 1)
		prof = DataS.GetProfile(p)
		local econ, combat = nil, nil
		for _, d in ipairs(PCat.Pets) do
			if d.Rarity ~= "Secret" then
				if d.Role == "Economy" and not econ then
					econ = d.Id
				elseif d.Role == "Combat" and not combat then
					combat = d.Id
				end
			end
		end
		give(p, econ, 3)
		give(p, combat, 3)
		DataS.MutateHome(p, function(h)
			h.Garden[1] = econ
			h.Gym[2] = combat
		end)
		ok = F.Upgrade(p, econ)
		local ok2 = F.Upgrade(p, combat)
		advance(0.2)
		local home = DataS.GetHome(p)
		T.check(ok and home.Garden[1] == econ .. "@Golden", "fusion: a Garden copy leaves its slot first; the Golden Economy pet takes the slot", tostring(home.Garden[1]))
		T.check(ok2 and home.Gym[2] == combat .. "@Golden", "fusion: a Gym copy leaves its slot first; the Golden Combat pet takes the slot", tostring(home.Gym[2]))

		-- atomic: a full result stack refuses before anything changes
		give(p, econ, 3)
		local cap = Config.Pets.MaxPerStack or 99
		local have = count(p, econ .. "@Golden")
		give(p, econ .. "@Golden", cap - have)
		local t0 = DataS.GetTokens(p)
		ok, key = F.Upgrade(p, econ)
		T.check(not ok and count(p, econ) == 3 and count(p, econ .. "@Golden") == cap and DataS.GetTokens(p) == t0, "fusion: a full stack of the result refuses before anything is used (atomic)", tostring(key))
		leave(p)

		-- the remote: junk arguments, no home claimed, too far, near, spam
		local errs0 = #Mock.Errors
		p = readyPlayer("Remote", 1)
		prof = DataS.GetProfile(p)
		give(p, "pip_penguin", 9)
		local t1 = DataS.GetTokens(p)
		local junk = {
			{}, { 42 }, { "Upgrade" }, { "Upgrade", 5 }, { "Upgrade", {} }, { "Upgrade", string.rep("x", 300) }, { "Mix", "pip_penguin" },
			{ "Mix", "pip_penguin", 0 / 0 }, { "Nope", "pip_penguin" }, { string.rep("U", 100), "pip_penguin" }, { "Upgrade", "pip_penguin", "extra" },
		}
		for _, args in ipairs(junk) do
			fuseRemote(p, unpack(args))
			advance(0.8)
		end
		T.check(count(p, "pip_penguin") == 9 and count(p, "pip_penguin@Golden") == 0 and DataS.GetTokens(p) == t1 and #Mock.Errors == errs0,
			"fusion remote: junk arguments (wrong types, NaN, huge strings, unknown actions) change nothing and raise nothing (and without a claimed home nothing fuses)")
		local mark = K.logSize()
		fuseRemote(p, "Upgrade", "pip_penguin")
		advance(0.3)
		local res = results(p, mark)
		T.check(#res >= 1 and res[#res].Ok == false and tostring(res[#res].Reason):find("home", 1, true) ~= nil and count(p, "pip_penguin") == 9,
			"fusion remote: without a claimed home the remote refuses (the window opens at the machine)", res[#res] and tostring(res[#res].Reason) or "no answer")

		-- claim a plot, build the machine, stand far / near
		local Ty = mod("TycoonService") or requireAt("server/Services/TycoonService")
		local SS = mod("SpotService")
		local spots = (K.W.lobbyInfo and K.W.lobbyInfo.Spots) or {}
		local index = nil
		for i = 1, config().Lobby.SpotCount do
			if spots[i] and SS and not SS.GetOwner(i) then
				index = i
				break
			end
		end
		local claimed = index and Ty and Ty.Claim(p, index)
		advance(0.6)
		if T.check(claimed and true or false, "fusion remote: (precondition) the player claims a home", tostring(index)) then
			setHome(p, 1, { FusionMachine = 1, Kitchen = 1, Press1 = 1, Collector = 1 })
			advance(2.2)
			local machine = spots[index].Folder:FindFirstChild("Station_FusionMachine", true)
			if T.check(machine ~= nil and machine:FindFirstChild("FusionPrompt", true) ~= nil, "fusion remote: (precondition) the plot shows the Fusion Machine with its FusionPrompt") then
				local at = machine:GetPivot().Position
				Mock.Teleport(p, at + Vector3.new(0, 3, -90))
				advance(0.1)
				mark = K.logSize()
				fuseRemote(p, "Upgrade", "pip_penguin")
				advance(0.3)
				res = results(p, mark)
				T.check(#res >= 1 and res[#res].Ok == false and tostring(res[#res].Reason):find("Walk", 1, true) ~= nil and count(p, "pip_penguin") == 9,
					"fusion remote: refused from far away (\"Walk up to your Fusion Machine\")", res[#res] and tostring(res[#res].Reason) or "no answer")
				Mock.Teleport(p, at + Vector3.new(0, 3, -7))
				advance(1)
				mark = K.logSize()
				local t2 = DataS.GetTokens(p)
				for _ = 1, 10 do
					fuseRemote(p, "Upgrade", "pip_penguin")
				end
				advance(0.3)
				res = results(p, mark)
				local okCount = 0
				for _, r in ipairs(res) do
					if r.Ok then
						okCount = okCount + 1
					end
				end
				local want = tokenCost("Upgrade", "Common", "Golden", 1)
				T.check(okCount == 1 and count(p, "pip_penguin") == 6 and count(p, "pip_penguin@Golden") == 1 and DataS.GetTokens(p) == t2 - want,
					"fusion remote: next to the machine it fuses, and 10 requests in one frame make exactly one fusion (cooldown)", okCount .. " fusions, " .. count(p, "pip_penguin") .. " left")
				advance(1)
				fuseRemote(p, "Upgrade", "pip_penguin")
				advance(0.3)
				T.check(count(p, "pip_penguin@Golden") == 2, "fusion remote: ...after the cooldown the next request works")
				-- a burst of junk drains the budget but never errors
				for _ = 1, 30 do
					fuseRemote(p, "Mix", "x", "y")
				end
				advance(0.2)
				T.check(#Mock.Errors == errs0, "fusion remote: a burst of 30 requests raises nothing")
			end
			Ty.Release(p)
		end
		leave(p)
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
	local LocalPlayer = Players.LocalPlayer
	local advance = KC.advance

	local function moduleAt(top, rest)
		local inst = Mock.GetPath(ROOTS[top] .. "/" .. rest)
		if not inst then
			return nil
		end
		local ok, result = pcall(require, inst)
		return ok and type(result) == "table" and result or nil
	end

	local function fusionGui()
		local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		return pg and pg:FindFirstChild("NimbusFusion")
	end

	local function windowShown()
		local g = fusionGui()
		local w = g and g:FindFirstChild("Window_Fusion")
		return w ~= nil and w.Visible == true
	end

	local function find(root, name)
		for _, d in ipairs(root and root:GetDescendants() or {}) do
			if d.Name == name then
				return d
			end
		end
		return nil
	end

	local function snapshot(over)
		local s = {
			Tokens = 50000,
			Pets = { pebble_pup = 4, pip_penguin = 1, ember_phoenix = 1, mallow_kitten = 2, honey_bunny = 1 },
			Equipped = { "honey_bunny" },
			Items = {},
			Stats = { Matches = 0, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = {} },
			Perks = { MaxHealth = 0, TokenBonus = 0, StaminaRegen = 0, CheckpointHeal = 0 },
			Discovered = {},
			IndexClaimed = {},
			Tutorial = { Step = 9, Done = true, Gifted = true },
			Cash = 100, Gems = 50,
			Home = { Level = 10, Prestige = 1, Stations = { FusionMachine = 1, Kitchen = 1 }, Garden = {}, Gym = {}, CollectorCash = 0 },
			Food = {},
			Tiers = { maple_fox = { Golden = 3 } },
			Hybrids = { hc1 = { Body = "pip_penguin", Style = "ember_phoenix", Elements = { "Frost", "Flame" }, Name = "Pengnix", Rarity = "Legendary", Tier = "Normal", Seed = 3 } },
			PetLevels = {},
		}
		for k, v in pairs(over or {}) do
			s[k] = v
		end
		return s
	end

	S.client_p2fusion = guarded("client_p2fusion", function()
		local FC = (KC.M and KC.M.FusionController) or moduleAt("client", "Controllers/FusionController")
		if not T.check(type(FC) == "table" and type(FC.Init) == "function" and type(FC.Open) == "function" and type(FC.Close) == "function",
			"fusion window: client/Controllers/FusionController.lua loads with Init / Open / Close") then
			return
		end
		local errors0 = #Mock.Errors
		FC.Init()
		T.check(fusionGui() ~= nil and not windowShown(), "fusion window: Init makes the NimbusFusion ScreenGui, closed")
		local Keys = moduleAt("shared", "PetKeys")
		local TCat = moduleAt("shared", "TycoonCatalog")
		local Config = moduleAt("shared", "Config")
		LocalPlayer:SetAttribute(Config.Attr.InMatch, false)
		LocalPlayer:SetAttribute(Config.Attr.Tokens, 50000)
		LocalPlayer:SetAttribute(Config.Attr.Gems, 50)
		KC.toClient("ProfileSync", snapshot())
		advance(0.3)

		-- OpenPanel("Fusion") opens it on a tab with a pet picked
		KC.toClient("OpenPanel", "Fusion", { Tab = "Upgrade", Key = "pebble_pup" })
		advance(0.6)
		T.check(windowShown() and FC.IsOpen(), "fusion window: OpenPanel(\"Fusion\", {Tab, Key}) opens the window")
		local plan = FC.Plan()
		local want = TCat.FusionCost("Upgrade", "Common", "Golden", 1).Tokens
		T.check(type(plan) == "table" and plan.Ok == true and plan.ResultKey == "pebble_pup@Golden" and plan.Cost and plan.Cost.Currency == "Tokens" and plan.Cost.Amount == want,
			"fusion window: the Upgrade preview mirrors the server (result key, Token cost)", plan and (tostring(plan.ResultKey) .. " " .. tostring(plan.Cost and plan.Cost.Amount) .. " " .. tostring(plan.Reason)) or "no plan")
		-- the tiles: no hybrids, no Rainbow, the copies counted
		local g = fusionGui()
		local tiles = {}
		for _, d in ipairs(g:GetDescendants()) do
			if d.Name == "Tile" and d:IsA("TextButton") then
				local name = d:FindFirstChild("PetName")
				tiles[#tiles + 1] = name and name.Text or "?"
			end
		end
		local joined = table.concat(tiles, "|")
		T.check(#tiles >= 4 and not joined:find("Pengnix", 1, true), "fusion window: the picker lists the regular pets (no hybrids)", joined)

		-- FUSE sends the remote
		local mark = #Mock.RemoteLog
		local fuse = find(g, "Fuse")
		T.check(fuse ~= nil and fuse:IsA("TextButton") and fuse:GetAttribute("Disabled") ~= true, "fusion window: FUSE is enabled for a valid fusion")
		if fuse then
			Mock.Click(fuse)
		end
		advance(0.1)
		local calls = KC.serverCalls("Fusion", mark)
		T.check(#calls == 1 and calls[1].args[1] == "Upgrade" and calls[1].args[2] == "pebble_pup", "fusion window: FUSE sends Fusion(\"Upgrade\", key)", #calls .. " calls")
		Mock.Click(fuse)
		advance(0.1)
		T.eq(#KC.serverCalls("Fusion", mark), 1, "fusion window: ...a second click while waiting sends nothing")

		-- the server's answer: the animation, then back to picking
		local s2 = snapshot({ Pets = { pebble_pup = 1, pip_penguin = 1, ember_phoenix = 1, mallow_kitten = 2, honey_bunny = 1 }, Tiers = { maple_fox = { Golden = 3 }, pebble_pup = { Golden = 1 } } })
		KC.toClient("ProfileSync", s2)
		KC.toClient("Fusion", "Result", { Ok = true, Action = "Upgrade", Key = "pebble_pup@Golden", Name = "Golden Pebble Pup", Rarity = "Common", Tier = "Golden" })
		advance(0.7)
		local newTag = find(g, "New")
		T.check(newTag ~= nil and newTag.Visible == true, "fusion window: the fusion animation shows the new pet with a NEW! tag")
		advance(2)
		T.check(windowShown() and newTag.Visible == false and fuse.Text:find("FUSE", 1, true) ~= nil, "fusion window: ...then it is back to picking (window still open)", fuse.Text)
		plan = FC.Plan()
		T.check(plan and plan.Inputs and plan.Inputs[1] and plan.Inputs[1].Key == "pebble_pup@Golden", "fusion window: ...the new Golden copy is picked next (it can still go to Rainbow)")

		-- a refusal shows its reason
		FC.Select("maple_fox@Golden")
		advance(0.1)
		mark = #Mock.RemoteLog
		Mock.Click(fuse)
		advance(0.1)
		T.eq(#KC.serverCalls("Fusion", mark), 1, "fusion window: FUSE for the Golden fox sends a request")
		KC.toClient("Fusion", "Result", { Ok = false, Action = "Upgrade", Reason = "Not enough Cloud Tokens" })
		advance(0.2)
		local note = find(g, "ServerNote")
		T.check(note ~= nil and note.Visible and note.Text == "Not enough Cloud Tokens", "fusion window: a refused fusion shows the server's reason", note and note.Text or "")

		-- Mix tab: the blended name, the higher rarity, both elements, the cost
		FC.Open("Mix", { Key = "pip_penguin", KeyB = "ember_phoenix" })
		advance(0.3)
		plan = FC.Plan()
		local wantMix = TCat.FusionCost("Mix", "Legendary", nil, 1).Tokens
		T.check(plan and plan.Ok and plan.ResultName == Keys.BlendName("Pip Penguin", "Ember Phoenix") and plan.Rarity == "Legendary" and plan.Cost.Amount == wantMix
			and type(plan.Elements) == "table" and #plan.Elements == 2,
			"fusion window: the Mix preview shows the blended name, the higher rarity, both elements and the cost", plan and (tostring(plan.ResultName) .. " " .. tostring(plan.Rarity) .. " " .. tostring(plan.Reason)) or "")
		T.check(plan and type(plan.ResultDef) == "table" and plan.ResultDef.IsHybrid == true, "fusion window: ...with a hybrid preview pet (PetKeys.DefOf of a stand-in record)")
		mark = #Mock.RemoteLog
		FC.Fuse()
		advance(0.1)
		local mc = KC.serverCalls("Fusion", mark)
		T.check(#mc == 1 and mc[1].args[1] == "Mix" and mc[1].args[2] == "pip_penguin" and mc[1].args[3] == "ember_phoenix", "fusion window: FUSE sends Fusion(\"Mix\", body, style)")
		KC.toClient("Fusion", "Result", { Ok = false, Action = "Mix", Reason = "x", Quiet = true })
		advance(0.1)
		-- the same pet twice is refused locally
		FC.Select("pebble_pup", "pebble_pup@Golden")
		advance(0.1)
		plan = FC.Plan()
		T.check(plan and not plan.Ok and tostring(plan.Reason):find("different", 1, true) ~= nil, "fusion window: two copies of the same pet cannot be mixed", plan and tostring(plan.Reason) or "")
		-- the only-equipped rule
		KC.toClient("ProfileSync", snapshot({ Pets = { pebble_pup = 3, honey_bunny = 1 }, Equipped = { "pebble_pup", "pebble_pup", "pebble_pup" } }))
		FC.Open("Upgrade", { Key = "pebble_pup" })
		advance(0.2)
		plan = FC.Plan()
		T.check(plan and not plan.Ok and tostring(plan.Reason):find("equipped", 1, true) ~= nil, "fusion window: fusing the only equipped pets is refused with the reason (like the server)", plan and tostring(plan.Reason) or "")

		-- readability: every text is >= 18 design px, every visible text has a stroke or a solid backing
		local small = {}
		for _, d in ipairs(g:GetDescendants()) do
			if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and not d.TextScaled then
				if d.TextSize < 18 then
					small[#small + 1] = d.Name .. "=" .. d.TextSize
				end
			end
		end
		T.check(#small == 0, "fusion window: every text is at least 18 design px (readability rule, under one UIScale)", table.concat(small, ", "))

		-- one window at a time: the menu closes it
		KC.toClient("OpenPanel", "Inventory")
		advance(0.5)
		T.check(not FC.IsOpen(), "fusion window: opening a menu window closes it")
		-- E at the player's own FusionPrompt opens it, someone else's does not
		local model = Instance.new("Model")
		model.Name = "Station_FusionMachine"
		local part = Instance.new("Part")
		part.Anchored = true
		-- next to the player: the window closes when the player walks away from the machine it opened at
		local root = KC.root and KC.root()
		part.Position = (root and root.Position or Vector3.new(0, 0, 0)) + Vector3.new(0, 0, -5)
		part.Parent = model
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "FusionPrompt"
		prompt:SetAttribute("OwnerUserId", LocalPlayer.UserId + 1)
		prompt.Parent = part
		model.Parent = workspace
		pcall(function()
			local menu = moduleAt("client", "Controllers/MenuController")
			if menu and menu.Close then
				menu.Close()
			end
		end)
		advance(0.3)
		Mock.Trigger(prompt, LocalPlayer)
		advance(0.3)
		T.check(not FC.IsOpen(), "fusion window: someone else's FusionPrompt does not open it")
		prompt:SetAttribute("OwnerUserId", LocalPlayer.UserId)
		Mock.Trigger(prompt, LocalPlayer)
		advance(0.3)
		T.check(FC.IsOpen() and windowShown(), "fusion window: E at the player's own FusionPrompt opens it")
		if root then
			part.Position = root.Position + Vector3.new(0, 0, -80)
			advance(0.4)
			T.check(not FC.IsOpen(), "fusion window: walking away from the machine closes it")
			part.Position = root.Position + Vector3.new(0, 0, -5)
			Mock.Trigger(prompt, LocalPlayer)
			advance(0.3)
		end
		-- a match closes it
		LocalPlayer:SetAttribute(Config.Attr.InMatch, true)
		advance(0.3)
		T.check(not FC.IsOpen(), "fusion window: entering a match closes it")
		LocalPlayer:SetAttribute(Config.Attr.InMatch, false)
		FC.Open("Upgrade")
		advance(0.2)
		FC.Close()
		advance(0.3)
		T.check(not FC.IsOpen() and not windowShown(), "fusion window: Close() hides it")
		model:Destroy()
		-- no errors from the controller
		local mine = 0
		for i = errors0 + 1, #Mock.Errors do
			local msg = tostring(Mock.Errors[i].msg)
			if msg:find("Fusion", 1, true) then
				mine = mine + 1
			end
		end
		T.eq(mine, 0, "fusion window: no script errors from FusionController")
		if KC.flushErrors then
			KC.flushErrors("client_p2fusion")
		end
	end)

	return S
end

if CONTEXT == "server" then
	return serverScenarios()
end
return clientScenarios()
