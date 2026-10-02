-- ============================================================================
-- Master Farmer - Grindbot
-- movement/combat.lua - combat movement
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.195.0
-- ============================================================================
-- Approach, retreat and the hysteresis that keeps the player off the range
-- edge. The class profile decides the "why" of a retreat; this module decides
-- the "when" through the band and the prediction, so no class code lives here.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local state = require("state")

local K  = require("movement/const")
local R  = require("movement/rt")
local U  = require("movement/util")
local G  = require("movement/geom")
local L  = require("movement/leash")
local S  = require("movement/steer")
local W  = require("movement/walker")
local N  = require("movement/sentinel")
-- Sentinel "pull" legs toward a target - off, see the pull-in below (2.76.0).
local SENTINEL_PULL = false
local O  = require("movement/own")
local Rg = require("movement/range")
local Z  = require("movement/zones")

local STATE                = K.STATE
local OWNER                = K.OWNER
local RESTRICT             = K.RESTRICT
local MIN_NAV              = K.MIN_NAV
local STEER_HOP            = K.STEER_HOP
local QUIET_STOP           = K.QUIET_STOP
local CHASE_BAND           = K.CHASE_BAND
local STEER_BACKOFF        = K.STEER_BACKOFF
local RETREAT_BAND         = K.RETREAT_BAND
local CHASE_GIVE_UP        = K.CHASE_GIVE_UP
local COMBAT_OFFSET        = K.COMBAT_OFFSET
local PREDICT_AHEAD        = K.PREDICT_AHEAD
local PREDICT_MARGIN       = K.PREDICT_MARGIN
local DEFAULT_MELEE_DANGER = K.DEFAULT_MELEE_DANGER
local PULL_RETRY           = K.PULL_RETRY
local MELEE_YARDS          = K.MELEE_YARDS
local MELEE_REACH          = K.MELEE_REACH
local MELEE_HOLD           = K.MELEE_HOLD
local MELEE_STANDOFF       = K.MELEE_STANDOFF
local MELEE_MIN_HOP        = K.MELEE_MIN_HOP
local CHASE_REISSUE        = K.CHASE_REISSUE
local PULL_MAX_TRIES       = K.PULL_MAX_TRIES

local pt = R.pt
local xyz, here_xyz, dist2, dist3 = U.xyz, U.here_xyz, U.dist2, U.dist3
local unit_xyz, unit_valid, unit_alive = U.unit_xyz, U.unit_valid, U.unit_alive
local log, dlog, ground_z, walk_open = U.log, U.dlog, U.ground_z, U.walk_open

local P_HERE, P_DEST, P_ALT, P_TMP = R.P_HERE, R.P_DEST, R.P_ALT, R.P_TMP

local sqrt = math.sqrt

local C = {}

-- ============================================================================
-- COMBAT PROFILE  (class rules without class code in the core)
-- ============================================================================
--- Register the active class's combat-movement rules. Every field is optional.
---   melee_danger   number  back away when a relevant enemy is inside this
---   melee_safe     number  stop backing away once this far out
---   should_retreat fun(ctx):boolean  ctx = {
---       player, target, distance, melee_count, enemies,
---       last_spell_id, last_spell_target, last_spell_age }
--- Returning false (or omitting should_retreat) disables retreating entirely.
function C.set_combat_profile(p)
    R.profile = type(p) == "table" and p or nil
    if R.profile then dlog("profile", "combat profile: " .. tostring(R.profile.name or "?")) end
end

function C.clear_combat_profile()
    R.profile = nil
end

local function melee_danger()
    local n = R.profile and tonumber(R.profile.melee_danger)
    if type(n) == "number" and n > 0 then return n end
    return DEFAULT_MELEE_DANGER
end

local function melee_safe()
    local n = R.profile and tonumber(R.profile.melee_safe)
    if type(n) == "number" and n > melee_danger() then return n end
    return melee_danger() + RETREAT_BAND
end

-- ============================================================================
-- ENEMY QUERIES
-- ============================================================================
--- Enemies within `yards` of the player that are still worth positioning for.
local function live_enemies(player, yards)
    local ok, list = pcall(player.get_enemies_in_range, player, yards, false)
    if not ok or type(list) ~= "table" then return nil, 0 end
    return list, #list
