-- ============================================================================
-- Master Farmer - Grindbot
-- Grind vs Quest mode helpers
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.77.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================

-- ASSUMPTIONS: Classic / TBC race ids from the client (enums has no race table).
local RACE = {
    HUMAN = 1,
    ORC = 2,
    DWARF = 3,
    NIGHT_ELF = 4,
    UNDEAD = 5,
    TAUREN = 6,
    GNOME = 7,
    TROLL = 8,
    GOBLIN = 9,
    BLOOD_ELF = 10,
    DRAENEI = 11,
}

-- Every race playable in TBC. Goblin (9) has an id but no playable character
-- until Cataclysm, so it is left out.
--
-- key is the file stem grind/zones/<key>.lua would use. Only some races ship
-- a zone file yet; grind/zone_lookup requires it under pcall, so a race
-- without one simply has no zone rather than an error.
local RACES = {
    [RACE.HUMAN]     = { key = "human",    label = "Human" },
    [RACE.ORC]       = { key = "orc",      label = "Orc" },
    [RACE.DWARF]     = { key = "dwarf",    label = "Dwarf" },
    [RACE.NIGHT_ELF] = { key = "nightelf", label = "Night Elf" },
    [RACE.UNDEAD]    = { key = "undead",   label = "Undead" },
    [RACE.TAUREN]    = { key = "tauren",   label = "Tauren" },
    [RACE.GNOME]     = { key = "gnome",    label = "Gnome" },
    [RACE.TROLL]     = { key = "troll",    label = "Troll" },
    [RACE.BLOOD_ELF] = { key = "bloodelf", label = "Blood Elf" },
    [RACE.DRAENEI]   = { key = "draenei",  label = "Draenei" },
}

local modes = {}
modes.RACE = RACE
modes.GRIND = "grind"
modes.QUEST = "quest"
modes.PATH = "path"

--- Can this race quest? Every TBC race can: quests come from the RestedXP
--- guide, which covers all of them, not from per-race data in this plugin.
function modes.race_has_starter_quests(race_id)
    return RACES[race_id] ~= nil
end

function modes.race_key(race_id)
    local r = RACES[race_id]
    return r and r.key or nil
end

function modes.race_label(race_id)
    local r = RACES[race_id]
    return r and r.label or nil
end

return modes
