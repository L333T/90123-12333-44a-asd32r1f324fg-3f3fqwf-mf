-- ============================================================================
-- Master Farmer - Grindbot
-- movement/nav.lua - travel through AmeisenNav
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.1
-- ============================================================================
-- Every walk is _G.AmeisenNav.client's (docs/API.md, AmeisenNav 2.0.0):
--   move_to(target, cb, { allow_partial, seamless })  pathfind and walk
--   follow_path(waypoints, cb)                         a recorded route
--   stop(reason) / pause(reason) / resume(reason)
--   get_height(pos, cb, { probe_up })                  ground under a point
--   validate_destination(target, cb) / plan_route(nodes, cb) / find_path
-- cb(ok, reason, detail) is called once; detail.code says why it ended.
--
-- SEAMLESS RETARGET: a new destination while a walk runs is handed over with
-- { seamless = true } - the running walk takes the new path without
-- releasing a key (no stop / start stutter). The same destination (within
-- SAME_DEST yd) while walking is a no-op, so callers can ask every tick.
--
-- GUESSED HEIGHTS (RestedXP waypoints are x, y only): a no-path answer for a
-- point within HEIGHT_RANGE yd asks AmeisenNav for the ground there
-- (client:get_height, probe from 60 yd up) and walks again at that height,
-- once per destination. The height found is kept (N.reach_z) for the route.
--
-- FAILURES: the code of the last failed walk is kept (last_fail_reason /
-- last_fail_offmesh). The same destination failing FAIL_BLACKLIST times in
-- FAIL_WINDOW s is blacklisted (movement/zones), so callers move on.
--
-- NO AMEISENNAV: the bot still moves - straight walks with simple_movement,
-- driven here every frame - and warns once.
--
-- EXACT-PATH WALKS (3.7.0, every mode but "combat"; recorded routes keep
-- follow_route): ONE find_path per destination, walked exactly as 5-yard
-- waypoints with follow_path. The path is prepared 15 yd ahead of the player
-- at a time (objects, walls, indoors - movement/guide_path; one batched server
-- request per window, client reads rate-limited, nothing per frame); the walk
-- is handed a changed window only when a check moved a waypoint (a restart is
-- a walker stop - at most every RESTART_GAP s). Combat walks keep move_to
-- with seamless retargets (a moving target). (3.5.0 - 3.6.1: RestedXP walks
-- only, 3-yard waypoints.)
-- ============================================================================

local R = require("movement/core")
local Z = require("movement/zones")
local GP = require("movement/guide_path")
local MT = require("movement/mount")         -- 3.8.0: mount for travel (the 1-60 way)

local N = {}

local SAME_DEST = 2.0          -- yd: the same destination
local RETARGET_GAP = 0.25      -- s between two seamless retargets
local UNDERFOOT = 1.0          -- yd: a destination this close is reached
local QUIET_STOP = 0.3         -- s callers wait after a real stop (is_quiet)
local HEIGHT_RANGE = 150       -- yd: the ground under nearer points can be read
local HEIGHT_PROBE_UP = 60
-- 3.0.6: the ground is looked for just above the guessed height first; only
-- when nothing is found there is it read from HEIGHT_PROBE_UP above. From 60
-- yd up the probe hit the hill over the Silver Stream Mine (z 366, the mine
-- floor ~320) and the route walked the hilltop (log 2026-10-12 10:36).
local HEIGHT_PROBE_NEAR = 8
local FAIL_WINDOW, FAIL_BLACKLIST = 120, 2
local REACH_TTL, REACH_TTL_BAD, REACH_GAP = 120, 45, 0.25
local REACH_TRUST_FAR = 150    -- yd: farther answers are guesses, never "unreachable"

local REPLAN_GAP = 2.0         -- s: at most one object re-plan of a guide walk this often
local OFFMESH = { start_off_mesh = true, end_off_mesh = true, no_path = true, unreachable = true,
    map_not_loaded = true }
local HEIGHT_RETRY = { no_path = true, end_off_mesh = true, unreachable = true }

