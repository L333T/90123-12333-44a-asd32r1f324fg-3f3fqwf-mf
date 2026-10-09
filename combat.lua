-- ============================================================================
-- Master Farmer - Grindbot
-- Combat engine - pack scan, target latch, kill-first priority, class hooks
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.247.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Shared by every class rotation. Class modules opt in by exposing interrupt,
-- taunt or aggro_dump; the engine never casts on their behalf.
--
-- WHAT THIS ADDS OVER targeting.combat_scan
--   That scan counts only mobs whose target is the PLAYER. Four things were
--   missing from it, and each one costs something real:
--
--   pet-held mobs   A hunter, warlock or a mage with a Water Elemental sees
--                   nothing the pet is holding, so the pack reads as empty
--                   and every AoE and every "2+ enemies" gate stays shut
--                   through the whole fight.
--   nearest first   The list came back in object-manager order, so "the
--                   closest one" was whatever the client happened to list.
--   can_attack      Nothing asked the client whether the unit is attackable,
--                   so a friendly or immune mob could enter the pack.
--   on_me           No way to tell how many are actually hitting the player,
--                   which is the number an aggro dump wants.
--
-- INTERRUPTS ACROSS THE PACK
--   The rotations interrupt their CURRENT target and nothing else. Fighting
--   mob A while mob B casts a heal means B finishes the cast. combat.assist
--   runs the class's interrupt against every caster in the pack, which is
--   what the hook was always for.
--
-- THE LATCH
--   A caller's own live target always wins; the latch only fills in when that
--   target is gone, so grind and quest routes stay in charge of what to fight.
--   Melee specs hold far longer than casters because retargeting mid-swing
--   throws away a swing timer, where a caster loses at most a global.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local state = require("state")

local combat = {}

-- core.get_instance_type() answers the client's instance type string, where
-- "none" or an empty string is the open world. Anything else widens the scan
-- to every hostile in combat instead of only the ones on the player or pet.
local OPEN_WORLD = "none"

local DEFAULT_RANGE = 40.0
local DISMOUNT_RANGE = 40.0
local DEFAULT_HOLD = 1.0
local MELEE_HOLD = 10.0

local MELEE_HOLD_CLASSES = {
    [enums.class_id.WARRIOR] = true,
    [enums.class_id.ROGUE] = true,
    [enums.class_id.DRUID] = true,
    [enums.class_id.PALADIN] = true,
}

local kill_first = {}
local fixed_unit = nil
local fixed_at = 0
local on_me_count = 0
local targeting_mod = nil

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
--- Identical behaviour, no allocation. Used for the calls inside loops over
--- the visible object list, where the closure form allocated one per object
--- per predicate.
---
--- THE RECEIVER MUST BE NON-NIL: the index u.is_valid happens OUTSIDE the
--- pcall, so a nil receiver throws here where the closure form swallowed it.
--- Every call site keeps its `if u and ...` guard for that reason. A receiver
--- that exists but lacks the method is still fine - pcall catches calling a
--- nil value.
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


-- targeting requires nothing from here, but resolving it lazily keeps the two
-- modules free of a load-order dependency either way round.
local function targeting_ref()
    if targeting_mod then
        return targeting_mod
    end
    local ok, mod = pcall(require, "targeting")
    if ok and type(mod) == "table" then
        targeting_mod = mod
    end
    return targeting_mod
end

local function guid_of(unit)
    if not indexable(unit) then
        return nil
    end
    return call(unit.get_guid, unit)
end

local function alive(unit)
    if not indexable(unit) then
        return false
    end
    if call(unit.is_valid, unit) ~= true then
        return false
    end
    return call(unit.is_dead_or_ghost, unit) ~= true
end

local function grouped()
    local list = safe(function() return core.object_manager.get_party_frames() end)
    return type(list) == "table" and #list > 0
end

local function hold_time(player)
    local class_id = safe(function() return player:get_class() end)
    if class_id and MELEE_HOLD_CLASSES[class_id] then
        return MELEE_HOLD
    end
    return DEFAULT_HOLD
end

--- Is the character inside an instance rather than the open world?
function combat.in_instance()
    local kind = safe(function() return core.get_instance_type() end)
    if type(kind) ~= "string" or kind == "" then
        return false
    end
    return string.lower(kind) ~= OPEN_WORLD
end

