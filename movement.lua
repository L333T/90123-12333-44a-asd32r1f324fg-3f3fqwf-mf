-- ============================================================================
-- Master Farmer - Grindbot
-- Movement - public facade
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.0.2
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- 3.0.0 RECODE ON THE AMEISENNAV 2.0.0 API (docs/API.md). AmeisenNav does
-- every walk: navmesh paths, wall traces (safe collision mask, crash-guarded),
-- object avoidance, corner cutting, stuck recovery, swim / indoor profiles.
-- This layer decides where to go and when to stand still:
--
--   travel   nav_to / follow_route / nav_stop      movement/nav
--   combat   combat_engage / combat_release        movement/combat
--   holds    rest, cast, channel, loot, backpedal  movement/locks
--   sight    facing, line of sight, arrival        movement/range, sight
--   corridor recorded-path leash (path_runner)      movement/leash
--   areas    blacklisted areas                     movement/zones
--
-- The surface below is the one the rest of the bot calls (every name has
-- callers; the 2.x helpers nobody called are gone). Reading a name that does
-- not exist is logged once and answers nil.
-- ============================================================================

local R  = require("movement/core")
local Z  = require("movement/zones")
local N  = require("movement/nav")
local Lk = require("movement/locks")
local Rg = require("movement/range")
local C  = require("movement/combat")
local L  = require("movement/leash")

local movement = {}

-- GUI snapshot state (built in movement.pulse, read by debug_snapshot)
local SNAP_EVERY = 0.5
local snap = { state = "idle", owner = "none", quiet = false }
local snap_t = -1e9
local build_snapshot

-- ============================================================================
-- TRAVEL
-- ============================================================================
movement.nav_to       = function(dest, direct) return N.nav_to(dest, direct) end
movement.nudge        = function(dest) return N.nav_to(dest) end
movement.follow_route = N.follow_route
movement.nav_path     = function(points) return N.follow_route(points) end
movement.nav_stop     = function() N.stop("Master Farmer") end
movement.is_moving    = function() return N.busy() or R.backpedal_until ~= nil end
movement.is_navigating = function() return N.busy() and not C.in_combat_movement() end
movement.sentinel_active = N.busy
movement.is_quiet     = function() return R.now() < (R.quiet_until or 0) end

--- The running walk's destination is within `yards` (2D) of `pos`.
function movement.headed_to(pos, yards)
    local dx, dy = N.destination()
    local x, y = R.xyz(pos)
    if not dx or not x then return false end
    return R.dist2(dx, dy, x, y) <= (tonumber(yards) or 15)
end

-- "long travel" / approach hints: AmeisenNav needs neither (one path to the
-- real destination); kept so the callers' bookkeeping stays simple.
local hints = { keep = false, approach = nil, target = nil }
movement.keep_path           = function(on) hints.keep = on == true end
movement.set_approach        = function(kind) hints.approach = kind end
movement.set_approach_target = function(guid) hints.target = guid end

--- Everything stops: walk, fight, holds, backpedal.
function movement.halt()
    C.combat_release()
    Lk.clear()
    N.stop("halt")
end

-- ============================================================================
-- FAILURES
-- ============================================================================
movement.last_fail_reason  = N.last_fail_reason
movement.last_fail_offmesh = N.last_fail_offmesh
movement.clear_fail        = N.clear_fail

-- ============================================================================
-- COMBAT
-- ============================================================================
movement.combat_engage        = C.combat_engage
movement.combat_release       = C.combat_release
movement.in_combat_movement   = C.in_combat_movement
movement.combat_unit          = C.combat_unit
movement.combat_in_position   = C.in_position
movement.set_combat_profile   = C.set_combat_profile
movement.clear_combat_profile = C.clear_combat_profile

-- ============================================================================
-- FACING / SIGHT / RANGE
-- ============================================================================
movement.face           = Rg.face
movement.has_los        = Rg.has_los
movement.in_fight_range = Rg.in_fight_range
movement.arrived        = Rg.arrived
movement.line_blocked   = Rg.line_blocked
movement.can_reach      = Rg.can_reach
--- Ground height: no ray of our own - the hint stands (AmeisenNav corrects
--- heights where it walks).
movement.ground_z       = function(_, _, hint_z) return hint_z end

-- ============================================================================
-- AREAS
-- ============================================================================
movement.is_blocked     = Z.is_blocked
movement.blacklist_area = Z.blacklist_area

-- ============================================================================
-- HOLDS
-- ============================================================================
movement.set_resting     = Lk.set_resting
movement.release         = Lk.release
movement.cast_cancelled  = Lk.cast_cancelled
movement.prepare_cast    = Lk.prepare_cast
movement.prepare_channel = Lk.prepare_channel
movement.prepare_ground  = Lk.prepare_ground
movement.pause_for_loot  = Lk.pause_for_loot
movement.backpedal       = Lk.backpedal
movement.backpedaling    = Lk.backpedaling

