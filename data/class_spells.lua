-- ============================================================================
-- Master Farmer - Grindbot
-- Class spell catalog (TBC) - what the Spells tab lists and the rotation casts
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.113.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- ONE LIST PER CLASS (2.64.0)
--   Every DPS, healing and tanking spell of the class, by the name the client
--   gives it. After the spellbook scan, the Spells tab shows the entries the
--   character actually knows - so it never lists another class's spells, a
--   profession, a passive or a spell not learned yet - and smart.lua builds the
--   rotation from the ones that are ticked. The best known rank is cast.
--
--   The ORDER of a class list is its priority: within a role the first entry
--   that can be cast wins. The roles themselves run in the order smart.lua
--   gives (heal, defensive, interrupt, ... damage, filler).
--
-- FIELDS
--   [1]    spell name, exactly as the client reports it
--   [2]    role:
--            buff      kept up on the player, in and out of combat
--            cbuff     kept up in combat only (Holy Shield, Ice Barrier...)
--            form      shapeshift / stance / presence, kept up
--            seal      paladin seal: only while actually attacking a target
--            imbue     shaman weapon imbue (checked on the main hand)
--            pet       summon (hunter / warlock); pets.lua does the upkeep
--            petheal   Mend Pet / Health Funnel
--            heal      self heal below the "Self-heal below %" slider
--            defensive below the "Defensives below %" slider
--            interrupt a casting enemy
--            resource  mana / rage generation (Life Tap, Evocation, Bloodrage)
--            opener    only before the fight has started (Charge)
--            execute   target below 20% (or `thp`)
--            control   Frost Nova, War Stomp-like: a mob in melee range
--            debuff    DoT / debuff kept on the target
--            totem     dropped once per `recast` seconds in combat
--            cooldown  burst, on a healthy target or a pack
--            aoe       with enough enemies (the "AoE when" slider or `n`)
--            finisher  combo-point spender
--            damage    the main rotation, in list order
--            filler    wand / auto shot, last
--   on       ticked by default (false = listed but unticked)
--   g        exclusive group: only the FIRST ticked, known member is used
--            (one aura, one seal, one armor, one stance, one pet...)
--   melee    needs melee range; `min` = minimum yards (hunter dead zone)
--   form     druid form / warrior stance the spell needs (string or list)
--   self     cast on the player (default for buff / heal / defensive ...)
--   enemy    cast on the target although the role is a self one (Drain Life)
--   ground   cast at the target's position (Blizzard, Flamestrike...)
--   center   "self" or "target" for an AoE count (default "target")
--   r        AoE radius (default 10); n = enemies needed
--   thp      execute: target health below; debuff/cooldown: target above
--   hp       heal / defensive threshold override (percent)
--   cp       finisher: combo points needed
--   hot      heal-over-time: skipped while its buff is on the player
--   ctype    target creature types it works on ("UNDEAD", "DEMON")
--   when     function(c) -> bool, the spell-specific condition (see smart.lua
--            for what `c` offers)
--   recast   totem: seconds before it is dropped again
--   tip      tooltip in the Spells tab
-- ============================================================================

local W = {}

local function t(list)
    return list
end

-- Shared conditions --------------------------------------------------------
local function mana_below(p)
    return function(c) return c.mana() < p end
end

local function rage_at_least(r)
    return function(c) return c.rage() >= r end
end

