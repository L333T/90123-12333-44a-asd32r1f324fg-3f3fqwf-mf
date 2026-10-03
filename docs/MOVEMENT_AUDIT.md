# Master Farmer — Player Movement Audit (v2.216.0, 2026-10-03)

**Status:** Phase 1 shipped in 2.217.0 (PR #236 merged; H1, H2, H3, H4, H5 done; Path
mode removed with `modes.lua` — H10 partly done, `path_runner.lua` kept for the
route preview). Phases 2–6 await approval.

Read-only audit. No code was changed for this document. Evidence is `file:line` in this
repo, the session logs in `scripts_log/MASTER_FARMER_ERRORS`, and the API stubs.
Items marked **verified** were re-read in the code after the sweep; **plausible** items
are from the code sweep and have not been reproduced.

---

## A. Movement architecture (as it is)

```text
Movement request         callers call the movement facade directly: nav_to / nudge /
                         nav_stop / combat_engage / halt  (no intent object)
      ↓
Movement decision        main.lua cascade order (early return = claims the tick):
                         watchdog → death → flight freeze → loot → conjure → rest →
                         trainer → vendor → equip → quest | grind engine
                         Inside the engines: fight_back → loot wait → rest → flight →
                         goal → waypoint walk
      ↓
Ownership                movement/own.lua — OWNER NONE | NAV | COMBAT, O.take() halts the
                         outgoing actuator first; STATE IDLE | NAVIGATION | COMBAT |
                         RESTRICTED arbitrated per frame in fsm.lua:266-324
      ↓
Path selection           nav.lua navigate(): Sentinel travel out of combat
                         (K.SENTINEL_TRAVEL) — move_direct < 30 yd with a clear ray,
                         find_path_avoid near danger/blacklist zones, else move_to;
                         walker steering in combat and as fallback
      ↓
Execution                two actuators only: simple_movement (walker.lua) and
                         SentinelNavClient (sentinel.lua). movement_handler = facing and
                         cast pauses. Raw core.input: strafe.lua, backpedal (locks.lua),
                         jump (repath.lua), dismount (combat.lua, resting.lua)
      ↓
Position / progress      fsm.pulse every frame; repath ladder every 0.25 s
                         (distance-to-goal progress, Sentinel path index counts)
      ↓
Arrival / failure        travel_near < 4 yd (2D) in the core; every caller also has its
                         own arrival test (see C)
      ↓
Recovery / replanning    ONE stuck authority: the repath ladder (replan 4 s → jump 7 s →
                         give up 11 s), Sentinel's own recovery waited on while it moves
                         the character, area_watch (20 s → blacklist ahead + re-path)
```

**Where it differs from the ideal model**

* The actuator layer is already centralised (single owner, `O.take`, pause reasons
  reference-counted). There is **no request/intent layer**: priority is the cascade
  order in `main.lua` plus early returns. It is deterministic, but implicit.
* Arrival is decided twice: the caller's own threshold and the core's `travel_near`.
* Nothing reacts to map / continent changes, loading screens or teleports.

Measured cost (session 2026-10-03 13:00, 475 samples): whole plugin **0.34 ms/frame avg,
0.72 max**; the largest movement entry, `mv:arbitrate`, **0.02 ms**. Performance is not
where the movement problems are.

## B. Movement files

| File | Responsibility |
|---|---|
| `movement.lua` | facade; unknown keys log once and return nil |
| `movement/const.lua`, `rt.lua` | tunables / shared mutable state |
| `movement/own.lua` | ownership, restriction (dead, CC, invalid), `may_issue` gates |
| `movement/walker.lua` | simple_movement actuator, pause reasons, fail marking |
| `movement/sentinel.lua` | Sentinel actuator, events, reachability, avoid paths, recovery watch |
| `movement/nav.lua` | `nav_to` / `nav_path` / `nudge` / `nav_stop` / `halt` |
| `movement/combat.lua` | `combat_engage` chase / hold band / retreat, `combat_release` |
| `movement/fsm.lua` | per-frame pulse, arbitration, walker stuck watch, look-ahead, hop chaining |
| `movement/repath.lua` | re-aim, the stuck ladder, area_watch, recovery_watch |
| `movement/locks.lua` | rest lock, cast/channel/loot locks, Frost Nova backpedal |
| `movement/zones.lua` | blacklist zones (TTL 900 s, mirrored to Sentinel), danger map |
| `movement/steer.lua`, `geom.lua`, `leash.lua`, `probe.lua`, `range.lua`, `util.lua`, `diag.lua` | steering, geometry, path leash, collision probes, facing/range/LoS, helpers, debug |
| `quest/engine.lua` | quest walks (`walk_to`), NPC approach, fight_back, stall recovery (30 s × 3) |
| `grind/engine.lua` | node walk, kill approach |
| `loot.lua`, `death.lua`, `resting.lua`, `vendor.lua`, `trainer.lua`, `watchdog.lua`, `conjure.lua`, `smart.lua`, `strafe.lua` | subsystem walks / stops / locks |
| `path_runner.lua`, `main.lua path_fight/path_handle_combat` | **dead** — nothing starts a path session |

