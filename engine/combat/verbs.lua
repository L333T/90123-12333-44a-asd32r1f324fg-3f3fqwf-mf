-- ============================================================================
-- combat/verbs.lua - HOW a combat move is performed. One function per verb.
-- ============================================================================
-- A rotation never presses a key, never calls Sentinel and never calls
-- movement_handler. It calls registry.add. The engine ticks the registry once
-- per update: the first verb whose when(ctx) returns true is the active move
-- and every other move is idle. When the active when() goes false, this file
-- releases whatever key or walk that verb started, on that same frame.
--
-- Adding a move later is one registry.add block. Changing how every backoff,
-- strafe or chase behaves is an edit to the one function here. A verb's body
-- is never copied into a class file.
--
-- KEY OWNER. Sentinel is stopped before any verb that uses core.input, and
-- only once the walk is older than about a second and the full state is not
-- awaiting_path. movement_handler is facing and the cast pause, nothing else:
-- it does not walk, strafe, blink or chase. Every strafe and move start is
-- paired with its stop. A step is refused when trace_line with the WALK mask
-- hits in that direction. No verb runs while swimming.
-- ============================================================================

local engine = require("engine/astar")

---@type movement_handler
local movement_handler = require("common/utility/movement_handler")

local V = {}

-- ---------------------------------------------------------------------------
-- shared plumbing
-- ---------------------------------------------------------------------------
local MELEE_YARDS = 5           -- combat.lua: at or under this the band is a melee band
local CHASE_BAND = 3            -- ranged: stand this far inside the cast range
local CHASE_GAIN = 2.0
local CHASE_STALL = 10.0
local CHASE_REPATH = 4.0
local CHASE_GAP = 0.75

local BACKPEDAL_JUMP_AT = 0.75
local SHORT_GAP = 3.0           -- yards of back-off a key step can cover

local BLINK_ID = 1953           -- Blink. The engine does not invent other spell ids.
local BLINK_AT, BLINK_END = 0.25, 1.5
local BLINK_AWAY = 15

local STRAFE_MIN, STRAFE_MAX = 0.20, 0.50
local PAUSE_MIN, PAUSE_MAX = 0.06, 0.12

local BACK_JUMP_BACK, BACK_JUMP_AT, BACK_JUMP_GAP = 2.5, 0.5, 4.0

local FLEE_HP, FLEE_N, FLEE_YD, FLEE_TIME, FLEE_GAP = 20, 3, 10, 5.0, 45.0
V.FLEE_HP, V.FLEE_N, V.FLEE_YD = FLEE_HP, FLEE_N, FLEE_YD

local STACKED_YD, UNSTACK_BACK = 1.0, 0.5

local STEP_BEHIND_SHORT = 2.5   -- at or under this a strafe gets there; past it, Sentinel
local STEP_BEHIND_MAX = 4.0     -- s a step-behind window may last

local random = math.random

local function now()
    return engine.now()
end

local function spread(min, max)
    return min + random() * (max - min)
end

local function press(name)
    local f = core.input[name]
    if type(f) == "function" then
        pcall(f)
    end
end

local function unit_pos(unit)
    if not unit then
        return nil
    end
    local okv, valid = pcall(unit.is_valid, unit)
    if not okv or valid ~= true then
        return nil
    end
    local okp, pos = pcall(unit.get_position, unit)
    if not okp or type(pos) ~= "table" or type(pos.x) ~= "number" then
        return nil
    end
    return pos
end

V.unit_pos = unit_pos

local function unit_guid(unit)
    if not unit then
        return nil
    end
    local okv, valid = pcall(unit.is_valid, unit)
    if not okv or valid ~= true then
        return nil
    end
    local okg, guid = pcall(unit.get_guid, unit)
    if okg and type(guid) == "string" and guid ~= "" then
        return guid
    end
    return nil
end

V.unit_guid = unit_guid

local function same_unit(a, b)
    local ga, gb = unit_guid(a), unit_guid(b)
    return ga ~= nil and ga == gb
end

--- Are the movement keys ours to press? Sentinel is stopped first, and only
--- when the walk is old enough and not awaiting its path.
local function take_keys(reason)
    if not engine.travel_moving() and not engine.is_travelling() then
        return true
    end
    if not engine.travel_can_stop() then
        return false
    end
    engine.cancel(reason)              -- a planned leg, if one is running
    engine.travel_stop(reason)
    return true
