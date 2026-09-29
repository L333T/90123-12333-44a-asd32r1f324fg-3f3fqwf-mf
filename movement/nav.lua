-- ============================================================================
-- Master Farmer - Grindbot
-- movement/nav.lua - navigation (Simple Movement primary, Sentinel fallback)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.120.0
-- ============================================================================
-- Out-of-combat travel.
--
-- SENTINEL FOR ALL TRAVEL (2.109.0): out of combat every move - waypoints,
-- NPCs, corpses, grind nodes, recorded routes - is a Sentinel path. No short
-- walker legs, no leash hops, no walker fallback while Sentinel is only rate
-- limited: the move waits for the next request slot instead. The walker
-- (Simple Movement / movement handler) moves the character out of combat
-- only when Sentinel is unavailable. In combat nothing here runs: combat
-- movement (movement/combat.lua) owns the player and uses the walker.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

local K  = require("movement/const")
local R  = require("movement/rt")
local U  = require("movement/util")
local Z  = require("movement/zones")
local L  = require("movement/leash")
local S  = require("movement/steer")
local W  = require("movement/walker")
local N  = require("movement/sentinel")
local O  = require("movement/own")
local Lk = require("movement/locks")

local STATE         = K.STATE
local OWNER         = K.OWNER
local PATROL_HOP    = K.PATROL_HOP
local STEER_BACKOFF = K.STEER_BACKOFF
local QUIET_STOP    = K.QUIET_STOP

local pt = R.pt
local xyz, here_xyz, dist3, dlog, ground_z, walk_open =
      U.xyz, U.here_xyz, U.dist3, U.dlog, U.ground_z, U.walk_open

local P_HERE, P_DEST = R.P_HERE, R.P_DEST

local Nv = {}

-- ============================================================================
-- SENTINEL-ONLY TRAVEL (2.109.0)
-- ============================================================================
local function player_in_combat()
    local ok, v = pcall(function() return izi.me():is_in_combat() end)
    return ok and v == true
end

--- Out of combat with Sentinel available: travel goes through Sentinel only.
local function sentinel_travel()
    if not K.SENTINEL_TRAVEL then return false end
    if O.owns(OWNER.COMBAT) or player_in_combat() then return false end
    return N.client() ~= nil
end
Nv.sentinel_travel = sentinel_travel

--- Did Sentinel just fail this destination? (Not re-requested for SN_FAIL_HOLD.)
local function recently_failed(x, y)
    local f = R.sn_fail
    if not f or (izi.now() - f.t) > (K.SN_FAIL_HOLD or 3) then return false end
    local dx, dy = x - f.x, y - f.y
    return dx * dx + dy * dy < 25
end

--- A Sentinel move for travel. True = moving or waiting for the next request
--- slot (never a walker leg); false = Sentinel failed this destination.
local function sentinel_go(goal, why)
    if recently_failed(goal.x, goal.y) then return false end
    if N.move(goal, why) then return true end
    -- Refused by the rate limit: wait for the next slot, do not walk it.
    R.goal_x, R.goal_y, R.goal_z = nil, nil, nil
    return true
end

-- ============================================================================
-- OWNERSHIP REQUEST
-- ============================================================================
--- Ask for navigation ownership. Refused while combat movement owns the player
--- or while a restriction is active.
local function want_nav()
    if R.cur_state == STATE.RESTRICTED then return false end
    if O.owns(OWNER.COMBAT) then return false end
    return O.take(OWNER.NAV)
end

-- ============================================================================
-- CORE
-- ============================================================================
local MAX_LEG = K.MAX_LEG

--- A destination more than MAX_LEG yards away, pulled in to MAX_LEG along the
--- straight line. Height is interpolated; ground_z settles it once the point
--- is close. The leg is re-planned every time the last one lands, so a far
--- target is still reached - in legs no path request has to span in one go.
local function clamp_leg(x, y, z)
    local hx, hy, hz = here_xyz()
    if not hx then return x, y, z end
    local dx, dy = x - hx, y - hy
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= MAX_LEG then return x, y, z end
    local s = MAX_LEG / d
    return hx + dx * s, hy + dy * s, hz + (z - hz) * s