## C. Arrival thresholds (one table)

| Where | Value | Metric |
|---|---|---|
| core `travel_near` | 4 yd | 2D |
| core `Rg.arrived` / `MIN_NAV` | 2 yd | 3D |
| repath `NEAR_DONE` / `DEAD_ZONE` | 5 / 3 yd | 2D |
| walker library threshold / final | 2.0 / 1.0 | library |
| quest `ARRIVE` / `TALK_ARRIVE` / `TALK_REACH` / `CLOSE_REACH` | 3 / 8 / 4 / 2.5 | 2D (+ `ARRIVE_DZ` 12) |
| grind node | 2 yd | 3D (`movement.arrived`) |
| vendor merchant spot / unit | 5 / 5 yd | 3D / `distance_to` |
| trainer unit | 5 yd | `distance_to` |
| loot reach / stopped | 3.5 / 5 yd | `distance_to` |
| death corpse | 32 yd | 3D |
| vendor quest-spot return | 8 yd | 2D |

The spread is mostly intentional (NPC vs node vs corpse). The two real seams are
the core's 4 yd vs callers' 2–3 yd (a caller can ask for a move the core refuses as
"already there"), and 2D/3D mixing near multi-level terrain.

## D. Duplicate logic

* **Stuck detectors** — seven, layered by time: repath ladder 11 s, Sentinel
  `stall_check` 12 s, `note_chase_failure` 10 s (combat), `area_watch` 20 s,
  `recovery_watch` 6 s, quest dialog stall 30 s × 3, watchdog 300 s. The core ones are
  coordinated (2.141.0 "one stuck authority"); two can still act on one combat incident
  (chase failure 10 s + ladder rung 3 at 11 s) — **plausible**.
* **NPC approach** — quest giver (`dialog_goal`), vendor, trainer, loot corpse each
  implement find → walk → stop in reach → interact with their own reach and retry
  rules. A shared helper is possible but each has different verification; see H-8.
* **Distance helpers** — `geometry.distance` (3D, allocates 2 vec3 + closure),
  `geometry.distance_flat`, `movement.arrived`, `player:distance_to`, plus local `near`,
  `d2`, `dist3`, inline sqrt in vendor / watchdog.
* `face()` is called twice per tick in grind and quest kill paths, then again by
  `rotation.tick` (it is throttled internally, so harmless).

## E. Conflicting logic (same tick / same incident)

| # | Sequence | Status |
|---|---|---|
| E1 | vendor.lua:1609 `nav_stop()` then :1640 `nav_place()` every tick when the merchant stands > 5 yd from the bot but the bot is within 5 yd of the recorded spot — stop/start stutter | **verified** |
| E2 | sentinel.lua: a deferred `stop` (path still being planned) is not cancelled by the `move_direct` short-leg path (begin_leg, ~:630) or the underfoot-skip `follow_path` (~:898); the old stop then kills the new leg, which later reads as an idle client / server timeout | **verified** |
| E3 | sentinel.lua:1193-1247 `repath_around` job survives `nav_stop`, `halt` and the rest lock; `repath_tick` can issue a Sentinel move up to 4 s later, including while eating | **verified** |
| E4 | watchdog.lua:225-231 Hearthstone hold calls `nav_stop` and claims the tick for 12 s with no combat check — the bot does not fight back during it | **verified** |
| E5 | quest engine 1817→1819 / `g_force_path`: `nav_stop` then `nav_to` in one tick (intentional re-route, one extra stop) | verified, low |
| E6 | resting `move_away_from` drops the rest lock and walks; next tick `halt_for_rest` re-takes it — by design, but no hysteresis | plausible |
| E7 | quest engine sets `keep_path(false)` every tick then `walk_to` sets it true — the pulse sees the last value of the previous tick | low |

