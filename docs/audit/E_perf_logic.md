> **Evidence appendix (2026-10-11, audit of 2.305.0).** Working notes from one audit pass, kept for the per-finding evidence (stub file:line citations, symbol tables, scenarios). Statuses here are as found BEFORE any fix. The current status of every finding, and which ones were re-verified, is in `docs/CODEBASE_AUDIT_REPORT.md`.

# Audit E - Performance / memory and state / logic robustness

Repo: `C:\Users\ebene\OneDrive\Desktop\SNES_\Master_Farmer_Grindbot` (v2.305.0). Read-only audit, 2026-10-11.
Logs analysed (all 2026-10-11):

- 664322289a264b: `session_2026-10-11_03-21-29.log`, `session_2026-10-11_03-24-18.log` plus `_part2` and `_part3` (one session, 03:24 to 12:53, about 9.5 h)
- daaa22: `session_2026-10-11_13-42-49.log`, `session_2026-10-11_13-51-26.log`

Labelling: **measured** means the number comes straight from PERF/SPIKE/MEM/BEAT lines. **Derived** means it is arithmetic on measured numbers, for example ms per tick = ms/frame x fps / ticks per second. **Estimate** means it was not measured.

How the profiler attributes time (errorlog.lua `perf_mark`): each `probe(tag)` closes the previous segment, so a tag's time runs until the next probe. Two consequences matter below:

1. The post-cascade work in the update wrapper (main.lua:917-939: `release_data_chunks`, `strafe.update`, `allow_reads`, `errorlog.tick_end`/BEAT) is charged to whichever probe ran last. On bot-tick frames that is `u:death`, `u:quest.tick done` or `u:loot.frame`. On non-tick frames it falls after `probe("-")` (main.lua:533) and is **not counted at all**.
2. Tag names are therefore partly misleading. For example, `u:loot.frame` in part3 is tick bookkeeping while the player object is invalid; the loot code itself is idle.

---

## (a) Measured profile summary

| Session (install) | Span | Avg fps (frames/10 s) | ms/frame mean / median / p95 / max | Top probes (mean ms/frame when listed) | SPIKEs | Lua heap min-max (mean), MEM lines |
|---|---|---|---|---|---|---|
| 03-21-29 (664) | 3 min, idle | ~188 | 0.36 / 0.44 / 0.47 / 0.47 | gui:menu.draw 0.27, u:begin 0.036, u:izi.on_update 0.031, gui.draw 0.022 | 0 | 13 894-21 410 KB (load peak 21 410) |
| 03-24-18 (664) | 52 min, questing then ghost from 04:05:45 | ~187 | 0.31 / 0.30 / 0.43 / 0.49 (alive 0.31 mean, ghost 0.30) | u:death 0.140 (ghost), u:quest.tick done 0.082 (max 0.21), gui.draw 0.046, u:begin 0.039, u:vendor 0.037 (max 0.23), u:keybinds 0.020, mv:arbitrate 0.018 | 4 | 13 517-16 671 KB (14 806), 110 lines, no trend |
| 03-24-18_part2 (664) | 6 h (04:16-10:15), ghost, then player invalid from 04:35:57 | ~187 dropping to ~64 | 0.17 / 0.15 / 0.30 / **1.81** | u:death 0.30 (**0.70-0.73 from 04:18:29 to 04:23:36**), u:begin 0.043, gui.draw 0.040, u:loot.frame 0.039 (max 1.69) | 0 | 13 469-15 737 KB (14 506), 693 lines, flat |
| 03-24-18_part3 (664) | 2.6 h (10:15-12:53), player invalid | ~64 | 0.15 / 0.15 / 0.16 / 0.19 | u:begin 0.043, gui.draw 0.040, u:loot.frame 0.040, u:keybinds 0.016 | 0 | 13 468-15 505 KB (14 501), 297 lines, flat |
| 13-42-49 (daaa22) | 8 min, idle with menu open | ~200 | 0.58 / 0.65 / 0.70 / 0.73 | gui:menu.draw **0.40**, on_render **0.14**, u:begin 0.031 | 0 | 13 359-23 724 KB (load peak 23 724) |
| 13-51-26 (daaa22) | 3 min, vendor/rest | ~198 | 0.36 / 0.36 / 0.39 / 0.39 | on_render 0.14, gui.draw 0.058, u:begin 0.034, u:vendor 0.033 | 2 | 14 480-23 742 KB (load peak) |

