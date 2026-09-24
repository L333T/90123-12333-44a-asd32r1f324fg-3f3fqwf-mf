-- ============================================================================
-- Master Farmer - Grindbot
-- Zygor Guides adapter
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.12.2
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

    -- A world object to click: a chest, a lever, a herb, a quest pickup lying
    -- on the ground. These are NOT units, so the mob scan cannot see them.
    click       = "object",

    -- Zygor uses these for "end up holding N of this". That can be an object
    -- on the ground or a drop from a mob, and the goal does not say which, so
    -- "collect" tries an object first and falls back to killing.
    get         = "collect",
    collect     = "collect",
    buy         = "collect",

    -- Use something already in the bags.
    ["use"]     = "item",
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
-- FINDING THINGS IN THE WORLD
-- ============================================================================

--- The nearest visible game object this step wants, or nil.
---
--- Objects are not units: targeting's mob scan will never return a chest or a
--- herb, so this walks the visible-object list itself. A goal may name its
--- target by id or, when the object has no numeric id, by name - get_objectives
--- returns both and this matches either.
---
--- `range` is in yards and is measured from the player.
function zygor.find_object(player, range)
    if not player then
        return nil, nil
    end
    range = tonumber(range) or 30

    local ids, names = zygor.objectives()
    -- Nothing named means nothing to look for. Returning the nearest object of
    -- any kind would have the bot clicking scenery.
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
            local is_unit = safe(function() return o:is_unit() end)
            if is_unit ~= true then
                local want = false
                local oid = safe(function() return o:get_npc_id() end)
                if type(oid) == "number" and ids[oid] then
                    want = true
                end
                if not want then
                    local oname = safe(function() return o:get_name() end)
                    if type(oname) == "string" and names[oname] then
                        want = true
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

-- ============================================================================
-- FINDING THINGS IN THE BAGS
-- ============================================================================

--- The bag entry for an item this step wants, or nil.
---
--- Returns the entry as core.inventory.get_items_in_bag gives it - the object
--- and its slot - because core.input.use_item wants the object, not an id.
---
--- Matched against the step's objective ids and names, the same set the world
--- search uses: a "use" goal names the item the same way.
function zygor.find_bag_item()
    local ids, names = zygor.objectives()
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
                    local info = (type(iid) == "number")
                        and safe(function() return core.quests.get_item_info(iid) end) or nil
                    if type(info) == "table" and type(info.name) == "string" and names[info.name] then
                        return entry
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
--- first and the raw item id second. Whichever the build wants, one of them
--- lands; if neither does this returns false rather than claiming success.
function zygor.use_bag_item(entry, target)
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
