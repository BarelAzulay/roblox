#!/usr/bin/env python3
"""Offline renders of the game's voxel art: build a model with the REAL Lua modules and draw it.

    python3 tools/render_model.py <target> -o out.png [--views front,threequarter,side,back,top] [--size 768]
                                  [--box x0,y0,z0,x1,y1,z1] [--json dump.json] [--dump-only] [--echo]
    python3 tools/render_model.py --grid -o pets.png [pets|pets:Low|species|species:Low] [--cell 240]

Targets (see tools/dump_model.lua; several can be joined with "+", e.g. lobby+npcs+storm-altar):
    pet:<petId>[:High|Low]   species:<Species>[:High|Low]   lobby   npcs   storm-altar   skydragon
    token[:golden]           module:<path>:<func>[:lobby]   or a .json file written earlier with --json

How it works: tools/dump_model.lua runs inside a lupa Lua world booted like tools/smoke.py (tools/robloxmock.lua,
src/ mounted per default.project.json), builds the model with the game's own code and dumps every BasePart
(CFrame, Size, Color, Material, Transparency, Shape). This file then rasterises the parts with numpy + Pillow:
orthographic camera, z-buffer, every part an oriented box (wedges as prisms, balls and cylinders as polyhedra),
Lambert + ambient shading with a soft key light from the upper front-left, Neon unshaded with a slight bloom,
Glass / transparent parts alpha blended, thin dark outlines on silhouette edges and a light sky gradient.
The front view looks the model in the face (a pet's LookVector), "side" looks at its right flank, "top" has the
front at the bottom of the image. Prints the part count and the bounding box; the sheet shows the count too.

Needs: lupa, numpy, Pillow.
"""
import argparse
import json
import math
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError as exc:  # pragma: no cover
    sys.exit("render_model.py needs numpy and Pillow (%s)" % exc)

# ---------------------------------------------------------------------------------------------------
# Lua world (booted the way tools/smoke.py boots one)
# ---------------------------------------------------------------------------------------------------
ENGINES = ["luajit21", "luajit20", "lua54", "lua53", "lua55", "lua52"]
CLIENT_KINDS = {"skydragon", "dragon"}


def load_engine(preferred=None):
    import importlib

    try:
        import lupa  # noqa: F401
    except ImportError:
        sys.exit("render_model.py needs lupa:  pip install lupa")
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
    """One booted mock DataModel (server or client) with src/ mounted."""

    def __init__(self, context, engine=None, echo=False):
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
        self.mock.Boot(context, t({"localName": "Renderer", "localUserId": 4242, "touch": False}))
        roots = {}
        for inst_path, directory in project_mounts():
            if not os.path.isdir(directory):
                continue
            parent = self.mock.GetPath("/".join(inst_path.split("/")[:-1]), "Folder")
            self.mock.Mount(parent, self.to_lua(fs_node(directory, inst_path.split("/")[-1])))
            roots[os.path.basename(directory)] = inst_path
        g.ROOTS = t(roots)
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

    def dump(self, target, box=None, out=None):
        g = self.rt.globals()
        spec = {"target": target}
        if box:
            spec["box"] = self.rt.table_from(list(box))
        if out:
            spec["out"] = out
        g.DUMP = self.rt.table_from(spec)
        src = open(os.path.join(HERE, "dump_model.lua"), encoding="utf-8").read()
        g.DUMP_SRC = src
        runner = self.rt.eval(
            "function() local load_ = loadstring or load; local f, e = load_(DUMP_SRC, '=tools/dump_model.lua'); "
            "if not f then error(e, 0) end; return f() end")
        result = runner()
        text = result[0] if isinstance(result, tuple) else result
        if isinstance(text, bytes):
            text = text.decode("utf-8")
        return json.loads(text)


def target_context(piece):
    fields = piece.split(":")
    kind = fields[0].lower()
    if kind in CLIENT_KINDS:
        return "client"
    if kind == "module" and len(fields) > 1 and fields[1].replace("src/", "", 1).startswith("client/"):
        return "client"
    return "server"


def dump_target(target, box=None, json_out=None, engine=None, echo=False, verbose=False):
    """Runs dump_model.lua for the target (one Lua world per context) -> dump dict."""
    pieces = [p for p in target.split("+") if p]
    groups = []
    for piece in pieces:
        ctx = target_context(piece)
        if groups and groups[-1][0] == ctx:
            groups[-1][1].append(piece)
        elif any(g[0] == ctx for g in groups):
            next(g for g in groups if g[0] == ctx)[1].append(piece)
        else:
            groups.append((ctx, [piece]))
    models = []
    single = len(groups) == 1
    for ctx, group in groups:
        world = LuaWorld(ctx, engine, echo)
        try:
            # with one world dump_model.lua writes the JSON file itself; several worlds are merged here
            data = world.dump("+".join(group), box, json_out if single else None)
        except Exception as exc:  # a Lua error: show its message (not the runner's traceback) + the game's errors
            msg = str(exc).split("\nstack traceback:")[0].replace("dump_model: ", "")
            extra = world.script_errors()
            if extra:
                msg += "\nscript errors:\n  " + "\n  ".join(extra[:8])
            sys.exit("dump failed (%s world): %s" % (ctx, msg))
        if verbose:
            for w in world.warnings():
                print("  warn: " + w)
        for e in world.script_errors():
            print("  script error: " + e.splitlines()[0])
        models.extend(data.get("models", []))
    dump = {"target": target, "box": list(box) if box else None, "models": models}
    if json_out and not single:
        with open(json_out, "w", encoding="utf-8") as fh:
            json.dump(dump, fh)
    return dump


