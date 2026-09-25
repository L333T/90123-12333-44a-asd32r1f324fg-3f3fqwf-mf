-- ============================================================================
-- Master Farmer - Grindbot
-- Consumables — conjured + vendor food/water from Orca tables
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.17.0
-- Folder: Master_Farmer_Grindbot
-- Source: orca de.lua conjuredFood / food / conjuredDrinks / drinks / foodordrink
-- Highest rank / best restore first.
-- ============================================================================

local consumables = {}

-- Conjure Food spell IDs (rank 8 -> rank 1)
consumables.CONJURE_FOOD_SPELL_IDS = {
    33717, -- Rank 8
    28612, -- Rank 7
    10145, -- Rank 6
    10144, -- Rank 5
    6129,  -- Rank 4
    990,   -- Rank 3
    597,   -- Rank 2
    587,   -- Rank 1
}

-- Conjure Water spell IDs (rank 9 -> rank 1)
consumables.CONJURE_WATER_SPELL_IDS = {
    27090, -- Rank 9
    37420, -- Rank 8
    10140, -- Rank 7
    10139, -- Rank 6
    10138, -- Rank 5
    6127,  -- Rank 4
    5506,  -- Rank 3
    5505,  -- Rank 2
    5504,  -- Rank 1
}

-- Conjured food item IDs (highest first)
consumables.CONJURED_FOOD_ITEM_IDS = {
    22019, -- Conjured Croissant
    34062, -- Conjured Manna Biscuit
    22895, -- Conjured Cinnamon Roll
    8076,  -- Conjured Sweet Roll
    8075,  -- Conjured Sourdough
    1487,  -- Conjured Pumpernickel
    1114,  -- Conjured Rye
    1113,  -- Conjured Bread
    5349,  -- Conjured Muffin
}

-- Conjured water item IDs (highest first)
consumables.CONJURED_WATER_ITEM_IDS = {
    22018, -- Conjured Glacier Water
    30703, -- Conjured Mountain Spring Water
    8079,  -- Conjured Crystal Water
    8078,  -- Conjured Sparkling Water
    8077,  -- Conjured Mineral Water
    3772,  -- Conjured Spring Water
    2136,  -- Conjured Purified Water
    2288,  -- Conjured Fresh Water
    5350,  -- Conjured Water
}

-- Dual-purpose (food + drink)
consumables.MANNA_ITEM_IDS = {
    34062, -- Conjured Manna Biscuit
    19301, -- Alterac Manna Biscuit
    13724, -- Enriched Manna Biscuit
    34780, -- Naaru Ration
}

-- ============================================================================
-- THE FULL FOOD AND DRINK LISTS
-- ============================================================================
-- Every food and drink the bot will consider, BEST FIRST. Position in these
-- lists is the whole ranking: resting.lua uses the first one it is actually
-- carrying, so earlier means better.
--
-- ORDER MATTERS, AND THE SOURCE FOOD LIST WAS NOT IN IT
--   The drink list arrived best first already - Conjured Glacier Water sixth,
--   Refreshing Spring Water last. The food list did not: it was a Vanilla
--   block in best-first order with a TBC block appended after it, so Tough
--   Jerky (level 1) sat at position 179 while Conjured Croissant (level 70)
--   sat at 188 and Smoked Talbuk Venison at 223. Taking the first held item
--   from that would have meant a level 70 mage eating Tough Jerky.
--
--   The TBC block is therefore moved in front of the Vanilla block here.
--   Neither block's internal order is touched - each was already best first -
--   and the result is one list that genuinely descends in quality.
--
-- FIVE IDS APPEAR IN BOTH
--   20031, 32722, 33053, 34062 and 34780 are the manna biscuits and rations,
--   which restore health and mana together. Being in both lists is correct:
--   they are a valid answer to either question.
-- ============================================================================

