#!/usr/bin/env python3
"""Smoke test for Nimbus Climb v2: runs the real Lua modules against a Roblox mock (tools/robloxmock.lua).

    pip install lupa
    python3 tools/smoke.py [--only SCENARIO[,SCENARIO...]] [--seeds N] [-v] [--strict] [--json FILE]

What it does (see tools/smoke_*.lua for the scenarios; --list prints their names):

  server world   loads every shared + server module through a fake ModuleScript tree, checks the public
                 API of ARCHITECTURE.md + ARCHITECTURE_V2.md (tools/contract.json), the Config / PetCatalog /
                 ItemCatalog data, PetBuilder for every pet, CourseBuilder.GenerateLayout + ValidateLayout for
                 the five difficulties over N seeds (independent audit + statistics per difficulty), cannon
                 ballistics, built courses (part budget, tags, attributes), then boots src/server/Main.server.lua,
                 joins fake players and drives the lobby (spots, shop, portals), the economy (DataService, pets,
                 roulettes, items, ProfileSync, v1 -> v2 migration), matches (victory, defeat, timeout, abandon,
                 leave, deaths, concurrent slots, pet perks), hazards (including pendulum, wind, cannon, golden
                 tokens), persistence and leak checks on a fake clock.
  client world   loads the client controllers + UI kit with a fake LocalPlayer on a 1920x1080 screen, runs
                 Main.client.lua, feeds it the exact remote traffic recorded in the server world and checks the
                 HUD, toasts, menu windows, hotbar, pet followers and the "no system text in the middle of the
                 screen" layout rule.

Exit status is 1 when any check fails or a script raised an error.
"""
import argparse
import json
import os
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# ---------------------------------------------------------------------------------------------------
# Lua engine
# ---------------------------------------------------------------------------------------------------
try:
    import lupa  # noqa: F401
except ImportError:
    sys.exit("smoke.py needs lupa:  pip install lupa")

ENGINES = ["luajit21", "luajit20", "lua54", "lua53", "lua55", "lua52"]


def load_engine(preferred=None):
    """LuaJIT first: it has Lua 5.1 semantics like Luau and can yield across pcall."""
    import importlib

    order = ([preferred] if preferred else []) + [e for e in ENGINES if e != preferred]
    for name in order:
        try:
            module = importlib.import_module("lupa." + name)
            return name, module
        except Exception:
            continue
    sys.exit("no usable lupa Lua engine found (pip install --upgrade lupa)")


class Reporter:
    """Collects Lua-side results (T.results) and prints them as they appear."""

    ICONS = {"ok": "  ok    ", "fail": "  FAIL  ", "warn": "  warn  ", "info": "  ..    "}

    def __init__(self, verbose, quiet_ok):
        self.verbose = verbose
        self.fails = 0
        self.warns = 0
        self.oks = 0
        self.records = []
        self.section = None

    def emit(self, status, section, name, detail):
        rec = {"status": status, "section": section, "name": name, "detail": detail}
        self.records.append(rec)
        if status == "fail":
            self.fails += 1
        elif status == "warn":
            self.warns += 1
        elif status == "ok":
            self.oks += 1
        if status == "ok" and not self.verbose:
            return
        if status == "info" and not self.verbose and not name.startswith("*"):
            return
        text = name.lstrip("*")
        line = self.ICONS.get(status, "  ?     ") + text
        if detail:
            line += "  -- " + str(detail).replace("\n", "\n            ")
        print(line)
        sys.stdout.flush()


def lua_len(t):
    try:
        return len(t)
    except Exception:
        return 0


def drain(lua_results, start, reporter):
    """Print results[start+1 ..] of the Lua results table; returns the new length."""
    n = lua_len(lua_results)
    for i in range(start + 1, n + 1):
        r = lua_results[i]
        reporter.emit(r["status"], r["section"], r["name"], r["detail"])
    return n


# ---------------------------------------------------------------------------------------------------
# Project tree -> mock instances (Rojo rules)
# ---------------------------------------------------------------------------------------------------
def script_class(filename):
    if filename.endswith(".server.lua") or filename.endswith(".server.luau"):
        return "Script", filename.rsplit(".server.", 1)[0]
    if filename.endswith(".client.lua") or filename.endswith(".client.luau"):
        return "LocalScript", filename.rsplit(".client.", 1)[0]
    if filename.endswith(".lua") or filename.endswith(".luau"):
        return "ModuleScript", filename.rsplit(".", 1)[0]
    return None, None


