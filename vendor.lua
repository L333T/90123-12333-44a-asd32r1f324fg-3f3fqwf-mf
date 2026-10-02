-- ============================================================================
-- Master Farmer - Grindbot
-- Vendor sell + repair (Grind_Information merchants)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.194.0
-- Folder: Master_Farmer_Grindbot
-- Sell via core.input.use_container_item while a merchant is open.
-- Quality from core.quests.get_item_info. No is_vendor invent.
--
-- LAP VENDORING (1.6.1)
--   The Alliance 1-60 w/Vendoring routes are loops that begin and end at their
--   merchant, and they carry `vendor_each_lap`. For those, a completed lap is
--   a trip trigger in its own right, alongside the usual full-bags and broken
--   -gear ones: the bot is standing at the vendor anyway, so selling there
--   costs nothing and saves a special trip later.
--
--   Those routes give `merchant.ids` - every vendor NPC id the route's README
--   listed - because several of them pass more than one. Any of them will do,
--   so the first one actually standing nearby wins.
--
--   The merchant x/y/z on those routes is the path's FIRST WAYPOINT, not a
--   surveyed vendor position. It is only there to give the bot somewhere to
--   walk back to if a fight dragged it off the route; the npc id is what
--   identifies the merchant.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local gossip = require("gossip")

---@type inventory_helper
local inventory_helper = require("common/utility/inventory_helper")
local bags = require("bags")

---@type vec3
local vec3 = require("common/geometry/vector_3")

local gui = require("gui")
local state = require("state")
local supplies = require("supplies")
local targeting = require("targeting")
local movement = require("movement")
local travel_routes = require("travel_routes")
local rotation = require("rotation")

local vendor = {}

local HEARTHSTONE = 6948
local SELL_GAP = 0.40
local INTERACT_GAP = 1.20
local DONE_COOLDOWN = 90.0
local FULL_RETRY = 60         -- 2.169.0: full bags retry a trip that freed nothing after this
local RETURN_NEAR = 8         -- 2.169.0: yards from the paused quest spot that count as back
local RETURN_MAX = 120        -- 2.169.0: seconds the walk back may take
local BAG_HOLD = 300          -- 2.159.0: seconds a full-bag trip that freed nothing is not repeated
local HERE_COOLDOWN = 60.0    -- a merchant window already worked is left alone this long

-- FULL BAGS, NO KNOWN MERCHANT -> HEARTHSTONE (2.47.0). Zones without merchant
-- data ("No merchant for this zone") left full bags full for good. Hearth to
-- the inn - an innkeeper is a merchant - then find one by talking to the
-- nearest friendly NPCs until a merchant window opens; the merchant-window
-- trip (2.42.0) sells, restocks and repairs from there.
local HEARTH_ID = 6948
local HEARTH_CAST = 12.0      -- seconds held still for the 10 s cast
local FIND_RADIUS = 30
local FIND_MAX = 8            -- NPCs tried before giving up
-- A repair trip (2.49.0) searches wider and longer: an innkeeper is a
-- merchant but cannot repair, so the smiths near the inn have to be reached.
local FIND_RADIUS_REPAIR = 60
local FIND_MAX_REPAIR = 12
local FIND_TIMEOUT = 90.0
local TALK_WAIT = 1.5         -- seconds after an interact before judging it
local ht = nil                -- hearth trip: { stage, t, tried = {}, cur, tries, started, want_repair }
local ht_skip_until = 0       -- stone not ready: do not try to hearth again before this
local ARRIVE = 5.0
local FIND_RANGE = 12.0

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local function merchant_pos(info)
    if type(info) ~= "table" then
        return nil
    end
    if type(info.x) ~= "number" or type(info.y) ~= "number" or type(info.z) ~= "number" then
        return nil
    end
    return vec3.new(info.x, info.y, info.z)
end

