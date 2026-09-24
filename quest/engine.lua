-- ============================================================================
-- Master Farmer - Grindbot
-- Quest engine — starter slice from quest/data only. Never runs grind.
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.16.0
-- Folder: Master_Farmer_Grindbot
-- ASSUMPTIONS: Undertaker Mordo=1568, Sarvis=1569, Kaltunk=10176, Gornek=3143
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local gui = require("gui")
local modes = require("modes")
local state = require("state")
local npc = require("quest/npc")
local rotation = require("rotation")
local targeting = require("targeting")
local movement = require("movement")
local healing = require("healing")
local guide = require("quest/guide")

local DATA = {}
local DATA_MOD = {}

local quest = {}
local current = nil

local EMPTY_QUEST = "(no starter quests)"
local HUNT_SCAN = 0.8
local HUNT_KILL = 60.0
local HUNT_ARRIVE = 2.0

-- Guide state. The addon owns WHICH objective; these only track where the
-- bot is in walking to it, and reset when the objective changes.
local g_key = nil
local g_move = 1
local g_scan_until = 0
-- Interacting and using are rate limited for the same reason quest dialogs
-- are: re-issuing every frame tears down the frame that just opened.
local g_act_until = 0
local GUIDE_ACT_GAP = 1.5
local INTERACT_YARDS = 5.0

local hunt_move = 1
local hunt_scan_until = 0
local hunt_kill_until = 0
local hunt_quest_id = nil

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local function list_for(player)
    local race_id = safe(function() return player:get_race_id() end)
    local key = modes.race_key(race_id)
    if not key then
        return nil, race_id, nil
    end
    local list = DATA[key]
    if type(list) == "table" then
        return list, race_id, key
    end
    for old_key, mod in pairs(DATA_MOD) do
        if old_key ~= key then
            DATA[old_key] = nil
            DATA_MOD[old_key] = nil
            package.loaded[mod] = nil
        end
    end
    local mod = "quest/data/" .. key
    local ok, data = pcall(require, mod)
    if not ok or type(data) ~= "table" then
        return nil, race_id, key
    end
    DATA[key] = data
    DATA_MOD[key] = mod
    pcall(collectgarbage, "step", 200)
    return data, race_id, key
end

local function skipped_id(id)
    if type(id) ~= "number" then
        return false
    end
    local bag = state.quest.skipped
    return type(bag) == "table" and bag[id] == true
end

local function quest_done(id)
    if type(id) ~= "number" then
        return false
    end
    return safe(function()
        return core.quests.is_quest_flagged_completed(id)
    end) == true
end

