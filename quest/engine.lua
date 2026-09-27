-- ============================================================================
-- Master Farmer - Grindbot
-- Quest engine - driven entirely by the RestedXP Guides addon. Never runs grind.
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.20.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- RestedXP is the single source of quest information:
--
--   which quest, and what to do with it   the current step's first open goal
--   where to go                           the goal's own step waypoints, then
--                                         the arrow
--   who to talk to                        the waypoint title, an NPC learned
--                                         on an earlier visit, or the nearest
--                                         friendly unit at the waypoint
--   what to kill / collect / click        the quest's RestedXP objectives:
--                                         their text names the target and
--                                         their type says which of the three
--   when it is done                       RestedXP's own completion flags
--
-- This file does the doing, with the dialog helpers in quest/npc and the same
-- fight / walk primitives grind mode uses. quest/guide only reads the addon.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local gui = require("gui")
local state = require("state")
local npc = require("quest/npc")
local rotation = require("rotation")
local targeting = require("targeting")
local movement = require("movement")
local healing = require("healing")
local geometry = require("geometry")
local guide = require("quest/guide")

local quest = {}

local SCAN_GAP = 0.8          -- seconds between target scans
local KILL_TIMEOUT = 60.0     -- give up on one mob after this
local ARRIVE = 3.0            -- yards: standing on a waypoint
local TALK_REACH = 4.0        -- yards: close enough to interact
local TALK_SEARCH = 12.0      -- yards around the waypoint to look for a giver
local ACT_GAP = 1.5           -- seconds between interacts / item uses
local MOB_RANGE = 50          -- yards: named quest mobs
local OBJECT_RANGE = 40       -- yards: quest objects on the ground
local CAMP_RADIUS = 45        -- yards around a waypoint for unnamed drop sources

-- Walk state for the current goal. RestedXP owns WHICH goal; these only track
-- where the bot is in walking to it, and reset when the goal changes.
local g_key = nil
local g_move = 1
local g_scan_until = 0
local g_act_until = 0
local g_kill_until = 0

-- The NPC the bot opened a dialog with, remembered until the goal changes so
-- it can be recorded as that quest's giver once the accept or turnin lands.
local g_pending = nil

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

-- Breadcrumbs for scripts_log/MASTER_FARMER_ERRORS. errorlog.trail writes a
-- line only when it differs from the previous one with the same tag, so these
-- can sit on per-frame paths.
local errorlog = nil
do
    local ok, mod = pcall(require, "errorlog")
    if ok and type(mod) == "table" then
        errorlog = mod
    end
end

local function trail(tag, fmt, ...)
    if errorlog then
        errorlog.trail(tag, fmt, ...)
    end
end

local function debug(fmt, ...)
    if not gui.is_on("quest_debug") then
        return
    end
    local text = string.format(fmt, ...)
    core.log("[Master Farmer - Grindbot] guide: " .. text)
    local ok, dbg = pcall(require, "debuglog")
    if ok and dbg and type(dbg.line) == "function" then
        dbg.line("guide", "%s", text)
    end
end

local function release_combat()
    if movement and type(movement.nav_stop) == "function" then
        movement.nav_stop()
    end
    if movement and type(movement.combat_release) == "function" then
        movement.combat_release()
    end
    state.reset_target()
end

local function combat_yards(player)
    local yards = 30
    if type(rotation.combat_range) == "function" then
        yards = rotation.combat_range(player)
    end
    if type(yards) ~= "number" or yards < 5 then
        yards = 30
    end
    return yards
end

--- Fight the current kill target. Returns false once there is nothing left to
--- fight - dead, gone, unreachable or timed out.
local function fight_unit(player, unit, note)
    local now = izi.now()
    if not unit or safe(function() return unit:is_valid() end) ~= true then
        release_combat()
        return false
    end
    if g_kill_until > 0 and now > g_kill_until and state.target.kind == "kill" then
        state.mark_killed(state.target.guid)
        release_combat()
        return false
    end
    if safe(function() return unit:is_dead_or_ghost() end) == true or safe(function() return unit:is_dead() end) == true then
        state.mark_killed(state.target.guid or safe(function() return unit:get_guid() end))
        release_combat()
        return false
    end
    local dist = safe(function() return player:distance_to(unit) end) or 99
    if dist > 1000 then
        release_combat()
        return false
    end
    pcall(function()
        core.input.set_target(unit)
    end)
    local yards = combat_yards(player)
    targeting.start_auto_attack(player, unit)
    if not movement.combat_engage(player, unit, yards) then
        if state.is_unreachable and state.is_unreachable(state.target.guid) then
            release_combat()
            state.set_note("Quest", "Skip unreachable")
            return false
        end
        movement.face(unit)
        state.set_note("Quest", note or "Closing")
        rotation.tick(player, unit, { enemies = targeting.combat_scan(player, yards), no_move = true })
        return true
    end
    movement.face(unit)
    state.set_note("Quest", note or "Killing")
    rotation.tick(player, unit, { enemies = targeting.combat_scan(player, yards), no_move = true })
    return true
