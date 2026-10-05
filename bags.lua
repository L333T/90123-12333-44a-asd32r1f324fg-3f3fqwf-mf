-- ============================================================================
-- Master Farmer - Grindbot
-- Bag items with the (bag, slot) pair the container calls actually take
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.236.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- core.input.use_container_item documents it plainly: the slot index that
-- core.inventory.get_items_in_bag reports is shifted by one from the one the
-- container calls take, and "passing a raw slot_id straight from
-- get_items_in_bag targets the item NEXT to the one you meant".
-- common/utility/inventory_helper owns that shift and is the supported source
-- of the pair.
--
-- equip.lua and vendor.lua both passed the raw slot_id. Auto-equip used the
-- item beside the upgrade - the gloves never moved, so it tried again every
-- ten seconds for the whole session - and the vendor sold the item beside
-- each grey or white.
--
-- This is the pattern the working SP / SP_Pull plugins use:
-- get_character_bag_slots, minus anything that is currently equipped, and
-- use_container_item(slot.bag_id, slot.bag_slot).
-- ============================================================================

---@type inventory_helper
local inventory_helper = require("common/utility/inventory_helper")

local bags = {}

local EQUIP_MIN, EQUIP_MAX = 0, 23

local function equipped_set(player)
    local set = {}
    if not player then
        return set
    end
    for slot_id = EQUIP_MIN, EQUIP_MAX do
        local ok, info = pcall(player.get_item_at_inventory_slot, player, slot_id)
        if ok and type(info) == "table" and info.object then
            local ok_v, valid = pcall(info.object.is_valid, info.object)
            if ok_v and valid == true then
                set[info.object] = true
            end
        end
    end
    return set
end

--- Every item in the character's bags, as
---     { item = game_object, item_id = n, bag = bag_id, slot = bag_slot, count = n }
--- with bag / slot exactly what use_container_item takes. Equipped items are
--- left out.
-- ONLY WHAT IS REALLY IN THE BAGS (2.184.0). get_character_bag_slots on this
-- client also hands back entries at "bag 0 slot 61-72": the engine's player
-- container ends with bank storage on some clients, and the 10:34 vendor
-- tried to sell those same seven items on every trip. An entry is kept only
-- inside a real bag: the backpack's 16 slots, or a worn bag's own size
-- (get_num_bag_slots, one higher than the bag id; 0 = no bag there).
local BACKPACK_SLOTS = 16

local function bag_capacity(bag)
    if bag == 0 then return BACKPACK_SLOTS end
    if type(bag) ~= "number" or bag < 1 or bag > 4 then return 0 end
    local ok, n = pcall(function() return core.inventory.get_num_bag_slots(bag + 1) end)
    if ok and type(n) == "number" and n > 0 and n <= 36 then return n end
    return 0
end
bags.capacity = bag_capacity

function bags.list(player)
    local out = {}
    local caps = {}
    for b = 0, 4 do caps[b] = bag_capacity(b) end
    if not inventory_helper or type(inventory_helper.get_character_bag_slots) ~= "function" then
        return out
    end
    local ok, slots = pcall(function() return inventory_helper:get_character_bag_slots() end)
    if not ok or type(slots) ~= "table" then
        return out
    end
    local equipped = equipped_set(player)
    for i = 1, #slots do
        local s = slots[i]
        if type(s) == "table" and s.item and not equipped[s.item]
            and type(s.bag_id) == "number" and type(s.bag_slot) == "number"
            and s.bag_slot >= 1 and s.bag_slot <= (caps[s.bag_id] or 0) then
            local ok_v, valid = pcall(s.item.is_valid, s.item)
            if ok_v and valid == true then
                local ok_id, id = pcall(s.item.get_item_id, s.item)
                out[#out + 1] = {
                    item = s.item,
                    item_id = (ok_id and type(id) == "number") and id or nil,
                    bag = s.bag_id,
                    slot = s.bag_slot,
                    count = s.stack_count,
                    global = s.global_slot,
                }
            end
        end
    end
    return out
