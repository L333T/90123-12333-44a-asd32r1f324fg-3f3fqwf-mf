-- ============================================================================
-- AmeisenNav
-- anav/avoid.lua - walls (navmesh, via the server) and nearby objects
-- ============================================================================
-- Version: 1.1.0
-- Author: BLIZZ
-- ============================================================================
-- The navmesh already routes around buildings and terrain. What it cannot
-- know about: corners the character clips while steering an arc, and objects
-- standing in the way. This module answers one question for the steering code:
-- "is the way ahead clear, and if not, where should I aim instead?"
--
-- NO core.graphics.trace_line
--   It crashes the WoW Forever client outright (2026-09-28, AmeisenNav 1.3.0:
--   the last breadcrumb before the crash was its first call). Walls are asked
--   of the nav server instead, asynchronously:
--     /move    slide from the player toward a point ahead along the navmesh;
--              an answer well short of that point means a wall or edge is in
--              the way, and the answer is where to aim to slide along it.
--     /raycast is the straight line to the next-but-one waypoint walkable?
--              (corner cutting)
--   Answers are used only while fresh (C.avoid_fresh seconds).
--
-- OBJECT CACHE
--   Refreshed every C.object_scan_every seconds from
--   core.object_manager.get_visible_objects(): position + radius of every
--   non-player object within C.object_scan_radius. Steering reads the cache,
--   never the object manager, so the per-frame cost is a few table reads.
-- ============================================================================

local C = require("anav/config")
local L = require("anav/log")
local X = require("anav/context")
local Q = require("anav/query")

local A = {}

local sqrt = math.sqrt

-- ----------------------------------------------------------------------------
-- object cache
-- ----------------------------------------------------------------------------
local cache = {}          -- { x, y, z, r } per nearby object
local cache_n = 0
local next_refresh = 0
local list_fn = core.object_manager and core.object_manager.get_visible_objects

local function num(obj, name)
    local ok, v = X.call(obj, name)
    if ok and type(v) == "number" then return v end
    return nil
end

local function truthy(obj, name)
    local ok, v = X.call(obj, name)
    return ok and v == true
end

--- Rebuild the cache around (px, py, pz); rate-limited to C.object_scan_every.
function A.refresh(px, py, pz)
    local t = core.time()
    if t < next_refresh then return end
    next_refresh = t + C.object_scan_every
    if type(list_fn) ~= "function" then return end
    local ok, objects = X.call_fn("get_visible_objects", list_fn)
    if not ok or type(objects) ~= "table" then return end

    local radius2 = C.object_scan_radius * C.object_scan_radius
    local n = 0
    for i = 1, #objects do
        local object = objects[i]
        if object == nil then goto continue end
        local okv, valid = X.call(object, "is_valid")
        if okv and valid == false then goto continue end
        -- other players never block movement; units only when enabled
        if truthy(object, "is_player") then goto continue end
        local is_unit = truthy(object, "is_unit")
        if is_unit and (not C.avoid_units or truthy(object, "is_dead")) then goto continue end

        do
            local okp, pos = X.call(object, "get_position")
            if not okp or not pos then goto continue end
            local dx, dy, dz = pos.x - px, pos.y - py, pos.z - pz
            local d2 = dx * dx + dy * dy
            -- skip the player itself (distance ~0), far objects and other floors
            if d2 < 0.25 or d2 > radius2 or math.abs(dz) > 6 then goto continue end
            local r = num(object, "get_bounding_radius") or 1.0
            if r < 0.3 then r = 0.3 elseif r > 4 then r = 4 end
            n = n + 1
            local e = cache[n]
            if not e then e = {}; cache[n] = e end
            e.x, e.y, e.z, e.r = pos.x, pos.y, pos.z, r
        end

        ::continue::
    end
    cache_n = n
end

function A.cached_count() return cache_n end

--- 1.6.0 (anav/horizon): the cached objects { x, y, z, r }[] and their count.
function A.objects() return cache, cache_n end

