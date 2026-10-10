-- ============================================================================
-- AmeisenNav
-- anav/ui.lua - menu page and in-world path drawing
-- ============================================================================
-- Version: 1.0.0
-- Author: BLIZZ
-- ============================================================================

---@type color
local color = require("common/color")
---@type vec3
local vec3 = require("common/geometry/vector_3")

local C = require("anav/config")
local L = require("anav/log")
local T = require("anav/transport")
local X = require("anav/context")
local FW = require("anav/follow")

local okH, plugin_helper = pcall(require, "common/utility/plugin_helper")
local okV, vec2 = pcall(require, "common/geometry/vector_2")

local U = {}

local fmt = string.format

-- Menu elements (ids are saved by the loader, so keep them stable).
local m = {
    tree          = core.menu.tree_node(),
    draw_path     = core.menu.checkbox(C.draw_path, "anav_draw_path"),
    debug_log     = core.menu.checkbox(C.debug_log, "anav_debug_log"),
    pause_cast    = core.menu.checkbox(C.pause_while_casting, "anav_pause_cast"),
    wp_threshold  = core.menu.slider_float(1.0, 5.0, C.waypoint_threshold, "anav_wp_threshold"),
    fin_threshold = core.menu.slider_float(0.5, 4.0, C.final_threshold, "anav_final_threshold"),
    stuck_window  = core.menu.slider_float(0.8, 4.0, C.stuck_window, "anav_stuck_window"),
    btn_target    = core.menu.button("anav_btn_target"),
    btn_stop      = core.menu.button("anav_btn_stop"),
    btn_ping      = core.menu.button("anav_btn_ping"),
    kb_minimap    = core.menu.keybind(999, false, "anav_kb_minimap"),   -- 1.6.6
    follow_mode   = core.menu.combobox(1, "anav_follow_mode"),
    follow_name   = core.menu.text_input("anav_follow_name", true),
    btn_fstart    = core.menu.button("anav_follow_start"),
    btn_fstop     = core.menu.button("anav_follow_stop"),
    btn_fpause    = core.menu.button("anav_follow_pause"),
    banner        = core.menu.checkbox(true, "anav_banner"),
    faction       = core.menu.combobox(1, "anav_faction"),
}

local FACTIONS = { "auto", "alliance", "horde", "none" }
local FOLLOW_LABELS = { "Target", "Focus (may be unavailable on Forever)", "Name" }
local FACTION_LABELS = { "Auto (race / faction id)", "Alliance", "Horde", "None (no faction avoidance)" }

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

-- ----------------------------------------------------------------------------
-- update side: everything that reads the game or the menu widgets
-- ----------------------------------------------------------------------------
-- core.register_on_render_menu_callback is documented as "solely for rendering
-- menus and variables", and warns against calling game functions inside it.
-- AmeisenNav 1.4.0 read the map, the player and the walker from render_status
-- while drawing the page, which took WoW Forever down as soon as the character
-- entered the world with the page open.
--
-- So the split is: this side runs in on_update and does every game read, the
-- render side below only draws numbers this side already cached. Reading the
-- widgets themselves in on_update is the documented pattern (see the combobox
-- example in the Menu docs).
local function sync_config()
    C.draw_path = get_bool(m.draw_path, C.draw_path)
    C.debug_log = get_bool(m.debug_log, C.debug_log)
    C.pause_while_casting = get_bool(m.pause_cast, C.pause_while_casting)
    C.waypoint_threshold = get_num(m.wp_threshold, C.waypoint_threshold)
    C.final_threshold = get_num(m.fin_threshold, C.final_threshold)
    C.stuck_window = get_num(m.stuck_window, C.stuck_window)
    C.banner = get_bool(m.banner, C.banner)
    local fi = get_num(m.faction, 1)
    if fi < 1 then fi = fi + 1 end -- tolerate a 0-based combobox
    C.faction = FACTIONS[fi] or "auto"
end

-- What the menu draws. Filled in on_update, read while rendering.
local snap = {
    map_id = nil, ui_map = nil, map_name = "?", filter = "?",
    state = "idle", index = 0, total = 0, driver = nil,
    fail_code = nil, fail_detail = nil, fail_recent = false,
    follow_who = nil, follow_dist = nil,
}