end

local function engage(player, unit, note)
    trail("act", "engage %s (%s)", tostring(safe(function() return unit:get_name() end)), tostring(note))
    targeting.set_current(unit, "kill")
    g_kill_until = izi.now() + KILL_TIMEOUT
    fight_unit(player, unit, note)
end

--- Anything already fighting us comes first, whatever the goal is: walking on
--- to a quest giver with three mobs on your back is how a character dies.
local function fight_back(player, label)
    local unit = state.target.unit
    if unit and state.target.kind == "kill" then
        if fight_unit(player, unit, "Guide: " .. label) then
            return true
        end
    end
    if safe(function() return player:is_in_combat() end) ~= true then
        return false
    end
    local pack = targeting.combat_scan(player, combat_yards(player) + 10)
    local attacker = targeting.nearest(player, pack)
    if attacker then
        engage(player, attacker, "Guide: defending")
        return true
    end
    return false
end

--- Walk toward a position. Returns true while there is still walking to do.
local function walk_to(pos, note)
    if movement.arrived(pos, ARRIVE) then
        return false
    end
    local me = safe(function() return izi.me():get_position() end)
    trail("walk", "to (%.0f, %.0f, %.0f) %.0fy away for %s", pos.x, pos.y, pos.z,
        me and geometry.distance(me, pos) or -1, tostring(note))
    if movement.is_blocked(pos) or movement.last_fail_offmesh() then
        movement.clear_fail()
        state.set_note("Quest", "Guide: cannot reach " .. note)
        return true
    end
    if movement.is_quiet() or movement.in_combat_movement() then
        state.set_note("Quest", "Nav settle")
        return true
    end
    state.set_note("Quest", "Guide: " .. note)
    if not movement.is_moving() then
        movement.nav_to(pos, true)
    end
    return true
end

--- The quest title the NPC's frames will list, for selecting it.
---
--- The quest log has it for a turnin. An accept is not in the log yet, so the
--- guide line is used with its verb stripped; quest/npc also takes a lone
--- entry without any title match, which covers most givers.
local function quest_title(goal, kind)
    local title = guide.log_title(goal.quest_id)
    if title then
        return title
    end
    local text = goal.text
    if type(text) ~= "string" then
        return nil
    end
    if kind == "accept" then
        text = text:gsub("^[Aa]ccept%s+", "")
    elseif kind == "turnin" then
        text = text:gsub("^[Tt]urn%s*[Ii]n%s+", "")
    end
    return text
end

--- Find the NPC for an accept, a turnin or a talk goal.
---
--- In order of how certain the answer is:
---   1. an NPC learned for this exact quest on an earlier visit
---   2. the waypoint's title, which RestedXP sets to the NPC it points at
---   3. the player's own target, when it is a friendly creature
---   4. the nearest friendly unit standing at the waypoint
local function find_giver(player, goal, kind, wps)
    local known = guide.known_quest_npc(kind, goal.quest_id, goal.text)
    if known then
        local unit = targeting.find_npc(player, known, 80)
        if unit then
            return unit, "learned id " .. tostring(known)
        end
    end
    for i = 1, #wps do
        local title = wps[i].title
        if title then
            local unit = targeting.find_named(player, title, nil, 80)
            if unit then
                return unit, "waypoint title '" .. title .. "'"
            end
        end
    end
    local tid, tunit = guide.target_npc_id(player)
    if tid and tunit and safe(function() return player:can_attack(tunit) end) == false then
        return tunit, "player target"
    end
    for i = 1, #wps do
        local unit = guide.nearest_talkable(player, TALK_SEARCH, wps[i].pos)
        if unit then
            return unit, "nearest at waypoint"
        end
    end
    if #wps == 0 then
        local unit = guide.nearest_talkable(player, TALK_SEARCH)
        if unit then
            return unit, "nearest"
        end
    end
    return nil, nil
