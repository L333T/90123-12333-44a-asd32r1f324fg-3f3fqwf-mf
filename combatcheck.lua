-- ============================================================================
-- restedXP_questing
-- combatcheck.lua - time to death, crowd control, immunities, facing
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.22.0
-- ============================================================================
-- 4.14.0 (improvements 7, 9 and 10 of the API-dump review). The izi unit
-- extensions (.api common/izi_sdk.lua), every call pcall-guarded; an answer
-- of the wrong type is "unknown" (nil) and the caller keeps its old way.
--
--   TIME TO DEATH (7)   unit:has_time_to_die_data() must be true (false =
--                       time_to_die answers its 1.1 "no data" value), then
--                       unit:time_to_die() / get_time_to_death(). Out of
--                       (0, 600) s: unknown.
--   CROWD CONTROL (9)   unit:is_cc_weak()      CC that breaks on damage (a
--                                              sheep, a sap, a gouge)
--                       unit:is_cc_immune()    immune to crowd control
--                       unit:is_slowed(0.3)    slowed by 30 %+
--                       unit:is_rooted() / is_stunned()
--                       unit:is_slow_immune()
--   FACING (10)         player:is_looking_at_unit(unit, FACE_ANGLE)
--   APPROACH (10)       unit:is_moving_towards_me(player)
-- Answers are cached per unit for CACHE_S (one tick's worth of calls).
-- ============================================================================

local CK = {}

CK.FACE_ANGLE = 90          -- degrees off the facing still "in front"
CK.SLOW_PCT = 0.3           -- is_slowed threshold (0.3 = slowed 30 %+)
CK.TTD_MAX = 600
local CACHE_S = 0.2

local cache = {}            -- [guid .. key] = { t, v }
local cache_n = 0

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then
        local okn, t = pcall(izi.now)
        if okn and type(t) == "number" then return t end
    end
    return 0
end

local function guid(u)
    if not u then return nil end
    local ok, g = pcall(u.get_guid, u)
    if ok and g ~= nil then return tostring(g) end
    return nil
end

--- unit:<name>(...) -> its first answer, or nil when the method is missing
--- or errors.
local function ask(u, name, ...)
    if not u then return nil end
    local f = u[name]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, u, ...)
    if ok then return v end
    return nil
end

local function cached(u, key, fn)
    local g = guid(u)
    local t = now()
    local k = g and (g .. key) or nil
    local e = k and cache[k] or nil
    if e and (t - e.t) < CACHE_S then return e.v end
    local v = fn()
    if k then
        if not cache[k] then
            cache_n = cache_n + 1
            if cache_n > 256 then cache, cache_n = {}, 1 end
        end
        cache[k] = { t = t, v = v }
    end
    return v
end

local function bool(v) if type(v) == "boolean" then return v end return nil end

-- ---------------------------------------------------------------------------
-- time to death
-- ---------------------------------------------------------------------------
--- Seconds until `u` dies at the current damage rate, or nil (no data).
function CK.ttd(u)
    return cached(u, ":ttd", function()
        if ask(u, "has_time_to_die_data") ~= true then return nil end
        local v = tonumber(ask(u, "time_to_die"))
        if not v then v = tonumber(ask(u, "get_time_to_death")) end
        if not v or v ~= v or v <= 0 or v >= CK.TTD_MAX then return nil end
        return v
    end)
end

--- True when `u` is forecast to die within `secs`; false / nil otherwise.
function CK.dies_within(u, secs)
    local v = CK.ttd(u)
    if not v or type(secs) ~= "number" then return nil end
    return v <= secs
end

-- ---------------------------------------------------------------------------
-- crowd control and immunities
-- ---------------------------------------------------------------------------
function CK.weak_cc(u) return cached(u, ":wcc", function() return bool(ask(u, "is_cc_weak")) end) end
function CK.cc_immune(u) return cached(u, ":cci", function() return bool(ask(u, "is_cc_immune")) end) end
function CK.slow_immune(u) return cached(u, ":sli", function() return bool(ask(u, "is_slow_immune")) end) end
function CK.slowed(u) return cached(u, ":slw", function() return bool(ask(u, "is_slowed", CK.SLOW_PCT)) end) end
function CK.held(u)
    return cached(u, ":hld", function()
        local r, s = bool(ask(u, "is_rooted")), bool(ask(u, "is_stunned"))
        if r == true or s == true then return true end
        if r == nil and s == nil then return nil end
        return false
    end)
end

--- A pack member other than `target` under crowd control that breaks on
--- damage, within `radius` yd (+ 2 yd of hit box) of `center` (a unit):
--- that unit, else nil.
function CK.breaks_cc(center, radius, pack, target)
    if not center or type(pack) ~= "table" then return nil end
    local tg = guid(target)
    local r = (tonumber(radius) or 10) + 2
    for i = 1, #pack do
        local u = pack[i]
        local g = guid(u)
        if u and g ~= nil and g ~= tg and CK.weak_cc(u) == true then
            local d = tonumber(ask(center, "distance_to", u))
            if d and d <= r then return u end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- facing and approach
-- ---------------------------------------------------------------------------
--- Is `player` facing `u`? true / false, or nil (unknown).
function CK.facing(player, u)
    if not player or not u then return nil end
    local ok, v = pcall(function() return player:is_looking_at_unit(u, CK.FACE_ANGLE) end)
    if ok then return bool(v) end
    return nil
end

--- Is `u` walking towards `player`? true / false, or nil.
function CK.approaching(u, player)
    if not u or not player then return nil end
    return cached(u, ":apr", function() return bool(ask(u, "is_moving_towards_me", player)) end)
end

function CK._reset() cache, cache_n = {}, 0 end

return CK
