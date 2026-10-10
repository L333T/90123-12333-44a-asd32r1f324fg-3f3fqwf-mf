-- ============================================================================
-- Master Farmer - Grindbot
-- movement/sentinel_adv.lua - map-change reset (Ameisen build)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.277.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- In Master Farmer - Grindbot this file drove Sentinel's lower-level services
-- (nav_client.get_continent_id / check_path, obstacle.probe_path_ahead /
-- get_zone_count). AmeisenNav has none of them: its follower re-paths a walk
-- that deviates and runs its own stuck recovery, and it keeps no obstacle
-- list to repair. What is kept is the one job that does not depend on the
-- nav client:
--
-- MAP CHANGE
--   Every blacklist zone, learned hazard and cached nav answer is keyed by
--   x / y only, and WoW coordinates repeat on every map - a zone from the last
--   continent would block the same coordinates on the new one. core.get_map_id
--   is sampled every MAP_GAP s; a change confirmed on two samples in a row
--   (a loading screen can read wrong once) clears the zones (Z.clear_all),
--   the nav caches (N.reset_caches, which also resets terrain and hazards -
--   the next hazards tick loads the new map's file) and halts the walk out of
--   combat. Adv.tick / Adv.status keep the parent's interface for fsm.lua.
-- ============================================================================

local K = require("movement/const")
local R = require("movement/rt")
local Z = require("movement/zones")
local N = require("movement/sentinel")
local O = require("movement/own")

local OWNER = K.OWNER

local Adv = {}

local MAP_GAP = 2.0
local map = { t = -1e9, id = nil, cand = nil }

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "ameisen", fmt, ...)
    end
end

local function read_map()
    local ok, id = pcall(function() return core.get_map_id() end)
    if ok and type(id) == "number" then return id end
    return nil
end

local function map_tick(t)
    if (t - map.t) < MAP_GAP then return end
    map.t = t
    local id = read_map()
    if id == nil then return end              -- loading screen, or no answer
    if map.id == nil then
        map.id = id
        return
    end
    if id == map.id then
        map.cand = nil
        return
    end
    if map.cand ~= id then                    -- confirm on the next sample
        map.cand = id
        return
    end
    trail("map %s -> %s: blacklist zones, nav caches and the walk reset", tostring(map.id), tostring(id))
    map.id, map.cand = id, nil
    Z.clear_all()
    N.reset_caches()
    if R.cur_owner ~= OWNER.COMBAT then
        O.halt_all()
    end
end

--- Per frame (fsm.pulse); throttles itself.
function Adv.tick(t)
    map_tick(t)
end

--- For diagnostics.
function Adv.status()
    return { map_id = map.id }
end

return Adv
