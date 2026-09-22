-- ============================================================================
-- Master Farmer - Grindbot
-- Quest NPC interact / gossip / accept / turn-in
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 1.5.0
-- Folder: Master_Farmer_Grindbot_v1.5.0
-- ============================================================================
-- TWO FRAMES, NOT ONE
--   An NPC with quests shows either a GOSSIP frame (get_gossip_*_quests, keyed
--   by quest id) or a QUEST GREETING frame (get_available_title / get_active_
--   title, keyed by a 1-based INDEX). Only the gossip path existed before, so a
--   greeting-frame NPC fell through to a bare accept_quest() with nothing
--   selected and the bot stalled. Both paths are handled here.
--
-- COMPLETE vs GET_QUEST_REWARD ARE ALTERNATIVES
--   complete_quest() is for a quest with no reward choice. get_quest_reward(i)
--   SELECTS choice i AND completes the quest. They were being called one after
--   the other, which meant a quest offering a choice of rewards could never be
--   handed in: complete_quest() is refused while a choice is pending, and the
--   follow-up passed index 0, which is the "no choice" sentinel.
--
-- ESCORTS NEED A SECOND YES
--   accept_quest() is not enough for an auto-accept / escort quest; the client
--   raises a confirmation popup that confirm_accept_quest() answers.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local movement = require("movement")
local targeting = require("targeting")
local state = require("state")

local npc = {}

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

-- Walk an indexed NPC-frame list until the titles run out. There is no
-- get_num_* for these, and an index past the end returns an empty string.
local MAX_FRAME_QUESTS = 32

local function frame_titles(getter)
    local out = {}
    for i = 1, MAX_FRAME_QUESTS do
        local title = safe(function() return getter(i) end)
        if type(title) ~= "string" or title == "" then
            break
        end
        out[i] = title
    end
    return out
end

--- Index of `want` in `titles`, or nil.
---
--- Quest names in the data files are English and the client may not be, so an
--- exact match is tried first, then a case-insensitive one. A single-entry list
--- needs no match at all - there is only one thing it can be, which keeps the
--- common case working in every locale.
local function index_of_title(titles, want)
    local n = 0
    for _ in pairs(titles) do n = n + 1 end
    if n == 0 then
        return nil
    end
    if n == 1 then
        return 1
    end
    if type(want) ~= "string" or want == "" then
        return nil
    end
    for i, t in pairs(titles) do
        if t == want then return i end
    end
    local lower = want:lower()
    for i, t in pairs(titles) do
        if t:lower() == lower then return i end
    end
    return nil
end

local warned_frame = {}
local function warn_once(key, fmt, ...)
    if warned_frame[key] then return end
    warned_frame[key] = true
    core.log_warning(string.format("[Master Farmer - Grindbot] " .. fmt, ...))
end

local function gossip_open()
    if izi.gossip and type(izi.gossip.is_open) == "function" then
        if safe(function() return izi.gossip.is_open() end) == true then
            return true
        end
    end
    return safe(function() return core.quests.is_gossip_frame_shown() end) == true
end

local function gossip_close()
    if izi.gossip and type(izi.gossip.close) == "function" then
        pcall(function()
            izi.gossip.close()
        end)
    end
    pcall(function()
        core.quests.close_gossip()
    end)
end

function npc.name_of(player, npc_id)
    if not player or not npc_id then
        return nil
    end
    local unit = targeting.find_npc(player, npc_id, 80)
    if not unit then
        return nil
    end
    local name = safe(function() return unit:get_name() end)
    if type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

function npc.go_and_interact(player, npc_id, dest)
    local unit = targeting.find_npc(player, npc_id, 80)
    if unit then
        local d = safe(function() return player:distance_to(unit) end) or 99
        if d > 4 then
            local p = safe(function() return unit:get_position() end) or dest
            movement.nav_to(p)
            return false
        end
        movement.nav_stop()
        if izi.now() < state.quest.interact_until then
            return false
        end
        state.quest.interact_until = izi.now() + 1.2
        pcall(function()
            core.input.interact_with_object(unit)
        end)
        return true
    end
    if dest then
        if movement.arrived(dest, 4) then
            return false
        end
        movement.nav_to(dest)
    end
    return false
end

