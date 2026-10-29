-- ============================================================================
-- restedXP_questing
-- movement/combat.lua - closing on a target and standing in range
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.46.0
-- ============================================================================
-- 4.46.0 (the Astar movement engine port, group A of docs/ASTAR_ENGINE_PORT_PLAN.md):
-- this file no longer decides HOW a combat move is performed. It is the bridge
-- between the product's pull API - combat_engage(player, unit, yards) asked
-- once a tick by grind / quest - and the engine's push API in
-- engine/combat/registry.lua, which picks one verb a frame out of
-- engine/combat/verbs.lua.
--
-- WHAT MOVED OUT. The band and its hysteresis, the chase and its re-path gap,
-- the stall that marks a target unreachable, the retreat, the flee, the strafe
-- (strafe.lua) and the backpedal / blink are all verbs now. One verb owns the
-- keys at a time, and a verb that stops releases whatever it started on that
-- same frame. A class's rules are one registry.add row, not a should_retreat
-- closure per rotation file.
--
-- WHAT STAYED HERE, because it is this product's and not the engine's:
--   * OWNERSHIP: each call holds travel off for COMBAT_HOLD s (R.combat_until);
--     combat_release() hands the player back at once.
--   * the public names grind/engine.lua, loot.lua, movement.lua and the tests
--     use: combat_engage, combat_release, in_combat_movement, combat_unit,
--     in_position, set_combat_profile, clear_combat_profile.
--   * state.mark_unreachable when the engine gives a target up.
--   * the `yards` the caller worked out (GUI sliders, the hunter dead zone, the
--     rogue throw range) OVERRIDES the engine's own spell-book range: the
--     product knows about its sliders and the engine does not.
--
-- WHO OWNS WHAT NOW (the one-owner rule):
--   * movement/nav.lua still owns every walk, its token and its stuck ladder.
--     The engine is given nav's walk through set_walk_provider, so it decides
--     WHERE to go and nav does the going. engine recovery is OFF here
--     (set_recovery_enabled(false)) - two stuck recoveries on one walk is the
--     thing to avoid, and nav's ladder is the one that feeds the nav memory.
--   * movement/sentinel.lua stays the one adapter: the engine is handed
--     N.client() and never looks the global up.
--   * movement_handler keeps facing and the cast pause.
-- ============================================================================

local R = require("movement/core")
local N = require("movement/nav")
local Rg = require("movement/range")

-- The engine's three modules are fetched on first use. movement.lua requires
-- this file at load, and a load (or a test) that never reaches a fight should
-- not have to carry them - nor stub the modules they require in turn.
-- NOTE the names: Rg above is movement/range. The engine handles are ENG / VRB
-- / REG so nothing here can shadow it.
local ENG_mod, VRB_mod, REG_mod = nil, nil, nil

local function ENG()
    if ENG_mod == nil then
        local ok, mod = pcall(require, "engine/astar")
        ENG_mod = (ok and type(mod) == "table") and mod or false
    end
    return ENG_mod or nil
end

local function VRB()
    if VRB_mod == nil then
        local ok, mod = pcall(require, "engine/combat/verbs")
        VRB_mod = (ok and type(mod) == "table") and mod or false
    end
    return VRB_mod or nil
end

local function REG()
    if REG_mod == nil then
        local ok, mod = pcall(require, "engine/combat/registry")
        REG_mod = (ok and type(mod) == "table") and mod or false
    end
    return REG_mod or nil
end

--- True when all three loaded. Without them this file answers "not in
--- position" and nothing moves, rather than throwing once a frame.
local function ready()
    return ENG() ~= nil and VRB() ~= nil and REG() ~= nil
end

local C = {}

local COMBAT_HOLD = 1.0
local MELEE_YARDS = 5

C.FLEE_HP, C.FLEE_N = 20, 3        -- engine/combat/verbs.lua's own numbers

local st = {
    guid = nil, unit = nil, yards = nil,
    profile = nil, wired = false,
}

local function state_mod()
    local ok, s = pcall(require, "state")
    if ok and type(s) == "table" then return s end
    return nil
end

local gui_mod = nil
local function get_gui()
    if gui_mod == nil then
        local ok, mod = pcall(require, "gui")
        gui_mod = (ok and type(mod) == "table") and mod or false
    end
    return gui_mod or nil
end

