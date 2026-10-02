"""Build data/rxp_targets.lua from the RestedXP guide files.

RestedXP's target frame (RXPTargetFrame, Targeting.lua) lists the mobs a step
names on its .mob / .target / .unitscan lines. Those names live in the
addon's element.unitlist, which core.addons.rested_xp does not expose - the
API gives each goal only action, quest_id, text, is_complete, text_only and
ids. So the pairing is read here, offline, from the guide source: every step
that has a .complete <quest>,<objective> or .collect <item>,<qty>,<quest> line
and target lines gives quest -> mob names (and quest|objective -> names).
Enemy names RestedXP colours in a step's ">>" text (|cRXP_ENEMY_...|r) count
too. Numeric ids on a target line are kept as npc ids.

Usage:
    python tools/gen_rxp_targets.py ["<path to RXPGuides>"]
"""
import os
import re
import sys

DEFAULT = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\RXPGuides"
# Retail-era guides use quest ids and mobs this bot never meets.
SKIP_DIRS = {"Retail", "cata", "mop", "Talents", "Dailies"}
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "rxp_targets.lua")

TARGET_TAGS = ("mob", "target", "unitscan")
ENEMY_RE = re.compile(r"\|cRXP_ENEMY_([^|]+)\|r")


def plural_to_singular(name):
    """RestedXP's >> text says "Ragged Young Wolves"; the unit is "...Wolf"."""
    for a, b in (("olves", "olf"), ("ies", "y"), ("men", "man")):
        if name.endswith(a):
            return name[: -len(a)] + b
    if name.endswith("s") and not name.endswith("ss"):
        return name[:-1]
    return name


def guide_files(root):
    guides = os.path.join(root, "Guides")
    for dirpath, dirnames, filenames in os.walk(guides):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for f in filenames:
            if f.endswith(".lua"):
                yield os.path.join(dirpath, f)


def parse(path, by_quest, by_obj, ids_by_quest):
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return

    def flush(step):
        if not step["quests"] or not (step["names"] or step["ids"]):
            return
        for q, obj in step["quests"]:
            by_quest.setdefault(q, set()).update(step["names"])
            ids_by_quest.setdefault(q, set()).update(step["ids"])
            if obj is not None:
                by_obj.setdefault((q, obj), set()).update(step["names"])

    step = None
    for raw in text.splitlines():
        line = raw.strip()
        if line == "step" or line.startswith("step "):
            if step:
                flush(step)
            step = {"quests": [], "names": set(), "ids": set()}
            continue
        if step is None:
            continue
        line = re.sub(r"\s*<<.*$", "", line)          # class / faction tags
        line = re.sub(r"\s*--.*$", "", line)          # comments
        m = re.match(r"^\.(\w+)\s*(.*)$", line)
        if m:
            tag, args = m.group(1), m.group(2)
            args = re.sub(r"\s*>>.*$", "", args)
            parts = [a.strip() for a in args.split(",") if a.strip()]
            if tag == "complete" and len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
                step["quests"].append((int(parts[0]), int(parts[1])))
            elif tag == "collect" and len(parts) >= 3 and parts[2].isdigit():
                step["quests"].append((int(parts[2]), None))
            elif tag in TARGET_TAGS:
                for p in parts:
                    p = p.lstrip("+").strip()
                    if p.isdigit():
                        step["ids"].add(int(p))
                    elif len(p) >= 3:
                        step["names"].add(p)
        for name in ENEMY_RE.findall(raw):
            name = name.strip()
            if len(name) >= 3:
                step["names"].add(plural_to_singular(name))
    if step:
        flush(step)


def dedupe(names):
    """One spelling per name, case-insensitively (the guide's own wins)."""
    seen = {}
    for n in sorted(names, key=lambda x: (x.lower(), x != x.title(), x)):
        seen.setdefault(n.lower(), n)
    return sorted(seen.values())


def version():
    try:
        txt = open(os.path.join(os.path.dirname(OUT), "..", "version.lua"), encoding="utf-8").read()
        m = re.search(r'version\s*=\s*"([\d.]+)"', txt)
        return m.group(1) if m else "0.0.0"
    except OSError:
        return "0.0.0"


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    by_quest, by_obj, ids_by_quest = {}, {}, {}
    n = 0
    for f in guide_files(root):
        parse(f, by_quest, by_obj, ids_by_quest)
        n += 1
    lines = [
        "-- ============================================================================",
        "-- Master Farmer - Grindbot",
        "-- RestedXP target mobs per quest (GENERATED - tools/gen_rxp_targets.py)",
        "-- ============================================================================",
        "-- Authors: BLIZZ - Anthonyk",
        f"-- Version: {version()}",
        "-- Folder: Master_Farmer_Grindbot",
        "-- ============================================================================",
        "-- The mobs RestedXP's target frame shows for a quest objective, read from the",
        "-- guide files' .mob / .target / .unitscan lines and RXP_ENEMY names. The API",
        "-- does not expose them (element.unitlist). Regenerate after a RestedXP update.",
        f"-- {n} guide files, {len(by_quest)} quests.",
        "-- ============================================================================",
        "",
        "local M = {}",
        "",
        "-- quest id -> { mob names }",
        "M.by_quest = {",
    ]
    for q in sorted(by_quest):
        names = dedupe(by_quest[q])
        if names:
            lines.append(f"    [{q}] = {{ {', '.join(lua_str(x) for x in names)} }},")
    lines += ["}", "", "-- \"quest|objective\" -> { mob names }", "M.by_objective = {"]
    for (q, o) in sorted(by_obj):
        names = dedupe(by_obj[(q, o)])
        if names:
            lines.append(f"    [\"{q}|{o}\"] = {{ {', '.join(lua_str(x) for x in names)} }},")
    lines += ["}", "", "-- quest id -> { npc ids } (numeric ids on target lines)", "M.ids_by_quest = {"]
    for q in sorted(ids_by_quest):
        ids = sorted(ids_by_quest[q])
        if ids:
            lines.append(f"    [{q}] = {{ {', '.join(str(x) for x in ids)} }},")
    lines += ["}", "", "return M", ""]
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    print(f"{n} guide files -> {OUT}: {len(by_quest)} quests, {len(by_obj)} objectives, "
          f"{os.path.getsize(OUT):,} bytes")


if __name__ == "__main__":
    main()
