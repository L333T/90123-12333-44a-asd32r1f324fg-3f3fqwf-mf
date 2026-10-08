-- ============================================================================
-- AmeisenNav
-- anav/client.lua - public API: _G.AmeisenNav.client
-- ============================================================================
-- Version: 1.5.0
-- Author: BLIZZ
-- ============================================================================
-- STATES   idle -> planning -> navigating -> arrived | failed
--          navigating.recovering.<step> while stuck recovery runs
--
-- CALLBACK cb(success, reason, detail) - once per navigation, never twice.
--          reason is a short message; detail = { code = <code>, detail = <text> }
--          codes: arrived, cancelled, unreachable, start_off_mesh, end_off_mesh,
--                 map_not_loaded, no_path, server_timeout, server_down,
--                 max_stuck_exceeded, max_repath_exceeded, bad_request
--
-- RECOVERY (on "stuck", level rises until real progress is made)
--          1 jump   2 repath   3 detour to a random nearby mesh point
--          4 back off, then repath   5 jump + repath   > C.max_stuck: fail
-- ============================================================================

---@type vec3
local vec3 = require("common/geometry/vector_3")

local C = require("anav/config")
local L = require("anav/log")
local T = require("anav/transport")
local X = require("anav/context")
local Q = require("anav/query")
local F = require("anav/follower")
local PC = require("anav/pathcheck")    -- 1.5.0: 5-yard waypoints, height / width checks ahead

local M = {}
M.__index = M

local fmt = string.format
local sqrt = math.sqrt

local function now() return core.time() end

local function player_point()
    local x, y, z = X.position()
    if not x then return nil end
    return { x = x, y = y, z = z }
end

local function as_point(p)
    local x, y, z = Q.xyz(p)
    if not x then return nil end
    return { x = x, y = y, z = z }
end

-- ============================================================================
-- construction / events
-- ============================================================================
function M.new()
    local self = setmetatable({}, M)
    self.state = "idle"
    self.sub = nil               -- recovery step name while recovering
    self.nav = nil               -- the active navigation record
    self.nav_id = 0
    self.listeners = {}          -- event -> { id -> fn }
    self.next_listener = 0
    self.last_path = nil         -- last path walked, for drawing after arrival
    self.last_failure = nil      -- { code, detail, t }
    T.on_server_change(function(up) self:_emit("server", up) end)
    return self
end

--- Subscribe: events are state_change(new, old), path(points), arrived(dest),
--- failed(code, detail), stuck(level), repath(reason), server(up).
--- Returns an id for off().
function M:on(event, fn)
    self.next_listener = self.next_listener + 1
    local id = self.next_listener
    self.listeners[event] = self.listeners[event] or {}
    self.listeners[event][id] = fn
    return id
end

--- Unsubscribe by id, or by (event, fn).
function M:off(a, b)
    if type(a) == "number" then
        for _, set in pairs(self.listeners) do set[a] = nil end
        return
    end
    local set = self.listeners[a]
    if not set then return end
    for id, fn in pairs(set) do
        if fn == b then set[id] = nil end
    end
end

function M:_emit(event, ...)
    local set = self.listeners[event]
    if not set then return end
    for _, fn in pairs(set) do
        local ok, err = pcall(fn, ...)
        if not ok then L.error("listener for '%s' failed: %s", event, tostring(err)) end
    end
end

function M:_set_state(state, sub)
    local old = self:get_full_state()
    self.state, self.sub = state, sub
    local new = self:get_full_state()
    if new ~= old then
        L.debug("state %s -> %s", old, new)
        self:_emit("state_change", new, old)
    end
end

