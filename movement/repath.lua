-- ============================================================================
-- Master Farmer - Grindbot
-- movement/repath.lua - adaptive re-pathing and the stuck ladder
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.236.0
-- ============================================================================
-- Every movement goal - a navigation destination (quest waypoint, NPC,
-- vendor, corpse, grind node) or the combat target - is watched here, once
-- per REPATH_GAP, from the movement pulse.
--
-- 1. MOVING GOALS, ADAPTIVE RE-AIM
--    A walker or Sentinel move used to run to where the goal WAS: while the
--    character moved, no new move was accepted ("already going"). Now, when
--    the goal has shifted more than max(REAIM_MIN, REAIM_FRAC x distance)
--    from the destination being walked to, the move is re-aimed - every
--    REAIM_NEAR s inside REAIM_BAND yards, every REAIM_FAR s beyond - and
--    never inside the DEAD_ZONE, which is what stops orbiting a target the
--    character is already standing next to. navigate() asks RP.reaim().
--
-- 2. PROGRESS, NOT MOTION
--    The stuck check in fsm only noticed a character that had stopped. Running
--    against a wall, circling a rock or orbiting a mob is motion without
--    progress. Here, progress is the distance TO THE GOAL shrinking by
--    PROGRESS_YD; without it for WINDOW[level] seconds the ladder climbs:
--      1  steer     widen the search and retarget Sentinel in place.
--                   The walk is not stopped.
--      2  unstick   jump, still moving
--      3  give up   a combat target is marked unreachable and released (the
--                   engines pick another); a destination is blacklisted, so
--                   its caller moves on
--    Every rung is a `move:` trail line in the session log.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local K = require("movement/const")
local R = require("movement/rt")
local U = require("movement/util")
local Z = require("movement/zones")
local W = require("movement/walker")
local N = require("movement/sentinel")
local O = require("movement/own")
local Hz = require("movement/hazards")   -- 2.235.0: stuck spots are learned

local OWNER = K.OWNER
local pt = R.pt
local here_xyz, dist2, unit_xyz, dlog = U.here_xyz, U.dist2, U.unit_xyz, U.dlog

local RP = {}

local REPATH_GAP  = 0.25
local DEAD_ZONE   = 3.0
local REAIM_BAND  = 30
local REAIM_NEAR  = 0.2
local REAIM_FAR   = 1.0
local REAIM_MIN   = 2.0
local REAIM_FRAC  = 0.15
local PROGRESS_YD = 1.0
local WINDOW      = { 4.0, 3.0, 4.0 }   -- seconds without progress before rung 1, 2, 3
local GIVEUP_ZONE = 8.0

local g = { key = nil, best = nil, best_t = 0, level = 0 }
local next_t = 0
local last_reaim = 0

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "move", fmt, ...)
    end
end

local function reset(key, d, t)
    g.key, g.best, g.best_t, g.level = key, d, t, 0
end

-- ----------------------------------------------------------------------------
-- 1. RE-AIM
-- ----------------------------------------------------------------------------
--- May a move toward (x, y) replace the one in flight? True when the goal has
--- moved enough, not too recently for its distance, and outside the dead zone.
function RP.reaim(x, y)
    if not R.has_dest then return false end
    if not (R.walker_moving or R.sn_active) then return false end
    local hx, hy = here_xyz()
    if not hx then return false end
    local d = dist2(hx, hy, x, y)
    if d <= DEAD_ZONE then return false end
    local shift = dist2(R.dest_x, R.dest_y, x, y)
    local need = math.max(REAIM_MIN, d * REAIM_FRAC)
    if shift <= need then return false end
    local t = izi.now()
    local gap = (d < REAIM_BAND) and REAIM_NEAR or REAIM_FAR
    if (t - last_reaim) < gap then return false end
    last_reaim = t
    dlog("reaim", string.format("goal moved %.1f yd - re-aiming (%.0f yd away)", shift, d))
    return true
end

--- Is Sentinel benched by the ladder right now?
function RP.sentinel_benched()
    return izi.now() < (R.sn_bench_until or 0)
end

