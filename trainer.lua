-- ============================================================================
-- Master Farmer - Grindbot
-- Class trainer - buy trainable spell ranks
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.88.0
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
--- The trainer gossip option, found the way the vendor module finds its own
--- (2.75.0): izi's icon lookup first, then the gossip type.
local function trainer_option()
    if izi.gossip and type(izi.gossip.find_option_by_icon) == "function" then
        local icon = 3
        if type(izi.gossip.ICON) == "table" and type(izi.gossip.ICON.TRAINER) == "number" then
            icon = izi.gossip.ICON.TRAINER
        end
        local opt = safe(function() return izi.gossip.find_option_by_icon(icon) end)
        if type(opt) == "table" and type(opt.gossip_option_id) == "number" and opt.gossip_option_id ~= 0 then
            return opt.gossip_option_id
        end
    end
    local options = safe(function() return core.quests.get_gossip_options() end)
    if type(options) ~= "table" then
        return nil
    end
    for i = 1, #options do
        local opt = options[i]
        if type(opt) == "table" then
            local gtype = type(opt.gossip_type) == "string" and string.lower(opt.gossip_type) or ""
            local text = type(opt.name) == "string" and string.lower(opt.name) or ""
            if gtype == "trainer" or text:find("train me", 1, true) then
                local id = opt.gossip_option_id
                if type(id) ~= "number" or id == 0 then
                    id = i
                end
                return id
            end
        end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- GOING TO THE TRAINER (2.75.0)
-- ----------------------------------------------------------------------------
-- Training used to happen only when a gossip window was already open, so a
-- grinding character never trained at all. Now, after a level-up, a class
-- trainer IN SIGHT (by name - there is no trainer-location data and no NPC
-- flag call) is walked to and trained at, once per level. Out of combat and
-- only while the bot is running.
local TRAINERS = {
    WARRIOR = { "Llane Beanshield", "Lyria Du Lac", "Thran Khorman", "Granis Swiftaxe", "Ilsa Corbin", "Wu Shen", "Ander Germaine" },
    PALADIN = { "Brother Sammuel", "Brother Wilhelm", "Bromos Grummner", "Azar Stronghammer", "Arthur the Faithful", "Brother Joshua" },
    HUNTER  = { "Thorgas Grimson", "Grif Wildheart", "Ayanna Everstride", "Dazalar", "Kildar" },
    ROGUE   = { "Jorik Kerridan", "Keryn Sylvius", "Solm Hargrin", "Hogral Bakkan", "Osborne the Night Man" },
    PRIEST  = { "Priestess Anetta", "Priestess Josetta", "Branstock Khalder", "Maxan Anvol", "High Priestess Laurena", "Brother Benjamin" },
    SHAMAN  = { "Firmanvaar", "Nobundo", "Sulaa", "Tuluun" },
    MAGE    = { "Khelden Bremen", "Zaldimar Wefhellt", "Marryk Nurribit", "Magis Sparkmantle", "Jennea Cannon", "Elsharin" },
    WARLOCK = { "Drusilla La Salle", "Maximillian Crowe", "Alamar Grimm", "Gimrizz Shadowcog", "Demisette Cloyce", "Ursula Deline" },
    DRUID   = { "Mardant Strongoak", "Kal", "Gart Mistrunner", "Jannok Breezesong" },
}
local SEEK_RANGE = 100
local SEEK_TRIES = 6

local seek = nil             -- { guid, name, tries } while walking to a trainer
local trained_level = nil    -- the level last trained at
local seek_skip_level = nil  -- a level whose trainer never opened

local function class_trainers(player)
    local ok, enums = pcall(require, "common/enums")
    local cls = safe(function() return player:get_class() end)
    if not ok or type(enums) ~= "table" or type(enums.class_id) ~= "table" then
        return nil
    end
    for key, id in pairs(enums.class_id) do
        if id == cls and TRAINERS[key] then
            local set = {}
            for i = 1, #TRAINERS[key] do set[TRAINERS[key][i]] = true end
            return set
        end
    end
    return nil
