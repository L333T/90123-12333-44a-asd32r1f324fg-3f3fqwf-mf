# Master Farmer - Grindbot — shared agent rules

One rule set for every AI tool that works on this project: **Claude Code** reads it
through `CLAUDE.md`, **Cursor** reads this file directly (plus `.cursor/rules/`).
When a rule changes, change it HERE so both tools follow the same one.

A Sylvanas (Project Sylvanas) Lua plugin: an AFK WoW levelling bot. Targets
**TBC Classic** and **WoW Forever** (vanilla content on a modern client), chosen at
runtime by `gamever.lua`.

## Releasing — every change

1. **Bump the version** for any material change: `version.lua` and every
   `-- Version: X.Y.Z` banner (not historical references inside comments), and add
   a row at the top of the table in `VERSIONING.md`.
2. **Build the local test folder**: `python make_local.py` → regenerates
   `manifest.lua` (the loader fetches files by Adler-32 hash, so a stale manifest
   means the change never reaches the game), syntax-checks every `.lua`, and copies
   the build to `Desktop/Master_Farmer_Grindbot_v<version>/`.
3. **Always publish**: commit on `dev` (`vX.Y.Z: <summary>`), push, open the PR to
   `main` **and merge it**. The in-game loader downloads from GitHub `main`
   (`plugin_loader/main.lua`, `BRANCH = "main"`), so uncommitted or unmerged work is
   invisible in game. Do not leave a finished version uncommitted.
4. **Never stage `plugin_loader.zip`** (it is `skip-worktree` locally).
5. **Leave `plugin_loader/` alone** unless the user approves a change. When one is
   made, also copy it to the INSTALLED loader the game runs (below), back up the
   installed copy first, and keep backups OUTSIDE `scripts\` (a folder there is
   loaded as a plugin). Current loader: 1.2.2. It follows GitHub `main` (no commit pin) and loads on TBC and Forever for every class. Edit it only when the download mechanism changes.

## Paths

| What | Where |
|---|---|
| Repo (this folder) | `C:\Users\ebene\OneDrive\Desktop\Master_Farmer_Grindbot` |
| Active game install (changes between installs — ask if logs look stale) | `C:\Users\ebene\OneDrive\Documents\3cf70445e7` |
| Installed loader | `…\3cf70445e7\scripts\plugin_loader\` |
| Session logs (one per session, `errorlog.lua`) | `…\3cf70445e7\scripts_log\MASTER_FARMER_ERRORS\` |
| API stubs (source of truth for every call) | `…\3cf70445e7\scripts\.api\` |
| API docs (per game version, incl. Forever notes) | `C:\Users\ebene\Downloads\Sylvanas_coreAPI_IZI_API\` |
| Sentinel navigation source (v0.0.6; installed client is v0.23) | `C:\Users\ebene\OneDrive\Desktop\MF_Navigation\` |

## API discipline

Only call APIs declared in the `.api` stubs (see `.cursor/rules/00-no-guessing-index.mdc`).
Guard native calls with `pcall`; call `is_valid()` before any other method on a
stored unit; compare game objects by GUID, never `==`. Do not use Lua `goto`
(the client's Lua version is not confirmed).

## Architecture in one page

- **Cascade** (`main.lua`): death → flight check → enemy scan → loot → conjure →
  healing/rest → buffs → trainer → vendor → equip → mode (grind / quest / path).
- **Rotation**: the Spells tab ticks (`picks.lua`) + `data/class_spells.lua` (per-class
  catalog by spell name and role) drive `smart.lua` for every class.
  `rotations/*.lua` only supply range, melee shape, the movement combat profile
  and rest (their old `tick` / `buffs_ooc` / `register_gui` / `interrupt` code was
  removed in 2.142.0 - do not reintroduce class-module casting). The spellbook
  (`spellbook.lua`) admits only spells this character owns.
- **Movement** (`movement/*`): Sentinel (`SentinelNavClient`) owns out-of-combat
  travel (`K.SENTINEL_TRAVEL` in `movement/const.lua`); the local walker owns
  combat (chase, stand-off, kite, Frost Nova backpedal). Never flood Sentinel
  (≤ 1 request/s). Hand the SDK movement handler positions, never units.
- **Supplies**: a rest with nothing to eat / drink asks `supplies.request`; `vendor.lua` runs a food / water trip to the nearest inn (`data/ek_alliance_routes` inn ends) when gold or junk allows, else `resting.lua` waits for 80% HP / MP. Mages conjure once `is_usable_spell` allows.
- **Questing**: all quest data comes from RestedXP (`core.addons.rested_xp`) via
  `quest/guide.lua`; `quest/engine.lua` acts on it; kill goals attack the closest unit of the step's npc id. Far goals may use flight paths
  (`data/taxi_nodes.lua`).
- **Game version**: `gamever.lua` — `is_tbc()` / `is_forever()`, playable races.
  On Forever: no Blood Elf / Draenei (adds the Skyborne races 95 / 96), no quest-log
  index API, no vendor item info (food buying off), no Outland flight points.

## Testing

After any removal or large refactor, run an AST scan for undeclared reads and
global writes (luaparser) - both must stay at 0.

No test suite ships with the repo. Offline checks use `lupa` (Python) to load
modules with stubbed `core` / `izi`; `make_local.py` does the syntax pass. In-game
behaviour is confirmed from the session logs above.