-- the walk this layer asked for
local cur = { id = 0, x = nil, y = nil, z = nil, mode = nil, t = 0, route = nil }
-- the guide walk (mode "guide"): planning = a find_path / check is out
local guide = { planning = false, next_check = 0, replan_at = 0, full = nil, base = 1, done_to = 0,
    processing = false, dirty = false, restart_at = 0, known = {} }
GP.stats = { walks = 0, replans = 0, pushed = 0, fallbacks = 0 }
local fail = { reason = nil, offmesh = false, t = 0 }
local fails_at = {}            -- dest key -> { n, t }
local zfix = {}                -- dest key -> corrected z
local stats = { issued = 0, refused = 0 }
N.stats = stats

-- 3.0.0: fails_at / zfix are keyed per destination and would grow for a
-- whole session; past CACHE_MAX keys each is emptied (both are re-learnt).
local CACHE_MAX = 256
local cache_n = { fails = 0, zfix = 0 }
local function cache_put(tbl, which, k, v)
    if tbl[k] == nil then
        cache_n[which] = cache_n[which] + 1
        if cache_n[which] > CACHE_MAX then
            for key in pairs(tbl) do tbl[key] = nil end
            cache_n[which] = 1
        end
    end
    tbl[k] = v
end

local warned_no_nav = false
local fallback_walker = nil

-- ----------------------------------------------------------------------------
-- the client
-- ----------------------------------------------------------------------------
function N.client()
    local g = rawget(_G, "ArthasNav")
    local c = type(g) == "table" and g.client or nil
    if c == nil and not warned_no_nav then
        warned_no_nav = true
        R.log("MasterArthasNav not loaded - walking straight lines without the navmesh "
            .. "(install MasterArthasNav (MasterArthasNav-Setup.exe) and reload)")
    end
    if c ~= nil then warned_no_nav = false end
    return c
end

local function call(c, name, ...)
    local f = c and c[name]
    if type(f) ~= "function" then return false end
    return pcall(f, c, ...)
end

local function walker()
    if fallback_walker == nil then
        local ok, w = pcall(require, "common/utility/simple_movement")
        fallback_walker = (ok and w) and w or false
    end
    return fallback_walker or nil
end

local function key_of(x, y)
    return string.format("%d|%d", math.floor(x / 4), math.floor(y / 4))
end

local function vec(x, y, z)
    local ok, v = pcall(require, "common/geometry/vector_3")
    if ok and type(v) == "table" and type(v.new) == "function" then return v.new(x, y, z) end
    return { x = x, y = y, z = z }
end

-- ----------------------------------------------------------------------------
-- gates: who may start a walk now
-- ----------------------------------------------------------------------------
--- Why travel is refused now, or nil. Combat owns the player while a fight
--- asks for it every tick (movement/combat sets R.combat_until); a rest or a
--- backpedal holds everything.
function N.refusal()
    if R.resting then return "resting" end
    if R.backpedal_until then return "backpedal" end
    if (R.combat_until or 0) > R.now() then return "combat" end
    -- 3.0.2: standing at an NPC (movement.interact) - its window / gossip /
    -- purchase gets NPC_HOLD s before any walk starts again
    if (R.npc_until or 0) > R.now() then
        -- the game answered "too far away": nothing opened, the caller walks
        -- up to the NPC - the hold is lifted for that walk
        local ev = package.loaded["events"]
        if R.npc_ev_t and type(ev) == "table" and type(ev.too_far_since) == "function"
            and ev.too_far_since(R.npc_ev_t) == true then
            R.npc_until, R.npc_ev_t = nil, nil
            return nil
        end
        return "npc"
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- state
-- ----------------------------------------------------------------------------
function N.busy()
    local c = N.client()
    if c then
        local ok, b = call(c, "is_busy")
        return ok and b == true
    end
    local w = walker()
    if w then
        local ok, m = pcall(w.is_moving, w)
        return ok and m == true
    end
    return false
end

function N.destination()
    if cur.x and N.busy() then return cur.x, cur.y, cur.z end
    return nil
end

function N.mode() return N.busy() and cur.mode or nil end

