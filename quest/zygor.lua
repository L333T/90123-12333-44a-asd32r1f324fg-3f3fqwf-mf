-- ============================================================================
-- Master Farmer - Grindbot
-- Zygor Guides adapter
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.11.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Turns core.addons.zygor into the shapes quest/engine already understands:
-- somewhere to walk, something to kill, or an NPC to talk to.
--
-- Zygor decides WHAT to do. This file only reads it. Nothing here accepts,
-- turns in, fights or moves - the engine owns all of that, exactly as it does
-- for its own catalog, so a Zygor-guided run and a catalog run behave the
-- same way once the target is chosen.
--
-- WAYPOINTS ARE MAP COORDINATES, NOT WORLD COORDINATES
--   get_current_waypoint returns x and y in the 0-1 range, relative to the
--   map. Handing those to the navigator would walk the character to a point
--   a metre from the origin of the continent. coords_helper:map_to_world
--   converts them, and a waypoint that cannot be converted is dropped rather
--   than guessed at.
--
-- EVERYTHING IS OPTIONAL
--   The addon may not be installed, may have no guide loaded, may be between
--   steps, and this whole namespace may be missing on an older build. Every
--   call is wrapped and every accessor answers "nothing to do" rather than
--   throwing, because this runs inside the quest tick.
--
-- THE ACTION VOCABULARY IS ZYGOR'S, NOT OURS
--   goal.action is whatever string Zygor uses - kill, goto, talk, accept,
--   turnin, get, click and so on. The exact set is not documented anywhere we
--   can check, so classify() maps the ones we know onto what the engine can
--   do and sends everything else to "goto". Walking to the waypoint is the
--   honest fallback for an instruction we do not recognise: it makes progress
--   toward whatever the step wants without pretending to understand it.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

local zygor = {}

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

--- The addon namespace, or nil when this build has no core.addons.zygor.
local function api()
    local ns = safe(function()
        return core.addons.zygor
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
function zygor.is_loaded()
    local ns = api()
    if not ns or type(ns.is_loaded) ~= "function" then
        return false
    end
    return safe(function() return ns.is_loaded() end) == true
end

--- Is there a guide step to follow right now?
---
--- False when no guide is loaded, when the guide is finished, or when the
--- addon is not there at all - the engine treats all three the same way.
function zygor.ready()
    if not zygor.is_loaded() then
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
function zygor.step()
    if not zygor.ready() then
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

--- The first goal of the current step that is not finished yet.
---
--- Zygor lists a step's goals in the order it wants them done, so the first
--- incomplete one is the instruction to follow. A step whose goals are all
--- complete returns nil; the addon will move to the next step by itself.
function zygor.goal()
    local step = zygor.step()
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
            return {
                action = (type(g.action) == "string") and g.action or "",
                quest_id = tonumber(g.quest_id),
                npc_id = tonumber(g.npc_id),
                target_id = tonumber(g.target_id),
                target = (type(g.target) == "string") and g.target or nil,
                npc = (type(g.npc) == "string") and g.npc or nil,
                index = i,
            }
        end
    end
    return nil
end

-- ============================================================================
-- WHAT THE ENGINE SHOULD DO
-- ============================================================================
-- Zygor's own words on the left, what this bot can actually do on the right.
--
-- A goal we do not recognise becomes "goto". That is deliberate: walking to
-- the step's waypoint is progress toward whatever it wants, where guessing at
-- an unknown verb is how a bot ends up attacking a quest giver.
local ACTIONS = {
    accept      = "accept",
    turnin      = "turnin",
    ["turn-in"] = "turnin",
    kill        = "kill",
    killrare    = "kill",
    talk        = "talk",
    clicknpc    = "talk",
    ["goto"]    = "goto",
    click       = "interact",
    get         = "interact",
    collect     = "interact",
    ["use"]     = "interact",
}

--- What kind of thing this goal is, in the engine's vocabulary.
function zygor.classify(goal)
    if type(goal) ~= "table" then
        return "goto"
    end
    local a = goal.action
    if type(a) ~= "string" or a == "" then
        return "goto"
    end
    return ACTIONS[string.lower(a)] or "goto"
end

-- ============================================================================
-- OBJECTIVES
-- ============================================================================

--- Every target the current step and its stickies want, split by kind.
---
--- Returns two tables: ids keyed by npc/object id, and names keyed by object
--- name for the goals that carry no id. Zygor does not de-duplicate the list -
--- a target shared by the step and a sticky appears twice - so both are sets
--- rather than arrays.
function zygor.objectives()
    local ids, names = {}, {}
    local ns = api()
    if not ns or type(ns.get_objectives) ~= "function" then
        return ids, names
    end
    local list = safe(function() return ns.get_objectives() end)
    if type(list) ~= "table" then
        return ids, names
    end
    for i = 1, #list do
        local o = list[i]
        if type(o) == "number" then
            ids[o] = true
        elseif type(o) == "string" and o ~= "" then
            names[o] = true
        end
    end
    return ids, names
end

--- The objective ids as an array, for callers that scan by id.
function zygor.objective_ids()
    local ids = zygor.objectives()
    local out = {}
    for id in pairs(ids) do
        out[#out + 1] = id
    end
    table.sort(out)
    return out
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

--- Convert one Zygor waypoint into a world position.
---
--- x and y arrive in the 0-1 range, relative to the map, so they have to go
--- through coords_helper:map_to_world before anything can walk to them.
--- Returns nil when the conversion is unavailable or the result is not a
--- usable position - a waypoint we cannot place is dropped, never guessed.
local function to_world(wp)
    if type(wp) ~= "table" then
        return nil
    end
    local map_id = tonumber(wp.map_id)
    local x = tonumber(wp.x)
    local y = tonumber(wp.y)
    if not map_id or not x or not y then
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

--- Where Zygor is pointing right now, in world coordinates, or nil.
---
--- Also returns the waypoint's own distance and title, which are worth having
--- for the status line: Zygor's distance is measured its own way and is a
--- better thing to show than one we recompute.
function zygor.waypoint()
    if not zygor.ready() then
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

--- Every waypoint of the current step, in world coordinates.
---
--- A step with objectives in several places has several waypoints; this is
--- the list to walk when the current one is unreachable. Waypoints that will
--- not convert are left out rather than included as nil holes.
function zygor.step_waypoints()
    local out = {}
    if not zygor.ready() then
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

--- One line describing what Zygor is asking for, for the GUI.
function zygor.describe()
    if not zygor.is_loaded() then
        return "Zygor not loaded"
    end
    if not zygor.ready() then
        return "Zygor has no active step"
    end
    local goal = zygor.goal()
    if not goal then
        return "Zygor step complete"
    end
    local what = goal.target or goal.npc or tostring(goal.target_id or goal.npc_id or "?")
    local kind = zygor.classify(goal)
    return string.format("%s %s", kind, what)
end

return zygor
