-- ============================================================================
-- restedXP_questing
-- lootorder.lua - the order a loot window's slots are taken in
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.12.0
-- ============================================================================
-- 4.12.0 (improvement 8 of the API-dump review): QUEST ITEMS FIRST. Every loot
-- loop of this product takes the slots in LO.order(n) instead of 0..n-1:
--   1. quest items  core.game_ui.get_loot_item_id(slot) -> core.quests.
--                   get_item_info(id): class_id 12 or item_type "Quest"
--   2. gold         core.game_ui.get_loot_is_gold(slot)
--   3. the rest, in slot order
-- With the bags nearly full the quest item is the one that gets the slot.
-- Slots are 0 based (.api: get_loot_item_count / get_loot_item_id). An item
-- whose info cannot be read is "the rest"; the class is cached per item id.
-- Never errors: anything unreadable keeps the plain order.
-- ============================================================================

local LO = {}
LO.QUEST_CLASS = 12

local class_of = {}           -- item id -> "quest" | "other"

local function call(f, ...)
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

function LO.is_quest_item(id)
    id = tonumber(id)
    if not id or id <= 0 then return false end
    local c = class_of[id]
    if c == nil then
        local q = core and core.quests
        local info = q and call(q.get_item_info, id) or nil
        if type(info) == "table" and (tonumber(info.class_id) == LO.QUEST_CLASS or info.item_type == "Quest") then
            c = "quest"
        elseif type(info) == "table" and info.name then
            c = "other"
        end
        if c then class_of[id] = c end           -- an empty answer is asked again next time
    end
    return c == "quest"
end

--- The slots 0 .. n-1 in the order to loot them (a new list each call).
function LO.order(n)
    n = tonumber(n) or 0
    local quest, gold, rest = {}, {}, {}
    local ui = core and core.game_ui
    for i = 0, n - 1 do
        local is_gold = ui and call(ui.get_loot_is_gold, i) == true
        if is_gold then
            gold[#gold + 1] = i
        else
            local id = ui and call(ui.get_loot_item_id, i) or nil
            if LO.is_quest_item(id) then quest[#quest + 1] = i else rest[#rest + 1] = i end
        end
    end
    local out = quest
    for i = 1, #gold do out[#out + 1] = gold[i] end
    for i = 1, #rest do out[#out + 1] = rest[i] end
    return out
end

function LO._reset() class_of = {} end

return LO