end
Nv.clamp_leg = clamp_leg

local function navigate(dest, prefer_direct)
    local x, y, z = xyz(dest)
    if not x then return false end
    -- The real destination, for Sentinel (2.59.0): it plans the whole path.
    -- MAX_LEG only limits the WALKER's straight-line legs.
    local sn_goal = { x = x, y = y, z = z }
    -- A height that is still a guess (quest waypoint, no navmesh answer yet)
    -- asks Sentinel for a wide vertical search (2.112.0).
    if type(dest) == "table" and rawget(dest, "z_loose") == true then sn_goal.z_loose = true end
    x, y, z = clamp_leg(x, y, z)
    dest = pt(P_DEST, x, y, z)
    if not want_nav() then return false end
    -- A goal that has moved away from the move in flight re-aims it
    -- (2.84.0, movement/repath): distance-scaled rate, 3 yd dead zone.
    local ok_rp, RP = pcall(require, "movement/repath")
    if ok_rp and RP and RP.reaim(x, y) then
        if R.sn_active then
            -- Sentinel leg: retarget it in place (soft_update, 2.118.0) -
            -- movement keeps running. Refused by the rate limit: keep the
            -- current leg; the next re-aim tries again.
            N.retarget(sn_goal, "reaim")
            return true
        end
        R.force_reissue = true
    end
    local go, ret = O.may_issue(x, y, z)
    if not go then return ret end
    if Z.blocked_xy(x, y) then
        W.mark_fail("blacklisted", dest)
        return false
    end

    -- Sentinel for all travel (2.109.0): the real destination, whole path.
    if sentinel_travel() then
        return sentinel_go(sn_goal, "travel")
    end

    local hx, hy, hz = here_xyz()
    local here = pt(P_HERE, hx, hy, hz)
    z = ground_z(x, y, z)
    local goal = pt(P_DEST, x, y, z)

    -- Without Sentinel travel (unavailable, or K.SENTINEL_TRAVEL off):
    -- Simple Movement owns clear, short legs. Sentinel is the fallback for long
    -- legs and blocked straight lines, where a smoothed straight walk would
    -- fail. Without Sentinel we fall through to walker steering.
    local dist = dist3(hx, hy, hz, x, y, z)
    if dist > PATROL_HOP or not walk_open(here, goal) then
        if N.move(sn_goal, "travel") then return true end
    end

    local target
    if L.needs_rejoin() then
        target = S.rejoin_hop(here)
    else
        target = S.steer(here, goal, PATROL_HOP)
        if target and not L.allows(here, target) then
            target = S.rejoin_hop(here)
        end
    end
    if not target then
        R.steer_backoff_until = izi.now() + STEER_BACKOFF
        dlog("steer", "no clear hop - backing off")
        return false
    end
    if Z.blocked_xy(target.x, target.y) then
        W.mark_fail("blacklisted", target)
        return false
    end
    if not prefer_direct and target ~= here and not walk_open(here, target) and L.needs_rejoin() then
        return false
    end
    -- The leg's real end, for hop chaining in the pulse (2.85.0): the next
    -- hop is planned while this one is walked and issued before it ends.
    R.goal_x, R.goal_y, R.goal_z = goal.x, goal.y, goal.z
    return W.move(target, "nav_to")
end

Nv.navigate = navigate

-- ============================================================================
-- PUBLIC API
-- ============================================================================
--- Navigate to a destination. `direct` skips the "steer around it" guard for
--- callers that already know the line is walkable (grind nodes, corpse runs).
function Nv.nav_to(dest, direct)
    return navigate(dest, direct == true)
end

