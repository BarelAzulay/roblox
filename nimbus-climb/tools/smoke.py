#!/usr/bin/env python3
"""Smoke test for Nimbus Climb v2: runs the real Lua modules against a Roblox mock (tools/robloxmock.lua).

    pip install lupa
    python3 tools/smoke.py [--only SCENARIO[,SCENARIO...]] [--seeds N] [--quick] [-v] [--strict] [--json FILE] [--echo]

Two Lua worlds are booted (each its own state, so server and client cannot cheat by sharing globals):

  server world   smoke_server.lua   mock self-test, module loading, contract.json API check, boot of Main.server.lua, lobby,
                                    players, portals, damage rules, the fall rule (landing on a lower lap), the match lifecycle
                                    (victory / defeat / timeout / abandon / leave / death / concurrent slots), persistence, DataStore
                                    orphans (leaving during an outage), shutdown, whole-run invariants
                 smoke_content.lua  PetCatalog / ItemCatalog / roulette odds, Config shape, PetBuilder for every pet
                 smoke_course.lua   5 difficulties x N seeds of GenerateLayout + ValidateLayout + an independent audit with
                                    per-difficulty statistics, cannon ballistics, CourseBuilder.Build (budget, tags, attributes)
                 smoke_economy.lua  spots, DataService / PetService economy, items, match locks (items in the countdown, pets in
                                    matches), ProfileSync shape, v1 -> v2 migration,
                                    the match lifecycle on all five difficulties, pet perks inside matches
                 smoke_hazards.lua  HazardService on real generated courses (incl. pendulum, wind, cannon, golden tokens) and the
                                    TokenService no-animation rule (Config.Tokens.ClientAnimated)
  both worlds    smoke_dev.lua      owner-only developer tools (DevService / DevController)
                 smoke_storm.lua    the Stormfang round: pet elements and the damage chart, the Stormfang pet (catalog +
                                    PetBuilder High / Low), the Storm Altar on the real lobby (budget, overlaps, bridge
                                    walk, rate-limited toast), and on the client the element pills, the Index art banner
                                    and ShowcaseController
  client world   smoke_client.lua   Main.client.lua boot, movement, HUD, toasts / results, damage fx, replay of the exact
                                    server traffic, final invariants, touch layout (390x844 phone)
                 smoke_client_v2.lua CloudUI kit, State, menu + windows + roulette reveal, hotbar, pet followers, TokenFx
                                    (client coin spin/bob), and the "no text in the middle of the screen" rule at 1920x1080 and 390x844

`--list` prints the scenario names. Every tools/smoke_*.lua must be listed in `server_files` / `client_files` below and every
scenario function must be listed in the scenario lists (smoke.py reports a failure otherwise). A scenario that crashes or runs
longer than --scenario-timeout seconds is reported as one failed check; the other scenarios still run.

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
                            "Echo": bool(getattr(args, "echo", False)),
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
    ap.add_argument("--echo", action="store_true", help="print the game's print() / warn() output and script errors as they happen (debugging)")
    ap.add_argument("--strict-members", action="store_true", help="unknown Instance members raise errors (like Roblox) instead of being recorded")
    ap.add_argument("--engine", help="lupa engine (luajit21, lua54, ...) default: luajit21")
    ap.add_argument("--fps", type=float, default=30.0, help="simulation steps per fake second (default 30)")
    ap.add_argument("--scenario-timeout", type=float, default=600.0, help="real seconds one scenario may run before it is aborted (default 600)")
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
            "boot", "lobby", "players", "spots", "economy", "items", "match_locks", "profile_sync", "migration", "portals", "damage_rules",
            "fall_rule", "match_victory", "match_defeat", "match_timeout", "match_abandon", "match_leave", "match_death",
            "match_slots", "match_difficulties", "match_pets", "hazards", "persistence", "data_orphans", "dash_relay", "shutdown",
            "final_checks",
        ]
    )
    server_files = ["smoke_server.lua", "smoke_content.lua", "smoke_course.lua", "smoke_economy.lua", "smoke_hazards.lua"]
    client_scenarios = [
        "client_load", "client_ui_kit", "client_state", "client_input", "client_hud", "client_notify", "client_damage",
        "client_menu", "client_hotbar", "client_pets", "client_tokens", "client_layout_rule", "client_replay", "client_final",
    ]
    mobile_scenarios = ["client_mobile"]
    client_files = ["smoke_client.lua", "smoke_client_v2.lua"]
    server_files.append("smoke_dev.lua"); client_files.append("smoke_dev.lua"); server_scenarios.insert(server_scenarios.index("final_checks"), "dev_tools"); client_scenarios.insert(client_scenarios.index("client_final"), "client_dev"); mobile_scenarios.append("client_dev_mobile")  # owner-only developer tools (smoke_dev.lua: both worlds, ARGS.context picks the half)
    # the Stormfang round (smoke_storm.lua: both worlds, ARGS.context picks the half): elements + the Stormfang pet are
    # content scenarios (after petbuilder), the Storm Altar runs on the booted lobby (after lobby), client_storm checks
    # the element pills, the Index art banner and ShowcaseController
    server_files.append("smoke_storm.lua"); client_files.append("smoke_storm.lua")
    pure_scenarios += ["storm_elements", "storm_pet"]
    server_scenarios[server_scenarios.index("petbuilder") + 1:server_scenarios.index("petbuilder") + 1] = ["storm_elements", "storm_pet"]
    server_scenarios.insert(server_scenarios.index("lobby") + 1, "storm_altar")
    client_scenarios.insert(client_scenarios.index("client_final"), "client_storm")
    server_files.append("smoke_polish_portals.lua"); client_files.append("smoke_polish_portals.lua"); server_scenarios.insert(server_scenarios.index("final_checks"), "polish_portals"); client_scenarios.insert(client_scenarios.index("client_final"), "client_polish_portals"); mobile_scenarios.append("client_polish_portals_mobile")  # portal lock-in + outside countdown (smoke_polish_portals.lua: both worlds)
    client_files.append("smoke_polish_guitool.lua"); client_scenarios.insert(client_scenarios.index("client_final"), "client_gui_dump")  # offline GUI renderer: tools/dump_gui.lua walks PlayerGui + the widget gallery (smoke_polish_guitool.lua: client world)
    client_files.append("smoke_polish_vitals.lua"); client_scenarios.insert(client_scenarios.index("client_final"), "client_polish_vitals"); mobile_scenarios.append("client_polish_vitals_mobile"); mobile_scenarios.append("client_polish_matchpanel_mobile")  # HP / stamina vitals card + the match panel on touch screens (smoke_polish_vitals.lua: client + phone worlds)
    server_files.append("smoke_polish_worldtext.lua"); client_files.append("smoke_polish_worldtext.lua"); server_scenarios.insert(server_scenarios.index("final_checks"), "polish_worldtext"); client_scenarios.insert(client_scenarios.index("client_final"), "client_polish_worldtext")  # World text rule: census of every BillboardGui / SurfaceGui, home nameplates (smoke_polish_worldtext.lua: both worlds)
    server_files.append("smoke_polish_data.lua"); server_scenarios[server_scenarios.index("shutdown"):server_scenarios.index("shutdown")] = ["polish_data_outage", "polish_data_dev_reset", "polish_data_fwdcompat"]  # save-system release fixes: provisional failed loads, dev reset overwrite, forward-compatible saves (smoke_polish_data.lua: server world only, before shutdown so the autosave / orphan retries still run)
    client_files.append("smoke_release_client.lua"); client_scenarios[client_scenarios.index("client_final"):client_scenarios.index("client_final")] = ["client_release_pets", "client_release_roulette"]; mobile_scenarios.append("client_release_touch_mobile")  # release pass (client): welded pet followers + build time budgets, Low roulette strip + pre-sculpted pools, touch menu vs thumbstick, tutorial vs HP card, menu pointer (smoke_release_client.lua: client + phone worlds)
    if args.list:
        print("server:", ", ".join(server_scenarios))
        print("client:", ", ".join(client_scenarios + mobile_scenarios))
        print("files: ", ", ".join(["smoke_common.lua"] + server_files + client_files))
        return 0

    # every tools/smoke_*.lua must be loaded by one of the worlds, otherwise its scenarios silently never run
    wired = set(server_files + client_files + ["smoke_common.lua"])
    for name in sorted(os.listdir(HERE)):
        if name.startswith("smoke_") and name.endswith(".lua") and name not in wired:
            reporter.emit("fail", "smoke.py", "tools/%s is not wired into smoke.py" % name, "add it to server_files / client_files in tools/smoke.py")

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
        if "cannon" in only:
            only |= {"layouts"}  # the cannon audit reads the cannons the layouts scenario collected

    def wanted(name):
        return only is None or name in only

    run_server = any(wanted(n) for n in server_scenarios)
    run_client = any(wanted(n) for n in client_scenarios + mobile_scenarios)
    # the client replay feeds on the traffic of the whole server run
    if only is not None and wanted("client_replay") and not any(n in only for n in server_scenarios):
        run_server = True
        only = only | set(server_scenarios)

    def check_listed(table, names, label):
        """A scenario function that exists in the Lua files but is not in the lists above would never run."""
        listed = set(names) | {"export_replication"}
        for key in list(table.keys()):
            if isinstance(key, str) and key not in listed:
                reporter.emit("fail", "smoke.py", "%s scenario '%s' is defined but not listed in tools/smoke.py" % (label, key), "add it to the scenario lists")

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
            # a runaway scenario (or a game function it calls) is aborted instead of hanging the whole suite
            world.Mock["Deadline"] = world.Mock.RealClock() + args.scenario_timeout
            try:
                fn()
            except Exception as exc:  # a Lua error escaping a scenario (guarded() normally catches them)
                reporter.emit("fail", name, "scenario crashed", str(exc))
            world.Mock["Deadline"] = None
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
            check_listed(S, server_scenarios, "server")
            run_scenarios(server, S, server_scenarios, "server")
            replication = S["export_replication"]() if S["export_replication"] else None
        except Exception:
            reporter.emit("fail", "server", "server world crashed", traceback.format_exc())

    # -- client world ----------------------------------------------------------------------------
    if run_client and any(wanted(n) for n in client_scenarios):
        try:
            client = World(engine, engine_name, "client", args, api, contract, viewport=(1920, 1080))
            C = client.load_scenarios(client_files)
            check_listed(C, client_scenarios + mobile_scenarios, "client")
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