--- Accept `quest_id`, whichever frame the NPC is showing.
--- `quest_name` is the title from the quest data, used only to disambiguate a
--- greeting frame that lists more than one quest.
function npc.accept(quest_id, quest_name)
    local selected = false

    if gossip_open() then
        local list = safe(function() return core.quests.get_gossip_available_quests() end)
        if type(list) == "table" then
            for i = 1, #list do
                if list[i].quest_id == quest_id then
                    pcall(function()
                        core.quests.select_gossip_available_quest(quest_id)
                    end)
                    selected = true
                    break
                end
            end
        end
    end

    -- No gossip frame, or the quest was not in it: this is the quest greeting
    -- frame, which is keyed by index rather than by quest id.
    if not selected then
        local titles = frame_titles(function(i) return core.quests.get_available_title(i) end)
        local idx = index_of_title(titles, quest_name)
        if idx then
            pcall(function() core.quests.select_available_quest(idx) end)
            selected = true
        elseif next(titles) ~= nil then
            warn_once("avail:" .. tostring(quest_id),
                "Quest %s is not one of the %d quests this NPC is offering by that name - "
                .. "the quest data name may not match the client's locale.",
                tostring(quest_name or quest_id), #titles)
        end
    end

    pcall(function()
        core.quests.accept_quest()
    end)
    -- Escort and other auto-accept quests raise a second confirmation popup;
    -- without this they sit on screen and the bot never starts them.
    pcall(function()
        core.quests.confirm_accept_quest()
    end)
end

--- Reward choice index to take, or nil when the quest offers no choice.
---
--- get_quest_item_link("choice", i) returns "" past the last choice, so the
--- list ends itself. When there is a choice the most valuable one is taken -
--- something has to be picked, and vendor price is the only ranking that means
--- anything to a grind bot.
local MAX_REWARD_CHOICES = 10

local function best_reward_choice()
    local best_idx, best_value = nil, -1
    for i = 1, MAX_REWARD_CHOICES do
        local link = safe(function() return core.quests.get_quest_item_link("choice", i) end)
        if type(link) ~= "string" or link == "" then
            break
        end
        local value = 0
        local info = safe(function() return core.quests.get_item_info(link) end)
        if type(info) == "table" and type(info.sell_price) == "number" then
            value = info.sell_price
        end
        if value > best_value then
            best_idx, best_value = i, value
        end
    end
    return best_idx
end

--- Hand in `quest_id`, whichever frame the NPC is showing.
function npc.turn_in(quest_id, quest_name)
    local selected = false

    if gossip_open() then
        local list = safe(function() return core.quests.get_gossip_active_quests() end)
        if type(list) == "table" then
            for i = 1, #list do
                if list[i].quest_id == quest_id then
                    pcall(function()
                        core.quests.select_gossip_active_quest(quest_id)
                    end)
                    selected = true
                    break
                end
            end
        end
        if not selected then
            -- Older behaviour: ask for it by id even when the list did not come
            -- back, which costs nothing and still works on most NPCs.
            pcall(function()
                core.quests.select_gossip_active_quest(quest_id)
            end)
            selected = true
        end
    end

    if not selected then
        local titles = frame_titles(function(i) return core.quests.get_active_title(i) end)
        local idx = index_of_title(titles, quest_name)
        if idx then
            pcall(function() core.quests.select_active_quest(idx) end)
        elseif next(titles) ~= nil then
            warn_once("active:" .. tostring(quest_id),
                "Quest %s is not among the %d quests this NPC will take back by that name - "
                .. "the quest data name may not match the client's locale.",
                tostring(quest_name or quest_id), #titles)
        end
    end

    -- complete_quest and get_quest_reward are alternatives, never a sequence.
    -- get_quest_reward(i) both picks choice i and completes the quest.
    local choice = best_reward_choice()
    if choice then
        pcall(function()
            core.quests.get_quest_reward(choice)
        end)
    else
        pcall(function()
            core.quests.complete_quest()
        end)
    end
end

function npc.close()
    pcall(function()
        core.quests.close_quest()
    end)
    gossip_close()
end

function npc.is_complete(quest_id)
    pcall(function()
        core.quests.expand_quest_header(0)
    end)
    local n = safe(function() return core.quests.get_num_quest_log_entries() end) or 0
    for i = 1, n do
        local entry = safe(function() return core.quests.get_quest_log_title(i) end)
        if type(entry) == "table" and entry.quest_id == quest_id then
            if entry.is_complete == 1 then
                return true
            end
            local boards = safe(function() return core.quests.get_num_quest_leader_boards(i) end) or 0
            if boards > 0 then
                local all = true
                for b = 1, boards do
                    local obj = safe(function() return core.quests.get_quest_log_leader_board(b, i) end)
                    if not (type(obj) == "table" and obj.is_completed == true) then
                        all = false
                    end
                end
                return all
            end
            return false
        end
    end
    local gossip = safe(function() return core.quests.get_gossip_active_quests() end)
    if type(gossip) == "table" then
        for i = 1, #gossip do
            if gossip[i].quest_id == quest_id and gossip[i].is_complete == true then
                return true
            end
        end
    end
    return false
end

return npc
