-- ============================================================================
-- AmeisenNav
-- anav/horizon.lua - rolling 20-yard path windows, validated before walking
-- ============================================================================
-- Version: 1.6.0
-- Author: BLIZZ
-- ============================================================================
-- WHAT (1.6.0)
--   A move_to is no longer walked as one long server path. The client asks
--   the server for an UNSMOOTHED path from where the player stands (position
--   and height) to the destination, and this module turns its first
--   C.horizon_length (20) yards into a window of waypoints C.waypoint_spacing
--   (5) yards apart. The window is checked and corrected completely BEFORE a
--   single step is taken; the client walks it, and when the player is within
--   C.horizon_refresh (5) yards of its end the next window is built the same
--   way from the player's new position and swapped in without stopping. That
--   repeats until the destination is in the window (the final window).
--
-- HOW (nav server only - no native traces: core.graphics.trace_line crashes
-- the client, see avoid.lua). Two batched POST /paths per window:
--   1. ground   every leg is asked at four heights (the line's, the previous
--               ground, +6, -6); the answer that lands on the waypoint gives
--               its real ground height. No answer = the leg leaves walkable
--               ground. Then climb / drop per yard and cliff drops per leg.
--               A bad leg is re-planned unsmoothed (C.splice_flags) between
--               its neighbours and spliced in (C.horizon_splices per window).
--   2. width    from every waypoint, short probes C.horizon_probes (1, 2, 3)
--               yards to the left and right at ground height. A probe is free
--               when it reaches its target with no detour and no ledge; the
--               free distance each side is measured from the probe ends.
--               Each waypoint is then moved so it keeps C.horizon_clearance
--               (2) yards from walls, ledges and drops on both sides; a
--               corridor narrower than twice that is walked down its middle.
--   3. objects  cached nearby objects (avoid.lua, radius + body) push the
--               waypoint sideways, never past the free distance measured in 2.
-- The start point is the player's own position; the destination is never
-- moved. No smoothing anywhere: the walker's own smoothing is off as well.
-- ============================================================================

local C = require("anav/config")
local L = require("anav/log")
local Q = require("anav/query")
local AV = require("anav/avoid")
---@type vec3
local vec3 = require("common/geometry/vector_3")

local H = {}

local sqrt = math.sqrt
local fmt = string.format

H.stats = { windows = 0, lifted = 0, shifted = 0, narrow = 0, objects = 0, spliced = 0, bad_legs = 0 }