### SPIKE lines

All six SPIKE lines in the logs come from `u:healing`, which is the rest path (resting.lua). In each line the segment label names the probe that **opened** that segment.

| Time | Total | Heap delta | Worst segments |
|---|---|---|---|
| 03:27:16 | 1.89 ms | +93 KB | (single segment) |
| 03:28:07 | 2.54 ms | +255 KB | rest:use 0.49 ms +70 KB, rest:checks 0.46 ms +49 KB, rest:food_ids 0.44 ms +30 KB, rest:halt 0.42 ms +36 KB |
| 03:57:06 | **8.77 ms** | +123 KB | rest:halt **3.77 ms**, rest:decide **3.58 ms**, rest:food_ids 0.79 ms +36 KB, rest:checks 0.53 ms +62 KB |
| 03:57:25 | 4.33 ms | +6 KB | rest:decide **4.25 ms** |
| 13:53:29 | 7.03 ms | +237 KB | rest:used **3.84 ms**, rest:food_ids 1.19 ms +41 KB, rest:checks +46 KB, rest:use 117 +60 KB |
| 13:54:28 | 1.22 ms | +2 KB | rest:auras 1.20 ms |

The spikes happen once per rest start or item use. They are not recurring per frame.

### Heap

There is **no monotonic growth** in about 9.5 h on 664 or in the two daaa22 sessions. The heap saw-tooths between about 13.5 and 15.7 MB and keeps the same band from 04:16 to 12:53. The load peak of 21-24 MB drops to about 14 MB within 30 s, which is consistent with the release of DATA_CHUNKS.

**Caveat:** only about 40 min of the 9.5 h was active play (03:24-04:05). The other 8.5 h was a stuck ghost, then a disconnected client (see LOGIC-1). A long active-grind session has not been measured, so the slow unbounded tables in PERF-7 are not ruled out.

### The 5 most expensive recurring probes, traced to code

| # | Probe | Measured | Code |
|---|---|---|---|
| 1 | `u:death` (ghost) | 0.14 ms/frame, which is about 2.7 ms per bot tick (derived: 187 fps / ~9.7 ticks/s). It rose to 0.70-0.73 ms/frame (about 13 ms/tick, 5.1x) for 5 min with identical BEAT state. | death.lua:417-446. `safe_retrieve_pos` (death.lua:256-276) calls `hostiles_near`, which does a `unit_helper:get_enemy_list_around` scan, once when the corpse is clear and **5 times** (corpse + 4 offsets) when a mob is within 8 yd. The 5x ratio matches 0.14 -> 0.72 (estimate of cause). This runs every tick even at 273 yd. It also includes the post-cascade wrapper and the BEAT write (note 1 above). |
| 2 | `gui:menu.draw` | 0.14-0.45 ms/frame whenever the main window is open (mean 0.40 in the 13:42 session). This is the largest single per-frame cost when the bot is idle. | gui.lua:2905 `menu:draw()` (ui.lua) plus the `menu:set_status` value closures (gui.lua ~2070+). These call `gui.is_started()` twice (State label), `pcall(require,"rotation")` (class_status) and `pcall(require,"movement")` (Movement label) on every frame. |
| 3 | `on_render` | 0.13-0.15 ms/frame on daaa22, at most 0.01 on 664 | main.lua:773-799. The likely cause (estimate) is `path_runner.draw` (path_runner.lua:747-822) with "draw_path" ticked. It walks up to 300 nodes per frame with `near_player`/`wp_vec` per node and a closure per `line_3d`. `movement.on_render` only does work with move_debug on. |
| 4 | `u:begin` | 0.03-0.06 ms/frame, every frame | main.lua:496-503: `errorlog.frame`, `collectgarbage("step",16)` every frame, `errorlog.tick(safe(function() return izi.now() end))` (a closure per frame). |
| 5 | `gui.draw` | 0.02-0.08 ms/frame, every frame | gui.lua:3046 -> `mini_tick` -> `draw_mini` (gui.lua:2943-3020). About 13 `pcall(function() ... end)` closures, about 10 `vec2.new`, plus string formats per frame. `gui.is_started()` runs per frame and does 4x `is_on`, `pcall(require)` and `izi.me()`. |

Honourable mentions:

