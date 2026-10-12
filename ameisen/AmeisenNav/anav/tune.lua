-- ============================================================================
-- AmeisenNav
-- anav/tune.lua - "Ameisen Movement" menu page: movement tuning and tests
-- ============================================================================
-- Version: 1.0.0
-- Author: BLIZZ
-- ============================================================================
-- Same split as anav/ui.lua: Tune.tick (on_update) reads the widgets into the
-- config, refreshes the readout and runs button actions; Tune.render_menu
-- only draws widgets and cached text; Tune.render_world only draws cached
-- probes. Element ids are saved by the loader: keep them stable. The outdoor
-- reach / arrival / stuck sliders keep the ids they had on the AmeisenNav
-- page, so saved values carry over.
-- ============================================================================

---@type color
local color = require("common/color")
---@type vec3
local vec3 = require("common/geometry/vector_3")

local C  = require("anav/config")
local L  = require("anav/log")
local X  = require("anav/context")
local Q  = require("anav/query")
local P  = require("anav/profile")
local A  = require("anav/avoid")
local F  = require("anav/follower")

local Tune = {}
local fmt = string.format

-- ----------------------------------------------------------------------------
-- slider definitions (profile keys, in P.KEYS order)
-- ----------------------------------------------------------------------------
local SLIDERS = {
    waypoint_threshold = { 0.5, 5.0, "Waypoint reach (yd)",
        "A corner counts as reached this close. Larger cuts corners, smaller turns exactly at doorways" },
    final_threshold = { 0.3, 4.0, "Arrival reach (yd)",
        "The destination counts as reached this close" },
    wall_probe = { 1.0, 12.0, "Wall look-ahead (yd)",
        "How far ahead the knee / chest rays look for walls. Too long indoors and it reacts to the far wall of the room" },
    avoid_lookahead = { 1.0, 15.0, "Object look-ahead (yd)",
        "How far ahead objects and NPCs in the way are noticed" },
    avoid_clearance = { 0.0, 2.0, "Object clearance (yd)",
        "Extra room kept when passing an object. Too much and narrow gaps become impassable" },
    string_pull_range = { 0.0, 30.0, "Corner-cut range (yd)",
        "Skip to the next waypoint when it is this close and the way is clear. 0 = never cut corners" },
    deviation_limit = { 2.0, 20.0, "Off-path limit (yd)",
        "Pushed further than this off the path (knock-back, fear) = repath" },
    stuck_window = { 0.8, 5.0, "Stuck after (s)",
        "Seconds without progress before stuck recovery starts" },
    ground_max_dev = { 0.5, 5.0, "Ledge / drop height (yd)",
        "Corner cutting: ground this far above or below the straight line is a drop, step or water" },
}

-- ids that existed on the AmeisenNav page (saved values carry over)
local LEGACY_IDS = {
    waypoint_threshold = "anav_wp_threshold",
    final_threshold = "anav_final_threshold",
    stuck_window = "anav_stuck_window",
}

local PROFILES = {
    { key = "outdoor", label = "Outdoor" },
    { key = "indoor",  label = "Indoor & caves" },
    { key = "swim",    label = "Swimming" },
}

local function base_value(profile, key)
    if profile ~= "outdoor" then
        local over = C.profiles[profile]
        if over and over[key] ~= nil then return over[key] end
    end
    return C[key]
end

-- ----------------------------------------------------------------------------
-- elements
-- ----------------------------------------------------------------------------
local PROFILE_MODES  = { "auto", "outdoor", "indoor", "swim" }
local PROFILE_LABELS = { "Auto (indoors / outdoors / swimming)", "Always outdoor", "Always indoor & caves", "Always swimming" }
local COMBAT_MODES   = { "continue", "pause", "stop" }
local COMBAT_LABELS  = { "Continue (consumer decides)", "Pause until combat ends", "Stop the navigation" }
local FACING_MODES   = { "auto", "on", "off" }
local FACING_LABELS  = { "Auto (check it first)", "Always steer by facing", "Never (measure from positions)" }
local DRIVERS        = { "auto", "walker", "input" }
local DRIVER_LABELS  = { "Auto", "simple_movement", "Built-in input" }

