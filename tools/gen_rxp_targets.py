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
FRIENDLY_RE = re.compile(r"\|cRXP_FRIENDLY_([^|:]+)(?:::\d+)?\|r")
MAP_RE = re.compile(r'\["([^"]+)"\]\s*=\s*(\d+)\s*,')
MAP_IDS = {}            # zone name -> UiMapID (RXPGuides DB/*/db.lua addon.mapId)


def load_map_ids(root):
    """Zone name -> UiMapID from RestedXP's own tables (classic, tbc, forever)."""
    for sub_db in ("classic", "tbc", "forever"):
        path = os.path.join(root, "DB", sub_db, "db.lua")
        try:
            txt = open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for name, mid in MAP_RE.findall(txt):
            mid = int(mid)
            if 1400 <= mid < 2000:
                MAP_IDS.setdefault(name, mid)


def world_anchor(parts):
    """2.211.0: ".goto <zone>/<continent>,a,b" - RestedXP hands a, b to
    HereBeDragons' GetZoneCoordinatesFromWorld: WORLD coordinates in
    (world y, world x) order. Returns (world x, world y) or None."""
    if len(parts) < 3 or "/" not in parts[0]:
        return None
    try:
        a, b = float(parts[1]), float(parts[2])
    except ValueError:
        return None
    return (round(b, 1), round(a, 1))


def goto_anchor(parts):
    """(map, x 0-1, y 0-1) from a .goto line's arguments, or None."""
    if len(parts) < 3 or "/" in parts[0]:
        return None
    zone = parts[0]
    mid = int(zone) if zone.isdigit() else MAP_IDS.get(zone)
    try:
        x, y = float(parts[1]), float(parts[2])
    except ValueError:
        return None
    if not mid or not (0 <= x <= 100 and 0 <= y <= 100):
        return None
    return (mid, round(x / 100, 4), round(y / 100, 4))


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


ITEM_NAME_RE = re.compile(r"\[([^\]|]+)\]")


