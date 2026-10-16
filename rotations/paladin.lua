-- ============================================================================
-- Master Farmer - Grindbot
-- Paladin grind filler + OOC buffs (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.7.1
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHY THE AURA IS A DROPDOWN AND NOT SIX CHECKBOXES
--   The reference grindbot exposes six independent booleans - Devotion, Frost
--   Resistance, Concentration, Shadow Resistance, Retribution, Fire Resistance -
--   and casts the first enabled one whose buff is missing. Only ONE aura can be
--   active at a time, so enabling two makes each cast cancel the other and the
--   bot re-casts forever, burning a GCD every tick and never fighting.
--
--   One dropdown makes that state unrepresentable. This is the single most
--   important thing not to copy from the source.
--
-- SPELL IDS
--   Highest rank first. A wrong ID fails CLOSED but silently, so
--   `mfg_paladin_debug` prints which ones resolved. Run once after any ID edit.
-- ============================================================================

---@type enums
local enums = require("common/enums")

local gui = require("gui")
local resting = require("resting")
local racials = require("racials")
local state = require("state")
local spellbook = require("spellbook")
local auras = require("auras")

local paladin = {}

-- ----------------------------------------------------------------------------
-- HELPERS
-- ----------------------------------------------------------------------------
local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local function health_pct(unit)
    -- 2.306.0 (audit IZI-2): get_health / get_max_health first (game_object.lua,
    -- exact); then get_health_percentage AS IS - izi_sdk.lua:72 says 1..100, so
    -- the old "0..1.5 means a fraction, x100" rescale read a unit at 1% as 100%.
    -- The undeclared health_pct() is no longer read.
    local cur = safe(function() return unit:get_health() end)
    local mx = safe(function() return unit:get_max_health() end)
    if type(cur) == "number" and type(mx) == "number" and mx > 0 then
        return (cur / mx) * 100
    end
    local p = safe(function() return unit:get_health_percentage() end)
    if type(p) == "number" and p == p then
        return p
    end
    return 100
end

-- ----------------------------------------------------------------------------
-- IDENTITY
-- ----------------------------------------------------------------------------
function paladin.class_id()
    return enums.class_id.PALADIN
end

function paladin.label()
    return "Paladin"
end

function paladin.combat_range(player)
    return 5        -- melee
end

function paladin.is_melee(player)
    return true
end

-- A paladin has no ranged filler worth kiting for and heavy armour to stand in.
-- Retreating mid-fight is a straight damage loss, so this never asks for it.
--- How far out to look for something to fight.
---
--- Melee has to walk into contact and then stand still, so a wide
--- scan only drags extra mobs into a fight it cannot kite out of.
function paladin.scan_range(player)
    return 20
end

function paladin.combat_profile()
    return {
        name         = "paladin",
        melee_danger = 0,
        melee_safe   = 0,
        should_retreat = function()
            return false
        end,
    }
end

-- ----------------------------------------------------------------------------
-- RESTING
-- ----------------------------------------------------------------------------
--- Sit down and eat or drink. The thresholds are this class's to choose; the
--- machinery lives in resting.lua so a fix lands once rather than nine times.
function paladin.rest(player)
    return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
end

return paladin