local function record_fail(code, x, y, z)
    fail.reason, fail.offmesh, fail.t = tostring(code or "failed"), OFFMESH[code] == true, R.now()
    if not x then return end
    local k = key_of(x, y)
    local e = fails_at[k]
    local t = R.now()
    if not e or (t - e.t) > FAIL_WINDOW then e = { n = 0, t = t } cache_put(fails_at, "fails", k, e) end
    e.n, e.t = e.n + 1, t
    if e.n >= FAIL_BLACKLIST and fail.offmesh then
        Z.blacklist_area({ x = x, y = y, z = z }, 6, "no path there (" .. fail.reason .. ")")
        fails_at[k] = nil
    end
end

-- ----------------------------------------------------------------------------
-- fresh legs (3.7.1, crash logs 2026-10-16 17:30 - 18:06)
-- ----------------------------------------------------------------------------
-- Every crash came 0.6 - 1.6 s after a walk leg started, and 2.181.0 already
-- found stopping a fresh leg to be the common factor. A leg is "fresh" for
-- FRESH_LEG s; movement/pivot does not hold one, and no new leg starts while
-- a sharp turn is being made (R.turning) - the next leg starts after it,
-- facing the right way.
local FRESH_LEG = 1.0
local FALSE_ARRIVAL = 5.0      -- yd: an "arrived" farther from the goal is not one

--- Seconds since the running leg started (huge when none runs).
function N.leg_age()
    if not cur.leg_t or not N.busy() then return 1e9 end
    return R.now() - cur.leg_t
end
function N.leg_fresh() return N.leg_age() < FRESH_LEG end

--- MasterArthasNav answered "arrived" for a walk paused by the sharp-turn
--- stop, far from the goal (log 2026-10-16 18:06: "arrived after 2.4s", 305
--- yd short). Logged once per leg; such a leg is not counted as arrived.
function N.false_arrival(x, y)
    local hx, hy = R.here()
    if not hx or not x then return false end
    local d = R.dist2(hx, hy, x, y)
    if d <= FALSE_ARRIVAL then return false end
    R.trail("nav", "walk ended as 'arrived' %.0f yd short of (%.0f, %.0f) - not counted", d, x, y)
    return true
end

-- ----------------------------------------------------------------------------
-- issuing walks
-- ----------------------------------------------------------------------------
local issue_move

--- The ground at (x, y) nearest the guessed z: probed from just above it, then
--- from HEIGHT_PROBE_UP above. cb(ok, z). True when the query went out.
local function ground_near(c, x, y, z, cb)
    return call(c, "get_height", { x = x, y = y, z = z }, function(ok, hz)
        if ok and R.finite(hz) then cb(true, hz) return end
        local sent = call(c, "get_height", { x = x, y = y, z = z }, cb, { probe_up = HEIGHT_PROBE_UP })
        if not sent then cb(false) end
    end, { probe_up = HEIGHT_PROBE_NEAR }) == true
end

--- AmeisenNav found no path to (x, y, z): read the ground there and walk again
--- at that height, once per destination.
local function retry_at_ground(c, id, x, y, z, code, opts)
    local hx, hy = R.here()
    if not hx or R.dist2(hx, hy, x, y) > HEIGHT_RANGE then return false end
    local k = key_of(x, y)
    if zfix[k] ~= nil then return false end
    cache_put(zfix, "zfix", k, false)             -- asked once
    local ok = ground_near(c, x, y, z, function(okh, hz)
        if cur.id ~= id then return end           -- superseded meanwhile
        if okh and R.finite(hz) and math.abs(hz - z) > 2 then
            zfix[k] = hz
            R.trail("nav", "(%.0f, %.0f): no path at z %.1f (%s) - walking again at the ground, z %.1f",
                x, y, z, tostring(code), hz)
            issue_move(c, x, y, hz, opts)
        else
            record_fail(code, x, y, z)
        end
    end)
    return ok == true
end

