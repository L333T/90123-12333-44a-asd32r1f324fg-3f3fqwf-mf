-- ============================================================================
-- Master Farmer - Grindbot
-- Class trainer - buy trainable spell ranks
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.182.0
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
--
-- 2.104.0 - EVERY 3 LEVELS, EVERYTHING AFFORDABLE, VERIFIED
--   * A trainer is checked once, then again only after 3 more levels
--     (CHECK_EVERY). The level of the last check is saved per character, so a
--     restart does not send the bot back. A RestedXP ".trainer" step before
--     that is skipped straight to the next goal.
--   * Every available class spell is bought, cheapest first, until the list
--     is empty or the purse is. Headers are expanded first so no rank hides
--     under a collapsed category.
--   * Each purchase is verified (gold spent, or the rank no longer
--     available) and retried up to BUY_TRIES times before it is given up on.
--   * The window is closed with close_trainer when done - close_gossip left
--     it open - so the quest step and the bot move on.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local gossip = require("gossip")

local gui = require("gui")
local state = require("state")

local trainer = {}

local ACT_GAP = 0.6          -- seconds between purchases
local GOLD_STEP = 10000      -- 1g more than last time counts as "richer"
local MAX_SERVICES = 200     -- sanity bound on the service list

local last_act = -1e9
local select_tries = 0       -- 2.125.0: trainer-option selects this gossip visit
local SELECT_MAX = 3
local tried_level = nil
local tried_gold = nil
-- Training is over for the window that is open now (2.43.0). The window
-- cannot be closed through the API, and while it stayed open this module
-- claimed ~95% of all ticks - so nothing walked the bot away, which is the
-- only thing that closes it. Cleared when the window closes.
local finished = false
local skip_reset = false     -- 2.149.0: a quest visit clears the "trainer never opened" level
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

-- 2.104.0: purchase verification and the every-3-levels check.
local CHECK_EVERY = 3        -- levels between trainer checks
local BUY_TRIES = 3          -- attempts at one rank before giving up on it
local VERIFY_AFTER = 0.8     -- seconds before a purchase is checked
local attempts = {}          -- name -> purchases tried this visit
local pending = nil          -- { name, gold, at } awaiting verification
local trained_this_visit = 0
local expanded = false       -- headers expanded for this window
local checked_level = nil    -- level of the last completed trainer check (saved)

local function forget_bought()
    bought = {}
    attempts = {}
    pending = nil
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
    trained_this_visit = 0
    expanded = false
end

-- ----------------------------------------------------------------------------
-- EVERY 3 LEVELS (2.104.0)
-- ----------------------------------------------------------------------------
local function level_of(player)
    return safe(function() return player:get_level() end) or 0
end

-- QUEST TRAINER STEPS (2.149.0). A RestedXP ".train" / ".trainer" step is
-- followed when questing: it asks for a visit now, whatever the every-3-levels
-- check says. The visit walks to the class trainer in sight, trains what can
-- be afforded, and reports done so the quest engine moves on.
local quest_wanted = false
local quest_title = nil      -- the quest step's waypoint title, while a quest visit runs
local quest_done = false

--- A quest step wants a trainer visit now (true), or no longer (false).
function trainer.quest_visit(on, title)
    quest_title = (on and type(title) == "string" and title ~= "") and title or nil
    if on then
        if not quest_wanted then
            quest_wanted, quest_done = true, false
            tried_level, tried_gold = nil, nil
            skip_reset = true
            finished = false
        end
    else
        quest_wanted, quest_done = false, false
    end
end

--- Did the visit a quest step asked for finish?
function trainer.quest_visit_done()
    return quest_done == true
end

--- Is a trainer check due? Never checked (this character), 3+ levels since,
--- or a quest step asked for one.
function trainer.due(player)
    if not player then return false end
    if quest_wanted and not quest_done then return true end
    if checked_level == nil then return true end
    return level_of(player) >= checked_level + CHECK_EVERY
end

--- The level at which the next check falls due.
function trainer.next_level()
    return checked_level and (checked_level + CHECK_EVERY) or nil
end

local function note_checked(player)
    checked_level = level_of(player)
    local ok, settings = pcall(require, "settings")
    if ok and type(settings) == "table" and type(settings.mark_dirty) == "function" then
        settings.mark_dirty()
    end
end