end

local function trainer_in_sight(player)
    local names = class_trainers(player)
    if not names then return nil end
    local ok_t, targeting = pcall(require, "targeting")
    local list = ok_t and targeting and type(targeting.visible_objects) == "function"
        and targeting.visible_objects() or nil
    if type(list) ~= "table" then return nil end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_player() end) ~= true then
            local name = safe(function() return u:get_name() end)
            if type(name) == "string" and names[name] then
                local d = safe(function() return player:distance_to(u) end)
                if type(d) == "number" and d <= SEEK_RANGE and (best_d == nil or d < best_d) then
                    best, best_d = u, d
                end
            end
        end
    end
    return best
end

local function unit_by_guid(guid)
    local ok_t, targeting = pcall(require, "targeting")
    local list = ok_t and targeting and type(targeting.visible_objects) == "function"
        and targeting.visible_objects() or nil
    if type(list) ~= "table" then return nil end
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:get_guid() end) == guid then
            return u
        end
    end
    return nil
end

local function bot_running()
    if type(gui.is_started) == "function" and gui.is_started() then
        return true
    end
    return false
end

--- Walk to a class trainer in sight after a level-up. True while doing so.
local function seek_tick(player, now)
    local level = safe(function() return player:get_level() end) or 0
    if trained_level == nil then
        -- First look this session: train once if a trainer is in sight.
        trained_level = level - 1
    end
    if level <= trained_level or seek_skip_level == level then
        seek = nil
        return false
    end
    if not bot_running() then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    local ok_h, healing = pcall(require, "healing")
    if ok_h and healing and type(healing.is_resting) == "function" and healing.is_resting() then
        return false
    end

    local unit = seek and unit_by_guid(seek.guid) or nil
    if not unit then
        unit = trainer_in_sight(player)
        if not unit then
            seek = nil
            return false
        end
        seek = { guid = safe(function() return unit:get_guid() end),
            name = safe(function() return unit:get_name() end), tries = 0 }
    end
    local movement = require("movement")
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > 5 then
        local p = safe(function() return unit:get_position() end)
        if p and movement.nav_to(p) then
            state.set_note("Trainer", "Going to " .. tostring(seek.name))
            return true
        end
        return false
    end
    movement.nav_stop()
    if (now - last_act) < 1.2 then
        return true
    end
    seek.tries = seek.tries + 1
    if seek.tries > SEEK_TRIES then
        seek_skip_level = level
        seek = nil
        state.set_note("Trainer", "Trainer did not open")
        return false
    end
    last_act = now
    tried_level, tried_gold = nil, nil     -- a fresh visit: the gossip path may select
    pcall(function() core.input.interact_with_object(unit) end)
    state.set_note("Trainer", "Talking to " .. tostring(seek.name))
    return true
end

--- Busy training: the service list is open and not finished, or walking to
--- a trainer. The quest engine's talk goals wait for this.
function trainer.busy()
    return seek ~= nil or (service_count() > 0 and not finished)
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
        trained_level = safe(function() return player:get_level() end) or trained_level
        seek = nil
        state.set_note("Trainer", "Training complete")
        core.log(string.format("[Master Farmer - Grindbot] Training complete (%d bought).", bought_this_visit))
        pcall(function() core.quests.close_gossip() end)
        return false
    end

    -- 2. A gossip frame is open in front of us. If this NPC trains, open it.
    if not gossip_open() then
        return seek_tick(player, now)
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
    -- On by default (2.75.0), and the bot now walks to a trainer in sight.
    menu:checkbox("mfg_train", true, {
        label = "Train Spells",
        tab = "settings",
        tooltip = "When a gossip frame is open at an NPC that trains this class, "
            .. "buy every spell rank the character can afford, cheapest first. "
            .. "Class spells only - talents and professions are never bought. "
            .. "After a level-up it also walks to a class trainer in sight (within 100 yards) "
            .. "and trains there, once per level.",
    })
end

return trainer