-- 242 ids: 60 from TBC, then 182 from Vanilla.
consumables.FOOD_FULL_LIST = {
    33053, 34062, 34780, 32722, 27663, 22019, 29394, 29448, 29449, 29450,
    29451, 29452, 29453, 30355, 30357, 30358, 30359, 30361, 32685, 32686,
    33048, 33052, 33872, 38428, 22895, 24008, 24009, 24539, 27651, 27655,
    27657, 27658, 27659, 27660, 27661, 27662, 27664, 27665, 27666, 27667,
    27854, 27855, 27856, 27857, 27858, 27859, 28486, 29393, 29412, 30155,
    30458, 30610, 31672, 31673, 32721, 33867, 38427, 24338, 28501, 29292,
    21215, 21023, 20031, 19301, 20516, 19996, 21236, 23172, 21240, 21254,
    19995, 21235, 19696, 19994, 8932, 20452, 13893, 18255, 13810, 18254,
    8952, 13724, 13935, 8953, 8948, 8950, 8076, 11415, 13933, 13934,
    21033, 21031, 23160, 16171, 12763, 11444, 19225, 22324, 13755, 13931,
    13928, 3927, 6887, 4599, 13932, 13929, 4608, 13930, 4602, 13927,
    16766, 21552, 4601, 19306, 9681, 21030, 16168, 8075, 17408, 18635,
    12218, 16971, 18045, 12216, 21217, 17222, 12215, 4457, 13546, 12210,
    8364, 3771, 13851, 3729, 12213, 4594, 12214, 4539, 1707, 18632,
    12212, 4544, 19224, 4607, 17407, 16169, 1487, 6038, 8543, 12211,
    6807, 20074, 3728, 1119, 5527, 4593, 3770, 7228, 12209, 3665,
    4538, 3664, 3663, 3726, 4606, 5480, 1017, 3727, 3666, 422,
    19305, 4542, 1114, 16170, 5479, 21072, 1082, 5526, 5478, 2685,
    12238, 5525, 4592, 5095, 2683, 2684, 2687, 6890, 4537, 2287,
    4541, 3220, 414, 17119, 2682, 4605, 5477, 724, 733, 1113,
    5066, 3662, 19304, 5476, 16167, 6316, 17406, 18633, 3448, 1326,
    17198, 5474, 17199, 2888, 2680, 6888, 2681, 17197, 12224, 5472,
    11109, 7808, 7806, 7807, 6299, 6290, 787, 5349, 19223, 2679,
    7097, 16166, 17344, 4536, 2070, 11584, 961, 4604, 117, 4540,
    4656, 5057,
}

-- 40 ids, best first as supplied.
consumables.DRINK_FULL_LIST = {
    33053, 34062, 34780, 20031, 32722, 22018, 27860, 29395, 29401, 30457,
    32453, 32668, 33042, 34411, 38431, 28399, 29454, 30703, 33825, 38430,
    8079, 18300, 32455, 8766, 8078, 1645, 8077, 19300, 4791, 1708,
    10841, 3772, 1205, 9451, 2136, 1179, 2288, 17404, 5350, 159,
}

-- The previous names, kept so nothing that referred to them breaks. They are
-- the same lists: the split into "vendor" and everything else stopped being
-- meaningful once these covered drops and quest rewards too.
consumables.VENDOR_FOOD_ITEM_IDS = consumables.FOOD_FULL_LIST
consumables.VENDOR_WATER_ITEM_IDS = consumables.DRINK_FULL_LIST

local function merge_unique(lists)
    local seen = {}
    local out = {}
    for i = 1, #lists do
        local list = lists[i]
        if type(list) == "table" then
            for j = 1, #list do
                local id = list[j]
                if type(id) == "number" and id > 0 and not seen[id] then
                    seen[id] = true
                    out[#out + 1] = id
                end
            end
        end
    end
    return out
end

-- The curated list comes FIRST, because its order is the ranking.
--
-- These used to lead with CONJURED_*_ITEM_IDS, which put all nine conjured
-- ranks ahead of every vendor item - so a level 70 mage carrying a leftover
-- rank 1 Conjured Water and a stack of Filtered Draenic Water would have
-- drunk the rank 1. The full lists already contain every conjured item at its
-- proper place (Conjured Glacier Water sixth, Conjured Water second from
-- last), so leading with them was both redundant and wrong.
--
-- The conjured and manna tables still follow as a safety net: anything they
-- hold that the curated list somehow misses is appended rather than lost.
consumables.FOOD_ITEM_IDS = merge_unique({
    consumables.FOOD_FULL_LIST,
    consumables.CONJURED_FOOD_ITEM_IDS,
    consumables.MANNA_ITEM_IDS,
})

consumables.WATER_ITEM_IDS = merge_unique({
    consumables.DRINK_FULL_LIST,
    consumables.CONJURED_WATER_ITEM_IDS,
    consumables.MANNA_ITEM_IDS,
})

-- Eat / drink buff spell IDs (not item IDs)
consumables.FOOD_AURA_IDS = {
    434, 435, 5004, 5005, 5006, 5007,
    10256, 10257, 18229, 18230, 18231, 18233, 18234,
    22731, 24869, 25660, 26401, 27094, 28616,
    33252, 33253, 33254, 33257, 33259, 33261, 33263, 33265, 33268,
    33725, 35270, 35271, 40768, 42293, 43763, 45618, 46683, 46899,
}

consumables.DRINK_AURA_IDS = {
    430, 431, 432, 433,
    1133, 1135, 1137,
    10250, 22734, 27089, 34291, 43182, 43183,
    43706, 46755,
}

return consumables