--- Npc ids to kill before anything else in the pack.
function combat.set_kill_first(ids)
    kill_first = {}
    if type(ids) ~= "table" then
        return
    end
    for i = 1, #ids do
        if type(ids[i]) == "number" and ids[i] > 0 then
            kill_first[#kill_first + 1] = ids[i]
        end
    end
end

function combat.kill_first()
    return kill_first
end

--- Hostile combatants around the player, nearest first.
---
--- In the open world a mob counts when it is fighting the player OR the pet.
--- Inside an instance every hostile in combat counts, which is how packs are
--- pulled there.
---@return game_object[] pack, integer on_me
function combat.scan(player, range)
    local found = {}
    on_me_count = 0
    if not player then
        return found, 0
    end

    local yards = tonumber(range) or DEFAULT_RANGE
    if yards < 10 then yards = 10 end        -- 2.90.0: melee engage distance is 1-5 yd
    local list = nil
    local targeting = targeting_ref()
    if targeting and type(targeting.enemy_list) == "function" then
        list = safe(function() return targeting.enemy_list(player, yards) end)
    end
    if type(list) ~= "table" then
        list = safe(function() return izi.enemies(yards) end) or {}
    end

    local me_guid = guid_of(player)
    local pet = safe(function() return player:get_pet() end)
    local pet_guid = pet and guid_of(pet) or nil
    local dungeon = combat.in_instance()

    local rows = {}
    for i = 1, #list do
        local u = list[i]
        if alive(u) and call(u.is_in_combat, u) == true then
            if call(player.can_attack, player, u) ~= false then
                local tar = call(u.get_target, u)
                local tguid = tar and guid_of(tar) or nil
                local mine = me_guid ~= nil and tguid ~= nil and tguid == me_guid
                local on_pet = pet_guid ~= nil and tguid ~= nil and tguid == pet_guid
                if dungeon or mine or on_pet then
                    local d = call(player.distance_to, player, u)
                    rows[#rows + 1] = {
                        unit = u,
                        distance = type(d) == "number" and d or 9999,
                        on_me = mine,
                    }
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        return a.distance < b.distance
    end)
    for i = 1, #rows do
        found[i] = rows[i].unit
        if rows[i].on_me then
            on_me_count = on_me_count + 1
        end
    end
    return found, on_me_count
end

--- How many from the last scan are actually hitting the player, as opposed to
--- the pet. This is the number an aggro dump cares about.
function combat.on_me()
    return on_me_count
end

--- Which one of the pack to fight.
function combat.pick(player, pack)
    if type(pack) ~= "table" or #pack == 0 then
        return nil
    end

    for k = 1, #kill_first do
        for i = 1, #pack do
            local u = pack[i]
            local id = indexable(u) and call(u.get_npc_id, u)
            if id == kill_first[k] then
                return u
            end
        end
    end

    -- Grouped play: help with something an ally already holds rather than
    -- pulling a fresh mob. There is no group-leader call, so ally aggro is
    -- the only cue available.
    if grouped() then
        local me_guid = guid_of(player)
        for i = 1, #pack do
            local u = pack[i]
            local tar = indexable(u) and call(u.get_target, u)
            if tar and guid_of(tar) ~= me_guid then
                if indexable(tar) and call(tar.is_player, tar) == true then
                    return u
                end
            end
        end
    end

    -- A mob the player can see first (2.81.0); the nearest otherwise, since a
    -- pack member out of sight may still be the one hitting us.
    local targeting = targeting_ref()
    if targeting and type(targeting.can_see) == "function" then
        for i = 1, #pack do
            if targeting.can_see(player, pack[i]) then
                return pack[i]
            end
        end
    end
    return pack[1]
end

function combat.hold(unit)
    fixed_unit = unit
    fixed_at = izi.now()
end

function combat.release()
    fixed_unit = nil
    fixed_at = 0
end

