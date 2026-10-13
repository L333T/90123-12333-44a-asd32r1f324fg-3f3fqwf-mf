-- ============================================================================
-- Master Farmer - Grindbot
-- movement/range.lua - facing, line of sight, arrival, fight range
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.1.0
-- ============================================================================
-- FACING: a POSITION, never the unit object (2.72.0: the movement handler
-- keeps whatever it is given across frames, and a freed mob read later is a
-- native crash). Throttled, and never while AmeisenNav is walking - it steers
-- the facing itself.
--
-- LINE OF SIGHT, no ray (2.311.0 / 2.313.0): a unit is in sight unless
--   * the game refused a cast at it with "Target not in line of sight"
--     within LOS_HOLD s (events.lua), or
--   * the navmesh says the walk to it bends round something, or it is
--     underground / unreachable (movement/sight.lua).
-- 3 yd and closer: always in sight. Cached per unit for LOS_TTL.
-- ============================================================================

local R = require("movement/core")
local N = require("movement/nav")

local Rg = {}

local FACE_GAP = 0.35
local LOS_TTL = 0.25
local LOS_HOLD = 2.5
local ARRIVE = 2.0

local last_face = 0
local los_cache = { guid = nil, t = -1, v = true }
local ev_mod, sight_mod, handler_mod = nil, nil, nil

local function handler()
    if handler_mod == nil then
        local ok, h = pcall(require, "common/utility/movement_handler")
        handler_mod = (ok and h) and h or false
    end
    return handler_mod or nil
end

--- Face `target` (a unit). Fire-and-forget; false when nothing was sent.
function Rg.face(target)
    if not R.alive(target) then return false end
    if R.resting or R.backpedal_until then return false end
    if N.busy() then return false end
    local t = R.now()
    if (t - last_face) < FACE_GAP then return false end
    last_face = t
    local ok, pos = pcall(target.get_position, target)
    if ok and pos then
        local h = handler()
        if h then pcall(h.look_at_position, h, 0.5, 0, pos) end
        pcall(core.input.look_at, pos)
        return true
    end
    return false
end

local function raw_los(player, unit, range)
    if type(range) == "number" and range <= 3 then return true end
    if sight_mod == nil then
        local ok, m = pcall(require, "movement/sight")
        sight_mod = (ok and type(m) == "table") and m or false
    end
    if sight_mod then
        local okv, v = pcall(sight_mod.verdict, player, unit)
        if okv and (v == "around" or v == "underground" or v == "unreachable") then return false end
    end
    if ev_mod == nil then
        local ok, m = pcall(require, "events")
        ev_mod = (ok and type(m) == "table" and type(m.los_failed) == "function") and m or false
    end
    if not ev_mod then return true end
    local okf, guid, at = pcall(ev_mod.los_failed)
    if not okf or guid == nil or type(at) ~= "number" then return true end
    if (R.now() - at) > LOS_HOLD then return true end
    return R.guid(unit) ~= guid
end

--- Can the player see `unit`? Cached briefly per unit.
function Rg.has_los(player, unit)
    if not player or not unit then return false end
    local g = R.guid(unit)
    local t = R.now()
    if g ~= nil and g == los_cache.guid and (t - los_cache.t) < LOS_TTL then return los_cache.v end
    local okd, range = pcall(player.distance_to, player, unit)
    local v = raw_los(player, unit, okd and range or nil)
    los_cache.guid, los_cache.t, los_cache.v = g, t, v
    return v
end

--- in_range (hitbox, the client's own test), centre distance, has_los.
function Rg.in_fight_range(player, unit, yards)
    yards = tonumber(yards) or 20
    if not player or not unit then return false, 99, false end
    local ok, range = pcall(player.distance_to, player, unit)
    if not ok or type(range) ~= "number" then return false, 99, false end
    local los = Rg.has_los(player, unit)
    local in_range
    local okr, hit = pcall(unit.is_in_range, unit, yards)
    if okr and type(hit) == "boolean" then in_range = hit else in_range = range <= yards end
    return in_range and los, range, los
end

--- Within `yards` (3D) of `dest`?
function Rg.arrived(dest, yards)
    local hx, hy, hz = R.here()
    local x, y, z = R.xyz(dest)
    if not hx or not x then return false end
    return R.dist3(hx, hy, hz, x, y, z) <= (tonumber(yards) or ARRIVE)
end

--- AmeisenNav steers round walls and objects itself; a straight line is never
--- "blocked" for the caller (path_runner skips a waypoint only on a failure).
function Rg.line_blocked() return false end

--- Target selection: false only when the navmesh says it cannot be reached.
function Rg.can_reach(_, dest)
    return N.reachable(dest) ~= false
end

return Rg
