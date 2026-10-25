-- ============================================================================
-- restedXP_questing
-- movement/guide_path.lua - the exact server path, checked 15 yd ahead
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.1.1
-- ============================================================================
-- 3.7.0 EXACT PATH. Every out-of-combat walk (movement/nav modes nil, move,
-- guide, npc) follows the server's own path, not a smoothed one:
--   1. ONE server request per destination: client:find_path. resample() cuts
--      it into waypoints SPACING (5) yd apart; the destination is the last one.
--   2. The path is prepared in WINDOWS of HORIZON (15) yd, each one shortly
--      before the player reaches it (movement/nav keeps >= HORIZON yd of
--      checked path ahead). process_window() does, per window:
--        objects  push(): a waypoint inside an object's clearance (radius +
--                 BODY + CLEAR) moves straight away from it, <= MAX_PUSH yd
--                 (client object list, scanned at most every SCAN_GAP s);
--        walls    each waypoint is probed WALL_CLEAR yd to its left and right
--                 (WALL_CLEAR_IN indoors): a side the navmesh cannot reach in
--                 about a straight line is a wall / edge, and the waypoint
--                 moves WALL_SHIFT yd away from it (both sides closed: a
--                 corridor - it stays on the server's line);
--        validate a moved waypoint is kept only when the navmesh walks to it
--                 from the one before in about a straight line, else it goes
--                 back (a push must never aim the player at a wall);
--      all of it in ONE batched server request (query.find_paths, <= 64
--      pairs) per window - about one request per 15 yd walked, never per frame.
--   3. indoors() reads the client (player:is_indoors) at most once a second.
-- The destination itself never moves. No ray casts (no core.graphics.trace_line,
-- no /raycast) - the walls come from the navmesh.
-- (3.5.0 - 3.6.1: RestedXP walks only, 3 yd waypoints, checked once at the start.)
-- Objects come from targeting.visible_objects() (the shared cache), filtered
-- like MasterArthasNav's own avoidance: no players, no bag items, no hidden
-- objects, no dead units, no critters / pets / gas clouds, nothing two floors
-- away.
-- ============================================================================

local P = {}

P.SPACING     = 5.0    -- yd between two walked waypoints (3.7.0; was 3)
P.HORIZON     = 15.0   -- yd: one window, prepared ahead of the player
P.BODY        = 0.9    -- yd: the player's body (launcher 2.6.0 body_radius)
P.CLEAR       = 1.0    -- yd kept between the body and an object
P.MAX_PUSH    = 3.0    -- yd a waypoint may be moved aside
P.WALL_CLEAR    = 2.0  -- yd probed left / right of a waypoint outdoors
P.WALL_CLEAR_IN = 1.0  -- ... indoors (doorways, corridors)
P.WALL_SHIFT    = 0.5  -- share of the probe distance a waypoint moves off a wall
P.PROBE_STRAIGHT = 1.3 -- a probe is open when the mesh path to it is <= this x straight + 0.5 yd
P.INDOOR_GAP  = 1.0    -- s between two client indoors reads
P.SCAN_RADIUS = 30     -- yd around the player
P.SCAN_GAP    = 0.5    -- s between two object scans
P.RECHECK_GAP = 0.5    -- s between two looks at the path ahead (client only)
P.AHEAD       = 3      -- waypoints re-checked for new objects (15 yd)
P.STRAIGHT    = 1.6    -- a pushed point is walkable when the mesh path to it
                       -- is at most this times the straight line (+1 yd)
P.PROP_R      = 1.0    -- yd: radius of a non-unit object (no model read, 3.6.1)
P.SAME_OBJ    = 1.0    -- yd: an object this close to one seen at plan time is that one

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
                        -- 3.6.1: the radius is read for units only (a unit
                        -- field). A prop's radius would come from its model,
                        -- and a model that has not loaded yet is the known
                        -- crash class here (M2HitTest, 2.309.0) - props count
                        -- as P.PROP_R yd, no model data is touched.
                        local r = P.PROP_R
                        if unit then
                            local okr, ur = call(o, "get_bounding_radius")
                            if okr and type(ur) == "number" then r = ur end
                        end
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

--- The objects of `objs` that were not in `known` (the scan the path was
--- planned with): only these can make a re-plan worth it (3.6.1). Before, an
--- object the plan had already been pushed round - or a push the navmesh
--- check took back - re-planned the walk every 2 s.
function P.new_only(objs, known)
    if type(known) ~= "table" or #known == 0 then return objs or {} end
    local out = {}
    local d2 = P.SAME_OBJ * P.SAME_OBJ
    for i = 1, #(objs or {}) do
        local o = objs[i]
        local seen = false
        for j = 1, #known do
            local k = known[j]
            local dx, dy = o.x - k.x, o.y - k.y
            if dx * dx + dy * dy <= d2 then seen = true break end
        end
        if not seen then out[#out + 1] = o end
    end
    return out
end

--- A copy of a scan (positions only), kept with the walk.
function P.snapshot(objs)
    local out = {}
    for i = 1, #(objs or {}) do out[i] = { x = objs[i].x, y = objs[i].y } end
    return out
end

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

--- Moves waypoints out of every object's clearance (never the last one);
--- i1..i2 limits it to one window. Returns { [i] = original point } for the
--- waypoints it moved.
function P.push(pts, objs, i1, i2)
    local moved = {}
    if type(pts) ~= "table" or type(objs) ~= "table" or #objs == 0 then return moved end
    for i = math.max(1, i1 or 1), math.min(#pts - 1, i2 or #pts) do
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

-- ----------------------------------------------------------------------------
-- windows (3.7.0)
-- ----------------------------------------------------------------------------
--- Walking distance along pts from index i1 to i2 (2D).
function P.along(pts, i1, i2)
    local d = 0
    for i = math.max(2, i1 + 1), math.min(#pts, i2) do
        d = d + sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].y - pts[i - 1].y) ^ 2)
    end
    return d
end

--- The last index of the window that starts at i1: HORIZON yd of path.
function P.window_end(pts, i1, horizon)
    horizon = horizon or P.HORIZON
    local d, j = 0, i1
    while j < #pts do
        local step = sqrt((pts[j + 1].x - pts[j].x) ^ 2 + (pts[j + 1].y - pts[j].y) ^ 2)
        if d + step > horizon + 0.01 and j > i1 then break end
        d = d + step
        j = j + 1
    end
    return j
end

local indoor = { v = false, t = -1e9 }
--- Is the player indoors (client read, at most once per INDOOR_GAP s)?
function P.indoors()
    local t = now()
    if t - indoor.t < P.INDOOR_GAP then return indoor.v end
    indoor.t = t
    local ok, v = pcall(function()
        local me = core.object_manager.get_local_player()
        return me and me:is_indoors()
    end)
    indoor.v = ok and v == true
    return indoor.v
end

local function path_len(points)
    local len, a = 0, points[1]
    for k = 2, #points do
        local b = points[k]
        len = len + sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        a = b
    end
    return len
end

--- A batch result: ok, points (find_paths answers named fields).
local function result(r)
    if type(r) ~= "table" then return false, nil end
    local ok = r.ok
    local pts = r.points
    if ok == nil then ok, pts = r[1], r[2] end
    return ok == true and type(pts) == "table" and #pts >= 2, pts
end

--- Is the navmesh walk from a to b about a straight line ending at b?
local function straight_ok(r, a, b, factor, slack)
    local ok, pts = result(r)
    if not ok then return false end
    local last = pts[#pts]
    if (last.x - b.x) ^ 2 + (last.y - b.y) ^ 2 > 1.0 then return false end
    local straight = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    return path_len(pts) <= straight * factor + slack
end

--- Prepare the window pts[i1..i2] (step 2 of the header): object pushes, wall
--- probes and the validation of every move, in ONE find_paths request.
--- done(changed): the number of waypoints that moved. Without the batch query
--- the object pushes stay (<= MAX_PUSH) and no wall is probed.
function P.process_window(nav_table, pts, i1, i2, objs, is_indoor, done)
    local last = #pts
    i1, i2 = math.max(1, i1), math.min(i2, last)
    local moved = P.push(pts, objs, i1, i2)
    local q = type(nav_table) == "table" and nav_table.query or nil
    if type(q) ~= "table" or type(q.find_paths) ~= "function" then
        local n = 0
        for _ in pairs(moved) do n = n + 1 end
        return done(n)
    end
    local clear = is_indoor and P.WALL_CLEAR_IN or P.WALL_CLEAR
    local pairs_, jobs = {}, {}
    for i = i1, i2 do
        if i > 1 and i < last then
            local a, b = pts[i - 1], pts[i + 1]
            local dx, dy = b.x - a.x, b.y - a.y
            local l = sqrt(dx * dx + dy * dy)
            if l > 0.01 then
                local p = pts[i]
                local nx, ny = -dy / l, dx / l                  -- left of the walking direction
                local left = { x = p.x + nx * clear, y = p.y + ny * clear, z = p.z }
                local right = { x = p.x - nx * clear, y = p.y - ny * clear, z = p.z }
                pairs_[#pairs_ + 1] = { p, left }
                pairs_[#pairs_ + 1] = { p, right }
                local o = moved[i] or p
                jobs[#jobs + 1] = { i = i, nx = nx, ny = ny, li = #pairs_ - 1, ri = #pairs_, vi = nil,
                    sx = o.x, sy = o.y }                       -- where the server put it
                if moved[i] then
                    pairs_[#pairs_ + 1] = { pts[i - 1], p }
                    jobs[#jobs].vi = #pairs_
                end
            end
        end
        if #pairs_ > 60 then break end                     -- the server takes 64 per batch
    end
    if #pairs_ == 0 then
        local n = 0
        for _ in pairs(moved) do n = n + 1 end
        return done(n)
    end
    local answered = false
    local ok = pcall(q.find_paths, pairs_, nil, function(okb, results)
        if answered then return end
        answered = true
        local changed = 0
        local res = (okb and type(results) == "table") and results or {}
        for _, j in ipairs(jobs) do
            local p = pts[j.i]
            if j.vi and not straight_ok(res[j.vi], pairs_[j.vi][1], p, P.STRAIGHT, 1.0) then
                local o = moved[j.i]
                p.x, p.y, p.z = o.x, o.y, o.z                   -- the push is taken back
            end
            local lp, rp = pairs_[j.li][2], pairs_[j.ri][2]
            local l_open = straight_ok(res[j.li], p, lp, P.PROBE_STRAIGHT, 0.5)
            local r_open = straight_ok(res[j.ri], p, rp, P.PROBE_STRAIGHT, 0.5)
            local s = clear * P.WALL_SHIFT
            if l_open and not r_open then
                p.x, p.y = p.x + j.nx * s, p.y + j.ny * s       -- wall on the right
            elseif r_open and not l_open then
                p.x, p.y = p.x - j.nx * s, p.y - j.ny * s       -- wall on the left
            end
            if (p.x - j.sx) ^ 2 + (p.y - j.sy) ^ 2 > 0.09 then changed = changed + 1 end
        end
        done(changed)
    end)
    if not ok and not answered then
        answered = true
        local n = 0
        for _ in pairs(moved) do n = n + 1 end
        done(n)
    end
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
