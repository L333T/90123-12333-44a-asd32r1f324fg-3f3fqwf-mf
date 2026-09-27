-- ============================================================================
-- Master Farmer - Grindbot
-- Class trainer - buy trainable spell ranks
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.73.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- IT DOES NOT TRAVEL, AND THAT IS DELIBERATE
--   There is no trainer location data in this project. The zone tables carry a
--   `merchant` record (name plus coordinates) and nothing else, and inventing
--   class-trainer coordinates for every race, zone and class would be guessing
--   at data the bot would then walk into a lake to reach.
--
--   So this trains OPPORTUNISTICALLY: whenever a gossip frame is open in front
--   of the bot for any reason - a quest giver, the zone merchant, anything -
--   and that NPC offers a trainer option, it trains before anything else gets
--   to use the frame. It never opens a dialog of its own and never changes
--   where the bot walks.
--
--   To make it travel, add `trainer = { name = ..., x/y/z }` beside `merchant`
--   in grind/zones/*.lua and the vendor trip pattern can be reused directly.
--
-- WHAT IT BUYS
--   Class spell ranks only: services whose talent_cost and profession_cost are
--   both zero. Talent and profession purchases are irreversible choices that
--   belong to the player, not to a bot.
--
--   Cheapest first, so a level's worth of gold buys the most ranks.
--
-- WHY IT LATCHES
--   Reading the service list is cheap but selecting the trainer gossip option
--   is not: it replaces whatever frame is open. Once a trainer has been worked
--   through, it is not touched again until the character levels or gets
--   meaningfully richer - the only two things that can produce new affordable
--   ranks.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local gui = require("gui")
local state = require("state")

local trainer = {}

local ACT_GAP = 0.6          -- seconds between purchases
local GOLD_STEP = 10000      -- 1g more than last time counts as "richer"
local MAX_SERVICES = 200     -- sanity bound on the service list

local last_act = -1e9
local tried_level = nil
local tried_gold = nil
-- Training is over for the window that is open now (2.43.0). The window
-- cannot be closed through the API, and while it stayed open this module
-- claimed ~95% of all ticks - so nothing walked the bot away, which is the
-- only thing that closes it. Cleared when the window closes.
local finished = false
local bought_this_visit = 0
local MAX_PER_VISIT = 30      -- hard stop if a purchase keeps silently failing

-- Spells bought while this trainer window has been open.
--
-- A learned spell normally leaves the service list, but nothing here can rely
-- on that: if the list lags a frame, or buy_trainer_service quietly fails, the
-- cheapest entry stays cheapest and the bot buys it again every tick until the
-- purse is empty. Keyed on the spell name rather than the index, because
-- indices shift as entries are removed.
local bought = {}

local function forget_bought()
    bought = {}
end

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local function gold()
    local c = safe(function() return core.inventory.get_gold() end)
    if type(c) == "number" then
        return c
    end
    return 0
end

-- ----------------------------------------------------------------------------
-- LATCH
-- ----------------------------------------------------------------------------
--- Have we already worked this trainer over at this level and this much gold?
local function already_tried(player)
    local level = safe(function() return player:get_level() end) or 0
    if tried_level ~= level then
        return false
    end
    if type(tried_gold) == "number" and (gold() - tried_gold) >= GOLD_STEP then
        return false
    end
    return true
end

local function mark_tried(player)
    tried_level = safe(function() return player:get_level() end) or 0
    tried_gold = gold()
end

--- Let the next level or a decent purse re-open the question.
function trainer.reset()
    tried_level, tried_gold = nil, nil
    forget_bought()
    finished = false
    bought_this_visit = 0
end

-- ----------------------------------------------------------------------------
-- SERVICES
-- ----------------------------------------------------------------------------
local function service_count()
    local n = safe(function() return core.quests.get_num_trainer_services() end)
    if type(n) ~= "number" or n < 0 then
        return 0
    end
    if n > MAX_SERVICES then
        return MAX_SERVICES
    end
    return n
end

--- The cheapest service this character may buy right now, or nil.
---
--- Returns (index, name, cost). Only class spells are considered: a service
--- carrying a talent or profession cost is a player decision, not a bot one.
local function cheapest_affordable()
    local budget = gold()
    if budget <= 0 then
        return nil
    end

    local best_idx, best_cost, best_name = nil, nil, nil
    for i = 1, service_count() do
        local cost = safe(function() return core.quests.get_trainer_service_cost(i) end)
        if type(cost) == "table" then
            local service = cost.service_cost
            local talent = cost.talent_cost or 0
            local profession = cost.profession_cost or 0
            if type(service) == "number" and service > 0
                and talent == 0 and profession == 0
                and service <= budget
                and (best_cost == nil or service < best_cost) then
                local info = safe(function() return core.quests.get_trainer_service_info(i) end)
                local name = (type(info) == "table" and info.spell_name) or nil
                -- category is the service type: "available", "unavailable"
                -- (level too low), "used" (already learned) or "header".
                -- Only an available one can be bought (2.43.0); the others
                -- were "bought" once per visit, 0.6 s each.
                local cat = type(info) == "table" and info.category or nil
                if type(cat) == "string" and cat ~= "" and string.lower(cat) ~= "available" then
                    name = nil
                end
                -- A row with no spell name is a category header, not a spell.
                if type(name) == "string" and name ~= "" then
                    if type(info.rank) == "string" and info.rank ~= "" then
                        name = name .. " (" .. info.rank .. ")"
                    end
                    if not bought[name] then
                        best_idx, best_cost, best_name = i, service, name
                    end
                end
            end
        end
    end
    return best_idx, best_name, best_cost
end

-- ----------------------------------------------------------------------------
-- GOSSIP
-- ----------------------------------------------------------------------------
local function gossip_open()
    return safe(function() return core.quests.is_gossip_frame_shown() end) == true
end

--- The trainer option in the open gossip frame, or nil.
---
--- Matched on gossip_type, never on list position: the documentation is
--- explicit that the order is not stable. The id is opaque and is handed
--- straight back to the selector in the same frame.
local function trainer_option()
    local options = safe(function() return core.quests.get_gossip_options() end)
    if type(options) ~= "table" then
        return nil
    end
    for i = 1, #options do
        local opt = options[i]
        if type(opt) == "table" and type(opt.gossip_type) == "string"
            and string.lower(opt.gossip_type) == "trainer" then
            local id = opt.gossip_option_id
            if type(id) ~= "number" or id == 0 then
                id = i
            end
            return id
        end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- TICK
-- ----------------------------------------------------------------------------
--- Returns true when it acted, so the caller holds the rest of the cascade.
function trainer.tick(player)
    if not player or gui.is_on("train") ~= true then
        return false
    end

    local now = izi.now()
    local open = service_count() > 0
    if not open then
        -- The window has closed: the next one is a fresh visit.
        finished = false
        bought_this_visit = 0
    elseif finished then
        -- Done with this window. Do not claim the tick: the quest / grind
        -- engine has to run so the bot walks off, which closes the window.
        return false
    end
    if (now - last_act) < ACT_GAP then
        -- Mid-purchase: hold the cascade so nothing else grabs the window.
        return open
    end

    -- 1. A trainer window is open: spend.
    if open then
        local idx, name, cost = nil, nil, nil
        if bought_this_visit < MAX_PER_VISIT then
            idx, name, cost = cheapest_affordable()
        end
        if idx then
            bought_this_visit = bought_this_visit + 1
            last_act = now
            state.set_note("Trainer", string.format("Training %s", tostring(name)))
            core.log(string.format(
                "[Master Farmer - Grindbot] Training %s for %d.%02dg",
                tostring(name), math.floor(cost / 10000), math.floor((cost % 10000) / 100)))
            bought[name] = true
            pcall(function() core.quests.buy_trainer_service(idx) end)
            local ok_sb, spellbook = pcall(require, "spellbook")
            if ok_sb and spellbook and type(spellbook.request_rescan) == "function" then
                spellbook.request_rescan()
            end
            return true
        end

        -- Nothing left we can afford. Close up and leave it alone until the
        -- character levels or gets richer.
        mark_tried(player)
        forget_bought()
        finished = true
        state.set_note("Trainer", "Training complete")
        core.log(string.format("[Master Farmer - Grindbot] Training complete (%d bought).", bought_this_visit))
        pcall(function() core.quests.close_gossip() end)
        return false
    end

    -- 2. A gossip frame is open in front of us. If this NPC trains, open it.
    if not gossip_open() then
        return false
    end
    if already_tried(player) then
        return false
    end
    local option = trainer_option()
    if not option then
        return false
    end

    last_act = now
    forget_bought()
    state.set_note("Trainer", "Opening trainer")
    pcall(function() core.quests.select_gossip_option(option) end)
    return true
end

function trainer.register_gui(menu)
    menu:checkbox("mfg_train", false, {
        label = "Train Spells",
        tab = "settings",
        tooltip = "When a gossip frame is open at an NPC that trains this class, "
            .. "buy every spell rank the character can afford, cheapest first. "
            .. "Class spells only - talents and professions are never bought. "
            .. "It does not walk to a trainer: there is no trainer location data, "
            .. "so it trains at trainers the bot already happens to be talking to.",
    })
end

return trainer
