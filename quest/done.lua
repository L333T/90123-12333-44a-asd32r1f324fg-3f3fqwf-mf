-- ============================================================================
-- restedXP_questing
-- quest/done.lua - the quests this character has completed (one set)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.11.0
-- ============================================================================
-- 4.11.0 (improvement 4 of the API-dump review): core.game_ui.
-- get_all_completed_quest_ids() answers every completed quest id in ONE call
-- (109 on the 2026-10-24 dump). Read into a set at most every GAP s, and at
-- once after a QUEST_TURNED_IN event (events.ui.QUEST_TURNED_IN newer than the
-- read). Without that call (or before its first answer) each id falls back to
-- core.quests.is_quest_flagged_completed.
-- D.done(id) -> true / false; D.skip(goal, kind) -> true when every quest the
-- goal works for is completed and none is in the log - the guide step's goal
-- is then skipped (quest/engine, quest/guide). Accepts are not decided here
-- (the accept check asks D.done itself). An item goal (.use) carries item ids
-- in goal.ids, so only goal.quest_id counts for every kind but a turn-in.
-- ============================================================================

local D = {}
D.GAP = 10
D.KINDS = { turnin = true, kill = true, collect = true, object = true, item = true, talk = true,
    complete = true, objective = true }

local set, read_t, count = nil, -1e9, 0

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    local ok2, t = pcall(function() return ok and izi.now() or core.time() end)
    return (ok2 and type(t) == "number") and t or 0
end

local function turned_in_since(t)
    local ev = package.loaded["events"]
    local ui = type(ev) == "table" and ev.ui or nil
    local at = type(ui) == "table" and ui.QUEST_TURNED_IN or nil
    return type(at) == "number" and at >= t
end

function D.refresh()
    read_t = now()
    local ok, list = pcall(function() return core.game_ui.get_all_completed_quest_ids() end)
    if ok and type(list) == "table" then
        local s, n = {}, 0
        for _, v in pairs(list) do
            local id = tonumber(v)
            if id then s[id] = true n = n + 1 end
        end
        set, count = s, n
    end
    return set ~= nil
end

function D.done(id)
    id = tonumber(id)
    if not id or id <= 0 then return false end
    if set == nil or (now() - read_t) >= D.GAP or turned_in_since(read_t) then D.refresh() end
    if set then return set[id] == true end
    local ok, v = pcall(function() return core.quests.is_quest_flagged_completed(id) end)
    return ok and v == true
end

function D.count() return count end

local function in_log(id)
    local ok, v = pcall(function() return core.quests.is_on_quest(id) end)
    return ok and v == true
end

--- The quest ids a goal works for (see the header), or {}.
function D.goal_ids(goal, kind)
    if type(goal) ~= "table" then return {} end
    local out = {}
    local q = tonumber(goal.quest_id)
    if q and q > 0 then out[1] = q end
    if kind == "turnin" and type(goal.ids) == "table" then
        for i = 1, #goal.ids do
            local id = tonumber(goal.ids[i])
            if id and id > 0 and id ~= q then out[#out + 1] = id end
        end
    end
    return out
end

--- True when the goal is for completed quests only (none in the log).
function D.skip(goal, kind)
    if not D.KINDS[kind] then return false end
    local ids = D.goal_ids(goal, kind)
    if #ids == 0 then return false end
    for i = 1, #ids do
        if in_log(ids[i]) or not D.done(ids[i]) then return false end
    end
    return true, ids
end

function D._reset() set, read_t, count = nil, -1e9, 0 end

return D