--- Every vendor npc id this merchant record offers, best first.
local function merchant_ids(info)
    local out = {}
    if type(info) ~= "table" then
        return out
    end
    if type(info.npc_id) == "number" and info.npc_id > 0 then
        out[#out + 1] = info.npc_id
    end
    if type(info.ids) == "table" then
        for i = 1, #info.ids do
            local id = info.ids[i]
            if type(id) == "number" and id > 0 and id ~= info.npc_id then
                out[#out + 1] = id
            end
        end
    end
    return out
end

--- The merchant belonging to the grind path that is running right now.
--- Takes precedence over the zone table: a path that names its own vendor
--- knows better than the zone default which one it walks past.
-- The running grind profile (grind/engine, only when the grind pack is
-- loaded), else path_runner's path (2.151.0).
local function running_grind()
    local g = package.loaded["grind/engine"]
    if type(g) == "table" and type(g.current_profile) == "function" then
        local p = safe(function() return g.current_profile() end)
        if type(p) == "table" then return g, p end
    end
    return nil, nil
end

local function path_merchant()
    local _, path = running_grind()
    if not path then
        local ok, runner = pcall(require, "path_runner")
        if ok and type(runner) == "table" and type(runner.current_path) == "function" then
            path = safe(function() return runner.current_path() end)
        end
    end
    if type(path) ~= "table" or type(path.merchant) ~= "table" then
        return nil
    end
    return path.merchant, path
end

local function current_merchant(player)
    local from_path = path_merchant()
    if from_path then
        return from_path
    end
    local okz, grind_zones = pcall(require, "grind/zone_lookup")
    if not okz or type(grind_zones) ~= "table" or type(grind_zones.lookup) ~= "function" then
        return nil
    end
    local race_id = safe(function() return player:get_race_id() end)
    local level = safe(function() return player:get_level() end) or 1
    local zone = grind_zones.lookup(race_id, level)
    if type(zone) ~= "table" then
        return nil
    end
    local info = zone.merchant
    if type(info) ~= "table" then
        return nil
    end
    return info
end

local function backpack_free()
    local slots = safe(function() return core.inventory.get_num_bag_slots(1) end) or 16
    if type(slots) ~= "number" or slots < 1 then
        slots = 16
    end
    local items = safe(function() return core.inventory.get_items_in_bag(0) end)
    local used = 0
    if type(items) == "table" then
        used = #items
    end
    local left = slots - used
    if left < 0 then
        return 0
    end
    return left
end

-- FREE SLOTS (2.159.0). inventory_helper's bags 1-4 already include the
-- backpack ("Bag 1 has an internal slot offset"), and backpack_free() read
-- get_items_in_bag(0) - which is the WHOLE player container, worn gear
-- included - against get_num_bag_slots(0), which is always 0 (the slot
-- binding is shifted one: 1 = backpack). Adding the two either added nothing
-- or counted the backpack twice. The helper's number is used alone.
local last_free_logged = nil

-- SPECIAL BAGS DO NOT HOLD LOOT (2.160.0). A hunter's quiver / ammo pouch
-- (item class 11) and a soul bag or other profession bag (container class 1
-- with a subclass) take only their own item type, but their empty slots were
-- counted as free: the 12:07 session read "5 free" with the bags full, and a
-- quest that hands over an item could not be accepted. Their free slots are
-- taken off. The bag objects sit at inventory slots 20-23 (bag 1-4); the
-- name is the fallback where item info is empty (WoW Forever).
local SPECIAL_WORDS = { "quiver", "ammo pouch", "shot pouch", "bandolier", "soul pouch",
    "soul bag", "felcloth bag", "box of souls", "herb", "enchant", "mining sack" }
local special_cache = {}      -- item id -> true / false

-- 2.161.0: item info is empty on this client (the 12:15 count never saw the
-- ammo pouch), so the bag is also known by id, and by what it holds.
-- Quivers, ammo / shot pouches, bandoliers and soul bags (Vanilla + TBC).
local SPECIAL_IDS = {}
for _, id in ipairs({
    2101, 2102, 2662, 2663, 3573, 3574, 3604, 3605, 5439, 5441, 7278, 7279,
    7371, 7372, 8217, 8218, 11362, 11363, 18714, 19319, 19320,
    21340, 21341, 21342, 22243, 22244,
}) do SPECIAL_IDS[id] = true end
-- Arrows and bullets (Vanilla + TBC): a bag holding nothing else is an
-- ammo bag even when its id is not listed.
local AMMO_IDS = {}
for _, id in ipairs({
    2512, 2515, 3030, 3464, 9399, 11285, 12654, 18042, 19316, 24412, 24417,
    28053, 28056, 30319, 31737, 31949, 32760, 33803, 34581,
    2516, 2519, 3033, 3465, 4960, 5568, 8067, 8068, 8069, 10512, 10513,
    11284, 11630, 13377, 15997, 19317, 23772, 23773, 28060, 28061, 30612,
    31735, 32761, 32882, 32883, 34582,
}) do AMMO_IDS[id] = true end

local function holds_only_ammo(bag)
    local items = safe(function() return core.inventory.get_items_in_bag(bag) end)
    if type(items) ~= "table" or #items == 0 then return false end
    for i = 1, #items do
        local e = items[i]
        local id = type(e) == "table" and e.object and safe(function() return e.object:get_item_id() end)
        if not AMMO_IDS[id] then return false end
    end
    return true
end

local function special_bag(bag)
    local me = safe(function() return izi.me() end)
    if not me then return false end
    -- The client's own slot for bag N (20-23 on the private servers, 31-34
    -- on retail), 19 + N when it cannot say.
    local inv = safe(function() return core.inventory.get_bag_inventory_slot(bag) end)
    if type(inv) ~= "number" then inv = 19 + bag end
    local row = safe(function() return me:get_item_at_inventory_slot(inv) end)
    local obj = type(row) == "table" and row.object or nil
    if not obj then return holds_only_ammo(bag) end
    local id = safe(function() return obj:get_item_id() end)
    if type(id) ~= "number" then return holds_only_ammo(bag) end
    if SPECIAL_IDS[id] then return true end
    if special_cache[id] ~= nil then return special_cache[id] or holds_only_ammo(bag) end
    local info = safe(function() return core.quests.get_item_info(id) end)
    local yes = false
    if type(info) == "table" and type(info.class_id) == "number" then
        yes = info.class_id == 11 or (info.class_id == 1 and (info.subclass_id or 0) ~= 0)
    end
    if not yes then
        local name = (type(info) == "table" and info.name) or safe(function() return obj:get_name() end)
        if type(name) == "string" then
            local low = string.lower(name)
            for i = 1, #SPECIAL_WORDS do
                if low:find(SPECIAL_WORDS[i], 1, true) then yes = true break end
            end
        end
    end
    special_cache[id] = yes
    return yes or holds_only_ammo(bag)
end

--- Free slots in special bags (not usable for loot).
local function special_free()
    local total = 0
    for bag = 1, 4 do
        if special_bag(bag) then
            -- get_num_bag_slots is one higher than get_items_in_bag.
            local cap = safe(function() return core.inventory.get_num_bag_slots(bag + 1) end) or 0
            local items = safe(function() return core.inventory.get_items_in_bag(bag) end)
            local used = type(items) == "table" and #items or 0
            if type(cap) == "number" and cap > used then
                total = total + (cap - used)
            end
        end
    end
    return total
end

local function bag_free()
    -- Counted from the filtered bag list (2.184.0): the helper's total also
    -- saw bank storage on this client. Special bags are left out.
    local me = safe(function() return izi.me() end)
    local own = me and bags.free_slots(me, special_bag) or nil
    local helper_free = own or safe(function()
        return inventory_helper:get_total_free_slots()
    end)
    if type(helper_free) == "number" and helper_free >= 0 then
        local sp = own and 0 or special_free()
        helper_free = math.max(0, helper_free - sp)
        if helper_free ~= last_free_logged then
            last_free_logged = helper_free
            local ok_e, el = pcall(require, "errorlog")
            if ok_e and type(el) == "table" and type(el.trail) == "function" then
                local sp_show = own and special_free() or sp
                pcall(el.trail, "vendor", "bags: %d free slot(s)%s", helper_free,
                    sp_show > 0 and string.format(" (%d in ammo / special bags not counted)", sp_show) or "")
            end
        end
        return helper_free
    end
    local free = backpack_free()
    for bag = 1, 4 do
        -- get_num_bag_slots is shifted one higher than get_items_in_bag.
        local slots = safe(function() return core.inventory.get_num_bag_slots(bag + 1) end) or 0
        if type(slots) == "number" and slots > 0 then
            local items = safe(function() return core.inventory.get_items_in_bag(bag) end)
            local used = 0
            if type(items) == "table" then
                used = #items
            end
            local left = slots - used
            if left > 0 then
                free = free + left
            end
        end
    end
    return math.max(0, free - special_free())
end

local function worst_durability()
    local worst = 1
    local broken = false
    for slot = 1, 19 do
        local d = safe(function() return core.inventory.get_item_durability(slot) end)
        if type(d) == "table" then
            local maxd = d.max
            local cur = d.current
            if type(maxd) == "number" and maxd > 0 and type(cur) == "number" then
                local ratio = cur / maxd
                if ratio < worst then
                    worst = ratio
                end
                if cur <= 0 then
                    broken = true
                end
            end
        end
    end
    return worst, broken
end

local function merchant_open()
    local count = safe(function() return core.game_ui.get_vendor_item_count() end) or 0
    if type(count) == "number" and count > 0 then
        return true
    end
    return safe(function() return core.inventory.can_merchant_repair() end) == true
end

local function keep_ids(player)
    local ids = { [HEARTHSTONE] = true }
    local foods = rotation.preferred_food_ids(player)
    if type(foods) == "table" then
        for i = 1, #foods do
            if type(foods[i]) == "number" then
                ids[foods[i]] = true
            end
        end
    end
    local drinks = rotation.preferred_drink_ids(player)
    if type(drinks) == "table" then
        for i = 1, #drinks do
            if type(drinks[i]) == "number" then
                ids[drinks[i]] = true
            end
        end
    end
    return ids
end

local function quality_ok(quality)
    if type(quality) ~= "number" then
        return false
    end
    if quality == 0 then
        return gui.is_on("sell_grey")
    end
    if quality == 1 then
        return gui.is_on("sell_white")
    end
    if quality == 2 then
        return gui.is_on("sell_green")
    end
    return false
end

-- 2.183.0: item ids inventory_helper reports as consumables.
local helper_consumables = {}

local function refresh_consumables()
    helper_consumables = {}
    pcall(function() inventory_helper:update_consumables_list() end)
    local ok, list = pcall(function() return inventory_helper:get_current_consumables_list() end)
    if ok and type(list) == "table" then
        for i = 1, #list do
            local c = list[i]
            local it = type(c) == "table" and c.item or nil
            local id = it and safe(function() return it:get_item_id() end)
            if type(id) == "number" then helper_consumables[id] = true end
        end
    end
end

local function should_sell_item(player, item_id)
    if type(item_id) ~= "number" or item_id <= 0 then
        return false
    end
    local keep = keep_ids(player)
    if keep[item_id] then
        return false
    end
    -- NEVER SELL WHAT THE BOT LIVES ON (2.182.0). The 10:10 session "sold"
    -- the bread and water it had just bought (white items under Sell white).
    -- Food, drink, every consumable, ammo and quest items stay.
    local food, water = bags.food_water(player)
    if (food and food[item_id]) or (water and water[item_id]) then
        return false
    end
    -- The inventory helper's consumables list (2.183.0): food, drink and
    -- potions it recognises are kept too. Refreshed when a trip starts.
    if helper_consumables[item_id] then
        return false
    end
    local info = safe(function() return core.quests.get_item_info(item_id) end)
    if type(info) ~= "table" then
        return false
    end
    -- 0 consumable, 6 projectile, 11 quiver / ammo pouch, 12 quest
    if info.class_id == 0 or info.class_id == 6 or info.class_id == 11 or info.class_id == 12 then
        return false
    end
    local price = info.sell_price
    if type(price) == "number" and price <= 0 then
        return false
    end
    return quality_ok(info.quality)
end

--- Sell the first sellable bag item.
---
--- Through bags.lua (2.34.0): the raw get_items_in_bag slot_id is off by one
--- from what use_container_item takes, so this used to sell the item NEXT to
--- each grey or white. bags.list hands out inventory_helper's (bag, slot).
-- SELL VERIFICATION (2.66.0). A sale that did not happen - the item still
-- in the same bag slot on the next pass - was sent again forever: the log
-- showed "Sold 7073" 79 times at one merchant while the item never left the
-- bag. Every sale is now checked; a slot whose item stays put after
-- SELL_RETRIES attempts is skipped for the rest of the trip (with a log
-- line naming bag and slot), and the trip moves on to restock and repair.
local SELL_RETRIES = 2
local sell_pending = nil        -- { item_id, count } of the last sale sent
local sell_fails = {}           -- item id -> failed attempts this trip

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "vendor", fmt, ...)
    end