local MAP_EVERY = 0.5 -- map name and faction filter change rarely
local next_map = 0

local function refresh(client)
    local t = core.time()
    if t >= next_map then
        next_map = t + MAP_EVERY
        local _, ui_map, name = X.map_info()
        snap.ui_map, snap.map_name = ui_map, name
        snap.map_id = X.map_id()
        snap.filter = X.filter_state()
    end

    snap.state = client:get_full_state()
    local prog = client:get_progress()
    snap.index, snap.total = prog.current_index, prog.total_waypoints
    snap.driver = require("anav/follower").driver

    local lf = client:get_last_failure()
    snap.fail_recent = lf ~= nil and (t - lf.t) < 60
    if lf then snap.fail_code, snap.fail_detail = lf.code, lf.detail end

    snap.follow_who = FW.unit_name or (FW.unit and "unit") or nil
    snap.follow_dist = FW.distance
end

-- A menu button may not act on the click itself: acting means stopping the
-- walker or reading the target, which are game calls. The click is recorded
-- here and carried out by U.tick on the next update.
local pending = nil

local function request(action, arg)
    pending = { action = action, arg = arg }
end

local function run_request(client)
    local r = pending
    if not r then return end
    pending = nil
    local a = r.action
    if a == "test_target" then
        local t = X.target()
        local okp, pos = false, nil
        if t then okp, pos = X.call(t, "get_position") end
        if not X.player() then
            L.info("test: no player object (%s)", X.player_status())
        elseif okp and pos then
            client:move_to(pos, function(success, reason)
                if success then L.info("test: arrived at target")
                else L.info("test: failed - %s", tostring(reason)) end
            end)
        else
            L.info("test: no target selected")
        end
    elseif a == "minimap" then
        -- 1.6.6: the minimap point under the cursor (coords_helper)
        local okc, GZ = pcall(require, "anav/coords")
        local pos, why = nil, "no anav/coords"
        if okc and type(GZ) == "table" then pos, why = GZ.cursor_point() end
        if pos then
            L.info("test: walking to the minimap point %.0f, %.0f, %.0f", pos.x, pos.y, pos.z)
            client:move_to(pos, function(success, reason)
                if success then L.info("test: arrived at the minimap point")
                else L.info("test: failed - %s", tostring(reason)) end
            end)
        else
            L.info("test: no minimap point - %s", tostring(why))
        end
    elseif a == "stop" then
        client:stop()
    elseif a == "ping" then
        client:health_check(function(ok, info)
            L.info(ok and ("server OK: " .. tostring(info)) or "server did not answer")
        end)
    elseif a == "follow_start" then
        FW.start(r.arg.mode, r.arg.name)
    elseif a == "follow_stop" then
        FW.stop(client)
    elseif a == "follow_pause" then
        FW.toggle_pause(client)
    end
end

--- Call once per update tick, never from a render callback: copies the menu
--- values into the config, refreshes what the menu draws, and carries out
--- whatever a menu button asked for.
local kb_was = false
function U.tick(client)
    sync_config()
    refresh(client)
    -- 1.6.6: "walk to the minimap point" key, on the press (not while held)
    local okk, down = pcall(m.kb_minimap.get_state, m.kb_minimap)
    down = okk and down == true
    if down and not kb_was and not pending then request("minimap") end
    kb_was = down
    run_request(client)
end

-- ----------------------------------------------------------------------------
-- render side: menu elements only, no game calls
-- ----------------------------------------------------------------------------
-- A failing element must not blank the rest of the page, and each distinct
-- failure is logged once (the menu is drawn every frame).
local reported = {}
-- 1.6.7: the Sylvanas menu builds its elements over the first frames with a
-- per-frame budget (menu_api consume_build_unit); a section that does not
-- fit yet fails once and draws on the next frame. Not reported while the
-- menu is still being built.
local BUILD_FRAMES = 10
local rendered_frames = 0

