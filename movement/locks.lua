-- ============================================================================
-- restedXP_questing
-- movement/locks.lua - rest, cast, channel and loot holds; backpedal
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.17.0
-- ============================================================================
-- HOLDS go through AmeisenNav's own pause (client:pause(reason) /
-- resume(reason) - reasons are counted separately, so a cast hold and a loot
-- hold do not undo each other). AmeisenNav also pauses by itself while the
-- player casts or channels (pause_while_casting); the hold here covers the
-- moment before the cast starts, when moving would cancel it. Each hold has
-- an end time and is lifted by the pulse even if nobody calls release().
--
-- REST halts everything and refuses travel and combat movement until lifted.
--
-- BACKPEDAL (Frost Nova, hunter dead zone, unstacking) walks backwards with
-- the core movement keys for a set time, with an optional jump. While it
-- runs nothing else moves the player (nav refuses).
-- ============================================================================

local R = require("movement/core")
local N = require("movement/nav")

local Lk = {}

local HOLD_MAX = 12.0
local holds = {}               -- reason -> end time
local face_lock = nil

local function handler()
    if face_lock == nil then
        local ok, h = pcall(require, "common/utility/movement_handler")
        face_lock = (ok and h) and h or false
    end
    return face_lock or nil
end

local function hold(reason, seconds)
    seconds = tonumber(seconds) or 1.0
    if seconds > HOLD_MAX then seconds = HOLD_MAX end
    if seconds <= 0 then return end
    if not holds[reason] then N.pause("mf_" .. reason) end
    holds[reason] = R.now() + seconds
end

local function lift(reason)
    if holds[reason] then
        holds[reason] = nil
        N.resume("mf_" .. reason)
    end
end

local function face_pos(pos)
    local x, y, z = R.xyz(pos)
    if not x then return end
    local ok, vec3 = pcall(require, "common/geometry/vector_3")
    local p = (ok and vec3 and vec3.new) and vec3.new(x, y, z) or { x = x, y = y, z = z }
    -- 4.0.4 (R3.1): no look while the walk owns the keys - stopped first
    if N.busy() then N.stop("face for a cast") end
    if N.busy() then return end
    pcall(core.input.look_at, p)        -- audit 2026-10-17: movement_handler is not pumped here
end

--- Hold the walk for a cast of `seconds` and face `unit` (nil = no facing).
function Lk.prepare_cast(unit, seconds)
    hold("cast", seconds)
    if unit then
        local ok, pos = pcall(unit.get_position, unit)
        if ok and pos then face_pos(pos) end
    end
end

function Lk.prepare_channel(unit, seconds)
    Lk.prepare_cast(unit, seconds)
end

--- Hold for a ground-targeted spell at `pos`.
function Lk.prepare_ground(pos, seconds)
    hold("cast", seconds)
    face_pos(pos)
end

function Lk.pause_for_loot(seconds)
    hold("loot", seconds or 2)
end

--- Zygor 1.7.8: a cast / channel / loot hold is on (the walk is paused on purpose).
function Lk.holding() return next(holds) ~= nil end

--- Lift the cast / channel / loot holds (not rest).
function Lk.release()
    lift("cast")
    lift("loot")
end

--- The cast ended early (callbacks.lua): only the cast hold goes.
function Lk.cast_cancelled()
    lift("cast")
end

-- ----------------------------------------------------------------------------
-- rest
-- ----------------------------------------------------------------------------
function Lk.set_resting(on)
    on = on == true
    if on and not R.resting then
        N.stop("rest")
        Lk.backpedal_stop()
    end
    R.resting = on
end

function Lk.is_resting() return R.resting == true end

-- ----------------------------------------------------------------------------
-- backpedal
-- ----------------------------------------------------------------------------
local bp = { jump_at = nil, jumped = false }
local BACKPEDAL_JUMP_AT = 0.75 -- s in: the default jump (Frost Nova backpedal)

local function key(name)
    local f = core.input and core.input[name]
    if type(f) == "function" then pcall(f) end
end

--- Walk backwards for `seconds`, jumping `jump_at` s in (default 0.75 s; a
--- value past `seconds` means no jump).
--- True when started, false when one is already running.
function Lk.backpedal(seconds, jump_at)
    if R.backpedal_until or R.resting then return false end
    seconds = tonumber(seconds) or 1.5
    N.stop("backpedal")
    local t = R.now()
    R.backpedal_until = t + seconds
    bp.jump_at = t + (tonumber(jump_at) or BACKPEDAL_JUMP_AT)
    bp.jumped = false
    key("move_backward_start")
    R.trail("move", "backpedal %.1f s", seconds)
    return true
end

function Lk.backpedal_stop()
    if not R.backpedal_until then return end
    R.backpedal_until = nil
    key("move_backward_stop")
end

function Lk.backpedaling() return R.backpedal_until ~= nil end

--- Per frame: end holds and the backpedal on time.
function Lk.tick(t)
    t = t or R.now()
    for reason, ends in pairs(holds) do
        if t >= ends then lift(reason) end
    end
    if R.backpedal_until then
        if bp.jump_at and not bp.jumped and t >= bp.jump_at then
            bp.jumped = true
            key("jump")
        end
        if t >= R.backpedal_until then Lk.backpedal_stop() end
    end
end

--- Everything off (bot stop, unload).
function Lk.clear()
    for reason in pairs(holds) do lift(reason) end
    Lk.backpedal_stop()
    R.resting = false
    R.npc_until, R.npc_ev_t = nil, nil
end

return Lk
