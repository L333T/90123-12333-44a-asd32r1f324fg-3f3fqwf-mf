-- ============================================================================
-- Master Farmer - Grindbot
-- Enemy scan, tap filter, player detect, corpse list
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.154.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type auto_attack_helper
local auto_attack = require("common/utility/auto_attack_helper")

---@type enums
local enums = require("common/enums")

local gui = require("gui")
local state = require("state")

local targeting = {}

-- One bot tick, not five (2.32.0): every finder walks this list calling
-- methods on its handles, and a handle half a second old can belong to an
-- object the game has since freed.
local OBJ_CACHE_GAP = 0.10
local obj_cache_t = -1
local obj_cache_list = nil

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

--- safe(), without the closure: the same "first result, or nil on error", but
--- using pcall's own argument passing.
---
---     safe(function() return u:is_valid() end)   ->   call(u.is_valid, u)
---
--- Identical behaviour, no allocation. The closure form builds a new closure
--- capturing `u` on every call, and these are called inside loops over every
--- visible object - five to seven per object, per scan, several scans a frame
--- in combat. find_corpses below has always used this form for its predicate;
--- this just makes the rest of the file agree with it.
---
--- ONE DIFFERENCE, AND IT MATTERS: the index `u.is_valid` happens OUTSIDE the
--- pcall, so a nil receiver throws here where the closure form would have
--- swallowed it. Every call site keeps its `if u and ...` guard for exactly
--- that reason - do not remove one thinking call() covers it. A receiver that
--- exists but lacks the method is still fine: pcall catches calling a nil.
--- Is this value something call() may index?
---
--- call() does the index OUTSIDE the pcall, so a receiver that is not a table
--- or userdata throws before pcall can catch it. The closure form tolerated
--- any junk in a list - a boolean, a number, a leftover - and this keeps that
--- tolerance rather than narrowing it to "not nil".
local function indexable(v)
    local t = type(v)
    return t == "table" or t == "userdata"
end

local function call(fn, a, b)
    local ok, result = pcall(fn, a, b)
    if ok then
        return result
    end
    return nil
end

-- ============================================================================
-- RANGE CEILING (2.25.0)
-- ============================================================================
-- No search anywhere in the plugin looks further than MAX_RANGE yards. Every
-- range argument that reaches a finder in this module is clamped to it, and
-- quest/guide and movement read the same constant.
local MAX_RANGE = 300
targeting.MAX_RANGE = MAX_RANGE
-- How far every mode looks for an enemy to fight (2.94.0): one number for all
-- classes. The nearest valid one is attacked, closing to the GUI melee /
-- ranged attack distance first (rotation.combat_range).
targeting.ENEMY_SCAN = 100

--- A range argument clamped to MAX_RANGE. nil stays nil so each caller's own
--- default still applies.
local function cap(r)
    r = tonumber(r)
    if r == nil then
        return nil
    end
    if r > MAX_RANGE then
        return MAX_RANGE
    end
    return r
end
targeting.cap_range = cap

local function all_objects()
    local now = izi.now()
    if obj_cache_list and (now - obj_cache_t) < OBJ_CACHE_GAP then
        return obj_cache_list
    end
    local objects = core.object_manager.get_visible_objects()
    if type(objects) == "table" then
        obj_cache_list = objects
        obj_cache_t = now
        return objects
    end
    return nil
end

--- The visible-object list, from the shared cache. Every scan in the plugin
--- should come through here: each call to get_visible_objects builds a new
--- table of every object in range, and quest/guide used to make four of them
--- a tick on top of this module's own.
function targeting.visible_objects()
    return all_objects()
end

function targeting.cache_player(player)
    if not player then
        return nil
    end
    local pos = safe(function() return player:get_position() end)
    state.cached_pos = pos
    state.cached_now = izi.now()
    return pos
end

local function tap_denied(unit)
    if not indexable(unit) then
        return false
    end
    local v = call(unit.is_tap_denied, unit)
    if v == true then
        return true
    end
    if type(v) == "number" and v ~= 0 then
        return true
    end
    return false