def merge_models(dump):
    """One model from every model of a dump (combined targets like lobby+npcs)."""
    models = dump.get("models", [])
    if len(models) <= 1:
        return models[0] if models else {"label": "empty", "parts": [], "facing": [0, 0, -1], "total": 0}
    parts = []
    total = whole = 0
    for m in models:
        parts.extend(m.get("parts", []))
        total += int(m.get("total", len(m.get("parts", []))))
        whole += int(m.get("all", m.get("total", len(m.get("parts", [])))))
    return {"label": " + ".join(m.get("label", "?") for m in models), "sub": dump.get("target", ""),
            "facing": models[0].get("facing", [0, 0, -1]), "parts": parts, "total": total, "all": whole}


# ---------------------------------------------------------------------------------------------------
# Geometry: every part -> flat primitives (triangles and parallelograms) in world space
# ---------------------------------------------------------------------------------------------------
TRI, PARA = 0, 1


def _unit_box():
    faces = [  # origin corner, edge 1, edge 2 (unit half extents)
        ((1, -1, -1), (0, 2, 0), (0, 0, 2)),
        ((-1, -1, -1), (0, 0, 2), (0, 2, 0)),
        ((-1, 1, -1), (0, 0, 2), (2, 0, 0)),
        ((-1, -1, -1), (2, 0, 0), (0, 0, 2)),
        ((-1, -1, 1), (2, 0, 0), (0, 2, 0)),
        ((-1, -1, -1), (0, 2, 0), (2, 0, 0)),
    ]
    return [(PARA, a, e1, e2) for a, e1, e2 in faces], (0.0, 0.0, 0.0)


def _tri(a, b, c):
    return (TRI, a, tuple(b[i] - a[i] for i in range(3)), tuple(c[i] - a[i] for i in range(3)))


def _unit_wedge():
    # Roblox WedgePart: full bottom (-Y) and back (+Z) faces, the slope runs from the top-back edge down to the
    # front-bottom edge (it faces up and to the front, -Z)
    faces = [
        (PARA, (-1, -1, -1), (2, 0, 0), (0, 0, 2)),  # bottom
        (PARA, (-1, -1, 1), (2, 0, 0), (0, 2, 0)),  # back
        (PARA, (-1, -1, -1), (2, 0, 0), (0, 2, 2)),  # slope
        _tri((1, -1, -1), (1, -1, 1), (1, 1, 1)),  # right side
        _tri((-1, -1, -1), (-1, -1, 1), (-1, 1, 1)),  # left side
    ]
    return faces, (0.0, -1.0 / 3.0, 1.0 / 3.0)


def _unit_corner_wedge():
    # Roblox CornerWedgePart: a full bottom and one tall vertical edge at (+X, -Z) rising to the apex
    top = (1, 1, -1)
    b = [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1)]
    faces = [(PARA, (-1, -1, -1), (2, 0, 0), (0, 0, 2))]
    for i in range(4):
        faces.append(_tri(b[i], b[(i + 1) % 4], top))
    return faces, (0.2, -0.6, -0.2)