-- ============================================================================
-- WARRIOR
-- ============================================================================
W.WARRIOR = t({
    { "Battle Stance",     "form", on = true,  g = "stance", tip = "The stance this rotation fights in. Only one stance is kept." },
    { "Defensive Stance",  "form", on = false, g = "stance" },
    { "Berserker Stance",  "form", on = false, g = "stance" },
    { "Battle Shout",      "buff", on = true,  g = "shout" },
    { "Commanding Shout",  "buff", on = false, g = "shout" },

    { "Charge",            "opener", on = true, form = "battle",
      when = function(c) return c.dist() >= 8 and c.dist() <= 25 end, tip = "Opens the fight from 8-25 yards." },
    { "Intercept",         "opener", on = true, form = "berserker",
      when = function(c) return c.dist() >= 8 and c.dist() <= 25 end },

    { "Last Stand",        "defensive", on = true },
    { "Shield Wall",       "defensive", on = true, form = "defensive" },
    { "Intimidating Shout","defensive", on = false, enemy = true, when = function(c) return c.near(8) >= 2 end },

    { "Pummel",            "interrupt", on = true, melee = true, form = "berserker" },
    { "Shield Bash",       "interrupt", on = true, melee = true, form = { "battle", "defensive" } },

    { "Bloodrage",         "resource", on = true, self = true,
      when = function(c) return c.rage() < 30 and c.hp() > 50 end },
    { "Berserker Rage",    "resource", on = false, self = true, form = "berserker" },

    { "Victory Rush",      "execute", on = true, melee = true, thp = 101 },
    { "Execute",           "execute", on = true, melee = true, form = { "battle", "berserker" } },

    { "Rend",              "debuff", on = true, melee = true, form = { "battle", "defensive" }, thp = 50,
      when = function(c) return not c.ttype("UNDEAD") and not c.ttype("ELEMENTAL") and not c.ttype("MECHANICAL") end },
    { "Demoralizing Shout","debuff", on = false, self = true, when = function(c) return c.near(10) >= 2 end },
    { "Thunder Clap",      "debuff", on = true, self = true, form = { "battle", "defensive" },
      when = function(c) return c.near(8) >= 2 end },
    { "Sunder Armor",      "debuff", on = false, melee = true },

    { "Death Wish",        "cooldown", on = true, self = true },
    { "Recklessness",      "cooldown", on = false, self = true, form = "berserker" },
    { "Sweeping Strikes",  "cooldown", on = true, self = true, form = { "battle", "berserker" },
      when = function(c) return c.near(8) >= 2 end },

    { "Whirlwind",         "aoe", on = true, center = "self", r = 8, n = 2, form = "berserker" },
    { "Cleave",            "aoe", on = true, melee = true, n = 2, r = 8, when = rage_at_least(40) },

    { "Overpower",         "damage", on = true, melee = true, form = "battle" },
    { "Revenge",           "damage", on = true, melee = true, form = "defensive" },
    { "Shield Slam",       "damage", on = true, melee = true },
    { "Mortal Strike",     "damage", on = true, melee = true },
    { "Bloodthirst",       "damage", on = true, melee = true },
    { "Whirlwind",         "damage", on = true, melee = true, form = "berserker" },
    { "Devastate",         "damage", on = true, melee = true },
    { "Slam",              "damage", on = false, melee = true },
    { "Heroic Strike",     "damage", on = true, melee = true, when = rage_at_least(50),
      tip = "Rage dump: only with 50+ rage, so the specials are never starved." },
    { "Hamstring",         "damage", on = false, melee = true },
})

-- ============================================================================
-- PALADIN
-- ============================================================================
local function seal_up(c)
    return c.group_up("seal")
end