end

-- ============================================================================
-- SELLING THROUGH THE INVENTORY HELPER (2.183.0)
-- ============================================================================
-- The inventory helper's documentation is explicit: slot_data.bag_id +
-- slot_data.bag_slot from inventory_helper:get_character_bag_slots() are the
-- pair core.input.use_container_item takes. Selling is exactly that, with
-- the pair and the item id read from the helper in the same tick.
--
-- What went wrong before: 2.166 confirmed a sale with core.inventory counts
-- (bags.count, the raw engine container) but compared the bag total from the
-- helper. The two sources disagree, which raised a false "removed a
-- different item" (10:10 log); that switched selling to core.input.use_item,
-- which USES items - it ate the bread and drank the water. 2.182 then
-- required the cursor name to match, which never matched, so nothing sold.
-- Now every count comes from the helper, there is no use_item path, and a
-- sale that really takes another item stops selling for the session.

--- Stack total of `item_id` in the character bags, from the helper.
local function helper_count(player, item_id)
    local total = 0
    local list = bags.list(player)
    for i = 1, #list do
        local e = list[i]
        if e.item_id == item_id then
            total = total + ((type(e.count) == "number" and e.count > 0) and e.count or 1)
        end
    end
    return total, #list
end

local selling_off = false
local surprise = 0              -- 2.186.0: sales this trip that emptied another slot too

--- Did the last sale land? Its stack total must have gone down (helper).
local function check_last_sale(player)
    local p = sell_pending
    if not p then
        return
    end
    sell_pending = nil
    local now_count, slots = helper_count(player, p.item_id)
    if now_count < p.count then
        sell_fails[p.item_id] = nil
        return
    end
    -- The target is all still there but a slot emptied (2.186.0): an auto-sell
    -- addon emptying grey items at the same moment does exactly this - the
    -- 11:00 log went from 3 to 12 free slots in one second on one sale. Not
    -- proof of a wrong item, so selling carries on; the item is skipped for
    -- the trip, and three such surprises in one trip stop selling.
    if type(p.slots) == "number" and slots < p.slots then
        surprise = surprise + 1
        sell_fails[p.item_id] = SELL_RETRIES
        trail("sale at bag %s slot %s: another slot emptied too (%d this trip)%s",
            tostring(p.bag), tostring(p.slot), surprise, surprise >= 3 and " - selling stopped" or "")
        if surprise >= 3 then
            selling_off = true
            core.log_warning("[Master Farmer - Grindbot] Vendor sales keep emptying other slots - "
                .. "selling is off for this session.")
        end
        return
    end
    sell_fails[p.item_id] = (sell_fails[p.item_id] or 0) + 1
    if sell_fails[p.item_id] >= SELL_RETRIES then
        trail("could not sell item %s (%d in bags) - skipped for this trip", tostring(p.item_id), now_count)
    end
end

