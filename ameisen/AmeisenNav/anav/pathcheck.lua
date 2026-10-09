-- ============================================================================
-- AmeisenNav
-- anav/pathcheck.lua - 5-yard waypoints, height and width checks ahead
-- ============================================================================
-- Version: 1.5.2
-- Author: BLIZZ
-- ============================================================================
-- Every path the client walks is first resampled so no two waypoints are more
-- than C.waypoint_spacing (5) yards apart. While walking, the next
-- C.check_ahead (3) waypoints - 15 yards - are checked ONCE each, as they come
-- into that window, and the walk is corrected before the character gets there.
--
-- HOW (server only - no new native game calls)
--   The nav server has no working height or edge query on this build: /height
--   is unsupported, /move echoes the target back unchanged, and /raycast takes
--   3.5 s and then kills AmeisenNavigationServer (2026-10-08). A SHORT /path
--   does both jobs, measured on the live server: its end point is snapped onto
--   the navmesh surface (the real ground height), and a target that is not
--   walkable ground ends short of it or needs a detour. Short paths cost about
--   0.1 ms on the server. One waypoint = ONE batched POST /paths:
--     forward   previous waypoint -> this one: ground height here, climb /
--               drop per yard, and whether the straight leg is walkable
--     sides     this waypoint -> C.side_probes (1.5, 3) yards to the left and
--               right: free when the path ends on the target with no detour
--   At most one batch in flight, at most one every C.check_gap seconds, and
--   only when an unchecked waypoint is in the window: a few requests a second
--   while running, none while standing. Never per frame.
--
-- WHAT IT CORRECTS
--   height    the waypoint takes the ground height (simple_movement and the
--             arrival test then compare against real ground)
--   steep     a climb steeper than C.max_climb yd/yd, or a drop steeper than
--             C.max_drop yd/yd or deeper than C.cliff_drop yd in one leg
--   edge      the straight leg is not walkable (ends short / detours)
--             -> that piece is re-planned UNSMOOTHED (C.splice_flags: no
--             Chaikin corner cutting, which is what cuts across edges) between
--             the waypoints before and after it, re-sampled, and spliced in;
--             at most C.max_splices per path, then it is left as it is
--   width     a side free at 1.5 yd but not the other: the waypoint moves
--             C.edge_clearance (1.5) yd toward the free side, so the character
--             keeps 1-2 yd from walls and edges. Both sides blocked at 1.5 yd:
--             a corridor under 3 yd wide - centred between the two side ends.
-- Each point is checked once; a spliced-in piece is checked like any other.
-- ============================================================================

local C = require("anav/config")
local L = require("anav/log")
local X = require("anav/context")
local Q = require("anav/query")
---@type vec3
local vec3 = require("common/geometry/vector_3")

local P = {}

local sqrt = math.sqrt

local gen = 0              -- bumped for every new path: late answers are dropped
local pts = nil            -- the walked points (vec3[], shared with the follower)
local src = nil            -- src[k] = index of the original server point k came from
local checked = nil        -- checked[k] = true once waypoint k has been checked
local stage = {}           -- stage[k] = "width" once its height is known
local busy = false
local next_check = 0
local splices = 0
P.stats = { checks = 0, lifted = 0, shifted = 0, narrow = 0, steep = 0, edge = 0, spliced = 0 }

local function now() return core.time() end

