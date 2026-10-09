-- ============================================================================
-- Master Farmer - Grindbot
-- movement/sentinel.lua - actuator: AMEISEN navmesh travel (out of combat)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.244.0
-- ============================================================================
-- Optional. Used for long legs, blocked straight lines and stuck recovery.
-- When the client is absent every caller silently degrades to walker steering,
-- so nothing in the plugin may treat the nav client as required.
--
-- MASTER FARMER BOT - AMEISEN (2.235.0-ameisen)
--   The filename and the N.* facade are Sentinel's; the client is
--   _G.AmeisenNav.client (scripts\AmeisenNav, server Ameisen\Start-Ameisen.bat).
--   Only calls in AmeisenNav/docs/API.md and anav/client.lua are used:
--   move_to, move_direct, follow_path, replan, stop, is_moving, is_busy,
--   get_state, get_full_state, get_current_path, get_path_index,
--   get_progress, get_destination, is_server_available, health_check, on,
--   validate_destination, find_path, raycast, random_point, kite, flee,
--   plan_route. Sentinel's nav_client / event bus / obstacle service /
--   find_path_avoid / check_path / corridor queries do not exist here:
--   avoid plans are built locally from find_path (avoid_plan), the rest is
--   feature-detected away. Comments below that describe Sentinel bugs are
--   history from the parent project.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

local K = require("movement/const")
local R = require("movement/rt")
local U = require("movement/util")
local W = require("movement/walker")

local OWNER             = K.OWNER
local SN_NEED           = K.SN_NEED
local INFLIGHT_TIMEOUT  = K.INFLIGHT_TIMEOUT
local SN_MIN_GAP        = K.SN_MIN_GAP

local pt, to_vec3 = R.pt, R.to_vec3
local xyz, dlog = U.xyz, U.dlog
local travel_near, here_xyz, dist2, walk_open = U.travel_near, U.here_xyz, U.dist2, U.walk_open

local P_DEST = R.P_DEST

local N = {}

-- PATH SMOOTHING (2.235.3-ameisen). AmeisenNavigation's PATH request takes
-- PathRequestFlags (github.com/L333T/AmeisenNavigation, Server/src/Protocol.hpp
-- and Main.hpp HandlePathFlagsAndSendData): SMOOTH_CHAIKIN = 1 rounds every
-- corner of the Detour straight path, VALIDATE_MAS = 16 then slides each
-- smoothed point along the navmesh (moveAlongSurface, <= 25 yd steps) so none
-- of them leaves walkable ground. AmeisenNav's default is 0 - corner to corner
-- - and those sharp corners are where the character clips rocks and walls.
-- Chaikin rather than Catmull-Rom / Bezier: it only cuts corners (never
-- overshoots past a waypoint), the safest of the three next to cliffs.
-- Passed per request (move_to / find_path opts.flags, AmeisenNav API.md);
-- the installed 1.8.3.2 server supports these flags.
local AN_FLAGS = 1 + 16
local AN_OPTS = { flags = AN_FLAGS }
local AN_SEAMLESS = { flags = AN_FLAGS, seamless = true }

--- find_path with the smoothing flags: cb(ok, points, info).
local function an_find(n, a, b, cb)
    return pcall(n.find_path, n, a, b, cb, AN_OPTS)
end

local function read_client(t) return t.client end

-- ============================================================================
-- STOP
-- ============================================================================
-- NO STOP WHILE A PATH IS BEING PLANNED (2.181.0). The two game crashes of
-- 2026-10-01 (09:17:10 and the 09:19 session) both came the moment combat
-- movement took over from a Sentinel leg that had been asked for seconds
-- earlier - an approach to a 78 yd wolf, and a waypoint walk whose path was
-- requested on the same tick - and the 2026-09-27 crashes (2.76.0 note in
-- movement/combat.lua) all came within a second of a fresh Sentinel leg.
-- Stopping the client while its path request is still in flight is the one
-- thing those share. The stop is now deferred until the client has left
-- "awaiting_path" / "repathing" (or STOP_WAIT_MAX passed), and sent then; a
-- new leg issued meanwhile cancels the deferred stop.
local STOP_WAIT_MAX = 15.0
local stop_pending = nil       -- { client, since }

-- AMEISEN: no deferral. Its stop() during "planning" finishes the navigation
-- as cancelled and the late path answer is ignored ("superseded" in
-- anav/client.lua _plan), so a stop is always sent at once.
local function in_flight(c)
    return false
end

--- Send a deferred stop once the path request has come back. Per frame.
function N.flush_stop(t)
    local p = stop_pending
    if not p then return end
    if in_flight(p.client) and (t - p.since) < STOP_WAIT_MAX then return end
    stop_pending = nil
    pcall(p.client.stop, p.client)
    dlog("ameisen", "deferred stop sent")
end

function N.stop()
    -- A pending re-path around a stuck spot belongs to the walk being stopped
    -- (2.217.0): it used to survive nav_stop / halt / the rest lock and issue a
    -- Sentinel move up to AR_WAIT s later - while eating, say. Every stop path
    -- (O.halt_all) comes through here.
    if N.cancel_repath then N.cancel_repath() end
    local c = R.sn_client
    -- Ameisen may still be walking a leg we no longer track (is_busy):
    -- AmeisenNav owns simple_movement until it is stopped.
    if not R.sn_active then
        if type(c) == "table" and type(c.is_busy) == "function" then
            local okb, busy = pcall(c.is_busy, c)
            if okb and busy == true then pcall(c.stop, c) end
        end
        return false
    end
    if type(c) == "table" then
        if in_flight(c) then
            stop_pending = { client = c, since = izi.now() }
            dlog("ameisen", "stop deferred - path request still in flight")
        else
            pcall(c.stop, c)
        end
    end
    R.sn_active, R.sn_reason = false, nil
    R.sn_leash_hold = false
    R.sn_watch_t = 0
    N.end_recovery()
    return true
end

