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
    path_cache_ttl      = 10,       -- seconds a cached path stays valid
    path_cache_grid     = 4,        -- yards; start/end snapped to this grid for the cache key
    path_cache_size     = 64,
    partial_accept      = 5.0,      -- a partial path ending this close to the goal counts as complete

    -- --------------------------------------------------------------- follower
    waypoint_threshold  = 2.5,      -- yards to count a waypoint as reached
    final_threshold     = 1.5,      -- yards to count the destination as reached
    look_distance       = 8,
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
    object_scan_every   = 0.5,      -- seconds between object cache refreshes
    object_scan_radius  = 30,       -- yards around the player that are cached
    body_radius         = 0.6,      -- yards: the character's own width
    avoid_clearance     = 0.8,      -- extra yards kept from an object when passing it
    avoid_lookahead     = 8,        -- yards ahead that objects are checked
    wall_probe          = 6,        -- yards ahead the navmesh wall check reaches
    wall_short          = 0.75,     -- yards short of the probe point that count as a wall
    avoid_ask_every     = 0.2,      -- seconds between wall / corner questions to the server
    avoid_fresh         = 0.6,      -- seconds a server answer stays usable
    string_pull_range   = 15,       -- yards: skip to the next waypoint when it is this close and in view
    deviation_limit     = 8.0,      -- yards off the path before a repath

    -- ------------------------------------------------- path check (1.5.0)
    -- anav/pathcheck.lua: 5-yard waypoints; the next 3 (15 yd) are checked
    -- once each, as they come into range, with one batched server request.
    pathcheck           = true,     -- master switch
    waypoint_spacing    = 5.0,      -- yards: no two walked waypoints further apart
    check_ahead         = 3,        -- waypoints ahead of the player that are checked
    check_gap           = 0.25,     -- seconds: at most one check request this often
    max_climb           = 1.0,      -- yd up per yd (45 deg): steeper is re-planned
    max_drop            = 1.5,      -- yd down per yd: steeper is a cliff
    cliff_drop          = 6.0,      -- yd down in one leg: a cliff whatever the slope
    edge_clearance      = 1.5,      -- yards kept from walls / edges (1-2 yd)
    side_probes         = { 1.5, 3.0 }, -- yards to each side that are checked
    splice_flags        = 16,       -- re-planned pieces: VALIDATE_MAS, no Chaikin corner cutting
    max_splices         = 4,        -- per path
    pathcheck_unsmoothed = true,    -- walk paths without Chaikin corner cutting (flag 1 dropped)
    max_repaths         = 10,       -- per navigation

    -- ------------------------------------------------------------ stuck logic
    stuck_sample        = 0.5,      -- seconds between position samples
    stuck_window        = 1.5,      -- seconds without progress = stuck
    stuck_min_move      = 0.8,      -- yards that count as progress in the window
    stuck_clear_move    = 3.0,      -- yards of progress that reset the stuck level
    max_stuck           = 5,        -- recovery attempts before giving up
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
