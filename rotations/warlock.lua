-- ============================================================================
-- Master Farmer - Grindbot
-- Warlock grind filler + OOC buffs (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.150.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Pet handling lives in pets.lua, shared with the Hunter.
--
-- SUMMONING COSTS A SHARD
--   Every summon except the Imp consumes a Soul Shard. The reference bot
--   summons without checking, so a shardless Warlock burns a GCD on a failing
--   cast every tick forever. can_summon() gates on the shard count, and the Imp
--   - which is free - is the fallback rather than the last resort.
--
-- ARMOUR IS ONE SLOT, NOT THREE
--   Fel Armor, Demon Armor and Demon Skin are the same buff slot. The source
--   tests each independently, so with two enabled they overwrite each other
--   every tick. Here the best known one is chosen and the others are not tried.
--
-- SPELL IDS
--   Highest rank first; mfg_warlock_debug prints what actually resolved.
-- ============================================================================

---@type enums
local enums = require("common/enums")

local gui = require("gui")
local resting = require("resting")
local racials = require("racials")
local pets = require("pets")
local state = require("state")
local spellbook = require("spellbook")
local auras = require("auras")

local warlock = {}

-- ----------------------------------------------------------------------------
-- IDENTITY
-- ----------------------------------------------------------------------------
function warlock.class_id() return enums.class_id.WARLOCK end
function warlock.label() return "Warlock" end
function warlock.combat_range(player) return 30 end

-- The pet holds threat, so backing out is usually a loss of cast time for
-- nothing. Retreat only when something is actually on US and the pet is not
-- there to take it back.
--- How far out to look for something to fight.
---
--- A caster opens from where it is already standing, so a wide
--- scan costs nothing and gives the rotation time to start a cast.
function warlock.scan_range(player)
    return 35
end

function warlock.combat_profile()
    return {
        name         = "warlock",
        melee_danger = 8,
        melee_safe   = 12,
        should_retreat = function(ctx)
            if not ctx or not ctx.target then return false end
            if ctx.melee_count < 1 then return false end
            return not pets.alive(ctx.player)
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
function warlock.rest(player)
    return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
end

return warlock
