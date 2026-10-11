# Codebase Audit Report: Master Farmer - Grindbot

- **Audited:** version 2.305.0 (branch `dev`, clean working tree apart from the untracked `.claude/` and `ameisen.zip`).
- **Corrections released:** 2.306.0.
- **Date:** 2026-10-11.

Companion documents:
- [`CODEBASE_REMEDIATION_PLAN.md`](CODEBASE_REMEDIATION_PLAN.md): the prioritised plan, including deferred and blocked items.
- [`API_VERIFICATION_MATRIX.md`](API_VERIFICATION_MATRIX.md): which API integrations were verified, and against what.
- [`audit/`](audit/): five evidence appendices with per-finding stub citations and full symbol tables.

> **Limits of this audit.** Nothing here was run inside World of Warcraft or against a live Sylvanas Core.
> - **API contract:** the authoritative source was the `.api` declaration stubs (`core.lua` 8,912 lines, `game_object.lua`, `common/**`; 58 files, about 20k lines). They are identical in the three installs checked (`daaa22`, `664322289a264b`, `ebe5e7d15a44b2aa650e7e27`). The 34 doc pages in `Downloads\Sylvanas_coreAPI_IZI_API` were the second source.
> - **No library implementation:** the `scripts/common` and `core_lua` folders are empty on disk, because the core supplies them at runtime. Where a stub only declares a signature, behaviour beyond the signature and its doc comment was not verifiable.
> - **Lua checks:** run under LuaJIT 2.1, Lua 5.1 and Lua 5.4 (`make_local.py`). The client's embedded Lua is "5.1-shaped" per AGENTS.md; its exact build is unknown.

---

## 1. Scope and files inspected

| Area | Files | Lines (approx.) | Inspected by |
|---|---|---|---|
| Main loop, events, death, settings, UI shell | main, callbacks, events, watchdog, death, deathzones, errorlog, settings, gamever, header, loader, state, ui, geometry, path_runner | 7.5k | A (API) + D (static) + E (perf/logic) |
| Movement / navigation | movement.lua + `movement/*.lua` (21 files) | 6.5k | A + D + E |
| Questing, economy, gathering | `quest/*`, vendor, trainer, gossip, loot, bags, equip, supplies, resting, healing, conjure, `gather/*`, `grind/*` code, professions | 22k | B + D |
| Combat and rotation | smart, spellbook, spellcheck, castq, targeting, combat, auras, buffs, pets, power, racials, adapt, rotation, `rotations/*`, predict, picks, strafe, `data/class_spells`, `data/racials` | 13k | C + D |
| GUI | gui.lua | 3k | D + E (hot path only) |
| Data | `data/rxp_targets.lua` (8.7k), `grind/paths/**` | not audited for logic | D (syntax, duplication) |
| Vendored | `ameisen/AmeisenNav` (separate plugin) | not audited for API use | D (duplication only) |
| Not shipped | `.bak_pre_movement2/`, `*.bak`, `ameisen.zip`, `plugin_loader/` | not audited | D (duplication only) |

- **Full coverage:** every shipped `.lua` file was checked for syntax, global writes and reads, and the local and upvalue limits (146 manifest files).
- **API coverage:** every `core.*`, `izi.*`, `common/` helper and unit-method call site in the scopes above was looked up in the stubs:
  - Audit A: about 60 core symbols.
  - Audit B: 101 core and 17 izi symbols, plus every `:method`.
  - Audit C: the combat symbol set.
- **Performance:** taken from the per-frame `PERF` / `SPIKE` / `MEM` profiling in the session logs (about 9.5 h of logs across two installs).

## 2. Architecture overview

- **Load:**
  1. `plugin_loader/` fetches the files listed in `manifest.lua` from GitHub `main`.
  2. `header.lua` gates the game version and checks the izi modules.
  3. `main.lua` requires the modules and registers the update and render callbacks once per load. A stale-instance guard protects against reloads.
  4. `loader.lua` lazily loads the grind, quest and gather packs.
