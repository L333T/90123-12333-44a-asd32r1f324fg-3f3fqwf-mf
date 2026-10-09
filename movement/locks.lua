-- ============================================================================
-- Master Farmer - Grindbot
-- movement/locks.lua - rest lock and cast / channel / loot locks
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.250.0
-- ============================================================================
-- Locks pause the walker by reason, so a cast finishing can never un-pause a
-- stun or a food break. Releasing a cast lock touches only the cast and loot
-- reasons; rest and restrict are owned by their own callers.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type movement_handler
local handler = require("common/utility/movement_handler")

local K = require("movement/const")
local R = require("movement/rt")
local U = require("movement/util")
local W = require("movement/walker")
local O = require("movement/own")

local OWNER      = K.OWNER
local QUIET_STOP = K.QUIET_STOP

local dlog = U.dlog

local Lk = {}

-- ============================================================================
-- REST LOCK
-- ============================================================================
function Lk.set_resting(on)
    if on == true then
        if not R.rest_lock then
            R.rest_lock = true
            W.set_pause("rest", true)
            W.set_quiet(QUIET_STOP)
            O.halt_all()
            R.cur_owner = OWNER.NONE
            dlog("rest", "resting - movement released")
        end
        return
    end
    if R.rest_lock then
        R.rest_lock = false
        W.set_pause("rest", false)
        dlog("rest", "resting cleared")
    end
end

function Lk.is_resting() return R.rest_lock end

-- ============================================================================
-- BACKPEDAL (2.97.0)
-- ============================================================================
-- A timed walk backwards with the core movement keys (Frost Nova, then back
-- away). While it runs it owns movement outright: the walker and Sentinel are
-- halted first, the walker is paused ("backpedal"), and may_issue / combat
-- engage refuse every other move. It always ends with move_backward_stop -
-- on time, on a rest, on a halt, on death - and normal movement picks up on
-- the next tick.
--
-- JUMP (2.105.0, 0.75 s since 2.110.0): BACKPEDAL_JUMP_AT seconds into the backward walk the player
-- jumps, still moving backward; the jump key is let go (ascend_stop)
-- JUMP_RELEASE later. The backpedal timer itself is unchanged.
local BACKPEDAL_JUMP_AT = 0.75
local JUMP_RELEASE = 0.15

function Lk.backpedal(seconds)
    local t = izi.now()
    if R.backpedal_until then return false end
    O.halt_all()
    W.set_pause("backpedal", true)
    R.backpedal_until = t + (tonumber(seconds) or 3)
    R.backpedal_jump_at = t + BACKPEDAL_JUMP_AT
    R.backpedal_jump_release = nil
    pcall(core.input.move_backward_start)
    dlog("backpedal", string.format("backing off for %.1fs", tonumber(seconds) or 3))
    return true
end

function Lk.backpedal_stop()
    if not R.backpedal_until then return end
    R.backpedal_until = nil
    R.backpedal_jump_at = nil
    if R.backpedal_jump_release then
        R.backpedal_jump_release = nil
        pcall(core.input.ascend_stop)
    end
    pcall(core.input.move_backward_stop)
    W.set_pause("backpedal", false)
    dlog("backpedal", "stopped")
end

--- Called every pulse: ends the backpedal on time (or when a rest begins).
function Lk.backpedal_tick(t)
    if not R.backpedal_until then return false end
    if t >= R.backpedal_until or R.rest_lock then
        Lk.backpedal_stop()
        return false
    end
    if R.backpedal_jump_at and t >= R.backpedal_jump_at then
        R.backpedal_jump_at = nil
        R.backpedal_jump_release = t + JUMP_RELEASE
        pcall(core.input.jump)
        dlog("backpedal", "jump")
    elseif R.backpedal_jump_release and t >= R.backpedal_jump_release then
        R.backpedal_jump_release = nil
        pcall(core.input.ascend_stop)
    end
    return true
end

function Lk.backpedaling()
    return R.backpedal_until ~= nil
end

-- A reload in the middle of a backpedal would leave the key held down: let
-- go of it once whenever this module loads.
pcall(core.input.move_backward_stop)

