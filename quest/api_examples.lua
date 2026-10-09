-- ============================================================================
-- Master Farmer - Grindbot
-- Example functions for the quest and RestedXP surface the quest tick uses.
-- ============================================================================
-- quest/engine.lua, quest/npc.lua and quest/guide.lua are the live state
-- machine. This file is the call list those modules need, one native action
-- per function so a tick never accepts and turns in on the same frame.
--
-- Signatures match the Documents .api stub (caebb61977a7c3\scripts\.api\core.lua;
-- BLIZZ_PROJECTS\.api\core.lua predates the 2026-10-06 core). Functions added in the
-- 2026-10-06 core (get_open_quest_info, get_quest_objectives, is_quest_complete,
-- get_quest_log_quest_ids, get_num_quest_choices, abandon_quest_by_id,
-- close_trainer, rested_xp.skip_current_step) are called only when the
-- function exists. Older cores leave them nil.
-- ============================================================================

local examples = {}

local rxp = core.addons and core.addons.rested_xp or nil

local function call(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

--- Private-server gossip ids are row indexes, not quest ids: any exact build
--- whose name contains "_ps" (the core.lua stub's gossip table: wow_tbc_ps /
--- wow_vanilla_ps), and Vanilla. Forever and Blizzard Classic carry real ids
--- (quest/npc.lua npc.gossip_ids_are_rows is the live copy of this rule).
local function gossip_ids_are_rows()
    local exact = call(core.get_exact_game_version)
    if type(exact) == "string" and exact:find("_ps", 1, true) then
        return true
    end
    local ver = call(core.get_game_version)
    return ver == "Vanilla"
end

-- ---------------------------------------------------------------------------
-- Quest log. Prefer a quest id. A log index moves when a header collapses.
-- ---------------------------------------------------------------------------

--- "active" | "complete" | "done" | "none"
--- is_quest_complete is the game's hand-in flag. is_quest_flagged_completed
--- is history, including quests already turned in.
function examples.quest_status(quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id or quest_id <= 0 then
        return "none"
    end
    if call(core.quests.is_quest_flagged_completed, quest_id) == true
        and call(core.quests.is_on_quest, quest_id) ~= true then
        return "done"
    end
    if call(core.quests.is_on_quest, quest_id) ~= true then
        return "none"
    end
    if type(core.quests.is_quest_complete) == "function"
        and call(core.quests.is_quest_complete, quest_id) == true then
        return "complete"
    end
    return "active"
end

--- Expand every header, then return quest rows. Headers are omitted.
--- Each row is { index, quest_id, title, level, is_complete }.
function examples.quest_log()
    call(core.quests.expand_quest_header, 0, false)
    local rows = {}
    if type(core.quests.get_quest_log_quest_ids) == "function" then
        local ids = call(core.quests.get_quest_log_quest_ids)
        if type(ids) == "table" then
            for i = 1, #ids do
                local quest_id = tonumber(ids[i])
                if quest_id and quest_id > 0 then
                    rows[#rows + 1] = {
                        index = nil,          -- a position in the id list is not a log index
                        quest_id = quest_id,
                        title = "",
                        level = 0,
                        is_complete = examples.quest_status(quest_id) == "complete" and 1 or nil,
                    }
                end
            end
            if #rows > 0 then
                return rows
            end
        end
    end
    local count = call(core.quests.get_num_quest_log_entries) or 0
    for i = 1, count do
        local info = call(core.quests.get_quest_log_title, i)
        if type(info) == "table" and info.is_header ~= true then
            rows[#rows + 1] = {
                index = i,
                quest_id = tonumber(info.quest_id) or 0,
                title = info.title or "",
                level = tonumber(info.level) or 0,
                is_complete = info.is_complete,
            }
        end
    end
    return rows
end

local function log_index(quest_id)
    -- the log rows themselves (get_quest_log_title): their index is a log index
    call(core.quests.expand_quest_header, 0, false)
    local count = call(core.quests.get_num_quest_log_entries) or 0
    for i = 1, count do
        local info = call(core.quests.get_quest_log_title, i)
        if type(info) == "table" and info.is_header ~= true and tonumber(info.quest_id) == quest_id then
            return i, info
        end
    end
    return nil
end

--- Objectives for a quest id.
--- Newer cores: { text, type, finished, fulfilled, required }.
--- Older cores: { text = description, type = objective_type, finished = is_completed }.
function examples.objectives(quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id then
        return {}
    end
    if type(core.quests.get_quest_objectives) == "function" then
        local list = call(core.quests.get_quest_objectives, quest_id)
        if type(list) == "table" then
            return list
        end
        return {}
    end
    local index = log_index(quest_id)
    if not index then
        return {}
    end
    local out = {}
    local n = call(core.quests.get_num_quest_leader_boards, index) or 0
    for j = 1, n do
        local obj = call(core.quests.get_quest_log_leader_board, j, index)
        if type(obj) == "table" then
            out[#out + 1] = {
                text = obj.description or "",
                type = obj.objective_type or "",
                finished = obj.is_completed == true,
            }
        end
    end
    return out
end

--- The quest the open detail, progress or reward panel is showing.
--- nil when the function is absent or no panel is open.
function examples.open_panel()
    if type(core.quests.get_open_quest_info) ~= "function" then
        return nil
    end
    local info = call(core.quests.get_open_quest_info)
    if type(info) ~= "table" then
        return nil
    end
    return {
        title = info.title or "",
        quest_id = tonumber(info.quest_id) or 0,
    }
end

--- true when every objective is finished, or the game says the quest can be handed in.
function examples.ready_to_turn_in(quest_id)
    if examples.quest_status(quest_id) == "complete" then
        return true
    end
    local list = examples.objectives(quest_id)
    if #list == 0 then
        return false
    end
    for i = 1, #list do
        if list[i].finished ~= true then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- NPC dialog. One call does one native action and returns what happened.
-- Pass gossip_option_id and gossip quest_id straight back in the same frame.
-- Do not store them. On a private server they are row indexes.
-- ---------------------------------------------------------------------------

function examples.gossip_open()
    return call(core.quests.is_gossip_frame_shown) == true
end

--- Select a gossip line by the id just read from get_gossip_options.
function examples.gossip_select(option_id)
    option_id = tonumber(option_id)
    if not option_id then
        return false
    end
    call(core.quests.select_gossip_option, option_id)
    return true
end

--- First non-trivial available quest on the open gossip frame.
--- Returns the row to pass to accept_selected, or nil.
function examples.gossip_available()
    if not examples.gossip_open() then
        return nil
    end
    local rows = call(core.quests.get_gossip_available_quests)
    if type(rows) ~= "table" then
        return nil
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" and row.is_trivial ~= true then
            return {
                title = row.title or "",
                quest_id = tonumber(row.quest_id) or 0,
                persist_id = not gossip_ids_are_rows(),
            }
        end
    end
    return nil
end

--- First active gossip quest the game marks complete.
function examples.gossip_ready()
    if not examples.gossip_open() then
        return nil
    end
    local rows = call(core.quests.get_gossip_active_quests)
    if type(rows) ~= "table" then
        return nil
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" and row.is_complete == true then
            return {
                title = row.title or "",
                quest_id = tonumber(row.quest_id) or 0,
                persist_id = not gossip_ids_are_rows(),
            }
        end
    end
    return nil
end

--- Open one available quest. Next tick, after QUEST_DETAIL, call accept_open.
function examples.accept_selected(quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id then
        return "no_id"
    end
    call(core.quests.select_gossip_available_quest, quest_id)
    return "selected"
end

--- Accept the quest detail that is already open. confirm covers escort quests.
function examples.accept_open()
    local panel = examples.open_panel()
    call(core.quests.accept_quest)
    call(core.quests.confirm_accept_quest)
    return panel
end

--- Open one completable quest. Next tick call continue_progress, then finish_reward.
function examples.turn_in_selected(quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id then
        return "no_id"
    end
    call(core.quests.select_gossip_active_quest, quest_id)
    return "selected"
end

--- Progress panel Continue. This is not the hand-in.
function examples.continue_progress()
    call(core.quests.complete_quest)
    return "continued"
end

--- Reward panel. choice is 1 .. get_num_quest_choices when the player must pick.
--- No choices: get_quest_reward(0), which is Complete Quest. Do not also call
--- complete_quest. That pair is one or the other.
function examples.finish_reward(choice)
    local n = 0
    if type(core.quests.get_num_quest_choices) == "function" then
        n = tonumber(call(core.quests.get_num_quest_choices)) or 0
    end
    if n > 0 then
        choice = tonumber(choice) or 1
        if choice < 1 then choice = 1 end
        if choice > n then choice = n end
        call(core.quests.get_quest_reward, choice)
        return "picked", choice
    end
    call(core.quests.get_quest_reward, 0)
    return "completed", 0
end

function examples.close_dialogs()
    call(core.quests.close_quest)
    call(core.quests.close_gossip)
    if type(core.quests.close_trainer) == "function" then
        call(core.quests.close_trainer)
    end
end

--- Abandon by quest id. Newer cores do it in one call. Older cores need the
--- log index, then set_abandon_quest and abandon_quest. Irreversible.
function examples.abandon(quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id then
        return false
    end
    if type(core.quests.abandon_quest_by_id) == "function" then
        return call(core.quests.abandon_quest_by_id, quest_id) == true
    end
    local index = log_index(quest_id)
    if not index then
        return false
    end
    call(core.quests.select_quest_log_entry, index)
    call(core.quests.set_abandon_quest)
    call(core.quests.abandon_quest)
    return true
end

--- Classic NPC quest list (no gossip). index is the row, not a quest id.
function examples.npc_list_select(kind, index)
    index = tonumber(index)
    if not index or index < 1 then
        return false
    end
    if kind == "active" then
        call(core.quests.select_active_quest, index)
    else
        call(core.quests.select_available_quest, index)
    end
    return true
end

function examples.npc_list_title(kind, index)
    index = tonumber(index)
    if not index then
        return ""
    end
    if kind == "active" then
        return call(core.quests.get_active_title, index) or ""
    end
    return call(core.quests.get_available_title, index) or ""
end

-- ---------------------------------------------------------------------------
-- Trainer. Buy one service the player can afford, then close.
-- ---------------------------------------------------------------------------

function examples.trainer_buy_one()
    local count = call(core.quests.get_num_trainer_services) or 0
    if count < 1 then
        return "empty"
    end
    local gold = call(core.inventory.get_gold) or 0
    for i = 1, count do
        local info = call(core.quests.get_trainer_service_info, i)
        local cost = call(core.quests.get_trainer_service_cost, i)
        local price = type(cost) == "table" and tonumber(cost.service_cost) or nil
        local name = type(info) == "table" and info.spell_name or ""
        if price and price >= 0 and gold >= price and name ~= "" then
            call(core.quests.buy_trainer_service, i)
            return "bought", name, price
        end
    end
    if type(core.quests.close_trainer) == "function" then
        call(core.quests.close_trainer)
    end
    return "none"
end

-- ---------------------------------------------------------------------------
-- Items a quest step uses.
-- ---------------------------------------------------------------------------

function examples.item_use_spell(item_id_or_link)
    local info = call(core.quests.get_item_spell, item_id_or_link)
    if type(info) ~= "table" then
        return nil
    end
    local spell_id = tonumber(info.spell_id) or 0
    if spell_id <= 0 and (info.spell_name or "") == "" then
        return nil
    end
    return { spell_id = spell_id, spell_name = info.spell_name or "" }
end

function examples.item_record(item_id_or_link)
    local info = call(core.quests.get_item_info, item_id_or_link)
    if type(info) ~= "table" or (info.name or "") == "" then
        return nil
    end
    return info
end

-- ---------------------------------------------------------------------------
-- RestedXP. Read only from the update callback, the same rule as guide.lua.
-- Titan never loads the addon: is_loaded stays false.
-- ---------------------------------------------------------------------------

local function goal_record(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local ids = {}
    if type(raw.ids) == "table" then
        for i = 1, #raw.ids do
            ids[#ids + 1] = raw.ids[i]
        end
    end
    local units = {}
    if type(raw.units) == "table" then
        for i = 1, #raw.units do
            units[#units + 1] = raw.units[i]
        end
    end
    return {
        action = raw.action or "",
        quest_id = tonumber(raw.quest_id) or 0,
        text = raw.text or "",
        is_complete = raw.is_complete == true,
        text_only = raw.text_only == true,
        ids = ids,
        objective = tonumber(raw.objective) or 0,
        objective_max = tonumber(raw.objective_max) or 0,
        reward = tonumber(raw.reward) or 0,
        money = tonumber(raw.money) or 0,
        money_greater_than = raw.money_greater_than == true,
        item_total = tonumber(raw.item_total) or 0,
        item_operator = tonumber(raw.item_operator) or 0,
        item_eq = raw.item_eq == true,
        units = units,
    }
end

local function step_record(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local goals = {}
    if type(raw.goals) == "table" then
        for i = 1, #raw.goals do
            local g = goal_record(raw.goals[i])
            if g then
                goals[#goals + 1] = g
            end
        end
    end
    return {
        num = tonumber(raw.num) or 0,
        is_complete = raw.is_complete == true,
        active = raw.active == true,
        requires = raw.requires or "",
        requires_step = tonumber(raw.requires_step) or 0,
        level = tonumber(raw.level) or 0,
        label = raw.label or "",
        goals = goals,
    }
end

local function waypoint_record(raw)
    if type(raw) ~= "table" then
        return nil
    end
    return {
        map_id = tonumber(raw.map_id) or 0,
        x = tonumber(raw.x) or 0,
        y = tonumber(raw.y) or 0,
        dist = tonumber(raw.dist) or 0,
        title = raw.title or "",
        type = raw.type or "",
        goal_num = tonumber(raw.goal_num) or 0,
        is_manual = raw.is_manual == true,
        wrong_continent = raw.wrong_continent == true,
    }
end

--- nil when RestedXP is not loaded or has no step.
--- The waypoint is nil when map_id is 0 or wrong_continent is set: dist is
--- not a walk target across a continent.
function examples.rested_read()
    if not rxp or call(rxp.is_loaded) ~= true then
        return nil
    end
    if call(rxp.has_current_step) ~= true then
        return nil
    end
    local step = step_record(call(rxp.get_current_step))
    if not step or step.num <= 0 then
        return nil
    end
    local stickies = {}
    local raw_stickies = call(rxp.get_current_stickies)
    if type(raw_stickies) == "table" then
        for i = 1, #raw_stickies do
            local st = step_record(raw_stickies[i])
            if st then
                stickies[#stickies + 1] = st
            end
        end
    end
    local wp = waypoint_record(call(rxp.get_current_waypoint))
    if not wp or wp.map_id == 0 or wp.wrong_continent then
        wp = nil
    end
    local step_wps = {}
    local raw_wps = call(rxp.get_step_waypoints)
    if type(raw_wps) == "table" then
        for i = 1, #raw_wps do
            local w = waypoint_record(raw_wps[i])
            if w and w.map_id ~= 0 and not w.wrong_continent then
                step_wps[#step_wps + 1] = w
            end
        end
    end
    return {
        step = step,
        stickies = stickies,
        waypoint = wp,
        step_waypoints = step_wps,
    }
end

--- RestedXP objective cache for one quest. Empty when the addon has no row.
function examples.rested_objectives(quest_id)
    if not rxp or call(rxp.is_loaded) ~= true then
        return {}
    end
    quest_id = tonumber(quest_id)
    if not quest_id then
        return {}
    end
    local list = call(rxp.get_objectives, quest_id)
    if type(list) ~= "table" then
        return {}
    end
    return list
end

--- Skip a step the bot cannot do: inactive, and not waiting on requires_step.
--- false when skip_current_step is absent, or RestedXP refused.
function examples.rested_skip_inactive()
    if not rxp or type(rxp.skip_current_step) ~= "function" then
        return false
    end
    local snap = examples.rested_read()
    if not snap then
        return false
    end
    local step = snap.step
    if step.active or step.requires_step ~= 0 then
        return false
    end
    return call(rxp.skip_current_step) == true
end

--- The first incomplete goal on the current step, or nil.
function examples.rested_goal()
    local snap = examples.rested_read()
    if not snap then
        return nil
    end
    for i = 1, #snap.step.goals do
        local g = snap.step.goals[i]
        if not g.is_complete and not g.text_only then
            g.step_num = snap.step.num
            g.reward_choice = g.reward
            return g
        end
    end
    return nil
end

return examples
