-- ============================================================================
-- Master Farmer - Grindbot
-- Quest engine - driven entirely by the RestedXP Guides addon. Never runs grind.
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.76.0
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
local loot = nil
do
    local ok, mod = pcall(require, "loot")
    if ok and type(mod) == "table" then
        loot = mod
    end
end

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
-- Collect goals: when the search for a mob named like the item began coming
-- up empty. 0 while one is in sight.
local g_nosource_since = 0
local SOURCE_PATIENCE = 30.0  -- seconds of walking before any camp mob will do
local g_armed_engage = false
local g_loot_wait = false
local g_label = "fighting"
-- Talk goals: when the NPC's frame first showed open. 0 while it is not.
local g_talk_opened = 0
local g_in_dialog = false      -- the last tick was spent on an NPC dialog goal
local g_in_travel = false      -- the last tick was spent walking to a waypoint
local TALK_DONE = 2.0         -- seconds a frame is left open before the goal counts
-- A dialog that has landed (accepted / handed in / skipped): how long RestedXP
-- gets to tick the goal off itself before the engine counts it done (2.63.0).
local DIALOG_DONE_WAIT = 1.5
local g_dialog_done_at = 0
-- Every candidate NPC ruled out: when, so the list can be retried later.
local g_bad_since = 0
local BAD_GIVER_RETRY = 20.0
-- Where the bot was last sent to reach the giver, to re-route when it moves.
local g_giver_walk = nil

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

local last_walk_x, last_walk_y = nil, nil
local last_note = nil

local function trail(tag, fmt, ...)
    if errorlog then
        errorlog.trail(tag, fmt, ...)
    end
end

local function probe(tag)
    if errorlog then
        errorlog.probe(tag)
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
    -- VALID FIRST, ALWAYS (2.32.0). The unit is held across ticks; once the
    -- game frees the object behind it, any other method is a native read of
    -- freed memory - pcall cannot catch that, the game dies. 2.31.0 asked
    -- is_dead before is_valid. An engaged target that has gone invalid most
    -- likely died and was cleaned up, so it is recorded as a kill from the
    -- saved GUID, never by touching the object.
    if not unit or safe(function() return unit:is_valid() end) ~= true then
        if state.target.kind == "kill" and state.target.guid then
            state.mark_killed(state.target.guid)
            -- No handle left to read: queue the corpse from what was saved.
            local ok_l, lt = pcall(require, "loot")
            if ok_l and type(lt) == "table" and type(lt.note_kill_guid) == "function" then
                lt.note_kill_guid(state.target.guid,
                    state.target.x and { x = state.target.x, y = state.target.y, z = state.target.z } or nil)
            end
        end
        release_combat()
        return false
    end
    if safe(function() return unit:is_dead() end) == true
        or safe(function() return unit:is_dead_or_ghost() end) == true then
        state.mark_killed(state.target.guid or safe(function() return unit:get_guid() end))
        trail("act", "killed %s", tostring(safe(function() return unit:get_name() end)))
        -- Queue the corpse now, in this tick, so loot.has_work is already
        -- true when the engine next looks for something to pull.
        if loot and type(loot.note_kill) == "function" then
            loot.note_kill(unit)
        end
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
    if dist > targeting.MAX_RANGE then
        release_combat()
        return false
    end
    probe("f:set_target")
    targeting.ensure_target(player, unit)
    probe("f:combat_range")
    local yards = combat_yards(player)
    probe("f:start_auto_attack")
    targeting.start_auto_attack(player, unit)
    probe("f:combat_engage")
    if not movement.combat_engage(player, unit, yards) then
        if state.is_unreachable and state.is_unreachable(state.target.guid) then
            release_combat()
            state.set_note("Quest", "Skip unreachable")
            return false
        end
        probe("f:face (closing)")
        movement.face(unit)
        state.set_note("Quest", note or "Closing")
        probe("f:combat_scan (closing)")
        local pack = targeting.combat_scan(player, yards)
        probe("f:rotation.tick (closing)")
        rotation.tick(player, unit, { enemies = pack, no_move = true })
        probe("f:rotation.tick done")
        return true
    end
    probe("f:face")
    movement.face(unit)
    state.set_note("Quest", note or "Killing")
    probe("f:combat_scan")
    local pack = targeting.combat_scan(player, yards)
    probe("f:rotation.tick")
    rotation.tick(player, unit, { enemies = pack, no_move = true })
    probe("f:rotation.tick done")
    return true