--- Sell one sellable bag item: use_container_item(bag_id, bag_slot) at the
--- helper's pair for that exact slot.
local function sell_one(player)
    check_last_sale(player)
    if selling_off then
        return false
    end
    local list = bags.list(player)
    local seen = {}
    for i = 1, #list do
        local e = list[i]
        local id = e.item_id
        if id and not seen[id] and type(e.bag) == "number" and type(e.slot) == "number" then
            seen[id] = true
            if (sell_fails[id] or 0) < SELL_RETRIES and should_sell_item(player, id) then
                local before = helper_count(player, id)
                if before > 0 then
                    pcall(function() core.input.use_container_item(e.bag, e.slot) end)
                    sell_pending = { item_id = id, count = before, slots = #list, bag = e.bag, slot = e.slot }
                    trail("sell item %s (%d in bags) at bag %d slot %d", tostring(id), before, e.bag, e.slot)
                    return true, id
                end
            end
        end
    end
    return false
end

local function gossip_open()
    return gossip.is_open()
end


-- The vendor option (gossip.lua, 2.144.0). This read gossip_option_id from
-- izi's option view - a field a view does not have - so izi's VENDOR icon
-- match was always discarded and only a raw gossip_type of "vendor" could
-- open an innkeeper's or merchant's goods.
local VENDOR_WORDS = { "browse your goods", "let me browse", "your wares" }

local function select_vendor_gossip()
    return (gossip.select({ icon = "VENDOR", icon_num = 1, type = "vendor", words = VENDOR_WORDS }))
end

local function close_vendor()
    -- The merchant window too (2.166.0): left open, it was taken as a new
    -- "trip right here" every 60 s while the bot stood by the vendor.
    pcall(function() core.input.close_merchant() end)
    if izi.gossip and type(izi.gossip.close) == "function" then
        pcall(function()
            izi.gossip.close()
        end)
    end
    pcall(function()
        core.quests.close_gossip()
    end)
end

local REPAIR_TRIES = 3

local function finish_trip(note)
    -- A food / water run is over whatever happened (2.139.0); if nothing was
    -- bought the rest asks again, and a run that could not pay is held until
    -- the gold goes up (supplies.lua).
    if state.vendor.reason == "supplies" then
        supplies.trip_done(0)
    end
    if state.vendor.reason == "bags" then
        local free = bag_free()
        if free <= gui.slider("bag_free", 1) then
            state.vendor.bag_hold_free = free
            state.vendor.bag_hold_until = izi.now() + BAG_HOLD
            state.vendor.bag_hold_set = izi.now()
            trail("bags still at %d free slot(s) after the trip - not going back until that changes", free)
        else
            state.vendor.bag_hold_free = nil
        end
    end
    trail("vendor trip done: %s - back to the %s", tostring(note),
        gui.is_on("use_quest") and "quest step" or "route")
    if state.vendor.return_pos and gui.is_on("use_quest") then
        state.vendor.returning = true
        state.vendor.return_since = izi.now()
    end
    state.vendor.reason = nil
    state.vendor.inn = nil
    state.vendor.idle_since = 0
    state.vendor.repair_tries = 0
    sell_pending = nil
    sell_fails = {}
    surprise = 0
    state.vendor.supplier_guid = nil
    state.vendor.supplier_name = nil
    state.vendor.supplier_skip = nil
    state.vendor.window_seen = false
    -- However this trip ended - sold, repaired, merchant missing, out of gold -
    -- the lap that asked for it is dealt with. Leaving the flag set would make
    -- the bot turn round and try again immediately.
    state.vendor.lap_due = false
    state.vendor.active = false
    state.vendor.repaired = false
    state.vendor.sold = 0
    state.vendor.interact_until = 0
    state.vendor.done_until = izi.now() + DONE_COOLDOWN
    state.vendor.wait_npc = 0
    state.vendor.tries = 0
    -- A merchant window still open is not worked again for HERE_COOLDOWN.
    state.vendor.here_until = izi.now() + HERE_COOLDOWN
    movement.nav_stop()
    if type(movement.keep_path) == "function" then
        movement.keep_path(false)
    end
    close_vendor()
    -- Let go of the merchant (2.42.0): the trip targeted it with kind
    -- "vendor" and nothing ever cleared it, so the character kept the NPC.
    if state.target and state.target.kind == "vendor" then
        state.reset_target()
    end
    if note then
        state.set_note("Vendor", note)
    end
end

local vend_aim_x, vend_aim_y = nil, nil

--- Walk `dest`. When it is an inn or flight master on a recorded road, and
--- the player is on that road or the straight line crosses it, follow the
--- road. A running walk is retargeted, not stopped.
local function nav_place(player, dest, direct)
    local here = safe(function() return player:get_position() end)
    local hop = here and travel_routes.hop(here, dest) or nil
    local target = hop or dest
    if hop and type(movement.keep_path) == "function" then
        movement.keep_path(true)
    end
    if hop and movement.is_moving() and type(movement.nudge) == "function" then
        local tx, ty = math.floor(target.x), math.floor(target.y)
        if tx ~= vend_aim_x or ty ~= vend_aim_y then
            vend_aim_x, vend_aim_y = tx, ty
            movement.nudge(target)
        end
        return true
    end
    return movement.nav_to(target, direct) == true
end

--- Is a vendor trip under way? The quest engine waits on it before it counts
--- a ".vendor" step as done.
function vendor.is_busy()
    return state.vendor.active == true or ht ~= nil
end

--- Is a merchant window open right now?
function vendor.merchant_open()
    return merchant_open()
end

function vendor.reset()
    ht = nil
    state.vendor.returning, state.vendor.return_pos = false, nil
    state.vendor.active = false
    state.vendor.repaired = false
    state.vendor.sold = 0
    state.vendor.interact_until = 0
    state.vendor.done_until = 0
    state.vendor.lack_gold = 0
    state.vendor.wait_npc = 0
    state.vendor.tries = 0
    -- A lap queued a trip that is now moot: the bot has been stopped, switched
    -- to rotation only, or moved to another path. Leaving it set would send it
    -- to a merchant the new path knows nothing about.
    state.vendor.lap_due = false
end

--- Did the running path just finish a lap that should end at the vendor?
---
--- The lap is consumed whether or not the trip goes ahead, so a route whose
--- vendor cannot be reached does not queue a trip for every lap it runs.
local function lap_wants_vendor()
    local info, path = path_merchant()
    if not info or not path or path.vendor_each_lap ~= true then
        return false
    end
    if #merchant_ids(info) == 0 then
        return false
    end
    local g = running_grind()
    if g and type(g.take_lap) == "function" then
        return safe(function() return g.take_lap() end) == true
    end
    local ok, runner = pcall(require, "path_runner")
    if not ok or type(runner) ~= "table" or type(runner.take_lap) ~= "function" then
        return false
    end
    return safe(function() return runner.take_lap() end) == true
end

--- Anything in the bags this vendor trip would sell? (2.139.0; cached 5 s.)
local junk_cache = { t = -1e9, v = false }
function vendor.has_junk(player)
    local now = izi.now()
    if (now - junk_cache.t) < 5 then return junk_cache.v end
    junk_cache.t = now
    junk_cache.v = false
    if not gui.is_on("sell") then return false end
    local list = bags.list(player)
    for i = 1, #list do
        local id = list[i].item_id
        if id and should_sell_item(player, id) then
            junk_cache.v = true
            break
        end
    end
    return junk_cache.v
end

--- Copper the next trip would raise by selling junk (2.171.0). A water run
--- uses this plus the gold on hand: the trip sells before it buys.
local junk_copper_cache = { t = -1e9, v = 0 }
function vendor.junk_copper(player)
    local now = izi.now()
    if (now - junk_copper_cache.t) < 5 then return junk_copper_cache.v end
    junk_copper_cache.t = now
    local total = 0
    if player and gui.is_on("sell") then
        local list = bags.list(player)
        for i = 1, #list do
            local id = list[i].item_id
            if id and should_sell_item(player, id) then
                local info = safe(function() return core.quests.get_item_info(id) end)
                local price = type(info) == "table" and info.sell_price or nil
                local n = list[i].count
                if type(n) ~= "number" or n < 1 then n = 1 end
                if type(price) == "number" and price > 0 then
                    total = total + price * n
                end
            end
        end
    end
    junk_copper_cache.v = total
    return total
end

-- VENDOR FIRST, THEN THE QUEST (2.160.0). A quest that hands over an item
-- cannot be accepted with full bags; RestedXP keeps the bot at the giver and
-- the free-slot count can be wrong (special bags). quest/npc.lua reports an
-- accept that was clicked but never landed, or an "inventory is full" error,
-- and asks for a trip here; it runs before the quest step gets the tick back.
local FORCE_TTL = 120
local FORCE_AGAIN = 600
local forced = nil            -- { why, at }
local forced_last = {}        -- why -> time last requested

--- Ask for a sell trip now, whatever the free-slot count says. Returns true
--- when one will run (selling on, level 2+, not asked for the same reason
--- in the last FORCE_AGAIN seconds).
function vendor.request_bag_trip(why, player)
    if not gui.is_on("sell") then return false end
    -- Only at or below the Vendor at Free Slots slider (2.166.0).
    if bag_free() > gui.slider("bag_free", 1) then return false end
    player = player or safe(function() return izi.me() end)
    if player and not vendor.level_ok(player) then return false end
    local now = izi.now()
    why = tostring(why or "bags full")
    if forced_last[why] and (now - forced_last[why]) < FORCE_AGAIN then return false end
    forced_last[why] = now
    forced = { why = why, at = now }
    state.vendor.bag_hold_free = nil
    trail("sell trip requested: %s", why)
    return true
end

function vendor.needs_trip(player)
    if not player then
        return false
    end
    if forced and not state.vendor.active then
        if (izi.now() - forced.at) <= FORCE_TTL then
            state.vendor.reason = "bags"
            forced = nil
            return true
        end
        forced = nil
    end
    -- No free slot at all (ammo and profession bags are not counted). A quest
    -- cannot hand over an item, and loot has nowhere to go, so the trip
    -- starts whether or not Sell is ticked. A trip that just freed nothing
    -- waits FULL_RETRY, then goes again.
    if bag_free() == 0 then
        local since = izi.now() - (state.vendor.bag_hold_set or 0)
        local held = state.vendor.bag_hold_free == 0
            and izi.now() < (state.vendor.bag_hold_until or 0)
            and since < FULL_RETRY
        if not held then
            state.vendor.reason = "bags"
            state.vendor.bag_hold_free = nil
            return true
        end
    end
    if not gui.is_on("sell") and not gui.is_on("repair") and not gui.is_on("buy_supplies") then
        return false
    end
    -- OUT OF FOOD / WATER (2.139.0): a rest found nothing to eat or drink and
    -- a run can pay for it (supplies.trip_wanted).
    if supplies.trip_wanted(player) then
        state.vendor.reason = "supplies"
        return true
    end
    if not gui.is_on("sell") and not gui.is_on("repair") then
        return false
    end

    -- A completed lap on a vendoring route is a trigger by itself. Checked
    -- before the cooldown below, because the lap must be consumed on the tick
    -- it happens or it is lost.
    if gui.is_on("vendor_each_lap") and lap_wants_vendor() then
        state.vendor.lap_due = true
    end
    if state.vendor.lap_due == true then
        return true
    end
    -- FULL IS FULL (2.161.0): with no free slot at all (special bags not
    -- counted) the trip is forced - the after-trip cooldown does not apply,
    -- only the "that trip freed nothing" hold does.
    local full_now = gui.is_on("sell") and bag_free() == 0
    if izi.now() < (state.vendor.done_until or 0) and not state.vendor.active and not full_now then
        return false
    end
    if gui.is_on("sell") then
        local need_slots = gui.slider("bag_free", 1)
        local free = bag_free()
        -- A trip that sold nothing left the bags as full as before: wait for
        -- the count to change (or BAG_HOLD) instead of walking back at once.
        local held = state.vendor.bag_hold_free ~= nil and free == state.vendor.bag_hold_free
            and izi.now() < (state.vendor.bag_hold_until or 0)
        -- ALWAYS WHEN FULL (2.169.0): no free slot at all (special bags not
        -- counted) always goes; only FULL_RETRY after a trip that freed
        -- nothing keeps it from turning straight round.
        if held and free == 0 and (izi.now() - (state.vendor.bag_hold_set or 0)) >= FULL_RETRY then
            held = false
        end
        if free <= need_slots and not held then
            state.vendor.reason = "bags"
            return true
        end
    end
    if gui.is_on("repair") then
        local lack = state.vendor.lack_gold or 0
        local can_pay = true
        if lack > 0 then
            local gold = safe(function() return core.inventory.get_gold() end) or 0
            if type(gold) == "number" and gold >= lack then
                state.vendor.lack_gold = 0
            else
                can_pay = false
            end
        end
        if can_pay then
            local ratio, broken = worst_durability()
            local pct = gui.slider("repair_pct", 10) / 100
            if broken or ratio <= pct then
                return true
            end
        end
    end
    return false
end

--- Friendly NPCs near the player, nearest first, not yet tried.
local function friendly_npcs(player, tried, radius)
    radius = radius or FIND_RADIUS
    local list = targeting.visible_objects and targeting.visible_objects() or nil
    local out = {}
    if type(list) ~= "table" then
        return out
    end
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_unit() end) == true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return u:is_dead_or_ghost() end) ~= true
            and safe(function() return player:can_attack(u) end) == false then
            local g = safe(function() return u:get_guid() end)
            local d = safe(function() return player:distance_to(u) end)
            if g and not tried[g] and type(d) == "number" and d <= radius then
                out[#out + 1] = { unit = u, guid = g, d = d }
            end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

local function hearth_ready()
    local item = safe(function() return izi.item(HEARTH_ID) end)
    return item
        and safe(function() return item:in_inventory() end) == true
        and safe(function() return item:cooldown_up() end) ~= false
end

local function hearth_tick(player)
    local now = izi.now()
    if ht.stage == "cast" then
        local item = safe(function() return izi.item(HEARTH_ID) end)
        local ready = item and safe(function() return item:in_inventory() end) == true
            and safe(function() return item:cooldown_up() end) ~= false
        if not ready then
            if ht.want_repair then
                -- The stone is not ready: walk to the zone merchant instead,
                -- if this zone has one (the normal trip below).
                core.log_warning("[Master Farmer - Grindbot] Gear needs repair but the Hearthstone is not ready - walking to a merchant if one is known.")
                ht = nil
                ht_skip_until = now + 120
                return false
            end
            core.log_warning("[Master Farmer - Grindbot] Bags full, no merchant known here, and the Hearthstone is not ready - carrying on.")
            ht = nil
            state.vendor.done_until = now + 60
            return false
        end
        movement.nav_stop()
        local ok = safe(function() return item:use_self("Hearthstone - bags full") end) == true
        local why = ht.want_repair and "gear needs repair" or "bags full and no merchant known here"
        core.log("[Master Farmer - Grindbot] " .. why .. " - Hearthstone to the inn.")
        ht.stage, ht.t = "casting", now
        state.set_note("Vendor", ok and ("Hearthstone - " .. why) or "Hearthstone refused")
        return true
    end
    if ht.stage == "casting" then
        movement.nav_stop()
        if (now - ht.t) < HEARTH_CAST then
            state.set_note("Vendor", "Hearthstone - bags full")
            return true
        end
        ht.stage, ht.started = "find", now
        return true
    end
    -- find: talk to the nearest friendly NPCs until a merchant window opens -
    -- for a repair trip, one that can repair.
    local max_tries = ht.want_repair and FIND_MAX_REPAIR or FIND_MAX
    if merchant_open() then
        local can_fix = safe(function() return core.inventory.can_merchant_repair() end) == true
        if not ht.want_repair or can_fix then
            ht = nil           -- the merchant-window trip takes over below
            return false
        end
        -- A merchant that cannot repair (an innkeeper): not this one.
        if ht.cur then
            ht.tried[ht.cur] = true
            ht.cur = nil
        end
        close_vendor()
    end
    if (now - (ht.started or now)) > FIND_TIMEOUT or (ht.tries or 0) >= max_tries then
        core.log_warning("[Master Farmer - Grindbot] Hearthed with full bags but found no merchant nearby.")
        ht = nil
        state.vendor.done_until = now + DONE_COOLDOWN
        return false
    end
    if ht.cur and (now - ht.t) < TALK_WAIT then
        if gossip_open() then
            if not select_vendor_gossip() then
                close_vendor()
                ht.cur = nil
            end
        end
        state.set_note("Vendor", "Looking for a merchant")
        return true
    end
    if ht.cur then
        ht.tried[ht.cur] = true    -- talked to, no merchant window
        ht.cur = nil
        close_vendor()
    end
    local npcs = friendly_npcs(player, ht.tried, ht.want_repair and FIND_RADIUS_REPAIR or FIND_RADIUS)
    local n = npcs[1]
    if not n then
        ht.tries = max_tries
        return true
    end
    if n.d > 4 then
        local p = safe(function() return n.unit:get_position() end)
        if p and not movement.is_moving() then
            nav_place(player, p, true)
        end
        state.set_note("Vendor", "Looking for a merchant")
        return true
    end
    movement.nav_stop()
    ht.cur, ht.t, ht.tries = n.guid, now, (ht.tries or 0) + 1
    pcall(function() core.input.interact_with_object(n.unit) end)
    state.set_note("Vendor", "Looking for a merchant")
    return true
end

-- ----------------------------------------------------------------------------
-- IDLE AT THE VENDOR (2.86.0)
-- ----------------------------------------------------------------------------
-- At a merchant - its window open, or standing next to it trying to open it -
-- with nothing sold, bought or repaired for IDLE_LIMIT seconds, the trip is
-- over and grinding / questing carries on. Walking to a merchant is not idle.
local IDLE_LIMIT = 15

--- Something was done at the merchant: the idle clock restarts.
local function vendor_progress(now)
    state.vendor.idle_since = now
end

--- At the merchant this tick. True when the idle limit ended the trip.
local function idle_check(now)
    local since = state.vendor.idle_since
    if type(since) ~= "number" or since <= 0 then
        state.vendor.idle_since = now
        return false
    end
    if (now - since) >= IDLE_LIMIT then
        trail("idle at the vendor for %ds - moving on", IDLE_LIMIT)
        finish_trip("Idle at the vendor - moving on")
        return true
    end
    return false
end

-- ----------------------------------------------------------------------------
-- FOOD / WATER SELLER (2.73.0)
-- ----------------------------------------------------------------------------
local SUPPLIER_RANGE = 80

local function supplier_unit(player)
    local want = state.vendor.supplier_guid
    local ok_t, list = pcall(function() return targeting.visible_objects() end)
    if not ok_t or type(list) ~= "table" then
        return nil
    end
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:get_guid() end) == want then
            return u
        end
    end
    return nil
