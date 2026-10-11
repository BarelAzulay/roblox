-- dump_gui.lua: boots the client world (Main.client.lua) inside the Roblox mock at a given screen size, drives
-- it into a scenario with the same fake server events the smoke tests use (tools/smoke_client*.lua), then walks
-- PlayerGui and dumps every VISIBLE GuiObject as JSON, so tools/render_gui.py can draw the 2D UI offline.
--
-- It runs under lupa with tools/robloxmock.lua, booted like tools/smoke.py boots a client world (render_gui.py
-- does that: Mock.Configure + Mock.Boot("client") + src/ mounted where default.project.json says). Globals:
--   Mock          the booted mock
--   ROOTS         src directory name -> instance path ("client" -> "StarterPlayer/StarterPlayerScripts/Client", ...)
--   DUMP          { scenario = "lobby", width = 1920, height = 1080, touch = false, out = "file.json" | nil }, or for
--                 tools/smoke_polish_guitool.lua { walk = true (walk the PlayerGui as it is now: no boot, no scenario),
--                 gallery = true (add the widget gallery first), probe = true (also test the text-measure hook and put
--                 the mock's own measure back), keep = true (leave the gallery in PlayerGui) }
--   GUI_MEASURE   optional function(fontName, text) -> advance width in em (render_gui.py passes its real font
--                 metrics; the mock's own text measure, a flat 0.5 em per character, is then replaced so
--                 AutomaticSize / TextBounds see the same text widths the renderer draws)
-- The chunk returns the JSON text, a one-line summary and the dump as a Lua table (and writes DUMP.out when given).
--
-- Scenarios (after the boot the title card is left to fade, a profile is synced and the player owns tokens):
--   gallery               no game UI: one cell per feature the renderer draws, with known values (renderer check)
--   lobby                 the idle lobby HUD
--   title                 right after joining (the title card is still up)
--   match[:hit]           in a match: match panel, team chips, a damaged HP bar, a partly drained stamina bar
--                         (":hit" = a quarter second after a hit, damage feedback included)
--   countdown             the pre-match countdown inside the match panel
--   party                 the portal party panel with its countdown
--   results               the victory results card
--   menu:<Window>[:<Tab>] Inventory / Pets / Index / Shop / Stats through the OpenPanel remote (Tab = window tab, or
--                         the Index group, e.g. menu:Index:Mythic, menu:Shop:Items)
--   tutorial[:<step>]     the tutorial side panel at step n (default 1)
--   npc[:<n>]             the NPC dialog of NPC n (default 1); the NPCs are built by the real NpcService
--   dev                   the owner-only DEV panel (NC_Dev attribute), when DevController exists
--   toasts                four side toasts (info / good / bad / token)
--   portal[:<Id>[:<n>[:<studs>]]]  no game HUD: the real LobbyBuilder + PortalService with n players (default 1) on
--                         the portal pad (default Medium); its world GUIs mirrored flat into the ScreenGui
--                         WorldMirror: the pixel billboard at its own size, the eye-level countdown face at the
--                         size it has on this screen from <studs> away (default 36, a friend outside the lock
--                         walls) over a sketch of the swirl, and the face's canvas at 1:1
--   homepads[:<tier>]     no game HUD: a Phase 2 home (real LobbyBuilder + HomeBuilder + TycoonCatalog) built half way
--                         to house tier <tier> (default 2) with its buy pads; every pad sign (pixel billboards at
--                         their own size), the "FREE HOME" signpost of a free plot and the Collector's cash screen
--                         (from 30 studs and at canvas size) mirrored flat into the ScreenGui WorldMirror
--
-- Every dumped node: absolute screen position/size (top bar inset included), cumulative UIScale, ZIndex, Rotation,
-- clipping, background colour/transparency, legacy border, UICorner radius in px, UIStrokes (colour, thickness in
-- px, transparency, ApplyStrokeMode, position, UIGradient), UIGradient, UIPadding, the text properties (font name,
-- size in screen px, TextScaled + UITextSizeConstraint, wrapping, alignment, colours, stroke, truncation, typewriter)
-- and image / viewport placeholders. Rotation, TextScaled and ScrollingFrame clipping are left to the renderer.
-- Plain Lua 5.1 syntax only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local ARGS = DUMP or {}
local MEASURE = GUI_MEASURE
local fmt = string.format
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil

local notes = {}

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------
local function fail(msg)
	error("dump_gui: " .. tostring(msg), 0)
end

local function note(msg)
	notes[#notes + 1] = tostring(msg)
end

-- plain-text split ("a:b::c" -> { "a", "b", "", "c" })
local function split(text, sep)
	local out = {}
	local pos = 1
	while true do
		local a, b = text:find(sep, pos, true)
		if not a then
			out[#out + 1] = text:sub(pos)
			return out
		end
		out[#out + 1] = text:sub(pos, a - 1)
		pos = b + 1
	end
end

local function moduleInstance(key)
	local top, rest = key:match("^(%w+)/(.+)$")
	local rootPath = top and ROOTS[top]
	if not rootPath then
		return nil
	end
	local inst = Mock.GetPath(rootPath)
	for part in rest:gmatch("[^/]+") do
		inst = inst and inst:FindFirstChild(part)
	end
	return inst
end

local loaded = {}
-- require a src module ("shared/Config", "client/Controllers/NpcController"); nil when optional and missing
local function req(key, optional)
	if loaded[key] then
		return loaded[key]
	end
	local inst = moduleInstance(key)
	if not inst then
		if optional then
			return nil
		end
		fail("src/" .. key .. ".lua does not exist")
	end
	local ok, result = pcall(require, inst)
	if not ok or type(result) ~= "table" then
		if optional then
			note("require " .. key .. " failed: " .. tostring(result))
			return nil
		end
		fail("require " .. key .. " failed: " .. tostring(result))
	end
	loaded[key] = result
	return result
end

-- runs fn in protected mode; a failure becomes a note in the dump instead of aborting it
local function try(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		note(label .. ": " .. tostring(type(err) == "table" and (err.msg or err) or err))
	end
	return ok
end

local function advance(seconds)
	Mock.Advance(seconds)
end

----------------------------------------------------------------------
-- JSON
----------------------------------------------------------------------
local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function jsonNumber(v)
	if v ~= v or v == math.huge or v == -math.huge then
		return "0"
	end
	if v == floor(v) and v > -1e15 and v < 1e15 then
		return fmt("%d", v)
	end
	local s = fmt("%.3f", v):gsub("0+$", ""):gsub("%.$", "")
	if s == "-0" then
		return "0"
	end
	return s
end

local function jsonString(v)
	local s = tostring(v):gsub('[%c"\\]', function(c)
		return ESC[c] or fmt("\\u%04x", c:byte())
	end)
	return '"' .. s .. '"'
end

local encode
-- arrays: tables whose keys are exactly 1..n (an empty table is an array)
local function isArray(t)
	local n = #t
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k > n or k ~= floor(k) then
			return false
		end
	end
	return true
end

encode = function(v, out)
	local t = type(v)
	if t == "nil" then
		out[#out + 1] = "null"
	elseif t == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif t == "number" then
		out[#out + 1] = jsonNumber(v)
	elseif t == "string" then
		out[#out + 1] = jsonString(v)
	elseif t == "table" then
		if isArray(v) then
			out[#out + 1] = "["
			for i = 1, #v do
				if i > 1 then
					out[#out + 1] = ","
				end
				encode(v[i], out)
			end
			out[#out + 1] = "]"
		else
			local keys = {}
			for k in pairs(v) do
				keys[#keys + 1] = tostring(k)
			end
			table.sort(keys)
			out[#out + 1] = "{"
			for i, k in ipairs(keys) do
				if i > 1 then
					out[#out + 1] = ","
				end
				out[#out + 1] = jsonString(k)
				out[#out + 1] = ":"
				encode(v[k], out)
			end
			out[#out + 1] = "}"
		end
	else
		out[#out + 1] = jsonString(tostring(v))
	end
end

local function toJson(v)
	local out = {}
	encode(v, out)
	return table.concat(out)
end

----------------------------------------------------------------------
-- text: rich text, font names, real text metrics for the mock's layout engine
----------------------------------------------------------------------
local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function plainRich(text)
	text = text:gsub("<[bB][rR]%s*/?>", "\n")
	text = text:gsub("<[^>]*>", "")
	text = text:gsub("&(%a+);", function(name)
		return ENTITIES[name]
	end)
	return text
end

local function utf8len(text)
	local _, n = text:gsub("[^\128-\191]", "")
	return n
end

local function fontNameOf(inst)
	local name = "SourceSans"
	local ok, f = pcall(function()
		return inst.Font
	end)
	if ok and f ~= nil then
		name = tostring(f.Name or f)
	end
	if name == "SourceSans" then
		-- a FontFace set directly (Font.new / Font.fromName) keeps the family file name
		local okFace, face = pcall(function()
			return inst.FontFace
		end)
		if okFace and face ~= nil then
			local family = tostring(face.Family or "")
			local fam = family:match("families/([%w_]+)%.json")
			if fam and fam ~= "SourceSansPro" then
				name = fam
				local okW, weight = pcall(function()
					return face.Weight
				end)
				local wname = okW and weight ~= nil and tostring(weight.Name or weight) or ""
				if wname == "Bold" or wname == "ExtraBold" or wname == "Heavy" or wname == "SemiBold" then
					name = name .. wname
				end
			end
		end
	end
	return name
end

local widthCache = {}
local function emWidth(font, s)
	local byFont = widthCache[font]
	if not byFont then
		byFont = {}
		widthCache[font] = byFont
	end
	local w = byFont[s]
	if w == nil then
		local ok, r = pcall(MEASURE, font, s)
		w = ok and tonumber(r) or nil
		if not w then
			w = utf8len(s) * 0.5
		end
		byFont[s] = w
	end
	return w
end

-- width, height of a text object's text with real font metrics (limit = wrap width or nil). Same contract and
-- wrapping rules as the mock's own textExtent: lines are TextSize * LineHeight tall, words wrap on spaces and a
-- word longer than the limit breaks over several rows.
local function realExtent(inst, limit)
	local text = tostring(inst.Text or "")
	if inst.RichText then
		text = plainRich(text)
	end
	local size = tonumber(inst.TextSize) or 14
	local lineH = size * (tonumber(inst.LineHeight) or 1)
	local font = fontNameOf(inst)
	local function width(s)
		return emWidth(font, s) * size
	end
	local spaceW = width(" ")
	local maxW, lines = 0, 0
	for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
		local full = width(raw)
		if limit and limit > 0 and full > limit + 0.01 then
			local cur, rows = 0, 1
			for word in raw:gmatch("%S+") do
				local wl = width(word)
				if cur > 0 and cur + spaceW + wl > limit then
					rows = rows + 1
					maxW = max(maxW, cur)
					cur = 0
				end
				if wl > limit then
					local extra = ceil(wl / limit) - 1
					rows = rows + extra
					maxW = max(maxW, limit)
					cur = wl - extra * limit
				else
					cur = (cur > 0) and (cur + spaceW + wl) or wl
				end
			end
			maxW = max(maxW, cur)
			lines = lines + rows
		else
			maxW = max(maxW, full)
			lines = lines + 1
		end
	end
	return maxW, lines * lineH
end

-- the n-th upvalue called `name` of a Lua function: value, index
local function upvalueOf(fn, name)
	if type(fn) ~= "function" or type(debug) ~= "table" or not debug.getupvalue then
		return nil
	end
	local i = 1
	while true do
		local n, v = debug.getupvalue(fn, i)
		if n == nil then
			return nil
		end
		if n == name then
			return v, i
		end
		i = i + 1
	end
end

-- Swaps the mock's flat 0.5 em text measure for real font metrics: Mock.GuiBox -> computeBox -> placeIn ->
-- resolveSize -> measureContent -> textExtent (one shared upvalue), plus Mock.TextExtent (TextBounds).
-- measure (optional) replaces GUI_MEASURE. Returns true + a function that puts the mock's own measure back,
-- or false + the reason.
-- LuaJIT treats a local function that is never reassigned as an immutable upvalue: a trace compiled while the layout
-- code was hot keeps calling the OLD textExtent after debug.setupvalue. Flushing the trace cache after every swap
-- makes the swap reach compiled code too (no-op without the jit library).
local function flushTraces()
	local j = rawget(_G, "jit")
	if type(j) == "table" and type(j.flush) == "function" then
		pcall(j.flush)
	end
end

local function installMetrics(measure)
	if measure then
		MEASURE = measure
		widthCache = {}
	end
	local t = type(MEASURE)
	if t ~= "function" and t ~= "userdata" then
		return false, "no GUI_MEASURE"
	end
	local computeBox = upvalueOf(Mock.GuiBox, "computeBox")
	local placeIn = upvalueOf(computeBox, "placeIn")
	local resolveSize = upvalueOf(placeIn, "resolveSize")
	local measureContent = upvalueOf(resolveSize, "measureContent")
	local original, index = upvalueOf(measureContent, "textExtent")
	if not index then
		return false, "the mock's text measure (textExtent) was not found; AutomaticSize uses its flat 0.5 em widths"
	end
	local originalPublic = Mock.TextExtent
	debug.setupvalue(measureContent, index, realExtent)
	Mock.TextExtent = realExtent
	Mock.GuiEpoch = (Mock.GuiEpoch or 0) + 1
	flushTraces()
	return true, function()
		debug.setupvalue(measureContent, index, original)
		Mock.TextExtent = originalPublic
		Mock.GuiEpoch = (Mock.GuiEpoch or 0) + 1
		flushTraces()
	end
end

----------------------------------------------------------------------
-- the PlayerGui walk
----------------------------------------------------------------------
local function rgb(c)
	if typeof(c) ~= "Color3" then
		return { 0, 0, 0 }
	end
	return { floor(c.R * 255 + 0.5), floor(c.G * 255 + 0.5), floor(c.B * 255 + 0.5) }
end

local function enumName(v)
	if v == nil then
		return ""
	end
	return tostring(v.Name or v)
end

local function get(inst, key)
	local ok, v = pcall(function()
		return inst[key]
	end)
	if ok then
		return v
	end
	return nil
end

local function isText(inst)
	return inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")
end

local function gradientOf(g)
	local out = { rot = tonumber(get(g, "Rotation")) or 0, colors = {}, transparency = {}, offset = { 0, 0 } }
	local cs = get(g, "Color")
	if cs and cs.Keypoints then
		for _, kp in ipairs(cs.Keypoints) do
			local c = rgb(kp.Value)
			out.colors[#out.colors + 1] = { kp.Time, c[1], c[2], c[3] }
		end
	end
	local ns = get(g, "Transparency")
	if ns and ns.Keypoints then
		for _, kp in ipairs(ns.Keypoints) do
			out.transparency[#out.transparency + 1] = { kp.Time, kp.Value }
		end
	end
	local off = get(g, "Offset")
	if typeof(off) == "Vector2" then
		out.offset = { off.X, off.Y }
	end
	return out
end

-- UICorner / UIStroke / UIGradient / UIPadding / UITextSizeConstraint children of a GuiObject
local function componentsOf(inst)
	local comp = { strokes = {} }
	for _, c in ipairs(inst:GetChildren()) do
		if c:IsA("UICorner") then
			comp.corner = comp.corner or c
		elseif c:IsA("UIStroke") then
			if get(c, "Enabled") ~= false then
				comp.strokes[#comp.strokes + 1] = c
			end
		elseif c:IsA("UIGradient") then
			if get(c, "Enabled") ~= false and not comp.gradient then
				comp.gradient = c
			end
		elseif c:IsA("UIPadding") then
			comp.padding = comp.padding or c
		elseif c:IsA("UITextSizeConstraint") then
			comp.textSize = comp.textSize or c
		end
	end
	return comp
end

local function modelLabel(viewport)
	local model = viewport:FindFirstChildWhichIsA("Model", true)
	if not model then
		local part = viewport:FindFirstChildWhichIsA("BasePart", true)
		return part and part.Name or ""
	end
	local id = model:GetAttribute("PetId")
	if type(id) == "string" and id ~= "" then
		return id
	end
	return model.Name
end

local function nodeOf(inst, ctx, path, order)
	if not inst:IsA("GuiObject") then
		return nil
	end
	if inst.Visible == false then
		ctx.hidden = ctx.hidden + 1
		return nil
	end
	local b = Mock.GuiBox(inst)
	local s = b.scale or 1
	local x, y, w, h = b.x, b.y + ctx.inset, b.w, b.h
	ctx.count = ctx.count + 1
	local comp = componentsOf(inst)
	local n = {
		id = ctx.count,
		order = order,
		class = inst.ClassName,
		name = inst.Name,
		path = path,
		x = x,
		y = y,
		w = w,
		h = h,
		s = s,
		z = tonumber(inst.ZIndex) or 1,
		rot = tonumber(inst.Rotation) or 0,
		clip = (inst.ClipsDescendants == true) or inst:IsA("ScrollingFrame"),
		bg = rgb(inst.BackgroundColor3),
		bgT = tonumber(inst.BackgroundTransparency) or 0,
		children = {},
	}
	local borderSize = tonumber(inst.BorderSizePixel) or 0
	if borderSize > 0 then
		n.border = { size = borderSize * s, color = rgb(inst.BorderColor3), mode = enumName(inst.BorderMode) }
	end
	if comp.corner then
		local r = comp.corner.CornerRadius
		local short = min(w, h)
		n.corner = max(0, min(r.Scale * short + r.Offset * s, short / 2))
	end
	if #comp.strokes > 0 then
		n.strokes = {}
		for _, st in ipairs(comp.strokes) do
			local entry = {
				color = rgb(st.Color),
				thickness = (tonumber(st.Thickness) or 1) * s,
				t = tonumber(st.Transparency) or 0,
				mode = enumName(st.ApplyStrokeMode),
				join = enumName(get(st, "LineJoinMode")),
				-- BorderStrokePosition is not read (the mock does not know it and the game never sets it): Roblox's
				-- default, Outer, is what the renderer draws
				position = "Outer",
			}
			local g = st:FindFirstChildWhichIsA("UIGradient")
			if g and get(g, "Enabled") ~= false then
				entry.gradient = gradientOf(g)
			end
			n.strokes[#n.strokes + 1] = entry
		end
	end
	if comp.gradient then
		n.gradient = gradientOf(comp.gradient)
	end
	local pl, pr, pt, pb = 0, 0, 0, 0
	if comp.padding then
		local p = comp.padding
		pl = p.PaddingLeft.Scale * w + p.PaddingLeft.Offset * s
		pr = p.PaddingRight.Scale * w + p.PaddingRight.Offset * s
		pt = p.PaddingTop.Scale * h + p.PaddingTop.Offset * s
		pb = p.PaddingBottom.Scale * h + p.PaddingBottom.Offset * s
		n.pad = { pl, pr, pt, pb }
	end
	if isText(inst) then
		local text = tostring(inst.Text or "")
		local color = inst.TextColor3
		local placeholder = false
		if inst:IsA("TextBox") and text == "" then
			text = tostring(get(inst, "PlaceholderText") or "")
			color = get(inst, "PlaceholderColor3") or color
			placeholder = true
		end
		local tx = {
			text = text,
			rich = inst.RichText == true,
			font = fontNameOf(inst),
			size = (tonumber(inst.TextSize) or 14) * s,
			scaled = inst.TextScaled == true,
			wrapped = inst.TextWrapped == true,
			color = rgb(color),
			t = tonumber(inst.TextTransparency) or 0,
			strokeColor = rgb(inst.TextStrokeColor3),
			strokeT = tonumber(inst.TextStrokeTransparency) or 1,
			xa = enumName(inst.TextXAlignment),
			ya = enumName(inst.TextYAlignment),
			lineHeight = tonumber(inst.LineHeight) or 1,
			maxGraphemes = tonumber(get(inst, "MaxVisibleGraphemes")) or -1,
			truncate = enumName(get(inst, "TextTruncate")),
			placeholder = placeholder,
			-- TextScaled bounds in screen px (Roblox's TextScaled tops out at 100 px before UIScale)
			minSize = 1 * s,
			maxSize = 100 * s,
		}
		if comp.textSize then
			tx.minSize = (tonumber(comp.textSize.MinTextSize) or 1) * s
			tx.maxSize = (tonumber(comp.textSize.MaxTextSize) or 100) * s
		end
		n.text = tx
	end
	if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
		n.image = { kind = "Image", image = tostring(inst.Image or ""), color = rgb(inst.ImageColor3), t = tonumber(inst.ImageTransparency) or 0 }
	elseif inst:IsA("ViewportFrame") then
		n.image = { kind = "Viewport", label = modelLabel(inst), color = rgb(inst.ImageColor3), t = tonumber(inst.ImageTransparency) or 0 }
	elseif inst:IsA("VideoFrame") then
		n.image = { kind = "Video", label = "video", color = { 255, 255, 255 }, t = 0 }
	end
	if inst:IsA("CanvasGroup") then
		n.group = { t = tonumber(get(inst, "GroupTransparency")) or 0, color = rgb(get(inst, "GroupColor3")) }
	end
	for i, c in ipairs(inst:GetChildren()) do
		local child = nodeOf(c, ctx, path .. "." .. c.Name, i)
		if child then
			n.children[#n.children + 1] = child
		end
	end
	if inst:IsA("ScrollingFrame") then
		local cs = inst.CanvasSize
		local cw = cs.X.Scale * w + cs.X.Offset * s
		local ch = cs.Y.Scale * h + cs.Y.Offset * s
		local cp = inst.CanvasPosition
		-- what the visible children span, measured from the canvas origin
		local contentW, contentH = 0, 0
		for _, child in ipairs(n.children) do
			contentW = max(contentW, child.x + child.w - x + cp.X)
			contentH = max(contentH, child.y + child.h - y + cp.Y)
		end
		contentW, contentH = contentW + pr, contentH + pb
		local auto = enumName(get(inst, "AutomaticCanvasSize"))
		if auto == "X" or auto == "XY" then
			cw = max(cw, contentW)
		end
		if auto == "Y" or auto == "XY" then
			ch = max(ch, contentH)
		end
		n.scroll = {
			bar = (tonumber(inst.ScrollBarThickness) or 12) * s,
			color = rgb(inst.ScrollBarImageColor3),
			t = tonumber(inst.ScrollBarImageTransparency) or 0,
			direction = enumName(get(inst, "ScrollingDirection")),
			canvas = { cw, ch },
			position = { cp.X, cp.Y },
		}
	end
	return n
end

local function walk()
	local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
	local data = {
		viewport = { Mock.Viewport.X, Mock.Viewport.Y },
		inset = Mock.TopInset or 0,
		touch = UserInputService.TouchEnabled == true,
		guis = {},
		skipped3d = 0,
		hidden = 0,
		nodes = 0,
	}
	if not pg then
		note("no PlayerGui")
		return data
	end
	for i, g in ipairs(pg:GetChildren()) do
		if g:IsA("ScreenGui") then
			local inset = (g.IgnoreGuiInset == false) and (Mock.TopInset or 0) or 0
			local entry = {
				name = g.Name,
				order = i,
				displayOrder = tonumber(g.DisplayOrder) or 0,
				ignoreInset = g.IgnoreGuiInset == true,
				zBehavior = enumName(g.ZIndexBehavior),
				enabled = g.Enabled ~= false,
				nodes = {},
			}
			if entry.enabled then
				local ctx = { inset = inset, count = data.nodes, hidden = 0 }
				for j, c in ipairs(g:GetChildren()) do
					local node = nodeOf(c, ctx, g.Name .. "." .. c.Name, j)
					if node then
						entry.nodes[#entry.nodes + 1] = node
					end
				end
				data.nodes = ctx.count
				data.hidden = data.hidden + ctx.hidden
			end
			data.guis[#data.guis + 1] = entry
		elseif g:IsA("LayerCollector") then
			data.skipped3d = data.skipped3d + 1
		end
	end
	return data
end

----------------------------------------------------------------------
-- the fake server (payloads as tools/smoke_client*.lua send them)
----------------------------------------------------------------------
local Config

local function remotesFolder()
	return ReplicatedStorage:FindFirstChild("Remotes")
end

local function ensureRemotes()
	if remotesFolder() then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "Remotes"
	for _, name in ipairs(Config.Remotes) do
		local r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	folder.Parent = ReplicatedStorage
end

local function toClient(name, ...)
	local folder = remotesFolder()
	local remote = folder and folder:FindFirstChild(name)
	if not remote then
		note("remote " .. name .. " does not exist")
		return
	end
	Mock.ToClient(remote, ...)
end

local function hum()
	return Mock.GetHumanoid(LocalPlayer)
end

-- a profile like the server's ProfileSync: two owned pets of every rarity (Secrets stay undiscovered), the first
-- two equipped, items, stats
local function snapshot()
	local pets, discovered, owned = {}, {}, {}
	local PetCatalog = req("shared/PetCatalog", true)
	local perRarity = {}
	if PetCatalog and type(PetCatalog.Pets) == "table" then
		for _, def in ipairs(PetCatalog.Pets) do
			local rarity = tostring(def.Rarity)
			if rarity ~= "Secret" and (perRarity[rarity] or 0) < 2 then
				perRarity[rarity] = (perRarity[rarity] or 0) + 1
				pets[def.Id] = (#owned % 3) + 1
				discovered[def.Id] = true
				owned[#owned + 1] = def.Id
			end
		end
	end
	local eq = {}
	for i = 1, min(2, #owned) do
		eq[i] = owned[i]
	end
	return {
		Tokens = 1250,
		Pets = pets,
		Equipped = eq,
		Items = { heal_cloud = 2, phoenix_feather = 1 },
		Stats = { Matches = 12, Wins = 7, TokensEarned = 900, Spins = 5, BestTimes = { Easy = 123.4 } },
		SpotIndex = 3,
		Perks = { MaxHealth = 0.12, TokenBonus = 0.25, StaminaRegen = 0, CheckpointHeal = 0.02 },
		Discovered = discovered,
		IndexClaimed = {},
		Tutorial = { Step = 9, Done = true, Gifted = true },
	}
end

local function difficulty(id)
	if type(Config.GetDifficulty) == "function" then
		local ok, d = pcall(Config.GetDifficulty, id)
		if ok and type(d) == "table" then
			return d
		end
	end
	return { Id = id, DisplayName = id, Color = Color3.fromRGB(96, 190, 140) }
end

local function matchState(over)
	local easy = difficulty("Easy")
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
			{ UserId = LocalPlayer.UserId, Name = LocalPlayer.Name, Health = 0.45, Downed = false, Finished = false, Tokens = 3 },
			{ UserId = 77, Name = "Buddy", Health = 0.8, Downed = false, Finished = false, Tokens = 4 },
			{ UserId = 78, Name = "Fallen", Health = 0.01, Downed = true, Finished = false, Tokens = 0 },
		},
	}
	for k, v in pairs(over or {}) do
		s[k] = v
	end
	return s
end

-- hold Shift for `seconds` while walking: MovementController drains the stamina bar like in a real run
local function drainStamina(seconds)
	local h = hum()
	if not h then
		return
	end
	h.MoveDirection = Vector3.new(0, 0, -1)
	Mock.KeysDown.LeftShift = true
	Mock.TriggerAction("NimbusRun", "Begin", Mock.NewInput("LeftShift", "Keyboard", "Begin"))
	advance(seconds)
	Mock.KeysDown.LeftShift = false
	Mock.TriggerAction("NimbusRun", "End", Mock.NewInput("LeftShift", "Keyboard", "End"))
	h.MoveDirection = Vector3.new(0, 0, 0)
end

local function setHealth(maxHealth, health)
	local h = hum()
	if h then
		h.MaxHealth = maxHealth
		h.Health = health
	end
end

local function tutorialPayload(index)
	local Steps = req("shared/TutorialSteps")
	local list = Steps.Steps or {}
	index = max(1, min(#list, index))
	local step = list[index]
	if not step then
		fail("TutorialSteps has no steps")
	end
	local text = tostring(step.Text or "")
	local tutorialCfg = Config.Tutorial or {}
	local finish = tutorialCfg.FinishReward or {}
	text = text:gsub("{GiftTokens}", tostring(tutorialCfg.GiftTokens or 0))
	text = text:gsub("{FinishTokens}", tostring(finish.Tokens or 0))
	return {
		Step = index, Total = #list, Id = step.Id, Title = step.Title, Text = text, Target = step.Target,
		CompleteOn = step.CompleteOn, Hint = step.Hint, Button = step.Button, Gift = step.Gift == true,
		Done = false, Completed = false, Skipped = false, Reward = 0,
	}
end

----------------------------------------------------------------------
-- scenarios
----------------------------------------------------------------------
local SCENARIOS = {}
local ORDER = {}
local function scenario(name, fn)
	SCENARIOS[name] = fn
	ORDER[#ORDER + 1] = name
end

scenario("lobby", function()
	advance(0.5)
end)

scenario("title", function() end)

scenario("match", function(arg)
	LocalPlayer:SetAttribute(Config.Attr.InMatch, true)
	LocalPlayer:SetAttribute(Config.Attr.MatchTokens, 7)
	toClient("MatchState", matchState())
	advance(2.5)
	setHealth(117, 117)
	advance(0.6)
	setHealth(117, 52)
	if arg == "hit" then
		try("stamina drain", drainStamina, 1.4)
		toClient("DamageTaken", 65, "Lightning")
		advance(0.25)
	else
		advance(2.2)
		try("stamina drain", drainStamina, 1.4) -- last, so the bar has no time to refill
		advance(0.2)
	end
end)

scenario("countdown", function()
	LocalPlayer:SetAttribute(Config.Attr.InMatch, true)
	toClient("MatchState", matchState({ Phase = "Countdown", Seconds = 3, Checkpoint = 0, TokensCollected = 0 }))
	advance(0.6)
end)

scenario("party", function()
	local medium = difficulty("Medium")
	toClient("PartyState", {
		PortalId = medium.Id,
		DifficultyName = medium.DisplayName,
		Color = medium.Color,
		Players = { { UserId = LocalPlayer.UserId, Name = LocalPlayer.Name }, { UserId = 77, Name = "Buddy" } },
		Max = 4,
		Countdown = 12,
	})
	advance(1.2)
end)

scenario("results", function()
	LocalPlayer:SetAttribute(Config.Attr.InMatch, true)
	toClient("MatchState", matchState())
	advance(0.5)
	toClient("MatchResult", {
		Won = true, Reason = "victory", Seconds = 187, MatchTokens = 11, Bonus = 10, DifficultyId = "Easy", DifficultyName = "Easy",
		Stars = 1, TotalTokens = 24,
		Members = {
			{ Name = LocalPlayer.Name, MatchTokens = 11, Finished = true, Downed = false },
			{ Name = "Buddy", MatchTokens = 6, Finished = true, Downed = false },
		},
	})
	advance(4)
end)

scenario("menu", function(window, tab)
	if not window or window == "" then
		fail("usage: menu:<Inventory|Pets|Index|Shop|Stats>[:<Tab>]")
	end
	local args = nil
	if tab and tab ~= "" then
		args = { Tab = tab, GroupId = tab }
	end
	toClient("OpenPanel", window, args)
	advance(2.5)
end)

scenario("tutorial", function(step)
	toClient("TutorialState", tutorialPayload(tonumber(step) or 1))
	advance(5)
end)

scenario("npc", function(which)
	local ND = req("shared/NpcDialog")
	local NC = req("client/Controllers/NpcController")
	local NS = req("server/Services/NpcService")
	local list = ND.Npcs or ND.List or {}
	local count = max(1, #list)
	local spots = {}
	local origin = (Config.Lobby and Config.Lobby.Origin) or Vector3.new(0, 300, 0)
	for i = 1, count do
		local a = (i - 1) * math.pi * 2 / count
		local pos = origin + Vector3.new(math.cos(a) * 30, 0, math.sin(a) * 30)
		spots[i] = CFrame.lookAt(pos, Vector3.new(origin.X, pos.Y, origin.Z))
	end
	Mock.Teleport(LocalPlayer, origin + Vector3.new(0, 3, 0))
	NS.Init({ NpcSpots = spots })
	advance(2)
	local index = tonumber(which) or 1
	local pick = list[index]
	if not pick then
		for _, npc in ipairs(list) do
			if npc.Id == which then
				pick = npc
			end
		end
	end
	if not pick then
		fail("no NPC '" .. tostring(which) .. "'")
	end
	for i, npc in ipairs(list) do
		if npc == pick then
			-- stand in front of it: the dialog closes when the player walks away
			Mock.Teleport(LocalPlayer, spots[i].Position + spots[i].LookVector * 7 + Vector3.new(0, 3, 0))
		end
	end
	advance(0.5)
	if not NC.Open(pick.Id) then
		note("NpcController.Open(" .. tostring(pick.Id) .. ") returned false")
	end
	advance(6)
end)

scenario("dev", function()
	local Dev = req("client/Controllers/DevController", true)
	if not Dev then
		fail("client/Controllers/DevController.lua does not exist")
	end
	LocalPlayer:SetAttribute("NC_Dev", true)
	advance(1)
	if type(Dev.Open) == "function" then
		Dev.Open()
	end
	advance(0.8)
end)

scenario("toasts", function()
	toClient("Notify", "Welcome back to Nimbus Climb!", "info", 8)
	advance(0.15)
	toClient("Notify", "Checkpoint 2/4 reached!", "good", 8)
	advance(0.15)
	toClient("Notify", "Not enough cloud tokens", "bad", 8)
	advance(0.15)
	toClient("Notify", "+25 cloud tokens", "token", 8)
	advance(0.9)
end)

----------------------------------------------------------------------
-- the widget gallery: one cell per feature the renderer draws, with known values (render_gui.py gallery and
-- tools/smoke_polish_guitool.lua check the tool against it). Built into PlayerGui as the ScreenGui RenderGallery.
----------------------------------------------------------------------
local NAVY = Color3.fromRGB(24, 34, 78)
local WHITE = Color3.fromRGB(255, 255, 255)

local function make(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props or {}) do
		inst[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(parent, scale, offset)
	return make("UICorner", { CornerRadius = UDim.new(scale, offset) }, parent)
end

local function label(parent, text, size, props)
	local l = make("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = text,
		TextSize = size,
		Font = Enum.Font.GothamBold,
		TextColor3 = WHITE,
		Size = UDim2.new(1, 0, 1, 0),
	}, parent)
	for k, v in pairs(props or {}) do
		l[k] = v
	end
	return l
end

local function buildGallery()
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("RenderGallery")
	if old then
		old:Destroy()
	end
	local gui = make("ScreenGui", { Name = "RenderGallery", ResetOnSpawn = false, IgnoreGuiInset = false, DisplayOrder = 50,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
	local vp = Mock.Viewport
	local area = Vector2.new(vp.X, vp.Y - (Mock.TopInset or 0))
	local root = make("Frame", { Name = "Cells", BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(1896, 960) }, gui)
	make("UIScale", { Scale = math.min(1, (area.X - 24) / 1896, (area.Y - 24) / 960) }, root)
	make("UIGridLayout", { CellSize = UDim2.fromOffset(306, 228), CellPadding = UDim2.fromOffset(12, 12),
		SortOrder = Enum.SortOrder.LayoutOrder }, root)
	local cells = {}
	local function cell(name, caption)
		local c = make("Frame", { Name = name, LayoutOrder = #cells + 1, BackgroundColor3 = Color3.fromRGB(30, 40, 80),
			BackgroundTransparency = 0.15, BorderSizePixel = 0 }, root)
		corner(c, 0, 12)
		label(c, caption, 16, { Name = "Caption", Position = UDim2.new(0, 8, 1, -32), Size = UDim2.new(1, -16, 0, 26),
			TextWrapped = true, TextStrokeTransparency = 0.4 })
		local demo = make("Frame", { Name = "Demo", BackgroundTransparency = 1, BorderSizePixel = 0,
			Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 1, -48) }, c)
		cells[#cells + 1] = c
		return demo
	end
	local centre = { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) }
	local function centred(className, size, props, parent)
		local p = { AnchorPoint = centre.AnchorPoint, Position = centre.Position, Size = size, BorderSizePixel = 0 }
		for k, v in pairs(props or {}) do
			p[k] = v
		end
		return make(className, p, parent)
	end

	-- 1 corner + border stroke
	local d = cell("Corner", "UICorner 16 + Border UIStroke 4")
	local f = centred("Frame", UDim2.fromOffset(170, 100), { Name = "Box", BackgroundColor3 = Color3.fromRGB(238, 126, 176) }, d)
	corner(f, 0, 16)
	make("UIStroke", { Color = NAVY, Thickness = 4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	-- 2 vertical gradient
	d = cell("GradientV", "UIGradient 90: white to navy")
	f = centred("Frame", UDim2.fromOffset(170, 100), { Name = "Box", BackgroundColor3 = WHITE }, d)
	corner(f, 0, 12)
	make("UIGradient", { Color = ColorSequence.new(WHITE, NAVY), Rotation = 90 }, f)
	-- 3 horizontal gradient with transparency
	d = cell("GradientT", "UIGradient 0: transparency 0 to 1")
	f = centred("Frame", UDim2.fromOffset(170, 100), { Name = "Box", BackgroundColor3 = Color3.fromRGB(90, 158, 234) }, d)
	corner(f, 0, 12)
	make("UIGradient", { Transparency = NumberSequence.new(0, 1), Rotation = 0 }, f)
	-- 4 rotation
	d = cell("Rotation", "Rotation 30 (children turn too)")
	f = centred("Frame", UDim2.fromOffset(96, 96), { Name = "Box", Rotation = 30, BackgroundColor3 = Color3.fromRGB(244, 196, 78) }, d)
	corner(f, 0, 12)
	make("UIStroke", { Color = NAVY, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	label(f, "30", 34, { Name = "Text", TextColor3 = NAVY, Font = Enum.Font.FredokaOne })
	-- 5 TextScaled + constraint
	d = cell("Scaled", "TextScaled, MaxTextSize 28")
	f = centred("TextLabel", UDim2.fromOffset(240, 70), { Name = "Box", BackgroundColor3 = Color3.fromRGB(64, 84, 142),
		Text = "Scaled to fit", TextScaled = true, Font = Enum.Font.FredokaOne, TextColor3 = WHITE }, d)
	make("UITextSizeConstraint", { MaxTextSize = 28, MinTextSize = 10 }, f)
	-- 6 wrapping + padding
	d = cell("Wrapped", "Wrapped, Left / Top, UIPadding 8")
	f = centred("TextLabel", UDim2.fromOffset(250, 110), { Name = "Box", BackgroundColor3 = Color3.fromRGB(226, 234, 246),
		Text = "Long text wraps on spaces inside its box, starting at the top left corner.", TextWrapped = true, TextSize = 18,
		Font = Enum.Font.GothamBold, TextColor3 = Color3.fromRGB(30, 40, 82), TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top }, d)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8) }, f)
	-- 7 truncation
	d = cell("Truncate", "TextTruncate AtEnd")
	f = centred("TextLabel", UDim2.fromOffset(230, 36), { Name = "Box", BackgroundColor3 = Color3.fromRGB(64, 84, 142),
		Text = "This text is far too long for its box", TextSize = 20, Font = Enum.Font.GothamBold, TextColor3 = WHITE,
		TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = Enum.TextXAlignment.Left }, d)
	-- 8 rich text
	d = cell("Rich", "RichText font colours")
	centred("TextLabel", UDim2.fromOffset(270, 40), { Name = "Box", BackgroundTransparency = 1, RichText = true, TextSize = 22,
		Font = Enum.Font.GothamBold, TextColor3 = WHITE,
		Text = 'Rich <font color="#ff6070">red</font> and <font color="rgb(90,220,130)">green</font> &amp; more' }, d)
	-- 9 typewriter
	d = cell("Typewriter", "MaxVisibleGraphemes 6")
	centred("TextLabel", UDim2.fromOffset(270, 40), { Name = "Box", BackgroundTransparency = 1, TextSize = 26,
		Font = Enum.Font.FredokaOne, TextColor3 = WHITE, Text = "Typewriter text", MaxVisibleGraphemes = 6 }, d)
	-- 10 list layout of auto-sized pills
	d = cell("List", "UIListLayout + AutomaticSize X pills")
	local row = centred("Frame", UDim2.fromOffset(280, 40), { Name = "Row", BackgroundTransparency = 1 }, d)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center }, row)
	for i, text in ipairs({ "A", "Pill", "Longer pill" }) do
		local pill = make("TextLabel", { Name = "Pill" .. i, LayoutOrder = i, AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 34), BackgroundColor3 = Color3.fromRGB(96, 196, 108), BorderSizePixel = 0, Text = text,
			TextSize = 20, Font = Enum.Font.FredokaOne, TextColor3 = WHITE }, row)
		corner(pill, 0.5, 0)
		make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, pill)
	end
	-- 11 grid layout
	d = cell("Grid", "UIGridLayout 60 x 50, padding 6")
	local grid = centred("Frame", UDim2.fromOffset(192, 106), { Name = "Grid", BackgroundTransparency = 1 }, d)
	make("UIGridLayout", { CellSize = UDim2.fromOffset(60, 50), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	for i = 1, 6 do
		local c = make("TextLabel", { Name = "Cell" .. i, LayoutOrder = i, BackgroundColor3 = Color3.fromHSV((i - 1) / 6, 0.55, 0.9),
			BorderSizePixel = 0, Text = tostring(i), TextSize = 22, Font = Enum.Font.FredokaOne, TextColor3 = NAVY }, grid)
		corner(c, 0, 8)
	end
	-- 12 scrolling frame
	d = cell("Scroll", "ScrollingFrame: clips + scroll bar")
	local sf = centred("ScrollingFrame", UDim2.fromOffset(220, 120), { Name = "List", BackgroundColor3 = Color3.fromRGB(20, 28, 60),
		CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 8,
		ScrollBarImageColor3 = Color3.fromRGB(176, 212, 244), CanvasPosition = Vector2.new(0, 30) }, d)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
	for i = 1, 6 do
		label(sf, "Row " .. i, 18, { Name = "Row" .. i, LayoutOrder = i, Size = UDim2.new(1, -12, 0, 30), BackgroundTransparency = 0,
			BackgroundColor3 = Color3.fromRGB(64, 84, 142) })
	end
	-- 13 canvas group
	d = cell("Group", "CanvasGroup, transparency 0.5")
	local cg = centred("CanvasGroup", UDim2.fromOffset(170, 100), { Name = "Box", GroupTransparency = 0.5,
		BackgroundColor3 = Color3.fromRGB(228, 90, 92) }, d)
	corner(cg, 0, 16)
	make("Frame", { Name = "Bar", BackgroundColor3 = WHITE, BorderSizePixel = 0, Position = UDim2.new(0, -20, 0.6, 0),
		Size = UDim2.new(1, 40, 0, 20) }, cg)
	label(cg, "50%", 30, { Name = "Text", Font = Enum.Font.FredokaOne, Size = UDim2.new(1, 0, 0.6, 0) })
	-- 14 image + viewport placeholders
	d = cell("Media", "ImageLabel + ViewportFrame")
	make("ImageLabel", { Name = "Image", BackgroundTransparency = 1, Image = "rbxassetid://1234567", Position = UDim2.new(0.5, -126, 0.5, -55),
		Size = UDim2.fromOffset(110, 110) }, d)
	local vf = make("ViewportFrame", { Name = "Viewport", BackgroundColor3 = Color3.fromRGB(176, 212, 244), BorderSizePixel = 0,
		Position = UDim2.new(0.5, 16, 0.5, -55), Size = UDim2.fromOffset(110, 110) }, d)
	corner(vf, 0, 12)
	local model = make("Model", { Name = "DemoPet" }, vf)
	make("Part", { Name = "Body", Size = Vector3.new(2, 2, 2), Anchored = true }, model)
	-- 15 legacy border
	d = cell("Border", "BorderSizePixel 3 (no UICorner)")
	centred("Frame", UDim2.fromOffset(170, 90), { Name = "Box", BackgroundColor3 = Color3.fromRGB(226, 234, 246), BorderSizePixel = 3,
		BorderColor3 = Color3.fromRGB(96, 196, 108) }, d)
	-- 16 UIScale
	d = cell("Scale", "UIScale 1.5: 20 px text -> 30 px")
	local holder = centred("Frame", UDim2.fromOffset(120, 44), { Name = "Holder", BackgroundColor3 = Color3.fromRGB(64, 84, 142) }, d)
	corner(holder, 0, 10)
	make("UIScale", { Scale = 1.5 }, holder)
	local scaledText = label(holder, "Scaled", 20, { Name = "Text", Font = Enum.Font.FredokaOne })
	make("UIStroke", { Color = NAVY, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, scaledText)
	-- 17 text outline
	d = cell("Outline", "Contextual UIStroke 3 on text")
	local outline = centred("TextLabel", UDim2.fromOffset(250, 60), { Name = "Box", BackgroundTransparency = 1, Text = "Outline",
		TextSize = 44, Font = Enum.Font.FredokaOne, TextColor3 = Color3.fromRGB(250, 224, 132), TextStrokeTransparency = 0 }, d)
	make("UIStroke", { Color = NAVY, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, outline)
	-- 18 ZIndex
	d = cell("ZIndex", "ZIndex 2 (red) over a later sibling")
	f = make("Frame", { Name = "Red", ZIndex = 2, BackgroundColor3 = Color3.fromRGB(228, 90, 92), BorderSizePixel = 0,
		Position = UDim2.new(0.5, -90, 0.5, -45), Size = UDim2.fromOffset(110, 70) }, d)
	corner(f, 0, 10)
	f = make("Frame", { Name = "Blue", ZIndex = 1, BackgroundColor3 = Color3.fromRGB(90, 158, 234), BorderSizePixel = 0,
		Position = UDim2.new(0.5, -30, 0.5, -20), Size = UDim2.fromOffset(110, 70) }, d)
	corner(f, 0, 10)
	-- 19 emoji + symbols
	d = cell("Glyphs", "Emoji and symbols")
	centred("TextLabel", UDim2.fromOffset(270, 50), { Name = "Box", BackgroundTransparency = 1, TextSize = 30, Font = Enum.Font.FredokaOne,
		TextColor3 = WHITE, Text = "\240\159\142\146 Bag \226\152\129 \226\152\133 \226\153\165" }, d)
	-- 20 pill corner (scale radius) + hidden subtree
	d = cell("Pill", "CornerRadius (0.5, 0) = pill")
	f = centred("Frame", UDim2.fromOffset(200, 50), { Name = "Box", BackgroundColor3 = Color3.fromRGB(160, 130, 232) }, d)
	corner(f, 0.5, 0)
	local hidden = make("Frame", { Name = "Hidden", Visible = false, Size = UDim2.fromOffset(40, 40) }, f)
	make("Frame", { Name = "InsideHidden", Size = UDim2.fromOffset(20, 20) }, hidden)
	gui.Parent = pg
	return gui
end

-- metrics probe for the smoke test: hook a fake measure (1 em per character), read an AutomaticSize label, restore
local function probeMetrics(gui)
	local probe = make("TextLabel", { Name = "MetricsProbe", AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 20),
		Text = "abcdefghij", TextSize = 20, Font = Enum.Font.GothamBold, BackgroundTransparency = 1 }, gui)
	local before = probe.AbsoluteSize.X
	local ok, restore = installMetrics(function(_, text)
		return utf8len(tostring(text))
	end)
	local hooked = probe.AbsoluteSize.X
	local bounds = probe.TextBounds.X
	if ok then
		restore()
	end
	local after = probe.AbsoluteSize.X
	probe:Destroy()
	return { hooked = ok == true, before = before, during = hooked, bounds = bounds, after = after, reason = (not ok) and tostring(restore) or nil }
end

----------------------------------------------------------------------
-- portal: the world GUIs of one portal, built by the real LobbyBuilder + PortalService and mirrored flat into the
-- ScreenGui WorldMirror (no game HUD). The pixel billboard is drawn at its own size (it keeps that size on
-- screen at any distance); the eye-level countdown face (a SurfaceGui) is drawn at the size it has on this screen
-- from `distance` studs (70 degree vertical field of view, over a sketch of the gate's swirl), then at its canvas
-- size for the details.
----------------------------------------------------------------------
local FOV_HALF_TAN = math.tan(math.rad(35))
local FRIEND_DISTANCE = 36 -- studs: a friend 4 studs outside the lock walls, default camera 12.5 studs behind

local function canvasOf(gui)
	if gui:IsA("BillboardGui") then
		return gui.Size.X.Offset, gui.Size.Y.Offset
	end
	return gui.CanvasSize.X, gui.CanvasSize.Y
end

-- screen px per canvas px of a SurfaceGui seen face-on from `distance` studs
local function onScreenScale(gui, distance)
	local pps = gui.PixelsPerStud
	if gui.SizingMode ~= Enum.SurfaceGuiSizingMode.PixelsPerStud or not pps or pps <= 0 then
		pps = 50
	end
	return Mock.Viewport.Y / (2 * FOV_HALF_TAN * distance) / pps
end

-- the gate's swirl (radius 5.3 studs) and its glow ring behind a face cell `w` x `h` canvas px at `pps`
local function swirlSketch(parent, x, y, w, h, scale, pps, color)
	local r = 5.3 * pps * scale
	local swirl = make("Frame", {
		Name = "SwirlSketch",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(x + w * scale / 2, y + h * scale / 2),
		Size = UDim2.fromOffset(2 * r, 2 * r),
		BackgroundColor3 = color:Lerp(WHITE, 0.35),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
	}, parent)
	corner(swirl, 0.5, 0)
	make("UIStroke", { Color = color, Thickness = max(2, 0.5 * pps * scale), Transparency = 0.1 }, swirl)
	return swirl
end

-- Multiplies every pixel quantity under `root` by `s` (sizes, positions, text sizes, strokes, corners, paddings,
-- list gaps). The mock measures AutomaticSize text without the scale of an ANCESTOR UIScale, so a scaled copy is
-- made this way instead; a text that would pass Roblox's 100 px cap keeps 100 and gets the rest as its own UIScale.
local function deepScale(root, s)
	local function u2(v)
		return UDim2.new(v.X.Scale, v.X.Offset * s, v.Y.Scale, v.Y.Offset * s)
	end
	local function ud(v)
		return UDim.new(v.Scale, v.Offset * s)
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.Size = u2(d.Size)
			d.Position = u2(d.Position)
			if isText(d) then
				local px = d.TextSize * s
				if px > 100 then
					local own = d:FindFirstChildWhichIsA("UIScale")
					if own then
						own.Scale = own.Scale * px / 100
					else
						make("UIScale", { Scale = px / 100 }, d)
					end
					px = 100
				end
				d.TextSize = max(1, px)
			end
		elseif d:IsA("UICorner") then
			d.CornerRadius = ud(d.CornerRadius)
		elseif d:IsA("UIStroke") then
			d.Thickness = d.Thickness * s
		elseif d:IsA("UIPadding") then
			d.PaddingTop, d.PaddingBottom = ud(d.PaddingTop), ud(d.PaddingBottom)
			d.PaddingLeft, d.PaddingRight = ud(d.PaddingLeft), ud(d.PaddingRight)
		elseif d:IsA("UIListLayout") then
			d.Padding = ud(d.Padding)
		end
	end
end

-- a flat copy of `gui`'s content with its top-left at (x, y), drawn `scale` times its canvas size; caption above
local function mirrorCell(parent, gui, x, y, scale, caption)
	local w, h = canvasOf(gui)
	local cell = make("Frame", { Name = gui.Name, BackgroundTransparency = 1, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w * scale, h * scale) }, parent)
	for _, c in ipairs(gui:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Clone().Parent = cell
		end
	end
	if math.abs(scale - 1) > 1e-3 then
		deepScale(cell, scale)
	end
	label(parent, caption, 18, {
		Name = "Caption",
		Position = UDim2.fromOffset(x, y - 30),
		Size = UDim2.fromOffset(max(utf8len(caption) * 10 + 12, w * scale), 24),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextStrokeTransparency = 0.2,
		TextStrokeColor3 = NAVY,
	})
	return cell
end

-- portal[:<Id>[:<members>[:<distance>]]]
local function portalScene(id, members, distance, width, height)
	Config = req("shared/Config")
	local okMetrics, why = installMetrics()
	if not okMetrics then
		note("text metrics: " .. tostring(why))
	end
	ensureRemotes()
	Mock.SetViewport(width, height)
	-- the two services are server code (PortalService listens to OnServerEvent): run them as the server would,
	-- then hand the world back to the client for the walk
	local context = Mock.Context
	Mock.Context = "server"
	local LobbyBuilder = req("server/Services/LobbyBuilder")
	local PortalService = req("server/Services/PortalService")
	local lobby = LobbyBuilder.Build()
	local portals = (type(lobby) == "table" and lobby.Portals) or {}
	if not id or id == "" then
		id = "Medium"
	end
	if not portals[id] then
		Mock.Context = context
		local known = {}
		for _, d in ipairs(Config.Difficulties) do
			known[#known + 1] = d.Id
		end
		fail("no portal '" .. tostring(id) .. "'. Known: " .. table.concat(known, ", "))
	end
	-- no matches here: a launch just fails quietly
	PortalService.Init(lobby, {
		StartMatch = function()
			return nil
		end,
		GetMatchOf = function()
			return nil
		end,
	})
	local info = portals[id]
	local zone = info.Zone
	local count = max(0, min(Config.Match.MaxPlayers, floor(tonumber(members) or 1)))
	local list = { LocalPlayer }
	for i = 2, count do
		list[i] = Mock.AddPlayer("Buddy" .. i, 9100 + i)
	end
	advance(0.3)
	Mock.Teleport(LocalPlayer, (Config.Lobby.Origin or Vector3.new(0, 300, 0)) + Vector3.new(0, 4, 0))
	for i = 1, count do
		Mock.Teleport(list[i], zone.CFrame * CFrame.new((i - 1) * 2.6 - 3.9, 0, 1))
	end
	advance(1.6)
	Mock.Context = context

	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local screen = make("ScreenGui", { Name = "WorldMirror", IgnoreGuiInset = true, ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
	local vp = Mock.Viewport
	local x, y, rowH = 24, 104, 0 -- under the top bar
	local function place(w, h, caption)
		w = max(w, utf8len(caption) * 10 + 12) -- the caption's width (18 px text)
		if x > 24 and x + w > vp.X - 24 then
			x, y, rowH = 24, y + rowH + 56, 0
		end
		local px, py = x, y
		x = x + w + 48
		rowH = max(rowH, h)
		return px, py
	end

	local board = info.Billboard
	if board and board:IsA("BillboardGui") then
		local w, h = canvasOf(board)
		local caption = "Billboard (pixels; " .. floor(board.MaxDistance) .. " studs max)"
		local px, py = place(w, h, caption)
		mirrorCell(screen, board, px, py, 1, caption)
	else
		note("portal " .. id .. " has no billboard")
	end

	local facePart = info.CountdownFace
	local face = facePart and facePart:FindFirstChildWhichIsA("SurfaceGui")
	if face then
		local d = tonumber(distance) or FRIEND_DISTANCE
		local s = onScreenScale(face, d)
		local w, h = canvasOf(face)
		local caption = fmt("Face from %d studs (x%.2f)%s", d, s, face.Enabled and "" or ", hidden")
		local px, py = place(w * s, h * s, caption)
		swirlSketch(screen, px, py, w, h, s, face.PixelsPerStud, (info.Model and info.Model:FindFirstChild("SwirlCore") and info.Model.SwirlCore.Color) or difficulty(id).Color)
		mirrorCell(screen, face, px, py, s, caption)
		caption = fmt("Face canvas (%d px per stud)", floor(face.PixelsPerStud))
		px, py = place(w, h, caption)
		mirrorCell(screen, face, px, py, 1, caption)
	else
		note("portal " .. id .. " has no CountdownFace")
	end
	screen.Parent = pg
	advance(0.1)
	return okMetrics
end

----------------------------------------------------------------------
-- homepads: the world GUIs of a Phase 2 home (server/Services/HomeBuilder.lua), mirrored flat like the portal's
----------------------------------------------------------------------
local function homePadsScene(tier, width, height)
	Config = req("shared/Config")
	local okMetrics, why = installMetrics()
	if not okMetrics then
		note("text metrics: " .. tostring(why))
	end
	ensureRemotes()
	Mock.SetViewport(width, height)
	local context = Mock.Context
	Mock.Context = "server"
	local LobbyBuilder = req("server/Services/LobbyBuilder")
	local HB = req("server/Services/HomeBuilder", true)
	local TC = req("shared/TycoonCatalog", true)
	if not HB or not TC then
		Mock.Context = context
		fail("homepads needs server/Services/HomeBuilder.lua and shared/TycoonCatalog.lua")
	end
	local lobby = LobbyBuilder.Build()
	HB.Init(lobby)
	local spot, free = lobby.Spots[1], lobby.Spots[2]
	HB.SetOwner(spot, LocalPlayer)
	tier = max(1, min(4, floor(tonumber(tier) or 2)))
	local tierId = TC.HouseTiers[tier].Id
	local home = { Stations = {}, Prestige = 0 }
	for _, def in ipairs(TC.Stations) do
		local cap = (def.TierCaps and def.TierCaps[tierId]) or 0
		if def.Id == "House" then
			cap = tier
		elseif def.Id ~= "Press1" and def.Id ~= "Collector" then
			cap = floor(cap / 2)
		end
		if cap > 0 and not def.ComingSoon then
			home.Stations[def.Id] = min(cap, def.MaxLevel)
		end
	end
	HB.BuildHome(spot, home)
	HB.SetPads(spot, TC.AvailablePads(home))
	HB.SetCollector(spot, 12345, 50000)
	advance(0.3)
	Mock.Context = context

	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local screen = make("ScreenGui", { Name = "WorldMirror", IgnoreGuiInset = true, ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
	local vp = Mock.Viewport
	local x, y, rowH = 24, 104, 0
	local function place(w, h, caption)
		w = max(w, utf8len(caption) * 10 + 12)
		if x > 24 and x + w > vp.X - 24 then
			x, y, rowH = 24, y + rowH + 56, 0
		end
		local px, py = x, y
		x = x + w + 36
		rowH = max(rowH, h)
		return px, py
	end
	local pads = {}
	for _, d in ipairs(spot.Folder:GetDescendants()) do
		if d:IsA("BillboardGui") and d.Name == "PadSign" then
			pads[#pads + 1] = d
		end
	end
	table.sort(pads, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	for _, gui in ipairs(pads) do
		local w, h = canvasOf(gui)
		local node, id = gui, "?"
		for _ = 1, 6 do
			node = node.Parent
			if not node then
				break
			end
			if node:GetAttribute("StationId") then
				id = node:GetAttribute("StationId")
				break
			end
		end
		local px, py = place(w, h, id)
		mirrorCell(screen, gui, px, py, 1, id)
	end
	-- a PixelsPerStud surface sign: its canvas is the adornee's face size x PixelsPerStud
	local function surface(gui, caption)
		if not gui then
			note("homepads: no " .. caption)
			return
		end
		local part = gui.Adornee or gui.Parent
		local fw, fh = 4, 2
		if part and part:IsA("BasePart") then
			local sz = part.Size
			if gui.Face == Enum.NormalId.Top or gui.Face == Enum.NormalId.Bottom then
				fw, fh = sz.X, sz.Z
			elseif gui.Face == Enum.NormalId.Left or gui.Face == Enum.NormalId.Right then
				fw, fh = sz.Z, sz.Y
			else
				fw, fh = sz.X, sz.Y
			end
		end
		local pps = gui.PixelsPerStud or 50
		local w, h = fw * pps, fh * pps
		for _, scale in ipairs({ onScreenScale(gui, 30), 1 }) do
			local cap = (scale == 1) and (caption .. " canvas") or (caption .. fmt(" from 30 studs (x%.2f)", scale))
			local px, py = place(w * scale, h * scale, cap)
			local cell = make("Frame", { Name = gui.Name, BackgroundTransparency = 1, Position = UDim2.fromOffset(px, py), Size = UDim2.fromOffset(w * scale, h * scale) }, screen)
			for _, c in ipairs(gui:GetChildren()) do
				if c:IsA("GuiObject") then
					c:Clone().Parent = cell
				end
			end
			if math.abs(scale - 1) > 1e-3 then
				deepScale(cell, scale)
			end
			label(screen, cap, 18, {
				Name = "Caption",
				Position = UDim2.fromOffset(px, py - 30),
				Size = UDim2.fromOffset(max(utf8len(cap) * 10 + 12, w * scale), 24),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextStrokeTransparency = 0.2,
				TextStrokeColor3 = NAVY,
			})
		end
	end
	local claim = free and free.Folder and free.Folder:FindFirstChild("ClaimGui", true)
	surface(claim, "Claim sign")
	local cash = spot.Folder:FindFirstChild("CashGui", true)
	surface(cash, "Collector screen")
	screen.Parent = pg
	advance(0.1)
	return okMetrics
end

----------------------------------------------------------------------
-- boot
----------------------------------------------------------------------
local function boot(width, height, touch, keepTitle)
	Config = req("shared/Config")
	local okMetrics, why = installMetrics()
	if not okMetrics then
		note("text metrics: " .. tostring(why))
	end
	ensureRemotes()
	if touch then
		UserInputService.TouchEnabled = true
		UserInputService.KeyboardEnabled = false
		UserInputService.MouseEnabled = false
	end
	Mock.SetViewport(width, height)
	LocalPlayer:SetAttribute(Config.Attr.Tokens, 1250)
	local main = Mock.GetPath(ROOTS["client"] .. "/Main")
	if not main or not main:IsA("LocalScript") then
		fail("client/Main.client.lua was not mounted")
	end
	Mock.RunScript(main)
	advance(0.8)
	toClient("ProfileSync", snapshot())
	if keepTitle then
		advance(1.2)
	else
		advance(7.5) -- the title card slides in, stays four seconds and leaves
	end
	return okMetrics
end

----------------------------------------------------------------------
-- main
----------------------------------------------------------------------
local function summaryOf(data)
	local guis = {}
	for _, g in ipairs(data.guis) do
		guis[#guis + 1] = g.name .. (g.enabled and "" or " (disabled)")
	end
	return fmt("%d visible GuiObjects in %d ScreenGuis (%s); %d hidden subtrees", data.nodes, #data.guis, table.concat(guis, ", "), data.hidden)
end

local data
if ARGS.walk then
	-- the PlayerGui as it is now (tools/smoke_polish_guitool.lua); ARGS.gallery adds the widget gallery for the walk
	local gallery, probe = nil, nil
	if ARGS.gallery then
		gallery = buildGallery()
		if ARGS.probe then
			probe = probeMetrics(gallery)
		end
	end
	data = walk()
	data.scenario = "walk"
	data.probe = probe
	if gallery and not ARGS.keep then
		gallery:Destroy()
	end
else
	local spec = tostring(ARGS.scenario or "lobby")
	local fields = split(spec, ":")
	local name = (fields[1] or ""):lower()
	local width = tonumber(ARGS.width) or 1920
	local height = tonumber(ARGS.height) or 1080
	if name == "gallery" then
		-- the widget gallery alone (no game UI)
		local okMetrics, why = installMetrics()
		if not okMetrics then
			note("text metrics: " .. tostring(why))
		end
		Mock.SetViewport(width, height)
		buildGallery()
		advance(0.1)
		data = walk()
		data.metrics = okMetrics and "font" or "mock"
	elseif name == "portal" then
		-- the world GUIs of one portal (no game HUD)
		local okMetrics = portalScene(fields[2], fields[3], fields[4], width, height)
		data = walk()
		data.metrics = okMetrics and "font" or "mock"
	elseif name == "homepads" then
		-- the world GUIs of a Phase 2 home (no game HUD)
		local okMetrics = homePadsScene(fields[2], width, height)
		data = walk()
		data.metrics = okMetrics and "font" or "mock"
	else
		local fn = SCENARIOS[name]
		if not fn then
			fail("unknown scenario '" .. spec .. "'. Known: gallery, portal, " .. table.concat(ORDER, ", "))
		end
		local metrics = boot(width, height, ARGS.touch == true, name == "title")
		fn(fields[2], fields[3])
		data = walk()
		data.metrics = metrics and "font" or "mock"
	end
	data.scenario = spec
end
data.notes = notes
data.player = LocalPlayer and LocalPlayer.Name or ""

local json = toJson(data)
if ARGS.out and ARGS.out ~= "" then
	local fh, err = io.open(tostring(ARGS.out), "w")
	if not fh then
		fail("cannot write " .. tostring(ARGS.out) .. ": " .. tostring(err))
	end
	fh:write(json)
	fh:close()
end
return json, summaryOf(data), data
