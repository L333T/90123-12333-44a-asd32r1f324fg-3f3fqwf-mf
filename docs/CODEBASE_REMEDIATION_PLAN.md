# Codebase Remediation Plan: Master Farmer - Grindbot

This plan follows the audit of 2.305.0 ([`CODEBASE_AUDIT_REPORT.md`](CODEBASE_AUDIT_REPORT.md)). Groups A and B were implemented in **2.306.0**, except where an item says otherwise. Groups C to E, and every item marked *Deferred* or *Blocked*, are still open.

Rules applied to every change:
- **Targeted edits only.** No file rewrites. Every caller of a changed function was checked.
- **Declared APIs only.** No new API was introduced unless it is declared in the `.api` stubs.
- **Validation.** Each change was compiled under Lua 5.1, Lua 5.4 and LuaJIT, followed by the full test suite. Behavioural tests were added where the code can be exercised offline.

---

## Group A: Critical and high-severity corrections

| # | Finding | Files / functions | Strategy | API evidence | Tests | Regression risk | Status |
|---|---|---|---|---|---|---|---|
| A1 | LOGIC-1: corpse-run deadlock | movement/nav.lua `navigate` + `nav_path` steer branch; deathzones.lua `M.tick` | Fail an avoid-area destination with a reason outside `K.OFFMESH_WORDS`, so it is no longer re-blacklisted. Withdraw death zones from navigation while `state.dead.waiting`. | const.lua:155, walker.lua:125-150, zones.lua:103 (merge refreshes `t`) | test_audit_fixes (classification), test_corpse_position | Medium: the off-mesh classification also drives probe mode and cooldowns. Real off-mesh reasons are unchanged. | **Done 2.306.0**; in-game check pending |
| A2 | IZI-2 / CORE-A-1 / CORE-B-3: health percentage | smart `health_of`, healing / resting `as_percent`, pets `health_pct`, racials and rotations `health_pct`, movement/combat `retreat_allowed` | Read `get_health`/`get_max_health` first, then `get_health_percentage` as is; drop the rescale and the undeclared names. | izi_sdk.lua:72, game_object.lua:262/270, izi_sdk.lua:283 | test_audit_fixes (Execute at 1%; fails on 2.305.0) | Low: the exact ratio matches the percentage | **Done 2.306.0** |
| A3 | LOGIC-3: recovery counter overflow | quest/engine.lua `recover_stall` | Reset on every give-up; on the second give-up of the same goal, call `skip_current` (`TK.gave_up` key). | `skip_current_step` declared | test_npc_ladder | Low | **Done 2.306.0** |
| A4 | CORE-B-1: bag slot range | bags.lua:87 | Extend to `capacity + 1` **only if** the in-game check confirms the +1 numbering | stub contradicts itself (core.lua:1092 vs 1172/6835) | in-game print of a full backpack | High if wrong (selling, eating) | **Blocked: Missing API #1** |
| A5 | LOGIC-2 / LOGIC-7: no cap on the corpse run or revives | death.lua | Progress watchdog: no yard gained for 60 s means trail plus re-path; after N revive refusals, step to the next reach and stop at a cap. | n/a (logic) | offline death harness (test_corpse_position) | Low | Deferred: the root cause (A1) is fixed; to do next |
| A6 | LUA-5 / LUA-6: quest/engine at 200/200 locals and 56/60 upvalues | quest/engine.lua | Move constants and state into the existing `TK` / `IS` / `OX` tables, or split goal handlers into `quest/goals_*.lua` | n/a (Lua limits) | make_local (5.1, 5.4, LuaJIT) plus test_questing_fixes, test_npc_ladder, test_route_ground | Medium: a large mechanical change | Deferred: schedule before the next questing feature |

## Group B: Logic and reliability

