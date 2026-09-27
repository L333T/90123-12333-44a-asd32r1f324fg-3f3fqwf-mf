-- ============================================================================
-- Master Farmer - Grindbot
-- Guide adapter - RestedXP
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.40.0
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

local geometry = require("geometry")

-- The plugin-wide search ceiling; targeting.lua owns the value.
local MAX_RANGE = 300

-- The visible-object list, through targeting's shared cache: one native scan
-- serves every finder here and the combat code, instead of each finder
-- building its own copy of every object in range.
local targeting_mod = nil
local function visible_objects()
    if targeting_mod == nil then
        local ok, mod = pcall(require, "targeting")
        targeting_mod = (ok and type(mod) == "table") and mod or false
    end
    if targeting_mod and type(targeting_mod.visible_objects) == "function" then
        local ok, list = pcall(targeting_mod.visible_objects)
        if ok and type(list) == "table" then
            return list
        end
        return nil
    end
    local ok, list = pcall(function() return core.object_manager.get_visible_objects() end)
    return (ok and type(list) == "table") and list or nil
end

local guide = {}

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end
--- safe(), without the closure: the same "first result, or nil on error", but
--- using pcall's own argument passing.
---
---     safe(function() return u:is_valid() end)   ->   call(u.is_valid, u)
---
--- Identical behaviour, no allocation. Used for the calls inside loops over
--- the visible object list, where the closure form allocated one per object
--- per predicate.
---
--- THE RECEIVER MUST BE NON-NIL: the index u.is_valid happens OUTSIDE the
--- pcall, so a nil receiver throws here where the closure form swallowed it.
--- Every call site keeps its `if u and ...` guard for that reason. A receiver
--- that exists but lacks the method is still fine - pcall catches calling a
--- nil value.
---
--- WHAT IS DELIBERATELY STILL ON safe(): the quest-log walks and the bag
--- scan. Those loops run over at most a couple of dozen entries, on throttled
--- paths rather than every frame, and they call through core.quests and
--- core.inventory rather than a unit - tables a build may not carry at all,
--- so moving the index outside the pcall would buy nothing and cost a new
--- guard on each one. Only the visible-object loops, which run over
--- everything in range, were converted. The rest are not oversights.
--- Is this value something call() may index?
---
--- call() does the index OUTSIDE the pcall, so a receiver that is not a table
--- or userdata throws before pcall can catch it. The closure form tolerated
--- any junk in a list - a boolean, a number, a leftover - and this keeps that
--- tolerance rather than narrowing it to "not nil".
local function indexable(v)
    local t = type(v)
    return t == "table" or t == "userdata"
end

local function call(fn, a, b)
    local ok, result = pcall(fn, a, b)
    if ok then
        return result
    end
    return nil
end


-- ============================================================================
-- READING THE ADDON
-- ============================================================================
-- Everything RestedXP returns is copied into plain Lua tables HERE, and only
-- here. The core binds its namespaces and result structures as either tables
-- or userdata depending on the build, and a `type(x) == "table"` test on a
-- userdata result fails silently: the addon then looks unloaded, or loaded
-- with no step, and the bot receives no quest information at all. So nothing
-- below this section ever sees a raw value from the addon.

local function index_of(o, k)
    return o[k]
end

--- Is this something that can be indexed - a table or a bound userdata?
local function is_obj(v)
    local t = type(v)
    return t == "table" or t == "userdata"
end

--- o[k], or nil when o cannot be indexed or the index throws.
local function get(o, k)
    if not is_obj(o) then
        return nil
    end
    local ok, v = pcall(index_of, o, k)
    if ok then
        return v
    end
    return nil
end

local function length_of(o)
    return #o
end

