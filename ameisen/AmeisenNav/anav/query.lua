-- ============================================================================
-- AmeisenNav
-- anav/query.lua - navmesh queries (no movement)
-- ============================================================================
-- Version: 1.0.0
-- Author: BLIZZ
-- ============================================================================
-- Every function is asynchronous and calls back exactly once.
--
--   Q.find_path(from, to, opts, cb)     cb(ok, points|nil, info)
--   Q.find_paths(pairs, opts, cb)       cb(ok, results|nil, info)
--   Q.get_height(pos, cb)               cb(ok, z|nil, info)
--   Q.raycast(from, to, cb)             cb(ok, clear, hit_point|nil, info)
--   Q.move_along_surface(from, to, cb)  cb(ok, point|nil, info)
--   Q.random_point(center, radius, cb)  cb(ok, point|nil, info)
--
-- info = { code = <code>, detail = <text>, partial = bool, ms = latency }
-- Failure codes:
--   map_not_loaded  no mesh for this map
--   start_off_mesh  start not on the navmesh
--   end_off_mesh    destination not on the navmesh
--   no_path         no connection between start and end
--   unreachable     only a partial path exists (and it stops too far away)
--   bad_request     invalid input (a bug in the caller)
--   server_timeout  the server did not answer in time
--   server_down     the server is not running
--
-- Points are plain tables { x=, y=, z= } unless opts.vec3 is set.
-- opts: { map = id, state = "normal|alliance|horde|dead", flags = n,
--         allow_partial = bool, no_cache = bool, vec3 = bool }
-- ============================================================================

---@type vec3
local vec3 = require("common/geometry/vector_3")

local C = require("anav/config")
local L = require("anav/log")
local T = require("anav/transport")
local X = require("anav/context")

local Q = {}

local floor, sqrt = math.floor, math.sqrt
local fmt = string.format

-- ----------------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------------
local function xyz(p)
    if not p then return nil end
    local x, y, z = p.x, p.y, p.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return x, y, z
end
Q.xyz = xyz

local function make_point(x, y, z, as_vec3)
    if as_vec3 then return vec3.new(x, y, z) end
    return { x = x, y = y, z = z }
end

local function ctx(opts)
    local map = opts and opts.map or X.map_id()
    local state = opts and opts.state or X.filter_state()
    return map, state
end

--- Map a transport result / server "err" line to an info table.
local function failure(ok, status, body)
    if not ok then
        if status == "server_down" then return { code = "server_down", detail = "server not running" } end
        if status == "timeout" then return { code = "server_timeout", detail = "no answer in time" } end
        if status == "busy" then return { code = "server_timeout", detail = "request queue full" } end
        return { code = "server_timeout", detail = "transport error" }
    end
    local code, detail = body:match("^err (%S+)%s*([^\n]*)")
    if code then return { code = code, detail = detail ~= "" and detail or code } end
    return { code = "bad_request", detail = fmt("unexpected HTTP %s", tostring(status)) }
end

--- Parse "ok <n> complete|partial" + n lines. Returns points, partial.
local function parse_path_block(lines, i, as_vec3)
    local n, kind = lines[i]:match("^ok (%d+) (%a+)")
    n = tonumber(n)
    if not n then return nil end
    local pts = {}
    for k = 1, n do
        local line = lines[i + k]
        if not line then return nil end
        local x, y, z = line:match("^(%S+) (%S+) (%S+)")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if not z then return nil end
        pts[k] = make_point(x, y, z, as_vec3)
    end
    return pts, kind == "partial", i + n + 1
end

