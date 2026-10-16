-- ============================================================================
-- Master Farmer - Grindbot
-- movement/guide_path.lua - 3-yard, object-checked paths for RestedXP walks
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.5.0
-- ============================================================================
-- RestedXP waypoints and movement instructions (quest/engine walk_to) are
-- walked as SPACING-yard waypoints (3.5.0), not one long MasterArthasNav
-- move_to:
--   1. MasterArthasNav plans the path (client:find_path).
--   2. resample(): the path becomes waypoints SPACING yd apart.
--   3. push(): a waypoint that comes within clearance of a nearby object
--      (its bounding radius + BODY + CLEAR) is moved straight away from it,
--      at most MAX_PUSH yd; the destination itself never moves.
--   4. A moved waypoint is kept only when the navmesh walks to it from the
--      waypoint before in about a straight line (query.find_paths, one batch);
--      otherwise it goes back (a push must never aim the player at a wall).
--   5. movement/nav walks the list with client:follow_path and, while it runs,
--      blocked() re-checks the next AHEAD waypoints every RECHECK_GAP s
--      against the objects around the player (they spawn, move, respawn):
--      one comes too close -> the path is planned again from where the player
--      stands, before the collision.
-- Server queries only - no ray casts (no core.graphics.trace_line, no /raycast).
-- Objects come from targeting.visible_objects() (the shared cache), filtered
-- like MasterArthasNav's own avoidance: no players, no bag items, no hidden
-- objects, no dead units, no critters / pets / gas clouds, nothing two floors
-- away.
-- ============================================================================

local P = {}

P.SPACING     = 3.0    -- yd between two walked waypoints
P.BODY        = 0.9    -- yd: the player's body (launcher 2.6.0 body_radius)
P.CLEAR       = 1.0    -- yd kept between the body and an object
P.MAX_PUSH    = 3.0    -- yd a waypoint may be moved aside (one waypoint spacing)
P.SCAN_RADIUS = 30     -- yd around the player
P.SCAN_GAP    = 0.5    -- s between two object scans
P.RECHECK_GAP = 0.5    -- s between two re-checks of the path ahead
P.AHEAD       = 5      -- waypoints re-checked ahead (15 yd)
P.STRAIGHT    = 1.6    -- a pushed point is walkable when the mesh path to it
                       -- is at most this times the straight line (+1 yd)

local OBJ_DZ = 6       -- yd: objects farther above / below are another floor
local MIN_R, MAX_R = 0.3, 4.0

-- Units too small or too mobile to walk round: they move off by themselves.
local okE, enums = pcall(require, "common/enums")
local CT = okE and type(enums) == "table" and enums.creature_type or {}
local IGNORED = {}
for name, fallback in pairs({ CRITTER = 8, NON_COMBAT_PET = 12, GAS_CLOUD = 13, WILD_PET = 14 }) do
    IGNORED[type(CT[name]) == "number" and CT[name] or fallback] = true
end

local sqrt, floor, max, min = math.sqrt, math.floor, math.max, math.min

local function now()
    local ok, t = pcall(core.time)
    return ok and type(t) == "number" and t or 0
end

local function call(obj, name)
    local f = obj and obj[name]
    if type(f) ~= "function" then return false, nil end
    return pcall(f, obj)
end

local function yes(obj, name)
    local ok, v = call(obj, name)
    return ok and v == true
end

