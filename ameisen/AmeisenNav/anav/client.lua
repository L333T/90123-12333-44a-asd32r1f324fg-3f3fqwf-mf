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
local H = require("anav/horizon")      -- 1.6.0: rolling 20-yard validated windows (move_to)
---@type movement_handler
local MH = nil
do
    local ok, m = pcall(require, "common/utility/movement_handler")
    if ok and type(m) == "table" then MH = m end
end

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
-- START POSITION WITHOUT A PATH (1.6.5). The 11:2x log: from (-5760,-2599)
-- every request failed no_path at once, every 3 s for 90 s - the height
-- search found nothing at any height, because the START was the problem
-- (the character on a spot the navmesh does not cover). The walk ladder
-- never ran: no walk ever started. After C.unstick_after_fails failed plans
-- from the same spot (within 2 yd), the manoeuvre runs on its own (side
-- alternating; the 4th failure backs off instead); the consumer's next
-- request then starts from wherever that left the character.
local PLAN_FAIL_CODES = { no_path = true, start_off_mesh = true, unreachable = true, end_off_mesh = true }

function M:_note_plan_fail(code)
    if not PLAN_FAIL_CODES[code] then return end
    local here = player_point()
    if not here then return end
    local f = self.spot_fail
    if f and (here.x - f.x) ^ 2 + (here.y - f.y) ^ 2 <= 4 and (now() - f.t) < 20 then
        f.n, f.t = f.n + 1, now()
    else
        f = { x = here.x, y = here.y, n = 1, t = now() }
        self.spot_fail = f
    end
    if f.n >= C.unstick_after_fails and not F.manoeuvring() and not F.active then
        if f.n % 4 == 0 then
            L.info("no path from (%.1f, %.1f) %d times - backing off", here.x, here.y, f.n)
            X.call_fn("core.input.move_backward_start", core.input.move_backward_start)
            local back = core.time() + C.backoff_time
            self.backing_free = back
        else
            L.info("no path from (%.1f, %.1f) %d times - strafe, jump, strafe", here.x, here.y, f.n)
            F.manoeuvre()
        end
    end
end

function M:_finish(ok, code, detail, keep_moving)
    local nav = self.nav
    if not nav then return end
    if ok then self.spot_fail = nil elseif nav.mode == "move_to" then
        -- noted after this navigation is closed (below)
        self.pending_fail_code = code
    end
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
    local pc = self.pending_fail_code
    self.pending_fail_code = nil
    if pc and not self.nav then self:_note_plan_fail(pc) end
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

-- HEIGHT SEARCH (1.6.2). A far destination's height is often a guess: a
-- RestedXP waypoint is x, y only, and on WoW Forever the terrain height read
-- answers 0, so the consumer passes the player's own height - 514 yd away
-- that was 20+ yd off the ground and the server answered no_path (10:53
-- Loch Modan log: the bot then stood on "cannot reach" for good). On
-- no_path / end_off_mesh / unreachable the same x, y is asked again at
-- Z_SEARCH offsets in ONE batched request; the first offset (nearest to the
-- guess) with a full path is walked, and the destination takes its height.
local Z_SEARCH = { 8, -8, 20, -20, 40, -40, 80, -80, 150 }
local Z_RETRY_CODES = { no_path = true, end_off_mesh = true, unreachable = true }

