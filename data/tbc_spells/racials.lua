-- ============================================================================
-- TBC racial spell ids by race (GENERATED - tools/gen_tbc_spells.py, do not edit)
-- ============================================================================
-- From old_code/db/spellsTBC. Names are comments only (see the generator).
-- ============================================================================

-- [race_id] = { { id, classes }, ... }; classes nil = every class
return {
    [1] = {
        { 20599, nil },  -- Diplomacy
        { 20864, nil },  -- Mace Specialization
        { 20600, nil },  -- Perception
        { 20597, nil },  -- Sword Specialization
        { 20598, nil },  -- The Human Spirit
    },
    [2] = {
        { 20574, nil },  -- Axe Specialization
        { 20572, { 1, 3, 4 } },  -- Blood Fury
        { 33697, { 7 } },  -- Blood Fury
        { 33702, { 9 } },  -- Blood Fury
        { 20575, { 9 } },  -- Command
        { 20573, nil },  -- Hardiness
    },
    [3] = {
        { 2481, nil },  -- Find Treasure
        { 20596, nil },  -- Frost Resistance
        { 20595, nil },  -- Gun Specialization
        { 20594, nil },  -- Stoneform
    },
    [4] = {
        { 20583, nil },  -- Nature Resistance
        { 20582, nil },  -- Quickness
        { 20580, { 4 } },  -- Shadowmeld
        { 20585, nil },  -- Wisp Spirit
    },
    [5] = {
        { 20577, nil },  -- Cannibalize
        { 20579, nil },  -- Shadow Resistance
        { 5227, nil },  -- Underwater Breathing
        { 7744, nil },  -- Will of the Forsaken
    },
    [6] = {
        { 20552, nil },  -- Cultivation
        { 20550, nil },  -- Endurance
        { 20551, nil },  -- Nature Resistance
        { 20549, nil },  -- War Stomp
    },
    [7] = {
        { 20592, nil },  -- Arcane Resistance
        { 20593, nil },  -- Engineering Specialization
        { 20589, nil },  -- Escape Artist
        { 20591, nil },  -- Expansive Mind
    },
    [8] = {
        { 20557, nil },  -- Beast Slaying
        { 20554, { 2, 3, 5, 7, 8, 9, 11 } },  -- Berserking
        { 26296, { 1 } },  -- Berserking
        { 26297, { 4 } },  -- Berserking
        { 26290, nil },  -- Bow Specialization
        { 20555, nil },  -- Regeneration
        { 20558, nil },  -- Throwing Specialization
    },
    [10] = {
        { 28877, nil },  -- Arcane Affinity
        { 25046, { 4 } },  -- Arcane Torrent
        { 28730, { 2, 3, 5, 8, 9 } },  -- Arcane Torrent
        { 822, nil },  -- Magic Resistance
        { 28734, { 8 } },  -- Mana Tap
    },
    [11] = {
        { 28875, nil },  -- Gemcutting
        { 28880, { 5 } },  -- Gift of the Naaru
        { 6562, { 1, 2, 3 } },  -- Heroic Presence
        { 28878, { 5, 7, 8 } },  -- Inspiring Presence
        { 20579, nil },  -- Shadow Resistance
    },
}
