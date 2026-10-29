-- Local grid A* ported from the Orca search (Path, Node, AStar, Handler,
-- get_astar_path, FixPath, SmoothPath, FlattenPath, simplify_path, ShouldJump).
-- World queries use the Sylvanas core API. trace_line returns a boolean, so
-- impact height is recovered with a binary search. Ground Z uses
-- core.get_height_for_position. There is no verified mesh-tile query, so a
-- cell is accepted when the clearance traces are open.

---@type vec3
local vec3 = require("common/geometry/vector_3")
-- common/color is only ever needed by the debug draw, so it is fetched when
-- set_debug(true) first asks for it: a product that never draws does not have
-- to have the module, and neither does a test that loads this file.
local color = nil
local function colors()
    if color == nil then
        local ok, mod = pcall(require, "common/color")
        color = (ok and type(mod) == "table") and mod or false
    end
    return color or nil
end
---@type vec2
local vec2 = require("common/geometry/vector_2")
---@type enums
local enums = require("common/enums")

local M = {}

local function trace_mask(...)
    return enums.collision_flags.combine(...)
end

local COLLISION = trace_mask("DoodadCollision", "DoodadRender", "WmoCollision", "WmoRender", "EntityCollision")
local ALL_FLAGS = trace_mask("DoodadCollision", "DoodadRender", "WmoCollision", "WmoRender", "EntityCollision", "Terrain", "LiquidWaterWalkable", "LiquidAll")
local FIX_FLAGS = trace_mask("DoodadCollision", "DoodadRender", "WmoCollision", "WmoRender", "Terrain", "LiquidWaterWalkable")
local WATER_FLAGS = trace_mask("LiquidWaterWalkable", "LiquidAll")
local JUMP_FLAGS = trace_mask("WmoCollision", "WmoRender", "DoodadCollision", "Terrain")

-- The three masks the movement engine runs on. Built from enums.collision_flags
-- by name, never a raw hex: on a classic client any bit above 0x1FFFFF
-- (EntityRender and up) raises a Lua error instead of being passed on, so
-- EntityRender is in none of them.
--   WALK  decides a blocked micro cell and whether a cluster edge has an opening
--   WATER is a water-surface height sample and nothing else
--   SIGHT is the cast-range line of sight check
local WALK = trace_mask(
    "DoodadCollision", "DoodadRender",
    "WmoCollision", "WmoRender",
    "EntityCollision", "Terrain")
local WATER = trace_mask("LiquidWaterWalkable", "LiquidAll")
local SIGHT = trace_mask("LineOfSight")

local HORIZONTAL_COST = 20
local VERTICAL_COST = 5
local MAX_SYNC_CHECKS = 100
local MAX_ASYNC_CHECKS = 75
local ASYNC_BUDGET_SEC = 0.75
local STEP = 1

local debug_enabled = false
local render_hooked = false
local pump_hooked = false
local draw_path = nil
local good_nodes = {}
local bad_nodes = {}
local active_job = nil

local function v3(x, y, z)
    return vec3.new(x, y, z)
end

-- RAY HEALTH IS SHARED. A trace_line / native_intersect / height call that
-- THROWS is the client, not the question asked, and every ray user has to stop
-- together: one switch, never two (two switches were the 2026-10-27 mid-match
-- native crash). A product lends its own flag here; without one the engine
-- keeps a local count and stops asking after RAY_ERRORS throws.
local RAY_ERRORS = 3
local ray_errors = 0
local ray_reporter = nil
local rays_dead = false

--- fn(why) is the product's shared "the client is bad" entry (auto_bg's
--- T.client_bad, for instance). Called on a THROW only, never on a false.
function M.set_ray_error_reporter(fn)
    ray_reporter = (type(fn) == "function") and fn or nil
end

function M.rays_dead()
    return rays_dead
end

function M.reset_ray_health()
    ray_errors, rays_dead = 0, false
end

local function ray_threw(what)
    ray_errors = ray_errors + 1
    if ray_reporter then
        pcall(ray_reporter, "astar engine: " .. tostring(what) .. " threw")
    end
    if ray_errors >= RAY_ERRORS then
        rays_dead = true
        pcall(core.log_warning, "movement engine: rays off for this session - "
            .. tostring(what) .. " kept throwing")
    end
end

local function trace(ax, ay, az, bx, by, bz, flags)
    if rays_dead then
        return false
    end
    local ok, hit = pcall(core.graphics.trace_line, v3(ax, ay, az), v3(bx, by, bz), flags)
    if not ok then
        ray_threw("trace_line")
        return false
    end
    return hit == true
end

local function hit_z(x, y, z_top, z_bottom, flags)
    if not trace(x, y, z_top, x, y, z_bottom, flags) then
        return nil
    end
    local lo = z_bottom
    local hi = z_top
    for _ = 1, 8 do
        local mid = (lo + hi) * 0.5
        if trace(x, y, z_top, x, y, mid, flags) then
            lo = mid
        else
            hi = mid
        end
    end
    return lo
end

local function ground_z(x, y, z)
    local h = core.get_height_for_position(v3(x, y, z))
    if type(h) == "number" and h == h then
        return h
    end
    return z
end

local function player()
    return core.object_manager.get_local_player()
end

local function indoors()
    local me = player()
    if me and me:is_valid() and me:is_indoors() then
        return true
    end
    return false
end

local function player_pos()
    local me = player()
    if not me or not me:is_valid() then
        return nil
    end
    local pos = me:get_position()
    if not pos then
        return nil
    end
    return pos.x, pos.y, pos.z, me
end

local Path = {}
Path.__index = Path

function Path.new(nodes, total_cost)
    return setmetatable({ nodes = nodes, total_cost = total_cost }, Path)
end

function Path:get_nodes()
    return self.nodes
end

function Path:get_total_move_cost()
    return self.total_cost
end

local Node = {}
Node.__index = Node

function Node.new(location, move_cost, id, parent)
    return setmetatable({
        location = location,
        move_cost = move_cost,
        parent = parent,
        score = 0,
        id = id,
        x = location.x,
        y = location.y,
        z = location.z,
    }, Node)
end

local Handler = {}
Handler.__index = Handler

function Handler.new()
    return setmetatable({
        node_attempts = 0,
        max_attempts = 5000000,
    }, Handler)
end

function Handler:get_node_id(location)
    return (location.x * 50000 * 50000) + (location.y * 50000) + location.z
end