end

-- ----------------------------------------------------------------------------
-- CAN THE PLAYER SEE IT? (2.81.0)
-- ----------------------------------------------------------------------------
-- New targets only: a mob behind a wall, down a mine shaft under the player,
-- or on a ledge overhead was picked, walked at and cast at ("Target not in
-- line of sight") while a visible one stood nearby.
--   * Another level: more than VERT_MAX yards above or below AND close in
--     plan (horizontal < VERT_RATIO x the height gap) - a tunnel under the
--     player, not a hillside a long way off.
--   * No line of sight at eye height - the same check the casts use
--     (movement.has_los).
-- Answers are cached SEE_TTL per unit, so a scan over a camp costs one set
-- of native calls per mob per second.
local SEE_TTL = 1.0
local VERT_MAX = 12
local VERT_RATIO = 3
local see_cache, see_n = {}, 0

function targeting.can_see(player, unit)
    if not player or not indexable(unit) then
        return false
    end
    local g = call(unit.get_guid, unit)
    local now = izi.now()
    local e = g and see_cache[g]
    if e and (now - e.t) < SEE_TTL then
        return e.v
    end
    local v = true
    local pp = call(player.get_position, player)
    local up = call(unit.get_position, unit)
    if pp and up and type(pp.z) == "number" and type(up.z) == "number" then
        local dz = math.abs(up.z - pp.z)
        local dx, dy = up.x - pp.x, up.y - pp.y
        local flat = math.sqrt(dx * dx + dy * dy)
        if dz > VERT_MAX and flat < dz * VERT_RATIO then
            v = false
        end
    end
    if v then
        local ok_m, movement = pcall(require, "movement")
        if ok_m and type(movement) == "table" and type(movement.has_los) == "function" then
            v = movement.has_los(player, unit) == true
        end
    end
    if g then
        if see_n > 300 then
            see_cache, see_n = {}, 0
        end
        if not see_cache[g] then
            see_n = see_n + 1
        end
        see_cache[g] = { t = now, v = v }
    end
    return v
end

-- ----------------------------------------------------------------------------
-- 360-DEGREE ENEMY SCAN (2.95.0)
-- ----------------------------------------------------------------------------
-- Every visible object, not the SDK's "enemy" list (which leaves out neutral
-- mobs): each living, attackable unit within ENEMY_SCAN yards of the player's
-- x, y, z - all the way round, 3D distance - sorted into
--   attack  up to LEVEL_CAP above the player: candidates for a fight
--   avoid   hostile and more than LEVEL_CAP above: never targeted, and their
--           positions go to movement's danger map so paths keep clear
-- Cached SCAN_TTL.
local LEVEL_CAP = 5
local SCAN_TTL = 0.25
local DANGER_RADIUS = 12
local scan = { t = -1, attack = {}, avoid = {} }