issue_move = function(c, x, y, z, opts)
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.exact = x, y, z, R.now(), opts.mode or "move", nil, nil
    cur.leg_t = R.now()
    stats.issued = stats.issued + 1
    local ok = call(c, "move_to", { x = x, y = y, z = z }, function(arrived, _, detail)
        if cur.id ~= id then return end
        local code = type(detail) == "table" and detail.code or nil
        if arrived and N.false_arrival(x, y) then return end
        if arrived then
            fail.reason, fail.offmesh = nil, false
            return
        end
        if code == "cancelled" then return end
        if HEIGHT_RETRY[code] and retry_at_ground(c, id, x, y, z, code, opts) then return end
        R.trail("nav", "walk to (%.0f, %.0f, %.0f) ended: %s", x, y, z, tostring(code))
        record_fail(code, x, y, z)
    end, { allow_partial = opts.allow_partial ~= false, seamless = opts.seamless == true })
    return ok == true
end

--- An exact-path walk (3.7.0, movement/guide_path header): ONE find_path ->
--- 5-yard waypoints -> the first 15 yd window prepared (objects, walls, one
--- batched server request) -> follow_path. While it runs, guide_recheck keeps
--- at least HORIZON yd of prepared path ahead of the player. Falls back to a
--- plain move_to when the client cannot plan or no path comes back.
local RESTART_GAP = 1.5        -- s: at most one walk restart (a changed window) this often

local function nav_table() return rawget(_G, "ArthasNav") end

--- follow_path from guide.full[from] to the end; guide.base maps the client's
--- path index back onto guide.full.
local function start_walk(c, id, from)
    local list = {}
    for i = math.max(1, from), #guide.full do list[#list + 1] = guide.full[i] end
    if #list < 1 then return false end
    guide.base = math.max(1, from)
    cur.leg_t = R.now()
    local x, y, z = cur.x, cur.y, cur.z
    local okf = call(c, "follow_path", list, function(arrived, _, detail)
        if cur.id ~= id then return end
        if arrived and N.false_arrival(x, y) then return end
        if arrived then fail.reason, fail.offmesh = nil, false return end
        local code = type(detail) == "table" and detail.code or nil
        if code == "cancelled" then return end
        if HEIGHT_RETRY[code] and retry_at_ground(c, id, x, y, z, code, { mode = "move" }) then return end
        R.trail("nav", "exact walk to (%.0f, %.0f, %.0f) ended: %s", x, y, z, tostring(code))
        record_fail(code, x, y, z)
    end)
    return okf == true
end