end

local function melee_count(player)
    local ok, list = pcall(player.get_enemies_in_melee_range, player, melee_danger(), false)
    if not ok or type(list) ~= "table" then return 0, nil end
    return #list, list
end

--- Predicted distance from the player's current spot to where `unit` will be in
--- PREDICT_AHEAD seconds. nil when prediction is unavailable.
local function predicted_distance(player, unit)
    local ok, p = pcall(unit.predict_position, unit, PREDICT_AHEAD)
    if not ok then return nil end
    local px, py, pz = xyz(p)
    if not px then return nil end
    local hx, hy, hz = here_xyz()
    if not hx then hx, hy, hz = unit_xyz(player) end
    if not hx then return nil end
    return dist3(hx, hy, hz, px, py, pz)
end

-- ============================================================================
-- RETREAT
-- ============================================================================
--- Should we back out of melee? Only the class profile decides the "why"
--- (frozen, snared, cooldown up...); the core decides the "when" via the
--- hysteresis band and the prediction.
local function want_retreat(player, target, distance)
    local profile = R.profile
    if not profile or type(profile.should_retreat) ~= "function" then return false end
    local danger = melee_danger()

    -- already retreating: keep going until we are past melee_safe (hysteresis)
    if izi.now() < R.retreat_until then
        return distance < melee_safe()
    end

    local close = distance <= danger
    if not close then
        -- not close yet, but closing fast enough to be inside the band shortly
        local pd = predicted_distance(player, target)
        if not pd or pd > (danger - PREDICT_MARGIN) then return false end
    end

    local mc, mlist = melee_count(player)
    local ok, want = pcall(profile.should_retreat, {
        player            = player,
        target            = target,
        distance          = distance,
        melee_count       = mc,
        enemies           = mlist,
        last_spell_id     = R.last_spell_id,
        last_spell_target = R.last_spell_target,
        last_spell_age    = R.last_spell_t > 0 and (izi.now() - R.last_spell_t) or nil,
    })
    return ok and want == true
end

