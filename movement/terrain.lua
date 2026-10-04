-- ============================================================================
-- Master Farmer - Grindbot
-- movement/terrain.lua - terrain-aware Sentinel pathing (coords_helper)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.233.0
-- ============================================================================
-- Sentinel plans on its navmesh and knows nothing about the ground the client
-- has loaded. Three things here read that ground through
-- common/utility/coords_helper and help Sentinel with it:
--
-- 1. WAYPOINT HEIGHT RETRY
--    A destination Sentinel answers "unreachable" for is usually the right
--    x, y at the wrong z (a far waypoint given the player's height, a quest
--    giver on a ledge). It used to be marked failed, and "unreachable" is an
--    off-mesh word, so the area around the destination was blacklisted.
--    Now, when the destination is within Q_RANGE (terrain loaded), the floor
--    heights at its x, y are read - coords:get_terrain_height, then
--    coords:map_to_world with several extra_height offsets for upper and lower
--    floors - and the move is asked again at an untried height. Only after
--    every candidate has failed does the old failure handling run.
--
-- 2. TERRAIN WALLS (mountains, cliffs)
--    The stuck watch (movement/repath.lua) blacklists a fixed 6-yard area
--    after 20 s caught in one spot. Against a mountainside that is slow, and
--    6 yards is too small: the next path hits the same slope a few yards
--    along. Here, after WALL_STALL s of a Sentinel leg that has not moved the
--    character, the terrain ahead is sampled. A rise or drop steeper than
--    STEEP per yard is a wall: its width is measured to each side, an area
--    sized to it is blacklisted (Sentinel's obstacle list + find_path_avoid)
--    and the destination is re-pathed around it. WALL_MAX per destination;
--    after that the repath ladder gives up as before.
--
-- 3. DIRECT LEGS
--    N.move sends a clear line under 30 yards as move_direct, which walks
--    straight. A clear eye-height ray does not mean walkable ground: a slope
--    too steep to climb lets the ray through. Such a line is now sent to the
--    planner (move_to) instead.
--
-- THE RAYCAST WINDOW
--   coords_helper heights come from a terrain raycast started near the
--   player's height (its extra_height note: start = player z + offset,
--   default +4). Ground well above the player is therefore not readable -
--   the ray starts inside it. Sampling stops once the ground has risen
--   WINDOW yards above the character ("high": cannot vouch for it), so an
--   ordinary uphill is never read as a cliff. A wall is the jump between
--   two neighbouring samples, or two samples in a row with no answer.
--
-- Every native call is pcall-guarded, switched off after ERR_MAX errors, and
-- logs its first result shape (`terrain: ... first result`).
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

local K = require("movement/const")
local R = require("movement/rt")
local U = require("movement/util")
local Z = require("movement/zones")
local N = require("movement/sentinel")

local OWNER = K.OWNER
local pt = R.pt
local here_xyz, dist2, dlog = U.here_xyz, U.dist2, U.dlog
local abs, floor, min, max = math.abs, math.floor, math.min, math.max

local T = {}

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "terrain", fmt, ...)
    end
end

-- ============================================================================
-- COORDS HELPER
-- ============================================================================
local helper, helper_tried = nil, false

---@return coords_helper|nil
local function coords()
    if not helper_tried then
        helper_tried = true
        local ok, m = pcall(require, "common/utility/coords_helper")
        if ok and type(m) == "table" then helper = m end
    end
    return helper
end

local WORLD_LIMIT = 20000
local ERR_MAX = 5

local function finite(n)
    return type(n) == "number" and n == n and n > -WORLD_LIMIT and n < WORLD_LIMIT
end

--- Field of a vec2 / vec3 result, which may be userdata.
local function fld(v, k)
    local ok, r = pcall(function() return v[k] end)
    if ok then return tonumber(r) end
    return nil
end

local errors = { height = 0, floors = 0 }
local first = { height = false, floors = false }

