-- ============================================================================
-- Master Farmer - Grindbot
-- supplies.lua - restock food and drink at the merchant
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.106.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Ported from the reference bot's Buy_Food_Drinks.
--
-- This was reported as unimplementable in v1.4.3. That was wrong: the search
-- covered only the calls this project already made, not the runtime. The
-- reflected API reference confirms all three needed calls exist -
--   core.game_ui.get_vendor_item_count()
--   core.game_ui.get_vendor_item_info(index)
--   core.input.buy_item(index, quantity)
--
-- WHAT THE SOURCE GETS WRONG, AND WHAT IS DONE INSTEAD
--
--   1. The source compares GetMerchantItemInfo's first return against an item
--      NAME from GetItemInfo. Names are localised, so on any non-English
--      client nothing ever matches and the bot silently buys nothing. Here the
--      match is on item id, which is locale-proof - the same reason
--      rotations/*.lua key spells by id.
--
--   2. The source picks the highest-level food it can use, then buys 5 of it
--      with one BuyMerchantItem call. A vendor stack is usually 1, so "5" is
--      five stacks only if the vendor sells them that way - it does not check.
--      Here the wanted count is tracked against what is actually in the bags
--      and the purchase repeats across ticks until the target is met.
--
--   3. The source sets Lack_Money on ANY failure, including "vendor does not
--      stock this", and then gives up on food entirely. Gold and stock are
--      separated here so an unstocked vendor does not look like poverty.
--
-- ONE THING STILL UNVERIFIED
--   get_vendor_item_info's return shape is not reflected - the dump states
--   "Return types are never reflected". field_of() therefore probes the
--   plausible key names and vendor_debug prints the real table once. Until
--   that is confirmed on a live merchant, treat buying as best-effort: it
--   fails closed (buys nothing) rather than buying the wrong thing.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local consumables = require("data/consumables")
local gui = require("gui")
local state = require("state")

local supplies = {}

local BUY_GAP = 0.8          -- seconds between buy_item calls
local MAX_PER_TRIP = 40      -- hard stop so a bad probe cannot drain the purse

local last_buy = -1e9
local bought_this_trip = 0
local debug_done = false

-- 2.73.0: what the merchant that is open now did NOT stock, so the vendor trip
-- can go on to an innkeeper / general-goods NPC for it. Every zone merchant in
-- grind/zones is an armorer or weaponsmith, which stocks neither food nor
-- water - buying could never succeed at them.
local missing = { food = false, drink = false }
-- A buy that does not raise the bag count is not repeated for ever.
local pending = nil            -- { reason, have } of the last buy sent
local refused = {}             -- reason -> failed buys at this merchant
local MAX_REFUSED = 3

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "supplies", fmt, ...)
    end
end

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- VENDOR ITEM INFO
-- ----------------------------------------------------------------------------
--- Read a field from a vendor entry under any of its plausible names.
--- The return shape is not reflected in the API dump, so guessing a single
--- name would read nil and silently match nothing.
local function field_of(entry, names)
    if type(entry) ~= "table" then
        return nil
    end
    for i = 1, #names do
        local v = entry[names[i]]
        if v ~= nil then
            return v
        end
    end
    return nil
end

local ID_KEYS    = { "item_id", "id", "itemId", "item" }
local PRICE_KEYS = { "price", "cost", "money", "buy_price", "item_price" }
local STACK_KEYS = { "stack_count", "stack", "quantity", "count", "item_stack" }

local function vendor_entry(index)
    return safe(function() return core.game_ui.get_vendor_item_info(index) end)
end

local function vendor_count()
    local n = safe(function() return core.game_ui.get_vendor_item_count() end)
    if type(n) == "number" and n > 0 then
        return n
    end
    return 0
end

-- ----------------------------------------------------------------------------
-- DIAGNOSTIC
-- ----------------------------------------------------------------------------
local function debug_dump(entry, index)
    if debug_done or not gui.is_on("vendor_debug") then
        return
    end
    debug_done = true
    core.log("[Master Farmer - Grindbot] get_vendor_item_info(" .. tostring(index) .. ") fields:")
    if type(entry) ~= "table" then
        core.log("    returned a " .. type(entry) .. ", not a table - buying cannot work on this build")
        return
    end
    local keys = {}
    for k in pairs(entry) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for i = 1, #keys do
        local v = entry[keys[i]]
        local ty = type(v)
        if ty == "string" or ty == "number" or ty == "boolean" then
            core.log(string.format("    %-16s %s = %s", keys[i], ty, tostring(v)))
        else
            core.log(string.format("    %-16s %s", keys[i], ty))
        end
    end
    core.log("    id field resolved:    " .. tostring(field_of(entry, ID_KEYS)))
    core.log("    price field resolved: " .. tostring(field_of(entry, PRICE_KEYS)))
end

-- ----------------------------------------------------------------------------
-- BAG COUNTS
-- ----------------------------------------------------------------------------
--- How many of any id in `ids` we are carrying.
local function carried(ids)
    local want = {}
    for i = 1, #ids do want[ids[i]] = true end

    local total = 0
    for bag = 0, 4 do
        local items = safe(function() return core.inventory.get_items_in_bag(bag) end)
        if type(items) == "table" then
            for i = 1, #items do
                local entry = items[i]
                if type(entry) == "table" and entry.object then
                    local id = safe(function() return entry.object:get_item_id() end)
                    if id and want[id] then
                        local n = safe(function() return entry.object:get_item_stack_count() end)
                        total = total + ((type(n) == "number" and n > 0) and n or 1)
                    end
                end
            end
        end
    end
    return total
end

-- ----------------------------------------------------------------------------
-- SELECTION
-- ----------------------------------------------------------------------------
--- Best vendor index stocking anything in `ids`, preferring the entry earliest
--- in the ranked list (data/consumables.lua is ordered best-first, so the first
--- match is the best item the vendor actually stocks).
local function find_on_vendor(ids)
    local rank = {}
    for i = 1, #ids do
        if rank[ids[i]] == nil then rank[ids[i]] = i end
    end

    local n = vendor_count()
    local best_index, best_rank, best_price = nil, nil, nil
    for index = 1, n do
        local entry = vendor_entry(index)
        debug_dump(entry, index)
        local id = field_of(entry, ID_KEYS)
        if type(id) == "number" and rank[id] then
            local r = rank[id]
            if not best_rank or r < best_rank then
                best_index, best_rank = index, r
                best_price = field_of(entry, PRICE_KEYS)
            end
        end
    end
    return best_index, best_price
end

-- ----------------------------------------------------------------------------
-- BUY
-- ----------------------------------------------------------------------------
--- Buy one lot of `ids` if we are short.
--- Returns acted, failure - where failure is nil, "stock" or "gold".
--- The caller needs the distinction: running out of gold is terminal for the
--- whole trip, while an unstocked item only rules out that one line.
local function restock(ids, target, reason)
    if type(ids) ~= "table" or #ids == 0 or target <= 0 then
        return false
    end

    local have = carried(ids)
    if pending and pending.reason == reason then
        if have <= pending.have then
            refused[reason] = (refused[reason] or 0) + 1
            trail("bought %s but the bag count did not rise (%d) - attempt %d", reason, have, refused[reason])
        else
            refused[reason] = 0
        end
        pending = nil
    end
    if have >= target then
        return false
    end
    if (refused[reason] or 0) >= MAX_REFUSED then
        state.set_note("Vendor", "Merchant would not sell " .. reason)
        return false, "stock"
    end

    local index, price = find_on_vendor(ids)
    if not index then
        state.set_note("Vendor", "No " .. reason .. " stocked here")
        trail("no %s stocked at this merchant (%d vendor items)", reason, vendor_count())
        return false, "stock"
    end

    -- Gold and stock are separate failures. Reporting "out of money" for an
    -- unstocked vendor, as the source does, sends the operator hunting the
    -- wrong problem.
    -- Up to 5 per call (2.73.0): one item per 0.8 s made a 20 + 20 restock a
    -- 30-second stand at the counter. Never more than the gold covers.
    local qty = math.min(target - have, 5)
    if type(price) == "number" and price > 0 then
        local gold = safe(function() return core.inventory.get_gold() end)
        if type(gold) == "number" then
            if gold < price then
                state.set_note("Vendor", "Not enough gold for " .. reason)
                return false, "gold"
            end
            qty = math.max(1, math.min(qty, math.floor(gold / price)))
        end
    end

    bought_this_trip = bought_this_trip + 1
    last_buy = izi.now()
    pending = { reason = reason, have = have }
    state.set_note("Vendor", string.format("Buying %s (%d/%d)", reason, have, target))
    trail("buy %d %s at vendor index %d", qty, reason, index)
    pcall(function() core.input.buy_item(index, qty) end)
    return true
end

-- ----------------------------------------------------------------------------
-- PUBLIC
-- ----------------------------------------------------------------------------
--- Call while the merchant window is open, from vendor.lua's trip.
--- Returns true when it acted this tick (the caller should hold the cascade).
function supplies.tick(player)
    if not player or not gui.is_on("buy_supplies") then
        return false
    end
    if bought_this_trip >= MAX_PER_TRIP then
        return false
    end
    if (izi.now() - last_buy) < BUY_GAP then
        return true
    end

    local food_target = gui.slider("food_target", 20) or 20
    local acted, failure = restock(consumables.FOOD_ITEM_IDS, food_target, "food")
    missing.food = failure == "stock"
    if acted then
        return true
    end
    -- Out of gold is terminal: trying drink next would only overwrite the note
    -- with a stock message and hide the real reason from the operator.
    if failure == "gold" then
        return false
    end

    -- Warriors and Rogues have no mana, so drink is dead weight for them.
    local class_id = safe(function() return player:get_class() end)
    local no_mana = (class_id == 1) or (class_id == 4)   -- WARRIOR, ROGUE
    if not no_mana then
        local drink_target = gui.slider("drink_target", 20) or 20
        local d_acted, d_failure = restock(consumables.WATER_ITEM_IDS, drink_target, "drink")
        missing.drink = d_failure == "stock"
        if d_acted then
            return true
        end
    end

    return false
end

--- Reset the per-trip cap. vendor.lua calls this when a trip starts or ends.
function supplies.reset()
    bought_this_trip = 0
    last_buy = -1e9
    missing.food, missing.drink = false, false
    pending = nil
    refused = {}
end

--- A new merchant window: its stock is judged afresh.
function supplies.new_merchant()
    missing.food, missing.drink = false, false
    pending = nil
    refused = {}
end

--- Did the merchant just worked lack food or drink we still need?
function supplies.needs_supplier(player)
    if not player or not gui.is_on("buy_supplies") then
        return false
    end
    if missing.food then
        return true
    end
    if missing.drink then
        local class_id = safe(function() return player:get_class() end)
        return class_id ~= 1 and class_id ~= 4
    end
    return false
end

-- NPCs that sell food and water. Every innkeeper does; these general-goods
-- vendors stand beside the starting zones' armorers.
local SUPPLIER_NAMES = {
    ["Brother Danil"] = true,         -- Northshire Abbey
    ["Adlin Pridedrift"] = true,      -- Coldridge Valley
}

--- The nearest friendly food / water seller in sight, skipping `skip` GUIDs.
function supplies.find_supplier(player, range, skip)
    local ok_t, targeting = pcall(require, "targeting")
    local list = ok_t and targeting and type(targeting.visible_objects) == "function"
        and targeting.visible_objects() or nil
    if type(list) ~= "table" then
        return nil
    end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_unit() end) == true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return u:is_dead_or_ghost() end) ~= true
            and safe(function() return player:can_attack(u) end) ~= true then
            local name = safe(function() return u:get_name() end)
            if type(name) == "string" and (SUPPLIER_NAMES[name] or name:find("^Innkeeper ")) then
                local g = safe(function() return u:get_guid() end)
                if not (skip and g and skip[g]) then
                    local d = safe(function() return player:distance_to(u) end)
                    if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then
                        best, best_d = u, d
                    end
                end
            end
        end
    end
    return best, best_d
end

function supplies.register_gui(menu)
    -- On by default (2.73.0): with it off nothing was ever bought, and the
    -- box sits in the Vendor popup where it was easy to miss.
    menu:checkbox("mfg_buy_supplies", true, {
        label = "Buy Food / Drink",
        tab = "vendor",
        tooltip = "Restock food and water during a vendor trip, up to the counts below.",
    })
    menu:slider_int("mfg_food_target", 0, 60, 20, {
        label = "Keep Food",
        tab = "vendor",
    })
    menu:slider_int("mfg_drink_target", 0, 60, 20, {
        label = "Keep Drink",
        tab = "vendor",
        tooltip = "Ignored for Warriors and Rogues.",
    })
    menu:checkbox("mfg_vendor_debug", false, {
        label = "Log vendor item fields",
        tab = "vendor",
        tooltip = "Prints once what get_vendor_item_info actually returns. Run this at a "
            .. "merchant before trusting automatic buying.",
    })
end

return supplies
