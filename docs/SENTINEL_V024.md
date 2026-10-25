# Sentinel Navigation v0.24 - what the library really answers

The installed library (`scripts\ext_lib_sentinel_nav`) is an encrypted package, so
its behaviour is recorded in game by the Settings-tab **Sentinel Self-Test**
(`movement/sentinel.lua`). Every entry below comes from a self-test results file;
anything not listed here is **not verified** on v0.24 and must not be relied on.

## Run 1 - 2026-10-24 19:34 (restedXP_questing 4.1.2, TBC, Eastern Plaguelands)

Server: the Master Farmer SentinelNavServer (`game=tbc`), set by launcher 2.15.0.

### Functions on `_G.SentinelNavClient.client`

- Present: `move_to move_direct follow_path plan_route start_route validate_destination
  replan stop get_state get_full_state is_moving get_destination get_current_path
  get_path_index get_progress get_corridor_widths is_server_available health_check
  get_height get_player_height get_all_heights get_player_all_heights on off
  get_event_bus update_config`
- **Missing:** `pause resume is_busy get_last_failure`
- `client.nav_client` (advanced): `find_path find_route_multi find_route_tsp check_path
  find_path_avoid raycast get_height get_all_heights random_point flee kite
  is_available` - all present.

### Callbacks (argument lists exactly as received)

| Call | Callback arguments |
|---|---|
| `health_check(cb)` | `(true, { status = "ok", loaded_maps = { tbc, forever }, uptime_secs, version }, nil)` |
| `get_player_height(cb)` | `(true, { height = 97.36 }, nil)` - **a table, not a number** |
| `get_height(pos, cb)` | `(true, { height = 97.36 }, nil)` |
| `get_all_heights(pos, cb)` | `(true, { count = 1, heights = { { height, flags }, ... } }, nil)` |
| `validate_destination(pos, cb)` | `(true, nil, 8.15)` = `(reachable, reason, distance)` |
| `nav_client:find_path(a, b, cb)` | `(true, { waypoints = { vec3, ... }, distance, partial = false, computation_time_ms }, nil)` |
| `move_to(pos, cb)` | returns `nil`; on arrival `cb(true, nil, { code = "arrived", destination })` |

### Events (`client:get_event_bus():on(name, fn, { owner })`, handler `fn(data, name)`)

- `nav.state_changed` `{ from, to, substate_from?, substate_to? }`
  (e.g. `idle -> navigating/awaiting_path`, `navigating/awaiting_path -> navigating/following_path`,
  `navigating/following_path -> arrived`)
- `nav.path_requested` `{ request_id, start, destination }`
- `nav.path_received` `{ distance, partial, waypoint_count }`
- `nav.waypoint_reached` `{ index, position, total }`
- `nav.arrived` `{ destination }`
- The bus also carries undocumented `nav.http_sent` and `nav.leg_completed`.
- `bus:off_owner(owner)` works.

### Timing

- Path request -> path received: 0.14 s (Hetzner, Germany).
- An 8 yd walk: following its path 0.14 s after `move_to`, arrived 0.73 s after.

## Run 2 - 2026-10-24 19:37 (restedXP_questing 4.1.3, TBC, Eastern Plaguelands)

`MASTER_FARMER.nav` = `{ kind = "sentinel", game = "tbc", base_url = "http://5.161.160.108:47110", supported = true }`
(the 4.1.3 lookup fix works). Callback shapes, heights and events as in run 1.

### A second `move_to` while walking (A 30 yd ahead, B sent 1.6 s later)

- The library re-plans without stopping: `following_path -> awaiting_path -> following_path`
  in 0.12 s (`nav.path_requested` request_id 2, `nav.path_received`), the character keeps walking.
- **The replaced walk's callback NEVER fires** (A: 0 calls). Only B's fires, on arrival:
  `(true, nil, { code = "arrived", destination })`.

### `stop()` while walking (C 30 yd back, stopped 1.6 s in, following its path)

- `stop()` returns `nil`; state goes straight to `idle` (`nav.state_changed {from = navigating, to = idle}`).
- **The stopped walk's callback NEVER fires** (C: 0 calls).

### An off-mesh target (U: 30 yd away, 150 yd up)

- Server `HTTP 422: Position not on navmesh`; the library retries itself:
  `nav.server_retry { attempt, code = 422, delay_secs = 2 then 4, max_retries = 3, next_attempt, url }`,
  then `nav.server_error { code = 422, error = "HTTP 422: Position not on navmesh", failures, url }` -
  about **6 s** after the request.
- Then it **auto-snaps** the target and walks: `nav.path_received { distance = 41.97, partial = false,
  snapped = true, waypoint_count = 45 }`, `following_path`.
- No `nav.failed`, no `nav.path_failed`, no failure callback (the walk was then stopped by the test).
- Path URL seen: `/api/v1/path?allow_partial=true&optimize=true&end_z=...` on the Master Farmer server.

### Still not verified

- the failure callback / `nav.failed` payload (a target with no path at all - snapping hides the
  off-mesh case);
- `move_direct`, `follow_path`, `replan`, `get_progress`, `start_route`.

## What this means for the port

- A replaced or stopped walk gives **no** callback: the product must track its own walks
  (one token per walk; a new walk or a stop retires the old token) and never wait on a callback
  that a newer walk or `stop()` has cancelled.
- No `pause` / `resume`: a hold is `stop()` + re-issue the same destination after it.
- Retargeting is cheap (0.12 s) and does not stop the character: a second `move_to` is the
  retarget (no prefetch / `follow_path` dance needed).
- An off-mesh destination costs about 6 s of library retries before the snap: the product should
  give Sentinel a height it has checked (`get_all_heights` floors) rather than a guess.
- Failures must be read from `get_state()` / `nav.server_error` and the product's own stall timer,
  not from a failure callback whose shape is unknown.

## Product bug found by run 1

`MASTER_FARMER` lives in the product's environment (`mfcore/loader.lua` `env.MASTER_FARMER`),
not in the real `_G`: `rawget(_G, "MASTER_FARMER")` returned nil, so the self-test saw
`MASTER_FARMER.nav = { kind = "none" }` and wrote to the fallback folder
`scripts_data/restedxp_questing/`. Fixed in 4.1.3 (`S.master_farmer()`).
