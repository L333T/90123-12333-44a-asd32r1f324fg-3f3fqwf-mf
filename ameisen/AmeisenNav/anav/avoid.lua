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
-- WALLS: core.graphics.trace_line, through X.trace_clear
--   It crashed the WoW Forever client on 2026-09-28 (AmeisenNav 1.3.0). The
--   Graphics docs since say masks with bits at or above EntityRender
--   (0x200000) crashed the Classic clients; X.trace_clear refuses those and
--   only traces collision geometry (X.TRACE_OBSTACLES). Its first call runs
--   under the crash guard: if it still takes the game down, it is blocked on
--   the next load and everything below falls back to the nav server:
--     /move    slide from the player toward a point ahead along the navmesh;
--              an answer well short of that point means a wall or edge is in
--              the way, and the answer is where to aim to slide along it.
--   Corner cutting adds a ground profile (core.get_height_for_position), which
--   sees the drops and water the trace cannot. Only when the client cannot
--   tell does it ask the server:
--     /raycast is the straight line to the next-but-one waypoint walkable?
--   Server answers are used only while fresh (C.avoid_fresh seconds).
--
-- OBJECT CACHE
--   Refreshed every C.object_scan_every seconds from X.objects()
--   (get_visible_objects, or get_all_objects where that does not answer):
--   position + radius of every
--   non-player object within C.object_scan_radius. Steering reads the cache,
--   never the object manager, so the per-frame cost is a few table reads.
-- ============================================================================

local C = require("anav/config")
local L = require("anav/log")
local X = require("anav/context")
local Q = require("anav/query")
local P = require("anav/profile")

local A = {}

local sqrt = math.sqrt

-- ----------------------------------------------------------------------------
-- object cache
-- ----------------------------------------------------------------------------
local cache = {}          -- { x, y, z, r } per nearby object
local cache_n = 0
local next_refresh = 0
-- is_visible() false = removed from the world (an expired trap ...). If a
-- whole scan reads invisible, the call is not answering on this client:
-- stop asking for the session rather than drop every obstacle.
local use_visible = true
local VISIBLE_SANITY_MIN = 5

-- Units too small or too mobile to steer round: they walk off by themselves.
local okE, enums = pcall(require, "common/enums")
local CT = okE and type(enums) == "table" and enums.creature_type or {}
local IGNORED_CREATURES = {}
for name, fallback in pairs({ CRITTER = 8, NON_COMBAT_PET = 12, GAS_CLOUD = 13, WILD_PET = 14 }) do
    IGNORED_CREATURES[type(CT[name]) == "number" and CT[name] or fallback] = true
end

local function num(obj, name)
    local ok, v = X.call(obj, name)
    if ok and type(v) == "number" then return v end
    return nil
end

local function truthy(obj, name)
    local ok, v = X.call(obj, name)
    return ok and v == true
end

--- One object as a cache entry: x, y, z, radius - or nil when it is not in
--- the way. counts.seen / counts.hidden feed the is_visible sanity check.
--- (No goto: the release is encoded by a Lua 5.1 parser.)
local function scan_object(object, px, py, pz, radius2, counts)
    if object == nil then return nil end
    local okv, valid = X.call(object, "is_valid")
    if okv and valid == false then return nil end
    -- distance first: the cheapest filter, and get_all_objects (the
    -- fallback list) is mostly things far away or not in the world
    local okp, pos = X.call(object, "get_position")
    if not okp or not pos then return nil end
    local dx, dy, dz = pos.x - px, pos.y - py, pos.z - pz
    local d2 = dx * dx + dy * dy
    -- skip the player itself (distance ~0), far objects and other floors
    if d2 < 0.25 or d2 > radius2 or math.abs(dz) > 6 then return nil end
    -- bag items sit at the player's position or nowhere; never in the way
    if truthy(object, "is_item") then return nil end
    if use_visible then
        counts.seen = counts.seen + 1
        local okvis, visible = X.call(object, "is_visible")
        if okvis and visible == false then counts.hidden = counts.hidden + 1 return nil end
    end
    -- other players never block movement; units only when enabled
    if truthy(object, "is_player") then return nil end
    local is_unit = truthy(object, "is_unit")
    if is_unit and (not P.avoid_units() or truthy(object, "is_dead")) then return nil end
    if is_unit and IGNORED_CREATURES[num(object, "get_creature_type")] then return nil end
    local r = num(object, "get_bounding_radius") or 1.0
    if r < 0.3 then r = 0.3 elseif r > 4 then r = 4 end
    return pos.x, pos.y, pos.z, r
end

