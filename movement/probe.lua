-- ============================================================================
-- Master Farmer - Grindbot
-- movement/probe.lua - forward collision probing and path shaping
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.18.0
-- ============================================================================
-- The legacy obstacle code, ported onto the Sylvanas API:
--
--   _isPathBlocked  -> probe.blocked      which way is the wall
--   FixPath         -> probe.prune        drop nodes you can walk straight past
--   SmoothPath      -> probe.smooth       Chaikin corner cutting
--   FlattenPath     -> probe.settle       drop nodes onto ground or water
--   (all three)     -> probe.shape        prune, smooth, settle in order
--   _findPath       -> probe.navigate     handed to Sentinel; see below
--
-- THE TWO TRACES, AND WHICH ONE ANSWERS WHAT
--   The legacy TraceLine returns the hit point and is tested with ~= 0, so
--   for it "nonzero means blocked". Neither Sylvanas call works that way, and
--   they do not agree with each other either, so the polarity is written out
--   here once:
--
--   core.graphics.trace_line(pos1, pos2, flags) -> boolean
--     TRUE MEANS CLEAR. The SDK's own example checks line of sight with it
--     and reads a true return as "the enemy is in line of sight". So it is
--     the opposite sense from the legacy test, and probe.hits inverts it.
--     No distance argument, so there is nothing to clip.
--
--   core.graphics.native_intersect(end_pos, start_pos, distance, hit_mask)
--     -> hit, hit_pos, hit_distance
--     TRUE MEANS BLOCKED - "hit: whether an intersection occurred" - which is
--     the legacy sense. Used only where the hit POSITION is wanted, because
--     trace_line cannot give one: that is probe.hit_at, and through it the
--     water-surface probe in settle.
--
--     Two traps in it, both covered by tests. The argument order is END
--     first, then START, which is the reverse of what you would expect. And
--     `distance` defaults to 1.0, so it must be passed or a twenty yard probe
--     silently reports on its first yard.
--
--   Getting either polarity backwards inverts every decision in this file:
--   the bot walks into walls and stops in open ground. The tests assert the
--   inversion directly, so dropping it fails there rather than in game.
--
-- WHY NOT ObjectHeight FOR THE PROBE HEIGHTS
--   The porting list maps ObjectHeight("player") to client:get_player_height.
--   Those are not the same quantity. ObjectHeight is the model's height, used
--   here only to pick how far up the body to aim the probes. Sentinel's
--   get_player_height is a NAVMESH height query - the ground Z under the
--   player - and it is asynchronous. Feeding a world Z in where a body offset
--   is wanted aims every probe at the floor, or at the sky. Fixed offsets off
--   K.EYE_Z are used instead.
--
-- WHY NOT get_perp_left / get_perp_right
--   Both exist, but their convention - what the origin argument means, which
--   plane, how far - is not recorded anywhere available. A perpendicular that
--   comes out on the wrong side sends the bot into the obstacle it was trying
--   to walk around. Left and right of a facing vector in the XY plane is two
--   negations, so it is done here explicitly. Same call geometry.lua makes
--   for get_angle.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

---@type enums
local enums = require("common/enums")

local K = require("movement/const")
local U = require("movement/util")

local probe = {}

-- ============================================================================
-- COLLISION FLAG SETS
-- ============================================================================
-- The legacy hex literals and enums.collision_flags are the same numbers:
-- 0x1 DoodadCollision, 0x2 DoodadRender, 0x10 WmoCollision, 0x20 WmoRender,
-- 0x100 Terrain, 0x10000 LiquidWaterWalkable, 0x20000 LiquidAll. The values
-- below are those, used only when the enum table is not present.

-- Guarded on the TABLE, not on truthiness: a stub enums module whose
-- __index hands back a function for any key makes enums.collision_flags
-- truthy but not indexable, and indexing it throws at load time - which takes
-- the whole plugin down, not just this file.
local CF = type(enums) == "table" and enums.collision_flags or nil
if type(CF) ~= "table" then CF = {} end

local function flag(name, fallback)
    local ok, v = pcall(function() return CF[name] end)
    if ok and type(v) == "number" then return v end
    return fallback
end