local function index_of(list, value)
    for i = 1, #list do if list[i] == value then return i end end
    return 1
end

local m = {
    tree         = core.menu.tree_node(),
    t_env        = core.menu.tree_node(),
    t_obst       = core.menu.tree_node(),
    t_combat     = core.menu.tree_node(),
    t_steer      = core.menu.tree_node(),
    t_test       = core.menu.tree_node(),
    profile_mode = core.menu.combobox(index_of(PROFILE_MODES, C.profile_mode), "anav_t_profile_mode"),
    scale_speed  = core.menu.checkbox(C.scale_with_speed, "anav_t_scale_speed"),
    speed_max    = core.menu.slider_float(1.0, 4.0, C.speed_scale_max, "anav_t_speed_max"),
    wall_trace   = core.menu.checkbox(C.wall_trace, "anav_t_wall_trace"),
    ground_check = core.menu.checkbox(C.ground_check, "anav_t_ground_check"),
    avoid        = core.menu.checkbox(C.avoid, "anav_t_avoid"),
    avoid_units  = core.menu.checkbox(C.avoid_units, "anav_t_avoid_units"),
    units_combat = core.menu.checkbox(C.avoid_units_in_combat, "anav_t_units_combat"),
    body_radius  = core.menu.slider_float(0.3, 1.5, C.body_radius, "anav_t_body_radius"),
    scan_radius  = core.menu.slider_float(10, 60, C.object_scan_radius, "anav_t_scan_radius"),
    show_rays    = core.menu.checkbox(C.show_rays, "anav_t_show_rays"),
    combat_mode  = core.menu.combobox(index_of(COMBAT_MODES, C.combat_mode), "anav_t_combat_mode"),
    pause_ctrl   = core.menu.checkbox(C.pause_while_controlled, "anav_t_pause_ctrl"),
    use_facing   = core.menu.combobox(index_of(FACING_MODES, C.use_facing), "anav_t_use_facing"),
    heading_tol  = core.menu.slider_float(4, 30, C.heading_tolerance, "anav_t_heading_tol"),
    driver       = core.menu.combobox(index_of(DRIVERS, C.driver), "anav_t_driver"),
    btn_ahead    = core.menu.button("anav_t_btn_ahead"),
    btn_random   = core.menu.button("anav_t_btn_random"),
    btn_square   = core.menu.button("anav_t_btn_square"),
    btn_target   = core.menu.button("anav_t_btn_target"),
    btn_walls    = core.menu.button("anav_t_btn_walls"),
    btn_ground   = core.menu.button("anav_t_btn_ground"),
    btn_stop     = core.menu.button("anav_t_btn_stop"),
    btn_reset    = core.menu.button("anav_t_btn_reset"),
}

-- profile sliders: prof[profile][key] = { el = slider, default = n }
local prof, prof_tree = {}, {}
for _, p in ipairs(PROFILES) do
    prof[p.key] = {}
    prof_tree[p.key] = core.menu.tree_node()
    for _, key in ipairs(P.KEYS) do
        local def = SLIDERS[key]
        local value = base_value(p.key, key)
        local id = (p.key == "outdoor" and LEGACY_IDS[key]) or ("anav_t_" .. p.key .. "_" .. key)
        prof[p.key][key] = { el = core.menu.slider_float(def[1], def[2], value, id), default = value }
    end
end

