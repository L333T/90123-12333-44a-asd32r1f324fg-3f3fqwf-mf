-- ============================================================================
-- Master Farmer - Grindbot
-- Game version: TBC Classic or WoW Forever
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.127.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- core.get_game_version() answers "Tbc" on TBC Classic (and the TBC 2.5.3
-- private-server client) and "Forever" on WoW Forever (exact build
-- "wowforeverbetaus"). Everything that differs between the two asks here
-- instead of calling the core itself, so the answer is read once.
--
-- PLAYABLE RACES (wowhead.com/forever/races, checked 2026-09-29)
--   TBC      Human, Orc, Dwarf, Night Elf, Undead, Tauren, Gnome, Troll,
--            Blood Elf (10), Draenei (11)
--   Forever  Human, Orc, Dwarf, Night Elf, Undead, Tauren, Gnome, Troll,
--            High Order Skyborne (95, Alliance), Windshaper Skyborne (96, Horde)
--            - no Blood Elf, no Draenei.
-- Both have the same nine classes: Warrior, Paladin, Hunter, Rogue, Priest,
-- Shaman, Mage, Warlock, Druid.
-- ============================================================================

local gamever = {}

gamever.TBC = "Tbc"
gamever.FOREVER = "Forever"

local cached = nil

--- "Tbc", "Forever", or whatever else the core reports.
function gamever.version()
    if cached == nil then
        local ok, v = pcall(function() return core.get_game_version() end)
        cached = (ok and type(v) == "string") and v or ""
    end
    return cached
end

function gamever.is_forever() return gamever.version() == gamever.FOREVER end
function gamever.is_tbc() return gamever.version() == gamever.TBC end

--- Is this a game version the plugin runs on?
function gamever.supported()
    return gamever.is_tbc() or gamever.is_forever()
end

local RACES_TBC = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
    [6] = true, [7] = true, [8] = true, [10] = true, [11] = true }
local RACES_FOREVER = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
    [6] = true, [7] = true, [8] = true, [95] = true, [96] = true }

--- Is `race_id` a playable race on the running game version?
function gamever.race_playable(race_id)
    if type(race_id) ~= "number" then return false end
    if gamever.is_forever() then return RACES_FOREVER[race_id] == true end
    return RACES_TBC[race_id] == true
end

return gamever