W.PALADIN = t({
    { "Devotion Aura",          "form", on = true,  g = "aura", tip = "Only one aura can be active: the first ticked one is kept up." },
    { "Retribution Aura",       "form", on = false, g = "aura" },
    { "Sanctity Aura",          "form", on = false, g = "aura" },
    { "Concentration Aura",     "form", on = false, g = "aura" },
    { "Crusader Aura",          "form", on = false, g = "aura" },
    { "Frost Resistance Aura",  "form", on = false, g = "aura" },
    { "Shadow Resistance Aura", "form", on = false, g = "aura" },
    { "Fire Resistance Aura",   "form", on = false, g = "aura" },

    { "Blessing of Might",      "buff", on = true,  g = "blessing", tip = "One blessing on yourself: the first ticked one." },
    { "Blessing of Wisdom",     "buff", on = true,  g = "blessing" },
    { "Blessing of Kings",      "buff", on = false, g = "blessing" },
    { "Blessing of Sanctuary",  "buff", on = false, g = "blessing" },
    { "Blessing of Light",      "buff", on = false, g = "blessing" },
    { "Righteous Fury",         "buff", on = false, tip = "Tanking: more threat from holy damage." },
    { "Holy Shield",            "cbuff", on = false },

    { "Seal of Righteousness",  "seal", on = true,  g = "seal", tip = "Cast only while actually attacking a target - never on the walk in or out of combat." },
    { "Seal of Command",        "seal", on = false, g = "seal" },
    { "Seal of Blood",          "seal", on = false, g = "seal" },
    { "Seal of Vengeance",      "seal", on = false, g = "seal" },
    { "Seal of the Crusader",   "seal", on = false, g = "seal" },
    { "Seal of Light",          "seal", on = false, g = "seal" },
    { "Seal of Wisdom",         "seal", on = false, g = "seal" },

    { "Flash of Light",         "heal", on = true },
    { "Holy Light",             "heal", on = true, when = function(c) return c.hp() < c.heal_pct() - 15 end },
    { "Holy Shock",             "heal", on = true },
    { "Lay on Hands",           "defensive", on = true, hp = 15 },
    { "Divine Shield",          "defensive", on = true, hp = 20 },
    { "Divine Protection",      "defensive", on = true },

    { "Hammer of Justice",      "interrupt", on = true },

    { "Hammer of Wrath",        "execute", on = true },

    { "Avenging Wrath",         "cooldown", on = true, self = true },

    { "Consecration",           "aoe", on = false, self = true, center = "self", r = 8, tip = "Off by default: expensive, and pulls adds when soloing." },
    { "Holy Wrath",             "aoe", on = false, self = true, center = "self", r = 20, ctype = { "UNDEAD", "DEMON" } },

    { "Judgement",              "damage", on = true, when = seal_up, tip = "Only with a seal up - judging with none wastes the cooldown." },
    { "Crusader Strike",        "damage", on = true, melee = true },
    { "Avenger's Shield",       "damage", on = false },
    { "Exorcism",               "damage", on = true, ctype = { "UNDEAD", "DEMON" } },
})

-- ============================================================================
-- HUNTER
-- ============================================================================
W.HUNTER = t({
    { "Aspect of the Hawk",     "form", on = true,  g = "aspect", tip = "One aspect at a time: the first ticked one you know." },
    { "Aspect of the Monkey",   "form", on = true,  g = "aspect" },
    { "Aspect of the Viper",    "form", on = false, g = "aspect" },
    { "Trueshot Aura",          "buff", on = true },

    { "Call Pet",               "pet",  on = true, tip = "Summons, revives and heals the pet out of combat." },
    { "Mend Pet",               "petheal", on = true },

    { "Deterrence",             "defensive", on = true },
    { "Intimidation",           "interrupt", on = true },

    { "Hunter's Mark",          "debuff", on = true, min = 0 },
    { "Serpent Sting",          "debuff", on = true, min = 8, g = "sting", thp = 40 },
    { "Viper Sting",            "debuff", on = false, min = 8, g = "sting" },

    { "Bestial Wrath",          "cooldown", on = true, self = true },
    { "Rapid Fire",             "cooldown", on = true, self = true },

    { "Multi-Shot",             "aoe", on = true, min = 8, n = 2 },

    { "Raptor Strike",          "damage", on = true, melee = true },
    { "Mongoose Bite",          "damage", on = true, melee = true },
    { "Wing Clip",              "damage", on = false, melee = true },
    { "Concussive Shot",        "damage", on = false, when = function(c) return c.dist() <= 10 end },
    { "Kill Command",           "damage", on = true },
    { "Arcane Shot",            "damage", on = true, min = 8 },
    { "Steady Shot",            "damage", on = true, min = 8 },

    { "Auto Shot",              "filler", on = true, min = 8 },
})

