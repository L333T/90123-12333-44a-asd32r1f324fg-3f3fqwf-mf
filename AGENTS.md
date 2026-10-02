# Master Farmer - Grindbot — shared agent rules

One rule set for every AI tool that works on this project: **Claude Code** reads it
through `CLAUDE.md`, **Cursor** reads this file directly (plus `.cursor/rules/`).
When a rule changes, change it HERE so both tools follow the same one.

Master Farmer work lives in `C:\Users\ebene\OneDrive\Desktop\SNES_\`.
The repo is `SNES_\Master_Farmer_Grindbot`. Every local build
(`Master_Farmer_Grindbot_v<version>`) and the older `Master Farmer Versions`
archive sit in that same folder. Do not put new version folders on the
desktop beside `SNES_`.

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
   the build to `Desktop/SNES_/Master_Farmer_Grindbot_v<version>/`.
3. **Always publish**: commit on `dev` (`vX.Y.Z: <summary>`), push, open the PR to
   `main` **and merge it**. The in-game loader downloads from GitHub `main`
   (`plugin_loader/main.lua`, `BRANCH = "main"`), so uncommitted or unmerged work is
   invisible in game. Do not leave a finished version uncommitted.
4. **Never stage `plugin_loader.zip`** (it is `skip-worktree` locally).
5. **Leave `plugin_loader/` alone** unless the user approves a change. When one is
   made, also copy it to the INSTALLED loader the game runs (below), back up the
   installed copy first, and keep backups OUTSIDE `scripts\` (a folder there is
   loaded as a plugin). Current loader: 1.2.3 (quiet console: only "[Master Farmer] loading..." / "loaded <name> v<version>"; repository, commit, URLs, HTTP codes and progress only with `VERBOSE = true` in `plugin_loader/main.lua`). It follows GitHub `main` (no commit pin) and loads on TBC and Forever for every class. Edit it only when the download mechanism changes. The game install now runs a PACKED copy (`scripts\ext_plugin_masterfarmer_beta_test`) - a loader change reaches the game only when that file is rebuilt from `plugin_loader/`.

## Paths

| What | Where |
|---|---|
| Home folder (all Master Farmer work) | `C:\Users\ebene\OneDrive\Desktop\SNES_\` |
| Repo (open this folder) | `C:\Users\ebene\OneDrive\Desktop\SNES_\Master_Farmer_Grindbot` |
| Local version builds | `C:\Users\ebene\OneDrive\Desktop\SNES_\Master_Farmer_Grindbot_v<version>\` |
| Older version archive | `C:\Users\ebene\OneDrive\Desktop\SNES_\Master Farmer Versions\` |
| Active game install (changes between installs — ask if logs look stale) | `C:\Users\ebene\OneDrive\Documents\3cf70445e7` |
| Installed loader | `…\3cf70445e7\scripts\plugin_loader\` |
| Session logs (one per session, `errorlog.lua`) | `…\3cf70445e7\scripts_log\MASTER_FARMER_ERRORS\` |
| API stubs (source of truth for every call) | `…\3cf70445e7\scripts\.api\` |
| API docs (per game version, incl. Forever notes) | `C:\Users\ebene\Downloads\Sylvanas_coreAPI_IZI_API\` |
| Sentinel navigation source (v0.0.6; installed client is v0.23) | `C:\Users\ebene\OneDrive\Desktop\SNES_\MF_Navigation\` |

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
  (`spellbook.lua`) admits only spells this character owns. Racial ids in `data/racials` (and `spellbook.probe_ids`) are asked about directly on every scan, since `get_spells()` can omit them (Forever's Eureka!); book spells outside the class catalog appear unticked under "Other known spells" (2.194.0).
- **Movement** (`movement/*`): Sentinel (`SentinelNavClient`) owns out-of-combat
  travel (`K.SENTINEL_TRAVEL` in `movement/const.lua`); the local walker owns
  combat (chase, stand-off, kite, Frost Nova backpedal). Never flood Sentinel
  (≤ 1 request/s). Hand the SDK movement handler positions, never units.
  Never stop the Sentinel client while its path request is in flight - `N.stop`
  defers the stop until it leaves awaiting_path / repathing (2.181.0; stopping a
  fresh leg is the common factor in the game crashes). Ranged classes engage and
  cast at or inside the Spells-tab "Ranged attack distance" (hunter: Shooting
  distance) - `smart.lua` in_reach and `rotation.combat_range` enforce it.
  Stuck 20 s while trying to move: `RP.area_watch` blacklists the area just ahead
  and re-paths; blacklist zones reach Sentinel (obstacle list + find_path_avoid) (2.190.0).
  Sentinel's own stuck recovery is waited on only while it moves the character: frozen
  6 s (`N.recovery_stalled`) -> `RP.recovery_watch` blacklists the area ahead along the
  path and `N.repath_around` plans around it with find_path_avoid (2.192.0).
- **Bag items**: always through `bags.list` (inventory_helper `bag_id` / `bag_slot`, the pair
  `use_container_item` takes), which keeps only real bag slots - backpack 1-16, worn bags
  1..`get_num_bag_slots(bag+1)`; the helper also returns bank-storage entries on this client
  (2.184.0). Never sell with `core.input.use_item` - it uses (eats / equips) the item.
- **Food in the bags**: `bags.food_water` classifies every bag item (curated ids,
  then item spell Food / Drink / Refreshment, then item class 0 / 5) - resting and
  supply runs count every kind, not only `data/consumables.lua`. No vendoring
  below level 2 (`vendor.level_ok`): no trips or buying; a quest ".vendor" step still
  opens the merchant so RestedXP ticks it.
- **Supplies**: a rest with nothing to eat / drink asks `supplies.request`; `vendor.lua` runs a food / water trip to the nearest inn (`data/ek_alliance_routes` inn ends) when gold or junk allows, else `resting.lua` waits for 80% HP / MP. Mages conjure once `is_usable_spell` allows.
- **Questing**: all quest data comes from RestedXP (`core.addons.rested_xp`) via
  `quest/guide.lua`; `quest/engine.lua` acts on it; kill goals attack the closest unit of the step's npc id. RestedXP's target mobs (`.mob` / `.target` / `.unitscan`, element.unitlist) are not exposed by the API: `data/rxp_targets.lua` (quest -> mob names) is generated from the guide files by `tools/gen_rxp_targets.py` - rerun it after a RestedXP update (2.200.0). When questing, follow the step: a ".train" / ".trainer" step asks `trainer.quest_visit` for a visit now (the every-3-levels rule covers only the bot's own trainer visits). RestedXP has no "skip step" API: a step only moves on when its goals are really done, so never skip a goal just on our side (a skipped `.vendor` step left the bot standing); goals the bot marked done are retried after 30 s on "step complete". Trainers are found by the step's waypoint title, the class name list, then the class-trainer NPC flag (`get_npc_flags` 0x20). Far goals may use flight paths
  (`data/taxi_nodes.lua`).
- **Game version**: `gamever.lua` — `is_tbc()` / `is_forever()`, playable races.
  On Forever: no Blood Elf / Draenei (adds the Skyborne races 95 / 96), no quest-log
  index API, no vendor item info (food buying off), no Outland flight points.
- **Intentional undeclared API**: `core.reload_game_ui()` (reload after a flight
  lands, 2.107.0) is called on purpose even though the API docs do not list it.
  `izi.is_los` does not exist - LoS is `player:los_to(unit)` only (2.147.0).
- **Loader**: the in-game loader is `plugin_loader/` (http_loader.lua reads
  manifest.lua). The old `bootstrap/` and root `net_loader.lua` were removed in 2.147.0.

## Testing

After any removal or large refactor, run an AST scan for undeclared reads and
global writes (luaparser) - both must stay at 0.

No test suite ships with the repo. Offline checks use `lupa` (Python) to load
modules with stubbed `core` / `izi`; `make_local.py` does the syntax pass. In-game
behaviour is confirmed from the session logs above.
