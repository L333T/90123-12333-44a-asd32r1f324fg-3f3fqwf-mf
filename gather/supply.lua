-- ============================================================================
-- Master Farmer - Grindbot
-- Gathering: hunter ammo and route food / drink trips (PORT_PLAYBOOK
-- "Food, drink, ammo")
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.247.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Port of EP_Herb_Mine BulletRun / BuyBullets / Hunter_Ammo_* and
-- Food_Drink_Run / Buy_Food_Drinks. Every route row names its own
-- ammo_vendor / ammo_coord and food_vendor / food_coord / food / drink.
--
--   Ammo (hunters): the ranged weapon's subclass picks arrows (bow 2,
--   crossbow 18) or shot (gun 3). A trip starts when the ammo carried is
--   under "Ammo Buy Below" and buys the best tier the vendor sells that the
--   hunter can use (vendor is_usable) until "Ammo Stop At". The bought ammo
--   is then used once from the bags, which puts it in the ammo slot.
--
--   Food / drink: a trip starts when food, or drink (not warriors / rogues),
--   is at or under "Restock At" and buys up to "Food / Drink Stock". The
--   route's own food / drink name is bought when the vendor sells it and it
--   is usable at this level; otherwise the best usable item from
--   data/consumables the vendor stocks. Mages never buy (they conjure).
--
-- Items are matched by item id first, English name second. Each purchase is
-- measured: the first buy_item is one unit, and later quantities come from
-- what one unit actually added to the bags. A purchase that adds nothing
-- three times, or no gold, ends the trip.
--
-- WoW Forever cannot read vendor items (core.game_ui.get_vendor_item_info is
-- empty there), so these trips are off on Forever and say so once.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local movement = require("movement")
local targeting = require("targeting")
local gossip = require("gossip")
local state = require("state")
local bags = require("bags")
local gamever = require("gamever")
local consumables = require("data/consumables")

local supply = {}

local CLASS_WARRIOR, CLASS_HUNTER, CLASS_ROGUE, CLASS_MAGE = 1, 3, 4, 8
local RANGED_SLOT = 18

-- Worst to best. The playbook's four tiers plus the TBC pair the script
-- also listed (Wicked Arrow / Blackflight Arrow, Impact Shot / Ironbite Shell).
local ARROWS = {
    { id = 2512, name = "Rough Arrow" }, { id = 2515, name = "Sharp Arrow" },
    { id = 3030, name = "Razor Arrow" }, { id = 11285, name = "Jagged Arrow" },
    { id = 28053, name = "Wicked Arrow" }, { id = 28056, name = "Blackflight Arrow" },
}
local SHOT = {
    { id = 2516, name = "Light Shot" }, { id = 2519, name = "Heavy Shot" },
    { id = 3033, name = "Solid Shot" }, { id = 11284, name = "Accurate Slugs" },
    { id = 28060, name = "Impact Shot" }, { id = 28061, name = "Ironbite Shell" },
}

local ARRIVE = 5
local TALK_GAP = 2.0
local BUY_GAP = 0.8
local TRIP_MAX = 900          -- give up a trip after 15 min
local AT_VENDOR_MAX = 60      -- give up at the vendor after 60 s without a window
local RETRY_AFTER = 600       -- a failed trip waits 10 min
local POOR_AFTER = 1800       -- no gold: 30 min
local MAX_REFUSED = 3

local trip = nil
local rest_until = { ammo = 0, food = 0 }
local forever_logged = false

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function now() return izi.now() or 0 end

local function log(msg) core.log("[Master Farmer - Grindbot] gather supply: " .. msg) end

-- ----------------------------------------------------------------------------
-- Counts
-- ----------------------------------------------------------------------------

local function ammo_list(player)
    local info = safe(function() return player:get_item_at_inventory_slot(RANGED_SLOT) end)
    local id = type(info) == "table" and info.object and safe(function() return info.object:get_item_id() end)
    if type(id) ~= "number" or id <= 0 then return nil end
    local item = safe(function() return core.quests.get_item_info(id) end)
    local sub = type(item) == "table" and item.subclass_id or nil
    if sub == 2 or sub == 18 then return ARROWS end
    if sub == 3 then return SHOT end
    return nil
end

local function count_ids(list)
    local n = 0
    for i = 1, #list do n = n + (bags.count(list[i].id) or 0) end
    return n
end

local function food_drink(player)
    bags.food_water_invalidate()
    local nf, nw = bags.food_water_count(player)
    return nf or 0, nw or 0
end

local function drinks(class_id)
    return class_id ~= CLASS_WARRIOR and class_id ~= CLASS_ROGUE
end

