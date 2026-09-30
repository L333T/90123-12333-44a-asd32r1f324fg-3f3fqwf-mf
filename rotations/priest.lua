-- ============================================================================
-- Master Farmer - Grindbot
-- Priest grind filler + OOC buffs (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.143.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Ported from the reference grindbot's Buff_Check Priest branch, which kept
-- only Power Word: Fortitude and Shadowform. That is not enough to level with,
-- so this adds a shadow-leaning filler rotation and self-healing.
--
-- Two things the source does that are NOT copied:
--   * it casts Shadowform unconditionally whenever the spell is known.
--     Shadowform locks out every healing spell, so here it is behind a GUI
--     toggle that defaults OFF.
--   * it has no self-heal at all. A priest that cannot heal itself while
--     grinding dies to any two-pull.
--
-- SPELL IDS
--   Rank arrays are highest-rank-first, matching rotations/mage.lua. A wrong ID
--   fails CLOSED - spellbook reports the spell as not learned and it is simply
--   never cast - but it fails silently, so `mfg_priest_debug` logs which of
--   these the scanner actually resolved. Turn it on once after any ID edit.
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

local priest = {}

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

local mind_flay  = make({ 25387, 18807, 17314, 17313, 17312, 17311, 15407 })

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

local function learned(spell)
    if not spell then
        return false
    end
    if not spellbook.ready() then
        return false
    end
    return spellbook.spell_known(spell)
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
function priest.class_id()
    return enums.class_id.PRIEST
end

function priest.label()
    return "Priest"
end

function priest.combat_range(player)
    local flay = mind_flay
    if flay and type(flay.maximum_range) == "number" and flay.maximum_range > 0 then
        return flay.maximum_range
    end
    return 30
end

-- ----------------------------------------------------------------------------
-- MOVEMENT PROFILE
-- ----------------------------------------------------------------------------
-- The movement controller owns positioning; this only supplies the rules.
-- A priest has no reliable snare or root while levelling, so backing out of
-- melee mid-fight just eats damage with no cast time gained. Retreat only when
-- something is actually on us AND we are healthy enough to survive the walk.
--- How far out to look for something to fight.
---
--- A caster opens from where it is already standing, so a wide
--- scan costs nothing and gives the rotation time to start a cast.
function priest.scan_range(player)
    return 35
end

function priest.combat_profile()
    return {
        name         = "priest",
        melee_danger = 8,
        melee_safe   = 12,
        should_retreat = function(ctx)
            if not ctx or not ctx.target then
                return false
            end
            if ctx.melee_count < 1 and ctx.distance > 8 then
                return false
            end
            local player = ctx.player
            if player and health_pct(player) < 35 then
                return false        -- too low to kite; stand and fight or heal
            end
            return false            -- no snare available: kiting is a net loss
        end,
    }
end

-- ----------------------------------------------------------------------------
-- RESTING
-- ----------------------------------------------------------------------------
--- Sit down and eat or drink. The thresholds are this class's to choose; the
--- machinery lives in resting.lua so a fix lands once rather than nine times.
function priest.rest(player)
    return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
end

return priest