-- ============================================================================
-- ROGUE
-- ============================================================================
W.ROGUE = t({
    { "Evasion",                "defensive", on = true, when = function(c) return c.near(8) >= 2 or c.hp() < c.def_pct() end, hp = 101 },
    { "Cloak of Shadows",       "defensive", on = true },
    { "Kick",                   "interrupt", on = true, melee = true },
    { "Gouge",                  "interrupt", on = false, melee = true },

    { "Adrenaline Rush",        "cooldown", on = true, self = true },
    { "Blade Flurry",           "cooldown", on = true, self = true, when = function(c) return c.near(8) >= 2 end },
    { "Cold Blood",             "cooldown", on = true, self = true, when = function(c) return c.cp() >= 4 end },

    { "Slice and Dice",         "finisher", on = true, self = true, cp = 2, thp = 30,
      when = function(c) return not c.buff("Slice and Dice") end },
    { "Rupture",                "finisher", on = false, melee = true, cp = 4, thp = 50,
      when = function(c) return not c.debuff("Rupture") end },
    { "Envenom",                "finisher", on = false, melee = true, cp = 4 },
    { "Eviscerate",             "finisher", on = true, melee = true, cp = 4 },

    { "Riposte",                "damage", on = true, melee = true },
    { "Ghostly Strike",         "damage", on = true, melee = true },
    { "Mutilate",               "damage", on = true, melee = true },
    { "Hemorrhage",             "damage", on = true, melee = true },
    { "Backstab",               "damage", on = false, melee = true, tip = "Needs to be behind the target and a dagger." },
    { "Sinister Strike",        "damage", on = true, melee = true },
})

-- ============================================================================
-- PRIEST
-- ============================================================================
local function not_shadowform(c)
    return not c.buff("Shadowform")
end

W.PRIEST = t({
    { "Power Word: Fortitude",  "buff", on = true },
    { "Inner Fire",             "buff", on = true },
    { "Divine Spirit",          "buff", on = true },
    { "Shadow Protection",      "buff", on = false },
    { "Fear Ward",              "buff", on = false },
    { "Touch of Weakness",      "buff", on = true },
    { "Shadowguard",            "buff", on = true },
    { "Shadowform",             "form", on = false, tip = "Shadow priests: blocks holy spells, so heals stop while it is up." },

    { "Power Word: Shield",     "heal", on = true, hp = 101,
      when = function(c) return c.in_combat() and c.hp() < 90 and not c.self_debuff_id(6788) end,
      tip = "Kept up in combat (not while Weakened Soul is on you)." },
    { "Flash Heal",             "heal", on = true, when = not_shadowform },
    { "Renew",                  "heal", on = true, hot = true, when = not_shadowform },
    { "Greater Heal",           "heal", on = true, when = function(c) return not_shadowform(c) and c.hp() < c.heal_pct() - 15 end },
    { "Heal",                   "heal", on = true, when = function(c) return not_shadowform(c) and c.hp() < c.heal_pct() - 15 end },
    { "Lesser Heal",            "heal", on = true, when = not_shadowform },
    { "Desperate Prayer",       "defensive", on = true },
    { "Psychic Scream",         "defensive", on = true, when = function(c) return c.near(8) >= 1 end },

    { "Silence",                "interrupt", on = true },

    { "Shadowfiend",            "resource", on = true, enemy = true, when = mana_below(50) },
    { "Shadow Word: Death",     "execute", on = true, when = function(c) return c.hp() > 40 end },

    { "Vampiric Touch",         "debuff", on = true, thp = 30 },
    { "Shadow Word: Pain",      "debuff", on = true, thp = 25 },
    { "Devouring Plague",       "debuff", on = true, thp = 30 },
    { "Vampiric Embrace",       "debuff", on = true, thp = 40 },

    { "Inner Focus",            "cooldown", on = true, self = true },

    { "Holy Nova",              "aoe", on = false, self = true, center = "self", r = 10 },

    { "Mind Blast",             "damage", on = true },
    { "Holy Fire",              "damage", on = false, when = not_shadowform },
    { "Mind Flay",              "damage", on = true },
    { "Smite",                  "damage", on = true, when = not_shadowform },

    { "Shoot",                  "filler", on = true, tip = "Wand, once mana drops below the wand slider." },
})

