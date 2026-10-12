# Master Farmer movement (3.0.0)

Grinding, questing, gathering and vendor/NPC runs all move through **AmeisenNav
2.0.0** (`_G.AmeisenNav.client`, see `ameisen/AmeisenNav/docs/API.md`). The
plugin decides where to go and when to stand still. AmeisenNav does the rest:

- navmesh paths;
- the wall traces, which use only safe collision masks and are crash-guarded;
- object avoidance and corner cutting;
- stuck recovery;
- indoor and swim profiles.

The plugin casts **no ray** of its own and never drives `simple_movement` while
AmeisenNav is loaded.

## Modules

| file | job |
|---|---|
| `movement.lua` | the facade the rest of the bot calls (`require("movement")`) |
| `movement/core.lua` | shared state, positions, distances, logging |
| `movement/nav.lua` | travel: `move_to` / `follow_path` / `stop` / `pause`; failures; reachability; height retry; AmeisenNav-missing fallback |
| `movement/combat.lua` | closing on a target, standing in range, retreat (`client:kite`), "no way closer" |
| `movement/locks.lua` | rest, cast, channel and loot holds (AmeisenNav pause reasons), backpedal |
| `movement/range.lua` | facing (a position, never a unit object), line of sight without rays, arrival, fight range |
| `movement/sight.lua` | reachable / underground / around (no line of sight) from one navmesh path |
| `movement/leash.lua` | the recorded-path corridor `path_runner` keeps to |
| `movement/zones.lua` | blacklisted areas and danger circles (no game calls) |

## Behaviour

**Travel.** `nav_to(dest)` starts a walk, or keeps the running one:
- **Same place:** within 2 yd of the current destination, it's a no-op, so callers can ask every tick.
- **New place while walking:** a seamless re-path, where the walk takes the new path without releasing a key. Retargets are at least 0.25 s apart.
- **Refused:** during a fight, a rest or a backpedal; for a blacklisted area; or for a spot that just failed.
- **Guessed heights.** RestedXP waypoints give x and y only. A no-path answer for a point within 150 yd asks AmeisenNav for the ground there (`get_height`, probing from 60 yd up), walks again at that height, and remembers it (`reach_z`) so the route uses it.
- **Failures.** The last failure's code is kept (`last_fail_reason`, `last_fail_offmesh`). The same spot failing off-mesh twice within 2 minutes is blacklisted.

**Routes.** `follow_route(list)` hands AmeisenNav a recorded route (`follow_path`). Its recovery rejoins the route at the waypoint being approached. Grinding and gathering hand over **one full lap** at a time: `follow_path` cannot take a new list without stopping, so the old "refill every few nodes" approach stuttered.
- **Starting point:** a grind route starts at the nearest point or waypoint to wherever the player stands. It walks there first with a pathfinding `move_to`.
- **Direction:** it always loops, last waypoint to first. *Reverse Path* walks it the other way.

**Combat.** `combat_engage(player, unit, yards)` is called every tick of a fight:
- **Holds travel:** for 1 s per call. `combat_release` hands the player back at once.
- **In position:** in sight and in range. For melee that's the GUI melee distance, held to +1 yd. For ranged it's 3 yd inside the range, held to the full range. The walk stops, the player faces the target, and it answers true.
- **Closing:** otherwise AmeisenNav walks to the target with seamless re-paths. A unit standing on the goal is never treated as an obstacle.
- **No way closer:** no 2 yd of progress for 10 s marks the target unreachable.
- **Retreat:** a class rule (`should_retreat`) walks to AmeisenNav's kite point.
- **AmeisenNav setting:** its *When combat starts* must be **Continue**. The bot warns once a minute if it isn't.

**Holds.** Casts, channels and looting pause the walk through AmeisenNav's own pause reasons (`mf_cast`, `mf_loot`). Each hold ends on time from the movement pulse. A rest halts and refuses everything until it's lifted. Backpedal walks backwards with the core keys and jumps 0.75 s in by default.

**Line of sight**, no ray. A unit is in sight unless:
- the game refused a cast at it ("Target not in line of sight") within 2.5 s; or
- the navmesh says the walk to it bends round something, or it's underground or unreachable.

3 yd and closer always counts as in sight.

## NPC runs

Full bags (the *Vendor at Free Slots* setting) or worn gear (*Repair at Durability %*) start a vendor run. A grinding route picks its NPC in this order:

1. the vendor **saved for the route** (Vendor tab: target the NPC, then *Save Target as Route Vendor*; *Clear Route Vendor* forgets it), kept in `scripts_data/mfb/route_vendors.txt`;
2. the route's own merchant record;
3. a vendor in sight;
4. the nearest repair NPC or innkeeper the bot has seen on this continent (`scripts_data/mfb/merchants.txt`);
5. the Hearthstone, or the inn list.

After the run, the bot walks back to the route's nearest waypoint and carries on.