-- ----------------------------------------------------------------------------
-- Vendor window
-- ----------------------------------------------------------------------------

local function vendor_rows()
    local n = tonumber(safe(function() return core.game_ui.get_vendor_item_count() end)) or 0
    local rows = {}
    for i = 1, math.min(n, 200) do
        local e = safe(function() return core.game_ui.get_vendor_item_info(i) end)
        if type(e) == "table" then
            rows[#rows + 1] = {
                index = i,
                id = tonumber(e.item_id) or 0,
                name = tostring(e.item_name or ""),
                cost = tonumber(e.cost) or 0,
                usable = e.is_usable ~= false,
            }
        end
    end
    return rows
end

local function sells(rows, id, name)
    for i = 1, #rows do
        local r = rows[i]
        if (id and r.id == id) or (name and name ~= "" and r.name == name) then return r end
    end
    return nil
end

---Best usable ammo row (highest tier the vendor sells).
local function pick_ammo(rows, list)
    for i = #list, 1, -1 do
        local r = sells(rows, list[i].id, list[i].name)
        if r and r.usable then return r end
    end
    return nil
end

---The route's item when sold and usable, else the best usable listed one.
local function pick_food(rows, route_name, ids)
    local r = sells(rows, nil, route_name)
    if r and r.usable then return r end
    for i = 1, #ids do
        r = sells(rows, ids[i], nil)
        if r and r.usable then return r end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- Trip
-- ----------------------------------------------------------------------------

local function coord(c)
    if type(c) ~= "table" then return nil end
    local x, y, z = c.x or c[2], c.y or c[3], c.z or c[4]
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    if x == 0 and y == 0 and z == 0 then return nil end
    return { x = x, y = y, z = z }
end

local function finish(why, wait)
    if trip then
        rest_until[trip.kind] = now() + (wait or RETRY_AFTER)
        log(trip.vendor .. " - " .. why)
        if trip.kind == "ammo" and trip.equip_id then
            pcall(bags.use_id, trip.equip_id)        -- puts the new ammo in the ammo slot
        end
    end
    pcall(function() core.input.close_merchant() end)
    trip = nil
    return false
end

function supply.reset()
    trip = nil
    rest_until = { ammo = 0, food = 0 }
end

function supply.busy() return trip ~= nil end

---What this character needs now, or nil.
---@return string|nil kind "ammo" | "food"
local function due(player, opts, r)
    local t = now()
    local class_id = safe(function() return player:get_class() end)
    if opts.ammo and class_id == CLASS_HUNTER and t >= rest_until.ammo
        and type(r.ammo_vendor) == "string" and r.ammo_vendor ~= "" and coord(r.ammo_coord) then
        local list = ammo_list(player)
        if list and count_ids(list) < opts.ammo_low then return "ammo" end
    end
    if opts.food and class_id ~= CLASS_MAGE and t >= rest_until.food
        and type(r.food_vendor) == "string" and r.food_vendor ~= "" and coord(r.food_coord) then
        local nf, nw = food_drink(player)
        if nf <= opts.food_low or (drinks(class_id) and nw <= opts.food_low) then return "food" end
    end
    return nil
end

---Buys the next lot. True while buying goes on.
local function buy_step(player, opts)
    local rows = vendor_rows()
    local class_id = safe(function() return player:get_class() end)
    local row, have, target, label
    if trip.kind == "ammo" then
        local list = ammo_list(player)
        if not list then return finish("no ranged weapon") end
        have, target = count_ids(list), opts.ammo_stop
        if have >= target then return finish(string.format("ammo %d / %d", have, target), 60) end
        row = pick_ammo(rows, list)
        if not row then return finish("sells no usable ammo") end
        label = row.name ~= "" and row.name or "ammo"
        trip.equip_id = row.id > 0 and row.id or trip.equip_id
    else
        local nf, nw = food_drink(player)
        local want_food = nf < opts.food_stock
        local want_drink = drinks(class_id) and nw < opts.food_stock
        if not want_food and not want_drink then
            return finish(string.format("food %d, drink %d", nf, nw), 60)
        end
        local route = trip.route
        if want_food and not trip.no_food then
            row = pick_food(rows, route.food, consumables.FOOD_FULL_LIST)
            if not row then trip.no_food = true end
            have, label = nf, "food"
        end
        if not row and want_drink and not trip.no_drink then
            row = pick_food(rows, route.drink, consumables.DRINK_FULL_LIST)
            if not row then trip.no_drink = true end
            have, label = nw, "drink"
        end
        if not row then return finish("sells no usable food / drink") end
        target = opts.food_stock
        label = (row.name ~= "" and row.name) or label
    end

    -- Measure what the last buy added.
    local key = trip.kind .. ":" .. row.index
    if trip.pending and trip.pending.key == key then
        local gained = have - trip.pending.have
        if gained <= 0 then
            trip.refused = trip.refused + 1
            if trip.refused >= MAX_REFUSED then return finish("purchase did not arrive (" .. label .. ")") end
        else
            trip.refused = 0
            trip.unit[key] = trip.unit[key] or (gained / math.max(1, trip.pending.q))
        end
        trip.pending = nil
    end

    local gold = tonumber(safe(function() return core.inventory.get_gold() end)) or 0
    if row.cost > 0 and gold < row.cost then return finish("not enough gold for " .. label, POOR_AFTER) end
    local qty = 1
    local unit = trip.unit[key]
    if unit and unit > 0 then
        qty = math.max(1, math.ceil((target - have) / unit))
        if row.cost > 0 then qty = math.min(qty, math.floor(gold / row.cost)) end
        qty = math.max(1, math.min(qty, 20))
    end
    trip.pending = { key = key, have = have, q = qty }
    state.set_note("Gather", string.format("Buying %s (%d / %d)", label, have, target))
    pcall(function() core.input.buy_item(row.index, qty) end)
    return true
