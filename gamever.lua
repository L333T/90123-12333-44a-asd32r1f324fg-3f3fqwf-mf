-- ============================================================================
-- Master Farmer - Grindbot
-- Game version: TBC Classic or WoW Forever
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.195.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- core.get_game_version() answers "Tbc" on TBC Classic (and the TBC 2.5.3
-- private-server client) and "Forever" on WoW Forever. The beta client is
-- also accepted when get_exact_game_version() is "wow_forever_beta_us".
-- Everything that differs between the two asks here
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

-- The coarse name is "Forever". The beta client is identified by the exact
-- build when get_game_version() does not say that.
local FOREVER_EXACT = "wow_forever_beta_us"

local function exact_version()
    if type(core) ~= "table" or type(core.get_exact_game_version) ~= "function" then
        return ""
    end
    local ev = core.get_exact_game_version()
    if type(ev) ~= "string" then
        return ""
    end
    return ev
end

function gamever.is_forever()
    return gamever.version() == gamever.FOREVER or exact_version() == FOREVER_EXACT
end
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

-- CONTINENT (2.146.0): 0 Eastern Kingdoms, 1 Kalimdor, 530 Outland. One
-- answer for the flight planner and the supply runs, which each had their own.
-- core.get_map_id() when it is one of those ids (it is only documented as
-- "the current map"), else the continent of the nearest flight point that
-- exists on this game version (data/taxi_nodes).
function gamever.continent_of(pos)
    local raw = nil
    pcall(function() raw = core.get_map_id() end)
    if raw == 0 or raw == 1 or raw == 530 then
        return raw, raw
    end
    if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
        return nil, raw
    end
    local ok, cat = pcall(require, "data/taxi_nodes")
    if not ok or type(cat) ~= "table" or type(cat.nodes) ~= "table" then
        return nil, raw
    end
    local best, best_d = nil, nil
    for i = 1, #cat.nodes do
        local n = cat.nodes[i]
        if type(cat.in_game) ~= "function" or cat.in_game(n) then
            local d = (n.x - pos.x) ^ 2 + (n.y - pos.y) ^ 2
            if best_d == nil or d < best_d then best, best_d = n, d end
        end
    end
    return best and best.map or nil, raw
end

return gamever