end

V.take_keys = take_keys

-- ---------------------------------------------------------------------------
-- backpedal: the one backward key step every retreat verb runs on. Refuses
-- water, as it always has.
-- ---------------------------------------------------------------------------
local bp = { until_t = nil, jump_at = nil, jumped = false, forward = false }

local function backpedal(seconds, jump_at, ctx)
    if bp.until_t then
        return false
    end
    if ctx and ctx.swimming then
        return false
    end
    if not take_keys("backpedal") then
        return false
    end
    seconds = tonumber(seconds) or 1.5
    local t = now()
    bp.until_t = t + seconds
    bp.jump_at = t + (tonumber(jump_at) or BACKPEDAL_JUMP_AT)
    bp.jumped = false
    bp.forward = false
    press("move_backward_start")
    return true
end

--- The blink run-up uses the same timer, forward instead of backward.
local function runpedal(seconds, ctx)
    if bp.until_t then
        return false
    end
    if ctx and ctx.swimming then
        return false
    end
    if not take_keys("blink") then
        return false
    end
    bp.until_t = now() + (tonumber(seconds) or BLINK_END)
    bp.jump_at, bp.jumped = nil, true
    bp.forward = true
    press("move_forward_start")
    return true
end

local function backpedal_stop()
    if not bp.until_t then
        return
    end
    bp.until_t, bp.jump_at, bp.jumped = nil, nil, false
    if bp.forward then
        press("move_forward_stop")
    else
        press("move_backward_stop")
    end
    bp.forward = false
end

local function backpedal_tick(t)
    if not bp.until_t then
        return false
    end
    if bp.jump_at and not bp.jumped and t >= bp.jump_at then
        bp.jumped = true
        press("jump")
    end
    if t >= bp.until_t then
        backpedal_stop()
        return false
    end
    return true
end

V.backpedal = backpedal
V.backpedal_stop = backpedal_stop
V.backpedaling = function()
    return bp.until_t ~= nil
end

--- The player's facing, 0 when it cannot be read.
local function facing(ctx)
    local me = ctx and ctx.player or nil
    if not me then
        return 0
    end
    local okv, valid = pcall(me.is_valid, me)
    if not okv or valid ~= true then
        return 0
    end
    local okr, r = pcall(me.get_rotation, me)
    if okr and type(r) == "number" and r == r then
        return r
    end
    return 0
end

-- ===========================================================================
-- close - walk to the target with Sentinel until in the band, then stop and face
-- ===========================================================================
local close = { guid = nil, latched = false, best = nil, best_t = 0, chase_t = 0,
                goal = nil, unreachable = nil }

--- The band: melee is the configured melee distance held to +1 yard; ranged is
--- CHASE_BAND inside the cast range, held out to the full range.
-- ctx.cast_range is the range the registry read out of the spell book this
-- tick; cfg.range is only the fallback for when the game has no answer.
local function band(cfg, ctx)
    local yards = tonumber(ctx and ctx.cast_range) or tonumber(cfg and cfg.range) or MELEE_YARDS
    if yards < 1 then
        yards = MELEE_YARDS
    end
    if yards <= MELEE_YARDS then
        return yards, yards + 1
    end
    return math.max(MELEE_YARDS, yards - CHASE_BAND), yards
end

local function close_reset(t)
    close.latched, close.best, close.best_t = false, nil, t
    close.goal, close.chase_t = nil, 0
end

--- The band, as a plain question with no state: in sight and inside the hold
--- distance. close keeps its own latch for the chase hysteresis; this is what
--- orbit and step_behind are gated on, so they work on their first frame.
function V.in_band(ctx, range)
    if not ctx or ctx.target == nil or ctx.distance == nil then
        return false
    end
    -- ctx is not passed on: the range asked for here is the one that decides
    local _, hold = band({ range = range }, nil)
    if ctx.distance > hold then
        return false
    end
    return engine.has_sight(ctx.target)
end

function V.close_in_position()
    return close.latched == true
end

--- True when this target has been given up on as unreachable.
function V.close_unreachable(unit)
    local g = unit_guid(unit)
    return g ~= nil and close.unreachable == g
end

