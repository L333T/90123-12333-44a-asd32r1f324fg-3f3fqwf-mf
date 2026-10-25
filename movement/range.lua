-- ============================================================================
-- restedXP_questing
-- movement/range.lua - facing, line of sight, arrival, fight range
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.29.0
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
--
-- 4.14.0 LINE OF SIGHT BY THE GAME (improvement 12 of the API-dump review,
-- the user's OK 2026-10-24 to lift the no-game-ray rule for this): the game's
-- own answer - izi player:los_to(unit), else core.graphics.is_line_of_sight
-- (player, unit) - decides first. false = out of sight; true = in sight even
-- when the navmesh walk bends round something (a fence, a low rock: you can
-- see over it). The navmesh still rules out underground / unreachable enemies
-- and the game's "not in line of sight" refusal still applies. Each unit is
-- asked at most every GAME_TTL s, only within GAME_MAX yd; GAME_ERRORS call
-- errors switch the game check off for the session (logged) and the navmesh
-- verdict takes over again. Rg.GAME_LOS = false turns it off.
-- ============================================================================

local R = require("movement/core")
local N = require("movement/nav")

local Rg = {}

local FACE_GAP = 0.35
local LOS_TTL = 0.25
local LOS_HOLD = 2.5
local ARRIVE = 2.0

local last_face = 0
Rg.GAME_LOS = true
local GAME_TTL, GAME_MAX, GAME_ERRORS, GAME_CACHE_MAX = 0.3, 60, 3, 64
local game = { errors = 0, off = false, cache = {}, n = 0, said = false }
Rg._game = game
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
        pcall(core.input.look_at, pos)  -- audit 2026-10-17: movement_handler is not pumped here
        return true
    end
    return false
end

--- The game's line of sight from `player` to `unit`: true / false, or nil
--- (off, too far, no call, or the call failed).
local function game_los(player, unit, range)
    if not Rg.GAME_LOS or game.off then return nil end
    if type(range) ~= "number" or range > GAME_MAX then return nil end
    local g = R.guid(unit)
    local t = R.now()
    local e = g ~= nil and game.cache[g] or nil
    if e and (t - e.t) < GAME_TTL then return e.v end
    local v, failed = nil, false
    if type(player.los_to) == "function" then
        local ok, r = pcall(player.los_to, player, unit)
        if ok and type(r) == "boolean" then v = r elseif not ok then failed = true end
    end
    if v == nil then
        local gr = core and core.graphics
        if gr and type(gr.is_line_of_sight) == "function" then
            local ok, r = pcall(gr.is_line_of_sight, player, unit)
            if ok and type(r) == "boolean" then v = r failed = false elseif not ok then failed = true end
        end
    end
    if failed and v == nil then
        game.errors = game.errors + 1
        if game.errors >= GAME_ERRORS then
            game.off = true
            if not game.said then
                game.said = true
                R.log("game line-of-sight check failed " .. game.errors .. " times - navmesh line of sight only for this session")
            end
        end
        return nil
    end
    if g ~= nil and v ~= nil then
        if not game.cache[g] then
            game.n = game.n + 1
            if game.n > GAME_CACHE_MAX then game.cache, game.n = {}, 1 end
        end
        game.cache[g] = { t = t, v = v }
    end
    return v
end
Rg.game_los = game_los

local function raw_los(player, unit, range)
    if type(range) == "number" and range <= 3 then return true end
    if sight_mod == nil then
        local ok, m = pcall(require, "movement/sight")
        sight_mod = (ok and type(m) == "table") and m or false
    end
    local seen = game_los(player, unit, range)       -- 4.14.0: the game's answer first
    if seen == false then return false end
    if sight_mod then
        local okv, v = pcall(sight_mod.verdict, player, unit)
        if okv and (v == "underground" or v == "unreachable") then return false end
        if okv and v == "around" and seen ~= true then return false end
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
