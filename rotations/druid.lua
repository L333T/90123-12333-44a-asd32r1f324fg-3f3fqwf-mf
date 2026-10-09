-- ============================================================================
-- Master Farmer - Grindbot
-- Druid grind filler + OOC buffs (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.245.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- The reference grindbot's Druid branch is two lines - Mark of the Wild and
-- Thorns - with no rotation at all. This adds a balance (caster) filler.
--
-- WHY CASTER AND NOT FERAL
--   Cat/Bear levelling is stronger, but it needs form management: every heal
--   and every caster spell requires shifting out, shifting costs mana and a
--   GCD, and a bot that mis-sequences a shift spends the fight in the wrong
--   form doing nothing. Moonfire + Wrath is weaker per kill and far more
--   robust, which is the right trade for an unattended grinder. Feral can be
--   added later behind its own toggle once form state is readable.
--
-- SPELL IDS
--   Highest rank first. A wrong ID fails CLOSED - spellbook reports the spell
--   as unknown and it is never cast - but silently, so `mfg_druid_debug` prints
--   which ones resolved. Run it once after any ID edit.
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

local druid = {}

-- ----------------------------------------------------------------------------
-- SPELLS  (highest rank first)
-- ----------------------------------------------------------------------------
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

local ROOTS_IDS     = { 26989, 9853, 9852, 5196, 5195, 1062, 339 }

local wrath        = make({ 26985, 26984, 9912, 8905, 6780, 5180, 5179, 5178, 5177, 5176 })
local entangling   = make(ROOTS_IDS, false, true)

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

local function as_pct(value)
    if type(value) ~= "number" then
        return nil
    end
    if value >= 0 and value <= 1.5 then
        return value * 100
    end
    return value
end

local function health_pct(unit)
    local pct = as_pct(safe(function() return unit:health_pct() end))
    if pct then
        return pct
    end
    -- unit:health_current() does not exist on this API. The working names are
    -- get_health_percentage (which health_pct above aliases) and the
    -- get_health / get_max_health pair, so the fallback uses those. Before
    -- 1.6.3 every step of this fallback threw, and a health_pct that ever
    -- failed would have left the unit looking permanently at full health.
    local pct = as_pct(safe(function() return unit:get_health_percentage() end))
    if pct then
        return pct
    end
    local cur = safe(function() return unit:get_health() end)
    local mx = safe(function() return unit:get_max_health() end)
    if type(cur) == "number" and type(mx) == "number" and mx > 0 then
        return (cur / mx) * 100
    end
    return 100
end

-- ----------------------------------------------------------------------------
-- IDENTITY
-- ----------------------------------------------------------------------------
function druid.class_id()
    return enums.class_id.DRUID
end

function druid.label()
    return "Druid"
end

function druid.combat_range(player)
    if wrath and type(wrath.maximum_range) == "number" and wrath.maximum_range > 0 then
        return wrath.maximum_range
    end
    return 30
end

-- Entangling Roots is a real root, so unlike the Priest this class CAN kite.
-- Retreat only in the window where the target is actually held, otherwise
-- walking away just donates free melee swings.
--- How far out to look for something to fight.
---
--- Melee has to walk into contact and then stand still, so a wide scan just
--- drags extra mobs into a fight it cannot kite out of. At range the pull
--- starts from where the bot is already standing, so the extra warning is
--- free. This class does both, so the scan follows the same toggle its
--- combat range does.
--- Melee while in Cat or Bear form (2.151.0). This read a "cat_form" GUI
--- toggle that was never registered, so it was always false; the form the
--- druid is actually in decides now (GetShapeshiftFormID: 1 Cat, 5 Bear,
--- 8 Dire Bear), and the druid's melee distance slider applies in form.
local MELEE_FORMS = { [1] = true, [5] = true, [8] = true }

function druid.is_melee(player)
    local form = safe(function() return core.spell_book.get_shapeshift_form_id() end)
    return MELEE_FORMS[form] == true
end

function druid.scan_range(player)
    if druid.is_melee(player) then
        return 20
    end
    return 35
end

function druid.combat_profile()
    return {
        name         = "druid",
        melee_danger = 8,
        melee_safe   = 14,
        should_retreat = function(ctx)
            if not ctx or not ctx.target then
                return false
            end
            if ctx.melee_count < 1 and ctx.distance > 8 then
                return false
            end
            -- Rooted: step out of reach. (This also required an "entangling"
            -- GUI toggle that no longer exists - 2.151.0; the Spells tab
            -- decides whether Roots is cast at all.)
            return auras.debuff_up(ctx.target, ROOTS_IDS)
        end,
    }
end

-- ----------------------------------------------------------------------------
-- RESTING
-- ----------------------------------------------------------------------------
--- Sit down and eat or drink. The thresholds are this class's to choose; the
--- machinery lives in resting.lua so a fix lands once rather than nine times.
function druid.rest(player)
    return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
end

return druid