V.close = {
    start = function(ctx, cfg)
        close_reset(now())
        close.guid = unit_guid(ctx.target)
        return true
    end,

    tick = function(ctx, cfg)
        local t = now()
        local target = ctx.target
        local pos = unit_pos(target)
        if not pos then
            return false
        end
        local guid = unit_guid(target)
        if guid ~= close.guid then
            close.guid = guid
            close_reset(t)
        end

        local reach, hold = band(cfg, ctx)
        local sight = engine.has_sight(target)
        local range = ctx.distance or 1e9

        -- in the band, in sight: the walk stops and the player faces the target
        if sight and (range <= reach or (close.latched and range <= hold)) then
            if engine.travel_moving() and engine.travel_can_stop() then
                engine.travel_stop("in range")
            end
            close.latched = true
            close.best, close.best_t = range, t
            pcall(movement_handler.look_at_target, movement_handler, nil, nil, target)
            return true
        end
        close.latched = false

        -- no way closer: no CHASE_GAIN yd of progress for CHASE_STALL s
        if close.best == nil or range < (close.best - CHASE_GAIN) then
            close.best, close.best_t = range, t
        elseif (t - close.best_t) >= CHASE_STALL then
            close.unreachable = guid
            close.best, close.best_t = range, t
            if engine.travel_can_stop() then
                engine.travel_stop("unreachable")
            end
            return false
        end

        -- closing. Out of line of sight it keeps closing until SIGHT is clear.
        -- Sentinel paths to the unit itself. A chase is not what the HPA*
        -- planner is for: the planner shapes a travel leg, and re-planning a
        -- polyline every CHASE_GAP at a moving mob would only stutter.
        local moved = true
        if close.goal then
            local dx, dy = close.goal.x - pos.x, close.goal.y - pos.y
            moved = math.sqrt(dx * dx + dy * dy) > CHASE_REPATH
        end
        local walk_old = (not engine.travel_moving()) or engine.travel_age() >= 1.0
        if not engine.travel_moving() or (walk_old and moved and (t - close.chase_t) >= CHASE_GAP) then
            close.chase_t = t
            close.goal = pos
            engine.travel_to(pos, nil)
        end
        return true
    end,

    stop = function()
        -- the latch is a band fact and is recomputed in tick(); only the keys
        -- and the walk are given up here
        close.goal, close.chase_t = nil, 0
        if engine.travel_moving() and engine.travel_can_stop() then
            engine.travel_stop("close released")
        end
    end,
}

-- ===========================================================================
-- face - movement_handler only
-- ===========================================================================
V.face = {
    start = function(ctx)
        if not ctx.target then
            return false
        end
        pcall(movement_handler.look_at_target, movement_handler, nil, nil, ctx.target)
        return true
    end,

    tick = function(ctx)
        if not unit_pos(ctx.target) then
            return false
        end
        pcall(movement_handler.look_at_target, movement_handler, nil, nil, ctx.target)
        return true
    end,

    stop = function()
        pcall(movement_handler.unlock_look_at, movement_handler)
    end,
}

-- ===========================================================================
-- backoff - outward to the verb's safe distance
-- ===========================================================================
-- A short gap is a backward key step with the WALK mask checked behind the
-- player. A longer gap is one Sentinel move_to to a point at that distance
-- from the enemy with SIGHT clear, then a face. The jump during the backpedal
-- is the optional jump_at argument the backpedal already takes.
-- ---------------------------------------------------------------------------
local backoff = { walking = false, t0 = 0 }

local function safe_distance(cfg, ctx)
    return tonumber(cfg and cfg.melee_safe) or tonumber(ctx and ctx.melee_safe) or 12
end

