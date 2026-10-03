#!/usr/bin/env python3
"""
Build a local, versioned copy of the plugin to test in game BEFORE pushing.

    python make_local.py                # -> Desktop/SNES_/Master_Farmer_Grindbot_v<version>/
    python make_local.py --force        # rebuild a version folder that exists
    python make_local.py --check        # syntax check only, copy nothing
    python make_local.py --dest D:/wow/scripts/Master_Farmer_Grindbot_test

Steps, in order, stopping at the first failure:

  1. Syntax-check every .lua that would be copied (needs `pip install luaparser`).
     A file that does not parse would fail the whole plugin load in game.
  2. Regenerate manifest.lua (make_manifest.py), so the copy and the eventual
     push carry the same hashes.
  3. Copy the plugin into the version folder. Copy-forward, per VERSIONING.md:
     an existing version folder is never overwritten without --force.

Not copied: plugin_loader/ and plugin_loader.zip (the loader fetches from
GitHub, which is exactly what a local test must not do), bootstrap/, .git,
the .bak_* snapshots and *.bak files. Files are taken from git's view of the
working tree - tracked plus new untracked ones, minus .gitignore'd and deleted
ones - so the copy is what the next commit will contain.

Load the resulting folder in Sylvanas in place of the loader plugin, test, and
only then commit and push.
"""

import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))

SKIP_PREFIX = ("plugin_loader/", "bootstrap/", ".bak_", ".git/", ".claude/")
SKIP_FILES = {"plugin_loader.zip", "make_local.py"}
SKIP_SUFFIX = (".bak", ".orig", ".rej", ".zip", ".7z", ".rar")


def version_of():
    with open(os.path.join(ROOT, "version.lua"), encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("version") and '"' in s:
                return s.split('"')[1]
    raise SystemExit("version.lua has no version field")


def files():
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, capture_output=True, text=True, check=True).stdout
    keep = []
    for rel in out.splitlines():
        rel = rel.strip().replace("\\", "/")
        if not rel or rel in SKIP_FILES or rel.startswith(SKIP_PREFIX):
            continue
        if rel.endswith(SKIP_SUFFIX):
            continue
        if not os.path.isfile(os.path.join(ROOT, rel)):
            continue  # deleted in the working tree, not yet committed
        keep.append(rel)
    return sorted(keep)


def syntax_check(paths):
    try:
        from luaparser import ast
    except ImportError:
        raise SystemExit("luaparser is not installed: pip install luaparser")
    # A real Lua compiler as well, when lupa is installed (2.65.0): luaparser
    # accepted a newline inside a quoted string, which the game rejects.
    # THE CLIENT'S LUA IS 5.1-SHAPED (2.218.0): 2.215.0 gave quest/engine.lua's
    # tick_inner a 61st upvalue - fine in Lua 5.4 (limit 255), "function at line
    # 2888 has more than 60 upvalues" in Lua 5.1 and LuaJIT - and nothing loaded
    # in game. Every file is now compiled by Lua 5.1 and LuaJIT 2.1 too.
    compilers = []
    for mod_name, label in (("lupa", "lua"), ("lupa.lua51", "lua5.1"), ("lupa.luajit21", "luajit2.1")):
        try:
            mod = __import__(mod_name, fromlist=["LuaRuntime"])
            rt = mod.LuaRuntime()
            compilers.append((label, rt.eval(
                "function(src, name) local f, err = (loadstring or load)(src, '@' .. name) return err end")))
        except Exception:
            if label != "lua":
                print("  NOTE    %s compiler unavailable (pip install -U lupa) - not checked" % label)
    compile_fn = compilers[0][1] if compilers else None
    bad = 0
    lua = [p for p in paths if p.endswith(".lua")]
    for rel in lua:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
            src = fh.read()
        try:
            ast.parse(src)
        except Exception as exc:  # luaparser raises several error types
            bad += 1
            print("  SYNTAX  %s: %s" % (rel, str(exc).splitlines()[0][:200]))
            continue
        for label, fn in compilers:
            err = fn(src, rel)
            if err:
                bad += 1
                print("  COMPILE [%s] %s: %s" % (label, rel, str(err)[:200]))
                break
    print("syntax: %d .lua file(s), %d failed" % (len(lua), bad))
    return bad == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--dest", help="target folder (default ../Master_Farmer_Grindbot_v<version>)")
    ap.add_argument("--force", action="store_true", help="replace an existing target folder")
    ap.add_argument("--check", action="store_true", help="syntax check only")
    args = ap.parse_args()

    version = version_of()
    paths = files()

    if not syntax_check(paths):
        return 1
    if args.check:
        return 0

    subprocess.run([sys.executable, os.path.join(ROOT, "make_manifest.py")], cwd=ROOT, check=True)

    # Version folders live in Desktop/SNES_. Once this repo sits inside SNES_,
    # that folder is the parent. Until then, SNES_ is the sibling of the repo.
    parent = os.path.dirname(ROOT)
    if os.path.basename(parent) == "SNES_":
        home = parent
    else:
        home = os.path.join(parent, "SNES_")
    dest = args.dest or os.path.join(home, "Master_Farmer_Grindbot_v" + version)
    dest = os.path.abspath(dest)
    if os.path.exists(dest):
        if not args.force:
            print("%s already exists. Bump version.lua for a new build, or pass --force." % dest)
            return 1
        shutil.rmtree(dest)

    for rel in paths:
        src = os.path.join(ROOT, rel)
        dst = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
    print("v%s: %d files -> %s" % (version, len(paths), dest))
    return 0


if __name__ == "__main__":
    sys.exit(main())