--- The cached object whose circle (radius + C.body_radius) crosses the segment
--- (px,py) -> (tx,ty) within C.avoid_lookahead yards, nearest first; or nil.
local function blocking_object(px, py, tx, ty)
    local dx, dy = tx - px, ty - py
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.01 then return nil end
    local ux, uy = dx / len, dy / len
    local reach = math.min(len, C.avoid_lookahead)
    local best, best_s = nil, math.huge
    for i = 1, cache_n do
        local e = cache[i]
        local ox, oy = e.x - px, e.y - py
        local s = ox * ux + oy * uy            -- distance along the segment
        if s <= 0 or s > reach then goto continue end
        do
            local perp = math.abs(ox * uy - oy * ux) -- distance off the line
            if perp < e.r + C.body_radius and s < best_s then best, best_s = e, s end
        end
        ::continue::
    end
    return best
end

-- ----------------------------------------------------------------------------
-- walls: server /move (slide along the navmesh)
-- ----------------------------------------------------------------------------
local slide = { pending = false, t = -1e9, ok = false, x = 0, y = 0, z = 0, rx = 0, ry = 0 }
local next_slide = 0

local function ask_slide(t, px, py, pz, tx, ty, tz)
    if slide.pending or t < next_slide then return end
    next_slide = t + C.avoid_ask_every
    local dx, dy = tx - px, ty - py
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.5 then return end
    local reach = math.min(len, C.wall_probe)
    local rx, ry = px + dx / len * reach, py + dy / len * reach
    local rz = pz + (tz - pz) * (reach / len)
    slide.pending = true
    Q.move_along_surface({ x = px, y = py, z = pz }, { x = rx, y = ry, z = rz }, function(ok, p)
        slide.pending = false
        slide.t = core.time()
        slide.ok = ok and p ~= nil
        if slide.ok then
            slide.x, slide.y, slide.z = p.x, p.y, p.z
            slide.rx, slide.ry = rx, ry
        end
    end)
end

-- ----------------------------------------------------------------------------
-- steering advice
-- ----------------------------------------------------------------------------
local AIM = { x = 0, y = 0, z = 0 }

--- Where to aim instead of (tx,ty,tz), or nil when the way is clear.
--- Returns aim_point, reason ("object" | "wall").
function A.advise(px, py, pz, tx, ty, tz)
    local t = core.time()

    -- 1) an object in the corridor: aim beside it, on the side nearer our line
    local o = blocking_object(px, py, tx, ty)
    if o then
        local dx, dy = tx - px, ty - py
        local len = sqrt(dx * dx + dy * dy)
        local nx, ny = -dy / len, dx / len -- left normal
        local off = o.r + C.body_radius + C.avoid_clearance
        local side = ((px - o.x) * nx + (py - o.y) * ny) >= 0 and 1 or -1
        AIM.x, AIM.y, AIM.z = o.x + nx * off * side, o.y + ny * off * side, pz
        return AIM, "object"
    end

    -- 2) a wall or edge ahead: the navmesh slide stopped short of the probe point
    ask_slide(t, px, py, pz, tx, ty, tz)
    if slide.ok and (t - slide.t) <= C.avoid_fresh then
        local sx, sy = slide.x - px, slide.y - py
        local short_x, short_y = slide.rx - slide.x, slide.ry - slide.y
        local short = sqrt(short_x * short_x + short_y * short_y)
        local got = sqrt(sx * sx + sy * sy)
        if short > C.wall_short and got > 0.7 then
            AIM.x, AIM.y, AIM.z = slide.x, slide.y, slide.z
            return AIM, "wall"
        end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- corner cutting: server /raycast to the waypoint after the current one
-- ----------------------------------------------------------------------------
local pull = { pending = false, key = nil, t = -1e9, clear = false }

--- True when a fresh server answer says the straight line from the player to
--- `q` is walkable (and q is close and level enough). Asks when needed.
function A.can_skip_to(px, py, pz, q, key)
    local dx, dy, dz = q.x - px, q.y - py, q.z - pz
    if dx * dx + dy * dy > C.string_pull_range * C.string_pull_range then return false end
    if math.abs(dz) > 2.5 then return false end
    local t = core.time()
    if pull.key == key and (t - pull.t) <= C.avoid_fresh then return pull.clear end
    if not pull.pending then
        pull.pending = true
        Q.raycast({ x = px, y = py, z = pz }, q, function(ok, clear)
            pull.pending = false
            pull.key, pull.t, pull.clear = key, core.time(), ok and clear == true
        end)
    end
    return false
end

return A