--- A list as a plain array: a Lua table, or a bound container that supports
--- # and integer indexing, or one that only supports indexing.
local MAX_LIST = 512
local function to_list(v)
    local out = {}
    if not is_obj(v) then
        return out
    end
    local ok, n = pcall(length_of, v)
    if ok and type(n) == "number" and n > 0 then
        for i = 1, math.min(n, MAX_LIST) do
            out[#out + 1] = get(v, i)
        end
        return out
    end
    for i = 1, MAX_LIST do
        local item = get(v, i)
        if item == nil then
            break
        end
        out[#out + 1] = item
    end
    return out
end

local function as_bool(v)
    return v == true or v == 1
end

local function as_str(v)
    if type(v) == "string" and v ~= "" then
        return v
    end
    return nil
end

--- A positive id, or nil. RestedXP reports "no quest" as 0.
local function as_id(v)
    local n = tonumber(v)
    if n and n > 0 then
        return n
    end
    return nil
end

local function plain_goal(raw)
    if not is_obj(raw) then
        return nil
    end
    local ids = {}
    local raw_ids = to_list(get(raw, "ids"))
    for i = 1, #raw_ids do
        local v = raw_ids[i]
        if type(v) == "number" or type(v) == "string" then
            ids[#ids + 1] = v
        end
    end
    return {
        action = as_str(get(raw, "action")) or "",
        quest_id = as_id(get(raw, "quest_id")),
        text = as_str(get(raw, "text")),
        is_complete = as_bool(get(raw, "is_complete")),
        text_only = as_bool(get(raw, "text_only")),
        ids = ids,
    }
end

local function plain_step(raw)
    if not is_obj(raw) then
        return nil
    end
    local goals = {}
    local raw_goals = to_list(get(raw, "goals"))
    for i = 1, #raw_goals do
        local g = plain_goal(raw_goals[i])
        if g then
            goals[#goals + 1] = g
        end
    end
    return {
        num = tonumber(get(raw, "num")) or 0,
        is_complete = as_bool(get(raw, "is_complete")),
        goals = goals,
    }
end

local function plain_waypoint(raw)
    if not is_obj(raw) then
        return nil
    end
    return {
        map_id = tonumber(get(raw, "map_id")) or 0,
        x = tonumber(get(raw, "x")),
        y = tonumber(get(raw, "y")),
        dist = tonumber(get(raw, "dist")),
        title = as_str(get(raw, "title")),
        type = as_str(get(raw, "type")),
        goal_num = tonumber(get(raw, "goal_num")),
        is_manual = as_bool(get(raw, "is_manual")),
        wrong_continent = as_bool(get(raw, "wrong_continent")),
    }
end

local function plain_objective(raw)
    if not is_obj(raw) then
        return nil
    end
    return {
        text = as_str(get(raw, "text")),
        type = as_str(get(raw, "type")),
        num_required = tonumber(get(raw, "num_required")) or 0,
        num_fulfilled = tonumber(get(raw, "num_fulfilled")) or 0,
        finished = as_bool(get(raw, "finished")),
    }
end

--- The addon namespace, or nil when this build has no core.addons.rested_xp.
local function api()
    local addons = get(rawget(_G, "core"), "addons")
    local ns = get(addons, "rested_xp")
    if not is_obj(ns) then
        return nil
    end
    return ns
end

local errorlog_mod = nil
local function probe(tag)
    if errorlog_mod == nil then
        local ok, mod = pcall(require, "errorlog")
        errorlog_mod = (ok and type(mod) == "table") and mod or false
    end
    if errorlog_mod then
        errorlog_mod.probe(tag)
    end
end

-- ----------------------------------------------------------------------------
-- READS ONLY FROM THE UPDATE CALLBACK (2.30.0)
-- ----------------------------------------------------------------------------
-- The game crashed a few seconds into questing whenever frames were fast
-- (2.20, 2.21, 2.29 at ~540 fps) and never while the flight recorder slowed
-- them to ~10 fps (2.22, 2.27). The Questing tab asked for the guide snapshot
-- from the RENDER callback, and once the window had lapsed that read the
-- addon right there - in the render hook, as often as hundreds of times a
-- second - and so could the objectives lookup and the detection panel.
--
-- Now ns_call refuses unless main.lua has opened the update window
-- (guide.allow_reads). Every read happens inside on_update, at most once per
-- WINDOW; everything else only ever sees the last snapshot.
local reads_ok = false

--- Open or close the window in which the addon may be read. main.lua opens
--- it around on_update and closes it straight after.
function guide.allow_reads(on)
    reads_ok = on == true
end

--- Call one function of the namespace.
--- Returns result, nil - or nil, reason when it could not be called.
local function ns_call(name, ...)
    if not reads_ok then
        return nil, "outside the update callback"
    end
    local ns = api()
    if not ns then
        return nil, "core.addons.rested_xp missing"
    end
    local fn = get(ns, name)
    if fn == nil then
        return nil, name .. " missing"
    end
    probe("rxp:" .. name)
    local ok, res = pcall(fn, ...)
    if not ok then
        return nil, tostring(res)
    end
    return res, nil
end

-- ============================================================================
-- ONE READ PER WINDOW (2.21.0)
-- ============================================================================
-- Every native RestedXP call happens in refresh(), at most once per WINDOW,
-- and everything else reads the plain copy it leaves in `snap`.
--
-- Before this, a single quest tick asked the addon for its step, its loaded
-- flag, its waypoints and a quest's objectives many times over - classify
-- alone fetched get_objectives on every call, and it was called several times
-- a tick - and the Questing tab repeated all of it on every rendered frame.
-- Each call built fresh tables from native data. That was the memory churn,
-- and it meant reading the addon's state dozens of times a frame, including
-- while RestedXP was rebuilding it: the crash in 2.20.0 came on a frame where
-- the step's waypoints changed mid-fight.
--
-- Derived values (the current goal, its kind, its targets, its waypoints)
-- are memoised in the same snapshot, so they are also computed once a window.
local WINDOW = 0.25           -- seconds

local snap = {
    t = -1,
    loaded = false,
    ready = false,
    step = nil,
    stickies = {},
    wp = nil,                 -- current arrow waypoint, plain
    step_wps = {},            -- current step's waypoints, plain
    objectives = {},          -- quest id -> plain objective list
    memo = {},                -- derived values, cleared with the snapshot
}

local function clock()
    local ok, t = pcall(izi.now)
    if ok and type(t) == "number" then
        return t
    end
    return 0
end

--- Is the player in combat? Read once per refresh.
local function player_in_combat()
    local ok, me = pcall(izi.me)
    if not ok or not me then
        return false
    end
    local ok2, c = pcall(me.is_in_combat, me)
    return ok2 and c == true
end

local function refresh()
    if not reads_ok then
        return                -- render / GUI: the last snapshot stands
    end
    local now = clock()
    if snap.t >= 0 and now >= snap.t and (now - snap.t) < WINDOW then
        return
    end
    -- NO ADDON READS IN COMBAT (2.22.0). Both crash logs end within a second
    -- of the character entering combat, and combat is when the game's UI -
    -- RestedXP with it - is busiest processing events. The bot needs nothing
    -- new from the guide mid-fight, so the last snapshot stands until the
    -- fight is over. Objectives fetched during the window stay cached too.
    if snap.ready and player_in_combat() then
        snap.t = now
        return
    end
    snap.t = now
    snap.loaded = as_bool((ns_call("is_loaded")))
    snap.ready = false
    snap.step = nil
    snap.stickies = {}
    snap.wp = nil
    snap.step_wps = {}
    snap.objectives = {}
    snap.memo = {}
    if not snap.loaded then
        return
    end

    local step = plain_step((ns_call("get_current_step")))
    local has = as_bool((ns_call("has_current_step")))
    -- has_current_step is the documented test; a step with a number or goals
    -- is the same answer read a second way, kept in case the flag is missing.
    snap.ready = has or (step ~= nil and (step.num > 0 or #step.goals > 0))
    if not snap.ready then
        return
    end
    snap.step = step

    local list = to_list((ns_call("get_current_stickies")))
    for i = 1, #list do
        local st = plain_step(list[i])
        if st then
            snap.stickies[#snap.stickies + 1] = st
        end
    end
    snap.wp = plain_waypoint((ns_call("get_current_waypoint")))
    local wps = to_list((ns_call("get_step_waypoints")))
    for i = 1, #wps do
        local wp = plain_waypoint(wps[i])
        if wp then
            snap.step_wps[#snap.step_wps + 1] = wp
        end
    end
end

--- A value derived from this window's snapshot, computed at most once.
local function memo(key, fn)
    refresh()
    local v = snap.memo[key]
    if v == nil and not reads_ok then
        -- Outside the update window a derived value may be missing data the
        -- addon would have supplied; hand it back but never cache it, or the
        -- engine would reuse the thinner answer for the rest of the window.
        v = fn()
        if v == false then
            return nil
        end
        return v
    end
    if v == nil then
        v = fn()
        if v == nil then
            v = false
        end
        snap.memo[key] = v
    end
    if v == false then
        return nil
    end
    return v
end

-- ============================================================================
-- AVAILABILITY
-- ============================================================================

--- Is the addon installed and running?
function guide.is_loaded()
    refresh()
    return snap.loaded
end

--- Is there a guide step to follow right now?
function guide.ready()
    refresh()
    return snap.ready
end

-- ============================================================================
-- THE CURRENT STEP
-- ============================================================================

--- Called by main.lua every bot tick while Questing is enabled, inside the
--- update window: keeps the snapshot (and a requested detection reading)
--- current for the GUI even while the bot is not started.
function guide.update()
    refresh()
    if diag_wanted then
        diag_wanted = false
        guide.diagnose()
        diag_wanted = false
    end
end

--- The current step as a plain table { num, is_complete, goals }, or nil.
function guide.step()
    refresh()
    return snap.step
end

--- Sticky steps: persistent objectives shown alongside the current one.
--- The current step is not included in this list.
function guide.stickies()
    refresh()
    return snap.stickies
end

--- Everything the Questing tab shows about how the addon is being read, so a
--- "no quest information" report can be answered by looking at the tab.
local diag_cache, diag_t = nil, -1
local diag_wanted = false
local DIAG_PENDING = {
    addons = "-", namespace = "-", missing = {}, is_loaded = "(reading)",
    has_step = "(reading)", step_type = "-", step_num = 0, goal_count = 0,
    waypoint = "(reading)", step_waypoints = 0,
}

--- The detection panel's figures. Called from the GUI it only files a
--- request and returns the last reading; the update fills it in.
function guide.diagnose()
    diag_wanted = true
    if not reads_ok then
        return diag_cache or DIAG_PENDING
    end
    local now = clock()
    if diag_cache and now >= diag_t and (now - diag_t) < 1.0 then
        return diag_cache
    end
    diag_t = now
    local out = {}
    local addons = get(rawget(_G, "core"), "addons")
    out.addons = type(addons)
    local ns = get(addons, "rested_xp")
    out.namespace = type(ns)
    local fns = { "is_loaded", "has_current_step", "get_current_step",
        "get_current_stickies", "get_objectives", "get_current_waypoint",
        "get_step_waypoints" }
    local missing = {}
    for i = 1, #fns do
        if get(ns, fns[i]) == nil then
            missing[#missing + 1] = fns[i]
        end
    end
    out.missing = missing

    local loaded, lerr = ns_call("is_loaded")
    out.is_loaded = tostring(loaded) .. (lerr and (" (" .. lerr .. ")") or "")
    local has, herr = ns_call("has_current_step")
    out.has_step = tostring(has) .. (herr and (" (" .. herr .. ")") or "")

    local raw, serr = ns_call("get_current_step")
    out.step_type = type(raw) .. (serr and (" (" .. serr .. ")") or "")
    local step = plain_step(raw)
    out.step_num = step and step.num or 0
    out.goal_count = step and #step.goals or 0

    local wraw = ns_call("get_current_waypoint")
    local wp = plain_waypoint(wraw)
    out.waypoint = wp and string.format("map %d  %.3f,%.3f  %s",
        wp.map_id, wp.x or 0, wp.y or 0, tostring(wp.title or "-"))
        or ("none (" .. type(wraw) .. ")")
    out.step_waypoints = #to_list((ns_call("get_step_waypoints")))
    diag_cache = out
    return out
end

--- Normalise one goal into the fields this project reads, with its position
--- in the step. The input is already a plain table from plain_goal.
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
    if type(g.ids) == "table" and #g.ids > 0 then
        ids = {}
        for i = 1, #g.ids do
            ids[i] = g.ids[i]
        end
    end
    return {
        action = (type(g.action) == "string") and g.action or "",
        quest_id = as_id(g.quest_id),
        text = (type(g.text) == "string" and g.text ~= "") and g.text or nil,
        text_only = g.text_only == true,
        is_complete = g.is_complete == true,
        ids = ids,
        index = index,
    }
end

--- Has the grey-quest check (quest/npc) put this quest in the skip bag?
local function skipped(quest_id)
    if type(quest_id) ~= "number" then
        return false
    end
    local ok, state = pcall(require, "state")
    if not ok or type(state) ~= "table" or type(state.quest) ~= "table" then
        return false
    end
    local bag = state.quest.skipped
    return type(bag) == "table" and bag[quest_id] == true
end
guide.skipped = skipped

--- The current step's number, or 0.
function guide.step_num()
    local step = guide.step()
    return step and tonumber(step.num) or 0
end

--- The first goal of the current step that is not finished yet.
---
--- The guide lists a step's goals in the order it wants them done, so the
--- first incomplete one is the instruction to follow. Two kinds are passed
--- over: text_only lines, which are commentary with nothing to act on, and a
--- quest the grey-quest check skipped, which the guide would otherwise keep
--- the bot standing at forever. A text_only goal is still returned when it is
--- the only thing left, so its waypoint is walked to. A step whose goals are
--- all complete returns nil; the addon moves on by itself.
local function compute_goal()
    local step = guide.step()
    if not step or step.is_complete == true then
        return nil
    end
    local goals = step.goals
    if type(goals) ~= "table" then
        return nil
    end
    local fallback = nil
    for i = 1, #goals do
        local g = goals[i]
        if type(g) == "table" and g.is_complete ~= true
            and not skipped(tonumber(g.quest_id)) then
            if g.text_only ~= true then
                return shape_goal(g, i)
            end
            fallback = fallback or shape_goal(g, i)
        end
    end
    return fallback
end

--- The goal to work on now. The same table for the whole window, so callers
--- can memoise against it.
function guide.goal()
    return memo("goal", compute_goal)
end

--- Every goal of the current step, shaped, for the GUI.
function guide.goals()
    return memo("goals", function()
    local out = {}
    local step = guide.step()
    if not step or type(step.goals) ~= "table" then
        return out
    end
    for i = 1, #step.goals do
        local g = shape_goal(step.goals[i], i)
        if g then
            out[#out + 1] = g
        end
    end
    return out
    end)
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

    -- ".complete <quest>,<objective>": the most common instruction in a
    -- RestedXP guide, and it says nothing about HOW. The quest's own
    -- objective type answers that - see classify.
    complete        = "objective",
    questcomplete   = "objective",
}

-- Objective type, as RestedXP's get_objectives reports it, to the engine's
-- kind. "monster" is a kill count, "item" something to end up holding, and
-- "object" a thing in the world to click. Anything else - an event, an area
-- to explore, a reputation - is reached by walking to the waypoint.
local OBJECTIVE_KIND = {
    monster = "kill",
    item    = "collect",
    object  = "object",
}

--- The unfinished objective a goal refers to, or nil.
---
--- A goal does not carry an objective index, so it is matched on text: the
--- goal line for a ".complete" step is the objective's own text. When nothing
--- matches, the first unfinished objective is the one being worked on.
function guide.goal_objective(goal)
    if type(goal) ~= "table" or not goal.quest_id then
        return nil
    end
    local list = guide.objectives(goal.quest_id)
    local first = nil
    local want = goal.text and string.lower(goal.text) or nil
    for i = 1, #list do
        local o = list[i]
        if not o.finished then
            first = first or o
            local head = o.text and string.lower(o.text:match("^(.-):%s*%d+%s*/%s*%d+%s*$") or o.text)
            if want and head and head ~= "" and string.find(want, head, 1, true) then
                return o
            end
        end
    end
    return first
end

--- What kind of thing this goal is, in the engine's vocabulary.
---
--- The action names the verb. When the verb is only "complete", the quest's
--- objective type from RestedXP says whether that means killing, collecting
--- or clicking. A collect goal on a quest whose objective is a world object
--- becomes "object", so the bot clicks it instead of fighting for it.
local classify_raw

function guide.classify(goal)
    if type(goal) ~= "table" then
        return "goto"
    end
    local k = goal._kind
    if k == nil then
        k = classify_raw(goal)
        if reads_ok then
            goal._kind = k
        end
    end
    return k
end

classify_raw = function(goal)
    local a = goal.action
    if type(a) ~= "string" or a == "" then
        return "goto"
    end
    local kind = ACTIONS[a] or ACTIONS[string.lower(a)] or "goto"
    if kind == "objective" or kind == "collect" then
        local o = guide.goal_objective(goal)
        local t = o and o.type and string.lower(o.type) or nil
        if t and OBJECTIVE_KIND[t] then
            return OBJECTIVE_KIND[t]
        end
        if kind == "objective" then
            return "goto"
        end
    end
    return kind
end

-- ============================================================================
-- OBJECTIVE PROGRESS
-- ============================================================================

--- Progress on one quest: { text, type, num_required, num_fulfilled, finished }.
---
--- This is RestedXP's view of the quest, and the primary source for both
--- "is this done" and "what does it want killed or collected": the objective
--- text names the creature or item, and type says which of the two it is.
function guide.objectives(quest_id)
    local out = {}
    quest_id = tonumber(quest_id)
    if not quest_id then
        return out
    end
    refresh()
    local hit = snap.objectives[quest_id]
    if hit then
        return hit
    end
    if not reads_ok then
        return out            -- asked from the GUI: nothing cached yet
    end
    local list = to_list((ns_call("get_objectives", quest_id)))
    for i = 1, #list do
        local o = plain_objective(list[i])
        if o then
            out[#out + 1] = o
        end
    end
    snap.objectives[quest_id] = out
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
-- TARGET NAMES
-- ============================================================================
-- RestedXP does not hand out creature or object ids for a kill or collect -
-- see the header - but its objectives name the target in the client's own
-- words: "Kobold Vermin slain: 3/10", "Bundle of Wood: 0/5". Stripping the
-- progress leaves the name as the client spells it, localised correctly,
-- which is a far tighter thing to match a unit against than the guide's
-- sentence.
--
-- The quest log carries the same lines and is read only when RestedXP has no
-- objective data for the quest.

local log_cache = {}         -- quest_id -> { names = {...}, t = when }
local LOG_TTL = 1.0
local headers_expanded = false

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
    local head = text:match("^(.-):%s*%d+%s*/%s*%d+%s*$")
    if head and head ~= "" then
        return head
    end
    return text
end
guide.strip_progress = strip_progress

--- The quest log index for a quest id, or nil.
---
--- Collapsed headers hide their quests from the log indices, so every header
--- is expanded once per session before the first walk.
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
            return i, info
        end
    end
    return nil
end

--- The quest's title from the quest log, or nil when it is not in the log.
function guide.log_title(quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id then
        return nil
    end
    local _, info = log_index_of(quest_id)
    if type(info) == "table" and type(info.title) == "string" and info.title ~= "" then
        return info.title
    end
    return nil
end

--- Names of the unfinished objectives of a quest, as the client words them.
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
    local rxp = guide.objectives(quest_id)
    for i = 1, #rxp do
        if not rxp[i].finished then
            local name = strip_progress(rxp[i].text)
            if name then
                names[#names + 1] = name
            end
        end
    end

    if #rxp == 0 then
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
    end

    if reads_ok then
        log_cache[quest_id] = { names = names, t = now }
    end
    return names
end

-- ============================================================================
-- TARGETS
-- ============================================================================
local compute_targets
-- Kinds whose goals name something to fight, collect or click. Only these
-- contribute target names: an accept line's text is a quest title, and a mob
-- that happens to share a word with it is not a target.
local TARGET_KINDS = { kill = true, collect = true, object = true, item = true }

--- Everything a goal asks us to act on, split into numeric ids and names.
---
--- Taken from the goal itself (its ids and its text), from RestedXP's
--- unfinished objectives for the goal's quest, and from the sticky steps'
--- kill and collect goals - a sticky "kill 10 wolves" stays wanted while the
--- current step walks somewhere else.
---
--- Returns two sets: ids keyed by number, names keyed by string.
function guide.targets(goal)
    goal = goal or guide.goal()
    local key = "targets:" .. tostring(goal and goal.index or 0)
    local pair = memo(key, function()
        local i, n = compute_targets(goal)
        return { i, n }
    end)
    return pair[1], pair[2]
end

compute_targets = function(goal)
    local ids, names = {}, {}

    local function take(g, with_objectives)
        if type(g) ~= "table" or g.is_complete == true then
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
        local text = strip_progress(g.text)
        if text then
            names[text] = true
        end
        if with_objectives then
            local from = guide.objective_names(g.quest_id)
            for k = 1, #from do
                names[from[k]] = true
            end
        end
    end

    take(goal, true)

    local stickies = guide.stickies()
    for i = 1, #stickies do
        local s = stickies[i]
        if type(s.goals) == "table" then
            for j = 1, #s.goals do
                local g = shape_goal(s.goals[j], j)
                if g and TARGET_KINDS[guide.classify(g)] then
                    take(g, true)
                end
            end
        end
    end

    return ids, names
end

--- The target ids as an array, for callers that scan by id.
--- Often empty: see the header note on why RestedXP is name-oriented.
function guide.target_ids(goal)
    local ids = guide.targets(goal)
    local out = {}
    for id in pairs(ids) do
        out[#out + 1] = id
    end
    table.sort(out)
    return out
end

--- Does a unit or object name match the target names?
---
--- Exact first, then the name occurring inside a candidate - the candidates
--- are objective lines and guide sentences, which carry more than the name.
local function name_wanted(name, names)
    if type(name) ~= "string" or name == "" then
        return false
    end
    if names[name] then
        return true
    end
    local lower = string.lower(name)
    for n in pairs(names) do
        if string.find(string.lower(n), lower, 1, true) then
            return true
        end
    end
    return false
end

-- ============================================================================
-- FINDING THINGS IN THE WORLD
-- ============================================================================

--- The nearest visible game object this goal wants, or nil.
---
--- Objects are not units: the mob scan will never return a chest or a herb,
--- so this walks the visible-object list itself.
function guide.find_object(player, range, goal)
    if not player then
        return nil, nil
    end
    range = math.min(tonumber(range) or 30, MAX_RANGE)

    local ids, names = guide.targets(goal)
    -- Nothing named means nothing to look for. Returning the nearest object
    -- of any kind would have the bot clicking scenery.
    if next(ids) == nil and next(names) == nil then
        return nil, nil
    end

    local list = visible_objects()
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
        if indexable(o) and call(o.is_valid, o) ~= false then
            -- A unit is handled by the kill path; this is for everything else.
            if call(o.is_unit, o) ~= true then
                local oid = call(o.get_npc_id, o)
                local want = type(oid) == "number" and ids[oid] == true
                if not want then
                    want = name_wanted(call(o.get_name, o), names)
                end
                if want then
                    local pos = call(o.get_position, o)
                    if pos then
                        local d = call(player.distance_to, player, o)
                        if type(d) ~= "number" then
                            d = geometry.distance(me, pos)
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

--- Can the bot fight this unit? Alive, not a player, attackable.
local function fightable(player, u)
    return indexable(u) and call(u.is_valid, u) == true
        and call(u.is_unit, u) == true
        and call(u.is_dead_or_ghost, u) ~= true
        and call(u.is_player, u) ~= true
        and call(u.is_tap_denied, u) ~= true
        and call(player.can_attack, player, u) ~= false
end

--- The nearest unit this goal wants to fight, or nil.
---
--- Name-matched against RestedXP's objective names, because its mob and
--- target steps carry names rather than creature ids. An id is used when the
--- guide happens to supply one.
function guide.find_mob(player, range, goal)
    if not player then
        return nil, nil
    end
    range = math.min(tonumber(range) or 40, MAX_RANGE)

    local ids, names = guide.targets(goal)
    if next(ids) == nil and next(names) == nil then
        return nil, nil
    end

    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end

    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if fightable(player, u) then
            local uid = call(u.get_npc_id, u)
            local want = type(uid) == "number" and ids[uid] == true
            if not want then
                want = name_wanted(call(u.get_name, u), names)
            end
            if want then
                local d = call(player.distance_to, player, u)
                if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then
                    best, best_d = u, d
                end
            end
        end
    end
    return best, best_d
end

--- The nearest level-appropriate hostile near a point, or nil.
---
--- For an item objective whose drop source RestedXP does not name: its
--- waypoints sit on the camp that drops it, so what stands there is what to
--- fight. Kept to within LEVEL_GAP levels below the player, so critters and
--- grey wildlife around the camp are left alone.
local LEVEL_GAP = 4
-- A camp is judged from its waypoint, but the mob chosen must also be near the
-- PLAYER: one at the far edge of a 45-yard camp could be 90 yards off, which
-- sends the bot on a long pull-in across broken ground for a random mob.
local CAMP_REACH = 40

-- Never a camp target: nothing about these drops quest items.
local NOT_CAMP = nil
local function camp_excluded(u)
    if NOT_CAMP == nil then
        NOT_CAMP = {}
        local ok, enums = pcall(require, "common/enums")
        local ct = ok and type(enums) == "table" and enums.creature_type or nil
        if type(ct) == "table" then
            for _, k in ipairs({ "CRITTER", "NON_COMBAT_PET", "WILD_PET", "TOTEM", "GAS_CLOUD" }) do
                if type(ct[k]) == "number" then
                    NOT_CAMP[ct[k]] = true
                end
            end
        end
    end
    local t = call(u.get_creature_type, u)
    return type(t) == "number" and NOT_CAMP[t] == true
end

function guide.find_camp_mob(player, center, radius)
    if not player or not center then
        return nil, nil
    end
    radius = math.min(tonumber(radius) or 40, MAX_RANGE)
    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end
    local my_level = call(player.get_level, player) or 1
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if fightable(player, u) then
            local lvl = call(u.get_level, u) or 0
            local pos = call(u.get_position, u)
            if lvl >= my_level - LEVEL_GAP and pos and not camp_excluded(u)
                and geometry.distance(center, pos) <= radius then
                local d = call(player.distance_to, player, u)
                if type(d) == "number" and d <= CAMP_REACH and (best_d == nil or d < best_d) then
                    best, best_d = u, d
                end
            end
        end
    end
    return best, best_d
end

-- ============================================================================
-- DROP SOURCES FROM THE ITEM NAME (2.24.0)
-- ============================================================================
-- RestedXP names the ITEM a collect objective wants - "Tough Wolf Meat" - but
-- not the creature that drops it, and no unit is called "Tough Wolf Meat". The
-- bot used to fall straight back to fighting whatever stood at the waypoint:
-- troggs, boars and rabbits for wolf meat, and the quest never moved.
--
-- Item names almost always carry the dropper's name: Tough WOLF Meat, BOAR
-- Meat, KOBOLD Candle, WENDIGO Mane, Crag BOAR Rib. So the words of the item
-- name, minus the generic ones, are matched against the words of each unit's
-- name. Plurals are folded to one form on both sides (wolves -> wolf).
local GENERIC = {}
for w in ([[
    a an the of and or in on with for from to
    tough small large big young old fresh rotten raw cured fine coarse thick
    thin heavy light broken torn ragged pristine intact whole
    meat flesh flank rib ribs shank chop steak leg legs haunch loin
    hide hides pelt pelts skin skins leather fur scale scales feather feathers
    fang fangs tooth teeth claw claws talon talons tusk tusks horn horns hoof
    hooves paw paws tail tails ear ears eye eyes heart hearts head heads skull
    skulls bone bones blood venom sac sacs gland glands wing wings mane manes
    spine spines stinger stingers carapace shell shells egg eggs gizzard
    tongue brain liver kidney essence dust powder sample samples shard shards
    fragment fragments piece pieces chunk chunks scrap scraps bundle bundles
    sack sacks bag bags crate crates box boxes pouch pouches satchel bottle
    note letter orders package parcel token tokens badge insignia ring charm
    slain killed defeated destroyed collected gathered
]]):gmatch("%a+") do
    GENERIC[w] = true
end

local function fold(w)
    w = string.lower(w)
    if #w > 4 and w:sub(-3) == "ves" then
        return w:sub(1, -4) .. "f"           -- wolves -> wolf
    end
    if #w > 4 and w:sub(-3) == "ies" then
        return w:sub(1, -4) .. "y"
    end
    if #w > 3 and w:sub(-1) == "s" and w:sub(-2) ~= "ss" then
        return w:sub(1, -2)                  -- troggs -> trogg
    end
    return w
end

--- The meaningful words of the goal's objective names, as a set, or nil.
local function source_words(goal)
    local names = guide.objective_names(goal and goal.quest_id)
    local text = goal and strip_progress(goal.text)
    local set, any = {}, false
    local function take(s)
        if type(s) ~= "string" then
            return
        end
        for w in s:gmatch("%a+") do
            local f = fold(w)
            if #f >= 3 and not GENERIC[f] and not GENERIC[string.lower(w)] then
                set[f] = true
                any = true
            end
        end
    end
    for i = 1, #names do
        take(names[i])
    end
    take(text)
    return any and set or nil
end

--- Does the goal's item name give any clue to its drop source?
function guide.has_source_words(goal)
    return memo("srcw:" .. tostring(goal and goal.index or 0), function()
        return source_words(goal) and true or false
    end) == true
end

--- The nearest fightable unit whose name shares a meaningful word with the
--- item the goal collects, or nil.
function guide.find_source_mob(player, range, goal)
    if not player then
        return nil, nil
    end
    local words = memo("srcset:" .. tostring(goal and goal.index or 0), function()
        return source_words(goal)
    end)
    if not words then
        return nil, nil
    end
    range = math.min(tonumber(range) or 50, MAX_RANGE)
    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if fightable(player, u) and not camp_excluded(u) then
            local name = call(u.get_name, u)
            if type(name) == "string" then
                local hit = false
                for w in name:gmatch("%a+") do
                    if words[fold(w)] then
                        hit = true
                        break
                    end
                end
                if hit then
                    local d = call(player.distance_to, player, u)
                    if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then
                        best, best_d = u, d
                    end
                end
            end
        end
    end
    return best, best_d
end

--- The npc id of whatever is currently targeted, or nil.
---
--- get_target is a UNIT method, not an object_manager one. An id of 0 means
--- "not a creature" - a player, a pet, an object - and is rejected.
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
    local id = geometry.object_id(target)
    if not id then
        return nil, target
    end
    return id, target
end

-- ============================================================================
-- LEARNING NPC IDS
-- ============================================================================
-- RestedXP never names the NPC behind an accept or turnin, so one can only be
-- read off a unit. Two pairings are kept:
--
--   quest title -> npc id   learned whenever a gossip frame is open with the
--                           NPC targeted: that NPC gives what the frame lists.
--   accept/turnin + quest id -> npc id
--                           learned when a dialog the bot opened with a unit
--                           actually accepted or handed in that quest.
--
-- Either lets the next visit go straight to a verified unit instead of
-- guessing by proximity. Persisted per character through settings.lua.
--
-- Staleness is handled rather than feared: an id that no longer matches
-- anything simply finds no unit, and the proximity path takes over.
local learned = {}           -- quest title -> npc id
local by_quest = {}          -- "a<quest id>" / "t<quest id>" -> npc id

local function mark_dirty()
    local ok, settings = pcall(require, "settings")
    if ok and settings and type(settings.mark_dirty) == "function" then
        settings.mark_dirty()
    end
end

--- Record the targeted npc as the giver of whatever the gossip frame lists.
function guide.learn_npc_id(player)
    if safe(function() return core.quests.is_gossip_frame_shown() end) ~= true then
        return nil
    end
    local id = guide.target_npc_id(player)
    if not id then
        return nil
    end

    local changed = false
    local function record(list)
        if type(list) ~= "table" then
            return
        end
        for i = 1, #list do
            local q = list[i]
            if type(q) == "table" and type(q.title) == "string" and q.title ~= "" then
                if learned[q.title] ~= id then
                    learned[q.title] = id
                    changed = true
                end
            end
        end
    end
    record(safe(function() return core.quests.get_gossip_active_quests() end))
    record(safe(function() return core.quests.get_gossip_available_quests() end))

    -- Only ask for a write when something actually changed: this runs on
    -- every tick that has a gossip frame open.
    if changed then
        mark_dirty()
    end
    return id
end

local function quest_key(kind, quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id then
        return nil
    end
    if kind == "accept" then
        return "a" .. quest_id
    end
    if kind == "turnin" then
        return "t" .. quest_id
    end
    return nil
end

--- Remember which NPC took an accept or a turnin for a quest.
function guide.learn_quest_npc(kind, quest_id, npc_id)
    local key = quest_key(kind, quest_id)
    npc_id = tonumber(npc_id)
    if not key or not npc_id or npc_id <= 0 then
        return
    end
    if by_quest[key] ~= npc_id then
        by_quest[key] = npc_id
        mark_dirty()
    end
end

--- The NPC learned for an accept or turnin of a quest, or nil.
---
--- The quest-keyed pairing is tried first. A title learned from a gossip
--- frame is the fallback, matched against the quest's log title and the
--- goal's text.
function guide.known_quest_npc(kind, quest_id, text)
    local key = quest_key(kind, quest_id)
    if key and by_quest[key] then
        return by_quest[key]
    end
    local title = guide.log_title(quest_id)
    if title and learned[title] then
        return learned[title]
    end
    if type(text) == "string" and text ~= "" then
        for t, id in pairs(learned) do
            if string.find(text, t, 1, true) then
                return id
            end
        end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- PERSISTENCE
-- ----------------------------------------------------------------------------
-- settings.lua stores one line per provider as key=value and escapes the
-- value, so anything may be put in it. The inner format is one entry per line:
--
--     <npc id>=<quest title>       from a gossip frame
--     a<quest id>=<npc id>         the NPC that took an accept
--     t<quest id>=<npc id>         the NPC that took a turnin
--
-- A title line leads with its numeric id, so the first "=" is always the
-- separator and a title containing one cannot break the parse. The quest
-- lines lead with a letter, which an older build's parser skips.
local ENTRY_SEP = "\n"

--- Everything learned, for settings.lua to write out.
function guide.serialise()
    local lines = {}
    for title, id in pairs(learned) do
        if type(title) == "string" and title ~= "" and type(id) == "number" then
            lines[#lines + 1] = string.format("%d=%s", id, title)
        end
    end
    for key, id in pairs(by_quest) do
        if type(key) == "string" and type(id) == "number" then
            lines[#lines + 1] = string.format("%s=%d", key, id)
        end
    end
    -- Sorted so the file does not churn between sessions that learned the
    -- same things in a different order.
    table.sort(lines)
    return table.concat(lines, ENTRY_SEP)
end

--- Load what a previous session learned.
function guide.deserialise(text)
    learned = {}
    by_quest = {}
    if type(text) ~= "string" or text == "" then
        return
    end
    for line in text:gmatch("[^\n]+") do
        local qkey, qnpc = line:match("^([at]%d+)=(%d+)$")
        if qkey then
            local n = tonumber(qnpc)
            if n and n > 0 then
                by_quest[qkey] = n
            end
        else
            local id, title = line:match("^(%d+)=(.+)$")
            id = tonumber(id)
            if id and id > 0 and type(title) == "string" and title ~= "" then
                learned[title] = id
            end
        end
    end
end

--- Forget everything. Used by the tests and on a settings reset.
function guide.forget_npc_ids()
    learned = {}
    by_quest = {}
end

--- The npc id learned for a quest title, or nil.
function guide.known_npc_id(title)
    if type(title) ~= "string" or title == "" then
        return nil
    end
    return learned[title]
end

--- The nearest NPC that can be spoken to.
---
--- Once the bot is standing where the guide sent it, the nearest unit it
--- cannot attack is a quest giver, a vendor or a guard rather than a mob.
--- Deliberately short ranged: it is a guess, and a guess is only reasonable
--- once standing where the guide pointed.
function guide.nearest_talkable(player, range, center)
    if not player then
        return nil, nil
    end
    range = math.min(tonumber(range) or 8, MAX_RANGE)

    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end

    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true
            and call(u.is_unit, u) == true
            and call(u.is_dead_or_ghost, u) ~= true
            and call(u.is_player, u) ~= true then
            if call(player.can_attack, player, u) == false then
                local d
                if center then
                    local pos = call(u.get_position, u)
                    d = pos and geometry.distance(center, pos) or nil
                else
                    d = call(player.distance_to, player, u)
                end
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

--- The bag entry for an item this goal wants, or nil.
---
--- Returns the entry as core.inventory.get_items_in_bag gives it - the object
--- and its slot - because core.input.use_item wants the object, not an id.
function guide.find_bag_item(goal)
    local ids, names = guide.targets(goal)
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
                        if name_wanted(iname, names) then
                            return entry
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
--- first and the raw item id second.
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
---
--- WHY NOT coords_helper:map_to_world EVERY FRAME (2.20.0)
---   map_to_world is not a pure conversion: it runs a terrain raycast at the
---   target x,y, starting from the PLAYER's height. It was called for every
---   step waypoint on every frame, for points that can be across the zone on
---   terrain the client has not loaded, and it was handed a plain {x, y}
---   table where the API declares a vec2. Questing crashed the game on start;
---   this was the one native call that began running every frame at that
---   moment and not in grind mode.
---
--- Now:
---   * x,y come from core.game_ui.get_world_pos_from_map_pos, which converts
---     without touching terrain, given a real vec2.
---   * each waypoint is converted ONCE and cached.
---   * height is only queried once the point is within HEIGHT_RANGE of the
---     player, where its terrain is certainly loaded. Until then the player's
---     own height stands in, which is all a far-away walk target needs.
---   * map_to_world remains as a fallback only when the pure conversion is
---     missing, and then at most once per waypoint.
local HEIGHT_RANGE = 120      -- yards
local WORLD_LIMIT = 20000     -- no WoW coordinate is larger than this
local CONV_MAX = 400          -- cached waypoints before the cache is dropped

local vec2_mod = nil
local conv = {}               -- "map|x|y" -> { x, y, z, final } or false
local conv_n = 0

local function vec2_new(x, y)
    if vec2_mod == nil then
        local ok, mod = pcall(require, "common/geometry/vector_2")
        vec2_mod = (ok and type(mod) == "table") and mod or false
    end
    if vec2_mod and type(vec2_mod.new) == "function" then
        local ok, v = pcall(vec2_mod.new, x, y)
        if ok and v ~= nil then
            return v
        end
    end
    return nil
end

local function elog()
    local ok, mod = pcall(require, "errorlog")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function finite(n)
    return type(n) == "number" and n == n and n > -WORLD_LIMIT and n < WORLD_LIMIT
end

local function convert(map_id, x, y)
    local mp = vec2_new(x, y)
    if not mp then
        return nil
    end
    local gui = safe(function() return core.game_ui end)
    if gui and type(gui.get_world_pos_from_map_pos) == "function" then
        local ok, w = pcall(gui.get_world_pos_from_map_pos, map_id, mp)
        if ok and w ~= nil then
            local wx, wy = tonumber(get(w, "x")), tonumber(get(w, "y"))
            if finite(wx) and finite(wy) and not (wx == 0 and wy == 0) then
                return { x = wx, y = wy, z = nil, final = false }
            end
        end
    end
    -- Fallback: the raycasting helper, once for this waypoint.
    local helper = coords()
    if helper and type(helper.map_to_world) == "function" then
        local ok, w = pcall(helper.map_to_world, helper, map_id, mp, 0)
        if ok and w ~= nil then
            local wx, wy, wz = tonumber(get(w, "x")), tonumber(get(w, "y")), tonumber(get(w, "z"))
            if finite(wx) and finite(wy) and finite(wz) then
                return { x = wx, y = wy, z = wz, final = true }
            end
        end
    end
    return nil
end

local function to_world(wp)
    if not usable(wp) then
        return nil
    end
    local map_id = tonumber(wp.map_id)
    local x = tonumber(wp.x)
    local y = tonumber(wp.y)
    if not x or not y or x ~= x or y ~= y or x < 0 or x > 1 or y < 0 or y > 1 then
        return nil
    end

    local key = string.format("%d|%.4f|%.4f", map_id, x, y)
    local e = conv[key]
    if e == false then
        return nil
    end
    if e == nil then
        if conv_n >= CONV_MAX then
            conv, conv_n = {}, 0
        end
        e = convert(map_id, x, y)
        conv[key] = e or false
        conv_n = conv_n + 1
        local log = elog()
        if log then
            if e then
                log.trail("waypoint", "map %d (%.4f, %.4f) -> world (%.1f, %.1f)%s",
                    map_id, x, y, e.x, e.y, e.final and string.format(" z %.1f", e.z) or "")
            else
                log.warn("waypoint map %d (%.4f, %.4f) could not be converted", map_id, x, y)
            end
        end
        if not e then
            return nil
        end
    end

    local z = e.z
    if not e.final then
        local me = safe(function() return izi.me():get_position() end)
        local mx, my, mz = tonumber(get(me, "x")), tonumber(get(me, "y")), tonumber(get(me, "z"))
        if not mx or not my or not mz then
            return nil
        end
        z = mz
        local dx, dy = e.x - mx, e.y - my
        if dx * dx + dy * dy <= HEIGHT_RANGE * HEIGHT_RANGE then
            local ok, h = pcall(izi.get_terrain_height, e.x, e.y)
            if ok and finite(h) and math.abs(h - mz) < 200 then
                e.z, e.final = h, true
                z = h
            end
        end
    end
    return vec3.new(e.x, e.y, z)
end

local function raw_waypoint()
    refresh()
    return snap.wp
end

local function raw_step_waypoints()
    refresh()
    return snap.step_wps
end

--- Where the guide's arrow is pointing right now, in world coordinates.
--- Returns position, distance, title - or nil when there is nothing usable.
function guide.waypoint()
    local wp = raw_waypoint()
    local pos = to_world(wp)
    if not pos then
        return nil
    end
    return pos, tonumber(wp.dist), (type(wp.title) == "string" and wp.title ~= "") and wp.title or nil
end

local compute_goal_waypoints

--- The waypoints that belong to one goal, as { pos, title } in world space.
---
--- RestedXP tags each active waypoint with the goal it serves (goal_num), so
--- a step that accepts from one NPC and kills at a camp across the zone sends
--- each goal to its own spot rather than everything to the arrow. The arrow
--- target is used when no step waypoint names the goal.
function guide.goal_waypoints(goal)
    local key = "wps:" .. tostring(type(goal) == "table" and goal.index or 0)
    return memo(key, function() return compute_goal_waypoints(goal) end) or {}
end

compute_goal_waypoints = function(goal)
    local out = {}
    local index = type(goal) == "table" and goal.index or nil
    if index then
        local list = raw_step_waypoints()
        for i = 1, #list do
            local wp = list[i]
            if type(wp) == "table" and tonumber(wp.goal_num) == index then
                local pos = to_world(wp)
                if pos then
                    out[#out + 1] = {
                        pos = pos,
                        title = (type(wp.title) == "string" and wp.title ~= "") and wp.title or nil,
                    }
                end
            end
        end
    end
    if #out == 0 then
        local pos, _, title = guide.waypoint()
        if pos then
            out[1] = { pos = pos, title = title }
        end
    end
    return out
end

--- Is the current waypoint on another continent? Worth saying out loud in the
--- status line: the bot will not walk, and the reason is not obvious.
function guide.wrong_continent()
    local wp = raw_waypoint()
    return type(wp) == "table" and wp.wrong_continent == true
end

--- Every waypoint of the current step, in world coordinates.
function guide.step_waypoints()
    local out = {}
    local list = raw_step_waypoints()
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

local compute_snapshot

--- Everything the Questing tab shows, in one table. Never throws. Built once
--- per window; the tab reads the same table on every frame in between.
function guide.snapshot()
    return memo("snapshot", compute_snapshot)
end

compute_snapshot = function()
    local out = {
        loaded = guide.is_loaded(),
        ready = false,
        step = 0,
        goals = {},
        goal = nil,
        kind = nil,
        objectives = {},
        waypoint = nil,
        wrong_continent = false,
        stickies = 0,
        describe = guide.describe(),
    }
    if not out.loaded then
        return out
    end
    out.ready = guide.ready()
    if not out.ready then
        return out
    end
    out.step = guide.step_num()
    out.goals = guide.goals()
    out.goal = guide.goal()
    if out.goal then
        out.kind = guide.classify(out.goal)
        out.objectives = guide.objectives(out.goal.quest_id)
    end
    local wp = raw_waypoint()
    if type(wp) == "table" and tonumber(wp.map_id) and tonumber(wp.map_id) ~= 0 then
        out.waypoint = {
            title = (type(wp.title) == "string" and wp.title ~= "") and wp.title or nil,
            dist = tonumber(wp.dist),
            map_id = tonumber(wp.map_id),
        }
    end
    out.wrong_continent = type(wp) == "table" and wp.wrong_continent == true
    out.stickies = #guide.stickies()
    return out
end

return guide
