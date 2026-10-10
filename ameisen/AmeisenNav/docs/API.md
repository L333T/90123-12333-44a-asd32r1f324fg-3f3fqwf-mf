# AmeisenNav API (v1.6.0)

Shared navmesh navigation for Sylvanas plugins, backed by the local
AmeisenNavigation server. Replaces SentinelNavClient.

Game versions: loads on every client. `_G.AmeisenNav.GAME_VERSION` is the
client actually running. Runtime quirks (no `get_local_player`,
`simple_movement` refusing a path, `look_at` not turning, `race_id` 0) are
probed at runtime.

The nav server must have the mmaps for the map you walk on. Maps load on the
first query against `Ameisen\AmeisenNavigationServer.exe`.

## Setup

1. Start the server: `Ameisen\Start-Ameisen.bat` (leave the window open).
   It listens on `http://127.0.0.1:47110` and forwards to TCP `127.0.0.1:47111`.
2. Copy the `AmeisenNav` folder into the Sylvanas `scripts` folder and reload.
3. Open the menu page **AmeisenNav**: it should say *Server: connected*.
   *Test: walk to my target* walks to your current target.

## Using it from another plugin

Look the client up when you need it, not in `header.lua`: plugin load order is
not guaranteed.

```lua
local function nav()
    local g = rawget(_G, "AmeisenNav")
    return g and g.client or nil
end

local c = nav()
if c then
    c:move_to({ x = -9464, y = 62, z = 56 }, function(ok, reason, detail)
        if ok then core.log("arrived")
        else core.log("navigation failed: " .. detail.code .. " - " .. tostring(detail.detail)) end
    end)
end
```

**While AmeisenNav is moving (`c:is_busy()`), do not drive `simple_movement`
yourself and do not call `walker:process()`.** AmeisenNav owns the walker until
the navigation ends (arrived, failed or `stop()`).

## Movement

| Call | What it does |
|---|---|
| `c:move_to(target, cb, opts)` | Pathfind from the player to `target` and walk it. `opts.allow_partial` walks a path that stops short; `opts.flags` sets server smoothing flags. |
| `c:move_direct(target, cb)` | Walk a straight line (no pathfinding), with stuck recovery. |
| `c:follow_path(waypoints, cb)` | Walk a recorded route. Recovery rejoins the route at the waypoint being approached. |
| `c:replan(reason)` | Rebuild the active path from the current position. |
| `c:stop()` | Stop. The active callback gets `code = "cancelled"`. |
| `c:pause(reason)` / `c:resume(reason)` | Hold the walk (e.g. looting) without losing it. Reasons are counted separately. |

Starting a new navigation cancels the old one (its callback gets `cancelled`).

### Callback

`cb(success, reason, detail)` is called exactly once. `detail.code` is one of:

| code | meaning |
|---|---|
| `arrived` | success |
| `cancelled` | `stop()` or replaced by a new navigation |
| `unreachable` | only a partial path exists and it stops more than 5 yd from the target |
| `start_off_mesh` / `end_off_mesh` | the player / target is not on the navmesh |
| `no_path` | no connection between start and target |
| `map_not_loaded` | no mesh for this map |
| `server_timeout` / `server_down` | the server did not answer / is not running |
| `max_stuck_exceeded` | stuck recovery gave up |
| `max_repath_exceeded` | more than 10 repaths in one navigation |
| `bad_request` | invalid input from the caller |

### Stuck recovery

No progress for *Stuck after* seconds (menu, default 1.5) raises the stuck
level; real progress (3 yd) resets it.

1. jump, 2. repath, 3. detour to a random mesh point within 5 yd,
4. back off 0.6 s then repath, 5. jump + repath, 6. fail `max_stuck_exceeded`.

Being pushed more than 8 yd off the path repaths immediately. Walking pauses
while casting or channelling (menu option), and that never counts as stuck.

## Path check (1.5.0)

`anav/pathcheck.lua`, on by default (`pathcheck = true`).

- **5-yard waypoints.** Every walked path is resampled so no two waypoints are
  more than `waypoint_spacing` (5) yards apart. `get_current_path()` and
  `get_path_index()` report the walked (resampled) points.