-- 3.0.2: AT AN NPC. Every NPC interaction goes through movement.interact:
-- the walk stops and travel is held NPC_HOLD s from the LAST interaction,
-- so a window, gossip, purchase, repair or turn-in completes before the
-- bot walks off (walking away closed trainer / merchant windows). Fights
-- are not held (combat_engage walks regardless).
local NPC_HOLD = 2.0
local function event_clock()
    -- events.lua stamps UI errors with izi.now(); the too-far check compares
    -- against that clock
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then
        local okn, t = pcall(izi.now)
        if okn and type(t) == "number" then return t end
    end
    return nil
end

function movement.npc_hold(seconds)
    R.npc_until = R.now() + (tonumber(seconds) or NPC_HOLD)
    R.npc_ev_t = event_clock()
    if N.busy() then N.stop("at an NPC") end
end

function movement.npc_holding()
    return (R.npc_until or 0) > R.now()
end

--- Interact with an NPC and hold travel NPC_HOLD s. True when sent.
function movement.interact(unit)
    if not unit then return false end
    movement.npc_hold()
    local ok = pcall(function() core.input.interact_with_object(unit) end)
    return ok
end

-- ============================================================================
-- RECORDED-PATH CORRIDOR (path_runner)
-- ============================================================================
movement.set_path_leash    = L.set_path_leash
movement.clear_path_leash  = L.clear_path_leash
movement.needs_rejoin      = L.needs_rejoin
movement.rejoin_path       = L.rejoin_path
movement.path_anchor_index = L.path_anchor_index

-- ============================================================================
-- NAVMESH QUERIES
-- ============================================================================
movement.reachable         = N.reachable
movement.node_reachable    = N.node_reachable
movement.reach_z           = N.reach_z
movement.reach_forget      = N.reach_forget
movement.plan_grind_route  = N.plan_grind_route
movement.grind_visit_order = N.grind_visit_order
movement.nav_stats         = function() return N.stats end

-- ============================================================================
-- SPELLS (spellcheck.lua records each cast sent; class retreat rules read it)
-- ============================================================================
function movement.note_spell(id, target)
    R.last_spell_id, R.last_spell_target, R.last_spell_t = id, target, R.now()
end

function movement.last_player_spell()
    return R.last_spell_id, R.last_spell_target, R.last_spell_t
end

-- ============================================================================
-- PER FRAME / DEBUG
-- ============================================================================
--- Once per frame (main.lua), before anything reads movement state.
function movement.pulse()
    local t = R.now()
    Lk.tick(t)
    N.pulse()
    Z.prune(t)
    if t - snap_t >= SNAP_EVERY then build_snapshot(t) end
end

function movement.on_render() end

function movement.set_debug(on) R.debug_on = on == true end

function movement.owner()
    if C.in_combat_movement() then return "combat" end
    if N.busy() then return "nav" end
    return "none"
end

function movement.state()
    local c = N.client()
    if c and type(c.get_full_state) == "function" then
        local ok, s = pcall(c.get_full_state, c)
        if ok then return s end
    end
    return N.busy() and "navigating" or "idle"
end

-- The GUI movement panel is drawn on the RENDER path, where no game call
-- may run (AmeisenNav docs: a game call inside the menu render crashed WoW
-- Forever). The snapshot is built on the update tick (movement.pulse, every
-- SNAP_EVERY s) and the panel only reads this cached table.
build_snapshot = function(t)
    local u = C.combat_unit()
    local d = nil
    if u then
        local me = R.me()
        if me then
            local ok, v = pcall(me.distance_to, me, u)
            if ok and type(v) == "number" then d = v end
        end
    end
    snap = {
        state = movement.state(),
        owner = movement.owner(),
        restriction = R.resting and "resting" or (R.backpedal_until and "backpedal" or nil),
        retreating = false,
        paused = R.resting == true,
        sentinel = N.busy(),
        quiet = t < (R.quiet_until or 0),
        target_dist = d,
    }
    snap_t = t
end

--- For the GUI movement panel: the cached snapshot (no game call).
function movement.debug_snapshot()
    return snap
end

-- ============================================================================
-- STRICT SURFACE
-- ============================================================================
local missing_reported = {}
setmetatable(movement, {
    __index = function(_, key)
        if type(key) == "string" and not missing_reported[key] then
            missing_reported[key] = true
            pcall(core.log_error, R.TAG .. " movement." .. key .. " does not exist (stale call site)")
        end
        return nil
    end,
})

return movement
