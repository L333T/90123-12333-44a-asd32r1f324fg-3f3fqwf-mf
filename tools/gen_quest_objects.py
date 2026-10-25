"""Quest -> game object ids to interact with (GENERATES data/quest_objects.lua).

4.5.0. RestedXP's guides name the objects to click by colour (|cRXP_PICK_Large
Termite Mounds|r) but carry no ids; the core.addons.rested_xp API carries
neither. Zygor's TBC Anniversary guides (installed beside RestedXP) write every
object step as "click Large Termite Mound##177464" with the quest it serves on
the step's goal lines (|q 5903/1) or accept / turn-in lines (##questid). Every
click in a step is paired with every quest of that step:

    M.by_quest[quest]       = { object id, ... }   objective objects (|q tags)
    M.givers[quest]         = { object id, ... }   a click step that accepts / turns in the
                                                   quest and talks to no NPC (Wanted Poster)
    M.names[object id]      = "Large Termite Mound"
    M.names_by_quest[quest] = { name, ... }        click lines with no id

The bot matches objects by game_object:get_npc_id() (the object's entry id,
as the Project Sylvanas Object ESP example does).

    python tools/gen_quest_objects.py ["<path to ZygorGuidesViewerClassicTBCAnniv>"]
"""
import os
import re
import sys

DEFAULT = r"C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns\ZygorGuidesViewerClassicTBCAnniv"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "quest_objects.lua")
SUBDIR = "Guides-TBC"

CLICK_RE = re.compile(r"^\s*click\s+([^#|+]+?)\s*(?:##(\d+))?\+?\s*(?:\||$)")
QTAG_RE = re.compile(r"\|q\s+(\d+)")
DIALOG_RE = re.compile(r"^\s*(?:accept|turnin)\s+[^#]*##(\d+)")
TALK_RE = re.compile(r"^\s*talk\s")


def guide_files(root):
    base = os.path.join(root, SUBDIR)
    for dirpath, _, filenames in os.walk(base):
        for f in filenames:
            if f.endswith(".lua") and "Trial" not in f:
                yield os.path.join(dirpath, f)


def parse(path, by_quest, names, names_by_quest, givers):
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return

    def flush(clicks, quests, dialog, talks):
        if not clicks:
            return
        # an object that gives / takes the quest: the step clicks it and talks to nobody
        if dialog and not talks:
            for name, oid in clicks:
                if oid:
                    for q in dialog:
                        givers.setdefault(q, set()).add(oid)
                        names.setdefault(oid, name)
        for name, oid in clicks:
            for q in quests:
                if oid:
                    by_quest.setdefault(q, set()).add(oid)
                    names.setdefault(oid, name)
                else:
                    names_by_quest.setdefault(q, set()).add(name)

    clicks, quests, dialog, talks = [], set(), set(), False
    for raw in text.splitlines():
        line = raw.strip()
        if line == "step" or line.startswith("step "):
            flush(clicks, quests, dialog, talks)
            clicks, quests, dialog, talks = [], set(), set(), False
            continue
        if TALK_RE.match(line):
            talks = True
        m = CLICK_RE.match(line)
        if m:
            name = m.group(1).strip()
            if len(name) >= 3:
                clicks.append((name, int(m.group(2)) if m.group(2) else None))
        for q in QTAG_RE.findall(line):
            quests.add(int(q))
        d = DIALOG_RE.match(line)
        if d and clicks:                     # only an accept / turn-in AFTER the click
            dialog.add(int(d.group(1)))
    flush(clicks, quests, dialog, talks)


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
    by_quest, names, names_by_quest, givers = {}, {}, {}, {}
    n = 0
    for f in guide_files(root):
        parse(f, by_quest, names, names_by_quest, givers)
        n += 1
    lines = [
        "-- ============================================================================",
        "-- restedXP_questing",
        "-- Quest -> game object ids to interact with (GENERATED - tools/gen_quest_objects.py)",
        "-- ============================================================================",
        "-- Authors: BLIZZ - Anthonyk",
        f"-- Version: {version()}",
        "-- Folder: restedXP_questing",
        "-- ============================================================================",
        "-- From Zygor's TBC Anniversary guides (\"click Large Termite Mound##177464\" with",
        "-- the step's |q tags). Objects are matched by game_object:get_npc_id().",
        f"-- {n} guide files, {len(by_quest)} quests with object ids, {len(names)} objects.",
        "-- ============================================================================",
        "",
        "local M = {}",
        "",
        "-- quest id -> { object id, ... }",
        "M.by_quest = {",
    ]
    for q in sorted(by_quest):
        lines.append(f"    [{q}] = {{ {', '.join(str(x) for x in sorted(by_quest[q]))} }},")
    lines += ["}", "", "-- quest id -> { object id, ... } that gives / takes the quest", "M.givers = {"]
    for q in sorted(givers):
        lines.append(f"    [{q}] = {{ {', '.join(str(x) for x in sorted(givers[q]))} }},")
    lines += ["}", "", "-- object id -> name", "M.names = {"]
    for oid in sorted(names):
        lines.append(f"    [{oid}] = {lua_str(names[oid])},")
    lines += ["}", "", "-- quest id -> { object names } (click lines with no id)", "M.names_by_quest = {"]
    for q in sorted(names_by_quest):
        lines.append(f"    [{q}] = {{ " + ", ".join(lua_str(x) for x in sorted(names_by_quest[q])) + " },")
    lines += ["}", "", "return M", ""]
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    print(f"{n} guide files -> {OUT}: {len(by_quest)} quests, {len(names)} objects, "
          f"{len(givers)} object-given quests, {len(names_by_quest)} quests with unnamed-id clicks, {os.path.getsize(OUT):,} bytes")


if __name__ == "__main__":
    main()
