-- ============================================================================
-- Master Farmer - Grindbot
-- movement/range.lua - facing, range, line of sight, reachability
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.318.0
-- ============================================================================
-- Read-only questions about the world plus the one fire-and-forget command
-- (facing). Split out from combat so navigation callers can ask "can I reach
-- this?" without pulling the combat controller in.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type movement_handler
local handler = require("common/utility/movement_handler")

local K = require("movement/const")
local R = require("movement/rt")
local U = require("movement/util")
local Z = require("movement/zones")
local S = require("movement/steer")
local O = require("movement/own")

local EYE_Z      = K.EYE_Z
local ARRIVE     = K.ARRIVE
local MIN_NAV    = K.MIN_NAV
local STEER_HOP  = K.STEER_HOP
local FACE_GAP   = K.FACE_GAP
local FACE_LOCK  = K.FACE_LOCK
local FLAG_LOS   = K.FLAG_LOS

local pt = R.pt
local xyz, here_xyz, dist2, dist3 = U.xyz, U.here_xyz, U.dist2, U.dist3
local unit_xyz, unit_valid, trace, walk_open = U.unit_xyz, U.unit_valid, U.trace, U.walk_open

local P_HERE, P_DEST = R.P_HERE, R.P_DEST

local Rg = {}

-- ============================================================================
-- FACING
-- ============================================================================
--- Command the player to face `target`. There is no facing read-back anywhere
--- in the API, so this is fire-and-forget and throttled to FACE_GAP.
function Rg.face(target)
    if not unit_valid(target) then return false end
    if not O.can_act() then return false end
    -- While the walker or Sentinel is moving the character, it steers the
    -- facing itself (the walker runs look_at every frame). A look_at lock
    -- from here on top of it was two controllers turning the character at
    -- once. Facing the target resumes the moment the character stops.
    if R.walker_moving or R.sn_active then return false end
    local t = izi.now()
    if (t - R.last_face_t) < FACE_GAP then return false end
    R.last_face_t = t
    -- A POSITION, never the unit (2.72.0). look_at_target hands the SDK's
    -- movement handler the game object, which it keeps across frames (and
    -- its on_render reads it every frame). A mob freed meanwhile - a corpse
    -- despawning, a mob leaving view - is then touched after its memory is
    -- gone, which is a native crash, not a Lua error. The crashes of
    -- 2026-09-27 all came while facing / casting at a mob. The position is
    -- re-read on every call (every FACE_GAP), so the facing still follows.
    local ok, pos = pcall(target.get_position, target)
    if ok and pos then
        pcall(handler.look_at_position, handler, FACE_LOCK, 0, pos)
        pcall(core.input.look_at, pos)
    end
    return true
end

-- ============================================================================
-- RANGE / LOS
-- ============================================================================
--- Distance + LoS to a unit, with every verified LoS path tried in turn.
--- Returns in_range, distance, has_los.
-- LINE OF SIGHT, shared (2.78.0). The rotation checked only range before a
-- cast, so it kept casting into walls ("Target not in line of sight") while
-- combat movement - which did check LoS - was still repositioning. Answers
-- are cached per unit for LOS_TTL so several spells checked in one tick cost
-- one set of native calls.
local LOS_TTL = 0.25
local los_cache = { guid = nil, t = -1, v = false }

-- 2.311.0: NO LINE-OF-SIGHT RAY. Every M2HitTest game crash of 2026-10-11
-- (ASSERT(m_data), the game's ray test against a model) came from this ray
-- test - player:los_to on the unit the bot engaged. The 2.309.0 model gate
-- was not enough for the user: line of sight is no ray at all now. A unit is
-- taken as in sight until the game itself refuses a cast at it with "Target
-- not in line of sight" (UI_ERROR_MESSAGE, events.lua); for LOS_HOLD seconds
-- after that it reads as out of sight, so combat movement repositions
-- (orbit / close in) as it did on a los_to "no". 3 yd and closer: in sight.
local LOS_HOLD = 2.5
local ev_mod = nil

local sight_mod = nil

local function raw_los(player, unit, range)
    if type(range) == "number" and range <= 3 then return true end
    -- 2.313.0: the navmesh (movement/sight.lua, AmeisenNav find_path - no
    -- game ray): a walk round a wall, an enemy under the ground or out of
    -- reach is not in sight. No answer yet: the refusal check below decides.
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
    if (izi.now() - at) > LOS_HOLD then return true end
    local okg, ug = pcall(unit.get_guid, unit)
    return not (okg and ug ~= nil and ug == guid)
end

--- Can the player see `unit`? Cached briefly per unit.
function Rg.has_los(player, unit)
    if not player or not unit then return false end
    local okg, guid = pcall(unit.get_guid, unit)
    local t = izi.now()
    if okg and guid ~= nil and guid == los_cache.guid and (t - los_cache.t) < LOS_TTL then
        return los_cache.v
    end
    local okd, range = pcall(player.distance_to, player, unit)
    local v = raw_los(player, unit, okd and range or nil)
    los_cache.guid, los_cache.t, los_cache.v = okg and guid or nil, t, v
    return v
end

function Rg.in_fight_range(player, unit, yards)
    yards = tonumber(yards) or 20
    if yards < 1 then yards = 5 end
    if not player or not unit then return false, 99, false end
    local ok, range = pcall(player.distance_to, player, unit)
    if not ok or type(range) ~= "number" then return false, 99, false end

    local has_los = raw_los(player, unit, range)
    local okg, guid = pcall(unit.get_guid, unit)
    if okg and guid ~= nil then
        los_cache.guid, los_cache.t, los_cache.v = guid, izi.now(), has_los
    end

    -- `range` is centre to centre, so comparing it straight against `yards`
    -- puts a large mob out of the fight while the player is standing in its
    -- hitbox. Ask the client, which measures to the hitbox, and keep the raw
    -- distance as the returned value because callers steer on it.
    local in_range
    local ok_r, hit = pcall(unit.is_in_range, unit, yards)
    if ok_r and type(hit) == "boolean" then
        in_range = hit
    else
        in_range = (range <= yards)
    end

    return (in_range and has_los), range, has_los
end

function Rg.arrived(dest, yards)
    local hx, hy, hz = here_xyz()
    local x, y, z = xyz(dest)
    if not hx or not x then return false end
    return dist3(hx, hy, hz, x, y, z) <= (yards or ARRIVE)
end

function Rg.line_blocked(from, dest)
    local fx, fy, fz = xyz(from)
    local tx, ty, tz = xyz(dest)
    if not fx or not tx then return false end
    return not walk_open(pt(P_HERE, fx, fy, fz), pt(P_DEST, tx, ty, tz))
end

function Rg.can_reach(from, dest)
    local fx, fy, fz = xyz(from)
    local tx, ty, tz = xyz(dest)
    if not fx or not tx then return false end
    if Z.blocked_xy(tx, ty) then return false end
    local f, d = pt(P_HERE, fx, fy, fz), pt(P_DEST, tx, ty, tz)
    if walk_open(f, d) then return true end
    local hop = dist2(fx, fy, tx, ty)
    if hop > STEER_HOP then hop = STEER_HOP end
    if hop < MIN_NAV then hop = MIN_NAV end
    if S.pick_steer(f, d, hop, false, true) then return true end
    return S.orbit_for_los(f, d, 8) ~= nil
end

return Rg
