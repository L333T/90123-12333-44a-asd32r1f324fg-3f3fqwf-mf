-- ============================================================================
-- Master Farmer - Grindbot
-- Bag items with the (bag, slot) pair the container calls actually take
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.141.0
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
function bags.list(player)
    local out = {}
    if not inventory_helper or type(inventory_helper.get_character_bag_slots) ~= "function" then
        return out
    end
    local ok, slots = pcall(inventory_helper.get_character_bag_slots, inventory_helper)
    if not ok or type(slots) ~= "table" then
        return out
    end
    local equipped = equipped_set(player)
    for i = 1, #slots do
        local s = slots[i]
        if type(s) == "table" and s.item and not equipped[s.item]
            and type(s.bag_id) == "number" and type(s.bag_slot) == "number" then
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
    local total = 0
    for bag = 0, 4 do
        local ok, items = pcall(core.inventory.get_items_in_bag, bag)
        if ok and type(items) == "table" then
            for i = 1, #items do
                local e = items[i]
                local obj = type(e) == "table" and e.object or nil
                if obj then
                    local ok_id, id = pcall(obj.get_item_id, obj)
                    if ok_id and id == item_id then
                        local ok_n, n = pcall(obj.get_item_stack_count, obj)
                        total = total + ((ok_n and type(n) == "number" and n > 0) and n or 1)
                    end
                end
            end
        end
    end
    return total
end

return bags