-- ============================================================================
-- SHAMAN
-- ============================================================================
W.SHAMAN = t({
    { "Water Shield",           "buff", on = false, g = "shield" },
    { "Lightning Shield",       "buff", on = true,  g = "shield" },
    { "Windfury Weapon",        "imbue", on = true, g = "imbue", tip = "One main-hand imbue: the first ticked one you know." },
    { "Flametongue Weapon",     "imbue", on = true, g = "imbue" },
    { "Frostbrand Weapon",      "imbue", on = false, g = "imbue" },
    { "Rockbiter Weapon",       "imbue", on = true, g = "imbue" },

    { "Lesser Healing Wave",    "heal", on = true },
    { "Healing Wave",           "heal", on = true },

    { "Shamanistic Rage",       "defensive", on = true },
    { "Earth Shock",            "interrupt", on = true },

    { "Searing Totem",          "totem", on = true, recast = 50, when = function(c) return c.dist() <= 20 end },
    { "Strength of Earth Totem","totem", on = false, recast = 110 },
    { "Stoneskin Totem",        "totem", on = false, recast = 110 },
    { "Mana Spring Totem",      "totem", on = false, recast = 110 },
    { "Windfury Totem",         "totem", on = false, recast = 110 },
    { "Grace of Air Totem",     "totem", on = false, recast = 110 },

    { "Flame Shock",            "debuff", on = true, thp = 40 },

    { "Elemental Mastery",      "cooldown", on = true, self = true },
    { "Bloodlust",              "cooldown", on = false, self = true },
    { "Heroism",                "cooldown", on = false, self = true },

    { "Chain Lightning",        "aoe", on = true, n = 2 },
    { "Fire Nova Totem",        "aoe", on = false, self = true, center = "self", r = 10 },

    { "Stormstrike",            "damage", on = true, melee = true, tip = "Ticking this makes the shaman fight in melee." },
    { "Frost Shock",            "damage", on = false },
    { "Lightning Bolt",         "damage", on = true },
})

-- ============================================================================
-- MAGE
-- ============================================================================
local function target_frozen(c)
    return c.tdebuff_any({ 122, 865, 6131, 10230, 27088, 12494, 33395 })
end

W.MAGE = t({
    { "Molten Armor",           "buff", on = false, g = "armor", tip = "One armor at a time: the first ticked one you know." },
    { "Mage Armor",             "buff", on = false, g = "armor" },
    { "Ice Armor",              "buff", on = true,  g = "armor" },
    { "Frost Armor",            "buff", on = true,  g = "armor" },
    { "Arcane Intellect",       "buff", on = true },
    { "Ice Barrier",            "buff", on = true },

    { "Summon Water Elemental", "cooldown", on = true, self = true },

    { "Mana Shield",            "defensive", on = false, when = function(c) return c.mana() > 30 end },
    { "Ice Block",              "defensive", on = false, hp = 15 },

    { "Counterspell",           "interrupt", on = true },

    { "Evocation",              "resource", on = true, self = true,
      when = function(c) return c.mana() < 15 and c.near(10) == 0 end },

    { "Frost Nova",             "control", on = true, self = true,
      when = function(c) return c.near(6) >= 1 end,
      tip = "When an enemy is within 6 yards - then the mage backs off for 2.5 seconds." },
    { "Cone of Cold",           "aoe", on = false, center = "self", r = 10, n = 2 },
    { "Blast Wave",             "aoe", on = true, self = true, center = "self", r = 8, n = 2 },
    { "Dragon's Breath",        "aoe", on = true, center = "self", r = 8, n = 2 },
    { "Arcane Explosion",       "aoe", on = true, self = true, center = "self", r = 10 },
    { "Blizzard",               "aoe", on = false, ground = true },
    { "Flamestrike",            "aoe", on = false, ground = true },

    { "Icy Veins",              "cooldown", on = true, self = true },
    { "Arcane Power",           "cooldown", on = false, self = true },
    { "Presence of Mind",       "cooldown", on = true, self = true },
    { "Combustion",             "cooldown", on = true, self = true },
    { "Cold Snap",              "cooldown", on = false, self = true },

    { "Ice Lance",              "damage", on = true, when = target_frozen, tip = "Only on a frozen target." },
    { "Fire Blast",             "damage", on = true },
    { "Frostbolt",              "damage", on = true },
    { "Fireball",               "damage", on = true },
    { "Arcane Blast",           "damage", on = false },
    { "Arcane Missiles",        "damage", on = false },
    { "Scorch",                 "damage", on = false },
    { "Pyroblast",              "damage", on = false },

    { "Shoot",                  "filler", on = true, tip = "Wand, once mana drops below the wand slider." },
})