- **`u:quest.tick done`** is 0.082 ms/frame (max 0.21), about 1.6 ms per tick (derived). This is **not** quest code: `u:quest.tick` itself reads 0.000 and its sub-probes are tiny. It is the wrapper tail (strafe.update, data-chunk release, BEAT build and write). See PERF-2 and PERF-8.
- **`u:vendor`** spikes to 0.23 ms/frame.

---

## (b) Findings

Severity is about the real effect on a bot running unattended. Confidence is how sure I am that the mechanism is right.

### LOGIC-1 | Critical | High (measured end-to-end) | Corpse run deadlocked by a nav blacklist zone that keeps refreshing itself

**Files:**

- death.lua:290-300 (`run_to` ignores `nav_to`'s result)
- movement/nav.lua:158-161:
  ```lua
  if Z.blocked_xy(x, y) then
      W.mark_fail("blacklisted", dest)
      return false
  end
  ```
- movement/const.lua:155 `K.OFFMESH_WORDS = { ..., "blocked", "blacklisted", ... }`
- movement/walker.lua:143-150: an off-mesh fail calls `Z.blacklist_area(at, ZONE_RADIUS 12, reason)`
- movement/zones.lua:103-111: merging within ZONE_MERGE 10 yd **moves the zone centre and resets `zn.t = t`**
- deathzones.lua:202-210 `push_nav` (keep = true, r up to 30) and 365-369 `pull_nav` -> `Z.remove_area(z.x, z.y)` (removes only one zone within 10 yd of the death-zone centre)

**Scenario (it happened):**

1. 04:05:45: third death to Snow Leopard. The death zone is created at (-5963,-527), r 36, for 10 min. The corpse lies at (-5952,-531), 11.7 yd from the zone centre.
2. The ghost's `nav_to(corpse)` sees `blocked_xy` = true and calls `mark_fail("blacklisted", corpse)`. "blacklisted" is in OFFMESH_WORDS, so a **new 12 yd zone is created centred on the corpse**. It is not merged, because 11.7 > ZONE_MERGE 10.
3. Every following attempt merges into that corpse zone, which refreshes `t`. Attempts come at most every max(QUIET_OFFMESH 5 s, FAIL_COOLDOWN 6 s), well inside ZONE_TTL 900 s, so the zone never expires.
4. At 04:15:16 the death zone expired and `pull_nav` removed only the zone near (-5963,-527). The corpse zone stayed.
5. The BEAT reads "Corpse 273 yd" unchanged from 04:05:46 until 04:35:57. MEM shows "ameisen requests 0 issued" for that whole window.
6. About 30 min of no movement triggers WoW's AFK logout: at 04:35:57 the map goes 1426 -> 0 and hp reads "?". The bot then idled for **8.3 h** until 12:53.

**Control case:** the 03:46 death to Ice Claw Bear also had its corpse inside a death zone. That corpse lay 7.3 yd from the zone centre (< 10), so the self-zone merged into the death zone. The two expired together and the run resumed at **exactly** 03:55:48. This confirms the mechanism.

**Impact:** measured. One session lost about 8.5 h of botting. Any destination inside any zone can lock itself the same way.

**Fix:**

1. A destination refused by `blocked_xy` must not call `mark_fail` with an off-mesh reason. Use a non-off-mesh reason such as "zone", or remove "blacklisted" from OFFMESH_WORDS.
2. `blacklist_area` must not refresh `t` or move the centre of an existing zone when the same caller re-blacklists it.
3. Death zones must not apply to the player's own corpse run. Skip `push_nav` while `state.dead.waiting`, or give `nav_to` an "ignore zones" flag for corpse retrieval.
4. `pull_nav` should remove by id, not by "first zone within 10 yd".

**Regression risk:** Medium. Off-mesh classification feeds `Pr.set_off_mesh` and the cooldowns. Test a real off-mesh destination and a death-zone grind route.

### LOGIC-2 | High | High | No progress watchdog or cap on the corpse run, and death zones block retrieval by design

**Files:**

- death.lua:433-446: `run_to` is called every tick with no progress check and no fallback
- watchdog.lua:191-198 and 245-247: `travel_tick` only runs while `travelling()` (quest travel, or `is_navigating()` = owns NAV and is moving). A ghost that is not moving is never "travelling".
- deathzones.lua AVOID_BASE 600 s up to AVOID_MAX 3600 s

**Scenario:**

- Any nav refusal (LOGIC-1, a Sentinel failure, the corpse z on bad terrain) leaves the ghost standing with no log line except the static note. Nothing escalates, and a 30 min AFK logout ends the run.
- Even without LOGIC-1, a 4th or later death in the same zone extends avoidance up to 60 min. If the corpse is inside, the ghost waits longer than the 30 min AFK limit.
- Measured: the first instance cost 9 min 40 s idle (03:46:08 -> 03:55:48).

**Impact:** measured, as above.

**Fix:**

1. Keep the best corpse distance. If it has not improved by 5 yd in 30-60 s, trail the reason (`movement.last_fail_reason()`) and escalate: direct nav ignoring zones, then a forced Sentinel request, then the spirit-healer revive option.
2. Send a small input (jump) every few minutes while a ghost waits, to avoid the AFK logout.

**Regression risk:** Low to medium.

### LOGIC-3 | High | High (code path; the pattern was seen before as "recovery 25 of 3") | Quest stall "recovery N of M" can still exceed M

**Files:** quest/engine.lua:1609-1669, quest/guide.lua:3056-3069.

**Code:** recoveries increment (1609) and the trail prints `recovery %d of %d` (1615). With no giver (`gv == nil`) and `recoveries >= STALL_MAX`, the code calls `mark_goal_done` and returns **without resetting `recoveries`** (1664-1668). Only `stall_reset` (1538, called at 3719 on a **step change**) clears it. `guide.skip_current` returns false when the step was already skipped once (`skip_cur.num == step.num`, guide.lua:3059) or when RestedXP lacks the call (AGENTS.md: "RestedXP has no skip step API").

**Scenario:**

1. A waypoint or object goal with no NPC stalls 3 times, so the goal is marked done.
2. RestedXP keeps the step, and goals marked done are retried after 30 s.
3. The next stall prints "recovery 4 of 3". `skip_current` returns false, so the goal is marked done again.
4. Then "recovery 5 of 3", "6 of 3"... about every 60 s for as long as the step lasts. Each round also does `npc.close`, `nav_stop`, `guide.invalidate` and clears `g_bad_givers`.

**Impact:** estimated. Indefinite loop on that step with misleading logs. This is the same class as the 01:57 "25 of 3" incident.

**Fix:**

1. Reset `recoveries` to 0 at every give-up.
2. Keep a separate per-goal give-up count. After 2 give-ups, park the goal for N minutes in a keyed table.
3. Clamp the printed N to M.

**Regression risk:** Low.

### LOGIC-4 | Medium | Medium | `jump()` (JumpOrAscendStart) without the paired `ascend_stop`

**Files:** movement/repath.lua:171 (stuck ladder rung 2), movement/repath.lua:347 (after an area blacklist), quest/engine.lua:3018 (stand up before a sit retry).

The stub (`.api/core.lua` jump / ascend_stop) says "Pair it with ascend_stop to end a climb". locks.lua:93 and 114 already do this for the backpedal jump (added 2.110.0).

**Scenario:** the character is stuck while swimming, or the quest sit retry triggers. `jump()` leaves ascend held, so the character keeps rising to the surface or bobbing. Whether ground-held jump repeats depends on the client. Nothing else calls `ascend_stop` (only locks.lua). on_unload (main.lua:956-968) does not release it either.

**Impact:** estimated. Swim paths fail, and the character bobs at the surface until the next backpedal.

**Fix:** a shared `U.tap_jump()` that schedules `ascend_stop` about 0.15 s later from the pulse (reuse `R.backpedal_jump_release`-style state). Also add `ascend_stop` to on_unload.

**Regression risk:** Low.

### LOGIC-5 | Medium | Medium | izi callbacks registered at module load with no once-per-session guard or unsubscribe

**File:** movement/fsm.lua:442-466. It registers `izi.on_combat_start`, `izi.on_combat_finish` and `izi.on_spell_success`.

The http loader clears `package.loaded` for **every** manifest module on install (plugin_loader/http_loader.lua:190), but `common/izi_sdk` is not in the manifest, so its subscriber lists survive. callbacks.lua:122-145 already solved this exact problem with an NS guard plus unsub (2.271.0). fsm.lua was left out.

**Scenario:** the bot is closed and re-opened from the launcher in the same Lua state, which re-runs the loader install. That adds 3 more handlers, and the previous ones keep the whole old movement/* module graph alive. Each spell success then runs N copies, each doing `pcall(izi.me)` plus two `get_guid` calls.

**Impact:** estimated. A small CPU cost per event, and old module graphs are retained, likely 100s of KB per reload.

**Fix:** route through callbacks.lua (`NS` handler table plus single registration), or store the unsubs in NS and call them in on_unload.

**Regression risk:** Low.

### LOGIC-6 | Low | Medium | Partial module refresh leaves modules bound to an old `state`

**Files:** main.lua:16-77 (PLUGIN_MODULES lists `state` but not movement/*, quest/*, grind/*, gather/*), movement/util.lua:18 and 85-87 (`U.here_xyz()` reads `state.cached_pos` from the `state` captured at first load), movement/combat.lua:16, quest/engine.lua:33, grind/engine.lua:14.

**Scenario:** main.lua re-runs without a full package reset (the "hot reload" its own comments describe). `targeting.cache_player` then writes the **new** `state.cached_pos` while movement reads the **old** one, frozen. Every travel_near, clamp_leg and may_issue distance is computed from a stale position, and `state.mark_unreachable` from movement/combat writes to the old table.

A loader install clears everything (http_loader.lua:190), so this only applies to non-loader reloads. That is why confidence is not higher.

**Impact:** estimated. Navigation is broken until a full reload.

**Fix:** have main.lua clear every module listed in manifest.lua (or the full movement/*, quest/*, grind/*, gather/* sets) instead of a hand list, or have `here_xyz` read `package.loaded.state`.

**Regression risk:** Low.

### LOGIC-7 | Low | High | Corpse revive retries are uncapped

**File:** death.lua:433-466.

**Scenario:** after 6 refused revives the reach shrinks to 4 yd. From then on `resurrect_corpse` fires every 1.5 s forever, with no alternative. A wrong corpse z, LoS, or a mob standing on the corpse keeps the bot there.

**Impact:** estimated, rare.

**Fix:** after about 20 tries, trail it, wait out the hostiles via `safe_retrieve_pos`, then fall back to the spirit healer.

**Regression risk:** Low.

### LOGIC-8 | Low | High | Mixed clocks exist only in fallback paths

Per the stubs:

- `core.time()` is seconds since injection.
- `core.game_time()` is **ms since game start** (a different epoch).
- `izi.now()` is "core timer seconds (same source as core.now())".

Measured: MEM and PERF are scheduled on `izi.now` (errorlog.lua `errorlog.tick(now)`) and stamped with `core.time`. Their t= spacing is exactly 10.00 s and 30.00 s across hours, so the two clocks run at the same rate. No cross-clock comparison was found in the main paths. Each module compares against its own clock: strafe/state/errorlog use core.time, the rest use izi.now.

Fallbacks that would mix epochs if the primary call failed intermittently:

- castq.lua:59-65: `izi.now` else `game_time()/1000`
- spellcheck.lua:32-40: else `os.clock()`, which is process CPU time
- targeting.lua:1184 and adapt.lua:585: `safe(core.time) or izi.now()`

**Scenario:** `izi.now` throws once. `castq.last[key]` then holds a game-time stamp about hours apart, and the REQUEUE_GAP check misfires once.

**Impact:** estimated, negligible.

**Fix:** use one `now()` helper (U or state) with a single fallback that keeps the same epoch.

**Regression risk:** None.

### LOGIC-9 | Low | Medium | `gui.is_started()` dereferences the player outside pcall

**File:** gui.lua:1720 `local class_id = me and me.get_class and me:get_class() or gui.class_id()` (the same at 1751).

**Scenario:** `izi.me()` returns a freed or invalid object during a loading screen or zoning, and `get_class` throws. `is_started` is the first call of `death.tick` (death.lua:394) and of the strafe gate, so the whole cascade tick errors and gets logged as "repeated N times".

**Impact:** estimated, transient.

**Fix:** use `pcall(me.get_class, me)`.

**Regression risk:** None.

### PERF-1 | Medium | High (measured cost, estimated cause) | The ghost tick rescans enemies around the corpse every tick, up to 5 scans

**File:** death.lua:424 `local dest = safe_retrieve_pos(corpse, my_level)` runs before the distance check. death.lua:256-276 calls `hostiles_near` for the corpse and 4 offsets. death.lua:213-215 does a `get_enemy_list_around` scan per call, and the hostiles_near loop uses `call()`.

**Scenario:** the ghost is 273 yd away while a mob wanders onto the corpse.

**Impact:** measured. `u:death` went from 0.14 to 0.72 ms/frame for 5 min (04:18:29-04:23:36), about 13 ms per bot tick, which is 78% of the plugin's frame time then (0.87-0.92 ms/frame total). The safe spot is only used when `d <= reach`.

**Fix:** compute `dest` only when `d < RETRIEVE_STEPS[1] + 15`, and cache it for 1 s keyed on the corpse position.

**Regression risk:** Low.

### PERF-2 | Low-Medium | High | Alternating stage lists defeat BEAT dedupe, so "Detailed session log" appends ~5-6 lines/s

**Files:** errorlog.lua `tick_end` (`body = table.concat(beat_tags...) .. " | " .. extra`, compared whole against `beat_last_body`). quest/guide.lua:385 `probe("rxp:" .. name)` only fires on refresh ticks, so consecutive ticks alternate between "settings>rxp:...>death" and "settings>deathzones>escape>death". Each `write` calls `stamp()` (`core.get_local_time` plus format), `game_time()` (format) and `core.write_log_file`.

**Measured:**

- part1: 18 553 BEAT lines in 52 min (5.9/s); the file is 5.3 MB per 52 min.
- part2 ghost stretch: 8 223 lines in about 26 min, all identical except the tag alternation.
- Once the bodies stopped alternating (player invalid), the same probe dropped to 0.04 ms/frame at 64 fps.
- `u:quest.tick done`, which is mostly this tail, is about 1.6 ms per tick (derived). The share that is file I/O versus beat_extra is an estimate.

**Fix:** dedupe on `extra` plus the stage list with `rxp:*` (and other refresh-only tags) stripped, or on `extra` alone. Cache the `stamp()` string per second.

**Regression risk:** Low. It only touches the diagnostic log.

### PERF-3 | Low | High | Main menu draw costs 0.14-0.45 ms/frame while open

**Files:** gui.lua:2905 and gui.lua `menu:set_status` value closures (~2070-2140), which run `gui.is_started()` twice, `class_status` (`pcall(require)` plus `menu:get`) and the Movement label (`pcall(require,"movement")` plus state reads) every frame.

**Measured:** mean 0.40 ms/frame for 7 min in the 13:42 session.

**Fix:** compute the status rows at 4-5 Hz into a cached table.

**Regression risk:** Low. The status line would lag up to 0.25 s.

### PERF-4 | Low | Medium (attribution is an estimate) | `path_runner.draw` walks the whole path every frame

**File:** path_runner.lua:747-822. Per frame it does up to 300 iterations of `wp_at`/`near_player`, a `wp_vec` allocation per near node, and a `pcall(function() core.graphics.line_3d(...) end)` closure per segment.

**Measured:** `on_render` is 0.13-0.15 ms/frame on daaa22 against at most 0.01 on 664. The draw_path setting is not logged.

**Fix:** precompute the vec3 list once per path, recompute "near" at 2 Hz, and call `line_3d` with `pcall(f, args)` instead of a closure.

**Regression risk:** Low.

### PERF-5 | Low | High (sites) / estimate (cost) | Steady per-frame allocation churn

**Sites:**

- main.lua:502 and 531 `safe(function() return izi.now() end)` (2 closures per frame), main.lua:505 `pcall(function() izi.on_update() end)`
- `errorlog.guard` (errorlog.lua `guard`): a `{ n = select('#', ...), ... }` table plus an xpcall closure on **every** call, and it is called 4 times per frame (main.lua:156, 916, 930, 943). All four call sites pass no arguments.
- gui.lua `draw_mini` (2943-3020): about 13 closures, about 10 `vec2.new`, and 3-4 strings per frame
- main.lua:327-338 `player_is_busy`: 4 closures

**Impact:** estimated at 30-40 short-lived objects per frame, about 6-8 k/s at 190 fps, roughly 0.3-0.5 MB/s of garbage. That is consistent with the measured 2 MB heap saw-tooth, which the GC step(16) per frame (inside u:begin, 0.03-0.06 ms) keeps flat.

**Fix:**

- `guard`: a fast path when `select('#', ...) == 0` that calls `xpcall(fn, handler)` with a module-level handler.
- Call `pcall(izi.now)` directly.
- Hoist the mini-window vec2s and colours to upvalues.

**Regression risk:** Low.

### PERF-6 | Low | High (measured) | Rest start and item use cost 1-9 ms in one tick

**File:** resting.lua:975-1029. The `rest:decide` segment includes `rest_threat` (an enemy scan) and measured 3.58-4.25 ms. The `rest:halt` segment includes `halt_for_rest` plus consume and measured 3.77 ms. resting.lua:470-473: the `rest:used` segment (`present_reset` plus `rtrail`, which is a log-file write) measured 3.84 ms. `food_ids`/`water_ids` allocate 30-41 KB each time.

**Measured:** 6 spikes, 1.2-8.8 ms, heap +2 to +255 KB. Each happens once per rest, so a 9 ms hitch at most.

**Fix:** cache `rest_threat` for 0.5 s, reuse food/water lists until the bag signature changes (already partly done), and defer `rtrail` writes.

**Regression risk:** Low.

### PERF-7 | Low | High (code) / estimate (size) | Tables keyed by GUID that never shrink in normal play

**Sites:**

- state.lua:186: `mark_killed` stores **every killed GUID** in `state.combat.unreachable`. state.lua:265-280 drops an entry only when that same GUID is queried again after 45 s. Dead corpses despawn and are never queried, so one entry leaks per kill.
- loot.lua:77 and 300/569/606 `ignored[guid]`: reset only on Stop or mode change (312).
- adapt.lua:108 and 455 `spec_cache[guid..":"..id]`: never pruned outside `_reset`.
- errorlog.lua `seen[where.."|"..err]`: grows once per distinct error text, and texts with GUIDs or numbers are unique.

**Impact:** estimated at about 100 B per kill, roughly 50 KB per 500 kills. Not visible in the measured heap, but active time was only 40 min.

**Fix:** prune `unreachable` in `mark_killed` when there are more than 64 entries (the same pattern as `note_engaged`), and cap `ignored`/`spec_cache` at about 200 entries with a time-based sweep.

**Regression risk:** None.

### PERF-8 | Info | High | Profiler blind spot: the post-cascade tail is misattributed or uncounted

**File:** main.lua:912-940. After `guarded("on_update", on_update)` the wrapper runs `release_data_chunks` (every 5 s), `strafe.update` (every frame), `allow_reads` and `errorlog.tick_end` with no probe of its own.

**Measured effect:**

- Labels mislead: `u:quest.tick done` is 0.082 ms/frame and `u:loot.frame` is 0.04 ms/frame while the loot code is idle.
- On non-tick frames (about 95% of frames) the tail is not counted at all, because it falls after `probe("-")` (main.lua:533). The reported ms/frame is a lower bound.

**Fix:** `probe("u:tail")` at the start of the wrapper tail and `probe("-")` only at its end. Have main.lua:533 mark `"u:tail"` instead of `"-"`.

**Regression risk:** None.

---

## Checked and found sound (no finding)

- **Held movement keys:** strafe.lua releases forward and strafe on every exit (gate failure, range loss, timer, stop, module load at strafe.lua:212-215). The walker never uses `move_forward_*`, so strafe's `move_forward_stop` cannot cancel a nav move. Backpedal is time-bounded in `Lk.backpedal_tick` (locks.lua:101-118), which runs in `movement.pulse` every frame, plus `backpedal_stop` in `Nv.halt` and the module-load release. on_unload releases forward and backward (main.lua:963-964). The only held-input gap is LOGIC-4.
- **Main-loop clock guard:** `now_t < next_bot_tick and (next_bot_tick - now_t) <= BOT_TICK` (main.lua:532) survives a clock reset.
- **Callback registration:** events.lua (NS.events_registered), adapt.lua (NS.adapt_cast_cb), callbacks.lua (NS.izi_cb_unsub plus uninstall), gui hotkeys (NS.unbind_hotkeys) and main.lua update/render callbacks (is_stale gate) are each registered once per session. The exception is movement/fsm.lua (LOGIC-5).
- **Bounded caches:** sentinel `reach` (200), terrain `hc` (H_MAX), util `corridor_cache` (400), predict (300), targeting `find_cache` (100), castq `last` (200), quest `zf.cache` (256), `g_obj_skip` (swept at quest/engine.lua:3038), state `killed` (KILLED_MAX 48), state `engaged` (TTL sweep over 64), movement zones (MAX_ZONES 24).
- **Quest NPC ladder:** with a giver (`gv` set), the ladder resets `recoveries` at 3 (quest/engine.lua:1646). Flight retries are capped (FLY_FAIL_MAX). terrain/repath re-plans are capped per destination (WALL_MAX).
