-- ============================================================================
-- AmeisenNav
-- anav/follower.lua - walks a waypoint list
-- ============================================================================
-- Version: 1.5.0
-- Author: BLIZZ
-- ============================================================================
-- Pure execution: it walks, watches and reports. Deciding what to do about a
-- problem (repath, jump, detour, give up) is anav/client.lua's job.
--
-- F.tick() returns one event per frame at most:
--   "arrived"   the last waypoint is reached
--   "stuck"     no progress for C.stuck_window seconds while not paused
--   "deviated"  the player is more than C.deviation_limit from the path
--   "backed"    a timed back-off (F.back_off) has finished
--
-- DRIVERS (C.driver)
--   "walker"  common/utility/simple_movement. Shared by every plugin: while
--             F.active, AmeisenNav owns it.
--   "input"   AmeisenNav's own, for WoW Forever, where simple_movement
--             refuses every path (it cannot find the player) and
--             core.input.look_at does not turn the character. It holds
--             move forward and steers with the turn keys like a player:
--             the running direction is measured from position changes and
--             turn_left / turn_right is held just long enough to line up
--             with the next waypoint (C.turn_rate degrees per second).
--   "auto"    try the walker; after the first refusal use "input" for the
--             rest of the session.
-- ============================================================================

---@type simple_movement
local walker = require("common/utility/simple_movement")
---@type vec3
local vec3 = require("common/geometry/vector_3")

local C = require("anav/config")
local L = require("anav/log")
local X = require("anav/context")
local AV = require("anav/avoid")

local F = {}

local sqrt = math.sqrt

F.active = false
F.points = nil             -- vec3[] currently being walked
F.paused = false
F.driver = nil             -- driver of the active walk: "walker" | "input"

local walker_refused = false  -- auto: simple_movement refused once this session
local walker_offset = 0       -- walker driver: F.points index = walker index + offset (1.5.0)
local last_replace = -1e9

local pause_reasons = {}   -- reason -> true
local walker_paused = false

-- input driver state
local idx = 1              -- waypoint being approached
local forward_on = false
local next_forward = 0     -- re-assert move forward (the game can drop it)
local FORWARD_REFRESH = 1.0
local turn_dir = 0         -- 1 = turning left, -1 = right, 0 = not turning
local turn_until = 0
local sample_x, sample_y = nil, nil  -- where the current heading measurement started
local MIN_MOVE_FOR_HEADING = 0.8     -- yards run before the heading is trusted
local last_turn = nil      -- { err = signed deg, dur = s, idx = n } for turn-rate calibration
F.turn_rate = nil          -- calibrated degrees / second (nil = use C.turn_rate)
-- avoidance
local aim = { x = 0, y = 0, z = 0 }
local aim_until = 0        -- use `aim` instead of the waypoint until then
local aim_reason = nil
local next_advice = 0
local next_pull = 0
local ADVICE_EVERY, AIM_HOLD, PULL_EVERY = 0.1, 0.4, 0.3

local anchor_x, anchor_y, anchor_t = nil, nil, 0
local next_sample = 0
local next_deviation_check = 0
local backing_until = nil

local function now() return core.time() end

-- ----------------------------------------------------------------------------
-- input driver primitives
-- ----------------------------------------------------------------------------
local function forward_stop()
    if forward_on then
        X.call_fn("core.input.move_forward_stop", core.input.move_forward_stop)
        forward_on = false
    end
end

local function forward_start(t)
    if not forward_on or t >= next_forward then
        X.call_fn("core.input.move_forward_start", core.input.move_forward_start)
        forward_on = true
        next_forward = t + FORWARD_REFRESH
    end
end

local function turn_stop()
    if turn_dir == 1 then
        X.call_fn("core.input.turn_left_stop", core.input.turn_left_stop)
    elseif turn_dir == -1 then
        X.call_fn("core.input.turn_right_stop", core.input.turn_right_stop)
    end
    turn_dir = 0
end

local function turn_start(dir)
    if dir == turn_dir then return end
    turn_stop()
    if dir == 1 then
        X.call_fn("core.input.turn_left_start", core.input.turn_left_start)
    else
        X.call_fn("core.input.turn_right_start", core.input.turn_right_start)
    end
    turn_dir = dir
end

