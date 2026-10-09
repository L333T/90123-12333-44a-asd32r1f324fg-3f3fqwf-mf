-- ============================================================================
-- Master Farmer - Grindbot
-- Gathering: profession trainer trips (PORT_PLAYBOOK "Vendor, repair, trainers")
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.256.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- trainer.lua (the class trainer) refuses every profession service on
-- purpose, so the gathering mode trains its professions here. A trip is due,
-- out of combat, when the profession's tracking spell (Find Herbs / Find
-- Minerals) is not learned, or the skill sits at its maximum while that
-- maximum is below this client's cap (gather/route.profession_cap: 300 on
-- Classic / Forever, 375 on TBC Anniversary).
--
-- Walk to the trainer row's coordinate (movement.nav_to), find the NPC by
-- name, open gossip -> trainer option (gossip.select, the same spec the quest
-- engine's profession trainer uses), then buy every affordable profession
-- service, one per BUY_GAP. Class spells are never bought here.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local movement = require("movement")
local targeting = require("targeting")
local gossip = require("gossip")
local state = require("state")
local factions = require("data/factions")
local spellbook = require("spellbook")
local route = require("gather/route")

local trainer = {}

-- The eight trainer rows from the playbook (English names, exact coordinates).
local ROWS = {
    { skill = "herbalism", high = false, faction = "Horde",    name = "Martha Alliestar", map = 1458, x = 1560.99,  y = 355.14,   z = -62.16 },
    { skill = "herbalism", high = false, faction = "Alliance", name = "Kali Healtouch",   map = 1432, x = -5380.36, y = -2999.62, z = 330.77 },
    { skill = "herbalism", high = true,  faction = "Horde",    name = "Ruak Stronghorn",  map = 1944, x = 232.84,   y = 2842.45,  z = 131.34 },
    { skill = "herbalism", high = true,  faction = "Alliance", name = "Rorelien",         map = 1944, x = -784.47,  y = 2771.25,  z = 120.84 },
    { skill = "mining",    high = false, faction = "Horde",    name = "Brom Killian",     map = 1458, x = 1638.69,  y = 335.61,   z = -62.18 },
    { skill = "mining",    high = false, faction = "Alliance", name = "Yarr Hammerstone", map = 1426, x = -5528.96, y = -660.98,  z = 393.45 },
    { skill = "mining",    high = true,  faction = "Horde",    name = "Krugosh",          map = 1944, x = 186.75,   y = 2676.35,  z = 88.89 },
    { skill = "mining",    high = true,  faction = "Alliance", name = "Hurnak Grimmord",  map = 1944, x = -717.80,  y = 2611.66,  z = 91.01 },
}

local TRACKING = { herbalism = "Find Herbs", mining = "Find Minerals" }

local ARRIVE = 5
local TALK_GAP = 2.0
local BUY_GAP = 0.6
local TRIP_MAX = 900          -- give up a trip after 15 min
local AT_TRAINER_MAX = 60     -- give up at the trainer after 60 s
local RETRY_AFTER = 1800      -- a failed / finished trip is not retried for 30 min

local trip = nil              -- { row, since, arrived_at, talk_t, buy_t, bought }
local rest_until = {}         -- skill -> time

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function now() return izi.now() or 0 end

local function profession_level(skill)
    local profs = safe(function() return core.spell_book.get_professions() end)
    if type(profs) ~= "table" then return nil, nil end
    for _, slot in ipairs({ "prof1", "prof2" }) do
        local idx = profs[slot]
        if type(idx) == "number" then
            local info = safe(function() return core.spell_book.get_profession_info(idx) end)
            if type(info) == "table" and string.lower(tostring(info.skill_line_name or "")) == skill then
                return tonumber(info.skill_level) or 0, tonumber(info.max_skill_level) or 0
            end
        end
    end
    return nil, nil
end

---The trainer row this character should visit for `skill`, or nil.
local function due_row(player, skill)
    if now() < (rest_until[skill] or 0) then return nil end
    local cap = route.profession_cap()
    local level, max_level = profession_level(skill)
    local missing = spellbook.family(TRACKING[skill]) == nil
    local capped = level ~= nil and max_level ~= nil and max_level > 0 and level >= max_level and max_level < cap
    if not missing and not capped then return nil end
    local high = (level or 0) >= 300
    if high and cap < 375 then return nil end
    local side = factions.of_player(player)
    local faction = side == factions.HORDE and "Horde" or "Alliance"
    for _, r in ipairs(ROWS) do
        if r.skill == skill and r.high == high and r.faction == faction then return r end
    end
    return nil
end

local function finish(why, retry_after)
    if trip then
        rest_until[trip.row.skill] = now() + (retry_after or RETRY_AFTER)
        core.log("[Master Farmer - Grindbot] gather trainer: " .. trip.row.name .. " - " .. why)
    end
    pcall(function() core.quests.close_trainer() end)
    trip = nil
    return false
end

function trainer.reset()
    trip = nil
    rest_until = {}
end

function trainer.busy()
    return trip ~= nil
end

---Buys the next affordable profession service in the open trainer window.
---@return boolean bought
local function buy_next()
    pcall(function() core.skill.expand_trainer_skill_line(0) end)
    local n = safe(function() return core.quests.get_num_trainer_services() end) or 0
    local gold = safe(function() return core.inventory.get_gold() end) or 0
    for i = 1, math.min(tonumber(n) or 0, 400) do
        local info = safe(function() return core.quests.get_trainer_service_info(i) end)
        if type(info) == "table" then
            local cat = string.lower(tostring(info.category or ""))
            local cost_t = safe(function() return core.quests.get_trainer_service_cost(i) end)
            local cost = type(cost_t) == "table" and tonumber(cost_t.service_cost) or 0
            local talent = type(cost_t) == "table" and tonumber(cost_t.talent_cost) or 0
            if (cat == "available" or cat == "") and talent == 0 and (cost or 0) <= gold then
                pcall(function() core.quests.buy_trainer_service(i) end)
                return true
            end
        end
    end
    return false
end

---@param need table { herbalism = bool, mining = bool } from the Gathering tab
---@return boolean true while a trainer trip holds the tick
function trainer.tick(player, need, enabled)
    if not enabled then trip = nil return false end
    local t = now()
    if not trip then
        if safe(function() return player:is_in_combat() end) == true then return false end
        for _, skill in ipairs({ "mining", "herbalism" }) do
            if need[skill] then
                local row = due_row(player, skill)
                if row then
                    trip = { row = row, since = t, arrived_at = nil, talk_t = -1e9, buy_t = -1e9, bought = 0 }
                    core.log(string.format("[Master Farmer - Grindbot] gather trainer: %s (%s, map %d)",
                        row.name, skill, row.map))
                    break
                end
            end
        end
        if not trip then return false end
    end

    local r = trip.row
    if (t - trip.since) > TRIP_MAX then return finish("gave up (trip too long)") end
    if safe(function() return player:is_in_combat() end) == true then return false end

    local here = state.cached_pos or safe(function() return player:get_position() end)
    local dest = { x = r.x, y = r.y, z = r.z }
    local n_serv = tonumber(safe(function() return core.quests.get_num_trainer_services() end)) or 0

    if n_serv > 0 then
        movement.nav_stop()
        if (t - trip.buy_t) < BUY_GAP then return true end
        trip.buy_t = t
        if buy_next() then
            trip.bought = trip.bought + 1
            state.set_note("Gather", "Training " .. r.skill)
            return true
        end
        return finish(trip.bought > 0 and ("learned " .. trip.bought .. " rank(s)") or "nothing to learn",
            trip.bought > 0 and 60 or RETRY_AFTER)
    end

    if here and not movement.arrived(dest, ARRIVE) then
        local unit = targeting.find_named(player, r.name, nil, 30)
        local up = unit and safe(function() return unit:get_position() end)
        if not up then
            state.set_note("Gather", string.format("To trainer %s", r.name))
            movement.nav_to(dest)
            return true
        end
        if (safe(function() return player:distance_to(unit) end) or 99) > ARRIVE then
            movement.nav_to(up)
            state.set_note("Gather", string.format("To trainer %s", r.name))
            return true
        end
    end

    trip.arrived_at = trip.arrived_at or t
    if (t - trip.arrived_at) > AT_TRAINER_MAX then return finish("no trainer window") end
    movement.nav_stop()
    local unit = targeting.find_named(player, r.name, nil, 15)
    if not unit then
        state.set_note("Gather", "Trainer " .. r.name .. " not here")
        return true
    end
    if (t - trip.talk_t) >= TALK_GAP then
        trip.talk_t = t
        targeting.set_current(unit, "trainer")
        if gossip.is_open() then
            gossip.select({ icon = "TRAINER", icon_num = 3, type = "trainer", words = { "train", "teach", "learn" } })
        else
            pcall(function() core.input.interact_with_object(unit) end)
        end
    end
    state.set_note("Gather", "Opening trainer " .. r.name)
    return true
end

return trainer