def _unit_sphere(subdiv=2):
    t = (1.0 + 5 ** 0.5) / 2.0
    verts = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
             (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    verts = [tuple(c / math.sqrt(sum(x * x for x in v)) for c in v) for v in verts]
    tris = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
            (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11),
            (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    for _ in range(subdiv):
        cache = {}

        def mid(i, j):
            key = (min(i, j), max(i, j))
            if key not in cache:
                a, b = verts[i], verts[j]
                m = [(a[k] + b[k]) / 2 for k in range(3)]
                n = math.sqrt(sum(x * x for x in m))
                verts.append(tuple(x / n for x in m))
                cache[key] = len(verts) - 1
            return cache[key]

        new = []
        for a, b, c in tris:
            ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
            new += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        tris = new
    return [_tri(verts[a], verts[b], verts[c]) for a, b, c in tris], (0.0, 0.0, 0.0)


def _unit_cylinder(sides=24):
    # Roblox cylinder: the axis is local X
    faces = []
    ring = [(math.cos(2 * math.pi * i / sides), math.sin(2 * math.pi * i / sides)) for i in range(sides)]
    for i in range(sides):
        y0, z0 = ring[i]
        y1, z1 = ring[(i + 1) % sides]
        faces.append((PARA, (-1, y0, z0), (2, 0, 0), (0, y1 - y0, z1 - z0)))
        faces.append(_tri((1, 0, 0), (1, y0, z0), (1, y1, z1)))
        faces.append(_tri((-1, 0, 0), (-1, y1, z1), (-1, y0, z0)))
    return faces, (0.0, 0.0, 0.0)


MESHES = {
    "Block": _unit_box(),
    "Wedge": _unit_wedge(),
    "CornerWedge": _unit_corner_wedge(),
    "Ball": _unit_sphere(2),
    "Ellipsoid": _unit_sphere(2),
    "Cylinder": _unit_cylinder(24),
}

# Materials with special handling: Neon is drawn unshaded and blooms, Glass is always a little see-through,
# ForceField is mostly see-through. Every other material (Grass, Slate, WoodPlanks...) shades like Plastic.
NEON = "Neon"
GLASS = {"Glass"}
FORCEFIELD = {"ForceField"}


class Geometry:
    """Flat primitives of a model: origin A, edges E1 / E2, kind (TRI or PARA), outward normal, colour, alpha."""

    def __init__(self, parts):
        keep = []
        for p in parts:
            tr = float(p.get("transparency", 0) or 0)
            if tr >= 0.98:
                continue
            keep.append(p)
        self.count_all = len(parts)
        self.count_visible = len(keep)
        groups = {}
        for i, p in enumerate(keep):
            shape = p.get("shape", "Block")
            if shape not in MESHES:
                shape = "Block"
            groups.setdefault(shape, []).append(i)
        n = len(keep)
        pos = np.array([p["pos"] for p in keep], dtype=np.float64).reshape(n, 3)
        rot = np.array([p["rot"] for p in keep], dtype=np.float64).reshape(n, 3, 3)
        size = np.array([p["size"] for p in keep], dtype=np.float64).reshape(n, 3)
        color = np.array([p.get("color", [163, 162, 165]) for p in keep], dtype=np.float64).reshape(n, 3) / 255.0
        trans = np.array([float(p.get("transparency", 0) or 0) for p in keep], dtype=np.float64)
        mats = [p.get("material", "Plastic") for p in keep]
        neon = np.array([m == NEON for m in mats], dtype=bool)
        glass = np.array([m in GLASS for m in mats], dtype=bool)
        alpha = 1.0 - trans
        alpha = np.where(glass, np.minimum(alpha, 0.82), alpha)
        alpha = np.where(np.array([m in FORCEFIELD for m in mats], dtype=bool), alpha * 0.35, alpha)
        self.part_pos, self.part_rot, self.part_size = pos, rot, size

        A, E1, E2, K, NRM, PID = [], [], [], [], [], []
        for shape, idx in groups.items():
            idx = np.array(idx, dtype=np.int64)
            faces, centroid = MESHES[shape]
            fa = np.array([f[1] for f in faces], dtype=np.float64)
            f1 = np.array([f[2] for f in faces], dtype=np.float64)
            f2 = np.array([f[3] for f in faces], dtype=np.float64)
            fk = np.array([f[0] for f in faces], dtype=np.int8)
            half = size[idx] / 2.0
            if shape == "Ball":
                r = half.min(axis=1, keepdims=True)
                half = np.repeat(r, 3, axis=1)
            elif shape == "Cylinder":
                r = np.minimum(half[:, 1], half[:, 2])
                half = np.stack([half[:, 0], r, r], axis=1)
            R = rot[idx]
            P = pos[idx]

            def world(local, translate):
                scaled = local[None, :, :] * half[:, None, :]  # (n, F, 3)
                w = np.einsum("nij,nfj->nfi", R, scaled)
                if translate:
                    w = w + P[:, None, :]
                return w

            wa = world(fa, True)
            w1 = world(f1, False)
            w2 = world(f2, False)
            nrm = np.cross(w1, w2)
            length = np.linalg.norm(nrm, axis=2, keepdims=True)
            ok = length[:, :, 0] > 1e-12
            nrm = nrm / np.maximum(length, 1e-12)
            # outward: away from the solid's centroid
            cen = world(np.array([centroid], dtype=np.float64), True)  # (n, 1, 3)
            fc = wa + (w1 + w2) * np.where(fk == PARA, 0.5, 1.0 / 3.0)[None, :, None]
            flip = np.einsum("nfi,nfi->nf", fc - cen, nrm) < 0
            nrm = np.where(flip[:, :, None], -nrm, nrm)
            F = len(faces)
            A.append(wa[ok])
            E1.append(w1[ok])
            E2.append(w2[ok])
            K.append(np.broadcast_to(fk[None, :], (len(idx), F))[ok])
            NRM.append(nrm[ok])
            PID.append(np.broadcast_to(idx[:, None], (len(idx), F))[ok])
        if A:
            self.A = np.concatenate(A)
            self.E1 = np.concatenate(E1)
            self.E2 = np.concatenate(E2)
            self.kind = np.concatenate(K)
            self.normal = np.concatenate(NRM)
            self.pid = np.concatenate(PID)
        else:
            self.A = self.E1 = self.E2 = self.normal = np.zeros((0, 3))
            self.kind = np.zeros(0, dtype=np.int8)
            self.pid = np.zeros(0, dtype=np.int64)
        self.color, self.alpha, self.neon = color, alpha, neon

    def corners(self):
        """Every corner of every primitive (for framing)."""
        pts = [self.A, self.A + self.E1, self.A + self.E2]
        para = self.kind == PARA
        if para.any():
            pts.append((self.A + self.E1 + self.E2)[para])
        return np.concatenate(pts) if len(self.A) else np.zeros((0, 3))

    def bounds(self, box=None):
        """AABB of the visible geometry (balls and cylinders by their polyhedra), optionally clipped to a box."""
        pts = self.corners()
        if len(pts) == 0:
            return np.zeros(3), np.zeros(3)
        lo, hi = pts.min(axis=0), pts.max(axis=0)
        if box is not None:
            lo = np.clip(lo, np.minimum(box[:3], box[3:]), np.maximum(box[:3], box[3:]))
            hi = np.clip(hi, np.minimum(box[:3], box[3:]), np.maximum(box[:3], box[3:]))
        return lo, hi


# ---------------------------------------------------------------------------------------------------
# Cameras
# ---------------------------------------------------------------------------------------------------
VIEW_ALIASES = {"3q": "threequarter", "three-quarter": "threequarter", "threequarters": "threequarter",
                "persp": "threequarter", "right": "side", "profile": "side"}
VIEWS = ["front", "threequarter", "side", "left", "back", "top", "hero"]
VIEW_LABEL = {"front": "FRONT", "threequarter": "3/4", "side": "SIDE", "left": "LEFT", "back": "BACK", "top": "TOP", "hero": "HERO"}


def _norm(v):
    v = np.asarray(v, dtype=np.float64)
    n = np.linalg.norm(v)
    return v / n if n > 1e-9 else v


def view_basis(view, facing):
    """-> (right, up, forward) unit vectors; the camera looks along forward."""
    world_up = np.array([0.0, 1.0, 0.0])
    f = np.asarray(facing, dtype=np.float64)
    f = np.array([f[0], 0.0, f[2]])
    f = _norm(f) if np.linalg.norm(f) > 1e-6 else np.array([0.0, 0.0, -1.0])
    right_m = np.cross(f, world_up)  # the model's own right hand
    if view == "front":
        cam = f
    elif view == "back":
        cam = -f
    elif view == "side":
        cam = right_m
    elif view == "left":
        cam = -right_m
    elif view == "threequarter":
        az, el = math.radians(38), math.radians(24)
        horiz = math.cos(az) * f + math.sin(az) * right_m
        cam = math.cos(el) * horiz + math.sin(el) * world_up
    elif view == "hero":  # lower and more from the side: the evolved sheet's showcase angle
        az, el = math.radians(52), math.radians(13)
        horiz = math.cos(az) * f + math.sin(az) * right_m
        cam = math.cos(el) * horiz + math.sin(el) * world_up
    elif view == "top":
        fwd = -world_up
        up = -f  # the front of the model at the bottom of the image
        return np.cross(fwd, up), up, fwd
    else:
        raise ValueError(view)
    fwd = -_norm(cam)
    up = _norm(world_up - fwd * np.dot(world_up, fwd))
    right = np.cross(fwd, up)
    return right, up, fwd


# ---------------------------------------------------------------------------------------------------
# Rasteriser
# ---------------------------------------------------------------------------------------------------
LIGHT_CAM = _norm([-0.45, 0.70, 0.55])  # key light: upper front-left, in camera space (right, up, towards camera)
AMBIENT, DIFFUSE, HEMI = 0.68, 0.50, 0.05
OUTLINE_RGB = np.array([34.0, 40.0, 62.0], dtype=np.float32) / 255.0
BATCH = 2_000_000  # scanline rows + covered pixels handled per vectorised batch
NO_HIT = np.iinfo(np.int64).max
QSCALE = float(2 ** 38)  # depth quantisation of the z-buffer key (the low 24 bits hold the primitive index)


def fragments(ax, ay, az, e1x, e1y, e1z, e2x, e2y, e2z, kind, W, H):
    """Scanline rasteriser for flat convex primitives (screen-space triangles / parallelograms).
    Yields batches of (pixel index, depth, primitive index): exactly one fragment per covered pixel centre."""
    para = kind == PARA
    vx = np.stack([ax, ax + e1x, np.where(para, ax + e1x + e2x, ax + e2x), ax + e2x], axis=1)
    vy = np.stack([ay, ay + e1y, np.where(para, ay + e1y + e2y, ay + e2y), ay + e2y], axis=1)
    det = e1x * e2y - e1y * e2x
    ok = np.abs(det) > 1e-9  # edge-on faces cover nothing
    safe = np.where(ok, det, 1.0)
    dzdx = (e1z * e2y - e2z * e1y) / safe  # depth gradient across the screen
    dzdy = (e2z * e1x - e1z * e2x) / safe
    y0 = np.maximum(np.ceil(vy.min(axis=1) - 0.5), 0)
    y1 = np.minimum(np.floor(vy.max(axis=1) - 0.5), H - 1)
    live = np.nonzero(ok & (y1 >= y0) & (vx.max(axis=1) >= 0.5) & (vx.min(axis=1) <= W - 0.5))[0]
    if len(live) == 0:
        return
    cost = np.cumsum((y1[live] - y0[live] + 1) + np.minimum(np.abs(det[live]), W * H))
    start = 0
    while start < len(live):
        end = int(np.searchsorted(cost, (cost[start - 1] if start else 0) + BATCH, side="right"))
        ids = live[start:max(end, start + 1)]
        start = max(end, start + 1)
        # one (primitive, row) pair per scanline the primitive touches
        nr = (y1[ids] - y0[ids] + 1).astype(np.int64)
        pr = np.repeat(ids, nr)
        yc = y0[pr] + (np.arange(len(pr)) - np.repeat(np.cumsum(nr) - nr, nr)) + 0.5
        xl = np.full(len(pr), np.inf)
        xr = np.full(len(pr), -np.inf)
        pvx, pvy = vx[pr], vy[pr]
        for k in range(4):  # where the row crosses each polygon edge
            px_, py_ = pvx[:, k], pvy[:, k]
            qx_, qy_ = pvx[:, (k + 1) % 4], pvy[:, (k + 1) % 4]
            dy = qy_ - py_
            hit = (np.minimum(py_, qy_) <= yc) & (np.maximum(py_, qy_) >= yc) & (dy != 0)
            x = px_ + (yc - py_) / np.where(hit, dy, 1.0) * (qx_ - px_)
            xl = np.where(hit, np.minimum(xl, x), xl)
            xr = np.where(hit, np.maximum(xr, x), xr)
        good = np.isfinite(xl)
        c0 = np.maximum(np.ceil(np.where(good, xl, 0.0) - 0.5), 0)
        c1 = np.minimum(np.floor(np.where(good, xr, -1.0) - 0.5), W - 1)
        cnt = np.where(good & (c1 >= c0), c1 - c0 + 1, 0).astype(np.int64)
        total = int(cnt.sum())
        if total == 0:
            continue
        fp = np.repeat(np.arange(len(pr)), cnt)
        x = c0[fp] + (np.arange(total) - np.repeat(np.cumsum(cnt) - cnt, cnt))
        prim = pr[fp]
        yf = yc[fp]
        depth = az[prim] + dzdx[prim] * (x + 0.5 - ax[prim]) + dzdy[prim] * (yf - ay[prim])
        yield (yf - 0.5).astype(np.int64) * W + x.astype(np.int64), depth, prim


def sky_gradient(W, H, top=(172, 208, 246), bottom=(236, 244, 252)):
    t = np.linspace(0.0, 1.0, H, dtype=np.float32)[:, None, None]
    img = np.array(top, dtype=np.float32) * (1 - t) + np.array(bottom, dtype=np.float32) * t
    return np.repeat(img / 255.0, W, axis=1)


def render_view(geom, view, facing, W, H, scale, center, ss=2, outline=0.04, extent=1.0):
    """One panel of W x H output pixels (rendered at ss x ss supersampling) -> PIL image."""
    right, up, fwd = view_basis(view, facing)
    SW, SH = W * ss, H * ss
    s = scale * ss
    ccx, ccy = float(np.dot(center, right)), float(np.dot(center, up))
    img = sky_gradient(SW, SH)
    idx = np.nonzero(geom.normal @ fwd < -1e-9)[0] if len(geom.A) else np.zeros(0, np.int64)
    if len(idx) == 0:  # back faces never show on these closed solids
        return _downsample(img, ss)
    A, E1, E2 = geom.A[idx], geom.E1[idx], geom.E2[idx]
    ax = (A @ right - ccx) * s + SW / 2.0
    ay = SH / 2.0 - (A @ up - ccy) * s
    az = A @ fwd
    e1x, e1y, e1z = (E1 @ right) * s, -(E1 @ up) * s, E1 @ fwd
    e2x, e2y, e2z = (E2 @ right) * s, -(E2 @ up) * s, E2 @ fwd
    kind = geom.kind[idx]
    arrays = (ax, ay, az, e1x, e1y, e1z, e2x, e2y, e2z)

    # shading per primitive: camera-relative key light + a little sky light from the world up
    nrm = geom.normal[idx]
    light = LIGHT_CAM[0] * right + LIGHT_CAM[1] * up + LIGHT_CAM[2] * (-fwd)
    shade = AMBIENT + DIFFUSE * np.maximum(nrm @ light, 0.0) + HEMI * nrm[:, 1]
    pid = geom.pid[idx]
    base = geom.color[pid]
    neon = geom.neon[pid]
    lit = np.clip(base * shade[:, None], 0.0, 1.0)
    glowing = np.clip(base + (1.0 - base) * 0.12, 0.0, 1.0)  # Neon: unshaded, a touch brighter
    pcol = np.where(neon[:, None], glowing, lit).astype(np.float32)
    palpha = geom.alpha[pid].astype(np.float32)
    opaque = palpha >= 0.999

    # opaque z-buffer, streamed batch by batch: key = quantised depth << 24 | primitive (nearest wins)
    total = SW * SH
    zs = np.concatenate([az, az + e1z, az + e2z, az + e1z + e2z])
    dmin, span = float(zs.min()), max(float(zs.max() - zs.min()), 1e-9)
    best = np.full(total, NO_HIT, dtype=np.int64)
    oi = np.nonzero(opaque)[0]
    if len(oi):
        for pix, depth, prim in fragments(*(a[oi] for a in arrays), kind[oi], SW, SH):
            q = np.clip((depth - dmin) * (QSCALE / span), 0, QSCALE).astype(np.int64)
            np.minimum.at(best, pix, (q << 24) | oi[prim])
    hit = best != NO_HIT
    owner = np.where(hit, best & ((1 << 24) - 1), -1)
    zbuf = np.where(hit, dmin + (best >> 24) * (span / QSCALE), np.inf)
    flat = img.reshape(-1, 3)
    flat[hit] = pcol[owner[hit]]

    # thin outlines where the depth jumps (silhouettes): the near pixel darkens, the far one takes the ink
    zimg = zbuf.reshape(SH, SW)
    finite = hit.reshape(SH, SW)
    if finite.any():
        zf = np.where(finite, zimg, float(zimg[finite].max()) + extent * 4 + 1).astype(np.float32)
        pad = np.pad(zf, 1, mode="edge")
        c = pad[1:-1, 1:-1]
        thr = max(outline * extent, 2.5 / s)
        near = np.zeros_like(finite)
        far_side = np.zeros_like(finite)
        for (dy, dx) in ((0, 1), (1, 0)):
            fwd_n = pad[1 + dy:SH + 1 + dy, 1 + dx:SW + 1 + dx]
            back_n = pad[1 - dy:SH + 1 - dy, 1 - dx:SW + 1 - dx]
            curv = fwd_n + back_n - 2 * c  # ~0 on any plane, however steep
            near |= ((fwd_n - c > thr) | (back_n - c > thr)) & (curv > thr)
            far_side |= ((c - fwd_n > thr) | (c - back_n > thr)) & (curv < -thr)
        near &= finite
        far_side &= ~near
        img3 = flat.reshape(SH, SW, 3)
        img3[near] *= 0.5
        img3[far_side] = img3[far_side] * 0.45 + OUTLINE_RGB * 0.55

    # neon glow layer: visible opaque neon plus translucent neon (weighted by its alpha)
    glow_layer = np.zeros((total, 3), dtype=np.float32)
    neon_hit = np.zeros(total, dtype=bool)
    neon_hit[hit] = neon[owner[hit]]
    glow_layer[neon_hit] = pcol[owner[neon_hit]]

    # translucent parts (Glass, Transparency) in front of the opaque surface, blended back to front
    ti = np.nonzero(~opaque)[0]
    if len(ti):
        parts_pix, parts_depth, parts_prim = [], [], []
        for pix, depth, prim in fragments(*(a[ti] for a in arrays), kind[ti], SW, SH):
            front = depth < zbuf[pix]
            parts_pix.append(pix[front])
            parts_depth.append(depth[front])
            parts_prim.append(ti[prim[front]])
        if parts_pix:
            t_pix, t_depth, t_prim = np.concatenate(parts_pix), np.concatenate(parts_depth), np.concatenate(parts_prim)
            if len(t_pix):
                order = np.lexsort((-t_depth, t_pix))
                t_pix, t_prim = t_pix[order], t_prim[order]
                first = np.r_[True, t_pix[1:] != t_pix[:-1]]
                rank = np.arange(len(t_pix)) - np.maximum.accumulate(np.where(first, np.arange(len(t_pix)), 0))
                for k in range(int(rank.max()) + 1):  # layer k = the k-th farthest translucent surface of a pixel
                    sel = rank == k
                    pp, pr = t_pix[sel], t_prim[sel]
                    a = palpha[pr][:, None]
                    flat[pp] = flat[pp] * (1 - a) + pcol[pr] * a
                    nsel = neon[pr]
                    if nsel.any():
                        glow_layer[pp[nsel]] = np.maximum(glow_layer[pp[nsel]], pcol[pr[nsel]] * a[nsel])

    img = flat.reshape(SH, SW, 3)
    if glow_layer.any():  # soft bloom around Neon
        radius = max(2.0, 0.012 * min(SW, SH))
        g8 = Image.fromarray((np.clip(glow_layer.reshape(SH, SW, 3), 0, 1) * 255).astype(np.uint8))
        blurred = np.asarray(g8.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32) / 255.0
        img = 1.0 - (1.0 - img) * (1.0 - 0.6 * blurred)
    return _downsample(img, ss)


def _downsample(img, ss):
    im = Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8))
    if ss > 1:
        im = im.reduce(ss)
    return im