- **Checked 15 yards ahead.** The next `check_ahead` (3) waypoints are checked
  once each, as they come into that window, and corrected before the character
  gets there. One small request in flight, the next waypoint no sooner than
  `check_gap` (0.25 s): about 3 requests a second while running, none while
  standing. Never per frame. No game (native) calls: server requests only.
- **Height.** A short server path from the previous waypoint is asked at four
  heights in one batch (the line's, the last ground height, +/- 6 yd); the one
  that lands on the waypoint gives the ground height, and the waypoint takes it.
- **Too steep / cliff.** A climb over `max_climb` (1.0 yd per yd), a drop over
  `max_drop` (1.5 yd per yd) or deeper than `cliff_drop` (6 yd), or a leg that
  leaves the walkable mesh: that leg is re-planned unsmoothed (`splice_flags`
  16) between the waypoints around it and spliced in (`max_splices` 4 per path).
- **Width.** Side probes 1.5 and 3 yd left and right of the waypoint (from the
  ground height). A wall / edge on one side moves the waypoint
  `edge_clearance` (1.5) yd away from it, so the character keeps 1-2 yd; both
  sides closed at 1.5 yd (a corridor under 3 yd) centres it. The destination
  itself is never moved.
- **No Chaikin smoothing** while it runs (`pathcheck_unsmoothed`): flag 1 is
  dropped from walked paths - measured on the server, smoothing left the
  walkable mesh twice on a 540 yd route. VALIDATE_MAS (16) is kept.
- **No corner skipping** (input driver) while it runs: skipping ahead would
  bypass the checked waypoints, and its `/raycast` kills the 1.8.3.2 server.

`client:update_config({ pathcheck = false })` turns all of it off (1.4.0
behaviour). Stats: `require("anav/pathcheck").stats`.

## Rolling horizon (1.6.0)

`c:move_to` no longer walks one long server path. Every walk is a chain of
**windows**:

1. The server is asked for an **unsmoothed** path from the player's current
   position and height to the destination.
2. Its first `horizon_length` (20) yards become waypoints `waypoint_spacing`
   (5) yards apart, starting at the player.
3. The window is checked **before** a step is taken (nav server only, two
   batched requests - no native traces):
   - **ground**: each leg is probed at four heights; the waypoint takes the real
     ground height. A leg that leaves walkable ground, climbs steeper than
     `max_climb`, or drops steeper than `max_drop` / deeper than `cliff_drop`
     is re-planned unsmoothed between its neighbours and spliced in
     (`horizon_splices` per window).
   - **width**: probes `horizon_probes` (1, 2, 3) yards left and right measure
     the free room; every waypoint is moved to keep `horizon_clearance` (2)
     yards from walls, ledges and drops. A corridor narrower than twice that
     is walked down its middle.
   - **objects**: nearby objects (radius + `body_radius` +
     `horizon_object_clearance`) push the waypoint aside, never past the
     measured free room.
4. When the player is within `horizon_refresh` (5) yards of the window end,
   the next window is planned from the player's position and swapped in
   **without releasing a key**. This repeats until the destination is in the
   window. The destination itself is never moved.

`opts.horizon = false` (or `horizon = false` in the config) walks the whole
server path the old way (with the 1.5.0 path check). `c:follow_path`
(recorded routes) keeps the 1.5.0 path check.

## Handoff (1.6.0)

| Call | Does |
|---|---|
| `c:handoff("simple", { position = p })` | Lets go of the walk **without releasing a key**. The walker gets its own thresholds back and, with `position`, is pointed at it (`simple_movement:move_to_position`); your code drives simple_movement from there. |
| `c:handoff("combat", { target = u, face = s, pause = s })` | Stops the walk; the movement handler faces `u` for `face` seconds (`handoff_face`, 1) and, with `pause`, holds still that long (`pause_movement_light`, for a cast). Your combat movement takes over. |
| `c:move_to(p, cb, { handoff = { at = 5 } })` | Automatic handoff: once the player is `at` yards from the destination, the callback gets `(true, "arrived", { code = "arrived", detail = "handoff:simple" })` and simple_movement walks the last yards to `p` with no stop in between. |

The callback of a navigation handed off by `c:handoff` receives
`(false, "handoff:<to>", { code = "cancelled", detail = "handoff:<to>" })`, the
same code as `c:stop()`. The movement handler's `on_render` is called by
AmeisenNav while its handoff lock lasts.

## Following a moving unit

```lua
local g = rawget(_G, "AmeisenNav")
g.follow.start("target")          -- or "focus", or "name" with g.follow.start("name", "Brandon")
g.follow.toggle_pause(g.client)   -- pause / resume
g.follow.stop(g.client)           -- or the menu button "Stop following"
```

Re-paths every 0.2 s within 30 yd (1 s beyond), only when the unit has moved
2 yd from the last goal, and stands still within 3 yd. Re-paths are
*seamless*: the running walk takes the new path without releasing any key.
`c:move_to(pos, cb, { seamless = true })` does the same for your own
continuous re-pathing. Focus may be unavailable on WoW Forever
(`get_focus()` is nil on private-server clients; the "focus" token is tried).

## Queries (no movement)

| Call | Callback |
|---|---|
| `c:find_path(from, to, cb, opts)` | `cb(ok, points, info)` |
| `c:validate_destination(target, cb)` | `cb(reachable, code, path_length)` |
| `c:get_height(pos, cb)` / `c:get_player_height(cb)` | `cb(ok, z)` |
| `c:raycast(from, to, cb)` | `cb(ok, clear, hit_point)` |
| `c:random_point(center, radius, cb)` | `cb(ok, point)` |
| `c:kite(player_pos, target_pos, cb)` | `cb(point or nil)`: a mesh point about 12 yd away from the target |
| `c:flee(player_pos, threats, cb)` | `cb(point or nil)`: away from the threats' centre |
| `c:plan_route(nodes, cb)` | `cb(ok, { waypoints, visit_order, total_distance })`: nearest-neighbour + 2-opt from the player |
| `_G.AmeisenNav.query.find_paths(pairs, opts, cb)` | batch: `pairs = { {from, to}, ... }`, `cb(ok, results)` with `results[i] = { ok, points, info }` |

All positions are `{ x, y, z }` tables or `vec3`. Queries are cached for 10 s
on a 4-yard grid, and identical in-flight path requests are merged.

## Status

`get_state()` (`idle`, `planning`, `navigating`, `arrived`, `failed`),
`get_full_state()` (e.g. `navigating.recovering.detour`), `is_moving()`,
`is_busy()`, `get_destination()`, `get_current_path()`, `get_path_index()`,
`get_progress()` (`percent`, `waypoints_remaining`, `total_waypoints`,
`current_index`), `get_last_failure()`, `is_server_available()`,
`health_check(cb)`.

## Events

`local id = c:on(event, fn)` / `c:off(id)`

| event | arguments |
|---|---|
| `state_change` | new_state, old_state |
| `path` | points (each new path walked) |
| `arrived` | destination |
| `failed` | code, detail |
| `stuck` | level |
| `repath` | reason |
| `server` | up (boolean) |

## Configuration

`c:update_config({ key = value })` changes any key in `anav/config.lua`
(`base_url`, `token`, timeouts, thresholds...). The menu owns *Faction*,
*Draw path*, *Pause while casting*, *Debug log*, *Waypoint reach*,
*Arrival reach*, *Stuck after* and *On-screen banner*, and rewrites those on
every update tick.

The menu page itself only draws values cached on the update tick.
`core.register_on_render_menu_callback` is documented as being for menu
elements alone, and calling a game function inside it crashed WoW Forever, so
nothing in `anav/ui.lua`'s render path reads the map, the player or the walker.
Menu buttons record the click and it is carried out on the next update.

For a remote server set `base_url = "https://nav.example.com"` and
`token = "<the server's sHttpToken>"`.

## Server HTTP API (for reference)

Plain text; the first line is `ok ...` or `err <code>`. Add `&fmt=json` to see JSON.

```
GET  /health
GET  /path?map&sx&sy&sz&ex&ey&ez[&flags][&state=normal|alliance|horde|dead][&random=1]
POST /paths        one "map sx sy sz ex ey ez [flags] [state]" per line (max 64)
GET  /height?map&x&y&z
GET  /raycast?map&sx&sy&sz&ex&ey&ez
GET  /move?map&sx&sy&sz&ex&ey&ez
GET  /random?map[&x&y&z&r]
```