end

--- A goal changed: if the previous one was a dialog the bot drove and it
--- landed, record the NPC as that quest's giver or taker.
local function commit_pending()
    local p = g_pending
    g_pending = nil
    if not p or not p.npc_id or not p.quest_id then
        return
    end
    local on = safe(function() return core.quests.is_on_quest(p.quest_id) end) == true
    local landed = (p.kind == "accept" and on) or (p.kind == "turnin" and not on)
    if landed then
        guide.learn_quest_npc(p.kind, p.quest_id, p.npc_id)
        debug("learned %s npc %d for quest %d", p.kind, p.npc_id, p.quest_id)
    end
end

-- ----------------------------------------------------------------------------
-- GOAL HANDLERS
-- ----------------------------------------------------------------------------

local function dialog_goal(player, goal, kind, wps, label)
    local unit, how = find_giver(player, goal, kind, wps)
    if not unit then
        return false
    end
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > TALK_REACH then
        local p = safe(function() return unit:get_position() end)
        if p then
            walk_to(p, label)
            return true
        end
        return false
    end
    movement.nav_stop()

    local npc_id = geometry.object_id(unit)
    trail("act", "%s with %s npc %s via %s", kind,
        tostring(safe(function() return unit:get_name() end)), tostring(npc_id), tostring(how))
    if (kind == "accept" or kind == "turnin") and goal.quest_id then
        g_pending = { kind = kind, quest_id = goal.quest_id, npc_id = npc_id }
        state.quest.id = goal.quest_id
        local title = quest_title(goal, kind)
        if kind == "accept" then
            state.set_note("Quest", "Guide: accept " .. tostring(title or goal.quest_id))
            npc.accept(player, goal.quest_id, title, npc_id, unit)
        else
            state.set_note("Quest", "Guide: turn in " .. tostring(title or goal.quest_id))
            npc.turn_in(player, goal.quest_id, title, npc_id, unit)
        end
        debug("%s quest %d at %s (npc %s)", kind, goal.quest_id, tostring(how), tostring(npc_id))
        return true
    end

    -- Talk / trainer / vendor / flight master: open the frame, and let the
    -- trainer, vendor and dialog modules act on it. Rate limited, because
    -- re-interacting tears down the frame that just opened.
    local now = izi.now()
    local open = safe(function() return core.quests.is_gossip_frame_shown() end) == true
    if not open and now >= g_act_until then
        g_act_until = now + ACT_GAP
        pcall(function() core.input.interact_with_object(unit) end)
        debug("talk to %s", tostring(how))
    end
    state.set_note("Quest", "Guide: talk to " .. label)
    return true
end

local function item_goal(player, goal, label)
    local entry = guide.find_bag_item(goal)
    if not entry then
        return false
    end
    local now = izi.now()
    if now >= g_act_until then
        g_act_until = now + ACT_GAP
        local on = state.target.unit
        if guide.use_bag_item(entry, on) then
            state.set_note("Quest", "Guide: use " .. label)
            return true
        end
        state.set_note("Quest", "Guide: could not use " .. label)
        return true
    end
    state.set_note("Quest", "Guide: use " .. label)
    return true
end

local function object_goal(player, goal, label)
    local obj, odist = guide.find_object(player, OBJECT_RANGE, goal)
    if not obj then
        return false
    end
    if type(odist) == "number" and odist <= TALK_REACH then
        movement.nav_stop()
        local now = izi.now()
        if now >= g_act_until then
            g_act_until = now + ACT_GAP
            pcall(function() core.input.interact_with_object(obj) end)
        end
        state.set_note("Quest", "Guide: click " .. label)
        return true
    end
    local opos = safe(function() return obj:get_position() end)
    if opos and not movement.is_blocked(opos) then
        walk_to(opos, label)
        return true
    end
    return false
end

local function kill_goal(player, goal, kind, wps, label)
    local now = izi.now()
    if now < g_scan_until then
        return false
    end
    g_scan_until = now + SCAN_GAP
    local unit = guide.find_mob(player, MOB_RANGE, goal)
    -- An item that drops from something RestedXP does not name: its waypoints
    -- sit on the camp that drops it, so fight what stands there.
    if not unit and kind == "collect" then
        for i = 1, #wps do
            unit = guide.find_camp_mob(player, wps[i].pos, CAMP_RADIUS)
            if unit then
                break
            end
        end
    end
    if unit then
        engage(player, unit, "Guide: " .. label)
        return true
    end
    return false
