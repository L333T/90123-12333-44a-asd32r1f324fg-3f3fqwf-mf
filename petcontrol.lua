-- ============================================================================
-- restedXP_questing
-- petcontrol.lua - pet abilities in a fight (Mage, Warlock, Hunter)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.6.0
-- Folder: restedXP_questing
-- ============================================================================
-- 4.6.0 (user: "correctly control pets for player classes who have pets -
-- Mage Water Elemental, Warlock, Hunter - and use their spells and abilities
-- on enemy targets"). pets.lua already summons / revives / heals the pet and
-- sends it in (pets.attack: pet_handler ASSIST + core.input.pet_attack); this
-- file makes the pet USE ITS OWN ABILITIES.
--
-- API (.api core.lua): core.spell_book.get_pet_spells() / get_pet_action_info
-- (name, auto_cast_allowed, auto_cast_enabled, in_range), core.input.
-- pet_cast_target_spell / pet_cast_position_spell, enable_ / disable_pet_autocast.
--
-- WHICH ABILITIES THE PET HAS: read from the pet's own spell book, by NAME
-- (every rank is one name): get_pet_spells() ids -> get_pet_action_info(id).name,
-- re-read for each new pet and every LEARN_S s. A few ids are known and tried
-- when the book reads empty (Waterbolt 31707, Freeze 33395, Phase Shift 4511,
-- Seduction 6358, Spell Lock 19244 / 19647).
--
-- AUTOCAST (once per pet, re-checked every AUTO_S s): damage and taunts ON
-- (Waterbolt, Firebolt, Lash of Pain, Torment, Anguish, Cleave, Growl, Claw,
-- Bite, ...), the ones that stop a pet fighting OFF (Phase Shift, Cower,
-- Prowl, Soothing Kiss, Lesser Invisibility) and the ones this file casts by
-- hand OFF (Seduction, Spell Lock, Suffering, Sacrifice, Dash, Dive, Freeze).
--
-- BY HAND (RULES, each with its own gap - a pet spell's cooldown is not in
-- core.spell_book; the game refuses one that is not ready):
--   Freeze        an enemy within FREEZE_NEAR yd of the player (else the target), at its feet
--   Waterbolt     the target, whenever the elemental stands idle (Zygor 1.7 hook)
--   Torment / Anguish / Growl   a mob hitting the PLAYER (the pet takes it back)
--   Suffering     2+ mobs on the player
--   Spell Lock    a caster (target or pack) mid-cast
--   Seduction     a second mob on the player (not the target), not near a sheep
--   Intercept     the target 8-25 yd from the Felguard
--   Dash / Dive   the target 20+ yd from the pet
--   Sacrifice     Voidwalker under 15 % with the player under 40 %
-- Never on a polymorphed (sheeped) mob. Pet commands are not the player's GCD:
-- the tick is never taken.
-- Public: PC.tick(player, target, enemies), PC.ooc(player), PC._reset().
-- ============================================================================

local pets = require("pets")
local auras = require("auras")

local PC = {}

PC.LEARN_S = 30
PC.AUTO_S = 5
PC.FREEZE_NEAR = 10

local AUTO_ON = {
    ["Waterbolt"] = true, ["Firebolt"] = true, ["Lash of Pain"] = true, ["Torment"] = true,
    ["Anguish"] = true, ["Cleave"] = true, ["Growl"] = true, ["Claw"] = true, ["Bite"] = true,
    ["Gore"] = true, ["Screech"] = true, ["Lightning Breath"] = true, ["Scorpid Poison"] = true,
    ["Fire Breath"] = true, ["Thunderstomp"] = true, ["Furious Howl"] = true, ["Charge"] = true,
    ["Poison Spit"] = true, ["Warp"] = true, ["Fire Shield"] = true, ["Devour Magic"] = true,
}
local AUTO_OFF = {
    ["Phase Shift"] = true, ["Cower"] = true, ["Prowl"] = true, ["Soothing Kiss"] = true,
    ["Lesser Invisibility"] = true, ["Seduction"] = true, ["Spell Lock"] = true, ["Suffering"] = true,
    ["Sacrifice"] = true, ["Dash"] = true, ["Dive"] = true, ["Freeze"] = true, ["Intercept"] = true,
}
local KNOWN_IDS = { 31707, 33395, 4511, 6358, 19244, 19647 }
local POLY_IDS = { 118, 12824, 12825, 12826, 28271, 28272 }

local st = { pet = nil, learn_t = -1e9, auto_t = -1e9, book = {}, last = {} }

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    local t = ok and type(izi) == "table" and safe(function() return izi.now() end) or nil
    return type(t) == "number" and t or 0
end

local function trail(fmt, ...)
    local el = package.loaded["errorlog"]
    if type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "pet", fmt, ...) end
