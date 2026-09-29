-- ============================================================================
-- Master Farmer - Grindbot
-- movement/sentinel.lua - actuator: Sentinel navmesh fallback (out of combat)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.122.0
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

local P_DEST = R.P_DEST

local N = {}

local function read_client(t) return t.client end

-- ============================================================================
-- STOP
-- ============================================================================
function N.stop()
    if not R.sn_active then return false end
    local c = R.sn_client
    if type(c) == "table" then pcall(c.stop, c) end
    R.sn_active, R.sn_reason = false, nil
    R.sn_leash_hold = false
    R.sn_watch_t = 0
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
        R.sn_active, R.sn_reason = false, r
        R.sn_leash_hold = false
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
        -- Sentinel exhausted its recovery. Hand back to the walker, but do
        -- NOT blacklist anything here.
        --
        -- This used to blacklist the DESTINATION, which is the one place we
        -- know is not the obstruction: failing to reach a quest giver would
        -- blacklist the quest giver. Sentinel's own AddAvoidanceZone puts the
        -- zone at obstacles.last_hit, or the player's position when there is
        -- no hit - the place actually blocked - and it owns that memory.
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
local function on_sn_stuck()
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
    R.sn_recovering = false
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
            if ok1 or ok2 or ok3 then
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
    if not okA or avail ~= true then return nil end
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
-- TIGHT PATHS INDOORS (2.96.0)
-- ----------------------------------------------------------------------------
-- Sentinel shapes its paths from its own config (get_path_opts): variation /
-- humanising and corridor width that look natural outdoors but walk the
-- character into door frames and walls inside buildings, caves and mines.
-- Indoors (player:is_indoors) each move_to gets a copy of those options with
--   * every numeric key named like variation / jitter / random / deviation /
--     wander / spread / noise / humaniz set to 0 (booleans to false)
--   * every corridor / path width capped at TIGHT_WIDTH yards
-- update_config is not used: Sentinel's UI rewrites it every frame. The key
-- names are not documented, so the first time the options are read they are
-- written to the session log (trail "sentinel").
local TIGHT_WIDTH = 1.0
local opts_logged = false

local function loose_key(k)
    k = tostring(k):lower()
    return k:find("variation", 1, true) or k:find("jitter", 1, true) or k:find("random", 1, true)
        or k:find("deviation", 1, true) or k:find("wander", 1, true) or k:find("spread", 1, true)
        or k:find("noise", 1, true) or k:find("humaniz", 1, true)
end

local function width_key(k)
    k = tostring(k):lower()
    return (k:find("corridor", 1, true) or k:find("path", 1, true)) and
        (k:find("width", 1, true) or k:find("margin", 1, true))
end

local function log_opts(c)
    if opts_logged then return end
    opts_logged = true
    local ok_e, el = pcall(require, "errorlog")
    if not (ok_e and type(el) == "table" and type(el.trail) == "function") then return end
    for _, name in ipairs({ "get_path_opts", "get_corridor_opts" }) do
        local ok, t = pcall(c[name], c)
        if ok and type(t) == "table" then
            local parts = {}
            for k, v in pairs(t) do
                if type(v) ~= "table" and type(v) ~= "function" then
                    parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
                end
            end
            table.sort(parts)
            pcall(el.trail, "sentinel", "%s: %s", name, table.concat(parts, " "))
        end
    end
end

-- LOOSE HEIGHT (2.112.0). The server finds a destination's polygon in three
-- tiers, (6,6,3) (10,10,6) (50,50,50) yards; its docs say to pass z_extent
-- when a position's height is imprecise. A quest waypoint whose height is
-- still the player's own (no navmesh answer yet) is flagged z_loose and gets
-- a wide vertical search instead of a 422.
local LOOSE_Z_EXTENT = 250

-- AVOID DANGEROUS MOBS (2.118.0). targeting.scan_enemies keeps a danger map
-- of mobs too high to fight (movement/zones, R.danger: { x, y, z, r }). It
-- only steered the walker; Sentinel planned straight through their aggro
-- radius. Each leg now carries them as avoid_zones - Sentinel's own per-move
-- option ({ x, y, z, radius, cost }, merged with its obstacle zones and sent
-- as a path-avoid request) - the AVOID_MAX nearest within AVOID_RANGE of the
-- player. A zone that contains the destination is left out: walking up to a
-- quest giver standing next to an elite is still allowed.
local AVOID_MAX = 8
local AVOID_RANGE = 200
local AVOID_COST = 100

