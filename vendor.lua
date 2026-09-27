-- ============================================================================
-- Master Farmer - Grindbot
-- Vendor sell + repair (Grind_Information merchants)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.82.0
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
local rotation = require("rotation")

local vendor = {}

local HEARTHSTONE = 6948
local SELL_GAP = 0.40
local INTERACT_GAP = 1.20
local DONE_COOLDOWN = 90.0
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
local function path_merchant()
    local ok, runner = pcall(require, "path_runner")
    if not ok or type(runner) ~= "table" or type(runner.current_path) ~= "function" then
        return nil
    end
    local path = safe(function() return runner.current_path() end)
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
    local slots = safe(function() return core.inventory.get_num_bag_slots(0) end) or 16
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

local function bag_free()
    local helper_free = safe(function()
        return inventory_helper:get_total_free_slots()
    end)
    if type(helper_free) == "number" and helper_free >= 0 then
        return helper_free + backpack_free()
    end
    local free = backpack_free()
    for bag = 1, 4 do
        local slots = safe(function() return core.inventory.get_num_bag_slots(bag) end) or 0
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
    return free
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

local function should_sell_item(player, item_id)
    if type(item_id) ~= "number" or item_id <= 0 then
        return false
    end
    local keep = keep_ids(player)
    if keep[item_id] then
        return false
    end
    local info = safe(function() return core.quests.get_item_info(item_id) end)
    if type(info) ~= "table" then
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

--- Did the last sale land? The count of that item must have gone down.
local function check_last_sale()
    local p = sell_pending
    if not p then
        return
    end
    sell_pending = nil
    local now_count = bags.count(p.item_id)
    if now_count < p.count then
        sell_fails[p.item_id] = nil
        return
    end
    sell_fails[p.item_id] = (sell_fails[p.item_id] or 0) + 1
    if sell_fails[p.item_id] >= SELL_RETRIES then
        trail("could not sell item %s (%d in bags) - skipped for this trip", tostring(p.item_id), now_count)
    end
end

--- Sell the first sellable bag item, BY ITEM ID (2.80.0) - see bags.use_id.
local function sell_one(player)
    check_last_sale()
    local list = bags.list(player)
    local seen = {}
    for i = 1, #list do
        local e = list[i]
        local id = e.item_id
        if id and not seen[id] then
            seen[id] = true
            if (sell_fails[id] or 0) < SELL_RETRIES and should_sell_item(player, id) then
                local before = bags.count(id)
                if before > 0 then
                    bags.use_id(id)
                    sell_pending = { item_id = id, count = before }
                    trail("sell item %s (%d in bags)", tostring(id), before)
                    return true, id
                end
            end
        end
    end
    return false
end

local function gossip_open()
    if izi.gossip and type(izi.gossip.is_open) == "function" then
        if safe(function() return izi.gossip.is_open() end) == true then
            return true
        end
    end
    return safe(function() return core.quests.is_gossip_frame_shown() end) == true
end

local function gossip_option_id(opt)
    if type(opt) == "number" and opt ~= 0 then
        return opt
    end
    if type(opt) ~= "table" then
        return nil
    end
    if type(opt.gossip_option_id) == "number" and opt.gossip_option_id ~= 0 then
        return opt.gossip_option_id
    end
    if type(opt.id) == "number" and opt.id ~= 0 then
        return opt.id
    end
    if type(opt.index) == "number" and opt.index ~= 0 then
        return opt.index
    end
    return nil
end