do
    local ok, settings = pcall(require, "settings")
    if ok and type(settings) == "table" and type(settings.register) == "function" then
        settings.register("trainer_level",
            function() return checked_level and tostring(checked_level) or nil end,
            function(v) checked_level = tonumber(v) end)
    end
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
local short = 0              -- available ranks left that cost more than we hold

--- One service row as (name, cost, available) - nil for headers / non-class.
local function service_row(i)
    local cost = safe(function() return core.quests.get_trainer_service_cost(i) end)
    if type(cost) ~= "table" then return nil end
    local service = cost.service_cost
    if type(service) ~= "number" or (cost.talent_cost or 0) ~= 0 or (cost.profession_cost or 0) ~= 0 then
        return nil
    end
    local info = safe(function() return core.quests.get_trainer_service_info(i) end)
    if type(info) ~= "table" or type(info.spell_name) ~= "string" or info.spell_name == "" then
        return nil
    end
    local cat = type(info.category) == "string" and string.lower(info.category) or ""
    local name = info.spell_name
    if type(info.rank) == "string" and info.rank ~= "" then
        name = name .. " (" .. info.rank .. ")"
    end
    return name, service, (cat == "" or cat == "available")
end

--- Is this rank still offered as "available"? (For purchase verification.)
local function still_available(name)
    for i = 1, service_count() do
        local n, _, avail = service_row(i)
        if n == name and avail then return true end
    end
    return false
end

local function cheapest_affordable()
    local budget = gold()
    short = 0

    local best_idx, best_cost, best_name = nil, nil, nil
    for i = 1, service_count() do
        local n, c, avail = service_row(i)
        if n and avail and not bought[n] then
            if c > budget then
                short = short + 1
            elseif best_cost == nil or c < best_cost then
                best_idx, best_cost, best_name = i, c, n
            end
        end
    end
    if best_idx then
        return best_idx, best_name, best_cost
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- GOSSIP
-- ----------------------------------------------------------------------------
local function gossip_open()
    return gossip.is_open()
end

--- The trainer option in the open gossip frame, or nil.
---
--- Matched on gossip_type, never on list position: the documentation is
--- explicit that the order is not stable. The id is opaque and is handed
--- straight back to the selector in the same frame.
--- The trainer gossip option, found the way the vendor module finds its own
--- (2.75.0): izi's icon lookup first, then the gossip type.
-- THE TRAINER OPTION (2.125.0). Three bugs left a class trainer's gossip
-- ("I am interested in mage training.") standing open:
--   * izi.gossip.find_option_by_icon returns a VIEW ({ index, name,
--     gossip_type, icon, id, select = fn }); this read its gossip_option_id,
--     which a view does not have, so the icon match was always thrown away;
--   * the text fallback only knew "train me";
--   * see trainer.tick: the every-3-levels gate also blocked an open window.
-- Now: izi's icon match (selected through the view's own :select()), then the
-- raw options by gossip_type "trainer", the trainer icon (3) or the wording
-- (train / teach / instruct), selected by gossip_option_id - a real id on
-- Blizzard's Classic clients, the row index on the private-server ones.
local TRAINER_ICON = 3
local TRAIN_WORDS = { "train", "teach", "instruct" }

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "trainer", fmt, ...)
    end
end


--- The open gossip's trainer option as (select_function, label), or nil.
local function trainer_option()
    -- gossip.lua (2.144.0): izi's TRAINER icon, then type / icon 3 / wording.
    return gossip.find({ icon = "TRAINER", icon_num = TRAINER_ICON, type = "trainer", words = TRAIN_WORDS })
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
    WARRIOR = { "Llane Beshere", "Lyria Du Lac", "Thran Khorman", "Granis Swiftaxe", "Ilsa Corbin", "Wu Shen", "Ander Germaine" },
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

-- FINDING THE TRAINER (2.150.0). The name list alone missed trainers - the
-- Northshire warrior trainer was listed as "Llane Beanshield" (he is Llane
-- Beshere), so a quest ".train" step stood beside him finding nobody. In
-- order of certainty:
--   1. the name a quest step's waypoint gives (RestedXP titles it);
--   2. this class's names in TRAINERS;
--   3. any unit flagged class trainer (get_npc_flags 0x20) that has not
--      already refused us - another class's trainer offers no training, is
--      marked `rejected`, and the next one is tried.
local NPC_CLASS_TRAINER = 0x20
local rejected = {}          -- guid -> true: a class trainer that did not train us

