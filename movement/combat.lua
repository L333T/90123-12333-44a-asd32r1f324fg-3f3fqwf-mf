-- ============================================================================
-- Master Farmer - Grindbot
-- movement/combat.lua - closing on a target and standing in range
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.0.4
-- ============================================================================
-- combat_engage(player, unit, yards) is called every tick of a fight.
--   * OWNERSHIP: each call holds travel off for COMBAT_HOLD s
--     (R.combat_until); combat_release() hands the player back at once.
--   * IN POSITION: in sight and within the band - melee (yards <= 5): the
--     GUI melee distance, held to +1 yd; ranged: CHASE_BAND inside the range,
--     held to the full range. The walk stops, the player faces the target,
--     and true is returned (the caller attacks).
--   * CLOSING: AmeisenNav walks to the target (seamless re-paths as it
--     moves; a unit standing on the goal is never an obstacle there), and
--     false is returned. Out of sight closes in until it is in sight.
--   * NO WAY CLOSER: no CHASE_GAIN yd of progress for CHASE_STALL s while
--     out of position - the target is marked unreachable
--     (state.mark_unreachable), which grind / quest check to drop it.
--   * RETREAT: a class profile's should_retreat(ctx) (mage, priest) sends
--     the player to AmeisenNav's kite point (client:kite) for RETREAT_TIME s.
-- ============================================================================

local R = require("movement/core")
local N = require("movement/nav")
local Rg = require("movement/range")

local C = {}

local COMBAT_HOLD = 1.0
local MELEE_YARDS = 5
local CHASE_BAND = 3
local CHASE_GAIN, CHASE_STALL = 2.0, 10.0
-- 3.0.0.1: the chase re-paths only when the target moved CHASE_REPATH yd
-- from the walk's goal, at most every CHASE_GAP s. AmeisenNav's walker
-- driver restarts on every new path, and a re-path every 0.25 s made the
-- chase stutter and fall behind (log 01:44, 48 -> 53 yd while "Closing").
local CHASE_REPATH, CHASE_GAP = 4.0, 0.75
local RETREAT_TIME = 2.5
local DEFAULT_MELEE_DANGER = 8

local st = {
    guid = nil, unit = nil, yards = nil,
    latched = false,
    best = nil, best_t = 0,
    retreat_until = 0, kite_pending = false,
    profile = nil,
}

function C.set_combat_profile(p)
    st.profile = type(p) == "table" and p or nil
end

function C.clear_combat_profile()
    st.profile = nil
end

local function state_mod()
    local ok, s = pcall(require, "state")
    if ok and type(s) == "table" then return s end
    return nil
end

local function want_retreat(player, unit, range)
    local p = st.profile
    if not p or type(p.should_retreat) ~= "function" then return false end
    local enemies = {}
    local oke, list = pcall(player.get_enemies_in_range, player, tonumber(p.melee_danger) or DEFAULT_MELEE_DANGER, false)
    if oke and type(list) == "table" then enemies = list end
    local ctx = {
        player = player, target = unit, distance = range, melee_count = #enemies, enemies = enemies,
        last_spell_id = R.last_spell_id, last_spell_target = R.last_spell_target,
        last_spell_age = R.now() - (R.last_spell_t or 0),
    }
    local ok, v = pcall(p.should_retreat, ctx)
    return ok and v == true
end

local function start_retreat(player, unit)
    if st.kite_pending then return end
    local c = N.client()
    if not c or type(c.kite) ~= "function" then return end
    local okp, pp = pcall(player.get_position, player)
    local oku, up = pcall(unit.get_position, unit)
    if not okp or not oku or not pp or not up then return end
    st.kite_pending = true
    local ok = pcall(c.kite, c, R.point(pp), R.point(up), function(point)
        st.kite_pending = false
        if point and N.nav_to(point, true, "combat") then
            st.retreat_until = R.now() + RETREAT_TIME
            R.trail("move", "retreat to the kite point (%.0f, %.0f)", point.x or 0, point.y or 0)
        end
    end)
    if not ok then st.kite_pending = false end
end

--- True when in position to attack `unit` from `yards`; false while closing.
function C.combat_engage(player, unit, yards)
    if not player or not unit then return false end
    if R.resting or R.backpedal_until then return false end
    if not R.alive(unit) then return false end
    yards = tonumber(yards) or 20
    if yards < 1 then yards = MELEE_YARDS end
    local t = R.now()
    R.combat_until = t + COMBAT_HOLD

    local guid = R.guid(unit)
    if guid == nil or guid ~= st.guid then
        st.guid, st.latched, st.best, st.best_t = guid, false, nil, t
        st.retreat_until, st.kite_pending = 0, false
    end
    st.unit, st.yards = unit, yards

    local okd, range = pcall(player.distance_to, player, unit)
    if not okd or type(range) ~= "number" then return false end
    local los = Rg.has_los(player, unit)
    local melee = yards <= MELEE_YARDS
    local reach = melee and yards or math.max(MELEE_YARDS, yards - CHASE_BAND)
    local hold = melee and (yards + 1) or yards
    local ready = los and range <= hold

    -- retreating: the kite walk runs, the caller casts what it can
    if t < st.retreat_until then return ready end
    if want_retreat(player, unit, range) then
        start_retreat(player, unit)
        if t < st.retreat_until or st.kite_pending then return ready end
    end

    if los and (range <= reach or (st.latched and range <= hold)) then
        -- 3.0.0.1: ANY running walk stops here, not only the chase - the
        -- route walk kept going through a fight and carried the player out
        -- of range, unable to face the target (log 01:44, 14 -> 48 yd)
        if N.busy() then N.stop("in range") end
        st.latched = true
        st.best, st.best_t = range, t
        Rg.face(unit)
        return true
    end
    st.latched = false

    -- closing
    if st.best == nil or range < st.best - CHASE_GAIN then
        st.best, st.best_t = range, t
    elseif (t - st.best_t) >= CHASE_STALL then
        local s = state_mod()
        if s and guid and type(s.mark_unreachable) == "function" then s.mark_unreachable(guid) end
        R.trail("move", "no way closer to %s for %.0f s (%.0f yd%s) - marked unreachable",
            tostring(select(2, pcall(unit.get_name, unit))), t - st.best_t, range, los and "" or ", out of sight")
        st.best, st.best_t = range, t
        return false
    end
    local okp, pos = pcall(unit.get_position, unit)
    if okp and pos then
        local tx, ty = R.xyz(pos)
        local gx, gy = N.destination()
        local chasing = N.mode() == "combat" and N.busy()
        local moved = (not gx or not tx) or R.dist2(gx, gy, tx, ty) > CHASE_REPATH
        if not chasing or (moved and (t - (st.chase_t or 0)) >= CHASE_GAP) then
            st.chase_t = t
            N.nav_to(pos, true, "combat")
        end
    end
    return false
end

function C.in_combat_movement()
    return (R.combat_until or 0) > R.now()
end

--- The unit being fought, never a freed one.
function C.combat_unit()
    if st.unit and R.alive(st.unit) then return st.unit end
    return nil
end

--- Latched in position against a live target while combat is asked for.
function C.in_position()
    if not st.latched or not C.in_combat_movement() then return false end
    if R.resting or R.backpedal_until or R.now() < st.retreat_until then return false end
    return C.combat_unit() ~= nil
end

--- Give the player back (loot, quest approach, fight over).
function C.combat_release()
    R.combat_until = 0
    st.latched = false
    st.retreat_until = 0
    if N.mode() == "combat" then N.stop("combat over") end
end

return C