-- ============================================================================
-- CALLBACKS
-- ============================================================================
-- FAILURE CODES (2.112.0), from SentinelNavClient's own source (Client.lua,
-- _fail_navigation / _normalize_fail_reason): the move_to callback is
-- (success, reason, detail). `reason` is the raw message ("HTTP 422: Position
-- not on navmesh", ...), and the normalised code - unreachable,
-- server_timeout, max_stuck_exceeded, max_repath_exceeded - is detail.code.
-- This compared the RAW message against the codes, so none of them ever
-- matched. The nav.failed bus event carries a table ({ fail_reason, ... }),
-- which used to arrive here as "table: 0x...". Both are classified here, the
-- same way Sentinel does it when no code is given.
local FAIL_CODES = { unreachable = true, server_timeout = true,
    max_stuck_exceeded = true, max_repath_exceeded = true,
    -- Ameisen's own codes (anav/client.lua), kept distinct (2.235.0-ameisen)
    cancelled = true, start_off_mesh = true, end_off_mesh = true, no_path = true,
    map_not_loaded = true, server_down = true, bad_request = true }

local function fail_code(reason, detail)
    if type(detail) == "table" and FAIL_CODES[detail.code] then
        return detail.code, tostring(detail.detail or reason or detail.code)
    end
    if type(reason) == "table" then
        local c = reason.fail_reason or reason.code or reason.reason
        if FAIL_CODES[c] then return c, tostring(reason.detail or c) end
        reason = c
    end
    local msg = tostring(reason or "")
    if FAIL_CODES[msg] then return msg, msg end
    local low = msg:lower()
    if low:find("timeout", 1, true) or low:find("http 0", 1, true) or low:find("http 5", 1, true) then
        return "server_timeout", msg
    end
    if low:find("max_stuck", 1, true) then return "max_stuck_exceeded", msg end
    if low:find("max_repath", 1, true) then return "max_repath_exceeded", msg end
    return "unreachable", msg
end
N.fail_code = fail_code

--- A FAR_HOP yd step from the player toward (x, y), at the ground height read
--- there, when the destination is more than FAR_HOP_MIN yd away. nil when it
--- is closer (the terrain height retry handles that) or no height is known.
local FAR_HOP = 120
local FAR_HOP_MIN = 160
function N.far_hop(x, y, z)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    local hx, hy, hz = here_xyz()
    if not hx then return nil end
    local d = dist2(hx, hy, x, y)
    if d <= FAR_HOP_MIN then return nil end
    local f = FAR_HOP / d
    local px, py = hx + (x - hx) * f, hy + (y - hy) * f
    local pz = nil
    local ok_t, Tr = pcall(require, "movement/terrain")
    if ok_t and type(Tr) == "table" and type(Tr.height) == "function" then
        pz = Tr.height(px, py, (hz or 0) + 80)
    end
    if type(pz) ~= "number" then return nil end
    return { x = px, y = py, z = pz, d = d }
end

local chain_busy = false
local try_random_unstick

function N.on_nav_done(ok, reason, detail)
    if not R.sn_active then return end           -- stale: we already stopped/switched
    local r, msg = "arrived", ""
    if ok ~= true then
        r, msg = fail_code(reason, detail)
        -- AMEISEN: "cancelled" is our own stop() or a newer navigation that
        -- replaced this one (retarget, follow_path) - never a failure.
        if r == "cancelled" then return end
        local ok_e, el = pcall(require, "errorlog")
        if ok_e and type(el) == "table" and type(el.trail) == "function" then
            pcall(el.trail, "ameisen", "leg '%s' failed: %s (%s)", tostring(R.sn_why or ""), r, msg)
        end
    end
    if ok == true then
        -- A steering hop finished and the RestedXP waypoint is still ahead.
        -- Continue to it. Stopping here is the full stop between points.
        if R.keep_path and type(R.goal_x) == "number" then
            local dx = R.goal_x - (R.dest_x or R.goal_x)
            local dy = R.goal_y - (R.dest_y or R.goal_y)
            if dx * dx + dy * dy > 9 and not chain_busy then
                local goal = { x = R.goal_x, y = R.goal_y, z = R.goal_z }
                chain_busy = true
                local went = N.retarget(goal, "chain")
                chain_busy = false
                if went then return end
            end
        end
        R.sn_active, R.sn_reason = false, r
        R.sn_leash_hold = false
        if R.keep_path then
            W.clear_dest()
            return
        end
        W.clear_dest()
        W.halt()
        return
    end
    -- AMEISEN: the server, the map or the player's own position is the
    -- problem, not the destination - walk this leg with the walker and
    -- blacklist nothing.
    if r == "server_down" or r == "map_not_loaded" or r == "start_off_mesh" then
        if r ~= "start_off_mesh" then R.sn_ok = false end
        local ok_e2, el2 = pcall(require, "errorlog")
        if ok_e2 and type(el2) == "table" and type(el2.trail) == "function" then
            pcall(el2.trail, "ameisen", "%s - walking this leg without Ameisen%s", r,
                r == "server_down" and " (start Ameisen\\Start-Ameisen.bat)" or "")
        end
        R.sn_active, R.sn_reason = false, r
        R.sn_leash_hold = false
        if R.has_dest then
            W.move(pt(P_DEST, R.dest_x, R.dest_y, R.dest_z), "an_" .. r)
        else
            W.clear_dest()
        end
        return
    end
    if r == "server_timeout" then
        R.sn_ok = false
        R.sn_active, R.sn_reason = false, r
        R.sn_leash_hold = false
        if R.has_dest then
            W.move(pt(P_DEST, R.dest_x, R.dest_y, R.dest_z), "sn_timeout")
        else
            W.clear_dest()
        end
        return
    end
    -- FAR LEG WITHOUT A PATH (2.239.0): a far destination's height is a
    -- guess, and Ameisen answers no_path / end_off_mesh for it. Walk a hop of
    -- FAR_HOP yd toward it at the ground height read here (terrain within
    -- range is loaded) and ask again from there - no blacklist, no hold.
    if (r == "no_path" or r == "end_off_mesh" or r == "unreachable")
        and R.has_dest and R.cur_owner ~= OWNER.COMBAT then
        local hop = N.far_hop(R.dest_x, R.dest_y, R.dest_z)
        if hop then
            local ok_e3, el3 = pcall(require, "errorlog")
            if ok_e3 and type(el3) == "table" and type(el3.trail) == "function" then
                pcall(el3.trail, "ameisen", "%s to a point %.0f yd away (height unknown) - walking a %d yd hop toward it",
                    r, hop.d, FAR_HOP)
            end
            -- The next move toward this goal is sent to the hop (N.move);
            -- the reply came inside the request gap, so it is not re-issued here.
            R.far_hop = { gx = R.dest_x, gy = R.dest_y, x = hop.x, y = hop.y, z = hop.z, t = izi.now() }
            R.sn_active, R.sn_reason = false, r
            R.sn_leash_hold = false
            W.clear_dest()
            return
        end
    end
    -- WAYPOINT HEIGHT RETRY (2.221.0, movement/terrain.lua): "unreachable" is
    -- most often the right x, y at the wrong z. When another floor height is
    -- found there, drop the leg without the failure handling below (no hold,
    -- no off-mesh blacklist); the caller's next move asks at that height.
    if (r == "unreachable" or r == "end_off_mesh" or r == "no_path")
        and R.has_dest and R.cur_owner ~= OWNER.COMBAT then
        local ok_t, Tr = pcall(require, "movement/terrain")
        if ok_t and type(Tr) == "table" and Tr.on_unreachable(R.dest_x, R.dest_y, R.dest_z) then
            R.sn_active, R.sn_reason = false, r
            R.sn_leash_hold = false
            W.clear_dest()
            return
        end
    end
    -- Remember the failed destination (2.109.0): Sentinel-only travel does not
    -- re-request it for K.SN_FAIL_HOLD seconds.
    if R.has_dest then
        R.sn_fail = { x = R.dest_x, y = R.dest_y, t = izi.now(), reason = r, detail = msg }
    end
    if r == "unreachable" or r == "max_repath_exceeded" or r == "end_off_mesh" or r == "no_path" then
        W.mark_fail("unreachable")
    elseif r == "max_stuck_exceeded" then
        if try_random_unstick() then
            return
        end
        W.mark_fail("max_stuck_exceeded")
    else
        W.mark_fail(r ~= "" and r or "failed")
    end
    R.sn_active, R.sn_reason = false, r
    R.sn_leash_hold = false
    W.clear_dest()
    W.halt()
end

local on_nav_done = N.on_nav_done

--- Sentinel has detected a stuck condition and has STARTED recovering.
---
--- This is not a failure and must not be treated as one. The legacy "stuck"
--- event is documented as mapped from navigating.recovering, and the bus
--- event nav.stuck_detected fires at the same point: the StuckRecoveryTree is
--- about to run its staged escalation - jump, then probe plus an avoidance
--- zone plus a repath, then strafe.
---
--- This used to call on_nav_done(false, "max_stuck_exceeded"), which tore the
--- navigation down and took the player back before Sentinel had tried any of
--- that. Sentinel owns stuck handling; we wait.
---
--- The terminal case arrives separately, as a failure with the reason
--- max_stuck_exceeded, and is handled in on_nav_done.
-- RECOVERY THAT NEVER ENDS (2.192.0). The 13:25 Sentinel log: 9 s and more
-- in navigating.recovering with the character frozen at the same spot to the
-- hundredth of a yard - stuck attempt 1..5, a re-plan to the SAME 68-point
-- path, again and again - and no "recovered" event. R.sn_recovering held the
-- re-path ladder, the stall check and the stuck-area watch off for as long as
-- that lasted, so nothing of ours ever re-pathed. A recovery that has not
-- moved the character SN_RECOVER_MOVE yards in SN_RECOVER_MAX seconds stops
-- counting as "Sentinel is handling it" (N.recovery_stalled) and the ladder
-- takes over: the area ahead is blacklisted and a path around it is planned.
local SN_RECOVER_MAX  = 6.0
local SN_RECOVER_MOVE = 2.0
local rec = { since = nil, x = nil, y = nil }

--- Forget Sentinel's recovery (a new leg, a stop, or we took over).
function N.end_recovery()
    R.sn_recovering = false
    rec.since, rec.x, rec.y = nil, nil, nil
end

--- Sentinel has been "recovering" SN_RECOVER_MAX s without moving the character.
function N.recovery_stalled()
    if not R.sn_recovering then return false end
    if not R.sn_active then
        N.end_recovery()
        return false
    end
    local hx, hy = here_xyz()
    if not hx then return false end
    local t = izi.now()
    if not rec.since or not rec.x then
        rec.since, rec.x, rec.y = t, hx, hy
        return false
    end
    if dist2(hx, hy, rec.x, rec.y) > SN_RECOVER_MOVE then
        rec.since, rec.x, rec.y = t, hx, hy      -- it is moving: the recovery works
        return false
    end
    return (t - rec.since) >= SN_RECOVER_MAX
end

--- Sentinel's own stuck handler is running AND still worth waiting on.
function N.recovering()
    return R.sn_recovering == true and not N.recovery_stalled()
end

local function on_sn_stuck()
    if not R.sn_recovering or not rec.since then
        local hx, hy = here_xyz()
        rec.since, rec.x, rec.y = izi.now(), hx, hy
    end
    R.sn_recovering = true
    -- Sentinel owns the recovery. All we add is which way the wall is, so the
    -- log says what it was stuck ON and not just that it was stuck. This is
    -- diagnostic only - nothing steers off it.
    local ok, Pr = pcall(require, "movement/probe")
    local side = ok and type(Pr) == "table" and Pr.blocked() or nil
    if type(side) == "string" then
        dlog("ameisen", "stuck detected, obstacle to the " .. side
            .. " - Ameisen is recovering, holding")
    else
        dlog("ameisen", "stuck detected - Ameisen is recovering, holding")
    end
end

--- Recovery worked and navigation continues.
local function on_sn_recovered()
    N.end_recovery()
    dlog("ameisen", "stuck recovered")
end

local function on_sn_failed(data)
    -- nav.failed carries { fail_reason, destination } (a table), the legacy
    -- "failed" event nothing; fail_code handles both.
    on_nav_done(false, data or "failed")
end

local function on_plan_done(ok, data)
    R.sn_plan_pending = false
    if ok == true and type(data) == "table" and type(data.visit_order) == "table" then
        R.sn_plan_order = data.visit_order
    end
end

local function on_reach_done(reachable, reason, _distance)
    R.sn_reach_pending = false
    R.sn_reach_ok = reachable == true
    if not R.sn_reach_ok then
        W.mark_fail(tostring(reason or "unreachable"))
    end
end

--- Subscribe to Ameisen's events (c:on only - there is no event bus).
---   stuck(level)           recovery STARTED: wait, as for Sentinel
---   failed(code, detail)   also reported by the move_to callback; the second
---                          report finds the leg already closed and is ignored
---   state_change(new, old) leaving "...recovering..." = recovered (Ameisen
---                          has no separate recovered event)
local function on_an_state(new, old)
    if type(old) == "string" and old:find("recovering", 1, true)
        and not (type(new) == "string" and new:find("recovering", 1, true)) then
        on_sn_recovered()
    end
end

local function on_an_failed(code, detail)
    on_nav_done(false, code or "failed", { code = code, detail = detail })
end

local function bind_sn_events(c)
    if R.sn_events or type(c) ~= "table" or type(c.on) ~= "function" then return end
    local ok1 = pcall(c.on, c, "stuck", on_sn_stuck)
    local ok2 = pcall(c.on, c, "failed", on_an_failed)
    local ok3 = pcall(c.on, c, "state_change", on_an_state)
    R.sn_events = ok1 == true or ok2 == true or ok3 == true
end

-- ============================================================================
-- CLIENT
-- ============================================================================
-- SERVER BACK UP (2.213.0). is_server_available() is Sentinel's connection
-- flag, set true by a successful response and dropped after repeated
-- failures. Every request we make is gated on that flag, so once it dropped
-- nothing of ours ever asked the server again and Sentinel stayed off for
-- the session. While the flag is down, the documented health_check pings the
-- server every HEALTH_GAP s; a good answer re-probes the client at once.
local HEALTH_GAP = 30
local health_asked = -1e9
local an_warned, an_down_warned, an_ready_logged = false, false, false

local function on_health(ok)
    if ok == true then
        R.sn_checked_t = -1e9
        dlog("ameisen", "server reachable again")
    end
end

--- Resolve the Sentinel client, re-probed at most every 5s. nil = unavailable,
--- in which case every caller silently falls back to walker steering.
function N.client()
    local t = izi.now()
    if (t - R.sn_checked_t) < 5 then return R.sn_ok and R.sn_client or nil end
    R.sn_checked_t = t
    R.sn_ok, R.sn_client = false, nil
    -- AMEISEN: looked up here, never in header.lua (plugin load order).
    local g = rawget(_G, "AmeisenNav")
    if type(g) ~= "table" then
        if not an_warned then
            an_warned = true
            core.log_warning("[Master Farmer - Grindbot] AmeisenNav not loaded - walking without navmesh "
                .. "(install scripts\\AmeisenNav, start Ameisen\\Start-Ameisen.bat, reload)")
        end
        return nil
    end
    local ok, c = pcall(read_client, g)
    if not ok or type(c) ~= "table" then return nil end
    for i = 1, #SN_NEED do
        if type(c[SN_NEED[i]]) ~= "function" then return nil end
    end
    local okA, avail = pcall(c.is_server_available, c)
    if not okA or avail ~= true then
        if not an_down_warned then
            an_down_warned = true
            core.log_warning("[Master Farmer - Grindbot] Ameisen server not answering - start Ameisen\\Start-Ameisen.bat")
        end
        if okA and type(c.health_check) == "function" and (t - health_asked) >= HEALTH_GAP then
            health_asked = t
            pcall(c.health_check, c, on_health)
        end
        return nil
    end
    bind_sn_events(c)
    if an_down_warned or not an_ready_logged then
        an_down_warned, an_ready_logged = false, true
        core.log("[Master Farmer - Grindbot] Ameisen ready - out-of-combat travel through AmeisenNav")
    end
    R.sn_ok, R.sn_client = true, c
    return c
end

local client = N.client

-- ============================================================================
-- COMMAND
-- ============================================================================
--- Issue a Sentinel move_to. Combat never goes here. Fresh vec3 per move.
---
--- RATE LIMITED (2.23.0). Each move_to is a navmesh path request whose result
--- lives in the same Lua state as this plugin. The combat pull-in used to issue
--- one on every frame whenever Sentinel answered fast - an instant failure or
--- an instant arrival - which is what drove memory to its limit while
--- travelling to mobs. Whatever a caller does, no more than one request per
--- SN_MIN_GAP now goes out; a refused request returns false, and every caller
--- already treats false as "use the walker instead".
-- ----------------------------------------------------------------------------
-- DOCUMENTED NAV QUERIES (client.nav_client)
-- ----------------------------------------------------------------------------
-- The Sentinel UI owns path config. We do not read get_path_opts, write
-- update_config, or pass z_extent / avoid_zones / soft_update on move_to.
local AVOID_MAX = 8
local AVOID_WAIT = 2.5     -- s a move waits for its find_path_avoid plan (2.235.0)
local AVOID_RANGE = 200
local BODY_WIDTH = 2 * K.BODY_HALF   -- the body width the obstacle traces use (1.0)

-- AMEISEN: the queries live on the client itself (no nav_client service).
local function nav()
    return client()
end

local function danger_zones(p)
    -- Dangerous mobs, and since 2.190.0 the blacklisted areas too (stuck
    -- spots, unreachable ground): find_path_avoid then plans AROUND them.
    local list = R.danger
    local zl = R.zones
    local have_d = type(list) == "table" and #list > 0
    local have_z = type(zl) == "table" and #zl > 0
    if not have_d and not have_z then return nil end
    local me = nil
    pcall(function() me = izi.me():get_position() end)
    if not me then return nil end
    local picked = {}
    local function consider(d, radius)
        if type(d) == "table" and type(d.x) == "number" and type(radius) == "number" then
            local dx, dy = d.x - me.x, d.y - me.y
            local dist = math.sqrt(dx * dx + dy * dy)
            local ex, ey = p and (d.x - p.x) or 1e9, p and (d.y - p.y) or 1e9
            local holds_dest = ex * ex + ey * ey <= radius * radius
            -- A zone the character stands in cannot be planned out of.
            local holds_me = dist <= radius
            if dist <= AVOID_RANGE and not holds_dest and not holds_me then
                picked[#picked + 1] = { dist = dist, zone = { x = d.x, y = d.y, z = d.z or me.z,
                    radius = radius } }
            end
        end
    end
    if have_d then
        for i = 1, #list do consider(list[i], list[i] and list[i].r) end
    end
    if have_z then
        for i = 1, #zl do consider(zl[i], zl[i] and zl[i].r) end
    end
    if #picked == 0 then return nil end
    table.sort(picked, function(a, b) return a.dist < b.dist end)
    local out = {}
    for i = 1, math.min(AVOID_MAX, #picked) do out[i] = picked[i].zone end
    return out
end

--- Drop leading path points that are under the player. nil when every
--- remaining point is too close (the caller treats that as arrived).
local function skip_near_pts(pts)
    if type(pts) ~= "table" or #pts == 0 then return pts end
    local i = 1
    while i <= #pts do
        local p = pts[i]
        if type(p) == "table" and not travel_near(p.x, p.y) then
            break
        end
        i = i + 1
    end
    if i <= 1 then return pts end
    if i > #pts then return nil end
    local out = {}
    for j = i, #pts do
        out[#out + 1] = pts[j]
    end
    return out
end
N.skip_near_pts = skip_near_pts

local ray = { asked = -1e9, t = -1e9, clear = nil, ax = 0, ay = 0, bx = 0, by = 0 }

local function line_clear(ax, ay, az, bx, by, bz)
    local now = izi.now()
    if ray.clear ~= nil and (now - ray.t) < 1.0
        and ray.ax == ax and ray.ay == ay and ray.bx == bx and ray.by == by then
        return ray.clear == true
    end
    -- NO /raycast TO AMEISEN (2.235.1-ameisen). The 11:39 session (nav log
    -- t=3127-3130): the bot's first short direct move sent /raycast, the nav
    -- server never answered it, and http_bridge.py holds one lock for every
    -- request (30 s TCP timeout, retried) - /health and every path after it
    -- timed out for the rest of the session. The straight line is judged by
    -- the local walk test only.
    if ray.clear ~= nil and ray.ax == ax and ray.ay == ay and ray.bx == bx and ray.by == by then
        return ray.clear == true
    end
    if type(walk_open) == "function" then
        return walk_open({ x = ax, y = ay, z = az }, { x = bx, y = by, z = bz }) == true
    end
    return false
end

-- ----------------------------------------------------------------------------
-- AVOID PLAN FROM find_path (Master Farmer Bot / Ameisen)
-- ----------------------------------------------------------------------------
-- Ameisen has no find_path_avoid and no obstacle list, so the blacklisted
-- areas and learned hazards (movement/hazards) would never reach its planner.
-- avoid_plan asks find_path for the direct path; when that path passes
-- through a zone, it asks again from the player to a DETOUR point beside the
-- first zone hit (DETOUR_PAD yards outside it, on the side the path already
-- leans to) and from there to the destination, and joins the two. One detour
-- per plan; a joined path that still crosses a zone is dropped (cb(nil)) and
-- the caller falls back to a plain move. cb(points) / cb(nil), exactly once.
local DETOUR_PAD = 4.0

local function seg_zone_hit(ax, ay, bx, by, z)
    local vx, vy = bx - ax, by - ay
    local len2 = vx * vx + vy * vy
    local k = 0
    if len2 > 0.0001 then
        k = ((z.x - ax) * vx + (z.y - ay) * vy) / len2
        if k < 0 then k = 0 elseif k > 1 then k = 1 end
    end
    local cx, cy = ax + vx * k, ay + vy * k
    local dx, dy = z.x - cx, z.y - cy
    return dx * dx + dy * dy < z.radius * z.radius, cx, cy
end

--- The first zone the path walks through: zone, segment start index.
local function first_zone_hit(pts, zones)
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local ax, ay = xyz(a)
        local bx, by = xyz(b)
        if ax and bx then
            for k = 1, #zones do
                if seg_zone_hit(ax, ay, bx, by, zones[k]) then return zones[k], i end
            end
        end
    end
    return nil
end

local function detour_point(z, a, b)
    local ax, ay, az = xyz(a)
    local bx, by = xyz(b)
    local _, cx, cy = seg_zone_hit(ax, ay, bx, by, z)
    local nx, ny = cx - z.x, cy - z.y
    local len = math.sqrt(nx * nx + ny * ny)
    if len < 0.1 then
        -- the path runs through the centre: go round on the segment's left
        local vx, vy = bx - ax, by - ay
        local vl = math.sqrt(vx * vx + vy * vy)
        if vl < 0.1 then return nil end
        nx, ny, len = -vy / vl, vx / vl, 1
    end
    local d = z.radius + DETOUR_PAD
    return vec3.new(z.x + nx / len * d, z.y + ny / len * d, z.z or az)
end

local function path_of(ok_q, pts)
    if ok_q == true and type(pts) == "table" and #pts >= 2 then return pts end
    return nil
end

local function avoid_plan(n, from, dest, zones, cb)
    if not n or type(n.find_path) ~= "function" then cb(nil) return false end
    local ok = an_find(n, from, dest, function(ok1, pts1)
        local direct = path_of(ok1, pts1)
        if not direct then cb(nil) return end
        local z, i = first_zone_hit(direct, zones)
        if not z then cb(direct) return end
        local via = detour_point(z, direct[i], direct[i + 1])
        if not via then cb(nil) return end
        local ok2 = an_find(n, from, via, function(okA, ptsA)
            local legA = path_of(okA, ptsA)
            if not legA then cb(nil) return end
            local ok3 = an_find(n, via, dest, function(okB, ptsB)
                local legB = path_of(okB, ptsB)
                if not legB then cb(nil) return end
                local out = {}
                for k = 1, #legA do out[#out + 1] = legA[k] end
                for k = 2, #legB do out[#out + 1] = legB[k] end
                if first_zone_hit(out, zones) then cb(nil) return end
                dlog("ameisen", string.format("avoid plan: detour (%.0f, %.0f) round a zone r%.0f",
                    via.x, via.y, z.radius))
                cb(out)
            end)
            if not ok3 then cb(nil) end
        end)
        if not ok2 then cb(nil) end
    end)
    return ok == true
end

local av = { asked = -1e9, t = -1e9, pts = nil, gx = nil, gy = nil, pending = false }

local function take_avoid_pts(from, dest, zones)
    if type(zones) ~= "table" or #zones == 0 then return nil end
    local n = nav()
    if not n or type(n.find_path) ~= "function" then return nil end
    local now = izi.now()
    if av.pts and av.gx and (now - av.t) <= 2.5 then
        local dx, dy = av.gx - dest.x, av.gy - dest.y
        if dx * dx + dy * dy <= 16 then
            local pts = av.pts
            av.pts = nil
            return pts
        end
    end
    if av.pending and (now - av.asked) < 5 then return nil end
    if (now - av.asked) < 1.0 then return nil end
    av.asked, av.pending = now, true
    local gx, gy = dest.x, dest.y
    local ok = avoid_plan(n, vec3.new(from.x, from.y, from.z),
        vec3.new(dest.x, dest.y, dest.z), zones, function(pts)
            av.pending = false
            if type(pts) == "table" and #pts >= 2 then
                av.pts, av.t, av.gx, av.gy = pts, izi.now(), gx, gy
            end
        end)
    if not ok then av.pending = false end
    -- Ameisen answers from its 10 s query cache inside the call itself: the
    -- plan may already be here - use it now, not on the next request.
    if av.pts and av.gx == gx and av.gy == gy then
        local pts = av.pts
        av.pts = nil
        return pts
    end
    return nil
end

local chk = { key = nil, ok = nil, pending = false, asked = -1e9 }

-- Ameisen has no check_path: a planned path is walked as planned (its own
-- stuck recovery and "deviated" repath cover a path gone bad).
local function path_checked(from, pts)
    chk.ok = true
    return true
end

local unstick_at = -1e9

try_random_unstick = function()
    local n = nav()
    if not n or type(n.random_point) ~= "function" then return false end
    local now = izi.now()
    if (now - unstick_at) < 8 then return false end
    unstick_at = now
    local gx, gy, gz = R.dest_x, R.dest_y, R.dest_z
    local hx, hy, hz = here_xyz()
    if not hx then return false end
    -- Ameisen: random_point(center, radius, cb(ok, point))
    local ok = pcall(n.random_point, n, vec3.new(hx, hy, hz), 8, function(ok_q, p)
        if ok_q ~= true or type(p) ~= "table" or type(p.x) ~= "number" then return end
        R.sn_active = false
        if type(gx) == "number" then
            R.goal_x, R.goal_y, R.goal_z = gx, gy, gz
            R.keep_path = true
        end
        N.move({ x = p.x, y = p.y, z = p.z }, "unstick")
    end)
    if ok then
        dlog("ameisen", "max_stuck - random_point then replan")
    end
    return ok == true
end

local function begin_leg(p, why)
    local now = izi.now()
    -- A new leg cancels a stop still deferred for the previous one (2.217.0).
    -- move_direct (short clear legs) did not clear it, so the old stop landed
    -- on the new leg once its path request was in.
    stop_pending = nil
    R.sn_last_issue_t = now
    R.sn_issued = R.sn_issued + 1
    R.sn_active, R.sn_reason = true, nil
    R.sn_why = why
    R.sn_leash_hold = true
    R.sn_watch_t = now
    R.sn_tight = false
    R.sn_prog_idx, R.sn_prog_pct = nil, nil
    N.end_recovery()
    W.begin_issue(p.x, p.y, p.z)
end

function N.move(p, why)
    if R.cur_owner == OWNER.COMBAT then return false end
    -- Benched by the re-pathing ladder (2.84.0): its plan made no progress,
    -- so the walker's steering gets the next legs. Not with Sentinel-only
    -- travel (2.109.0), where the ladder re-plans through Sentinel instead.
    if not K.SENTINEL_TRAVEL and izi.now() < (R.sn_bench_until or 0) then return false end
    local now = izi.now()
    if (now - R.sn_last_issue_t) < SN_MIN_GAP then
        R.sn_refused = R.sn_refused + 1
        return false
    end
    local c = client()
    if not c or type(p) ~= "table" then return false end
    -- No MAX_LEG clamp here (2.59.0): Sentinel plans the whole path itself,
    -- and a straight-line midpoint can be off the mesh. The one-request-per-
    -- SN_MIN_GAP rate limit above is what guards against flooding.
    if not xyz(p) then return false end
    -- FAR HOP (2.239.0): a far goal Ameisen had no path to is approached
    -- through the hop point on_nav_done picked, until the player is there.
    local fh = R.far_hop
    if fh then
        local hx1, hy1 = here_xyz()
        if (izi.now() - fh.t) > 180 or dist2(fh.gx, fh.gy, p.x, p.y) > 10
            or (hx1 and dist2(hx1, hy1, fh.x, fh.y) <= 8) then
            R.far_hop = nil
        else
            p = { x = fh.x, y = fh.y, z = fh.z }
            why = "far_hop"
        end
    end
    if travel_near(p.x, p.y) then return false end
    local hx, hy, hz = here_xyz()
    if R.sn_active then
        return N.retarget(p, why)
    end
    local okl, elog = pcall(require, "errorlog")
    if okl and type(elog) == "table" then
        elog.probe("sentinel move_to " .. tostring(why or ""))
    end
    if hx then
        local d = dist2(hx, hy, p.x, p.y)
        -- 2.221.0: a clear ray is not walkable ground - a slope too steep to
        -- climb lets it through. Terrain the line cannot vouch for is planned.
        local ok_t, Tr = pcall(require, "movement/terrain")
        if d < 30 and line_clear(hx, hy, hz, p.x, p.y, p.z)
            and (not ok_t or type(Tr) ~= "table" or Tr.line_ok(hx, hy, hz, p.x, p.y)) then
            W.halt()
            begin_leg(p, why)
            local okd = pcall(c.move_direct, c, to_vec3(p), on_nav_done)
            if not okd then
                R.sn_active, R.sn_reason = false, nil
                R.sn_leash_hold = false
                W.clear_dest()
                return false
            end
            dlog("issue", string.format("sentinel direct %s -> (%.1f, %.1f, %.1f)",
                tostring(why or ""), p.x, p.y, p.z))
            return true
        end
        local zones = danger_zones(p)
        if zones then
            local pts = take_avoid_pts({ x = hx, y = hy, z = hz }, p, zones)
            if pts and #pts >= 2 then
                pts = skip_near_pts(pts) or pts
                if #pts >= 2 then
                    return N.follow(pts, why or "avoid")
                end
            end
            -- WAIT FOR THE AVOID PLAN (2.235.0). The first ask only SENT the
            -- find_path_avoid request and move_to ran the plain plan at once -
            -- straight through the bad terrain - and Sentinel's own obstacle
            -- list is often empty (23:04 log: "holds 0 avoidance zone(s)").
            -- The plan is waited on up to AVOID_WAIT s; the caller sees
            -- "moving" and asks again next tick.
            if av.pending and (izi.now() - av.asked) < AVOID_WAIT then
                return true
            end
        end
    end
    W.halt()
    begin_leg(p, why)
    stop_pending = nil
    local ok = pcall(c.move_to, c, to_vec3(p), on_nav_done, AN_OPTS)
    if not ok then
        R.sn_active, R.sn_reason = false, nil
        R.sn_leash_hold = false
        W.clear_dest()
        return false
    end
    dlog("issue", string.format("sentinel %s -> (%.1f, %.1f, %.1f)",
        tostring(why or ""), p.x, p.y, p.z))
    return true
end

-- ============================================================================
-- RETARGET WITHOUT STOPPING
-- ============================================================================
-- Prefetch a path (nav_client.find_path) while the current leg runs, then
-- switch with follow_path. replan is reserved for the stuck ladder.
function N.retarget(p, why)
    if not R.sn_active or R.cur_owner == OWNER.COMBAT then return false end
    local now = izi.now()
    local c = client()
    if not c or type(p) ~= "table" or not xyz(p) then return false end
    if travel_near(p.x, p.y) then return false end
    -- A chain onto the real waypoint, or one avoidance hop, must not wait
    -- out the request gap: that wait is the character standing at the hop.
    local urgent = why == "chain" or why == "avoid"
    if not urgent and (now - R.sn_last_issue_t) < SN_MIN_GAP then return false end
    -- AMEISEN (2.235.2-ameisen): move_to with { seamless = true } (API.md
    -- "Following a moving unit"): Ameisen plans from where the character is
    -- NOW and the running walk takes the new path without releasing a key.
    -- The Sentinel way - a path prefetched up to 2.5 s earlier, then
    -- follow_path - started behind the character and was flagged "deviated".
    -- The replaced navigation's callback arrives as "cancelled" (ignored).
    begin_leg({ x = p.x, y = p.y, z = p.z }, why or R.sn_why)
    stop_pending = nil
    local ok = pcall(c.move_to, c, to_vec3(p), on_nav_done, AN_SEAMLESS)
    if not ok then return false end
    R.sn_active = true
    R.sn_why = why or R.sn_why
    dlog("issue", string.format("ameisen retarget (seamless) -> (%.1f, %.1f, %.1f)", p.x, p.y, p.z))
    return true
end

-- ============================================================================
-- WATCHDOG  (called from pulse while Sentinel is driving)
-- ============================================================================
-- STALLED LEG (2.70.0). A Sentinel leg that stops moving the character
-- without ever reporting "arrived" or "failed" - a "pull" leg deferred by a
-- cast and never resumed, say - kept R.sn_active true for good: the walker
-- stays silent while Sentinel drives, and every later move (the walk to a
-- corpse, the vendor trip) was refused as "already moving". The 12:15 log
-- shows the character standing still for over two minutes that way. The
-- leg is now dropped once the character has not moved SN_STALL_YD in
-- SN_STALL_SEC while not casting, and the next move is issued afresh.
-- SAFETY NET ONLY (2.141.0). This dropped the leg after 4 s - the same moment
-- the re-path ladder re-planned it, so the stop won and the character halted.
-- The ladder (movement/repath.lua) is the stuck authority: re-plan at 4 s,
-- jump at 7 s, give up at 11 s. This now fires only past all of that, for a
-- leg the ladder is not tracking.
local SN_STALL_SEC = 12.0

-- STILL PLANNING (2.111.0). A long path request (thousands of yards) keeps
-- Sentinel in "awaiting_path" for 4-5 s. The stall check and the re-path
-- ladder counted that as "no progress", dropped the leg and jumped, and the
-- request was sent again - the idle / awaiting_path loop in the console. A
-- leg that is still being planned is waited on, up to SN_PLAN_MAX seconds.
local SN_PLAN_MAX = 15.0
local plan_since = nil

--- Is Sentinel still computing the path for the leg in flight?
function N.planning()
    if not R.sn_active then plan_since = nil return false end
    if N.recovery_stalled() then return false end
    local c = R.sn_client
    if type(c) ~= "table" or type(c.get_full_state) ~= "function" then return false end
    local ok, st = pcall(c.get_full_state, c)
    -- awaiting_path, repathing, deferred (a move_to made while casting) and
    -- recovering (Sentinel's own stuck handler) are all "still working" -
    -- the grouping Sentinel's own questing adapter uses (2.112.0), plus
    -- recovering so a jump or strafe is not counted as a stall.
    -- Ameisen: "planning[.reason]" and "navigating.recovering.<step>".
    if not ok or type(st) ~= "string"
        or not (st:find("planning", 1, true) or st:find("awaiting", 1, true)
            or st:find("repathing", 1, true) or st:find("deferred", 1, true)
            or st:find("recovering", 1, true)) then
        plan_since = nil
        return false
    end
    local t = izi.now()
    plan_since = plan_since or t
    return (t - plan_since) < SN_PLAN_MAX
end

--- Path index or percent moved forward. A detour that walks away from the
--- goal is still progress (euclidean distance is not).
function N.progress_advanced()
    local c = R.sn_client
    if type(c) ~= "table" or type(c.get_progress) ~= "function" then return false end
    local ok, p = pcall(c.get_progress, c)
    if not ok or type(p) ~= "table" then return false end
    local idx = tonumber(p.current_index)
    local pct = tonumber(p.percent)
    local moved = false
    if idx and R.sn_prog_idx and idx > R.sn_prog_idx then moved = true end
    if pct and R.sn_prog_pct and pct > R.sn_prog_pct + 0.01 then moved = true end
    if idx then R.sn_prog_idx = idx end
    if pct then R.sn_prog_pct = pct end
    return moved
end

--- Re-request the current path. Does not stop the character.
function N.replan(reason)
    local c = client()
    if not c or type(c.replan) ~= "function" then return false end
    local now = izi.now()
    if (now - R.sn_last_issue_t) < SN_MIN_GAP then return false end
    R.sn_last_issue_t = now
    local ok = pcall(c.replan, c, reason or "no_progress")
    if ok then
        dlog("ameisen", "replan " .. tostring(reason or ""))
    end
    return ok == true
end

local SN_STALL_YD = 1.5
local stall_x, stall_y, stall_t = nil, nil, 0

local function stall_check(t)
    local me = nil
    pcall(function() me = izi.me() end)
    if not me then return false end
    local casting = false
    pcall(function() casting = me:is_channeling_or_casting() == true end)
    local pos = nil
    pcall(function() pos = me:get_position() end)
    if casting or not pos or N.recovering() or N.planning() then
        stall_x, stall_y, stall_t = nil, nil, t
        return false
    end
    if stall_x == nil then
        stall_x, stall_y, stall_t = pos.x, pos.y, t
        return false
    end
    local dx, dy = pos.x - stall_x, pos.y - stall_y
    if dx * dx + dy * dy >= SN_STALL_YD * SN_STALL_YD then
        stall_x, stall_y, stall_t = pos.x, pos.y, t
        return false
    end
    return (t - stall_t) >= SN_STALL_SEC
end

local corr_asked = -1e9
-- ONCE PER DESTINATION (2.213.0). find_path_corridor is documented as "path
-- with corridor widths" - not as a wider path - so its answer may run through
-- the same doorway. Re-asking every 2 s then restarted the walk on an equal
-- path for as long as the character stood in the narrow section. One corridor
-- re-plan per destination; the stuck ladder owns anything after that.
local corr_key = nil

-- AMEISEN: no corridor widths and no find_path_corridor - a narrow doorway
-- is left to Ameisen's own stuck recovery (jump, repath, detour, back off).
local function maybe_corridor(c)
    return
end

--- Sentinel's current waypoint is under the player: skip it. 1-yard densify
--- points were walked as dests and the character orbited them.
local function skip_near_wp(c)
    -- AMEISEN (2.235.1-ameisen): off. Sentinel walked its 1-yard densify
    -- points as destinations; AmeisenNav's follower reaches its waypoints by
    -- itself. This re-handed the rest of the path with follow_path every 1-2 s
    -- (nav log 11:35: "walking N points (route" then "repath #1 (deviated)",
    -- over and over), and each one restarted Ameisen's walk.
    do return end
    if type(c) ~= "table" then return end
    if N.planning() or R.sn_recovering then return end
    if type(c.get_current_path) ~= "function" or type(c.get_path_index) ~= "function" then
        return
    end
    local okp, path = pcall(c.get_current_path, c)
    if not okp or type(path) ~= "table" or #path == 0 then return end
    local oki, idx = pcall(c.get_path_index, c)
    if not oki or type(idx) ~= "number" then idx = 1 end
    if not path[idx] then idx = idx + 1 end
    local cur = path[idx]
    if type(cur) ~= "table" or not travel_near(cur.x, cur.y) then return end
    local rest = {}
    for i = idx, #path do
        local p = path[i]
        if type(p) == "table" and not travel_near(p.x, p.y) then
            rest[#rest + 1] = vec3.new(p.x, p.y, p.z)
        end
    end
    if #rest == 0 then
        if type(c.get_destination) == "function" then
            local okd, dest = pcall(c.get_destination, c)
            if okd and type(dest) == "table" and not travel_near(dest.x, dest.y) then
                N.retarget({ x = dest.x, y = dest.y, z = dest.z }, "skip")
                return
            end
        end
        on_nav_done(true, "arrived")
        return
    end
    if #rest == 1 then
        N.retarget({ x = rest[1].x, y = rest[1].y, z = rest[1].z }, "skip")
        return
    end
    local now = izi.now()
    if (now - R.sn_last_issue_t) < SN_MIN_GAP then return end
    R.sn_last_issue_t = now
    stop_pending = nil                        -- 2.217.0: see begin_leg
    local last = rest[#rest]
    W.begin_issue(last.x, last.y, last.z)
    pcall(c.follow_path, c, rest, on_nav_done)
    dlog("ameisen", "skipped underfoot waypoint")
end

function N.watch(t)
    if (t - R.sn_watch_t) < 1.0 then return end
    R.sn_watch_t = t
    if R.sn_active and stall_check(t) then
        local why = tostring(R.sn_why or "")
        dlog("ameisen", "leg '" .. why .. "' stalled - dropped")
        local ok_e, el = pcall(require, "errorlog")
        if ok_e and type(el) == "table" and type(el.trail) == "function" then
            pcall(el.trail, "move", "Ameisen leg '%s' made no progress for %.0fs - dropped", why, SN_STALL_SEC)
        end
        stall_x, stall_y = nil, nil
        if R.keep_path and R.has_dest then
            N.retarget({ x = R.dest_x, y = R.dest_y, z = R.dest_z }, "chain")
            return
        end
        N.stop()
        W.clear_dest()
        return
    end
    if not R.sn_active then
        stall_x, stall_y = nil, nil
    end
    local c = R.sn_client
    if R.sn_active and type(c) == "table" then
        skip_near_wp(c)
        maybe_corridor(c)
    end
    if type(c) == "table" then
        local ok, st = pcall(c.get_state, c)
        if ok then
            if st == "arrived" then
                on_nav_done(true, "arrived")
            elseif st == "failed" then
                on_nav_done(false, "failed")
            elseif st == "idle" and (t - R.last_move_t) >= INFLIGHT_TIMEOUT then
                on_nav_done(false, "server_timeout")
            end
        elseif (t - R.last_move_t) >= INFLIGHT_TIMEOUT then
            on_nav_done(false, "server_timeout")
        end
    elseif (t - R.last_move_t) >= INFLIGHT_TIMEOUT then
        on_nav_done(false, "server_timeout")
    end
end

-- ============================================================================
-- HELPERS  (grind node order / reachability; one shot, not per frame)
-- ============================================================================
function N.plan_grind_route(coords)
    if type(coords) ~= "table" or #coords < 2 then return nil end
    if R.sn_plan_key == coords then return R.sn_plan_order end
    local c = client()
    if not c or type(c.plan_route) ~= "function" then return nil end
    R.sn_plan_key, R.sn_plan_order, R.sn_plan_pending = coords, nil, true
    local nodes = {}
    if type(coords[1]) == "number" then
        -- A path's own flat x,y,z array.
        for i = 1, math.floor(#coords / 3) do
            local k = (i - 1) * 3
            local x, y, z = coords[k + 1], coords[k + 2], coords[k + 3]
            if type(x) == "number" and type(y) == "number" and type(z) == "number" then
                nodes[#nodes + 1] = vec3.new(x, y, z)
            end
        end
    else
        for i = 1, #coords do
            local x, y, z = xyz(coords[i])
            if x then nodes[#nodes + 1] = vec3.new(x, y, z) end
        end
    end
    if #nodes < 2 then
        R.sn_plan_pending = false
        return nil
    end
    local ok = pcall(c.plan_route, c, nodes, on_plan_done)
    if not ok then R.sn_plan_pending = false end
    return R.sn_plan_order
end

function N.grind_visit_order()
    return R.sn_plan_order
end

--- Cached validate_destination for a grind node index. Returns false only after
--- Sentinel has reported the node unreachable. Pending / no client = true.
function N.node_reachable(pos, index)
    if type(index) ~= "number" then return true end
    if R.sn_reach_index == index then
        if R.sn_reach_pending then return true end
        return R.sn_reach_ok ~= false
    end
    R.sn_reach_index, R.sn_reach_ok, R.sn_reach_pending = index, true, true
    local c = client()
    if not c then
        R.sn_reach_pending, R.sn_reach_ok = false, true
        return true
    end
    local x, y, z = xyz(pos)
    if not x then
        R.sn_reach_pending, R.sn_reach_ok = false, true
        return true
    end
    local ok = pcall(c.validate_destination, c, vec3.new(x, y, z), on_reach_done)
    if not ok then
        R.sn_reach_pending, R.sn_reach_ok = false, true
    end
    return true
end

-- ============================================================================
-- SENTINEL-FIRST MOVEMENT (2.59.0)
-- ============================================================================
-- The rest of the plugin asks these, never the client directly. Every call is
-- feature-detected and non-blocking: while an answer is pending, or with no
-- server, the caller gets "no opinion" and carries on as before.

-- Result parsing. The Sentinel docs name the arguments but not every result
-- shape, so a point is anything with numeric x / y / z - or such a table under
-- position / pos / point / target / destination - and a path is an array of
-- points, or such an array under waypoints / path / points.
local function as_point(v)
    if type(v) ~= "table" and type(v) ~= "userdata" then return nil end
    local x, y, z = xyz(v)
    if x then return vec3.new(x, y, z) end
    if type(v) == "table" then
        local keys = { "position", "pos", "point", "target", "destination", "result" }
        for i = 1, #keys do
            local inner = v[keys[i]]
            if inner ~= nil then
                local p = as_point(inner)
                if p then return p end
            end
        end
    end
    return nil
end

local function as_points(v)
    if type(v) ~= "table" then return nil end
    if v[1] ~= nil then
        local out = {}
        for i = 1, #v do
            local p = as_point(v[i])
            if p then out[#out + 1] = p end
        end
        if #out > 0 then return out end
        return nil
    end
    local keys = { "waypoints", "path", "points" }
    for i = 1, #keys do
        if v[keys[i]] ~= nil then
            local pts = as_points(v[keys[i]])
            if pts then return pts end
        end
    end
    return nil
end

local function nav_service()
    return client()
end

-- ----------------------------------------------------------------------------
-- 1. REACHABILITY  (validate_destination, cached)
-- ----------------------------------------------------------------------------
-- reach[key] = { ok = true|false|nil (pending), t = when }. Keyed on a 4-yard
-- grid so nearby asks share one answer; answers live REACH_TTL.
local REACH_TTL = 300
local REACH_GAP = 0.5          -- seconds between new requests
local reach = {}
local reach_n = 0
local reach_next = 0

local function reach_key(x, y)
    return string.format("%d|%d", math.floor(x / 4), math.floor(y / 4))
end

--- false only once Sentinel has said "unreachable"; true while pending,
--- unknown, or with no server - never blocks the caller.
--- 2.239.0: never false for a point more than REACH_TRUST_FAR yd away. Its
--- height is a guess there (RestedXP gives x, y only, and the Ameisen server
--- has no height query), and a wrong height reads "no_path" - one answer
--- skipped every kill goal of a step at the same spot and stalled the guide.
--- Far legs are walked in hops instead (on_nav_done, far_hop).
local REACH_TRUST_FAR = 150
function N.reachable(pos)
    local x, y, z = xyz(pos)
    if not x then return true end
    local hx0, hy0 = here_xyz()
    local far = hx0 ~= nil and dist2(hx0, hy0, x, y) > REACH_TRUST_FAR
    local key = reach_key(x, y)
    local now = izi.now()
    local e = reach[key]
    if e and (now - e.t) < REACH_TTL then
        return e.ok ~= false or far
    end
    local c = client()
    if not c or now < reach_next then return true end
    reach_next = now + REACH_GAP
    if reach_n > 200 then reach, reach_n = {}, 0 end
    e = { ok = nil, t = now }
    reach[key] = e
    reach_n = reach_n + 1
    local ok = pcall(c.validate_destination, c, vec3.new(x, y, z), function(reachable)
        e.ok = reachable == true
        e.t = izi.now()
    end)
    if not ok then e.ok = true end
    return true
end

-- ----------------------------------------------------------------------------
-- 2. FOLLOW A WAYPOINT LIST  (follow_path)
-- ----------------------------------------------------------------------------
--- Hand a recorded route to Sentinel so it gets Sentinel's stuck recovery.
--- Same gates and rate limit as N.move; false means "walk it yourself".
function N.follow(points, why)
    if R.cur_owner == OWNER.COMBAT then return false end
    if type(points) ~= "table" or #points < 2 then return false end
    local now = izi.now()
    if (now - R.sn_last_issue_t) < SN_MIN_GAP then
        R.sn_refused = R.sn_refused + 1
        return false
    end
    local c = client()
    if not c or type(c.follow_path) ~= "function" then return false end
    local pts = {}
    for i = 1, #points do
        local x, y, z = xyz(points[i])
        if x then pts[#pts + 1] = vec3.new(x, y, z) end
    end
    pts = skip_near_pts(pts)
    if not pts or #pts < 2 then return false end
    local hx, hy, hz = here_xyz()
    if hx then
        local ready = path_checked({ x = hx, y = hy, z = hz }, pts)
        if chk.ok == false then
            return N.move({ x = pts[1].x, y = pts[1].y, z = pts[1].z }, why or "path")
        end
        if not ready then return false end
    end
    R.sn_last_issue_t = now
    R.sn_issued = R.sn_issued + 1
    local last = pts[#pts]
    W.halt()
    W.begin_issue(last.x, last.y, last.z)
    R.sn_active, R.sn_reason = true, nil
    R.sn_why = why or "path"
    R.sn_leash_hold = true
    R.sn_watch_t = now
    stop_pending = nil
    N.end_recovery()
    local ok = pcall(c.follow_path, c, pts, on_nav_done)
    if not ok then
        R.sn_active, R.sn_reason = false, nil
        R.sn_leash_hold = false
        W.clear_dest()
        return false
    end
    dlog("issue", string.format("sentinel follow_path %s (%d pts)", tostring(why or ""), #pts))
    return true
end

-- ----------------------------------------------------------------------------
-- RE-PATH AROUND A STUCK SPOT (2.192.0)
-- ----------------------------------------------------------------------------
--- The point the running Sentinel path walks toward next: the first path
--- point at least `min_d` yards from the player. x, y, z or nil.
function N.ahead_point(min_d)
    local c = R.sn_client
    if not R.sn_active or type(c) ~= "table" or type(c.get_current_path) ~= "function" then return nil end
    local hx, hy = here_xyz()
    if not hx then return nil end
    local okp, path = pcall(c.get_current_path, c)
    if not okp or type(path) ~= "table" or #path == 0 then return nil end
    local idx = 1
    if type(c.get_path_index) == "function" then
        local oki, i = pcall(c.get_path_index, c)
        if oki and type(i) == "number" and i >= 1 then idx = i end
    end
    for i = idx, #path do
        local p = path[i]
        if type(p) == "table" and type(p.x) == "number" and dist2(hx, hy, p.x, p.y) >= (min_d or 3) then
            return p.x, p.y, p.z
        end
    end
    return nil
end

-- The 2.190.0 "stuck_avoid" re-path went through N.move: with a leg running
-- that is N.retarget -> plain find_path (no avoid zones, maybe even the cached
-- old path), and with none, take_avoid_pts only ASKS on the first call and
-- move_to ran the plain plan meanwhile - the same blocked route came back.
-- Now the avoid plan is asked for and waited on (up to AR_WAIT s, the stuck
-- leg keeps running meanwhile), then followed; no plan -> move_to, which still
-- has the blacklisted area in Sentinel's obstacle list.
local AR_WAIT = 4.0
local ar = { dest = nil }

--- Drop a pending re-path job (2.217.0). Called by N.stop.
function N.cancel_repath()
    if ar.dest then ar = { dest = nil } end
end

--- Plan to `p` around the blacklisted areas and follow it. True when asked.
function N.repath_around(p, why)
    local px, py, pz = xyz(p)
    if not px or R.cur_owner == OWNER.COMBAT then return false end
    why = why or "stuck_avoid"
    local n = nav()
    local zones = danger_zones({ x = px, y = py, z = pz })
    local hx, hy, hz = here_xyz()
    if n and type(n.find_path) == "function" and zones and hx then
        local job = { dest = { x = px, y = py, z = pz }, asked = izi.now(), pts = nil, why = why }
        ar = job
        local ok = avoid_plan(n, vec3.new(hx, hy, hz), vec3.new(px, py, pz), zones, function(raw)
            local pts = as_points(raw)
            if pts and #pts >= 2 then
                job.pts = pts
                return
            end
            job.failed = true
        end)
        if ok then
            dlog("ameisen", string.format("re-path around %d blacklisted area(s) -> (%.0f, %.0f)", #zones, px, py))
            return true
        end
        ar = { dest = nil }
    end
    N.stop()
    W.clear_dest()
    R.sn_last_issue_t = -1e9
    return N.move({ x = px, y = py, z = pz }, why)
end

--- Per pulse: follow the avoid plan once it is back, or fall back to move_to.
function N.repath_tick(t)
    local job = ar
    if not job.dest then return end
    if R.cur_owner == OWNER.COMBAT then ar = { dest = nil } return end
    if job.pts then
        R.sn_last_issue_t = -1e9             -- one re-path per stuck spot, not a flood
        if N.follow(job.pts, job.why) then
            ar = { dest = nil }
            local ok_e, el = pcall(require, "errorlog")
            if ok_e and type(el) == "table" and type(el.trail) == "function" then
                pcall(el.trail, "move", "re-path around the stuck spot: following %d points", #job.pts)
            end
            return
        end
    end
    if job.failed or (t - job.asked) >= AR_WAIT then
        ar = { dest = nil }
        N.stop()
        W.clear_dest()
        R.sn_last_issue_t = -1e9
        N.move(job.dest, job.why)
    end
end

-- ----------------------------------------------------------------------------
-- 4. CHASE PATH  (nav_client.find_path, driven by the local walker)
-- ----------------------------------------------------------------------------
-- A blocked line to a mob mid-fight: Sentinel plans, the walker walks (it is
-- not deferred while casting, as a Sentinel move is). One cached path per
-- target; asked again when the target has moved CHASE_REPATH yards from the
-- path's end, or it is CHASE_AGE old, never more than once per CHASE_GAP.
-- ----------------------------------------------------------------------------
-- PREFETCH (2.85.0) - a re-aim without stopping
-- ----------------------------------------------------------------------------
-- A re-aimed Sentinel leg used to be a fresh move_to, which drops Sentinel
-- into "awaiting_path" - standing still - until its server answers, up to
-- once a second on a moving goal. Now the path to the new goal is asked for in
-- the background while the current leg keeps running, and the switch is made
-- with follow_path once the points are in: the character never stands.
local PRE_GAP, PRE_AGE, PRE_NEAR = 1.0, 2.5, 4.0
local pre = { t = -1e9, asked = -1e9, pts = nil, pending = false, gx = nil, gy = nil }

--- A fresh planned path from `from` to `to`, or nil (asked for if needed).
function N.prefetch(from, to)
    local fx, fy, fz = xyz(from)
    local tx, ty, tz = xyz(to)
    if not fx or not tx then return nil end
    local now = izi.now()
    if pre.pts and pre.gx and (now - pre.t) <= PRE_AGE then
        local dx, dy = pre.gx - tx, pre.gy - ty
        if dx * dx + dy * dy <= PRE_NEAR * PRE_NEAR then
            local pts = pre.pts
            pre.pts = nil
            return pts
        end
    end
    if pre.pending and (now - pre.asked) < 5 then return nil end
    if (now - pre.asked) < PRE_GAP then return nil end
    local nav = nav_service()
    if not nav or type(nav.find_path) ~= "function" then return nil end
    pre.asked, pre.pending = now, true
    local gx, gy = tx, ty
    local ok = an_find(nav, vec3.new(fx, fy, fz), vec3.new(tx, ty, tz), function(...)
        pre.pending = false
        for i = 1, select("#", ...) do
            local pts = as_points((select(i, ...)))
            if pts and #pts >= 2 then
                pts = skip_near_pts(pts)
                if pts and #pts >= 2 then
                    pre.pts, pre.t, pre.gx, pre.gy = pts, izi.now(), gx, gy
                    return
                end
            end
        end
    end)
    if not ok then pre.pending = false end
    return nil
end

local CHASE_GAP, CHASE_AGE, CHASE_REPATH = 1.0, 3.0, 5.0
local chase = { key = nil, t = -1e9, asked = -1e9, pts = nil, pending = false }

function N.chase_path(from, to, key)
    local fx, fy, fz = xyz(from)
    local tx, ty, tz = xyz(to)
    if not fx or not tx then return nil end
    local now = izi.now()
    local have = chase.key == key and chase.pts
    if have then
        local last = chase.pts[#chase.pts]
        local moved = math.sqrt((last.x - tx) ^ 2 + (last.y - ty) ^ 2)
        if moved <= CHASE_REPATH and (now - chase.t) <= CHASE_AGE then
            return chase.pts
        end
    end
    if chase.pending and (now - chase.asked) < 5 then return have and chase.pts or nil end
    if (now - chase.asked) < CHASE_GAP then return have and chase.pts or nil end
    local nav = nav_service()
    if not nav or type(nav.find_path) ~= "function" then return nil end
    chase.asked, chase.pending = now, true
    local want = key
    local ok = an_find(nav, vec3.new(fx, fy, fz), vec3.new(tx, ty, tz), function(...)
        chase.pending = false
        local pts = nil
        for i = 1, select("#", ...) do
            pts = as_points((select(i, ...)))
            if pts then break end
        end
        if pts and #pts >= 2 then
            chase.key, chase.t, chase.pts = want, izi.now(), pts
        end
    end)
    if not ok then chase.pending = false end
    return have and chase.pts or nil
end

-- ----------------------------------------------------------------------------
-- 5. KITE / FLEE POINTS  (nav_client.kite / flee)
-- ----------------------------------------------------------------------------
-- A mesh-aware retreat spot for the combat retreat. The answer is used while
-- fresh (ESCAPE_FRESH); a new one is asked at most every ESCAPE_GAP. nil
-- means "use the geometric fallback".
local ESCAPE_GAP, ESCAPE_FRESH = 1.0, 1.5
local escape = { t = -1e9, asked = -1e9, p = nil }

local function escape_request(method, a, b)
    local nav = nav_service()
    if not nav or type(nav[method]) ~= "function" then return end
    escape.asked = izi.now()
    pcall(nav[method], nav, a, b, function(...)
        for i = 1, select("#", ...) do
            local p = as_point((select(i, ...)))
            if p then
                escape.p, escape.t = p, izi.now()
                return
            end
        end
    end)
end

local function escape_point(method, a, b)
    local now = izi.now()
    if escape.p and (now - escape.t) <= ESCAPE_FRESH then
        return escape.p
    end
    if (now - escape.asked) >= ESCAPE_GAP then
        escape_request(method, a, b)
    end
    return nil
end

--- Where to step to keep `target_pos` at range (one target).
function N.kite_point(player_pos, target_pos)
    local px, py, pz = xyz(player_pos)
    local tx, ty, tz = xyz(target_pos)
    if not px or not tx then return nil end
    return escape_point("kite", vec3.new(px, py, pz), vec3.new(tx, ty, tz))
end

--- Where to run from several threats (positions).
function N.flee_point(player_pos, threats)
    local px, py, pz = xyz(player_pos)
    if not px or type(threats) ~= "table" or #threats == 0 then return nil end
    local list = {}
    for i = 1, #threats do
        local x, y, z = xyz(threats[i])
        if x then list[#list + 1] = vec3.new(x, y, z) end
    end
    if #list == 0 then return nil end
    return escape_point("flee", vec3.new(px, py, pz), list)
end


-- ----------------------------------------------------------------------------
-- CACHE RESET (2.219.0) - a continent change (movement/sentinel_adv.lua)
-- ----------------------------------------------------------------------------
-- Every answer cached here is keyed by x / y only, and WoW coordinates repeat
-- on every continent: a reach verdict, a planned path or a failed destination
-- from the last continent would be applied to a different place.
function N.reset_caches()
    reach, reach_n, reach_next = {}, 0, 0
    ray.clear, ray.t, ray.asked = nil, -1e9, -1e9
    av.pts, av.pending, av.asked = nil, false, -1e9
    chk.key, chk.ok, chk.pending = nil, nil, false
    pre.pts, pre.pending, pre.asked = nil, false, -1e9
    chase.key, chase.pts, chase.pending = nil, nil, false
    ar = { dest = nil }
    corr_key = nil
    R.sn_fail = nil
    local ok_t, Tr = pcall(require, "movement/terrain")   -- 2.221.0
    if ok_t and type(Tr) == "table" and type(Tr.reset) == "function" then Tr.reset() end
end

return N