-- ============================================================================
-- CAST / CHANNEL LOCKS
-- ============================================================================
local function clamp_sec(value, fallback)
    local n = tonumber(value)
    if type(n) ~= "number" or n ~= n or n <= 0 then return fallback end
    if n > 20 then n = n / 1000 end            -- milliseconds were passed
    if n < 0.15 then n = 0.15 elseif n > 12 then n = 12 end
    return n
end

-- HOLD WHILE STILL CASTING (2.240.0). A channel's lock was a fixed 3.2 s
-- (smart.lua takes 3.0 s for every CHANNEL spell): Evocation and Blizzard
-- run 8 s, Arcane Missiles up to 5, so movement came back mid-channel and a
-- waiting combat hop broke it. When the timer fires while the player is
-- still casting or channelling, the pause is renewed and checked again every
-- HOLD_STEP s, up to HOLD_MAX s from the start of the lock.
local HOLD_STEP, HOLD_MAX = 0.25, 12.0

local function still_casting()
    local okp, me = pcall(izi.me)
    if not okp or not me then return false end
    local ok, b = pcall(me.is_channeling_or_casting, me)
    return ok and b == true
end

local function on_unlock_timer(gen)
    if gen ~= R.lock_gen then return end
    if still_casting() and (izi.now() - (R.lock_started or 0)) < HOLD_MAX then
        pcall(handler.pause_movement, handler, HOLD_STEP + 0.25)
        pcall(izi.after, HOLD_STEP, function() on_unlock_timer(gen) end)
        return
    end
    Lk.release()
end

local function arm_unlock(seconds)
    R.lock_gen = R.lock_gen + 1
    local gen = R.lock_gen
    -- one small closure per cast lock (not per frame); it captures only `gen`
    pcall(izi.after, seconds, function() on_unlock_timer(gen) end)
end

--- Release a cast / channel / loot lock. Does not touch the rest or restriction
--- pauses, so finishing a cast cannot un-pause a stun or a food break.
function Lk.release()
    R.lock_gen = R.lock_gen + 1
    pcall(handler.resume_movement, handler)
    pcall(handler.unlock_look_at, handler)
    W.set_pause("cast", false)
    W.set_pause("loot", false)
end

local function begin_lock(sec, light, target, pos)
    R.lock_started = izi.now()
    W.set_pause("cast", true)
    if light then
        pcall(handler.pause_movement_light, handler, sec)
    else
        pcall(handler.pause_movement, handler, sec + 0.5)
    end
    -- The target's position, not the unit (2.72.0) - see Rg.face: the
    -- handler keeps what it is given across frames, and a freed unit there
    -- is a native crash.
    if target and not pos then
        local ok, p = pcall(target.get_position, target)
        if ok and p then pos = p end
    end
    if pos then
        pcall(handler.look_at_position, handler, sec, 0, pos)
    end
    arm_unlock(light and sec or (sec + 0.5))
end

function Lk.prepare_cast(target, duration)
    begin_lock(clamp_sec(duration, 0.5), true, target, nil)
end

function Lk.prepare_channel(target, duration)
    begin_lock(clamp_sec(duration, 3.0), false, target, nil)
end

function Lk.prepare_ground(pos, duration, channel)
    begin_lock(clamp_sec(duration, channel and 3.0 or 0.5), not channel, nil, pos)
end

function Lk.pause_for_loot(duration)
    O.halt_all()
    W.set_pause("loot", true)
    begin_lock(clamp_sec(duration, 0.5), true, nil, nil)
end

-- ============================================================================
-- FAILURE REPORTING
-- ============================================================================
function Lk.last_fail_offmesh()
    return R.last_fail.valid and R.last_fail.offmesh
end

function Lk.last_fail_reason()
    if R.last_fail.valid then return R.last_fail.reason end
    return nil
end

function Lk.clear_fail()
    R.last_fail.valid = false
    -- The off-mesh probe flag was set alongside the failure; it goes with it.
    local ok, Pr = pcall(require, "movement/probe")
    if ok and type(Pr) == "table" then Pr.set_off_mesh(false) end
end

return Lk