## F. Performance

Measured above: not a bottleneck. Real but small items:

* `arbitrate` runs ~9 native pcalls per frame (`restriction_of`), and during the combat
  exit window `C.may_release` every frame (range, LoS, enemy lists) — fsm.lua:266-324.
* fsm.lua:304 builds a log string every frame even with debug off.
* `geometry.distance` / `distance_flat` allocate 2 vec3 + a closure per call; the quest
  walk calls them 1–4× per tick.
* `look_ahead` / `chain_hops` allocate 1–2 tables every 0.25 s; `stall_check` 3
  closures per second.
* loot / death / trainer / vendor call `nav_to` every tick — the core dedupes
  (`may_issue`: already moving, `SAME_DEST`, `MOVE_GAP`), so these are wasted calls,
  not repeated commands.

## G. Reliability issues

| # | Issue | Evidence | Status |
|---|---|---|---|
| G1 | Quest walk targets a learned NPC instead of RestedXP's waypoint; wrong NPCs learned in older versions persist on disk (`guide.learn_quest_npc` → `mark_dirty`) | session 13:40, turn in 233 walked to Sten Stoutarm 350 yd off the waypoint, 3 × 30 s stalls | **fixed in PR #236 (2.215.0, unmerged)**; persisted entries are only dropped when they refuse |
| G2 | No map / continent / loading / teleport handling: blacklist zones (x,y only, 15 min), reach cache (5 min), Sentinel fail memory, leash survive a continent change; WoW coordinates overlap between continents | no subscriptions (events.lua:237-257) | verified gap |
| G3 | E2 deferred stop kills a new leg | sentinel.lua | verified |
| G4 | E3 stale re-path job | sentinel.lua | verified |
| G5 | 4–5 yd gap: core `travel_near` < 4 vs ladder `NEAR_DONE` 5 — a blocked spot there re-issues, sits, is cleared, repeats, never blacklisted | repath.lua / util.lua | plausible |
| G6 | Combat rung 3 with no walk issued releases without blacklisting; the engine re-engages the same GUID → ~11 s loop | repath.lua escalate | plausible |
| G7 | `chase_direct` and `chase_path` ignore blacklist zones (combat.lua:499-531) | — | plausible |
| G8 | Prefetch pending keeps an arrived Sentinel leg "active"; N.watch re-handles arrival / may declare server_timeout after 8 s | sentinel.lua retarget | plausible |
| G9 | `try_random_unstick` callback sets `keep_path` / `goal_*` without checking the leg is still current | sentinel.lua:575-590 | plausible |
| G10 | `combat_stopped` latch needs LoS; LoS flicker near walls toggles hold/chase | combat.lua:403-417 | plausible |
| G11 | Dismount called every tick while mounted, unthrottled (combat.lua:426, resting.lua:932) | — | verified, low |
| G12 | Death: ghost is not a restriction; resurrect (`end_death`) re-issues nothing — the next tick's engines do | death.lua:263-291 | by design, OK |

Dead code found: Path mode (`path_runner.start` has no caller, `main.lua`
`path_fight` / `path_handle_combat`), `quest/npc.lua npc.talk / npc.at_npc`,
`movement.pause_for_loot / nav_pause / nav_resume`, the Sentinel branches of
`look_ahead` / `chain_hops` (pulse returns before them while Sentinel drives),
`SENTINEL_PULL` pull-in, `R.sn_bench_until` (read, never set).

## H. Proposed improvements