end

-- THE CLOSEST VENDOR (2.159.0). Quest mode has no route merchant, and the
-- zone merchant table covers few zones, so a full-bag trip often ended at
-- "No merchant for this zone". Any NPC the game flags as a vendor (npc flag
-- 0x80; 0x1000 repairs) in sight is used first - one that repairs when the
-- gear needs it - then the zone merchant, then the nearest inn.
local NPC_VENDOR, NPC_REPAIR = 0x80, 0x1000
local VENDOR_SIGHT = 100

local function has_flag(v, bit)
    return type(v) == "number" and v > 0 and math.floor(v / bit) % 2 == 1
end

local function vendor_in_sight(player, want_repair)
    local ok_t, list = pcall(function() return targeting.visible_objects() end)
    if not ok_t or type(list) ~= "table" then return nil end
    local best, best_d, best_rank = nil, nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_unit() end) == true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return u:is_dead_or_ghost() end) ~= true
            and safe(function() return player:can_attack(u) end) ~= true then
            local flags = safe(function() return u:get_npc_flags() end)
            if has_flag(flags, NPC_VENDOR) or has_flag(flags, NPC_REPAIR) then
                local d = safe(function() return player:distance_to(u) end)
                -- A repairer ranks first only when the gear needs it.
                local rank = (want_repair and has_flag(flags, NPC_REPAIR)) and 1 or 2
                if type(d) == "number" and d <= VENDOR_SIGHT
                    and (best_rank == nil or rank < best_rank or (rank == best_rank and d < best_d)) then
                    best, best_d, best_rank = u, d, rank
                end
            end
        end
    end
    return best, best_d
