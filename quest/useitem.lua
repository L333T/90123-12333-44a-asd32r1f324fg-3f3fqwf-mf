-- ============================================================================
-- restedXP_questing
-- quest/useitem.lua - the guide's RXP_PICK objects; quest items only at them
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.28.0
-- Folder: restedXP_questing
-- ============================================================================
-- 4.3.0 (in-game log 2026-10-24 20:01, Eastern Plaguelands): "Plagueland
-- Termites" (quest 5903) stayed 0/100 - the Empty Termite Jar (15042) was
-- never used. RestedXP's quest-item button takes it from
-- addon.questCompleteItems (data/rxp_targets.lua M.use_items).
--
-- 4.4.0 (user rule): A QUEST ITEM IS NEVER USED UNLESS THE OBJECT IT IS FOR IS
-- IN SIGHT. The TBC guide (Guides/tbc/A-58Boost.lua) says "Open the
-- |cRXP_PICK_Large Termite Mounds|r ... Loot them": the step's RXP_PICK names
-- (data/rxp_targets.lua M.picks, guide.pick_names) are the objects. The 4.3.0
-- "first use where it stands" probe is gone. With no object named for the
-- step (and none learnt), the item is not used here.
--
-- 4.4.1 (user, 2026-10-24): "the termite jar is not used, player just needs
-- to interact with the termite mound". U.goal never uses an item: it OPENS
-- the step's RXP_PICK object, nothing else.
--
-- U.goal - a collect / object goal whose step names RXP_PICK objects:
--   * the nearest visible one (exact name, so a small "Termite Mound" is not
--     a "Large Termite Mound") within SCAN yd is walked to (USE_NEAR yd); none
--     in sight: false - the route walk goes on;
--   * there: stop, dismount (no remount for NO_MOUNT_S), open it (use_object,
--     the entry point for world objects); its loot window is looted by the
--     engine's object goal; opened again every WAIT_LOOT s;
--   * TRIES opens with no change in the goal's count: the object is skipped
--     for SKIP_S s.
-- U.spot - a ".use" goal (kind "item") of a RestedXP quest-complete item, with
-- RXP_PICK objects named for the step, waits until one is in reach.
-- Public: U.goal, U.spot, U.item_for, U.reset.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")
local state = require("state")
local movement = require("movement")
local guide = require("quest/guide")
local QO = require("quest/objects")     -- 4.5.0: quest objects by id

local U = {}

U.SCAN = 60           -- yd: objects of the step's names looked for this far
U.USE_NEAR = 3.5      -- yd: opened / used from this close
U.USE_CLOSE = 2.0     -- 4.27.0: yd after use_object was not accepted (never interact_with_object)
U.WAIT_LOOT = 1.5     -- s an open waits for its loot window
U.WAIT_USE = 1.5      -- s after a use (and its cast) before the next cycle
U.TRIES = 3           -- cycles at one object without the count moving
U.SKIP_S = 120        -- s an object that gave nothing is skipped
U.NO_MOUNT_S = 20     -- s no mount while working the objects

local learnt = {}     -- item id -> lower-case name from "Requires <name>"
local skip = {}       -- object guid -> until
local cur = { guid = nil, phase = nil, t = 0, cycles = 0, count = nil }
local next_t = 0
local said = {}       -- item id -> true: "no object named" logged

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
end

local function trail(tag, fmt, ...)
    local el = package.loaded["errorlog"]
    if type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, tag, fmt, ...) end
end

local names = {}      -- item id -> name (core.quests.get_item_info), for the log
local function iname(id)
    if names[id] == nil then
        local info = safe(function() return core.quests.get_item_info(id) end)
        names[id] = (type(info) == "table" and type(info.name) == "string" and info.name ~= "")
            and info.name or ("item " .. tostring(id))
    end
    return names[id]
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