-- The latch follows state.target (2.143.0): a cleared target clears it too.
if type(state.on_target_reset) == "table" then
    state.on_target_reset[#state.on_target_reset + 1] = function() combat.release() end
end

function combat.fixed_target()
    if alive(fixed_unit) then
        return fixed_unit
    end
    return nil
end

local CLOSER_BY = 3

local function is_kill_first(unit)
    local id = indexable(unit) and call(unit.get_npc_id, unit)
    if type(id) ~= "number" then return false end
    for k = 1, #kill_first do
        if kill_first[k] == id then return true end
    end
    return false
end

local function same_unit(a, b)
    if not a or not b then return false end
    local ga, gb = guid_of(a), guid_of(b)
    return ga ~= nil and ga == gb
end

--- A living pack member that should replace `candidate`: a kill-first npc
--- the current target is not, or an enemy at least CLOSER_BY yards nearer
--- and already inside the class engage distance.
local function closer_target(player, candidate, pack, engage)
    if type(pack) ~= "table" then return nil end
    if not is_kill_first(candidate) then
        for k = 1, #kill_first do
            for i = 1, #pack do
                local u = pack[i]
                if alive(u) and not same_unit(u, candidate) then
                    local id = indexable(u) and call(u.get_npc_id, u)
                    if id == kill_first[k] then return u end
                end
            end
        end
    end
    local cd = call(player.distance_to, player, candidate)
    if type(cd) ~= "number" then return nil end
    local limit = tonumber(engage) or 30
    local best, best_d = nil, cd
    for i = 1, #pack do
        local u = pack[i]
        if alive(u) and not same_unit(u, candidate) then
            local d = call(player.distance_to, player, u)
            if type(d) == "number" and d <= limit and d <= best_d - CLOSER_BY then
                best, best_d = u, d
            end
        end
    end
    return best
end

local function adopt(unit, kind)
    combat.hold(unit)
    local targeting = targeting_ref()
    if targeting and type(targeting.set_current) == "function" then
        pcall(function()
            targeting.set_current(unit, kind or "kill")
        end)
    end
end

--- Resolve who to fight.
---
--- A caller's live target is kept unless a kill-first npc, or an enemy
--- already inside the class range and at least 3 yards closer, should take
--- over. The latch only fills in when that target is gone.
---@return game_object|nil target, game_object[] pack
--- Is the candidate being fought (alive; in combat or wounded)? 2.226.0.
local function engaged(unit)
    local targeting = targeting_ref()
    if targeting and type(targeting.engaged) == "function" then
        return targeting.engaged(unit) == true
    end
    return alive(unit) and call(unit.is_in_combat, unit) == true
end

function combat.acquire(player, range, candidate, pack)
    if type(pack) ~= "table" then
        pack = combat.scan(player, range)
    end
    if alive(candidate) then
        -- ONE TARGET UNTIL IT DIES (2.226.0): a target being fought is kept,
        -- whatever else joins - no closer mob, no kill-first npc takes over.
        -- Those swaps apply only before the fight with it has begun.
        if not engaged(candidate) then
            local nearer = closer_target(player, candidate, pack, range)
            if nearer then
                adopt(nearer, "kill")
                return nearer, pack
            end
        end
        combat.hold(candidate)
        return candidate, pack
    end
    if alive(fixed_unit) and (izi.now() - fixed_at) < hold_time(player) then
        return fixed_unit, pack
    end

    local picked = combat.pick(player, pack)
    if picked then
        combat.hold(picked)
        local targeting = targeting_ref()
        if targeting and type(targeting.set_current) == "function" then
            pcall(function()
                targeting.set_current(picked, "kill")
            end)
        end
    else
        combat.release()
    end
    return picked, pack
end

-- One dismount per DISMOUNT_GAP (2.217.0): it was sent every tick, 10 a second,
-- for as long as the mount lasted. The tick is still claimed while mounted.
local DISMOUNT_GAP = 1.0
local dismount_t = -1e9

function combat.dismount(player, target)
    if not player or safe(function() return player:is_mounted() end) ~= true then
        return false
    end
    if target then
        local d = safe(function() return player:distance_to(target) end)
        if type(d) == "number" and d > DISMOUNT_RANGE then
            return false
        end
    end
    local now = izi.now()
    if (now - dismount_t) >= DISMOUNT_GAP then
        dismount_t = now
        pcall(core.input.dismount)
    end
    return true
end

local function casting(unit)
    if not indexable(unit) then
        return false
    end
    return call(unit.is_channeling_or_casting, unit) == true
end

--- Give the class module its interrupt, taunt and aggro-dump windows before
--- the damage rotation runs. Every hook is optional.
---
--- The interrupt pass is the point of this function: it runs against every
--- caster in the pack, not just the current target, so a mob healing itself
--- behind the one being hit still gets kicked.
function combat.assist(player, target, pack, module)
    if type(module) ~= "table" or type(pack) ~= "table" then
        return false
    end

    if type(module.interrupt) == "function" then
        for i = 1, #pack do
            local u = pack[i]
            if casting(u) and call(module.interrupt, player, u) == true then
                return true
            end
        end
    end

    if type(module.taunt) == "function" then
        local me_guid = guid_of(player)
        for i = 1, #pack do
            local u = pack[i]
            local tar = indexable(u) and call(u.get_target, u)
            if not tar or guid_of(tar) ~= me_guid then
                if call(module.taunt, player, u) == true then
                    return true
                end
            end
        end
    end

    if #pack >= 2 and type(module.aggro_dump) == "function" then
        if call(module.aggro_dump, player, pack) == true then
            return true
        end
    end

    return false
end

function combat.reset()
    combat.release()
    on_me_count = 0
    if state and type(state.combat) == "table" then
        state.combat.kite_until = 0
    end
end

return combat