-- defaults for "Reset", captured before the menu has written anything
local DEFAULTS = {
    { m.profile_mode, index_of(PROFILE_MODES, C.profile_mode) },
    { m.scale_speed, C.scale_with_speed }, { m.speed_max, C.speed_scale_max },
    { m.wall_trace, C.wall_trace }, { m.ground_check, C.ground_check }, { m.avoid, C.avoid },
    { m.avoid_units, C.avoid_units }, { m.units_combat, C.avoid_units_in_combat },
    { m.body_radius, C.body_radius }, { m.scan_radius, C.object_scan_radius },
    { m.show_rays, C.show_rays }, { m.combat_mode, index_of(COMBAT_MODES, C.combat_mode) },
    { m.pause_ctrl, C.pause_while_controlled }, { m.use_facing, index_of(FACING_MODES, C.use_facing) },
    { m.heading_tol, C.heading_tolerance }, { m.driver, index_of(DRIVERS, C.driver) },
}
for _, p in ipairs(PROFILES) do
    for _, key in ipairs(P.KEYS) do
        local s = prof[p.key][key]
        DEFAULTS[#DEFAULTS + 1] = { s.el, s.default }
    end
end

-- ----------------------------------------------------------------------------
-- widget reads (update side)
-- ----------------------------------------------------------------------------
local function get_bool(el, fallback)
    local ok, v = pcall(el.get_state, el)
    if ok and type(v) == "boolean" then return v end
    return fallback
end

local function get_num(el, fallback)
    local ok, v = pcall(el.get, el)
    if ok and type(v) == "number" then return v end
    return fallback
end

local function get_choice(el, list, fallback)
    local i = get_num(el, nil)
    if not i then return fallback end
    if i < 1 then i = i + 1 end -- tolerate a 0-based combobox
    return list[i] or fallback
end

local function sync_config()
    C.profile_mode = get_choice(m.profile_mode, PROFILE_MODES, C.profile_mode)
    C.scale_with_speed = get_bool(m.scale_speed, C.scale_with_speed)
    C.speed_scale_max = get_num(m.speed_max, C.speed_scale_max)
    C.wall_trace = get_bool(m.wall_trace, C.wall_trace)
    C.ground_check = get_bool(m.ground_check, C.ground_check)
    C.avoid = get_bool(m.avoid, C.avoid)
    C.avoid_units = get_bool(m.avoid_units, C.avoid_units)
    C.avoid_units_in_combat = get_bool(m.units_combat, C.avoid_units_in_combat)
    C.body_radius = get_num(m.body_radius, C.body_radius)
    C.object_scan_radius = get_num(m.scan_radius, C.object_scan_radius)
    C.show_rays = get_bool(m.show_rays, C.show_rays)
    C.combat_mode = get_choice(m.combat_mode, COMBAT_MODES, C.combat_mode)
    C.pause_while_controlled = get_bool(m.pause_ctrl, C.pause_while_controlled)
    C.use_facing = get_choice(m.use_facing, FACING_MODES, C.use_facing)
    C.heading_tolerance = get_num(m.heading_tol, C.heading_tolerance)
    C.driver = get_choice(m.driver, DRIVERS, C.driver)
    for _, p in ipairs(PROFILES) do
        local target = p.key == "outdoor" and C or C.profiles[p.key]
        if not target then target = {}; C.profiles[p.key] = target end
        for _, key in ipairs(P.KEYS) do
            target[key] = get_num(prof[p.key][key].el, target[key] or C[key])
        end
    end
end

-- ----------------------------------------------------------------------------
-- readout (filled on update, drawn on render)
-- ----------------------------------------------------------------------------
local snap = { lines = {}, result = nil, result_ok = true, result_t = 0 }

local PROFILE_NAMES = { outdoor = "Outdoor", indoor = "Indoor / cave", swim = "Swimming" }

local function yn(b) return b and "yes" or "no" end

local function refresh()
    local e = P.env
    local lines = {}
    local forced = C.profile_mode ~= "auto"
    lines[#lines + 1] = { fmt("Profile: %s%s", PROFILE_NAMES[e.profile] or e.profile,
        forced and "  (forced in the menu)" or "  (auto)"), color.cyan(230) }
    lines[#lines + 1] = { fmt("Indoors %s   swimming %s   mounted %s   in combat %s",
        yn(e.indoors), yn(e.swimming), yn(e.mounted), yn(e.combat)) }
    lines[#lines + 1] = { fmt("Speed %.1f yd/s   distance scale x%.2f%s", e.speed, e.factor,
        C.scale_with_speed and "" or " (off)") }

    local _, _, pz = X.position()
    local ground = e.ground
    local above = (pz and ground) and (pz - ground) or nil
    lines[#lines + 1] = { fmt("Player height %.2f yd   rays at %.2f / %.2f yd", e.height, e.knee, e.chest) }
    if ground then
        lines[#lines + 1] = { fmt("Ground under you %.2f   you are at %.2f (%s)", ground, pz or 0,
            (above and math.abs(above) < 0.5) and "on the ground"
            or fmt("%.1f yd above what the probe hit", above or 0)) }
    else
        lines[#lines + 1] = { "Ground under you: no answer (probe missed or unavailable)", color.gray(200) }
    end

    lines[#lines + 1] = { fmt("Now: reach %.1f / arrival %.1f   walls %.1f   objects %.1f   clearance %.1f",
        P.get("waypoint_threshold"), P.get("final_threshold"), P.get("wall_probe"),
        P.get("avoid_lookahead"), P.get("avoid_clearance")) }
    lines[#lines + 1] = { fmt("Now: corner cut %.1f   off-path %.1f   stuck %.1fs   ledge %.1f   ground check %s",
        P.get("string_pull_range"), P.get("deviation_limit"), P.get("stuck_window"),
        P.get("ground_max_dev"), P.ground_check() and "on" or "off") }

    local trace = not C.wall_trace and "off" or (X.trace_available() and "client trace" or "server (trace blocked)")
    local facing = F.facing_trusted == true and "facing" or (F.facing_trusted == false and "positions" or "checking")
    lines[#lines + 1] = { fmt("Walls: %s   units avoided: %s   obstacles cached %d (%s)   steering: %s",
        trace, P.avoid_units() and "yes" or "no", A.cached_count(), X.objects_source(), facing), color.gray(220) }
    snap.lines = lines