local function avoid_zones(p)
    local list = R.danger
    if type(list) ~= "table" or #list == 0 then return nil end
    local me = nil
    pcall(function() me = izi.me():get_position() end)
    if not me then return nil end
    local picked = {}
    for i = 1, #list do
        local d = list[i]
        if type(d) == "table" and type(d.x) == "number" and type(d.r) == "number" then
            local dx, dy = d.x - me.x, d.y - me.y
            local dist = math.sqrt(dx * dx + dy * dy)
            local ex, ey = p and (d.x - p.x) or 1e9, p and (d.y - p.y) or 1e9
            local holds_dest = ex * ex + ey * ey <= d.r * d.r
            if dist <= AVOID_RANGE and not holds_dest then
                picked[#picked + 1] = { dist = dist, zone = { x = d.x, y = d.y, z = d.z or me.z,
                    radius = d.r, cost = AVOID_COST } }
            end
        end
    end
    if #picked == 0 then return nil end
    table.sort(picked, function(a, b) return a.dist < b.dist end)
    local out = {}
    for i = 1, math.min(AVOID_MAX, #picked) do out[i] = picked[i].zone end
    return out
end

--- move_to options for this leg, or nil (Sentinel's own defaults).
local function leg_opts(c, p)
    log_opts(c)
    local loose = type(p) == "table" and rawget(p, "z_loose") == true
    local zones = avoid_zones(p)
    local extra = nil
    if loose or zones then
        extra = { z_extent = loose and LOOSE_Z_EXTENT or nil, avoid_zones = zones }
    end
    local indoors = false
    pcall(function() indoors = izi.me():is_indoors() == true end)
    if not indoors or type(c.get_path_opts) ~= "function" then return extra end
    local ok, base = pcall(c.get_path_opts, c)
    if not ok or type(base) ~= "table" then return extra end
    local out = {}
    for k, v in pairs(base) do
        if loose_key(k) and type(v) == "number" then
            out[k] = 0
        elseif loose_key(k) and type(v) == "boolean" then
            out[k] = false
        elseif width_key(k) and type(v) == "number" and v > TIGHT_WIDTH then
            out[k] = TIGHT_WIDTH
        else
            out[k] = v
        end
    end
    R.sn_tight = true
    if extra then
        out.z_extent = extra.z_extent
        out.avoid_zones = extra.avoid_zones
    end
    return out
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
    R.sn_last_issue_t = now
    R.sn_issued = R.sn_issued + 1
    local okl, elog = pcall(require, "errorlog")
    if okl and type(elog) == "table" then
        elog.probe("sentinel move_to " .. tostring(why or ""))
    end
    W.halt()
    W.begin_issue(p.x, p.y, p.z)
    R.sn_active, R.sn_reason = true, nil
    R.sn_why = why                -- what the leg is for (2.54.0): "pull", "travel", ...
    R.sn_leash_hold = true
    R.sn_watch_t = izi.now()
    R.sn_tight = false
    local opts = leg_opts(c, p)
    local ok
    if opts then
        ok = pcall(c.move_to, c, to_vec3(p), on_nav_done, opts)
    else
        ok = pcall(c.move_to, c, to_vec3(p), on_nav_done)
    end
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
-- RETARGET WITHOUT STOPPING (2.118.0)
-- ============================================================================
-- Sentinel's move_to takes opts.soft_update: while it is already moving, the
-- new destination is set and a soft repath is requested, and movement keeps
-- running (Client.lua, "seamless retarget"). It replaces the old re-aim,
-- which planned a separate path in the background and switched to it with
-- follow_path. Same one-request-per-SN_MIN_GAP limit as every other request.
function N.retarget(p, why)
    if not R.sn_active or R.cur_owner == OWNER.COMBAT then return false end
    local now = izi.now()
    if (now - R.sn_last_issue_t) < SN_MIN_GAP then return false end
    local c = client()
    if not c or type(p) ~= "table" or not xyz(p) then return false end
    local opts = leg_opts(c, p) or {}
    opts.soft_update = true
    R.sn_last_issue_t = now
    R.sn_issued = R.sn_issued + 1
    local ok = pcall(c.move_to, c, to_vec3(p), on_nav_done, opts)
    if not ok then return false end
    W.begin_issue(p.x, p.y, p.z)
    R.sn_active = true
    R.sn_why = why or R.sn_why
    dlog("issue", string.format("sentinel retarget -> (%.1f, %.1f, %.1f)", p.x, p.y, p.z))
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
local SN_STALL_SEC = 4.0

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
    local c = R.sn_client
    if type(c) ~= "table" or type(c.get_full_state) ~= "function" then return false end
    local ok, st = pcall(c.get_full_state, c)
    -- awaiting_path, repathing and deferred (a move_to made while casting)
    -- are all "path not in hand yet" - the grouping Sentinel's own questing
    -- adapter uses (2.112.0).
    if not ok or type(st) ~= "string"
        or not (st:find("awaiting", 1, true) or st:find("repathing", 1, true) or st:find("deferred", 1, true)) then
        plan_since = nil
        return false
    end
    local t = izi.now()
    plan_since = plan_since or t
    return (t - plan_since) < SN_PLAN_MAX
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
    if casting or not pos or N.planning() then
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
        N.stop()
        W.clear_dest()
        return
    end
    if not R.sn_active then
        stall_x, stall_y = nil, nil
    end
    local c = R.sn_client
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
    if #pts < 2 then return false end
    R.sn_last_issue_t = now
    R.sn_issued = R.sn_issued + 1
    local last = pts[#pts]
    W.halt()
    W.begin_issue(last.x, last.y, last.z)
    R.sn_active, R.sn_reason = true, nil
    R.sn_why = why or "path"
    R.sn_leash_hold = true
    R.sn_watch_t = now
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
                pre.pts, pre.t, pre.gx, pre.gy = pts, izi.now(), gx, gy
                return
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
