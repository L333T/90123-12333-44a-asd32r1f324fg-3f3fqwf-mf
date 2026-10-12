-- ============================================================================
-- Master Farmer - Grindbot
-- movement/objects.lua - objects in the way of a straight move (no raycast)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.317.0
-- ============================================================================
-- The user (2.317.0): "Player should check for objects when using Movement
-- Handler API". Since 2.311.0 there is no ray, and U.walk_open - the
-- straight-line check behind the combat chase, the steering search and the
-- short direct legs - answered "open" for every line. The 20:00 daaa22 log:
-- the path approach handed a Young Thistle Boar over at 40 yd, combat
-- movement ran straight at it, "no progress toward the combat for 4s (40 yd)",
-- "still stuck - jumping", target dropped.
--
-- Same method as AmeisenNav's object cache (anav/avoid.lua), no raycast:
--   every REFRESH s, core.object_manager.get_visible_objects() -> position +
--   bounding radius of each object that blocks a walk, within SCAN yd of the
--   player and on its floor (|dz| < FLOOR_DZ):
--     * game objects (not units): crates, totems, braziers, wells, mailboxes ...
--     * units standing still that cannot be attacked (vendors, quest givers,
--       guards - the body of an NPC blocks the character)
--   never: players, dead units, moving units, attackable units (the mobs the
--   bot fights or walks past - they move, and the target is one of them).
--   Ob.blocked(a, b): the first object whose circle (radius + BODY) crosses
--   the segment a -> b, leaving out an object at either end of it (the
--   destination NPC / object itself, or one the player is already touching).
-- ============================================================================

local Ob = {}

local REFRESH  = 0.3      -- s between object scans
local SCAN     = 30.0     -- yd around the player
local FLOOR_DZ = 6.0      -- yd of height: more is another floor
local BODY     = 0.6      -- yd: the character's own half width
local END_PAD  = 1.5      -- yd: an object this close to an end of the line is that end
local R_MIN, R_MAX = 0.3, 4.0

local cache, cache_n = {}, 0
local next_refresh = -1e9

Ob.REFRESH, Ob.SCAN, Ob.BODY = REFRESH, SCAN, BODY

local function call(obj, name, ...)
    local f = obj and obj[name]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, obj, ...)
    if ok then return v end
    return nil
end

local function now()
    local ok, t = pcall(core.time)
    if ok and type(t) == "number" then return t end
    return 0
end

local function me()
    local ok, p = pcall(function() return core.object_manager.get_local_player() end)
    if ok and p and call(p, "is_valid") == true then return p end
    return nil
end

local function xyz(p)
    if p == nil then return nil end
    local ok, x, y, z = pcall(function() return p.x, p.y, p.z end)
    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
    return nil
end

--- Does `o` block the character's walk? Returns x, y, z, radius or nil.
local function entry(o, player, px, py, pz)
    if o == nil or call(o, "is_valid") == false then return nil end
    if call(o, "is_player") == true then return nil end
    if call(o, "is_unit") == true then
        if call(o, "is_dead") == true or call(o, "is_moving") == true then return nil end
        if call(player, "can_attack", o) == true then return nil end
    end
    local x, y, z = xyz(call(o, "get_position"))
    if not x then return nil end
    local dx, dy = x - px, y - py
    local d2 = dx * dx + dy * dy
    if d2 < 0.04 or d2 > SCAN * SCAN or math.abs(z - pz) > FLOOR_DZ then return nil end
    local r = tonumber(call(o, "get_bounding_radius")) or 1.0
    if r < R_MIN then r = R_MIN elseif r > R_MAX then r = R_MAX end
    return x, y, z, r
end

--- Rebuild the cache (rate-limited to REFRESH).
function Ob.refresh(force)
    local t = now()
    if not force and t < next_refresh then return end
    next_refresh = t + REFRESH
    local player = me()
    if not player then cache_n = 0 return end
    local px, py, pz = xyz(call(player, "get_position"))
    if not px then cache_n = 0 return end
    local ok, list = pcall(function() return core.object_manager.get_visible_objects() end)
    if not ok or type(list) ~= "table" then return end
    local n = 0
    for i = 1, #list do
        local x, y, z, r = entry(list[i], player, px, py, pz)
        if x then
            n = n + 1
            local e = cache[n]
            if not e then e = {} cache[n] = e end
            e.x, e.y, e.z, e.r = x, y, z, r
        end
    end
    cache_n = n
end

function Ob.count() return cache_n end

--- The first cached object whose circle (radius + BODY) crosses the segment
--- a -> b (nearest to a), or nil when the way is clear.
function Ob.blocked(a, b)
    Ob.refresh()
    if cache_n == 0 then return nil end
    local ax, ay = xyz(a)
    local bx, by = xyz(b)
    if not ax or not bx then return nil end
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.5 then return nil end
    local ux, uy = dx / len, dy / len
    local best, best_s = nil, math.huge
    for i = 1, cache_n do
        local e = cache[i]
        local ox, oy = e.x - ax, e.y - ay
        local s = ox * ux + oy * uy                    -- along the line
        local ex, ey = e.x - bx, e.y - by
        local at_start = ox * ox + oy * oy <= (e.r + END_PAD) ^ 2
        local at_end = ex * ex + ey * ey <= (e.r + END_PAD) ^ 2
        if s > 0 and s < len and not at_start and not at_end then
            local perp = math.abs(ox * uy - oy * ux)   -- off the line
            if perp < e.r + BODY and s < best_s then best, best_s = e, s end
        end
    end
    return best
end

--- Test hook: replace the cache.
function Ob._set(list)
    cache, cache_n = list or {}, list and #list or 0
    next_refresh = now() + 1e9
end

return Ob