local smart_mod = nil
local function get_smart()
    if smart_mod == nil then
        local ok, mod = pcall(require, "smart")
        smart_mod = (ok and type(mod) == "table") and mod or false
    end
    return smart_mod or nil
end

-- ----------------------------------------------------------------------------
-- THE AWAY POINT: Sentinel's own kite / flee, with the engine's local scan as
-- the fallback
-- ----------------------------------------------------------------------------
-- The engine asks for an away point synchronously (verbs.backoff / verbs.flee
-- want one on the frame they start), and nav's N.kite / N.flee answer over the
-- real navmesh but asynchronously. So the server answer is cached: a fresh one
-- for roughly this spot is handed over at once, and a stale one kicks off the
-- next request while this frame falls through to the engine's own arc scan
-- (trace-weighted, cliff- and steep-aware). Both kill switches stay nav's.
local AWAY_FRESH = 3.0         -- s an answer is good for
local AWAY_MOVED = 6.0         -- yd of player movement that makes it stale
local AWAY_WAIT = 3.0          -- s before a lost request is asked again
local away = { t = -1e9, ask_t = -1e9, pending = false, point = nil, x = nil, y = nil }

local function away_store(point)
    away.pending = false
    if type(point) ~= "table" then return end
    local x, y, z = R.xyz(point)
    if not x then return end
    away.point, away.t = { x = x, y = y, z = z }, R.now()
    local px, py = R.here()
    away.x, away.y = px, py
end

local function away_provider(from, threats, distance, watch)
    local t = R.now()
    if away.point and (t - away.t) < AWAY_FRESH and away.x
        and R.dist2(away.x, away.y, from.x, from.y) < AWAY_MOVED then
        return away.point
    end
    if away.pending and (t - away.ask_t) < AWAY_WAIT then return nil end
    local list = {}
    if type(threats) == "table" then
        for i = 1, #threats do list[#list + 1] = threats[i] end
    end
    away.ask_t = t
    local asked = false
    if #list >= C.FLEE_N then
        asked = N.flee(from, list, away_store) == true
    elseif list[1] then
        asked = N.kite(from, list[1], away_store) == true
    end
    away.pending = asked
    return nil                 -- this frame uses the engine's own scan
end

-- ----------------------------------------------------------------------------
-- WIRING: done once, lazily, so load order does not matter
-- ----------------------------------------------------------------------------
local function wire()
    if st.wired then return end
    st.wired = true

    local E, V, G = ENG(), VRB(), REG()
    if not (E and V and G) then
        st.wired = false
        return
    end

    -- movement/sentinel.lua stays the one adapter
    E.set_client_provider(function() return N.client() end)

    -- nav owns every walk and its token. The engine's arrival callback is not
    -- used here: nav does not take one, and no verb depends on it (they all
    -- read engine.travel_moving(), which asks the real client).
    E.set_walk_provider(function(kind, arg)
        if R.resting or R.backpedal_until then return false end
        if kind == "path" or kind == "route" then
            return N.follow_route(arg, true) == true
        end
        return N.nav_to(arg, true, "combat") == true
    end)
    E.set_stop_provider(function(reason)
        if N.mode() == "combat" and N.busy() then
            N.stop(reason or "combat")
        end
        return true
    end)

    -- nav's stuck ladder is the only recovery (it feeds the nav memory)
    E.set_recovery_enabled(false)

    E.set_away_point_provider(away_provider)

    -- RAY HEALTH IS SHARED (the rule that came out of the 2026-10-27 mid-match
    -- native crash: two switches, not one). A throw inside the engine's own
    -- traces is reported to movement/trace.lua, which is this product's switch.
    E.set_ray_error_reporter(function(why)
        local ok, TR = pcall(require, "movement/trace")
        if not ok or type(TR) ~= "table" then return end
        if type(TR.client_bad) == "function" then
            pcall(TR.client_bad, why)
        end
    end)

    -- the caller's yards win over the engine's spell-book resolver
    G.set_range_override(function() return st.yards end)
    G.set_target_reader(function() return st.unit end)

    G.set_settings_reader(function(name)
        local gui = get_gui()
        if gui and type(gui.is_on) == "function" then
            local ok, v = pcall(gui.is_on, name)
            if ok then return v == true end
        end
        return false
    end)

    G.set_wants_behind_reader(function(player, unit)
        local sm = get_smart()
        if sm and type(sm.rogue_wants_behind) == "function" then
            local ok, v = pcall(sm.rogue_wants_behind, player, unit)
            if ok then return v == true end
        end
        return false
    end)
