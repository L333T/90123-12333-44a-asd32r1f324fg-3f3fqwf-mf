-- ============================================================================
-- Master Farmer - Grindbot
-- Quest engine - driven entirely by the RestedXP Guides addon. Never runs grind.
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.116.0
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
local MOB_RANGE = 100         -- yards: named quest mobs (2.94.0: the shared enemy scan)
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

local dbg_last, dbg_at = nil, 0

local function debug(fmt, ...)
    if not gui.is_on("quest_debug") then
        return
    end
    local text = string.format(fmt, ...)
    -- The same line every tick flooded the console (2.108.0): once per 5 s.
    local t = izi.now()
    if text == dbg_last and (t - dbg_at) < 5 then
        return
    end
    dbg_last, dbg_at = text, t
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
    -- A flight master's map counts as its frame (2.95.0): talking to it is
    -- what learns the flight path (".fp"), and the map is what opens.
    local taxi_n = safe(function() return core.taxi.num_nodes() end)
    local taxi = type(taxi_n) == "number" and taxi_n > 0
    if gossip or merchant or trainer or taxi then
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

-- ============================================================================
-- FLIGHT (2.95.0) - RestedXP ".fly <destination>"
-- ============================================================================
-- Walk to the flight master (found like any NPC goal), open its map - picking
-- the taxi gossip option when it talks first - find the destination by name
-- (the node list is per flight master, so it is matched by name every time,
-- never by a remembered index) and take it. In the air the bot does nothing.
-- 2.106.0 - FLIGHT MASTER FIXES
--   * A quest window left open at the flight master (Thor at Sentinel Hill
--     is both quest giver and gryphon master) has no taxi option; the bot
--     used to wait on it forever ("gossip has no taxi option"). Now any open
--     frame without a taxi option is closed and the NPC is talked to again.
--   * The taxi option is found through izi.gossip (TAXI icon, "taxi" type,
--     then the option text) and selected with the view's own :select().
--   * RestedXP colour tags (|cRXP_FRIENDLY_...|r) are stripped from the
--     destination before it is matched against the flight map's node names;
--     an exact node name wins, then the part before the comma.
--   * The flight is tracked by position, not only is_flying (not proven true
--     on a taxi): nothing else runs while it travels, a take-off that never
--     leaves the ground is retried, and on landing the goal is closed so the
--     bot heads for the guide's next position.
local g_fly_taken = 0
local g_fly_warned = false
local g_fly_noopt = 0          -- frames opened at the flight master with no taxi option
local g_fly_fails = 0          -- take-offs that never left the ground
local FLY_NOOPT_MAX = 4
local FLY_FAIL_MAX = 3
local FLY_TAKEOFF = 8.0        -- seconds for a take-off to show movement
local FLY_SPEED = 10.0         -- yd/s: faster than this is a flight
local FLY_LANDED = 2.5         -- seconds still before a flight counts as landed

-- { dest, taken, from, last, last_t, still_since, airborne, step, goal }
local g_flight = nil
local g_trip = nil             -- 2.115.0: flight trip toward a far goal (see far_travel)

local function clean_text(text)
    text = type(text) == "string" and text or ""
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cRXP_[%u_]-_", ""):gsub("|r", "")
    return text
end

local function fly_destination(goal)
    local text = clean_text(goal.text)
    local dest = text:match("^[Ff]ly%s+to%s+(.+)$") or text:match("^[Ff]ly%s+(.+)$") or text
    dest = dest:gsub("^%s+", ""):gsub("%s*[%.,!]+$", ""):gsub("%s+$", "")
    return dest ~= "" and dest or nil
end

local function taxi_node_for(dest)
    local n = safe(function() return core.taxi.num_nodes() end)
    if type(n) ~= "number" or n <= 0 or not dest then return nil, n end
    local want = dest:lower()
    local first = want:match("^([%a']+)")
    local partial, loose = nil, nil
    for i = 1, n do
        local name = safe(function() return core.taxi.node_name(i) end)
        if type(name) == "string" and name ~= "" and name ~= "INVALID" then
            local low = name:lower()
            local head = low:match("^([^,]+)") or low
            if low == want or head == want then
                return i, n
            end
            if not partial and (low:find(want, 1, true) or want:find(head, 1, true)) then
                partial = i
            end
            if not loose and first and #first >= 4 and low:find(first, 1, true) then
                loose = i
            end
        end
    end
    return partial or loose, n