-- Distinct single bits, so a sum is the same number as a bitwise or. Written
-- as a sum because bit.bor is a LuaJIT extension and the | operator is 5.3+;
-- neither is portable, and adding distinct bits needs neither.
local function combine(...)
    local fn = CF.combine
    if type(fn) == "function" then
        local ok, v = pcall(fn, ...)
        if ok and type(v) == "number" then return v end
    end
    local total = 0
    for i = 1, select("#", ...) do
        total = total + (select(i, ...) or 0)
    end
    return total
end

local DOODAD_COLLISION = flag("DoodadCollision", 0x1)
local DOODAD_RENDER    = flag("DoodadRender",    0x2)
local WMO_COLLISION    = flag("WmoCollision",    0x10)
local WMO_RENDER       = flag("WmoRender",       0x20)
local TERRAIN          = flag("Terrain",         0x100)
local ENTITY_COLLISION = flag("EntityCollision", 0x100000)
local LIQUID_WALKABLE  = flag("LiquidWaterWalkable", 0x10000)
local LIQUID_ALL       = flag("LiquidAll",       0x20000)

-- What counts as a wall in front of you. Terrain is left out while we are on
-- the navmesh: the mesh already encodes where the ground is walkable, so
-- including it makes every uphill slope read as a wall.
local F_WALL = combine(DOODAD_COLLISION, DOODAD_RENDER,
                       WMO_COLLISION, WMO_RENDER, ENTITY_COLLISION)

-- Off the mesh nothing else is describing the ground, so terrain goes back in.
local F_WALL_OFF_MESH = combine(F_WALL, TERRAIN)

-- What a path node should be dropped onto.
local F_GROUND = combine(DOODAD_COLLISION, DOODAD_RENDER,
                         WMO_COLLISION, WMO_RENDER, TERRAIN, LIQUID_WALKABLE)
local F_WATER  = combine(LIQUID_WALKABLE, LIQUID_ALL)

probe.FLAGS = {
    wall = F_WALL, wall_off_mesh = F_WALL_OFF_MESH,
    ground = F_GROUND, water = F_WATER,
}

-- ============================================================================
-- OFF-MESH STATE
-- ============================================================================
-- The legacy set notOnMesh itself, from GetActiveNodeCount() == 0. Sentinel
-- owns pathfinding now, so it is the one that knows; this is only where the
-- answer is kept so the flag set can react to it.

local off_mesh = false

function probe.set_off_mesh(v)
    off_mesh = (v == true)
end

function probe.off_mesh()
    return off_mesh
end

-- ============================================================================
-- THE TRACE
-- ============================================================================

--- True when something is between `a` and `b`, false when the line is clear,
--- nil when the trace could not be run.
---
--- NOTE THE INVERSION. trace_line answers the opposite question: it returns
--- true when the line is CLEAR. This function is named for what the callers
--- want to know - is there a wall - so the return is flipped exactly once,
--- here, and nowhere else in the file.
---
--- Arguments are the natural way round for this one: from, then to.
function probe.hits(a, b, flags)
    if type(flags) ~= "number" then
        return nil
    end
    local ax, ay, az = U.xyz(a)
    local bx, by, bz = U.xyz(b)
    if not ax or not bx then
        return nil
    end

    local from = vec3.new(ax, ay, az)
    local to   = vec3.new(bx, by, bz)
    if from:dist_to(to) <= 0 then
        return false
    end

    local ok, clear = pcall(core.graphics.trace_line, from, to, flags)
    if not ok or type(clear) ~= "boolean" then
        return nil
    end
    return clear == false
end

--- Where the line first hits, as a vec3, or nil for a clear line.
---
--- native_intersect rather than trace_line, because only it returns the hit
--- position. Its boolean is the other way round - true means it DID hit - so
--- there is no inversion here.
function probe.hit_at(a, b, flags)
    if type(flags) ~= "number" then
        return nil
    end
    local ax, ay, az = U.xyz(a)
    local bx, by, bz = U.xyz(b)
    if not ax or not bx then
        return nil
    end

    local from = vec3.new(ax, ay, az)
    local to   = vec3.new(bx, by, bz)
    local span = from:dist_to(to)
    if span <= 0 then
        return nil
    end

    local ok, hit, at = pcall(core.graphics.native_intersect, to, from, span, flags)
    if not ok or hit ~= true then
        return nil
    end
    local hx, hy, hz = U.xyz(at)
    if not hx then
        return nil
    end
    return vec3.new(hx, hy, hz)
