-- ============================================================================
-- Master Farmer - Grindbot
-- Rogue grind filler (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.267.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- POISONS ARE NOT IMPLEMENTED, AND THIS IS THE REASON
--   Applying a poison is a two-step interaction: use the poison, which puts it
--   on the cursor, then click the weapon slot. The first half exists here
--   (core.input.use_container_item); the second does not. The reflected API
--   reference has no call that targets an inventory slot with a held item -
--   core.input has use_item, use_item_position and use_item_target, none of
--   which take slot 16 or 17.
--
--   unit:item_has_enchant CAN tell us a poison has worn off, so detection is
--   solved and only application is missing. The moment an inventory-slot use
--   appears, this is a small addition.
--
--   Half-implementing it would be worse than leaving it out: the poison would
--   sit on the cursor, and a cursor holding an item blocks other interactions.
--
-- ENERGY IS NOT MANA
--   Energy regenerates on a fixed tick regardless of what you do, so there is
--   no "conserve" state and no drinking. The rotation therefore spends down to
--   a floor and never waits.
--
-- SPELL IDS
--   Highest rank first; mfg_rogue_debug prints what resolved.
-- ============================================================================

---@type enums
local enums = require("common/enums")

local gui = require("gui")
local resting = require("resting")
local racials = require("racials")
local state = require("state")
local spellbook = require("spellbook")
local auras = require("auras")

local rogue = {}

-- ----------------------------------------------------------------------------
-- IDENTITY
-- ----------------------------------------------------------------------------
function rogue.class_id() return enums.class_id.ROGUE end
function rogue.label() return "Rogue" end
function rogue.combat_range(player) return 5 end
function rogue.is_melee(player) return true end

-- Pure melee with no ranged filler: stepping out is a flat DPS loss and the
-- target simply follows. Never retreats.
--- How far out to look for something to fight.
---
--- Melee has to walk into contact and then stand still, so a wide
--- scan only drags extra mobs into a fight it cannot kite out of.
function rogue.scan_range(player)
    -- Throw pull (2.224.0): look as far as Throw reaches.
    local ok, sm = pcall(require, "smart")
    if ok and type(sm) == "table" and type(sm.rogue_can_throw) == "function"
        and sm.rogue_can_throw(player) == true then
        return 30
    end
    return 20
end

--- Engage distance (2.224.0): the throw distance while a Throw pull is under
--- way (stop, throw, wait for the mob), else the Melee attack distance.
function rogue.engage_range(player, target)
    local ok, sm = pcall(require, "smart")
    if ok and type(sm) == "table" and type(sm.rogue_throw_range) == "function" then
        local yd = sm.rogue_throw_range(player, target)
        if type(yd) == "number" then return yd, false end
    end
    local m = 5
    local okg, gui = pcall(require, "gui")
    if okg and type(gui) == "table" and type(gui.slider) == "function" then
        local v = gui.slider("melee_yards", 5)
        if type(v) == "number" then m = v end
    end
    if m < 1 then m = 1 elseif m > 5 then m = 5 end
    return m, true
end

function rogue.combat_profile()
    return {
        name = "rogue", melee_danger = 0, melee_safe = 0,
        should_retreat = function() return false end,
        -- Stealth opener (2.228.0): step into the target's rear arc for Backstab.
        want_behind = function(player, unit)
            local ok, sm = pcall(require, "smart")
            return ok and type(sm) == "table" and type(sm.rogue_wants_behind) == "function"
                and sm.rogue_wants_behind(player, unit) == true
        end,
    }
end

-- ----------------------------------------------------------------------------
-- COMBAT
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- RESTING
-- ----------------------------------------------------------------------------
--- Sit down and eat or drink. The thresholds are this class's to choose; the
--- machinery lives in resting.lua so a fix lands once rather than nine times.
function rogue.rest(player)
    return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
end

return rogue