local function hunt_text(row)
    if type(row) ~= "table" or type(row.hunt) ~= "table" then
        return "Talk / travel"
    end
    local mobs = row.hunt.mobs
    if type(mobs) ~= "table" or #mobs == 0 then
        return "Talk / travel"
    end
    local parts = {}
    for i = 1, #mobs do
        parts[#parts + 1] = tostring(mobs[i])
    end
    return "Kill " .. table.concat(parts, ", ")
end

local function npc_line(player, npc_id)
    if type(npc_id) ~= "number" or npc_id <= 0 then
        return "-"
    end
    local name = npc.name_of(player, npc_id)
    if type(name) == "string" and name ~= "" then
        return string.format("%s (%d)", name, npc_id)
    end
    return tostring(npc_id)
end

local function leave_hunt()
    hunt_kill_until = 0
    if state.target and state.target.kind == "kill" then
        if movement and type(movement.combat_release) == "function" then
            movement.combat_release()
        end
        state.reset_target()
    end
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

local function fight_unit(player, unit, note)
    local now = izi.now()
    if not unit or safe(function() return unit:is_valid() end) ~= true then
        if movement and type(movement.nav_stop) == "function" then
            movement.nav_stop()
        end
        if movement and type(movement.combat_release) == "function" then
            movement.combat_release()
        end
        state.reset_target()
        return false
    end
    if hunt_kill_until > 0 and now > hunt_kill_until and state.target.kind == "kill" then
        state.mark_killed(state.target.guid)
        if movement and type(movement.nav_stop) == "function" then
            movement.nav_stop()
        end
        if movement and type(movement.combat_release) == "function" then
            movement.combat_release()
        end
        state.reset_target()
        return false
    end
    if safe(function() return unit:is_dead_or_ghost() end) == true or safe(function() return unit:is_dead() end) == true then
        state.mark_killed(state.target.guid or safe(function() return unit:get_guid() end))
        if movement and type(movement.nav_stop) == "function" then
            movement.nav_stop()
        end
        if movement and type(movement.combat_release) == "function" then
            movement.combat_release()
        end
        state.reset_target()
        return false
    end
    local dist = safe(function() return player:distance_to(unit) end) or 99
    if dist > 1000 then
        if movement and type(movement.combat_release) == "function" then
            movement.combat_release()
        end
        state.reset_target()
        return false
    end
    pcall(function()
        core.input.set_target(unit)
    end)
    local yards = combat_yards(player)
    targeting.start_auto_attack(player, unit)
    if not movement.combat_engage(player, unit, yards) then
        if state.is_unreachable and state.is_unreachable(state.target.guid) then
            if movement and type(movement.combat_release) == "function" then
                movement.combat_release()
            end
            state.reset_target()
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

--- Walk hunt.coords and kill hunt.mobs from the quest data file. No grind zones.
local function hunt_tick(player, row)
    local hunt = row.hunt
    if type(hunt) ~= "table" then
        return
    end
    if hunt_quest_id ~= row.id then
        hunt_quest_id = row.id
        hunt_move = 1
        hunt_scan_until = 0
        hunt_kill_until = 0
        if movement and type(movement.combat_release) == "function" then
            movement.combat_release()
        end
        state.reset_target()
    end
    if healing and type(healing.is_resting) == "function" and healing.is_resting() then
        if movement and type(movement.nav_stop) == "function" then
            movement.nav_stop()
        end
        pcall(function()
            core.input.stop_attack()
        end)
        return
    end

    local now = izi.now()
    local unit = state.target.unit
    if unit and state.target.kind == "kill" then
        if fight_unit(player, unit, "Kill for " .. (row.name or tostring(row.id))) then
            return
        end
    end

    local pull = 50
    if type(hunt.pull) == "number" and hunt.pull > 0 then
        pull = hunt.pull
    end

    local enemies = targeting.find_mobs(player, hunt.mobs, pull, true)
    local next_unit = targeting.nearest(player, enemies)
    if not next_unit and now >= hunt_scan_until then
        hunt_scan_until = now + HUNT_SCAN
        local in_combat = safe(function() return player:is_in_combat() end) == true
        if in_combat then
            local pack = targeting.combat_scan(player, pull)
            next_unit = targeting.nearest(player, pack)
        end
    end
    if next_unit then
        targeting.set_current(next_unit, "kill")
        hunt_kill_until = now + HUNT_KILL
        fight_unit(player, next_unit, "Kill for " .. (row.name or tostring(row.id)))
        return
    end

    local coords = hunt.coords
    if type(coords) ~= "table" or #coords < 1 then
        state.set_note("Quest", "Waiting for objectives")
        return
    end
    local n = #coords
    if hunt_move > n then
        hunt_move = 1
    end
    local pos = coords[hunt_move]
    if not pos then
        hunt_move = hunt_move + 1
        return
    end
    if movement.arrived(pos, HUNT_ARRIVE) then
        hunt_move = hunt_move + 1
        if hunt_move > n then
            hunt_move = 1
        end
        return
    end
    if movement.is_blocked(pos) or movement.last_fail_offmesh() then
        hunt_move = hunt_move + 1
        if hunt_move > n then
            hunt_move = 1
        end
        movement.clear_fail()
        return
    end
    if movement.is_quiet() or movement.in_combat_movement() then
        state.set_note("Quest", "Nav settle")
        return
    end
    if movement.is_moving() then
        state.set_note("Quest", "Kill for " .. (row.name or tostring(row.id)))
        return
    end
    state.set_note("Quest", "Kill for " .. (row.name or tostring(row.id)))
    movement.nav_to(pos, true)
end

function quest.is_ready(player)
    if gui.mode() ~= modes.QUEST then
        return false
    end
    if not player then
        return false
    end
    if not rotation.supported(safe(function() return player:get_class() end)) then
        return false
    end
    local race_id = safe(function() return player:get_race_id() end)
    return modes.race_has_starter_quests(race_id)
end

function quest.status_text()
    if current then
        return string.format("%s (%d)", current.name or "Quest", current.id or 0)
    end
    return "No starter quest"
end

function quest.current()
    return current
end

function quest.catalog(player)
    local list = list_for(player)
    if type(list) == "table" then
        return list
    end
    return {}
end

function quest.labels(player)
    local list = quest.catalog(player)
    local labels = {}
    if #list == 0 then
        labels[1] = EMPTY_QUEST
        return labels
    end
    for i = 1, #list do
        local row = list[i]
        local name = row.name or ("Quest " .. tostring(row.id or 0))
        local mark = ""
        if skipped_id(row.id) then
            mark = " [skip]"
        elseif quest_done(row.id) then
            mark = " [done]"
        end
        labels[i] = string.format("%s (%d)%s", name, row.id or 0, mark)
    end
    return labels
end

function quest.row_at(player, index)
    local list = quest.catalog(player)
    if type(index) ~= "number" or index < 1 or index > #list then
        return nil
    end
    return list[index]
end

local function pick(player)
    local list = list_for(player)
    if type(list) ~= "table" then
        return nil
    end
    local level = safe(function() return player:get_level() end) or 1
    if gui.is_on("quest_force") == true then
        local row = quest.row_at(player, gui.quest_index())
        if row and not quest_done(row.id) and not skipped_id(row.id) then
            return row
        end
    end
    for i = 1, #list do
        local row = list[i]
        if not quest_done(row.id) and not skipped_id(row.id) then
            if level >= (row.min_level or 1) and level <= (row.max_level or 60) then
                return row
            end
        end
    end
    return nil
end

function quest.snapshot(player)
    local list, race_id, key = list_for(player)
    if type(list) ~= "table" then
        list = {}
    end
    local labels = quest.labels(player)
    local index = 1
    if gui and type(gui.quest_index) == "function" then
        index = gui.quest_index()
    end
    if index < 1 then
        index = 1
    end
    if index > #labels then
        index = #labels
    end
    local selected = list[index]
    local start_npc = selected and selected.start_npc or nil
    local end_npc = selected and selected.end_npc or nil
    local on_it = false
    if selected and selected.id then
        on_it = safe(function() return core.quests.is_on_quest(selected.id) end) == true
    end
    local complete = false
    if selected and selected.id and on_it then
        complete = npc.is_complete(selected.id, selected.name) == true
    end
    local phase = "-"
    if selected then
        if skipped_id(selected.id) then
            phase = "Skipped"
        elseif quest_done(selected.id) then
            phase = "Completed"
        elseif not on_it then
            phase = "Accept at start NPC"
        elseif complete then
            phase = "Turn in at end NPC"
        elseif selected.hunt then
            phase = "Hunt"
        else
            phase = "Travel to end NPC"
        end
    end
    return {
        race_id = race_id,
        race_key = key,
        race_label = modes.race_label(race_id) or "Unknown",
        race_ok = modes.race_has_starter_quests(race_id) == true,
        count = #list,
        labels = labels,
        index = index,
        selected = selected,
        current = current,
        status = quest.status_text(),
        note = state.note or "",
        phase = phase,
        start_npc = start_npc,
        end_npc = end_npc,
        start_name = npc_line(player, start_npc),
        end_name = npc_line(player, end_npc),
        hunt = hunt_text(selected),
        min_level = selected and selected.min_level or nil,
        max_level = selected and selected.max_level or nil,
        map_id = selected and selected.start and selected.start.map_id or nil,
        done = selected and quest_done(selected.id) or false,
        skipped = selected and skipped_id(selected.id) or false,
        on_quest = on_it,
    }
end

-- ----------------------------------------------------------------------------
-- GUIDE
-- ----------------------------------------------------------------------------
--- Follow the addon's current step.
---
--- The guide decides what to do; this does it with the same helpers the catalog
--- path uses, so accepting, turning in, fighting and walking behave
--- identically whichever source chose the target.
---
--- Returns true when it handled the tick. False means the guide had nothing to
--- say and the caller should fall back to its own catalog.
local function guide_tick(player)
    if not guide.ready() then
        return false
    end

    local goal = guide.goal()
    if not goal then
        -- Every goal of the step is done and the addon has not moved on yet.
        -- Standing still for a frame is right: inventing work here would
        -- fight whatever it does next.
        state.set_note("Quest", "Guide: step complete")
        return true
    end

    -- A rest outranks the guide, exactly as it outranks a hunt.
    if healing and type(healing.is_resting) == "function" and healing.is_resting() then
        if movement and type(movement.nav_stop) == "function" then
            movement.nav_stop()
        end
        pcall(function() core.input.stop_attack() end)
        return true
    end

    local kind = guide.classify(goal)

    local unit_id = nil
    local name_a = goal.text
    local name_b = nil

    -- RestedXP names no NPC on any goal. Its accept and turnin elements hold
    -- questId, title and text; element.ids is never set by them. So there is
    -- no id or name to resolve a quest giver with, and the dialog branches
    -- below reach it by proximity at the waypoint instead - see
    -- guide.nearest_talkable, which is the primary path here rather than a
    -- fallback.

    -- Turn "still not finding the NPC" into something readable. Off unless
    -- the Quest Debug box is ticked.
    if gui.is_on("quest_debug") then
        local ok_d, dbg = pcall(require, "debuglog")
        local function say(fmt, ...)
            local text = string.format(fmt, ...)
            core.log("[Master Farmer - Grindbot] guide: " .. text)
            if ok_d and dbg and type(dbg.line) == "function" then
                dbg.line("guide", "%s", text)
            end
        end

        local found, how = npc.find(player, unit_id, name_a, name_b, 100)
        say("action=%s kind=%s npc_id=%s target_id=%s npc=%s target=%s -> %s%s",
            tostring(goal.action), tostring(kind), tostring(goal.npc_id),
            tostring(goal.target_id), tostring(name_a), tostring(name_b),
            found and "FOUND by " or "NOT FOUND", found and tostring(how) or "")


        if pos then
            local me = safe(function() return player:get_position() end)
            say("waypoint %.1f,%.1f,%.1f  player %.1f,%.1f,%.1f",
                pos.x, pos.y, pos.z,
                me and me.x or 0, me and me.y or 0, me and me.z or 0)
        else
            say("no usable waypoint")
        end
    end
    local pos, zdist, title = guide.waypoint()
    local label = goal.target or goal.npc or title or tostring(goal.target_id or goal.npc_id or "?")

    -- Anything that changes what we are walking toward restarts the walk.
    local key = string.format("%s|%s|%s|%s", kind, tostring(goal.quest_id),
        tostring(goal.npc_id or goal.target_id), tostring(goal.index))
    if key ~= g_key then
        g_key = key
        g_move = 1
        g_scan_until = 0
        g_act_until = 0
        state.reset_target()
    end

    -- ---- quest dialog -----------------------------------------------------
    -- npc.at_npc walks there and returns true once the NPC is in reach, which
    -- is the same handshake the catalog path uses.
    -- Some steps are only `turnin ... |goto x,y` with no talk goal anywhere,
    -- so nothing names the NPC at all. Once the bot is standing where the
    -- guide sent it, the nearest thing it cannot attack is the quest giver.
    if (kind == "accept" or kind == "turnin") and not unit_id and not name_a and not name_b then
        local near = guide.nearest_talkable(player, 8)
        if near then
            local now = izi.now()
            if now >= g_act_until then
                g_act_until = now + GUIDE_ACT_GAP
                pcall(function() core.input.interact_with_object(near) end)
            end
            state.set_note("Quest", "Guide: " .. kind .. " at the nearest NPC")
            -- The dialog handlers take it from here on the next tick: the
            -- gossip frame is matched on the quest, not on who opened it.
            if goal.quest_id then
                state.quest.id = goal.quest_id
                if kind == "accept" then
                    npc.accept(player, goal.quest_id, nil, nil)
                else
                    npc.turn_in(player, goal.quest_id, nil, nil)
                end
            end
            return true
        end
        -- Not there yet: fall through to the walk below.
    end

    if kind == "accept" and unit_id then
        state.set_note("Quest", "Guide: accept " .. label)
        if npc.at_npc(player, unit_id, pos, name_a, name_b) then
            if goal.quest_id then
                state.quest.id = goal.quest_id
                npc.accept(player, goal.quest_id, goal.npc, unit_id)
            else
                -- No quest id from the addon. Open the dialog anyway: the
                -- gossip handler matches on title, and a frame the player can
                -- see beats standing silently next to the quest giver.
                npc.talk(player, unit_id, pos, name_a, name_b)
            end
        end
        return true
    end

    if kind == "turnin" and unit_id then
        state.set_note("Quest", "Guide: turn in " .. label)
        if npc.at_npc(player, unit_id, pos, name_a, name_b) then
            if goal.quest_id then
                state.quest.id = goal.quest_id
                npc.turn_in(player, goal.quest_id, goal.npc, unit_id)
            else
                npc.talk(player, unit_id, pos, name_a, name_b)
            end
        end
        return true
    end

    if kind == "talk" and unit_id then
        -- npc.talk walks AND interacts. at_npc only walks - it returns true
        -- once the NPC is in reach and leaves the dialog to accept/turn_in -
        -- so calling it alone here meant the bot arrived and stood there.
        state.set_note("Quest", "Guide: talk to " .. label)
        npc.talk(player, unit_id, pos, name_a, name_b)
        return true
    end

    -- ---- use an item from the bags -----------------------------------------
    -- "use" goals: a quest item that has to be used, sometimes on a
    -- target, sometimes on the spot. Rate limited because a use that does not
    -- clear the goal would otherwise be issued every frame.
    if kind == "item" then
        local entry = guide.find_bag_item()
        if entry then
            local now = izi.now()
            if now >= g_act_until then
                g_act_until = now + GUIDE_ACT_GAP
                local on = state.target.unit
                if guide.use_bag_item(entry, on) then
                    state.set_note("Quest", "Guide: use " .. label)
                    return true
                end
                state.set_note("Quest", "Guide: could not use " .. label)
            else
                state.set_note("Quest", "Guide: use " .. label)
            end
            return true
        end
        -- Not carrying it yet. Walk to the waypoint; the step usually wants
        -- the item picked up there first.
    end

    -- ---- click a world object ----------------------------------------------
    -- Chests, levers, herbs, quest pickups on the ground. These are not units,
    -- so the mob scan never sees them and find_object walks the visible-object
    -- list instead.
    if kind == "object" or kind == "collect" then
        local obj, odist = guide.find_object(player, 40)
        if obj then
            if type(odist) == "number" and odist <= INTERACT_YARDS then
                local now = izi.now()
                if now >= g_act_until then
                    g_act_until = now + GUIDE_ACT_GAP
                    -- Interacting re-issued every frame tears down the frame it
                    -- just opened; that is the 1.5.1 lesson from quest dialogs.
                    pcall(function() core.input.interact_with_object(obj) end)
                end
                state.set_note("Quest", "Guide: click " .. label)
                return true
            end
            local opos = safe(function() return obj:get_position() end)
            if opos and not movement.is_blocked(opos) then
                state.set_note("Quest", "Guide: " .. label)
                if not movement.is_moving() then
                    movement.nav_to(opos, true)
                end
                return true
            end
        end
        -- collect falls through to the kill scan: the thing may drop from a
        -- mob rather than lie on the ground, and the goal does not say which.
    end

    -- ---- kill, and collect-by-killing --------------------------------------
    if kind == "kill" or kind == "collect" then
        local now = izi.now()
        local unit = state.target.unit
        if unit and state.target.kind == "kill" then
            if fight_unit(player, unit, "Guide: " .. label) then
                return true
            end
        end

        -- guide.find_mob, not targeting.find_mobs by id.
        --
        -- find_mobs matches on npc id, and RestedXP supplies none for a mob
        -- step: CheckNpcIds rewrites element.mobs and element.unitlist to
        -- NAME strings on an English client. An id scan would find nothing
        -- every time. find_mob matches the guide's names against the unit
        -- names on screen, and still takes an id when one is offered.
        if now >= g_scan_until then
            g_scan_until = now + HUNT_SCAN
            local next_unit = guide.find_mob(player, 50)
            if next_unit then
                targeting.set_current(next_unit, "kill")
                fight_unit(player, next_unit, "Guide: " .. label)
                return true
            end
        end
        -- Nothing in range yet: walk to the waypoint and look again there.
    end

    -- ---- walk ---------------------------------------------------------------
    if not pos then
        -- No waypoint we can place. Say so rather than standing silently:
        -- either the addon has none, or map_to_world could not convert it.
        state.set_note("Quest", "Guide: no usable waypoint for " .. label)
        return true
    end

    if movement.arrived(pos, HUNT_ARRIVE) then
        -- Arrived and there is still nothing to do here. Try the step's other
        -- waypoints before giving up on the step.
        local alts = guide.step_waypoints()
        if #alts > 0 then
            g_move = g_move + 1
            if g_move > #alts then
                g_move = 1
            end
            local alt = alts[g_move]
            if alt and not movement.arrived(alt, HUNT_ARRIVE) then
                state.set_note("Quest", "Guide: " .. label)
                movement.nav_to(alt, true)
                return true
            end
        end
        state.set_note("Quest", "Guide: waiting at " .. label)
        return true
    end

    if movement.is_blocked(pos) or movement.last_fail_offmesh() then
        movement.clear_fail()
        state.set_note("Quest", "Guide: cannot reach " .. label)
        return true
    end
    if movement.is_quiet() or movement.in_combat_movement() then
        state.set_note("Quest", "Nav settle")
        return true
    end

    if type(zdist) == "number" then
        state.set_note("Quest", string.format("Guide: %s  %.0fy", label, zdist))
    else
        state.set_note("Quest", "Guide: " .. label)
    end
    if not movement.is_moving() then
        movement.nav_to(pos, true)
    end
    return true
end

function quest.tick(player)
    -- The addon leads when it is switched on and has something to say.
    -- Falling through to the catalog when it does not means a guide that
    -- finishes, or is not installed, leaves the bot working rather than idle.
    if gui.is_on("guide") and guide_tick(player) then
        return
    end

    current = pick(player)
    if not current then
        leave_hunt()
        hunt_quest_id = nil
        state.set_note("Quest", "Starters complete")
        return
    end
    state.quest.id = current.id
    local on_it = safe(function() return core.quests.is_on_quest(current.id) end) == true
    if not on_it then
        leave_hunt()
        state.set_note("Quest", "Accept " .. (current.name or tostring(current.id)))
        if npc.at_npc(player, current.start_npc, current.start) then
            npc.accept(player, current.id, current.name, current.start_npc)
        end
        return
    end
    if npc.is_complete(current.id, current.name) then
        leave_hunt()
        state.set_note("Quest", "Turn in " .. (current.name or tostring(current.id)))
        if npc.at_npc(player, current.end_npc, current.finish) then
            npc.turn_in(player, current.id, current.name, current.end_npc)
        end
        return
    end
    if current.hunt then
        hunt_tick(player, current)
        return
    end
    leave_hunt()
    state.set_note("Quest", "Travel " .. (current.name or tostring(current.id)))
    npc.at_npc(player, current.end_npc, current.finish)
end

return quest