| # | Current → proposed | Why better | Perf | Reliability | Files | Risk |
|---|---|---|---|---|---|---|
| H1 | Deferred Sentinel stop survives a new direct leg → clear `stop_pending` in `begin_leg` (every new leg) | a new leg can never be killed by an old stop | none | + | movement/sentinel.lua | LOW |
| H2 | Re-path job outlives stop/rest → cancel it in `N.stop`, `Nv.halt` and when the rest lock is set | no movement after a stop or during eating | none | + | movement/sentinel.lua, locks.lua | LOW |
| H3 | Vendor stops every tick before walking to a merchant > 5 yd away → only `nav_stop` once the merchant unit is in reach (or not found) | removes the stutter | none | + | vendor.lua | LOW |
| H4 | Watchdog Hearthstone hold ignores combat → drop the hold when in combat or attacked | fights back; the hearth is re-tried by the existing timer | none | + | watchdog.lua | LOW |
| H5 | Dismount spam → throttle to one attempt per ~1 s | fewer native calls / UI errors | small + | = | combat.lua, resting.lua | LOW |
| H6 | No map-change handling → on continent change (verified API needed), clear zones, reach cache, Sentinel fail memory, leash, and `nav_stop` once | no blacklist from another continent; no stale leg after a hearth / flight / portal | none | + | movement/zones, sentinel, nav; main.lua | MEDIUM (needs an API verified in the stubs) |
| H7 | 4–5 yd gap (G5) → align `NEAR_DONE` with `MIN_NAV_TRAVEL` (both 4) or treat the gap as arrived | no re-issue loop near the goal | none | + | movement/repath.lua | LOW — after reproducing G5 |
| H8 | Combat drop/re-engage loop (G6), blacklist-blind chase (G7) → rung 3 marks the GUID for a short time even with no walk; chase checks `Z.blocked_xy` | no 11 s loops into the same wall | none | + | movement/repath.lua, combat.lua | MEDIUM |
| H9 | Purge persisted learned NPCs that fail the waypoint check (G1) | old wrong entries stop costing a stall | none | + | quest/engine.lua, quest/guide.lua | LOW (after PR #236) |
| H10 | Dead code (Path mode etc.) → remove, or wire Path mode back up | less to reason about | none | = | path_runner.lua, main.lua, npc.lua, fsm.lua | LOW (decision needed) |
| H11 | Movement intent: callers pass a short reason string to `nav_to` (`"quest turnin 233"`, `"vendor"`, `"loot"`), recorded with the destination | the log says WHY every leg was issued; stale-leg detection by owner subsystem | none | + diagnostics | movement/nav.lua + callers | LOW |
| H12 | Full central MOVEMENT_STATE / priority-request rewrite | **not recommended**: ownership is already single, the cascade already gives deterministic priority, and the real defects are the specific seams above | — | risk of regressions across every subsystem | — | HIGH |

## Implementation plan

**Phase 1 — Safe cleanup (low risk):** merge PR #236; H1, H2, H3, H4, H5. Each is a
few lines, each gets an offline lupa replay (the method used for 2.215 / 2.216).

**Phase 2 — Consolidation:** H10 (after the Path-mode decision); share one distance
helper set (`geometry.distance_flat`, allocation-free variants) for new code only.

**Phase 3 — State / intent:** H11 (reason strings); H6 map-change reset once the
continent/map API is verified in `.api`.

**Phase 4 — Intelligent navigation:** reproduce G5–G10 from logs or replays; fix the ones
that reproduce (H7, H8). Arrival hysteresis only where a log shows oscillation.

**Phase 5 — Performance:** optional — the debug string in arbitrate (fsm.lua:304),
allocation-free distance helpers. Expected gain is a fraction of 0.02 ms/frame.

**Phase 6 — Validation:** the matrix below, offline where it can be replayed, then one
in-game session per phase with the session log reviewed.

## Test matrix

| Scenario | Expected | How |
|---|---|---|
| Long-distance waypoint | Sentinel leg, no stalls | session log |
| Short waypoint (< 30 yd, clear) | `move_direct`, no overshoot | log + H1 replay |
| Quest pickup / turn-in | guide NPC at waypoint, verified result | 2.215 replay + log |
| Vendor | walk to merchant without stutter | H3 replay + log |
| Combat during navigation | NAV halted, COMBAT owns | existing behaviour, log |
| Combat ends | goal re-issued from source (quest/grind/vendor) | log |
| Stuck | ladder rungs in order, one action per rung | log |
| Navigation fails | fallback walker / blacklist / next goal | log |
| Map change | caches cleared, one stop | H6 replay + hearth test |
| Destination changes | re-aim without stop | log |
| Player dies / resurrects | halt; corpse run; engines resume | log |
| Mount | dismount once, no spam | H5 replay |
| Interaction target moves | re-route (E5) | log |
| RestedXP step changes | per-goal state reset | 2.215 replay |
| Watchdog hearth while attacked | fight first | H4 replay |
| Stop / rest during a re-path job | no movement afterwards | H2 replay |