def fs_node(path, name, relroot):
    """Convert a file or directory under src/ into a spec dict like Rojo would."""
    if os.path.isdir(path):
        spec = {"name": name or os.path.basename(path), "class": "Folder", "children": []}
        entries = sorted(os.listdir(path))
        init = None
        for e in entries:
            if e in ("init.lua", "init.server.lua", "init.client.lua"):
                init = e
        for e in entries:
            if e == init or e.startswith(".") or e.endswith(".meta.json"):
                continue
            child = fs_node(os.path.join(path, e), None, relroot)
            if child:
                spec["children"].append(child)
        if init:
            cls, _ = script_class(init)
            spec["class"] = cls
            spec["source"] = open(os.path.join(path, init), encoding="utf-8").read()
            spec["path"] = os.path.relpath(os.path.join(path, init), ROOT)
        return spec
    cls, stem = script_class(os.path.basename(path))
    if not cls:
        return None
    return {
        "name": name or stem,
        "class": cls,
        "source": open(path, encoding="utf-8").read(),
        "path": os.path.relpath(path, ROOT),
        "children": [],
    }


def project_mounts():
    """Read default.project.json -> list of (instance path under the DataModel, directory)."""
    mounts = []
    with open(os.path.join(ROOT, "default.project.json"), encoding="utf-8") as fh:
        project = json.load(fh)

    def walk(node, path):
        for key, value in node.items():
            if key.startswith("$"):
                continue
            sub = path + [key]
            if isinstance(value, dict):
                if "$path" in value:
                    mounts.append(("/".join(sub), os.path.join(ROOT, value["$path"])))
                walk(value, sub)

    walk(project["tree"], [])
    return mounts


# ---------------------------------------------------------------------------------------------------
# Lua value helpers
# ---------------------------------------------------------------------------------------------------
def to_lua(rt, value):
    """Recursively convert Python lists/dicts into Lua tables."""
    if isinstance(value, dict):
        return rt.table_from({k: to_lua(rt, v) for k, v in value.items()})
    if isinstance(value, (list, tuple)):
        return rt.table_from([to_lua(rt, v) for v in value])
    return value


def lua_to_py(value, depth=0):
    """Convert simple Lua tables back to Python (for the replay log)."""
    if depth > 6:
        return None
    t = type(value).__name__
    if t == "_LuaTable":
        keys = list(value.keys())
        if keys and all(isinstance(k, (int, float)) for k in keys):
            return [lua_to_py(value[k], depth + 1) for k in sorted(keys)]
        return {k: lua_to_py(value[k], depth + 1) for k in keys}
    return value


# ---------------------------------------------------------------------------------------------------
# A Lua world (one runtime = one server or one client)
# ---------------------------------------------------------------------------------------------------
class World:
    def __init__(self, engine_module, engine_name, context, args, api, contract, touch=False, viewport=None):
        self.context = context
        self.rt = engine_module.LuaRuntime(unpack_returned_tuples=True, register_eval=False)
        self.engine = engine_name
        g = self.rt.globals()
        src = open(os.path.join(HERE, "robloxmock.lua"), encoding="utf-8").read()
        g.MOCK_SRC = src
        mock_loader = self.rt.eval(
            "function() local load_ = loadstring or load; local f, e = load_(MOCK_SRC, '=tools/robloxmock.lua'); "
            "if not f then error(e, 0) end; return f() end"
        )
        self.Mock = mock_loader()
        g.Mock = self.Mock
        self.Mock.Configure(
            self.rt.table_from(
                {
                    "creatableClasses": self.rt.table_from(api["creatableClasses"]),
                    "services": self.rt.table_from(api["services"]),
                    "options": self.rt.table_from(
                        {
                            "StrictMembers": bool(args.strict_members),
                            "Watchdog": not args.no_watchdog,
                            "StepSize": 1.0 / args.fps,
                            "SliceLimit": args.slice_limit,
                        }
                    ),
                }
            )
        )
        boot_opts = {"localName": "Tester", "localUserId": 4242, "touch": bool(touch)}
        self.Mock.Boot(context, self.rt.table_from(boot_opts))
        if viewport:
            self.Mock.SetViewport(viewport[0], viewport[1])
        if not args.no_watchdog:
            self.Mock.EnableMainWatchdog()
        self.mount_sources()
        g.CONTRACT = to_lua(self.rt, contract)
        g.ARGS = self.rt.table_from(
            {
                "seeds": args.seeds,
                "verbose": bool(args.verbose),
                "quick": bool(args.quick),
                "context": context,
            }
        )

    def mount_sources(self):
        """Mount src/ below the DataModel exactly where default.project.json says."""
        roots = {}
        for inst_path, directory in project_mounts():
            name = inst_path.split("/")[-1]
            parent_path = "/".join(inst_path.split("/")[:-1])
            if not os.path.isdir(directory):
                print("  warning: %s is mapped to %s which does not exist" % (inst_path, directory))
                continue
            spec = fs_node(directory, name, directory)
            parent = self.Mock.GetPath(parent_path, "Folder")
            self.Mock.Mount(parent, to_lua(self.rt, spec))
            roots[os.path.basename(directory)] = inst_path
        self.rt.globals().ROOTS = self.rt.table_from(roots)

    def load_scenarios(self, filenames):
        """Loads smoke_common.lua once, then every scenario file; the returned table merges them all."""
        if isinstance(filenames, str):
            filenames = [filenames]
        loader = self.rt.eval(
            "function(src, name) local load_ = loadstring or load; local f, e = load_(src, '='..name); "
            "if not f then error(e, 0) end; return f end"
        )
        merge = self.rt.eval("function(a, b) for k, v in pairs(b) do a[k] = v end return a end")
        if not getattr(self, "_common_loaded", False):
            common = open(os.path.join(HERE, "smoke_common.lua"), encoding="utf-8").read()
            loader(common, "tools/smoke_common.lua")()
            self._common_loaded = True
        merged = None
        for filename in filenames:
            src = open(os.path.join(HERE, filename), encoding="utf-8").read()
            chunk = loader(src, "tools/" + filename)
            part = chunk()
            merged = part if merged is None else merge(merged, part)
        return merged


