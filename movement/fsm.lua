-- ============================================================================
-- Master Farmer - Grindbot
-- movement/fsm.lua - stuck watch, arbitration, per-frame pulse, events
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.117.0
-- ============================================================================
-- The top of the movement stack. Nothing requires this module except the
-- facade, so it is free to depend on every layer below it.
--
-- State transitions are debounced: escalations (restriction, combat entry) are
-- immediate; releases must hold for a settle window. Nothing toggles per frame.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type movement_handler
local handler = require("common/utility/movement_handler")

local K = require("movement/const")
local R = require("movement/rt")
local U = require("movement/util")
local Z = require("movement/zones")
local L = require("movement/leash")
local W = require("movement/walker")
local N = require("movement/sentinel")
local O = require("movement/own")
local C = require("movement/combat")
local RP = require("movement/repath")      -- 2.84.0: re-aim + stuck ladder
local Lk_mod = require("movement/locks")

local STATE             = K.STATE
local OWNER             = K.OWNER
local SETTLE            = K.SETTLE
local COMBAT_EXIT_HOLD  = K.COMBAT_EXIT_HOLD
local PATH_LEASH        = K.PATH_LEASH
local STUCK_GRACE       = K.STUCK_GRACE
local STUCK_MOVE        = K.STUCK_MOVE
local STUCK_ZONE_RADIUS = K.STUCK_ZONE_RADIUS

local pt = R.pt
local here_xyz, dist2, dlog = U.here_xyz, U.dist2, U.dlog

local P_TMP = R.P_TMP

local F = {}

-- ============================================================================
-- STUCK WATCH
-- ============================================================================
-- ============================================================================
-- LOOK-AHEAD AVOIDANCE (2.82.0)
-- ============================================================================
-- A walker move was checked once, when it was issued, and then walked blind.
-- Every LOOK_GAP while the walker (not Sentinel) is moving and nothing has it
-- paused, the body corridor LOOKAHEAD yards ahead toward the destination is
-- re-checked; when it has closed, a detour hop is steered and issued at once,
-- so the character turns before it walks into the obstacle. The caller
-- re-issues its real destination when the detour hop is done.
local LOOKAHEAD = K.LOOKAHEAD
local LOOK_GAP = K.LOOK_GAP
local look_next = 0
local S_mod = nil

local function look_ahead(t)
    if t < look_next then return end
    look_next = t + LOOK_GAP
    if not R.walker_moving or R.sn_active or not R.has_dest or R.rest_lock then return end
    local pr = R.pause_reason
    if pr.cast or pr.restrict or pr.rest or pr.loot or pr.nav then return end
    local x, y, z = here_xyz()
    if not x then return end
    local remain = dist2(x, y, R.dest_x, R.dest_y)
    if remain <= 1.5 then return end
    local here = pt(R.P_HERE, x, y, z)
    -- A plain table, not a pool slot: the steering search below reuses the pool.
    local dest = { x = R.dest_x, y = R.dest_y, z = R.dest_z }
    local ahead = dest
    if remain > LOOKAHEAD then
        local s = LOOKAHEAD / remain
        ahead = pt(R.P_MID, x + (R.dest_x - x) * s, y + (R.dest_y - y) * s, z + (R.dest_z - z) * s)
    end
    -- Walking into a too-high mob's radius counts as blocked (2.95.0).
    local danger_ahead = Z.dangerous_xy(ahead.x, ahead.y) and not Z.dangerous_xy(R.dest_x, R.dest_y)
    if not danger_ahead and U.corridor(here, ahead) ~= false then return end
    if not S_mod then
        local ok, m = pcall(require, "movement/steer")
        S_mod = ok and m or false
    end
    if not S_mod then return end
    local hop = S_mod.pick_steer(here, dest, K.STEER_HOP, false, true)
    if hop then
        local keep_x, keep_y, keep_z = R.dest_x, R.dest_y, R.dest_z
        dlog("avoid", string.format("obstacle ahead - detour to (%.1f, %.1f)", hop.x, hop.y))
        if W.move(hop, "avoid") then
            -- keep the real destination known for the next look-ahead / stuck check
            R.dest_x, R.dest_y, R.dest_z = keep_x, keep_y, keep_z
            R.avoid_hops = (R.avoid_hops or 0) + 1
        end
    end
end

-- ============================================================================
-- HOP CHAINING (2.85.0)
-- ============================================================================
-- Steering walks in hops of a few yards. When one ended the character
-- stopped, the move was cleared 0.3 s later and the caller re-issued after
-- the move gap - up to a second standing still per hop. Now, while a hop is
-- walked, the NEXT hop toward the leg's real end (R.goal_*) is planned from
-- this hop's end point, and issued as soon as the character is within
-- CHAIN_DIST of it, so the walk flows on. Navigation only (combat re-issues
-- every COMBAT_GAP by itself).
local CHAIN_DIST = K.CHAIN_DIST
local chain_next = 0
local planned = nil          -- { x, y, z } of the pre-computed next hop