function Handler:get_node(location)
    self.node_attempts = self.node_attempts + 1
    if self.node_attempts > self.max_attempts then
        return nil
    end

    if location.px and location.x then
        local reach = 0.25
        local ground_reach = 0.5
        local high_ground_reach = 2.2
        local x, y, z = location.x, location.y, location.z
        local px, py, pz = location.px, location.py, location.pz
        local blocked = false

        for sx = -2, 2 do
            for sy = -2, 2 do
                local ox = x + (sx * reach)
                local oy = y + (sy * reach)
                if trace(ox, oy, z + ground_reach, px, py, pz + ground_reach, COLLISION)
                    or trace(ox, oy, z + high_ground_reach, px, py, pz + high_ground_reach, COLLISION) then
                    blocked = true
                    break
                end
            end
            if blocked then
                break
            end
        end

        if not blocked and trace(x, y, z + 0.1, x, y, z + 3, COLLISION) then
            blocked = true
        end

        if blocked or (math.max(z, pz) - math.min(z, pz)) > 0.5 then
            if debug_enabled then
                bad_nodes[#bad_nodes + 1] = location
            end
            return nil
        end

        if debug_enabled then
            good_nodes[#good_nodes + 1] = location
        end
        return Node.new(location, 1, self:get_node_id(location))
    end

    if debug_enabled then
        good_nodes[#good_nodes + 1] = location
    end
    return Node.new(location, 1, self:get_node_id(location))
end

function Handler:locations_equal(a, b)
    return math.abs(a.x - b.x) < 1
        and math.abs(a.y - b.y) < 1
        and math.abs(a.z - b.z) < 1
end

function Handler:expand(x, y, z, from_node, destx, desty, destz)
    local offset_high = indoors() and 1.5 or 8
    local snapped = hit_z(x, y, z + offset_high, z - 500, ALL_FLAGS)
    if snapped then
        z = snapped
    else
        z = ground_z(x, y, z)
    end

    local node = self:get_node({
        x = x,
        y = y,
        z = z,
        px = from_node.x,
        py = from_node.y,
        pz = from_node.z,
    })
    if not node then
        return nil
    end

    local dx = math.max(x, destx) - math.min(x, destx)
    local dy = math.max(y, desty) - math.min(y, desty)
    local dz = math.max(z, destz) - math.min(z, destz)
    node.move_cost = node.move_cost + from_node.move_cost
    node.score = node.move_cost + ((dx + dy) * HORIZONTAL_COST) + (dz * VERTICAL_COST)
    node.parent = from_node
    node.x, node.y, node.z = x, y, z
    return node
end

function Handler:adjacent(current, dest)
    local result = {}
    local cl = current.location
    for x = -STEP, STEP, STEP do
        for y = -STEP, STEP, STEP do
            local node = self:expand(cl.x + x, cl.y + y, cl.z, current, dest.x, dest.y, dest.z)
            if node then
                result[#result + 1] = node
            end
        end
    end
    return result
end

local AStar = {}
AStar.__index = AStar

function AStar.new(handler)
    return setmetatable({ handler = handler, open = {}, closed = {} }, AStar)
end

function AStar:_best_open()
    local best = nil
    for _, node in pairs(self.open) do
        if best == nil or node.score <= best.score then
            best = node
        end
    end
    return best
end

function AStar:_trace(node)
    local nodes = {}
    local total = node.move_cost
    local parent = node.parent
    nodes[#nodes + 1] = node
    while parent do
        nodes[#nodes + 1] = parent
        parent = parent.parent
    end
    local ordered = {}
    for i = #nodes, 1, -1 do
        ordered[#ordered + 1] = nodes[i]
    end
    draw_path = ordered
    return Path.new(ordered, total)
end

function AStar:_consider(node, goal)
    self.open[node.id] = nil
    self.closed[node.id] = node.id
    local neighbors = self.handler:adjacent(node, goal)
    for i = 1, #neighbors do
        local next_node = neighbors[i]
        if self.handler:locations_equal(next_node.location, goal) then
            return next_node
        elseif self.closed[next_node.id] == nil then
            local existing = self.open[next_node.id]
            if existing == nil or next_node.move_cost < existing.move_cost then
                self.open[next_node.id] = next_node
            end
        end
    end
    return nil
end

function AStar:find_next(from_location, to_location, max_checks, yield_each)
    self.open = {}
    self.closed = {}
    local start = self.handler:get_node(from_location)
    if not start then
        return nil
    end
    self.open[start.id] = start
    local current = start
    local checks = 0
    local finish = nil
    while not finish do
        checks = checks + 1
        if checks > max_checks or not current then
            return nil
        end
        finish = self:_consider(current, to_location)
        if not finish then
            current = self:_best_open()
            if yield_each then
                coroutine.yield()
            end
        end
    end
    return self:_trace(finish)
end

local handler = Handler.new()
local astar = AStar.new(handler)

local function shallow_copy(nodes)
    local copy = {}
    for i = 1, #nodes do
        copy[i] = nodes[i]
    end
    return copy
end

local function simplify_nodes(nodes)
    local simplified = shallow_copy(nodes)
    local total = #nodes
    for index = 1, total do
        local node = nodes[index]
        if node and index + 2 <= total then
            local far_node = nodes[index + 2]
            local middle = nodes[index + 1]
            local px = (node.location.x + far_node.location.x) * 0.5
            local py = (node.location.y + far_node.location.y) * 0.5
            local pz = (node.location.z + far_node.location.z) * 0.5
            if math.abs(middle.location.x - px) < 0.1
                and math.abs(middle.location.y - py) < 0.1
                and math.abs(middle.location.z - pz) < 0.1 then
                table.remove(simplified, index)
            end
        end
    end
    return simplified
end

local function to_vec3_list(nodes)
    local points = {}
    for i = 1, #nodes do
        local location = nodes[i].location
        points[i] = v3(location.x, location.y, location.z)
    end
    return points
end

local function reset_debug_nodes()
    good_nodes = {}
    bad_nodes = {}
    handler.node_attempts = 0
end

function M.find_path(from_pos, to_pos)
    if not from_pos or not to_pos then
        return nil
    end
    reset_debug_nodes()
    local path = astar:find_next(
        { x = from_pos.x, y = from_pos.y, z = from_pos.z },
        { x = to_pos.x, y = to_pos.y, z = to_pos.z },
        MAX_SYNC_CHECKS,
        false
    )
    if not path then
        return nil
    end
    local nodes = path:get_nodes()
    local simplified = simplify_nodes(nodes)
    for _ = 1, #nodes do
        simplified = simplify_nodes(simplified)
    end
    local points = to_vec3_list(simplified)
    draw_path = points
    return points
end

local function ensure_pump()
    if pump_hooked then
        return
    end
    pump_hooked = true
    core.register_on_update_callback(function()
        local job = active_job
        if not job then
            return
        end
        local now = core.time()
        if now - job.started > ASYNC_BUDGET_SEC then
            active_job = nil
            job.callback(nil)
            return
        end
        for _ = 1, 10 do
            if not active_job then
                return
            end
            local ok, value = coroutine.resume(job.co)
            if not ok then
                active_job = nil
                core.log_error("A* search failed: " .. tostring(value))
                job.callback(nil)
                return
            end
            if value then
                active_job = nil
                local nodes = value:get_nodes()
                local simplified = simplify_nodes(nodes)
                for _ = 1, #nodes do
                    simplified = simplify_nodes(simplified)
                end
                local points = to_vec3_list(simplified)
                draw_path = points
                job.callback(points)
                return
            end
            if coroutine.status(job.co) == "dead" then
                active_job = nil
                job.callback(nil)
                return
            end
        end
    end)
end

function M.find_path_async(from_pos, to_pos, callback)
    if type(callback) ~= "function" then
        return
    end
    if not from_pos or not to_pos then
        callback(nil)
        return
    end
    if active_job then
        active_job = nil
    end
    reset_debug_nodes()
    ensure_pump()
    local co = coroutine.create(function()
        return astar:find_next(
            { x = from_pos.x, y = from_pos.y, z = from_pos.z },
            { x = to_pos.x, y = to_pos.y, z = to_pos.z },
            MAX_ASYNC_CHECKS,
            true
        )
    end)
    active_job = {
        co = co,
        callback = callback,
        started = core.time(),
    }
end

function M.find_path_from_player(to_pos)
    local x, y, z = player_pos()
    if not x or not to_pos then
        return nil
    end
    return M.find_path(v3(x, y, z), to_pos)
end

function M.fix_path(path)
    if not path or #path == 0 then
        return path
    end
    local last = path[1]
    local fixed = { last }
    for i = 2, #path - 1 do
        local point = path[i]
        if trace(last.x, last.y, last.z + 1, point.x, point.y, point.z + 1, FIX_FLAGS) then
            fixed[#fixed + 1] = point
            last = point
        end
    end
    fixed[#fixed + 1] = path[#path]
    return fixed
end

function M.smooth_path(path)
    if not path or not path[1] then
        return path
    end
    local first = path[1]
    local last = path[#path]
    local result = { v3(first.x, first.y, first.z) }
    for i = 1, #path - 1 do
        local p0 = path[i]
        local p1 = path[i + 1]
        result[#result + 1] = v3(0.75 * p0.x + 0.25 * p1.x, 0.75 * p0.y + 0.25 * p1.y, 0.75 * p0.z + 0.25 * p1.z)
        result[#result + 1] = v3(0.25 * p0.x + 0.75 * p1.x, 0.25 * p0.y + 0.75 * p1.y, 0.25 * p0.z + 0.75 * p1.z)
    end
    result[#result + 1] = v3(last.x, last.y, last.z)
    return result
end

function M.flatten_path(path)
    if not path then
        return path
    end
    for i = 1, #path do
        local point = path[i]
        local gz = ground_z(point.x, point.y, point.z)
        local wz = hit_z(point.x, point.y, point.z + 20, point.z + 1, WATER_FLAGS)
        if wz then
            path[i] = v3(point.x, point.y, wz)
        else
            path[i] = v3(point.x, point.y, gz)
        end
    end
    return path
end

function M.prepare(path)
    return M.flatten_path(M.smooth_path(M.fix_path(path)))
end

local function offset_xy(x, y, facing, angle, reach)
    return x + math.cos(facing + angle) * reach, y + math.sin(facing + angle) * reach
end

function M.is_path_blocked()
    local x, y, z, me = player_pos()
    if not x then
        return false
    end
    local height = me:get_height()
    if not height or height <= 0 then
        height = 2
    end
    local facing = me:get_rotation()
    local reach = 1
    local fx, fy = offset_xy(x, y, facing, 0, reach)
    local sx, sy = offset_xy(x, y, facing, 0, reach / 3)
    local lx, ly = offset_xy(x, y, facing, -1.5708, reach)
    local rx, ry = offset_xy(x, y, facing, 1.5708, reach)
    local flx, fly = offset_xy(fx, fy, facing, -1.5708, reach)
    local frx, fry = offset_xy(fx, fy, facing, 1.5708, reach)
    local probes = {
        { 0, height },
        { height * 0.5, height * 0.5 },
        { height, height },
    }

    local function side_blocked(ax, ay, bx, by)
        for i = 1, #probes do
            local oz = probes[i][1]
            local dz = probes[i][2]
            if trace(ax, ay, z + oz, bx, by, z + dz, COLLISION) then
                return true
            end
        end
        return false
    end

    if side_blocked(x, y, sx, sy) or side_blocked(x, y, fx, fy) then
        return "front"
    end
    if side_blocked(rx, ry, frx, fry) then
        return "right"
    end
    if side_blocked(lx, ly, flx, fly) then
        return "left"
    end
    return false
end

function M.should_jump()
    local x, y, z, me = player_pos()
    if not x then
        return false
    end
    local facing = me:get_rotation()
    local yards = 2
    local max_obs = 0
    for i = 1, 10 do
        local ox = x + (yards / i) * math.cos(facing)
        local oy = y + (yards / i) * math.sin(facing)
        local impact = hit_z(ox, oy, z + 3, z, JUMP_FLAGS)
        if impact and (impact - z) > max_obs then
            max_obs = impact - z
        end
    end
    return max_obs > 0.50
end

function M.hill_angle(a, b)
    local dot = a.x * b.x + a.y * b.y + a.z * b.z
    local mag_a = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    local mag_b = math.sqrt(b.x * b.x + b.y * b.y + b.z * b.z)
    if mag_a == 0 or mag_b == 0 then
        return 0
    end
    return math.acos(dot / (mag_a * mag_b))
end

function M.ground_z(pos)
    if not pos then
        return nil
    end
    return ground_z(pos.x, pos.y, pos.z)
end

local function ensure_render()
    if render_hooked then
        return
    end
    render_hooked = true
    core.register_on_render_callback(function()
        if not debug_enabled then
            return
        end
        local c = colors()
        if not c then
            return
        end
        local line = c.new(80, 180, 255, 255)
        if draw_path and #draw_path > 1 then
            for i = 2, #draw_path do
                local a = draw_path[i - 1]
                local b = draw_path[i]
                local ax = a.x or a.location.x
                local ay = a.y or a.location.y
                local az = a.z or a.location.z
                local bx = b.x or b.location.x
                local by = b.y or b.location.y
                local bz = b.z or b.location.z
                core.graphics.line_3d(v3(ax, ay, az), v3(bx, by, bz), line, 2)
            end
        end
        local bad = c.red(220)
        local good = c.green(220)
        for i = 1, #bad_nodes do
            local location = bad_nodes[i]
            core.graphics.circle_3d(v3(location.x, location.y, location.z), 0.35, bad, 1, 1)
        end
        for i = 1, #good_nodes do
            local location = good_nodes[i]
            core.graphics.circle_3d(v3(location.x, location.y, location.z), 0.35, good, 1, 1)
        end
    end)
end

function M.set_debug(enabled)
    debug_enabled = enabled == true
    if debug_enabled then
        ensure_render()
    end
end

-- ===========================================================================
-- MOVEMENT ENGINE
-- ===========================================================================
-- ONE KEY OWNER AT A TIME.
--   TRAVEL    Sentinel Navigation (_G.SentinelNavClient.client, v0.24) is the
--             only thing that walks. The single lookup in this file is
--             sentinel_client() below. The client is never cached across
--             ticks, and update() / update_config() are never called.
--   PLANNING  HPA* here. It presses no keys. It hands Sentinel a vec3 list.
--   RECOVERY  one short core.input action, and only once Sentinel's own
--             recovery (navigating.recovering.*) is not running.
--   COMBAT    combat/verbs.lua and combat/registry.lua. Facing and the cast
--             pause stay on common/utility/movement_handler.
-- ===========================================================================

local function engine_now()
    local ok, t = pcall(core.time)
    if ok and type(t) == "number" and t == t then
        return t
    end
    return 0
end

M.now = engine_now

--- Distance to the first WALK / SIGHT hit from `from` towards `to`, nil when
--- nothing is hit. native_intersect takes END first, then START.
local function ray(from, to, mask)
    local span = from:dist_to(to)
    if span <= 0 then
        return nil
    end
    if rays_dead then
        return nil
    end
    local ok, hit, _, dist = pcall(core.graphics.native_intersect, to, from, span, mask)
    if not ok then
        ray_threw("native_intersect")
        return nil
    end
    if hit ~= true then
        return nil
    end
    if type(dist) ~= "number" or dist ~= dist or dist > span then
        return span
    end
    return dist
end

--- Free yards from `from` along the horizontal unit direction, capped at `limit`.
local function clearance(from, dirx, diry, limit, mask)
    local d = ray(from, v3(from.x + dirx * limit, from.y + diry * limit, from.z), mask)
    if d == nil or d > limit then
        return limit
    end
    return d
end

M.clearance = clearance

-- Body and probe sizes. CHEST is the trace height the wall probes run at.
local BODY = 0.55
local BODY_HEIGHT = 1.9
local CHEST = 1.1
local WALL_PROBE = 2.2

-- Weight terms, applied only inside the micro search. A macro edge carries the
-- summed weight of the cached border-to-border path instead.
local TAN47 = math.tan(47 * math.pi / 180)
local RAD47 = 47 * math.pi / 180
local STEEP_TERM = 60
local CLIFF_TERM = 400
local CLIFF_DROP = 2.5
local STAIR_RISE = 1.0
local WALL_TERM = 25
local DISK_TERM = 120

-- get_height_for_position starts its ray 2 yards above the z it is given and
-- cannot hit a surface it starts below, so the probe is raised. Indoors it is
-- left low on purpose: a high probe inside a building or a cave hits the floor
-- or the ceiling above the player.
local PROBE_IN = 1.5
local PROBE_OUT = 25

--- Floor height under (x, y), nil when there is none. A miss answers 0, which
--- cannot be told from a real height of 0, so 0 is read as "no floor here".
local function mesh_z(x, y, ref_z)
    if rays_dead then
        return nil
    end
    local up = indoors() and PROBE_IN or PROBE_OUT
    local ok, h = pcall(core.get_height_for_position, v3(x, y, ref_z), { probe_up = up })
    if not ok then
        ray_threw("get_height_for_position")
        return nil
    end
    if type(h) == "number" and h == h and h ~= 0 then
        return h
    end
    return nil
end

M.mesh_z = mesh_z

--- The surface normal's angle away from world up, in radians, read from three
--- floor samples a yard apart. Used by the outdoor steep term when a plain
--- rise over run is not enough (a side slope the path crosses diagonally).
local function slope_angle(x, y, ref_z)
    local c = mesh_z(x, y, ref_z)
    local ex = mesh_z(x + 1, y, ref_z)
    local ey = mesh_z(x, y + 1, ref_z)
    if not c or not ex or not ey then
        return nil
    end
    local a = v3(1, 0, ex - c)
    local b = v3(0, 1, ey - c)
    local n = a:cross(b)
    local len = n:length()
    if len <= 0 then
        return 0
    end
    local up = n.z / len
    if up < 0 then
        up = -up
    end
    return math.acos(up)
end

M.slope_angle = slope_angle

-- ---------------------------------------------------------------------------
-- Blockers: a unit or basic object overlapping a cell makes it impassable.
-- Re-read at most every BLOCK_TTL s, into flat arrays.
-- ---------------------------------------------------------------------------
local BLOCK_TTL = 0.5
local blockers = { t = -1e9, n = 0, x = {}, y = {}, z = {}, r = {} }

local function clear_table(t)
    for k in pairs(t) do
        t[k] = nil
    end
end

local function refresh_blockers()
    local t = engine_now()
    if (t - blockers.t) < BLOCK_TTL then
        return
    end
    blockers.t = t
    clear_table(blockers.x)
    clear_table(blockers.y)
    clear_table(blockers.z)
    clear_table(blockers.r)
    blockers.n = 0

    local my_guid = nil
    local me = player()
    if me then
        local okv, valid = pcall(me.is_valid, me)
        if okv and valid == true then
            local okg, g = pcall(me.get_guid, me)
            if okg and type(g) == "string" then
                my_guid = g
            end
        end
    end

    local ok, list = pcall(core.object_manager.get_visible_objects)
    if not ok or type(list) ~= "table" then
        return
    end
    for i = 1, #list do
        local o = list[i]
        local okv, valid = pcall(o.is_valid, o)
        if okv and valid == true then
            local okg, g = pcall(o.get_guid, o)
            local mine = okg and my_guid ~= nil and g == my_guid
            local okd, dead = pcall(o.is_dead, o)
            if not mine and not (okd and dead == true) then
                local okp, p = pcall(o.get_position, o)
                if okp and p and type(p.x) == "number" then
                    local okr, r = pcall(o.get_bounding_radius, o)
                    local n = blockers.n + 1
                    blockers.n = n
                    blockers.x[n], blockers.y[n], blockers.z[n] = p.x, p.y, p.z
                    blockers.r[n] = (okr and type(r) == "number" and r > 0.05) and r or 0.5
                end
            end
        end
    end
end

--- Horizontal distance under body plus bounding radius, on the same floor.
local function occupied(x, y, z)
    refresh_blockers()
    for i = 1, blockers.n do
        local dz = blockers.z[i] - z
        if dz < 0 then
            dz = -dz
        end
        if dz <= BODY_HEIGHT then
            local dx = blockers.x[i] - x
            local dy = blockers.y[i] - y
            local reach = BODY + blockers.r[i]
            if (dx * dx + dy * dy) < (reach * reach) then
                return true
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Stuck disks. A disk adds weight to a step that moves deeper into it and
-- none to a step that moves away from its centre. Runtime data for the
-- current map: dropped on a map change.
-- ---------------------------------------------------------------------------
local disks = { n = 0, x = {}, y = {}, r = {} }

function M.add_stuck_disk(pos, radius)
    if not pos or type(pos.x) ~= "number" then
        return false
    end
    local r = tonumber(radius) or 4
    if r <= 0 then
        return false
    end
    for i = 1, disks.n do
        local dx, dy = disks.x[i] - pos.x, disks.y[i] - pos.y
        if (dx * dx + dy * dy) < 1 then
            if r > disks.r[i] then
                disks.r[i] = r
            end
            return true
        end
    end
    local n = disks.n + 1
    disks.n = n
    disks.x[n], disks.y[n], disks.r[n] = pos.x, pos.y, r
    return true
end

function M.clear_stuck_disks()
    clear_table(disks.x)
    clear_table(disks.y)
    clear_table(disks.r)
    disks.n = 0
end

local function disk_weight(fx, fy, tx, ty)
    local total = 0
    for i = 1, disks.n do
        local r = disks.r[i]
        local tdx, tdy = tx - disks.x[i], ty - disks.y[i]
        local td = math.sqrt(tdx * tdx + tdy * tdy)
        if td < r then
            local fdx, fdy = fx - disks.x[i], fy - disks.y[i]
            local fd = math.sqrt(fdx * fdx + fdy * fdy)
            if td < fd then
                total = total + DISK_TERM * (1 - td / r)
            end
        end
    end
    return total
end

M.disk_weight = disk_weight

-- ===========================================================================
-- TRAVEL OWNER - Sentinel Navigation v0.24
-- ===========================================================================
-- The one lookup in this file. The client is fetched on every use and never
-- held across ticks. update() and update_config() are never called: the
-- launcher owns the server URL and the map set.
-- ---------------------------------------------------------------------------
local client_provider = nil

--- A product that already owns the client (its own movement/sentinel.lua
--- adapter) lends it here, and this file stops looking the global up at all.
--- fn() returns the client, or nil.
function M.set_client_provider(fn)
    client_provider = (type(fn) == "function") and fn or nil
end

local function sentinel_client()
    if client_provider then
        local ok, c = pcall(client_provider)
        if ok and type(c) == "table" and type(c.move_to) == "function" then
            return c
        end
        return nil
    end
    local s = rawget(_G, "SentinelNavClient")
    local c = type(s) == "table" and s.client or nil
    if type(c) == "table" and type(c.move_to) == "function" then
        return c
    end
    return nil
end

local nav_said_why = false

--- Why the engine will not walk, or nil when it will. MASTER_FARMER is a
--- product-env global and is read as a plain global, never with rawget.
local function nav_refusal()
    if sentinel_client() == nil then
        return "Sentinel Navigation is not loaded"
    end
    local mf = MASTER_FARMER
    if type(mf) == "table" and type(mf.nav) == "table" and mf.nav.supported == false then
        return "Sentinel Navigation does not support this map"
    end
    return nil
end

local function nav_client()
    local why = nav_refusal()
    if why then
        if not nav_said_why then
            nav_said_why = true
            pcall(core.log_warning, "movement engine: not walking - " .. why)
        end
        return nil
    end
    nav_said_why = false
    return sentinel_client()
end

M.nav_refusal = nav_refusal

-- Every walk carries a token. A replaced or stopped walk never fires its
-- callback on v0.24, so the token is what tells a live arrival from a dead one.
local TRAVEL_MIN_AGE = 1.0
local walk_provider = nil

--- A product whose own travel layer owns the walk token, the retarget gaps and
--- the failure bookkeeping (its movement/nav.lua) lends its walk here, and
--- this file stops calling the client to move. fn(kind, target, cb) with kind
--- "to" | "direct" | "path" | "route" returns true when the walk was accepted.
--- The engine still carries its own token, so a replaced walk's callback is
--- still retired.
function M.set_walk_provider(fn)
    walk_provider = (type(fn) == "function") and fn or nil
end
local walk = { token = 0, t0 = -1e9, goal = nil, owner = nil }

local function walk_state()
    local c = sentinel_client()
    if not c then
        return "idle"
    end
    local ok, s = pcall(c.get_state, c)
    if ok and type(s) == "string" then
        return s
    end
    return "idle"
end

local function walk_full_state()
    local c = sentinel_client()
    if not c then
        return ""
    end
    local ok, s = pcall(c.get_full_state, c)
    if ok and type(s) == "string" then
        return s
    end
    return ""
end

M.travel_state = walk_state
M.travel_full_state = walk_full_state

function M.travel_moving()
    local c = sentinel_client()
    if not c then
        return false
    end
    local ok, moving = pcall(c.is_moving, c)
    return ok and moving == true
end

function M.travel_age()
    return engine_now() - walk.t0
end

function M.travel_destination()
    local c = sentinel_client()
    if not c then
        return nil
    end
    local ok, d = pcall(c.get_destination, c)
    if ok and type(d) == "table" and type(d.x) == "number" then
        return d
    end
    return nil
end

function M.travel_path()
    local c = sentinel_client()
    if not c then
        return nil
    end
    local ok, p = pcall(c.get_current_path, c)
    if ok and type(p) == "table" then
        return p
    end
    return nil
end

function M.travel_index()
    local c = sentinel_client()
    if not c then
        return 0
    end
    local ok, i = pcall(c.get_path_index, c)
    if ok and type(i) == "number" then
        return i
    end
    return 0
end

function M.travel_progress()
    local c = sentinel_client()
    if not c then
        return nil
    end
    local ok, p = pcall(c.get_progress, c)
    if ok and type(p) == "table" then
        return p
    end
    return nil
end

function M.travel_server_up()
    local c = sentinel_client()
    if not c then
        return false
    end
    local ok, up = pcall(c.is_server_available, c)
    return ok and up == true
end

function M.travel_health_check(cb)
    local c = nav_client()
    if not c then
        if cb then
            cb(false)
        end
        return false
    end
    local ok = pcall(c.health_check, c, function(up)
        if cb then
            cb(up == true)
        end
    end)
    return ok
end

--- True while Sentinel is running its own recovery. The keys are its to press
--- then, so nothing here touches them.
local function sentinel_recovering()
    local s = walk_full_state()
    if s == "" then
        return false
    end
    if string.find(s, "recovering", 1, true) then
        return true
    end
    return false
end

M.travel_recovering = sentinel_recovering

local function awaiting_path()
    return string.find(walk_full_state(), "awaiting_path", 1, true) ~= nil
end

M.travel_awaiting_path = awaiting_path

--- A walk is only ever stopped once it is older than about a second and not
--- awaiting its path. Stopping bumps the token, so the stopped walk's
--- callback - which v0.24 never fires anyway - can no longer be mistaken for
--- an arrival.
function M.travel_can_stop()
    if not M.travel_moving() then
        return true
    end
    if awaiting_path() then
        return false
    end
    return M.travel_age() >= TRAVEL_MIN_AGE
end

local stop_provider = nil

--- Paired with set_walk_provider: fn(reason) stops that layer's walk. Without
--- one, a provider's walk is left to its own layer to end and only the token is
--- retired here.
function M.set_stop_provider(fn)
    stop_provider = (type(fn) == "function") and fn or nil
end

function M.travel_stop(reason)
    local c = sentinel_client()
    walk.token = walk.token + 1
    walk.goal, walk.owner = nil, nil
    if walk_provider then
        if stop_provider then
            local ok, done = pcall(stop_provider, reason)
            return ok and done ~= false
        end
        return true
    end
    if not c then
        return false
    end
    local ok = pcall(c.stop, c)
    if ok and reason then
        pcall(core.log, "movement engine: stop (" .. tostring(reason) .. ")")
    end
    return ok
end

function M.travel_replan(reason)
    local c = nav_client()
    if not c then
        return false
    end
    return pcall(c.replan, c, reason) == true
end

--- Issue a walk under a fresh token. `kind` is "to", "direct", "path" or
--- "route". `cb(ok, reason, data)` only fires for the walk that is still the
--- current one.
local function issue_walk(kind, arg, cb, opts, owner)
    local c = nav_client()
    if not c then
        if cb then
            cb(false, "no_nav")
        end
        return false
    end
    walk.token = walk.token + 1
    local token = walk.token
    walk.t0 = engine_now()
    walk.owner = owner
    if kind == "path" or kind == "route" then
        walk.goal = arg[#arg]
    else
        walk.goal = arg
    end

    local function done(ok, reason, data)
        if token ~= walk.token then
            return
        end
        if cb then
            cb(ok == true, reason, data)
        end
    end

    local sent
    if walk_provider then
        local ok, accepted = pcall(walk_provider, kind, arg, done)
        sent = ok and accepted ~= false
    elseif kind == "path" then
        sent = pcall(c.follow_path, c, arg, done)
    elseif kind == "direct" then
        sent = pcall(c.move_direct, c, arg, done)
    elseif kind == "route" then
        sent = pcall(c.start_route, c, arg, done, opts)
    else
        sent = pcall(c.move_to, c, arg, done, opts)
    end
    if not sent then
        walk.token = walk.token + 1
        if cb then
            cb(false, "refused")
        end
        return false
    end
    return true
end

function M.travel_to(pos, cb, opts)
    if not pos then
        return false
    end
    return issue_walk("to", pos, cb, opts, "travel")
end

function M.travel_direct(pos, cb)
    if not pos then
        return false
    end
    return issue_walk("direct", pos, cb, nil, "travel")
end

function M.travel_follow(points, cb)
    if type(points) ~= "table" or #points == 0 then
        return false
    end
    if #points == 1 then
        return issue_walk("to", points[1], cb, nil, "travel")
    end
    return issue_walk("path", points, cb, nil, "travel")
end

function M.travel_route(nodes, cb, opts)
    if type(nodes) ~= "table" or #nodes == 0 then
        return false
    end
    return issue_walk("route", nodes, cb, opts, "travel")
end

function M.travel_plan_route(nodes, cb, opts)
    local c = nav_client()
    if not c then
        if cb then
            cb(false, nil)
        end
        return false
    end
    return pcall(c.plan_route, c, nodes, cb, opts) == true
end

function M.travel_validate(pos, cb)
    local c = nav_client()
    if not c then
        if cb then
            cb(false, "no_nav")
        end
        return false
    end
    return pcall(c.validate_destination, c, pos, cb) == true
end

-- ---------------------------------------------------------------------------
-- Mesh heights. get_height answers (true, { height = N }, nil) - a table, not
-- a number. get_all_heights answers (true, { count, heights = { { height,
-- flags }, ... } }, nil); for a far or multi-floor target the height closest
-- to the requested z is the one to keep.
-- ---------------------------------------------------------------------------
local function height_from(data)
    if type(data) == "table" and type(data.height) == "number" then
        return data.height
    end
    return nil
end

function M.nav_height(pos, cb)
    local c = nav_client()
    if not c or type(cb) ~= "function" then
        if cb then
            cb(nil)
        end
        return false
    end
    local ok = pcall(c.get_height, c, pos, function(success, data)
        cb(success == true and height_from(data) or nil)
    end)
    if not ok then
        cb(nil)
    end
    return ok
end

function M.nav_player_height(cb)
    local c = nav_client()
    if not c or type(cb) ~= "function" then
        if cb then
            cb(nil)
        end
        return false
    end
    local ok = pcall(c.get_player_height, c, function(success, data)
        cb(success == true and height_from(data) or nil)
    end)
    if not ok then
        cb(nil)
    end
    return ok
end

local function pick_floor(data, want_z)
    if type(data) ~= "table" then
        return nil
    end
    local list = data.heights
    if type(list) ~= "table" then
        return height_from(data)
    end
    local best, gap = nil, nil
    for i = 1, #list do
        local entry = list[i]
        local h = (type(entry) == "table") and entry.height or entry
        if type(h) == "number" and h == h then
            local d = h - want_z
            if d < 0 then
                d = -d
            end
            if gap == nil or d < gap then
                best, gap = h, d
            end
        end
    end
    return best
end

--- The floor nearest `want_z` at this x,y. Asked before a multi-floor exit and
--- before a far walk.
function M.nav_floor_near(pos, want_z, cb, opts)
    local c = nav_client()
    if not c or type(cb) ~= "function" then
        if cb then
            cb(nil)
        end
        return false
    end
    local target_z = tonumber(want_z) or (pos and pos.z) or 0
    local ok = pcall(c.get_all_heights, c, pos, function(success, data)
        cb(success == true and pick_floor(data, target_z) or nil)
    end, opts)
    if not ok then
        cb(nil)
    end
    return ok
end

function M.nav_player_floors(cb, opts)
    local c = nav_client()
    if not c or type(cb) ~= "function" then
        if cb then
            cb(nil)
        end
        return false
    end
    local ok = pcall(c.get_player_all_heights, c, function(success, data)
        cb(success == true and data or nil)
    end, opts)
    if not ok then
        cb(nil)
    end
    return ok
end

--- Corridor width for Sentinel's current waypoint `index`, or nil. One number
--- per waypoint is that segment's free width; a count that does not match the
--- path is ignored and the traces decide instead.
function M.corridor_width(index)
    local c = sentinel_client()
    if not c then
        return nil
    end
    local okw, widths = pcall(c.get_corridor_widths, c)
    if not okw or type(widths) ~= "table" then
        return nil
    end
    local path = M.travel_path()
    if type(path) ~= "table" or #path ~= #widths then
        return nil
    end
    local w = widths[index]
    if type(w) == "number" and w == w then
        return w
    end
    return nil
end

-- ===========================================================================
-- STUCK RECOVERY - one short key press, never over a Sentinel recovery
-- ===========================================================================
local STUCK_WINDOW = 2.5
local STUCK_YARDS = 0.55
local STUCK_GAP = 3.0
local LIP_MIN, LIP_MAX = 0.5, 1.2
local STRAFE_HOLD = 0.35
local JUMP_HOLD = 0.2
local SIDE_PROBE = 3.0

local stuck = { t = -1e9, x = nil, y = nil, key = nil, until_t = 0, last = -1e9, reissue = nil }
local recovery_on = true

--- Off for a product whose own travel layer already has a stuck ladder (and
--- feeds it into a nav memory the engine has no equivalent for). Two
--- recoveries on one walk is the thing to avoid; a key already down is still
--- released on the next tick.
function M.set_recovery_enabled(on)
    recovery_on = on ~= false
end

function M.recovery_enabled()
    return recovery_on == true
end

local function press(name)
    local f = core.input[name]
    if type(f) == "function" then
        pcall(f)
    end
end

local function release_stuck_key()
    if stuck.key == "left" then
        press("strafe_left_stop")
    elseif stuck.key == "right" then
        press("strafe_right_stop")
    elseif stuck.key == "forward" then
        press("move_forward_stop")
    elseif stuck.key == "back" then
        press("move_backward_stop")
    end
    stuck.key, stuck.until_t = nil, 0
end

M.release_stuck_key = release_stuck_key

--- The rise of the walk mask straight ahead, one yard out. A lip between
--- LIP_MIN and LIP_MAX yards is what a jump clears.
local function lip_ahead(px, py, pz, facing)
    local fx = px + math.cos(facing)
    local fy = py + math.sin(facing)
    local top = hit_z(fx, fy, pz + LIP_MAX + 0.6, pz - 0.2, WALK)
    if not top then
        return nil
    end
    return top - pz
end

local function clearer_side(px, py, pz, facing)
    local eye = v3(px, py, pz + CHEST)
    local lx, ly = math.cos(facing - 1.5708), math.sin(facing - 1.5708)
    local left = clearance(eye, lx, ly, SIDE_PROBE, WALK)
    local right = clearance(eye, -lx, -ly, SIDE_PROBE, WALK)
    if left >= right then
        return "left", left
    end
    return "right", right
end

--- Watched every update. A recovery only ever runs when the walk is in
--- "navigating", older than about a second, not awaiting its path and not
--- already inside Sentinel's own jumping / strafing / probing / backtracking.
local function stuck_tick(t)
    if not recovery_on and not stuck.key then
        return
    end
    if stuck.key then
        if t >= stuck.until_t then
            release_stuck_key()
            local again = stuck.reissue
            stuck.reissue = nil
            if type(again) == "function" then
                again()
            end
        end
        return
    end

    if walk_state() ~= "navigating" then
        stuck.x, stuck.y, stuck.t = nil, nil, t
        return
    end
    if (t - walk.t0) < TRAVEL_MIN_AGE then
        stuck.x, stuck.y, stuck.t = nil, nil, t
        return
    end
    if awaiting_path() or sentinel_recovering() then
        stuck.x, stuck.y, stuck.t = nil, nil, t
        return
    end
    if (t - stuck.last) < STUCK_GAP then
        return
    end

    local px, py, pz, me = player_pos()
    if not px then
        return
    end
    if stuck.x == nil then
        stuck.x, stuck.y, stuck.t = px, py, t
        return
    end
    if (t - stuck.t) < STUCK_WINDOW then
        return
    end

    local dx, dy = px - stuck.x, py - stuck.y
    local moved = math.sqrt(dx * dx + dy * dy)
    stuck.x, stuck.y, stuck.t = px, py, t
    if moved >= STUCK_YARDS then
        return
    end

    -- Stuck. Sentinel is stopped first: a key is never pressed over a running
    -- walk. The walk is re-issued once the key is let go again.
    local goal = walk.goal
    local owner = walk.owner
    stuck.last = t
    M.add_stuck_disk(v3(px, py, pz), 4)
    M.travel_stop("stuck")

    local facing = 0
    local okr, r = pcall(me.get_rotation, me)
    if okr and type(r) == "number" then
        facing = r
    end

    local lip = lip_ahead(px, py, pz, facing)
    if lip and lip >= LIP_MIN and lip <= LIP_MAX then
        press("jump")
        stuck.key, stuck.until_t = "forward", t + JUMP_HOLD
        press("move_forward_start")
    else
        local side = clearer_side(px, py, pz, facing)
        if side == "left" then
            press("strafe_left_start")
            stuck.key = "left"
        else
            press("strafe_right_start")
            stuck.key = "right"
        end
        stuck.until_t = t + STRAFE_HOLD
    end

    if goal then
        stuck.reissue = function()
            if owner == "engine" then
                M.resume_plan()
            else
                M.travel_to(goal, nil)
            end
        end
    end
end

-- ===========================================================================
-- HIERARCHICAL A* (HPA*)
-- ===========================================================================
-- The local planner. It presses no keys: it produces a vec3 list and Sentinel
-- executes it.
--
-- The split exists for memory. The Lua side never allocates a node per yard of
-- a continent. Only the cluster the player is in and the clusters that share
-- its edges hold fine grids; everything else is a handful of border nodes.
--
--     +-------------------+-------------------+
--     |   CLUSTER (0,1)   |   CLUSTER (1,1)   |
--     |   [ Micro-Grid ]  |   [ Micro-Grid ]  |
--     |      . . . .      |      . . . .      |
--     |      . . . . =====|=====> . . . .     |  macro-edge, a clear opening
--     |      . . . .      |      . . . .      |
--     +-------------------+-------------------+
--     |   CLUSTER (0,0)   |   CLUSTER (1,0)   |
--     +-------------------+-------------------+
--
-- A 50 by 50 cluster is 2500 possible cells and not one node object: six flat
-- arrays of numbers, indexed by local_x + local_y * CLUSTER_SIZE, written only
-- where a trace or a search has actually touched.
--
-- The caches are runtime data for the current map. Objects, doors and stuck
-- disks move the openings, so nothing here is ever shipped precompiled, and
-- the whole lot is dropped on a map change or PLAYER_ENTERING_WORLD.
-- ---------------------------------------------------------------------------
local CLUSTER_SIZE = 50
local STRIDE = 8192
local BIAS = 4096

local function cluster_id(x, y)
    local cx = math.floor(x / CLUSTER_SIZE)
    local cy = math.floor(y / CLUSTER_SIZE)
    return (cx + BIAS) * STRIDE + (cy + BIAS)
end

local function cluster_origin(id)
    local cx = math.floor(id / STRIDE) - BIAS
    local cy = id - (cx + BIAS) * STRIDE - BIAS
    return cx * CLUSTER_SIZE, cy * CLUSTER_SIZE
end

M.cluster_id = cluster_id
M.cluster_origin = cluster_origin

local pinned_cluster = nil      -- never freed while its micro search is running
local MAX_LOADED = 5            -- fine grids at once: the active cluster and the four that share its edges
local MAX_CLUSTERS = 96         -- clusters a single request may create at all
local MICRO_BUDGET = 1800       -- cell expansions per micro search
local MACRO_BUDGET = 400        -- border-node expansions per macro search
local YIELD_EVERY = 48

-- A cell's x, y and weight are only stored when they differ from the default
-- the index itself gives: the cell centre, and no wall term. Outdoors that is
-- every cell, so a cluster holds two arrays of numbers (floor and blocked bit)
-- instead of six - measured at 26 bytes a cell against 79.
local clusters = {}             -- id -> cluster (numbers only as keys)
local cluster_count = 0
local borders = {}              -- border node id -> node
local border_seq = 0
local map_id = nil

-- One open table and one closed table for the micro search, and one pair for
-- the macro search, with their two bookkeeping tables each. They are cleared
-- with a pairs loop before a search and never replaced with a fresh {}. The
-- macro search gets its own pair because it calls micro searches while its own
-- open set is still being built - sharing one pair had the macro frontier
-- wiped out from under it.
local S_open = {}
local S_closed = {}
local S_g = {}
local S_from = {}

local Mo_open = {}
local Mo_closed = {}
local Mo_g = {}
local Mo_from = {}

local function clear_search()
    clear_table(S_open)
    clear_table(S_closed)
    clear_table(S_g)
    clear_table(S_from)
end

local function clear_macro_search()
    clear_table(Mo_open)
    clear_table(Mo_closed)
    clear_table(Mo_g)
    clear_table(Mo_from)
end

local function maybe_yield(n)
    if (n % YIELD_EVERY) == 0 and coroutine.running() then
        coroutine.yield()
    end
end

local function cell_index(lx, ly)
    return lx + ly * CLUSTER_SIZE
end

--- blk doubles as the "this cell has been probed" marker: every exit of
--- probe_cell writes it, so there is no separate seen array.
local function cell_known(cl, i)
    return i ~= nil and cl.blk[i] ~= nil
end

local function cell_x(cl, i)
    local v = cl.wx[i]
    if v then
        return v
    end
    return cl.ox + (i % CLUSTER_SIZE) + 0.5
end

local function cell_y(cl, i)
    local v = cl.wy[i]
    if v then
        return v
    end
    return cl.oy + math.floor(i / CLUSTER_SIZE) + 0.5
end

local function cell_weight(cl, i)
    return cl.wt[i] or 0
end

--- Drop a cluster's fine grid. The arrays are REPLACED, not pairs-cleared: a
--- cleared table keeps every byte it ever grew to in LuaJIT (measured: 100%),
--- so clearing an evicted cluster handed nothing back and a long walk piled up
--- one dead grid per cluster crossed. The reused search tables below are a
--- different case and are still cleared in place.
local function free_cells(cl)
    cl.wx, cl.wy, cl.wz, cl.blk, cl.wt = {}, {}, {}, {}, {}
    cl.loaded = false
end

--- Drop every fine grid but the ones nearest the player, keeping the border
--- nodes and the border-to-border costs that were already paid for.
local function trim_loaded(keep_id)
    local px, py = player_pos()
    local loaded = {}
    for id, cl in pairs(clusters) do
        if cl.loaded and id ~= keep_id and id ~= pinned_cluster then
            loaded[#loaded + 1] = cl
        end
    end
    if (#loaded + 1) <= MAX_LOADED then
        return
    end
    local function near(cl)
        if not px then
            return 0
        end
        local dx = (cl.ox + CLUSTER_SIZE * 0.5) - px
        local dy = (cl.oy + CLUSTER_SIZE * 0.5) - py
        return dx * dx + dy * dy
    end
    table.sort(loaded, function(a, b)
        return near(a) > near(b)
    end)
    local over = (#loaded + 1) - MAX_LOADED
    for i = 1, over do
        free_cells(loaded[i])
    end
end

local function get_cluster(id, ref_z, create)
    local cl = clusters[id]
    if cl then
        if not cl.loaded and create then
            cl.loaded = true
            cl.ref_z = ref_z or cl.ref_z
            trim_loaded(id)
        end
        return cl
    end
    if not create or cluster_count >= MAX_CLUSTERS then
        return nil
    end
    local ox, oy = cluster_origin(id)
    cl = {
        id = id, ox = ox, oy = oy, ref_z = ref_z or 0,
        wx = {}, wy = {}, wz = {}, blk = {}, wt = {},
        loaded = true, borders = {}, costs = {}, scanned = {},
    }
    clusters[id] = cl
    cluster_count = cluster_count + 1
    trim_loaded(id)
    return cl
end

--- Put a micro waypoint in the middle of its gap. Indoors the two chest-height
--- traces decide; both sides clear past the probe means no wall term and no
--- shift at all.
local function centre_cell(x, y, z)
    local eye = v3(x, y, z + CHEST)
    local wl = clearance(eye, -1, 0, WALL_PROBE, WALK)
    local wr = clearance(eye, 1, 0, WALL_PROBE, WALK)
    local sl = clearance(eye, 0, -1, WALL_PROBE, WALK)
    local sr = clearance(eye, 0, 1, WALL_PROBE, WALK)
    local near = math.min(wl, wr, sl, sr)
    if near >= WALL_PROBE then
        return x, y, 0
    end
    local px, py = x, y
    local function middle(a, b)
        local shift = (b - a) * 0.5
        local room = (a + b) * 0.5 - BODY
        if room < 0 then
            room = 0
        end
        if shift > room then
            shift = room
        elseif shift < -room then
            shift = -room
        end
        return shift
    end
    if math.min(wl, wr) <= math.min(sl, sr) then
        px = x + middle(wl, wr)
    else
        py = y + middle(sl, sr)
    end
    return px, py, WALL_TERM * (1 - near / WALL_PROBE)
end

--- Write one cell. Returns its flat index, or nil when it is outside the
--- cluster. A cell is only ever written when a trace or a search touches it.
local function probe_cell(cl, lx, ly)
    if lx < 0 or ly < 0 or lx >= CLUSTER_SIZE or ly >= CLUSTER_SIZE then
        return nil
    end
    local i = cell_index(lx, ly)
    if cl.blk[i] ~= nil then
        return i
    end
    local x = cl.ox + lx + 0.5
    local y = cl.oy + ly + 0.5
    local z = mesh_z(x, y, cl.ref_z + 1)
    if z == nil then
        cl.wz[i] = cl.ref_z
        cl.blk[i] = 1
        return i
    end
    -- the body has to fit standing up
    -- deep water: the walkable surface is the top of it, not the bed
    local wz = hit_z(x, y, z + 20, z + 0.5, WATER)
    if wz and (wz - z) > BODY_HEIGHT then
        z = wz
    end
    if trace(x, y, z + 0.2, x, y, z + BODY_HEIGHT, WALK) then
        cl.wz[i] = z
        cl.blk[i] = 1
        return i
    end
    if occupied(x, y, z) then
        cl.wz[i] = z
        cl.blk[i] = 1
        return i
    end
    -- The wall term and the centring are an indoor job: a corridor or a
    -- doorway is where the middle of the gap matters, and outdoors it would
    -- cost four rays a cell for nothing.
    cl.wz[i] = z
    if indoors() then
        local px, py, term = centre_cell(x, y, z)
        -- only the shift and the term are worth a slot; the plain centre and a
        -- zero term are what the index already says
        if px ~= x then
            cl.wx[i] = px
        end
        if py ~= y then
            cl.wy[i] = py
        end
        if term ~= 0 then
            cl.wt[i] = term
        end
    end
    cl.blk[i] = 0
    return i
end

local function passable(cl, i)
    return i ~= nil and cl.blk[i] == 0
end

--- weight = horizontal yards + steep term + cliff term + wall term indoors
---          + stuck-disk term
local function step_cost(cl, i, j, run, inside)
    if cl.blk[j] ~= 0 then
        return nil
    end
    local cost = run
    local dz = cl.wz[j] - cl.wz[i]
    if dz > 0 then
        -- Indoors a stair-sized rise stays cheap: the staircase has to stay
        -- the cheap way up, so Sentinel can be handed it.
        if not (inside and dz <= STAIR_RISE) then
            if (dz / run) > TAN47 then
                cost = cost + STEEP_TERM
            else
                local ang = slope_angle(cell_x(cl, j), cell_y(cl, j), cl.ref_z + 1)
                if ang and ang > RAD47 then
                    cost = cost + STEEP_TERM
                end
            end
        end
    elseif -dz > CLIFF_DROP then
        -- A drop this big, or no floor at all on the far side (that cell is
        -- blocked outright), has to cost more than another opening.
        cost = cost + CLIFF_TERM
    end
    if inside then
        cost = cost + cell_weight(cl, j)
    end
    cost = cost + disk_weight(cell_x(cl, i), cell_y(cl, i), cell_x(cl, j), cell_y(cl, j))
    return cost
end

local NDX = { 1, -1, 0, 0, 1, 1, -1, -1 }
local NDY = { 0, 0, 1, -1, 1, -1, 1, -1 }
local NRUN = { 1, 1, 1, 1, 1.4142136, 1.4142136, 1.4142136, 1.4142136 }

local function octile(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    if dx < 0 then dx = -dx end
    if dy < 0 then dy = -dy end
    if dx > dy then
        return dx + 0.4142136 * dy
    end
    return dy + 0.4142136 * dx
end

--- Micro A* inside one cluster. Returns the list of cell indices from `si` to
--- `gi`, and the path's summed weight.
local function micro_search(cl, si, gi, budget)
    if si == nil or gi == nil then
        return nil
    end
    if not passable(cl, si) or not passable(cl, gi) then
        return nil
    end
    clear_search()
    local was_pinned = pinned_cluster
    pinned_cluster = cl.id
    local gx, gy = gi % CLUSTER_SIZE, math.floor(gi / CLUSTER_SIZE)
    local inside = indoors()
    S_g[si] = 0
    S_open[si] = octile(si % CLUSTER_SIZE, math.floor(si / CLUSTER_SIZE), gx, gy)
    local expanded = 0
    while true do
        local best, bf = nil, nil
        for i, f in pairs(S_open) do
            if bf == nil or f < bf then
                best, bf = i, f
            end
        end
        if best == nil then
            pinned_cluster = was_pinned
            return nil
        end
        if best == gi then
            local cells, n = {}, 0
            local at = gi
            while at do
                n = n + 1
                cells[n] = at
                at = S_from[at]
            end
            local ordered = {}
            for k = n, 1, -1 do
                ordered[n - k + 1] = cells[k]
            end
            pinned_cluster = was_pinned
            return ordered, S_g[gi]
        end
        S_open[best] = nil
        S_closed[best] = true
        expanded = expanded + 1
        if expanded > budget then
            pinned_cluster = was_pinned
            return nil
        end
        maybe_yield(expanded)
        local blx, bly = best % CLUSTER_SIZE, math.floor(best / CLUSTER_SIZE)
        for d = 1, 8 do
            local j = probe_cell(cl, blx + NDX[d], bly + NDY[d])
            if j and not S_closed[j] then
                local c = step_cost(cl, best, j, NRUN[d], inside)
                if c then
                    local g = S_g[best] + c
                    if S_g[j] == nil or g < S_g[j] then
                        S_g[j], S_from[j] = g, best
                        S_open[j] = g + octile(blx + NDX[d], bly + NDY[d], gx, gy)
                    end
                end
            end
        end
    end
end

local function world_cell(cl, x, y)
    local lx = math.floor(x - cl.ox)
    local ly = math.floor(y - cl.oy)
    if lx < 0 then lx = 0 elseif lx >= CLUSTER_SIZE then lx = CLUSTER_SIZE - 1 end
    if ly < 0 then ly = 0 elseif ly >= CLUSTER_SIZE then ly = CLUSTER_SIZE - 1 end
    return probe_cell(cl, lx, ly)
end

--- The nearest passable cell to (x, y) inside `cl`, searched outwards in
--- rings. A player standing in a doorway can read as blocked by its own
--- neighbours; this is what keeps the search from refusing to start.
local function nearest_open_cell(cl, x, y)
    local i = world_cell(cl, x, y)
    if passable(cl, i) then
        return i
    end
    local lx = math.floor(x - cl.ox)
    local ly = math.floor(y - cl.oy)
    for r = 1, 6 do
        for dx = -r, r do
            for dy = -r, r do
                if dx == -r or dx == r or dy == -r or dy == r then
                    local j = probe_cell(cl, lx + dx, ly + dy)
                    if passable(cl, j) then
                        return j
                    end
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Macro graph: border nodes at the clear openings of a shared cluster edge
-- ---------------------------------------------------------------------------
local OPPOSITE = { north = "south", south = "north", east = "west", west = "east" }

local function add_border(a, b, edge, x, y, z)
    border_seq = border_seq + 1
    local node = {
        id = border_seq, x = x, y = y, z = z,
        cluster = a.id, other = b.id, edge = edge,
    }
    borders[node.id] = node
    a.borders[#a.borders + 1] = node.id
    b.borders[#b.borders + 1] = node.id
    return node
end

--- Scan the edge `a` shares with `b` with the walk mask and the slope test.
--- Each run of clear yards becomes one border node at the opening's midpoint.
local function scan_edge(a, b, edge)
    if a.scanned[edge] then
        return
    end
    a.scanned[edge] = true
    b.scanned[OPPOSITE[edge]] = true

    local run_from = nil
    local last = CLUSTER_SIZE - 1
    for k = 0, last do
        local ia, ib
        if edge == "east" then
            ia = probe_cell(a, CLUSTER_SIZE - 1, k)
            ib = probe_cell(b, 0, k)
        elseif edge == "west" then
            ia = probe_cell(a, 0, k)
            ib = probe_cell(b, CLUSTER_SIZE - 1, k)
        elseif edge == "north" then
            ia = probe_cell(a, k, CLUSTER_SIZE - 1)
            ib = probe_cell(b, k, 0)
        else
            ia = probe_cell(a, k, 0)
            ib = probe_cell(b, k, CLUSTER_SIZE - 1)
        end

        local open = passable(a, ia) and passable(b, ib)
        if open then
            -- the step across has to be clear at chest height, and not a cliff
            local dz = b.wz[ib] - a.wz[ia]
            if dz > CLIFF_DROP or -dz > CLIFF_DROP then
                open = false
            elseif trace(cell_x(a, ia), cell_y(a, ia), a.wz[ia] + CHEST,
                         cell_x(b, ib), cell_y(b, ib), b.wz[ib] + CHEST, WALK) then
                open = false
            end
        end

        if open then
            if run_from == nil then
                run_from = k
            end
        end
        if (not open or k == last) and run_from ~= nil then
            local run_to = open and k or (k - 1)
            local mid = math.floor((run_from + run_to) * 0.5)
            local ja, jb
            if edge == "east" then
                ja, jb = probe_cell(a, CLUSTER_SIZE - 1, mid), probe_cell(b, 0, mid)
            elseif edge == "west" then
                ja, jb = probe_cell(a, 0, mid), probe_cell(b, CLUSTER_SIZE - 1, mid)
            elseif edge == "north" then
                ja, jb = probe_cell(a, mid, CLUSTER_SIZE - 1), probe_cell(b, mid, 0)
            else
                ja, jb = probe_cell(a, mid, 0), probe_cell(b, mid, CLUSTER_SIZE - 1)
            end
            if passable(a, ja) and passable(b, jb) then
                add_border(a, b, edge,
                    (cell_x(a, ja) + cell_x(b, jb)) * 0.5,
                    (cell_y(a, ja) + cell_y(b, jb)) * 0.5,
                    (a.wz[ja] + b.wz[jb]) * 0.5)
            end
            run_from = nil
        end
    end
end

local NEIGHBOUR_EDGE = { "east", "west", "north", "south" }
local NEIGHBOUR_DX = { 1, -1, 0, 0 }
local NEIGHBOUR_DY = { 0, 0, 1, -1 }

--- Load the four clusters that share an edge with `cl` and scan those edges.
local function open_edges(cl)
    local cx = math.floor(cl.id / STRIDE) - BIAS
    local cy = cl.id - (cx + BIAS) * STRIDE - BIAS
    for d = 1, 4 do
        local nid = (cx + NEIGHBOUR_DX[d] + BIAS) * STRIDE + (cy + NEIGHBOUR_DY[d] + BIAS)
        local nb = get_cluster(nid, cl.ref_z, true)
        if nb then
            if not nb.loaded then
                nb.loaded = true
            end
            scan_edge(cl, nb, NEIGHBOUR_EDGE[d])
        end
    end
end

--- Border-to-border costs inside one cluster, paid once with the micro search
--- and kept on the cluster. The global search never sees a floor tile.
local function border_costs(cl)
    local list = cl.borders
    for a = 1, #list do
        local ida = list[a]
        local from = borders[ida]
        local row = cl.costs[ida]
        if row == nil then
            row = {}
            cl.costs[ida] = row
        end
        for b = 1, #list do
            local idb = list[b]
            if idb ~= ida and row[idb] == nil then
                local to = borders[idb]
                local si = nearest_open_cell(cl, from.x, from.y)
                local gi = nearest_open_cell(cl, to.x, to.y)
                local _, cost = micro_search(cl, si, gi, MICRO_BUDGET)
                row[idb] = cost or false
                local other = cl.costs[idb]
                if other == nil then
                    other = {}
                    cl.costs[idb] = other
                end
                other[ida] = cost or false
            end
        end
    end
end

--- A* over border nodes only. The open set here is a few dozen nodes, not the
--- map. Returns the border-node id sequence from the player's cluster to the
--- destination's.
local function macro_search(start_cluster, dest_cluster, from_x, from_y, dest)
    clear_macro_search()
    local start = get_cluster(start_cluster, dest.z, true)
    if not start then
        return nil
    end
    open_edges(start)
    border_costs(start)

    local function heur(node)
        local dx, dy = dest.x - node.x, dest.y - node.y
        return math.sqrt(dx * dx + dy * dy)
    end

    local si = nearest_open_cell(start, from_x, from_y)
    local seeded = false
    for k = 1, #start.borders do
        local id = start.borders[k]
        local node = borders[id]
        local gi = nearest_open_cell(start, node.x, node.y)
        local _, cost = micro_search(start, si, gi, MICRO_BUDGET)
        if cost then
            Mo_g[id] = cost
            Mo_open[id] = cost + heur(node)
            seeded = true
        end
    end
    if not seeded then
        return nil
    end

    local expanded = 0
    while true do
        local best, bf = nil, nil
        for id, f in pairs(Mo_open) do
            if bf == nil or f < bf then
                best, bf = id, f
            end
        end
        if best == nil then
            return nil
        end
        local node = borders[best]
        if node and (node.cluster == dest_cluster or node.other == dest_cluster) then
            local seq, n = {}, 0
            local at = best
            while at do
                n = n + 1
                seq[n] = at
                at = Mo_from[at]
            end
            local ordered = {}
            for k = n, 1, -1 do
                ordered[n - k + 1] = seq[k]
            end
            return ordered
        end
        Mo_open[best] = nil
        Mo_closed[best] = true
        expanded = expanded + 1
        if expanded > MACRO_BUDGET then
            return nil
        end
        maybe_yield(expanded)

        -- A node the caches dropped is simply closed and not expanded.
        if node then
            for side = 1, 2 do
                local cid = (side == 1) and node.cluster or node.other
                local cl = get_cluster(cid, node.z, true)
                if cl then
                    if #cl.borders == 0 or cl.costs[best] == nil then
                        open_edges(cl)
                        border_costs(cl)
                    end
                    local row = cl.costs[best]
                    if row then
                        for id, cost in pairs(row) do
                            if cost and not Mo_closed[id] and borders[id] then
                                local g = Mo_g[best] + cost
                                if Mo_g[id] == nil or g < Mo_g[id] then
                                    Mo_g[id], Mo_from[id] = g, best
                                    Mo_open[id] = g + heur(borders[id])
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The map's caches are runtime data. A map change or PLAYER_ENTERING_WORLD
-- drops the macro nodes, the border costs, the micro pool and the stuck disks.
-- ---------------------------------------------------------------------------
local function reset_caches(why)
    clear_table(clusters)
    clear_table(borders)
    pinned_cluster = nil
    cluster_count = 0
    border_seq = 0
    M.clear_stuck_disks()
    -- A map change is the one moment the search tables are REPLACED rather
    -- than cleared in place. Clearing keeps their high-water capacity for the
    -- session (measured: a pairs-clear hands back 0%), and the point of this
    -- function is to give the map's memory back. Between searches they are
    -- still reused, which is what keeps a search from churning allocations.
    S_open, S_closed, S_g, S_from = {}, {}, {}, {}
    Mo_open, Mo_closed, Mo_g, Mo_from = {}, {}, {}, {}
    if why then
        pcall(core.log, "movement engine: caches dropped (" .. tostring(why) .. ")")
    end
end

M.reset_caches = reset_caches

-- ===========================================================================
-- PIPELINE - local entry, macro, local exit streamed
-- ===========================================================================
-- 1. Local entry: micro A* from the player to the cheapest border node of the
--    current cluster that reduces the remaining macro cost. A destination
--    inside the same cluster skips the macro step and micro-searches straight
--    to it.
-- 2. Macro: A* over border nodes only, from that entrance to a border node of
--    the cluster that holds the destination.
-- 3. Local exit, streamed: only the cluster the player is standing in gets a
--    micro path. Crossing into the next cluster clears the finished micro
--    arrays with a pairs loop - the pool table itself is kept - resolves the
--    new entrance-to-exit path and issues the next walk under a new token.
-- ---------------------------------------------------------------------------
local PLAN_BUDGET = 2.5         -- s a single plan may spend across frames
local FRAME_SLICE = 6           -- coroutine resumes per update
local LEG_SPAN = 1              -- a leg of this many points is a move_to, not a follow_path
local SIMPLIFY_TOL = 0.35
local FLOOR_ASK_DZ = 3.0
local FLOOR_WAIT = 1.5
local REPATH_EVERY = 0.75
local REPATH_LOOK = 6

local plan = nil

local function plan_fail(reason)
    local cb = plan and plan.cb or nil
    local hand_over = plan and plan.plan_only or nil
    plan = nil
    if not hand_over then
        M.travel_stop(nil)
    end
    if hand_over then
        hand_over(nil, reason)
    end
    if cb then
        cb(false, reason)
    end
end

local function plan_done()
    local cb = plan and plan.cb or nil
    plan = nil
    if cb then
        cb(true, nil, { code = "arrived" })
    end
end

local function cells_to_points(cl, cells)
    local raw, n = {}, 0
    local last2 = nil
    for k = 1, #cells do
        local i = cells[k]
        local here = vec2.new(cell_x(cl, i), cell_y(cl, i))
        -- two cells that centred onto the same spot are one waypoint
        if last2 == nil or here:squared_dist_to(last2) > 0.04 then
            n = n + 1
            raw[n] = v3(cell_x(cl, i), cell_y(cl, i), cl.wz[i])
            last2 = here
        end
    end
    if #raw <= 2 then
        return raw
    end
    local out = { raw[1] }
    local anchor = raw[1]
    for k = 2, #raw - 1 do
        local point = raw[k]
        local next_point = raw[k + 1]
        if point:dist_to_line_segment(anchor, next_point) > SIMPLIFY_TOL then
            out[#out + 1] = point
            anchor = point
        end
    end
    out[#out + 1] = raw[#raw]
    return out
end

--- Issue the leg. A single span is a move_to; anything longer is a follow_path.
local function walk_leg(points, final)
    if type(points) ~= "table" or #points == 0 then
        plan_fail("empty_leg")
        return
    end
    plan.leg = points
    plan.leg_t = engine_now()
    local function arrived(ok, reason)
        if not plan then
            return
        end
        if not ok then
            plan_fail(reason or "walk_failed")
            return
        end
        if final then
            plan_done()
        else
            plan.need_leg = true
        end
    end
    local sent
    if #points <= LEG_SPAN then
        sent = issue_walk("to", points[#points], arrived, nil, "engine")
    else
        sent = issue_walk("path", points, arrived, nil, "engine")
    end
    if not sent then
        plan_fail("nav_refused")
    end
end

--- Build the micro path for the cluster the player is standing in. Returns the
--- point list and whether it ends at the destination. Runs inside the plan
--- coroutine, so the micro search may yield.
local function build_leg()
    local px, py, pz = player_pos()
    if not px then
        return nil, false, "no_player"
    end
    local cid = cluster_id(px, py)
    local cl = get_cluster(cid, pz, true)
    if not cl then
        return nil, false, "cluster_budget"
    end
    plan.cluster = cid
    if not cl.loaded then
        cl.loaded = true
    end
    local si = nearest_open_cell(cl, px, py)
    if si == nil then
        return nil, false, "no_start_cell"
    end

    -- the destination is in this cluster: no macro step at all
    if cluster_id(plan.dest.x, plan.dest.y) == cid then
        local gi = nearest_open_cell(cl, plan.dest.x, plan.dest.y)
        if gi == nil then
            return nil, false, "no_goal_cell"
        end
        local cells = micro_search(cl, si, gi, MICRO_BUDGET)
        if not cells then
            return nil, false, "no_micro_path"
        end
        local points = cells_to_points(cl, cells)
        points[#points] = v3(plan.dest.x, plan.dest.y, plan.dest.z)
        return points, true, nil
    end

    -- otherwise: the next border node of the macro plan that this cluster owns
    local seq = plan.seq
    if type(seq) ~= "table" then
        return nil, false, "no_macro_plan"
    end
    local pick = nil
    for k = plan.i, #seq do
        local node = borders[seq[k]]
        if node and (node.cluster == cid or node.other == cid) then
            pick = k
        elseif pick then
            break
        end
    end
    if pick == nil then
        return nil, false, "off_plan"
    end
    plan.i = pick + 1
    local node = borders[seq[pick]]
    local gi = nearest_open_cell(cl, node.x, node.y)
    if gi == nil then
        return nil, false, "no_exit_cell"
    end
    local cells = micro_search(cl, si, gi, MICRO_BUDGET)
    if not cells then
        return nil, false, "no_micro_path"
    end
    local points = cells_to_points(cl, cells)
    -- a yard past the opening, so the walk really crosses into the neighbour
    local last = points[#points]
    local dx, dy = last.x - px, last.y - py
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 0.1 then
        points[#points + 1] = v3(last.x + dx / len, last.y + dy / len, last.z)
    end
    return points, false, nil
end

--- Before a multi-floor exit the floor nearest the target z is the one to
--- keep, so the last point is asked for over the mesh. One ask, with its own
--- timeout: a lost answer must not hold the plan for good.
local function issue_with_floor(points, final)
    local last = points[#points]
    local _, _, pz = player_pos()
    local dz = (pz and (last.z - pz)) or 0
    if dz < 0 then
        dz = -dz
    end
    if dz < FLOOR_ASK_DZ then
        walk_leg(points, final)
        return
    end
    plan.floor_wait = engine_now() + FLOOR_WAIT
    plan.floor_points, plan.floor_final = points, final
    M.nav_floor_near(last, last.z, function(z)
        if not plan or not plan.floor_points then
            return
        end
        local list = plan.floor_points
        local was_final = plan.floor_final
        plan.floor_points, plan.floor_final, plan.floor_wait = nil, nil, nil
        if type(z) == "number" then
            list[#list] = v3(last.x, last.y, z)
        end
        walk_leg(list, was_final)
    end)
end

local function start_leg_job()
    plan.need_leg = false
    plan.started = engine_now()
    plan.co = coroutine.create(function()
        return build_leg()
    end)
end

--- Plan a route to `dest` with HPA* and have Sentinel walk it.
function M.travel(dest, cb)
    if not dest or type(dest.x) ~= "number" then
        if cb then
            cb(false, "no_dest")
        end
        return false
    end
    local why = nav_refusal()
    if why then
        nav_client()                -- says why, once
        if cb then
            cb(false, "no_nav")
        end
        return false
    end
    local px, py, pz = player_pos()
    if not px then
        if cb then
            cb(false, "no_player")
        end
        return false
    end
    M.ensure_engine()
    -- A second walk while one is running re-plans in about 0.12 s, so the old
    -- one is not stopped here: issue_walk's token bump is what retires the
    -- replaced walk, whose callback v0.24 never fires anyway.
    plan = {
        dest = v3(dest.x, dest.y, dest.z),
        cb = cb, i = 1, seq = nil, cluster = nil,
        need_leg = false, started = engine_now(), t0 = engine_now(),
    }
    local from_x, from_y = px, py
    local start_cid = cluster_id(px, py)
    local dest_cid = cluster_id(dest.x, dest.y)
    plan.co = coroutine.create(function()
        if start_cid ~= dest_cid then
            local seq = macro_search(start_cid, dest_cid, from_x, from_y, plan.dest)
            if not seq then
                return nil, false, "no_macro_path"
            end
            plan.seq = seq
        end
        return build_leg()
    end)
    return true
end

--- Plan the path to `dest` and hand the point list over WITHOUT walking it.
--- For a product whose own travel layer owns the walk token and the legs (its
--- movement/nav.lua): the engine plans, that layer walks. One leg of the
--- current cluster, which for a short off-mesh goal is the whole path.
--- cb(points) on success, cb(nil, why) otherwise.
function M.plan_only(dest, cb)
    if type(cb) ~= "function" then
        return false
    end
    if not dest or type(dest.x) ~= "number" then
        cb(nil, "no_dest")
        return false
    end
    local px, py, pz = player_pos()
    if not px then
        cb(nil, "no_player")
        return false
    end
    M.ensure_engine()
    if plan then
        cb(nil, "busy")
        return false
    end
    plan = {
        dest = v3(dest.x, dest.y, dest.z),
        cb = nil, i = 1, seq = nil, cluster = nil, plan_only = cb,
        need_leg = false, started = engine_now(), t0 = engine_now(),
    }
    local from_x, from_y = px, py
    local start_cid = cluster_id(px, py)
    local dest_cid = cluster_id(dest.x, dest.y)
    plan.co = coroutine.create(function()
        if start_cid ~= dest_cid then
            local seq = macro_search(start_cid, dest_cid, from_x, from_y, plan.dest)
            if not seq then
                return nil, false, "no_macro_path"
            end
            plan.seq = seq
        end
        return build_leg()
    end)
    return true
end

--- Re-issue the current leg after a stuck recovery.
function M.resume_plan()
    if not plan then
        return false
    end
    plan.need_leg = true
    return true
end

function M.is_travelling()
    return plan ~= nil
end

function M.cancel(reason)
    if not plan then
        return false
    end
    local cb = plan.cb
    local hand_over = plan.plan_only
    plan = nil
    if not hand_over then
        M.travel_stop(reason or "cancelled")
    end
    release_stuck_key()
    if hand_over then
        hand_over(nil, "cancelled")
    end
    if cb then
        cb(false, "cancelled")
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Outdoor repath watch: a short timer samples the next yards of
-- get_current_path() and rebuilds when an upcoming segment's weight crosses
-- the cliff or the steep term. Never during awaiting_path, never inside the
-- first second of a walk.
-- ---------------------------------------------------------------------------
local function segment_is_bad(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local run = math.sqrt(dx * dx + dy * dy)
    if run < 0.5 then
        return false
    end
    local _, _, pz = player_pos()
    local ref = pz or a.z
    local za = mesh_z(a.x, a.y, ref + 1) or a.z
    local steps = math.floor(run)
    if steps > 8 then
        steps = 8
    end
    for s = 1, steps do
        local f = s / steps
        local x, y = a.x + dx * f, a.y + dy * f
        local z = mesh_z(x, y, ref + 1)
        if z == nil then
            return true                       -- no floor on the far side
        end
        local dz = z - za
        if -dz > CLIFF_DROP then
            return true
        end
        if dz > 0 and (dz / (run / steps)) > TAN47 then
            return true
        end
        za = z
    end
    return false
end

local function repath_tick(t)
    if not plan or plan.co or plan.need_leg or plan.floor_points then
        return
    end
    if (t - (plan.repath_t or 0)) < REPATH_EVERY then
        return
    end
    plan.repath_t = t
    if indoors() then
        return
    end
    if walk_state() ~= "navigating" then
        return
    end
    if awaiting_path() or sentinel_recovering() then
        return
    end
    if (t - walk.t0) < TRAVEL_MIN_AGE then
        return
    end
    local path = M.travel_path()
    if type(path) ~= "table" or #path < 2 then
        return
    end
    local from = M.travel_index()
    if from < 1 then
        from = 1
    end
    local last = from + REPATH_LOOK
    if last > #path then
        last = #path
    end
    for k = from, last - 1 do
        local a, b = path[k], path[k + 1]
        if type(a) == "table" and type(b) == "table" then
            local tight = M.corridor_width(k + 1)
            if segment_is_bad(a, b) or (tight and tight < BODY * 2) then
                M.travel_stop("repath")
                plan.need_leg = true
                return
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The update pump: plan coroutine, cluster streaming, stuck watch, repath.
-- ---------------------------------------------------------------------------
local function plan_tick(t)
    if not plan then
        return
    end

    if plan.floor_points then
        if plan.floor_wait and t > plan.floor_wait then
            local list, final = plan.floor_points, plan.floor_final
            plan.floor_points, plan.floor_final, plan.floor_wait = nil, nil, nil
            walk_leg(list, final)
        end
        return
    end

    if plan.co then
        if (t - plan.started) > PLAN_BUDGET then
            local hand_over = plan.plan_only
            if hand_over then
                plan = nil
                hand_over(nil, "plan_timeout")
            else
                plan_fail("plan_timeout")
            end
            return
        end
        for _ = 1, FRAME_SLICE do
            if not plan or not plan.co then
                return
            end
            local ok, points, final, why = coroutine.resume(plan.co)
            if not ok then
                pcall(core.log_error, "movement engine: plan failed - " .. tostring(points))
                plan_fail("plan_error")
                return
            end
            if coroutine.status(plan.co) == "dead" then
                plan.co = nil
                local hand_over = plan.plan_only
                if hand_over then
                    plan = nil
                    hand_over(type(points) == "table" and points or nil, why)
                    return
                end
                if type(points) ~= "table" then
                    plan_fail(why or "no_path")
                    return
                end
                issue_with_floor(points, final == true)
                return
            end
        end
        return
    end

    -- crossed into the next cluster: free the finished micro arrays and
    -- resolve the new entrance-to-exit path under a new token
    local px, py = player_pos()
    if px and plan.cluster then
        local cid = cluster_id(px, py)
        if cid ~= plan.cluster then
            local old = clusters[plan.cluster]
            if old then
                free_cells(old)
            end
            M.travel_stop(nil)
            plan.cluster = cid
            start_leg_job()
            return
        end
    end

    if plan.need_leg then
        start_leg_job()
        return
    end

    if walk_state() == "failed" then
        plan_fail("sentinel_failed")
    end
end

local engine_hooked = false

function M.ensure_engine()
    if engine_hooked then
        return
    end
    engine_hooked = true
    core.register_on_update_callback(function()
        local t = engine_now()
        local okm, mid = pcall(core.get_map_id)
        if okm and mid ~= nil then
            if map_id == nil then
                map_id = mid
            elseif mid ~= map_id then
                map_id = mid
                if plan then
                    plan_fail("map_changed")
                end
                reset_caches("map " .. tostring(mid))
            end
        end
        stuck_tick(t)
        plan_tick(t)
        repath_tick(t)
    end)
    core.register_on_game_event_callback(function(event_name)
        if event_name == "PLAYER_ENTERING_WORLD" then
            if plan then
                plan_fail("entering_world")
            end
            release_stuck_key()
            reset_caches("PLAYER_ENTERING_WORLD")
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Away points. A backoff, a blink and a flee all need a point to run to; the
-- outdoor cliff and steep terms are what keeps a flee from leaving over a
-- cliff.
-- ---------------------------------------------------------------------------
local AWAY_ARCS = 12
local away_provider = nil

--- A product with its own away-point source (Sentinel's kite / flee on the
--- server, which answers over the real navmesh) lends it here. fn(from,
--- threats, distance, watch) returns a point, or nil to fall through to the
--- local arc scan below.
function M.set_away_point_provider(fn)
    away_provider = (type(fn) == "function") and fn or nil
end

--- A point `distance` yards from `from`, away from every threat, with the
--- walk mask clear, line of sight kept to `watch` when one is given, and the
--- outdoor terms paid. nil when no arc is safe.
function M.pick_away_point(from, threats, distance, watch)
    if not from or type(distance) ~= "number" or distance <= 0 then
        return nil
    end
    if away_provider then
        local ok, point = pcall(away_provider, from, threats, distance, watch)
        if ok and type(point) == "table" and type(point.x) == "number" then
            return point
        end
    end
    local ax, ay = 0, 0
    local n = 0
    if type(threats) == "table" then
        for i = 1, #threats do
            local p = threats[i]
            if type(p) == "table" and type(p.x) == "number" then
                ax = ax + (from.x - p.x)
                ay = ay + (from.y - p.y)
                n = n + 1
            end
        end
    end
    local base
    if n > 0 and (ax * ax + ay * ay) > 0.01 then
        base = math.atan2(ay, ax)
    else
        local me = player()
        base = 0
        if me then
            local okv, valid = pcall(me.is_valid, me)
            if okv and valid == true then
                local okr, r = pcall(me.get_rotation, me)
                if okr and type(r) == "number" then
                    base = r + math.pi
                end
            end
        end
    end

    local best, best_score = nil, nil
    for k = 0, AWAY_ARCS - 1 do
        local spread = (k % 2 == 0) and 1 or -1
        local angle = base + spread * (math.floor(k / 2) * (math.pi / 8))
        local tx = from.x + math.cos(angle) * distance
        local ty = from.y + math.sin(angle) * distance
        local eye = v3(from.x, from.y, from.z + CHEST)
        local free = clearance(eye, math.cos(angle), math.sin(angle), distance, WALK)
        if free >= distance - 0.5 then
            local tz = mesh_z(tx, ty, from.z + 1)
            if tz then
                local drop = from.z - tz
                local score = 0
                if drop > CLIFF_DROP then
                    score = score + CLIFF_TERM
                end
                local ang = slope_angle(tx, ty, from.z + 1)
                if ang and ang > RAD47 then
                    score = score + STEEP_TERM
                end
                score = score + disk_weight(from.x, from.y, tx, ty)
                score = score + math.abs(angle - base) * 2
                local point = v3(tx, ty, tz)
                if watch then
                    local okp, wp = pcall(watch.get_position, watch)
                    if okp and wp then
                        local eyes = v3(point.x, point.y, point.z + CHEST)
                        if ray(eyes, v3(wp.x, wp.y, wp.z + CHEST), SIGHT) then
                            score = score + 150
                        end
                    end
                end
                if best_score == nil or score < best_score then
                    best, best_score = point, score
                end
            end
        end
    end
    return best
end

--- Is the walk mask clear for `yards` in this direction from the player?
function M.step_is_clear(angle, yards)
    local px, py, pz = player_pos()
    if not px then
        return false
    end
    local eye = v3(px, py, pz + CHEST)
    return clearance(eye, math.cos(angle), math.sin(angle), yards, WALK) >= yards - 0.1
end

--- Line of sight to `unit`, SIGHT mask.
function M.has_sight(unit)
    local px, py, pz = player_pos()
    if not px or not unit then
        return false
    end
    local okv, valid = pcall(unit.is_valid, unit)
    if not okv or valid ~= true then
        return false
    end
    local okp, p = pcall(unit.get_position, unit)
    if not okp or not p then
        return false
    end
    return ray(v3(px, py, pz + CHEST), v3(p.x, p.y, p.z + CHEST), SIGHT) == nil
end

-- ---------------------------------------------------------------------------
-- Debug draw: render callback only.
-- ---------------------------------------------------------------------------
local hpa_render_hooked = false

local function ensure_hpa_render()
    if hpa_render_hooked then
        return
    end
    hpa_render_hooked = true
    core.register_on_render_callback(function()
        if not debug_enabled then
            return
        end
        local c = colors()
        if not c then
            return
        end
        local leg = plan and plan.leg or nil
        if leg and #leg > 1 then
            local tint = c.new(255, 200, 60, 255)
            for i = 2, #leg do
                core.graphics.line_3d(leg[i - 1], leg[i], tint, 3)
            end
        end
        local ring = c.new(120, 255, 160, 200)
        for id, node in pairs(borders) do
            if node.x then
                core.graphics.circle_3d(v3(node.x, node.y, node.z), 1.2, ring, 2, 1)
            end
        end
        local disk = c.red(160)
        local _, _, pz = player_pos()
        if pz then
            for i = 1, disks.n do
                core.graphics.circle_3d(v3(disks.x[i], disks.y[i], pz), disks.r[i], disk, 1, 1)
            end
        end
    end)
end

local base_set_debug = M.set_debug

function M.set_debug(enabled)
    base_set_debug(enabled)
    if enabled == true then
        ensure_hpa_render()
    end
end

return M