--- Rebuild the cache around (px, py, pz); rate-limited to C.object_scan_every.
function A.refresh(px, py, pz)
    local t = core.time()
    if t < next_refresh then return end
    next_refresh = t + C.object_scan_every
    local objects = X.objects()
    if type(objects) ~= "table" then return end

    local radius2 = C.object_scan_radius * C.object_scan_radius
    local n = 0
    local counts = { seen = 0, hidden = 0 }
    for i = 1, #objects do
        local x, y, z, r = scan_object(objects[i], px, py, pz, radius2, counts)
        if x then
            n = n + 1
            local e = cache[n]
            if not e then e = {}; cache[n] = e end
            e.x, e.y, e.z, e.r = x, y, z, r
        end
    end
    local seen, hidden = counts.seen, counts.hidden
    if use_visible and seen >= VISIBLE_SANITY_MIN and hidden == seen then
        use_visible = false
        next_refresh = 0 -- rescan next frame without the check
        L.info("avoid: is_visible() is false for all %d objects - ignoring it this session", seen)
        return
    end
    cache_n = n
end

function A.cached_count() return cache_n end

--- The cached object whose circle (radius + C.body_radius) crosses the segment
--- (px,py) -> (tx,ty) within the look-ahead, nearest first; or nil.
--- An object standing on the point steered at is the destination, not in the
--- way: walking to a mob or an NPC put that unit at the end of the corridor,
--- and the character steered round its own target.
local function blocking_object(px, py, tx, ty)
    local dx, dy = tx - px, ty - py
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.01 then return nil end
    local ux, uy = dx / len, dy / len
    local reach = math.min(len, P.get("avoid_lookahead"))
    local best, best_s = nil, math.huge
    for i = 1, cache_n do
        local e = cache[i]
        local ox, oy = e.x - px, e.y - py
        local s = ox * ux + oy * uy            -- distance along the segment
        if s > 0 and s <= reach then
            local gx, gy = e.x - tx, e.y - ty
            local at_goal = e.r + C.body_radius + 1.0
            if gx * gx + gy * gy >= at_goal * at_goal then
                local perp = math.abs(ox * uy - oy * ux) -- distance off the line
                if perp < e.r + C.body_radius and s < best_s then best, best_s = e, s end
            end
        end
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
    local reach = math.min(len, P.get("wall_probe"))
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
-- walls: client collision trace (same frame, no server round trip)
-- ----------------------------------------------------------------------------
-- Two rays toward the probe point, at knee and chest height. Blocked: fan
-- out WALL_FAN degrees either side, the side that worked last time first so
-- the character does not swap sides every check, and aim at the first clear
-- ray's end. No clear ray: no advice (the stuck ladder takes over).
-- Ray heights follow the player's model (anav/profile.lua: knee 25%,
-- chest 65% of the height).
local WALL_FAN = { 30, 60 }
local wall_side = 1
local RA, RB = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }

-- Probe log for the menu's "Show probes" (drawn by anav/tune.lua): the last
-- RAY_LOG rays and ground samples, each with the time it was made.
A.rays, A.samples = {}, {}
local RAY_LOG, SAMPLE_LOG = 24, 24
local ray_i, sample_i = 0, 0

local function log_ray(ax, ay, az, bx, by, bz, clear)
    ray_i = ray_i % RAY_LOG + 1
    local r = A.rays[ray_i] or {}
    A.rays[ray_i] = r
    r.ax, r.ay, r.az, r.bx, r.by, r.bz, r.clear, r.t = ax, ay, az, bx, by, bz, clear, core.time()
end

local function log_sample(x, y, z, ok)
    sample_i = sample_i % SAMPLE_LOG + 1
    local s = A.samples[sample_i] or {}
    A.samples[sample_i] = s
    s.x, s.y, s.z, s.ok, s.t = x, y, z, ok, core.time()
end

local HEIGHTS = { 0, 0 }

--- Both rays from the player to (ex, ey, ez) clear? true / false / nil (cannot trace).
local function ray_clear(px, py, pz, ex, ey, ez)
    HEIGHTS[1], HEIGHTS[2] = P.env.knee, P.env.chest
    for k = 1, 2 do
        local h = HEIGHTS[k]
        RA.x, RA.y, RA.z = px, py, pz + h
        RB.x, RB.y, RB.z = ex, ey, ez + h
        local clear = X.trace_clear(RA, RB)
        if clear == nil then return nil end
        if C.show_rays then log_ray(RA.x, RA.y, RA.z, RB.x, RB.y, RB.z, clear) end
        if not clear then return false end
    end
    return true
end
A.ray_clear = ray_clear