local function has_flag(value, bit)
    return type(value) == "number" and value > 0 and math.floor(value / bit) % 2 == 1
end

local function trainer_in_sight(player)
    local names = class_trainers(player) or {}
    local ok_t, targeting = pcall(require, "targeting")
    local list = ok_t and targeting and type(targeting.visible_objects) == "function"
        and targeting.visible_objects() or nil
    if type(list) ~= "table" then return nil end
    local best, best_d, best_rank = nil, nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_player() end) ~= true then
            local name = safe(function() return u:get_name() end)
            local guid = safe(function() return u:get_guid() end)
            local rank = nil
            if type(name) == "string" and quest_title and name == quest_title then
                rank = 1
            elseif type(name) == "string" and names[name] then
                rank = 2
            elseif quest_wanted and not (guid and rejected[guid])
                and has_flag(safe(function() return u:get_npc_flags() end), NPC_CLASS_TRAINER) then
                -- Any flagged class trainer only for a quest ".train" step
                -- (2.161.0): the bot's own level-up visits walked to other
                -- classes' trainers - one of them the 12:15 turn-in NPC.
                rank = 3
            end
            if rank and safe(function() return player:can_attack(u) end) ~= true then
                local d = safe(function() return player:distance_to(u) end)
                if type(d) == "number" and d <= SEEK_RANGE
                    and (best_rank == nil or rank < best_rank or (rank == best_rank and d < best_d)) then
                    best, best_d, best_rank = u, d, rank
                end
            end
        end
    end
    return best
end

--- The trainer being walked to did not train us: skip it and try another.
local function reject_seek(why)
    if seek and seek.guid then
        rejected[seek.guid] = true
        trail("%s did not train us (%s) - trying another trainer", tostring(seek.name), tostring(why))
    end
    seek = nil
end

--- The nearest class trainer in sight (SEEK_RANGE), or nil.
function trainer.in_sight(player)
    return trainer_in_sight(player)
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
-- THE QUEST STEP FIRST (2.161.0). The quest goal being worked, or nil.
-- A trainer visit the bot decides on itself waits while questing is on an
-- NPC goal (accept / turn in / talk / fly): the 12:15 session walked to a
-- turn-in NPC who is a class trainer while this module walked it to a
-- trainer too - "Nav settle" every few seconds, then standing.
local DIALOG_KINDS = { accept = true, turnin = true, talk = true, fly = true }

local function quest_goal_kind()
    local ok_q, quest = pcall(require, "quest/engine")
    if not ok_q or type(quest) ~= "table" then return nil end
    if type(gui.is_on) == "function" and not gui.is_on("use_quest") then return nil end
    if type(quest.current_kind) ~= "function" then return nil end
    return quest.current_kind()
end