--- Follow a caller-owned list of points (vec3s or { x, y, z } arrays).
--- The list is snapped and copied once per distinct table; passing the same
--- table every frame while the walker is busy costs nothing.
function Nv.nav_path(points)
    if R.rest_lock then return false end
    if type(points) ~= "table" or #points == 0 then return false end
    local lx, ly, lz = xyz(points[#points])
    if not lx then return false end
    if not want_nav() then return false end
    if points == R.path_src and O.is_moving() then return true end

    local go, ret = O.may_issue(lx, ly, lz)
    if not go then return ret end

    -- Sentinel for all travel (2.109.0): the route is followed by Sentinel;
    -- rate limited = wait for the slot.
    if sentinel_travel() and #points >= 2 then
        local pts = {}
        for i = 1, #points do
            local x, y, z = xyz(points[i])
            if x and not Z.blocked_xy(x, y) then pts[#pts + 1] = vec3.new(x, y, z) end
        end
        if #pts >= 2 then
            if N.follow(pts, "route") then return true end
            return true
        end
    end

    local hx, hy, hz = here_xyz()
    local here = pt(P_HERE, hx, hy, hz)
    if L.needs_rejoin() then
        local hop = S.rejoin_hop(here)
        if not hop then
            R.steer_backoff_until = izi.now() + STEER_BACKOFF
            return false
        end
        return W.move(hop, "rejoin")
    end

    -- snap + filter once per list
    if points ~= R.path_src or not R.path_pts then
        local pts = {}
        for i = 1, #points do
            local x, y, z = xyz(points[i])
            if x and not Z.blocked_xy(x, y) then
                pts[#pts + 1] = vec3.new(x, y, ground_z(x, y, z))
            end
        end
        R.path_src, R.path_pts = points, pts
    end
    local pts = R.path_pts
    if #pts == 0 then return false end
    if #pts == 1 then return navigate(pts[1], true) end
    -- A recorded route goes to Sentinel's follow_path (2.59.0) for its stuck
    -- recovery and repathing; the walker is the fallback (no server, rate
    -- limit, combat owning the player).
    if N.follow(pts, "route") then return true end
    if not walk_open(here, pts[1]) then
        return navigate(pts[1], false)              -- steer to the first point
    end
    return W.navigate_path(pts)
end

--- Stop navigation and release ownership. Returns true when something stopped.
function Nv.nav_stop()
    local stopped = O.halt_all()
    if stopped then W.set_quiet(QUIET_STOP) end
    if O.owns(OWNER.NAV) then R.cur_owner = OWNER.NONE end
    return stopped
end

--- Full stop: drop every actuator, every lock and all ownership. Used when the
--- bot is switched off, changes mode, or dies - not on the per-frame path.
function Nv.halt()
    pcall(function() require("movement/locks").backpedal_stop() end)
    R.combat_req = false
    R.combat_target = nil
    R.combat_stopped = false
    R.combat_ok_since = 0
    R.retreat_until = 0
    R.chase_fail_key, R.chase_fail_t = nil, 0
    O.halt_all()
    R.cur_owner = OWNER.NONE
    O.set_state(STATE.IDLE, "halted")
    Lk.release()
    W.set_quiet(QUIET_STOP)
    return true
end

function Nv.nav_pause()
    if R.sn_active then N.stop() end
    W.set_pause("nav", true)
end

function Nv.nav_resume()
    W.set_pause("nav", false)
end

function Nv.is_navigating()
    return O.owns(OWNER.NAV) and O.is_moving()
end

--- True when navigation is allowed to start right now. Callers use this instead
--- of poking at combat / quiet state themselves.
function Nv.can_navigate()
    if R.cur_state == STATE.RESTRICTED then return false end
    if O.owns(OWNER.COMBAT) then return false end
    return not O.is_quiet()
end

--- Steer back inside the path leash.
function Nv.rejoin_path()
    if R.rest_lock or izi.now() < R.stuck_grace_until then return false end
    if not want_nav() then return false end
    local hx, hy, hz = here_xyz()
    if not hx then return false end
    local hop = S.rejoin_hop(pt(P_HERE, hx, hy, hz))
    if not hop then return false end
    return navigate(hop, walk_open(R.POOL[P_HERE], hop))
end

return Nv
