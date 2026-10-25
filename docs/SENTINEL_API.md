# Sentinel Navigation - consumer API (official doc v0.0.8) vs the installed v0.24

Source 1 for every Sentinel call in this product. The user supplied the official Project
Sylvanas documentation page on 2026-10-24 ("Sentinel Navigation API", reflects v0.0.8,
July 2026). The library installed in game prints **v0.24** (`[SentinelNavClient] v0.24 Loaded`).
What the in-game self-test recorded on v0.24 is in `docs/SENTINEL_V024.md`; the column
"recorded on v0.24" below points at it. A call that is in neither is not used.

## Global

`_G.SentinelNavClient` - `client` (live getter for the shared client, may be nil),
`create(config?)` (returns the shared client; config ignored), `ui`, `JSON`, `Helpers`,
`VERSION` (string).

Consumer rules (doc): never call `client:update()`; never own navigation tuning (the
Sentinel UI owns config); check `client:is_server_available()` before navigating.
Positions: `vec3` or `{ x, y, z }` in; positions out are `vec3`.

## Movement

| Call | Doc | Recorded on v0.24 |
|---|---|---|
| `move_to(target, cb?, opts?)` | `cb(success, reason?)`; defers while casting (`navigating.deferred`), else `navigating.awaiting_path`. Off-mesh targets snap to the nearest reachable point (v0.0.8, setting "Snap Off-Mesh Targets", on by default); a genuinely unreachable area fails with `unreachable` | returns nil; arrival `cb(true, nil, { code = "arrived", destination })` (3rd arg extra); a 2nd `move_to` while walking re-plans in 0.12 s without stopping and the **replaced walk's cb never fires**; off-mesh: 3 HTTP 422 tries (~6 s) then snap |
| `move_direct(target, cb?)` | single waypoint, no pathfinding; `cb(success, reason?)` | not run |
| `follow_path(waypoints, cb?)` | precomputed waypoints in order; `cb(success, reason?)` | not run |
| `plan_route(nodes, cb?, opts?)` | TSP plan only; `cb(success, data)`, data = `{ waypoints, visit_order, leg_boundaries, leg_distances, total_distance }` or nil / `{ error }`; opts e.g. `{ return_to_start = false }` | not run |
| `start_route(nodes, cb?, opts?)` | plan + follow; `cb(success, reason?)` | not run |
| `validate_destination(target, cb)` | `cb(reachable, reason?, distance?)` | `(true, nil, 8.15)` |
| `replan(reason?)` | clears path state, back to `awaiting_path` | not run |
| `stop()` | stops all movement, resets navigation state | returns nil, state `idle`, the **stopped walk's cb never fires** |

## State

`get_state()` -> `idle | navigating | arrived | failed`; `get_full_state()` -> dotted
(`navigating.awaiting_path | following_path | recovering(.jumping|.probing|.strafing|.backtracking) | repathing | deferred`);
`is_moving()` (true only while `navigating`); `get_destination()` -> vec3|nil;
`get_current_path()` -> vec3[]|nil; `get_path_index()` -> number;
`get_progress()` -> `{ percent 0..1, waypoints_remaining, total_waypoints, current_index }`;
`get_corridor_widths()` -> number[]|nil.

Failure reasons (doc): `unreachable`, `server_timeout`, `max_stuck_exceeded`, `max_repath_exceeded`.

## Server queries

| Call | Doc | Recorded on v0.24 |
|---|---|---|
| `is_server_available()` | boolean (connection flag) | true |
| `health_check(cb)` | `cb(ok)` | `(true, { status, loaded_maps, uptime_secs, version }, nil)` |
| `get_height(pos, cb)` | navmesh height | `(true, { height = N }, nil)` - a table |
| `get_player_height(cb)` | navmesh height at the player | `(true, { height = N }, nil)` |
| `get_all_heights(pos, cb, opts?)` | multi-layer heights | `(true, { count, heights = { { height, flags }, ... } }, nil)` |
| `get_player_all_heights(cb, opts?)` | multi-layer at the player | not run |

## Events

Legacy `client:on/off`: `state_change {from, to}`, `arrived`, `stuck` (from
`navigating.recovering`), `failed`.

EventBus `client:get_event_bus()`: `on(event, cb, opts?)`, `once`, `on_pattern(pattern, cb, opts?)`,
`off(id)`, `off_owner(owner)`, `pause()`, `resume()`; handler `cb(data, event_name)`; opts
`{ owner, priority }`. Events: `nav.state_changed`, `nav.arrived`, `nav.failed`,
`nav.stuck_detected`, `nav.stuck_recovered`, `nav.deviation_detected`, `nav.repath_started`,
`nav.repath_completed`, `nav.obstacle_detected`, `nav.path_requested`, `nav.path_received`,
`nav.path_failed`, `nav.waypoint_reached`, `nav.server_connected`, `nav.server_retry`,
`nav.server_disconnected`, `nav.server_error`. Payloads recorded on v0.24: see SENTINEL_V024.md
(v0.24 also emits `nav.http_sent`, `nav.leg_completed`).

## Advanced ("use with care", may change - only through movement/sentinel.lua)

- `client.nav_client`: `find_path(start, dest, cb, opts?)`, `find_route_tsp`, `find_route_multi`,
  `check_path(pos, waypoints, cb, opts?)`, `find_path_corridor`, `find_path_avoid(start, dest, zones, cb, opts?)`,
  `raycast`, `get_height`, `get_all_heights`, `random_point(cb, opts?)`, `flee(player_pos, threats, cb, opts?)`,
  `kite(player_pos, target_pos, cb, opts?)`, `health_check`, `is_available()`,
  static `is_indoor()`, `get_continent_id()`. Recorded: `find_path` ->
  `(true, { waypoints, distance, partial, computation_time_ms }, nil)`.
- `client.movement`: `navigate`, `process`, `stop`, `get_current_index`, `get_remaining_waypoints`,
  `is_moving`, `strafe`, `apply_dynamic_speed` - not driven by this product.
- `client.obstacle`: `probe_forward`, `probe_segment`, `probe_path_ahead`, `add_zone`,
  `remove_zone`, `get_avoidance_zones`, `get_zone_count`, `clear`.