local function api_error(name)
    errors[name] = errors[name] + 1
    if errors[name] == ERR_MAX then
        trail("coords_helper %s errored %d times - off for this session", name, ERR_MAX)
    end
end

-- ----------------------------------------------------------------------------
-- HEIGHT  (coords:get_terrain_height, cached on a 1-yard grid)
-- ----------------------------------------------------------------------------
local H_TTL, H_MAX = 2.0, 600
local hc, hc_n = {}, 0

local function hkey(x, y)
    return (floor(x) + WORLD_LIMIT) * 40001 + (floor(y) + WORLD_LIMIT)
end

--- Terrain height at (x, y), or nil. Only near the player: the raycast reads
--- terrain the client has loaded.
function T.height(x, y)
    if not finite(x) or not finite(y) then return nil end
    local c = coords()
    if not c or type(c.get_terrain_height) ~= "function" or errors.height >= ERR_MAX then
        return nil
    end
    local key = hkey(x, y)
    local now = izi.now()
    local e = hc[key]
    if e and (now - e.t) < H_TTL then return e.h or nil end
    local ok, h = pcall(c.get_terrain_height, c, x, y)
    if not ok then
        api_error("height")
        return nil
    end
    if not first.height then
        first.height = true
        trail("coords_helper get_terrain_height first result: %s %s", type(h), tostring(h))
    end
    -- 0 is what the call answers with nothing under the point.
    if not finite(h) or h == 0 then h = false end
    if not e then
        if hc_n >= H_MAX then hc, hc_n = {}, 0 end
        e = {}
        hc[key] = e
        hc_n = hc_n + 1
    end
    e.h, e.t = h, now
    return h or nil
end

-- ----------------------------------------------------------------------------
-- FLOORS  (several heights at one x, y: ground, upper floors, lower floors)
-- ----------------------------------------------------------------------------
-- map_to_world raycasts from player z + extra_height, so a few offsets find
-- the floors above and below the player. It needs map coordinates: the point
-- is converted with world_pos_to_map_pos_normalized on the current map, and
-- an answer more than FLOOR_XY yards from the asked x, y is thrown away (a
-- different map, or a bad conversion). Called only after a failure, for a
-- point within Q_RANGE - never per frame, never for unloaded terrain (see
-- quest/guide.lua "WHY NOT coords_helper:map_to_world EVERY FRAME").
local FLOOR_EXTRA = { 4, 20, 50, -15 }
local FLOOR_XY = 3.0
local FLOOR_SAME = 1.5

local vec2_mod = nil

local function vec2_new(x, y)
    if vec2_mod == nil then
        local ok, m = pcall(require, "common/geometry/vector_2")
        vec2_mod = (ok and type(m) == "table") and m or false
    end
    if vec2_mod and type(vec2_mod.new) == "function" then
        local ok, v = pcall(vec2_mod.new, x, y)
        if ok and v ~= nil then return v end
    end
    return nil
end