- **Per frame:** `main.lua` runs the on_update cascade:
  1. death
  2. flight
  3. enemy scan
  4. loot
  5. conjure
  6. healing / rest
  7. buffs
  8. trainer
  9. vendor
  10. equip
  11. mode (grind / quest / gather / path)

  The first module that claims the tick wins. `strafe.update` and the log heartbeat run after the cascade.
- **Combat:** `smart.lua` reads the Spells-tab ticks (`picks.lua`) and the per-class catalog (`data/class_spells.lua`). `rotations/*.lua` supply only range, melee shape, movement profile and rest. `targeting.lua` handles target choice and the swing timer.
- **Movement:** `movement/fsm.lua` gives one owner per frame:
  - NAV: AmeisenNav through `movement/sentinel.lua`.
  - COMBAT: the local walker (`movement/combat.lua`).
  - Locks: rest, backpedal, loot.
  - Avoid areas: `movement/zones.lua`; death zones (`deathzones.lua`) push areas into them.
- **Questing:** `quest/guide.lua` reads RestedXP through `core.addons.rested_xp`; `quest/engine.lua` acts on goals; `quest/npc.lua` runs the dialogs.
- **Shared state:** `state.lua` (one table) and `_G.MasterFarmer_Grindbot` (reload-surviving handles). There are no other global writes (static scan: 0 GSET).
- **Hazards known to the project and confirmed here:** `quest/engine.lua` sits at exactly 200 top-level locals (LUA-5), and its `tick_inner` has 56 of 60 upvalues (LUA-6).

## 3. Findings by severity

| Severity | Count | Fixed in 2.306.0 | Open |
|---|---|---|---|
| Critical | 1 | 1 | 0 |
| High | 4 | 1 (LOGIC-3) | 3 (CORE-B-1 blocked on API; LOGIC-2, LUA-5 deferred) |
| Medium | 16 | 10 | 5 open, plus DUP-3 resolved outside the repo |
| Low | 27 | 2 | 25 |
| API Verification Required | 3 | 0 | 3 blocked (CORE-B-4, B-7, B-8) |
| Info | 14 | 1 (AGENTS.md text) | n/a |

Counts are after merging duplicates found by more than one audit pass (for example IZI-2 = CORE-A-1 = CORE-B-3, LOGIC-4 = CORE-A-5, LOGIC-5 = CORE-A-7).

## 4. Summary table

Status values:
- **Fixed + Validated:** a test exercises the fix and fails on the pre-fix code.
- **Fixed:** compiled, suite green and call sites reviewed, but no behavioural test.
- **Deferred:** fix known, held back for regression risk or size.
- **Blocked:** needs API information (section 13).