local function split_lines(body)
    local lines = {}
    for line in body:gmatch("[^\n]+") do lines[#lines + 1] = line end
    return lines
end

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return sqrt(dx * dx + dy * dy + dz * dz)
end
Q.dist3 = dist3

function Q.path_length(pts)
    local d = 0
    for i = 2, #pts do d = d + dist3(pts[i - 1], pts[i]) end
    return d
end

-- ----------------------------------------------------------------------------
-- path cache + in-flight merging
-- ----------------------------------------------------------------------------
local cache = {}        -- key -> { t, pts, partial }
local cache_n = 0
local waiting = {}      -- key -> { callbacks }

local function cache_key(map, state, flags, sx, sy, sz, ex, ey, ez)
    local g = C.path_cache_grid
    return fmt("%d|%s|%d|%d|%d|%d|%d|%d|%d", map, state, flags,
        floor(sx / g), floor(sy / g), floor(sz / g), floor(ex / g), floor(ey / g), floor(ez / g))
end

local function cache_put(key, pts, partial)
    if cache_n >= C.path_cache_size then
        -- drop the oldest entry
        local oldest_k, oldest_t = nil, math.huge
        for k, e in pairs(cache) do
            if e.t < oldest_t then oldest_k, oldest_t = k, e.t end
        end
        if oldest_k then cache[oldest_k] = nil; cache_n = cache_n - 1 end
    end
    if not cache[key] then cache_n = cache_n + 1 end
    cache[key] = { t = core.time(), pts = pts, partial = partial }
end

function Q.clear_cache()
    cache, cache_n = {}, 0
end

local function copy_points(pts, as_vec3)
    local out = {}
    for i = 1, #pts do
        local p = pts[i]
        out[i] = make_point(p.x, p.y, p.z, as_vec3)
    end
    return out
end

--- Decide whether a (possibly partial) path is usable for `to`.
local function accept(pts, partial, to, opts)
    if not partial then return true end
    if opts and opts.allow_partial then return true end
    local last = pts[#pts]
    return last and dist3(last, to) <= C.partial_accept
end

-- ----------------------------------------------------------------------------
-- find_path
-- ----------------------------------------------------------------------------
function Q.find_path(from, to, opts, cb)
    local sx, sy, sz = xyz(from)
    local ex, ey, ez = xyz(to)
    if not sx or not ex then
        cb(false, nil, { code = "bad_request", detail = "from/to need x, y, z" })
        return
    end
    local map, state = ctx(opts)
    if not map then
        cb(false, nil, { code = "map_not_loaded", detail = "no map id" })
        return
    end
    local flags = (opts and opts.flags) or C.path_flags
    local as_vec3 = opts and opts.vec3
    local target = { x = ex, y = ey, z = ez }
    local key = cache_key(map, state, flags, sx, sy, sz, ex, ey, ez)

    local function deliver(ok, pts, partial, info)
        if ok and not accept(pts, partial, target, opts) then
            local last = pts[#pts]
            cb(false, nil, { code = "unreachable",
                detail = fmt("path stops %.1f yd short of the destination", dist3(last, target)),
                partial = true })
            return
        end
        if ok then
            cb(true, copy_points(pts, as_vec3), info)
        else
            cb(false, nil, info)
        end
    end

    if not (opts and opts.no_cache) then
        local e = cache[key]
        if e and (core.time() - e.t) <= C.path_cache_ttl then
            deliver(true, e.pts, e.partial, { code = "ok", partial = e.partial, cached = true, ms = 0 })
            return
        end
        local w = waiting[key]
        if w then
            w[#w + 1] = deliver
            return
        end
    end

    local list = { deliver }
    waiting[key] = list
    local t0 = core.time()
    local path = fmt("/path?map=%d&sx=%.2f&sy=%.2f&sz=%.2f&ex=%.2f&ey=%.2f&ez=%.2f&flags=%d&state=%s",
        map, sx, sy, sz, ex, ey, ez, flags, state)

    T.request(path, nil, function(ok, status, body)
        if waiting[key] == list then waiting[key] = nil end
        local ms = (core.time() - t0) * 1000
        local pts, partial
        if ok and status == 200 then
            pts, partial = parse_path_block(split_lines(body), 1, false)
        end
        local info
        if pts and #pts > 0 then
            cache_put(key, pts, partial)
            info = { code = "ok", partial = partial, ms = ms }
        else
            info = pts and { code = "no_path", detail = "empty path" } or failure(ok, status, body)
            info.ms = ms
            L.debug("path map %d (%.0f,%.0f)->(%.0f,%.0f) failed: %s %s", map, sx, sy, ex, ey, info.code, info.detail or "")
        end
        for i = 1, #list do
            if pts and #pts > 0 then list[i](true, pts, partial, info)
            else list[i](false, nil, nil, info) end
        end
    end)
end

-- ----------------------------------------------------------------------------
-- find_paths (batch)   pairs = { {from, to}, ... }  ->  results[i] = { ok, points, info }
-- ----------------------------------------------------------------------------
function Q.find_paths(pairs_list, opts, cb)
    local map, state = ctx(opts)
    if not map then
        cb(false, nil, { code = "map_not_loaded", detail = "no map id" })
        return
    end
    local flags = (opts and opts.flags) or C.path_flags
    local body = {}
    for i = 1, #pairs_list do
        local sx, sy, sz = xyz(pairs_list[i][1])
        local ex, ey, ez = xyz(pairs_list[i][2])
        if not sx or not ex then
            cb(false, nil, { code = "bad_request", detail = fmt("pair %d needs x, y, z", i) })
            return
        end
        body[i] = fmt("%d %.2f %.2f %.2f %.2f %.2f %.2f %d %s", map, sx, sy, sz, ex, ey, ez, flags, state)
    end
    if #body == 0 then cb(true, {}, { code = "ok" }); return end

    T.request("/paths", table.concat(body, "\n"), function(ok, status, text)
        if not ok or status ~= 200 then
            cb(false, nil, failure(ok, status, text))
            return
        end
        local lines = split_lines(text)
        local results, i = {}, 1
        while i <= #lines do
            local idx, rest = lines[i]:match("^#(%d+) (.*)$")
            idx = tonumber(idx)
            if not idx then break end
            lines[i] = rest
            if rest:sub(1, 3) == "ok " then
                local pts, partial, nxt = parse_path_block(lines, i, opts and opts.vec3)
                if not pts then break end
                local to = pairs_list[idx + 1][2]
                if accept(pts, partial, to, opts) then
                    results[idx + 1] = { ok = true, points = pts, info = { code = "ok", partial = partial } }
                else
                    results[idx + 1] = { ok = false, info = { code = "unreachable", partial = true } }
                end
                i = nxt
            else
                results[idx + 1] = { ok = false, info = failure(true, 422, rest) }
                i = i + 1
            end
        end
        cb(true, results, { code = "ok" })
    end, { timeout = C.request_timeout * 3 })
end

-- ----------------------------------------------------------------------------
-- single point queries
-- ----------------------------------------------------------------------------
local function point_query(path, as_vec3, cb)
    T.request(path, nil, function(ok, status, body)
        if ok and status == 200 then
            local x, y, z = body:match("^ok (%S+) (%S+) (%S+)")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            if z then
                cb(true, make_point(x, y, z, as_vec3), { code = "ok" })
                return
            end
        end
        cb(false, nil, failure(ok, status, body))
    end)
end

function Q.get_height(pos, cb, opts)
    local x, y, z = xyz(pos)
    local map = ctx(opts)
    if not x or not map then cb(false, nil, { code = "bad_request" }); return end
    point_query(fmt("/height?map=%d&x=%.2f&y=%.2f&z=%.2f", map, x, y, z), false, function(ok, p, info)
        cb(ok, p and p.z or nil, info)
    end)
end

function Q.move_along_surface(from, to, cb, opts)
    local sx, sy, sz = xyz(from)
    local ex, ey, ez = xyz(to)
    local map, state = ctx(opts)
    if not sx or not ex or not map then cb(false, nil, { code = "bad_request" }); return end
    point_query(fmt("/move?map=%d&sx=%.2f&sy=%.2f&sz=%.2f&ex=%.2f&ey=%.2f&ez=%.2f&state=%s",
        map, sx, sy, sz, ex, ey, ez, state), opts and opts.vec3, cb)
end

function Q.random_point(center, radius, cb, opts)
    local x, y, z = xyz(center)
    local map, state = ctx(opts)
    if not x or not map or type(radius) ~= "number" or radius <= 0 then
        cb(false, nil, { code = "bad_request" })
        return
    end
    point_query(fmt("/random?map=%d&x=%.2f&y=%.2f&z=%.2f&r=%.2f&state=%s", map, x, y, z, radius, state),
        opts and opts.vec3, cb)
end

function Q.raycast(from, to, cb, opts)
    local sx, sy, sz = xyz(from)
    local ex, ey, ez = xyz(to)
    local map, state = ctx(opts)
    if not sx or not ex or not map then cb(false, false, nil, { code = "bad_request" }); return end
    T.request(fmt("/raycast?map=%d&sx=%.2f&sy=%.2f&sz=%.2f&ex=%.2f&ey=%.2f&ez=%.2f&state=%s",
        map, sx, sy, sz, ex, ey, ez, state), nil, function(ok, status, body)
        if ok and status == 200 then
            if body:sub(1, 8) == "ok clear" then
                cb(true, true, nil, { code = "ok" })
                return
            end
            local x, y, z = body:match("^ok hit (%S+) (%S+) (%S+)")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            if z then
                cb(true, false, make_point(x, y, z, opts and opts.vec3), { code = "ok" })
                return
            end
        end
        cb(false, false, nil, failure(ok, status, body))
    end)
end

return Q
