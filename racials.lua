-- ============================================================================
-- Master Farmer - Grindbot
-- Racial abilities - one implementation, driven by every rotation
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.216.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Racials are per RACE, not per class, so they cannot live in the nine class
-- files without being written nine times for every race. The class rotations
-- call racials.tick(player, target, ctx) from their combat tick and
-- racials.ooc(player) out of combat; this file decides what is worth casting.
--
-- WHEN EACH KIND FIRES
--   offensive  once the fight is properly under way, not on the pull. Firing
--              Blood Fury at a mob that dies in two globals wastes a two
--              minute cooldown, so it waits until the target has enough health
--              left to be worth it.
--   mana       when mana is low, in combat. Out of combat the bot drinks.
--   heal       when health is low, in combat. Out of combat the bot eats.
--   free_cc    when the matching control is actually on us. is_rooted,
--              is_feared and is_stunned come from the SDK and report the real
--              state, so this is never a guess.
--   aoe_stun   only when more than one thing is in melee range - a single
--              target does not justify the cooldown.
--
-- EVERY RACIAL IS OPTIONAL. Each one gets a checkbox on the Class tab, all on
-- by default, and the whole file no-ops for a race that has none.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local data = require("data/racials")
local spellbook = require("spellbook")
local state = require("state")

local racials = {}

local ACT_GAP = 1.0          -- seconds between racial casts
local OFFENSIVE_MIN_HP = 40  -- target must still have this much health left
local MANA_PCT = 30
local HEAL_PCT = 50

local last_act = -1e9
local resolved = nil         -- race_id -> { {def, spell}, ... }
local resolved_race = nil
-- 2.194.0: the Spells tab's "Other known spells" (smart.lua), used like an
-- offensive racial when ticked.
local extra_defs = {}

--- The other known spells smart.lua listed; replaces the previous list.
function racials.set_extra(list)
    extra_defs = type(list) == "table" and list or {}
    resolved, resolved_race = nil, nil
end

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local function as_pct(v)
    if type(v) ~= "number" then
        return nil
    end
    if v >= 0 and v <= 1.5 then
        return v * 100
    end
    return v
end

local function health_pct(unit)
    local p = as_pct(safe(function() return unit:health_pct() end))
    if p then
        return p
    end
    p = as_pct(safe(function() return unit:get_health_percentage() end))
    if p then
        return p
    end
    local cur = safe(function() return unit:get_health() end)
    local mx = safe(function() return unit:get_max_health() end)
    if type(cur) == "number" and type(mx) == "number" and mx > 0 then
        return (cur / mx) * 100
    end
    return 100
end

local power = require("power")

local function mana_pct(unit)
    -- power.lua (2.202.0): izi mana_* first, native get_power / get_max_power (mana 0) when
    -- they read nothing - on WoW Forever a Mage read as having no mana and never drank.
    return power.mana_pct(unit)
end