end

local function is_taxi_option(o)
    if type(o) ~= "table" then return false end
    local gt = type(o.gossip_type) == "string" and o.gossip_type:lower() or ""
    local nm = type(o.name) == "string" and o.name:lower() or ""
    return gt == "taxi" or nm:find("fly", 1, true) ~= nil or nm:find("flight", 1, true) ~= nil
end

--- Select the taxi option of the open gossip frame. True when one was chosen.
local function taxi_gossip()
    local g = izi.gossip
    if type(g) == "table" then
        local view = nil
        local icon = type(g.ICON) == "table" and g.ICON.TAXI or nil
        if icon and type(g.find_option_by_icon) == "function" then
            view = safe(function() return g.find_option_by_icon(icon) end)
        end
        if type(view) ~= "table" and type(g.options) == "function" then
            local opts = safe(g.options)
            if type(opts) == "table" then
                for i = 1, #opts do
                    if is_taxi_option(opts[i]) then view = opts[i] break end
                end
            end
        end
        if type(view) == "table" and type(view.select) == "function" and pcall(view.select, view) then
            return true
        end
    end
    local opts = safe(function() return core.quests.get_gossip_options() end)
    if type(opts) ~= "table" then return false end
    for i = 1, #opts do
        local o = opts[i]
        if is_taxi_option(o) then
            local id = o.gossip_option_id
            if type(id) ~= "number" or id == 0 then id = i end
            pcall(function() core.quests.select_gossip_option(id) end)
            return true
        end
    end
    return false
end

local function pos_of(player)
    local p = safe(function() return player:get_position() end)
    if p and type(p.x) == "number" then return { x = p.x, y = p.y, z = p.z or 0 } end
    return nil
end

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- On a flight path? Tracked from the take-off: is_flying, or moving faster
--- than a character can run. Ends FLY_LANDED seconds after the movement stops.
function quest.in_flight(player)
    if not g_flight or not player then return false end
    local now = izi.now()
    local here = pos_of(player)
    if not here then return true end
    if safe(function() return player:is_flying() end) == true then
        g_flight.still_since = nil
        g_flight.airborne = true
        g_flight.last, g_flight.last_t = here, now
        return true
    end
    local dt = now - g_flight.last_t
    if dt >= 0.5 then
        local speed = dist3(here, g_flight.last) / dt
        g_flight.last, g_flight.last_t = here, now
        if speed > FLY_SPEED then
            g_flight.airborne = true
            g_flight.still_since = nil
        else
            g_flight.still_since = g_flight.still_since or now
        end
    end
    if not g_flight.airborne then
        -- Still on the ground after the take-off window: the flight never started.
        if now - g_flight.taken >= FLY_TAKEOFF and dist3(here, g_flight.from) < 5 then
            g_fly_fails = g_fly_fails + 1
            trail("act", "flight to %s did not take off (%d/%d)", tostring(g_flight.dest), g_fly_fails, FLY_FAIL_MAX)
            g_flight = nil
            g_fly_taken = 0
            return false
        end
        return true
    end
    if g_flight.still_since and (now - g_flight.still_since) >= FLY_LANDED then
        trail("act", "landed at %s (%.0f yd from take-off)", tostring(g_flight.dest), dist3(here, g_flight.from))
        -- RestedXP normally ticks the fly goal off on landing; close it if it
        -- has not, so the bot heads for the guide's next position.
        -- Not for a travel flight (2.115.0): that one only got the bot
        -- closer, the goal itself still has to be done.
        if g_flight.travel then
            g_trip = nil
        elseif guide.step_num() == g_flight.step then
            pcall(guide.mark_goal_done, g_flight.step, g_flight.goal)
        end
        g_flight = nil
        g_fly_taken = 0
        g_fly_fails = 0
        -- RELOAD ON LANDING (2.107.0): a UI reload after every flight, as
        -- asked - it refreshes RestedXP's step state at the new position.
        -- Not in the local API docs, so guarded; logged when missing.
        if type(core.reload_game_ui) == "function" then
            trail("act", "landed - reloading the game UI")
            pcall(core.reload_game_ui)
        else
            trail("act", "landed - core.reload_game_ui is not available on this build")
        end
        return false
    end
    return true
end