end

local function engage(player, unit, note)
    -- The first fight after Start is where every crash happened; one burst
    -- there is enough. Arming on every engage wrote 15,000 lines in five
    -- minutes of normal play.
    if errorlog and not g_armed_engage and gui.is_on("crash_recorder") then
        g_armed_engage = true
        errorlog.arm("first engage")
    end
    trail("act", "engage %s (%s)", tostring(safe(function() return unit:get_name() end)), tostring(note))
    targeting.set_current(unit, "kill")
    g_kill_until = izi.now() + KILL_TIMEOUT
    fight_unit(player, unit, note)
end

--- Anything already fighting us comes first, whatever the goal is: walking on
--- to a quest giver with three mobs on your back is how a character dies.
--- THE COMBAT LOCK (2.39.0). Returns true while the fight owns the tick; the
--- quest goal and its waypoint only get the tick back once nothing is left.
---
---   1. a mob attacking the player or the pet that is not the current target
---      -> switch to the nearest one
---   2. the current kill target, while it lives -> keep fighting it
---   3. any attacker at all (the current one proved unreachable, say)
---      -> engage the nearest
---   4. still in combat but nothing in view -> hold position, up to 8 s
---
--- Attackers are looked for out to THREAT_RANGE (40 yd), not combat range
--- + 10, so a caster hitting a melee character from range counts.
local function fight_back(player, label)
    local range = targeting.THREAT_RANGE or 40
    local cur_guid = (state.target.kind == "kill") and state.target.guid or nil
    local attacker = targeting.attacker_to_switch(player, cur_guid, range)
    if attacker then
        targeting.combat_active()
        trail("act", "switch to attacker %s", tostring(safe(function() return attacker:get_name() end)))
        engage(player, attacker, "Guide: defending")
        return true
    end
    local unit = state.target.unit
    if unit and state.target.kind == "kill" then
        if fight_unit(player, unit, "Guide: " .. label) then
            targeting.combat_active()
            return true
        end
    end
    if safe(function() return player:is_in_combat() end) ~= true then
        targeting.combat_hold(player)        -- resets the hold window
        return false
    end
    local nearest = targeting.nearest(player, targeting.threats(player, range))
    if nearest then
        targeting.combat_active()
        engage(player, nearest, "Guide: defending")
        return true
    end
    if targeting.combat_hold(player) then
        movement.nav_stop()
        state.set_note("Quest", "Guide: holding - combat not over")
        return true
    end
    return false
end

--- Walk toward a position. Returns true while there is still walking to do.
-- KILL MOBS ON THE WAY (2.51.0). Every walk the engine makes goes through
-- walk_to; before each leg it looks - at most every PATH_SCAN_GAP - for a
-- hostile mob ahead within PATH_RANGE (guide.find_path_mob) and fights it
-- through the normal path: combat lock, loot, then on. Off while a rest is
-- due (the rest would come first anyway) and when the Questing tab's box is
-- unticked.
local PATH_RANGE = 20
local PATH_CONE = 70           -- degrees either side of the direction of travel
local PATH_SCAN_GAP = 0.8
local g_path_scan_until = 0

local function path_pull(dest)
    if not gui.is_on("quest_path_pull") then
        return false
    end
    local now = izi.now()
    if now < g_path_scan_until then
        return false
    end
    g_path_scan_until = now + PATH_SCAN_GAP
    local player = safe(function() return izi.me() end)
    if not player then
        return false
    end
    -- Low health or mana: the rest comes first, not another fight.
    local hp = safe(function() return player:get_health_percentage() end)
    if type(hp) == "number" and hp < 50 then
        return false
    end
    local unit = guide.find_path_mob(player, dest, PATH_RANGE, PATH_CONE, 4, 3)
    if not unit then
        return false
    end
    trail("act", "clear the path: %s", tostring(safe(function() return unit:get_name() end)))
    engage(player, unit, "Guide: clearing the path")
    return true
end