-- ----------------------------------------------------------------------------
-- 2. PROGRESS WATCHDOG
-- ----------------------------------------------------------------------------
--- The goal being worked toward: { x, y, z, key, kind, unit }, or nil.
local function current_goal()
    if R.cur_owner == OWNER.COMBAT and R.combat_target then
        local x, y, z = unit_xyz(R.combat_target)
        if x and R.combat_guid ~= nil then
            return x, y, z, "u" .. tostring(R.combat_guid), "combat"
        end
        return nil
    end
    if R.has_dest and (R.walker_moving or R.sn_active or R.pending) then
        local key = string.format("d%d|%d", math.floor(R.dest_x / 5), math.floor(R.dest_y / 5))
        return R.dest_x, R.dest_y, R.dest_z, key, "nav"
    end
    return nil
end

--- Should the watchdog stand still this tick? (casting, resting, restricted,
--- a combat target already in reach - none of those is being stuck)
local function holding()
    if R.rest_lock then return true end
    local pr = R.pause_reason
    if pr.cast or pr.restrict or pr.rest or pr.loot then return true end
    if R.cur_owner == OWNER.COMBAT and R.combat_stopped then return true end
    -- Sentinel still planning, or recovering from its own stuck handler.
    -- Climbing the ladder here would retarget or stop a walk that is moving.
    -- 2.192.0: only while that recovery still moves the character (N.recovering).
    if N.recovering() then return true end
    if type(N.planning) == "function" and N.planning() then return true end
    return false
end

--- Within attack distance of the combat target (2.155.0): standing there is
--- fighting, not being stuck. The 01:00 log climbed the ladder at 3 yd -
--- "no progress toward the combat (3 yd) - jumping" - beside the boar it was
--- killing, whenever the in-position latch had not caught (a line-of-sight
--- miss at contact range).
local function in_reach(kind, d)
    if kind ~= "combat" then return false end
    local reach = (tonumber(R.combat_yards) or 5) + 1
    if reach < DEAD_ZONE then reach = DEAD_ZONE end
    return d <= reach
end

local function escalate(x, y, z, kind, d, t)
    g.level = g.level + 1
    local secs = t - g.best_t
    g.best_t = t
    if g.level == 1 then
        trail("no progress toward the %s for %.0fs (%.0f yd) - steering, not stopping", kind, secs, d)
        -- Do not stop Sentinel or the walker. A stop is what made the
        -- character stand still between hops. Sentinel retargets in place;
        -- the walker look-ahead turns onto the next hop by itself.
        if kind ~= "combat" and R.sn_active and type(N.replan) == "function" then
            N.replan("no_progress")
        end
        R.block_streak = math.max(R.block_streak or 0, 2)
        R.detour_side = -(R.detour_side ~= 0 and R.detour_side or 1)
        return
    end
    if g.level == 2 then
        trail("still stuck (%.0f yd) - jumping, still moving", d)
        pcall(function() core.input.jump() end)
        return
    end
    -- rung 3: give up on this goal
    if kind == "combat" then
        -- A mob we never walked toward is not unreachable. The 22:51 log
        -- blacklisted wolves at 43 yd after 8 s of standing still. Drop the
        -- target so the quest waypoint can run; leave it on the table.
        if not R.walker_moving and not R.sn_active then
            trail("no walk issued toward the combat (%.0f yd) - dropping without blacklist", d)
        else
            trail("target unreachable after the re-plan and unstick - dropping it")
            local ok_s, state = pcall(require, "state")
            if ok_s and state and type(state.mark_unreachable) == "function" and R.combat_guid ~= nil then
                state.mark_unreachable(R.combat_guid)
            end
        end
        local ok_c, C = pcall(require, "movement/combat")
        if ok_c and C and type(C.combat_release) == "function" then
            C.combat_release()
        end
    elseif R.approach_guid ~= nil then
        -- An approach to a mob (2.140.0): give up on the mob, not the ground.
        trail("approach to the target stalled (%.0f yd) - target unreachable, no blacklist", d)
        local ok_s, state = pcall(require, "state")
        if ok_s and state and type(state.mark_unreachable) == "function" then
            state.mark_unreachable(R.approach_guid)
        end
        R.approach_guid = nil
        O.halt_all()
        W.clear_dest()
    else
        trail("destination (%.0f, %.0f) unreachable - blacklisted", x, y)
        Z.blacklist_area(pt(R.P_TMP, x, y, z), GIVEUP_ZONE, "unreachable")
        O.halt_all()
        W.clear_dest()
    end
    g.key, g.level = nil, 0
end