local function section(name, fn)
    local ok, err = xpcall(fn, L.traceback)
    if not ok and rendered_frames <= BUILD_FRAMES then return end
    if not ok and not reported[name] then
        reported[name] = true
        L.error("menu section '%s' failed: %s", name, tostring(err))
    end
end

-- Menu elements must be created once, not every frame: the loader's menu
-- library has a limited build budget, and creating a header per line per
-- frame ran out of it ("consume_build_unit"). A fixed pool is reused, one
-- element per line position, reset at the start of every render pass.
local HEADER_POOL = 48
local header_pool = {}
for i = 1, HEADER_POOL do header_pool[i] = core.menu.header() end
local header_next = 1

local function header(text, col)
    local el = header_pool[header_next]
    if not el then return end -- more lines than the pool: drop the rest
    header_next = header_next + 1
    el:render(text, col or color.white(220))
end

local function render_status(version)
    header("AmeisenNav " .. version)

    local up = T.server_up
    if up == true then
        header(fmt("Server: connected   %s   %.0f ms", C.base_url, T.avg_latency * 1000), color.green(230))
    elseif up == false then
        header(fmt("Server: NOT RUNNING at %s", C.base_url), color.red(230))
        header("Start Ameisen\\Start-Ameisen.bat", color.orange(230))
    else
        header("Server: checking...", color.yellow(230))
    end

    header(fmt("Map %s (%s, ui map %s)   filter %s", tostring(snap.map_id), snap.map_name,
        tostring(snap.ui_map), snap.filter))

    if snap.total > 0 then
        header(fmt("State: %s   waypoint %d / %d", snap.state, snap.index, snap.total))
    else
        header("State: " .. snap.state)
    end
    if snap.driver then
        header("Movement driver: " .. snap.driver ..
            (snap.driver == "input" and " (built-in)" or " (simple_movement)"))
    end

    header("Log file: " .. tostring(L.file_status), color.gray(200))
    header("Server log: " .. tostring(L.server_status), color.gray(200))

    if snap.fail_recent then
        header(fmt("Last failure: %s - %s", tostring(snap.fail_code), tostring(snap.fail_detail)),
            color.orange(230))
    end
end

local function render_options()
    m.faction:render("Faction", FACTION_LABELS, "Which faction's towns paths avoid. Auto reads the player's race")
    m.draw_path:render("Draw path", "Draw the current path in the world")
    m.pause_cast:render("Pause while casting", "Stop walking while casting or channelling")
    m.debug_log:render("Debug log", "Print every request and state change to the console")
    m.wp_threshold:render("Waypoint reach (yd)", "Distance at which a corner counts as reached")
    m.fin_threshold:render("Arrival reach (yd)", "Distance at which the destination counts as reached")
    m.stuck_window:render("Stuck after (s)", "Seconds without progress before stuck recovery starts")
end

local function render_buttons()
    if m.btn_target:render("Test: walk to my target", "Pathfind to the current target and walk there") then
        request("test_target")
    end
    if m.btn_stop:render("Stop", "Stop the current navigation") then
        request("stop")
    end
    if m.btn_ping:render("Ping server", "Check the navigation server now") then
        request("ping")
    end
    m.kb_minimap:render("Test: walk to the minimap point",
        "Hover the minimap and press this key: pathfind to that spot (coords_helper) and walk there")
end

local function render_follow()
    m.follow_mode:render("Follow mode", FOLLOW_LABELS, "Who to follow: your target, your focus, or a unit by exact name")
    local mi = get_num(m.follow_mode, 1)
    if mi < 1 then mi = mi + 1 end
    local mode = FW.MODES[mi] or "target"
    if mode == "name" then
        m.follow_name:render("Name", "Exact name of the unit to follow")
    end
    if not FW.active then
        if m.btn_fstart:render("Start following", "Keep re-pathing to the unit as it moves") then
            local okt, text = pcall(m.follow_name.get_text, m.follow_name)
            request("follow_start", { mode = mode, name = okt and text or "" })
        end
    else
        if m.btn_fstop:render("Stop following", "Stop following") then
            request("follow_stop")
        end
        if m.btn_fpause:render(FW.paused and "Resume following" or "Pause following", "Hold still without losing the unit") then
            request("follow_pause")
        end
        local who = snap.follow_who or "searching..."
        local d = snap.follow_dist and fmt("%.0f yd", snap.follow_dist) or "?"
        header(fmt("%s: %s (%s)", FW.paused and "Paused" or "Following", tostring(who), d),
            FW.paused and color.yellow(230) or color.cyan(230))
    end
    m.banner:render("On-screen banner", "Show a status banner while navigating or following")
