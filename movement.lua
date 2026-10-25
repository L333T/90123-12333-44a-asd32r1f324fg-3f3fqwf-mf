-- ============================================================================
-- restedXP_questing
-- Movement - public facade
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.7.0
-- Folder: restedXP_questing
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
local Pv = require("movement/pivot")   -- 3.2.0: stop and turn on sharp waypoint turns
local Mt = require("movement/mount")   -- 3.8.0: mount for travel (the 1-60 way)

-- 3.8.0: Gathering uses its own "Use Mount" box; questing / grinding the
-- General tab one
Mt.enabled_fn = function()
    local ok, gui = pcall(require, "gui")
    if not ok or type(gui) ~= "table" or type(gui.is_on) ~= "function" then return true end
    return gui.is_on("mfg_mount") ~= false
end

-- 3.2.0: the GUI switch (Path tab, "Stop and Turn on Sharp Turns", on by default)
Pv.set_enabled_fn(function()
    local ok, gui = pcall(require, "gui")
    if not ok or type(gui) ~= "table" or type(gui.is_on) ~= "function" then return true end
    local v = gui.is_on("sharp_turn_stop")
    return v ~= false
end)

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
-- 3.5.0: RestedXP waypoints / movement instructions: 3-yard, object-checked walks
movement.guide_to     = function(dest) return N.nav_to(dest, true, "guide") end
movement.follow_route = N.follow_route
movement.want_input_driver = N.want_input_driver      -- 4.0.4 (gui Start / Stop)
movement.nav_path     = function(points) return N.follow_route(points) end
-- 3.0.4: callers stop every tick once "near" an NPC (4-5 yd); an approach
-- movement.interact started (to NPC_REACH) is not cancelled by that
local npc_walk = { until_t = 0 }
movement.nav_stop     = function()
    if R.now() < npc_walk.until_t and N.mode() == "npc" then return end
    N.stop("Master Farmer")
end
movement.is_moving    = function() return N.busy() or R.backpedal_until ~= nil end
movement.is_navigating = function() return N.busy() and not C.in_combat_movement() end
movement.sentinel_active = N.busy
movement.path_points  = N.path_points          -- 4.7.0: quest/threat reads the path ahead
movement.path_index   = N.path_index
movement.nav_mode     = N.mode
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
    Pv.release("halt")
    C.combat_release()
    Lk.clear()
    N.stop("halt")
    N.release_driver_now()                               -- 4.0.4: unload puts the driver back
end

-- ============================================================================
-- FAILURES
-- ============================================================================
movement.last_fail_reason  = N.last_fail_reason
movement.last_fail_offmesh = N.last_fail_offmesh
movement.clear_fail        = N.clear_fail
movement.nav_pending       = N.pending            -- 4.0.8: planning / asking a floor
movement.server_trouble    = N.server_trouble     -- 4.0.8: a server code, not the place

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
-- 3.0.4: the player walks to within NPC_REACH yd of the NPC first (the
-- callers stopped at 4-5 yd and the game answered "too far away"), and the
-- hold is NPC_HOLD = 10 s (user: stay long enough for the actions).
local NPC_HOLD = 10.0
local NPC_REACH = 3.0
movement.NPC_REACH = NPC_REACH
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
--- Farther than NPC_REACH: walks up to the NPC instead and answers false
--- (the caller's next attempt interacts from there).
function movement.interact(unit)
    if not unit then return false end
    local me = R.me()
    local d = nil
    if me then
        local okd, v = pcall(me.distance_to, me, unit)
        if okd and type(v) == "number" then d = v end
    end
    if d and d > NPC_REACH then
        local okp, pos = pcall(unit.get_position, unit)
        if okp and pos then
            R.npc_until, R.npc_ev_t = nil, nil
            if N.nav_to(pos, true, "npc") then
                npc_walk.until_t = R.now() + 3.0
                R.trail("move", "NPC %.1f yd away - walking within %.0f yd before interacting", d, NPC_REACH)
                return false
            end
        end
    end
    npc_walk.until_t = 0
    movement.npc_hold()
    -- 4.5.0: a game object (a Wanted Poster giving a quest) is opened with
    -- use_object - interact_with_object does not cover every object
    local okq, is_unit = pcall(unit.is_unit, unit)
    if okq and is_unit == false then
        local oku, used = pcall(function() return core.input.use_object(unit) end)
        if oku and used == true then return true end
    end
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
-- Zygor 1.7.8 INDOOR JUMP (user: "add a jump on indoor pathing when the player's
-- position stays on a waypoint for more than 3 seconds, to help with sharp
-- turns indoors"). While a MasterArthasNav walk runs indoors and the player has
-- moved less than STILL_YD for STILL_S, one jump (jump = JumpOrAscendStart, so
-- ascend_stop right after, as quest/engine does); then the window starts again.
-- Not while the walk is held on purpose: a sharp-turn pivot, a cast / loot
-- hold, casting, resting, a backpedal, standing at an NPC, or a portal step.
-- The user's rule; an exception to CLAUDE_MASTERARTHASNAV_RULES R3.1 / R6.2.
local IJ = { STILL_S = 3.0, STILL_YD = 0.5, x = nil, y = nil, since = 0, jumps = 0 }
movement.IJ = IJ
local function indoor_jump(t)
    local function reset() IJ.x = nil end
    if not N.busy() or R.turning or R.resting or R.backpedal_until or Lk.holding()
        or (R.npc_until or 0) > t or N.mode() == "portal" then return reset() end
    local me = R.me()
    if not me then return reset() end
    local okc, casting = pcall(function() return me:is_casting_spell() == true or me:is_channelling_spell() == true end)
    if okc and casting == true then return reset() end
    local oki, indoors = pcall(function() return me:is_indoors() == true end)
    if not (oki and indoors == true) then return reset() end
    local x, y = R.here()
    if not x then return reset() end
    if not IJ.x or R.dist2(IJ.x, IJ.y, x, y) > IJ.STILL_YD then
        IJ.x, IJ.y, IJ.since = x, y, t
        return
    end
    if t - IJ.since < IJ.STILL_S then return end
    pcall(function() core.input.jump() end)
    pcall(function() core.input.ascend_stop() end)
    IJ.jumps = IJ.jumps + 1
    IJ.since = t                          -- the next jump only after another STILL_S
    R.trail("move", "indoors: no movement for %.0f s on the walk - jump", IJ.STILL_S)
end

--- Once per frame (main.lua), before anything reads movement state.
function movement.pulse()
    local t = R.now()
    Lk.tick(t)
    N.pulse()
    indoor_jump(t)                -- Zygor 1.7.8
    Pv.tick(t)                 -- 3.2.0: sharp turn -> hold the walk, turn in place
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
    return N.full_state() or (N.busy() and "navigating" or "idle")     -- 4.2.0: Sentinel, through movement/nav
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
        -- 4.0.4 (R2.4): the server state, read here on the update tick
        nav = N.client() == nil and "missing" or (N.nav_ready() and "ready" or "down"),
        nav_why = N.unavailable(),                        -- 4.2.0: why Sentinel cannot navigate (GUI)
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