end

-- ============================================================================
-- IS THE PATH BLOCKED
-- ============================================================================

local REACH    = 1.0      -- how far ahead to look, yards
local SHOULDER = 1.25     -- how far out the side lanes sit
local RECHECK  = 0.15     -- seconds between real probes

local last_check, last_verdict = -1, false

-- Three heights up the body: over the step, at the waist, at the head.
--
-- The legacy probed at ObjectHeight, ObjectHeight/2 and ObjectHeight - it
-- assigned the full height to two different locals and used both, so a third
-- of its nine traces repeated another third. These are three distinct
-- heights, so all nine do some work.
local HEIGHTS = { 0.25, K.EYE_Z * 0.55, K.EYE_Z }

--- The facing direction as a flat unit vector, or nil.
---
--- get_direction hands the facing back already as a vector, so the cos/sin
--- pair the legacy used to rebuild it is not needed. get_rotation is the
--- fallback for a build that does not carry get_direction.
local function facing(player)
    local ok, d = pcall(player.get_direction, player)
    if ok then
        local dx, dy = U.xyz(d)
        if dx and (dx ~= 0 or dy ~= 0) then
            local len = math.sqrt(dx * dx + dy * dy)
            return dx / len, dy / len
        end
    end
    local ok2, r = pcall(player.get_rotation, player)
    if ok2 and type(r) == "number" and r == r then
        return math.cos(r), math.sin(r)
    end
    return nil
end

--- Which way the wall is: "front", "right", "left", false for clear, or nil
--- when it could not be worked out.
---
--- Three lanes - centre, right shoulder, left shoulder - each probed at three
--- heights, and the first lane to report a hit wins, front before right
--- before left. That ordering is the legacy's and is kept: a wall dead ahead
--- should be answered by backing off, not by strafing into the corner.
function probe.blocked(reach)
    local now = izi.now()
    if now - last_check < RECHECK then
        return last_verdict
    end
    last_check = now

    local player = core.object_manager.get_local_player()
    if not player then
        last_verdict = nil
        return nil
    end

    local px, py, pz = U.unit_xyz(player)
    if not px then
        last_verdict = nil
        return nil
    end

    local fx, fy = facing(player)
    if not fx then
        last_verdict = nil
        return nil
    end

    reach = tonumber(reach) or REACH
    local flags = off_mesh and F_WALL_OFF_MESH or F_WALL

    -- Left of a heading in the XY plane is (-y, x); right is (y, -x).
    local lx, ly = -fy, fx
    local rx, ry = fy, -fx

    local function lane(sx, sy, ex, ey)
        for i = 1, #HEIGHTS do
            local h = HEIGHTS[i]
            local a = { x = sx, y = sy, z = pz + h }
            local b = { x = ex, y = ey, z = pz + h }
            if probe.hits(a, b, flags) == true then
                return true
            end
        end
        return false
    end

    local ahead_x, ahead_y = px + fx * reach, py + fy * reach

    if lane(px, py, ahead_x, ahead_y) then
        last_verdict = "front"
    elseif lane(px + rx * SHOULDER, py + ry * SHOULDER,
                ahead_x + rx * SHOULDER, ahead_y + ry * SHOULDER) then
        last_verdict = "right"
    elseif lane(px + lx * SHOULDER, py + ly * SHOULDER,
                ahead_x + lx * SHOULDER, ahead_y + ly * SHOULDER) then
        last_verdict = "left"
    else
        last_verdict = false
    end

    return last_verdict
end

--- Throw away the cached verdict, so the next blocked() really probes.
function probe.forget()
    last_check = -1
    last_verdict = false
end

-- ============================================================================
-- PATH SHAPING
-- ============================================================================