--- Lower-case object names the item is for: the step's RXP_PICK names, then a learnt one.
local function spots(goal, item)
    local out = {}
    local names = type(guide.pick_names) == "function" and guide.pick_names(goal) or {}
    for i = 1, #names do out[#out + 1] = string.lower(names[i]) end
    if item and learnt[item] then out[#out + 1] = learnt[item] end
    return out
end

--- The nearest visible object of these names, not skipped, within SCAN yd.
local function nearest(player, needles, now)
    for g, t in pairs(skip) do if now >= t then skip[g] = nil end end
    local best, bd, bn = nil, nil, nil
    for i = 1, #needles do
        local o, d = guide.find_named_object(player, U.SCAN, needles[i], skip)
        if o and type(d) == "number" and (not bd or d < bd) then best, bd, bn = o, d, needles[i] end
    end
    return best, bd, bn
end

local function count_of(label)
    return tonumber(tostring(label or ""):match("(%d+)%s*/%s*%d+"))
end

local function ev() return package.loaded["events"] end

local function since(name, t)
    local e = ev()
    return type(e) == "table" and type(e.since) == "function" and e.since(name, t) == true
end

local function loot_open()
    local n = safe(function() return core.game_ui.get_loot_item_count() end)
    return type(n) == "number" and n > 0
end

--- Stand still and off the mount next to the object. True while not yet standing.
local function settle(player, label)
    movement.nav_stop()
    if safe(function() return player:is_mounted() end) == true then
        pcall(core.input.dismount)
        next_t = izi.now() + 0.6
        state.set_note("Quest", "Guide: dismount for " .. label)
        return true
    end
    if movement.is_moving() then
        state.set_note("Quest", "Guide: stopping for " .. label)
        return true
    end
    return false
end

--- Walk to the object (true while walking).
local function approach(obj, d, name, label, walk_to)
    local near = cur.close and U.USE_CLOSE or U.USE_NEAR          -- 4.27.0: closer after a refusal
    if type(d) ~= "number" or d <= near then return false end
    local p = safe(function() return obj:get_position() end)
    if p and type(walk_to) == "function" and walk_to(p, label, math.max(1.0, near - 1.0), true) then
        state.set_note("Quest", string.format("Guide: to the %s (%.0f yd) for %s", name, d, label))
        return true
    end
    return false
end

--- One tick of a collect / object goal whose step names RXP_PICK objects
--- ("Open the Large Termite Mounds ... Loot them"): open the nearest one and
--- let the object goal loot it. 4.4.1: NO ITEM IS USED HERE - RestedXP's
--- quest-item list (M.use_items) is only its item button; the Empty Termite
--- Jar is never used, the mound is just opened (user, 2026-10-24).
--- True when the tick was spent here.
function U.goal(player, goal, kind, wps, label, walk_to)
    -- 4.5.0: the goal's quest object ids (data/quest_objects) - an "explore /
    -- event" objective (kind goto) done at an object counts too
    local ids = QO.objective_ids(goal)
    local has_ids = next(ids) ~= nil
    if kind ~= "collect" and kind ~= "object" and not (kind == "goto" and has_ids) then return false end
    if loot_open() then return false end                 -- the object goal loots it
    if safe(function() return player:is_in_combat() end) == true then return false end
    local needles = spots(goal, nil)
    if #needles == 0 and not has_ids then return false end
    local now = izi.now()
    if safe(function() return player:is_channeling_or_casting() end) == true then
        if cur.phase == "opened" then cur.t = now end    -- an "Opening" cast: its loot comes after it
        state.set_note("Quest", "Guide: opening for " .. label)
        return true
    end
    for g, t in pairs(skip) do if now >= t then skip[g] = nil end end
    -- by id first (exact), then by the guide's RXP_PICK name
    local obj, d, name = nil, nil, nil
    if has_ids then obj, d, name = QO.nearest(player, ids, U.SCAN, skip) end
    if not obj and #needles > 0 then obj, d, name = nearest(player, needles, now) end
    if not obj then return false end                     -- route walk: the next one comes into sight
    name = string.lower(tostring(name))
    local mt = package.loaded["movement/mount"]
    if mt and type(mt.suppress) == "function" then pcall(mt.suppress, U.NO_MOUNT_S) end

    local guid = safe(function() return obj:get_guid() end)
    local c = count_of(label)
    if guid ~= cur.guid then
        cur.guid, cur.phase, cur.cycles, cur.count, cur.close = guid, nil, 0, c, nil
    elseif c and cur.count and c > cur.count then
        cur.cycles, cur.count = 0, c
    end
    if cur.cycles >= U.TRIES then
        if guid then skip[guid] = now + U.SKIP_S end
        trail("act", "%s: opened %d times, the count did not move - next one", name, cur.cycles)
        cur.guid, cur.phase, cur.cycles = nil, nil, 0
        return true
    end
    if approach(obj, d, name, label, walk_to) then return true end
    if settle(player, label) then return true end
    if now < next_t then
        state.set_note("Quest", "Guide: at the " .. name .. " for " .. label)
        return true
    end
    if cur.phase == "opened" then
        cur.phase = nil
        cur.cycles = cur.cycles + 1
    end
    -- open it, as the guide says - 4.23.0: through quest/objguard (journalled; an
    -- object whose use_object crashed the game is interacted with instead, one that
    -- crashed both ways is skipped)
    local OG = require("quest/objguard")
    local sent, how = OG.open(obj)
    if not sent and how == "refused" then
        -- 4.27.0: not in reach yet - step closer (USE_CLOSE yd) and try again
        cur.close = true
        next_t = now + 0.5
        trail("act", "%s: use_object not accepted at %.1f yd - closing in", name, d or -1)
        return true
    end
    if not sent then
        if guid then skip[guid] = now + 3600 end
        trail("act", "%s: %s", name, tostring(how))
        state.set_note("Quest", "Guide: " .. name .. " crashed the game before - open it by hand")
        cur.guid, cur.phase, cur.cycles = nil, nil, 0
        return true
    end
    cur.phase, cur.t = "opened", now
    next_t = now + U.WAIT_LOOT
    trail("act", "open %s (%.1f yd, %s) for %s", name, d or -1, tostring(how), label)
    state.set_note("Quest", "Guide: open the " .. name .. " for " .. label)
    return true
end

local world_items = nil   -- item id -> true: RestedXP quest-complete items (used at a spot)
local function is_world_item(id)
    if not world_items then
        world_items = {}
        for _, it in pairs(rxp_items() or {}) do world_items[it] = true end
    end
    return id ~= nil and world_items[id] == true
end

--- A ".use" goal (kind "item") with bag entry `entry`: when the item is one of
--- RestedXP's quest-complete items (used at a spot in the world, not a bag
--- combine like Pamela's Doll) and RXP_PICK objects are named for the step,
--- it waits until one is in reach. nil = no gate (use as before), "walking",
--- "none" (none in sight - walk the route), "ok" (in reach, standing).
function U.spot(player, goal, label, walk_to, entry)
    local id = type(entry) == "table" and entry.object and safe(function() return entry.object:get_item_id() end) or nil
    if not is_world_item(id) then return nil end
    local needles = spots(goal, id)
    if #needles == 0 then return nil end
    local obj, d, name = nearest(player, needles, izi.now())
    if not obj then
        state.set_note("Quest", "Guide: looking for a " .. tostring(needles[1]) .. " for " .. label)
        return "none"
    end
    if approach(obj, d, name, label, walk_to) then return "walking" end
    if settle(player, label) then return "walking" end
    return "ok"
end

function U.reset()
    cur.guid, cur.phase, cur.t, cur.cycles, cur.count = nil, nil, 0, 0, nil
    next_t = 0
end

--- Test hooks.
function U._state() return { learnt = learnt, skip = skip, cur = cur } end
function U._wipe()
    for k in pairs(learnt) do learnt[k] = nil end
    for k in pairs(skip) do skip[k] = nil end
    for k in pairs(said) do said[k] = nil end
    world_items = nil
    U.reset()
end

return U