local function chain_hops(t)
    if not R.walker_moving or R.sn_active or not R.has_dest or not R.goal_x then
        planned = nil
        return
    end
    if R.cur_owner ~= K.OWNER.NAV then planned = nil return end
    local pr = R.pause_reason
    if pr.cast or pr.restrict or pr.rest or pr.loot or pr.nav then return end
    local x, y, z = here_xyz()
    if not x then return end
    -- the leg is done: nothing to chain
    if dist2(R.dest_x, R.dest_y, R.goal_x, R.goal_y) < 1.0
        or dist2(x, y, R.goal_x, R.goal_y) <= CHAIN_DIST then
        planned = nil
        return
    end
    if not S_mod then
        local ok, m = pcall(require, "movement/steer")
        S_mod = ok and m or false
    end
    if not S_mod then return end
    -- plan the next hop from THIS hop's end, while walking (every LOOK_GAP)
    if t >= chain_next or not planned then
        chain_next = t + LOOK_GAP
        local from = { x = R.dest_x, y = R.dest_y, z = R.dest_z }
        local goal = { x = R.goal_x, y = R.goal_y, z = R.goal_z }
        local hop = S_mod.steer(from, goal, K.PATROL_HOP)
        planned = hop and { x = hop.x, y = hop.y, z = hop.z } or nil
    end
    if not planned then return end
    if dist2(x, y, R.dest_x, R.dest_y) > CHAIN_DIST then return end
    -- about to arrive: go straight on to the next hop, if the body fits
    local here = pt(R.P_HERE, x, y, z)
    if U.corridor(here, planned) == false then
        planned = nil
        return
    end
    local gx, gy, gz = R.goal_x, R.goal_y, R.goal_z
    local hop = pt(P_TMP, planned.x, planned.y, planned.z)
    planned = nil
    if W.move(hop, "chain") then
        R.goal_x, R.goal_y, R.goal_z = gx, gy, gz
        dlog("chain", string.format("next hop (%.1f, %.1f) - no stop", hop.x, hop.y))
    end
end

local function watch_stuck(t)
    local x, y = here_xyz()
    if not R.pending or R.rest_lock or not x then
        R.stuck_x, R.stuck_y, R.stuck_since = x, y, t
        return
    end
    if not R.stuck_x or dist2(x, y, R.stuck_x, R.stuck_y) >= STUCK_MOVE then
        R.stuck_x, R.stuck_y, R.stuck_since = x, y, t
        return
    end
    if (t - R.stuck_since) < STUCK_GRACE then return end
    R.stuck_grace_until = t + STUCK_GRACE
    -- The re-pathing ladder decides what "stuck" means now (2.84.0): re-plan,
    -- then unstick, then give the goal up - instead of cancelling and
    -- blacklisting on the first standstill.
    if RP.stuck_now(t) then
        R.stuck_x, R.stuck_y, R.stuck_since = x, y, t
        return
    end
    W.set_quiet(1.5)
    local had, dx, dy, dz = R.has_dest, R.dest_x, R.dest_y, R.dest_z
    W.clear_dest()
    W.halt()
    if had and dist2(x, y, dx, dy) > 16 then
        Z.blacklist_area(pt(P_TMP, dx, dy, dz), STUCK_ZONE_RADIUS, "stuck")
    end
    dlog("stuck", "move cancelled")
    R.stuck_x, R.stuck_y, R.stuck_since = x, y, t
end

-- ============================================================================
-- ARBITRATION
-- ============================================================================
--- Resolve state and ownership for this tick, in strict priority order.
local function arbitrate(player, t)
    -- 1 + 2. invalid / dead / crowd control / resting
    local why = O.restriction_of(player)
    if why then
        R.restrict_why = why
        if R.restrict_since == 0 then R.restrict_since = t end
        R.clear_since = 0
        W.set_pause("restrict", true)
        if R.cur_state ~= STATE.RESTRICTED then
            O.halt_all()
            R.cur_owner = OWNER.NONE
            O.set_state(STATE.RESTRICTED, why)
        end
        return
    end

    -- restrictions must stay clear for SETTLE before we steer again
    if R.clear_since == 0 then R.clear_since = t end
    if (t - R.clear_since) < SETTLE then
        R.restrict_why = nil
        return
    end
    R.restrict_why, R.restrict_since = nil, 0
    W.set_pause("restrict", false)

    -- 3. combat movement
    if R.combat_req and (t - R.combat_req_t) <= 1.0 then
        R.combat_ok_since = 0
        if R.cur_state ~= STATE.COMBAT then O.set_state(STATE.COMBAT, "engaged") end
        return
    end

    -- combat was requested recently but the caller has stopped asking: hold the
    -- player until every end condition has been true for COMBAT_EXIT_HOLD
    if R.cur_state == STATE.COMBAT or O.owns(OWNER.COMBAT) then
        local may, blocker = C.may_release(player)
        if not may then
            R.combat_ok_since = 0
            dlog("combat_end", "holding: " .. tostring(blocker))
            return
        end
        if R.combat_ok_since == 0 then
            R.combat_ok_since = t
            dlog("combat_end", "all clear - settling")
            return
        end
        if (t - R.combat_ok_since) < COMBAT_EXIT_HOLD then return end
        C.combat_release()
        O.set_state(STATE.IDLE, "combat complete")
        return
    end

    -- 4. navigation / idle
    if O.owns(OWNER.NAV) and O.is_moving() then
        if R.cur_state ~= STATE.NAVIGATION then O.set_state(STATE.NAVIGATION, "moving") end
    elseif R.cur_state ~= STATE.IDLE then
        O.set_state(STATE.IDLE, "nothing to do")
    end