local function as_points(path)
    if type(path) ~= "table" or #path < 1 then
        return nil
    end
    local out = {}
    for i = 1, #path do
        local x, y, z = U.xyz(path[i])
        if not x then
            return nil
        end
        out[#out + 1] = vec3.new(x, y, z)
    end
    return out
end

--- Drop the nodes you can walk straight past.
---
--- Keeps the first node, then walks forward holding the last node still
--- reachable in a straight line from the anchor. The moment the line breaks,
--- that last reachable node becomes the new anchor. The end node is kept.
---
--- The legacy kept the node the line broke ON rather than the one before it,
--- which puts a waypoint on the far side of whatever blocked the trace - a
--- corner you cannot actually walk to. This keeps the last one that was still
--- clear, which is what string pulling is.
function probe.prune(path)
    local pts = as_points(path)
    if not pts or #pts < 3 then
        return path
    end

    local out = { pts[1] }
    local anchor = pts[1]
    local furthest = nil

    for i = 2, #pts - 1 do
        local blocked = probe.hits(
            { x = anchor.x, y = anchor.y, z = anchor.z + 1 },
            { x = pts[i].x, y = pts[i].y, z = pts[i].z + 1 },
            F_GROUND)
        if blocked == true then
            -- The line broke. Fall back to the last node that was clear.
            anchor = furthest or pts[i]
            out[#out + 1] = anchor
            furthest = nil
        elseif blocked == false then
            furthest = pts[i]
        else
            -- Trace unavailable: keep the node rather than silently deleting
            -- a corner that could not be checked.
            anchor = pts[i]
            out[#out + 1] = anchor
            furthest = nil
        end
    end

    out[#out + 1] = pts[#pts]
    return out
end

--- Chaikin corner cutting.
---
--- Each segment contributes the points a quarter and three quarters along it,
--- which is exactly a lerp, so the nine multiplications per segment the
--- legacy wrote out by hand become two calls.
function probe.smooth(path)
    local pts = as_points(path)
    if not pts or #pts < 2 then
        return path
    end

    local out = { pts[1]:clone() }
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        out[#out + 1] = a:lerp(b, 0.25)
        out[#out + 1] = a:lerp(b, 0.75)
    end
    out[#out + 1] = pts[#pts]:clone()
    return out
end

--- Drop each node onto the ground, or onto the water surface above it.
---
--- The legacy traced straight down and took the hit point. The ground answer
--- is already available without a trace - core.get_height_for_position, via
--- U.ground_z, which also refuses an answer from a different floor - so the
--- downward trace is gone. The upward liquid probe stays, because nothing
--- else reports where the surface is, and it is what keeps a swimming path
--- from being pushed to the riverbed.
function probe.settle(path)
    local pts = as_points(path)
    if not pts then
        return path
    end

    for i = 1, #pts do
        local p = pts[i]
        local gz = U.ground_z(p.x, p.y, p.z)
        if type(gz) == "number" then
            p.z = gz
        end

        local surface = probe.hit_at(
            { x = p.x, y = p.y, z = p.z + 1 },
            { x = p.x, y = p.y, z = p.z + 20 },
            F_WATER)
        if surface then
            p.z = surface.z
        end
    end
    return pts
end

--- prune, then smooth, then settle - the order the legacy used.
function probe.shape(path)
    return probe.settle(probe.smooth(probe.prune(path)))
end

-- ============================================================================
-- NAVIGATION
-- ============================================================================

--- Walk to a position.
---
--- _findPath is not ported line for line, because almost all of it is work
--- Sentinel already does and does better: CalculatePath and the
--- GetActiveNodeByIndex loop are client:move_to, the one second lastFind gate
--- and the ten frame `skips` counter are its request throttling, and the
--- notOnMesh fallback of walking straight at the destination is its recovery
--- state machine. Re-implementing any of it would mean two things steering at
--- once, which is the failure this project has already had once.
---
--- What is left is the call, which goes through movement/sentinel so the
--- event wiring and the client checks stay in one place. Required inside the
--- function rather than at the top so movement/sentinel stays free to require
--- this module.
function probe.navigate(dest, why)
    local ok, sn = pcall(require, "movement/sentinel")
    if not ok or type(sn) ~= "table" or type(sn.move) ~= "function" then
        return false
    end
    return sn.move(dest, why or "probe") == true
end

return probe