--- Called from the movement pulse.
function RP.update(t)
    if t < next_t then return end
    next_t = t + REPATH_GAP
    local x, y, z, key, kind = current_goal()
    if not x then
        g.key = nil
        return
    end
    local hx, hy = here_xyz()
    if not hx then return end
    local d = dist2(hx, hy, x, y)
    if key ~= g.key then
        reset(key, d, t)
        return
    end
    if holding() or d <= DEAD_ZONE or in_reach(kind, d) then
        g.best, g.best_t = math.min(g.best or d, d), t
        return
    end
    if kind == "nav" and R.sn_active and type(N.progress_advanced) == "function"
        and N.progress_advanced() then
        g.best, g.best_t, g.level = d, t, 0
        return
    end
    if d < (g.best or d) - PROGRESS_YD then
        g.best, g.best_t, g.level = d, t, 0
        return
    end
    local window = WINDOW[g.level + 1] or WINDOW[#WINDOW]
    if (t - g.best_t) >= window then
        escalate(x, y, z, kind, d, t)
    end
end

--- The fsm stuck check hands over here instead of cancelling on its own.
-- ARRIVED, NOT STUCK (2.117.0). Standing still within NEAR_DONE yards of a
-- travel target (at the NPC, next to the corpse) is arrival: the logs showed
-- "no progress toward the nav for 0s (3 yd) - re-planning" with the
-- character already at the quest giver. The move is simply finished.
local NEAR_DONE = 5.0

function RP.stuck_now(t)
    local x, y, z, key, kind = current_goal()
    if not x then return false end
    local hx, hy = here_xyz()
    if not hx then return false end
    if kind ~= "combat" and dist2(hx, hy, x, y) <= NEAR_DONE then
        W.clear_dest()
        W.halt()
        g.key = nil
        return true
    end
    -- ONE STUCK AUTHORITY (2.141.0). The walker's stuck check used to call
    -- escalate here directly, on top of RP.update doing the same on its own
    -- clock, so a walker leg climbed two rungs at a time (re-plan and jump
    -- together, give up after ~8 s instead of ~11). The ladder now escalates
    -- only on its own windows; the walker check just reports.
    local d = dist2(hx, hy, x, y)
    if key ~= g.key then
        reset(key, d, t)
        return true
    end
    if holding() or in_reach(kind, d) then
        g.best_t = t
        return true
    end
    local window = WINDOW[g.level + 1] or WINDOW[#WINDOW]
    if (t - g.best_t) >= window then
        escalate(x, y, z, kind, d, t)
    end
    return true
end

function RP.reset()
    g.key, g.level = nil, 0
end

-- ----------------------------------------------------------------------------
-- 4. STUCK AREAS (2.190.0)
-- ----------------------------------------------------------------------------
-- The ladder above works on one goal at a time and, when it gives up,
-- blacklists the DESTINATION - not the spot the character is caught on, so a
-- fence or rock that keeps catching it is walked into again on the next
-- goal. This watches the character itself: while movement is trying to move
-- (a travel leg or a combat chase) and the character has stayed within
-- AREA_MOVE yards for AREA_STUCK seconds of trying - casting, resting,
-- standing in reach and Sentinel still planning do not count - the area just
-- ahead, toward the goal, is blacklisted (AREA_R yards, the character just
-- outside it, the destination never inside it). Blacklisted areas go to
-- Sentinel's obstacle list (movement/zones) and to find_path_avoid
-- (movement/sentinel avoid zones), and the same destination is asked for
-- again, so the new path goes around the obstruction.
local AREA_STUCK  = 20.0
local AREA_MOVE   = 3.0
local AREA_R      = 6.0
local AREA_AHEAD  = 7.0       -- zone centre this far ahead: AREA_R + 1, the character stays outside
local AREA_SAMPLE = 0.5
local aw = { x = nil, y = nil, acc = 0, last = 0, idle_since = nil }

local function trying_to_move()
    if R.cur_owner == OWNER.COMBAT and R.combat_target then
        return not R.combat_stopped
    end
    return R.has_dest and (R.walker_moving or R.sn_active or R.pending) and true or false
end

--- Blacklist an AREA_R area just ahead and re-plan around it. The direction
--- is where the character is trying to go: the running path's next point
--- (2.192.0), else straight at the goal. True when an area was blacklisted.
local function avoid_ahead(hx, hy, hz, gx, gy, gz, kind, why)
    local d = dist2(hx, hy, gx, gy)
    local ax, ay = nil, nil
    if kind ~= "combat" and type(N.ahead_point) == "function" then
        ax, ay = N.ahead_point(2.0)
    end
    if not ax then ax, ay = gx, gy end
    local da = dist2(hx, hy, ax, ay)
    if da < 0.5 then return false end
    local ux, uy = (ax - hx) / da, (ay - hy) / da
    local cx, cy = hx + ux * AREA_AHEAD, hy + uy * AREA_AHEAD
    local cz = hz + ((gz or hz) - hz) * math.min(1, AREA_AHEAD / math.max(d, 1))
    if dist2(cx, cy, gx, gy) < AREA_R + 2 then
        -- The goal itself is inside where the zone would go: blacklisting
        -- would wall it off. The ladder's give-up handles an unreachable goal.
        trail("%s %.0f yd from the %s - too close to blacklist ahead", why, d, kind)
        return false
    end
    -- A learned hazard (2.235.0): kept all session, saved once hit twice, so
    -- the next lap of a grind loop routes around it instead of sticking.
    Hz.add(cx, cy, cz, AREA_R, why)
    trail("%s at (%.0f, %.0f) toward the %s - area (%.0f, %.0f) r%.0f blacklisted, re-pathing around it",
        why, hx, hy, kind, cx, cy, AREA_R)
    -- The ladder starts over on the new path.
    g.key, g.level = nil, 0
    aw.acc = 0
    pcall(function() core.input.jump() end)  -- free a wedged character before the new path
    if kind == "combat" then
        -- Combat movement steers clear of blacklisted ground on its next hop.
        O.halt_all()
        return true
    end
    local dx, dy, dz = R.dest_x, R.dest_y, R.dest_z
    if type(dx) ~= "number" then return true end
    if type(N.end_recovery) == "function" then N.end_recovery() end
    if R.cur_owner ~= OWNER.COMBAT then
        if type(N.repath_around) == "function" then
            N.repath_around(pt(R.P_DEST, dx, dy, dz), "stuck_avoid")
        elseif type(N.move) == "function" then
            O.halt_all()
            R.sn_last_issue_t = -1e9
            N.move(pt(R.P_DEST, dx, dy, dz), "stuck_avoid")
        end
    end
    return true
end

--- Sentinel's own recovery has stood still SN_RECOVER_MAX s (2.192.0): stop
--- waiting on it and re-path around the spot now. Per movement pulse.
function RP.recovery_watch(t)
    if type(N.recovery_stalled) ~= "function" or not N.recovery_stalled() then return end
    local hx, hy, hz = here_xyz()
    local gx, gy, gz, _, kind = current_goal()
    if not hx or not gx or kind ~= "nav" then return end
    trail("Ameisen stuck recovery has not moved the character - re-pathing ourselves")
    if not avoid_ahead(hx, hy, hz, gx, gy, gz, kind, "Ameisen recovery stuck") then
        -- Too close to the goal to blacklist: drop the recovery hold so the
        -- ladder (re-plan, jump, give up) runs on its own clock.
        N.end_recovery()
    end
end

function RP.area_watch(t)
    if (t - aw.last) < AREA_SAMPLE then return end
    local dt = t - aw.last
    aw.last = t
    if dt > 2 then dt = AREA_SAMPLE end
    local hx, hy, hz = here_xyz()
    if not hx then return end
    if not trying_to_move() then
        aw.idle_since = aw.idle_since or t
        if (t - aw.idle_since) > 2.0 then aw.x, aw.acc = nil, 0 end
        return
    end
    aw.idle_since = nil
    if not aw.x or dist2(aw.x, aw.y, hx, hy) > AREA_MOVE then
        aw.x, aw.y, aw.acc = hx, hy, 0
        return
    end
    if holding() then return end            -- paused, not reset
    -- 2.191.0: beside the combat target is fighting, not stuck (the 12:50
    -- log counted 20 s "stuck 4 yd from the combat" while meleeing).
    do
        local cx, cy, _, _, ck = current_goal()
        if cx and in_reach(ck, dist2(hx, hy, cx, cy)) then return end
    end
    aw.acc = aw.acc + dt
    if aw.acc < AREA_STUCK then return end
    aw.acc = 0
    aw.x, aw.y = hx, hy
    local gx, gy, gz, _, kind = current_goal()
    if not gx then return end
    avoid_ahead(hx, hy, hz, gx, gy, gz, kind, "stuck " .. string.format("%.0f", AREA_STUCK) .. " s")
end

return RP
