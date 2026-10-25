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

### Not yet verified (run 2 needed)

- a second `move_to` while a walk follows its path (what happens to the first callback);
- `stop()` during a walk (callback arguments, state after);
- the failure callback (`detail.code` for an unreachable target);
- `move_direct`, `follow_path`, `replan`, `get_progress`.

## Product bug found by run 1

`MASTER_FARMER` lives in the product's environment (`mfcore/loader.lua` `env.MASTER_FARMER`),
not in the real `_G`: `rawget(_G, "MASTER_FARMER")` returned nil, so the self-test saw
`MASTER_FARMER.nav = { kind = "none" }` and wrote to the fallback folder
`scripts_data/restedxp_questing/`. Fixed in 4.1.3 (`S.master_farmer()`).