local function guide_move(c, x, y, z, mode)
    mode = mode or "move"
    if type(c.find_path) ~= "function" or type(c.follow_path) ~= "function" then
        return issue_move(c, x, y, z, { seamless = N.busy(), mode = mode })
    end
    local hx, hy, hz = R.here()
    if not hx then return false end
    cur.id = cur.id + 1
    local id = cur.id
    -- the caller's mode is kept (movement.interact walks up as "npc"); cur.exact
    -- marks the exact-path walk
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.exact = x, y, z, R.now(), mode, nil, true
    guide.planning, guide.full, guide.processing, guide.dirty = true, nil, false, false
    stats.issued = stats.issued + 1
    local function fallback()
        guide.planning, guide.full = false, nil
        GP.stats.fallbacks = GP.stats.fallbacks + 1
        if cur.id == id then issue_move(c, x, y, z, { seamless = N.busy(), mode = mode }) end
    end
    local sent = call(c, "find_path", { x = hx, y = hy, z = hz }, { x = x, y = y, z = z }, function(ok, points, info)
        if cur.id ~= id then return end                 -- a newer walk replaced this one
        -- 3.7.1: a partial path (the server stops short) is walked too, as
        -- move_to's allow_partial does - it used to fall back to move_to
        local partial = type(info) == "table" and info.partial == true
        if type(points) ~= "table" or #points < 2 or not (ok or partial) then
            R.trail("nav", "exact walk to (%.0f, %.0f, %.0f): find_path ok=%s points=%s code=%s partial=%s - walking move_to",
                x, y, z, tostring(ok), tostring(type(points) == "table" and #points or nil),
                tostring(type(info) == "table" and info.code or nil), tostring(partial))
            return fallback()
        end
        local pts = GP.resample(points, GP.SPACING)
        if not partial then
            pts[#pts] = { x = x, y = y, z = pts[#pts].z }  -- the destination itself, never moved
        end
        guide.full, guide.base, guide.done_to = pts, 1, 0
        local objs = GP.objects(hx, hy, hz)
        guide.known = GP.snapshot(objs)
        local w = GP.window_end(pts, 1)
        guide.processing = true
        GP.process_window(nav_table(), pts, 1, w, objs, GP.indoors(), function(changed)
            if cur.id ~= id then return end
            guide.processing, guide.planning, guide.done_to = false, false, w
            GP.stats.pushed = GP.stats.pushed + changed
            GP.stats.windows = (GP.stats.windows or 0) + 1
            guide.next_check = R.now() + GP.RECHECK_GAP
            guide.restart_at = R.now() + RESTART_GAP
            GP.stats.walks = GP.stats.walks + 1
            if not start_walk(c, id, 1) then fallback() end
        end)
    end)
    if sent ~= true then
        guide.planning = false
        return issue_move(c, x, y, z, { seamless = N.busy(), mode = mode })
    end
    return true
end

--- While an exact walk runs (every GP.RECHECK_GAP s; client reads only, a
--- server request only for a new window):
---   1. a window that changed is handed to the client: follow_path again from
---      the waypoint being walked (at most every RESTART_GAP s - a restart is a
---      walker stop);
---   2. less than HORIZON yd of prepared path ahead: the next window is
---      prepared (one batched request);
---   3. an object that was NOT there when its window was prepared, inside the
---      clearance of one of the next AHEAD waypoints: that stretch is prepared
---      again (never in the first GUIDE_SETTLE s of a walk, at most
---      GUIDE_REPLAN_MAX times per destination in GUIDE_REPLAN_WINDOW s).
local GUIDE_SETTLE, GUIDE_REPLAN_MAX, GUIDE_REPLAN_WINDOW = 3.0, 3, 60
local function guide_recheck(c)
    local t = R.now()
    if not cur.exact or guide.planning or not guide.full or t < guide.next_check then return end
    guide.next_check = t + GP.RECHECK_GAP
    if not N.busy() then return end
    local full = guide.full
    local id = cur.id
    local oki, idx = call(c, "get_path_index")
    idx = (oki and type(idx) == "number") and idx or 1
    local fi = math.min(#full, math.max(1, (guide.base or 1) + idx - 1))

    -- 1. a changed window reaches the client
    if guide.dirty and not guide.processing and t >= (guide.restart_at or 0) then
        guide.dirty = false
        guide.restart_at = t + RESTART_GAP
        GP.stats.restarts = (GP.stats.restarts or 0) + 1
        start_walk(c, id, fi)
        return
    end
    if guide.processing then return end

    -- 2. keep HORIZON yd of prepared path ahead
    if guide.done_to < #full and GP.along(full, fi, guide.done_to) < GP.HORIZON then
        local hx, hy, hz = R.here()
        if not hx then return end
        local i1 = guide.done_to + 1
        local i2 = GP.window_end(full, guide.done_to)
        local objs = GP.objects(hx, hy, hz)
        local snap = GP.snapshot(objs)
        for k = 1, #snap do guide.known[#guide.known + 1] = snap[k] end
        guide.processing = true
        GP.process_window(nav_table(), full, i1, i2, objs, GP.indoors(), function(changed)
            if cur.id ~= id then return end
            guide.processing, guide.done_to = false, i2
            GP.stats.windows = (GP.stats.windows or 0) + 1
            if changed > 0 then
                GP.stats.pushed = GP.stats.pushed + changed
                guide.dirty = true
            end
        end)
        return
    end

    -- 3. a new object close to the path just ahead
    if t - (cur.t or 0) < GUIDE_SETTLE then return end
    local key = cur.x and key_of(cur.x, cur.y) or nil
    local b = guide.budget
    if not b or b.key ~= key or t - b.t0 > GUIDE_REPLAN_WINDOW then
        b = { key = key, t0 = t, n = 0 }
        guide.budget = b
    end
    if b.n >= GUIDE_REPLAN_MAX or t < guide.replan_at then return end
    local hx, hy, hz = R.here()
    if not hx then return end
    local objs = GP.objects(hx, hy, hz)
    local fresh = GP.new_only(objs, guide.known)
    local last = math.min(guide.done_to, fi + GP.AHEAD)
    local i, o = GP.blocked(full, fresh, fi + 1, last)
    if not i then return end
    guide.replan_at = t + REPLAN_GAP
    b.n = b.n + 1
    GP.stats.replans = GP.stats.replans + 1
    R.trail("nav", "exact walk: waypoint %d of %d is %.1f yd from a new object (r %.1f) - preparing it again",
        i, #full, R.dist2(full[i].x, full[i].y, o.x, o.y), o.r)
    local snap = GP.snapshot(fresh)
    for k = 1, #snap do guide.known[#guide.known + 1] = snap[k] end
    guide.processing = true
    GP.process_window(nav_table(), full, fi + 1, last, objs, GP.indoors(), function(changed)
        if cur.id ~= id then return end
        guide.processing = false
        if changed > 0 then guide.dirty = true end
    end)
end

-- AmeisenNav's "When combat starts" (C.combat_mode, its Movement page) must
-- be Continue: Pause holds and Stop ends the walk the bot uses to close on
-- its target. The menu owns the key, so it is not changed here - a warning
-- once a minute says what to set.
local mode_warned_t = -1e9
local function check_combat_mode(c)
    local t = R.now()
    if t - mode_warned_t < 60 then return end
    local ok, cfg = call(c, "get_config")
    local m = ok and type(cfg) == "table" and cfg.combat_mode or nil
    if m and m ~= "continue" then
        mode_warned_t = t
        R.log("MasterArthasNav 'When combat starts' is '" .. tostring(m) .. "' - set it to Continue "
            .. "(ArthasNav tab > Movement > When combat starts), or the bot cannot close on its targets")
    end
end

--- Walk to `dest`. True when a walk there is running or was started (also
--- when `dest` is underfoot); false when refused (combat / rest / backpedal,
--- a blacklisted area, the same spot just failed). Safe to call every tick.
function N.nav_to(dest, direct, mode)
    local x, y, z = R.xyz(dest)
    if not x then return false end
    -- 3.5.0: a retarget (movement.nudge) of a running guide walk stays one
    if mode == nil and cur.exact and cur.mode == "guide" and (guide.planning or N.busy()) then mode = "guide" end
    -- 3.7.1: a sharp turn is being made - the next leg starts after it
    if R.turning and mode ~= "combat" then
        local cx, cy = cur.x, cur.y
        if cx and R.dist2(cx, cy, x, y) <= SAME_DEST then return true end
        stats.refused = stats.refused + 1
        return true
    end
    local why = N.refusal()
    -- combat walks always go; an NPC approach (movement.interact) goes
    -- through its own NPC hold
    if why and mode ~= "combat" and not (mode == "npc" and why == "npc") then
        stats.refused = stats.refused + 1
        return false
    end
    if zfix[key_of(x, y)] then z = zfix[key_of(x, y)] end
    local hx, hy, hz = R.here()
    if hx and R.dist2(hx, hy, x, y) <= UNDERFOOT and math.abs(hz - z) < 3 then
        return true
    end
    if not direct and mode ~= "combat" and Z.blocked_xy(x, y) then
        record_fail("blacklisted")
        return false
    end
    local k = key_of(x, y)
    local fe = fails_at[k]
    if fe and fe.n > 0 and (R.now() - fe.t) < 5 and fail.offmesh then return false end
    local c = N.client()
    local busy = N.busy()
    if busy and cur.x and R.dist2(cur.x, cur.y, x, y) <= SAME_DEST and cur.mode ~= "route" then
        return true
    end
    -- the guide walk to this spot is still being planned (not busy yet)
    if guide.planning and cur.exact and cur.x and R.dist2(cur.x, cur.y, x, y) <= SAME_DEST then
        return true
    end
    if not c then
        local w = walker()
        if not w then return false end
        cur.x, cur.y, cur.z, cur.mode, cur.t = x, y, z, mode or "move", R.now()
        local ok, r = pcall(w.move_to_position, w, vec(x, y, z))
        return ok and r ~= false
    end
    if busy and (R.now() - cur.t) < RETARGET_GAP then return true end
    if mode == "combat" then check_combat_mode(c) end
    -- 3.8.0: before an out-of-combat walk of MIN_WALK yd or more starts, mount
    -- (or Travel Form) first - the player stands for the cast meanwhile
    if not busy and mode ~= "combat" and mode ~= "npc" and hx and MT.wants(R.dist2(hx, hy, x, y)) then
        if MT.step(R.me()) then return true end
    end
    if mode ~= "combat" then
        -- 3.7.0: every out-of-combat walk follows the exact server path;
        -- a retarget re-plans: at most every REPLAN_GAP s while walking
        if (busy or guide.planning) and (R.now() - cur.t) < REPLAN_GAP then return true end
        return guide_move(c, x, y, z, mode)
    end
    return issue_move(c, x, y, z, { seamless = busy, mode = mode })
end

--- Walk a recorded route (array of {x,y,z}). The same table while it runs is a
--- no-op unless `replace`. True when accepted.
function N.follow_route(list, replace)
    if type(list) ~= "table" or #list < 1 then return false end
    if N.refusal() then return false end
    local c = N.client()
    if not c then
        local p = list[#list]
        return N.nav_to(p, true)
    end
    if not replace and cur.route == list and N.busy() then return true end
    local pts = {}
    for i = 1, #list do
        local x, y, z = R.xyz(list[i])
        if not x then return false end
        pts[i] = { x = x, y = y, z = z }
    end
    cur.id = cur.id + 1
    local id = cur.id
    local last = pts[#pts]
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.exact = last.x, last.y, last.z, R.now(), "route", list, nil
    cur.leg_t = R.now()
    stats.issued = stats.issued + 1
    local ok = call(c, "follow_path", pts, function(arrived, _, detail)
        if cur.id ~= id or arrived then return end
        local code = type(detail) == "table" and detail.code or nil
        if code ~= "cancelled" then
            R.trail("nav", "route walk ended: %s", tostring(code))
            record_fail(code)
        end
    end)
    return ok == true
end

--- Stop the walk this layer started. Cheap when idle.
function N.stop(reason)
    local c = N.client()
    local was = N.busy()
    if c then
        if was then call(c, "stop", reason or "Master Farmer") end
    else
        local w = walker()
        if w and was then pcall(w.stop, w) end
    end
    cur.id = cur.id + 1                     -- late callbacks of the stopped walk are ignored
    cur.x, cur.mode, cur.route, cur.exact = nil, nil, nil, nil
    -- 3.7.1: a deliberate stop also ends a sharp turn in progress (movement/pivot
    -- only finishes a turn when MasterArthasNav ended the walk by itself)
    if R.turning then R.turn_cancel, R.turning = true, false end
    guide.planning, guide.full, guide.processing, guide.dirty = false, nil, false, false
    if was then R.quiet_until = R.now() + QUIET_STOP end
end

function N.pause(reason)
    local c = N.client()
    if c then call(c, "pause", reason) end
end

function N.resume(reason)
    local c = N.client()
    if c then call(c, "resume", reason) end
end

--- Per frame: drive the fallback walker when AmeisenNav is missing.
function N.pulse()
    if rawget(_G, "ArthasNav") ~= nil then
        if cur.exact then
            local c = N.client()
            if c then guide_recheck(c) end
        end
        return
    end
    local w = walker()
    if w and cur.x then
        local ok, reached = pcall(w.process, w)
        if ok and reached == true then cur.x, cur.mode = nil, nil end
    end
end

-- ----------------------------------------------------------------------------
-- failures
-- ----------------------------------------------------------------------------
function N.last_fail_reason() return fail.reason end
function N.last_fail_offmesh() return fail.offmesh == true end
function N.clear_fail() fail.reason, fail.offmesh = nil, false end

-- ----------------------------------------------------------------------------
-- reachability (validate_destination, cached; never blocks the caller)
-- ----------------------------------------------------------------------------
local reach, reach_n, reach_next = {}, 0, 0

--- false only once AmeisenNav said "unreachable" (also at the ground height);
--- true while pending, unknown, far, or with no server.
function N.reachable(pos)
    local x, y, z = R.xyz(pos)
    if not x then return true end
    local hx, hy = R.here()
    local far = not hx or R.dist2(hx, hy, x, y) > REACH_TRUST_FAR
    local k = key_of(x, y)
    local t = R.now()
    local e = reach[k]
    if e and (t - e.t) < ((e.ok == false) and REACH_TTL_BAD or REACH_TTL) then
        return e.ok ~= false or far
    end
    local c = N.client()
    if not c or t < reach_next then return true end
    reach_next = t + REACH_GAP
    if reach_n > 300 then reach, reach_n = {}, 0 end
    if not e then reach_n = reach_n + 1 end
    e = { ok = nil, t = t, z = nil }
    reach[k] = e
    call(c, "validate_destination", { x = x, y = y, z = z }, function(ok)
        e.t = R.now()
        if ok == true then e.ok = true return end
        if far then e.ok = true return end
        -- the height may be the guess: ask at the ground before saying no
        local okh = ground_near(c, x, y, z, function(okg, gz)
            if not okg or not R.finite(gz) or math.abs(gz - z) <= 2 then e.ok, e.t = false, R.now() return end
            call(c, "validate_destination", { x = x, y = y, z = gz }, function(ok2)
                e.ok, e.t = ok2 == true, R.now()
                if ok2 == true then e.z = gz zfix[k] = gz end
            end)
        end)
        if not okh then e.ok = false end
    end)
    return true
end

function N.node_reachable(pos) return N.reachable(pos) end

--- The ground height found at (x, y) when the given one was wrong, or nil.
function N.reach_z(pos)
    local x, y = R.xyz(pos)
    if not x then return nil end
    local z = zfix[key_of(x, y)]
    if R.finite(z) then return z end
    return nil
end

function N.reach_forget(pos)
    local x, y = R.xyz(pos)
    if not x then return end
    local k = key_of(x, y)
    if reach[k] then reach[k] = nil end
end

--- One find_path for movement/sight: cb(points|nil, ok, info). False when
--- there is no client to ask.
function N.path_probe(from, to, cb)
    local c = N.client()
    if not c then return false end
    local ok = call(c, "find_path", R.point(from), R.point(to), function(okp, pts, info)
        pcall(cb, type(pts) == "table" and #pts >= 2 and pts or nil, okp, info)
    end)
    return ok == true
end

function N.nav_ready()
    local c = N.client()
    if not c then return false end
    local ok, up = call(c, "is_server_available")
    return ok and up == true
end

-- ----------------------------------------------------------------------------
-- built-in grind zones (not recorded paths): a short visiting order
-- ----------------------------------------------------------------------------
local plan = { src = nil, order = nil, pending = false }

function N.plan_grind_route(coords)
    if type(coords) ~= "table" or coords == plan.src or plan.pending then return end
    local c = N.client()
    if not c then return end
    local nodes = {}
    if type(coords[1]) == "number" then
        for i = 1, math.floor(#coords / 3) do
            local k = (i - 1) * 3
            nodes[i] = { x = coords[k + 1], y = coords[k + 2], z = coords[k + 3] }
        end
    else
        for i = 1, #coords do nodes[i] = R.point(coords[i]) or { x = 0, y = 0, z = 0 } end
    end
    plan.src, plan.order, plan.pending = coords, nil, true
    local ok = call(c, "plan_route", nodes, function(okp, res)
        plan.pending = false
        if okp and type(res) == "table" and type(res.visit_order) == "table" then plan.order = res.visit_order end
    end)
    if not ok then plan.pending = false end
end

function N.grind_visit_order() return plan.order end

return N
