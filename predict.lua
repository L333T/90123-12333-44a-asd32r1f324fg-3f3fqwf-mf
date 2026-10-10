-- ============================================================================
-- Master Farmer - Grindbot
-- predict.lua - Sylvanas spell_prediction for the class rotations
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.261.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHY (2.248.0)
--   The AoE role counted enemies within a fixed radius of the player or the
--   target, and the first ticked AoE spell in list order won. Blizzard went to
--   the target's feet, not to where the pack was.
--
-- WHAT
--   For every catalog AoE spell (data/class_spells.lua role "aoe" - never
--   guessed for other spells), the hits are PREDICTED by
--   common/modules/spell_prediction with the spell's own shape, range and cast
--   time:
--     ground  (Blizzard, Flamestrike, Rain of Fire, Hurricane...)
--             CIRCLE, MOST_HITS, cast position from get_cast_position;
--     self    (Arcane Explosion, Whirlwind, Consecration, Holy Nova...)
--             CIRCLE around the player at hit time;
--     cone    (Cone of Cold, Dragon's Breath - catalog `cone = true`)
--             CONE from the player toward the target, `angle` degrees;
--     target  (Chain Lightning, Cleave, Swipe, Seed of Corruption...)
--             CIRCLE around the target.
--   smart.lua uses the count for the AoE condition, orders the AoE spells by
--   predicted hits (most first), and casts ground spells at the predicted
--   most-hits position. One prediction per spell per CACHE_S (the module's
--   own advice: not every frame). Without the module everything falls back
--   to the old radius count (nil answers).
-- ============================================================================

local M = {}

local CACHE_S = 0.2
local DEFAULT_RADIUS = 8
local DEFAULT_RANGE = 30
local DEFAULT_ANGLE = 60

local sp_mod = nil           -- spell_prediction, false when unavailable
local cache = {}             -- key -> { t, hits, pos }
local cache_n = 0

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function lib()
    if sp_mod == nil then
        local ok, m = pcall(require, "common/modules/spell_prediction")
        sp_mod = (ok and type(m) == "table" and type(m.new_spell_data) == "function") and m or false
    end
    return sp_mod or nil
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    return ok and type(izi) == "table" and safe(izi.now) or 0
end

--- The shape of a catalog entry: "ground", "self", "cone" or "target".
function M.shape(def)
    if type(def) ~= "table" then return "target" end
    if def.ground then return "ground" end
    if def.cone then return "cone" end
    if def.center == "self" or def.self then return "self" end
    return "target"
end

local function count(list)
    if type(list) ~= "table" then return nil end
    return #list
end

--- Predicted enemies hit by catalog entry `e` (id, def) cast by `me` at
--- `target`, and for a ground spell the cast position. nil when the module or
--- the inputs are missing (the caller falls back to its own count).
--- `cast_time` (s) and `max_range` (yd) come from the spell when known.
function M.hits(e, me, target, cast_time, max_range)
    local S = lib()
    if not S or type(e) ~= "table" or not me then return nil end
    local def = e.def or {}
    local shape = M.shape(def)
    if shape ~= "self" and not target then return nil end
    local key = tostring(e.key or e.id) .. "|" .. tostring(target and safe(function() return target:get_guid() end) or "self")
    local t = now()
    local c = cache[key]
    if c and t - c.t < CACHE_S then return c.hits, c.pos end

    local id = tonumber(e.id) or 0
    local radius = tonumber(def.r) or DEFAULT_RADIUS
    local range = tonumber(max_range) or DEFAULT_RANGE
    if range <= 0 then range = (shape == "self") and radius or DEFAULT_RANGE end
    local ct = tonumber(cast_time) or 0
    local mypos = safe(function() return me:get_position() end)
    if not mypos then return nil end
    local types = S.prediction_type or {}
    local geos = S.geometry_type or {}

    local hits, pos = nil, nil
    if shape == "ground" then
        local data = safe(function()
            return S:new_spell_data(id, range, radius, ct, 0.0, types.MOST_HITS, geos.CIRCLE, mypos)
        end)
        local res = data and safe(function() return S:get_cast_position(target, data) end)
        if type(res) == "table" and type(res.amount_of_hits) == "number" then
            hits, pos = res.amount_of_hits, res.cast_position
        end
    elseif shape == "self" then
        local data = safe(function()
            return S:new_spell_data(id, radius, radius, ct, 0.0, types.MOST_HITS, geos.CIRCLE, mypos)
        end)
        hits = data and count(safe(function() return S:get_circle_list(mypos, data) end))
    elseif shape == "cone" then
        local tpos = safe(function() return target:get_position() end)
        local data = tpos and safe(function()
            return S:new_spell_data(id, radius, radius, ct, 0.0, types.MOST_HITS, geos.CONE, mypos)
        end)
        if data then
            data.angle = tonumber(def.angle) or DEFAULT_ANGLE
            hits = count(safe(function() return S:get_cone_list(tpos, data) end))
        end
    else
        local tpos = safe(function() return target:get_position() end)
        local data = tpos and safe(function()
            return S:new_spell_data(id, range, radius, ct, 0.0, types.MOST_HITS, geos.CIRCLE, mypos)
        end)
        hits = data and count(safe(function() return S:get_circle_list(tpos, data) end))
    end
    if type(hits) ~= "number" then hits = nil end
    cache_n = cache_n + 1
    if cache_n > 300 then cache, cache_n = {}, 0 end
    cache[key] = { t = t, hits = hits, pos = pos }
    return hits, pos
end

--- Forget cached predictions (a new fight).
function M.reset()
    cache, cache_n = {}, 0
end

return M