-- ============================================================================
-- WARLOCK
-- ============================================================================
W.WARLOCK = t({
    { "Fel Armor",              "buff", on = true, g = "armor", tip = "One armor at a time: the first ticked one you know." },
    { "Demon Armor",            "buff", on = true, g = "armor" },
    { "Demon Skin",             "buff", on = true, g = "armor" },

    { "Summon Felguard",        "pet", on = true,  g = "pet", tip = "One demon: the first ticked one you know." },
    { "Summon Voidwalker",      "pet", on = true,  g = "pet" },
    { "Summon Felhunter",       "pet", on = false, g = "pet" },
    { "Summon Succubus",        "pet", on = false, g = "pet" },
    { "Summon Imp",             "pet", on = true,  g = "pet" },
    { "Health Funnel",          "petheal", on = true },

    { "Drain Life",             "heal", on = true, enemy = true },
    { "Death Coil",             "defensive", on = true, enemy = true },
    { "Howl of Terror",         "defensive", on = false, when = function(c) return c.near(10) >= 2 end },

    { "Spell Lock",             "interrupt", on = true },

    { "Life Tap",               "resource", on = true, self = true,
      when = function(c) return c.mana() < 40 and c.hp() > 60 end },
    { "Dark Pact",              "resource", on = false, self = true, when = mana_below(40) },

    { "Shadowburn",             "execute", on = true },
    { "Drain Soul",             "execute", on = false, thp = 25 },

    { "Curse of Agony",         "debuff", on = true,  g = "curse", thp = 40 },
    { "Curse of the Elements",  "debuff", on = false, g = "curse" },
    { "Curse of Recklessness",  "debuff", on = false, g = "curse" },
    { "Curse of Weakness",      "debuff", on = false, g = "curse" },
    { "Curse of Tongues",       "debuff", on = false, g = "curse" },
    { "Curse of Doom",          "debuff", on = false, g = "curse", thp = 60 },
    { "Unstable Affliction",    "debuff", on = true, thp = 40 },
    { "Corruption",             "debuff", on = true, thp = 30 },
    { "Siphon Life",            "debuff", on = true, thp = 40 },
    { "Immolate",               "debuff", on = true, thp = 40 },

    { "Amplify Curse",          "cooldown", on = true, self = true },

    { "Seed of Corruption",     "aoe", on = true },
    { "Rain of Fire",           "aoe", on = false, ground = true },
    { "Hellfire",               "aoe", on = false, self = true, center = "self", r = 10, tip = "Burns you too." },

    { "Conflagrate",            "damage", on = true, when = function(c) return c.debuff("Immolate") end },
    { "Shadow Bolt",            "damage", on = true },
    { "Incinerate",             "damage", on = false },
    { "Searing Pain",           "damage", on = false },
    { "Soul Fire",              "damage", on = false },

    { "Shoot",                  "filler", on = true, tip = "Wand, once mana drops below the wand slider." },
})

-- ============================================================================
-- DRUID
-- ============================================================================
local CASTER = { "caster", "moonkin" }

