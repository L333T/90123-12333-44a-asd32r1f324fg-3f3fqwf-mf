> **Evidence appendix (2026-10-11, audit of 2.305.0).** Working notes from one audit pass, kept for the per-finding evidence (stub file:line citations, symbol tables, scenarios). Statuses here are as found BEFORE any fix. The current status of every finding, and which ones were re-verified, is in `docs/CODEBASE_AUDIT_REPORT.md`.

# Audit A - core / movement API usage (read-only)

Repo: `C:\Users\ebene\OneDrive\Desktop\SNES_\Master_Farmer_Grindbot` (version banners 2.305.0)
Contract: `C:\Users\ebene\OneDrive\Documents\daaa22\scripts\.api` (`core.lua`, `game_object.lua`, `menu.lua`, `common/**`) plus `C:\Users\ebene\Downloads\Sylvanas_coreAPI_IZI_API\`.
Note: AGENTS.md names the stubs at `...\3cf70445e7\scripts\.api`; this audit used the `daaa22` copy the task named. If the two differ, re-check the findings against the active install.

Scope: main.lua, callbacks.lua, events.lua, watchdog.lua, death.lua, deathzones.lua, movement.lua, movement/*.lua (20 files), path_runner.lua, geometry.lua, errorlog.lua, settings.lua, gamever.lua, header.lua, loader.lua, state.lua, ui.lua (about 15.8k lines).

Method: grep of every `core.*`, `izi.*`, `require("common/...")` and every `:method(` / `pcall(x.method, x, ...)` in scope. Each name was looked up in the stubs (exact name, `.` vs `:`, parameters, returns). Then the call sites with a non-trivial contract were read: sentinels, nil returns, append semantics, TTLs, input pairing and stored units.

---------------------------------------------------------------------------------------------------

## (a) API symbol table

### core.*

| symbol | declared? (stub file:line) | used in (file:line) | notes |
|---|---|---|---|
| core.log / log_warning / log_error | yes core.lua:16/20/24 | everywhere (~52 sites) | ok |
| core.time | yes core.lua:312 | ui.lua:661,700; main.lua:916; errorlog.lua:82 | ok (seconds) |
| core.cpu_time | yes core.lua:330 (ns) | errorlog.lua:367-373 | ok, detected with type() |
| core.get_local_time | yes core.lua:849 (table) | errorlog.lua:70 | ok |
| core.get_map_id | yes core.lua:368 ("id of the current localplayer map") | main.lua:818; deathzones.lua:86; hazards.lua:82; sentinel_adv.lua:48; path_runner.lua:299; gamever.lua:113 | see CORE-A-4 (used as a continent id) |
| core.get_map_name | yes core.lua:445 | main.lua:819 | ok |
| core.get_height_for_position | yes core.lua:488 (0 on a miss) | movement/util.lua:152; movement/terrain.lua:185 | util.lua ignores the 0 sentinel (CORE-A-2); terrain.lua handles it |
| core.get_game_version | yes core.lua:505 | gamever.lua:36; header.lua:32; ui.lua:651 | ok |
| core.get_exact_game_version | yes core.lua:511 | gamever.lua:50; header.lua:33 | ok |
| core.create_data_file | yes core.lua:664 (returns boolean since 2026-10-06) | settings.lua:278; hazards.lua:124; deathzones.lua:130; ui.lua:636 | return value never checked (CORE-A-8) |
| core.create_data_folder | yes core.lua:686 | settings.lua:206; hazards.lua:120; deathzones.lua:127; ui.lua:634-635 | ok |
| core.write_data_file | yes core.lua:721 (APPENDS; missing file = silent no-op) | settings.lua:279; hazards.lua:125; deathzones.lua:131; ui.lua:637 | create-then-write pattern is correct; see CORE-A-8 |
| core.read_data_file | yes core.lua:749 (string, may be nil/"") | settings.lua:230; hazards.lua:97; deathzones.lua:136; ui.lua:401,407,624 | ok, all type-checked |
| core.get_data_file_size | yes core.lua:909 (0 when missing) | settings.lua:224; ui.lua:442,445 | ok |
| core.read_dir | yes core.lua:949 (EMPTY table when missing) | ui.lua:448 | sentinel mis-read, cosmetic (CORE-A-9) |
| core.create_log_folder / create_log_file / write_log_file | yes core.lua:795/770/816 | errorlog.lua:98,102,110,114,129 | ok |
| core.register_on_update_callback | yes core.lua:36 | main.lua:912 | once per load, stale-guarded (intended) |
| core.register_on_render_callback | yes core.lua:40 | main.lua:941 | same |
| core.register_on_render_window_callback | yes core.lua:32 | main.lua:151 | same |
| core.register_on_game_event_callback | yes core.lua:300 (signature only in docs: `function(event_name, args)`) | events.lua:298 | once per session via NS.events_registered: ok |
| core.reload_game_ui | **NO** (undeclared) | main.lua:457,488 | intentional per AGENTS.md, type()-guarded (CORE-A-11) |
| core.http_get | yes core.lua:5283 | ui.lua:629-638 | ok (callback code, _, data) |
| core.http_post | yes core.lua:5321 (overload url, body, cb) | header.lua:38 | ok |
| core.get_mouse_wheel_delta | yes core.lua:5351 | ui.lua:1179,2165 | ok |
| core.input.set_target | yes core.lua:3067 | main.lua:414 | target validated first: ok |
| core.input.interact_with_object | yes core.lua:3376 (dispatch only) | geometry.lua:100 | ok; returns pcall status, which the doc also allows |
| core.input.release_spirit / resurrect_corpse | yes core.lua:3382/3388 | death.lua:410,462 | ok |
| core.input.move_forward_stop | yes core.lua:3156 | main.lua:963 | ok |
| core.input.move_backward_start / _stop | yes core.lua:3162/3168 | locks.lua:82,95,125; main.lua:964 | paired: stop on time, rest, halt, module load, unload |
| core.input.jump | yes core.lua:3611 ("JumpOrAscendStart ... Pair it with ascend_stop") | locks.lua:110; repath.lua:171,347 | repath does not pair it (CORE-A-5) |
| core.input.ascend_stop | yes core.lua:3620 | locks.lua:93,114 | ok |
| core.input.look_at | yes core.lua:3191 (vec3) | range.lua:68 | passes a position: ok |
| core.input.confirm_loot_slot | yes core.lua:3035 (0-based) | events.lua:86 | converts 1-based event slot: ok |
| core.input.equip_pending_item | yes core.lua:3005 | events.lua:97 | args[1] forwarded, as in the doc example: ok |
| core.input.confirm_binder | yes core.lua:3023 | events.lua:115 | see CORE-A-12 (Forever skip is stale) |
| core.input.close_loot | yes core.lua:3661 | watchdog.lua:148 | ok |
| core.game_ui.get_corpse_position | yes core.lua:1810 (vec3) | death.lua:158 | (0,0) and non-finite handled: ok |
| core.game_ui.get_resurrect_corpse_delay | yes core.lua:1804 | death.lua:451 | ok |
| core.game_ui.get_pending_equip_slot | yes core.lua:1435 | comment only (events.lua:29) | - |
| core.game_ui.world_pos_to_map_pos_normalized | yes core.lua:1798 | terrain.lua:303-308 (via alias `gui`) | ok |
| core.quests.is_gossip_frame_shown / close_gossip / close_quest / get_num_trainer_services | yes core.lua:6206/6202/5990/6210 | main.lua:466; watchdog.lua:84,96,146,147 | ok |
| core.object_manager.get_local_player | yes core.lua:3772 | probe.lua:281 | not pcall'd, returns early on nil: ok |
| core.graphics.trace_line | yes core.lua:4678 (true = clear) | probe.lua:188; util.lua:179,208 | polarity correct; native rays are off (K.NATIVE_RAYS=false) |
| core.graphics.native_intersect | yes core.lua:4957 (end, start, dist, mask) -> hit, pos, dist | probe.lua:217 | argument order and returns correct; off |
| core.graphics.line_3d / circle_3d | yes core.lua:4777/4852 | path_runner.lua:782,800,807,811,819 | vec3 inputs (wp_at builds vec3): ok |
| core.graphics.load_texture | yes core.lua:5385 (id[, w, h]; w/h only when newly queued) | ui.lua:666,711 | w/h fallback handled: ok |
| core.graphics.draw_texture / draw_texture_rect | yes core.lua:5410/5029 | ui.lua:685,687,758,763 | argument order ok |
| core.graphics.load_font | yes core.lua:4965 | ui.lua:428 | ok |
| core.menu.window / checkbox / slider_int / slider_float / combobox / keybind / button / text_input | yes core.lua:5202/5102/5124/5134/5142/5167/5174/5196 | ui.lua:516,524,807-848,968 | parameter order matches |

### game_object methods (native = game_object.lua; izi = common/izi_sdk.lua extension)

| method | declared? | used in | notes |
|---|---|---|---|
| is_valid, get_guid, get_position, get_name, get_npc_id, get_level, is_dead, is_ghost, is_player, is_in_combat, is_moving, is_flying, is_indoors, get_rotation, get_direction, get_movement_direction, get_movement_speed, get_height, get_target, is_casting_spell | native game_object.lua:105-344 | many | ok |
| is_dead_or_ghost, is_channeling_or_casting, is_casting, is_channeling, npc_id, get_health_percentage, is_dummy, is_valid_enemy, is_in_range, distance_to, los_to, predict_position, is_behind_unit, get_enemies_in_range, get_enemies_in_melee_range | izi izi_sdk.lua:72-321 | main.lua, death.lua, combat.lua, range.lua, geometry.lua, locks.lua | ok |
| **get_health_percent** | **NO** | movement/combat.lua:180 | CORE-A-1 |
| **health_pct** | **NO** | movement/combat.lua:181 | CORE-A-1 |

### izi.*

| symbol | declared (izi_sdk.lua) | used in | notes |
|---|---|---|---|
| izi.now | 607 | everywhere (92) | ok |
| izi.me | 584 (game_object or nil) | 16 sites | nil-guarded or pcall'd |
| izi.on_update | 558 ("call once from your on_update") | main.lua:506 | ok |
| izi.on_combat_start / on_combat_finish / on_spell_success / on_spell_cancel | 563/564/569/570 (return unsubscribe) | callbacks.lua:129,131 (once per session); movement/fsm.lua:443,448,454 (every load) | CORE-A-7 |
| izi.after | 595 | locks.lua:157,167 | ok |
| izi.spell / izi.item | 578 / 613 | path_runner.lua:48; watchdog.lua:201 | ok |
| izi_spell:is_learned / cast_safe(target, message) | 353 / 426 | path_runner.lua:347,357 | ok |
| izi_item:in_inventory / cooldown_up / cooldown_remains / use_self / use_self_safe | 624-633 | watchdog.lua:205-218 | ok |
| izi.get_terrain_height(x, y, extra) | 1282 | terrain.lua:200; util.lua:158 | ok |
| izi.print | 552 | state.lua:88 | ok |
| izi.load_local_data | 1355 | ui.lua:395 | ok |

### common/* helpers

| symbol | declared | used in | notes |
|---|---|---|---|
| vector_3 `vec3.new`, `:dist_to`, `:dist_to_ignore_z`, `:squared_dist_to`, `:get_extended`, `:get_angle` | geometry/vector_3.lua:14-66 | many | ok |
| vector_2 `vec2.new` | geometry/vector_2.lua:14 | ui.lua (108) | ok |
| color.new / color.white | color.lua:10/30 | ui.lua; path_runner.lua | ok |
| enums.collision_flags (Collision, LineOfSight, DoodadCollision, WmoCollision, EntityCollision) | enums.lua:102-118 | const.lua:173-182; probe.lua:89 | ok (all below 0x200000) |
| enums.window_enums (window_resizing_flags.RESIZE_HEIGHT / NO_RESIZE, window_cross_visuals.BLUE_THEME, font_id.*) | enums.lua:196-241 | ui.lua:46-105,2278-2464 | ok |
| movement_handler: pause_movement, pause_movement_light, resume_movement, look_at_position(lock, delay, pos), unlock_look_at, on_render | utility/movement_handler.lua:13-19 | locks.lua; range.lua:67; fsm.lua:416 | `:` calls via pcall(fn, handler, ...); positions only: ok |
| simple_movement: move_to_position, navigate, stop, clear_navigation, pause, resume, process, is_moving, strafe(nil), get_state, set_* | utility/simple_movement.lua:18-121 | movement/walker.lua:51-228 | ok |
| unit_helper:get_enemy_list_around(point, range, incl_out_combat, incl_blacklist, players_only, include_dead) | utility/unit_helper.lua:75 | death.lua:214 | ok |
| assets_helper:register_zip_pack / load_local_data | utility/assets_helper.lua:62/66 | ui.lua:41,389 | ok |
| coords_helper:get_terrain_height / map_to_world / get_current_map_id / is_valid_map_coords | utility/coords_helper.lua:16-21 | terrain.lua:158,305,316,319 | ok |
| ts_override_helper:create_session, session:set_pull_allowed / tick / destroy | utility/ts_override_helper.lua:139-161 | deathzones.lua:326-347 | TTL misuse (CORE-A-3) |
| menu window methods (begin, begin_popup, render_*, push_clip_rect, set_focus, get_close_cross_bounds, ...) | menu.lua:192-422 | ui.lua | all declared; keybind `set` see CORE-A-13 |

Summary: about 70 distinct core symbols, about 45 game_object/izi unit methods, 14 izi functions and 9 helper modules are used. Three are undeclared: `core.reload_game_ui` (intentional), `game_object:get_health_percent` and `game_object:health_pct` (both defects, CORE-A-1). Outside the stub contract and so unverified: the AmeisenNav client (`_G.AmeisenNav.client`, movement/sentinel*.lua) and `os.time`.

---------------------------------------------------------------------------------------------------

## (b) Findings

### CORE-A-1 | Medium | Confidence: High | CONFIRMED DEFECT
**File:** movement/combat.lua:180-182
```lua
local hp = pct_of(safe(function() return player:get_health_percent() end))
    or pct_of(safe(function() return player:health_pct() end))
if hp and hp < RETREAT_MIN_HP then return false, string.format("health %d%%", hp) end
```
- **Actual vs expected:** neither method exists. Both calls raise "attempt to call a nil value", `safe` turns that into nil, so `hp` is always nil. The RETREAT GUARD "not below RETREAT_MIN_HP (40) % health - fight back instead" therefore never applies.
- **Evidence:** game_object.lua only has `get_health` (:262) and `get_max_health` (:270). izi_sdk.lua:72 declares `---@field get_health_percentage fun(self: game_object): number -- 1..100`. Neither stub has `get_health_percent` or `health_pct`.
- **Runtime scenario:** a ranged class whose profile asks for a retreat (`should_retreat`) at 15% HP with a mob in melee keeps backing off. It takes free hits instead of fighting back, which is exactly what the guard was written to stop.
- **Fix:** `player:get_health_percentage()` (already used in main.lua:861). Do NOT pass it through `pct_of`: `pct_of` rescales 0..1.5 to x100, so a real 1% reading would become 100%. Either compare the raw 1..100 value, or compute `get_health()/get_max_health()*100`.
- **Callers affected:** `retreat_allowed`, then `want_retreat`, then combat movement for every class with a `should_retreat` profile (rotations/*).
- **Regression risk:** Low. It only switches on a guard that was meant to be on, so retreats now stop below 40% HP.

### CORE-A-2 | Medium | Confidence: Medium-High | CONFIRMED DEFECT (sentinel ignored)
**File:** movement/util.lua:145-166 (`U.ground_z`, exported as `movement.ground_z`)
```lua
local ok, hz = pcall(core.get_height_for_position, q)
if not ok or type(hz) ~= "number" or hz ~= hz then   -- izi fallback only on error / NaN
...
if ok and type(hz) == "number" and hz == hz and abs(hint_z - hz) < 80 then
    return hz
```
- **Actual vs expected:** a miss answers 0. That 0 is accepted as a height whenever |hint_z| < 80, and the izi fallback is skipped because 0 is a number.
- **Evidence:** core.lua:488 doc: "A miss answers 0, which you cannot tell from a real height of 0" and "The ray starts 2 yards above pos.z. It cannot hit a surface it starts BELOW". movement/terrain.lua:186 already treats `h == 0` as no answer (`if not ok or not finite(h) or h == 0 then return nil end`); util.lua does not.
- **Runtime scenario:** in any zone with ground between about z = -80 and +80 (most open-world terrain), ask for a point uphill (hint_z interpolated more than 2 yd below the slope) or a point over a hole or unloaded cell. ground_z returns z = 0 and the walker or a combat hop gets a destination tens of yards underground. Examples: geom.lua:32-62 hop points, combat.lua:412/623/692/716 stand-off points, nav.lua:170/298 path points, death.lua:248 corpse retreat spot. The 3D arrival checks then never complete, so the character stalls until the stuck ladder fires.
- **Fix:** treat `hz == 0` as a miss unless |hint_z| is small (as terrain.lua and izi_height do: `h == 0 and abs(hz) > 5`). Then fall through to the izi fallback. Optionally pass `{ probe_up = N }` (core.lua:466-478) instead of relying on the 2 yd default.
- **Callers affected:** movement/geom.lua, movement/combat.lua, movement/nav.lua, movement/probe.lua:442, death.lua:248.
- **Regression risk:** Low-Medium. Points near real z = 0 (coastlines) still need the small-|hint_z| exception.

### CORE-A-3 | Medium | Confidence: High | CONFIRMED DEFECT
**File:** deathzones.lua:326-337 (`ts_hold`) with 350-353 (`M.tick` self-throttled to `TICK_GAP = 1.0` s)
```lua
if ts_session then pcall(ts_session.tick, ts_session) return end
... sess = ts:create_session(...) ; pcall(sess.set_pull_allowed, sess, false)
```
- **Actual vs expected:** the session is refreshed once a second and its value is set only once, at creation.
- **Evidence:** common/utility/ts_override_helper.lua:12-13: "When your plugin stops calling ... overrides expire within 500ms". Line 24: "Set overrides each frame. Each call refreshes the 500ms TTL." Line 144: `tick` is "Refresh session TTL".
- **Runtime scenario:** near an active death zone, every 1 s refresh leaves at least 500 ms in which the override has expired. The Target Selector then uses the player's own pull setting and auto-pulls the mob that killed the character three times. If the core drops an expired session (`is_active` false, :146), `tick()` may never revive it and the "no pulls" override is gone for good. Meanwhile `ts_session` stays non-nil, so `set_pull_allowed(false)` is never sent again.
- **Fix:** while near a zone, call `sess:set_pull_allowed(false)` (or at least `sess:tick()`) every frame or every bot tick (0.1 s), outside the 1 s throttle. Re-create the session when `sess:is_active()` is false.
- **Callers affected:** deathzones.tick (main.lua:620-623); grind / quest pulls through the Target Selector.
- **Regression risk:** Low.

### CORE-A-4 | Medium | Confidence: Medium-High | PROBABLE (map id semantics)
**File:** movement/sentinel_adv.lua:47-79 (`read_map` / `map_tick`). The same id keys movement/hazards.lua:81-89 and deathzones.lua:85-88.
```lua
local ok, id = pcall(function() return core.get_map_id() end)
... if id ~= map.id (confirmed twice) then Z.clear_all(); N.reset_caches(); O.halt_all() (out of combat)
```
- **Actual vs expected:** the code treats `get_map_id` as the continent (header comment: "a zone from the last continent would block the same coordinates on the new one"). The repo itself records that `get_map_id` is the UI map / zone: gamever.lua:88 says "core.get_map_id() answers the zone's UiMapID (1426 Dun Morogh)", and ameisen/AmeisenNav/anav/context.lua:8-10 says "core.get_map_id() is the UI map on WoW Forever (1429 = Elwynn Forest)" and uses `core.get_instance_id()` for the continent.
- **Evidence:** core.lua:366-368 `get_map_id`: "id of the current localplayer map" (unspecific). core.lua:372-376 `get_instance_id`: "the instance MAP id ... also in the open world, where it is the continent ... Not a UI map id".
- **Runtime scenario:** walking from Elwynn Forest into Westfall (same continent) changes the id, so about 4 s later every blacklist zone is cleared. That includes learned stuck areas and death-zone avoidance areas. The Ameisen caches reset and the travel leg halts. Compounding effect: deathzones keeps `z.pushed = true` (deathzones.lua:166, 351-352), so its zones are never pushed back to `movement/zones` after `Z.clear_all`. Navigation stops avoiding death zones for the rest of their duration. Hazard files are also split per zone, so a hazard at a zone border is not loaded on the other side.
- **Fix:** sample `core.get_instance_id()` (core.lua:376) for the continent-change reset. Keep `get_map_id` only where a zone id is wanted. In deathzones, re-push zones after a clear (for example clear `pushed` when `movement/zones` reports a clear, or re-push on a zone-count mismatch). Verify in game: log both ids once.
- **Callers affected:** fsm.pulse to Adv.tick; movement/zones; deathzones; hazards persistence; path_runner.lua:299 (map warning only).
- **Regression risk:** Medium. Hazard and death-zone files keyed by the old id would no longer match. Migrate them or key them by instance id plus zone.

### CORE-A-5 | Medium | Confidence: Medium | PROBABLE (input left held)
**File:** movement/repath.lua:171 and :347
```lua
pcall(function() core.input.jump() end)   -- no matching ascend_stop anywhere in repath.lua
```
- **Actual vs expected:** `jump()` is a key-down action that needs a release. locks.lua:110-115 does this correctly (jump, then `ascend_stop` 0.15 s later).
- **Evidence:** core.lua:3605-3611: "the game's JumpOrAscendStart action, which jumps on the ground and climbs in the air ... Pair it with ascend_stop to end a climb." core.lua:3617-3620 defines `ascend_stop` as "Stops an ascent started by jump()".
- **Runtime scenario:** the stuck ladder (rung 2), or a blacklist-and-repath, fires while the character is swimming (stuck against a shore or pier). The ascend input stays held, so the character keeps swimming up and bobs at the surface. It cannot dive under the obstacle and the next path legs fight the held key. Whether a held jump also re-jumps on land depends on the client. Nothing in on_unload or halt releases it.
- **Fix:** release it the same way locks.lua does: record a release time and call `core.input.ascend_stop()` about 0.15 s later from the pulse, and in `Nv.halt` / on_unload.
- **Callers affected:** RP.area_watch, recovery_watch and the progress ladder (movement/repath.lua).
- **Regression risk:** Low.

### CORE-A-6 | Medium | Confidence: Medium | PROBABLE (stored unit used without is_valid)
**Files:**
- movement/repath.lua:112-113 `unit_xyz(R.combat_target)` (get_position on the stored unit with no `is_valid`). The same happens at :312.
- death.lua:328-332 `blacklist_killer`: `movement.combat_unit()` then `unit:get_guid()`.
- death.lua:345 passes the same stored unit to deathzones.lua:199-201 (`killer:get_npc_id()`, `killer:get_name()`).
- movement/combat.lua:224 hands `R.last_spell_target` (a unit kept from an izi event, fsm.lua:463) to class profiles without validation.
- **Actual vs expected:** AGENTS.md: "call is_valid() before any other method on a stored unit". range.lua:58-66 explains why: a freed object is "a native crash, not a Lua error", and pcall does not catch that. `R.combat_target` is held across ticks and is exactly the unit most likely freed at death (corpse despawn / release).
- **Evidence:** game_object.lua:105 `is_valid fun(self): boolean`. The rule itself is AGENTS.md "API discipline". The stub does not document what happens with a freed object, hence PROBABLE.
- **Runtime scenario:** the character dies and the killer leaves visibility or despawns before `begin_death` runs. `get_guid` / `get_npc_id` / `get_name` are then called on a freed object. The same can happen in the progress watchdog after the combat target despawns.
- **Fix:** `if U.unit_valid(u) then ... end` before any method. For the killer, prefer the stored `R.combat_guid` (set at combat.lua:467) and read npc id / name only after `is_valid()`.
- **Callers affected:** death flow, death zones, repath watchdog, class retreat profiles.
- **Regression risk:** Very low.

### CORE-A-7 | Low | Confidence: High | PROBABLE (callbacks registered more than once)
**File:** movement/fsm.lua:442-466
- **Actual vs expected:** `izi.on_combat_start`, `on_combat_finish` and `on_spell_success` are subscribed at module load. The unsubscribe functions they return are thrown away, and nothing unsubscribes in on_unload. callbacks.lua:120-143 has the correct "register once per session, keep unsub, uninstall on unload" pattern.
- **Evidence:** izi_sdk.lua:563-570: each `on_*` returns `(fun())`, the unsubscribe function.
- **Runtime scenario:** each plugin reload (launcher reload or standalone re-require) adds three more live closures. Every event then runs `izi.me()` plus two GUID reads once per accumulated copy. If the launcher re-creates `movement/rt`, old closures keep writing to stale R tables. If it does not, they write duplicates. This is a growing per-event cost and a leak.
- **Fix:** store the unsubscribes in `_G.MasterFarmer_Grindbot` and either register once per session (as callbacks.lua does) or unsubscribe in main.lua on_unload.
- **Regression risk:** Low.

### CORE-A-8 | Low | Confidence: Medium | PROBABLE (write result not verified)
**Files:** settings.lua:278-286; movement/hazards.lua:120-128; deathzones.lua:127-131; ui.lua:634-637
- **Actual vs expected:** `pcall(core.write_data_file, ...)` is treated as success, and settings.lua then sets `dirty = false`. Its comment (:274-277) says "create_data_file is a no-op when the file already exists ... write_data_file overwrites", which is the reverse of the documented behaviour. The code order (create, then write) is still right.
- **Evidence:** core.lua:710-713: write_data_file "APPENDS ... The file must already EXIST. On a missing file nothing is written and nothing is reported: no error, no return value". core.lua:661-662: create_data_file "@return boolean created".
- **Runtime scenario:** if `create_data_file` fails (path rejected, folder missing because `create_data_folder` ran only once via `folder_ready`, file locked by OneDrive sync), the save is silently lost while it is reported as saved and `dirty` is cleared. Settings are never retried that session.
- **Fix:** check `core.create_data_file(path) == true` before writing. Optionally read back `get_data_file_size(path) > 0`. Keep `dirty` set on failure. Correct the comment.
- **Regression risk:** Low.

### CORE-A-9 | Low | Confidence: High | CONFIRMED (cosmetic)
**File:** ui.lua:447-452 (`log_assets_once`)
- **Actual vs expected:** `listed` stays "-" only for a non-table. `read_dir` returns `{}` for a missing folder, so `listed = ""` and the "nothing to report" early return never fires. One misleading log line is written with an empty dir listing.
- **Evidence:** core.lua:926-929: "An EMPTY table when the folder does not exist ... Check `#files > 0`, not `files ~= nil`."
- **Fix:** `if type(listing) == "table" and #listing > 0 then listed = ... end`.
- **Regression risk:** None.

### CORE-A-10 | API Verification Required | Confidence: Low-Medium
**File:** deathzones.lua:79-83
```lua
local ok, t = pcall(os.time)
```
- **Issue:** `os.time` is evaluated before `pcall` runs. If the sandbox has no `os` global, the index raises outside the pcall. `wall()` then throws, and so do `save()` / `load()` / `record_death` (each pcall'd by its caller, so the death zone is silently not recorded or loaded).
- **Evidence:** core.lua:846: "Useful in sandboxed Lua where `os.date()` / `os.time()` are unavailable." core.lua:337-350: `core.get_server_time()` is "the one clock that agrees across sessions, reloads and machines, so use it for anything you store".
- **Fix:** `local ok, t = pcall(function() return core.get_server_time() end)`. Keep the `left` fallback when it answers 0. Confirm in game whether `os` exists.

### CORE-A-11 | INFO
main.lua:457,488 `core.reload_game_ui`: not declared in core.lua. It is intentional (AGENTS.md, 2.107.0 / 2.189.0) and guarded by `type(...) == "function"` plus `pcall`. No action.

### CORE-A-12 | Low / INFO | Confidence: Medium
events.lua:103-112: the CONFIRM_BINDER handler skips Forever because "confirm_binder always returns false and does nothing there". core.lua:3017-3020 now says it "works on every client since the 2026-10-06 core ... so it no longer always answers false on those two". This is not a call error, but the assumption is stale. It matters only if the bot ever binds at an inn (the comment says it does not).

### CORE-A-13 | INFO (latent wrong type)
ui.lua:871-883 `Menu:set(id, value)` for kind "keybind" calls `element:set(value)`. menu.lua:138 declares `keybind.set fun(self, val: integer)`, which sets the key code. `Menu:get` reads keybinds as a toggle boolean (ui.lua:862-863), so a symmetric `set(id, true)` would write a boolean into the key code. There is no keybind caller today (no `Menu:keybind` callers found). Toggles should use `set_toggle_state` (menu.lua:136).

### CORE-A-14 | INFO (unverified surfaces)
- AmeisenNav (`_G.AmeisenNav.client`, movement/sentinel.lua, sentinel_adv.lua) is not in the `.api` stubs. Its contract is ameisen/AmeisenNav/docs, which this audit did not cover.
- movement/fsm.lua:427-433 `is_me(ev)` treats `ev.unit == nil` as the player. The stub (izi_sdk.lua:563-564) types `ev.unit` as a non-optional game_object, so this is harmless unless the SDK sends nil for a freed unit.
- terrain.lua:301-319 combines `coords_helper:get_current_map_id()` (minimap map) with `core.game_ui.world_pos_to_map_pos_normalized` (map not specified in the stub, core.lua:1797-1798). Each call is declared, but whether the two refer to the same map is unverified.

### Checked and found correct (no finding)
- confirm_loot_slot 0-based conversion.
- trace_line polarity and native_intersect argument order.
- load_texture's optional w/h.
- draw_texture / draw_texture_rect argument order.
- http_get / http_post overloads.
- Backpedal key pairing: move_backward_start/stop on time, rest, halt, module load and unload; jump paired with ascend_stop.
- Movement handler is given positions only.
- Game objects compared by GUID everywhere (no `==` on units found).
- events / callbacks registered once per session.
- get_corpse_position (0,0) and non-finite handling.
- read_data_file / get_data_file_size nil/0 handling.
- create-then-write replace pattern.
- simple_movement and unit_helper signatures.
- ts_override_helper and coords_helper `:` calls.
