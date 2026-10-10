-- ============================================================================
-- Master Farmer - Grindbot
-- Gathering: herb and ore node table (port of EP_Herb_Mine Mine_Herb_Find)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.262.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================

-- English-client node table for the EP_Herb_Mine port.
-- Numeric ids are the ids in Mine_Herb_Find(). English names for those ids
-- were resolved from the public pfDB enUS object list (same ids the script scans).
-- Name-only rows are the script's Check_Client English strings. Do not add an
-- id that was not in the script. Match a node when get_name() equals `name`
-- or get_npc_id() equals `id`.

local nodes = {
    herbs = {
        { id = 1617, name = "Silverleaf", min_rank = 0, max_rank = 100, max_op = "<" },
        { id = 1618, name = "Peacebloom", min_rank = 0, max_rank = 100, max_op = "<" },
        { id = 1619, name = "Earthroot", min_rank = 15, max_rank = 130, max_op = "<=" },
        { id = 1620, name = "Mageroyal", min_rank = 50, max_rank = 150, max_op = "<=" },
        { id = 1621, name = "Briarthorn", min_rank = 70, max_rank = 170, max_op = "<=" },
        { id = 1622, name = "Bruiseweed", min_rank = 100, max_rank = 200, max_op = "<=" },
        { id = 1623, name = "Wild Steelbloom", min_rank = 115, max_rank = 200, max_op = "<=" },
        { id = 1624, name = "Kingsblood", min_rank = 125, max_rank = 210, max_op = "<=" },
        { id = 2041, name = "Liferoot", min_rank = 150, max_rank = 260, max_op = "<=" },
        { id = 2042, name = "Fadeleaf", min_rank = 160, max_rank = 280, max_op = "<=" },
        { id = 2046, name = "Goldthorn", min_rank = 170, max_rank = 300, max_op = "<=" },
        { id = 2043, name = "Khadgar's Whisker", min_rank = 185, max_rank = 300, max_op = "<=" },
        { id = 2044, name = "Wintersbite", min_rank = 195, max_rank = 300, max_op = "<=" },
        { id = 142140, name = "Purple Lotus", min_rank = 210, max_rank = 330, max_op = "<=" },
        { id = 142142, name = "Sungrass", min_rank = 230, max_rank = 330, max_op = "<=" },
        { id = 176583, name = "Golden Sansam", min_rank = 260, max_rank = 330, max_op = "<=" },
        { id = nil, name = "Golden Sansam", min_rank = 300, max_rank = 375, max_op = "<=" },
        { id = nil, name = "Mountain Silversage", min_rank = 300, max_rank = 375, max_op = "<=" },
        { id = nil, name = "Dreamfoil", min_rank = 300, max_rank = 375, max_op = "<=" },
        { id = nil, name = "Blindweed", min_rank = 300, max_rank = 375, max_op = "<=" },
        { id = nil, name = "Flame Cap", min_rank = 300, max_rank = 375, max_op = "<=" },
        { id = nil, name = "Felweed", min_rank = 300, max_rank = 375, max_op = "<=" },
        { id = nil, name = "Dreaming Glory", min_rank = 315, max_rank = 375, max_op = "<=" },
        { id = nil, name = "Ragveil", min_rank = 325, max_rank = 375, max_op = "<=" },
    },
    ore = {
        { id = 1731, name = "Copper Vein", min_rank = 0, max_rank = 65, max_op = "<=" },
        { id = 3764, name = "Tin Vein", min_rank = 65, max_rank = 125, max_op = "<=" },
        { id = 1610, name = "Incendicite Mineral Vein", min_rank = 65, max_rank = 125, max_op = "<=" },
        { id = 1732, name = "Tin Vein", min_rank = 65, max_rank = 125, max_op = "<=" },
        { id = 1733, name = "Silver Vein", min_rank = 75, max_rank = 140, max_op = "<=" },
        { id = 1735, name = "Iron Deposit", min_rank = 125, max_rank = 180, max_op = "<=" },
        { id = 1734, name = "Gold Vein", min_rank = 155, max_rank = 245, max_op = "<=" },
        { id = 2040, name = "Mithril Deposit", min_rank = 175, max_rank = 275, max_op = "<=" },
        { id = nil, name = "Truesilver Deposit", min_rank = 230, max_rank = 330, max_op = "<=" },
        { id = nil, name = "Dark Iron Deposit", min_rank = 230, max_rank = 330, max_op = "<=" },
        { id = nil, name = "Small Thorium Vein", min_rank = 245, max_rank = 330, max_op = "<=" },
        { id = nil, name = "Rich Thorium Vein", min_rank = 275, max_rank = 330, max_op = "<=" },
        { id = nil, name = "Fel Iron Deposit", min_rank = 300, max_rank = 375, max_op = "<=" },
        { id = nil, name = "Adamantite Deposit", min_rank = 325, max_rank = 375, max_op = "<=" },
        { id = nil, name = "Rich Adamantite Deposit", min_rank = 350, max_rank = 375, max_op = "<=" },
    },
}

return nodes