def parse(path, by_quest, by_obj, ids_by_quest, steps_out=None, givers=None, items=None):
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return

    def flush(step):
        # 2.206.0: NPC steps - vendor / trainer npc ids, gossip choices, anchored
        # by the step's .goto points so the engine can match its live step.
        if steps_out is not None and (step["anchors"] or step["wanchors"]) and (
                step["vendor"] or step["trainer"] or step["gossip"] or step["skip"] is not None):
            steps_out.append({"p": step["anchors"][:4], "w": step["wanchors"][:4], "v": step["vendor"],
                              "t": step["trainer"], "g": sorted(step["gossip"]), "s": step["skip"]})
        # 2.215.0: each .accept / .turnin goes to ITS .target line, by role -
        # givers for accept, takers for turnin. A step that talks to two NPCs
        # no longer lists both for every quest in it (Grelin Whitebeard was a
        # "giver" of Scalding Mornbrew Delivery that way). Guides use two
        # layouts: quest lines, .goto, .target (target AFTER its quests) and
        # .goto, .target, quest lines (target BEFORE). A .target ahead of the
        # step's first quest line means the second; each quest then takes the
        # nearest target on that side, and the other side only when there is
        # none. No .target at all: the step text's friendly names.
        if givers is not None:
            ev = step["events"]
            first_d = next((i for i, e in enumerate(ev) if e[0] == "d"), None)
            first_t = next((i for i, e in enumerate(ev) if e[0] == "t"), None)
            before = first_t is not None and first_d is not None and first_t < first_d
            for i, e in enumerate(ev):
                if e[0] != "d":
                    continue
                prev = next((ev[j][1] for j in range(i - 1, -1, -1) if ev[j][0] == "t"), None)
                nxt = next((ev[j][1] for j in range(i + 1, len(ev)) if ev[j][0] == "t"), None)
                names = (prev or nxt) if before else (nxt or prev)
                names = names or step["text_friendly"]
                if names:
                    givers.setdefault(e[2], {}).setdefault(e[1], set()).update(names)
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
            step = {"quests": [], "names": set(), "ids": set(), "anchors": [], "wanchors": [], "vendor": None,
                    "trainer": None, "gossip": set(), "skip": None, "dialog": set(), "friendly": set(),
                    "events": [], "text_friendly": set()}
            continue
        if step is None:
            continue
        line = re.sub(r"\s*<<.*$", "", line)          # class / faction tags
        line = re.sub(r"\s*--.*$", "", line)          # comments
        m = re.match(r"^\.(\w+)\s*(.*)$", line)
        if m and items is not None and m.group(1) in ("destroy", "equip"):
            # 2.209.0: ".destroy <item>" / ".equip <slot>,<item>" - item name (the
            # [bracket] in the >> text, which the API's goal text carries) -> id.
            tag_i, rest = m.group(1), m.group(2)
            head = re.sub(r"\s*>>.*$", "", rest)
            nums = [x.strip() for x in head.split(",") if x.strip()]
            names = ITEM_NAME_RE.findall(rest)
            if names:
                rec = None
                if tag_i == "destroy" and nums and nums[0].isdigit():
                    rec = {"id": int(nums[0])}
                elif tag_i == "equip" and len(nums) >= 2 and nums[0].lstrip("-").isdigit() and nums[1].isdigit():
                    rec = {"id": int(nums[1]), "slot": abs(int(nums[0]))}
                if rec:
                    items.setdefault(names[0].strip(), rec)
        if m:
            tag, args = m.group(1), m.group(2)
            args = re.sub(r"\s*>>.*$", "", args)
            parts = [a.strip() for a in args.split(",") if a.strip()]
            if tag == "complete" and len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
                step["quests"].append((int(parts[0]), int(parts[1])))
            elif tag == "collect" and len(parts) >= 3 and parts[2].isdigit():
                step["quests"].append((int(parts[2]), None))
            elif tag in ("goto", "questgoto", "groundgoto"):
                a = goto_anchor(parts)
                if a and a not in step["anchors"]:
                    step["anchors"].append(a)
                w = world_anchor(parts)
                if w and w not in step["wanchors"]:
                    step["wanchors"].append(w)
            elif tag == "vendor" and parts and parts[0].isdigit():
                step["vendor"] = int(parts[0])
            elif tag == "trainer" and parts and parts[0].isdigit():
                step["trainer"] = int(parts[0])
            elif tag in ("gossipoption", "skipgossipid"):
                for p_ in parts:
                    if p_.lstrip("+").isdigit():
                        step["gossip"].add(int(p_.lstrip("+")))
            elif tag == "skipgossip":
                nums = [int(x) for x in parts if x.isdigit()]
                step["skip"] = nums                    # [] = pick the first option
            elif tag in ("accept", "turnin") and parts and parts[0].isdigit():
                step["dialog"].add(int(parts[0]))
                step["events"].append(("d", int(parts[0]), tag))
            if tag == "target":
                tnames = set()
                for p_ in parts:
                    p_ = re.sub(r"::\d+$", "", p_.lstrip("+*").strip())   # "Name::npcid"
                    if len(p_) >= 3 and not p_.isdigit():
                        step["friendly"].add(p_)
                        tnames.add(p_)
                if tnames:
                    step["events"].append(("t", tnames))
            if tag in TARGET_TAGS:
                for p in parts:
                    p = p.lstrip("+*").strip()          # + parent, * low priority (Targeting.lua)
                    if p.isdigit():
                        step["ids"].add(int(p))
                    elif len(p) >= 3:
                        step["names"].add(p)
        for name in FRIENDLY_RE.findall(raw):
            name = name.strip()
            if len(name) >= 3:
                step["friendly"].add(name)
                step["text_friendly"].add(name)
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
    steps, givers, items = [], {}, {}
    load_map_ids(root)
    n = 0
    for f in guide_files(root):
        parse(f, by_quest, by_obj, ids_by_quest, steps, givers, items)
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
    ]
    # SHARED NAME LISTS (2.220.0). 6883 name lists, 2377 distinct: every distinct
    # list is written once into L and the quest tables point at it - same
    # lookups, a third of the tables. Lists are read-only for every consumer.
    # M.by_objective (quest|objective -> names) is no longer written: nothing
    # reads it.
    pool, pool_idx = [], {}

    def ref(names):
        key = tuple(names)
        i = pool_idx.get(key)
        if i is None:
            pool.append(key)
            i = pool_idx[key] = len(pool)
        return f"L[{i}]"

    body = ["-- quest id -> { mob names }", "M.by_quest = {"]
    for q in sorted(by_quest):
        names = dedupe(by_quest[q])
        if names:
            body.append(f"    [{q}] = {ref(names)},")
    body += ["}", "", "-- quest id -> { npc ids } (numeric ids on target lines)", "M.ids_by_quest = {"]
    for q in sorted(ids_by_quest):
        ids = sorted(ids_by_quest[q])
        if ids:
            body.append(f"    [{q}] = {{ {', '.join(str(x) for x in ids)} }},")
    for role, label, title in (("accept", "M.givers", "gives (accept)"),
                               ("turnin", "M.takers", "takes (turn-in)")):
        table = givers.get(role, {})
        body += ["}", "",
                 f"-- quest id -> {{ friendly NPC names }} the guide's .target pairs with the quest:",
                 f"-- who {title} it (2.215.0, by role)",
                 f"{label} = {{"]
        for q in sorted(table):
            names = dedupe(table[q])
            if names:
                body.append(f"    [{q}] = {ref(names)},")
    lines += ["-- shared name lists, referenced as L[n] below (2.220.0)", "local L = {"]
    for key in pool:
        lines.append("    { " + ", ".join(lua_str(x) for x in key) + " },")
    lines += ["}", ""]
    lines += body
    lines += ["}", "",
              "-- NPC steps: p = { map, x, y, ... } anchors (UiMapID, 0-1), w = { x, y, ... } world",
              "-- anchors (\".goto zone/0,y,x\" lines), v / t = vendor /",
              "-- trainer npc id, g = gossip option ids, s = .skipgossip { npc, option, ... }",
              "-- ({} = first option).",
              "M.steps = {"]
    for st in steps:
        parts = []
        if st["p"]:
            flat = ", ".join(f"{m}, {x}, {y}" for (m, x, y) in st["p"])
            parts.append(f"p = {{ {flat} }}")
        if st["w"]:
            wflat = ", ".join(f"{x}, {y}" for (x, y) in st["w"])
            parts.append(f"w = {{ {wflat} }}")
        if st["v"]:
            parts.append(f"v = {st['v']}")
        if st["t"]:
            parts.append(f"t = {st['t']}")
        if st["g"]:
            parts.append("g = { " + ", ".join(str(x) for x in st["g"]) + " }")
        if st["s"] is not None:
            parts.append("s = { " + ", ".join(str(x) for x in st["s"]) + " }")
        lines.append("    { " + ", ".join(parts) + " },")
    lines += ["}", "", "-- .destroy / .equip item name -> { id = item id, slot = equip slot }", "M.items = {"]
    for name in sorted(items):
        rec = items[name]
        extra = f", slot = {rec['slot']}" if "slot" in rec else ""
        lines.append(f"    [{lua_str(name)}] = {{ id = {rec['id']}{extra} }},")
    lines += ["}", "", "return M", ""]
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    print(f"{n} guide files -> {OUT}: {len(by_quest)} quests, {len(by_obj)} objectives, "
          f"{len(givers.get('accept', {}))} giver / {len(givers.get('turnin', {}))} taker quests, {len(steps)} NPC steps, {len(MAP_IDS)} zone names, "
          f"{os.path.getsize(OUT):,} bytes")


if __name__ == "__main__":
    main()