end

--- Can the bags be read at all (inventory_helper present)? 2.231.0.
function bags.readable()
    return inventory_helper ~= nil and type(inventory_helper.get_character_bag_slots) == "function"
end

--- The item id at (bag, slot) now, or nil when the slot is empty.
function bags.item_at(player, bag, slot)
    local list = bags.list(player)
    for i = 1, #list do
        if list[i].bag == bag and list[i].slot == slot then
            return list[i].item_id
        end
    end
    return nil
end

--- Use the bag item at (bag, slot): equips gear, sells at a merchant.
function bags.use(bag, slot)
    return pcall(function() core.input.use_container_item(bag, slot) end)
end

-- BY ITEM ID (2.80.0). The (bag, slot) pair inventory_helper hands out is
-- wrong for the backpack on this client: the 14:25 log sold "bag 0 slot
-- 61..72" - a 16-slot bag - and every sale failed, so the vendor trip stood
-- at the merchant retrying. The raw get_items_in_bag slot is documented as
-- shifted by one, so guessing a correction could sell the item beside the
-- junk. use_item(item_id) acts on a stack of exactly that item - selling it
-- while a merchant is open, equipping it otherwise - and cannot touch any
-- other item.
function bags.use_id(item_id)
    if type(item_id) ~= "number" or item_id <= 0 then
        return false
    end
    local ok, r = pcall(function() return core.input.use_item(item_id) end)
    return ok and r ~= false
end

--- How many of `item_id` are in the bags (stack sizes summed).
function bags.count(item_id)
    -- From the filtered helper list (2.184.0): the raw bag-0 container also
    -- holds worn gear and, on some clients, bank storage.
    local total = 0
    local me = nil
    pcall(function() me = require("common/izi_sdk").me() end)
    local list = bags.list(me)
    for i = 1, #list do
        local e = list[i]
        if e.item_id == item_id then
            total = total + ((type(e.count) == "number" and e.count > 0) and e.count or 1)
        end
    end
    return total
end

--- Free slots in ordinary bags: capacity minus occupied entries, special
--- bags (by `is_special(bag)`) left out.
function bags.free_slots(player, is_special)
    local list = bags.list(player)
    local used = {}
    for i = 1, #list do
        local b = list[i].bag
        used[b] = (used[b] or 0) + 1
    end
    local free = 0
    for b = 0, 4 do
        local cap = bag_capacity(b)
        if cap > 0 and not (is_special and b > 0 and is_special(b)) then
            free = free + math.max(0, cap - (used[b] or 0))
        end
    end
    return free
end

-- ----------------------------------------------------------------------------
-- FOOD AND WATER IN THE BAGS, WHATEVER THEY ARE (2.149.0)
-- ----------------------------------------------------------------------------
-- Resting and the supply runs only knew the ids in data/consumables.lua. Food
-- that list misses - a quest reward, a new drop - counted as "nothing to eat",
-- and the bot went to a vendor with food in its bags. Every bag item is now
-- classified once:
--   1. the curated lists (data/consumables.lua);
--   2. the item's use spell (core.quests.get_item_spell): "Food", "Drink",
--      "Refreshment" (both);
--   3. the item class (core.quests.get_item_info): Consumable (0) / Food &
--      Drink (5), split by the drink words below.
-- 2 and 3 are empty on WoW Forever (per the API docs), where only 1 applies.
-- An item the player's level cannot use yet is left out.
local consumables = require("data/consumables")

local KNOWN_FOOD, KNOWN_WATER = {}, {}
for i = 1, #consumables.FOOD_ITEM_IDS do KNOWN_FOOD[consumables.FOOD_ITEM_IDS[i]] = true end
for i = 1, #consumables.WATER_ITEM_IDS do KNOWN_WATER[consumables.WATER_ITEM_IDS[i]] = true end