local function walk_to(pos, note)
    if movement.arrived(pos, ARRIVE) then
        return false
    end
    if path_pull(pos) then
        return true
    end
    -- Only when the destination moves to a new yard: formatting the line
    -- every frame just to have errorlog throw it away is what this avoids.
    local wx, wy = math.floor(pos.x), math.floor(pos.y)
    if wx ~= last_walk_x or wy ~= last_walk_y then
        last_walk_x, last_walk_y = wx, wy
        local me = safe(function() return izi.me():get_position() end)
        trail("walk", "to (%.0f, %.0f, %.0f) %.0fy away for %s", pos.x, pos.y, pos.z,
            me and geometry.distance(me, pos) or -1, tostring(note))
    end
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
    g_in_travel = true
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
-- NPCs that did not offer this goal's quest, or ran out of tries (2.50.0).
-- GUID -> true; cleared when the goal changes. find_giver skips them, so a
-- guard picked as "nearest at the waypoint" is not retried until the
-- watchdog steps in.
local g_bad_givers = {}

local function bad(unit)
    local g = unit and safe(function() return unit:get_guid() end)
    return g ~= nil and g_bad_givers[g] == true
end

local function find_giver(player, goal, kind, wps)
    local known = guide.known_quest_npc(kind, goal.quest_id, goal.text)
    if known then
        local unit = targeting.find_npc(player, known, 80)
        if unit and not bad(unit) then
            return unit, "learned id " .. tostring(known)
        end
    end
    -- An NPC RestedXP has marked with a raid icon (2.53.0): the guide marks
    -- the giver so it can be found - more certain than the waypoint title
    -- or the nearest unit at the waypoint.
    local marked = guide.find_marked(player, 80, "friendly", g_bad_givers)
    if marked then
        return marked, "raid marker"
    end
    for i = 1, #wps do
        local title = wps[i].title
        if title then
            local unit = targeting.find_named(player, title, nil, 80)
            if unit and not bad(unit) then
                return unit, "waypoint title '" .. title .. "'"
            end
        end
    end
    -- The player's target only counts when it stands at the goal's waypoint
    -- (2.71.0): a vendor trip leaves the merchant targeted, and the next accept
    -- was tried on him ("accept with Godric Rothgar via player target").
    local tid, tunit = guide.target_npc_id(player)
    if tid and tunit and not bad(tunit) and safe(function() return player:can_attack(tunit) end) == false then
        local near = (#wps == 0)
        local tp = safe(function() return tunit:get_position() end)
        if not near and tp then
            for i = 1, #wps do
                local p = wps[i].pos
                if p and geometry.distance(tp, p) <= TALK_SEARCH * 2 then
                    near = true
                    break
                end
            end
        end
        if near then
            return tunit, "player target"
        end
    end
    for i = 1, #wps do
        local unit = guide.nearest_talkable(player, TALK_SEARCH, wps[i].pos, g_bad_givers)
        if unit then
            return unit, "nearest at waypoint"
        end
    end
    if #wps == 0 then
        local unit = guide.nearest_talkable(player, TALK_SEARCH, nil, g_bad_givers)
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

--- The goal is already satisfied in the quest log: accepted, or handed in.
--- RestedXP normally ticks these off itself, but its snapshot can lag a
--- tick - or the player did it by hand - and the bot walked to the NPC and
--- opened a dialog for nothing (2.63.0).
local function dialog_already_done(goal, kind)
    local qid = goal.quest_id
    if not qid then
        return false
    end
    local on = safe(function() return core.quests.is_on_quest(qid) end) == true
    if kind == "accept" then
        return on
    end
    if kind == "turnin" then
        return not on and safe(function() return core.quests.is_quest_flagged_completed(qid) end) == true
    end
    return false
end

local function dialog_goal(player, goal, kind, wps, label)
    if dialog_already_done(goal, kind) then
        trail("act", "%s quest %s: already done in the quest log - next goal", kind, tostring(goal.quest_id))
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    local unit, how = find_giver(player, goal, kind, wps)
    if not unit then
        -- Every NPC here was ruled out. Give them another chance after a
        -- while (2.63.0): a giver that timed out once - lag, a frame that
        -- opened late - is usually fine the second time, and until now the
        -- list was only cleared when the goal changed, i.e. by the watchdog.
        if next(g_bad_givers) ~= nil then
            local now = izi.now()
            if g_bad_since == 0 then
                g_bad_since = now
            elseif (now - g_bad_since) >= BAD_GIVER_RETRY then
                trail("act", "%s: retrying every NPC at the waypoint", kind)
                g_bad_givers = {}
                g_bad_since = 0
            end
        end
        return false
    end
    g_bad_since = 0
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > TALK_REACH then
        local p = safe(function() return unit:get_position() end)
        if p then
            -- Re-route when the giver is not where the bot is already
            -- heading (2.63.0): walk_to does not re-issue while moving, so a
            -- walk begun toward the waypoint carried on to it before turning
            -- to an NPC standing somewhere else - or one walking a patrol.
            if g_giver_walk == nil or geometry.distance(g_giver_walk, p) > 5 then
                g_giver_walk = { x = p.x, y = p.y, z = p.z }
                movement.nav_stop()
            end
            walk_to(p, label)
            return true
        end
        return false
    end
    g_giver_walk = nil
    movement.nav_stop()

    local npc_id = geometry.object_id(unit)
    trail("act", "%s with %s npc %s via %s", kind,
        tostring(safe(function() return unit:get_name() end)), tostring(npc_id), tostring(how))
    if (kind == "accept" or kind == "turnin") and goal.quest_id then
        g_pending = { kind = kind, quest_id = goal.quest_id, npc_id = npc_id }
        state.quest.id = goal.quest_id
        local title = quest_title(goal, kind)
        local result
        if kind == "accept" then
            state.set_note("Quest", "Guide: accept " .. tostring(title or goal.quest_id))
            result = npc.accept(player, goal.quest_id, title, npc_id, unit)
        else
            state.set_note("Quest", "Guide: turn in " .. tostring(title or goal.quest_id))
            result = npc.turn_in(player, goal.quest_id, title, npc_id, unit)
        end
        if result == "done" or result == "skipped" then
            -- Landed. RestedXP gets DIALOG_DONE_WAIT to tick the goal off;
            -- after that it is counted done here so the bot moves on instead
            -- of standing at the NPC (2.63.0).
            local now = izi.now()
            if g_dialog_done_at == 0 then
                g_dialog_done_at = now
                trail("act", "%s quest %d: %s", kind, goal.quest_id, result)
            elseif (now - g_dialog_done_at) >= DIALOG_DONE_WAIT then
                guide.mark_goal_done(guide.step_num(), goal.index)
                npc.close()
                g_dialog_done_at = 0
            end
            return true
        end
        if result == "not_offered" or result == "gave_up" then
            -- Not this NPC: rule it out and let find_giver pick the next.
            local g = safe(function() return unit:get_guid() end)
            if g then
                g_bad_givers[g] = true
            end
            trail("act", "%s: %s does not have quest %d (%s) - trying another NPC", kind,
                tostring(safe(function() return unit:get_name() end)), goal.quest_id, result)
            npc.close()
            g_pending = nil
        end
        debug("%s quest %d at %s (npc %s)", kind, goal.quest_id, tostring(how), tostring(npc_id))
        return true
    end

    -- Talk / trainer / vendor / flight master: open the frame, and let the
    -- trainer, vendor and dialog modules act on it. Rate limited, because
    -- re-interacting tears down the frame that just opened.
    --
    -- DONE ONCE THE FRAME HAS OPENED (2.42.0). This interacted every ACT_GAP
    -- unless a GOSSIP frame was open - a merchant window is not one - and
    -- RestedXP does not tick every vendor / trainer / flight step off by
    -- itself, so the bot stood at the NPC re-interacting after the vendor had
    -- long finished. Now: once any NPC frame is open (gossip, merchant,
    -- trainer) and the vendor trip is over, the goal counts as done after
    -- TALK_DONE and the bot moves on.
    local now = izi.now()
    local gossip = safe(function() return core.quests.is_gossip_frame_shown() end) == true
    local ok_v, vendor = pcall(require, "vendor")
    local merchant = ok_v and type(vendor) == "table" and type(vendor.merchant_open) == "function"
        and vendor.merchant_open() == true
    local trainer_n = safe(function() return core.quests.get_num_trainer_services() end)
    local trainer = type(trainer_n) == "number" and trainer_n > 0
    if gossip or merchant or trainer then
        if g_talk_opened == 0 then
            g_talk_opened = now
        end
        local busy = ok_v and type(vendor) == "table" and type(vendor.is_busy) == "function" and vendor.is_busy()
        -- A trainer still buying ranks keeps the goal open (2.75.0): it used to
        -- count as done 2 s after the frame opened and the gossip was closed
        -- mid-training.
        if not busy then
            local ok_tr, tr = pcall(require, "trainer")
            busy = ok_tr and type(tr) == "table" and type(tr.busy) == "function" and tr.busy() == true
        end
        if not busy and (now - g_talk_opened) >= TALK_DONE then
            trail("act", "talk goal done at %s", tostring(safe(function() return unit:get_name() end)))
            guide.mark_goal_done(guide.step_num(), goal.index)
            pcall(function() core.quests.close_gossip() end)
            g_talk_opened = 0
            return true
        end
        state.set_note("Quest", "Guide: at " .. label)
        return true
    end
    if now >= g_act_until then
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
        if on and safe(function() return on:is_valid() end) ~= true then
            on = nil
        end
        if not on then
            -- RestedXP marks the unit a quest item is used on (2.53.0).
            on = guide.find_marked(player, 30, "hostile")
        end
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

local function camp_mob(player, wps)
    for i = 1, #wps do
        local unit = guide.find_camp_mob(player, wps[i].pos, CAMP_RADIUS)
        if unit then
            return unit
        end
    end
    return nil
end

local function kill_goal(player, goal, kind, wps, label)
    local now = izi.now()
    if now < g_scan_until then
        return false
    end
    g_scan_until = now + SCAN_GAP
    -- A mob RestedXP has marked with a raid icon comes first (2.53.0).
    local unit = guide.find_marked(player, MOB_RANGE, "hostile")
    -- Not one combat movement has given up on (2.76.0): it was re-engaged
    -- every 0.8 s - engage, "Skip unreachable", engage - for as long as the
    -- mark stayed on it.
    if unit and type(state.is_unreachable) == "function"
        and state.is_unreachable(safe(function() return unit:get_guid() end)) then
        unit = nil
    end
    if unit then
        trail("act", "raid-marked target %s", tostring(safe(function() return unit:get_name() end)))
    else
        unit = guide.find_mob(player, MOB_RANGE, goal)
    end
    if not unit and kind == "collect" then
        -- RestedXP names the item, not what drops it. First choice: a mob
        -- whose name shares a word with the item ("Tough Wolf Meat" ->
        -- "Ragged Young Wolf").
        unit = guide.find_source_mob(player, MOB_RANGE, goal)
        if unit then
            g_nosource_since = 0
        elseif guide.has_source_words(goal) then
            -- The item names its dropper but none is in sight: walk the goal's
            -- waypoints to find one rather than fight whatever is standing
            -- there. Only after SOURCE_PATIENCE of finding nothing does the
            -- camp fallback get a turn - the name may simply not match.
            if g_nosource_since == 0 then
                g_nosource_since = now
            end
            if (now - g_nosource_since) >= SOURCE_PATIENCE then
                unit = camp_mob(player, wps)
            end
        else
            -- The name gives no clue ("Linen Scraps"): the waypoints sit on
            -- the camp that drops it, so fight what stands there.
            unit = camp_mob(player, wps)
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

local tick_inner

--- The tick, plus a breadcrumb whenever the status line changes - the finest
--- grained record of what the bot was doing that is cheap enough to keep on.
function quest.tick(player)
    tick_inner(player)
    local note = state.note
    if note ~= last_note then
        last_note = note
        trail("note", "%s", tostring(note))
    end
end

tick_inner = function(player)
    g_in_dialog = false
    g_in_travel = false
    -- FIGHT FIRST (2.38.0). Anything attacking the player, and the fight
    -- already under way, come before every other branch of this tick. The
    -- early returns below (RestedXP not loaded, no active step, step
    -- complete, resting) used to come first, and the first two also released
    -- combat movement every tick - a mob could hit the bot with no answer.
    probe("q:fight_back")
    if fight_back(player, g_label) then
        g_loot_wait = false
        return
    end

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

    probe("q:learn_npc_id")
    guide.learn_npc_id(player)

    probe("q:goal")
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

    probe("q:classify")
    local kind = guide.classify(goal)
    probe("q:goal_waypoints")
    local wps = guide.goal_waypoints(goal)
    local label = goal_label(goal, wps)
    -- An accept / turn-in is labelled by its quest (2.63.0): goal_label gave
    -- the quest's objective line, so a turn-in read "Objective Complete" and
    -- an accept "Ice Claw Bear slain: 0/6".
    if kind == "accept" or kind == "turnin" then
        local title = quest_title(goal, kind)
        if title then
            label = (kind == "accept" and "accept " or "turn in ") .. title
        end
    end

    local key = string.format("%d|%d|%s|%s", guide.step_num(), goal.index or 0,
        tostring(goal.quest_id), kind)
    if key ~= g_key then
        commit_pending()
        g_key = key
        g_move = 1
        g_scan_until = 0
        g_act_until = 0
        g_kill_until = 0
        g_nosource_since = 0
        g_talk_opened = 0
        g_bad_givers = {}
        g_bad_since = 0
        g_dialog_done_at = 0
        g_giver_walk = nil
        -- A step change mid-fight keeps the fight; only an idle target is
        -- dropped.
        if safe(function() return player:is_in_combat() end) ~= true then
            state.reset_target()
        end
        trail("quest", "step %d goal %d: %s [%s] %s (quest %s, %d waypoint%s)",
            guide.step_num(), goal.index or 0, tostring(goal.action), kind, tostring(label),
            tostring(goal.quest_id), #wps, #wps == 1 and "" or "s")
        debug("step %d goal %d: %s %s (quest %s, %d waypoint%s)",
            guide.step_num(), goal.index or 0, tostring(goal.action), tostring(label),
            tostring(goal.quest_id), #wps, #wps == 1 and "" or "s")
    end

    g_label = label

    -- A corpse of ours to loot comes before the next pull (2.25.0). Stop our
    -- own walk once, so loot.tick's walk to the corpse is not swallowed by
    -- navigation's "already moving" answer, then wait for it to finish.
    if loot and loot.has_work(player) then
        if not g_loot_wait then
            g_loot_wait = true
            movement.nav_stop()
        end
        state.set_note("Quest", "Guide: looting before the next pull")
        return
    end
    g_loot_wait = false
    probe("q:act " .. kind)

    if kind == "accept" or kind == "turnin" or kind == "talk" then
        if dialog_goal(player, goal, kind, wps, label) then
            g_in_dialog = true
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
    -- REACHABILITY FIRST (2.59.0): Sentinel's validate_destination, cached.
    -- A waypoint it reports unreachable is skipped for the next one; when
    -- every waypoint of the goal is unreachable the goal is skipped with a log
    -- line, instead of walking into the 5-minute stuck watchdog.
    -- Never for an accept / turn-in / talk goal (2.71.0): the guide cannot
    -- move on without it, so skipping it left the bot idle on "step complete"
    -- with the quest never taken. Those keep walking to their waypoint.
    local must_do = kind == "accept" or kind == "turnin" or kind == "talk"
    if type(movement.reachable) == "function" and not must_do then
        local tried = 0
        while tried < #wps and movement.reachable(wps[g_move].pos) == false do
            g_move = g_move + 1
            if g_move > #wps then
                g_move = 1
            end
            tried = tried + 1
        end
        if tried >= #wps then
            trail("quest", "every waypoint of goal %d is unreachable - skipping it", goal.index or 0)
            core.log_warning("[Master Farmer - Grindbot] Quest goal '" .. tostring(label)
                .. "': Sentinel reports every waypoint unreachable - skipping it.")
            guide.mark_goal_done(guide.step_num(), goal.index)
            return
        end
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

--- Was the last tick spent walking toward a waypoint? Read by the watchdog.
function quest.in_travel()
    return g_in_travel == true
end

--- Was the last tick spent on an accept / turn in / talk goal at an NPC?
--- Read by the NPC-stuck watchdog.
function quest.in_npc_interaction()
    return g_in_dialog == true
end

--- Count the current guide goal as done - the watchdog's way out of an NPC
--- the bot has been stuck at.
function quest.skip_current_goal()
    local goal = guide.goal()
    if goal and goal.index then
        guide.mark_goal_done(guide.step_num(), goal.index)
    end
    g_talk_opened = 0
    g_key = nil
end

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