def main():
    ap = argparse.ArgumentParser(description="Nimbus Climb smoke test (Roblox mock on lupa)")
    ap.add_argument("--only", help="comma separated scenario names (default: all)")
    ap.add_argument("--list", action="store_true", help="list scenario names and exit")
    ap.add_argument("--seeds", type=int, default=300, help="layout seeds per difficulty (default 300)")
    ap.add_argument("--quick", action="store_true", help="shorter runs (fewer seeds, skip the long timeout wait)")
    ap.add_argument("-v", "--verbose", action="store_true", help="print passing checks too")
    ap.add_argument("--strict", action="store_true", help="warnings fail the run")
    ap.add_argument("--strict-members", action="store_true", help="unknown Instance members raise errors (like Roblox) instead of being recorded")
    ap.add_argument("--engine", help="lupa engine (luajit21, lua54, ...) default: luajit21")
    ap.add_argument("--fps", type=float, default=30.0, help="simulation steps per fake second (default 30)")
    ap.add_argument("--slice-limit", type=float, default=30.0, help="real seconds a script may run without yielding")
    ap.add_argument("--no-watchdog", action="store_true", help="disable the runaway-loop debug hooks (faster)")
    ap.add_argument("--json", metavar="FILE", help="write all results as JSON")
    ap.add_argument("--root", metavar="DIR", help="project root to test (default: the repo this script lives in)")
    args = ap.parse_args()
    if args.root:
        global ROOT
        ROOT = os.path.abspath(args.root)
    if args.quick and args.seeds == 300:
        args.seeds = 40

    engine_name, engine = load_engine(args.engine)
    with open(os.path.join(HERE, "contract.json"), encoding="utf-8") as fh:
        contract = json.load(fh)
    with open(os.path.join(HERE, "roblox-api.json"), encoding="utf-8") as fh:
        api = json.load(fh)

    reporter = Reporter(args.verbose, True)
    started = time.time()
    print("Nimbus Climb smoke test  (Lua engine: %s, %d layout seeds/difficulty)" % (engine_name, args.seeds))

    only = set(x.strip() for x in args.only.split(",")) if args.only else None
    replication = None

    # -- server world ----------------------------------------------------------------------------
    # Pure content scenarios (need only the loaded modules):
    pure_scenarios = ["contract", "catalog", "config_shape", "petbuilder", "layouts", "cannon", "courses"]
    server_scenarios = (
        ["mock_selftest", "load_modules"]
        + pure_scenarios
        + [
            "boot", "lobby", "players", "spots", "economy", "items", "profile_sync", "portals", "damage_rules",
            "match_victory", "match_defeat", "match_timeout", "match_abandon", "match_leave", "match_death",
            "match_slots", "match_difficulties", "match_pets", "hazards", "persistence", "dash_relay", "shutdown",
            "final_checks",
        ]
    )
    server_files = ["smoke_server.lua", "smoke_content.lua", "smoke_economy.lua"]
    client_scenarios = [
        "client_load", "client_ui_kit", "client_state", "client_input", "client_hud", "client_notify", "client_damage",
        "client_menu", "client_hotbar", "client_pets", "client_layout_rule", "client_replay", "client_final",
    ]
    mobile_scenarios = ["client_mobile"]
    client_files = ["smoke_client.lua", "smoke_client_v2.lua"]
    if args.list:
        print("server:", ", ".join(server_scenarios))
        print("client:", ", ".join(client_scenarios + mobile_scenarios))
        return 0

    # scenarios build on each other: asking for one pulls in what it needs
    if only is not None:
        no_boot = {"mock_selftest", "load_modules", "boot"} | set(pure_scenarios)
        needs_boot = set(server_scenarios) - no_boot
        if only & needs_boot:
            only |= {"boot", "load_modules"}
        elif only & set(pure_scenarios):
            only |= {"load_modules"}
        if only & set(client_scenarios) - {"client_load"}:
            only |= {"client_load"}

    def wanted(name):
        return only is None or name in only

    run_server = any(wanted(n) for n in server_scenarios)
    run_client = any(wanted(n) for n in client_scenarios + mobile_scenarios)
    # the client replay feeds on the traffic of the whole server run
    if only is not None and wanted("client_replay") and not any(n in only for n in server_scenarios):
        run_server = True
        only = only | set(server_scenarios)

    def run_scenarios(world, table, names, label):
        """Runs the wanted scenarios of one world; a crash in one never stops the rest."""
        results = world.rt.globals().T.results
        cursor = 0
        for name in names:
            if not wanted(name):
                continue
            fn = table[name]
            if fn is None:
                reporter.emit("fail", name, "scenario %s is missing" % name, "")
                continue
            print("\n== %s ==" % name)
            t0 = time.time()
            try:
                fn()
            except Exception as exc:  # a Lua error escaping a scenario (guarded() normally catches them)
                reporter.emit("fail", name, "scenario crashed", str(exc))
            try:
                cursor = drain(results, cursor, reporter)
            except Exception:
                reporter.emit("fail", name, "could not read the results of %s" % name, traceback.format_exc())
                cursor = lua_len(results)
            if args.verbose:
                print("   (%.1fs)" % (time.time() - t0))

    server = None
    if run_server:
        try:
            server = World(engine, engine_name, "server", args, api, contract)
            S = server.load_scenarios(server_files)
            run_scenarios(server, S, server_scenarios, "server")
            replication = S["export_replication"]() if S["export_replication"] else None
        except Exception:
            reporter.emit("fail", "server", "server world crashed", traceback.format_exc())

    # -- client world ----------------------------------------------------------------------------
    if run_client and any(wanted(n) for n in client_scenarios):
        try:
            client = World(engine, engine_name, "client", args, api, contract, viewport=(1920, 1080))
            C = client.load_scenarios(client_files)
            if replication is not None:
                client.rt.globals().REPLICATION = replication_to_client(client.rt, server, replication)
            run_scenarios(client, C, client_scenarios, "client")
        except Exception:
            reporter.emit("fail", "client", "client world crashed", traceback.format_exc())

    if run_client and any(wanted(n) for n in mobile_scenarios):
        try:
            phone = World(engine, engine_name, "client", args, api, contract, touch=True, viewport=(390, 844))
            C = phone.load_scenarios(client_files)
            run_scenarios(phone, C, mobile_scenarios, "mobile")
        except Exception:
            reporter.emit("fail", "client_mobile", "mobile client world crashed", traceback.format_exc())

    # -- summary -----------------------------------------------------------------------------------
    elapsed = time.time() - started
    print(
        "\nsmoke test: %d passed, %d failed, %d warnings  (%.1fs)"
        % (reporter.oks, reporter.fails, reporter.warns, elapsed)
    )
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(reporter.records, fh, indent=2)
    failed = reporter.fails > 0 or (args.strict and reporter.warns > 0)
    return 1 if failed else 0


def replication_to_client(rt, server, replication):
    """The server world exports its replication log as a Lua table; client Lua just reads it, but it
    lives in another runtime, so copy it through plain Python data."""
    data = lua_to_py(replication)
    return to_lua(rt, data)


if __name__ == "__main__":
    sys.exit(main())
