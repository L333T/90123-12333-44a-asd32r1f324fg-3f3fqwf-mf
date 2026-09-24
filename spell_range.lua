-- ============================================================================
-- Master Farmer - Grindbot
-- Spell range checks - one implementation, used by every rotation
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.16.0
-- Folder: Master_Farmer_Grindbot
-- Not to be confused with movement/range.lua, which answers navigation
-- questions - facing, line of sight, whether a point is reachable. This file
-- answers one question only: can this spell reach this unit right now.
-- ============================================================================
-- Every rotation used to answer "can I reach this?" with
--
--     local dist = player:distance_to(target)
--     if dist > combat_range(player) then return false end
--
-- which is wrong in three ways that all show up in normal grinding.
--
-- 1. distance_to is CENTRE TO CENTRE. The client measures to the target's
--    hitbox, so a large mob is reachable from further away than its centre
--    distance suggests. On a kodo or an ogre the melee rotations stood next to
--    the mob reading eight yards and refused to swing.
--
-- 2. combat_range is ONE number for the whole rotation, taken from the main
--    nuke. A mage gets 30 yards from Frostbolt and then gates Fire Blast (20),
--    Cone of Cold (10) and Arcane Explosion (10) on that same 30. Everything
--    short-ranged fired from too far away, was rejected by the server, and the
--    rotation retried it on the next tick.
--
-- 3. There is no minimum range anywhere in it. A hunter inside the five to
--    eight yard dead zone cannot shoot, and nothing in the old maths knew
--    that, so a hunter that got run down kept trying to Auto Shot.
--
-- unit:is_spell_in_range(spell) is the client's own answer to the exact
-- question, per spell, hitbox aware, and it accounts for minimum range too.
-- It is what greys the button out on the action bar. Preferring it fixes all
-- three at once, and it means we no longer keep a table of spell ranges in
-- step with the game's.
--
-- NO PLAYER ARGUMENT
--   Every call here is a method on the TARGET and is already measured from
--   the local player, so these take the unit to reach and not the unit doing
--   the reaching. Only range.to, which returns a scalar for callers that want
--   one, takes the player - and only to use distance_to when it is there.
--
-- WHEN A CHECK CANNOT ANSWER
--   Unknown is treated as IN range, not out. These are gates in front of a
--   cast that is itself gated - cast_safe still refuses an impossible cast -
--   so a permissive unknown costs one rejected cast on an exotic build, while
--   a strict unknown would mean a build missing one method never attacks at
--   all. Silence should not disarm the bot.

---@type izi_api
local izi = require("common/izi_sdk")

local range = {}

--- pcall wrapper: the API surface differs between client builds and a missing
--- method must degrade, not raise, inside a combat tick.
local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

-- ============================================================================
-- DISTANCE
-- ============================================================================

--- Centre-to-centre distance in yards, or nil when it cannot be read.
---
--- Kept for the things that genuinely want a scalar - leashing, pull distance,
--- picking the nearest of several mobs. It is the wrong tool for "can I cast
--- this", which is what range.spell is for. `player` may be nil.
function range.to(player, target)
    if not target then
        return nil
    end
    if player then
        local d = safe(function() return player:distance_to(target) end)
        if type(d) == "number" then
            return d
        end
    end
    -- distance() is already measured from the local player.
    local d = safe(function() return target:distance() end)
    if type(d) == "number" then
        return d
    end
    return nil
end

-- ============================================================================
-- RANGE TESTS
-- ============================================================================

--- Is `target` within `meters`, counting its hitbox?
---
--- The melee form: is_in_melee_range adds the target's radius, which is the
--- whole point - five yards from a kodo's centre is still inside the kodo.
function range.melee(target, meters)
    if not target then
        return false
    end
    meters = (type(meters) == "number" and meters > 0) and meters or 5

    local hit = safe(function() return target:is_in_melee_range(meters) end)
    if type(hit) == "boolean" then
        return hit
    end
    -- Older alias, same semantics.
    hit = safe(function() return target:inMeleeRange(meters) end)
    if type(hit) == "boolean" then
        return hit
    end

    -- No hitbox-aware call on this build. Fall back to a plain radius test and
    -- allow a couple of yards for the hitbox we can no longer measure, or the
    -- large-mob case this function exists to fix comes straight back.
    local plain = safe(function() return target:is_in_range(meters + 2) end)
    if type(plain) == "boolean" then
        return plain
    end

    local d = range.to(nil, target)
    if type(d) == "number" then
        return d <= (meters + 2)
    end
    return true
end

--- Is `target` within a flat `meters`?
function range.within(target, meters)
    if not target then
        return false
    end
    if type(meters) ~= "number" or meters <= 0 then
        return true
    end

    local hit = safe(function() return target:is_in_range(meters) end)
    if type(hit) == "boolean" then
        return hit
    end
    hit = safe(function() return target:inRange(meters) end)
    if type(hit) == "boolean" then
        return hit
    end

    local d = range.to(nil, target)
    if type(d) == "number" then
        return d <= meters
    end
    return true
end

--- Can `spell` reach `target` right now?
---
--- The one to call from a rotation. `fallback_yards` is consulted only when
--- the client will not answer for the spell itself; pass the rotation's
--- combat_range, or a melee ability's reach, or leave it nil.
function range.spell(target, spell, fallback_yards)
    if not target then
        return false
    end
    if not spell then
        -- Nothing to ask about: fall back to whatever the caller knows.
        return range.within(target, fallback_yards)
    end

    -- The client's own per-spell answer. Hitbox aware, and it knows about
    -- minimum range, so a hunter in the dead zone reads false here.
    local hit = safe(function() return target:is_spell_in_range(spell) end)
    if type(hit) == "boolean" then
        return hit
    end
    hit = safe(function() return target:spellInRange(spell) end)
    if type(hit) == "boolean" then
        return hit
    end

    -- The spell object may carry its own maximum, which is still per spell and
    -- so still better than the rotation-wide number.
    local max_yards = fallback_yards
    local own = safe(function() return spell.maximum_range end)
    if type(own) == "number" and own > 0 then
        max_yards = own
    end

    -- A short reach is a melee reach, and melee is the case where the hitbox
    -- matters most, so shape the fallback accordingly.
    if type(max_yards) == "number" and max_yards > 0 and max_yards <= 6 then
        return range.melee(target, max_yards)
    end
    return range.within(target, max_yards)
end

return range