end

---@param r table the gathering route row
---@param opts table { ammo, ammo_low, ammo_stop, food, food_low, food_stock, mount_up = fn(far) }
---@return boolean true while a supply trip holds the tick
function supply.tick(player, r, opts)
    if not r then trip = nil return false end
    if gamever.is_forever() then
        if not forever_logged and (opts.ammo or opts.food) then
            forever_logged = true
            log("WoW Forever cannot read vendor items - ammo and food buying is off.")
        end
        return false
    end
    local t = now()
    if not trip then
        if safe(function() return player:is_in_combat() end) == true then return false end
        local kind = due(player, opts, r)
        if not kind then return false end
        local c = kind == "ammo" and r.ammo_coord or r.food_coord
        trip = {
            kind = kind, route = r,
            vendor = kind == "ammo" and r.ammo_vendor or r.food_vendor,
            dest = coord(c), map = type(c) == "table" and c.mapid or nil,
            since = t, arrived_at = nil, talk_t = -1e9, buy_t = -1e9,
            pending = nil, refused = 0, unit = {},
        }
        log(string.format("%s trip to %s (map %s)", kind, trip.vendor, tostring(trip.map)))
    end
    if (t - trip.since) > TRIP_MAX then return finish("gave up (trip too long)") end

    local n_items = tonumber(safe(function() return core.game_ui.get_vendor_item_count() end)) or 0
    if n_items > 0 then
        movement.nav_stop()
        if (t - trip.buy_t) < BUY_GAP then return true end
        trip.buy_t = t
        return buy_step(player, opts) ~= false and trip ~= nil
    end

    local unit = targeting.find_named(player, trip.vendor, nil, 40)
    local d_npc = unit and safe(function() return player:distance_to(unit) end) or nil
    if not d_npc and not movement.arrived(trip.dest, ARRIVE) then
        local here = state.cached_pos or safe(function() return player:get_position() end)
        local far = here and type(here.x) == "number"
            and math.sqrt((here.x - trip.dest.x) ^ 2 + (here.y - trip.dest.y) ^ 2) > 60
        if opts.mount_up and opts.mount_up(far) then return true end
        state.set_note("Gather", string.format("To %s (%s)", trip.vendor, trip.kind))
        if not movement.is_moving() then movement.nav_to(trip.dest) end
        return true
    end
    if d_npc and d_npc > ARRIVE then
        local up = safe(function() return unit:get_position() end)
        state.set_note("Gather", string.format("To %s (%s)", trip.vendor, trip.kind))
        if up and not movement.is_moving() then movement.nav_to(up) end
        return true
    end

    trip.arrived_at = trip.arrived_at or t
    if (t - trip.arrived_at) > AT_VENDOR_MAX then return finish("no merchant window") end
    movement.nav_stop()
    if not unit then
        state.set_note("Gather", trip.vendor .. " not here")
        return true
    end
    if safe(function() return player:is_mounted() end) == true then
        pcall(function() core.input.dismount() end)
        return true
    end
    if (t - trip.talk_t) >= TALK_GAP then
        trip.talk_t = t
        targeting.set_current(unit, "vendor")
        if gossip.is_open() then
            gossip.select({ icon = "VENDOR", icon_num = 1, type = "vendor", words = { "browse", "goods", "buy", "wares" } })
        else
            pcall(function() core.input.interact_with_object(unit) end)
        end
    end
    state.set_note("Gather", "Opening " .. trip.vendor)
    return true
end

return supply