end

-- only game_object methods in the .api stubs (is_dead / is_ghost, positions,
-- get_health / get_max_health; auras.debuff_up for the sheep)
local function alive(u)
    return u ~= nil and safe(function() return u:is_valid() end) == true
        and safe(function() return u:is_dead() end) ~= true
        and safe(function() return u:is_ghost() end) ~= true
end

local function guid(u) return u and safe(function() return u:get_guid() end) or nil end

local function dist(a, b)
    local pa, pb = safe(function() return a:get_position() end), safe(function() return b:get_position() end)
    if not pa or not pb then return nil end
    return math.sqrt((pa.x - pb.x) ^ 2 + (pa.y - pb.y) ^ 2 + ((pa.z or 0) - (pb.z or 0)) ^ 2)
end

local function sheeped(u)
    return safe(function() return auras.debuff_up(u, POLY_IDS) end) == true
end

local function casting(u)
    return safe(function() return u:is_casting_spell() == true or u:is_channelling_spell() == true end) == true
end

local function info_of(id)
    local i = safe(function() return core.spell_book.get_pet_action_info(id) end)
    return type(i) == "table" and i or nil
end

--- The pet's spell book: name -> spell id (one per name, the last seen rank).
local function learn(t)
    local book = {}
    local ids = {}
    local list = safe(function() return core.spell_book.get_pet_spells() end)
    if type(list) == "table" then
        for i = 1, #list do
            local e = list[i]
            local id = type(e) == "number" and e
                or (type(e) == "table" and (tonumber(e.spell_id) or tonumber(e.id))) or nil
            if id then ids[#ids + 1] = id end
        end
    end
    if #ids == 0 then ids = KNOWN_IDS end
    for i = 1, #ids do
        local info = info_of(ids[i])
        local name = info and type(info.name) == "string" and info.name ~= "" and info.name or nil
        if name and info.is_token ~= true then book[name] = ids[i] end
    end
    st.book, st.learn_t = book, t
    local names = {}
    for n in pairs(book) do names[#names + 1] = n end
    table.sort(names)
    trail("pet abilities: %s", #names > 0 and table.concat(names, ", ") or "none read")
end

--- Autocast on / off by the tables above (only where the game allows it).
local function autocast()
    for name, id in pairs(st.book) do
        local want = nil                     -- (not "x and false or nil": that is always nil)
        if AUTO_ON[name] then want = true elseif AUTO_OFF[name] then want = false end
        if want ~= nil then
            local info = info_of(id)
            if info and info.auto_cast_allowed ~= false and info.auto_cast_enabled ~= want then
                if want then
                    pcall(core.input.enable_pet_autocast, id)
                else
                    pcall(core.input.disable_pet_autocast, id)
                end
                trail("autocast %s %s", name, want and "on" or "off")
            end
        end
    end
end

--- Cast pet ability `name` at `unit` (or at a position) at most every `gap` s.
local function cast(name, gap, unit, at_pos, t, why)
    local id = st.book[name]
    if not id or not unit then return false end
    if (t - (st.last[name] or -1e9)) < gap then return false end
    st.last[name] = t
    if at_pos then
        local p = safe(function() return unit:get_position() end)
        if not p then return false end
        pcall(core.input.pet_cast_position_spell, id, p)
    else
        pcall(core.input.pet_cast_target_spell, id, unit)
    end
    trail("%s on %s%s", name, tostring(safe(function() return unit:get_name() end)), why and (" - " .. why) or "")
    return true
end

--- Who is attacking the player: live, not sheeped, targeting the player.
local function on_player(player, enemies)
    local me = guid(player)
    local out = {}
    for i = 1, #(enemies or {}) do
        local u = enemies[i]
        if alive(u) and not sheeped(u) then
            local tt = safe(function() return u:get_target() end)
            if tt and me and guid(tt) == me then out[#out + 1] = u end
        end
    end
    return out
end

--- One combat tick of pet abilities. Never takes the tick (returns nothing).
function PC.tick(player, target, enemies)
    local pet = pets.get(player)
    if not pet or not pets.alive(player) then st.pet = nil return end
    local t = now()
    local pg = guid(pet)
    if pg ~= st.pet then
        st.pet, st.learn_t, st.auto_t, st.last = pg, -1e9, -1e9, {}
    end
    if (t - st.learn_t) >= PC.LEARN_S then learn(t) end
    if (t - st.auto_t) >= PC.AUTO_S then st.auto_t = t autocast() end
    if not alive(target) or sheeped(target) then return end
    local b = st.book
    local hitting = on_player(player, enemies)

    -- Water Elemental
    if b["Freeze"] then
        local near, nd = nil, nil
        for i = 1, #(enemies or {}) do
            local u = enemies[i]
            if alive(u) and not sheeped(u) then
                local d = dist(player, u)
                if d and d <= PC.FREEZE_NEAR and (not nd or d < nd) then near, nd = u, d end
            end
        end
        cast("Freeze", 25, near or target, true, t, near and string.format("%.0f yd from the player", nd) or "the target")
    end
    if b["Waterbolt"] and not casting(pet) then cast("Waterbolt", 1.0, target, false, t) end

    -- taunts: a mob on the player goes back to the pet
    local taunt = hitting[1]
    if taunt then
        cast("Torment", 5, taunt, false, t, "it hits the player")
        cast("Anguish", 5, taunt, false, t, "it hits the player")
        cast("Growl", 5, taunt, false, t, "it hits the player")
    end
    if #hitting >= 2 then cast("Suffering", 120, pet, false, t, #hitting .. " on the player") end

    -- interrupts
    if b["Spell Lock"] then
        local caster = casting(target) and target or nil
        for i = 1, #(enemies or {}) do
            if not caster and alive(enemies[i]) and casting(enemies[i]) then caster = enemies[i] end
        end
        if caster then cast("Spell Lock", 24, caster, false, t, "casting") end
    end

    -- crowd control: a second mob on the player
    if b["Seduction"] then
        local tg = guid(target)
        for i = 1, #hitting do
            if guid(hitting[i]) ~= tg then
                cast("Seduction", 15, hitting[i], false, t, "an add on the player")
                break
            end
        end
    end

    -- gap closers
    local pd = dist(pet, target)
    if pd and pd >= 8 and pd <= 25 then cast("Intercept", 30, target, false, t, string.format("%.0f yd", pd)) end
    if pd and pd >= 20 then
        cast("Dash", 30, pet, false, t, string.format("target %.0f yd", pd))
        cast("Dive", 30, pet, false, t, string.format("target %.0f yd", pd))
    end

    -- Voidwalker last stand
    if b["Sacrifice"] then
        local php = pets.health_pct(player)
        local cur = safe(function() return player:get_health() end)
        local mx = safe(function() return player:get_max_health() end)
        local hp = (type(cur) == "number" and type(mx) == "number" and mx > 0) and (cur * 100 / mx) or nil
        if type(php) == "number" and php < 15 and type(hp) == "number" and hp < 40 then
            cast("Sacrifice", 300, pet, false, t, string.format("pet %.0f%%, player %.0f%%", php, hp))
        end
    end
end

--- Out of combat: the pet's autocasts kept right (a fresh summon comes with
--- the game's defaults - Phase Shift on, Cower on).
function PC.ooc(player)
    local pet = pets.get(player)
    if not pet or not pets.alive(player) then st.pet = nil return end
    local t = now()
    local pg = guid(pet)
    if pg ~= st.pet then st.pet, st.learn_t, st.auto_t, st.last = pg, -1e9, -1e9, {} end
    if (t - st.learn_t) >= PC.LEARN_S then learn(t) end
    if (t - st.auto_t) >= PC.AUTO_S then st.auto_t = t autocast() end
end

--- Test hooks.
function PC._state() return st end
function PC._reset() st.pet, st.learn_t, st.auto_t, st.book, st.last = nil, -1e9, -1e9, {}, {} end

return PC