V.backoff = {
    start = function(ctx, cfg)
        if ctx.swimming then
            return false
        end
        local target = ctx.target
        local pos = unit_pos(target)
        if not pos then
            return false
        end
        local safe = safe_distance(cfg, ctx)
        local gap = safe - (ctx.distance or 0)
        if gap <= 0 then
            return false            -- already out past melee_safe: the hysteresis holds
        end
        backoff.walking, backoff.t0 = false, now()

        if gap <= SHORT_GAP then
            -- behind the player, WALK mask
            local back = facing(ctx) + math.pi
            if not engine.step_is_clear(back, math.max(1, gap)) then
                return false
            end
            return backpedal(math.max(0.4, gap / 4), cfg and cfg.jump_at or nil, ctx)
        end

        local me = ctx.player
        local from = unit_pos(me)
        if not from then
            return false
        end
        local point = engine.pick_away_point(from, { pos }, safe, target)
        if not point then
            return false
        end
        if not engine.travel_to(point, nil) then
            return false
        end
        backoff.walking = true
        pcall(movement_handler.look_at_target, movement_handler, nil, nil, target)
        return true
    end,

    tick = function(ctx, cfg)
        local t = now()
        if backoff.walking then
            if ctx.target then
                pcall(movement_handler.look_at_target, movement_handler, nil, nil, ctx.target)
            end
            if (ctx.distance or 0) >= safe_distance(cfg, ctx) then
                if engine.travel_can_stop() then
                    engine.travel_stop("backoff done")
                end
                backoff.walking = false
                return false
            end
            return engine.travel_moving()
        end
        return backpedal_tick(t)
    end,

    stop = function()
        backpedal_stop()
        if backoff.walking then
            backoff.walking = false
            if engine.travel_can_stop() then
                engine.travel_stop("backoff released")
            end
        end
        pcall(movement_handler.unlock_look_at, movement_handler)
    end,
}

-- ===========================================================================
-- back_jump - backward 2.5 s, a jump 0.5 s in, at most once every 4 s
-- ===========================================================================
local back_jump = { t = -1e9 }

V.back_jump = {
    start = function(ctx)
        local t = now()
        if (t - back_jump.t) < BACK_JUMP_GAP then
            return false
        end
        if ctx.swimming then
            return false
        end
        local back = facing(ctx) + math.pi
        if not engine.step_is_clear(back, 2) then
            return false
        end
        if not backpedal(BACK_JUMP_BACK, BACK_JUMP_AT, ctx) then
            return false
        end
        back_jump.t = t
        return true
    end,

    tick = function()
        return backpedal_tick(now())
    end,

    stop = function()
        backpedal_stop()
    end,
}

-- ===========================================================================
-- blink_away - face away, run, Blink at 0.25 s, stop at 1.5 s, face again
-- ===========================================================================
-- The away point is rejected when WALK hits: a blink into a wall is worse
-- than a back-off, so start() returns false and the registry falls through to
-- the backoff registration.
-- ---------------------------------------------------------------------------
local blink = { t0 = 0, cast = false, away = nil, enemy = nil }

V.blink_away = {
    start = function(ctx)
        if ctx.swimming then
            return false
        end
        local enemy = ctx.target
        local ep = unit_pos(enemy)
        local from = unit_pos(ctx.player)
        if not ep or not from then
            return false
        end
        local dx, dy = from.x - ep.x, from.y - ep.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 0.05 then
            dx, dy, len = 1, 0, 1              -- standing on it: any direction
        end
        local angle = math.atan2(dy, dx)
        if not engine.step_is_clear(angle, BLINK_AWAY) then
            return false                        -- WALK hits: back off instead
        end
        local away = engine.pick_away_point(from, { ep }, BLINK_AWAY, nil)
        if not away then
            return false
        end
        if not runpedal(BLINK_END, ctx) then
            return false
        end
        blink.t0, blink.cast = now(), false
        blink.away, blink.enemy = away, enemy
        pcall(movement_handler.look_at_position, movement_handler, BLINK_END, nil, away)
        return true
    end,

    tick = function()
        local t = now()
        if not blink.cast and (t - blink.t0) >= BLINK_AT then
            blink.cast = true
            if blink.away then
                pcall(movement_handler.look_at_position, movement_handler, BLINK_END, nil, blink.away)
            end
            local me = core.object_manager.get_local_player()
            if me then
                local okv, valid = pcall(me.is_valid, me)
                if okv and valid == true then
                    pcall(core.input.cast_target_spell, BLINK_ID, me)
                end
            end
        end
        if not backpedal_tick(t) then
            if blink.enemy and unit_pos(blink.enemy) then
                pcall(movement_handler.look_at_target, movement_handler, nil, nil, blink.enemy)
            end
            blink.away, blink.enemy = nil, nil
            return false
        end
        return true
    end,

    stop = function()
        backpedal_stop()
        if blink.enemy and unit_pos(blink.enemy) then
            pcall(movement_handler.look_at_target, movement_handler, nil, nil, blink.enemy)
        end
        blink.away, blink.enemy, blink.cast = nil, nil, false
    end,
}

