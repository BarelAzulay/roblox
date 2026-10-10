-- smoke_polish_guitool.lua: client-world checks for the offline GUI renderer (tools/render_gui.py) and its dumper
-- (tools/dump_gui.lua), run by tools/smoke.py after the other client scenarios:
--   client_gui_dump   the dumper compiles and walks the live PlayerGui without changing it; every visible GuiObject
--                     is dumped once (hidden subtrees are not), in tree order, with its absolute box (top bar inset
--                     included exactly when the ScreenGui respects it); the widget gallery comes out with the values it
--                     was built with (corner radius in px, UIStroke thickness / mode, UIGradient keypoints, Rotation,
--                     UIScale applied to text size and strokes, TextScaled bounds, padding, alignment, truncation,
--                     rich text, typewriter, list / grid placement, ScrollingFrame canvas, CanvasGroup, placeholders,
--                     legacy border, ZIndex); the real-font text measure hooks into the mock's layout engine
--                     (AutomaticSize and TextBounds follow it) and is removed again without a trace.
-- dump_gui.lua is read from tools/ relative to the working directory (smoke.py / run_checks.sh run from the repo root).
-- Plain Lua 5.1 syntax only.

local T = SmokeCommon.T
local guarded = SmokeCommon.guarded

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local abs = math.abs

local S = {}

local function close(a, b, tol)
	return type(a) == "number" and type(b) == "number" and abs(a - b) <= (tol or 0.01)
end

local function loadDumper()
	local here = debug.getinfo(1, "S").source:match("^=(.*)smoke_polish_guitool%.lua$")
	local candidates = { "tools/dump_gui.lua", "dump_gui.lua", "../tools/dump_gui.lua" }
	if here and here ~= "" then
		table.insert(candidates, 1, here .. "dump_gui.lua")
	end
	for _, path in ipairs(candidates) do
		local fh = io.open(path, "r")
		if fh then
			local src = fh:read("*a")
			fh:close()
			local load_ = loadstring or load
			local fn, err = load_(src, "=tools/dump_gui.lua")
			return fn, err
		end
	end
	return nil, "tools/dump_gui.lua not found from the working directory (run tools/smoke.py from the repo root)"
end

-- runs the dumper chunk with DUMP = spec; returns ok, json, summary, data
local function runDumper(fn, spec)
	local saved = rawget(_G, "DUMP")
	rawset(_G, "DUMP", spec)
	local ok, json, summary, data = pcall(fn)
	rawset(_G, "DUMP", saved)
	return ok, json, summary, data
end