end

local function result(ok, text, ...)
    snap.result = fmt(text, ...)
    snap.result_ok = ok
    snap.result_t = core.time()
    L.info("tune test: %s", snap.result)
end

-- ----------------------------------------------------------------------------
-- tests (update side)
-- ----------------------------------------------------------------------------
local pending = nil
local function request(action) pending = action end

local function nav_cb(label)
    return function(ok, reason, detail)
        if ok then result(true, "%s: arrived", label)
        else result(detail and detail.code == "cancelled", "%s: %s (%s)", label,
            tostring(detail and detail.code), tostring(detail and detail.detail or reason)) end
    end
end

--- A point `dist` yards ahead of the player, on the ground where the client
--- can tell, else at the player's height.
local function ahead(dist)
    local px, py, pz = X.position()
    local f = X.facing()
    if not px or not f then return nil end
    local x, y = px + math.cos(f) * dist, py + math.sin(f) * dist
    local z = X.ground_height(x, y, pz, 10) or pz
    return { x = x, y = y, z = z }, px, py, pz
end

local function run_request(client)
    local a = pending
    if not a then return end
    pending = nil
    local px, py, pz = X.position()
    if not px then result(false, "no player position"); return end

    if a == "ahead" then
        local p = ahead(20)
        if not p then result(false, "walk ahead: facing unknown"); return end
        result(true, "walking 20 yd ahead (pathfinding)...")
        client:move_to(p, nav_cb("20 yd ahead"))
    elseif a == "random" then
        result(true, "asking the server for a mesh point within 25 yd...")
        Q.random_point({ x = px, y = py, z = pz }, 25, function(ok, p)
            if not ok or not p then result(false, "random point: no answer from the server"); return end
            client:move_to(p, nav_cb("random point"))
        end)
    elseif a == "square" then
        local d = 10
        result(true, "walking a %d yd square (no pathfinding: steering and avoidance only)...", d)
        client:follow_path({
            { x = px + d, y = py, z = pz }, { x = px + d, y = py + d, z = pz },
            { x = px, y = py + d, z = pz }, { x = px, y = py, z = pz },
        }, nav_cb("square"))
    elseif a == "target" then
        local t = X.target()
        local okp, pos = false, nil
        if t then okp, pos = X.call(t, "get_position") end
        if not (okp and pos) then result(false, "walk to target: no target selected"); return end
        result(true, "walking to the target...")
        client:move_to({ x = pos.x, y = pos.y, z = pos.z }, nav_cb("target"))
    elseif a == "walls" then
        local p = ahead(P.get("wall_probe"))
        if not p then result(false, "wall probe: facing unknown"); return end
        local clear = A.ray_clear(px, py, pz, p.x, p.y, p.z)
        if clear == nil then
            result(false, "wall probe: client trace unavailable (blocked or off)")
        else
            local side = A.open_side(px, py, pz, p.x, p.y)
            result(clear, "wall probe %.1f yd ahead: %s; sidestep side: %s", P.get("wall_probe"),
                clear and "clear" or "BLOCKED", side == 1 and "left" or (side == -1 and "right" or "none open"))
        end
    elseif a == "ground" then
        local p = ahead(10)
        if not p then result(false, "ground probe: facing unknown"); return end
        p.z = pz -- the straight line from the feet, as corner cutting tests it
        local ok = A.ground_follows(px, py, pz, p)
        if ok == nil then result(false, "ground probe: no answer (ground not loaded or call unavailable)")
        else result(ok, "ground 10 yd ahead: %s (limit %.1f yd)", ok and "follows the line"
            or "drop, step or water on the line", P.get("ground_max_dev")) end
    elseif a == "stop" then
        client:stop("menu")
        result(true, "stopped")
    elseif a == "reset" then
        for _, d in ipairs(DEFAULTS) do pcall(d[1].set, d[1], d[2]) end
        sync_config() -- apply now, not on the next tick
        result(true, "movement settings reset to defaults")
    end