end

local function supplier_tick(player)
    local unit = supplier_unit(player)
    if not unit then
        finish_trip(state.vendor.reason == "supplies" and "Food / water seller not found" or "Vendor not found")
        return false
    end
    local now = izi.now()
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > 5 then
        local p = safe(function() return unit:get_position() end)
        if not p or not nav_place(player, p) then
            return false
        end
        state.set_note("Vendor", "Travel to " .. tostring(state.vendor.supplier_name))
        state.vendor.idle_since = 0
        return true
    end
    movement.nav_stop()
    if idle_check(now) then
        return false
    end
    if now < (state.vendor.interact_until or 0) then
        return true
    end
    state.vendor.tries = (state.vendor.tries or 0) + 1
    if state.vendor.tries > 8 then
        finish_trip("Food / water seller did not open")
        return false
    end
    state.vendor.interact_until = now + INTERACT_GAP
    targeting.set_current(unit, "vendor")
    pcall(function() core.input.interact_with_object(unit) end)
    if gossip_open() then
        if not select_vendor_gossip() then
            close_vendor()
            state.set_note("Vendor", "No vendor gossip")
        end
    end
    state.set_note("Vendor", "Interact " .. tostring(state.vendor.supplier_name))
    return true
end

-- NO VENDORING BELOW LEVEL 2 (2.149.0): a fresh character has nothing worth
-- selling and cannot afford food; the trips (and a quest ".vendor" step)
-- only cost it time.
local MIN_VENDOR_LEVEL = 2

--- May vendoring run at this level?
function vendor.level_ok(player)
    local lvl = safe(function() return player:get_level() end)
    return type(lvl) ~= "number" or lvl >= MIN_VENDOR_LEVEL
end

-- A merchant window that is simply open (2.166.0) is worked only when a trip
-- would be wanted anyway - free slots at or below the slider, gear due for
-- repair, or food / water asked for - or when the quest step is the one that
-- opened it (a RestedXP ".vendor" talk goal). Otherwise it is left alone.
local function window_trip_wanted(player)
    if gui.is_on("sell") and bag_free() <= gui.slider("bag_free", 1) then return true end
    if gui.is_on("repair") then
        local ratio, broken = worst_durability()
        if broken or ratio <= gui.slider("repair_pct", 10) / 100 then return true end
    end
    if supplies.trip_wanted(player) then return true end
    local q = package.loaded["quest/engine"]
    if type(q) == "table" and type(q.current_kind) == "function" and q.current_kind() == "talk"
        and gui.is_on("use_quest") then
        return true
    end
    return false
end