local DRINK_WORDS = { "water", "milk", "juice", "tea", "nectar", "dew", "drink", "tonic", "spring" }
local CLASS_RETRY = 30.0
local class_cache = {}         -- item id -> { food, water, min_level } or { none = true, t = time }
local scan_cache = { t = -1e9, food = nil, water = nil }
local SCAN_TTL = 2.0

---@type izi_api
local izi = require("common/izi_sdk")

local function now_s()
    local ok, t = pcall(izi.now)
    if ok and type(t) == "number" then return t end
    return 0
end

local function has_drink_word(name)
    if type(name) ~= "string" then return false end
    local text = string.lower(name)
    for i = 1, #DRINK_WORDS do
        if text:find(DRINK_WORDS[i], 1, true) then return true end
    end
    return false
end

--- What an item is for: food, water (booleans) and its minimum level, or nil.
local function classify(id)
    if KNOWN_FOOD[id] or KNOWN_WATER[id] then
        return { food = KNOWN_FOOD[id] == true, water = KNOWN_WATER[id] == true, min_level = 0 }
    end
    local c = class_cache[id]
    if c and not c.none then return c end
    local t = now_s()
    if c and c.none and (t - c.t) < CLASS_RETRY then return nil end
    local ok_i, info = pcall(core.quests.get_item_info, id)
    info = (ok_i and type(info) == "table") and info or {}
    local min_level = type(info.min_level) == "number" and info.min_level or 0
    local ok_s, sp = pcall(core.quests.get_item_spell, id)
    local spell = ok_s and type(sp) == "table" and sp.spell_name or nil
    local food, water = false, false
    if spell == "Food" then
        food = true
    elseif spell == "Drink" then
        water = true
    elseif spell == "Refreshment" or spell == "Food & Drink" then
        food, water = true, true
    elseif info.class_id == 0 and info.subclass_id == 5 then
        if has_drink_word(info.name) then water = true else food = true end
    end
    if not food and not water then
        -- Nothing known yet: the client may not have the item cached. Ask again later.
        class_cache[id] = { none = true, t = t }
        return nil
    end
    c = { food = food, water = water, min_level = min_level }
    class_cache[id] = c
    return c
end

--- Food and water in the bags: two maps item id -> count, usable at the
--- player's level. Cached SCAN_TTL seconds.
function bags.food_water(player)
    local t = now_s()
    if scan_cache.food and (t - scan_cache.t) < SCAN_TTL then
        return scan_cache.food, scan_cache.water
    end
    local food, water = {}, {}
    local ok_l, level = pcall(function() return player:get_level() end)
    level = (ok_l and type(level) == "number") and level or 1
    local list = bags.list(player)
    for i = 1, #list do
        local e = list[i]
        local id = e.item_id
        if id then
            local c = classify(id)
            if c and (c.min_level or 0) <= level then
                local n = (type(e.count) == "number" and e.count > 0) and e.count or 1
                if c.food then food[id] = (food[id] or 0) + n end
                if c.water then water[id] = (water[id] or 0) + n end
            end
        end
    end
    scan_cache.t, scan_cache.food, scan_cache.water = t, food, water
    return food, water
end

--- Forget the cached scan (a purchase or a use just changed the bags).
function bags.food_water_invalidate()
    scan_cache.t = -1e9
end

--- Total food / water items carried (every kind, not only the curated ids).
function bags.food_water_count(player)
    local food, water = bags.food_water(player)
    local nf, nw = 0, 0
    for _, n in pairs(food) do nf = nf + n end
    for _, n in pairs(water) do nw = nw + n end
    return nf, nw
end

--- Bag food / water ids the curated lists do not have (for resting's use list).
function bags.extra_food_water(player)
    local food, water = bags.food_water(player)
    local ef, ew = {}, {}
    for id in pairs(food) do if not KNOWN_FOOD[id] then ef[#ef + 1] = id end end
    for id in pairs(water) do if not KNOWN_WATER[id] then ew[#ew + 1] = id end end
    table.sort(ef)
    table.sort(ew)
    return ef, ew
end

return bags