--- Aim point around a wall ahead, false when the way is clear, nil when the
--- trace is not available (caller falls back to the server slide).
local function trace_wall(px, py, pz, tx, ty, tz, out)
    local dx, dy = tx - px, ty - py
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.5 then return false end
    local reach = math.min(len, P.get("wall_probe"))
    local ez = pz + (tz - pz) * (reach / len)
    local ux, uy = dx / len, dy / len
    local straight = ray_clear(px, py, pz, px + ux * reach, py + uy * reach, ez)
    if straight == nil then return nil end
    if straight then return false end
    for _, deg in ipairs(WALL_FAN) do
        for _, side in ipairs({ wall_side, -wall_side }) do
            local a = math.rad(deg * side)
            local ca, sa = math.cos(a), math.sin(a)
            local rx, ry = ux * ca - uy * sa, ux * sa + uy * ca
            local ex, ey = px + rx * reach, py + ry * reach
            local clear = ray_clear(px, py, pz, ex, ey, ez)
            if clear == nil then return nil end
            if clear then
                wall_side = side
                out.x, out.y, out.z = ex, ey, ez
                return out
            end
        end
    end
    return false
end

--- Which side is open for a sidestep while facing from (px, py) toward
--- (tx, ty): 1 = left, -1 = right, nil = cannot tell or both blocked.
--- Rays of `reach` yards straight out to each side, both heights; when both
--- are open, the side that cleared the last wall is preferred.
function A.open_side(px, py, pz, tx, ty, reach)
    if not C.wall_trace then return nil end
    local dx, dy = tx - px, ty - py
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.01 then return nil end
    local nx, ny = -dy / len, dx / len -- left normal
    reach = reach or 2.0
    local left = ray_clear(px, py, pz, px + nx * reach, py + ny * reach, pz)
    local right = ray_clear(px, py, pz, px - nx * reach, py - ny * reach, pz)
    if left and right then return wall_side end
    if left then return 1 end
    if right then return -1 end
    return nil
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
        local off = o.r + C.body_radius + P.get("avoid_clearance")
        local side = ((px - o.x) * nx + (py - o.y) * ny) >= 0 and 1 or -1
        AIM.x, AIM.y, AIM.z = o.x + nx * off * side, o.y + ny * off * side, pz
        return AIM, "object"
    end

    -- 2) a wall ahead: the client trace, answered this frame
    if C.wall_trace then
        local w = trace_wall(px, py, pz, tx, ty, tz, AIM)
        if w then return AIM, "wall" end
        if w == false then return nil end
        -- nil: the trace is unavailable, fall back to the server
    end

    -- 3) fallback: the navmesh slide stopped short of the probe point
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
-- Ground along a shortcut, from the client (X.ground_height): one sample
-- every GROUND_STEP yards between the ends. Ground more than ground_max_dev off
-- the straight line is a drop, a bump or deep water (the probe ignores water
-- and answers the bed). Ground that high above the line is not hit at all:
-- the ray starts 2 yd above it and answers something far below, which also
-- reads as off the line.
local GROUND_STEP = 2.0

--- true = the ground follows the line, false = it does not, nil = cannot tell.
local function ground_follows(px, py, pz, q)
    local dx, dy, dz = q.x - px, q.y - py, q.z - pz
    local n = math.ceil(sqrt(dx * dx + dy * dy) / GROUND_STEP)
    local dev = P.get("ground_max_dev")
    for i = 1, n - 1 do
        local f = i / n
        local lz = pz + dz * f
        local sx, sy = px + dx * f, py + dy * f
        local h = X.ground_height(sx, sy, lz)
        if not h then return nil end
        local ok = math.abs(h - lz) <= dev
        if C.show_rays then log_sample(sx, sy, h, ok) end
        if not ok then return false end
    end
    return true
end
A.ground_follows = ground_follows

--- Corner cutting, client first: the collision trace (nothing solid in the
--- way) and the ground profile (no drop, bump or lake). Both clear: skip,
--- no server round trip. Either says no: don't. Either cannot tell: the
--- server's mesh raycast decides, as before.
function A.can_skip_to(px, py, pz, q, key)
    local dx, dy, dz = q.x - px, q.y - py, q.z - pz
    local pull_range = P.get("string_pull_range")
    if dx * dx + dy * dy > pull_range * pull_range then return false end
    if math.abs(dz) > 2.5 then return false end
    if C.wall_trace then
        local clear = ray_clear(px, py, pz, q.x, q.y, q.z)
        if clear == false then return false end
        if clear and P.ground_check() then
            local ground = ground_follows(px, py, pz, q)
            if ground ~= nil then return ground end
        end
    end
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