function vendor.tick(player)
    if not player then
        return false
    end
    if not vendor.level_ok(player) and bag_free() > 0 then
        if state.vendor.active then
            vendor.reset()
        end
        return false
    end
    if ht then
        local in_combat_h = safe(function() return player:is_in_combat() end) == true
        if not in_combat_h and hearth_tick(player) then
            return true
        end
    end
    if bag_free() > 0 and not gui.is_on("sell") and not gui.is_on("repair") and not gui.is_on("buy_supplies") then
        if state.vendor.active then
            vendor.reset()
        end
        return false
    end

    -- BACK TO THE QUEST SPOT (2.169.0). A trip that finished while questing
    -- walks back to where it paused the step; a fight on the way comes first
    -- (the cascade's combat runs before this), then the walk carries on.
    if state.vendor.returning and not state.vendor.active then
        local rp = state.vendor.return_pos
        local here = safe(function() return player:get_position() end)
        local d = (rp and here) and math.sqrt((here.x - rp.x) ^ 2 + (here.y - rp.y) ^ 2) or 0
        if not rp or d <= RETURN_NEAR or (izi.now() - (state.vendor.return_since or 0)) > RETURN_MAX
            or not gui.is_on("use_quest") then
            trail("back at the quest spot (%.0f yd) - resuming the quest step", d)
            state.vendor.returning, state.vendor.return_pos = false, nil
            movement.nav_stop()
            return false
        end
        if safe(function() return player:is_in_combat() end) == true then
            return false
        end
        if nav_place(player, rp) then
            state.set_note("Vendor", string.format("Back to the quest spot  %.0fy", d))
            return true
        end
        return false
    end

    local in_combat = safe(function() return player:is_in_combat() end) == true
    if in_combat and not merchant_open() then
        return false
    end

    -- A merchant window someone else opened - a quest ".vendor" step, or the
    -- player - is a trip right here (2.42.0): sell, restock and repair while
    -- it is open. It used to be ignored unless this module had started the
    -- trip itself, and then bailed with "No merchant for this zone".
    if not state.vendor.active and merchant_open() and izi.now() >= (state.vendor.here_until or 0)
        and window_trip_wanted(player) then
        state.vendor.active = true
        supplies.reset()
        state.vendor.repaired = false
        state.vendor.sold = 0
        state.vendor.wait_npc = 0
        state.vendor.tries = 0
    end

    if not state.vendor.active then
        if not vendor.needs_trip(player) then
            return false
        end
        -- PAUSE THE QUEST STEP HERE (2.169.0): the trip walks back to this
        -- spot before RestedXP gets the tick again.
        if gui.is_on("use_quest") then
            local here = safe(function() return player:get_position() end)
            if here then
                state.vendor.return_pos = { x = here.x, y = here.y, z = here.z }
                trail("quest paused at (%.0f, %.0f) for the vendor trip", here.x, here.y)
            end
        end
        -- FOOD / WATER RUN (2.139.0): the nearest inn, or an innkeeper in sight.
        if state.vendor.reason == "supplies" then
            state.vendor.active = true
            supplies.reset()
            state.vendor.repaired = false
            state.vendor.sold = 0
            state.vendor.wait_npc = 0
            state.vendor.tries = 0
            local seller = supplies.find_supplier(player, SUPPLIER_RANGE, nil)
            if seller then
                state.vendor.supplier_guid = safe(function() return seller:get_guid() end)
                state.vendor.supplier_name = safe(function() return seller:get_name() end)
                trail("supply run: %s in sight", tostring(state.vendor.supplier_name))
            else
                local inn, d = supplies.nearest_inn(player)
                state.vendor.inn = inn
                trail("supply run: nearest inn %.0f yd away", d or -1)
            end
            state.set_note("Vendor", "Out of food / water - going to buy")
        end
        -- NEAREST VENDOR IN SIGHT (2.159.0): any trip that is not a food /
        -- water run goes to the closest flagged vendor first.
        if not state.vendor.active then
            local ratio_r, broken_r = worst_durability()
            local want_repair = gui.is_on("repair")
                and (broken_r or ratio_r <= gui.slider("repair_pct", 10) / 100)
            local v, vd = vendor_in_sight(player, want_repair)
            if v then
                state.vendor.active = true
                supplies.reset()
                state.vendor.repaired = false
                state.vendor.sold = 0
                state.vendor.wait_npc = 0
                state.vendor.tries = 0
                state.vendor.supplier_guid = safe(function() return v:get_guid() end)
                state.vendor.supplier_name = safe(function() return v:get_name() end)
                trail("vendor run (%s): %s %.0f yd away, %d free slot(s)", tostring(state.vendor.reason or "repair"),
                    tostring(state.vendor.supplier_name), vd or -1, bag_free())
                state.set_note("Vendor", "Going to " .. tostring(state.vendor.supplier_name))
                return supplier_tick(player)
            end
        end
        -- LOW DURABILITY -> HEARTHSTONE AND REPAIR (2.49.0). Out of combat,
        -- stop questing and hearth to the inn to find a merchant that can
        -- repair - even when a zone merchant is known. A stone not ready
        -- falls through to walking to the zone merchant below.
        if gui.is_on("repair") and izi.now() >= ht_skip_until then
            local ratio, broken = worst_durability()
            if broken or ratio <= gui.slider("repair_pct", 10) / 100 then
                ht = { stage = "cast", t = izi.now(), tried = {}, tries = 0, want_repair = true }
                return hearth_tick(player)
            end
        end
        local info = current_merchant(player)
        if not info or not merchant_pos(info) then
            -- No merchant data here. Full bags cannot wait for one: hearth
            -- when the stone is ready, otherwise walk to the nearest inn.
            -- A stone on cooldown used to return here every tick and the
            -- walk never started.
            local free = bag_free()
            local bags_need = free == 0 or (gui.is_on("sell") and free <= gui.slider("bag_free", 1))
            if bags_need and hearth_ready() then
                ht = { stage = "cast", t = izi.now(), tried = {}, tries = 0 }
                return hearth_tick(player)
            end
            -- The nearest inn (2.159.0): innkeepers buy and sell.
            local inn, ind = supplies.nearest_inn(player)
            if inn then
                state.vendor.active = true
                supplies.reset()
                state.vendor.repaired = false
                state.vendor.sold = 0
                state.vendor.wait_npc = 0
                state.vendor.tries = 0
                state.vendor.inn = inn
                trail("vendor run (%s): no vendor in sight - nearest inn %.0f yd away",
                    tostring(state.vendor.reason or "repair"), ind or -1)
                state.set_note("Vendor", "Going to the inn to sell")
                return true
            end
            state.set_note("Vendor", "No merchant for this zone")
            state.vendor.done_until = izi.now() + 30
            return false
        end
        state.vendor.active = true
        supplies.reset()
        state.vendor.repaired = false
        state.vendor.sold = 0
        state.vendor.wait_npc = 0
        state.vendor.tries = 0
    end

    if merchant_open() then
        movement.nav_stop()
        state.vendor.tries = 0
        local now = izi.now()
        if not state.vendor.window_seen then
            state.vendor.window_seen = true
            refresh_consumables()
            supplies.new_merchant()
            trail("merchant window open (%d items, repair %s)",
                safe(function() return core.game_ui.get_vendor_item_count() end) or 0,
                tostring(safe(function() return core.inventory.can_merchant_repair() end) == true))
        end
        if idle_check(now) then
            return false
        end
        if now < (state.vendor.interact_until or 0) then
            state.set_note("Vendor", "Selling")
            return true
        end
        if gui.is_on("sell") or bag_free() == 0 then
            local sold, item_id = sell_one(player)
            if sold then
                state.vendor.sold = (state.vendor.sold or 0) + 1
                vendor_progress(now)
                state.vendor.interact_until = now + SELL_GAP
                state.set_note("Vendor", "Sold " .. tostring(item_id))
                return true
            end
        end
        -- Restock before repair: repair drains gold, and arriving with no food
        -- is what forces the next trip. Buying first spends what is left over
        -- after selling instead of after repairing.
        if supplies.tick(player) then
            vendor_progress(now)
            return true
        end

        -- REPAIR, VERIFIED (2.73.0). It used to fire repair_all_items once and
        -- call the trip repaired whatever happened. Now the cost is read again
        -- on the next pass: still owing means the repair did not land, and it
        -- is sent again, up to REPAIR_TRIES. Every step is a vendor: trail line.
        if gui.is_on("repair") and not state.vendor.repaired then
            local can = safe(function() return core.inventory.can_merchant_repair() end) == true
            local cost = safe(function() return core.inventory.get_total_repair_cost() end) or 0
            local gold = safe(function() return core.inventory.get_gold() end) or 0
            local tries = state.vendor.repair_tries or 0
            if not can then
                trail("this merchant cannot repair")
                state.vendor.repaired = true
            elseif type(cost) ~= "number" or cost <= 0 then
                if tries > 0 then
                    trail("repaired")
                end
                state.vendor.repaired = true
            elseif type(gold) == "number" and cost > gold then
                state.vendor.lack_gold = cost
                trail("repair costs %d copper, only %d on hand", cost, gold)
                state.set_note("Vendor", "Need more gold to repair")
                state.vendor.repaired = true
            elseif tries >= REPAIR_TRIES then
                trail("repair refused %d times (still %d copper owed) - leaving it", tries, cost)
                state.vendor.repaired = true
            else
                state.vendor.repair_tries = tries + 1
                trail("repair all: %d copper (attempt %d)", cost, tries + 1)
                pcall(function()
                    core.input.repair_all_items(false)
                end)
                vendor_progress(now)
                state.set_note("Vendor", "Repair")
            end
            state.vendor.interact_until = now + 0.60
            return true
        end
        -- FOOD AND WATER ELSEWHERE (2.73.0). The zone merchant (an armorer /
        -- weaponsmith) stocks neither; an innkeeper or general-goods NPC in
        -- sight does. Go there next, once per trip per NPC.
        if supplies.needs_supplier(player) then
            state.vendor.supplier_skip = state.vendor.supplier_skip or {}
            local cur = state.vendor.supplier_guid
            if cur then
                state.vendor.supplier_skip[cur] = true
            end
            local unit = supplies.find_supplier(player, SUPPLIER_RANGE, state.vendor.supplier_skip)
            if unit then
                state.vendor.supplier_guid = safe(function() return unit:get_guid() end)
                state.vendor.supplier_name = safe(function() return unit:get_name() end)
                state.vendor.window_seen = false
                state.vendor.tries = 0
                close_vendor()
                state.set_note("Vendor", "Food / water at " .. tostring(state.vendor.supplier_name))
                return true
            end
        end
        finish_trip("Vendor done")
        return false
    end

    -- On the way to the food / water seller picked above.
    if state.vendor.supplier_guid then
        return supplier_tick(player)
    end

    -- Supply run to an inn (2.139.0): walk there, then find the innkeeper.
    if state.vendor.inn then
        local inn = state.vendor.inn
        local me = safe(function() return player:get_position() end)
        local d = me and math.sqrt((me.x - inn.x) ^ 2 + (me.y - inn.y) ^ 2) or 999
        local seller = d <= 60 and supplies.find_supplier(player, 60, state.vendor.supplier_skip) or nil
        if seller then
            state.vendor.supplier_guid = safe(function() return seller:get_guid() end)
            state.vendor.supplier_name = safe(function() return seller:get_name() end)
            state.vendor.inn = nil
            trail("supply run: innkeeper %s", tostring(state.vendor.supplier_name))
            return true
        end
        if d > 12 then
            if not nav_place(player, inn) then
                return false
            end
            state.set_note("Vendor", string.format("Going to the inn for food / water  %.0fy", d))
            return true
        end
        local now = izi.now()
        local started = state.vendor.wait_npc
        if type(started) ~= "number" or started <= 0 then
            state.vendor.wait_npc = now
        elseif now - started > 20 then
            supplies.trip_done(600)
            finish_trip("No innkeeper found at the inn")
            return false
        end
        state.set_note("Vendor", "Looking for the innkeeper")
        return true
    end

    local info = current_merchant(player)
    local dest = merchant_pos(info)
    if not dest then
        finish_trip("No merchant for this zone")
        return false
    end

    if not movement.arrived(dest, ARRIVE) then
        -- Claim the tick only if movement took the request; combat still owning
        -- the player (post-fight settle) must not stall the rest of the cascade.
        if not nav_place(player, dest) then
            return false
        end
        local who = (info and info.name) or (info and info.npc_id) or "merchant"
        state.set_note("Vendor", "Travel to " .. tostring(who))
        return true
    end

    movement.nav_stop()
    local now = izi.now()
    local unit = nil
    local ids = merchant_ids(info)
    for i = 1, #ids do
        unit = targeting.find_npc(player, ids[i], FIND_RANGE)
        if unit then
            break
        end
    end
    if not unit then
        unit = targeting.find_named(player, info.name, info.name_cn, FIND_RANGE)
    end
    if not unit then
        local started = state.vendor.wait_npc
        if type(started) ~= "number" or started <= 0 then
            started = now
            state.vendor.wait_npc = now
        end
        if now - started > 20 then
            finish_trip("Merchant not found nearby")
            return false
        end
        state.set_note("Vendor", "Merchant not found nearby")
        return true
    end
    state.vendor.wait_npc = 0

    local d = safe(function() return player:distance_to(unit) end) or 99
    if type(d) == "number" and d > 5 then
        local p = safe(function() return unit:get_position() end) or dest
        state.vendor.idle_since = 0
        return nav_place(player, p) == true
    end

    if idle_check(now) then
        return false
    end
    if now < (state.vendor.interact_until or 0) then
        return true
    end
    state.vendor.tries = (state.vendor.tries or 0) + 1
    if state.vendor.tries > 8 then
        finish_trip("Merchant did not open")
        return false
    end
    state.vendor.interact_until = now + INTERACT_GAP
    targeting.set_current(unit, "vendor")
    pcall(function()
        core.input.interact_with_object(unit)
    end)
    if gossip_open() then
        if not select_vendor_gossip() then
            close_vendor()
            state.set_note("Vendor", "No vendor gossip")
        end
    end
    state.set_note("Vendor", "Interact")
    return true
end

return vendor