| # | Finding | Files | Strategy | Evidence | Status |
|---|---|---|---|---|---|
| B1 | CORE-A-2: height 0 = miss | movement/util.lua `U.ground_z` | Reject 0 from `get_height_for_position` and from the izi fallback | core.lua:488 | **Done** (test_audit_fixes; fails on 2.305.0) |
| B2 | CORE-A-3: TS override TTL | deathzones.lua `M.tick` | Call `set_pull_allowed(false)` every frame while the session exists | ts_override_helper.lua:12-24, 139 | **Done**; check the TS header in game |
| B3 | CORE-A-4: zone id used as continent | movement/sentinel_adv.lua `read_map` | `core.get_instance_id()`, 0 = no answer | core.lua:372-376 | **Done**; check a zone border in game |
| B4 | CORE-A-5 / LOGIC-4: jump without release | movement/repath.lua ×2, quest/engine.lua | `ascend_stop` after `jump` | core.lua:3606-3609 | **Done** |
| B5 | CORE-A-6: stored unit without is_valid | movement/util.lua `unit_xyz`, movement/combat.lua `combat_unit` | Check `U.unit_valid` first | AGENTS.md rule | **Done** |
| B6 | CORE-A-7 / LOGIC-5: callbacks pile up on reload | movement/fsm.lua | Keep the unsubscribe functions in `_G.MasterFarmer_Grindbot.fsm_unsub` and call them before re-registering | izi_sdk.lua:559-570 | **Done** |
| B7 | IZI-3: stale memo in pack_interrupt | smart.lua | Clear the memo on every target swap and restore | code path | **Done** |
| B8 | LUA-3 / CORE-A-10: `os` in the sandbox | deathzones.lua `wall`, spellcheck.lua | `core.get_server_time()` (unix seconds), guarded `os` fallback | core.lua:340-350, 846 | **Done** |
| B9 | LOGIC-9: unguarded get_class every frame | gui.lua `is_started` | pcall | n/a | **Done** |
| B10 | LUA-2: undefined global `hop` | quest/engine.lua | Remove the dead line | bytecode GGET | **Done** |
| B11 | IZI-1: ungated `spell:cast` fallback | smart.lua:966-970, 2129; racials.lua:183 | Honour the `cast_safe` refusal reason: no fallback for LoS, range or "not usable"; keep `fast_queue_busy` without a fail gap; count `cast` only as "queued" | spell object docs in izi_sdk.lua | Deferred: the fallback was added on purpose (2.252.0). First count, in a session log, the "cast" lines for spells izi refused. |
| B12 | CORE-B-2: use_bag_item passes an object | quest/guide.lua:2440-2467 | Pass the item id; treat a `false` return as failed | core.lua `use_item(item_id)` | Open (Medium): next pass, with a quest-item test |
| B13 | CORE-B-5 / B-6: bag 0 includes worn gear and bank | supplies.lua, quest/guide.lua, vendor.lua | Route through `bags.list` (AGENTS.md rule) | inventory_helper stub | Open (Medium) |
| B14 | CORE-B-4: window state from counts | vendor, equip, trainer, gather/trainer, quest/engine | Track MERCHANT_* / TRAINER_* events if counts do not reset | events doc | **Blocked: Missing API #2** |
| B15 | IZI-5: aura ownership | auras.lua | Filter by caster when the helper exposes it | buff_manager stub | Open (Low) |
| B16 | CORE-A-8: write results unchecked | settings, hazards, deathzones, ui | Log once when `create_data_file` returns false | core.lua:664 | Open (Low) |

## Group C: Duplicate and redundant code

| # | Finding | Strategy | Safe? | Callers | Status |
|---|---|---|---|---|---|
| C1 | DUP-5: `safe(fn)` vs `safe(fn, ...)` (49 files) | Change every copy to `local function safe(fn, ...) local ok, r = pcall(fn, ...) ... end` | Yes: identical for every existing call, since the scan found no extra-argument calls | 45 files, internal only | Deferred: one mechanical change on its own |
| C2 | DUP-6: `call(fn, a, b)` drops a third argument | Vararg form | Yes | 4 files | Deferred, with C1 |
| C3 | DUP-7: `trail` not wrapped in pcall (quest/engine.lua:168, quest/npc.lua:317) | pcall like the other 11 copies | Yes | internal | Open (Low) |
| C4 | DUP-8: `quest/api_examples.lua` shipped, never required | Exclude from make_manifest.py, or move to docs/ | Yes: not referenced, including string-built requires | none | Open (Low): saves a 19 KB download per session |
| C5 | DUP-1 / DUP-2: stale backups in the repo folder, old `ameisen.zip` | Move outside the repo (they are not shipped) | Yes | none | Open: the user decides, since these are local files |
| C6 | Helper families (`now`, `trail`, `here_xyz`, `dist2`) | A shared `util.lua` only if the variants are proven equivalent; 10 variants of `now` differ in fallbacks | Not yet shown | many | Not planned |

## Group D: Performance and memory

| # | Finding | Measured? | Strategy | Status |
|---|---|---|---|---|
| D1 | PERF-1: ghost enemy scans at any distance | Yes: 0.72 ms/frame | Scan only within 60 yd of the corpse | **Done** (improvement not re-measured) |
| D2 | PERF-2: log dedupe defeated (about 6 lines/s) | Yes: 5.3 MB per 52 min | Dedupe on the note and target, not the stage list | Open |
| D3 | PERF-3: menu status values computed every frame | Yes: 0.14-0.45 ms/frame when the menu is open | Cache `is_started` and the module requires per frame | Open |
| D4 | PERF-4: path draw walks all nodes every frame | Estimate | Window around the player | Open |
| D5 | PERF-5: per-frame closures in `errorlog.guard` / `draw_mini` | Estimate | Hoist closures | Open |
| D6 | PERF-6: rest start 1-9 ms once per rest | Yes | Cache the food id list between rests | Open (low value) |
| D7 | PERF-7: tables keyed by GUID that never shrink | Size not measured | Prune entries older than N minutes | Open: measure a long grind session first |

## Group E: Architecture and maintainability

| # | Item | Status |
|---|---|---|
| E1 | AGENTS.md: skip-step sentence corrected (CORE-B-16) | **Done** |
| E2 | AGENTS.md: the stub root `3cf70445e7` no longer exists. The current installs are `daaa22`, `664322289a264b` and `ebe5e7d15a44b2aa650e7e27` (stubs identical). | Open: confirm which install is the "active" one |
| E3 | Split quest/engine.lua (see A6) | Deferred |
| E4 | Profiler blind spot: post-cascade tail (PERF-8) | Open |

## Testing requirements for the open items

- **B11 (IZI-1):** a session log with `cast_safe` refusals logged. Then a smart.lua harness: a refused spell is not counted as cast and gets no fail gap for `fast_queue_busy`.
- **A6:** compile under all three runtimes, then all quest tests. The upvalue count of `tick_inner` must stay at 60 or below.
- **C1/C2:** the scope-aware argument scan (audit/D) must stay at 0 extra-argument calls. Then the full suite.
- **A4 / B14:** the in-game prints listed in the audit report, section 13.
