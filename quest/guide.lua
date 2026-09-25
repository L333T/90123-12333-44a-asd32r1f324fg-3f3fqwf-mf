-- ============================================================================
-- Master Farmer - Grindbot
-- Guide adapter - RestedXP
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.17.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Turns core.addons.rested_xp into the shapes quest/engine understands:
-- somewhere to walk, something to kill, or an NPC to talk to.
--
-- The guide decides WHAT to do. This file only reads it; the engine does the
-- doing, with the same helpers the catalog path uses.
--
-- WHY THIS IS NAME-ORIENTED AND NOT ID-ORIENTED
--   RestedXP does not carry creature or object ids for the actions a bot
--   acts on. Read from the addon itself:
--
--     accept / turnin elements hold questId, title and text. No NPC.
--     collect holds questId, id (the ITEM), itemName, qty.
--     element.ids is set only by daily, dailyturnin, abandon, petfamily,
--       areapoiexists, areapoiguide, questcount, cast, itemcount and
--       isQuestOffered - never by accept, turnin, collect or mob.
--     mob / target / unitscan keep element.mobs and element.unitlist, and
--       CheckNpcIds rewrites those entries to NAME strings on an English
--       client, keeping a numeric id only when no name resolves.
--
--   So the targets arrive as text. Matching is therefore by name, through
--   targeting.find_named and the name paths below. goal.ids IS read where it
--   is present, because a numeric id is better than a name when offered -
--   but nothing here depends on it being there.
--
-- WAYPOINTS ARE MAP COORDINATES
--   x and y are 0-1, relative to the map. coords_helper:map_to_world converts
--   them. A waypoint with map_id 0, or with wrong_continent set, is refused:
--   its dist is meaningless across a continent boundary and walking at it
--   would send the character at a wall for as long as the step lasts.
--
-- EVERYTHING IS OPTIONAL
--   The addon may not be installed, may have no guide loaded, and this whole
--   namespace may be missing on an older build. Every call is wrapped and
--   every accessor answers "nothing to do" rather than throwing, because this
--   runs inside the quest tick.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

local guide = {}

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

--- The addon namespace, or nil when this build has no core.addons.rested_xp.
local function api()
    local ns = safe(function()
        return core.addons.rested_xp
    end)
    if type(ns) ~= "table" then
        return nil
    end
    return ns
end

-- ============================================================================
-- AVAILABILITY
-- ============================================================================

--- Is the addon installed and running?
function guide.is_loaded()
    local ns = api()
    if not ns or type(ns.is_loaded) ~= "function" then
        return false
    end
    return safe(function() return ns.is_loaded() end) == true
end

--- Is there a guide step to follow right now?
---
--- has_current_step is the documented test. An empty get_current_step is not
--- the same question and must not be used in its place.
function guide.ready()
    if not guide.is_loaded() then
        return false
    end
    local ns = api()
    if type(ns.has_current_step) ~= "function" then
        return false
    end
    return safe(function() return ns.has_current_step() end) == true
end

-- ============================================================================
-- THE CURRENT STEP
-- ============================================================================

--- The raw step table, or nil.
function guide.step()
    if not guide.ready() then
        return nil
    end
    local ns = api()
    if type(ns.get_current_step) ~= "function" then
        return nil
    end
    local step = safe(function() return ns.get_current_step() end)
    if type(step) ~= "table" then
        return nil
    end
    return step
end