-- ----------------------------------------------------------------------------
-- shared
-- ----------------------------------------------------------------------------
--- Which steering the walker should use. look_at is simple_movement's default
--- and the smoother of the two, but it does not turn the character on WoW
--- Forever, so that client falls back to the turn keys.
local function want_look_at()
    if C.use_look_at == "look_at" then return true end
    if C.use_look_at == "turns" then return false end
    return not X.is_forever()
end

-- 1.5.2: the walker (simple_movement) is shared by every plugin. Its arrival
-- thresholds are saved before AmeisenNav sets its own and put back when the
-- walk ends (F.stop) - Slave Pens arrives at 0.7 yd and inherited 1.5 yd.
-- get_threshold / get_final_threshold: simple_movement stub.
local saved_thresholds = nil

local function restore_walker()
    local sv = saved_thresholds
    if not sv then return end
    saved_thresholds = nil
    if type(sv.threshold) == "number" then X.call(walker, "set_threshold", sv.threshold) end
    if type(sv.final) == "number" then X.call(walker, "set_final_threshold", sv.final) end
end

local function configure_walker()
    if not saved_thresholds then
        local _, th = X.call(walker, "get_threshold")
        local _, fi = X.call(walker, "get_final_threshold")
        saved_thresholds = { threshold = th, final = fi }
    end
    X.call(walker, "set_use_look_at", want_look_at())
    X.call(walker, "set_smoothing_enabled", false) -- the server returns the corners we want
    X.call(walker, "set_threshold", C.waypoint_threshold)
    X.call(walker, "set_final_threshold", C.final_threshold)
    X.call(walker, "set_look_distance", C.look_distance)
end

local function release_inputs()
    if F.driver == "walker" then X.call(walker, "strafe", nil) end
    forward_stop()
    turn_stop()
    if backing_until then
        X.call_fn("core.input.move_backward_stop", core.input.move_backward_stop)
        backing_until = nil
    end
    -- a back-off interrupted by stop()/follow() must not leave the walk paused
    pause_reasons.backoff = nil
end

local function sync_pause()
    local want = next(pause_reasons) ~= nil
    F.paused = want
    if F.driver == "input" then
        if want then forward_stop(); turn_stop() end -- tick() restarts when unpaused
        walker_paused = want
        return
    end
    if want == walker_paused then return end
    walker_paused = want
    if want then X.call(walker, "pause") else X.call(walker, "resume") end
end

--- Pause / resume following for a named reason ("cast", "consumer", ...).
function F.set_paused(reason, on)
    if (pause_reasons[reason] == true) == (on == true) then return end
    pause_reasons[reason] = on and true or nil
    sync_pause()
    -- a pause is not being stuck
    anchor_t = now()
end

local function reset_anchor()
    local x, y = X.position()
    anchor_x, anchor_y, anchor_t = x, y, now()
end

local function start_walker(pts)
    configure_walker()
    X.call(walker, "clear_navigation")
    local ok, issued = X.call(walker, "navigate", pts, false, true)
    if ok and issued ~= false then return true end
    L.warn("simple_movement refused the path (%s)%s", tostring(issued),
        C.driver == "auto" and " - using the built-in input driver from now on" or "")
    return false
end