-- ===========================================================================
-- orbit - the Rogue / Warrior micro-strafe, only while close reports in_position
-- ===========================================================================
-- step_behind borrows this holder for its own short side step, so there is one
-- release path for the strafe keys and no second strafe function anywhere.
--
-- Right tap: strafe_right_start, move_forward_start, then move_forward_stop,
-- strafe_right_stop. Left tap: move_forward_start, strafe_left_start, then
-- move_forward_stop, strafe_left_stop. The forward key is what keeps the
-- player in the swing band. A tap whose WALK trace hits is skipped. The moment
-- in_position is false both keys go on that frame, so close can chase.
-- ---------------------------------------------------------------------------
local orbit = { held = false, dir = 0, until_t = nil, pause_until = nil }

local function orbit_release(t)
    if not orbit.held then
        return
    end
    press("move_forward_stop")
    if orbit.dir > 0 then
        press("strafe_right_stop")
    else
        press("strafe_left_stop")
    end
    orbit.held, orbit.until_t = false, nil
    orbit.pause_until = t and (t + spread(PAUSE_MIN, PAUSE_MAX)) or nil
end

local function orbit_tap(ctx, t)
    local right = orbit.dir <= 0
    local side = facing(ctx) + (right and 1.5708 or -1.5708)
    if not engine.step_is_clear(side, 1.5) then
        -- that direction is walled: try the other one next tick
        orbit.dir = right and -1 or 1
        return false
    end
    if right then
        press("strafe_right_start")
        press("move_forward_start")
        orbit.dir = 1
    else
        press("move_forward_start")
        press("strafe_left_start")
        orbit.dir = -1
    end
    orbit.held = true
    orbit.until_t = t + spread(STRAFE_MIN, STRAFE_MAX)
    return true
end

V.orbit = {
    start = function(ctx)
        if ctx.swimming or ctx.in_position ~= true then
            return false
        end
        if not take_keys("orbit") then
            return false
        end
        orbit.pause_until = nil
        return true
    end,

    tick = function(ctx)
        local t = now()
        if ctx.in_position ~= true or ctx.swimming then
            orbit_release(nil)
            return false
        end
        if ctx.target then
            pcall(movement_handler.look_at_target, movement_handler, nil, nil, ctx.target)
        end
        if orbit.held then
            if t >= orbit.until_t then
                orbit_release(t)
            end
            return true
        end
        if orbit.pause_until and t < orbit.pause_until then
            return true
        end
        orbit_tap(ctx, t)
        return true
    end,

    stop = function()
        orbit_release(nil)
        orbit.pause_until = nil
    end,
}

--- A reload mid-tap would leave a key down: let go of all three once on load.
press("move_forward_stop")
press("strafe_right_stop")
press("strafe_left_stop")

-- ===========================================================================
-- step_behind - one melee reach behind the target, opposite its facing
-- ===========================================================================
local behind = { t0 = 0, walking = false }

local function behind_point(target, reach)
    local pos = unit_pos(target)
    if not pos then
        return nil
    end
    local okr, r = pcall(target.get_rotation, target)
    if not okr or type(r) ~= "number" or r ~= r then
        return nil
    end
    local bx = pos.x - math.cos(r) * reach
    local by = pos.y - math.sin(r) * reach
    local bz = engine.mesh_z(bx, by, pos.z + 1) or pos.z
    return { x = bx, y = by, z = bz }
end