local function d2(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    return sqrt(dx * dx + dy * dy)
end

local function same(a, b)
    return math.abs(a.x - b.x) < 0.05 and math.abs(a.y - b.y) < 0.05 and math.abs(a.z - b.z) < 0.05
end

local function pt(x, y, z) return { x = x, y = y, z = z } end

--- Resample to at most `spacing` yards between points (no stub segments).
function H.densify(points, spacing)
    spacing = math.max(1, spacing or C.waypoint_spacing or 5)
    local out = {}
    local function add(x, y, z)
        local p = pt(x, y, z)
        local last = out[#out]
        if last and same(last, p) then return end
        out[#out + 1] = p
    end
    for i = 1, #points do
        local b = points[i]
        if i > 1 then
            local a = points[i - 1]
            local d = d2(a, b)
            local n = math.floor(d / spacing)
            if d - n * spacing < 0.5 then n = n - 1 end
            for k = 1, n do
                local f = (k * spacing) / d
                add(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f)
            end
        end
        add(b.x, b.y, b.z)
    end
    return out
end

--- The first `length` yards of `path` (densified), starting at `from`.
--- Returns points, is_final (the window reaches the path's end).
function H.cut(from, path, length)
    local dense = H.densify(path, C.waypoint_spacing)
    local out = { pt(from.x, from.y, from.z) }
    -- skip server points that are already behind / under the player
    local start = 1
    while start <= #dense and d2(from, dense[start]) < 1.0 do start = start + 1 end
    local walked, prev = 0, out[1]
    for k = start, #dense do
        local p = dense[k]
        walked = walked + d2(prev, p)
        out[#out + 1] = pt(p.x, p.y, p.z)
        prev = p
        if walked >= length and k < #dense then
            -- the rest is short: take the whole path now (no 2-yard window)
            local rest = 0
            for j = k + 1, #dense do rest = rest + d2(dense[j - 1], dense[j]) end
            if rest > C.horizon_refresh then return out, false end
        end
    end
    return out, true
end

-- ----------------------------------------------------------------------------
-- 1. ground height / slope / cliff
-- ----------------------------------------------------------------------------
local Z_TRY = { 0, "a", 6, -6 }

local function ground_of(res, base, a, q)
    local leg = d2(a, q)
    for i = 1, #Z_TRY do
        local r = res[base + i]
        if r and r.ok and r.points and #r.points > 0 then
            local e = r.points[#r.points]
            if d2(e, q) <= 1.0 and Q.path_length(r.points) <= leg * 1.4 + 2.5 then
                return e.z
            end
        end
    end
    return nil
end

local function check_ground(win, cb)
    local list = {}
    for k = 2, #win do
        local a, q = win[k - 1], win[k]
        for i = 1, #Z_TRY do
            local dz = Z_TRY[i]
            list[#list + 1] = { a, pt(q.x, q.y, dz == "a" and a.z or (q.z + dz)) }
        end
    end
    if #list == 0 then cb(true, nil); return end
    Q.find_paths(list, { flags = C.splice_flags, allow_partial = true }, function(ok, res)
        if not ok or type(res) ~= "table" then cb(false, nil); return end
        local bad = nil
        for k = 2, #win do
            local a, q = win[k - 1], win[k]
            local g = ground_of(res, (k - 2) * #Z_TRY, a, q)
            if not g then
                bad = bad or { k = k, why = "leg leaves the walkable ground" }
            else
                if math.abs(g - q.z) > 0.3 then
                    q.z = g
                    H.stats.lifted = H.stats.lifted + 1
                end
                local leg = math.max(d2(a, q), 0.5)
                local rise = q.z - a.z
                if not bad and rise > C.max_climb * leg then
                    bad = { k = k, why = fmt("climb %.1f yd over %.1f yd", rise, leg) }
                elseif not bad and (-rise > C.max_drop * leg or -rise > C.cliff_drop) then
                    bad = { k = k, why = fmt("drop %.1f yd over %.1f yd", -rise, leg) }
                end
            end
        end
        cb(true, bad)
    end)
end

-- ----------------------------------------------------------------------------
-- 2. width: free distance left / right, keep the clearance
-- ----------------------------------------------------------------------------
local function normal_at(win, k)
    local a, b
    if k < #win then a, b = win[k], win[k + 1] else a, b = win[k - 1], win[k] end
    if k > 1 and k < #win then a = win[k - 1] end
    local dx, dy = b.x - a.x, b.y - a.y
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.05 then return nil end
    return -dy / len, dx / len                             -- left normal
end

-- how far the probe from q toward `to` (distance d, side normal n) really gets
local function reach(r, q, to, d, nx, ny)
    if not r or not r.ok or not r.points or #r.points == 0 then return 0, false end
    local e = r.points[#r.points]
    local along = (e.x - q.x) * nx + (e.y - q.y) * ny
    local ledge = math.abs(e.z - q.z) > d * 1.2 + 0.5
    local detour = Q.path_length(r.points) > d * 1.4 + 0.5
    if d2(e, to) <= 0.5 and not detour and not ledge then return d, true end
    if ledge or detour then return 0, false end
    if along < 0 then along = 0 elseif along > d then along = d end
    return along, false
end

local function check_width(win, final, cb)
    local probes = C.horizon_probes
    local list, idx = {}, {}
    local last = final and #win - 1 or #win                -- never move the destination
    for k = 2, last do
        local nx, ny = normal_at(win, k)
        if nx then
            local q = win[k]
            idx[#idx + 1] = { k = k, nx = nx, ny = ny, base = #list }
            for i = 1, #probes do
                local d = probes[i]
                list[#list + 1] = { q, pt(q.x + nx * d, q.y + ny * d, q.z) }
                list[#list + 1] = { q, pt(q.x - nx * d, q.y - ny * d, q.z) }
            end
        end
    end
    if #list == 0 then cb(true, {}); return end
    Q.find_paths(list, { flags = C.splice_flags, allow_partial = true }, function(ok, res)
        if not ok or type(res) ~= "table" then cb(false, nil); return end
        local free = {}
        for _, e in ipairs(idx) do
            local q = win[e.k]
            local fl, fr = 0, 0
            local open_l, open_r = true, true
            for i = 1, #probes do
                local d = probes[i]
                local tl = pt(q.x + e.nx * d, q.y + e.ny * d, q.z)
                local tr = pt(q.x - e.nx * d, q.y - e.ny * d, q.z)
                if open_l then
                    local got, whole = reach(res[e.base + (i - 1) * 2 + 1], q, tl, d, e.nx, e.ny)
                    if got > fl then fl = got end
                    if not whole then open_l = false end
                end
                if open_r then
                    local got, whole = reach(res[e.base + (i - 1) * 2 + 2], q, tr, d, -e.nx, -e.ny)
                    if got > fr then fr = got end
                    if not whole then open_r = false end
                end
            end
            free[e.k] = { l = fl, r = fr, nx = e.nx, ny = e.ny,
                open_l = open_l, open_r = open_r }
        end
        cb(true, free)
    end)
end

-- shift waypoint k along its normal so both sides keep the clearance
local function place(win, k, f)
    local c = C.horizon_clearance
    local shift = 0
    if f.l + f.r < 2 * c then
        shift = (f.l - f.r) / 2                            -- narrow: the middle
        H.stats.narrow = H.stats.narrow + 1
    elseif f.l < c then
        shift = -math.min(c - f.l, f.r - c)                -- wall left: step right
    elseif f.r < c then
        shift = math.min(c - f.r, f.l - c)                 -- wall right: step left
    end
    -- 3. objects: push clear of cached objects, inside the measured free room
    local q = win[k]
    local objs, n = AV.objects()
    for i = 1, n do
        local o = objs[i]
        local qx, qy = q.x + f.nx * shift, q.y + f.ny * shift
        local need = o.r + C.body_radius + C.horizon_object_clearance
        local dx, dy = qx - o.x, qy - o.y
        if dx * dx + dy * dy < need * need and math.abs(o.z - q.z) < 4 then
            local side = dx * f.nx + dy * f.ny                 -- object left (<0) or right (>0) of q
            local off = sqrt(math.max(0, need * need - (dx * f.ny - dy * f.nx) ^ 2))
            local want = side >= 0 and (off - side) or -(off + side)
            local cand = shift + want
            if cand > f.l - 0.5 then cand = f.l - 0.5 end
            if cand < -(f.r - 0.5) then cand = -(f.r - 0.5) end
            if math.abs(cand - shift) > 0.1 then
                shift = cand
                H.stats.objects = H.stats.objects + 1
            end
        end
    end
    if math.abs(shift) >= 0.25 then
        q.x, q.y = q.x + f.nx * shift, q.y + f.ny * shift
        H.stats.shifted = H.stats.shifted + 1
    end
end

-- ----------------------------------------------------------------------------
-- build one window
-- ----------------------------------------------------------------------------
--- cb(ok, window_points(vec3[]) | nil, info { final, why })
--- `from` = player position (x, y, z), `path` = server path to the destination.
function H.build(from, path, cb)
    if type(path) ~= "table" or #path == 0 then cb(false, nil, { why = "empty path" }); return end
    local win, final = H.cut(from, path, C.horizon_length)
    if #win < 2 then
        cb(true, { vec3.new(from.x, from.y, from.z) }, { final = true })
        return
    end
    pcall(AV.refresh, from.x, from.y, from.z)
    local splices = 0

    local function finish()
        H.stats.windows = H.stats.windows + 1
        local out = {}
        for i = 1, #win do out[i] = vec3.new(win[i].x, win[i].y, win[i].z) end
        cb(true, out, { final = final })
    end

    local function widths()
        check_width(win, final, function(ok, free)
            if ok and free then
                for k, f in pairs(free) do place(win, k, f) end
            else
                L.debug("horizon: width check failed - walking the window unshifted")
            end
            finish()
        end)
    end

    local ground
    ground = function()
        check_ground(win, function(ok, bad)
            if not ok then
                L.debug("horizon: ground check failed - walking the window as planned")
                return widths()
            end
            if not bad then return widths() end
            H.stats.bad_legs = H.stats.bad_legs + 1
            if splices >= C.horizon_splices then
                L.debug("horizon: %s at waypoint %d - splice limit reached, walking it", bad.why, bad.k)
                return widths()
            end
            splices = splices + 1
            local a = win[bad.k - 1]
            local j = math.min(#win, bad.k + 1)
            local b = win[j]
            Q.find_path(a, b, { flags = C.splice_flags, no_cache = true, allow_partial = false }, function(okp, piece)
                if not okp or not piece or #piece < 2 then
                    L.debug("horizon: %s at waypoint %d - no unsmoothed re-plan, walking it", bad.why, bad.k)
                    return widths()
                end
                local dense = H.densify(piece, C.waypoint_spacing)
                if #dense > 0 and same(dense[1], a) then table.remove(dense, 1) end
                local new = {}
                for k = 1, bad.k - 1 do new[#new + 1] = win[k] end
                for k = 1, #dense do new[#new + 1] = dense[k] end
                for k = j + 1, #win do new[#new + 1] = win[k] end
                win = new
                H.stats.spliced = H.stats.spliced + 1
                L.debug("horizon: %s at waypoint %d - re-planned unsmoothed (%d points)", bad.why, bad.k, #dense)
                ground()                                   -- check the new legs too
            end)
        end)
    end
    ground()
end

return H
