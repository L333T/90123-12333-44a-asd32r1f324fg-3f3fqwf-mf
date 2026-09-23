-- ============================================================================
-- Master Farmer - Grindbot
-- Faction lookup
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 1.9.0
-- Folder: Master_Farmer_Grindbot_v1.9.0
-- ============================================================================
-- Race, not faction id. get_faction_id returns a faction TEMPLATE id, which
-- varies by unit and is not a clean Alliance/Horde answer for the player.
-- The race a character was created as never changes and maps to exactly one
-- side, so that is what this reads.
-- ============================================================================

local factions = {}

factions.ALLIANCE = "alliance"
factions.HORDE = "horde"

factions.labels = { "Alliance", "Horde" }
factions.keys = { factions.ALLIANCE, factions.HORDE }

local BY_RACE = {
    [1] = factions.ALLIANCE,   -- Human
    [3] = factions.ALLIANCE,   -- Dwarf
    [4] = factions.ALLIANCE,   -- Night Elf
    [7] = factions.ALLIANCE,   -- Gnome
    [11] = factions.ALLIANCE,  -- Draenei
    [2] = factions.HORDE,      -- Orc
    [5] = factions.HORDE,      -- Undead
    [6] = factions.HORDE,      -- Tauren
    [8] = factions.HORDE,      -- Troll
    [10] = factions.HORDE,     -- Blood Elf
}

--- The faction key for a race id, or nil when the race is not known yet.
function factions.of_race(race_id)
    if type(race_id) ~= "number" then
        return nil
    end
    return BY_RACE[race_id]
end

--- The faction key for a player object, or nil while the object is not ready.
function factions.of_player(player)
    if not player then
        return nil
    end
    local ok, race = pcall(function() return player:get_race_id() end)
    if not ok then
        return nil
    end
    return factions.of_race(race)
end

--- 1 for Alliance, 2 for Horde. Used to drive the selector.
function factions.index_of(key)
    for i = 1, #factions.keys do
        if factions.keys[i] == key then
            return i
        end
    end
    return 1
end

function factions.key_at(index)
    if type(index) ~= "number" or index < 1 or index > #factions.keys then
        return factions.ALLIANCE
    end
    return factions.keys[index]
end

--- Faction a catalog entry belongs to. Everything that does not say otherwise
--- is Alliance: every route shipped so far is an Alliance levelling route, and
--- a Horde one will carry `faction = "horde"` explicitly.
function factions.of_entry(entry)
    if type(entry) ~= "table" then
        return factions.ALLIANCE
    end
    local f = entry.faction
    if type(f) == "string" and f ~= "" then
        return string.lower(f)
    end
    return factions.ALLIANCE
end

return factions