end

function U.render_menu(version)
    rendered_frames = rendered_frames + 1
    header_next = 1
    m.tree:render("AmeisenNav", function()
        section("status", function() render_status(version) end)
        section("options", render_options)
        section("buttons", render_buttons)
        section("follow", render_follow)
    end)
end

-- ----------------------------------------------------------------------------
-- world drawing
-- ----------------------------------------------------------------------------
-- Bright green and thick so the path is easy to see; walked segments and the
-- previous path stay green but dimmer.
local COL_PATH   = color.new(40, 255, 40, 255)
local COL_DONE   = color.new(40, 160, 40, 170)
local COL_DEST   = color.new(40, 255, 40, 255)
local COL_OLD    = color.new(40, 200, 40, 110)
local PATH_WIDTH = 6.0

local function v(p) return vec3.new(p.x, p.y, p.z + 0.2) end

function U.render_world(client)
    if not C.draw_path then return end
    local pts = client:get_current_path()
    local active = pts ~= nil
    if not pts then pts = client:get_last_path() end
    if not pts or #pts < 2 then return end
    -- snap.index is the walker's waypoint as of the last update tick; reading it
    -- from the walker here would be a game call inside a render callback
    local cur = active and snap.index or #pts + 1
    for i = 2, #pts do
        local col = not active and COL_OLD or (i < cur and COL_DONE) or COL_PATH
        pcall(core.graphics.line_3d, v(pts[i - 1]), v(pts[i]), col, PATH_WIDTH)
    end
    if active then
        local dest = client:get_destination()
        if dest then pcall(core.graphics.circle_3d, v(dest), 1.5, COL_DEST, PATH_WIDTH) end
    end
end

-- ----------------------------------------------------------------------------
-- on-screen banner (plugin_helper:draw_text_message, as in the Nav Follower example)
-- ----------------------------------------------------------------------------
local BANNER_FG_FOLLOW = color.new(100, 200, 255, 255)
local BANNER_FG_NAV    = color.new(40, 255, 40, 255)
local BANNER_FG_PAUSE  = color.new(255, 200, 0, 255)
local BANNER_BG        = color.new(0, 0, 0, 150)

function U.render_banner(client)
    if not C.banner or not okH or not okV then return end
    local text, fg
    if FW.active then
        local who = snap.follow_who or "searching..."
        local d = snap.follow_dist and fmt("%.0f yd", snap.follow_dist) or "?"
        text = (FW.paused and "FOLLOW: PAUSED" or ("FOLLOWING: " .. tostring(who))) .. " \n" .. d
        fg = FW.paused and BANNER_FG_PAUSE or BANNER_FG_FOLLOW
    elseif client:is_busy() then
        -- cached on the update tick: asking the walker for its index is a game
        -- call, and a render callback is not the place for one
        text = fmt("AMEISENNAV: %s \nwaypoint %d/%d", snap.state:upper(), snap.index, snap.total)
        fg = BANNER_FG_NAV
    else
        return
    end
    local okS, scr = X.call_fn("core.graphics.get_screen_size", core.graphics.get_screen_size)
    if not okS or not scr then return end
    local okW, tw = X.call_fn("core.graphics.get_text_width", core.graphics.get_text_width, text, 9, 3)
    tw = okW and type(tw) == "number" and tw or 100
    X.call(plugin_helper, "draw_text_message", text, fg, BANNER_BG,
        vec2.new(scr.x * 0.5 - tw, scr.y * 0.25), vec2.new(200, 36),
        false, true, "anav_banner", nil, true, 3)
end

return U
