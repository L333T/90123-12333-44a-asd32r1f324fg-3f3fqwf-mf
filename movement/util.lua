-- ============================================================================
-- Master Farmer - Grindbot
-- movement/util.lua - logging, position input, distance, ground and traces
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.198.0
-- ============================================================================
-- The bottom layer. Depends only on const + rt, so every other movement module
-- may require it without creating a cycle.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

local state = require("state")
local K     = require("movement/const")
local R     = require("movement/rt")

local TAG            = K.TAG
local LOG_REPEAT     = K.LOG_REPEAT
local EYE_Z          = K.EYE_Z
local TRACE_BUDGET   = K.TRACE_BUDGET
local FLAG_COLLISION = K.FLAG_COLLISION
local FLAG_LOS       = K.FLAG_LOS
local FLAG_OBSTACLE  = K.FLAG_OBSTACLE
local BODY_HALF      = K.BODY_HALF
local BODY_HALF_TIGHT = K.BODY_HALF_TIGHT
local KNEE_Z         = K.KNEE_Z
local CHEST_Z        = K.CHEST_Z

local sqrt, abs = math.sqrt, math.abs

local U = {}

-- ============================================================================
-- LOGGING
-- ============================================================================
function U.log(msg)
    core.log(TAG .. " " .. msg)
end

--- Debug line, de-duplicated per key: the same text for the same key is not
--- reprinted inside LOG_REPEAT seconds, so a per-frame call cannot spam.
function U.dlog(key, msg)
    if not R.debug_on then return end
    local t = izi.now()
    local prev = R.log_last[key]
    if prev and prev.msg == msg and (t - prev.t) < LOG_REPEAT then return end
    R.log_last[key] = { msg = msg, t = t }
    core.log(TAG .. " [move/" .. key .. "] " .. msg)
end

-- ============================================================================
-- POSITION INPUT
-- ============================================================================
--- Read x, y, z from any position-like value without allocating:
---   vec3 / { x=, y=, z= } / { map_id=, x=, y=, z= } / array { x, y, z }.
--- Returns nil when the value is not a finite 3D position.
function U.xyz(p)
    if type(p) ~= "table" then return nil end
    local x, y, z = p.x, p.y, p.z
    if type(x) ~= "number" then
        x, y, z = p[1], p[2], p[3]
    end
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end   -- NaN
    return x, y, z
end

--- Public: normalise any accepted position shape to a fresh vec3 (or nil).
function U.to_pos(p)
    local x, y, z = U.xyz(p)
    if not x then return nil end
    return vec3.new(x, y, z)
end

function U.here_xyz()
    return U.xyz(state.cached_pos)
end

function U.dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return sqrt(dx * dx + dy * dy + dz * dz)
end

function U.dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

--- True when (x, y) is too close to walk to: Sentinel densifies to 1-yard
--- points, and a dest under MIN_NAV_TRAVEL makes the character orbit it.
function U.travel_near(x, y)
    local hx, hy = U.here_xyz()
    if not hx or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    return U.dist2(hx, hy, x, y) < (K.MIN_NAV_TRAVEL or 4)
end

function U.unit_xyz(unit)
    if not unit then return nil end
    local ok, p = pcall(unit.get_position, unit)
    if not ok then return nil end
    return U.xyz(p)
end

function U.unit_valid(unit)
    if not unit then return false end
    local ok, v = pcall(unit.is_valid, unit)
    return ok and v == true
end

function U.unit_alive(unit)
    if not unit then return false end
    local ok, d = pcall(unit.is_dead_or_ghost, unit)
    if ok and d == true then return false end
    ok, d = pcall(unit.is_dead, unit)
    if ok and d == true then return false end
    return true
end

-- ============================================================================
-- GROUND / TRACE
-- ============================================================================
--- Ground height under (x, y); falls back to hint_z when the lookup fails or
--- the terrain is more than 80 yards from the hint (wrong floor).
--- Terrain height at x,y, or hint_z.
---
--- Only asked for points near the player (GROUND_Q_RANGE). The height query
--- is native terrain work, and a quest waypoint can be across the zone on a
--- tile the client has not loaded; there is nothing to gain from asking
--- there, because the leg will be re-planned with a real height long before
--- the character arrives. Grind legs are short and are unaffected.
local GROUND_Q_RANGE = 150

function U.ground_z(x, y, hint_z)
    local hx, hy = U.here_xyz()
    if not hx or U.dist2(hx, hy, x, y) > GROUND_Q_RANGE then
        return hint_z
    end
    local q = R.HEIGHT_Q
    q.x, q.y, q.z = x, y, hint_z
    local ok, hz = pcall(core.get_height_for_position, q)
    if not ok or type(hz) ~= "number" or hz ~= hz then
        ok, hz = pcall(izi.get_terrain_height, x, y)
    end
    if ok and type(hz) == "number" and hz == hz and abs(hint_z - hz) < 80 then
        return hz
    end
    return hint_z
