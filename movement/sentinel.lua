-- ============================================================================
-- Master Farmer - Grindbot
-- movement/sentinel.lua - actuator: Sentinel navmesh fallback (out of combat)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.215.0
-- ============================================================================
-- Optional. Used for long legs, blocked straight lines and stuck recovery.
-- When the client is absent every caller silently degrades to walker steering,
-- so nothing in the plugin may treat Sentinel as required.
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

local function in_flight(c)
    if type(c) ~= "table" or type(c.get_full_state) ~= "function" then return false end
    local ok, st = pcall(c.get_full_state, c)
    return ok and type(st) == "string"
        and (st:find("awaiting", 1, true) ~= nil or st:find("repathing", 1, true) ~= nil)
end

--- Send a deferred stop once the path request has come back. Per frame.
function N.flush_stop(t)
    local p = stop_pending
    if not p then return end
    if in_flight(p.client) and (t - p.since) < STOP_WAIT_MAX then return end
    stop_pending = nil
    pcall(p.client.stop, p.client)
    dlog("sentinel", "deferred stop sent")
end

function N.stop()
    if not R.sn_active then return false end
    local c = R.sn_client
    if type(c) == "table" then
        if in_flight(c) then
            stop_pending = { client = c, since = izi.now() }
            dlog("sentinel", "stop deferred - path request still in flight")
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
    max_stuck_exceeded = true, max_repath_exceeded = true }

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

local chain_busy = false
local try_random_unstick

function N.on_nav_done(ok, reason, detail)
    if not R.sn_active then return end           -- stale: we already stopped/switched
    local r, msg = "arrived", ""
    if ok ~= true then
        r, msg = fail_code(reason, detail)
        local ok_e, el = pcall(require, "errorlog")
        if ok_e and type(el) == "table" and type(el.trail) == "function" then
            pcall(el.trail, "sentinel", "leg '%s' failed: %s (%s)", tostring(R.sn_why or ""), r, msg)
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
    -- Remember the failed destination (2.109.0): Sentinel-only travel does not
    -- re-request it for K.SN_FAIL_HOLD seconds.
    if R.has_dest then
        R.sn_fail = { x = R.dest_x, y = R.dest_y, t = izi.now(), reason = r, detail = msg }
    end
    if r == "unreachable" or r == "max_repath_exceeded" then
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
        dlog("sentinel", "stuck detected, obstacle to the " .. side
            .. " - Sentinel is recovering, holding")
    else
        dlog("sentinel", "stuck detected - Sentinel is recovering, holding")
    end
end

--- Recovery worked and navigation continues.
local function on_sn_recovered()
    N.end_recovery()
    dlog("sentinel", "stuck recovered")
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

--- Subscribe to Sentinel's navigation events.
---
--- TWO NAMING SCHEMES, AND THEY ARE NOT INTERCHANGEABLE.
---   client:on(...)        legacy compatibility: "state_change", "arrived",
---                         "stuck", "failed"
---   get_event_bus():on()  namespaced: nav.state_changed, nav.arrived,
---                         nav.stuck_detected, nav.stuck_recovered, nav.failed
---
--- The bus branch used to subscribe to the bare "stuck" and "failed". Those
--- keys are never emitted on the bus, so it bound to nothing - and because
--- bus:on happily registers a subscription for an event that never fires,
--- the pcall succeeded and sn_events was set, so the silence looked like
--- success. Sentinel's stuck and failure reports simply never arrived.
---
--- The bus is preferred now: it carries stuck_recovered, which the legacy
--- event set has no equivalent for.
local function bind_sn_events(c)
    if R.sn_events or type(c) ~= "table" then return end

    if type(c.get_event_bus) == "function" then
        local okB, bus = pcall(c.get_event_bus, c)
        if okB and type(bus) == "table" and type(bus.on) == "function" then
            local opts = { owner = N }
            local ok1 = pcall(bus.on, bus, "nav.stuck_detected", on_sn_stuck, opts)
            local ok2 = pcall(bus.on, bus, "nav.stuck_recovered", on_sn_recovered, opts)
            local ok3 = pcall(bus.on, bus, "nav.failed", on_sn_failed, opts)
            local ok4 = pcall(bus.on, bus, "nav.deviation_detected", function()
                dlog("sentinel", "path deviation detected")
            end, opts)
            if ok1 or ok2 or ok3 or ok4 then
                R.sn_events = true
                return
            end
        end
    end

    -- Older build with no bus: the legacy names are the right ones there.
    if type(c.on) == "function" then
        local ok1 = pcall(c.on, c, "stuck", on_sn_stuck)
        local ok2 = pcall(c.on, c, "failed", on_sn_failed)
        R.sn_events = ok1 == true or ok2 == true
    end
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

local function on_health(ok)
    if ok == true then
        R.sn_checked_t = -1e9
        dlog("sentinel", "server reachable again")
    end
end

