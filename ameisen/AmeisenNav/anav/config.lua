-- ============================================================================
-- AmeisenNav
-- anav/config.lua - defaults for every tunable
-- ============================================================================
-- Version: 1.5.0
-- Author: BLIZZ
-- ============================================================================
-- One shared table. The menu (anav/ui.lua) writes the user-facing values into
-- it every frame; consumers may change the rest through client:update_config().
-- ============================================================================

local C = {
    -- ------------------------------------------------------------------ server
    base_url            = "http://127.0.0.1:47110",
    token               = "",       -- sent as X-Nav-Token when set (remote server)
    request_timeout     = 3.0,      -- seconds before an unanswered request fails
    max_inflight        = 4,        -- concurrent HTTP requests
    max_queued          = 32,       -- requests waiting for a free slot
    health_interval     = 30,       -- seconds between pings while the server is up
    health_retry        = 5,        -- seconds between pings while it is down
    down_after_failures = 3,        -- transport failures in a row = server down

    -- ------------------------------------------------------------------ paths
    path_flags          = 0,        -- server smoothing flags (0 = straight corners)
    -- 1.6.8: NO SMOOTHING, ever: the smoothing bits (1 Chaikin, 2, 4) are
    -- stripped from every path request whatever the caller asks for
    -- (query.lua); VALIDATE_MAS (16) is kept.
    no_smoothing        = true,
    path_cache_ttl      = 10,       -- seconds a cached path stays valid
    path_cache_grid     = 4,        -- yards; start/end snapped to this grid for the cache key
    path_cache_size     = 64,
    partial_accept      = 5.0,      -- a partial path ending this close to the goal counts as complete

    -- --------------------------------------------------------------- follower
    waypoint_threshold  = 2.5,      -- yards to count a waypoint as reached
    final_threshold     = 1.5,      -- yards to count the destination as reached
    look_distance       = 8,        -- walker look-ahead; with direct_path the stub minimum (5) is used
    -- 1.6.9: DIRECT MOVEMENT ALONG THE PATH. The path is walked straight from
    -- waypoint to waypoint, unsmoothed: the walker aims at its own waypoint
    -- (look-ahead at the simple_movement minimum, 5 yd, instead of 8 - an 8 yd
    -- look-ahead rounds every corner), and the input driver no longer cuts to
    -- the next waypoint early. Server smoothing stays off (no_smoothing).
    direct_path         = true,
    pause_while_casting = true,
    driver              = "auto",   -- walker (simple_movement) | input (built-in) | auto
    use_look_at         = "auto",   -- walker steering: auto | look_at | turns
                                    -- auto = look_at everywhere except WoW Forever,
                                    -- where core.input.look_at does not turn the character
    turn_rate           = 180,      -- input driver: degrees per second the turn keys rotate
    heading_tolerance   = 12,       -- input driver: degrees off course before steering

    -- ------------------------------------------------------------ avoidance
    avoid               = true,     -- input driver: navmesh wall check + object cache + corner cutting
    avoid_units         = true,     -- treat living NPCs as obstacles too (players never)
    object_scan_every   = 0.3,      -- seconds between object cache refreshes (1.6.8: was 0.5)
    object_scan_radius  = 30,       -- yards around the player that are cached
    body_radius         = 0.6,      -- yards: the character's own width
    avoid_clearance     = 0.8,      -- extra yards kept from an object when passing it
    avoid_lookahead     = 8,        -- yards ahead that objects are checked
    wall_probe          = 6,        -- yards ahead the navmesh wall check reaches
    wall_short          = 0.75,     -- yards short of the probe point that count as a wall
    avoid_ask_every     = 0.15,     -- seconds between wall / corner questions to the server (1.6.8: 0.2)
    avoid_fresh         = 0.6,      -- seconds a server answer stays usable
    string_pull_range   = 15,       -- yards: skip to the next waypoint when it is this close and in view
    deviation_limit     = 8.0,      -- yards off the path before a repath

    -- ------------------------------------------------- path check (1.5.0)
    -- anav/pathcheck.lua: 5-yard waypoints; the next 3 (15 yd) are checked
    -- once each, as they come into range, with one batched server request.
    pathcheck           = true,     -- master switch
    waypoint_spacing    = 5.0,      -- yards: no two walked waypoints further apart
    check_ahead         = 3,        -- waypoints ahead of the player that are checked
    check_gap           = 0.15,     -- seconds: at most one check request this often (1.6.8: 0.25)
    max_climb           = 1.0,      -- yd up per yd (45 deg): steeper is re-planned
    max_drop            = 1.5,      -- yd down per yd: steeper is a cliff
    cliff_drop          = 6.0,      -- yd down in one leg: a cliff whatever the slope
    edge_clearance      = 1.5,      -- yards kept from walls / edges (1-2 yd)
    side_probes         = { 1.5, 3.0 }, -- yards to each side that are checked
    splice_flags        = 16,       -- re-planned pieces: VALIDATE_MAS, no Chaikin corner cutting
    max_splices         = 4,        -- per path

    -- ---------------------------------------------- rolling horizon (1.6.0)
    -- anav/horizon.lua: move_to walks validated 20-yard windows of 5-yard
    -- waypoints, re-planned from the player's position 5 yards before each
    -- window ends. Unsmoothed. Recorded routes (follow_path) keep pathcheck.
    horizon             = true,     -- master switch
    -- 1.6.8: smaller windows, planned earlier - each is checked and ready
    -- sooner, and the next one is prepared well before the walk reaches the
    -- end of the current one, so the character keeps moving.
    horizon_length      = 20.0,     -- yards of path per window (1.6.9: 20 again; 1.6.8 had 15)
    horizon_refresh     = 8.0,      -- yards before the window end: plan the next one (was 5)
    horizon_clearance   = 2.0,      -- yards kept from walls, ledges, drops (both sides)
    horizon_probes      = { 1.0, 2.0, 3.0 }, -- side probe distances (yards)
    horizon_object_clearance = 1.0, -- extra yards kept from cached objects
    -- 1.6.3 indoors (game_object:is_indoors): doorways and rooms are narrow
    -- 1.6.8: tighter indoors - closer waypoints, smaller clearances, a
    -- tighter "waypoint reached"
    horizon_clearance_indoors = 0.9,         -- was 1.25
    horizon_object_clearance_indoors = 0.3,  -- was 0.4
    waypoint_spacing_indoors = 3.0,          -- yards between waypoints indoors (5 outdoors)
    waypoint_threshold_indoors = 1.5,        -- yards to reach a waypoint indoors (2.5 outdoors)
    horizon_splices     = 3,        -- bad legs re-planned per window

    -- ------------------------------------- environment profiles (1.7.0)
    -- Window length, waypoint spacing, "reached" radius and clearances per
    -- kind of place (anav/coords.lua G.environment):
    --   open    outdoors, sky above
    --   indoor  is_indoors and no rock above: buildings, inns, crypts
    --   cave    the terrain surface is env_cave_cover+ yd ABOVE the character
    --           (it is under the ground), indoors flag or not
    -- Every "reached" radius is at least 2.0 yd: running at about 7 yd/s and
    -- turning 180 deg/s, the character's turning circle is about 2.2 yd, and a
    -- smaller radius approached off-axis is orbited instead of reached.
    -- Windows are re-planned with about 40% of the window still ahead, so the
    -- next one is checked and ready before the walk gets there.
    env_profiles = {
        open   = { length = 20.0, refresh = 8.0, spacing = 5.0, threshold = 2.5,
                   clearance = 2.0, object_clearance = 1.0 },
        indoor = { length = 12.0, refresh = 5.0, spacing = 3.0, threshold = 2.0,
                   clearance = 0.9, object_clearance = 0.3 },
        cave   = { length = 15.0, refresh = 6.0, spacing = 4.0, threshold = 2.0,
                   clearance = 1.2, object_clearance = 0.5 },
    },
    env_cave_cover      = 8.0,      -- yards of terrain above the character that make it a cave
    env_check_every     = 1.0,      -- seconds between environment reads

    -- ------------------------------------------- indoors / interact (1.6.1)
    arrive_dz           = 2.5,      -- yards of height: more is another floor, not arrived
    interact_pad        = 0.5,      -- yards kept from an object / NPC standing on the destination

    -- ------------------------------------------------------ handoff (1.6.0)
    handoff_face        = 1.0,      -- seconds a combat handoff keeps facing the target
    pathcheck_unsmoothed = true,    -- walk paths without Chaikin corner cutting (flag 1 dropped)
    max_repaths         = 10,       -- per navigation

    -- ------------------------------------------------------------ stuck logic
    stuck_sample        = 0.5,      -- seconds between position samples
    stuck_window        = 1.5,      -- seconds without progress = stuck
    stuck_min_move      = 0.8,      -- yards that count as progress in the window
    stuck_clear_move    = 3.0,      -- yards of progress that reset the stuck level
    max_stuck           = 6,        -- recovery attempts before giving up (1.6.5: 6 steps)
    unstick_after_fails = 2,        -- 1.6.5: failed plans from one spot before the manoeuvre
    backoff_time        = 0.6,      -- seconds of backing up in recovery

    -- --------------------------------------------------------------- follow
    follow_near         = 3.0,      -- yards: stand still this close to the followed unit
    follow_fast_range   = 30,       -- yards: re-path quickly inside this distance
    follow_fast         = 0.2,      -- seconds between re-paths when close
    follow_slow         = 1.0,      -- seconds between re-paths when far
    follow_repath_move  = 2.0,      -- yards the unit must move before a new path is asked
    follow_scan_every   = 2.0,      -- seconds between name scans (name mode)
    banner              = true,     -- on-screen status banner while navigating / following

    -- ------------------------------------------------------------- kite/flee
    escape_distance     = 12.0,

    -- -------------------------------------------------------------------- ui
    faction             = "auto",   -- query filter faction: auto | alliance | horde | none (menu)
    draw_path           = true,
    debug_log           = false,    -- print debug lines to the console too
    file_log            = true,     -- session log in scripts_log/ or scripts_data/ameisen_nav/
    server_log          = true,     -- also POST the log to the nav HTTP bridge (/log)
    log_keep            = 10,       -- session log files kept
}

return C