end

--- Call once per update tick, before the client update.
function Tune.tick(client)
    sync_config()
    refresh()
    run_request(client)
end

-- ----------------------------------------------------------------------------
-- render side: widgets and cached text only
-- ----------------------------------------------------------------------------
local HEADER_POOL = 20
local header_pool = {}
for i = 1, HEADER_POOL do header_pool[i] = core.menu.header() end
local header_next = 1

local function header(text, col)
    local el = header_pool[header_next]
    if not el then return end
    header_next = header_next + 1
    el:render(text, col or color.white(220))
end

local reported = {}
local function section(name, fn)
    local ok, err = xpcall(fn, L.traceback)
    if not ok and not reported[name] then
        reported[name] = true
        L.error("movement menu section '%s' failed: %s", name, tostring(err))
    end
end

local function render_profile(p)
    prof_tree[p.key]:render(p.label .. " profile", function()
        for _, key in ipairs(P.KEYS) do
            local def = SLIDERS[key]
            prof[p.key][key].el:render(def[3], def[4])
        end
    end)
end

function Tune.render_menu()
    header_next = 1
    m.tree:render("Ameisen Movement", function()
        section("readout", function()
            for _, line in ipairs(snap.lines) do header(line[1], line[2]) end
            if snap.result then
                header("Test: " .. snap.result, snap.result_ok and color.green(230) or color.orange(230))
            end
        end)
        section("env", function()
            m.t_env:render("Environment", function()
                m.profile_mode:render("Profile", PROFILE_LABELS,
                    "Auto switches by where you are. Force one to test it anywhere")
                m.scale_speed:render("Scale distances with speed",
                    "Mounted or sprinting: reach and look-ahead grow with speed so corners are not orbited")
                m.speed_max:render("Speed scale limit", "Largest distance multiplier from speed")
            end)
        end)
        section("profiles", function()
            for _, p in ipairs(PROFILES) do render_profile(p) end
        end)
        section("obstacles", function()
            m.t_obst:render("Obstacles & terrain", function()
                m.avoid:render("Avoidance", "Steer around walls and objects (built-in input driver)")
                m.wall_trace:render("Walls from the game client",
                    "Collision rays from the client (same frame). Off: ask the nav server instead")
                m.ground_check:render("Ground check for corner cuts",
                    "Sample the ground along a shortcut: drops, steps and water stop it")
                m.avoid_units:render("Avoid NPCs", "Living NPCs count as obstacles (players never do)")
                m.units_combat:render("Avoid NPCs in combat",
                    "Off: in combat the units around you are the fight, not obstacles")
                m.body_radius:render("Body radius (yd)", "Half the character's width")
                m.scan_radius:render("Object scan radius (yd)", "Objects this close are cached as obstacles")
                m.show_rays:render("Show probes", "Draw the wall rays and ground samples in the world")
            end)
        end)
        section("combat", function()
            m.t_combat:render("Combat & control", function()
                m.combat_mode:render("When combat starts", COMBAT_LABELS,
                    "What AmeisenNav does with its own walk. Master Farmer stops it itself, so Continue suits it")
                m.pause_ctrl:render("Pause while stunned / rooted / feared",
                    "Hold the walk instead of treating loss of control as stuck")
            end)
        end)
        section("steering", function()
            m.t_steer:render("Steering", function()
                m.driver:render("Movement driver", DRIVER_LABELS,
                    "Auto: simple_movement, the built-in driver where it refuses (WoW Forever)")
                m.use_facing:render("Steer by facing", FACING_LABELS,
                    "Turn until the reported facing lines up, instead of timed turns")
                m.heading_tol:render("Heading tolerance (deg)", "Off course by more than this before turning")
            end)
        end)
        section("tests", function()
            m.t_test:render("Tests", function()
                if m.btn_ahead:render("Walk 20 yd ahead", "Pathfind to a point 20 yd in front of you") then request("ahead") end
                if m.btn_random:render("Walk to a random point", "A random navmesh point within 25 yd") then request("random") end
                if m.btn_square:render("Walk a 10 yd square", "Straight legs, no pathfinding: tests turning, walls and objects") then request("square") end
                if m.btn_target:render("Walk to my target", "Pathfind to the current target") then request("target") end
                if m.btn_walls:render("Probe walls ahead", "Cast the wall rays in front of you now and report") then request("walls") end
                if m.btn_ground:render("Probe ground ahead", "Sample the ground 10 yd ahead as a corner cut would") then request("ground") end
                if m.btn_stop:render("Stop", "Stop the current navigation") then request("stop") end
                if m.btn_reset:render("Reset movement settings", "Every value on this page back to its default") then request("reset") end
            end)
        end)
    end)
end

-- ----------------------------------------------------------------------------
-- world drawing: the probes, while "Show probes" is on
-- ----------------------------------------------------------------------------
local COL_CLEAR = color.new(60, 220, 255, 220)
local COL_BLOCK = color.new(255, 60, 60, 240)
local PROBE_SHOW = 0.6 -- seconds a probe stays drawn

function Tune.render_world()
    if not C.show_rays then return end
    local t = core.time()
    for _, r in pairs(A.rays) do
        if t - r.t <= PROBE_SHOW then
            pcall(core.graphics.line_3d, vec3.new(r.ax, r.ay, r.az), vec3.new(r.bx, r.by, r.bz),
                r.clear and COL_CLEAR or COL_BLOCK, 2.0)
        end
    end
    for _, s in pairs(A.samples) do
        if t - s.t <= PROBE_SHOW then
            pcall(core.graphics.circle_3d, vec3.new(s.x, s.y, s.z + 0.1), 0.3,
                s.ok and COL_CLEAR or COL_BLOCK, 2.0)
        end
    end
end

return Tune
