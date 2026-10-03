"""Build data/forever_spells.lua from RestedXP's WoW Forever trainer list.

RXPGuides DB/forever/spells.lua (addon.defaultSpellList) lists, per class and
race, the spell ids RestedXP recommends training on WoW Forever, by level.
The spell book scan asks the client about these ids directly on Forever
(spellbook.lua), so a spell the book walk leaves out is still found - the
same reason racial ids are probed.

Usage:
    python tools/gen_forever_spells.py ["<path to RXPGuides>"]
"""
import os
import re
import sys

DEFAULT = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\RXPGuides"
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "forever_spells.lua")


def version():
    try:
        txt = open(os.path.join(os.path.dirname(OUT), "..", "version.lua"), encoding="utf-8").read()
        m = re.search(r'version\s*=\s*"([\d.]+)"', txt)
        return m.group(1) if m else "0.0.0"
    except OSError:
        return "0.0.0"


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    src = open(os.path.join(root, "DB", "forever", "spells.lua"), encoding="utf-8", errors="ignore").read()
    # Drop commented-out entries before reading ids.
    src = re.sub(r"--[^\n]*", "", src)
    groups = {}
    for m in re.finditer(r's\["(\w+)"\]\s*=\s*\{', src):
        key = m.group(1)
        depth, i = 1, m.end()
        while depth and i < len(src):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
            i += 1
        body = src[m.end():i - 1]
        body = re.sub(r"\[\d+\]\s*=", "", body)          # level keys are not spell ids
        ids = sorted({int(x) for x in re.findall(r"\b\d+\b", body)})
        groups[key] = ids
    lines = [
        "-- ============================================================================",
        "-- Master Farmer - Grindbot",
        "-- WoW Forever trainer spell ids (GENERATED - tools/gen_forever_spells.py)",
        "-- ============================================================================",
        "-- Authors: BLIZZ - Anthonyk",
        f"-- Version: {version()}",
        "-- Folder: Master_Farmer_Grindbot",
        "-- ============================================================================",
        "-- From RXPGuides DB/forever/spells.lua (addon.defaultSpellList). Keys are",
        "-- RestedXP's: class tokens (MAGE...) and race names (Dwarf, NightElf, Scourge).",
        "-- ============================================================================",
        "",
        "local M = {}",
        "",
        "M.ids = {",
    ]
    for key in sorted(groups):
        lines.append(f"    {key} = {{ {', '.join(str(x) for x in groups[key])} }},")
    lines += ["}", "", "return M", ""]
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    print(f"{OUT}: {len(groups)} groups, {sum(len(v) for v in groups.values())} ids")


if __name__ == "__main__":
    main()