local function add_floor(out, z)
    if not finite(z) or z == 0 then return end
    for i = 1, #out do
        if abs(out[i] - z) < FLOOR_SAME then return end
    end
    out[#out + 1] = z
end

local function map_floors(out, x, y, z)
    local c = coords()
    if not c or errors.floors >= ERR_MAX then return end
    if type(c.map_to_world) ~= "function" or type(c.get_current_map_id) ~= "function" then return end
    local gui = nil
    pcall(function() gui = core.game_ui end)
    if type(gui) ~= "table" or type(gui.world_pos_to_map_pos_normalized) ~= "function" then return end
    local okm, map_id = pcall(c.get_current_map_id, c)
    if not okm then api_error("floors") return end
    if type(map_id) ~= "number" or map_id == 0 then return end
    local okp, mp = pcall(gui.world_pos_to_map_pos_normalized, vec3.new(x, y, z))
    if not okp or mp == nil then return end
    local mx, my = fld(mp, "x"), fld(mp, "y")
    if not mx or not my or mx <= 0 or my <= 0 or mx >= 0.99 or my >= 0.99 then return end
    local v2 = vec2_new(mx, my)
    if not v2 then return end
    for i = 1, #FLOOR_EXTRA do
        local ok, w = pcall(c.map_to_world, c, map_id, v2, FLOOR_EXTRA[i])
        if not ok then
            api_error("floors")
            return
        end
        if not first.floors then
            first.floors = true
            trail("coords_helper map_to_world first result: %s (map %s, extra %s)",
                type(w), tostring(map_id), tostring(FLOOR_EXTRA[i]))
        end
        if w ~= nil then
            local wx, wy, wz = fld(w, "x"), fld(w, "y"), fld(w, "z")
            if finite(wx) and finite(wy) and dist2(wx, wy, x, y) <= FLOOR_XY then
                add_floor(out, wz)
            end
        end
    end
end

--- Candidate ground heights at (x, y): terrain first, then map floors.
function T.floors(x, y, z)
    local out = {}
    local h = T.height(x, y)
    if h then out[1] = h end
    map_floors(out, x, y, z)
    return out
end

-- ============================================================================
-- 1. WAYPOINT HEIGHT RETRY
-- ============================================================================
local Q_RANGE = 150          -- yards: as U.ground_z, terrain this close is loaded
local FIX_TTL = 300
local FIX_MAX = 64
local FIX_TRIES = 4          -- heights tried per destination, the original included
local TRIED_SAME = 2.0
local fix, fix_n = {}, 0     -- 4-yard key -> { z = height to ask, t, tried = { z, ... } }

local function gkey(x, y)
    return (floor(x / 4) + 5000) * 10001 + (floor(y / 4) + 5000)
end

--- Sentinel answered "unreachable" for (x, y, z). True when another height
--- is worth asking for: T.goal_z now returns it, and the caller should drop
--- the leg without the failure handling (no blacklist, no hold).
function T.on_unreachable(x, y, z)
    if not finite(x) or not finite(y) or not finite(z) then return false end
    local hx, hy = here_xyz()
    if not hx or dist2(hx, hy, x, y) > Q_RANGE then return false end
    local now = izi.now()
    local k = gkey(x, y)
    local e = fix[k]
    if e and (now - e.t) >= FIX_TTL then e = nil end
    if not e then
        if fix_n >= FIX_MAX then fix, fix_n = {}, 0 end
        e = { z = nil, t = now, tried = {} }
        fix[k] = e
        fix_n = fix_n + 1
    end
    local tried = e.tried
    tried[#tried + 1] = z
    if #tried >= FIX_TRIES then
        e.z = nil
        return false
    end
    -- In T.floors order: the terrain ground first (the usual truth outdoors),
    -- then the map floors - same floor as the player, upper, lower.
    local best = nil
    local cands = T.floors(x, y, z)
    for i = 1, #cands do
        local c = cands[i]
        local fresh = true
        for j = 1, #tried do
            if abs(c - tried[j]) < TRIED_SAME then fresh = false end
        end
        if fresh and not best then best = c end
    end
    if not best then
        e.z = nil
        trail("(%.0f, %.0f) unreachable at z %.1f - no other floor height there", x, y, z)
        return false
    end
    e.z, e.t = best, now
    trail("(%.0f, %.0f) unreachable at z %.1f - asking Sentinel again at ground height %.1f",
        x, y, z, best)
    return true
end

--- The height to ask Sentinel for at (x, y): a floor found after an
--- "unreachable" answer there, else z unchanged.
function T.goal_z(x, y, z)
    if fix_n == 0 or not finite(x) or not finite(y) then return z end
    local e = fix[gkey(x, y)]
    if e and e.z and (izi.now() - e.t) < FIX_TTL then return e.z end
    return z
end

-- ============================================================================
-- TERRAIN MARCH
-- ============================================================================
local STEP      = 1.0    -- yards between samples
local STEEP     = 1.4    -- rise per yard: ~54 degrees, past WoW's walkable slope
local STEEP_PAD = 0.25   -- sample noise allowed on top of STEEP
local WINDOW    = 2.5    -- stop once the ground is this far above the reference
local FLOOR_TOL = 3.0    -- terrain under the character must be this close to its z

--- Walk the terrain from (x, y) along the unit vector (ux, uy) for `len`.
--- `zref` is the character's height (the raycast window), `tol` how far the
--- terrain under the start may be from it. Returns a verdict and a distance:
---   "ok",    len  every step walkable
---   "steep", s    the ground jumps more than STEEP per yard at s
---   "blind", s    two samples in a row with no answer, ending at s
---   "high",  s    the ground has risen out of the readable window at s
---   nil           no terrain under the start (bridge, building, cave)
local function march(x, y, zref, tol, ux, uy, len)
    local h0 = T.height(x, y)
    if not h0 or abs(h0 - zref) > tol then return nil end
    local prev, prev_s, s, misses = h0, 0, 0, 0
    while s < len do
        if prev > zref + WINDOW then return "high", s end
        s = min(len, s + STEP)
        local h = T.height(x + ux * s, y + uy * s)
        if h then
            if abs(h - prev) > STEEP * (s - prev_s) + STEEP_PAD then return "steep", s end
            prev, prev_s, misses = h, s, 0
        else
            misses = misses + 1
            if misses >= 2 then return "blind", s end
        end
    end
    return "ok", len
end

-- ============================================================================
-- 3. DIRECT LEGS
-- ============================================================================
--- May a straight move_direct walk from (hx, hy, hz) to (x, y)? False when the
--- terrain on the line is too steep, or rises beyond what can be read; true
--- when it is walkable or the terrain says nothing (no terrain under the
--- character: the caller's ray test stands alone, as before).
function T.line_ok(hx, hy, hz, x, y)
    if not finite(hx) or not finite(x) then return true end
    local d = dist2(hx, hy, x, y)
    if d < 1 then return true end
    local verdict = march(hx, hy, hz, FLOOR_TOL, (x - hx) / d, (y - hy) / d, d)
    if verdict == nil or verdict == "ok" then return true end
    dlog("terrain", "direct line refused: " .. verdict)
    return false
end

-- ============================================================================
-- 2. TERRAIN WALLS
-- ============================================================================
local WALL_STALL = 4.0    -- s a Sentinel leg has not moved the character WALL_MOVE yd
local WALL_MOVE  = 1.5
local WALL_LOOK  = 8.0    -- yards of ground read ahead
local WALL_GAP   = 6.0    -- s between two terrain blacklists
local WALL_MAX   = 3      -- terrain blacklists per destination
local SIDE_STEP  = 4.0    -- wall width sampling to each side
local SIDE_MAX   = 16.0
local SIDE_TOL   = 6.0    -- terrain beside the character may sit on a slope
local ZONE_MIN, ZONE_MAX = 6.0, 18.0
local GOAL_KEEP  = 2.0    -- the destination stays this far outside the zone

local w = { x = nil, y = nil, t = 0, last = -1e9, key = nil, n = 0, next = 0 }

local function is_wall(verdict)
    return verdict == "steep" or verdict == "blind"
end

--- How far the wall runs to either side of the heading: the widest offset at
--- which the ground the same distance ahead is still a wall.
local function wall_width(hx, hy, hz, ux, uy, s)
    local nx, ny = -uy, ux
    local widest = 0
    for side = -1, 1, 2 do
        local o = SIDE_STEP
        while o <= SIDE_MAX do
            local bx, by = hx + nx * o * side, hy + ny * o * side
            if not is_wall(march(bx, by, hz, SIDE_TOL, ux, uy, s + 2)) then break end
            if o > widest then widest = o end
            o = o + SIDE_STEP
        end
    end
    return widest
end

local function stalled_reason()
    if R.rest_lock then return true end
    local pr = R.pause_reason
    if type(pr) == "table" and (pr.cast or pr.restrict or pr.rest or pr.loot) then return true end
    if N.planning() or N.recovering() then return true end
    return false
end

--- Per movement pulse.
function T.tick(t)
    if t < w.next then return end
    w.next = t + 0.5
    if R.cur_owner == OWNER.COMBAT or not R.sn_active or not R.has_dest then
        w.x = nil
        return
    end
    local hx, hy, hz = here_xyz()
    if not hx then return end
    if not w.x or dist2(w.x, w.y, hx, hy) > WALL_MOVE then
        w.x, w.y, w.t = hx, hy, t
        return
    end
    if stalled_reason() then
        w.t = t                       -- held, not stuck
        return
    end
    if (t - w.t) < WALL_STALL or (t - w.last) < WALL_GAP then return end
    w.t = t                           -- one look per stall window, whatever it finds
    local indoors = false
    pcall(function() indoors = izi.me():is_indoors() == true end)
    if indoors then return end

    local gx, gy, gz = R.dest_x, R.dest_y, R.dest_z
    if not finite(gx) or not finite(gy) then return end
    local gd = dist2(hx, hy, gx, gy)
    if gd <= 5 then return end
    local key = gkey(gx, gy)
    if key ~= w.key then w.key, w.n = key, 0 end
    if w.n >= WALL_MAX then return end

    -- Heading: the running path's next point, else straight at the goal.
    local ax, ay = N.ahead_point(2.0)
    if not ax then ax, ay = gx, gy end
    local da = dist2(hx, hy, ax, ay)
    if da < 0.5 then return end
    local ux, uy = (ax - hx) / da, (ay - hy) / da
    local verdict, s = march(hx, hy, hz, FLOOR_TOL, ux, uy, WALL_LOOK)
    if not is_wall(verdict) then
        dlog("terrain", "stalled, ground ahead " .. tostring(verdict))
        return
    end

    local width = wall_width(hx, hy, hz, ux, uy, s)
    local radius = max(ZONE_MIN, min(ZONE_MAX, width + 4))
    -- The zone's near edge 1.5 yards ahead: the character stays outside it.
    local cx, cy = hx + ux * (radius + 1.5), hy + uy * (radius + 1.5)
    local room = dist2(cx, cy, gx, gy) - GOAL_KEEP
    if room < radius then
        -- The destination is up there too: shrink the zone toward the wall.
        radius = room
        if radius < ZONE_MIN then
            trail("%s ground %.0f yd ahead, but the destination (%.0f yd) is on it - not blacklisting",
                verdict, s, gd)
            return
        end
        cx, cy = hx + ux * (radius + 1.5), hy + uy * (radius + 1.5)
    end
    w.last, w.n = t, w.n + 1
    Z.blacklist_area(pt(R.P_TMP, cx, cy, hz), radius, "terrain")
    trail("%s ground %.0f yd ahead at (%.0f, %.0f), %.0f yd wide - area (%.0f, %.0f) r%.0f blacklisted, re-pathing around it (%d/%d)",
        verdict, s, hx, hy, width * 2, cx, cy, radius, w.n, WALL_MAX)
    local ok_rp, RP = pcall(require, "movement/repath")
    if ok_rp and type(RP) == "table" and type(RP.reset) == "function" then RP.reset() end
    N.end_recovery()
    N.repath_around(pt(R.P_DEST, gx, gy, gz), "terrain_avoid")
end

-- ============================================================================
-- RESET  (continent change - every key here is x / y only)
-- ============================================================================
function T.reset()
    hc, hc_n = {}, 0
    fix, fix_n = {}, 0
    w.x, w.key, w.n, w.last = nil, nil, 0, -1e9
end

return T