end

C.wire = wire

-- ----------------------------------------------------------------------------
-- the profile: data only now (the decisions are registry rows)
-- ----------------------------------------------------------------------------
--- A rotation's combat_profile. Only its melee_danger / melee_safe are read -
--- the should_retreat decision lives in that class's registry row, so a
--- profile that still carries one is ignored.
function C.set_combat_profile(p)
    st.profile = type(p) == "table" and p or nil
    local G = REG()
    if not G then return end
    G.melee_danger = st.profile and tonumber(st.profile.melee_danger) or nil
    G.melee_safe = st.profile and tonumber(st.profile.melee_safe) or nil
end

function C.clear_combat_profile()
    st.profile = nil
    local G = REG()
    if not G then return end
    G.melee_danger, G.melee_safe = nil, nil
end

-- ----------------------------------------------------------------------------
-- the tick
-- ----------------------------------------------------------------------------
--- True when in position to attack `unit` from `yards`; false while closing,
--- and false while a flee runs (nothing is attacked then).
function C.combat_engage(player, unit, yards)
    if not player or not unit then return false end
    if R.resting or R.backpedal_until then return false end
    if not R.alive(unit) then return false end
    yards = tonumber(yards) or 20
    if yards < 1 then yards = MELEE_YARDS end
    local t = R.now()
    R.combat_until = t + COMBAT_HOLD

    local guid = R.guid(unit)
    st.guid, st.unit, st.yards = guid, unit, yards

    if not ready() then return false end
    wire()
    if not st.wired then return false end
    local G, V = REG(), VRB()
    G.start()
    local ok = pcall(G.tick)
    if not ok then
        -- a verb that threw must not hold the keys
        pcall(G.release)
        return false
    end

    -- the engine gave this target up (no CHASE_GAIN yd for CHASE_STALL s):
    -- grind / quest drop it on state.mark_unreachable, as they always have
    if V.close_unreachable(unit) and guid then
        local s = state_mod()
        if s and type(s.mark_unreachable) == "function" then
            s.mark_unreachable(guid)
            R.trail("move", "no way closer to %s - marked unreachable",
                tostring(select(2, pcall(unit.get_name, unit))))
        end
    end

    if V.fleeing() then return false end
    local ctx = G.ctx()
    return ctx ~= nil and ctx.in_position == true
end

--- Per frame from movement.pulse: when combat ownership has lapsed without a
--- combat_release (the fight ended elsewhere, the bot stopped), no verb may
--- keep a key or a walk.
function C.tick(t)
    if not st.wired then return end
    if C.in_combat_movement() then return end
    local G = REG()
    if G and G.is_running() then
        pcall(G.stop)
        st.unit, st.guid, st.yards = nil, nil, nil
    end
end

function C.in_combat_movement()
    return (R.combat_until or 0) > R.now()
end

--- The unit being fought, never a freed one.
function C.combat_unit()
    if st.unit and R.alive(st.unit) then return st.unit end
    return nil
end

--- In the band against a live target while combat is asked for. The band is a
--- plain question (engine in_band), so it is right on the frame a verb other
--- than close owns the keys.
function C.in_position()
    if not C.in_combat_movement() then return false end
    if R.resting or R.backpedal_until then return false end
    if not st.wired then return false end
    local V, G = VRB(), REG()
    if not (V and G) then return false end
    if V.fleeing() then return false end
    if C.combat_unit() == nil then return false end
    local ctx = G.ctx()
    return ctx ~= nil and ctx.in_position == true
end

--- Give the player back (loot, quest approach, fight over).
function C.combat_release()
    R.combat_until = 0
    if st.wired then
        local G = REG()
        if G then pcall(G.stop) end      -- releases the active verb's keys / walk
    end
    st.unit, st.guid, st.yards = nil, nil, nil
    away.point, away.pending = nil, false
    if N.mode() == "combat" then N.stop("combat over") end
end

--- 4.46.0: kept for the callers and tests that asked the old internal.
function C._flee_check()
    local V = VRB()
    return V ~= nil and V.fleeing() == true
end

--- What the engine is doing, for the debug snapshot.
function C.verb()
    local G = REG()
    if not G then return nil end
    return G.active_id()
end

C.face = Rg.face

return C