-- ----------------------------------------------------------------------------
-- waypoints
-- ----------------------------------------------------------------------------
--- points -> waypoints `spacing` yd apart (first and last kept). Heights are
--- interpolated along each leg.
function P.resample(points, spacing)
    spacing = spacing or P.SPACING
    local out = {}
    if type(points) ~= "table" or #points == 0 then return out end
    local a = points[1]
    out[1] = { x = a.x, y = a.y, z = a.z }
    for i = 2, #points do
        local b = points[i]
        local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
        local len = sqrt(dx * dx + dy * dy)
        local n = floor(len / spacing)
        for k = 1, n do
            local f = (k * spacing) / len
            if f < 1 then out[#out + 1] = { x = a.x + dx * f, y = a.y + dy * f, z = a.z + dz * f } end
        end
        out[#out + 1] = { x = b.x, y = b.y, z = b.z }
        a = b
    end
    return out
end

-- ----------------------------------------------------------------------------
-- objects
-- ----------------------------------------------------------------------------
local cache = { t = -1e9, list = {}, x = 0, y = 0 }

local function object_list()
    local tg = package.loaded["targeting"]
    if type(tg) == "table" and type(tg.visible_objects) == "function" then
        local ok, list = pcall(tg.visible_objects)
        if ok and type(list) == "table" then return list end
    end
    local ok, list = pcall(function() return core.object_manager.get_visible_objects() end)
    return ok and type(list) == "table" and list or nil
end

--- Objects in the way around (px, py, pz): { {x, y, z, r}, ... }, rescanned at
--- most every SCAN_GAP s (or when the player moved SCAN_RADIUS / 2).
function P.objects(px, py, pz)
    local t = now()
    local dx, dy = px - cache.x, py - cache.y
    if t - cache.t < P.SCAN_GAP and dx * dx + dy * dy < (P.SCAN_RADIUS * 0.5) ^ 2 then return cache.list end
    cache.t, cache.x, cache.y = t, px, py
    local out = {}
    local list = object_list()
    if not list then cache.list = out return out end
    local r2 = P.SCAN_RADIUS * P.SCAN_RADIUS
    for i = 1, #list do
        local o = list[i]
        local okv, valid = call(o, "is_valid")
        if o ~= nil and not (okv and valid == false) then
            local okp, pos = call(o, "get_position")
            if okp and pos and type(pos.x) == "number" then
                local ox, oy = pos.x - px, pos.y - py
                local d2 = ox * ox + oy * oy
                if d2 >= 0.25 and d2 <= r2 and math.abs((pos.z or pz) - pz) <= OBJ_DZ
                    and not yes(o, "is_item") and not yes(o, "is_player") then
                    local okvis, vis = call(o, "is_visible")
                    local unit = yes(o, "is_unit")
                    local skip = (okvis and vis == false)
                    if unit and not skip then
                        local okc, ctype = call(o, "get_creature_type")
                        skip = yes(o, "is_dead") or (okc and IGNORED[ctype] == true)
                    end
                    if not skip then
                        local okr, r = call(o, "get_bounding_radius")
                        r = (okr and type(r) == "number") and r or 1.0
                        out[#out + 1] = { x = pos.x, y = pos.y, z = pos.z or pz, r = min(MAX_R, max(MIN_R, r)) }
                    end
                end
            end
        end
    end
    cache.list = out
    return out
end

--- Forget the scan (tests, a new map).
function P.reset() cache.t, cache.list = -1e9, {} end

local function need(o) return o.r + P.BODY + P.CLEAR end

-- ----------------------------------------------------------------------------
-- checks
-- ----------------------------------------------------------------------------
--- The first waypoint in pts[i1..i2] inside an object's clearance (with a
--- 0.25 yd margin, so a waypoint push() just placed does not count), and that
--- object; nil when the stretch is clear.
function P.blocked(pts, objs, i1, i2)
    if type(pts) ~= "table" or type(objs) ~= "table" then return nil end
    i1 = max(1, i1 or 1)
    i2 = min(#pts, i2 or #pts)
    for i = i1, i2 do
        local p = pts[i]
        for j = 1, #objs do
            local o = objs[j]
            local dx, dy = p.x - o.x, p.y - o.y
            local lim = need(o) - 0.25
            if dx * dx + dy * dy < lim * lim and math.abs((p.z or o.z) - o.z) <= OBJ_DZ then return i, o end
        end
    end
    return nil
end

--- Moves waypoints out of every object's clearance (never the last one).
--- Returns { [i] = original point } for the waypoints it moved.
function P.push(pts, objs)
    local moved = {}
    if type(pts) ~= "table" or type(objs) ~= "table" or #objs == 0 then return moved end
    for i = 1, #pts - 1 do
        local p = pts[i]
        local ox, oy = 0, 0                       -- total push of this waypoint
        for _ = 1, 3 do                           -- a few passes: objects side by side
            local any = false
            for j = 1, #objs do
                local o = objs[j]
                local dx, dy = (p.x + ox) - o.x, (p.y + oy) - o.y
                local d = sqrt(dx * dx + dy * dy)
                local lim = need(o)
                if d < lim and math.abs((p.z or o.z) - o.z) <= OBJ_DZ then
                    if d < 0.01 then                -- dead centre: push across the path
                        local q = pts[i + 1]
                        local ax, ay = q.x - p.x, q.y - p.y
                        local al = sqrt(ax * ax + ay * ay)
                        if al < 0.01 then ax, ay, al = 1, 0, 1 end
                        dx, dy, d = -ay / al, ax / al, 1
                    end
                    local k = (lim - d) / d
                    ox, oy = ox + dx * k, oy + dy * k
                    any = true
                end
            end
            if not any then break end
        end
        local pl = sqrt(ox * ox + oy * oy)
        if pl > 0.01 then
            if pl > P.MAX_PUSH then ox, oy = ox * P.MAX_PUSH / pl, oy * P.MAX_PUSH / pl end
            moved[i] = { x = p.x, y = p.y, z = p.z }
            p.x, p.y = p.x + ox, p.y + oy
        end
    end
    return moved
end

--- Step 4: each moved waypoint must be reachable from the one before in about
--- a straight line, or it goes back to where it was. done(pts) once (at once
--- when nothing moved or the batch query is missing - pushes then stay, they
--- are at most MAX_PUSH yd).
function P.validate(nav_table, pts, moved, done)
    local pairs_, idx = {}, {}
    for i in pairs(moved) do
        if i > 1 then
            pairs_[#pairs_ + 1] = { pts[i - 1], pts[i] }
            idx[#idx + 1] = i
        end
    end
    local q = type(nav_table) == "table" and nav_table.query or nil
    if #pairs_ == 0 or type(q) ~= "table" or type(q.find_paths) ~= "function" then return done(pts) end
    local answered = false
    local ok = pcall(q.find_paths, pairs_, nil, function(okb, results)
        if answered then return end
        answered = true
        for n, i in ipairs(idx) do
            local r = okb and type(results) == "table" and results[n] or nil
            local good = false
            if type(r) == "table" and r.ok and type(r.points) == "table" and #r.points >= 2 then
                local len, a = 0, r.points[1]
                for k = 2, #r.points do
                    local b = r.points[k]
                    len = len + sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
                    a = b
                end
                local s = pts[i - 1]
                local straight = sqrt((pts[i].x - s.x) ^ 2 + (pts[i].y - s.y) ^ 2)
                good = len <= straight * P.STRAIGHT + 1.0
            end
            if not good then
                local o = moved[i]
                pts[i].x, pts[i].y, pts[i].z = o.x, o.y, o.z
            end
        end
        done(pts)
    end)
    if not ok and not answered then
        answered = true
        done(pts)
    end
end

return P