end

-- ----------------------------------------------------------------------------
-- TICK
-- ----------------------------------------------------------------------------

local function goal_label(goal, wps)
    local o = guide.goal_objective(goal)
    if o and o.text then
        return o.text
    end
    if goal.text then
        return goal.text
    end
    if wps[1] and wps[1].title then
        return wps[1].title
    end
    return tostring(goal.quest_id or goal.action or "?")
end

function quest.tick(player)
    if not guide.is_loaded() then
        release_combat()
        trail("quest", "RestedXP not loaded")
        state.set_note("Quest", "RestedXP Guides is not loaded")
        return
    end
    if not guide.ready() then
        release_combat()
        trail("quest", "RestedXP has no active step")
        state.set_note("Quest", "RestedXP: no active step - load a guide")
        return
    end

    guide.learn_npc_id(player)

    local goal = guide.goal()
    if not goal then
        -- Every goal of the step is done and the addon has not moved on yet.
        -- Standing still is right: inventing work here would fight whatever
        -- it does next.
        commit_pending()
        state.set_note("Quest", "Guide: step complete")
        return
    end

    -- A rest outranks the guide.
    if healing and type(healing.is_resting) == "function" and healing.is_resting() then
        movement.nav_stop()
        pcall(function() core.input.stop_attack() end)
        return
    end

    local kind = guide.classify(goal)
    local wps = guide.goal_waypoints(goal)
    local label = goal_label(goal, wps)

    local key = string.format("%d|%d|%s|%s", guide.step_num(), goal.index or 0,
        tostring(goal.quest_id), kind)
    if key ~= g_key then
        commit_pending()
        g_key = key
        g_move = 1
        g_scan_until = 0
        g_act_until = 0
        g_kill_until = 0
        state.reset_target()
        trail("quest", "step %d goal %d: %s [%s] %s (quest %s, %d waypoint%s)",
            guide.step_num(), goal.index or 0, tostring(goal.action), kind, tostring(label),
            tostring(goal.quest_id), #wps, #wps == 1 and "" or "s")
        debug("step %d goal %d: %s %s (quest %s, %d waypoint%s)",
            guide.step_num(), goal.index or 0, tostring(goal.action), tostring(label),
            tostring(goal.quest_id), #wps, #wps == 1 and "" or "s")
    end

    if fight_back(player, label) then
        return
    end

    if kind == "accept" or kind == "turnin" or kind == "talk" then
        if dialog_goal(player, goal, kind, wps, label) then
            return
        end
    elseif kind == "item" then
        if item_goal(player, goal, label) then
            return
        end
    elseif kind == "object" then
        if object_goal(player, goal, label) then
            return
        end
    elseif kind == "kill" then
        if kill_goal(player, goal, kind, wps, label) then
            return
        end
    elseif kind == "collect" then
        -- Could be on the ground or a drop: look for the object first.
        if object_goal(player, goal, label) or kill_goal(player, goal, kind, wps, label) then
            return
        end
    end

    -- Nothing to act on here yet: walk the goal's waypoints.
    if #wps == 0 then
        if guide.wrong_continent() then
            state.set_note("Quest", "Guide: target is on another continent")
        else
            state.set_note("Quest", "Guide: no usable waypoint for " .. label)
        end
        return
    end
    if g_move > #wps then
        g_move = 1
    end
    if walk_to(wps[g_move].pos, label) then
        return
    end
    -- Standing on this waypoint with nothing to do. A kill or collect loop
    -- moves on to the next of its waypoints; anything else waits here for the
    -- addon to tick the goal off.
    if #wps > 1 then
        g_move = g_move + 1
        if g_move > #wps then
            g_move = 1
        end
        walk_to(wps[g_move].pos, label)
        return
    end
    state.set_note("Quest", "Guide: waiting at " .. label)
end

-- ----------------------------------------------------------------------------
-- STATUS
-- ----------------------------------------------------------------------------

function quest.is_ready(player)
    return player ~= nil and guide.is_loaded()
end

function quest.status_text()
    return guide.describe()
end

--- What the Questing tab shows.
function quest.snapshot()
    local snap = guide.snapshot()
    snap.note = state.note or ""
    return snap
end

return quest
