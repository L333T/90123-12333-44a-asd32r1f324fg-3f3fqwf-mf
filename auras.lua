-- ============================================================================
-- Master Farmer - Grindbot
-- Aura queries - one implementation, used by every rotation
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.17.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Everything in this project asked about auras the same way:
--
--     if unit:has_debuff(CORRUPTION_IDS) ~= true then recast() end
--
-- which answers yes or no and nothing else. Two things follow from that, and
-- both cost uptime on every single mob.
--
-- 1. A DoT is only ever refreshed AFTER it has fallen off. The bot notices on
--    the tick after expiry, casts, and the mob spends that whole window with
--    no DoT on it. The same is true of every self buff: Mana Shield came back
--    a beat after it dropped, not before.
--
-- 2. Nothing could act on how long is left. "Refresh at three seconds" is not
--    expressible when the only answer is a boolean.
--
-- common/modules/buff_manager answers with remaining, stacks and duration,
-- and caches so that asking once per frame per unit is not a pile of game API
-- calls. This wraps it so callers get a uniform table, and falls back to the
-- old boolean calls when the module is not there.
--
-- WHY NOT A TIMER OF OUR OWN
--   buffs.lua used to reason that a self-kept timer drifts, is wrong after a
--   dispel it never hears about, and needs a duration table per rank. All of
--   that is still true. `remaining` here is the GAME's number, read fresh, so
--   it has none of those problems - it is the direct question, just with more
--   than one bit of answer.
--
-- CACHING AND STALENESS
--   A cached answer can be up to its cache duration old, which matters right
--   after casting: read "not active" from a stale entry and the bot recasts
--   something it just cast. Callers that act on the result are gated by their
--   own cooldowns (buffs.lua holds 1.2s between casts), which is longer than
--   the cache window used here. DEFAULT_MS is deliberately short for that
--   reason rather than tuned for the fewest API calls.

---@type izi_api
local izi = require("common/izi_sdk")

local auras = {}

-- Short enough that a buff cast this second is not still reported missing on
-- the next attempt, long enough that a rotation asking about six auras in one
-- frame does not make six trips into the game.
local DEFAULT_MS = 200

local NONE = { is_active = false, active = false, remaining = 0, stacks = 0, duration = 0 }

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

-- The module is resolved once and remembered, including the failure. Retrying
-- a require that has already failed, once per aura check per frame, is its own
-- performance problem.
local bm = nil
local bm_tried = false

local function manager()
    if bm_tried then
        return bm
    end
    bm_tried = true
    local ok, mod = pcall(require, "common/modules/buff_manager")
    if ok and type(mod) == "table" then
        bm = mod
    else
        bm = nil
    end
    return bm
end

--- Normalise to the shape callers read, whatever the source gave us.
local function shape(data)
    if type(data) ~= "table" then
        return nil
    end
    local active = data.is_active
    if type(active) ~= "boolean" then
        return nil
    end
    return {
        is_active = active,
        active = active,          -- both spellings, so call sites read naturally
        remaining = tonumber(data.remaining) or 0,
        stacks = tonumber(data.stacks) or 0,
        duration = tonumber(data.duration) or 0,
    }
end

--- A result built from the old boolean calls, for a build with no buff_manager.
---
--- `remaining` is reported as a large number rather than 0 when the aura IS
--- up. Zero would read as "about to expire" to every caller that compares
--- against a threshold, and would turn a missing module into a permanent
--- refresh loop. Unknown time left must not look like no time left.
local function from_boolean(up)
    if up then
        return { is_active = true, active = true, remaining = math.huge, stacks = 1, duration = 0 }
    end
    return { is_active = false, active = false, remaining = 0, stacks = 0, duration = 0 }
end

local function ids_of(spec)
    if type(spec) == "table" then
        return spec
    end
    if type(spec) == "number" then
        return { spec }
    end
    return nil
end

-- ============================================================================
-- QUERIES
-- ============================================================================

