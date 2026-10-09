-- ============================================================================
-- Master Farmer - Grindbot
-- Shaman grind filler + OOC buffs (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.243.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WEAPON IMBUES - THE BUG NOT COPIED
--   The reference bot tests MainHand_Enchant once, then casts EVERY enabled
--   imbue in sequence without re-checking. Enable two and they overwrite each
--   other on every tick, so the Shaman spends the whole fight re-imbuing and
--   never attacks. Here the imbue is a single CHOICE (a dropdown), and it is
--   only cast when unit:item_has_enchant reports the main hand is bare.
--
--   unit:item_has_enchant is what makes this checkable at all - it was the
--   blocker that kept Shaman out of earlier versions.
--
-- SPELL IDS
--   Highest rank first; mfg_shaman_debug prints what resolved.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local gui = require("gui")
local resting = require("resting")
local racials = require("racials")
local state = require("state")
local spellbook = require("spellbook")
local auras = require("auras")

local shaman = {}

local function make(ids, track_buff, track_debuff)
    local spell = izi.spell(ids)
    if not spell then return nil end
    if track_buff and spell.track_buff then spell:track_buff(ids) end
    if track_debuff and spell.track_debuff then spell:track_debuff(ids) end
    return spellbook.watch(spell, ids, track_buff, track_debuff)
end

local lightning_bolt = make({ 25449, 25448, 15208, 15207, 10392, 10391, 6041, 943, 915, 548, 529, 403 })

-- ----------------------------------------------------------------------------
-- IDENTITY
-- ----------------------------------------------------------------------------
function shaman.class_id() return enums.class_id.SHAMAN end
function shaman.label() return "Shaman" end

function shaman.is_melee(player)
    return false
end

--- Stand at Lightning Bolt range. Melee spells fire on their own once the
--- mob is inside the melee distance; the approach does not walk in to get there.
function shaman.engage_range(player, target)
    local reach = nil
    if lightning_bolt and type(lightning_bolt.maximum_range) == "number"
        and lightning_bolt.maximum_range > 8 then
        reach = lightning_bolt.maximum_range - 1
    end
    if type(reach) ~= "number" or reach < 8 then reach = 30 end
    return reach
end

function shaman.combat_range(player)
    return shaman.engage_range(player, nil)
end

--- How far out to look for something to fight.
---
--- Melee has to walk into contact and then stand still, so a wide scan just
--- drags extra mobs into a fight it cannot kite out of. At range the pull
--- starts from where the bot is already standing, so the extra warning is
--- free. This class does both, so the scan follows the same toggle its
--- combat range does.
-- (2.151.0) These read an "enhancement" GUI toggle removed with the old
-- class checkboxes in 2.142.0; is_melee is the one answer now.
function shaman.scan_range(player)
    if shaman.is_melee(player) then
        return 20
    end
    return 35
end

function shaman.combat_profile()
    local melee = shaman.is_melee(nil)
    return {
        name         = "shaman",
        melee_danger = melee and 0 or 8,
        melee_safe   = melee and 0 or 12,
        -- Enhancement wants to BE in melee, so it never retreats. Elemental has
        -- no snare worth the global, so kiting costs more cast time than it saves.
        should_retreat = function() return false end,
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
function shaman.rest(player)
    return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
end

return shaman