V.step_behind = {
    start = function(ctx, cfg)
        if ctx.swimming then
            return false
        end
        local reach = tonumber(cfg and cfg.reach) or MELEE_YARDS
        local point = behind_point(ctx.target, reach)
        local from = unit_pos(ctx.player)
        if not point or not from then
            return false
        end
        behind.t0, behind.walking = now(), false
        local dx, dy = point.x - from.x, point.y - from.y
        local gap = math.sqrt(dx * dx + dy * dy)
        if gap > STEP_BEHIND_SHORT then
            if not engine.travel_to(point, nil) then
                return false
            end
            behind.walking = true
        else
            local angle = math.atan2(dy, dx)
            if not engine.step_is_clear(angle, gap) then
                return false
            end
            if not take_keys("step behind") then
                return false
            end
            -- a short step there: the side key that points at the spot
            local side = angle - facing(ctx)
            while side > math.pi do side = side - 2 * math.pi end
            while side < -math.pi do side = side + 2 * math.pi end
            if side >= 0 then
                press("strafe_left_start")
                orbit.dir = -1
            else
                press("strafe_right_start")
                orbit.dir = 1
            end
            orbit.held = true
            orbit.until_t = now() + STRAFE_MAX
        end
        pcall(movement_handler.look_at_target, movement_handler, nil, nil, ctx.target)
        return true
    end,

    tick = function(ctx)
        local t = now()
        if ctx.target then
            pcall(movement_handler.look_at_target, movement_handler, nil, nil, ctx.target)
        end
        if ctx.behind == true or (t - behind.t0) > STEP_BEHIND_MAX then
            return false
        end
        if orbit.held then
            if t >= orbit.until_t then
                orbit_release(nil)
                return false
            end
            return true
        end
        if behind.walking then
            return engine.travel_moving()
        end
        return false
    end,

    stop = function()
        orbit_release(nil)
        if behind.walking then
            behind.walking = false
            if engine.travel_can_stop() then
                engine.travel_stop("step behind released")
            end
        end
    end,
}

-- ===========================================================================
-- flee - 20% health with 3+ enemies inside 10 yd, for about 5 s, once per 45 s
-- ===========================================================================
-- Nothing is faced and nothing is attacked while it runs. The away point is
-- weighted with the outdoor cliff and steep terms, so the flee does not leave
-- over a cliff.
-- ---------------------------------------------------------------------------
local flee = { until_t = 0, t = -1e9, running = false }

function V.fleeing()
    return flee.running == true and now() < flee.until_t
end

V.flee = {
    start = function(ctx)
        local t = now()
        if (t - flee.t) < FLEE_GAP then
            return false
        end
        local from = unit_pos(ctx.player)
        if not from then
            return false
        end
        local threats = {}
        local list = ctx.enemies
        if type(list) == "table" then
            for i = 1, #list do
                local p = unit_pos(list[i])
                if p then
                    local dx, dy = p.x - from.x, p.y - from.y
                    if math.sqrt(dx * dx + dy * dy) <= FLEE_YD then
                        threats[#threats + 1] = p
                    end
                end
            end
        end
        if #threats < FLEE_N then
            return false
        end
        local point = engine.pick_away_point(from, threats, FLEE_YD + 10, nil)
        if not point then
            return false
        end
        if not engine.travel_to(point, nil) then
            return false
        end
        flee.t, flee.until_t, flee.running = t, t + FLEE_TIME, true
        pcall(movement_handler.unlock_look_at, movement_handler)
        return true
    end,

    tick = function()
        if now() >= flee.until_t then
            flee.running = false
            return false
        end
        return true
    end,

    stop = function()
        flee.running = false
        if engine.travel_moving() and engine.travel_can_stop() then
            engine.travel_stop("flee over")
        end
    end,
}

-- ===========================================================================
-- unstack - another unit stacked inside the stacked-yards threshold
-- ===========================================================================
V.unstack = {
    start = function(ctx)
        if ctx.swimming then
            return false
        end
        local from = unit_pos(ctx.player)
        if not from then
            return false
        end
        local stacked = false
        local list = ctx.enemies
        if type(list) == "table" then
            for i = 1, #list do
                local p = unit_pos(list[i])
                if p and not same_unit(list[i], ctx.player) then
                    local dx, dy = p.x - from.x, p.y - from.y
                    if math.sqrt(dx * dx + dy * dy) < STACKED_YD then
                        stacked = true
                        break
                    end
                end
            end
        end
        if not stacked then
            return false
        end
        -- jump_at past the end of the step: a plain step back, no jump
        return backpedal(UNSTACK_BACK, UNSTACK_BACK + 10, ctx)
    end,

    tick = function()
        return backpedal_tick(now())
    end,

    stop = function()
        backpedal_stop()
    end,
}

V.STACKED_YD = STACKED_YD

-- ---------------------------------------------------------------------------
-- Release everything. Called by the registry when no verb is active, and on
-- unload.
-- ---------------------------------------------------------------------------
function V.release_all()
    backpedal_stop()
    orbit_release(nil)
    engine.release_stuck_key()
    pcall(movement_handler.unlock_look_at, movement_handler)
    close.goal = nil
    backoff.walking, behind.walking, flee.running = false, false, false
end

return V