--- Buff data for `unit`: { is_active, remaining, stacks, duration }.
---
--- `spec` is an array of spell ids (every rank of the same buff is fine - the
--- first one present answers) or a buff_db enum key.
function auras.buff(unit, spec, cache_ms)
    if not unit or spec == nil then
        return NONE
    end

    local m = manager()
    if m then
        local got = shape(safe(function()
            return m:get_buff_data(unit, spec, cache_ms or DEFAULT_MS)
        end))
        if got then
            return got
        end
    end

    local ids = ids_of(spec)
    if not ids then
        return NONE
    end
    return from_boolean(safe(function() return unit:has_buff(ids) end) == true)
end

--- Debuff data for `unit`. Same shape as auras.buff.
function auras.debuff(unit, spec, cache_ms)
    if not unit or spec == nil then
        return NONE
    end

    local m = manager()
    if m then
        local got = shape(safe(function()
            return m:get_debuff_data(unit, spec, cache_ms or DEFAULT_MS)
        end))
        if got then
            return got
        end
    end

    local ids = ids_of(spec)
    if not ids then
        return NONE
    end
    return from_boolean(safe(function() return unit:has_debuff(ids) end) == true)
end

--- Either kind, for callers that do not care which it is.
function auras.aura(unit, spec, cache_ms)
    if not unit or spec == nil then
        return NONE
    end

    local m = manager()
    if m then
        local got = shape(safe(function()
            return m:get_aura_data(unit, spec, cache_ms or DEFAULT_MS)
        end))
        if got then
            return got
        end
    end

    local ids = ids_of(spec)
    if not ids then
        return NONE
    end
    -- has_buff first, then has_aura: a build that has only one of them still
    -- answers, and the project's own call sites already pair them this way.
    if safe(function() return unit:has_buff(ids) end) == true then
        return from_boolean(true)
    end
    return from_boolean(safe(function() return unit:has_aura(ids) end) == true)
end

-- ============================================================================
-- CONVENIENCE
-- ============================================================================

--- Is this buff up at all? The straight replacement for has_buff.
function auras.buff_up(unit, spec, cache_ms)
    return auras.buff(unit, spec, cache_ms).is_active
end

--- Is this debuff up at all? The straight replacement for has_debuff.
function auras.debuff_up(unit, spec, cache_ms)
    return auras.debuff(unit, spec, cache_ms).is_active
end

--- Is this aura up at all, buff or debuff?
function auras.aura_up(unit, spec, cache_ms)
    return auras.aura(unit, spec, cache_ms).is_active
end

--- Should this buff be (re)cast - missing, or with less than `secs` left?
---
--- This is the whole point of the module. `secs` of 0 or nil means "only when
--- it is actually gone", which is exactly the old behaviour, so a caller that
--- does not want early refresh is not forced into it.
function auras.buff_expiring(unit, spec, secs, cache_ms)
    local d = auras.buff(unit, spec, cache_ms)
    if not d.is_active then
        return true
    end
    if type(secs) ~= "number" or secs <= 0 then
        return false
    end
    return d.remaining < secs
end

--- Should this debuff be (re)applied - missing, or with less than `secs` left?
function auras.debuff_expiring(unit, spec, secs, cache_ms)
    local d = auras.debuff(unit, spec, cache_ms)
    if not d.is_active then
        return true
    end
    if type(secs) ~= "number" or secs <= 0 then
        return false
    end
    return d.remaining < secs
end

--- Same, for an aura of either kind.
function auras.aura_expiring(unit, spec, secs, cache_ms)
    local d = auras.aura(unit, spec, cache_ms)
    if not d.is_active then
        return true
    end
    if type(secs) ~= "number" or secs <= 0 then
        return false
    end
    return d.remaining < secs
end

--- True when the build has a real buff_manager behind these calls, so a caller
--- can tell "lots of time left" from "we cannot see the clock".
function auras.has_timings()
    return manager() ~= nil
end

return auras
