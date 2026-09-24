-- ============================================================================
-- Master Farmer - Grindbot
-- Self-buff upkeep
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.9.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHEN A BUFF IS MAINTAINED
--   The bot must be doing something - rotation only, a grind profile, or a
--   quest profile - and it must not be resting. Those are the conditions the
--   request names, and each one is checked rather than assumed:
--
--     doing something   gui.is_on("rotation_only") or gui.is_started()
--     not resting       healing.is_resting() is false
--
--   Resting matters because eating and drinking break on any cast. A buff
--   refreshed mid-drink costs the whole drink, which is a worse trade than
--   the buff being a few seconds late.
--
-- WHICH BUFFS
--   Whatever is ticked in the Spells tab, which lists everything the scanner
--   filed as a buff. Nothing is hardcoded here: a Mage with Mana Shield ticked
--   gets Mana Shield kept up, and the same code keeps a Shaman's Lightning
--   Shield up, because both arrive as a buff family from the same scan.
--
-- HOW "EXPIRED" IS DECIDED
--   By asking the game, not by timing the cast. A timer of our own drifts,
--   is wrong after a dispel it never hears about, and has to guess a duration
--   per rank.
--
--   The question now includes how long is left, via auras.lua, so a buff is
--   refreshed just BEFORE it runs out rather than just after. Waiting for it
--   to drop meant it was genuinely missing for a tick or two, and the moment
--   a buff is most likely to lapse is mid fight - the moment it was wanted.
--   On a build that cannot report the time left this degrades to exactly the
--   old behaviour.
--
-- ONE AT A TIME
--   One buff per tick, with a gap between. A global cooldown is shared, so
--   firing five buffs in one frame just means four refusals, and the refusals
--   are silent.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local gui = require("gui")
local auras = require("auras")
local picks = require("picks")
local spellbook = require("spellbook")
local state = require("state")

local buffs = {}

local ACT_GAP = 1.2          -- seconds between buff casts
local RETRY_GAP = 6.0        -- how long before re-trying one that did not land

-- How early to refresh a buff, in seconds before it runs out.
--
-- Zero: recast when the player does NOT have the buff, and not before. An
-- early refresh throws away the tail of a buff that is still working, and on
-- a long self buff that is a cast and a global spent for nothing every cycle.
--
-- The anti-spam that matters is elsewhere and does not depend on this: the
-- aura check says the buff is up, ACT_GAP holds a second between any two buff
-- casts, and RETRY_GAP backs off one that would not land. Those three are why
-- a buff is cast once and then left alone.
local REFRESH_LEAD = 0

local last_act = -1e9
local failed_until = {}      -- name -> time before which we do not retry

-- Which buffs are switched on lives in picks.lua, shared with the Spells tab
-- and the rotations. Only the back-off timers are local to this file.

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- TOGGLE STATE
-- ----------------------------------------------------------------------------
-- Delegated to picks.lua. This used to be a second copy of the same table,
-- and two registries of one fact can only drift: the set the Spells tab drew
-- was not always the set this file read.
--
-- A buff is kept up only when it was explicitly switched ON. Unlike a
-- rotation spell there is no sensible default here - buffing everything in
-- the book on sight would be worse than buffing nothing - so untouched
-- counts as off.
function buffs.is_enabled(name)
    return picks.is_enabled(name)
end

local function mark_dirty()
    local ok, settings = pcall(require, "settings")
    if ok and settings and type(settings.mark_dirty) == "function" then
        settings.mark_dirty()
    end
end

function buffs.set_enabled(name, on)
    if type(name) ~= "string" then
        return
    end
    picks.set(name, on)
    failed_until[name] = nil
    mark_dirty()
end

function buffs.toggle(name)
    buffs.set_enabled(name, not buffs.is_enabled(name))
    return buffs.is_enabled(name)
end

--- How many buffs are switched on, for the tab's status line.
function buffs.enabled_count()
    local on = picks.count()
    return on
end

-- ----------------------------------------------------------------------------
-- CONDITIONS
-- ----------------------------------------------------------------------------
--- Is the bot doing something that justifies keeping buffs up?
local function bot_is_working()
    if gui.is_on("rotation_only") then
        return true
    end
    if type(gui.is_started) == "function" and gui.is_started() then
        return true
    end
    return false
end

--- Is the character eating or drinking, by anyone's doing?
---
--- healing.is_resting reports the BOT's own rest flag, which is only set when
--- the bot sat the character down itself. In Rotation Only the bot never
--- rests - the player drives - so that flag is always false, and a buff that
--- happened to drop while the player was eating would be cast straight into
--- the meal and cancel it.
---
--- The food and drink auras are the real answer and cost nothing extra: the
--- aura layer is cached.
local function is_resting()
    local ok, healing = pcall(require, "healing")
    if ok and healing and type(healing.is_resting) == "function" then
        if healing.is_resting() == true then
            return true
        end
    end

    local ok_c, cons = pcall(require, "data/consumables")
    if not ok_c or type(cons) ~= "table" then
        return false
    end
    local player = safe(function() return izi.me() end)
    if not player then
        return false
    end
    if type(cons.FOOD_AURA_IDS) == "table"
        and auras.buff_up(player, cons.FOOD_AURA_IDS) then
        return true
    end
    if type(cons.DRINK_AURA_IDS) == "table"
        and auras.buff_up(player, cons.DRINK_AURA_IDS) then
        return true
    end
    return false
end

--- Does this buff need casting - missing, or nearly out?
--- Every rank is offered, because a lower rank's aura is still the buff.
local function needs_cast(player, fam)
    local ids = fam.ranks
    if type(ids) ~= "table" or #ids == 0 then
        ids = { fam.id }
    end
    return auras.aura_expiring(player, ids, REFRESH_LEAD)
end

-- ----------------------------------------------------------------------------
-- TICK
-- ----------------------------------------------------------------------------
--- Keep the enabled buffs up. Returns true when it cast something, so the
--- caller can hold the rest of its tick.
function buffs.tick(player)
    if not player then
        return false
    end
    if not bot_is_working() then
        return false
    end
    if is_resting() then
        return false
    end

    -- Mounted or already casting: a buff now would either not go off or would
    -- cancel what is going off.
    if safe(function() return player:is_mounted() end) == true then
        return false
    end

    local now = izi.now()
    if (now - last_act) < ACT_GAP then
        return false
    end

    if type(spellbook.ready) == "function" and spellbook.ready() ~= true then
        return false
    end

    local ok_cat, cats = pcall(require, "data/spell_categories")
    local buff_key = (ok_cat and cats and cats.BUFF) or "buff"
    local list = (type(spellbook.category) == "function") and spellbook.category(buff_key) or {}

    for i = 1, #list do
        local fam = list[i]
        local name = fam.name
        if picks.is_enabled(name) then
            local hold = failed_until[name] or 0
            if now >= hold and needs_cast(player, fam) then
                local spell = safe(function() return izi.spell(fam.id) end)
                local cast = false
                if spell then
                    cast = safe(function() return spell:cast_safe(player, name) end) == true
                    if not cast then
                        cast = safe(function() return spell:cast(player, name) end) == true
                    end
                end

                last_act = now
                if cast then
                    state.set_note("Buff", "Casting " .. tostring(name))
                else
                    -- Out of mana, on cooldown, or not castable here. Back off
                    -- rather than retrying every tick and burning the gap on a
                    -- spell that will not go.
                    failed_until[name] = now + RETRY_GAP
                end
                return cast
            end
        end
    end

    return false
end

--- Forget the back-off timers. Called when the bot stops.
function buffs.reset()
    failed_until = {}
end

return buffs