local function seek_tick(player, now)
    if not quest_wanted and DIALOG_KINDS[quest_goal_kind() or ""] then
        seek = nil
        return false
    end
    local level = safe(function() return player:get_level() end) or 0
    -- Every CHECK_EVERY levels (2.104.0), saved per character.
    if skip_reset then
        skip_reset = false
        seek_skip_level = nil
    end
    if not trainer.due(player) or seek_skip_level == level then
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
        state.set_note("Trainer", "Trainer did not open")
        reject_seek("no trainer window")
        if not trainer_in_sight(player) then
            seek_skip_level = level
        end
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
    if open and select_tries > 0 then
        trail("trainer window open: %d service(s)", service_count())
        select_tries = 0
    end
    if not open then
        -- The window has closed: the next one is a fresh visit.
        finished = false
        bought_this_visit = 0
        trained_this_visit = 0
        expanded = false
        pending = nil
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
        -- Expand every category once, so no rank hides under a collapsed
        -- header (0 = all lines).
        if not expanded then
            expanded = true
            pcall(function() core.skill.expand_trainer_skill_line(0) end)
            last_act = now
            return true
        end
        -- Verify the last purchase: gold spent, or the rank no longer offered.
        if pending then
            if (now - pending.at) < VERIFY_AFTER then
                return true
            end
            local p = pending
            pending = nil
            if gold() < p.gold or not still_available(p.name) then
                trained_this_visit = trained_this_visit + 1
                core.log("[Master Farmer - Grindbot] Trained " .. tostring(p.name))
                trail("trained %s", tostring(p.name))
            elseif (attempts[p.name] or 0) < BUY_TRIES then
                bought[p.name] = nil          -- not learned: try it again
                core.log_warning("[Master Farmer - Grindbot] " .. tostring(p.name)
                    .. " was not learned - retrying.")
            else
                core.log_warning("[Master Farmer - Grindbot] Could not train " .. tostring(p.name)
                    .. " after " .. BUY_TRIES .. " tries - skipping it.")
            end
        end
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
            attempts[name] = (attempts[name] or 0) + 1
            pending = { name = name, gold = gold(), at = now }
            pcall(function() core.quests.buy_trainer_service(idx) end)
            local ok_sb, spellbook = pcall(require, "spellbook")
            if ok_sb and spellbook and type(spellbook.request_rescan) == "function" then
                spellbook.request_rescan()
            end
            return true
        end

        -- Nothing left to train, or nothing left we can afford. The check is
        -- done for the next CHECK_EVERY levels; close the window (close_trainer
        -- - close_gossip left it open) so the quest step moves on.
        mark_tried(player)
        forget_bought()
        finished = true
        note_checked(player)
        if quest_wanted then quest_done = true end
        seek = nil
        local msg
        if trained_this_visit == 0 and short == 0 then
            msg = "No new spells to train"
        elseif short > 0 then
            msg = string.format("Trained %d spell(s); %d more need more gold", trained_this_visit, short)
        else
            msg = string.format("Trained %d spell(s)", trained_this_visit)
        end
        state.set_note("Trainer", msg)
        core.log(string.format("[Master Farmer - Grindbot] %s - next trainer check at level %d.",
            msg, (checked_level or 0) + CHECK_EVERY))
        trail("%s - next check at level %d", msg, (checked_level or 0) + CHECK_EVERY)
        pcall(function() core.quests.close_trainer() end)
        pcall(function() core.quests.close_gossip() end)
        return false
    end

    -- 2. A gossip frame is open in front of us. If this NPC trains, open it.
    --    Not gated on the every-3-levels check (2.125.0): that decides whether
    --    to WALK to a trainer; a trainer already talking to us is used. Only
    --    a quest being handed in or taken at this NPC goes first - class
    --    trainers give class quests, and selecting training would close them.
    if not gossip_open() then
        select_tries = 0
        return seek_tick(player, now)
    end
    if already_tried(player) then
        return false
    end
    -- A quest giver / turn-in NPC who also trains (2.161.0): the quest goes
    -- first, whether or not the dialog has started yet. Training there is
    -- the bot's own visit, and it can come back once the goal moves on.
    local gk = quest_goal_kind()
    if not quest_wanted and (gk == "accept" or gk == "turnin") then
        return false
    end
    local ok_q, quest = pcall(require, "quest/engine")
    if ok_q and type(quest) == "table" and type(quest.in_npc_interaction) == "function"
        and quest.in_npc_interaction() then
        local goal_kind = type(quest.current_kind) == "function" and quest.current_kind() or nil
        if goal_kind ~= "talk" then
            return false
        end
    end
    local select_fn, label = trainer_option()
    if not select_fn then
        -- Walked up to a class trainer and it offers no training: another
        -- class's trainer (2.150.0). Close, mark it, try the next.
        if seek then
            reject_seek("no training option")
            pcall(function() core.quests.close_gossip() end)
        end
        return false
    end
    -- Selected SELECT_MAX times and no trainer window: stop for this visit.
    if select_tries >= SELECT_MAX then
        if select_tries == SELECT_MAX then
            select_tries = select_tries + 1
            trail("'%s' selected %d times - no trainer window opened", tostring(label), SELECT_MAX)
            mark_tried(player)
        end
        return false
    end

    select_tries = select_tries + 1
    last_act = now
    forget_bought()
    expanded = false
    state.set_note("Trainer", "Opening trainer")
    trail("gossip: selecting '%s' (try %d)", tostring(label), select_tries)
    pcall(select_fn)
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
            .. "Checked every 3 levels: it walks to a class trainer in sight (within 100 yards), "
            .. "and a RestedXP trainer step before then is skipped.",
    })
end

return trainer