local function select_vendor_gossip()
    if izi.gossip and type(izi.gossip.find_option_by_icon) == "function" then
        local icon = 1
        if type(izi.gossip.ICON) == "table" and type(izi.gossip.ICON.VENDOR) == "number" then
            icon = izi.gossip.ICON.VENDOR
        end
        local opt = safe(function()
            return izi.gossip.find_option_by_icon(icon)
        end)
        local id = nil
        if type(opt) == "table" and type(opt.gossip_option_id) == "number" and opt.gossip_option_id ~= 0 then
            id = opt.gossip_option_id
        end
        if type(id) == "number" then
            pcall(function()
                core.quests.select_gossip_option(id)
            end)
            return true
        end
    end
    local options = safe(function() return core.quests.get_gossip_options() end)
    if type(options) ~= "table" then
        return false
    end
    for i = 1, #options do
        local opt = options[i]
        if type(opt) == "table" then
            local gtype = opt.gossip_type
            if type(gtype) == "string" and string.lower(gtype) == "vendor" then
                local id = gossip_option_id(opt) or i
                pcall(function()
                    core.quests.select_gossip_option(id)
                end)
                return true
            end
        end
    end
    return false
end

local function close_vendor()
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
    state.vendor.repair_tries = 0
    sell_pending = nil
    sell_fails = {}
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
    local ok, runner = pcall(require, "path_runner")
    if not ok or type(runner) ~= "table" or type(runner.take_lap) ~= "function" then
        return false
    end
    return safe(function() return runner.take_lap() end) == true
end

function vendor.needs_trip(player)
    if not player then
        return false
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
    if izi.now() < (state.vendor.done_until or 0) and not state.vendor.active then
        return false
    end
    if gui.is_on("sell") then
        local need_slots = gui.slider("bag_free", 1)
        if bag_free() <= need_slots then
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
            movement.nav_to(p, true)
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

local function supplier_tick(player)
    local unit = supplier_unit(player)
    if not unit then
        finish_trip("Food / water seller not found")
        return false
    end
    local now = izi.now()
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > 5 then
        local p = safe(function() return unit:get_position() end)
        if not p or not movement.nav_to(p) then
            return false
        end
        state.set_note("Vendor", "Travel to " .. tostring(state.vendor.supplier_name))
        return true
    end
    movement.nav_stop()
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

function vendor.tick(player)
    if not player then
        return false
    end
    if ht then
        local in_combat_h = safe(function() return player:is_in_combat() end) == true
        if not in_combat_h and hearth_tick(player) then
            return true
        end
    end
    if not gui.is_on("sell") and not gui.is_on("repair") then
        if state.vendor.active then
            vendor.reset()
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
    if not state.vendor.active and merchant_open() and izi.now() >= (state.vendor.here_until or 0) then
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
            -- No merchant data here. Full bags cannot wait for one: hearth to
            -- the inn and find a merchant there (2.47.0).
            if gui.is_on("sell") and bag_free() <= gui.slider("bag_free", 1) then
                ht = { stage = "cast", t = izi.now(), tried = {}, tries = 0 }
                return hearth_tick(player)
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
            supplies.new_merchant()
            trail("merchant window open (%d items, repair %s)",
                safe(function() return core.game_ui.get_vendor_item_count() end) or 0,
                tostring(safe(function() return core.inventory.can_merchant_repair() end) == true))
        end
        if now < (state.vendor.interact_until or 0) then
            state.set_note("Vendor", "Selling")
            return true
        end
        if gui.is_on("sell") then
            local sold, item_id = sell_one(player)
            if sold then
                state.vendor.sold = (state.vendor.sold or 0) + 1
                state.vendor.interact_until = now + SELL_GAP
                state.set_note("Vendor", "Sold " .. tostring(item_id))
                return true
            end
        end
        -- Restock before repair: repair drains gold, and arriving with no food
        -- is what forces the next trip. Buying first spends what is left over
        -- after selling instead of after repairing.
        if supplies.tick(player) then
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

    local info = current_merchant(player)
    local dest = merchant_pos(info)
    if not dest then
        finish_trip("No merchant for this zone")
        return false
    end

    if not movement.arrived(dest, ARRIVE) then
        -- Claim the tick only if movement took the request; combat still owning
        -- the player (post-fight settle) must not stall the rest of the cascade.
        if not movement.nav_to(dest) then
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
        return movement.nav_to(p) == true
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
