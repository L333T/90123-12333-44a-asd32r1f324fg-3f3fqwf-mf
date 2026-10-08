# Ameisen navigation (Master Farmer - Grindbot 2.236.0+)

Since 2.236.0 the Grindbot's out-of-combat travel goes through **AmeisenNav**
(`_G.AmeisenNav.client`) instead of Sentinel. Combat movement still uses the local walker.
The in-game loader downloads only the Grindbot itself. AmeisenNav, the nav server and the
maps are installed by hand, once, from this folder.

Nothing in `ameisen/` goes into `manifest.lua` or the local build (`make_manifest.py` /
`make_local.py` skip it).

## Install

1. **AmeisenNav plugin:** copy `ameisen/AmeisenNav/` to `<game install>\scripts\AmeisenNav\`.
2. **Nav server:** make `<game install>\scripts\Ameisen\` holding
   - `AmeisenNavigationServer.exe` (AmeisenNavigation 1.8.3.2 binary release; not in git),
   - `http_bridge.py`, `Start-Ameisen.bat`, `config.cfg` from `ameisen/server/`,
   - `mmaps\` with the navmesh tiles (about 1.9 GB, 3,510 files; **not in git**).
3. Edit `config.cfg`: set `sMmapsPath=` to the full path of that `mmaps\` folder (ending in `\`).
4. Python 3 must be on the PATH as `py -3` (the bridge).

## Run

1. Start `scripts\Ameisen\Start-Ameisen.bat` and leave the window open. It serves
   `http://127.0.0.1:47110` and forwards to TCP `127.0.0.1:47111`.
2. Reload Sylvanas scripts. The AmeisenNav menu should say *Server: connected*.
3. Grindbot status panel, **Ameisen** row:
   - `Ameisen ready` (green): travel uses Ameisen. **Movement** shows `(Ameisen)` on a leg.
   - `server down - start Ameisen\Start-Ameisen.bat`: the server isn't running.
   - `AmeisenNav not loaded`: `scripts\AmeisenNav` is missing or failed to load.

With the server down the bot logs `server_down - walking this leg without Ameisen` and carries on
with the local walker. It picks Ameisen up again within about 30 s of a restart.

## Logs and data

- Session logs: `scripts_log\MASTER_FARMER_ERRORS\` (as before). Lines: `ameisen: leg '…' failed: <code>`
  (`no_path`, `end_off_mesh`, `start_off_mesh`, `map_not_loaded`, `server_down`, `max_stuck_exceeded`, …),
  `ameisen: map A -> B`, and the MEM line `ameisen requests N issued` (limit 1 per second).
- Settings: `scripts_data\mfg\` (as before). Learned bad terrain for the Ameisen meshes:
  `scripts_data\mfb\hazards_<map>.txt` (kept apart from the Sentinel-era hazards).

## What differs from the Sentinel build

| Sentinel feature | With Ameisen |
|---|---|
| `find_path_avoid` (route round blacklisted / hazard zones) | Built locally from Ameisen `find_path`: plan direct; if it crosses a zone, plan via a detour point beside it. |
| Obstacle-service mirror of the zones | None (Ameisen has no obstacle list); zones reach it through the detour planner. |
| `check_path`, `probe_path_ahead`, corridor re-plan | Not available. Ameisen's follower re-paths past 8 yd off the path; its stuck ladder handles doorways. |
| Navmesh height of far quest waypoints | Not available on server 1.8.3.2 (no `GET_HEIGHT`). Far waypoints use the player's height until close; `end_off_mesh` / `no_path` retries at the floor heights there. |
| Continent change via `get_continent_id` | `core.get_map_id()` change resets zones, caches and learned hazards. |
| "Cancelled" | Ameisen's `cancelled` (bot stopped or replaced a route) is ignored, never a failure. |

Also: no `/raycast` is ever sent (the 1.8.3.2 server never answers it and the bridge then blocks
every request for 30 s); grind paths are handed over as one long route (60 nodes); re-targets use
Ameisen's seamless `move_to`; every path request sends `flags = 17` (`SMOOTH_CHAIKIN | VALIDATE_MAS`).

**AmeisenNav 1.5.0 path check** (`AmeisenNav/anav/pathcheck.lua`, docs/API.md "Path check"): walked
paths are resampled to 5-yard waypoints; the next 3 (15 yd) are checked once each with short server paths -
ground height, climbs over 1 yd/yd, drops over 1.5 yd/yd or 6 yd, legs leaving the mesh (re-planned unsmoothed
and spliced in), and walls / edges 1.5 and 3 yd to each side (the waypoint is kept 1-2 yd away; narrow
corridors are centred). About 3 small requests a second while walking, no native game calls. While it runs, the
bot's `flags = 17` is walked as 16 (Chaikin smoothing left the mesh on a measured route) and the input
driver's corner skipping is off. `/raycast` does worse than block: on 2026-10-08 it took 3.5 s and then killed
AmeisenNavigationServer.

## Known server-side gaps (not changed)

- The server sends no reply to an unknown message type or a too-small packet; `http_bridge.py`
  waits `TCP_TIMEOUT = 30` s (retried once) under one lock, `/health` included.
  Fix in the bridge: ~5 s timeout, lock-free `/health`.
- Source 1.8.4.0 adds `GET_HEIGHT` and `CONFIGURE_FILTER` (water cost, faction / ghost state);
  the installed binary is 1.8.3.2. Building 1.8.4.0 would bring back mesh heights for far waypoints
  and let routes avoid water.
