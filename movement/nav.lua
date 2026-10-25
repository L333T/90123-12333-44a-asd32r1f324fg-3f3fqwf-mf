-- ============================================================================
-- restedXP_questing
-- movement/nav.lua - travel through Sentinel Navigation
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.29.0
-- ============================================================================
-- 4.2.0 SENTINEL PORT (branch sentinel-nav; docs/SENTINEL_API.md = the official
-- v0.0.8 page, docs/SENTINEL_V024.md = what the installed v0.24 really does).
-- Every Sentinel call goes through movement/sentinel.lua (S.*). Sentinel walks
-- its own path: this layer hands it destinations and reads how they end.
--
-- WALK = move_to(target, cb(success, reason)). A new destination while a walk
-- runs is another move_to - Sentinel re-plans without stopping (0.12 s,
-- recorded) - at most every RETARGET_GAP s (combat COMBAT_GAP s): one path
-- request a second, never per frame. The same destination (within SAME_DEST
-- yd) while walking is a no-op, so callers can ask every tick.
--
-- WALKS ARE OURS TO TRACK: a walk replaced by a newer move_to, or stopped,
-- gets NO callback (recorded). Each walk carries a token (cur.id); a newer
-- walk or a stop retires it and its callback, should one ever come, is
-- ignored. A walk the Sentinel UI ended (no callback) is closed by the pulse
-- from get_state().
--
-- HEIGHTS (RestedXP waypoints are x, y only): an off-mesh target costs ~6 s
-- of library retries before Sentinel snaps it (recorded), so an out-of-combat
-- walk of FLOOR_FIRST yd or more asks the navmesh floors there first
-- (get_all_heights, one request per spot, nearest the guess) and walks at
-- that height. A walk that still ends "unreachable" tries the next floor
-- (retry_at_ground). The height found is kept (N.reach_z).
--
-- HOLDS: Sentinel has no pause / resume. A hold (a cast, a sharp turn) stops
-- the walk and remembers where it went; when the last hold lifts the same
-- destination is walked again. Destinations asked for during a hold replace
-- the remembered one.
--
-- STOPS: never on a walk still waiting for its path or younger than
-- FRESH_LEG s (the 2.181.0 / 3.7.1 crash pattern: stopping a fresh leg came
-- right before game crashes). Such a stop is deferred to the pulse (at most
-- STOP_WAIT_MAX s); a new walk meanwhile replaces it instead.
--
-- FAILURES: the reason of the last failed walk is kept (last_fail_reason /
-- last_fail_offmesh). "unreachable" twice at one spot in FAIL_WINDOW s
-- blacklists it (movement/zones); "server_timeout" backs off SERVER_BACKOFF s
-- and asks is_server_available() again.
--
-- NO SENTINEL (library missing, no maps for this game version): no movement
-- at all, and the reason is logged (once per reason). There is no straight-
-- line fallback.
-- ============================================================================

local R = require("movement/core")
local Z = require("movement/zones")
local MT = require("movement/mount")         -- 3.8.0: mount for travel (the 1-60 way)
local S = require("movement/sentinel")

local N = {}

local SAME_DEST = 2.0          -- yd: the same destination
local RETARGET_GAP = 1.0       -- s between two travel retargets (one path request a second)
local COMBAT_GAP = 0.5         -- s between two combat retargets (a moving target)
local UNDERFOOT = 1.0          -- yd: a destination this close is reached
local QUIET_STOP = 0.3         -- s callers wait after a real stop (is_quiet)
local FLOOR_FIRST = 40         -- yd: farther travel walks ask the floors there first
local HEIGHT_SAME = 2.0        -- yd: a height this close to a tried one is the same
local HEIGHT_SCAN_HOLD = 10.0  -- s: a floor query with no answer holds new walks there no longer
local FAIL_WINDOW, FAIL_BLACKLIST = 120, 2
local REACH_TTL, REACH_TTL_BAD, REACH_GAP = 120, 45, 0.25
local REACH_TRUST_FAR = 150    -- yd: farther answers are guesses, never "unreachable"
local FRESH_LEG = 1.0          -- s: a leg younger than this is never stopped (3.7.1)
local STOP_WAIT_MAX = 3.0      -- s: a deferred stop is sent after this at the latest
local LOST_WALK = 2.0          -- s: an idle client this long after our walk began = it ended

-- Sentinel failure reasons (doc): unreachable, server_timeout,
-- max_stuck_exceeded, max_repath_exceeded
local OFFMESH = { unreachable = true }
local SERVER_CODES = { server_timeout = true, server_down = true, map_not_loaded = true }
local SERVER_BACKOFF = 3.5
local GIVE_UP_CODES = { max_stuck_exceeded = true, max_repath_exceeded = true }
local HEIGHT_RETRY = { unreachable = true }

-- the walk this layer asked for
local cur = { id = 0, x = nil, y = nil, z = nil, mode = nil, t = 0, route = nil, done = false }
local fail = { reason = nil, offmesh = false, t = 0 }
local fails_at = {}            -- dest key -> { n, t }
local zfix = {}                -- dest key -> corrected z
local zscan = {}               -- dest key -> { tried = { z, ... }, t, list, asking }
local stats = { issued = 0, refused = 0, floors = 0, deferred_stops = 0 }
N.stats = stats
local stop_req = nil           -- { t, reason } a stop waiting for a safe moment
local held = { reasons = {}, dest = nil }

-- fails_at / zfix / zscan are keyed per destination and would grow for a whole
-- session; past CACHE_MAX keys each is emptied (all are re-learnt).
local CACHE_MAX = 256
local cache_n = { fails = 0, zfix = 0, zscan = 0 }
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

-- ----------------------------------------------------------------------------
-- the client
-- ----------------------------------------------------------------------------
local warned = nil             -- the last "no navigation" reason logged

--- Sentinel's shared client, or nil: the library is missing, or this game
--- version has no maps on the server (the launcher says so in MASTER_FARMER.nav).
function N.client()
    local info = S.info()
    local why = nil
    if info.kind ~= "sentinel" then
        why = "not loaded through Master Farmer's Sentinel entry - the bot will not move"
    elseif not info.supported then
        why = "Sentinel navigation has no maps for this game version - the bot will not move"
    end
    local c = nil
    if not why then
        c = S.client()
        if not c then why = "the Sentinel Navigation library is not loaded - enable it and reload" end
    end
    if why then
        if warned ~= why then
            warned = why
            R.log(why)
        end
        return nil
    end
    warned = nil
    return c