| ID | Severity | Category | File | Finding | Status |
|---|---|---|---|---|---|
| LOGIC-1 | Critical | Logic | movement/nav.lua, deathzones.lua | Corpse run deadlocked: a destination inside an avoid area was failed as "blacklisted" (an off-mesh word), which made a new self-refreshing 12 yd zone on the corpse. Measured: ghost stuck 30 min, then AFK logout, 8.3 h idle. | Fixed + Partially Validated |
| IZI-2 (= CORE-A-1, CORE-B-3) | Medium | IZI API | smart, healing, resting, pets, racials, rotations/{druid,paladin,priest}, movement/combat | Health read through the undeclared `health_pct`/`get_health_percent`, or `get_health_percentage` (1..100, izi_sdk.lua:72) rescaled ×100 when 0..1.5. A unit at 1% read as 100%, so no Execute, no emergency heal, potion or Mend Pet. In movement/combat the guard read nil, so the retreat-below-40% guard never applied. | Fixed + Validated |
| LOGIC-3 | High | Logic | quest/engine.lua `recover_stall` | "recovery N of 3" could still exceed 3 when no NPC was found. | Fixed |
| CORE-B-1 | High | Core API | bags.lua:87 | Possible off-by-one bag slot range; the stub contradicts itself (core.lua:1092 vs 1172/6835). | Blocked: Missing API |
| LOGIC-2 | High | Logic | death.lua | Corpse run has no progress watchdog or cap. Root cause LOGIC-1 is fixed. | Deferred |
| CORE-A-2 | Medium | Core API | movement/util.lua `U.ground_z` | `get_height_for_position` 0 = miss (core.lua:488) was accepted as ground where the hint z < 80 (low zones); the izi fallback's 0 likewise. | Fixed + Validated |
| CORE-A-3 | Medium | Common helper API | deathzones.lua | Target Selector override refreshed every 1 s but expires after 500 ms (ts_override_helper.lua:12-24), so "no pulls near a death zone" was off about half the time. | Fixed |
| CORE-A-4 | Medium | Core API | movement/sentinel_adv.lua | `core.get_map_id()` (the zone UiMapID, e.g. 1426) was used as a continent id. Every zone border wiped avoid zones and nav caches and halted travel. Now `core.get_instance_id()` (core.lua:372-376: "in the open world … the continent"). | Fixed |
| CORE-A-5 / LOGIC-4 | Medium | Core API | movement/repath.lua (×2), quest/engine.lua | `core.input.jump()` is JumpOrAscendStart; the stub (core.lua:3606-3609) says to pair it with `ascend_stop`. | Fixed |
| CORE-A-6 | Medium | Core API | movement/combat.lua, movement/util.lua | Stored combat target used without `is_valid()` (AGENTS.md rule; a freed unit is a native crash). | Fixed |
| CORE-A-7 / LOGIC-5 | Medium | IZI API | movement/fsm.lua | izi `on_*` subscriptions re-registered on each module load; their unsubscribe returns (izi_sdk.lua:559-570) were dropped. | Fixed |
| IZI-3 | Medium | Logic | smart.lua `pack_interrupt` | Target swapped to a casting add without clearing the per-tick memo, so the add's distance, HP and immunity were used for the real target. | Fixed |
| PERF-1 | Medium | Performance | death.lua | Ghost ran up to 5 enemy scans per tick at any distance (measured 0.72 ms/frame at 273 yd); now only within 60 yd of the corpse. | Fixed |
| LUA-3 / CORE-A-10 | Medium | Lua runtime | deathzones.lua, spellcheck.lua | `pcall(os.time)` reads `os.time` outside the pcall; `os.clock()` unguarded. core.lua:846 says `os.time` is unavailable in the sandbox. Now `core.get_server_time()` (core.lua:340-350, same unix-seconds unit). | Fixed |
| IZI-1 | Medium | IZI API | smart.lua:966-970, 2129; racials.lua:183 | Ungated `spell:cast` fallback after `cast_safe` refuses; its `true` (= queued) is counted as cast. | Deferred (intentional since 2.252.0; needs in-game evidence) |
| LUA-5 | High | Lua limits | quest/engine.lua | Exactly 200 top-level locals: any new `local` breaks the quest pack. | Fixed 2.307.0: flight / far-travel moved to `quest/travel.lua`, engine at 167 (test_quest_split) |
| LUA-6 | Medium | Lua limits | quest/engine.lua `tick_inner` | 56 of 60 upvalues. | Fixed 2.307.0: 52 |
| DUP-5 | Medium | Duplication | 49 files | Two contracts under one name: `safe(fn)` drops args (45 files), `safe(fn, ...)` passes them (4). Caused the 2.300.0 route-height bug. No current call passes extra args to a dropping `safe` (scope-aware scan). | Deferred |
| CORE-B-2 | Medium | Core API | quest/guide.lua:2440-2467 | `use_bag_item` passes an item object where `use_item` takes an id; the boolean result is ignored. | Open |
| CORE-B-4 | Medium | API Verification Required | vendor, equip, trainer, quest/engine | Merchant / trainer window "open" inferred from item counts > 0; the stub defines open/closed by events. | Blocked: Missing API |
| CORE-B-5 | Medium | Core API | supplies.lua, quest/guide.lua | `get_items_in_bag(0..4)`: bag 0 includes worn gear and bank storage (AGENTS.md: use `bags.list`). | Open |
| PERF-2 | Low | Performance | errorlog BEAT | Detailed log dedupe defeated by alternating stage tags (about 6 lines/s). | Open |
| LOGIC-9 | Low | Lua runtime | gui.lua `is_started` | `me:get_class()` outside pcall, every frame. | Fixed |
| LUA-2 | Low | Lua runtime | quest/engine.lua:614 | Read of undefined global `hop` (dead branch since 2.266.0). | Fixed |
| IZI-4 | Low (latent) | Common helper API | auras.lua | buff_manager `remaining` is ms (buff_manager.lua:11), compared with seconds; the only caller passes 0. | Open |
| IZI-5 | Low | IZI API | auras.lua | Aura reads ignore ownership (another player's DoT counts as ours). | Open |
| CORE-A-8 | Low | Core API | settings, hazards, deathzones, ui | `create_data_file` boolean result never checked. | Open |
| CORE-A-9 | Low | Core API | ui.lua:447 | `read_dir` missing-folder sentinel misread (one misleading log line). | Open |
| CORE-A-12 | Low | Core API | inn set-home | Skipped on Forever; the stub now says confirm works on every client. | Open |
| CORE-B-6, B-9, B-10, B-11 | Low | Core API | vendor, quest/guide, professions, bags/gather | See audit/B_core_quest.md. | Open |
| LOGIC-6, LOGIC-7, LOGIC-8 | Low | Logic | see audit/E | Stale `state` after partial reload; uncapped revive retries; mixed clocks in fallbacks only. | Open |
| PERF-3 … PERF-7 | Low | Performance | gui, path_runner, errorlog, resting, state | Menu draw 0.14-0.45 ms/frame when open; per-frame allocations; rest spikes 1-9 ms once per rest; GUID-keyed tables that never shrink. | Open |
| LUA-7, LUA-8 | Low | Lua | movement/combat, quest/engine | 51 upvalues in `combat_engage`; `local function debug` shadows the library. | Open |
| DUP-1, DUP-2, DUP-6, DUP-7, DUP-8 | Low | Duplication | see audit/D | Stale backups in the repo folder (not shipped); old `ameisen.zip`; `call(fn,a,b)` drops a 3rd arg (no caller passes one); unwrapped `trail` in 2 files; `quest/api_examples.lua` shipped but never required. | Open |
| DUP-3 | Low | Deployment | install folders | Installed AmeisenNav older than the repo copy. The three test installs were updated to 1.6.8 on 2026-10-11; the `3cf70445e7` install named in AGENTS.md no longer exists. | Resolved outside the repo |
| CORE-B-7, CORE-B-8, IZI-8, IZI-10, CORE-A-14 | API Verification Required | | see section 13 | | Blocked |
| CORE-B-16 | Info | Docs | AGENTS.md | Said RestedXP has no skip-step API; the stub declares `skip_current_step` and the code uses it. | Fixed (AGENTS.md) |

## 5. Confirmed Sylvanas Core API defects

CORE-A-2, CORE-A-4, CORE-A-5, CORE-A-6 and LUA-3/CORE-A-10 were all fixed; section 10 has the evidence for each.

Still open:
- CORE-A-8 (Low): write results unchecked.
- CORE-A-9 (Low, cosmetic).
- CORE-B-2 (Medium).
- CORE-B-5 / B-6.

CORE-B-1 and CORE-B-4 cannot be settled from the stubs (section 13).

No `.`/`:` mistakes and no argument-order errors were found in any of the 160+ core and izi call sites checked. Index bases were checked and are correct:
- loot: 0-based
- vendor buying: 1-based
- taxi nodes
- gossip ids
- quest log
- rewards

## 6. Confirmed IZI Library defects

- **Fixed:**
  - IZI-2 (health scale).
  - IZI-3 (stale memo; a logic defect in IZI-object handling).
  - CORE-A-7 (subscription leak).
- **Open:**
  - IZI-1 (ungated cast fallback, deferred).
  - IZI-4 (latent ms/s mismatch).
  - IZI-5 (aura ownership).

Every `c.xxx` called by a `data/class_spells.lua` condition is defined in `smart.lua`. All `core.spell_book.*` names and arities, the spell_helper / spell_queue argument order, `get_spell_base_cooldown` (ms) and the stance form ids 17/18/19 were verified.

## 7. Lua syntax and runtime findings

- **Syntax:**
  - 147 files compile, with 0 failures, under Lua 5.1, Lua 5.4 and LuaJIT.
  - The only failing file is the unshipped `movement.lua.monolith.bak`, which exceeds 200 locals.
- **Globals:** 0 global writes outside the `_G.MasterFarmer_Grindbot` namespace. Unexpected global reads:
  - `hop`: fixed (LUA-2).
  - `os`: fixed (LUA-3).
- **Limits:**
  - LUA-5: engine at 200/200 locals.
  - LUA-6: `tick_inner` at 56/60 upvalues.
  - LUA-7: `combat_engage` at 51 upvalues.
- **Use-before-define:** none.
- **Helper arguments:** no call passes extra arguments to a local `safe`/`call` that drops them. This was checked with a scope-aware scan over all code plus AmeisenNav.

## 8. Duplicate files and duplicate logic

- **Files:**
  - No byte-identical shipped files.
  - Backups live in the repo folder but are gitignored and not shipped: `.bak_pre_movement2/` (13 files) and `movement.lua.*.bak`.
  - The untracked `ameisen.zip` is an outdated AmeisenNav snapshot (11 files differ; it lacks `coords.lua`, `horizon.lua` and `pathcheck.lua`).
- **Helpers:**
  - `safe`: 49 copies, 2 contracts (DUP-5).
  - `now`: 17 copies, 10 variants.
  - `trail`: 13 copies, 12 variants.
  - `call`: 7 copies, 3 variants.
  - The behavioural differences are documented in audit/D_static_dup.md. Consolidation is deferred: it touches about 50 files for no functional gain today, and the scan shows no live mismatch.
- **Unreachable:** `quest/api_examples.lua` (19 KB) is in the manifest but never required (DUP-8).

## 9. Performance and memory findings (measured)

| Measure | Value | Source |
|---|---|---|
| Frame cost (Lua, plugin) | typical 0.15-0.4 ms/frame, worst 1.81 ms/frame | PERF lines, 664 and daaa22 logs |
| Heap | 13.5-15.7 MB steady over about 9.5 h; load peak 21-24 MB falls to about 14 MB within 30 s; no monotonic growth | MEM lines (only about 40 min of the 9.5 h was active play, so slow-growing tables are not ruled out) |
| Spikes | all 6 from the rest path, 1.2-8.8 ms, once per rest | SPIKE lines |
| Top probes | `u:death` (ghost) 0.14 → 0.72 ms/frame; `gui:menu.draw` 0.14-0.45; `on_render` 0.14 (path drawing, estimate); `u:begin` / `gui.draw` about 0.04 each | PERF lines |

PERF-1 is fixed. Its improvement is an **estimate**: the scans no longer run beyond 60 yd of the corpse. It has not been re-measured in game. The other items are low impact (section 4).

## 10. Corrections implemented (2.306.0)

| File | Change | Finding | Evidence | Validation |
|---|---|---|---|---|
| smart.lua `health_of` | `get_health`/`get_max_health` first, then `get_health_percentage` as is; no ×100 rescale; undeclared `health_pct` not read | IZI-2 | izi_sdk.lua:72 "1..100"; game_object.lua:262/270 | `tests/test_audit_fixes.lua`: Execute at 1% and 1.4%; fails on 2.305.0 code |
| healing.lua, resting.lua `as_percent` | same order and scale | CORE-B-3 | same | suite; call sites reviewed |
| pets.lua `health_pct`; racials.lua, rotations/{druid,paladin,priest}.lua `health_pct` | same; unused rescale helpers removed | IZI-2 | same | suite (test_hunter_pet etc.) |
| movement/combat.lua `retreat_allowed` | health from declared calls (was undeclared → nil, so the guard never applied) | CORE-A-1 | `get_health_percent` / `health_pct` absent from the stubs | `test_retreat_guards` (stub corrected to the declared method) |
| smart.lua `pack_interrupt` | memo cleared on every target swap and restore | IZI-3 | code path | suite |
| movement/util.lua `U.ground_z` | 0 from `get_height_for_position` or the izi fallback = miss | CORE-A-2 | core.lua:488 "0 on a miss" | `test_audit_fixes.lua`; fails on 2.305.0 code |
| deathzones.lua `M.tick` | `set_pull_allowed(false)` every frame while the session exists | CORE-A-3 | ts_override_helper.lua:12-24, 139 | suite; needs in-game check of the TS header |
| deathzones.lua `wall` | `core.get_server_time()`, guarded `os` fallback | LUA-3/CORE-A-10 | core.lua:340-350, 846 | compile; unit unchanged (unix s) |
| spellcheck.lua clock fallback | `os.clock` guarded | LUA-3 | core.lua:846 | compile |
| movement/sentinel_adv.lua `read_map` | `core.get_instance_id()` (continent), 0 = no answer | CORE-A-4 | core.lua:372-376; logs show `get_map_id` = 1426 (zone) | compile; needs in-game zone-border check |
| movement/repath.lua ×2, quest/engine.lua | `ascend_stop` after each `jump` | CORE-A-5 | core.lua:3606-3609 | compile |
| movement/util.lua `unit_xyz`, movement/combat.lua `combat_unit` | `is_valid()` before use | CORE-A-6 | AGENTS.md rule; game_object.lua is_valid | suite |
| movement/fsm.lua events | unsubscribe the previous load's izi handlers (kept in `_G.MasterFarmer_Grindbot.fsm_unsub`) | CORE-A-7 | izi_sdk.lua:559-570 `: (fun())` unsubscribe | compile; GSET scan clean |
| movement/nav.lua (×2) | avoid-area refusal recorded as "in an avoid area" (not an off-mesh word) | LOGIC-1 | const.lua:155 OFFMESH_WORDS; walker.lua:143 | `test_audit_fixes.lua` (classification) |
| deathzones.lua `M.tick` | death zones withdrawn from navigation while the player is dead, pushed back after | LOGIC-1 | log 04:05-04:35 (audit/E) | suite; needs an in-game death inside a death zone |
| quest/engine.lua `recover_stall` | counter reset on every give-up; a second give-up of the same goal asks RestedXP to skip the step | LOGIC-3 | code path | `test_npc_ladder` |
| quest/engine.lua walk_to | dead `if hop` line removed | LUA-2 | GGET "hop" in bytecode, now 0 | bytecode scan |
| death.lua | safe-spot enemy scans only within 60 yd | PERF-1 | measured 0.72 ms/frame | `test_corpse_position` |
| gui.lua `is_started` | `get_class` in pcall | LOGIC-9 | code path | compile |
| tests (9 files) | stubs switched from undeclared `health_pct` / `get_health_percent` to the declared `get_health_percentage` | n/a | tests previously asserted on an API the code must not use | suite |
| AGENTS.md | skip-step API sentence corrected | CORE-B-16 | stub `skip_current_step` | n/a |

## 11. Tests executed and actual results

- **Test suite** (`_MASTER-FARMER_/tests`, LuaJIT with stubbed `core` / `izi`): **50 / 50 files pass** after the changes, including the new `test_audit_fixes.lua`.
  - The new test was also run against the 2.305.0 versions of `smart.lua` and `movement/util.lua`. It **fails there on 3 checks** (Execute at 1%, at 1.4%, height 0), which proves it exercises the fixed defects.
  - Before the stub corrections, 2 files failed (`test_retreat_guards`, `test_rogue_sprint`) because their mocks provided only the undeclared methods the code no longer reads.
- **Syntax** (`make_local.py` compiling under Lua 5.4, Lua 5.1 and LuaJIT): 147 files, **0 failed**.
- **Global scan** (bytecode GGET/GSET): no new globals introduced.
- **Not executed:** anything in game. The checks that need the live client are in section 14.

## 12. Unresolved findings

Section 4 lists each one with its status:
- **Deferred:** IZI-1, LUA-5, LUA-6, DUP-5, LOGIC-2.
- **Open:** the low-severity items.
- **Blocked:** the API questions.

The remediation plan orders them.

## 13. MISSING API INFORMATION: USER ACTION REQUIRED

| # | API / operation | Used in | Why it cannot be verified | Searched | Needed | Safe workaround now | Fix once supplied |
|---|---|---|---|---|---|---|---|
| 1 | Bag slot numbering for `core.inventory` / `use_container_item` (CORE-B-1) | bags.lua:87 `bags.list` | core.lua:1092 says slots 1-16; core.lua:1172-1173 and 6835 say the API slot is the in-game slot + 1 ("backpack slot 16 is (0, 17)"). | core.lua, inventory_helper stub, docs txt | Which is current for TBC and Forever, or one in-game print of `get_items_in_bag(0)` with a full backpack | none: left unchanged | extend the range to capacity + 1 if confirmed |
| 2 | Merchant / trainer window state (CORE-B-4) | vendor.lua:371, equip.lua:727, trainer.lua:599, gather/trainer.lua:168, quest/engine.lua:2225 | Code treats item count > 0 as "open"; the stub documents MERCHANT_SHOW/CLOSED and TRAINER_SHOW/CLOSED but not whether the counts reset to 0 on close | core.lua, events doc | Do `get_merchant_num_items` / `get_num_trainer_services` return 0 after the window closes? | none needed if yes | track the events instead if no |
| 3 | `core.game_ui.get_current_map_id` return (CORE-B-7) | quest/mismatch.lua:96, gather/engine.lua:176 | The stub gives no description of the value | core.lua, game-ui doc | UiMapID of the zone, or the map the world-map frame shows? | none | switch to `get_map_at_position` if it is the frame's map |
| 4 | `core.input.use_item(id)` for equipping gear and ammo (CORE-B-8) | bags.lua:134 via equip.lua:826, gather/supply.lua:185 | The stub documents use, not equip | core.lua, input doc | Does it equip an equippable item from the bags on TBC and Forever? | keep | use `equip_container_item` if not |
| 5 | `player:gcd_remains()` unit (IZI-8) | smart.lua GCD gate | Not documented (s vs ms) | izi_sdk.lua, game_object.lua | seconds or ms | read as seconds (works in logs) | none if seconds |
| 6 | Several izi units / ranges (IZI-10) | smart, castq | undocumented units | izi_sdk.lua | units for `cast_time`, `get_spell_cooldown` remainders | handled defensively | none |
| 7 | AmeisenNav client API and coords_helper map-id pairing (CORE-A-14) | movement/sentinel*.lua | outside the Sylvanas stubs | ameisen/AmeisenNav docs/API.md | AmeisenNav is our own code: verified against its source, not a stub | n/a | n/a |

Everything else in the audited scopes was checked against the stubs. The three undeclared symbols still in use are known:
- `core.reload_game_ui`: intentional per AGENTS.md, type-guarded.
- `player:get_class_id()`: a guarded fallback.
- `unit:health_pct()`: no longer read by the health paths fixed here; one guarded mana fallback reads `mana_pct`, whose scale the stub does not state.

## 14. Remaining manual (in-game) tests

| Check | How | Expected | Failure looks like |
|---|---|---|---|
| LOGIC-1 | Die 3× to the same mob (death zone created), release | Ghost walks to the corpse at once and revives; log shows the death zones withdrawn | "Corpse N yd" unchanged for more than 60 s |
| CORE-A-4 | Walk across a zone border (Dun Morogh → Loch Modan) | No "map … -> …: blacklist zones, nav caches and the walk reset" line; one appears on a continent change | the line on every zone border |
| CORE-A-3 | Stand near an active death zone with the Target Selector menu open | The "Overridden by" header stays on | the header flickers |
| IZI-2 | Warrior with Execute; Hunter pet below 50%; any class at low HP | Execute under 20%; Mend Pet; potion / heal / retreat guards | none of these below 2% HP |
| CORE-A-5 | Get stuck in water (repath jump) | no continuous swim-up afterwards | the character keeps rising |
| CORE-A-7 | Reload the plugin from the launcher 3× | combat-state flags behave the same | — |

## 15. Recommended next steps

1. Run the in-game checks in section 14 on the three test installs (2.306.0 reaches them through the launcher).
2. Answer the API questions in section 13, especially #1 (bag slots) and #2 (window state), which can affect selling.
3. Plan the `quest/engine.lua` split (LUA-5 / LUA-6) before the next questing feature, because the next new `local` there breaks the quest pack.
4. Decide on IZI-1 with a log check: count "cast" lines for spells izi refused.
5. Consolidate `safe` to the vararg form (DUP-5) in a dedicated, mechanical change.