# ---------------------------------------------------------------------------------------------------
# Framing + sheets
# ---------------------------------------------------------------------------------------------------
def fit(geom, views, facing, W, H, margin=0.86, box=None):
    """Common scale (pixels per stud) for every view and each view's centre (world point). With a crop box the
    framing covers only what lies inside the box (parts that stick out of it are drawn but may be cut off)."""
    pts = geom.corners()
    if len(pts) == 0:
        return 1.0, {v: np.zeros(3) for v in views}
    if box is not None:
        pts = np.clip(pts, np.minimum(box[:3], box[3:]), np.maximum(box[:3], box[3:]))
    if len(pts) > 400_000:
        pts = pts[:: max(1, len(pts) // 400_000)]
    scale = math.inf
    centres = {}
    for v in views:
        right, up, fwd = view_basis(v, facing)
        x, y = pts @ right, pts @ up
        xr, yr = max(float(x.max() - x.min()), 1e-6), max(float(y.max() - y.min()), 1e-6)
        scale = min(scale, W * margin / xr, H * margin / yr)
        cx, cy = (x.max() + x.min()) / 2.0, (y.max() + y.min()) / 2.0
        d = float((pts @ fwd).mean())
        centres[v] = cx * right + cy * up + d * fwd
    return scale, centres


def font(size):
    for name in ("DejaVuSans-Bold.ttf", "DejaVuSans.ttf", "Arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except Exception:
            continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def text(draw, xy, msg, size, fill=(40, 52, 78), anchor="la"):
    f = font(size)
    x, y = xy
    draw.text((x + 1, y + 1), msg, font=f, fill=(255, 255, 255), anchor=anchor)
    draw.text((x, y), msg, font=f, fill=fill, anchor=anchor)


def layout(n):
    if n <= 1:
        return 1, 1
    if n == 2:
        return 2, 1
    if n == 4:
        return 2, 2
    cols = 3 if n <= 9 else 4
    return cols, (n + cols - 1) // cols


def render_sheet(model, views, size, ss=2, outline=0.04, box=None):
    geom = Geometry(model.get("parts", []))
    facing = model.get("facing", [0, 0, -1])
    cols, rows = layout(len(views))
    panel = max(64, size // cols)
    lo, hi = geom.bounds(box)
    extent = max(float(np.max(hi - lo)), 1e-3) if geom.count_visible else 1.0
    scale, centres = fit(geom, views, facing, panel, panel, box=box)
    sheet = Image.new("RGB", (panel * cols, panel * rows), (236, 244, 252))
    draw = ImageDraw.Draw(sheet)
    for i, v in enumerate(views):
        im = render_view(geom, v, facing, panel, panel, scale, centres[v], ss, outline, extent)
        x, y = (i % cols) * panel, (i // cols) * panel
        sheet.paste(im, (x, y))
        draw.rectangle([x, y, x + panel - 1, y + panel - 1], outline=(206, 220, 238))
        text(draw, (x + 8, y + 6), VIEW_LABEL.get(v, v.upper()), max(11, panel // 26))
    fs = max(11, (panel * cols) // 52)
    text(draw, (sheet.width - 8, sheet.height - 6), count_text(model, geom), fs, anchor="rd")
    label = str(model.get("label", ""))
    sub = str(model.get("sub", ""))
    text(draw, (8, sheet.height - 6), label + ("   " + sub if sub else ""), fs, anchor="ld")
    return sheet, geom


def render_grid(models, view, cell, ss=2, outline=0.04, margin=0.84):
    n = len(models)
    cols = max(1, min(8, int(math.ceil(math.sqrt(n * 1.5)))))
    rows = (n + cols - 1) // cols
    label_h = max(30, cell // 6)
    sheet = Image.new("RGB", (cols * cell, rows * (cell + label_h)), (236, 244, 252))
    draw = ImageDraw.Draw(sheet)
    stats = []
    for i, m in enumerate(models):
        geom = Geometry(m.get("parts", []))
        facing = m.get("facing", [0, 0, -1])
        lo, hi = geom.bounds()
        extent = max(float(np.max(hi - lo)), 1e-3) if geom.count_visible else 1.0
        scale, centres = fit(geom, [view], facing, cell, cell, margin=margin)
        im = render_view(geom, view, facing, cell, cell, scale, centres[view], ss, outline, extent)
        x, y = (i % cols) * cell, (i // cols) * (cell + label_h)
        sheet.paste(im, (x, y))
        draw.rectangle([x, y + cell, x + cell - 1, y + cell + label_h - 1], fill=(250, 252, 255))
        draw.rectangle([x, y, x + cell - 1, y + cell + label_h - 1], outline=(206, 220, 238))
        text(draw, (x + cell // 2, y + cell + 3), str(m.get("label", "?")), max(11, cell // 17), anchor="ma")
        sub = str(m.get("sub", ""))
        if sub.startswith("BUILD FAILED"):  # the pet's own build raised: say so in red, details on stdout
            text(draw, (x + cell // 2, y + cell + label_h - 3), "BUILD FAILED", max(9, cell // 22),
                 fill=(196, 40, 52), anchor="md")
            print("  %s: %s" % (m.get("label", "?"), sub))
        else:
            small = "  ".join(s for s in sub.split("  ") if s and s not in ("High", "Low", "EvoHigh", "EvoLow", "Evo2High", "Evo2Low"))
            text(draw, (x + cell // 2, y + cell + label_h - 3), "%s  %d parts" % (small, m.get("total", geom.count_all)),
                 max(9, cell // 24), fill=(84, 96, 122), anchor="md")
        stats.append((m.get("label", "?"), m.get("total", geom.count_all)))
    return sheet, stats


# ---------------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------------
def parse_box(text_value):
    try:
        vals = [float(v) for v in text_value.split(",")]
    except ValueError:
        vals = []
    if len(vals) != 6:
        sys.exit("--box needs six numbers: x0,y0,z0,x1,y1,z1")
    return vals


def crop_parts(parts, box):
    """Keeps the parts whose world AABB touches the box (also applied to dumps loaded from JSON)."""
    lo = np.minimum(box[:3], box[3:])
    hi = np.maximum(box[:3], box[3:])
    out = []
    for p in parts:
        R = np.abs(np.array(p["rot"], dtype=np.float64).reshape(3, 3))
        ext = R @ (np.array(p["size"], dtype=np.float64) / 2.0)
        c = np.array(p["pos"], dtype=np.float64)
        if np.all(c + ext >= lo) and np.all(c - ext <= hi):
            out.append(p)
    return out


def count_text(model, geom):
    """'6214 parts (6157 visible)' or, cropped, '3100 of 6214 parts (3054 visible)'."""
    total = int(model.get("total", geom.count_all))
    whole = int(model.get("all", total) or total)
    out = ("%d of %d parts" % (total, whole)) if whole != total else ("%d parts" % total)
    if geom.count_visible != total:
        out += " (%d visible)" % geom.count_visible
    return out


def report(model, geom, box=None):
    lo, hi = geom.bounds()
    print("%s: %s, %d primitives" % (model.get("label", "?"), count_text(model, geom), len(geom.A)))
    print("  bounds min (%.2f, %.2f, %.2f)  max (%.2f, %.2f, %.2f)  size %.2f x %.2f x %.2f studs" % (
        lo[0], lo[1], lo[2], hi[0], hi[1], hi[2], hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]))
    if box is not None:
        print("  cropped to the box (%s)" % ", ".join("%g" % v for v in box))


def main():
    ap = argparse.ArgumentParser(description="Offline renders of Nimbus Climb models (real Lua modules + numpy rasteriser)")
    ap.add_argument("target", nargs="?", help="pet:<id>[:High|Low], species:<Species>, lobby, npcs, storm-altar, skydragon, "
                    "token[:golden], module:<path>:<func>[:lobby], A+B, or a dump .json")
    ap.add_argument("-o", "--out", help="output PNG (default: render_<target>.png in the current directory)")
    ap.add_argument("--views", default="front,threequarter,side,back", help="comma list of " + ", ".join(VIEWS))
    ap.add_argument("--size", type=int, default=768, help="sheet width in pixels (default 768)")
    ap.add_argument("--box", help="world crop x0,y0,z0,x1,y1,z1 (parts touching the box are kept)")
    ap.add_argument("--grid", action="store_true", help="contact sheet of every catalog pet (target: pets[:Low] or species[:Low])")
    ap.add_argument("--cell", type=int, default=240, help="--grid cell size in pixels (default 240)")
    ap.add_argument("--margin", type=float, default=0.84, help="--grid: how much of a cell the model may fill (0.84)")
    ap.add_argument("--ss", type=int, default=2, help="supersampling factor (default 2)")
    ap.add_argument("--outline", type=float, default=0.04, help="outline depth threshold as a fraction of the model size")
    ap.add_argument("--json", metavar="FILE", help="also write the part dump as JSON")
    ap.add_argument("--dump-only", action="store_true", help="only write the --json dump, do not render")
    ap.add_argument("--engine", help="lupa engine (default: luajit21)")
    ap.add_argument("--echo", action="store_true", help="print the game's print()/warn() output while building")
    ap.add_argument("-v", "--verbose", action="store_true", help="print the game's warn() lines")
    # "--box -120,..." would look like an option to argparse: glue the value on
    argv = list(sys.argv[1:])
    for i in range(len(argv) - 1):
        if argv[i] == "--box" and argv[i + 1][:1] == "-":
            argv[i:i + 2] = ["--box=" + argv[i + 1], ""]
    args = ap.parse_args([a for a in argv if a != ""])

    target = args.target
    if args.grid and not target:
        target = "pets"
    if not target:
        ap.error("a target is required (or --grid)")
    is_file = target.lower().endswith(".json")
    if is_file and not os.path.isfile(target):
        sys.exit("no such dump file: " + target)
    if args.grid and not is_file and target.split(":")[0].lower() not in ("pets", "species"):
        ap.error("--grid renders pets or species (got '%s')" % target)
    if args.dump_only and not args.json:
        ap.error("--dump-only needs --json FILE")
    box = parse_box(args.box) if args.box else None
    views = []
    for v in args.views.split(","):
        v = VIEW_ALIASES.get(v.strip().lower(), v.strip().lower())
        if v not in VIEWS:
            ap.error("unknown view '%s' (views: %s)" % (v, ", ".join(VIEWS)))
        views.append(v)

    t0 = time.time()
    if is_file:
        with open(target, encoding="utf-8") as fh:
            dump = json.load(fh)
    else:
        dump = dump_target(target, box, args.json, args.engine, args.echo, args.verbose)
    if box:
        for m in dump.get("models", []):
            m.setdefault("all", m.get("total", len(m.get("parts", []))))
            m["parts"] = crop_parts(m.get("parts", []), np.array(box, dtype=np.float64))
            m["total"] = len(m["parts"])
    t1 = time.time()
    print("dumped %s in %.1fs" % (target, t1 - t0))
    if args.dump_only:
        print("wrote " + args.json)
        return 0

    out = args.out or ("render_%s.png" % "".join(c if c.isalnum() or c in "-_" else "_" for c in target))
    if args.grid:
        sheet, stats = render_grid(dump.get("models", []), views[0] if args.views != ap.get_default("views") else "threequarter",
                                   max(96, args.cell), args.ss, args.outline, args.margin)
        for label, count in stats:
            print("  %-22s %4d parts" % (label, count))
        print("%d models" % len(stats))
    else:
        model = merge_models(dump)
        box_arr = np.array(box, dtype=np.float64) if box else None
        sheet, geom = render_sheet(model, views, max(128, args.size), args.ss, args.outline, box_arr)
        report(model, geom, box)
    sheet.save(out)
    print("wrote %s (%dx%d) in %.1fs" % (out, sheet.width, sheet.height, time.time() - t1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
