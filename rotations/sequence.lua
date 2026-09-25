-- ============================================================================
-- Master Farmer - Grindbot
-- rotations/sequence.lua - the damage sequencer, shared by the class rotations
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.18.0
-- ============================================================================
-- mage.lua has routed its damage through izi.advanced_sequence for several
-- versions; the other seven called cast_at straight down a priority list.
-- This is the mage's arrangement, lifted out so the rest can use it:
--
--     the sequence is preferred, because it handles the interesting ordering
--     the class's own priority list is the floor underneath it
--
-- WHY A MODULE AND NOT EIGHT COPIES
--   The scaffolding is about eighty lines of guards, entry filtering and
--   condition building, none of it class-specific. Pasted into seven files it
--   would be seven places to fix the next time the sequencer API moves.
--   resting.lua carries the same note for the same reason: the machinery
--   lives in one file so a fix lands once rather than nine times.
--
-- WHY mage.lua STILL HAS ITS OWN
--   Its sequence carries state that does not generalise - the Water Elemental
--   summon, Cold Snap, and the frozen check that gates Ice Lance - and it is
--   the tuned, working reference this file was written from. Migrating it is
--   a separate change with its own risk, and bundling it here would put the
--   one rotation that already works through the sequencer at risk for the
--   benefit of the seven that do not.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   It does not decide anything. Whether the sequence started is the only
--   thing it reports. A class that gets false from start() runs exactly the
--   priority list it ran before this file existed, so the failure mode is
--   the old behaviour rather than a stall.
--
-- EVERY API HERE IS IN THE REFLECTED DUMP
--   izi.advanced_sequence, izi.is_sequence_active, izi.is_sequence_on_cooldown
--   and the advanced_spell_entry / advanced_sequence_opts field names are the
--   documented ones: spell, target, condition; timeout, cooldown, debug_name,
--   is_flexible_order.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local gui      = require("gui")
local range    = require("spell_range")
local spellbook = require("spellbook")

local sequence = {}

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

-- ============================================================================
-- UNITS
-- ============================================================================

local function unit_ok(unit)
    if not unit then
        return false
    end
    return safe(function() return unit:is_valid() end) == true
end

--- The enemy the sequence should aim at.
---
--- The caller's target wins; izi.ts() is the fallback for the case where the
--- sequence outlives the tick that started it and the original target has
--- gone. Same order mage.lua uses.
local function enemy_for(target)
    if unit_ok(target) then
        return target
    end
    local t = safe(function() return izi.ts() end)
    if unit_ok(t) then
        return t
    end
    return nil
end

-- ============================================================================
-- CONDITIONS
-- ============================================================================

local function learned(spell)
    if not spell then
        return false
    end
    if not spellbook.ready() then
        return false
    end
    return spellbook.spell_known(spell) == true
end

--- Build the condition for one entry.
---
--- Order matters here and mirrors mage.lua's cond_target:
---   the toggle, so a spell the user turned off never enters the sequence
---   the range, asked of the client so it is hitbox aware
---   the caller's own extra test
---   whether it is known
---   whether the client will actually let it go at this unit
---
--- range.spell rather than a centre-to-centre number: the mage's version of
--- this condition was the one place left doing the arithmetic itself, and it
--- silently dropped entries against large mobs whose hitbox the client would
--- have accepted.
local function build_condition(spell, key, max_dist, extra, target)
    return function()
        if key ~= nil and gui.is_on(key) ~= true then
            return false
        end
        local unit = enemy_for(target)
        if not spell or not unit then
            return false
        end
        if type(max_dist) == "number" and not range.spell(unit, spell, max_dist) then
            return false
        end
        if extra and extra() ~= true then
            return false
        end
        if not learned(spell) then
            return false
        end
        return safe(function()
            return spell:is_castable_to_unit(unit)
        end) == true
    end
end

-- ============================================================================
-- STARTING
-- ============================================================================

--- Try to start a damage sequence.
---
--- `rows` is the class's damage priority, highest first, each one:
---
---     { spell, key = "gui_toggle", dist = 30, when = function() ... end }
---
--- `key`, `dist` and `when` are all optional. A row whose spell did not
--- resolve is dropped rather than failing the whole sequence, which is what
--- lets a low level character start one from the two abilities it has.
---
--- Returns true when a sequence is running - either one this call started, or
--- one already in flight. The caller treats true as "damage is handled this
--- tick" and false as "run your own priority list", which is exactly what it
--- did before this module existed.
function sequence.start(rows, target, debug_name, opts)
    if type(rows) ~= "table" or #rows < 1 then
        return false
    end

    -- Already running: leave it alone. Restarting every tick is how a
    -- sequencer ends up casting nothing but its first entry.
    if type(izi.is_sequence_active) == "function" and izi.is_sequence_active() then
        return true
    end
    if type(izi.is_sequence_on_cooldown) == "function" and izi.is_sequence_on_cooldown() then
        return false
    end
    if type(izi.advanced_sequence) ~= "function" then
        return false
    end

    local unit = enemy_for(target)
    if not unit then
        return false
    end

    local entries = {}
    for i = 1, #rows do
        local row = rows[i]
        local spell = row and row.spell
        if spell then
            entries[#entries + 1] = {
                spell = spell,
                target = function() return enemy_for(target) end,
                condition = build_condition(spell, row.key, row.dist, row.when, target),
            }
        end
    end
    if #entries < 1 then
        return false
    end

    local started = safe(function()
        return izi.advanced_sequence(entries, {
            timeout = (opts and opts.timeout) or 12.0,
            cooldown = (opts and opts.cooldown) or 0,
            debug_name = debug_name or "Rotation",
            is_flexible_order = true,
        })
    end)

    return started == true
end

--- Is a sequence running right now?
---
--- Exposed so a rotation can hold off on something that would interrupt one.
function sequence.active()
    if type(izi.is_sequence_active) ~= "function" then
        return false
    end
    return safe(function() return izi.is_sequence_active() end) == true
end

return sequence