end

-- ============================================================================
-- PER-FRAME
-- ============================================================================
-- Flight-recorder probe (2.68.0). Free unless the Crash Recorder box is ticked:
-- then each one is a disk line, and the last line before a crash names the
-- native call the game died in.
local probe_el = nil
local function xprobe(tag)
    if probe_el == nil then
        local ok, m = pcall(require, "errorlog")
        probe_el = (ok and type(m) == "table" and type(m.probe) == "function") and m or false
    end
    if probe_el then
        pcall(probe_el.probe, tag)
    end
end

function F.pulse()
    R.pulse_tick = R.pulse_tick + 1
    R.traces_used = 0
    W.ensure()
    local t = izi.now()
    -- Backpedalling (2.97.0): nothing else may steer until it ends.
    if Lk_mod.backpedal_tick(t) then
        return
    end

    local player = nil
    local okp, me = pcall(izi.me)
    if okp then player = me end

    -- Sentinel owns the tick while it is driving: the walker must stay silent.
    if R.sn_active then
        R.walker_moving = false
        xprobe("mv:sentinel watch")
        N.watch(t)
        RP.update(t)
        xprobe("mv:arbitrate")
        arbitrate(player, t)
        if (t - R.combat_req_t) > K.COMBAT_REQ_TTL then R.combat_req = false end
        Z.prune(t)
        return
    end

    xprobe("mv:walker")
    if W.process() then W.clear_dest() end
    W.sample()
    if R.pending and not R.walker_moving and (t - R.last_move_t) >= 0.3 then
        W.clear_dest()        -- walker has no destination: it finished or gave up
    end

    watch_stuck(t)
    look_ahead(t)
    chain_hops(t)
    RP.update(t)
    if R.leash and not R.leash_armed and not R.rest_lock then
        local _, _, _, d = L.here_on_leash()
        if d and d <= PATH_LEASH then R.leash_armed = true end
    end

    xprobe("mv:arbitrate")
    arbitrate(player, t)
    xprobe("mv:done")
    -- Callers re-assert every BOT tick, which since 2.28.0 is 10 Hz rather
    -- than every frame; the request stays live for COMBAT_REQ_TTL so the
    -- frames between two bot ticks do not read as "combat stopped".
    if (t - R.combat_req_t) > K.COMBAT_REQ_TTL then R.combat_req = false end
    Z.prune(t)
end

function F.on_render()
    -- Only with the movement debug box ticked (2.72.0): the handler's render
    -- pass only draws its own debug lines, and it reads whatever it was last
    -- told to look at - every frame, for the whole session.
    if R.debug_on then
        pcall(handler.on_render, handler)
    end
end

function F.set_debug(on)
    R.debug_on = on == true
end

-- ============================================================================
-- EVENTS  (events update state, they never issue movement)
-- ============================================================================
do
    --- True when the event describes the local player. The payload is
    --- { unit = game_object }; anything else is somebody else's fight.
    local function is_me(ev)
        if type(ev) ~= "table" then return false end
        local unit = ev.unit
        if unit == nil then return true end        -- no unit field: player event
        local ok, me = pcall(izi.me)
        if not ok or me == nil then return false end
        -- GUIDs, not `unit == me`: object __eq throws on a freed object.
        local ok1, g1 = pcall(unit.get_guid, unit)
        local ok2, g2 = pcall(me.get_guid, me)
        return ok1 and ok2 and g1 ~= nil and g1 == g2
    end

    if type(izi.on_combat_start) == "function" then
        pcall(izi.on_combat_start, function(ev)
            if is_me(ev) then R.in_combat_flag = true end
        end)
    end
    if type(izi.on_combat_finish) == "function" then
        pcall(izi.on_combat_finish, function(ev)
            if is_me(ev) then R.in_combat_flag = false end
        end)
    end
    -- the class profile reads these to decide whether a retreat is warranted
    if type(izi.on_spell_success) == "function" then
        pcall(izi.on_spell_success, function(ev)
            if type(ev) ~= "table" then return end
            local caster = ev.caster
            local okp, me = pcall(izi.me)
            if not okp or not me or not caster then return end
            local ok1, g1 = pcall(caster.get_guid, caster)
            local ok2, g2 = pcall(me.get_guid, me)
            if not (ok1 and ok2) or g1 == nil or g1 ~= g2 then return end
            R.last_spell_id = ev.spell_id
            R.last_spell_target = ev.target
            R.last_spell_t = izi.now()
        end)
    end
end

function F.last_player_spell()
    return R.last_spell_id, R.last_spell_target, R.last_spell_t
end

return F
