#!/usr/bin/env python3
"""Syntax-check Lua files with an embedded Lua interpreter (lupa).

Usage: python3 tools/syntax.py [files or dirs...]   (default: src)
Rejects Luau-only syntax because stock Lua cannot parse it (type annotations, `continue`, `+=`).
"""
import os
import sys

try:
    import lupa
except ImportError:
    sys.exit("pip install lupa")


def collect(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for f in sorted(files):
                    if f.endswith(".lua"):
                        yield os.path.join(root, f)
        else:
            yield p


def main():
    paths = sys.argv[1:] or ["src"]
    rt = lupa.LuaRuntime()
    load = rt.globals().load
    bad = 0
    n = 0
    for path in collect(paths):
        n += 1
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        res = load(src, "=" + path)
        if isinstance(res, tuple):
            fn, err = res[0], res[1] if len(res) > 1 else None
        else:
            fn, err = res, None
        if fn is None:
            bad += 1
            print("SYNTAX ERROR", err)
    print("checked %d files, %d with syntax errors" % (n, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