end

--- Why the bot cannot navigate now (for the GUI), or nil.
function N.unavailable() return S.unavailable() end

-- 4.0.4 MasterArthasNav driver claim: Sentinel has no driver setting and its
-- UI owns the tuning - kept so the callers (gui Start / Stop, unload) stay as they are.
function N.want_input_driver(_) end
function N.driver_claimed() return false end
function N.release_driver_now() end

local function key_of(x, y)
    return string.format("%d|%d", math.floor(x / 4), math.floor(y / 4))
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
--- Sentinel is navigating (is_moving: true only while "navigating").
function N.busy()
    local c = N.client()
    return c ~= nil and S.moving(c)
end

function N.destination()
    if cur.x and N.busy() then return cur.x, cur.y, cur.z end
    return nil
end

function N.mode() return N.busy() and cur.mode or nil end

--- Sentinel's dotted state, or nil.
function N.full_state()
    local c = N.client()
    return c and S.full_state(c) or nil
end

--- The path Sentinel follows (vec3[]) and the index being walked to, or nil.
function N.path_points()
    local c = N.client()
    return c and S.current_path(c) or nil
end
function N.path_index()
    local c = N.client()
    return c and S.path_index(c) or nil
end

local function record_fail(code, x, y, z)
    fail.reason, fail.offmesh, fail.t = tostring(code or "failed"), OFFMESH[code] == true, R.now()
    if SERVER_CODES[code] then fail.server_until = R.now() + SERVER_BACKOFF end
    fail.give_up = GIVE_UP_CODES[code] == true
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
local FALSE_ARRIVAL = 5.0      -- yd: an "arrived" farther from the goal is not one

--- Seconds since the running leg started (huge when none runs).
function N.leg_age()
    if not cur.leg_t or not N.busy() then return 1e9 end
    return R.now() - cur.leg_t
end
function N.leg_fresh() return N.leg_age() < FRESH_LEG end

--- An "arrived" far from the goal is not counted (logged once per leg).
function N.false_arrival(x, y)
    local hx, hy = R.here()
    if not hx or not x then return false end
    local d = R.dist2(hx, hy, x, y)
    if d <= FALSE_ARRIVAL then return false end
    R.trail("nav", "walk ended as 'arrived' %.0f yd short of (%.0f, %.0f) - not counted", d, x, y)
    return true
end

-- ----------------------------------------------------------------------------
-- heights: the navmesh floors at a spot
-- ----------------------------------------------------------------------------
local function swimming()
    local ok, v = pcall(function() return core.character.is_swimming() end)
    return ok and v == true
end