--- Index to start a (new or swapped-in) path at: the end of the segment
--- nearest the player among the first few. A path starts where the player
--- stood when it was requested; by the time it arrives that point is often
--- behind, and steering to it would turn the character around.
local function start_index(pts)
    local px, py = X.position()
    if not px or #pts < 2 then return 1 end
    local best, best_i = math.huge, 1
    for k = 1, math.min(#pts - 1, 4) do
        local a, b = pts[k], pts[k + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local len2 = dx * dx + dy * dy
        local t = 0
        if len2 > 0 then
            t = ((px - a.x) * dx + (py - a.y) * dy) / len2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local cx, cy = a.x + dx * t - px, a.y + dy * t - py
        local d = cx * cx + cy * cy
        if d < best then best, best_i = d, k + 1 end
    end
    return best_i
end

--- Start walking `points` (tables or vec3 with x, y, z). Returns false if it could not start.
--- `seamless`: when the input driver is already walking, swap the points in
--- without releasing move forward or the turn keys (continuous re-pathing,
--- e.g. following a moving target: a stop + restart may not resume on WoW Forever).
function F.follow(points, seamless)
    if type(points) ~= "table" or #points == 0 then return false end
    local pts = {}
    for i = 1, #points do
        local p = points[i]
        pts[i] = vec3.new(p.x, p.y, p.z)
    end
    if seamless and F.active and F.driver == "input" then
        F.points = pts
        idx = start_index(pts)
        last_turn = nil    -- calibration referred to the old waypoint
        aim_until = 0
        return true
    end
    release_inputs()

    local driver = C.driver
    if driver == "auto" then driver = walker_refused and "input" or "walker" end
    if driver == "walker" and not start_walker(pts) then
        if C.driver ~= "auto" then
            F.active = false
            return false
        end
        walker_refused = true
        driver = "input"
    end
    if driver == "input" then
        X.call(walker, "clear_navigation") -- make sure simple_movement is not steering too
        idx = start_index(pts)
        turn_until, sample_x, last_turn, aim_until = 0, nil, nil, 0
    end
    F.driver = driver
    L.debug("driver: %s", driver)

    walker_offset = 0
    F.points = pts
    F.active = true
    -- Force a resume() unless a pause reason is still live: the walker may have been
    -- left paused by a previous navigation (or another plugin).
    walker_paused = true
    sync_pause()
    reset_anchor()
    next_sample = now() + C.stuck_sample
    next_deviation_check = now() + 1.0
    return true
end

--- 1.6.0 (anav/horizon): swap a new window in under a running walk, now
--- (no REPLACE_GAP, no key release): the walker gets the new points from the
--- one nearest the player.
function F.swap(points)
    if type(points) ~= "table" or #points == 0 then return false end
    if not F.active then return F.follow(points) end
    local pts = {}
    for i = 1, #points do pts[i] = vec3.new(points[i].x, points[i].y, points[i].z) end
    local from = start_index(pts)
    F.points = pts
    if F.driver == "input" then
        idx = from
        last_turn, aim_until = nil, 0
        return true
    end
    local rest = {}
    for k = from, #pts do rest[#rest + 1] = pts[k] end
    X.call(walker, "clear_navigation")
    local ok, issued = X.call(walker, "navigate", rest, false, true)
    if not ok or issued == false then
        L.warn("simple_movement refused the next window")
        return false
    end
    walker_offset = from - 1
    last_replace = now()
    if walker_paused then X.call(walker, "pause") end
    return true
end

--- 1.6.0 HANDOFF TO SIMPLE MOVEMENT: AmeisenNav lets go of the walk WITHOUT
--- releasing a key. The walker gets its own settings back (thresholds) and,
--- with `pos`, is pointed at it at once (move_to_position) - the character
--- keeps running and the consumer drives simple_movement from here.
function F.hand_to_walker(pos)
    if F.driver == "input" then
        turn_stop()                                         -- simple_movement steers now
        if backing_until then
            X.call_fn("core.input.move_backward_stop", core.input.move_backward_stop)
            backing_until = nil
        end
    end
    pause_reasons = {}
    if walker_paused then walker_paused = false; X.call(walker, "resume") end
    restore_walker()
    X.call(walker, "clear_navigation")
    local ok = false
    if pos then
        local okc, issued = X.call(walker, "move_to_position", vec3.new(pos.x, pos.y, pos.z))
        ok = okc and issued ~= false
    end
    if not ok and F.driver == "input" then forward_stop() end
    F.active = false
    F.points = nil
    return ok
end

--- Stop walking and release the walker / inputs.
function F.stop()
    release_inputs()
    if F.active and F.driver == "walker" then
        X.call(walker, "stop")
        X.call(walker, "clear_navigation")
    end
    restore_walker()
    F.active = false
    F.points = nil
end

--- 1-based index of the waypoint being approached.
function F.current_index()
    if not F.active or not F.points then return 1 end
    if F.driver == "input" then return math.min(idx, #F.points) end
    local ok, i = X.call(walker, "get_current_index")
    if ok and type(i) == "number" and i >= 1 then return math.min(i + walker_offset, #F.points) end
    return math.min(1 + walker_offset, #F.points)
end

--- 1.5.0 (anav/pathcheck): corrected points for the walk in progress, from
--- waypoint `from` on. The input driver swaps them in place; the walker gets
--- the rest of the list re-issued (at most every REPLACE_GAP s - a correction
--- arriving sooner is still in F.points and goes out with the next one).
--- Returns true when the walk now uses them.
local REPLACE_GAP = 0.5
function F.replace_points(points, from)
    if not F.active or type(points) ~= "table" or #points == 0 then return false end
    from = math.max(1, math.min(from or 1, #points))
    F.points = points
    if F.driver == "input" then
        idx = from
        last_turn, aim_until = nil, 0
        return true
    end
    local t = now()
    if t - last_replace < REPLACE_GAP then return false end
    last_replace = t
    local rest = {}
    for k = from, #points do rest[#rest + 1] = points[k] end
    X.call(walker, "clear_navigation")
    local ok, issued = X.call(walker, "navigate", rest, false, true)
    if not ok or issued == false then
        L.warn("simple_movement refused the corrected path")
        return false
    end
    walker_offset = from - 1
    if walker_paused then X.call(walker, "pause") end
    return true
end

--- Back up for `seconds` (walking paused meanwhile). tick() returns "backed" when done.
function F.back_off(seconds)
    F.set_paused("backoff", true)
    forward_stop()
    turn_stop()
    X.call_fn("core.input.move_backward_start", core.input.move_backward_start)
    backing_until = now() + (seconds or C.backoff_time)
end

function F.jump()
    X.call_fn("core.input.jump", core.input.jump)
end

-- 2D distance from (px, py) to segment a-b.
local function seg_dist(px, py, a, b)
    local ax, ay, bx, by = a.x, a.y, b.x, b.y
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 0 then
        t = ((px - ax) * dx + (py - ay) * dy) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local cx, cy = ax + dx * t - px, ay + dy * t - py
    return sqrt(cx * cx + cy * cy)
end

--- Distance from the player to the path around the current waypoint.
function F.off_path_distance()
    if not F.points then return 0 end
    local px, py = X.position()
    if not px then return 0 end
    local i = F.current_index()
    local pts = F.points
    local best = math.huge
    for k = math.max(1, i - 1), math.min(#pts - 1, i + 1) do
        local d = seg_dist(px, py, pts[k], pts[k + 1])
        if d < best then best = d end
    end
    if best == math.huge then
        local p = pts[1]
        best = sqrt((p.x - px) ^ 2 + (p.y - py) ^ 2)
    end
    return best
end

-- STEERING
-- Move forward stays held. Every frame with at least MIN_MOVE_FOR_HEADING
-- yards of running since the last measurement, the running direction is
-- compared with the bearing to the waypoint; when it is more than
-- C.heading_tolerance off, the matching turn key is held for
-- |error| / C.turn_rate seconds. Measurement restarts after every turn,
-- because the direction run during a turn is a curve.
-- WoW angles: 0 = +x (north), counter-clockwise toward +y (west) = turning left.
local TWO_PI = 2 * math.pi

local function wrap(a)
    a = (a + math.pi) % TWO_PI
    if a < 0 then a = a + TWO_PI end
    return a - math.pi
end

local function rate()
    return F.turn_rate or C.turn_rate
end

--- After a timed turn, compare what the heading error became with what it
--- was: (before - after) / duration is the real turn speed. Smoothed, clamped.
local function calibrate(err_after_deg)
    local lt = last_turn
    last_turn = nil
    if not lt or lt.idx ~= idx or math.abs(lt.err) < 30 then return end
    local turned = lt.err - err_after_deg
    if lt.err < 0 then turned = -turned end
    local measured = turned / lt.dur
    if measured < 40 or measured > 400 then return end
    local old = rate()
    F.turn_rate = old * 0.7 + measured * 0.3
    if math.abs(F.turn_rate - old) > 5 then
        L.debug("turn rate calibrated: %.0f deg/s (measured %.0f)", F.turn_rate, measured)
    end
end

--- The point to steer at this frame: the waypoint, or an avoidance aim point.
local function steer_target(t, px, py, pz)
    local pts, n = F.points, #F.points
    if not C.avoid then return pts[idx] end
    AV.refresh(px, py, pz)
    -- corner cutting: aim at the next waypoint as soon as it is in clear view.
    -- 1.5.0: off while the path check runs - skipping ahead would bypass the
    -- checked / shifted 5-yard waypoints, and its server /raycast took 3.5 s
    -- and then killed AmeisenNavigationServer (2026-10-08).
    if idx < n and t >= next_pull and not C.pathcheck then
        next_pull = t + PULL_EVERY
        if AV.can_skip_to(px, py, pz, pts[idx + 1], pts[idx + 1]) then
            idx = idx + 1
            last_turn = nil
        end
    end
    local target = pts[idx]
    if t >= next_advice then
        next_advice = t + ADVICE_EVERY
        local a, why = AV.advise(px, py, pz, target.x, target.y, target.z)
        if a then
            aim.x, aim.y, aim.z = a.x, a.y, a.z
            aim_until = t + AIM_HOLD
            if why ~= aim_reason then
                L.debug("avoid: %s ahead, aiming around it (%d objects cached)", why, AV.cached_count())
            end
            aim_reason = why
        elseif t >= aim_until then
            aim_reason = nil
        end
    end
    if t < aim_until then return aim end
    return target
end

--- Input driver: one frame of steering. Returns true when the last point is reached.
local function drive_input(t, px, py, pz)
    local pts = F.points
    local n = #pts
    -- advance past every waypoint already within reach
    while idx <= n do
        local p = pts[idx]
        local dx, dy = p.x - px, p.y - py
        local reach = idx == n and C.final_threshold or C.waypoint_threshold
        if dx * dx + dy * dy > reach * reach then break end
        idx = idx + 1
        last_turn = nil
    end
    if idx > n then return true end
    if F.paused then
        forward_stop()
        turn_stop()
        sample_x = nil
        return false
    end

    forward_start(t)
    local target = steer_target(t, px, py, pz)

    -- finish a timed turn, then measure afresh
    if turn_dir ~= 0 then
        if t < turn_until then return false end
        turn_stop()
        sample_x, sample_y = px, py
        return false
    end

    if not sample_x then
        sample_x, sample_y = px, py
        return false
    end
    local mx, my = px - sample_x, py - sample_y
    if mx * mx + my * my < MIN_MOVE_FOR_HEADING * MIN_MOVE_FOR_HEADING then return false end

    local heading = math.atan2(my, mx)
    local bearing = math.atan2(target.y - py, target.x - px)
    local err = wrap(bearing - heading)
    local err_deg = math.deg(err)
    sample_x, sample_y = px, py
    if target == pts[idx] then calibrate(err_deg) else last_turn = nil end
    if math.abs(err_deg) > C.heading_tolerance then
        local dur = math.abs(err_deg) / rate()
        turn_start(err > 0 and 1 or -1)
        turn_until = t + dur
        last_turn = (target == pts[idx]) and { err = err_deg, dur = dur, idx = idx } or nil
        L.debug("steer: %s %.0f deg toward %s %d/%d", err > 0 and "left" or "right",
            math.abs(err_deg), target == pts[idx] and "waypoint" or "avoid point", idx, n)
    end
    return false
end

--- Drive one frame. Returns an event name or nil.
function F.tick()
    if not F.active then return nil end
    local t = now()

    if backing_until then
        if t >= backing_until then
            X.call_fn("core.input.move_backward_stop", core.input.move_backward_stop)
            backing_until = nil
            F.set_paused("backoff", false)
            return "backed"
        end
        return nil
    end

    if C.pause_while_casting then
        F.set_paused("cast", X.is_casting())
    elseif pause_reasons.cast then
        F.set_paused("cast", false)
    end

    local px, py, pz = X.position()
    local reached = false
    if F.driver == "input" then
        if px then reached = drive_input(t, px, py, pz) end
    else
        local ok, r = X.call(walker, "process")
        reached = ok and r == true
    end
    local last = F.points[#F.points]

    if px and last then
        local dx, dy, dz = last.x - px, last.y - py, last.z - pz
        local close = dx * dx + dy * dy <= C.final_threshold * C.final_threshold and math.abs(dz) < 6
        if reached or close then
            F.stop()
            return "arrived"
        end
    end

    if F.paused or not px then
        anchor_t = t
        return nil
    end

    -- stuck: no C.stuck_min_move progress for C.stuck_window
    if t >= next_sample then
        next_sample = t + C.stuck_sample
        if not anchor_x then
            reset_anchor()
        else
            local mx, my = px - anchor_x, py - anchor_y
            if mx * mx + my * my >= C.stuck_min_move * C.stuck_min_move then
                anchor_x, anchor_y, anchor_t = px, py, t
            elseif t - anchor_t >= C.stuck_window then
                reset_anchor()
                return "stuck"
            end
        end
    end

    -- deviation: knocked back, feared, slid off a ledge ...
    if t >= next_deviation_check then
        next_deviation_check = t + 1.0
        if F.off_path_distance() > C.deviation_limit then
            return "deviated"
        end
    end

    return nil
end

return F
