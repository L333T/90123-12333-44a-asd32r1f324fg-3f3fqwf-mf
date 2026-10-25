"""Build data/rxp_vendors.lua - every vendor RestedXP's guides send the player to.

4.16.0 (user: "Get all vendor locations from the addon RXPGuides. When bags
are full, make vendor run"). Each guide step with a .vendor line is a vendor
stop: its .goto point (UiMapID + 0-1 map position; the bot converts it with
core.game_ui.get_world_pos_from_map_pos at run time, no ray), the NPC's name
(.target line, else the step's |cRXP_FRIENDLY_<name>|r), the npc id when the
.vendor line names one, and the guide's faction (its "<< Alliance" /
"<< Horde" header line, else the file name). Forever guides are marked so
the TBC client never walks to a Forever-only vendor and the other way round.
Duplicates (same name, map and a point within 0.5 % of the map) are merged.

Usage:
    python tools/gen_rxp_vendors.py ["<path to RXPGuides>"]
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_rxp_targets as G   # noqa: E402  (load_map_ids, goto_anchor, guide_files, MAP_IDS)

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "rxp_vendors.lua")
FRIENDLY_RE = re.compile(r"\|cRXP_FRIENDLY_([^|:]+)(?:::\d+)?\|r")
SEASON_ONLY = {"Rune Broker"}          # Season of Discovery NPCs in season-gated steps of the Classic guides
FACTION_RE = re.compile(r"^\s*<<\s*(Alliance|Horde)\b")


def faction_of(path, text):
    for line in text.splitlines()[:40]:
        m = FACTION_RE.match(line)
        if m:
            return m.group(1)[0]           # "A" / "H"
    base = os.path.basename(path).lower()
    if "alliance" in base or base.startswith("a-") or "(a)" in base:
        return "A"
    if "horde" in base or base.startswith("h-") or "(h)" in base:
        return "H"
    return "N"                             # both


def parse(path, out):
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return
    fac = faction_of(path, text)
    forever = os.sep + "Forever" + os.sep in path or "/Forever/" in path.replace("\\", "/")
    step = None

    def flush(st):
        if not st or not st["vendor"] or not st["goto"]:
            return
        name = st["target"] or st["friendly"]
        if not name or name.strip() in SEASON_ONLY:
            return
        mid, x, y = st["goto"]
        out.append({"name": name.strip(), "id": st["vid"], "m": mid, "x": x, "y": y, "f": fac,
                    "forever": forever})

    for raw in text.splitlines():
        line = raw.strip()
        if line == "step" or line.startswith("step "):
            flush(step)
            step = {"vendor": False, "vid": None, "goto": None, "target": None, "friendly": None}
            continue
        if step is None:
            continue
        if line.startswith("."):
            body = line[1:].split("--")[0]
            tag, _, rest = body.partition(" ")
            rest = rest.strip()
            if tag in ("goto", "groundgoto"):
                a = G.goto_anchor([p.strip() for p in rest.split(",")])
                if a:
                    step["goto"] = a                 # the LAST point of the step: the NPC's spot
            elif tag == "vendor":
                step["vendor"] = True
                first = rest.split(" ")[0] if rest else ""
                if first.isdigit():
                    step["vid"] = int(first)
            elif tag == "target":
                names = [n.strip().lstrip("+") for n in rest.split(",") if n.strip()]
                if names and not step["target"]:
                    step["target"] = names[0]
        m = FRIENDLY_RE.search(line)
        if m and not step["friendly"]:
            step["friendly"] = m.group(1)
    flush(step)


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


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
    rows, n = [], 0
    for f in G.guide_files(root):
        if os.sep + "SoD" + os.sep in f or "/SoD/" in f.replace("\\", "/"):
            continue                      # Season of Discovery vendors (Rune Brokers) are not on TBC / Forever
        parse(f, rows)
        n += 1
    merged = []
    for r in rows:
        dup = None
        for o in merged:
            if o["name"] == r["name"] and o["m"] == r["m"] and abs(o["x"] - r["x"]) < 0.005 and abs(o["y"] - r["y"]) < 0.005:
                dup = o
                break
        if dup:
            if r["f"] != dup["f"]:
                dup["f"] = "N"
            dup["id"] = dup["id"] or r["id"]
            dup["forever"] = dup["forever"] and r["forever"]
            continue
        merged.append(dict(r))
    merged.sort(key=lambda r: (r["m"], r["name"]))
    lines = [
        "-- ============================================================================",
        "-- restedXP_questing",
        "-- Vendors from RestedXP's guides (GENERATED - tools/gen_rxp_vendors.py)",
        "-- ============================================================================",
        "-- Authors: BLIZZ - Anthonyk",
        f"-- Version: {version()}",
        "-- Folder: restedXP_questing",
        "-- ============================================================================",
        "-- Every guide step with a .vendor line: n = NPC name, id = npc id (when the",
        "-- line names one), m = UiMapID, x / y = 0-1 map position (the step's last",
        "-- .goto), f = faction A / H / N (both), fv = true: a WoW Forever guide only.",
        f"-- {n} guide files, {len(rows)} vendor steps, {len(merged)} vendors.",
        "-- ============================================================================",
        "",
        "return {",
    ]
    for r in merged:
        idp = f", id = {r['id']}" if r["id"] else ""
        fv = ", fv = true" if r["forever"] else ""
        lines.append(f"    {{ n = {lua_str(r['name'])}{idp}, m = {r['m']}, x = {r['x']}, y = {r['y']}, f = \"{r['f']}\"{fv} }},")
    lines += ["}", ""]
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    print(f"{n} guide files -> {OUT}: {len(rows)} vendor steps, {len(merged)} vendors, {os.path.getsize(OUT):,} bytes")


if __name__ == "__main__":
    main()