local function fly_goal(player, goal, wps, label)
    local now = izi.now()
    local dest = fly_destination(goal)
    -- In the air (or taking off): nothing to do but wait.
    if quest.in_flight(player) or safe(function() return player:is_flying() end) == true then
        state.set_note("Quest", "Flying to " .. tostring(dest))
        return true
    end
    if g_fly_fails >= FLY_FAIL_MAX then
        trail("act", "flight to %s failed %d times - skipping the step", tostring(dest), g_fly_fails)
        g_fly_fails = 0
        pcall(function() core.taxi.close() end)
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    -- 1. The flight map is open: pick the destination by name.
    local idx, n = taxi_node_for(dest)
    if type(n) == "number" and n > 0 then
        g_fly_noopt = 0
        if idx then
            local node = tostring(safe(function() return core.taxi.node_name(idx) end))
            trail("act", "flight to %s: node %d of %d (%s)", tostring(dest), idx, n, node)
            movement.nav_stop()
            pcall(function() core.taxi.take_node(idx) end)
            g_fly_taken = now
            local here = pos_of(player) or { x = 0, y = 0, z = 0 }
            g_flight = { dest = dest, taken = now, from = here, last = here, last_t = now,
                step = guide.step_num(), goal = goal.index }
            state.set_note("Quest", "Taking off to " .. tostring(dest))
            return true
        end
        if not g_fly_warned then
            g_fly_warned = true
            local names = {}
            for i = 1, n do
                names[#names + 1] = tostring(safe(function() return core.taxi.node_name(i) end))
            end
            trail("act", "no flight to '%s' from here (known: %s) - skipping the step",
                tostring(dest), table.concat(names, ", "))
        end
        pcall(function() core.taxi.close() end)
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    -- 2. A frame is open at the flight master: take its taxi option, or - a
    --    quest window, a gossip without one - close it and talk again.
    local gossip = safe(function() return core.quests.is_gossip_frame_shown() end) == true
    if gossip then
        if now >= g_act_until then
            g_act_until = now + ACT_GAP
            if taxi_gossip() then
                trail("act", "flight master: taxi option selected")
            else
                g_fly_noopt = g_fly_noopt + 1
                trail("act", "flight master frame has no taxi option - closing it and talking again (%d/%d)",
                    g_fly_noopt, FLY_NOOPT_MAX)
                pcall(function() core.quests.close_gossip() end)
                pcall(function() core.quests.close_quest() end)
                pcall(npc.close)
                if g_fly_noopt >= FLY_NOOPT_MAX then
                    g_fly_noopt = 0
                    trail("act", "flight master never offered a flight - skipping the step")
                    guide.mark_goal_done(guide.step_num(), goal.index)
                end
            end
        end
        state.set_note("Quest", "Guide: " .. label)
        return true
    end
    -- 3. Walk to the flight master and talk.
    local unit = find_giver(player, goal, "talk", wps)
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
    if now >= g_act_until then
        g_act_until = now + ACT_GAP
        -- A quest window left over from this NPC blocks its flight map.
        pcall(function() core.quests.close_quest() end)
        pcall(function() core.input.interact_with_object(unit) end)
    end
    state.set_note("Quest", "Guide: talk to the flight master")
    return true
end

-- ============================================================================
-- FLIGHT TRAVEL TO FAR GOALS (2.115.0)
-- ============================================================================
-- A guide goal thousands of yards away (the Dun Morogh turn-in from Elwynn)
-- was walked in a straight line over mountains, fighting everything on the
-- way. Now, when the goal is more than FAR_TRAVEL yards off and a flight
-- would clearly shorten the trip:
--   1. walk to the nearest flight point of the player's faction on this
--      continent (data/taxi_nodes.lua - positions from TaxiNodes.dbc),
--   2. talk to the friendly NPCs standing there, nearest first, until one
--      opens a flight map (directly or through its taxi gossip option),
--   3. of the flight points ON THAT MAP (only the ones this character knows),
--      take the one closest to the goal - if it really is closer,
--   4. fly (tracked by quest.in_flight, which pauses the whole bot), land,
--      and carry on with the same goal from there.
-- Anything that does not work out - no flight master found, no known flight
-- point closer to the goal, three take-offs that never left the ground - is
-- logged, and the goal is walked as before for TRAVEL_BLOCK seconds.
local FAR_TRAVEL = 1000        -- yards to the goal before a flight is considered
local TRAVEL_GAIN = 0.6        -- the flight must leave at most 60% of the trip to walk
local FM_SEARCH = 30           -- yards around the flight point to look for its master
local FM_TRIES = 2             -- interacts per NPC before trying the next one
local TRAVEL_BLOCK = 300       -- seconds a goal is walked after a failed flight plan

local taxi_nodes = nil
-- g_trip ({ key, start, target, tried, fm_guid, fm_tries }) is declared with g_flight.
local g_trip_block = {}        -- goal key -> time before which no flight is planned

local function catalog()
    if taxi_nodes == nil then
        local ok, m = pcall(require, "data/taxi_nodes")
        taxi_nodes = (ok and type(m) == "table") and m or false
    end
    return taxi_nodes or nil
end

local function faction_key(player)
    local ok, f = pcall(require, "data/factions")
    if ok and type(f) == "table" and type(f.of_player) == "function" then
        local key = f.of_player(player)
        if type(key) == "string" then return key:lower() end
    end
    return nil
end

local function node_usable(n, map, fkey)
    if n.map ~= map then return false end
    if fkey == "alliance" then return n.alliance == true end
    if fkey == "horde" then return n.horde == true end
    return n.alliance == true or n.horde == true
end

local function d2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function trip_fail(key, why)
    trail("travel", "no flight: %s - walking the goal instead", why)
    g_trip_block[key] = izi.now() + TRAVEL_BLOCK
    g_trip = nil
    pcall(function() core.taxi.close() end)
    return false
end

--- The flight point on the OPEN map that lands closest to the target.
local function best_map_node(map, fkey, target, start)
    local n = safe(function() return core.taxi.num_nodes() end)
    if type(n) ~= "number" or n <= 0 then return nil end
    local cat = catalog()
    local best_i, best_e, best_d = nil, nil, nil
    for i = 1, n do
        local name = safe(function() return core.taxi.node_name(i) end)
        local list = cat and type(name) == "string" and name ~= "" and name ~= "INVALID" and cat.find(name) or nil
        if type(list) == "table" then
            for k = 1, #list do
                local e = list[k]
                if node_usable(e, map, fkey) and d2(e, start) > 50 then
                    local d = d2(e, target)
                    if best_d == nil or d < best_d then
                        best_i, best_e, best_d = i, e, d
                    end
                end
            end
        end
    end
    return best_i, best_e, best_d
end

--- True while a flight trip toward a far goal owns the tick.
local function far_travel(player, goal, kind, wps, label)
    if kind == "fly" or #wps == 0 or g_flight then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    local here = pos_of(player)
    if not here then return false end
    -- The goal's nearest waypoint.
    local target, dist = nil, nil
    for i = 1, #wps do
        local p = wps[i].pos
        if p and type(p.x) == "number" then
            local d = d2(here, p)
            if dist == nil or d < dist then target, dist = p, d end
        end
    end
    local key = tostring(guide.step_num()) .. "|" .. tostring(goal.index)
    if not target or dist <= FAR_TRAVEL then
        if g_trip and g_trip.key == key then g_trip = nil end
        return false
    end
    if (g_trip_block[key] or 0) > izi.now() then return false end
    local cat = catalog()
    local map = safe(function() return core.get_map_id() end)
    local fkey = faction_key(player)
    if not cat or type(map) ~= "number" then return false end

    -- Plan once per goal: nearest start point, and is a flight worth it at all?
    if not g_trip or g_trip.key ~= key then
        local start, sd, near_goal = nil, nil, nil
        for i = 1, #cat.nodes do
            local n = cat.nodes[i]
            if node_usable(n, map, fkey) then
                local d = d2(here, n)
                if sd == nil or d < sd then start, sd = n, d end
                local g = d2(n, target)
                if near_goal == nil or g < near_goal then near_goal = g end
            end
        end
        if not start or near_goal == nil or sd + near_goal > dist * TRAVEL_GAIN then
            return trip_fail(key, string.format("no flight point shortens the %.0f yd trip", dist))
        end
        g_trip = { key = key, start = start, target = { x = target.x, y = target.y, z = target.z },
            tried = {}, fm_guid = nil, fm_tries = 0 }
        g_fly_fails = 0
        trail("travel", "goal %.0f yd away - flying: walk to %s (%.0f yd)", dist, start.name, sd)
    end
    local trip = g_trip
    if g_fly_fails >= FLY_FAIL_MAX then
        g_fly_fails = 0
        return trip_fail(key, "the flight did not take off")
    end
    local now = izi.now()

    -- 3. Flight map open: take the known flight point closest to the goal.
    local n_nodes = safe(function() return core.taxi.num_nodes() end)
    if type(n_nodes) == "number" and n_nodes > 0 then
        local idx, e, gd = best_map_node(map, fkey, trip.target, trip.start)
        if not idx or gd > dist * TRAVEL_GAIN then
            return trip_fail(key, "no known flight point is closer to the goal")
        end
        trail("travel", "flying to %s (lands %.0f yd from the goal, was %.0f)", e.name, gd, dist)
        movement.nav_stop()
        pcall(function() core.taxi.take_node(idx) end)
        g_fly_taken = now
        local from = here
        g_flight = { dest = e.name, taken = now, from = from, last = from, last_t = now,
            step = guide.step_num(), goal = goal.index, travel = true }
        state.set_note("Travel", "Taking off to " .. e.name)
        return true
    end

    -- 2b. A gossip window: its taxi option, else this NPC is not the one.
    if safe(function() return core.quests.is_gossip_frame_shown() end) == true then
        if now >= g_act_until then
            g_act_until = now + ACT_GAP
            if not taxi_gossip() then
                if trip.fm_guid then trip.tried[trip.fm_guid] = true end
                trip.fm_guid, trip.fm_tries = nil, 0
                pcall(function() core.quests.close_gossip() end)
            end
        end
        state.set_note("Travel", "Talking to the flight master")
        return true
    end

    -- 1. Walk to the flight point.
    local sp = trip.start
    local to_start = d2(here, sp)
    if to_start > FM_SEARCH * 0.5 and not trip.fm_guid then
        walk_to({ x = sp.x, y = sp.y, z = sp.z }, "flight master at " .. sp.name)
        state.set_note("Travel", string.format("To %s flight master  %.0fy", sp.name, to_start))
        return true
    end

    -- 2. Find its flight master: friendly NPCs near the flight point, nearest first.
    local unit = nil
    if trip.fm_guid then
        local list = targeting.visible_objects() or {}
        for i = 1, #list do
            local u = list[i]
            if u and safe(function() return u:is_valid() end) == true
                and safe(function() return u:get_guid() end) == trip.fm_guid then
                unit = u
                break
            end
        end
        if not unit then trip.fm_guid = nil end
    end
    if not unit then
        local best_d = nil
        local list = targeting.visible_objects() or {}
        for i = 1, #list do
            local u = list[i]
            if u and safe(function() return u:is_valid() end) == true
                and safe(function() return u:is_player() end) ~= true
                and safe(function() return u:is_dead() end) ~= true
                and safe(function() return player:can_attack(u) end) ~= true then
                local g = safe(function() return u:get_guid() end)
                local p = safe(function() return u:get_position() end)
                if g ~= nil and not trip.tried[g] and p and d2(p, sp) <= FM_SEARCH then
                    local d = d2(here, p)
                    if best_d == nil or d < best_d then unit, best_d = u, d end
                end
            end
        end
        if not unit then
            return trip_fail(key, "no flight master found at " .. sp.name)
        end
        trip.fm_guid = safe(function() return unit:get_guid() end)
        trip.fm_tries = 0
    end
    local ud = safe(function() return player:distance_to(unit) end) or 99
    if ud > TALK_REACH then
        local p = safe(function() return unit:get_position() end)
        if p then walk_to(p, "flight master") end
        state.set_note("Travel", "To the flight master")
        return true
    end
    movement.nav_stop()
    if now >= g_act_until then
        if trip.fm_tries >= FM_TRIES then
            trip.tried[trip.fm_guid] = true
            trip.fm_guid, trip.fm_tries = nil, 0
            return true
        end
        g_act_until = now + ACT_GAP
        trip.fm_tries = trip.fm_tries + 1
        pcall(function() core.quests.close_quest() end)
        pcall(function() core.input.interact_with_object(unit) end)
        trail("travel", "talking to %s (try %d)", tostring(safe(function() return unit:get_name() end)), trip.fm_tries)
    end
    state.set_note("Travel", "Talking to the flight master")
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

-- QUEST OBJECTS ON THE GROUND (2.79.0)
--   * use_object, not interact_with_object: the SDK documents use_object as
--     THE entry point for world objects (chests, nodes, quest crates) and
--     interact_with_object as not covering everything.
--   * A "Collecting" cast is left alone - re-clicking every ACT_GAP
--     interrupted it.
--   * The loot window the object opens is emptied and closed.
--   * Reach is measured generously (a big object's centre can be several
--     yards inside it), and once the walk has stopped next to it the bot
--     clicks from up to OBJECT_CLICK.
--   * An object used OBJECT_TRIES times with nothing to show is skipped for
--     OBJECT_SKIP seconds, so the next one is tried.
local OBJECT_REACH = 5.0
local OBJECT_CLICK = 8.0
local OBJECT_TRIES = 4
local OBJECT_SKIP = 60
local g_obj = { guid = nil, uses = 0 }
local g_obj_skip = {}          -- guid -> until

local function loot_window_open()
    local n = safe(function() return core.game_ui.get_loot_item_count() end)
    return type(n) == "number" and n > 0, n
end

local function object_skip_set()
    local now = izi.now()
    local set = {}
    for g, t in pairs(g_obj_skip) do
        if t > now then set[g] = true else g_obj_skip[g] = nil end
    end
    return set
end

local function object_goal(player, goal, label)
    -- 1. The object's loot window: take everything, close it.
    local open, n = loot_window_open()
    if open then
        for i = 0, n - 1 do
            pcall(function() core.input.loot_item(i) end)
        end
        pcall(function() core.input.close_loot() end)
        g_obj.uses = 0
        trail("act", "looted %d slot(s) from a quest object", n)
        state.set_note("Quest", "Guide: looting " .. label)
        return true
    end
    -- 2. Mid "Collecting" / "Opening" cast: wait for it.
    if safe(function() return player:is_channeling_or_casting() end) == true then
        state.set_note("Quest", "Guide: using " .. label)
        return true
    end

    local obj, odist = guide.find_object(player, OBJECT_RANGE, goal, object_skip_set())
    if not obj then
        return false
    end
    local guid = safe(function() return obj:get_guid() end)
    if guid ~= g_obj.guid then
        g_obj.guid, g_obj.uses = guid, 0
    end
    local standing = not movement.is_moving()
    if type(odist) == "number" and (odist <= OBJECT_REACH or (standing and odist <= OBJECT_CLICK)) then
        movement.nav_stop()
        local now = izi.now()
        if now >= g_act_until then
            if g_obj.uses >= OBJECT_TRIES then
                if guid then
                    g_obj_skip[guid] = now + OBJECT_SKIP
                end
                trail("act", "quest object %s gave nothing after %d uses - trying another",
                    tostring(safe(function() return obj:get_name() end)), g_obj.uses)
                g_obj.guid, g_obj.uses = nil, 0
                return true
            end
            g_act_until = now + ACT_GAP
            g_obj.uses = g_obj.uses + 1
            local ok = safe(function() return core.input.use_object(obj) end)
            if ok ~= true then
                pcall(function() core.input.interact_with_object(obj) end)
            end
            trail("act", "use quest object %s (%.1f yd, use %d)",
                tostring(safe(function() return obj:get_name() end)), odist, g_obj.uses)
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
        g_obj.guid, g_obj.uses = nil, 0
        g_fly_taken, g_fly_warned, g_fly_noopt = 0, false, 0
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

    -- A far goal: fly most of the way (2.115.0).
    if far_travel(player, goal, kind, wps, label) then
        return
    end

    -- TRAINER STEPS EVERY 3 LEVELS (2.104.0): a RestedXP ".trainer" goal
    -- before the next check is due is skipped to the next goal.
    if type(goal.action) == "string" and string.lower(goal.action) == "trainer" then
        local ok_tr, tr = pcall(require, "trainer")
        local no_train = gui.is_on("train") ~= true
        if ok_tr and type(tr) == "table" and type(tr.due) == "function"
            and (no_train or not tr.due(player)) then
            trail("quest", "trainer goal skipped - %s", no_train and "Train Spells is off"
                or ("next check at level " .. tostring(tr.next_level())))
            guide.mark_goal_done(guide.step_num(), goal.index)
            return
        end
    end

    if kind == "accept" or kind == "turnin" or kind == "talk" then
        if dialog_goal(player, goal, kind, wps, label) then
            g_in_dialog = true
            return
        end
    elseif kind == "fly" then
        if fly_goal(player, goal, wps, label) then
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
    local must_do = kind == "accept" or kind == "turnin" or kind == "talk" or kind == "fly"
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