--- Sticky steps: persistent objectives shown alongside the current one.
--- The current step is not included in this list.
function guide.stickies()
    local out = {}
    if not guide.ready() then
        return out
    end
    local ns = api()
    if type(ns.get_current_stickies) ~= "function" then
        return out
    end
    local list = safe(function() return ns.get_current_stickies() end)
    if type(list) ~= "table" then
        return out
    end
    for i = 1, #list do
        if type(list[i]) == "table" then
            out[#out + 1] = list[i]
        end
    end
    return out
end

--- Normalise one goal into the fields this project reads.
---
--- Only the documented RestedXP fields are read: action, quest_id, text,
--- is_complete, text_only, ids. There is deliberately no npc_id, target_id,
--- npc or target here - RestedXP does not provide them, and inventing them
--- would be a lie the engine then acts on.
local function shape_goal(g, index)
    if type(g) ~= "table" then
        return nil
    end
    local ids = nil
    if type(g.ids) == "table" then
        ids = {}
        for i = 1, #g.ids do
            ids[i] = g.ids[i]
        end
    end
    return {
        action = (type(g.action) == "string") and g.action or "",
        quest_id = tonumber(g.quest_id),
        text = (type(g.text) == "string" and g.text ~= "") and g.text or nil,
        text_only = g.text_only == true,
        is_complete = g.is_complete == true,
        ids = ids,
        index = index,
    }
end

--- The first goal of the current step that is not finished yet.
---
--- The guide lists a step's goals in the order it wants them done, so the
--- first incomplete one is the instruction to follow. A step whose goals are
--- all complete returns nil; the addon moves on by itself.
function guide.goal()
    local step = guide.step()
    if not step then
        return nil
    end
    local goals = step.goals
    if type(goals) ~= "table" then
        return nil
    end
    for i = 1, #goals do
        local g = goals[i]
        if type(g) == "table" and g.is_complete ~= true then
            return shape_goal(g, i)
        end
    end
    return nil
end

-- ============================================================================
-- WHAT THE ENGINE SHOULD DO
-- ============================================================================
-- RestedXP declares 153 step functions. Only the ones a levelling bot can act
-- on are mapped; everything else falls to "goto", which walks to the step's
-- waypoint and lets the addon tick the goal off however it normally would.
-- Walking is the honest response to an instruction we do not understand.
local ACTIONS = {
    -- quest dialog
    accept          = "accept",
    acceptmultiple  = "accept",
    turnin          = "turnin",
    turninmultiple  = "turnin",

    -- speak to someone
    gossip          = "talk",
    gossipoption    = "talk",
    trainer         = "talk",
    vendor          = "talk",
    fp              = "talk",
    stable          = "talk",

    -- fight
    mob             = "kill",
    target          = "kill",
    unitscan        = "kill",
    rare            = "kill",

    -- move
    ["goto"]        = "goto",
    questgoto       = "goto",
    groundgoto      = "goto",
    flygoto         = "goto",
    waypoint        = "goto",
    zone            = "goto",
    home            = "goto",
    hs              = "goto",

    -- click a thing in the world
    treasure        = "object",
    openitem        = "object",

    -- end up holding N of something: a drop, a ground object or a purchase,
    -- and the goal does not say which, so both are tried
    collect         = "collect",
    collectmultiple = "collect",
    buy             = "collect",
    buyAll          = "collect",
    retrieveitem    = "collect",

    -- use something already carried
    ["use"]         = "item",
    usespell        = "item",
    addquestitem    = "item",
}

--- What kind of thing this goal is, in the engine's vocabulary.
function guide.classify(goal)
    if type(goal) ~= "table" then
        return "goto"
    end
    local a = goal.action
    if type(a) ~= "string" or a == "" then
        return "goto"
    end
    return ACTIONS[a] or ACTIONS[string.lower(a)] or "goto"
end

-- ============================================================================
-- TARGETS
-- ============================================================================

--- Everything the current step and its stickies are asking us to act on,
--- split into numeric ids and names.
---
--- ids come from goal.ids where the guide supplies them. names come from
--- goal.text, and from any string entry in goal.ids - RestedXP stores unit
--- lists as names on an English client, so a "numeric" id field can hold
--- either.
---
--- Returns two sets: ids keyed by number, names keyed by string.
function guide.targets()
    local ids, names = {}, {}

    local function take(g)
        if type(g) ~= "table" then
            return
        end
        if type(g.ids) == "table" then
            for i = 1, #g.ids do
                local v = g.ids[i]
                local n = tonumber(v)
                if n then
                    ids[n] = true
                elseif type(v) == "string" and v ~= "" then
                    names[v] = true
                end
            end
        end
        -- text is the on-screen line. It is the only target information the
        -- core actions carry, so it is a name candidate in its own right.
        if type(g.text) == "string" and g.text ~= "" then
            names[g.text] = true
        end
    end

    local step = guide.step()
    if type(step) == "table" and type(step.goals) == "table" then
        for i = 1, #step.goals do
            take(step.goals[i])
            -- The quest log words the same objective in the client's own
            -- terms, which is a tighter match than the guide's sentence.
            local g = step.goals[i]
            if type(g) == "table" and g.is_complete ~= true then
                local from_log = guide.objective_names(g.quest_id)
                for k = 1, #from_log do
                    names[from_log[k]] = true
                end
            end
        end
    end
    local stickies = guide.stickies()
    for i = 1, #stickies do
        local s = stickies[i]
        if type(s.goals) == "table" then
            for j = 1, #s.goals do
                take(s.goals[j])
            end
        end
    end

    return ids, names
end

-- ============================================================================
-- TARGET NAMES FROM THE QUEST LOG
-- ============================================================================
-- The guide's text is a sentence - "Collect 5 Bundles of Wood" - so matching
-- a unit name against it means a substring test, which is loose.
--
-- The quest log carries the same objective in the client's own words:
-- get_quest_log_leader_board returns "Kobold Vermin slain: 3/10". Stripping
-- the progress off the end leaves the creature or item name as the client
-- spells it, localised correctly, which is a far tighter thing to match on.
--
-- core.quests has no npc id anywhere - not in the log, the dialog, the gossip
-- lists or the trainer info - so this is names, not ids. It is the best
-- identity that API can give.

local log_cache = {}         -- quest_id -> { names = {...}, t = when }
local LOG_TTL = 5.0
local headers_expanded = false

--- The quest log index for a quest id, or nil.
---
--- Collapsed headers hide their quests from the log indices, so every header
--- is expanded once per session before the first walk. Once, not per tick:
--- it changes what the player sees in their own quest log.
local function log_index_of(quest_id)
    if not headers_expanded then
        headers_expanded = true
        pcall(function() core.quests.expand_quest_header(0) end)
    end
    local n = safe(function() return core.quests.get_num_quest_log_entries() end)
    if type(n) ~= "number" then
        return nil
    end
    for i = 1, n do
        local info = safe(function() return core.quests.get_quest_log_title(i) end)
        if type(info) == "table" and info.is_header ~= true
            and tonumber(info.quest_id) == quest_id then
            return i
        end
    end
    return nil
end

--- Strip the progress off an objective description.
---
--- "Kobold Vermin slain: 3/10" -> "Kobold Vermin slain"
--- "Bundle of Wood: 0/5"       -> "Bundle of Wood"
---
--- The trailing verb is left on. Matching asks whether the unit's name occurs
--- INSIDE the candidate, so "Kobold Vermin" still matches "Kobold Vermin
--- slain", and trying to strip verbs would mean a localised word list.
local function strip_progress(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local head = text:match("^(.*):%s*%d+%s*/%s*%d+%s*$")
    if head and head ~= "" then
        return head
    end
    return text
end

--- Objective names for a quest, as the client words them.
---
--- Finished objectives are skipped: their target is not wanted any more, and
--- including them sends the bot after mobs it has already killed enough of.
function guide.objective_names(quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id then
        return {}
    end

    local now = safe(function() return izi.now() end) or 0
    local hit = log_cache[quest_id]
    if hit and (now - hit.t) < LOG_TTL then
        return hit.names
    end

    local names = {}
    local idx = log_index_of(quest_id)
    if idx then
        local count = safe(function()
            return core.quests.get_num_quest_leader_boards(idx)
        end)
        if type(count) == "number" then
            for j = 1, count do
                local obj = safe(function()
                    return core.quests.get_quest_log_leader_board(j, idx)
                end)
                if type(obj) == "table" and obj.is_completed ~= true then
                    local name = strip_progress(obj.description)
                    if name then
                        names[#names + 1] = name
                    end
                end
            end
        end
    end

    log_cache[quest_id] = { names = names, t = now }
    return names
end

--- The target ids as an array, for callers that scan by id.
--- Often empty: see the header note on why RestedXP is name-oriented.
function guide.target_ids()
    local ids = guide.targets()
    local out = {}
    for id in pairs(ids) do
        out[#out + 1] = id
    end
    table.sort(out)
    return out
end

-- ============================================================================
-- OBJECTIVE PROGRESS
-- ============================================================================

--- Progress on one quest: { text, type, num_required, num_fulfilled, finished }.
---
--- Note the shape: this reports PROGRESS, not targets. A provider that
--- returned target ids from a call of this name would be a different API,
--- and this one needs the quest id the current goal carries. It
--- answers "how far along is this quest", which is a different question, and
--- it needs the quest id that the current goal carries.
function guide.objectives(quest_id)
    local out = {}
    quest_id = tonumber(quest_id)
    if not quest_id then
        return out
    end
    local ns = api()
    if not ns or type(ns.get_objectives) ~= "function" then
        return out
    end
    local list = safe(function() return ns.get_objectives(quest_id) end)
    if type(list) ~= "table" then
        return out
    end
    for i = 1, #list do
        local o = list[i]
        if type(o) == "table" then
            out[#out + 1] = {
                text = (type(o.text) == "string") and o.text or nil,
                type = (type(o.type) == "string") and o.type or nil,
                num_required = tonumber(o.num_required) or 0,
                num_fulfilled = tonumber(o.num_fulfilled) or 0,
                finished = o.finished == true,
            }
        end
    end
    return out
end

--- Does this quest still need work? False when every objective is finished,
--- and when the quest id is unusable or the guide reports nothing.
function guide.needs_progress(quest_id)
    local objectives = guide.objectives(quest_id)
    if #objectives == 0 then
        return false
    end
    for i = 1, #objectives do
        if not objectives[i].finished then
            return true
        end
    end
    return false
end

-- ============================================================================
-- FINDING THINGS IN THE WORLD
-- ============================================================================

--- The nearest visible game object this step wants, or nil.
---
--- Objects are not units: the mob scan will never return a chest or a herb,
--- so this walks the visible-object list itself. Matched on name first,
--- because that is what RestedXP supplies, and on id when one is offered.
function guide.find_object(player, range)
    if not player then
        return nil, nil
    end
    range = tonumber(range) or 30

    local ids, names = guide.targets()
    -- Nothing named means nothing to look for. Returning the nearest object
    -- of any kind would have the bot clicking scenery.
    if next(ids) == nil and next(names) == nil then
        return nil, nil
    end

    local list = safe(function() return core.object_manager.get_visible_objects() end)
    if type(list) ~= "table" then
        return nil, nil
    end

    local me = safe(function() return player:get_position() end)
    if not me then
        return nil, nil
    end

    local best, best_d = nil, nil
    for i = 1, #list do
        local o = list[i]
        if o and safe(function() return o:is_valid() end) ~= false then
            -- A unit is handled by the kill path; this is for everything else.
            if safe(function() return o:is_unit() end) ~= true then
                local want = false
                local oid = safe(function() return o:get_npc_id() end)
                if type(oid) == "number" and ids[oid] then
                    want = true
                end
                if not want then
                    local oname = safe(function() return o:get_name() end)
                    if type(oname) == "string" and oname ~= "" then
                        if names[oname] then
                            want = true
                        else
                            -- The guide's text is a sentence - "Collect 5
                            -- Bundles of Wood" - so an exact match will
                            -- usually fail. The object's own name appearing
                            -- inside it is the workable test.
                            local lower = string.lower(oname)
                            for n in pairs(names) do
                                if string.find(string.lower(n), lower, 1, true) then
                                    want = true
                                    break
                                end
                            end
                        end
                    end
                end
                if want then
                    local pos = safe(function() return o:get_position() end)
                    if pos then
                        local d = safe(function() return player:distance_to(o) end)
                        if type(d) ~= "number" then
                            local dx, dy, dz = me.x - pos.x, me.y - pos.y, (me.z or 0) - (pos.z or 0)
                            d = math.sqrt(dx * dx + dy * dy + dz * dz)
                        end
                        if d <= range and (best_d == nil or d < best_d) then
                            best, best_d = o, d
                        end
                    end
                end
            end
        end
    end
    return best, best_d
end

--- The nearest unit this step wants to fight, or nil.
---
--- Name-matched, because RestedXP's mob and target steps store their unit
--- lists as names. An id is used when the guide happens to supply one.
function guide.find_mob(player, range)
    if not player then
        return nil, nil
    end
    range = tonumber(range) or 40

    local ids, names = guide.targets()
    if next(ids) == nil and next(names) == nil then
        return nil, nil
    end

    local list = safe(function() return core.object_manager.get_visible_objects() end)
    if type(list) ~= "table" then
        return nil, nil
    end

    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_unit() end) == true
            and safe(function() return u:is_dead_or_ghost() end) ~= true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return player:can_attack(u) end) ~= false then

            local want = false
            local uid = safe(function() return u:get_npc_id() end)
            if type(uid) == "number" and ids[uid] then
                want = true
            end
            if not want then
                local uname = safe(function() return u:get_name() end)
                if type(uname) == "string" and uname ~= "" then
                    if names[uname] then
                        want = true
                    else
                        local lower = string.lower(uname)
                        for n in pairs(names) do
                            if string.find(string.lower(n), lower, 1, true) then
                                want = true
                                break
                            end
                        end
                    end
                end
            end

            if want then
                local d = safe(function() return player:distance_to(u) end)
                if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then
                    best, best_d = u, d
                end
            end
        end
    end
    return best, best_d
end

--- The npc id of whatever is currently targeted, or nil.
---
--- This is the one place a real creature id is available under RestedXP. The
--- guide never names an NPC - its accept and turnin elements carry questId,
--- title and text and nothing else - so every other path here matches on
--- name. A targeted unit can simply be asked.
---
--- get_target is a UNIT method, not an object_manager one: there is no
--- core.object_manager.get_target on this build. npc_id() and get_npc_id()
--- both exist, so both are tried.
---
--- An id of 0 means "not a creature" - a player, a pet, an object - and is
--- rejected rather than passed on as if it were real.
---
--- Returns id, unit.
function guide.target_npc_id(player)
    if not player then
        return nil, nil
    end
    local target = safe(function() return player:get_target() end)
    if not target then
        return nil, nil
    end
    if safe(function() return target:is_valid() end) ~= true then
        return nil, nil
    end

    local id = safe(function() return target:npc_id() end)
    if type(id) ~= "number" then
        id = safe(function() return target:get_npc_id() end)
    end
    if type(id) ~= "number" or id == 0 then
        return nil, target
    end
    return id, target
end

-- ============================================================================
-- LEARNING NPC IDS
-- ============================================================================
-- core.quests never reports an npc id, so one can only be read off a unit.
-- But the gossip frame says WHICH npc we are standing at: when it is open and
-- lists the quest we want, the thing we have targeted is that quest's giver.
--
-- That pairing is worth keeping. Learned once, an accept or turnin for the
-- same quest can go straight to a verified id on the next visit instead of
-- guessing by proximity.
--
-- In memory only, and small. Persisting it would mean a per-character file
-- whose entries can go stale when a guide is changed, for a saving of one
-- interaction.
local learned = {}           -- quest title -> npc id

--- Record the targeted npc as the giver of whatever the gossip frame lists.
---
--- Only called when the frame is actually open: without it there is nothing
--- confirming that the target has anything to do with the current goal.
--- Returns the id when one was learned.
function guide.learn_npc_id(player)
    if safe(function() return core.quests.is_gossip_frame_shown() end) ~= true then
        return nil
    end
    local id = guide.target_npc_id(player)
    if not id then
        return nil
    end

    local function record(list)
        if type(list) ~= "table" then
            return
        end
        for i = 1, #list do
            local q = list[i]
            if type(q) == "table" and type(q.title) == "string" and q.title ~= "" then
                learned[q.title] = id
            end
        end
    end
    record(safe(function() return core.quests.get_gossip_active_quests() end))
    record(safe(function() return core.quests.get_gossip_available_quests() end))
    return id
end

--- The npc id learned for a quest title, or nil.
---
--- Keyed on title because that is what the gossip frame gives on TBC - its
--- quest_id is a row index, not a quest id, and must never be stored.
function guide.known_npc_id(title)
    if type(title) ~= "string" or title == "" then
        return nil
    end
    return learned[title]
end

--- The nearest NPC that can be spoken to.
---
--- RestedXP names no NPC on an accept or turnin goal - those elements carry
--- questId, title and text and nothing else - so this is the primary way the
--- dialog branches find the quest giver, not a fallback. Once the bot is
--- standing where the guide sent it, the nearest unit it cannot attack is a
--- quest giver, a vendor or a guard rather than a mob.
---
--- Deliberately short ranged: it is a guess, and a guess is only reasonable
--- once standing where the guide pointed.
function guide.nearest_talkable(player, range)
    if not player then
        return nil, nil
    end
    range = tonumber(range) or 8

    local list = safe(function() return core.object_manager.get_visible_objects() end)
    if type(list) ~= "table" then
        return nil, nil
    end

    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_unit() end) == true
            and safe(function() return u:is_dead_or_ghost() end) ~= true
            and safe(function() return u:is_player() end) ~= true then
            if safe(function() return player:can_attack(u) end) == false then
                local d = safe(function() return player:distance_to(u) end)
                if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then
                    best, best_d = u, d
                end
            end
        end
    end
    return best, best_d
end

-- ============================================================================
-- FINDING THINGS IN THE BAGS
-- ============================================================================

--- The bag entry for an item this step wants, or nil.
---
--- Returns the entry as core.inventory.get_items_in_bag gives it - the object
--- and its slot - because core.input.use_item wants the object, not an id.
function guide.find_bag_item()
    local ids, names = guide.targets()
    if next(ids) == nil and next(names) == nil then
        return nil
    end

    for bag = 0, 4 do
        local items = safe(function() return core.inventory.get_items_in_bag(bag) end)
        if type(items) == "table" then
            for i = 1, #items do
                local entry = items[i]
                if type(entry) == "table" and entry.object then
                    local iid = safe(function() return entry.object:get_item_id() end)
                    if type(iid) == "number" and ids[iid] then
                        return entry
                    end
                    if type(iid) == "number" then
                        local info = safe(function() return core.quests.get_item_info(iid) end)
                        local iname = (type(info) == "table" and type(info.name) == "string")
                            and info.name or nil
                        if iname then
                            if names[iname] then
                                return entry
                            end
                            local lower = string.lower(iname)
                            for n in pairs(names) do
                                if string.find(string.lower(n), lower, 1, true) then
                                    return entry
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

--- Use a bag item. Returns true when a use was actually issued.
---
--- core.input has use_item, use_item_target and use_item_position and the
--- reflected reference does not record what they take, so the object is tried
--- first and the raw item id second. Returns false rather than claiming a
--- success nothing acted on.
function guide.use_bag_item(entry, target)
    if type(entry) ~= "table" or not entry.object then
        return false
    end
    local input = safe(function() return core.input end)
    if type(input) ~= "table" then
        return false
    end

    local iid = safe(function() return entry.object:get_item_id() end)

    if target and type(input.use_item_target) == "function" then
        if pcall(function() input.use_item_target(entry.object, target) end) then
            return true
        end
        if iid and pcall(function() input.use_item_target(iid, target) end) then
            return true
        end
    end
    if type(input.use_item) == "function" then
        if pcall(function() input.use_item(entry.object) end) then
            return true
        end
        if iid and pcall(function() input.use_item(iid) end) then
            return true
        end
    end
    return false
end

-- ============================================================================
-- WAYPOINTS
-- ============================================================================

local coords_mod = nil
local coords_tried = false

local function coords()
    if coords_tried then
        return coords_mod
    end
    coords_tried = true
    local ok, mod = pcall(require, "common/utility/coords_helper")
    if ok and type(mod) == "table" then
        coords_mod = mod
    end
    return coords_mod
end

--- Is this waypoint usable at all?
---
--- map_id 0 means the guide has no place to point at. wrong_continent means
--- the target is across an ocean: its dist is meaningless and walking at it
--- would drive the character into the coastline for the whole step.
local function usable(wp)
    if type(wp) ~= "table" then
        return false
    end
    local map_id = tonumber(wp.map_id)
    if not map_id or map_id == 0 then
        return false
    end
    if wp.wrong_continent == true then
        return false
    end
    return true
end

--- Convert one waypoint into a world position, or nil.
local function to_world(wp)
    if not usable(wp) then
        return nil
    end
    local map_id = tonumber(wp.map_id)
    local x = tonumber(wp.x)
    local y = tonumber(wp.y)
    if not x or not y then
        return nil
    end

    local helper = coords()
    if not helper or type(helper.map_to_world) ~= "function" then
        return nil
    end

    local world = safe(function()
        return helper:map_to_world(map_id, { x = x, y = y }, 0)
    end)
    if type(world) ~= "table" then
        return nil
    end
    local wx, wy, wz = tonumber(world.x), tonumber(world.y), tonumber(world.z)
    if not wx or not wy or not wz then
        return nil
    end
    return vec3.new(wx, wy, wz)
end

--- Where the guide is pointing right now, in world coordinates.
--- Returns position, distance, title - or nil when there is nothing usable.
function guide.waypoint()
    if not guide.ready() then
        return nil
    end
    local ns = api()
    if type(ns.get_current_waypoint) ~= "function" then
        return nil
    end
    local wp = safe(function() return ns.get_current_waypoint() end)
    local pos = to_world(wp)
    if not pos then
        return nil
    end
    return pos, tonumber(wp.dist), (type(wp.title) == "string") and wp.title or nil
end

--- Is the current waypoint on another continent? Worth saying out loud in the
--- status line: the bot will not walk, and the reason is not obvious.
function guide.wrong_continent()
    if not guide.ready() then
        return false
    end
    local ns = api()
    if type(ns.get_current_waypoint) ~= "function" then
        return false
    end
    local wp = safe(function() return ns.get_current_waypoint() end)
    return type(wp) == "table" and wp.wrong_continent == true
end

--- Every waypoint of the current step, in world coordinates.
---
--- Only active current-step waypoints are returned by the addon, and their
--- dist is always 0 - use guide.waypoint() when a real distance is wanted.
function guide.step_waypoints()
    local out = {}
    if not guide.ready() then
        return out
    end
    local ns = api()
    if type(ns.get_step_waypoints) ~= "function" then
        return out
    end
    local list = safe(function() return ns.get_step_waypoints() end)
    if type(list) ~= "table" then
        return out
    end
    for i = 1, #list do
        local pos = to_world(list[i])
        if pos then
            out[#out + 1] = pos
        end
    end
    return out
end

-- ============================================================================
-- STATUS
-- ============================================================================

--- One line describing what the guide is asking for, for the GUI.
function guide.describe()
    if not guide.is_loaded() then
        return "RestedXP not loaded"
    end
    if not guide.ready() then
        return "RestedXP has no active step"
    end
    local goal = guide.goal()
    if not goal then
        return "RestedXP step complete"
    end
    if guide.wrong_continent() then
        return "RestedXP target is on another continent"
    end
    local what = goal.text or tostring(goal.quest_id or "?")
    return string.format("%s %s", guide.classify(goal), what)
end

return guide
