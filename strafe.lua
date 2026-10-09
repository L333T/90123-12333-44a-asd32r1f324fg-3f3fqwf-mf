-- ============================================================================
-- Master Farmer - Grindbot
-- strafe.lua - Rogue "Strafe Combat": short left / right micro-strafes
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.251.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHAT IT DOES (2.212.0)
--   Rogue only, Spells tab "Strafe Combat" ticked, bot started, in combat:
--   while combat movement says it is IN POSITION on a live target
--   (movement.combat_in_position - the same hysteresis band that decides
--   when combat_engage stops and when it chases), tap the strafe keys
--   RIGHT -> pause -> LEFT -> pause -> RIGHT ... for a fraction of a second
--   each. The two directions cancel out, so the rogue stays in swing range.
--
-- FORWARD + STRAFE TOGETHER (2.232.0)
--   Each tap holds two keys at once, pressed and let go in this order:
--     right: strafe_right_start, move_forward_start ... move_forward_stop, strafe_right_stop
--     left:  move_forward_start, strafe_left_start ... move_forward_stop, strafe_left_stop
--   The forward key keeps the rogue pressed into the target while it side-
--   steps. Taps are 0.10 s longer than before (0.22-0.32 s).
--
-- IT NEVER MOVES THE PLAYER ANYWHERE
--   No positions, no walker, no Sentinel: only core.input.strafe_*_start /
--   _stop and move_forward_start / _stop. The moment the target leaves the band, combat_engage clears its
--   in-position latch and issues the chase; strafe.update runs after the
--   cascade on that same frame, sees the latch gone and lets go of the key.
--   Combat movement then has the player to itself until it is back in
--   position.
--
-- NON-BLOCKING
--   Deadlines, checked once per frame from main.lua's update callback. A held
--   key is always let go: on its deadline, on any gate failing, on a stale
--   instance (main.lua), and once when this module loads (a reload in the
--   middle of a strafe would otherwise leave the key down).
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local strafe = {}

local ROGUE = enums.class_id.ROGUE

-- Short taps: micro-positioning, not travel. 2.232.0: +0.10 s (was 0.12-0.22).
local STRAFE_MIN = 0.22
local STRAFE_MAX = 0.32

local PAUSE_MIN = 0.06
local PAUSE_MAX = 0.12

-- The gates that are not about range (class, setting, started, combat,
-- casting) are read at the bot's own decision rate, not every frame.
local GATE_EVERY = 0.1

local strafe_combat = nil          -- true while a strafe key is held down
local strafe_until = nil           -- core.time() at which the held key is let go
local strafe_pause_until = nil     -- earliest core.time() for the next strafe
local strafe_direction = 0         -- last key pressed: 1 right, -1 left

local gate_ok = false
local gate_next = 0

local random = math.random

-- gui and movement load around this file; the requires stay lazy and only a
-- successful lookup is remembered (the rotation.lua pattern).
local gui_mod = nil
local movement_mod = nil

local function get_gui()
    if gui_mod then return gui_mod end
    local ok, mod = pcall(require, "gui")
    if ok and type(mod) == "table" then gui_mod = mod end
    return gui_mod
end

local function get_movement()
    if movement_mod then return movement_mod end
    local ok, mod = pcall(require, "movement")
    if ok and type(mod) == "table" then movement_mod = mod end
    return movement_mod
end

local function random_range(min, max)
    return min + random() * (max - min)
end

local function start_strafe(now)
    if strafe_combat then
        return
    end

    if strafe_direction <= 0 then
        pcall(core.input.strafe_right_start)
        pcall(core.input.move_forward_start)
        strafe_direction = 1
    else
        pcall(core.input.move_forward_start)
        pcall(core.input.strafe_left_start)
        strafe_direction = -1
    end

    strafe_combat = true
    strafe_until = now + random_range(STRAFE_MIN, STRAFE_MAX)
end

--- Let go of the held key. `now` arms the short pause before the next tap;
--- nil (a gate failed, range was lost) clears it, so a strafe can begin the
--- moment everything holds again.
local function stop_strafe(now)
    if not strafe_combat then
        return
    end

    pcall(core.input.move_forward_stop)
    if strafe_direction > 0 then
        pcall(core.input.strafe_right_stop)
    else
        pcall(core.input.strafe_left_stop)
    end

    strafe_combat = nil
    strafe_until = nil
    strafe_pause_until = now and (now + random_range(PAUSE_MIN, PAUSE_MAX)) or nil
end

--- Everything except range. Cheapest test first: a non-Rogue stops at the
--- class (gui.class_id, synced from the player by gui.sync_player).
local function gate()
    local gui = get_gui()
    if not gui then return false end
    if gui.class_id() ~= ROGUE then return false end
    if gui.is_on("strafe_combat") ~= true then return false end
    -- Rotation Only: the player steers, the bot moves nothing.
    if gui.is_on("rotation_only") == true then return false end
    if gui.is_started() ~= true then return false end

    local ok, me = pcall(izi.me)
    if not ok or not me then return false end
    local okv, valid = pcall(me.is_valid, me)
    if not okv or valid ~= true then return false end
    local okc, in_combat = pcall(me.is_in_combat, me)
    if not okc or in_combat ~= true then return false end
    -- A cast or channel (a bandage) is broken by moving.
    local okb, busy = pcall(me.is_channeling_or_casting, me)
    if okb and busy == true then return false end
    return true
end

--- Called once per frame, after the decision cascade (main.lua).
function strafe.update()
    local now = core.time()
    if now >= gate_next then
        gate_next = now + GATE_EVERY
        gate_ok = gate()
    end

    if not gate_ok then
        if strafe_combat then stop_strafe(nil) end
        strafe_pause_until = nil
        return
    end

    local movement = get_movement()
    if strafe_combat then
        -- Range first: out of the band means combat movement is chasing, so
        -- the key goes now, not at the end of this tap.
        if not movement or movement.combat_in_position() ~= true then
            stop_strafe(nil)
        elseif now >= strafe_until then
            stop_strafe(now)
        end
        return
    end

    if strafe_pause_until and now < strafe_pause_until then
        return
    end
    if movement and movement.combat_in_position() == true then
        start_strafe(now)
    end
end

--- Let go of any held key. Safe to call at any time; does nothing when no
--- key is down.
function strafe.stop()
    stop_strafe(nil)
    gate_ok = false
    gate_next = 0
end

function strafe.active()
    return strafe_combat == true
end

-- A reload mid-strafe would leave a key held down: let go of both once
-- whenever this module loads.
pcall(core.input.move_forward_stop)
pcall(core.input.strafe_right_stop)
pcall(core.input.strafe_left_stop)

return strafe