--- The floors at (x, y), asked once per spot per FAIL_WINDOW s: cb(list).
--- True when the list is known or the query went out.
local function floors_for(c, k, x, y, z, cb)
    local st = zscan[k]
    if st and (R.now() - st.t) > FAIL_WINDOW then st = nil end
    if not st then
        st = { tried = {}, t = R.now(), list = nil, asking = false, waiting = {} }
        cache_put(zscan, "zscan", k, st)
    end
    if st.list then cb(st.list, st) return true end
    st.waiting[#st.waiting + 1] = cb
    if st.asking then return true end
    st.asking = true
    stats.floors = stats.floors + 1
    local sent = S.floors(c, { x = x, y = y, z = z }, function(list)
        st.asking, st.list = false, list
        local w = st.waiting
        st.waiting = {}
        for i = 1, #w do pcall(w[i], list, st) end
    end)
    if not sent then
        st.asking, st.list, st.waiting = false, {}, {}
        cb(st.list, st)
    end
    return true
end
N._floors_for = floors_for     -- tests

local function untried(st)
    for i = 1, #(st.list or {}) do
        local v, fresh = st.list[i], true
        for j = 1, #st.tried do
            if math.abs(v - st.tried[j]) <= HEIGHT_SAME then fresh = false break end
        end
        if fresh then return v end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- issuing walks
-- ----------------------------------------------------------------------------
local issue_walk

--- "unreachable" at (x, y, z): walk again at the next floor found there.
--- True when a retry is under way (it reports the failure itself).
local function retry_at_ground(c, id, x, y, z, code, mode)
    if swimming() then return false end          -- R9.2 (the floor query answers the bed)
    local k = key_of(x, y)
    cur.scanning, cur.scan_t = id, R.now()
    floors_for(c, k, x, y, z, function(list, st)
        if cur.scanning == id then cur.scanning = nil end
        st.tried[#st.tried + 1] = z
        if cur.id ~= id then return end           -- superseded meanwhile (the list is kept)
        local hz = untried(st)
        if hz then
            cache_put(zfix, "zfix", k, hz)
            R.trail("nav", "(%.0f, %.0f): %s at z %.1f - walking again at a floor there, z %.1f (%d found)",
                x, y, tostring(code), z, hz, #list)
            issue_walk(c, x, y, hz, mode)
        else
            if not st.spent then
                st.spent = true
                R.trail("nav", "(%.0f, %.0f): no floor with a path found (%d found) - %s", x, y, #list, tostring(code))
            end
            record_fail(code, x, y, z)
        end
    end)
    return true
end

issue_walk = function(c, x, y, z, mode)
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = x, y, z, R.now(), mode or "move", nil, false
    cur.leg_t = R.now()
    cur.scanning = nil                            -- audit 4.29.0: a new walk ends any floor scan (a stale one blocked the lost-walk check)
    stop_req = nil                                -- a new walk replaces a pending stop
    stats.issued = stats.issued + 1
    local sent = S.move_to(c, { x = x, y = y, z = z }, function(success, reason)
        if cur.id ~= id then return end
        cur.done = true
        if success then
            if N.false_arrival(x, y) then return end
            fail.reason, fail.offmesh = nil, false
            return
        end
        local code = reason or "failed"
        if HEIGHT_RETRY[code] and retry_at_ground(c, id, x, y, z, code, mode) then return end
        R.trail("nav", "walk to (%.0f, %.0f, %.0f) ended: %s", x, y, z, tostring(code))
        record_fail(code, x, y, z)
    end)
    if not sent then cur.done = true end
    return sent
end

--- Out of combat and FLOOR_FIRST yd or more away with an unchecked height:
--- the floors there first, then the walk at the nearest one. True while it runs.
local function walk_at_floor(c, x, y, z, mode)
    local k = key_of(x, y)
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = x, y, z, R.now(), mode or "move", nil, false
    cur.scanning, cur.scan_t = id, R.now()
    stop_req = nil
    return floors_for(c, k, x, y, z, function(list, st)
        if cur.scanning == id then cur.scanning = nil end
        st.checked = true
        if cur.id ~= id then return end
        local hz = list[1]
        if hz and math.abs(hz - z) > HEIGHT_SAME then
            cache_put(zfix, "zfix", k, hz)
            R.trail("nav", "(%.0f, %.0f): walking at the floor there, z %.1f (guess %.1f, %d floor(s))", x, y, hz, z, #list)
            issue_walk(c, x, y, hz, mode)
        else
            issue_walk(c, x, y, z, mode)
        end
    end)
end

--- Why a NEW walk may not start now, or nil. A walk already running is a
--- retarget, not a new start.
local function event_flags()
    local ev = package.loaded["events"]
    return type(ev) == "table" and type(ev.navflags) == "table" and ev.navflags or nil
end

local function start_blocked(c, mode)
    -- no new travel walk in combat - only the fight's own walks (mode "combat")
    if mode ~= "combat" then
        local nf = event_flags()
        local me0 = R.me()
        local okc, fighting = pcall(function() return me0 and me0:is_in_combat() == true end)
        if (nf and nf.in_combat) or (okc and fighting == true) then return "in combat" end
    end
    if not S.server_up(c) then
        fail.server_until = R.now() + SERVER_BACKOFF
        return "server down"
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- holds (Sentinel has no pause / resume)
-- ----------------------------------------------------------------------------
function N.holding() return next(held.reasons) ~= nil end

--- Walk to `dest`. True when a walk there is running or was started (also
--- when `dest` is underfoot, or remembered for after a hold); false when
--- refused (combat / rest / backpedal, a blacklisted area, the same spot just
--- failed, no Sentinel). Safe to call every tick.
function N.nav_to(dest, direct, mode)
    local x, y, z = R.xyz(dest)
    if not x then return false end
    -- 3.7.1: a sharp turn is being made - the next leg starts after it
    if R.turning and mode ~= "combat" then
        if held.dest then held.dest = { x = x, y = y, z = z, mode = mode, direct = direct } end
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
    if fe and fe.n > 0 and (R.now() - fe.t) < 5 and (fail.offmesh or fail.give_up) then return false end
    local c = N.client()
    if not c then return false end
    -- server back-off, then is_server_available()
    if fail.server_until then
        if R.now() < fail.server_until then
            stats.refused = stats.refused + 1
            return false
        end
        if not S.server_up(c) then
            fail.server_until = R.now() + SERVER_BACKOFF
            stats.refused = stats.refused + 1
            return false
        end
        fail.server_until = nil
    end
    -- a hold (cast, sharp turn): remembered, walked when it lifts
    if N.holding() then
        held.dest = { x = x, y = y, z = z, mode = mode, direct = direct }
        return true
    end
    local busy = S.moving(c)
    if busy and cur.x and R.dist2(cur.x, cur.y, x, y) <= SAME_DEST and cur.mode ~= "route" then
        return true
    end
    -- its floors are being asked for (walk_at_floor / retry_at_ground)
    if cur.scanning and cur.scanning == cur.id and (R.now() - (cur.scan_t or 0)) < HEIGHT_SCAN_HOLD
        and cur.x and R.dist2(cur.x, cur.y, x, y) <= SAME_DEST then
        return true
    end
    if busy and (R.now() - cur.t) < (mode == "combat" and COMBAT_GAP or RETARGET_GAP) then return true end
    if not busy then
        local blocked = start_blocked(c, mode)
        if blocked then stats.refused = stats.refused + 1 return false end
    end
    -- 3.8.0: before an out-of-combat walk of MIN_WALK yd or more starts, mount
    -- (or Travel Form) first - the player stands for the cast meanwhile
    if not busy and mode ~= "combat" and mode ~= "npc" and hx and MT.wants(R.dist2(hx, hy, x, y)) then
        if MT.step(R.me()) then return true end
    end
    if mode ~= "combat" and hx and R.dist2(hx, hy, x, y) >= FLOOR_FIRST and not zfix[k] and not swimming() then
        local st = zscan[k]
        -- audit 4.29.0: a floor query unanswered HEIGHT_SCAN_HOLD s no longer
        -- holds the walk (it re-queued on the stuck query until FAIL_WINDOW)
        local stale = st and st.asking and (R.now() - st.t) >= HEIGHT_SCAN_HOLD
        if not stale and not (st and st.checked and (R.now() - st.t) <= FAIL_WINDOW) then
            return walk_at_floor(c, x, y, z, mode)
        end
    end
    return issue_walk(c, x, y, z, mode)
end

--- Walk a recorded route (array of {x,y,z}) with follow_path. The same table
--- while it runs is a no-op unless `replace`. True when accepted.
function N.follow_route(list, replace)
    if type(list) ~= "table" or #list < 1 then return false end
    if N.refusal() then return false end
    local c = N.client()
    if not c then return false end
    if N.holding() then
        held.dest = { route = list }
        return true
    end
    if not replace and cur.route == list and S.moving(c) then return true end
    local pts = {}
    for i = 1, #list do
        local x, y, z = R.xyz(list[i])
        if not x then return false end
        pts[i] = { x = x, y = y, z = z }
    end
    cur.id = cur.id + 1
    local id = cur.id
    local last = pts[#pts]
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = last.x, last.y, last.z, R.now(), "route", list, false
    cur.leg_t = R.now()
    cur.scanning = nil                      -- audit 4.29.0: as issue_walk
    stop_req = nil
    stats.issued = stats.issued + 1
    local ok = S.follow_path(c, pts, function(success, reason)
        if cur.id ~= id then return end
        cur.done = true
        if success then return end
        R.trail("nav", "route walk ended: %s", tostring(reason))
        record_fail(reason or "failed")
    end)
    if not ok then cur.done = true end
    return ok
end

--- A stop may go out now: the walk follows its path and is not fresh.
local function safe_to_stop(c)
    if S.path_pending(c) then return false end
    return (R.now() - (cur.leg_t or 0)) >= FRESH_LEG
end

--- Stop the walk this layer started. Cheap when idle. A walk still waiting
--- for its path or younger than FRESH_LEG s is stopped by the pulse later.
function N.stop(reason)
    local c = N.client()
    local was = c ~= nil and S.moving(c)
    if c and was then
        if safe_to_stop(c) then
            S.stop(c)
            stop_req = nil
        else
            stop_req = { t = R.now(), reason = reason }
            stats.deferred_stops = stats.deferred_stops + 1
        end
    end
    cur.id = cur.id + 1                     -- the stopped walk's callback, if any, is ignored
    cur.x, cur.mode, cur.route, cur.done = nil, nil, nil, true
    cur.t = -1e9                            -- the next walk is not a retarget: it goes at once (and replaces a deferred stop)
    cur.scanning = nil
    -- 3.7.1: a deliberate stop also ends a sharp turn in progress (movement/pivot
    -- only finishes a turn when the walk ended by itself)
    if R.turning then R.turn_cancel, R.turning = true, false end
    if was then R.quiet_until = R.now() + QUIET_STOP end
end

--- Hold the walk for `reason` (a cast, a sharp turn): stopped, its
--- destination remembered.
function N.pause(reason)
    reason = reason or "hold"
    local first = not N.holding()
    held.reasons[reason] = true
    if first and cur.x and N.busy() then
        held.dest = { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route, direct = true }
        local turning = R.turning
        N.stop("hold " .. reason)
        R.turning = turning                     -- a sharp-turn hold keeps its turn
        R.turn_cancel = false
    end
end

--- Lift `reason`; when no hold is left the remembered destination is walked again.
function N.resume(reason)
    held.reasons[reason or "hold"] = nil
    if N.holding() then return end
    local d = held.dest
    held.dest = nil
    if not d then return end
    if d.route then
        N.follow_route(d.route, true)
    else
        N.nav_to(d, d.direct, d.mode)
    end
end

--- Per frame: event-flag stops, the deferred stop, walks ended without a callback.
function N.pulse()
    -- death or a loading screen flagged by the event callback: the walk stops
    -- here, on the update tick (Sentinel does not stop on death / loading)
    local nf = event_flags()
    if nf and nf.stop then
        local why = nf.stop
        nf.stop = nil
        held.reasons, held.dest = {}, nil
        N.stop(why)
        R.trail("nav", "walk stopped: %s", why)
    end
    local c = N.client()
    if not c then return end
    if stop_req then
        if not S.moving(c) then
            stop_req = nil
        -- audit 4.29.0: never while the path request is in flight (AGENTS rule);
        -- STOP_WAIT_MAX only cuts the fresh-leg wait short
        elseif not S.path_pending(c) and ((R.now() - (cur.leg_t or 0)) >= FRESH_LEG
            or (R.now() - stop_req.t) >= STOP_WAIT_MAX) then
            S.stop(c)
            R.trail("nav", "deferred stop sent (%s)", tostring(stop_req.reason))
            stop_req = nil
        end
    end
    -- a walk of ours that Sentinel ended without a callback (its UI stopped it,
    -- another consumer took over): closed here
    if cur.x and not cur.done and not cur.scanning and (R.now() - cur.t) >= LOST_WALK then
        local st = S.state(c)
        if st == "idle" or st == "arrived" then
            cur.done = true
            R.trail("nav", "walk to (%.0f, %.0f) ended without a callback (state %s)", cur.x, cur.y, st)
        elseif st == "failed" then
            cur.done = true
            record_fail("failed", cur.x, cur.y, cur.z)
        end
    end
    S.indoor_tick(c, R.now())        -- 4.16.0: tighter Sentinel pathing indoors
    N.ahead_tick(c)
end

-- ----------------------------------------------------------------------------
-- 4.8.0 THE PATH AHEAD (user: trace line / raycast hits -> re-path round them
-- while walking; avoid height and collisions in the path; regenerate the
-- path ahead without stalling the player). Every AHEAD.GAP s while a walk
-- follows its path (never while it waits for one or recovers):
--   * COLLISIONS: Sentinel's own obstacle probe (movement/sentinel
--     S.probe_ahead: 3 game trace lines a segment, doodad collision) on the
--     path BEYOND the AHEAD.SKIP segments Sentinel already probes itself
--     (its proactive scan, 3 by default), AHEAD.SEGS more;
--   * HEIGHT: a path segment climbing steeper than AHEAD.STEEP (rise / run,
--     segments of AHEAD.STEEP_MIN yd and more, within AHEAD.STEEP_YD of the
--     player) - Sentinel's probes do not see the slope (the 2026-10-24
--     Plaguewood slope: Stuck 1-3/7 again and again);
--   * STALLS: a place where Sentinel's stuck recovery starts a second time
--     within AHEAD.STALL_R yd in AHEAD.STALL_S s.
-- Each puts a Sentinel avoidance zone there (S.add_zone, AHEAD.ZONE_R yd;
-- the library ages them out) and asks for a SOFT re-path (S.soft_replan:
-- the new path is blended in, the character keeps walking). At most one
-- re-path every AHEAD.REPLAN_GAP s; a spot is zoned once.
-- ----------------------------------------------------------------------------
--
-- 4.16.0 STEEP / STUCK AREAS (user: "stuck attempting to move over steep
-- inclines, attempt re-pathing to path around steep map areas"). The 00:08
-- log zoned 4 yd circles on one slope six times (2539,-1783 -> 2461,-1750:
-- every new path hugged the same slope) and then stood "no movement for 6 s"
-- with Sentinel recovering while the engine only flipped between its two
-- points. Now:
--   * a zone starts at AHEAD.ZONE_R (7) yd and GROWS: a new steep / stall spot
--     within AHEAD.AREA_R yd of an area zoned in the last AHEAD.AREA_S s
--     zones AHEAD.GROW times that area's radius (up to AHEAD.ZONE_MAX), so the
--     path is pushed off the whole slope, not one step of it;
--   * the same spot again after AHEAD.DEBOUNCE s counts as "not avoided" and
--     grows the area too (it used to be skipped for 120 s);
--   * N.stuck_ahead(why): the player is not moving (the quest walk's 6 s
--     watch, Sentinel recovering for AHEAD.RECOVER_S s) - the ground AHEAD of
--     the player along the path (radius yd on, so the player stands at the
--     zone's edge) is zoned the same way and the path re-planned round it.
local AHEAD = { GAP = 1.0, SKIP = 3, SEGS = 5, STEEP = 1.0, STEEP_MIN = 2.0, STEEP_YD = 40,
    STALL_R = 8, STALL_S = 60, ZONE_R = 7, REPLAN_GAP = 3.0, SAME = 3.0,
    AREA_R = 15, AREA_S = 180, GROW = 1.6, ZONE_MAX = 20, DEBOUNCE = 6.0, RECOVER_S = 3.0,
    ZONE_R_IN = 2.5, ZONE_MAX_IN = 5,        -- 4.16.0: indoors (S.indoors) - no steep check there (stairs)
    -- 4.22.0 STAIRS, CAVES, STRUCTURES (see below)
    SUSPECT_S = 30, SUSPECT_R = 8, VERT_YD = 10, VERT_DZ = 2.5, VERT_FREE = 2, ZONE_R_VERT = 3, ZONE_MAX_VERT = 6,
    GOAL_KEEP = 4, suspects = {}, vert_stalls = {},
    t = -1e9, replan_t = -1e9, zones = {}, areas = {}, recover_at = nil, stalls = {}, was_recovering = false,
    recover_t = nil, recover_zoned = false }
N.AHEAD = AHEAD

-- 4.22.0 STAIRS, CAVES AND STRUCTURES (user: "allow the player to go
-- upstairs, downstairs, inside caves and other structures"). The 02:33 log
-- zoned the stairs down to Zaeldarr's crypt ten times ("too steep 46-55 deg")
-- and grew the zone to 20 yd across the entrance; Sentinel then refused the
-- walk (13 refused). Sentinel's navmesh only plans over walkable ground, so a
-- steep path segment is a stair / ramp far more often than a wall. Now:
--   * a steep segment is a SUSPECT (remembered SUSPECT_S s), never zoned on
--     sight; it is zoned only when the player really stalls within
--     SUSPECT_R yd of it;
--   * a stall where the path ahead climbs or drops (VERT_DZ yd within
--     VERT_YD yd - stairs, a ramp, a cave or crypt slope) is re-planned
--     WITHOUT a zone the first VERT_FREE times in that spot (Sentinel's own
--     stuck recovery gets its go); after that a small zone only - ZONE_R_VERT
--     yd, at most ZONE_MAX_VERT - never the 20 yd wall;
--   * no zone ever covers the walk's goal: a zone is shrunk to end GOAL_KEEP
--     yd short of it, or not placed.
local ahead_points            -- (defined below: the walk's points from the player on)
local function vertical_ahead()
    local pts = ahead_points and ahead_points() or nil
    if not pts or #pts < 2 then return false end
    local z0, along = pts[1].z, 0
    for k = 1, #pts - 1 do
        local a, b = pts[k], pts[k + 1]
        along = along + R.dist2(a.x, a.y, b.x, b.y)
        if math.abs(b.z - z0) >= AHEAD.VERT_DZ then return true end
        if along > AHEAD.VERT_YD then break end
    end
    return false
end

--- The radius a zone at `p` may have without covering the goal (nil: none).
local function goal_safe_radius(p, radius)
    if not cur.x then return radius end
    local d = R.dist2(p.x, p.y, cur.x, cur.y)
    local r = math.min(radius, d - AHEAD.GOAL_KEEP)
    if r < 1.5 then return nil end
    return r
end

--- A steep segment near the player: remembered (see above).
local function suspect(p, deg)
    local t = R.now()
    for i = #AHEAD.suspects, 1, -1 do
        local s = AHEAD.suspects[i]
        if (t - s.t) > AHEAD.SUSPECT_S then table.remove(AHEAD.suspects, i)
        elseif R.dist2(s.x, s.y, p.x, p.y) <= 3 then s.t = t return end
    end
    AHEAD.suspects[#AHEAD.suspects + 1] = { x = p.x, y = p.y, z = p.z, t = t, deg = deg }
    stats.suspects = (stats.suspects or 0) + 1
    R.trail("nav", "steep path ahead (%.0f deg) at (%.0f, %.0f): watched, not zoned (stairs / a ramp?)", deg, p.x, p.y)
end

--- The steep suspect within SUSPECT_R yd of the player, or nil.
local function suspect_here()
    local hx, hy = R.here()
    if not hx then return nil end
    local t = R.now()
    for i = #AHEAD.suspects, 1, -1 do
        local s = AHEAD.suspects[i]
        if (t - s.t) > AHEAD.SUSPECT_S then table.remove(AHEAD.suspects, i)
        elseif R.dist2(s.x, s.y, hx, hy) <= AHEAD.SUSPECT_R then return s, i end
    end
    return nil
end

--- A stall at the player's spot on stairs / a slope: how many so far (this one counted).
local function vert_stall_count(x, y)
    local t = R.now()
    for i = #AHEAD.vert_stalls, 1, -1 do
        local v = AHEAD.vert_stalls[i]
        if (t - v.t) > AHEAD.AREA_S then table.remove(AHEAD.vert_stalls, i)
        elseif R.dist2(v.x, v.y, x, y) <= AHEAD.STALL_R then
            v.n, v.t = v.n + 1, t
            return v.n
        end
    end
    AHEAD.vert_stalls[#AHEAD.vert_stalls + 1] = { x = x, y = y, n = 1, t = t }
    return 1
end
N._vertical_ahead, N._goal_safe_radius, N._suspect_here = vertical_ahead, goal_safe_radius, suspect_here

--- A zone at (x, y) made within DEBOUNCE s (the re-path has not had time to
--- show whether it worked): the spot is not zoned again yet.
local function zoned(x, y)
    for i = #AHEAD.zones, 1, -1 do
        local z = AHEAD.zones[i]
        if (R.now() - z.t) > 120 then table.remove(AHEAD.zones, i)
        elseif R.dist2(z.x, z.y, x, y) <= AHEAD.SAME and (R.now() - z.t) < AHEAD.DEBOUNCE then return true end
    end
    return false
end

--- 4.16.0: the radius for a zone at (x, y): `base` for a new area, the
--- area's radius x GROW (up to ZONE_MAX) when the spot is in an area zoned
--- before - the slope was not avoided. Returns radius, hits in the area.
local function area_radius(x, y, base, vertical)
    local t = R.now()
    -- 4.16.0: indoors a zone stays small (a hall, a doorway - not the building)
    local cap = AHEAD.ZONE_MAX
    if S.indoors() then base, cap = math.min(base, AHEAD.ZONE_R_IN), AHEAD.ZONE_MAX_IN end
    -- 4.22.0: on stairs / a slope too (a crypt entrance, a cave mouth, a tower stair)
    if vertical then base, cap = math.min(base, AHEAD.ZONE_R_VERT), math.min(cap, AHEAD.ZONE_MAX_VERT) end
    local hit = nil
    for i = #AHEAD.areas, 1, -1 do
        local a = AHEAD.areas[i]
        if (t - a.t) > AHEAD.AREA_S then table.remove(AHEAD.areas, i)
        elseif not hit and R.dist2(a.x, a.y, x, y) <= math.max(AHEAD.AREA_R, a.r + 8) then hit = a end
    end
    if hit then
        hit.r = math.min(cap, math.max(hit.r * AHEAD.GROW, base))
        hit.n, hit.t = hit.n + 1, t
        return hit.r, hit.n
    end
    AHEAD.areas[#AHEAD.areas + 1] = { x = x, y = y, r = base, n = 1, t = t }
    return base, 1
end
N._area_radius = area_radius

--- Zone the spot (`radius` yd, default AHEAD.ZONE_R) and re-path softly.
--- True when a re-path went out.
local function avoid(c, p, why, radius, vertical)
    if zoned(p.x, p.y) then return false end
    local hits
    radius, hits = area_radius(p.x, p.y, radius or AHEAD.ZONE_R, vertical)     -- 4.16.0: grows in a known area
    -- 4.22.0: never over the goal
    local safe_r = goal_safe_radius(p, radius)
    if not safe_r then
        R.trail("nav", "%s at (%.0f, %.0f): not zoned - the goal is there", why, p.x, p.y)
        return false
    end
    radius = safe_r
    AHEAD.zones[#AHEAD.zones + 1] = { x = p.x, y = p.y, t = R.now() }
    stats.zones = (stats.zones or 0) + 1
    if hits > 1 then why = string.format("%s (area hit %d times)", why, hits) end
    if not S.add_zone(c, p, radius) then
        R.trail("nav", "%s at (%.0f, %.0f): Sentinel has no avoidance zones here - not re-pathed", why, p.x, p.y)
        return false
    end
    if (R.now() - AHEAD.replan_t) < AHEAD.REPLAN_GAP then
        R.trail("nav", "%s at (%.0f, %.0f): zoned (re-path waits)", why, p.x, p.y)
        return false
    end
    AHEAD.replan_t = R.now()
    local ok = S.soft_replan(c, "mf_" .. why:gsub("%s", "_"))
    stats.soft_replans = (stats.soft_replans or 0) + (ok and 1 or 0)
    R.trail("nav", "%s at (%.0f, %.0f): avoidance zone %.0f yd, %s", why, p.x, p.y, radius,
        ok and "path regenerated ahead (soft, no stop)" or "re-path refused")
    return ok
end

--- The walk's path from the current waypoint on (player first), as {x,y,z}.
function ahead_points()
    local pts, i = N.path_points(), N.path_index()
    if type(pts) ~= "table" or #pts == 0 then return nil end
    i = (type(i) == "number" and i >= 1) and math.floor(i) or 1
    local hx, hy, hz = R.here()
    if not hx then return nil end
    local out = { { x = hx, y = hy, z = hz } }
    for k = i, #pts do
        local x, y, z = R.xyz(pts[k])
        if x then out[#out + 1] = { x = x, y = y, z = z } end
    end
    return out
end

function N.ahead_tick(c)
    local now = R.now()
    local fs = S.full_state(c) or ""
    local recovering = fs:find("recovering", 1, true) ~= nil
    -- stalls: each start of Sentinel's stuck recovery is noted where it began
    if recovering and not AHEAD.was_recovering then
        local hx, hy, hz = R.here()
        if hx then
            for i = #AHEAD.stalls, 1, -1 do
                local s = AHEAD.stalls[i]
                if (now - s.t) > AHEAD.STALL_S then
                    table.remove(AHEAD.stalls, i)
                elseif R.dist2(s.x, s.y, hx, hy) <= AHEAD.STALL_R then
                    table.remove(AHEAD.stalls, i)
                    AHEAD.recover_at = { x = hx, y = hy, z = hz }
                end
            end
            AHEAD.stalls[#AHEAD.stalls + 1] = { x = hx, y = hy, t = now }
        end
    end
    AHEAD.was_recovering = recovering
    -- 4.16.0: still recovering RECOVER_S s on - the ground ahead is zoned (once a recovery)
    if recovering then
        AHEAD.recover_t = AHEAD.recover_t or now
        if not AHEAD.recover_zoned and (now - AHEAD.recover_t) >= AHEAD.RECOVER_S then
            AHEAD.recover_zoned = true
            N.stuck_ahead("stuck (Sentinel recovering)")
        end
    else
        AHEAD.recover_t, AHEAD.recover_zoned = nil, false
    end
    if (now - AHEAD.t) < AHEAD.GAP then return end
    if not cur.x or cur.done or cur.mode == "npc" or not S.moving(c) then return end
    if S.path_pending(c) or recovering then return end
    AHEAD.t = now
    if AHEAD.recover_at then
        local p = AHEAD.recover_at
        AHEAD.recover_at = nil
        -- 4.22.0: stalled at a steep suspect -> that spot; on stairs / a slope -> re-plan first, small zone later
        local sus = suspect_here()
        local vert = vertical_ahead()
        if vert and vert_stall_count(p.x, p.y) <= AHEAD.VERT_FREE then
            if (now - AHEAD.replan_t) >= AHEAD.REPLAN_GAP then
                AHEAD.replan_t = now
                local okr = S.soft_replan(c, "mf_stairs")
                R.trail("nav", "stalled on stairs / a slope at (%.0f, %.0f): re-planned, no zone%s", p.x, p.y,
                    okr and "" or " (re-plan refused)")
            end
            return
        end
        if sus then
            if avoid(c, sus, string.format("too steep (%.0f deg), stalled there", sus.deg or 0), nil, vert) then return end
        elseif avoid(c, p, "repeated stall", nil, vert) then return end
    end
    local pts = ahead_points()
    if not pts or #pts < 2 then return end
    -- height: too steep to climb, near the player (4.16.0: not indoors -
    -- stairs are steep and walkable; the indoor profile's vertical re-path
    -- catches a fall off them)
    local along = 0
    for k = 1, S.indoors() and 0 or (#pts - 1) do
        local a, b = pts[k], pts[k + 1]
        local run = R.dist2(a.x, a.y, b.x, b.y)
        if run >= AHEAD.STEEP_MIN and (b.z - a.z) / run > AHEAD.STEEP then
            stats.steep = (stats.steep or 0) + 1
            -- 4.22.0: watched, zoned only if the player stalls there (stairs are steep and walkable)
            suspect({ x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2 },
                math.deg(math.atan((b.z - a.z) / run)))
        end
        along = along + run
        if along > AHEAD.STEEP_YD then break end
    end
    -- collisions: Sentinel's probe, past the segments it probes itself
    if #pts > AHEAD.SKIP + 1 then
        local far = {}
        for k = AHEAD.SKIP + 1, #pts do far[#far + 1] = pts[k] end
        local hit = S.probe_ahead(c, far, AHEAD.SEGS)
        stats.probes = (stats.probes or 0) + 1
        if hit then avoid(c, hit, "obstacle ahead") end
    end
end

--- 4.16.0: the point `yd` yards ahead of the player along the running path
--- (else toward the walk's destination), or nil.
local function point_ahead(yd)
    local hx, hy, hz = R.here()
    if not hx then return nil end
    local pts = ahead_points()
    if pts and #pts >= 2 then
        local left = yd
        for k = 1, #pts - 1 do
            local a, b = pts[k], pts[k + 1]
            local seg = R.dist2(a.x, a.y, b.x, b.y)
            if seg >= left and seg > 0 then
                local f = left / seg
                return { x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f, z = a.z + (b.z - a.z) * f }
            end
            left = left - seg
        end
        local last = pts[#pts]
        return { x = last.x, y = last.y, z = last.z }
    end
    if cur.x then
        local d = R.dist2(hx, hy, cur.x, cur.y)
        if d > 0.5 then
            local f = math.min(1, yd / d)
            return { x = hx + (cur.x - hx) * f, y = hy + (cur.y - hy) * f, z = hz }
        end
    end
    return nil
end
N._point_ahead = point_ahead

--- 4.16.0: the player is not getting anywhere - zone the ground just AHEAD
--- of the player (grown in a known area; the player at the zone's edge) and
--- re-plan round it. True when a zone was placed.
function N.stuck_ahead(why)
    local c = N.client()
    if not c then return false end
    local hx, hy = R.here()
    if not hx then return false end
    -- 4.22.0: on stairs / a slope (a crypt, a cave, a tower) the first stalls re-plan only
    local vert = vertical_ahead()
    if vert and vert_stall_count(hx, hy) <= AHEAD.VERT_FREE then
        local okr = S.moving(c) and S.soft_replan(c, "mf_stairs") or false
        AHEAD.replan_t = R.now()
        R.trail("nav", "%s on stairs / a slope at (%.0f, %.0f): re-planned, no zone%s", tostring(why), hx, hy,
            okr and "" or " (the next path tries again)")
        return false
    end
    local r0, hits = area_radius(hx, hy, AHEAD.ZONE_R, vert)
    local sus = suspect_here()
    local p = sus and { x = sus.x, y = sus.y, z = sus.z } or point_ahead(r0 + 1)
    if not p or zoned(p.x, p.y) then return false end
    r0 = goal_safe_radius(p, r0)
    if not r0 then
        R.trail("nav", "%s at (%.0f, %.0f): not zoned - the goal is there", tostring(why), p.x, p.y)
        return false
    end
    AHEAD.zones[#AHEAD.zones + 1] = { x = p.x, y = p.y, t = R.now() }
    stats.zones = (stats.zones or 0) + 1
    if not S.add_zone(c, p, r0) then
        R.trail("nav", "%s at (%.0f, %.0f): Sentinel has no avoidance zones here - not re-pathed", tostring(why), p.x, p.y)
        return false
    end
    stats.stuck_zones = (stats.stuck_zones or 0) + 1
    AHEAD.replan_t = R.now()
    local ok = S.moving(c) and S.soft_replan(c, "mf_stuck") or false
    R.trail("nav", "%s: avoidance zone %.0f yd on the ground ahead (%.0f, %.0f)%s, %s", tostring(why), r0, p.x, p.y,
        hits > 1 and string.format(" (area hit %d times)", hits) or "",
        ok and "path re-planned round it" or "the next path goes round it")
    return true
end

--- 4.9.0: a mob 3+ levels above the player or an elite (quest/threat.lua):
--- a Sentinel avoidance zone the size of its aggro range + a soft re-path
--- (the same zone memory and re-path gap as the path-ahead check). True
--- when the area is avoided (now, or zoned before and still standing).
function N.avoid_area(p, radius, why)
    local x, y, z = R.xyz(p)
    if not x then return false end
    if zoned(x, y) then return true end
    local c = N.client()
    if not c or not S.add_zone(c, { x = x, y = y, z = z }, radius) then return false end
    AHEAD.zones[#AHEAD.zones + 1] = { x = x, y = y, t = R.now() }
    stats.zones = (stats.zones or 0) + 1
    local replanned = false
    if S.moving(c) and (R.now() - AHEAD.replan_t) >= AHEAD.REPLAN_GAP then
        AHEAD.replan_t = R.now()
        replanned = S.soft_replan(c, "mf_avoid")
        stats.soft_replans = (stats.soft_replans or 0) + (replanned and 1 or 0)
    end
    R.trail("nav", "avoid %s: Sentinel avoidance zone %.0f yd at (%.0f, %.0f)%s", tostring(why), radius, x, y,
        replanned and ", path re-planned (soft, no stop)" or "")
    return true
end

--- 4.8.0: the navmesh raycast (server, no game call) - cb(ok, hit, t).
function N.nav_raycast(from, to, cb)
    local c = N.client()
    if not c then return false end
    return S.raycast(c, R.point(from), R.point(to), cb)
end

-- ----------------------------------------------------------------------------
-- failures
-- ----------------------------------------------------------------------------
function N.last_fail_reason() return fail.reason end
function N.last_fail_offmesh() return fail.offmesh == true end
function N.clear_fail() fail.reason, fail.offmesh = nil, false end

--- A walk is being planned or its floors are being asked for - not a stand
--- (quest/engine's route watchdog waits for it).
function N.pending()
    local c = N.client()
    if c and cur.x and not cur.done and S.path_pending(c) then return true end
    return cur.scanning ~= nil and cur.scanning == cur.id and (R.now() - (cur.scan_t or 0)) < HEIGHT_SCAN_HOLD
end

--- A failure reason that is the server's, not the place's.
function N.server_trouble(code) return SERVER_CODES[code] == true end

-- ----------------------------------------------------------------------------
-- reachability (validate_destination, cached; never blocks the caller)
-- ----------------------------------------------------------------------------
local reach, reach_n, reach_next = {}, 0, 0

--- false only once Sentinel said "not reachable" (also at the floors there);
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
    S.validate(c, { x = x, y = y, z = z }, function(ok)
        e.t = R.now()
        if ok == true then e.ok = true return end
        if far then e.ok = true return end
        -- the height may be the guess: ask at the floors there before saying no
        floors_for(c, k, x, y, z, function(list)
            local gz = nil
            for i = 1, #list do if math.abs(list[i] - z) > HEIGHT_SAME then gz = list[i] break end end
            if not gz then e.ok, e.t = false, R.now() return end
            S.validate(c, { x = x, y = y, z = gz }, function(ok2)
                e.ok, e.t = ok2 == true, R.now()
                if ok2 == true then e.z = gz cache_put(zfix, "zfix", k, gz) end
            end)
        end)
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

--- One path query for movement/sight: cb(points|nil, ok, info). False when
--- there is no client to ask.
function N.path_probe(from, to, cb)
    local c = N.client()
    if not c then return false end
    return S.find_path(c, R.point(from), R.point(to), cb)
end

function N.nav_ready()
    local c = N.client()
    return c ~= nil and S.server_up(c)
end

--- 4.10.0 KITE: a ranged retreat point from Sentinel's nav_client:kite (a path
--- round the target at KITE.RADIUS yd; the walk goes to its last point).
--- cb(point | nil). The FIRST answer of an unexpected shape switches kiting
--- off for the session (logged with what came back) - the call was read from
--- the v0.0.6 source, so its v0.24 answer is checked live. True when asked.
local KITE = { RADIUS = 15, off = false, said = false }
N.KITE = KITE
function N.kite(from, target, cb)
    if KITE.off then return false end
    local c = N.client()
    if not c then return false end
    return S.kite(c, R.point(from), R.point(target), KITE.RADIUS, function(pts, ok, info)
        if info and info.shape_bad then
            KITE.off = true
            if not KITE.said then
                KITE.said = true
                R.log("Sentinel kite answered in an unknown shape (" .. tostring(info.got) .. ") - kiting off for this session")
            end
            pcall(cb, nil)
            return
        end
        local last = pts and pts[#pts] or nil
        local x, y, z                          -- (not `last and R.xyz(last)`: that keeps one value)
        if last then x, y, z = R.xyz(last) end
        if x then
            stats.kites = (stats.kites or 0) + 1
            pcall(cb, { x = x, y = y, z = z })
        else
            if info and info.error then R.trail("nav", "kite: no point (%s)", info.error) end
            pcall(cb, nil)
        end
    end)
end

--- 4.14.0 FLEE (improvement 3 of the API-dump review): a path AWAY from every
--- threat from Sentinel's nav_client:flee, FLEE.DISTANCE yd long. cb(point |
--- nil) - the path's last point. Like kite, the first answer of another shape
--- switches fleeing off for the session (logged). True when asked.
local FLEE = { DISTANCE = 30, off = false, said = false }
N.FLEE = FLEE
function N.flee(from, threats, cb)
    if FLEE.off or type(threats) ~= "table" or #threats < 1 then return false end
    local c = N.client()
    if not c then return false end
    local list = {}
    for i = 1, #threats do list[#list + 1] = R.point(threats[i]) end
    return S.flee(c, R.point(from), list, FLEE.DISTANCE, function(pts, ok, info)
        if info and info.shape_bad then
            FLEE.off = true
            if not FLEE.said then
                FLEE.said = true
                R.log("Sentinel flee answered in an unknown shape (" .. tostring(info.got) .. ") - fleeing off for this session")
            end
            pcall(cb, nil)
            return
        end
        local last = pts and pts[#pts] or nil
        local x, y, z
        if last then x, y, z = R.xyz(last) end
        if x then
            stats.flees = (stats.flees or 0) + 1
            pcall(cb, { x = x, y = y, z = z })
        else
            if info and info.error then R.trail("nav", "flee: no point (%s)", info.error) end
            pcall(cb, nil)
        end
    end)
end

--- 4.14.0 LIVE SENTINEL STATUS (improvements 5 and 11): the walk's progress,
--- the recorded route's progress, the distance to the destination, the
--- avoidance zone count and the consecutive path failures. Read at most every
--- STATUS.GAP s, on the update tick only (movement.lua's snapshot) - the GUI
--- reads the cached table. nil without a client.
local STATUS = { GAP = 0.5, t = -1e9, v = nil }
function N.status()
    local now = R.now()
    if (now - STATUS.t) < STATUS.GAP then return STATUS.v end
    STATUS.t = now
    local c = N.client()
    if not c then STATUS.v = nil return nil end
    local v = { progress = S.progress(c), route = S.route_progress(c), zones = S.zone_count(c),
        failures = S.failures(c), state = S.state(c) }
    local d = S.destination(c)
    local hx, hy, hz = R.here()
    if d and hx then v.dest_yd = R.dist3(hx, hy, hz, d.x, d.y, tonumber(d.z) or hz) end
    STATUS.v = v
    return v
end

--- One line for the GUI from a status table (no game call).
function N.status_text(v)
    if type(v) ~= "table" then return nil end
    local parts = {}
    local pr = v.progress
    if v.state == "navigating" and pr and pr.total and pr.total > 0 then
        parts[#parts + 1] = string.format("%.0f%% (wp %d/%d)", pr.percent or 0, pr.index or 0, pr.total)
    end
    if v.dest_yd then parts[#parts + 1] = string.format("%.0f yd to go", v.dest_yd) end
    if v.route and v.route.percent then parts[#parts + 1] = string.format("route %.0f%%", v.route.percent) end
    if v.zones and v.zones > 0 then parts[#parts + 1] = string.format("%d zone%s", v.zones, v.zones == 1 and "" or "s") end
    if v.failures and v.failures > 0 then parts[#parts + 1] = string.format("%d failed path%s", v.failures, v.failures == 1 and "" or "s") end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
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
    local ok = S.plan_route(c, nodes, function(okp, res)
        plan.pending = false
        if okp and type(res) == "table" and type(res.visit_order) == "table" then plan.order = res.visit_order end
    end)
    if not ok then plan.pending = false end
end

function N.grind_visit_order() return plan.order end

-- tests
function N._reset()
    cur = { id = 0, x = nil, y = nil, z = nil, mode = nil, t = 0, route = nil, done = false }
    fail = { reason = nil, offmesh = false, t = 0 }
    fails_at, zfix, zscan, reach, reach_n = {}, {}, {}, {}, 0
    cache_n = { fails = 0, zfix = 0, zscan = 0 }
    stop_req, held = nil, { reasons = {}, dest = nil }
    warned = nil
    AHEAD.t, AHEAD.replan_t, AHEAD.zones, AHEAD.recover_at, AHEAD.stalls, AHEAD.was_recovering =
        -1e9, -1e9, {}, nil, {}, false
end

return N