-- ============================================================================
-- navigation lifecycle
-- ============================================================================
function M:_finish(ok, code, detail, keep_moving)
    local nav = self.nav
    if not nav then return end
    self.nav = nil
    if not keep_moving then F.stop() end
    PC.clear()
    if ok then
        L.debug("arrived at (%.1f, %.1f, %.1f) after %.1fs, %d repaths", nav.dest.x, nav.dest.y, nav.dest.z,
            now() - nav.started, nav.repaths)
        self:_set_state("arrived")
        self:_emit("arrived", nav.dest)
    else
        self.last_failure = { code = code, detail = detail, t = now() }
        self:_set_state(code == "cancelled" and "idle" or "failed")
        if code ~= "cancelled" then
            L.info("navigation failed: %s (%s)", code, tostring(detail))
            self:_emit("failed", code, detail)
        end
    end
    if nav.cb then
        local ok_cb, err = pcall(nav.cb, ok, ok and "arrived" or tostring(detail or code),
            { code = ok and "arrived" or code, detail = detail })
        if not ok_cb then L.error("navigation callback failed: %s", tostring(err)) end
    end
end

--- Start walking `points`; `nav` must be the active navigation.
function M:_walk(nav, points)
    if self.nav ~= nav then return end
    -- 1.5.0: no two waypoints more than C.waypoint_spacing apart; src maps
    -- every walked point back to the server point it came from (route index).
    local walk, src = points, nil
    if C.pathcheck then walk, src = PC.densify(points) end
    self.last_path = points
    L.debug("walking %d points (%s, %.0f yd)%s", #walk, nav.mode, Q.path_length(points),
        #walk ~= #points and fmt(" - %d server points", #points) or "")
    if not F.follow(walk, nav.opts.seamless) then
        PC.clear()
        self:_finish(false, "bad_request", "walker refused the path")
        return
    end
    -- the follower's own copy: pathcheck corrects these points in place
    nav.points = F.points
    nav.pc_src = src
    nav.pc_dirty = false
    if C.pathcheck then PC.reset(F.points, src) else PC.clear() end
    self:_set_state("navigating")
    self:_emit("path", nav.points)
end

local function new_nav(self, mode, dest, cb, opts)
    if self.nav then
        -- seamless: the new path takes over the running walk (no key release)
        self:_finish(false, "cancelled", "replaced by a new navigation", opts and opts.seamless)
    end
    self.nav_id = self.nav_id + 1
    local nav = {
        id = self.nav_id, mode = mode, dest = dest, cb = cb, opts = opts or {},
        repaths = 0, stuck_level = 0, stuck_at = nil, started = now(), route = nil,
        detour = false,
    }
    self.nav = nav
    return nav
end

--- Ask the server for a path from the player to `target` and walk it.
--- `tail` points are appended after the path (used when following a route);
--- `route_i` is the route index of `target` in route mode.
function M:_plan(nav, target, tail, reason, route_i)
    local from = player_point()
    if not from then
        self:_finish(false, "bad_request", "no player position")
        return
    end
    self:_set_state("planning", reason)
    -- 1.5.0: with the path check on, walked paths are not Chaikin-smoothed
    -- (flag 1): measured on the server, smoothing cut off the walkable mesh
    -- twice on a 540 yd route (cliff edges). The 5-yard waypoints and the
    -- clearance shifts keep the walk smooth instead. VALIDATE_MAS (16) stays.
    local flags = nav.opts.flags or C.path_flags
    if C.pathcheck and C.pathcheck_unsmoothed and flags % 2 == 1 then flags = flags - 1 end
    Q.find_path(from, target, {
        no_cache = reason ~= nil,
        allow_partial = nav.opts.allow_partial,
        flags = flags,
    }, function(ok, pts, info)
        if self.nav ~= nav then return end -- superseded
        if not ok then
            self:_finish(false, info.code, info.detail)
            return
        end
        local n = #pts
        if tail then
            for i = 1, #tail do pts[#pts + 1] = tail[i] end
        end
        if route_i then
            -- walked point k -> route waypoint being approached
            local map = {}
            for k = 1, n do map[k] = route_i end
            for k = 1, #pts - n do map[n + k] = route_i + k end
            nav.walk_map = map
        end
        self:_walk(nav, pts)
    end)
end

--- Rebuild the path from where the player stands.
function M:_repath(nav, reason)
    nav.repaths = nav.repaths + 1
    if nav.repaths > C.max_repaths then
        self:_finish(false, "max_repath_exceeded", fmt("gave up after %d repaths", C.max_repaths))
        return
    end
    self:_emit("repath", reason)
    L.debug("repath #%d (%s)", nav.repaths, reason)
    F.stop()
    if nav.mode == "route" and nav.route then
        -- rejoin the recorded route at the waypoint we were heading to
        local i = math.min(nav.route_index or 1, #nav.route)
        local tail = {}
        for k = i + 1, #nav.route do tail[#tail + 1] = nav.route[k] end
        self:_plan(nav, nav.route[i], tail, reason, i)
    else
        self:_plan(nav, nav.dest, nil, reason)
    end
end

-- ============================================================================
-- stuck recovery
-- ============================================================================
function M:_on_stuck(nav)
    local here = player_point()
    -- real progress since the last stuck resets the ladder
    if nav.stuck_at and here then
        local dx, dy = here.x - nav.stuck_at.x, here.y - nav.stuck_at.y
        if dx * dx + dy * dy >= C.stuck_clear_move * C.stuck_clear_move then
            nav.stuck_level = 0
        end
    end
    nav.stuck_at = here
    nav.stuck_level = nav.stuck_level + 1
    local level = nav.stuck_level
    self:_emit("stuck", level)

    if level > C.max_stuck then
        self:_finish(false, "max_stuck_exceeded", fmt("stuck %d times", level - 1))
        return
    end

    L.debug("stuck level %d", level)
    if level == 1 then
        self:_set_state("navigating", "recovering.jump")
        F.jump()
    elseif level == 2 then
        self:_repath(nav, "recovering.repath")
    elseif level == 3 then
        self:_set_state("navigating", "recovering.detour")
        local center = here
        Q.random_point(center, 5, function(ok, p)
            if self.nav ~= nav then return end
            if ok and p and here then
                nav.detour = true
                F.stop()
                if F.follow({ here, p }) then return end
            end
            self:_repath(nav, "recovering.repath")
        end)
    elseif level == 4 then
        self:_set_state("navigating", "recovering.backoff")
        F.back_off(C.backoff_time)
    else
        F.jump()
        self:_repath(nav, "recovering.jump_repath")
    end
end

-- ============================================================================
-- per-frame driver (called by main.lua)
-- ============================================================================
function M:update()
    T.tick()
    local nav = self.nav
    if not nav then return end

    if nav.mode == "route" and F.active and nav.walk_map and not nav.detour then
        -- keep route_index in step with the walker for route rejoining
        -- (1.5.0: walked index -> the server point it came from)
        nav.route_index = nav.walk_map[PC.source_index(F.current_index())] or nav.route_index
    end

    -- 1.5.0: check the next C.check_ahead waypoints (throttled inside) and
    -- hand corrections to the follower. Not during a detour (its own 2 points).
    if C.pathcheck and F.active and nav.points and F.points == nav.points and not nav.detour then
        PC.tick(F.current_index(), function(new_pts)
            if self.nav ~= nav then return end
            nav.points = new_pts
            nav.pc_dirty = true
        end)
    end
    if nav.pc_dirty and F.active and not nav.detour then
        if F.replace_points(nav.points, F.current_index()) then nav.pc_dirty = false end
    end

    local ev = F.tick()
    if not ev then return end
    -- a seamless replacement is still being planned: the event belongs to the
    -- previous walk (the follower already stopped itself on "arrived")
    if not nav.points then return end

    if ev == "arrived" then
        if nav.detour then
            nav.detour = false
            self:_repath(nav, "after_detour")
        else
            self:_finish(true, "arrived")
        end
    elseif ev == "stuck" then
        self:_on_stuck(nav)
    elseif ev == "deviated" then
        self:_repath(nav, "deviated")
    elseif ev == "backed" then
        self:_repath(nav, "after_backoff")
    end
end

-- ============================================================================
-- PUBLIC: movement
-- ============================================================================
--- Pathfind to `target` and walk there.
--- opts: { allow_partial = bool, flags = n,
---         seamless = bool (replace a running walk without stopping - for re-pathing) }
function M:move_to(target, cb, opts)
    local dest = as_point(target)
    if not dest then
        if cb then pcall(cb, false, "bad target", { code = "bad_request" }) end
        return
    end
    local nav = new_nav(self, "move_to", dest, cb, opts)
    L.debug("move_to (%.1f, %.1f, %.1f)", dest.x, dest.y, dest.z)
    self:_plan(nav, dest, nil, nil)
end

--- Walk straight to `target` without pathfinding (still gets stuck recovery).
function M:move_direct(target, cb)
    local dest = as_point(target)
    local here = player_point()
    if not dest or not here then
        if cb then pcall(cb, false, "bad target", { code = "bad_request" }) end
        return
    end
    local nav = new_nav(self, "move_to", dest, cb, nil)
    self:_walk(nav, { here, dest })
end

--- Follow a recorded waypoint list. Recovery rejoins the route at the
--- waypoint being approached instead of cutting to the end.
function M:follow_path(waypoints, cb)
    if type(waypoints) ~= "table" or #waypoints == 0 then
        if cb then pcall(cb, false, "empty path", { code = "bad_request" }) end
        return
    end
    local route = {}
    for i = 1, #waypoints do
        local p = as_point(waypoints[i])
        if not p then
            if cb then pcall(cb, false, fmt("waypoint %d has no x, y, z", i), { code = "bad_request" }) end
            return
        end
        route[i] = p
    end
    local nav = new_nav(self, "route", route[#route], cb, nil)
    nav.route = route
    nav.route_index = 1
    nav.walk_map = {}
    for i = 1, #route do nav.walk_map[i] = i end
    self:_walk(nav, route)
end

--- Rebuild the active path from the player's position.
function M:replan(reason)
    if self.nav then self:_repath(self.nav, reason or "replan") end
end

--- Stop moving. The active callback receives (false, ..., { code = "cancelled" }).
function M:stop()
    if self.nav then
        self:_finish(false, "cancelled", "stopped")
    else
        F.stop()
    end
    if self.state ~= "idle" then self:_set_state("idle") end
end

--- Pause / resume the walk without losing it (e.g. while looting).
function M:pause(reason) F.set_paused(reason or "consumer", true) end
function M:resume(reason) F.set_paused(reason or "consumer", false) end

-- ============================================================================
-- PUBLIC: planning helpers (no movement)
-- ============================================================================
--- cb(ok, points, info) - path from `from` to `to` (tables or vec3).
function M:find_path(from, to, cb, opts)
    Q.find_path(from, to, opts, cb)
end

--- cb(reachable, reason, distance) - can the player walk to `target`?
function M:validate_destination(target, cb)
    local from = player_point()
    if not from then cb(false, "no player position"); return end
    Q.find_path(from, target, nil, function(ok, pts, info)
        if ok then cb(true, nil, Q.path_length(pts))
        else cb(false, info.code, nil) end
    end)
end

--- Order `nodes` into a short visiting route starting at the player
--- (nearest neighbour, then 2-opt; straight-line distances).
--- cb(ok, { waypoints, visit_order, total_distance })
function M:plan_route(nodes, cb)
    local pts = {}
    for i = 1, #(nodes or {}) do
        local p = as_point(nodes[i])
        if p then pts[#pts + 1] = { p = p, i = i } end
    end
    if #pts == 0 then cb(false, nil); return end
    local here = player_point() or pts[1].p
    local function d(a, b) return sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end

    local order, used, cur = {}, {}, here
    for _ = 1, #pts do
        local best, bi = math.huge, nil
        for k = 1, #pts do
            if not used[k] then
                local dk = d(cur, pts[k].p)
                if dk < best then best, bi = dk, k end
            end
        end
        used[bi] = true
        order[#order + 1] = bi
        cur = pts[bi].p
    end

    local improved, passes = true, 0
    while improved and passes < 20 do
        improved, passes = false, passes + 1
        for a = 1, #order - 2 do
            for b = a + 1, #order - 1 do
                local pa = a == 1 and here or pts[order[a - 1]].p
                local p1, p2, p3 = pts[order[a]].p, pts[order[b]].p, pts[order[b + 1]].p
                if d(pa, p2) + d(p1, p3) < d(pa, p1) + d(p2, p3) - 0.01 then
                    local i, j = a, b
                    while i < j do order[i], order[j] = order[j], order[i]; i, j = i + 1, j - 1 end
                    improved = true
                end
            end
        end
    end

    local waypoints, visit, total, prev = {}, {}, 0, here
    for k = 1, #order do
        local e = pts[order[k]]
        waypoints[k] = vec3.new(e.p.x, e.p.y, e.p.z)
        visit[k] = e.i
        total = total + d(prev, e.p)
        prev = e.p
    end
    cb(true, { waypoints = waypoints, visit_order = visit, total_distance = total })
end

local function escape(player_pos, dx, dy, cb)
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.01 then dx, dy, len = 1, 0, 1 end
    local p = as_point(player_pos)
    if not p then cb(nil); return end
    local goal = { x = p.x + dx / len * C.escape_distance, y = p.y + dy / len * C.escape_distance, z = p.z }
    -- slide along the mesh toward the goal: stops at walls and cliffs
    Q.move_along_surface(p, goal, function(ok, point)
        cb(ok and point and vec3.new(point.x, point.y, point.z) or nil)
    end)
end

--- cb(point|nil) - a mesh point away from `target_pos`, for kiting.
function M:kite(player_pos, target_pos, cb)
    local p, t = as_point(player_pos), as_point(target_pos)
    if not p or not t then cb(nil); return end
    escape(p, p.x - t.x, p.y - t.y, cb)
end

--- cb(point|nil) - a mesh point away from the centroid of `threats`.
function M:flee(player_pos, threats, cb)
    local p = as_point(player_pos)
    if not p or type(threats) ~= "table" or #threats == 0 then cb(nil); return end
    local cx, cy, n = 0, 0, 0
    for i = 1, #threats do
        local t = as_point(threats[i])
        if t then cx, cy, n = cx + t.x, cy + t.y, n + 1 end
    end
    if n == 0 then cb(nil); return end
    escape(p, p.x - cx / n, p.y - cy / n, cb)
end

--- cb(ok, z) - navmesh height under `pos`.
function M:get_height(pos, cb) Q.get_height(pos, cb) end
function M:get_player_height(cb)
    local p = player_point()
    if not p then cb(false, nil); return end
    Q.get_height(p, cb)
end

--- cb(ok, clear, hit_point) - is the straight line walkable on the mesh?
function M:raycast(from, to, cb) Q.raycast(from, to, cb) end

--- cb(ok, point) - a random mesh point within `radius` of `center`.
function M:random_point(center, radius, cb) Q.random_point(center, radius, cb) end

-- ============================================================================
-- PUBLIC: status
-- ============================================================================
function M:get_state() return self.state end

function M:get_full_state()
    if self.sub then return self.state .. "." .. self.sub end
    return self.state
end

function M:is_moving() return self.state == "navigating" end
function M:is_busy() return self.nav ~= nil end
function M:get_destination() return self.nav and self.nav.dest or nil end
function M:get_current_path() return self.nav and self.nav.points or nil end
function M:get_last_path() return self.last_path end
function M:get_path_index() return F.active and F.current_index() or 0 end
function M:get_last_failure() return self.last_failure end

function M:get_progress()
    local pts = self.nav and self.nav.points
    if not pts or #pts == 0 then
        return { percent = 0, waypoints_remaining = 0, total_waypoints = 0, current_index = 0 }
    end
    local i = F.active and F.current_index() or 1
    return {
        percent = (i - 1) / math.max(1, #pts - 1),
        waypoints_remaining = #pts - i + 1,
        total_waypoints = #pts,
        current_index = i,
    }
end

function M:is_server_available() return T.server_up == true end

--- cb(up, info_line)
function M:health_check(cb) T.health(cb) end

--- Change any key of anav/config.lua at runtime (menu-owned keys are
--- overwritten by the menu each frame).
function M:update_config(overrides)
    if type(overrides) ~= "table" then return end
    for k, v in pairs(overrides) do
        if C[k] ~= nil and type(C[k]) == type(v) then C[k] = v end
    end
    if overrides.base_url then Q.clear_cache() end
end

function M:get_config() return C end

return M
