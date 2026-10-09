-- ============================================================================
-- Master Farmer - Grindbot
-- Warrior grind filler (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.246.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- RAGE IS NOT MANA AND NOT ENERGY
--   Rage is earned by fighting and decays out of combat, so there is nothing
--   to conserve and nothing to drink for. A warrior opens a fight with an
--   empty bar, which is why the rotation leads with what is cheap and keeps
--   Heroic Strike behind a rage floor: spend it too early and the specials
--   never fire.
--
--   resting.lua already gates drinking on mana_max > 0, so the drink
--   threshold passed below is inert for this class. It is passed anyway so
--   the interface reads the same as the other eight.
--
-- STANCES: THIS ROTATION DOES NOT DANCE
--   Most of the warrior book is stance-locked. Whirlwind and Pummel need
--   Berserker, Shield Bash and Taunt need Defensive, Charge and Overpower
--   need Battle. Switching stance costs rage, drops the rest, and takes a
--   global - doing it mid-fight to fit one ability in is a trade this bot
--   cannot judge, and a rotation that flickers between stances spends the
--   whole fight paying for the privilege.
--
--   So: Battle Stance is maintained out of combat when the toggle is on, and
--   the stance-locked abilities are offered only when the player is ALREADY
--   in the right stance. A Fury warrior who lives in Berserker gets
--   Whirlwind and Pummel; an Arms warrior in Battle gets Overpower. Neither
--   gets moved.
--
--   core.spell_book.get_shapeshift_form_id is what reports this. Nothing else
--   in the project reads it yet, so it is called through pcall and an
--   unreadable stance means "do not offer the stance-locked abilities"
--   rather than an error.
--
-- OVERPOWER IS OFF BY DEFAULT
--   It is only usable for five seconds after the target dodges, and no call
--   in the reflected reference reports a dodge. The spell simply fails when
--   the window is closed, which costs a tick. Left in, defaulted off, so a
--   player who wants it can have it.
--
-- SPELL IDS
--   Highest rank first; mfg_warrior_debug prints what resolved. Wrong or
--   missing ids degrade to "not learned" rather than erroring, because every
--   use is behind learned().
-- ============================================================================

---@type enums
local enums = require("common/enums")

local gui = require("gui")
local resting = require("resting")
local racials = require("racials")
local state = require("state")
local spellbook = require("spellbook")
local auras = require("auras")

local warrior = {}

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local function learned(spell)
    if not spell or not spellbook.ready() then return false end
    return spellbook.spell_known(spell)
end

--- Current rage, 0-100.
---
--- rage_current is the documented name and is what a warrior build will have;
--- power_current(RAGE) is the generic form and is kept as the fallback. A
--- build that can report neither returns 0, which reads as "no rage" and
--- leaves the rage-gated abilities alone rather than firing them blind.
local function rage(player)
    local r = safe(function() return player:rage_current() end)
    if type(r) == "number" then return r end
    local pt = enums.power_type and enums.power_type.RAGE
    if type(pt) == "number" then
        r = safe(function() return player:power_current(pt) end)
        if type(r) == "number" then return r end
    end
    return 0
end

--- The stance the player is in, or nil when it cannot be read.
---
--- Nil is not "Battle". Everything stance-locked below treats nil as "do not
--- offer", because guessing wrong means queueing an ability the server will
--- refuse on every tick.
local function stance()
    local f = safe(function() return core.spell_book.get_shapeshift_form_id() end)
    if type(f) == "number" and f > 0 then return f end
    return nil
end

-- ----------------------------------------------------------------------------
-- IDENTITY
-- ----------------------------------------------------------------------------
function warrior.class_id() return enums.class_id.WARRIOR end
function warrior.label() return "Warrior" end
function warrior.combat_range(player) return 5 end
function warrior.is_melee(player) return true end

--- How far out to look for something to fight.
---
--- Melee has to walk into contact and then stand still, so a wide scan only
--- drags extra mobs into a fight it cannot kite out of.
function warrior.scan_range(player)
    return 20
end

-- Pure melee with no ranged filler: stepping out is a flat DPS loss, the
-- target simply follows, and a warrior who backs off loses the rage that
-- pays for everything. Never retreats.
function warrior.combat_profile()
    return {
        name = "warrior", melee_danger = 0, melee_safe = 0,
        should_retreat = function() return false end,
    }
end

-- ----------------------------------------------------------------------------
-- RESTING
-- ----------------------------------------------------------------------------
--- Sit down and eat. The thresholds are this class's to choose; the machinery
--- lives in resting.lua so a fix lands once rather than nine times.
---
--- drink_pct is inert here - resting.lua gates drinking on mana_max > 0 and a
--- warrior has none - and is passed so this reads like the other eight.
function warrior.rest(player)
    return resting.tick(player, { eat_pct = 35, drink_pct = 0 })
end

return warrior