W.DRUID = t({
    { "Mark of the Wild",       "buff", on = true, form = "caster" },
    { "Thorns",                 "buff", on = true, form = "caster" },
    { "Omen of Clarity",        "buff", on = true, form = "caster" },
    { "Moonkin Form",           "form", on = false, g = "form", tip = "One form: the first ticked one. Cat and Bear are taken when a fight starts." },
    { "Tree of Life",           "form", on = false, g = "form" },
    { "Cat Form",               "form", on = false, g = "form" },
    { "Dire Bear Form",         "form", on = false, g = "form" },
    { "Bear Form",              "form", on = false, g = "form" },

    { "Regrowth",               "heal", on = true, form = { "caster", "tree" }, hot = true },
    { "Rejuvenation",           "heal", on = true, form = { "caster", "tree" }, hot = true },
    { "Lifebloom",              "heal", on = false, form = { "caster", "tree" }, hot = true },
    { "Swiftmend",              "heal", on = false, form = { "caster", "tree" } },
    { "Healing Touch",          "heal", on = true, form = { "caster", "tree" },
      when = function(c) return c.hp() < c.heal_pct() - 15 end },

    { "Barkskin",               "defensive", on = true },
    { "Frenzied Regeneration",  "defensive", on = true, form = "bear" },

    { "Bash",                   "interrupt", on = true, melee = true, form = "bear" },

    { "Innervate",              "resource", on = true, self = true, when = mana_below(20) },
    { "Enrage",                 "resource", on = true, self = true, form = "bear", when = function(c) return c.rage() < 20 end },

    { "Faerie Fire (Feral)",    "debuff", on = true, form = { "cat", "bear" } },
    { "Faerie Fire",            "debuff", on = false, form = CASTER },
    { "Moonfire",               "debuff", on = true, form = CASTER, thp = 30 },
    { "Insect Swarm",           "debuff", on = true, form = CASTER, thp = 40 },
    { "Demoralizing Roar",      "debuff", on = true, self = true, form = "bear", when = function(c) return c.near(10) >= 1 end },
    { "Rake",                   "debuff", on = true, melee = true, form = "cat", thp = 40 },
    { "Lacerate",               "debuff", on = true, melee = true, form = "bear" },

    { "Tiger's Fury",           "cooldown", on = true, self = true, form = "cat" },

    { "Swipe",                  "aoe", on = true, melee = true, form = "bear", n = 2, r = 8 },
    { "Hurricane",              "aoe", on = false, ground = true, form = CASTER },

    { "Rip",                    "finisher", on = true, melee = true, form = "cat", cp = 4, thp = 40,
      when = function(c) return not c.debuff("Rip") end },
    { "Ferocious Bite",         "finisher", on = true, melee = true, form = "cat", cp = 4 },

    { "Mangle (Cat)",           "damage", on = true, melee = true, form = "cat" },
    { "Shred",                  "damage", on = false, melee = true, form = "cat", tip = "Needs to be behind the target." },
    { "Claw",                   "damage", on = true, melee = true, form = "cat" },
    { "Mangle (Bear)",          "damage", on = true, melee = true, form = "bear" },
    { "Maul",                   "damage", on = true, melee = true, form = "bear", when = rage_at_least(20) },
    { "Starfire",               "damage", on = false, form = CASTER },
    { "Wrath",                  "damage", on = true, form = CASTER },
})

-- ============================================================================
-- DISPLAY
-- ============================================================================
-- The Spells tab groups rows by these headings, in this order.
local SECTIONS = {
    { key = "buffs",     label = "Buffs, Auras & Forms", roles = { buff = true, cbuff = true, form = true, seal = true, imbue = true } },
    { key = "pet",       label = "Pet",                  roles = { pet = true, petheal = true } },
    { key = "damage",    label = "Damage",               roles = { damage = true, execute = true, opener = true, finisher = true, filler = true } },
    { key = "debuff",    label = "Damage over Time & Debuffs", roles = { debuff = true, totem = true } },
    { key = "aoe",       label = "Area of Effect",       roles = { aoe = true, control = true } },
    { key = "cooldown",  label = "Cooldowns & Resources", roles = { cooldown = true, resource = true } },
    { key = "heal",      label = "Healing",              roles = { heal = true } },
    { key = "defensive", label = "Defensive",            roles = { defensive = true } },
    { key = "interrupt", label = "Interrupts",           roles = { interrupt = true } },
    { key = "racial",    label = "Racial",               roles = { racial = true } },
}

local M = {}
M.sections = SECTIONS

-- Keyed on the SDK's own class ids rather than hard-coded numbers.
local CLASS_KEY = {}
do
    local ok, enums = pcall(require, "common/enums")
    local ids = ok and type(enums) == "table" and enums.class_id or nil
    if type(ids) == "table" then
        for key in pairs(W) do
            if type(ids[key]) == "number" then
                CLASS_KEY[ids[key]] = key
            end
        end
    end
end

--- The catalog for a class id (the client's own numbering), or an empty list.
function M.for_class(class_id)
    local key = CLASS_KEY[class_id]
    return key and W[key] or {}
end

function M.class_key(class_id)
    return CLASS_KEY[class_id]
end

--- The Spells tab section a role belongs to.
function M.section_of(role)
    for i = 1, #SECTIONS do
        if SECTIONS[i].roles[role] then
            return SECTIONS[i].key
        end
    end
    return "damage"
end

return M
