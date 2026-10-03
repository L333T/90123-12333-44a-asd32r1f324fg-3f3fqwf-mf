-- ============================================================================
-- Master Farmer - Grindbot
-- Grind zone lookup by race + level
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.225.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================

-- RACE -> zone file stem (moved here from modes.lua, removed in 2.217.0: this
-- is its only user). Classic / TBC race ids from the client (enums has no race
-- table); Blood Elf and Draenei exist only on TBC, the two Skyborne races only
-- on WoW Forever (gamever.race_playable, 2.121.0). Goblin (9) has no playable
-- character before Cataclysm. A race without a grind/zones/<key>.lua simply
-- has no zone (required under pcall below).
local gamever = require("gamever")

local RACE_KEY = {
    [1] = "human", [2] = "orc", [3] = "dwarf", [4] = "nightelf", [5] = "undead",
    [6] = "tauren", [7] = "gnome", [8] = "troll", [10] = "bloodelf", [11] = "draenei",
    [95] = "skyborne_highorder",    -- High Order Skyborne (Forever, Alliance)
    [96] = "skyborne_windshaper",   -- Windshaper Skyborne (Forever, Horde)
}

local function race_key(race_id)
    if not gamever.race_playable(race_id) then return nil end
    return RACE_KEY[race_id]
end

local grind_zones = {}
local loaded_key = nil
local loaded_list = nil

local function list_for(race_id)
    local key = race_key(race_id)
    if not key then
        return nil
    end
    if loaded_key == key then
        return loaded_list
    end
    if loaded_key then
        package.loaded["grind/zones/" .. loaded_key] = nil
        loaded_list = nil
    end
    local ok, list = pcall(require, "grind/zones/" .. key)
    if not ok or type(list) ~= "table" then
        loaded_key = nil
        loaded_list = nil
        return nil
    end
    loaded_key = key
    loaded_list = list
    pcall(collectgarbage, "step", 200)
    return list
end

function grind_zones.lookup(race_id, level)
    local list = list_for(race_id)
    if type(list) ~= "table" then
        return nil
    end
    for i = 1, #list do
        local row = list[i]
        if level >= row.min and level <= row.max then
            return row
        end
    end
    return nil
end

return grind_zones
