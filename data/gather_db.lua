-- ============================================================================
-- Master Farmer - Grindbot
-- data/gather_db.lua - the herbing and mining node database (ESP + gathering)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.9.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- One database of gatherable nodes, read by gather/esp.lua (the node ESP and
-- the recorded-path detours). Two sources:
--
--   1. gather/nodes.lua - the EP_Herb_Mine node table (Classic / TBC herbs and
--      ore, with ids and skill windows). Not copied here: gather/esp reads it.
--   2. ZONES below - zone lists added from gathering profiles. Each zone keeps
--      its profile's node ids and names exactly; `herbs` / `ore` sort the names
--      by profession, `other` holds the profile's objects that are not herbs
--      or ore (lumber, books, caches - not drawn, never gathered).
--      The profile's ids are NOT paired with names in the source, so an id
--      match is only a filter: the node's kind comes from its name.
--
-- A node is matched by entry id (get_npc_id) or by its English name
-- (get_name). min_rank = the skill needed (0 = any rank: the source gives none).
-- ============================================================================

local M = {}

M.zones = {
    {
        -- Source: Core_Api\Eversong woods gathering ORE + HERBS (converted).json
        -- (Expansion "Midnight", entry "Eversong Woods gather")
        id = "eversong_woods_midnight",
        name = "Eversong Woods gather",
        expansion = "Midnight",
        rect = { continent = 0, min_x = 4548, max_x = 8171, min_y = -5821, max_y = -3323 },
        spot_cooldown_minutes = 5,
        node_ids = {
            523295, 523284, 523288, 523281, 618517, 547829, 531478, 523303, 523294, 556758,
            556759, 556760, 556761, 556762, 568254, 516932, 568241, 568243, 516937, 555631,
            516936, 516935, 523297, 516934, 555829, 555830, 516965, 516966, 516967, 516988,
            531479, 523282, 523289, 523290, 516982, 516981, 523301, 516980,
        },
        ore = {
            "Brilliant Silver",
            "Lightfused Brilliant Silver",
            "Rich Brilliant Silver",
            "Voidbound Brilliant Silver",
            "Refulgent Copper",
            "Lightfused Refulgent Copper",
            "Rich Refulgent Copper",
            "Umbral Tin",
            "Lightfused Umbral Tin",
            "Rich Umbral Tin",
            "Umbral Tin Seam",
        },
        herbs = {
            "Argentleaf",
            "Voidbound Argentleaf",
            "Azeroot",
            "Lightfused Azeroot",
            "Voidbound Azeroot",
            "Sanguithorn",
            "Lightfused Sanguithorn",
            "Voidbound Sanguithorn",
            "Tranquility Bloom",
            "Lightfused Tranquility Bloom",
            "Lush Tranquility Bloom",
            "Mana Lily",
            "Golden Sunleaf",
        },
        other = {
            "Thalassian Lumber",
            "Misplaced Tome",
            "Intercepted Shipment",
            "Scattered Supplies",
            "Bright Feather",
            "Remnant of Anguish",
            "Herbalist's Handbook: Eversong Medicinals",
            "Index of Ranger Corps Recipes Vol. VII",
            "Ranger's Cache",
        },
    },
}

return M