local function dist2d(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    return sqrt(dx * dx + dy * dy)
end

local function same(a, b)
    return math.abs(a.x - b.x) < 0.05 and math.abs(a.y - b.y) < 0.05 and math.abs(a.z - b.z) < 0.05
end

--- Resample `points` to at most C.waypoint_spacing between waypoints.
--- Returns vec3[] and src[] (original index each new point belongs to).
function P.densify(points, base_src)
    local out, map = {}, {}
    local spacing = math.max(1, C.waypoint_spacing or 5)
    local function add(x, y, z, s)
        local p = vec3.new(x, y, z)
        local last = out[#out]
        if last and same(last, p) then return end      -- the server repeats its last point
        out[#out + 1] = p
        map[#out] = s
    end
    for i = 1, #points do
        local b = points[i]
        local s = base_src and base_src[i] or i
        if i > 1 then
            local a = points[i - 1]
            local d = dist2d(a, b)
            local n = math.floor(d / spacing)
            if d - n * spacing < 0.5 then n = n - 1 end   -- no stub segment before b
            for k = 1, n do
                local f = (k * spacing) / d
                add(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f, s)
            end
        end
        add(b.x, b.y, b.z, s)
    end
    return out, map
end

--- A new walk: `walk_pts` are the follower's points, `walk_src` their origins.
function P.reset(walk_pts, walk_src)
    gen = gen + 1
    pts, src = walk_pts, walk_src
    if not src and pts then
        src = {}
        for k = 1, #pts do src[k] = k end
    end
    checked = {}
    stage = {}
    busy = false
    splices = 0
    if pts and pts[1] then checked[1] = true end          -- where the path starts
end

function P.clear()
    gen = gen + 1
    pts, src, checked, busy = nil, nil, nil, false
    stage = {}
end

--- Original server point index for walked index k (route bookkeeping).
function P.source_index(k)
    if not src then return k end
    return src[math.max(1, math.min(k, #src))] or k
end

-- side probe end points at `d` yards left / right of q, across the leg a -> q
local function sides(a, q, d)
    local dx, dy = q.x - a.x, q.y - a.y
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.05 then return nil end
    local nx, ny = -dy / len, dx / len                    -- left normal
    return { x = q.x + nx * d, y = q.y + ny * d, z = q.z }, { x = q.x - nx * d, y = q.y - ny * d, z = q.z }, nx, ny
end

-- free = the probe path ends on its target with no detour
local function free(r, from, to, d)
    if not r or not r.ok or not r.points or #r.points == 0 then return false end
    local e = r.points[#r.points]
    if dist2d(e, to) > 0.5 then return false end
    if Q.path_length(r.points) > d * 1.4 + 0.5 then return false end
    if math.abs(e.z - from.z) > d * 1.2 + 0.5 then return false end   -- a ledge beside the path
    return true
end

--- Replace walked points [i, j] with `piece` (already densified).
local function splice(i, j, piece, piece_src, on_change)
    local new_pts, new_src, new_chk = {}, {}, {}
    local function put(p, s, c)
        local n = #new_pts + 1
        new_pts[n], new_src[n], new_chk[n] = p, s, c
    end
    for k = 1, i - 1 do put(pts[k], src[k], checked[k]) end
    for k = 1, #piece do put(piece[k], piece_src, nil) end      -- the new piece is checked too
    for k = j + 1, #pts do put(pts[k], src[k], checked[k]) end
    pts, src, checked = new_pts, new_src, new_chk
    stage = {}
    on_change(pts, "splice")
end

--- Re-plan the leg into waypoint k unsmoothed and splice it in.
local function replan_leg(k, why, my_gen, on_change)
    if splices >= C.max_splices then
        L.debug("pathcheck: %s at waypoint %d - splice limit (%d) reached, walking it as it is", why, k, C.max_splices)
        return
    end
    splices = splices + 1
    local a = pts[k - 1]
    local j = math.min(#pts, k + 1)
    local b = pts[j]
    busy = true
    Q.find_path(a, b, { flags = C.splice_flags, no_cache = true, allow_partial = false }, function(ok, path, info)
        if gen ~= my_gen then return end
        busy = false
        if not ok or not path or #path < 2 then
            L.debug("pathcheck: re-plan of waypoint %d (%s) failed: %s", k, why, tostring(info and info.code))
            checked[k] = true
            return
        end
        local piece = P.densify(path)
        -- the piece starts at a (already walked) - drop it
        if #piece > 0 and same(piece[1], a) then table.remove(piece, 1) end
        if #piece == 0 then checked[k] = true; return end
        P.stats.spliced = P.stats.spliced + 1
        L.info("pathcheck: %s at waypoint %d - re-planned unsmoothed, %d waypoints spliced in (%d/%d)",
            why, k, #piece, splices, C.max_splices)
        splice(k, j, piece, src[j], on_change)
    end)
end

-- HEIGHT CANDIDATES (1.5.0): a straight line between two path corners does
-- not follow a hill, so the height asked for can be 7-13 yd off the ground
-- (measured on the Burning Steppes route), and the server then snaps to a
-- different spot - a false "edge". So the leg is asked at four heights in one
-- batch - the line's, the last ground height, and 6 yd above / below - and
-- the answer that lands on the waypoint gives the ground.
local Z_TRY = { 0, "a", 6, -6 }

local function ground_of(res, a, q)
    local leg = dist2d(a, q)
    for i = 1, #Z_TRY do
        local r = res[i]
        if r and r.ok and r.points and #r.points > 0 then
            local e = r.points[#r.points]
            -- 1.5.1: + 2.5 yd, not + 1.0: the probe starts where the server
            -- snaps the previous waypoint, which on a short leg is most of it
            -- (a 1.2 yd leg was rejected with its end 0.0 yd off).
            if dist2d(e, q) <= 1.0 and Q.path_length(r.points) <= leg * 1.4 + 2.5 then
                return e.z
            end
        end
    end
    return nil
end

-- width: keep C.edge_clearance from walls / edges (side probes from ground)
local function width_fix(k, a, q, res, on_change)
    local l1, r1 = sides(a, q, C.side_probes[1])
    local l2, r2 = sides(a, q, C.side_probes[2])
    if not l1 then return end
    local fl1, fr1 = free(res[1], q, l1, C.side_probes[1]), free(res[2], q, r1, C.side_probes[1])
    local fl2, fr2 = free(res[3], q, l2, C.side_probes[2]), free(res[4], q, r2, C.side_probes[2])
    if fl1 and fr1 then return end                            -- 1.5 yd free both sides
    local _, _, nx, ny = sides(a, q, 1)
    local shift = 0
    if not fl1 and not fr1 then
        -- a corridor under 3 yd: centre between the probe ends
        P.stats.narrow = P.stats.narrow + 1
        local le = res[1] and res[1].points and res[1].points[#res[1].points]
        local re = res[2] and res[2].points and res[2].points[#res[2].points]
        if le and re then
            local dl = (le.x - q.x) * nx + (le.y - q.y) * ny
            local dr = -((re.x - q.x) * nx + (re.y - q.y) * ny)
            shift = (dl - dr) / 2
            if math.abs(shift) > C.edge_clearance then shift = shift > 0 and C.edge_clearance or -C.edge_clearance end
        end
        L.debug("pathcheck: narrow passage at waypoint %d - centred %.1f yd", k, shift)
    elseif fl1 and fl2 then
        shift = C.edge_clearance                              -- wall / edge on the right
    elseif fr1 and fr2 then
        shift = -C.edge_clearance                             -- wall / edge on the left
    else
        shift = fl1 and C.edge_clearance * 0.5 or -C.edge_clearance * 0.5
    end
    if math.abs(shift) >= 0.3 and k < #pts then               -- never move the destination
        q.x, q.y = q.x + nx * shift, q.y + ny * shift
        P.stats.shifted = P.stats.shifted + 1
        on_change(pts, "shift")
    end
end

---Every update while walking. `index` is the waypoint being approached;
---`on_change(new_pts, why)` hands corrected points back to the follower.
---One request in flight, height then width per waypoint, the next waypoint
---no sooner than C.check_gap after the last one started.
function P.tick(index, on_change)
    if not C.pathcheck or not pts or busy then return end
    local t = now()
    -- the first unchecked waypoint in the window
    local k = nil
    local last = math.min(#pts, index + C.check_ahead - 1)
    for i = math.max(2, index), last do
        if not checked[i] then k = i; break end
    end
    if not k then return end
    local a, q = pts[k - 1], pts[k]
    -- 1.5.1: a leg under 2 yd (a splice joint) is not worth a request
    if dist2d(a, q) < 2.0 then checked[k] = true; return end
    local my_gen = gen
    local opts = { flags = C.splice_flags, allow_partial = true }

    if stage[k] == "width" then
        local l1, r1 = sides(a, q, C.side_probes[1])
        local l2, r2 = sides(a, q, C.side_probes[2])
        if not l1 then checked[k] = true; return end
        busy = true
        Q.find_paths({ { q, l1 }, { q, r1 }, { q, l2 }, { q, r2 } }, opts, function(ok, res)
            if gen ~= my_gen then return end
            busy = false
            checked[k] = true
            if ok and type(res) == "table" then width_fix(k, a, q, res, on_change) end
        end)
        return
    end

    if t < next_check then return end
    next_check = t + C.check_gap
    local list = {}
    for i = 1, #Z_TRY do
        local dz = Z_TRY[i]
        local z = dz == "a" and a.z or (q.z + dz)
        list[i] = { a, { x = q.x, y = q.y, z = z } }
    end
    busy = true
    P.stats.checks = P.stats.checks + 1
    Q.find_paths(list, opts, function(ok, res)
        if gen ~= my_gen then return end
        busy = false
        if not ok or type(res) ~= "table" then checked[k] = true; return end
        local leg = dist2d(a, q)
        local g = ground_of(res, a, q)
        -- edge: no height reaches the waypoint on a straight, walkable leg
        if not g then
            checked[k] = true
            local r = res[1]
            local e = r and r.ok and r.points and r.points[#r.points]
            L.debug("pathcheck: waypoint %d leg %.1f yd: no height reaches it%s", k, leg,
                e and string.format(" (line height: ends %.1f yd off, z %.1f -> %.1f)", dist2d(e, q), q.z, e.z) or "")
            P.stats.edge = P.stats.edge + 1
            return replan_leg(k, "leg leaves the walkable ground", my_gen, on_change)
        end
        if math.abs(g - q.z) > 0.3 then
            q.z = g
            P.stats.lifted = P.stats.lifted + 1
        end
        -- too steep / cliff
        local rise = q.z - a.z
        local h = math.max(leg, 0.5)
        if rise > C.max_climb * h then
            checked[k] = true
            P.stats.steep = P.stats.steep + 1
            return replan_leg(k, string.format("climb %.1f yd over %.1f yd", rise, leg), my_gen, on_change)
        end
        if -rise > C.max_drop * h or -rise > C.cliff_drop then
            checked[k] = true
            P.stats.steep = P.stats.steep + 1
            return replan_leg(k, string.format("drop %.1f yd over %.1f yd", -rise, leg), my_gen, on_change)
        end
        stage[k] = "width"                                    -- next tick: the side probes
    end)
end

return P
