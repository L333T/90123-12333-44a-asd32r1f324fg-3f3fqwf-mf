-- ============================================================================
-- restedXP_questing
-- movement/pivot.lua - stop and turn on sharp waypoint turns
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.1.3
-- ============================================================================
-- THE RULE (CLAUDE_MOVEMENT_RULES.md, "Sharp turns: stop, turn, go"):
-- AmeisenNav's walkers keep running forward while they turn, so a sharp
-- corner is taken as a wide arc - off the path, into walls and packs. Every
-- frame (movement.pulse) the next point of the walk AmeisenNav is on is
-- compared with the player's facing:
--   * more than ON_DEG off: the walk is held with AmeisenNav's own pause
--     (reason "mf_turn" - a paused walk releases its forward and turn keys
--     and presses nothing until resumed), and the player turns in place on
--     the turn keys toward the point;
--   * within OFF_DEG (or turned past it): the turn keys are released and the
--     walk resumed - AmeisenNav runs on from there;
--   * a turn never lasts more than MAX_S (then the walk resumes anyway).
-- Turn keys only - never look_at, never a second walker. Not while casting,
-- channeling, backpedalling, or with no AmeisenNav walk running.
-- 3.7.1 (crash logs 2026-10-16 18:06): the pause made MasterArthasNav end the
-- walk as "arrived"; the turn was dropped the next frame and a fresh leg was
-- started at once, still facing the wrong way, and held again. Now a turn
-- started is finished toward its point even when the walk ended meanwhile,
-- no new travel leg starts while it runs (R.turning, movement/nav), and a
-- leg younger than movement/nav FRESH_LEG is never held.
-- FACING TRUST: the facing (get_rotation) is only used once it has matched
-- the running direction TRUST_N times (as AmeisenNav's own use_facing does);
-- a client whose facing never matches never pivots.
-- ============================================================================

local R = require("movement/core")
local N = require("movement/nav")

local Pv = {}

Pv.ON_DEG   = 70      -- the next point this far off the facing: stop and turn
Pv.OFF_DEG  = 15      -- turned to within this: walk on
Pv.MAX_S    = 1.5     -- a turn never takes longer
Pv.MIN_DIST = 1.5     -- yd: closer points are never turned to
Pv.GAP_S    = 0.4     -- s after a turn before the next one can start

local REASON = "mf_turn"
local TRUST_N, SAMPLE_YD, MATCH_DEG = 3, 1.5, 25

local active = nil            -- { sign = 1|-1, since = t }
local next_ok = 0
local trust = { ok = 0, bad = 0, x = nil, y = nil, logged = false }
local enabled_fn = nil        -- set by movement.lua (GUI checkbox)

local function wrap(a)
    while a > math.pi do a = a - 2 * math.pi end
    while a < -math.pi do a = a + 2 * math.pi end
    return a
end
Pv.wrap = wrap

local function keys_off()
    pcall(function() core.input.turn_left_stop() end)
    pcall(function() core.input.turn_right_stop() end)
end

---Stop turning and give the walk back (safe to call any time).
function Pv.release(why)
    if not active then return end
    active = nil
    R.turning, R.turn_cancel = false, false
    keys_off()
    N.resume(REASON)
    next_ok = R.now() + Pv.GAP_S
    if why then R.dlog("pivot", "turn done: " .. tostring(why)) end
end

function Pv.is_turning() return active ~= nil end

function Pv.set_enabled_fn(fn) enabled_fn = fn end

local function enabled()
    if type(enabled_fn) ~= "function" then return true end
    local ok, v = pcall(enabled_fn)
    return not ok or v ~= false
end

---The next point of AmeisenNav's walk at least MIN_DIST yd away, or nil.
local function next_point(c, px, py)
    local okp, pts = pcall(c.get_current_path, c)
    local oki, i = pcall(c.get_path_index, c)
    if not okp or type(pts) ~= "table" or #pts == 0 then return nil end
    i = (oki and type(i) == "number" and i >= 1) and math.floor(i) or 1
    for k = i, #pts do
        local p = pts[k]
        if type(p) == "table" and type(p.x) == "number" then
            local dx, dy = p.x - px, p.y - py
            if dx * dx + dy * dy >= Pv.MIN_DIST * Pv.MIN_DIST then return p end
        end
    end
    return nil
end

---Facing trust: compare get_rotation with the direction actually run.
local function learn_trust(px, py, rot)
    if not trust.x then trust.x, trust.y = px, py return end
    local dx, dy = px - trust.x, py - trust.y
    if dx * dx + dy * dy < SAMPLE_YD * SAMPLE_YD then return end
    trust.x, trust.y = px, py
    local err = math.abs(math.deg(wrap(math.atan2(dy, dx) - rot)))
    if err <= MATCH_DEG then
        trust.ok = trust.ok + 1
    elseif err >= 60 then
        trust.bad = trust.bad + 1
        if trust.bad >= 8 and trust.ok == 0 and not trust.logged then
            trust.logged = true
            R.log("sharp-turn stop off: this client's facing does not match the running direction")
        end
    end
end

---Per frame (movement.pulse). Holds the walk and turns in place on a sharp turn.
function Pv.tick(t)
    if R.turn_cancel then                      -- the bot stopped the walk itself
        R.turn_cancel = false
        Pv.release("walk stopped")
    end
    local c = N.client()
    local me = R.me()
    local busy = c ~= nil and N.busy()
    -- a turn in progress is finished even when the walk ended meanwhile
    if not (enabled() and c and me and (busy or active)) or R.backpedal_until or R.resting then
        Pv.release()
        trust.x = nil
        return
    end
    local okc, casting = pcall(function() return me:is_casting_spell() == true or me:is_channelling_spell() == true end)
    if okc and casting == true then
        Pv.release("casting")
        return
    end
    local okm, mounted_taxi = pcall(function() return me:is_flying() end)
    if okm and mounted_taxi == true then Pv.release() return end
    local okp, pos = pcall(function() return me:get_position() end)
    local okr, rot = pcall(function() return me:get_rotation() end)
    if not okp or not pos or not okr or type(rot) ~= "number" then Pv.release() return end

    if not active then learn_trust(pos.x, pos.y, rot) end
    if trust.ok < TRUST_N then return end

    local pt = (busy and next_point(c, pos.x, pos.y)) or (active and active.pt) or nil
    if not pt then
        Pv.release("no point ahead")
        return
    end
    local diff = wrap(math.atan2(pt.y - pos.y, pt.x - pos.x) - rot)

    if active then
        local passed = (diff > 0 and active.sign < 0) or (diff < 0 and active.sign > 0)
        if math.abs(diff) <= math.rad(Pv.OFF_DEG) then
            Pv.release("facing the next point")
        elseif passed then
            Pv.release("turned past it")
        elseif (t - active.since) > Pv.MAX_S then
            Pv.release("time cap")
        end
        return
    end

    if t < next_ok or math.abs(diff) <= math.rad(Pv.ON_DEG) then return end
    if not busy or N.leg_fresh() then return end      -- 3.7.1: never hold a fresh leg
    -- sharp: hold the walk (AmeisenNav lets go of its keys), turn on the spot
    N.pause(REASON)
    pcall(function() core.input.move_forward_stop() end)
    keys_off()
    local left = diff > 0
    if left then
        pcall(function() core.input.turn_left_start() end)
    else
        pcall(function() core.input.turn_right_start() end)
    end
    active = { sign = left and 1 or -1, since = t, pt = { x = pt.x, y = pt.y } }
    R.turning = true
    R.trail("move", "sharp turn %.0f deg %s: stop and turn", math.abs(math.deg(diff)), left and "left" or "right")
    R.dlog("pivot", string.format("sharp turn %.0f deg %s - stop and turn", math.abs(math.deg(diff)),
        left and "left" or "right"))
end

---Test hook: reset everything.
function Pv._reset()
    active, next_ok = nil, 0
    R.turning = false
    trust.ok, trust.bad, trust.x, trust.y, trust.logged = 0, 0, nil, nil, false
end

return Pv