-- visible GuiObjects of a ScreenGui in the dumper's order (children in GetChildren order, depth first)
local function visibleObjects(gui)
	local out = {}
	local function visit(inst)
		for _, c in ipairs(inst:GetChildren()) do
			if c:IsA("GuiObject") and c.Visible then
				out[#out + 1] = c
				visit(c)
			end
		end
	end
	visit(gui)
	return out
end

local function flatten(nodes, out)
	out = out or {}
	for _, n in ipairs(nodes or {}) do
		out[#out + 1] = n
		flatten(n.children, out)
	end
	return out
end

local function entryOf(data, name)
	for _, g in ipairs(data.guis or {}) do
		if g.name == name then
			return g
		end
	end
	return nil
end

-- compares a dumped ScreenGui with the live one: same objects, same order, same boxes; returns bad, total, examples
local function crossCheck(gui, entry)
	local live = visibleObjects(gui)
	local dumped = flatten(entry.nodes)
	local inset = gui.IgnoreGuiInset and 0 or (Mock.TopInset or 0)
	local bad, examples = 0, {}
	if #live ~= #dumped then
		return 1, math.max(#live, #dumped), { string.format("%s: %d visible objects, %d dumped", gui.Name, #live, #dumped) }
	end
	for i, inst in ipairs(live) do
		local n = dumped[i]
		local p, s = inst.AbsolutePosition, inst.AbsoluteSize
		local ok = n.name == inst.Name and n.class == inst.ClassName and close(n.x, p.X) and close(n.y, p.Y + inset)
			and close(n.w, s.X) and close(n.h, s.Y)
		if not ok then
			bad = bad + 1
			if #examples < 3 then
				examples[#examples + 1] = string.format("%s: dumped %s %.1f,%.1f %.1fx%.1f, live %s %.1f,%.1f %.1fx%.1f", tostring(n.path), tostring(n.name),
					n.x or -1, n.y or -1, n.w or -1, n.h or -1, inst.Name, p.X, p.Y + inset, s.X, s.Y)
			end
		end
	end
	return bad, #live, examples
end

S.client_gui_dump = guarded("client_gui_dump", function()
	local fn, err = loadDumper()
	if not T.check(fn ~= nil, "GUI dumper: tools/dump_gui.lua compiles", tostring(err)) then
		return
	end
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local before = #pg:GetDescendants()

	-- 1. the live game UI, untouched
	local ok, json, summary, data = runDumper(fn, { walk = true })
	if not T.check(ok and type(data) == "table", "GUI dumper: walks the live PlayerGui", tostring(json)) then
		return
	end
	T.check(type(json) == "string" and json:sub(1, 1) == "{" and json:find('"guis":[', 1, true) ~= nil, "GUI dumper: returns JSON text", tostring(json):sub(1, 80))
	T.check(not json:find("[^%w_]nan[^%w_]") and not json:find("[^%w_]inf[^%w_]"), "GUI dumper: the JSON has no NaN / inf numbers")
	T.eq(#pg:GetDescendants(), before, "GUI dumper: walking changes nothing in PlayerGui")
	local hud = entryOf(data, "NimbusHud")
	T.check(hud ~= nil and #hud.nodes > 0 and hud.ignoreInset == false and hud.displayOrder == 10, "GUI dumper: NimbusHud is dumped with its display order and inset flag")
	local tally = T.tally("GUI dumper: every visible GuiObject of every ScreenGui is dumped once, in order, with its absolute box (+ top bar inset)")
	local total = 0
	for _, g in ipairs(pg:GetChildren()) do
		if g:IsA("ScreenGui") and g.Enabled then
			local entry = entryOf(data, g.Name)
			if not entry then
				tally:case(false, g.Name .. " missing from the dump")
			else
				local bad, n, examples = crossCheck(g, entry)
				total = total + n
				tally:case(bad == 0, table.concat(examples, " | "))
			end
		end
	end
	tally:report(total .. " objects")
	T.eq(data.nodes, total, "GUI dumper: the node count matches the visible objects")
	T.info("*GUI dumper: " .. tostring(summary))

	-- 2. the widget gallery: known values in, the same values out
	ok, json, summary, data = runDumper(fn, { walk = true, gallery = true, probe = true, keep = true })
	if not T.check(ok and type(data) == "table", "GUI dumper: builds and walks the widget gallery", tostring(json)) then
		local leftover = pg:FindFirstChild("RenderGallery")
		if leftover then
			leftover:Destroy()
		end
		return
	end
	local galleryGui = pg:FindFirstChild("RenderGallery")
	local gallery = entryOf(data, "RenderGallery")
	if not T.check(galleryGui ~= nil and gallery ~= nil, "GUI dumper: the gallery ScreenGui is in the dump") then
		return
	end
	local bad, n, examples = crossCheck(galleryGui, gallery)
	T.check(bad == 0 and n > 60, "GUI dumper: gallery objects and boxes match the live ones (" .. n .. " objects)", table.concat(examples, " | "))
	local byPath = {}
	for _, node in ipairs(flatten(gallery.nodes)) do
		byPath[node.path] = node
	end
	local function node(path)
		return byPath["RenderGallery.Cells." .. path]
	end
	local s = (node("Corner") or {}).s or 1
	local box = node("Corner.Demo.Box")
	T.check(box and close(box.corner, 16 * s) and box.strokes and #box.strokes == 1 and close(box.strokes[1].thickness, 4 * s)
		and box.strokes[1].mode == "Border", "GUI dumper: UICorner 16 -> corner px, Border UIStroke 4 -> thickness px + mode")
	local pill = node("Pill.Demo.Box")
	T.check(pill and close(pill.corner, pill.h / 2), "GUI dumper: CornerRadius (0.5, 0) -> half the short side (a pill)", pill and tostring(pill.corner))
	T.check(node("Pill.Demo.Box.Hidden") == nil and node("Pill.Demo.Box.Hidden.InsideHidden") == nil and (data.hidden or 0) >= 1, "GUI dumper: invisible objects and their subtree are not dumped")
	local grad = node("GradientV.Demo.Box")
	local g = grad and grad.gradient
	T.check(g and g.rot == 90 and #g.colors == 2 and g.colors[1][2] == 255 and g.colors[2][2] == 24 and g.colors[2][4] == 78,
		"GUI dumper: UIGradient rotation and colour keypoints")
	local gt = node("GradientT.Demo.Box")
	T.check(gt and gt.gradient and #gt.gradient.transparency == 2 and gt.gradient.transparency[2][2] == 1, "GUI dumper: UIGradient transparency keypoints")
	T.eq(node("Rotation.Demo.Box") and node("Rotation.Demo.Box").rot, 30, "GUI dumper: Rotation")
	local scaled = node("Scaled.Demo.Box")
	T.check(scaled and scaled.text and scaled.text.scaled and close(scaled.text.maxSize, 28 * s) and close(scaled.text.minSize, 10 * s),
		"GUI dumper: TextScaled with UITextSizeConstraint bounds")
	local holder, scaledText = node("Scale.Demo.Holder"), node("Scale.Demo.Holder.Text")
	T.check(holder and close(holder.s, 1.5 * s) and close(holder.w, 180 * s) and scaledText and close(scaledText.text.size, 30 * s)
		and scaledText.strokes and close(scaledText.strokes[1].thickness, 3 * s) and scaledText.strokes[1].mode == "Contextual",
		"GUI dumper: UIScale 1.5 scales the box, the text size (20 -> 30) and the text stroke (2 -> 3)")
	local wrapped = node("Wrapped.Demo.Box")
	T.check(wrapped and wrapped.pad and close(wrapped.pad[1], 8 * s) and close(wrapped.pad[4], 8 * s) and wrapped.text.wrapped
		and wrapped.text.xa == "Left" and wrapped.text.ya == "Top", "GUI dumper: UIPadding px, TextWrapped and alignment")
	T.eq(node("Truncate.Demo.Box") and node("Truncate.Demo.Box").text.truncate, "AtEnd", "GUI dumper: TextTruncate")
	T.check(node("Rich.Demo.Box") and node("Rich.Demo.Box").text.rich == true, "GUI dumper: RichText flag")
	T.eq(node("Typewriter.Demo.Box") and node("Typewriter.Demo.Box").text.maxGraphemes, 6, "GUI dumper: MaxVisibleGraphemes")
	T.eq(node("Outline.Demo.Box") and node("Outline.Demo.Box").text.font, "FredokaOne", "GUI dumper: the font is dumped by its Enum.Font name")
	local p1, p2, p3 = node("List.Demo.Row.Pill1"), node("List.Demo.Row.Pill2"), node("List.Demo.Row.Pill3")
	T.check(p1 and p2 and p3 and close(p2.x, p1.x + p1.w + 8 * s, 0.05) and close(p3.x, p2.x + p2.w + 8 * s, 0.05) and p3.w > p2.w and p2.w > p1.w,
		"GUI dumper: UIListLayout places AutomaticSize pills left to right with the padding")
	local c1, c2, c4 = node("Grid.Demo.Grid.Cell1"), node("Grid.Demo.Grid.Cell2"), node("Grid.Demo.Grid.Cell4")
	T.check(c1 and c2 and c4 and close(c2.x - c1.x, 66 * s) and close(c4.y - c1.y, 56 * s) and close(c4.x, c1.x), "GUI dumper: UIGridLayout cells (3 per row)")
	local list = node("Scroll.Demo.List")
	T.check(list and list.clip and list.scroll and list.scroll.canvas[2] > list.h and close(list.scroll.position[2], 30) and close(list.scroll.bar, 8 * s),
		"GUI dumper: ScrollingFrame clips, with its canvas size, position and bar")
	T.check(node("Group.Demo.Box") and node("Group.Demo.Box").group and close(node("Group.Demo.Box").group.t, 0.5), "GUI dumper: CanvasGroup transparency")
	local image, viewport = node("Media.Demo.Image"), node("Media.Demo.Viewport")
	T.check(image and image.image and image.image.kind == "Image" and image.image.image:find("1234567", 1, true) ~= nil
		and viewport and viewport.image and viewport.image.kind == "Viewport" and viewport.image.label == "DemoPet",
		"GUI dumper: ImageLabel / ViewportFrame placeholders (asset, model name)")
	local border = node("Border.Demo.Box")
	T.check(border and border.border and close(border.border.size, 3 * s) and border.border.color[2] == 196 and border.corner == nil,
		"GUI dumper: legacy border size and colour")
	T.check(node("ZIndex.Demo.Red") and node("ZIndex.Demo.Red").z == 2 and node("ZIndex.Demo.Blue").z == 1, "GUI dumper: ZIndex")
	local outline = node("Outline.Demo.Box")
	T.check(outline and outline.text.strokeT == 0 and outline.strokes and close(outline.strokes[1].thickness, 3 * s), "GUI dumper: text stroke + Contextual UIStroke")
	T.check(gallery.ignoreInset == false and close(node("Corner").y, galleryGui.Cells.Corner.AbsolutePosition.Y + (Mock.TopInset or 0)),
		"GUI dumper: boxes of a ScreenGui below the top bar include the inset")

	-- 3. the real-font measure hook (render_gui.py passes Pillow's metrics): AutomaticSize and TextBounds follow it,
	-- and the mock's own measure comes back afterwards
	local probe = data.probe
	if T.check(type(probe) == "table" and probe.hooked == true, "GUI dumper: the text measure hooks into the mock's layout engine", probe and tostring(probe.reason)) then
		T.check(close(probe.during, 200, 0.5) and close(probe.bounds, 200, 0.5), "GUI dumper: ...AutomaticSize and TextBounds use the hooked measure (10 chars x 1 em x 20 px)",
			string.format("during %.1f, bounds %.1f", probe.during or -1, probe.bounds or -1))
		T.check(close(probe.after, probe.before) and not close(probe.before, probe.during), "GUI dumper: ...and the mock's measure is restored afterwards",
			string.format("before %.1f, after %.1f", probe.before or -1, probe.after or -1))
	end
	galleryGui:Destroy()
	T.check(pg:FindFirstChild("RenderGallery") == nil and #pg:GetDescendants() == before, "GUI dumper: the gallery is removed without a trace")
	if _G.KC and _G.KC.flushErrors then
		_G.KC.flushErrors("gui dump")
	end
end)

return S