function targeting.scan_enemies(player)
    local now = izi.now()
    if (now - scan.t) < SCAN_TTL then
        return scan.attack, scan.avoid
    end
    scan.t = now
    local attack, avoid = {}, {}
    if not player then
        scan.attack, scan.avoid = attack, avoid
        return attack, avoid
    end
    local pos = call(player.get_position, player)
    local my_lvl = call(player.get_level, player) or 1
    local list = targeting.visible_objects()
    local range = targeting.ENEMY_SCAN
    local danger = {}
    if pos and type(list) == "table" then
        for i = 1, #list do
            local u = list[i]
            if indexable(u) and call(u.is_valid, u) == true and call(u.is_unit, u) == true
                and call(u.is_dead_or_ghost, u) ~= true and call(u.is_player, u) ~= true
                and call(player.can_attack, player, u) == true then
                local up = call(u.get_position, u)
                if up then
                    local dx, dy, dz = up.x - pos.x, up.y - pos.y, up.z - pos.z
                    if dx * dx + dy * dy + dz * dz <= range * range then
                        local lvl = call(u.get_level, u) or 1
                        if lvl > my_lvl + LEVEL_CAP then
                            if call(u.is_enemy_with, u, player) == true then
                                avoid[#avoid + 1] = u
                                danger[#danger + 1] = { x = up.x, y = up.y, z = up.z, r = DANGER_RADIUS }
                            end
                        else
                            attack[#attack + 1] = u
                        end
                    end
                end
            end
        end
    end
    scan.attack, scan.avoid = attack, avoid
    local ok_m, movement = pcall(require, "movement")
    if ok_m and type(movement) == "table" and type(movement.set_danger) == "function" then
        pcall(movement.set_danger, danger)
    end
    return attack, avoid
end

-- ----------------------------------------------------------------------------
-- ATTACKERS (2.102.0)
-- ----------------------------------------------------------------------------
-- How many living units are fighting the player right now: in combat and
-- targeting the player or the pet, from the 360-degree scan (both lists, so
-- neutral and too-high mobs count too). Looting and resting wait for zero.
-- The player's own combat flag is not the test: it drops for a moment while
-- a fled or evading mob is still coming back.
local ATTACK_TTL = 0.2
local attackers_cache = { t = -1, n = 0 }

function targeting.attackers(player)
    local now = izi.now()
    if (now - attackers_cache.t) < ATTACK_TTL then
        return attackers_cache.n
    end
    attackers_cache.t = now
    local n = 0
    if player then
        local me_guid = call(player.get_guid, player)
        local pet = call(player.get_pet, player)
        local pet_guid = (indexable(pet) and call(pet.is_valid, pet) == true) and call(pet.get_guid, pet) or nil
        local attack, avoid = targeting.scan_enemies(player)
        for _, list in ipairs({ attack, avoid }) do
            for i = 1, #list do
                local u = list[i]
                if indexable(u) and call(u.is_valid, u) == true and call(u.is_dead_or_ghost, u) ~= true
                    and call(u.is_in_combat, u) == true then
                    local tar = call(u.get_target, u)
                    local tg = indexable(tar) and call(tar.get_guid, tar) or nil
                    if tg ~= nil and (tg == me_guid or (pet_guid ~= nil and tg == pet_guid)) then
                        n = n + 1
                    end
                end
            end
        end
    end
    attackers_cache.n = n
    return n
end

--- Too high to fight: more than LEVEL_CAP levels above the player.
function targeting.too_high(player, unit)
    local my_lvl = call(player.get_level, player)
    local lvl = call(unit.get_level, unit)
    return type(my_lvl) == "number" and type(lvl) == "number" and lvl > my_lvl + LEVEL_CAP
end

local function id_wanted(npc_id, mobs)
    if type(mobs) ~= "table" or #mobs == 0 then
        return true
    end
    for i = 1, #mobs do
        if mobs[i] == npc_id then
            return true
        end
    end
    return false
end

local function enemy_units(player, pos, range)
    range = cap(range)
    if pos then
        local around = safe(function()
            return unit_helper:get_enemy_list_around(pos, range, true, false, false, false)
        end)
        if type(around) == "table" and #around > 0 then
            return around
        end
    end
    local list = safe(function()
        return izi.enemies(range)
    end)
    if type(list) == "table" then
        return list
    end
    return {}
end

function targeting.find_mobs(player, mobs, range, pve_only, opts)
    range = cap(range)
    local found = {}
    if not player then
        return found
    end
    opts = opts or {}
    range = tonumber(range) or targeting.ENEMY_SCAN
    if range > targeting.ENEMY_SCAN then
        range = targeting.ENEMY_SCAN
    end
    local pos = state.cached_pos or safe(function() return player:get_position() end)
    if not pos then
        return found
    end
    -- The 360-degree scan's attack list (2.95.0), trimmed to `range`.
    local list = {}
    local all = targeting.scan_enemies(player)
    for i = 1, #all do
        local u = all[i]
        local d = call(player.distance_to, player, u)
        if type(d) == "number" and d <= range then
            list[#list + 1] = u
        end
    end
    local ok_mv, movement = pcall(require, "movement")
    if not ok_mv then
        movement = nil
    end
    local skip_reach = opts.skip_reach == true
    local my_level = safe(function() return player:get_level() end) or 1
    local band = gui.attack_level_band()
    local untapped = gui.is_on("untapped")
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true then
            local skip = false
            if call(u.is_dead_or_ghost, u) == true then
                skip = true
            elseif call(u.is_dead, u) == true then
                skip = true
            end
            if (not skip) and pve_only == true then
                if call(u.is_player, u) == true then
                    skip = true
                end
                if (not skip) and call(u.is_dummy, u) == true then
                    skip = true
                end
            end
            if not skip then
                local guid = call(u.get_guid, u)
                if (not state.was_killed(guid)) and not (state.is_unreachable and state.is_unreachable(guid)) then
                    local npc_id = call(u.get_npc_id, u) or 0
                    local lvl = call(u.get_level, u) or 1
                    local diff = lvl - my_level
                    local level_ok = true
                    if type(band) == "number" then
                        level_ok = diff >= -band and diff <= band
                    end
                    -- Never more than 5 above (2.95.0), whatever the band says.
                    if diff > LEVEL_CAP then
                        level_ok = false
                    end
                    if id_wanted(npc_id, mobs) and level_ok then
                        if (not untapped) or (not tap_denied(u)) then
                            if call(player.can_attack, player, u) ~= false then
                                local upos = call(u.get_position, u)
                                local reach_ok = upos ~= nil
                                if (not skip_reach) and reach_ok and movement and type(movement.can_reach) == "function" then
                                    reach_ok = movement.can_reach(pos, upos) == true
                                end
                                -- Visible from here (2.81.0).
                                if reach_ok and opts.skip_los ~= true then
                                    reach_ok = targeting.can_see(player, u)
                                end
                                if reach_ok then
                                    found[#found + 1] = u
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return found
end

--- The closest fightable enemy within `range` (default ENEMY_SCAN) of the
--- player's current position, or nil. Same filters as find_mobs.
function targeting.nearest_enemy(player, range)
    range = cap(range) or targeting.ENEMY_SCAN
    if range > targeting.ENEMY_SCAN then
        range = targeting.ENEMY_SCAN
    end
    return targeting.nearest(player, targeting.find_mobs(player, nil, range, true))
end

function targeting.threat_nearby(player, yards)
    yards = cap(yards)
    if not player then
        return false
    end
    yards = tonumber(yards) or 50
    local pos = state.cached_pos or safe(function() return player:get_position() end)
    if not pos then
        return false
    end
    local list = enemy_units(player, pos, yards)
    if type(list) ~= "table" then
        return false
    end
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true then
            if call(u.is_dead_or_ghost, u) ~= true then
                if call(u.is_player, u) ~= true then
                    if call(u.is_dummy, u) ~= true then
                        if call(player.can_attack, player, u) ~= false then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- ============================================================================
-- COMBAT LOCK (2.39.0)
-- ============================================================================
-- Everything that is fighting us, and the rule that the bot does not walk off
-- while a fight is still on.
local THREAT_RANGE = 40
targeting.THREAT_RANGE = THREAT_RANGE
local COMBAT_HOLD = 8.0       -- seconds to hold position in combat with no visible attacker
local hold_since = 0

--- Every live, attackable mob in combat that is targeting the player OR the
--- player's pet, within `range` (default THREAT_RANGE).
---
--- combat_scan counts only mobs targeting the player, and callers looked out
--- to combat range + 10 yards: a caster hitting a melee character from 25
--- yards, or anything on the pet, was not an attacker, and the bot walked
--- back to its waypoint mid-fight. Mobs already marked unreachable are left
--- out, so the lock cannot fix on something it cannot get to.
function targeting.threats(player, range)
    local found = {}
    if not player then
        return found
    end
    local pos = state.cached_pos or safe(function() return player:get_position() end)
    if not pos then
        return found
    end
    local me_guid = safe(function() return player:get_guid() end)
    local pet_guid = nil
    local pet = safe(function() return player:get_pet() end)
    if indexable(pet) and call(pet.is_valid, pet) == true then
        pet_guid = call(pet.get_guid, pet)
    end
    local list = enemy_units(player, pos, cap(range) or THREAT_RANGE)
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true
            and call(u.is_dead_or_ghost, u) ~= true
            and call(u.is_in_combat, u) == true then
            local tar = call(u.get_target, u)
            local tguid = indexable(tar) and call(tar.get_guid, tar) or nil
            if tguid ~= nil and (tguid == me_guid or (pet_guid ~= nil and tguid == pet_guid)) then
                local g = call(u.get_guid, u)
                if not (state.is_unreachable and g and state.is_unreachable(g)) then
                    found[#found + 1] = u
                end
            end
        end
    end
    return found
end

--- Should the bot hold position instead of going back to its route?
---
--- True while the player is in combat with no attacker in view, for up to
--- COMBAT_HOLD seconds: a DoT still ticking, a mob that fled and is coming
--- back, a caster that has dropped its target for a moment. Walking off to
--- the next waypoint there drags the fight along or leaves a mob behind.
--- Call only when there is nothing to fight right now.
function targeting.combat_hold(player)
    if not player or call(player.is_in_combat, player) ~= true then
        hold_since = 0
        return false
    end
    local now = izi.now()
    if hold_since == 0 then
        hold_since = now
    end
    return (now - hold_since) < COMBAT_HOLD
end

--- A fight is on: restart the hold window next time nothing is in view.
function targeting.combat_active()
    hold_since = 0
end

--- The nearest unit attacking the player, when the current target is not
--- one of them - or nil.
---
--- "If being attacked, always attack what is attacking you" (2.37.0): the
--- engines only fought back when they had NO target, so a bot chasing one
--- mob kept chasing it while another hit it from behind. Compared by GUID
--- (current_guid), never by calling the stored target's methods - that
--- handle may belong to an object the game has freed.
function targeting.attacker_to_switch(player, current_guid, range)
    if not player or call(player.is_in_combat, player) ~= true then
        return nil
    end
    local pack = targeting.threats(player, range)
    if type(pack) ~= "table" or #pack == 0 then
        return nil
    end
    if current_guid ~= nil then
        for i = 1, #pack do
            local u = pack[i]
            if indexable(u) and call(u.get_guid, u) == current_guid then
                return nil          -- the current target is attacking us: stay on it
            end
        end
    end
    return targeting.nearest(player, pack)
end

function targeting.combat_scan(player, range)
    -- At least 10 yd (2.90.0): callers pass the engage distance, which for
    -- melee is now 1-5 yd - too tight to see what is hitting us.
    range = cap(math.max(tonumber(range) or 40, 10))
    local found = {}
    if not player then
        return found
    end
    local pos = state.cached_pos or safe(function() return player:get_position() end)
    if not pos then
        return found
    end
    local list = enemy_units(player, pos, range or 40)
    if type(list) ~= "table" then
        return found
    end
    local me_guid = safe(function() return player:get_guid() end)
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_in_combat, u) == true and call(u.is_dead_or_ghost, u) ~= true then
            local tar = call(u.get_target, u)
            local tguid = indexable(tar) and call(tar.get_guid, tar)
            if me_guid ~= nil and tguid == me_guid then
                found[#found + 1] = u
            end
        end
    end
    return found
end

--- Dead, lootable-looking units within `range` yards, nearest first not implied.
---
--- Read from the visible-object list (2.25.0). This used izi.enemies_if, which
--- lists ENEMIES - and a corpse is not one any more, so the scan came back
--- empty and the bot walked away from every kill without looting it. The
--- only other path was the kill target itself, which the quest engine clears
--- the moment the mob dies. enemies_if is kept as a fallback for a build
--- where the object list is unavailable.
function targeting.find_corpses(player, range)
    local found = {}
    if not player then
        return found
    end
    local yards = cap(range) or 10
    if yards < 1 then
        yards = 10
    end
    local objects = all_objects()
    if type(objects) == "table" then
        for i = 1, #objects do
            local obj = objects[i]
            if indexable(obj) and call(obj.is_valid, obj) == true
                and call(obj.is_unit, obj) == true
                and call(obj.is_player, obj) ~= true
                and call(obj.is_dead, obj) == true then
                local d = call(player.distance_to, player, obj)
                if type(d) == "number" and d <= yards then
                    found[#found + 1] = obj
                end
            end
        end
        return found
    end
    if type(izi.enemies_if) ~= "function" then
        return found
    end
    local ok, list = pcall(izi.enemies_if, yards, function(enemy)
        if not enemy then
            return false
        end
        local ok_valid, valid = pcall(enemy.is_valid, enemy)
        if not ok_valid or valid ~= true then
            return false
        end
        local ok_dead, dead = pcall(enemy.is_dead, enemy)
        return ok_dead == true and dead == true
    end)
    if not ok or type(list) ~= "table" then
        return found
    end
    return list
end

function targeting.nearest(player, units)
    local best = nil
    local best_d = 9999
    if not player or type(units) ~= "table" then
        return nil
    end
    for i = 1, #units do
        local u = units[i]
        local d = call(player.distance_to, player, u)
        if type(d) == "number" and d < best_d then
            best_d = d
            best = u
        end
    end
    return best, best_d
end

local function as_percent(value, current, maximum)
    if type(value) == "number" then
        if value >= 0 and value <= 1.5 then
            return value * 100
        end
        return value
    end
    if type(current) == "number" and type(maximum) == "number" and maximum > 0 then
        return (current / maximum) * 100
    end
    return 100
end

local RANGED_SLOT = 18 -- INVSLOT_RANGED (equipment slots 1-19)
local WAND_MANA = 5
local wand_eq_until = 0
local wand_eq_val = false

local function mana_percent(player)
    local pct = safe(function() return player:mana_pct() end)
    local cur = safe(function() return player:mana_current() end)
    local mx = safe(function() return player:mana_max() end)
    return as_percent(pct, cur, mx)
end

local function ranged_item_id(player)
    local info = safe(function()
        return player:get_item_at_inventory_slot(RANGED_SLOT)
    end)
    if type(info) ~= "table" or not info.object then
        return nil
    end
    local id = safe(function()
        return info.object:get_item_id()
    end)
    if type(id) == "number" and id > 0 then
        return id
    end
    return nil
end

local function item_is_wand(item_id)
    local info = safe(function()
        return core.quests.get_item_info(item_id)
    end)
    if type(info) ~= "table" then
        return nil
    end
    local loc = info.equip_loc
    if loc == "INVTYPE_RANGEDRIGHT" then
        return true
    end
    if loc == "INVTYPE_RANGED" or loc == "INVTYPE_THROWN" then
        return false
    end
    local sub = info.item_sub_type
    if type(sub) == "string" then
        if string.find(string.lower(sub), "wand", 1, true) then
            return true
        end
    end
    return nil
end

function targeting.has_wand_equipped(player)
    if not player then
        return false
    end
    local now = izi.now()
    if now < wand_eq_until then
        return wand_eq_val
    end
    wand_eq_until = now + 2
    wand_eq_val = false
    local id = ranged_item_id(player)
    if not id then
        return false
    end
    local wand = item_is_wand(id)
    if wand == true then
        wand_eq_val = true
        return true
    end
    if wand == false then
        return false
    end
    local class_id = safe(function() return player:get_class() end)
    if class_id == enums.class_id.MAGE or class_id == enums.class_id.PRIEST or class_id == enums.class_id.WARLOCK then
        wand_eq_val = true
        return true
    end
    return false
end

local function is_attacking(player)
    return safe(function()
        return auto_attack:is_auto_attacking(player)
    end) == true
end

local function start_attack_type(unit, attack_type)
    if type(attack_type) ~= "number" then
        return false
    end
    return safe(function()
        return auto_attack:start_attack(unit, attack_type)
    end) == true
end

local function stop_attack_type(unit, attack_type)
    if type(attack_type) ~= "number" then
        return
    end
    safe(function()
        return auto_attack:stop_attack(unit, attack_type)
    end)
end

local function in_melee(player, unit)
    if safe(function() return unit:is_in_melee_range(5) end) == true then
        return true
    end
    local d = safe(function() return player:distance_to(unit) end)
    return type(d) == "number" and d <= 5
end

local function start_wand_or_melee(player, unit, types)
    if is_attacking(player) then
        return true
    end
    if type(types) ~= "table" then
        return false
    end
    if in_melee(player, unit) then
        if start_attack_type(unit, types.MELEE) then
            return true
        end
        return start_attack_type(unit, types.WAND)
    end
    if start_attack_type(unit, types.WAND) then
        return true
    end
    return start_attack_type(unit, types.MELEE)
end

--- Target `unit` unless it already is the player's target.
---
--- set_target was issued up to three times a bot tick on the same unit -
--- set_current, the engine's fight_unit and start_auto_attack each asserted
--- it - which is a stream of targeting input for a target that never changed.
function targeting.ensure_target(player, unit)
    if not unit then
        return false
    end
    local cur = player and call(player.get_target, player)
    if indexable(cur) then
        local a = call(cur.get_guid, cur)
        local b = call(unit.get_guid, unit)
        if a ~= nil and a == b then
            return true
        end
    end
    pcall(core.input.set_target, unit)
    return true
end

-- Auto-attack is started at most once per AUTO_GAP per target, and only
-- within AUTO_REACH: it was re-issued every bot tick, including all the way
-- in from 10+ yards while the character was still walking up.
local AUTO_GAP = 1.0
local AUTO_REACH = 6.0
local auto_guid, auto_t, auto_type = nil, -1e9, nil

function targeting.start_auto_attack(player, unit)
    if not player or not indexable(unit) then
        return false
    end
    -- A freed unit here is a native crash (2.32.0 / 01:11 session).
    if call(unit.is_valid, unit) ~= true then
        return false
    end
    local types = auto_attack.ATTACK_TYPE
    if type(types) ~= "table" or type(types.MELEE) ~= "number" then
        return false
    end
    local d = call(player.distance_to, player, unit)
    local reach = AUTO_REACH
    local want = types.MELEE
    local hunter = call(player.get_class, player) == enums.class_id.HUNTER
    local shoot = 35
    if hunter then
        local hm = package.loaded["rotations/hunter"]
        if type(hm) == "table" and type(hm.gun_range) == "function" then
            local okg, gr = pcall(hm.gun_range)
            if okg and type(gr) == "number" and gr > 8 then
                shoot = gr
            end
        else
            local y = gui.slider and gui.slider("ranged_yards", 35)
            if type(y) == "number" and y > 8 then
                shoot = y
            end
        end
    end
    -- Hunter Auto Shot is ATTACK_TYPE.RANGED (75), not MELEE (6603).
    -- 2.152 started melee from the engage distance, so the hunter never
    -- shot and only white-hit after the mob closed (01:00 log).
    if hunter and type(d) == "number" and d > 5 and type(types.RANGED) == "number" then
        want = types.RANGED
        reach = shoot
    end
    if type(d) == "number" and d > reach then
        return false
    end
    -- Not through a wall (2.78.0).
    local ok_m, movement = pcall(require, "movement")
    if ok_m and type(movement) == "table" and type(movement.has_los) == "function"
        and movement.has_los(player, unit) ~= true then
        return false
    end
    local g = call(unit.get_guid, unit)
    local now = izi.now()
    if g ~= nil and g == auto_guid and auto_type == want and (now - auto_t) < AUTO_GAP then
        return true
    end
    auto_guid, auto_t, auto_type = g, now, want
    targeting.ensure_target(player, unit)
    if want == types.RANGED then
        stop_attack_type(unit, types.MELEE)
    end
    start_attack_type(unit, want)
    return true
end

function targeting.set_current(unit, kind)
    if not unit then
        state.reset_target()
        return
    end
    local pos = safe(function() return unit:get_position() end)
    state.target.unit = unit
    state.target.guid = safe(function() return unit:get_guid() end)
    state.target.kind = kind
    if kind == "kill" and state.target.guid and type(state.note_engaged) == "function" then
        state.note_engaged(state.target.guid)
    end
    if pos then
        state.target.x = pos.x
        state.target.y = pos.y
        state.target.z = pos.z
    end
    local player = nil
    pcall(function() player = izi.me() end)
    targeting.ensure_target(player, unit)
end

local function names_match(got, want)
    if type(got) ~= "string" or type(want) ~= "string" or want == "" then
        return false
    end
    if got == want then
        return true
    end
    return string.lower(got) == string.lower(want)
end

-- ----------------------------------------------------------------------------
-- SCAN COOLDOWN (2.98.0)
-- ----------------------------------------------------------------------------
-- Finding an NPC by name or id walks the whole object list, and the NPC
-- walks (quest givers, flight masters, merchants, trainers) asked every tick.
-- A match is reused for FIND_TTL while it is still valid, alive and within
-- the caller's range; after that, or once it has gone, the list is scanned
-- again.
local FIND_TTL = 2.0
local find_cache = {}          -- key -> { obj, t }
local find_n = 0

local function cached(player, key, range)
    local e = find_cache[key]
    if not e then return nil end
    if (izi.now() - e.t) >= FIND_TTL then return nil end
    local obj = e.obj
    if not indexable(obj) or call(obj.is_valid, obj) ~= true or call(obj.is_dead_or_ghost, obj) == true then
        find_cache[key] = nil
        return nil
    end
    local d = call(player.distance_to, player, obj)
    if type(d) ~= "number" or d > (range or 80) then return nil end
    return obj
end

local function remember(key, obj)
    if find_n > 100 then find_cache, find_n = {}, 0 end
    if not find_cache[key] then find_n = find_n + 1 end
    if obj then
        find_cache[key] = { obj = obj, t = izi.now() }
    else
        find_cache[key] = nil
    end
end

local function scan_named(player, name_a, name_b, range)
    if not player then
        return nil
    end
    local objects = all_objects()
    if type(objects) ~= "table" then
        return nil
    end
    local best = nil
    local best_d = range or 80
    for i = 1, #objects do
        local obj = objects[i]
        if indexable(obj) and call(obj.is_valid, obj) == true then
            if call(obj.is_dead_or_ghost, obj) ~= true then
                local got = call(obj.get_name, obj)
                if names_match(got, name_a) or names_match(got, name_b) then
                    local d = call(player.distance_to, player, obj)
                    if type(d) == "number" and d < best_d then
                        best_d = d
                        best = obj
                    end
                end
            end
        end
    end
    return best
end

function targeting.find_named(player, name_a, name_b, range)
    range = cap(range)
    if not player then return nil end
    local key = "n" .. tostring(name_a) .. "|" .. tostring(name_b)
    local hit = cached(player, key, range)
    if hit then return hit end
    local obj = scan_named(player, name_a, name_b, range)
    remember(key, obj)
    return obj
end

local function scan_npc(player, npc_id, range)
    if not player or not npc_id then
        return nil
    end
    local objects = all_objects()
    if type(objects) ~= "table" then
        return nil
    end
    local best = nil
    local best_d = range or 80
    for i = 1, #objects do
        local obj = objects[i]
        if indexable(obj) and call(obj.is_valid, obj) == true then
            local id = call(obj.get_npc_id, obj)
            if id == npc_id then
                local d = call(player.distance_to, player, obj)
                if type(d) == "number" and d < best_d then
                    best_d = d
                    best = obj
                end
            end
        end
    end
    return best
end

function targeting.find_npc(player, npc_id, range)
    range = cap(range)
    if not player or not npc_id then return nil end
    local key = "i" .. tostring(npc_id)
    local hit = cached(player, key, range)
    if hit then return hit end
    local obj = scan_npc(player, npc_id, range)
    remember(key, obj)
    return obj
end

return targeting
