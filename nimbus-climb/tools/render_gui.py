#!/usr/bin/env python3
"""Offline renders of the game's 2D UI: boot the REAL client (Main.client.lua) in the Roblox mock and draw PlayerGui.

    python3 tools/render_gui.py <scenario> [--size 1920x1080] [-o out.png] [--grid] [--json dump.json]
                                [--touch | --no-touch] [--bg lobby|grey|sky|dark] [--ss 2] [--boxes]
                                [--mark-small [PX]] [--no-chrome] [--no-labels] [--echo] [-v]
    python3 tools/render_gui.py --list

Scenarios (see tools/dump_gui.lua): lobby, title, match[:hit], countdown, party, results,
menu:<Inventory|Pets|Index|Shop|Stats>[:<Tab>], tutorial[:<step>], npc[:<n>], dev, toasts,
portal[:<Id>[:<players>[:<studs>]]] (a portal's world GUIs mirrored flat: the pixel billboard and the eye-level
countdown face as big as it looks from <studs> away), or a .json dump written earlier with --json.

How it works: tools/dump_gui.lua runs inside a lupa Lua world booted like tools/smoke.py boots its client world
(tools/robloxmock.lua, src/ mounted per default.project.json, the viewport set to --size, a touch device when the
smaller screen side is <= 500 px unless --touch / --no-touch), boots Main.client.lua, feeds it the fake server
events the smoke tests use, then dumps every visible GuiObject with its absolute geometry (the mock resolves
UDim2 / AnchorPoint / AutomaticSize / UIListLayout / UIGridLayout / UIPadding / UIScale / UIAspectRatio /
UISizeConstraint). This file passes the mock real font metrics (so AutomaticSize and TextBounds measure text like
the renderer draws it) and draws the dump with Pillow at --ss supersampling: ScreenGuis by DisplayOrder, siblings
by ZIndex (or globally), rounded corners, UIStrokes (border and text), UIGradients, legacy borders, text with
stroke, TextScaled + UITextSizeConstraint, wrapping, truncation, rich-text colours, colour emoji, Rotation,
CanvasGroups, clipping (ClipsDescendants, ScrollingFrames, with scroll bars) and labelled placeholders for
ImageLabels and ViewportFrames, over a backdrop that resembles the lobby (or --bg grey). Roblox's own top bar
and, on touch devices, its thumbstick and jump button are sketched as faint ghosts.

Fonts: Roblox fonts are mapped to installed TTF/OTF files (fc-list): a bold rounded sans is preferred for
FredokaOne / BuilderSans / Gotham (Fredoka, Nunito, Varela Round, ...), then Inter, DejaVu Sans; symbols fall back
to DejaVu / FreeSans, emoji to Noto Color Emoji. `-v` prints the mapping. Glyph shapes differ from Roblox's
fonts, sizes and positions do not.

The report on stdout ends with the smallest on-screen text size (px) and every text under the readability floor
(15 px on screens >= 1000 px tall, 14 px below; ARCHITECTURE_V3.md). --grid renders 1920x1080, 1280x720,
390x844 and 844x390 into one sheet.

Needs: lupa, numpy, Pillow (fontTools optional: exact glyph coverage for the font fallback).
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError as exc:  # pragma: no cover
    sys.exit("render_gui.py needs numpy and Pillow (%s)" % exc)

try:  # optional: exact glyph coverage per font
    from fontTools.ttLib import TTFont
except Exception:  # pragma: no cover
    TTFont = None

GRID_SIZES = [(1920, 1080), (1280, 720), (390, 844), (844, 390)]
SCENARIOS = ["gallery", "lobby", "title", "match", "match:hit", "countdown", "party", "results", "menu:Inventory", "menu:Pets",
             "menu:Index", "menu:Shop", "menu:Stats", "tutorial", "npc", "dev", "toasts", "portal", "portal:Saint:4"]

# ---------------------------------------------------------------------------------------------------
# Lua world (booted the way tools/smoke.py boots its client world)
# ---------------------------------------------------------------------------------------------------
ENGINES = ["luajit21", "luajit20", "lua54", "lua53", "lua55", "lua52"]


def load_engine(preferred=None):
    import importlib

    try:
        import lupa  # noqa: F401
    except ImportError:
        sys.exit("render_gui.py needs lupa:  pip install lupa")
    order = ([preferred] if preferred else []) + [e for e in ENGINES if e != preferred]
    for name in order:
        try:
            return name, importlib.import_module("lupa." + name)
        except Exception:
            continue
    sys.exit("no usable lupa Lua engine found (pip install --upgrade lupa)")


def script_class(filename):
    if filename.endswith(".server.lua") or filename.endswith(".server.luau"):
        return "Script", filename.rsplit(".server.", 1)[0]
    if filename.endswith(".client.lua") or filename.endswith(".client.luau"):
        return "LocalScript", filename.rsplit(".client.", 1)[0]
    if filename.endswith(".lua") or filename.endswith(".luau"):
        return "ModuleScript", filename.rsplit(".", 1)[0]
    return None, None


def fs_node(path, name=None):
    """A file or directory under src/ as a mount spec, like Rojo would sync it."""
    if os.path.isdir(path):
        spec = {"name": name or os.path.basename(path), "class": "Folder", "children": []}
        entries = sorted(os.listdir(path))
        init = next((e for e in entries if e in ("init.lua", "init.server.lua", "init.client.lua")), None)
        for e in entries:
            if e == init or e.startswith(".") or e.endswith(".meta.json"):
                continue
            child = fs_node(os.path.join(path, e))
            if child:
                spec["children"].append(child)
        if init:
            spec["class"] = script_class(init)[0]
            spec["source"] = open(os.path.join(path, init), encoding="utf-8").read()
            spec["path"] = os.path.relpath(os.path.join(path, init), ROOT)
        return spec
    cls, stem = script_class(os.path.basename(path))
    if not cls:
        return None
    return {"name": name or stem, "class": cls, "source": open(path, encoding="utf-8").read(),
            "path": os.path.relpath(path, ROOT), "children": []}


def project_mounts():
    with open(os.path.join(ROOT, "default.project.json"), encoding="utf-8") as fh:
        project = json.load(fh)
    mounts = []

    def walk(node, path):
        for key, value in node.items():
            if key.startswith("$") or not isinstance(value, dict):
                continue
            sub = path + [key]
            if "$path" in value:
                mounts.append(("/".join(sub), os.path.join(ROOT, value["$path"])))
            walk(value, sub)

    walk(project["tree"], [])
    return mounts


class LuaWorld:
    """One booted mock client DataModel with src/ mounted."""

    def __init__(self, touch=False, engine=None, echo=False, measure=None):
        name, module = load_engine(engine)
        self.rt = module.LuaRuntime(unpack_returned_tuples=True, register_eval=False)
        g = self.rt.globals()
        g.MOCK_SRC = open(os.path.join(HERE, "robloxmock.lua"), encoding="utf-8").read()
        self.mock = self.rt.eval(
            "function() local load_ = loadstring or load; local f, e = load_(MOCK_SRC, '=tools/robloxmock.lua'); "
            "if not f then error(e, 0) end; return f() end")()
        g.Mock = self.mock
        with open(os.path.join(HERE, "roblox-api.json"), encoding="utf-8") as fh:
            api = json.load(fh)
        t = self.rt.table_from
        self.mock.Configure(t({
            "creatableClasses": t(api.get("creatableClasses", [])),
            "services": t(api.get("services", [])),
            "options": t({"StrictMembers": False, "Echo": bool(echo), "Watchdog": False,
                          "StepSize": 1.0 / 30, "SliceLimit": 300.0}),
        }))
        self.mock.Boot("client", t({"localName": "SkyClimber", "localUserId": 4242, "touch": bool(touch)}))
        roots = {}
        for inst_path, directory in project_mounts():
            if not os.path.isdir(directory):
                continue
            parent = self.mock.GetPath("/".join(inst_path.split("/")[:-1]), "Folder")
            self.mock.Mount(parent, self.to_lua(fs_node(directory, inst_path.split("/")[-1])))
            roots[os.path.basename(directory)] = inst_path
        g.ROOTS = t(roots)
        if measure is not None:
            g.GUI_MEASURE = measure
        self.engine = name

    def to_lua(self, value):
        if isinstance(value, dict):
            return self.rt.table_from({k: self.to_lua(v) for k, v in value.items()})
        if isinstance(value, (list, tuple)):
            return self.rt.table_from([self.to_lua(v) for v in value])
        return value

    def script_errors(self):
        out = []
        errors = self.mock.Errors
        n = len(errors) if errors is not None else 0
        for i in range(1, n + 1):
            out.append(str(errors[i]["msg"]))
        return out

    def warnings(self):
        out = []
        lines = self.mock.Output
        n = len(lines) if lines is not None else 0
        for i in range(1, n + 1):
            if lines[i]["kind"] == "warn":
                out.append(str(lines[i]["text"]))
        return out

    def dump(self, scenario, width, height, touch, out=None):
        g = self.rt.globals()
        spec = {"scenario": scenario, "width": width, "height": height, "touch": bool(touch)}
        if out:
            spec["out"] = out
        g.DUMP = self.rt.table_from(spec)
        g.DUMP_SRC = open(os.path.join(HERE, "dump_gui.lua"), encoding="utf-8").read()
        runner = self.rt.eval(
            "function() local load_ = loadstring or load; local f, e = load_(DUMP_SRC, '=tools/dump_gui.lua'); "
            "if not f then error(e, 0) end; return f() end")
        result = runner()
        text = result[0] if isinstance(result, tuple) else result
        if isinstance(text, bytes):
            text = text.decode("utf-8")
        return json.loads(text)


def is_touch(width, height, flag):
    if flag is not None:
        return flag
    return min(width, height) <= 500


def dump_scenario(scenario, width, height, touch, fonts, json_out=None, engine=None, echo=False, verbose=False):
    world = LuaWorld(touch, engine, echo, fonts.measure_em)
    try:
        data = world.dump(scenario, width, height, touch, json_out)
    except Exception as exc:  # a Lua error: its message plus the game's own errors
        msg = str(exc).split("\nstack traceback:")[0].replace("dump_gui: ", "")
        extra = world.script_errors()
        if extra:
            msg += "\nscript errors:\n  " + "\n  ".join(e.splitlines()[0] for e in extra[:8])
        raise SystemExit("dump failed (%s at %dx%d): %s" % (scenario, width, height, msg))
    data["errors"] = world.script_errors()
    data["warnings"] = world.warnings()
    if json_out:  # keep the errors in the file too
        with open(json_out, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
    return data


# ---------------------------------------------------------------------------------------------------
# Fonts: Roblox font names -> installed files, glyph fallback, colour emoji, metrics
# ---------------------------------------------------------------------------------------------------
HEAVY_ROUNDED = [("Fredoka One", None), ("Fredoka", "Bold"), ("Fredoka", "SemiBold"), ("Baloo 2", "ExtraBold"),
                 ("Nunito", "Black"), ("Nunito", "ExtraBold"), ("Varela Round", None), ("M PLUS Rounded 1c", "ExtraBold"),
                 ("Quicksand", "Bold"), ("Inter", "ExtraBold"), ("Montserrat", "ExtraBold"), ("DejaVu Sans", "Bold"),
                 ("Liberation Sans", "Bold"), ("FreeSans", "Bold")]
BLACK_ROUNDED = [("Nunito", "Black"), ("Fredoka", "Bold"), ("M PLUS Rounded 1c", "Black"), ("Baloo 2", "ExtraBold"),
                 ("Inter", "Black"), ("Montserrat", "Black"), ("DejaVu Sans", "Bold"), ("Liberation Sans", "Bold"),
                 ("FreeSans", "Bold")]
BOLD_ROUNDED = [("Nunito", "ExtraBold"), ("Nunito", "Bold"), ("Varela Round", None), ("Fredoka", "SemiBold"),
                ("M PLUS Rounded 1c", "Bold"), ("Quicksand", "Bold"), ("Inter", "Bold"), ("Montserrat", "Bold"),
                ("DejaVu Sans", "Bold"), ("Liberation Sans", "Bold"), ("FreeSans", "Bold")]
MEDIUM = [("Nunito", "SemiBold"), ("Inter", "SemiBold"), ("Inter", "Medium"), ("DejaVu Sans", "Book"),
          ("Liberation Sans", "Regular"), ("FreeSans", None)]
REGULAR = [("Liberation Sans", "Regular"), ("Inter", "Regular"), ("DejaVu Sans", "Book"), ("FreeSans", None)]
SANS_BOLD = [("Liberation Sans", "Bold"), ("Inter", "Bold"), ("DejaVu Sans", "Bold"), ("FreeSans", "Bold")]
SERIF = [("Caladea", "Bold Italic"), ("DejaVu Serif", "Bold"), ("Liberation Serif", "Bold"), ("FreeSerif", "Bold")]
MONO = [("DejaVu Sans Mono", "Book"), ("Liberation Mono", "Regular"), ("FreeMono", None)]
MONO_BOLD = [("DejaVu Sans Mono", "Bold"), ("Liberation Mono", "Bold"), ("FreeMono", "Bold")]
SYMBOL_FALLBACKS = [("DejaVu Sans", "Bold"), ("DejaVu Sans", "Book"), ("FreeSans", "Bold"), ("FreeSerif", None),
                    ("Unifont", None)]

ROBLOX_FONTS = {
    "fredokaone": HEAVY_ROUNDED, "bangers": HEAVY_ROUNDED, "cartoon": HEAVY_ROUNDED, "permanentmarker": HEAVY_ROUNDED,
    "luckiestguy": BLACK_ROUNDED, "gothamblack": BLACK_ROUNDED, "buildersansextrabold": HEAVY_ROUNDED,
    "gothambold": BOLD_ROUNDED, "gothamsemibold": BOLD_ROUNDED, "gothamssm": BOLD_ROUNDED, "buildersansbold": BOLD_ROUNDED,
    "gothammedium": MEDIUM, "gotham": MEDIUM, "buildersans": MEDIUM, "buildersansmedium": MEDIUM, "nunito": MEDIUM,
    "montserrat": MEDIUM, "sourcesans": REGULAR, "sourcesanslight": REGULAR, "sourcesansitalic": REGULAR,
    "arial": REGULAR, "legacy": REGULAR, "roboto": REGULAR, "ubuntu": REGULAR, "sourcesansbold": SANS_BOLD,
    "sourcesanssemibold": SANS_BOLD, "arialbold": SANS_BOLD, "highway": SANS_BOLD, "montserratbold": SANS_BOLD,
    "montserratblack": BLACK_ROUNDED, "fondamento": SERIF, "antique": SERIF, "garamond": SERIF, "merriweather": SERIF,
    "code": MONO, "robotomono": MONO, "arcade": MONO_BOLD, "sciFi": MONO_BOLD,
}
EMOJI_SIZE = 109  # Noto Color Emoji is a bitmap font with one strike
# code points below U+1F000 that default to emoji presentation (the rest of the BMP draws as text glyphs)
EMOJI_BMP = set([0x231A, 0x231B, 0x23F0, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615, 0x267F, 0x2693, 0x26A1, 0x26AA,
                 0x26AB, 0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26FA,
                 0x26FD, 0x2705, 0x270A, 0x270B, 0x2728, 0x274C, 0x274E, 0x2753, 0x2754, 0x2755, 0x2757, 0x2795,
                 0x2796, 0x2797, 0x27B0, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55]
                + list(range(0x23E9, 0x23ED)) + list(range(0x2648, 0x2654)))
ZERO_WIDTH = set([0x200B, 0x200C, 0x200D, 0xFE0E, 0xFE0F])
FONT_DIRS = ["/usr/share/fonts", "/usr/local/share/fonts", os.path.expanduser("~/.fonts"),
             os.path.expanduser("~/.local/share/fonts"), "/Library/Fonts", "/System/Library/Fonts",
             "C:\\Windows\\Fonts"]


def discover_fonts():
    """Installed fonts: [(path, [families lower], [styles lower], index)], from fc-list or by scanning font dirs."""
    out = []
    try:
        proc = subprocess.run(["fc-list", "--format", "%{file}\t%{family}\t%{style}\t%{index}\n"],
                              capture_output=True, text=True, timeout=20)
        for line in proc.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) < 4 or not parts[0]:
                continue
            fams = [f.strip().lower() for f in parts[1].split(",") if f.strip()]
            styles = [s.strip().lower() for s in parts[2].split(",") if s.strip()]
            try:
                index = int(parts[3] or 0)
            except ValueError:
                index = 0
            out.append((parts[0], fams, styles, index))
    except Exception:
        out = []
    if out:
        return out
    for base in FONT_DIRS:
        if not os.path.isdir(base):
            continue
        for dirpath, _, files in os.walk(base):
            for f in files:
                if not f.lower().endswith((".ttf", ".otf")):
                    continue
                path = os.path.join(dirpath, f)
                try:
                    fam, style = ImageFont.truetype(path, 12).getname()
                except Exception:
                    continue
                out.append((path, [str(fam).lower()], [str(style).lower()], 0))
    return out


class FontBook:
    def __init__(self):
        self.installed = discover_fonts()
        self.chains = {}
        self.cmaps = {}
        self.fonts = {}
        self.em_cache = {}
        self.emoji_cache = {}
        self.symbols = [p for p in (self.find(f, s) for f, s in SYMBOL_FALLBACKS) if p]
        self.emoji_path = self.find("Noto Color Emoji", None)
        self.tool_path = self.find("DejaVu Sans", "Bold") or self.find("Inter", "Bold")
        self.emoji_font = None
        if self.emoji_path:
            try:
                self.emoji_font = ImageFont.truetype(self.emoji_path[0], EMOJI_SIZE, index=self.emoji_path[1])
            except Exception:
                self.emoji_font = None

    def find(self, family, style):
        family = family.lower()
        best = None
        for path, fams, styles, index in self.installed:
            if family not in fams:
                continue
            first = styles[0] if styles else "regular"
            if style is None:
                if "italic" in first or "oblique" in first:
                    continue
                score = 0 if first in ("regular", "book", "normal") else 1
            elif first == style.lower():
                score = 0
            else:
                continue
            if index:
                score += 2
            if best is None or score < best[0]:
                best = (score, path, index)
        return (best[1], best[2]) if best else None

    def chain(self, name):
        """[(path, index)...] for a Roblox font name: the first installed candidate, then the symbol fallbacks."""
        key = re.sub(r"[^a-z0-9]", "", str(name).lower())
        if key in self.chains:
            return self.chains[key]
        candidates = ROBLOX_FONTS.get(key)
        if candidates is None:
            candidates = BOLD_ROUNDED
        primary = None
        for fam, style in candidates:
            primary = self.find(fam, style)
            if primary:
                break
        out = []
        for p in ([primary] if primary else []) + self.symbols:
            if p not in out:
                out.append(p)
        self.chains[key] = out
        return out

    def mapping(self, names):
        lines = []
        for n in names:
            ch = self.chain(n)
            lines.append("  %-20s -> %s" % (n, os.path.basename(ch[0][0]) if ch else "Pillow default"))
        return lines

    def cmap(self, ref):
        if ref in self.cmaps:
            return self.cmaps[ref]
        cps = None
        if TTFont is not None:
            try:
                tt = TTFont(ref[0], fontNumber=ref[1], lazy=True)
                cps = set(tt.getBestCmap() or {})
                tt.close()
            except Exception:
                cps = None
        self.cmaps[ref] = cps
        return cps

    def has(self, ref, cp):
        cps = self.cmap(ref)
        if cps is None:  # no fontTools: assume the primary covers Latin, the fallbacks the rest
            return cp < 0x250 or ref in self.symbols
        return cp in cps

    def font(self, ref, size):
        key = (ref, round(size, 2))
        f = self.fonts.get(key)
        if f is None:
            try:
                f = ImageFont.truetype(ref[0], max(1.0, size), index=ref[1], layout_engine=ImageFont.Layout.BASIC)
            except Exception:
                try:
                    f = ImageFont.load_default(size=max(1.0, size))
                except TypeError:
                    f = ImageFont.load_default()
            self.fonts[key] = f
        return f

    def is_emoji(self, cp, nxt):
        if self.emoji_font is None or not self.has(self.emoji_path, cp):
            return False
        return cp >= 0x1F000 or cp in EMOJI_BMP or nxt == 0xFE0F

    def runs(self, name, text):
        """Splits text into [(ref | 'emoji', substring)] by glyph coverage."""
        chain = self.chain(name)
        out = []
        for i, ch in enumerate(text):
            cp = ord(ch)
            if cp in ZERO_WIDTH:
                continue
            nxt = ord(text[i + 1]) if i + 1 < len(text) else 0
            if self.is_emoji(cp, nxt):
                ref = "emoji"
            else:
                ref = chain[0] if chain else None
                if cp > 0x7E or ch == "\t":
                    for cand in chain:
                        if self.has(cand, cp):
                            ref = cand
                            break
            if out and out[-1][0] == ref:
                out[-1] = (ref, out[-1][1] + ch)
            else:
                out.append((ref, ch))
        return out

    def run_em(self, ref, s):
        key = (ref, s)
        w = self.em_cache.get(key)
        if w is None:
            s2 = s.replace("\t", "    ")
            if ref == "emoji":
                w = self.emoji_font.getlength(s2) / EMOJI_SIZE * 0.92
            elif ref is None:
                w = 0.55 * len(s2)
            else:
                w = self.font(ref, 1000).getlength(s2) / 1000.0
            self.em_cache[key] = w
        return w

    def measure_em(self, name, text):
        """Advance width of text in em (the GUI_MEASURE callback of dump_gui.lua)."""
        if isinstance(name, bytes):
            name = name.decode("utf-8", "replace")
        if isinstance(text, bytes):
            text = text.decode("utf-8", "replace")
        key = (name, text)
        w = self.em_cache.get(key)
        if w is None:
            w = sum(self.run_em(ref, s) for ref, s in self.runs(name, text))
            self.em_cache[key] = w
        return w

    def width(self, name, text, size):
        return self.measure_em(name, text) * size

    def metrics(self, name, size):
        chain = self.chain(name)
        if not chain:
            return size * 0.8, size * 0.2
        asc, desc = self.font(chain[0], 1000).getmetrics()
        return asc / 1000.0 * size, desc / 1000.0 * size

    def emoji_image(self, s, size):
        key = (s, round(size, 1))
        img = self.emoji_cache.get(key)
        if img is None:
            f = self.emoji_font
            asc, desc = f.getmetrics()
            w = int(math.ceil(f.getlength(s))) + 4
            big = Image.new("RGBA", (w, asc + desc + 4), (0, 0, 0, 0))
            ImageDraw.Draw(big).text((2, asc + 2), s, font=f, embedded_color=True, anchor="ls")
            k = size * 0.92 / EMOJI_SIZE
            img = big.resize((max(1, int(round(big.width * k))), max(1, int(round(big.height * k)))), Image.LANCZOS)
            self.emoji_cache[key] = (img, (asc + 2) * k, 2 * k)
            img = self.emoji_cache[key]
        return img


# ---------------------------------------------------------------------------------------------------
# Text layout (rich text, wrapping, TextScaled, truncation)
# ---------------------------------------------------------------------------------------------------
ENTITIES = {"lt": "<", "gt": ">", "amp": "&", "quot": '"', "apos": "'"}


def parse_color(value):
    value = value.strip()
    m = re.match(r"^#?([0-9a-fA-F]{6})$", value)
    if m:
        h = m.group(1)
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    m = re.match(r"^rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$", value)
    if m:
        return tuple(min(255, int(m.group(i))) for i in (1, 2, 3))
    return None


def styled_chars(text, rich):
    """[(char, colour | None)] with <font color> / <br/> / entities resolved (other tags dropped)."""
    if not rich:
        return [(c, None) for c in text]
    out = []
    stack = []
    pos = 0
    for m in re.finditer(r"<[^>]*>|&(\w+);", text):
        for c in text[pos:m.start()]:
            out.append((c, stack[-1] if stack else None))
        token = m.group(0)
        if token.startswith("&"):
            out.append((ENTITIES.get(m.group(1), token), stack[-1] if stack else None))
        else:
            tag = token[1:-1].strip()
            low = tag.lower()
            if re.match(r"^br\s*/?$", low):
                out.append(("\n", None))
            elif low.startswith("font"):
                cm = re.search(r"color\s*=\s*[\"']([^\"']+)[\"']", tag, re.I)
                stack.append(parse_color(cm.group(1)) if cm else (stack[-1] if stack else None))
            elif low.startswith("/font") and stack:
                stack.pop()
        pos = m.end()
    for c in text[pos:]:
        out.append((c, stack[-1] if stack else None))
    return out


def join(chars):
    return "".join(c for c, _ in chars)


def wrap_lines(fonts, font, chars, size, limit):
    """Greedy word wrap on spaces like Roblox (long words break). limit None = no wrapping."""
    lines = []
    para = []
    paragraphs = []
    for item in chars:
        if item[0] == "\n":
            paragraphs.append(para)
            para = []
        else:
            para.append(item)
    paragraphs.append(para)
    for para in paragraphs:
        if limit is None or fonts.width(font, join(para), size) <= limit + 0.01:
            lines.append(para)
            continue
        words, cur = [], []
        for item in para:
            if item[0] == " ":
                if cur:
                    words.append(cur)
                cur = []
            else:
                cur.append(item)
        if cur:
            words.append(cur)
        line = []
        for word in words:
            candidate = line + [(" ", line[-1][1])] + word if line else word
            if fonts.width(font, join(candidate), size) <= limit + 0.01:
                line = candidate
                continue
            if line:
                lines.append(line)
                line = []
            if fonts.width(font, join(word), size) <= limit + 0.01:
                line = word
                continue
            piece = []  # a word longer than the line: break it
            for item in word:
                if piece and fonts.width(font, join(piece + [item]), size) > limit + 0.01:
                    lines.append(piece)
                    piece = []
                piece.append(item)
            line = piece
        lines.append(line)
    return lines


def text_fits(fonts, font, chars, size, w, h, line_height):
    lines = wrap_lines(fonts, font, chars, size, w)
    if len(lines) * size * line_height > h + 0.01:
        return False
    return all(fonts.width(font, join(l), size) <= w + 0.01 for l in lines)


def layout_text(fonts, tx, aw, ah):
    """-> (size px, [lines of (char, colour)]) for a text node inside an area of aw x ah px."""
    chars = styled_chars(tx.get("text", ""), tx.get("rich"))
    font = tx.get("font", "SourceSans")
    lh = float(tx.get("lineHeight", 1) or 1)
    size = float(tx.get("size", 14))
    if tx.get("scaled"):
        lo = max(1, int(math.floor(float(tx.get("minSize", 1)))))
        hi = max(lo, int(math.floor(float(tx.get("maxSize", 100)))))
        best = lo
        a, b = lo, hi
        while a <= b:  # largest size that fits (Roblox searches whole pixels)
            mid = (a + b) // 2
            if text_fits(fonts, font, chars, mid, aw, ah, lh):
                best = mid
                a = mid + 1
            else:
                b = mid - 1
        size = float(best)
    wrap = bool(tx.get("wrapped") or tx.get("scaled"))
    lines = wrap_lines(fonts, font, chars, size, aw if wrap else None)
    trunc = tx.get("truncate", "None")
    if trunc and trunc != "None":
        ell = "\u2026"
        if wrap:
            fit = max(1, int(math.floor((ah + 0.01) / (size * lh))))
            if len(lines) > fit:
                lines = lines[:fit]
                last = lines[-1]
                colour = last[-1][1] if last else None
                while last and fonts.width(font, join(last) + ell, size) > aw + 0.01:
                    last = last[:-1]
                lines[-1] = last + [(ell, colour)]
        else:
            out = []
            for line in lines:
                if fonts.width(font, join(line), size) > aw + 0.01:
                    colour = line[-1][1] if line else None
                    while line and fonts.width(font, join(line) + ell, size) > aw + 0.01:
                        line = line[:-1]
                    line = line + [(ell, colour)]
                out.append(line)
            lines = out
    return size, lines


# ---------------------------------------------------------------------------------------------------
# Paint helpers (all coordinates in supersampled canvas pixels)
# ---------------------------------------------------------------------------------------------------
def rr(draw, x0, y0, x1, y1, r, fill):
    if x1 - x0 < 0.5 or y1 - y0 < 0.5:
        return
    r = max(0.0, min(r, (x1 - x0) / 2.0, (y1 - y0) / 2.0))
    box = [x0, y0, x1 - 1, y1 - 1]
    if box[2] < box[0] or box[3] < box[1]:
        return
    if r < 0.75:
        draw.rectangle(box, fill=fill)
    else:
        draw.rounded_rectangle(box, radius=r, fill=fill)


def intersect(a, b):
    if a is None:
        return b
    if b is None:
        return a
    r = (max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3]))
    return r


def gradient_field(g, rect, px0, py0, pw, ph):
    """UIGradient over rect, sampled on a pw x ph patch at (px0, py0): (rgb 0..255 float [h,w,3], alpha [h,w])."""
    x0, y0, x1, y1 = rect
    rw, rh = max(x1 - x0, 1e-6), max(y1 - y0, 1e-6)
    off = g.get("offset") or [0, 0]
    xs = (np.arange(pw, dtype=np.float32) + px0 + 0.5 - x0) / rw - float(off[0]) - 0.5
    ys = (np.arange(ph, dtype=np.float32) + py0 + 0.5 - y0) / rh - float(off[1]) - 0.5
    th = math.radians(float(g.get("rot", 0) or 0))
    t = np.clip(0.5 + xs[None, :] * math.cos(th) + ys[:, None] * math.sin(th), 0.0, 1.0)
    cols = sorted(g.get("colors") or [[0, 255, 255, 255], [1, 255, 255, 255]], key=lambda k: k[0])
    times = [c[0] for c in cols]
    rgb = np.stack([np.interp(t, times, [c[i] for c in cols]) for i in (1, 2, 3)], axis=-1)
    tr = sorted(g.get("transparency") or [[0, 0], [1, 0]], key=lambda k: k[0])
    alpha = 1.0 - np.interp(t, [k[0] for k in tr], [k[1] for k in tr])
    return rgb.astype(np.float32), alpha.astype(np.float32)


class Layer:
    """An RGBA image whose top-left sits at (ox, oy) in canvas pixels."""

    def __init__(self, img, ox=0, oy=0):
        self.img, self.ox, self.oy = img, ox, oy


# ---------------------------------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------------------------------
class GuiRenderer:
    def __init__(self, dump, fonts, ss=2, bg="lobby", chrome=True, labels=True, boxes=False, mark_small=None):
        self.dump = dump
        self.fonts = fonts
        self.ss = max(1, int(ss))
        self.W, self.H = int(dump["viewport"][0]), int(dump["viewport"][1])
        self.bg = bg
        self.chrome = chrome
        self.labels = labels
        self.boxes = boxes
        self.mark_small = mark_small
        self.texts = []
        self.drawn = 0
        self.box_list = []

    # -- geometry -----------------------------------------------------------------------------------
    def rect(self, n):
        s = self.ss
        return (n["x"] * s, n["y"] * s, (n["x"] + n["w"]) * s, (n["y"] + n["h"]) * s)

    def composite(self, layer, patch, x0, y0, clip):
        """alpha-composites patch (canvas coords x0, y0) onto layer, inside clip (canvas rect) and the layer."""
        lx0, ly0 = layer.ox, layer.oy
        lx1, ly1 = lx0 + layer.img.width, ly0 + layer.img.height
        bx0, by0 = int(x0), int(y0)
        bx1, by1 = bx0 + patch.width, by0 + patch.height
        ix0, iy0, ix1, iy1 = max(bx0, lx0), max(by0, ly0), min(bx1, lx1), min(by1, ly1)
        if clip is not None:
            ix0, iy0 = max(ix0, int(math.floor(clip[0]))), max(iy0, int(math.floor(clip[1])))
            ix1, iy1 = min(ix1, int(math.ceil(clip[2]))), min(iy1, int(math.ceil(clip[3])))
        if ix1 <= ix0 or iy1 <= iy0:
            return
        crop = patch.crop((ix0 - bx0, iy0 - by0, ix1 - bx0, iy1 - by0))
        layer.img.alpha_composite(crop, dest=(ix0 - lx0, iy0 - ly0))

    @staticmethod
    def with_alpha(img, factor):
        if factor >= 0.999:
            return img
        a = img.getchannel("A").point(lambda v: int(v * max(0.0, factor) + 0.5))
        img.putalpha(a)
        return img

    def fill_patch(self, mask, px0, py0, color, alpha, gradient=None, rect=None):
        """RGBA patch from an L mask: colour (or colour x gradient), opacity alpha."""
        pw, ph = mask.size
        if gradient is None:
            patch = Image.new("RGBA", (pw, ph), tuple(int(c) for c in color) + (255,))
            patch.putalpha(mask.point(lambda v: int(v * alpha + 0.5)) if alpha < 0.999 else mask)
            return patch
        grgb, galpha = gradient_field(gradient, rect, px0, py0, pw, ph)
        rgb = grgb * (np.array(color, dtype=np.float32) / 255.0)
        a = np.asarray(mask, dtype=np.float32) * galpha * alpha
        arr = np.dstack([np.clip(rgb, 0, 255), np.clip(a, 0, 255)]).astype(np.uint8)
        return Image.fromarray(arr, "RGBA")

    # -- one GuiObject ------------------------------------------------------------------------------
    def paint(self, n, layer, clip):
        s = self.ss
        x0, y0, x1, y1 = self.rect(n)
        if (x1 - x0 <= 0 or y1 - y0 <= 0) and not n.get("text"):
            return
        self.drawn += 1
        self.box_list.append((x0, y0, x1, y1, n))
        r = float(n.get("corner") or 0) * s
        has_corner = n.get("corner") is not None
        bgT = float(n.get("bgT", 0))
        text_node = n.get("text") is not None
        strokes = n.get("strokes") or []
        box_strokes = [k for k in strokes if not (text_node and k.get("mode", "Contextual") == "Contextual")]
        text_strokes = [k for k in strokes if text_node and k.get("mode", "Contextual") == "Contextual"]
        grad = n.get("gradient")

        # background
        if bgT < 0.995 and x1 > x0 and y1 > y0:
            px0, py0 = int(math.floor(x0)), int(math.floor(y0))
            pw, ph = int(math.ceil(x1)) - px0, int(math.ceil(y1)) - py0
            mask = Image.new("L", (pw, ph), 0)
            rr(ImageDraw.Draw(mask), x0 - px0, y0 - py0, x1 - px0, y1 - py0, r, 255)
            patch = self.fill_patch(mask, px0, py0, n["bg"], 1.0 - bgT, grad, (x0, y0, x1, y1))
            self.composite(layer, patch, px0, py0, clip)
        # legacy border (drawn by Roblox only without a UICorner and with a visible background)
        border = n.get("border")
        if border and not has_corner and bgT < 0.995:
            t = float(border["size"]) * s
            mode = border.get("mode", "Outline")
            if mode == "Middle":
                o, i = t / 2.0, t / 2.0
            elif mode == "Inset":
                o, i = 0.0, t
            else:
                o, i = t, 0.0
            self.ring(layer, clip, x0, y0, x1, y1, 0.0, o, i, border["color"], 1.0 - bgT, None, "Miter")
        # image / viewport placeholder
        if n.get("image"):
            self.placeholder(n, layer, clip, x0, y0, x1, y1, r)
        # UIStroke around the box
        for k in box_strokes:
            t = float(k.get("thickness", 1)) * s
            if t <= 0 or float(k.get("t", 0)) >= 0.995:
                continue
            pos = k.get("position") or "Outer"
            if pos == "Center":
                o, i = t / 2.0, t / 2.0
            elif pos == "Inner":
                o, i = 0.0, t
            else:
                o, i = t, 0.0
            self.ring(layer, clip, x0, y0, x1, y1, r, o, i, k["color"], 1.0 - float(k.get("t", 0)), k.get("gradient"),
                      k.get("join") or "Round")
        if text_node:
            self.paint_text(n, layer, clip, text_strokes)

    def ring(self, layer, clip, x0, y0, x1, y1, r, out, inn, color, alpha, gradient, join):
        if out + inn <= 0:
            return
        ox0, oy0, ox1, oy1 = x0 - out, y0 - out, x1 + out, y1 + out
        px0, py0 = int(math.floor(ox0)) - 1, int(math.floor(oy0)) - 1
        pw, ph = int(math.ceil(ox1)) - px0 + 1, int(math.ceil(oy1)) - py0 + 1
        if pw <= 0 or ph <= 0:
            return
        mask = Image.new("L", (pw, ph), 0)
        d = ImageDraw.Draw(mask)
        r_out = r + out if (r > 0 or join == "Round") else r
        rr(d, ox0 - px0, oy0 - py0, ox1 - px0, oy1 - py0, r_out, 255)
        rr(d, x0 + inn - px0, y0 + inn - py0, x1 - inn - px0, y1 - inn - py0, max(0.0, r - inn), 0)
        patch = self.fill_patch(mask, px0, py0, color, alpha, gradient, (ox0, oy0, ox1, oy1))
        self.composite(layer, patch, px0, py0, clip)

    def label(self, layer, clip, cx, cy, text, max_w, color=(255, 255, 255), back=(20, 26, 50, 170), size_px=None):
        """A small annotation pill of the tool (not game text: never counted as on-screen text)."""
        if not self.labels or not text:
            return
        size = (size_px or max(8.0, min(12.0, max_w / self.ss / 8.0))) * self.ss
        f = self.fonts.font(self.fonts.tool_path, size) if self.fonts.tool_path else ImageFont.load_default()
        pad = 3 * self.ss
        room = max_w - 2 * pad - 2 * self.ss
        tw = f.getlength(text)
        while tw > room and len(text) > 4:  # stay inside the placeholder
            text = text[:-2] + "\u2026"
            tw = f.getlength(text)
        if tw > room:
            return
        w, h = int(tw + 2 * pad), int(size + 2 * pad)
        patch = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(patch)
        rr(d, 0, 0, w, h, h / 2.0, back)
        d.text((w / 2.0, h / 2.0), text, font=f, fill=color + (235,), anchor="mm")
        self.composite(layer, patch, cx - w / 2.0, cy - h / 2.0, clip)

    def placeholder(self, n, layer, clip, x0, y0, x1, y1, r):
        im = n["image"]
        kind = im.get("kind", "Image")
        alpha = 1.0 - float(im.get("t", 0))
        tint = np.array(im.get("color", [255, 255, 255]), dtype=np.float32) / 255.0
        if (kind == "Image" and not im.get("image")) or alpha <= 0.01 or x1 - x0 < 1 or y1 - y0 < 1:
            return
        px0, py0 = int(math.floor(x0)), int(math.floor(y0))
        pw, ph = int(math.ceil(x1)) - px0, int(math.ceil(y1)) - py0
        mask = Image.new("L", (pw, ph), 0)
        rr(ImageDraw.Draw(mask), x0 - px0, y0 - py0, x1 - px0, y1 - py0, r, 255)
        yy, xx = np.mgrid[0:ph, 0:pw].astype(np.float32)
        if kind == "Viewport":
            # a soft blob where the 3D model sits (black for silhouettes: ImageColor3 tints it)
            cx, cy = (x0 + x1) / 2.0 - px0, (y0 + y1) / 2.0 - py0 + (y1 - y0) * 0.04
            rx, ry = (x1 - x0) * 0.30, (y1 - y0) * 0.33
            dist = ((xx - cx) / max(rx, 1)) ** 2 + ((yy - cy) / max(ry, 1)) ** 2
            shade = np.clip(1.15 - dist, 0, 1) ** 0.6
            base = np.array([196, 206, 232], dtype=np.float32) * tint
            light = base * (0.72 + 0.28 * np.clip(1.0 - (yy - cy + ry) / max(2 * ry, 1), 0, 1))[..., None]
            a = np.asarray(mask, dtype=np.float32) * shade * 0.9 * alpha
            arr = np.dstack([np.clip(light, 0, 255), np.clip(a, 0, 255)]).astype(np.uint8)
            self.composite(layer, Image.fromarray(arr, "RGBA"), px0, py0, clip)
            caption = "3D " + (im.get("label") or "viewport")
        else:
            stripe = (((xx + yy) // (6 * self.ss)) % 2).astype(np.float32)
            base = (np.array([214, 220, 232], dtype=np.float32) + stripe[..., None] * 22.0) * tint
            a = np.asarray(mask, dtype=np.float32) * alpha
            arr = np.dstack([np.clip(base, 0, 255), np.clip(a, 0, 255)]).astype(np.uint8)
            self.composite(layer, Image.fromarray(arr, "RGBA"), px0, py0, clip)
            src = str(im.get("image", ""))
            m = re.search(r"(\d{5,})", src)
            caption = "image " + (m.group(1)[:6] + "\u2026" if m else os.path.basename(src)[:14])
        if x1 - x0 >= 64 * self.ss and y1 - y0 >= 28 * self.ss:
            self.label(layer, clip, (x0 + x1) / 2.0, (y0 + y1) / 2.0, caption, x1 - x0)

    # -- text ---------------------------------------------------------------------------------------
    def paint_text(self, n, layer, clip, text_strokes):
        tx = n["text"]
        raw = tx.get("text", "")
        tT = float(tx.get("t", 0))
        if not str(raw).strip() or tT >= 0.99:
            return
        pad = n.get("pad") or [0, 0, 0, 0]
        ax, ay = n["x"] + pad[0], n["y"] + pad[2]
        aw, ah = max(0.0, n["w"] - pad[0] - pad[1]), max(0.0, n["h"] - pad[2] - pad[3])
        font = tx.get("font", "SourceSans")
        size, lines = layout_text(self.fonts, tx, aw, ah)
        lh = float(tx.get("lineHeight", 1) or 1)
        step = size * lh
        total = step * len(lines)
        ya = tx.get("ya", "Center")
        top = ay if ya == "Top" else (ay + ah - total if ya == "Bottom" else ay + (ah - total) / 2.0)
        xa = tx.get("xa", "Center")
        asc, desc = self.fonts.metrics(font, size)
        placed = []
        for i, line in enumerate(lines):
            lw = self.fonts.width(font, join(line), size)
            lx = ax if xa == "Left" else (ax + aw - lw if xa == "Right" else ax + (aw - lw) / 2.0)
            centre = top + (i + 0.5) * step
            placed.append((lx, centre + (asc - desc) / 2.0, line, lw))
        # what the player sees: the drawn text block, clipped by ancestors and the screen
        s = self.ss
        bx0 = min(p[0] for p in placed) if placed else ax
        bx1 = max(p[0] + p[3] for p in placed) if placed else ax
        limit = int(tx.get("maxGraphemes", -1))
        on_screen = limit != 0  # a typewriter at 0 shows nothing yet
        vis = intersect(clip, (0, 0, self.W * s, self.H * s))
        if vis is not None and on_screen:
            on_screen = bx1 * s > vis[0] and bx0 * s < vis[2] and (top + total) * s > vis[1] and top * s < vis[3]
        self.texts.append({"size": size, "path": n.get("path", ""), "text": re.sub(r"<[^>]*>", "", raw).strip(),
                           "scaled": bool(tx.get("scaled")), "on_screen": on_screen,
                           "rect": (bx0, top, bx1, top + total)})
        # supersampled patch around the text block
        stroke_w = 0.0
        stroke_col, stroke_a = (0, 0, 0), 0.0
        if text_strokes:
            k = text_strokes[0]
            stroke_w = float(k.get("thickness", 1))
            stroke_col = tuple(k["color"])
            stroke_a = (1.0 - float(k.get("t", 0))) * (1.0 - tT)
        elif float(tx.get("strokeT", 1)) < 0.995:
            stroke_w = 1.0
            stroke_col = tuple(tx.get("strokeColor", [0, 0, 0]))
            stroke_a = (1.0 - float(tx.get("strokeT", 1))) * (1.0 - tT)
        margin = (stroke_w + size * 0.6 + 4) * s
        px0 = int(math.floor(bx0 * s - margin))
        py0 = int(math.floor(top * s - margin))
        pw = int(math.ceil((bx1 - bx0) * s + 2 * margin))
        ph = int(math.ceil(total * s + 2 * margin))
        if pw <= 0 or ph <= 0 or pw * ph > 60000000:
            return
        fill = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
        stroke = Image.new("RGBA", (pw, ph), (0, 0, 0, 0)) if stroke_a > 0.003 and stroke_w > 0 else None
        df = ImageDraw.Draw(fill)
        ds = ImageDraw.Draw(stroke) if stroke is not None else None
        sw = max(1, int(round(stroke_w * s)))
        base_col = tuple(tx.get("color", [255, 255, 255]))
        shown = 0
        for lx, base, line, _ in placed:
            x = lx
            for ch_run in self.colour_runs(line):
                colour, string = ch_run
                for ref, sub in self.fonts.runs(font, string):
                    if limit >= 0:
                        if shown >= limit:
                            break
                        sub = sub[:max(0, limit - shown)]
                    shown += len(sub)
                    adv = self.fonts.run_em(ref, sub) * size
                    X, Y = x * s - px0, base * s - py0
                    if ref == "emoji":
                        img, asc_px, left = self.fonts.emoji_image(sub, size * s)
                        fill.alpha_composite(img, dest=(int(X - left), int(Y - asc_px)))
                    elif ref is not None:
                        f = self.fonts.font(ref, size * s)
                        df.text((X, Y), sub, font=f, fill=(colour or base_col) + (255,), anchor="ls")
                        if ds is not None:
                            ds.text((X, Y), sub, font=f, fill=stroke_col + (255,), anchor="ls", stroke_width=sw,
                                    stroke_fill=stroke_col + (255,))
                    x += adv
        grad = n.get("gradient")
        if grad:
            fill = self.tint(fill, grad, self.rect(n), px0, py0)
        if stroke is not None:
            self.composite(layer, self.with_alpha(stroke, stroke_a), px0, py0, clip)
        self.composite(layer, self.with_alpha(fill, 1.0 - tT), px0, py0, clip)

    @staticmethod
    def colour_runs(line):
        out = []
        for c, col in line:
            if out and out[-1][0] == col:
                out[-1] = (col, out[-1][1] + c)
            else:
                out.append((col, c))
        return out

    def tint(self, img, grad, rect, px0, py0):
        grgb, galpha = gradient_field(grad, rect, px0, py0, img.width, img.height)
        arr = np.asarray(img, dtype=np.float32).copy()
        arr[..., :3] *= grgb / 255.0
        arr[..., 3] *= galpha
        return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")

    # -- trees --------------------------------------------------------------------------------------
    @staticmethod
    def zkey(n):
        return (n.get("z", 1), n.get("order", 0))

    def subtree_extent(self, n, cx, cy):
        x0, y0, x1, y1 = self.rect(n)
        far = max(math.hypot(x - cx, y - cy) for x in (x0, x1) for y in (y0, y1))
        for c in n.get("children", []):
            far = max(far, self.subtree_extent(c, cx, cy))
        return far

    def draw_tree(self, n, layer, clip):
        rot = float(n.get("rot", 0) or 0)
        group = n.get("group")
        if abs(rot) < 0.01 and not group:
            self.draw_node(n, layer, clip)
            return
        x0, y0, x1, y1 = self.rect(n)
        cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
        if abs(rot) >= 0.01:  # room for everything the turn sweeps over
            half = int(self.subtree_extent(n, cx, cy) + 40 * self.ss)
            ox, oy, size_w, size_h = int(cx) - half, int(cy) - half, 2 * half, 2 * half
        else:  # a CanvasGroup only shows what lies inside its own box
            ox, oy, size_w, size_h = int(x0) - 2, int(y0) - 2, int(x1 - x0) + 4, int(y1 - y0) + 4
        size_w, size_h = max(1, min(size_w, 16000)), max(1, min(size_h, 16000))
        sub = Layer(Image.new("RGBA", (size_w, size_h), (0, 0, 0, 0)), ox, oy)
        self.draw_node(n, sub, None)
        if group:
            gt = float(group.get("t", 0))
            mask = Image.new("L", sub.img.size, 0)
            rr(ImageDraw.Draw(mask), x0 - ox, y0 - oy, x1 - ox, y1 - oy, float(n.get("corner") or 0) * self.ss, 255)
            arr = np.asarray(sub.img, dtype=np.float32).copy()
            arr[..., :3] *= np.array(group.get("color", [255, 255, 255]), dtype=np.float32) / 255.0
            arr[..., 3] *= (np.asarray(mask, dtype=np.float32) / 255.0) * (1.0 - gt)
            sub.img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")
        if abs(rot) >= 0.01:
            # Roblox turns clockwise for positive Rotation, around the object's centre
            sub.img = sub.img.rotate(-rot, resample=Image.BICUBIC, center=(cx - ox, cy - oy))
        self.composite(layer, sub.img, ox, oy, clip)

    def draw_node(self, n, layer, clip):
        self.paint(n, layer, clip)
        child_clip = intersect(clip, self.rect(n)) if n.get("clip") else clip
        for c in sorted(n.get("children", []), key=self.zkey):
            self.draw_tree(c, layer, child_clip)
        if n.get("scroll"):
            self.scrollbar(n, layer, clip)

    def scrollbar(self, n, layer, clip):
        sc = n["scroll"]
        bar = float(sc.get("bar", 0))
        if bar <= 0 or float(sc.get("t", 0)) >= 0.99:
            return
        s = self.ss
        x0, y0, x1, y1 = self.rect(n)
        cw, ch = float(sc["canvas"][0]), float(sc["canvas"][1])
        posx, posy = float(sc["position"][0]), float(sc["position"][1])
        d = sc.get("direction", "XY")
        col = tuple(sc.get("color", [0, 0, 0])) + (int(255 * (1 - float(sc.get("t", 0)))),)
        patch_layer = []
        if d in ("Y", "XY") and ch > n["h"] + 0.5:
            length = max(bar * 2, n["h"] * n["h"] / ch)
            yy = n["y"] + (n["h"] - length) * min(1.0, posy / max(1e-6, ch - n["h"]))
            patch_layer.append(((n["x"] + n["w"] - bar) * s, yy * s, (n["x"] + n["w"]) * s, (yy + length) * s))
        if d in ("X", "XY") and cw > n["w"] + 0.5:
            length = max(bar * 2, n["w"] * n["w"] / cw)
            xx = n["x"] + (n["w"] - length) * min(1.0, posx / max(1e-6, cw - n["w"]))
            patch_layer.append((xx * s, (n["y"] + n["h"] - bar) * s, (xx + length) * s, (n["y"] + n["h"]) * s))
        for bx0, by0, bx1, by1 in patch_layer:
            px0, py0 = int(bx0), int(by0)
            patch = Image.new("RGBA", (int(bx1 - px0) + 1, int(by1 - py0) + 1), (0, 0, 0, 0))
            rr(ImageDraw.Draw(patch), bx0 - px0, by0 - py0, bx1 - px0, by1 - py0, bar * s / 2.0, col)
            self.composite(layer, patch, px0, py0, intersect(clip, (x0, y0, x1, y1)))

    def draw_global(self, gui, layer):
        flat = []

        def collect(n, clip):
            # a rotated object or a CanvasGroup takes its descendants along (one texture), whatever their ZIndex
            unit = abs(float(n.get("rot", 0) or 0)) >= 0.01 or bool(n.get("group"))
            flat.append((n, clip, len(flat), unit))
            if unit:
                return
            child_clip = intersect(clip, self.rect(n)) if n.get("clip") else clip
            for c in n.get("children", []):
                collect(c, child_clip)

        for n in gui["nodes"]:
            collect(n, None)
        for n, clip, _, unit in sorted(flat, key=lambda e: (e[0].get("z", 1), e[2])):
            if unit:
                self.draw_tree(n, layer, clip)
                continue
            single = dict(n)
            single["children"] = []  # the descendants come in their own ZIndex turn
            self.draw_tree(single, layer, clip)

    # -- backdrop + Roblox chrome --------------------------------------------------------------------
    def backdrop(self):
        W, H = self.W, self.H
        if self.bg == "grey":
            return Image.new("RGBA", (W, H), (128, 128, 128, 255))
        if self.bg == "dark":
            return Image.new("RGBA", (W, H), (34, 38, 52, 255))
        y = np.linspace(0, 1, H, dtype=np.float32)[:, None]
        horizon = 1.0 if self.bg == "sky" else 0.56
        sky_t = np.clip(y / horizon, 0, 1)
        top, low = np.array([104, 162, 230], np.float32), np.array([198, 226, 250], np.float32)
        img = (top * (1 - sky_t[..., None]) + low * sky_t[..., None]) * np.ones((1, W, 1), np.float32)
        if self.bg != "sky":
            g = np.clip((y - horizon) / (1 - horizon), 0, 1)
            grass = np.array([126, 196, 98], np.float32) * (1 - g[..., None]) + np.array([84, 150, 66], np.float32) * g[..., None]
            ground = (y >= horizon)[..., None]
            img = np.where(ground, grass * np.ones((1, W, 1), np.float32), img)
        base = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
        hy = int(H * horizon)
        if self.bg != "sky":
            # a stone plaza in perspective with a path, and far cloud islands on the horizon
            d = ImageDraw.Draw(base)
            for i in range(9):
                cx = W * (0.05 + i * 0.12)
                d.ellipse([cx - W * 0.09, hy - H * 0.035, cx + W * 0.09, hy + H * 0.02], fill=(232, 240, 250, 255))
            d.polygon([(W * 0.28, hy), (W * 0.72, hy), (W * 1.05, H), (W * -0.05, H)], fill=(178, 182, 192, 255))
            d.polygon([(W * 0.46, hy), (W * 0.54, hy), (W * 0.64, H), (W * 0.36, H)], fill=(206, 192, 162, 255))
        over = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(over)
        rng = np.random.RandomState(7)
        for _ in range(7):
            cx, cy = rng.uniform(0, W), rng.uniform(0.05, 0.38) * H
            for k in range(4):
                big = max(W, H)
                rx, ry = big * rng.uniform(0.03, 0.06), big * rng.uniform(0.014, 0.028)
                ox = (k - 1.5) * rx * 0.9
                d.ellipse([cx + ox - rx, cy - ry, cx + ox + rx, cy + ry], fill=(255, 255, 255, 150))
        over = over.filter(ImageFilter.GaussianBlur(max(1, W // 400)))
        base.alpha_composite(over)
        return base

    def draw_chrome(self, layer):
        """Faint ghosts of Roblox's own top bar buttons and touch controls (drawn on an overlay, then blended)."""
        s = self.ss
        inset = float(self.dump.get("inset", 0) or 0)
        over = Layer(Image.new("RGBA", layer.img.size, (0, 0, 0, 0)), layer.ox, layer.oy)
        d = ImageDraw.Draw(over.img)
        ghost = (20, 22, 28, 120)
        if inset > 0:
            b = 44.0
            y = (inset - b) / 2.0
            for i, x in enumerate((12.0, 12.0 + b + 8)):
                rr(d, x * s, y * s, (x + b) * s, (y + b) * s, 10 * s, ghost)
                if i == 0:
                    for k in range(3):
                        yy = (y + 14 + k * 8) * s
                        d.rectangle([(x + 12) * s, yy, (x + b - 12) * s, yy + 2 * s], fill=(255, 255, 255, 170))
                else:
                    d.rounded_rectangle([(x + 11) * s, (y + 12) * s, (x + b - 11) * s, (y + b - 15) * s],
                                        radius=4 * s, outline=(255, 255, 255, 170), width=max(1, 2 * s))
            x = self.W - 12.0 - b
            rr(d, x * s, y * s, (x + b) * s, (y + b) * s, 10 * s, ghost)
            for k in range(3):
                cx = (x + 13 + k * 9) * s
                d.ellipse([cx - 2 * s, (y + b / 2 - 2) * s, cx + 2 * s, (y + b / 2 + 2) * s], fill=(255, 255, 255, 170))
        if self.dump.get("touch"):
            small = min(self.W, self.H) <= 500
            j = 70.0 if small else 120.0
            jx0 = self.W - (j * 1.5 + 10)
            jy1 = self.H - (20.0 if small else j * 0.75)
            stick = j
            tx0 = (stick / 2.0 - 10) if small else stick / 2.0
            ty1 = self.H - (20.0 if small else stick * 0.75)
            for (x0, y1, size, name) in ((jx0, jy1, j, "jump"), (tx0, ty1, stick, "thumbstick")):
                box = [x0 * s, (y1 - size) * s, (x0 + size) * s, y1 * s]
                d.ellipse(box, outline=(255, 255, 255, 150), width=max(1, int(3 * s)))
                d.ellipse([box[0] + 6 * s, box[1] + 6 * s, box[2] - 6 * s, box[3] - 6 * s], fill=(255, 255, 255, 38))
        layer.img.alpha_composite(over.img)
        if self.dump.get("touch"):
            for (x0, y1, size, name) in ((jx0, jy1, j, "jump"), (tx0, ty1, stick, "thumbstick")):
                self.label(layer, None, (x0 + size / 2.0) * s, (y1 - size / 2.0) * s, "Roblox " + name, 140 * s,
                           (240, 244, 252), (20, 26, 50, 120), size_px=10)

    # -- debug overlays -----------------------------------------------------------------------------
    def draw_boxes(self, layer):
        over = Image.new("RGBA", layer.img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(over)
        palette = [(255, 64, 160, 200), (64, 200, 255, 200), (255, 200, 40, 200), (120, 255, 120, 200)]
        for x0, y0, x1, y1, n in self.box_list:
            depth = n.get("path", "").count(".")
            d.rectangle([x0, y0, max(x0, x1 - 1), max(y0, y1 - 1)], outline=palette[depth % len(palette)], width=1)
        layer.img.alpha_composite(over)

    def draw_small_marks(self, layer, floor_px):
        d = ImageDraw.Draw(layer.img)
        s = self.ss
        for t in self.texts:
            if t["on_screen"] and t["size"] < floor_px - 0.05:
                x0, y0, x1, y1 = t["rect"]
                d.rectangle([x0 * s - 2 * s, y0 * s - 2 * s, x1 * s + 2 * s, y1 * s + 2 * s], outline=(255, 30, 30, 255),
                            width=max(2, 2 * s))

    # -- all ----------------------------------------------------------------------------------------
    def render(self, scale=1.0, crop=None):
        """The screen as an RGB image (scale x the screen size), or only crop = (x, y, w, h) screen px of it."""
        s = self.ss
        canvas = Layer(self.backdrop().resize((self.W * s, self.H * s), Image.BILINEAR))
        guis = sorted(self.dump.get("guis", []), key=lambda g: (g.get("displayOrder", 0), g.get("order", 0)))
        for gui in guis:
            if not gui.get("enabled", True):
                continue
            if gui.get("zBehavior") == "Global":
                self.draw_global(gui, canvas)
            else:
                for n in sorted(gui.get("nodes", []), key=self.zkey):
                    self.draw_tree(n, canvas, None)
        if self.chrome:
            self.draw_chrome(canvas)
        if self.boxes:
            self.draw_boxes(canvas)
        if self.mark_small:
            self.draw_small_marks(canvas, self.mark_small)
        img = canvas.img
        x, y, w, h = crop if crop else (0, 0, self.W, self.H)
        x, y = max(0, min(int(x), self.W - 1)), max(0, min(int(y), self.H - 1))
        w, h = max(1, min(int(w), self.W - x)), max(1, min(int(h), self.H - y))
        if crop:
            img = img.crop((x * s, y * s, (x + w) * s, (y + h) * s))
        size = (max(1, int(round(w * scale))), max(1, int(round(h * scale))))
        return img.resize(size, Image.LANCZOS).convert("RGB")


# ---------------------------------------------------------------------------------------------------
# Report + sheets
# ---------------------------------------------------------------------------------------------------
def readability_floor(height):
    return 15.0 if height >= 1000 else 14.0


def text_report(renderer, height):
    shown = [t for t in renderer.texts if t["on_screen"]]
    floor_px = readability_floor(height)
    small = sorted([t for t in shown if t["size"] < floor_px - 0.05], key=lambda t: t["size"])
    smallest = min(shown, key=lambda t: t["size"]) if shown else None
    return shown, small, smallest, floor_px


def describe(t):
    text = t["text"].replace("\n", " ")
    if len(text) > 34:
        text = text[:33] + "\u2026"
    path = t["path"]
    if len(path) > 70:
        path = "\u2026" + path[-69:]
    return "%5.1f px%s  \"%s\"  (%s)" % (t["size"], " (scaled)" if t["scaled"] else "", text, path)


def print_report(dump, renderer, label, verbose=False):
    W, H = dump["viewport"]
    shown, small, smallest, floor_px = text_report(renderer, H)
    print("%s: %d GuiObjects drawn, %d texts on screen" % (label, renderer.drawn, len(shown)))
    for note in dump.get("notes", []):
        print("  note: " + str(note))
    for e in dump.get("errors", []):
        print("  script error: " + str(e).splitlines()[0])
    if verbose:
        for w in dump.get("warnings", []):
            print("  warn: " + str(w))
    if small:
        print("  %d text(s) under the %.0f px readability floor:" % (len(small), floor_px))
        for t in small[:12]:
            print("    " + describe(t))
        if len(small) > 12:
            print("    ... %d more" % (len(small) - 12))
    if smallest:
        print("  smallest on-screen text: " + describe(smallest))
    else:
        print("  smallest on-screen text: none (no text on screen)")
    return smallest


def caption_font(fonts, size):
    if fonts.tool_path:
        return fonts.font(fonts.tool_path, size)
    return ImageFont.load_default()


def grid_sheet(cells, fonts, title):
    """cells: [(image, caption)] in the order of GRID_SIZES -> one sheet (desktop row, phone row)."""
    gap, head, cap = 24, 56, 52
    scales = [0.5, 0.75, 1.0, 1.0]
    scaled = []
    for (img, caption), k in zip(cells, scales):
        w, h = int(round(img.width * k)), int(round(img.height * k))
        scaled.append((img.resize((w, h), Image.LANCZOS) if k != 1.0 else img, caption, k))
    row1 = scaled[:2]
    row2 = scaled[2:]
    w1 = sum(i.width for i, _, _ in row1) + gap * (len(row1) + 1)
    w2 = sum(i.width for i, _, _ in row2) + gap * (len(row2) + 1)
    h1 = max(i.height for i, _, _ in row1) + cap
    h2 = max(i.height for i, _, _ in row2) + cap
    W = max(w1, w2)
    H = head + h1 + gap + h2 + gap
    sheet = Image.new("RGB", (W, H), (236, 240, 247))
    d = ImageDraw.Draw(sheet)
    d.text((gap, head / 2), title, font=caption_font(fonts, 26), fill=(30, 40, 82), anchor="lm")
    y = head
    for row, rh in ((row1, h1), (row2, h2)):
        x = gap
        for img, caption, k in row:
            first, _, second = caption.partition("|")
            d.text((x, y + 4), "%s  (x%.2g)" % (first.strip(), k), font=caption_font(fonts, 17), fill=(30, 40, 82), anchor="la")
            d.text((x, y + 26), second.strip(), font=caption_font(fonts, 15), fill=(70, 80, 120), anchor="la")
            sheet.paste(img, (x, y + cap))
            d.rectangle([x - 1, y + cap - 1, x + img.width, y + cap + img.height], outline=(30, 40, 82), width=1)
            x += img.width + gap
        y += rh + gap
    return sheet


def parse_size(text):
    m = re.match(r"^\s*(\d+)\s*[xX*,]\s*(\d+)\s*$", text or "")
    if not m:
        raise argparse.ArgumentTypeError("size must look like 1920x1080")
    w, h = int(m.group(1)), int(m.group(2))
    if w < 100 or h < 100 or w > 7680 or h > 4320:
        raise argparse.ArgumentTypeError("size out of range (100..7680 x 100..4320)")
    return w, h


def parse_crop(text):
    parts = [p for p in re.split(r"[,\s]+", text or "") if p]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("crop must look like X,Y,W,H (screen px)")
    try:
        x, y, w, h = [float(p) for p in parts]
    except ValueError:
        raise argparse.ArgumentTypeError("crop must look like X,Y,W,H (screen px)")
    if w <= 0 or h <= 0:
        raise argparse.ArgumentTypeError("crop width and height must be positive")
    return x, y, w, h


def render_one(dump, fonts, args):
    floor_px = None
    if args.mark_small is not None:
        floor_px = args.mark_small if args.mark_small > 0 else readability_floor(dump["viewport"][1])
    scale = max(0.1, float(getattr(args, "scale", 1.0) or 1.0))
    ss = max(args.ss, int(math.ceil(scale * 2))) if scale > 1 else args.ss  # enough pixels for a zoomed view
    r = GuiRenderer(dump, fonts, ss=ss, bg=args.bg, chrome=not args.no_chrome, labels=not args.no_labels,
                    boxes=args.boxes, mark_small=floor_px)
    return r.render(scale, getattr(args, "crop", None)), r


def main():
    ap = argparse.ArgumentParser(description="Offline renders of the Nimbus Climb 2D UI (real client code + Pillow)")
    ap.add_argument("scenario", nargs="?", help="lobby, title, match[:hit], countdown, party, results, menu:<Window>[:<Tab>], "
                    "tutorial[:<step>], npc[:<n>], dev, toasts, portal[:<Id>[:<players>[:<studs>]]], homepads[:<tier>], or a dump .json")
    ap.add_argument("-o", "--out", help="output PNG (default: gui_<scenario>_<W>x<H>.png in the current directory)")
    ap.add_argument("--size", type=parse_size, default=(1920, 1080), help="screen size WxH (default 1920x1080)")
    ap.add_argument("--grid", action="store_true", help="render 1920x1080, 1280x720, 390x844 and 844x390 into one sheet")
    ap.add_argument("--touch", dest="touch", action="store_true", default=None, help="boot as a touch device")
    ap.add_argument("--no-touch", dest="touch", action="store_false", help="boot as a desktop (keyboard + mouse)")
    ap.add_argument("--bg", choices=["lobby", "grey", "sky", "dark"], default="lobby", help="backdrop (default lobby)")
    ap.add_argument("--ss", type=int, default=2, help="supersampling factor (default 2)")
    ap.add_argument("--crop", type=parse_crop, metavar="X,Y,W,H", help="only this part of the screen (screen px)")
    ap.add_argument("--scale", type=float, default=1.0, help="output scale, e.g. 3 with --crop to zoom in (default 1)")
    ap.add_argument("--boxes", action="store_true", help="outline every GuiObject's box (layout debugging)")
    ap.add_argument("--mark-small", type=float, nargs="?", const=-1.0, default=None, metavar="PX",
                    help="frame texts smaller than PX in red (default: the readability floor)")
    ap.add_argument("--no-chrome", action="store_true", help="do not sketch Roblox's top bar / touch controls")
    ap.add_argument("--no-labels", action="store_true", help="no captions on image / viewport placeholders")
    ap.add_argument("--json", metavar="FILE", help="also write the GUI dump as JSON")
    ap.add_argument("--list", action="store_true", help="list the scenarios and exit")
    ap.add_argument("--engine", help="lupa engine (default: luajit21)")
    ap.add_argument("--echo", action="store_true", help="print the game's print()/warn() output while it runs")
    ap.add_argument("-v", "--verbose", action="store_true", help="print the font mapping and the game's warn() lines")
    args = ap.parse_args()

    if args.list:
        print("scenarios: " + ", ".join(SCENARIOS))
        print("(menu:<Window>[:<Tab>] also takes a tab or an Index group, e.g. menu:Shop:Items, menu:Index:Mythic;"
              " tutorial:<step>, npc:<n>)")
        return 0
    if not args.scenario:
        ap.error("a scenario is required (or --list)")
    fonts = FontBook()
    if args.verbose:
        print("fonts:")
        for line in fonts.mapping(["FredokaOne", "GothamBlack", "GothamBold", "BuilderSansBold", "LuckiestGuy",
                                   "Fondamento", "SourceSans"]):
            print(line)
        print("  emoji                -> %s" % (os.path.basename(fonts.emoji_path[0]) if fonts.emoji_path else "none"))
    scenario = args.scenario
    is_file = scenario.lower().endswith(".json")
    if is_file and not os.path.isfile(scenario):
        sys.exit("no such dump file: " + scenario)
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in os.path.basename(scenario).replace(".json", ""))

    t0 = time.time()
    if args.grid:
        if is_file:
            ap.error("--grid needs a scenario, not a dump file")
        if args.crop or args.scale != 1.0:
            ap.error("--crop / --scale work on single renders, not on --grid")
        cells = []
        for (w, h) in GRID_SIZES:
            touch = is_touch(w, h, args.touch)
            t1 = time.time()
            dump = dump_scenario(scenario, w, h, touch, fonts, None, args.engine, args.echo, args.verbose)
            img, r = render_one(dump, fonts, args)
            label = "%dx%d%s" % (w, h, " touch" if touch else "")
            smallest = print_report(dump, r, "%s %s (%.1fs)" % (scenario, label, time.time() - t1), args.verbose)
            cap = label + ("|smallest text %.1f px" % smallest["size"] if smallest else "|no text")
            cells.append((img, cap))
        sheet = grid_sheet(cells, fonts, "Nimbus Climb UI: " + scenario)
        out = args.out or ("gui_%s_grid.png" % safe)
        sheet.save(out)
        print("wrote %s (%dx%d) in %.1fs" % (out, sheet.width, sheet.height, time.time() - t0))
        return 0

    w, h = args.size
    if is_file:
        with open(scenario, encoding="utf-8") as fh:
            dump = json.load(fh)
        w, h = int(dump["viewport"][0]), int(dump["viewport"][1])
        label = "%s (%dx%d)" % (scenario, w, h)
    else:
        touch = is_touch(w, h, args.touch)
        dump = dump_scenario(scenario, w, h, touch, fonts, args.json, args.engine, args.echo, args.verbose)
        label = "%s at %dx%d%s" % (scenario, w, h, " (touch)" if touch else "")
        print("dumped %s in %.1fs (text metrics: %s)" % (label, time.time() - t0, dump.get("metrics", "?")))
    t1 = time.time()
    img, r = render_one(dump, fonts, args)
    print_report(dump, r, label, args.verbose)
    out = args.out or ("gui_%s_%dx%d.png" % (safe, w, h))
    img.save(out)
    print("wrote %s (%dx%d) in %.1fs" % (out, img.width, img.height, time.time() - t1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