end

--- Trace at eye height between two points. true = clear, false = hit,
--- nil = no budget left / no flag.
---
--- That polarity is trace_line's own, and it is confirmed rather than
--- assumed: the SDK's line-of-sight example reads a true return as "the enemy
--- is in line of sight". Do not invert it here. movement/probe.lua flips it
--- once, deliberately, because its callers ask the opposite question.
function U.trace(a, b, flags)
    if type(flags) ~= "number" or R.traces_used >= TRACE_BUDGET then return nil end
    R.traces_used = R.traces_used + 1
    local A, B = R.TRACE_A, R.TRACE_B
    A.x, A.y, A.z = a.x, a.y, a.z + EYE_Z
    B.x, B.y, B.z = b.x, b.y, b.z + EYE_Z
    local ok, clear = pcall(core.graphics.trace_line, A, B, flags)
    return ok and clear == true
end

-- ============================================================================
-- AVOIDANCE CORRIDOR (2.82.0)
-- ============================================================================
-- "Can the BODY walk from a to b", not "can an eye see from a to b". The old
-- test was one ray at eye height (EYE_Z) with the Collision flags, so a
-- knee-high rock, a fence or a crate was invisible to it, and a gap narrower
-- than the character read as open. The corridor is up to four
-- core.graphics.trace_line rays, cheapest-to-fail first, stopping at the
-- first hit:
--   1. chest height, centre, Collision flags (walls, trees, cliffs, terrain)
--   2. knee height, centre, objects only (rocks, fences, crates, stumps)
--   3. knee height, left shoulder, objects only
--   4. knee height, right shoulder, objects only
-- trace_line returns TRUE for a clear line (see movement/probe.lua).
-- Answers are cached for CORRIDOR_TTL on a half-yard grid, because the
-- steering search asks about the same segments many times in one tick.
local CORRIDOR_TTL = 0.3
local corridor_cache, corridor_n = {}, 0

local function ray(ax, ay, az, bx, by, bz, flags)
    if R.traces_used >= TRACE_BUDGET then return nil end
    R.traces_used = R.traces_used + 1
    local A, B = R.TRACE_A, R.TRACE_B
    A.x, A.y, A.z = ax, ay, az
    B.x, B.y, B.z = bx, by, bz
    local ok, clear = pcall(core.graphics.trace_line, A, B, flags)
    return ok and clear == true
end

local function corridor_key(a, b, tight)
    return string.format("%d|%d|%d|%d|%d|%d|%s",
        math.floor(a.x * 2), math.floor(a.y * 2), math.floor(a.z),
        math.floor(b.x * 2), math.floor(b.y * 2), math.floor(b.z), tight and "t" or "")
end

--- true = the body fits from a to b; false = blocked; nil = out of budget.
function U.corridor(a, b)
    if FLAG_COLLISION == nil then return true end
    -- TIGHT (2.85.0): R.tight_corridor narrows the shoulder rays for the
    -- steering search's last-chance pass through doorways and tunnels.
    local tight = R.tight_corridor == true
    local half = tight and BODY_HALF_TIGHT or BODY_HALF
    local key = corridor_key(a, b, tight)
    local t = izi.now()
    local e = corridor_cache[key]
    if e and (t - e.t) < CORRIDOR_TTL then return e.v end

    local v = ray(a.x, a.y, a.z + CHEST_Z, b.x, b.y, b.z + CHEST_Z, FLAG_COLLISION)
    if v == true and FLAG_OBSTACLE then
        v = ray(a.x, a.y, a.z + KNEE_Z, b.x, b.y, b.z + KNEE_Z, FLAG_OBSTACLE)
        if v == true then
            local dx, dy = b.x - a.x, b.y - a.y
            local len = sqrt(dx * dx + dy * dy)
            if len > 0.5 then
                -- left normal of the direction, scaled to half the body width
                local nx, ny = -dy / len * half, dx / len * half
                v = ray(a.x + nx, a.y + ny, a.z + KNEE_Z, b.x + nx, b.y + ny, b.z + KNEE_Z, FLAG_OBSTACLE)
                if v == true then
                    v = ray(a.x - nx, a.y - ny, a.z + KNEE_Z, b.x - nx, b.y - ny, b.z + KNEE_Z, FLAG_OBSTACLE)
                end
            end
        end
    end
    if v ~= nil then
        if corridor_n > 400 then corridor_cache, corridor_n = {}, 0 end
        if not corridor_cache[key] then corridor_n = corridor_n + 1 end
        corridor_cache[key] = { t = t, v = v }
    end
    return v
end

function U.walk_open(a, b)
    return U.corridor(a, b) == true
end

function U.los_open(a, b)
    if FLAG_LOS == nil then return true end
    return U.trace(a, b, FLAG_LOS) == true
end

return U
