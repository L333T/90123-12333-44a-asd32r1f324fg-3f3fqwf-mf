-- ============================================================================
-- Master Farmer - Grindbot
-- Warrior grind filler (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.18.0
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

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local gui = require("gui")
local resting = require("resting")
local racials = require("racials")
local state = require("state")
local spellbook = require("spellbook")
local range = require("spell_range")
local auras = require("auras")
local sequence = require("rotations/sequence")

local warrior = {}

-- Stance form ids, as the client reports them for a warrior.
local STANCE_BATTLE    = 1
local STANCE_DEFENSIVE = 2
local STANCE_BERSERKER = 3

local DOT_LEAD = 2.0

local function make(ids, track_buff, track_debuff)
    local spell = izi.spell(ids)
    if not spell then return nil end
    if track_buff and spell.track_buff then spell:track_buff(ids) end
    if track_debuff and spell.track_debuff then spell:track_debuff(ids) end
    return spellbook.watch(spell)
end

local BATTLE_SHOUT_IDS = { 2048, 11551, 11550, 11549, 6673 }
local REND_IDS         = { 25208, 11574, 11573, 11572, 6548, 6547, 6546, 772 }
local DEMO_SHOUT_IDS   = { 25203, 11556, 11555, 6190, 1160 }
local VICTORIOUS_IDS   = { 32216 }

local battle_shout   = make(BATTLE_SHOUT_IDS, true, false)
local rend           = make(REND_IDS, false, true)
local demo_shout     = make(DEMO_SHOUT_IDS, false, true)

local mortal_strike  = make({ 30330, 21553, 21552, 21551, 12294 })
local bloodthirst    = make({ 30335, 23894, 23893, 23892, 23881 })
local whirlwind      = make({ 1680 })
local execute        = make({ 25236, 25234, 20662, 20661, 20660, 20658, 5308 })
local overpower      = make({ 11585, 11584, 7887, 7384 })
local heroic_strike  = make({ 29707, 25286, 11567, 11566, 11565, 11564, 1608, 284, 78 })
local cleave         = make({ 25231, 20569, 11609, 11608, 845 })
local thunder_clap   = make({ 25264, 11581, 11580, 8205, 8204, 8198, 6343 })
local sunder_armor   = make({ 25225, 11597, 11596, 8380, 7405, 7386 })
local hamstring      = make({ 25212, 7373, 7372, 1715 })
local victory_rush   = make({ 34428 })
local bloodrage      = make({ 2687 })
local berserker_rage = make({ 18499 })
local pummel         = make({ 6554, 6552 })
local shield_bash    = make({ 1672, 1671, 72 })
local taunt          = make({ 355 })
local battle_stance  = make({ 2457 })

local SPELL_LABELS = {
    { "Battle Shout", battle_shout }, { "Rend", rend },
    { "Demoralizing Shout", demo_shout }, { "Mortal Strike", mortal_strike },
    { "Bloodthirst", bloodthirst }, { "Whirlwind", whirlwind },
    { "Execute", execute }, { "Overpower", overpower },
    { "Heroic Strike", heroic_strike }, { "Cleave", cleave },
    { "Thunder Clap", thunder_clap }, { "Sunder Armor", sunder_armor },
    { "Hamstring", hamstring }, { "Victory Rush", victory_rush },
    { "Bloodrage", bloodrage }, { "Berserker Rage", berserker_rage },
    { "Pummel", pummel }, { "Shield Bash", shield_bash },
    { "Taunt", taunt }, { "Battle Stance", battle_stance },
}

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local function rotation_note(text)
    local ok, rotation = pcall(require, "rotation")
    if ok and rotation and type(rotation.set_last_action) == "function" then
        rotation.set_last_action(text)
    end
    state.last_action = text
end

local function learned(spell)
    if not spell or not spellbook.ready() then return false end
    return spellbook.spell_known(spell)
end

local function as_pct(v)
    if type(v) ~= "number" then return nil end
    if v >= 0 and v <= 1.5 then return v * 100 end
    return v
end

local function health_pct(unit)
    local p = as_pct(safe(function() return unit:health_pct() end))
    if p then return p end
    local c = safe(function() return unit:get_health() end)
    local m = safe(function() return unit:get_max_health() end)
    if type(c) == "number" and type(m) == "number" and m > 0 then return (c / m) * 100 end
    return 100
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

local function has_aura(unit, ids)
    if not unit then return false end
    return auras.aura_up(unit, ids)
end

local function cast_self(spell, player, label)
    if not spell or not player then return false end
    local ok = safe(function() return spell:cast_safe(player, label) end)
    if ok ~= true then ok = safe(function() return spell:cast(player, label) end) end
    if ok == true then rotation_note(label) return true end
    return false
end

local function cast_at(spell, target, label)
    if not spell or not target then
        return false
    end

    -- Ask the client whether THIS spell reaches THIS target before trying it.
    -- The raw cast below is ungated, so without this an out-of-range ability
    -- was sent to the server, rejected, and retried on the very next tick -
    -- the rotation would sit on a short-ranged spell and never fall through
    -- to one it could actually land.
    if not range.spell(target, spell) then
        return false
    end

    local ok = safe(function() return spell:cast_safe(target, label) end)
    if ok ~= true then
        ok = safe(function() return spell:cast(target, label) end)
    end
    if ok == true then rotation_note(label) return true end
    return false
end

local debug_printed = false
local function debug_dump(player)
    if debug_printed or not gui.is_on("warrior_debug") then return end
    if not spellbook.ready() then return end
    debug_printed = true
    core.log("[Master Farmer - Grindbot] Warrior spell resolution:")
    for i = 1, #SPELL_LABELS do
        core.log(string.format("    %-20s %s", SPELL_LABELS[i][1],
            (SPELL_LABELS[i][2] and learned(SPELL_LABELS[i][2])) and "OK" or "not learned / unresolved"))
    end
    core.log("    rage readable: " .. tostring(rage(player)))
    core.log("    stance: " .. tostring(stance())
        .. "  (1 Battle, 2 Defensive, 3 Berserker, nil unreadable)")
end

-- ----------------------------------------------------------------------------
-- IDENTITY
-- ----------------------------------------------------------------------------
function warrior.class_id() return enums.class_id.WARRIOR end
function warrior.label() return "Warrior" end
function warrior.combat_range(player) return 5 end

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
-- GUI
-- ----------------------------------------------------------------------------
function warrior.register_gui(menu)
    local class_id = enums.class_id.WARRIOR
    local function opt(label, spell, tip)
        return { label = label, tab = "class", class_id = class_id, spell = spell, tooltip = tip }
    end
    menu:checkbox("mfg_battle_shout", true, opt("Battle Shout", battle_shout))
    menu:checkbox("mfg_battle_stance", true, opt("Keep Battle Stance", battle_stance,
        "Out of combat only. This rotation never changes stance mid-fight."))
    menu:checkbox("mfg_bloodrage", true, opt("Bloodrage", bloodrage,
        "Costs health to make rage; held above the health floor below."))
    menu:checkbox("mfg_victory_rush", true, opt("Victory Rush", victory_rush))
    menu:checkbox("mfg_execute", true, opt("Execute", execute))
    menu:checkbox("mfg_mortal_strike", true, opt("Mortal Strike", mortal_strike))
    menu:checkbox("mfg_bloodthirst", true, opt("Bloodthirst", bloodthirst))
    menu:checkbox("mfg_whirlwind", true, opt("Whirlwind", whirlwind,
        "Berserker Stance only. Offered when already in it; never swaps for it."))
    menu:checkbox("mfg_overpower", false, opt("Overpower", overpower,
        "Only usable after the target dodges, and no API reports a dodge, so it "
        .. "will sometimes be tried and fail. Off by default."))
    menu:checkbox("mfg_rend", true, opt("Rend", rend))
    menu:checkbox("mfg_thunder_clap", true, opt("Thunder Clap", thunder_clap,
        "Battle or Defensive Stance."))
    menu:checkbox("mfg_cleave", true, opt("Cleave", cleave))
    menu:checkbox("mfg_heroic_strike", true, opt("Heroic Strike", heroic_strike,
        "The rage dump. Held behind the rage floor below so it cannot starve "
        .. "the specials."))
    menu:checkbox("mfg_sunder_armor", false, opt("Sunder Armor", sunder_armor,
        "Threat and armour reduction; rarely worth a global while solo."))
    menu:checkbox("mfg_demo_shout", false, opt("Demoralizing Shout", demo_shout))
    menu:checkbox("mfg_hamstring", false, opt("Hamstring", hamstring))
    menu:checkbox("mfg_berserker_rage", true, opt("Berserker Rage", berserker_rage))
    menu:checkbox("mfg_pummel", true, opt("Pummel", pummel,
        "Berserker Stance only."))
    menu:checkbox("mfg_shield_bash", true, opt("Shield Bash", shield_bash,
        "Defensive Stance and a shield."))
    menu:slider_int("mfg_heroic_rage", 20, 90, 40, {
        label = "Heroic Strike above rage", tab = "class", class_id = class_id })
    menu:slider_int("mfg_bloodrage_hp", 30, 95, 60, {
        label = "Bloodrage above health %", tab = "class", class_id = class_id })
    menu:slider_int("mfg_execute_pct", 5, 25, 20, {
        label = "Execute below target %", tab = "class", class_id = class_id })
    menu:checkbox("mfg_warrior_debug", false, {
        label = "Log spell resolution", tab = "class", class_id = class_id,
        tooltip = "Also reports current rage and stance." })
end

-- ----------------------------------------------------------------------------
-- OUT OF COMBAT
-- ----------------------------------------------------------------------------
function warrior.buffs_ooc(player)
    if not player then return false end
    if racials.ooc(player) then
        return true
    end
    debug_dump(player)

    -- Stance out of combat only, and only when it is readable and wrong.
    -- Doing this in combat would cost the rage the fight has already earned.
    if gui.is_on("battle_stance") and learned(battle_stance) then
        local here = stance()
        if here ~= nil and here ~= STANCE_BATTLE then
            if cast_self(battle_stance, player, "Battle Stance") then
                return true
            end
        end
    end

    if gui.is_on("battle_shout") and learned(battle_shout) then
        if not has_aura(player, BATTLE_SHOUT_IDS) then
            if cast_self(battle_shout, player, "Battle Shout") then
                return true
            end
        end
    end

    return false
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

-- Damage priority for the sequencer, highest first - the same order the floor
-- below casts in.
--
-- Left OFF the sequence on purpose:
--   Heroic Strike and Cleave, because they are rage dumps whose whole job is
--   to spend what is left after the specials. Inside a flexible-order
--   sequence they would compete with the specials for the same rage.
--   Bloodrage, Berserker Rage and Battle Shout, because they are cast on the
--   player rather than the target.
--   The stance-locked abilities, because whether they are legal depends on a
--   stance that can change between the sequence being built and reached.
local function start_sequence(player, target, ctx)
    local pack = (ctx and ctx.enemies and #ctx.enemies) or 0
    local exec_at = gui.slider("execute_pct", 20) or 20
    return sequence.start({
        { spell = execute, key = "execute", dist = 5,
          when = function() return health_pct(target) < exec_at end },
        { spell = victory_rush, key = "victory_rush", dist = 5,
          when = function() return has_aura(player, VICTORIOUS_IDS) end },
        { spell = mortal_strike, key = "mortal_strike", dist = 5 },
        { spell = bloodthirst, key = "bloodthirst", dist = 5 },
        { spell = rend, key = "rend", dist = 5,
          when = function() return auras.debuff_expiring(target, REND_IDS, DOT_LEAD) end },
        { spell = thunder_clap, key = "thunder_clap", dist = 8,
          when = function() return pack >= 2 end },
    }, target, "Warrior Rotation")
end

-- ----------------------------------------------------------------------------
-- COMBAT
-- ----------------------------------------------------------------------------
function warrior.tick(player, target, ctx)
    if not player or not target then return false end
    ctx = ctx or {}

    -- Racials first: short cooldowns that only pay off while the fight is
    -- live, and none of them cost a global.
    if racials.tick(player, target, ctx) then
        return true
    end

    local hp = health_pct(player)
    local rg = rage(player)

    -- Rage generators before the melee gate: both are self-cast and both are
    -- worth having up while closing the last few yards.
    if gui.is_on("bloodrage") and learned(bloodrage) then
        local floor_hp = gui.slider("bloodrage_hp", 60) or 60
        if rg < 20 and hp > floor_hp then
            if cast_self(bloodrage, player, "Bloodrage") then return true end
        end
    end
    if gui.is_on("berserker_rage") and learned(berserker_rage) then
        if rg < 20 and safe(function() return player:is_in_combat() end) == true then
            if cast_self(berserker_rage, player, "Berserker Rage") then return true end
        end
    end

    -- Hitbox aware: centre-to-centre distance to a large mob reads well over
    -- five yards while the player is standing inside its hitbox swinging at
    -- it, and the old check refused the whole melee block on that reading.
    if not range.melee(target, 5) then return false end

    -- The sequence first: it handles the interesting ordering. Everything
    -- below is the floor under it, unchanged, and it runs whenever the
    -- sequence does not start - the sequencer being busy or on cooldown,
    -- advanced_sequence missing on the build, or no entry resolving.
    if start_sequence(player, target, ctx) then
        return true
    end

    local exec_at = gui.slider("execute_pct", 20) or 20
    if gui.is_on("execute") and learned(execute) and health_pct(target) < exec_at then
        if cast_at(execute, target, "Execute") then return true end
    end

    if gui.is_on("victory_rush") and learned(victory_rush) then
        if has_aura(player, VICTORIOUS_IDS) then
            if cast_at(victory_rush, target, "Victory Rush") then return true end
        end
    end

    if gui.is_on("mortal_strike") and learned(mortal_strike) then
        if cast_at(mortal_strike, target, "Mortal Strike") then return true end
    end
    if gui.is_on("bloodthirst") and learned(bloodthirst) then
        if cast_at(bloodthirst, target, "Bloodthirst") then return true end
    end

    -- Stance-locked, and offered only from the stance that already allows it.
    -- See the header: this rotation does not dance.
    local here = stance()
    if here == STANCE_BERSERKER and gui.is_on("whirlwind") and learned(whirlwind) then
        if cast_at(whirlwind, target, "Whirlwind") then return true end
    end
    if here == STANCE_BATTLE and gui.is_on("overpower") and learned(overpower) then
        if cast_at(overpower, target, "Overpower") then return true end
    end

    if gui.is_on("rend") and learned(rend) then
        if auras.debuff_expiring(target, REND_IDS, DOT_LEAD) then
            if cast_at(rend, target, "Rend") then return true end
        end
    end

    local pack = (ctx.enemies and #ctx.enemies) or 0
    if pack >= 2 and here ~= STANCE_BERSERKER then
        if gui.is_on("thunder_clap") and learned(thunder_clap) then
            if cast_at(thunder_clap, target, "Thunder Clap") then return true end
        end
    end

    if gui.is_on("demo_shout") and learned(demo_shout) then
        if auras.debuff_expiring(target, DEMO_SHOUT_IDS, DOT_LEAD) then
            if cast_self(demo_shout, player, "Demoralizing Shout") then return true end
        end
    end

    if gui.is_on("sunder_armor") and learned(sunder_armor) then
        if cast_at(sunder_armor, target, "Sunder Armor") then return true end
    end

    if gui.is_on("hamstring") and learned(hamstring) then
        if cast_at(hamstring, target, "Hamstring") then return true end
    end

    -- The rage dump, last. Everything above is a better use of the same rage,
    -- so this only fires with what they did not want, which is why it sits
    -- behind a floor rather than a cooldown.
    local dump_at = gui.slider("heroic_rage", 40) or 40
    if rg >= dump_at then
        if pack >= 2 and gui.is_on("cleave") and learned(cleave) then
            if cast_at(cleave, target, "Cleave") then return true end
        end
        if gui.is_on("heroic_strike") and learned(heroic_strike) then
            if cast_at(heroic_strike, target, "Heroic Strike") then return true end
        end
    end

    return false
end

-- ----------------------------------------------------------------------------
-- COMBAT ENGINE HOOKS
-- ----------------------------------------------------------------------------
--- Interrupt any caster in the pack, not only the current target.
---
--- Both warrior interrupts are stance-locked and this does not dance, so it
--- offers whichever one the current stance already allows and otherwise
--- declines. Shield Bash additionally needs a shield, which is not checked
--- here - the cast simply fails, at the cost of one tick, and no call in the
--- reflected reference reports the off-hand type.
---
--- Range is checked through spell_range so a big mob's hitbox counts, and the
--- cast itself goes through cast_at, which refuses an out-of-range spell.
function warrior.interrupt(player, unit)
    if not player or not unit then
        return false
    end
    local here = stance()
    if here == STANCE_BERSERKER then
        if gui.is_on("pummel") ~= true or not learned(pummel) then
            return false
        end
        if not range.spell(unit, pummel, 5) then
            return false
        end
        return cast_at(pummel, unit, "Pummel")
    end
    if here == STANCE_DEFENSIVE then
        if gui.is_on("shield_bash") ~= true or not learned(shield_bash) then
            return false
        end
        if not range.spell(unit, shield_bash, 5) then
            return false
        end
        return cast_at(shield_bash, unit, "Shield Bash")
    end
    return false
end

--- Pull something off whatever it is chewing on.
---
--- Taunt is Defensive Stance only. Same rule as the interrupts: offered from
--- the stance that already allows it, never swapped into.
function warrior.taunt(player, unit)
    if not player or not unit then
        return false
    end
    if stance() ~= STANCE_DEFENSIVE then
        return false
    end
    if not learned(taunt) then
        return false
    end
    if not range.spell(unit, taunt, 30) then
        return false
    end
    return cast_at(taunt, unit, "Taunt")
end

return warrior