--- Resolve the Sentinel client, re-probed at most every 5s. nil = unavailable,
--- in which case every caller silently falls back to walker steering.
function N.client()
    local t = izi.now()
    if (t - R.sn_checked_t) < 5 then return R.sn_ok and R.sn_client or nil end
    R.sn_checked_t = t
    R.sn_ok, R.sn_client = false, nil
    local S = rawget(_G, "SentinelNavClient")
    if type(S) ~= "table" then return nil end
    local ok, c = pcall(read_client, S)
    if not ok or type(c) ~= "table" then return nil end
    for i = 1, #SN_NEED do
        if type(c[SN_NEED[i]]) ~= "function" then return nil end
    end
    local okA, avail = pcall(c.is_server_available, c)
    if not okA or avail ~= true then
        if okA and type(c.health_check) == "function" and (t - health_asked) >= HEALTH_GAP then
            health_asked = t
            pcall(c.health_check, c, on_health)
        end
        return nil
    end
    bind_sn_events(c)
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
local AVOID_RANGE = 200
local BODY_WIDTH = 2 * K.BODY_HALF   -- the body width the obstacle traces use (1.0)

local function nav()
    local c = client()
    if not c or type(c.nav_client) ~= "table" then return nil end
    return c.nav_client
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
    local n = nav()
    if n and type(n.raycast) == "function" and (now - ray.asked) >= 1.0 then
        ray.asked = now
        pcall(n.raycast, n, vec3.new(ax, ay, az), vec3.new(bx, by, bz), function(a)
            ray.t, ray.ax, ray.ay, ray.bx, ray.by = izi.now(), ax, ay, bx, by
            ray.clear = (a == true)
        end)
    end
    if ray.clear ~= nil and ray.ax == ax and ray.ay == ay and ray.bx == bx and ray.by == by then
        return ray.clear == true
    end
    if type(walk_open) == "function" then
        return walk_open({ x = ax, y = ay, z = az }, { x = bx, y = by, z = bz }) == true
    end
    return false
end

local av = { asked = -1e9, t = -1e9, pts = nil, gx = nil, gy = nil, pending = false }

local function take_avoid_pts(from, dest, zones)
    if type(zones) ~= "table" or #zones == 0 then return nil end
    local n = nav()
    if not n or type(n.find_path_avoid) ~= "function" then return nil end
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
    local ok = pcall(n.find_path_avoid, n, vec3.new(from.x, from.y, from.z),
        vec3.new(dest.x, dest.y, dest.z), zones, function(...)
            av.pending = false
            for i = 1, select("#", ...) do
                local pts = select(i, ...)
                if type(pts) == "table" and #pts >= 2 then
                    av.pts, av.t, av.gx, av.gy = pts, izi.now(), gx, gy
                    return
                end
            end
        end)
    if not ok then av.pending = false end
    return nil
end

local chk = { key = nil, ok = nil, pending = false, asked = -1e9 }