function M:_z_search(nav, from, target, flags, done)
    local list = {}
    for i = 1, #Z_SEARCH do
        list[i] = { from, { x = target.x, y = target.y, z = target.z + Z_SEARCH[i] } }
    end
    Q.find_paths(list, { flags = flags, allow_partial = false }, function(ok, res)
        if self.nav ~= nav then return end
        if ok and type(res) == "table" then
            for i = 1, #Z_SEARCH do
                local r = res[i]
                if r and r.ok and r.points and #r.points > 1 then
                    local e = r.points[#r.points]
                    local dx, dy = e.x - target.x, e.y - target.y
                    if dx * dx + dy * dy <= C.partial_accept * C.partial_accept then
                        L.debug("height search: destination found %+d yd from the given height (z %.1f)",
                            Z_SEARCH[i], e.z)
                        return done(true, r.points, e.z)
                    end
                end
            end
        end
        done(false)
    end)
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
        if not ok and not tail and not nav.z_searched and Z_RETRY_CODES[info and info.code] then
            -- 1.6.2: the right x, y at the wrong height - search the height once
            nav.z_searched = true
            self:_z_search(nav, from, target, flags, function(found, zpts, z)
                if not found then
                    self:_finish(false, info.code, (info.detail or info.code) .. " (no height at that spot)")
                    return
                end
                target.z = z
                if nav.dest and nav.dest ~= target then
                    local ddx, ddy = nav.dest.x - target.x, nav.dest.y - target.y
                    if ddx * ddx + ddy * ddy < 1 then nav.dest.z = z end
                end
                if nav.horizon then
                    self:_window(nav, zpts, from)
                else
                    self:_walk(nav, zpts)
                end
            end)
            return
        end
        if not ok then
            self:_finish(false, info.code, info.detail)
            return
        end
        local n = #pts
        if tail then
            for i = 1, #tail do pts[#pts + 1] = tail[i] end
        end
        if nav.horizon and not tail then
            self:_window(nav, pts, from)
            return
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

-- ============================================================================
-- ROLLING HORIZON (1.6.0, anav/horizon.lua)
-- ============================================================================
--- Build and walk (or swap in) the next validated window of `path`, which
--- starts at `from` (the player position when it was asked for).
function M:_window(nav, path, from)
    nav.window_pending = true
    H.build(from, path, function(ok, win, info)
        if self.nav ~= nav then return end
        nav.window_pending = false
        if not ok or not win or #win == 0 then
            self:_finish(false, "no_path", info and info.why or "window could not be built")
            return
        end
        nav.window_final = info and info.final == true
        nav.window_end = win[#win]
        if info and info.exact then nav.exact_z = true end
        if nav.window_final and #win <= 1 then
            -- 1.6.1: already standing at the object's / NPC's edge
            self:_finish(true, "arrived")
            return
        end
        nav.windows = (nav.windows or 0) + 1
        self.last_path = win
        L.debug("window #%d: %d points, %.0f yd%s", nav.windows, #win, Q.path_length(win),
            nav.window_final and " (final)" or "")
        local started
        if F.active then started = F.swap(win) else started = F.follow(win) end
        if not started then
            self:_finish(false, "bad_request", "walker refused the window")
            return
        end
        nav.points = F.points
        PC.clear()                                       -- windows are checked before walking
        if self.state ~= "navigating" or self.sub then self:_set_state("navigating") end
        self:_emit("path", nav.points)
        self:_prefetch(nav)                              -- 1.6.4: the next one, while walking this one
    end, nav.dest)
end

-- PLAN WHILE MOVING (1.6.4). The next window used to be asked for 5 yd
-- before the current one ended - a full path to the destination plus the two
-- validation batches, 0.5-1 s, against 0.7 s of running: the 11:13 Loch
-- Modan log shows "navigating -> navigating.window" at every window, the
-- walker stopping, the keys released and a fresh walk 0.25 s later (and a
-- fresh walk from where the request was made can turn the character back).
-- Now the next window is built from the CURRENT window's end point the
-- moment that window starts walking; 5 yd before its end it is appended to
-- the points still ahead of the player and swapped in as one list - no
-- stop, no key release, nothing behind the player. Planning from the player
-- (_next_window) stays the fallback: no prepared window within
-- PREFETCH_LATE yd of the end, or the walk was re-planned.
local PREFETCH_LATE = 2.0

function M:_prefetch(nav)
    if nav.window_final or not nav.window_end then return end
    nav.pf_id = (nav.pf_id or 0) + 1
    local id = nav.pf_id
    nav.prefetch = nil
    local e = nav.window_end
    local from = { x = e.x, y = e.y, z = e.z }
    Q.find_path(from, nav.dest, { flags = 0, no_cache = true, allow_partial = nav.opts.allow_partial },
        function(ok, pts)
            if self.nav ~= nav or nav.pf_id ~= id then return end
            if not ok then return end                    -- the fallback plans from the player
            H.build(from, pts, function(ok2, win, info)
                if self.nav ~= nav or nav.pf_id ~= id then return end
                if ok2 and win and #win >= 2 then
                    nav.prefetch = { id = id, win = win, info = info, from = from }
                end
            end, nav.dest)
        end)
end

--- Swap the prepared window in after the points still ahead of the player.
function M:_take_prefetch(nav)
    local pf = nav.prefetch
    nav.prefetch = nil
    if not pf then return false end
    local combined = {}
    if F.active and type(F.points) == "table" then
        for k = F.current_index(), #F.points do combined[#combined + 1] = F.points[k] end
    end
    for k = 2, #pf.win do combined[#combined + 1] = pf.win[k] end   -- pf.win[1] is the old end
    if #combined == 0 then return false end
    local started
    if F.active then started = F.swap(combined) else started = F.follow(combined) end
    if not started then return false end
    nav.window_final = pf.info and pf.info.final == true
    nav.window_end = combined[#combined]
    if pf.info and pf.info.exact then nav.exact_z = true end
    nav.windows = (nav.windows or 0) + 1
    nav.points = F.points
    self.last_path = combined
    L.debug("window #%d: %d points, %.0f yd (prepared while walking)%s", nav.windows, #pf.win,
        Q.path_length(pf.win), nav.window_final and " (final)" or "")
    if self.state ~= "navigating" or self.sub then self:_set_state("navigating") end
    self:_emit("path", nav.points)
    self:_prefetch(nav)
    return true
end

--- Ask the server for the path from the player to the destination and turn
--- it into the next window (not counted as a repath: this is normal progress).
function M:_next_window(nav)
    local from = player_point()
    if not from or nav.window_pending then return end
    nav.window_pending = true
    Q.find_path(from, nav.dest, { flags = 0, no_cache = true, allow_partial = nav.opts.allow_partial },
        function(ok, pts, info)
            if self.nav ~= nav then return end
            nav.window_pending = false
            if not ok then
                -- keep walking what we have; the stuck / arrival logic decides
                L.debug("next window: %s (%s)", tostring(info and info.code), tostring(info and info.detail))
                nav.window_retry_t = now() + 1.0
                if not F.active then self:_finish(false, info and info.code or "no_path", info and info.detail) end
                return
            end
            self:_window(nav, pts, from)
        end)
end

--- 1.6.0 HANDOFF. Let go of the active navigation for another mover.
---   to = "simple": no key is released; simple_movement is pointed at
---        opts.position (if given) and the consumer drives it from here.
---   to = "combat": the walk stops; the movement handler faces opts.target
---        for opts.face seconds (C.handoff_face) and, with opts.pause, holds
---        still that long (a cast). The consumer's combat movement takes over.
--- The handed-off navigation's callback gets (false, "handoff:<to>",
--- { code = "cancelled", detail = "handoff:<to>" }) - consumers treat it as
--- an ordinary cancel. Returns true when the handoff was made.
function M:handoff(to, opts)
    opts = opts or {}
    local nav = self.nav
    if to == "simple" then
        if nav then
            self.nav = nil
            PC.clear()
            if nav.cb then pcall(nav.cb, false, "handoff:simple", { code = "cancelled", detail = "handoff:simple" }) end
        end
        local ok = F.hand_to_walker(opts.position and as_point(opts.position) or nil)
        self:_set_state("idle")
        self:_emit("handoff", "simple")
        L.debug("handoff -> simple_movement%s", ok and " (still moving)" or "")
        return true
    end
    if to == "combat" then
        if nav then self:_finish(false, "cancelled", "handoff:combat") else F.stop() end
        if MH then
            if opts.pause and opts.pause > 0 then pcall(MH.pause_movement_light, MH, opts.pause) end
            if opts.target then
                pcall(MH.look_at_target, MH, opts.face or C.handoff_face, 0, opts.target)
            end
            self.mh_until = now() + math.max(opts.pause or 0, opts.target and (opts.face or C.handoff_face) or 0) + 0.5
        end
        if self.state ~= "idle" then self:_set_state("idle") end
        self:_emit("handoff", "combat")
        L.debug("handoff -> combat movement")
        return true
    end
    return false
end

--- Movement handler bookkeeping after a combat handoff (its delays and
--- auto-resume run in on_render - main.lua calls this from its render).
function M:render()
    if MH and self.mh_until and now() < self.mh_until then pcall(MH.on_render, MH) end
end

--- Rebuild the path from where the player stands.
function M:_repath(nav, reason)
    nav.pf_id = (nav.pf_id or 0) + 1                    -- 1.6.4: a prepared window is stale
    nav.prefetch = nil
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
    -- 1.6.5 ladder: 1 strafe-jump-strafe, 2 repath, 3 strafe-jump-strafe the
    -- other way, 4 detour, 5 back off, 6 jump + repath
    if level == 1 or level == 3 then
        self:_set_state("navigating", "recovering.strafe_jump")
        nav.manoeuvre = true
        F.manoeuvre()
    elseif level == 2 then
        self:_repath(nav, "recovering.repath")
    elseif level == 4 then
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
    elseif level == 5 then
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
    -- 1.6.5: the back-off from a spot without a path ends after C.backoff_time
    if self.backing_free and core.time() >= self.backing_free then
        self.backing_free = nil
        X.call_fn("core.input.move_backward_stop", core.input.move_backward_stop)
    end
    -- 1.6.5: the strafe-jump-strafe manoeuvre runs with or without a walk
    if F.manoeuvring() then
        local done = F.manoeuvre_tick()
        local nv = self.nav
        if done and nv and nv.manoeuvre then
            nv.manoeuvre = false
            self:_repath(nv, "after_strafe_jump")
        end
        if F.manoeuvring() then return end
    end
    local nav = self.nav
    if not nav then return end

    if nav.mode == "route" and F.active and nav.walk_map and not nav.detour then
        -- keep route_index in step with the walker for route rejoining
        -- (1.5.0: walked index -> the server point it came from)
        nav.route_index = nav.walk_map[PC.source_index(F.current_index())] or nav.route_index
    end

    -- 1.5.0: check the next C.check_ahead waypoints (throttled inside) and
    -- hand corrections to the follower. Not during a detour (its own 2 points).
    -- 1.6.0 rolling horizon: 5 yards before the window ends, the next one
    if nav.horizon and F.active and not nav.detour and not nav.window_final
        and not nav.window_pending and nav.window_end and now() >= (nav.window_retry_t or 0) then
        local here = player_point()
        if here then
            local dx, dy = nav.window_end.x - here.x, nav.window_end.y - here.y
            local d2 = dx * dx + dy * dy
            if d2 <= C.horizon_refresh * C.horizon_refresh then
                -- 1.6.4: the window prepared while walking; else, late, from the player
                if not (nav.prefetch and self:_take_prefetch(nav))
                    and (nav.prefetch == nil and (nav.pf_id == nil or d2 <= PREFETCH_LATE * PREFETCH_LATE)) then
                    self:_next_window(nav)
                end
            end
        end
    end
    -- 1.6.0 quick handoff near the destination (opts.handoff = { at = yards })
    local ho = nav.opts.handoff
    if ho and F.active and type(ho.at) == "number" then
        local here = player_point()
        if here then
            local dx, dy = nav.dest.x - here.x, nav.dest.y - here.y
            if dx * dx + dy * dy <= ho.at * ho.at and math.abs(nav.dest.z - here.z) < 6 then
                local dest, cb = nav.dest, nav.cb
                self.nav = nil
                PC.clear()
                F.hand_to_walker(dest)
                self:_set_state("arrived")
                self:_emit("handoff", "simple")
                self:_emit("arrived", dest)
                L.debug("handoff -> simple_movement %.1f yd from the destination", sqrt(dx * dx + dy * dy))
                if cb then pcall(cb, true, "arrived", { code = "arrived", detail = "handoff:simple" }) end
                return
            end
        end
    end

    if C.pathcheck and not nav.horizon and F.active and nav.points and F.points == nav.points and not nav.detour then
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

    if ev == "arrived" and nav.horizon and not nav.detour and not nav.window_final then
        -- the window ran out before the next one was taken: a prepared one,
        -- else plan it now (1.6.4)
        if nav.prefetch and self:_take_prefetch(nav) then return end
        self:_set_state("navigating", "window")
        self:_next_window(nav)
        return
    end
    if ev == "arrived" and nav.exact_z and not nav.detour then
        -- 1.6.1: an object / NPC stands on the destination, so its height is
        -- real: arriving on another floor (under an upstairs NPC) is not there
        local here = player_point()
        if here and math.abs(here.z - nav.dest.z) >= C.arrive_dz then
            L.debug("arrived %.1f yd below/above the destination - another floor, re-planning",
                math.abs(here.z - nav.dest.z))
            self:_repath(nav, "wrong_floor")
            return
        end
    end
    if ev == "arrived" then
        if nav.detour then
            nav.detour = false
            self:_repath(nav, "after_detour")
        else
            self:_finish(true, "arrived")
        end
    elseif ev == "wrong_floor" then
        self:_repath(nav, "wrong_floor")
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
    -- 1.6.0: rolling validated windows unless switched off (C.horizon / opts.horizon = false)
    nav.horizon = C.horizon and not (opts and opts.horizon == false)
    if nav.horizon then nav.opts.flags = 0 end           -- unsmoothed, always
    L.debug("move_to (%.1f, %.1f, %.1f)%s", dest.x, dest.y, dest.z, nav.horizon and " - horizon" or "")
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