--- Issue a retreat hop directly away from `target` (and away from the melee
--- pack when there is one). Simple Movement is the actuator; the combat
--- controller owns it exclusively while COMBAT is the movement owner.
local function retreat_from(player, target)
    if not O.owns(OWNER.COMBAT) then return false end
    local hx, hy, hz = here_xyz()
    if not hx then hx, hy, hz = unit_xyz(player) end
    local ux, uy, uz = unit_xyz(target)
    if not hx or not ux then return false end

    local here = pt(P_HERE, hx, hy, hz)
    -- retreat away from the centroid of the melee pack when several are on us
    local mc, mlist = melee_count(player)
    local tx, ty, tz = ux, uy, uz
    if mc > 1 and type(mlist) == "table" then
        local sx, sy, sz, n = 0, 0, 0, 0
        for i = 1, #mlist do
            local ex, ey, ez = unit_xyz(mlist[i])
            if ex then sx, sy, sz, n = sx + ex, sy + ey, sz + ez, n + 1 end
        end
        if n > 0 then tx, ty, tz = sx / n, sy / n, sz / n end
    end

    local threat = pt(P_DEST, tx, ty, tz)
    local need = melee_safe() - dist2(hx, hy, tx, ty)
    if need < MIN_NAV then need = MIN_NAV end
    if need > STEER_HOP * 2 then need = STEER_HOP * 2 end

    -- A mesh-aware spot from Sentinel first (2.59.0): flee from the pack when
    -- several are on us, kite a single target otherwise. The geometric
    -- away-vector is the fallback while no answer is fresh.
    local spot = nil
    local sn_spot
    if mc > 1 and type(mlist) == "table" then
        local threats = {}
        for i = 1, #mlist do
            local ex, ey, ez = unit_xyz(mlist[i])
            if ex then threats[#threats + 1] = { x = ex, y = ey, z = ez } end
        end
        sn_spot = N.flee_point(here, threats)
    else
        sn_spot = N.kite_point(here, { x = ux, y = uy, z = uz })
    end
    if sn_spot then
        spot = pt(P_TMP, sn_spot.x, sn_spot.y, sn_spot.z)
    else
        spot = G.away_from(P_TMP, here, threat, need)
    end
    if spot and S.cand_ok(here, spot, nil, false) then
        R.retreat_x, R.retreat_y, R.retreat_z = spot.x, spot.y, spot.z
        R.retreat_until = izi.now() + 2.0
        return W.move(spot, "retreat")
    end

    -- straight back is blocked: peel off to the side instead of hugging a wall
    if not spot then
        dlog("retreat", "no retreat vector (on top of threat)")
        return false
    end
    for i = 1, #COMBAT_OFFSET do
        local alt = G.rotate(P_ALT, spot, here, COMBAT_OFFSET[i])
        if S.cand_ok(here, alt, nil, false) then
            R.retreat_x, R.retreat_y, R.retreat_z = alt.x, alt.y, alt.z
            R.retreat_until = izi.now() + 2.0
            return W.move(alt, "retreat_side")
        end
    end
    dlog("retreat", "no retreat lane")
    return false
end

-- ============================================================================
-- APPROACH
-- ============================================================================
--- Issue a combat approach hop toward a computed point.
local function combat_hop(p, min_hop)
    min_hop = min_hop or MIN_NAV
    if not O.owns(OWNER.COMBAT) or R.rest_lock then return false end
    -- Only a live walk blocks a new hop. Stale pending (a dest issued but
    -- the body never moved) is what left the 22:51 log standing at 43 yd.
    if R.walker_moving or R.sn_active then return true end
    if not O.nav_gap_ok() then return true end
    local hx, hy, hz = here_xyz()
    if not hx then return false end
    local here = pt(P_HERE, hx, hy, hz)
    local target = pt(P_TMP, p.x, p.y, p.z)      -- own copy: steering reuses p's slot
    if L.needs_rejoin() or not L.allows(here, target) then
        target = S.rejoin_hop(here)
        if not target then return false end
    end
    if not walk_open(here, target) then
        local hop = dist2(hx, hy, target.x, target.y)
        if hop > STEER_HOP then hop = STEER_HOP end
        target = S.pick_steer(here, target, hop, false, true)
        if not target or not walk_open(here, target) then return false end
    end
    if not W.ensure() then return false end
    if dist3(hx, hy, hz, target.x, target.y, target.z) < min_hop then return false end
    return W.move(target, "chase")
end

--- Remember an unreachable mob so the target selector stops offering it.
local function note_chase_failure(unit, t)
    local okg, guid = pcall(unit.get_guid, unit)
    local key = (okg and guid ~= nil) and guid or "?"
    if R.chase_fail_key ~= key then
        R.chase_fail_key, R.chase_fail_t = key, t
    elseif (t - R.chase_fail_t) >= CHASE_GIVE_UP then
        if type(state.mark_unreachable) == "function" then state.mark_unreachable(guid) end
        R.chase_fail_key, R.chase_fail_t = nil, 0
        log("Blacklist unreachable mob after " .. tostring(CHASE_GIVE_UP) .. "s")
    end
end

-- ============================================================================
-- ENGAGE
-- ============================================================================
--- Drive combat movement for one tick. Returns true when the player is in
--- position to fight (in range, LoS, not repositioning).
---
--- This is the only entry point that takes combat ownership. Callers invoke it
--- every tick while they want to fight `unit`; when they stop calling it, the
--- state machine notices and releases combat movement on its own terms.
function C.combat_engage(player, unit, yards)
    if not player or not unit or R.rest_lock then return false end
    -- Backpedalling after Frost Nova owns movement (2.97.0): no chase, no hop.
    if R.backpedal_until then return false end
    if not unit_valid(unit) then return false end
    yards = tonumber(yards) or 20
    if yards < 1 then yards = 5 end
    -- MELEE (2.26.0): every melee rotation reports a 5-yard combat range.
    -- Stopping at 5 yards from the target's centre left melee out of swing
    -- range of anything small, so melee closes to MELEE_REACH instead.
    local melee = yards <= MELEE_YARDS
    -- Melee distance from the GUI: stand at the slider, in position at the
    -- slider, chase again 1 yd past it. 2.90.0 arrived 1-2 yd outside the
    -- setting; the 00:52 warrior then stopped well short of it.
    local m_stand, m_reach, m_hold = MELEE_STANDOFF, MELEE_REACH, MELEE_HOLD
    if melee then
        m_stand = yards
        m_reach = yards
        m_hold = yards + 1
    end

    R.combat_req, R.combat_req_t = true, izi.now()
    -- By GUID, never `R.combat_target ~= unit` (2.47.0): comparing two game
    -- objects runs the native __eq, which THROWS "Invalid game object!" once
    -- the stored one has been freed - it aborted combat movement every tick
    -- (150+ times in the 22:54 log) until the target changed.
    local ok_g, guid = pcall(unit.get_guid, unit)
    if not ok_g then guid = nil end
    if guid == nil or R.combat_guid ~= guid then
        -- Light crash capture over the first moments of the approach (2.87.0).
        local ok_gui, gui_m = pcall(require, "gui")
        if ok_gui and gui_m and type(gui_m.is_on) == "function" and gui_m.is_on("crash_capture") then
            local ok_e, el = pcall(require, "errorlog")
            if ok_e and type(el) == "table" and type(el.arm_light) == "function" then
                el.arm_light(1.5, "approach a new target")
            end
        end
        -- new target: the hysteresis latch and the retreat latch describe the
        -- old one, so carrying them over would mis-band the first approach.
        R.combat_stopped = false
        R.retreat_until = 0
        R.chase_fail_key, R.chase_fail_t = nil, 0
        R.combat_ok_since = 0
    end
    R.combat_target, R.combat_yards, R.combat_guid = unit, yards, guid
    if R.cur_state == STATE.RESTRICTED then
        -- rooted: we cannot reposition, but we can still turn and cast
        if R.restrict_why ~= RESTRICT.ROOT then return false end
        Rg.face(unit)
        return Rg.in_fight_range(player, unit, yards)
    end

    -- Sentinel is still landing an out-of-combat PULL-IN - combat's own leg
    -- toward this target. Taking COMBAT here would halt it, and we would
    -- re-issue it next frame forever. Let it finish.
    --
    -- Any OTHER Sentinel leg is halted (2.54.0). A waypoint walk is a
    -- Sentinel leg too, and this used to wait for it: a mob engaged on the
    -- way to a quest waypoint was "fought" while the character kept walking
    -- to the waypoint - "closing" with the distance growing 4 -> 14 yd, the
    -- mob hitting its back, nothing ever killed (22:xx log).
    if R.sn_active then
        if R.sn_why == "pull" then
            R.chase_fail_key, R.chase_fail_t = nil, 0
            Rg.face(unit)
            return false
        end
        O.halt_all()
        dlog("combat", "halted Sentinel leg '" .. tostring(R.sn_why) .. "' to fight")
    end

    O.take(OWNER.COMBAT)

    local ready, range, has_los = Rg.in_fight_range(player, unit, yards)
    if melee then
        -- Swinging range: m_hold (5 yd) once in position.
        ready = has_los and type(range) == "number" and range <= m_hold
    end
    local t = izi.now()

    -- 1. retreat has priority over everything else while it is latched
    if want_retreat(player, unit, range) then
        R.combat_stopped = false
        R.chase_fail_key, R.chase_fail_t = nil, 0
        if not O.is_moving() and O.nav_gap_ok() then
            retreat_from(player, unit)
        end
        Rg.face(unit)
        return ready
    end
    if R.retreat_until > 0 then
        -- edge: the profile has stopped asking, so drop the latch once and stop
        -- the retreat hop. Leaving it set would cancel the next approach.
        R.retreat_until = 0
        if O.is_moving() then O.halt_all() end
        dlog("retreat", string.format("clear at %.1f yd", range))
    end

    -- 2. in position, with hysteresis: we must close to CHASE_BAND inside max
    --    range before we call it "in position", but once we are there we hold
    --    until we fall all the way back outside max range. Without the two
    --    thresholds the player oscillates on the range edge.
    local hold_in = yards - CHASE_BAND
    if hold_in < 5 then hold_in = yards end
    local in_band
    if melee then
        -- Arrive at the GUI slider; once there, hold until 1 yd past it.
        if R.combat_stopped then
            in_band = range <= m_hold
        else
            in_band = range <= m_reach
        end
    elseif R.combat_stopped then
        in_band = range <= yards            -- holding: leave only past max range
    else
        in_band = range <= hold_in          -- closing: arrive well inside it
    end
    if has_los and in_band then
        R.chase_fail_key, R.chase_fail_t = nil, 0
        if not R.combat_stopped then
            R.combat_stopped = true
            if R.pending or O.is_moving() then O.halt_all() end
            dlog("combat", string.format("in position at %.1f yd (band %.1f/%.1f)",
                range, hold_in, yards))
        end
        Rg.face(unit)
        return true
    end
    if R.combat_stopped then
        dlog("combat", string.format("left band at %.1f yd - chasing", range))
    end
    R.combat_stopped = false

    -- 3. long out-of-combat pull-in: one Sentinel leg to just inside range when
    --    the mob is far and the straight line is blocked.
    --
    --    THROTTLED (2.23.0). This bypassed every gate navigation has - move gap,
    --    failure cooldown, blacklisted areas - so when Sentinel answered at once
    --    (off-mesh, unreachable, or already there) the next frame asked again,
    --    and the frame after: a navmesh request per frame for as long as the
    --    bot travelled to the mob. Now: the move gap applies, a failed leg waits
    --    PULL_RETRY before the same mob is tried again, a blacklisted spot is
    --    never asked for, and after PULL_MAX_TRIES legs the mob is marked
    --    unreachable like any other chase that goes nowhere.
    local okc, in_cbt = pcall(player.is_in_combat, player)
    local pull_key = nil
    do
        local okg, g = pcall(unit.get_guid, unit)
        pull_key = (okg and g ~= nil) and g or unit
    end
    if R.pull_key ~= pull_key then
        R.pull_key, R.pull_next_t, R.pull_tries = pull_key, 0, 0
    end
    -- SENTINEL PULL-IN OFF (2.76.0). Every game crash of 2026-09-27 whose
    -- log reaches the moment (11:49:55, 12:45:04, 13:31:22) came within about
    -- a second of a Sentinel "pull" leg starting toward a fresh target 44-50
    -- yd away - out in the open and inside the Echo Ridge mine alike - and
    -- pull legs had also been seen hanging (2.70.0). While such a leg runs this
    -- plugin does almost nothing per frame; Sentinel drives. Closing on a
    -- target is left to the local walker (direct chase, steering, and the
    -- find_path-planned chase below), which is how every in-combat approach
    -- already works. Sentinel keeps long-distance travel.
    if SENTINEL_PULL and not (okc and in_cbt == true) and type(range) == "number" and range > 30
        and t >= R.pull_next_t and O.nav_gap_ok() then
        local ux, uy, uz = unit_xyz(unit)
        local hx, hy, hz = here_xyz()
        if ux and hx then
            local here, goal = pt(P_HERE, hx, hy, hz), pt(P_DEST, ux, uy, ground_z(ux, uy, uz))
            if not walk_open(here, goal) then
                local pull = yards - 5
                if pull < MIN_NAV then pull = yards end
                local dx, dy, dz = hx - ux, hy - uy, hz - uz
                local len = sqrt(dx * dx + dy * dy)
                if len > pull then
                    local s = pull / len
                    local dest = pt(P_TMP, ux + dx * s, uy + dy * s,
                                   ground_z(ux + dx * s, uy + dy * s, uz + dz * s))
                    if R.pull_tries >= PULL_MAX_TRIES then
                        -- Every leg so far has ended without closing the gap.
                        local okg, guid = pcall(unit.get_guid, unit)
                        if okg and guid ~= nil and type(state.mark_unreachable) == "function" then
                            state.mark_unreachable(guid)
                        end
                        log("Pull-in gave up after " .. tostring(PULL_MAX_TRIES) .. " legs")
                        R.pull_next_t = t + PULL_RETRY * 10
                    elseif not Z.blocked_xy(dest.x, dest.y) then
                        R.pull_tries = R.pull_tries + 1
                        R.pull_next_t = t + PULL_RETRY
                        -- A Sentinel leg is out-of-combat navigation, so hand the
                        -- player to NAV for the pull-in. combat_engage retakes
                        -- COMBAT once the leg lands and sn_active goes false.
                        O.take(OWNER.NAV)
                        if N.move(dest, "pull") then
                            R.chase_fail_key, R.chase_fail_t = nil, 0
                            return false
                        end
                        O.take(OWNER.COMBAT)
                    end
                end
            end
        end
    end

    -- 4a. DIRECT CHASE (2.37.0). When the straight line to the target is
    -- clear, walk straight at it in ONE move - to melee contact, or to the
    -- class's range - and only re-aim when the target has shifted more than
    -- CHASE_REISSUE from where that move is headed.
    --
    -- The steering search below hands out STEER_HOP (5 yd) hops chosen from
    -- angled offsets and side-steps, re-planned about every half second from
    -- wherever the last one ended; a chain of slightly angled hops is the S
    -- the character weaved in on a mob in open ground. Steering is kept for
    -- when something is actually in the way. The path leash still applies.
    do
        local ux, uy, uz = unit_xyz(unit)
        local hx, hy, hz = here_xyz()
        if not hx then hx, hy, hz = unit_xyz(player) end
        if ux and hx and O.owns(OWNER.COMBAT) and not R.rest_lock then
            local stand = m_stand
            if not melee then
                stand = yards - CHASE_BAND
                if stand < 5 then stand = yards end
            end
            local remain = dist2(hx, hy, ux, uy)
            if remain > 0 and (remain - stand) >= MELEE_MIN_HOP then
                local s = (remain - stand) / remain
                local dx, dy = hx + (ux - hx) * s, hy + (uy - hy) * s
                local moving = R.walker_moving or R.sn_active
                local shifted = not R.has_dest or dist2(R.dest_x, R.dest_y, dx, dy) > CHASE_REISSUE
                if moving and not shifted then
                    -- Already walking the straight line: keep going.
                    R.chase_fail_key, R.chase_fail_t = nil, 0
                    return false
                end
                if O.nav_gap_ok() and not L.needs_rejoin() then
                    local here = pt(P_HERE, hx, hy, hz)
                    local goal = pt(P_DEST, ux, uy, ground_z(ux, uy, uz))
                    local dest = pt(P_ALT, dx, dy, hz + (goal.z - hz) * s)
                    if L.allows(here, dest) and walk_open(here, goal) and W.ensure()
                        and W.move(dest, "chase_direct") then
                        R.chase_fail_key, R.chase_fail_t = nil, 0
                        return false
                    end
                end
            end
        end
    end

    if R.walker_moving or R.sn_active then
        R.chase_fail_key, R.chase_fail_t = nil, 0
        Rg.face(unit)
        return false
    end

    -- 4. close the gap (line blocked: steer around it)
    local ux, uy, uz = unit_xyz(unit)
    if not ux then return false end
    local hx, hy, hz = here_xyz()
    if not hx then hx, hy, hz = unit_xyz(player) end
    if not hx then return false end
    local here, goal = pt(P_HERE, hx, hy, hz), pt(P_DEST, ux, uy, ground_z(ux, uy, uz))

    -- 4b. BLOCKED LINE: a Sentinel-planned path, walked by the local walker
    -- (2.59.0). Sentinel's own move would be deferred while the rotation
    -- casts; the walker is not. Steering below is the fallback while the
    -- path is pending or there is no server.
    if O.nav_gap_ok() and not walk_open(here, goal) then
        local pts = N.chase_path(here, goal, R.combat_guid)
        if pts and #pts >= 2 and W.ensure() and W.navigate_path(pts) then
            R.chase_fail_key, R.chase_fail_t = nil, 0
            Rg.face(unit)
            return false
        end
    end

    -- steering only when a move could actually be issued; a failed search backs
    -- off for STEER_BACKOFF so the trace budget is not burnt every frame
    local dest
    if O.nav_gap_ok() and t >= R.steer_backoff_until then
        -- aim for CHASE_BAND inside max range so we do not stop on the edge;
        -- melee aims for m_stand from the target
        local hold = yards - CHASE_BAND
        if hold < 5 then hold = yards end
        if melee then
            hold = m_stand
            -- Close enough for one hop and nothing in the way: step straight
            -- in to m_stand on the line to the target. The steering
            -- search would otherwise hand back a point short of it.
            local remain = dist2(hx, hy, ux, uy)
            if remain > 0 and remain <= STEER_HOP + m_stand and walk_open(here, goal) then
                local s = (remain - m_stand) / remain
                dest = pt(P_ALT, hx + (ux - hx) * s, hy + (uy - hy) * s,
                          hz + (goal.z - hz) * s)
            end
        end
        if not dest then
            dest = S.approach_unit(here, goal, hold)
            if not dest and not has_los then dest = S.orbit_for_los(here, goal, hold) end
        end
        if not dest then R.steer_backoff_until = t + STEER_BACKOFF end
    end
    local issued = dest ~= nil and combat_hop(dest, melee and MELEE_MIN_HOP or nil)
    Rg.face(unit)
    if issued or not O.nav_gap_ok() then
        R.chase_fail_key, R.chase_fail_t = nil, 0
        return false
    end

    note_chase_failure(unit, t)
    return false
end

function C.in_combat_movement()
    return O.owns(OWNER.COMBAT)
end

function C.combat_unit()
    return R.combat_target
end

-- ============================================================================
-- COMBAT END CONDITIONS
-- ============================================================================
--- Every condition that must hold before combat movement may hand the player
--- back to navigation. Returns true plus nil, or false plus the blocking reason.
function C.may_release(player)
    if not player then return true end
    if R.rest_lock then return false, "resting" end
    if izi.now() < R.retreat_until then return false, "retreating" end

    local ok, v = pcall(player.is_in_combat, player)
    if ok and v == true then return false, "in combat" end
    -- The combat callbacks are a fast-path hint, not the truth. A poll that says
    -- we are out of combat wins and clears a stale flag, so a missed or
    -- mis-scoped on_combat_finish cannot strand us in COMBAT forever.
    if ok and v == false then
        R.in_combat_flag = false
    elseif R.in_combat_flag then
        return false, "combat flag"
    end

    ok, v = pcall(player.is_channeling_or_casting, player)
    if ok and v == true then return false, "casting" end

    if R.combat_target and unit_valid(R.combat_target) and unit_alive(R.combat_target) then
        local ready = Rg.in_fight_range(player, R.combat_target, R.combat_yards)
        if ready then return false, "target alive in range" end
    end

    -- anything else still worth positioning for?
    local list = live_enemies(player, R.combat_yards)
    if type(list) == "table" then
        for i = 1, #list do
            local e = list[i]
            if unit_valid(e) and unit_alive(e) then
                local okv, valid_enemy = pcall(e.is_valid_enemy, e)
                if okv and valid_enemy == true then
                    local oke, e_cbt = pcall(e.is_in_combat, e)
                    if oke and e_cbt == true then return false, "enemy engaged" end
                end
            end
        end
    end

    local mc = melee_count(player)
    if mc > 0 then return false, "enemy in melee" end

    return true
end

--- Release combat movement and hand the player back. Callers use this when they
--- abandon a fight; the state machine also calls it once every end condition
--- has held for COMBAT_EXIT_HOLD.
function C.combat_release()
    -- The fight is over: a leg issued to close on its target has nothing
    -- left to do (2.70.0). Left running, it held Sentinel "active" and
    -- blocked every move after the fight.
    if R.sn_active and R.sn_why == "pull" then
        N.stop()
        W.clear_dest()
    end
    R.combat_req = false
    R.combat_target = nil
    R.combat_guid = nil
    R.combat_stopped = false
    R.retreat_until = 0
    R.combat_ok_since = 0
    R.chase_fail_key, R.chase_fail_t = nil, 0
    if not O.owns(OWNER.COMBAT) then return false end
    O.halt_all()
    R.cur_owner = OWNER.NONE
    W.set_quiet(QUIET_STOP)
    dlog("combat", "released")
    return true
end

return C
