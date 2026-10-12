-- ============================================================================
-- AmeisenNav
-- anav/config.lua - defaults for every tunable
-- ============================================================================
-- Version: 1.0.0
-- Author: BLIZZ
-- ============================================================================
-- One shared table. The menus (anav/ui.lua, anav/tune.lua) write the
-- user-facing values into it every frame; consumers may change the rest
-- through client:update_config(). Steering reads most distances through
-- anav/profile.lua, which swaps in C.profiles.<name> where the player is.
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
    pause_while_controlled = true,  -- hold the walk while stunned / rooted / feared / charmed
    driver              = "auto",   -- walker (simple_movement) | input (built-in) | auto
    use_look_at         = "auto",   -- walker steering: auto | look_at | turns
                                    -- auto = look_at everywhere except WoW Forever,
                                    -- where core.input.look_at does not turn the character
    turn_rate           = 180,      -- input driver: degrees per second the turn keys rotate
    heading_tolerance   = 12,       -- input driver: degrees off course before steering
    use_facing          = "auto",   -- input driver: steer by the player's reported facing
                                    -- auto = once it has matched the running direction
                                    -- 3 times this session | on | off (measure from positions)

    -- ------------------------------------------------------------ avoidance
    avoid               = true,     -- input driver: navmesh wall check + object cache + corner cutting
    avoid_units         = true,     -- treat living NPCs as obstacles too (players never)
    object_scan_every   = 0.5,      -- seconds between object cache refreshes
    object_scan_radius  = 30,       -- yards around the player that are cached
    body_radius         = 0.6,      -- yards: the character's own width
    avoid_clearance     = 0.8,      -- extra yards kept from an object when passing it
    avoid_lookahead     = 8,        -- yards ahead that objects are checked
    wall_trace          = true,     -- walls from the client collision trace (trace_line, safe mask);
                                    -- falls back to the server /move check when unavailable
    ground_check        = true,     -- corner cutting: sample the ground along the shortcut
                                    -- (core.get_height_for_position) to see drops and water
    wall_probe          = 6,        -- yards ahead the wall check reaches
    wall_short          = 0.75,     -- yards short of the probe point that count as a wall
    avoid_ask_every     = 0.2,      -- seconds between wall / corner questions to the server
    avoid_fresh         = 0.6,      -- seconds a server answer stays usable
    string_pull_range   = 15,       -- yards: skip to the next waypoint when it is this close and in view
    deviation_limit     = 8.0,      -- yards off the path before a repath
    max_repaths         = 10,       -- per navigation

    -- ------------------------------------------------------------ stuck logic
    stuck_sample        = 0.5,      -- seconds between position samples
    stuck_window        = 1.5,      -- seconds without progress = stuck
    stuck_min_move      = 0.8,      -- yards that count as progress in the window
    stuck_clear_move    = 3.0,      -- yards of progress that reset the stuck level
    max_stuck           = 5,        -- recovery attempts before giving up
    backoff_time        = 0.6,      -- seconds of backing up in recovery

    ground_max_dev      = 2.0,      -- corner cutting: ground this far off the straight line
                                    -- is a drop, bump or water (outdoor; see profiles)
    avoid_units_in_combat = false,  -- in combat the units around you are the fight, not obstacles
    show_rays           = false,    -- draw the wall / ground probes in the world (menu)

    -- ------------------------------------------------------------- profiles
    -- anav/profile.lua picks one by where the player is. The plain keys
    -- are the outdoor profile; the others list only what differs.
    profile_mode        = "auto",   -- auto | outdoor | indoor | swim (menu)
    scale_with_speed    = true,     -- grow reach / look-ahead with speed (mounted)
    speed_scale_max     = 2.5,
    profiles = {
        indoor = {                  -- buildings and caves
            waypoint_threshold = 1.5,  -- turn exactly at doorways
            final_threshold    = 1.0,
            wall_probe         = 3.0,  -- a 6 yd probe hits the far wall of every room
            avoid_lookahead    = 4,
            avoid_clearance    = 0.4,  -- 0.8 would make corridors impassable
            string_pull_range  = 6,    -- short shortcuts: rooms, stairs, cave bends
            deviation_limit    = 5,
            stuck_window       = 1.5,
            ground_max_dev     = 1.2,  -- balconies, stair wells, cave ledges
        },
        swim = {
            waypoint_threshold = 2.0,
            wall_probe         = 4.0,  -- slower: less look-ahead needed
            string_pull_range  = 10,
            stuck_window       = 2.5,  -- currents and slow turns are not stuck
            ground_check       = false, -- the probe answers the lake bed
        },
    },

    -- --------------------------------------------------------------- combat
    combat_mode         = "continue", -- continue | pause | stop: own navigation when combat starts
                                      -- (consumers such as Master_Farmer_Bot stop it themselves)

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