local function path_checked(from, pts)
    local n = nav()
    if not n or type(n.check_path) ~= "function" then return true end
    if type(pts) ~= "table" or #pts < 2 then return true end
    local a, b = pts[1], pts[#pts]
    local key = string.format("%.0f|%.0f|%.0f|%.0f|%d", a.x, a.y, b.x, b.y, #pts)
    local now = izi.now()
    if chk.key == key and chk.ok ~= nil and (now - chk.asked) < 8 then
        return chk.ok == true
    end
    if chk.pending and (now - chk.asked) < 5 then return false end
    if (now - chk.asked) < 1.0 and chk.key == key then return false end
    chk.key, chk.pending, chk.asked, chk.ok = key, true, now, nil
    local ok = pcall(n.check_path, n, vec3.new(from.x, from.y, from.z), pts, function(ok_path)
        chk.pending = false
        chk.ok = ok_path == true
    end)
    if not ok then
        chk.pending, chk.ok = false, true
        return true
    end
    return false
end

local unstick_at = -1e9

try_random_unstick = function()
    local n = nav()
    if not n or type(n.random_point) ~= "function" then return false end
    local now = izi.now()
    if (now - unstick_at) < 8 then return false end
    unstick_at = now
    local gx, gy, gz = R.dest_x, R.dest_y, R.dest_z
    local ok = pcall(n.random_point, n, function(p)
        if type(p) ~= "table" or type(p.x) ~= "number" then return end
        R.sn_active = false
        if type(gx) == "number" then
            R.goal_x, R.goal_y, R.goal_z = gx, gy, gz
            R.keep_path = true
        end
        N.move({ x = p.x, y = p.y, z = p.z }, "unstick")
    end)
    if ok then
        dlog("sentinel", "max_stuck - random_point then replan")
    end
    return ok == true
end

local function begin_leg(p, why)
    local now = izi.now()
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
        if d < 30 and line_clear(hx, hy, hz, p.x, p.y, p.z) then
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
        end
    end
    W.halt()
    begin_leg(p, why)
    stop_pending = nil
    local ok = pcall(c.move_to, c, to_vec3(p), on_nav_done)
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
    local hx, hy, hz = here_xyz()
    if not hx then return false end
    local pts = N.prefetch({ x = hx, y = hy, z = hz }, p)
    if not pts or #pts < 2 then
        return true
    end
    pts = skip_near_pts(pts) or pts
    if #pts < 2 then return false end
    begin_leg({ x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z }, why or R.sn_why)
    stop_pending = nil
    local ok = pcall(c.follow_path, c, pts, on_nav_done)
    if not ok then return false end
    R.sn_active = true
    R.sn_why = why or R.sn_why
    dlog("issue", string.format("sentinel retarget follow -> (%.1f, %.1f, %.1f)", p.x, p.y, p.z))
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
    if not ok or type(st) ~= "string"
        or not (st:find("awaiting", 1, true) or st:find("repathing", 1, true)
            or st:find("deferred", 1, true) or st:find("recovering", 1, true)) then
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
        dlog("sentinel", "replan " .. tostring(reason or ""))
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

local function maybe_corridor(c)
    local indoors = false
    pcall(function() indoors = izi.me():is_indoors() == true end)
    if not indoors then return end
    if type(c.get_corridor_widths) ~= "function" then return end
    local okw, widths = pcall(c.get_corridor_widths, c)
    local oki, idx = pcall(c.get_path_index, c)
    if not okw or type(widths) ~= "table" or type(idx) ~= "number" then return end
    local w = widths[idx] or widths[idx + 1]
    if type(w) ~= "number" or w >= BODY_WIDTH then return end
    local n = nav()
    if not n or type(n.find_path_corridor) ~= "function" then return end
    local now = izi.now()
    if (now - corr_asked) < 2 then return end
    local dest = nil
    if type(c.get_destination) == "function" then
        local okd, d = pcall(c.get_destination, c)
        if okd then dest = d end
    end
    local hx, hy, hz = here_xyz()
    if not hx or type(dest) ~= "table" or type(dest.x) ~= "number" then return end
    local key = string.format("%d|%d", math.floor(dest.x / 4), math.floor(dest.y / 4))
    if key == corr_key then return end
    corr_key = key
    corr_asked = now
    pcall(n.find_path_corridor, n, vec3.new(hx, hy, hz), vec3.new(dest.x, dest.y, dest.z), function(...)
        for i = 1, select("#", ...) do
            local pts = select(i, ...)
            if type(pts) == "table" and #pts >= 2 then
                N.follow(pts, "corridor")
                return
            end
        end
    end)
end

--- Sentinel's current waypoint is under the player: skip it. 1-yard densify
--- points were walked as dests and the character orbited them.
local function skip_near_wp(c)
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
    local last = rest[#rest]
    W.begin_issue(last.x, last.y, last.z)
    pcall(c.follow_path, c, rest, on_nav_done)
    dlog("sentinel", "skipped underfoot waypoint")
end

function N.watch(t)
    if (t - R.sn_watch_t) < 1.0 then return end
    R.sn_watch_t = t
    if R.sn_active and stall_check(t) then
        local why = tostring(R.sn_why or "")
        dlog("sentinel", "leg '" .. why .. "' stalled - dropped")
        local ok_e, el = pcall(require, "errorlog")
        if ok_e and type(el) == "table" and type(el.trail) == "function" then
            pcall(el.trail, "move", "Sentinel leg '%s' made no progress for %.0fs - dropped", why, SN_STALL_SEC)
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
    local c = client()
    if not c or type(c.nav_client) ~= "table" then return nil end
    return c.nav_client
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
function N.reachable(pos)
    local x, y, z = xyz(pos)
    if not x then return true end
    local key = reach_key(x, y)
    local now = izi.now()
    local e = reach[key]
    if e and (now - e.t) < REACH_TTL then
        return e.ok ~= false
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

--- Plan to `p` around the blacklisted areas and follow it. True when asked.
function N.repath_around(p, why)
    local px, py, pz = xyz(p)
    if not px or R.cur_owner == OWNER.COMBAT then return false end
    why = why or "stuck_avoid"
    local n = nav()
    local zones = danger_zones({ x = px, y = py, z = pz })
    local hx, hy, hz = here_xyz()
    if n and type(n.find_path_avoid) == "function" and zones and hx then
        local job = { dest = { x = px, y = py, z = pz }, asked = izi.now(), pts = nil, why = why }
        ar = job
        local ok = pcall(n.find_path_avoid, n, vec3.new(hx, hy, hz), vec3.new(px, py, pz), zones, function(...)
            for i = 1, select("#", ...) do
                local pts = as_points((select(i, ...)))
                if pts and #pts >= 2 then
                    job.pts = pts
                    return
                end
            end
            job.failed = true
        end)
        if ok then
            dlog("sentinel", string.format("re-path around %d blacklisted area(s) -> (%.0f, %.0f)", #zones, px, py))
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
    local ok = pcall(nav.find_path, nav, vec3.new(fx, fy, fz), vec3.new(tx, ty, tz), function(...)
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
    local ok = pcall(nav.find_path, nav, vec3.new(fx, fy, fz), vec3.new(tx, ty, tz), function(...)
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


return N
