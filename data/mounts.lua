-- ============================================================================
-- restedXP_questing - MOUNTS (3.8.0, from the 1-60 product's data/mounts)
-- ============================================================================
-- Used by movement/mount.lua (any out-of-combat travel, gathering included):
--   class_spells - class mounts, best first (cast when known)
--   items        - Vanilla mount item ids (bags). A bag item whose item info
--                  says class 15 (Miscellaneous) subclass 5 (Mount) is taken
--                  too, so a mount missing from this list still works.
-- Vanilla 1.12 mounts only (no TBC flying / Outland mounts).
-- ============================================================================

local M = {}

-- epic before normal
M.class_spells = {
    [2] = { "Summon Charger", "Summon Warhorse" },        -- paladin
    [9] = { "Summon Dreadsteed", "Summon Felsteed" },     -- warlock
}

-- Swift / epic first so the faster mount wins when both are in the bags
M.items = {
    -- epic (swift) faction mounts
    18776, 18777, 18778,                 -- Swift Palomino / Brown Steed / White Steed
    18785, 18786, 18787,                 -- Swift White / Brown / Gray Ram
    18772, 18773, 18774,                 -- Swift Green / White / Yellow Mechanostrider
    18766, 18767, 18902,                 -- Swift Frostsaber / Mistsaber / Stormsaber
    18796, 18797, 18798,                 -- Horn of the Swift Brown / Timber / Gray Wolf
    18788, 18789, 18790,                 -- Swift Blue / Olive / Orange Raptor
    18793, 18794, 18795,                 -- Great White / Brown / Gray Kodo
    13334, 18791,                        -- Green / Purple Skeletal Warhorse
    -- PvP epic mounts
    18241, 18242, 18243, 18244, 18245, 18246, 18247, 18248,
    19029, 19030,                        -- Frostwolf Howler / Stormpike Battle Charger
    -- rare epic mounts
    13335, 19872, 19902, 13086, 12302,   -- Deathcharger, Razzashi Raptor, Zulian Tiger,
                                         -- Winterspring Frostsaber, Ancient Frostsaber
    -- normal faction mounts
    2411, 2414, 5655, 5656,              -- Black Stallion, Pinto, Chestnut Mare, Brown Horse
    5864, 5872, 5873,                    -- Gray / Brown / White Ram
    8563, 8595, 13321, 13322,            -- Red / Blue / Green / Unpainted Mechanostrider
    8629, 8631, 8632, 12303,             -- Striped Nightsaber, Striped / Spotted Frostsaber, Nightsaber
    1132, 5665, 5668, 12330, 12351,      -- Timber / Dire / Brown / Red / Arctic Wolf
    8588, 8591, 8592,                    -- Emerald / Turquoise / Violet Raptor
    15277, 15290,                        -- Gray / Brown Kodo
    13331, 13332, 13333,                 -- Red / Blue / Brown Skeletal Horse
    12353, 12354,                        -- White Stallion, Palomino
}

local rank = {}
for i, id in ipairs(M.items) do rank[id] = i end
M.rank = rank
-- 2026-10-25 (Desktop\Helper mounts.lua: fast class mount > mount item > slow class
-- mount): the swift items are the list up to the rare epics (12302 Ancient Frostsaber)
M.SWIFT_LAST = rank[12302]
M.slow_class = { ["Summon Warhorse"] = true, ["Summon Felsteed"] = true }

return M
