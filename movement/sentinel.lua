-- ============================================================================
-- restedXP_questing
-- Movement — Sentinel Navigation adapter (4.1.0)
-- ============================================================================
-- Version: 4.15.0
-- Authors: BLIZZ - Anthonyk
-- Folder: restedXP_questing
-- ============================================================================
-- The ONE module that talks to Sentinel Navigation (_G.SentinelNavClient, a
-- Sylvanas library; the player installs and enables it, Master Farmer 2.15.0
-- points its shared client at the Master Farmer SentinelNavServer and this
-- client's map set). A library update is fixed here and nowhere else.
--
--   * the client is looked up lazily at run time, never in header.lua:
--     rawget(_G, "SentinelNavClient"), then its `client` (a live getter, may
--     be nil);
--   * the game / server come from the launcher (MASTER_FARMER.nav: kind
--     "sentinel", game "tbc" | "forever" | nil, base_url, supported) - this
--     product never writes the server address;
--   * on a client without maps there (Classic, Retail, ...) navigation is
--     unavailable: S.unavailable() says why, and nothing moves.
--
-- 4.1.0 STEP 1 - SELF-TEST. The installed library ships as an encrypted
-- package (scripts\ext_lib_sentinel_nav, "LUA1"), so its behaviour cannot be
-- read; it reports itself as v0.24 in game. Before the movement layer is
-- ported, the self-test (Settings tab, bot stopped, standing in the open)
-- runs the documented v0.0.8 consumer calls once and writes what they really
-- answer - callback arguments, a second move_to while moving, stop(), the
-- height payloads, the EventBus payloads - to
--     scripts_data/<MASTER_FARMER.data_dir>/sentinel_selftest.txt
-- It walks the character up to 30 yd away and back (4.1.3: an 8 yd walk
-- arrived in 0.7 s, before the second move_to / stop() could be tried).
-- SAFE TIMING (the crash pattern of 2.181.0 / 3.7.1, v0.23 era: stopping a
-- leg still awaiting its path, or under ~1.6 s old, came right before game
-- crashes): the second move_to and the stop() wait until the walk is
-- following its path AND at least SAFE_LEG s old; a walk that never gets
-- there within SAFE_WAIT s is recorded and that step is skipped, never forced.
-- ============================================================================

local S = {}

local FILE_NAME = "sentinel_selftest.txt"
local SAFE_LEG = 1.6           -- s: a leg younger than this is never stopped / replaced
local SAFE_WAIT = 8.0          -- s: then the step is skipped
local DEFAULT_DIR = "restedxp_questing"

-- the documented v0.0.8 EventBus names (CLAUDE_PROMPT_RESTEDXP_SENTINEL.md 4)
S.EVENTS = {
    "nav.state_changed", "nav.arrived", "nav.failed", "nav.stuck_detected", "nav.stuck_recovered",
    "nav.deviation_detected", "nav.repath_started", "nav.repath_completed", "nav.obstacle_detected",
    "nav.path_requested", "nav.path_received", "nav.path_failed", "nav.waypoint_reached",
    "nav.server_connected", "nav.server_retry", "nav.server_disconnected", "nav.server_error",
}

-- ----------------------------------------------------------------------------
-- the library and the launcher's word on it
-- ----------------------------------------------------------------------------
---_G.SentinelNavClient (or nil).
function S.library()
    local g = rawget(_G, "SentinelNavClient")
    return type(g) == "table" and g or nil
end

---The shared client (or nil): looked up every time - the library may reload.
function S.client()
    local g = S.library()
    if not g then return nil end
    local ok, c = pcall(function() return g.client end)
    if ok and type(c) == "table" then return c end
    return nil
end

---The library's VERSION string ("" when unknown).
function S.version()
    local g = S.library()
    local ok, v = pcall(function() return g and g.VERSION end)
    return (ok and v ~= nil) and tostring(v) or ""
end

---The launcher's MASTER_FARMER table, or nil. 4.1.3: it lives in this
---product's environment (mfcore/loader.lua env.MASTER_FARMER), NOT in the
---real _G - rawget(_G, ...) never saw it (the 4.1.2 self-test read kind "none").
function S.master_farmer()
    local mf = MASTER_FARMER
    return type(mf) == "table" and mf or nil
end

---MASTER_FARMER.nav from the launcher, or a table saying it is missing.
function S.info()
    local mf = S.master_farmer()
    local n = type(mf) == "table" and mf.nav or nil
    if type(n) == "table" and n.kind == "sentinel" then return n end
    return { kind = "none", game = nil, supported = false }
end

---Why Sentinel navigation cannot be used now, or nil when it can.
function S.unavailable()
    local n = S.info()
    if n.kind ~= "sentinel" then return "not loaded through Master Farmer's Sentinel entry" end
    if not n.supported then return "Sentinel navigation has no maps for this game version" end
    local c = S.client()
    if not c then return "the Sentinel Navigation library is not loaded" end
    local ok, up = pcall(function() return c:is_server_available() end)
    if not ok or up ~= true then return "the navigation server is not answering" end
    return nil
end

-- ----------------------------------------------------------------------------
-- 4.2.0 RUNTIME CALLS - the only Sentinel calls the bot makes. Arguments and
-- answers as documented (docs/SENTINEL_API.md, the official v0.0.8 page) and
-- as recorded on v0.24 (docs/SENTINEL_V024.md). Every call is pcall-guarded;
-- callbacks are wrapped so the bot sees one fixed shape.
-- ----------------------------------------------------------------------------
local function m(c, name, ...)
    local f = c and c[name]
    if type(f) ~= "function" then return false end
    return pcall(f, c, ...)
end

local function pt(p)
    return { x = p.x, y = p.y, z = p.z }
end

---move_to: cb(success, reason) - reason "unreachable" | "server_timeout" |
---"max_stuck_exceeded" | "max_repath_exceeded" (doc). A walk replaced by a
---newer move_to, or stopped, gets NO callback (recorded on v0.24). A second
---move_to while walking re-plans without stopping (0.12 s, recorded).
function S.move_to(c, p, cb)
    local ok = m(c, "move_to", pt(p), function(success, reason)
        if cb then pcall(cb, success == true, reason ~= nil and tostring(reason) or nil) end
    end)
    return ok == true
end

---follow_path: precomputed waypoints in order; cb(success, reason) (doc).
function S.follow_path(c, points, cb)
    local list = {}
    for i = 1, #points do list[i] = pt(points[i]) end
    local ok = m(c, "follow_path", list, function(success, reason)
        if cb then pcall(cb, success == true, reason ~= nil and tostring(reason) or nil) end
    end)
    return ok == true
end

---stop(): stops all movement (doc); no callback for the stopped walk (v0.24).
function S.stop(c) return m(c, "stop") == true end

---is_moving(): true only while the top-level state is navigating (doc).
function S.moving(c)
    local ok, v = m(c, "is_moving")
    return ok and v == true
end

---get_state(): "idle" | "navigating" | "arrived" | "failed" (doc), or nil.
function S.state(c)
    local ok, v = m(c, "get_state")
    return ok and type(v) == "string" and v or nil
end

---get_full_state(): dotted ("navigating.awaiting_path", ...) or nil.
function S.full_state(c)
    local ok, v = m(c, "get_full_state")
    return ok and type(v) == "string" and v or nil
end

---The walk is still waiting for (or re-requesting) its path.
function S.path_pending(c)
    local f = S.full_state(c) or ""
    return f:find("awaiting_path", 1, true) ~= nil or f:find("repathing", 1, true) ~= nil
end

function S.server_up(c)
    local ok, v = m(c, "is_server_available")
    return ok and v == true
end

---get_current_path() -> vec3[] | nil, get_path_index() -> number (doc).
function S.current_path(c)
    local ok, v = m(c, "get_current_path")
    return (ok and type(v) == "table") and v or nil
end
function S.path_index(c)
    local ok, v = m(c, "get_path_index")
    return (ok and type(v) == "number") and v or nil
end

---Every navmesh floor at (x, y): cb(list of heights, nearest `p.z` first).
---v0.24 answers (true, { count, heights = { { height, flags }, ... } }, nil).
---False when the query could not be sent (cb is not called then).
function S.floors(c, p, cb)
    local done = false
    local ok = m(c, "get_all_heights", pt(p), function(okh, data)
        if done then return end
        done = true
        local out = {}
        local hs = (okh == true and type(data) == "table") and data.heights or nil
        for i = 1, #(type(hs) == "table" and hs or {}) do
            local h = hs[i]
            local v = type(h) == "table" and tonumber(h.height) or tonumber(h)
            if v and v == v and math.abs(v) < 20000 then out[#out + 1] = v end
        end
        local z = tonumber(p.z) or 0
        table.sort(out, function(a, b) return math.abs(a - z) < math.abs(b - z) end)
        pcall(cb, out)
    end)
    return ok == true
end

---validate_destination: cb(reachable, reason, distance) (doc, recorded).
function S.validate(c, p, cb)
    local ok = m(c, "validate_destination", pt(p), function(reachable, reason, distance)
        pcall(cb, reachable == true, reason, distance)
    end)
    return ok == true
end

---plan_route: cb(success, data) - data.visit_order on success (doc).
function S.plan_route(c, nodes, cb)
    local ok = m(c, "plan_route", nodes, function(success, data) pcall(cb, success == true, data) end)
    return ok == true
end

---One path query, no movement (advanced: client.nav_client:find_path).
---v0.24 answers (true, { waypoints, distance, partial, computation_time_ms }, nil).
---cb(points or nil, ok, info) where info.partial says the path stops short.
function S.find_path(c, a, b, cb)
    local okn, nc = pcall(function() return c.nav_client end)
    if not okn or type(nc) ~= "table" or type(nc.find_path) ~= "function" then return false end
    local ok = pcall(nc.find_path, nc, pt(a), pt(b), function(okp, data)
        local pts = (type(data) == "table" and type(data.waypoints) == "table") and data.waypoints or nil
        local info = { partial = type(data) == "table" and data.partial == true or false }
        pcall(cb, (pts and #pts >= 2) and pts or nil, okp == true, info)
    end)
    return ok == true
end

-- ----------------------------------------------------------------------------
-- 4.8.0: OBSTACLES AHEAD, SOFT RE-PATH, NAVMESH RAYCAST (user: "use Sentinel
-- navigation API to find trace line and / or raycast hits to re-path the
-- player around these objects ... regenerate pathing ahead of the player
-- without stalling"). Signatures read from the readable v0.0.6 library
-- source (C:\SentinelNav\SentinelCore\SentinelNavClient); not yet recorded on
-- v0.24, so every call is pcall'd and a missing one answers nil / false:
--   client.obstacle:probe_path_ahead(waypoints, max_segments) -> hit {x,y,z}|nil, segment
--       3 game trace lines per segment (core.graphics.trace_line, doodad
--       collision), run by Sentinel's own ObstacleService
--   client.obstacle:add_zone(pos, radius)  an avoidance zone (FIFO, TTL in the
--       Sentinel UI); every path request after it avoids it (path-avoid)
--   client:replan(reason, { soft = true }) a new path from here without
--       stopping (SoftRepath: no movement:stop)
--   client.nav_client:raycast(a, b, cb(ok, { hit, t }))  the SERVER's navmesh
--       raycast (no game call): hit = the straight line leaves the walkable mesh
-- ----------------------------------------------------------------------------
function S.probe_ahead(c, points, n)
    local oko, ob = pcall(function() return c.obstacle end)
    if not oko or type(ob) ~= "table" or type(ob.probe_path_ahead) ~= "function" then return nil end
    local list = {}
    for i = 1, #points do list[i] = pt(points[i]) end
    local ok, hit, seg = pcall(ob.probe_path_ahead, ob, list, n)
    if ok and type(hit) == "table" and type(hit.x) == "number" then return hit, seg end
    return nil
end

function S.add_zone(c, p, radius)
    local oko, ob = pcall(function() return c.obstacle end)
    if not oko or type(ob) ~= "table" or type(ob.add_zone) ~= "function" then return false end
    return pcall(ob.add_zone, ob, pt(p), radius) == true
end

function S.soft_replan(c, reason)
    local ok, r = pcall(function() return c:replan(reason, { soft = true }) end)
    return ok and r == true
end

function S.raycast(c, a, b, cb)
    local okn, nc = pcall(function() return c.nav_client end)
    if not okn or type(nc) ~= "table" or type(nc.raycast) ~= "function" then return false end
    local ok = pcall(nc.raycast, nc, pt(a), pt(b), function(okr, data)
        local hit = type(data) == "table" and data.hit == true or false
        local t = type(data) == "table" and tonumber(data.t) or nil
        pcall(cb, okr == true, hit, t)
    end)
    return ok == true
end

-- ----------------------------------------------------------------------------
-- self-test: recording
-- ----------------------------------------------------------------------------
local T = { active = false, lines = {}, step = 0, t0 = 0, wait_until = 0, note = nil }

local function now()
    local ok, t = pcall(core.time)
    return (ok and type(t) == "number") and t or 0
end

---A value as text: type, and for a table its keys (and the size of a list).
local function describe(v, depth)
    depth = depth or 0
    local tv = type(v)
    if tv == "string" then return string.format("%q", v:sub(1, 80)) end
    if tv == "number" or tv == "boolean" or tv == "nil" then return tostring(v) end
    if tv ~= "table" then return "<" .. tv .. ">" end
    local okx, x = pcall(function() return v.x end)
    local oky, y = pcall(function() return v.y end)
    local okz, z = pcall(function() return v.z end)
    if okx and oky and okz and type(x) == "number" and type(y) == "number" and type(z) == "number" then
        return string.format("(%.1f, %.1f, %.1f)", x, y, z)
    end
    local n, parts = #v, {}
    if n > 0 then parts[#parts + 1] = "list " .. n .. (n > 0 and (" first " .. describe(v[1], depth + 1)) or "") end
    local keys = {}
    pcall(function() for k in pairs(v) do if type(k) ~= "number" then keys[#keys + 1] = tostring(k) end end end)
    table.sort(keys)
    for i = 1, math.min(#keys, 14) do
        local k = keys[i]
        local okv, val = pcall(function() return v[k] end)
        parts[#parts + 1] = k .. "=" .. ((depth < 1 and okv) and describe(val, depth + 1) or ("<" .. type(val) .. ">"))
    end
    if #keys > 14 then parts[#parts + 1] = "+" .. (#keys - 14) .. " keys" end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function rec(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    T.lines[#T.lines + 1] = string.format("t=%6.2f  %s", now() - T.t0, ok and s or tostring(fmt))
end

---Every argument of a callback, in order.
local function args_text(...)
    local n = select("#", ...)
    local out = {}
    for i = 1, n do out[i] = "#" .. i .. " " .. describe((select(i, ...))) end
    return n .. " arg(s): " .. table.concat(out, " | ")
end

local function cb_recorder(label)
    return function(...) rec("%s callback -> %s", label, args_text(...)) end
end

local function data_path()
    local mf = S.master_farmer()
    local dir = (type(mf) == "table" and type(mf.data_dir) == "string") and mf.data_dir or DEFAULT_DIR
    return dir, dir .. "/" .. FILE_NAME
end

local function flush()
    local dir, path = data_path()
    pcall(core.create_data_folder, dir)
    if not pcall(core.create_data_file, path) then return nil end          -- empties the file
    pcall(core.write_data_file, path, table.concat(T.lines, "\n") .. "\n")  -- appends
    return path
end

local function me()
    local ok, p = pcall(core.object_manager.get_local_player)
    if ok and p then return p end
    return nil
end

local function here()
    local p = me()
    local ok, pos = pcall(function() return p and p:get_position() end)
    if ok and type(pos) == "table" then return { x = pos.x, y = pos.y, z = pos.z } end
    return nil
end

---(x, y, z) `yd` ahead of the player at `deg` degrees off its facing.
local function ahead(yd, deg)
    local p, pos = me(), here()
    if not p or not pos then return nil end
    local ok, r = pcall(function() return p:get_rotation() end)
    local a = ((ok and type(r) == "number") and r or 0) + math.rad(deg or 0)
    return { x = pos.x + math.cos(a) * yd, y = pos.y + math.sin(a) * yd, z = pos.z }
end

local function state_text(c)
    local okf, full = pcall(function() return c:get_full_state() end)
    local okm, moving = pcall(function() return c:is_moving() end)
    return string.format("full_state=%s is_moving=%s", okf and describe(full) or "<error>", okm and tostring(moving) or "<error>")
end

-- ----------------------------------------------------------------------------
-- self-test: the steps (one per update tick, each may wait)
-- ----------------------------------------------------------------------------
---The walk started at `since` may be stopped / replaced now: following its
---path (not awaiting / repathing) and SAFE_LEG s old.
local function safe_to_touch(c, since)
    if now() - since < SAFE_LEG then return false end
    local ok, full = pcall(function() return c:get_full_state() end)
    full = ok and tostring(full) or ""
    return full:find("following_path", 1, true) ~= nil
end

---The walk is still navigating (any navigating.* sub-state).
local function navigating(c)
    local ok, full = pcall(function() return c:get_full_state() end)
    return ok and tostring(full):find("navigating", 1, true) == 1
end

local OWNER = {}
local bus = nil

local function sub_events(c)
    local okb, b = pcall(function() return c:get_event_bus() end)
    rec("get_event_bus() -> %s", okb and describe(b) or ("error " .. tostring(b)))
    if not okb or type(b) ~= "table" then return end
    bus = b
    for _, name in ipairs(S.EVENTS) do
        local ok, id = pcall(function()
            return b:on(name, function(...) rec("event %s -> %s", name, args_text(...)) end, { owner = OWNER })
        end)
        if not ok then rec("bus:on(%s) error %s", name, tostring(id)) end
    end
    rec("subscribed %d event names with { owner = <table> }", #S.EVENTS)
end

local function unsub_events()
    if bus then
        local ok, err = pcall(function() return bus:off_owner(OWNER) end)
        rec("bus:off_owner(owner) -> %s", ok and "ok" or ("error " .. tostring(err)))
        bus = nil
    end
end

local A, B, C = nil, nil, nil
local steps = {
    -- 1. what is there
    function(c)
        rec("library VERSION=%s  MASTER_FARMER.nav=%s", S.version(), describe(S.info()))
        local names = { "move_to", "move_direct", "follow_path", "plan_route", "start_route", "validate_destination",
            "replan", "stop", "get_state", "get_full_state", "is_moving", "get_destination", "get_current_path",
            "get_path_index", "get_progress", "get_corridor_widths", "is_server_available", "health_check",
            "get_height", "get_player_height", "get_all_heights", "get_player_all_heights", "on", "off",
            "get_event_bus", "update_config", "pause", "resume", "is_busy", "get_last_failure" }
        local have, miss = {}, {}
        for _, n in ipairs(names) do
            local ok, f = pcall(function() return c[n] end)
            if ok and type(f) == "function" then have[#have + 1] = n else miss[#miss + 1] = n end
        end
        rec("client functions present: %s", table.concat(have, " "))
        rec("client functions MISSING: %s", #miss > 0 and table.concat(miss, " ") or "(none)")
        local okn, nc = pcall(function() return c.nav_client end)
        if okn and type(nc) == "table" then
            local adv, amiss = {}, {}
            for _, n in ipairs({ "find_path", "find_route_multi", "find_route_tsp", "check_path", "find_path_avoid",
                "raycast", "get_height", "get_all_heights", "random_point", "flee", "kite", "is_available" }) do
                local ok, f = pcall(function() return nc[n] end)
                if ok and type(f) == "function" then adv[#adv + 1] = n else amiss[#amiss + 1] = n end
            end
            rec("nav_client present: %s | MISSING: %s", table.concat(adv, " "), #amiss > 0 and table.concat(amiss, " ") or "(none)")
        else
            rec("client.nav_client: %s", okn and type(nc) or "error")
        end
        local oku, up = pcall(function() return c:is_server_available() end)
        rec("is_server_available() -> %s  %s", oku and tostring(up) or "error", state_text(c))
        sub_events(c)
        return 0.5
    end,
    -- 2. queries
    function(c)
        local pos = here()
        rec("player at %s", describe(pos))
        pcall(function() c:health_check(cb_recorder("health_check")) end)
        pcall(function() c:get_player_height(cb_recorder("get_player_height")) end)
        pcall(function() c:get_height(pos, cb_recorder("get_height(player pos)")) end)
        pcall(function() c:get_all_heights(pos, cb_recorder("get_all_heights(player pos)")) end)
        A = ahead(8, 0)
        pcall(function() c:validate_destination(A, cb_recorder("validate_destination(8 yd ahead)")) end)
        local okn, nc = pcall(function() return c.nav_client end)
        if okn and type(nc) == "table" and type(nc.find_path) == "function" then
            pcall(function() nc:find_path(pos, A, cb_recorder("nav_client:find_path(8 yd ahead)")) end)
        end
        return 3.0
    end,
    -- 3. move_to A, then a second move_to (B) while it walks
    function(c)
        A = ahead(30, 0)
        rec("move_to A %s  (30 yd ahead)", describe(A))
        local ok, r = pcall(function() return c:move_to(A, cb_recorder("move_to A")) end)
        rec("move_to A returned %s  %s", ok and describe(r) or ("error " .. tostring(r)), state_text(c))
        T.leg_t = now()
        T.watch = { until_t = now() + SAFE_WAIT, label = "after move_to A" }
        return 0
    end,
    function(c)
        if not safe_to_touch(c, T.leg_t) then
            if not navigating(c) then
                rec("second move_to NOT tried: walk A ended after %.1f s, before it was %.1f s old (%s)",
                    now() - T.leg_t, SAFE_LEG, state_text(c))
                return 0
            end
            if now() - T.leg_t < SAFE_WAIT then return false end
            rec("SKIPPED second move_to: walk A never reached following_path (%s) - no more moves are sent", state_text(c))
            T.no_moves = true
            return 0
        end
        B = ahead(25, 45)
        rec("SECOND move_to B %s while moving (%s)", describe(B), state_text(c))
        local ok, r = pcall(function() return c:move_to(B, cb_recorder("move_to B")) end)
        rec("move_to B returned %s  %s", ok and describe(r) or ("error " .. tostring(r)), state_text(c))
        T.watch = { until_t = now() + 6, label = "after move_to B" }
        return 6.0
    end,
    -- 4. move_to C, then stop() while it walks
    function(c)
        if T.no_moves then rec("SKIPPED move_to C (a walk is still waiting for its path)") return 0 end
        C = ahead(30, 180)
        rec("move_to C %s (30 yd back), stop() once it follows its path and is %.1f s old", describe(C), SAFE_LEG)
        pcall(function() c:move_to(C, cb_recorder("move_to C")) end)
        T.leg_t = now()
        T.watch = { until_t = now() + SAFE_WAIT, label = "after move_to C" }
        return 0
    end,
    function(c)
        if T.no_moves then return 0 end
        if not safe_to_touch(c, T.leg_t) then
            if not navigating(c) then
                rec("stop() NOT tried: walk C ended after %.1f s, before it was %.1f s old (%s)",
                    now() - T.leg_t, SAFE_LEG, state_text(c))
                return 0
            end
            if now() - T.leg_t < SAFE_WAIT then return false end
            rec("SKIPPED stop(): walk C never reached following_path (%s) - no more moves are sent", state_text(c))
            T.no_moves = true
            return 0
        end
        local ok, r = pcall(function() return c:stop() end)
        rec("stop() returned %s  %s", ok and describe(r) or ("error " .. tostring(r)), state_text(c))
        T.watch = { until_t = now() + 2, label = "after stop" }
        return 2.0
    end,
    -- 5. an unreachable target (150 yd up in the air): the failure reason
    function(c)
        if T.no_moves then rec("SKIPPED move_to U (a walk is still waiting for its path)") return 0 end
        local p = here()
        local U = p and { x = p.x + 30, y = p.y, z = p.z + 150 } or nil
        rec("move_to U %s (30 yd away, 150 yd up)", describe(U))
        pcall(function() c:move_to(U, cb_recorder("move_to U (unreachable)")) end)
        T.leg_t = now()
        T.watch = { until_t = now() + 6, label = "after move_to U" }
        return 6.0
    end,
    function(c)
        -- the last walk: stopped only once it is safe; a path still pending
        -- (or never coming) is left to end on its own - never stopped
        local okf, fs = pcall(function() return c:get_full_state() end)
        fs = okf and tostring(fs) or ""
        local pending = fs:find("awaiting_path", 1, true) or fs:find("repathing", 1, true)
        if T.no_moves or pending then
            if not T.no_moves and now() - (T.leg_t or 0) < SAFE_WAIT then return false end
            rec("final: NOT stopped (%s) - left to end on its own", state_text(c))
        else
            if now() - (T.leg_t or 0) < SAFE_LEG then return false end
            pcall(function() c:stop() end)
            rec("final stop  %s", state_text(c))
        end
        unsub_events()
        return 0
    end,
}

---Start the self-test (from the update tick). Refused while the bot runs.
function S.selftest_request()
    T.requested = true
end

function S.selftest_running() return T.active end
function S.selftest_note() return T.note end

---One update tick. True while the self-test owns the frame.
function S.selftest_tick(bot_started)
    if T.requested and not T.active then
        T.requested = false
        if bot_started then
            T.note = "Sentinel self-test: stop the bot first"
            pcall(core.log, "[restedXP_questing] " .. T.note)
            return false
        end
        local c = S.client()
        if not c then
            T.note = "Sentinel self-test: the Sentinel Navigation library is not loaded"
            pcall(core.log, "[restedXP_questing] " .. T.note)
            return false
        end
        T.active, T.lines, T.step, T.t0, T.wait_until, T.watch, T.shown = true, {}, 0, now(), 0, nil, nil
        T.no_moves, T.leg_t = false, nil
        T.note = "Sentinel self-test running - do not move"
        rec("restedXP_questing Sentinel self-test")
        -- 4.1.1: announced, and the file is saved after every step (a run cut
        -- short still leaves what it recorded)
        local _, path = data_path()
        pcall(core.log, string.format("[restedXP_questing] Sentinel self-test started (%d steps, about 40 s) - do not move; "
            .. "results: scripts_data/%s", #steps, path))
        flush()
    end
    if not T.active then return false end
    local c = S.client()
    if not c then
        rec("ABORTED: the client went away")
        T.step = #steps
    end
    local t = now()
    if T.watch and t <= T.watch.until_t then
        local s = c and state_text(c) or "?"
        if s ~= T.watch.last then
            T.watch.last = s
            rec("  %s: %s", T.watch.label, s)
        end
    end
    if t < T.wait_until then return true end
    T.step = T.step + 1
    if T.step > #steps then
        T.active = false
        local path = flush()
        T.note = "Sentinel self-test done - " .. (path and ("scripts_data/" .. path) or "could not write the file")
        pcall(core.log, "[restedXP_questing] " .. T.note)
        return false
    end
    local first = T.shown ~= T.step
    if first then
        T.shown = T.step
        pcall(core.log, string.format("[restedXP_questing] Sentinel self-test step %d/%d", T.step, #steps))
    end
    local ok, wait = pcall(steps[T.step], c)
    if not ok then rec("step %d error: %s", T.step, tostring(wait)) wait = 0 end
    if wait == false then
        T.step = T.step - 1                    -- not yet: the same step next tick
        return true
    end
    flush()
    T.wait_until = t + (tonumber(wait) or 0)
    return true
end

---Unload: the self-test's listeners go, and a running test stops its walk.
function S.on_unload()
    if T.active then
        local c = S.client()
        if c then pcall(function() c:stop() end) end
        T.active = false
    end
    unsub_events()
end

-- KITE (nav_client:kite, present on v0.24 with 5 args - MF API Dump
-- 2026-10-24; its answer read from the readable v0.0.6 source, the same
-- (true, { waypoints, ... }, nil) shape as find_path, which v0.24 confirmed):
--   kite(player_pos, target_pos, cb(ok, { waypoints, waypoint_count }, err), { kite_radius })
-- cb(points | nil, ok, info): info.shape_bad = an answer of another shape
-- (the caller switches kiting off), info.error = the library's error text.
function S.kite(c, from, target, radius, cb)
    local okn, nc = pcall(function() return c.nav_client end)
    if not okn or type(nc) ~= "table" or type(nc.kite) ~= "function" then return false end
    local ok = pcall(nc.kite, nc, pt(from), pt(target), function(okp, data, err)
        local pts = (type(data) == "table" and type(data.waypoints) == "table") and data.waypoints or nil
        local info = { error = err ~= nil and tostring(err) or nil,
            shape_bad = okp == true and pts == nil, got = type(data) }
        pcall(cb, (pts and #pts >= 1) and pts or nil, okp == true, info)
    end, { kite_radius = radius })
    return ok == true
end


-- 4.14.0 FLEE (nav_client:flee, present on v0.24 - MF API Dump 2026-10-24;
-- argument order from the official page: flee(player_pos, threats, cb, opts)):
--   flee(player_pos, { threat_pos, ... }, cb(ok, { waypoints, ... }, err), { flee_distance })
-- The answer is expected in find_path's shape and checked live like kite's:
-- cb(points | nil, ok, info) - info.shape_bad = another shape (the caller
-- switches fleeing off), info.error = the library's error text.
function S.flee(c, from, threats, distance, cb)
    local okn, nc = pcall(function() return c.nav_client end)
    if not okn or type(nc) ~= "table" or type(nc.flee) ~= "function" then return false end
    local list = {}
    for i = 1, #threats do list[i] = pt(threats[i]) end
    local ok = pcall(nc.flee, nc, pt(from), list, function(okp, data, err)
        local pts = (type(data) == "table" and type(data.waypoints) == "table") and data.waypoints or nil
        local info = { error = err ~= nil and tostring(err) or nil,
            shape_bad = okp == true and pts == nil, got = type(data) }
        pcall(cb, (pts and #pts >= 1) and pts or nil, okp == true, info)
    end, { flee_distance = distance })
    return ok == true
end

-- 4.14.0 LIVE STATUS for the GUI and the route progress (improvements 5 and
-- 11 of the API-dump review). Shapes recorded on v0.24 by the MF Start Dump:
--   get_progress()        { current_index, percent, total_waypoints, waypoints_remaining }
--   get_route_progress()  nothing while no recorded route runs (its shape when
--                         one runs is not recorded: a number or a table with
--                         percent / index / total is read, anything else ignored)
--   get_destination()     vec3 | nothing
--   obstacle:get_zone_count()             number
--   nav_client:get_consecutive_failures() number
-- Read on the update tick only (never on the render path).
local function num(v) v = tonumber(v) if v and v == v then return v end return nil end
function S.progress(c)
    local ok, v = m(c, "get_progress")
    if not ok or type(v) ~= "table" then return nil end
    return { index = num(v.current_index), percent = num(v.percent),
        total = num(v.total_waypoints), left = num(v.waypoints_remaining) }
end
function S.route_progress(c)
    local ok, v = m(c, "get_route_progress")
    if not ok then return nil end
    if type(v) == "number" then return { percent = (v <= 1 and v * 100) or v } end
    if type(v) ~= "table" then return nil end
    local pc = num(v.percent)
    local fr = num(v.progress)
    if not pc and fr then pc = (fr <= 1 and fr * 100) or fr end
    local i = num(v.current_index) or num(v.index) or num(v.current)
    local n = num(v.total) or num(v.total_waypoints) or num(v.count)
    if not pc and i and n and n > 0 then pc = i / n * 100 end
    if not pc then return nil end
    return { percent = pc, index = i, total = n }
end
function S.destination(c)
    local ok, v = m(c, "get_destination")
    if ok and type(v) == "table" and type(v.x) == "number" then return v end
    return nil
end
function S.zone_count(c)
    local oko, ob = pcall(function() return c.obstacle end)
    if not oko or type(ob) ~= "table" or type(ob.get_zone_count) ~= "function" then return nil end
    local ok, v = pcall(ob.get_zone_count, ob)
    return ok and num(v) or nil
end
function S.failures(c)
    local okn, nc = pcall(function() return c.nav_client end)
    if not okn or type(nc) ~= "table" or type(nc.get_consecutive_failures) ~= "function" then return nil end
    local ok, v = pcall(nc.get_consecutive_failures, nc)
    return ok and num(v) or nil
end

return S
