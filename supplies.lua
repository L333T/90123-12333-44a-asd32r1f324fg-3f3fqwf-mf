-- ============================================================================
-- Master Farmer - Grindbot
-- supplies.lua - restock food and drink at the merchant
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.233.0
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
local gamever = require("gamever")

local consumables = require("data/consumables")
local bags = require("bags")
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
local per_unit = {}            -- 2.182.0: reason -> items one buy_item unit gave

-- Supply runs (2.139.0; moved up in 2.140.0 - supplies.tick writes poor_gold,
-- and a later declaration turned that write into a global, so the "no run
-- until the gold goes up" hold never engaged).
local MIN_COPPER = 25
local requested = { food = false, water = false }
local poor_gold = nil            -- gold on hand when a run last could not pay
local block_until = 0
local inn_list = nil
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
local QTY_KEYS   = { "quantity", "count", "stack" }     -- 2.182.0: units one purchase gives
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
    local best_index, best_rank, best_price, best_lot = nil, nil, nil, nil
    for index = 1, n do
        local entry = vendor_entry(index)
        debug_dump(entry, index)
        local id = field_of(entry, ID_KEYS)
        if type(id) == "number" and rank[id] then
            local r = rank[id]
            if not best_rank or r < best_rank then
                best_index, best_rank = index, r
                best_price = field_of(entry, PRICE_KEYS)
                best_lot = field_of(entry, QTY_KEYS)
            end
        end
    end
    return best_index, best_price, best_lot
end

-- ----------------------------------------------------------------------------
-- BUY
-- ----------------------------------------------------------------------------
--- Buy one lot of `ids` if we are short.
--- Returns acted, failure - where failure is nil, "stock" or "gold".
--- The caller needs the distinction: running out of gold is terminal for the
--- whole trip, while an unstocked item only rules out that one line.
local function restock(ids, target, reason, player)
    if type(ids) ~= "table" or #ids == 0 or target <= 0 then
        return false
    end

    -- Every kind in the bags counts (2.149.0, bags.food_water), not only the
    -- curated ids: food the list does not know is still food.
    local have = carried(ids)
    if player then
        bags.food_water_invalidate()
        local nf, nw = bags.food_water_count(player)
        local all = reason == "food" and nf or nw
        if type(all) == "number" and all > have then have = all end
    end
    if pending and pending.reason == reason then
        local gained = have - pending.have
        if gained <= 0 then
            refused[reason] = (refused[reason] or 0) + 1
            trail("bought %s but the bag count did not rise (%d) - attempt %d", reason, have, refused[reason])
        else
            refused[reason] = 0
            -- What one unit of buy_item's quantity gave (2.182.0): a lot of 5,
            -- or a single item. Measured once per trip, never assumed.
            if not per_unit[reason] then
                per_unit[reason] = gained / math.max(1, pending.q or 1)
                trail("%s: one buy unit gives %s", reason, tostring(per_unit[reason]))
            end
        end
        pending = nil
    end
    -- At or above the GUI amount: nothing to buy (2.182.0).
    if have >= target then
        return false
    end
    if (refused[reason] or 0) >= MAX_REFUSED then
        state.set_note("Vendor", "Merchant would not sell " .. reason)
        return false, "stock"
    end

    local index, price, lot = find_on_vendor(ids)
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
    -- HOW MANY (2.182.0). Food and water come 5 to a purchase; asking for
    -- (target - have) "units" bought five times too much when a unit was a
    -- lot. The first call buys one unit and measures it; after that only as
    -- many units as the shortfall needs, rounded up to whole lots.
    local need = target - have
    lot = (type(lot) == "number" and lot >= 1) and lot or 1
    local qty = 1
    local unit = per_unit[reason]
    if unit and unit > 0 then
        qty = math.ceil(need / unit)
        if unit < lot then
            -- A unit is one item: buy whole lots' worth.
            qty = math.ceil(qty / lot) * lot
        end
        qty = math.max(1, math.min(qty, (unit >= lot) and 5 or 20))
    end
    if type(price) == "number" and price > 0 then
        local gold = safe(function() return core.inventory.get_gold() end)
        if type(gold) == "number" then
            if gold < price then
                state.set_note("Vendor", "Not enough gold for " .. reason)
                return false, "gold"
            end
            -- price is per purchase (one lot): cap what the gold covers.
            local lots_affordable = math.floor(gold / price)
            local units_affordable = (unit and unit < lot) and lots_affordable * lot or lots_affordable
            qty = math.max(1, math.min(qty, units_affordable))
        end
    end

    bought_this_trip = bought_this_trip + 1
    last_buy = izi.now()
    pending = { reason = reason, have = have, q = qty }
    state.set_note("Vendor", string.format("Buying %s (%d/%d)", reason, have, target))
    trail("buy %d unit(s) of %s at vendor index %d (have %d, want %d, %d per purchase)", qty, reason, index, have, target, lot)
    pcall(function() core.input.buy_item(index, qty) end)
    return true
end

-- ----------------------------------------------------------------------------
-- PUBLIC
-- ----------------------------------------------------------------------------
--- Call while the merchant window is open, from vendor.lua's trip.
--- Returns true when it acted this tick (the caller should hold the cascade).
-- WoW Forever (2.123.0): core.game_ui.get_vendor_item_info returns an empty
-- row for every slot there (the game function it reads no longer exists), so
-- nothing on a vendor can be identified and buying by index would be buying
-- blind. Buying food / water stands down on Forever - conjured water and
-- looted food still work - and says so once.
local forever_logged = false

local function forever_blind()
    if not gamever.is_forever() then
        return false
    end
    if not forever_logged then
        forever_logged = true
        core.log("[Master Farmer - Grindbot] WoW Forever: vendor items cannot be read on this client "
            .. "- buying food and water is off (repair and selling still work).")
        trail("Forever: vendor item info unavailable - food / water buying off")
    end
    return true
end

function supplies.tick(player)
    if not player or not gui.is_on("buy_supplies") then
        return false
    end
    if forever_blind() then
        return false
    end
    if bought_this_trip >= MAX_PER_TRIP then
        return false
    end
    if (izi.now() - last_buy) < BUY_GAP then
        return true
    end

    local food_target = gui.slider("food_target", 20) or 20
    local acted, failure = restock(consumables.FOOD_ITEM_IDS, food_target, "food", player)
    missing.food = failure == "stock"
    if acted then
        return true
    end
    -- Out of gold is terminal: trying drink next would only overwrite the note
    -- with a stock message and hide the real reason from the operator.
    if failure == "gold" then
        -- No further run until the gold goes up (2.139.0).
        poor_gold = safe(function() return core.inventory.get_gold() end) or 0
        trail("not enough gold for food - no supply run until the gold goes up")
        return false
    end

    -- Warriors and Rogues have no mana, so drink is dead weight for them.
    local class_id = safe(function() return player:get_class() end)
    local no_mana = (class_id == 1) or (class_id == 4)   -- WARRIOR, ROGUE
    if not no_mana then
        local drink_target = gui.slider("drink_target", 20) or 20
        local d_acted, d_failure = restock(consumables.WATER_ITEM_IDS, drink_target, "drink", player)
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
    per_unit = {}
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
    if forever_blind() then
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

-- ----------------------------------------------------------------------------
-- SUPPLY RUNS (2.139.0)
-- ----------------------------------------------------------------------------
-- A rest that finds nothing to eat / drink asks for food or water
-- (supplies.request). A mana class also asks for water while questing when
-- the bags are under the Keep Drink count (2.171.0). A water run pauses the
-- RestedXP step only when one of the level's vendor waters is affordable:
-- gold on hand, or that gold plus the junk a trip would sell. Otherwise the
-- step keeps running until the water can be paid for. Food runs are unchanged.
-- vendor.lua walks to the nearest inn on the recorded Alliance Eastern
-- Kingdoms roads (data/ek_alliance_routes - innkeepers sell both), or to an
-- innkeeper in sight, sells junk, buys, and carries on.
-- (The run's state is declared with the module state at the top: supplies.tick
-- writes poor_gold, and a declaration down here made that write a global.)

local function forever()
    return gamever.is_forever()
end

--- A rest found no food ("food") or no water ("water").
function supplies.request(kind)
    if kind == "food" or kind == "water" then requested[kind] = true end
end

--- A run is finished; `blocked_for` seconds before another is wanted.
function supplies.trip_done(blocked_for)
    requested.food, requested.water = false, false
    if type(blocked_for) == "number" and blocked_for > 0 then
        block_until = izi.now() + blocked_for
    end
end

--- Innkeeper spots: every recorded road end tagged "inn".
local function inns()
    if inn_list then return inn_list end
    inn_list = {}
    local ok, routes = pcall(require, "data/ek_alliance_routes")
    if not ok or type(routes) ~= "table" then return inn_list end
    local function add(x, y, z)
        if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return end
        for i = 1, #inn_list do
            local p = inn_list[i]
            if (p.x - x) ^ 2 + (p.y - y) ^ 2 < 1600 then return end
        end
        inn_list[#inn_list + 1] = { x = x, y = y, z = z }
    end
    for i = 1, #routes do
        local r = routes[i]
        if type(r) == "table" and #r >= 7 then
            local n = math.floor((#r - 4) / 3)
            if r[2] == "inn" then add(r[5], r[6], r[7]) end
            if r[3] == "inn" and n >= 1 then
                local b = 5 + (n - 1) * 3
                add(r[b], r[b + 1], r[b + 2])
            end
        end
    end
    return inn_list
end

--- On Eastern Kingdoms? The continent of the nearest flight point.
local function in_eastern_kingdoms(me)
    return (gamever.continent_of(me)) == 0
end

--- The nearest known inn as { x, y, z }, or nil.
function supplies.nearest_inn(player)
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local ok_f, factions = pcall(require, "data/factions")
    if ok_f and type(factions) == "table" and factions.of_player(player) ~= "alliance" then
        return nil
    end
    if not in_eastern_kingdoms(me) then return nil end
    local best, best_d = nil, nil
    local list = inns()
    for i = 1, #list do
        local p = list[i]
        local d = math.sqrt((p.x - me.x) ^ 2 + (p.y - me.y) ^ 2)
        if best_d == nil or d < best_d then best, best_d = p, d end
    end
    return best, best_d
end

local function has_mana(player)
    local class_id = safe(function() return player:get_class() end)
    if class_id == 1 or class_id == 4 then
        return false
    end
    local ok_pw, pw = pcall(require, "power")
    local mx = ok_pw and type(pw) == "table" and pw.mana_max(player) or nil
    if type(mx) == "number" then
        return mx > 0
    end
    return type(class_id) == "number"
end

-- Innkeeper water, cheapest rank first. Buy prices are copper (classicdb /
-- TBC: Refreshing Spring Water 25c, Ice Cold Milk 1s25c, Melon Juice 5s,
-- Sweet Nectar 10s, Moonberry Juice 20s, Morning Glory Dew 40s, Filtered
-- Draenic Water 56s, Purified Draenic Water 64s).
local VENDOR_WATER = {
    { id = 159,   level = 1,  price = 25 },
    { id = 1179,  level = 5,  price = 125 },
    { id = 1205,  level = 15, price = 500 },
    { id = 1708,  level = 25, price = 1000 },
    { id = 1645,  level = 35, price = 2000 },
    { id = 8766,  level = 45, price = 4000 },
    { id = 28399, level = 60, price = 5600 },
    { id = 27860, level = 65, price = 6400 },
}

local function drink_target()
    local n = gui.slider("drink_target", 20)
    if type(n) ~= "number" or n < 1 then return 0 end
    return n
end

local function conjures_water()
    local ok_c, conjure = pcall(require, "conjure")
    return ok_c and type(conjure) == "table" and type(conjure.knows) == "function"
        and conjure.knows("water") == true
end

--- Best innkeeper water this level can drink, or nil.
local function water_offer(player)
    local lvl = safe(function() return player:get_level() end) or 1
    local best = nil
    for i = 1, #VENDOR_WATER do
        local row = VENDOR_WATER[i]
        if lvl >= row.level then best = row end
    end
    return best
end

local function water_have(player)
    local have = carried(consumables.WATER_ITEM_IDS)
    local _, nw = bags.food_water_count(player)
    if type(nw) == "number" and nw > have then have = nw end
    return have
end

--- Mana class, under the Keep Drink count, and not a mage who conjures it.
local function water_short(player)
    if not player or not has_mana(player) or conjures_water() then return false end
    local target = drink_target()
    if target < 1 then return false end
    return water_have(player) < target
end

--- One of this level's waters, from gold or from gold plus junk.
local function can_afford_water(player)
    local offer = water_offer(player)
    if not offer then return false end
    local gold = safe(function() return core.inventory.get_gold() end) or 0
    if gold >= offer.price then return true end
    local ok_v, vendor = pcall(require, "vendor")
    local junk = 0
    if ok_v and type(vendor) == "table" and type(vendor.junk_copper) == "function" then
        junk = vendor.junk_copper(player) or 0
    end
    return (gold + junk) >= offer.price
end

--- What a run would be for: need_food, need_water (after mage conjuring).
function supplies.missing(player)
    local need_food = requested.food
    local need_water = requested.water and has_mana(player)
    if need_food or need_water then
        local nf, nw = bags.food_water_count(player)
        if need_food and nf > 0 then need_food, requested.food = false, false end
        if need_water then
            local have = water_have(player)
            if type(nw) == "number" and nw > have then have = nw end
            if have >= drink_target() then need_water, requested.water = false, false end
        end
    end
    local ok_c, conjure = pcall(require, "conjure")
    if ok_c and type(conjure) == "table" and type(conjure.knows) == "function" then
        if need_water and conjure.knows("water") then need_water = false end
        if need_food and conjure.knows("food") then need_food = false end
    end
    return need_food, need_water
end

--- Should vendor.lua start a food / water run now? Also returns a reason
--- when it should not (for the resting note).
function supplies.trip_wanted(player)
    if not player or not gui.is_on("buy_supplies") then return false, "buying is off" end
    if forever() then return false, "vendor items unreadable on WoW Forever" end
    local ok_lv, vendor_lv = pcall(require, "vendor")
    if ok_lv and type(vendor_lv) == "table" and type(vendor_lv.level_ok) == "function"
        and not vendor_lv.level_ok(player) then
        return false, "no vendoring below level 2"
    end
    if izi.now() < block_until then return false, "no seller reachable" end
    if water_short(player) then requested.water = true end
    local need_food, need_water = supplies.missing(player)
    if not need_food and not need_water then return false, nil end
    local gold = safe(function() return core.inventory.get_gold() end) or 0
    if poor_gold ~= nil and gold > poor_gold + MIN_COPPER then poor_gold = nil end
    if need_water and not can_afford_water(player) then
        if not need_food then
            return false, "cannot afford water"
        end
        need_water = false
    end
    local ok_v, vendor = pcall(require, "vendor")
    local junk = ok_v and type(vendor) == "table" and type(vendor.has_junk) == "function"
        and vendor.has_junk(player) == true
    if need_food and not need_water and not junk and (gold < MIN_COPPER or poor_gold ~= nil) then
        return false, "no gold and nothing to sell"
    end
    if not need_food and not need_water then return false, "cannot afford water" end
    local inn = supplies.nearest_inn(player)
    if not inn and not supplies.find_supplier(player, 80, nil) then
        return false, "no inn or innkeeper known here"
    end
    return true, nil
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
