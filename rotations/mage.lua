-- ============================================================================
-- Master Farmer - Grindbot
-- Mage grind filler + OOC buffs (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.207.0
-- Folder: Master_Farmer_Grindbot
-- Spell rank-1 IDs are registered with spellbook.define. The scanner saves the
-- highest known rank and Class-tab toggles feed izi.advanced_sequence.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

---@type spell_prediction
local spell_prediction = require("common/modules/spell_prediction")

local consumables = require("data/consumables")
local gui = require("gui")
local resting = require("resting")
local racials = require("racials")
local state = require("state")
local spellbook = require("spellbook")
local auras = require("auras")
local pets = require("pets")
local targeting = require("targeting")

local mage = {}

-- Highest rank first. Rest eats and drinks these before any other food.
function mage.preferred_food_ids()
    return consumables.CONJURED_FOOD_ITEM_IDS
end

function mage.preferred_drink_ids()
    return consumables.CONJURED_WATER_ITEM_IDS
end

local function make(ids, track_buff, track_debuff)
    local spell = izi.spell(ids)
    if not spell then
        return nil
    end
    if track_buff and spell.track_buff then
        spell:track_buff(ids)
    end
    if track_debuff and spell.track_debuff then
        spell:track_debuff(ids)
    end
    return spellbook.watch(spell, ids, track_buff, track_debuff)
end

local frostbolt = make({ 27072, 27071, 25304, 10181, 10180, 10179, 8408, 8407, 8406, 7322, 837, 205, 116 })
local fireball = make({ 27070, 25306, 10151, 10150, 10149, 10148, 8402, 8401, 8400, 3140, 145, 143, 133 })
local arcane_missiles = make({ 38704, 38699, 27075, 25345, 10212, 10211, 8417, 8416, 5145, 5144, 5143 })
local fire_blast = make({ 27079, 27078, 10199, 10197, 8413, 8412, 2138, 2137, 2136 })
local scorch = make({ 27074, 27073, 10207, 10206, 10205, 8446, 8445, 8444, 2948 })
local pyroblast = make({ 33938, 27132, 18809, 12526, 12525, 12524, 12523, 12522, 12505, 11366 })
local flamestrike = make({ 27086, 10216, 10215, 8423, 8422, 2121, 2120 })
local blizzard = make({ 27085, 10187, 10186, 10185, 8427, 6141, 10 })
local cone_of_cold = make({ 27087, 10161, 10160, 10159, 8492, 120 })
local frost_nova = make({ 27088, 10230, 6131, 865, 122 }, false, true)
local ice_lance = make({ 30455 })
local blast_wave = make({ 11113 })
local dragons_breath = make({ 33043, 33041, 31661 })
-- Ice Barrier, rank 6 down to rank 1. 33405 is the TBC rank.
--
-- The id list was already here and nothing used it - it was left behind when
-- the Class tab checkbox was removed. It is a maintained self buff now, kept
-- up alongside the armour and Arcane Intellect rather than being a rotation
-- toggle.
local ICE_BARRIER_IDS = { 33405, 27134, 13033, 13032, 13031, 11426 }
local ice_barrier = make(ICE_BARRIER_IDS, true, false)
local mana_shield = make({ 27131, 10193, 10192, 10191, 8495, 8494, 1463 }, true, false)
local ice_armor = make({ 27124, 10220, 10219, 7320, 7302 }, true, false)
local frost_armor = make({ 7301, 7300, 168 }, true, false)
local mage_armor = make({ 27125, 22783, 22782, 6117 }, true, false)
local molten_armor = make({ 30482 }, true, false)
local arcane_intellect = make({ 27126, 10157, 10156, 1461, 1460, 1459 }, true, false)
local icy_veins = make({ 12472 }, true, false)
local evocation = make({ 12051 }, true, false)
local counterspell = make({ 2139 })
local presence_of_mind = make({ 12043 }, true, false)
local combustion = make({ 11129 }, true, false)
local arcane_power = make({ 12042 }, true, false)
local water_elemental = make({ 31687 })
local freeze = make({ 33395 })
local cold_snap = make({ 11958 })
local conjure_water = make(consumables.CONJURE_WATER_SPELL_IDS)
local conjure_food = make(consumables.CONJURE_FOOD_SPELL_IDS)

spellbook.define({
    frostbolt = 116,
    ice_barrier = 11426,
    fireball = 133,
    arcane_missiles = 5143,
    fire_blast = 2136,
    scorch = 2948,
    pyroblast = 11366,
    flamestrike = 2120,
    blizzard = 10,
    cone_of_cold = 120,
    frost_nova = 122,
    ice_lance = 30455,
    blast_wave = 11113,
    dragons_breath = 31661,
    mana_shield = 1463,
    ice_armor = 7302,
    frost_armor = 168,
    mage_armor = 6117,
    molten_armor = 30482,
    arcane_intellect = 1459,
    icy_veins = 12472,
    evocation = 12051,
    counterspell = 2139,
    presence_of_mind = 12043,
    combustion = 11129,
    arcane_power = 12042,
    water_elemental = 31687,
    freeze = 33395,
    cold_snap = 11958,
    conjure_water = 5504,
    conjure_food = 587,
})

local function live(key, fallback)
    local sp = spellbook.spell(key)
    if sp then
        return sp
    end
    return fallback
end

function mage.class_id()
    return enums.class_id.MAGE
end

function mage.label()
    return "Mage"
end

function mage.combat_range(player)
    local bolt = live("frostbolt", frostbolt)
    if bolt and type(bolt.maximum_range) == "number" and bolt.maximum_range > 0 then
        return bolt.maximum_range
    end
    local ball = live("fireball", fireball)
    if ball and type(ball.maximum_range) == "number" and ball.maximum_range > 0 then
        return ball.maximum_range
    end
    return 30
end

-- ============================================================================
-- COMBAT MOVEMENT PROFILE
-- ============================================================================
-- Frost Nova ranks + Frostbite. A target carrying one of these is held in
-- place, which is the moment a mage wants to be walking out of melee.
local FROZEN_IDS = { 27088, 10230, 6131, 865, 122, 33395 }
-- Cone of Cold ranks: a successful cast means the pack is snared right now.
local COLD_IDS   = { 27087, 10161, 10160, 10159, 8492, 120 }

local function id_in(list, id)
    if not id then return false end
    for i = 1, #list do
        if list[i] == id then return true end
    end
    return false
end

local function target_frozen(target)
    if not target then return false end
    local ranks = spellbook.ranks("frost_nova")
    if type(ranks) == "table" and #ranks > 0 then
        if auras.debuff_up(target, ranks) then
            return true
        end
    end
    return auras.debuff_up(target, FROZEN_IDS)
end

--- Rules the combat movement controller applies for this class (§17).
--- It decides WHEN to reposition (range bands, prediction, hysteresis); this
--- only answers WHETHER backing out of melee is the right play right now.
--- How far out to look for something to fight.
---
--- A caster opens from where it is already standing, so a wide
--- scan costs nothing and gives the rotation time to start a cast.
function mage.scan_range(player)
    return 35
end

function mage.combat_profile()
    return {
        name         = "mage",
        melee_danger = 8,       -- inside this, a caster is in trouble
        melee_safe   = 12,      -- walk out to here, then stop (hysteresis)
        should_retreat = function(ctx)
            local target = ctx.target
            if not target then return false end
            -- nothing is actually on us: stand and cast
            if ctx.melee_count < 1 and ctx.distance > 8 then return false end
            -- the target is held: this is the window to walk out
            if target_frozen(target) then return true end
            -- Cone of Cold just landed: the pack is snared, same window
            if ctx.last_spell_age and ctx.last_spell_age <= 2.0 then
                if id_in(COLD_IDS, ctx.last_spell_id) then return true end
                if id_in(FROZEN_IDS, ctx.last_spell_id) then return true end
            end
            return false
        end,
    }
end

-- ----------------------------------------------------------------------------
-- RESTING
-- ----------------------------------------------------------------------------
--- Sit down and eat or drink. The thresholds are this class's to choose; the
--- machinery lives in resting.lua so a fix lands once rather than nine times.
function mage.rest(player)
    return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
end

return mage