-- ----------------------------------------------------------------------------
-- RESOLUTION
-- ----------------------------------------------------------------------------
--- Build this race's spell objects once. Rebuilt if the race ever reads
--- differently, which happens when the player object is not ready on the first
--- tick and reports nil.
local function for_player(player)
    local race = safe(function() return player:get_race_id() end)
    if type(race) ~= "number" then
        return nil
    end
    if resolved and resolved_race == race then
        return resolved
    end
    local out = {}
    local defs = {}
    local base = data.for_race(race)
    for i = 1, #base do defs[#defs + 1] = base[i] end
    for i = 1, #extra_defs do defs[#defs + 1] = extra_defs[i] end
    for i = 1, #defs do
        local def = defs[i]
        local spell = safe(function() return izi.spell(def.ids) end)
        if spell then
            if spellbook and type(spellbook.watch) == "function" then
                spell = spellbook.watch(spell) or spell
            end
            out[#out + 1] = { def = def, spell = spell }
        end
    end
    resolved, resolved_race = out, race
    return resolved
end

--- Ticked in the Spells tab (2.64.0)? Racials are listed there by name with
--- the rest of the character's spells; untouched means on.
local function wanted(def)
    local ok, picks = pcall(require, "picks")
    if ok and type(picks) == "table" and type(picks.wants) == "function" then
        return picks.wants(def.label, def.default ~= false)
    end
    return def.default ~= false
end

local function learned(spell)
    if not spell then
        return false
    end
    if spellbook and type(spellbook.ready) == "function" and spellbook.ready() ~= true then
        return false
    end
    if spellbook and type(spellbook.spell_known) == "function" then
        return spellbook.spell_known(spell) == true
    end
    return true
end

local function ready(spell)
    local up = safe(function() return spell:cooldown_up() end)
    return up ~= false
end

local function cast(spell, unit, label)
    local ok = safe(function() return spell:cast_safe(unit, label) end)
    if ok ~= true then
        ok = safe(function() return spell:cast(unit, label) end)
    end
    if ok == true then
        last_act = izi.now()
        state.set_note("Racial", label)
        return true
    end
    return false
end

-- ----------------------------------------------------------------------------
-- WHETHER EACH KIND WANTS TO FIRE
-- ----------------------------------------------------------------------------
-- ONCE PER FIGHT (2.195.0). A "fight_start" racial goes out when a fight
-- begins - at the pull, before the first damage spell - and not again until
-- that fight is over: the player was in combat after the cast and has then
-- been out of it FIGHT_GAP seconds. A pull that never became a fight frees it
-- after FIGHT_STALE seconds out of combat.
local FIGHT_GAP = 2.0
local FIGHT_STALE = 30.0
local fight = { used = false, used_at = -1e9, seen_combat = false, ooc_since = nil }

local function note_fight(player)
    local now = izi.now()
    local in_combat = safe(function() return player:is_in_combat() end) == true
    if in_combat then
        fight.ooc_since = nil
        if fight.used then fight.seen_combat = true end
        return
    end
    fight.ooc_since = fight.ooc_since or now
    if fight.used and (now - fight.ooc_since) >= FIGHT_GAP
        and (fight.seen_combat or (now - fight.used_at) >= FIGHT_STALE) then
        fight.used, fight.seen_combat = false, false
    end
end

local function cc_on_us(player, which)
    if which == "root" then
        return safe(function() return player:is_rooted() end) == true
    end
    if which == "fear" then
        if safe(function() return player:is_feared() end) == true then
            return true
        end
        return safe(function() return player:is_stunned() end) == true
    end
    if which == "bleed" then
        -- No "am I bleeding" call exists, and guessing from debuff ids would
        -- need a table of every bleed, poison and disease in the game. Health
        -- falling while out of a fight is the honest proxy, and Stoneform's
        -- armour is worth having in a bad fight regardless.
        return health_pct(player) <= HEAL_PCT
    end
    return false
end

local function wants(entry, player, target, ctx)
    local def = entry.def
    local kind = def.kind

    if kind == "offensive" then
        if not target then
            return false
        end
        return health_pct(target) >= OFFENSIVE_MIN_HP
    end

    if kind == "fight_start" then
        if not target or fight.used then
            return false
        end
        return safe(function() return target:is_dead() end) ~= true
    end

    if kind == "mana" then
        return mana_pct(player) <= MANA_PCT
    end

    if kind == "mana_tap" then
        -- Mana Tap only charges Arcane Torrent; it is pointless without a
        -- target and wasteful at full mana.
        if not target then
            return false
        end
        return mana_pct(player) <= (MANA_PCT + 20)
    end

    if kind == "heal" then
        return health_pct(player) <= HEAL_PCT
    end

    if kind == "free_cc" then
        return cc_on_us(player, def.cc)
    end

    if kind == "aoe_stun" then
        local melee = ctx and ctx.melee_count
        if type(melee) ~= "number" then
            melee = 0
            local list = ctx and ctx.enemies
            if type(list) == "table" then
                for i = 1, #list do
                    local d = safe(function() return player:distance_to(list[i]) end)
                    if type(d) == "number" and d <= 8 then
                        melee = melee + 1
                    end
                end
            end
        end
        return melee >= 2
    end

    return false
end

local function target_for(entry, player, target)
    local kind = entry.def.kind
    if kind == "mana_tap" then
        return target
    end
    return player
end

-- ----------------------------------------------------------------------------
-- PUBLIC
-- ----------------------------------------------------------------------------
--- Combat racials. Returns true when one was cast, so the rotation can hold
--- the rest of its cascade for a tick.
function racials.tick(player, target, ctx)
    if not player then
        return false
    end
    note_fight(player)
    local now = izi.now()
    if (now - last_act) < ACT_GAP then
        return false
    end
    local list = for_player(player)
    if not list or #list == 0 then
        return false
    end
    for i = 1, #list do
        local entry = list[i]
        local def = entry.def
        if wanted(def) and learned(entry.spell) and ready(entry.spell) then
            if wants(entry, player, target, ctx) then
                local unit = target_for(entry, player, target)
                -- An uncatalogued spell (2.194.0): whether it takes the enemy
                -- or the player is not known - the enemy first, then self.
                if def.extra and target and cast(entry.spell, target, def.label) then
                    return true
                end
                if unit and cast(entry.spell, unit, def.label) then
                    if def.kind == "fight_start" then
                        fight.used, fight.used_at, fight.seen_combat = true, izi.now(), false
                    end
                    return true
                end
            end
        end
    end
    return false
end

--- Out of combat, only the escapes are worth anything: a root or a snare stops
--- the bot walking, and nothing else will clear it.
function racials.ooc(player)
    if not player then
        return false
    end
    note_fight(player)
    local now = izi.now()
    if (now - last_act) < ACT_GAP then
        return false
    end
    local list = for_player(player)
    if not list or #list == 0 then
        return false
    end
    for i = 1, #list do
        local entry = list[i]
        local def = entry.def
        if def.kind == "free_cc" and def.cc ~= "bleed"
            and wanted(def) and learned(entry.spell) and ready(entry.spell) then
            if cc_on_us(player, def.cc) then
                if cast(entry.spell, player, def.label) then
                    return true
                end
            end
        end
    end
    return false
end

--- Forget the resolved race, so a reload or a character swap re-reads it.
function racials.reset()
    resolved, resolved_race = nil, nil
end

return racials
