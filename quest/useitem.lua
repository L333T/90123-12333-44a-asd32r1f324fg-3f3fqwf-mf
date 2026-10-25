-- ============================================================================
-- restedXP_questing
-- quest/useitem.lua - RestedXP quest items (the quest-item button's item)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.3.0
-- Folder: restedXP_questing
-- ============================================================================
-- 4.3.0 (in-game log 2026-10-24 20:01, Eastern Plaguelands): "Plagueland
-- Termites" (quest 5903) stayed 0/100 - the bot rode the guide's route past
-- the termite mounds and never used the Empty Termite Jar (15042). RestedXP
-- does not put a .use line on that step: its quest-item button takes the item
-- from addon.questCompleteItems (DB/tbc/quest.lua), now generated into
-- data/rxp_targets.lua M.use_items (quest id -> item id).
--
-- For a kill / collect / object goal whose quest has such an item in the
-- bags, near the goal's waypoints (AREA yd):
--   * the spot the item needs is learnt from the game: the first use is made
--     where the character stands, and a "Requires <name>" refusal
--     (UI_ERROR_MESSAGE) names the object (a spell focus such as "Termite
--     Mound"). Learnt once per item for the session.
--   * with a spot known: the nearest visible object of that name within SCAN
--     yd is walked to (within USE_NEAR yd), the character dismounts and uses
--     the item; no new mount while it works the area. An object used TRIES
--     times with no change in the goal's count is skipped for SKIP_S s.
--     No such object in sight: false - the guide's route walk goes on and
--     the next one comes into sight.
--   * no refusal: the item works where it is used - used every GAP s.
--   * any other refusal (a target needed, ...): left to the engine's own
--     item / marked-unit handling, probed again after PROBE_RETRY s.
-- Public: U.goal(player, goal, kind, wps, label, walk_to) -> true when this
-- tick was spent on it; U.item_for(goal); U.reset().
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")
local state = require("state")
local movement = require("movement")
local guide = require("quest/guide")

local U = {}

U.AREA = 150          -- yd from a goal waypoint / route point: the item's area
U.SCAN = 60           -- yd: objects of the learnt name looked for this far
U.USE_NEAR = 3.5      -- yd: used from this close to the object
U.GAP = 2.5           -- s between two uses
U.WAIT_ERR = 1.5      -- s a use waits for its refusal before it counts
U.TRIES = 3           -- uses at one object without the count moving
U.SKIP_S = 120        -- s an object that gave nothing is skipped
U.PROBE_RETRY = 60    -- s before a refused (not "Requires") item is probed again
U.NO_MOUNT_S = 20     -- s no mount while working the area

local focus = {}      -- item id -> lower-case object name, or false = works anywhere
local refused = {}    -- item id -> izi.now() of a refusal that names no object
local skip = {}       -- object guid -> until
local cur = { guid = nil, uses = 0, count = nil }
local pend = nil      -- { item, t } a use waiting for its refusal
local next_t = 0

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
end

local function trail(tag, fmt, ...)
    local el = package.loaded["errorlog"]
    if type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, tag, fmt, ...) end
end

local function rxp_items()
    local ok, d = pcall(require, "data/rxp_targets")
    return ok and type(d) == "table" and type(d.use_items) == "table" and d.use_items or nil
end

--- The bag entry for item `id`, or nil.
local function bag_entry(id)
    for bag = 0, 4 do
        local items = safe(function() return core.inventory.get_items_in_bag(bag) end)
        if type(items) == "table" then
            for i = 1, #items do
                local e = items[i]
                if type(e) == "table" and e.object
                    and safe(function() return e.object:get_item_id() end) == id then
                    return e
                end
            end
        end
    end
    return nil
end

--- The RestedXP quest item for this goal's quest(s) and its bag entry, or nil.
function U.item_for(goal)
    local map = rxp_items()
    if not map or type(goal) ~= "table" then return nil end
    local ids = type(guide.goal_quest_ids) == "function" and guide.goal_quest_ids(goal) or nil
    if type(ids) ~= "table" or #ids == 0 then ids = { goal.quest_id } end
    for i = 1, #ids do
        local item = map[tonumber(ids[i]) or -1]
        if item then
            local e = bag_entry(item)
            if e then return item, e end
        end
    end
    return nil
end

--- Within AREA yd of any of the goal's waypoints / route points.
local function in_area(player, goal, kind, wps)
    local me = safe(function() return player:get_position() end)
    if not me then return false end
    local pts = wps
    if type(guide.route) == "function" then pts = guide.route(goal, kind, wps) or wps end
    for _, list in ipairs({ wps, pts }) do
        if type(list) == "table" then
            for i = 1, #list do
                local p = list[i] and list[i].pos
                if p and type(p.x) == "number" then
                    local dx, dy = p.x - me.x, p.y - me.y
                    if dx * dx + dy * dy <= U.AREA * U.AREA then return true end
                end
            end
        end
    end
    return false
end

--- The "N/M" count in the goal text, for "did the use bring anything".
local function count_of(label)
    local a = tostring(label or ""):match("(%d+)%s*/%s*%d+")
    return tonumber(a)
end

--- The refusal text since `t`, or nil.
local function refusal_since(t)
    local ev = package.loaded["events"]
    if type(ev) ~= "table" or type(ev.since) ~= "function" or not ev.since("UI_ERROR_MESSAGE", t) then return nil end
    local txt = ev.ui and ev.ui.error_text
    return type(txt) == "string" and txt or ""
end

local function use(entry)
    return guide.use_bag_item(entry, nil) == true
end

local function stand_and_use(player, item, entry, label)
    movement.nav_stop()
    if safe(function() return player:is_mounted() end) == true then
        pcall(core.input.dismount)
        next_t = izi.now() + 0.6
        state.set_note("Quest", "Guide: dismount to use the item for " .. label)
        return true
    end
    if movement.is_moving() then
        state.set_note("Quest", "Guide: stopping to use the item for " .. label)
        return true
    end
    local now = izi.now()
    if use(entry) then
        pend = { item = item, t = now }
        next_t = now + U.GAP
        state.set_note("Quest", "Guide: use the quest item for " .. label)
    else
        next_t = now + U.GAP
        state.set_note("Quest", "Guide: could not use the quest item for " .. label)
    end
    return true
end

--- One tick of a goal with a RestedXP quest item. True when the tick was spent here.
function U.goal(player, goal, kind, wps, label, walk_to)
    if kind ~= "kill" and kind ~= "collect" and kind ~= "object" then return false end
    local item, entry = U.item_for(goal)
    if not item then return false end
    local now = izi.now()

    -- a use waiting for its answer: a "Requires X" refusal names the spot
    if pend and pend.item == item then
        local txt = refusal_since(pend.t)
        if txt then
            local need = txt:match("^[Rr]equires (.+)$")
            pend = nil
            if need and need ~= "" then
                need = need:gsub("%.$", "")
                if focus[item] ~= need:lower() then
                    trail("act", "quest item %d needs %s - looking for one", item, need)
                end
                focus[item] = need:lower()
            elseif focus[item] == nil then
                refused[item] = now
                trail("act", "quest item %d refused here (%s) - left to the target / item handling for %d s",
                    item, txt, U.PROBE_RETRY)
                return false
            end
        elseif now - pend.t >= U.WAIT_ERR then
            if focus[item] == nil then
                focus[item] = false
                trail("act", "quest item %d works where it is used", item)
            end
            pend = nil
        else
            state.set_note("Quest", "Guide: use the quest item for " .. label)
            return true
        end
    end

    if refused[item] and (now - refused[item]) < U.PROBE_RETRY then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    if safe(function() return player:is_channeling_or_casting() end) == true then
        state.set_note("Quest", "Guide: using the quest item for " .. label)
        return true
    end
    if not in_area(player, goal, kind, wps) then return false end
    local mt = package.loaded["movement/mount"]
    if mt and type(mt.suppress) == "function" then pcall(mt.suppress, U.NO_MOUNT_S) end

    local need = focus[item]
    if need == nil or need == false then
        -- first use (learns the spot), or the item works anywhere
        if now < next_t then
            state.set_note("Quest", "Guide: use the quest item for " .. label)
            return true
        end
        if need == nil then trail("act", "quest item %d: first use here (to learn where it works)", item) end
        return stand_and_use(player, item, entry, label)
    end

    for g, t in pairs(skip) do if now >= t then skip[g] = nil end end
    local obj, d = guide.find_named_object(player, U.SCAN, need, skip)
    if not obj then return false end
    local guid = safe(function() return obj:get_guid() end)
    local c = count_of(label)
    if guid ~= cur.guid then
        cur.guid, cur.uses, cur.count = guid, 0, c
    elseif c and cur.count and c > cur.count then
        cur.uses, cur.count = 0, c
    end
    if cur.uses >= U.TRIES then
        if guid then skip[guid] = now + U.SKIP_S end
        trail("act", "%s: %d uses, the count did not move - next one", need, cur.uses)
        cur.guid, cur.uses = nil, 0
        return true
    end
    if type(d) == "number" and d > U.USE_NEAR then
        local p = safe(function() return obj:get_position() end)
        if p and type(walk_to) == "function" and walk_to(p, label, U.USE_NEAR - 1.0, true) then
            state.set_note("Quest", string.format("Guide: to the %s (%.0f yd) for %s", need, d, label))
            return true
        end
    end
    if now < next_t then
        state.set_note("Quest", "Guide: use the quest item for " .. label)
        return true
    end
    cur.uses = cur.uses + 1
    return stand_and_use(player, item, entry, label)
end

function U.reset()
    cur.guid, cur.uses, cur.count = nil, 0, nil
    pend, next_t = nil, 0
end

--- Test hook.
function U._state() return { focus = focus, refused = refused, skip = skip, cur = cur } end
function U._wipe()
    for k in pairs(focus) do focus[k] = nil end
    for k in pairs(refused) do refused[k] = nil end
    for k in pairs(skip) do skip[k] = nil end
    U.reset()
end

return U
