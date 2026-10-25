"""Build data/rxp_steps.lua - the ACTION of every RestedXP guide step the bot
must carry out itself, with every id the guide line gives.

4.25.0 (user: "Always check the step action that should be completed and
complete that action. Use the Addon folder to get ALL of the needed itemid,
npc ID create table databases for every single step to ensure all steps get
completed"). A survey of the TBC / Classic guides (98 files, 44 528 steps)
found the step actions the engine had no handler for: .cast / .usespell
(spell ids, often aimed at a named NPC), .abandon (quest ids), .emote (token,
npc id), .tame (npc ids), .bankdeposit / .bankwithdraw (item ids),
.deathskip, .skipgossip. Every step with one of them becomes a row:

    { p = { map, x, y, ... },   the step's .goto points (UiMapID, 0-1)
      q = { quest ids },         the step's accept / turnin / complete quests
      a = { { t = "cast", ids = { 818 }, to = "Narm Faulk" }, ... },
      n = { names },             the step's .target / RXP_FRIENDLY names
      m = { names } }            its .mob / RXP_ENEMY names

The engine matches the live step by quest id + action first, then by its
waypoint (as data/rxp_targets M.steps). Item / npc / spell ids come from the
guide lines themselves (".cast 8593", ".emote salute,3401", ".tame 2163",
".bankdeposit 2784,5849").

    python tools/gen_rxp_steps.py ["<path to RXPGuides>"]
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_rxp_targets as G   # noqa: E402  (load_map_ids, goto_anchor, guide_files)

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "rxp_steps.lua")
ACTION_TAGS = {"cast", "usespell", "abandon", "emote", "tame", "bankdeposit", "bankwithdraw", "deathskip", "skipgossip",
               "skipgossipid"}
QUEST_TAGS = {"accept", "turnin", "complete", "isOnQuest", "isQuestComplete"}
FRIENDLY_RE = re.compile(r"\|cRXP_FRIENDLY_([^|:]+)(?:::\d+)?\|r")
ENEMY_RE = re.compile(r"\|cRXP_ENEMY_([^|:]+)(?:::\d+)?\|r")
SKIP_PARTS = {"SoD"}


def ids_of(text):
    return [int(x) for x in re.findall(r"-?\d+", text.split(">>")[0]) if int(x) > 0]


def parse(path, rows, stats):
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return
    step = None

    def flush(st):
        if not st or not st["a"]:
            return
        rows.append(st)
        for a in st["a"]:
            stats[a["t"]] = stats.get(a["t"], 0) + 1

    for raw in text.splitlines():
        line = raw.strip()
        if line == "step" or line.startswith("step "):
            flush(step)
            step = {"p": [], "q": [], "a": [], "n": [], "m": []}
            continue
        if step is None:
            continue
        if not line.startswith("."):
            for nm in FRIENDLY_RE.findall(line):
                if nm not in step["n"]:
                    step["n"].append(nm)
            for nm in ENEMY_RE.findall(line):
                if nm not in step["m"]:
                    step["m"].append(nm)
            continue
        body = line[1:].split("--")[0]
        tag, _, rest = body.partition(" ")
        rest = rest.strip()
        for nm in FRIENDLY_RE.findall(rest):
            if nm not in step["n"]:
                step["n"].append(nm)
        for nm in ENEMY_RE.findall(rest):
            if nm not in step["m"]:
                step["m"].append(nm)
        if tag in ("goto", "groundgoto"):
            a = G.goto_anchor([p.strip() for p in rest.split(",")])
            if a and len(step["p"]) < 12:
                step["p"].extend(a)
        elif tag in QUEST_TAGS:
            for q in ids_of(rest)[:1]:
                if q not in step["q"]:
                    step["q"].append(q)
        elif tag in ("target", "mob", "unitscan"):
            dest = step["n"] if tag == "target" else step["m"]
            for nm in [n.strip().lstrip("+") for n in rest.split(">>")[0].split(",") if n.strip()]:
                if not nm.isdigit() and nm not in dest:
                    dest.append(nm)
        elif tag in ACTION_TAGS:
            rec = {"t": "cast" if tag == "usespell" else ("skipgossip" if tag == "skipgossipid" else tag)}
            if tag == "emote":
                parts = [p.strip() for p in rest.split(">>")[0].split(",")]
                rec["token"] = parts[0].upper() if parts and parts[0] else "WAVE"
                ids = [int(x) for x in parts[1:] if x.isdigit()]
                if ids:
                    rec["ids"] = ids
            else:
                ids = ids_of(rest)
                if ids:
                    rec["ids"] = ids
            to = FRIENDLY_RE.findall(rest) or ENEMY_RE.findall(rest)
            if to:
                rec["to"] = to[0]
            step["a"].append(rec)
    flush(step)


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_list(v):
    return "{ " + ", ".join(lua_str(x) if isinstance(x, str) else repr(x) for x in v) + " }"


def version():
    try:
        txt = open(os.path.join(os.path.dirname(OUT), "..", "version.lua"), encoding="utf-8").read()
        m = re.search(r'version\s*=\s*"([\d.]+)"', txt)
        return m.group(1) if m else "0.0.0"
    except OSError:
        return "0.0.0"


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else G.DEFAULT
    G.load_map_ids(root)
    rows, stats, n = [], {}, 0
    for f in G.guide_files(root):
        if any(os.sep + s + os.sep in f or "/" + s + "/" in f.replace("\\", "/") for s in SKIP_PARTS):
            continue
        parse(f, rows, stats)
        n += 1
    # dedupe identical rows (the same step appears in several guides)
    seen, uniq = set(), []
    for r in rows:
        key = repr((r["p"][:3], r["q"], r["a"]))
        if key in seen:
            continue
        seen.add(key)
        uniq.append(r)
    lines = [
        "-- ============================================================================",
        "-- restedXP_questing",
        "-- Guide step ACTIONS with their ids (GENERATED - tools/gen_rxp_steps.py)",
        "-- ============================================================================",
        "-- Authors: BLIZZ - Anthonyk",
        f"-- Version: {version()}",
        "-- Folder: restedXP_questing",
        "-- ============================================================================",
        "-- Each row: p = { map, x, y, ... } .goto points, q = { quest ids }, a = { action },",
        "-- n = friendly names, m = enemy names. Actions: " + ", ".join(f"{k} {v}" for k, v in sorted(stats.items())) + ".",
        f"-- {n} guide files, {len(uniq)} steps with an action the bot carries out.",
        "-- ============================================================================",
        "",
        "return {",
    ]
    for r in uniq:
        acts = []
        for a in r["a"]:
            parts = [f't = {lua_str(a["t"])}']
            if a.get("ids"):
                parts.append("ids = " + lua_list(a["ids"]))
            if a.get("token"):
                parts.append("token = " + lua_str(a["token"]))
            if a.get("to"):
                parts.append("to = " + lua_str(a["to"]))
            acts.append("{ " + ", ".join(parts) + " }")
        parts = ["p = " + lua_list(r["p"])] if r["p"] else []
        if r["q"]:
            parts.append("q = " + lua_list(r["q"]))
        parts.append("a = { " + ", ".join(acts) + " }")
        if r["n"]:
            parts.append("n = " + lua_list(r["n"][:6]))
        if r["m"]:
            parts.append("m = " + lua_list(r["m"][:6]))
        lines.append("    { " + ", ".join(parts) + " },")
    lines += ["}", ""]
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    print(f"{n} guide files -> {OUT}: {len(uniq)} action steps {stats}, {os.path.getsize(OUT):,} bytes")


if __name__ == "__main__":
    main()
